"""Regression suite for full `array` parity (diffed against CPython).

Covers subclassing, weakrefs, ArrayType, unicode methods, sequence operators,
extended slicing, all array methods, ABC registration, NaN comparisons,
Intable(2**64-1), _array_reconstructor (all 22 machine format codes),
__reduce_ex__ / pickle protocols 0-5, and forward/reverse iterator pickling.
"""

import array
import collections.abc
import copy
import gc
import operator
import pickle
import struct
import weakref
from array import _array_reconstructor as reconstructor


class ArraySub(array.array):
    pass


class ArraySubKw(array.array):
    def __init__(self, tc, init=(), extra=0):
        array.array.__init__(self)
        self.extra = extra


class ArraySubSlots(array.array):
    __slots__ = ("tag",)


class Intable:
    def __init__(self, v):
        self.v = v

    def __index__(self):
        return self.v


print("--- ArrayType & ABC ---")
print("ArrayType:", array.ArrayType is array.array)
print("issubclass MS:", issubclass(array.array, collections.abc.MutableSequence))
print("isinstance MS:", isinstance(array.array("B"), collections.abc.MutableSequence))
print("isinstance Rev:", isinstance(array.array("B"), collections.abc.Reversible))

print("--- subclassing & weakrefs ---")
s1 = ArraySub("i", [1, 2, 3])
s1.x = 99
print("sub:", type(s1).__name__, s1, s1.x)
s2 = ArraySubKw("h", [4, 5], extra=7)
print("subkw:", s2, s2.extra)
s3 = ArraySubSlots("b", [1, -1])
s3.tag = "ok"
print("subslots:", s3, s3.tag)

a = array.array("i", [10, 20, 30])
p = weakref.proxy(a)
print("proxy:", len(p), p.tobytes() == a.tobytes())
del a
gc.collect()
try:
    len(p)
except ReferenceError:
    print("proxy dead: ReferenceError")

print("--- unicode ---")
u = array.array("u", "a\xe9\u263a")
u.fromunicode("\U0002030a")
print("u:", u.tounicode(), repr(u), len(u))
for bad_tc in ("i", "B", "d"):
    try:
        array.array(bad_tc, "abc")
    except TypeError:
        print("str rejected:", bad_tc)
    try:
        array.array(bad_tc, u)
    except TypeError:
        print("u-array rejected:", bad_tc)

print("--- sequence ops ---")
x = array.array("i", [1, 2])
y = array.array("i", [3, 4])
print("add:", x + y)
print("mul:", x * 3, 3 * x, x * 0, x * -2)
z = array.array("i", [1, 2])
z += y
print("iadd:", z)
z *= 2
print("imul:", z)
z *= 0
print("imul0:", z)
print("contains:", 2 in x, 2.0 in x, 9 in x)
for fn, args in [
    (operator.add, (x, [1])),
    (operator.add, (x, array.array("f", [1.0]))),
    (operator.iadd, (array.array("i", [1]), array.array("f", [1.0]))),
]:
    try:
        fn(*args)
    except TypeError:
        print("op TypeError ok")

print("--- slicing ---")
a = array.array("i", [0, 1, 2, 3, 4, 5])
print("slice:", a[1:4], a[::-1], a[::2], a[4:1:-1])
a[1:3] = array.array("i", [10, 20, 30])
print("grow:", a)
a[1:4] = array.array("i", [99])
print("shrink:", a)
a[:] = a
print("self-assign:", a)
a[::2] = array.array("i", [7, 8, 9])
print("ext-assign:", a)
del a[1::2]
print("ext-del:", a)
del a[::-2]
print("neg-del:", a)
del a[0]
print("item-del:", a)

print("--- methods ---")
m = array.array("i", [1, 2, 3, 2, 1])
print("count:", m.count(2), m.count(99))
print("index:", m.index(2), m.index(2, 2), m.index(2, -3, -1))
m.insert(0, 10)
m.insert(100, 20)
m.insert(-1, 15)
print("insert:", m)
print("pop:", m.pop(), m.pop(0), m.pop(-2), m)
m.remove(2)
print("remove:", m)
m.reverse()
print("reverse:", m)
c1 = copy.copy(m)
c2 = copy.deepcopy(m)
print("copy:", c1 == m and c1 is not m, c2 == m and c2 is not m)

try:
    m.extend(array.array("f", [1.0]))
except TypeError:
    print("extend diff tc: TypeError")

