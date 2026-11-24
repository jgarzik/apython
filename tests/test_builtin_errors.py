# The error paths of the builtin functions: wrong counts, wrong types, bad
# keywords, and callbacks that raise.
#
# Each case runs 200 times with sys.getallocatedblocks() read before and
# after, and prints the exception's type and whether the count stayed put.
# A builtin that raises by jumping out of its own frame gets the exception
# right and leaves behind whatever that frame held; only the count shows it.
#
# Messages are not printed: the wording is tests/arity_probe.sh's business,
# and half of it differs from CPython's on purpose.
import gc
import io
import sys
import time
import types
import warnings


class Boom(Exception):
    pass


def boom(*a, **k):
    raise Boom("boom")


def attempt(fn):
    seen = "ok"
    for _ in range(200):
        try:
            fn()
        except BaseException as e:      # sys.exit() is one of the cases
            seen = type(e).__name__
    return seen


def check(name, fn):
    # Unmeasured first: the early calls fill freelists and caches, which is
    # growth that stops -- some of it only after several hundred calls.  A
    # leak does not stop.
    for _ in range(4):
        attempt(fn)
    gc.collect()
    before = sys.getallocatedblocks()
    seen = attempt(fn)
    gc.collect()
    after = sys.getallocatedblocks()
    print(name, seen, after - before < 50)


# --- str() -----------------------------------------------------------------
class StrSub(str):
    pass


check("str bad keyword", lambda: str(b"a", bogus=1))
check("str encoding int", lambda: str(b"a", 5))
check("str errors int", lambda: str(b"a", "utf-8", 5))
check("str errors only", lambda: str(b"abc", errors="strict"))
check("str errors only, not bytes", lambda: str(5, errors="strict"))
check("str decoding str", lambda: str("a", "utf-8"))
check("str four", lambda: str(1, 2, 3, 4))
check("str subclass errors int", lambda: StrSub(b"a", "utf-8", 5))
check("str.__new__ encoding int", lambda: str.__new__(str, b"a", 5))

# --- getattr, hasattr, setattr, delattr --------------------------------------
o = object()
check("getattr one", lambda: getattr(o))
check("getattr four", lambda: getattr(o, "a", 1, 2))
check("getattr name int", lambda: getattr(o, 1))
check("getattr missing", lambda: getattr(o, "zz"))
check("hasattr one", lambda: hasattr(o))
check("hasattr name int", lambda: hasattr(o, 1))
check("setattr two", lambda: setattr(o, "a"))
check("setattr name int", lambda: setattr(o, 1, 2))
check("setattr on int", lambda: setattr(5, "x", 2))
check("delattr one", lambda: delattr(o))
check("delattr name int", lambda: delattr(o, 1))
check("delattr on int", lambda: delattr(5, "x"))
check("object.__setattr__ short", lambda: o.__setattr__("x"))
check("object.__delattr__ name int", lambda: o.__delattr__(3))
check("object.__getattribute__ name int", lambda: o.__getattribute__(3))
check("object.__getattribute__ missing", lambda: o.__getattribute__("zz"))


class GetterRaises:
    @property
    def p(self):
        raise Boom()

    def __getattr__(self, name):
        raise Boom()




# A store that finds nothing to store into names neither .name nor .obj on
# the AttributeError; a read names both.
for label, fn in (("setattr", lambda: setattr(5, "x", 1)),
                  ("delattr", lambda: delattr(5, "x")),
                  ("getattr", lambda: getattr(5, "x"))):
    try:
        fn()
    except AttributeError as e:
        print(label, "AttributeError", e.name, e.obj)

check("getattr getter raises", lambda: getattr(GetterRaises(), "p", 1))
check("hasattr __getattr__ raises", lambda: hasattr(GetterRaises(), "q"))

# --- pow() -----------------------------------------------------------------
check("pow one", lambda: pow(1))
check("pow four", lambda: pow(1, 2, 3, 4))
check("pow float with modulus", lambda: pow(2.0, 2, 3))
check("pow zero modulus", lambda: pow(2, 3, 0))
check("pow not invertible", lambda: pow(2, -1, 4))
check("pow complex modulus", lambda: pow(1j, 2, 3))
check("pow big zero modulus", lambda: pow(10 ** 30, 10 ** 20, 0))
check("int.__pow__ zero modulus", lambda: (2).__pow__(3, 0))
check("pow str", lambda: pow("a", 2))


class PowRaises:
    def __pow__(self, other, mod=None):
        raise Boom()


check("pow three-argument __pow__ raises", lambda: pow(PowRaises(), 2, 3))

