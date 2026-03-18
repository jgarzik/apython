# contextlib.py - Utilities for with-statement contexts (minimal for apython)


class contextmanager:
    """Decorator to turn a generator function into a context manager."""

    def __init__(self, func):
        self._func = func

    def __call__(self, *args, **kwargs):
        return _GeneratorContextManager(self._func, args, kwargs)


class _GeneratorContextManager:
    """Helper for @contextmanager decorator."""

    def __init__(self, func, args, kwargs):
        self._gen = func(*args, **kwargs)

    def __enter__(self):
        try:
            return next(self._gen)
        except StopIteration:
            raise RuntimeError("generator didn't yield")

    def __exit__(self, typ, value, traceback):
        if typ is None:
            try:
                next(self._gen)
            except StopIteration:
                return False
            raise RuntimeError("generator didn't stop")
        else:
            if value is None:
                value = typ()
            try:
                next(self._gen)
            except StopIteration:
                return False
            except BaseException as exc:
                if exc is not value:
                    raise
                return False
            raise RuntimeError("generator didn't stop after throw")


class suppress:
    """Context manager to suppress specified exceptions."""

    def __init__(self, *exceptions):
        self._exceptions = exceptions

    def __enter__(self):
        return self

    def __exit__(self, exctype, excinst, exctb):
        return exctype is not None and issubclass(exctype, self._exceptions)


class closing:
    """Context manager for objects with a close() method."""

    def __init__(self, thing):
        self.thing = thing

    def __enter__(self):
        return self.thing

    def __exit__(self, *exc_info):
        self.thing.close()


class redirect_stdout:
    """Context manager for temporarily redirecting stdout."""

    def __init__(self, new_target):
        self._new_target = new_target

    def __enter__(self):
        import sys
        self._old_target = sys.stdout
        sys.stdout = self._new_target
        return self._new_target

    def __exit__(self, exctype, excinst, exctb):
        import sys
        sys.stdout = self._old_target


class redirect_stderr:
    """Context manager for temporarily redirecting stderr."""

    def __init__(self, new_target):
        self._new_target = new_target

    def __enter__(self):
        import sys
        self._old_target = sys.stderr
        sys.stderr = self._new_target
        return self._new_target

    def __exit__(self, exctype, excinst, exctb):
        import sys
        sys.stderr = self._old_target


class nullcontext:
    """Context manager that does nothing."""

    def __init__(self, enter_result=None):
        self.enter_result = enter_result

    def __enter__(self):
        return self.enter_result

    def __exit__(self, *excinfo):
        pass
