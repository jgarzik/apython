#!/usr/bin/env python3
"""raise_probe.py - the driver behind tests/raise_probe.sh.

Makes builtins FAIL, thousands of ways, and reads the allocator's live-block
count around each: a failure that leaks is a failure that left by jumping out
from under whoever held the memory.  See the .sh for the why.

    python3 tests/raise_probe.py APYTHON [--record] [--show] [--filter TEXT]

Two families of case, each run in a loop inside ONE interpreter process:

  refuse   every method of every builtin type, every builtin function and
           every constructor, called with arguments it must turn away
  callback tests/reentry_probe.py's container operations, with the element's
           __eq__ / __hash__ / __lt__ / __repr__ / __index__ / iterator / key
           function raising in the middle of the operation

A case counts only if it RAISED.  It leaks if the block count climbs by at
least one block per call, twice running.  The cases that leak today are
tests/raise_leak_floor.txt; the gate is that the set only shrinks -- a new
leak fails, and so does an entry that no longer leaks, so the floor is
lowered (`--record`) in the commit that earns it.  A crash is recorded the
same way, as a `CRASH` line: each one is a bug with a deadline.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FLOOR = os.path.join(HERE, 'raise_leak_floor.txt')
sys.path.insert(0, HERE)
import reentry_probe  # noqa: E402  (the callback corpus is its corpus)

CHILD = r'''
import sys, gc
START = int(sys.argv[1]); FILT = sys.argv[2]
CALLBACKS = __CALLBACKS__
g = sys.getallocatedblocks
import os as _os
# Report on a descriptor of our own, far from the ones a refused FileIO(1)
# might still close on its way out.
_os.dup2(1, 250)
def say(s):
    _os.write(250, (s + "\n").encode())

N = 12
def once(f):
    try:
        f()
    except BaseException:
        return 1
    return 0
def measure(f):
    for _ in range(6):
        once(f)
    a = g()
    for _ in range(N):
        once(f)
    return (g() - a) // N

# ---- refusals ------------------------------------------------------------
FILL = [(), (None,), (1.5,), ('s',), (b'b',), (-1,), ([],), (object,),
        (None, 1, 2, 3, 4, 5, 6, 7)]
KW = {'zzz': 1}
SKIP = {'__init_subclass__', '__subclasshook__', '__del__', '__class__',
        'breakpoint', 'help', 'input', 'copyright', 'credits', 'license',
        'sleep', 'settrace', 'setprofile', 'setswitchinterval',
        'setrecursionlimit', '_settraceallthreads', '_setprofileallthreads',
        'set_debug', 'set_threshold', 'freeze', 'disable', 'pthread_kill',
        'excepthook', 'unraisablehook', 'displayhook', 'exit', '_exit',
        'abort', 'fork', 'kill', 'pause', 'alarm', 'setitimer', 'open',
        'print', 'exec', 'eval', '__import__', 'globals', 'locals', 'vars',
        'dir', 'call_tracing', 'settimeout', 'run', 'throw', 'send', 'close'}

def _gen():
    yield 1
def _fn():
    pass
MAKE = {
    'int': lambda: 5, 'bool': lambda: True, 'float': lambda: 1.5,
    'complex': lambda: 1j, 'str': lambda: 'abc', 'bytes': lambda: b'abc',
    'bytearray': lambda: bytearray(b'abc'), 'list': lambda: [1, 2, 3],
    'tuple': lambda: (1, 2, 3), 'dict': lambda: {1: 2},
    'set': lambda: {1, 2}, 'frozenset': lambda: frozenset((1, 2)),
    'range': lambda: range(5), 'slice': lambda: slice(1, 2),
    'memoryview': lambda: memoryview(b'abc'), 'object': lambda: object(),
    'property': lambda: property(), 'staticmethod': lambda: staticmethod(len),
    'classmethod': lambda: classmethod(len), 'enumerate': lambda: enumerate([]),
    'zip': lambda: zip(), 'map': lambda: map(len, []),
    'filter': lambda: filter(None, []), 'reversed': lambda: reversed([]),
    'list_iterator': lambda: iter([1]), 'tuple_iterator': lambda: iter((1,)),
    'dict_keys': lambda: {1: 2}.keys(), 'dict_values': lambda: {1: 2}.values(),
    'dict_items': lambda: {1: 2}.items(), 'generator': lambda: _gen(),
    'function': lambda: _fn, 'NoneType': lambda: None,
    'ellipsis': lambda: Ellipsis, 'Exception': lambda: Exception('x'),
    'OSError': lambda: OSError(2, 'x'), 'method': lambda: [].append,
    'code': lambda: _fn.__code__, 'module': lambda: sys, 'type': lambda: int,
    'super': lambda: super(int, 5),
}
TYPES = {}
def _extra(modname, attrs, mk):
    try:
        m = __import__(modname)
    except ImportError:
        return
    for a in attrs:
        t = getattr(m, a, None)
        if t is not None:
            TYPES[modname + '.' + a] = t
            if mk.get(a):
                MAKE[modname + '.' + a] = mk[a]
import builtins
for _n in ('int', 'bool', 'float', 'complex', 'str', 'bytes', 'bytearray',
           'list', 'tuple', 'dict', 'set', 'frozenset', 'range', 'slice',
           'memoryview', 'object', 'property', 'staticmethod', 'classmethod',
           'enumerate', 'zip', 'map', 'filter', 'reversed', 'super', 'type',
           'Exception', 'OSError', 'BaseException', 'StopIteration',
           'SyntaxError', 'UnicodeDecodeError', 'ImportError', 'KeyError'):
    TYPES[_n] = getattr(builtins, _n)
def _mk_extra():
    import _io, array, re
    _extra('_io', ['FileIO', 'BytesIO', 'StringIO'],
           {'BytesIO': lambda: _io.BytesIO(b'abc'),
            'StringIO': lambda: _io.StringIO('abc')})
    _extra('array', ['array'], {'array': lambda: array.array('i', [1, 2])})
    MAKE['re.Pattern'] = lambda: re.compile('a')
    MAKE['re.Match'] = lambda: re.match('a', 'a')
try:
    _mk_extra()
except Exception:
    pass

def refusals():
    # constructors
    for tn, t in sorted(TYPES.items()):
        for args in FILL:
            yield 'new | %s%r' % (tn, args), (lambda t=t, a=args: t(*a))
            yield 'new | %s%r **kw' % (tn, args), (lambda t=t, a=args: t(*a, **KW))
    # methods, bound to a fresh instance each call
    for tn, mk in sorted(MAKE.items()):
        try:
            names = sorted(dir(mk()))
        except Exception:
            continue
        for name in names:
            if name in SKIP:
                continue
            try:
                if not callable(getattr(mk(), name)):
                    continue
            except Exception:
                continue
            for args in FILL:
                yield ('meth | %s.%s%r' % (tn, name, args),
                       (lambda mk=mk, n=name, a=args: getattr(mk(), n)(*a)))
            yield ('meth | %s.%s **kw' % (tn, name),
                   (lambda mk=mk, n=name: getattr(mk(), n)(**KW)))
    # module-level functions
    for mn in ('builtins', 'math', 'cmath', 'sys', 'gc', 'marshal', 'time',
               'unicodedata', '_sre', 'zlib', 'binascii', '_struct',
               '_random', 'errno', 'array', '_operator', '_functools',
               '_codecs', '_weakref', '_abc', '_collections'):
        try:
            m = __import__(mn)
        except ImportError:
            continue
        for name in sorted(dir(m)):
            if name in SKIP or name.startswith('__'):
                continue
            fn = getattr(m, name, None)
            if not callable(fn) or isinstance(fn, type):
                continue
            for args in FILL:
                yield ('func | %s.%s%r' % (mn, name, args),
                       (lambda fn=fn, a=args: fn(*a)))
            yield 'func | %s.%s **kw' % (mn, name), (lambda fn=fn: fn(**KW))

# ---- callbacks that raise ------------------------------------------------
CB_PRELUDE = """
class E:
    def __init__(self, v): self.v = v
    def __eq__(self, o):
        hook('eq'); return self.v == getattr(o, 'v', o)
    def __hash__(self):
        hook('hash'); return hash(self.v)
    def __lt__(self, o):
        hook('lt'); return self.v < getattr(o, 'v', o)
    def __repr__(self):
        hook('repr'); return 'E(%r)' % (self.v,)
    def __index__(self):
        hook('index'); return self.v
