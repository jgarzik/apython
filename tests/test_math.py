# The math module.
#
# Its absence blocked thirteen CPython stdlib modules outright, because every
# one of them opens with `import math` and none of them guards it.
#
# The float functions are glibc's, and for ordinary finite arguments CPython
# calls glibc too on Linux -- so most of what follows is compared bit for bit
# through repr().  Where the two genuinely differ, the comparison is loosened
# and the reason is written down rather than hidden:
#
#   gamma, lgamma   CPython uses a Lanczos approximation of its own
#   hypot (n-ary)   CPython's vector_norm does Veltkamp-Dekker splitting and
#                   a Neumaier sum; the two-argument form is glibc's in both
#
# math.fsum is NOT in that list.  Exactness is the whole reason it exists, so
# it is Shewchuk's algorithm, as CPython's is, and it is compared exactly.
# Nor is math.sumprod: its float path is CPython's triple-length tl_fma, so
# it is compared exactly too (tests/test_math_sumprod_prod_types.py).

import math

print("=== constants ===")
print(repr(math.pi), repr(math.e), repr(math.tau))
print(repr(math.inf), repr(math.nan), repr(-math.inf))
print("nan is not equal to itself:", math.nan != math.nan)
print("copysign keeps nan's sign:", repr(math.copysign(1.0, math.nan)))

print("=== the libm surface, bit for bit ===")
for name in ("sqrt", "exp", "expm1", "exp2", "log2", "log10", "log1p",
             "sin", "cos", "tan", "asin", "atan", "sinh", "cosh", "tanh",
             "asinh", "atanh", "cbrt", "erf", "erfc", "fabs"):
    f = getattr(math, name)
    print(name, [repr(f(x)) for x in (0.5, 0.25)])
print("acos", repr(math.acos(0.5)), "acosh", repr(math.acosh(2.0)))
print("log", repr(math.log(2.0)), repr(math.log(8, 2)), repr(math.log(100, 10)))
print("atan2", repr(math.atan2(1.0, 2.0)), repr(math.atan2(-1.0, -2.0)))
print("fmod", repr(math.fmod(7.0, 3.0)), repr(math.fmod(-7.0, 3.0)))
print("remainder", repr(math.remainder(7.0, 3.0)))
print("copysign", repr(math.copysign(3.0, -1.0)), repr(math.copysign(-3.0, 1.0)))
print("pow", repr(math.pow(2.0, 10.0)), repr(math.pow(2.0, 0.5)),
      repr(math.pow(0.0, 0.0)))
print("nextafter", repr(math.nextafter(1.0, 2.0)))
print("degrees", repr(math.degrees(math.pi)), repr(math.degrees(0.0)))
print("radians", repr(math.radians(180.0)), repr(math.radians(0.0)))
print("ldexp", repr(math.ldexp(1.0, 10)), repr(math.ldexp(1.5, -2)))
print("hypot 2", repr(math.hypot(3.0, 4.0)), repr(math.hypot(3, 4)))

print("=== the predicates ===")
for v in (1.0, 0.0, -0.0, math.inf, -math.inf, math.nan, 5, True):
    print(repr(v), math.isnan(v), math.isinf(v), math.isfinite(v))

print("=== floor, ceil and trunc return ints ===")
for v in (2.7, -2.7, 2.0, -2.0, 0.0, -0.0, 5, -5, True,
          10 ** 30 + 1, -(10 ** 30 + 1)):
    print(repr(v), math.floor(v), math.ceil(v), math.trunc(v))
print("types:", type(math.floor(2.5)).__name__, type(math.ceil(2.5)).__name__,
      type(math.trunc(2.5)).__name__)

class Rounds:
    def __floor__(self): return "Rounds.floor"
    def __ceil__(self): return "Rounds.ceil"
    def __trunc__(self): return "Rounds.trunc"

class OnlyFloat:
    def __float__(self): return 2.7

r = Rounds()
print("dunders:", math.floor(r), math.ceil(r), math.trunc(r))
print("via __float__:", math.floor(OnlyFloat()), math.ceil(OnlyFloat()))

print("=== modf and frexp ===")
for v in (2.5, -2.5, 0.0, -0.0, math.inf, -math.inf, math.nan, 5):
    print("modf", repr(v), math.modf(v))
for v in (8.0, 0.5, -8.0, 0.0, -0.0, math.inf, math.nan):
    print("frexp", repr(v), math.frexp(v))

print("=== the integer functions, exactly ===")
print("gcd", math.gcd(), math.gcd(7), math.gcd(-7), math.gcd(12, 18),
      math.gcd(12, 18, 24), math.gcd(2 ** 100, 2 ** 60), math.gcd(0, 5))
