"""Mapping and conversion primitives used by the CJK codec modules."""

from bisect import bisect_right
import marshal
import os
import zlib


def _load(name):
    path = os.path.join(os.path.dirname(__file__), "_cjk_data", name + ".map")
    with open(path, "rb") as data:
        return marshal.loads(zlib.decompress(data.read()))


class Legacy:
    def __init__(self, name):
        self.name = name
        (self.enc, self.dec, self.pairs, self.makeup, self.ranges,
         early, self.wide_errors) = _load(name)
        self.early = set(early)
        self.pending = {pair[0] for pair in self.pairs}
        self.third = name in ("euc_jp", "euc_jis_2004", "euc_jisx0213")
        self.range_indexes = [entry[0] for entry in self.ranges]
        self.range_points = [entry[2] for entry in self.ranges]

    def initial(self):
        return 0

    initial_decode = initial

    def reset_decode(self, state):
        return state

    def finish(self, state):
        return b"", 0

    def encode_step(self, text, i, state, final):
        ch = text[i]
        if ch in self.pending:
            if i + 1 == len(text) and not final:
                return None, 0, state
            data = self.pairs.get(text[i:i + 2])
            if data is not None:
                return data, 2, state
        point = ord(ch)
        data = self.enc.get(point)
        if data is None and self.ranges:
            data = self.gb_encode(point)
        return data, 1, state

    def decode_step(self, data, i, state):
        lead = data[i]
        char = self.dec.get(lead)
        if char is not None:
            return char, 1, state
        if lead in self.early:
            return None, 1, state
        remaining = len(data) - i
        if remaining < 2:
            return None, 0, state
        tail = data[i + 1]
        width = 2
        if self.third and lead == 0x8f:
            width = 3
        elif self.name == "gb18030" and 0x30 <= tail <= 0x39:
            width = 4
        elif self.makeup and lead == 0xa4 and tail == 0xd4:
            width = 8
        if remaining < width:
            return None, 0, state
        count = 1
        if width == 8:
            char = self.makeup.get(data[i:i + 8])
        elif width == 4:
            char = self.gb_decode(data[i:i + 4])
        else:
            key = (lead << 8) | tail
            if width == 3:
                key = (key << 8) | data[i + 2]
            char = self.dec.get(key)
            if char is None:
                count = self.wide_errors.get(key, 1)
        return char, (width if char is not None else count), state

    def gb_encode(self, point):
        if point >= 0x10000:
            index = point - 0x10000 + 189000
        else:
            row = bisect_right(self.range_points, point) - 1
            if row < 0:
                return None
            first, end, base = self.ranges[row]
            index = first + point - base
            if index >= end:
                return None
        index, last = divmod(index, 10)
        index, third = divmod(index, 126)
        first, second = divmod(index, 10)
        return bytes((first + 0x81, second + 0x30, third + 0x81, last + 0x30))

    def gb_decode(self, data):
        first, second, third, last = data
        if not (0x81 <= first <= 0xfe and 0x81 <= third <= 0xfe and 0x30 <= last <= 0x39):
            return None
        index = ((first - 0x81) * 10 + second - 0x30) * 1260
        index += (third - 0x81) * 10 + last - 0x30
        if index < 39420:
            row = bisect_right(self.range_indexes, index) - 1
            first, _, base = self.ranges[row]
            return chr(base + index - first)
        if 189000 <= index < 189000 + 0x100000:
            return chr(index - 189000 + 0x10000)
        return None


class HZ:
    def __init__(self):
        self.table = Legacy("gb2312")

    def initial(self):
        return 0

    initial_decode = initial

    def reset_decode(self, state):
        return state & ~0xff

    def finish(self, state):
        return (b"~}" if state else b""), 0

    def encode_step(self, text, i, state, final):
        point = ord(text[i])
        if point < 0x80:
            unit = b"~~" if point == 0x7e else bytes([point])
            return (b"~}" + unit if state else unit), 1, 0
        unit = self.table.enc.get(point)
        if unit is None:
            return None, 1, state
        unit = bytes([unit[0] & 0x7f, unit[1] & 0x7f])
        return (unit if state else b"~{" + unit), 1, 1

    def decode_step(self, data, i, state):
        lead = data[i]
        if lead == 0x7e:
            if len(data) - i < 2:
                return None, 0, state
            following = data[i + 1]
            if not state:
                if following == 0x7e:
                    return "~", 2, state
                if following == 0x7b:
                    return "", 2, 1
                if following == 10:
                    return "", 2, state
            elif following == 0x7d:
                return "", 2, 0
            return None, 1, state
        if lead >= 0x80:
            return None, 1, state
        if not state:
            return chr(lead), 1, state
        if len(data) - i < 2:
            return None, 0, state
        tail = data[i + 1]
        if tail >= 0x80:
            return None, 1, state
        char = self.table.dec.get(((lead | 0x80) << 8) | (tail | 0x80))
        return char, (2 if char is not None else 1), state


