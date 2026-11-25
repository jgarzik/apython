# Error paths of os/posix, socket and signal: wrong counts and types, bad
# paths, bad descriptors -- and what each failure leaves behind.
#
# Every case is run once for its exception and then 200 more times with
# sys.getallocatedblocks() read around the loop.  An error that leaves a
# builtin by jumping abandons whatever the call held: a path __fspath__
# built, a read buffer, the first of two resolved paths.  Only "did it climb
# by fewer than 50 blocks" is printed, so the output is the same wherever the
# allocator differs.
import os
import sys
import signal
import socket
import tempfile
import shutil

LOOPS = 200


def case(label, fn, msg=False):
    try:
        fn()
        result = "no error"
    except BaseException as e:
        result = type(e).__name__
        if isinstance(e, OSError) and e.errno is not None:
            result += " errno=%d" % e.errno
        if msg:
            result += ": %s" % e
    before = sys.getallocatedblocks()
    for _ in range(LOOPS):
        try:
            fn()
        except BaseException:
            pass
    grew = sys.getallocatedblocks() - before
    print("%-28s %s | steady=%s" % (label, result, grew < 50))


class P:
    """A path-like whose __fspath__ builds a NEW string every time."""
    def __init__(self, *parts):
        self.parts = parts

    def __fspath__(self):
        return os.path.join(*self.parts)


class Raises:
    def __fspath__(self):
        raise KeyError("from __fspath__")


class NotAPath:
    def __fspath__(self):
        return 42


