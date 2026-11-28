"""_io - the streams module, assembled from its two halves.

CPython implements all of _io in C.  Here the raw layer and the type objects
are assembly, in the builtin module _iocore, and everything stacked on top of
them -- the buffering and the text layer -- is this file.  The split is an
implementation detail and is not visible from outside: the types built in
_iocore already say _io in their __module__, and CPython's own Lib/io.py
imports every name it needs from here and works unchanged.

The classes below are meant to be read against CPython's Lib/_pyio.py, which
is its readable replica of the same C module.  This is not that file, and
must not be named _pyio: CPython ships one, and on a path where its stdlib is
visible theirs would win -- and theirs opens with `from io import ...`, a
circle that only closes if the whole C module is already there.

What is deliberately not here: the threading locks, since there is one
thread; ResourceWarning, since there is no warnings filter to hear it; and
the Windows paths.

The decoders are the one place this departs from CPython in shape rather than
size.  CPython reaches for codecs.lookup() for every encoding; codecs is
CPython's own Python module and is not always on the path here, so utf-8,
ascii and latin-1 -- which is every encoding the interpreter itself uses --
are served directly out of _codecs, and codecs is consulted only for the
rest.
"""


import _codecs
import _iocore
import _thread
import abc

from _iocore import (BlockingIOError, BytesIO, DEFAULT_BUFFER_SIZE, FileIO,
                     UnsupportedOperation, text_encoding, _BufferedIOBase,
                     _IOBase, _RawIOBase, _TextIOBase)

__all__ = ["BlockingIOError", "open", "open_code", "IOBase", "RawIOBase",
           "FileIO", "BytesIO", "StringIO", "BufferedIOBase",
           "BufferedReader", "BufferedWriter", "BufferedRandom",
           "BufferedRWPair", "TextIOBase", "TextIOWrapper",
           "UnsupportedOperation", "IncrementalNewlineDecoder",
           "DEFAULT_BUFFER_SIZE", "text_encoding"]

SEEK_SET = 0
SEEK_CUR = 1
SEEK_END = 2

_BLOCKSIZE = DEFAULT_BUFFER_SIZE


# --- the decoders and encoders -------------------------------------------

class _Utf8IncrementalDecoder:
    """utf-8 without going through codecs, which may not be importable.

    _codecs.utf_8_decode already holds back an incomplete trailing sequence
    and reports what it consumed, so the state is just the bytes it did not
    take.
    """

    def __init__(self, errors="strict"):
        self.errors = errors
        self.buffer = b""

    def decode(self, data, final=False):
        data = self.buffer + bytes(data)
        text, consumed = _codecs.utf_8_decode(data, self.errors, final)
        self.buffer = data[consumed:]
        return text

    def reset(self):
        self.buffer = b""

    def getstate(self):
        return (self.buffer, 0)

    def setstate(self, state):
        self.buffer = state[0]


class _SingleByteIncrementalDecoder:
    """ascii and latin-1: one byte in, one character out, so never split."""

    def __init__(self, decode, errors="strict"):
        self._decode = decode
        self.errors = errors

    def decode(self, data, final=False):
        return self._decode(bytes(data), self.errors)[0]

    def reset(self):
        pass

    def getstate(self):
        return (b"", 0)

    def setstate(self, state):
        pass


def _normalize_encoding(encoding):
    if encoding is None:
        return "utf-8"
    name = encoding.lower().replace("_", "-")
    if name in ("utf-8", "utf8", "u8", "utf", "locale"):
        return "utf-8"
    if name in ("ascii", "us-ascii", "646"):
        return "ascii"
    if name in ("latin-1", "latin1", "iso-8859-1", "iso8859-1", "8859",
                "cp819", "latin", "l1"):
        return "latin-1"
    return name


def _make_decoder(encoding, errors):
    name = _normalize_encoding(encoding)
    if name == "utf-8":
        return _Utf8IncrementalDecoder(errors)
    if name == "ascii":
        return _SingleByteIncrementalDecoder(_codecs.ascii_decode, errors)
    if name == "latin-1":
        return _SingleByteIncrementalDecoder(_codecs.latin_1_decode, errors)
    import codecs
    return codecs.getincrementaldecoder(encoding)(errors)


def _make_encoder(encoding, errors):
    name = _normalize_encoding(encoding)
    if name == "utf-8":
        return lambda s: _codecs.utf_8_encode(s, errors)[0]
    if name == "ascii":
        return lambda s: _codecs.ascii_encode(s, errors)[0]
    if name == "latin-1":
        return lambda s: _codecs.latin_1_encode(s, errors)[0]
    import codecs
    enc = codecs.getincrementalencoder(encoding)(errors)
    return enc.encode


# --- what every stream gets, whatever it is made of ------------------------
#
# CPython puts these on the C _IOBase, so a FileIO or a BytesIO has them
# without anyone writing them twice.  _iocore._IOBase is a heaptype, so they
# can be attached from here -- which keeps the generic code in Python and out
# of the assembly, and is why open(path, "rb", buffering=0) has a readline at
# all: it hands back the raw file itself, with no buffered layer above it.


def _size_or_none(value):
    """A size argument that accepts None, converted as CPython converts it.

    Every size here is a C Py_ssize_t on CPython's side, so the conversion
    happens BEFORE the method does anything -- which matters, because a
    method that validates late has already moved its cursor.  `read(0.0)` on a
    BufferedReader raised TypeError from a slice deep inside, having first
    written a FLOAT into _read_pos; every later read on that object then
    failed too.
    """
    if value is None or isinstance(value, int):
        return value
    try:
        method = type(value).__index__
    except AttributeError:
        raise TypeError("argument should be integer or None, not '%s'"
                        % (type(value).__name__,)) from None
    result = method(value)
    if not isinstance(result, int):
        raise TypeError("__index__ returned non-int (type %s)"
                        % (type(result).__name__,))
    return result


def _ssize(value):
    """A size argument that does NOT accept None; CPython's other wording."""
    if isinstance(value, int):
        return value
    try:
        method = type(value).__index__
    except AttributeError:
        raise TypeError("'%s' object cannot be interpreted as an integer"
                        % (type(value).__name__,)) from None
    result = method(value)
    if not isinstance(result, int):
        raise TypeError("__index__ returned non-int (type %s)"
                        % (type(result).__name__,))
    return result


