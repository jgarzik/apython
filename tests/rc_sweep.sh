#!/bin/bash
# rc_sweep.sh - the release-candidate measurement: CPython's own Lib/test,
# run under apython, and the same corpus run under CPython for a control.
#
# This is the instrument the RC gate is judged by, and it is a REPORT rather
# than a ratchet -- it takes about ten minutes a side, which is too long for
# `make check`.  The ratchets over subsets of the same ground are
# tests/stdlib_probe.sh (can a module be imported at all) and
# tests/pkg_probe.sh (the package-style test directories).  This one is the
# whole of Lib/test/test_*.py, which is where the headline percentage comes
# from.
#
#   bash tests/rc_sweep.sh ap      # apython
#   bash tests/rc_sweep.sh cp      # CPython, for the control
#
# Results land in $OUTDIR (default: a directory under /tmp named for the
# side): one log per module, plus sweep-<side>.tsv with a row per module of
#
#   name  category  exit  ran  failing  skipped  last-exception-line
#
# Categories: OK, FAILED, IMPORT, SYNTAX, SKIP, NOTESTS, ERROR, CRASH, HANG.
# The number that matters is `passing`, summed -- and it is `ran` minus the
# DISTINCT tests that failed, counted from the FAIL:/ERROR: headers, not from
# the summary line.  unittest's summary does not close: one test can report
# several errors (setUp and a cleanup both raising is two), so
# `ran - failures - errors` goes negative.  test_tools really does say
# "Ran 39 tests" and "errors=45".
#
# Three traps this script exists to avoid, each of which has cost a whole
# wasted sweep at some point:
#
#  1. PYTHONPATH must name Lib/, not Lib/test/.  apython adds the script's own
#     directory, so without it every module dies on `import random` and the
#     sweep measures nothing.
#  2. grep needs -a.  A test that writes a NUL byte turns its log into a
#     binary file, and grep then answers nothing rather than the count, so the
#     module silently scores zero.
#  3. A module that forks, or that execs, can replace or outlive the runner.
#     The ulimit and the timeout are what keep one bad module from taking the
#     sweep with it.
#  4. Each module runs in a scratch directory of its own, thrown away
#     afterwards.  They used to run in the REPO ROOT, and a test that writes
#     in its cwd left the file there: `tempcwd/`, `@test_<pid>_tmp*` and once
#     a 586 MB one from test_largefile.  Two things came of that.  The debris
#     showed up as untracked files and got committed by anyone reaching for
#     `git add -A`; and, worse, it perturbed the NEXT run -- a leftover
#     `tempcwd/` makes test_pydoc, test_warnings, test_shutil, test_subprocess
#     and test_tarfile report failures that are not there, which has been
#     mistaken for a regression more than once.

set -u

SIDE=${1:-ap}
APYTHON=${APYTHON:-./apython}
# The control.  It must be the CPython that $CPYTHON_LIB belongs to: the
# system python3 is an older 3.12 point release, and run over a newer Lib/
# it segfaulted or hung on a dozen modules (test_typing, test_list,
# test_exceptions, test_fstring among them) that apython passed -- which
# made the gap read SMALLER than it is.  Build the checkout out of tree,
#   mkdir ~/tmp/cpython-build && cd ~/tmp/cpython-build &&
#   ../repo/cpython/configure && make -j
# and this picks it up; python3 is the fallback when there is none.
CPYTHON_BIN=${CPYTHON_BIN:-$HOME/tmp/cpython-build/python}
if [ -z "${PYTHON:-}" ]; then
    if [ -x "$CPYTHON_BIN" ]; then PYTHON=$CPYTHON_BIN; else PYTHON=python3; fi
fi
TESTDIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$TESTDIR")"
CPYTHON_LIB=${CPYTHON_LIB:-$HOME/tmp/repo/cpython/Lib}
TIMEOUT=${RC_TIMEOUT:-90}
JOBS=${RC_JOBS:-6}
VLIMIT=${RC_VLIMIT:-3000000}
OUTDIR=${RC_OUTDIR:-/tmp/apython-rc-sweep-$SIDE}

if [ ! -d "$CPYTHON_LIB" ]; then
    echo "SKIP: no CPython Lib/ at $CPYTHON_LIB (set CPYTHON_LIB to override)"
    exit 0
