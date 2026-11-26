import sys
from xml.parsers import expat


def rejects(kind, fn):
    try:
        fn()
    except kind as exc:
        return str(exc)
    raise AssertionError("expected " + kind.__name__)


p = expat.ParserCreate()
assert p.buffer_text is False and p.buffer_size == 8192
p.buffer_size = 8192
assert p.buffer_text is False
p.buffer_size = 4
assert p.buffer_text is True and p.buffer_size == 4
p.buffer_size = True
assert p.buffer_size == 1
for size, kind in ((0, ValueError), (-1, ValueError), (2**31, ValueError),
                   (sys.maxsize + 1, OverflowError), (2.0, TypeError)):
    rejects(kind, lambda: setattr(p, "buffer_size", size))
    assert p.buffer_size == 1 and p.buffer_text is True
p.buffer_text = False
assert p.buffer_text is False and p.buffer_size == 1

p = expat.ParserCreate()
p.buffer_size = 4
events = []
p.CharacterDataHandler = lambda text: events.append((text, p.buffer_used))
p.CommentHandler = lambda value: events.append(("comment", value))
p.Parse("<r>é&amp;é<!-- boundary -->")
p.Parse("abcdefgh</r>", True)
assert events == [("é&", 3), ("é", 2), ("comment", " boundary "),
                  ("abcdefgh", 0)], events
assert p.buffer_used == 0


class CallbackError(Exception):
    pass


def fail(text):
    raise CallbackError(text)


for document, start_handler in ((b"<r>ab&amp;c</r>", False),
                                (b"<r>ab&amp;c<n/></r>", True)):
    p = expat.ParserCreate()
    p.buffer_text = True
    p.CharacterDataHandler = fail
    if start_handler:
        p.StartElementHandler = lambda name, attrs: None
    assert rejects(CallbackError, lambda: p.Parse(document, True)) == "ab&c"
    assert p.buffer_used == 0

print("pyexpat character-data buffering OK")
