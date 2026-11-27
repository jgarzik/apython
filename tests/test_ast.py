# `ast`, and the _ast module under it.
#
# apython has had a complete parser for a long time and no way to see what it
# produced: the arena is 32-byte records addressed by a u32 index, freed the
# moment a compile ends.  compile(src, name, mode, ast.PyCF_ONLY_AST) now
# walks it and hands back CPython's node classes.
#
# ast.dump is the oracle for nearly all of this on purpose: it is a total
# function of every node's _fields, so one diff covers the whole model -- the
# class names, the field names, the field ORDER, and the shape of every list.
#
# The positions are compared too, with include_attributes=True: all four of
# lineno, col_offset, end_lineno and end_col_offset.

import ast


def dump(tree, **kw):
    """ast.dump, with one CPython patch-release difference normalised away.

    A format spec that ends with a replacement field -- `f"{a:{w}}"` -- carried
    a trailing `Constant(value='')` in its JoinedStr up to CPython 3.12.3, and
    does not in 3.12.14; this parser reproduces the older shape, which is what
    the local python3 answers.  An empty piece says nothing either way, so both
    sides drop them and everything else is still compared exactly.
    """
    for node in ast.walk(tree):
        if isinstance(node, ast.JoinedStr):
            node.values = [v for v in node.values
                           if not (isinstance(v, ast.Constant)
                                   and isinstance(v.value, str)
                                   and v.value == "")]
    return ast.dump(tree, **kw)


EXPRS = [
    "1 + 2", "a - b * c", "x // y % z", "a ** b ** c", "a | b ^ c & d",
    "a << 1 >> 2", "a @ b", "-x", "+x", "~x", "not x", "a and b or c",
    "a < b <= c", "a is not b", "a not in b", "x if y else z",
    "lambda: 1", "lambda a: a", "lambda a, b=1, *c, d, e=2, **f: a",
    "lambda a, /, b, *, c: a",
    "(1, 2)", "[1, 2]", "{1, 2}", "{1: 2}", "{1: 2, **d}", "()", "[]", "{}",
    "f(1, 2, k=3, *a, **b)", "f()", "f(*a)", "f(**b)",
    "a.b.c", "a[1]", "a[1:2]", "a[1:2:3]", "a[::2]", "a[:]", "a[b, c]",
    "(x := 1)", "[*a, *b]", "{**a, **b}",
    "[i for i in r]", "[i for i in r if i]", "[i for i in r if i if j]",
    "{i for i in r}", "{i: j for i, j in r}", "(i for i in r)",
    "[i for a in b for i in a]",
    "f'{x}'", "f'{x!r}'", "f'{x!s}'", "f'{x!a}'", "f'{x:>10}'",
    "f'a{x}b{y}c'", "f''",
    "'a' 'b'", "b'xy'", "None", "True", "False", "...", "1.5", "1j", "0x10",
]

