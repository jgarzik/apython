"""compile() of an AST object: node objects back into the parser's raw tuples.

`compile(tree, filename, mode)` with an `ast.Module`, `ast.Expression` or
`ast.Interactive` is the inverse of `ast.parse`.  _ast_build.py turns the raw
tuples src/compiler/astraw.asm walks out of the parse arena into node objects;
this turns node objects back into the same raw tuples, and
src/compiler/astload.asm rebuilds the arena from them and runs the rest of the
pipeline -- symbol table, code generator, assembler -- exactly as a compile of
source text does once its parser has finished.

A raw node is the twelve-tuple astraw.asm's header describes:

    (kind, subkind, lineno, col, end_lineno, end_col, a, b, c, children,
     type_params, type_comment)

Everything _ast_build.py undoes is done here in reverse:

  * an else, elif or finally tail becomes a BLOCK node again;
  * decorators go back onto a DECORATED wrapper around the def;
  * the seven parallel parameter lists fold into one flat list, with the
    counts in an EXTRA node and each default on its own ARG;
  * a class's bases and keywords become one CALL node;
  * a keyword with no name becomes a DOUBLESTARRED node;
  * async def, async for, async with and except* become subkind bits;
  * and the operator and context singletons become subkind numbers.

Two things the parser does that a tree cannot carry are redone here as well.
Private names are mangled while the parser is inside a class body, so the
names in the raw tree are the MANGLED ones, as the compiler wants them -- the
fields mangled are exactly the ones the parser mangles.  And under PEP 563 an
annotation is its own source text, which a tree does not have: CPython emits
the text of its unparser, and so does this, as a string Constant in the
annotation's place.

Before any of that the tree is checked the way CPython's obj2ast and AST
validator check it, so a malformed tree is a TypeError or ValueError rather
than whatever the code generator would make of it.
"""

import sys

import _ast

# --- the kinds, mirroring src/compiler/compiler.inc ------------------------
(CONST, NAME, BINOP, UNARYOP, BOOLOP, COMPARE, IFEXP, LAMBDA, TUPLE, LIST,
 SET, DICT, CALL, ATTRIBUTE, SUBSCRIPT, SLICE, STARRED, DOUBLESTARRED,
 KEYWORD, NAMEDEXPR, YIELD, YIELDFROM, AWAIT, JOINEDSTR, FORMATTEDVALUE,
 LISTCOMP, SETCOMP, DICTCOMP, GENEXP, COMPREHENSION) = range(1, 31)

MODULE, EXPRESSION, EXPR_STMT, ASSIGN, AUGASSIGN, ANNASSIGN = range(40, 46)
IF, WHILE, FOR, BLOCK, PASS, BREAK, CONTINUE, RETURN, DELETE = range(46, 55)
RAISE, ASSERT, GLOBAL, NONLOCAL, IMPORT, IMPORTFROM, ALIAS = range(55, 62)
FUNCTIONDEF, CLASSDEF, TRY, HANDLER, WITH, WITHITEM = range(62, 68)
ARGUMENTS, ARG, MATCH, EXTRA, DECORATED = range(68, 73)
(CASE, PAT_VALUE, PAT_CAPTURE, PAT_SEQUENCE, PAT_MAPPING, PAT_CLASS,
 PAT_KEYWORD, PAT_OR, PAT_AS) = range(73, 82)
TYPEALIAS, TYPEPARAMS, TYPEVAR, PARAMSPEC, TYPEVARTUPLE = range(83, 88)

LOAD, STORE, DEL = 0, 1, 2
CTX_NAMES = ("Load", "Store", "Del")
CTX_OF = {_ast.Load: LOAD, _ast.Store: STORE, _ast.Del: DEL}

UNARY_OF = {_ast.UAdd: 0, _ast.USub: 1, _ast.Invert: 2, _ast.Not: 3}
BOOL_OF = {_ast.And: 0, _ast.Or: 1}
CMP_OF = {_ast.Lt: 0, _ast.LtE: 1, _ast.Eq: 2, _ast.NotEq: 3, _ast.Gt: 4,
          _ast.GtE: 5, _ast.In: 6, _ast.NotIn: 7, _ast.Is: 8, _ast.IsNot: 9}
# BINARY_OP's own argument numbering, which is what the parser stores; an
# augmented assignment stores the in-place code, thirteen higher.
BINOP_OF = {_ast.Add: 0, _ast.BitAnd: 1, _ast.FloorDiv: 2, _ast.LShift: 3,
            _ast.MatMult: 4, _ast.Mult: 5, _ast.Mod: 6, _ast.BitOr: 7,
            _ast.Pow: 8, _ast.RShift: 9, _ast.Sub: 10, _ast.Div: 11,
            _ast.BitXor: 12}
CONVERSION_OF = {-1: 0, ord("s"): 1, ord("r"): 2, ord("a"): 3}

_MISSING = object()
_NOPOS = (-1, -1, -1, -1)


def _cls_lookup(table, obj):
    for cls in type(obj).__mro__:
        v = table.get(cls)
        if v is not None:
            return v
    return None


def _raw(kind, sub, pos, a=None, b=None, c=None, ch=None, tp=None):
    return (kind, sub, pos[0], pos[1], pos[2], pos[3], a, b, c, ch, tp, None)


