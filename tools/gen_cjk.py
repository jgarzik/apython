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


def decode_unit(data, name):
    try:
        return data.decode(name)
    except UnicodeDecodeError:
        return None


def legacy_maps(name):
    decode = {}
    for lead in range(256):
        first = bytes([lead])
        single = decode_unit(first, name)
        if single is not None:
            decode[lead] = single
            continue
        if lead == 0x8f and name in ("euc_jp", "euc_jis_2004", "euc_jisx0213"):
            tails = (bytes((a, b)) for a in range(256) for b in range(256))
        else:
            tails = (bytes([trail]) for trail in range(256))
        for tail in tails:
            unit = first + tail
            result = decode_unit(unit, name)
            if result is not None:
                decode[int.from_bytes(unit, "big")] = result

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
    return encode, decode, pairs, special, ranges


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("names", nargs="*")
    parser.add_argument("--output", type=Path, default=Path("lib/_cjk_data"))
    args = parser.parse_args()
    if sys.implementation.name != "cpython" or sys.version_info[:3] != (3, 12, 9):
        parser.error("generate checked-in data with CPython 3.12.9")
    names = args.names or STATELESS
    for name in names:
        if name not in STATELESS:
            parser.error("unsupported codec " + name)
        tables = legacy_maps(name)
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / (name + ".map")).write_bytes(zlib.compress(marshal.dumps(tables, 2), 9))


if __name__ == "__main__":
    main()