# --- isinstance, issubclass ---------------------------------------------------
class ClassRaises:
    @property
    def __class__(self):
        raise Boom()


class NoAttributes:
    def __getattribute__(self, name):
        raise AttributeError(name)


class HookMeta(type):
    def __instancecheck__(cls, obj):
        raise Boom()

    def __subclasscheck__(cls, sub):
        raise Boom()


class Hooked(metaclass=HookMeta):
    pass


# A module with a PEP 562 __getattr__ is asked for __class__ through the
# hook, which raises AttributeError, before its type answers.  isinstance()
# must not take the hook's exception for a failure of its own: unittest's
# loader calls it on every name in a test module, `unittest` among them.
def module_hook(name):
    raise AttributeError(name)


hooked = types.ModuleType("hooked")
hooked.__getattr__ = module_hook
print("hooked module", isinstance(hooked, int), isinstance(hooked, (str, int)),
      isinstance(hooked, types.ModuleType), hasattr(hooked, "__class__"),
      getattr(hooked, "__class__", None) is types.ModuleType,
      isinstance(hooked, int))
check("isinstance hooked module", lambda: isinstance(hooked, int))
check("getattr hooked module", lambda: getattr(hooked, "__class__"))
check("getattr hooked module, missing", lambda: getattr(hooked, "zz"))

check("isinstance one", lambda: isinstance(1))
check("isinstance arg 2 int", lambda: isinstance(1, 1))
check("isinstance tuple with int", lambda: isinstance(1, (str, 1)))
check("isinstance nested generic", lambda: isinstance(1, (str, (bytes, (list[int],)))))
check("isinstance generic", lambda: isinstance(1, list[int]))
check("isinstance __class__ raises", lambda: isinstance(ClassRaises(), int))
check("isinstance __class__ raises, tuple", lambda: isinstance(ClassRaises(), (str, int)))
check("isinstance no __class__", lambda: isinstance(NoAttributes(), int))
check("isinstance hook raises", lambda: isinstance(1, Hooked))
check("isinstance hook raises, tuple", lambda: isinstance(1, (str, Hooked)))
check("issubclass one", lambda: issubclass(int))
check("issubclass arg 1 int", lambda: issubclass(1, int))
check("issubclass arg 2 int", lambda: issubclass(int, 1))
check("issubclass tuple with int", lambda: issubclass(int, (str, 1)))
check("issubclass generic", lambda: issubclass(int, list[int]))
check("issubclass hook raises", lambda: issubclass(int, Hooked))
check("issubclass hook raises, tuple", lambda: issubclass(int, (str, Hooked)))
check("type.__instancecheck__ __class__ raises",
      lambda: type.__instancecheck__(int, ClassRaises()))


# super(C, proxy).name asks the proxy for its __class__.  One that raised
# released the three operands twice, and the third call freed super_type.
class SuperUser:
    def attr(self):
        return super(int, ClassRaises()).real

    def call(self):
        return super(int, ClassRaises()).bit_length()

    def built(self):
        s = super
        return s(int, ClassRaises())


check("super attr, __class__ raises", lambda: SuperUser().attr())
check("super method, __class__ raises", lambda: SuperUser().call())
check("super object, __class__ raises", lambda: SuperUser().built())

# --- len, range, repr, bool, float --------------------------------------------
class LenRaises:
    def __len__(self):
        raise Boom()


class LenStr:
    def __len__(self):
        return "x"


class LenNegative:
    def __len__(self):
        return -1


class StrRaises:
    def __str__(self):
        raise Boom()

    def __repr__(self):
        raise Boom()


class IndexRaises:
    def __index__(self):
        raise Boom()


class FloatRaises:
    def __float__(self):
        raise Boom()


class FloatStr:
    def __float__(self):
        return "x" * 3


class FloatBigInt:
    def __float__(self):
        return 10 ** 30


class BoolRaises:
    def __bool__(self):
        raise Boom()


check("len none", lambda: len())
check("len two", lambda: len(1, 2))
check("len int", lambda: len(5))
check("len float", lambda: len(1.5))
check("len __len__ raises", lambda: len(LenRaises()))
check("len __len__ str", lambda: len(LenStr()))
check("len __len__ negative", lambda: len(LenNegative()))
check("range none", lambda: range())
check("range four", lambda: range(1, 2, 3, 4))
check("range str", lambda: range("a"))
check("range big, str", lambda: range(10 ** 30, "a"))
check("range big, big, str", lambda: range(10 ** 30, 10 ** 31, "a"))
check("range big, str, big", lambda: range(10 ** 30, "a", 10 ** 31))
check("range zero step", lambda: range(10 ** 30, 10 ** 31, 0))
check("range __index__ raises", lambda: range(IndexRaises()))
check("range big, big, __index__ raises",
      lambda: range(10 ** 30, 10 ** 31, IndexRaises()))
