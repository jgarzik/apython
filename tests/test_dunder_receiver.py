# A dunder registered by name is callable unbound, with any receiver at all.
# The slot behind it decodes args[0] without asking, so int.__neg__(2.5)
# handed int's nb_negative a float and str.__getitem__(5, 0) handed str's
# subscript an integer -- each a wild pointer rather than an error.
#
# Registering these names is what made the calls reachable, so every wrapper
# has to check the receiver first.  CPython raises TypeError for all of them.

CASES = [
    ("int.__neg__", lambda: int.__neg__(2.5)),
    ("int.__abs__", lambda: int.__abs__(2.5)),
    ("int.__invert__", lambda: int.__invert__(2.5)),
    ("int.__bool__", lambda: int.__bool__([1])),
    ("int.__float__", lambda: int.__float__("x")),
    ("float.__neg__", lambda: float.__neg__(5)),
    ("str.__len__", lambda: str.__len__(5)),
    ("str.__getitem__", lambda: str.__getitem__(5, 0)),
    ("str.__add__", lambda: str.__add__(5, "a")),
    ("str.__mul__", lambda: str.__mul__(5, 2)),
    ("list.__len__", lambda: list.__len__(5)),
    ("list.__add__", lambda: list.__add__(5, [])),
    ("list.__iadd__", lambda: list.__iadd__(5, [])),
    ("list.__getitem__", lambda: list.__getitem__(5, 0)),
    ("list.__contains__", lambda: list.__contains__(5, 1)),
    ("list.__iter__", lambda: list.__iter__(5)),
    ("tuple.__add__", lambda: tuple.__add__(5, ())),
    ("tuple.__len__", lambda: tuple.__len__(5)),
    ("tuple.__getitem__", lambda: tuple.__getitem__(5, 0)),
    ("dict.__or__", lambda: dict.__or__(5, {})),
    ("dict.__len__", lambda: dict.__len__(5)),
    ("dict.__getitem__", lambda: dict.__getitem__(5, "k")),
    ("set.__and__", lambda: set.__and__(5, set())),
    ("frozenset.__hash__", lambda: frozenset.__hash__(5)),
    ("bytes.__add__", lambda: bytes.__add__(5, b"")),
    ("bytes.__len__", lambda: bytes.__len__(5)),
    ("bytearray.__imul__", lambda: bytearray.__imul__(5, 1)),
    ("bytearray.__len__", lambda: bytearray.__len__(5)),
]

for name, call in CASES:
    try:
        call()
        print(name, "NO ERROR")
    except TypeError:
        print(name, "TypeError")

# The receiver may be a SUBCLASS: that is how a subclass reaches the base's
# operator, so the check is a subtype test rather than a pointer compare.
class D(int):
    pass


class L(list):
    pass


print(int.__neg__(D(7)), int.__index__(D(3)))
print(list.__len__(L([1, 2])), list.__contains__(L([1, 2]), 2))

# set and frozenset are registered from one shared table -- siblings, neither
# a subtype of the other -- so set's wrappers have to answer for both, or
# frozenset loses the names entirely.  (CPython gives frozenset its own
# descriptors and so rejects set.__and__(frozenset(...)); we are the more
# permissive of the two, which the old bug list recorded.)
fs = frozenset({1, 2})
print(len(fs), sorted(fs.__iter__()), fs.__len__())
print(sorted(fs & {2, 3}), sorted(fs | {3}))
