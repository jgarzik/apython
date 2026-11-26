import codecs
import sys
from xml.parsers import expat


def xml(encoding, body):
    return b"<?xml version='1.0' encoding='" + encoding + b"'?><r>" + body + b"</r>"


def parse(document, reader=None):
    output = []
    parser = expat.ParserCreate()
    parser.CharacterDataHandler = output.append
    if reader is None:
        assert parser.Parse(document, True) == 1
    else:
        assert parser.ParseFile(reader(document)) == 1
    return "".join(output)


class Chunks:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def read(self, size):
        head = self.pos
        self.pos += min(7, size)
        return self.data[head:self.pos]


def fails(kind, operation):
    try:
        operation()
    except kind as error:
        return error
    raise AssertionError("expected " + kind.__name__)


assert parse(xml(b"ascii", b"seven")) == "seven"
assert parse(xml(b"iso-8859-15", b"\xa4"), Chunks) == "€"
assert parse(xml(b"cp437", b"\xfb")) == "√"
assert parse(xml(b"iso2022-jp-2004", b"plain")) == "plain"
assert parse(xml(b"hz", b"plain"), Chunks) == "plain"

cp1252 = codecs.lookup("cp1252")
calls = []


def decode(data, errors="strict"):
    calls.append((len(data), errors))
    return cp1252.decode(data, errors)


class RegistryError(Exception):
    pass


def raises(data, errors="strict"):
    raise RegistryError("decoder refused input")


def search(name):
    if name == "expat_test":
        return codecs.CodecInfo(encode=cp1252.encode, decode=decode, name=name)
    if name == "expat_raises":
        return codecs.CodecInfo(encode=cp1252.encode, decode=raises, name=name)
    return None


codecs.register(search)
try:
    assert parse(xml(b"expat-test", b"\x80")) == "€"
    assert calls == [(256, "replace")]
    error = fails(RegistryError, lambda: parse(xml(b"expat-raises", b"a")))
    assert str(error) == "decoder refused input"
finally:
    codecs.unregister(search)

error = fails(expat.ExpatError, lambda: parse(xml(b"cp1252", b"\x81")))
assert error.code == expat.errors.codes[expat.errors.XML_ERROR_INVALID_TOKEN]
fails(LookupError, lambda: parse(xml(b"expat-does-not-exist", b"a")))
error = fails(ValueError, lambda: parse(xml(b"gb18030", b"a")))
assert str(error) == "multi-byte encodings are not supported"

parent = expat.ParserCreate()
chars = []
parent.CharacterDataHandler = chars.append


def external(context, base, system, public):
    child = parent.ExternalEntityParserCreate(context, "mac-roman")
    return child.Parse("˚".encode("mac-roman"), True)


parent.ExternalEntityRefHandler = external
assert parent.Parse(b"<!DOCTYPE r [<!ENTITY e SYSTEM 'child'>]><r>&e;</r>", True) == 1
assert chars == ["˚"]

if sys.implementation.name == "apython":
    import _pyexpatcore

    handle = _pyexpatcore.parser_new(None, None, None, lambda name: 1)
    try:
        fails(TypeError, lambda: _pyexpatcore.parser_parse(handle, xml(b"test", b""), True))
    finally:
        _pyexpatcore.parser_free(handle)

print("Expat codec registry, errors and external encoding OK")
