# Every refusal a list makes, and what is left alive after it.
#
# list's slots -- index, slice, assignment, `in`, +, +=, *, *=, the
# comparisons, the constructor -- used to leave non-locally on an error, from
# wherever they were.  They return it now.  Each case here is one refusal;
# the type of the exception is what CPython raises, the list is what it was,
# and the Tracked count says nothing the slot was holding leaked: the
# temporary a generic iterable is drained into, the iterator, the item in
# hand.
import gc


class Boom(Exception):
    pass


class Tracked:
    live = 0

    def __init__(self, v=0):
        self.v = v
        Tracked.live += 1

    def __del__(self):
        Tracked.live -= 1


class IndexRaises:
    def __index__(self):
        raise Boom("index")


class EqRaises:
    def __eq__(self, other):
        raise Boom("eq")


class LtRaises:
    def __eq__(self, other):
        return False

    def __lt__(self, other):
        raise Boom("lt")


class LenRaises:
    def __len__(self):
        raise Boom("len")

    def __iter__(self):
        return iter([1])


class IterRaises:
    def __iter__(self):
        raise Boom("iter")


def gen_raises():
    yield Tracked()
    yield Tracked()
    raise Boom("gen")


def gen_three():
    yield Tracked()
    yield Tracked()
    yield Tracked()


def check(label, fn):
    try:
        r = fn()
    except Exception as e:
        print("%-30s %s%s" % (label, type(e).__name__,
                              ": " + str(e) if isinstance(e, Boom) else ""))
    else:
        print("%-30s %r" % (label, r))


def fresh():
    return [1, 2, 3, 4]


def setitem(key, value):
    x = fresh()
    x[key] = value
    return x


def delitem(key):
    x = fresh()
    del x[key]
    return x


cases = [
    ("x[9]", lambda: fresh()[9]),
    ("x[-9]", lambda: fresh()[-9]),
    ("x['a']", lambda: fresh()["a"]),
    ("x[1.5]", lambda: fresh()[1.5]),
    ("x[None]", lambda: fresh()[None]),
    ("x[raises]", lambda: fresh()[IndexRaises()]),
    ("x[2**70]", lambda: fresh()[2 ** 70]),
    ("x[raises:]", lambda: fresh()[IndexRaises():]),
    ("x[:'a']", lambda: fresh()[:"a"]),
    ("x[::0]", lambda: fresh()[::0]),
    ("x.__getitem__(9)", lambda: fresh().__getitem__(9)),
    ("x[9] = 1", lambda: setitem(9, 1)),
    ("x['a'] = 1", lambda: setitem("a", 1)),
    ("x[raises] = 1", lambda: setitem(IndexRaises(), 1)),
    ("x[1.5] = 1", lambda: setitem(1.5, 1)),
    ("x[raises:] = []", lambda: setitem(slice(IndexRaises(), None), [])),
    ("x[::0] = []", lambda: setitem(slice(None, None, 0), [])),
    ("x[0:1] = 5", lambda: setitem(slice(0, 1), 5)),
    ("x[0:1] = None", lambda: setitem(slice(0, 1), None)),
    ("x[0:1] = iter raises", lambda: setitem(slice(0, 1), IterRaises())),
    ("x[0:1] = gen raises", lambda: setitem(slice(0, 1), gen_raises())),
    ("x[::2] = 5", lambda: setitem(slice(None, None, 2), 5)),
    ("x[::2] = iter raises", lambda: setitem(slice(None, None, 2), IterRaises())),
    ("x[::2] = gen raises", lambda: setitem(slice(None, None, 2), gen_raises())),
    ("x[::2] = gen of 3", lambda: len(setitem(slice(None, None, 2), gen_three()))),
    ("x[::2] = [1]", lambda: setitem(slice(None, None, 2), [1])),
    ("x[::2] = (1, 2, 3)", lambda: setitem(slice(None, None, 2), (1, 2, 3))),
    ("x.__setitem__(9, 1)", lambda: fresh().__setitem__(9, 1)),
    ("del x[9]", lambda: delitem(9)),
    ("del x['a']", lambda: delitem("a")),
    ("del x[raises]", lambda: delitem(IndexRaises())),
    ("del x[raises:]", lambda: delitem(slice(IndexRaises(), None))),
    ("del x[::0]", lambda: delitem(slice(None, None, 0))),
    ("x.__delitem__(9)", lambda: fresh().__delitem__(9)),
    ("1 in [eq raises]", lambda: 1 in [Tracked(), EqRaises()]),
    ("x.__contains__", lambda: [EqRaises()].__contains__(1)),
    ("x + 5", lambda: fresh() + 5),
    ("x + (1,)", lambda: fresh() + (1,)),
    ("x.__add__('a')", lambda: fresh().__add__("a")),
    ("x += 5", lambda: fresh().__iadd__(5)),
    ("x += iter raises", lambda: fresh().__iadd__(IterRaises())),
    ("x += gen raises", lambda: len(fresh().__iadd__(gen_raises()))),
    ("x *= 'a'", lambda: fresh().__imul__("a")),
    ("x *= raises", lambda: fresh().__imul__(IndexRaises())),
    ("x *= 2**40", lambda: fresh().__imul__(2 ** 40)),
    ("x * 2**40", lambda: fresh() * 2 ** 40),
    ("[eq raises] == [1]", lambda: [Tracked(), EqRaises()] == [Tracked(), 1]),
    ("[eq raises] != [1]", lambda: [EqRaises()] != [1]),
    ("[lt raises] < [1]", lambda: [LtRaises()] < [1]),
    ("[lt raises] >= [1]", lambda: [LtRaises()] >= [1]),
    ("x < 5", lambda: fresh() < 5),
    ("list(5)", lambda: list(5)),
    ("list(1, 2)", lambda: list(1, 2)),
    ("list(x=1)", lambda: list(x=1)),
    ("list(iter raises)", lambda: list(IterRaises())),
    ("list(gen raises)", lambda: list(gen_raises())),
    ("list(len raises)", lambda: list(LenRaises())),
]
for label, fn in cases:
    for _ in range(2):
        check(label, fn)
