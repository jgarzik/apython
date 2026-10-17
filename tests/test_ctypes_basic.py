# ctypes over libc: loading, calls, structures, callbacks and memory.
# Diffed against CPython, so every line printed has to be the same there.

import ctypes
import ctypes.util
import struct
import sys
from ctypes import (CDLL, CFUNCTYPE, POINTER, Structure, Union, byref, c_char,
                    c_char_p, c_double, c_float, c_int, c_int8, c_long,
                    c_longlong, c_short, c_ubyte, c_uint, c_uint16, c_uint32,
                    c_ulonglong, c_void_p, c_wchar, c_wchar_p, c_bool,
                    c_size_t, cast, create_string_buffer,
                    create_unicode_buffer, memmove, memset, pointer, sizeof,
                    alignment, addressof, string_at, wstring_at, c_longdouble,
                    py_object, ArgumentError, BigEndianStructure)

libc = CDLL(ctypes.util.find_library("c"))

print("--- sizes")
for t in (c_char, c_ubyte, c_short, c_int, c_long, c_longlong, c_float,
          c_double, c_longdouble, c_void_p, c_char_p, c_wchar, c_bool,
          c_size_t):
    print(t.__name__, sizeof(t), alignment(t))

print("--- simple values")
print(c_int(42).value, c_int(2**32 + 7).value, c_uint(-1).value)
print(c_int8(200).value, c_uint16(70000).value, c_ulonglong(-1).value)
print(c_double(1.5).value, c_float(0.1).value == struct.unpack("f", struct.pack("f", 0.1))[0])
print(c_longdouble(2.5).value, c_longdouble(-1e300).value)
print(c_char(b"x").value, c_char(65).value, c_wchar("€").value)
print(c_bool(5).value, c_char_p(b"abc").value, c_wchar_p("hé").value)
print(c_void_p(None).value, c_void_p(1234).value)
print(repr(c_int(3)), repr(c_double(2.0)), bool(c_int(0)), bool(c_int(1)))
try:
    c_int("x")
except TypeError as e:
    print("TypeError", type(e).__name__)

print("--- calls")
print(libc.strlen(b"hello"))
libc.abs.argtypes = (c_int,)
print(libc.abs(-17))
libc.labs.restype = c_long
print(libc.labs(c_long(-2**40)))
libc.atof.restype = c_double
libc.atof.argtypes = (c_char_p,)
print(libc.atof(b"3.25"))
libc.strtoul.restype = c_ulonglong
print(libc.strtoul(b"ffffffffffffffff", None, 16))
libc.snprintf.restype = c_int
buf = create_string_buffer(64)
n = libc.snprintf(buf, sizeof(buf), b"%d-%s-%.2f", 7, b"ab", c_double(2.5))
print(n, buf.value)
try:
    libc.abs("not an int")
except ArgumentError as e:
    print("ArgumentError", e)

print("--- structures")


class POINT(Structure):
    _fields_ = [("x", c_int), ("y", c_int)]


class RECT(Structure):
    _fields_ = [("a", POINT), ("b", POINT)]


p = POINT(1, 2)
r = RECT(p, POINT(3, 4))
print(p.x, p.y, r.a.x, r.b.y, sizeof(RECT))
r.b.x = 30
print(r.b.x, POINT.x, POINT.y.offset, POINT.y.size)
setattr(p, "x", 9)
print(getattr(p, "x"), getattr(POINT, "x"))


class MIXED(Structure):
    _fields_ = [("c", c_char), ("d", c_double), ("s", c_short)]


class PACKED(Structure):
    _pack_ = 1
    _fields_ = [("c", c_char), ("d", c_double), ("s", c_short)]


print(sizeof(MIXED), MIXED.d.offset, MIXED.s.offset)
print(sizeof(PACKED), PACKED.d.offset, PACKED.s.offset)


class BITS(Structure):
    _fields_ = [("a", c_uint, 3), ("b", c_uint, 5), ("c", c_int, 4),
                ("d", c_short)]


bf = BITS(5, 17, -3, 9)
print(sizeof(BITS), bf.a, bf.b, bf.c, bf.d, BITS.c)


