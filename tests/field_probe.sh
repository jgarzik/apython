#!/bin/bash
# field_probe.sh - third-party packages, under apython and under CPython.
#
# Runs every case in tests/field_probe.py once per interpreter, one process
# per case, and compares the two outputs line for line.  A REPORT, not a
# ratchet: what is installed differs from box to box, so there is no floor to
# hold it to.  Each case is classified
#
#   SAME     both printed the same thing -- an import, or a result
#   DIFF     both finished and disagree; the two lines are shown
#   AP-EXC   CPython succeeded and apython raised
#   AP-DIED  apython crashed, hung, or printed nothing at all
#   MISSING  the package is not installed (not counted either way)
#   BOTH-EXC both raised -- usually the case is wrong, not the interpreter
#
#   bash tests/field_probe.sh            # every case
#   bash tests/field_probe.sh -v         # also show the SAME ones
#   bash tests/field_probe.sh CASE...    # just these
#
# The reference is the HOST python3, not the CPython the sweep builds: the
# packages are the host's dist-packages, built and installed for it.
# apython is handed $CPYTHON_LIB for the standard library until it ships one
# of its own.

set -u

TESTDIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$TESTDIR")"
APYTHON=${APYTHON:-$ROOT/apython}
PYTHON=${FIELD_PYTHON:-python3}
CPYTHON_LIB=${CPYTHON_LIB:-$HOME/tmp/repo/cpython/Lib}
TIMEOUT=${FIELD_TIMEOUT:-60}
PROBE="$TESTDIR/field_probe.py"

VERBOSE=0
if [ "${1:-}" = "-v" ]; then VERBOSE=1; shift; fi

if [ ! -x "$APYTHON" ]; then echo "SKIP: $APYTHON not built"; exit 0; fi

if [ $# -gt 0 ]; then CASES="$*"; else CASES=$($PYTHON "$PROBE" --list); fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

run_case() {
    local c="$1" cp ap rc
    cp=$(cd "$WORK" && timeout "$TIMEOUT" "$PYTHON" "$PROBE" "$c" 2>/dev/null \
         | head -c 4000)
    ap=$(cd "$WORK" && PYTHONPATH="$CPYTHON_LIB" timeout "$TIMEOUT" \
         "$APYTHON" "$PROBE" "$c" 2>/dev/null | head -c 4000)
    rc=$?
    local cat
    case "$cp" in
        MISSING*) cat=MISSING ;;
        *)
            if [ "$cp" = "$ap" ]; then
                case "$cp" in EXC*) cat=BOTH-EXC ;; *) cat=SAME ;; esac
            elif [ -z "$ap" ]; then cat=AP-DIED
            else
                case "$ap" in
                    EXC*|MISSING*) cat=AP-EXC ;;
                    *) cat=DIFF ;;
                esac
            fi ;;
    esac
    printf '%s\t%s\n' "$cat" "$c"
    case "$cat" in
        SAME|MISSING) [ $VERBOSE -eq 1 ] && printf '    %s\n' "${ap:0:200}" ;;
        *) printf '    cpython: %s\n    apython: %s\n' "${cp:0:300}" "${ap:0:300}" ;;
    esac
}

for c in $CASES; do run_case "$c"; done > "$WORK/out"
cat "$WORK/out"
echo
echo "=== summary ==="
grep -E '^[A-Z-]+	' "$WORK/out" | cut -f1 | sort | uniq -c | sort -rn | sed 's/^/  /'
