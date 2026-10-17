"""_thread - the single-threaded stand-in apython ships.

CPython's _thread is a C module.  apython has no threads, so the pieces the
stdlib actually reaches for at import time -- get_ident, allocate_lock, RLock
-- are provided here with the only behaviour a single thread can observe: the
identity is constant and the locks are uncontended.  Anything that would
actually start a thread raises, rather than pretending to.
"""

TIMEOUT_MAX = 10000000.0


class error(RuntimeError):
    """Raised on thread-specific errors.  _thread.error is RuntimeError in 3.x."""


def get_ident():
    """The one thread there is.  CPython guarantees only that it is a nonzero int."""
    return 1


def get_native_id():
    return 1


def _count():
    return 0


def stack_size(size=None):
    return 0


def interrupt_main(signum=2):
    raise KeyboardInterrupt


def start_new_thread(function, args, kwargs=None):
    raise error("apython does not support threads")


start_joinable_thread = start_new_thread


def daemon_threads_allowed():
    """Whether a thread may be made a daemon.  CPython says no in a
    subinterpreter that owns its GIL; here there is one interpreter and one
    thread, so the answer is yes.  threading reads this at import time, which
    is what kept it -- and the thirteen modules behind it -- from loading."""
    return True


def _is_main_interpreter():
    """There is only one."""
    return True


def _set_sentinel():
    """A lock released when the calling thread dies.

    Thread._bootstrap uses it to detect that a thread is gone: it takes the
    lock itself and the interpreter releases it when the thread dies.  So it
    comes back UNLOCKED -- acquiring it here made threading's own acquire()
    the second one and a deadlock.  The one thread there is outlives anything
    that could ask, so nothing ever releases it."""
    return LockType()


class _ExceptHookArgs(tuple):
    """The named 4-tuple threading.excepthook is handed.

    CPython's is a structseq; the fields are what the stdlib reads."""

    __slots__ = ()

    def __new__(cls, seq):
        return tuple.__new__(cls, seq)

    @property
    def exc_type(self):
        return self[0]

    @property
    def exc_value(self):
        return self[1]

    @property
    def exc_traceback(self):
        return self[2]

    @property
    def thread(self):
        return self[3]

    def __repr__(self):
        return ("_thread._ExceptHookArgs(exc_type=%r, exc_value=%r, "
                "exc_traceback=%r, thread=%r)"
                % (self[0], self[1], self[2], self[3]))


def _excepthook(args):
    """Report an exception that escaped a thread's run().

    threading imports this in preference to a pure-Python fallback that pulls
    in traceback -> linecache -> _tokenize, none of which is here yet.  A
    SystemExit is silent, as it is in CPython.
    """
    import sys

    if args.exc_type is SystemExit:
        return
    stderr = getattr(sys, "stderr", None)
    if stderr is None:
        return
    name = getattr(args.thread, "name", None)
    if name is None:
        name = "MainThread"
    print("Exception in thread %s:" % (name,), file=stderr)
    exc = args.exc_value
    if exc is None:
        print("%s" % (args.exc_type,), file=stderr)
        return
    text = str(exc)
    if text:
        print("%s: %s" % (args.exc_type.__name__, text), file=stderr)
    else:
        print("%s" % (args.exc_type.__name__,), file=stderr)


class LockType:
    """An uncontended lock.  With one thread, acquire always succeeds."""

    __slots__ = ("_locked",)

    def __init__(self):
        self._locked = False

    def acquire(self, blocking=True, timeout=-1):
        if self._locked:
            # A single thread that blocks on its own lock would never wake.
            if blocking:
                raise error("deadlock: lock already held by this thread")
            return False
        self._locked = True
        return True

    __enter__ = acquire

    def release(self):
        if not self._locked:
            raise error("release unlocked lock")
        self._locked = False

    def __exit__(self, t, v, tb):
        self.release()

    def locked(self):
        return self._locked

    def acquire_lock(self, blocking=True, timeout=-1):
        return self.acquire(blocking, timeout)

    def release_lock(self):
        self.release()

    def locked_lock(self):
        return self._locked

    def _at_fork_reinit(self):
        # What a child of fork() calls on a lock its parent held: the thread
        # that held it does not exist in the child, so it is simply unlocked.
        # concurrent.futures.thread registers it at import, which is why its
        # absence failed the import rather than a fork.
        self._locked = False

    def __repr__(self):
        state = "locked" if self._locked else "unlocked"
        return "<_thread.lock %s>" % state


class RLock:
    """A reentrant lock: the same thread may acquire it repeatedly."""

    __slots__ = ("_count",)

    def __init__(self):
        self._count = 0

    def acquire(self, blocking=True, timeout=-1):
        self._count += 1
        return True

    __enter__ = acquire

    def release(self):
        if self._count == 0:
            raise RuntimeError("cannot release un-acquired lock")
        self._count -= 1

    def __exit__(self, t, v, tb):
        self.release()

    def _is_owned(self):
        return self._count > 0

    def _at_fork_reinit(self):
        self._count = 0

    def __repr__(self):
        return "<_thread.RLock count=%d>" % self._count


def allocate_lock():
    return LockType()


allocate = allocate_lock


class _local:
    """thread._local, which with one thread is an ordinary attribute holder."""


local = _local