check("repr none", lambda: repr())
check("repr __repr__ raises", lambda: repr(StrRaises()))
check("bool two", lambda: bool(1, 2))
check("bool keyword", lambda: bool(x=1))
check("bool __bool__ raises", lambda: bool(BoolRaises()))
check("float two", lambda: float(1, 2))
check("float keyword", lambda: float(x=1))
check("float None", lambda: float(None))
check("float bad str", lambda: float("abc" * 10))
check("float bad fullwidth", lambda: float("１x"))
check("float bad bytes", lambda: float(b"zz"))
check("float __float__ raises", lambda: float(FloatRaises()))
check("float __float__ str", lambda: float(FloatStr()))
check("float __float__ big int", lambda: float(FloatBigInt()))

# --- print ------------------------------------------------------------------
class WriteRaises:
    def write(self, s):
        raise Boom()


class WriteOnly:
    def write(self, s):
        pass


sink = io.StringIO()
check("print bad keyword", lambda: print(1, bogus=2))
check("print sep int", lambda: print(1, sep=2, file=sink))
check("print end int", lambda: print(1, end=2, file=sink))
check("print file int", lambda: print(1, file=5))
check("print file float", lambda: print(1, file=1.5))
check("print write raises", lambda: print(1, file=WriteRaises()))
check("print __str__ raises", lambda: print(StrRaises(), file=sink))
check("print no flush", lambda: print(1, file=WriteOnly(), flush=True))
check("print flush __bool__ raises", lambda: print(1, file=sink, flush=BoolRaises()))
check("displayhook two", lambda: sys.displayhook(1, 2))
check("displayhook __repr__ raises", lambda: sys.displayhook(StrRaises()))

# --- a method descriptor handed the wrong receiver, or the wrong count ------------
check("list.append unbound, no arguments", lambda: list.append())
check("list.append on a tuple", lambda: list.append((1, 2), 3))
check("int.__neg__ on a float", lambda: int.__neg__(1.5))
check("list.append none", lambda: [].append())
check("list.append two", lambda: [].append(1, 2))
check("str.join on an int", lambda: str.join(5, []))

# --- int() ------------------------------------------------------------------
class IntRaises:
    def __int__(self):
        raise Boom()
class IntStr:
    def __int__(self):
        return "x" * 3
class IntFloat:
    def __int__(self):
        return 1.5
class IndexStr:
    def __index__(self):
        return "x" * 3
class TruncStr:
    def __trunc__(self):
        return "y" * 3
class TruncFloat:
    def __trunc__(self):
        return 1.5
class TruncRaises:
    def __trunc__(self):
        raise Boom()
class TruncIndexStr:
    def __trunc__(self):
        return IndexStr()
class SubInt(int):
    def __int__(self):
        return "z" * 3
class SubIntSub(int):
    def __int__(self):
        return SubIntSub(5)
class IntBool:
    def __int__(self):
        return True
class GetRaises:
    def __get__(self, o, t):
        raise Boom()
class IntDescr:
    __int__ = GetRaises()
class S(int):
    pass
warnings.simplefilter("ignore")
check("int three", lambda: int(1, 2, 3))
check("int None", lambda: int(None))
check("int bad str", lambda: int("abc" * 10))
check("int bad uni", lambda: int("１x"))
check("int bad bytes", lambda: int(b"zz"))
check("int bad bytearray", lambda: int(bytearray(b"zz")))
check("int bad memoryview", lambda: int(memoryview(b"zz")))
check("int nul", lambda: int("1\x002"))
check("int raises", lambda: int(IntRaises()))
check("int str", lambda: int(IntStr()))
check("int float", lambda: int(IntFloat()))
check("int index str", lambda: int(IndexStr()))
check("int index raises", lambda: int(IndexRaises()))
check("int trunc str", lambda: int(TruncStr()))
check("int trunc float", lambda: int(TruncFloat()))
check("int trunc raises", lambda: int(TruncRaises()))
check("int trunc index str", lambda: int(TruncIndexStr()))
check("int sub str", lambda: int(SubInt(3)))
check("int descr", lambda: int(IntDescr()))
check("int base float", lambda: int("1", 1.5))
check("int base str", lambda: int("1", "a"))
check("int base 1", lambda: int("1", 1))
check("int base 37", lambda: int("1", 37))
check("int base big", lambda: int("1", 10**30))
check("int base index raises", lambda: int("1", IndexRaises()))
check("int nonstr base", lambda: int(5, 10))
check("int bad str base", lambda: int("zz" * 10, 16))
check("int bad bytes base", lambda: int(b"zz", 16))
check("int bad bytearray base", lambda: int(bytearray(b"zz"), 16))
check("int kw", lambda: int("1", bogus=2))
check("int base kw only", lambda: int(base=10))
check("S bad", lambda: S("abc"))
check("int inf", lambda: int(float("inf")))
check("int nan", lambda: int(float("nan")))
warnings.simplefilter("error")
check("int trunc warn error", lambda: int(TruncFloat()))
check("int sub warn error", lambda: int(SubIntSub(3)))
check("int bool warn error", lambda: int(IntBool()))
warnings.resetwarnings()

