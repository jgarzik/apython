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
import sys

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


def check(label, fn, message=True):
    first = one(fn)
    if not message:
        first = first.split(":")[0]
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

# ---- __instancecheck__ and __subclasscheck__ --------------------------------
check("isinstance, hook raises", lambda: isinstance(1, Checked))
check("issubclass, hook raises", lambda: issubclass(int, Checked))
check("isinstance, in a tuple", lambda: isinstance(1, (str, Checked)))
check("issubclass, in a tuple", lambda: issubclass(int, (str, Checked)))
check("isinstance, answer's bool", lambda: isinstance(1, CheckedTruth))
check("issubclass, answer's bool", lambda: issubclass(int, CheckedTruth))

for line in results:
    print(line)
