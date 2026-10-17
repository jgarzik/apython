# generator.throw() and coroutine.throw() take CPython's deprecated
# (type, value, traceback) spelling as well as an exception: the exception is
# built from the type and the value, a value that is already an instance of
# the type IS the exception, and the call warns DeprecationWarning.  It used
# to refuse with "throw() takes exactly one argument".
import warnings

warnings.simplefilter("ignore", DeprecationWarning)


def g():
    while True:
        try:
            yield 1
        except Exception as e:
            yield (type(e).__name__, e.args)


for args in ((ValueError,), (ValueError, "msg"), (ValueError, ("a", "b")),
             (ValueError, None), (ValueError, ValueError("inst")),
             (KeyError, "k", None), (ValueError("only"),)):
    it = g()
    next(it)
    print(args, "->", it.throw(*args))


class Fut:
    def __await__(self):
        try:
            yield
        except Exception as e:
            return (type(e).__name__, e.args)


async def co():
    return await Fut()


c = co()
c.send(None)
try:
    c.throw(TypeError, "via coroutine")
except StopIteration as e:
    print("coroutine ->", e.value)

for bad in ((), (ValueError, 1, 2, 3), (5,), (ValueError, 1, 5)):
    it = g()
    next(it)
    try:
        it.throw(*bad)
    except TypeError as e:
        print("refused:", e)

with warnings.catch_warnings():
    warnings.simplefilter("error")
    it = g()
    next(it)
    try:
        it.throw(ValueError, "x")
    except DeprecationWarning as e:
        print("deprecated:", e)
    print("single arg still fine:", it.throw(ValueError("y")))
