"""A .pyc whose source has been edited since must not be used.

A .pyc records the source's mtime and size in its header, and CPython refuses
one that no longer matches.  Without that check, editing a module and running
it again silently runs the old code -- which is what happened here, and what
makes the compiled `stdlib/` a trap rather than a cache the moment one of its
sources is touched by hand.

The cache this needs is built by copying one that already exists rather than
by importing: what is under test is the CHECK, and a cache this interpreter
wrote would agree with its source by construction.  Aligning the copy's mtime
with the header makes the pair agree; appending a line to the source makes
them disagree in both the size and the mtime, which is the case the check is
for.
"""

import os
import sys

SRC = os.path.join("stdlib", "stat.py")
CACHE = os.path.join("stdlib", "__pycache__", "stat.cpython-312.pyc")

root = "_staletree"
cachedir = os.path.join(root, "__pycache__")
for d in (root, cachedir):
    try:
        os.mkdir(d)
    except FileExistsError:
        pass
sys.path.insert(0, root)

target_src = os.path.join(root, "stalemod.py")
target_cache = os.path.join(cachedir, "stalemod.cpython-312.pyc")


def copy(a, b):
    with open(a, "rb") as fh:
        data = fh.read()
    with open(b, "wb") as fh:
        fh.write(data)
    return data


source_text = copy(SRC, target_src)
header = copy(CACHE, target_cache)[:16]
recorded_mtime = (header[8] | (header[9] << 8) | (header[10] << 16)
                  | (header[11] << 24))
recorded_size = (header[12] | (header[13] << 8) | (header[14] << 16)
                 | (header[15] << 24))

print("--- the pair agrees, so the cache is used ---")
os.utime(target_src, (recorded_mtime, recorded_mtime))
print(os.stat(target_src).st_size == recorded_size)
import stalemod

print(stalemod.S_IFDIR, stalemod.S_IFREG)
print(hasattr(stalemod, "MARKER"))

print("--- now the source is edited, and the cache is one behind ---")
with open(target_src, "a") as fh:
    fh.write('\nMARKER = "compiled from source"\n')
os.utime(target_src, (recorded_mtime + 100, recorded_mtime + 100))
del sys.modules["stalemod"]
import stalemod as edited

print(edited.S_IFDIR, edited.S_IFREG)
print(edited.MARKER)

print("--- and putting the pair back in step restores the cache ---")
copy(SRC, target_src)
os.utime(target_src, (recorded_mtime, recorded_mtime))
del sys.modules["stalemod"]
import stalemod as restored

print(restored.S_IFDIR, hasattr(restored, "MARKER"))

# Everything in the cache directory, not just the file this test wrote: an
# import through apython leaves its own tag's entry beside it.
for _name in sorted(os.listdir(cachedir)):
    os.unlink(os.path.join(cachedir, _name))
os.unlink(target_src)
os.rmdir(cachedir)
os.rmdir(root)
print("done")