# --- __reduce__, __setstate__ and __length_hint__ of the builtin iterators ------
ITERATOR_TYPES = (
    ("list iterator", type(iter([]))),
    ("tuple iterator", type(iter(()))),
    ("str iterator", type(iter(""))),
    ("bytes iterator", type(iter(b""))),
    ("bytearray iterator", type(iter(bytearray()))),
    ("range iterator", type(iter(range(3)))),
    ("dict iterator", type(iter({}))),
    ("set iterator", type(iter(set()))),
    ("dict reverse iterator", type(reversed({}))),
)
for label, iterator_type in ITERATOR_TYPES:
    for method in ("__reduce__", "__length_hint__"):
        unbound = getattr(iterator_type, method)
        check(label + " " + method + " unbound", lambda: unbound())
check("list iterator __setstate__ none", lambda: iter([1]).__setstate__())
check("list iterator __setstate__ str", lambda: iter([1]).__setstate__("a"))
check("range.__reduce__ unbound", lambda: range.__reduce__())
check("slice.__reduce__ unbound", lambda: slice.__reduce__())
check("builtin function __reduce__ unbound", lambda: type(len).__reduce__())
check("bound method __reduce__ unbound", lambda: type([].append).__reduce__())
check("Ellipsis __reduce__ unbound", lambda: type(...).__reduce__())
check("NotImplemented __reduce__ unbound", lambda: type(NotImplemented).__reduce__())

# --- sys ----------------------------------------------------------------------
class SizeofRaises:
    def __sizeof__(self):
        raise Boom()


class SizeofTypeError:
    def __sizeof__(self):
        raise TypeError("no size")


check("sys.getsizeof none", lambda: sys.getsizeof())
check("sys.getsizeof __sizeof__ raises", lambda: sys.getsizeof(SizeofRaises()))
check("sys.getsizeof __sizeof__ raises, default",
      lambda: sys.getsizeof(SizeofRaises(), 5))
check("sys.getsizeof __sizeof__ TypeError", lambda: sys.getsizeof(SizeofTypeError()))
check("sys.getsizeof __sizeof__ TypeError, default",
      lambda: sys.getsizeof(SizeofTypeError(), 5))
check("sys.setrecursionlimit none", lambda: sys.setrecursionlimit())
check("sys.setrecursionlimit str", lambda: sys.setrecursionlimit("a"))
check("sys.setrecursionlimit zero", lambda: sys.setrecursionlimit(0))
check("sys.exit", lambda: sys.exit())
check("sys.exit int", lambda: sys.exit(3))
check("sys.exit str", lambda: sys.exit("bye" * 5))
check("sys.get_int_max_str_digits one", lambda: sys.get_int_max_str_digits(1))
check("sys.set_int_max_str_digits str", lambda: sys.set_int_max_str_digits("a"))
check("sys.set_int_max_str_digits too small", lambda: sys.set_int_max_str_digits(5))
check("sys.get_coroutine_origin_tracking_depth one",
      lambda: sys.get_coroutine_origin_tracking_depth(1))
check("sys.set_coroutine_origin_tracking_depth none",
      lambda: sys.set_coroutine_origin_tracking_depth())
check("sys.set_coroutine_origin_tracking_depth negative",
      lambda: sys.set_coroutine_origin_tracking_depth(-1))
check("sys.set_coroutine_origin_tracking_depth str",
      lambda: sys.set_coroutine_origin_tracking_depth("a"))
