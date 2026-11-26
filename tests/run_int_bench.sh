#!/bin/bash
# Integer benchmarks: apython against CPython, on the same .pyc, startup
# subtracted, best of five.  Reported, not gated -- a perf claim should be
# reproducible rather than trusted.
#
# Every loop is INSIDE A FUNCTION on purpose.  The same loop written at module
# scope measures LOAD_NAME/STORE_NAME dict lookups rather than arithmetic, and
# the two answers differ by more than the thing being measured.
#
# The run begins by diffing both interpreters' OUTPUT on every case, before it
# times anything.  That is not ceremony: a specialized opcode that computes the
# wrong answer is usually faster, and this check is what caught `i << 3`
# quietly computing `i & 3` after a fall-through into the wrong ladder arm.
#
# What the cases are chosen to separate:
#
#   - immediates (+-2^50) from compact heap integers (to +-2^63) from
#     GMP-backed ones, since each has its own paths
#   - the specialized opcodes from the generic protocol: a site only
#     specializes once it has run, so every loop runs long enough to
#   - arithmetic from builtin CALL overhead: abs, str, int, divmod, sum and
#     hash are as much a measure of op_call as of anything numeric
#
# Usage: bash tests/run_int_bench.sh
set -u
cd "$(dirname "$0")/.."
APYTHON=${APYTHON:-./apython}
PYTHON=${PYTHON:-python3}
BD=${TMPDIR:-/tmp}/apython-int-bench
mkdir -p "$BD"
mk() { cat > "$BD/$1.py"; }
echo "pass" > "$BD/empty.py"

# ---- small ints, well inside the +-2^50 immediate range --------------------
mk i_add <<'EOF'
def run(n):
    x = 0
    i = 0
    while i < n:
        x = x + 3
        i += 1
    return x
print(run(3000000))
EOF

mk i_sub <<'EOF'
def run(n):
    x = 0
    i = 0
    while i < n:
        x = x - 3
        i += 1
    return x
print(run(3000000))
EOF

mk i_mul <<'EOF'
def run(n):
    x = 1
    i = 0
    while i < n:
        x = (x * 3) % 1000003
        i += 1
    return x
print(run(2000000))
EOF

mk i_floordiv <<'EOF'
def run(n):
    s = 0
    i = 1
    while i < n:
        s += i // 7
        i += 1
    return s
print(run(2000000))
EOF

mk i_truediv <<'EOF'
def run(n):
    s = 0.0
    i = 1
    while i < n:
        s += i / 7
        i += 1
    return s
print(round(run(1000000), 3))
EOF

mk i_mod <<'EOF'
def run(n):
    s = 0
    i = 1
    while i < n:
        s += i % 7
        i += 1
    return s
print(run(2000000))
EOF

mk i_cmp <<'EOF'
def run(n):
    c = 0
    i = 0
    while i < n:
        if i < 1000:
            c += 1
        i += 1
    return c
print(run(3000000))
EOF

mk i_inplace <<'EOF'
def run(n):
    x = 0
    i = 0
    while i < n:
        x += 3
        i += 1
    return x
print(run(3000000))
EOF

mk i_neg <<'EOF'
def run(n):
    s = 0
    i = 0
    while i < n:
        s += -i
        i += 1
    return s
print(run(2000000))
EOF

mk i_abs <<'EOF'
def run(n):
    s = 0
    i = 0
    while i < n:
        s += abs(-i)
        i += 1
    return s
print(run(2000000))
EOF

mk i_bitand <<'EOF'
def run(n):
    s = 0
    i = 0
    while i < n:
        s += (i & 255) | (i ^ 7)
        i += 1
    return s
print(run(2000000))
EOF

mk i_shift <<'EOF'
def run(n):
    s = 0
    i = 0
    while i < n:
        s += (i << 3) >> 2
        i += 1
    return s
print(run(2000000))
EOF

mk i_pow <<'EOF'
def run(n):
    s = 0
    i = 1
    while i < n:
        s += i ** 2
        i += 1
    return s
print(run(500000))
EOF

mk i_divmod <<'EOF'
def run(n):
    s = 0
    i = 1
    while i < n:
        q, r = divmod(i, 7)
        s += q + r
        i += 1
    return s
print(run(1000000))
EOF

# ---- the range loop, which every int-heavy program uses --------------------
mk i_range <<'EOF'
def run(n):
    s = 0
    for i in range(n):
        s += i
    return s
print(run(5000000))
EOF

mk i_rangestep <<'EOF'
def run(n):
    s = 0
    for i in range(0, n, 3):
        s += i
    return s
print(run(5000000))
EOF

mk i_enumerate <<'EOF'
def run(n):
    a = list(range(1000))
    s = 0
    for r in range(n):
        for i, v in enumerate(a):
            s += i + v
    return s
