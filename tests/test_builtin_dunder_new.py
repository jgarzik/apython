"""A builtin that keeps its constructor in tp_new must still publish __new__.

The stdlib asks by NAME.  `super().__new__(cls, ...)` resolves along the MRO,
and a builtin whose constructor is only a slot has nothing there -- so the
search runs on to object.__new__, which refuses a type whose real constructor
is elsewhere.  That is:

  * every subclass that writes its own __new__ and chains to the base, which
    is how `_CallableGenericAlias` in _collections_abc is written -- so
    `collections.abc.Callable[[int], int]` raised outright;
  * every copy.copy, copy.deepcopy and pickle of a subclass of one of them,
    because the reduce protocol reconstructs through __new__.

The old bug list recorded this for `bytes`.  It is a family.
"""

import collections
import copy
import types


def check_published(t):
    assert '__new__' in t.__dict__, t.__name__
    assert t.__new__ is not object.__new__, t.__name__


def test_published_on_every_slot_constructor():
    for t in (staticmethod, classmethod, property, slice,
              type(None), type(...), type(NotImplemented),
              types.MethodType, types.GenericAlias, types.SimpleNamespace,
              type(type.__dict__)):
        check_published(t)


def test_callable_generic_alias():
    import collections.abc as abc
    a = abc.Callable[[int], int]
    assert type(a).__name__ == '_CallableGenericAlias', type(a).__name__
    assert repr(a) == 'collections.abc.Callable[[int], int]', repr(a)
    assert a.__args__ == (int, int), a.__args__


def test_generic_alias_subclass_keeps_its_class():
    class G(types.GenericAlias):
        __slots__ = ()

    g = G(list, (int,))
    assert type(g) is G, type(g)
    assert g.__origin__ is list
    assert g.__args__ == (int,)


def test_subclass_new_chains_to_the_base():
    class S(staticmethod):
        def __new__(cls, f):
            return super().__new__(cls, f)

    class C:
        m = S(lambda: 7)

    assert C.m() == 7

    class N(types.SimpleNamespace):
        def __new__(cls, **kw):
            return super().__new__(cls)

    n = N(a=1)
    assert isinstance(n, N)


def test_namespace_subclass_round_trips():
    class N(types.SimpleNamespace):
        pass

    n = N(a=1, b=[2])
    again = copy.deepcopy(n)
    assert again.a == 1 and again.b == [2]
    assert again.b is not n.b
    assert type(again) is N


def test_deque_and_property_subclasses_still_build():
    class D(collections.deque):
        pass

    d = D([1, 2, 3])
    assert list(d) == [1, 2, 3]

    class P(property):
        pass

    class C:
        @P
        def x(self):
            return 11

    assert C().x == 11


for fn in (test_published_on_every_slot_constructor,
           test_callable_generic_alias,
           test_generic_alias_subclass_keeps_its_class,
           test_subclass_new_chains_to_the_base,
           test_namespace_subclass_round_trips,
           test_deque_and_property_subclasses_still_build):
    fn()
    print(fn.__name__, 'ok')
print('OK')
