# The object model refusing something, two hundred times over.
#
# Calls, descriptors, classes, generators, modules and generic aliases are
# all assembly here, and each of their refusals used to JUMP into the
# unwinder from wherever it was noticed -- abandoning the native frames in
# between and whatever those held: the frame being bound, the half-built
# instance, the iterator, the argument array.  Every case below provokes one
# refusal in a loop and reads sys.getallocatedblocks() around it.  What is
# printed is the exception's type, its message where CPython words it the
# same way, and whether the block count stayed put.
import gc
import sys
import types

ROUNDS = 200


def case(label, fn, msg=False):
    seen = None
    text = None
    for i in range(3):                  # warm every cache first
        try:
            fn()
        except Exception as e:
            pass
    gc.collect()
    before = sys.getallocatedblocks()
    for i in range(ROUNDS):
        try:
            fn()
        except Exception as e:
            seen = type(e).__name__
            if msg:
                text = str(e)
        else:
            seen = "no error"
    gc.collect()
    after = sys.getallocatedblocks()
    steady = (after - before) < 50
    if msg:
        print("%-44s %s: %s | steady %s" % (label, seen, text, steady))
    else:
        print("%-44s %s | steady %s" % (label, seen, steady))


# ---------------------------------------------------------------- bad calls
def f2(a, b):
    return a


def fdef(a, b=2, *, k, m=4):
    return a


def fpos(a, b, /, c):
    return a


def fkw(a, **kw):
    return a


def fvar(*args, k):
    return args


big = [list(range(10)) for _ in range(3)]

case("call: missing one", lambda: f2(big), True)
case("call: missing two", lambda: f2(), True)
case("call: too many", lambda: f2(big, big, big), True)
case("call: too many, one wanted", lambda: (lambda a: a)(big, big), True)
case("call: unknown keyword", lambda: f2(big, b=1, zzz=big), True)
case("call: duplicate", lambda: f2(big, a=big))
case("call: missing keyword-only", lambda: fdef(big), True)
case("call: keyword-only given positionally", lambda: fdef(big, 2, big), True)
case("call: positional-only by keyword", lambda: fpos(big, b=big, c=1))
case("call: positional-only missing", lambda: fpos(big), True)
case("call: **kw then missing", lambda: fkw(x=big, y=big), True)
case("call: *args, kw-only missing", lambda: fvar(big, big), True)
case("call: star of a non-iterable", lambda: f2(*5))
case("call: double-star of a non-mapping", lambda: f2(**5))
case("call: double-star repeats a name", lambda: f2(big, **{'a': big}))
five = 5
nothing = None
case("call: an int", lambda: five(big), True)
case("call: None", lambda: nothing(big), True)


class Meth:
    def m(self, a):
        return a

    @staticmethod
    def s(a):
        return a

    @classmethod
    def c(cls, a):
        return a


mo = Meth()
case("method: missing", lambda: mo.m(), True)
case("method: too many", lambda: mo.m(big, big), True)
case("method: unknown keyword", lambda: mo.m(big, zzz=big), True)
case("staticmethod: too many", lambda: mo.s(big, big), True)
case("classmethod: missing", lambda: Meth.c(), True)
case("unbound: no self", lambda: Meth.m(), True)
case("MethodType: no arguments", lambda: types.MethodType(), True)
case("MethodType: not callable", lambda: types.MethodType(5, big), True)
case("MethodType: None instance", lambda: types.MethodType(f2, None), True)
case("MethodType: keywords", lambda: types.MethodType(f2, x=big))
case("bound to a non-callable",
     lambda: types.MethodType(mo, big).__func__.nothing)

# ------------------------------------------------------- function objects
case("FunctionType: no arguments", lambda: types.FunctionType())
case("FunctionType: code is not code",
     lambda: types.FunctionType(big, {}))
case("FunctionType: globals is not a dict",
     lambda: types.FunctionType(f2.__code__, big))
case("FunctionType: name is not a str",
     lambda: types.FunctionType(f2.__code__, {}, big), True)
case("FunctionType: defaults not a tuple",
     lambda: types.FunctionType(f2.__code__, {}, "n", big), True)
case("FunctionType: closure not a tuple",
     lambda: types.FunctionType(f2.__code__, {}, "n", None, big))
case("CellType: two arguments", lambda: types.CellType(big, big))
case("cell: empty", lambda: types.CellType().cell_contents, True)
case("cell: no such attribute",
     lambda: setattr(types.CellType(), 'zzz', big))


