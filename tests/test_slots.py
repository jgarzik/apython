# Test __slots__

# Basic slots
class Point:
    __slots__ = ('x', 'y')

p = Point()
p.x = 10
p.y = 20
print(p.x)
print(p.y)

# Slots with different types
class Mixed:
    __slots__ = ('name', 'value', 'flag')

m = Mixed()
m.name = "hello"
m.value = 42
m.flag = True
print(m.name)
print(m.value)
print(m.flag)

# AttributeError for non-slot attribute
class Restricted:
    __slots__ = ('a',)

r = Restricted()
r.a = 1
try:
    r.b = 2
except AttributeError:
    print("AttributeError raised for non-slot")

# Unset slot raises AttributeError
class Unset:
    __slots__ = ('x',)

u = Unset()
try:
    _ = u.x
except AttributeError:
    print("AttributeError raised for unset slot")

# Overwrite slot value
class Overwrite:
    __slots__ = ('val',)

o = Overwrite()
o.val = "first"
print(o.val)
o.val = "second"
print(o.val)

# Multiple instances have independent slots
class Pair:
    __slots__ = ('a', 'b')

p1 = Pair()
p2 = Pair()
p1.a = 1
p1.b = 2
p2.a = 10
p2.b = 20
print(p1.a, p1.b)
print(p2.a, p2.b)

# Slots with __init__
class WithInit:
    __slots__ = ('x', 'y')
    def __init__(self, x, y):
        self.x = x
        self.y = y
    def sum(self):
        return self.x + self.y

w = WithInit(3, 4)
print(w.sum())

# Slots with methods
class Counter:
    __slots__ = ('count',)
    def __init__(self):
        self.count = 0
    def increment(self):
        self.count = self.count + 1
    def get(self):
        return self.count

c = Counter()
c.increment()
c.increment()
c.increment()
print(c.get())

# object.__getstate__ answered self.__dict__ or None, and a __slots__ class
# has no instance dict -- so every one of them answered None and lost every
# slot it had.  CPython 3.11+ gives a two-tuple, (None, {name: value}).
#
# There is no name-carrying slot walk anywhere else: instance_traverse and
# instance_dealloc walk the same words by OFFSET, which is all they need.
# The names come from where they are actually recorded -- the member
# descriptors in each type's dict, along the MRO, most derived first.


class Plain:
    pass


class One:
    __slots__ = ('a', 'b')


class NoSlots:
    __slots__ = ()


class Derived(One):
    __slots__ = ('c',)


p = Plain()
print(p.__getstate__())
p.q = 1
print(p.__getstate__())

print(One().__getstate__())          # nothing assigned yet: None
o = One()
o.a = 1
print(o.__getstate__())
o.b = 2
print(o.__getstate__())

print(NoSlots().__getstate__())

d = Derived()
d.a = 1
d.c = 3
print(d.__getstate__())
d2 = Derived()
d2.c = 9
print(d2.__getstate__())

# The values are the objects themselves, not copies.
marker = [1, 2]
o2 = One()
o2.a = marker
state = o2.__getstate__()
print(state[0], state[1]['a'] is marker, sorted(state[1]))

# Deleting a slot takes it back out of the state.
o3 = One()
o3.a = 1
o3.b = 2
del o3.a
print(o3.__getstate__())

# It is still a method on every object, and still takes no arguments.
try:
    o.__getstate__(1)
except TypeError:
    print("TypeError")
print(object().__getstate__())

# __slots__ suppressed the instance dict unconditionally.  Python's rule is
# that it suppresses one only when NO BASE already provides it -- `class C(A)`
# with a plain A inherits A's __dict__, so `c.z = 1` is ordinary and was an
# AttributeError here.  TYPE_FLAG_HAS_SLOTS is what four sites read as "this
# class has no dict": instance_new, instance_setattr's fallback,
# obj_generic_attr's __dict__ arm and vars().
#
# The slots are unaffected either way -- they are laid out past the header,
# and instance_dealloc's and instance_traverse's walks derive the header end
# from tp_dictoffset, which is untouched.
#
# This is also what makes object.__getstate__'s (dict, slots) pair form
# reachable; it could only ever answer (None, {...}) before.


class NoBase:
    pass


class WithDict(NoBase):
    __slots__ = ("y",)


class PureSlots:
    __slots__ = ("a",)


class EmptySlotsOnDict(NoBase):
    __slots__ = ()


class EmptySlotsPure:
    __slots__ = ()


class SlotsOnSlots(PureSlots):
    __slots__ = ("b",)


def show(label, fn):
    try:
        return "%s => %r" % (label, fn())
    except BaseException as e:
        return "%s !! %s: %s" % (label, type(e).__name__, e)


# A base with a dict keeps it.
w = WithDict()
w.y = 5
w.z = 6
print(w.y, w.z, sorted(vars(w)), w.__getstate__())

e = EmptySlotsOnDict()
e.anything = 1
print(vars(e), show("getstate", e.__getstate__))

# A base without one still refuses.
p = PureSlots()
p.a = 1
print(show("pure setattr", lambda: setattr(p, "zz", 1)))
print(show("pure vars", lambda: vars(p)))
print(p.__getstate__())

