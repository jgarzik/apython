"""The regressions a second review found in the first review's fixes.

Every one of these was introduced by a commit that was itself fixing
something, which is the point of the file: a fix is not finished until the
shape it introduces has been looked for too.

  * DUNDER_RAISED asks "did current_exception change", and call_iternext
    CLEARS it to swallow a StopIteration -- so list(it)/tuple(it) inside an
    except block saw a change, called it a raise, and returned NULL.
  * bytes % latin-1 decoded its arguments but not the FORMAT, so the two
    halves of the round trip disagreed and the re-encode ran off the end of
    the allocation.
  * startswith/endswith went through bytes_like_ptr_len, which declines a
    tuple -- turning the documented `data.startswith((b'PK', b'\\x1f\\x8b'))`
    into a TypeError.
  * memoryview.cast() is a fourth place a view takes a share of another's
    source, and only three of them acquired a BytesIO export.
  * BytesIO.__init__ held nargs in a caller-saved register across ap_free.
  * format() of a wide int subclass boxed a value nothing released.
  * decode() reached for PyStrObject.data on a non-str errors=.
"""

import io
import posix
import _io


def check(label, fn):
    try:
        got = fn()
    except Exception as exc:
        got = type(exc).__name__ + ": " + str(exc)
    print(label.ljust(36), repr(got))


def check_type(label, fn):
    """Like check(), but names only the exception's class.

    For the cases where the finding was a segfault and the wording of the
    replacement message is not what is being pinned down.
    """
    try:
        got = repr(fn())
    except Exception as exc:
        got = type(exc).__name__
    print(label.ljust(36), got)


# --- list()/tuple() of a Python iterator, inside a handler ---
class Counter:
    def __init__(self):
        self.i = 0

    def __iter__(self):
        return self

    def __next__(self):
        self.i += 1
        if self.i > 3:
            raise StopIteration
        return self.i


def in_handler(fn):
    try:
        raise ValueError("being handled")
    except ValueError:
        return fn()


check("list outside", lambda: list(Counter()))
check("list inside", lambda: in_handler(lambda: list(Counter())))
check("tuple inside", lambda: in_handler(lambda: tuple(Counter())))
check("set inside", lambda: in_handler(lambda: sorted(set(Counter()))))
check("sorted inside", lambda: in_handler(lambda: sorted(Counter())))
check("nested handler", lambda: in_handler(lambda: in_handler(
    lambda: list(Counter()))))
check("the handler still works", lambda: in_handler(lambda: "reached"))


class RaisingNext:
    def __iter__(self):
        return self

    def __next__(self):
        raise KeyError("from __next__")


check("a real raise propagates", lambda: list(RaisingNext()))
check("and inside a handler too", lambda: in_handler(
    lambda: list(RaisingNext())))


# --- bytes % with a format that has high bytes ---
check("high byte format", lambda: b"\xc3\xa9%s" % (b"a",))
check("three-byte format", lambda: b"\xe4\xb8\xad%s" % (b"a",))
check("no directives", lambda: b"\x80\x81\x82" % ())
check("0xff and an arg", lambda: b"\xff%s" % (b"a",))
check("a long one", lambda: len((b"\xe4\xb8\xad" * 40) % ()))
check("a wide str argument", lambda: b"%s" % ("中" * 3,))
check("an ascii str argument", lambda: b"%r" % ("x",))
check("the ordinary cases", lambda: (b"%d" % 5, b"%s" % (b"x",), b"%%" % ()))


# --- startswith / endswith with a tuple ---
check("startswith a tuple", lambda: b"abc".startswith((b"x", b"a")))
check("startswith no match", lambda: b"abc".startswith((b"x", b"y")))
check("startswith empty tuple", lambda: b"abc".startswith(()))
check("endswith a tuple", lambda: b"abc".endswith((b"z", b"bc")))
check("a bytearray in the tuple", lambda: b"abc".startswith((bytearray(b"a"),)))
check("on a bytearray", lambda: bytearray(b"abc").startswith((b"z", b"ab")))
check("a str in the tuple", lambda: b"abc".endswith((b"z", "c")))
check("a bare str", lambda: b"abc".startswith("a"))
check("still takes one affix", lambda: (b"abc".startswith(b"a"),
                                        b"abc".endswith(b"c")))


# --- memoryview.cast() and the BytesIO export count ---
b = _io.BytesIO(b"abcdefgh")
whole = b.getbuffer()
cast = whole.cast("B")
del whole
check("write while a cast view lives", lambda: b.write(b"x"))
check("the cast view still reads", lambda: bytes(cast))
del cast
check("write once it is gone", lambda: (b.write(b"!"), b.getvalue()[:4]))


