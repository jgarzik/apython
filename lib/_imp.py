"""_imp - the import system's own primitives.

CPython's _imp is a C module, and importlib's bootstrap is written against
it: acquire_lock and release_lock around the import machinery, is_builtin and
create_builtin for the modules the interpreter carries inside it, is_frozen
and get_frozen_object for the ones it has as marshalled code, create_dynamic
for extension modules, and source_hash for a hash-based .pyc.

None of that needs to be C here.  This interpreter is single-threaded, so the
lock is a counter; there are no frozen modules and no extension modules, so
those answer "no" honestly rather than raising; and a builtin is made by the
interpreter's own loader, through _impcore.

The reason to have it at all is that importlib will not load without it, and
importlib is what twenty-one modules of CPython's Lib/ reach for -- usually a
few lines after some other import that appeared to be the blocker.
"""

import sys
import _impcore

# The GIL is not a thing here: there is one thread, so the lock is a counter
# that records the nesting importlib expects to see balanced.
_lock_count = 0


def acquire_lock():
    global _lock_count
    _lock_count += 1


def release_lock():
    global _lock_count
    if _lock_count <= 0:
        raise RuntimeError("not holding the import lock")
    _lock_count -= 1


def lock_held():
    return _lock_count > 0


# The two the interpreter wires up itself rather than through the module
# table's creator function.  CPython marks the same pair with a NULL initfunc
# in PyImport_Inittab, and is_builtin answers -1 for those: in the table, but
# not something create_builtin can make.
_ALREADY_MADE = ("sys", "builtins")


def is_builtin(name):
    """1 for a module the interpreter can create, -1 for one it already made,
    0 for anything else.

    CPython's three-valued answer, and the middle one is not about __main__:
    it means "in the table, with no initfunc", which is `sys` and `builtins`.
    """
    if name in _ALREADY_MADE:
        return -1
    return 1 if name in sys.builtin_module_names else 0


def create_builtin(spec):
    """The module object for a builtin, already initialised.

    Made by the interpreter's own loader, never by importlib: this is where
    importlib's BuiltinImporter ends up, so going through `__import__` would
    come straight back here.  Asking twice gives the same object, which is
    what CPython's does too.
    """
    name = spec.name
    if name in sys.modules:
        return sys.modules[name]
    return _impcore.create_builtin(name)


def exec_builtin(mod):
    """A builtin has no separate exec step: create_builtin finished it."""
    return 0


# ---------------------------------------------------------------------------
# Frozen modules.  CPython freezes importlib itself and a handful of others
# into the binary as marshalled code objects; this interpreter has none, and
# says so rather than pretending.
# ---------------------------------------------------------------------------

def is_frozen(name):
    return False


def find_frozen(name, *, withdata=False):
    return None


def get_frozen_object(name, data=None):
    raise ImportError("No such frozen object named %r" % (name,), name=name)


def init_frozen(name):
    return None


def is_frozen_package(name):
    raise ImportError("No such frozen object named %r" % (name,), name=name)


def _frozen_module_names():
    return []


def _override_frozen_modules_for_tests(override):
    return None


# ---------------------------------------------------------------------------
# Extension modules.  There is no dynamic loader here, so the suffix list is
# empty -- which is what makes FileFinder skip the extension hook entirely
# rather than try it and fail.
# ---------------------------------------------------------------------------

def extension_suffixes():
    """Empty, which is what makes FileFinder skip the extension hook.

    CPython answers ['.cpython-312-x86_64-linux-gnu.so', '.abi3.so', '.so'];
    there is no dynamic loader here, so offering a suffix would only make the
    finder try one and fail.
    """
    return []


def create_dynamic(spec, file=None):
    raise ImportError("dynamic modules are not supported", name=spec.name)


def exec_dynamic(mod):
    raise ImportError("dynamic modules are not supported")


def _override_multi_interp_extensions_check(override):
    return 0


# ---------------------------------------------------------------------------
# .pyc support
# ---------------------------------------------------------------------------

# "default", "always" or "never", from -X pycache_prefix.  An attribute in
# CPython too, not a function.  Nothing here sets it, so the default applies:
# a hash-based .pyc marked "checked" is verified, an unchecked one is trusted.
check_hash_based_pycs = "default"


def source_hash(key, source):
    """The 8-byte hash a hash-based .pyc carries.

    CPython uses SipHash with the key from the .pyc's magic; the algorithm
    has to match its own, because the value is written into a file that
    another interpreter may read.  This is siphash13, which is what CPython
    3.11+ uses for it.
    """
    if isinstance(source, str):
        source = source.encode("utf-8")
    return _siphash13(key & _MASK, 0, bytes(source)).to_bytes(8, "little")


def _fix_co_filename(code, path):
    """Rewrite co_filename in place, through every nested code object.

    A .pyc records the path it was compiled under; when the source has moved
    since, or was compiled under a relative name, the loader calls this so
    that tracebacks name the file where it is.
    """
    _impcore.fix_co_filename(code, path)


_MASK = (1 << 64) - 1


def _rotl(x, b):
    return ((x << b) | (x >> (64 - b))) & _MASK


def _sipround(v0, v1, v2, v3):
    """CPython's SINGLE_ROUND: two half-rounds, the second over (v2, v1, v0, v3).

    The published algorithm's round is written the other way about, and the
    two are not the same permutation -- so this follows pyhash.c line for
    line, because the number it produces goes into a .pyc another interpreter
    reads.
    """
    # HALF_ROUND(v0, v1, v2, v3, 13, 16)
    v0 = (v0 + v1) & _MASK
    v2 = (v2 + v3) & _MASK
    v1 = _rotl(v1, 13) ^ v0
    v3 = _rotl(v3, 16) ^ v2
    v0 = _rotl(v0, 32)
    # HALF_ROUND(v2, v1, v0, v3, 17, 21)
    v2 = (v2 + v1) & _MASK
    v0 = (v0 + v3) & _MASK
    v1 = _rotl(v1, 17) ^ v2
    v3 = _rotl(v3, 21) ^ v0
    v2 = _rotl(v2, 32)
    return v0, v1, v2, v3


def _siphash13(k0, k1, data):
    """CPython's siphash13: one round per block, three at the end.

    The result folds as (v0 ^ v1) ^ (v2 ^ v3), which pyhash.c marks
    "modified" -- the published algorithm xors all four together.  The
    difference matters, because the value goes into a .pyc another
    interpreter reads.
    """
    b = (len(data) << 56) & _MASK
    v0 = k0 ^ 0x736F6D6570736575
    v1 = k1 ^ 0x646F72616E646F6D
    v2 = k0 ^ 0x6C7967656E657261
    v3 = k1 ^ 0x7465646279746573

    n = len(data)
    full = n - (n % 8)
    for i in range(0, full, 8):
        m = int.from_bytes(data[i:i + 8], "little")
        v3 ^= m
        v0, v1, v2, v3 = _sipround(v0, v1, v2, v3)
        v0 ^= m

    b |= int.from_bytes(data[full:] + b"\0" * (8 - (n - full)), "little")
    v3 ^= b
    v0, v1, v2, v3 = _sipround(v0, v1, v2, v3)
    v0 ^= b

    v2 ^= 0xFF
    for _ in range(3):
        v0, v1, v2, v3 = _sipround(v0, v1, v2, v3)
    return ((v0 ^ v1) ^ (v2 ^ v3)) & _MASK
