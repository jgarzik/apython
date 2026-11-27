# Every builtin binary operator against every builtin type, in both operand
# orders.  What is compared is the *protocol* -- which pairs are legal and what
# kind of thing comes out -- not arithmetic values; tests/test_arithmetic.py and
# tests/test_binop_mixed_values.py cover those.
#
# It exists because the builtin numeric slots used to trust whatever operand
# they were handed.  `1 + "a"` read the string's ob_length and answered 2;
# `1 + [1]` read past the end of a list and then wrote an mpz_t over its header;
# `{1,2} | 5` and `True * [1,2]` -- the second of which is legal Python --
# dumped core.  Nothing in the suite covered the quadrant, because
# tests/test_operand_types.py only ever puts the sequence on the left.
#
# Only names and small exact values are printed.  The TypeError text now
# matches CPython's -- operator and both operand types -- but this file still
# compares the exception's identity rather than its str(): a matrix cell has
# to stay short enough to locate in a diff.  tests/test_error_messages.py is
# where the wording is checked.  A float result prints as its type alone
# unless it is integral, because agreeing on repr digits is a different
# subsystem's job.


def show(v):
    # Cells are joined with spaces, so no cell may contain one: a repr with a
    # space in it would make a differing cell impossible to locate in the diff.
    t = type(v).__name__
    if isinstance(v, bool) or not isinstance(v, float):
        if isinstance(v, (set, frozenset)):
            body = repr(sorted(v))          # iteration order is not the spec
        else:
            body = repr(v)
        return t + body.replace(" ", "")
    # Finite integral floats repr identically everywhere; the rest do not
    # belong in a protocol test.
    if v == v and v not in (float("inf"), float("-inf")) and v == int(v):
        return t + repr(v)
    return t


def trial(fn, mk_a, mk_b):
    try:
        return show(fn(mk_a(), mk_b()))
    except Exception as e:
        return type(e).__name__


# Factories, not values: the inplace half mutates its left operand, so every
# cell needs a fresh one.  Operands are small, non-zero and deterministic --
# no ZeroDivisionError noise, and 3 ** 3 / 3 << 3 / "ab" * 3 all stay tiny.
TYPES = [
    ("int",       lambda: 3),
    ("bool",      lambda: True),
    ("float",     lambda: 1.5),
    ("str",       lambda: "ab"),
    ("bytes",     lambda: b"ab"),
    ("bytearray", lambda: bytearray(b"ab")),
    ("list",      lambda: [1, 2]),
    ("tuple",     lambda: (1, 2)),
    ("dict",      lambda: {1: 2}),
    ("set",       lambda: {1, 2}),
    ("frozenset", lambda: frozenset({1, 2})),
    ("NoneType",  lambda: None),
    ("range",     lambda: range(2)),
    ("slice",     lambda: slice(1, 2)),
    ("type",      lambda: int),
]

BINOPS = [
    ("+",  lambda a, b: a + b),
    ("-",  lambda a, b: a - b),
    ("*",  lambda a, b: a * b),
    ("/",  lambda a, b: a / b),
    ("//", lambda a, b: a // b),
    ("%",  lambda a, b: a % b),
    ("**", lambda a, b: a ** b),
    ("&",  lambda a, b: a & b),
    ("|",  lambda a, b: a | b),
    ("^",  lambda a, b: a ^ b),
    ("<<", lambda a, b: a << b),
    (">>", lambda a, b: a >> b),
]


# The inplace forms take a different route through op_binary_op: no builtin has
# an NB_INPLACE_* slot, so they reach a fallback that had a second and laxer
# coercion policy of its own -- `a = "s"; a %= 1.5` answered 0.0.
def _iadd(a, b):
    a += b
    return a


def _isub(a, b):
    a -= b
    return a


def _imul(a, b):
    a *= b
    return a


def _itruediv(a, b):
    a /= b
    return a


def _ifloordiv(a, b):
    a //= b
    return a


def _imod(a, b):
    a %= b
    return a


def _ipow(a, b):
    a **= b
    return a


def _iand(a, b):
    a &= b
    return a


def _ior(a, b):
    a |= b
    return a


def _ixor(a, b):
    a ^= b
    return a


def _ilshift(a, b):
    a <<= b
    return a


def _irshift(a, b):
    a >>= b
    return a


INPLACE = [
    ("+=", _iadd), ("-=", _isub), ("*=", _imul), ("/=", _itruediv),
    ("//=", _ifloordiv), ("%=", _imod), ("**=", _ipow), ("&=", _iand),
    ("|=", _ior), ("^=", _ixor), ("<<=", _ilshift), (">>=", _irshift),
]


# (operator, left type, right type) cells where apython and CPython disagree for
# a reason that is a missing *feature* rather than an unsafe one.  Every one of
# these raises TypeError or returns the wrong container type; none of them reads
# or writes memory it should not.  Each group was in the old bug list.
#
# The set was derived from the triage after the safety fixes landed, not guessed
# at up front -- a skip set written in advance is how one grows to cover real
# bugs.
SKIP = set()

# bytearray has no sq_concat and no sq_repeat, so those cells raise here and
# yield a value in CPython.  Its % works now.
for _op in ("+", "+="):                                     # sq_concat
    for _a, _b in (("bytearray", "bytearray"), ("bytearray", "bytes"),
                   ("bytes", "bytearray")):
        SKIP.add((_op, _a, _b))
for _op in ("*", "*="):                                     # sq_repeat
    for _a, _b in (("bytearray", "int"), ("int", "bytearray"),
                   ("bytearray", "bool"), ("bool", "bytearray")):
        SKIP.add((_op, _a, _b))

for name, fn in BINOPS + INPLACE:
    for lname, mk_a in TYPES:
        cells = []
        for rname, mk_b in TYPES:
            if (name, lname, rname) in SKIP:
                cells.append("skip")
            else:
                cells.append(trial(fn, mk_a, mk_b))
        print(name, lname, "|", " ".join(cells))
