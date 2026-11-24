# An error crossing each kind of slot boundary.
#
# A user class whose dunder raises is reached from assembly through a type
# slot -- tp_hash, nb_bool, sq_length, tp_iter, mp_subscript and the rest --
# and the wrapper in that slot RETURNS the slot's error value with the
# exception pending; it used to jump into the unwinder from wherever it was.
# So every builtin that calls a slot has to notice, release what it holds and
# hand the same exception on.  Each case here is one builtin calling one slot
# whose dunder raises, and the line printed is the exception that reached the
# caller: the type and the message have to be the dunder's own, not a
# builtin's idea of what went wrong, and not nothing at all.
import functools
import sys

results = []


def check(label, fn):
    try:
        r = fn()
    except Exception as e:
        results.append("%-34s %s: %s" % (label, type(e).__name__, e))
    else:
        results.append("%-34s no error (%r)" % (label, r))


class Boom(Exception):
    pass


def boom(what):
    raise Boom(what)


class Hash:
    def __hash__(self):
        boom("hash")


class Eq:
    def __init__(self, h=1):
        self.h = h

    def __hash__(self):
        return self.h

    def __eq__(self, other):
        boom("eq")


class Lt:
    def __lt__(self, other):
        boom("lt")


class Len:
    def __len__(self):
        boom("len")


class Bool:
    def __bool__(self):
        boom("bool")


class Index:
    def __index__(self):
        boom("index")


class Iter:
    def __iter__(self):
        boom("iter")


class Next:
    def __init__(self, n=2):
        self.n = n

    def __iter__(self):
        return self

    def __next__(self):
        if self.n:
            self.n -= 1
            return self.n + 1           # always truthy
        boom("next")


class GetItem:
    def __getitem__(self, k):
        boom("getitem")


class SetItem:
    def __setitem__(self, k, v):
        boom("setitem")

    def __delitem__(self, k):
        boom("delitem")


class Contains:
    def __contains__(self, x):
        boom("contains")


class Repr:
    def __repr__(self):
        boom("repr")


class Str:
    def __str__(self):
        boom("str")


class GetAttr:
    def __getattr__(self, name):
        boom("getattr " + name)


class SetAttr:
    def __setattr__(self, name, value):
        boom("setattr " + name)

    def __delattr__(self, name):
        boom("delattr " + name)


class Descr:
    def __get__(self, obj, owner):
        boom("get")

    def __set__(self, obj, value):
        boom("set")

    def __delete__(self, obj):
        boom("delete")


class HasDescr:
    d = Descr()


class Prop:
    @property
    def p(self):
        boom("property get")

    @p.setter
    def p(self, v):
        boom("property set")

    @p.deleter
    def p(self):
        boom("property del")


class Call:
    def __call__(self, *a):
        boom("call")


class Init:
    def __init__(self):
        boom("init")


class New:
    def __new__(cls):
        boom("new")


class ExcInit(Exception):
    def __init__(self):
        boom("exception init")


class Add:
    def __add__(self, other):
        boom("add")

    def __radd__(self, other):
        boom("radd")

    def __iadd__(self, other):
        boom("iadd")

    def __mul__(self, other):
        boom("mul")


class Neg:
    def __neg__(self):
        boom("neg")

    def __pos__(self):
        boom("pos")

    def __invert__(self):
        boom("invert")

    def __abs__(self):
        boom("abs")

    def __float__(self):
        boom("float")

    def __int__(self):
        boom("int")


class Enter:
    def __enter__(self):
        boom("enter")

    def __exit__(self, *a):
        return False


class Exit:
    def __enter__(self):
        return self

    def __exit__(self, *a):
        boom("exit")


class InstanceCheck(type):
    def __instancecheck__(cls, obj):
        boom("instancecheck")

    def __subclasscheck__(cls, sub):
        boom("subclasscheck")


class Checked(metaclass=InstanceCheck):
    pass


class Format:
    def __format__(self, spec):
        boom("format")


class Keys:
    def keys(self):
        boom("keys")


class KeysThenGetItem:
    def keys(self):
        return ["a"]

    def __getitem__(self, k):
        boom("mapping getitem")


