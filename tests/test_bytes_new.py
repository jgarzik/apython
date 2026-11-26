import gc
import weakref


class Sub(bytes):
    pass


events = []


class WithHooks(Sub):
    def __new__(cls, source=b"", **kwargs):
        events.append("new")
        return super().__new__(cls, source, **kwargs)

    def __init__(self, source=b"", **kwargs):
        events.append("init")
        self.enc = kwargs.get("encoding")


class BaseSpelling(bytes):
    def __new__(cls, value):
        result = bytes.__new__(cls, value)
        result.seen = True
        return result


class Boom(Exception):
    pass


class Convertible:
    def __bytes__(self):
        return b"\x00\xff"


class Broken:
    def __bytes__(self):
        raise Boom("from __bytes__")


class Payload:
    pass


def rejects(kind, fn, message=None):
    try:
        fn()
    except kind as exc:
        if message is not None:
            assert str(exc) == message, str(exc)
    else:
        raise AssertionError("expected " + kind.__name__)


raw = b"a\x00b"
assert bytes.__new__(bytes, source=raw) is raw
assert type(Sub.__new__(Sub)) is Sub
b = bytes.__new__(Sub, source=raw)
assert b == raw and type(b) is Sub and vars(b) == {}
assert bytes.__new__(Sub, b) is not b
assert bytes.__new__(Sub, source=Convertible()) == b"\x00\xff"
b = bytes.__new__(WithHooks, encoding="utf8", source="é")
assert b == b"\xc3\xa9" and type(b) is WithHooks
assert events == [] and not hasattr(b, "enc")
b = WithHooks("é", encoding="utf8")
assert b == b"\xc3\xa9" and b.enc == "utf8"
assert events == ["new", "init"]
events.clear()
b = WithHooks.fromhex("00 ff")
assert b == b"\x00\xff" and type(b) is WithHooks and b.enc is None
assert events == ["new", "init"]
b = BaseSpelling.fromhex("41")
assert b == b"A" and type(b) is BaseSpelling and b.seen

rejects(TypeError, lambda: bytes.__new__(),
        "bytes.__new__(): not enough arguments")
rejects(TypeError, lambda: bytes.__new__(source=b"x"),
        "bytes.__new__(): not enough arguments")
rejects(TypeError, lambda: bytes.__new__(1),
        "bytes.__new__(X): X is not a type object (int)")
rejects(TypeError, lambda: bytes.__new__(str),
        "bytes.__new__(str): str is not a subtype of bytes")
rejects(TypeError, lambda: bytes.__new__(Sub, extra=1),
        "'extra' is an invalid keyword argument for bytes()")
rejects(Boom, lambda: bytes.__new__(Sub, source=Broken()), "from __bytes__")
rejects(UnicodeEncodeError, lambda: bytes.__new__(Sub, "é", encoding="ascii"))

# The attribute dictionary sits past the variable payload and owns its Values.
for source in (b"", b"odd", b"\x00" * 513):
    b = bytes.__new__(Sub, source)
    obj = Payload()
    ref = weakref.ref(obj)
    b.obj = obj
    obj.value = b
    assert b == source and len(b) == len(source)
    del b, obj
    gc.collect()
    assert ref() is None

print("bytes.__new__ OK")
