# What a frame object says about where its frame is.
#
# f_lineno and f_lasti were read from PyFrame.instr_ptr, which is written only
# when a generator YIELDS -- so every running frame answered lineno 0 and
# lasti -1, and anything that reports a caller's position (logging, warnings,
# a traceback built by hand) had nothing to report.  The innermost frame's
# position is the interpreter's own IP; an outer one is where it was when it
# made the call that leads here.
#
# The frame object is a SNAPSHOT, so f_lineno is where the frame was when
# sys._getframe() ran -- CPython's is a live view and answers where the frame
# is when the attribute is READ.  Every case here reads it on the same line,
# where the two agree; the old bug list carried the difference.

import sys


def where():
    return sys._getframe(1).f_lineno


def inner():
    return sys._getframe().f_lineno, where()


def outer():
    a = inner()
    return a, sys._getframe().f_lineno


print("=== the running frame ===")
print(sys._getframe().f_lineno)
print(sys._getframe().f_lineno)
print(sys._getframe().f_lasti >= 0)
print(sys._getframe().f_code.co_name)

print("=== a frame that is not the innermost ===")
print(inner())
print(outer())
print(where())

print("=== through a chain of calls ===")


def a3():
    # Not a comprehension: this compiler does not inline one the way CPython
    # 3.12 does, so it would add a frame and shift every depth by one.
    out = []
    out.append(sys._getframe(0).f_lineno)
    out.append(sys._getframe(1).f_lineno)
    out.append(sys._getframe(2).f_lineno)
    return out


def a2():
    return a3()


def a1():
    return a2()


print(a1())

print("=== a generator's frame ===")


def gen():
    yield sys._getframe().f_lineno
    yield sys._getframe().f_lineno


print(list(gen()))

print("=== f_back walks the same chain ===")


def deep():
    f = sys._getframe()
    names = []
    while f is not None:
        names.append((f.f_code.co_name, f.f_lineno > 0))
        f = f.f_back
    return names


print(deep())
print("done")

# f_lasti and tb_lasti are BYTE offsets into co_code, as CPython's are; the
# line and column tables are indexed in code units, and the two were being
# reported in those.  A traceback's is exact -- it names the instruction that
# raised -- where a frame's is a snapshot taken during the call, so only its
# unit is comparable.
print("=== lasti ===")


def raises():
    raise ValueError("for the traceback")


try:
    raises()
except ValueError:
    tb = sys.exc_info()[2]
    while tb.tb_next is not None:
        tb = tb.tb_next
    # Not the value: the offset depends on which compiler produced the
    # bytecode, and this file is run from source as well as from a .pyc.
    print("tb_lasti in range:", 0 < tb.tb_lasti < 200)
    print("frame agrees:", tb.tb_frame.f_lasti == tb.tb_lasti)
    print("even:", tb.tb_lasti % 2 == 0)
    print("line", tb.tb_lineno)
print("f_lasti even:", sys._getframe().f_lasti % 2 == 0)
print("lasti done")
