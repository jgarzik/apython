# itertools as CPython's C module behaves: every iterator is a class of its
# own, the arguments are checked with CPython's wordings, the inputs are
# consumed in CPython's order and amount, groupby's groups and tee's
# branches share one underlying iterator, and pickling round-trips under the
# 3.12 deprecation.  Diffed against python3.

import copy
import gc
import operator
import pickle
import sys
import warnings
import weakref
from fractions import Fraction
from itertools import *
import itertools


def show(label, f):
    try:
        r = f()
    except Exception as e:
        print(label, "->", type(e).__name__, e)
    else:
        print(label, "->", r)


class Counted:
    """An iterator over range(n) that records how far it was pulled."""

    def __init__(self, n):
        self.n = n
        self.i = 0

    def __iter__(self):
        return self

    def __next__(self):
        if self.i >= self.n:
            raise StopIteration
        self.i += 1
        return self.i - 1


# -- types, names, modules, __iter__ ---------------------------------------

print("== types")
objs = [accumulate([1]), batched([1], 1), chain([1]), combinations([1], 1),
        combinations_with_replacement([1], 1), compress([1], [1]), count(),
        cycle([1]), dropwhile(bool, [1]), filterfalse(None, [1]),
        groupby([1]), islice([1], 1), pairwise([1]), permutations([1]),
        product([1]), repeat(1), starmap(pow, []), takewhile(bool, [1]),
        tee([1])[0], zip_longest([1])]
for o in objs:
    t = type(o)
    print(t.__name__, t.__module__, iter(o) is o, isinstance(t, type),
          hasattr(t, "__reduce__"))
g = groupby("aab")
k, grp = next(g)
print(type(grp).__name__, type(grp).__module__)
with warnings.catch_warnings():
    warnings.simplefilter("ignore", DeprecationWarning)
    print(type(tee("a")[0].__reduce__()[2][0]).__name__)
print(sorted(n for n in dir(itertools) if not n.startswith("_")),
      all(hasattr(itertools, n) for n in ("_grouper", "_tee", "_tee_dataobject")))
print(chain[int], chain.from_iterable.__name__)
print(hasattr(islice, "__class_getitem__"), hasattr(count, "__class_getitem__"))

# -- reprs and length hints ------------------------------------------------

print("== repr")
for args in [(), (5,), (5, 2), (5.0,), (10.5, 1), (10.5, 1.0), (10, 1.0),
             (-9, 0), (5, True), (True,), (Fraction(1, 3), Fraction(1, 2)),
             (1 + 2j,), (2**70, 3)]:
    c = count(*args)
    first = next(c)
    print(args, repr(count(*args)), repr(first), type(first).__name__,
          repr(c))
c = count(sys.maxsize - 1)
next(c)
next(c)
print(repr(c) == "count(%d)" % (sys.maxsize + 1))
r = repeat("a", 3)
print(repr(r), repr(repeat(1 + 0j)), repr(repeat("a", -2)), list(r), repr(r))
print(operator.length_hint(repeat(None, 5)), operator.length_hint(repeat(None, -1)),
      operator.length_hint(repeat(None), 12))
show("repeat(1).__length_hint__()", lambda: repeat(1).__length_hint__())
class Sub(count):
    pass
print(repr(Sub(3)), repr(type("R", (repeat,), {})(1, 2)))

# -- argument validation ---------------------------------------------------

print("== validation")
for a in [(-1,), (2**100,), (None, "a"), ("a",), (1.0,), (1, -1), (1, -5),
          (1, 2, 0), (1, 2, "x"), (-5, 10), (0, None, 2**100), (None,),
          (None, None, None), (3, None, 2)]:
    show("islice%r" % (a,), lambda: list(islice(range(10), *a)))
