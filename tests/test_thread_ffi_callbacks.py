# ctypes FFI concurrency: parallel ffi_call with Python callbacks (libc qsort)
# + STW GC during FFI + callbacks invoked from a foreign C pthread.
import ctypes
import ctypes.util
import gc
import threading
import time

libc_name = ctypes.util.find_library("c") or "libc.so.6"
libc = ctypes.CDLL(libc_name)

CMPFUNC = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int))
libc.qsort.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, CMPFUNC]
libc.qsort.restype = None

errors = []
gc_stop = threading.Event()


def gc_bg():
    try:
        while not gc_stop.is_set():
            gc.collect(0)
            time.sleep(0.002)
    except BaseException as exc:
        errors.append(("gc_bg", repr(exc)))


def qsort_worker(tid):
    try:
        @CMPFUNC
        def cmp_int(pa, pb):
            a, b = pa[0], pb[0]
            return (a > b) - (a < b)

        for r in range(40):
            n = 64
            arr_t = ctypes.c_int * n
            data = [((i * 37 + tid * 13 + r) & 255) for i in range(n)]
            buf = arr_t(*data)
            libc.qsort(buf, n, ctypes.sizeof(ctypes.c_int), cmp_int)
            got = [buf[i] for i in range(n)]
            assert got == sorted(data), f"qsort mismatch: {got}"
    except BaseException as exc:
        errors.append(("qsort", tid, repr(exc)))


gt = threading.Thread(target=gc_bg)
qs = [threading.Thread(target=qsort_worker, args=(i,)) for i in range(4)]
gt.start()
for t in qs:
    t.start()
for t in qs:
    t.join()
gc_stop.set()
gt.join()
assert not errors, f"qsort errors: {errors}"
print("ffi_qsort_parallel ok")

# 2. Foreign C pthread created directly via pthread_create calling a Python callback
THREAD_FN = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p)
libc.pthread_create.argtypes = [
    ctypes.POINTER(ctypes.c_ulong),
    ctypes.c_void_p,
    THREAD_FN,
    ctypes.c_void_p,
]
libc.pthread_create.restype = ctypes.c_int
libc.pthread_join.argtypes = [ctypes.c_ulong, ctypes.POINTER(ctypes.c_void_p)]
libc.pthread_join.restype = ctypes.c_int

foreign_out = []
foreign_lock = threading.Lock()


@THREAD_FN
def foreign_entry(arg):
    # Allocate Python objects, mutate containers, and run bytecode on a foreign OS thread
    local_sum = sum(i * i for i in range(200))
    d = {k: k * 2 for k in range(50)}
    with foreign_lock:
        foreign_out.append((local_sum, len(d)))
    return None


tids = []
for _ in range(4):
    tid = ctypes.c_ulong(0)
    rc = libc.pthread_create(ctypes.byref(tid), None, foreign_entry, None)
    assert rc == 0, f"pthread_create failed: {rc}"
    tids.append(tid)

for tid in tids:
    rc = libc.pthread_join(tid, None)
    assert rc == 0, f"pthread_join failed: {rc}"

expected_sum = sum(i * i for i in range(200))
assert len(foreign_out) == 4
assert all(pair == (expected_sum, 50) for pair in foreign_out)
print("ffi_foreign_pthread ok")