check("sys.intern none", lambda: sys.intern())
check("sys.intern int", lambda: sys.intern(5))
check("sys.intern str subclass", lambda: sys.intern(StrSub("x")))
check("sys.getrefcount none", lambda: sys.getrefcount())
check("sys.is_finalizing one", lambda: sys.is_finalizing(1))
check("sys.get_asyncgen_hooks one", lambda: sys.get_asyncgen_hooks(1))
check("sys.set_asyncgen_hooks three", lambda: sys.set_asyncgen_hooks(None, None, None))
check("sys.set_asyncgen_hooks bad keyword", lambda: sys.set_asyncgen_hooks(bogus=None))
check("sys.set_asyncgen_hooks firstiter int", lambda: sys.set_asyncgen_hooks(5))
check("sys.set_asyncgen_hooks finalizer int", lambda: sys.set_asyncgen_hooks(None, 5))
check("sys.set_asyncgen_hooks finalizer= int", lambda: sys.set_asyncgen_hooks(finalizer=5))
check("sys.displayhook none", lambda: sys.displayhook())
check("sys.excepthook none", lambda: sys.excepthook())
try:
    sys.exit(7)
except SystemExit as e:
    print("sys.exit code", e.code)

# --- format(), f-strings, str.format and the spec engine behind them --------------
class FormatRaises:
    def __format__(self, spec):
        raise Boom()


class FormatInt:
    def __format__(self, spec):
        return 5


class WideInt(int):
    pass


# A subclass of int whose value is past an int64 is formatted from the int it
# wraps.  The spec engine released that int as though it had made it, so the
# second format() of one instance freed the instance's value.
wide = WideInt(10 ** 30)
for _ in range(50):
    text = format(wide, "x")
    churn = [10 ** 31 + i for i in range(4)]
print("wide subclass", text, int(wide) == 10 ** 30, format(wide, ",d"))

INT_SPECS = ["=+10.3z", "z", "zd", "zs", ".3d", ".3n", "+s", "#s", "=s", ",x",
             "_c", "+c", "#c", ".2c", "999999999999999999999d",
             ".99999999999999999999f", "q", "10q", ",,", "_,", "s", "é",
             ",s", "_s", ",b", "_n"]
FLOAT_SPECS = ["=+10.3z", "zd", "zs", ".3d", "+s", "#s", "=s", ",x", "_c", "+c",
               "#c", ".2c", "c", "999999999999999999999d",
               ".99999999999999999999f", "q", "10q", ",,", "_,", "s", "x",
               "5.5.5", "é", ",s", "_s", ",b", "_n"]
STR_SPECS = ["=+10.3z", "z", "zd", "zs", ".3d", ".3n", "+s", "#s", "=s", ",x",
             "_c", "+c", "#c", ".2c", "c", "999999999999999999999d",
             ".99999999999999999999f", "q", "10q", ",,", "_,", "x", "5.5.5",
             "é", ",b", "_n"]
COMPLEX_SPECS = ["=+10.3z", "zd", "zs", ".3d", "+s", "#s", "=s", ",x", "_c",
                 "+c", "#c", ".2c", "c", "999999999999999999999d",
                 ".99999999999999999999f", "q", "10q", ",,", "_,", "s", "x",
                 "5.5.5", "é", ",s", "_s", ",b"]
FORMAT_CASES = (
    ("int", 5, INT_SPECS),
    ("negative int", -5, INT_SPECS),
    ("big int", 10 ** 30, INT_SPECS),
    ("wide int subclass", wide, INT_SPECS),
    ("bool", True, INT_SPECS),
    ("float", 1.5, FLOAT_SPECS),
    ("str", "abc", STR_SPECS),
    ("complex", 1 + 2j, COMPLEX_SPECS),
)
for label, value, specs in FORMAT_CASES:
    for spec in specs:
        check("format %s %s" % (label, ascii(spec)), lambda: format(value, spec))
check("format c out of range", lambda: format(0x110000, "c"))
check("format c negative", lambda: format(-1, "c"))
check("format c big", lambda: format(10 ** 30, "c"))
check("format c wide subclass", lambda: format(wide, "c"))
check("format complex zero padding", lambda: format(1j, "010"))
check("format complex = alignment", lambda: format(1j, "=10"))
check("format __format__ raises", lambda: format(FormatRaises(), "x"))
check("format __format__ int", lambda: format(FormatInt(), "x"))
check("format none", lambda: format())
check("format three", lambda: format(1, "", 3))
check("format spec int", lambda: format(1, 5))
check("f-string __format__ raises", lambda: f"{FormatRaises():x}")
check("f-string bad spec", lambda: f"{5:.3d}")
check("f-string __str__ raises", lambda: f"{StrRaises()!s:>5}")
check("str.format bad spec", lambda: "{:.3d}".format(5))
check("str.format bad spec, wide subclass", lambda: "{:.3d}".format(wide))
check("str.format __format__ raises", lambda: "{}".format(FormatRaises()))
check("int.__format__ bad spec", lambda: (5).__format__(".3d"))
check("int.__format__ spec int", lambda: (5).__format__(5))
check("int.__format__ none", lambda: (5).__format__())
check("% s __str__ raises", lambda: "%s" % StrRaises())
check("% 5s __str__ raises", lambda: "%5s" % StrRaises())

