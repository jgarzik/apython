# bytearray: a mutable byte buffer, which it was not.
#
# It had no methods at all -- tp_getattr was 0, tp_as_mapping was 0, and its
# sequence table held only sq_length.  Construction, len(), iteration and
# bytes(ba) worked; nothing else did.  No subscript, no item assignment, no
# find, no append, not even `in`.
#
# It could not grow, either: the data was inline at a fixed offset in the
# object body, so there was nowhere to put more of it.  The buffer is now a
# separate allocation with its own capacity, doubling as it fills, so append
# and extend are amortised O(1) -- the same shape as the compiler's Buf.
#
# This is a prerequisite twice over.  CPython's regex compiler builds its
# character classes in a `bytearray(256)` and does `charmap[av] = 1`, so
# every `[abc]` and every `a|b` died in _optimize_charset before a single
# opcode was generated.  And _io wants a real mutable buffer for readinto
# and for BufferedWriter.

def check(label, fn):
    try:
        print("%-32s %r" % (label, fn()))
    except BaseException as e:
        print("%-32s %s" % (label, type(e).__name__))


B = lambda *a: bytearray(*a)

print("--- construction ---")
check("bytearray()", lambda: bytes(B()))
check("bytearray(0)", lambda: bytes(B(0)))
check("bytearray(5)", lambda: bytes(B(5)))
check("bytearray(b'abc')", lambda: bytes(B(b"abc")))
check("bytearray(bytearray)", lambda: bytes(B(B(b"xy"))))
check("bytearray([65,66])", lambda: bytes(B([65, 66])))
check("bytearray((65,66))", lambda: bytes(B((65, 66))))
check("bytearray(range(3))", lambda: bytes(B(range(3))))
# bytearray(str, encoding) is not accepted yet; the old bug list recorded it.
check("bytearray(-1)", lambda: B(-1))
check("bytearray([256])", lambda: B([256]))
check("bytearray([-1])", lambda: B([-1]))
check("bytearray('ab')", lambda: B("ab"))
check("len", lambda: (len(B()), len(B(5)), len(B(b"abc"))))
check("repr", lambda: repr(B(b"a\x00b")))
check("bool", lambda: (bool(B()), bool(B(b"x"))))

print()
print("--- reading: subscript, slice, iteration, contains ---")
b = B(b"hello")
check("b[0]", lambda: b[0])
check("b[-1]", lambda: b[-1])
check("b[10]", lambda: b[10])
check("b[1:3]", lambda: bytes(b[1:3]))
check("type of a slice", lambda: type(b[1:3]).__name__)
check("b[:]", lambda: bytes(b[:]))
check("b[::2]", lambda: bytes(b[::2]))
check("b[::-1]", lambda: bytes(b[::-1]))
check("list(b)", lambda: list(b))
check("in (int)", lambda: (101 in b, 200 in b))
check("in (bytes)", lambda: (b"ell" in b, b"xyz" in b))
check("iter", lambda: [x for x in b])
check("min/max", lambda: (min(b), max(b)))
check("sum", lambda: sum(b))

print()
print("--- item and slice assignment ---")


def mut(fn):
    a = B(b"abcdef")
    fn(a)
    return bytes(a)


def setitem(k, v):
    a = B(b"abcdef")
    a[k] = v
    return bytes(a)


def delitem(k):
    a = B(b"abcdef")
    del a[k]
    return bytes(a)


check("b[0] = 65", lambda: setitem(0, 65))
check("b[-1] = 90", lambda: setitem(-1, 90))
check("b[1:3] = b'XY'", lambda: setitem(slice(1, 3), b"XY"))
check("b[1:3] = b'LONGER'", lambda: setitem(slice(1, 3), b"LONGER"))
check("b[1:3] = b''", lambda: setitem(slice(1, 3), b""))
check("b[1:1] = b'ZZ'", lambda: setitem(slice(1, 1), b"ZZ"))
check("b[:] = b'xy'", lambda: setitem(slice(None), b"xy"))
check("b[::2] = b'XYZ'", lambda: setitem(slice(None, None, 2), b"XYZ"))
check("b[1:3] = [1,2]", lambda: setitem(slice(1, 3), [1, 2]))
check("b[1:3] = bytearray", lambda: setitem(slice(1, 3), B(b"QQ")))
check("b[0] = 256", lambda: setitem(0, 256))
check("b[0] = -1", lambda: setitem(0, -1))
check("b[0] = b'x'", lambda: setitem(0, b"x"))
check("b[9] = 65", lambda: setitem(9, 65))
check("b[::2] = wrong len", lambda: setitem(slice(None, None, 2), b"XY"))
check("del b[0]", lambda: delitem(0))
check("del b[1:3]", lambda: delitem(slice(1, 3)))
check("del b[::2]", lambda: delitem(slice(None, None, 2)))
check("b[:] = itself", lambda: (lambda a: (a.__setitem__(slice(None), a), bytes(a))[1])(B(b"abc")))

