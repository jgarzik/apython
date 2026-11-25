# Class construction that is refused, and class construction that is not:
# what each raises, and that neither leaves anything behind.  Every case runs
# 300 times to warm up and then 200 more around sys.getallocatedblocks(); a
# count that climbs by 50 over those is a leak of at least one block in four
# rounds.
import sys, gc


def flat(fn):
    for _ in range(300):
        fn()
    gc.collect()
    before = sys.getallocatedblocks()
    for _ in range(200):
        fn()
    gc.collect()
    return sys.getallocatedblocks() - before < 50


def case(label, fn, message=True):
    try:
        fn()
        said = "ok"
    except Exception as e:
        said = type(e).__name__
        if message:
            said += ": " + str(e)

    def quiet():
        try:
            fn()
        except Exception:
            pass

    print("%-34s %s | %s" % (label, said, "flat" if flat(quiet) else "CLIMBS"))


class X:
    pass


class Y(X):
    pass


class RaisesInInitSubclass:
    def __init_subclass__(cls, **kw):
        raise ValueError("init_subclass said no")


class TakesKeywords:
    def __init_subclass__(cls, **kw):
        cls.kw = kw


class BadSetName:
    def __set_name__(self, owner, name):
        raise KeyError("set_name said no")


class GoodSetName:
    def __set_name__(self, owner, name):
        self.name = name


class Meta(type):
    pass


class MetaNewRaises(type):
    def __new__(mcls, name, bases, ns):
        raise LookupError("new said no")


class MetaInitRaises(type):
    def __init__(cls, name, bases, ns):
        raise ArithmeticError("init said no")


class MetaPrepareRaises(type):
    @classmethod
    def __prepare__(mcls, name, bases, **kw):
        raise OSError("prepare said no")


class MetaPrepareNone(type):
    @classmethod
    def __prepare__(mcls, name, bases, **kw):
        return None


class MetaKeywords(type):
    def __new__(mcls, name, bases, ns, **kw):
        return super().__new__(mcls, name, bases, ns)

    def __init__(cls, name, bases, ns, **kw):
        super().__init__(name, bases, ns)


class M1(type):
    pass


class M2(type):
    pass


class A1(metaclass=M1):
    pass


class A2(metaclass=M2):
    pass


counter = [0]


def fresh():
    counter[0] += 1
    return "N%d" % counter[0]


print("--- type(): the success paths")
case("fresh name", lambda: type(fresh(), (X,), {"v": 1}))
case("constant name", lambda: type("N", (X,), {"v": 1}))
case("no bases", lambda: type(fresh(), (), {}))
case("slots", lambda: type(fresh(), (), {"__slots__": ("a", "b")}))
case("slots, one name", lambda: type(fresh(), (), {"__slots__": "abc"}))
case("slots twice", lambda: type(fresh(), (), {"__slots__": ("a", "a")}))
case("slots and __dict__", lambda: type(fresh(), (), {"__slots__": ("a", "__dict__")}))
case("slots on a str subclass", lambda: type(fresh(), (str,), {"__slots__": ("a",)}))
case("empty slots on an int subclass", lambda: type(fresh(), (int,), {"__slots__": ()}))
case("qualname", lambda: type(fresh(), (), {"__qualname__": "Q.N"}))
case("descriptor with __set_name__", lambda: type(fresh(), (), {"d": GoodSetName()}))
case("base takes keywords", lambda: type(fresh(), (TakesKeywords,), {}, tag=1))
case("metaclass from a base", lambda: type(fresh(), (Meta("B", (), {}),), {}))
case("type.__new__", lambda: type.__new__(type, fresh(), (X,), {"v": 1}))
case("type.__new__ with a metaclass", lambda: type.__new__(Meta, fresh(), (), {}))



def builtin_bases():
    for base in (list, dict, int, tuple, float, bytes, str, set, ValueError, type, property):
        type(fresh(), (base,), {})


def operator_dunders():
    ns = {"__len__": lambda self: 0, "__add__": lambda self, other: self,
          "__getitem__": lambda self, key: key}
    a = type(fresh(), (), dict(ns))
    b = type(fresh(), (a,), {"__neg__": lambda self: self})
    c = type(fresh(), (b, list), {"__contains__": lambda self, x: True})
    del a
    assert len(b()) == 0 and 3 in c() and c()[4] == 4
    b.__mul__ = lambda self, other: 7
    assert b() * 2 == 7 and c() * 2 == 7


print("--- type(): what a class with operators owns")
case("a builtin for a base", builtin_bases)
case("dunders, and subclasses of them", operator_dunders)

print("--- type(): bases that are refused")
case("an int for a base", lambda: type("N", (3,), {}))
case("a str for a base", lambda: type("N", ("a",), {}))
case("bool", lambda: type("B", (bool,), {"a": 1}))
case("bool, fresh name", lambda: type(fresh(), (X, bool), {"a": [1]}))
case("layout conflict", lambda: type("N", (int, str), {"a": 1}))
case("layout conflict, subclasses",
     lambda: type("N", (type("L", (list,), {}), type("D", (dict,), {})), {}))
