"""_thread - threads and the locks they wait on.

CPython's _thread is a C module.  Here the machine half is `_threadcore`
(src/modules/thread.asm): pthread_create and the entry point a new thread
starts at, the per-thread state, and a semaphore that gives the GIL up while
a thread waits on it.  This file is everything a program sees -- the lock
types, the argument checking and its wordings, the bootstrap every thread
runs under, the sentinels Thread.join waits on, thread-local storage and the
excepthook.

One thread runs Python at a time: there is a GIL (src/gil.asm), handed over
every switch interval and around anything that blocks.
"""

import _threadcore as _core

error = RuntimeError

# The longest timeout a blocking call accepts, in seconds: what fits in a
# signed 64-bit count of nanoseconds, as CPython's PY_TIMEOUT_MAX is.
TIMEOUT_MAX = 9223372036.0

get_ident = _core.get_ident
get_native_id = _core.get_native_id
_count = _core.count


class lock:
    """A lock object: the primitive every other synchronisation is built on.

    Not owned by the thread that takes it -- any thread may release it, which
    is what lets one thread signal another with it.
    """

    __slots__ = ("_h", "__weakref__")

    def __init__(self):
        self._h = _core.lock_new()

    def acquire(self, blocking=True, timeout=-1):
        if not blocking:
            if timeout != -1:
                raise ValueError("can't specify a timeout for a non-blocking call")
            return _core.lock_acquire(self._h, 0)
        if timeout == -1:
            return _core.lock_acquire(self._h, -1)
        if timeout < 0:
            raise ValueError("timeout value must be positive")
        if timeout > TIMEOUT_MAX:
            raise OverflowError("timestamp out of range for platform time_t")
        return _core.lock_acquire(self._h, int(timeout * 1e9))

    acquire_lock = acquire

    def __enter__(self):
        return _core.lock_acquire(self._h, -1)

    def release(self):
        _core.lock_release(self._h)

    release_lock = release

    def __exit__(self, t, v, tb):
        _core.lock_release(self._h)

    def locked(self):
        return _core.lock_locked(self._h)

    locked_lock = locked

    def _at_fork_reinit(self):
        # What a child of fork() calls on a lock its parent held: the thread
        # that held it does not exist in the child, so it is simply unlocked.
        _core.lock_reinit(self._h)

    def __repr__(self):
        return "<%s %s.%s object at %#x>" % (
            "locked" if _core.lock_locked(self._h) else "unlocked",
            type(self).__module__, type(self).__qualname__, id(self))

    def __del__(self):
        h = self._h
        self._h = None
        if h is not None:
            _core.lock_free(h)


LockType = lock


# The class itself, not a function returning one: CPython's is a builtin, and
# a builtin stored as a class attribute is not bound as a method -- which
# `locktype = _thread.allocate_lock` in the stdlib's own tests depends on.
allocate_lock = lock
allocate = allocate_lock


class RLock:
    """A reentrant lock: the thread that holds it may take it again, and it
    is released when that thread has let go as many times."""

    __slots__ = ("_block", "_owner", "_count", "__weakref__")

    def __init__(self):
        self._block = lock()
        self._owner = 0
        self._count = 0

    def acquire(self, blocking=True, timeout=-1):
        me = get_ident()
        if self._owner == me:
            self._count += 1
            return True
        if self._block.acquire(blocking, timeout):
            self._owner = me
            self._count = 1
            return True
        return False

    __enter__ = acquire

    def release(self):
        if self._owner != get_ident():
            raise RuntimeError("cannot release un-acquired lock")
        self._count = count = self._count - 1
        if not count:
            self._owner = 0
            self._block.release()

    def __exit__(self, t, v, tb):
        self.release()

    # What threading.Condition uses to let go of a lock held several deep
    # and take it back at the same depth.
    def _release_save(self):
        if self._count == 0:
            raise RuntimeError("cannot release un-acquired lock")
        state = (self._count, self._owner)
        self._count = 0
        self._owner = 0
        self._block.release()
        return state

    def _acquire_restore(self, state):
        self._block.acquire()
        self._count, self._owner = state

    def _is_owned(self):
        return self._owner == get_ident()

    def _recursion_count(self):
        return self._count if self._owner == get_ident() else 0

    def _at_fork_reinit(self):
        self._block._at_fork_reinit()
        self._owner = 0
        self._count = 0

    def __repr__(self):
        return "<%s %s.%s object owner=%d count=%d at %#x>" % (
            "locked" if self._count else "unlocked",
            type(self).__module__, type(self).__qualname__,
            self._owner, self._count, id(self))


def stack_size(size=0):
    """Set the stack size for threads started from now on; 0 is the
    platform's default.  Returns the previous setting."""
    if size != 0 and size < 32768:
        raise ValueError("size not valid: %d bytes" % (size,))
    return _core.set_stack_size(size)


def interrupt_main(signum=2):
    """Simulate the arrival of a signal in the main thread."""
    if signum < 1 or signum > 64:
        raise ValueError("signal number out of range")
    _core.interrupt_main(signum)


