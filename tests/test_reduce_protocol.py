# The reduction protocol for the builtins that had none.
#
# copy.deepcopy({1, 2, 3}) was set().  Not an error -- an empty set, silently,
# from a function ordinary code uses everywhere.  The cause is that set,
# frozenset, bytearray and every exception carry no __reduce__, so
# lib/_reduce.py's override test finds object's and falls through to
# _reduce_newobj, which names the class and never its contents.  str, tuple and
# bytes have the same hole one level down: no __getnewargs__, so a SUBCLASS of
# one of them rebuilds empty.
#
# CPython supplies all of these in C.  Everything below is measured against it.
import copy
import pickle

# --- __getnewargs__ ---------------------------------------------------------


class S(str):
    pass


class T(tuple):
    pass


class B(bytes):
    pass


for v in ("hi", S("hi"), (1, 2), T((1, 2)), b"hi", B(b"hi")):
    args = v.__getnewargs__()
    print("%-12r getnewargs %-14r inner %s" % (v, args, type(args[0]).__name__))

# An exact tuple hands ITSELF over -- there is nothing to copy -- while a
# subclass hands over a plain tuple.
t = (1, 2)
print("exact tuple is self:", t.__getnewargs__()[0] is t)
print("tuple subclass is self:", T(t).__getnewargs__()[0] is T(t))

print("empty str:", "".__getnewargs__())
print("wide str:", "héllo".__getnewargs__())
print("empty tuple:", ().__getnewargs__())
print("nested tuple:", ((1, (2, 3)),)[0].__getnewargs__() if False else (1, (2, 3)).__getnewargs__())
print("empty bytes:", b"".__getnewargs__())

# --- __reduce__ on the containers -------------------------------------------


class St(set):
    pass


class Fs(frozenset):
    pass


class BA(bytearray):
    pass


def show(v):
    r = v.__reduce__()
    # The set arguments are a list, whose order follows the set's iteration
    # order, and that need not match CPython's.  Sort what is comparable.
    # The RECEIVER is named by type rather than by repr: a bytearray subclass
    # reprs as `bytearray(...)` here and as `BA(...)` in CPython, which is a
    # separate divergence and not this one.
    cls, args = r[0], r[1]
    if args and isinstance(args[0], list):
        args = (sorted(args[0], key=repr),) + args[1:]
    print("%-10s -> %s %r state=%r" % (type(v).__name__, cls.__name__, args,
                                       r[2] if len(r) > 2 else "<none>"))


show(set())
show({1, 2, 3})
show(frozenset())
show(frozenset({1, 2}))
show(St({1, 2}))
show(Fs({1, 2}))
show(bytearray())
show(bytearray(b"hi"))
show(BA(b"hi"))
show(bytearray(b"\x00\xff\x80"))

# --- __reduce__ on exceptions -----------------------------------------------

for e in (ValueError("x"), KeyError("k"), StopIteration(5), RuntimeError(),
          TypeError("a", "b"), ZeroDivisionError("div"), SystemExit(2)):
    print("%-26r -> %r" % (e, e.__reduce__()))

# A non-empty instance dict becomes a third element.
e = ValueError("x")
print("no dict:", e.__reduce__())
e.extra = 1
print("with dict:", e.__reduce__())

# A user subclass reduces as itself.
class MyError(ValueError):
    pass


print("subclass:", MyError("m").__reduce__())

# OSError's class and args are compared, but not the whole tuple.  CPython
# keeps errno, strerror, filename and filename2 as C members, so they are not
# in vars(e) and its reduction is a two-tuple with the filename re-packed into
# the args; here they live in the instance dict, so they come back as a STATE.
# Every value survives the round trip either way and only the tuple's shape
# differs -- recorded in the old bug list beside its cause, which is the same one.
for e in (OSError(2, "no"), OSError(2, "no", "f1"), OSError("plain"), OSError()):
    r = e.__reduce__()
    # args[:len(e.args)] rather than args: CPython re-packs the filename into
    # the reduction's arguments and this does not, for the reason above.
    print("OSError %-16r -> %s %r" % (e.args, r[0].__name__, r[1][:len(e.args)]))
print("OSError args 3:", OSError(2, "no", "f1").args)

# --- what the whole thing is for --------------------------------------------

for v in ({1, 2, 3}, frozenset({1, 2}), bytearray(b"ab"), ValueError("x"),
          OSError(2, "no"), St({4, 5}), BA(b"cd"), S("hi"), T((1, 2)), B(b"hi")):
    c = copy.copy(v)
    d = copy.deepcopy(v)
    def content(x):
        if isinstance(x, (set, frozenset)):
            return sorted(x, key=repr)
        if isinstance(x, bytearray):
            return bytes(x)          # a bytearray subclass reprs differently
        if isinstance(x, BaseException):
            return x.args
        return x
    print("%-12s copy %-12s deep %-12s contents %r/%r"
          % (type(v).__name__, type(c).__name__, type(d).__name__,
             content(c), content(d)))

b = B(b"a\x00b\xff")
nested_b = B(b"\x00")
nested_b.tag = "inner"
b.items = [nested_b]


def check_bytes_clone(clone):
    assert clone is not b and type(clone) is B and clone == b"a\x00b\xff"
    assert vars(clone) == {"items": [b"\x00"]}
    child = clone.items[0]
    assert type(child) is B and vars(child) == {"tag": "inner"}


shallow = copy.copy(b)
check_bytes_clone(shallow)
assert shallow.items is b.items
deep_copy = copy.deepcopy(b)
check_bytes_clone(deep_copy)
assert deep_copy.items is not b.items and deep_copy.items[0] is not nested_b
for protocol in range(pickle.HIGHEST_PROTOCOL + 1):
    result = pickle.loads(pickle.dumps(b, protocol=protocol))
    check_bytes_clone(result)
    assert result.items is not b.items and result.items[0] is not nested_b

# Nested, which is where a silent empty is worst: the loss is not at the top.
nested = {"a": [1, {2, 3}], "b": (4, frozenset({5})), "c": ValueError("deep")}
dn = copy.deepcopy(nested)
print("nested set:", sorted(dn["a"][1]))
print("nested frozenset:", sorted(dn["b"][1]))
print("nested exception args:", dn["c"].args)
print("nested independent:", dn["a"] is not nested["a"])

# A set inside a tuple inside a list, since a tuple that copies to itself is
# returned unchanged and must not shortcut a set inside it.
deep = [({1, 2},)]
dd = copy.deepcopy(deep)
print("set in tuple in list:", sorted(dd[0][0]), dd[0][0] is not deep[0][0])

print("done")
