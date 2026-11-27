"""Heap-type interface for the native asyncio Future state machine."""

import contextvars
import sys
from types import GenericAlias

from _asyncio_native import _future_transition

_PENDING, _FINISHED, _CANCELLED = range(3)
_STATES = ("PENDING", "FINISHED", "CANCELLED")
_DEFAULT_CONTEXT = object()


class Future:
    """A result or exception that will be delivered by an asyncio loop."""

    # These indexes match the state record in src/modules/asyncio_future.asm.
    __slots__ = ("__record", "__loop", "__callbacks", "__trace",
                 "__blocking", "_cancelled_exc", "__dict__", "__weakref__")

    def __new__(cls, *args, **kwargs):
        self = super().__new__(cls)
        self.__record = [_PENDING, None, None, None, None, False]
        self.__loop = None
        self.__callbacks = []
        self.__trace = None
        self.__blocking = False
        self._cancelled_exc = None
        return self

    def __init__(self, *, loop=None):
        from asyncio import events, format_helpers

        self.__record[:] = [_PENDING, None, None, None, None, False]
        self.__callbacks = []
        self.__blocking = False
        self._cancelled_exc = None
        self.__loop = events.get_event_loop() if loop is None else loop
        self.__trace = (format_helpers.extract_stack(sys._getframe(1))
                        if self.__loop.get_debug() else None)

    __class_getitem__ = classmethod(GenericAlias)

    @property
    def _state(self):
        return _STATES[self.__record[0]]

    @property
    def _result(self):
        return self.__record[1]

    @property
    def _exception(self):
        return self.__record[2]

    @property
    def _loop(self):
        return self.__loop

    @property
    def _source_traceback(self):
        return self.__trace

    @property
    def _callbacks(self):
        return self.__callbacks[:] or None

    @property
    def _cancel_message(self):
        return self.__record[4]

    @_cancel_message.setter
    def _cancel_message(self, value):
        self.__record[4] = value

    @property
    def _log_traceback(self):
        return bool(self.__record[5])

    @_log_traceback.setter
    def _log_traceback(self, value):
        if value:
            raise ValueError("_log_traceback can only be set to False")
        self.__record[5] = False

    @property
    def _asyncio_future_blocking(self):
        return self.__blocking

    @_asyncio_future_blocking.setter
    def _asyncio_future_blocking(self, value):
        self.__blocking = bool(value)

    def __repr__(self):
        from asyncio.base_futures import _future_repr

        return _future_repr(self)

    def __del__(self):
        if self.__record[5]:
            self.__loop.call_exception_handler({
                "message": f"{type(self).__name__} exception was never retrieved",
                "exception": self.__record[2],
                "future": self,
                **({"source_traceback": self.__trace} if self.__trace else {}),
            })

    def get_loop(self):
        if self.__loop is None:
            raise RuntimeError("Future object is not initialized.")
        return self.__loop

    def _make_cancelled_error(self):
        from asyncio.exceptions import CancelledError

        exc = self._cancelled_exc
        if exc is not None:
            self._cancelled_exc = None
            return exc
        message = self.__record[4]
        return CancelledError() if message is None else CancelledError(message)

    def cancel(self, msg=None):
        self.get_loop()
        if not _future_transition(self.__record, 2, msg, None):
            return False
        self.__schedule_callbacks()
        return True

    def cancelled(self):
        return self.__record[0] == _CANCELLED

    def done(self):
        return self.__record[0] != _PENDING

    def result(self):
        state, result, exception, traceback = self.__record[:4]
        if state == _CANCELLED:
            raise self._make_cancelled_error()
        if state != _FINISHED:
            from asyncio.exceptions import InvalidStateError

            raise InvalidStateError("Result is not set.")
        self.__record[5] = False
        if exception is not None:
            raise exception.with_traceback(traceback)
        return result

    def exception(self):
        state = self.__record[0]
        if state == _CANCELLED:
            raise self._make_cancelled_error()
        if state != _FINISHED:
            from asyncio.exceptions import InvalidStateError

            raise InvalidStateError("Exception is not set.")
        self.__record[5] = False
        return self.__record[2]

    def __schedule_callbacks(self):
        callbacks = self.__callbacks
        self.__callbacks = []
        for callback, context in callbacks:
            self.__loop.call_soon(callback, self, context=context)

    def add_done_callback(self, fn, *, context=_DEFAULT_CONTEXT):
        loop = self.get_loop()
        if context is _DEFAULT_CONTEXT:
            context = contextvars.copy_context()
        if self.done():
            loop.call_soon(fn, self, context=context)
        else:
            self.__callbacks.append((fn, context))

    def remove_done_callback(self, fn):
        self.get_loop()
        removed = 0
        for entry in self.__callbacks[:]:
            if entry[0] == fn:
                # Equality may settle the future or add another callback.
                # Remove only the entry we inspected from the live list.
                for index, current in enumerate(self.__callbacks):
                    if current is entry:
                        del self.__callbacks[index]
                        removed += 1
                        break
        return removed

    def set_result(self, result):
        self.get_loop()
        if not _future_transition(self.__record, 0, result, None):
            from asyncio.exceptions import InvalidStateError

            raise InvalidStateError("invalid state")
        self.__schedule_callbacks()

    def set_exception(self, exception):
        from asyncio.exceptions import InvalidStateError

        self.get_loop()
        if self.done():
            raise InvalidStateError("invalid state")
        if isinstance(exception, type):
            exception = exception()
        if not isinstance(exception, BaseException):
            raise TypeError("invalid exception object")
        if isinstance(exception, StopIteration):
            wrapped = RuntimeError(
                "StopIteration interacts badly with generators "
                "and cannot be raised into a Future"
            )
            wrapped.__cause__ = wrapped.__context__ = exception
            exception = wrapped
        if not _future_transition(self.__record, 1, exception, exception.__traceback__):
            raise InvalidStateError("invalid state")
        self.__schedule_callbacks()

    def __await__(self):
        if not self.done():
            self.__blocking = True
            yield self
        if not self.done():
            raise RuntimeError("await wasn't used with future")
        return self.result()

    __iter__ = __await__