STMTS = [
    "pass", "break" if False else "x = 1", "x = y = 1", "x, y = 1, 2",
    "[x, y] = z", "x += 1", "x **= 2", "x: int = 1", "x: int",
    "del x", "del x, y",
    "def f():\n    return", "def f():\n    return 1",
    "raise", "raise E", "raise E from C", "assert x", "assert x, 'm'",
    "global a, b",
    "import os", "import os.path", "import os.path as p", "import a, b",
    "from a import b", "from a import b as c", "from a import (b, c)",
    "from . import b", "from ..a import b as c", "from a import *",
    "if x: pass", "if x: pass\nelse: pass",
    "if x: pass\nelif y: pass\nelse: pass",
    "while x: pass", "while x: pass\nelse: pass",
    "while x:\n    break\n    continue",
    "for i in r: pass", "for i in r: pass\nelse: pass",
    "for i, j in r: pass",
    "with a: pass", "with a as b: pass", "with a as b, c as d: pass",
    "with (a as b, c as d): pass",
    "try: pass\nexcept: pass", "try: pass\nexcept E: pass",
    "try: pass\nexcept (E, F) as e: pass",
    "try: pass\nexcept E as e: pass\nelse: pass\nfinally: pass",
    "try: pass\nfinally: pass",
    "try: pass\nexcept* E: pass",
    "def f(): pass", "def f(a, b=1, *c, d, **e): return a",
    "def f(a, /, b, *, c): pass", "def f(a: int, b: str = 'x'): pass",
    "@d\ndef f(): pass", "@d1\n@d2(x)\ndef f(): pass",
    "class C: pass", "class C(B): pass", "class C(B, metaclass=M): pass",
    "class C(*bases, **kw): pass", "@d\nclass C: pass",
    "async def f(): pass", "async def f():\n    await x",
    "async def f():\n    async for i in r: pass",
    "async def f():\n    async with a: pass",
    "async def f():\n    return [i async for i in r]",
    "def g():\n    yield", "def g():\n    yield 1", "def g():\n    yield from r",
    "def f():\n    nonlocal_placeholder = 1\n    def g():\n        nonlocal nonlocal_placeholder",
    "def f():\n    'doc'\n    pass",
    "match x:\n    case 1: pass",
    "match x:\n    case 'a' | 'b': pass",
    "match x:\n    case [1, 2]: pass",
    "match x:\n    case [1, *rest]: pass",
    "match x:\n    case (1, 2): pass",
    "match x:\n    case {'a': b}: pass",
    "match x:\n    case {'a': b, **r}: pass",
    "match x:\n    case C(): pass",
    "match x:\n    case C(1, k=2): pass",
    "match x:\n    case [1] as y: pass",
    "match x:\n    case None: pass",
    "match x:\n    case True: pass",
    "match x:\n    case _: pass",
    "match x:\n    case y if y > 1: pass",
    "match x:\n    case 1: pass\n    case 2: pass",
    # PEP 695.  The parser used to skip the brackets by counting them, so a
    # def carried no type parameters and `type X = int` was an Assign
    # indistinguishable from `X = int`.
    "type X = int", "type X[T] = list[T]",
    "type X[T: int, *Ts, **P] = dict[T, P]",
    "def f[T](x: T) -> T: return x", "def f[T: int](): pass",
    "def f[T: (int, str)](): pass", "def f[*Ts](): pass", "def f[**P](): pass",
    "def f[T, *Ts, **P](): pass", "async def f[T](): pass",
    "@d\ndef f[T](): pass",
    "class C[T]: pass", "class C[T](B, metaclass=M): pass",
    "class C[T: int, *Ts, **P]: pass",
]

print("=== expressions, in eval mode ===")
for src in EXPRS:
    print(repr(src), dump(ast.parse(src, mode="eval")))

print("=== statements, in exec mode ===")
for src in STMTS:
    print(repr(src), dump(ast.parse(src)))

print("=== the same expressions as statements ===")
for src in EXPRS[:20]:
    print(repr(src), dump(ast.parse(src)))

print("=== compile() takes the flag positionally and by keyword ===")
print(dump(compile("1+1", "<s>", "eval", ast.PyCF_ONLY_AST)))
print(dump(compile("1+1", "<s>", "eval", flags=ast.PyCF_ONLY_AST)))
print(type(compile("1+1", "<s>", "eval")).__name__)
print(ast.PyCF_ONLY_AST)

print("=== literal_eval ===")
for src in ["1", "-1", "1.5", "'s'", "b'b'", "True", "None", "...",
            "(1, 2)", "[1, [2]]", "{1: 2}", "{1, 2}", "1 + 2j", "-1 - 2j"]:
    print(repr(src), repr(ast.literal_eval(src)))
for bad in ["f()", "x", "1 if x else 2"]:
    try:
        ast.literal_eval(bad)
        print(repr(bad), "NO ERROR")
    except ValueError:
        print(repr(bad), "ValueError")

print("=== walk, iter_fields, iter_child_nodes ===")
tree = ast.parse("def f(a):\n    return a + 1\n")
print(sorted({type(n).__name__ for n in ast.walk(tree)}))
print([n for n, _ in ast.iter_fields(tree.body[0])])
print([type(n).__name__ for n in ast.iter_child_nodes(tree.body[0])])

print("=== NodeVisitor ===")


class Names(ast.NodeVisitor):
    def __init__(self):
        self.seen = []

    def visit_Name(self, node):
        self.seen.append((node.id, type(node.ctx).__name__))
        self.generic_visit(node)


v = Names()
v.visit(ast.parse("a = b + c[d]\nfor e in f: del g\n"))
print(v.seen)

print("=== the class model ===")
print(ast.AST._fields, ast.expr._fields)
print(ast.Name._fields, ast.Name._attributes)
print(ast.arguments._fields)
print(ast.FunctionDef._fields)
print(issubclass(ast.Name, ast.expr), issubclass(ast.expr, ast.AST))
print(issubclass(ast.Add, ast.operator), issubclass(ast.Load, ast.expr_context))
n = ast.Name("x", ast.Load())
print(n.id, type(n.ctx).__name__, sorted(n.__dict__))
try:
    ast.Name().id
