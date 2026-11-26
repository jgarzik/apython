"""Incremental and streaming support for the CJK codecs in encodings."""

from operator import index


_ILLEGAL = "illegal multibyte sequence"
_INCOMPLETE = "incomplete multibyte sequence"


def _text(value):
    if not isinstance(value, str):
        raise TypeError("expected str, not " + type(value).__name__)
    return value


def _bytes(value):
    if isinstance(value, bytes):
        return value
    try:
        view = memoryview(value)
    except TypeError:
        raise TypeError("a bytes-like object is required, not '%s'"
                        % type(value).__name__) from None
    if not view.c_contiguous:
        raise BufferError("memoryview: underlying buffer is not C-contiguous")
    return view.tobytes()


def _error_name(name):
    if not isinstance(name, str):
        raise TypeError("errors must be a string")
    if "\0" in name:
        raise ValueError("embedded null character")
    return name


def _handler(errors, exc, length, replacement_types):
    from codecs import lookup_error

    result = lookup_error(errors)(exc)
    if (not isinstance(result, tuple) or len(result) != 2 or
            not isinstance(result[0], replacement_types) or not isinstance(result[1], int)):
        kind = "encoding" if isinstance(exc, UnicodeEncodeError) else "decoding"
        raise TypeError(kind + " error handler must return (str, int) tuple")
    replacement, position = result
    if position < 0:
        position += length
    if not 0 <= position <= length:
        raise IndexError("position %d from error handler out of bounds" % position)
    return replacement, position


class _Codec:
    def __init__(self, name):
        self.name = name
        self._impl = None

    @property
    def impl(self):
        if self._impl is None:
            from _cjk import HZ, ISO2022, Legacy
            if self.name == "hz":
                self._impl = HZ()
            elif self.name.startswith("iso2022_"):
                self._impl = ISO2022(self.name)
            else:
                self._impl = Legacy(self.name)
        return self._impl

    def encode(self, text, errors="strict", /):
        if not isinstance(text, str):
            text = str(text)
        output, count, _ = self.encode_run(text, _error_name(errors), self.impl.initial(), True)
        return output, count

    def decode(self, data, errors="strict", /):
        data = _bytes(data)
        output, count, _ = self.decode_run(data, _error_name(errors), self.impl.initial_decode(), True)
        return output, count

    def encode_run(self, text, errors, state, final, reset=True):
        impl = self.impl
        out = bytearray()
        i = 0
        size = len(text)
        while i < size:
            chunk, count, state = impl.encode_step(text, i, state, final)
            if chunk is not None:
                out.extend(chunk)
                i += count
                continue
            if count == 0 and not final:
                break
            exc = UnicodeEncodeError(self.name, text, i, i + (count or size - i),
                                     _ILLEGAL if count else _INCOMPLETE)
            if errors == "replace":
                chunk, _, state = impl.encode_step("?", 0, state, False)
                out.extend(chunk if chunk is not None else b"?")
                i = exc.end
            else:
                replacement, i = _handler(errors, exc, size, (str, bytes))
                if isinstance(replacement, str) and replacement:
                    replacement, _, state = self.encode_run(replacement, "strict", state, True, False)
                if replacement:
                    out.extend(replacement)
        if final and reset:
            tail, state = impl.finish(state)
            out.extend(tail)
        return bytes(out), i, state

    def decode_run(self, data, errors, state, final):
        impl = self.impl
        out = []
        i = 0
        size = len(data)
        while i < size:
            chunk, count, state = impl.decode_step(data, i, state)
            if chunk is not None:
                out.append(chunk)
                i += count
                continue
            if count == 0 and not final:
                break
            exc = UnicodeDecodeError(self.name, data, i, i + (count or size - i),
                                     _ILLEGAL if count else _INCOMPLETE)
            replacement, i = _handler(errors, exc, size, str)
            out.append(replacement)
        return "".join(out), i, state


