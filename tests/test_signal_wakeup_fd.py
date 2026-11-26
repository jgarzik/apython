import _thread
import contextlib
import errno
import io
import os
import signal
import socket
import sys
import threading


def refuses(exception, operation):
    try:
        operation()
    except exception as error:
        return error
    raise AssertionError(f"expected {exception.__name__}")


read_fd, write_fd = os.pipe()
os.set_blocking(read_fd, False)
seen = []
errors = []
old_handler = signal.signal(signal.SIGUSR1, lambda signum, frame: seen.append(signum))
old_hook = sys.unraisablehook
old_fd = signal.set_wakeup_fd(-1)
sys.unraisablehook = errors.append

try:
    refuses(ValueError, lambda: signal.set_wakeup_fd(write_fd))
    refuses(OSError, lambda: signal.set_wakeup_fd(-2))
    refuses(OverflowError, lambda: signal.set_wakeup_fd(1 << 100))
    refuses(TypeError, lambda: signal.set_wakeup_fd(fd=write_fd))

    os.set_blocking(write_fd, False)
    assert signal.set_wakeup_fd(write_fd) == -1
    worker_errors = []
    worker = threading.Thread(
        target=lambda: worker_errors.append(refuses(ValueError, lambda: signal.set_wakeup_fd(-1)))
    )
    worker.start()
    worker.join(5)
    assert len(worker_errors) == 1
    assert signal.set_wakeup_fd(write_fd) == write_fd

    signal.raise_signal(signal.SIGUSR1)
    assert os.read(read_fd, 1) == bytes([signal.SIGUSR1])
    assert seen == [signal.SIGUSR1]
    _thread.interrupt_main(signal.SIGUSR1)
    assert os.read(read_fd, 1) == bytes([signal.SIGUSR1])
    assert seen == [signal.SIGUSR1] * 2

    sender, receiver = socket.socketpair()
    with sender, receiver:
        sender.setblocking(False)
        receiver.setblocking(False)
        assert signal.set_wakeup_fd(sender.fileno()) == write_fd
        signal.raise_signal(signal.SIGUSR1)
        assert receiver.recv(1) == bytes([signal.SIGUSR1])
        assert signal.set_wakeup_fd(write_fd) == sender.fileno()

    while True:
        try:
            os.write(write_fd, b"x" * 4096)
        except BlockingIOError:
            break
    while True:
        try:
            os.write(write_fd, b"x")
        except BlockingIOError:
            break

    signal.raise_signal(signal.SIGUSR1)
    assert len(errors) == 1
    assert errors[0].exc_value.errno == errno.EAGAIN
    assert errors[0].err_msg == "Exception ignored when trying to write to the signal wakeup fd"
    assert errors[0].object is None
    errors.clear()

    assert signal.set_wakeup_fd(write_fd, warn_on_full_buffer=False) == write_fd
    signal.raise_signal(signal.SIGUSR1)
    assert not errors

    os.close(write_fd)
    write_fd = -1
    signal.raise_signal(signal.SIGUSR1)
    assert len(errors) == 1
    assert errors[0].exc_value.errno == errno.EBADF
    report = io.StringIO()
    with contextlib.redirect_stderr(report):
        sys.__unraisablehook__(errors[0])
    assert errors[0].err_msg + ":" in report.getvalue()
    assert "OSError: [Errno 9]" in report.getvalue()
    assert signal.set_wakeup_fd(-1) >= 0
    assert signal.set_wakeup_fd(-1) == -1
finally:
    signal.set_wakeup_fd(old_fd)
    signal.signal(signal.SIGUSR1, old_handler)
    sys.unraisablehook = old_hook
    if write_fd != -1:
        os.close(write_fd)
    os.close(read_fd)

print("signal wakeup descriptors passed")
