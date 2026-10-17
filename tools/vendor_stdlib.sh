#!/bin/bash
# vendor_stdlib.sh - copy CPython's pure-Python standard library into stdlib/.
#
#   bash tools/vendor_stdlib.sh [CPYTHON_SRC]     # default ~/tmp/repo/cpython
#
# apython runs CPython's own Lib/ rather than a rewrite of it: the interpreter
# and the C modules are ours, the Python half of the standard library is
# theirs, unmodified, and under the PSF license (stdlib/LICENSE).  Where a
# module needs to differ, the difference lives in lib/ as a stand-in for a C
# module, never as an edit here -- so re-running this script over a newer
# 3.12.x is the whole of an upgrade, and `git diff stdlib/` after it shows
# exactly what CPython changed.
#
# Left out: Lib/test (tens of megabytes, and the sweeps read it from the
# checkout), and every __pycache__.  The tag and commit copied are recorded in
# stdlib/VENDORED.

set -eu

SRC=${1:-$HOME/tmp/repo/cpython}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/stdlib"

if [ ! -f "$SRC/Lib/os.py" ]; then
    echo "no CPython source tree at $SRC" >&2
    exit 1
fi
ver=$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)
case "$ver" in
    v3.12.*) ;;
    *) echo "$SRC is not at a v3.12.x tag (got '${ver:-untagged}')" >&2
       exit 1 ;;
esac

rm -rf "$DEST"
mkdir -p "$DEST"
( cd "$SRC/Lib" &&
  find . -path ./test -prune -o -name __pycache__ -prune -o -type f -print0 \
  | cpio -0 -pdm --quiet "$DEST" )
cp "$SRC/LICENSE" "$DEST/LICENSE"
{
    echo "CPython $ver"
    echo "commit $(git -C "$SRC" rev-parse HEAD)"
    echo "Copied from Lib/ by tools/vendor_stdlib.sh, minus Lib/test."
} > "$DEST/VENDORED"
echo "vendored $ver: $(find "$DEST" -name '*.py' | wc -l) modules into stdlib/"
