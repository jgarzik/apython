#!/bin/bash
# String benchmarks: apython against CPython on the same .pyc, startup
# subtracted, best of five.  Reported, not gated.
#
# The fourth harness, after int, float and core.  Between them those three
# measure almost no string work: a change to split, join, find, replace,
# iteration or comparison moves nothing any of them reports.
#
# Every loop is INSIDE A FUNCTION, for the reason the other three say and for
# one more that is specific to strings: `s += x` at module scope compiles to
# STORE_NAME, and CPython's BINARY_OP_INPLACE_ADD_UNICODE specialization only
# fires ahead of a STORE_FAST.  Measured at module scope both interpreters are
# quadratic and look level, which is how the quadratic one here went unnoticed
# for as long as it did.
#
# The run diffs both interpreters' OUTPUT on every case before it times
# anything.  Note what that forbids: no case may expose a hash VALUE, because
# apython uses unseeded FNV-1a where CPython uses randomized siphash13 -- a
# recorded divergence, not a bug.  s_hash counts hashes taken instead.
#
# Cases come in ASCII and non-ASCII pairs.  The wide inputs are the same
# LENGTH IN CODE POINTS as the ASCII ones, so an operation that is O(code
# points) compares like for like and one that is O(bytes) shows what the
# encoding costs.
#
# Wide iteration counts for indexing and slicing are 50-100x lower than their
# ASCII partners' BECAUSE OF A BUG, not by design: str_cp_offset walks from
# byte 0, so a loop that indexes a non-ASCII string is quadratic here and
# CPython's is not.  At ASCII counts those cases do not finish.  Reading their
# ratios is therefore reading a bug and a millisecond of CPython time, and
# neither number means much until ROADMAP.md's entry is closed and the counts are
# raised to match.
#
# Usage: bash tests/run_str_bench.sh
set -u
cd "$(dirname "$0")/.."
BD=${TMPDIR:-/tmp}/apython-str-bench
mkdir -p "$BD"
mk() { cat > "$BD/$1.py"; }
echo "pass" > "$BD/empty.py"

# The two inputs every case draws on.  ASCII and wide are the same LENGTH in
# code points, so a case that is O(code points) compares like for like and a
# case that is O(bytes) shows the 2x the encoding costs.
PRE='A = "abcdefghij" * 100
W = "αβγδεζηθικ" * 100
'

# ---- concatenation ---------------------------------------------------------
mk s_concat <<EOF
${PRE}
def run(n):
    a = "abcdefg"
    b = "hijklmn"
    c = 0
    i = 0
    while i < n:
        c += len(a + b)
        i += 1
    return c
print(run(1000000))
EOF

mk s_iadd <<EOF
${PRE}
def run(n):
    s = ""
    i = 0
    while i < n:
        s += "abcdefghij"
        i += 1
    return len(s)
print(run(20000))
EOF

mk s_iadd_w <<EOF
${PRE}
def run(n):
    s = ""
    i = 0
    while i < n:
        s += "αβγδε"
        i += 1
    return len(s)
print(run(20000))
EOF

# ---- join ------------------------------------------------------------------
mk s_join <<EOF
${PRE}
def run(n):
    parts = ["abcdefghij"] * 200
    c = 0
    for _ in range(n):
        c += len("".join(parts))
    return c
print(run(5000))
EOF

mk s_join_sep <<EOF
${PRE}
def run(n):
    parts = ["abcdefghij"] * 200
    c = 0
    for _ in range(n):
        c += len(", ".join(parts))
    return c
print(run(5000))
EOF

mk s_join_w <<EOF
${PRE}
def run(n):
    parts = ["αβγδε"] * 200
    c = 0
    for _ in range(n):
        c += len("".join(parts))
    return c
print(run(5000))
EOF

mk s_join_gen <<EOF
${PRE}
def run(n):
    c = 0
    for _ in range(n):
        c += len("".join(str(i) for i in range(100)))
    return c
print(run(2000))
EOF

# ---- split -----------------------------------------------------------------
mk s_split_ws <<EOF
${PRE}
def run(n):
    s = "the quick brown fox jumps over the lazy dog " * 20
    c = 0
    for _ in range(n):
        c += len(s.split())
    return c
print(run(5000))
EOF

mk s_split_sep <<EOF
${PRE}
def run(n):
    s = ",".join(["field"] * 200)
    c = 0
    for _ in range(n):
        c += len(s.split(","))
    return c
print(run(5000))
EOF

mk s_split_multi <<EOF
${PRE}
def run(n):
    s = "::".join(["field"] * 200)
    c = 0
    for _ in range(n):
        c += len(s.split("::"))
    return c
print(run(5000))
EOF

mk s_split_w <<EOF
${PRE}
def run(n):
    s = ",".join(["αβγ"] * 200)
    c = 0
    for _ in range(n):
        c += len(s.split(","))
    return c
print(run(5000))
EOF

