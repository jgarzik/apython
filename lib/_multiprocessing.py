"""Linux named semaphores for CPython's multiprocessing package.

The native half owns each sem_open reference, tracks the lock owner, and
releases the GIL while waiting.
"""

from operator import index as _index
from os import O_CREAT as _O_CREAT, O_EXCL as _O_EXCL

import _multiprocessingcore as _core


_RECURSIVE_MUTEX = 0
_SEMAPHORE = 1
_NS_PER_SECOND = 10 ** 9
_TIMEOUT_MAX = (2 ** 63 - 1) // _NS_PER_SECOND


def _c_int(value):
    value = _index(value)
    if not -(2 ** 31) <= value < 2 ** 31:
        raise OverflowError("Python int too large to convert to C int")
    return value


def sem_unlink(name, /):
    """Remove the name of an existing semaphore."""
    str.encode(name, "utf-8")
    return _core.unlink(name)


class SemLock:
    """A counting semaphore or recursive mutex shared between processes."""

    SEM_VALUE_MAX = 2 ** 31 - 1
    __slots__ = ("_ref", "_kind", "_maxvalue", "_name")

    def __init__(self, kind, value, maxvalue, name, unlink):
        kind = _c_int(kind)
        value = _c_int(value)
        maxvalue = _c_int(maxvalue)
        str.encode(name, "utf-8")
        unlink = bool(unlink)
        if kind not in (_RECURSIVE_MUTEX, _SEMAPHORE):
            raise ValueError("unrecognized kind")
        ref = _core.open(name, _O_CREAT | _O_EXCL, value, kind)
        if unlink:
            _core.unlink(name)
            name = None
        self._init(ref, kind, maxvalue, name)

    def _init(self, ref, kind, maxvalue, name):
        self._ref = ref
        self._kind = kind
        self._maxvalue = maxvalue
        self._name = name

    @property
    def handle(self):
        return _core.handle(self._ref)

    @property
    def kind(self):
        return self._kind

    @property
    def maxvalue(self):
        return self._maxvalue

    @property
    def name(self):
        return self._name

    def acquire(self, block=True, timeout=None):
        block = bool(block)
        if self._kind == _RECURSIVE_MUTEX and self._is_mine():
            return _core.wait(self._ref, 0)
        timeout_ns = -1
        if timeout is not None:
            if isinstance(timeout, (str, bytes, bytearray)):
                raise TypeError("timeout must be a real number")
            timeout = float(timeout)
            if timeout > _TIMEOUT_MAX:
                raise OverflowError("timeout is too large")
            timeout_ns = int(max(timeout, 0.0) * _NS_PER_SECOND + 0.5)
        return _core.wait(self._ref, timeout_ns if block else 0)

    def release(self):
        _core.release(self._ref, self._maxvalue)

    def __enter__(self):
        return self.acquire()

    def __exit__(self, exc_type, exc_value, traceback):
        self.release()

    def _count(self):
        return _core.count(self._ref)

    def _is_mine(self):
        return _core.owned(self._ref)

    def _get_value(self):
        return _core.value(self._ref)

    def _is_zero(self):
        return self._get_value() == 0

    def _after_fork(self):
        _core.reset(self._ref)

    @classmethod
    def _rebuild(cls, handle, kind, maxvalue, name, /):
        _index(handle)
        kind = _c_int(kind)
        maxvalue = _c_int(maxvalue)
        if name is None:
            raise ValueError("a semaphore name is required to reopen a handle")
        str.encode(name, "utf-8")
        obj = object.__new__(cls)
        obj._init(_core.open(name, 0, 0, kind), kind, maxvalue, name)
        return obj
