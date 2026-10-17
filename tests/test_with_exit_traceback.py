# __exit__ and __aexit__ receive the exception's traceback, not None.
# contextlib's _GeneratorContextManager.__exit__ ends with
# `exc.__traceback__ = traceback`, so a None there erased every frame below
# the `with` -- and pytest, whose capture plugin wraps each test call in one,
# reported every failing test at a line inside pluggy.
import asyncio
import contextlib
import traceback


def names(tb):
    return [(f.name, f.lineno - BASE) for f in traceback.extract_tb(tb)]


BASE = traceback.extract_stack()[-1].lineno


class CM:
    def __enter__(self):
        return self

    def __exit__(self, t, v, tb):
        print("exit tb:", names(tb), tb is v.__traceback__)
        return False


def boom():
    raise ValueError("x")


def plain():
    with CM():
        boom()


try:
    plain()
except ValueError as e:
    print("final:", names(e.__traceback__))


@contextlib.contextmanager
def capture():
    try:
        yield
    finally:
        pass


def wrapped():
    with capture():
        boom()


try:
    wrapped()
except ValueError as e:
    print("contextlib:", names(e.__traceback__))


def wrapper_gen():
    with capture():
        return (yield)


try:
    boom()
except ValueError as e:
    exc = e
g = wrapper_gen()
next(g)
try:
    g.throw(exc)
except ValueError as e:
    print("thrown through:", names(e.__traceback__))


class ACM:
    async def __aenter__(self):
        return self

    async def __aexit__(self, t, v, tb):
        print("aexit tb:", names(tb))
        return False


async def amain():
    try:
        async with ACM():
            boom()
    except ValueError as e:
        print("async final:", names(e.__traceback__))


asyncio.run(amain())

with CM() if False else contextlib.nullcontext():
    pass
print("no exception: fine")
