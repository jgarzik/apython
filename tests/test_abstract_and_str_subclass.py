# Two entries the old bug list carried that no longer reproduce.
#
# "@abc.abstractmethod is not enforced" -- it is: type_call consults
# __abstractmethods__ and abc's bookkeeping fills it.  The message differed
# too, once, which is why the older checks here compare the exception type
# rather than its text; the block at the end compares the text, because it
# now matches.
#
# "A str subclass has no instance __dict__" -- it has one.  A str keeps its
# characters inline, so the dict cannot sit at a fixed offset past the header;
# TP_DICT_AT_TAIL puts it after the data instead, and bytes and tuple
# subclasses get theirs the same way.

import abc


class Base(abc.ABC):
    @abc.abstractmethod
    def f(self):
        ...

    @abc.abstractmethod
    def g(self):
        ...


class Half(Base):
    def f(self):
        return "f"


class Full(Half):
    def g(self):
        return "g"


print(sorted(Base.__abstractmethods__), sorted(Half.__abstractmethods__))
print(Full.__abstractmethods__ == frozenset())
for cls in (Base, Half):
    try:
        cls()
        print(cls.__name__, "instantiated")
    except TypeError:
        print(cls.__name__, "=> TypeError")
o = Full()
print(o.f(), o.g(), isinstance(o, Base), issubclass(Full, Base))


# A subclass of a variable-size builtin carries an instance dict.
class S(str):
    pass


class B(bytes):
    pass


class T(tuple):
    pass


s = S("hello")
s.x = 1
s.y = [2]
print(s, len(s), s.upper(), s.x, s.y, sorted(s.__dict__))
print(s + "!", s[1:], "ell" in s, S("a") < S("b"))

b = B(b"hi")
b.tag = "t"
print(b, len(b), b.tag, sorted(b.__dict__), b + b"!")

t = T((1, 2))
t.z = 3
print(t, len(t), t.z, sorted(t.__dict__), t + (3,))

# The data and the dict do not tread on each other, whatever the length.
for n in (0, 1, 7, 8, 9, 64, 200):
    v = S("a" * n)
    v.n = n
    if len(v) != n or v.n != n or v != "a" * n:
        print("clash at", n)
print("no clash")

# (An empty __slots__ on a str subclass still gets a dict here, where CPython
# suppresses it.  Recorded in the old bug list; it is not what this file is about.)

# The message names the class and what is missing.
#
# It used to be "Can't instantiate abstract class with abstract methods",
# which names neither -- and those are the two things the reader needs.
# CPython sorts the names and agrees the noun with how many there are.
import abc as _abc

class _One(_abc.ABC):
    @_abc.abstractmethod
    def f(self): ...

class _Two(_abc.ABC):
    @_abc.abstractmethod
    def zebra(self): ...
    @_abc.abstractmethod
    def alpha(self): ...

class _Three(_Two):
    @_abc.abstractmethod
    def middle(self): ...

class _Concrete(_One):
    def f(self): return "concrete"

print()
print("--- the abstract-instantiation message ---")
for _C in (_One, _Two, _Three):
    try:
        _C()
    except TypeError as _e:
        print(_e)
print("a concrete subclass still builds:", _Concrete().f())
