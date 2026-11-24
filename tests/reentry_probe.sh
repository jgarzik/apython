#!/bin/bash
# reentry_probe.sh - what does a container do when Python runs in the middle
# of one of its own operations and changes it?
#
# Every container method that compares, hashes, prints, converts or releases
# an element calls back into Python: __eq__, __hash__, __lt__, __repr__,
# __index__, __del__, a key function, an iterator's __next__.  That code is
# arbitrary, and it can reach the container being operated on.  A method that
# read the size before the call, or still holds the element borrowed after
# it, or releases an element before the container is consistent, is then
# reading freed memory.
#
# The first run of this probe found six operations that segfaulted --
# `del l[i]`, `del l[i:j]`, `l[i:j] = iterable`, `l[::k] = iterable` and
# bytearray's slice assignment among them -- beside the four a code review had
# already found by reading (list.clear, set.clear, and the list and dict
# reprs).  None of them was visible to `make check`: the corpus compares
# output, and no test mutates a container from inside a callback.
#
# It matters more with threads.  A GIL protects only code that never runs
# Python; every case here is a place where another thread can be let in.
#
# The corpus is generated: each operation of list, dict, set and bytearray,
# crossed with the hook that fires and with what the hook does (clear, shrink,
# grow, replace).  One process per case, because a crash takes the process.
#
# CRASHES MUST BE ZERO.  A wall, not a ratchet, the way pyc_probe.sh and
# typefuzz_probe.sh treat a signal.  Answers are not compared: CPython's own
# vary by point release here, and 3.12.3 segfaults on two of these cases.
#
#   bash tests/reentry_probe.sh              # the gate
#   bash tests/reentry_probe.sh --valgrind   # the same corpus, each case
#                                            # under valgrind; minutes, not
#                                            # seconds, and it sees the reads
#                                            # of freed memory that do not
#                                            # happen to crash

set -u

APYTHON=${APYTHON:-./apython}
PYTHON=${PYTHON:-python3}
TESTDIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$TESTDIR")"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

case "$APYTHON" in
    /*) APY="$APYTHON" ;;
    *)  APY="$ROOT/${APYTHON#./}" ;;
esac
[ -x "$APY" ] || { echo "SKIP: $APYTHON not built"; exit 0; }

RUNNER="$APY"
if [ "${1:-}" = "--valgrind" ]; then
    command -v valgrind >/dev/null || { echo "SKIP: valgrind not installed"; exit 0; }
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
    # The pool allocator hides a use-after-free from valgrind; libc's does not.
    printf '#!/bin/bash\nAPYTHON_MALLOC=libc exec valgrind -q --error-exitcode=200 "%s" "$@"\n' "$APY" > "$WORK/apy-vg"
    chmod +x "$WORK/apy-vg"
    RUNNER="$WORK/apy-vg"
    export REENTRY_TIMEOUT=${REENTRY_TIMEOUT:-600}
fi

OUT=$("$PYTHON" "$TESTDIR/reentry_probe.py" "$RUNNER")
STATUS=$?
echo "$OUT" | tail -1
if [ $STATUS -ne 0 ]; then
    echo "$OUT" | sed '$d' | head -40
    echo -e "${RED}FAIL${NC} reentrant mutation: a container operation crashed"
    exit 1
fi
echo -e "${GREEN}PASS${NC} reentrant mutation: no crash"