# --- __init__ called again ---
r = io.BytesIO(b"abcdef")
check("BytesIO re-init, no args", lambda: (r.__init__(), r.getvalue()))
check("BytesIO re-init, an arg", lambda: (r.__init__(b"xy"), r.getvalue()))
TMP = "/tmp/apython_review_regressions"
open(TMP, "wb").write(b"hello")
f = _io.FileIO(TMP, "rb")
check("FileIO re-init", lambda: (f.__init__(TMP, "rb"), f.read(5)))
f.close()


# --- format() of a wide int subclass ---
class I(int):
    pass


wide = 1125899906842623 * 2
check("format a wide subclass", lambda: format(I(wide), "d"))
check("f-string of one", lambda: f"{I(wide):d}")
check("a narrow one", lambda: format(I(7), "03d"))
check("a bool", lambda: format(True, "d"))
for _ in range(20000):
    _ = format(I(wide), "d")
print("formatted 20000".ljust(36), repr(True))


# --- decode() with a bad errors= ---
for e in (5, None, [], b"x"):
    check("decode errors=%r" % (e,), lambda e=e: b"\xff".decode("utf-8", e))
check("decode errors ok", lambda: b"\xff".decode("utf-8", "replace"))
check("an unknown handler", lambda: b"\xff".decode("utf-8", "nosuch"))


# --- a truncated sequence is one subpart, not one per byte ---
for raw in (b"ab\xf0\x9f\x92cd", b"\xe2\x82x", b"\xc3(", b"\xf0\x9f"):
    check("replace %r" % raw, lambda raw=raw: raw.decode("utf-8", "replace"))
    check("strict %r" % raw, lambda raw=raw: raw.decode("utf-8"))


# --- maketrans by code point ---
check("maketrans wide", lambda: sorted(str.maketrans("ab", "áâ").items()))
check("applied", lambda: "abc".translate(str.maketrans("ab", "áâ")))
check("wide keys", lambda: "áéx".translate(str.maketrans("áé", "ab")))
check("with deletions", lambda: "abc".translate(str.maketrans("a", "x", "c")))
check("an out-of-range ordinal", lambda: "abc".translate({97: 0x110000}))


# --- posix integers are range-checked, and a PathLike is released ---
class P:
    def __init__(self, s):
        self._s = s

    def __fspath__(self):
        return "".join(self._s)


check("close a huge fd", lambda: posix.close(2 ** 64 + 3))
check("close a negative fd", lambda: posix.close(-1))
check("chmod with a bad mode", lambda: posix.chmod(P(TMP), "no"))
check("access with a bad mode", lambda: posix.access(P(TMP), "no"))
check("open with bad flags", lambda: posix.open(P(TMP), "no"))
check("and they still work", lambda: (posix.access(P(TMP), 0),
                                      posix.stat(P(TMP)).st_size))

# --- a struct sequence built from a raising iterator ---
def raises_late():
    yield 1
    yield 2
    raise ValueError("late")


def raises_early():
    raise KeyError("early")
    yield 1


check("raising after the count", lambda: posix.terminal_size(raises_late()))
check("raising before it", lambda: posix.terminal_size(raises_early()))
check("a good one", lambda: posix.terminal_size((80, 24)))

posix.unlink(TMP)
print("cleaned")


# ---------------------------------------------------------------------------
# A register a call destroyed, and a frame slot nothing initialised.
#
# Seven crashes, six of them SIGSEGV.  The shape behind most of them is one
# value left in a caller-saved register across a call that does not preserve
# it -- r8 through tp_getattr, r8 through bytearray_resize, rdi through
# dunder_call_1, a double parked in the red zone under a call that writes its
# own return address there.
# ---------------------------------------------------------------------------

# LOAD_ATTR on an immediate whose tp_getattr declines: .la_resolve_tag_dict
# walked r8, which the tp_getattr call had already clobbered.
check("attr miss on an int", lambda: getattr(5, "numeratorZ", "absent"))
check_type("attr miss raises", lambda: (5).numeratorZ)


# bytearray slice assignment that grows: the removed span's width was the one
# value in the stretch not spilled around bytearray_resize/bytearray_data.
def ba_grow_big():
    b = bytearray(b"0123456789")
    b[2:5] = b"Y" * 30
    return bytes(b)


def ba_grow_small():
    b = bytearray(b"abcdef")
    b[1:3] = b"X" * 40
    return bytes(b)


def ba_shrink():
    b = bytearray(b"0123456789")
    b[2:8] = b"Z"
    return bytes(b)


check("bytearray slice grows", ba_grow_big)
check("bytearray slice grows more", ba_grow_small)
check("bytearray slice shrinks", ba_shrink)


# posix.fspath: .pfs_bad read rdi back after dunder_call_1 had destroyed it,
# and reported a raising __fspath__ as a bad path type rather than letting the
# real exception out.
class FsRaises:
    def __fspath__(self):
        raise ValueError("boom")


class FsBadType:
    def __fspath__(self):
        return 42


