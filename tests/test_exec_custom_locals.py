# A frame's locals need not be a dict.
#
# exec() takes any mapping, and a class body runs in whatever __prepare__
# returned.  Three opcodes reached into that object as if it were a
# PyDictObject and probed its header as a hash table: LOAD_NAME's locals
# probe, DELETE_NAME, and SETUP_ANNOTATIONS -- the last of which also
# installed a fresh __annotations__ unconditionally, discarding whatever was
# already there.  CPython asks PyDict_CheckExact and goes through
# PyObject_GetItem / PyObject_SetItem / PyObject_DelItem otherwise.
#
# A dict SUBCLASS keeps the direct read here, where CPython's
# PyDict_CheckExact sends it through PyObject_GetItem: a builtin __getitem__
# reports a miss by RAISING, which in this tree is a non-local jump into the
# unwinder, so the KeyError could not be absorbed.  ROADMAP.md carries what that
# costs.
#
# CPython's test_grammar.test_var_annot_refleak is the annotations half.


class NS:
    def __init__(self, d=None):
        self._d = dict(d or {})
        self.got = []
        self.set = []
        self.deleted = []

    def __getitem__(self, k):
        self.got.append(k)
        return self._d[k]

    def __setitem__(self, k, v):
        self.set.append(k)
        self._d[k] = v

    def __delitem__(self, k):
        self.deleted.append(k)
        del self._d[k]

    def keys(self):
        return self._d.keys()


# --- LOAD_NAME and STORE_NAME ---------------------------------------------
ns = NS()
exec("x = 1\ny = x + 1", {}, ns)
print(sorted(ns._d.items()), ns.got, ns.set)

ns2 = NS({"z": 5})
exec("w = z * 2", {}, ns2)
print(sorted(ns2._d.items()))

# A name that is in globals rather than in the mapping: the mapping's miss has
# to be absorbed, not raised.
ns3 = NS()
exec("out = g + 1", {"g": 10}, ns3)
print(ns3._d["out"], ns3.got)

# ...and one that is only a builtin.
ns4 = NS()
exec("out = len([1, 2, 3])", {}, ns4)
print(ns4._d["out"])

# A name that is nowhere still reports NameError.
try:
    exec("out = nope", {}, NS())
except NameError as e:
    print("NameError")

# --- DELETE_NAME ----------------------------------------------------------
ns5 = NS({"q": 1, "r": 2})
exec("del q", {}, ns5)
print(sorted(ns5._d.items()), ns5.deleted)

# --- SETUP_ANNOTATIONS ----------------------------------------------------
ns6 = NS()
exec("A: int\nB: str = 'b'", {}, ns6)
print(sorted(ns6._d.keys()), ns6._d["__annotations__"])

# An __annotations__ the mapping already holds is NOT replaced.
existing = {"already": True}
ns7 = NS({"__annotations__": existing})
exec("C: float", {}, ns7)
print(ns7._d["__annotations__"] is existing, sorted(existing.items()))

# The same in a plain dict locals, which is the fast path.
d = {"__annotations__": {"kept": 1}}
exec("D: bytes", {}, d)
print(sorted(d["__annotations__"].items()))

# --- CPython's own shape, from test_grammar --------------------------------
class CNS:
    def __init__(self):
        self._dct = {}

    def __setitem__(self, item, value):
        self._dct[item.lower()] = value

    def __getitem__(self, item):
        return self._dct[item]


cns = CNS()
nonloc_ns = {"__annotations__": cns}


class CNS2:
    def __init__(self):
        self._dct = {"__annotations__": cns}

    def __setitem__(self, item, value):
        self._dct[item] = value
        nonloc_ns[item] = value

    def __getitem__(self, item):
        return self._dct[item]


exec("X: str", {}, CNS2())
print(nonloc_ns["__annotations__"]["x"])

# --- a dict subclass, whose storage is read directly ----------------------
class Sub(dict):
    pass


sub = Sub(seed=3)
exec("v = seed + 1", {}, sub)
print(sub["v"], sorted(sub))

# --- a mapping whose __getitem__ raises something OTHER than KeyError ------
class Angry:
    def __getitem__(self, k):
        raise RuntimeError("no lookups here")

    def __setitem__(self, k, v):
        pass


try:
    exec("out = 1", {}, Angry())
except RuntimeError as e:
    print("RuntimeError", e)
else:
    print("no error from Angry")

# --- class bodies through __prepare__ -------------------------------------
class Meta(type):
    @classmethod
    def __prepare__(mcls, name, bases, **kw):
        return NS()

    def __new__(mcls, name, bases, ns, **kw):
        return type.__new__(mcls, name, bases, dict(ns._d))


class Body(metaclass=Meta):
    a = 1
    b = a + 1
    c: int


print(Body.a, Body.b, sorted(Body.__annotations__.items()))
print("done")
