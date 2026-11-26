from xml.parsers import expat


def collect(parser, document):
    text = []
    parser.CharacterDataHandler = text.append
    assert parser.Parse(document, True) == 1
    return "".join(text)


data = b"<r>caf\xe9 \xff</r>"
for spelling in ("iso8859", "ISO8859"):
    declaration = ("<?xml version='1.0' encoding='%s'?>" % spelling).encode()
    assert collect(expat.ParserCreate(), declaration + data) == "café ÿ"
    assert collect(expat.ParserCreate(spelling), data) == "café ÿ"

print("pyexpat Latin-1 alias OK")