class FsGood:
    def __fspath__(self):
        return "/tmp"


check("fspath that raises", lambda: posix.fspath(FsRaises()))
check("fspath answering an int", lambda: posix.fspath(FsBadType()))
check("fspath that works", lambda: posix.fspath(FsGood()))
check("fspath of a str", lambda: posix.fspath("/tmp"))
check("fspath of an int", lambda: posix.fspath(42))

# __import__() with no arguments at all: BIM_NAME was the one slot the
# prologue did not zero, so the "was a name given" test read stack garbage.
check_type("__import__ with no name", lambda: __import__())
check("__import__ still works", lambda: __import__("posix").__name__)


# A metaclass that is not a type.  The most-derived-metaclass scan handed the
# function to type_is_subtype, which read tp_mro off it; and once that no
# longer crashed, the callable was still never called.
def meta_fn(name, bases, ns):
    return 42


def build_with_fn_meta():
    class D(object, metaclass=meta_fn):
        pass
    return D


def build_with_fn_meta_nobase():
    class E(metaclass=meta_fn):
        pass
    return E


check("function as metaclass", build_with_fn_meta)
check("function metaclass, no base", build_with_fn_meta_nobase)


# UNPACK_SEQUENCE over an iterable whose iteration raises: tuple_type_call
# answers NULL there, and the generic arm read ob_type off it.
class GetitemRaises:
    def __getitem__(self, i):
        if i == 2:
            raise ValueError("late")
        return i


def unpack_raising():
    a, b, c = GetitemRaises()
    return (a, b, c)


def unpack_ok():
    a, b, c = range(3)
    return (a, b, c)


check("unpack a raising __getitem__", unpack_raising)
check("unpack a good one", unpack_ok)


# int.__truediv__ with a GMP-backed operand: the left double was saved in the
# red zone, and __gmpz_get_d's own return address landed on the same slot.
check("1 / 2**70", lambda: 1 / (2 ** 70))
check("2**70 / 2**70", lambda: (2 ** 70) / (2 ** 70))
check("2**70 / 2", lambda: (2 ** 70) / 2)
check("-(2**70) / 2**69", lambda: -(2 ** 70) / (2 ** 69))


# ---------------------------------------------------------------------------
# Sizes nothing checked: a re-encode past the allocation, an addition that
# wrapped, and a repeat count taken on trust.
# ---------------------------------------------------------------------------

# bytes %-formatting decodes its argument through latin-1 and re-encodes it,
# which only survives for ASCII.  The guard that refuses a wide str compared
# the type pointer, so a subclass walked past it into the overflow.
class WideStr(str):
    pass


check("b'%s' % a wide str subclass", lambda: b"%s" % (WideStr("\u4e2d" * 20),))
check("b'%s' % a wide str", lambda: b"%s" % ("\u4e2d" * 20,))
check("b'%s' % an ASCII str subclass", lambda: b"%r" % (WideStr("ab"),))
check("b'%s' % bytes still works", lambda: b"%s" % (b"xy",))

# BytesIO: cursor + length overflowed to negative, bytesio_reserve read that
# as "big enough", and the gap-fill ran rep stosb with rcx near 2**63.
def bytesio_far_seek():
    b = io.BytesIO()
    b.seek(2 ** 63 - 1)
    b.write(b"x")
    return b.tell()


def bytesio_ordinary_gap():
    b = io.BytesIO(b"ab")
    b.seek(6)
    b.write(b"z")
    return b.getvalue()


check("BytesIO write past 2**63", bytesio_far_seek)
check("BytesIO write past the end", bytesio_ordinary_gap)

# bytearray repeat had none of the guards bytes and list repeat both have.
check_type("bytearray * 2**70", lambda: bytearray(b"x") * (2 ** 70))
check_type("bytearray * 2**40", lambda: bytearray(b"xy") * (2 ** 40))
check("bytearray * a str", lambda: bytearray(b"x") * "3")
check("bytearray * a float", lambda: bytearray(b"x") * 2.0)
check("bytearray * 3", lambda: bytes(bytearray(b"ab") * 3))
check("bytearray * 0", lambda: bytes(bytearray(b"ab") * 0))
check("bytearray * -1", lambda: bytes(bytearray(b"ab") * -1))
check("bytearray * True", lambda: bytes(bytearray(b"ab") * True))


# ---------------------------------------------------------------------------
# tp_iternext answers NULL for a clean exhaustion and for a __next__ that
# raised, and the two are told apart only by the pending exception.  eb7cdce
# enabled the legacy __getitem__ protocol, which put arbitrary Python inside
# every one of these loops; eleven consumers were reading NULL as the end.
# ---------------------------------------------------------------------------

class RaisingSeq:
    """The legacy protocol: iterable through __getitem__, and it throws."""

    def __getitem__(self, i):
        if i == 2:
            raise ValueError("late")
        return i


