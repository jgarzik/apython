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