def gen(n):
    for i in range(n):
        hook('iter')
        yield E(i)
def key(e):
    hook('key'); return e.v
"""
def callbacks():
    for name, hookname, setup, op in CALLBACKS:
        ns = {}
        src = (CB_PRELUDE
               + "state = [False, 0]\n"
               + "def hook(name):\n"
               + "    if state[0] and name == %r:\n" % hookname
               + "        state[1] += 1\n"
               + "        if state[1] == NTH:\n"
               + "            raise ValueError('probe')\n"
               + "def case():\n"
               + "    state[0] = False; state[1] = 0\n"
               + "".join("    " + l + "\n" for l in setup.split("\n"))
               + "    state[0] = True\n"
               + "    try:\n"
               + "        " + op + "\n"
               + "    finally:\n"
               + "        state[0] = False\n")
        # Raise on the first firing, and again on the third: the first is
        # before the operation has built anything, the third is mid-flight.
        for nth in (1, 3):
            ns = {'NTH': nth}
            try:
                exec(src, ns)
            except Exception:
                continue
            yield 'cb | %s | nth=%d' % (name, nth), ns['case']

def run():
    idx = -1
    raised = 0
    for fam in (refusals, callbacks):
        for name, f in fam():
            idx += 1
            if idx < START or (FILT and FILT not in name):
                continue
            say('@ %d %s' % (idx, name))
            if not once(f):
                continue            # it ran: not a failure path
            raised += 1
            say('!')
            d = measure(f)
            if d >= 1:
                d = measure(f)
            if d >= 1:
                say('LEAK %d %s' % (d, name))
    say('DONE %d' % raised)
run()
'''


def callback_cases():
    out = []
    for kind, (setup, muts, ops) in reentry_probe.KINDS.items():
        for op in ops:
            for hook in reentry_probe.HOOKS:
                if hook == 'del':
                    continue        # a __del__ that raises is swallowed
                if hook == 'iter' and 'gen(' not in op:
                    continue
                if hook == 'key' and 'key' not in op:
                    continue
                if hook == 'index' and kind != 'bytearray' and 'E(' not in op:
                    continue
                if kind == 'bytearray' and hook not in ('index', 'iter'):
                    continue
                out.append(('%s | %s | %s' % (kind, op, hook), hook, setup, op))
    return out


def sweep(apython, filt):
    """-> (leaks {name: blocks}, crashes [name], cases that raised)"""
    child = CHILD.replace('__CALLBACKS__', json.dumps(callback_cases()))
    leaks, crashes, raised, start = {}, [], 0, 0
    # A directory of our own (mode 0700, random name): the child is a script
    # this hands to an interpreter, so its path must not be one that anyone
    # else could have written first.
    with tempfile.TemporaryDirectory() as work:
        path = os.path.join(work, 'child.py')
        with open(path, 'w') as fh:
            fh.write(child)
        while True:
            p = subprocess.run([apython, path, str(start), filt],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               stdin=subprocess.DEVNULL, timeout=600)
            last, done = None, False
            for line in p.stdout.decode('utf-8', 'replace').split('\n'):
                if line.startswith('@ '):
                    _, i, name = line.split(' ', 2)
                    last = (int(i), name)
                elif line.startswith('LEAK '):
                    _, d, name = line.split(' ', 2)
                    leaks[name] = int(d)
                elif line == '!':
                    raised += 1
                elif line.startswith('DONE '):
                    done = True
            if done:
                break
            if last is None:
                raise SystemExit("raise_probe: the interpreter did not start"
                                 " (rc=%d)" % p.returncode)
            crashes.append(last[1])
            start = last[0] + 1
    return leaks, crashes, raised


def main():
    args = sys.argv[1:]
    apython = args[0]
    filt = args[args.index('--filter') + 1] if '--filter' in args else ''
    leaks, crashes, raised = sweep(apython, filt)
    found = set(leaks) | set('CRASH ' + c for c in crashes)
    if '--show' in args:
        for name in sorted(leaks):
            print("LEAK %d  %s" % (leaks[name], name))
        for c in crashes:
            print("CRASH  %s" % c)
    if '--record' in args:
        with open(FLOOR, 'w') as fh:
            fh.write("# Failure paths that leak or crash, found by\n"
                     "# tests/raise_probe.sh.  The set may only shrink: a new\n"
                     "# one fails the gate, and so does one that is fixed --\n"
                     "# re-record with\n"
                     "#   bash tests/raise_probe.sh --record\n"
                     "# in the commit that fixes it.\n")
            for name in sorted(found):
                fh.write(name + "\n")
        print("raise probe: recorded %d leaking and %d crashing failure"
              " path(s) of %d" % (len(leaks), len(crashes), raised))
        return 0
    floor = set()
    try:
        for line in open(FLOOR):
            line = line.rstrip('\n')
            if line and not line.startswith('#'):
                floor.add(line)
    except FileNotFoundError:
        pass
    new = sorted(found - floor)
    fixed = sorted(floor - found) if not filt else []
    for name in new[:40]:
        print("NEW  %s" % name)
    for name in fixed[:40]:
        print("FIXED (re-record the floor)  %s" % name)
    ok = not (new or fixed)
    print("%s raise probe: %d failure paths, %d leak, %d crash (floor %d);"
          " %d new, %d fixed"
          % ("PASS" if ok else "FAIL", raised, len(leaks), len(crashes),
             len(floor), len(new), len(fixed)))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
