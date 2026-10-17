"""compile() of an AST object rather than of source text.

`compile(tree, filename, mode)` is how every tool that rewrites Python gets
code back out: pytest's assertion rewriting parses a test file, rewrites each
`assert` and compiles the tree; its `-k`/`-m` expressions build an
`ast.Expression` by hand and compile that.  Until this existed both were a
TypeError, "compile() arg 1 must be a string, bytes or AST object".

lib/_ast_load.py folds the node objects back into the parser's raw tuples and
src/compiler/astload.asm rebuilds the parse arena from them, so a tree goes
through the same symbol table, code generator and assembler as source does.
Most of what is checked here is therefore that a tree compiles to code that
BEHAVES as the source does, and that a malformed tree is the TypeError or
ValueError CPython's validator gives rather than anything worse.
"""

import ast
import sys
import types


def run(src, name="<ast>"):
    """Execute src by way of its tree, with print() visible."""
    tree = ast.parse(src)
    code = compile(tree, name, "exec")
    ns = {"__name__": "sample"}
    exec(code, ns)
    return ns


def err(label, fn):
    try:
        fn()
    except Exception as e:
        print(label, type(e).__name__, e)
    else:
        print(label, "no error")


# --- a broad round trip ------------------------------------------------------

SAMPLE = r'''
import functools
from collections import namedtuple as nt

def deco(tag):
    def wrap(fn):
        @functools.wraps(fn)
        def inner(*a, **k):
            return (tag, fn(*a, **k))
        return inner
    return wrap

@deco("d")
def f(a, b=2, /, c=3, *rest, d, e=5, **kw):
    return a + b + c + sum(rest) + d + e + len(kw)

print("call", f(1, d=4), f(1, 2, 3, 4, 5, d=6, z=7))

class Base:
    count = 0
    def __init__(self, v):
        self.__v = v
        Base.count += 1
    def value(self):
        return self.__v
    @property
    def doubled(self):
        return self.__v * 2

class Child(Base):
    def value(self):
        return super().value() + 100

c = Child(5)
print("class", c.value(), c.doubled, Base.count, hasattr(c, "_Base__v"))

print("comps", [x * y for x in range(4) if x for y in (1, 2)],
      {k: v for k, v in zip("ab", (1, 2))}, sorted({n % 3 for n in range(9)}),
      sum(n for n in range(5)))

def gen():
    x = yield 1
    yield x * 2
    yield from range(3)

g = gen()
print("gen", next(g), g.send(10), list(g))

def handlers(v):
    try:
        if v == 0:
            raise ValueError("zero")
        elif v == 1:
            raise KeyError(v)
        return 1 / v
    except ValueError as e:
        return "value:" + str(e)
    except (KeyError, TypeError):
        return "key"
    else:
        pass
    finally:
        print("finally", v)

print("try", handlers(0), handlers(1), handlers(4))

def star(n):
    try:
        raise ExceptionGroup("g", [ValueError(n), TypeError(n)])
    except* ValueError as eg:
        print("star value", [str(x) for x in eg.exceptions])
    except* TypeError:
        print("star type")

star(7)

class Ctx:
    def __enter__(self):
        print("enter")
        return self
    def __exit__(self, *exc):
        print("exit", exc[0] is not None)
        return True

with Ctx() as a, Ctx():
    raise RuntimeError("swallowed")

def matcher(v):
    match v:
        case 0 | None:
            return "zero-or-none"
        case [x, *rest] if x > 0:
            return "seq %d %d" % (x, len(rest))
        case {"k": val, **others}:
            return "map %r %r" % (val, others)
        case complex(real=r) as z:
            return "complex %r" % r
        case str() | bytes():
            return "text"
        case _:
            return "other"

print("match", matcher(0), matcher([3, 4, 5]), matcher({"k": 1, "j": 2}),
      matcher(2j), matcher("s"), matcher(1.5))

import asyncio
async def agen():
    for i in range(3):
        yield i

async def amain():
    out = [i async for i in agen()]
    async with Actx():
        pass
    await asyncio.sleep(0)
    return out

class Actx:
    async def __aenter__(self):
        print("aenter")
    async def __aexit__(self, *a):
        print("aexit")

print("async", asyncio.run(amain()))

name, width = "pi", 8
print("fstr", f"{name!r:>{width}}|{3.14159:.2f}|{width=}|{'x' + 'y'}")
print("lambda", (lambda x, *, y=2: x * y)(5), list(map(lambda s: s.upper(), "ab")))

def walrus(xs):
    return [y for x in xs if (y := x * 2) > 2]

print("walrus", walrus([1, 2, 3]))

def scopes():
    total = 0
    def bump():
        nonlocal total
        total += 1
    bump(); bump()
    global G
    G = total
    return total

print("scopes", scopes(), G)

class Box[T]:
    def __init__(self, item: T):
        self.item = item

def first[S](xs: list[S]) -> S:
    return xs[0]

type Pair[K] = tuple[K, K]
print("pep695", Box(3).item, first([9, 8]), Box.__type_params__, Pair.__value__)

x: int = 5
print("annotations", __annotations__, x)
del x
a = b = [1, 2, 3]
a[1:2] = [7, 8]
q, *r = a
print("assign", a, q, r, b is a)
n = 10
n //= 3; n **= 2; n <<= 1
print("augassign", n, -n, ~n, not n, 1 < n <= 18 != 3)
assert n == 18, "n"
for i in range(3):
    if i == 1:
        continue
    print("loop", i)
else:
    print("loop else")
while True:
    break
print("done", nt("P", "x y")(1, 2))
'''

