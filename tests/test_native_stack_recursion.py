"""A high recursion limit still lets the interpreter unwind safely."""

import sys
import threading


def recurse():
    recurse()


def check_recursion(results):
    try:
        recurse()
    except RecursionError:
        results.append("recursion stopped")


results = []
old_limit = sys.getrecursionlimit()
old_stack = threading.stack_size()
try:
    sys.setrecursionlimit(100_000)
    check_recursion(results)
    threading.stack_size(128 * 1024)
    worker = threading.Thread(target=check_recursion, args=(results,))
    worker.start()
    worker.join()
finally:
    threading.stack_size(old_stack)
    sys.setrecursionlimit(old_limit)

assert results == ["recursion stopped", "recursion stopped"], results
print("deep recursion unwinds on both stacks")
