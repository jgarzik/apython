# Error paths of _io, mmap, array, re, the exception types, weakref and the
# frame and traceback setters: each refusal is made 200 times and must not
# climb the block count.  A raise that jumped out of the middle of a builtin
# used to abandon whatever its native frames held; these now return, and
# release it on the way.
#
# Only the exception's TYPE is printed: the wording of several of these
# still differs from CPython's, and that is not what this file is about.
import sys, os, gc, tempfile, shutil, io, _io, mmap, array, re, weakref

def check(name, f, count=None):
    for _ in range(600):            # the freelists keep filling for a while
        try:
            f()
        except BaseException:
            pass
    gc.collect()                    # cycles are the collector's, not a leak
    before = sys.getallocatedblocks()
    out = "ok"
    for _ in range(200):
        try:
            f()
        except BaseException as e:
            out = type(e).__name__
    gc.collect()
    climbed = sys.getallocatedblocks() - before
    if count is None:
        count = out != "ok"         # a refusal, unless the case says otherwise
    if not count:
        # Where CPython's own count wanders -- a success that builds lists, a
        # split whose groups carry tracebacks and so cycles -- only the
        # outcome is compared.
        print(name, "->", out)
        return
    print(name, "->", out, "| steady" if climbed < 50 else "| CLIMBED")

class BadIdx:
    def __index__(self):
        raise RuntimeError("idx")

def gen():
    yield 1
    raise KeyError("mid")

def boom(m):
    raise RuntimeError("cb")

class C:
    pass

# ---- exceptions, weakref, frames and tracebacks

e = ValueError("x")
check("with_traceback(5)", lambda: e.with_traceback(5))
check("with_traceback()", lambda: e.with_traceback())
check("add_note(5)", lambda: e.add_note(5))
check("add_note()", lambda: e.add_note())
def f(): e.__cause__ = 5
check("cause=5", f)
def f(): e.__context__ = 5
check("context=5", f)
def f(): e.__traceback__ = 5
check("tb=5", f)
def f(): e.__suppress_context__ = 5
check("suppress=5", f)
def f(): e.__dict__ = 5
check("dict=5", f)
def f(): del e.args
check("del args", f)
def f(): del e.nosuch
check("del nosuch", f)
def f(): e.args = gen()
check("args=gen", f)
check("ValueError(k=1)", lambda: ValueError(k=1))
check("AttributeError(zz=1)", lambda: AttributeError("m", zz=1))
check("ImportError(zz=1)", lambda: ImportError("m", zz=1))
check("BaseException.__new__()", lambda: BaseException.__new__())
check("BaseException.__new__(5)", lambda: BaseException.__new__(5))
check("BaseException.__new__(int)", lambda: BaseException.__new__(int))
def f():
    try: raise ValueError
    except 5: pass
check("except 5", f)
check("EG()", lambda: ExceptionGroup())
check("EG(5, [])", lambda: ExceptionGroup(5, [ValueError()]))
check("EG('m', 5)", lambda: ExceptionGroup("m", 5))
check("EG('m', [])", lambda: ExceptionGroup("m", []))
check("EG('m', ())", lambda: ExceptionGroup("m", ()))
check("EG('m', [5])", lambda: ExceptionGroup("m", [5]))
check("EG('m', 'ab')", lambda: ExceptionGroup("m", "ab"))
check("EG('m', [KI])", lambda: ExceptionGroup("m", [KeyboardInterrupt()]))
g = ExceptionGroup("m", [ValueError(1), ExceptionGroup("n", [KeyError(2)])])
def f(): g.message = 5
check("eg.message=", f)
def f(): g.exceptions = 5
check("eg.exceptions=", f)
check("eg.split()", lambda: g.split())
check("eg.subgroup()", lambda: g.subgroup())
check("eg.derive()", lambda: g.derive())
check("eg.derive(5)", lambda: g.derive(5))
check("eg.split(ok)", lambda: g.split(ValueError), count=False)
check("eg.subgroup(ok)", lambda: g.subgroup(KeyError), count=False)
class BadDerive(ExceptionGroup):
    def derive(self, excs): return 5
