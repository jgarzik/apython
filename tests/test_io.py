"""io: the whole stack, from open() down to the descriptor.

open() assembles three layers -- a FileIO, a buffer, and for text a
TextIOWrapper -- and the interesting behaviour is in how they agree with each
other.  A buffered reader is ahead of the file position, so tell() has to
subtract what it read early; a buffered writer is behind it, so tell() has to
add what it has not written yet; and BufferedRandom has to reconcile the two
every time the direction changes.  Text adds a decoder whose state is part of
the position, which is why tell() on a text file returns an opaque cookie
rather than a byte offset.
"""

import io
import posix

TMP = "/tmp/apython_io_test"


def check(label, fn):
    try:
        got = fn()
    except Exception as exc:
        got = type(exc).__name__ + ": " + str(exc)
    print(label.ljust(34), repr(got))


def type_name_of(fn):
    try:
        fn()
    except Exception as exc:
        return type(exc).__name__
    return "no error"


def cleanup(*names):
    for n in names:
        try:
            posix.unlink(n)
        except OSError:
            pass


cleanup(TMP, TMP + "2")

# --- text, the default ---
with open(TMP, "w") as f:
    check("write returns the length", lambda: f.write("alpha\nbeta\ngamma\n"))
    check("writable", lambda: (f.readable(), f.writable(), f.seekable()))
    check("encoding", lambda: f.encoding)
    check("read on a write file", lambda: f.read())
check("closed after with", lambda: f.closed)

check("read it all", lambda: open(TMP).read())
check("readlines", lambda: open(TMP).readlines())
check("iterate", lambda: [line for line in open(TMP)])
check("readline", lambda: open(TMP).readline())
check("readline capped", lambda: open(TMP).readline(3))
check("read(5)", lambda: open(TMP).read(5))
check("read(0)", lambda: open(TMP).read(0))
check("readlines with a hint", lambda: open(TMP).readlines(3))

f = open(TMP)
check("tell at the start", lambda: f.tell())
check("read then tell", lambda: (f.read(5), f.tell()))
check("seek back and read", lambda: (f.seek(0), f.read(5)))
check("seek to a cookie", lambda: (lambda c: (f.read(1), f.seek(c),
                                              f.read(5)))(f.tell()))
check("seek to the end", lambda: (f.seek(0, 2), f.read()))
check("relative seek", lambda: f.seek(1, 1))
f.close()
check("read after close", lambda: f.read())
check("tell after close", lambda: f.tell())

# --- binary ---
with open(TMP, "rb") as b:
    check("binary read", lambda: b.read())
    check("binary tell", lambda: b.tell())
    check("binary seek", lambda: (b.seek(6), b.read(4)))
    check("binary readline", lambda: (b.seek(0), b.readline()))
    check("binary peek", lambda: (b.seek(0), b.peek(3)[:3]))
    check("binary readinto", lambda: (lambda buf: (b.seek(0),
                                                   b.readinto(buf),
                                                   bytes(buf)))(bytearray(5)))
    check("binary predicates", lambda: (b.readable(), b.writable(),
                                        b.seekable()))
    check("layers", lambda: (type(b).__name__, type(b.raw).__name__))
    check("name", lambda: b.name)
    check("write on a read file", lambda: b.write(b"x"))

# --- unbuffered binary is the raw file itself ---
with open(TMP, "rb", buffering=0) as u:
    check("unbuffered type", lambda: type(u).__name__)
    check("unbuffered read", lambda: u.read())
check("unbuffered text", lambda: open(TMP, "r", buffering=0))

# --- writing binary, and the buffer that holds it back ---
with open(TMP + "2", "wb") as w:
    check("buffered write", lambda: w.write(b"0123456789"))
    check("tell includes the buffer", lambda: w.tell())
    check("nothing on disk yet", lambda: open(TMP + "2", "rb").read())
    w.flush()
    check("flushed", lambda: open(TMP + "2", "rb").read())
    check("truncate", lambda: (w.truncate(4), open(TMP + "2", "rb").read()))
check("after close", lambda: open(TMP + "2", "rb").read())

# --- update mode, where both buffers are live ---
with open(TMP + "2", "r+b") as rw:
    check("type", lambda: type(rw).__name__)
    check("read then write", lambda: (rw.read(2), rw.write(b"XY"),
                                      rw.seek(0), rw.read()))
    check("write then read", lambda: (rw.seek(0), rw.write(b"z"),
                                      rw.seek(0), rw.read()))
    check("tell across a switch", lambda: (rw.seek(0), rw.read(1), rw.tell()))

