"""Mainland Chinese multibyte codecs."""

from _multibytecodec import _getcodec


def getcodec(name, /):
    return _getcodec(name, ('gb2312', 'gbk', 'gb18030', 'hz'))
