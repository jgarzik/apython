import sys
from xml.parsers import expat


def rejects(kind, operation):
    try:
        operation()
    except kind as exc:
        return exc
    raise AssertionError("expected " + kind.__name__)


for doctype, expected in (
    (b"", (None, None)),
    (b'<!DOCTYPE r PUBLIC "public" "r.dtd">', ("public", "r.dtd")),
):
    p = expat.ParserCreate()
    assert p.GetBase() is None
    base = "file:///fixtures/r.xml"
    assert p.SetBase(base) is None and p.GetBase() == base
    p.UseForeignDTD()
    calls = []

    def dtd(context, base_url, system, public):
        assert context is None and base_url == base
        calls.append((public, system))
        child = p.ExternalEntityParserCreate(context)
        return child.Parse(b'<!ATTLIST r color CDATA "blue">', True)

    assert p.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_ALWAYS) == 1
    p.ExternalEntityRefHandler = dtd
    attrs = []
    p.StartElementHandler = lambda name, values: attrs.append(values)
    assert p.Parse(doctype + b"<r/>", True) == 1
    assert calls == [expected]
    assert attrs == [{"color": "blue"}]

p = expat.ParserCreate()
p.Parse(b"<r>")
assert p.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_ALWAYS) == 0
exc = rejects(expat.ExpatError, lambda: p.UseForeignDTD(False))
assert exc.code == expat.errors.codes[
    expat.errors.XML_ERROR_CANT_CHANGE_FEATURE_ONCE_PARSING]
rejects(TypeError, lambda: p.ExternalEntityParserCreate("", None))
rejects(ValueError, lambda: p.ExternalEntityParserCreate("x\0"))
rejects(ValueError, lambda: p.SetBase("x\0"))

p = expat.ParserCreate(namespace_separator="!")
p.buffer_size = 128
p.buffer_text = True
p.ordered_attributes = True
p.specified_attributes = True
p.namespace_prefixes = True
events = []
start = lambda name, attrs: events.append((name, attrs))
p.StartElementHandler = start
p.CharacterDataHandler = events.append


class Encoding(str):
    pass


def entity(context, base_url, system, public):
    child = p.ExternalEntityParserCreate(context, Encoding("iso8859"))
    assert child.intern is p.intern
    assert child.buffer_text is True and child.buffer_size == 128
    assert child.buffer_used == 0
    assert child.ordered_attributes is child.specified_attributes is True
    assert child.namespace_prefixes is True
    assert child.StartElementHandler is start
    p.StartElementHandler = None
    child.Parse(b'<n:leaf z="first" a="second">caf\xe9&amp;</n:leaf>', True)
    child.buffer_text = False
    assert p.buffer_text is True
    return 1


p.ExternalEntityRefHandler = entity
assert p.Parse(b'<!DOCTYPE r [<!ENTITY e SYSTEM "child">]>'
               b'<r xmlns:n="urn:leaf">&e;</r>', True) == 1
assert events == [
    ("r", []),
    ("urn:leaf!leaf!n", ["z", "first", "a", "second"]),
    "café&",
]

# Expat can consult the native parent during a deferred general-entity parse.
if sys.implementation.name == "apython":
    parent = expat.ParserCreate()
    children = []
    text = []
    parent.CharacterDataHandler = text.append

    def defer(context, *args):
        children.append(parent.ExternalEntityParserCreate(context))
        return 1

    parent.ExternalEntityRefHandler = defer
    parent.Parse(b'<!DOCTYPE r [<!ENTITY e SYSTEM "child">]><r>&e;</r>', True)
    del parent
    child = children.pop()
    assert child.Parse(b"retained child", True) == 1
    assert text == ["retained child"]

print("pyexpat external entities and DTDs OK")
