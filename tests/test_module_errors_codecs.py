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
    # Up to five rounds, and the quietest one counts: an interpreter fills
    # freelists of its own during the first few hundred calls, and that is
    # growth without being a leak.  A real leak climbs in every round.
    climbed = None
    for _round in range(5):
        before = sys.getallocatedblocks()
        for _ in range(200):
            try:
                fn(*args, **kw)
            except Exception:
                pass
        grew = sys.getallocatedblocks() - before
        if climbed is None or grew < climbed:
            climbed = grew
        if climbed < 50:
            break
    print(label, "steady" if climbed < 50 else "CLIMBED")


def err_type(label, fn, *args, **kw):
    """The exception only.  For a failure that is raised underneath the
    module -- by the binary-operator dispatch, by tuple(), by a __float__
    slot -- where what is left behind is not this module's to release."""
    msg = kw.pop("_msg", False)
    try:
        fn(*args, **kw)
        print(label, "-> no error")
    except Exception as e:
        if msg:
            print(label, "->", type(e).__name__, str(e))
        else:
            print(label, "->", type(e).__name__)


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


class AbsIsNone(int):
    def __abs__(self):
        return None


# bpo-31478: seeding asks the int for its magnitude, not the subclass.
_rng.seed(AbsIsNone(7))
_first = _rng.random()
_rng.seed(7)
print(_first == _rng.random())
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

# --- bz2 -----------------------------------------------------------------
import bz2

print("== bz2")
_bh = None
try:
    import _bz2core
    _bh = _bz2core.stream_new(1, 9)
except ImportError:
    pass
core("bz2 stream_new(1 arg)", "_bz2core", "stream_new", 0)
core("bz2 stream_new(str)", "_bz2core", "stream_new", "x", 9)
core("bz2 stream_new(str level)", "_bz2core", "stream_new", 0, "x")
core("bz2 stream_new(bad level)", "_bz2core", "stream_new", 0, 99)
core("bz2 stream_feed(3 args)", "_bz2core", "stream_feed", _bh, b"", 0)
core("bz2 stream_feed(dead)", "_bz2core", "stream_feed", 99999, b"", 0, -1)
core("bz2 stream_feed(str handle)", "_bz2core", "stream_feed", "x", b"", 0, -1)
core("bz2 stream_feed(str action)", "_bz2core", "stream_feed", _bh, b"", "x", -1)
core("bz2 stream_feed(str max)", "_bz2core", "stream_feed", _bh, b"", 0, "x")
core("bz2 stream_feed(int data)", "_bz2core", "stream_feed", _bh, 5, 0, -1)
core("bz2 stream_feed(strided view)", "_bz2core", "stream_feed", _bh, memoryview(b"abcdef")[::2], 0, -1)
core("bz2 stream_feed(garbage)", "_bz2core", "stream_feed", _bh, b"this is not a bz2 stream" * 40, 0, -1)
core("bz2 stream_state()", "_bz2core", "stream_state")
core("bz2 stream_state(dead)", "_bz2core", "stream_state", 99999)
core("bz2 stream_state(str)", "_bz2core", "stream_state", "x")
core("bz2 stream_free()", "_bz2core", "stream_free")
core("bz2 stream_free(str)", "_bz2core", "stream_free", "x")

_bdata = bz2.compress(b"some data to compress " * 50)


def _b_truncated():
    bz2.decompress(_bdata[:30])


def _b_corrupt():
    bz2.decompress(_bdata[:20] + b"\xff\xff\xff\xff" + _bdata[24:])


def _b_after_flush():
    c = bz2.BZ2Compressor()
    c.compress(b"abc")
    c.flush()
    c.compress(b"more")


def _b_flush_twice():
    c = bz2.BZ2Compressor()
    c.flush()
    c.flush()


def _b_after_eof():
    d = bz2.BZ2Decompressor()
    d.decompress(_bdata)
    d.decompress(b"more")


def _b_garbage_obj():
    bz2.BZ2Decompressor().decompress(b"\x00" * 1000)


