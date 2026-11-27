# The binary operator dunders, by name.
#
# int.__add__ did not exist at all -- dir(int) was short by about forty names
# -- so a class delegating to it found nothing, and the stdlib's habit of
# asking hasattr(x, "__add__") answered no for the type it is truest of.
#
# A dunder called by name answers NotImplemented for an operand it does not
# want, where the operator itself raises TypeError; both are checked here.

INT_BIN = ["add", "sub", "mul", "mod", "pow", "lshift", "rshift", "and",
           "xor", "or", "floordiv", "truediv", "divmod"]
FLOAT_BIN = ["add", "sub", "mul", "mod", "pow", "floordiv", "truediv",
             "divmod"]

print("=== every name is there ===")
for t, names in ((int, INT_BIN), (float, FLOAT_BIN)):
    for n in names:
        print(t.__name__, n, hasattr(t, "__%s__" % n), hasattr(t, "__r%s__" % n))

print("=== int, forward ===")
PAIRS = [(7, 2), (-7, 2), (7, -2), (0, 5), (6, 3), (2, 10), (1, 4), (16, 2)]
for a, b in PAIRS:
    for n in INT_BIN:
        try:
            print(n, a, b, getattr(int, "__%s__" % n)(a, b))
        except Exception as e:
            print(n, a, b, type(e).__name__)

print("=== int, reflected ===")
for a, b in PAIRS:
    for n in INT_BIN:
        try:
            print("r" + n, a, b, getattr(int, "__r%s__" % n)(a, b))
        except Exception as e:
            print("r" + n, a, b, type(e).__name__)

print("=== float ===")
# (-7.5) ** 2.5 is a complex in CPython and a nan here; the old bug list carried it,
# and it is not what this file is about.
FPAIRS = [(7.0, 2.0), (-7.5, 2.0), (1.5, 0.5), (2.0, 3.0)]
for a, b in FPAIRS:
    for n in FLOAT_BIN:
        try:
            print(n, a, b, getattr(float, "__%s__" % n)(a, b))
        except Exception as e:
            print(n, a, b, type(e).__name__)
    for n in FLOAT_BIN:
        try:
            print("r" + n, a, b, getattr(float, "__r%s__" % n)(a, b))
        except Exception as e:
            print("r" + n, a, b, type(e).__name__)

print("=== an operand the slot does not want is NotImplemented ===")
for other in ("x", [1], None, {}, (1,)):
    print(repr(other), int.__add__(1, other), int.__mul__(2, other),
          int.__radd__(1, other), float.__add__(1.5, other),
          int.__divmod__(1, other), float.__rdivmod__(1.5, other))

print("=== the mixed pairs the slots do want ===")
print(int.__add__(1, 2.5), int.__truediv__(1, 2.0), float.__add__(1.5, 2))
print(int.__radd__(1, 2.5), float.__rsub__(1.5, 4))
print(int.__add__(True, 1), int.__and__(True, 3))

print("=== bound, and through an instance ===")
print((7).__add__(2), (7).__floordiv__(2), (1.5).__mul__(2.0))
print((7).__radd__(2), (1.5).__rtruediv__(3.0))

print("=== big integers still go through the same slot ===")
big = 10 ** 30
print(int.__add__(big, 1), int.__mul__(big, 2), int.__mod__(big, 7))
print(int.__divmod__(big, 7), int.__rshift__(big, 10))

print("=== division by zero comes through as itself ===")
for n, args in (("truediv", (1, 0)), ("floordiv", (1, 0)), ("mod", (1, 0)),
                ("divmod", (1, 0))):
    try:
        print(n, getattr(int, "__%s__" % n)(*args))
    except ZeroDivisionError as e:
        print(n, "ZeroDivisionError")