# --- abs, divmod, ord, chr, hex, bin, oct, round, complex -------------------------
class AbsRaises:
    def __abs__(self):
        raise Boom()


class DivmodRaises:
    def __divmod__(self, other):
        raise Boom()


class FloordivOnly:
    def __floordiv__(self, other):
        return 10 ** 30


class RoundRaises:
    def __round__(self, ndigits=None):
        raise Boom()


class ComplexRaises:
    def __complex__(self):
        raise Boom()


class ComplexStr:
    def __complex__(self):
        return "x" * 3


class FloatSub(float):
    pass


class ComplexSub(complex):
    pass


check("abs none", lambda: abs())
check("abs str", lambda: abs("a"))
check("abs None", lambda: abs(None))
check("abs __abs__ raises", lambda: abs(AbsRaises()))
check("divmod one", lambda: divmod(1))
check("divmod str", lambda: divmod("a", 1))
check("divmod int, str", lambda: divmod(1, "a"))
check("divmod by zero", lambda: divmod(1, 0))
check("divmod big by zero", lambda: divmod(10 ** 30, 0))
check("divmod float by zero", lambda: divmod(1.0, 0.0))
check("divmod int by float zero", lambda: divmod(1, 0.0))
check("divmod __divmod__ raises", lambda: divmod(DivmodRaises(), 1))
check("divmod quotient, no remainder", lambda: divmod(FloordivOnly(), 1))
check("ord none", lambda: ord())
check("ord int", lambda: ord(5))
check("ord two characters", lambda: ord("ab"))
check("ord two bytes", lambda: ord(b"ab"))
check("ord empty", lambda: ord(""))
check("chr none", lambda: chr())
check("chr str", lambda: chr("a"))
check("chr negative", lambda: chr(-1))
check("chr out of range", lambda: chr(0x110000))
check("chr huge", lambda: chr(10 ** 30))
check("chr __index__ raises", lambda: chr(IndexRaises()))
check("hex none", lambda: hex())
check("hex str", lambda: hex("a"))
check("hex float", lambda: hex(1.5))
check("hex __index__ raises", lambda: hex(IndexRaises()))
check("bin none", lambda: bin())
check("bin str", lambda: bin("a"))
check("bin __index__ raises", lambda: bin(IndexRaises()))
check("oct none", lambda: oct())
check("oct str", lambda: oct("a"))
check("oct __index__ raises", lambda: oct(IndexRaises()))
check("round none", lambda: round())
check("round three", lambda: round(1, 2, 3))
check("round str", lambda: round("a"))
check("round ndigits str", lambda: round(1.5, "a"))
check("round ndigits float", lambda: round(1.5, 1.5))
check("round __round__ raises", lambda: round(RoundRaises()))
check("round __round__ raises, ndigits", lambda: round(RoundRaises(), 2))
check("round nan", lambda: round(float("nan")))
check("round inf", lambda: round(float("inf")))
check("complex three", lambda: complex(1, 2, 3))
check("complex bad keyword", lambda: complex(bogus=1))
check("complex None", lambda: complex(None))
check("complex second None", lambda: complex(1, None))
check("complex str and second", lambda: complex("1", 2))
check("complex second str", lambda: complex(1, "2"))
check("complex bad str", lambda: complex("zz" * 10))
check("complex __complex__ raises", lambda: complex(ComplexRaises()))
check("complex __complex__ str", lambda: complex(ComplexStr()))
check("complex __float__ raises", lambda: complex(FloatRaises()))
check("complex second __float__ raises", lambda: complex(1, FloatRaises()))
check("complex subclass None", lambda: ComplexSub(None))
check("complex.__new__ subclass None", lambda: complex.__new__(ComplexSub, None))
check("float.__new__ subclass None", lambda: float.__new__(FloatSub, None))
check("float subclass keyword", lambda: FloatSub(x=1))
check("float subclass bad str", lambda: FloatSub("zz"))
check("bool.__new__ keyword", lambda: bool.__new__(bool, x=1))