orig_m = list(m)
try:
    m.fromlist([5, "bad"])
except TypeError:
    print("fromlist rollback:", list(m) == orig_m)

print("--- export lock ---")
e = array.array("i", [1, 2, 3])
mv = memoryview(e)
e *= 1
for fn, args in [
    (e.append, (4,)),
    (e.insert, (0, 4)),
    (e.pop, ()),
    (e.remove, (1,)),
    (operator.imul, (e, 2)),
    (operator.delitem, (e, slice(0, 1))),
]:
    try:
        fn(*args)
    except BufferError:
        pass
    else:
        print("MISSING BufferError")
mv.release()
print("export lock ok")

print("--- NaN & Intable ---")
for tc in ("f", "d"):
    n1 = array.array(tc, [float("nan")])
    n2 = array.array(tc, [float("nan")])
    print(tc, "nan:", n1 == n2, n1 != n2, n1 < n2, n1 <= n2, n1 > n2, n1 >= n2)
    try:
        n1[0] = None
    except TypeError:
        print(tc, "None rejected")

for tc in ("L", "Q"):
    big = array.array(tc, [Intable(0), Intable((1 << 64) - 1)])
    print(tc, "intable:", big.tolist())

print("--- reconstructor & pickle ---")
cases = [
    ("B", 0, "=BB", [0, 255]),
    ("b", 1, "=bb", [-128, 127]),
    ("H", 2, "<HH", [0, 65535]),
    ("H", 3, ">HH", [0, 65535]),
    ("h", 4, "<hh", [-32768, 32767]),
    ("h", 5, ">hh", [-32768, 32767]),
    ("I", 6, "<II", [0, (1 << 32) - 1]),
    ("I", 7, ">II", [0, (1 << 32) - 1]),
    ("i", 8, "<ii", [-(1 << 31), (1 << 31) - 1]),
    ("i", 9, ">ii", [-(1 << 31), (1 << 31) - 1]),
    ("Q", 10, "<QQ", [0, (1 << 64) - 1]),
    ("Q", 11, ">QQ", [0, (1 << 64) - 1]),
    ("q", 12, "<qq", [-(1 << 63), (1 << 63) - 1]),
    ("q", 13, ">qq", [-(1 << 63), (1 << 63) - 1]),
    ("f", 14, "<ff", [-1.5, 2.5]),
    ("f", 15, ">ff", [-1.5, 2.5]),
    ("d", 16, "<dd", [-1.5, 2.5]),
    ("d", 17, ">dd", [-1.5, 2.5]),
]
for tc, mf, fmt, vals in cases:
    raw = struct.pack(fmt, *vals)
    r = reconstructor(array.array, tc, mf, raw)
    assert r == array.array(tc, vals)
utext = "Bonne Journ\xe9e \U0002030a\U00020347"
for mf, enc in [(18, "utf-16-le"), (19, "utf-16-be"), (20, "utf-32-le"), (21, "utf-32-be")]:
    r = reconstructor(array.array, "u", mf, utext.encode(enc))
    assert r == array.array("u", utext)
print("reconstructor 22 formats ok")

for p in range(pickle.HIGHEST_PROTOCOL + 1):
    a = array.array("i", [1, -2, 3])
    b = pickle.loads(pickle.dumps(a, p))
    assert b == a and b is not a
    sub = ArraySub("i", [4, 5])
    sub.x = 123
    sub2 = pickle.loads(pickle.dumps(sub, p))
    assert sub2 == sub and sub2.x == 123 and type(sub2) is ArraySub
print("pickle protocols 0..5 ok")

print("--- iterator pickling & exhaustion ---")
orig = array.array("i", [10, 20, 30])
for p in range(pickle.HIGHEST_PROTOCOL + 1):
    it = iter(orig)
    next(it)
    it2, arr2 = pickle.loads(pickle.dumps((it, orig), p))
    arr2.append(40)
    assert list(it2) == [20, 30, 40]
    rit = reversed(orig)
    next(rit)
    rit2, rarr2 = pickle.loads(pickle.dumps((rit, orig), p))
    rarr2.insert(0, 99)
    assert list(rit2) == [10, 99]

exh = iter(array.array("i", [1, 2]))
list(exh)
a_exh = array.array("i", [1, 2])
exh2 = iter(a_exh)
emp2 = iter(a_exh)
for _ in exh2:
    next(emp2)
a_exh.append(3)
print("exhausted:", list(exh2), list(emp2))
print("ALL_OK")
