# repr() of a bound method whose function is neither a Python function nor a
# builtin.
#
# method_repr routed func_type one way and builtin_func_type another, and for
# anything else read PyBuiltinObject.func_name off it -- whatever sat at +24
# in an object of a different shape, dereferenced as a string.  It is a
# segfault from ordinary Python: types.MethodType over any callable that is
# not one of those two, which is how a class with __call__ binds and what
# CPython's test_descr does.
#
# CPython's method_repr asks the object: __qualname__, then __name__, and "?"
# when neither is a str.  The names are set on the INSTANCE here because a
# class's __qualname__ lives in its tp_dict in this tree and in a getset on
# `type` in CPython, so an instance of a plain class finds one here and not
# there -- a divergence of its own, recorded in the old bug list, and not what this
# file is about.

import types


class C:
    pass


class Callable:
    __qualname__ = "?"          # what CPython's fallback produces anyway

    def __call__(self, *a):
        return 1


def name_of(m):
    return repr(m).split(" of ")[0] + ">"


o = C()

# No names at all.
print(name_of(types.MethodType(Callable(), o)))

# __qualname__ wins.
f = Callable()
f.__qualname__ = "Outer.inner"
f.__name__ = "ignored"
print(name_of(types.MethodType(f, o)))

# A __qualname__ that is PRESENT but not a str gives "?": __name__ is the
# fallback for an absent one only, which is what CPython's
# Py_SETREF(funcname, NULL) after the two lookups amounts to.
f = Callable()
f.__qualname__ = 42
f.__name__ = "not used"
print(name_of(types.MethodType(f, o)))

# __name__ is reached only when there is no __qualname__ at all.
class NoQual:
    def __call__(self, *a):
        return 8


f = NoQual()
f.__name__ = "by_name"
print(name_of(types.MethodType(f, o)))

# An empty name is a name.
f = Callable()
f.__qualname__ = ""
print(name_of(types.MethodType(f, o)))

# A long one is truncated by the buffer, not by a fault.
f = Callable()
f.__qualname__ = "q" * 200
r = repr(types.MethodType(f, o))
print(r.startswith("<bound method " + "q" * 200 + " of "))

# A nested function is the ordinary case and must not have changed.
def outer():
    def inner():
        return 6
    return inner


print(name_of(types.MethodType(outer(), o)))

# The bound method still works, and its repr is stable across calls.
m = types.MethodType(Callable(), o)
print(repr(m) == repr(m), m())

# The two forms that were already right.
class Plain:
    def meth(self):
        return 7


print(name_of(Plain().meth))

print("done")
