#!/bin/bash
# Macro benchmarks: whole programs, not loops.  apython against CPython on the
# same .pyc, startup subtracted, best of five.  Reported, not gated.
#
# The other four harnesses (int, float, str, core) each measure one path in
# isolation, and between them they can all read above 1.00x while a real
# program still runs slower -- which is exactly what happened: the micro suites
# sat at 1.09x-1.83x while the last macro measurement was 0.55x.  A loop that
# does one thing cannot see dispatch overhead amortised across a call, an
# allocation and an attribute read in the same expression.  This harness is
# the one that can.
#
# The programs are written here rather than taken from the Computer Language
# Benchmarks Game, whose sources are BSD-licensed: these are the same classic
# workloads reimplemented, so the tree stays MIT and the measurement is
# unchanged.  Each is deterministic, uses no stdlib beyond builtins, and
# prints a checksum -- so the agreement pass below is a real correctness test
# and not just a smoke test.
#
# Every hot loop is INSIDE A FUNCTION, for the reason the other harnesses
# record: at module scope the same code measures LOAD_NAME/STORE_NAME dict
# lookups rather than the thing it is named after.
#
# The run diffs both interpreters' OUTPUT on every case before it times
# anything.  A handler that computes the wrong answer is usually faster.
#
# Floating-point results are printed through a FORMAT SPEC ("%.9f"-shaped),
# not through repr(), so that a change to the shortest-repr search shows up in
# run_float_bench.sh and in tests/test_float_format_diff.py rather than
# reporting itself as ten macro benchmarks all disagreeing at once.  m_repr is
# the one case that measures repr on purpose.
#
# Usage: bash tests/run_macro_bench.sh
set -u
cd "$(dirname "$0")/.."
APYTHON=${APYTHON:-./apython}
PYTHON=${PYTHON:-python3}
BD=${TMPDIR:-/tmp}/apython-macro-bench
mkdir -p "$BD"
mk() { cat > "$BD/$1.py"; }
echo "pass" > "$BD/empty.py"

# ---- n-body: float arithmetic through list indexing and nested loops -------
# A symplectic Euler integrator over five bodies.  Floats live in lists, so
# every step is BINARY_SUBSCR + BINARY_OP + STORE_SUBSCR, which is the mix an
# arithmetic kernel written in Python actually has.
mk m_nbody <<'EOF'
def advance(pos, vel, mass, n, dt):
    k = len(mass)
    for _ in range(n):
        for i in range(k):
            pi = pos[i]
            for j in range(i + 1, k):
                pj = pos[j]
                dx = pi[0] - pj[0]
                dy = pi[1] - pj[1]
                dz = pi[2] - pj[2]
                d2 = dx * dx + dy * dy + dz * dz
                mag = dt / (d2 * (d2 ** 0.5))
                mi = mass[i] * mag
                mj = mass[j] * mag
                vi = vel[i]
                vj = vel[j]
                vi[0] -= dx * mj
                vi[1] -= dy * mj
                vi[2] -= dz * mj
                vj[0] += dx * mi
                vj[1] += dy * mi
                vj[2] += dz * mi
        for i in range(k):
            p = pos[i]
            v = vel[i]
            p[0] += dt * v[0]
            p[1] += dt * v[1]
            p[2] += dt * v[2]

