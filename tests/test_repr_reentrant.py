# A container's repr, when an element's __repr__ runs Python that changes the
# container or raises and catches.  The loop must re-read the size and hold
# the element; and an exception caught INSIDE a nested __repr__ must not make
# the outer container forget it is being printed.

class Shrink:
    def __repr__(self):
        del l[1:]
        return 'A'

l = [Shrink(), object(), object()]
print(repr(l))


class K:
    def __repr__(self):
        d.clear()
        return 'K'
    def __hash__(self):
        return 1

d = {K(): 1}
for i in range(20):
    d[i] = str(i) * 3
print(repr(d))


class DropVal:
    def __repr__(self):
        d2['v'] = None
        return 'DV'

class Val:
    def __repr__(self):
        return 'Val'

d2 = {DropVal(): 0, 'v': Val()}
d2[next(iter(d2))] = Val()
print(repr(d2))


class SK:
    def __repr__(self):
        st.clear()
        return 'SK'

st = {SK()}
print(repr(st))


# The cycle guard survives an exception caught in a nested __repr__.
class Catcher:
    def __repr__(self):
        try:
            {}['k']
        except KeyError:
            pass
        return 'C'

cyc = [Catcher()]
cyc.append(cyc)
print(repr(cyc))

dc = {}
dc['c'] = Catcher()
dc['self'] = dc
print(repr(dc))

t = ([Catcher()],)
t[0].append(t)
print(repr(t))


# One that raises all the way out leaves the guard clean for the next repr.
class Boom:
    def __repr__(self):
        raise ValueError('boom')

for _ in range(3):
    try:
        repr([1, [2, (Boom(),)]])
    except ValueError as e:
        print('raised', e)
again = [1]
again.append(again)
print(repr(again), repr([[[]]]), repr({1: {2: [3]}}))


# Caught at an intermediate level: the outer levels are still guarded.
class Mid:
    def __repr__(self):
        try:
            return repr([Boom()])
        except ValueError:
            return 'mid'

m = [Mid()]
m.append(m)
print(repr(m))
