# Every way bytes() and bytearray() refuse their arguments.
#
# Both gather their source through one function, which used to jump out of
# the constructor from wherever the refusal was found -- with the list it had
# materialised, the buffer it had filled so far, and (for a subclass) nothing
# to tell type() that no instance was coming.  It returns now, and so do the
# constructors: the exception that arrives is the argument's own, and nothing
# the constructor built on the way is left alive.
import gc


class Boom(Exception):
    pass


class Tracked:
    live = 0

    def __init__(self, v=1):
        self.v = v
        Tracked.live += 1

    def __del__(self):
        Tracked.live -= 1

    def __index__(self):
        if self.v < 0:
            raise Boom("item index")
        return self.v


class IndexRaises:
    def __index__(self):
        raise Boom("index")


class IndexHuge:
    def __index__(self):
        return 2 ** 70


class IndexStr:
    def __index__(self):
        return "x"


class BytesRaises:
    def __bytes__(self):
        raise Boom("bytes")


class BytesInt:
    def __bytes__(self):
        return 5


class BufferRaises:
    def __buffer__(self, flags):
        raise Boom("buffer")


class IterRaises:
    def __iter__(self):
        raise Boom("iter")


def gen_raises():
    yield 1
    yield Tracked(2)
    raise Boom("gen")


class Sub(bytes):
    pass


class SubArray(bytearray):
    pass


def check(label, fn):
    try:
        r = fn()
    except Exception as e:
        print("%-34s %s: %s" % (label, type(e).__name__, e))
    else:
        if isinstance(r, (bytes, bytearray)):
            # not repr(): a bytearray subclass names itself in CPython's
            r = (type(r).__name__, bytes(r))
        print("%-34s %r" % (label, r))


def cases(ctor):
    return [
        ("index raises", lambda: ctor(IndexRaises())),
        ("index huge", lambda: ctor(IndexHuge())),
        ("int huge", lambda: ctor(2 ** 70)),
        ("negative", lambda: ctor(-1)),
        ("item raises", lambda: ctor([1, Tracked(3), Tracked(-1)])),
        ("item str", lambda: ctor([1, Tracked(3), "a"])),
        ("item 256", lambda: ctor([Tracked(3), 256])),
        ("item -1", lambda: ctor([Tracked(3), -1])),
        ("item 2**70", lambda: ctor([Tracked(3), 2 ** 70])),
        ("gen raises", lambda: ctor(gen_raises())),
        ("iter raises", lambda: ctor(IterRaises())),
        ("map raises", lambda: ctor(map(lambda x: 1 // x, [1, 0]))),
        ("str alone", lambda: ctor("abc")),
        ("str, int", lambda: ctor("abc", 5)),
        ("int, encoding", lambda: ctor(5, "utf-8")),
        ("bad codec", lambda: ctor("abc", "no-such-codec")),
        ("cannot encode", lambda: ctor("ሴ", "ascii")),
        ("four args", lambda: ctor("a", "b", "c", "d")),
        ("float", lambda: ctor(1.5)),
        ("none", lambda: ctor(None)),
        ("object", lambda: ctor(object())),
        ("buffer raises", lambda: ctor(BufferRaises())),
        ("ok list", lambda: ctor([65, Tracked(66)])),
        ("ok count", lambda: ctor(2)),
        ("ok empty", lambda: ctor()),
    ]


for name, ctor in (("bytes", bytes), ("Sub", Sub), ("bytearray", bytearray),
                   ("SubArray", SubArray)):
    for label, fn in cases(ctor):
        for _ in range(2):
            check("%s: %s" % (name, label), fn)
    gc.collect()
    print(name, "live", Tracked.live)

check("__bytes__ raises", lambda: bytes(BytesRaises()))
check("__bytes__ int", lambda: bytes(BytesInt()))
check("Sub __bytes__ int", lambda: Sub(BytesInt()))
check("index str", lambda: bytes(IndexStr()))

# The other callers of the same source: a bytearray's slice assignment,
# extend, += and `in`.
b = bytearray(b"abc")
check("b[0:1] = raises", lambda: b.__setitem__(slice(0, 1), gen_raises()))
check("b[0:1] = [256]", lambda: b.__setitem__(slice(0, 1), [256]))
check("b[0:1] = ['a']", lambda: b.__setitem__(slice(0, 1), ["a"]))
check("b.extend(raises)", lambda: b.extend(gen_raises()))
check("b.extend([1, 'a'])", lambda: b.extend([1, "a"]))
check("b += raises", lambda: b.__iadd__(IterRaises()))
check("str in b", lambda: "a" in b)
check("300 in b", lambda: 300 in b)
check("raises in b", lambda: IndexRaises() in b)
gc.collect()
print("live", Tracked.live)

# str(view, encoding) reads the view through bytes().
m = memoryview(b"abc")
check("str(view)", lambda: str(m, "ascii"))
m.release()
check("bytes(released view)", lambda: bytes(m))
