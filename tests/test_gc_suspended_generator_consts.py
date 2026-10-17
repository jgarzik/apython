# A generator suspended inside a try/finally, in a namespace that is cyclic
# garbage together with the code the generator runs.
#
# The collector clears every object in the garbage set, and closing the
# generator -- which runs its finally -- happens partway through that.  Code
# objects and tuples used to have a tp_clear: code_clear NULLed co_consts and
# tuple_clear emptied the co_consts tuple.  The generator's frame keeps its
# code alive, so when the close re-entered eval_frame it loaded co_consts as
# NULL and segfaulted; with only the tuple emptied, LOAD_CONST read freed
# strings and the finally printed some other string.  CPython clears neither
# -- both are immutable, so a cycle through one always runs through something
# else too.  Found as a segfault in test_generators' doctests.

import gc


def collect_namespace(src):
    code = compile(src, "<cycle>", "exec")
    ns = {}
    exec(code, ns)
    ns["ns"] = ns           # the namespace is garbage, with the code in it
    del code, ns
    return gc.collect() > 0


print("collected", collect_namespace("""
def g():
    try:
        yield 1
    finally:
        print("finally ran", (1, 2), 3.5)
it = g()
next(it)
"""))

print("collected", collect_namespace("""
def inner():
    try:
        yield "a"
        yield "b"
    finally:
        print("inner finally", ("x", "y"))
def outer():
    try:
        for v in inner():
            yield v
    finally:
        print("outer finally", ("p", "q"))
it = outer()
next(it)
"""))

print("done")