print()
print("--- growth: append, extend, insert, +=  ---")


def iadd(v):
    a = B(b"abcdef")
    a += v
    return bytes(a)


def imul(n):
    a = B(b"abcdef")
    a *= n
    return bytes(a)


check("append", lambda: mut(lambda a: a.append(88)))
check("append 256", lambda: mut(lambda a: a.append(256)))
check("extend bytes", lambda: mut(lambda a: a.extend(b"XY")))
check("extend list", lambda: mut(lambda a: a.extend([88, 89])))
check("extend bytearray", lambda: mut(lambda a: a.extend(B(b"ZZ"))))
check("extend range", lambda: mut(lambda a: a.extend(range(65, 68))))
check("insert", lambda: mut(lambda a: a.insert(1, 88)))
check("insert at end", lambda: mut(lambda a: a.insert(99, 88)))
check("+= bytes", lambda: iadd(b"XY"))
check("+= bytearray", lambda: iadd(B(b"XY")))
check("*= 2", lambda: imul(2))
check("pop", lambda: mut(lambda a: a.pop()))
check("pop(0)", lambda: mut(lambda a: a.pop(0)))
check("pop empty", lambda: B().pop())
check("remove", lambda: mut(lambda a: a.remove(98)))
check("remove missing", lambda: mut(lambda a: a.remove(200)))
check("clear", lambda: mut(lambda a: a.clear()))
check("reverse", lambda: mut(lambda a: a.reverse()))
check("copy", lambda: bytes(B(b"abc").copy()))
check("copy is a bytearray", lambda: type(B(b"abc").copy()).__name__)


def grow(n):
    a = B()
    for i in range(n):
        a.append(i & 0xFF)
    return len(a), bytes(a[:4]), bytes(a[-4:])


check("grow to 1000", lambda: grow(1000))
check("grow to 5000", lambda: grow(5000))


def grow_extend(n):
    a = B()
    for _ in range(n):
        a.extend(b"0123456789")
    return len(a), bytes(a[:5])


check("extend 500 times", lambda: grow_extend(500))

print()
print("--- concatenation and repetition produce new objects ---")
check("b + b", lambda: bytes(B(b"ab") + B(b"cd")))
check("b + bytes", lambda: bytes(B(b"ab") + b"cd"))
check("bytes + b", lambda: bytes(b"ab" + B(b"cd")))
check("b * 3", lambda: bytes(B(b"ab") * 3))
check("3 * b", lambda: bytes(3 * B(b"ab")))
check("b * 0", lambda: bytes(B(b"ab") * 0))
check("b + str", lambda: B(b"ab") + "cd")

print()
print("--- the read-only methods bytes already had ---")
# Only the ones bytes itself implements.  bytes has no rfind, index, rindex,
# rsplit, splitlines, strip, partition, the case methods, the justify
# methods, zfill, expandtabs, translate or the is* predicates, so neither
# does bytearray -- recorded in the old bug list as one gap covering both types.
c = B(b"Hello World")
check("find", lambda: (c.find(b"World"), c.find(b"zzz")))
check("find int", lambda: B(b"abc").find(98))
check("find with start", lambda: B(b"abcabc").find(b"b", 2))
check("find with start and end", lambda: B(b"abcabc").find(b"b", 0, 3))
check("find past the end", lambda: B(b"abc").find(b"a", 5))
check("find empty", lambda: B(b"abc").find(b"", 2))
check("count", lambda: (B(b"aaa").count(b"a"), B(b"aaa").count(97)))
check("startswith", lambda: (c.startswith(b"Hello"), c.startswith(b"x")))
check("endswith", lambda: (c.endswith(b"World"), c.endswith(b"x")))
check("split", lambda: [bytes(x) for x in c.split()])
check("split sep", lambda: [bytes(x) for x in B(b"a,b,c").split(b",")])
check("split element type", lambda: type(B(b"a b").split()[0]).__name__)
check("join", lambda: bytes(B(b",").join([b"a", b"b"])))
check("join returns bytearray", lambda: type(B(b",").join([b"a"])).__name__)
check("replace", lambda: bytes(c.replace(b"World", b"there")))
check("replace type", lambda: type(c.replace(b"o", b"0")).__name__)
check("hex", lambda: B(b"\x01\xff").hex())
check("decode", lambda: B(b"ab").decode())
check("decode utf-8", lambda: B(b"ab").decode("utf-8"))

