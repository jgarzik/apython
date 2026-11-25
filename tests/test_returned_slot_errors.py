# The last callers that jumped into the unwinder when a slot they called
# through returned an error -- the set and dict operators, str.join and
# bytes.join, str.translate's length probe, the separator of bytes.hex and a
# format field's subscript -- now hand it to their own exit.  Each case is
# the exception that reaches Python and whether two hundred rounds of it
# leave the block count where it was.
#
# `d |= x` is the one that could have gone wrong quietly: a binary slot's 0
# means NotImplemented unless an exception is pending, and reading it as
# "declined" would turn update's ValueError into the dispatch's TypeError.
import gc
import sys


class Boom(Exception):
    pass


def name_of(fn):
    try:
        fn()
    except BaseException as e:
        return "%s: %s" % (type(e).__name__, e)
    return "no error"


def check(label, fn):
    first = name_of(fn)
    for _ in range(300):
        name_of(fn)
    gc.collect()
    before = sys.getallocatedblocks()
    for _ in range(200):
        name_of(fn)
    gc.collect()
    grew = sys.getallocatedblocks() - before
    print("%-30s %s | %s" % (label, first, "steady" if grew < 50 else "LEAKS"))


class BadEq:
    def __hash__(self):
        return 7

    def __eq__(self, other):
        raise Boom("eq")


class BadIter:
    def __iter__(self):
        raise Boom("iter")


class BadLen:
    def __len__(self):
        raise Boom("len")

    def __getitem__(self, i):
        raise IndexError(i)


class BadItem:
    def __getitem__(self, k):
        raise Boom("item")


def ior(x):
    d = {}
    d |= x
    return d


check("d |= 'ab'", lambda: ior("ab"))
check("d |= 5", lambda: ior(5))
check("d |= BadIter()", lambda: ior(BadIter()))
check("{} | 5", lambda: {} | 5)

check("set | set, eq raises", lambda: {BadEq()} | {BadEq()})
check("set & set, eq raises", lambda: {BadEq()} & {BadEq()})
check("set - set, eq raises", lambda: {BadEq()} - {BadEq()})
check("set ^ set, eq raises", lambda: {BadEq()} ^ {BadEq()})
check("set | list", lambda: set() | [1])

check("update(BadIter())", lambda: {}.update([BadIter()]))
check("update([5])", lambda: {}.update([5]))
check("''.join(BadIter())", lambda: "".join(BadIter()))
check("''.join(5)", lambda: "".join(5))
check("b''.join(BadIter())", lambda: b"".join(BadIter()))
check("b''.join(5)", lambda: b"".join(5))
check("translate(BadLen())", lambda: "abc".translate(BadLen()))
check("bytes.hex(BadLen())", lambda: b"ab".hex(BadLen()))
check("format {0[k]}, item raises", lambda: "{0[k]}".format(BadItem()))
check("format {0[k]}, no item", lambda: "{0[k]}".format({}))
check("format_map, item raises", lambda: "{k}".format_map(BadItem()))
