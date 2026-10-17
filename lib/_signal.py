"""_signal - the signal module's C half, assembled from its two halves.

The handlers, the trampoline that marks a signal pending, and the syscalls are
assembly, in the builtin module _signalcore.  This file presents them to the
standard library as `_signal`, the name CPython's own Lib/signal.py imports
everything from and then wraps in enums.

What is added here is what is easier said in Python than in assembly:

  * `ItimerError`.  _signalcore's setitimer and getitimer raise a plain
    OSError for a `which` the kernel refuses; CPython's raise this subclass
    of it, so narrowing here keeps both kinds of `except` working.
  * `valid_signals()`, which CPython answers from sigfillset: every number
    from 1 to NSIG-1 except the two glibc keeps for its own thread
    machinery.  It answers plain ints -- Lib/signal.py turns them into
    Signals members.

What is still missing is the thread-mask family -- pthread_sigmask,
sigpending, sigwait, sigwaitinfo, sigtimedwait, pthread_kill -- plus
set_wakeup_fd, siginterrupt and pidfd_send_signal.  Lib/signal.py guards each
with `if 'x' in _globals`, so their absence is what a platform without them
looks like rather than an error.
"""

import _signalcore as _c
from _signalcore import *


class ItimerError(OSError):
    pass


ItimerError.__module__ = "signal"
ItimerError.__name__ = ItimerError.__qualname__ = "itimer_error"


def setitimer(*args):
    """setitimer(which, seconds, interval=0.0) -> (delay, interval)

    The timer replaced.  The arguments pass through untouched so that
    _signalcore's own arity message is the one that shows.
    """
    try:
        return _c.setitimer(*args)
    except OSError as exc:
        raise ItimerError(*exc.args) from None


def getitimer(*args):
    """getitimer(which) -> (delay, interval)"""
    try:
        return _c.getitimer(*args)
    except OSError as exc:
        raise ItimerError(*exc.args) from None


def valid_signals():
    """valid_signals() -> the set of signal numbers this platform accepts"""
    return {n for n in range(1, NSIG) if n not in (32, 33)}


# CPython's signal.py defines these in Python itself, so they report the
# signal module; test_signal checks every Python-level routine it exports.
setitimer.__module__ = getitimer.__module__ = valid_signals.__module__ = "signal"
