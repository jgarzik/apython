"""Traditional Chinese multibyte codecs."""

from _multibytecodec import _getcodec


def getcodec(name, /):
    return _getcodec(name, ('big5', 'cp950'))
