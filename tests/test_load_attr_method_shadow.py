"""A warm method cache notices an instance attribute that shadows the class.

LOAD_ATTR_METHOD (203) guards on the receiver's type and on that type's dict
version.  Neither says anything about the INSTANCE dict, so once a site was
warm, `c.m = something` was ignored and `c.m()` went on calling the class's
method -- a wrong answer, not a slow one.

It needs the SAME call site to run before and after the shadow.  A fresh site
is cold and takes the generic path, so the obvious test -- warm it in a loop,
then read `c.m` on the next line -- passes while the bug is live.  Every case
below funnels through one function for that reason.

The old bug list described this hazard as something a hypothetical new opcode would
have to avoid.  It was already live: 203 has been installed for classes
written in Python since the method-load work, and its guards were the ones
written for a static builtin type, whose instances have no dict to shadow
with.
"""


class C:
    def m(self):
        return "class"

    def n(self):
        return "class-n"


def call_m(o):
    return o.m()


def call_n(o):
    return o.n()


def get_m(o):
    return o.m


def warm(fn, o, n=300):
    for _ in range(n):
        fn(o)


print("--- an instance attribute shadows a warm site ---")
c = C()
warm(call_m, c)
print("warm:", call_m(c))
c.m = lambda: "instance"
print("shadowed:", call_m(c))
del c.m
print("unshadowed:", call_m(c))

print("--- and through a plain load, not only a call ---")
d = C()
warm(get_m, d)
print("warm:", get_m(d)())
d.m = lambda: "instance"
print("shadowed:", get_m(d)())
del d.m
print("unshadowed:", get_m(d)())

print("--- one instance shadowing does not disturb another ---")
a, b = C(), C()
warm(call_m, a)
warm(call_m, b)
a.m = lambda: "only-a"
print("a:", call_m(a), "b:", call_m(b))
del a.m
print("a again:", call_m(a))

print("--- an unrelated instance attribute leaves the method alone ---")
e = C()
warm(call_m, e)
e.other = 1
print("other set:", call_m(e))
e.m = lambda: "now-m"
print("m set too:", call_m(e))

print("--- replacing the method on the class ---")
f = C()
warm(call_n, f)
print("warm:", call_n(f))
C.n = lambda self: "replaced"
print("replaced:", call_n(f))

print("--- deleting it from the class ---")


class D:
    def p(self):
        return "D.p"


def call_p(o):
    return o.p()


g = D()
warm(call_p, g)
print("warm:", call_p(g))
D.p = lambda self: "D.p2"
print("changed:", call_p(g))

print("--- a subclass overriding it ---")


class Base:
    def q(self):
        return "base"


class Sub(Base):
    pass


def call_q(o):
    return o.q()


s = Sub()
warm(call_q, s)
print("warm:", call_q(s))
Sub.q = lambda self: "sub"
print("overridden:", call_q(s))

print("--- __slots__ has no dict to shadow with ---")


class Slotted:
    __slots__ = ("v",)

    def r(self):
        return "slotted"


def call_r(o):
    return o.r()


sl = Slotted()
warm(call_r, sl)
print("slotted:", call_r(sl))
sl.v = 1
print("after a slot store:", call_r(sl))

print("--- a builtin receiver still specializes ---")
def upper(s):
    return s.upper()


warm(upper, "abc")
print("builtin:", upper("abc"), upper("xy"))

print("--- a property is not a method ---")


class WithProp:
    @property
    def val(self):
        return "prop"


def get_val(o):
    return o.val


w = WithProp()
warm(get_val, w)
print("property:", get_val(w))

print("done")


# Pick a collision whose perturbation slot differs from the next linear slot.
def check_shadow():
    class Worker:
        pass

    for suffix in range(100):
        name = "method" + str(suffix)
        name_hash = hash(name)
        first = name_hash & 7
        displaced = (first * 5 + (name_hash >> 5) + 1) & 7
        if displaced not in (first, (first + 1) & 7):
            break
    else:
        raise AssertionError("no displaced name")

    setattr(Worker, name, lambda self: "type")
    invoke = eval("lambda worker: worker." + name + "()")
    worker = Worker()
    assert invoke(worker) == "type"

    for suffix in range(100):
        other = "other" + str(suffix)
        if hash(other) & 7 == first:
            setattr(worker, other, None)
            break
    else:
        raise AssertionError("no collision")

    setattr(worker, name, lambda: "instance")
    return invoke(worker)

print(check_shadow())
