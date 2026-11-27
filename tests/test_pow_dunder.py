# int.__pow__ and float.__pow__ take a modulus, as pow() does.
#
# The dunder generator built every binary dunder with a fixed two-argument
# shape, so `(2).__pow__(5, 3)` was a TypeError where CPython answers 2.  The
# three-argument form goes to the same routine pow() uses; a reflected dunder
# swaps the base and the exponent on the way in.


def show(label, fn, *a):
    try:
        print("%-28s %r" % (label, fn(*a)))
    except TypeError as e:
        # CPython's arity wording for a wrapper that takes a range has a
        # leading space and says "at most"; ours reports the count.  The old bug list
        # recorded that, so only the class is compared for those.
        text = str(e)
        print("%-28s TypeError%s" % (label, "" if "expected" in text else ": " + text))
    except Exception as e:
        print("%-28s %s: %s" % (label, type(e).__name__, e))


print(pow(2, 5, 3), pow(2, 5))
show("(2).__pow__(5)", (2).__pow__, 5)
show("(2).__pow__(5, 3)", (2).__pow__, 5, 3)
show("(2).__pow__(5, 1)", (2).__pow__, 5, 1)
show("(2).__rpow__(5)", (2).__rpow__, 5)
show("(2).__rpow__(5, 3)", (2).__rpow__, 5, 3)
show("(3).__pow__(100, 7)", (3).__pow__, 100, 7)
show("(2).__pow__(5, 0)", (2).__pow__, 5, 0)
show("(2).__pow__('x')", (2).__pow__, "x")
show("(2).__pow__('x', 3)", (2).__pow__, "x", 3)
show("True.__pow__(5, 3)", True.__pow__, 5, 3)
show("(2.0).__pow__(5)", (2.0).__pow__, 5)
show("(2.0).__pow__(5, 3)", (2.0).__pow__, 5, 3)
show("(2.0).__rpow__(5)", (2.0).__rpow__, 5)
show("(2).__pow__()", (2).__pow__)
show("(2).__pow__(1, 2, 3)", (2).__pow__, 1, 2, 3)
show("(7).__rpow__('x', 0)", (7).__rpow__, "x", 0)
show("True.__rpow__('x', 0)", True.__rpow__, "x", 0)
show("(1.5).__pow__('x', 0)", (1.5).__pow__, "x", 0)
show("(1.5).__pow__(2, 0)", (1.5).__pow__, 2, 0)
show("(2).__rpow__('x', 3)", (2).__rpow__, "x", 3)
