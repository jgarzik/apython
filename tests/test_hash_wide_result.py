# A __hash__ that returns an int too wide for an immediate hands back an
# OBJECT, and the slot that calls it has to release it.  It did not: every
# hash() of such an instance, and every dict or set lookup with one as the
# key, leaked the int.  `return hash(self.name)` is the usual way to write
# one, and a str's hash is always that wide.
import gc
import sys


class Wide:
    def __hash__(self):
        return 1 << 60


class Named:
    def __init__(self, name):
        self.name = name

    def __hash__(self):
        return hash(self.name)

    def __eq__(self, other):
        return self.name == other.name


class Narrow:
    def __hash__(self):
        return 7


class Minus:
    def __hash__(self):
        return -1


class NotInt:
    def __hash__(self):
        return "x" * 3


def check(label, fn):
    def run():
        try:
            return fn()
        except Exception as e:
            return type(e).__name__
    first = run()
    for _ in range(300):
        run()
    gc.collect()
    before = sys.getallocatedblocks()
    for _ in range(200):
        run()
    gc.collect()
    grew = sys.getallocatedblocks() - before
    print("%-28s %-10s %s" % (label, first, "steady" if grew < 50 else "LEAKS"))


check("hash(Wide())", lambda: hash(Wide()) == 1 << 60)
check("hash(Narrow())", lambda: hash(Narrow()))
check("hash(Minus())", lambda: hash(Minus()))
check("hash(NotInt())", lambda: hash(NotInt()))
check("{}.get(Wide())", lambda: {}.get(Wide()))
check("Wide() in {}", lambda: Wide() in {})
check("{Wide()}", lambda: len({Wide()}))
check("{Wide(): 1}", lambda: len({Wide(): 1}))
check("Named in a dict", lambda: {Named("a"): 1}[Named("a")])
check("Named in a set", lambda: Named("a") in {Named("a")})
check("frozenset of Named", lambda: len(frozenset([Named("a"), Named("b")])))
