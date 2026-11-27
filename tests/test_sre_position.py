"""Matching at a position, and the ASCII/non-ASCII split behind it.

`sre_state_init` used to decide whether a subject was ASCII by scanning every
one of its bytes, and `sre_match_get_group_str` ran the identical loop again on
every `m.group(n)`.  Both answers are already on the str object -- ob_size is
the byte length and ob_length the code-point length, and they are equal iff the
string is pure ASCII -- so an incremental parser was paying O(len(subject))
twice per token where CPython pays nothing.  json.loads went quadratic on it.

The functional risk in replacing a scan with that comparison is that some way
of *building* a string leaves ob_length disagreeing with reality, so most of
this file is the same match driven over strings made many different ways.  The
last section is the complexity guard: cost per match must not grow with the
part of the subject the match never looks at.
"""

import re
import time

# --- matching at a position, ASCII and not -----------------------------------

pat = re.compile(r"[0-9]+")

for filler, label in (("x", "ascii"), ("é", "latin1"),
                      ("中", "cjk"), ("\U0001f600", "astral")):
    for n in (0, 1, 5, 64):
        s = filler * n + "12345tail"
        m = pat.match(s, n)
        print(label, n, m.span(), repr(m.group()), m.pos, m.endpos)

# search, fullmatch and the anchors, which read length independently
def span_of(m):
    return m.span() if m else None

for filler in ("x", "é", "\U0001f600", " ", "-"):
    s = filler * 3 + "42"
    print(repr(filler),
          span_of(re.search(r"\d+", s)),
          span_of(re.fullmatch(r".*", s)),
          span_of(re.search(r"\d+$", s)),
          span_of(re.search(r"^\w", s)),
          span_of(re.search(r"\w+$", s)))
    # \b and \B are deliberately not probed with a non-ASCII filler: this
    # tree's word-boundary test is ASCII-only, so "\b\d+\b" matches inside
    # "eee42" where CPython sees no boundary.  The old bug list carried it; it is not
    # what this file is about.
    if filler.isascii():
        print("  b", span_of(re.search(r"\b\d+\b", s)),
              span_of(re.search(r"\B\d", s)))

# --- endpos clamping, on both paths ------------------------------------------

for filler in ("a", "é"):
    s = filler * 4 + "999"
    for endpos in (0, 3, 5, 6, 7, 100):
        m = pat.search(s, 0, endpos)
        print(repr(filler), endpos, m.span() if m else None,
              m.endpos if m else None)

# --- ob_length must agree with reality however the string was built ----------

base = "é中\U0001f600ab"
built = [
    ("literal", base),
    ("concat", "é" + "中" + "\U0001f600" + "ab"),
    ("slice", ("ZZ" + base + "ZZ")[2:-2]),
    ("join", "".join(["é", "中", "\U0001f600", "a", "b"])),
    ("mul", ("é中\U0001f600ab" * 3)[:5]),
    ("decode", base.encode("utf-8").decode("utf-8")),
    ("fstring", f"{base}"),
    ("percent", "%s" % base),
    ("format", "{}".format(base)),
    ("upper", base.upper().lower()),
    ("replace", ("Q" + base).replace("Q", "")),
    ("strip", ("  " + base + "  ").strip()),
    ("ascii-only", "plain ascii"),
    ("empty", ""),
]
for label, s in built:
    subject = s + "77"
    m = pat.search(subject)
    print(label, len(subject), m.span() if m else None,
          repr(m.group()) if m else None)

# --- group extraction on a non-ASCII subject ---------------------------------

m = re.search(r"(\w)(\d+)", "é中\U0001f600z123end")
print(m.span(), m.span(1), m.span(2), repr(m.group(0)), repr(m.group(1)),
      repr(m.group(2)), repr(m.groups()))

# --- finditer / scanner over a mixed string ----------------------------------

mixed = "".join("%s%d," % (c, i) for i, c in enumerate("aéb中c\U0001f600"))
print(repr(mixed))
print([(mo.span(), mo.group()) for mo in re.finditer(r"\d+", mixed)])