err("bz2.compress()", bz2.compress)
err("bz2.compress(str)", bz2.compress, "text")
err("bz2.compress(bad level)", bz2.compress, b"abc", 99, _msg=True)
err("bz2.decompress(garbage)", bz2.decompress, b"not a bz2 stream at all", _msg=True)
err("bz2.decompress(truncated)", _b_truncated, _msg=True)
err("bz2.decompress(corrupt)", _b_corrupt)
err("bz2.decompress(str)", bz2.decompress, "text")
err("BZ2Compressor(0)", bz2.BZ2Compressor, 0, _msg=True)
err("BZ2Compressor(str)", bz2.BZ2Compressor, "x")
err("BZ2Compressor.compress(str)", bz2.BZ2Compressor().compress, "text")
err("BZ2Compressor.compress(after flush)", _b_after_flush, _msg=True)
err("BZ2Compressor.flush(twice)", _b_flush_twice, _msg=True)
err("BZ2Decompressor.decompress(str)", bz2.BZ2Decompressor().decompress, "text")
err("BZ2Decompressor.decompress(garbage)", _b_garbage_obj, _msg=True)
err("BZ2Decompressor.decompress(after eof)", _b_after_eof, _msg=True)
err("BZ2Decompressor.decompress(str max)", bz2.BZ2Decompressor().decompress, _bdata, "x")
err("BZ2File(bad mode)", bz2.BZ2File, "/tmp/x.bz2", "z")
print(bz2.decompress(_bdata) == b"some data to compress " * 50)

# --- lzma ----------------------------------------------------------------
import lzma

print("== lzma")
_lh = None
try:
    import _lzmacore
    _lh = _lzmacore.decoder(0, -1, None)
except ImportError:
    pass
_LZ2 = (0x21, 6, -1, -1, -1, -1, -1, -1, -1, -1)
core("lzma encoder(3 args)", "_lzmacore", "encoder", 1, 4, 6)
core("lzma encoder(str format)", "_lzmacore", "encoder", "x", 4, 6, None)
core("lzma encoder(str check)", "_lzmacore", "encoder", 1, "x", 6, None)
core("lzma encoder(str preset)", "_lzmacore", "encoder", 1, 4, "x", None)
core("lzma encoder(bad format)", "_lzmacore", "encoder", 99, 4, 6, None)
core("lzma encoder(bad check)", "_lzmacore", "encoder", 1, 99, 6, None)
core("lzma encoder(bad preset)", "_lzmacore", "encoder", 1, 4, 99, None)
core("lzma encoder(int filters)", "_lzmacore", "encoder", 1, 4, 6, 5)
core("lzma encoder(filters of ints)", "_lzmacore", "encoder", 1, 4, 6, [5])
core("lzma encoder(empty filter)", "_lzmacore", "encoder", 1, 4, 6, [()])
core("lzma encoder(long chain)", "_lzmacore", "encoder", 1, 4, 6, [_LZ2] * 5)
core("lzma encoder(str id)", "_lzmacore", "encoder", 1, 4, 6, [("x", 6)])
core("lzma encoder(str field)", "_lzmacore", "encoder", 1, 4, 6, [(0x21, 6, "x", -1, -1, -1, -1, -1, -1, -1)])
core("lzma encoder(filter bad preset)", "_lzmacore", "encoder", 1, 4, 6, [(0x21, 99, -1, -1, -1, -1, -1, -1, -1, -1)])
core("lzma encoder(alone, two filters)", "_lzmacore", "encoder", 2, 4, 6, [_LZ2, _LZ2])
core("lzma encoder(raw, no filters)", "_lzmacore", "encoder", 3, 4, 6, None)
core("lzma encoder(alone bad preset)", "_lzmacore", "encoder", 2, 4, 99, None)
core("lzma decoder(2 args)", "_lzmacore", "decoder", 0, -1)
core("lzma decoder(str format)", "_lzmacore", "decoder", "x", -1, None)
core("lzma decoder(str memlimit)", "_lzmacore", "decoder", 0, "x", None)
core("lzma decoder(bad format)", "_lzmacore", "decoder", 99, -1, None)
core("lzma decoder(raw, no filters)", "_lzmacore", "decoder", 3, -1, None)
core("lzma decoder(int filters)", "_lzmacore", "decoder", 3, -1, 5)
core("lzma decoder(str field)", "_lzmacore", "decoder", 3, -1, [(3, "x")])
core("lzma stream_feed(3 args)", "_lzmacore", "stream_feed", _lh, b"", 0)
core("lzma stream_feed(dead)", "_lzmacore", "stream_feed", 99999, b"", 0, -1)
core("lzma stream_feed(str handle)", "_lzmacore", "stream_feed", "x", b"", 0, -1)
core("lzma stream_feed(str action)", "_lzmacore", "stream_feed", _lh, b"", "x", -1)
core("lzma stream_feed(str max)", "_lzmacore", "stream_feed", _lh, b"", 0, "x")
core("lzma stream_feed(int data)", "_lzmacore", "stream_feed", _lh, 5, 0, -1)
core("lzma stream_feed(strided view)", "_lzmacore", "stream_feed", _lh, memoryview(b"abcdef")[::2], 0, -1)
core("lzma stream_feed(garbage)", "_lzmacore", "stream_feed", _lh, b"this is not an xz stream" * 40, 0, -1)
core("lzma stream_state()", "_lzmacore", "stream_state")
core("lzma stream_state(dead)", "_lzmacore", "stream_state", 99999)
core("lzma stream_state(str)", "_lzmacore", "stream_state", "x")
core("lzma stream_free()", "_lzmacore", "stream_free")
core("lzma stream_free(str)", "_lzmacore", "stream_free", "x")
core("lzma check_is_supported()", "_lzmacore", "check_is_supported")
core("lzma check_is_supported(str)", "_lzmacore", "check_is_supported", "x")
core("lzma encode_filter_props()", "_lzmacore", "encode_filter_props")
core("lzma encode_filter_props(int)", "_lzmacore", "encode_filter_props", 5)
core("lzma encode_filter_props(empty)", "_lzmacore", "encode_filter_props", ())
core("lzma encode_filter_props(str id)", "_lzmacore", "encode_filter_props", ("x", 1))
core("lzma encode_filter_props(str field)", "_lzmacore", "encode_filter_props", (3, "x"))
core("lzma encode_filter_props(bad preset)", "_lzmacore", "encode_filter_props", (0x21, 99, -1, -1, -1, -1, -1, -1, -1, -1))
core("lzma encode_filter_props(bad id)", "_lzmacore", "encode_filter_props", (12345, 0))
core("lzma decode_filter_props(1 arg)", "_lzmacore", "decode_filter_props", 3)
core("lzma decode_filter_props(str id)", "_lzmacore", "decode_filter_props", "x", b"\x00")
core("lzma decode_filter_props(int props)", "_lzmacore", "decode_filter_props", 3, 5)
core("lzma decode_filter_props(strided)", "_lzmacore", "decode_filter_props", 3, memoryview(b"abcdef")[::2])
core("lzma decode_filter_props(bad props)", "_lzmacore", "decode_filter_props", 0x21, b"\xff\xff\xff")
core("lzma decode_filter_props(bad id)", "_lzmacore", "decode_filter_props", 12345, b"\x00")

