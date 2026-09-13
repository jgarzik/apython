"""`array.fromfile` and `array.tofile`, the two the module shipped without.

They are the reason the module's own header said "every caller in the suite
reaches for frombytes and tobytes instead": that was measured and it is not
true.  CPython's `test.datetimetester` calls `fromfile` on its way into 840 of
its tests, and it is the single largest reach of anything left in bugs.md.

The two are the file object's own `read` and `write` seen from the array's
side, so what they mostly have to get right is the failures: a short read
keeps what it got AND raises, a text-mode file is refused for the type of what
`read` returned, and an object with no `read` at all fails as an ordinary
missing attribute rather than as a type check.
"""

import array
import io
import os
import sys

TMP = "/tmp/apython_test_array_file.bin"


def show(label, fn):
    try:
        print(label, repr(fn()))
    except Exception as e:                      # noqa: BLE001 - the point
        print(label, type(e).__name__, str(e))


def cleanup():
    try:
        os.unlink(TMP)
    except OSError:
        pass


print("--- a round trip through a real file, every typecode ---")
for code, items in (("b", [-1, 0, 127]), ("B", [0, 1, 255]),
                    ("h", [-300, 300]), ("H", [0, 65535]),
                    ("i", [-1, 2, 3]), ("I", [0, 7]),
                    ("l", [-5, 5]), ("L", [9]),
                    ("q", [-(2 ** 40), 2 ** 40]), ("Q", [2 ** 40]),
                    ("f", [1.5, -2.25]), ("d", [1.5, -2.25]),
                    ("u", list("abc"))):
    a = array.array(code, items)
    with open(TMP, "wb") as f:
        a.tofile(f)
    b = array.array(code)
    with open(TMP, "rb") as f:
        b.fromfile(f, len(items))
    print("%-2s %-8s wrote %3d bytes, read back equal: %s"
          % (code, a.typecode, os.path.getsize(TMP), a == b))
cleanup()

print("--- a short read keeps what it got, then raises ---")
a = array.array("i", [1, 2, 3])
with open(TMP, "wb") as f:
    a.tofile(f)
b = array.array("i")
with open(TMP, "rb") as f:
    try:
        b.fromfile(f, 10)
    except EOFError as e:
        print("EOFError:", e)
print("kept:", b)

print("--- reading twice continues where the first left off ---")
c = array.array("i")
with open(TMP, "rb") as f:
    c.fromfile(f, 1)
    print("after one:", c)
    c.fromfile(f, 2)
    print("after two more:", c)

print("--- an existing array is appended to, not replaced ---")
d = array.array("i", [99])
with open(TMP, "rb") as f:
    d.fromfile(f, 3)
print("appended:", d)

print("--- zero is allowed, negative is not ---")
e = array.array("i")
with open(TMP, "rb") as f:
    e.fromfile(f, 0)
print("zero:", e)
with open(TMP, "rb") as f:
    show("negative       ", lambda: array.array("i").fromfile(f, -1))

print("--- what the argument has to be ---")
with open(TMP, "r") as f:
    show("text mode      ", lambda: array.array("i").fromfile(f, 1))
show("no read        ", lambda: array.array("i").fromfile(42, 1))
show("count not int  ", lambda: array.array("i").fromfile(io.BytesIO(b""), "x"))
show("tofile no write", lambda: array.array("i", [1]).tofile(42))
show("empty tofile   ", lambda: array.array("i").tofile(42))
cleanup()

print("--- BytesIO is a file for both of them ---")
bio = io.BytesIO()
array.array("d", [1.5, 2.5]).tofile(bio)
print("wrote:", bio.getvalue())
bio.seek(0)
g = array.array("d")
g.fromfile(bio, 2)
print("read:", g)

print("--- tofile appends to the stream position, and is not framed ---")
bio = io.BytesIO()
array.array("h", [1]).tofile(bio)
array.array("h", [2]).tofile(bio)
print("two writes:", bio.getvalue())
bio.seek(0)
h = array.array("h")
h.fromfile(bio, 2)
print("read as one:", h)

print("--- the arity and the names ---")
show("no args        ", lambda: array.array("i").fromfile())
show("one arg        ", lambda: array.array("i").fromfile(io.BytesIO(b"")))
show("tofile no args ", lambda: array.array("i").tofile())
print("fromfile on the type:", "fromfile" in dir(array.array))
print("tofile on the type:", "tofile" in dir(array.array))
