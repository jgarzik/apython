# Every refusal a memoryview makes, and the views it must not read through.
#
# Its slots and methods used to leave non-locally on an error -- "operation
# forbidden on released memoryview object" above all, reached by a jump from
# the middle of twenty-one callers.  They return it now.
#
# The second half is what user code can do in the middle of an operation: the
# __index__ of a key, a slice bound or a value, the __float__ and the __bool__
# of a value are all Python, and each can release the very view it was called
# for.  The operation has to notice, because what it does next goes through
# the view's buffer pointer -- and once the view is released its owner is
# free to resize.
import array


class Boom(Exception):
    pass


class IndexRaises:
    def __index__(self):
        raise Boom("index")


def check(label, fn):
    try:
        r = fn()
    except Exception as e:
        print("%-34s %s%s" % (label, type(e).__name__,
                              ": " + str(e) if isinstance(e, Boom)
                              or "released" in str(e) else ""))
    else:
        if isinstance(r, memoryview):
            r = ("view", bytes(r))
        print("%-34s %r" % (label, r))


def setitem(m, key, value):
    m[key] = value
    return bytes(m)


def delitem(m, key):
    del m[key]


# ---- a released view answers nothing -------------------------------------
def released():
    m = memoryview(bytearray(b"abcd"))
    m.release()
    return m


ops = [
    ("m[0]", lambda m: m[0]),
    ("m[0:2]", lambda m: m[0:2]),
    ("m[0] = 1", lambda m: setitem(m, 0, 1)),
    ("m[0:1] = b'x'", lambda m: setitem(m, slice(0, 1), b"x")),
    ("len(m)", lambda m: len(m)),
    ("m.__len__()", lambda m: m.__len__()),
    ("m.__getitem__(0)", lambda m: m.__getitem__(0)),
    ("m.__setitem__(0, 1)", lambda m: m.__setitem__(0, 1)),
    ("list(m)", lambda m: list(m)),
    ("reversed(m)", lambda m: list(reversed(m))),
    ("hash(m)", lambda m: hash(m)),
    ("bytes(m)", lambda m: bytes(m)),
    ("bytearray(m)", lambda m: bytearray(m)),
    ("memoryview(m)", lambda m: memoryview(m)),
    ("m.tobytes()", lambda m: m.tobytes()),
    ("m.tolist()", lambda m: m.tolist()),
    ("m.hex()", lambda m: m.hex()),
    ("m.cast('B')", lambda m: m.cast("B")),
    ("m.toreadonly()", lambda m: m.toreadonly()),
    ("m.__enter__()", lambda m: m.__enter__()),
    ("m.nbytes", lambda m: m.nbytes),
    ("m.itemsize", lambda m: m.itemsize),
    ("m.format", lambda m: m.format),
    ("m.readonly", lambda m: m.readonly),
    ("m.obj", lambda m: m.obj),
    ("m.shape", lambda m: m.shape),
    ("m.strides", lambda m: m.strides),
    ("m.release() again", lambda m: m.release()),
    ("b'ab' + m", lambda m: b"ab" + m),
    ("bytearray += m", lambda m: bytearray(b"x").__iadd__(m)),
]
for label, fn in ops:
    check("released: " + label, lambda: fn(released()))

# ---- the ordinary refusals -------------------------------------------------
def live(data=b"abcd"):
    return memoryview(bytearray(data))


def ro():
    return memoryview(b"abcd")