_ldata = lzma.compress(b"some data to compress " * 50)


def _l_corrupt():
    lzma.decompress(_ldata[:30] + b"\xff\xff\xff\xff" + _ldata[34:])


def _l_after_flush():
    c = lzma.LZMACompressor()
    c.compress(b"abc")
    c.flush()
    c.compress(b"more")


def _l_flush_twice():
    c = lzma.LZMACompressor()
    c.flush()
    c.flush()


def _l_after_eof():
    d = lzma.LZMADecompressor()
    d.decompress(_ldata)
    d.decompress(b"more")


def _l_garbage_obj():
    lzma.LZMADecompressor().decompress(b"\x01" * 1000)


def _l_memlimit():
    lzma.LZMADecompressor(memlimit=1).decompress(_ldata)


err("lzma.compress()", lzma.compress)
err("lzma.compress(str)", lzma.compress, "text")
err("lzma.compress(bad preset)", lzma.compress, b"abc", preset=99)
err("lzma.compress(bad format)", lzma.compress, b"abc", format=99, _msg=True)
err("lzma.compress(bad check)", lzma.compress, b"abc", check=99)
err("lzma.compress(raw, no filters)", lzma.compress, b"abc", format=lzma.FORMAT_RAW, _msg=True)
err("lzma.compress(filters=int)", lzma.compress, b"abc", filters=5)
err("lzma.compress(filter without id)", lzma.compress, b"abc", filters=[{}], _msg=True)
err("lzma.compress(filter bad id)", lzma.compress, b"abc", filters=[{"id": 12345}], _msg=True)
err("lzma.compress(filter bad option)", lzma.compress, b"abc", filters=[{"id": lzma.FILTER_LZMA2, "nope": 1}])
err("lzma.compress(filter str option)", lzma.compress, b"abc", filters=[{"id": lzma.FILTER_LZMA2, "lc": "x"}])
err("lzma.compress(long chain)", lzma.compress, b"abc", filters=[{"id": lzma.FILTER_DELTA}] * 5)
err("lzma.compress(preset and filters)", lzma.compress, b"abc", preset=6, filters=[{"id": lzma.FILTER_LZMA2}], _msg=True)
err("lzma.decompress(garbage)", lzma.decompress, b"not an xz stream at all, no", _msg=True)
err("lzma.decompress(corrupt)", _l_corrupt)
err("lzma.decompress(str)", lzma.decompress, "text")
err("lzma.decompress(bad format)", lzma.decompress, _ldata, format=99, _msg=True)
err("lzma.decompress(raw, no filters)", lzma.decompress, _ldata, format=lzma.FORMAT_RAW, _msg=True)
err("LZMACompressor.compress(str)", lzma.LZMACompressor().compress, "text")
err("LZMACompressor.compress(after flush)", _l_after_flush, _msg=True)
err("LZMACompressor.flush(twice)", _l_flush_twice, _msg=True)
err("LZMADecompressor.decompress(str)", lzma.LZMADecompressor().decompress, "text")
err("LZMADecompressor.decompress(garbage)", _l_garbage_obj, _msg=True)
err("LZMADecompressor.decompress(after eof)", _l_after_eof, _msg=True)
err("LZMADecompressor.decompress(memlimit)", _l_memlimit, _msg=True)
err("LZMADecompressor(memlimit with raw)", lzma.LZMADecompressor, lzma.FORMAT_RAW, 100, _msg=True)
err("_encode_filter_properties(int)", lzma._encode_filter_properties, 5)
err("_encode_filter_properties(no id)", lzma._encode_filter_properties, {}, _msg=True)
err("_decode_filter_properties(bad props)", lzma._decode_filter_properties, lzma.FILTER_LZMA2, b"\xff\xff\xff")
err("_decode_filter_properties(str)", lzma._decode_filter_properties, lzma.FILTER_LZMA2, "x")
print(lzma.decompress(_ldata) == b"some data to compress " * 50)

