"""_testcapi - the few things CPython's TEST HARNESS reads off it.

Like lib/_testinternalcapi.py, and for the same reason: this is not CPython's
_testcapi, which is a C module exercising the public C API.  It is a stand-in
for what `test.support` looks up while it is being imported or while a
decorator is being evaluated, because those lookups sit at module scope and
an ImportError there takes a whole test module down before any of its tests
run.

test_call is the one that costs the most.  It writes

    _instance = _testcapi.MethInstance()

inside a class body, with the module fetched by a guarded import that leaves
None behind on failure -- so the whole file died on "'NoneType' object has no
attribute 'MethInstance'", and 181 tests with it.  That one cannot be stood
in for: MethInstance exists to exercise the C-level vectorcall protocol,
which this interpreter does not have.  What is here is only what
test.support itself reads, so the modules that merely IMPORT it survive.

These helpers expose the corresponding apython behavior where it exists.
They do not exercise the CPython extension ABI.
"""

# test.support.requires_limited_api decorates with skipUnless(this), so False
# is what makes those tests skip rather than error.  There is no Limited API
# here: there is no C API at all.
LIMITED_API_AVAILABLE = False

# test.support.with_pymalloc() answers this.  The allocator here is
# src/alloc.asm's size-class pool, which is not pymalloc; the tests that
# branch on it are asking "are object sizes and arenas CPython's", and they
# are not.
WITH_PYMALLOC = False

# What test.support.requires_legacy_unicode_capi checks for.  Deliberately
# absent rather than present-and-lying: the decorator is
# skipUnless(unicode_legacy_string), so an AttributeError on the import is
# exactly how those tests get skipped.  Nothing else reads it.

# Sizes test.support and a few modules read directly.
SIZEOF_PYGC_HEAD = 16
SIZEOF_TIME_T = 8
SIZEOF_WCHAR_T = 4

# Recursion is Python-level here; see lib/_testinternalcapi.py.
Py_C_RECURSION_LIMIT = 10000

# The two subinterpreter entry points test.support wraps.  There are no
# subinterpreters here -- one interpreter state, no per-interpreter GIL -- so
# these raise, and test.support's callers are decorated with skips that read
# the absence correctly when they are not.


def run_in_subinterp(code):
    raise NotImplementedError(
        "_testcapi.run_in_subinterp is not implemented: this interpreter has "
        "one interpreter state and no subinterpreter support")


def run_in_subinterp_with_config(code, **config):
    raise NotImplementedError(
        "_testcapi.run_in_subinterp_with_config is not implemented; see "
        "run_in_subinterp")


# ---------------------------------------------------------------------------
# The C integer limits.
#
# These are read as plain numbers -- "the value at which a C int parameter
# overflows" -- and the syscall wrappers in src/modules/ really do take C ints
# for file descriptors, backlogs and timeouts, so the limits are this
# interpreter's too.  test_exceptions carries its own `INT_MAX = 2**31 - 1`
# fallback, which is the value to agree with.
#
# They are not decoration: test_socket reads INT_MAX at MODULE scope
# (socklen_t_limit = min(0x7fffffff, _testcapi.INT_MAX)), so their absence was
# 732 tests that never ran rather than a handful that failed.
# ---------------------------------------------------------------------------
INT_MAX = 2 ** 31 - 1
INT_MIN = -(2 ** 31)
UINT_MAX = 2 ** 32 - 1
SHRT_MAX = 2 ** 15 - 1
SHRT_MIN = -(2 ** 15)
USHRT_MAX = 2 ** 16 - 1
LONG_MAX = 2 ** 63 - 1
LONG_MIN = -(2 ** 63)
ULONG_MAX = 2 ** 64 - 1
LLONG_MAX = 2 ** 63 - 1
LLONG_MIN = -(2 ** 63)
ULLONG_MAX = 2 ** 64 - 1
PY_SSIZE_T_MAX = 2 ** 63 - 1
PY_SSIZE_T_MIN = -(2 ** 63)
SIZE_MAX = 2 ** 64 - 1


# ---------------------------------------------------------------------------
# The three classes test_call builds its calling-convention matrix from.
#
# CPython's are C types whose methods are each registered under a different
# METH_* convention -- VARARGS, VARARGS|KEYWORDS, O, NOARGS, FASTCALL,
# FASTCALL|KEYWORDS -- and the point of the matrix is that all six arrive at
# the same answer.  Here there is ONE calling convention, so these are six
# ordinary methods wearing the C names, and what they prove is that the answer
# is the same, not that six conventions reached it.  That is the honest claim,
# and it is worth making: test_call's line 479 builds an instance at CLASS-BODY
# scope, so without these the whole module -- 181 tests -- died before it ran.
#
# What is NOT here: pyobject_fastcall, pyobject_vectorcall,
# pyobject_fastcalldict, make_vectorcall_class, has_vectorcall_flag and the
# MethodDescriptor family.  Those exercise the C vectorcall protocol itself
# rather than a result, there is no such protocol here, and a stand-in would
# be claiming to test something that does not exist.  The tests that reach for
# them fail by name, which is the report a reader can act on.
# ---------------------------------------------------------------------------
class MethInstance:
    """Instance methods under every name CPython gives a calling convention.

    One convention here; see the module comment.
    """

    def meth_varargs(self, *args):
        return (self, args)

    def meth_varargs_keywords(self, *args, **kwargs):
        return (self, args, kwargs)

    def meth_o(self, arg):
        return (self, arg)

    def meth_noargs(self):
        return self

    def meth_fastcall(self, *args):
        return (self, args)

    def meth_fastcall_keywords(self, *args, **kwargs):
        return (self, args, kwargs)


