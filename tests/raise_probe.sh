#!/bin/bash
# raise_probe.sh - make builtins fail, and see what each failure leaves behind.
#
# An error that leaves a function by jumping into the unwinder abandons every
# native frame between it and the eval loop, and whatever those frames held is
# never released.  Nothing else in the suite can see that: the answer is
# right, the exception is right, and the process is a few blocks larger.
#
# So this calls every method of every builtin type, every builtin function and
# every constructor with arguments it must refuse, and runs the container
# operations with a callback that raises in the middle -- and around each it
# reads sys.getallocatedblocks().  tests/raise_probe.py is the driver and
# says how a leak is told from noise.
#
# The failure paths that leak or crash today are tests/raise_leak_floor.txt.
# The gate is a ratchet in both directions: a new entry fails, and an entry
# that is fixed fails until the floor is re-recorded, so the file is always
# the truth.
#
#   bash tests/raise_probe.sh            the gate
#   bash tests/raise_probe.sh --show     every leak, with blocks per call
#   bash tests/raise_probe.sh --record   rewrite the floor from this run
#   bash tests/raise_probe.sh --filter 'meth | list.'   one corner
set -u

APYTHON=${APYTHON:-./apython}
PYTHON=${PYTHON:-python3}
TESTDIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$TESTDIR")"

case "$APYTHON" in
    /*) APY="$APYTHON" ;;
    *)  APY="$ROOT/${APYTHON#./}" ;;
esac
[ -x "$APY" ] || { echo "SKIP: $APYTHON not built"; exit 0; }

cd "$ROOT" && exec "$PYTHON" "$TESTDIR/raise_probe.py" "$APY" "$@"
