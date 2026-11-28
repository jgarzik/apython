"""Regression test for CALL_FUNCTION_EX materialisation + exception unwind.

When *args is materialised to a tuple (e.g. a list under free-threading, or
any non-tuple iterable), op_call_function_ex decrefs the original iterable.
If the callee then raises via non-local unwind (e.g. getattr on a dead weakref
proxy, or non-callable), eval_exception_unwind must see the replacement tuple
in the value-stack slot rather than double-DECREFing the freed original.
"""
import gc
import threading
import weakref


class Dummy:
    pass


t = threading.Thread(target=lambda: None)
t.start()
t.join()

for _ in range(20):
    obj = Dummy()
    p = weakref.proxy(obj)
    del obj
    gc.collect()
    args = [p, "missing"]
    try:
        getattr(*args)
    except ReferenceError:
        pass
    del args
    # Allocate enough lists to pop the entire per-thread list freelist
    xs = [[] for _ in range(80)]
    del xs

# Also test non-list iterables and non-callable targets
for _ in range(10):
    it_args = (x for x in (1, 2))
    not_callable = 42
    try:
        not_callable(*it_args)
    except TypeError:
        pass
    try:
        not_callable(*[1, 2], **{1: 2})
    except TypeError:
        pass

print("call_ex_unwind: ok")
