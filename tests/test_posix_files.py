# posix's write side: a temporary tree built, walked, renamed and removed.
#
# The read-only calls are covered in test_posix.py; this one is about the
# calls that change something, and about their errors being the right OSError
# subclass with the right filename attached.
#
# Everything happens under a directory named for the pid, so the two
# interpreters this is diffed against never collide, and nothing printed
# depends on the name.

import posix

root = "/tmp/apython-posix-test-%d" % posix.getpid()


def cleanup(path):
    """Remove a tree, tolerating anything already gone."""
    try:
        names = posix.listdir(path)
    except OSError:
        try:
            posix.unlink(path)
        except OSError:
            pass
        return
    for n in names:
        cleanup(path + "/" + n)
    try:
        posix.rmdir(path)
    except OSError:
        pass


cleanup(root)

print("--- mkdir ---")
posix.mkdir(root)
print("exists     :", posix.access(root, posix.F_OK))
print("is a dir   :", posix.stat(root).st_mode & 0o170000 == 0o040000)
print("empty      :", posix.listdir(root))

try:
    posix.mkdir(root)
    print("twice      : accepted?!")
except FileExistsError as e:
    print("twice      : FileExistsError", e.filename == root)

print()
print("--- open, write, read, close ---")
path = root + "/hello.txt"
fd = posix.open(path, posix.O_WRONLY | posix.O_CREAT | posix.O_TRUNC, 0o644)
n = posix.write(fd, b"hello, world\n")
print("written    :", n)
posix.close(fd)
print("size       :", posix.stat(path).st_size)
print("mode       :", oct(posix.stat(path).st_mode & 0o777))

fd = posix.open(path, posix.O_RDONLY)
data = posix.read(fd, 100)
print("read back  :", data)
print("at eof     :", posix.read(fd, 100))
print("rewound    :", posix.lseek(fd, 0, 0))
print("first five :", posix.read(fd, 5))
print("seek 7     :", posix.lseek(fd, 7, 0), posix.read(fd, 5))
print("from end   :", posix.lseek(fd, -1, 2), posix.read(fd, 1))
posix.close(fd)

print()
print("--- append, and O_EXCL ---")
fd = posix.open(path, posix.O_WRONLY | posix.O_APPEND)
posix.write(fd, b"second line\n")
posix.close(fd)
fd = posix.open(path, posix.O_RDONLY)
print("appended   :", posix.read(fd, 200))
posix.close(fd)

try:
    posix.open(path, posix.O_WRONLY | posix.O_CREAT | posix.O_EXCL, 0o644)
    print("O_EXCL     : accepted?!")
except FileExistsError as e:
    print("O_EXCL     : FileExistsError", e.filename == path)

print()
print("--- chmod ---")
posix.chmod(path, 0o600)
print("after chmod:", oct(posix.stat(path).st_mode & 0o777))
posix.chmod(path, 0o644)
print("restored   :", oct(posix.stat(path).st_mode & 0o777))

print()
print("--- listdir sees it, and sees a crowd ---")
print("one file   :", posix.listdir(root))
for i in range(50):
    fd = posix.open(root + "/f%02d" % i, posix.O_WRONLY | posix.O_CREAT, 0o644)
    posix.write(fd, b"x" * i)
    posix.close(fd)
names = posix.listdir(root)
print("count      :", len(names))
print("unique     :", len(set(names)) == len(names))
print("all there  :", all(("f%02d" % i) in names for i in range(50)))
print("sizes      :", [posix.stat(root + "/f%02d" % i).st_size
                       for i in (0, 1, 7, 49)])

print()
print("--- rename and replace ---")
posix.rename(path, root + "/renamed.txt")
print("gone       :", not posix.access(path, posix.F_OK))
print("arrived    :", posix.access(root + "/renamed.txt", posix.F_OK))
print("contents   :", posix.stat(root + "/renamed.txt").st_size > 0)

fd = posix.open(root + "/target.txt", posix.O_WRONLY | posix.O_CREAT, 0o644)
posix.write(fd, b"replaced")
posix.close(fd)
posix.replace(root + "/renamed.txt", root + "/target.txt")
print("replaced   :", not posix.access(root + "/renamed.txt", posix.F_OK))
fd = posix.open(root + "/target.txt", posix.O_RDONLY)
print("survivor   :", posix.read(fd, 100)[:5])
posix.close(fd)

print()
print("--- nested directories ---")
posix.mkdir(root + "/sub")
posix.mkdir(root + "/sub/deeper")
fd = posix.open(root + "/sub/deeper/leaf", posix.O_WRONLY | posix.O_CREAT, 0o644)
posix.write(fd, b"leaf")
posix.close(fd)
print("nested     :", posix.listdir(root + "/sub"),
      posix.listdir(root + "/sub/deeper"))
print("stat leaf  :", posix.stat(root + "/sub/deeper/leaf").st_size)

try:
    posix.rmdir(root + "/sub")
    print("non-empty  : accepted?!")
except OSError as e:
    print("non-empty  :", type(e).__name__)

print()
print("--- unlink and rmdir ---")
posix.unlink(root + "/sub/deeper/leaf")
posix.rmdir(root + "/sub/deeper")
posix.rmdir(root + "/sub")
print("sub gone   :", not posix.access(root + "/sub", posix.F_OK))

try:
    posix.unlink(root + "/sub")
    print("twice      : accepted?!")
except FileNotFoundError as e:
    print("twice      : FileNotFoundError", e.filename == root + "/sub")

try:
    posix.rmdir(root + "/target.txt")
    print("rmdir file : accepted?!")
except OSError as e:
    print("rmdir file :", type(e).__name__)

try:
    posix.unlink(root)
    print("unlink dir : accepted?!")
except OSError as e:
    print("unlink dir :", type(e).__name__)

print()
print("--- pipe, which is the only call returning a pair ---")
r, w = posix.pipe()
print("types      :", type(r).__name__, type(w).__name__)
print("distinct   :", r != w, r >= 0, w >= 0)
posix.write(w, b"through the pipe")
print("read       :", posix.read(r, 100))
posix.close(r)
posix.close(w)

print()
print("--- change only the blocking mode of a pipe ---")
r, w = posix.pipe()


class PipeEnd:
    def __index__(self):
        return r


try:
    print("initial    :", posix.get_blocking(r))
    print("set returns:", posix.set_blocking(PipeEnd(), []))
    print("read/write :", posix.get_blocking(r), posix.get_blocking(w))
    posix.set_blocking(r, [1])
    print("restored   :", posix.get_blocking(r))
    for bad_fd in (-1, 1 << 100):
        try:
            posix.set_blocking(bad_fd, False)
        except (OSError, OverflowError) as error:
            print("bad fd     :", type(error).__name__)
finally:
    posix.close(r)
    posix.close(w)

print()
print("--- umask, restored immediately ---")
old = posix.umask(0o077)
print("type       :", type(old).__name__)
back = posix.umask(old)
print("round trip :", back == 0o077)

print()
print("--- clean up, and prove it ---")
cleanup(root)
print("root gone  :", not posix.access(root, posix.F_OK))
try:
    posix.listdir(root)
    print("listdir    : accepted?!")
except FileNotFoundError:
    print("listdir    : FileNotFoundError")
