"""Task coroutine driving, eager starts, context, and cancellation."""

import asyncio
import contextvars
import sys

if sys.implementation.name == "apython":
    from _asyncio_native import Task, current_task
else:
    from _asyncio import Task, current_task


local = contextvars.ContextVar("local", default="caller")


async def exercise():
    loop = asyncio.get_running_loop()
    seen = []

    async def eager():
        seen.append((current_task(loop).get_name(), local.get()))
        return 7

    ctx = contextvars.copy_context()
    ctx.run(local.set, "task")
    done = Task(eager(), loop=loop, name="eager", context=ctx, eager_start=True)
    assert done.done() and await done == 7
    assert done.get_context() is ctx
    assert seen == [("eager", "task")]
    assert local.get() == "caller"

    waiting = loop.create_future()
    started = loop.create_future()

    async def blocked():
        started.set_result(current_task(loop))
        try:
            await waiting
        except asyncio.CancelledError as exc:
            seen.append(exc.args)
            raise

    task = Task(blocked(), loop=loop)
    assert await started is task
    assert task.cancel("stop") and task.cancelling() == 1
    assert task.uncancel() == 0
    try:
        await task
    except asyncio.CancelledError:
        pass
    else:
        raise AssertionError("cancellation did not complete the task")
    assert task.cancelled()
    assert waiting.cancelled()
    assert seen[-1] == ("stop",)

    async def value():
        await asyncio.sleep(0)
        return 42

    assert await Task(value(), loop=loop) == 42


asyncio.run(exercise())
print("native Task resumes, shares task state, and propagates cancellation")