def raising_gen():
    yield 0
    yield 0
    raise ValueError("late")


class RaisingIter:
    def __iter__(self):
        return self

    def __next__(self):
        raise ValueError("nxt")


def do_extend(it):
    L = [9]
    L.extend(it)
    return L


def do_iadd(it):
    L = [9]
    L += it
    return L


def do_setupdate(it):
    s = {9}
    s.update(it)
    return s


def do_unpack_ex(it):
    a, *b = it
    return (a, b)


def do_slice_assign(it):
    L = [9]
    L[0:1] = it
    return L


for _label, _mk in (("getitem", RaisingSeq), ("generator", raising_gen)):
    check(_label + ": list()", lambda mk=_mk: list(mk()))
    check(_label + ": tuple()", lambda mk=_mk: tuple(mk()))
    check(_label + ": [*it]", lambda mk=_mk: [*mk()])
    check(_label + ": {*it}", lambda mk=_mk: {*mk()})
    check(_label + ": set()", lambda mk=_mk: set(mk()))
    check(_label + ": frozenset()", lambda mk=_mk: frozenset(mk()))
    check(_label + ": L.extend()", lambda mk=_mk: do_extend(mk()))
    check(_label + ": L += it", lambda mk=_mk: do_iadd(mk()))
    check(_label + ": L[0:1] = it", lambda mk=_mk: do_slice_assign(mk()))
    check(_label + ": a, *b = it", lambda mk=_mk: do_unpack_ex(mk()))
    check(_label + ": s.update()", lambda mk=_mk: do_setupdate(mk()))
    check(_label + ": dict.fromkeys()", lambda mk=_mk: dict.fromkeys(mk()))
    check(_label + ": 99 in it", lambda mk=_mk: 99 in mk())
    check(_label + ": any()", lambda mk=_mk: any(mk()))
    check(_label + ": all()", lambda mk=_mk: all(x or True for x in mk()))
    check(_label + ": sum()", lambda mk=_mk: sum(mk()))
    check(_label + ": sorted()", lambda mk=_mk: sorted(mk()))
    check(_label + ": for loop", lambda mk=_mk: [x for x in mk()])
    check(_label + ": zip()", lambda mk=_mk: list(zip(mk(), "abcd")))
    check(_label + ": map()", lambda mk=_mk: list(map(str, mk())))
    check(_label + ": filter()", lambda mk=_mk: list(filter(None, mk())))
    check(_label + ": enumerate()", lambda mk=_mk: list(enumerate(mk())))

class GoodSeq:
    def __getitem__(self, i):
        if i > 3:
            raise IndexError(i)
        return i


# next() with and without a default: the default form cleared whatever was
# pending, the bare form manufactured a StopIteration over it.
check("next(it) that raises", lambda: next(RaisingIter()))
check("next(it, default) that raises", lambda: next(RaisingIter(), "dflt"))
check("next(it, default) exhausted", lambda: next(iter([]), "dflt"))
check("next(it) exhausted", lambda: next(iter([])))
check("next(it) ordinary", lambda: next(iter([7])))


# sorted() discarded list.sort()'s return, so a comparison or a key that
# raised produced a half-sorted list where L.sort() correctly raised.
class Unorderable:
    def __lt__(self, other):
        raise ValueError("cmp")

    def __gt__(self, other):
        raise ValueError("cmp")

    def __repr__(self):
        return "<U>"


def key_raises(x):
    raise ValueError("key")


def sort_in_place():
    L = [Unorderable(), Unorderable()]
    L.sort()
    return L


check("sorted, raising __lt__", lambda: sorted([Unorderable(), Unorderable()]))
check("list.sort, raising __lt__", sort_in_place)
check("sorted, raising key", lambda: sorted([1, 2], key=key_raises))
check("sorted still sorts", lambda: sorted([3, 1, 2]))
check("sorted with a key", lambda: sorted([3, 1, 2], key=lambda x: -x))
check("sorted reversed", lambda: sorted([3, 1, 2], reverse=True))


# The same iterables, not raising: none of the guards may cost a correct answer.
check("list of a good getitem", lambda: list(GoodSeq()))
check("set of a good getitem", lambda: sorted(set(GoodSeq())))
check("in over a good getitem", lambda: 2 in GoodSeq())


# ---------------------------------------------------------------------------
# Exceptions that went nowhere, and allocations that went with them.  Each of
# these raises from a point that holds an owned reference, or swallows a call
# that failed and answers from what it had.
# ---------------------------------------------------------------------------

# oserror_str never checked the four repr()/str() calls it makes on the
# exception's own fields, so a filename with a raising __repr__ produced a
# truncated message and left the exception to fire somewhere unrelated.
class ReprRaises:
    def __repr__(self):
        raise ValueError("repr")


check("OSError str, raising repr",
      lambda: str(OSError(2, "No such file", ReprRaises())))
