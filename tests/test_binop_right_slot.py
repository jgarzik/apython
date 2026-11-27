# The right operand's slot gets a turn when the LEFT type has none.
#
# op_binary_op used to reach .binop_try_right_slot only after a left slot that
# was present and *declined*.  When the left type had no tp_as_number at all,
# or a NULL entry in it, the dispatcher jumped straight to the dunder arm --
# which requires TYPE_FLAG_HEAPTYPE and so refuses every builtin static type.
# CPython's binary_op1 asks the right operand's slot in both cases.
#
# The visible symptom was `None | int`: NoneType's nb_or is 0 and type's is
# union_type_or, so nothing was ever asked and it came out a TypeError.

u = None | int
print(type(u).__name__)
print(u == (int | None))
print(u == (None | int))

# The same shape one level up: a union on the right of a None.
print(type(None | (int | str)).__name__)

# What must NOT change: a pair neither side can serve is still a TypeError,
# and it still names no operator (the old bug list recorded that wording gap).
for expr in ("None + 1", "1 + None", "None * 2", "[] - []", "'a' - 'b'"):
    try:
        eval(expr)
        print(expr, "=> no error")
    except TypeError as e:
        print(expr, "=> TypeError")

# Ordinary arithmetic is untouched.
print(1 + 2, 1.5 * 2, "ab" * 2, [1] + [2], 7 // 2, 7 % 2, 2 ** 10)
print(3 | 5, 3 & 5, 3 ^ 5, 1 << 4, 32 >> 2)


# CPython's subclass-priority rule, the other half of binary_op1 -- and the
# half of do_richcompare that the old bug list did not record at all.  When the right
# operand's type is a PROPER SUBCLASS of the left's and overrides the
# operator, the right side goes first: P() + Q() for a Q(P) defining __radd__
# is Q.__radd__, and P() < Q() for a Q defining __gt__ is Q.__gt__.
#
# It cannot be binary_op1's `slotv != slotw`.  Every heaptype that overrides
# an operator holds the same slots.asm wrapper, so that compare is always
# equal and the rule would never fire; and a class defining only __radd__
# inherits int's nb_add, where CPython's slot_nb_add serves both directions
# and so differs from long_add.  The reflected NAME is what is asked for, on
# both types, which is CPython's own method_is_overloaded.


class P:
    def __add__(self, o): return "P.add"
    def __sub__(self, o): return "P.sub"
    def __mul__(self, o): return "P.mul"
    def __truediv__(self, o): return "P.div"
    def __mod__(self, o): return "P.mod"
    def __pow__(self, o): return "P.pow"
    def __and__(self, o): return "P.and"
    def __or__(self, o): return "P.or"
    def __xor__(self, o): return "P.xor"
    def __lshift__(self, o): return "P.lshift"
    def __rshift__(self, o): return "P.rshift"
    def __floordiv__(self, o): return "P.floordiv"
    def __matmul__(self, o): return "P.matmul"
    def __divmod__(self, o): return "P.divmod"
    def __lt__(self, o): return "P.lt"
    def __le__(self, o): return "P.le"
    def __eq__(self, o): return "P.eq"
    def __ne__(self, o): return "P.ne"
    def __gt__(self, o): return "P.gt"
    def __ge__(self, o): return "P.ge"
    __hash__ = None


class Q(P):
    def __radd__(self, o): return "Q.radd"
    def __rsub__(self, o): return "Q.rsub"
    def __rmul__(self, o): return "Q.rmul"
    def __rtruediv__(self, o): return "Q.rdiv"
    def __rmod__(self, o): return "Q.rmod"
    def __rpow__(self, o): return "Q.rpow"
    def __rand__(self, o): return "Q.rand"
    def __ror__(self, o): return "Q.ror"
    def __rxor__(self, o): return "Q.rxor"
    def __rlshift__(self, o): return "Q.rlshift"
    def __rrshift__(self, o): return "Q.rrshift"
    def __rfloordiv__(self, o): return "Q.rfloordiv"
    def __rmatmul__(self, o): return "Q.rmatmul"
    def __rdivmod__(self, o): return "Q.rdivmod"
    def __lt__(self, o): return "Q.lt"
    def __gt__(self, o): return "Q.gt"


p, q = P(), Q()
print(p + q, p - q, p * q, p / q, p % q, p ** q)
print(p & q, p | q, p ^ q, p << q, p >> q, p // q, p @ q, divmod(p, q))
print(p < q, p > q, p <= q, p >= q, p == q, p != q)

# The other direction, and two of the same type, are untouched.
print(q + p, p + p, q + q, q < p, p < p, q < q)


# An INHERITED reflected method is not an override; a redefined one is.
class R(P):
    pass


class S(P):
    def __radd__(self, o): return "S.radd"


class T(S):
    pass


print(p + R(), p + S(), p + T())
print(p < R(), p == R())


# A subclass that overrides only the forward operator changes nothing.
class U(P):
    def __add__(self, o): return "U.add"


print(p + U())


# A class that is not a subclass still comes second.
class V:
    def __radd__(self, o): return "V.radd"


print(p + V())


# The builtin left operand, which is where the rule's other shape lives: an
# immediate has no ob_type, and its type has to be named the way
# .binop_left_type names it.
class MyInt(int):
    def __radd__(self, o): return "MyInt.radd"
    def __lt__(self, o): return "MyInt.lt"
    def __gt__(self, o): return "MyInt.gt"
    __hash__ = int.__hash__


class MyStr(str):
    def __radd__(self, o): return "MyStr.radd"
    def __gt__(self, o): return "MyStr.gt"


class MyList(list):
    def __radd__(self, o): return "MyList.radd"


print(1 + MyInt(2), MyInt(2) + 1)
print(1 < MyInt(2), MyInt(2) < 1, 1 > MyInt(2))
print(1 == MyInt(1), MyInt(1) == 1)
print("a" + MyStr("b"), MyStr("b") + "a")
print("a" < MyStr("b"), MyStr("b") < "a")
print([1] + MyList([2]), MyList([2]) + [1])


# A forward-only builtin subclass is not preferred -- CPython answers 3.
class D(int):
    def __add__(self, o): return "D.add"


print(1 + D(2), D(2) + 1)

# And nothing about ordinary operands changes.
print(1 + 2, 1.5 * 2, "ab" * 2, [1] + [2], 7 // 2, 7 % 2, 2 ** 10, {1} | {2})
print(1 < 2, "a" < "b", [1] < [2], (1,) < (2,), 1 == 1.0, 1 < 2.5)
print(sorted([3, 1, 2]), sorted(["b", "a"]), sorted([1.5, 0.5]))
