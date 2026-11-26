import errno
import os
import secrets

from _posixshmem import shm_open, shm_unlink


name = "/apython-test-" + secrets.token_hex(12)
flags = os.O_CREAT | os.O_EXCL | os.O_RDWR
fd = shm_open(path=name, flags=flags, mode=0o600)
try:
    assert not os.get_inheritable(fd)
    os.ftruncate(fd, 4)
    assert os.write(fd, b"data") == 4
    reader = shm_open(name, os.O_RDONLY)
    try:
        assert os.read(reader, 4) == b"data"
    finally:
        os.close(reader)
    try:
        shm_open(name, flags)
    except FileExistsError as exc:
        assert exc.errno == errno.EEXIST and exc.filename == name
    else:
        raise AssertionError("exclusive creation must fail")
finally:
    try:
        shm_unlink(path=name)
    finally:
        os.close(fd)

try:
    shm_open(name, os.O_RDONLY)
except FileNotFoundError as exc:
    assert exc.errno == errno.ENOENT and exc.filename == name
else:
    raise AssertionError("unlinked name must be gone")

for bad_name, error in ((name.encode(), TypeError), (name + "\0x", ValueError)):
    try:
        shm_unlink(bad_name)
    except error:
        pass
    else:
        raise AssertionError("invalid name accepted")