work = tempfile.mkdtemp()
try:
    here = os.path.join(work, "present")
    open(here, "w").close()
    gone = P(work, "no-such-entry-" + "x" * 40)
    gone2 = P(work, "nor-this-one-" + "y" * 40)
    present = P(work, "present")
    NUL = "a\0b"

    print("-- one path")
    for name in ("stat", "lstat", "unlink", "rmdir", "chdir", "readlink",
                 "listdir", "scandir"):
        fn = getattr(os, name)
        case(name + " missing", lambda: fn(gone))
        case(name + " NUL", lambda: fn(NUL))
        case(name + " float", lambda: fn(3.5))
        case(name + " fspath raises", lambda: fn(Raises()))
        case(name + " fspath int", lambda: fn(NotAPath()))
    for name in ("stat", "lstat", "unlink", "rmdir", "chdir", "readlink"):
        fn = getattr(os, name)
        case(name + " no args", lambda: fn())

    print("-- path and integer")
    case("open missing", lambda: os.open(gone, os.O_RDONLY))
    case("open flags str", lambda: os.open(present, "r"))
    case("open mode str", lambda: os.open(present, os.O_RDONLY, "m"))
    case("open NUL", lambda: os.open(NUL, os.O_RDONLY))
    case("open fspath raises", lambda: os.open(Raises(), os.O_RDONLY))
    case("open one arg", lambda: os.open(present))
    case("mkdir mode str", lambda: os.mkdir(gone, "m"))
    case("mkdir exists", lambda: os.mkdir(P(work)))
    case("mkdir no args", lambda: os.mkdir())
    case("chmod missing", lambda: os.chmod(gone, 0o600))
    case("chmod mode str", lambda: os.chmod(present, "m"))
    case("chmod fspath raises", lambda: os.chmod(Raises(), 0o600))
    case("chmod one arg", lambda: os.chmod(present))
    case("access mode str", lambda: os.access(present, "m"))
    case("access fspath raises", lambda: os.access(Raises(), os.R_OK))
    case("access missing", lambda: os.access(gone, os.R_OK))
    case("chown missing", lambda: os.chown(gone, -1, -1))
    case("chown uid str", lambda: os.chown(present, "u", -1))
    case("chown gid str", lambda: os.chown(present, -1, "g"))
    case("chown fspath int", lambda: os.chown(NotAPath(), -1, -1))
    case("truncate missing", lambda: os.truncate(gone, 0))
    case("truncate length str", lambda: os.truncate(present, "n"))
    case("truncate fspath raises", lambda: os.truncate(Raises(), 0))
    case("utime missing", lambda: os.utime(gone, (1, 2)))
    case("utime times int", lambda: os.utime(present, 5))
    case("utime fspath raises", lambda: os.utime(Raises(), (1, 2)))

    print("-- two paths: the second is refused, the first must be released")
    for name in ("rename", "replace", "symlink", "link"):
        fn = getattr(os, name)
        case(name + " 2nd NUL", lambda: fn(gone, NUL))
        case(name + " 2nd float", lambda: fn(gone, 3.5))
        case(name + " 2nd raises", lambda: fn(gone, Raises()))
        case(name + " 2nd int", lambda: fn(gone, NotAPath()))
        case(name + " 1st raises", lambda: fn(Raises(), gone))
        case(name + " one arg", lambda: fn(gone))
    case("rename both missing", lambda: os.rename(gone, gone2))
    case("link both missing", lambda: os.link(gone, gone2))
    case("symlink exists", lambda: os.symlink(gone, present))

    print("-- environment and exec")
    case("putenv one arg", lambda: os.putenv("A"))
    case("putenv = in name", lambda: os.putenv("A=B", "c"))
    case("putenv 2nd int", lambda: os.putenv(P("NAME" + "n" * 40), 5))
    case("putenv 2nd raises", lambda: os.putenv(P("NAME" + "n" * 40), Raises()))
    case("unsetenv int", lambda: os.unsetenv(5))
    case("execv missing", lambda: os.execv(gone, ["x"]))
    case("execv args int", lambda: os.execv(gone, 5))
    case("execv arg not str", lambda: os.execv(gone, ["x", 5]))
    case("execv arg NUL", lambda: os.execv(gone, ["x\0y"]), msg=True)
    case("execve env int", lambda: os.execve(gone, ["x"], 5))
    case("execve = in name", lambda: os.execve(gone, ["x"], {"A=B": "c"}), msg=True)
    case("execve NUL in name", lambda: os.execve(gone, ["x"], {"A\0": "c"}), msg=True)
    case("execve NUL in value", lambda: os.execve(gone, ["x"], {"A": "c\0"}), msg=True)

    print("-- descriptors")
    case("close bad fd", lambda: os.close(-1))
    case("close str", lambda: os.close("x"))
    case("close float", lambda: os.close(1.5))
    case("close huge", lambda: os.close(2 ** 70))
    case("close no args", lambda: os.close())
    case("read bad fd", lambda: os.read(-1, 16))
    case("read fd str", lambda: os.read("x", 16))
    case("read count str", lambda: os.read(0, "n"))
    case("read one arg", lambda: os.read(0))
    case("write bad fd", lambda: os.write(-1, b"x"))
    case("write fd str", lambda: os.write("x", b"x"))
    case("write data int", lambda: os.write(1, 5))
    case("write one arg", lambda: os.write(1))
    case("lseek bad fd", lambda: os.lseek(-1, 0, 0))
    case("lseek fd str", lambda: os.lseek("x", 0, 0))
    case("lseek pos str", lambda: os.lseek(0, "p", 0))
    case("lseek whence str", lambda: os.lseek(0, 0, "w"))
    case("dup bad fd", lambda: os.dup(-1))
    case("dup str", lambda: os.dup("x"))
    case("dup2 bad fd", lambda: os.dup2(-1, 50))
    case("dup2 fd str", lambda: os.dup2("x", 50))
    case("dup2 fd2 str", lambda: os.dup2(1, "y"))
    case("fstat bad fd", lambda: os.fstat(-1))
    case("fstat str", lambda: os.fstat("x"))
    case("ftruncate bad fd", lambda: os.ftruncate(-1, 0))
    case("ftruncate fd str", lambda: os.ftruncate("x", 0))
    case("ftruncate length str", lambda: os.ftruncate(1, "n"))
    case("fchmod bad fd", lambda: os.fchmod(-1, 0o600))
    case("fchmod mode str", lambda: os.fchmod(1, "m"))
    case("fsync str", lambda: os.fsync("x"))
    case("pread bad fd", lambda: os.pread(-1, 16, 0))
    case("pread fd str", lambda: os.pread("x", 16, 0))
    case("pread offset str", lambda: os.pread(0, 16, "o"))
    case("pwrite bad fd", lambda: os.pwrite(-1, b"x", 0))
    case("pwrite data str", lambda: os.pwrite(1, "x", 0))
    case("pwrite offset str", lambda: os.pwrite(1, b"x", "o"))
    case("sendfile bad fds", lambda: os.sendfile(-1, -1, 0, 1))
    case("sendfile count str", lambda: os.sendfile(1, 0, 0, "n"))
    case("get_inheritable bad fd", lambda: os.get_inheritable(-1))
    case("get_inheritable str", lambda: os.get_inheritable("x"))
    case("set_inheritable bad fd", lambda: os.set_inheritable(-1, True))
    case("set_inheritable str", lambda: os.set_inheritable("x", True))
    case("get_terminal_size bad fd", lambda: os.get_terminal_size(-1))
    case("isatty str", lambda: os.isatty("x"))
    case("umask str", lambda: os.umask("x"))
    case("urandom negative", lambda: os.urandom(-1))
    case("urandom str", lambda: os.urandom("x"))
    case("strerror str", lambda: os.strerror("x"))
    case("fspath int", lambda: os.fspath(5), msg=True)
    case("fspath raises", lambda: os.fspath(Raises()))
    case("fspath fspath int", lambda: os.fspath(NotAPath()), msg=True)

    print("-- processes")
    case("kill pid str", lambda: os.kill("p", 0))
    case("kill sig str", lambda: os.kill(os.getpid(), "s"))
    case("kill no such pid", lambda: os.kill(2 ** 22 + 12345, 0))
    case("waitpid pid str", lambda: os.waitpid("p", 0))
    case("waitpid options str", lambda: os.waitpid(0, "o"))
    case("waitpid no child", lambda: os.waitpid(2 ** 22 + 12345, 0))
    case("WEXITSTATUS str", lambda: os.WEXITSTATUS("s"))
    case("WIFEXITED str", lambda: os.WIFEXITED("s"))
    case("waitstatus_to_exitcode str", lambda: os.waitstatus_to_exitcode("s"))
    case("waitstatus_to_exitcode bad", lambda: os.waitstatus_to_exitcode(0x7f))
    case("setpgid pid str", lambda: os.setpgid("p", 0))
    case("setpgid pgrp str", lambda: os.setpgid(0, "g"))
    case("setuid str", lambda: os.setuid("u"))
    case("sched_getaffinity str", lambda: os.sched_getaffinity("p"))
    case("register_at_fork nothing", lambda: os.register_at_fork(), msg=True)
    case("register_at_fork bad kw", lambda: os.register_at_fork(nope=len))
    case("_exit str", lambda: os._exit("code"))

    print("-- socket")
    a, b = socket.socketpair()
    closed = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    closed_fd = closed.fileno()
    closed.close()
    case("socket bad family", lambda: socket.socket(9999, socket.SOCK_STREAM))
    case("socket family str", lambda: socket.socket("f", socket.SOCK_STREAM))
    case("recv count str", lambda: a.recv("n"))
    case("recv negative", lambda: a.recv(-1))
    case("recv flags str", lambda: a.recv(1, "f"))
    case("recv closed", lambda: closed.recv(1))
    case("send int", lambda: a.send(5))
    case("send flags str", lambda: a.send(b"x", "f"))
    case("send closed", lambda: closed.send(b"x"))
    case("recv_into bytes", lambda: a.recv_into(b"readonly"))
    case("recv_into too many", lambda: a.recv_into(bytearray(4), 99))
    case("recvfrom count str", lambda: a.recvfrom("n"))
    case("recvfrom negative", lambda: a.recvfrom(-1))
    case("setsockopt level str", lambda: a.setsockopt("l", socket.SO_REUSEADDR, 1))
    case("setsockopt name str", lambda: a.setsockopt(socket.SOL_SOCKET, "n", 1))
    case("setsockopt closed", lambda: closed.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1))
    case("getsockopt level str", lambda: a.getsockopt("l", socket.SO_REUSEADDR))
    case("getsockopt closed", lambda: closed.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR))
    case("listen backlog str", lambda: a.listen("b"))
    case("listen closed", lambda: closed.listen(1))
    case("shutdown how str", lambda: a.shutdown("h"))
    case("shutdown closed", lambda: closed.shutdown(socket.SHUT_RDWR))
    case("accept closed", lambda: closed.accept())
    case("getsockname closed", lambda: closed.getsockname())
    case("getpeername closed", lambda: closed.getpeername())
    case("setblocking closed", lambda: closed.setblocking(False))
    case("socketpair bad family", lambda: socket.socketpair(9999))
    case("dup bad fd", lambda: socket.dup(-1))
    a.close()
    b.close()

    print("-- signal")
    case("signal no args", lambda: signal.signal())
    case("signal number str", lambda: signal.signal("n", signal.SIG_DFL))
    case("signal out of range", lambda: signal.signal(9999, signal.SIG_DFL), msg=True)
    case("signal handler str", lambda: signal.signal(signal.SIGUSR1, "h"), msg=True)
    case("signal SIGKILL", lambda: signal.signal(signal.SIGKILL, signal.SIG_IGN))
    case("getsignal str", lambda: signal.getsignal("n"))
    case("getsignal out of range", lambda: signal.getsignal(9999), msg=True)
    case("raise_signal str", lambda: signal.raise_signal("n"))
    case("alarm str", lambda: signal.alarm("s"))
    case("strsignal str", lambda: signal.strsignal("n"))
    case("setitimer one arg", lambda: signal.setitimer(signal.ITIMER_REAL))
    case("setitimer seconds str", lambda: signal.setitimer(signal.ITIMER_REAL, "s"))
    case("setitimer interval str", lambda: signal.setitimer(signal.ITIMER_REAL, 0, "i"))
    case("setitimer which str", lambda: signal.setitimer("w", 0))
    case("setitimer bad which", lambda: signal.setitimer(9999, 0))
    case("getitimer str", lambda: signal.getitimer("w"))
    case("getitimer bad which", lambda: signal.getitimer(9999))
    case("default_int_handler", lambda: signal.default_int_handler(signal.SIGINT, None))

    # A fork hook that raises is reported as unraisable and dropped; fork()
    # still answers, and nothing is left pending behind it.
    print("-- fork hook")
    armed = [True]
    seen = []

    def hook():
        if armed[0]:
            raise ValueError("from the fork hook")

    old_hook = sys.unraisablehook
    sys.unraisablehook = lambda u: seen.append(type(u.exc_value).__name__)
    os.register_at_fork(before=hook)
    try:
        pid = os.fork()
        if pid == 0:
            os._exit(0)
        os.waitpid(pid, 0)
        print("fork answered:", pid > 0)
    except Exception as e:
        print("fork raised:", type(e).__name__)
    finally:
        armed[0] = False
        sys.unraisablehook = old_hook
    print("unraisable:", seen)
    print("nothing pending:", sys.exc_info()[0] is None, len("abc"), int("7"))
finally:
    os.chdir("/")
    shutil.rmtree(work, ignore_errors=True)
print("done")