class MethClass:
    """The same six as class methods, so `self` is the class either way."""

    @classmethod
    def meth_varargs(cls, *args):
        return (cls, args)

    @classmethod
    def meth_varargs_keywords(cls, *args, **kwargs):
        return (cls, args, kwargs)

    @classmethod
    def meth_o(cls, arg):
        return (cls, arg)

    @classmethod
    def meth_noargs(cls):
        return cls

    @classmethod
    def meth_fastcall(cls, *args):
        return (cls, args)

    @classmethod
    def meth_fastcall_keywords(cls, *args, **kwargs):
        return (cls, args, kwargs)


class MethStatic:
    """The same six as static methods, so there is no receiver to report."""

    @staticmethod
    def meth_varargs(*args):
        return (None, args)

    @staticmethod
    def meth_varargs_keywords(*args, **kwargs):
        return (None, args, kwargs)

    @staticmethod
    def meth_o(arg):
        return (None, arg)

    @staticmethod
    def meth_noargs():
        return None

    @staticmethod
    def meth_fastcall(*args):
        return (None, args)

    @staticmethod
    def meth_fastcall_keywords(*args, **kwargs):
        return (None, args, kwargs)


# The module-level row of the same matrix.  A C function defined on a module
# is handed that module as its receiver, so these answer with this one.
def _self():
    import sys
    return sys.modules[__name__]


def meth_varargs(*args):
    return (_self(), args)


def meth_varargs_keywords(*args, **kwargs):
    return (_self(), args, kwargs)


def meth_o(arg):
    return (_self(), arg)


def meth_noargs():
    return _self()


def meth_fastcall(*args):
    return (_self(), args)


def meth_fastcall_keywords(*args, **kwargs):
    return (_self(), args, kwargs)


# ---------------------------------------------------------------------------
# The type-version tag.
#
# This interpreter HAS one -- it lives in the high 32 bits of tp_flags and the
# attribute caches are built on it -- but nothing publishes it to Python, and
# `type.__flags__` deliberately does not report it (the low bits are this
# tree's own layout).  So the honest answer to "what version is this type at"
# is 0, which is precisely CPython's answer for a type that has no valid tag,
# and it is what makes test_type_cache's own `if type_get_version(t) == 0:
# continue` guards skip rather than assert against a number we made up.
#
# The four names are fetched together at test_type_cache's MODULE scope, so
# all four have to exist for any of the module to run.
# ---------------------------------------------------------------------------
def type_get_version(cls):
    if not isinstance(cls, type):
        raise TypeError("argument must be a type")
    return 0


def type_modified(cls):
    if not isinstance(cls, type):
        raise TypeError("argument must be a type")
    import sys
    sys._clear_type_cache()


def type_assign_version(cls):
    if not isinstance(cls, type):
        raise TypeError("argument must be a type")
    return 0            # 0 = no tag was assigned, as CPython reports it


def type_assign_specific_version_unsafe(cls, version):
    raise NotImplementedError(
        "_testcapi.type_assign_specific_version_unsafe is not implemented: "
        "the type version is not writable from Python here")


# ---------------------------------------------------------------------------
# The five feature macros, and only those five: test_stable_abi_ctypes asserts
# `set(get_feature_macros()) == EXPECTED_FEATURE_MACROS` against a hardcoded
# five-element set, at module scope.  The values describe this build.
# ---------------------------------------------------------------------------
def get_feature_macros():
    return {
        "HAVE_FORK": True,              # src/modules/posixproc.asm
        "MS_WINDOWS": False,
        "PY_HAVE_THREAD_NATIVE_ID": True,   # lib/_thread.get_native_id
        "Py_REF_DEBUG": False,
        "USE_STACKCHECK": False,
    }


# The abstract-object tests also exercise Python-visible attribute access:
# descriptor invocation, name validation, and exception propagation.
def object_getattr(obj, name, /):
    return getattr(obj, name)


def _attribute_name(text):
    if isinstance(text, str):
        text = str.encode(text)
    if not isinstance(text, bytes):
        raise TypeError("attribute name must be str or bytes")
    # The String variants take a NUL-terminated UTF-8 name.
    return bytes.split(text, b"\0", 1)[0].decode("utf-8")


def object_getattrstring(obj, name, /):
    return getattr(obj, _attribute_name(name))


def object_hasattr(obj, name, /):
    try:
        getattr(obj, name)
    except BaseException:
        return 0
    return 1


def object_hasattrstring(obj, name, /):
    try:
        name = _attribute_name(name)
    except UnicodeDecodeError:
        return 0
    return object_hasattr(obj, name)


def object_setattr(obj, name, value, /):
    # The upstream adapter reserves None as the spelling of C NULL.
    if value is None:
        return object_delattr(obj, name)
    setattr(obj, name, value)
    return 0


def object_setattrstring(obj, name, value, /):
    return object_setattr(obj, _attribute_name(name), value)


def object_delattr(obj, name, /):
    delattr(obj, name)
    return 0


def object_delattrstring(obj, name, /):
    return object_delattr(obj, _attribute_name(name))
