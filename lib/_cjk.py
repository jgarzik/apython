"""Mapping and conversion primitives used by the CJK codec modules."""

from bisect import bisect_right
import marshal
import os
import zlib


class Legacy:
    def __init__(self, name):
        self.name = name
        path = os.path.join(os.path.dirname(__file__), "_cjk_data", name + ".map")
        with open(path, "rb") as data:
            tables = marshal.loads(zlib.decompress(data.read()))
        self.enc, self.dec, self.pairs, self.makeup, self.ranges = tables
        self.pending = {pair[0] for pair in self.pairs}
        self.third = name in ("euc_jp", "euc_jis_2004", "euc_jisx0213")
        self.range_indexes = [entry[0] for entry in self.ranges]
        self.range_points = [entry[2] for entry in self.ranges]

    def initial(self):
        return 0

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
        if width == 8:
            char = self.makeup.get(data[i:i + 8])
        elif width == 4:
            char = self.gb_decode(data[i:i + 4])
        else:
            key = (lead << 8) | tail
            if width == 3:
                key = (key << 8) | data[i + 2]
            char = self.dec.get(key)
        return char, (width if char is not None else 1), state

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