check("OSError str, one name", lambda: str(OSError(2, "No such file", "/x")))
check("OSError str, two names", lambda: str(OSError(2, "msg", "/a", None, "/b")))
check("OSError str, no filename", lambda: str(OSError(2, "msg")))


# str.translate: a table that is a user class was asked through its
# mp_subscript slot, and a slot that raises never comes back -- so CPython's
# rule that a LookupError means "leave the character alone" could not be
# applied.  A dict subclass was not asked at all.
class TableLookupError:
    def __getitem__(self, k):
        raise LookupError(k)


class TableValueError:
    def __getitem__(self, k):
        raise ValueError("tbl")


class TableGood:
    def __getitem__(self, k):
        return "X" if k == 97 else None


class DictLookupError(dict):
    def __getitem__(self, k):
        raise LookupError(k)


class DictSubst(dict):
    def __getitem__(self, k):
        if k == 97:
            return "Z"
        raise KeyError(k)


check("translate, LookupError table", lambda: "abc".translate(TableLookupError()))
check("translate, ValueError table", lambda: "abc".translate(TableValueError()))
check("translate, mapping table", lambda: "abc".translate(TableGood()))
check("translate, dict subclass miss", lambda: "abc".translate(DictLookupError()))
check("translate, dict subclass hit", lambda: "abc".translate(DictSubst()))
check("translate, plain dict", lambda: "abc".translate({97: "X", 98: None}))
check("translate, out of range", lambda: "abc".translate({97: 0x110000}))
check("translate, bad value", lambda: "abc".translate({97: 1.5}))
check("translate, str.maketrans", lambda: "abc".translate(str.maketrans("ab", "xy")))


# An extended-slice length mismatch raised while still holding the temp list
# it had materialised the right-hand side into.
def ext_slice_mismatch():
    L = [1, 2, 3, 4]
    L[::2] = (x for x in (9, 9, 9))
    return L


def ext_slice_ok():
    L = [1, 2, 3, 4]
    L[::2] = (x for x in (9, 9))
    return L


check_type("extended slice mismatch", ext_slice_mismatch)
check("extended slice, right size", ext_slice_ok)


# FileIO: closefd was read only as a fourth positional, so closefd=False on a
# path silently cleared the bit and leaked a descriptor where CPython raises,
# and FileIO(path, closefd=False) read False as the mode.
def fileio_fd_closefd():
    fd = posix.open("/etc/hostname", 0)
    f = _io.FileIO(fd, "r", False)
    f.close()
    posix.close(fd)
    return "reused the fd"


check("FileIO path, closefd=False", lambda: _io.FileIO("/etc/hostname", "r", False))
check("FileIO path, closefd kwarg", lambda: _io.FileIO("/etc/hostname", closefd=False))
check("FileIO fd, closefd=False", fileio_fd_closefd)
check("FileIO path reads", lambda: len(_io.FileIO("/etc/hostname", "r").readall()) > 0)


# Container subclasses keep their storage out of line, and instance_dealloc
# never ran the base's dealloc for them -- so every instance leaked its tables
# AND everything in them.  The leak itself is a valgrind result; what is
# checkable here is that releasing them still releases the contents exactly
# once, which is what a double free or an early free would break.
class DictSub(dict):
    pass


class ListSub(list):
    pass


class SetSub(set):
    pass


class Tracked:
    live = 0

    def __init__(self):
        Tracked.live += 1

    def __del__(self):
        Tracked.live -= 1


def container_subclass_roundtrip():
    out = []
    for cls, fill in ((DictSub, lambda c: c.update({"a": Tracked(), "b": Tracked()})),
                      (ListSub, lambda c: c.extend([Tracked(), Tracked()])),
                      (SetSub, lambda c: c.update({1, 2, 3}))):
        for _ in range(20):
            c = cls()
            fill(c)
            out.append(len(c))
        del c
    return (out[0], out[20], out[40], Tracked.live)


check("container subclass lifetime", container_subclass_roundtrip)
check("dict subclass still maps", lambda: sorted(DictSub({"x": 1, "y": 2}).items()))
check("list subclass still lists", lambda: list(ListSub([3, 1, 2])))
check("set subclass still sets", lambda: sorted(SetSub({3, 1, 2})))


# ---------------------------------------------------------------------------
# Numbers and comparisons: paths that decided what a value was from its tag,
# or from an exact type-pointer match, and were wrong for everything else.
# ---------------------------------------------------------------------------

class FloatSub(float):
    pass


class IntSub(int):
    pass


class Declines:
    def __add__(self, other):
        return NotImplemented


class Reflects:
    def __radd__(self, other):
        return "radd"


class Roundable:
    def __round__(self, ndigits=None):
        return "rounded"


# The inplace->non-inplace fallback coerced to float's slots on a bare tag
# test.  complex_number_methods leaves every nb_inplace_* NULL, so every
# complex/float augmented assignment landed there and came out a TypeError.
def complex_iadd():
    z = 1 + 2j
    z += 1.5
    return z


