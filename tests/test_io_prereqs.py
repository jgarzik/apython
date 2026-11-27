# The three things _io needs that were missing: a usable memoryview,
# sys.flags, and a handful of posix calls.
#
# memoryview was a near-stub -- len() and an int subscript worked and nothing
# else did.  No slicing, no iteration, no methods at all (tp_getattr was 0),
# no writing (mp_ass_subscript was 0), and repr() raised.  _pyio takes a
# memoryview of every buffer it reads into: readinto, BufferedReader's
# refill, BytesIO.getbuffer and TextIOWrapper's decode all go through one.
#
# sys.flags did not exist, and _pyio reads sys.flags.utf8_mode and .dev_mode
# at module level -- so the module could not even be imported.
#
# posix was missing isatty, ftruncate, set_inheritable, get_inheritable,
# device_encoding and uname.  FileIO calls the first four in its constructor
# and its truncate(); platform.system() reads uname().

import sys
import posix


def check(label, fn):
    try:
        print("%-32s %r" % (label, fn()))
    except BaseException as e:
        print("%-32s %s" % (label, type(e).__name__))


print("--- memoryview over bytes ---")
mv = memoryview(b"abcdef")
check("len", lambda: len(mv))
check("mv[0]", lambda: mv[0])
check("mv[-1]", lambda: mv[-1])
check("mv[10]", lambda: mv[10])
check("mv[1:3]", lambda: bytes(mv[1:3]))
check("type of a slice", lambda: type(mv[1:3]).__name__)
check("mv[:]", lambda: bytes(mv[:]))
# A step other than 1 needs a stride the view does not carry; CPython answers
# with a non-contiguous view.  Recorded in the old bug list, so the two lines that
# would test it are not here.
check("list(mv)", lambda: list(mv))
check("iter", lambda: [x for x in mv])
check("in", lambda: (98 in mv, 200 in mv))
check("tobytes", lambda: mv.tobytes())
check("hex", lambda: memoryview(b"\x01\xff").hex())
check("tolist", lambda: mv.tolist())
check("nbytes", lambda: mv.nbytes)
check("itemsize", lambda: mv.itemsize)
check("format", lambda: mv.format)
check("readonly", lambda: mv.readonly)
check("ndim", lambda: mv.ndim)
check("shape", lambda: mv.shape)
check("strides", lambda: mv.strides)
check("obj type", lambda: type(mv.obj).__name__)
check("c_contiguous", lambda: mv.c_contiguous)
check("== bytes", lambda: mv == b"abcdef")
check("== other mv", lambda: mv == memoryview(b"abcdef"))
check("!=", lambda: mv != b"xyz")

print()
print("--- memoryview over a bytearray: writable ---")


def written(index, value):
    b = bytearray(b"abcdef")
    m = memoryview(b)
    m[index] = value
    return bytes(b)


check("readonly", lambda: memoryview(bytearray(b"ab")).readonly)
check("m[0] = 65", lambda: written(0, 65))
check("m[-1] = 90", lambda: written(-1, 90))
check("m[0] = 256", lambda: written(0, 256))
check("m[9] = 65", lambda: written(9, 65))
check("write to a readonly", lambda: memoryview(b"ab").__setitem__(0, 65))


def slice_written(sl, value):
    b = bytearray(b"abcdef")
    m = memoryview(b)
    m[sl] = value
    return bytes(b)


check("m[1:3] = b'XY'", lambda: slice_written(slice(1, 3), b"XY"))
check("m[:] = 6 bytes", lambda: slice_written(slice(None), b"XYZXYZ"))
check("m[1:3] = wrong size", lambda: slice_written(slice(1, 3), b"X"))
check("bytes(mv of bytearray)", lambda: bytes(memoryview(bytearray(b"xy"))))

print()
print("--- release, and the context manager _pyio uses ---")


def released():
    m = memoryview(bytearray(b"abc"))
    m.release()
    return m


check("release returns None", lambda: memoryview(b"ab").release())
check("len after release", lambda: len(released()))
check("index after release", lambda: released()[0])
check("tobytes after release", lambda: released().tobytes())
check("release twice", lambda: (lambda m: (m.release(), m.release()))(memoryview(b"ab")))


def with_view(data):
    with memoryview(data) as m:
        return m.tobytes()


