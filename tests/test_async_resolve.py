# A host NAME, rather than a dotted quad, is resolved before any socket is
# made, and one that does not resolve is an OSError (socket.gaierror).
#
# CPython's asyncio resolves through loop.getaddrinfo, which is
# run_in_executor over socket.getaddrinfo -- a thread pool.  A numeric
# address skips it (_ipaddr_info answers without a lookup), so this is the
# one shape of open_connection that needs threads, and it lives in a file of
# its own so that the rest of the stream tests do not wait on them.
import asyncio


async def main():
    try:
        await asyncio.open_connection("no.such.host.invalid", 80)
        print("bad host", "connected?")
    except OSError as exc:
        print("bad host", type(exc).__name__)
    # Which OSError depends on the machine: where localhost is one address
    # it is ConnectionRefusedError, and where /etc/hosts also names ::1
    # asyncio tries both and raises a plain OSError naming the two failures.
    try:
        await asyncio.open_connection("localhost", 1)
        print("localhost", "connected?")
    except OSError as exc:
        print("localhost resolved, then", "OSError")


asyncio.run(main())
