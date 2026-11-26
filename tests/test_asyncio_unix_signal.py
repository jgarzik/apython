import asyncio
import os
import signal


async def unix_signal():
    loop = asyncio.get_running_loop()
    received = asyncio.Event()
    callbacks = []
    old_handler = signal.getsignal(signal.SIGUSR1)

    def callback():
        callbacks.append(True)
        received.set()

    loop.add_signal_handler(signal.SIGUSR1, callback)
    try:
        pid = os.fork()
        if pid == 0:
            status = 1
            try:
                assert signal.set_wakeup_fd(-1) == -1
                child_signals = []
                signal.signal(signal.SIGUSR1, lambda sig, frame: child_signals.append(sig))
                os.kill(os.getpid(), signal.SIGUSR1)
                assert child_signals == [signal.SIGUSR1]
                status = 0
            finally:
                os._exit(status)
        assert os.waitpid(pid, 0) == (pid, 0)
        await asyncio.sleep(0)
        assert callbacks == []

        loop.call_later(0.05, os.kill, os.getpid(), signal.SIGUSR1)
        await asyncio.wait_for(received.wait(), 5)
        assert callbacks == [True]
        assert loop.remove_signal_handler(signal.SIGUSR1)
        assert signal.set_wakeup_fd(-1) == -1
    finally:
        loop.remove_signal_handler(signal.SIGUSR1)
        signal.signal(signal.SIGUSR1, old_handler)


asyncio.run(unix_signal())
print("asyncio Unix signal and fork isolation passed")
