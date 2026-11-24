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
