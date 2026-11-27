"""Calling an instance whose class defines __call__, by every route.

`__call__` had no slot_table row, so tp_call stayed 0 on every heaptype and
`x()` worked only because op_call and obj_call_n each hand-rolled a lookup.
Everything that consults tp_call directly did not: `f(*args)` was a TypeError,
`callable()` answered False, and iter(o, sentinel), min/max's key= and the
weakref and signal callback checks all refused a perfectly good callable.

So this file is less about `__call__` than about the paths that reach it.
"""


class Plain:
    def __call__(self, *a, **k):
        return ("Plain", a, sorted(k.items()))


class Sub(Plain):
    pass


class Slotted:
    __slots__ = ()

    def __call__(self, *a, **k):
        return ("Slotted", a, sorted(k.items()))


class Fixed:
    def __call__(self, a, b=2, *, c=3):
        return (a, b, c)


c = Plain()
s = Sub()
sl = Slotted()
f = Fixed()

# --- the direct call, which already worked ----------------------------------

print(c(), s(1), sl(1, 2), f(1), f(1, 2, c=9))
print(c(x=1), f(a=1, c=4))

# --- unpacking, which did not -----------------------------------------------

print(c(*[1, 2]))
print(c(**{"x": 1}))
print(c(*[1], **{"x": 2}))
print(c(*(), **{}))
print(f(*[1, 5], **{"c": 7}))
print(s(*[1, 2], **{"z": 3}))
print(sl(*"ab", **{"k": 1}))

args = [1, 2, 3]
kw = {"p": 1, "q": 2}
print(c(0, *args, r=9, **kw))

# --- callable() --------------------------------------------------------------

print([callable(x) for x in (c, s, sl, f, Plain, Sub, object(), 1, 1.5, None,
                             "x", [], {}, len, print, str.join, "a".join,
                             lambda: 1, type, int, Exception, ValueError(),
                             range, range(3), iter([]), c.__call__)])


class NoCall:
    pass


class Later:
    pass


print(callable(NoCall()), callable(Later()))

# builtins whose instances are callable through a real tp_call.  callable()
# used to answer these from a three-name allowlist, so anything outside it --
# a weakref, an itemgetter -- came back False however genuinely callable it
# was.  It reads tp_call now, the way CPython's PyCallable_Check does.
import functools
import operator

print([callable(x) for x in (operator.itemgetter(0), operator.attrgetter("x"),
                             operator.methodcaller("upper"),
                             functools.partial(len), functools.partial(len, []),
                             property(), classmethod(len), memoryview(b"a"),
                             bytearray(), frozenset(), NotImplemented,
                             Ellipsis, __debug__ if False else ...)])
print(operator.itemgetter(1)([7, 8]), functools.partial(len)("abc"))
Later.__call__ = lambda self: "late"
print(callable(Later()), Later()())
# `del Later.__call__` is not probed: type_install_slots never clears a slot
# it once filled, so a deleted dunder stays installed.  That is a whole family
# -- `del C.__iter__` answers RuntimeError today where CPython answers
# TypeError -- and the old bug list carried it.  It is not specific to __call__.


# `__call__ = None` is not probed: type_install_slots leaves the slot empty
# for any dunder explicitly set to None, which is right for __iter__ and
# __hash__ and makes this tree answer callable() False where CPython answers
# True and then fails inside the call.  The old bug list carried it.

# --- iter(callable, sentinel) ------------------------------------------------


class Counter:
    def __init__(self):
        self.n = 0

    def __call__(self):
        self.n += 1
        return self.n if self.n < 4 else 9


print(list(iter(Counter(), 9)))

# --- key= on the builtins that validate it ----------------------------------


class Key:
    def __call__(self, x):
        return -x


k = Key()
print(min([1, 2, 3], key=k), max([1, 2, 3], key=k), sorted([1, 2, 3], key=k))
print(list(map(k, [1, 2])), list(filter(Plain(), [1, 2])))

# --- the routes that already worked, so a regression in them is caught ------


class Rec:
    def __call__(self, n):
        return n if n <= 0 else self(n - 1)


print(Rec()(5))
print([Plain()(i) for i in range(2)])

bound = c.__call__
print(bound(7), bound(*[8]), callable(bound))


def takes_fn(fn, *a, **k):
    return fn(*a, **k)


print(takes_fn(c, 1, z=2))


class Wrapped:
    def __init__(self, fn):
        self.fn = fn

    def __call__(self, *a, **k):
        return self.fn(*a, **k)


print(Wrapped(len)("abcd"), Wrapped(len)(*["abcde"]))
print(Wrapped(Wrapped(len))(*["abc"]))

# a callable instance used as a decorator, which is the shape that matters


class Deco:
    def __init__(self, fn):
        self.fn = fn

    def __call__(self, *a, **k):
        return ("deco", self.fn(*a, **k))


@Deco
def add(a, b):
    return a + b


print(add(1, 2), add(*[3, 4]), add(**{"a": 5, "b": 6}))

# --- a callable inherited through a deeper MRO -------------------------------


class Mixin:
    def __call__(self, *a):
        return ("mixin", a)


class Left:
    pass


class Diamond(Left, Mixin):
    pass


print(callable(Diamond()), Diamond()(1), Diamond()(*[1, 2]))

# --- __call__ on the metaclass makes the class callable the usual way -------


class Meta(type):
    def __call__(cls, *a, **k):
        return ("meta", a)


class ViaMeta(metaclass=Meta):
    pass


print(callable(ViaMeta), ViaMeta(1), ViaMeta(*[1, 2]))

# --- a non-callable instance still refuses, with CPython's wording ----------

for bad in (NoCall(), 1, 1.5, None, "x", [], {}, object()):
    for how in ("plain", "star"):
        try:
            bad(1) if how == "plain" else bad(*[1])
        except TypeError as e:
            print(how, type(bad).__name__, e)

print("OK")
