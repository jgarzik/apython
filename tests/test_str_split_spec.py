# split, rsplit and the strip family, over the boundaries their new
# implementations actually have.
#
# The separator scan is now one ap_memfind per piece rather than one ap_memcmp
# per byte, so what matters is the cases where a search either finds nothing,
# finds something at position zero, or finds something that runs to the very
# end -- and separators of one byte, which take a different path inside
# ap_memfind (straight to ap_memchr) from longer ones.
#
# The whitespace scan is a 256-entry table lookup rather than a six-way compare
# ladder reached through a call, so every byte the table classifies is walked
# here, in a haystack and on its own.
#
# And each piece is built without recounting its code points when the haystack
# is ASCII -- which is only sound BECAUSE it is ASCII, so the non-ASCII cases
# below are what say the general path is still taken when it must be.  A piece
# whose length is wrong shows up as a wrong len(), never as a wrong repr.

# The whitespace the byte table classifies.  \x1c-\x1f are in it because
# CPython's split() and strip() treat them as whitespace; the compare ladder
# this replaced had left them out, which was a wrong answer.
WS = ["\t", "\n", "\v", "\f", "\r", "\x1c", "\x1d", "\x1e", "\x1f", " "]
NOT_WS = ["\0", "a", "0", "_", "\x0e", "\x7f"]
# NOT tested here: U+0085, U+00A0, U+2028 and the other Unicode spaces, which
# CPython also splits on.  They are two or three bytes in UTF-8, so no byte
# table can see them and the split loops would have to decode.  Once in the old bug list.


def separators():
    hay = ["", "a", "a,b", ",a", "a,", ",", ",,", ",,,", "a,,b", "a,b,c,d",
           "abc", "aXXbXXc", "XXa", "aXX", "XX", "XXXX", "a\0b\0c", "\0",
           "abcdefghij" * 4 + "," + "z"]
    seps = [",", "XX", "\0", "abc", "a", "z", ",,", "abcdefghij"]
    for h in hay:
        for sep in seps:
            for m in (-1, 0, 1, 2, 11, 12, 13):
                print(repr(h), repr(sep), m, h.split(sep, m), h.rsplit(sep, m))


def separator_lengths():
    # A separator of every length from 1 to 12, present and absent, so both
    # the one-byte path and the multi-byte path are crossed.
    base = "abcdefghijklmnopqrstuvwxyz"
    for n in range(1, 13):
        sep = base[:n]
        h = "x" + sep + "y" + sep + "z"
        print(n, h.split(sep), h.rsplit(sep), h.split(sep, 1),
              h.rsplit(sep, 1))
        print(n, (base + "q").split(sep), base.split(base[:n] + "!"))


def whitespace_table():
    for c in WS + NOT_WS:
        s = "a" + c + "b"
        print(repr(c), s.split(), s.rsplit(), repr(s.strip()),
              repr(s.lstrip()), repr(s.rstrip()))
        t = c + c + "mid" + c + c
        print(repr(t.strip()), repr(t.lstrip()), repr(t.rstrip()),
              t.split(), t.rsplit())
    # Every whitespace byte in one string, leading, trailing and between.
    allws = "".join(WS)
    s = allws + "one" + allws + "two" + allws
    print(s.split(), s.rsplit(), repr(s.strip()))
    for m in (-1, 0, 1, 2, 3):
        print(m, s.split(None, m), s.rsplit(None, m))
    # A string that is nothing but whitespace.
    print(allws.split(), allws.rsplit(), repr(allws.strip()))


def strip_chars():
    s = "xxayybzzxx"
    for chars in ("x", "xz", "xyz", "", "abc", "\0", " ", None):
        if chars is None:
            print(repr(s.strip()), repr(s.lstrip()), repr(s.rstrip()))
        else:
            print(repr(chars), repr(s.strip(chars)), repr(s.lstrip(chars)),
                  repr(s.rstrip(chars)))
    t = "\0\0mid\0\0"
    print(repr(t.strip("\0")), repr(t.lstrip("\0")), repr(t.rstrip("\0")))
    print(repr("".strip()), repr("".strip("x")), repr(" ".strip()))


def lengths_of_pieces():
    # The whole point of skipping the code-point recount: len() must still be
    # right on every piece, for an ASCII haystack and for one that is not.
    a = ",".join("piece%d" % i for i in range(30))
    print([len(p) for p in a.split(",")][:5], len(a.split(",")))
    w = "、".join("é中\U0001f600" for _ in range(20))
    pieces = w.split("、")
    print(len(pieces), [len(p) for p in pieces][:3],
          [len(p.encode()) for p in pieces][:3])
    print(pieces[0], pieces[0] == "é中\U0001f600")
    # A separator that is itself non-ASCII, splitting an ASCII-looking string.
    m = "aXéXb"
    print(m.split("é"), [len(p) for p in m.split("é")])
    # Mixed: ASCII pieces from a non-ASCII haystack.
    n = "é,abc,def,é"
    print(n.split(","), [len(p) for p in n.split(",")],
          [len(p.encode()) for p in n.split(",")])
    # A NUL inside a piece.
    q = "a\0b,c\0d"
    print(q.split(","), [len(p) for p in q.split(",")])


def maxsplit_boundaries():
    # Either side of the twelve CPython preallocates for.
    s = ",".join(str(i) for i in range(30))
    for m in (-1, 0, 1, 10, 11, 12, 13, 29, 30, 31, 100):
        print(m, len(s.split(",", m)), s.split(",", m)[-1],
              len(s.rsplit(",", m)), s.rsplit(",", m)[0])


def no_match():
    for s in ("", "a", "abcdef", "é中", "a" * 100):
        print(repr(s.split(",")), repr(s.rsplit(",")), repr(s.split("zz")))
        print(s.split(",") == [s], s.split(",")[0] == s)


def errors_and_subclass():
    for meth in ("split", "rsplit"):
        try:
            getattr("abc", meth)("")
        except ValueError as e:
            print(meth, "ValueError", e)
        try:
            getattr("abc", meth)(1)
        except TypeError as e:
            print(meth, "TypeError")

    class S(str):
        pass

    v = S("a,b,c")
    print(v.split(","), [type(x).__name__ for x in v.split(",")])
    print(S("a b").split(), S("a,b").rsplit(","))
    print(repr(S("  x  ").strip()), type(S("  x  ").strip()).__name__)


def big():
    s = ",".join(str(i) for i in range(500))
    parts = s.split(",")
    print(len(parts), parts[0], parts[-1], sum(len(p) for p in parts))
    ws = "  ".join("word%d" % i for i in range(500))
    print(len(ws.split()), ws.split()[-1])
    r = s.rsplit(",")
    print(len(r), r[0], r[-1], r == parts)


separators()
separator_lengths()
whitespace_table()
strip_chars()
lengths_of_pieces()
maxsplit_boundaries()
no_match()
errors_and_subclass()
big()
