"""The `_ctypes_test` module CPython's ctypes tests load.

CPython's is an extension module whose C functions the tests call through
ctypes: every use is `CDLL(_ctypes_test.__file__)`.  So what matters is that
`__file__` names a shared library holding those functions.  The Makefile
builds Modules/_ctypes/_ctypes_test.c, unmodified, into
build/_ctypes_test.so; this module is only the name that points at it.
"""

import os as _os

__file__ = _os.path.join(
    _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))),
    "build", "_ctypes_test.so")

if not _os.path.exists(__file__):
    raise ImportError("_ctypes_test: %s was not built" % __file__)


def func():
    return None


def func_si(s, i):
    if not isinstance(s, str) or not isinstance(i, int):
        raise TypeError("func_si() argument types")
    return None
