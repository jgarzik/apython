"""The `_ctypes` module CPython's Lib/ctypes is written against.

CPython's is C (Modules/_ctypes).  This is the object model in Python over
`_ctypescore` (src/modules/ctypes.asm), which supplies only what has to be
machine code: dlopen and dlsym, reading and writing memory at an address,
libffi's prep_cif and call, and the closure trampoline a callback enters
through.  The same split `_zlibcore`/`zlib` and `_iocore`/`_io` use.

Every ctypes instance owns, or borrows, a block of memory at an ADDRESS.  An
owned block is a bytearray -- its buffer does not move while it is not resized
-- and `_ctypescore.addr` tells us where it is.  The type information CPython
keeps in a StgDict (size, alignment, the libffi type, the get and set
functions) is a `_StgInfo` stored in the class's own `__dict__` as `_stg_`.

The layout rules, the keep-alive bookkeeping (`_objects`) and the error
wordings follow Modules/_ctypes/{_ctypes,cfield,stgdict,callproc,callbacks}.c
of CPython 3.12 closely; the function names below say which C function each
mirrors.
"""

import _ctypescore as _core
import _struct
import sys as _sys

__version__ = "1.1.0"

FUNCFLAG_CDECL = 0x1
FUNCFLAG_HRESULT = 0x2
FUNCFLAG_PYTHONAPI = 0x4
FUNCFLAG_USE_ERRNO = 0x8
FUNCFLAG_USE_LASTERROR = 0x10

RTLD_LOCAL = 0
RTLD_GLOBAL = 0x100
_RTLD_NOW = 2

CTYPES_MAX_ARGCOUNT = 1024
SIZEOF_TIME_T = 8

_FFI_DEFAULT_ABI = 2            # FFI_UNIX64
_FFI_TYPE_STRUCT = 13


class ArgumentError(Exception):
    pass


ArgumentError.__module__ = "ctypes"

_read = _core.read
_write = _core.write
_addr = _core.addr


def _sym(name):
    return _core.dlsym(0, name)


_FT = {}
for _n in ("void", "uint8", "sint8", "uint16", "sint16", "uint32", "sint32",
           "uint64", "sint64", "float", "double", "longdouble", "pointer"):
    _FT[_n] = _sym(b"ffi_type_" + _n.encode())
del _n


def _rd_ptr(addr):
    return int.from_bytes(_read(addr, 8), "little")


def _wr_ptr(addr, value):
    _write(addr, (value & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "little"))


class _Block:
    """A zeroed block of memory owned by Python: a bytearray and its address."""
    __slots__ = ("buf", "addr")

    def __init__(self, size):
        # At least 16 zeroed bytes, as CPython's in-object b_value gives a
        # small instance: a lone c_wchar read through a c_wchar_p then finds
        # its terminator, as it does there.
        self.buf = bytearray(size if size > 16 else 16)
        self.addr = _addr(self.buf)


# ---------------------------------------------------------------------------
# The field descriptors (cfield.c): one get and one set function per code.
# `size` is the byte size, or for a bitfield (bits << 16) | bit offset.
# A set function returns what the owner must keep alive, or None.
# ---------------------------------------------------------------------------

def _index(value):
    try:
        return value.__index__()
    except AttributeError:
        raise TypeError("'%s' object cannot be interpreted as an integer"
                        % type(value).__name__) from None


def _make_int(n, signed, swapped):
    order = "big" if swapped else "little"
    nbits = n * 8
    full = (1 << nbits) - 1

    def get(addr, size):
        v = int.from_bytes(_read(addr, n), order)
        bits = size >> 16
        if bits:
            v = (v >> (size & 0xFFFF)) & ((1 << bits) - 1)
            w = bits
        else:
            w = nbits
        if signed and v >> (w - 1):
            v -= 1 << w
        return v

    def set(addr, value, size):
        v = _index(value)
        bits = size >> 16
        if bits:
            ofs = size & 0xFFFF
            m = ((1 << bits) - 1) << ofs
            cur = int.from_bytes(_read(addr, n), order)
            v = (cur & ~m) | ((v << ofs) & m)
        _write(addr, (v & full).to_bytes(n, order))
        return None
    return get, set


def _as_double(value):
    if isinstance(value, float):
        return value
    tp = type(value)
    f = getattr(tp, "__float__", None)
    if f is not None:
        return f(value)
    if hasattr(tp, "__index__"):
        return float(tp.__index__(value))
    raise TypeError("must be real number, not %s" % tp.__name__)


def _make_float(fmt):
    size = _struct.calcsize(fmt)

    def get(addr, sz):
        return _struct.unpack(fmt, _read(addr, size))[0]

    def set(addr, value, sz):
        _write(addr, _struct.pack(fmt, _as_double(value)))
        return None
    return get, set


def _ld_get(addr, size):
    b = _read(addr, 10)
    mant = int.from_bytes(b[:8], "little")
    se = int.from_bytes(b[8:10], "little")
    sign = se >> 15
    exp = se & 0x7FFF
    if exp == 0x7FFF:
        if mant & 0x7FFFFFFFFFFFFFFF:
            v = float("nan")
        else:
            v = float("inf")
    elif exp == 0 and mant == 0:
        v = 0.0
    else:
        import math
        try:
            v = math.ldexp(float(mant), exp - 16383 - 63)
        except OverflowError:
            v = float("inf")
    return -v if sign else v


def _ld_set(addr, value, size):
    import math
    x = _as_double(value)
    sign = 1 if math.copysign(1.0, x) < 0 else 0
    if x != x:
        mant, exp = 0xC000000000000000, 0x7FFF
    elif x in (float("inf"), float("-inf")):
        mant, exp = 0x8000000000000000, 0x7FFF
    elif x == 0:
        mant, exp = 0, 0
    else:
        m, e = math.frexp(abs(x))
        mant = int(m * (1 << 64))
        exp = e - 1 + 16383
    _write(addr, mant.to_bytes(8, "little")
           + ((sign << 15) | exp).to_bytes(2, "little") + bytes(6))
    return None


def _bool_get(addr, size):
    return _read(addr, 1) != b"\x00"


def _bool_set(addr, value, size):
    _write(addr, b"\x01" if value else b"\x00")
    return None


def _vbool_get(addr, size):
    return _read(addr, 2) != b"\x00\x00"


def _vbool_set(addr, value, size):
    _write(addr, b"\xff\xff" if value else b"\x00\x00")
    return None


def _c_get(addr, size):
    return _read(addr, 1)


def _c_set(addr, value, size):
    if isinstance(value, (bytes, bytearray)) and len(value) == 1:
        _write(addr, bytes(value))
        return None
    if isinstance(value, int) and 0 <= value < 256:
        _write(addr, bytes((value,)))
        return None
    raise TypeError("one character bytes, bytearray or integer expected")


def _wchar_decode(raw):
    return raw.decode("utf-32-le", "surrogatepass")


def _wchar_encode(s):
    return s.encode("utf-32-le", "surrogatepass")


def _u_get(addr, size):
    return _wchar_decode(_read(addr, 4))


def _u_set(addr, value, size):
    if not isinstance(value, str):
        raise TypeError("unicode string expected instead of %s instance"
                        % type(value).__name__)
    if len(value) != 1:
        raise TypeError("one character unicode string expected")
    _write(addr, _wchar_encode(value))
    return None


def _s_get(addr, size):
    raw = _read(addr, size)
    i = raw.find(b"\x00")
    return raw if i < 0 else raw[:i]


def _s_set(addr, value, length):
    if not isinstance(value, bytes):
        raise TypeError("expected bytes, %s found" % type(value).__name__)
    i = value.find(b"\x00")
    data = value if i < 0 else value[:i]
    size = len(data)
    if size < length:
        data = data + b"\x00"
    elif size > length:
        raise ValueError("bytes too long (%d, maximum length %d)"
                         % (size, length))
    _write(addr, data)
    return value


def _U_get(addr, size):
    raw = _read(addr, size)
    n = size // 4
    for i in range(n):
        if raw[4 * i:4 * i + 4] == b"\x00\x00\x00\x00":
            n = i
            break
    return _wchar_decode(raw[:4 * n])


def _U_set(addr, value, size):
    if not isinstance(value, str):
        raise TypeError("unicode string expected instead of %s instance"
                        % type(value).__name__)
    length = size // 4
    if len(value) > length:
        raise ValueError("string too long (%d, maximum length %d)"
                         % (len(value), length))
    data = _wchar_encode(value)
    if len(value) < length:
        data += bytes(4)
    _write(addr, data)
    return value


def _z_get(addr, size):
    p = _rd_ptr(addr)
    if not p:
        return None
    return _read(p, _core.strlen(p))


def _z_set(addr, value, size):
    if value is None:
        _wr_ptr(addr, 0)
        return None
    if isinstance(value, bytes):
        _wr_ptr(addr, _addr(value))
        return value
    if isinstance(value, int):
        _wr_ptr(addr, value)
        return None
    raise TypeError("bytes or integer address expected instead of %s instance"
                    % type(value).__name__)


def _Z_get(addr, size):
    p = _rd_ptr(addr)
    if not p:
        return None
    return _wchar_decode(_read(p, 4 * _core.wcslen(p)))


def _Z_set(addr, value, size):
    if value is None:
        _wr_ptr(addr, 0)
        return None
    if isinstance(value, int):
        _wr_ptr(addr, value)
        return None
    if not isinstance(value, str):
        raise TypeError("unicode string or integer address expected instead "
                        "of %s instance" % type(value).__name__)
    keep = _wchar_encode(value) + bytes(4)
    _wr_ptr(addr, _addr(keep))
    return keep


def _P_get(addr, size):
    p = _rd_ptr(addr)
    return p if p else None


def _P_set(addr, value, size):
    if value is None:
        _wr_ptr(addr, 0)
        return None
    if not isinstance(value, int):
        raise TypeError("cannot be converted to pointer")
    _wr_ptr(addr, value)
    return None


# py_object: the memory holds id(obj), and this registry maps it back.  The
# object is kept alive in the owner's _objects too, as in CPython.
_pyobjs = {}


def _O_get(addr, size):
    p = _rd_ptr(addr)
    if not p:
        raise ValueError("PyObject is NULL")
    try:
        return _pyobjs[p]
    except KeyError:
        raise ValueError("PyObject is NULL") from None


def _O_set(addr, value, size):
    k = id(value)
    _pyobjs[k] = value
    _wr_ptr(addr, k)
    return value


# code -> (size, align, ffi type name, get, set, swapped get/set or None)
_FIELDS = {}


def _fd(code, size, align, ffi, get, set, sw=None):
    _FIELDS[code] = (size, align, ffi, get, set, sw)


