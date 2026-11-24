# Two Python threads: start, run, finish, and share data under a lock.
# Everything printed is deterministic -- threads are joined before a result
# is read, and nothing prints from inside a thread without a lock ordering it.
import _thread
import time

done = _thread.allocate_lock()
done.acquire()
seen = []

def worker(a, b, key=None):
    seen.append((a, b, key, _thread.get_ident() != main_ident))
    done.release()

main_ident = _thread.get_ident()
ident = _thread.start_new_thread(worker, (1, 2), {'key': 'k'})
done.acquire()
print('ran:', seen, isinstance(ident, int), ident != main_ident)

# A counter incremented from several threads, each under the lock.
lock = _thread.allocate_lock()
count = 0
N = 4
ITER = 20000
finished = [_thread.allocate_lock() for _ in range(N)]
for f in finished:
    f.acquire()

def bump(f):
    global count
    for _ in range(ITER):
        with lock:
            count += 1
    f.release()

for f in finished:
    _thread.start_new_thread(bump, (f,))
for f in finished:
    f.acquire()
print('count:', count, count == N * ITER)

# Threads really interleave: a spinning thread does not starve another.
flag = []
def spinner(f):
    while not flag:
        pass
    f.release()

f = _thread.allocate_lock(); f.acquire()
_thread.start_new_thread(spinner, (f,))
time.sleep(0.05)
flag.append(1)
print('spinner stopped:', f.acquire(True, 5))

# A builtin as the thread's function, and a list filled from threads.
out = []
g = _thread.allocate_lock(); g.acquire()
def fill(n, g):
    out.extend(range(n))
    g.release()
_thread.start_new_thread(fill, (5, g))
g.acquire()
print('filled:', out)

# SystemExit ends a thread silently; the main thread carries on.
e = _thread.allocate_lock(); e.acquire()
def quitter():
    try:
        _thread.exit()
    finally:
        e.release()
_thread.start_new_thread(quitter, ())
e.acquire()
print('exit was silent')

# Sleeping threads sleep at the same time, not one after another.
t0 = time.monotonic()
sl = [_thread.allocate_lock() for _ in range(4)]
for s in sl:
    s.acquire()
def sleeper(s):
    time.sleep(0.2)
    s.release()
for s in sl:
    _thread.start_new_thread(sleeper, (s,))
for s in sl:
    s.acquire()
print('slept together:', time.monotonic() - t0 < 0.6)

# Argument checking, in CPython's words.
for bad in [(1, ()), (len, []), (len, (), 3)]:
    try:
        _thread.start_new_thread(*bad)
    except TypeError as err:
        print('TypeError:', err)

time.sleep(0.05)        # let the last threads finish unwinding
print('_count:', _thread._count())
print('error is RuntimeError:', _thread.error is RuntimeError)

# os._exit() from a thread ends the PROCESS, not the thread.
import os, sys, subprocess
code = ("import os, threading, time\n"
        "threading.Thread(target=lambda: os._exit(7)).start()\n"
        "time.sleep(30)\n")
r = subprocess.run([sys.executable, '-c', code], timeout=20)
print('_exit from a thread:', r.returncode)
