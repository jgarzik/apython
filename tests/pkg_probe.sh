#!/bin/bash
# pkg_probe.sh - CPython's PACKAGE-style test directories, run under apython.
#
# CPython's Lib/test holds two kinds of test module: a file, test_foo.py, and
# a package, test_foo/.  Every sweep this project ran globbed the first kind
# only, so the second was never measured at all -- twenty-one directories
# holding, in the CPython control, five thousand passing tests.  Three of them
# segfaulted the first time they were run.
#
# This is a ratchet over that region, not a report.  Each directory is run in
# a fresh process and classified:
#
#   OK      every test it ran passed
#   FAILED  it ran tests and some did not pass
#   ERROR   it ran no tests -- an import died, or a SkipTest at module scope
#   CRASH   the process died on a signal
#   HANG    it did not finish inside the timeout
#
# Compared against tests/pkg_floor.txt, which records the per-directory count
# of PASSING tests and the crash set.  A directory that passes fewer tests
# than it did, or a new crash, fails the target.  Raise the floor with
#   bash tests/pkg_probe.sh --record
# in the commit that earns it.
# Whole packages excluded by the mission scope still run and retain the
# crash check. Only their passing-test floor is omitted.
#
# Needs CPython's Lib/ (a source checkout, not an installed python).  Point
# $CPYTHON_LIB at it; the target skips cleanly when it is not there, so a
# build never depends on an out-of-tree checkout.
#
# A package cannot be named on the command line the way a file can, so each
# is driven through unittest's own loader, the way CPython's own suite is:
#
#   apython -m unittest test.<pkg>

set -u

APYTHON=${APYTHON:-./apython}
PYTHON=${PYTHON:-python3}
TESTDIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$TESTDIR")"
FLOOR="$TESTDIR/pkg_floor.txt"
SCOPE="$TESTDIR/conformance_scope.txt"
CPYTHON_LIB=${CPYTHON_LIB:-$HOME/tmp/repo/cpython/Lib}
TIMEOUT=${PKG_TIMEOUT:-300}
JOBS=${PKG_JOBS:-5}
# A runaway allocation should fail the directory, not the machine.  3 GB is
# far more than any of these needs and well under what a desktop has.
VLIMIT=${PKG_VLIMIT:-3000000}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

if [ ! -d "$CPYTHON_LIB" ]; then
    echo "SKIP: no CPython Lib/ at $CPYTHON_LIB (set CPYTHON_LIB to override)"
    exit 0
fi
if [ ! -x "$ROOT/$APYTHON" ] && [ ! -x "$APYTHON" ]; then
    echo "SKIP: $APYTHON not built"
    exit 0
fi
case "$APYTHON" in
    /*) APY="$APYTHON" ;;
    *)  APY="$ROOT/${APYTHON#./}" ;;
esac

# apython reads .pyc and never .py, so the reference tree has to be
# byte-compiled before anything can be found in it -- and unlike
# stdlib_probe.sh this one needs test/ compiled too, which is the expensive
# half.  CPython gitignores __pycache__, so doing it in place is invisible.
if [ ! -f "$CPYTHON_LIB/test/__pycache__/__init__.cpython-312.pyc" ]; then
    echo "byte-compiling $CPYTHON_LIB (one time, including test/)..."
    $PYTHON -m compileall -q -j0 "$CPYTHON_LIB" >/dev/null 2>&1
fi

list_pkgs() {
    ( cd "$CPYTHON_LIB/test" || exit
      for d in test_*/; do
          d=${d%/}
          [ -f "$d/__init__.py" ] && echo "$d"
      done ) | sort
}

in_scope_floors() {
    awk '
        NR == FNR {
            if ($1 == "exclude" && $2 ~ /^test\.test_[a-zA-Z0-9_]+\.\*$/) {
                split($2, parts, ".")
                excluded[parts[2]] = 1
            }
            next
        }
        !($1 in excluded)
    ' "$SCOPE" "$1"
}