bd = BadDerive("m", [ValueError(1), KeyError(2)])
check("bad derive split", lambda: bd.split(ValueError), count=False)
check("bad derive subgroup", lambda: bd.subgroup(ValueError), count=False)
class RaisingDerive(ExceptionGroup):
    def derive(self, excs): raise RuntimeError("no")
rd = RaisingDerive("m", [ValueError(1), KeyError(2)])
check("raising derive split", lambda: rd.split(ValueError), count=False)
def f():
    try: raise RaisingDerive("m", [ValueError(1), KeyError(2)])
    except* ValueError: pass
check("raising derive except*", f, count=False)
# weakref
check("ref(5)", lambda: weakref.ref(5))
check("ref([])", lambda: weakref.ref([]))
check("ref()", lambda: weakref.ref())
c = C()
check("ref(c,1,2)", lambda: weakref.ref(c, 1, 2))
check("ref(c, callback=)", lambda: weakref.ref(c, callback=None))
check("proxy(5)", lambda: weakref.proxy(5))
def f():
    d = C(); p = weakref.proxy(d); del d
    return p.x
check("dead proxy attr", f)
def f():
    d = C(); p = weakref.proxy(d); del d
    p.x = 1
check("dead proxy set", f)
def f():
    d = C(); p = weakref.proxy(d); del d
    return repr(p) and 1
def f2():
    d = C(); r = weakref.ref(d); del d
    return hash(r)
check("dead ref hash", f2)
def f():
    def cb(r): raise RuntimeError("cb")
    d = C(); r = weakref.ref(d, cb)
    return 1
def f():
    def cb(r): raise RuntimeError("cb")
    d = C(); r = weakref.ref(d, cb); del d
    return 1
old = sys.stderr; sys.stderr = io.StringIO()      # the callback's report
check("raising callback", f, count=False)
sys.stderr = old
check("ref.__init__ bad", lambda: weakref.ref.__init__(weakref.ref(c), 1, 2, 3))
# frame / traceback
fr0 = sys._getframe()       # held here, not in a local: a frame that holds
def f(): fr0.f_lineno = 5   # itself is a cycle, and the count would follow
check("f_lineno=", f)       # the collector rather than the setter
def f(): fr0.f_code = 5
check("f_code=", f)
check("_getframe('x')", lambda: sys._getframe("x"))
check("_getframe(1000)", lambda: sys._getframe(100000))
check("frame.clear(1)", lambda: fr0.clear(1))
check("frame.clear()", lambda: fr0.clear())
def tb():
    try: raise ValueError
    except ValueError as e: return e.__traceback__
t = tb()
def f(): t.tb_next = 5
check("tb_next=5", f)
def f(): t.tb_next = t
check("tb_next=self", f)
def f(): t.tb_lineno = 5
check("tb_lineno=", f)
def f(): t.tb_frame = 5
check("tb_frame=", f)
def f(): t.zz = 5
check("tb.zz=", f)
check("stdout.write(5)", lambda: sys.stdout.write(5))
check("stdout.writelines(5)", lambda: sys.stdout.writelines(5))
check("stdout.writelines([5])", lambda: sys.stdout.writelines([5]))

