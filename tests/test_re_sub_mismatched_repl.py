# re.sub with a replacement of the other string type -- a str for a bytes
# pattern, or bytes for a str one -- only fails when a match is actually
# replaced, and then with the join's own wording ("sequence item N: expected
# a bytes-like object, str found").  With no match it returns the input
# unchanged.  tabulate strips ANSI codes from bytes cells with
# `bytes_pattern.sub(r"\4", s)`, which CPython never notices because the
# cells have none; it was a TypeError on every bytes cell.
import re

p = re.compile(b"(z)(z)(z)(z)")
for repl in (r"\4", "x", r"x\1"):
    print(repr(repl), p.sub(repl, b"aa"), p.subn(repl, b"aa"))

q = re.compile("(z)")
print(q.sub(b"x", "aa"), q.subn(b"\\1", "abc"))

for pat, repl, s in ((p, r"\4", b"zzzz"), (p, "x", b"zzzz"), (q, b"x", "z"),
                     (q, b"y\\1", "az")):
    try:
        print(pat.sub(repl, s))
    except TypeError as e:
        print("TypeError:", e)
