# A dunder that raises, reached through one of the core helpers.
#
# obj_is_true, obj_hash, type_custom_check and their neighbours are what half
# of the assembly asks its questions through, and each now RETURNS the error
# a dunder raised instead of jumping into the unwinder from wherever it was
# called.  So every caller has to notice it, release what it holds, and hand
# the same exception on.
#
# Each case runs the failing call two hundred times around
# sys.getallocatedblocks().  The line printed is the exception that reached
# the caller the first time, and whether the block count stayed put: a caller
# that does not release what it held climbs by at least one block a round.
import gc
import importlib
import os
import shutil
import tempfile
import marshal
import sys
import weakref

results = []


class Boom(Exception):
    pass


def boom(what):
    raise Boom(what)


def one(fn):
    try:
        r = fn()
    except Exception as e:
        return "%s: %s" % (type(e).__name__, e)
    return "no error (%r)" % (r,)


def check(label, fn, message=True, leak=True):
    first = one(fn)
    if not message:
        first = first.split(":")[0]
    if not leak:
        # CPython's own import machinery allocates on a failed import, so
        # only the exception is comparable; CHK_LEAKS=1 prints the rest.
        if not os.environ.get("CHK_LEAKS"):
            results.append("%-36s %s" % (label, first))
            return
    for _ in range(20):
        one(fn)
    gc.collect()
    before = sys.getallocatedblocks()
    for _ in range(200):
        one(fn)
    gc.collect()
    grew = sys.getallocatedblocks() - before
    results.append("%-36s %-28s %s" % (label, first, "steady" if grew < 50 else "LEAKS"))


class Bool:
    def __bool__(self):
        boom("bool")


class Hash:
    def __hash__(self):
        boom("hash")


class HashCall:
    def __hash__(self):
        boom("hash")

    def __call__(self):
        pass

    def m(self):
        pass


class MinusOne:
    def __hash__(self):
        return -1


class Iter:
    def __iter__(self):
        boom("iter")


class Next:
    def __iter__(self):
        return self

    def __next__(self):
        boom("next")


class Rev:
    def __reversed__(self):
        boom("reversed")


class LenSeq:
    def __len__(self):
        boom("len")

    def __getitem__(self, i):
        return i


class GetItem:
    def __len__(self):
        return 2

    def __getitem__(self, i):
        boom("getitem")


class Repr:
    def __repr__(self):
        boom("repr")


class ReprHashable(Repr):
    def __hash__(self):
        return 1


class Sink:
    def write(self, data):
        return len(data)


class BadSink:
    def write(self, data):
        boom("write")

    def read(self, n=-1):
        boom("read")


GOOD = marshal.dumps((1, "two", 3.0, [4, b"five"]))

class Index:
    def __index__(self):
        boom("index")


MODDIR = tempfile.mkdtemp()
for name, body in (
    ("chk_raises", "raise ValueError('module body')\n"),
    ("chk_syntax", "def (\n"),
    ("chk_circ_a", "from chk_circ_b import b\na = 1\n"),
    ("chk_circ_b", "from chk_circ_a import a\nb = 1\n"),
):
    with open(os.path.join(MODDIR, name + ".py"), "w") as f:
        f.write(body)
sys.path.insert(0, MODDIR)
sys.dont_write_bytecode = True

class DocProp(property):
    def __setattr__(self, name, value):
        boom("setattr " + name)


HASH = Hash()
HASHCALL = HashCall()


class Len:
    def __len__(self):
        boom("len")


class BadBool:
    def __bool__(self):
        return 1


class NegLen:
    def __len__(self):
        return -1


class NoneBool:
    __bool__ = None


class EqBool:
    # a comparison whose ANSWER cannot be asked for its truth
    def __eq__(self, other):
        return Bool()

    def __lt__(self, other):
        return Bool()

    __hash__ = None


class Contains:
    def __contains__(self, item):
        return Bool()


class Meta(type):
    def __instancecheck__(cls, obj):
        boom("instancecheck")

    def __subclasscheck__(cls, sub):
        boom("subclasscheck")


class MetaTruth(type):
    def __instancecheck__(cls, obj):
        return Bool()

    def __subclasscheck__(cls, sub):
        return Bool()


class Checked(metaclass=Meta):
    pass


class CheckedTruth(metaclass=MetaTruth):
    pass


def if_(x):
    if x:
        return 1
    return 0


def while_(x):
    while x:
        return 1
    return 0


