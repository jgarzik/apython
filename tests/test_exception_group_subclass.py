# A SUBCLASS of ExceptionGroup, split by `except*`.
#
# `except*` splits a group by constructing one of the group's OWN type, so a
# subclass reaches the group constructor.  That constructor allocated with the
# plain allocator, while a subclass of any exception type is given a dealloc
# that frees through the collector -- so the block went back sixteen bytes
# below where it came from, and `except*` over a subclassed group was a
# segfault.  It is why CPython's test_except_star and test_exception_group both
# died here.
#
# The same subclass had also lost the group's own slots to the generic
# exception ones, so `.exceptions` did not answer and the tuple behind it was
# never released.
#
# The split halves are printed by CONTENT rather than by type: apython builds
# them from the group's own type where CPython's default derive() builds a
# plain ExceptionGroup, which is a separate divergence recorded in the old bug list.

import gc


class MyEG(ExceptionGroup):
    pass


def raiser():
    raise MyEG("m", [ValueError(1), TypeError(2)])


for i in range(5):
    try:
        raiser()
    except* ValueError as e:
        print("V", isinstance(e, ExceptionGroup), [repr(x) for x in e.exceptions])
    except* TypeError as e:
        print("T", isinstance(e, ExceptionGroup), [repr(x) for x in e.exceptions])

# The split halves stay usable after the group they came from is gone, which is
# what the early free destroyed.
kept = []
try:
    raiser()
except* ValueError as e:
    kept.append(e)
except* TypeError as e:
    kept.append(e)

gc.collect()
for g in kept:
    print("kept", g.message, [repr(x) for x in g.exceptions])

# A group built and dropped without ever being raised goes through the same
# constructor and the same dealloc.
for i in range(5):
    g = MyEG("m", [ValueError(1), TypeError(2), ValueError(3)])
    print("built", g.message, len(g.exceptions))
    del g
del kept
gc.collect()

# A plain group is built by the same constructor and freed by the same dealloc.
for i in range(5):
    try:
        raise ExceptionGroup("plain", [KeyError("k"), OSError("o")])
    except* KeyError as e:
        print("K", [repr(x) for x in e.exceptions])
    except* OSError as e:
        print("O", [repr(x) for x in e.exceptions])
gc.collect()
print("done")
