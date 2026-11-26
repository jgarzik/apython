import gc
import sys
import weakref
from xml.parsers import expat


def rejects(kind, fn):
    try:
        fn()
    except kind as exc:
        return str(exc)
    raise AssertionError("expected " + kind.__name__)


class Reader:
    def __init__(self, chunks, before=None):
        self.chunks = iter(chunks)
        self.before = before
        self.index = 0

    def read(self, size):
        assert size == 2048
        if self.before is not None:
            self.before(self.index)
        self.index += 1
        return next(self.chunks)


p = expat.ParserCreate()
p.buffer_text = True
events = []
p.CharacterDataHandler = events.append
assert p.ParseFile(Reader([b"<r>a", bytearray(b"&amp;"), b"b</r>", b""])) == 1
assert events == ["a&b"], events

p = expat.ParserCreate()
p.buffer_text = True
events = []
p.CharacterDataHandler = lambda data: events.append(("old", data, p.buffer_used))


def change_handler(index):
    if index == 1:
        assert p.buffer_used == 1 and events == []
        p.CharacterDataHandler = lambda data: events.append(("new", data, p.buffer_used))
    if index == 2:
        assert events == [("old", "a", 1)]


assert p.ParseFile(Reader([b"<r>a", b"b</r>", b""], change_handler)) == 1
assert events == [("old", "a", 1), ("new", "b", 1)]
assert p.buffer_used == 0

p = expat.ParserCreate()
p.buffer_text = True
events = []
p.CharacterDataHandler = events.append


def resize_and_disable(index):
    if index == 1:
        p.buffer_size = 128
    if index == 2:
        p.buffer_text = False


assert p.ParseFile(Reader([b"<r>a", b"b", b"c</r>", b""], resize_and_disable)) == 1
assert events == ["a", "b", "c"]
assert p.buffer_size == 128 and p.buffer_text is False

assert rejects(TypeError, lambda: expat.ParserCreate().ParseFile(object())) == (
    "argument must have 'read' attribute")
assert rejects(ValueError, lambda: expat.ParserCreate().ParseFile(Reader([b"a" * 2049]))) == (
    "read() returned too much data: 2048 bytes requested, 2049 returned")


class CallbackError(Exception):
    pass


def fail(text):
    raise CallbackError(text)


p = expat.ParserCreate()
p.buffer_text = True
p.CharacterDataHandler = fail
replacement = lambda text: None
assert rejects(CallbackError, lambda: p.ParseFile(Reader(
    [b"<r>a", b"b</r>", b""],
    lambda index: setattr(p, "CharacterDataHandler", replacement) if index == 1 else None
))) == "a"
assert p.CharacterDataHandler is not replacement and p.buffer_used == 0

for attribute, value in (("buffer_size", 64), ("buffer_text", False)):
    p = expat.ParserCreate()
    p.buffer_text = True
    p.CharacterDataHandler = fail
    assert rejects(CallbackError, lambda: p.ParseFile(Reader(
        [b"<r>a", b"b</r>", b""],
        lambda index: setattr(p, attribute, value) if index == 1 else None
    ))) == "a"
    assert p.buffer_size == 8192 and p.buffer_text is True and p.buffer_used == 0

# Changing the settings from inside a dispatch must deliver the block once.
if sys.implementation.name == "apython":
    p = expat.ParserCreate()
    p.buffer_text = True
    events = []

    def during_delivery(text):
        events.append((text, p.buffer_used))
        p.CharacterDataHandler = None
        p.buffer_size = 64
        p.buffer_text = False
        assert rejects(RuntimeError, lambda: p.Parse(b"<nested/>", True)) == (
            "cannot parse the same parser from a callback")

    p.CharacterDataHandler = during_delivery
    assert p.Parse(b"<r>a&amp;b</r>", True) == 1
    assert events == [("a&b", 3)]
    assert p.buffer_used == 0 and p.buffer_size == 64 and p.buffer_text is False


class Receiver:
    def __init__(self):
        self.parser = expat.ParserCreate()
        self.parser.buffer_text = True
        self.parser.CharacterDataHandler = self.text

    def text(self, value):
        pass


owner = Receiver()
ref = weakref.ref(owner)
owner.parser.Parse(b"<r>a&amp;b</r>", True)
del owner
gc.collect()
assert ref() is None

print("pyexpat file buffering and cleanup OK")
