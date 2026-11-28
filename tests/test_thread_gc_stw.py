# Stop-The-World (STW) GC stress + detached blocked threads + fork() under load.
import gc
import os
import threading
import time
import warnings
import weakref

warnings.filterwarnings("ignore", category=DeprecationWarning)

stop_evt = threading.Event()
errors = []
fin_count = [0]
fin_lock = threading.Lock()
wr_cb_count = [0]
wr_lock = threading.Lock()


class CycNode:
    def __init__(self, v):
        self.v = v
        self.peer = None

    def __del__(self):
        with fin_lock:
            fin_count[0] += 1


def wr_cb(_r):
    with wr_lock:
        wr_cb_count[0] += 1


def make_gen_cycle():
    d = {}

    def g():
        try:
            yield 1
        finally:
            pass

    it = g()
    next(it)
    d["self"] = d
    d["it"] = it
    return d


# 1. Cycle churn + concurrent gc.collect() + gc.get_objects() + detached sleepers
def churn_worker(tid):
    try:
        refs = []
        for r in range(250):
            a, b = CycNode(r), CycNode(-r)
            a.peer, b.peer = b, a
            if r % 4 == 0:
                refs.append(weakref.ref(a, wr_cb))
                if len(refs) > 32:
                    del refs[:16]
            del a, b
            if r % 10 == 0:
                make_gen_cycle()
    except BaseException as exc:
        errors.append(("churn", tid, repr(exc)))


def gc_worker(tid):
    try:
        while not stop_evt.is_set():
            gc.collect()
            objs = gc.get_objects(0)
            assert isinstance(objs, list)
            del objs
            time.sleep(0.001)
    except BaseException as exc:
        errors.append(("gc", tid, repr(exc)))


# Detached pipe reader: verifies STW does NOT stall on a thread blocked in read()
r_fd, w_fd = os.pipe()


def pipe_reader():
    try:
        data = os.read(r_fd, 16)
        assert data == b"wake"
    except BaseException as exc:
        errors.append(("pipe", 0, repr(exc)))


def sleeper():
    try:
        while not stop_evt.is_set():
            time.sleep(0.005)
    except BaseException as exc:
        errors.append(("sleep", 0, repr(exc)))


pr = threading.Thread(target=pipe_reader)
sl = threading.Thread(target=sleeper)
gcs = [threading.Thread(target=gc_worker, args=(i,)) for i in range(2)]
churns = [threading.Thread(target=churn_worker, args=(i,)) for i in range(4)]

pr.start()
sl.start()
for t in gcs:
    t.start()
for t in churns:
    t.start()
for t in churns:
    t.join()

stop_evt.set()
os.write(w_fd, b"wake")
pr.join()
sl.join()
for t in gcs:
    t.join()
os.close(r_fd)
os.close(w_fd)

gc.collect()
assert not errors, f"stw gc errors: {errors}"
assert fin_count[0] == 4 * 250 * 2, f"fin_count={fin_count[0]}"
print("stw_gc ok")

# 2. os.fork() while background threads actively allocate, mutate dicts, and GC
fork_stop = threading.Event()
fork_errors = []


def bg_mutator(tid):
    try:
        d = {}
        i = 0
        while not fork_stop.is_set():
            d[i & 63] = [tid, i, (i, i + 1)]
            if i % 100 == 0:
                gc.collect(0)
            i += 1
    except BaseException as exc:
        fork_errors.append((tid, repr(exc)))


bgs = [threading.Thread(target=bg_mutator, args=(i,)) for i in range(4)]
for t in bgs:
    t.start()
time.sleep(0.01)

pid = os.fork()
if pid == 0:
    # Child: verify allocator, dict/list, GC, and new threads work cleanly
    child_d = {i: [i, i * 2] for i in range(200)}
    gc.collect()
    res = []
    ct = threading.Thread(target=lambda: res.append(sum(k for k in child_d)))
    ct.start()
    ct.join()
    ok = (len(res) == 1 and res[0] == sum(range(200)))
    os._exit(0 if ok else 1)
else:
    _, status = os.waitpid(pid, 0)
    fork_stop.set()
    for t in bgs:
        t.join()
    assert not fork_errors, f"fork bg errors: {fork_errors}"
    assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
    print("fork_under_load ok")
