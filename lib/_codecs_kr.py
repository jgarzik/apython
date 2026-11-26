"""Korean multibyte codecs."""

from _multibytecodec import _getcodec


def getcodec(name, /):
    return _getcodec(name, ('euc_kr', 'cp949', 'johab'))
