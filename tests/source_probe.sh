#!/bin/bash
# source_probe.sh - Run the whole test corpus through our own compiler.
#
# The ordinary suite hands apython a .pyc that CPython produced; this hands it
# the .py and makes apython compile it.  Every file is a differential test of
# the compiler against CPython for free, and it is the only thing that has ever
# exercised the compiler on a large body of ordinary code -- most of its bugs
# were found here rather than by a test written for them.
#
# Ratchets against tests/compile_floor.txt: a file that used to match and now
# does not is a failure, and so is a file that crashes.  Raise the floor with
#
#     bash tests/source_probe.sh --record
#
# in the commit that earns it.
set -u

APYTHON=./apython
PYTHON=python3
TESTDIR=tests
FLOOR=tests/compile_floor.txt
RECORD=0
[ "${1:-}" = "--record" ] && RECORD=1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

# Files whose output is legitimately different depending on which compiler
# produced the bytecode, and so cannot be a differential test of anything.
# The list is empty: test_traceback_carets was on it because our location
# table carried no columns, so a report rendered from our own bytecode had no
# caret rows.  It emits the long form now and the two reports match.
SKIP=""

# The skip list is itself ratcheted: a name here that no longer needs to be
# is a skip that has outlived its reason, and a list nothing checks grows
# quietly.  Each is re-run at the end and reported if it now matches.

matched=""
failed=""
crashed=""
skipped=""

for test_py in "$TESTDIR"/test_*.py; do
    name=$(basename "$test_py" .py)

    case " $SKIP " in
        *" $name "*) skipped="$skipped $name"; continue ;;
    esac

    # The same oracle the ordinary suite uses: CPython, except for the handful
    # of tests that crash it, which record their expected output instead.
    if [ -f "$TESTDIR/expected/$name.txt" ]; then
        expected=$(cat "$TESTDIR/expected/$name.txt")
    else
        expected=$(timeout 60 $PYTHON "$test_py" 2>&1) || true
    fi

    # A package under tests/ that exists to be imported from source must not
    # have a __pycache__ when apython runs, or it reads the .pyc instead.
    rm -rf "$TESTDIR"/srcpkg/__pycache__ "$TESTDIR"/srcpkg/*/__pycache__

    actual=$(timeout 60 $APYTHON "$test_py" 2>&1)
    status=$?
    # A recorded oracle is a transcript of the .pyc run, whose co_filename is
    # the relative path py_compile was given.  Run from source, the script is
    # named by its absolute path, as CPython names it -- so map that back.
    if [ -f "$TESTDIR/expected/$name.txt" ]; then
        actual=${actual//"$PWD/$TESTDIR/"/"$TESTDIR/"}
    fi

    if [ $status -ge 128 ]; then
        crashed="$crashed $name"
    elif [ "$expected" = "$actual" ]; then
        matched="$matched $name"
    else
        failed="$failed $name"
    fi
done

n_match=$(echo $matched | wc -w)
n_fail=$(echo $failed | wc -w)
n_crash=$(echo $crashed | wc -w)
n_skip=$(echo $skipped | wc -w)
total=$((n_match + n_fail + n_crash))

if [ $RECORD -eq 1 ]; then
    {
        echo "# Test files that our own compiler runs identically to CPython."
        echo "# Recorded by: bash tests/source_probe.sh --record"
        echo "# A name here that stops matching is a regression; a name missing"
        echo "# from here that starts matching should be added in the same commit."
        for n in $matched; do echo "$n"; done
    } > "$FLOOR"
    echo "recorded $n_match matching files to $FLOOR"
    exit 0
fi

if [ ! -f "$FLOOR" ]; then
    echo "no $FLOOR; run: bash tests/source_probe.sh --record"
    exit 1
fi

regressed=""
for n in $(grep -v '^#' "$FLOOR" | grep -v '^$'); do
    case " $matched " in
        *" $n "*) ;;
        *) regressed="$regressed $n" ;;
    esac
done

# A skipped file that now matches should come off the list.
unskipped=""
for name in $SKIP; do
    test_py="$TESTDIR/$name.py"
    [ -f "$test_py" ] || continue
    if [ -f "$TESTDIR/expected/$name.txt" ]; then
        expected=$(cat "$TESTDIR/expected/$name.txt")
    else
        expected=$(timeout 60 $PYTHON "$test_py" 2>&1) || true
    fi
    actual=$(timeout 60 $APYTHON "$test_py" 2>&1)
    if [ "$expected" = "$actual" ]; then
        unskipped="$unskipped $name"
    fi
done

echo ""
echo "source compiler: $n_match matching, $n_fail differing, $n_crash crashing, $n_skip skipped, $total total"

status=0
if [ -n "$crashed" ]; then
    echo -e "${RED}CRASH${NC}$crashed"
    status=1
fi
if [ -n "$regressed" ]; then
    echo -e "${RED}REGRESSED${NC}$regressed"
    status=1
fi

# A file that now matches but is not in the floor is not a failure -- it is a
# ratchet waiting to be raised.
gained=""
for n in $matched; do
    if ! grep -qx "$n" "$FLOOR"; then gained="$gained $n"; fi
done
[ -n "$gained" ] && echo -e "${YELLOW}NEW${NC}$gained (raise the floor: bash tests/source_probe.sh --record)"

[ -n "$unskipped" ] && echo -e "${YELLOW}UNSKIP${NC}$unskipped (matches now; take it out of SKIP)"

[ $status -eq 0 ] && echo -e "${GREEN}PASS${NC} source-compiler scoreboard: $n_match matching, 0 crashing"
exit $status