def complex_isub():
    z = 1 + 2j
    z -= 1.5
    return z


def complex_imul():
    z = 1 + 2j
    z *= 2.0
    return z


def complex_item_iadd():
    L = [1 + 2j]
    L[0] += 1.5
    return L[0]


check("z += 1.5", complex_iadd)
check("z -= 1.5", complex_isub)
check("z *= 2.0", complex_imul)
check("z + 1.5, for comparison", lambda: (1 + 2j) + 1.5)
check("L[0] += 1.5", complex_item_iadd)


# The sort merge resolved tp_richcompare from the right element only, with no
# reflected retry, so which way round two comparable values fell decided
# whether sorting them raised.
check("sorted([F(3.5), 1])", lambda: sorted([FloatSub(3.5), 1]))
check("sorted([2.5, F(3.5)])", lambda: sorted([2.5, FloatSub(3.5)]))
check("sorted([I(3), 1])", lambda: sorted([IntSub(3), 1]))
check("sorted, four kinds", lambda: sorted([3, FloatSub(1.5), 2, IntSub(0)]))
check("sorted, reverse", lambda: sorted([FloatSub(3.5), 1], reverse=True))


# pow() had a hand-rolled float path testing ob_type == float_type exactly,
# and knew nothing of complex.  It goes through obj_binary_op now, which is
# what ** itself uses.
check("pow(F(2.0), 2)", lambda: pow(FloatSub(2.0), 2))
check("pow(2.0, 2)", lambda: pow(2.0, 2))
check("pow(1+2j, 2)", lambda: pow(1 + 2j, 2))
check("(1+2j) ** 2", lambda: (1 + 2j) ** 2)
check("pow(2, 10)", lambda: pow(2, 10))
check("pow(2, -1)", lambda: pow(2, -1))
check("pow(2, 3, 5)", lambda: pow(2, 3, 5))
check("pow(2, 100)", lambda: pow(2, 100))


# int's methods read their self straight out of the Value: an int subclass
# was measured as 0, and a float was read as a PyIntObject.
check("I(7).bit_length()", lambda: IntSub(7).bit_length())
check("(7).bit_length()", lambda: (7).bit_length())
check("I(2**70).bit_length()", lambda: IntSub(2 ** 70).bit_length())
check("(2**70).bit_length()", lambda: (2 ** 70).bit_length())
check("int.bit_length(1.5)", lambda: int.bit_length(1.5))
check("I(255).to_bytes", lambda: IntSub(255).to_bytes(2, "big"))


# round() tested for float by exact type and never asked for __round__.
check("round(F(2.5))", lambda: round(FloatSub(2.5)))
check("round(2.5)", lambda: round(2.5))
check("round(3.5)", lambda: round(3.5))
check("round(R())", lambda: round(Roundable()))
check("round(F(1.234), 2)", lambda: round(FloatSub(1.234), 2))
check("round(1.234, 2)", lambda: round(1.234, 2))
check("round(7)", lambda: round(7))


# A dunder answering NotImplemented is declining, not answering.
check("B() + C()", lambda: Declines() + Reflects())
# The message is the fixed string the old bug list recorded, not CPython's wording.
check_type("B() + B()", lambda: Declines() + Declines())


# cvttsd2si answers INT64_MIN for anything out of range and says nothing.
check("int(1e300)", lambda: int(1e300))
check("int(2.0**70)", lambda: int(2.0 ** 70))
check("int(-2.0**70)", lambda: int(-(2.0 ** 70)))
check("int(1e18)", lambda: int(1e18))
check("int(2.5)", lambda: int(2.5))
check("int(-2.5)", lambda: int(-2.5))
check("int(float('inf'))", lambda: int(float("inf")))


# ---------------------------------------------------------------------------
# Behaviour CPython has and this did not: a keyword accepted and dropped, a
# slot left at zero, a flag set and never read.
# ---------------------------------------------------------------------------

class BytesSub(bytes):
    pass


check("bytes subclass +", lambda: BytesSub(b"ab") + b"cd")
check("bytes subclass, on the right", lambda: b"cd" + BytesSub(b"ab"))
check("bytes subclass *", lambda: BytesSub(b"ab") * 2)
check("bytes subclass, result type", lambda: type(BytesSub(b"ab") + b"cd").__name__)
check("bytes + bytearray", lambda: b"ab" + bytearray(b"cd"))
check("plain bytes +", lambda: b"ab" + b"cd")

# generic_alias had tp_hash and tp_richcompare at 0 where union got both.
check("alias as a dict key", lambda: {list[int]: 1}[list[int]])
check("alias equality", lambda: (list[int] == list[int], list[int] == list[str]))
check("alias is ordered", lambda: list[int, str] == list[str, int])
check("alias vs a non-alias", lambda: (list[int] == 5, 5 == list[int]))
check("alias hash is stable", lambda: hash(list[int]) == hash(list[int]))
check("union as a dict key", lambda: {int | str: 1}[int | str])