class U(Union):
    _fields_ = [("i", c_uint32), ("b", c_ubyte * 4)]


u = U(0x01020304)
print(sizeof(U), list(u.b))


class BE(BigEndianStructure):
    _fields_ = [("v", c_uint32)]


be = BE(0x01020304)
print(bytes(be).hex(), be.v)


class TM(Structure):
    _fields_ = [(n, c_int) for n in
                "sec min hour mday mon year wday yday isdst".split()] + \
               [("gmtoff", c_long), ("zone", c_char_p)]


t = c_long(86400 * 365 + 3661)
tm = TM()
libc.gmtime_r(byref(t), byref(tm))
print(tm.year, tm.mon, tm.mday, tm.hour, tm.min, tm.sec, tm.zone)


class DIV(Structure):
    _fields_ = [("quot", c_int), ("rem", c_int)]


libc.div.restype = DIV
d = libc.div(17, 5)
print(d.quot, d.rem)


class LDIV(Structure):
    _fields_ = [("quot", c_longlong), ("rem", c_longlong)]


libc.lldiv.restype = LDIV
libc.lldiv.argtypes = (c_longlong, c_longlong)
d = libc.lldiv(-(10**15), 7)
print(d.quot, d.rem)

print("--- arrays and pointers")
IntArr = c_int * 5
arr = IntArr(5, 1, 4, 2, 3)
print(len(arr), arr[0], arr[-1], arr[1:3], list(arr))
arr[2] = 40
print(arr[2], sizeof(arr), type(arr).__name__)
ip = pointer(c_int(7))
print(ip.contents.value, ip[0])
ip[0] = 8
print(ip.contents.value, bool(ip), bool(POINTER(c_int)()))
pa = cast(arr, POINTER(c_int))
print(pa[0], pa[4], pa[1:3])
s = create_string_buffer(b"hello", 10)
print(sizeof(s), s.value, s.raw)
s.value = b"hi"
print(s.raw[:4])
w = create_unicode_buffer("wärld")
print(sizeof(w), w.value)

print("--- callbacks")
CMPFUNC = CFUNCTYPE(c_int, POINTER(c_int), POINTER(c_int))
calls = []


def cmp(a, b):
    calls.append(1)
    return a[0] - b[0]


arr = IntArr(5, 1, 4, 2, 3)
cmp_c = CMPFUNC(cmp)
libc.qsort(arr, len(arr), sizeof(c_int), cmp_c)
print(list(arr), len(calls) > 0)

DFUNC = CFUNCTYPE(c_double, c_double, c_int)
f = DFUNC(lambda x, n: x * n + 0.5)
print(f(1.5, 4))
VFUNC = CFUNCTYPE(None, c_char_p)
seen = []
VFUNC(lambda s: seen.append(s))(b"xyz")
print(seen)

print("--- memory")
src = (c_ubyte * 8)(*range(8))
dst = (c_ubyte * 8)()
memmove(dst, src, 8)
print(list(dst))
memset(dst, 0x41, 4)
print(bytes(dst))
print(string_at(addressof(src), 4), string_at(b"abc\0def"))
print(wstring_at(create_unicode_buffer("wide"), 3))
ba = bytearray(8)
v = c_int.from_buffer(ba, 4)
v.value = -2
print(ba.hex())
c2 = c_int.from_buffer_copy(b"\x01\x00\x00\x00")
print(c2.value, memoryview(c2).tobytes(), bytes(c_uint16(0x1234)))
try:
    c_int.from_buffer(b"1234")
except TypeError as e:
    print("TypeError", e)
x = c_int(5)
y = c_int.from_address(addressof(x))
y.value = 6
print(x.value)
o = py_object([1, 2])
print(o.value)

print("--- errno")
lc2 = CDLL(ctypes.util.find_library("c"), use_errno=True)
lc2.open.argtypes = (c_char_p, c_int)
print(lc2.open(b"/nonexistent/x", 0), ctypes.get_errno())
print(ctypes.set_errno(0), ctypes.get_errno())