# --- hashlib and hmac ----------------------------------------------------
import hashlib
import hmac

print("== hashlib")
_hh = _mh = None
try:
    import _hashlibcore
    _hh = _hashlibcore.new("sha256", True)
    _mh = _hashlibcore.hmac_new(b"key", "sha256")
except ImportError:
    pass
core("hc new(1 arg)", "_hashlibcore", "new", "sha256")
core("hc new(int name)", "_hashlibcore", "new", 5, True)
core("hc new(unknown)", "_hashlibcore", "new", "no-such-digest", True)
core("hc update(1 arg)", "_hashlibcore", "update", _hh)
core("hc update(dead)", "_hashlibcore", "update", 99999, b"")
core("hc update(str handle)", "_hashlibcore", "update", "x", b"")
core("hc update(wrong kind)", "_hashlibcore", "update", _mh, b"")
core("hc update(str data)", "_hashlibcore", "update", _hh, "text")
core("hc update(int data)", "_hashlibcore", "update", _hh, 5)
core("hc digest()", "_hashlibcore", "digest")
core("hc digest(dead)", "_hashlibcore", "digest", 99999)
core("hc digest(str)", "_hashlibcore", "digest", "x")
core("hc digest(wrong kind)", "_hashlibcore", "digest", _mh)
core("hc xof_digest(1 arg)", "_hashlibcore", "xof_digest", _hh)
core("hc xof_digest(dead)", "_hashlibcore", "xof_digest", 99999, 8)
core("hc xof_digest(str length)", "_hashlibcore", "xof_digest", _hh, "x")
core("hc xof_digest(negative)", "_hashlibcore", "xof_digest", _hh, -1)
core("hc xof_digest(not an xof)", "_hashlibcore", "xof_digest", _hh, 8)
core("hc copy()", "_hashlibcore", "copy")
core("hc copy(dead)", "_hashlibcore", "copy", 99999)
core("hc copy(wrong kind)", "_hashlibcore", "copy", _mh)
core("hc free()", "_hashlibcore", "free")
core("hc free(str)", "_hashlibcore", "free", "x")
core("hc info()", "_hashlibcore", "info")
core("hc info(dead)", "_hashlibcore", "info", 99999)
core("hc info(str)", "_hashlibcore", "info", "x")
core("hc pbkdf2(4 args)", "_hashlibcore", "pbkdf2", "sha256", b"p", b"s", 1)
core("hc pbkdf2(int name)", "_hashlibcore", "pbkdf2", 5, b"p", b"s", 1, 16)
core("hc pbkdf2(unknown)", "_hashlibcore", "pbkdf2", "nope", b"p", b"s", 1, 16)
core("hc pbkdf2(str password)", "_hashlibcore", "pbkdf2", "sha256", "p", b"s", 1, 16)
core("hc pbkdf2(str salt)", "_hashlibcore", "pbkdf2", "sha256", b"p", "s", 1, 16)
core("hc pbkdf2(str iterations)", "_hashlibcore", "pbkdf2", "sha256", b"p", b"s", "x", 16)
core("hc pbkdf2(zero iterations)", "_hashlibcore", "pbkdf2", "sha256", b"p", b"s", 0, 16)
core("hc pbkdf2(str dklen)", "_hashlibcore", "pbkdf2", "sha256", b"p", b"s", 1, "x")
core("hc pbkdf2(zero dklen)", "_hashlibcore", "pbkdf2", "sha256", b"p", b"s", 1, 0)
core("hc scrypt(6 args)", "_hashlibcore", "scrypt", b"p", b"s", 2, 1, 1, 0)
core("hc scrypt(str password)", "_hashlibcore", "scrypt", "p", b"s", 2, 1, 1, 0, 16)
core("hc scrypt(str salt)", "_hashlibcore", "scrypt", b"p", "s", 2, 1, 1, 0, 16)
core("hc scrypt(str n)", "_hashlibcore", "scrypt", b"p", b"s", "x", 1, 1, 0, 16)
core("hc scrypt(negative r)", "_hashlibcore", "scrypt", b"p", b"s", 2, -1, 1, 0, 16)
core("hc scrypt(str dklen)", "_hashlibcore", "scrypt", b"p", b"s", 2, 1, 1, 0, "x")
core("hc scrypt(n not a power of two)", "_hashlibcore", "scrypt", b"p", b"s", 3, 1, 1, 0, 16)
core("hc scrypt(zero dklen)", "_hashlibcore", "scrypt", b"p", b"s", 2, 1, 1, 0, 0)
core("hc hmac_new(1 arg)", "_hashlibcore", "hmac_new", b"k")
core("hc hmac_new(str key)", "_hashlibcore", "hmac_new", "k", "sha256")
core("hc hmac_new(int name)", "_hashlibcore", "hmac_new", b"k", 5)
core("hc hmac_new(unknown)", "_hashlibcore", "hmac_new", b"k", "nope")
core("hc hmac_update(1 arg)", "_hashlibcore", "hmac_update", _mh)
core("hc hmac_update(dead)", "_hashlibcore", "hmac_update", 99999, b"")
core("hc hmac_update(wrong kind)", "_hashlibcore", "hmac_update", _hh, b"")
core("hc hmac_update(str data)", "_hashlibcore", "hmac_update", _mh, "text")
core("hc hmac_digest()", "_hashlibcore", "hmac_digest")
core("hc hmac_digest(dead)", "_hashlibcore", "hmac_digest", 99999)
core("hc hmac_digest(wrong kind)", "_hashlibcore", "hmac_digest", _hh)
core("hc hmac_copy()", "_hashlibcore", "hmac_copy")
core("hc hmac_copy(dead)", "_hashlibcore", "hmac_copy", 99999)
core("hc hmac_copy(wrong kind)", "_hashlibcore", "hmac_copy", _hh)
core("hc hmac_info()", "_hashlibcore", "hmac_info")
core("hc hmac_info(str)", "_hashlibcore", "hmac_info", "x")
core("hc hmac_free()", "_hashlibcore", "hmac_free")
core("hc compare_digest(1 arg)", "_hashlibcore", "compare_digest", b"a")
core("hc compare_digest(str, bytes)", "_hashlibcore", "compare_digest", "a", b"a")
core("hc compare_digest(bytes, int)", "_hashlibcore", "compare_digest", b"a", 5)

