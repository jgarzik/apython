# math.sumprod and math.prod keep their operands' types the way CPython's do:
# an int fast path, a float fast path, and for anything else the ordinary
# `total + p * q` starting from the int 0 -- so a Fraction stays a Fraction
# and a Decimal a Decimal.
import math
from fractions import Fraction
from decimal import Decimal


def show(label, fn):
    try:
        r = fn()
        print(label, type(r).__name__, repr(r))
    except Exception as e:
        print(label, "raised", type(e).__name__, e)


print("=== sumprod: ints ===")
show("small", lambda: math.sumprod([1, 2, 3], [4, 5, 6]))
show("neg", lambda: math.sumprod([-1, 2, -3], [4, -5, 6]))
show("huge", lambda: math.sumprod([10**15, 10**15], [10**15, 3 * 10**15]))
show("huger", lambda: math.sumprod([10**30, -7], [10**30, 3]))
show("2**63", lambda: math.sumprod([2**62, 2**62], [2, 2]))
show("bools", lambda: math.sumprod([True, True, False], [True, 5, 7]))
show("bool only", lambda: math.sumprod([True], [True]))
show("empty", lambda: math.sumprod([], []))
show("empty iters", lambda: math.sumprod(iter(()), ()))

print("=== sumprod: floats ===")
show("tenths", lambda: math.sumprod([0.1] * 10, [1.0] * 10))
show("cancel", lambda: math.sumprod([1e100, 1.0, -1e100], [1.0, 1.0, 1.0]))
show("cancel2", lambda: math.sumprod([0.1, 0.2, 0.3], [0.3, 0.2, -0.1]))
show("thirds", lambda: math.sumprod([1 / 3] * 7, [3.0, -1.1, 2.2, 0.7, 5.5, 1e-9, -2.25]))
xs = [i * 0.37 - 5.1 for i in range(40)]
ys = [1.0 / (i + 0.5) for i in range(40)]
show("forty", lambda: math.sumprod(xs, ys))
show("overflow", lambda: math.sumprod([1e308, 1e308], [10.0, -10.0]))
show("inf", lambda: math.sumprod([float("inf"), 1.0], [1.0, 2.0]))
show("nan", lambda: math.sumprod([float("nan")], [1.0]))

print("=== sumprod: mixed int/float ===")
show("int*float", lambda: math.sumprod([1, 2], [0.5, 0.25]))
show("float*int", lambda: math.sumprod([0.5, 0.25], [3, 4]))
show("int then float", lambda: math.sumprod([1, 2, 0.1], [3, 4, 0.1]))
show("float then int", lambda: math.sumprod([0.1, 2, 3], [0.1, 4, 5]))
show("huge int with float", lambda: math.sumprod([10**30, 0.5], [10**30, 0.5]))
show("bool*float", lambda: math.sumprod([True, 0.5], [0.25, False]))

print("=== sumprod: Fraction ===")
show("frac", lambda: math.sumprod([Fraction(1, 3)], [Fraction(2, 3)]))
show("frac2", lambda: math.sumprod([Fraction(1, 3), Fraction(1, 7)], [3, Fraction(14, 5)]))
show("int then frac", lambda: math.sumprod([1, 2, Fraction(1, 2)], [3, 4, Fraction(1, 2)]))
show("frac float", lambda: math.sumprod([Fraction(1, 2), 0.25], [2, 2]))

print("=== sumprod: Decimal ===")
show("dec", lambda: math.sumprod([Decimal("1.1"), Decimal("2.2")], [Decimal("3"), Decimal("0.5")]))
show("dec int", lambda: math.sumprod([Decimal("1.1"), 2], [3, 4]))
show("int dec", lambda: math.sumprod([1, 2], [Decimal("0.1"), Decimal("0.2")]))

print("=== sumprod: complex ===")
show("cplx", lambda: math.sumprod([1j, 2], [1j, 3 + 1j]))
show("float cplx", lambda: math.sumprod([0.5, 1j], [2.0, 1j]))