# One directory, one process.  Writes a single tab-separated row.
probe_one() {
    local pkg="$1" out rc ran fail err cwd
    out="$WORK/$pkg.txt"
    # A cwd of its own, thrown away afterwards, for the reason rc_sweep.sh
    # gives at length: run in the repo root, a package that writes in its cwd
    # leaves the file there, and a leftover `tempcwd/` then makes test_pydoc
    # and test_warnings report failures that are not theirs.  Nothing here
    # needs the root -- every path involved is absolute.
    cwd=$(mktemp -d "$WORK/cwd-$pkg.XXXXXX") || return
    ( ulimit -v "$VLIMIT" 2>/dev/null
      cd "$cwd" || exit
      PYTHONPATH="$CPYTHON_LIB" timeout "$TIMEOUT" "$APY" -m unittest \
        "test.$pkg" ) > "$out" 2>&1
    rc=$?
    rm -rf "$cwd"          # after rc is taken: rm would clobber it
    # grep -a: a test that writes a NUL turns the log into a binary file, and
    # grep then answers nothing at all rather than the count.  That trap cost
    # a whole undercounted sweep once already.
    ran=$(grep -aoE '^Ran [0-9]+ test' "$out" | tail -1 | grep -oE '[0-9]+')
    : "${ran:=0}"
    # Passing is `ran` minus the DISTINCT tests that failed, counted from the
    # FAIL:/ERROR: headers rather than from the summary line.  The summary's
    # arithmetic does not close: one test can report several errors -- setUp
    # and a cleanup both raising is two -- so `ran - failures - errors` goes
    # NEGATIVE, and test_tools really does say "Ran 39" and "errors=45".  A
    # negative floor is worse than no floor, because a regression to zero
    # then reads as an improvement.
    local nbad
    nbad=$(grep -aoE '^(FAIL|ERROR): [^ ]+' "$out" \
           | sed -E 's/^(FAIL|ERROR): //' | sort -u | wc -l)
    local cat
    if [ "$rc" -gt 128 ] && [ "$rc" -le 192 ]; then
        cat=CRASH
    elif [ $rc -eq 124 ]; then
        cat=HANG
    elif [ "$ran" -eq 0 ]; then
        cat=ERROR
    elif [ "$nbad" -eq 0 ]; then
        cat=OK
    else
        cat=FAILED
    fi
    local pass=$(( ran - nbad ))
    [ "$pass" -lt 0 ] && pass=0
    printf '%s\t%s\t%s\t%s\n' "$pkg" "$cat" "$pass" "$ran" \
        >> "$WORK/results.txt"
}
export -f probe_one
export WORK ROOT APY CPYTHON_LIB TIMEOUT VLIMIT

: > "$WORK/results.txt"
NPKG=$(list_pkgs | wc -l)
echo "Probing $NPKG package-style test directories from $CPYTHON_LIB/test"
list_pkgs | xargs -P "$JOBS" -I{} bash -c 'probe_one "$@"' _ {}
sort -k1,1 "$WORK/results.txt" -o "$WORK/results.txt"

PASS_TOTAL=$(awk -F'\t' '{n+=$3} END {print n+0}' "$WORK/results.txt")
RAN_TOTAL=$(awk -F'\t' '{n+=$4} END {print n+0}' "$WORK/results.txt")
NCRASH=$(awk -F'\t' '$2=="CRASH"||$2=="HANG"' "$WORK/results.txt" | wc -l)

echo
awk -F'\t' '{printf "  %-34s %-7s %5d/%-5d\n", $1, $2, $3, $4}' "$WORK/results.txt"
echo
echo "  passing $PASS_TOTAL of $RAN_TOTAL run, $NCRASH crashing"