def set_on_function(name, value):
    def g():
        pass
    setattr(g, name, value)


case("function: __code__ = list",
     lambda: set_on_function('__code__', big), True)
case("function: __name__ = list",
     lambda: set_on_function('__name__', big), True)
case("function: __qualname__ = list",
     lambda: set_on_function('__qualname__', big), True)
case("function: __defaults__ = list",
     lambda: set_on_function('__defaults__', big), True)
case("function: __kwdefaults__ = list",
     lambda: set_on_function('__kwdefaults__', big), True)
case("function: __annotations__ = list",
     lambda: set_on_function('__annotations__', big), True)
case("function: no such attribute", lambda: f2.zzz, True)


def closure_mismatch():
    x = big

    def inner():
        return x

    def plain():
        pass
    plain.__code__ = inner.__code__


case("function: __code__ with free variables", closure_mismatch)

# ------------------------------------------------------------ descriptors
class P:
    def __init__(self):
        self._v = big

    @property
    def ro(self):
        return self._v

    @property
    def boom(self):
        raise KeyError(big)

    rw = property(lambda self: self._v, None, None)


po = P()
case("property: no setter", lambda: setattr(po, 'ro', big))
case("property: no deleter", lambda: delattr(po, 'ro'))
case("property: getter raises", lambda: po.boom)
case("property: no getter", lambda: property().__get__(po, P), True)
case("property: __set__ with no setter",
     lambda: property(lambda s: 1).__set__(po, big))
case("property: __delete__ with no deleter",
     lambda: property(lambda s: 1).__delete__(po))
case("property: too many arguments",
     lambda: property(1, 2, 3, 4, big))
case("property: unknown keyword", lambda: property(zzz=big))
case("property.getter: no arguments", lambda: P.ro.getter(), True)
case("staticmethod: no arguments", lambda: staticmethod(), True)
case("classmethod: no arguments", lambda: classmethod(), True)
case("classmethod: two arguments", lambda: classmethod(big, big), True)
case("staticmethod: not callable, called",
     lambda: staticmethod(big)(), True)
case("list.append on a tuple", lambda: list.append((1, 2), big), True)
case("list.append unbound, no receiver", lambda: list.append(), True)
case("str.upper on an int", lambda: str.upper(5), True)
case("int.__add__ on a str", lambda: int.__add__("a", big), True)
case("int.real of a str",
     lambda: int.__dict__['real'].__get__("a"), True)
case("dict.__getitem__ wrapper arity",
     lambda: dict.__getitem__({}, big, big), True)
case("object.__init__ wrapper on nothing",
     lambda: object.__init__(), True)


class Slotted:
    __slots__ = ('a', 'b')


class Other:
    __slots__ = ('a',)


so = Slotted()
case("slot: read before assignment", lambda: so.a, True)
case("slot: delete before assignment", lambda: delattr(so, 'a'), True)
case("slot: no such attribute", lambda: setattr(so, 'zzz', big), True)
case("slot: no __dict__", lambda: so.__dict__, True)
case("slot: descriptor on the wrong class",
     lambda: Slotted.a.__get__(Other()))
case("slot: descriptor set on the wrong class",
     lambda: Slotted.a.__set__(Other(), big))
case("slot: __slots__ names a non-identifier",
     lambda: type('X', (), {'__slots__': ('a b',)}), True)


class Plain:
    pass


class ListSub(list):
    pass


plain = Plain()
case("instance: no such attribute", lambda: plain.zzz, True)
case("instance: delete what is not there",
     lambda: delattr(plain, 'zzz'), True)
case("instance: __dict__ = list",
     lambda: setattr(plain, '__dict__', big), True)


class GetattrBoom:
    def __getattr__(self, name):
        raise KeyError(big)


class SetattrBoom:
    def __setattr__(self, name, value):
        raise KeyError(big)


class DescrBoom:
    def __get__(self, obj, cls):
        raise KeyError(big)

    def __set__(self, obj, value):
        raise KeyError(big)

    def __delete__(self, obj):
        raise KeyError(big)


class HasDescr:
    d = DescrBoom()


hd = HasDescr()
case("__getattr__ raises KeyError", lambda: GetattrBoom().zzz)
case("__getattr__ raises, via getattr()",
     lambda: getattr(GetattrBoom(), 'zzz', None))
case("__getattr__ raises, via hasattr()",
     lambda: hasattr(GetattrBoom(), 'zzz'))