_ASCII = 0x42
_SHIFT = 1 << 32
_ESCAPE_THROUGH = 2 << 32


def _plane(state, number):
    return (state >> (number * 8)) & 0xff


def _designate(state, number, mark):
    shift = number * 8
    return (state & ~(0xff << shift)) | (mark << shift)


def _escape_end(byte):
    return 0x40 <= byte <= 0x5a


class ISO2022:
    def __init__(self, name):
        self.enc, self.dec, self.pairs = _load(name)
        self.pending = {pair[0] for pair in self.pairs}
        self.korean = name == "iso2022_kr"
        self.g2 = name == "iso2022_jp_2"

    def initial(self):
        return 0x4242

    def initial_decode(self):
        return 0x424242

    def reset_decode(self, state):
        return _designate(state & ~_SHIFT, 0, _ASCII)

    def finish(self, state):
        out = b""
        if state & _SHIFT:
            out = b"\x0f"
            state &= ~_SHIFT
        if _plane(state, 0) != _ASCII:
            out += b"\x1b(B"
            state = _designate(state, 0, _ASCII)
        return out, state

    def encode_step(self, text, i, state, final):
        point = ord(text[i])
        if point < 0x80:
            prefix, state = self.finish(state)
            return prefix + bytes([point]), 1, state

        unit = None
        width = 1
        if text[i] in self.pending:
            if len(text) - i < 2 and not final:
                return None, 0, state
            unit = self.pairs.get(text[i:i + 2])
            if unit is not None:
                width = 2
        if unit is None:
            unit = self.enc.get(point)
        if unit is None:
            return None, 1, state
        mark, payload = unit

        out = b""
        if self.korean:
            if _plane(state, 1) != mark:
                out = b"\x1b$)C"
                state = _designate(state, 1, mark)
            if not state & _SHIFT:
                out += b"\x0e"
                state |= _SHIFT
        else:
            if state & _SHIFT:
                out = b"\x0f"
                state &= ~_SHIFT
            if _plane(state, 0) != mark:
                if mark == 0xc2:
                    out += b"\x1b$B"
                elif mark & 0x80:
                    out += b"\x1b$(" + bytes([mark & 0x7f])
                else:
                    out += b"\x1b(" + bytes([mark])
                state = _designate(state, 0, mark)
        return out + payload, width, state

    def _escape(self, data, i, state):
        remaining = len(data) - i
        j = 1
        while j < 16:
            if j >= remaining:
                return None, 0, state
            if _escape_end(data[i + j]):
                break
            if (not self.korean and data[i + j] == 0x26 and
                    j + 1 < remaining and data[i + j + 1] == 0x40):
                j += 2
            j += 1
        if j >= 16:
            return None, 1, state

        unit = data[i:i + j + 1]
        n = len(unit)
        plane = 0
        mark = unit[-1]
        if n == 3:
            if unit[1] == 0x24:
                mark |= 0x80
            elif unit[1] == 0x29:
                plane = 1
            elif unit[1] == 0x2e and self.g2:
                plane = 2
            elif unit[1] != 0x28:
                return None, n, state
        elif n == 4 and unit[1:3] in (b"$(", b"$)"):
            plane = int(unit[2] == 0x29)
            mark |= 0x80
        elif n == 6 and not self.korean and unit[3:] == b"\x1b$B":
            mark = 0xc2
        else:
            return None, n, state
        if mark != _ASCII and mark not in self.dec:
            return None, n, state
        return "", n, _designate(state, plane, mark)

    def decode_step(self, data, i, state):
        lead = data[i]
        remaining = len(data) - i
        if state & _ESCAPE_THROUGH:
            if _escape_end(lead):
                state &= ~_ESCAPE_THROUGH
            return chr(lead), 1, state
        if lead == 0x1b:
            if remaining < 2:
                return None, 0, state
            if data[i + 1] in b"()$.&":
                return self._escape(data, i, state)
            if self.g2 and data[i + 1] == 0x4e:
                if remaining < 3:
                    return None, 0, state
                third = data[i + 2]
                mark = _plane(state, 2)
                if mark == _ASCII and third < 0x80:
                    return chr(third), 3, state
                char = self.dec.get(mark, {}).get(third)
                return char, 3, state
            return "\x1b", 1, state | _ESCAPE_THROUGH
        if lead == 0x0a:
            return "\n", 1, state & ~_SHIFT
        if self.korean and lead in (0x0e, 0x0f):
            return "", 1, (state | _SHIFT if lead == 0x0e else state & ~_SHIFT)
        if lead < 0x20:
            return chr(lead), 1, state
        if lead >= 0x80:
            return None, 1, state
        mark = _plane(state, int(bool(state & _SHIFT)))
        if mark == _ASCII:
            return chr(lead), 1, state
        width = 2 if mark & 0x80 else 1
        if remaining < width:
            return None, 0, state
        key = (lead << 8) | data[i + 1] if width == 2 else lead
        return self.dec.get(mark, {}).get(key), width, state
