"""rc_gap.py - where apython's tests go missing, from two rc_sweep.sh runs.

    python3 tests/rc_gap.py AP_DIR CP_DIR [--top N]

AP_DIR and CP_DIR are the $RC_OUTDIRs of `rc_sweep.sh ap` and `... cp`: each
holds sweep-<side>.tsv and logs/.  Three tables come out:

  1. totals -- the gap in passing tests, raw and with skips taken out of both
     sides, plus how much of it sits in modules the CONTROL could not run
     (a control that crashes makes the gap read smaller than it is);
  2. the modules losing the most tests, worst first;
  3. the causes -- the last exception line of every failing test in
     apython's logs, normalised and counted across all modules, so one
     missing feature that breaks forty modules ranks as one line, not forty.

`passing` here is the sweep's own: ran minus the distinct tests that failed.
A skipped test counts as passing in that number on both sides, which is why
the skip-excluded figure is the honest one.
"""

import os
import re
import sys
from collections import Counter, defaultdict


def load(d):
    side = "ap" if os.path.exists(os.path.join(d, "sweep-ap.tsv")) else "cp"
    rows = {}
    with open(os.path.join(d, f"sweep-{side}.tsv"), errors="replace") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) < 6:
                continue
            name, cat, rc, ran, bad, skip = p[:6]
            ran, bad, skip = int(ran or 0), int(bad or 0), int(skip or 0)
            rows[name] = dict(cat=cat, ran=ran, bad=bad, skip=skip,
                              passing=max(ran - bad, 0),
                              strict=max(ran - bad - skip, 0),
                              last=p[6] if len(p) > 6 else "")
    return rows


# A traceback's final line, made comparable across tests: quoted names,
# numbers and addresses vary between two instances of the same cause.
NORM = [
    (re.compile(r"0x[0-9a-f]+"), "0x…"),
    (re.compile(r"\b\d+\b"), "N"),
    (re.compile(r"'[^']{40,}'"), "'…'"),
]


def norm(line):
    line = line.strip()[:160]
    for rx, rep in NORM:
        line = rx.sub(rep, line)
    return line


HDR = re.compile(r"^(FAIL|ERROR): (\S+)")
EXC = re.compile(r"^[A-Za-z_][\w.]*(Error|Exception|Exit|Interrupt|Warning|"
                 r"error|Failure|StopIteration)\b.*")


def causes(logdir, modules):
    """Count, per normalised final exception line, the failing tests it ends."""
    count, where = Counter(), defaultdict(Counter)
    for m in modules:
        path = os.path.join(logdir, m + ".txt")
        try:
            text = open(path, "rb").read().decode("utf-8", "replace")
        except OSError:
            continue
        # unittest prints each failure as a block: a ==== rule, the FAIL:/
        # ERROR: header, a ---- rule, the traceback.  The cause is the last
        # exception-looking line before the next rule.
        blocks = re.split(r"^={50,}$", text, flags=re.M)
        seen = set()
        for b in blocks:
            lines = b.strip("\n").splitlines()
            if not lines:
                continue
            h = HDR.match(lines[0])
            if not h or h.group(2) in seen:
                continue
            seen.add(h.group(2))
            last = None
            for ln in lines[1:]:
                if ln.startswith("-" * 50) and last is not None:
                    break
                if EXC.match(ln):
                    last = ln
            key = norm(last) if last else "(no exception line)"
            count[key] += 1
            where[key][m] += 1
    return count, where


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    top = 30
    if "--top" in sys.argv:
        top = int(sys.argv[sys.argv.index("--top") + 1])
        args = [a for a in args if a != str(top)]
    if len(args) != 2:
        print(__doc__)
        sys.exit(2)
    ap, cp = load(args[0]), load(args[1])

    names = sorted(set(ap) | set(cp))
    z = dict(cat="ABSENT", ran=0, bad=0, skip=0, passing=0, strict=0, last="")
    raw = strict = 0
    broken_ctl = []
    gaps = []
    for n in names:
        a, c = ap.get(n, z), cp.get(n, z)
        g, gs = c["passing"] - a["passing"], c["strict"] - a["strict"]
        raw += g
        strict += gs
        if c["cat"] in ("CRASH", "HANG", "ERROR", "IMPORT") and a["passing"]:
            broken_ctl.append((n, c["cat"], a["passing"]))
        gaps.append((gs, g, n, a, c))

    tp = lambda d, k: sum(r[k] for r in d.values())
    print("=== totals ===")
    print(f"  passing          apython {tp(ap, 'passing'):6}  "
          f"cpython {tp(cp, 'passing'):6}  "
          f"({100 * tp(ap, 'passing') / max(tp(cp, 'passing'), 1):.1f}%)")
    print(f"  ex-skips         apython {tp(ap, 'strict'):6}  "
          f"cpython {tp(cp, 'strict'):6}  "
          f"({100 * tp(ap, 'strict') / max(tp(cp, 'strict'), 1):.1f}%)")
    print(f"  gap: raw {raw}, ex-skips {strict}")
    print(f"  crashes: apython "
          f"{sum(r['cat'] == 'CRASH' for r in ap.values())}, cpython "
          f"{sum(r['cat'] == 'CRASH' for r in cp.values())}; hangs: apython "
          f"{sum(r['cat'] == 'HANG' for r in ap.values())}, cpython "
          f"{sum(r['cat'] == 'HANG' for r in cp.values())}")
    if broken_ctl:
        print("  control could not run (apython passes there, uncounted):")
        for n, cat, p in broken_ctl:
            print(f"    {n:34} {cat:7} apython passes {p}")

    print(f"\n=== modules losing the most (ex-skips), top {top} ===")
    print(f"  {'module':34} {'gap':>5}  {'apython':>14}  {'cpython':>14}  "
          "apython's last exception")
    for gs, g, n, a, c in sorted(gaps, key=lambda t: -t[0])[:top]:
        if gs <= 0:
            break
        print(f"  {n:34} {gs:5}  {a['cat']:7}{a['strict']:7}  "
              f"{c['cat']:7}{c['strict']:7}  {a['last'][:70]}")

    count, where = causes(os.path.join(args[0], "logs"), sorted(ap))
    print(f"\n=== causes: final exception line of each failing test, "
          f"top {top} ===")
    for key, k in count.most_common(top):
        mods = ", ".join(f"{m} {v}" for m, v in where[key].most_common(3))
        print(f"  {k:5}  {key[:100]}\n         {mods}")


main()