def _iobase_readline(self, size=-1):
    if size is None:
        size = -1
    peek = getattr(self, "peek", None)
    res = bytearray()
    while size < 0 or len(res) < size:
        n = 1
        if peek is not None:
            readahead = peek(1)
            if not readahead:
                break
            found = readahead.find(b"\n") + 1
            n = found if found > 0 else len(readahead)
            if size >= 0:
                n = min(n, size - len(res))
        chunk = self.read(n)
        if not chunk:
            break
        res += chunk
        if res.endswith(b"\n"):
            break
    return bytes(res)


def _iobase_readlines(self, hint=None):
    if hint is None or hint <= 0:
        return list(self)
    n = 0
    lines = []
    for line in self:
        lines.append(line)
        n += len(line)
        if n >= hint:
            break
    return lines


def _iobase_writelines(self, lines):
    if self.closed:
        raise ValueError("I/O operation on closed file.")
    for line in lines:
        self.write(line)


def _iobase_iter(self):
    if self.closed:
        raise ValueError("I/O operation on closed file.")
    return self


def _iobase_next(self):
    line = self.readline()
    if not line:
        raise StopIteration
    return line


def _iobase_fileno(self):
    raise UnsupportedOperation("fileno")


def _iobase_isatty(self):
    if self.closed:
        raise ValueError("I/O operation on closed file.")
    return False


def _iobase_flush(self):
    if self.closed:
        raise ValueError("I/O operation on closed file.")


for _name, _fn in (("readline", _iobase_readline),
                   ("readlines", _iobase_readlines),
                   ("writelines", _iobase_writelines),
                   ("__iter__", _iobase_iter),
                   ("__next__", _iobase_next),
                   ("fileno", _iobase_fileno),
                   ("isatty", _iobase_isatty),
                   ("flush", _iobase_flush)):
    if not hasattr(_iocore._IOBase, _name):
        setattr(_iocore._IOBase, _name, _fn)
del _name, _fn


# --- the abstract layer ---------------------------------------------------

class IOBase(_iocore._IOBase, metaclass=abc.ABCMeta):
    """The methods every stream has, whatever it is made of.

    Everything here is defined in terms of the four a concrete class must
    supply -- readinto, write, seek and close -- so a new stream type needs
    only those.
    """

    def _unsupported(self, name):
        # CPython's C module raises the bare operation name here, and code
        # that matches on the message sees that one, not a prettier one.
        raise UnsupportedOperation(name)

    def seek(self, pos, whence=0):
        self._unsupported("seek")

    def tell(self):
        return self.seek(0, 1)

    def truncate(self, pos=None):
        self._unsupported("truncate")

    def flush(self):
        if self.__closed:
            raise ValueError("I/O operation on closed file.")

    __closed = False

    def close(self):
        if not self.__closed:
            try:
                self.flush()
            finally:
                self.__closed = True

    def __del__(self):
        try:
            closed = self.closed
        except Exception:
            # A detached stream raises ValueError here, and a half-built one
            # AttributeError.  Neither is worth reporting from a finaliser.
            return
        if closed:
            return
        try:
            self.close()
        except Exception:
            pass

    def seekable(self):
        return False

    def _checkSeekable(self, msg=None):
        if not self.seekable():
            raise UnsupportedOperation(
                "not seekable" if msg is None else msg)
        return True

    def readable(self):
        return False

    def _checkReadable(self, msg=None):
        if not self.readable():
            raise UnsupportedOperation(
                "not readable" if msg is None else msg)
        return True

    def writable(self):
        return False

    def _checkWritable(self, msg=None):
        if not self.writable():
            raise UnsupportedOperation(
                "not writable" if msg is None else msg)
        return True

    @property
    def closed(self):
        return self.__closed

    def _checkClosed(self, msg=None):
        if self.closed:
            raise ValueError("I/O operation on closed file."
                             if msg is None else msg)

    def __enter__(self):
        self._checkClosed()
        return self

    def __exit__(self, *args):
        self.close()

    def fileno(self):
        self._unsupported("fileno")

    def isatty(self):
        self._checkClosed()
        return False

    def readline(self, size=-1):
        # peek() is the fast path: without it a line costs one read() per
        # character, which is what a stream with no peek falls back to.
        size = _size_or_none(size)
        if size is None:
            size = -1
        peek = getattr(self, "peek", None)
        res = bytearray()
        while size < 0 or len(res) < size:
            b = 1
            if peek is not None:
                readahead = peek(1)
                if not readahead:
                    break
                n = readahead.find(b"\n") + 1
                if n > 0:
                    b = n
                else:
                    b = len(readahead)
                if size >= 0:
                    b = min(b, size - len(res))
            chunk = self.read(b)
            if not chunk:
                break
            res += chunk
            if res.endswith(b"\n"):
                break
        return bytes(res)

    def __iter__(self):
        self._checkClosed()
        return self

    def __next__(self):
        line = self.readline()
        if not line:
            raise StopIteration
        return line

    def readlines(self, hint=None):
        hint = _size_or_none(hint)
        if hint is None or hint <= 0:
            return list(self)
        n = 0
        lines = []
        for line in self:
            lines.append(line)
            n += len(line)
            if n >= hint:
                break
        return lines

    def writelines(self, lines):
        self._checkClosed()
        for line in lines:
            self.write(line)


def _push_down(pyclass, coretype):
    """Copy a Python base's methods onto the _iocore type it derives from.

    CPython's C `_io._IOBase` carries this whole surface, and its own
    Lib/io.py builds on it DIRECTLY rather than on the Python class here:
    `class IOBase(_io._IOBase, metaclass=abc.ABCMeta)` is what everything
    written against `io.IOBase` really derives from.  A method that lives
    only on this module's IOBase is invisible to all of it -- gzip.GzipFile
    derives from io.BufferedIOBase and so had no `closed` and no
    `__enter__`, and `with gzip.open(...)` was a TypeError about the context
    manager protocol.

    So the definitions are written once, here, and pushed down onto the core
    type, which is what makes the split invisible from either direction.
    Anything the assembly already defines is left alone.
    """
    skip = ("__dict__", "__weakref__", "__module__", "__qualname__",
            "__doc__", "__abstractmethods__", "_abc_impl", "__slots__")
    for name, value in list(vars(pyclass).items()):
        if name in skip:
            continue
        if name in vars(coretype):
            continue
        setattr(coretype, name, value)


