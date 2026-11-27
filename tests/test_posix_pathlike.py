"""os.PathLike arguments, and the path they leave behind.

posix_path_arg resolves str, bytes and anything with __fspath__.  The first
two hand back a pointer into the caller's own object and own nothing; the
third builds a new str, and its contract said so in a flag that none of its
eleven callers read.  Every PathLike argument leaked its resolved path.

The release belongs immediately after the syscall and before the errno
check: by then the kernel has copied the path out, and a raise abandons the
C stack without running anything placed after it.
"""

import posix

TMP = "/tmp/apython_pathlike"
TMP2 = "/tmp/apython_pathlike2"


class P:
    """The smallest os.PathLike there is."""

    def __init__(self, s):
        self._s = s

    def __fspath__(self):
        # A fresh string every time, so nothing is shared with the caller and
        # a missing release shows up as a leak rather than as a live object.
        return "".join(self._s)


class PBytes:
    def __fspath__(self):
        return b"".join([TMP.encode()])


class Bad:
    def __fspath__(self):
        return 5


class Raises:
    def __fspath__(self):
        raise RuntimeError("from __fspath__")


def check(label, fn):
    try:
        got = fn()
    except Exception as exc:
        got = type(exc).__name__ + ": " + str(exc)
    print(label.ljust(34), repr(got))


def type_name(fn):
    try:
        fn()
    except Exception as exc:
        return type(exc).__name__
    return "no error"


def type_and_path(fn):
    try:
        fn()
    except Exception as exc:
        return type(exc).__name__, TMP + "_nope" in str(exc)
    return "no error"


def cleanup(*names):
    for n in names:
        try:
            posix.unlink(n)
        except OSError:
            pass


cleanup(TMP, TMP2)

# --- every call that takes a path takes a PathLike ---
fd = posix.open(P(TMP), 0o101, 0o644)          # O_WRONLY | O_CREAT
posix.write(fd, b"hello")
posix.close(fd)
check("open and write", lambda: posix.stat(P(TMP)).st_size)
check("stat", lambda: posix.stat(P(TMP)).st_size)
check("lstat", lambda: posix.lstat(P(TMP)).st_size)
check("access", lambda: posix.access(P(TMP), 0))
check("chmod", lambda: posix.chmod(P(TMP), 0o644))
check("rename", lambda: (posix.rename(P(TMP), P(TMP2)),
                         posix.access(TMP2, 0)))
check("rename back", lambda: (posix.rename(P(TMP2), P(TMP)),
                              posix.access(TMP, 0)))
check("listdir", lambda: type(posix.listdir(P("/tmp"))).__name__)
check("a bytes PathLike", lambda: posix.stat(PBytes()).st_size)
check("unlink", lambda: (posix.unlink(P(TMP)), posix.access(TMP, 0)))
check("mkdir and rmdir", lambda: (posix.mkdir(P(TMP), 0o755),
                                  posix.rmdir(P(TMP))))

# --- and the error paths, which are where a release is easiest to lose ---
check("stat a missing PathLike", lambda: posix.stat(P(TMP + "_nope")))
check("unlink a missing one", lambda: posix.unlink(P(TMP + "_nope")))
check("listdir a missing one", lambda: posix.listdir(P(TMP + "_nope")))
check("listdir a file", lambda: posix.listdir(P("/etc/hostname")))
# Two message shapes differ from CPython's and have nothing to do with the
# release: rename names only one of its two paths, and the "not a path"
# message carries no function-name prefix.  The old bug list recorded both; what
# matters here is the type and that the resolved path reaches the message.
check("rename a missing one", lambda: type_and_path(
    lambda: posix.rename(P(TMP + "_nope"), P(TMP2))))
check("open a missing one", lambda: posix.open(P(TMP + "_nope"), 0))
check("__fspath__ returns an int", lambda: posix.stat(Bad()))
check("__fspath__ raises", lambda: posix.stat(Raises()))
# The type only: CPython 3.12 changed this message mid-series, and the suite
# diffs against whichever python3 is installed.
check("an embedded NUL", lambda: type_name(lambda: posix.stat(P("/tmp/a\0b"))))
check("not a path at all", lambda: type_name(lambda: posix.stat(5.5)))

# --- the plain kinds still work ---
open(TMP, "w").close()
check("a str", lambda: posix.access(TMP, 0))
check("bytes", lambda: posix.access(TMP.encode(), 0))
cleanup(TMP, TMP2)

# Many of them, so a leak of one object per call is visible as growth.
for _ in range(3000):
    try:
        posix.stat(P(TMP + "_nope"))
    except OSError:
        pass
    try:
        posix.listdir(P(TMP + "_nope"))
    except OSError:
        pass
print("churned".ljust(34), repr(True))
