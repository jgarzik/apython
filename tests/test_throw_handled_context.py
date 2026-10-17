# An exception thrown INTO a generator or coroutine with .throw() is raised at
# the suspended yield, so its __context__ is whatever that frame is handling
# there -- not whatever the CALLER of throw() happens to be handling.
# asyncio depends on it: Task.__wakeup catches a finished task's exception and
# throws it into the awaiting coroutine from inside its own `except`, so the
# caller's handled exception is the very object being thrown, and the awaiting
# coroutine's `except` is the one that must become the context.


class Fut:
    def __await__(self):
        yield self


async def co():
    try:
        raise KeyError("coroutine handler")
    except KeyError:
        try:
            await Fut()
        except ValueError as e:
            print("coroutine:", repr(e.__context__))


c = co()
c.send(None)
try:
    raise ValueError("thrown")
except ValueError as e:
    try:
        c.throw(e)
    except StopIteration:
        pass


def g():
    try:
        raise KeyError("generator handler")
    except KeyError:
        try:
            yield
        except ValueError as e:
            print("generator:", repr(e.__context__))


it = g()
next(it)
try:
    it.throw(ValueError("y"))
except StopIteration:
    pass


# Delegation: the innermost suspended frame is where the throw lands, and its
# handler is the context even when an outer delegator is handling another.
def inner():
    try:
        raise KeyError("inner handler")
    except KeyError:
        try:
            yield
        except ValueError as e:
            print("delegated:", repr(e.__context__))


def outer():
    try:
        raise IndexError("outer handler")
    except IndexError:
        yield from inner()


it = outer()
next(it)
try:
    it.throw(ValueError("z"))
except StopIteration:
    pass


# A frame handling nothing falls through to what its awaiter is handling.
def bare():
    yield


def handling():
    try:
        raise KeyError("awaiter handler")
    except KeyError:
        try:
            yield from bare()
        except ValueError as e:
            print("fall-through:", repr(e.__context__))


it = handling()
next(it)
try:
    it.throw(ValueError("w"))
except StopIteration:
    pass

# Nothing handled anywhere: no context at all.
it = bare()
next(it)
try:
    it.throw(ValueError("v"))
except ValueError as e:
    print("none:", repr(e.__context__))
