"""Generate portable CJK maps with CPython 3.12.9 as the mapping oracle.

Run with a build of the local CPython v3.12.9 checkout. Its codec tables
and algorithms live in Modules/cjkcodecs. See lib/_cjk_data/README.md.
"""

import argparse
import marshal
from pathlib import Path
import sys
import zlib


STATELESS = (
    "gb2312", "gbk", "gb18030", "big5", "big5hkscs", "cp950",
    "cp932", "shift_jis", "shift_jis_2004", "shift_jisx0213",
    "euc_jp", "euc_jis_2004", "euc_jisx0213", "euc_kr", "cp949", "johab",
)
ISO_MARKS = {
    "iso2022_kr": b"\xc3",
    "iso2022_jp": b"\xc2J\xc0",
    "iso2022_jp_1": b"\xc2\xc4J\xc0",
    "iso2022_jp_2": b"\xc2\xc4\xc3\xc1J\xc0AF",
    "iso2022_jp_2004": b"\xc2\xd1\xd0",
    "iso2022_jp_3": b"\xc2\xcf\xd0",
    "iso2022_jp_ext": b"\xc2\xc4JI\xc0",
}


def iso_prefix(mark, korean):
    if korean:
        return b"\x1b$)C\x0e"
    if mark & 0x80:
        return b"\x1b$(" + bytes([mark & 0x7f])
    if mark in b"AF":
        return b"\x1b." + bytes([mark]) + b"\x1bN"
    return b"\x1b(" + bytes([mark])


def iso_maps(name):
    korean = name == "iso2022_kr"
    decode = {}
    for mark in ISO_MARKS[name]:
        prefix = iso_prefix(mark, korean)
        mapping = {}
        for first in range(0x20 if mark not in b"AF" else 0, 0x80):
            units = ((first, second) for second in range(256)) if mark & 0x80 else ((first,),)
            for unit in units:
                data = bytes(unit)
                text = decode_unit(prefix + data, name)
                if text is not None:
                    mapping[int.from_bytes(data, "big")] = text
        decode[mark] = mapping

    def encoded_unit(text):
        try:
            data = text.encode(name)
        except UnicodeEncodeError:
            return None
        if korean:
            assert data.startswith(b"\x1b$)C\x0e") and data.endswith(b"\x0f")
            return 0xc3, data[5:-1]
        assert data.endswith(b"\x1b(B")
        if data.startswith(b"\x1b$("):
            return data[3] | 0x80, data[4:-3]
        if data.startswith(b"\x1b$"):
            return data[2] | 0x80, data[3:-3]
        assert data.startswith(b"\x1b(")
        return data[2], data[3:-3]

    encode = {}
    for point in range(0x80, 0x30000):
        unit = encoded_unit(chr(point))
        if unit is not None:
            encode[point] = unit
    pairs = {}
    values = {value for mapping in decode.values()
              for value in mapping.values() if len(value) == 2}
    for value in sorted(values):
        unit = encoded_unit(value)
        if unit is not None:
            mark, data = unit
            if decode.get(mark, {}).get(int.from_bytes(data, "big")) == value:
                pairs[value] = unit
    return encode, decode, pairs


def decode_unit(data, name):
    try:
        return data.decode(name)
    except UnicodeDecodeError:
        return None


def legacy_maps(name):
    decode = {}
    early = []
    wide_errors = {}
    for lead in range(256):
        first = bytes([lead])
        try:
            single = first.decode(name)
        except UnicodeDecodeError as error:
            if error.reason == "illegal multibyte sequence":
                early.append(lead)
                continue
        else:
            decode[lead] = single
            continue
        if lead == 0x8f and name in ("euc_jp", "euc_jis_2004", "euc_jisx0213"):
            tails = (bytes((a, b)) for a in range(256) for b in range(256))
        else:
            tails = (bytes([trail]) for trail in range(256))
        for tail in tails:
            unit = first + tail
            key = int.from_bytes(unit, "big")
            try:
                decode[key] = unit.decode(name)
            except UnicodeDecodeError as error:
                if error.reason == "illegal multibyte sequence" and error.end > 1:
                    wide_errors[key] = error.end

    encode = {}
    special = {}
    for point in range(0x110000 if "jis" in name or name == "big5hkscs" else 0x10000):
        try:
            data = chr(point).encode(name)
        except UnicodeEncodeError:
            continue
        if name == "gb18030" and len(data) == 4:
            continue
        if name == "euc_kr" and len(data) == 8:
            special[data] = chr(point)
        encode[point] = data

    pairs = {}
    for value in sorted({value for value in decode.values() if len(value) == 2}):
        try:
            unit = value.encode(name)
        except UnicodeEncodeError:
            continue
        if decode.get(int.from_bytes(unit, "big")) == value:
            pairs[value] = unit

    ranges = []
    if name == "gb18030":
        for index in range(39420):
            prefix, last = divmod(index, 10)
            prefix, third = divmod(prefix, 126)
            first, second = divmod(prefix, 10)
            unit = bytes((first + 0x81, second + 0x30, third + 0x81, last + 0x30))
            point = ord(unit.decode(name))
            if not ranges or point - index != ranges[-1][2] - ranges[-1][0]:
                ranges.append([index, index + 1, point])
            else:
                ranges[-1][1] = index + 1
    return encode, decode, pairs, special, ranges, early, wide_errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("names", nargs="*")
    parser.add_argument("--output", type=Path, default=Path("lib/_cjk_data"))
    args = parser.parse_args()
    if sys.implementation.name != "cpython" or sys.version_info[:3] != (3, 12, 9):
        parser.error("generate checked-in data with CPython 3.12.9")
    names = args.names or (*STATELESS, *ISO_MARKS)
    for name in names:
        if name in STATELESS:
            tables = legacy_maps(name)
        elif name in ISO_MARKS:
            tables = iso_maps(name)
        else:
            parser.error("unsupported codec " + name)
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / (name + ".map")).write_bytes(zlib.compress(marshal.dumps(tables, 2), 9))


if __name__ == "__main__":
    main()