# min/max never read kw_names_pending, so key= and default= were compared as
# ordinary positional operands.
check("min with key", lambda: min([1, -3, 2], key=abs))
check("max with key", lambda: max([1, -3, 2], key=abs))
check("min of args with key", lambda: min(1, -5, 3, key=abs))
check("min with default", lambda: min([], default="none"))
check("max with default", lambda: max([], default="none"))
check("min with key and default", lambda: min([], key=abs, default=-1))
check("min, key=None", lambda: min([3, 1, 2], key=None))
check("min plain", lambda: min([3, 1, 2]))
check("max of args", lambda: max(1, 5, 3))
check("min of empty", lambda: min([]))
check("max of empty", lambda: max([]))
check("default with args", lambda: min(1, 2, default=0))
check("min, raising key", lambda: min([1, 2], key=key_raises))
check("max, raising key", lambda: max([1, 2], key=key_raises))
check("min, key not callable", lambda: min([1, 2], key=5))

# bytes.split accepted maxsplit and ignored it, and sep=None was a TypeError.
check("bytes split, maxsplit", lambda: b"a,b,,c".split(b",", 1))
check("bytes split, no limit", lambda: b"a,b,,c".split(b","))
check("bytes split, maxsplit 0", lambda: b"a,b".split(b",", 0))
check("bytes split, maxsplit past", lambda: b"a,b,c".split(b",", 5))
check("bytes split, whitespace", lambda: b"a b  c".split())
check("bytes split, ws maxsplit", lambda: b"a b  c".split(None, 1))
check("bytearray split, maxsplit", lambda: bytearray(b"a,b,c").split(b",", 1))
check("str split, maxsplit", lambda: "a,b,,c".split(",", 1))

# A structseq's named-only tail stored a zero Value, which is also what
# "no such attribute" answers with.
check("structseq named tail", lambda: posix.terminal_size((80, 24)).columns)
check("structseq repr", lambda: repr(posix.terminal_size((80, 24))))

# stat: the _ns fields published tv_nsec alone, and follow_symlinks was
# accepted and dropped.  The old bug list recorded that symlinks cannot be created from
# here, so this checks the keyword on a regular file.
_ST = posix.stat("/etc/hostname")

