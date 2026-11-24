# Slice assignment and deletion on a list or bytearray, when Python runs in
# the middle and changes the container: the iterable being assigned, an
# element's __index__, or the __del__ of an item being displaced.  The bounds
# are clamped again after the value is materialised, and displaced items are
# released only once the list is whole.

class D:
    def __init__(self, v, act=None):
        self.v = v
        self.act = act
    def __repr__(self):
        return 'D%d' % self.v
    def __del__(self):
        if self.act:
            self.act()


def fresh(n=8):
    return [D(i) for i in range(n)]

# del l[i]: the displaced item's __del__ sees the list already without it.
log = []
l = fresh()
l[3] = D(3, lambda: log.append(list(map(repr, l))))
del l[3]
print('del item sees', log, l)

l = fresh()
l[3] = D(3, lambda: l.clear())
del l[3]
print('del item clears', l)

l = fresh()
l[2] = D(2, lambda: l.append(D(99)))
del l[2:6]
print('del slice appends', l)

l = fresh()
l[2] = D(2, lambda: l.clear())
del l[2:6]
print('del slice clears', l)

l = fresh()
l[1] = D(1, lambda: l.clear())
l[1:6] = [D(50)]
print('assign shorter, clears', l)

l = fresh()
l[1] = D(1, lambda: log.append(len(l)))
log.clear()
l[1:3] = [D(50), D(51), D(52), D(53)]
print('assign longer, len seen', log, l)

l = fresh()
l[0] = D(0, lambda: l.clear())
l[::2] = [D(60), D(61), D(62), D(63)]
print('extended assign, clears', l)

l = fresh()
l[0] = D(0, lambda: l.clear())
del l[::2]
print('extended delete, clears', l)

# The iterable mutates the list it is being assigned into.
def shrinking(n):
    for i in range(n):
        if i == 1:
            del l[1:]
        yield D(70 + i)

l = fresh()
l[2:5] = shrinking(3)
print('iter shrinks', l)

def clearing(n):
    for i in range(n):
        if i == 1:
            l.clear()
        yield D(80 + i)

l = fresh()
l[4:6] = clearing(3)
print('iter clears', l)

def growing(n):
    for i in range(n):
        if i == 0:
            l.extend(D(200 + k) for k in range(5))
        yield D(90 + i)

l = fresh()
l[2:4] = growing(2)
print('iter grows', l)

# (An extended slice whose iterable empties the list is left to
# tests/reentry_probe.sh: CPython before 3.12.5 segfaults on it, so it cannot
# be diffed against whichever python3 the oracle happens to be.)

# bytearray: an element's __index__ resizes the target.
class I:
    def __init__(self, v, act=None):
        self.v = v
        self.act = act
    def __index__(self):
        if self.act:
            self.act()
        return self.v

b = bytearray(range(10))
b[2:5] = [I(65), I(66, lambda: b.clear())]
print('bytearray cleared mid-convert', b)

b = bytearray(range(10))
b[2:5] = [I(65), I(66, lambda: b.__delitem__(slice(1, None)))]
print('bytearray shrunk mid-convert', b)

b = bytearray(range(10))
try:
    b[::2] = [I(1), I(2, lambda: b.clear()), I(3), I(4), I(5)]
    print('bytearray extended', b)
except ValueError:
    print('bytearray extended: ValueError', b)

# Ordinary behaviour is unchanged.
l = list(range(10)); l[2:5] = 'ab'; print(l)
l = list(range(10)); l[2:2] = [7, 8]; print(l)
l = list(range(10)); l[::3] = 'wxyz'; print(l)
l = list(range(10)); del l[::3]; print(l)
l = list(range(10)); del l[-3]; print(l)
l = list(range(10)); l[5:] = l; print(l)
l = list(range(10)); l[8:2] = [1]; print(l)
l = list(range(10)); l[::-2] = 'abcde'; print(l)
l = list(range(10)); del l[::-3]; print(l)
b = bytearray(b'0123456789'); b[2:5] = b'ab'; print(b)
b = bytearray(b'0123456789'); b[::2] = b'abcde'; print(b)
