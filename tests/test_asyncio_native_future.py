"""Future state transitions, callback contexts, and GC through the native facade."""

import asyncio
import contextvars
import gc
import sys
import weakref

if sys.implementation.name == "apython":
    from _asyncio_native import Future
else:
    from _asyncio import Future


class DerivedFuture(Future):
    pass


local = contextvars.ContextVar("local", default="unset")


async def exercise():
    loop = asyncio.get_running_loop()
    future = DerivedFuture(loop=loop)
    seen = []

    def callback(completed):
        seen.append((completed.result(), local.get()))

    token = local.set("registered")
    try:
        future.add_done_callback(callback)
    finally:
        local.reset(token)
    callbacks = future._callbacks
    callbacks.clear()
    assert len(future._callbacks) == 1
    loop.call_soon(future.set_result, 42)
    assert await future == 42
    assert seen == [(42, "registered")]
    assert future._callbacks is None
    try:
        future.set_result(99)
    except asyncio.InvalidStateError:
        pass
    else:
        raise AssertionError("completed twice")

    exception = Future(loop=loop)
    exception.set_exception(ValueError("failed"))
    try:
        exception.result()
    except ValueError as exc:
        assert str(exc) == "failed"
    else:
        raise AssertionError("exception was swallowed")
    assert exception.exception().args == ("failed",)
    assert not exception._log_traceback

    cancelled = Future(loop=loop)
    assert cancelled.cancel("stopped") and not cancelled.cancel()
    try:
        await cancelled
    except asyncio.CancelledError as exc:
        assert exc.args == ("stopped",)
    else:
        raise AssertionError("cancellation was swallowed")

    cycle = Future(loop=loop)
    ref = weakref.ref(cycle)
    cycle.set_result(cycle)
    del cycle
    gc.collect()
    assert ref() is None


asyncio.run(exercise())
print("native Future state, callbacks, cancellation and GC")