show("islice()", lambda: islice())
show("islice(1 arg)", lambda: islice([]))
show("islice(5 args)", lambda: islice([], 1, 2, 3, 4))
show("islice kw", lambda: islice([], stop=1))
show("chain kw", lambda: chain([], x=1))
show("cycle()", lambda: cycle())
show("cycle kw", lambda: cycle([], x=1))
show("takewhile 1", lambda: takewhile(bool))
show("dropwhile 3", lambda: dropwhile(bool, [], 1))
show("starmap 3", lambda: starmap(pow, [], 1))
show("filterfalse 1", lambda: filterfalse(None))
show("pairwise kw", lambda: pairwise(iterable=[]))
show("pairwise 0", lambda: pairwise())
show("repeat times None", lambda: repeat(1, None))
show("repeat times str", lambda: repeat(1, "x"))
show("repeat kw", lambda: list(repeat(object="o", times=2)))
show("count str", lambda: count("a"))
show("count step str", lambda: count(1, "b"))
show("count kw", lambda: next(count(start=3, step=4)))
show("permutations r str", lambda: permutations("abc", "s"))
show("permutations r neg", lambda: permutations("abc", -1))
show("permutations r=None", lambda: list(permutations("ab", None)))
show("combinations neg", lambda: combinations("abc", -2))
show("cwr neg", lambda: combinations_with_replacement("abc", -2))
show("zip_longest fv", lambda: zip_longest("a", fv=1))
show("zip_longest 2kw", lambda: zip_longest("a", fillvalue=1, x=2))
show("product kw", lambda: product("a", x=1))
show("product neg", lambda: product("a", repeat=-1))
show("product repeat=0", lambda: list(product("ab", repeat=0)))
show("tee neg", lambda: tee([], -1))
show("tee n str", lambda: tee([], "x"))
show("tee 0", lambda: tee([1], 0))
show("batched 0", lambda: batched("a", 0))
show("batched str", lambda: batched("a", "x"))
show("accumulate positional initial", lambda: list(accumulate([10, 20], 100)))
show("starmap non-iterable args", lambda: list(starmap(pow, [None])))

# -- consumption and laziness ----------------------------------------------

print("== consumption")
for a in [(3,), (3, 3), (4, 1), (2, 5, 2), (0, 0), (1, 3, 50), (0, None, 3)]:
    it = Counted(10)
    out = list(islice(it, *a))
    print("islice", a, out, it.i, next(it, None))
c = count()
print(list(islice(c, 1, 3, 50)), next(c))
it = Counted(10)
s = islice(it, 2)
print(list(s), list(s), it.i)

data, sel = Counted(5), Counted(5)
print(list(compress(data, iter([1, 0]))), data.i)
a, b = Counted(2), Counted(5)
z = zip_longest(a, b)
print(next(z), next(z), next(z), a.i, b.i)
a, b = Counted(3), Counted(1)
print(list(zip_longest(a, b, fillvalue="-")), a.i, b.i)
srcs = [Counted(3), Counted(3)]
p = product(*srcs)
print([s.i for s in srcs], next(p))
srcs = [Counted(4)]
cb = combinations(srcs[0], 2)
print(srcs[0].i, next(cb))
it = Counted(5)
tw = takewhile(lambda x: x < 2, it)
print(list(tw), it.i, list(tw))
it = Counted(5)
dw = dropwhile(lambda x: x < 2, it)
print(next(dw), it.i)
it = Counted(7)
bt = batched(it, 3)
print(next(bt), it.i, list(bt), it.i)
it = Counted(5)
pw = pairwise(it)
print(next(pw), it.i)
print(list(chain.from_iterable(repeat(range(3), 2))))
print(list(islice(chain.from_iterable(repeat(range(5))), 2)))


def gen1(hist):
    hist.append(0)
    yield 1
    hist.append(1)
    raise ValueError("boom")


hist = []
show("chain error", lambda: list(chain(gen1(hist), [2])))
print(hist)
cy = cycle(Counted(3))
print([next(cy) for _ in range(7)])

# -- groupby ---------------------------------------------------------------

print("== groupby")
calls = []


def key(x):
    calls.append(x)
    return x // 10


gb = groupby([1, 2, 11, 12, 13, 21], key)
k1, g1 = next(gb)
print(k1, next(g1), calls)
k2, g2 = next(gb)
print(k2, list(g1), list(g2), calls)
print([(k, list(g)) for k, g in gb], calls)
s = list(zip("AABBBAAAA", range(9)))
it = groupby(s, operator.itemgetter(0))
_, g1 = next(it)
_, g2 = next(it)
_, g3 = next(it)
print(list(g1), list(g2), next(g3))
list(it)
print(list(g3))
print([k for k, g in groupby("AAAABBBCCDAABBB")])
print([list(g) for k, g in groupby("AAAABBBCCD")])
print([k for k, g in groupby([])], list(groupby([], key=id)))