case("inconsistent MRO", lambda: type("N", (object, int), {"a": 1}), message=False)
case("inconsistent MRO, own classes", lambda: type("N", (X, Y), {"a": 1}), message=False)

print("--- type(): __slots__ that are refused")
case("on an int subclass", lambda: type("N", (int,), {"__slots__": ("a",)}))
case("on a tuple subclass", lambda: type("N", (tuple,), {"__slots__": ["a"]}))
case("on a bytes subclass", lambda: type("N", (bytes,), {"__slots__": ("a",)}))
case("__dict__ twice", lambda: type("N", (), {"__slots__": ("__dict__", "__dict__")}))
case("__dict__ over a base's", lambda: type("N", (X,), {"__slots__": ("__dict__",)}))
case("not a str", lambda: type("N", (), {"__slots__": ("a", 1)}))
case("not an identifier", lambda: type("N", (), {"__slots__": ("a", "b c")}))
case("a class variable", lambda: type("N", (), {"__slots__": ("a",), "a": 1}))
case("a class variable, mangled", lambda: type("N", (), {"__slots__": ("__a",), "_N__a": 1}))
case("a class variable, one name", lambda: type("N", (), {"__slots__": "a", "a": 1}))
case("__slots__ itself", lambda: type("N", (), {"__slots__": ("__slots__",)}))
case("__doc__ with no docstring", lambda: type(fresh(), (), {"__slots__": ("__doc__",)}))
case("__doc__ with a docstring",
     lambda: type("N", (), {"__slots__": ("__doc__",), "__doc__": "d"}))
case("__module__ not in the namespace", lambda: type(fresh(), (), {"__slots__": ("__module__",)}))
case("__module__ in the namespace",
     lambda: type("N", (), {"__slots__": ("__module__",), "__module__": "m"}))

print("--- type(): the namespace")
case("__qualname__ not a str", lambda: type("N", (), {"__qualname__": 3, "a": [1]}))
case("__classcell__ not a cell", lambda: type("N", (), {"__classcell__": 3}))
case("__classcell__ None", lambda: type("N", (X,), {"__classcell__": None, "a": [1]}))
case("__classdictcell__ not a cell", lambda: type("N", (), {"__classdictcell__": "x"}))

print("--- type(): the hooks")
case("__init_subclass__ raises", lambda: type("N", (RaisesInInitSubclass,), {"v": [1]}))
case("__init_subclass__ raises, fresh",
     lambda: type(fresh(), (X, RaisesInInitSubclass), {"__slots__": ("a",)}))
case("a keyword nothing takes, type()", lambda: type("N", (X,), {}, tag=1), message=False)
case("__set_name__ raises", lambda: type("N", (), {"d": BadSetName()}), message=False)
case("__set_name__ raises, with slots",
     lambda: type(fresh(), (X,), {"__slots__": "s", "d": BadSetName()}), message=False)


class EntriesRaise:
    def __mro_entries__(self, bases):
        raise ZeroDivisionError("mro_entries said no")


class EntriesNotTuple:
    def __mro_entries__(self, bases):
        return [X]


class EntriesGood:
    def __mro_entries__(self, bases):
        return (X, )


def s_plain():
    class N(X):
        v = 1


def s_keywords():
    class N(TakesKeywords, tag=1, other=[2]):
        pass
    assert N.kw == {"tag": 1, "other": [2]}


def s_slots():
    class N(X):
        __slots__ = ("a", "__b")

        def get(self):
            return __class__


def s_metaclass():
    class N(X, metaclass=Meta):
        v = [1]


def s_metaclass_keywords():
    class N(metaclass=MetaKeywords, tag=1):
        pass


def s_metaclass_base_keywords():
    class N(TakesKeywords, metaclass=Meta, tag=1):
        pass
    assert N.kw == {"tag": 1}


def s_metaclass_function():
    class N(X, metaclass=lambda name, bases, ns: 42):
        pass
    assert N == 42


def s_mro_entries():
    class N(EntriesGood()):
        pass
    assert N.__orig_bases__ != N.__bases__


def s_super():
    class N(Y):
        def f(self):
            return super().__init__()
    N().f()


def s_bad_keyword():
    class N(X, tag=1):
        pass


def s_bad_keyword_metaclass():
    class N(X, metaclass=Meta, tag=1):
        pass


def s_bool():
    class N(bool):
        v = [1]


def s_layout():
    class N(int, str):
        pass


def s_mro():
    class N(X, Y):
        pass


def s_conflict():
    class N(A1, A2):
        pass


def s_conflict_explicit():
    class N(A1, metaclass=M2):
        pass


def s_slots_int():
    class N(int):
        __slots__ = ("a",)


def s_slots_conflict():
    class N:
        __slots__ = ("a",)
        a = 1


def s_slots_module():
    class N:
        __slots__ = ("__module__",)


def s_qualname():
    class N:
        __qualname__ = 3


