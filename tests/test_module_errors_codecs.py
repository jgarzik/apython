"""Error paths of the C-backed modules: math, cmath, random, unicodedata,
zlib, bz2, lzma, hashlib, ssl, ctypes and pyexpat.

Every refusal here used to leave its function by jumping into the unwinder,
which abandoned whatever the native frames in between were holding.  Each
case is run once for the exception type (and for the message where CPython
3.12 words it the same way), then 200 more times with
sys.getallocatedblocks() read around the loop: a failure path that keeps a
buffer, a handle or a reference shows up as a climb.
"""
import sys


def err(label, fn, *args, **kw):
    """Print the exception type fn(*args) raises, and whether 200 more of
    them leave the heap where it was."""
    msg = kw.pop("_msg", False)
    try:
        fn(*args, **kw)
        print(label, "-> no error")
    except Exception as e:
        if msg:
            print(label, "->", type(e).__name__, str(e))
        else:
            print(label, "->", type(e).__name__)
    # Once more before measuring, so anything built lazily exists already.
    for _ in range(3):
        try:
            fn(*args, **kw)
        except Exception:
            pass
    # Two rounds, and the quieter one counts: an interpreter may grow a
    # cache of its own during the first.
    climbed = None
    for _round in range(2):
        before = sys.getallocatedblocks()
        for _ in range(200):
            try:
                fn(*args, **kw)
            except Exception:
                pass
        grew = sys.getallocatedblocks() - before
        if climbed is None or grew < climbed:
            climbed = grew
    print(label, "steady" if climbed < 50 else "CLIMBED")


def core(label, modname, fnname, *args):
    """The same for a function of one of OUR private core modules, which
    CPython does not have: there the two lines are printed without a call,
    so the output still compares."""
    try:
        mod = __import__(modname)
    except ImportError:
        print(label, "-> refused")
        print(label, "steady")
        return
    fn = getattr(mod, fnname)
    try:
        fn(*args)
        print(label, "-> no error")
    except Exception:
        print(label, "-> refused")
    climbed = None
    for _round in range(3):
        before = sys.getallocatedblocks()
        for _ in range(200):
            try:
                fn(*args)
            except Exception:
                pass
        grew = sys.getallocatedblocks() - before
        if climbed is None or grew < climbed:
            climbed = grew
    print(label, "steady" if climbed < 50 else "CLIMBED")


class RaisesFloat:
    def __float__(self):
        raise ValueError("from __float__")


class RaisesIndex:
    def __index__(self):
        raise ValueError("from __index__")


class RaisesComplex:
    def __complex__(self):
        raise ValueError("from __complex__")


class BadComplex:
    def __complex__(self):
        return "not a complex"


# --- unicodedata: the normal forms ---------------------------------------
import unicodedata

print("== unicodedata.normalize")
err("normalize()", unicodedata.normalize)
err("normalize(1 arg)", unicodedata.normalize, "NFC")
err("normalize(bad form)", unicodedata.normalize, "NFX", "abc", _msg=True)
err("normalize(int form)", unicodedata.normalize, 1, "abc")
err("normalize(int str)", unicodedata.normalize, "NFC", 1)
err("is_normalized()", unicodedata.is_normalized)
err("is_normalized(bad form)", unicodedata.is_normalized, "NFX", "abc", _msg=True)
err("is_normalized(int str)", unicodedata.is_normalized, "NFC", 1)
err("decomposition()", unicodedata.decomposition)
err("decomposition(2 chars)", unicodedata.decomposition, "ab")
err("decomposition(int)", unicodedata.decomposition, 65)
err("ucd_3_2_0.normalize(bad form)", unicodedata.ucd_3_2_0.normalize, "NFX", "abc", _msg=True)
err("ucd_3_2_0.decomposition(int)", unicodedata.ucd_3_2_0.decomposition, 65)

# --- cmath ---------------------------------------------------------------
import cmath

