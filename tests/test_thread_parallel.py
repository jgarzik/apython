# Parallel free-threaded CPU workloads: verifies exact deterministic answers
# across multiple threads executing Python bytecode concurrently.
import sys
import threading
import re

if hasattr(sys, "_is_gil_enabled"):
    assert sys._is_gil_enabled() is False

NTHREADS = 4


def run_parallel(fn, arg_list):
    results = [None] * len(arg_list)
    errors = []

    def wrap(idx, arg):
        try:
            results[idx] = fn(arg)
        except BaseException as exc:
            errors.append((idx, repr(exc)))

    threads = [
        threading.Thread(target=wrap, args=(i, arg_list[i]))
        for i in range(len(arg_list))
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert not errors, f"worker errors: {errors}"
    return results


def work_small_int(seed):
    s = 0
    for i in range(50000):
        s += (i * 3 + seed) & 1023
    return s


def work_big_int(seed):
    s = 1 << 70
    for i in range(1, 5000):
        s += (i * i) + seed
    return s


def work_float(seed):
    s = 0.0
    for i in range(1, 20000):
        s += (i + seed) * 0.25
    return int(s)


def work_dict(seed):
    d = {}
    for i in range(10000):
        k = (i + seed) & 255
        d[k] = d.get(k, 0) + i
    return sum(d.values())


def work_list_sort(seed):
    a = [((i * 1103515245 + seed) & 0xFFFF) for i in range(4000)]
    a.sort()
    return (a[0], a[len(a) // 2], a[-1], sum(a))


def work_str_re(seed):
    pat = re.compile(r"[a-z]+[0-9]+")
    total = 0
    for i in range(400):
        s = f"foo{seed + i} bar{i * 2} baz{seed}"
        total += len(pat.findall(s))
    return total


seeds = [1, 7, 13, 29]
for name, fn in [
    ("small_int", work_small_int),
    ("big_int", work_big_int),
    ("float", work_float),
    ("dict", work_dict),
    ("list_sort", work_list_sort),
    ("str_re", work_str_re),
]:
    expected = [fn(s) for s in seeds]
    actual = run_parallel(fn, seeds)
    assert actual == expected, f"{name}: {actual} != {expected}"
    print(name, "ok")
