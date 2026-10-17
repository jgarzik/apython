# A class made by calling type() -- or types.new_class, which does -- takes
# attribute assignment like one made by a class statement.  With an
# exception base it was "AttributeError: cannot set attribute" for every
# name: the class came out with a metatype carrying no setattr.  Library code
# sets __module__ and __qualname__ on generated classes all the time.
import types

for make in (lambda b: type("T", b, {}),
             lambda b: types.new_class("T", b),
             lambda b: type("T", b, {"x": 1})):
    for bases in ((), (Exception,), (ValueError,), (dict,), (object,)):
        cls = make(bases)
        cls.__module__ = "pkg.mod"
        cls.__qualname__ = "Outer.T"
        cls.extra = 42
        del cls.extra
        print(bases, cls.__module__, cls.__qualname__, hasattr(cls, "extra"),
              type(cls) is type)


# The same STORE_ATTR site, warmed on ordinary classes first, then handed a
# class with an exception base: the cached store must not decide for it.
def setx(cls):
    cls.zz = 1


for b in ((), (object,), (Exception,), (dict,), (ValueError,), ()):
    c = type("W", b, {})
    setx(c)
    print("warm", b, c.zz)


class S(Exception):
    pass


for k in (S, type("F", (Exception,), {}), types.new_class("E", (KeyError,))):
    setx(k)
    print("warm2", k.__name__, k.zz)


# The same helpers, warm, over every way of making a class -- type(),
# types.new_class and a metaclass -- with each kind of base: the load, the
# store and the delete through one site apiece.  types.new_class asks
# type(base) for the metaclass, so type(ValueError) has to be `type` too, or
# the class is built by the exception metatype, which has no setattr of a
# heaptype's.
class M(type):
    mattr = "meta"


def getz(c):
    return c.zz


def getm(c):
    return getattr(c, "mattr", None), c.__name__


def setz(c, v):
    c.zz = v


def delz(c):
    del c.zz


makers = []
for b in ((), (object,), (Exception,), (dict,), (ValueError,), (KeyError,)):
    makers.append(("type", b, lambda b=b: type("W", b, {"zz": 5})))
    makers.append(("new_class", b, lambda b=b: types.new_class(
        "W", b, exec_body=lambda ns: ns.update(zz=5))))
    makers.append(("meta", b, lambda b=b: M("W", b, {"zz": 5})))

for _ in range(3):
    for kind, b, mk in makers:
        c = mk()
        r = [getz(c), getm(c)]
        setz(c, 7)
        r.append(getz(c))
        setz(c, 8)
        r.append(getz(c))
        delz(c)
        r.append(hasattr(c, "zz"))
        print(kind, b, r, type(c).__name__)

# A builtin exception class stays immutable, at a warm site too, and says so
# with CPython's TypeError rather than a generic AttributeError.
for c in (ValueError, KeyError, Exception, int):
    try:
        setz(c, 1)
    except TypeError as e:
        print("TypeError", e)
    try:
        delz(c)
    except (TypeError, AttributeError) as e:
        print(type(e).__name__, e)
print(type(ValueError) is type, type(type("Q", (OSError,), {})) is type)
