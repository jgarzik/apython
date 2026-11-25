#!/usr/bin/env python3
"""Where an error leaves a function by JUMPING instead of by returning.

A jump-style raise (`RAISE`, `call raise_exception`, `jmp
eval_exception_unwind`, a call to any helper that ends in one) abandons every
native frame between itself and the eval loop.  That is right inside an opcode
handler, which IS the eval loop, and wrong everywhere else: the references
those frames held leak, and a caller written in assembly cannot absorb the
error.  Everything that is CALLED reports an error by setting the exception
and returning 0 (or -1, for a function whose 0 is an answer).

It is true now outside src/opcodes/ and src/eval.asm, and lint.py keeps it so:
this module is what its wall and its must-check rule are built on.  Run
directly it prints the map of where the handlers jump:

    python3 src/compiler/raisemap.py              per-file counts
    python3 src/compiler/raisemap.py FILE...      every site in those files
    python3 src/compiler/raisemap.py --order DIR  functions leaf-first
    python3 src/compiler/raisemap.py --callers F  who calls F, and whether
                                                  each call is checked
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# The three ways into the unwinder that everything else is built from.
SEEDS = frozenset(('raise_exception', 'raise_exception_obj',
                   'eval_exception_unwind'))

# Macros that expand to a jump-style raise.
RAISE_MACROS = ('RAISE', 'NO_KEYWORDS', 'NO_KEYWORDS_TP_INIT')
# The transitional propagation: counted apart from the raises themselves,
# because converting ONE callee adds one of these at each caller that cannot
# return an error yet.  Both numbers end at zero outside the handlers.
JUMP_RE = re.compile(r'^\s*ERR_(?:NULL|M1|PENDING)_JUMP\b')
MACRO_RE = re.compile(r'^\s*(%s)\b' % '|'.join(RAISE_MACROS))
BRANCH_RE = re.compile(r'^\s*(call|jmp|j[a-z]{1,3})\s+([A-Za-z_][\w.]*)\s*$')
DEF_RE = re.compile(r'^DEF_FUNC(?:_LOCAL|_BARE)?\s+(\w+)')
END_RE = re.compile(r'^END_FUNC\s+(\w+)')
CHECK_RE = re.compile(r'^\s*(ERR_NULL|ERR_M1|ERR_PENDING|ERR_DICT_GET|ERR_DICT_IDX)'
                      r'(_JUMP)?\b')
# `;; Fails: 0`, `;; Fails: 0?` or `;; Fails: -1` in a docblock is the
# function's promise that it RETURNS its own errors, and what it returns for
# one: 0; 0 with an exception pending (0 alone is an answer); -1 with an
# exception pending (-1 alone is an answer).
FAILS_RE = re.compile(r'^;;\s*Fails:\s*(\S+)')

# Where a jump IS the design: the handlers and the loop they belong to.
def is_handler_file(path):
    return path.startswith('src/opcodes/') or path == 'src/eval.asm'


def all_asm():
    return sorted(p for p in glob.glob('src/**/*.asm', recursive=True))


def strip(line):
    """The code part of a line: no comment, and no quoted text."""
    out, q = [], None
    for ch in line:
        if q:
            if ch == q:
                q = None
            continue
        if ch in '"\'`':
            q = ch
            continue
        if ch == ';':
            break
        out.append(ch)
    return ''.join(out).rstrip()


LABELS = {}     # column-0 label inside a function -> that function's name


class Func:
    __slots__ = ('name', 'path', 'line', 'body', 'fails', 'sites', 'calls',
                 'has_ret')

    def __init__(self, name, path, line):
        self.name, self.path, self.line = name, path, line
        self.body = []          # (lineno, code)
        self.fails = None       # '0' / '-1' / None
        self.sites = []         # (lineno, what) -- filled by classify()
        self.calls = []         # (lineno, kind, target)
        self.has_ret = False


def macro_bodies():
    """{macro name: [code lines]} for every %macro in any .asm or .inc."""
    bodies = {}
    for path in all_asm() + sorted(glob.glob('src/include/*.inc')) \
            + ['src/compiler/compiler.inc']:
        name = None
        try:
            lines = open(path, errors='replace').read().split('\n')
        except FileNotFoundError:
            continue
        for raw in lines:
            m = re.match(r'^\s*%macro\s+(\w+)', raw)
            if m:
                name = m.group(1)
                bodies.setdefault(name, [])
                continue
            if re.match(r'^\s*%endmacro\b', raw):
                name = None
                continue
            if name:
                code = strip(raw)
                if code.strip():
                    bodies[name].append(code)
    return bodies


def raising_macros(noret):
    """Macros, in any .asm or .inc, whose body ends up in a jump-style raise:
    SOCK_CHECK, POSIX_CHECK and their kind.  A use of one is a site like any
    other, and without this a file full of them reads as clean.  The
    ERR_*_JUMP forms are left out: they are counted on their own."""
    bodies = macro_bodies()
    bad = set(RAISE_MACROS)
    changed = True
    while changed:
        changed = False
        for name, body in bodies.items():
            if name in bad or JUMP_RE.match('    ' + name) \
                    or name.startswith('ERR_'):
                continue
            for code in body:
                m = BRANCH_RE.match(code)
                w = re.match(r'^\s*(\w+)', code)
                if (m and m.group(2) in noret) or (w and w.group(1) in bad):
                    bad.add(name)
                    changed = True
                    break
    return bad


def jumping_macros(noret, seeds=()):
    """Every macro whose expansion can NAME the unwinder, by any route: a
    token of its body is a never-returning function, one of `seeds`, or
    another such macro.  Wider than raising_macros on purpose -- it takes
    ERR_*_JUMP and a macro handed the unwinder as an argument too -- because
    it is what the wall in lint.py forbids outside the handlers."""
    bodies = macro_bodies()
    bad = set(RAISE_MACROS) | set(seeds)
    changed = True
    while changed:
        changed = False
        for name, body in bodies.items():
            if name in bad:
                continue
            if any(t in noret or t in bad
                   for code in body
                   for t in re.findall(r'[A-Za-z_]\w*', code)):
                bad.add(name)
                changed = True
    return bad


def parse(paths):
    """{name: Func} plus {path: [Func]}; a name defined twice keeps both."""
    funcs, byfile = {}, {}
    LABELS.clear()
    for path in paths:
        lines = open(path, errors='replace').read().split('\n')
        cur, in_macro = None, False
        byfile[path] = []
        for i, raw in enumerate(lines, 1):
            if re.match(r'^\s*%macro\s', raw):
                in_macro = True
            elif re.match(r'^\s*%endmacro\b', raw):
                in_macro = False
                continue
            if in_macro:
                continue
            m = DEF_RE.match(raw)
            if m:
                cur = Func(m.group(1), path, i)
                # the docblock above it carries the Fails: marker
                j = i - 2
                while j >= 0 and not lines[j].startswith(';;'):
                    if lines[j].strip() and not (
                            re.match(r'^\w+\s+equ\s', lines[j])
                            or re.match(r'^\s*;', lines[j])
                            or re.match(r'^\s*(?:extern|global|align)\s', lines[j])):
                        break
                    j -= 1
                while j >= 0 and lines[j].startswith(';;'):
                    f = FAILS_RE.match(lines[j])
                    if f:
                        cur.fails = f.group(1)
                    j -= 1
                byfile[path].append(cur)
                funcs.setdefault(cur.name, cur)
                continue
            if END_RE.match(raw):
                cur = None
                continue
            if cur is None:
                continue
            # A column-0 label inside a function is a second way into it
            # (`jmp rtn_compose`); it answers for the function it is in.
            lm = re.match(r'^([A-Za-z_]\w*):', raw)
            if lm:
                LABELS.setdefault(lm.group(1), cur.name)
            code = strip(raw)
            if code.strip():
                cur.body.append((i, code))
    return funcs, byfile


def classify(funcs, byfile):
    """Fill .sites and .calls; return (noreturn names, may-jump names)."""
    every = [f for fs in byfile.values() for f in fs]
    for f in every:
        f.calls = []
        f.has_ret = False
        for n, code in f.body:
            s = code.strip()
            if re.match(r'^(ret|DISPATCH|iretq)\b', s) or 'DISPATCH' == s:
                f.has_ret = True
            m = BRANCH_RE.match(code)
            if m and not m.group(2).startswith('.'):
                t = m.group(2)
                t = LABELS.get(t, t) if t not in funcs else t
                if t != f.name:
                    f.calls.append((n, m.group(1), t))

    # A raiser that never comes back: no `ret`, and every way out of it is a
    # jump-style raise.  Found to a fixed point, since they are built on each
    # other (raise_no_attribute -> eval_exception_unwind).  They all live in
    # the handler files now -- src/opcodes/raise.asm, and a few a handler
    # keeps beside itself.
    noret = set(SEEDS)
    changed = True
    while changed:
        changed = False
        for f in every:
            if f.name in noret or f.has_ret:
                continue
            outs = [t for _, k, t in f.calls if k == 'jmp']
            hits = [t for _, k, t in f.calls if t in noret]
            macro = any(MACRO_RE.match(c) for _, c in f.body)
            if not hits and not macro:
                continue
            if any(t not in noret and t in funcs for t in outs):
                continue
            # it must END in one: the last branch or macro in the body
            last = None
            for n, code in f.body:
                if MACRO_RE.match(code):
                    last = 'raise'
                else:
                    m = BRANCH_RE.match(code)
                    if m and m.group(1) in ('call', 'jmp') \
                            and not m.group(2).startswith('.'):
                        t = m.group(2)
                        t = LABELS.get(t, t) if t not in funcs else t
                        if t != f.name:
                            last = 'raise' if t in noret else 'other'
            if last == 'raise':
                noret.add(f.name)
                changed = True

    macros = raising_macros(noret)
    for f in every:
        f.sites = []
        for n, code in f.body:
            m = re.match(r'^\s*(\w+)\b', code)
            if m and m.group(1) in macros:
                f.sites.append((n, m.group(1)))
                continue
            m = BRANCH_RE.match(code)
            t = m.group(2) if m else None
            if t is not None and t not in funcs:
                t = LABELS.get(t, t)
            if t is not None and t in noret and t != f.name:
                f.sites.append((n, '%s %s' % (m.group(1), m.group(2))))

    # May-jump: has a site of its own, or calls something that does.
    may = set(f.name for f in every
              if f.sites or any(JUMP_RE.match(c) for _, c in f.body)) | noret
    changed = True
    while changed:
        changed = False
        for f in every:
            if f.name in may:
                continue
            if any(t in may for _, _, t in f.calls):
                may.add(f.name)
                changed = True
    return noret, may


def file_counts(byfile):
    return {p: sum(len(f.sites) for f in fs) for p, fs in byfile.items()}


def jump_counts(byfile):
    """ERR_*_JUMP per file: callers still waiting to return an error."""
    return {p: sum(1 for f in fs for _, c in f.body if JUMP_RE.match(c))
            for p, fs in byfile.items()}


def load():
    os.chdir(ROOT)
    funcs, byfile = parse(all_asm())
    noret, may = classify(funcs, byfile)
    return funcs, byfile, noret, may


def unchecked_calls(funcs, byfile):
    """Calls to a function that promises to return its errors (`Fails:`), not
    followed by a check.  -> [(path, line, caller, callee)]

    The check is ERR_NULL / ERR_M1 (or their _JUMP forms) within the next
    three instructions, or the words `err:` in a comment on the call line --
    a waiver that says why the error cannot happen or where it IS checked.
    """
    bad = []
    for path, fs in byfile.items():
        raw = None
        for f in fs:
            for idx, (n, code) in enumerate(f.body):
                m = BRANCH_RE.match(code)
                if not m or m.group(1) != 'call':
                    continue
                callee = funcs.get(m.group(2))
                if callee is None or callee.fails is None:
                    continue
                if any(CHECK_RE.match(c) for _, c in f.body[idx + 1:idx + 4]):
                    continue
                if raw is None:
                    raw = open(path, errors='replace').read().split('\n')
                if 'err:' in raw[n - 1]:
                    continue
                bad.append((path, n, f.name, callee.name))
    return bad


def main(argv):
    funcs, byfile, noret, may = load()
    counts = file_counts(byfile)
    if '--order' in argv:
        want = argv[argv.index('--order') + 1]
        rows = [f for p, fs in byfile.items() if p.startswith(want) for f in fs
                if f.sites]
        # leaf-first: fewest may-jump callees first
        def depth(f):
            return sum(1 for _, _, t in f.calls if t in may and t not in noret)
        for f in sorted(rows, key=lambda f: (depth(f), f.path, f.line)):
            print("%-34s %-28s sites=%-3d fallible-callees=%d%s"
                  % (f.path, f.name, len(f.sites), depth(f),
                     '' if f.has_ret else '  NORETURN'))
        return 0
    if '--callers' in argv:
        want = argv[argv.index('--callers') + 1]
        for p, fs in sorted(byfile.items()):
            for f in fs:
                for n, k, t in f.calls:
                    if t == want:
                        print("%s:%d  %s  (%s)" % (p, n, f.name, k))
        return 0
    if '--noreturn' in argv:
        for name in sorted(noret):
            f = funcs.get(name)
            print("%-34s %s" % (name, f.path if f else '-'))
        return 0
    files = [a for a in argv if a.endswith('.asm')]
    if files:
        for p in files:
            for f in byfile.get(p, ()):
                for n, what in f.sites:
                    print("%s:%d  %-28s %s" % (p, n, f.name, what))
        return 0
    hand = sum(n for p, n in counts.items() if is_handler_file(p))
    rest = sum(n for p, n in counts.items() if not is_handler_file(p))
    for p, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        if n:
            print("%5d  %s" % (n, p))
    jumps = sum(n for p, n in jump_counts(byfile).items()
                if not is_handler_file(p))
    print("%d transitional ERR_*_JUMP outside the handlers" % jumps)
    print("\n%d site(s): %d in the handlers, %d elsewhere; %d never-returning"
          " raiser(s); %d of %d functions can reach one"
          % (hand + rest, hand, rest, len(noret) - len(SEEDS),
             len(may), sum(len(fs) for fs in byfile.values())))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
