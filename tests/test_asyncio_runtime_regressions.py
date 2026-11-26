import _thread
import asyncio
import gc
import signal
import socket


async def finalize_cycle():
    closed = asyncio.Event()
    closed_sizes = []

    async def abandon():
        cycle = []

        async def values():
            try:
                yield 1
            finally:
                closed_sizes.append(len(cycle))
                closed.set()

        generator = values()
        cycle.append(generator)
        assert await anext(generator) == 1

    gc.disable()
    try:
        await abandon()
        assert not closed.is_set()
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, gc.collect)
        await asyncio.wait_for(closed.wait(), 5)
        gc.collect()
        assert closed_sizes == [1]
    finally:
        gc.enable()


class Connector(asyncio.SelectorEventLoop):
    async def sock_connect(self, sock, address):
        raise OSError("class connector")


async def connect_twice(loop):
    addresses = [(socket.AF_INET, socket.SOCK_STREAM, 0, "", ("127.0.0.1", 1))]

    async def resolve(*args, **kwargs):
        return addresses

    async def overridden_connect(sock, address):
        raise OSError("instance connector")

    loop.getaddrinfo = resolve
    try:
        await loop.create_connection(asyncio.Protocol, "fixture.invalid", 1)
    except OSError as error:
        assert str(error) == "class connector"
    else:
        raise AssertionError("the class connector should refuse the connection")

    addresses.append((socket.AF_INET, socket.SOCK_STREAM, 0, "", ("127.0.0.1", 2)))
    loop.sock_connect = overridden_connect
    try:
        await loop.create_connection(
            asyncio.Protocol, "fixture.invalid", 1, all_errors=True
        )
    except ExceptionGroup as error:
        assert [str(exc) for exc in error.exceptions] == ["instance connector"] * 2
    else:
        raise AssertionError("the instance connector should refuse both addresses")


def runner_interrupt():
    cancelled = []

    async def interrupted():
        try:
            _thread.interrupt_main(signal.SIGINT)
            await asyncio.wait_for(asyncio.Event().wait(), 5)
        except asyncio.CancelledError:
            cancelled.append(True)
            raise
        except KeyboardInterrupt:
            raise AssertionError("SIGINT reached the coroutine without cancelling it")

    try:
        asyncio.run(interrupted())
    except KeyboardInterrupt:
        assert cancelled == [True]
    else:
        raise AssertionError("Runner should surface the interrupt")


asyncio.run(asyncio.wait_for(finalize_cycle(), 10))
with asyncio.Runner(loop_factory=Connector) as runner:
    runner.run(asyncio.wait_for(connect_twice(runner.get_loop()), 5))
runner_interrupt()
print("asyncio runtime regressions passed")