class AlwaysEq:
    def __init__(self, v):
        self.v = v

    def __eq__(self, other):
        print("eq", self.v, other.v)
        return True


print([len(list(g)) for k, g in groupby([1, 2, 3], AlwaysEq)])

# -- tee -------------------------------------------------------------------

print("== tee")
src = Counted(200)
a, b = tee(src)
print([next(a) for _ in range(3)], src.i, next(b), src.i)
print(len(list(a)), src.i, len(list(b)))
a, b = tee("abc")
c, d = tee(a)
print(type(c) is type(a))
e = copy.copy(b)
print(list(b), list(e), list(c), list(d))
a, b = tee(range(2000), 3)[:2]
print(next(a), list(islice(b, 1998, None)), next(a))
t = type(tee("x")[0])
print(list(t("def")))
show("_tee()", lambda: t())
show("_tee(10)", lambda: t(10))
print([list(x) for x in tee("ab", 3)])


class Reenter:
    first = True

    def __iter__(self):
        return self

    def __next__(self):
        first = self.first
        self.first = False
        if first:
            return next(tb)


ta, tb = tee(Reenter())
show("tee re-enter", lambda: next(ta))
a, b = tee(range(10))
p = weakref.proxy(a)
print(p.__class__ is type(b))
del a
gc.collect()
show("dead proxy", lambda: p.__class__)

# -- pairwise re-entry and accumulate --------------------------------------

print("== pairwise / accumulate")


def check(reenter_at, n):
    class I:
        count = 0

        def __iter__(self):
            return self

        def __next__(self):
            self.count += 1
            if self.count in reenter_at:
                return next(it)
            return [self.count]

    it = pairwise(I())
    print(reenter_at, [next(it) for _ in range(n)])


check({1}, 2)
check({2}, 3)
check({1, 4}, 3)
print(list(accumulate([1, 2, 3])), list(accumulate([1, 2, 3], initial=10)),
      list(accumulate([], initial=5)), list(accumulate("abc")),
      list(accumulate([2, 8, 9, 5], max)), list(accumulate(iterable=[1, 1])))

# -- combinatorics ---------------------------------------------------------

print("== combinatorics")
print(list(permutations(range(3), 2)))
print(list(combinations("ABCD", 2)))
print(list(combinations_with_replacement("ABC", 2)))
print(list(product("ab", range(2), repeat=1)), list(product()))
print(list(combinations("ab", 5)), list(permutations("ab", 5)),
      list(combinations_with_replacement("", 2)),
      list(combinations_with_replacement("", 0)))
print(len(list(product(range(4), repeat=4))))
r1 = next(combinations("abc", 2))
print(type(r1), r1)

# -- pickling, copying, and the 3.12 deprecation ----------------------------

print("== pickle")


def norm(x):
    if isinstance(x, tuple) and len(x) == 2 and type(x[1]) is type(grp):
        return (x[0], list(x[1]))
    return x


def below3(x):
    return x < 3


def roundtrip(it, take=1):
    for _ in range(take):
        next(it, None)
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        out = []
        for proto in range(pickle.HIGHEST_PROTOCOL + 1):
            out.append([norm(x) for x in
                        islice(pickle.loads(pickle.dumps(it, proto)), 8)])
        out.append([norm(x) for x in islice(copy.deepcopy(it), 8)])
    msgs = sorted({str(x.message) for x in w})
    cats = sorted({x.category.__name__ for x in w})
    same = all(o == out[0] for o in out)
    print(type(it).__name__, same, out[0], cats, msgs)