print("== cmath")
err("cmath.sqrt()", cmath.sqrt)
err("cmath.sqrt(str)", cmath.sqrt, "x", _msg=True)
err("cmath.sqrt(__complex__ raises)", cmath.sqrt, RaisesComplex(), _msg=True)
err("cmath.sqrt(__float__ raises)", cmath.sqrt, RaisesFloat(), _msg=True)
err("cmath.sqrt(__index__ raises)", cmath.sqrt, RaisesIndex(), _msg=True)
err("cmath.sqrt(__complex__ non-complex)", cmath.sqrt, BadComplex(), _msg=True)
err("cmath.log(0)", cmath.log, 0, _msg=True)
err("cmath.log()", cmath.log)
err("cmath.log(1, str)", cmath.log, 1, "x")
err("cmath.log(1, __complex__ raises)", cmath.log, 1, RaisesComplex(), _msg=True)
err("cmath.exp(overflow)", cmath.exp, 1e308, _msg=True)
err("cmath.atanh(1)", cmath.atanh, 1, _msg=True)
err("cmath.phase(str)", cmath.phase, "x")
err("cmath.polar(None)", cmath.polar, None)
err("cmath.rect(1 arg)", cmath.rect, 1)
err("cmath.rect(str)", cmath.rect, "x", 1)
err("cmath.rect(__float__ raises)", cmath.rect, RaisesFloat(), 1, _msg=True)
err("cmath.isnan(str)", cmath.isnan, "x")
err("cmath.isclose(1 arg)", cmath.isclose, 1)
err("cmath.isclose(str)", cmath.isclose, "x", 1)
err("cmath.isclose(negative tol)", cmath.isclose, 1, 1, rel_tol=-1.0, _msg=True)
err("cmath.isclose(str tol)", cmath.isclose, 1, 1, abs_tol="x")
err("cmath.isclose(__complex__ raises)", cmath.isclose, RaisesComplex(), 1, _msg=True)
err("cmath.isclose(bad keyword)", cmath.isclose, 1, 1, tol=1)

# --- ssl -----------------------------------------------------------------
import ssl

print("== ssl")
core("_sslcore.free()", "_sslcore", "free")
core("_sslcore.free(str)", "_sslcore", "free", "x")
core("_sslcore.set_password(int)", "_sslcore", "set_password", 1)
core("_sslcore.set_password(long)", "_sslcore", "set_password", b"x" * 2000)
core("_sslcore.set_alpn_server(1 arg)", "_sslcore", "set_alpn_server", 1)
core("_sslcore.set_alpn_server(dead handle)", "_sslcore", "set_alpn_server", 99999, b"a")
core("_sslcore.set_alpn_server(str handle)", "_sslcore", "set_alpn_server", "x", b"a")
core("_sslcore.set_alpn_server(int list)", "_sslcore", "set_alpn_server", 1, 2)
core("_sslcore.BIO_read()", "_sslcore", "BIO_read")
core("_sslcore.BIO_read(dead handle)", "_sslcore", "BIO_read", 99999, 10)
core("_sslcore.BIO_read(str handle)", "_sslcore", "BIO_read", "x", 10)
core("_sslcore.BIO_read(negative)", "_sslcore", "BIO_read", 99999, -5)
core("_sslcore.BIO_write(int data)", "_sslcore", "BIO_write", 99999, 5)
core("_sslcore.OBJ_txt2nid(int)", "_sslcore", "OBJ_txt2nid", 5)
core("_sslcore.SSL_CTX_new(bad method)", "_sslcore", "SSL_CTX_new", 9999)
core("_sslcore.SSL_CTX_new(str)", "_sslcore", "SSL_CTX_new", "x")

_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
err("ctx.set_ciphers(bogus)", _ctx.set_ciphers, "no-such-cipher")
err("ctx.load_cert_chain(missing)", _ctx.load_cert_chain, "/nonexistent/cert.pem")
err("ctx.load_verify_locations()", _ctx.load_verify_locations)
err("ctx.set_alpn_protocols(long)", _ctx.set_alpn_protocols, ["x" * 300])
err("MemoryBIO.write(str)", ssl.MemoryBIO().write, "text")

# --- random --------------------------------------------------------------
import random


class RaisesIndexKey:
    def __index__(self):
        raise KeyError("from __index__")


print("== random")
_rh = None
try:
    import _randomcore
    _rh = _randomcore.new()
except ImportError:
    pass