# ---- search ----------------------------------------------------------------
mk s_find <<EOF
${PRE}
def run(n):
    s = A
    c = 0
    i = 0
    while i < n:
        c += s.find("ij")
        i += 1
    return c
print(run(200000))
EOF

mk s_find_miss <<EOF
${PRE}
def run(n):
    s = A
    c = 0
    i = 0
    while i < n:
        c += s.find("zz")
        i += 1
    return c
print(run(200000))
EOF

mk s_in <<EOF
${PRE}
def run(n):
    s = A
    c = 0
    i = 0
    while i < n:
        if "hij" in s:
            c += 1
        i += 1
    return c
print(run(200000))
EOF

mk s_find_w <<EOF
${PRE}
def run(n):
    s = W
    c = 0
    i = 0
    while i < n:
        c += s.find("ικ")
        i += 1
    return c
print(run(4000))
EOF

mk s_count <<EOF
${PRE}
def run(n):
    s = A
    c = 0
    i = 0
    while i < n:
        c += s.count("a")
        i += 1
    return c
print(run(100000))
EOF

mk s_replace <<EOF
${PRE}
def run(n):
    s = A
    c = 0
    i = 0
    while i < n:
        c += len(s.replace("a", "XY"))
        i += 1
    return c
print(run(50000))
EOF

# ---- affix and case --------------------------------------------------------
mk s_startswith <<EOF
${PRE}
def run(n):
    s = A
    c = 0
    i = 0
    while i < n:
        if s.startswith("abc"):
            c += 1
        if s.endswith("hij"):
            c += 1
        i += 1
    return c
print(run(500000))
EOF

mk s_upper <<EOF
${PRE}
def run(n):
    s = A
    c = 0
    i = 0
    while i < n:
        c += len(s.upper())
        i += 1
    return c
print(run(100000))
EOF

mk s_strip <<EOF
${PRE}
def run(n):
    s = "   " + A + "   "
    c = 0
    i = 0
    while i < n:
        c += len(s.strip())
        i += 1
    return c
print(run(200000))
EOF

# ---- indexing, slicing, iteration ------------------------------------------
mk s_getitem <<EOF
${PRE}
def run(n):
    s = A
    c = 0
    for _ in range(n):
        for i in range(1000):
            if s[i] == "a":
                c += 1
    return c
print(run(500))
EOF

mk s_getitem_w <<EOF
${PRE}
def run(n):
    s = W
    c = 0
    for _ in range(n):
        for i in range(1000):
            if s[i] == "α":
                c += 1
    return c
print(run(10))
EOF

mk s_slice <<EOF
${PRE}
def run(n):
    s = A
    c = 0
    i = 0
    while i < n:
        c += len(s[10:110])
        i += 1
    return c
print(run(300000))
EOF

mk s_slice_w <<EOF
${PRE}
def run(n):
    s = W
    c = 0
    i = 0
    while i < n:
        c += len(s[10:110])
        i += 1
    return c
print(run(20000))
EOF

mk s_foreach <<EOF
${PRE}
def run(n):
    s = A
    c = 0
    for _ in range(n):
        for ch in s:
            c += 1
    return c
print(run(2000))
EOF

mk s_foreach_w <<EOF
${PRE}
def run(n):
    s = W
    c = 0
    for _ in range(n):
        for ch in s:
            c += 1
    return c
print(run(2000))
EOF

mk s_len <<EOF
${PRE}
def run(n):
    s = A
    c = 0
    i = 0
    while i < n:
        c += len(s)
        i += 1
    return c
print(run(2000000))
EOF

# ---- comparison, four ways -------------------------------------------------
mk s_eq_short <<EOF
${PRE}
def run(n):
    a = "alpha"
    b = "alpha"
    c = 0
    i = 0
    while i < n:
        if a == b:
            c += 1
        i += 1
    return c
print(run(2000000))
EOF

mk s_ne_short <<EOF
${PRE}
def run(n):
    a = "alpha"
    b = "beta"
    c = 0
    i = 0
    while i < n:
        if a == b:
            c += 1
        i += 1
    return c
print(run(2000000))
EOF

mk s_eq_long <<EOF
${PRE}
def run(n):
    a = "abcdefghij" * 20
    b = "abcdefghij" * 20
    c = 0
    i = 0
    while i < n:
        if a == b:
            c += 1
        i += 1
    return c
print(run(500000))
EOF

mk s_ne_long_tail <<EOF
${PRE}
def run(n):
    a = "abcdefghij" * 20 + "x"
    b = "abcdefghij" * 20 + "y"
    c = 0
    i = 0
    while i < n:
        if a == b:
            c += 1
        i += 1
    return c
print(run(500000))
EOF

mk s_ne_len <<EOF
${PRE}
def run(n):
    a = "abcdefghij" * 20
    b = "abcdefghij" * 21
    c = 0
    i = 0
    while i < n:
        if a == b:
            c += 1
        i += 1
    return c
print(run(500000))
EOF

