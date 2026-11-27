# Ordering comparisons that raise, with operands that die when they do.
#
# Two heap-corrupting bugs met here, and neither was visible without an
# allocation after the raise -- the damage was to malloc's free list, so the
# crash landed arbitrarily far away.
#
#   1. op_compare_op's identity fallback DECREFed both operands and then
#      raised.  eval_exception_unwind releases the frame's value stack from
#      above the slots the operands were VPOPped out of, so it decremented the
#      refcount word of memory malloc had already put on its tcache list --
#      overwriting the list's forward pointer.  `object() < object()`,
#      `range(1) < range(2)` and `int < str` all did it.
#
#   2. object_type_call built its instance with gc_alloc, which does not INCREF
#      the type it stamps into ob_type, while instance_dealloc DECREFs it.
#      object_type starts at refcount 1, so the first object() to be collected
#      handed &object_type -- a .data address -- to free().
#
# So every case below constructs its operands as temporaries, and every group
# is followed by allocation churn: without the churn the corruption is silent.


def churn():
    return len([[i, i] for i in range(300)])


def ordering(a, b, label):
    for op in ("<", "<=", ">", ">="):
        try:
            if op == "<":
                a() < b()
            elif op == "<=":
                a() <= b()
            elif op == ">":
                a() > b()
            else:
                a() >= b()
            print(label, op, "no error")
        except TypeError:
            print(label, op, "TypeError")
        except Exception as e:
            print(label, op, type(e).__name__)
    print(label, "churn", churn())


ordering(lambda: object(), lambda: object(), "object")
ordering(lambda: range(1), lambda: range(2), "range")
# (slice is left out: CPython orders slices as tuples and we raise -- once in the old bug list)
ordering(lambda: [1], lambda: {1}, "list/set")
ordering(lambda: {1: 2}, lambda: {3: 4}, "dict")
ordering(lambda: int, lambda: str, "type")
ordering(lambda: None, lambda: None, "None")
ordering(lambda: 1, lambda: "a", "int/str")
ordering(lambda: b"a", lambda: 1, "bytes/int")

# Bare temporaries of a static type, collected immediately: bug 2 on its own.
for _ in range(20):
    object()
print("after object() churn:", churn())

# And kept alive, then released together.
xs = [object() for _ in range(20)]
del xs
print("after del churn:", churn())