print("lcm", math.lcm(), math.lcm(4), math.lcm(4, 6), math.lcm(4, 6, 8),
      math.lcm(0, 5))
print("isqrt", math.isqrt(0), math.isqrt(1), math.isqrt(17),
      math.isqrt(10 ** 30), math.isqrt(2 ** 100))
print("factorial", math.factorial(0), math.factorial(5), math.factorial(20))
print("comb", math.comb(5, 2), math.comb(0, 0), math.comb(1, 5),
      math.comb(50, 25), math.comb(100, 3))
# An int in +-2^50 IS its Value here, so a boxed one would not compare equal
# by identity to the one every other operation makes.
print("not boxed:", math.gcd(4, 6) == 2, math.isqrt(4) == 2,
      type(math.gcd(2 ** 100, 2 ** 60)).__name__)

print("=== fsum is exact, which is the whole point ===")
print(repr(math.fsum([0.1] * 10)))
print(repr(math.fsum([])), repr(math.fsum([1, 2, 3])))
print(repr(math.fsum([1e100, 1.0, -1e100, 1.0])))
print(repr(math.fsum(range(100))))
print(repr(math.fsum([1e-100, 1.0, 1e-100])))

print("=== sumprod ===")
print(math.sumprod([1, 2, 3], [4, 5, 6]), type(math.sumprod([1, 2], [3, 4])).__name__)
print(repr(math.sumprod([], [])), repr(math.sumprod([0.1] * 10, [1.0] * 10)))
print(repr(math.sumprod([1.5, 2.5], [2, 4])))

print("=== the errors ===")
for e in ("math.sqrt(-1)", "math.log(0)", "math.log(-1)", "math.log2(0)",
          "math.acos(2)", "math.asin(2)", "math.atanh(1)", "math.exp(1e9)",
          "math.exp2(1e9)", "math.cosh(1e9)", "math.sin(math.inf)",
          "math.isqrt(-1)", "math.factorial(-1)", "math.factorial(1.5)",
          "math.comb(-1, 2)", "math.comb(1, -2)", "math.gcd(1.5, 2)",
          "math.sqrt('a')", "math.floor('a')", "math.trunc(object())",
          "math.sqrt()", "math.sqrt(1, 2)", "math.atan2(1)",
          "math.ldexp(1.0, 10**20)", "math.fsum([1e308, 1e308, -1e308])",
          "math.sumprod([1], [1, 2])"):
    try:
        print(e, "->", repr(eval(e)))
    except Exception as ex:
        print(e, "->", type(ex).__name__ + ":", ex)

print("=== the ones that round differently, to 12 digits ===")
# See the header: CPython does not call glibc for these.
print("gamma  ", "%.12g %.12g" % (math.gamma(5.0), math.gamma(0.5)))
print("lgamma ", "%.12g %.12g" % (math.lgamma(5.0), math.lgamma(0.5)))
print("hypot n", "%.12g %.12g" % (math.hypot(1.0, 2.0, 2.0), math.hypot(1e200, 1e200)))
print("hypot 0", repr(math.hypot()), repr(math.hypot(5.0)), repr(math.hypot(-5.0)))

# --- hypot: ucomisd sets ZF for an unordered compare, so the max scan read
# a NaN as an infinity and hypot(1, 2, nan) answered inf.  An infinity really
# does win over a NaN, which is why the test needs both orders.
inf = float("inf")
nan = float("nan")
print(math.hypot(1.0, 2.0, nan), math.hypot(inf, nan), math.hypot(nan, inf))
print(math.hypot(3.0, 4.0), math.hypot(3.0, 4.0, 12.0), math.hypot())

# --- log(x, base) is two logs and a division, and this path checked none of
# the three ways that goes wrong.
for expr in ["math.log(0, 10)", "math.log(-1, 2)", "math.log(10, 1)",
             "math.log(0)", "math.log(-1)", "math.log2(0)", "math.log10(0)"]:
    try:
        print(expr, "=", eval(expr))
    except Exception as e:
        print(expr, "->", type(e).__name__)
print(math.log(8, 2), math.log(100, 10), math.log(1024, 2))
print(math.log(nan, 2), math.log(2, nan), math.log(inf, 2), math.log(2, inf))

# --- an int too large for a double: sqrt overflows and says so, but the log
# family answers, because CPython's loghelper splits off the exponent instead
# of converting.
try:
    math.sqrt(10**400)
except OverflowError:
    print("sqrt(10**400): OverflowError")
print(math.log(10**400), math.log2(10**400), math.log10(10**400))
print(math.log(2**1000), math.log(10**400, 10), math.log(10**400, 2))
try:
    math.log(-(10**400))
except ValueError:
    print("log(-huge): ValueError")
