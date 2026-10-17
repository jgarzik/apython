# throw() into a chain of awaiting coroutines records each frame ONCE in the
# traceback, innermost last, as CPython does.  It used to record every
# delegating frame twice -- once on the way down and once as the exception
# unwound -- which is what made every asyncio traceback print each awaiting
# frame twice.
import traceback


def frames(exc):
    return [(f.name, f.lineno - FIRST) for f in traceback.extract_tb(exc.__traceback__)]


FIRST = traceback.extract_stack()[-1].lineno


class F:
    def __await__(self):
        yield self


async def inner():
    await F()


async def outer():
    await inner()


c = outer()
c.send(None)
try:
    c.throw(ValueError("v"))
except ValueError as e:
    print("coroutine chain:", frames(e))


def ginner():
    yield 1


def gouter():
    yield from ginner()


g = gouter()
next(g)
try:
    g.throw(KeyError("k"))
except KeyError as e:
    print("generator chain:", frames(e))


# Three levels, and an exception the innermost frame raises itself while
# handling the thrown one.
async def a():
    try:
        await F()
    except ValueError:
        raise RuntimeError("replaced")


async def b():
    await a()


async def top():
    await b()


c = top()
c.send(None)
try:
    c.throw(ValueError("v"))
except RuntimeError as e:
    print("replaced:", frames(e))
    print("its context:", frames(e.__context__))