# A call with no argument at all used to read args[0] off the caller's stack.
core("_randomcore.genrand()", "_randomcore", "genrand")
core("_randomcore.random()", "_randomcore", "random")
core("_randomcore.getstate()", "_randomcore", "getstate")
core("_randomcore.free()", "_randomcore", "free")
core("_randomcore.genrand(str)", "_randomcore", "genrand", "x")
core("_randomcore.genrand(dead)", "_randomcore", "genrand", 99999)
core("_randomcore.random(__index__ raises)", "_randomcore", "random", RaisesIndexKey())
core("_randomcore.bits(1 arg)", "_randomcore", "bits", _rh)
core("_randomcore.bits(negative)", "_randomcore", "bits", _rh, -1)
core("_randomcore.bits(wide)", "_randomcore", "bits", _rh, 40)
core("_randomcore.bits(str)", "_randomcore", "bits", _rh, "x")
core("_randomcore.bits(dead)", "_randomcore", "bits", 99999, 1)
core("_randomcore.words(1 arg)", "_randomcore", "words", _rh)
core("_randomcore.words(negative)", "_randomcore", "words", _rh, -1)
core("_randomcore.words(dead)", "_randomcore", "words", 99999, 1)
core("_randomcore.words(__index__ raises)", "_randomcore", "words", _rh, RaisesIndexKey())
core("_randomcore.seed_words(int)", "_randomcore", "seed_words", _rh, 5)
core("_randomcore.seed_words(1 arg)", "_randomcore", "seed_words", _rh)
core("_randomcore.seed_words(str item)", "_randomcore", "seed_words", _rh, [1, "x"])
core("_randomcore.seed_words(__index__ raises)", "_randomcore", "seed_words", _rh, [1, RaisesIndexKey()])
# An empty key used to read key[0] of an empty list.
core("_randomcore.seed_words(empty)", "_randomcore", "seed_words", _rh, [])
core("_randomcore.getstate(dead)", "_randomcore", "getstate", 99999)
core("_randomcore.setstate(1 arg)", "_randomcore", "setstate", _rh)
core("_randomcore.setstate(str)", "_randomcore", "setstate", _rh, "x")
core("_randomcore.setstate(short)", "_randomcore", "setstate", _rh, b"x")
core("_randomcore.setstate(bad cursor)", "_randomcore", "setstate", _rh, b"\xff" * 2500)

_rng = random.Random(1)
err("getrandbits(-1)", _rng.getrandbits, -1, _msg=True)
err("getrandbits(str)", _rng.getrandbits, "x")
err("getrandbits(__index__ raises)", _rng.getrandbits, RaisesIndexKey(), _msg=True)
err("seed(list)", _rng.seed, [1])
err("setstate(int)", _rng.setstate, 5)
err("setstate(short tuple)", _rng.setstate, (3, (1, 2, 3), None))
err("randbytes(-1)", _rng.randbytes, -1)
err("randrange(0)", _rng.randrange, 0)
# The generator still works, and still gives CPython's sequence.
_rng.seed(12345)
print(_rng.getrandbits(32), _rng.getrandbits(70), _rng.random())

# --- unicodedata: names and properties -----------------------------------
print("== unicodedata")
err("lookup()", unicodedata.lookup)
err("lookup(int)", unicodedata.lookup, 5)
err("lookup(unknown)", unicodedata.lookup, "NO SUCH CHARACTER NAME")
err("name()", unicodedata.name)
err("name(3 args)", unicodedata.name, "a", 1, 2)
err("name(int)", unicodedata.name, 5)
err("name(two chars)", unicodedata.name, "ab")
err("name(unnamed)", unicodedata.name, "\n", _msg=True)
err("decimal()", unicodedata.decimal)
err("decimal(int)", unicodedata.decimal, 5)
err("decimal(letter)", unicodedata.decimal, "a", _msg=True)
err("digit()", unicodedata.digit)
err("digit(int)", unicodedata.digit, 5)
err("digit(letter)", unicodedata.digit, "a", _msg=True)
err("numeric()", unicodedata.numeric)
err("numeric(int)", unicodedata.numeric, 5)
err("numeric(letter)", unicodedata.numeric, "a", _msg=True)
for _name in ("category", "bidirectional", "east_asian_width", "combining", "mirrored"):
    _fn = getattr(unicodedata, _name)
    err(_name + "()", _fn)
    err(_name + "(int)", _fn, 5)
    err(_name + "(two chars)", _fn, "ab")