except AttributeError:
    print("an unset field is an AttributeError")
# ast.get_docstring is not called here: it imports inspect for cleandoc, and
# inspect needs _imp.
print(ast.parse("'doc'\npass").body[0].value.value)

print("=== positions, on every node ===")
POS = [
    "x = a + 1", "a.b.c", "f(x, y)", "a[1:2]", "x if y else z",
    "a and b or c", "a < b < c", "[1, 2]", "{'k': v}", "-x",
    "def f(a, b=1):\n    return a\n",
    "class C(B):\n    x = 1\n",
    "if a:\n    b\nelse:\n    c\n",
    "for i in r:\n    pass\n",
    "while a:\n    b\n",
    "with a as b:\n    pass\n",
    "try:\n    a\nexcept E as e:\n    b\nfinally:\n    c\n",
    "lambda a: a + 1",
    "[i for i in r]",
    "x: int = 1",
    "x += 1",
    "import a.b as c",
    "from x import y",
    "assert a, b",
    "del a, b",
    "@d\ndef f(): pass\n",
    "a = (\n    1 +\n    2\n)\n",
    "def f():\n    return (a,\n            b)\n",
    "f(x for x in y)",
    "sum(i * 2 for i in r if i)",
    "(x for x in y)",
    "{i for i in r}",
    "{i: j for i, j in r}",
    "async def f():\n    async for i in r:\n        await g()\n",
    "async def f():\n    async with a as b:\n        pass\n",
    "try:\n    a\nexcept A:\n    b\nexcept B as e:\n    c\nelse:\n    d\n",
    "try:\n    a\nexcept* E:\n    b\n",
    "from . import x",
    "from ..p import a as b, c",
    "import a.b, c as d",
    "def f(a, /, b, *c, d=1, **e):\n    pass\n",
    "def f(a: int = 1, *, b: str) -> bool:\n    pass\n",
    "x = *a, *b",
    "a[b], c = d",
    "a[::2, ...]",
    "global g\nnonlocal_ = 1\n",
    "raise E('m') from f",
    "x = f'{a!r:>{w}} tail'",
    "x = 'a' 'b'",
    "match p:\n    case [1, *r] if r:\n        pass\n    case {'k': v, **w}:\n        pass\n    case C(a, b=2) | None:\n        pass\n    case _:\n        pass\n",
    "@a.b(c)\nclass C(B, metaclass=M):\n    pass\n",
    "yield_ = lambda: (yield)",
    "def f():\n    yield 1\n    x = yield from g()\n",
    "if a:\n    pass\nelif b:\n    pass\nelse:\n    pass\n",
    "while a:\n    break\nelse:\n    continue\n",
    "for i in r:\n    pass\nelse:\n    pass\n",
    "with (a as b, c as d):\n    pass\n",
    "x = a if b else c if d else e",
    "print(*a, **b)",
    "x = not a is not b",
    "x = ~-+1",
    "x = b'ab' b'cd'",
    "x = (\n)",
    "x = [\n    1,\n]",
]
for src in POS:
    print(repr(src), dump(ast.parse(src), include_attributes=True))

print("=== a syntax error is still a syntax error ===")
for bad in ["1 +", "def", "class 1:", "for x in: pass"]:
    try:
        ast.parse(bad)
        print(repr(bad), "NO ERROR")
    except SyntaxError as e:
        # Only the type: SyntaxError carries none of CPython's .msg,
        # .filename, .lineno or .offset attributes here -- once in the old bug list.
        print(repr(bad), type(e).__name__)

print("=== positions that a whole file finds and a snippet does not ===")
# Every one of these came out of diffing dump(include_attributes=True)
# over this repository's own lib/ and tests/ against CPython's.
WHOLE = [
    'x = """a\nb"""\n',
    'def f():\n    """Doc\n    over lines\n    """\n    return 1\n',
    "s = '''one\ntwo\nthree'''\n",
    'x = f"""val {1 +\n 2} end"""\n',
    'x = (a - b) | c\n',
    'y = (lambda: 1)()\n',
    'z = (a + b).bit_length()\n',
    'w = (a, b)[0]\n',
    'def g():\n    yield a, b\n',
    'def h():\n    yield from (a, b)\n',
    'from m import *\n',
    'q = f"{a} " "plain"\n',
    'r = ("one "\n     f"{two} "\n     "three")\n',
    'print(f"{x=}")\n',
    'print(f"{x = }")\n',
    'print(f"{x!r:>{w}}")\n',
    'a, *b = [1, 2, 3]\n',
    '[c, *d] = [1, 2]\n',
    '(e, *f), g = (1, 2), 3\n',
    'for h, *i in [[1, 2]]:\n    pass\n',
    'del a[0], b.c\n',
    'with (open("f") as x, open("g") as y):\n    pass\n',
]
for src in WHOLE:
    print(repr(src), dump(ast.parse(src), include_attributes=True))

