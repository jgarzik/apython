#!/bin/bash
# run_tests.sh - Test runner for apython
# Compiles .py to .pyc, runs both python3 and ./apython, diffs output

set -e

APYTHON=./apython
PYTHON=python3
TESTDIR=tests
TIMEOUT=60          # no test should take anywhere near this; a hang must not
                    # wedge the run until CI's own job limit kills it
PASS=0
FAIL=0
SKIP=0
ERRORS=""

# Private scratch, so two concurrent runs cannot clobber each other's output
# and a leftover file owned by someone else cannot make a selftest "fail".
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# The oracle names itself.  Almost every test here is a diff against whatever
# `python3` happens to be, so when one disagrees the first question is which
# CPython answered -- and a run that does not say cannot be compared against
# another machine's.  test_generator_frame was green here and red on CI for
# exactly that reason.
echo "oracle: $($PYTHON -VV 2>&1 | head -1)"

# Value encoding self-test: verifies the NaN-box boundaries directly, before
# any Python-level test can be misled by a mis-encoded value.
printf "%-40s " "value encoding selftest"
if $APYTHON --selftest-value > "$WORK/selftest.out" 2>&1; then
    printf "${GREEN}PASS${NC}\n"
    PASS=$((PASS + 1))
else
    printf "${RED}FAIL${NC}\n"
    cat "$WORK/selftest.out"
    FAIL=$((FAIL + 1))
    ERRORS="$ERRORS value-selftest"
fi

# The allocator, before anything that allocates.  An allocator bug reaches a
# Python-level test as data corruption in code that is correct, which is the
# hardest kind of failure to localise; this runs against ap_malloc/ap_free/
# ap_realloc directly, with no objects and no eval loop.
printf "%-40s " "pool allocator selftest"
if $APYTHON --selftest-alloc > "$WORK/alloctest.out" 2>&1; then
    printf "${GREEN}PASS${NC}\n"
    PASS=$((PASS + 1))
else
    printf "${RED}FAIL${NC}\n"
    cat "$WORK/alloctest.out"
    FAIL=$((FAIL + 1))
    ERRORS="$ERRORS alloc-selftest"
fi

# Static checks over the assembly: 64-bit reads of 4-byte struct fields, and
# calls made with a misaligned rsp.  Both assemble cleanly and fail at runtime
# far from the cause, so they are checked here rather than discovered.
printf "%-40s " "compiler lint"
if $PYTHON src/compiler/lint.py > "$WORK/lint.out" 2>&1; then
    printf "${GREEN}PASS${NC}\n"
    PASS=$((PASS + 1))
else
    printf "${RED}FAIL${NC}\n"
    cat "$WORK/lint.out"
    FAIL=$((FAIL + 1))
    ERRORS="$ERRORS compiler-lint"
fi

# Every call into GMP, checked in the BINARY rather than in the source: the
# probe breaks on each one under gdb and reads rsp.  It is here and not in
# lint.py because NASM macros hide both pushes and branches from any
# source-level check -- INT_NEED_MPZ expands to a `push rdi` around a call.
# Skips where gdb is absent, which is why lint.py's own check still matters.
printf "%-40s " "gmp call alignment"
if bash "$TESTDIR/gmp_align_probe.sh" > "$WORK/gmpalign.out" 2>&1; then
    if grep -q "SKIP" "$WORK/gmpalign.out"; then
        printf "${YELLOW}SKIP${NC} %s\n" "$(cat "$WORK/gmpalign.out")"
        SKIP=$((SKIP + 1))
    else
        printf "${GREEN}PASS${NC}\n"
        PASS=$((PASS + 1))
    fi
else
    printf "${RED}FAIL${NC}\n"
    cat "$WORK/gmpalign.out"
    FAIL=$((FAIL + 1))
    ERRORS="$ERRORS gmp-alignment"
fi

