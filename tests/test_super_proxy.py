# super() through a proxy that forwards attribute access.
#
# CPython's supercheck asks three questions: is the object an instance of the
# class, is it a subclass of the class, and -- the third -- does it SAY it is an
# instance of the class.  The third is what makes super() work through a proxy,
# and is what test_descr.test_proxy_super is for.
#
# op_load_super_attr asked all three; super_check, which every shape that does
# NOT compile to LOAD_SUPER_ATTR goes through, asked only the first two.  Both
# raise the same sentence, so the difference read as position-dependent --
# the old bug list recorded it as an answer that changed when an unrelated later
# statement was deleted.  It is not: it is which of two code paths the shape
# compiles to.


class Proxy(object):
    def __init__(self, obj):
        self.__obj = obj

    def __getattribute__(self, name):
        if name.startswith("_Proxy__"):
            return object.__getattribute__(self, name)
        return getattr(self.__obj, name)


class B(object):
    def f(self):
        return "B.f"

    @classmethod
    def g(cls):
        return "B.g:" + cls.__name__


class C(B):
    def f(self):
        return "C.f"

    @classmethod
    def g(cls):
        return "C.g"


def opcode_form(obj):
    return super(C, obj).f()


def two_step(obj):
    s = super(C, obj)
    return s.f()


def getattr_form(obj):
    return getattr(super(C, obj), "f")()


def passed_along(obj):
    s = super(C, obj)
    return (lambda u: u.f())(s)


def own_attrs(obj):
    s = super(C, obj)
    return (s.__self_class__.__name__, s.__thisclass__.__name__,
            s.__self__ is obj)


p = Proxy(C())
for name, fn in (("opcode", opcode_form), ("two-step", two_step),
                 ("getattr", getattr_form), ("passed", passed_along)):
    try:
        print(name, "->", fn(p))
    except Exception as e:
        print(name, "->", type(e).__name__, e)

print("own attrs:", own_attrs(p))

# CPython's own shape: the function taken out of the class dict and called with
# the proxy as self.
print("unbound:", C.__dict__["f"](p))

# A proxy of the CLASS reaches the classmethod form, where the object is a
# subclass rather than an instance.
print("classmethod:", C.g())

# The refusals have to keep refusing.  An object that is neither an instance
# nor a subclass nor says it is one of either gets the TypeError.
class Unrelated(object):
    pass


for bad in (Unrelated(), 1, "x", 1.5, [1], object()):
    try:
        s = super(C, bad)
        print("accepted", type(bad).__name__, "->", s)
    except TypeError as e:
        print("refused", type(bad).__name__, "->", e)

# A __class__ that lies about something unrelated is still refused.
class LiesAboutInt(object):
    @property
    def __class__(self):
        return int


try:
    super(C, LiesAboutInt())
    print("lying object accepted")
except TypeError as e:
    print("lying object refused:", e)

# ...and one that names a real subclass is accepted, by both paths.
class Sub(C):
    pass


class SaysSub(object):
    @property
    def __class__(self):
        return Sub

    def f(self):
        return "SaysSub.f"


says = SaysSub()
s = super(C, says)
print("says-subclass self_class:", s.__self_class__.__name__)
print("says-subclass f:", s.f())
print("says-subclass opcode:", super(C, says).f())

# super(C, None) is the unbound form, and answers nothing.
s = super(C, None)
print("unbound self:", s.__self__, "self_class:", s.__self_class__)

print("done")