print("=== sumprod: errors ===")
show("short p", lambda: math.sumprod([1], [1, 2]))
show("short q", lambda: math.sumprod([1, 2], [1]))
show("short float", lambda: math.sumprod([1.0, 2.0], [1.0]))
show("p not iterable", lambda: math.sumprod(3, [1]))
show("q not iterable", lambda: math.sumprod([1], None))
show("str*str", lambda: math.sumprod(["a"], ["b"]))
show("str*int", lambda: math.sumprod(["ab"], [2]))
show("arity", lambda: math.sumprod([1]))


def gen_raises():
    yield 1
    raise ZeroDivisionError("from p")


show("p raises", lambda: math.sumprod(gen_raises(), [1, 2]))
show("q raises", lambda: math.sumprod([1, 2], gen_raises()))


# more_itertools' polynomial_eval recipe
def polynomial_eval(coefficients, x):
    n = len(coefficients)
    if n == 0:
        return x * 0
    powers = map(pow, [x] * n, reversed(range(n)))
    return math.sumprod(coefficients, powers)


show("poly int", lambda: polynomial_eval([1, -4, -17, 60], 2))
show("poly big", lambda: polynomial_eval([1, -4, -17, 60], 10**9))
show("poly frac", lambda: polynomial_eval([1, -4, -17, 60], Fraction(1, 3)))
show("poly dec", lambda: polynomial_eval([1, -4, -17, 60], Decimal("2.5")))
show("poly float", lambda: polynomial_eval([1, -4, -17, 60], 2.5))
show("poly cplx", lambda: polynomial_eval([1, -4, -17, 60], 1 + 2j))

print("=== prod ===")
show("ints", lambda: math.prod([1, 2, 3, 4]))
show("huge", lambda: math.prod([10**15, 10**15, 10**15]))
show("2**63", lambda: math.prod([2**32, 2**32]))
show("range", lambda: math.prod(range(1, 30)))
show("floats", lambda: math.prod([0.1, 0.2, 0.3]))
show("int float", lambda: math.prod([3, 0.1, 7]))
show("bools", lambda: math.prod([True, True]))
show("empty", lambda: math.prod([]))
show("empty start", lambda: math.prod([], start=2.5))
show("frac", lambda: math.prod([Fraction(1, 3), Fraction(3, 7)]))
show("frac int", lambda: math.prod([2, Fraction(1, 3)]))
show("dec", lambda: math.prod([Decimal("1.5"), Decimal("2")]))
show("dec start", lambda: math.prod([2, 3], start=Decimal("0.5")))
show("frac start", lambda: math.prod([2, 3], start=Fraction(1, 5)))
show("cplx", lambda: math.prod([1j, 1j, 2]))
show("float start", lambda: math.prod([2, 3], start=1.5))
show("big start", lambda: math.prod([2, 3], start=10**30))
show("str", lambda: math.prod(["ab", 3]))
show("str start", lambda: math.prod([3], start="ab"))
show("not iterable", lambda: math.prod(5))

print("=== fsum / hypot / dist ===")
show("fsum ints", lambda: math.fsum([1, 2, 3]))
show("fsum frac", lambda: math.fsum([Fraction(1, 3), Fraction(2, 3)]))
show("fsum dec", lambda: math.fsum([Decimal("0.1"), Decimal("0.2")]))
show("fsum str", lambda: math.fsum(["a"]))
show("hypot ints", lambda: math.hypot(3, 4))
show("hypot frac", lambda: math.hypot(Fraction(3), Fraction(4)))
show("hypot none", lambda: math.hypot())
show("dist ints", lambda: math.dist([0, 0], [3, 4]))
show("dist frac", lambda: math.dist([Fraction(0)], [Fraction(5, 2)]))
show("dist dec", lambda: math.dist([Decimal(0)], [Decimal("2.5")]))
show("dist len", lambda: math.dist([0, 0], [1]))

print("=== sumprod: float stress ===")
# A deterministic LCG, so both interpreters see the same doubles.
state = 12345