def _mangle(priv, name):
    """CPython's _Py_Mangle, as comp_intern_name applies it."""
    if priv is None or len(name) < 2 or not name.startswith("__"):
        return name
    if name.endswith("__"):
        return name
    p = priv.lstrip("_")
    if not p:
        return name
    return "_" + p + name


def _const_ok(value):
    if value is None or value is Ellipsis:
        return True
    t = type(value)
    if t in (int, float, complex, bool, str, bytes):
        return True
    if t is tuple or t is frozenset:
        return all(_const_ok(v) for v in value)
    return False


class _Loader:
    def __init__(self):
        self.priv = None            # the class whose body names mangle against
        self.future = False         # PEP 563 in force: annotations are text

    # --- field access, with obj2ast's errors -------------------------------
    def field(self, node, name):
        value = getattr(node, name, _MISSING)
        if value is _MISSING:
            raise TypeError('required field "%s" missing from %s'
                            % (name, type(node).__name__))
        return value

    def opt(self, node, name):
        value = getattr(node, name, None)
        return value

    def seq(self, node, name):
        value = getattr(node, name, _MISSING)
        if value is _MISSING or value is None:
            return []
        if not isinstance(value, list):
            raise TypeError('%s field "%s" must be a list, not a %s'
                            % (type(node).__name__, name,
                               type(value).__name__))
        return value

    def ident(self, value, optional=False):
        if value is None and optional:
            return None
        if type(value) is not str:
            raise TypeError("AST identifier must be of type str")
        if value in ("None", "True", "False"):
            raise ValueError("identifier field can't represent '%s' constant"
                             % value)
        return value

    def name(self, value, optional=False):
        """An identifier the parser would have mangled."""
        value = self.ident(value, optional)
        if value is None:
            return None
        return _mangle(self.priv, value)

    def intval(self, node, name, default=_MISSING):
        value = getattr(node, name, _MISSING)
        if value is _MISSING or value is None:
            if default is not _MISSING:
                return default
            raise TypeError('required field "%s" missing from %s'
                            % (name, type(node).__name__))
        if not isinstance(value, int):
            raise TypeError('field "%s" must be an int' % name)
        return int(value)

    def pos(self, node, category):
        line = getattr(node, "lineno", _MISSING)
        if line is _MISSING or line is None:
            raise TypeError('required field "lineno" missing from %s'
                            % category)
        col = getattr(node, "col_offset", _MISSING)
        if col is _MISSING or col is None:
            raise TypeError('required field "col_offset" missing from %s'
                            % category)
        eline = getattr(node, "end_lineno", None)
        ecol = getattr(node, "end_col_offset", None)
        return (self._posint(line), self._posint(col),
                -1 if eline is None else self._posint(eline),
                -1 if ecol is None else self._posint(ecol))

    @staticmethod
    def _posint(v):
        if not isinstance(v, int):
            raise TypeError("position must be an int, not %s"
                            % type(v).__name__)
        v = int(v)
        if v < -1:
            return -1
        if v > 0x7FFFFFFF:
            return 0x7FFFFFFF
        return v

    @staticmethod
    def kind_of(node, table, what):
        k = _cls_lookup(table, node)
        if k is None:
            raise TypeError("expected some sort of %s, but got %r"
                            % (what, node))
        return k

    # --- statement lists ---------------------------------------------------
    def body(self, node, name, owner, allow_empty=False):
        items = self.seq(node, name)
        if not items and not allow_empty:
            raise ValueError("empty %s on %s" % (name, owner))
        return [self.stmt(s) for s in items]

    def block(self, stmts, fallback):
        """A statement list as the BLOCK node an else/finally tail is."""
        if not stmts:
            return None
        first, last = stmts[0], stmts[-1]
        pos = (first[2], first[3], last[4], last[5])
        return _raw(BLOCK, 0, pos, ch=stmts)

    # --- statements --------------------------------------------------------
    def stmt(self, node):
        conv = _cls_lookup(STMT, node)
        if conv is None:
            raise TypeError("expected some sort of stmt, but got %r" % (node,))
        return conv(self, node, self.pos(node, "stmt"))

    def s_functiondef(self, n, p, is_async=0):
        name = self.name(self.field(n, "name"))
        decorators = [self.expr(d) for d in self.seq(n, "decorator_list")]
        tp = self.type_params(n)
        args = self.arguments(self.field(n, "args"), p)
        returns = self.opt(n, "returns")
        returns = self.annotation(returns) if returns is not None else None
        owner = "AsyncFunctionDef" if is_async else "FunctionDef"
        body = self.body(n, "body", owner)
        node = _raw(FUNCTIONDEF, is_async, p, name, args, returns, body, tp)
        return self.decorated(node, decorators)

    def s_asyncfunctiondef(self, n, p):
        return self.s_functiondef(n, p, 1)

    def decorated(self, node, decorators):
        if not decorators:
            return node
        # The parser places the wrapper at the first `@`, which the tree does
        # not record; it is the column before the decorator's expression in
        # every way but `@ dec`.
        d = decorators[0]
        pos = (d[2], d[3] - 1 if d[3] > 0 else 0, node[4], node[5])
        return _raw(DECORATED, 0, pos, node, ch=decorators)

    def s_classdef(self, n, p):
        name = self.name(self.field(n, "name"))
        decorators = [self.expr(d) for d in self.seq(n, "decorator_list")]
        tp = self.type_params(n)
        bases = [self.expr(b) for b in self.seq(n, "bases")]
        keywords = [self.keyword(k) for k in self.seq(n, "keywords")]
        call = None
        if bases or keywords:
            items = bases + keywords
            pos = (items[0][2], items[0][3], items[-1][4], items[-1][5])
            call = _raw(CALL, 0, pos, ch=items)
        saved = self.priv
        self.priv = name
        try:
            body = self.body(n, "body", "ClassDef")
        finally:
            self.priv = saved
        node = _raw(CLASSDEF, 0, p, name, call, None, body, tp)
        return self.decorated(node, decorators)

    def s_return(self, n, p):
        v = self.opt(n, "value")
        return _raw(RETURN, 0, p, self.expr(v) if v is not None else None)

    def s_delete(self, n, p):
        targets = self.seq(n, "targets")
        if not targets:
            raise ValueError("empty targets on Delete")
        return _raw(DELETE, 0, p, ch=[self.expr(t, DEL) for t in targets])

    def s_assign(self, n, p):
        targets = self.seq(n, "targets")
        if not targets:
            raise ValueError("empty targets on Assign")
        value = self.expr(self.field(n, "value"))
        return _raw(ASSIGN, 0, p, None, value,
                    ch=[self.expr(t, STORE) for t in targets])

    def s_typealias(self, n, p):
        target = self.field(n, "name")
        if not isinstance(target, _ast.Name):
            raise TypeError("TypeAlias with non-Name name")
        tp = self.type_params(n)
        name = self.expr(target, STORE)
        value = self.expr(self.field(n, "value"))
        return _raw(TYPEALIAS, 0, p, name, value, tp=tp)

    def s_augassign(self, n, p):
        target = self.expr(self.field(n, "target"), STORE)
        op = self.kind_of(self.field(n, "op"), BINOP_OF, "operator")
        value = self.expr(self.field(n, "value"))
        return _raw(AUGASSIGN, op + 13, p, target, value)

    def s_annassign(self, n, p):
        t = self.field(n, "target")
        target = self.expr(t, STORE)
        simple = self.intval(n, "simple")
        if simple and not isinstance(t, _ast.Name):
            raise TypeError("AnnAssign with simple non-Name target")
        ann = self.annotation(self.field(n, "annotation"))
        v = self.opt(n, "value")
        value = self.expr(v) if v is not None else None
        # The parser's bit is "a parenthesised Name", and only a Name has it.
        sub = 1 if (isinstance(t, _ast.Name) and not simple) else 0
        return _raw(ANNASSIGN, sub, p, target, ann, value)

    def s_for(self, n, p, is_async=0):
        owner = "AsyncFor" if is_async else "For"
        target = self.expr(self.field(n, "target"), STORE)
        it = self.expr(self.field(n, "iter"))
        body = self.body(n, "body", owner)
        orelse = self.body(n, "orelse", owner, True)
        return _raw(FOR, is_async, p, target, it, self.block(body, p),
                    self.block(orelse, p))

    def s_asyncfor(self, n, p):
        return self.s_for(n, p, 1)

    def s_while(self, n, p):
        test = self.expr(self.field(n, "test"))
        body = self.body(n, "body", "While")
        orelse = self.body(n, "orelse", "While", True)
        return _raw(WHILE, 0, p, test, self.block(orelse, p),
                    self.block(body, p))

    def s_if(self, n, p):
        test = self.expr(self.field(n, "test"))
        body = self.body(n, "body", "If")
        orelse = self.body(n, "orelse", "If", True)
        return _raw(IF, 0, p, test, self.block(orelse, p),
                    self.block(body, p))

    def s_with(self, n, p, is_async=0):
        owner = "AsyncWith" if is_async else "With"
        items = self.seq(n, "items")
        if not items:
            raise ValueError("empty items on %s" % owner)
        raw_items = [self.withitem(i, p) for i in items]
        body = self.body(n, "body", owner)
        return _raw(WITH, is_async, p, self.block(body, p), ch=raw_items)

    def s_asyncwith(self, n, p):
        return self.s_with(n, p, 1)

    def withitem(self, item, p):
        if not isinstance(item, _ast.withitem):
            raise TypeError("expected some sort of withitem, but got %r"
                            % (item,))
        ctx = self.expr(self.field(item, "context_expr"))
        v = self.opt(item, "optional_vars")
        var = self.expr(v, STORE) if v is not None else None
        end = var if var is not None else ctx
        pos = (ctx[2], ctx[3], end[4], end[5])
        return _raw(WITHITEM, 0, pos, ctx, var)

    def s_match(self, n, p):
        subject = self.expr(self.field(n, "subject"))
        cases = self.seq(n, "cases")
        if not cases:
            raise ValueError("empty cases on Match")
        return _raw(MATCH, 0, p, subject,
                    ch=[self.match_case(c, p) for c in cases])

    def match_case(self, c, p):
        if not isinstance(c, _ast.match_case):
            raise TypeError("expected some sort of match_case, but got %r"
                            % (c,))
        pat = self.pattern(self.field(c, "pattern"))
        g = self.opt(c, "guard")
        guard = self.expr(g) if g is not None else None
        body = self.body(c, "body", "match_case")
        pos = (pat[2], pat[3], body[-1][4], body[-1][5])
        return _raw(CASE, 0, pos, pat, guard, ch=body)

    def s_raise(self, n, p):
        e = self.opt(n, "exc")
        c = self.opt(n, "cause")
        if e is None and c is not None:
            raise ValueError("Raise with cause but no exception")
        return _raw(RAISE, 0, p, self.expr(e) if e is not None else None,
                    self.expr(c) if c is not None else None)

    def s_try(self, n, p, star=0):
        owner = "TryStar" if star else "Try"
        body = self.body(n, "body", owner)
        handlers = self.seq(n, "handlers")
        orelse = self.body(n, "orelse", owner, True)
        final = self.body(n, "finalbody", owner, True)
        if not handlers and not final:
            raise ValueError("%s has neither except handlers nor finalbody"
                             % owner)
        if not handlers and orelse:
            raise ValueError("%s has orelse but no except handlers" % owner)
        raw_h = [self.handler(h) for h in handlers]
        hblock = self.block(raw_h, p)
        return _raw(TRY, star, p, hblock, self.block(orelse, p),
                    self.block(final, p), body)

    def s_trystar(self, n, p):
        return self.s_try(n, p, 1)

    def handler(self, h):
        if not isinstance(h, _ast.ExceptHandler):
            raise TypeError("expected some sort of excepthandler, but got %r"
                            % (h,))
        p = self.pos(h, "excepthandler")
        t = self.opt(h, "type")
        name = self.name(self.opt(h, "name"), True)
        body = self.body(h, "body", "ExceptHandler")
        return _raw(HANDLER, 0, p, self.expr(t) if t is not None else None,
                    name, ch=body)

    def s_assert(self, n, p):
        test = self.expr(self.field(n, "test"))
        m = self.opt(n, "msg")
        return _raw(ASSERT, 0, p, test, self.expr(m) if m is not None else None)

    def s_import(self, n, p):
        names = self.seq(n, "names")
        if not names:
            raise ValueError("empty names on Import")
        out = []
        for a in names:
            ap = self.pos(a, "alias") if hasattr(a, "lineno") else p
            name = self.ident_dotted(self.field(a, "name"))
            asname = self.name(self.opt(a, "asname"), True)
            bound = asname if asname is not None else _mangle(
                self.priv, name.split(".")[0])
            out.append(_raw(ALIAS, 0, ap, name, asname, bound))
        return _raw(IMPORT, 0, p, ch=out)

    def ident_dotted(self, value):
        if type(value) is not str:
            raise TypeError("AST identifier must be of type str")
        return value

    def s_importfrom(self, n, p):
        module = self.opt(n, "module")
        if module is not None:
            module = self.ident_dotted(module)
        level = self.intval(n, "level", 0)
        if level < 0:
            raise ValueError("Negative ImportFrom level")
        names = self.seq(n, "names")
        if not names:
            raise ValueError("empty names on ImportFrom")
        out = []
        for a in names:
            ap = self.pos(a, "alias") if hasattr(a, "lineno") else p
            name = self.ident_dotted(self.field(a, "name"))
            if name == "*":
                out.append(_raw(ALIAS, 1, ap))
                continue
            name = _mangle(self.priv, name)
            asname = self.name(self.opt(a, "asname"), True)
            bound = asname if asname is not None else name
            out.append(_raw(ALIAS, 0, ap, name, asname, bound))
        return _raw(IMPORTFROM, level, p, module, ch=out)

    def s_global(self, n, p, kind=GLOBAL):
        names = self.seq(n, "names")
        if not names:
            raise ValueError("empty names on %s"
                             % ("Global" if kind == GLOBAL else "Nonlocal"))
        return _raw(kind, 0, p, ch=[self.name(x) for x in names])

    def s_nonlocal(self, n, p):
        return self.s_global(n, p, NONLOCAL)

    def s_expr(self, n, p):
        return _raw(EXPR_STMT, 0, p, self.expr(self.field(n, "value")))

    def s_pass(self, n, p):
        return _raw(PASS, 0, p)

    def s_break(self, n, p):
        return _raw(BREAK, 0, p)

    def s_continue(self, n, p):
        return _raw(CONTINUE, 0, p)

    # --- function signatures -----------------------------------------------
    def arguments(self, a, p):
        if not isinstance(a, _ast.arguments):
            raise TypeError("expected some sort of arguments, but got %r"
                            % (a,))
        posonly = self.seq(a, "posonlyargs")
        args = self.seq(a, "args")
        kwonly = self.seq(a, "kwonlyargs")
        kw_defaults = self.seq(a, "kw_defaults")
        defaults = self.seq(a, "defaults")
        positional = posonly + args
        if len(defaults) > len(positional):
            raise ValueError("more positional defaults than args on "
                             "arguments")
        if len(kw_defaults) != len(kwonly):
            raise ValueError("length of kwonlyargs is not the same as "
                             "kw_defaults on arguments")
        first_default = len(positional) - len(defaults)
        items = []
        for i, x in enumerate(positional):
            d = defaults[i - first_default] if i >= first_default else None
            items.append(self.arg(x, d))
        for x, d in zip(kwonly, kw_defaults):
            items.append(self.arg(x, d))
        va = self.opt(a, "vararg")
        ka = self.opt(a, "kwarg")
        vararg = self.arg(va, None) if va is not None else None
        kwarg = self.arg(ka, None) if ka is not None else None
        every = items + [x for x in (vararg, kwarg) if x is not None]
        if every:
            lo = min(every, key=lambda r: (r[2], r[3]))
            hi = max(every, key=lambda r: (r[4], r[5]))
            pos = (lo[2], lo[3], hi[4], hi[5])
        else:
            pos = (p[0], p[1], p[0], p[1])
        extra = _raw(EXTRA, 0, pos, len(positional), len(posonly),
                     len(kwonly))
        return _raw(ARGUMENTS, 0, pos, extra, vararg, kwarg, items)

    def arg(self, x, default):
        if not isinstance(x, _ast.arg):
            raise TypeError("expected some sort of arg, but got %r" % (x,))
        p = self.pos(x, "arg")
        name = self.name(self.field(x, "arg"))
        ann = self.opt(x, "annotation")
        ann = self.annotation(ann) if ann is not None else None
        d = self.expr(default) if default is not None else None
        return _raw(ARG, 0, p, name, ann, d)

    def annotation(self, node):
        """An annotation, which under PEP 563 is its own source text."""
        if not self.future:
            return self.expr(node)
        self.expr(node)                     # validated all the same
        import ast
        text = ast.unparse(node)
        return _raw(CONST, 0, self.pos(node, "expr"), text)

    def type_params(self, n):
        params = self.seq(n, "type_params")
        if not params:
            return None
        out = []
        for t in params:
            p = self.pos(t, "type_param")
            if isinstance(t, _ast.TypeVar):
                b = self.opt(t, "bound")
                out.append(_raw(TYPEVAR, 0, p, self.name(self.field(t, "name")),
                                self.expr(b) if b is not None else None))
            elif isinstance(t, _ast.ParamSpec):
                out.append(_raw(PARAMSPEC, 0, p,
                                self.name(self.field(t, "name"))))
            elif isinstance(t, _ast.TypeVarTuple):
                out.append(_raw(TYPEVARTUPLE, 0, p,
                                self.name(self.field(t, "name"))))
            else:
                raise TypeError("expected some sort of type_param, but got %r"
                                % (t,))
        pos = (out[0][2], out[0][3], out[-1][4], out[-1][5])
        return _raw(TYPEPARAMS, 0, pos, ch=out)

    # --- expressions -------------------------------------------------------
    def expr(self, node, ctx=LOAD):
        conv = _cls_lookup(EXPR, node)
        if conv is None:
            raise TypeError("expected some sort of expr, but got %r" % (node,))
        p = self.pos(node, "expr")
        if ctx != LOAD and conv not in _STORABLE:
            raise ValueError("expression which can't be assigned to in %s "
                             "context" % CTX_NAMES[ctx])
        return conv(self, node, p, ctx)

    def ctx(self, node, want):
        c = self.field(node, "ctx")
        have = _cls_lookup(CTX_OF, c)
        if have is None:
            raise TypeError("expected some sort of expr_context, but got %r"
                            % (c,))
        if have != want:
            raise ValueError("expression must have %s context but has %s "
                             "instead" % (CTX_NAMES[want], CTX_NAMES[have]))
        return have

    def exprs(self, items):
        return [self.expr(x) for x in items]

    def e_boolop(self, n, p, ctx):
        op = self.kind_of(self.field(n, "op"), BOOL_OF, "boolop")
        values = self.seq(n, "values")
        if len(values) < 2:
            raise ValueError("BoolOp with less than 2 values")
        return _raw(BOOLOP, op, p, ch=self.exprs(values))

    def e_namedexpr(self, n, p, ctx):
        target = self.field(n, "target")
        if not isinstance(target, _ast.Name):
            raise TypeError("NamedExpr target must be a Name")
        t = self.expr(target, STORE)
        return _raw(NAMEDEXPR, 0, p, t, self.expr(self.field(n, "value")))

    def e_binop(self, n, p, ctx):
        left = self.expr(self.field(n, "left"))
        op = self.kind_of(self.field(n, "op"), BINOP_OF, "operator")
        right = self.expr(self.field(n, "right"))
        return _raw(BINOP, op, p, left, right)

    def e_unaryop(self, n, p, ctx):
        op = self.kind_of(self.field(n, "op"), UNARY_OF, "unaryop")
        return _raw(UNARYOP, op, p, self.expr(self.field(n, "operand")))

    def e_lambda(self, n, p, ctx):
        args = self.arguments(self.field(n, "args"), p)
        # A lambda's parameters cannot be annotated, and PEP 563 must not
        # turn one into a string either: an `arg` with an annotation under a
        # lambda is refused by the parser, so the tree never has one.
        return _raw(LAMBDA, 0, p, None, args, self.expr(self.field(n, "body")))

    def e_ifexp(self, n, p, ctx):
        return _raw(IFEXP, 0, p, self.expr(self.field(n, "test")),
                    self.expr(self.field(n, "body")),
                    self.expr(self.field(n, "orelse")))

    def e_dict(self, n, p, ctx):
        keys = self.seq(n, "keys")
        values = self.seq(n, "values")
        if len(keys) != len(values):
            raise ValueError("Dict doesn't have the same number of keys as "
                             "values")
        ch = []
        for k, v in zip(keys, values):
            rv = self.expr(v)
            if k is None:
                ch.append(_raw(DOUBLESTARRED, 0, rv[2:6], rv))
                ch.append(None)
            else:
                ch.append(self.expr(k))
                ch.append(rv)
        return _raw(DICT, 0, p, ch=ch)

    def e_set(self, n, p, ctx):
        return _raw(SET, 0, p, ch=self.exprs(self.seq(n, "elts")))

    def generators(self, n, owner, p):
        gens = self.seq(n, "generators")
        if not gens:
            raise ValueError("comprehension with no generators")
        out = []
        for g in gens:
            if not isinstance(g, _ast.comprehension):
                raise TypeError("expected some sort of comprehension, but got"
                                " %r" % (g,))
            target = self.expr(self.field(g, "target"), STORE)
            it = self.expr(self.field(g, "iter"))
            ifs = self.exprs(self.seq(g, "ifs"))
            is_async = self.intval(g, "is_async", 0)
            last = ifs[-1] if ifs else it
            pos = (p[0], p[1], last[4], last[5])
            out.append(_raw(COMPREHENSION, 1 if is_async else 0, pos,
                            target, it, ch=ifs))
        return out

    def e_listcomp(self, n, p, ctx, kind=LISTCOMP):
        elt = self.expr(self.field(n, "elt"))
        return _raw(kind, 0, p, elt, ch=self.generators(n, "ListComp", p))

    def e_setcomp(self, n, p, ctx):
        return self.e_listcomp(n, p, ctx, SETCOMP)

    def e_genexp(self, n, p, ctx):
        return self.e_listcomp(n, p, ctx, GENEXP)

    def e_dictcomp(self, n, p, ctx):
        key = self.expr(self.field(n, "key"))
        value = self.expr(self.field(n, "value"))
        return _raw(DICTCOMP, 0, p, key, value,
                    ch=self.generators(n, "DictComp", p))

    def e_await(self, n, p, ctx):
        return _raw(AWAIT, 0, p, self.expr(self.field(n, "value")))

    def e_yield(self, n, p, ctx):
        v = self.opt(n, "value")
        return _raw(YIELD, 0, p, self.expr(v) if v is not None else None)

    def e_yieldfrom(self, n, p, ctx):
        return _raw(YIELDFROM, 0, p, self.expr(self.field(n, "value")))

    def e_compare(self, n, p, ctx):
        left = self.expr(self.field(n, "left"))
        ops = self.seq(n, "ops")
        comparators = self.seq(n, "comparators")
        if not comparators:
            raise ValueError("Compare with no comparators")
        if len(ops) != len(comparators):
            raise ValueError("Compare has a different number of comparators "
                             "and operands")
        ch = []
        for op, c in zip(ops, comparators):
            ch.append(self.kind_of(op, CMP_OF, "cmpop"))
            ch.append(self.expr(c))
        return _raw(COMPARE, 0, p, left, ch=ch)

    def e_call(self, n, p, ctx):
        func = self.expr(self.field(n, "func"))
        args = self.exprs(self.seq(n, "args"))
        kws = [self.keyword(k) for k in self.seq(n, "keywords")]
        return _raw(CALL, 0, p, func, ch=args + kws)

    def keyword(self, k):
        if not isinstance(k, _ast.keyword):
            raise TypeError("expected some sort of keyword, but got %r" % (k,))
        p = self.pos(k, "keyword")
        name = self.opt(k, "arg")
        value = self.expr(self.field(k, "value"))
        if name is None:
            return _raw(DOUBLESTARRED, 0, p, value)
        # Not mangled: the parser interns a keyword's name as written.
        return _raw(KEYWORD, 0, p, self.ident(name), value)

    def e_formattedvalue(self, n, p, ctx):
        value = self.expr(self.field(n, "value"))
        conv = self.intval(n, "conversion", -1)
        if conv not in CONVERSION_OF:
            raise SystemError("Unrecognized conversion character %d" % conv)
        spec = self.opt(n, "format_spec")
        if spec is not None:
            spec = self.expr(spec)
        return _raw(FORMATTEDVALUE, CONVERSION_OF[conv], p, value, spec)

    def e_joinedstr(self, n, p, ctx):
        return _raw(JOINEDSTR, 0, p, ch=self.exprs(self.seq(n, "values")))

    def e_constant(self, n, p, ctx):
        value = self.field(n, "value")
        if not _const_ok(value):
            raise TypeError("got an invalid type in Constant: %s"
                            % type(value).__name__)
        return _raw(CONST, 0, p, value)

    def e_attribute(self, n, p, ctx):
        c = self.ctx(n, ctx)
        value = self.expr(self.field(n, "value"))
        return _raw(ATTRIBUTE, c, p, value, self.name(self.field(n, "attr")))

    def e_subscript(self, n, p, ctx):
        c = self.ctx(n, ctx)
        value = self.expr(self.field(n, "value"))
        return _raw(SUBSCRIPT, c, p, value, self.expr(self.field(n, "slice")))

    def e_starred(self, n, p, ctx):
        c = self.ctx(n, ctx)
        return _raw(STARRED, c, p, self.expr(self.field(n, "value"), ctx))

    def e_name(self, n, p, ctx):
        c = self.ctx(n, ctx)
        return _raw(NAME, c, p, self.name(self.field(n, "id")))

    def e_list(self, n, p, ctx, kind=LIST):
        c = self.ctx(n, ctx)
        return _raw(kind, c, p,
                    ch=[self.expr(x, ctx) for x in self.seq(n, "elts")])

    def e_tuple(self, n, p, ctx):
        return self.e_list(n, p, ctx, TUPLE)

    def e_slice(self, n, p, ctx):
        lo = self.opt(n, "lower")
        hi = self.opt(n, "upper")
        st = self.opt(n, "step")
        return _raw(SLICE, 3 if st is not None else 2, p,
                    self.expr(lo) if lo is not None else None,
                    self.expr(hi) if hi is not None else None,
                    self.expr(st) if st is not None else None)

    # --- patterns ----------------------------------------------------------
    def pattern(self, node):
        conv = _cls_lookup(PATTERN, node)
        if conv is None:
            raise TypeError("expected some sort of pattern, but got %r"
                            % (node,))
        return conv(self, node, self.pos(node, "pattern"))

    def capture_name(self, name):
        name = self.ident(name, True)
        if name == "_":
            raise ValueError("can't capture name '_' in patterns")
        return None if name is None else _mangle(self.priv, name)

    def p_matchvalue(self, n, p):
        v = self.field(n, "value")
        if not isinstance(v, (_ast.Constant, _ast.Attribute, _ast.UnaryOp,
                              _ast.BinOp)):
            raise ValueError("patterns may only match literals and attribute "
                             "lookups")
        if isinstance(v, _ast.Constant) and (
                v.value is None or v.value is True or v.value is False):
            raise ValueError("MatchValue cannot match None, True or False")
        return _raw(PAT_VALUE, 0, p, self.expr(v))

    def p_matchsingleton(self, n, p):
        v = self.field(n, "value")
        if not (v is None or v is True or v is False):
            raise ValueError("MatchSingleton can only contain True, False "
                             "and None")
        return _raw(PAT_VALUE, 1, p, _raw(CONST, 0, p, v))

    def p_matchsequence(self, n, p):
        items = self.seq(n, "patterns")
        star = 0
        ch = []
        for i, x in enumerate(items):
            if isinstance(x, _ast.MatchStar):
                if star:
                    raise ValueError("can't use MatchStar more than once")
                star = i + 1
                xp = self.pos(x, "pattern")
                ch.append(_raw(PAT_CAPTURE, 1, xp,
                               self.capture_name(self.opt(x, "name"))))
            else:
                ch.append(self.pattern(x))
        return _raw(PAT_SEQUENCE, 0, p, None, star, ch=ch)

    def p_matchmapping(self, n, p):
        keys = self.seq(n, "keys")
        pats = self.seq(n, "patterns")
        if len(keys) != len(pats):
            raise ValueError("MatchMapping doesn't have the same number of "
                             "keys as patterns")
        rest = self.capture_name(self.opt(n, "rest"))
        ch = []
        for k, v in zip(keys, pats):
            ch.append(self.expr(k))
            ch.append(self.pattern(v))
        return _raw(PAT_MAPPING, 0, p, None, rest, ch=ch)

    def p_matchclass(self, n, p):
        cls = self.expr(self.field(n, "cls"))
        pats = [self.pattern(x) for x in self.seq(n, "patterns")]
        names = self.seq(n, "kwd_attrs")
        kpats = self.seq(n, "kwd_patterns")
        if len(names) != len(kpats):
            raise ValueError("MatchClass doesn't have the same number of "
                             "keyword attributes as patterns")
        ch = list(pats)
        for name, kp in zip(names, kpats):
            r = self.pattern(kp)
            ch.append(_raw(PAT_KEYWORD, 0, r[2:6],
                           _mangle(self.priv, self.ident(name)), r))
        return _raw(PAT_CLASS, 0, p, cls, len(pats), ch=ch)

    def p_matchstar(self, n, p):
        raise ValueError("can't use MatchStar here")

    def p_matchas(self, n, p):
        pat = self.opt(n, "pattern")
        name = self.capture_name(self.opt(n, "name"))
        if pat is None:
            return _raw(PAT_CAPTURE, 0, p, name)
        if name is None:
            raise ValueError("MatchAs must specify a target name if a pattern"
                             " is given")
        return _raw(PAT_AS, 0, p, self.pattern(pat), name)

    def p_matchor(self, n, p):
        pats = self.seq(n, "patterns")
        if len(pats) < 2:
            raise ValueError("MatchOr requires at least 2 patterns")
        return _raw(PAT_OR, 0, p, ch=[self.pattern(x) for x in pats])

    # --- the roots ---------------------------------------------------------
    def module(self, node):
        body = self.seq(node, "body")
        self.future = self.future or _has_future_annotations(body)
        stmts = [self.stmt(s) for s in body]
        if stmts:
            pos = (1, 0, stmts[-1][4], stmts[-1][5])
        else:
            pos = (1, 0, 1, 0)
        return _raw(MODULE, 0, pos, ch=stmts)


