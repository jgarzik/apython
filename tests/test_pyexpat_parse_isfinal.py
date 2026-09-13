"""`xmlparser.Parse`'s isfinal argument, which is any object at all.

CPython runs it through the ordinary truth test, so an int, a bool, None and
a list are all accepted.  Here it reached `obj_is_true` through a `V_UNPACK`
left over from before the value representation changed -- so it was handed a
raw PAYLOAD where the function wants a Value.  A bool, None and a str are
pointers and a pointer is its own Value, so those went on working; an int
immediate's payload is the number itself, and `Parse(data, 0)` dereferenced
address 0.

That is why nothing caught it: every caller in the stdlib passes a bool.
ElementTree's `feed` says `Parse(data, False)` and its `close` says
`Parse(b"", True)`.
"""

import pyexpat


print("--- isfinal takes anything with a truth value ---")
for v in (True, False, 0, 1, 2, None, "x", [], 1.5):
    p = pyexpat.ParserCreate()
    try:
        print("%-6r -> %r" % (v, p.Parse(b"<r/>", v)))
    except Exception as e:                      # noqa: BLE001 - the point
        print("%-6r -> %s %s" % (v, type(e).__name__, e))

print("--- and it decides whether the document may end here ---")
p = pyexpat.ParserCreate()
print("half a document, isfinal 0:", p.Parse(b"<root>", 0))
print("the rest, isfinal 1:", p.Parse(b"</root>", 1))

p = pyexpat.ParserCreate()
try:
    p.Parse(b"<root>", 1)
except Exception as e:                          # noqa: BLE001 - the point
    print("half a document, isfinal 1:", type(e).__name__, e)

print("--- an incremental parse with handlers, driven by ints ---")
events = []
p = pyexpat.ParserCreate()
p.StartElementHandler = lambda name, attrs: events.append(("start", name))
p.EndElementHandler = lambda name: events.append(("end", name))
for chunk, final in ((b"<root>", 0), (b"<a/>", 0), (b"<b/>", 0), (b"</root>", 1)):
    p.Parse(chunk, final)
print(events)

print("--- the default is 0 ---")
p = pyexpat.ParserCreate()
print("no second argument:", p.Parse(b"<root>"))
print("then finish:", p.Parse(b"</root>", 1))