print("== round trip")
run(SAMPLE)

# The same tree, compiled twice by name keywords as pytest does.
code = compile(ast.parse("x = 6 * 7"), filename="<kw>", mode="exec")
ns = {}
exec(code, ns)
print("keywords", ns["x"], code.co_filename)

# --- trees nobody parsed -----------------------------------------------------
print("== hand-built")
tree = ast.Module(
    body=[
        ast.Assign(targets=[ast.Name("y", ast.Store())],
                   value=ast.BinOp(ast.Constant(40), ast.Add(),
                                   ast.Constant(2))),
        ast.Expr(ast.Call(ast.Name("print", ast.Load()),
                          [ast.Constant("hand"), ast.Name("y", ast.Load())],
                          [ast.keyword("sep", ast.Constant(":"))])),
        ast.FunctionDef(
            name="sq",
            args=ast.arguments(posonlyargs=[], args=[ast.arg("v")],
                               kwonlyargs=[], kw_defaults=[], defaults=[]),
            body=[ast.Return(ast.BinOp(ast.Name("v", ast.Load()), ast.Mult(),
                                       ast.Name("v", ast.Load())))],
            decorator_list=[]),
        ast.Expr(ast.Call(ast.Name("print", ast.Load()),
                          [ast.Call(ast.Name("sq", ast.Load()),
                                    [ast.Constant(9)], [])], [])),
    ],
    type_ignores=[])
ast.fix_missing_locations(tree)
exec(compile(tree, "<hand>", "exec"), {})

# Constants of every kind a tree may carry, including the ones source spells
# with an operator or not at all.
consts = ast.Expression(ast.Tuple(
    [ast.Constant(v) for v in (None, True, ..., 3, -4, 2.5, 1j, "s", b"b",
                               (1, (2, "t")), frozenset({5}))],
    ast.Load()))
ast.fix_missing_locations(consts)
print("consts", eval(compile(consts, "<c>", "eval")))

print("eval", eval(compile(ast.parse("[n * 2 for n in range(4)]",
                                     mode="eval"), "<e>", "eval")))

# What pytest's -k builds: names it resolves itself, through a mapping.
expr = ast.Expression(ast.BoolOp(ast.Or(), [
    ast.Name("$a", ast.Load()),
    ast.UnaryOp(ast.Not(), ast.Name("$b", ast.Load()))]))
ast.fix_missing_locations(expr)
code = compile(expr, filename="<pytest match expression>", mode="eval")


class Matcher:
    """pytest's MatcherAdapter: a mapping that is not a dict."""

    def __getitem__(self, key):
        return key == "$a"

    def __iter__(self):
        raise NotImplementedError

    def __len__(self):
        raise NotImplementedError


print("pytest-k", eval(code, {"__builtins__": {}}, Matcher()))

# "single" displays a bare expression, as a REPL does.
print("single:")
inter = ast.Interactive(body=[ast.Expr(ast.BinOp(ast.Constant(6),
                                                 ast.Mult(),
                                                 ast.Constant(7)))])
ast.fix_missing_locations(inter)
exec(compile(inter, "<i>", "single"), {})

# --- a rewriting transformer, the shape of pytest's assert rewrite -----------
print("== transformer")


class AssertRewriter(ast.NodeTransformer):
    """Each `assert t` becomes: record t's value, then assert on the record."""

    def visit_Assert(self, node):
        tmp = ast.Name("@rec", ast.Store())
        save = ast.copy_location(ast.Assign([tmp], node.test), node)
        load = ast.copy_location(ast.Name("@rec", ast.Load()), node)
        note = ast.copy_location(ast.Expr(ast.Call(
            ast.Name("print", ast.Load()),
            [ast.Constant("checking line"), ast.Constant(node.lineno)], [])),
            node)
        msg = ast.Call(ast.Name("repr", ast.Load()), [load], [])
        check = ast.copy_location(ast.Assert(load, msg), node)
        out = [note, save, check]
        for n in out:
            ast.fix_missing_locations(n)
        return out


