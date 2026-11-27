# An index too wide for one, and a key that is not an index at all.
#
# obj_as_index used to truncate through __gmpz_get_si, so `[1][2**70]`
# answered the first element -- a wrong ANSWER.  Refusing it left two
# wordings behind: CPython raises an IndexError naming the index rather than
# an OverflowError naming a C type, and every container names ITSELF and the
# key's type in the refusal.  Both are diffed against CPython here.

# CPython's compiler warns about a constant subscript that looks like a
# missing comma, and this one has no such channel yet -- once in the old bug list.
import warnings
warnings.simplefilter("ignore", SyntaxWarning)

CASES = [
 '[1,2][2**70]', '(1,)[2**70]', '"abc"[2**70]', 'b"abc"[2**70]',
 'bytearray(b"ab")[2**70]', 'memoryview(b"ab")[2**70]', '[1][-(2**70)]',
 '[1,2][1.5]', '(1,2)[1.5]', 'b"ab"[1.5]', '"ab"[1.5]',
 'bytearray(b"ab")[1.5]', 'memoryview(b"ab")[1.5]',
 '[1,2][None]', '[1,2]["x"]', '(1,2)[None]', '"ab"[None]', 'b"ab"[None]',
 'bytearray(b"ab")[None]', 'memoryview(b"ab")[None]',
 '[1,2][True]', '"abc"[True]', 'b"abc"[True]', 'bytearray(b"abc")[True]',
 '[1,2,3][1:2]', '"abc"[2**70:]', '[1,2,3][2**70:]',
 'chr(2**70)', 'chr(-2**70)',
]
for e in CASES:
    try:
        print(e, "->", repr(eval(e)))
    except BaseException as ex:
        print(e, "->", type(ex).__name__, ex)

x = [1, 2]
for e in ("x[1.5]=3", "x[None]=3", "del x[1.5]", "x[2**70]=1", "del x[2**70]",
          "x[0]=9", "del x[0]"):
    try:
        exec(e)
        print(e, "-> ok", x)
    except BaseException as ex:
        print(e, "->", type(ex).__name__, ex)

y = bytearray(b"abc")
for e in ("y[1.5]=3", "y[None]=3", "y[2**70]=1", "y[0]=65"):
    try:
        exec(e)
        print(e, "-> ok", y)
    except BaseException as ex:
        print(e, "->", type(ex).__name__, ex)