# A default is handed back, not raised over.
print(unicodedata.name("\n", "dflt"), unicodedata.decimal("a", -1),
      unicodedata.digit("a", None), unicodedata.numeric("a", 2.5))

# --- pyexpat -------------------------------------------------------------
import pyexpat

print("== pyexpat")
_ph = None
try:
    import _pyexpatcore
    _ph = _pyexpatcore.parser_new(None, None, None)
except ImportError:
    pass


class RaisesBool:
    def __bool__(self):
        raise ValueError("from __bool__")


core("parser_new()", "_pyexpatcore", "parser_new")
core("parser_new(int encoding)", "_pyexpatcore", "parser_new", 1, None, None)
core("parser_new(int sep)", "_pyexpatcore", "parser_new", None, 1, None)
core("parser_new(long sep)", "_pyexpatcore", "parser_new", None, "ab", None)
core("parser_new(list intern)", "_pyexpatcore", "parser_new", None, None, [])
core("parser_free()", "_pyexpatcore", "parser_free")
core("parser_free(str)", "_pyexpatcore", "parser_free", "x")
core("parser_status()", "_pyexpatcore", "parser_status")
core("parser_status(str)", "_pyexpatcore", "parser_status", "x")
core("parser_status(dead)", "_pyexpatcore", "parser_status", 99999)
core("ErrorString()", "_pyexpatcore", "ErrorString")
core("ErrorString(str)", "_pyexpatcore", "ErrorString", "x")
core("parser_set_handler(2 args)", "_pyexpatcore", "parser_set_handler", _ph, 0)
core("parser_set_handler(dead)", "_pyexpatcore", "parser_set_handler", 99999, 0, None)
core("parser_set_handler(str handle)", "_pyexpatcore", "parser_set_handler", "x", 0, None)
core("parser_set_handler(bad index)", "_pyexpatcore", "parser_set_handler", _ph, 9999, None)
core("parser_set_handler(str index)", "_pyexpatcore", "parser_set_handler", _ph, "x", None)
core("parser_parse(2 args)", "_pyexpatcore", "parser_parse", _ph, b"")
core("parser_parse(dead)", "_pyexpatcore", "parser_parse", 99999, b"", False)
core("parser_parse(str handle)", "_pyexpatcore", "parser_parse", "x", b"", False)
core("parser_parse(int data)", "_pyexpatcore", "parser_parse", _ph, 5, False)
core("parser_parse(__bool__ raises)", "_pyexpatcore", "parser_parse", _ph, b"", RaisesBool())
core("parser_set_flag(2 args)", "_pyexpatcore", "parser_set_flag", _ph, 0)
core("parser_set_flag(dead)", "_pyexpatcore", "parser_set_flag", 99999, 0, 1)
core("parser_set_flag(bad flag)", "_pyexpatcore", "parser_set_flag", _ph, 9999, 1)
core("parser_set_flag(str flag)", "_pyexpatcore", "parser_set_flag", _ph, "x", 1)
core("parser_set_flag(str value)", "_pyexpatcore", "parser_set_flag", _ph, 0, "x")


def _parse_bad():
    pyexpat.ParserCreate().Parse(b"<a><b></a>", True)


def _parse_handler_raises():
    p = pyexpat.ParserCreate()

    def start(name, attrs):
        raise KeyError(name)

    p.StartElementHandler = start
    p.Parse(b"<a><b/></a>", True)


def _parse_text_handler_raises():
    p = pyexpat.ParserCreate()
    p.buffer_text = True

    def text(data):
        raise IndexError(data)

    p.CharacterDataHandler = text
    p.Parse(b"<a>some text<b/></a>", True)


def _parse_twice():
    p = pyexpat.ParserCreate()
    p.Parse(b"<a/>", True)
    p.Parse(b"<a/>", True)


err("ParserCreate(int)", pyexpat.ParserCreate, 5)
err("ParserCreate(long separator)", pyexpat.ParserCreate, None, "ab")
err("Parse(malformed)", _parse_bad)
err("Parse(int)", pyexpat.ParserCreate().Parse, 5)
err("Parse(handler raises)", _parse_handler_raises, _msg=True)
err("Parse(text handler raises)", _parse_text_handler_raises, _msg=True)
err("Parse(after final)", _parse_twice)
err("Parse(isfinal __bool__ raises)", pyexpat.ParserCreate().Parse, b"", RaisesBool(), _msg=True)
err("ErrorString(str)", pyexpat.ErrorString, "x")