# ---- array
a = array.array('i', [1, 2, 3])
check("array()", lambda: array.array())
check("array(5)", lambda: array.array(5))
check("array('z')", lambda: array.array('z'))
check("array('i', 5)", lambda: array.array('i', 5))
check("array('i', ['x'])", lambda: array.array('i', ['x']))
check("array('i', gen())", lambda: array.array('i', gen()))
check("array('b', [300])", lambda: array.array('b', [300]))
check("a[BadIdx]", lambda: a[BadIdx()])
check("a['x']", lambda: a['x'])
check("a[99]", lambda: a[99])
def f(): a[BadIdx()] = 1
check("a[BadIdx]=", f)
def f(): a[0] = 'x'
check("a[0]='x'", f)
def f(): a[99] = 1
check("a[99]=1", f)
check("append()", lambda: a.append())
check("append('x')", lambda: array.array('i').append('x'))
check("extend()", lambda: a.extend())
check("extend(5)", lambda: array.array('i').extend(5))
check("extend(gen)", lambda: array.array('i').extend(gen()))
check("frombytes()", lambda: a.frombytes())
check("frombytes(5)", lambda: array.array('i').frombytes(5))
check("frombytes(b'abc')", lambda: array.array('i').frombytes(b'abc'))
check("fromfile()", lambda: a.fromfile())
check("fromfile(5, 1)", lambda: array.array('i').fromfile(5, 1))
check("tofile()", lambda: a.tofile())
check("tofile(5)", lambda: a.tofile(5))
check("byteswap(1)", lambda: a.byteswap(1))
check("__getitem__()", lambda: a.__getitem__())
check("__setitem__()", lambda: a.__setitem__())
def f():
    b = array.array('i', [1]); m = memoryview(b)
    try: b.append(2)
    finally: m.release()
check("append exporting", f)
def f():
    b = array.array('i', [1]); m = memoryview(b)
    try: b.extend([2])
    finally: m.release()
check("extend exporting", f)
class E:
    def __eq__(self, o): raise RuntimeError("eq")
check("a == other", lambda: a == array.array('d', [1.0]))

# ---- mmap
m = mmap.mmap(-1, 4096)
check("mmap(-1, 0)", lambda: mmap.mmap(-1, 0))
check("mmap(-1, -5)", lambda: mmap.mmap(-1, -5))
check("mmap('x', 10)", lambda: mmap.mmap('x', 10))
check("mmap(9999, 10)", lambda: mmap.mmap(9999, 10))
check("seek(-1)", lambda: m.seek(-1))
check("m[99999]", lambda: m[99999])
check("write(5)", lambda: m.write(5))
check("find(5)", lambda: m.find(5))
check("move bad", lambda: m.move(0, 5000, 10))
check("flush bad", lambda: m.flush(1, 99999))
check("madvise bad", lambda: m.madvise(0, 99999, 1))
c = mmap.mmap(-1, 10); c.close()
check("closed read", lambda: c.read(1))
check("closed size", lambda: c.size())
check("closed write", lambda: c.write(b'x'))
m.write(b"hello"); m.seek(0)
print(m.read(5), m.find(b"llo"), m.rfind(b"l"))

