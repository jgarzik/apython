"""_io's type objects, which exist so that io.py can subclass them.

Lib/io.py writes `class IOBase(_io._IOBase, metaclass=abc.ABCMeta)` for each
of the four, and _compression, gzip and tarfile subclass the public names in
turn.  So what matters about these types is not what they do -- they are
empty -- but that they can be a base: with a metaclass, alongside a Python
class in the same MRO, with instances that carry a __dict__, and answering
register().

UnsupportedOperation is the other half: it derives from OSError AND
ValueError, because code that has never heard of io catches one or the
other.  A seek on a pipe has to look like an OSError, a bad argument like a
ValueError.
"""

import abc
import _io


def check(label, fn):
    try:
        got = fn()
    except Exception as exc:
        got = type(exc).__name__ + ": " + str(exc)
    print(label.ljust(30), repr(got))


# --- the module's surface ---
check("module name", lambda: _io.__name__)
# Membership, not the whole list: this module grows over several commits and
# CPython's carries __loader__ and __spec__ that no builtin module here has.
check("contents", lambda: sorted(n for n in
                                 ("_IOBase", "_RawIOBase", "_BufferedIOBase",
                                  "_TextIOBase", "UnsupportedOperation",
                                  "BlockingIOError", "DEFAULT_BUFFER_SIZE",
                                  "text_encoding")
                                 if hasattr(_io, n)))
check("DEFAULT_BUFFER_SIZE", lambda: _io.DEFAULT_BUFFER_SIZE)

# --- the four base types ---
for name in ("_IOBase", "_RawIOBase", "_BufferedIOBase", "_TextIOBase"):
    t = getattr(_io, name)
    check(name + " module", lambda t=t: t.__module__)
    check(name + " qualname", lambda t=t: t.__qualname__)
    check(name + " repr", lambda t=t: repr(t))
    check(name + " mro", lambda t=t: [c.__name__ for c in t.__mro__])

# --- an ordinary subclass ---
class Raw(_io._RawIOBase):
    def read(self, n=-1):
        return b"x" * n

    def readable(self):
        return True


r = Raw()
check("subclass read", lambda: r.read(3))
check("subclass isinstance", lambda: (isinstance(r, _io._RawIOBase),
                                      isinstance(r, _io._IOBase)))
check("instance __dict__", lambda: (setattr(r, "tag", 7), r.tag, r.__dict__))


# --- the shape io.py builds: a metaclass, and a Python class in the MRO ---
class IOBase(_io._IOBase, metaclass=abc.ABCMeta):
    def readable(self):
        return False

    # No abstractmethod here: apython does not enforce them, and this test is
    # about the base type, not about abc.  The old bug list recorded the gap.

class RawIOBase(_io._RawIOBase, IOBase):
    pass


class Impl(RawIOBase):
    def readable(self):
        return True


i = Impl()
check("concrete mro", lambda: [c.__name__ for c in type(i).__mro__])
check("override wins", lambda: i.readable())
check("isinstance through both", lambda: (isinstance(i, IOBase),
                                          isinstance(i, _io._IOBase)))


class Duck:
    pass


IOBase.register(Duck)
check("register", lambda: (issubclass(Duck, IOBase), isinstance(Duck(), IOBase)))

# --- UnsupportedOperation ---
check("Unsupported mro", lambda: [c.__name__ for c in
                                  _io.UnsupportedOperation.__mro__])


def raise_it():
    raise _io.UnsupportedOperation("seek")


def caught_as(exc_type):
    try:
        raise_it()
    except exc_type as e:
        return type(e).__name__ + ": " + str(e)
    return "not caught"


check("as OSError", lambda: caught_as(OSError))
check("as ValueError", lambda: caught_as(ValueError))
check("as Exception", lambda: caught_as(Exception))
check("its own args", lambda: _io.UnsupportedOperation("a", "b").args)

# io.py assigns to it, so __module__ has to be writable.
_io.UnsupportedOperation.__module__ = "io"
check("module reassigned", lambda: _io.UnsupportedOperation.__module__)
_io.UnsupportedOperation.__module__ = "_io"

check("BlockingIOError", lambda: (_io.BlockingIOError is BlockingIOError,
                                  issubclass(_io.BlockingIOError, OSError)))

# --- text_encoding ---
check("text_encoding(None)", lambda: _io.text_encoding(None))
check("text_encoding(utf-8)", lambda: _io.text_encoding("utf-8"))
check("text_encoding two args", lambda: _io.text_encoding(None, 3))
check("text_encoding no args", lambda: _io.text_encoding())
