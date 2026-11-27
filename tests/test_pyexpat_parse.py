# Parsing: the trampoline from libexpat back into Python, and the three
# handlers that need it most.
#
# This is the commit where the design is on trial.  libexpat calls OUR function
# pointer, which has to call a Python handler and then RETURN to libexpat --
# and the handler may raise.  The old bug list's "a raise from a C-level slot is a
# non-local jump" is about assembly RAISING (`RAISE` tail-jumps into the
# unwinder, which resets rsp to eval_base_rsp and never comes back); a CALLED
# Python function that raises returns control normally, because eval_frame
# publishes eval_base_rsp as its own rsp and eval_return hands back 0 with the
# exception pending.  Everything under "a handler that raises" below is that
# claim being tested rather than assumed.
#
# The other thing on trial is the three-valued return from the core:
#
#   1     a clean parse
#   0     libexpat reported an error and NOTHING is pending -- Python raises
#         ExpatError itself
#   NULL  a HANDLER raised; the exception is already travelling
#
# That split is why a handler's own ValueError is not turned into an
# ExpatError, which the zlib-style "core raises ValueError, Python converts"
# would have done -- and plistlib, expatreader and ElementTree all raise
# exceptions of their own from inside handlers.

import pyexpat

print("== the event stream, in order ==")
events = []
p = pyexpat.ParserCreate()
p.StartElementHandler = lambda n, a: events.append(("start", n, a))
p.EndElementHandler = lambda n: events.append(("end", n))
p.CharacterDataHandler = lambda d: events.append(("data", d))
print("Parse returned:", p.Parse('<a><b x="1" y="2">hello</b><c/></a>', True))
for e in events:
    print("  ", e)

print()
print("== str, bytes and bytearray all feed, and agree ==")
for kind, doc in (("str", '<a x="1">t</a>'), ("bytes", b'<a x="1">t</a>'),
                  ("bytearray", bytearray(b'<a x="1">t</a>'))):
    out = []
    q = pyexpat.ParserCreate()
    q.StartElementHandler = lambda n, a: out.append((n, a))
    q.CharacterDataHandler = lambda d: out.append(d)
    q.EndElementHandler = lambda n: out.append("/" + n)
    print("%-10s %s %s" % (kind, q.Parse(doc, True), out))


class mystr(str):
    pass


class mybytes(bytes):
    pass


for kind, doc in (("str subclass", mystr('<a>t</a>')),
                  ("bytes subclass", mybytes(b'<a>t</a>'))):
    out = []
    q = pyexpat.ParserCreate()
    q.StartElementHandler = lambda n, a: out.append(n)
    q.Parse(doc, True)
    print("%-16s %s" % (kind, out))

print()
print("== a document arriving in chunks ==")
out = []
v = pyexpat.ParserCreate()
v.StartElementHandler = lambda n, a: out.append("<" + n)
v.EndElementHandler = lambda n: out.append(n + ">")
v.CharacterDataHandler = lambda d: out.append(d)
for chunk in ("<a>", "he", "llo", "<b/>", "</a>"):
    v.Parse(chunk, False)
print("final chunk:", v.Parse("", True))
print(out)

print()
print("== non-ASCII in names, attributes and text ==")
w = pyexpat.ParserCreate()
seen = []
w.StartElementHandler = lambda n, a: seen.append((n, a))
w.CharacterDataHandler = lambda d: seen.append(d)
w.Parse('<données attr="héllo">naïve — ☃</données>', True)
print(seen)
# The same through bytes, which is the path a file takes.
w2 = pyexpat.ParserCreate()
seen2 = []
w2.StartElementHandler = lambda n, a: seen2.append(n)
w2.CharacterDataHandler = lambda d: seen2.append(d)
w2.Parse('<données>naïve</données>'.encode(), True)
print(seen2)
print("both routes agree:", seen2[0] == seen[0][0])

print()
print("== a repeated name is the SAME object, through the intern dict ==")
x = pyexpat.ParserCreate()
tags = []
x.StartElementHandler = lambda n, a: tags.append(n)
x.Parse("<r><a/><a/><a/><b/></r>", True)
print("names:", tags)
print("repeats are identical:", tags[1] is tags[2] is tags[3])
print("in the intern dict:", sorted(k for k in x.intern if isinstance(k, str)))
print("and the dict holds the same object:", x.intern["a"] is tags[1])
# Attribute NAMES are interned; attribute VALUES are not -- a document has
# few distinct names and many distinct values.
y = pyexpat.ParserCreate()
attrs = []
y.StartElementHandler = lambda n, a: attrs.append(a)
y.Parse('<r><i k="1"/><i k="2"/></r>', True)
# attrs[0] is <r>, which has none; the two <i> elements are 1 and 2.
print("attr names interned:", list(attrs[1])[0] is list(attrs[2])[0])
print("attr values are not:", attrs[1]["k"] != attrs[2]["k"])

