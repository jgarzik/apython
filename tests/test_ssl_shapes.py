# Three class shapes Lib/ssl.py and lib/_ssl.py lean on, each of which the
# interpreter got wrong until _ssl needed it.

# 1. super(C, C).prop is the property itself, so its setter can be run on an
#    instance -- ssl.SSLContext.options does exactly this.
class Base:
    def __init__(self):
        self._v = 0

    @property
    def value(self):
        return self._v

    @value.setter
    def value(self, v):
        self._v = v * 10


class Derived(Base):
    @property
    def value(self):
        return super().value + 1

    @value.setter
    def value(self, v):
        super(Derived, Derived).value.__set__(self, v)


d = Derived()
d.value = 4
print("super property", d.value, type(super(Derived, Derived).value).__name__)
print("unbound super", type(super(Derived).__get__(None, Derived)).__name__)

# 2. An OSError subclass mixed with ValueError stays an OSError:
#    ssl.SSLCertVerificationError(SSLError, ValueError).
class F(OSError):
    pass


class G(F, ValueError):
    pass


for cls in (G,):
    e = cls(5, "msg")
    print(cls.__name__, e.args, e.errno, e.strerror, str(e))
    e = cls("one")
    print(cls.__name__, e.args, e.errno, e.strerror, str(e))
print("G mro", [c.__name__ for c in G.__mro__])


# 3. An exception class with a metaclass of its own is still a class to
#    `except`.
class Meta(type):
    pass


class MErr(OSError, metaclass=Meta):
    pass


class MSub(MErr, ValueError):
    pass


for exc in (MErr(1, "x"), MSub(2, "y")):
    try:
        raise exc
    except MErr as e:
        print("caught", type(e).__name__, e.errno, e.strerror)
try:
    raise MSub(3, "z")
except ValueError as e:
    print("caught as ValueError", type(e).__name__, str(e))