# ---- tp_hash -------------------------------------------------------------
check("hash()", lambda: hash(Hash()))
check("dict key", lambda: {Hash(): 1})
check("dict lookup", lambda: {}[Hash()])
check("dict.get", lambda: {}.get(Hash()))
check("dict setitem", lambda: {}.__setitem__(Hash(), 1))
check("in dict", lambda: Hash() in {})
check("set literal", lambda: {Hash()})
check("set.add", lambda: set().add(Hash()))
check("in set", lambda: Hash() in set())
check("frozenset()", lambda: frozenset([Hash()]))
check("dict.fromkeys", lambda: dict.fromkeys([Hash()]))
check("set.discard", lambda: set().discard(Hash()))

# ---- tp_richcompare ------------------------------------------------------
check("==", lambda: Eq() == 1)
check("dict lookup collide", lambda: {Eq(): 1}[Eq()])
check("set collide", lambda: {Eq(), Eq()})
check("list.index", lambda: [Eq()].index(3))
check("list.count", lambda: [Eq()].count(3))
check("list.remove", lambda: [Eq()].remove(3))
check("in list", lambda: 3 in [Eq()])
check("in tuple", lambda: 3 in (Eq(),))
check("tuple.index", lambda: (Eq(),).index(3))
check("list == list", lambda: [Eq()] == [Eq()])
check("<", lambda: Lt() < 1)
check("list.sort", lambda: [Lt(), Lt()].sort())
check("sorted", lambda: sorted([Lt(), Lt()]))
check("min", lambda: min(Lt(), Lt()))
check("max", lambda: max([Lt(), Lt()]))
check("sorted(key=)", lambda: sorted([1, 2], key=lambda x: boom("key")))
check("min(key=)", lambda: min([1, 2], key=lambda x: boom("key")))
check("list.sort(key=)", lambda: [2, 1].sort(key=lambda x: boom("key")))

# ---- sq_length / mp_length / nb_bool -------------------------------------
check("len()", lambda: len(Len()))
check("bool(len)", lambda: bool(Len()))
check("if len", lambda: 1 if Len() else 2)
check("not len", lambda: not Len())
check("bool()", lambda: bool(Bool()))
check("if bool", lambda: 1 if Bool() else 2)
check("not bool", lambda: not Bool())
check("and", lambda: Bool() and 1)
check("any", lambda: any([Bool()]))
check("all", lambda: all([Bool()]))
check("filter(None)", lambda: list(filter(None, [Bool()])))
check("reversed(len)", lambda: reversed(Len()))

# ---- nb_index ------------------------------------------------------------
check("list[index]", lambda: [1, 2][Index()])
check("slice start", lambda: [1, 2][Index():])
check("slice stop", lambda: "abc"[:Index()])
check("range()", lambda: range(Index()))
check("list * index", lambda: [1] * Index())
check("bytes(index)", lambda: bytes(Index()))
check("hex()", lambda: hex(Index()))
check("bin()", lambda: bin(Index()))
check("chr()", lambda: chr(Index()))
check("str.center", lambda: "a".center(Index()))
check("int.to_bytes", lambda: (5).to_bytes(Index(), "big"))

# ---- tp_iter / tp_iternext -----------------------------------------------
check("iter()", lambda: iter(Iter()))
check("for", lambda: [x for x in Iter()])
check("list()", lambda: list(Iter()))
check("tuple()", lambda: tuple(Iter()))
check("set()", lambda: set(Iter()))
check("frozenset(iter)", lambda: frozenset(Iter()))
check("dict()", lambda: dict(Iter()))
check("sorted(iter)", lambda: sorted(Iter()))
check("sum", lambda: sum(Iter()))
check("min(iter)", lambda: min(Iter()))
check("any(iter)", lambda: any(Iter()))
check("all(iter)", lambda: all(Iter()))
check("zip", lambda: zip(Iter()))
check("map", lambda: map(str, Iter()))
check("filter", lambda: filter(None, Iter()))
check("enumerate", lambda: enumerate(Iter()))
check("str.join", lambda: ",".join(Iter()))
check("bytes.join", lambda: b",".join(Iter()))
check("list.extend", lambda: [].extend(Iter()))
check("list +=", lambda: [].__iadd__(Iter()))
check("list slice assign", lambda: [1, 2].__setitem__(slice(0, 1), Iter()))
check("set.update", lambda: set().update(Iter()))
check("dict.update(iter)", lambda: {}.update(Iter()))
check("unpack", lambda: (lambda a, b: 0)(*Iter()))
check("star unpack", lambda: [*Iter()])
check("set unpack", lambda: {*Iter()})
check("x in iter", lambda: 3 in Iter())
check("bytes(iter)", lambda: bytes(Iter()))
check("bytearray(iter)", lambda: bytearray(Iter()))
check("reduce(iter)", lambda: functools.reduce(lambda a, b: a, Iter()))