src = """
def checked(v):
    assert v > 0
    assert v < 10
    return v
print("ok", checked(3))
checked(42)
"""
tree = AssertRewriter().visit(ast.parse(src))
ns = {"__name__": "rewritten"}
try:
    exec(compile(tree, "<rewritten>", "exec", dont_inherit=True), ns)
except AssertionError as e:
    tb = e.__traceback__
    while tb.tb_next:
        tb = tb.tb_next
    print("assert failed", e, "at line", tb.tb_lineno, tb.tb_frame.f_code.co_name)

# --- what a tree carries through --------------------------------------------
print("== positions")
src = "def f(a):\n    b = a + 1\n    return b * 2\n"
from_src = compile(src, "<p>", "exec")
from_tree = compile(ast.parse(src), "<p>", "exec")


def codes(c):
    yield c
    for k in c.co_consts:
        if isinstance(k, types.CodeType):
            yield from codes(k)


print("positions equal", all(
    list(x.co_positions()) == list(y.co_positions()) and
    list(x.co_lines()) == list(y.co_lines())
    for x, y in zip(codes(from_src), codes(from_tree))))

# A traceback points where the tree says, not at line 1.
tree = ast.parse("x = 1\n\n\ny = x / 0\n")
try:
    exec(compile(tree, "<tb>", "exec"), {})
except ZeroDivisionError as e:
    print("traceback line", e.__traceback__.tb_next.tb_lineno)

# Private names mangle inside the class, as they do from source.
ns = run("class K:\n    __p = 1\n    def get(self):\n        return self.__p\n"
         "print('mangled', K().get(), '_K__p' in K.__dict__)\n")

# PEP 563 from the tree's own future import: annotations become text.
ns = run("from __future__ import annotations\n"
         "def g(a: Undefined, b: list[int] = None) -> 'Q': pass\n"
         "print('future', g.__annotations__)\n")

# --- the flags --------------------------------------------------------------
print("== flags")
t = ast.parse("1")
print("only_ast same object", compile(t, "<o>", "exec", ast.PyCF_ONLY_AST) is t)
print("only_ast any mode", type(compile(t, "<o>", "eval",
                                        ast.PyCF_ONLY_AST)).__name__)

# --- malformed trees ---------------------------------------------------------
print("== errors")
mod = lambda *body: ast.fix_missing_locations(ast.Module(list(body), []))
err("wrong mode exec", lambda: compile(ast.Expression(ast.Constant(1)),
                                       "f", "exec"))
err("wrong mode eval", lambda: compile(ast.parse("x"), "f", "eval"))
err("not ast", lambda: compile(42, "f", "exec"))
err("not ast obj", lambda: compile([1], "f", "exec"))
err("func_type", lambda: compile(ast.parse("(int) -> str", mode="func_type"),
                                 "f", "func_type"))
err("no lineno", lambda: compile(ast.Module([ast.Pass()], []), "f", "exec"))
err("bad const", lambda: compile(ast.fix_missing_locations(
    ast.Expression(ast.Constant([1]))), "f", "eval"))
err("load target", lambda: compile(mod(ast.Assign(
    [ast.Name("x", ast.Load())], ast.Constant(1))), "f", "exec"))
err("store in load", lambda: compile(ast.fix_missing_locations(
    ast.Expression(ast.Name("x", ast.Store()))), "f", "eval"))
err("call target", lambda: compile(mod(ast.Assign(
    [ast.Call(ast.Name("f", ast.Load()), [], [])], ast.Constant(1))),
    "f", "exec"))
err("None name", lambda: compile(ast.fix_missing_locations(
    ast.Expression(ast.Name("None", ast.Load()))), "f", "eval"))
err("body not list", lambda: compile(ast.Module(ast.Pass(), []), "f", "exec"))
err("empty def", lambda: compile(mod(ast.FunctionDef(
    "f", ast.arguments([], [], None, [], [], None, []), [], [])),
    "f", "exec"))
err("no ctx", lambda: compile(ast.fix_missing_locations(
    ast.Expression(ast.Name("x"))), "f", "eval"))
err("return outside", lambda: compile(mod(ast.Return(ast.Constant(1))),
                                      "f", "exec"))
err("break outside", lambda: compile(mod(ast.Break()), "f", "exec"))
err("empty compare", lambda: compile(ast.fix_missing_locations(
    ast.Expression(ast.Compare(ast.Constant(1), [], []))), "f", "eval"))
err("int name", lambda: compile(ast.fix_missing_locations(
    ast.Expression(ast.Name(3, ast.Load()))), "f", "eval"))
err("bad mode", lambda: compile(ast.parse("x"), "f", "nope"))
print("empty module", type(compile(ast.Module([], []), "f", "exec")).__name__)