def energy(pos, vel, mass):
    k = len(mass)
    e = 0.0
    for i in range(k):
        v = vel[i]
        e += 0.5 * mass[i] * (v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
        for j in range(i + 1, k):
            dx = pos[i][0] - pos[j][0]
            dy = pos[i][1] - pos[j][1]
            dz = pos[i][2] - pos[j][2]
            e -= (mass[i] * mass[j]) / ((dx * dx + dy * dy + dz * dz) ** 0.5)
    return e

def run(n):
    pos = [[0.0, 0.0, 0.0],
           [4.84143144, -1.16032004, -0.10362204],
           [8.34336671, 4.12479856, -0.40352324],
           [12.89436956, -15.11115140, -0.22330757],
           [15.37969711, -25.91931460, 0.17925877]]
    # Velocities are per day; the masses below are in solar-mass units, so the
    # velocities have to be carried into the same time unit or the planets
    # simply fall into the sun.  Getting this wrong does not crash -- it makes
    # the integration diverge, and a chaotic benchmark fails its own agreement
    # check the first time one operation differs by an ulp.
    dpy = 365.24
    vel = [[0.0, 0.0, 0.0],
           [0.00166007 * dpy, 0.00769901 * dpy, -0.00006904 * dpy],
           [-0.00276742 * dpy, 0.00499852 * dpy, 0.00002304 * dpy],
           [0.00296460 * dpy, 0.00237847 * dpy, -0.00002965 * dpy],
           [0.00268067 * dpy, 0.00162824 * dpy, -0.00009515 * dpy]]
    mass = [39.47841760, 0.03769368, 0.01128193, 0.00172372, 0.00203369]
    # Offset the sun's velocity so the system's momentum is zero.
    sx = sy = sz = 0.0
    for i in range(1, len(mass)):
        sx += vel[i][0] * mass[i]
        sy += vel[i][1] * mass[i]
        sz += vel[i][2] * mass[i]
    vel[0][0] = -sx / mass[0]
    vel[0][1] = -sy / mass[0]
    vel[0][2] = -sz / mass[0]
    before = energy(pos, vel, mass)
    advance(pos, vel, mass, n, 0.01)
    return before, energy(pos, vel, mass)

a, b = run(120000)
print("%.9f %.9f" % (a, b))
EOF

# ---- binary trees: allocation, recursion and immediate collection ----------
# Tuples rather than a class, so this measures the allocator and the recursion
# and not attribute access -- m_oo below is where attribute access is measured.
mk m_binary_trees <<'EOF'
def make(depth):
    if depth == 0:
        return (None, None)
    d = depth - 1
    return (make(d), make(d))

def check(node):
    l, r = node
    if l is None:
        return 1
    return 1 + check(l) + check(r)

def run(max_depth):
    total = 0
    total += check(make(max_depth + 1))
    d = 4
    while d <= max_depth:
        iterations = 1 << (max_depth - d + 4)
        c = 0
        for _ in range(iterations):
            c += check(make(d))
        total += c
        d += 2
    return total

print(run(15))
EOF

# ---- fannkuch: list mutation, reversal and integer comparison --------------
mk m_fannkuch <<'EOF'
def run(n):
    perm = list(range(n))
    count = list(range(1, n + 1))
    perm1 = list(range(n))
    max_flips = 0
    checksum = 0
    sign = 1
    r = n
    while True:
        while r != 1:
            count[r - 1] = r
            r -= 1
        i = 0
        while i < n:
            perm[i] = perm1[i]
            i += 1
        flips = 0
        k = perm[0]
        while k != 0:
            j = (k + 1) >> 1
            i = 0
            while i < j:
                t = perm[i]
                perm[i] = perm[k - i]
                perm[k - i] = t
                i += 1
            flips += 1
            k = perm[0]
        if flips > max_flips:
            max_flips = flips
        checksum += sign * flips
        sign = -sign
        while True:
            if r == n:
                return checksum, max_flips
            p0 = perm1[0]
            i = 0
            while i < r:
                perm1[i] = perm1[i + 1]
                i += 1
            perm1[r] = p0
            count[r] -= 1
            if count[r] > 0:
                break
            r += 1

c, m = run(9)
print(c, m)
EOF

# ---- spectral norm: float division inside a doubly nested loop -------------
mk m_spectral_norm <<'EOF'
def a_of(i, j):
    return 1.0 / ((i + j) * (i + j + 1) // 2 + i + 1)

def mul_av(n, v):
    out = [0.0] * n
    for i in range(n):
        s = 0.0
        for j in range(n):
            s += a_of(i, j) * v[j]
        out[i] = s
    return out

def mul_atv(n, v):
    out = [0.0] * n
    for i in range(n):
        s = 0.0
        for j in range(n):
            s += a_of(j, i) * v[j]
        out[i] = s
    return out

def run(n):
    u = [1.0] * n
    v = [0.0] * n
    for _ in range(10):
        v = mul_atv(n, mul_av(n, u))
        u = mul_atv(n, mul_av(n, v))
    vbv = 0.0
    vv = 0.0
    for i in range(n):
        vbv += u[i] * v[i]
        vv += v[i] * v[i]
    return (vbv / vv) ** 0.5

print("%.9f" % run(400))
EOF

# ---- n-queens: recursion, list append/pop and short-circuit boolean --------
mk m_nqueens <<'EOF'
def solve(n, row, cols, diag1, diag2):
    if row == n:
        return 1
    count = 0
    for c in range(n):
        d1 = row - c
        d2 = row + c
        if c in cols or d1 in diag1 or d2 in diag2:
            continue
        cols.add(c)
        diag1.add(d1)
        diag2.add(d2)
        count += solve(n, row + 1, cols, diag1, diag2)
        cols.discard(c)
        diag1.discard(d1)
        diag2.discard(d2)
    return count

def run(n):
    total = 0
    for size in range(4, n + 1):
        total += solve(size, 0, set(), set(), set())
    return total

print(run(12))
EOF

# ---- text: string building, slicing, dict counting and join ----------------
# A deterministic LCG feeds a nucleotide-style generator, then the result is
# counted and reassembled.  Exercises str concatenation, slicing, dict
# mutation and join in one program.
mk m_text <<'EOF'
def gen(n, seed):
    letters = "ACGT"
    out = []
    s = seed
    for _ in range(n):
        s = (s * 1103515245 + 12345) & 0x7FFFFFFF
        out.append(letters[(s >> 16) & 3])
    return "".join(out)

def run(n):
    text = gen(n, 42)
    counts = {}
    for k in (1, 2, 3):
        for i in range(len(text) - k + 1):
            frag = text[i:i + k]
            counts[frag] = counts.get(frag, 0) + 1
    keys = sorted(counts)
    parts = []
    for key in keys:
        parts.append(key + "=" + str(counts[key]))
    joined = ",".join(parts)
    return len(keys), len(joined), counts["ACG"]

a, b, c = run(1200000)
print(a, b, c)
EOF

# ---- object dispatch: attribute get/set and bound-method calls -------------
# The workload phases 4, 5 and 7 target.  A small class hierarchy so the MRO
# is more than one deep, a property so the data-descriptor path is live, and
# an inherited method so dunder_lookup and LOAD_ATTR_METHOD both matter.
mk m_oo <<'EOF'
class Shape:
    def __init__(self, x, y):
        self.x = x
        self.y = y
        self._scale = 1

    @property
    def scale(self):
        return self._scale

    @scale.setter
    def scale(self, v):
        self._scale = v

    def area(self):
        return 0

    def moved(self, dx, dy):
        self.x += dx
        self.y += dy
        return self

class Rect(Shape):
    def __init__(self, x, y, w, h):
        Shape.__init__(self, x, y)
        self.w = w
        self.h = h

    def area(self):
        return self.w * self.h * self.scale

class Square(Rect):
    def __init__(self, x, y, s):
        Rect.__init__(self, x, y, s, s)

    def area(self):
        return self.w * self.w * self.scale

def run(n):
    shapes = [Rect(i, i, i + 1, i + 2) for i in range(20)]
    shapes += [Square(i, i, i + 1) for i in range(20)]
    total = 0
    for _ in range(n):
        for s in shapes:
            s.moved(1, -1)
            total += s.area()
            s.scale = 2
            total += s.area()
            s.scale = 1
    return total

print(run(40000))
EOF

# ---- indexing: the subscript paths phase 2 targets ------------------------
mk m_index <<'EOF'
def run(n):
    grid = [[0] * 64 for _ in range(64)]
    lookup = {}
    for i in range(64):
        lookup[i] = i * i
    total = 0
    for step in range(n):
        r = step & 63
        row = grid[r]
        for c in range(64):
            row[c] = row[c] + lookup[c] + r
        total += row[63]
    return total

print(run(200000))
EOF

# ---- calls: plain function calls, recursion and keyword binding -----------
mk m_call <<'EOF'
def add(a, b):
    return a + b

def scaled(a, b, k=1):
    return (a + b) * k

def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

def run(n):
    total = 0
    for i in range(n):
        total += add(i, 1)
        total += scaled(i, 2)
        total += scaled(i, 2, k=3)
    total += fib(27)
    return total

print(run(3000000))
EOF

# ---- repr: the shortest-round-trip search phase 6 replaces ----------------
# The one case that prints floats through repr on purpose.  The value mix is
# deliberate: some exit the search at one digit and some need seventeen, so
# the case measures the search's shape and not one value's cost.
mk m_repr <<'EOF'
def run(n):
    vals = [1.0, 0.1, 3.141592653589793, 1e300, 2.5e-8, -0.0,
            1234567.125, 2.0 ** -24, 6.02214076e23, 0.30000000000000004]
    total = 0
    for _ in range(n):
        for v in vals:
            total += len(repr(v))
    return total

print(run(300000))
EOF

BENCHES="m_nbody m_binary_trees m_fannkuch m_spectral_norm m_nqueens \
         m_text m_oo m_index m_call m_repr"

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
bad=0
for b in $BENCHES; do
    PYC=$(ls "$BD/__pycache__/$b."*.pyc)
    e=$("$PYTHON" "$PYC" 2>&1); a=$("$APYTHON" "$PYC" 2>&1)
    if [ "$e" != "$a" ]; then echo "  DIFF $b: cpython=[$e] apython=[$a]"; bad=1; fi
done
[ "$bad" -eq 0 ] && echo "  (nothing above means all agree)"
echo
echo "=== whole programs (startup-subtracted ms; >1.00x = apython faster) ==="
printf "%-18s %9s %9s %8s\n" "benchmark" "apython" "cpython" "speedup"
TA=0; TC=0
for b in $BENCHES; do
    PYC=$(ls "$BD/__pycache__/$b."*.pyc)
    a=$(timeit "$APYTHON" "$PYC"); c=$(timeit "$PYTHON" "$PYC")
    a=$((a-SA)); c=$((c-SC)); [ "$a" -lt 1 ] && a=1; [ "$c" -lt 1 ] && c=1
    TA=$((TA+a)); TC=$((TC+c))
    printf "%-18s %9s %9s %8s\n" "$b" "$a" "$c" "$("$PYTHON" -c "print('%.2fx'%($c/$a))")"
done
echo
printf "TOTAL apython=%sms cpython=%sms overall=%s\n" "$TA" "$TC" \
       "$("$PYTHON" -c "print('%.2fx'%($TC/$TA))")"
