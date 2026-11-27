# zip() over iterables of different lengths releases the round it could not
# finish exactly once.
#
# zip_iternext builds the result tuple with tuple_new, which zero-fills it,
# and stores each item as its iterator yields one.  When a LATER iterator is
# the one that runs out, the partial-cleanup path DECREF'd the items already
# stored and then released the tuple -- and tuple_dealloc walks the same slots
# and releases them again.  Every element of the longer iterable that landed
# in the last, incomplete round lost a reference it still had, and the object
# was freed under whatever still pointed at it.
#
# It needs the SECOND iterable to be the short one: with the first exhausted,
# nothing has been stored yet and the double release has nothing to bite.

import gc


def fresh(prefix, n):
    # Built at run time so the strings are not the .pyc's interned constants:
    # an over-release of one of those is invisible.
    return ["".join([prefix, str(i), "-" * 12]) for i in range(n)]


a = fresh("x", 6)
b = fresh("p", 2)
print(list(zip(a, b)))
gc.collect()
print(a)
print(b)

# The same with three iterables, exhausting at each position in turn.
for short in range(3):
    lists = [fresh(c, 5) for c in "abc"]
    lists[short] = fresh("s", 2)
    got = list(zip(*lists))
    gc.collect()
    print(short, got)
    print(short, [x[0] for x in lists])

# Generators, so the iterators are not list iterators.
def gen(prefix, n):
    for i in range(n):
        yield "".join([prefix, str(i), "-" * 12])


print(list(zip(gen("g", 4), gen("h", 1))))
gc.collect()

# strict= takes the same exit before it raises.  The wording of its message
# is still ours rather than CPython's, so only the fact of the ValueError is
# compared here; the old bug list carried the difference.
for lengths in ((4, 1), (1, 4), (3, 3)):
    try:
        list(zip(fresh("m", lengths[0]), fresh("n", lengths[1]), strict=True))
    except ValueError:
        print("strict ValueError", lengths)
    else:
        print("strict ok", lengths)
gc.collect()

# Equal lengths, and the empty cases, still behave.
print(list(zip(fresh("q", 3), fresh("r", 3))))
print(list(zip([], [1, 2])), list(zip([1, 2], [])), list(zip()))
print(list(zip("ab", "cde")), list(zip(range(3), "xy", [7, 8, 9])))

# Hammer it: a survivor whose refcount went negative shows up as a crash in
# the collector rather than here.
for i in range(300):
    keep = fresh("k", 4)
    list(zip(keep, fresh("s", 1)))
    if i % 50 == 0:
        gc.collect()
    assert keep[1].startswith("k1"), keep
gc.collect()
print("hammered", keep)
print("done")
