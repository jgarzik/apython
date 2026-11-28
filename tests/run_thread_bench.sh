#!/bin/bash
# Multi-core scaling benchmark for apython's free-threaded runtime.
# Measures 1, 2, 4, and 8 threads running identical CPU-bound work per thread
# (weak scaling: speedup = N * T(1) / T(N)) and verifies >= 3.0x on 4 cores.
#
# Usage: bash tests/run_thread_bench.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APYTHON=${APYTHON:-./apython}

"$APYTHON" - <<'EOF'
import sys
import time
import threading

assert sys._is_gil_enabled() is False, "expected free-threaded runtime (GIL disabled)"


def small_int(n):
    s = 0
    for i in range(n):
        s += i & 1023
    return s


def float_loop(n):
    s = 0.0
    for i in range(n):
        s += i * 0.5
    return s


def dict_local(n):
    d = {}
    for i in range(n):
        d[i & 255] = i
    return len(d)


def list_local(n, _len=len):
    a = []
    for i in range(n):
        a.append(i)
        if _len(a) > 64:
            a.pop()
    return _len(a)


def str_work(n, _len=len):
    s = "abcdefghijklmnopqrstuvwxyz0123456789"
    acc = 0
    for i in range(n):
        acc += _len(s[i & 15 : 20 + (i & 15)])
    return acc


def measure(fn, n, nthreads):
    best = 1e9
    for _ in range(3):
        t0 = time.perf_counter()
        if nthreads == 1:
            fn(n)
        else:
            ts = [threading.Thread(target=fn, args=(n,)) for _ in range(nthreads)]
            for t in ts:
                t.start()
            for t in ts:
                t.join()
        dt = time.perf_counter() - t0
        if dt < best:
            best = dt
    return best


workloads = [
    ("small_int 15M", small_int, 15_000_000),
    ("float_loop 15M", float_loop, 15_000_000),
    ("dict_local 4M", dict_local, 4_000_000),
    ("list_local 2M", list_local, 2_000_000),
    ("str_work 3M", str_work, 3_000_000),
]

print(f"{'workload':18s} {'1T(ms)':>8s} {'2T(x)':>8s} {'4T(x)':>8s} {'8T(x)':>8s}")
print("-" * 54)
speedups_4t = []
for name, fn, n in workloads:
    t1 = measure(fn, n, 1)
    t2 = measure(fn, n, 2)
    t4 = measure(fn, n, 4)
    t8 = measure(fn, n, 8)
    s2 = (2.0 * t1) / t2
    s4 = (4.0 * t1) / t4
    s8 = (8.0 * t1) / t8
    speedups_4t.append((name, s4))
    print(f"{name:18s} {t1*1000:8.1f} {s2:7.2f}x {s4:7.2f}x {s8:7.2f}x")

avg_4t = sum(s for _, s in speedups_4t) / len(speedups_4t)
print("-" * 54)
print(f"4-thread mean speedup: {avg_4t:.2f}x")
assert avg_4t >= 3.0, f"expected >= 3.0x mean 4-thread speedup, got {avg_4t:.2f}x"
EOF
