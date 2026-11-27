# An exception's instance dict is exc_dict, and the type has to SAY so.
#
# The static exception types left tp_dictoffset at zero, and type_from_parts
# then treated an exception base like any other builtin with a fixed header:
# it put a second dict slot at the base's tp_basicsize and grew tp_basicsize
# by a word.  Every exception constructor allocates exactly
# PyExceptionObject_size regardless, so that offset pointed one word off the
# END of the object -- and obj_generic_attr and object.__getstate__, which
# both go through tp_dictoffset, read and WROTE there.
#
# With the offset set, the generic machinery finds the same dict exc_getattr
# and exc_setattr have always used, and a subclass inherits it rather than
# inventing a second one.  CPython's test_mailbox died on the read.

import gc


class E(Exception):
    pass


e = E("x")
e.extra = 42
e.other = ["a", "b"]
print(e.__dict__, e.args, e.extra, e.other)
print(e.__getstate__())
print(sorted(vars(e).items()))

# The base types themselves.
z = Exception("z")
z.w = 1
print(z.__getstate__(), z.__dict__, z.w)
print(Exception("y").__getstate__(), Exception("y").__dict__)
print(ValueError().__getstate__(), KeyError("k").__dict__)

# Deeper subclasses, and one with an __init__ of its own.
class F(E):
    def __init__(self, a, b):
        Exception.__init__(self, a, b)
        self.a = a
        self.b = b


f = F(1, 2)
print(f.args, f.a, f.b, sorted(f.__dict__.items()), f.__getstate__())


class G(F):
    pass


g = G(3, 4)
g.c = 5
print(g.args, sorted(g.__dict__.items()))

# Setting, reading and deleting through the generic paths.
h = E("h")
h.one = 1
h.two = 2
del h.one
print(sorted(h.__dict__.items()), hasattr(h, "one"), hasattr(h, "two"))
try:
    h.missing
except AttributeError as a:
    print("AttributeError")

# Assigning __dict__ wholesale.
i = E("i")
i.__dict__ = {"set": "wholesale"}
print(i.__dict__, i.set)

# An exception group subclass keeps its own fields AND a dict.
class GE(ExceptionGroup):
    pass


ge = GE("m", [ValueError(1)])
ge.tag = "grouped"
print(ge.message, [type(x).__name__ for x in ge.exceptions], ge.tag, ge.__dict__)

# OSError, whose constructor rewrites its own class.  Its four named
# attributes live in the instance dict here and in C fields in CPython, so
# only the attributes themselves are compared; the old bug list carried the rest.
oe = OSError(2, "no such file")
oe.note = "extra"
print(oe.errno, oe.strerror, oe.note, oe.note in str(oe.__dict__))

# Raised, caught, and still holding everything.
try:
    raise F(7, 8)
except F as caught:
    caught.during = True
    print(caught.args, sorted(caught.__dict__.items()))

# Hammered, so an over-write past the object shows up.
keep = []
for i in range(400):
    x = E("e%d" % i)
    x.n = i
    x.pad = "-" * 24
    keep.append(x)
    if i % 100 == 0:
        gc.collect()
gc.collect()
print(len(keep), keep[137].n, keep[137].args, keep[399].pad)
print("done")
