from array import array
from io import BytesIO


a = array("B", [97, 98, 99])
assert b"x" + a == b"xabc"
assert b"x" + memoryview(b"abc")[1:] == b"xbc"
assert b"x" + memoryview(b"") == b"x"

with BytesIO(b"abc") as stream:
    view = stream.getbuffer()
    assert b"x" + view == b"xabc"
    view.release()
    for bad in (view, memoryview(b"abc")[::2], [97, 98]):
        try:
            b"x" + bad
        except TypeError:
            pass
        else:
            raise AssertionError("non-contiguous or non-buffer operand accepted")