# ---- __bool__ and __len__, asked by everything that wants a truth value ----
check("bool(Bool)", lambda: bool(Bool()))
check("bool(Len)", lambda: bool(Len()))
check("bool(BadBool)", lambda: bool(BadBool()))
check("bool(NegLen)", lambda: bool(NegLen()))
check("bool(NoneBool)", lambda: bool(NoneBool()), message=False)
check("not Bool", lambda: not Bool())
check("if Bool", lambda: if_(Bool()))
check("while Len", lambda: while_(Len()))
check("Bool and 1", lambda: Bool() and 1)
check("Bool or 1", lambda: Bool() or 1)
check("1 if Bool else 2", lambda: 1 if Bool() else 2)
check("any([0, Bool])", lambda: any([0, Bool()]))
check("all([1, Bool])", lambda: all([1, Bool()]))
check("any(gen)", lambda: any(x for x in [0, Len()]))
check("all(gen)", lambda: all(x for x in [1, Len()]))
check("filter(None, [Bool])", lambda: list(filter(None, [1, Bool()])))
check("filter(f, ...) -> Bool", lambda: list(filter(lambda x: Bool(), [1, 2])))
check("sorted(reverse=Bool)", lambda: sorted([3, 1, 2], reverse=Bool()))
check("list.sort(reverse=Bool)", lambda: [3, 1, 2].sort(reverse=Bool()))
check("int.to_bytes(signed=Bool)", lambda: (1).to_bytes(1, "big", signed=Bool()))
check("int.from_bytes(signed=Bool)", lambda: int.from_bytes(b"\x01", "big", signed=Bool()))
check("bytes.splitlines(Bool)", lambda: b"a\nb".splitlines(Bool()))
check("print(flush=Bool)", lambda: print(end="", flush=Bool()))
check("__import__ fromlist Bool", lambda: __import__("sys", None, None, Bool()))
check("EqBool == 1", lambda: if_(EqBool() == 1))
check("EqBool in list", lambda: EqBool() in [1, 2])
check("list.index(EqBool)", lambda: [1, 2].index(EqBool()))
check("list.count(EqBool)", lambda: [1, 2].count(EqBool()))
check("list.remove(EqBool)", lambda: [1, 2].remove(EqBool()))
check("tuple.index(EqBool)", lambda: (1, 2).index(EqBool()))
check("min(EqBool, EqBool)", lambda: min(EqBool(), EqBool()))
check("max(EqBool, EqBool)", lambda: max(EqBool(), EqBool()))
check("sorted([EqBool, EqBool])", lambda: sorted([EqBool(), EqBool()]))
check("1 in Contains", lambda: 1 in Contains())
check("object.__ne__ over Bool", lambda: object.__ne__(EqBool(), 1))

# ---- __hash__ ----------------------------------------------------------------
check("hash(Hash)", lambda: hash(Hash()))
check("hash([])", lambda: hash([]), message=False)
check("hash((1, Hash))", lambda: hash((1, Hash())))
check("hash((1, []))", lambda: hash((1, [])), message=False)
check("hash(slice(Hash))", lambda: hash(slice(Hash())))
check("hash(bound method)", lambda: hash(HASHCALL.m) == hash(HASHCALL.m))
check("hash(list[Hash])", lambda: hash(list[Hash()]))
check("hash(int | str)", lambda: hash(int | str) == hash(str | int))
check("hash(weakref.ref(Hash))", lambda: hash(weakref.ref(HASH)))
check("object.__hash__ by name", lambda: tuple.__hash__((Hash(),)))
check("d[Hash]", lambda: {}[Hash()])
check("d[Hash] = 1", lambda: {}.__setitem__(Hash(), 1))
check("Hash in d", lambda: Hash() in {})
check("d.get(Hash)", lambda: {}.get(Hash()))
check("d.setdefault(Hash)", lambda: {}.setdefault(Hash()))
check("s.add(Hash)", lambda: set().add(Hash()))
check("Hash in s", lambda: Hash() in set())
check("s.discard(Hash)", lambda: set().discard(Hash()))
check("s.remove(Hash)", lambda: set().remove(Hash()))
check("hash == -1 is remapped", lambda: hash(MinusOne()) == -2)

# ---- __instancecheck__ and __subclasscheck__ --------------------------------
check("isinstance, hook raises", lambda: isinstance(1, Checked))
check("issubclass, hook raises", lambda: issubclass(int, Checked))
check("isinstance, in a tuple", lambda: isinstance(1, (str, Checked)))
check("issubclass, in a tuple", lambda: issubclass(int, (str, Checked)))
check("isinstance, answer's bool", lambda: isinstance(1, CheckedTruth))
check("issubclass, answer's bool", lambda: issubclass(int, CheckedTruth))