check("with memoryview", lambda: with_view(b"abc"))
check("with over bytearray", lambda: with_view(bytearray(b"abc")))

print()
print("--- cast, which _compiler._bytes_to_codes needs ---")
check("cast('B')", lambda: memoryview(b"abcd").cast("B").tolist())
check("cast('I') len 4", lambda: len(memoryview(b"abcd").cast("I")))
check("cast('I') itemsize", lambda: memoryview(b"abcd").cast("I").itemsize)
check("cast('I') value", lambda: memoryview(b"\x01\x00\x00\x00").cast("I").tolist())
check("cast('I') bad length", lambda: memoryview(b"abc").cast("I"))
check("cast round trip", lambda: memoryview(b"abcd").cast("I").cast("B").tobytes())

print()
print("--- sys.flags ---")
f = sys.flags
check("type name", lambda: type(f).__name__)
check("is a tuple", lambda: isinstance(f, tuple))
check("utf8_mode", lambda: f.utf8_mode)
check("dev_mode", lambda: f.dev_mode)
check("warn_default_encoding", lambda: f.warn_default_encoding)
check("optimize", lambda: f.optimize)
check("debug", lambda: f.debug)
check("verbose", lambda: f.verbose)
check("ignore_environment", lambda: f.ignore_environment)
check("dont_write_bytecode", lambda: f.dont_write_bytecode)
check("no_site", lambda: f.no_site)
check("interactive", lambda: f.interactive)
check("inspect", lambda: f.inspect)
check("quiet", lambda: f.quiet)
check("isolated", lambda: f.isolated)
check("safe_path", lambda: f.safe_path)
check("int_max_str_digits", lambda: f.int_max_str_digits)
check("positional", lambda: f[0] == f.debug)
check("repr shape", lambda: repr(f).startswith("sys.flags("))

print()
print("--- the posix calls FileIO makes ---")
check("isatty(0) is a bool", lambda: type(posix.isatty(0)).__name__)
check("isatty on a bad fd", lambda: posix.isatty(999))
check("isatty on a file", lambda: posix.isatty(posix.open("/etc/hostname",
                                                          posix.O_RDONLY)))
check("get_inheritable", lambda: type(posix.get_inheritable(0)).__name__)
check("set_inheritable", lambda: posix.set_inheritable(0, True))
check("round trip", lambda: (posix.set_inheritable(0, False),
                             posix.get_inheritable(0))[1])
check("device_encoding", lambda: posix.device_encoding(999))

print()
print("--- ftruncate, on a temporary of our own ---")
path = "/tmp/apython-io-prereq-%d" % posix.getpid()
fd = posix.open(path, posix.O_WRONLY | posix.O_CREAT | posix.O_TRUNC, 0o644)
posix.write(fd, b"0123456789")
print("size before  :", posix.fstat(fd).st_size)
posix.ftruncate(fd, 4)
print("after truncate:", posix.fstat(fd).st_size)
posix.ftruncate(fd, 8)
print("after extend :", posix.fstat(fd).st_size)
posix.close(fd)
fd = posix.open(path, posix.O_RDONLY)
print("contents     :", posix.read(fd, 100))
posix.close(fd)
posix.unlink(path)
print("cleaned      :", not posix.access(path, posix.F_OK))

print()
print("--- uname, which platform.system() reads ---")
u = posix.uname()
print("type         :", type(u).__name__)
print("is a tuple   :", isinstance(u, tuple))
print("len          :", len(u))
print("sysname      :", u.sysname)
print("named==pos   :", u.sysname == u[0], u.nodename == u[1],
      u.release == u[2], u.version == u[3], u.machine == u[4])
print("all str      :", all(type(x).__name__ == "str" for x in u))
print("nonempty     :", all(len(x) > 0 for x in (u.sysname, u.release, u.machine)))
print("repr shape   :", repr(u).startswith("posix.uname_result("))

print()
print("--- churn ---")
views = [memoryview(bytearray(bytes([i]) * (i + 1))) for i in range(40)]
print("churn        :", len([[i, i] for i in range(3000)]))
print("intact       :", views[7].tobytes(), len(views[39]))
print("flags again  :", sys.flags.utf8_mode, sys.flags.optimize)