# ---- _io
d = tempfile.mkdtemp()
p = os.path.join(d, "f")
open(p, "wb").write(b"hello\nworld\n")
r = _io.FileIO(p, "rb"); w = _io.FileIO(p, "ab"); c = _io.FileIO(p); c.close()
check("FileIO()", lambda: _io.FileIO())
check("FileIO nosuch", lambda: _io.FileIO(os.path.join(d, "no", "such")))
check("FileIO(5.5)", lambda: _io.FileIO(5.5))
check("FileIO(-1)", lambda: _io.FileIO(-1))
check("FileIO(BadIdx)", lambda: _io.FileIO(BadIdx()))
check("FileIO(p, 5)", lambda: _io.FileIO(p, 5))
check("FileIO(p, 'zz')", lambda: _io.FileIO(p, "zz"))
check("FileIO(p, 'rw')", lambda: _io.FileIO(p, "rw"))
check("FileIO(dir)", lambda: _io.FileIO(d))
check("FileIO(p, closefd=False)", lambda: _io.FileIO(p, closefd=False))
check("FileIO('a\\0b')", lambda: _io.FileIO("a\0b"))
check("open nosuch", lambda: open(os.path.join(d, "no", "such")))
check("open(p, 'zz')", lambda: open(p, "zz"))
check("open(p, buffering='x')", lambda: open(p, buffering="x"))
check("open(5.5)", lambda: open(5.5))
check("r.read('x')", lambda: r.read("x"))
check("r.read(BadIdx)", lambda: r.read(BadIdx()))
check("w.read()", lambda: w.read())
check("w.read(1)", lambda: w.read(1))
check("c.read()", lambda: c.read())
check("c.readall()", lambda: c.readall())
check("r.readinto(b'x')", lambda: r.readinto(b"x"))
check("r.readinto(5)", lambda: r.readinto(5))
check("w.readinto(bytearray(1))", lambda: w.readinto(bytearray(1)))
check("c.readinto", lambda: c.readinto(bytearray(1)))
check("r.write(b'x')", lambda: r.write(b"x"))
check("w.write('x')", lambda: w.write("x"))
check("w.write(5)", lambda: w.write(5))
check("c.write", lambda: c.write(b"x"))
check("r.seek('x')", lambda: r.seek("x"))
check("r.seek(0, 'x')", lambda: r.seek(0, "x"))
check("r.seek(0, 99)", lambda: r.seek(0, 99))
check("r.seek(-1)", lambda: r.seek(-1))
check("c.seek", lambda: c.seek(0))
check("c.tell", lambda: c.tell())
check("r.truncate()", lambda: r.truncate())
check("w.truncate('x')", lambda: w.truncate("x"))
check("w.truncate(-1)", lambda: w.truncate(-1))
check("c.truncate", lambda: c.truncate())
check("c.flush", lambda: c.flush())
check("c.fileno", lambda: c.fileno())
check("c.isatty", lambda: c.isatty())
check("c.readable", lambda: c.readable())
check("c.writable", lambda: c.writable())
check("c.seekable", lambda: c.seekable())
check("c.__enter__", lambda: c.__enter__())
b = _io.BytesIO(b"abc\ndef\n"); cb = _io.BytesIO(); cb.close()
check("BytesIO(5)", lambda: _io.BytesIO(5))
check("BytesIO('s')", lambda: _io.BytesIO("s"))
check("b.read('x')", lambda: b.read("x"))
check("b.read(BadIdx)", lambda: b.read(BadIdx()))
check("b.readline('x')", lambda: b.readline("x"))
check("b.readinto(b'x')", lambda: b.readinto(b"x"))
check("b.readinto(5)", lambda: b.readinto(5))
check("b.write('x')", lambda: b.write("x"))
check("b.write(5)", lambda: b.write(5))
check("b.seek('x')", lambda: b.seek("x"))
check("b.seek(0, 'x')", lambda: b.seek(0, "x"))
check("b.seek(0, 99)", lambda: b.seek(0, 99))
check("b.seek(-1)", lambda: b.seek(-1))
check("b.truncate('x')", lambda: b.truncate("x"))
check("b.truncate(-1)", lambda: b.truncate(-1))
for nm in ("read", "readline", "getvalue", "getbuffer", "tell", "truncate", "flush", "readable", "writable", "seekable", "__enter__", "__next__"):
    check("closed " + nm, lambda nm=nm: getattr(cb, nm)())
check("closed write", lambda: cb.write(b"x"))
check("closed seek", lambda: cb.seek(0))
check("closed readinto", lambda: cb.readinto(bytearray(1)))
e = _io.BytesIO(b"abc"); v = e.getbuffer()
check("export write", lambda: e.write(b"x"))
check("export truncate", lambda: e.truncate(0))
check("export close", lambda: e.close())
v.release()
print(e.write(b"x"), e.getvalue())
check("with closed bz2-ish", lambda: io.BufferedReader(c))
print(r.read(5), r.readall(), b.read(3), b.readline(), next(b))
r.close(); w.close()
shutil.rmtree(d)

