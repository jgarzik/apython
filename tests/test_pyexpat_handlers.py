import sys
from xml.parsers import expat


def rejects(kind, operation):
    try:
        operation()
    except kind as exc:
        return exc
    raise AssertionError("expected " + kind.__name__)


document = (b'<!DOCTYPE r [<!ELEMENT r (a,(b|c)+)><!ELEMENT a EMPTY>'
            b'<!ENTITY word "caf&#233;"><!ENTITY remote PUBLIC "id" "data">]>'
            b'<r>&word;&remote;</r>')
p = expat.ParserCreate()
elements, entities, events = [], [], []
p.buffer_text = True
p.ElementDeclHandler = lambda name, model: elements.append((name, model))
p.EntityDeclHandler = lambda *args: entities.append(args)
p.CharacterDataHandler = lambda data: events.append(("text", data))


class Accept:
    def __index__(self):
        return 1


def external(context, base, system, public):
    assert isinstance(context, str)
    events.append(("external", base, system, public))
    return Accept()


p.ExternalEntityRefHandler = external
assert p.Parse(document, True) == 1
m = expat.model
assert elements == [
    ("r", (m.XML_CTYPE_SEQ, m.XML_CQUANT_NONE, None, (
        (m.XML_CTYPE_NAME, m.XML_CQUANT_NONE, "a", ()),
        (m.XML_CTYPE_CHOICE, m.XML_CQUANT_PLUS, None, (
            (m.XML_CTYPE_NAME, m.XML_CQUANT_NONE, "b", ()),
            (m.XML_CTYPE_NAME, m.XML_CQUANT_NONE, "c", ()),
        )),
    ))),
    ("a", (m.XML_CTYPE_EMPTY, m.XML_CQUANT_NONE, None, ())),
]
assert entities == [
    ("word", 0, "café", None, None, None, None),
    ("remote", 0, None, None, "data", "id", None),
]
assert events == [("text", "café"), ("external", None, "data", "id")]

for attr in ("DefaultHandler", "DefaultHandlerExpand"):
    p = expat.ParserCreate()
    defaults, text = [], []
    setattr(p, attr, defaults.append)
    p.CharacterDataHandler = text.append
    p.Parse(b'<!DOCTYPE r [<!ENTITY word "hello">]><r>&word;</r>', True)
    assert ("&word;" in defaults) is (attr == "DefaultHandler")
    assert text == (["hello"] if attr == "DefaultHandlerExpand" else [])

doctype = b'<!DOCTYPE r SYSTEM "external.dtd"><r/>'
p = expat.ParserCreate()
p.NotStandaloneHandler = lambda: 0
exc = rejects(expat.ExpatError, lambda: p.Parse(doctype, True))
assert exc.code == expat.errors.codes[expat.errors.XML_ERROR_NOT_STANDALONE]


class CallbackError(Exception):
    pass


def fail(*args):
    raise CallbackError


for attr, data in (
    ("ElementDeclHandler", document),
    ("EntityDeclHandler", document),
    ("ExternalEntityRefHandler", document),
    ("NotStandaloneHandler", doctype),
    ("DefaultHandler", b"<r/>"),
    ("DefaultHandlerExpand", b"<r/>"),
):
    p = expat.ParserCreate()
    setattr(p, attr, fail)
    rejects(CallbackError, lambda: p.Parse(data, True))

p = expat.ParserCreate()
p.ExternalEntityRefHandler = lambda *args: None
rejects(TypeError, lambda: p.Parse(document, True))

if sys.implementation.name == "apython":
    class Reenter:
        def __index__(self):
            rejects(RuntimeError, lambda: p.Parse(b"<nested/>", True))
            return 1

    p = expat.ParserCreate()
    p.ExternalEntityRefHandler = lambda *args: Reenter()
    assert p.Parse(document, True) == 1

    p = expat.ParserCreate()
    p.ElementDeclHandler = lambda *args: None
    nested_model = b"(" * 210 + b"a" + b")" * 210
    rejects(RecursionError,
            lambda: p.Parse(b"<!DOCTYPE r [<!ELEMENT r " + nested_model + b">]><r/>", True))

print("pyexpat handlers OK")
