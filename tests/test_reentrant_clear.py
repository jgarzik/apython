# clear() on a list or a set, when releasing an element runs Python that
# touches the same container.  The container must already be empty and
# detached by then: each of these was a double free or a read of freed
# memory, visible only under valgrind until the heap layout made it a crash.

class Clr:
    def __del__(self):
        target.clear()

target = [Clr(), Clr()]
target.clear()
print("list clear from __del__:", target)


class App:
    def __del__(self):
        grow.append(7)

grow = [App(), App(), App()]
grow.clear()
print("list append from __del__:", grow)


class Seen:
    def __del__(self):
        seen.append(len(watch))

seen = []
watch = [Seen(), Seen()]
watch.clear()
print("len seen from __del__:", seen)


class H:
    def __init__(self, i):
        self.i = i
    def __hash__(self):
        return self.i
    def __del__(self):
        for k in range(100, 200):
            st.add(k)

st = {H(i) for i in range(8)}
st.clear()
print("set add from __del__:", len(st), sorted(st)[:3])


class SC:
    def __init__(self, i):
        self.i = i
    def __hash__(self):
        return self.i
    def __del__(self):
        st2.clear()

st2 = {SC(i) for i in range(8)}
st2.clear()
print("set clear from __del__:", st2)


# A second __init__ releases what the list held.
class Cnt:
    n = 0
    def __del__(self):
        Cnt.n += 1

l = [Cnt() for _ in range(100)]
l.__init__()
print("__init__ released:", Cnt.n, l)
l = [Cnt() for _ in range(50)]
l.__init__("ab")
print("__init__ with iterable:", Cnt.n, l)

# `l *= 0` is the same clear.
grow2 = None
class App2:
    def __del__(self):
        z.append(1)

z = [App2(), App2()]
z *= 0
print("imul 0:", z)

# Ordinary behaviour is unchanged.
a = list(range(20)); a.clear(); a.append(3); a.extend(range(30))
print(len(a), a[:3], a[-1])
s = set(range(1000)); s.clear(); s.add(5); s.update(range(40))
print(len(s), 5 in s, 999 in s)
f = [1, 2, 3]; f.clear(); f.clear()
print(f, f[0:5], f * 2)