# --- time ---------------------------------------------------------------------
for name in ("process_time", "monotonic", "perf_counter", "time", "time_ns",
             "monotonic_ns", "perf_counter_ns", "process_time_ns",
             "thread_time", "thread_time_ns", "tzset"):
    clock = getattr(time, name)
    check("time." + name + " one", lambda: clock(1))
check("time.clock_gettime none", lambda: time.clock_gettime())
check("time.clock_gettime str", lambda: time.clock_gettime("a"))
check("time.clock_gettime no such clock", lambda: time.clock_gettime(12345))
check("time.clock_gettime __index__ raises", lambda: time.clock_gettime(IndexRaises()))
check("time.clock_gettime_ns none", lambda: time.clock_gettime_ns())
check("time.clock_gettime_ns str", lambda: time.clock_gettime_ns("a"))
check("time.clock_gettime_ns no such clock", lambda: time.clock_gettime_ns(12345))
check("time.clock_getres none", lambda: time.clock_getres())
check("time.clock_getres str", lambda: time.clock_getres("a"))
check("time.clock_getres no such clock", lambda: time.clock_getres(12345))
check("time.get_clock_info none", lambda: time.get_clock_info())
check("time.get_clock_info int", lambda: time.get_clock_info(5))
check("time.get_clock_info None", lambda: time.get_clock_info(None))
check("time.get_clock_info embedded NUL", lambda: time.get_clock_info("time\0x"))
check("time.get_clock_info unknown", lambda: time.get_clock_info("zz"))
check("time.sleep none", lambda: time.sleep())
check("time.sleep str", lambda: time.sleep("a"))
check("time.sleep nan", lambda: time.sleep(float("nan")))
check("time.sleep inf", lambda: time.sleep(float("inf")))
check("time.sleep huge int", lambda: time.sleep(10 ** 30))
check("time.sleep negative", lambda: time.sleep(-1))
check("time.strptime none", lambda: time.strptime())
check("time.strptime three", lambda: time.strptime("a", "b", "c"))
check("time.strptime no match", lambda: time.strptime("zz", "%Y"))
check("time.strptime bad keyword", lambda: time.strptime("zz", bogus=1))
check("time.localtime str", lambda: time.localtime("a"))
check("time.localtime huge", lambda: time.localtime(10 ** 30))
check("time.localtime __index__ raises", lambda: time.localtime(IndexRaises()))
check("time.gmtime str", lambda: time.gmtime("a"))
check("time.mktime none", lambda: time.mktime())
check("time.mktime int", lambda: time.mktime(5))
check("time.mktime short tuple", lambda: time.mktime((1, 2, 3)))
check("time.mktime str field",
      lambda: time.mktime((2000, 1, 1, 0, 0, "a", 0, 1, 0)))
check("time.mktime field __index__ raises",
      lambda: time.mktime((2000, 1, 1, 0, 0, 0, IndexRaises(), 1, 0)))
check("time.strftime none", lambda: time.strftime())
check("time.strftime format int", lambda: time.strftime(5))
check("time.strftime short tuple", lambda: time.strftime("%Y", (1, 2)))
check("time.strftime not a tuple", lambda: time.strftime("%Y", 5))
check("time.strftime str field",
      lambda: time.strftime("%Y", (2000, 1, 1, 0, 0, 0, 0, 1, "a")))
check("time.asctime int", lambda: time.asctime(5))
check("time.asctime short tuple", lambda: time.asctime((1, 2)))
check("time.ctime str", lambda: time.ctime("a"))
check("time.ctime __index__ raises", lambda: time.ctime(IndexRaises()))

# --- id, hash, callable, iter, next, any, all, sum, min, max -----------------------
class Unhashable:
    __hash__ = None


class HashRaises:
    def __hash__(self):
        raise Boom()


class IterRaises:
    def __iter__(self):
        raise Boom()


class NextRaises:
    def __iter__(self):
        return self

    def __next__(self):
        raise Boom()


class CompareRaises:
    def __lt__(self, other):
        raise Boom()

    def __gt__(self, other):
        raise Boom()


class DirRaises:
    def __dir__(self):
        raise Boom()


class DictRaises:
    @property
    def __dict__(self):
        raise Boom()


def falsy_then_raise():
    yield 0
    yield 0
    raise Boom()