def _getcodec(name, names):
    name = _text(name)
    if name not in names:
        raise LookupError("no such codec is supported.")
    return _Codec(name)


def __create_codec(capsule, /):
    raise ValueError("argument type invalid")


class _Stateful:
    def __init__(self, errors="strict"):
        codec = getattr(self, "codec", None)
        if not isinstance(codec, _Codec):
            raise AttributeError("codec is not defined")
        self.errors = errors
        self.reset()

    @property
    def errors(self):
        return self._errors

    @errors.setter
    def errors(self, value):
        self._errors = _error_name(value)

    def reset(self):
        self._pending = self._empty
        self._state = self.codec.impl.initial()


class MultibyteIncrementalEncoder(_Stateful):
    _empty = ""

    def encode(self, input, final=False):
        if not isinstance(input, str):
            input = str(input)
        data = self._pending + input
        out, consumed, state = self.codec.encode_run(data, self.errors, self._state, final)
        self._state = state
        self._pending = data[consumed:]
        return out

    def getstate(self):
        pending = self._pending.encode("utf-8")
        return int.from_bytes(bytes([len(pending)]) + pending + self._state.to_bytes(8, "little"),
                              "little")

    def setstate(self, state):
        data = index(state).to_bytes(17, "little")
        n = data[0]
        if n > 8:
            raise UnicodeError("pending buffer too large")
        pending = data[1:1 + n].decode("utf-8")
        self._pending = pending
        self._state = int.from_bytes(data[1 + n:9 + n], "little")


class MultibyteIncrementalDecoder(_Stateful):
    _empty = b""

    def reset(self):
        self._pending = b""
        impl = self.codec.impl
        if hasattr(self, "_state"):
            self._state = impl.reset_decode(self._state)
        else:
            self._state = impl.initial_decode()

    def decode(self, input, final=False):
        data = self._pending + _bytes(input)
        out, consumed, state = self.codec.decode_run(data, self.errors, self._state, final)
        self._state = state
        self._pending = data[consumed:]
        return out

    def getstate(self):
        return self._pending, self._state

    def setstate(self, state):
        if (not isinstance(state, tuple) or len(state) != 2 or
                not isinstance(state[0], bytes) or not isinstance(state[1], int)):
            raise TypeError("setstate(): illegal state argument")
        pending, flags = state
        if len(pending) > 8:
            raise UnicodeError("pending buffer too large")
        flags.to_bytes(8, "little")
        self._state = flags
        self._pending = pending


class MultibyteStreamReader(MultibyteIncrementalDecoder):
    def __init__(self, stream, errors="strict"):
        self.stream = stream
        _Stateful.__init__(self, errors)

    def _read(self, method, size):
        size = -1 if size is None else index(size)
        if size == 0:
            return ""
        read = getattr(self.stream, method)
        while True:
            data = read() if size < 0 else read(size)
            if not isinstance(data, bytes):
                raise TypeError("stream function returned a non-bytes object (%s)"
                                % type(data).__name__)
            text = MultibyteIncrementalDecoder.decode(self, data, size < 0 or not data)
            if text or size < 0 or not data:
                return text
            size = 1

    def read(self, size=-1):
        return self._read("read", size)

    def readline(self, size=-1):
        return self._read("readline", size)

    def readlines(self, sizehint=-1):
        return self.read(sizehint).splitlines(True)


class MultibyteStreamWriter(MultibyteIncrementalEncoder):
    def __init__(self, stream, errors="strict"):
        self.stream = stream
        _Stateful.__init__(self, errors)

    def write(self, data):
        self.stream.write(MultibyteIncrementalEncoder.encode(self, data))

    def writelines(self, data):
        for line in data:
            self.write(line)

    def reset(self):
        if getattr(self, "_pending", ""):
            try:
                out = MultibyteIncrementalEncoder.encode(self, "", True)
                if out:
                    self.stream.write(out)
            finally:
                _Stateful.reset(self)
        elif not hasattr(self, "_state"):
            _Stateful.reset(self)
