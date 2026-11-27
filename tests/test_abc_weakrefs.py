# The _abc registry and its caches hold weak references.
#
# They held strong ones, so a class registered against an ABC -- or merely
# asked about once, which fills a cache -- lived as long as the ABC did.
# Registries are process-lifetime, so that is a leak with no upper bound on
# what it holds: a class, its dict, its methods, and whatever those close
# over.  The old bug list said "revisit if _weakref lands"; it has.
#
# A ref with no callback is SHARED here, so the same class always yields the
# same object.  That is what makes a set lookup find what a registration put
# there: no special comparison is needed, and a weakref hashes as its
# referent does.

import abc
import gc
import _weakref as weakref


class Base(abc.ABC):
    pass


class Other(abc.ABC):
    pass


def registered_then_dropped():
    class Temp:
        pass
    Base.register(Temp)
    ok = issubclass(Temp, Base)
    return ok, weakref.ref(Temp)


ok, ref = registered_then_dropped()
print("registered        ", ok)
gc.collect()
print("collected         ", ref() is None)


def cached_then_dropped():
    """A class nobody registered, but that a check asked about."""
    class Probe:
        pass
    negative = issubclass(Probe, Base)
    class Yes:
        pass
    Base.register(Yes)
    positive = issubclass(Yes, Base)
    issubclass(Yes, Base)          # again, so the positive cache answers
    return negative, positive, weakref.ref(Probe), weakref.ref(Yes)


neg, pos, probe_ref, yes_ref = cached_then_dropped()
print("negative, positive", neg, pos)
gc.collect()
print("both collected    ", probe_ref() is None, yes_ref() is None)


# Everything still answers, with the dead entries still sitting in the sets.
class Live:
    pass


Base.register(Live)
print("a live one        ", issubclass(Live, Base), isinstance(Live(), Base))
print("not registered    ", issubclass(int, Base))
Base.register(int)
print("after registering ", issubclass(int, Base), isinstance(3, Base))
print("a different ABC   ", issubclass(Live, Other))


# Registration through a subclass counts for the base, which is the walk that
# has to dereference what it finds.
class Middle(Base):
    pass


class ViaMiddle:
    pass


Middle.register(ViaMiddle)
print("through a subclass", issubclass(ViaMiddle, Middle), issubclass(ViaMiddle, Base))


# A registration whose class dies leaves the answer to the others.
def dies_between():
    class Gone:
        pass
    Base.register(Gone)
    return weakref.ref(Gone)


gone = dies_between()
gc.collect()
print("gone              ", gone() is None)
print("others unaffected ", issubclass(Live, Base), issubclass(ViaMiddle, Base))


# The abstract-method machinery is untouched by any of it.
class WithAbstract(abc.ABC):
    @abc.abstractmethod
    def m(self):
        ...


try:
    WithAbstract()
    print("abstract          ", "instantiated?")
except TypeError as exc:
    print("abstract          ", str(exc).startswith("Can't instantiate"))


class Concrete(WithAbstract):
    def m(self):
        return "m"


print("concrete          ", Concrete().m())
print("done")
