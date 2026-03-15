# itertools - adapted from CPython for apython

# chain is a native builtin (registered in __builtins__)
# Pull it into module namespace so 'from itertools import chain' works
chain = chain


def islice(iterable, *args):
    """islice(iterable, stop) or islice(iterable, start, stop[, step])"""
    if len(args) == 1:
        start, stop, step = 0, args[0], 1
    elif len(args) == 2:
        start, stop, step = args[0], args[1], 1
    elif len(args) == 3:
        start, stop, step = args
    else:
        raise TypeError("islice expected 2-4 arguments")

    it = iter(iterable)
    # Skip start elements
    for i in range(start):
        try:
            next(it)
        except StopIteration:
            return

    count = 0
    for i, item in enumerate(it):
        if stop is not None and start + i >= stop:
            return
        if i % step == 0:
            yield item


def count(start=0, step=1):
    """count(start=0, step=1) --> count object
    Return a count object whose .__next__() method returns consecutive values."""
    n = start
    while True:
        yield n
        n += step


def repeat(obj, times=None):
    """repeat(object [,times]) -> create an iterator which returns the object
    for the specified number of times."""
    if times is None:
        while True:
            yield obj
    else:
        for i in range(times):
            yield obj


def cycle(iterable):
    """cycle(iterable) --> cycle object
    Return elements from the iterable until it is exhausted.
    Then repeat the sequence indefinitely."""
    saved = []
    for element in iterable:
        yield element
        saved.append(element)
    while saved:
        for element in saved:
            yield element


def accumulate(iterable, func=None, initial=None):
    """accumulate(iterable[, func, initial]) --> accumulate object"""
    it = iter(iterable)
    if initial is not None:
        total = initial
    else:
        try:
            total = next(it)
        except StopIteration:
            return
    yield total
    for element in it:
        if func is None:
            total = total + element
        else:
            total = func(total, element)
        yield total


def starmap(function, iterable):
    """starmap(function, iterable) --> starmap object"""
    for args in iterable:
        yield function(*args)


def product(*iterables, repeat=1):
    """product(*iterables, repeat=1) --> product object"""
    pools = [list(pool) for pool in iterables] * repeat
    result = [[]]
    for pool in pools:
        result = [x + [y] for x in result for y in pool]
    for prod in result:
        yield tuple(prod)
