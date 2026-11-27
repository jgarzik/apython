# Source that is not valid UTF-8 is refused, not turned into an identifier.
#
# lex_cp_at checked the SEQUENCE LENGTH and nothing else, and handed an
# unrecognised lead byte back as its own code point -- several of which
# (0xAA, 0xB5, 0xBA, 0xF8..0xFF) are XID_Start.  So `\xff = 1` compiled and
# bound a name whose one code point was U+1C0000: outside Unicode, and a str
# whose code-point count did not match its bytes.
#
# Worse in the quiet direction: a Latin-1 source compiled to a DIFFERENT
# PROGRAM.  In `x = caf\xe9\ny = 2` the 0xE9 claimed three bytes, swallowing
# the newline and the `y`, so two statements became one.
#
# CPython refuses the file as a codec error with a position of its own;
# ROADMAP.md records that wording difference.  What matters is the refusal.

bad = [
    b"x = caf\xe9\ny = 2\nprint(y)\n",       # Latin-1, no encoding declared
    b"\xff = 1\n",                            # not a lead byte at all
    b"x\xe9 = 1\n",                           # mid-identifier
    b"\xc0\x80 = 1\n",                        # overlong two-byte
    b"\xe0\x80\x80 = 1\n",                    # overlong three-byte
    b"\xf0\x80\x80\x80 = 1\n",                # overlong four-byte
    b"\xed\xa0\x80 = 1\n",                    # a surrogate
    b"\xf5\x80\x80\x80 = 1\n",                # above U+10FFFF
    b"\xc3 = 1\n",                            # truncated
    b"\xc3\x28 = 1\n",                        # a continuation slot that is not
    b"\x80 = 1\n",                            # a lone continuation byte
]
for src in bad:
    try:
        compile(src, "<t>", "exec")
        print("ACCEPTED", src)
    except SyntaxError as e:
        # The line, not the column: CPython's offset for a bad FOUR-byte
        # lead is one further along than ours, and its message is a codec
        # error of its own.  ROADMAP.md records both.
        print("reject", src, "|", e.lineno)

good = [
    b"\xc3\xa9 = 1\nprint(\xc3\xa9)\n",       # e-acute
    b"\xce\xb1 = 2\nprint(\xce\xb1)\n",       # alpha
    b"\xe5\x8f\x98 = 3\nprint(\xe5\x8f\x98)\n",   # CJK
    b"# a comment with \xe9 in it\nx = 5\nprint(x)\n",   # comments pass
    b"x = 6 # trailing \xc3\nprint(x)\n",
]
for src in good:
    exec(compile(src, "<t>", "exec"))

# And the code points really are what they should be.  A name PEP 3131's NFKC
# normalisation would rewrite is left out: that step is absent here, and
# the old bug list recorded it -- CPython turns U+1D498 into plain 'U'.
code = compile(b"\xce\xb1\xce\xb2 = 1\n", "<t>", "exec")
name = code.co_names[0]
print([ord(c) for c in name], len(name))