check("next()", lambda: next(Next(0)))
check("for next", lambda: [x for x in Next()])
check("list(next)", lambda: list(Next()))
check("tuple(next)", lambda: tuple(Next()))
check("set(next)", lambda: set(Next()))
check("sorted(next)", lambda: sorted(Next()))
check("sum(next)", lambda: sum(Next()))
check("max(next)", lambda: max(Next()))
check("any(next)", lambda: any(Next(0)))
check("all(next)", lambda: all(Next()))
check("zip(next)", lambda: list(zip(Next(), Next(5))))
check("map(next)", lambda: list(map(str, Next())))
check("filter(next)", lambda: list(filter(None, Next())))
check("enumerate(next)", lambda: list(enumerate(Next())))
check("str.join(next)", lambda: ",".join(Next()))
check("list.extend(next)", lambda: [].extend(Next()))
check("dict.fromkeys(next)", lambda: dict.fromkeys(Next()))
check("unpack(next)", lambda: (lambda *a: 0)(*Next()))
check("a, *b = next", lambda: exec("a, *b = Next()"))
check("x in next", lambda: 9 in Next())
check("reduce(next)", lambda: functools.reduce(lambda a, b: a, Next()))
check("yield from", lambda: list((lambda: (yield from Next()))()))

# ---- mp_subscript / mp_ass_subscript / sq_contains -----------------------
check("obj[k]", lambda: GetItem()[0])
check("obj[a:b]", lambda: GetItem()[1:2])
check("iter via getitem", lambda: list(GetItem()))
check("x in getitem", lambda: 3 in GetItem())
check("dict.update(mapping)", lambda: {}.update(KeysThenGetItem()))
check("dict(mapping)", lambda: dict(KeysThenGetItem()))
check("{**mapping}", lambda: {**KeysThenGetItem()})
check("f(**mapping)", lambda: (lambda **k: 0)(**KeysThenGetItem()))
check("dict.update(keys)", lambda: {}.update(Keys()))
check("'%(a)s' %", lambda: "%(a)s" % KeysThenGetItem())
check("str.format_map", lambda: "{a}".format_map(KeysThenGetItem()))
check("obj[k] = v", lambda: SetItem().__setitem__(0, 1))
check("store subscr", lambda: exec("s = SetItem(); s[0] = 1"))
check("store slice", lambda: exec("s = SetItem(); s[0:1] = [1]"))
check("del obj[k]", lambda: exec("s = SetItem(); del s[0]"))
check("x in obj", lambda: 1 in Contains())
check("x not in obj", lambda: 1 not in Contains())

# ---- tp_repr / tp_str / __format__ ---------------------------------------
check("repr()", lambda: repr(Repr()))
check("str(repr)", lambda: str(Repr()))
check("repr(list)", lambda: repr([Repr()]))
check("repr(dict)", lambda: repr({1: Repr()}))
check("repr(tuple)", lambda: repr((Repr(),)))
check("repr(set)", lambda: repr({Repr()}))
check("'%r' %", lambda: "%r" % Repr())
check("f'{x!r}'", lambda: f"{Repr()!r}")
check("ascii()", lambda: ascii(Repr()))
check("str()", lambda: str(Str()))
check("print()", lambda: print(Str()))
check("'%s' %", lambda: "%s" % Str())
check("f'{x}'", lambda: f"{Str()}")
check("str.format", lambda: "{}".format(Str()))
check("format()", lambda: format(Format()))
check("f'{x:>3}'", lambda: f"{Format():>3}")
check("str.join(str)", lambda: ",".join([Str()]))

