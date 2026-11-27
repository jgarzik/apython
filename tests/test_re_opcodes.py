# The opcodes the engine used to get wrong, driven through _sre directly.
#
# This is the one that runs in the default `make check`.  tests/re_probe.sh
# is the real differential test, but it needs CPython's Lib/re on the path
# and so cannot be part of the ordinary gate -- and the two tests that were
# here before, test_sre.py and test_sre2.py, feed HAND-WRITTEN integer arrays
# that between them contain no REPEAT, REPEAT_ONE, IN or ASSERT.  Those are
# exactly the opcodes that were broken, which is why nothing caught:
#
#   .*x   matched "abc"          -- MAXREPEAT is 0xFFFFFFFF, which as an
#   .*    matched nothing           int32 is -1, and the greedy loop's
#   .*x\Z segfaulted                comparison was signed
#   (ab)+ matched zero times     -- the repeat context started its count at
#   (?=a)a failed                   0 instead of -1, and ASSERT was decoded
#                                   with three operand words where CPython
#                                   emits two
#
# The arrays below are CPython 3.12's own output, generated with
# re._compiler._code(re._parser.parse(p), 0) -- not written by hand, so they
# cannot drift from what the real compiler emits.

import _sre

CASES = [
    ('.*a', 'abc', [14, 4, 0, 1, 4294967295, 24, 5, 0, 4294967295, 2, 1, 16, 97, 1], 0, {}, (None,)),
    ('.*', 'abc', [14, 4, 0, 0, 4294967295, 24, 5, 0, 4294967295, 2, 1, 1], 0, {}, (None,)),
    ('a*', 'aaa', [14, 4, 0, 0, 4294967295, 24, 6, 0, 4294967295, 16, 97, 1, 1], 0, {}, (None,)),
    ('a+', 'aaa', [14, 4, 0, 1, 4294967295, 24, 6, 1, 4294967295, 16, 97, 1, 1], 0, {}, (None,)),
    ('a{2,3}', 'aaaa', [14, 4, 0, 2, 3, 24, 6, 2, 3, 16, 97, 1, 1], 0, {}, (None,)),
    ('[abc]+', 'abc', [14, 4, 0, 1, 4294967295, 24, 10, 1, 4294967295, 13, 5, 22, 97, 99, 0, 1, 1], 0, {}, (None,)),
    ('a*?b', 'aab', [14, 4, 0, 1, 4294967295, 26, 6, 0, 4294967295, 16, 97, 1, 16, 98, 1], 0, {}, (None,)),
    ('(ab)+', 'abab', [14, 4, 0, 2, 4294967295, 23, 11, 1, 4294967295, 17, 0, 16, 97, 16, 98, 17, 1, 18, 1], 1, {}, (None, None)),
    ('(a|b)*c', 'abc', [14, 4, 0, 1, 4294967295, 23, 13, 0, 4294967295, 17, 0, 13, 5, 22, 97, 98, 0, 17, 1, 18, 16, 99, 1], 1, {}, (None, None)),
    ('x(?:yz)?', 'xyz', [14, 8, 1, 1, 3, 1, 1, 120, 0, 16, 120, 23, 7, 0, 1, 16, 121, 16, 122, 18, 1], 0, {}, (None,)),
    ('(?=abc)a', 'abc', [14, 4, 0, 1, 1, 4, 9, 0, 16, 97, 16, 98, 16, 99, 1, 16, 97, 1], 0, {}, (None,)),
    ('(?!b)a', 'abc', [14, 4, 0, 1, 1, 5, 5, 0, 16, 98, 1, 16, 97, 1], 0, {}, (None,)),
    ('(?<=a)b', 'ab', [14, 4, 0, 1, 1, 4, 5, 1, 16, 97, 1, 16, 98, 1], 0, {}, (None,)),
    ('(?<!a)b', 'xb', [14, 4, 0, 1, 1, 5, 5, 1, 16, 97, 1, 16, 98, 1], 0, {}, (None,)),
    ('\\d+', '123', [14, 4, 0, 1, 4294967295, 24, 9, 1, 4294967295, 13, 4, 8, 10, 0, 1, 1], 0, {}, (None,)),
    ('(?>a*)b', 'aab', [14, 4, 0, 1, 4294967295, 27, 9, 24, 6, 0, 4294967295, 16, 97, 1, 1, 16, 98, 1], 0, {}, (None,)),
    ('a*+b', 'aab', [14, 4, 0, 1, 4294967295, 29, 6, 0, 4294967295, 16, 97, 1, 16, 98, 1], 0, {}, (None,)),
    ('.*x', 'abc', [14, 4, 0, 1, 4294967295, 24, 5, 0, 4294967295, 2, 1, 16, 120, 1], 0, {}, (None,)),
    ('a??b', 'ab', [14, 4, 0, 1, 2, 26, 6, 0, 1, 16, 97, 1, 16, 98, 1], 0, {}, (None,)),
    ('[^a]+', 'bcd', [14, 4, 0, 1, 4294967295, 24, 6, 1, 4294967295, 20, 97, 1, 1], 0, {}, (None,)),

    # Bounded repeats.  The general REPEAT counter starts at -1, as
    # sre_lib.h has it, and the two UNTIL handlers compare against max
    # STRICTLY because of that.  Nothing here exercised a bound before, so an
    # off-by-one that made every {m,n} match n+1 times passed the whole suite.
    ('(ab){2}', 'ababab', [14, 4, 0, 4, 4, 23, 11, 2, 2, 17, 0, 16, 97, 16, 98, 17, 1, 18, 1], 1, {}, (None, None)),
    ('(ab){2}', 'abab', [14, 4, 0, 4, 4, 23, 11, 2, 2, 17, 0, 16, 97, 16, 98, 17, 1, 18, 1], 1, {}, (None, None)),
    ('(ab){1,2}', 'ababab', [14, 4, 0, 2, 4, 23, 11, 1, 2, 17, 0, 16, 97, 16, 98, 17, 1, 18, 1], 1, {}, (None, None)),
    ('(ab){2,3}', 'ababababab', [14, 4, 0, 4, 6, 23, 11, 2, 3, 17, 0, 16, 97, 16, 98, 17, 1, 18, 1], 1, {}, (None, None)),
    ('(ab){0,1}', 'abab', [14, 4, 0, 0, 2, 23, 11, 0, 1, 17, 0, 16, 97, 16, 98, 17, 1, 18, 1], 1, {}, (None, None)),
    ('(a)?', 'aa', [14, 4, 0, 0, 1, 23, 9, 0, 1, 17, 0, 16, 97, 17, 1, 18, 1], 1, {}, (None, None)),
    ('(a|b){2}', 'abab', [14, 4, 0, 2, 2, 23, 13, 2, 2, 17, 0, 13, 5, 22, 97, 98, 0, 17, 1, 18, 1], 1, {}, (None, None)),
    ('(?:ab){2,}', 'ababab', [14, 4, 0, 4, 4294967295, 23, 7, 2, 4294967295, 16, 97, 16, 98, 18, 1], 0, {}, (None,)),
    ('(ab)+?', 'ababab', [14, 4, 0, 2, 4294967295, 23, 11, 1, 4294967295, 17, 0, 16, 97, 16, 98, 17, 1, 19, 1], 1, {}, (None, None)),
    ('(ab){2,3}?', 'ababababab', [14, 4, 0, 4, 6, 23, 11, 2, 3, 17, 0, 16, 97, 16, 98, 17, 1, 19, 1], 1, {}, (None, None)),
    ('(a){3}', 'aaaa', [14, 4, 0, 3, 3, 23, 9, 3, 3, 17, 0, 16, 97, 17, 1, 18, 1], 1, {}, (None, None)),
    ('(a)*', 'aaa', [14, 4, 0, 0, 4294967295, 23, 9, 0, 4294967295, 17, 0, 16, 97, 17, 1, 18, 1], 1, {}, (None, None)),
]

