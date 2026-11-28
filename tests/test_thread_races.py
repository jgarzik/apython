# Concurrent mutation stress across shared containers, classes/caches, cells,
# string interning, compiler, and lock release races.
import array
import gc
import re
import sys
import threading
import _thread


def run_threads(target, n=6):
    errors = []

    def wrap(tid):
        try:
            target(tid)
        except BaseException as exc:
            errors.append((tid, type(exc).__name__, str(exc)))

    ts = [threading.Thread(target=wrap, args=(i,)) for i in range(n)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert not errors, f"errors: {errors}"


# 1. Shared dict concurrent set / get / pop / resize / snapshot iteration
shared_dict = {}


def dict_racer(tid):
    for i in range(600):
        k = f"k_{tid}_{i & 63}"
        shared_dict[k] = (tid, i)
        _ = shared_dict.get(k)
        if i % 5 == 0:
            shared_dict.pop(k, None)
        if i % 50 == 0:
            try:
                _ = list(shared_dict.keys())
            except RuntimeError:
                pass
            shared_dict.setdefault(f"sd_{i & 15}", tid)


run_threads(dict_racer, 6)
print("shared_dict ok")

# 2. Shared list concurrent append / pop / slice / sort / clear
shared_list = []


def list_racer(tid):
    for i in range(600):
        try:
            shared_list.append((tid, i))
        except ValueError:
            pass
        if i % 3 == 0:
            try:
                shared_list.pop()
            except (IndexError, ValueError):
                pass
        if i % 40 == 0:
            try:
                _ = shared_list[:10]
            except ValueError:
                pass
        if i % 100 == 0:
            try:
                shared_list.sort()
            except ValueError:
                pass


run_threads(list_racer, 6)
print("shared_list ok")

# 3. Shared set concurrent add / discard / pop / set ops
shared_set = set()


def set_racer(tid):
    for i in range(600):
        v = (tid, i & 63)
        shared_set.add(v)
        _ = v in shared_set
        if i % 3 == 0:
            shared_set.discard(v)
        if i % 7 == 0:
            try:
                shared_set.pop()
            except KeyError:
                pass
        if i % 80 == 0:
            try:
                _ = shared_set | {(tid, -1)}
            except RuntimeError:
                pass


run_threads(set_racer, 6)
print("shared_set ok")

# 4. Shared bytearray and array.array concurrent resize/index/pop
shared_ba = bytearray(b"init")
shared_arr = array.array("q", [1, 2, 3, 4])


def buf_racer(tid):
    for i in range(500):
        shared_ba.append(65 + (tid & 15))
        if len(shared_ba) > 128:
            try:
                shared_ba.pop()
            except IndexError:
                pass
        shared_arr.append(tid * 1000 + i)
        if i % 50 == 0:
            shared_arr[0] = tid
            _ = len(shared_arr)


run_threads(buf_racer, 4)
print("shared_buffers ok")


# 5. Shared class attribute mutation (type_cache invalidation) + dynamic subclasses
class DynBase:
    val = 0

    def get_val(self):
        return self.val


dyn_inst = DynBase()


def type_racer(tid):
    for i in range(300):
        if tid == 0:
            setattr(DynBase, "val", i)
            setattr(DynBase, f"extra_{i & 7}", i)
            if i % 10 == 0:
                try:
                    delattr(DynBase, f"extra_{(i - 1) & 7}")
                except AttributeError:
                    pass
        elif tid == 1:
            class Sub(DynBase):
                x = i
            _ = DynBase.__subclasses__()
            del Sub
        else:
            _ = dyn_inst.get_val()
            _ = getattr(DynBase, "val", -1)
            setattr(dyn_inst, f"a_{tid}", i)
            _ = getattr(dyn_inst, f"a_{tid}", 0)


run_threads(type_racer, 5)
gc.collect()
print("shared_types ok")


# 6. Shared closure cell, sys.intern, re.compile, compile/exec, threading.local
def make_cell_funcs():
    box = 0

    def writer(v):
        nonlocal box
        box = v

    def reader():
        return box

    return writer, reader


cell_write, cell_read = make_cell_funcs()
locals_created = []
locals_lock = threading.Lock()


def runtime_racer(tid):
    for i in range(200):
        cell_write((tid, i))
        v = cell_read()
        assert v == 0 or isinstance(v, tuple)
        s = sys.intern(f"intern_key_{i & 31}")
        assert isinstance(s, str)
        if i % 20 == 0:
            p = re.compile(f"abc{i & 7}[0-9]+")
            assert p.match(f"abc{i & 7}123") is not None
        if i % 40 == 0:
            ns = {}
            exec(compile(f"res = {tid} * 100 + {i}", "<race>", "exec"), ns)
            assert ns["res"] == tid * 100 + i
        if i % 50 == 0:
            tl = threading.local()
            tl.v = tid
            assert tl.v == tid
            with locals_lock:
                locals_created.append(tl)


run_threads(runtime_racer, 4)
print("runtime_subsystems ok")

# 7. Concurrent double-release race on _thread.allocate_lock()
rlock_target = _thread.allocate_lock()
double_rel_ok = [0]
dl_guard = threading.Lock()


def release_racer(tid):
    for _ in range(400):
        rlock_target.acquire(False)
        try:
            rlock_target.release()
        except RuntimeError:
            pass
    with dl_guard:
        double_rel_ok[0] += 1


run_threads(release_racer, 4)
if rlock_target.locked():
    rlock_target.release()
assert not rlock_target.locked()
print("lock_release_race ok")