ep = EmptySlotsPure()
print(show("empty pure setattr", lambda: setattr(ep, "zz", 1)))
print(show("empty pure getstate", ep.__getstate__))

# Slots on top of slots: still no dict, and both levels' slots are present.
ss = SlotsOnSlots()
ss.a = 1
ss.b = 2
print(ss.a, ss.b, show("setattr", lambda: setattr(ss, "zz", 1)))
print(ss.__getstate__())

# A subclass of a __slots__ class that declares none regains a dict, which is
# the behaviour that was already right and must stay.
class Regains(PureSlots):
    pass


r = Regains()
r.a = 1
r.q = 2
print(r.a, r.q, sorted(vars(r)), r.__getstate__())

# Deleting and re-setting through both storage kinds.
w2 = WithDict()
w2.y = 1
w2.z = 2
del w2.z
print(show("deleted dict attr", lambda: w2.z))
del w2.y
print(show("deleted slot", lambda: w2.y))
w2.y = 3
print(w2.y, w2.__getstate__())

# `del obj.attr` stored a NULL into the instance dict instead of removing the
# key.  instance_setattr's dict fallback called dict_set either way, and a
# NULL value means DELETE -- so vars(obj) could not be repr'd, len(vars(obj))
# still counted the deleted name, and deleting a second time succeeded.
# Nothing to do with __slots__; found while testing it.
class Plain:
    pass


d = Plain()
d.z = 2
d.k = 1
del d.z
print(sorted(vars(d)), len(vars(d)), vars(d))
print(show("read deleted", lambda: d.z))
print(show("hasattr", lambda: hasattr(d, "z")))
print(show("delete twice", lambda: delattr(d, "z")))
print(show("delete never-set", lambda: delattr(d, "never")))
d.z = 9
print(d.z, d.k, sorted(vars(d)))


# A subtype of int, bytes or tuple cannot carry slots: int wraps its value
# rather than embedding it, and the other two keep their data inline, so a
# slot laid out at the base's basicsize lands past the allocation.  `class
# N(int): __slots__ = ('tag',)` put the member at offset 48 of a 32-byte
# object, and writing it was a wild store.  CPython refuses the class; so does
# this now, with the same wording.
print("=== slots on a variable-size builtin ===")
for base in ("int", "bytes", "tuple", "float", "list", "dict",
             "set", "frozenset", "bytearray"):
    for decl in ("('tag',)", "()", "['a', 'b']"):
        src = "class X(%s):\n    __slots__ = %s\n" % (base, decl)
        try:
            ns = {}
            exec(src, ns)
            print(base, decl, "built")
        except TypeError as e:
            print(base, decl, "->", e)

# An empty __slots__ is not "nonempty", and is accepted everywhere.
class EmptyInt(int):
    __slots__ = ()


print(EmptyInt(7) + 1, EmptyInt(7).__class__.__name__)

try:
    class Deeper(tuple):
        class_body_runs = True
        __slots__ = ("x",)
except TypeError as e:
    print("nested:", e)

# str is the one CPython accepts and this does not -- our str subclass keeps
# its characters inline and its dict at the tail, so there is nowhere to put a
# fixed-offset slot.  Refusing is the divergence; writing over the characters
# was the alternative, and it was a SIGSEGV.  Either answer passes here, which
# is why this asks whether the outcome was SAFE rather than what it was;
# the old bug list carried the divergence itself.
try:
    class MyStr(str):
        __slots__ = ("s",)
    m = MyStr("hi")
    m.s = "attached"
    safe = str(m) == "hi" and m.s == "attached"
except TypeError:
    safe = True
print("str slots handled safely:", safe)


# A slot declared by a BASE is the subclass's to release too.  The walk used
# to start at the subclass's own base's basicsize, which for `class D(C):
# pass` is the whole layout -- so it found no slots and released none of them,
# and a cycle through one was uncollectable because tp_traverse had the same
# floor.  The dict word sits in the middle of the region when the subclass is
# the one that added it, so the walk skips it rather than starting past it.
print("=== inherited slots are released ===")
import gc


class SA:
    __slots__ = ("a",)


class SB(SA):
    __slots__ = ("b",)


class SC(SA):
    pass


class SD(SC):
    __slots__ = ("d",)


class SE:
    pass


class SF(SE):
    __slots__ = ("f",)


class Tag:
    def __init__(self, name):
        self.name = name

    def __del__(self):
        print("released", self.name)


for cls, names in ((SA, "a"), (SB, "ab"), (SC, "a"), (SD, "ad"), (SF, "f")):
    obj = cls()
    for n in names:
        setattr(obj, n, Tag(cls.__name__ + "." + n))
    del obj
    print("--", cls.__name__)

# A subclass that adds a dict keeps its base's slot below it, and both go.
sc = SC()
sc.a = Tag("SC.a")
sc.other = Tag("SC.other")
del sc

print("=== and a cycle through one is collectable ===")


def make_cycles():
    x = SC()
    x.a = x
    y = SB()
    y.a = y
    y.b = y
    z = SD()
    z.d = z


make_cycles()
print("collected:", gc.collect() >= 3)
print("slots done")