_push_down(IOBase, _iocore._IOBase)


class RawIOBase(_iocore._RawIOBase, IOBase):

    def read(self, size=-1):
        if size is None or size < 0:
            return self.readall()
        b = bytearray(size)
        n = self.readinto(b)
        if n is None:
            return None
        del b[n:]
        return bytes(b)

    def readall(self):
        res = bytearray()
        while True:
            data = self.read(_BLOCKSIZE)
            if not data:
                break
            res += data
        if res:
            return bytes(res)
        return data

    def readinto(self, b):
        self._unsupported("readinto")

    def write(self, b):
        self._unsupported("write")


_push_down(RawIOBase, _iocore._RawIOBase)


class BufferedIOBase(_iocore._BufferedIOBase, IOBase):

    def read(self, size=-1):
        self._unsupported("read")

    def read1(self, size=-1):
        self._unsupported("read1")

    def readinto(self, b):
        return self._readinto(b, read1=False)

    def readinto1(self, b):
        return self._readinto(b, read1=True)

    def _readinto(self, b, read1):
        if not isinstance(b, memoryview):
            b = memoryview(b)
        b = b.cast("B")
        if read1:
            data = self.read1(len(b))
        else:
            data = self.read(len(b))
        n = len(data)
        b[:n] = data
        return n

    def write(self, b):
        self._unsupported("write")

    def detach(self):
        self._unsupported("detach")


class _BufferedIOMixin(BufferedIOBase):
    """The part of a buffered stream that is just forwarding to the raw one."""

    def __init__(self, raw):
        self._raw = raw

    def seek(self, pos, whence=0):
        new_position = self._checkDetached().seek(pos, whence)
        if new_position < 0:
            raise OSError("seek() returned an invalid position")
        return new_position

    def tell(self):
        pos = self._checkDetached().tell()
        if pos < 0:
            raise OSError("tell() returned an invalid position")
        return pos

    def truncate(self, pos=None):
        self._checkClosed()
        self._checkWritable()
        self.flush()
        if pos is None:
            pos = self.tell()
        return self.raw.truncate(pos)

    def flush(self):
        raw = self._checkDetached()
        if self.closed:
            raise ValueError("flush of closed file")
        raw.flush()

    def close(self):
        if self.raw is not None and not self.closed:
            try:
                self.flush()
            finally:
                self.raw.close()

    def detach(self):
        if self.raw is None:
            raise ValueError("raw stream has been detached")
        self.flush()
        raw = self._raw
        self._raw = None
        return raw

    def _checkDetached(self):
        # Every forwarder below goes through the raw stream, which detach()
        # sets to None.  Without this they all raised AttributeError on None;
        # CPython raises ValueError, and code that catches one and not the
        # other is looking for the second.
        if self._raw is None:
            raise ValueError("raw stream has been detached")
        return self._raw

    @property
    def closed(self):
        return self._checkDetached().closed

    @property
    def raw(self):
        return self._raw

    @property
    def name(self):
        return self._checkDetached().name

    @property
    def mode(self):
        return self._checkDetached().mode

    def __repr__(self):
        modname = self.__class__.__module__
        clsname = self.__class__.__qualname__
        try:
            name = self.name
        except Exception:
            return "<%s.%s>" % (modname, clsname)
        return "<%s.%s name=%r>" % (modname, clsname, name)

    def fileno(self):
        return self._checkDetached().fileno()

    def isatty(self):
        return self._checkDetached().isatty()

    def readable(self):
        return self._checkDetached().readable()

    def writable(self):
        return self._checkDetached().writable()

    def seekable(self):
        return self._checkDetached().seekable()

    def flush_and_close(self):
        self.close()


class BufferedReader(_BufferedIOMixin):
    """Reads ahead in blocks so a per-line loop is not a syscall per line."""

    def __init__(self, raw, buffer_size=DEFAULT_BUFFER_SIZE):
        if not raw.readable():
            raise OSError('"raw" argument must be readable.')
        _BufferedIOMixin.__init__(self, raw)
        if buffer_size <= 0:
            raise ValueError("invalid buffer size")
        self.buffer_size = buffer_size
        self._reset_read_buf()

    def _reset_read_buf(self):
        self._read_buf = b""
        self._read_pos = 0

    def readable(self):
        # Not a bare True: after detach() there is no raw stream to be
        # readable, and CPython raises rather than answering.
        self._checkDetached()
        return True

    def writable(self):
        # A reader is never writable, and CPython answers that without
        # consulting the raw stream -- so it still answers after detach(),
        # where readable() and seekable() raise.
        return False

    def read(self, size=None):
        size = _size_or_none(size)
        if size is not None and size < -1:
            raise ValueError("invalid number of bytes to read")
        return self._read_unlocked(size)

    def _read_unlocked(self, n=None):
        self._checkDetached()
        nodata_val = b""
        empty_values = (b"", None)
        buf = self._read_buf
        pos = self._read_pos

        # A read of everything: drain the buffer, then the raw stream.
        if n is None or n == -1:
            self._reset_read_buf()
            chunks = [buf[pos:]]
            current_size = 0
            while True:
                chunk = self.raw.read()
                if chunk in empty_values:
                    nodata_val = chunk
                    break
                current_size += len(chunk)
                chunks.append(chunk)
            return b"".join(chunks) or nodata_val

        avail = len(buf) - pos
        if n <= avail:
            self._read_pos += n
            return buf[pos:pos + n]

        chunks = [buf[pos:]]
        wanted = max(self.buffer_size, n)
        while avail < n:
            chunk = self.raw.read(wanted)
            if chunk in empty_values:
                nodata_val = chunk
                break
            avail += len(chunk)
            chunks.append(chunk)
        # The last chunk usually overshoots; what is past n becomes the
        # buffer, which is the whole point of reading ahead.
        n = min(n, avail)
        out = b"".join(chunks)
        self._read_buf = out[n:]
        self._read_pos = 0
        return out[:n] if out else nodata_val

    def peek(self, size=0):
        return self._peek_unlocked(_ssize(size))

    def _peek_unlocked(self, n=0):
        self._checkDetached()
        want = min(n, self.buffer_size)
        have = len(self._read_buf) - self._read_pos
        if have < want or have <= 0:
            to_read = self.buffer_size - have
            current = self.raw.read(to_read)
            if current:
                self._read_buf = self._read_buf[self._read_pos:] + current
                self._read_pos = 0
        return self._read_buf[self._read_pos:]

    def read1(self, size=-1):
        self._checkDetached()
        size = _ssize(size)
        if size < 0:
            size = self.buffer_size
        if size == 0:
            return b""
        self._peek_unlocked(1)
        return self._read_unlocked(min(size, len(self._read_buf)
                                       - self._read_pos))

    def _readinto(self, buf, read1):
        self._checkDetached()
        if not isinstance(buf, memoryview):
            buf = memoryview(buf)
        buf = buf.cast("B")
        written = 0
        n = len(self._read_buf) - self._read_pos
        if n > 0:
            if n > len(buf):
                n = len(buf)
            buf[:n] = self._read_buf[self._read_pos:self._read_pos + n]
            self._read_pos += n
            written = n
            if read1:
                return written
        while written < len(buf):
            n = self.raw.readinto(buf[written:])
            if not n:
                break
            written += n
            if read1:
                break
        return written

    def tell(self):
        return _BufferedIOMixin.tell(self) - len(self._read_buf) + self._read_pos

    def seek(self, pos, whence=0):
        if whence not in (0, 1, 2):
            raise ValueError("invalid whence value")
        self._checkClosed("seek of closed file")
        if whence == 1:
            pos -= len(self._read_buf) - self._read_pos
        pos = _BufferedIOMixin.seek(self, pos, whence)
        self._reset_read_buf()
        return pos