check("id none", lambda: id())
check("hash none", lambda: hash())
check("hash list", lambda: hash([]))
check("hash __hash__ None", lambda: hash(Unhashable()))
check("hash __hash__ raises", lambda: hash(HashRaises()))
check("callable none", lambda: callable())
check("iter none", lambda: iter())
check("iter three", lambda: iter(1, 2, 3))
check("iter int", lambda: iter(5))
check("iter sentinel, not callable", lambda: iter(5, 6))
check("iter __iter__ raises", lambda: iter(IterRaises()))
check("next none", lambda: next())
check("next three", lambda: next(1, 2, 3))
check("next int", lambda: next(5))
check("next list", lambda: next([]))
check("next list, default", lambda: next([], 1))
check("next __next__ raises", lambda: next(NextRaises()))
check("next __next__ raises, default", lambda: next(NextRaises(), 1))
check("next exhausted", lambda: next(iter([])))
check("any none", lambda: any())
check("any int", lambda: any(5))
check("any __iter__ raises", lambda: any(IterRaises()))
check("any __next__ raises", lambda: any(NextRaises()))
check("any generator raises", lambda: any(falsy_then_raise()))
check("all none", lambda: all())
check("all int", lambda: all(5))
check("all __iter__ raises", lambda: all(IterRaises()))
check("all __next__ raises", lambda: all(NextRaises()))
check("sum none", lambda: sum())
check("sum three", lambda: sum(1, 2, 3))
check("sum int", lambda: sum(5))
check("sum str start", lambda: sum([], "a"))
check("sum bytes start", lambda: sum([], b"a"))
check("sum bytearray start", lambda: sum([], bytearray()))
check("sum strs", lambda: sum(["a", "b"]))
check("sum int, big start", lambda: sum(5, 10 ** 30))
check("sum __next__ raises", lambda: sum(NextRaises()))
check("sum __next__ raises, big start", lambda: sum(NextRaises(), 10 ** 30))
check("sum __iter__ raises", lambda: sum(IterRaises()))
check("sum floats then str", lambda: sum([1.5, 2.5, "a"]))
check("sum bigs then str", lambda: sum([10 ** 30, 10 ** 30, "a"]))
check("min none", lambda: min())
check("max none", lambda: max())
check("min int", lambda: min(5))
check("min empty", lambda: min([]))
check("max empty", lambda: max([]))
check("min key int", lambda: min([1, 2], key=5))
check("min default with two", lambda: min(1, 2, default=3))
check("max default with two", lambda: max(1, 2, default=3))
check("min key raises", lambda: min([10 ** 30, 10 ** 31], key=boom))
check("max key raises", lambda: max(10 ** 30, 10 ** 31, key=boom))
check("min __lt__ raises", lambda: min([CompareRaises(), CompareRaises()]))
check("max __gt__ raises", lambda: max(CompareRaises(), CompareRaises()))
check("min int and str", lambda: min([1, "a"]))
check("max big and str", lambda: max([10 ** 30, "a" * 20]))
check("min __iter__ raises", lambda: min(IterRaises()))
check("min __next__ raises", lambda: min(NextRaises()))

# --- globals, locals, dir, ascii, vars, aiter, anext, __import__, open ----------
check("globals one", lambda: globals(1))
check("locals one", lambda: locals(1))
check("dir two", lambda: dir(1, 2))
check("dir __dir__ raises", lambda: dir(DirRaises()))
check("ascii none", lambda: ascii())
check("ascii __repr__ raises", lambda: ascii(StrRaises()))
check("vars two", lambda: vars(1, 2))
check("vars int", lambda: vars(5))
check("vars __dict__ raises", lambda: vars(DictRaises()))
check("aiter none", lambda: aiter())
check("aiter int", lambda: aiter(5))
check("aiter list", lambda: aiter([]))
check("anext none", lambda: anext())
check("anext three", lambda: anext(1, 2, 3))
check("anext int", lambda: anext(5))
check("__import__ none", lambda: __import__())
check("__import__ int", lambda: __import__(5))
check("__import__ None", lambda: __import__(None))
check("__import__ no such module", lambda: __import__("no_such_module_zz"))
check("__import__ bad keyword", lambda: __import__("sys", bogus=1))
check("__import__ level str", lambda: __import__("sys", level="a"))
check("open none", lambda: open())
check("open bad mode", lambda: open("/dev/null", "zz"))
check("open bad keyword", lambda: open("/dev/null", bogus=1))
check("open no such file", lambda: open("/no/such/file/zz"))
check("open a directory", lambda: open("/tmp"))


# --- callbacks that raise, through helpers that now return the error ------------
class AddRaises:
    def __add__(self, other):
        raise Boom()

    def __radd__(self, other):
        raise Boom()


check("sum __add__ raises", lambda: sum([AddRaises(), AddRaises()]))
check("pow __pow__ raises", lambda: pow(PowRaises(), 2))