def _has_future_annotations(body):
    """CPython's future.c: the leading run of `from __future__` imports."""
    i = 0
    if body and isinstance(body[0], _ast.Expr):
        v = getattr(body[0], "value", None)
        if isinstance(v, _ast.Constant) and isinstance(v.value, str):
            i = 1
    found = False
    for s in body[i:]:
        if not (isinstance(s, _ast.ImportFrom)
                and getattr(s, "module", None) == "__future__"
                and not getattr(s, "level", 0)):
            break
        for a in getattr(s, "names", None) or []:
            if getattr(a, "name", None) == "annotations":
                found = True
    return found


L = _Loader
STMT = {
    _ast.FunctionDef: L.s_functiondef,
    _ast.AsyncFunctionDef: L.s_asyncfunctiondef,
    _ast.ClassDef: L.s_classdef, _ast.Return: L.s_return,
    _ast.Delete: L.s_delete, _ast.Assign: L.s_assign,
    _ast.TypeAlias: L.s_typealias, _ast.AugAssign: L.s_augassign,
    _ast.AnnAssign: L.s_annassign, _ast.For: L.s_for,
    _ast.AsyncFor: L.s_asyncfor, _ast.While: L.s_while, _ast.If: L.s_if,
    _ast.With: L.s_with, _ast.AsyncWith: L.s_asyncwith,
    _ast.Match: L.s_match, _ast.Raise: L.s_raise, _ast.Try: L.s_try,
    _ast.TryStar: L.s_trystar, _ast.Assert: L.s_assert,
    _ast.Import: L.s_import, _ast.ImportFrom: L.s_importfrom,
    _ast.Global: L.s_global, _ast.Nonlocal: L.s_nonlocal,
    _ast.Expr: L.s_expr, _ast.Pass: L.s_pass, _ast.Break: L.s_break,
    _ast.Continue: L.s_continue,
}
EXPR = {
    _ast.BoolOp: L.e_boolop, _ast.NamedExpr: L.e_namedexpr,
    _ast.BinOp: L.e_binop, _ast.UnaryOp: L.e_unaryop,
    _ast.Lambda: L.e_lambda, _ast.IfExp: L.e_ifexp, _ast.Dict: L.e_dict,
    _ast.Set: L.e_set, _ast.ListComp: L.e_listcomp,
    _ast.SetComp: L.e_setcomp, _ast.DictComp: L.e_dictcomp,
    _ast.GeneratorExp: L.e_genexp, _ast.Await: L.e_await,
    _ast.Yield: L.e_yield, _ast.YieldFrom: L.e_yieldfrom,
    _ast.Compare: L.e_compare, _ast.Call: L.e_call,
    _ast.FormattedValue: L.e_formattedvalue,
    _ast.JoinedStr: L.e_joinedstr, _ast.Constant: L.e_constant,
    _ast.Attribute: L.e_attribute, _ast.Subscript: L.e_subscript,
    _ast.Starred: L.e_starred, _ast.Name: L.e_name, _ast.List: L.e_list,
    _ast.Tuple: L.e_tuple, _ast.Slice: L.e_slice,
}
_STORABLE = frozenset((L.e_attribute, L.e_subscript, L.e_starred, L.e_name,
                       L.e_list, L.e_tuple))
