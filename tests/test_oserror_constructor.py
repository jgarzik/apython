import copy
import errno
import pickle


class CustomInit(OSError):
    def __init__(self, reason, *, path):
        assert self.args == ()
        assert self.errno is None
        super().__init__(errno.ENOENT, reason, path)


class SkipsInit(OSError):
    def __init__(self, *args, **kwargs):
        pass


class BaseInit(OSError):
    __init__ = BaseException.__init__


class CustomNew(OSError):
    def __new__(cls, *, path):
        return super().__new__(cls, errno.ENOENT, "missing", path)

    def __init__(self, *, path):
        super().__init__(errno.EINVAL, "ignored", "other")


class BlockingSubclass(BlockingIOError):
    def native_values(self):
        return super().filename, super().characters_written


class WithFallback(BlockingIOError):
    def __getattr__(self, name):
        return name


class Index:
    def __index__(self):
        return 42


class TooWide:
    def __index__(self):
        return 2**85


class IndexErrorFromUser:
    def __index__(self):
        raise OverflowError("from index")


class NumericWithoutIndex:
    def __int__(self):
        return 42


class BadIndex:
    def __index__(self):
        return "forty-two"


def raises(kind, call, text=None):
    try:
        call()
    except kind as e:
        if text is not None:
            assert str(e) == text, str(e)
    else:
        raise AssertionError("expected " + kind.__name__)


e = CustomInit("missing", path="node")
assert type(e) is CustomInit
assert (e.args, e.errno, e.filename) == ((errno.ENOENT, "missing"), errno.ENOENT, "node")
e = SkipsInit(errno.ENOENT, "missing", "node", extra=True)
assert e.args == () and e.errno is None and e.filename is None
e = BaseInit(errno.ENOENT, "missing", "node")
assert e.args == (errno.ENOENT, "missing", "node") and e.errno is None
raises(TypeError, lambda: BaseInit(extra=True), "BaseInit() takes no keyword arguments")
e = OSError.__new__(SkipsInit, errno.ENOENT, "missing", "node", extra=True)
assert e.args == () and e.errno is None
OSError.__init__(e, errno.ENOENT, "missing", "node")
assert e.args == (errno.ENOENT, "missing") and e.filename == "node"
OSError.__init__(e, "one")
assert e.args == ("one",) and e.errno is None and e.filename == "node"
raises(TypeError, lambda: OSError.__init__(e, extra=True))
e = CustomNew(path="here")
assert e.args == (errno.ENOENT, "missing") and e.filename == "here"
assert type(OSError.__new__(OSError, errno.ENOENT, "x")) is FileNotFoundError
raises(TypeError, lambda: OSError.__new__(ValueError))
raises(TypeError, lambda: BaseException.__new__(BlockingIOError))
raises(TypeError, lambda: OSError(extra=True))

e = OSError(errno.EAGAIN, "wait", Index(), None, "ignored")
assert type(e) is BlockingIOError
assert type(e.args[2]) is Index and len(e.args) == 5
assert e.filename is None and e.filename2 is None and e.characters_written == 42
assert str(e) == "[Errno %s] wait" % errno.EAGAIN
e = BlockingSubclass(errno.EAGAIN, "wait", 42)
assert e.filename == 42 and not hasattr(e, "characters_written")
e.characters_written = 7
assert e.native_values() == (42, 7)
e = BlockingIOError(errno.EAGAIN, "wait", -2)
assert e.characters_written == -2
e = BlockingIOError(errno.EAGAIN, "wait", -1)
assert not hasattr(e, "characters_written")
raises(TypeError, lambda: BlockingIOError(errno.EAGAIN, "wait", 1.5))
raises(TypeError, lambda: BlockingIOError(errno.EAGAIN, "wait", 1j))
raises(TypeError, lambda: BlockingIOError(errno.EAGAIN, "wait", NumericWithoutIndex()))
raises(TypeError, lambda: BlockingIOError(errno.EAGAIN, "wait", BadIndex()),
       "__index__ returned non-int (type str)")
raises(ValueError, lambda: BlockingIOError(errno.EAGAIN, "wait", TooWide()),
       "cannot fit 'TooWide' into an index-sized integer")
raises(OverflowError, lambda: BlockingIOError(errno.EAGAIN, "wait", IndexErrorFromUser()),
       "from index")

e = OSError()
assert OSError.characters_written.__objclass__ is OSError
assert not hasattr(e, "characters_written")
raises(AttributeError, lambda: delattr(e, "characters_written"), "characters_written")
e.characters_written = Index()
assert e.characters_written == 42
for count in (-(2**63), 2**63 - 1, 0, True):
    OSError.characters_written.__set__(e, count)
    assert type(e.characters_written) is int and e.characters_written == count
raises(ValueError, lambda: setattr(e, "characters_written", 2**64))
assert e.characters_written == 1
del e.characters_written
assert not hasattr(e, "characters_written")
e.characters_written = -1
assert not hasattr(e, "characters_written")
assert WithFallback().characters_written == "characters_written"
assert getattr(WithFallback(), "characters_written") == "characters_written"

for code in (errno.ENOENT + 2**64, errno.ENOENT - 2**64):
    e = OSError(code, "wide")
    assert type(e) is OSError and e.errno == code

args = (errno.ENOENT, "missing", None, 0, "unused")
e = OSError(*args)
assert e.args == args and e.filename is None and e.filename2 is None

for e in (OSError(errno.ENOENT, "missing", "node"),
          OSError(errno.EEXIST, "exists", "node", None, "target"),
          BlockingIOError(errno.EAGAIN, "wait", 42)):
    e.extra = ["state"]
    def check(clone):
        assert type(clone) is type(e)
        assert clone.args == e.args and clone.filename == e.filename
        assert clone.filename2 == e.filename2 and vars(clone) == vars(e)
        assert getattr(clone, "characters_written", None) == getattr(e, "characters_written", None)
    check(copy.copy(e))
    check(copy.deepcopy(e))
    for protocol in range(pickle.HIGHEST_PROTOCOL + 1):
        check(pickle.loads(pickle.dumps(e, protocol=protocol)))

print("OSError constructors OK")