class BufferedWriter(_BufferedIOMixin):
    """Collects writes until there is a block's worth, then makes one."""

    def __init__(self, raw, buffer_size=DEFAULT_BUFFER_SIZE):
        if not raw.writable():
            raise OSError('"raw" argument must be writable.')
        _BufferedIOMixin.__init__(self, raw)
        if buffer_size <= 0:
            raise ValueError("invalid buffer size")
        self.buffer_size = buffer_size
        self._write_buf = bytearray()
        self._write_lock = _thread.allocate_lock()

    def readable(self):
        return False

    def writable(self):
        self._checkDetached()
        return True

    def write(self, b):
        self._checkDetached()
        if isinstance(b, str):
            raise TypeError("can't write str to binary stream")
        if self.closed:
            raise ValueError("write to closed file")
        with self._write_lock:
            if self.closed:
                raise ValueError("write to closed file")
            self._write_buf.extend(b)
            written = len(b)
            if len(self._write_buf) > self.buffer_size:
                self._flush_unlocked()
            return written

    def truncate(self, pos=None):
        self._checkClosed()
        self._checkWritable()
        with self._write_lock:
            self._flush_unlocked()
            if pos is None:
                pos = self.raw.tell()
            return self.raw.truncate(pos)

    def flush(self):
        if self.closed:
            raise ValueError("flush of closed file")
        with self._write_lock:
            if self.closed:
                raise ValueError("flush of closed file")
            self._flush_unlocked()

    def _flush_unlocked(self):
        while self._write_buf:
            n = self.raw.write(self._write_buf)
            if n is None:
                raise BlockingIOError(
                    11, "write could not complete without blocking", 0)
            if n > len(self._write_buf) or n < 0:
                raise OSError("write() returned incorrect number of bytes")
            del self._write_buf[:n]

    def tell(self):
        return _BufferedIOMixin.tell(self) + len(self._write_buf)

    def seek(self, pos, whence=0):
        if whence not in (0, 1, 2):
            raise ValueError("invalid whence value")
        self._checkClosed("seek of closed file")
        with self._write_lock:
            self._flush_unlocked()
            return _BufferedIOMixin.seek(self, pos, whence)

    def close(self):
        if self.raw is None or self.closed:
            return
        with self._write_lock:
            if self.raw is None or self.closed:
                return
            try:
                self._flush_unlocked()
            finally:
                self.raw.close()


class BufferedRandom(BufferedWriter, BufferedReader):
    """Both at once, for a file opened with a +.

    The rule that makes it work is that a read has to flush what is pending
    and a write has to discard what was read ahead; otherwise the two
    buffers disagree about where the file position is.
    """

    def __init__(self, raw, buffer_size=DEFAULT_BUFFER_SIZE):
        if not raw.seekable():
            raise UnsupportedOperation("not seekable")
        BufferedReader.__init__(self, raw, buffer_size)
        BufferedWriter.__init__(self, raw, buffer_size)

    def seek(self, pos, whence=0):
        if whence not in (0, 1, 2):
            raise ValueError("invalid whence value")
        self.flush()
        if self._read_buf:
            # The raw stream is ahead of where the caller thinks it is.
            self.raw.seek(self._read_pos - len(self._read_buf), 1)
        pos = self.raw.seek(pos, whence)
        self._reset_read_buf()
        if pos < 0:
            raise OSError("seek() returned invalid position")
        return pos

    def tell(self):
        if self._write_buf:
            return BufferedWriter.tell(self)
        return BufferedReader.tell(self)

    def read(self, size=None):
        size = _size_or_none(size)
        if size is None:
            size = -1
        self.flush()
        return BufferedReader.read(self, size)

    def readinto(self, b):
        self.flush()
        return BufferedReader.readinto(self, b)

    def peek(self, size=0):
        size = _ssize(size)
        self.flush()
        return BufferedReader.peek(self, size)

    def read1(self, size=-1):
        size = _ssize(size)
        self.flush()
        return BufferedReader.read1(self, size)

    def readinto1(self, b):
        self.flush()
        return BufferedReader.readinto1(self, b)

    def write(self, b):
        if self._read_buf:
            self.raw.seek(self._read_pos - len(self._read_buf), 1)
            self._reset_read_buf()
        return BufferedWriter.write(self, b)

    def readable(self):
        return True

    def writable(self):
        return True


