import asyncio
import sys


async def cancel_subprocess_setup():
    loop = asyncio.get_running_loop()
    task = loop.create_task(
        loop.subprocess_exec(
            asyncio.SubprocessProtocol,
            sys.executable,
            "-c",
            "import time; time.sleep(20)",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    )
    loop.call_soon(task.cancel)
    try:
        await asyncio.wait_for(task, 5)
    except asyncio.CancelledError:
        assert task.cancelled()
    else:
        raise AssertionError("the subprocess setup task should be cancelled")


asyncio.run(cancel_subprocess_setup())
print("asyncio subprocess setup cancelled")
