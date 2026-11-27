"""select - waiting on descriptors, over poll().

CPython's select module wraps four different multiplexers; two of them are
here -- poll() and epoll() -- with select() written on top of poll.  Both are
_socketcore's syscalls with the registry, the timeouts and the object
lifetime in Python, which is the same split the socket type itself uses.

kqueue and devpoll are absent, and their absence is the supported way to say
so: selectors and asyncio both ask with hasattr.

Adding epoll changes what Lib/selectors.py's DefaultSelector picks --
EpollSelector rather than PollSelector -- because that file gates on
`hasattr(select, "epoll")`.  tests/test_async_backends.py runs the async
suite over both.
"""

import _socketcore as _c

POLLIN = _c.POLLIN
POLLPRI = _c.POLLPRI
POLLOUT = _c.POLLOUT
POLLERR = _c.POLLERR
POLLHUP = _c.POLLHUP
POLLNVAL = _c.POLLNVAL

EPOLLIN = _c.EPOLLIN
EPOLLPRI = _c.EPOLLPRI
EPOLLOUT = _c.EPOLLOUT
EPOLLERR = _c.EPOLLERR
EPOLLHUP = _c.EPOLLHUP
EPOLLRDHUP = _c.EPOLLRDHUP
EPOLLRDNORM = _c.EPOLLRDNORM
EPOLLRDBAND = _c.EPOLLRDBAND
EPOLLWRNORM = _c.EPOLLWRNORM
EPOLLWRBAND = _c.EPOLLWRBAND
EPOLLMSG = _c.EPOLLMSG
EPOLLEXCLUSIVE = _c.EPOLLEXCLUSIVE
EPOLLWAKEUP = _c.EPOLLWAKEUP
EPOLLONESHOT = _c.EPOLLONESHOT
EPOLLET = _c.EPOLLET
EPOLL_CLOEXEC = _c.EPOLL_CLOEXEC

error = OSError

__all__ = ["select", "poll", "error", "POLLIN", "POLLPRI", "POLLOUT",
           "POLLERR", "POLLHUP", "POLLNVAL"]


def _fileno(obj):
    """-> the descriptor, CPython's PyObject_AsFileDescriptor.

    A negative one is a ValueError there rather than an EBADF from the
    syscall, and the message names the number -- which is what a caller that
    passed a closed object's -1 needs to see.
    """
    if isinstance(obj, int):
        fd = obj
    else:
        fd = obj.fileno()
        if not isinstance(fd, int):
            raise TypeError("fileno() returned a non-integer")
    if fd < 0:
        raise ValueError(
            "file descriptor cannot be a negative integer (%d)" % (fd,))
    return fd


def select(rlist, wlist, xlist, timeout=None):
    """The BSD interface, answered by poll().

    Duplicates are not merged: one pollfd per entry keeps the answer in the
    order the caller gave, which is what the return value is indexed by.
    """
    entries = []
    flat = []
    for obj in rlist:
        entries.append((obj, 0))
        flat.append(_fileno(obj))
        flat.append(POLLIN)
    for obj in wlist:
        entries.append((obj, 1))
        flat.append(_fileno(obj))
        flat.append(POLLOUT)
    for obj in xlist:
        entries.append((obj, 2))
        flat.append(_fileno(obj))
        flat.append(POLLPRI)

    if timeout is None:
        ms = -1
    else:
        timeout = float(timeout)
        if timeout < 0:
            raise ValueError("timeout must be non-negative")
        v = timeout * 1000.0
        ms = int(v)
        if v > ms:
            ms += 1

    revents = _c.poll(flat, ms)
    out = ([], [], [])
    for i in range(len(entries)):
        obj, which = entries[i]
        got = revents[i]
        if which == 0:
            if got & (POLLIN | POLLHUP | POLLERR | POLLNVAL):
                out[0].append(obj)
        elif which == 1:
            if got & (POLLOUT | POLLERR | POLLNVAL):
                out[1].append(obj)
        else:
            if got & (POLLPRI | POLLNVAL):
                out[2].append(obj)
    return out