# ---- tp_getattr / tp_setattr / descriptors -------------------------------
check("obj.x", lambda: GetAttr().x)
check("getattr()", lambda: getattr(GetAttr(), "x"))
check("getattr(default)", lambda: getattr(GetAttr(), "x", 5))
check("hasattr()", lambda: hasattr(GetAttr(), "x"))
check("obj.x = v", lambda: exec("s = SetAttr(); s.x = 1"))
check("setattr()", lambda: setattr(SetAttr(), "x", 1))
check("del obj.x", lambda: exec("s = SetAttr(); del s.x"))
check("delattr()", lambda: delattr(SetAttr(), "x"))
check("descr get", lambda: HasDescr().d)
check("descr getattr()", lambda: getattr(HasDescr(), "d"))
check("descr hasattr()", lambda: hasattr(HasDescr(), "d"))
check("descr set", lambda: exec("h = HasDescr(); h.d = 1"))
check("descr setattr()", lambda: setattr(HasDescr(), "d", 1))
check("descr delete", lambda: exec("h = HasDescr(); del h.d"))
check("property get", lambda: Prop().p)
check("property set", lambda: setattr(Prop(), "p", 1))
check("property del", lambda: delattr(Prop(), "p"))
check("property store", lambda: exec("q = Prop(); q.p = 1"))
check("vars(getattr)", lambda: sorted(vars(GetAttr())))

# ---- tp_call / tp_new / tp_init ------------------------------------------
check("obj()", lambda: Call()())
check("obj(*args)", lambda: Call()(*[1, 2]))
check("map(obj)", lambda: list(map(Call(), [1])))
check("filter(obj)", lambda: list(filter(Call(), [1])))
check("sorted(key=obj)", lambda: sorted([1], key=Call()))
check("reduce(obj)", lambda: functools.reduce(Call(), [1, 2]))
check("iter(obj, sentinel)", lambda: list(iter(Call(), None)))
check("C() init", lambda: Init())
check("C() new", lambda: New())
check("E() init", lambda: ExcInit())
check("raise E", lambda: exec("raise ExcInit"))
check("type() call", lambda: type("T", (Init,), {})())
check("5()", lambda: eval("x()", {"x": 5}))
check("None()", lambda: eval("x()", {"x": None}))
check("map(5)", lambda: list(map(5, [1])))
check("sorted(key=5)", lambda: sorted([1], key=5))
check("object(1)", lambda: object(1))
check("C(1)", lambda: type("T", (), {})(1))
check("init returns", lambda: type("T", (), {"__init__": lambda s: 5})())

# ---- number slots --------------------------------------------------------
check("a + b", lambda: Add() + 1)
check("1 + b", lambda: 1 + Add())
check("a += b", lambda: exec("a = Add(); a += 1"))
check("a * b", lambda: Add() * 2)
check("sum(add)", lambda: sum([Add(), Add()]))
check("sum(start)", lambda: sum([1], Add()))
check("reduce(add)", lambda: functools.reduce(lambda a, b: a + b, [Add(), 1]))
check("-a", lambda: -Neg())
check("+a", lambda: +Neg())
check("~a", lambda: ~Neg())
check("abs()", lambda: abs(Neg()))
check("float()", lambda: float(Neg()))
check("int()", lambda: int(Neg()))
check("divmod", lambda: divmod(Add(), 1))
check("pow", lambda: pow(Add(), 2))

# ---- with / isinstance ---------------------------------------------------
check("with enter", lambda: exec("with Enter(): pass"))
check("with exit", lambda: exec("with Exit(): pass"))
check("with exit after raise", lambda: exec("with Exit(): raise KeyError('k')"))
check("isinstance", lambda: isinstance(1, Checked))
check("issubclass", lambda: issubclass(int, Checked))
check("except Checked", lambda: exec("try:\n raise KeyError('k')\nexcept KeyError:\n isinstance(1, Checked)"))

# ---- a dunder that is there and cannot be called -------------------------
NotCallable = type("NotCallable", (), {
    "__len__": 5, "__iter__": 5, "__hash__": 5, "__bool__": 5,
    "__getitem__": 5, "__contains__": 5, "__call__": 5, "__neg__": 5,
    "__enter__": 5, "__exit__": 5, "__index__": 5})
check("len: int dunder", lambda: len(NotCallable()))
check("iter: int dunder", lambda: iter(NotCallable()))
check("hash: int dunder", lambda: hash(NotCallable()))
check("bool: int dunder", lambda: bool(NotCallable()))
check("[]: int dunder", lambda: NotCallable()[0])
check("in: int dunder", lambda: 1 in NotCallable())
check("call: int dunder", lambda: NotCallable()())
check("neg: int dunder", lambda: -NotCallable())
check("index: int dunder", lambda: [1][NotCallable()])
NoneDunder = type("NoneDunder", (), {"__iter__": None, "__hash__": None,
                                     "__call__": None})
