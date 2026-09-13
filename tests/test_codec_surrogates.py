"""The two surrogate error handlers, and the encoder that must refuse a lone one.

`surrogateescape` is how a filename that is not valid UTF-8 survives a decode
and an encode unchanged -- `sys.getfilesystemencodeerrors()` names it, and
`os.fsdecode`/`os.fsencode` are written against it.  `surrogatepass` is the
other direction: it lets a lone surrogate through a UTF-8 codec on purpose.

Everything here is diffed against CPython, so the wordings and the positions
are CPython's rather than ours.
"""

import os
import sys


def show(label, fn):
    try:
        print(label, repr(fn()))
    except Exception as e:                      # noqa: BLE001 - the point
        print(label, type(e).__name__, str(e))


print("--- surrogateescape, decode ---")
show("lone high byte ", lambda: b"caf\xe9.txt".decode("utf-8", "surrogateescape"))
show("several        ", lambda: b"\xff\xfe\x80".decode("utf-8", "surrogateescape"))
show("mixed          ", lambda: b"a\xe9b\xffc".decode("utf-8", "surrogateescape"))
show("ascii untouched", lambda: b"plain".decode("utf-8", "surrogateescape"))
show("valid utf-8 kept", lambda: b"caf\xc3\xa9".decode("utf-8", "surrogateescape"))

print("--- surrogateescape, encode ---")
show("round trip     ", lambda: "caf\udce9.txt".encode("utf-8", "surrogateescape"))
show("several        ", lambda: "\udcff\udcfe\udc80".encode("utf-8", "surrogateescape"))
show("not in range   ", lambda: "\ud800".encode("utf-8", "surrogateescape"))
show("ordinary text  ", lambda: "café".encode("utf-8", "surrogateescape"))

print("--- surrogateescape round trips ---")
for raw in (b"caf\xe9.txt", b"\xff", b"a\x80b", b"plain.txt", b"\xc3\xa9"):
    s = os.fsdecode(raw)
    print(repr(raw), "->", repr(s), "->", repr(os.fsencode(s)),
          "closes:", os.fsencode(s) == raw)

print("--- surrogatepass ---")
show("encode lone hi ", lambda: "\ud800".encode("utf-8", "surrogatepass"))
show("encode lone lo ", lambda: "\udfff".encode("utf-8", "surrogatepass"))
show("decode lone hi ", lambda: b"\xed\xa0\x80".decode("utf-8", "surrogatepass"))
show("decode lone lo ", lambda: b"\xed\xbf\xbf".decode("utf-8", "surrogatepass"))
show("decode invalid ", lambda: b"\xff".decode("utf-8", "surrogatepass"))
show("mixed          ", lambda: "a\ud800b".encode("utf-8", "surrogatepass"))

print("--- a lone surrogate is not encodable by a plain utf-8 encoder ---")
for h in ("strict", "ignore", "replace", "backslashreplace", "xmlcharrefreplace"):
    show("utf-8/%-18s" % h, lambda h=h: "a\ud800b".encode("utf-8", h))
show("escape half     ", lambda: "\udc80".encode("utf-8"))

print("--- the error object a refusal carries ---")
try:
    "a\ud800b".encode("utf-8")
except UnicodeEncodeError as e:
    print("encoding", e.encoding, "| start", e.start, "| end", e.end,
          "| object", repr(e.object), "| reason", e.reason)

try:
    b"a\xe9b".decode("utf-8")
except UnicodeDecodeError as e:
    print("encoding", e.encoding, "| start", e.start, "| end", e.end,
          "| object", repr(e.object), "| reason", e.reason)

print("--- the handler names are registered ---")
import _codecs
for name in ("strict", "ignore", "replace", "backslashreplace",
             "xmlcharrefreplace", "surrogateescape", "surrogatepass"):
    print(name, "->", _codecs.lookup_error(name) is not None)

print("--- filesystem encoding advertises what it can do ---")
print(sys.getfilesystemencoding(), sys.getfilesystemencodeerrors())