for _c, _sz, _sg, _ffi in (("b", 1, True, "sint8"), ("B", 1, False, "uint8"),
                           ("h", 2, True, "sint16"), ("H", 2, False, "uint16"),
                           ("i", 4, True, "sint32"), ("I", 4, False, "uint32"),
                           ("l", 8, True, "sint64"), ("L", 8, False, "uint64"),
                           ("q", 8, True, "sint64"), ("Q", 8, False, "uint64")):
    _g, _s = _make_int(_sz, _sg, False)
    _sw = None if _sz == 1 else _make_int(_sz, _sg, True)
    _fd(_c, _sz, _sz, _ffi, _g, _s, _sw)
_fd("f", 4, 4, "float", *_make_float("<f"), sw=_make_float(">f"))
_fd("d", 8, 8, "double", *_make_float("<d"), sw=_make_float(">d"))
_fd("g", 16, 16, "longdouble", _ld_get, _ld_set)
_fd("?", 1, 1, "uint8", _bool_get, _bool_set)
_fd("v", 2, 2, "sint16", _vbool_get, _vbool_set)
_fd("c", 1, 1, "sint8", _c_get, _c_set)
_fd("u", 4, 4, "sint32", _u_get, _u_set)
_fd("z", 8, 8, "pointer", _z_get, _z_set)
_fd("Z", 8, 8, "pointer", _Z_get, _Z_set)
_fd("P", 8, 8, "pointer", _P_get, _P_set)
_fd("O", 8, 8, "pointer", _O_get, _O_set)
del _c, _sz, _sg, _ffi, _g, _s, _sw

_SIMPLE_TYPE_CHARS = "cbBhHiIlLdfuzZqQPXOv?g"


class _StgInfo:
    """CPython's StgDictObject: what an instance of the class looks like."""
    __slots__ = ("size", "align", "length", "ffi", "proto", "getfunc",
                 "setfunc", "kind", "code", "final", "hasbitfield",
                 "hasunion", "haspointer", "ispointer", "argtypes",
                 "restype", "converters", "checker", "flags", "keep",
                 "fieldtypes", "fmt", "shape")

    def __init__(self, kind):
        self.kind = kind
        self.size = 0
        self.align = 0
        self.length = 0
        self.ffi = _FT["sint32"]
        self.proto = None
        self.getfunc = None
        self.setfunc = None
        self.code = None
        self.final = False
        self.hasbitfield = False
        self.hasunion = False
        self.haspointer = False
        self.ispointer = False
        self.argtypes = None
        self.restype = _NULL
        self.converters = None
        self.checker = None
        self.flags = 0
        self.keep = None
        self.fieldtypes = None
        self.fmt = None
        self.shape = ()


class _NullType:
    __slots__ = ()

    def __repr__(self):
        return "<NULL>"


_NULL = _NullType()


def _stg(tp):
    """PyType_stgdict: the class's OWN storage info, or None."""
    try:
        return tp.__dict__.get("_stg_")
    except AttributeError:
        return None


def _set_stg(cls, info):
    type.__setattr__(cls, "_stg_", info)


def _obj_stg(obj):
    return _stg(type(obj))


# ---------------------------------------------------------------------------
# _CData: the instance side, and the keep-alive tree
# ---------------------------------------------------------------------------

class _CData:
    __slots__ = ("_b_ptr_", "_b_owner_", "_b_size_", "_b_length_",
                 "_b_base", "_b_index", "_b_needsfree", "_b_objects",
                 "__weakref__")

    @property
    def _b_base_(self):
        return self._b_base

    @property
    def _b_needsfree_(self):
        return self._b_needsfree

    @property
    def _objects(self):
        o = self._b_objects
        return None if o is _NULL else o

    def __hash__(self):
        raise TypeError("unhashable type")

    def __ctypes_from_outparam__(self):
        return self

    def __reduce__(self):
        info = _obj_stg(self)
        if info.ispointer or info.haspointer:
            raise ValueError("ctypes objects containing pointers cannot be "
                             "pickled")
        return (_unpickle, (type(self),
                            (self.__dict__, _read(self._b_ptr_,
                                                  self._b_size_))))

    def __setstate__(self, d, data):
        if not isinstance(d, dict):
            raise TypeError("expected dict")
        if isinstance(data, str):
            data = data.encode("utf-8")
        n = min(len(data), self._b_size_)
        _write(self._b_ptr_, bytes(data[:n]))
        mydict = self.__dict__
        mydict.update(d)

    def __buffer__(self, flags):
        return _cdata_view(self)


def _unpickle(typ, state):
    obj = typ.__new__(typ)
    obj.__setstate__(*state)
    return obj


def _cdata_view(obj):
    """A memoryview over the object's memory, where Python can make one."""
    root = obj
    while root._b_base is not None and root._b_owner_ is None:
        root = root._b_base
    owner = root._b_owner_
    if isinstance(owner, _Block):
        mv = memoryview(owner.buf)
        start = obj._b_ptr_ - owner.addr
        return mv[start:start + obj._b_size_]
    if isinstance(owner, memoryview):
        start = obj._b_ptr_ - _addr(owner)
        return owner.cast("B")[start:start + obj._b_size_]
    raise TypeError("ctypes object at a foreign address has no buffer here")


def _alloc(cls):
    self = object.__new__(cls)
    if isinstance(self, CFuncPtr):
        self._fp_restype = _NULL
        self._fp_argtypes = None
        self._fp_converters = None
        self._fp_checker = None
        self._fp_errcheck = None
        self._fp_paramflags = None
        self._fp_callable = None
        self._fp_thunk = None
    return self


def _new_instance(cls, info=None):
    """GenericPyCData_new: a zeroed instance owning its memory."""
    if info is None:
        info = _stg(cls)
        if info is None:
            raise TypeError("abstract class")
    info.final = True
    self = _alloc(cls)
    blk = _Block(info.size)
    self._b_owner_ = blk
    self._b_ptr_ = blk.addr
    self._b_size_ = info.size
    self._b_length_ = info.length
    self._b_base = None
    self._b_index = 0
    self._b_needsfree = 1
    self._b_objects = _NULL
    return self


def _at_address(cls, addr, owner=None):
    """PyCData_AtAddress: an instance borrowing memory at addr."""
    info = _stg(cls)
    if info is None:
        raise TypeError("abstract class")
    info.final = True
    self = _alloc(cls)
    self._b_owner_ = owner
    self._b_ptr_ = addr
    self._b_size_ = info.size
    self._b_length_ = info.length
    self._b_base = None
    self._b_index = 0
    self._b_needsfree = 0
    self._b_objects = _NULL
    return self


def _from_base(cls, base, index, addr):
    """PyCData_FromBaseObj: share base's memory, or copy when base is None."""
    info = _stg(cls)
    if info is None:
        raise TypeError("abstract class")
    if base is None:
        self = _new_instance(cls, info)
        if info.size:
            _write(self._b_ptr_, _read(addr, info.size))
        self._b_index = index
        return self
    info.final = True
    self = _alloc(cls)
    self._b_owner_ = None
    self._b_ptr_ = addr
    self._b_size_ = info.size
    self._b_length_ = info.length
    self._b_base = base
    self._b_index = index
    self._b_needsfree = 0
    self._b_objects = _NULL
    return self


def _container(self):
    while self._b_base is not None:
        self = self._b_base
    if self._b_objects is _NULL:
        self._b_objects = {} if self._b_length_ else None
    return self


def _keeped(self):
    return _container(self)._b_objects


def _unique_key(target, index):
    key = "%x" % (index & 0xFFFFFFFF)
    while target._b_base is not None:
        key += ":%x" % (target._b_index & 0xFFFFFFFF)
        target = target._b_base
    return key


def _keepref(target, index, keep):
    if keep is None:
        return
    ob = _container(target)
    if type(ob._b_objects) is not dict:
        ob._b_objects = keep
        return
    ob._b_objects[_unique_key(target, index)] = keep


def _simple_instance(tp):
    """_ctypes_simple_instance: a SUBCLASS of c_int and the like."""
    return isinstance(tp, PyCSimpleType) and tp.__base__ is not _SimpleCData


def _cdata_get(tp, getfunc, src, index, size, addr):
    """PyCData_get."""
    if getfunc is not None:
        return getfunc(addr, size)
    info = _stg(tp)
    if info is not None and info.getfunc is not None \
            and not _simple_instance(tp):
        return info.getfunc(addr, size)
    return _from_base(tp, src, index, addr)


def _cdata_set_inner(dst, tp, setfunc, value, size, addr):
    """_PyCData_set: returns what the destination has to keep."""
    if setfunc is not None:
        return setfunc(addr, value, size)
    if not isinstance(value, _CData):
        info = _stg(tp)
        if info is not None and info.setfunc is not None:
            return info.setfunc(addr, value, size)
        if isinstance(value, tuple):
            try:
                ob = tp(*value)
            except Exception as e:
                raise RuntimeError("(%s) %s: %s"
                                   % (tp.__name__, type(e).__name__, e)) \
                    from None
            return _cdata_set_inner(dst, tp, setfunc, ob, size, addr)
        if value is None and isinstance(tp, PyCPointerType):
            _wr_ptr(addr, 0)
            return None
        raise TypeError("expected %s instance, got %s"
                        % (tp.__name__, type(value).__name__))
    if isinstance(value, tp):
        _write(addr, _read(value._b_ptr_, size))
        return _keeped(value)
    if isinstance(tp, PyCPointerType) and isinstance(value, Array):
        if _obj_stg(value).proto is not _stg(tp).proto:
            raise TypeError("incompatible types, %s instance instead of %s "
                            "instance" % (type(value).__name__, tp.__name__))
        _wr_ptr(addr, value._b_ptr_)
        return (_keeped(value), value)
    raise TypeError("incompatible types, %s instance instead of %s instance"
                    % (type(value).__name__, tp.__name__))


def _cdata_set(dst, tp, setfunc, value, index, size, addr):
    """PyCData_set."""
    if not isinstance(dst, _CData):
        raise TypeError("not a ctype instance")
    keep = _cdata_set_inner(dst, tp, setfunc, value, size, addr)
    _keepref(dst, index, keep)


# ---------------------------------------------------------------------------
# The parameter object byref() and from_param() answer (PyCArgObject)
# ---------------------------------------------------------------------------

class CArgObject:
    __slots__ = ("_tag", "_ffi", "_val", "_obj", "_keep", "__weakref__")

    def __init__(self, tag, ffi, val, obj, keep=None):
        self._tag = tag
        self._ffi = ffi
        self._val = val
        self._obj = obj
        self._keep = keep

    def _ival(self):
        return int.from_bytes(self._val[:8], "little")

    def __repr__(self):
        t = self._tag
        if t in "bBhHiIlLqQ":
            n = _FIELDS[t][0]
            v = int.from_bytes(self._val[:n], "little",
                               signed=t.islower())
            return "<cparam '%s' (%d)>" % (t, v)
        if t in "df":
            v = _struct.unpack("<" + t, self._val[:_FIELDS[t][0]])[0]
            return "<cparam '%s' (%r)>" % (t, v)
        if t == "c":
            b = self._val[0]
            if 32 <= b < 127:
                return "<cparam '%s' ('%c')>" % (t, b)
            return "<cparam '%s' ('\\x%02x')>" % (t, b)
        if t in "zZP":
            return "<cparam '%s' (%#x)>" % (t, self._ival())
        return "<cparam '%s' at %#x>" % (t, id(self))


