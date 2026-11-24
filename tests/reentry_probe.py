#!/usr/bin/env python3
"""reentry_probe.py - the driver behind tests/reentry_probe.sh.

Generates one small program per (container operation, hook, mutation), runs
each under the interpreter named on the command line in a process of its own,
and reports the ones that died on a signal or hung.  See the .sh for why.

    python3 tests/reentry_probe.py APYTHON [--jobs N] [--show] [--filter TEXT]
"""
import os
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

# Seconds a case may run.  REENTRY_TIMEOUT raises it for a run under valgrind.
TIMEOUT = int(os.environ.get('REENTRY_TIMEOUT', '20'))

# The element every container is filled with.  Each dunder reports to hook(),
# and the ONE hook the case arms fires the case's mutation, once.
PRELUDE = r'''
import sys
ARMED = %(hook)r
live = False        # set once the containers are built: setup hashes too
fired = False
def hook(name):
    global fired
    if live and name == ARMED and not fired:
        fired = True
        mutate()
class E:
    def __init__(self, v): self.v = v
    def __eq__(self, o):
        hook('eq'); return self.v == getattr(o, 'v', o)
    def __hash__(self):
        hook('hash'); return hash(self.v)
    def __lt__(self, o):
        hook('lt'); return self.v < getattr(o, 'v', o)
    def __repr__(self):
        hook('repr'); return 'E(%%r)' %% (self.v,)
    def __index__(self):
        hook('index'); return self.v
    def __del__(self):
        hook('del')
def gen(n):
    for i in range(n):
        hook('iter')
        yield E(i)
def key(e):
    hook('key'); return e.v
'''

HOOKS = ['eq', 'hash', 'lt', 'repr', 'index', 'del', 'iter', 'key']

# container kind -> (setup, mutations, operations).  `c` is the container.
KINDS = {
    'list': (
        'c = [E(i) for i in range(12)]\nother = [E(i) for i in range(12)]',
        {
            'clear': 'c.clear()',
            'shrink': 'del c[1:]',
            'grow': 'c.extend(E(100 + i) for i in range(200))',
            'replace': 'c[:] = [E(50), E(51)]',
        },
        [
            'c.index(E(11))', 'c.count(E(11))', 'c.remove(E(11))', 'E(11) in c',
            'c == other', 'c < other', 'c.sort()', 'c.sort(key=key)',
            'sorted(c)', 'sorted(c, key=key)', 'min(c)', 'max(c, key=key)',
            'c.extend(gen(8))', 'c[2:5] = gen(8)', 'c[::2] = gen(6)',
            'c += gen(8)', 'c.insert(E(3), E(9))', 'c.pop(E(3))', 'c[E(3)]',
            'c[E(1):E(9)]', 'c * E(3)', 'c *= E(2)', 'repr(c)', 'str(c)',
            'list(c)', 'tuple(c)', 'set(c)', 'dict.fromkeys(c)',
            'c.clear()', 'del c[3]', 'del c[2:9]', 'c[4] = E(40)',
            'c[1:8] = [E(1)]', 'c.pop()', 'c.__init__(gen(5))', 'c.reverse()',
            'c.copy()', 'list(reversed(c))', 'c.__init__()', 'c *= 0',
            'hash(tuple(c))', 'tuple(c) == tuple(other)', 'tuple(c) < tuple(other)',
        ],
    ),
    'dict': (
        'c = {E(i): E(i + 100) for i in range(12)}\n'
        'other = {E(i): E(i + 100) for i in range(12)}',
        {
            'clear': 'c.clear()',
            'shrink': 'c.pop(next(iter(c)), None) if c else None',
            'grow': 'c.update((E(1000 + i), i) for i in range(200))',
            'replace': 'c[E(5)] = E(7)',
        },
        [
            'c[E(11)]', 'c.get(E(11))', 'E(11) in c', 'c.pop(E(11))',
            'c.setdefault(E(99), 1)', 'c[E(99)] = 1', 'del c[E(11)]',
            'c.update(other)', 'c.update((e, 1) for e in gen(8))', 'c == other',
            'repr(c)', 'dict(c)', 'c.copy()', 'c.popitem()', 'c.clear()',
            'list(c.items())', 'repr(c.keys())', 'repr(c.values())',
            'repr(c.items())', 'c.keys() == other.keys()', 'c.keys() & other.keys()',
            'c.items() == other.items()', 'c | other', 'c |= other',
            'dict.fromkeys(gen(8))', 'sorted(c)', 'sorted(c, key=key)',
            '[k for k in c]', 'E(100) in c.values()', 'c.__init__(other)',
            'c[E(3)] = E(40)', 'list(c.values()).index(E(111))',
        ],
    ),
    'set': (
        'c = {E(i) for i in range(12)}\nother = {E(i) for i in range(6, 18)}',
        {
            'clear': 'c.clear()',
            'shrink': 'c.pop() if c else None',
            'grow': 'c.update(E(1000 + i) for i in range(200))',
            'replace': 'c.add(E(55))',
        },
        [
            'c.add(E(99))', 'c.discard(E(11))', 'c.remove(E(11))', 'E(11) in c',
            'c | other', 'c & other', 'c - other', 'c ^ other', 'c |= other',
            'c &= other', 'c -= other', 'c ^= other', 'c == other', 'c <= other',
            'c.issubset(other)', 'c.issuperset(other)', 'c.isdisjoint(other)',
            'c.update(gen(8))', 'c.intersection_update(other)',
            'c.difference_update(gen(8))', 'c.symmetric_difference_update(other)',
            'repr(c)', 'c.pop()', 'c.clear()', 'c.copy()', 'set(c)', 'frozenset(c)',
            'sorted(c)', 'sorted(c, key=key)', 'c.__init__(gen(5))',
            'hash(frozenset(c))', 'frozenset(c) == frozenset(other)',
        ],
    ),
    'bytearray': (
        'c = bytearray(range(40))\nother = bytearray(b"xyz")',
        {
            'clear': 'c.clear()',
            'shrink': 'del c[1:]',
            'grow': 'c.extend(bytes(5000))',
            'replace': 'c[:] = b"ab"',
        },
        [
            'c[E(3)]', 'c[E(3)] = 7', 'c[3] = E(7)', 'c.insert(E(3), 7)',
            'c.insert(3, E(7))', 'c.append(E(7))', 'c.pop(E(3))', 'c * E(3)',
            'c *= E(2)', 'c.extend(e.v for e in gen(8))', 'c[2:5] = [E(1), E(2)]',
            'c[E(1):E(9)]', 'c[E(1):E(9)] = b"q"', 'del c[E(1):E(9)]',
            'c.extend([E(1), E(2), E(3)])', 'c.remove(E(7))', 'c.index(E(7))',
            'c.count(E(7))', 'E(7) in c', 'c.find(E(7))', 'c.center(E(60))',
            'c.ljust(E(60))', 'c.zfill(E(60))', 'c.expandtabs(E(4))',
            'c.split(None, E(2))', 'c.replace(b"\\x01", b"z", E(2))',
            'bytes(c).join([other, other])', 'c.__init__(E(5))',
            'c.__init__([E(1), E(2)])', 'c.hex(":", E(2))',
            'c.startswith(other, E(1))', 'c[::E(2)]', 'c[::2] = bytes(E(20))',
        ],
    ),
}


