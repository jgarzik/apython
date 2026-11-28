# Biased Reference Counting (BRC) remote-drop, owner-exit orphan merge, and
# weakref death vs dereference (obj_try_incref) race tests.
import gc
import queue
import threading
import weakref

errors = []


class Box:
    def __init__(self, v):
        self.v = v


# 1. Cross-thread BRC handoff: producer creates objects, 4 consumers drop last ref
q = queue.Queue(maxsize=256)
consumed = [0]
c_lock = threading.Lock()


def consumer():
    try:
        local_n = 0
        while True:
            batch = q.get()
            if batch is None:
                break
            # Touch every object then drop all references on this remote thread
            s = 0
            for item in batch:
                s += item[0].v + len(item[1])
            assert s >= 0
            local_n += len(batch)
            del batch
        with c_lock:
            consumed[0] += local_n
    except BaseException as exc:
        errors.append(("brc_consumer", repr(exc)))


consumers = [threading.Thread(target=consumer) for _ in range(4)]
for t in consumers:
    t.start()

TOTAL_BATCHES = 400
BATCH_SIZE = 20
for b in range(TOTAL_BATCHES):
    batch = [
        (Box(b * BATCH_SIZE + i), [i, i + 1], {"k": f"v_{b}_{i}"}, 1 << 70)
        for i in range(BATCH_SIZE)
    ]
    q.put(batch)
    del batch
for _ in consumers:
    q.put(None)
for t in consumers:
    t.join()

gc.collect()
assert not errors, f"brc errors: {errors}"
assert consumed[0] == TOTAL_BATCHES * BATCH_SIZE
print("brc_handoff ok")

# 2. Orphaned BRC: owner thread creates objects and EXITS before they are freed
orphans = []


def orphan_producer():
    for i in range(2000):
        orphans.append((Box(i), [i, str(i)], {i: i * 2}, (1 << 80) + i))


op = threading.Thread(target=orphan_producer)
op.start()
op.join()
assert len(orphans) == 2000
assert orphans[1234][0].v == 1234
orphans.clear()
gc.collect()
print("brc_orphan ok")

# 3. Weakref death vs concurrent dereference (obj_try_incref) race
slot = [None, None]  # [strong_ref, weakref]
wr_stop = threading.Event()
deref_hits = [0]
wr_lock = threading.Lock()


def wr_creator():
    try:
        for i in range(4000):
            obj = Box(i)
            r = weakref.ref(obj)
            slot[1] = r
            slot[0] = obj
            slot[0] = None
            del obj
    except BaseException as exc:
        errors.append(("wr_creator", repr(exc)))
    finally:
        wr_stop.set()


def wr_reader(tid):
    try:
        hits = 0
        while not wr_stop.is_set():
            r = slot[1]
            if r is not None:
                o = r()
                if o is not None:
                    assert isinstance(o, Box)
                    assert isinstance(o.v, int)
                    hits += 1
                    del o
        with wr_lock:
            deref_hits[0] += hits
    except BaseException as exc:
        errors.append(("wr_reader", tid, repr(exc)))


readers = [threading.Thread(target=wr_reader, args=(i,)) for i in range(4)]
creator = threading.Thread(target=wr_creator)
for t in readers:
    t.start()
creator.start()
creator.join()
for t in readers:
    t.join()

assert not errors, f"weakref race errors: {errors}"
print("weakref_race ok")
