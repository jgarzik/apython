# A possessive repeat (Python 3.11's ?+ *+ ++ {m,n}+) whose body fails part
# way through must undo the groups it captured on the way, as a greedy one
# does.  It did not: `(?:(\d+)!)?+(\d+)` on "1" captured "1" into group 1,
# failed at the "!", and left the capture behind -- so group 2 was None.
# packaging's VERSION_PATTERN is written exactly that way, so every
# Version("1.10") was InvalidVersion, and pip is built on packaging.
import re

cases = [
    (r"(?:(\d+)!)?+(\d+)", "1"),
    (r"(?:(\d+)!)*+(\d+)", "12"),
    (r"(?:(\d+)!)++(\d+)", "1!2"),
    (r"(?:(\d+)!){0,2}+(\d+)", "7"),
    (r"(?:(a)(b)c)?+(ab)", "ab"),
    (r"(?:(a)|(b)x)?+(b)", "b"),
    (r"(?:(\d+)!)?+(\d+)", "3!4"),
    (r"(?>(\d+)!)?(\d+)", "1"),
    (r"(?:(\w)+;)?+(\w+)", "abc"),
]
for pat, s in cases:
    m = re.match(pat, s)
    print(pat, s, m and m.groups(), m and m.span())

VERSION = r"""
    v?+
    (?:
        (?:(?P<epoch>[0-9]+)!)?+
        (?P<release>[0-9]+(?:\.[0-9]+)*+)
    )
"""
r = re.compile(VERSION, re.VERBOSE)
for v in ("1.10", "2!1.0", "v3"):
    print(v, r.match(v).groupdict())
