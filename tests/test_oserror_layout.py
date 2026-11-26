import gc
import weakref


class Shadow(OSError):
    errno = 22


class Slotted(OSError):
    __slots__ = ("filename", "marker")


class WithProperty(OSError):
    @property
    def errno(self):
        return self.code

    @errno.setter
    def errno(self, value):
        self.code = value

    @errno.deleter
    def errno(self):
        del self.code


class Payload:
    pass


base_errno = OSError.errno
base_filename = OSError.filename
assert base_errno.__objclass__ is OSError
for cls in (OSError, BlockingIOError, ConnectionError, ConnectionResetError,
            FileNotFoundError, PermissionError, TimeoutError):
    e = cls()
    assert (e.errno, e.strerror, e.filename, e.filename2) == (None,) * 4
    del e.errno
    e.errno = 10
    assert base_errno.__get__(e) == 10
    base_errno.__delete__(e)
    assert e.errno is None
    assert vars(e) == {}
assert not hasattr(ValueError(), "errno")

e = Shadow(2, "missing", "name")
assert vars(e) == {}
assert e.errno == 22
assert base_errno.__get__(e) == 2
assert str(e) == "[Errno 2] missing: 'name'"
e.errno = 25
assert e.errno == 25 and vars(e) == {"errno": 25}
del e.errno
assert e.errno == 22

e = WithProperty(2, "missing")
e.errno = 30
assert e.errno == 30 and base_errno.__get__(e) == 2
del e.errno
assert not hasattr(e, "errno")

e = Slotted(2, "missing", "original")
assert not hasattr(e, "filename")
e.filename = "slot"
assert e.filename == "slot" and base_filename.__get__(e) == "original"
assert vars(e) == {}
del e.filename
assert not hasattr(e, "filename")

e = OSError(2, "missing", "before", None, "after")
assert e.__reduce__() == (FileNotFoundError, (2, "missing", "before", None, "after"))
vars(e)["errno"] = 45
assert e.errno == 2
assert e.__reduce__()[2] is vars(e)
assert e.__reduce__()[2] == {"errno": 45}
e.filename = None
assert str(e) == "[Errno 2] missing: None -> 'after'"
del e.filename
assert str(e) == "[Errno 2] missing"
e.strerror = "é" * 4096
assert str(e) == "[Errno 2] " + "é" * 4096

e = Slotted()
p = Payload()
ref = weakref.ref(p)
base_filename.__set__(e, p)
e.marker = p
p.error = e
del p, e
gc.collect()
assert ref() is None

print("OSError native fields OK")
