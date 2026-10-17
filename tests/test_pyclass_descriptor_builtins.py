# The builtins that reach attributes without the attribute opcodes --
# setattr(), delattr(), getattr() on a class -- and a data descriptor written
# in Python; and memoryview()/bytes() over a class with __buffer__ (PEP 688).


class D:
    def __get__(self, inst, owner=None):
        return ("get", inst is None, owner.__name__ if owner else None)

    def __set__(self, inst, value):
        print("set", value)

    def __delete__(self, inst):
        print("delete")


class A:
    x = D()


a = A()
setattr(a, "x", 1)
a.x = 2
object.__setattr__(a, "x", 3)
delattr(a, "x")
del a.x
print(a.__dict__)
print(a.x, getattr(a, "x"))
print(A.x, getattr(A, "x"))


class B:
    pass


B.y = D()            # added after the class was built
b = B()
setattr(b, "y", 4)
print(b.__dict__, getattr(B, "y"))


class Meta(type):
    pass


class C(metaclass=Meta):
    pass


type.__setattr__(C, "z", D())
print(C.z, getattr(C, "z"), getattr(C(), "z"))


class OnlyGet:
    def __get__(self, inst, owner=None):
        return "plain"


class E:
    g = OnlyGet()


e = E()
setattr(e, "g", "shadow")     # a non-data descriptor is shadowed
print(e.g, e.__dict__)


class Buf:
    def __init__(self, data):
        self.data = bytearray(data)

    def __buffer__(self, flags):
        return memoryview(self.data)


bb = Buf(b"abc")
m = memoryview(bb)
print(bytes(m), bytes(bb), m.readonly, len(m))
m[0] = ord("z")
print(bb.data)


class Raises:
    def __buffer__(self, flags):
        raise ValueError("no buffer")


for f in (memoryview, bytes):
    try:
        f(Raises())
    except ValueError as exc:
        print(f.__name__, "ValueError", exc)


class Wrong:
    def __buffer__(self, flags):
        return b"not a view"


try:
    memoryview(Wrong())
except TypeError as exc:
    print("TypeError", exc)

print(bytes([1, 2, 3]), bytes(3))