check("st_mtime_ns is whole", lambda: _ST.st_mtime_ns // 10 ** 9 == int(_ST.st_mtime))
check("st_atime_ns is whole", lambda: _ST.st_atime_ns // 10 ** 9 == int(_ST.st_atime))
check("st_ctime_ns is whole", lambda: _ST.st_ctime_ns // 10 ** 9 == int(_ST.st_ctime))
check("st_mtime_ns is not tv_nsec", lambda: _ST.st_mtime_ns > 10 ** 18)
check("follow_symlinks=False",
      lambda: posix.stat("/etc/hostname", follow_symlinks=False).st_size == _ST.st_size)
check("follow_symlinks=True",
      lambda: posix.stat("/etc/hostname", follow_symlinks=True).st_size == _ST.st_size)


# FIO_APPENDING was set and never read: O_APPEND positions the writes, not
# the offset, so an explicit seek to the end is what makes tell() right.
_APP = "/tmp/apython_review_append"


def append_positions():
    with open(_APP, "w") as f:
        f.write("hello world")
    with open(_APP, "a") as f:
        at_open = f.tell()
    with open(_APP, "a+") as f:
        read_at_open = f.read()
        f.write("!")
    with open(_APP) as f:
        final = f.read()
    posix.unlink(_APP)
    return (at_open, read_at_open, final)


check("append mode positions", append_positions)


# _pack_cookie was called with four positional arguments, so need_eof was
# never set and seek(tell()) mis-decoded a pending carriage return.
_CR = "/tmp/apython_review_cr"


def seek_to_tell():
    with open(_CR, "wb") as f:
        f.write(b"line1\r\nline2\rline3")
    with open(_CR, newline=None) as f:
        f.read(6)
        pos = f.tell()
        rest = f.read()
        f.seek(pos)
        again = f.read()
    posix.unlink(_CR)
    return (rest, again == rest)


check("seek(tell()) over a CR", seek_to_tell)


# ---------------------------------------------------------------------------
# A memoryview over a bytearray holds a raw pointer into its buffer, and
# nothing stopped the bytearray from moving out from under it: the first case
# below did not merely read freed memory, it corrupted the heap outright
# ("malloc(): unaligned tcache chunk detected").  BytesIO already counted its
# live views; a bytearray now does too.
# ---------------------------------------------------------------------------

def view_then(mutate):
    def run():
        ba = bytearray(b"abcdef")
        m = memoryview(ba)
        mutate(ba)
        return m[0]
    return run


def _extend(ba):
    ba.extend(b"x" * 200)


def _append(ba):
    ba.append(1)


def _pop(ba):
    ba.pop()


def _delitem(ba):
    del ba[0]


def _slice_grow(ba):
    ba[0:1] = b"xyz"


def _slice_del(ba):
    del ba[::2]


def _clear(ba):
    ba.clear()


def _remove(ba):
    ba.remove(ord("a"))


def _imul(ba):
    ba *= 2


def _iadd(ba):
    ba += b"xyz"


check("extend under a view", view_then(_extend))
check("append under a view", view_then(_append))
check("pop under a view", view_then(_pop))
check("del b[0] under a view", view_then(_delitem))
check("slice grow under a view", view_then(_slice_grow))
check("del b[::2] under a view", view_then(_slice_del))
check("clear under a view", view_then(_clear))
check("remove under a view", view_then(_remove))
check("b *= 2 under a view", view_then(_imul))
check("b += x under a view", view_then(_iadd))


def write_through_stale_view():
    ba = bytearray(b"abcdef")
    m = memoryview(ba)
    try:
        ba.extend(b"x" * 200)
    except BufferError:
        pass
    m[0] = 90
    return bytes(ba[:2])


def slice_view_blocks():
    ba = bytearray(b"abcdef")
    m = memoryview(ba)[1:3]
    ba.extend(b"x" * 100)
    return m[0]


def released_view_allows():
    ba = bytearray(b"abc")
    m = memoryview(ba)
    m.release()
    ba.extend(b"x" * 100)
    return len(ba)


def dropped_view_allows():
    ba = bytearray(b"abc")
    m = memoryview(ba)
    del m
    ba.extend(b"x" * 100)
    return len(ba)


def same_length_is_fine():
    ba = bytearray(b"abcdef")
    m = memoryview(ba)
    ba[0:2] = b"XY"
    ba.reverse()
    return bytes(m)


def two_views():
    ba = bytearray(b"abc")
    m1 = memoryview(ba)
    m2 = memoryview(ba)
    m1.release()
    try:
        ba.extend(b"x")
        return "grew with one view still out"
    except BufferError:
        pass
    m2.release()
    ba.extend(b"x")
    return len(ba)


check("write through a stale view", write_through_stale_view)
check("a slice view blocks too", slice_view_blocks)
check("release, then grow", released_view_allows)
check("drop the view, then grow", dropped_view_allows)
check("same-length edits stay legal", same_length_is_fine)
check("two views, released in turn", two_views)
check("memoryview(bytes) untouched", lambda: (memoryview(b"abcdef")[0], len(memoryview(b"abc"))))
check("bytearray still grows", lambda: len(bytearray(b"ab") + bytearray(b"cd")))


# Reached while testing the above: the sequence fallback sent NB_INPLACE_ADD
# to sq_concat and NB_INPLACE_MULTIPLY to sq_repeat, so `ba += x` built a new
# object and rebound the name -- an alias never saw the change.
def inplace_is_in_place():
    c = bytearray(b"x")
    d = c
    c += b"y"
    c *= 2
    return (bytes(c), bytes(d), c is d)


check("bytearray += is in place", inplace_is_in_place)


# tuple joins the three containers above: tuple_sub_fill gives a subclass
# instance its own item array and INCREFs into it, and instance_dealloc
# released neither.
class TupleSub(tuple):
    pass


def tuple_subclass_lifetime():
    out = []
    for _ in range(20):
        t = TupleSub((Tracked(), Tracked(), "abc"))
        out.append(len(t))
    del t
    return (out[0], Tracked.live)


check("tuple subclass lifetime", tuple_subclass_lifetime)
check("empty tuple subclass", lambda: (len(TupleSub()), TupleSub()))
check("tuple subclass contents", lambda: tuple(TupleSub((1, 2, 3))))


# A str subclass as errors=: bytes_check_errors_type accepts one and then
# codec_error_id, one call later, refused it -- so the argument passed the
# type check and came back as "unknown error handler name".  The old bug list recorded
# that the ascii codec consults no handler at all, which is why these are all
# utf-8.
class ErrStr(str):
    pass


check("decode, subclass 'ignore'", lambda: b"a\xffb".decode("utf-8", ErrStr("ignore")))
check("decode, subclass 'replace'", lambda: b"a\xffb".decode("utf-8", ErrStr("replace")))
check("decode, subclass 'strict'", lambda: b"a\xffb".decode("utf-8", ErrStr("strict")))
check("decode, plain 'ignore'", lambda: b"a\xffb".decode("utf-8", "ignore"))
check("decode, subclass unknown", lambda: b"a\xffb".decode("utf-8", ErrStr("bogus")))
check("decode, errors= not a str", lambda: b"ab".decode("utf-8", 5))