mk s_sorted <<EOF
${PRE}
def run(n):
    words = ("the quick brown fox jumps over the lazy dog " * 20).split()
    c = 0
    for _ in range(n):
        c += len(sorted(words))
    return c
print(run(3000))
EOF

# ---- hashing and dicts -----------------------------------------------------
mk s_hash <<EOF
${PRE}
def run(n):
    keys = ["key%03d" % i for i in range(100)]
    c = 0
    for _ in range(n):
        for k in keys:
            # The COUNT of hashes taken, never a hash VALUE: apython uses
            # unseeded FNV-1a where CPython uses randomized siphash13, a
            # recorded divergence, so any value here would differ by design.
            hash(k)
            c += 1
    return c
print(run(2000))
EOF

mk s_dictkey <<EOF
${PRE}
def run(n):
    d = {}
    keys = ["key%03d" % i for i in range(100)]
    for k in keys:
        d[k] = 1
    c = 0
    for _ in range(n):
        for k in keys:
            c += d[k]
    return c
print(run(3000))
EOF

mk s_dictlit <<EOF
${PRE}
def run(n):
    c = 0
    for _ in range(n):
        d = {"alpha": 1, "beta": 2, "gamma": 3, "delta": 4}
        c += d["alpha"] + d["delta"]
    return c
print(run(200000))
EOF

# ---- formatting and conversion ---------------------------------------------
mk s_strint <<EOF
${PRE}
def run(n):
    c = 0
    i = 0
    while i < n:
        c += len(str(i))
        i += 1
    return c
print(run(500000))
EOF

mk s_pct <<EOF
${PRE}
def run(n):
    c = 0
    i = 0
    while i < n:
        c += len("%s-%d" % ("abc", i))
        i += 1
    return c
print(run(300000))
EOF

mk s_fstring <<EOF
${PRE}
def run(n):
    a = "abc"
    c = 0
    i = 0
    while i < n:
        c += len(f"{a}-{i}")
        i += 1
    return c
print(run(300000))
EOF

mk s_encode <<EOF
${PRE}
def run(n):
    s = A
    c = 0
    i = 0
    while i < n:
        c += len(s.encode())
        i += 1
    return c
print(run(200000))
EOF

mk s_decode <<EOF
${PRE}
def run(n):
    b = A.encode()
    c = 0
    i = 0
    while i < n:
        c += len(b.decode())
        i += 1
    return c
print(run(200000))
EOF

BENCHES="s_concat s_iadd s_iadd_w \
         s_join s_join_sep s_join_w s_join_gen \
         s_split_ws s_split_sep s_split_multi s_split_w \
         s_find s_find_miss s_in s_find_w s_count s_replace \
         s_startswith s_upper s_strip \
         s_getitem s_getitem_w s_slice s_slice_w s_foreach s_foreach_w s_len \
         s_eq_short s_ne_short s_eq_long s_ne_long_tail s_ne_len s_sorted \
         s_hash s_dictkey s_dictlit \
         s_strint s_pct s_fstring s_encode s_decode"

for b in $BENCHES empty; do python3 -m py_compile "$BD/$b.py"; done

timeit() {
    local best=999999 t
    for i in 1 2 3 4 5; do
        local s=$(date +%s%N); "$@" >/dev/null 2>&1; local e=$(date +%s%N)
        t=$(( (e-s)/1000000 )); [ "$t" -lt "$best" ] && best=$t
    done
    echo "$best"
}

EPYC=$(ls "$BD/__pycache__/empty."*.pyc)
SA=$(timeit ./apython "$EPYC"); SC=$(timeit python3 "$EPYC")

echo "=== agreement ==="
for b in $BENCHES; do
    PYC=$(ls "$BD/__pycache__/$b."*.pyc)
    e=$(python3 "$PYC" 2>&1); a=$(./apython "$PYC" 2>&1)
    [ "$e" == "$a" ] || echo "  DIFF $b: cpython=[$e] apython=[$a]"
done
echo "  (nothing above means all agree)"
echo
echo "=== strings (startup-subtracted ms; >1.00x = apython faster) ==="
printf "%-16s %9s %9s %8s\n" "benchmark" "apython" "cpython" "speedup"
TA=0; TC=0
for b in $BENCHES; do
    PYC=$(ls "$BD/__pycache__/$b."*.pyc)
    a=$(timeit ./apython "$PYC"); c=$(timeit python3 "$PYC")
    a=$((a-SA)); c=$((c-SC)); [ "$a" -lt 1 ] && a=1; [ "$c" -lt 1 ] && c=1
    TA=$((TA+a)); TC=$((TC+c))
    printf "%-16s %9s %9s %8s\n" "$b" "$a" "$c" "$(python3 -c "print('%.2fx'%($c/$a))")"
done
echo
printf "TOTAL apython=%sms cpython=%sms overall=%s\n" "$TA" "$TC" \
       "$(python3 -c "print('%.2fx'%($TC/$TA))")"