# ---- the iterator builtins ---------------------------------------------------
check("enumerate(Iter)", lambda: enumerate(Iter()))
check("enumerate(1)", lambda: enumerate(1))
check("enumerate()", lambda: enumerate(), message=False)
check("enumerate([], 'x')", lambda: enumerate([], "x"))
check("enumerate(1, 'x')", lambda: enumerate(1, "x"), message=False)
check("zip([], [], Iter)", lambda: zip([1], [2], Iter()))
check("zip([], 1)", lambda: zip([1], 1), message=False)
check("map(f, [], Iter)", lambda: map(len, [1], Iter()))
check("map(f, 1)", lambda: map(len, 1))
check("map(f)", lambda: map(len), message=False)
check("filter(f, Iter)", lambda: filter(len, Iter()))
check("filter(None, 1)", lambda: filter(None, 1))
check("filter()", lambda: filter(), message=False)
check("reversed(1)", lambda: reversed(1))
check("reversed(Rev)", lambda: reversed(Rev()))
check("reversed(Len-only seq)", lambda: reversed(LenSeq()))
check("reversed()", lambda: reversed(), message=False)
check("list.extend(Iter)", lambda: [].extend(Iter()))
check("property subclass, doc store", lambda: DocProp(None, None, None, "doc"))
check("sorted(Iter)", lambda: sorted(Iter()))
check("sorted(1)", lambda: sorted(1))
check("sorted(Next)", lambda: sorted(Next()))
check("sorted()", lambda: sorted(), message=False)
check("sorted(key raises)", lambda: sorted([3, 1, 2], key=boom))
check("list(map(boom, ...))", lambda: list(map(boom, [1, 2])))
check("list(zip([1], Next))", lambda: list(zip([1], Next())))
check("list(enumerate(Next))", lambda: list(enumerate(Next())))
check("list(filter(None, Next))", lambda: list(filter(None, Next())))
check("list(reversed(GetItem))", lambda: list(reversed(GetItem())))

# ---- repr -------------------------------------------------------------------
check("repr([Repr])", lambda: repr([1, Repr()]))
check("repr((Repr,))", lambda: repr((1, Repr())))
check("repr({1: Repr})", lambda: repr({1: Repr()}))
check("repr({Repr})", lambda: repr({ReprHashable()}))
check("repr(d.values())", lambda: repr({1: Repr()}.values()))
check("str([Repr])", lambda: str([Repr()]))
check("'%r' % [Repr]", lambda: "%r" % ([Repr()],))
check("f'{[Repr]}'", lambda: f"{[Repr()]}")

# ---- marshal ------------------------------------------------------------------
check("marshal.loads(b'')", lambda: marshal.loads(b""), message=False)
check("marshal.loads(truncated)", lambda: marshal.loads(GOOD[:-3]), message=False)
check("marshal.loads(corrupt)", lambda: marshal.loads(b"\xff" + GOOD), message=False)
check("marshal.loads(1)", lambda: marshal.loads(1), message=False)
check("marshal.loads()", lambda: marshal.loads(), message=False)
check("marshal.dumps(object())", lambda: marshal.dumps(object()))
check("marshal.dumps()", lambda: marshal.dumps(), message=False)
check("marshal.dump(1, 1)", lambda: marshal.dump(1, 1), message=False)
check("marshal.dump(obj, file)", lambda: marshal.dump(object(), Sink()))
check("marshal.dump, write raises", lambda: marshal.dump(1, BadSink()))
check("marshal.dump()", lambda: marshal.dump(), message=False)
check("marshal.load(1)", lambda: marshal.load(1), message=False)
check("marshal.load, read raises", lambda: marshal.load(BadSink()))
check("marshal.load()", lambda: marshal.load(), message=False)

# ---- import ------------------------------------------------------------------
def imp(src):
    def run():
        exec(src, {"__name__": "chk", "__package__": None})
    return run


def blocked():
    sys.modules["chk_blocked"] = None
    try:
        import chk_blocked
    finally:
        del sys.modules["chk_blocked"]


check("import missing", imp("import chk_no_such_module"), leak=False)
check("import missing.sub", imp("import chk_no_such_module.sub"), leak=False)
check("import sys.missing", imp("import sys.chk_missing"), leak=False)
check("from missing import x", imp("from chk_no_such_module import x"), leak=False)
check("from sys import missing", imp("from sys import chk_missing"), message=False, leak=False)
check("from . import x, no package", imp("from . import x"), leak=False)
check("import of a None entry", blocked, leak=False)
check("import, body raises", imp("import chk_raises"), leak=False)
check("from m import x, body raises", imp("from chk_raises import x"), leak=False)
check("import, syntax error", imp("import chk_syntax"), message=False, leak=False)
check("circular from-import", imp("import chk_circ_a"), message=False, leak=False)
check("__import__(missing)", lambda: __import__("chk_no_such_module"), leak=False)
check("__import__(1)", lambda: __import__(1), message=False, leak=False)
check("__import__('a.b') missing", lambda: __import__("chk_no_such_module.b", None, None, ("x",)), leak=False)
check("importlib.import_module", lambda: importlib.import_module("chk_no_such_module"), leak=False)

