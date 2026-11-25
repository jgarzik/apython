# A key that cannot be hashed, whose __hash__ raises, or whose __eq__ raises
# when its hash collides with the key being looked up -- through the dict
# methods and through the dicts the interpreter keeps for itself but Python
# can reach.
#
# dict_get and dict_set RETURN that failure now, so each caller has to notice
# it, release what it holds and hand the same exception on.  Each case runs
# two hundred times around sys.getallocatedblocks(); the line printed is the
# exception's type and whether the block count stayed put.
import gc
import sys


class Boom(Exception):
    pass


class BadHash:
    def __hash__(self):
        raise Boom("hash")


class BadEq:
    """Collides with the key it was built for, and refuses to compare."""

    def __init__(self, like):
        self.h = hash(like)

    def __hash__(self):
        return self.h

    def __eq__(self, other):
        raise Boom("eq")


def name_of(fn):
    try:
        fn()
    except BaseException as e:
        return type(e).__name__
    return "no error"


def check(label, fn):
    first = name_of(fn)
    for _ in range(300):
        name_of(fn)
    gc.collect()
    before = sys.getallocatedblocks()
    for _ in range(200):
        name_of(fn)
    gc.collect()
    grew = sys.getallocatedblocks() - before
    print("%-44s %-12s %s" % (label, first, "steady" if grew < 50 else "LEAKS"))


def keys_for(like):
    return [("unhashable", lambda: []), ("bad hash", BadHash),
            ("bad eq", lambda: BadEq(like))]


def colliding(like):
    """A dict that already holds a key colliding with `like`."""
    return {BadEq(like): 1}


class K:
    pass


def fresh_keys():
    return iter([K() for _ in range(20)])


# --- no error at all: what a successful call must not leak -----------------
check("fromkeys of fresh objects", lambda: dict.fromkeys(fresh_keys()))
check("fromkeys with a value", lambda: dict.fromkeys(fresh_keys(), 1))

# --- the dict methods ------------------------------------------------------
for what, mk in keys_for("a"):
    check("get(%s)" % what, lambda: {}.get(mk()))
    check("pop(%s)" % what, lambda: {}.pop(mk()))
    check("pop(%s, default)" % what, lambda: {}.pop(mk(), None))
    check("setdefault(%s)" % what, lambda: {}.setdefault(mk()))
    check("__setitem__(%s)" % what, lambda: dict.__setitem__({}, mk(), 1))
    check("__getitem__(%s)" % what, lambda: dict.__getitem__({}, mk()))
    check("__contains__(%s)" % what, lambda: mk() in {})
    check("update([(%s, 1)])" % what, lambda: {}.update([(mk(), 1)]))
    check("update([[%s, 1]])" % what, lambda: {}.update([[mk(), 1]]))
    check("fromkeys([%s])" % what, lambda: dict.fromkeys([K(), mk(), K()]))

check("get, colliding", lambda: colliding("a").get("a"))
check("pop, colliding", lambda: colliding("a").pop("a"))
check("setdefault, colliding", lambda: colliding("a").setdefault("a"))
check("setdefault with default, colliding",
      lambda: colliding("a").setdefault("a", [1, 2]))
check("update(dict), colliding", lambda: colliding("a").update({"a": 1}))
check("update(pairs), colliding", lambda: colliding("a").update([("a", 1)]))
check("update(k=v), colliding", lambda: colliding("a").update(a=1))


class Keyed:
    def keys(self):
        return ["a"]

    def __getitem__(self, k):
        return [k]


check("update(mapping), colliding", lambda: colliding("a").update(Keyed()))
check("__setitem__, colliding", lambda: colliding("a").__setitem__("a", 1))
check("d | other, colliding", lambda: colliding("a") | {"a": 1})

# --- str.translate and str.maketrans ----------------------------------------
check("translate, colliding", lambda: "a".translate(colliding(ord("a"))))


class IntKey(int):
    """Hashes once, for the dict literal, and refuses the second time."""
    calls = 0

    def __hash__(self):
        IntKey.calls += 1
        if IntKey.calls % 2 == 0:
            raise Boom("hash")
        return 5


check("maketrans({bad int: 'x'})", lambda: str.maketrans({IntKey(5): "x"}))
check("format_map, colliding", lambda: "{a}".format_map(colliding("a")))

# --- dicts the interpreter keeps, and Python can reach -----------------------
check("eval, colliding __builtins__",
      lambda: eval("1", {BadEq("__builtins__"): 1}))
check("exec, colliding __builtins__",
      lambda: exec("pass", {BadEq("__builtins__"): 1}))


def import_colliding():
    k = BadEq("colorsys")
    sys.modules[k] = None
    try:
        __import__("colorsys")
    finally:
        del sys.modules[k]


check("__import__, colliding sys.modules", import_colliding)


def locals_colliding():
    a = 1
    locals()[BadEq("a")] = 2
    return locals()


check("locals(), colliding f_locals", locals_colliding)

# --- attribute lookup: the instance's dict fails, the type's does not -------
class Plain:
    pass


def instance_with(name):
    o = Plain()
    o.__dict__[BadEq(name)] = 1
    return o


check("o.y, colliding __dict__", lambda: instance_with("y").y)
check("o.y = 1, colliding __dict__", lambda: setattr(instance_with("y"), "y", 1))
check("getattr(o, 'y', 0)", lambda: getattr(instance_with("y"), "y", 0))
check("hasattr(o, 'y')", lambda: hasattr(instance_with("y"), "y"))

# A class body may put anything in its namespace, and a lookup along the MRO
# treats a key that will not compare as "not here": CPython's _PyType_Lookup
# clears the error.
Odd = type("Odd", (), {BadEq("x"): 1})
check("C.x, colliding class namespace", lambda: Odd.x)
check("C().x, colliding class namespace", lambda: Odd().x)


def module_with(name):
    m = type(sys)("m")
    m.__dict__[BadEq(name)] = 1
    return m


check("module.z", lambda: module_with("z").z)
check("module.z = 1", lambda: setattr(module_with("z"), "z", 1))


def function_with(name):
    def f():
        pass
    f.__dict__[BadEq(name)] = 1
    return f


check("function.a", lambda: function_with("a").a)
check("function.a = 1", lambda: setattr(function_with("a"), "a", 1))


def exception_with(name):
    e = ValueError("v")
    e.__dict__[BadEq(name)] = 1
    return e


check("exception.k", lambda: exception_with("k").k)
check("exception.k = 1", lambda: setattr(exception_with("k"), "k", 1))
check("add_note, colliding __notes__",
      lambda: exception_with("__notes__").add_note("n"))


def kwdefaults_colliding():
    def f(*, a=1):
        return a
    f.__kwdefaults__ = {BadEq("a"): 1}
    return f()


check("call, colliding __kwdefaults__", kwdefaults_colliding)