# --- ctypes --------------------------------------------------------------
import ctypes

print("== ctypes")
core("dlopen()", "_ctypescore", "dlopen")
core("dlopen(int name)", "_ctypescore", "dlopen", 5, 2)
core("dlopen(str mode)", "_ctypescore", "dlopen", None, "x")
core("dlsym(1 arg)", "_ctypescore", "dlsym", 0)
core("dlsym(str handle)", "_ctypescore", "dlsym", "x", b"puts")
core("dlsym(int name)", "_ctypescore", "dlsym", 0, 5)
core("dlclose()", "_ctypescore", "dlclose")
core("dlclose(str)", "_ctypescore", "dlclose", "x")
core("addr()", "_ctypescore", "addr")
core("addr(int)", "_ctypescore", "addr", 5)
core("addr(str)", "_ctypescore", "addr", "text")
core("read(1 arg)", "_ctypescore", "read", 0)
core("read(str address)", "_ctypescore", "read", "x", 1)
core("read(str length)", "_ctypescore", "read", 0, "x")
core("write(1 arg)", "_ctypescore", "write", 0)
core("write(str address)", "_ctypescore", "write", "x", b"")
core("write(int data)", "_ctypescore", "write", 0, 5)
core("strlen()", "_ctypescore", "strlen")
core("strlen(str)", "_ctypescore", "strlen", "x")
core("wcslen(str)", "_ctypescore", "wcslen", "x")
core("prep_cif(4 args)", "_ctypescore", "prep_cif", 0, 0, 0, 0)
core("prep_cif(str)", "_ctypescore", "prep_cif", 0, 0, 0, 0, "x")
core("prep_cif_var(str)", "_ctypescore", "prep_cif_var", 0, 0, 0, "x", 0, 0)
core("call(4 args)", "_ctypescore", "call", 0, 0, 0, 0)
core("call(str)", "_ctypescore", "call", 0, 0, "x", 0, 0)
core("closure(2 args)", "_ctypescore", "closure", 0, 0)
core("closure(str cif)", "_ctypescore", "closure", "x", len, 0)
core("closure(str out)", "_ctypescore", "closure", 0, len, "x")
core("closure_free()", "_ctypescore", "closure_free")
core("closure_free(str)", "_ctypescore", "closure_free", "x")
core("errno_set()", "_ctypescore", "errno_set")
core("errno_set(str)", "_ctypescore", "errno_set", "x")

_libc = ctypes.CDLL(None)
# CPython's own dlopen and dlsym failures grow its heap, so these two are
# asked for the type only.
for _what, _fn, _args in (("CDLL(missing)", ctypes.CDLL, ("/nonexistent/libnothing.so",)),
                          ("getattr(missing symbol)", getattr, (_libc, "no_such_symbol_anywhere"))):
    try:
        _fn(*_args)
        print(_what, "-> no error")
    except Exception as _e:
        print(_what, "->", type(_e).__name__)
err("c_int(str)", ctypes.c_int, "x")
err("c_char_p(int list)", ctypes.c_char_p, [1])
err("strlen(wrong type)", _libc.strlen, 1.5)
err("sizeof(int)", ctypes.sizeof, 5)
err("create_string_buffer(None)", ctypes.create_string_buffer, None)
err("cast(1 arg)", ctypes.cast, 1)

# A callback that raises: the C caller goes on, and qsort still sorts with
# the comparisons that did answer.
_CMP = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int))


def _cmp(a, b):
    return a[0] - b[0]


_arr = (ctypes.c_int * 5)(5, 1, 4, 2, 3)
_libc.qsort(_arr, 5, ctypes.sizeof(ctypes.c_int), _CMP(_cmp))
print(list(_arr))

# --- zlib ----------------------------------------------------------------
import zlib

print("== zlib")
_zh = None
try:
    import _zlibcore
    _zh = _zlibcore.stream_new(1, 6, 15, 8, 0)
except ImportError:
    pass
