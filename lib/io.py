# io.py - Core I/O module (minimal for apython)


class StringIO:
    """Text I/O implementation using an in-memory buffer."""

    def __init__(self, initial_value=''):
        self._buf = initial_value
        self._pos = 0

    def read(self, size=-1):
        if size < 0:
            result = self._buf[self._pos:]
            self._pos = len(self._buf)
        else:
            result = self._buf[self._pos:self._pos + size]
            self._pos += len(result)
        return result

    def readline(self, size=-1):
        buf = self._buf
        pos = self._pos
        idx = buf.find('\n', pos)
        if idx < 0:
            end = len(buf)
        else:
            end = idx + 1
        if size >= 0:
            end = min(end, pos + size)
        result = buf[pos:end]
        self._pos = end
        return result

    def readlines(self, hint=-1):
        lines = []
        total = 0
        while True:
            line = self.readline()
            if not line:
                break
            lines.append(line)
            total += len(line)
            if 0 < hint <= total:
                break
        return lines

    def write(self, s):
        if not isinstance(s, str):
            raise TypeError("string argument expected, got %r" % type(s).__name__)
        pos = self._pos
        buf = self._buf
        if pos == len(buf):
            self._buf = buf + s
        else:
            self._buf = buf[:pos] + s + buf[pos + len(s):]
        self._pos = pos + len(s)
        return len(s)

    def writelines(self, lines):
        for line in lines:
            self.write(line)

    def getvalue(self):
        return self._buf

    def tell(self):
        return self._pos

    def seek(self, pos, whence=0):
        if whence == 0:
            self._pos = max(0, pos)
        elif whence == 1:
            self._pos = max(0, self._pos + pos)
        elif whence == 2:
            self._pos = max(0, len(self._buf) + pos)
        return self._pos

    def truncate(self, size=None):
        if size is None:
            size = self._pos
        self._buf = self._buf[:size]
        return size

    def close(self):
        pass

    def closed(self):
        return False

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def __iter__(self):
        return self

    def __next__(self):
        line = self.readline()
        if not line:
            raise StopIteration
        return line


class BytesIO:
    """Binary I/O implementation using an in-memory bytes buffer."""

    def __init__(self, initial_bytes=b''):
        if isinstance(initial_bytes, (bytes, bytearray)):
            self._buf = bytearray(initial_bytes)
        else:
            self._buf = bytearray()
        self._pos = 0

    def read(self, size=-1):
        if size < 0:
            result = bytes(self._buf[self._pos:])
            self._pos = len(self._buf)
        else:
            result = bytes(self._buf[self._pos:self._pos + size])
            self._pos += len(result)
        return result

    def write(self, b):
        if isinstance(b, (bytes, bytearray)):
            n = len(b)
            pos = self._pos
            buf = self._buf
            end = pos + n
            if end > len(buf):
                buf += bytearray(end - len(buf))
            buf[pos:end] = b
            self._buf = buf
            self._pos = end
            return n
        raise TypeError("a bytes-like object is required")

    def getvalue(self):
        return bytes(self._buf)

    def tell(self):
        return self._pos

    def seek(self, pos, whence=0):
        if whence == 0:
            self._pos = max(0, pos)
        elif whence == 1:
            self._pos = max(0, self._pos + pos)
        elif whence == 2:
            self._pos = max(0, len(self._buf) + pos)
        return self._pos

    def truncate(self, size=None):
        if size is None:
            size = self._pos
        self._buf = self._buf[:size]
        return size

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


# TextIOBase and similar are stubs for compatibility
class IOBase:
    pass

class RawIOBase(IOBase):
    pass

class BufferedIOBase(IOBase):
    pass

class TextIOBase(IOBase):
    pass

# Constants
DEFAULT_BUFFER_SIZE = 8192
