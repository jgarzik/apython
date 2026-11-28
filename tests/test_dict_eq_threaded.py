"""Regression test for dict equality when free-threading is active.

When rt_threaded != 0 (after any thread has started), dict_richcompare_inner
used to fall through into .drc_unlock_next after already unlocking the left
dict, calling OBJ_UNLOCK on DRC_RVAL (which can be an immediate int/float)
and crashing with SIGSEGV.
"""
import threading

t = threading.Thread(target=lambda: None)
t.start()
t.join()

# Immediate integer values (previously crashed dereferencing tagged int + 12)
assert {"a": 1, "b": 2, "c": 3} == {"a": 1, "b": 2, "c": 3}
assert {"a": 1, "b": 2} != {"a": 1, "b": 3}
assert {"a": 1, "b": 2} != {"a": 1, "c": 2}
assert {1: 1.5, 2: "x", 3: None} == {1: 1.5, 2: "x", 3: None}
assert {1: True, 2: 0} == {1: 1, 2: 0.0}

# Nested dicts and concurrent dict equality checks
results = []
def worker(idx):
    d1 = {k: k * 2 for k in range(20)}
    d2 = {k: k * 2 for k in range(20)}
    for _ in range(100):
        assert d1 == d2
        assert d1 != {**d2, 0: 999}
    results.append(idx)

threads = [threading.Thread(target=worker, args=(i,)) for i in range(4)]
for th in threads:
    th.start()
for th in threads:
    th.join()

assert sorted(results) == [0, 1, 2, 3]
print("dict_eq_threaded: ok")
