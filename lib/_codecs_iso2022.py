"""The ISO-2022 CJK encodings."""

from _multibytecodec import _getcodec


def getcodec(name, /):
    return _getcodec(name, ("iso2022_kr", "iso2022_jp", "iso2022_jp_1",
                            "iso2022_jp_2", "iso2022_jp_2004",
                            "iso2022_jp_3", "iso2022_jp_ext"))
