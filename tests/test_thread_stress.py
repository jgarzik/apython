# Threads at a switch interval short enough that the GIL changes hands in the
# middle of everything: allocation churn, shared containers under a lock and
# private ones without, the collector with finalizers that run Python,
# imports, exceptions, generators, and lock ping-pong.  The answer has to be
# exactly what one thread at a time would produce.
import sys
import threading
import gc
import time

sys.setswitchinterval(1e-5)

N = 8
ROUNDS = 300
lock = threading.Lock()
shared = {}
total = [0]
finalized = [0]
errors = []


class Node:
    def __init__(self, v):
        self.v = v
        self.other = None
    def __del__(self):
        with lock:
            finalized[0] += 1


def gen(n):
    for i in range(n):
        yield i * i


def worker(tid):
    try:
        mine = []
        for r in range(ROUNDS):
            # private churn: lists, dicts, strings, tuples, big ints
            mine.append([tid, r, str(r) * 3, (r, r + 1), 1 << (60 + r % 20)])
            if len(mine) > 50:
                del mine[:25]
            d = {('k', i): [i] * 3 for i in range(20)}
            s = sum(len(v) for v in d.values()) + sum(gen(10))
            # a cycle with finalizers, left for the collector
            a, b = Node(r), Node(-r)
            a.other, b.other = b, a
            del a, b
            # shared state, under the lock
            with lock:
                shared[(tid, r)] = s
                total[0] += s
            # an exception caught
            try:
                {}['missing']
            except KeyError:
                pass
            if r % 60 == 0:
                gc.collect()
            if r % 100 == 0:
                import json, fractions, textwrap   # imports race each other
                json.dumps({'t': tid, 'r': r})
        with lock:
            shared[('done', tid)] = len(mine)
    except BaseException as e:           # must not happen
        errors.append((tid, repr(e)))


threads = [threading.Thread(target=worker, args=(i,)) for i in range(N)]
for t in threads:
    t.start()
for t in threads:
    t.join()

per_round = 60 + sum(i * i for i in range(10))
print('errors:', errors)
print('entries:', len(shared), len(shared) == N * ROUNDS + N)
print('total:', total[0], total[0] == N * ROUNDS * per_round)
gc.collect()
print('finalized:', finalized[0], finalized[0] == 2 * N * ROUNDS)

# Lock ping-pong: two threads alternate strictly.
a, b = threading.Lock(), threading.Lock()
b.acquire()
seq = []
def ping():
    for i in range(500):
        a.acquire(); seq.append('a'); b.release()
def pong():
    for i in range(500):
        b.acquire(); seq.append('b'); a.release()
t1 = threading.Thread(target=ping); t2 = threading.Thread(target=pong)
t1.start(); t2.start(); t1.join(); t2.join()
print('ping-pong:', len(seq), seq == ['a', 'b'] * 500)

# An unlocked counter in a single bytecode-atomic operation: list.append.
bag = []
def filler(k):
    for i in range(2000):
        bag.append((k, i))
ts = [threading.Thread(target=filler, args=(k,)) for k in range(N)]
for t in ts: t.start()
for t in ts: t.join()
print('appends:', len(bag), len(set(bag)))

# Condition-driven hand-off through a bounded buffer.
import queue
q = queue.Queue(maxsize=3)
got = []
def producer():
    for i in range(1000):
        q.put(i)
    q.put(None)
def consumer():
    while (x := q.get()) is not None:
        got.append(x)
p = threading.Thread(target=producer); c = threading.Thread(target=consumer)
p.start(); c.start(); p.join(); c.join()
print('queue:', got == list(range(1000)))
print('threads left:', threading.active_count())
