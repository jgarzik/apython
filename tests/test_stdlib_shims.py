# The pure-Python stand-ins in lib/ that unblock the stdlib, and the
# interpreter pieces they lean on.
#
# Each of these was a missing import that stopped a chain of stdlib modules:
# _thread.daemon_threads_allowed (threading and thirteen behind it),
# _operator._compare_digest (hmac), _string (string), _contextvars,
# _random, _tokenize (traceback, linecache, logging), atexit (logging).


def _lookup_type(var):
    try:
        var.get()
    except LookupError as e:
        return type(e).__name__, type(e.args[0]).__name__


def show(label, fn):
    try:
        print(label, "=>", repr(fn()))
    except BaseException as e:
        print(label, "!!", type(e).__name__, e)


# --- _thread
import _thread

show("daemon_threads_allowed", lambda: _thread.daemon_threads_allowed())
show("_is_main_interpreter", lambda: _thread._is_main_interpreter())
show("_set_sentinel unlocked",
     lambda: (lambda lk: (lk.acquire(False), lk.locked()))(_thread._set_sentinel()))
show("get_ident", lambda: _thread.get_ident() != 0)
show("_ExceptHookArgs fields",
     lambda: (lambda a: (a.exc_type, str(a.exc_value), a.exc_traceback, a.thread))(
         _thread._ExceptHookArgs((ValueError, ValueError("v"), None, None))))


class _FakeThread:
    name = "T-1"


def excepthook_runs():
    import sys
    saved, sys.stderr = sys.stderr, open("/dev/null", "w")
    try:
        _thread._excepthook(_thread._ExceptHookArgs(
            (ValueError, ValueError("v"), None, _FakeThread())))
        _thread._excepthook(_thread._ExceptHookArgs(
            (SystemExit, SystemExit(0), None, _FakeThread())))
    finally:
        sys.stderr.close()
        sys.stderr = saved
    return "ok"


show("_excepthook", excepthook_runs)

# --- _operator
from _operator import _compare_digest as cd

show("digest equal", lambda: cd(b"abc", b"abc"))
show("digest differ", lambda: cd(b"abc", b"abd"))
show("digest lengths", lambda: cd(b"abc", b"ab"))
show("digest empty", lambda: cd(b"", b""))
show("digest str", lambda: cd("abc", "abc"))
show("digest bytearray", lambda: cd(bytearray(b"abc"), b"abc"))
show("digest mixed", lambda: cd("a", b"a"))
show("digest ints", lambda: cd(1, 2))
show("digest non-ascii", lambda: cd("\xe9", "\xe9"))

# --- _string
import _string

show("parse simple", lambda: list(_string.formatter_parser("a{b!r:>10}c")))
show("parse empty field", lambda: list(_string.formatter_parser("{}")))
show("parse no field", lambda: list(_string.formatter_parser("x")))
show("parse escapes", lambda: list(_string.formatter_parser("a{{b}}c")))
show("parse nested spec", lambda: list(_string.formatter_parser("{a:{w}}")))
show("parse unmatched", lambda: list(_string.formatter_parser("{")))
show("split attrs", lambda: (lambda p: (p[0], list(p[1])))(
    _string.formatter_field_name_split("a.b[0].c")))
show("split index", lambda: (lambda p: (p[0], list(p[1])))(
    _string.formatter_field_name_split("0[1].x")))
show("split bare", lambda: (lambda p: (p[0], list(p[1])))(
    _string.formatter_field_name_split("a")))

# --- _contextvars
from _contextvars import ContextVar, copy_context

_v = ContextVar("v", default=7)
show("var default", lambda: _v.get())
show("var name", lambda: _v.name)


def set_and_reset():
    tok = _v.set(9)
    got = _v.get()
    _v.reset(tok)
    return got, _v.get(), tok.var is _v


show("set/reset", set_and_reset)
# The LookupError carries the variable, whose repr has an address in it.
show("no default", lambda: _lookup_type(ContextVar("w")))
show("explicit default", lambda: ContextVar("w").get(3))


def run_in_copy():
    ctx = copy_context()
    return ctx.run(lambda: (_v.set(42), _v.get())[1]), _v.get()


show("Context.run", run_in_copy)

# --- _random: the same generator CPython has, so the numbers match
import _random

show("seeded", lambda: [round(x, 12) for x in
                        (lambda r: [r.random() for _ in range(3)])(
                            _random.Random(42))])
show("reproducible",
     lambda: _random.Random(7).random() == _random.Random(7).random())
show("getrandbits",
     lambda: [_random.Random(1).getrandbits(n) for n in (1, 8, 32, 64, 100)])
show("state round trip", lambda: (lambda r: (
    lambda st: (lambda v: (r.setstate(st), r.random() == v)[1])(r.random()))(
        r.getstate()))(_random.Random(3)))
show("seed 0", lambda: round(_random.Random(0).random(), 12))
show("bad bits", lambda: _random.Random(1).getrandbits(-1))

# --- _tokenize
import _tokenize
import io

def _tok_err(src):
    try:
        toks(src)
    except SyntaxError as e:
        # e.msg is CPython's; without it the location is appended to str(e),
        # so the message is taken up to the parenthesis either way.
        msg = getattr(e, "msg", None)
        if msg is None:
            msg = str(e).split(" (")[0] + " (detected at line 1)"
        return type(e).__name__, msg


def toks(src):
    return [(t[0], t[1]) for t in
            _tokenize.TokenizerIter(io.StringIO(src).readline,
                                    extra_tokens=True)]


show("tok assign", lambda: toks("a = 1\n"))
show("tok indent", lambda: toks("if x:\n    y\n"))
show("tok string", lambda: toks("s = 'hi'\n"))
show("tok comment", lambda: toks("x  # c\n"))
show("tok triple", lambda: toks("s = '''a\nb'''\n"))
show("tok continuation", lambda: toks("x = (1,\n  2)\n"))
show("tok backslash", lambda: toks("x = 1 + \\\n  2\n"))
show("tok number", lambda: toks("0x1f 1_000 1.5e-3 4j\n"))
# A SyntaxError's str() carries the file and line in CPython and not here
# (once in the old bug list), so only the message is compared.
show("tok unterminated", lambda: _tok_err("s = 'a\n"))

# --- atexit
import atexit

_calls = []


def _note(x):
    _calls.append(x)


show("register returns", lambda: atexit.register(_note, 1) is _note)
show("run order", lambda: (atexit.register(_note, 2),
                           atexit._run_exitfuncs(), _calls)[2])
show("drained", lambda: atexit._ncallbacks())
show("unregister", lambda: (atexit.register(_note, 3),
                            atexit.unregister(_note),
                            atexit._run_exitfuncs(),
                            _calls)[3])
show("register non-callable", lambda: atexit.register(5))

print("done")
