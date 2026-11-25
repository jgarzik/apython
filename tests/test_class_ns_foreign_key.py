# A class namespace is the caller's: it can hold a key that is not a str,
# whose hash collides with a name type.__new__ looks up and whose __eq__
# raises.  Each such lookup has to hand the error back -- with the half-built
# class released -- or, where CPython's own lookup clears it, carry on.
import gc
import sys


class Odd:
    def __init__(self, name):
        self.h = hash(name)

    def __hash__(self):
        return self.h

    def __eq__(self, other):
        raise ZeroDivisionError("eq")


NAMES = [
    "__slots__", "__qualname__", "__new__", "__module__", "__doc__",
    "__init__", "__hash__", "__eq__", "__init_subclass__",
    "__class_getitem__", "__classcell__", "__classdictcell__", "__dict__",
    "__weakref__", "__abstractmethods__", "__set_name__", "x",
]


def build(name, bases=()):
    return type("C", bases, {Odd(name): 1})


def outcome(fn, *args):
    try:
        fn(*args)
    except Exception as e:
        return type(e).__name__
    return "ok"


for name in NAMES:
    print(name, outcome(build, name))

# int, bytes and tuple subclasses ask about __slots__ before the type exists.
for base in (int, bytes, tuple, str, list):
    print(base.__name__, "__slots__", outcome(build, "__slots__", (base,)))

# A class that was built with such a key is still usable.
C = build("x")
print(type(C()).__name__, len(C.__dict__) > 1)


# Through a class statement, where the namespace is __prepare__'s.
class Meta(type):
    @classmethod
    def __prepare__(mcls, name, bases, **kw):
        return {Odd(kw.get("collide", "x")): 1}

    def __new__(mcls, name, bases, ns, **kw):
        return super().__new__(mcls, name, bases, ns)


def stmt(collide):
    class K(metaclass=Meta, collide=collide):
        pass
    return K


for name in ("__slots__", "__doc__", "__module__", "__qualname__", "x"):
    print("stmt", name, outcome(stmt, name))


# None of the refusals may leak the half-built class.
def climbs(fn, *args):
    for _ in range(300):
        outcome(fn, *args)
    gc.collect()
    before = sys.getallocatedblocks()
    for _ in range(200):
        outcome(fn, *args)
    gc.collect()
    return sys.getallocatedblocks() - before >= 50


for name in NAMES:
    print("leak", name, climbs(build, name))
for name in ("__slots__", "__doc__"):
    print("leak stmt", name, climbs(stmt, name))
