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
case("qualname", lambda: type(fresh(), (), {"__qualname__": "Q.N"}))
case("descriptor with __set_name__", lambda: type(fresh(), (), {"d": GoodSetName()}))
case("metaclass from a base", lambda: type(fresh(), (Meta("B", (), {}),), {}))
case("type.__new__ with a metaclass", lambda: type.__new__(Meta, fresh(), (), {}))

print("--- type(): bases that are refused")
case("an int for a base", lambda: type("N", (3,), {}))
case("a str for a base", lambda: type("N", ("a",), {}))
case("bool", lambda: type("B", (bool,), {"a": 1}))
case("bool, fresh name", lambda: type(fresh(), (X, bool), {"a": [1]}))
case("layout conflict", lambda: type("N", (int, str), {"a": 1}))
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
case("__set_name__ raises", lambda: type("N", (), {"d": BadSetName()}), message=False)
case("__set_name__ raises, with slots",
     lambda: type(fresh(), (X,), {"__slots__": "s", "d": BadSetName()}), message=False)
