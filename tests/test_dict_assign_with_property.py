# `obj.__dict__ = d` replaces the instance dict even when the class has a
# property.  Any data descriptor in the MRO sends a store through the
# descriptor path first, which found the __dict__ getset and called its
# (absent) setter: "attribute '__dict__' of 'C' objects is not writable".
# rich's Console has properties and its reconfigure() swaps __dict__.


class C:
    @property
    def p(self):
        return "prop"


a, b = C(), C()
a.x = 1
b.y = 2
a.__dict__ = b.__dict__
print(vars(a), a.__dict__ is b.__dict__, a.p)
a.__dict__ = {"z": 3}
print(a.z, vars(b))
del a.__dict__
print(vars(a))
for bad in (5, [1]):
    try:
        a.__dict__ = bad
    except TypeError as e:
        print("TypeError:", e)
try:
    a.__weakref__ = 5
except AttributeError as e:
    print("AttributeError:", e)
