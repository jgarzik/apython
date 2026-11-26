from _multiprocessing import SemLock, sem_unlink
from threading import Event, Thread

import errno
import secrets
import time


def name():
    return "/apython-test-" + secrets.token_hex(12)


recursive = SemLock(0, 1, 1, name(), True)
assert recursive.name is None
assert recursive.acquire()
assert recursive.acquire(block=False)
assert recursive._count() == 2 and recursive._is_mine() and recursive._is_zero()
recursive.release()
recursive.release()
assert recursive._get_value() == 1
try:
    recursive.release()
except AssertionError:
    pass
else:
    raise AssertionError("recursive release requires ownership")

semaphore_name = name()
sem = SemLock(1, 0, 1, semaphore_name, False)
try:
    reopened = SemLock._rebuild(sem.handle, sem.kind, sem.maxvalue, sem.name)
    assert not reopened.acquire(block=False)
    assert not reopened.acquire(timeout=0.01)

    ready = Event()
    result = []

    def wait():
        ready.set()
        result.append(reopened.acquire(timeout=2))

    thread = Thread(target=wait)
    thread.start()
    assert ready.wait(2)
    time.sleep(0.02)
    assert not result
    sem.release()
    thread.join(3)
    assert not thread.is_alive() and result == [True]

    assert reopened._count() == 1
    reopened._after_fork()
    assert reopened._count() == 0 and not reopened._is_mine()
    assert reopened._is_zero()
    reopened.release()
    try:
        sem.release()
    except ValueError:
        pass
    else:
        raise AssertionError("bounded semaphore may not exceed its maximum")
finally:
    sem_unlink(semaphore_name)

try:
    SemLock._rebuild(sem.handle, sem.kind, sem.maxvalue, sem.name)
except FileNotFoundError as exc:
    assert exc.errno == errno.ENOENT
else:
    raise AssertionError("unlinked semaphore name must be gone")