err("hashlib.new()", hashlib.new)
err("hashlib.new(unknown)", hashlib.new, "no-such-digest")
err("hashlib.new(int)", hashlib.new, 5)
err("hashlib.sha256(str)", hashlib.sha256, "text")
err("hashlib.sha256(int)", hashlib.sha256, 5)
err("sha256().update(str)", hashlib.sha256().update, "text")
err("sha256().update()", hashlib.sha256().update)
err("md5().update(None)", hashlib.md5().update, None)
err("shake_128().digest()", hashlib.shake_128().digest)
err("shake_128().hexdigest(str)", hashlib.shake_128().hexdigest, "x")
err("pbkdf2_hmac()", hashlib.pbkdf2_hmac)
err("pbkdf2_hmac(unknown)", hashlib.pbkdf2_hmac, "nope", b"p", b"s", 1)
err("pbkdf2_hmac(str password)", hashlib.pbkdf2_hmac, "sha256", "p", b"s", 1)
err("pbkdf2_hmac(str salt)", hashlib.pbkdf2_hmac, "sha256", b"p", "s", 1)
err("pbkdf2_hmac(zero iterations)", hashlib.pbkdf2_hmac, "sha256", b"p", b"s", 0, _msg=True)
err("pbkdf2_hmac(negative dklen)", hashlib.pbkdf2_hmac, "sha256", b"p", b"s", 1, -1, _msg=True)
err("pbkdf2_hmac(str iterations)", hashlib.pbkdf2_hmac, "sha256", b"p", b"s", "x")
err("scrypt(no salt)", hashlib.scrypt, b"p")
err("scrypt(str password)", hashlib.scrypt, "p", salt=b"s", n=2, r=1, p=1)
err("scrypt(n not a power of two)", hashlib.scrypt, b"p", salt=b"s", n=3, r=1, p=1, _msg=True)
err("scrypt(str n)", hashlib.scrypt, b"p", salt=b"s", n="x", r=1, p=1)
err("hmac.new(no digestmod)", hmac.new, b"key")
err("hmac.new(str key)", hmac.new, "key", b"m", "sha256")
err("hmac.new(unknown digest)", hmac.new, b"key", b"m", "no-such-digest")
err("hmac.new(str msg)", hmac.new, b"key", "m", "sha256")
err("hmac update(str)", hmac.new(b"key", b"m", "sha256").update, "text")
err("hmac.digest(str key)", hmac.digest, "key", b"m", "sha256")
err("hmac.digest(unknown digest)", hmac.digest, b"key", b"m", "no-such-digest")
err("compare_digest(str, bytes)", hmac.compare_digest, "a", b"a")
err("compare_digest(int, int)", hmac.compare_digest, 1, 1)
err("compare_digest(non-ascii str)", hmac.compare_digest, "\xe9", "\xe9")
err("compare_digest(1 arg)", hmac.compare_digest, b"a")
print(hashlib.sha256(b"abc").hexdigest()[:16], hmac.new(b"k", b"m", "sha256").hexdigest()[:16],
      hashlib.pbkdf2_hmac("sha256", b"p", b"s", 2, 8).hex(), hmac.compare_digest(b"a", b"a"))