print(run(1000))
EOF

# ---- around and past the +-2^50 immediate boundary -------------------------
mk i_boundary <<'EOF'
def run(n):
    base = 1 << 49
    s = 0
    i = 0
    while i < n:
        s += base + i
        i += 1
    return s
print(run(1000000))
EOF

mk i_big <<'EOF'
def run(n):
    x = 1 << 60
    s = 0
    i = 0
    while i < n:
        s += x + i
        i += 1
    return s
print(run(1000000))
EOF

mk i_huge <<'EOF'
def run(n):
    x = 10 ** 50
    s = 0
    i = 0
    while i < n:
        s += x * 3 - x
        i += 1
    return s % 1000000007
print(run(200000))
EOF

mk i_factorial <<'EOF'
def run(n):
    f = 1
    for i in range(1, n):
        f *= i
    return f % 1000000007
print(run(3000))
EOF

# ---- conversions ----------------------------------------------------------
mk i_str <<'EOF'
def run(n):
    s = 0
    i = 0
    while i < n:
        s += len(str(i))
        i += 1
    return s
print(run(500000))
EOF

mk i_parse <<'EOF'
def run(n):
    t = ["1", "42", "1234567", "-99", "1000000000000"]
    s = 0
    for r in range(n):
        for v in t:
            s += int(v)
    return s
print(run(200000))
EOF

mk i_bigstr <<'EOF'
def run(n):
    x = 10 ** 200
    s = 0
    for r in range(n):
        s += len(str(x))
    return s
print(run(20000))
EOF

mk i_hash <<'EOF'
def run(n):
    s = 0
    i = 0
    while i < n:
        s += hash(i)
        i += 1
    return s
print(run(2000000))
EOF

mk i_sum <<'EOF'
def run(n):
    a = list(range(1000))
    s = 0
    for r in range(n):
        s += sum(a)
    return s
print(run(3000))
EOF

mk i_listidx <<'EOF'
def run(n):
    a = list(range(1000))
    s = 0
    for r in range(n):
        for i in range(1000):
            s += a[i]
    return s
print(run(2000))
EOF

mk i_dictkey <<'EOF'
def run(n):
    d = {}
    for i in range(1000):
        d[i] = i * 2
    s = 0
    for r in range(n):
        for i in range(1000):
            s += d[i]
    return s
print(run(1000))
EOF

BENCHES="i_add i_sub i_mul i_floordiv i_truediv i_mod i_cmp i_inplace i_neg \
         i_abs i_bitand i_shift i_pow i_divmod i_range i_rangestep i_enumerate \
         i_boundary i_big i_huge i_factorial i_str i_parse i_bigstr i_hash \
         i_sum i_listidx i_dictkey"

for b in $BENCHES empty; do "$PYTHON" -m py_compile "$BD/$b.py"; done

timeit() {
    local best=999999 t
    for i in 1 2 3 4 5; do
        local s=$(date +%s%N); "$@" >/dev/null 2>&1; local e=$(date +%s%N)
        t=$(( (e-s)/1000000 )); [ "$t" -lt "$best" ] && best=$t
    done
    echo "$best"
}

EPYC=$(ls "$BD/__pycache__/empty."*.pyc)
SA=$(timeit "$APYTHON" "$EPYC"); SC=$(timeit "$PYTHON" "$EPYC")

echo "=== agreement ==="
for b in $BENCHES; do
    PYC=$(ls "$BD/__pycache__/$b."*.pyc)
    e=$("$PYTHON" "$PYC" 2>&1); a=$("$APYTHON" "$PYC" 2>&1)
    [ "$e" == "$a" ] || echo "  DIFF $b: cpython=[$e] apython=[$a]"
done
echo "  (nothing above means all agree)"
echo
echo "=== int in functions (startup-subtracted ms; >1.00x = apython faster) ==="
printf "%-13s %9s %9s %8s\n" "benchmark" "apython" "cpython" "speedup"
TA=0; TC=0
for b in $BENCHES; do
    PYC=$(ls "$BD/__pycache__/$b."*.pyc)
    a=$(timeit "$APYTHON" "$PYC"); c=$(timeit "$PYTHON" "$PYC")
    a=$((a-SA)); c=$((c-SC)); [ "$a" -lt 1 ] && a=1; [ "$c" -lt 1 ] && c=1
    TA=$((TA+a)); TC=$((TC+c))
    printf "%-13s %9s %9s %8s\n" "$b" "$a" "$c" "$("$PYTHON" -c "print('%.2fx'%($c/$a))")"
done
echo
printf "TOTAL apython=%sms cpython=%sms overall=%s\n" "$TA" "$TC" \
       "$("$PYTHON" -c "print('%.2fx'%($TC/$TA))")"