def exit():
    """Raise SystemExit, which ends the calling thread silently."""
    raise SystemExit


exit_thread = exit

_NO_KWARGS = object()


def start_new_thread(function, args, kwargs=_NO_KWARGS):
    """Start a new thread and return its identifier.

    The thread calls function(*args, **kwargs) and ends when that returns.
    An exception that escapes is reported and otherwise ignored.
    """
    if not callable(function):
        raise TypeError("first arg must be callable")
    if not isinstance(args, tuple):
        raise TypeError("2nd arg must be a tuple")
    if kwargs is _NO_KWARGS:
        kwargs = {}
    elif not isinstance(kwargs, dict):
        raise TypeError("optional 3rd arg must be a dictionary")
    return _core.start(_bootstrap, function, args, kwargs)


start_new = start_new_thread


def _bootstrap(function, args, kwargs):
    """What every new thread runs: the bottom frame of its stack.

    Nothing may escape it -- there is no caller to catch it -- so the report
    of a failure is itself guarded, and the sentinels are released whatever
    happened.
    """
    try:
        try:
            function(*args, **kwargs)
        except SystemExit:
            pass
        except BaseException:
            try:
                _report_unraisable(function)
            except BaseException:
                pass
    finally:
        try:
            for sentinel in _core.thread_dict().pop("sentinels", ()):
                try:
                    sentinel.release()
                except RuntimeError:
                    pass                # threading released it itself
        except BaseException:
            pass


def _report_unraisable(function):
    import sys

    exc_type, exc, tb = sys.exc_info()
    stderr = getattr(sys, "stderr", None)
    if stderr is None:
        return
    print("Exception ignored in thread started by %r" % (function,), file=stderr)
    _display(exc_type, exc, tb, stderr)


def _display(exc_type, exc, tb, file):
    """The traceback and the exception, to `file` -- which is whatever
    sys.stderr IS at the moment, the way CPython's PyErr_Display writes."""
    import traceback

    traceback.print_exception(exc_type, exc, tb, file=file)
    file.flush()


def daemon_threads_allowed():
    """Whether a thread may be made a daemon.  CPython says no in a
    subinterpreter that owns its GIL; here there is one interpreter, so the
    answer is yes.  threading reads this at import time."""
    return True


def _is_main_interpreter():
    """There is only one."""
    return True


def _set_sentinel():
    """A lock that is released when the calling thread ends.

    Comes back UNLOCKED: Thread._set_tstate_lock takes it itself, and
    Thread.join then waits by trying to take it again, which succeeds only
    once the thread that asked for it is gone.  The bootstrap releases it;
    for the main thread, threading._shutdown does.
    """
    sentinel = lock()
    _core.thread_dict().setdefault("sentinels", []).append(sentinel)
    return sentinel


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
    _display(args.exc_type, args.exc_value, args.exc_traceback, stderr)


_local_seq = 0


class _local:
    """Thread-local data: each thread sees its own attributes.

    The per-thread namespaces live in the thread's own dict
    (_threadcore.thread_dict), keyed by a number that is never reused, and
    go away with the thread.  A subclass's __init__ runs once in EACH thread
    that touches the object, with the arguments the object was created with.
    """

    __slots__ = ("_local__key", "_local__args", "__weakref__")

    def __new__(cls, /, *args, **kw):
        if (args or kw) and cls.__init__ is object.__init__:
            raise TypeError("Initialization arguments are not supported")
        global _local_seq
        self = object.__new__(cls)
        _local_seq += 1
        object.__setattr__(self, "_local__key", _local_seq)
        object.__setattr__(self, "_local__args", (args, kw))
        return self

    def __getattribute__(self, name):
        ns = _local_ns(self)
        if name == "__dict__":
            return ns
        if name in ns:
            return ns[name]
        return object.__getattribute__(self, name)

    def __setattr__(self, name, value):
        if name == "__dict__":
            raise AttributeError(
                "%r object attribute '__dict__' is read-only"
                % (type(self).__name__,))
        ns = _local_ns(self)
        if hasattr(getattr(type(self), name, None), "__set__"):
            object.__setattr__(self, name, value)
        else:
            ns[name] = value

    def __delattr__(self, name):
        if name == "__dict__":
            raise AttributeError(
                "%r object attribute '__dict__' is read-only"
                % (type(self).__name__,))
        ns = _local_ns(self)
        if name in ns:
            del ns[name]
        else:
            object.__delattr__(self, name)


def _local_ns(self):
    """This thread's namespace for one _local, made on first touch."""
    key = object.__getattribute__(self, "_local__key")
    store = _core.thread_dict()
    ns = store.get(key)
    if ns is None:
        ns = store[key] = {}
        cls = type(self)
        if cls.__init__ is not object.__init__:
            args, kw = object.__getattribute__(self, "_local__args")
            cls.__init__(self, *args, **kw)
    return ns