fi
case "$SIDE" in
    ap)
        case "$APYTHON" in
            /*) RUNNER="$APYTHON" ;;
            *)  RUNNER="$ROOT/${APYTHON#./}" ;;
        esac
        if [ ! -x "$RUNNER" ]; then echo "SKIP: $RUNNER not built"; exit 0; fi
        ;;
    cp) RUNNER=$PYTHON ;;
    *)  echo "usage: bash tests/rc_sweep.sh [ap|cp]"; exit 2 ;;
esac

# apython reads .pyc and never .py, so the reference tree has to be
# byte-compiled first -- test/ included, which is the expensive half.
if [ ! -f "$CPYTHON_LIB/test/__pycache__/__init__.cpython-312.pyc" ]; then
    echo "byte-compiling $CPYTHON_LIB (one time, including test/)..."
    $PYTHON -m compileall -q -j0 "$CPYTHON_LIB" >/dev/null 2>&1
fi

mkdir -p "$OUTDIR/logs" "$OUTDIR/cwd"
TSV="$OUTDIR/sweep-$SIDE.tsv"

# Anything left in a scratch cwd by an earlier, killed run.  They are removed
# per module below; this is for the sweep that did not get to finish.
rm -rf "${OUTDIR:?}/cwd"/* 2>/dev/null

run_one() {
    local f="$1" b out rc ran nbad pass skip cat last work
    b=$(basename "$f" .py)
    out="$OUTDIR/logs/$b.txt"
    # A cwd of its own, so what the module writes there goes with it.  Nothing
    # needs the repo root: the runner, the module and PYTHONPATH are all
    # absolute paths, and apython finds lib/ relative to its own binary.
    work=$(mktemp -d "$OUTDIR/cwd/$b.XXXXXX") || return
    ( ulimit -v "$VLIMIT" 2>/dev/null
      cd "$work" || exit
      PYTHONPATH="$CPYTHON_LIB" timeout "$TIMEOUT" "$RUNNER" "$f" ) > "$out" 2>&1
    rc=$?
    # After rc is taken: rm would clobber it.  A module that forked and
    # outlived the runner may still be writing in here, and removing the
    # directory under it is the point -- the alternative is the repo.
    rm -rf "$work"
    ran=$(grep -aoE '^Ran [0-9]+ test' "$out" | tail -1 | grep -oE '[0-9]+')
    skip=$(grep -aoE 'skipped=[0-9]+' "$out" | tail -1 | grep -oE '[0-9]+')
    : "${ran:=0}" "${skip:=0}"
    nbad=$(grep -aoE '^(FAIL|ERROR): [^ ]+' "$out" \
           | sed -E 's/^(FAIL|ERROR): //' | sort -u | wc -l)
    pass=$(( ran - nbad )); [ "$pass" -lt 0 ] && pass=0
    if [ $rc -ge 132 ] && [ $rc -le 139 ]; then cat=CRASH
    elif [ $rc -eq 124 ]; then cat=HANG
    elif [ "$ran" -gt 0 ]; then
        if [ "$nbad" -eq 0 ]; then cat=OK; else cat=FAILED; fi
    elif grep -aqE '^(ModuleNotFoundError|ImportError)' "$out"; then cat=IMPORT
    elif grep -aqE '^(SyntaxError|IndentationError)' "$out"; then cat=SYNTAX
    elif grep -aqE 'unittest\.case\.SkipTest|^SkipTest' "$out"; then cat=SKIP
    elif [ $rc -eq 0 ]; then cat=NOTESTS
    else cat=ERROR; fi
    # The last line that looks like an exception, for triage at a glance.
    last=$(grep -aE '^[A-Za-z_][A-Za-z_.]*(Error|Exception|Warning|SkipTest)\b' \
           "$out" | tail -1 | cut -c1-160 | tr -d '\t')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$b" "$cat" "$rc" "$ran" "$nbad" "$skip" "$last"
}
export -f run_one
export OUTDIR ROOT RUNNER CPYTHON_LIB TIMEOUT VLIMIT

NMOD=$(ls "$CPYTHON_LIB"/test/test_*.py | wc -l)
echo "Sweeping $NMOD test modules from $CPYTHON_LIB/test under $RUNNER"
ls "$CPYTHON_LIB"/test/test_*.py \
  | xargs -P "$JOBS" -I{} bash -c 'run_one "$@"' _ {} \
  | sort -k1,1 > "$TSV"

echo
echo "=== categories ==="
cut -f2 "$TSV" | sort | uniq -c | sort -rn | sed 's/^/  /'
echo
echo "=== totals ==="
awk -F'\t' '{r+=$4; b+=$5; s+=$6; p += ($4 > $5 ? $4 - $5 : 0)}
            END {printf "  ran=%d failing=%d skipped=%d passing=%d\n",
                        r, b, s, p}' "$TSV"
echo "  modules running at least one test: $(awk -F'\t' '$4>0' "$TSV" | wc -l) of $NMOD"
echo
echo "rows: $TSV"
echo "logs: $OUTDIR/logs/"
