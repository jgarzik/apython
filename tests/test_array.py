"""The `array` module: a mutable sequence of C scalars, one typecode for all.

It was the largest missing C module by reach.  CPython's own suite imports it
from the test modules for struct, memoryview, io, bytes, socket, re, marshal,
codecs and the compression family -- more than the rest of the missing list
together -- and it is what stands between this tree and multiprocessing.

The storage is raw scalars and not Values, which is the whole reason the type
exists: an array of 'i' holds four-byte machine integers, and reading one
means widening it at the point of access.  Every typecode is exercised below
at its boundaries, because the narrowing half is where a wrong shift shows up
-- and it shows up as a wrong ANSWER, not a crash.
"""

import array

print("--- the typecodes ---")
print("typecodes:", array.typecodes)
for tc in array.typecodes:
    a = array.array(tc)
    print("%s itemsize=%d typecode=%r len=%d" % (tc, a.itemsize, a.typecode, len(a)))

print("--- construction ---")
print("empty:", array.array("i"))
print("from list:", array.array("i", [1, 2, 3]))
print("from tuple:", array.array("i", (4, 5)))
print("from range:", array.array("i", range(3)))
print("from another array:", array.array("i", array.array("i", [7, 8])))
print("from a generator:", array.array("i", (x * 2 for x in range(3))))

print("--- indexing ---")
a = array.array("i", [10, 20, 30])
print("forward:", a[0], a[1], a[2])
print("negative:", a[-1], a[-2], a[-3])
for i in (3, -4, 100):
    try:
        a[i]
        print("accepted", i, "- wrong")
    except IndexError as e:
        print("out of range", i, "->", e)

print("--- assignment ---")
a[0] = 99
a[-1] = -1
print("after:", a)
try:
    a[5] = 1
except IndexError as e:
    print("assign out of range:", e)

print("--- append and extend ---")
b = array.array("b")
b.append(1)
b.append(-2)
print("appended:", b)
b.extend([3, 4])
print("extended list:", b)
b.extend(array.array("b", [5]))
print("extended array:", b)
b.extend(())
print("extended empty:", b)

print("--- the ranges each typecode accepts ---")
LIMITS = {
    "b": (-128, 127), "B": (0, 255),
    "h": (-32768, 32767), "H": (0, 65535),
    "i": (-2147483648, 2147483647), "I": (0, 4294967295),
}
for tc, (lo, hi) in sorted(LIMITS.items()):
    a = array.array(tc, [lo, hi])
    print("%s ok at the edges: %s" % (tc, a.tolist()))
    for bad in (lo - 1, hi + 1):
        try:
            array.array(tc, [bad])
            print("  %s accepted %d - wrong" % (tc, bad))
        except OverflowError:
            print("  %s refuses %d" % (tc, bad))

print("--- the eight-byte codes hold what an int64 holds ---")
for tc in ("l", "q"):
    a = array.array(tc, [-(2 ** 63), 2 ** 63 - 1])
    print(tc, a.tolist())

print("--- floats ---")
f = array.array("d", [1.5, -0.25, 0.0])
print("d:", f.tolist())
g = array.array("f", [1.5, -0.25])
print("f:", g.tolist())
print("f narrows:", array.array("f", [1.0 / 3.0]).tolist() != [1.0 / 3.0])

print("--- tolist and fromlist ---")
a = array.array("i", [1, 2, 3])
print("tolist:", a.tolist())
c = array.array("i")
c.fromlist([9, 8])
print("fromlist:", c)

print("--- tobytes and frombytes ---")
a = array.array("b", [1, 2, 3])
print("tobytes:", a.tobytes())
d = array.array("b")
d.frombytes(a.tobytes())
print("roundtrip:", d, d == d)
e = array.array("i", [1, 2])
print("wider tobytes length:", len(e.tobytes()))
h = array.array("i")
h.frombytes(e.tobytes())
print("wider roundtrip:", h)
try:
    array.array("i").frombytes(b"\x01")
except ValueError as err:
    print("partial item:", err)

print("--- iteration ---")
a = array.array("i", [1, 2, 3])
print("list():", list(a))
print("comprehension:", [x + 1 for x in a])
print("sum:", sum(a))
print("max:", max(a), "min:", min(a))
print("in:", 2 in a, 99 in a)
print("reversed:", list(reversed(a)))
print("empty iterates:", list(array.array("i")))

