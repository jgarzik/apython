# _thread's locks: the plain lock, the reentrant one, timeouts, and the
# wordings a program that catches the errors would print.
import _thread
import time

lk = _thread.allocate_lock()
print(type(lk).__name__, lk.locked(), lk.acquire(), lk.locked())
print(lk.acquire(False), lk.acquire(blocking=False))
t0 = time.monotonic()
print(lk.acquire(True, 0.1), 0.08 < time.monotonic() - t0 < 2.0)
print(lk.acquire(timeout=0.01))
lk.release()
print(lk.locked())
try:
    lk.release()
except RuntimeError as e:
    print('RuntimeError:', e)
for args in [(False, 1), (True, -5), (True, 1e10)]:
    try:
        lk.acquire(*args)
    except (ValueError, OverflowError) as e:
        print(type(e).__name__ + ':', e)
with lk:
    print('held in with:', lk.locked())
print('after with:', lk.locked())
print(repr(lk).startswith('<unlocked _thread.lock object at 0x'))
lk.acquire()
print(repr(lk).startswith('<locked _thread.lock object at 0x'))
lk._at_fork_reinit()
print('reinit:', lk.locked())
print(_thread.LockType is type(lk))

# A lock is not owned: one thread takes it, another lets it go.
gate = _thread.allocate_lock()
gate.acquire()
def opener():
    time.sleep(0.05)
    gate.release()
_thread.start_new_thread(opener, ())
print('released by another thread:', gate.acquire(True, 5))

# As a class attribute it is not bound as a method.
class Holder:
    locktype = _thread.allocate_lock
print(type(Holder().locktype()).__name__)

# RLock
r = _thread.RLock()
print(r.acquire(), r.acquire(), r._is_owned())
r.release(); r.release()
print(r._is_owned())
try:
    r.release()
except RuntimeError as e:
    print('RuntimeError:', e)
res = []
def other():
    res.append(r.acquire(False))
    res.append(r._is_owned())
    try:
        r.release()
    except RuntimeError as e:
        res.append(str(e))
    done.release()
done = _thread.allocate_lock(); done.acquire()
r.acquire()
_thread.start_new_thread(other, ())
done.acquire()
r.release()
print('from another thread:', res)
with r:
    with r:
        st = r._release_save()
        print('saved depth:', st[0], r._is_owned())
        r._acquire_restore(st)
        print('restored:', r._is_owned())
print('rlock free:', r.acquire(False)); r.release()

# stack_size and interrupt_main
print(_thread.stack_size(), _thread.stack_size(262144), _thread.stack_size(0))
try:
    _thread.stack_size(100)
except ValueError as e:
    print('ValueError:', e)
try:
    _thread.interrupt_main()
    for _ in range(100000):
        pass
    print('not interrupted')
except KeyboardInterrupt:
    print('KeyboardInterrupt in main')
try:
    _thread.interrupt_main(1000)
except ValueError as e:
    print('ValueError:', e)
print(_thread.TIMEOUT_MAX)
