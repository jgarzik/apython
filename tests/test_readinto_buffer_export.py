import errno
import fcntl
import io
import os
import signal
import threading
import time


def while_reading(read_into, unblock):
    buffer = bytearray(8)
    ready = threading.Event()
    results = []

    def read():
        ready.set()
        results.append(read_into(buffer))

    worker = threading.Thread(target=read, daemon=True)
    worker.start()
    try:
        assert ready.wait(5)
        deadline = time.monotonic() + 0.5
        while time.monotonic() < deadline:
            try:
                buffer.append(0)
            except BufferError:
                break
            time.sleep(0.001)
        else:
            raise AssertionError("blocking read did not export its buffer")
    finally:
        unblock()
        worker.join(5)

    assert results == [0]
    buffer.append(0)


def file_readinto():
    read_fd, write_fd = os.pipe()
    try:
        with io.FileIO(read_fd, "rb", closefd=False) as reader:
            while_reading(reader.readinto, lambda: os.close(write_fd))
    finally:
        os.close(read_fd)

    read_fd, write_fd = os.pipe()
    try:
        with io.FileIO(read_fd, "rb", closefd=False) as reader:
            buffer = bytearray(1)
            flags = fcntl.fcntl(read_fd, fcntl.F_GETFL)
            fcntl.fcntl(read_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
            assert reader.readinto(buffer) is None
            buffer.append(0)

        bad_fd = os.dup(read_fd)
        with io.FileIO(bad_fd, "rb", closefd=False) as reader:
            os.close(bad_fd)
            try:
                reader.readinto(buffer)
            except OSError as error:
                assert error.errno == errno.EBADF
            else:
                raise AssertionError("read from a closed descriptor succeeded")
            buffer.append(0)
    finally:
        os.close(read_fd)
        os.close(write_fd)


def view_readinto():
    read_fd, write_fd = os.pipe()
    view = memoryview(bytearray(1))
    errors = []

    def interrupt_read(signum, frame):
        try:
            view.release()
        except BufferError as error:
            errors.append(str(error))
        os.write(write_fd, b"x")

    old_handler = signal.signal(signal.SIGALRM, interrupt_read)
    try:
        with io.FileIO(read_fd, "rb", closefd=False) as reader:
            signal.setitimer(signal.ITIMER_REAL, 0.05)
            assert reader.readinto(view) == 1
            assert view.tobytes() == b"x"
            assert errors == ["memoryview has 1 exported buffer"]
            view.release()
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, old_handler)
        os.close(read_fd)
        os.close(write_fd)


file_readinto()
view_readinto()
print("readinto releases its buffer")