# CPython's select() is a C function, which is NOT a descriptor: storing it in
# a class body keeps the function, and `self._select(r, w, x, t)` passes four
# arguments.  Lib/selectors.py is written against exactly that --
# `_select = select.select` in SelectSelector's body -- and a PYTHON function
# there binds instead, so every call arrived one argument too long.  A
# staticmethod is the Python spelling of "callable, and not a descriptor that
# binds": subprocess.communicate() over the select backend could not run
# without it, and hung with the child's pipe still open.
select = staticmethod(select)


class poll:
    """The poll object: a registry of descriptors and the events wanted."""

    def __init__(self):
        self._fds = {}

    def register(self, fd, eventmask=None):
        if eventmask is None:
            eventmask = POLLIN | POLLPRI | POLLOUT
        self._fds[_fileno(fd)] = eventmask

    def modify(self, fd, eventmask):
        fd = _fileno(fd)
        if fd not in self._fds:
            raise OSError(2, "No such file or directory")
        self._fds[fd] = eventmask

    def unregister(self, fd):
        fd = _fileno(fd)
        if fd not in self._fds:
            raise KeyError(fd)
        del self._fds[fd]

    def poll(self, timeout=None):
        fds = list(self._fds.items())
        flat = []
        for fd, mask in fds:
            flat.append(fd)
            flat.append(mask)
        if timeout is None or timeout < 0:
            ms = -1
        else:
            v = float(timeout)
            ms = int(v)
            if v > ms:
                ms += 1
        revents = _c.poll(flat, ms)
        out = []
        for i in range(len(fds)):
            if revents[i]:
                out.append((fds[i][0], revents[i]))
        return out


class epoll:
    """epoll(7), with the same surface CPython's select.epoll has.

    The descriptor is owned: close() releases it, __del__ is the safety net,
    and every method after close() raises ValueError rather than acting on a
    number the kernel has given to someone else.  That is the whole reason
    this is a class rather than three functions.

    `sizehint` is accepted and ignored, as CPython's is -- the kernel has not
    used it since 2.6.8 -- and so is `flags` beyond EPOLL_CLOEXEC.
    """

    __slots__ = ("_fd",)

    def __init__(self, sizehint=-1, flags=0):
        self._fd = _c.epoll_create1(flags)

    @classmethod
    def fromfd(cls, fd):
        """Wrap an existing epoll descriptor.  It becomes ours to close."""
        self = cls.__new__(cls)
        self._fd = _fileno(fd)
        return self

    def fileno(self):
        self._check()
        return self._fd

    @property
    def closed(self):
        return self._fd < 0

    def close(self):
        fd = self._fd
        if fd >= 0:
            self._fd = -1
            import posix

            posix.close(fd)

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    def __enter__(self):
        self._check()
        return self

    def __exit__(self, *exc):
        self.close()

    def _check(self):
        if self._fd < 0:
            raise ValueError("I/O operation on closed epoll object")

    def register(self, fd, eventmask=EPOLLIN | EPOLLPRI | EPOLLOUT):
        self._check()
        _c.epoll_ctl(self._fd, _c.EPOLL_CTL_ADD, _fileno(fd), eventmask)

    def modify(self, fd, eventmask):
        self._check()
        _c.epoll_ctl(self._fd, _c.EPOLL_CTL_MOD, _fileno(fd), eventmask)

    def unregister(self, fd):
        self._check()
        # EPOLL_CTL_DEL ignores the event, but the kernel wanted a non-NULL
        # pointer before 2.6.9 and CPython still passes one; so does this.
        _c.epoll_ctl(self._fd, _c.EPOLL_CTL_DEL, _fileno(fd), 0)

    def poll(self, timeout=None, maxevents=-1):
        """-> [(fd, events), ...], the ready descriptors.

        `timeout` is in SECONDS here and milliseconds in the syscall, which
        is CPython's interface and the one asymmetry worth pointing at: poll()
        above takes milliseconds because select.poll does.
        """
        self._check()
        if timeout is None or timeout < 0:
            ms = -1
        else:
            v = float(timeout) * 1000.0
            ms = int(v)
            if v > ms:
                ms += 1
        if maxevents == 0:
            raise ValueError("maxevents must be greater than 0, got 0")
        if maxevents < 0:
            maxevents = 1023
        flat = _c.epoll_wait(self._fd, maxevents, ms)
        out = []
        for i in range(0, len(flat), 2):
            out.append((flat[i], flat[i + 1]))
        return out