cases = [
    ("memoryview()", lambda: memoryview()),
    ("memoryview(1, 2)", lambda: memoryview(b"a", b"b")),
    ("memoryview(5)", lambda: memoryview(5)),
    ("memoryview('a')", lambda: memoryview("a")),
    ("memoryview(None)", lambda: memoryview(None)),
    ("m[9]", lambda: live()[9]),
    ("m[-9]", lambda: live()[-9]),
    ("m['a']", lambda: live()["a"]),
    ("m[1.5]", lambda: live()[1.5]),
    ("m[raises:]", lambda: live()[IndexRaises():]),
    ("m[::0]", lambda: live()[::0]),
    ("m.__getitem__()", lambda: live().__getitem__()),
    ("m[9] = 1", lambda: setitem(live(), 9, 1)),
    ("m[0] = 256", lambda: setitem(live(), 0, 256)),
    ("m[0] = -1", lambda: setitem(live(), 0, -1)),
    ("m[0] = 'a'", lambda: setitem(live(), 0, "a")),
    ("m[0] = 1.5", lambda: setitem(live(), 0, 1.5)),
    ("m[raises] = 1", lambda: setitem(live(), IndexRaises(), 1)),
    ("m[raises:] = b''", lambda: setitem(live(), slice(IndexRaises(), None), b"")),
    ("m[0:2] = b'x'", lambda: setitem(live(), slice(0, 2), b"x")),
    ("m[0:2] = 5", lambda: setitem(live(), slice(0, 2), 5)),
    ("m[0:2] = b'xy'", lambda: setitem(live(), slice(0, 2), b"xy")),
    ("ro[0] = 1", lambda: setitem(ro(), 0, 1)),
    ("ro[0:1] = b'x'", lambda: setitem(ro(), slice(0, 1), b"x")),
    ("del m[0]", lambda: delitem(live(), 0)),
    ("del m[0:1]", lambda: delitem(live(), slice(0, 1))),
    ("m.__setitem__(0)", lambda: live().__setitem__(0)),
    ("hash(writable)", lambda: hash(live())),
    ("hash(ro) == hash(bytes)", lambda: hash(ro()) == hash(b"abcd")),
    ("hash(ro.cast('I'))", lambda: hash(ro().cast("I"))),
    ("m.cast('I') of 3 bytes", lambda: live(b"abc").cast("I")),
    ("m.cast('zz')", lambda: live().cast("zz")),
    ("m[::2].cast('B')", lambda: live()[::2].cast("B")),
    ("m.cast()", lambda: live().cast()),
    ("m.hex(1, 2, 3)", lambda: live().hex(1, 2, 3)),
    ("m.hex(':')", lambda: live().hex(":")),
    ("m.tolist()", lambda: live().tolist()),
    ("m.cast('H')[0] = 70000", lambda: setitem(live().cast("H"), 0, 70000)),
    ("m.cast('h')[0] = -40000", lambda: setitem(live().cast("h"), 0, -40000)),
    ("m.cast('d') = 'a'", lambda: setitem(memoryview(bytearray(8)).cast("d"), 0, "a")),
    ("m.cast('d') = 1.5", lambda: setitem(memoryview(bytearray(8)).cast("d"), 0, 1.5) != b""),
    ("m.cast('c') = b'xy'", lambda: setitem(live().cast("c"), 0, b"xy")),
    ("m.cast('c') = 5", lambda: setitem(live().cast("c"), 0, 5)),
    ("m.cast('?') = 5", lambda: setitem(live().cast("?"), 0, 5)),
]
for label, fn in cases:
    for _ in range(2):
        check(label, fn)


# ---- a refusal leaves the export where it was -----------------------------
b = bytearray(b"abcd")
m = memoryview(b)
for label, fn in (("m[9]", lambda: m[9]), ("m[0] = 256", lambda: setitem(m, 0, 256)),
                  ("m.cast('I')[9]", lambda: m.cast("I")[9]),
                  ("m[raises:]", lambda: m[IndexRaises():]),
                  ("hash(m)", lambda: hash(m))):
    check("exported: " + label, fn)
check("append with the view out", lambda: b.append(1))
m.release()
check("append once it is released", lambda: (b.append(1), bytes(b))[1])


# ---- Python that releases the view in the middle of the operation ---------
class Releases:
    """An index, a float and a truth value, each of which releases a view."""

    def __init__(self, view, answer=0):
        self.view = view
        self.answer = answer

    def __index__(self):
        self.view.release()
        return self.answer

    def __float__(self):
        self.view.release()
        return 1.5

    def __bool__(self):
        self.view.release()
        return True


def fresh_view(fmt="B", size=8):
    owner = bytearray(size)
    return owner, memoryview(owner).cast(fmt)


def mid(label, fn):
    owner, m = fresh_view()
    check(label, lambda: fn(m))
    # The owner can be resized now, and is what it was.
    check("   owner afterwards", lambda: (owner.append(1), bytes(owner))[1])


# Not asked here: `m[Releases(m):]`.  CPython 3.12 hands back a view of the
# released buffer; this implementation refuses, and the two cannot be diffed.
mid("m[releases] = 1", lambda m: setitem(m, Releases(m), 1))
mid("m[releases:2] = b'xy'", lambda m: setitem(m, slice(Releases(m), 2), b"xy"))

owner, m = fresh_view("d")
check("m.cast('d')[0] = releases", lambda: setitem(m, 0, Releases(m)))
check("   owner afterwards", lambda: (owner.append(1), bytes(owner))[1])
owner, m = fresh_view("?")
check("m.cast('?')[0] = releases", lambda: setitem(m, 0, Releases(m)))
check("   owner afterwards", lambda: (owner.append(1), bytes(owner))[1])

# ---- an array's view, which goes through the buffer slot ------------------
a = array.array("i", [1, 2, 3])
m = memoryview(a)
check("array view [9]", lambda: m[9])
check("array view [0] = 'a'", lambda: setitem(m, 0, "a"))
m.release()
check("array view released", lambda: m[0])