class BufferedRWPair(BufferedIOBase):
    """Two unrelated raw streams read from and written to as one object.

    Lib/io.py imports it by name, so it has to exist; a socket is the only
    thing that really wants it, and there are no sockets here.  It is
    deliberately NOT a BufferedRandom: the two halves have separate positions
    and it is not seekable.
    """

    def __init__(self, reader, writer, buffer_size=DEFAULT_BUFFER_SIZE):
        if not reader.readable():
            raise OSError('"reader" argument must be readable.')
        if not writer.writable():
            raise OSError('"writer" argument must be writable.')
        self.reader = BufferedReader(reader, buffer_size)
        self.writer = BufferedWriter(writer, buffer_size)

    def read(self, size=-1):
        size = _size_or_none(size)
        if size is None:
            size = -1
        return self.reader.read(size)

    def readinto(self, b):
        return self.reader.readinto(b)

    def write(self, b):
        return self.writer.write(b)

    def peek(self, size=0):
        return self.reader.peek(_ssize(size))

    def read1(self, size=-1):
        return self.reader.read1(_ssize(size))

    def readinto1(self, b):
        return self.reader.readinto1(b)

    def readable(self):
        return self.reader.readable()

    def writable(self):
        return self.writer.writable()

    def flush(self):
        return self.writer.flush()

    def close(self):
        try:
            self.writer.close()
        finally:
            self.reader.close()

    def isatty(self):
        return self.reader.isatty() or self.writer.isatty()

    @property
    def closed(self):
        return self.writer.closed


# --- the text layer -------------------------------------------------------

_push_down(BufferedIOBase, _iocore._BufferedIOBase)


class TextIOBase(_iocore._TextIOBase, IOBase):

    def read(self, size=-1):
        self._unsupported("read")

    def write(self, s):
        self._unsupported("write")

    def truncate(self, pos=None):
        self._unsupported("truncate")

    def readline(self):
        self._unsupported("readline")

    def detach(self):
        self._unsupported("detach")

    @property
    def encoding(self):
        return None

    @property
    def newlines(self):
        return None

    @property
    def errors(self):
        return None


_push_down(TextIOBase, _iocore._TextIOBase)


class IncrementalNewlineDecoder:
    """Universal newlines, on top of a byte decoder.

    Translating "\\r\\n" is the whole difficulty: the pair can arrive split
    across two reads, so a trailing "\\r" has to be held back until the next
    chunk says whether an "\\n" follows it.
    """

    def __init__(self, decoder, translate, errors="strict"):
        self.decoder = decoder
        self.errors = errors
        self.translate = translate
        self.seennl = 0
        self.pendingcr = False

    def decode(self, input, final=False):
        if self.decoder is None:
            output = input
        else:
            output = self.decoder.decode(input, final=final)
        if self.pendingcr and (output or final):
            output = "\r" + output
            self.pendingcr = False

        if output.endswith("\r") and not final:
            output = output[:-1]
            self.pendingcr = True

        if output:
            if "\n" in output:
                self.seennl |= 1        # \n
            if "\r" in output:
                if "\r\n" in output:
                    self.seennl |= 4    # \r\n
                if output.replace("\r\n", "").find("\r") >= 0:
                    self.seennl |= 2    # \r

        if self.translate and "\r" in output:
            output = output.replace("\r\n", "\n").replace("\r", "\n")
        return output

    def getstate(self):
        if self.decoder is None:
            buf = b""
            flag = 0
        else:
            state = self.decoder.getstate()
            buf = state[0]
            flag = state[1] << 1
        return (buf, flag | int(self.pendingcr))

    def setstate(self, state):
        buf, flag = state
        self.pendingcr = bool(flag & 1)
        if self.decoder is not None:
            self.decoder.setstate((buf, flag >> 1))

    def reset(self):
        self.seennl = 0
        self.pendingcr = False
        if self.decoder is not None:
            self.decoder.reset()

    @property
    def newlines(self):
        return (None,
                "\n",
                "\r",
                ("\r", "\n"),
                "\r\n",
                ("\n", "\r\n"),
                ("\r", "\r\n"),
                ("\r", "\n", "\r\n"))[self.seennl]


