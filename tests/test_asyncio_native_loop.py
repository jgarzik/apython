"""The running loop belongs to a thread and clears in a forked child."""

import asyncio
import os
import sys
import threading
import weakref

import _asyncio as accelerator


class Loop:
    pass


def assert_unset():
    assert accelerator._get_running_loop() is None
    try:
        accelerator.get_running_loop()
    except RuntimeError as exc:
        assert str(exc) == "no running event loop"
    else:
        raise AssertionError("missing RuntimeError")


assert_unset()
main_loop = Loop()
accelerator._set_running_loop(main_loop)
assert accelerator.get_running_loop() is main_loop
assert accelerator.get_event_loop() is main_loop
refs = []


def worker():
    assert_unset()
    loop = Loop()
    refs.append(weakref.ref(loop))
    accelerator._set_running_loop(loop)
    assert accelerator.get_running_loop() is loop


thread = threading.Thread(target=worker)
thread.start()
thread.join()
assert len(refs) == 1 and refs[0]() is None
assert accelerator.get_running_loop() is main_loop

pid = os.fork()
if pid == 0:
    try:
        assert_unset()
    except BaseException:
        os._exit(1)
    os._exit(0)
assert os.waitpid(pid, 0)[1] == 0
assert accelerator.get_running_loop() is main_loop
accelerator._set_running_loop(None)
assert_unset()

policy_loop = asyncio.new_event_loop()
try:
    asyncio.set_event_loop(policy_loop)
    assert accelerator.get_event_loop() is policy_loop
finally:
    asyncio.set_event_loop(None)
    policy_loop.close()

print("running loop is thread-local and clears after fork")

scheduled = accelerator._scheduled_tasks
first, second = Loop(), Loop()
accelerator._register_task(first)
accelerator._register_eager_task(second)
assert first in scheduled
assert second in accelerator._eager_tasks
accelerator._unregister_eager_task(second)
assert second not in accelerator._eager_tasks
accelerator._unregister_task(first)
assert first not in scheduled
ephemeral = Loop()
ref = weakref.ref(ephemeral)
accelerator._register_task(ephemeral)
del ephemeral
assert ref() is None and len(scheduled) == 0

accelerator._set_running_loop(main_loop)
try:
    assert accelerator.current_task() is None
    accelerator._enter_task(main_loop, first)
    assert accelerator.current_task() is first
    try:
        accelerator._enter_task(main_loop, second)
    except RuntimeError:
        pass
    else:
        raise AssertionError("entered an occupied task")
    assert accelerator._swap_current_task(main_loop, second) is first
    assert accelerator.current_task(main_loop) is second
    try:
        accelerator._leave_task(main_loop, first)
    except RuntimeError:
        pass
    else:
        raise AssertionError("left a different task")
    accelerator._leave_task(main_loop, second)
    try:
        accelerator._swap_current_task(main_loop, None)
    except KeyError:
        pass
    else:
        raise AssertionError("swapped out an absent task")
    assert accelerator.current_task() is None
finally:
    accelerator._set_running_loop(None)
print("scheduled, eager and current tasks have separate registries")
