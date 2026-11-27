# Slices compare, and hash, as the tuple (start, stop, step).
#
# slice_type.tp_richcompare was 0, so every comparison fell to op_compare_op's
# identity path: ordering raised TypeError and equality was identity, which
# made slice(1,2,3) == slice(1,2,3) False.  The old bug list recorded the ordering half
# and said equality worked; it did not.  tp_hash was 0 as well, though a slice
# has been hashable since 3.12.

a = slice(1, 2, 3)
b = slice(1, 2, 3)
print(a == b, a != b, a is b)
print(slice(1) == slice(1), slice(None) == slice(None))
print(slice(1, 2) == slice(1, 3), slice(1, 2) != slice(1, 3))

print(slice(1) < slice(2), slice(2) < slice(1))
print(slice(1, 2) < slice(1, 3), slice(1, 3) <= slice(1, 3))
print(slice(1, 2, 3) > slice(1, 2, 2), slice(1) >= slice(1))
print(sorted([slice(3), slice(1), slice(2)], key=lambda s: s.stop))

# None sorts against None only, exactly as the tuple does.
print(slice(None) == slice(None, None, None))
try:
    slice(None) < slice(1)
except TypeError:
    print("slice(None) < slice(1) => TypeError")

# Mixed operands decline rather than crash.
print(slice(1) == 5, 5 == slice(1), slice(1) != 5)
for expr in ("slice(1) < 5", "5 < slice(1)", "slice(1) < (1, 2, 3)"):
    try:
        eval(expr)
        print(expr, "=> no error")
    except TypeError:
        print(expr, "=> TypeError")

# Hashing, and the equal-hashes-equal rule that dict keys need.
print(hash(a) == hash(b), hash(slice(1)) == hash(slice(1)))
d = {a: "x"}
print(d[b], d[slice(1, 2, 3)])
print(len({slice(1), slice(1), slice(2)}))
try:
    hash(slice([1], 2))
except TypeError:
    print("a slice of a list is unhashable")

# Slices still work as subscripts.
print([0, 1, 2, 3][a], [0, 1, 2, 3][slice(1, 3)])

# repr answered the fixed string "slice(...)" for every slice; CPython prints
# all three fields, always.
print(repr(slice(1)), repr(slice(1, 2)), repr(slice(1, 2, 3)))
print(repr(slice(None)), repr(slice("a", None, 2.5)))
print(slice(1), str(slice(1, 2)), "%s" % (slice(3),))
print([slice(1), slice(2, 3)])