print("--- match ---")
for pattern, subject, code, groups, groupindex, indexgroup in CASES:
    rx = _sre.compile(pattern, 0, code, groups, groupindex, indexgroup)
    m = rx.match(subject)
    print("%-10s %-6s %s" % (pattern, subject, m.span() if m else None))

print()
print("--- search, which drives the same opcodes from every start ---")
for pattern, subject, code, groups, groupindex, indexgroup in CASES:
    rx = _sre.compile(pattern, 0, code, groups, groupindex, indexgroup)
    m = rx.search(subject)
    print("%-10s %-6s %s" % (pattern, subject, m.span() if m else None))

print()
print("--- the groups the repeats capture ---")
for pattern, subject, code, groups, groupindex, indexgroup in CASES:
    if not groups:
        continue
    rx = _sre.compile(pattern, 0, code, groups, groupindex, indexgroup)
    m = rx.match(subject)
    print("%-10s %-6s %r" % (pattern, subject, m.groups() if m else None))

print()
print("--- a greedy repeat backing off one position at a time ---")
# .* over a long subject with a tail that only matches near the front: the
# back-off loop runs the whole length, which is where the position used to
# walk off the front of the string and segfault.
long_code = [24, 5, 0, 4294967295, 2, 1, 16, 97, 1]   # REPEAT_ONE ANY, then 'a'
rx = _sre.compile(".*a", 0, long_code, 0, {}, (None,))
for n in (0, 1, 2, 10, 100, 1000):
    subject = "a" + "b" * n
    m = rx.match(subject)
    print("len %-5d %s" % (len(subject), m.span() if m else None))
for n in (1, 10, 100):
    subject = "b" * n
    m = rx.match(subject)
    print("no 'a', len %-4d %s" % (n, m.span() if m else None))


