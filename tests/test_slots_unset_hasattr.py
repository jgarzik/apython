# An unassigned __slots__ slot is ABSENT, and every way of asking has to see
# that: hasattr() answers False and getattr() takes its default.  The slot's
# AttributeError used to unwind straight out of the lookup, past hasattr()'s
# own native frame -- babel's PluralRule.__call__ asks hasattr(self, "_func")
# on exactly such a slot.  A __getattr__ that says "absent" for a slot name
# must not hand back the member descriptor either.
class G:
    __slots__ = ('x',)
    def __getattr__(self, n):
        raise AttributeError("hook " + n)
g = G()
try:
    print(g.x)
except AttributeError as e:
    print("AE", e)
print(hasattr(g, 'x'), getattr(g, 'x', 5))
class S:
    __slots__ = ('x',)
s = S()
try:
    s.x
except AttributeError as e:
    print("AE", e, e.name, e.obj is s)
try:
    s.x()
except AttributeError as e:
    print("AE2", e)
try:
    getattr(s, 'x')
except AttributeError as e:
    print("AE3", e)
print(hasattr(s, 'x'), getattr(s, 'x', 9))
s.x = 3
print(hasattr(s, 'x'), getattr(s, 'x', 9), s.x)
del s.x
print(hasattr(s, 'x'))
class T(S):
    def f(self):
        return super().__getattribute__('x')
try:
    T().f()
except AttributeError as e:
    print("AE4", e)
print(S.x.__get__(s, S) if hasattr(s, 'x') else "unset")
try:
    S.x.__get__(s, S)
except AttributeError as e:
    print("AE5", e)
try:
    object.__getattribute__(s, 'x')
except AttributeError as e:
    print("AE6", e)
for i in range(3):
    try:
        s.x
    except AttributeError:
        print("loop", i)

import weakref
class S2:
    __slots__ = ('x', 'y', '__weakref__')
    __match_args__ = ('x',)
s = S2()
match s:
    case S2(x=1):
        print("x1")
    case S2(y=2):
        print("y2")
    case S2():
        print("plain")
match s:
    case S2(_):
        print("pos")
    case _:
        print("nopos")
try:
    s.x()
except AttributeError as e:
    print("call", e)
p = weakref.proxy(s)
try:
    p.x
except AttributeError as e:
    print("proxy", e)
print(hasattr(p, 'x'))
import operator
try:
    operator.attrgetter('x')(s)
except AttributeError as e:
    print("ag", e)
import copy
s.y = 4
c = copy.copy(s)
print(hasattr(c, 'x'), c.y)
import pickle
c = pickle.loads(pickle.dumps(s))
print(hasattr(c, 'x'), c.y)