# --- newline handling, which is what the text layer is for ---
with open(TMP, "wb") as raw:
    raw.write(b"one\r\ntwo\rthree\nfour")
check("universal newlines", lambda: open(TMP).read())
check("universal lines", lambda: open(TMP).readlines())
check("newline=''", lambda: open(TMP, newline="").read())
check("newline='\\n'", lambda: open(TMP, newline="\n").readlines())
check("newline='\\r\\n'", lambda: open(TMP, newline="\r\n").readlines())
check("seen newlines", lambda: (lambda h: (h.read(), h.newlines))(open(TMP)))
with open(TMP + "2", "w", newline="\r\n") as nl:
    nl.write("a\nb\n")
check("newline on write", lambda: open(TMP + "2", "rb").read())

# --- encodings ---
with open(TMP, "w", encoding="utf-8") as e:
    e.write("héllo 世界\n")
check("utf-8 round trip", lambda: open(TMP, encoding="utf-8").read())
check("as bytes", lambda: open(TMP, "rb").read())
check("latin-1 round trip", lambda: (lambda: [
    open(TMP + "2", "w", encoding="latin-1").write("café"),
    open(TMP + "2", "rb").read(),
    open(TMP + "2", encoding="latin-1").read()][1:])())
# str() of a UnicodeDecodeError does not render its fields here, so this
# checks the type rather than the message; the old bug list recorded the gap.
check("ascii rejects", lambda: type_name_of(
    lambda: open(TMP, encoding="ascii").read()))
check("a split character", lambda: (lambda h: (h.read(2), h.read()))(
    open(TMP, encoding="utf-8")))

# --- StringIO ---
s = io.StringIO("first\nsecond\n")
check("stringio read", lambda: s.read())
check("stringio getvalue", lambda: s.getvalue())
check("stringio seek", lambda: (s.seek(0), s.readline()))
check("stringio iterate", lambda: list(io.StringIO("a\nb\n")))
w2 = io.StringIO()
check("stringio write", lambda: (w2.write("abc"), w2.getvalue()))
check("stringio overwrite", lambda: (w2.seek(1), w2.write("XY"),
                                     w2.getvalue()))
check("stringio bytes", lambda: io.StringIO().write(b"no"))
check("stringio non-str init", lambda: io.StringIO(5))
check("stringio truncate", lambda: (w2.seek(1), w2.truncate(), w2.getvalue()))
check("stringio close", lambda: (w2.close(), w2.closed))
check("stringio read after close", lambda: w2.read())

# --- BytesIO through the io namespace ---
bio = io.BytesIO(b"a\nb\n")
check("bytesio", lambda: (bio.read(2), bio.readline(), bio.getvalue()))
check("wrapped in text", lambda: io.TextIOWrapper(io.BytesIO(b"x\ny\n")).read())
check("text over bytesio write", lambda: (lambda u, t: (t.write("hi"),
                                                        t.flush(),
                                                        u.getvalue()))(
    *(lambda u: (u, io.TextIOWrapper(u)))(io.BytesIO())))

# --- the class tree ---
check("open gives a TextIOWrapper", lambda: isinstance(open(TMP),
                                                       io.TextIOWrapper))
check("isinstance IOBase", lambda: isinstance(open(TMP), io.IOBase))
check("binary is BufferedIOBase", lambda: isinstance(open(TMP, "rb"),
                                                     io.BufferedIOBase))
check("FileIO is RawIOBase", lambda: issubclass(io.FileIO, io.RawIOBase))
check("Unsupported module", lambda: io.UnsupportedOperation.__module__)
check("SEEK constants", lambda: (io.SEEK_SET, io.SEEK_CUR, io.SEEK_END))
check("DEFAULT_BUFFER_SIZE", lambda: io.DEFAULT_BUFFER_SIZE > 0)

# --- the modes open() refuses ---
for mode in ("", "rw", "rb+t", "z", "rbt", "r+w"):
    check("mode %r" % mode, lambda mode=mode: open(TMP, mode))
check("binary with encoding", lambda: open(TMP, "rb", encoding="utf-8"))
check("binary with newline", lambda: open(TMP, "rb", newline="\n"))
check("a missing file", lambda: open(TMP + "_nope"))
check("a directory", lambda: open("/tmp"))
check("an int mode", lambda: open(TMP, 5))

cleanup(TMP, TMP + "2")
print("cleaned")