PATTERN = {
    _ast.MatchValue: L.p_matchvalue,
    _ast.MatchSingleton: L.p_matchsingleton,
    _ast.MatchSequence: L.p_matchsequence,
    _ast.MatchMapping: L.p_matchmapping, _ast.MatchClass: L.p_matchclass,
    _ast.MatchStar: L.p_matchstar, _ast.MatchAs: L.p_matchas,
    _ast.MatchOr: L.p_matchor,
}
del L

_ROOT = {"exec": _ast.Module, "eval": _ast.Expression,
         "single": _ast.Interactive, "func_type": _ast.FunctionType}

PyCF_ONLY_AST = 0x400


def _to_raw(node, mode):
    """The raw tree for a root node, checked against compile()'s mode."""
    want = _ROOT[mode]
    if not isinstance(node, want):
        raise TypeError("expected %s node, got %s"
                        % (want.__name__, type(node).__name__))
    loader = _Loader()
    if mode == "eval":
        # The bare expression, which is what par_eval_root hands
        # compile_source too: the Expression wrapper is the AST's alone.
        return loader.expr(loader.field(node, "body")), False
    if mode == "func_type":
        raise ValueError("compile() mode 'func_type' requires flag "
                         "PyCF_ONLY_AST")
    # "single" compiles as "exec" does here -- the parser hands
    # compile_source a Module for it too.
    raw = loader.module(node)
    return raw, loader.future


def _compile_prep(source, mode, flags):
    """What builtin compile() asks about a source that is not str or bytes.

    Answers the tree itself under PyCF_ONLY_AST, which CPython hands back
    untouched; otherwise a (raw tree, future-annotations) pair for
    src/compiler/astload.asm to build the arena from.
    """
    if not isinstance(source, _ast.AST):
        raise TypeError("compile() arg 1 must be a string, bytes or AST "
                        "object")
    if flags & PyCF_ONLY_AST:
        return source
    # Two Python frames a level, where CPython's converter spends C stack
    # rather than Python recursion: a 2000-deep chain of `+` that ast.parse
    # builds without complaint must compile too.  The ceiling still stops a
    # tree deep enough to exhaust the native stack the code generator
    # recurses on.
    old = sys.getrecursionlimit()
    if old < _CONVERT_DEPTH:
        sys.setrecursionlimit(_CONVERT_DEPTH)
    try:
        return _to_raw(source, mode)
    finally:
        if old < _CONVERT_DEPTH:
            sys.setrecursionlimit(old)


_CONVERT_DEPTH = 10000