def _carg_from_setfunc(tag, code, value):
    size, align, ffi, get, set, sw = _FIELDS[code]
    tmp = _Block(16)
    keep = set(tmp.addr, value, 0)
    return CArgObject(tag, _FT[ffi], bytes(tmp.buf[:max(size, 8)]), keep)


# ---------------------------------------------------------------------------
# The metatypes and the class-level methods every one of them has
# ---------------------------------------------------------------------------

_bootstrapping = True


class _CDataType(type):
    """The methods CPython's CDataType_methods gives every metatype."""

    def from_address(cls, address):
        if not isinstance(address, int):
            raise TypeError("integer expected")
        _sys.audit("ctypes.cdata", address)
        return _at_address(cls, address)

    def from_buffer(cls, obj, offset=0):
        info = _stg(cls)
        if info is None:
            raise TypeError("abstract class")
        addr, length, readonly, keep = _get_buffer(obj, True)
        if readonly:
            raise TypeError("underlying buffer is not writable")
        if offset < 0:
            raise ValueError("offset cannot be negative")
        if info.size > length - offset:
            raise ValueError("Buffer size too small (%d instead of at least "
                             "%d bytes)" % (length, info.size + offset))
        _sys.audit("ctypes.cdata/buffer", addr, length, offset)
        result = _at_address(cls, addr + offset,
                             keep if isinstance(keep, memoryview) else None)
        _keepref(result, -1, keep)
        return result

    def from_buffer_copy(cls, obj, offset=0):
        info = _stg(cls)
        if info is None:
            raise TypeError("abstract class")
        addr, length, readonly, keep = _get_buffer(obj, False)
        if offset < 0:
            raise ValueError("offset cannot be negative")
        if info.size > length - offset:
            raise ValueError("Buffer size too small (%d instead of at least "
                             "%d bytes)" % (length, info.size + offset))
        _sys.audit("ctypes.cdata/buffer", addr, length, offset)
        result = _new_instance(cls, info)
        if info.size:
            _write(result._b_ptr_, _read(addr + offset, info.size))
        return result

    def in_dll(cls, dll, name):
        _sys.audit("ctypes.dlsym", (dll, name))
        handle = dll._handle
        if not isinstance(handle, int):
            raise TypeError("the _handle attribute of the second argument "
                            "must be an integer")
        _core.dlerror()
        address = _core.dlsym(handle, name.encode())
        if address:
            return _at_address(cls, address)
        err = _core.dlerror()
        if err:
            raise ValueError(err)
        raise ValueError("symbol '%s' not found" % name)

    def from_param(cls, value):
        return _cdatatype_from_param(cls, value)

    def __mul__(cls, length):
        if not isinstance(length, int):
            return NotImplemented
        if length < 0:
            raise ValueError("Array length must be >= 0, not %d" % length)
        return _array_type_from_ctype(cls, length)

    __rmul__ = __mul__


def _cdatatype_from_param(cls, value):
    if isinstance(value, cls):
        return value
    if isinstance(value, CArgObject):
        info = _stg(cls)
        ob = value._obj
        if info is not None and ob is not None and info.proto is not None \
                and isinstance(info.proto, type) and isinstance(ob, info.proto):
            return value
        name = type(ob).__name__ if ob is not None else "???"
        raise TypeError("expected %s instance instead of pointer to %s"
                        % (cls.__name__, name))
    as_parameter = getattr(value, "_as_parameter_", _NULL)
    if as_parameter is not _NULL:
        return _cdatatype_from_param(cls, as_parameter)
    raise TypeError("expected %s instance instead of %s"
                    % (cls.__name__, type(value).__name__))


def _get_buffer(obj, writable):
    """(address, length, readonly, keep) for anything with a buffer."""
    if isinstance(obj, _CData):
        return obj._b_ptr_, obj._b_size_, False, obj
    mv = memoryview(obj)
    if writable and not mv.c_contiguous:
        raise TypeError("underlying buffer is not C contiguous")
    if not mv.c_contiguous:
        mv = memoryview(mv.tobytes())
    if mv.ndim != 1 or mv.format != "B":
        try:
            mv = mv.cast("B")
        except (TypeError, ValueError):
            pass
    length = mv.nbytes
    addr = _addr(mv) if length else 0
    return addr, length, mv.readonly, mv


# ---- simple types --------------------------------------------------------

class PyCSimpleType(_CDataType):

    def __new__(mcls, name, bases, ns, **kw):
        cls = super().__new__(mcls, name, bases, ns, **kw)
        if _bootstrapping:
            return cls
        proto = getattr(cls, "_type_", _NULL)
        if proto is _NULL:
            raise AttributeError("class must define a '_type_' attribute")
        if not isinstance(proto, str):
            raise TypeError("class must define a '_type_' string attribute")
        if len(proto) != 1:
            raise ValueError("class must define a '_type_' attribute which "
                             "must be a string of length 1")
        if proto not in _SIMPLE_TYPE_CHARS:
            raise AttributeError(
                "class must define a '_type_' attribute which must be\n"
                "a single character string containing one of '%s'."
                % _SIMPLE_TYPE_CHARS)
        fd = _FIELDS.get(proto)
        if fd is None:
            raise ValueError("_type_ '%s' not supported" % proto)
        info = _simple_info(proto, fd, False)
        _set_stg(cls, info)
        if cls.__base__ is _SimpleCData:
            meth = _SPECIAL_FROM_PARAM.get(proto)
            if proto in "zZPO":
                info.ispointer = True
            if meth is not None:
                type.__setattr__(cls, "from_param", classmethod(meth))
        if mcls is PyCSimpleType and fd[5] is not None:
            swapped = type.__new__(mcls, name + "_be", bases, dict(ns))
            sinfo = _simple_info(proto, fd, True)
            _set_stg(swapped, sinfo)
            type.__setattr__(cls, "__ctype_be__", swapped)
            type.__setattr__(cls, "__ctype_le__", cls)
            type.__setattr__(swapped, "__ctype_le__", cls)
            type.__setattr__(swapped, "__ctype_be__", swapped)
        return cls

    def from_param(cls, value):
        if isinstance(value, cls):
            return value
        info = _stg(cls)
        if info is None:
            raise TypeError("abstract class")
        try:
            return _carg_from_setfunc(info.code, info.code, value)
        except Exception as exc:
            as_parameter = getattr(value, "_as_parameter_", _NULL)
            if as_parameter is not _NULL:
                return cls.from_param(as_parameter)
            raise exc


def _simple_info(code, fd, swapped):
    size, align, ffi, get, set, sw = fd
    info = _StgInfo("simple")
    info.size = size
    info.align = align
    info.ffi = _FT[ffi]
    info.code = code
    info.proto = code
    if swapped:
        info.getfunc, info.setfunc = sw
    else:
        info.getfunc, info.setfunc = get, set
    return info


def _c_char_p_from_param(cls, value):
    if value is None:
        return None
    if isinstance(value, bytes):
        return _carg_from_setfunc("z", "z", value)
    if isinstance(value, cls):
        return value
    if isinstance(value, (Array, _Pointer)):
        p = _obj_stg(value).proto
        pi = _stg(p) if p is not None else None
        if pi is not None and pi.code == "c":
            return value
    if isinstance(value, CArgObject):
        oi = _obj_stg(value._obj) if value._obj is not None else None
        if oi is not None and oi.code == "c":
            return value
    as_parameter = getattr(value, "_as_parameter_", _NULL)
    if as_parameter is not _NULL:
        return _c_char_p_from_param(cls, as_parameter)
    raise TypeError("wrong type")


def _c_wchar_p_from_param(cls, value):
    if value is None:
        return None
    if isinstance(value, str):
        return _carg_from_setfunc("Z", "Z", value)
    if isinstance(value, cls):
        return value
    if isinstance(value, (Array, _Pointer)):
        p = _obj_stg(value).proto
        pi = _stg(p) if p is not None else None
        if pi is not None and pi.code == "u":
            return value
    if isinstance(value, CArgObject):
        oi = _obj_stg(value._obj) if value._obj is not None else None
        if oi is not None and oi.code == "u":
            return value
    as_parameter = getattr(value, "_as_parameter_", _NULL)
    if as_parameter is not _NULL:
        return _c_wchar_p_from_param(cls, as_parameter)
    raise TypeError("wrong type")


def _c_void_p_from_param(cls, value):
    if value is None:
        return None
    if isinstance(value, int):
        return _carg_from_setfunc("P", "P", value)
    if isinstance(value, bytes):
        return _carg_from_setfunc("z", "z", value)
    if isinstance(value, str):
        return _carg_from_setfunc("Z", "Z", value)
    if isinstance(value, cls):
        return value
    if isinstance(value, (Array, _Pointer)):
        return value
    if isinstance(value, CArgObject) and value._tag == "P":
        return value
    if isinstance(value, CFuncPtr):
        return CArgObject("P", _FT["pointer"], _read(value._b_ptr_, 8),
                          value)
    info = _obj_stg(value) if isinstance(value, _CData) else None
    if info is not None and info.code in ("z", "Z"):
        return CArgObject("Z", _FT["pointer"], _read(value._b_ptr_, 8),
                          value)
    as_parameter = getattr(value, "_as_parameter_", _NULL)
    if as_parameter is not _NULL:
        return _c_void_p_from_param(cls, as_parameter)
    raise TypeError("wrong type")


_SPECIAL_FROM_PARAM = {"z": _c_char_p_from_param, "Z": _c_wchar_p_from_param,
                       "P": _c_void_p_from_param}


# ---- structures and unions -----------------------------------------------

class CField:
    """A Structure/Union member: a data descriptor at an offset."""
    __slots__ = ("_offset", "_size", "_index", "_proto", "_getfunc",
                 "_setfunc", "_anonymous")

    def __new__(cls, *args, **kw):
        raise TypeError("cannot create '_ctypes.CField' instances")

    @property
    def offset(self):
        return self._offset

    @property
    def size(self):
        return self._size

    def __get__(self, inst, owner=None):
        if inst is None:
            return self
        if not isinstance(inst, _CData):
            raise TypeError("not a ctype instance")
        return _cdata_get(self._proto, self._getfunc, inst, self._index,
                          self._size, inst._b_ptr_ + self._offset)

    def __set__(self, inst, value):
        if not isinstance(inst, _CData):
            raise TypeError("not a ctype instance")
        _cdata_set(inst, self._proto, self._setfunc, value, self._index,
                   self._size, inst._b_ptr_ + self._offset)

    def __delete__(self, inst):
        raise TypeError("can't delete attribute")

    def __repr__(self):
        bits = self._size >> 16
        size = self._size & 0xFFFF
        name = self._proto.__name__
        if bits:
            return "<Field type=%s, ofs=%d:%d, bits=%d>" % (
                name, self._offset, size, bits)
        return "<Field type=%s, ofs=%d, size=%d>" % (name, self._offset, size)