case("__setattr__ raises", lambda: setattr(SetattrBoom(), 'a', big))
case("descriptor __get__ raises", lambda: hd.d)
case("descriptor __get__ raises on the class", lambda: HasDescr.d)
case("descriptor __set__ raises", lambda: setattr(hd, 'd', big))
case("descriptor __delete__ raises", lambda: delattr(hd, 'd'))

# ---------------------------------------------------------------- classes
class NewBoom:
    def __new__(cls, *a):
        raise KeyError(big)


class InitBoom:
    def __init__(self, *a):
        self.held = big
        raise KeyError(big)


class InitReturns:
    def __init__(self):
        return big


class NewReturnsOther:
    def __new__(cls):
        return big

    def __init__(self):
        raise KeyError("never runs")


class MetaBoom(type):
    def __call__(cls, *a):
        raise KeyError(big)


class MetaNewBoom(type):
    def __new__(mcs, name, bases, ns):
        raise KeyError(big)


class ViaMeta(metaclass=MetaBoom):
    pass


class Abstract:
    __abstractmethods__ = frozenset({'area', 'perimeter'})


import abc


class Shape(abc.ABC):
    @abc.abstractmethod
    def area(self):
        pass


case("class: __new__ raises", lambda: NewBoom(big))
case("class: __init__ raises", lambda: InitBoom(big))
case("class: __init__ returns a value", lambda: InitReturns())
case("class: __new__ returns another type",
     lambda: NewReturnsOther() is big)
case("class: metaclass __call__ raises", lambda: ViaMeta(big))
case("class: metaclass __new__ raises",
     lambda: MetaNewBoom('X', (), {}))
case("class: arguments with no __init__", lambda: Plain(big), True)
case("class: keyword with no __init__", lambda: Plain(x=big))
case("class: __init__ missing an argument", lambda: P(big))
case("class: abstract", lambda: Shape(), True)
case("class: object() with an argument", lambda: object(big), True)
case("class: object.__new__ of nothing", lambda: object.__new__(), True)
case("class: object.__new__ of an int",
     lambda: object.__new__(5), True)
case("class: object.__new__ of a list subclass",
     lambda: object.__new__(ListSub))
case("class: object.__new__ with arguments",
     lambda: object.__new__(Plain, big), True)
case("class: type() of two arguments", lambda: type('X', big))
case("class: type() bases is a list", lambda: type('X', [], {}))
case("class: type() dict is a list", lambda: type('X', (), []))
case("class: base is not a class", lambda: type('X', (5,), {}), True)
case("class: base is a str", lambda: type('X', ('a',), {}), True)
case("class: no consistent MRO",
     lambda: type('X', (object, Plain), {}))
case("class: NoneType()", lambda: type(None)(big), True)
case("class: no such class attribute", lambda: Plain.zzz, True)
case("class: set on a builtin type", lambda: setattr(int, 'zzz', big))
case("class: delete a missing class attribute",
     lambda: delattr(Plain, 'zzz'))
case("class: __subclasses__ with an argument",
     lambda: Plain.__subclasses__(big))
case("class: __name__ = int", lambda: setattr(Plain, '__name__', 5))
case("class: mro() with an argument", lambda: Plain.mro(big))
case("struct sequence: too short",
     lambda: type(sys.version_info)((1, 2)))
case("struct sequence: not a sequence",
     lambda: type(sys.version_info)(5))
case("struct sequence: no arguments",
     lambda: type(sys.float_info)())
case("abc: register a non-class",
     lambda: Shape.register(big), True)

# ------------------------------------------------- generators, coroutines
def gen():
    held = big
    x = yield 1
    yield held


def gen_raises():
    held = big
    yield 1
    raise KeyError(held)


def started():
    g = gen()
    next(g)
    return g


def exhausted():
    g = gen()
    list(g)
    return g


async def coro():
    held = big
    return held


class Awaitable:
    def __await__(self):
        yield big


def run(c):
    try:
        while True:
            c.send(None)
    except StopIteration as e:
        return e.value


def closed_coro(c):
    c.close()
    return c


async def agen():
    held = big
    yield 1
    yield held


async def agen_raises():
    held = big
    yield 1
    raise KeyError(held)


def anext_twice():
    a = agen()
    first = a.__anext__()
    second = a.__anext__()
    try:
        first.send(None)
    except StopIteration:
        pass
    try:
        second.send(None)
    finally:
        try:
            second.send(None)
        except Exception:
            pass
        run_quiet(a.aclose())


def run_quiet(c):
    try:
        run(c)
    except Exception:
        pass


