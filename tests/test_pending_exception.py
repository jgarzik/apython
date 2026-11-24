# Ordinary code runs with no exception pending.  Each case here used to leave
# one behind -- returned a value over it, or dropped it -- so that it surfaced
# at some later, unrelated instruction, or at the end of the program.
# `make EXC_STRICT=1` turns every one of them into a trap at the instruction
# that left it.
import sys


# A trace function that raises on a 'line' event raises INTO the traced frame.
def tracer_line(frame, event, arg):
    if event == 'line' and frame.f_code.co_name == 'victim':
        raise RuntimeError("from the line event")
    return tracer_line


def victim():
    x = 1
    return x


sys.settrace(tracer_line)
try:
    victim()
    print("line: not raised")
except RuntimeError as e:
    print("line:", e)
finally:
    sys.settrace(None)


# ...and one that raises on 'return' replaces the value being returned.
def tracer_return(frame, event, arg):
    if event == 'return' and frame.f_code.co_name == 'victim':
        raise RuntimeError("from the return event")
    return tracer_return


sys.settrace(tracer_return)
try:
    r = victim()
    print("return: not raised", r)
except RuntimeError as e:
    print("return:", e)
finally:
    sys.settrace(None)
print(victim())


# list.__init__ over an iterable that raises part-way.
def gen():
    yield 1
    raise ValueError("mid-iteration")


l = [0]
try:
    l.__init__(gen())
    print("init: not raised")
except ValueError as e:
    print("init:", e)


# A __getattr__ that says "absent" by raising AttributeError, asked by code
# for which absent is an answer.
class Hook:
    def __getattr__(self, name):
        raise AttributeError("hook says no: " + name)


h = Hook()
print(isinstance(h, int))
match h:
    case Hook(q=1):
        print("matched")
    case _:
        print("no match")
print(hasattr(h, "q"), getattr(h, "q", 7))
d = {}
try:
    d.update(h)
except TypeError as e:
    print("update:", type(e).__name__)
try:
    h.q
except AttributeError as e:
    print("attr:", e)


# print() flushing what it had when a later argument's __str__ raises.
class BadStr:
    def __str__(self):
        raise ValueError("no str")


class Sink:
    def __init__(self):
        self.parts = []

    def write(self, s):
        self.parts.append(s)
        return len(s)

    def flush(self):
        pass


s = Sink()
try:
    print("before", BadStr(), "after", file=s)
except ValueError as e:
    print("print:", e, repr("".join(s.parts)))


# A finalizer and a weakref callback that run while an exception unwinds.
import weakref

log = []


class Fin:
    def __del__(self):
        log.append(len([c for c in "abc"]))     # ordinary code, during an unwind


class Target:
    pass


def unwinds():
    f = Fin()
    t = Target()
    r = weakref.ref(t, lambda ref: log.append(bool(ref() is None)))
    raise KeyError("unwinding past f and t")


try:
    unwinds()
except KeyError as e:
    print("unwind:", e)
print(log)
print("done")
