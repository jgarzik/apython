import os
import signal
import threading


class Interrupted(Exception):
    pass


def order_when_reading(interrupt):
    read_fd, write_fd = os.pipe()
    stop = threading.Event()
    order = []

    def handler(signum, frame):
        raise Interrupted

    def writer():
        if not stop.wait(0.4):
            order.append("write")
            os.write(write_fd, b"x")

    old = signal.signal(signal.SIGALRM, handler)
    worker = threading.Thread(target=writer, daemon=True)
    try:
        signal.siginterrupt(signal.SIGALRM, interrupt)
        worker.start()
        signal.setitimer(signal.ITIMER_REAL, 0.05)
        try:
            os.read(read_fd, 1)
        except Interrupted:
            order.append("handler")
        else:
            raise AssertionError("the signal handler did not raise")
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, old)
        stop.set()
        if worker.ident is not None:
            worker.join(2)
        os.close(read_fd)
        os.close(write_fd)
    return order


assert order_when_reading(True) == ["handler"]
assert order_when_reading(False) == ["write", "handler"]
print("both signal restart modes passed")