gc.collect()
print("live", Tracked.live)

# The list is what it was after a refused slice assignment.
x = [Tracked(i) for i in range(4)]
for value in (IterRaises(), gen_raises(), 5):
    for key in (slice(1, 3), slice(None, None, 2)):
        try:
            x[key] = value if not hasattr(value, "gi_frame") else gen_raises()
        except (Boom, TypeError):
            pass
        print([t.v for t in x])
try:
    x[::2] = gen_three()
except ValueError:
    pass
print([t.v for t in x])
del x
gc.collect()
print("live", Tracked.live)

# A list changed while it is being sorted.  CPython lets the mutation happen
# and has the sort report it afterwards; here the mutation itself is refused,
# with the same exception.  Either way it is what comes out of sort(), and
# the object that was being added is not left behind.
def sorting(label, mutate):
    lst = [3, 1, 2]

    def key(v):
        mutate(lst)
        return v

    try:
        lst.sort(key=key)
        print("%-22s sorted" % label)
    except ValueError as e:
        print("%-22s ValueError: %s" % (label, e))


sorting("append", lambda l: l.append(Tracked()))
sorting("extend list", lambda l: l.extend([Tracked()]))
sorting("extend gen", lambda l: l.extend(t for t in [Tracked()]))
sorting("+= list", lambda l: l.__iadd__([Tracked()]))
sorting("+= tuple", lambda l: l.__iadd__((Tracked(),)))
sorting("+= gen", lambda l: l.__iadd__(t for t in [Tracked()]))
sorting("x[0:0] = [t]", lambda l: l.__setitem__(slice(0, 0), [Tracked()]))
sorting("insert", lambda l: l.insert(0, Tracked()))
gc.collect()
print("live", Tracked.live)

# dir() tells names apart with ==, over whatever the instance __dict__ is
# keyed by.
class Obj:
    pass


class Key:
    def __init__(self, bad):
        self.bad = bad

    def __hash__(self):
        return 7

    def __eq__(self, other):
        if self.bad or getattr(other, "bad", False):
            raise Boom("key eq")
        return self is other


o = Obj()
vars(o)[5] = 1
check("dir with an int key", lambda: dir(o))
o = Obj()
vars(o)["zzz"] = 1
check("dir with str keys", lambda: "zzz" in dir(o))
check("o.__dir__()", lambda: "zzz" in o.__dir__())