# Source-compiler self-test: checks the compiler's encoders directly, against
# the decoders the interpreter will actually use.  Runs before any Python-level
# test, because an encoding bug produces symptoms that look nothing like their
# cause.
printf "%-40s " "compiler selftest"
if $APYTHON --selftest-compile > "$WORK/comptest.out" 2>&1; then
    printf "${GREEN}PASS${NC}\n"
    PASS=$((PASS + 1))
else
    printf "${RED}FAIL${NC}\n"
    cat "$WORK/comptest.out"
    FAIL=$((FAIL + 1))
    ERRORS="$ERRORS compile-selftest"
fi

# Pre-compile all non-test .py files (helper modules)
for helper_py in "$TESTDIR"/*.py; do
    case "$(basename "$helper_py")" in
        test_*) continue ;;
    esac
    $PYTHON -m py_compile "$helper_py" 2>/dev/null || true
done

for test_py in "$TESTDIR"/test_*.py; do
    test_name=$(basename "$test_py" .py)

    # Compile to .pyc.  Guarded: under `set -e` an unguarded failure here
    # aborts the whole run mid-loop, before the summary, which makes the SKIP
    # branch just below unreachable and the symptom a run that simply stops.
    $PYTHON -m py_compile "$test_py" 2>/dev/null || true
    pyc_file="$TESTDIR/__pycache__/${test_name}.cpython-312.pyc"

    if [ ! -f "$pyc_file" ]; then
        echo -e "${YELLOW}SKIP${NC} $test_name (no .pyc generated)"
        SKIP=$((SKIP + 1))
        continue
    fi

    # Oracle: normally CPython itself.  A handful of tests exercise private
    # APIs that CPython does not validate and that crash it outright — those
    # record their expected output in tests/expected/ instead.  Such a test
    # must be self-checking (assert on every step) so the recording is a
    # transcript of a verified run, not the definition of correct.
    expected_file="$TESTDIR/expected/${test_name}.txt"
    if [ -f "$expected_file" ]; then
        expected=$(cat "$expected_file")
    else
        expected=$(timeout $TIMEOUT $PYTHON "$test_py" 2>&1) || true
    fi

    # tests/srcpkg exists to be imported from source.  Producing the expected
    # output above ran CPython over it, which left a __pycache__ behind -- and
    # with one there apython reads the .pyc and the test proves nothing.
    rm -rf "$TESTDIR"/srcpkg/__pycache__ "$TESTDIR"/srcpkg/*/__pycache__

    # Run with apython
    actual=$(timeout $TIMEOUT $APYTHON "$pyc_file" 2>&1) || true

    # Compare.  A test listed in known_failures.txt is expected to fail for
    # the reason written beside it, and is reported XFAIL rather than FAIL;
    # one that starts passing is XPASS, which FAILS the run, so the entry
    # comes out in the commit that earns it rather than going stale.
    known=$(awk -v t="$test_name" '$1 == t { $1 = ""; print; exit }' \
            "$TESTDIR/known_failures.txt")
    if [ "$expected" = "$actual" ]; then
        if [ -n "$known" ]; then
            echo -e "${RED}XPASS${NC} $test_name -- remove it from known_failures.txt"
            FAIL=$((FAIL + 1))
            ERRORS="$ERRORS\n--- $test_name ---\npasses, but is listed in known_failures.txt\n"
        else
            echo -e "${GREEN}PASS${NC} $test_name"
            PASS=$((PASS + 1))
        fi
    elif [ -n "$known" ]; then
        echo -e "${YELLOW}XFAIL${NC} $test_name --${known}"
        SKIP=$((SKIP + 1))
    else
        echo -e "${RED}FAIL${NC} $test_name"
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS\n--- $test_name ---\nExpected:\n$expected\nActual:\n$actual\n"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"

if [ -n "$ERRORS" ]; then
    echo -e "\nFailure details:$ERRORS"
    exit 1
fi