class TextIOWrapper(TextIOBase):
    """str on one side, a buffered byte stream on the other."""

    _CHUNK_SIZE = 2048

    def __init__(self, buffer, encoding=None, errors=None, newline=None,
                 line_buffering=False, write_through=False):
        if newline is not None and not isinstance(newline, str):
            raise TypeError("illegal newline type: %r" % (type(newline),))
        if newline not in (None, "", "\n", "\r", "\r\n"):
            raise ValueError("illegal newline value: %r" % (newline,))
        if encoding is None:
            encoding = "utf-8"
        elif not isinstance(encoding, str):
            raise ValueError("invalid encoding: %r" % encoding)
        if errors is None:
            errors = "strict"
        elif not isinstance(errors, str):
            raise ValueError("invalid errors: %r" % errors)

        self._buffer = buffer
        self._decoded_chars = ""
        self._decoded_chars_used = 0
        self._snapshot = None
        self._seekable = self._telling = self.buffer.seekable()
        self._has_read1 = hasattr(self.buffer, "read1")
        self._configure(encoding, errors, newline, line_buffering,
                        write_through)

    def _configure(self, encoding, errors, newline, line_buffering,
                   write_through):
        self._encoding = encoding
        self._errors = errors
        self._encoder = None
        self._decoder = None
        self._readnl = newline
        self._readtranslate = newline is None
        self._readuniversal = not newline
        self._writetranslate = newline != ""
        self._writenl = newline or "\n"
        self._line_buffering = line_buffering
        self._write_through = write_through

        if self._seekable and self.writable():
            position = self.buffer.tell()
            if position != 0:
                try:
                    self._get_encoder()
                except LookupError:
                    pass

    def __repr__(self):
        try:
            name = self.name
        except Exception:
            return "<%s.%s encoding=%r>" % (self.__class__.__module__,
                                            self.__class__.__qualname__,
                                            self.encoding)
        return "<%s.%s name=%r encoding=%r>" % (self.__class__.__module__,
                                                self.__class__.__qualname__,
                                                name, self.encoding)

    @property
    def encoding(self):
        return self._encoding

    @property
    def errors(self):
        return self._errors

    @property
    def line_buffering(self):
        return self._line_buffering

    @property
    def write_through(self):
        return self._write_through

    @property
    def buffer(self):
        return self._buffer

    def seekable(self):
        if self.closed:
            raise ValueError("I/O operation on closed file.")
        return self._seekable

    def readable(self):
        return self._checkDetached().readable()

    def writable(self):
        return self._checkDetached().writable()

    def flush(self):
        if self.closed:
            raise ValueError("I/O operation on closed file.")
        self.buffer.flush()
        self._telling = self._seekable

    def close(self):
        if self.buffer is not None and not self.closed:
            try:
                self.flush()
            finally:
                self.buffer.close()

    def _checkDetached(self):
        if self._buffer is None:
            raise ValueError("underlying buffer has been detached")
        return self._buffer

    @property
    def closed(self):
        return self._checkDetached().closed

    @property
    def name(self):
        return self._checkDetached().name

    def fileno(self):
        return self._checkDetached().fileno()

    def isatty(self):
        return self._checkDetached().isatty()

    def _get_encoder(self):
        if self._encoder is None:
            self._encoder = _make_encoder(self._encoding, self._errors)
        return self._encoder

    def _get_decoder(self):
        if self._decoder is None:
            decoder = _make_decoder(self._encoding, self._errors)
            if self._readuniversal:
                decoder = IncrementalNewlineDecoder(decoder,
                                                    self._readtranslate)
            self._decoder = decoder
        return self._decoder

    def write(self, s):
        if self.closed:
            raise ValueError("I/O operation on closed file.")
        if not isinstance(s, str):
            raise TypeError("can't write %s to text stream"
                            % s.__class__.__name__)
        length = len(s)
        haslf = (self._writetranslate or self._line_buffering) and "\n" in s
        if haslf and self._writetranslate and self._writenl != "\n":
            s = s.replace("\n", self._writenl)
        b = self._get_encoder()(s)
        self.buffer.write(b)
        if self._line_buffering and (haslf or "\r" in s):
            self.flush()
        if self._snapshot is not None:
            self._set_decoded_chars("")
            self._snapshot = None
        if self._decoder:
            self._decoder.reset()
        return length

    def _set_decoded_chars(self, chars):
        self._decoded_chars = chars
        self._decoded_chars_used = 0

    def _get_decoded_chars(self, n=None):
        offset = self._decoded_chars_used
        if n is None:
            chars = self._decoded_chars[offset:]
        else:
            chars = self._decoded_chars[offset:offset + n]
        self._decoded_chars_used += len(chars)
        return chars

    def _rewind_decoded_chars(self, n):
        if self._decoded_chars_used < n:
            raise AssertionError("rewind decoded_chars out of bounds")
        self._decoded_chars_used -= n

    def _read_chunk(self):
        """One block in, one batch of characters out.

        The snapshot is what makes tell() possible: a decoder state plus the
        bytes that had not been consumed when it was taken is enough to
        replay the decode from a known position.
        """
        if self._decoder is None:
            raise ValueError("no decoder")

        if self._telling:
            dec_buffer, dec_flags = self._decoder.getstate()

        if self._has_read1:
            input_chunk = self.buffer.read1(self._CHUNK_SIZE)
        else:
            input_chunk = self.buffer.read(self._CHUNK_SIZE)
        eof = not input_chunk
        decoded_chars = self._decoder.decode(input_chunk, eof)
        self._set_decoded_chars(decoded_chars)

        if self._telling:
            self._snapshot = (dec_flags, dec_buffer + input_chunk)
        return not eof

    def tell(self):
        self._checkClosed()
        if not self._seekable:
            raise UnsupportedOperation("underlying stream is not seekable")
        if not self._telling:
            raise OSError("telling position disabled by next() call")
        self.flush()
        position = self.buffer.tell()
        decoder = self._decoder
        if decoder is None or self._snapshot is None:
            if self._decoded_chars:
                raise AssertionError("pending decoded text")
            return position

        dec_flags, next_input = self._snapshot
        position -= len(next_input)
        chars_to_skip = self._decoded_chars_used
        if chars_to_skip == 0:
            return position

        # Replay the decode from the snapshot, one byte at a time, until as
        # many characters have come out as the caller has consumed.  That
        # byte offset is the answer; a character position would not be, since
        # the caller may hand it back as a seek.
        saved_state = decoder.getstate()
        try:
            decoder.setstate((b"", dec_flags))
            start_pos = position
            start_flags = dec_flags
            bytes_fed = 0
            chars_decoded = 0
            need_eof = 0
            for i in range(len(next_input)):
                bytes_fed += 1
                chars_decoded += len(decoder.decode(next_input[i:i + 1]))
                dec_buffer, dec_flags = decoder.getstate()
                if not dec_buffer and chars_decoded <= chars_to_skip:
                    start_pos += bytes_fed
                    start_flags = dec_flags
                    chars_to_skip -= chars_decoded
                    bytes_fed = 0
                    chars_decoded = 0
                if chars_decoded >= chars_to_skip:
                    break
            else:
                # The snapshot ran out before enough characters came back, so
                # replaying this cookie needs the decoder told about EOF.
                # need_eof was never set and never passed, so _unpack_cookie
                # read it as False and seek(tell()) mis-decoded a pending
                # '\r' at the end of the buffer.
                chars_decoded += len(decoder.decode(b"", final=True))
                need_eof = 1
                if chars_decoded < chars_to_skip:
                    raise OSError("can't reconstruct logical file position")
            return self._pack_cookie(start_pos, start_flags,
                                     bytes_fed, chars_to_skip, need_eof)
        finally:
            decoder.setstate(saved_state)

    def _pack_cookie(self, position, dec_flags=0, bytes_to_feed=0,
                     chars_to_skip=0, need_eof=False):
        return (position | (dec_flags << 64) | (bytes_to_feed << 128)
                | (chars_to_skip << 192) | bool(need_eof) << 256)

    def _unpack_cookie(self, bigint):
        rest, position = divmod(bigint, 1 << 64)
        rest, dec_flags = divmod(rest, 1 << 64)
        rest, bytes_to_feed = divmod(rest, 1 << 64)
        need_eof, chars_to_skip = divmod(rest, 1 << 64)
        return position, dec_flags, bytes_to_feed, chars_to_skip, bool(need_eof)

    def seek(self, cookie, whence=0):
        def _reset_encoder(position):
            if position != 0:
                self._get_encoder()

        if self.closed:
            raise ValueError("tell on closed file")
        if not self._seekable:
            raise UnsupportedOperation("underlying stream is not seekable")
        if whence == SEEK_CUR:
            if cookie != 0:
                raise UnsupportedOperation(
                    "can't do nonzero cur-relative seeks")
            cookie = self.tell()
        elif whence == SEEK_END:
            if cookie != 0:
                raise UnsupportedOperation(
                    "can't do nonzero end-relative seeks")
            self.flush()
            position = self.buffer.seek(0, whence)
            self._set_decoded_chars("")
            self._snapshot = None
            if self._decoder:
                self._decoder.reset()
            _reset_encoder(position)
            return position
        if whence != 0:
            raise ValueError("unsupported whence (%r)" % (whence,))
        if cookie < 0:
            raise ValueError("negative seek position %r" % (cookie,))
        self.flush()

        start_pos, dec_flags, bytes_to_feed, chars_to_skip, need_eof = \
            self._unpack_cookie(cookie)
        self.buffer.seek(start_pos)
        self._set_decoded_chars("")
        self._snapshot = None

        if cookie == 0 and self._decoder:
            self._decoder.reset()
        elif self._decoder or dec_flags or chars_to_skip:
            self._decoder = self._decoder or self._get_decoder()
            self._decoder.setstate((b"", dec_flags))
            self._snapshot = (dec_flags, b"")

        if chars_to_skip:
            input_chunk = self.buffer.read(bytes_to_feed)
            self._set_decoded_chars(
                self._decoder.decode(input_chunk, need_eof))
            self._snapshot = (dec_flags, input_chunk)
            if len(self._decoded_chars) < chars_to_skip:
                raise OSError("can't restore logical file position")
            self._decoded_chars_used = chars_to_skip

        _reset_encoder(cookie)
        return cookie

    def read(self, size=None):
        self._checkClosed()
        self._checkReadable()
        size = _size_or_none(size)
        if size is None:
            size = -1
        decoder = self._decoder or self._get_decoder()
        if size < 0:
            result = (self._get_decoded_chars()
                      + decoder.decode(self.buffer.read(), final=True))
            self._set_decoded_chars("")
            self._snapshot = None
            return result
        eof = False
        result = self._get_decoded_chars(size)
        while len(result) < size and not eof:
            eof = not self._read_chunk()
            result += self._get_decoded_chars(size - len(result))
        return result

    def __next__(self):
        self._telling = False
        line = self.readline()
        if not line:
            self._snapshot = None
            self._telling = self._seekable
            raise StopIteration
        return line

    def readline(self, size=None):
        if self.closed:
            raise ValueError("read from closed file")
        if size is not None:
            size = _ssize(size)
        if size is None:
            size = -1
        line = self._get_decoded_chars()
        start = 0
        if not self._decoder:
            self._get_decoder()
        pos = endpos = None
        while True:
            if self._readtranslate:
                # The decoder has already turned every ending into "\n".
                pos = line.find("\n", start)
                if pos >= 0:
                    endpos = pos + 1
                    break
                start = len(line)
            elif self._readuniversal:
                # Untranslated: a lone "\r" at the end of what is decoded so
                # far might be half of a "\r\n", so wait for more.
                nlpos = line.find("\n", start)
                crpos = line.find("\r", start)
                if crpos == -1:
                    if nlpos == -1:
                        start = len(line)
                    else:
                        endpos = nlpos + 1
                        break
                elif nlpos == -1:
                    if crpos == len(line) - 1:
                        start = len(line)
                    else:
                        endpos = crpos + 1
                        break
                elif nlpos < crpos:
                    endpos = nlpos + 1
                    break
                elif nlpos == crpos + 1:
                    endpos = crpos + 2
                    break
                else:
                    endpos = crpos + 1
                    break
            else:
                pos = line.find(self._readnl, start)
                if pos >= 0:
                    endpos = pos + len(self._readnl)
                    break
                start = max(0, len(line) - len(self._readnl) + 1)

            while self._read_chunk():
                if self._decoded_chars:
                    break
            if self._decoded_chars:
                line += self._get_decoded_chars()
            else:
                self._set_decoded_chars("")
                self._snapshot = None
                return line

        if size >= 0 and endpos > size:
            endpos = size

        self._rewind_decoded_chars(len(line) - endpos)
        return line[:endpos]

    @property
    def newlines(self):
        return self._decoder.newlines if self._decoder else None

    def detach(self):
        if self.buffer is None:
            raise ValueError("buffer is already detached")
        self.flush()
        buffer = self._buffer
        self._buffer = None
        return buffer

    def truncate(self, pos=None):
        self.flush()
        return self.buffer.truncate(pos)

    def reconfigure(self, *, encoding=None, errors=None, newline=Ellipsis,
                    line_buffering=None, write_through=None):
        if self._decoder is not None and (encoding is not None
                                          or errors is not None
                                          or newline is not Ellipsis):
            raise UnsupportedOperation(
                "It is not possible to set the encoding or newline of "
                "stream after the first read")
        if errors is None:
            errors = self._errors if encoding is None else "strict"
        if encoding is None:
            encoding = self._encoding
        if newline is Ellipsis:
            newline = self._readnl
        if line_buffering is None:
            line_buffering = self.line_buffering
        if write_through is None:
            write_through = self.write_through
        self.flush()
        self._configure(encoding, errors, newline, line_buffering,
                        write_through)