def athrow_non_exception():
    a = agen()
    try:
        a.athrow(5).send(None)
    finally:
        run_quiet(a.aclose())


def agen_body_raises():
    a = agen_raises()
    try:
        run(a.__anext__())
        run(a.__anext__())
    finally:
        run_quiet(a.aclose())


def anext_awaited_twice():
    a = agen()
    aw = a.__anext__()
    try:
        run(aw)
        aw.send(None)
    finally:
        run_quiet(a.aclose())


case("generator: throw a non-exception",
     lambda: started().throw(5), True)
case("generator: throw into a new one",
     lambda: gen().throw(KeyError(big)))
case("generator: throw into a finished one",
     lambda: exhausted().throw(KeyError(big)))
case("generator: next of a finished one", lambda: next(exhausted()))
case("generator: send to a finished one",
     lambda: exhausted().send(big))
case("generator: body raises", lambda: list(gen_raises()))
case("generator: send() with no argument", lambda: gen().send())
case("generator: throw() with no argument", lambda: gen().throw())
case("generator: unbound close, no receiver",
     lambda: type(gen()).close(*()), True)
case("generator: cannot be created",
     lambda: type(gen())(), True)
case("generator: no such attribute", lambda: gen().zzz, True)
case("generator: set an attribute", lambda: setattr(gen(), 'zzz', big))
case("generator: gi_code is read-only",
     lambda: setattr(gen(), 'gi_code', big))
case("generator: yield from a non-iterable",
     lambda: list((lambda: (yield from 5))()))
case("coroutine: throw a non-exception",
     lambda: closed_coro(coro()).throw(5))
case("coroutine: cannot be created",
     lambda: types.CoroutineType())
case("coroutine: iter()", lambda: closed_coro(coro()).__iter__)
case("async generator: athrow a non-exception", athrow_non_exception)
case("async generator: body raises", agen_body_raises)
case("async generator: anext while running", anext_twice)
case("async generator: anext awaited twice", anext_awaited_twice)
case("async generator: cannot be created",
     lambda: types.AsyncGeneratorType())
case("async generator: no such attribute", lambda: agen().zzz)


async def _await_int():
    await 5


case("coroutine: await an int", lambda: run(_await_int()))

# ---------------------------------------------------------------- modules
mod = types.ModuleType('m')


hooked = types.ModuleType('hooked')
hooked.__getattr__ = lambda name: (_ for _ in ()).throw(KeyError(big))

case("module: no such attribute", lambda: mod.zzz, True)
case("module: delete a missing attribute", lambda: delattr(mod, 'zzz'))
case("module: __getattr__ raises", lambda: hooked.zzz)
case("module: __getattr__ raises, via hasattr()",
     lambda: hasattr(hooked, 'zzz'))
case("module: no arguments", lambda: types.ModuleType())
case("module: name is not a str", lambda: types.ModuleType(big))
case("module: too many arguments",
     lambda: types.ModuleType('m', 'd', big))
case("module: sys has no such attribute", lambda: sys.zzz, True)

# ------------------------------------------------------------ code objects
co = f2.__code__
case("code: no arguments", lambda: types.CodeType())
case("code: replace an unknown field", lambda: co.replace(zzz=big))
case("code: replace with the wrong type",
     lambda: co.replace(co_name=big))
case("code: no such attribute", lambda: co.zzz, True)
case("code: read-only attribute",
     lambda: setattr(co, 'co_name', big))
case("code: co_positions takes nothing", lambda: co.co_positions(big))

# --------------------------------------------------------- generic aliases
GA = types.GenericAlias
case("GenericAlias: no arguments", lambda: GA())
case("GenericAlias: one argument", lambda: GA(list))
case("GenericAlias: keywords", lambda: GA(list, int, zzz=big))
case("GenericAlias: no such attribute", lambda: GA(list, int).zzz)
case("GenericAlias: call fails underneath",
     lambda: GA(dict, (str, int))(big, big, big))
case("GenericAlias: not generic again",
     lambda: GA(list, int)[big], True)
case("GenericAlias: too many arguments",
     lambda: list[int][str], True)
case("GenericAlias: isinstance",
     lambda: isinstance(big, GA(list, int)), True)
case("GenericAlias: issubclass",
     lambda: issubclass(list, GA(list, int)), True)
case("GenericAlias: __mro_entries__ arity",
     lambda: GA(list, int).__mro_entries__())
case("GenericAlias: subscript a non-generic", lambda: int[big], True)
case("GenericAlias: __class_getitem__ arity",
     lambda: list.__class_getitem__())
print("done")
