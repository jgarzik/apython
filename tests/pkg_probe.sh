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
#   N/A     the package requires dynamic extension loading
#           or a multiprocessing start method the runtime cannot offer
#
# Compared against tests/pkg_floor.txt, which records the per-directory count
# of PASSING tests and the crash set.  A directory that passes fewer tests
# than it did, or a new crash, fails the target.  Raise the floor with
#   bash tests/pkg_probe.sh --record
# in the commit that earns it.
#
# Point CPYTHON_LIB at Lib/ in a full CPython source checkout.  The probe
# copies the tree so the tests cannot leave artifacts in the checkout.
# Pass package names (e.g. test_module) to check only those packages.
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
LIB_OVERRIDE=${CPYTHON_LIB:-}
CPYTHON_LIB=${CPYTHON_LIB:-$HOME/tmp/repo/cpython/Lib}
TIMEOUT=${PKG_TIMEOUT:-300}
JOBS=${PKG_JOBS:-5}
# A runaway allocation should fail the directory, not the machine.  3 GB is
# far more than any of these needs and well under what a desktop has.
VLIMIT=${PKG_VLIMIT:-3000000}
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

if [ ! -d "$CPYTHON_LIB" ] && [ -z "$LIB_OVERRIDE" ]; then
    echo "SKIP: no CPython Lib/ at $CPYTHON_LIB (set CPYTHON_LIB to override)"
    exit 0
fi
if [ ! -d "$CPYTHON_LIB/test" ] || [ ! -d "$CPYTHON_LIB/../Tools/peg_generator" ]; then
    echo "CPYTHON_LIB must point to Lib/ in a full CPython source tree with Lib/test and Tools/peg_generator" >&2
    exit 1
fi
if [ ! -x "$ROOT/$APYTHON" ] && [ ! -x "$APYTHON" ]; then
    echo "SKIP: $APYTHON not built"
    exit 0
fi
case "$APYTHON" in
    /*) APY="$APYTHON" ;;
    *)  APY="$ROOT/${APYTHON#./}" ;;
esac

RECORD=0
if [ "${1:-}" = "--record" ]; then
    RECORD=1
    shift
    if [ "$#" -ne 0 ]; then
        echo "--record requires a full package sweep" >&2
        exit 1
    fi
fi

list_pkgs() {
    ( cd "$CPYTHON_LIB/test" || exit
      for d in test_*/; do
          d=${d%/}
          [ -f "$d/__init__.py" ] && echo "$d"
      done ) | sort
}

list_pkgs > "$WORK/packages"
if [ "$#" -gt 0 ]; then
    for pkg in "$@"; do
        if ! grep -Fxq -- "$pkg" "$WORK/packages"; then
            echo "Unknown CPython test package: $pkg" >&2
            exit 1
        fi
    done
    printf '%s\n' "$@" | sort -u > "$WORK/selected"
else
    cp "$WORK/packages" "$WORK/selected" || exit 1
fi

mkdir "$WORK/cpython" || exit 1
(
    cd "$CPYTHON_LIB/.." || exit 1
    shopt -s dotglob
    for entry in *; do
        [ "$entry" = .git ] && continue
        cp -a --reflink=auto -- "$entry" "$WORK/cpython/" || exit 1
    done
) || exit 1
CPYTHON_LIB="$WORK/cpython/Lib"

CAPABILITIES=$(cd "$WORK" && PYTHONPATH="$CPYTHON_LIB" timeout "$TIMEOUT" \
    "$APY" -B -c 'import sys, sysconfig
print(sys.implementation.name, int(bool(sysconfig.get_config_var("HAVE_DYNAMIC_LOADING"))))') || exit 1
read -r IMPLEMENTATION DYNAMIC_LOADING <<< "$CAPABILITIES"
case "$DYNAMIC_LOADING" in
    0|1) ;;
    *) echo "Unexpected dynamic loading capability: $DYNAMIC_LOADING" >&2; exit 1 ;;
esac

# Some upstream tests start an isolated child, which ignores PYTHONPATH.
# Give an in-tree apython the same library even in those child processes.
APY_DIR=$(dirname "$(realpath "$APY")")
if [ "$IMPLEMENTATION" = apython ] && [ -d "$APY_DIR/stdlib" ] && [ -d "$APY_DIR/lib" ]; then
    mkdir -p "$WORK/runtime/build" || exit 1
    cp -- "$APY" "$WORK/runtime/apython" || exit 1
    cp -a -- "$APY_DIR/lib" "$WORK/runtime/lib" || exit 1
    if [ -f "$APY_DIR/build/_ctypes_test.so" ]; then
        cp -- "$APY_DIR/build/_ctypes_test.so" "$WORK/runtime/build/" || exit 1
    fi
    ln -s -- "$CPYTHON_LIB" "$WORK/runtime/stdlib" || exit 1
    APY="$WORK/runtime/apython"
fi

FORKSERVER=$(cd "$WORK" && PYTHONPATH="$CPYTHON_LIB" timeout "$TIMEOUT" \
    "$APY" -B -c 'import multiprocessing
print(int("forkserver" in multiprocessing.get_all_start_methods()))') || exit 1
case "$FORKSERVER" in
    0|1) ;;
    *) echo "Unexpected forkserver capability: $FORKSERVER" >&2; exit 1 ;;