# a scanner abandoned part-way, then a fresh one over the same string
it = re.finditer(r"\d+", mixed)
print(next(it).group(), next(it).group())
del it
print([mo.group() for mo in re.finditer(r"\d+", mixed)])

# a scanner reused after exhaustion
it = re.finditer(r"\d+", mixed)
print(len(list(it)), list(it))

# --- the scanner's decode cache ----------------------------------------------
#
# A scanner holds its subject's u32 decode across iterations instead of
# rebuilding it per step.  The cache stores the UNCLAMPED length, so anything
# that narrows a single match must still measure against the whole string.

uni = "".join("é%d中" % (i % 10) for i in range(12))
print(len(uni), repr(uni[:9]))

# pattern.finditer with explicit pos/endpos, which the cached length must not
# override in either direction
up = re.compile(r"\d")
for pos, endpos in ((0, len(uni)), (3, 9), (0, 0), (5, 5), (9, 3), (0, 10**6)):
    print(pos, endpos, [(m.span(), m.group()) for m in up.finditer(uni, pos, endpos)])

# two scanners over the same string, interleaved: each owns its own cache
a = up.finditer(uni)
b = up.finditer(uni)
print([(next(a).span(), next(b).span()) for _ in range(3)])
print(next(a).span(), sum(1 for _ in b))

# the scanner's own search() method, which builds a state the same way
# finditer does and shares the same cache.  match() is not probed here: a
# failing scanner.match() ends the scan in CPython and does not in this tree,
# which the old bug list carried and which has nothing to do with the cache -- it
# reproduces identically on an ASCII subject, where no cache is built at all.
sc = up.scanner(uni)
print(span_of(sc.search()), span_of(sc.search()), span_of(sc.search()))

# a cached scanner interleaved with plain matches on the same string, which
# take the uncached path
it2 = up.finditer(uni)
print(next(it2).span(), up.search(uni, 5).span(), next(it2).span(),
      up.match(uni, 1).span() if up.match(uni, 1) else None)

# the same subject scanned after the first scanner is gone
del a, b, it2
print([m.span() for m in up.finditer(uni)][:4])

# an ASCII scanner never fills the cache at all
print([m.span() for m in up.finditer("a1b2c3")])

# findall / sub / split, which init once and reset per iteration
print(re.findall(r"\d+", mixed))
print(re.sub(r"\d+", "#", mixed))
print(re.split(r"\d+", mixed))

# bytes subjects keep the byte-indexed path, high bytes and all
b = b"\xff\xfe12\xff34"
print(re.findall(rb"\d+", b), re.search(rb"\d+", b).span())

# --- the complexity guard ----------------------------------------------------
#
# A match anchored at `pos` never inspects the prefix, so its cost must not
# grow with the prefix's length.  The old full-subject rescan made it linear.
# Timed as a best-of-3 minimum and compared against a deliberately loose
# threshold, so ordinary machine noise cannot fail it.

def per_call_us(subject_len, reps=200):
    s = "x" * subject_len + "12345"
    best = None
    for _ in range(3):
        t0 = time.perf_counter()
        for _ in range(reps):
            pat.match(s, subject_len)
        dt = time.perf_counter() - t0
        if best is None or dt < best:
            best = dt
    return best / reps * 1e6

small = per_call_us(5000)
large = per_call_us(40000)
# 8x the subject.  Linear behaviour lands near 8.0; O(1) lands near 1.0.
print("match-at-pos scales:", large < small * 4.0 or (small, large))

def group_us(subject_len, reps=200):
    s = "x" * subject_len + "12345"
    m = pat.search(s)
    best = None
    for _ in range(3):
        t0 = time.perf_counter()
        for _ in range(reps):
            m.group(0)
        dt = time.perf_counter() - t0
        if best is None or dt < best:
            best = dt
    return best / reps * 1e6

gsmall = group_us(5000)
glarge = group_us(40000)
print("group() scales:", glarge < gsmall * 4.0 or (gsmall, glarge))

print("OK")