print()
print("--- comparison and hashing ---")
check("== bytearray", lambda: B(b"ab") == B(b"ab"))
check("== bytes", lambda: B(b"ab") == b"ab")
check("bytes ==", lambda: b"ab" == B(b"ab"))
check("!=", lambda: B(b"ab") != B(b"ac"))
check("<", lambda: B(b"ab") < B(b"b"))
check("sorted", lambda: [bytes(x) for x in sorted([B(b"b"), B(b"a")])])
check("hash", lambda: hash(B(b"ab")))
check("as a dict key", lambda: {B(b"ab"): 1})

print()
print("--- the shape CPython's regex compiler uses ---")
# _optimize_charset: bytearray(256), charmap[ord] = 1, then find(1, q).
charmap = bytearray(256)
for ch in b"abc":
    charmap[ch] = 1
print("set bits     :", [i for i, v in enumerate(charmap) if v])
print("find(1)      :", charmap.find(1))
print("find(1, 98)  :", charmap.find(1, 98))
print("find(1, 200) :", charmap.find(1, 200))
charmap += b"\x00" * 16
print("after +=     :", len(charmap))
print("as bytes     :", bytes(charmap)[97:100])
data = bytearray()
data += b"\x01\x02"
data[0:0] = b"\x09"
print("prepended    :", bytes(data))

print()
print("--- churn, since every buffer is a separate allocation ---")
kept = [B(bytes([i & 0xFF]) * (i + 1)) for i in range(60)]
for a in kept:
    a.extend(b"tail")
print("churn        :", len([[i, i] for i in range(3000)]))
print("lengths      :", [len(kept[i]) for i in (0, 1, 30, 59)])
print("tails        :", bytes(kept[7][-4:]), bytes(kept[59][-4:]))
print("heads        :", bytes(kept[7][:2]))

print()
print("--- an empty right-hand side deletes an extended slice ---")
# b[::2] = b'' removes those positions, where a length mismatch would raise.
# CPython's bytearray_ass_subscript special-cases needed == 0 in the extended
# branch; here only a NULL value counted as a delete, so every one of these
# was "attempt to assign bytes of size 0 to extended slice of size 2".  This
# is bytearray's alone -- L[::2] = [] raises in CPython too, and still does.
for label, code in (
        ("b[::2]   = b''", "b[::2] = b''"),
        ("b[1::2]  = b''", "b[1::2] = b''"),
        ("b[::3]   = b''", "b[::3] = b''"),
        ("b[::-1]  = b''", "b[::-1] = b''"),
        ("b[::-2]  = b''", "b[::-2] = b''"),
        ("b[1:1:2] = b''", "b[1:1:2] = b''"),
        ("b[::2]   = bytearray()", "b[::2] = bytearray()"),
        ("b[::2]   = b'xy'", "b[::2] = b'xy'"),
        ("b[::2]   = b'x'", "b[::2] = b'x'"),
        ("del b[::2]", "del b[::2]"),
):
    b = bytearray(b"abcd")
    try:
        exec(code)
        print("%-22s -> %r" % (label, bytes(b)))
    except Exception as e:
        print("%-22s -> %s: %s" % (label, type(e).__name__, e))

# The memoryview guard still refuses a compaction under an export.
b = bytearray(b"abcd")
mv = memoryview(b)
try:
    b[::2] = b""
    print("exported     : no error")
except BufferError as e:
    print("exported     : BufferError")
del mv

# A list is unchanged: it raises for the same assignment in both.
l = [1, 2, 3, 4]
try:
    l[::2] = []
    print("list         :", l)
except ValueError as e:
    print("list         : ValueError:", e)

