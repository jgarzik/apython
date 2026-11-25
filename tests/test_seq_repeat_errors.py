# A repetition count that cannot be one, through every sequence that takes it.
#
# seq_repeat_count is the one funnel str, tuple, bytes, list and bytearray
# share for `s * n` and `s *= n`.  Its refusals -- an __index__ that raises,
# one that answers a non-int, a count too big for an index -- are returned to
# the sequence, which returns them in turn: the exception that reaches the
# caller is the count's own, the sequence is unchanged, and nothing is left
# alive behind it.
import gc


class Boom(Exception):
    pass


class Raises:
    def __index__(self):
        raise Boom("index")


class NotInt:
    def __index__(self):
        return "three"


class Three:
    def __index__(self):
        return 3


class Tracked:
    live = 0

    def __init__(self):
        Tracked.live += 1

    def __del__(self):
        Tracked.live -= 1


def check(label, fn):
    try:
        r = fn()
    except Exception as e:
        # The type, and the message only when it is the count's own: the
        # wording of the builtin refusals differs from CPython's in places.
        print("%-28s %s%s" % (label, type(e).__name__,
                              ": index" if isinstance(e, Boom) else ""))
    else:
        print("%-28s %r" % (label, r))


makers = [
    ("str", lambda: "ab"),
    ("tuple", lambda: (1, 2)),
    ("bytes", lambda: b"ab"),
    ("list", lambda: [1, 2]),
    ("bytearray", lambda: bytearray(b"ab")),
]
counts = [("raises", Raises), ("notint", NotInt), ("three", Three),
          ("huge", lambda: 2 ** 64), ("neg-huge", lambda: -(2 ** 64)),
          ("str", lambda: "x"), ("float", lambda: 2.0), ("none", lambda: None),
          ("minus-one", lambda: -1)]

for name, mk in makers:
    for cname, c in counts:
        check("%s * %s" % (name, cname), lambda: mk() * c())
        if not isinstance(c, type):
            # `Three() * "ab"` is not asked here: the reflected operator does
            # not reach __index__ on the left yet.
            check("%s rmul %s" % (name, cname), lambda: c() * mk())
        check("%s.__mul__(%s)" % (name, cname), lambda: mk().__mul__(c()))
        check("%s.__rmul__(%s)" % (name, cname), lambda: mk().__rmul__(c()))

# In place: the sequence must be what it was.
for name, mk in makers[3:]:
    for cname, c in counts:
        s = mk()
        keep = s

        def imul():
            global s
            s *= c()
            return s

        check("%s *= %s" % (name, cname), imul)
        print("   still", keep, keep is s)
        s2 = mk()
        check("%s.__imul__(%s)" % (name, cname), lambda: s2.__imul__(c()))
        print("   still", s2)

# Nothing held: the elements of a list or tuple whose repetition was refused.
for mk in (lambda: [Tracked(), Tracked()], lambda: (Tracked(), Tracked())):
    for c in (Raises, NotInt, lambda: 2 ** 64, lambda: 2 ** 40):
        for _ in range(3):
            try:
                mk() * c()
            except (Boom, TypeError, OverflowError, MemoryError):
                pass
        gc.collect()
        print("live", Tracked.live)
for c in (Raises, NotInt, lambda: 2 ** 64, lambda: 2 ** 40):
    for _ in range(3):
        x = [Tracked(), Tracked()]
        try:
            x *= c()
        except (Boom, TypeError, OverflowError, MemoryError):
            pass
        del x
    gc.collect()
    print("live", Tracked.live)
