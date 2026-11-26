"""POSIX shared-memory names and descriptors for multiprocessing."""

from operator import index as _index

import _posixshmemcore as _core


def shm_open(path, flags, mode=0o777):
    """Open a POSIX shared-memory object and return its file descriptor."""
    str.encode(path, "utf-8")
    return _core.shm_open(path, _index(flags), _index(mode))


def shm_unlink(path):
    """Remove a POSIX shared-memory name."""
    str.encode(path, "utf-8")
    return _core.shm_unlink(path)