esac

# A few tests consume bytecode fixtures. Some intentionally invalid sources
# in Lib/test make compileall return nonzero, so check a real cache entry.
if [ ! -f "$CPYTHON_LIB/test/__pycache__/__init__.cpython-312.pyc" ]; then
    "$PYTHON" -m compileall -q -j "$JOBS" "$CPYTHON_LIB" >/dev/null 2>&1 || true
    if [ ! -f "$CPYTHON_LIB/test/__pycache__/__init__.cpython-312.pyc" ]; then
        echo "Could not prepare bytecode with $PYTHON (CPython 3.12 required)" >&2
        exit 1
    fi
fi

# One directory, one process.  Writes a single tab-separated row.
probe_one() {
    local pkg="$1" out rc ran cwd
    if [ "$DYNAMIC_LOADING" = 0 ]; then
        case "$pkg" in
            test_cext|test_cppext)
                printf '%s\tN/A\t0\t0\n' "$pkg" >> "$WORK/results.txt"
                return
                ;;
        esac
    fi
    if [ "$pkg" = test_multiprocessing_forkserver ] && [ "$FORKSERVER" = 0 ]; then
        printf '%s\tN/A\t0\t0\n' "$pkg" >> "$WORK/results.txt"
        return
    fi
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
    if [ $rc -ge 132 ] && [ $rc -le 139 ]; then
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
export WORK APY CPYTHON_LIB TIMEOUT VLIMIT DYNAMIC_LOADING FORKSERVER

: > "$WORK/results.txt"
NPKG=$(wc -l < "$WORK/selected")
echo "Probing $NPKG package-style test directories from $CPYTHON_LIB/test"
xargs -P "$JOBS" -I{} bash -c 'probe_one "$@"' _ {} < "$WORK/selected" || exit 1
sort -k1,1 "$WORK/results.txt" -o "$WORK/results.txt"

PASS_TOTAL=$(awk -F'\t' '{n+=$3} END {print n+0}' "$WORK/results.txt")
RAN_TOTAL=$(awk -F'\t' '{n+=$4} END {print n+0}' "$WORK/results.txt")
NCRASH=$(awk -F'\t' '$2=="CRASH"||$2=="HANG"' "$WORK/results.txt" | wc -l)

echo
awk -F'\t' '{printf "  %-34s %-7s %5d/%-5d\n", $1, $2, $3, $4}' "$WORK/results.txt"
echo
echo "  passing $PASS_TOTAL of $RAN_TOTAL run, $NCRASH crashing"

if [ "$RECORD" -eq 1 ]; then
    {
        echo "# Passing-test count per package-style test directory, and the"
        echo "# crash set.  A ratchet: a directory must not pass fewer than"
        echo "# its number, and a new crash fails the target."
        echo "# Regenerate with: bash tests/pkg_probe.sh --record"
        awk -F'\t' '$2=="CRASH"||$2=="HANG"{print "crash " $1}' "$WORK/results.txt"
        {
            awk -F'\t' '$2!="N/A"{print "pass " $1 " " $3}' "$WORK/results.txt"
            awk 'NR==FNR {if ($2=="N/A") keep[$1]=1; next}
                $1=="pass" && ($2 in keep)' "$WORK/results.txt" "$FLOOR"
        } | sort -k2,2
    } > "$WORK/floor"
    mv "$WORK/floor" "$FLOOR" || exit 1
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
awk 'FILENAME==ARGV[1] {if ($2=="N/A") omit[$1]=1; next}
     /^pass / && !($2 in omit){print $2 "\t" $3}' \
    "$WORK/results.txt" "$FLOOR" | sort -k1,1 > "$WORK/floor_pass.txt"
awk -F'\t' '$2!="N/A"{print $1 "\t" $3}' "$WORK/results.txt" > "$WORK/now_pass.txt"
REGRESSED=$(join -t$'\t' "$WORK/floor_pass.txt" "$WORK/now_pass.txt" \
            | awk -F'\t' '$3 < $2 {printf "%s (%s -> %s)\n", $1, $2, $3}')
GAINED=$(join -t$'\t' "$WORK/floor_pass.txt" "$WORK/now_pass.txt" \
         | awk -F'\t' '$3 > $2 {printf "%s (%s -> %s)\n", $1, $2, $3}')
# A directory in the floor that did not report at all is a regression too.
VANISHED=$(join -t$'\t' -v1 "$WORK/floor_pass.txt" "$WORK/now_pass.txt" | cut -f1)
if [ "$#" -gt 0 ]; then
    VANISHED=$(comm -12 <(printf '%s\n' "$VANISHED") "$WORK/selected")
fi

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
if [ "$#" -gt 0 ]; then
    comm -12 "$WORK/floor_crash.txt" "$WORK/selected" > "$WORK/selected_crash.txt"
    mv "$WORK/selected_crash.txt" "$WORK/floor_crash.txt"
fi
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
