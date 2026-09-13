"""A dunder that is ALREADY a bound method must not be handed self again.

CPython's slot wrappers ask whether the attribute they found is a descriptor.
A plain `def` is one, so it is called unbound with self prepended; a bound
method is not, so it is called as it stands.  Here the slot path prepended
self unconditionally, so every one of these was a TypeError about arity --
while reaching the SAME attribute through the instance worked, which is what
made it invisible.

The shape is ordinary: `__next__ = iterator(source).__next__` is how
`xml.etree.ElementTree.iterparse` builds its iterator, and a `for` over one
never terminated, because a generator's `__next__` swallowed the extra
argument and answered self at exhaustion instead of raising StopIteration.
"""

L = [1, 2]


def show(label, fn):
    try:
        print("%-16s %r" % (label, fn()))
    except Exception as e:                      # noqa: BLE001 - the point
        print("%-16s %s: %s" % (label, type(e).__name__, e))


print("--- a bound builtin method as a slot, reached through the protocol ---")
for name, d, fn in (
    ("__len__", {"__len__": L.__len__}, lambda o: len(o)),
    ("__contains__", {"__contains__": L.__contains__}, lambda o: 1 in o),
    ("__getitem__", {"__getitem__": L.__getitem__}, lambda o: o[0]),
    ("__iter__", {"__iter__": L.__iter__}, lambda o: list(iter(o))),
    ("__str__", {"__str__": (5).__str__}, lambda o: str(o)),
    ("__repr__", {"__repr__": (5).__repr__}, lambda o: repr(o)),
    ("__hash__", {"__hash__": (5).__hash__}, lambda o: hash(o)),
    ("__eq__", {"__eq__": L.__eq__}, lambda o: o == [1, 2]),
    ("__call__", {"__call__": L.count}, lambda o: o(1)),
    ("__bool__", {"__bool__": L.__len__}, lambda o: bool(o)),
):
    C = type("C_" + name.strip("_"), (), d)
    show(name, lambda fn=fn, C=C: fn(C()))

print("--- and the same attribute reached directly still works ---")
C = type("C", (), {"__len__": L.__len__})
print("instance attr:", C().__len__())
print("class attr:   ", C.__len__())

print("--- __next__, over every builtin iterator ---")


def mk_gen():
    yield 1


for kind, nx in (("generator", mk_gen().__next__),
                 ("list_iterator", iter([1]).__next__),
                 ("range_iterator", iter(range(1)).__next__),
                 ("tuple_iterator", iter((1,)).__next__),
                 ("str_iterator", iter("a").__next__),
                 ("dict_keyiterator", iter({1: 2}).__next__),
                 ("set_iterator", iter({1}).__next__)):
    C = type("C_" + kind, (), {"__next__": nx})
    c = C()
    got = []
    for _ in range(2):
        try:
            got.append(next(c))
        except StopIteration:
            got.append("StopIteration")
        except Exception as e:                  # noqa: BLE001 - the point
            got.append("%s: %s" % (type(e).__name__, e))
    print("%-18s %r" % (kind, got))

print("--- a for loop over such an object terminates ---")


def gen3():
    yield from (1, 2, 3)


C = type("C", (), {"__next__": gen3().__next__, "__iter__": lambda self: self})
# Bounded deliberately.  The bug this file is about made exhaustion answer the
# ITERATOR instead of raising StopIteration, so an unbounded `for` here would
# hang the whole suite rather than fail one test in it.
collected = []
for x in C():
    collected.append(x)
    if len(collected) > 8:
        collected.append("DID NOT TERMINATE")
        break
print("collected:", collected)

print("--- a plain def still gets self, as it must ---")


class Plain:
    def __len__(self):
        return 7

    def __next__(self):
        raise StopIteration


print("plain __len__:", len(Plain()))
show("plain __next__  ", lambda: next(Plain()))

print("--- a staticmethod of a builtin is called without self either ---")


class WithStatic:
    __len__ = staticmethod(L.__len__)


print("staticmethod __len__:", len(WithStatic()))