CField.__module__ = "_ctypes"
CField.__qualname__ = CField.__name__ = "CField"


def _new_cfield():
    f = object.__new__(CField)
    f._anonymous = False
    f._getfunc = None
    f._setfunc = None
    return f


_BITFIELD_OK = ("uint8", "uint16", "uint32", "sint64", "uint64")
_BITFIELD_SIGNED = ("sint8", "sint16", "sint32")


def _ffi_kind(info):
    for k, v in _FT.items():
        if v == info.ffi:
            return k
    return None


def _make_ffi_struct(size, align, elements):
    """An ffi_type of FFI_TYPE_STRUCT, its elements NULL-terminated."""
    n = len(elements)
    blk = _Block(24 + 8 * (n + 1))
    b = blk.buf
    b[0:8] = size.to_bytes(8, "little")
    b[8:10] = align.to_bytes(2, "little")
    b[10:12] = _FFI_TYPE_STRUCT.to_bytes(2, "little")
    b[16:24] = (blk.addr + 24).to_bytes(8, "little")
    for i, e in enumerate(elements):
        b[24 + 8 * i:32 + 8 * i] = e.to_bytes(8, "little")
    return blk


def _flat_ffi(tp):
    """The ffi element list an array of tp contributes in a small struct."""
    info = _stg(tp)
    if isinstance(tp, PyCArrayType):
        return _flat_ffi(info.proto) * info.length
    return [info.ffi]