NoneLen = type("NoneLen", (), {"__len__": None})
check("iter: None dunder", lambda: iter(NoneDunder()))
check("list: None dunder", lambda: list(NoneDunder()))
check("hash: None dunder", lambda: hash(NoneDunder()))
check("set: None dunder", lambda: {NoneDunder()})
check("len: None dunder", lambda: len(NoneLen()))
check("call: None dunder", lambda: NoneDunder()())
check("len returns -1", lambda: len(type("T", (), {"__len__": lambda s: -1})()))
check("bool returns 5", lambda: bool(type("T", (), {"__bool__": lambda s: 5})()))
check("hash returns -1", lambda: hash(type("T", (), {"__hash__": lambda s: -1})()) in (-1, -2))
check("iter returns 5", lambda: iter(type("T", (), {"__iter__": lambda s: 5})()))


# ---- nested: a callback inside a builtin inside a callback ---------------
class Outer:
    def __init__(self, inner):
        self.inner = inner

    def __iter__(self):
        return iter(sorted(self.inner, key=lambda x: len(x)))


check("sorted in iter in list", lambda: list(Outer([Len(), Len()])))


class HashViaDict:
    def __hash__(self):
        return hash(tuple({Hash(): 1}))


check("dict in hash in set", lambda: {HashViaDict()})


class EqViaJoin:
    def __hash__(self):
        return 7

    def __eq__(self, other):
        return ",".join(Iter()) == other


check("join in eq in dict", lambda: {EqViaJoin(): 1}[EqViaJoin()])


class ReprViaSum:
    def __repr__(self):
        return repr(sum([Add(), Add()]))


check("sum in repr in repr", lambda: repr([(ReprViaSum(),)]))


def key_via_max(x):
    return max([Lt(), Lt()])


check("max in key in sort", lambda: [3, 2, 1].sort(key=key_via_max))


class BoolViaAny:
    def __bool__(self):
        return all(Next())


check("all in bool in filter", lambda: list(filter(None, [BoolViaAny()])))
check("map in map in list",
      lambda: list(map(lambda x: list(map(len, [x])), [Len()])))
check("reduce in reduce",
      lambda: functools.reduce(
          lambda a, b: functools.reduce(lambda c, d: c + d, [Add(), b]), [1, 2]))


# ---- the exception survives, and nothing else does -----------------------
def caught_then_fine():
    out = []
    for fn in (lambda: len(Len()), lambda: hash(Hash()), lambda: list(Iter())):
        try:
            fn()
        except Boom as e:
            out.append(str(e))
        out.append(len([1, 2, 3]))      # ordinary code, straight after
        out.append(hash(1))
        out.append(list(range(2)))
    return out


check("recovers", caught_then_fine)


# A dunder that raises inside a finalizer that runs while another exception
# unwinds: the finalizer sees its own error and only its own, and the
# exception that was unwinding is the one that arrives.
del_log = []


class DelCalls:
    def __del__(self):
        try:
            len(Len())
        except Boom as e:
            del_log.append("del caught %s" % e)
        del_log.append(len("abc"))


def unwinding():
    d = DelCalls()
    raise KeyError("the one that propagates")


check("del during unwind", unwinding)

for line in results:
    print(line)

# ---- a refused constructor releases what it was building -----------------
import gc
import _io


def climbs(fn, rounds=200):
    for _ in range(10):
        try:
            fn()
        except Exception:
            pass
    gc.collect()
    before = sys.getallocatedblocks()
    for _ in range(rounds):
        try:
            fn()
        except Exception:
            pass
    gc.collect()
    return sys.getallocatedblocks() - before > rounds // 2


print("BytesIO(5.5) climbs:", climbs(lambda: _io.BytesIO(5.5)))
print("FileIO(missing) climbs:", climbs(lambda: _io.FileIO("/no/such/file")))
print("C(1) climbs:", climbs(lambda: type.__call__(Init)))
print("len(Len()) climbs:", climbs(lambda: len(Len())))
print("-Neg() climbs:", climbs(lambda: -Neg()))
print("Add() + 1 climbs:", climbs(lambda: Add() + 1))
print(del_log)
print("done")