print()
print("--- BIGCHARSET, whose operand is a map and then the bitmaps ---")
# [a-z] under IGNORECASE folds in the Kelvin sign and the long s, so the set
# reaches past U+00FF and the compiler emits BIGCHARSET rather than a plain
# 256-bit CHARSET.  Its operand is <count> <256-byte map> <count * 32-byte
# bitmaps>, and the map comes FIRST -- the engine had the two the other way
# round, so it indexed a bitmap with the code point's high byte and then bit-
# tested a slice of the map.  The map is almost all 2s, so the "bitmap" was
# 0x02020202 and exactly the code points congruent to 1 mod 8 matched: a, i,
# q and y, and no other letter.  Nothing in this file reached BIGCHARSET, and
# nothing else could: only a charset wider than a byte compiles to one.
BIGCHARSET_CODE = [14, 4, 0, 1, 4294967295, 24, 97, 1, 4294967295, 39, 92, 10, 3, 33685760, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 0, 0, 0, 134217726, 0, 0, 0, 0, 0, 131072, 0, 2147483648, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1]
BIGCHARSET_ONE = [14, 4, 0, 1, 1, 39, 92, 10, 3, 33685760, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 33686018, 0, 0, 0, 134217726, 0, 0, 0, 0, 0, 131072, 0, 2147483648, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]

# 2 is re.IGNORECASE; this file drives _sre directly and never imports re.
rx = _sre.compile("[a-z]", 2, BIGCHARSET_ONE, 0, {}, (None,))
missed = [c for c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
          if rx.match(c) is None]
print("single, letters that do not match:", repr("".join(missed)))
extra = [c for c in "0123456789 _-@[]{}" if rx.match(c) is not None]
print("single, non-letters that do match:", repr("".join(extra)))

rxp = _sre.compile("[a-z]+", 2, BIGCHARSET_CODE, 0, {}, (None,))
for s in ("abc", "ABC", "AbC", "xyz", "a", "abc123", "1abc", ""):
    m = rxp.match(s)
    print("[a-z]+ %-8r %s" % (s, m.span() if m else None))

print()
print("--- the replacement template mini-language ---")
# Match.expand() used to hand the template straight back and Pattern.sub()
# concatenated the replacement verbatim, so every escape and every group
# reference came out as its own source text: sub(r'(a)(b)', r'\2\1', 'abab')
# answered '\2\1\2\1'.  The syntax is _parser.parse_template's, which is not
# the pattern syntax -- \b is a backspace here, and three octal digits after
# the backslash beat a two-digit group number.
TWO_GROUPS = ([14, 10, 1, 2, 2, 2, 0, 97, 98, 0, 0, 17, 0, 16, 97, 17, 1, 17, 2,
               16, 98, 17, 3, 1], 2, {}, (None, None, None))
NAMED = ([14, 4, 0, 2, 4294967295, 17, 0, 24, 6, 1, 4294967295, 16, 97, 1, 17, 1,
          17, 2, 24, 6, 0, 4294967295, 16, 98, 1, 17, 3, 17, 4, 16, 99, 17, 5, 1],
         3, {'first': 1, 'last': 3}, (None, 'first', None, 'last'))
OPT = ([14, 4, 0, 1, 2, 23, 9, 0, 1, 17, 0, 16, 97, 17, 1, 18, 16, 98, 1],
       1, {}, (None, None))

rx2 = _sre.compile("(a)(b)", 0, *TWO_GROUPS)
rxn = _sre.compile("(?P<first>a+)(b*)(?P<last>c)", 0, *NAMED)
rxo = _sre.compile("(a)?b", 0, *OPT)

m = rxn.match("aabbc")
for t in (r"\1-\2-\3", r"\g<first>|\g<last>", r"\g<1>\g<2>", "plain",
          r"a\nb", r"a\tb", r"a\rb", r"a\vb", r"a\fb", r"a\ab", r"a\bb",
          r"\\", r"\.", r"\-", r"x\0y", r"\101", r"\0101", r"[\g<0>]",
          r"\g<3>\g<2>\g<1>", ""):
    print("expand %-22r %r" % (t, m.expand(t)))

print("unmatched group ->", repr(rxo.match("b").expand(r"[\1]")))

for t in (r"\2\1", r"[\1|\2]", "Z", "", r"\g<0>"):
    print("sub  %-10r %r %r" % (t, rx2.sub(t, "abab"), rx2.subn(t, "abab")))
print("sub count ->", repr(rx2.sub(r"\2\1", "abab", 1)))
print("sub callable ->", repr(rx2.sub(lambda mm: mm.group(2) + mm.group(1), "abab")))

# A malformed template has to be refused; the class is deliberately not
# pinned here.  CPython raises re.error, which is defined in Python and so
# cannot be constructed from the engine without importing re -- these raise
# IndexError for a group problem and ValueError for a bad escape.  The old bug list
# carried it.
for bad in (r"\9", r"\g<nope>", r"\g<", r"\g", r"\q", "\\"):
    try:
        print("bad %-10r ->" % bad, repr(m.expand(bad)))
    except Exception:
        print("bad %-10r -> raised" % bad)