print("--- len and truth ---")
print("len:", len(array.array("i")), len(array.array("i", [1, 2])))
print("truth:", bool(array.array("i")), bool(array.array("i", [0])))

print("--- buffer_info ---")
a = array.array("i", [1, 2, 3])
info = a.buffer_info()
print("length:", info[1], "address is an int:", isinstance(info[0], int))

print("--- repr ---")
print(repr(array.array("i")))
print(repr(array.array("i", [1])))
print(repr(array.array("d", [1.5])))
print(repr(array.array("b", [-1, 0, 1])))
print("str matches repr:", str(array.array("i", [1])) == repr(array.array("i", [1])))

print("--- what it refuses ---")
for bad in ("z", "", "ii", 5, None):
    try:
        array.array(bad)
        print("accepted", repr(bad), "- wrong")
    except (ValueError, TypeError) as err:
        print(repr(bad), "->", type(err).__name__)

try:
    array.array("i", [1.5])
except TypeError as err:
    print("float into an int array:", type(err).__name__)

try:
    array.array("i", 5)
except TypeError as err:
    print("non-iterable initialiser:", type(err).__name__)

print("--- it is not hashable ---")
try:
    hash(array.array("i"))
    print("hashable - wrong")
except TypeError as err:
    print("unhashable:", type(err).__name__)

print("--- a large one still answers ---")
big = array.array("i", range(1000))
print("len:", len(big), "first:", big[0], "last:", big[-1], "sum:", sum(big))

print("--- arrays compare by their items ---")
_a = array.array("i", [1, 2, 3])
print("eq:", _a == array.array("i", [1, 2, 3]), _a == array.array("i", [1, 2]))
print("ne:", _a != array.array("i", [1, 2, 4]))
print("cross typecode:", array.array("i", [1]) == array.array("f", [1.0]))
print("vs list:", _a == [1, 2, 3], _a != [1, 2, 3])
print("order:", _a < array.array("i", [1, 2, 4]), _a <= _a,
      _a > array.array("i", [1, 2]), _a >= _a)
print("by name:", _a.__eq__(array.array("i", [1, 2, 3])))
print("empty:", array.array("i") == array.array("i"))

print("--- a long repr is not truncated ---")
_big = array.array("i", range(40))
print(repr(_big))
print("len:", len(repr(_big)))

print("--- every typecode's range, and how it refuses ---")
_LIMITS = {"b": (-128, 127), "B": (0, 255), "h": (-32768, 32767),
           "H": (0, 65535), "i": (-2 ** 31, 2 ** 31 - 1), "I": (0, 2 ** 32 - 1),
           "l": (-2 ** 63, 2 ** 63 - 1), "L": (0, 2 ** 64 - 1),
           "q": (-2 ** 63, 2 ** 63 - 1), "Q": (0, 2 ** 64 - 1)}
for _c in "bBhHiIlLqQ":
    _lo, _hi = _LIMITS[_c]
    print(_c, "edges:", list(array.array(_c, [_lo, _hi])))
    for _v in (_lo - 1, _hi + 1, -1, 2 ** 64, -2 ** 64):
        try:
            array.array(_c, [_v])
            print("%s %-22s stored" % (_c, _v))
        except OverflowError as e:
            print("%s %-22s OverflowError: %s" % (_c, _v, e))

print("--- and what is not an integer at all ---")


class _Index:
    def __index__(self):
        return 5


print("__index__:", list(array.array("i", [_Index()])))
print("bool:", list(array.array("i", [True, False])))
for _bad in (1.5, "x", None):
    try:
        array.array("i", [_bad])
    except TypeError as e:
        print("%-6r TypeError: %s" % (_bad, e))

print("--- byteswap reverses each item in place ---")
for _c in "bBhHiIlLqQfdu":
    _a = (array.array(_c, "ab") if _c == "u"
          else array.array(_c, [1.5, 2.5]) if _c in "fd"
          else array.array(_c, [1, 2]))
    _before = _a.tobytes()
    print(_a.byteswap(), _c, _a.itemsize, _before.hex(), _a.tobytes().hex())
_h = array.array("h", [1, 2])
_h.byteswap()
_h.byteswap()
print("twice is identity:", _h)
print("empty:", array.array("i").byteswap(), array.array("i"))
try:
    array.array("i", [1]).byteswap(1)
except TypeError as e:
    print("arity:", e)

print("done")
