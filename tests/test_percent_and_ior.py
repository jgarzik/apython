# What % and |= accept on the right.
#
# Three entries, one shape: the operand test was narrower than CPython's.
#
# str_mod called anything but an exact dict a single value, where CPython's
# rule is "has an mp_subscript, and is not a tuple or a str" -- so
# `"ab" % [1, 2]` was a TypeError rather than 'ab'.  dict's nb_ior took only a
# dict, where CPython's |= takes everything dict.update does.  And
# bytearray_type.tp_as_number was 0, so bytearray had no % at all.

# A mapping on the right: any mapping, and it counts as one argument.
print("ab" % [1, 2], "ab" % {"a": 1}, "ab" % ())
print("%s" % [1, 2], "%s" % {"a": 1}, "%s" % "one", "%s" % 5)
print("%(k)s" % {"k": "v"})
class M:
    def __getitem__(self, k):
        return "M[" + k + "]"
print("%(k)s" % M(), "%(a)s-%(b)s" % M())
# ("%d" % "x" is a TypeError in CPython and is accepted here; that is the
# conversion table, which the old bug list recorded, not the operand rule.)
for e in ("'%s%s' % [1, 2]", "'%(a)s' % [1, 2]", "'%s %s' % ('one',)",
          "'%s' % ('a', 'b')"):
    try:
        eval(e)
        print(e, "=> no error")
    except (TypeError, ValueError, KeyError) as x:
        print(e, "=>", type(x).__name__)

# A tuple is the argument list, never a mapping, even though it subscripts.
print("%s-%s" % (1, 2), "%r" % ((1, 2),))
class T(tuple):
    pass
print("%s-%s" % T((1, 2)))
try:
    "%s" % T(("a", "b"))
except TypeError as x:
    print("tuple subclass arity:", type(x).__name__)

# dict |= takes what dict.update takes.
def ior(x):
    d = {"z": 0}
    d |= x
    return d
print(ior({"a": 1}), ior([("a", 1), ("b", 2)]), ior((("a", 1),)))
print(ior(zip("ab", [1, 2])), ior((c, i) for i, c in enumerate("ab")))
for bad in (5, "ab", [1, 2], None):
    try:
        ior(bad)
        print(bad, "=> no error")
    except (TypeError, ValueError) as x:
        print(repr(bad), "=>", type(x).__name__)

# `|` stays strict, as it is in CPython: only a dict.
try:
    {"z": 0} | [("a", 1)]
except TypeError:
    print("| with a list => TypeError")
print({"z": 0} | {"a": 1})

# bytearray has a %.
print(bytearray(b"%d") % 5, bytearray(b"%s") % b"x")
print(bytearray(b"%d-%d") % (1, 2), bytearray(b"ab") % ())
print(bytearray(b"100%%") % (), type(bytearray(b"%d") % 5).__name__)
print(b"%d" % 5, type(b"%d" % 5).__name__)
try:
    bytearray(b"%d") % (1, 2)
except TypeError as x:
    print("bytearray arity:", type(x).__name__)