def _update_stgdict(cls, fields, isstruct):
    """PyCStructUnionType_update_stgdict, then MakeAnonFields."""
    if fields is None:
        return
    big_endian = hasattr(cls, "_swappedbytes_")
    pack = getattr(cls, "_pack_", _NULL)
    if pack is not _NULL:
        try:
            pack = _index(pack)
        except TypeError:
            raise ValueError("_pack_ must be a non-negative integer") from None
        if pack < 0 or pack > 0x7FFFFFFF:
            raise ValueError("_pack_ must be a non-negative integer")
    else:
        pack = 0
    try:
        fields = list(fields)
    except TypeError:
        raise TypeError("'_fields_' must be a sequence of pairs") from None
    info = _stg(cls)
    if info is None:
        raise TypeError("ctypes state is not initialized")
    if info.final:
        raise AttributeError("_fields_ is final")
    base = cls.__base__
    basedict = _stg(base) if isinstance(base, (PyCStructType, UnionType)) \
        else None
    if basedict is not None:
        info.hasunion = info.hasunion or basedict.hasunion
        info.hasbitfield = info.hasbitfield or basedict.hasbitfield
    if not isstruct:
        info.hasunion = True
    if basedict is not None:
        size = offset = basedict.size
        align = basedict.align
        union_size = 0
        total_align = align if align else 1
        elements = list(basedict.fieldtypes or ())
    else:
        offset = size = align = union_size = 0
        total_align = 1
        elements = []
    ffi_ofs = len(elements)
    field_size = 0
    bitofs = 0
    arrays_seen = False
    fieldtypes = []
    for i, pair in enumerate(fields):
        if not isinstance(pair, tuple) or not 2 <= len(pair) <= 3 \
                or not isinstance(pair[0], str):
            raise TypeError("'_fields_' must be a sequence of (name, C type) "
                            "pairs")
        name, desc = pair[0], pair[1]
        if isinstance(desc, PyCArrayType):
            arrays_seen = True
        dinfo = _stg(desc)
        if dinfo is None:
            raise TypeError("second item in _fields_ tuple (index %d) must be "
                            "a C type" % i)
        fieldtypes.append(desc)
        elements.append(dinfo.ffi)
        if dinfo.ispointer or dinfo.haspointer:
            info.haspointer = True
        info.hasunion = info.hasunion or dinfo.hasunion
        info.hasbitfield = info.hasbitfield or dinfo.hasbitfield
        dinfo.final = True
        if len(pair) == 3:
            try:
                bitsize = _index(pair[2])
            except TypeError:
                raise TypeError("'_fields_' must be a sequence of (name, C "
                                "type) pairs") from None
            info.hasbitfield = True
            kind = _ffi_kind(dinfo) if dinfo.kind == "simple" else None
            ok = kind in _BITFIELD_OK or (
                kind in _BITFIELD_SIGNED and dinfo.code not in ("c", "u"))
            if not ok:
                raise TypeError("bit fields not allowed for type %s"
                                % desc.__name__)
            if bitsize <= 0 or bitsize > dinfo.size * 8:
                raise ValueError("number of bits invalid for bit field")
        else:
            bitsize = 0
        if isstruct:
            prop, field_size, bitofs, size, offset, align = _cfield_from_desc(
                desc, dinfo, i, field_size, bitsize, bitofs, size, offset,
                pack, big_endian)
        else:
            prop, field_size, bitofs, size, offset, align = _cfield_from_desc(
                desc, dinfo, i, field_size, bitsize, bitofs, 0, 0, pack,
                big_endian)
            union_size = max(size, union_size)
        total_align = max(align, total_align)
        type.__setattr__(cls, name, prop)
    if not isstruct:
        size = union_size
    aligned_size = ((size + total_align - 1) // total_align) * total_align
    if arrays_seen and aligned_size <= 16:
        # bpo-22273: libffi has to see an array in a small struct as the
        # elements it is, or it classifies the registers wrongly.
        keep = []
        new_elems = list(elements[:ffi_ofs])
        for desc in fieldtypes:
            if isinstance(desc, PyCArrayType):
                flat = _flat_ffi(desc)
                d = _stg(desc)
                inner = _stg(_innermost(desc))
                blk = _make_ffi_struct(d.size, inner.align, flat)
                keep.append(blk)
                new_elems.append(blk.addr)
            else:
                new_elems.append(_stg(desc).ffi)
        elements = new_elems
    else:
        keep = []
    blk = _make_ffi_struct(aligned_size, total_align, elements)
    keep.append(blk)
    info.keep = keep
    info.ffi = blk.addr
    info.size = aligned_size
    info.align = total_align
    info.length = ffi_ofs + len(fields)
    info.fieldtypes = elements
    if info.final:
        # Set while the fields were walked: one of them was this very type.
        raise AttributeError("Structure or union cannot contain itself")
    info.final = True
    _make_anon_fields(cls)


def _innermost(tp):
    while isinstance(tp, PyCArrayType):
        tp = _stg(tp).proto
    return tp


def _cfield_from_desc(desc, dinfo, index, field_size, bitsize, bitofs,
                      size, offset, pack, big_endian):
    """PyCField_FromDesc, GCC's bitfield rules."""
    self = _new_cfield()
    dsize = dinfo.size
    if bitsize and field_size and dsize * 8 <= field_size \
            and bitofs + bitsize <= field_size:
        fieldtype = "cont"
    elif bitsize and field_size and dsize * 8 >= field_size \
            and bitofs + bitsize <= dsize * 8:
        fieldtype = "expand"
    elif bitsize:
        fieldtype = "new"
        bitofs = 0
        field_size = dsize * 8
    else:
        fieldtype = "none"
        bitofs = 0
        field_size = 0

    if isinstance(desc, PyCArrayType):
        proto = _stg(desc).proto
        pinfo = _stg(proto) if proto is not None else None
        if pinfo is not None and pinfo.code == "c" and pinfo.kind == "simple":
            self._getfunc, self._setfunc = _s_get, _s_set
        elif pinfo is not None and pinfo.code == "u" \
                and pinfo.kind == "simple":
            self._getfunc, self._setfunc = _U_get, _U_set
    self._index = index
    self._proto = desc
    align = 0
    if fieldtype in ("new", "none"):
        if fieldtype == "new":
            if big_endian:
                self._size = (bitsize << 16) + field_size - bitofs - bitsize
            else:
                self._size = (bitsize << 16) + bitofs
            bitofs = bitsize
        if pack:
            align = min(pack, dinfo.align)
        else:
            align = dinfo.align
        if align and offset % align:
            delta = align - (offset % align)
            size += delta
            offset += delta
        if bitsize == 0:
            self._size = dsize
        size += dsize
        self._offset = offset
        offset += dsize
    elif fieldtype == "expand":
        offset += dsize - field_size // 8
        size += dsize - field_size // 8
        field_size = dsize * 8
        if big_endian:
            self._size = (bitsize << 16) + field_size - bitofs - bitsize
        else:
            self._size = (bitsize << 16) + bitofs
        self._offset = offset - dsize
        bitofs += bitsize
    else:
        if big_endian:
            self._size = (bitsize << 16) + field_size - bitofs - bitsize
        else:
            self._size = (bitsize << 16) + bitofs
        self._offset = offset - dsize
        bitofs += bitsize
    return self, field_size, bitofs, size, offset, align


def _make_fields(cls, descr, index, offset):
    fieldlist = descr._proto.__dict__.get("_fields_")
    if fieldlist is None:
        fieldlist = getattr(descr._proto, "_fields_")
    for pair in fieldlist:
        fname = pair[0]
        fdescr = getattr(descr._proto, fname)
        if type(fdescr) is not CField:
            raise TypeError("unexpected type")
        if fdescr._anonymous:
            _make_fields(cls, fdescr, index + fdescr._index,
                         offset + fdescr._offset)
            continue
        new = _new_cfield()
        new._size = fdescr._size
        new._offset = fdescr._offset + offset
        new._index = fdescr._index + index
        new._proto = fdescr._proto
        new._getfunc = fdescr._getfunc
        new._setfunc = fdescr._setfunc
        type.__setattr__(cls, fname, new)


def _make_anon_fields(cls):
    anon = getattr(cls, "_anonymous_", _NULL)
    if anon is _NULL:
        return
    try:
        anon = list(anon)
    except TypeError:
        raise TypeError("_anonymous_ must be a sequence") from None
    for fname in anon:
        descr = getattr(cls, fname)
        if type(descr) is not CField:
            raise AttributeError("'%s' is specified in _anonymous_ but not in "
                                 "_fields_" % fname)
        descr._anonymous = True
        _make_fields(cls, descr, descr._index, descr._offset)


def _clone_info(info):
    new = _StgInfo(info.kind)
    for k in _StgInfo.__slots__:
        setattr(new, k, getattr(info, k))
    return new


class _StructUnionType(_CDataType):
    _isstruct = True

    def __new__(mcls, name, bases, ns, **kw):
        cls = super().__new__(mcls, name, bases, ns, **kw)
        if _bootstrapping or "_abstract_" in ns:
            return cls
        info = _StgInfo("struct" if mcls._isstruct_of() else "union")
        blk = _make_ffi_struct(0, 1, [])
        info.keep = [blk]
        info.ffi = blk.addr
        if not mcls._isstruct_of():
            info.hasunion = True
        _set_stg(cls, info)
        if "_fields_" in ns:
            cls._fields_ = ns["_fields_"]
            return cls
        basedict = _stg(cls.__base__)
        if basedict is None:
            return cls
        new = _clone_info(basedict)
        new.final = False
        basedict.final = True
        _set_stg(cls, new)
        return cls

    @classmethod
    def _isstruct_of(mcls):
        for k in mcls.__mro__:
            if k is PyCStructType:
                return True
            if k is UnionType:
                return False
        return True

    def __setattr__(cls, key, value):
        type.__setattr__(cls, key, value)
        if key == "_fields_":
            _update_stgdict(cls, value, type(cls)._isstruct_of())


class PyCStructType(_StructUnionType):
    pass


class UnionType(_StructUnionType):
    pass


# ---- arrays --------------------------------------------------------------

_array_cache = {}


def _array_type_from_ctype(itemtype, length):
    key = (itemtype, length)
    try:
        return _array_cache[key]
    except KeyError:
        pass
    except TypeError:
        key = None
    if not isinstance(itemtype, type):
        raise TypeError("Expected a type object")
    result = PyCArrayType("%s_Array_%d" % (itemtype.__name__, length),
                          (Array,),
                          {"_length_": length, "_type_": itemtype})
    if key is not None:
        _array_cache[key] = result
    return result


class PyCArrayType(_CDataType):

    def __new__(mcls, name, bases, ns, **kw):
        cls = super().__new__(mcls, name, bases, ns, **kw)
        if _bootstrapping:
            return cls
        length = getattr(cls, "_length_", _NULL)
        if length is _NULL:
            raise AttributeError("class must define a '_length_' attribute")
        if not isinstance(length, int):
            raise TypeError("The '_length_' attribute must be an integer")
        if length < 0:
            raise ValueError("The '_length_' attribute must not be negative")
        if length > _sys.maxsize:
            raise OverflowError("The '_length_' attribute is too large")
        itemtype = getattr(cls, "_type_", _NULL)
        if itemtype is _NULL:
            raise AttributeError("class must define a '_type_' attribute")
        iinfo = _stg(itemtype) if isinstance(itemtype, type) else None
        if iinfo is None:
            raise TypeError("_type_ must have storage info")
        info = _StgInfo("array")
        itemsize = iinfo.size
        if itemsize and length > _sys.maxsize // itemsize:
            raise OverflowError("array too large")
        info.haspointer = iinfo.ispointer or iinfo.haspointer
        info.size = itemsize * length
        info.align = iinfo.align
        info.length = length
        info.proto = itemtype
        info.ffi = _FT["pointer"]
        _set_stg(cls, info)
        if iinfo.kind == "simple" and iinfo.code == "c":
            type.__setattr__(cls, "raw", property(
                _chararray_get_raw, _chararray_set_raw, _no_delete_attr))
            type.__setattr__(cls, "value", property(
                _chararray_get_value, _chararray_set_value, _no_delete))
        elif iinfo.kind == "simple" and iinfo.code == "u":
            type.__setattr__(cls, "value", property(
                _wchararray_get_value, _wchararray_set_value, _no_delete))
        return cls


def _no_delete(self):
    raise TypeError("can't delete attribute")


def _no_delete_attr(self):
    raise AttributeError("cannot delete attribute")


def _chararray_get_raw(self):
    return _read(self._b_ptr_, self._b_size_)


def _chararray_set_raw(self, value):
    mv = memoryview(value)
    data = mv.tobytes()
    if len(data) > self._b_size_:
        raise ValueError("byte string too long")
    _write(self._b_ptr_, data)


def _chararray_get_value(self):
    raw = _read(self._b_ptr_, self._b_size_)
    i = raw.find(b"\x00")
    return raw if i < 0 else raw[:i]


def _chararray_set_value(self, value):
    if not isinstance(value, bytes):
        raise TypeError("bytes expected instead of %s instance"
                        % type(value).__name__)
    if len(value) > self._b_size_:
        raise ValueError("byte string too long")
    if len(value) < self._b_size_:
        value = value + b"\x00"
    _write(self._b_ptr_, value)


def _wchararray_get_value(self):
    return _U_get(self._b_ptr_, self._b_size_)


def _wchararray_set_value(self, value):
    if not isinstance(value, str):
        raise TypeError("unicode string expected instead of %s instance"
                        % type(value).__name__)
    size = self._b_size_ // 4
    if len(value) > size:
        raise ValueError("string too long")
    data = _wchar_encode(value)
    if len(value) < size:
        data += bytes(4)
    _write(self._b_ptr_, data)


# ---- pointers ------------------------------------------------------------

class PyCPointerType(_CDataType):

    def __new__(mcls, name, bases, ns, **kw):
        info = _StgInfo("pointer")
        info.size = 8
        info.align = 8
        info.length = 1
        info.ffi = _FT["pointer"]
        info.ispointer = True
        proto = ns.get("_type_", _NULL)
        if proto is not _NULL:
            _pointer_set_proto(info, proto)
        cls = super().__new__(mcls, name, bases, ns, **kw)
        if not _bootstrapping:
            _set_stg(cls, info)
        return cls

    def from_param(cls, value):
        if value is None:
            return value
        info = _stg(cls)
        if info is None:
            raise TypeError("abstract class")
        if info.proto is not None and isinstance(value, info.proto):
            return byref(value)
        if isinstance(value, (_Pointer, Array)):
            vi = _obj_stg(value)
            if info.proto is not None and isinstance(vi.proto, type) and \
                    issubclass(vi.proto, info.proto):
                return value
        return _cdatatype_from_param(cls, value)

    def set_type(cls, typ):
        info = _stg(cls)
        if info is None:
            raise TypeError("abstract class")
        _pointer_set_proto(info, typ)
        type.__setattr__(cls, "_type_", typ)


def _pointer_set_proto(info, proto):
    if not isinstance(proto, type):
        raise TypeError("_type_ must be a type")
    if _stg(proto) is None:
        raise TypeError("_type_ must have storage info")
    info.proto = proto


# ---- function pointers ---------------------------------------------------

def _converters_from_argtypes(ob):
    try:
        argtypes = tuple(ob)
    except TypeError:
        raise TypeError("_argtypes_ must be a sequence of types") from None
    if len(argtypes) > CTYPES_MAX_ARGCOUNT:
        raise ArgumentError("_argtypes_ has too many arguments (%d), maximum "
                            "is %d" % (len(argtypes), CTYPES_MAX_ARGCOUNT))
    converters = []
    for i, tp in enumerate(argtypes):
        info = _stg(tp) if isinstance(tp, type) else None
        if info is not None:
            if info.hasunion:
                raise TypeError("item %d in _argtypes_ passes a union by "
                                "value, which is unsupported." % (i + 1))
            if info.hasbitfield:
                raise TypeError("item %d in _argtypes_ passes a struct/union "
                                "with a bitfield by value, which is "
                                "unsupported." % (i + 1))
        cnv = getattr(tp, "from_param", _NULL)
        if cnv is _NULL:
            raise TypeError("item %d in _argtypes_ has no from_param method"
                            % (i + 1))
        converters.append(cnv)
    return argtypes, tuple(converters)


class PyCFuncPtrType(_CDataType):

    def __new__(mcls, name, bases, ns, **kw):
        cls = super().__new__(mcls, name, bases, ns, **kw)
        if _bootstrapping:
            return cls
        info = _StgInfo("func")
        info.size = 8
        info.align = 8
        info.length = 1
        info.ffi = _FT["pointer"]
        info.ispointer = True
        flags = ns.get("_flags_", _NULL)
        if flags is _NULL or not isinstance(flags, int):
            raise TypeError("class must define _flags_ which must be an "
                            "integer")
        info.flags = flags
        ob = ns.get("_argtypes_", _NULL)
        if ob is not _NULL:
            info.argtypes, info.converters = _converters_from_argtypes(ob)
        ob = ns.get("_restype_", _NULL)
        if ob is not _NULL:
            if ob is not None and _stg(ob) is None and not callable(ob):
                raise TypeError("_restype_ must be a type, a callable, or "
                                "None")
            info.restype = ob
            info.checker = getattr(ob, "_check_retval_", None)
        _set_stg(cls, info)
        return cls


# ---------------------------------------------------------------------------
# The base classes
# ---------------------------------------------------------------------------

class _SimpleCData(_CData, metaclass=PyCSimpleType):
    __slots__ = ()

    def __new__(cls, *args, **kw):
        return _new_instance(cls)

    def __init__(self, *args):
        if len(args) > 1:
            raise TypeError("__init__ expected at most 1 argument, got %d"
                            % len(args))
        if args:
            self.value = args[0]

    @property
    def value(self):
        info = _obj_stg(self)
        return info.getfunc(self._b_ptr_, self._b_size_)

    @value.setter
    def value(self, value):
        info = _obj_stg(self)
        keep = info.setfunc(self._b_ptr_, value, info.size)
        _keepref(self, 0, keep)

    @value.deleter
    def value(self):
        raise TypeError("can't delete attribute")

    def __bool__(self):
        return _read(self._b_ptr_, self._b_size_) != bytes(self._b_size_)

    def __repr__(self):
        if type(self).__base__ is not _SimpleCData:
            return "<%s object at %#x>" % (type(self).__name__, id(self))
        return "%s(%r)" % (type(self).__name__, self.value)

    def __ctypes_from_outparam__(self):
        if _simple_instance(type(self)):
            return self
        return self.value


class Structure(_CData, metaclass=PyCStructType):
    __slots__ = ()

    def __new__(cls, *args, **kw):
        return _new_instance(cls)

    def __init__(self, *args, **kw):
        _struct_init(self, args, kw)


class Union(_CData, metaclass=UnionType):
    __slots__ = ()

    def __new__(cls, *args, **kw):
        return _new_instance(cls)

    def __init__(self, *args, **kw):
        _struct_init(self, args, kw)


def _init_pos_args(self, tp, args, kw, index):
    base = tp.__base__
    if _stg(base) is not None:
        index = _init_pos_args(self, base, args, kw, index)
    info = _stg(tp)
    fields = tp.__dict__.get("_fields_")
    if fields is None:
        return index
    i = index
    while i < info.length and i < len(args):
        name = fields[i - index][0]
        if kw and name in kw:
            raise TypeError("duplicate values for field %r" % name)
        setattr(self, name, args[i])
        i += 1
    return info.length


def _struct_init(self, args, kw):
    if args:
        res = _init_pos_args(self, type(self), args, kw, 0)
        if res < len(args):
            raise TypeError("too many initializers")
    for k, v in kw.items():
        setattr(self, k, v)


class Array(_CData, metaclass=PyCArrayType):
    __slots__ = ()

    def __new__(cls, *args, **kw):
        return _new_instance(cls)

    def __init__(self, *args):
        for i, v in enumerate(args):
            self[i] = v

    def __len__(self):
        return self._b_length_

    def _item(self, index):
        if index < 0 or index >= self._b_length_:
            raise IndexError("invalid index")
        info = _obj_stg(self)
        size = info.size // info.length
        return _cdata_get(info.proto, info.getfunc, self, index, size,
                          self._b_ptr_ + index * size)

    def __getitem__(self, item):
        if hasattr(type(item), "__index__"):
            i = item.__index__()
            if i < 0:
                i += self._b_length_
            return self._item(i)
        if isinstance(item, slice):
            start, stop, step = item.indices(self._b_length_)
            rng = range(start, stop, step)
            iinfo = _stg(_obj_stg(self).proto)
            if iinfo.kind == "simple" and iinfo.code == "c":
                raw = _read(self._b_ptr_, self._b_size_)
                if step == 1:
                    return raw[start:stop]
                return bytes(raw[i] for i in rng)
            if iinfo.kind == "simple" and iinfo.code == "u":
                raw = _wchar_decode(_read(self._b_ptr_, self._b_size_))
                return "".join(raw[i] for i in rng)
            return [self._item(i) for i in rng]
        raise TypeError("indices must be integers")

    def _ass_item(self, index, value):
        info = _obj_stg(self)
        if index < 0 or index >= info.length:
            raise IndexError("invalid index")
        size = info.size // info.length
        _cdata_set(self, info.proto, info.setfunc, value, index, size,
                   self._b_ptr_ + index * size)

    def __setitem__(self, item, value):
        if hasattr(type(item), "__index__"):
            i = item.__index__()
            if i < 0:
                i += self._b_length_
            return self._ass_item(i, value)
        if isinstance(item, slice):
            start, stop, step = item.indices(self._b_length_)
            rng = range(start, stop, step)
            if len(value) != len(rng):
                raise ValueError("Can only assign sequence of same size")
            for j, i in enumerate(rng):
                self._ass_item(i, value[j])
            return
        raise TypeError("indices must be integer")

    def __delitem__(self, item):
        raise TypeError("Array does not support item deletion")

    def __iter__(self):
        for i in range(self._b_length_):
            yield self._item(i)

    def __class_getitem__(cls, item):
        import types
        return types.GenericAlias(cls, item)


class _Pointer(_CData, metaclass=PyCPointerType):
    __slots__ = ()

    def __new__(cls, *args, **kw):
        info = _stg(cls)
        if info is None or info.proto is None:
            raise TypeError("Cannot create instance: has no _type_")
        return _new_instance(cls, info)

    def __init__(self, *args):
        if len(args) > 1:
            raise TypeError("POINTER expected at most 1 argument, got %d"
                            % len(args))
        if args:
            self.contents = args[0]

    @property
    def contents(self):
        p = _rd_ptr(self._b_ptr_)
        if not p:
            raise ValueError("NULL pointer access")
        return _from_base(_obj_stg(self).proto, self, 0, p)

    @contents.setter
    def contents(self, value):
        info = _obj_stg(self)
        if not isinstance(value, _CData):
            raise TypeError("expected %s instead of %s"
                            % (info.proto.__name__, type(value).__name__))
        if not isinstance(value, info.proto):
            raise TypeError("expected %s instead of %s"
                            % (info.proto.__name__, type(value).__name__))
        _wr_ptr(self._b_ptr_, value._b_ptr_)
        _keepref(self, 1, value)
        _keepref(self, 0, _keeped(value))

    @contents.deleter
    def contents(self):
        raise TypeError("Pointer does not support item deletion")

    def _item(self, index):
        p = _rd_ptr(self._b_ptr_)
        if not p:
            raise ValueError("NULL pointer access")
        info = _obj_stg(self)
        size = _stg(info.proto).size
        return _cdata_get(info.proto, info.getfunc, self, index, size,
                          p + index * size)

    def __getitem__(self, item):
        if hasattr(type(item), "__index__"):
            return self._item(item.__index__())
        if isinstance(item, slice):
            step = 1 if item.step is None else _index(item.step)
            if step == 0:
                raise ValueError("slice step cannot be zero")
            if item.start is None:
                if step < 0:
                    raise ValueError("slice start is required for step < 0")
                start = 0
            else:
                start = _index(item.start)
            if item.stop is None:
                raise ValueError("slice stop is required")
            stop = _index(item.stop)
            rng = range(start, stop, step)
            iinfo = _stg(_obj_stg(self).proto)
            p = _rd_ptr(self._b_ptr_)
            if iinfo.kind == "simple" and iinfo.code == "c":
                if not len(rng):
                    return b""
                return bytes(_read(p + i, 1)[0] for i in rng)
            if iinfo.kind == "simple" and iinfo.code == "u":
                return "".join(_wchar_decode(_read(p + 4 * i, 4))
                               for i in rng)
            return [self._item(i) for i in rng]
        raise TypeError("Pointer indices must be integer")

    def __setitem__(self, item, value):
        if not hasattr(type(item), "__index__"):
            raise TypeError("Pointer indices must be integer")
        index = item.__index__()
        p = _rd_ptr(self._b_ptr_)
        if not p:
            raise ValueError("NULL pointer access")
        info = _obj_stg(self)
        size = _stg(info.proto).size
        _cdata_set(self, info.proto, info.setfunc, value, index, size,
                   p + index * size)

    def __delitem__(self, item):
        raise TypeError("Pointer does not support item deletion")

    def __bool__(self):
        return _rd_ptr(self._b_ptr_) != 0


# ---- CFuncPtr ------------------------------------------------------------

class CFuncPtr(_CData, metaclass=PyCFuncPtrType):
    __slots__ = ("_fp_restype", "_fp_argtypes", "_fp_converters",
                 "_fp_checker", "_fp_errcheck", "_fp_paramflags",
                 "_fp_callable", "_fp_thunk")

    def __new__(cls, *args, **kw):
        if not args:
            return _funcptr_alloc(cls)
        if isinstance(args[0], tuple):
            return _funcptr_from_dll(cls, *args)
        if len(args) == 1 and isinstance(args[0], int):
            self = _funcptr_alloc(cls)
            _wr_ptr(self._b_ptr_, args[0])
            return self
        if len(args) != 1:
            raise TypeError("argument must be callable or integer function "
                            "address")
        callable_ = args[0]
        if not callable(callable_):
            raise TypeError("argument must be callable or integer function "
                            "address")
        info = _stg(cls)
        if info is None or info.argtypes is None:
            raise TypeError("cannot construct instance of this class: no "
                            "argtypes")
        thunk = _CThunk(callable_, info.argtypes, info.restype, info.flags)
        self = _funcptr_alloc(cls)
        self._fp_callable = callable_
        self._fp_thunk = thunk
        _wr_ptr(self._b_ptr_, thunk.code)
        _keepref(self, 0, thunk)
        return self

    def __init__(self, *args, **kw):
        pass

    @property
    def errcheck(self):
        return self._fp_errcheck

    @errcheck.setter
    def errcheck(self, ob):
        if not callable(ob):
            raise TypeError("the errcheck attribute must be callable")
        self._fp_errcheck = ob

    @errcheck.deleter
    def errcheck(self):
        self._fp_errcheck = None

    @property
    def restype(self):
        if self._fp_restype is not _NULL:
            return self._fp_restype
        r = _obj_stg(self).restype
        return None if r is _NULL else r

    @restype.setter
    def restype(self, ob):
        if ob is not None and _stg(ob) is None and not callable(ob):
            raise TypeError("restype must be a type, a callable, or None")
        self._fp_checker = getattr(ob, "_check_retval_", None)
        self._fp_restype = ob

    @restype.deleter
    def restype(self):
        self._fp_checker = None
        self._fp_restype = _NULL

    @property
    def argtypes(self):
        if self._fp_argtypes is not None:
            return self._fp_argtypes
        return _obj_stg(self).argtypes

    @argtypes.setter
    def argtypes(self, ob):
        if ob is None:
            self._fp_argtypes = None
            self._fp_converters = None
        else:
            self._fp_argtypes, self._fp_converters = \
                _converters_from_argtypes(ob)

    @argtypes.deleter
    def argtypes(self):
        self._fp_argtypes = None
        self._fp_converters = None

    def __bool__(self):
        return _rd_ptr(self._b_ptr_) != 0

    def __repr__(self):
        return "<%s object at %#x>" % (type(self).__name__, id(self))

    def __call__(self, *inargs, **kwds):
        info = _obj_stg(self)
        restype = self._fp_restype if self._fp_restype is not _NULL \
            else info.restype
        converters = self._fp_converters if self._fp_converters is not None \
            else info.converters
        checker = self._fp_checker if self._fp_restype is not _NULL \
            else info.checker
        argtypes = self._fp_argtypes if self._fp_argtypes is not None \
            else info.argtypes
        errcheck = self._fp_errcheck
        pproc = _rd_ptr(self._b_ptr_)
        callargs, outmask, inoutmask, numretvals = _build_callargs(
            self, argtypes, inargs, kwds)
        if converters is not None:
            required = len(converters)
            actual = len(callargs)
            if (info.flags & FUNCFLAG_CDECL) == FUNCFLAG_CDECL:
                if required > actual:
                    raise TypeError(
                        "this function takes at least %d argument%s (%d given)"
                        % (required, "" if required == 1 else "s", actual))
            elif required != actual:
                raise TypeError("this function takes %d argument%s (%d given)"
                                % (required, "" if required == 1 else "s",
                                   actual))
        pyfunc = _PYAPI.get(pproc)
        if pyfunc is not None:
            result = pyfunc(callargs, converters)
        else:
            result = _callproc(pproc, callargs, info.flags, converters,
                               restype, checker)
        if errcheck is not None:
            v = errcheck(result, self, callargs)
            if v is not callargs:
                return v
        return _build_result(result, callargs, outmask, inoutmask, numretvals)


def _funcptr_alloc(cls):
    return _new_instance(cls)


def _check_outarg_type(arg, index):
    if isinstance(arg, (PyCPointerType, PyCArrayType)):
        return
    info = _stg(arg) if isinstance(arg, type) else None
    if info is not None and info.kind == "simple" and info.code in "PzZ":
        return
    raise TypeError("'out' parameter %d must be a pointer type, not %s"
                    % (index, arg.__name__ if isinstance(arg, type)
                       else type(arg).__name__))


def _validate_paramflags(cls, paramflags):
    info = _stg(cls)
    if info is None:
        raise TypeError("abstract class")
    argtypes = info.argtypes
    if paramflags is None or argtypes is None:
        return
    if not isinstance(paramflags, tuple):
        raise TypeError("paramflags must be a tuple or None")
    if len(paramflags) != len(argtypes):
        raise ValueError("paramflags must have the same length as argtypes")
    for i, item in enumerate(paramflags):
        ok = isinstance(item, tuple) and 1 <= len(item) <= 3 \
            and isinstance(item[0], int) \
            and (len(item) < 2 or item[1] is None or isinstance(item[1], str))
        if not ok:
            raise TypeError("paramflags must be a sequence of (int [,string "
                            "[,value]]) tuples")
        flag = item[0] & (1 | 2 | 4)
        if flag in (0, 1, 1 | 4, 1 | 2):
            continue
        if flag == 2:
            _check_outarg_type(argtypes[i], i + 1)
            continue
        raise TypeError("paramflag value %d not supported" % item[0])


def _funcptr_from_dll(cls, ftuple, paramflags=None):
    ftuple = tuple(ftuple)
    if len(ftuple) != 2:
        raise TypeError("illegal func_spec argument")
    name, dll = ftuple
    if isinstance(name, bytes):
        bname = name
    elif isinstance(name, str):
        bname = name.encode()
    else:
        raise TypeError("function name must be string, bytes object or "
                        "integer")
    _sys.audit("ctypes.dlsym", dll, name)
    handle = getattr(dll, "_handle")
    if not isinstance(handle, int):
        raise TypeError("the _handle attribute of the second argument must be "
                        "an integer")
    _core.dlerror()
    address = _core.dlsym(handle, bname)
    if not address:
        err = _core.dlerror()
        if err:
            raise AttributeError(err)
        raise AttributeError("function '%s' not found" % bname.decode())
    _validate_paramflags(cls, paramflags)
    self = _funcptr_alloc(cls)
    self._fp_paramflags = paramflags
    _wr_ptr(self._b_ptr_, address)
    _keepref(self, 0, dll)
    return self


def _get_arg(state, name, defval, inargs, kwds):
    if state[0] < len(inargs):
        v = inargs[state[0]]
        state[0] += 1
        return v
    if kwds and name is not None and name in kwds:
        state[0] += 1
        return kwds[name]
    if defval is not _NULL:
        return defval
    if name is not None:
        raise TypeError("required argument '%s' missing" % name)
    raise TypeError("not enough arguments")


def _build_callargs(self, argtypes, inargs, kwds):
    paramflags = self._fp_paramflags
    if argtypes is None or paramflags is None or len(argtypes) == 0:
        return inargs, 0, 0, 0
    outmask = inoutmask = numretvals = 0
    callargs = []
    state = [0]
    for i, item in enumerate(paramflags):
        flag = item[0]
        name = item[1] if len(item) > 1 else None
        defval = item[2] if len(item) > 2 else _NULL
        f = flag & (1 | 2 | 4)
        if f == (1 | 4):
            callargs.append(0 if defval is _NULL else defval)
        elif f in (0, 1, 1 | 2):
            if f == (1 | 2):
                inoutmask |= 1 << i
                numretvals += 1
            callargs.append(_get_arg(state, name, defval, inargs, kwds))
        elif f == 2:
            if defval is not _NULL:
                callargs.append(defval)
                outmask |= 1 << i
                numretvals += 1
                continue
            ob = argtypes[i]
            info = _stg(ob)
            if info is None:
                raise RuntimeError("NULL stgdict unexpected")
            if isinstance(info.proto, str):
                raise TypeError("%s 'out' parameter must be passed as default "
                                "value" % ob.__name__)
            if isinstance(ob, PyCArrayType):
                v = ob()
            else:
                v = info.proto()
            callargs.append(v)
            outmask |= 1 << i
            numretvals += 1
        else:
            raise ValueError("paramflag %d not yet implemented" % flag)
    actual = len(inargs) + (len(kwds) if kwds else 0)
    if actual != state[0]:
        raise TypeError("call takes exactly %d arguments (%d given)"
                        % (state[0], actual))
    return tuple(callargs), outmask, inoutmask, numretvals


def _build_result(result, callargs, outmask, inoutmask, numretvals):
    if numretvals == 0:
        return result
    out = []
    for i in range(32):
        bit = 1 << i
        if bit & inoutmask:
            v = callargs[i]
            if numretvals == 1:
                return v
            out.append(v)
        elif bit & outmask:
            v = callargs[i].__ctypes_from_outparam__()
            if numretvals == 1:
                return v
            out.append(v)
        if len(out) == numretvals:
            break
    return tuple(out)


# ---------------------------------------------------------------------------
# The call itself (callproc.c)
# ---------------------------------------------------------------------------

def _conv_param(obj, index):
    """ConvParam -> (ffi type address, value bytes, keep)."""
    if isinstance(obj, _CData):
        info = _obj_stg(obj)
        return _paramfunc(obj, info)
    if isinstance(obj, CArgObject):
        return obj._ffi, obj._val, obj
    if obj is None:
        return _FT["pointer"], bytes(8), None
    if isinstance(obj, int):
        if -(1 << 63) <= obj < (1 << 64):
            return _FT["sint32"], (obj & 0xFFFFFFFFFFFFFFFF).to_bytes(
                8, "little"), None
        raise OverflowError("int too long to convert")
    if isinstance(obj, bytes):
        return _FT["pointer"], _addr(obj).to_bytes(8, "little"), obj
    if isinstance(obj, str):
        keep = _wchar_encode(obj) + bytes(4)
        return _FT["pointer"], _addr(keep).to_bytes(8, "little"), keep
    arg = getattr(obj, "_as_parameter_", _NULL)
    if arg is not _NULL:
        return _conv_param(arg, index)
    raise TypeError("Don't know how to convert parameter %d" % index)


def _paramfunc(obj, info):
    kind = info.kind
    if kind == "simple":
        return info.ffi, _read(obj._b_ptr_, obj._b_size_), obj
    if kind in ("pointer", "func"):
        return _FT["pointer"], _read(obj._b_ptr_, 8), obj
    if kind == "array":
        return _FT["pointer"], obj._b_ptr_.to_bytes(8, "little"), obj
    # struct or union, by value
    return info.ffi, _read(obj._b_ptr_, obj._b_size_), obj


def _ffi_type_of(tp):
    if tp is None:
        return _FT["sint32"]
    info = _stg(tp) if isinstance(tp, type) else None
    if info is None:
        return _FT["sint32"]
    return info.ffi


def _ffi_size_of(tp):
    info = _stg(tp) if isinstance(tp, type) else None
    return info.size if info is not None else 4


def _extend_error(exc, prefix):
    return ArgumentError("%s%s: %s" % (prefix, type(exc).__name__, exc))


def _callproc(pproc, argtuple, flags, converters, restype, checker):
    n = len(argtuple)
    if n > CTYPES_MAX_ARGCOUNT:
        raise ArgumentError("too many arguments (%d), maximum is %d"
                            % (n, CTYPES_MAX_ARGCOUNT))
    ncnv = len(converters) if converters is not None else 0
    params = []
    for i in range(n):
        arg = argtuple[i]
        if i < ncnv:
            try:
                v = converters[i](arg)
            except Exception as e:
                raise _extend_error(e, "argument %d: " % (i + 1)) from None
            try:
                params.append(_conv_param(v, i + 1))
            except Exception as e:
                raise _extend_error(e, "argument %d: " % (i + 1)) from None
        else:
            try:
                params.append(_conv_param(arg, i + 1))
            except Exception as e:
                raise _extend_error(e, "argument %d: " % (i + 1)) from None
    if restype is None:
        rtype = _FT["void"]
        rsize = 8
    else:
        rtype = _ffi_type_of(restype if restype is not _NULL else None)
        rsize = max(_ffi_size_of(restype) if restype is not _NULL else 4, 8)
    # One block: cif, atypes, avalues, the values, the result.
    pos = 32 + 16 * n
    offs = []
    for p in params:
        pos = (pos + 15) & ~15
        offs.append(pos)
        pos += max(len(p[1]), 8)
    pos = (pos + 15) & ~15
    roff = pos
    pos += rsize + 16
    blk = _Block(pos)
    b = blk.buf
    base = blk.addr
    for i, p in enumerate(params):
        b[32 + 8 * i:40 + 8 * i] = p[0].to_bytes(8, "little")
        b[32 + 8 * n + 8 * i:40 + 8 * n + 8 * i] = \
            (base + offs[i]).to_bytes(8, "little")
        b[offs[i]:offs[i] + len(p[1])] = p[1]
    status = _core.prep_cif(base, _FFI_DEFAULT_ABI, n, rtype, base + 32)
    if status != 0:
        raise RuntimeError("ffi_prep_cif failed")
    if flags & FUNCFLAG_USE_ERRNO:
        _errno_enter()
        _core.call(base, pproc, base + roff, base + 32 + 8 * n, 1)
        _errno_leave()
    else:
        _core.call(base, pproc, base + roff, base + 32 + 8 * n, 0)
    del params
    return _get_result(restype, base + roff, checker)


def _get_result(restype, addr, checker):
    """GetResult."""
    if restype is _NULL:
        return int.from_bytes(_read(addr, 4), "little", signed=True)
    if restype is None:
        return None
    info = _stg(restype) if isinstance(restype, type) else None
    if info is None:
        return restype(int.from_bytes(_read(addr, 4), "little", signed=True))
    if info.getfunc is not None and not _simple_instance(restype):
        retval = info.getfunc(addr, info.size)
    else:
        retval = _from_base(restype, None, 0, addr)
    if checker is None:
        return retval
    return checker(retval)


# ---------------------------------------------------------------------------
# Callbacks (callbacks.c)
# ---------------------------------------------------------------------------

class _UnraisableHookArgs:
    def __init__(self, exc_type, exc_value, exc_traceback, err_msg, obj):
        self.exc_type = exc_type
        self.exc_value = exc_value
        self.exc_traceback = exc_traceback
        self.err_msg = err_msg
        self.object = obj


def _write_unraisable(msg, obj):
    exc = _sys.exc_info()[1]
    args = _UnraisableHookArgs(type(exc), exc, exc.__traceback__,
                               "Exception ignored " + msg, obj)
    try:
        hook = _sys.unraisablehook
        hook(args)
    except BaseException:
        try:
            import traceback
            print("Exception ignored %s: %r" % (msg, obj), file=_sys.stderr)
            traceback.print_exception(type(exc), exc, exc.__traceback__)
        except BaseException:
            pass


class _CThunk:
    """CThunkObject: a libffi closure that calls a Python callable."""

    def __init__(self, callable_, argtypes, restype, flags):
        self.callable = callable_
        self.argtypes = argtypes
        self.restype = restype
        self.flags = flags
        n = len(argtypes)
        if restype is None:
            self.setfunc = None
            rtype = _FT["void"]
        else:
            info = _stg(restype) if isinstance(restype, type) else None
            if info is None or info.setfunc is None:
                raise TypeError("invalid result type for callback function")
            self.setfunc = info.setfunc
            self.rsize = info.size
            rtype = info.ffi
        self.convs = []
        for cnv in argtypes:
            info = _stg(cnv) if isinstance(cnv, type) else None
            self.convs.append(info)
        self.blk = _Block(32 + 8 * (n + 1) + 8)
        b = self.blk.buf
        for i, cnv in enumerate(argtypes):
            b[32 + 8 * i:40 + 8 * i] = _ffi_type_of(cnv).to_bytes(8, "little")
        status = _core.prep_cif(self.blk.addr, _FFI_DEFAULT_ABI, n, rtype,
                                self.blk.addr + 32)
        if status != 0:
            raise RuntimeError("ffi_prep_cif failed with %d" % status)
        out = self.blk.addr + 32 + 8 * (n + 1)
        self.tramp = self._call
        self.closure = _core.closure(self.blk.addr, self.tramp, out)
        if not self.closure:
            raise MemoryError()
        self.code = _rd_ptr(out)

    def __del__(self):
        c = self.__dict__.get("closure")
        if c:
            self.closure = 0
            _core.closure_free(c)

    def _call(self, resaddr, argsaddr):
        callable_ = self.callable
        try:
            args = []
            for i, cnv in enumerate(self.argtypes):
                p = _rd_ptr(argsaddr + 8 * i)
                info = self.convs[i]
                if info is not None and info.getfunc is not None \
                        and not _simple_instance(cnv):
                    args.append(info.getfunc(p, info.size))
                elif info is not None:
                    obj = cnv()
                    if not isinstance(obj, _CData):
                        raise TypeError("%r returned unexpected result of "
                                        "type %s" % (cnv, type(obj).__name__))
                    if info.size:
                        _write(obj._b_ptr_, _read(p, info.size))
                    args.append(obj)
                else:
                    raise TypeError("cannot build parameter of type %r" % cnv)
        except BaseException:
            _write_unraisable("while creating argument for ctypes callback "
                              "function", callable_)
            return
        use_errno = self.flags & FUNCFLAG_USE_ERRNO
        if use_errno:
            _errno_enter()
            _core.errno_swap()
        ok = True
        try:
            result = callable_(*args)
        except BaseException:
            _write_unraisable("on calling ctypes callback function",
                              callable_)
            ok = False
        if use_errno:
            _core.errno_swap()
            _errno_leave()
        if self.setfunc is not None and ok:
            try:
                _write(resaddr, bytes(8))
                keep = self.setfunc(resaddr, result, 0)
            except BaseException:
                _write_unraisable("on converting result of ctypes callback "
                                  "function", callable_)
                return
            if keep is not None and self.setfunc is not _O_set:
                import warnings
                try:
                    warnings.warn("memory leak in callback function.",
                                  RuntimeWarning, stacklevel=1)
                except BaseException:
                    _write_unraisable("on converting result of ctypes "
                                      "callback function", callable_)


# ---------------------------------------------------------------------------
# Module-level functions
# ---------------------------------------------------------------------------

def sizeof(obj):
    if isinstance(obj, type):
        info = _stg(obj)
        if info is not None:
            return info.size
    elif isinstance(obj, _CData):
        return obj._b_size_
    raise TypeError("this type has no size")


def alignment(obj):
    info = _stg(obj) if isinstance(obj, type) else None
    if info is None and isinstance(obj, _CData):
        info = _obj_stg(obj)
    if info is None:
        raise TypeError("no alignment info")
    return info.align


def addressof(obj):
    if not isinstance(obj, _CData):
        raise TypeError("invalid type")
    _sys.audit("ctypes.addressof", obj)
    return obj._b_ptr_


def byref(obj, offset=0):
    if not isinstance(obj, _CData):
        raise TypeError("byref() argument must be a ctypes instance, not '%s'"
                        % type(obj).__name__)
    offset = _index(offset)
    return CArgObject("P", _FT["pointer"],
                      ((obj._b_ptr_ + offset) & 0xFFFFFFFFFFFFFFFF).to_bytes(
                          8, "little"), obj)


def resize(obj, size):
    if not isinstance(obj, _CData):
        raise TypeError("expected ctypes instance")
    info = _obj_stg(obj)
    if size < info.size:
        raise ValueError("minimum size is %d" % info.size)
    if obj._b_needsfree == 0:
        raise ValueError("Memory cannot be resized because this object "
                         "doesn't own it")
    if size <= obj._b_size_:
        obj._b_size_ = size
        return None
    blk = _Block(size)
    _write(blk.addr, _read(obj._b_ptr_, obj._b_size_))
    obj._b_owner_ = blk
    obj._b_ptr_ = blk.addr
    obj._b_size_ = size
    return None


# CPython keeps the ctypes errno per thread.  _ctypescore keeps one, which
# is the CURRENT thread's: these swap it in and out by thread.
_errnos = {}


def _tid():
    try:
        import _thread
        return _thread.get_ident()
    except Exception:
        return 0


def _errno_enter():
    _core.errno_set(_errnos.get(_tid(), 0))


def _errno_leave():
    _errnos[_tid()] = _core.errno_get()


def get_errno():
    return _errnos.get(_tid(), 0)


def set_errno(value):
    value = _index(value)
    tid = _tid()
    old = _errnos.get(tid, 0)
    _errnos[tid] = value
    return old


_pointer_type_cache = {}


def POINTER(cls):
    try:
        return _pointer_type_cache[cls]
    except KeyError:
        pass
    except TypeError:
        raise TypeError("must be a ctypes type") from None
    if isinstance(cls, str):
        result = PyCPointerType("LP_%s" % cls, (_Pointer,), {})
        _pointer_type_cache[id(result)] = result
        return result
    if isinstance(cls, type):
        result = PyCPointerType("LP_%s" % cls.__name__, (_Pointer,),
                                {"_type_": cls})
    else:
        raise TypeError("must be a ctypes type")
    _pointer_type_cache[cls] = result
    return result


def pointer(obj):
    return POINTER(type(obj))(obj)


def dlopen(name, flag=RTLD_LOCAL):
    if name is None:
        bname = None
    else:
        import os
        bname = os.fsencode(name)
    _sys.audit("ctypes.dlopen", name)
    handle = _core.dlopen(bname, flag | _RTLD_NOW)
    if not handle:
        raise OSError(_core.dlerror())
    return handle


def dlclose(handle):
    if _core.dlclose(handle):
        raise OSError(_core.dlerror())


def dlsym(handle, name):
    _sys.audit("ctypes.dlsym/handle", handle, name)
    _core.dlerror()
    ptr = _core.dlsym(handle, name.encode())
    if not ptr:
        raise OSError(_core.dlerror() or ("symbol '%s' not found" % name))
    return ptr


def buffer_info(obj):
    info = _stg(obj) if isinstance(obj, type) else None
    if info is None and isinstance(obj, _CData):
        info = _obj_stg(obj)
    if info is None:
        raise TypeError("not a ctypes type or object")
    return (info.fmt, len(info.shape), info.shape)


def PyObj_FromPtr(address):
    try:
        return _pyobjs[address]
    except KeyError:
        raise ValueError("PyObject is NULL") from None


def Py_INCREF(obj):
    return obj


def Py_DECREF(obj):
    return obj


def call_function(address, args):
    return _callproc(address, tuple(args), FUNCFLAG_CDECL, None, _NULL, None)


def call_cdeclfunction(address, args):
    return _callproc(address, tuple(args), FUNCFLAG_CDECL, None, _NULL, None)


# The three functions ctypes reaches through PYFUNCTYPE.  CPython's are C
# functions at real addresses; these are Python, so their "addresses" are
# keys the CFuncPtr call path looks up before going to libffi.

def _voidp_arg(v):
    ffi, val, keep = _conv_param(v, 1)
    return int.from_bytes(val[:8], "little")


def _py_arg(v):
    if isinstance(v, CArgObject):
        return v._obj
    if isinstance(v, _CData) and _obj_stg(v).code == "O":
        return v.value
    return v


def _converted(args, converters):
    out = []
    for i, a in enumerate(args):
        if converters is not None and i < len(converters):
            try:
                a = converters[i](a)
            except Exception as e:
                raise _extend_error(e, "argument %d: " % (i + 1)) from None
        out.append(a)
    return out


def _string_at_impl(args, converters):
    a = _converted(args, converters)
    ptr = _voidp_arg(a[0])
    size = _int_arg(a[1])
    _sys.audit("ctypes.string_at", ptr, size)
    if size == -1:
        size = _core.strlen(ptr)
    return _read(ptr, size)


def _wstring_at_impl(args, converters):
    a = _converted(args, converters)
    ptr = _voidp_arg(a[0])
    size = _int_arg(a[1])
    _sys.audit("ctypes.wstring_at", ptr, size)
    if size == -1:
        size = _core.wcslen(ptr)
    return _wchar_decode(_read(ptr, 4 * size))


def _int_arg(v):
    if isinstance(v, CArgObject):
        return int.from_bytes(v._val[:4], "little", signed=True)
    if isinstance(v, _CData):
        return v.value
    return v


def _cast_check_pointertype(arg):
    if isinstance(arg, (PyCPointerType, PyCFuncPtrType)):
        return
    info = _stg(arg) if isinstance(arg, type) else None
    if info is not None and info.kind == "simple" and info.code in "sPzUZXO":
        return
    raise TypeError("cast() argument 2 must be a pointer type, not %s"
                    % (arg.__name__ if isinstance(arg, type)
                       else type(arg).__name__))


def _cast_impl(args, converters):
    a = _converted(args, converters)
    ptr = _voidp_arg(a[0])
    src = _py_arg(a[1])
    ctype = _py_arg(a[2])
    _cast_check_pointertype(ctype)
    result = ctype()
    if isinstance(src, _CData):
        container = _container(src)
        if src._b_objects is None or src._b_objects is _NULL:
            src._b_objects = {}
        result._b_objects = src._b_objects
        if type(result._b_objects) is dict:
            result._b_objects[id(src)] = src
    _wr_ptr(result._b_ptr_, ptr)
    return result


_memmove_addr = _sym(b"memmove")
_memset_addr = _sym(b"memset")
_string_at_addr = 0x10
_wstring_at_addr = 0x20
_cast_addr = 0x30
_PYAPI = {_string_at_addr: _string_at_impl,
          _wstring_at_addr: _wstring_at_impl,
          _cast_addr: _cast_impl}

_bootstrapping = False

for _k in (_SimpleCData, Structure, Union, Array, _Pointer, CFuncPtr,
           PyCSimpleType, PyCStructType, UnionType, PyCArrayType,
           PyCPointerType, PyCFuncPtrType, CArgObject, _CData):
    _k.__module__ = "_ctypes"
del _k
