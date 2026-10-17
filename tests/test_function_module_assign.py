# A function's __module__ is an attribute of its own once assigned, as in
# CPython: functools.wraps copies it, signal's Python-level functions set it,
# and it was read from the globals every time -- so the assignment landed in
# __dict__ and never came back.
import functools


def f():
    pass


print(f.__module__)
f.__module__ = "pkg.mod"
print(f.__module__, f.__dict__)
f.__module__ = None
print(f.__module__)
del f.__module__
print(f.__module__)


def wrapped():
    pass


wrapped.__module__ = "elsewhere"


@functools.wraps(wrapped)
def wrapper():
    pass


print(wrapper.__module__, wrapper.__name__, wrapper.__dict__ == {"__wrapped__": wrapped})
g = lambda: 0
g.__module__ = 7
print(g.__module__)