def s_classcell():
    class N(metaclass=lambda name, bases, ns: type(name, bases, dict(ns, __classcell__=3))):
        def f(self):
            return __class__


def s_body_raises():
    class N(X, tag=1):
        v = [1]
        raise IndexError("body said no")


def s_init_subclass():
    class N(RaisesInInitSubclass, tag=[1]):
        v = [1]


def s_set_name():
    class N(X):
        d = BadSetName()


def s_meta_new():
    class N(X, metaclass=MetaNewRaises):
        v = [1]


def s_meta_init():
    class N(X, metaclass=MetaInitRaises):
        v = [1]


def s_prepare_raises():
    class N(X, metaclass=MetaPrepareRaises, tag=1):
        v = [1]


def s_prepare_none():
    class N(X, metaclass=MetaPrepareNone):
        v = [1]


def s_prepare_none_no_bases():
    class N(metaclass=MetaPrepareNone):
        v = [1]


def s_metaclass_not_callable():
    class N(X, metaclass=3):
        pass


def s_entries_raise():
    class N(X, EntriesRaise()):
        pass


def s_entries_not_tuple():
    class N(EntriesNotTuple(), X):
        pass


print("--- type() and type.__new__: the metaclass, and arguments of the wrong kind")
case("metaclass conflict", lambda: type("N", (A1, A2), {"a": [1]}))
case("metaclass conflict, called", lambda: M1("N", (A2,), {"a": [1]}))
case("metaclass conflict, type.__new__", lambda: type.__new__(M1, "N", (A2,), {}))
case("a base's metaclass wins", lambda: type(type.__new__(type, fresh(), (A1,), {})) is M1 or 1 / 0)
case("keywords through type.__new__",
     lambda: type.__new__(type, fresh(), (TakesKeywords,), {}, tag=1).kw["tag"])
case("keywords through a metaclass", lambda: MetaKeywords(fresh(), (TakesKeywords,), {}, tag=1))
case("a keyword nothing takes, called", lambda: Meta("N", (X,), {}, tag=1), message=False)
case("type.__new__ of nothing", lambda: type.__new__(), message=False)
case("type.__new__ of too little", lambda: type.__new__(type, "N"), message=False)
case("the name is an int", lambda: type.__new__(type, 1, (), {}))
case("the bases are an int", lambda: type.__new__(type, "N", 3, {}))
case("a base is an int", lambda: type.__new__(type, "N", (X, 3), {}))
case("the namespace is an int", lambda: type.__new__(type, "N", (), 3))
case("the namespace is a list", lambda: type.__new__(type, "N", (), [1]))
case("the metaclass is int", lambda: type.__new__(int, "N", (), {}))
case("the metaclass is 3", lambda: type.__new__(3, "N", (), {}))
case("type.__init__ of two", lambda: type.__init__(int, 1, 2))
case("type() of an int name", lambda: type(1, (), {}), message=False)
case("type() of int bases", lambda: type("N", 3, {}), message=False)
case("type() of an int namespace", lambda: type("N", (), 3), message=False)
case("type() of two", lambda: type("N", ()))

print("--- the class statement: the success paths")
case("plain", s_plain)
case("keywords", s_keywords)
case("slots and a class cell", s_slots)
case("metaclass", s_metaclass)
case("metaclass taking keywords", s_metaclass_keywords)
case("metaclass, base takes keywords", s_metaclass_base_keywords)
case("metaclass is a function", s_metaclass_function)
case("__mro_entries__", s_mro_entries)
case("super()", s_super)

print("--- the class statement: refused")
case("a keyword nothing takes", s_bad_keyword, message=False)
case("the same, through a metaclass", s_bad_keyword_metaclass, message=False)
case("bool", s_bool)
case("layout conflict", s_layout)
case("inconsistent MRO", s_mro, message=False)
case("metaclass conflict", s_conflict)
case("metaclass conflict, explicit", s_conflict_explicit)
case("__slots__ on an int subclass", s_slots_int)
case("__slots__ and a class variable", s_slots_conflict)
case("__slots__ naming __module__", s_slots_module)
case("__qualname__ not a str", s_qualname)
case("__classcell__ not a cell", s_classcell)
case("the body raises", s_body_raises)
case("__init_subclass__ raises", s_init_subclass)
case("__set_name__ raises", s_set_name, message=False)
case("metaclass __new__ raises", s_meta_new)
case("metaclass __init__ raises", s_meta_init)
case("__prepare__ raises", s_prepare_raises)
case("__prepare__ returns None", s_prepare_none)
case("the same, with no bases", s_prepare_none_no_bases)
case("metaclass is not callable", s_metaclass_not_callable, message=False)
case("__mro_entries__ raises", s_entries_raise)
case("__mro_entries__ not a tuple", s_entries_not_tuple)

print("--- __build_class__ called by hand")
case("no arguments", lambda: __build_class__())
case("not a function", lambda: __build_class__(None, "N", X))
case("not a name", lambda: __build_class__(lambda: None, 3, X, tag=[1]))
