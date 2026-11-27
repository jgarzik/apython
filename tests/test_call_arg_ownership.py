# CALL_PY_EXACT_ARGS moves each argument's stack reference INTO the callee's
# frame rather than incrementing it and releasing the slot afterwards.  That is
# only balanced because frame_free releases every localsplus entry and the
# handler's guards make it run unconditionally -- so every way a parameter can
# stop being the thing the caller pushed is a case here:
#
#   the callee rebinds it, deletes it, or returns it
#   the callee raises, so the frame is freed on the error path
#   the frame is captured -- by a traceback or by a closure  (sys._getframe is
#     NOT here: it leaks the frame's locals on its own, which predates this and
#     was recorded in the old bug list)
#   the argument's ONLY reference was the stack slot
#   both call shapes: a plain function and a bound method (self is an argument)
#
# A missed reference is a leak; an extra release is a use-after-free that
# surfaces somewhere else entirely.  gc.collect() and the identity checks are
# what make either visible from Python.

import gc
import sys


class Tracked:
    live = 0

    def __init__(self, tag):
        self.tag = tag
        Tracked.live += 1

    def __del__(self):
        Tracked.live -= 1

    def __repr__(self):
        return "T(%s)" % self.tag


def counts(fn, *a):
    gc.collect()
    before = Tracked.live
    out = fn(*a)
    gc.collect()
    return out, Tracked.live - before


def plain(x):
    return x.tag


def rebinds(x):
    x = "rebound"
    return x


def deletes(x):
    del x
    return "deleted"


def returns_it(x):
    return x


def raises(x):
    raise ValueError("boom:%s" % x.tag)


def five(a, b, c, d, e):
    return (a.tag, b.tag, c.tag, d.tag, e.tag)


class Holder:
    def __init__(self):
        self.kept = None

    def keep(self, x):
        self.kept = x
        return x.tag

    def drop(self, x):
        return x.tag


def temporary_argument():
    """The stack slot holds the ONLY reference: nothing else can keep it
    alive across the call, and nothing else will free it after."""
    out = []
    for i in range(200):
        out.append(plain(Tracked(i)))
    return out[0], out[-1]


def the_callee_rebinds():
    return [rebinds(Tracked(i)) for i in range(200)][0]


def the_callee_deletes():
    return [deletes(Tracked(i)) for i in range(200)][0]


def the_callee_returns_it():
    last = None
    for i in range(200):
        last = returns_it(Tracked(i))
    return last.tag, last is not None


def the_callee_raises():
    caught = 0
    for i in range(200):
        try:
            raises(Tracked(i))
        except ValueError:
            caught += 1
    return caught


def five_arguments():
    out = None
    for i in range(200):
        out = five(Tracked(i), Tracked(i), Tracked(i), Tracked(i), Tracked(i))
    return out


def a_bound_method_is_the_other_shape():
    h = Holder()
    out = None
    for i in range(200):
        out = h.drop(Tracked(i))
    return out, h.kept


def the_callee_keeps_it():
    h = Holder()
    for i in range(200):
        h.keep(Tracked(i))
    return h.kept.tag


def a_traceback_captures_the_frame():
    """frameobj_detach copies the fast locals out with a reference of their
    own, before frame_free walks them."""
    def inner(x):
        raise RuntimeError("%s" % x.tag)

    tbs = []
    for i in range(50):
        try:
            inner(Tracked(i))
        except RuntimeError:
            tbs.append(sys.exc_info()[2])
    return len(tbs), tbs[0] is not None


def a_fresh_callable_each_time():
    """The callable's slot is the ONE reference the handler still releases,
    and a callable built per call is the only way to see that it does: this
    closure holds the payload in a cell, so leaking the callable leaks the
    payload with it."""
    def make(t):
        def f(y):
            return t.tag + y
        return f

    out = 0
    for i in range(200):
        out = make(Tracked(i))(1)
    return out


def a_closure_over_the_parameter():
    def outer(x):
        def get():
            return x.tag
        return get

    gs = [outer(Tracked(i)) for i in range(100)]
    return gs[0](), gs[-1]()


def deep_recursion():
    def down(k, payload):
        if k == 0:
            return payload.tag
        return down(k - 1, payload)

    out = None
    for i in range(50):
        out = down(40, Tracked(i))
    return out


def an_argument_in_a_cycle():
    def take(x):
        return x.tag

    for i in range(100):
        t = Tracked(i)
        t.self = t                 # a cycle only the collector can break
        take(t)
    gc.collect()
    return "cycles collected"


for f in (temporary_argument, the_callee_rebinds, the_callee_deletes,
          the_callee_returns_it, the_callee_raises, five_arguments,
          a_bound_method_is_the_other_shape, the_callee_keeps_it,
          a_traceback_captures_the_frame, a_fresh_callable_each_time,
          a_closure_over_the_parameter, deep_recursion,
          an_argument_in_a_cycle):
    print(f.__name__, counts(f))
