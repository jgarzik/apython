# co_positions() and co_lines(), the two side tables the stdlib walks.
#
# co_positions() answered (line, line, None, None) for every code unit, on
# the ground that this tree recorded lines and not columns.  That stopped
# being true when the caret renderer was written: code_addr2location decodes
# the start and end column out of the same PEP 657 table, and
# src/traceback.asm has been drawing carets from them ever since.  So
# CPython's own traceback.py -- which any program using the real stdlib
# reaches -- drew none, while apython's renderer drew them correctly from the
# same data.
#
# co_lines() did not exist, and dis, trace and inspect all iterate it.


def f(a, b):
    c = a + b
    if c > 10:
        return c * 2
    return c


def g():
    return [x for x in range(3)]


for fn in (f, g):
    code = fn.__code__
    print("---", code.co_name, "---")
    print("positions:", list(code.co_positions()))
    print("lines    :", list(code.co_lines()))
    print("firstline:", code.co_firstlineno)

# A line-table run is a run: consecutive code units on one line are one entry.
print("runs are runs:", len(list(f.__code__.co_lines())) <
      f.__code__.co_code.__len__() // 2)

# Deliberately NOT compile(): a code object built here comes from apython's
# own compiler, whose line table differs from CPython's in ways the old bug list
# recorded -- a module's leading RESUME and the implicit `return None` at the
# end of a body.  Those are the compiler's to answer for, not these two
# readers'.  Everything above comes from the .pyc, so it is CPython's table
# being decoded.

# co_code, which dis reads and which lives inside the code object rather
# than behind a pointer.
print("co_code:", type(f.__code__.co_code).__name__,
      len(f.__code__.co_code) == f.__code__.co_code.__len__(),
      len(f.__code__.co_code) % 2 == 0)
print("tables:", type(f.__code__.co_linetable).__name__,
      type(f.__code__.co_exceptiontable).__name__)

# Both are methods, and both refuse arguments.
try:
    f.__code__.co_lines(1)
except TypeError as e:
    print("co_lines arity:", type(e).__name__)
try:
    f.__code__.co_positions(1)
except TypeError as e:
    print("co_positions arity:", type(e).__name__)

# Bound, so they can be taken off the object and called later.
m = f.__code__.co_lines
print("bound:", list(m()) == list(f.__code__.co_lines()))
