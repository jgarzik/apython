# A bytes path yields bytes names, as CPython's does.
#
# posix_path_arg hands back a C string and discards whether the argument was a
# str or a bytes, so every consumer built str: os.scandir(b'.') gave str .name
# and .path, os.listdir(b'.') gave str entries, and os.readlink on a bytes path
# gave a str.  os.walk(b'.') and the bytes half of glob propagate all three.
#
# The old bug list recorded only scandir; listdir and readlink are the same defect in the
# same function.
#
# Written against `posix` directly, like tests/test_posix_scandir.py, so it says
# the same thing on either interpreter -- and everything is sorted, because a
# directory has no order of its own.

import posix

BASE = "@bytespath_probe"


def cleanup():
    for name in ("d/inner.txt", "f.txt", "link", "d"):
        p = BASE + "/" + name
        try:
            posix.unlink(p)
        except OSError:
            try:
                posix.rmdir(p)
            except OSError:
                pass
    try:
        posix.rmdir(BASE)
    except OSError:
        pass


cleanup()
posix.mkdir(BASE)
posix.mkdir(BASE + "/d")
fd = posix.open(BASE + "/f.txt", posix.O_WRONLY | posix.O_CREAT, 0o644)
posix.write(fd, b"hello")
posix.close(fd)
fd = posix.open(BASE + "/d/inner.txt", posix.O_WRONLY | posix.O_CREAT, 0o644)
posix.close(fd)
posix.symlink("f.txt", BASE + "/link")

BB = BASE.encode()

print("--- listdir ---")
print("str   :", sorted(posix.listdir(BASE)))
print("bytes :", sorted(posix.listdir(BB)))
print("types :", sorted({type(x).__name__ for x in posix.listdir(BB)}))
print("str types:", sorted({type(x).__name__ for x in posix.listdir(BASE)}))

print("--- scandir name/path types ---")
for arg, label in ((BASE, "str"), (BB, "bytes")):
    entries = sorted(posix.scandir(arg), key=lambda e: e.name)
    print(label, "names:", [e.name for e in entries])
    print(label, "paths:", [e.path for e in entries])
    print(label, "name types:", sorted({type(e.name).__name__ for e in entries}))
    print(label, "path types:", sorted({type(e.path).__name__ for e in entries}))

print("--- the four that read the field ---")
entries = sorted(posix.scandir(BB), key=lambda e: e.name)
for e in entries:
    # stat() goes through de_path; a bytes path read at a str's data offset is
    # sixteen bytes past the start of the object.
    st = e.stat(follow_symlinks=False)
    print(repr(e.name), "is_dir:", e.is_dir(), "is_file:", e.is_file(),
          "is_link:", e.is_symlink(), "inode:", e.inode() == st.st_ino)
    print("  fspath:", repr(e.__fspath__()), type(e.__fspath__()).__name__)
    print("  repr has name:", repr(e.name).strip("b'\"") in repr(e))

print("--- readlink ---")
print("str   :", repr(posix.readlink(BASE + "/link")))
print("bytes :", repr(posix.readlink(BB + b"/link")))

print("--- a trailing separator must not double up ---")
for arg in (BASE + "/", BB + b"/"):
    paths = sorted(e.path for e in posix.scandir(arg))
    print(type(arg).__name__, paths)

print("--- os.walk over a bytes root ---")
import os

for root, dirs, files in sorted(os.walk(BB)):
    print(repr(root), sorted(dirs), sorted(files))

print("--- and a str root, unchanged ---")
for root, dirs, files in sorted(os.walk(BASE)):
    print(repr(root), sorted(dirs), sorted(files))

cleanup()
print("done")