print()
print("== the intern dict is the CALLER's, and may hold anything ==")
# `parser.intern` is documented and public, and expatbuilder writes into it
# with setdefault -- so a caller can put a non-string, or an int, in it, and
# whatever is there is what the handler receives.  CPython hands it back
# without a type check; the values are VALUES, so an immediate int or float
# must not be dereferenced.
for label, table in (("int value", {"a": 5}),
                     ("float value", {"a": 1.5}),
                     ("None value", {"a": None}),
                     ("bool value", {"a": True}),
                     ("a str, as usual", {"a": "REPLACED"}),
                     ("a big int", {"a": 1 << 70}),
                     ("empty", {})):
    out = []
    ip = pyexpat.ParserCreate(intern=table)
    ip.StartElementHandler = lambda n, at: out.append(n)
    ip.EndElementHandler = lambda n: out.append(n)
    ip.Parse("<a><a/></a>", True)
    print("%-18s %r" % (label, out))
# A pre-seeded entry is used rather than replaced, and a new name is added.
seeded = {"a": "FROM-TABLE"}
ip = pyexpat.ParserCreate(intern=seeded)
names = []
ip.StartElementHandler = lambda n, at: names.append(n)
ip.Parse("<a><b/></a>", True)
print("seeded name used:", names)
print("new name added to the caller's dict:", sorted(k for k in seeded))
# Attribute names go through the same table.
seeded2 = {"k": 99}
ip = pyexpat.ParserCreate(intern=seeded2)
got = []
ip.StartElementHandler = lambda n, at: got.append(at)
ip.Parse('<r k="v"/>', True)
print("attribute name from the table:", got)

print()
print("== ordered_attributes gives a FLAT LIST, not a dict ==")
# ElementTree sets this and then indexes the result numerically, so a dict
# there is a KeyError rather than a slower answer.
for ordered in (False, True):
    out = []
    z = pyexpat.ParserCreate()
    z.ordered_attributes = ordered
    z.StartElementHandler = lambda n, a: out.append((n, a, type(a).__name__))
    z.Parse('<a p="1" q="2"><b/></a>', True)
    print("ordered=%-5s %s" % (ordered, out))

print()
print("== specified_attributes drops what came from the DTD ==")
doc = ('<!DOCTYPE a [<!ELEMENT b EMPTY><!ATTLIST b '
       'given CDATA #IMPLIED defaulted CDATA "D">]><a><b given="g"/></a>')
for spec in (False, True):
    out = []
    s = pyexpat.ParserCreate()
    s.specified_attributes = spec
    s.StartElementHandler = lambda n, a: out.append((n, a))
    s.Parse(doc, True)
    print("specified=%-5s %s" % (spec, out))
# And the same with the flat list, where the count is what does the dropping.
for spec in (False, True):
    out = []
    s = pyexpat.ParserCreate()
    s.specified_attributes = spec
    s.ordered_attributes = True
    s.StartElementHandler = lambda n, a: out.append((n, a))
    s.Parse(doc, True)
    print("specified=%-5s ordered %s" % (spec, out))

print()
print("== a handler that raises: the whole point of the trampoline ==")
seen = []
p = pyexpat.ParserCreate()


def boom(name, attrs):
    seen.append(name)
    if name == "b":
        raise RuntimeError("from the handler")


p.StartElementHandler = boom
p.EndElementHandler = lambda n: seen.append("/" + n)
try:
    p.Parse("<a><b/><c/></a>", True)
    print("NO RAISE -- wrong")
except RuntimeError as e:
    print("propagated unchanged:", type(e).__name__, e)
print("events before it:", seen)
print("nothing fired after it:", seen == ["a", "b"])

print()
print("== and the parser is finished, not merely confused ==")
try:
    p.Parse("<d/>", True)
    print("accepted more -- wrong")
except pyexpat.ExpatError as e:
    print("ExpatError, code is XML_ERROR_FINISHED:",
          e.code == pyexpat.errors.codes[pyexpat.errors.XML_ERROR_FINISHED])