if [ "${1:-}" = "--record" ]; then
    {
        echo "# Passing-test count per package-style test directory, and the"
        echo "# crash set.  A ratchet: a directory must not pass fewer than"
        echo "# its number, and a new crash fails the target."
        echo "# Whole packages outside the mission scope retain only the crash check."
        echo "# Regenerate with: bash tests/pkg_probe.sh --record"
        awk -F'\t' '$2=="CRASH"||$2=="HANG"{print "crash " $1}' "$WORK/results.txt"
        in_scope_floors "$WORK/results.txt" | awk -F'\t' '{print "pass " $1 " " $3}'
    } > "$FLOOR"
    echo
    echo "recorded floor: $PASS_TOTAL passing, $NCRASH crashing -> $FLOOR"
    exit 0
fi

if [ ! -f "$FLOOR" ]; then
    echo "no floor file at $FLOOR; run with --record to create it"
    exit 1
fi

rc=0
# --- the passing counts, per directory -------------------------------------
awk '/^pass /{print $2 "\t" $3}' "$FLOOR" | sort -k1,1 > "$WORK/all_floors.txt"
in_scope_floors "$WORK/all_floors.txt" > "$WORK/floor_pass.txt"
awk -F'\t' '{print $1 "\t" $3}' "$WORK/results.txt" > "$WORK/now_pass.txt"
REGRESSED=$(join -t$'\t' "$WORK/floor_pass.txt" "$WORK/now_pass.txt" \
            | awk -F'\t' '$3 < $2 {printf "%s (%s -> %s)\n", $1, $2, $3}')
GAINED=$(join -t$'\t' "$WORK/floor_pass.txt" "$WORK/now_pass.txt" \
         | awk -F'\t' '$3 > $2 {printf "%s (%s -> %s)\n", $1, $2, $3}')
# A directory in the floor that did not report at all is a regression too.
VANISHED=$(join -t$'\t' -v1 "$WORK/floor_pass.txt" "$WORK/now_pass.txt" | cut -f1)

if [ -n "$GAINED" ]; then
    echo
    echo -e "${GREEN}newly passing${NC}:"
    echo "$GAINED" | sed 's/^/  /'
    echo "  (run 'bash tests/pkg_probe.sh --record' to raise the floor)"
fi
if [ -n "$REGRESSED" ]; then
    echo
    echo -e "${RED}REGRESSED${NC} — these pass fewer tests than they did:"
    echo "$REGRESSED" | sed 's/^/  /'
    rc=1
fi
if [ -n "$VANISHED" ]; then
    echo
    echo -e "${RED}MISSING${NC} — in the floor and did not report:"
    echo "$VANISHED" | tr '\n' ' ' | fold -s -w 76 | sed 's/^/  /'
    echo
    rc=1
fi

# --- the crash set ---------------------------------------------------------
awk '/^crash /{print $2}' "$FLOOR" | sort > "$WORK/floor_crash.txt"
awk -F'\t' '$2=="CRASH"||$2=="HANG"{print $1}' "$WORK/results.txt" | sort \
    > "$WORK/now_crash.txt"
NEWCRASH=$(comm -13 "$WORK/floor_crash.txt" "$WORK/now_crash.txt")
FIXEDCRASH=$(comm -23 "$WORK/floor_crash.txt" "$WORK/now_crash.txt")
if [ -n "$NEWCRASH" ]; then
    echo
    echo -e "${RED}NEW CRASHES${NC} — these did not crash before:"
    echo "$NEWCRASH" | tr '\n' ' ' | fold -s -w 76 | sed 's/^/  /'
    echo
    rc=1
fi
if [ -n "$FIXEDCRASH" ]; then
    echo
    echo -e "${GREEN}no longer crashing${NC}:"
    echo "$FIXEDCRASH" | tr '\n' ' ' | fold -s -w 76 | sed 's/^/  /'
    echo
    echo "  (record to tighten)"
fi

echo
if [ $rc -eq 0 ]; then
    echo -e "${GREEN}PASS${NC} package scoreboard: $PASS_TOTAL passing, $NCRASH crashing"
else
    echo -e "${RED}FAIL${NC} package scoreboard"
fi
exit $rc
