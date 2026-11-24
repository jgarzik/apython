"""atexit - callbacks to run at interpreter shutdown.

CPython's is a C module because the interpreter calls into it from its own
teardown.  Here `register` records the callbacks, `_run_exitfuncs` runs them,
and the interpreter calls `_run_exitfuncs` on its way out
(src/shutdown.asm), after threading._shutdown() and before finalization
begins -- the order Py_FinalizeEx uses.
"""

_registry = []


def register(func, *args, **kwargs):
    """Record func to be called at exit.  Returns func, so it can be used as
    a decorator."""
    if not callable(func):
        raise TypeError("the first argument must be callable")
    _registry.append((func, args, kwargs))
    return func


def unregister(func):
    """Remove every registration of func.  Not an error if there are none."""
    _registry[:] = [e for e in _registry if e[0] is not func]


def _clear():
    _registry.clear()


def _ncallbacks():
    return len(_registry)


def _run_exitfuncs():
    """Run the callbacks, last registered first.

    An exception in one does not stop the others and does not propagate:
    CPython reports it as "Exception ignored in atexit callback" and carries
    on, which is the only sane thing at shutdown.
    """
    import sys

    while _registry:
        func, args, kwargs = _registry.pop()
        try:
            func(*args, **kwargs)
        except SystemExit:
            raise
        except BaseException as exc:
            stderr = getattr(sys, "stderr", None)
            if stderr is not None:
                print("Exception ignored in atexit callback: %r" % (func,),
                      file=stderr)
                print("%s: %s" % (type(exc).__name__, exc), file=stderr)