for mk in [lambda: accumulate(range(6)), lambda: accumulate(range(4), initial=7),
           lambda: accumulate([None, None, None], operator.is_),
           lambda: chain("abc", "de"), lambda: combinations(range(4), 2),
           lambda: combinations_with_replacement("ab", 2),
           lambda: compress("ABCDEF", [1, 0, 1, 0, 1, 1]),
           lambda: count(3, 2), lambda: cycle("abc"),
           lambda: dropwhile(below3, range(6)),
           lambda: filterfalse(None, [0, 1, 0, 2]),
           lambda: groupby("aabbc"),
           lambda: islice(range(20), 2, 15, 3),
           lambda: permutations(range(3), 2),
           lambda: product("ab", range(2)), lambda: repeat("x", 4),
           lambda: starmap(pow, [(2, 3), (3, 2)]),
           lambda: takewhile(below3, range(6)),
           lambda: tee("abcdef")[0], lambda: zip_longest("ab", "wxyz")]:
    try:
        roundtrip(mk())
    except Exception as e:
        print("pickle failed", type(e).__name__, e)
for o in (pairwise("abc"), batched("abc", 2)):
    show("pickle " + type(o).__name__, lambda: pickle.dumps(o))
    show("copy " + type(o).__name__, lambda: copy.copy(o))
with warnings.catch_warnings():
    warnings.simplefilter("error", DeprecationWarning)
    show("pickle as error", lambda: pickle.dumps(count()))
with warnings.catch_warnings():
    warnings.simplefilter("ignore", DeprecationWarning)
    it = chain()
    it.__setstate__((iter(["abc", "def"]), iter(["ghi"])))
    print(list(it))
    for bad in [(), [], 0, ([],), (iter([]), [])]:
        show("chain.__setstate__(%s)" % type(bad).__name__,
             lambda: chain().__setstate__(bad))
    c = cycle("defg")
    c.__setstate__((list("abc"), 0))
    print("".join(islice(c, 12)))
    show("cycle setstate list", lambda: cycle("d").__setstate__([[], 0]))
    show("cycle setstate tuple", lambda: cycle("d").__setstate__((("a",), 0)))
    p = product((1, 2), (3,))
    p.__setstate__((0, 0x1000))
    print(next(p))
    # A protocol-0 pickle CPython 2.7 wrote: cycle over iter([1, 2, 3])
    # advanced once, with [1] already saved.
    old = (b'citertools\ncycle\n(c__builtin__\niter\n((lI1\naI2\naI3\n'
           b'atRI1\nbtR((lI1\naI0\ntb.')
    print(list(islice(pickle.loads(old), 7)))
    s = list(zip("AABBBAAAA", range(9)))
    it = groupby(s, operator.itemgetter(0))
    _, g = next(it)
    next(it)
    print(list(pickle.loads(pickle.dumps(g))))

# -- subclasses and keywords -----------------------------------------------

print("== subclasses")
for cls, args in [(repeat, (1, 2)), (filterfalse, (None, [0, 1])),
                  (chain, ([1, 2], [3, 4])), (starmap, (pow, ((2, 3), (3, 2)))),
                  (islice, ([1, 2, 3, 4], 1, 3)), (takewhile, (bool, [2, 3, 0])),
                  (dropwhile, (bool, [2, 0, 4])), (cycle, ([1, 2],)),
                  (compress, ("ABC", [1, 0, 1]))]:
    class subclass(cls):
        pass

    u = subclass(*args)
    print(cls.__name__, type(u) is subclass, list(islice(u, 0, 3)), end=" ")
    try:
        subclass(*args, newarg=3)
        print("accepted", end=" ")
    except TypeError:
        print("refused", end=" ")
    if cls not in (repeat, compress):
        class with_init(cls):
            def __init__(self, *args, newarg=None):
                self.newarg = newarg

        u = with_init(*args, newarg=3)
        print(list(islice(u, 0, 3)), u.newarg)
    else:
        print()

# -- builtins that call user code end on its StopIteration -----------------

print("== StopIteration from a mapped function")


def stopper(x):
    if x == 2:
        raise StopIteration
    return x


def yf():
    yield from map(stopper, range(5))
    yield "after"


print(list(map(stopper, range(5))), tuple(map(next, [iter("a"), iter("")])),
      list(filter(stopper, range(5))), list(yf()))


def roundrobin(*iterables):
    iterators = map(iter, iterables)
    for num_active in range(len(iterables), 0, -1):
        iterators = cycle(islice(iterators, num_active))
        yield from map(next, iterators)


print(list(roundrobin("ABC", "D", "EF")))