class StringIO(TextIOWrapper):
    """A text stream over memory, which is a TextIOWrapper over a BytesIO.

    CPython implements it that way too, and the consequence is worth knowing:
    the position a tell() returns counts encoded bytes, not characters.
    """

    def __init__(self, initial_value="", newline="\n"):
        super().__init__(BytesIO(), encoding="utf-8",
                         errors="surrogatepass", newline=newline)
        if newline is None:
            self._writetranslate = False
        if initial_value is not None:
            if not isinstance(initial_value, str):
                raise TypeError("initial_value must be str or None, not %s"
                                % type(initial_value).__name__)
            self.write(initial_value)
            self.seek(0)

    def write(self, s):
        if not isinstance(s, str):
            raise TypeError("string argument expected, got %r"
                            % type(s).__name__)
        return super().write(s)

    def _checkClosed(self, msg=None):
        # The C StringIO leaves the full stop off, and the message is what a
        # caller sees.
        if self.closed:
            raise ValueError("I/O operation on closed file"
                             if msg is None else msg)

    def read(self, size=None):
        self._checkClosed()
        return super().read(size)

    def readline(self, size=None):
        self._checkClosed()
        return super().readline(size)

    def getvalue(self):
        self._checkClosed()
        self.flush()
        decoder = self._decoder or self._get_decoder()
        old_state = decoder.getstate()
        decoder.reset()
        try:
            return decoder.decode(self.buffer.getvalue(), final=True)
        finally:
            decoder.setstate(old_state)

    def __repr__(self):
        return object.__repr__(self)

    @property
    def errors(self):
        return None

    @property
    def encoding(self):
        return None

    def detach(self):
        self._unsupported("detach")


