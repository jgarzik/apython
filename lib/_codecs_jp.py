"""Japanese multibyte codecs."""

from _multibytecodec import _getcodec


def getcodec(name, /):
    return _getcodec(name, ("cp932", "shift_jis", "shift_jis_2004",
                            "shift_jisx0213", "euc_jp", "euc_jis_2004",
                            "euc_jisx0213"))