# ---- re
p = re.compile(r"(a)(b)?(?P<n>c)?")
pb = re.compile(rb"(a)(b)?")
m = p.match("abc")
check("compile(", lambda: re.compile("(", 0))
check("compile bad flags", lambda: re.compile("a", "x"))
check("compile(5)", lambda: re.compile(5))
check("match(5)", lambda: p.match(5))
check("match(b'')", lambda: p.match(b"a"))
check("pb.match('a')", lambda: pb.match("a"))
check("match()", lambda: p.match())
check("match('a', 'x')", lambda: p.match("a", "x"))
check("match('a', 0, 'x')", lambda: p.match("a", 0, "x"))
check("search(5)", lambda: p.search(5))
check("search()", lambda: p.search())
check("search('a','x')", lambda: p.search("a", "x"))
check("fullmatch(5)", lambda: p.fullmatch(5))
check("fullmatch('a','x')", lambda: p.fullmatch("a", "x"))
check("findall(5)", lambda: p.findall(5))
check("findall()", lambda: p.findall())
check("findall('a','x')", lambda: p.findall("a", "x"))
check("findall('a',0,'x')", lambda: p.findall("a", 0, "x"))
check("finditer(5)", lambda: p.finditer(5))
check("finditer('a','x')", lambda: p.finditer("a", "x"))
check("finditer(b'a')", lambda: list(p.finditer(b"a")))
check("split(5)", lambda: p.split(5))
check("split()", lambda: p.split())
check("split('a','x')", lambda: p.split("a", "x"))
check("sub()", lambda: p.sub())
check("sub('x', 5)", lambda: p.sub("x", 5))
check("sub(5, 'abc')", lambda: p.sub(5, "abc"))
check("sub('x','abc','y')", lambda: p.sub("x", "abc", "y"))
check("sub(boom)", lambda: p.sub(boom, "xabcx"))
check("sub(lambda:5)", lambda: p.sub(lambda mm: 5, "xabcx"))
check("sub(lambda:b'')", lambda: p.sub(lambda mm: b"q", "xabcx"))
check("sub bad group", lambda: p.sub(r"\9", "abc"))
check("sub bad name", lambda: p.sub(r"\g<zz>", "abc"))
check("sub bad escape", lambda: p.sub("\\q", "abc"))
check("sub unterminated", lambda: p.sub(r"\g<n", "abc"))
check("sub bytes repl on str", lambda: p.sub(b"x", "abc"))
check("sub ok", lambda: p.sub(r"[\1\g<n>]", "xabcx"))
check("pb.sub(lambda:5)", lambda: pb.sub(lambda mm: 5, b"xabx"))
check("subn()", lambda: p.subn())
check("subn('x', 5)", lambda: p.subn("x", 5))
check("subn(5, 'abc')", lambda: p.subn(5, "abc"))
check("subn(boom)", lambda: p.subn(boom, "xabcx"))
check("subn(lambda:5)", lambda: p.subn(lambda mm: 5, "xabcx"))
check("subn bad group", lambda: p.subn(r"\9", "abc"))
check("subn bytes repl", lambda: p.subn(b"x", "abc"))
check("subn ok", lambda: p.subn(r"[\1]", "xabcx"))
# A callable's answer reaches the join as a Value: subn() unpacked it first,
# so an int was read as an address (a crash) and None was refused.
print(p.subn(lambda mm: None, "xabcx"), p.sub(lambda mm: None, "xabcx"))
print(p.subn(lambda mm: "Z", "xabcx"), pb.subn(lambda mm: b"Z", b"xabx"))
check("m.group(1, 2) ok", lambda: m.group(1, 2), count=True)
check("m.group(9)", lambda: m.group(9))
check("m.group('zz')", lambda: m.group("zz"))
check("m.group(1, 9)", lambda: m.group(1, 9))
check("m.group(1, 'zz')", lambda: m.group(1, "zz"))
check("m.group(1.5)", lambda: m.group(1.5))
check("m.group(1, 2)", lambda: m.group(1, 2))
check("m[9]", lambda: m[9])
check("m['zz']", lambda: m["zz"])
check("m.start(9)", lambda: m.start(9))
check("m.end('zz')", lambda: m.end("zz"))
check("m.span(9)", lambda: m.span(9))
check("m.span('zz')", lambda: m.span("zz"))
check("m.expand()", lambda: m.expand())
check("m.expand(5)", lambda: m.expand(5))
check("m.expand(bad)", lambda: m.expand(r"\9"))
check("m.expand(ok)", lambda: m.expand(r"<\1\g<n>>"))
check("re.sub cb raise", lambda: re.sub("a", boom, "banana"))
check("scanner", lambda: [x.group() for x in p.finditer("abcab")])