# ---- compile(), exec() and eval() ---------------------------------------------
check("compile(bad source)", lambda: compile("x = (", "<s>", "exec"), message=False)
check("compile(1, ...)", lambda: compile(1, "<s>", "exec"), message=False)
check("compile(src, 1, ...)", lambda: compile("x", 1, "exec"), message=False)
check("compile(src, f, 1)", lambda: compile("x", "<s>", 1), message=False)
check("compile(src, f, 'bogus')", lambda: compile("x", "<s>", "bogus"))
check("compile(src, f, m, 'x')", lambda: compile("x", "<s>", "exec", "x"), message=False)
check("compile(src, f, m, Index)", lambda: compile("x", "<s>", "exec", Index()))
check("compile()", lambda: compile(), message=False)
check("eval(bad source)", lambda: eval("1 +"), message=False)
check("eval(1)", lambda: eval(1), message=False)
check("eval(src, 1)", lambda: eval("1", 1), message=False)
check("eval()", lambda: eval(), message=False)
check("eval(raises)", lambda: eval("boom('eval')"))
check("exec(bad source)", lambda: exec("def ("), message=False)
check("exec(1)", lambda: exec(1), message=False)
check("exec(src, 1)", lambda: exec("x = 1", 1), message=False)
check("exec()", lambda: exec(), message=False)
check("exec(raises)", lambda: exec("boom('exec')"))

# ---- sys.call_tracing ---------------------------------------------------------
check("sys.call_tracing(f)", lambda: sys.call_tracing(len), message=False)
check("sys.call_tracing(f, 2)", lambda: sys.call_tracing(len, 2))
check("sys.call_tracing(boom, (1,))", lambda: sys.call_tracing(boom, (1,)))

# ---- a dunder reached by name, handed the wrong receiver ---------------------
check("int.__neg__(2.5)", lambda: int.__neg__(2.5))
check("int.__add__('a', 1)", lambda: int.__add__("a", 1))
check("int.__radd__('a', 1)", lambda: int.__radd__("a", 1))
check("int.__lt__('a', 1)", lambda: int.__lt__("a", 1))
check("int.__bool__('a')", lambda: int.__bool__("a"))
check("int.__hash__('a')", lambda: int.__hash__("a"))
check("int.__repr__('a')", lambda: int.__repr__("a"))
check("str.__len__(5)", lambda: str.__len__(5))
check("str.__iter__(5)", lambda: str.__iter__(5))
check("str.__getitem__(5, 0)", lambda: str.__getitem__(5, 0))
check("str.__contains__(5, 'a')", lambda: str.__contains__(5, "a"))
check("list.__getitem__((), 0)", lambda: list.__getitem__((), 0))
check("list.__setitem__((), 0, 1)", lambda: list.__setitem__((), 0, 1))
check("list.__delitem__((), 0)", lambda: list.__delitem__((), 0))
check("list.__contains__((), 0)", lambda: list.__contains__((), 0))
check("list.__len__(())", lambda: list.__len__(()))
check("list.__iadd__((), [])", lambda: list.__iadd__((), []))
check("tuple.__getitem__([], 0)", lambda: tuple.__getitem__([], 0))
check("tuple.__add__([], ())", lambda: tuple.__add__([], ()))
check("tuple.__mul__([], 2)", lambda: tuple.__mul__([], 2))
check("tuple.__rmul__([], 2)", lambda: tuple.__rmul__([], 2))
check("tuple.__len__([])", lambda: tuple.__len__([]))
check("tuple.__contains__([], 1)", lambda: tuple.__contains__([], 1))
check("dict.__getitem__([], 0)", lambda: dict.__getitem__([], 0))
check("dict.__setitem__([], 0, 1)", lambda: dict.__setitem__([], 0, 1))
check("dict.__delitem__([], 0)", lambda: dict.__delitem__([], 0))
check("dict.__len__([])", lambda: dict.__len__([]))
check("dict.__iter__([])", lambda: dict.__iter__([]))
check("frozenset.__hash__(set())", lambda: frozenset.__hash__(set()))
check("set.__len__([])", lambda: set.__len__([]))
check("bytearray.__len__(b'')", lambda: bytearray.__len__(b""))
check("bytearray.__getitem__(b'', 0)", lambda: bytearray.__getitem__(b"", 0))
check("bytearray.__contains__(b'', 0)", lambda: bytearray.__contains__(b"", 0))
check("bytes.__bytes__('a')", lambda: bytes.__bytes__("a"))
check("memoryview.__len__(b'')", lambda: memoryview.__len__(b""))
check("type(iter([])).__next__(1)", lambda: type(iter([])).__next__(1))
check("type(len).__call__(1)", lambda: type(len).__call__(1))

sys.path.remove(MODDIR)
shutil.rmtree(MODDIR)

for line in results:
    print(line)
