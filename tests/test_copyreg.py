"""copyreg's public surface, including the extension registry.

__all__ named add_extension, remove_extension and clear_extension_cache while
the module defined none of them, so `copyreg.add_extension(...)` was an
AttributeError and CPython's own pickle.py -- which opens with

    from copyreg import _extension_registry, _inverted_registry, _extension_cache

-- could not import at all.  Nothing here registers an extension code, which
is exactly why it went unnoticed: `from copyreg import *` does not check that
the names in __all__ exist (the old bug list carried that), so the promise was never
tested against the module.
"""

import copyreg


def t(label, fn):
    try:
        print("%-46s %r" % (label, fn()))
    except BaseException as e:
        print("%-46s !! %s: %s" % (label, type(e).__name__, str(e)[:52]))


# every name __all__ promises is really there
print(sorted(copyreg.__all__))
print([hasattr(copyreg, n) for n in copyreg.__all__])

# and the three private names pickle.py imports by name
print([hasattr(copyreg, n) for n in ("_extension_registry", "_inverted_registry",
                                     "_extension_cache", "dispatch_table")])
from copyreg import _extension_registry, _inverted_registry, _extension_cache
print(_extension_registry == {}, _inverted_registry == {}, _extension_cache == {})

# --- add_extension ------------------------------------------------------------

t("add_extension", lambda: copyreg.add_extension("mod", "name", 240))
t("registry after add", lambda: copyreg._extension_registry[("mod", "name")])
t("inverted after add", lambda: copyreg._inverted_registry[240])
t("redundant re-add is benign", lambda: copyreg.add_extension("mod", "name", 240))
t("same key, other code", lambda: copyreg.add_extension("mod", "name", 241))
t("same code, other key", lambda: copyreg.add_extension("mod", "other", 240))

for bad in (0, -1, 0x80000000, 0x7fffffff + 1):
    t("add_extension code=%d" % bad,
      (lambda c: lambda: copyreg.add_extension("m2", "n2", c))(bad))
t("add_extension code=0x7fffffff",
  lambda: copyreg.add_extension("m3", "n3", 0x7fffffff))
t("non-int code", lambda: copyreg.add_extension("m4", "n4", "x"))
t("float code truncates", lambda: copyreg.add_extension("m5", "n5", 242.0))

# --- remove_extension ---------------------------------------------------------

t("remove wrong code", lambda: copyreg.remove_extension("mod", "name", 999))
t("remove unknown key", lambda: copyreg.remove_extension("nope", "nope", 1))
t("remove_extension", lambda: copyreg.remove_extension("mod", "name", 240))
t("registry after remove", lambda: ("mod", "name") in copyreg._extension_registry)
t("inverted after remove", lambda: 240 in copyreg._inverted_registry)
t("remove twice", lambda: copyreg.remove_extension("mod", "name", 240))

# --- clear_extension_cache ----------------------------------------------------

copyreg._extension_cache[1] = "cached"
t("cache before clear", lambda: dict(copyreg._extension_cache))
t("clear_extension_cache", lambda: copyreg.clear_extension_cache())
t("cache after clear", lambda: dict(copyreg._extension_cache))

# remove_extension drops the cache entry for the code it removes
copyreg.add_extension("m6", "n6", 243)
copyreg._extension_cache[243] = "obj"
copyreg.remove_extension("m6", "n6", 243)
t("cache dropped with the code", lambda: 243 in copyreg._extension_cache)

# --- the rest of the surface still works -------------------------------------

t("pickle() rejects a non-callable", lambda: copyreg.pickle(int, 1))
t("constructor() rejects one too", lambda: copyreg.constructor(1))
t("__newobj__", lambda: copyreg.__newobj__(list))
t("__newobj_ex__", lambda: copyreg.__newobj_ex__(dict, (), {}))
t("dispatch_table is a dict", lambda: isinstance(copyreg.dispatch_table, dict))
# _reconstructor over a plain class.  The `list`/`object` pairing is not used
# here: object.__new__(list) is meant to raise "not safe", and does not in this
# tree -- a separate gap, recorded in the old bug list.


class _R:
    pass


t("_reconstructor", lambda: type(copyreg._reconstructor(_R, object, None)).__name__)

import copy
t("copy.copy of a plain object", lambda: type(copy.copy(object())).__name__)


class P:
    def __init__(self, a):
        self.a = a

    def __eq__(self, o):
        return type(o) is P and o.a == self.a


t("copy.copy round trip", lambda: copy.copy(P(3)) == P(3))
t("copy.deepcopy round trip", lambda: copy.deepcopy(P([1, 2])) == P([1, 2]))
t("__reduce_ex__(2)", lambda: type(P(1).__reduce_ex__(2)[0]).__name__)

# tidy up so the printed state does not depend on what ran before
for _k in list(copyreg._extension_registry):
    copyreg.remove_extension(_k[0], _k[1], copyreg._extension_registry[_k])
print(copyreg._extension_registry, copyreg._inverted_registry,
      copyreg._extension_cache)
