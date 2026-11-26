from concurrent.futures import ProcessPoolExecutor
from multiprocessing import get_context
import os
import pickle
import posix


def child_error(message):
    raise ValueError(message)


if __name__ == "__main__":
    context = get_context("fork")
    queue = context.Queue()
    child = context.Process(target=queue.put, args=({"answer": 42},))
    child.start()
    try:
        assert queue.get(timeout=5) == {"answer": 42}
        child.join(5)
        assert child.exitcode == 0
    finally:
        if child.is_alive():
            child.kill()
            child.join()
        child.close()
        queue.close()
        queue.join_thread()

    with ProcessPoolExecutor(max_workers=2, mp_context=context) as pool:
        assert pool.submit(pow, 2, 8).result(5) == 256
        assert os.getpid.__self__ is posix
        assert os.getpid.__module__ == "posix"
        assert pickle.loads(pickle.dumps(os.getpid)) is os.getpid
        assert pool.submit(os.getpid).result(5) != os.getpid()
        assert list(pool.map(abs, (-3, -1, 2), timeout=5)) == [3, 1, 2]
        try:
            pool.submit(child_error, "from worker").result(5)
        except ValueError as exc:
            assert str(exc) == "from worker"
        else:
            raise AssertionError("child exception did not reach the caller")
        assert pool.submit(pow, 2, 4).result(5) == 16
