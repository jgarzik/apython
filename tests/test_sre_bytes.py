# A bytes pattern matches bytes and answers bytes.
#
# SRE_State had an is_bytes field that nothing ever set or read: every
# pattern was a str pattern, every subject had to be a str, and
# `re.compile(rb'...')` was impossible.  CPython's own tokenize.detect_encoding
# uses one, which is what kept hashlib, random and uu out.
#
# The engine itself is unchanged: bytes are byte-indexed, which is the ASCII
# path it already had.  What is new is that the pattern records which kind it
# is, that the subject must match, and that every result -- groups, splits,
# substitutions, templates -- is built as that kind.
#
# This test has no CPython oracle, for the reason tests/test_sre.py gives:
# it feeds hand-written SRE bytecode to _sre.compile, which does not validate
# it, and CPython segfaults on some of it.  Every step asserts.
import _sre

# MARK 0, LITERAL h e l l o, MARK 1, SUCCESS
HELLO = [17, 0, 16, 104, 16, 101, 16, 108, 16, 108, 16, 111, 17, 1, 1]
# MARK 0, LITERAL ' ', MARK 1, SUCCESS
SPACE = [17, 0, 16, 32, 17, 1, 1]
# MARK 0, MARK 2, LITERAL a b c, MARK 3, MARK 1, SUCCESS
GROUP = [17, 0, 17, 2, 16, 97, 16, 98, 16, 99, 17, 3, 17, 1, 1]

bp = _sre.compile(b"hello", 0, HELLO, 0, {}, ())
sp = _sre.compile("hello", 0, HELLO, 0, {}, ())

# --- the pattern remembers which kind it is
assert bp.pattern == b"hello", bp.pattern
assert sp.pattern == "hello"
print("pattern kinds OK")

# --- matching
m = bp.match(b"hello world")
assert m is not None
assert m.group() == b"hello", m.group()
assert isinstance(m.group(), bytes)
assert m.start() == 0 and m.end() == 5
assert m.string == b"hello world"
print("match OK")

assert bp.match(b"goodbye") is None
assert bp.fullmatch(b"hello") is not None
assert bp.fullmatch(b"hello world") is None
print("fullmatch OK")

m2 = bp.search(b"say hello world")
assert m2 is not None and m2.group() == b"hello" and m2.start() == 4
print("search OK")

# --- a bytearray is a bytes-like subject
m3 = bp.match(bytearray(b"hello there"))
assert m3 is not None and m3.group() == b"hello", m3.group()
print("bytearray subject OK")

# --- the kinds must agree
for bad in ("hello", "hello world"):
    try:
        bp.match(bad)
    except TypeError as e:
        assert "bytes pattern" in str(e), e
    else:
        raise AssertionError("a str subject was accepted by a bytes pattern")
for bad in (b"hello", bytearray(b"hello")):
    try:
        sp.match(bad)
    except TypeError as e:
        assert "string pattern" in str(e), e
    else:
        raise AssertionError("a bytes subject was accepted by a str pattern")
for bad in (5, None, [1], 1.5, {}, ()):
    for pat in (bp, sp):
        try:
            pat.match(bad)
        except TypeError as e:
            assert "expected string or bytes-like object" in str(e), e
        else:
            raise AssertionError("%r was accepted" % (bad,))
print("kind checking OK")

# --- everything that builds a result builds bytes
assert bp.findall(b"hello world hello") == [b"hello", b"hello"]
assert sp.findall("hello hello") == ["hello", "hello"]
print("findall OK")

bsp = _sre.compile(b" ", 0, SPACE, 0, {}, ())
assert bsp.split(b"a b c") == [b"a", b"b", b"c"]
print("split OK")

assert bp.sub(b"HI", b"hello world hello") == b"HI world HI"
assert bp.subn(b"HI", b"hello world hello") == (b"HI world HI", 2)
assert bp.subn(b"HI", b"hello world hello", 1) == (b"HI world hello", 1)
print("sub OK")

assert [m.group() for m in bp.finditer(b"hello hello")] == [b"hello", b"hello"]
assert list(bp.finditer(b"goodbye")) == []
print("finditer OK")


def upper(m):
    return m.group(0).upper()


assert bp.sub(upper, b"hello world hello") == b"HELLO world HELLO"
print("callable sub OK")

# --- a replacement of the wrong kind is refused -- by the join that
# assembles the result, so only once a match is substituted
try:
    bp.sub("HI", b"hello")
except TypeError as e:
    assert "expected a bytes-like object, str found" in str(e), e
else:
    raise AssertionError("a str replacement was accepted for a bytes pattern")
try:
    sp.sub(b"HI", "hello")
except TypeError as e:
    pass
else:
    raise AssertionError("a bytes replacement was accepted for a str pattern")
print("replacement kinds OK")

# --- groups, and the template language
bg = _sre.compile(b"(abc)", 0, GROUP, 1, {}, ())
gm = bg.match(b"abcdef")
assert gm is not None
assert gm.group(0) == b"abc" and gm.group(1) == b"abc"
assert gm.groups() == (b"abc",)
assert gm[0] == b"abc" and gm[1] == b"abc"
assert gm.expand(rb"[\1]") == b"[abc]", gm.expand(rb"[\1]")
assert gm.expand(rb"\g<0>") == b"abc"
assert bg.sub(rb"<\1>", b"abcabc") == b"<abc><abc>"
print("groups and templates OK")

# --- the scanner
sc = bp.scanner(b"hello world hello")
assert sc.search().group() == b"hello"
assert sc.search().group() == b"hello"
assert sc.search() is None
print("scanner OK")

# --- str patterns are untouched
sm = sp.match("hello world")
assert sm.group() == "hello" and isinstance(sm.group(), str)
assert sp.sub("HI", "hello world hello") == "HI world HI"
assert sp.split("hello") == ["", ""]
print("str patterns unchanged OK")

# --- a byte above 127 is one element, not the start of a sequence
HIGH = [17, 0, 16, 255, 17, 1, 1]
hp = _sre.compile(b"\xff", 0, HIGH, 0, {}, ())
hm = hp.match(b"\xff\xfe")
assert hm is not None and hm.group() == b"\xff", hm.group()
assert hm.end() == 1, hm.end()
assert hp.findall(b"\xff\x00\xff") == [b"\xff", b"\xff"]
print("high bytes OK")

print("All bytes-pattern tests passed!")
