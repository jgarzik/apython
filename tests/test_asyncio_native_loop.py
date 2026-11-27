"""The running loop belongs to a thread and clears in a forked child."""

import asyncio
import os
import sys
import threading
import weakref

if sys.implementation.name == "apython":
    import _asyncio_native as accelerator
else:
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
