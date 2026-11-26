# A method descriptor knows the class it was found on.
#
# Distinguish an unbound descriptor from a module-level builtin so
# multiprocessing registers the descriptor reducer for the right type.
import copyreg
import inspect
import sys

assert type(str.count).__name__ == "method_descriptor"
assert type(list.append) is not type(len)
assert not hasattr(list.append, "__self__")
assert inspect.ismethoddescriptor(list.append)
assert not inspect.ismethoddescriptor(len)

# --- __objclass__ ------------------------------------------------------
print("str.count:", str.count.__objclass__)
print("list.append:", list.append.__objclass__)
print("list.__len__:", list.__len__.__objclass__)
print("dict.get:", dict.get.__objclass__)
print("str.maketrans:", getattr(str.maketrans, "__objclass__", "<absent>"))
print("len:", getattr(len, "__objclass__", "<absent>"))

# --- __self__ ----------------------------------------------------------
# A module-level builtin's __self__ is its module, and a bound one's is its
# receiver.
print("len.__self__:", len.__self__)
print("bound:", "x".upper.__self__)

# int.__new__ keeps its __self__: copyreg._reduce_ex walks the MRO comparing
# `base.__new__.__self__ is base` to find the last non-heap base, and without
# it every protocol-0 and protocol-1 reduction is an AttributeError.
print("int.__new__.__self__:", int.__new__.__self__)
print("str.__new__.__self__:", str.__new__.__self__)


class Q(int):
    pass


print("copyreg base:", copyreg._reconstructor is not None,
      Q(5).__reduce_ex__(1)[1][1])

# --- __reduce__, which is what reads them ------------------------------
for f in (str.count, tuple.count, list.append, list.__len__, str.maketrans,
          dict.get):
    r = f.__reduce__()
    print("%-18s %s" % (getattr(f, "__name__", "?"),
                        (r[0].__name__, r[1][0].__name__, r[1][1])
                        if isinstance(r, tuple) else r))

# A module-level builtin still reduces to its bare name.
print("len reduce:", len.__reduce__())

# And the round trip those reductions exist for.
for f in (str.count, list.append, list.__len__, tuple.count, dict.get):
    g = f.__reduce__()
    back = g[0](*g[1])
    print("roundtrip %-14s %s" % (getattr(f, "__name__", "?"), back is f))

# --- the repr, which reads func_kind too -------------------------------
# Addresses are stripped: they are not the same between two interpreters, and
# which WORDING each one gets is the thing func_kind decides.
import re

for o in (str.count, list.__len__, str.maketrans, len, "x".upper):
    print(re.sub(r"0x[0-9a-f]+", "0xX", repr(o)))
print("survived")
