# threading, queue and concurrent.futures over real threads: the stdlib's own
# code, which until there were threads raised from Thread.start().
import threading
import queue
import time
import sys
from concurrent.futures import ThreadPoolExecutor

res = []
def w(i):
    time.sleep(0.01)
    res.append(i)
ts = [threading.Thread(target=w, args=(i,)) for i in range(8)]
for t in ts:
    t.start()
for t in ts:
    t.join()
print(sorted(res), threading.active_count(), threading.current_thread().name)

q = queue.Queue(maxsize=5)
def prod():
    for i in range(200):
        q.put(i)
    q.put(None)
def cons(out):
    while (x := q.get()) is not None:
        out.append(x)
out = []
a = threading.Thread(target=prod)
b = threading.Thread(target=cons, args=(out,))
b.start(); a.start(); a.join(); b.join()
print(sum(out), len(out), out == sorted(out))
try:
    q.get(timeout=0.02)
except queue.Empty:
    print('queue.Empty after timeout')

ev = threading.Event()
def setter():
    time.sleep(0.02)
    ev.set()
threading.Thread(target=setter).start()
print('event:', ev.wait(5), ev.is_set())

with ThreadPoolExecutor(4) as ex:
    print(list(ex.map(lambda x: x * x, range(10))))
    print(ex.submit(pow, 2, 10).result())
    f = ex.submit(lambda: 1 / 0)
    print(type(f.exception()).__name__)

loc = threading.local()
loc.x = 1
seen = []
def chk():
    seen.append(hasattr(loc, 'x'))
    loc.x = 2
    seen.append(loc.x)
t = threading.Thread(target=chk); t.start(); t.join()
print('local:', seen, loc.x)

c = threading.Condition()
items = []
got = []
def waiter():
    with c:
        while not items:
            c.wait()
        got.append(list(items))
t = threading.Thread(target=waiter); t.start()
time.sleep(0.02)
with c:
    items.append(1)
    c.notify()
t.join()
print('condition:', got)

sem = threading.Semaphore(2)
peak = [0, 0]
plock = threading.Lock()
def limited():
    with sem:
        with plock:
            peak[0] += 1
            peak[1] = max(peak[1], peak[0])
        time.sleep(0.01)
        with plock:
            peak[0] -= 1
ts = [threading.Thread(target=limited) for _ in range(8)]
for t in ts: t.start()
for t in ts: t.join()
print('semaphore peak:', peak[1])

bar = threading.Barrier(3)
order = []
def party(i):
    order.append(bar.wait(timeout=5) in (0, 1, 2))
ts = [threading.Thread(target=party, args=(i,)) for i in range(3)]
for t in ts: t.start()
for t in ts: t.join()
print('barrier:', order)

tm = threading.Timer(0.02, lambda: res.append('timer'))
tm.start(); tm.join()
print('timer:', res[-1])

# An exception in a thread is reported and does not end the program.
class Capture:
    def __init__(self): self.parts = []
    def write(self, s): self.parts.append(s)
    def flush(self): pass
cap = Capture()
real, sys.stderr = sys.stderr, cap
def boom():
    raise ValueError('in thread')
t = threading.Thread(target=boom, name='Boomer'); t.start(); t.join()
sys.stderr = real
text = ''.join(cap.parts)
print(text.splitlines()[0], '|', text.splitlines()[-1])

d = threading.Thread(target=time.sleep, args=(30,), daemon=True)
d.start()
print('daemon alive at exit:', d.is_alive(), [t.name for t in threading.enumerate() if not t.daemon])