# --- open -----------------------------------------------------------------

def open(file, mode="r", buffering=-1, encoding=None, errors=None,
         newline=None, closefd=True, opener=None):
    """Open a file and return a stream.

    The stack is assembled from the bottom: a FileIO, then a buffer chosen by
    which of reading and writing was asked for, then -- unless the mode says
    binary -- a TextIOWrapper.  Every layer owns the one below it, so closing
    the top closes all of them.
    """
    if not isinstance(file, int):
        # Anything os.fspath() takes, which is what CPython's open() takes:
        # a str, a bytes, or an object with __fspath__.  The dunder is looked
        # up on the TYPE, as the protocol says -- an instance attribute named
        # __fspath__ is not a path.  os is not importable from here (it is
        # what imports this), so the lookup is done by hand.
        fspath = getattr(type(file), "__fspath__", None)
        if fspath is not None:
            file = fspath(file)
            if not isinstance(file, (str, bytes)):
                raise TypeError("expected __fspath__() to return str or bytes")
        if isinstance(file, bytes):
            file = file.decode()
        if not isinstance(file, str):
            # CPython names the kinds it takes rather than showing the value:
            # "expected str, bytes or os.PathLike object, not float".  The old
            # wording here was _pyio's, and _pyio is not what `open` is.
            raise TypeError(
                "expected str, bytes or os.PathLike object, not %s"
                % type(file).__name__)
    if not isinstance(mode, str):
        raise TypeError("open() argument 'mode' must be str, not %s"
                        % type(mode).__name__)
    if not isinstance(buffering, int):
        raise TypeError("invalid buffering: %r" % buffering)
    if encoding is not None and not isinstance(encoding, str):
        raise TypeError("invalid encoding: %r" % encoding)
    if errors is not None and not isinstance(errors, str):
        raise TypeError("invalid errors: %r" % errors)

    modes = set(mode)
    if modes - set("axrwb+t") or len(mode) > len(modes):
        raise ValueError("invalid mode: %r" % mode)

    creating = "x" in modes
    reading = "r" in modes
    writing = "w" in modes
    appending = "a" in modes
    updating = "+" in modes
    text = "t" in modes
    binary = "b" in modes
    if text and binary:
        raise ValueError("can't have text and binary mode at once")
    if creating + reading + writing + appending > 1:
        raise ValueError("must have exactly one of create/read/write/append "
                         "mode")
    if not (creating or reading or writing or appending):
        raise ValueError("Must have exactly one of create/read/write/append "
                         "mode and at most one plus")
    if binary and encoding is not None:
        raise ValueError("binary mode doesn't take an encoding argument")
    if binary and errors is not None:
        raise ValueError("binary mode doesn't take an errors argument")
    if binary and newline is not None:
        raise ValueError("binary mode doesn't take a newline argument")
    if binary and buffering == 1:
        # Line buffering is a text idea; a binary stream would have to look
        # for newlines in the bytes to honour it.  CPython warns and carries
        # on rather than refusing, so the call still returns a stream.
        import warnings
        warnings.warn("line buffering (buffering=1) isn't supported in "
                      "binary mode, the default buffer size will be used",
                      RuntimeWarning, 2)

    raw_mode = ((creating and "x" or "")
                + (reading and "r" or "")
                + (writing and "w" or "")
                + (appending and "a" or "")
                + (updating and "+" or ""))

    if opener is None:
        raw = FileIO(file, raw_mode, closefd)
    else:
        # An opener is handed the path and the flags open() would have used,
        # and returns the descriptor to wrap.  CPython threads this through
        # FileIO itself; here it is done in the layer above, because the
        # callable is Python and _iocore is not.  Doing it at all matters:
        # tempfile.NamedTemporaryFile passes the DIRECTORY as `file` and an
        # opener that ignores it and returns a descriptor from mkstemp, so an
        # ignored opener opened the directory and raised IsADirectoryError.
        import posix
        if creating:
            flags = posix.O_CREAT | posix.O_EXCL | posix.O_WRONLY
        elif writing:
            flags = posix.O_CREAT | posix.O_TRUNC | posix.O_WRONLY
        elif appending:
            flags = posix.O_CREAT | posix.O_APPEND | posix.O_WRONLY
        else:
            flags = posix.O_RDONLY
        if updating:
            flags = (flags & ~(posix.O_RDONLY | posix.O_WRONLY)) | posix.O_RDWR
        fd = opener(file, flags)
        if not isinstance(fd, int):
            raise TypeError("expected integer from opener")
        raw = FileIO(fd, raw_mode, closefd)
        # The name is what the caller asked for, not what the opener opened:
        # CPython reports the argument, and tempfile overwrites it afterwards
        # with the real path anyway.
        raw.name = file

    result = raw
    try:
        line_buffering = False
        if buffering == 1 or (buffering < 0 and raw.isatty()):
            buffering = -1
            line_buffering = True
        if buffering < 0:
            buffering = DEFAULT_BUFFER_SIZE
        if buffering == 0:
            if binary:
                return result
            raise ValueError("can't have unbuffered text I/O")

        if updating:
            buffer = BufferedRandom(raw, buffering)
        elif creating or writing or appending:
            buffer = BufferedWriter(raw, buffering)
        elif reading:
            buffer = BufferedReader(raw, buffering)
        else:
            raise ValueError("unknown mode: %r" % mode)
        result = buffer
        if binary:
            return result

        encoding = text_encoding(encoding)
        if encoding == "locale":
            # There is no locale module here and no LANG to consult; UTF-8 is
            # what the interpreter itself encodes in, and reporting the name
            # rather than the placeholder is what f.encoding is for.
            encoding = "UTF-8"
        text = TextIOWrapper(buffer, encoding, errors, newline,
                             line_buffering)
        result = text
        text.mode = mode
        return result
    except BaseException:
        result.close()
        raise


def open_code(path):
    """What the import system uses; a hook in CPython, plain here."""
    return open(path, "rb")