# The context and operator nodes are shared, one instance each, as CPython's
# parser shares them.
tree = ast.parse("a, *b = c[d].e + f\n")
ctxs = [n.ctx for n in ast.walk(tree) if hasattr(n, "ctx")]
print("distinct ctx objects:", len(set(id(c) for c in ctxs)))
print("ctx kinds:", sorted(set(type(c).__name__ for c in ctxs)))

# CPython 3.12's AST nodes have object's repr, and say `ast`, not `_ast`.
print(repr(ast.parse("x = 1").body[0]).split(" object at ")[0])
print(ast.Assign.__module__, ast.AST.__module__, ast.Load.__module__)

print("=== mode='single' has a root of its own ===")
# CPython's is Interactive, whose body is a statement list exactly as Module's
# is; this answered Module.  What single mode ACCEPTS is a narrower grammar
# there than here -- `def f(): pass` without a trailing newline, and the empty
# string, are syntax errors in CPython and not here -- which was in the old bug list, so
# every case below is one both interpreters take.
for src in ["x = 1", "1 + 2", "def f(): pass\n", "if x:\n    pass\n",
            "x = 1; y = 2", "class C: pass\n", "while 0: pass\n"]:
    tree = ast.parse(src, mode="single")
    print(repr(src), type(tree).__name__, dump(tree))
print(dump(compile("x = 1", "<s>", "single", ast.PyCF_ONLY_AST),
               include_attributes=True))
print(type(ast.parse("x = 1")).__name__,
      type(ast.parse("x", mode="eval")).__name__)
# And it still COMPILES, as exec does.
_ns = {}
exec(compile("single_mode_result = 41 + 1", "<s>", "single"), _ns)
print(_ns["single_mode_result"])

print("=== unparse, over the same constructs ===")
# ast.unparse is a headline ast API and did not run at all until lib's
# contextlib stopped being a stand-in whose contextmanager was a class -- a
# class does not bind as a method, so `self.delimit(...)` inside the unparser
# lost its self.  The round trip is a second oracle over the whole node model:
# a field the parser fills in wrongly usually survives ast.dump and does not
# survive being written back out and re-parsed.
for src in EXPRS:
    print(repr(src), "->", ast.unparse(ast.parse(src, mode="eval")))
for src in STMTS:
    out = ast.unparse(ast.parse(src))
    print(repr(src), "->", repr(out))
    # And what it writes must parse back to the same tree.
    again = ast.unparse(ast.parse(out))
    if again != out:
        print("   NOT STABLE:", repr(again))

print("=== PEP 695, with every position ===")
# The bracket skipper accepted `def f[](): pass` and `def f[1, +]():` alike and
# interned nothing.  These check the grammar it did not have, and the
# positions: a TypeVarTuple starts at its `*`, not at the name.
for src in ["def f[T, *Ts, **P](x): pass", "class C[T: (int, str)]: pass",
            "type X[T: int] = list[T]", "type X = int"]:
    print(repr(src), dump(ast.parse(src), include_attributes=True))

for src in ["def f[](): pass", "def f[1](): pass", "class C[T,,]: pass",
            "type X[] = int", "def f[T:](): pass", "def f[*](): pass",
            "def f[**](): pass", "class C[T: ]: pass", "type X = ",
            "def f[T](: pass", "class C[T: pass"]:
    try:
        ast.parse(src)
        print(repr(src), "PARSED")
    except SyntaxError:
        print(repr(src), "SyntaxError")

# A trailing comma is allowed, and `type` stays a soft keyword.
for src in ["def f[T,](): pass", "class C[*Ts,]: pass", "type X[T,] = T",
            "type = 1", "type(x)", "type.mro", "x = type"]:
    print(repr(src), dump(ast.parse(src)))