def cases():
    for kind, (setup, muts, ops) in KINDS.items():
        for op in ops:
            for hook in HOOKS:
                # A hook the operation cannot reach is a wasted process.
                if hook == 'iter' and 'gen(' not in op:
                    continue
                if hook == 'key' and 'key' not in op:
                    continue
                if hook == 'index' and kind != 'bytearray' and 'E(' not in op:
                    continue
                if kind == 'bytearray' and hook not in ('index', 'iter', 'del'):
                    continue
                for mname, mut in muts.items():
                    name = '%s | %s | %s | %s' % (kind, op, hook, mname)
                    src = (PRELUDE % {'hook': hook}
                           + setup + '\n'
                           + 'def mutate():\n    ' + mut + '\n'
                           + 'live = True\n'
                           + 'try:\n    ' + op + '\n'
                           + 'except Exception as e:\n    pass\n'
                           + 'c = other = None\n'
                           + "print('done')\n")
                    yield name, src


def run(apython, work, item):
    idx, (name, src) = item
    path = os.path.join(work, 'c%d.py' % idx)
    with open(path, 'w') as f:
        f.write(src)
    try:
        p = subprocess.run([apython, path], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=TIMEOUT)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        return name, 'HANG'
    if rc < 0 or rc >= 128:
        return name, 'CRASH(%d)' % (-rc if rc < 0 else rc - 128)
    # Every case ends by printing this, whatever the operation did.  Without
    # it an interpreter that cannot even start would score a clean sweep.
    if b'done' not in p.stdout:
        return name, 'DIED(%d)' % rc
    return name, 'ok'


def main():
    args = sys.argv[1:]
    apython = args[0]
    jobs = int(args[args.index('--jobs') + 1]) if '--jobs' in args else (os.cpu_count() or 4)
    filt = args[args.index('--filter') + 1] if '--filter' in args else None
    todo = [c for c in cases() if not filt or filt in c[0]]
    bad = []
    with tempfile.TemporaryDirectory() as work:
        with ThreadPoolExecutor(jobs) as ex:
            for name, verdict in ex.map(lambda it: run(apython, work, it), enumerate(todo)):
                if verdict != 'ok':
                    bad.append((name, verdict))
    for name, verdict in bad:
        print('%s  %s' % (verdict, name))
    print('reentrant mutation: %d cases, %d crashed or hung' % (len(todo), len(bad)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
