# bytes(obj) asks obj for __bytes__ first.
#
# CPython's bytes_new tries __bytes__ before a buffer, before __index__ and
# before the iterable path.  This asked nothing, so `bytes(headers)` on
# wsgiref's Headers -- which defines one -- fell through to the iterable path
# and indexed the mapping with integers until something asked an int to
# .lower().  That is what test_wsgiref ended on, and behind it a crash.
#
# Only a heaptype instance is asked: none of the builtins the buffer and
# iterable paths handle defines the dunder, so the order between them is not
# observable, and bytes(5) stays five zero bytes.


class Has:
    def __bytes__(self):
        return b"hello"

    # Present so that falling through to the iterable path would be visible
    # rather than merely different.
    def __getitem__(self, k):
        return k.lower()

    def __len__(self):
        return 3


print(bytes(Has()))


class Iterable:
    def __getitem__(self, k):
        if k > 2:
            raise IndexError
        return 65 + k


print(bytes(Iterable()))


class Returns5:
    def __bytes__(self):
        return 5


try:
    bytes(Returns5())
except TypeError:
    print("TypeError for a non-bytes __bytes__")


class Raises:
    def __bytes__(self):
        raise ValueError("no")


try:
    bytes(Raises())
except ValueError as e:
    print("ValueError", e)


class Sub(bytes):
    def __bytes__(self):
        return b"sub"


print(bytes(Sub(b"xy")), type(bytes(Sub(b"xy"))).__name__)


class Both:
    def __bytes__(self):
        return b"B"

    def __index__(self):
        return 3


# __bytes__ wins over __index__, which is CPython's order.  (__index__ ALONE
# is a count there and a TypeError here -- the old bug list recorded that.)
print(bytes(Both()))


class Inherits(Has):
    pass


print(bytes(Inherits()))


class NoDunder:
    pass


try:
    bytes(NoDunder())
except TypeError:
    print("TypeError for an object with nothing")

# Everything the constructor took before.
print(bytes(5), bytes(b"ab"), bytes([1, 2]), bytes(), bytes("a", "ascii"))
print(bytes(bytearray(b"q")), bytes(memoryview(b"mv")), bytes(range(3)))

import array

print(bytes(array.array("b", [1, 2])))

# bytearray does NOT consult it: CPython's bytearray_init has no such arm.
print(bytearray(Iterable()))


# A bytes SUBCLASS from __bytes__ is a bytes: CPython's check is
# PyBytes_Check, which takes one, and this asked `ob_type == bytes_type`.
class Sub(bytes):
    pass


class ReturnsSub:
    def __bytes__(self):
        return Sub(b"ab")


r = bytes(ReturnsSub())
print("subclass from __bytes__:", r, type(r).__name__)

# ...and the requested type decides what comes back.  bytes() hands over the
# dunder's own object, subclass and all; a SUBCLASS constructor adopts it,
# which is CPython's bytes_subtype_new.
class Other(bytes):
    pass


print("adopted:", type(Other(ReturnsSub())).__name__)


class ReturnsPlain:
    def __bytes__(self):
        return b"xy"


print("adopted plain:", type(Other(ReturnsPlain())).__name__,
      bytes(Other(ReturnsPlain())))

# A bytearray is still not a bytes, subclass rule or no.
class ReturnsBytearray:
    def __bytes__(self):
        return bytearray(b"ab")


try:
    bytes(ReturnsBytearray())
except TypeError:
    print("TypeError for a bytearray __bytes__")

# The subclass's own value still wins when it has no __bytes__ of its own.
print("plain subclass ctor:", type(Sub(b"zz")).__name__, Sub(b"zz"))