def rnd():
    global state
    state = (state * 6364136223846793005 + 1442695040888963407) % 2**64
    return state


def rfloat():
    r = rnd()
    mant = (r >> 11) / 2**53
    exp = (r & 63) - 32
    sign = -1.0 if r & 64 else 1.0
    return sign * mant * 2.0**exp


for trial in range(60):
    n = 1 + rnd() % 25
    p = [rfloat() for _ in range(n)]
    q = [rfloat() if rnd() % 5 else (rnd() % 1000 - 500) for _ in range(n)]
    print(trial, repr(math.sumprod(p, q)))

print("=== the operators sumprod and prod lean on ===")
show("prod positional start", lambda: math.prod([10, 20], 1))
show("prod no args", lambda: math.prod())
show("prod three args", lambda: math.prod([1], 2, 3))
show("prod start str", lambda: math.prod([2, 3], start="ab"))
show("prod start list", lambda: math.prod([2, 3], start=[1, 2]))
show("prod dict start", lambda: math.prod([], start={2: 3}))
show("sumprod huge int float", lambda: math.sumprod([10**1000], [1.0]))
show("sumprod float huge int", lambda: math.sumprod([1.0], [10**1000]))
show("huge int * float", lambda: 10**1000 * 1.0)
show("float + huge int", lambda: 1.0 + 10**1000)
show("float vs huge int", lambda: 1.0 < 10**1000)


def augmented():
    out = []
    for op in ("+=", "-=", "*=", "/=", "**="):
        x = 1.5
        if op == "+=":
            x += 2 + 1j
        elif op == "-=":
            x -= 2 + 1j
        elif op == "*=":
            x *= 2 + 1j
        elif op == "/=":
            x /= 2 + 1j
        else:
            x **= 2 + 1j
        out.append(x)
    return out


show("float op= complex", augmented)


def stress_case():
    total = 0
    for a, b in zip((3.75, 3.75), (3.75, 3 + 4j)):
        total += a * b
    return total, math.sumprod((3.75, 3.75), (3.75, 3 + 4j))


show("baseline loop", stress_case)


# test_math's sumprod stress oracle: an int subclass whose __add__ raises
# under `+=` must surface ITS exception, not "unsupported operand type(s)".
class Int(int):
    def __add__(self, other):
        return Int(int(self) + int(other))

    def __mul__(self, other):
        return Int(int(self) * int(other))

    __radd__ = __add__
    __rmul__ = __mul__

    def __repr__(self):
        return f"Int({int(self)})"


class Flt(float):
    def __add__(self, other):
        return Int(int(self) + int(other))

    def __mul__(self, other):
        return Int(int(self) * int(other))

    __radd__ = __add__
    __rmul__ = __mul__


def iadd_raises():
    total = Int(48)
    total += float("inf")
    return total


show("Int += inf", iadd_raises)
show("sumprod Flt inf", lambda: math.sumprod((3.75, 3.75), (Flt(13), float("inf"))))
show("sumprod Int", lambda: math.sumprod((Int(3), 2), (Int(4), 5)))
show("sumprod Flt", lambda: math.sumprod((Flt(3.5), 2.5), (2, 2.0)))


# A reflected dunder that RETURNS NotImplemented is a refusal, not a result.
class R:
    def __radd__(self, o):
        return NotImplemented

    def __rmul__(self, o):
        return NotImplemented


show("sum R", lambda: sum([1.5, R()]))
show("sum int R", lambda: sum([1, R()]))
show("prod R", lambda: math.prod([1.5, R()]))
show("sumprod R", lambda: math.sumprod([1.5], [R()]))
# (Only the exception's type: CPython's Decimal is the C one, named
# 'decimal.Decimal' in the message, and ours is _pydecimal's.)
try:
    math.sumprod([13.25, Decimal("10.5")], [13.25, Decimal("10.5")])
    print("sumprod dec after float: no error")
except TypeError:
    print("sumprod dec after float: TypeError")