print()
print("== a handler's own exception type SURVIVES ==")
# This is what the int-0/NULL split buys.  A converting `except ValueError`
# would have reported an ExpatError here, and plistlib's handler raises
# InvalidFileException, expatreader's raise SAXException, ElementTree's target
# raises ParseError.
for exc in (ValueError("mine"), KeyError("k"), StopIteration(),
            pyexpat.ExpatError("mine too")):
    r = pyexpat.ParserCreate()

    def thrower(n, a, _e=exc):
        raise _e

    r.StartElementHandler = thrower
    try:
        r.Parse("<a/>", True)
        print("%-18s NOT RAISED" % type(exc).__name__)
    except BaseException as e:
        print("%-18s %s  same object: %s"
              % (type(exc).__name__, type(e).__name__, e is exc))

print()
print("== a handler raising from DEEP in a document ==")
depth = []
d = pyexpat.ParserCreate()


def deep(n, a):
    depth.append(n)
    if len(depth) == 5:
        raise ArithmeticError("deep")


d.StartElementHandler = deep
try:
    d.Parse("<a><b><c><d><e><f><g/></f></e></d></c></b></a>", True)
except ArithmeticError as e:
    print("raised at depth", len(depth), ":", e)
print("saw:", depth)

print()
print("== a malformed document is an ExpatError with all three fields ==")
for bad in ("<a><b></a>", "<a", "", "<a>&nosuch;</a>", "<a></a><b/>",
            "<a x='1' x='2'/>"):
    q = pyexpat.ParserCreate()
    try:
        q.Parse(bad, True)
        print("%-20s ACCEPTED" % repr(bad))
    except pyexpat.ExpatError as e:
        print("%-20s %s | code=%d lineno=%d offset=%d"
              % (repr(bad), e, e.code, e.lineno, e.offset))

print()
print("== the error fields agree with the parser's own attributes ==")
q = pyexpat.ParserCreate()
try:
    q.Parse("<a>\n<b>\n</a>", True)
except pyexpat.ExpatError as e:
    print("code:", e.code == q.ErrorCode)
    print("lineno:", e.lineno == q.ErrorLineNumber)
    print("offset:", e.offset == q.ErrorColumnNumber)
    print("and the message is built from them:",
          str(e) == "%s: line %d, column %d"
          % (pyexpat.ErrorString(e.code), e.lineno, e.offset))

print()
print("== a handler cleared from inside a callback stops firing ==")
t = pyexpat.ParserCreate()
hits = []


def once(name, attrs):
    hits.append(name)
    t.StartElementHandler = None


t.StartElementHandler = once
t.Parse("<a><b/><c/></a>", True)
print("fired once:", hits)

print()
print("== handlers can be swapped mid-parse ==")
u = pyexpat.ParserCreate()
log = []
u.StartElementHandler = lambda n, a: (log.append("first:" + n),
                                      setattr(u, "StartElementHandler",
                                              lambda n2, a2: log.append("second:" + n2)))
u.Parse("<a><b/><c/></a>", True)
print(log)

print()
print("== ParseFile, over a BytesIO ==")
import io

f = io.BytesIO(b'<a><b x="1"/>text</a>')
out = []
pf = pyexpat.ParserCreate()
pf.StartElementHandler = lambda n, a: out.append((n, a))
pf.CharacterDataHandler = lambda d: out.append(d)
print("ParseFile returned:", pf.ParseFile(f))
print(out)
# A file whose read() answers a str is refused.


class StrFile:
    def read(self, n):
        return "not bytes"


try:
    pyexpat.ParserCreate().ParseFile(StrFile())
except TypeError as e:
    print("str from read():", e)

print()
print("== Parse's own argument checking ==")
pa = pyexpat.ParserCreate()
for bad in (None, 7, [1], {}):
    try:
        pyexpat.ParserCreate().Parse(bad, True)
        print("%-6r ACCEPTED" % bad)
    except TypeError as e:
        print("%-6r TypeError" % bad)

print()
print("== a parser with no handlers at all parses fine ==")
n = pyexpat.ParserCreate()
print("returned:", n.Parse("<a><b>text</b></a>", True))
print("and still reports a position:", n.CurrentLineNumber >= 1)

print()
print("== many parsers, interleaved ==")
ps = []
seen = []
for i in range(8):
    pp = pyexpat.ParserCreate()
    pp.StartElementHandler = (lambda idx: lambda n, a: seen.append((idx, n)))(i)
    pp.Parse("<r%d>" % i, False)
    ps.append(pp)
for i, pp in enumerate(ps):
    pp.Parse("<inner%d/></r%d>" % (i, i), True)
print(seen)
del ps
print("released")
