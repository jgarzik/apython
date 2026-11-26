class Sub(bytes):
    pass


class Text(str):
    pass


class Convertible:
    def __bytes__(self):
        return bytes(source="ok", encoding="ascii")


def rejects(call, kind, message):
    try:
        call()
    except kind as exc:
        assert str(exc) == message, str(exc)
    else:
        raise AssertionError("expected " + kind.__name__)


value = b"a\x00z"
assert bytes(value) is value
assert bytes(source=value) is value
assert bytes(source=Convertible()) == b"ok"

for ctor in (bytes, Sub):
    assert type(ctor()) is ctor
    assert type(ctor(source=value)) is ctor
    assert ctor(source=value) == value
    assert ctor(encoding=Text("utf-8"), source=Text("é")) == b"\xc3\xa9"
    assert ctor("café", errors=Text("ignore"), encoding=Text("ascii")) == b"caf"
    assert ctor(source=[65, 0, 255]) == b"A\x00\xff"
    assert ctor(source=2) == b"\x00\x00"
    rejects(lambda: ctor(encoding="utf-8"), TypeError,
            "encoding without a string argument")
    rejects(lambda: ctor(errors="ignore"), TypeError,
            "errors without a string argument")
    rejects(lambda: ctor(1, errors="ignore"), TypeError,
            "errors without a string argument")
    rejects(lambda: ctor("x", errors="ignore"), TypeError,
            "string argument without an encoding")
    rejects(lambda: ctor(encoding=2), TypeError,
            "bytes() argument 'encoding' must be str, not int")
    rejects(lambda: ctor("x", "utf-8", None), TypeError,
            "bytes() argument 'errors' must be str, not None")
    rejects(lambda: ctor("x", "utf\x008"), ValueError, "embedded null character")
    rejects(lambda: ctor("x", "utf8", errors="str\x00ict"), ValueError,
            "embedded null character")
    rejects(lambda: ctor("x", "a\x00\ud800"), UnicodeEncodeError,
            "'utf-8' codec can't encode character '\\ud800' in position 2: surrogates not allowed")
    rejects(lambda: ctor("x", "utf8", errors="\ud800"), UnicodeEncodeError,
            "'utf-8' codec can't encode character '\\ud800' in position 0: surrogates not allowed")
    rejects(lambda: ctor(value, source=value), TypeError,
            "argument for bytes() given by name ('source') and position (1)")
    rejects(lambda: ctor("x", "ascii", encoding="ascii"), TypeError,
            "argument for bytes() given by name ('encoding') and position (2)")
    rejects(lambda: ctor("x", "ascii", "strict", source="x"), TypeError,
            "bytes() takes at most 3 arguments (4 given)")
    rejects(lambda: ctor(source="x", encoding="ascii", errors="strict", extra=1),
            TypeError, "bytes() takes at most 3 keyword arguments (4 given)")
    for key in ("extra", "sou\x00ce", "λ" * 512):
        rejects(lambda: ctor(**{key: 1}), TypeError,
                "'%s' is an invalid keyword argument for bytes()" % key)

print("bytes constructor arguments OK")