# --- math ----------------------------------------------------------------
import math

print("== math")


class RaisesIter:
    def __iter__(self):
        raise ValueError("from __iter__")


class RaisesNext:
    def __iter__(self):
        return self

    def __next__(self):
        raise KeyError("from __next__")


class RaisesFloor:
    def __floor__(self):
        raise ValueError("from __floor__")

    def __trunc__(self):
        raise ValueError("from __trunc__")


_BIG = 10 ** 400
err("sqrt()", math.sqrt, _msg=True)
err("sqrt(2 args)", math.sqrt, 1, 2, _msg=True)
err("sqrt(str)", math.sqrt, "x", _msg=True)
err("sqrt(-1)", math.sqrt, -1, _msg=True)
err("sqrt(__float__ raises)", math.sqrt, RaisesFloat(), _msg=True)
err("sqrt(__index__ raises)", math.sqrt, RaisesIndex(), _msg=True)
err("sqrt(huge int)", math.sqrt, _BIG, _msg=True)
err("exp(overflow)", math.exp, 1e6, _msg=True)
err("cosh(overflow)", math.cosh, 1e6, _msg=True)
err("acos(2)", math.acos, 2, _msg=True)
err("gamma(-1)", math.gamma, -1, _msg=True)
err("cbrt(str)", math.cbrt, "x", _msg=True)
err("atan2(1 arg)", math.atan2, 1, _msg=True)
err("atan2(str, 1)", math.atan2, "x", 1, _msg=True)
err("atan2(1, str)", math.atan2, 1, "x", _msg=True)
err("atan2(__float__ raises, 1)", math.atan2, RaisesFloat(), 1, _msg=True)
err("atan2(1, __float__ raises)", math.atan2, 1, RaisesFloat(), _msg=True)
err("pow(overflow)", math.pow, 1e300, 1e300, _msg=True)
err("fmod(1, 0)", math.fmod, 1, 0, _msg=True)
err("remainder(1, 0)", math.remainder, 1, 0, _msg=True)
err("copysign(1 arg)", math.copysign, 1, _msg=True)
err("nextafter(str)", math.nextafter, "x", 1, _msg=True)
err("floor()", math.floor, _msg=True)
err("floor(str)", math.floor, "x", _msg=True)
err("floor(__floor__ raises)", math.floor, RaisesFloor(), _msg=True)
err("floor(inf)", math.floor, float("inf"), _msg=True)
err("floor(__float__ raises)", math.floor, RaisesFloat(), _msg=True)
err("ceil(nan)", math.ceil, float("nan"), _msg=True)
err("trunc()", math.trunc, _msg=True)
err("trunc(str)", math.trunc, "x", _msg=True)
err("trunc(__trunc__ raises)", math.trunc, RaisesFloor(), _msg=True)
err("modf(str)", math.modf, "x", _msg=True)
err("modf()", math.modf, _msg=True)
err("frexp(str)", math.frexp, "x", _msg=True)
err("degrees(str)", math.degrees, "x", _msg=True)
err("radians(__float__ raises)", math.radians, RaisesFloat(), _msg=True)
err("gcd(1, str)", math.gcd, 1, "x", _msg=True)
err("gcd(float)", math.gcd, 1.5, _msg=True)
err("lcm(big, str)", math.lcm, _BIG, "x", _msg=True)
err("isqrt()", math.isqrt, _msg=True)
err("isqrt(-1)", math.isqrt, -1, _msg=True)
err("isqrt(-big)", math.isqrt, -_BIG, _msg=True)
err("isqrt(str)", math.isqrt, "x", _msg=True)
err("factorial()", math.factorial, _msg=True)
err("factorial(-1)", math.factorial, -1, _msg=True)
err("factorial(-big)", math.factorial, -_BIG, _msg=True)
err("factorial(float)", math.factorial, 1.5, _msg=True)
err("factorial(huge)", math.factorial, _BIG)
err("comb(1 arg)", math.comb, 1, _msg=True)
err("comb(-1, 1)", math.comb, -1, 1, _msg=True)
err("comb(big, -1)", math.comb, _BIG, -1, _msg=True)
err("comb(str, 1)", math.comb, "x", 1, _msg=True)
err("comb(big, str)", math.comb, _BIG, "x", _msg=True)
err("perm()", math.perm)
err("perm(-big, 1)", math.perm, -_BIG, 1, _msg=True)
err("perm(big, -1)", math.perm, _BIG, -1, _msg=True)
err("perm(str)", math.perm, "x", _msg=True)
err("perm(big, str)", math.perm, _BIG, "x", _msg=True)
err("ulp()", math.ulp, _msg=True)
err("ulp(str)", math.ulp, "x", _msg=True)
err("ulp(__float__ raises)", math.ulp, RaisesFloat(), _msg=True)
err("prod()", math.prod, _msg=True)
err("prod(int)", math.prod, 1, _msg=True)
err("prod(2 positional)", math.prod, [1], 2, _msg=True)
err("prod(3 positional)", math.prod, [1], 2, 3, _msg=True)
err("prod(__iter__ raises)", math.prod, RaisesIter(), _msg=True)
err("prod(__next__ raises)", math.prod, RaisesNext(), _msg=True)
err_type("prod(unmultipliable)", math.prod, [_BIG, "x", []])
err("prod(bad keyword)", math.prod, [1, 2], begin=1)
err_type("prod(start unmultipliable)", math.prod, [_BIG, []], start="x")
err("isclose(1 arg)", math.isclose, 1)
err("isclose(str, 1)", math.isclose, "x", 1)
err("isclose(1, str)", math.isclose, 1, "x")
err("isclose(__float__ raises)", math.isclose, RaisesFloat(), 1, _msg=True)
err("isclose(str rel_tol)", math.isclose, 1, 1, rel_tol="x", _msg=True)
err("isclose(negative abs_tol)", math.isclose, 1, 1, abs_tol=-1.0, _msg=True)
err("isclose(rel_tol __float__ raises)", math.isclose, 1, 1, rel_tol=RaisesFloat(), _msg=True)
err("isclose(bad keyword)", math.isclose, 1, 1, tol=1)
err("dist(1 arg)", math.dist, (1,), _msg=True)
err("dist(lengths differ)", math.dist, (1,), (1, 2), _msg=True)
err("dist(str coordinate)", math.dist, (1.5, 2.5), (1.5, "x"))
err_type("dist(ints)", math.dist, 1, 2)
err_type("dist(__float__ raises)", math.dist, (1.5, RaisesFloat()), (1.5, 2.5), _msg=True)
err_type("dist(__iter__ raises)", math.dist, (1.5,), RaisesIter(), _msg=True)
err("log()", math.log)
err("log(0)", math.log, 0, _msg=True)
err("log(-1)", math.log, -1, _msg=True)
err("log(str)", math.log, "x", _msg=True)
err("log(1, str)", math.log, 1, "x", _msg=True)
err("log(10, 1)", math.log, 10, 1, _msg=True)
err("log(0, 10)", math.log, 0, 10, _msg=True)
err("log(-big)", math.log, -_BIG, _msg=True)
err("log(big, -big)", math.log, _BIG, -_BIG, _msg=True)
err("log(__float__ raises)", math.log, RaisesFloat(), _msg=True)
err("log(2, __float__ raises)", math.log, 2, RaisesFloat(), _msg=True)
err("log(3 args)", math.log, 1, 2, 3)
err("log2(0)", math.log2, 0, _msg=True)
err("log2(-big)", math.log2, -_BIG, _msg=True)
err("log2(str)", math.log2, "x", _msg=True)
err("log10(-big)", math.log10, -_BIG, _msg=True)
err("log10()", math.log10, _msg=True)
err("ldexp(1 arg)", math.ldexp, 1, _msg=True)
err("ldexp(str, 1)", math.ldexp, "x", 1, _msg=True)
err("ldexp(1, float)", math.ldexp, 1, 1.5, _msg=True)
err("ldexp(overflow)", math.ldexp, 1.0, 5000, _msg=True)
err("ldexp(__float__ raises)", math.ldexp, RaisesFloat(), 1, _msg=True)
err("fsum()", math.fsum, _msg=True)
err("fsum(int)", math.fsum, 1, _msg=True)
err("fsum(str item)", math.fsum, [1.5, 2.5, "x"], _msg=True)
err("fsum(overflow)", math.fsum, [1e308, 1e308], _msg=True)
err("fsum(__next__ raises)", math.fsum, RaisesNext(), _msg=True)
err_type("fsum(__float__ raises)", math.fsum, [1.5, 2.5, RaisesFloat()], _msg=True)
err("fsum(__iter__ raises)", math.fsum, RaisesIter(), _msg=True)
err("fsum(huge int item)", math.fsum, [1.5, _BIG], _msg=True)
err("hypot(str)", math.hypot, "x", _msg=True)
err("hypot(1, str)", math.hypot, 1, "x", _msg=True)
err("hypot(1, 2, str)", math.hypot, 1, 2, "x", _msg=True)
err("hypot(__float__ raises, 1)", math.hypot, RaisesFloat(), 1, _msg=True)
err("hypot(1, 2, __float__ raises)", math.hypot, 1, 2, RaisesFloat(), _msg=True)
err("sumprod(1 arg)", math.sumprod, [1], _msg=True)
err("sumprod(int, list)", math.sumprod, 1, [1], _msg=True)
err("sumprod(list, int)", math.sumprod, [1], 1, _msg=True)
err("sumprod(lengths differ)", math.sumprod, [1], [1, 2], _msg=True)
err("sumprod(__next__ raises)", math.sumprod, RaisesNext(), [1], _msg=True)
err("sumprod(unmultipliable)", math.sumprod, [_BIG, []], [_BIG, []])
err("isnan(str)", math.isnan, "x", _msg=True)
err("isinf()", math.isinf, _msg=True)
err("isfinite(__float__ raises)", math.isfinite, RaisesFloat(), _msg=True)
# The two callers of math's keyword binder that are not in math.
err("print(bad keyword)", print, 1, sepp="x", _msg=True)
_mv = memoryview(bytearray(16)).cast("d")
err_type("memoryview[d] = __float__ raises", _mv.__setitem__, 0, RaisesFloat())
print(math.sqrt(4), math.log(_BIG) > 900, math.prod([2, 3], start=2), math.fsum([0.1] * 10),
      math.hypot(3, 4), math.dist((0, 0), (3, 4)), math.isclose(1, 1 + 1e-12), math.perm(5, 2))
