# Builtins handed arguments they must refuse -- and that used to be a
# segfault rather than a refusal.  Each was found by tests/raise_probe.sh,
# which calls every builtin with arguments of the wrong type and count; the
# ones here read a class's fields off something that was not a class, took
# an int out of something that was not an int, or indexed an argument array
# past the arguments it was given.
#
# The type AND the message are printed: all of these are CPython's wording.
import sys
import _abc
import _sre
import _weakref


def t(label, f):
    try:
        r = f()
        print(label, "-> returned", type(r).__name__)
    except Exception as e:
        print(label, "->", type(e).__name__ + ":", e)


# --- _abc: the state is read off the argument, so it has to be a class ---
for name in ("_reset_registry", "_reset_caches", "_get_dump"):
    fn = getattr(_abc, name)
    for a in (1.5, -1, "s", [], b"b", None):
        t("_abc.%s(%r)" % (name, a), lambda: fn(a))
    t("_abc.%s(zzz=1)" % name, lambda: fn(zzz=1))
    t("_abc.%s()" % name, lambda: fn())
    t("_abc.%s(1, 2)" % name, lambda: fn(1, 2))

for name in ("_abc_subclasscheck", "_abc_instancecheck"):
    fn = getattr(_abc, name)
    t("_abc.%s()" % name, lambda: fn())
    t("_abc.%s(None)" % name, lambda: fn(None))
    t("_abc.%s(None, 1, 2)" % name, lambda: fn(None, 1, 2))
    t("_abc.%s(None, 1, 2, 3)" % name, lambda: fn(None, 1, 2, 3))
    t("_abc.%s(None, 1, 2, 3, 4, 5, 6, 7)" % name,
      lambda: fn(None, 1, 2, 3, 4, 5, 6, 7))
    for a in (1.5, -1, "s", [], None):
        t("_abc.%s(%r, int)" % (name, a), lambda: fn(a, int))

t("_abc._abc_register()", lambda: _abc._abc_register())
t("_abc._abc_register(None, 1, 2)", lambda: _abc._abc_register(None, 1, 2))

# The accepted forms still work.
import abc


class Base(abc.ABC):
    pass


class Impl:
    pass


Base.register(Impl)
print(issubclass(Impl, Base), isinstance(Impl(), Base), issubclass(int, Base))
print(type(_abc._get_dump(Base)).__name__, len(_abc._get_dump(Base)))
print(_abc._reset_registry(Base))
print(_abc._reset_caches(Base))
# ...and the second argument is asked what it is, too.
t("_abc._abc_subclasscheck(Base, 1)", lambda: _abc._abc_subclasscheck(Base, 1))
t("_abc._abc_instancecheck(Base, 1)", lambda: _abc._abc_instancecheck(Base, 1))
t("_abc._abc_register(1.5, int)", lambda: _abc._abc_register(1.5, int))

# --- sys.set_int_max_str_digits: an int, not whatever was passed ---
for a in (1.5, [], "s", None):
    t("sys.set_int_max_str_digits(%r)" % (a,),
      lambda: sys.set_int_max_str_digits(a))
t("sys.set_int_max_str_digits(-1)", lambda: sys.set_int_max_str_digits(-1))
t("sys.set_int_max_str_digits(100)", lambda: sys.set_int_max_str_digits(100))
t("sys.set_int_max_str_digits(1, 2)",
  lambda: sys.set_int_max_str_digits(1, 2))
t("sys.set_int_max_str_digits(maxdigits=1.5)",
  lambda: sys.set_int_max_str_digits(maxdigits=1.5))
old = sys.get_int_max_str_digits()
t("sys.set_int_max_str_digits(5000)", lambda: sys.set_int_max_str_digits(5000))
print(sys.get_int_max_str_digits())
t("sys.set_int_max_str_digits(maxdigits=0)",
  lambda: sys.set_int_max_str_digits(maxdigits=0))
print(sys.get_int_max_str_digits())
sys.set_int_max_str_digits(old)

# --- property.getter / setter / deleter take one positional argument ---
for m in ("getter", "setter", "deleter"):
    t("property().%s(zzz=1)" % m, lambda: getattr(property(), m)(zzz=1))
    t("property().%s()" % m, lambda: getattr(property(), m)())
    t("property().%s(1, 2)" % m, lambda: getattr(property(), m)(1, 2))
    t("property().%s(len)" % m, lambda: getattr(property(), m)(len))

# --- _weakref._remove_dead_weakref(dict, key) ---
t("_remove_dead_weakref()", lambda: _weakref._remove_dead_weakref())
t("_remove_dead_weakref(None)", lambda: _weakref._remove_dead_weakref(None))
t("_remove_dead_weakref(None, 1, 2)",
  lambda: _weakref._remove_dead_weakref(None, 1, 2))
t("_remove_dead_weakref(None, 1, 2, 3, 4)",
  lambda: _weakref._remove_dead_weakref(None, 1, 2, 3, 4))
t("_remove_dead_weakref(None, 1, 2, 3, 4, 5, 6, 7)",
  lambda: _weakref._remove_dead_weakref(None, 1, 2, 3, 4, 5, 6, 7))
t("_remove_dead_weakref(None, 1)",
  lambda: _weakref._remove_dead_weakref(None, 1))
t("_remove_dead_weakref([], 1)",
  lambda: _weakref._remove_dead_weakref([], 1))
t("_remove_dead_weakref({}, 1)",
  lambda: _weakref._remove_dead_weakref({}, 1))

# --- _sre.compile takes six arguments and no more ---
t("_sre.compile(None, 1, 2, 3, 4, 5, 6)",
  lambda: _sre.compile(None, 1, 2, 3, 4, 5, 6))
t("_sre.compile(None, 1, 2, 3, 4, 5, 6, 7)",
  lambda: _sre.compile(None, 1, 2, 3, 4, 5, 6, 7))
print("done")
