# asyncio's stream layer, over a real socket.
#
# What was here before was assembly that predated any socket support: it
# hard-coded 127.0.0.1 and ignored the host it was given, discarded what
# connect() returned, read into a fixed stack buffer, handed back `str` where
# CPython hands back `bytes`, and raised OSErrors built from fixed strings
# with no errno -- so `except ConnectionRefusedError` could not catch one.  It
# had no test, which is how all of that survived.
#
# The loop owes the Python half exactly one primitive: wait_fd(fd, events),
# an awaitable that suspends the running task until a descriptor is ready.
# That is the same IO_WAIT sentinel the old assembly yielded; it is simply
# reachable now.

import asyncio


async def echo_line(reader, writer):
    """One line in, the same line back, prefixed."""
    line = await reader.readline()
    writer.write(b"echo:" + line)
    await writer.drain()
    writer.close()
    await writer.wait_closed()


async def echo_all(reader, writer):
    """Everything until the peer stops, back in one piece."""
    data = await reader.read()
    writer.write(data.upper())
    await writer.drain()
    writer.close()
    await writer.wait_closed()


async def count_lines(reader, writer):
    n = 0
    async for _line in reader:
        n += 1
    writer.write(str(n).encode())
    await writer.drain()
    writer.close()
    await writer.wait_closed()


async def with_server(handler, body):
    server = await asyncio.start_server(handler, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    try:
        return await body(port)
    finally:
        server.close()
        await server.wait_closed()


async def one_line(port):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(b"hello\n")
    await writer.drain()
    line = await reader.readline()
    writer.close()
    await writer.wait_closed()
    return line


async def read_everything(port):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(b"shout at me")
    await writer.drain()
    writer.write_eof()
    data = await reader.read()
    writer.close()
    await writer.wait_closed()
    return data


async def many_lines(port):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.writelines([b"a\n", b"b\n", b"c\n"])
    await writer.drain()
    writer.write_eof()
    answer = await reader.read()
    writer.close()
    await writer.wait_closed()
    return answer


async def exactly(port):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(b"0123456789\n")
    await writer.drain()
    head = await reader.readexactly(5)
    rest = await reader.read()
    writer.close()
    await writer.wait_closed()
    return head, rest


async def short_read(port):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(b"tiny\n")
    await writer.drain()
    try:
        await reader.readexactly(1000)
        got = "no error"
    except asyncio.IncompleteReadError as exc:
        got = ("IncompleteReadError", exc.partial, exc.expected)
    writer.close()
    await writer.wait_closed()
    return got


async def main():
    print("a line         ", await with_server(echo_line, one_line))
    print("everything     ", await with_server(echo_all, read_everything))
    print("three lines    ", await with_server(count_lines, many_lines))
    print("readexactly    ", await with_server(echo_line, exactly))
    print("short read     ", await with_server(echo_line, short_read))

    # A refused connection is an ordinary ConnectionRefusedError, with the
    # errno on it: catching it by name is the whole point.
    try:
        await asyncio.open_connection("127.0.0.1", 1)
        print("refused        ", "connected?")
    except ConnectionRefusedError as exc:
        print("refused        ", type(exc).__name__, exc.errno)
    except OSError as exc:
        print("refused        ", "OSError", exc.errno)

    # Two connections at once, so the server's accept loop runs more than
    # once and each client gets its own pair of streams.
    server = await asyncio.start_server(echo_line, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]

    async def talk(word):
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.write(word + b"\n")
        await writer.drain()
        line = await reader.readline()
        writer.close()
        await writer.wait_closed()
        return line

    print("concurrent     ",
          await asyncio.gather(talk(b"one"), talk(b"two"), talk(b"three")))

    # Enough at once that the descriptors climb well past the small ones.
    # _asynciocore.wait_fd tested its arguments with V_IS_INT, which is true
    # only for an int IMMEDIATE, so a descriptor on the heap was refused as
    # "arguments must be int" -- and the refusal reached the caller as a
    # connection reset, because that is what the far end sees when this one
    # stops reading.  In an ordinary build a descriptor is an immediate up to
    # 2**50, so only INT_STRESS=1 reaches it; the count here is what makes
    # the shape visible at all.
    many = await asyncio.gather(*[talk(b"n%d" % i) for i in range(8)])
    print("eight at once  ", sorted(many))
    server.close()
    await server.wait_closed()


asyncio.run(main())


# A reader on its own, fed by hand, is what the read methods are actually
# about; the socket is only where the bytes come from.
async def buffered():
    reader = asyncio.StreamReader()
    reader.feed_data(b"one\ntwo\nthree")
    reader.feed_eof()
    print("readline       ", await reader.readline())
    print("readuntil      ", await reader.readuntil(b"\n"))
    print("read rest      ", await reader.read())
    print("at_eof         ", reader.at_eof())

    reader = asyncio.StreamReader()
    reader.feed_data(b"abcdef")
    reader.feed_eof()
    print("readexactly    ", await reader.readexactly(3), await reader.read(2))

    reader = asyncio.StreamReader()
    reader.feed_data(b"no separator here")
    reader.feed_eof()
    try:
        await reader.readuntil(b"\n")
    except asyncio.IncompleteReadError as exc:
        print("no separator   ", exc.partial, exc.expected)


asyncio.run(buffered())
print("done")