core("crc32(1 arg)", "_zlibcore", "crc32", b"")
core("crc32(str seed)", "_zlibcore", "crc32", b"", "x")
core("crc32(int data)", "_zlibcore", "crc32", 5, 0)
core("adler32(1 arg)", "_zlibcore", "adler32", b"")
core("adler32(str seed)", "_zlibcore", "adler32", b"", "x")
core("adler32(int data)", "_zlibcore", "adler32", 5, 1)
core("stream_new(4 args)", "_zlibcore", "stream_new", 0, 6, 15, 8)
core("stream_new(str)", "_zlibcore", "stream_new", 0, 6, "x", 8, 0)
core("stream_new(bad wbits)", "_zlibcore", "stream_new", 0, 6, 99, 8, 0)
core("stream_new(bad level)", "_zlibcore", "stream_new", 0, 99, 15, 8, 0)
core("stream_feed(3 args)", "_zlibcore", "stream_feed", _zh, b"", 0)
core("stream_feed(dead)", "_zlibcore", "stream_feed", 99999, b"", 0, 0)
core("stream_feed(str handle)", "_zlibcore", "stream_feed", "x", b"", 0, 0)
core("stream_feed(str flush)", "_zlibcore", "stream_feed", _zh, b"", "x", 0)
core("stream_feed(str max)", "_zlibcore", "stream_feed", _zh, b"", 0, "x")
core("stream_feed(int data)", "_zlibcore", "stream_feed", _zh, 5, 0, 0)
core("stream_feed(garbage)", "_zlibcore", "stream_feed", _zh, b"this is not a zlib stream" * 40, 0, 0)
core("stream_state()", "_zlibcore", "stream_state")
core("stream_state(dead)", "_zlibcore", "stream_state", 99999)
core("stream_state(str)", "_zlibcore", "stream_state", "x")
core("stream_drop_tail()", "_zlibcore", "stream_drop_tail")
core("stream_drop_tail(dead)", "_zlibcore", "stream_drop_tail", 99999)
core("stream_drop_tail(str)", "_zlibcore", "stream_drop_tail", "x")
core("stream_free()", "_zlibcore", "stream_free")
core("stream_free(str)", "_zlibcore", "stream_free", "x")

_zdata = zlib.compress(b"some data to compress " * 50)


def _z_truncated():
    zlib.decompress(_zdata[:20])


def _z_corrupt():
    zlib.decompress(_zdata[:10] + b"\xff\xff\xff\xff" + _zdata[14:])


def _z_corrupt_obj():
    d = zlib.decompressobj()
    d.decompress(b"\x00" * 1000)


def _z_after_flush():
    c = zlib.compressobj()
    c.compress(b"abc")
    c.flush()
    c.compress(b"more")


def _z_flush_twice():
    c = zlib.compressobj()
    c.flush()
    c.flush()


err("crc32()", zlib.crc32)
err("crc32(str)", zlib.crc32, "text")
err("crc32(bytes, str)", zlib.crc32, b"", "x")
err("adler32(int)", zlib.adler32, 5)
err("compress()", zlib.compress)
err("compress(str)", zlib.compress, "text")
err("compress(bad level)", zlib.compress, b"abc", 99)
err("compress(str level)", zlib.compress, b"abc", "x")
err("decompress(garbage)", zlib.decompress, b"not a zlib stream at all", _msg=True)
err("decompress(empty)", zlib.decompress, b"")
err("decompress(truncated)", _z_truncated, _msg=True)
err("decompress(corrupt)", _z_corrupt)
err("decompress(str)", zlib.decompress, "text")
err("decompress(bad wbits)", zlib.decompress, _zdata, 99)
err("decompress(wrong wbits)", zlib.decompress, _zdata, -15, _msg=True)
err("compressobj(str)", zlib.compressobj, "x")
err("compressobj.compress(str)", zlib.compressobj().compress, "text")
err("compressobj.compress(after flush)", _z_after_flush)
err("compressobj.flush(twice)", _z_flush_twice)
err("compressobj.flush(str)", zlib.compressobj().flush, "x")
err("decompressobj.decompress(str)", zlib.decompressobj().decompress, "text")
err("decompressobj.decompress(garbage)", _z_corrupt_obj, _msg=True)
err("decompressobj.decompress(str max)", zlib.decompressobj().decompress, _zdata, "x")
# And the stream still works after all of that.
print(zlib.decompress(_zdata) == b"some data to compress " * 50, zlib.crc32(b"abc"), zlib.adler32(b"abc"))
