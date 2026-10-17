# `lib/` — what stands in for CPython's C modules

apython runs CPython's own standard library: `../stdlib/` is CPython 3.12's
`Lib/`, unmodified, copied by `tools/vendor_stdlib.sh` (see
`../stdlib/VENDORED`).  What CPython implements in C, apython implements in
assembly -- the builtin modules in `../src/modules/` -- or here, in Python.
This directory is that second half and nothing else.

It comes AFTER `stdlib/` on `sys.path`, so no file here can shadow a CPython
module of the same name.  A module that needs to differ from CPython's is a
bug to fix or a C module to provide; it does not belong ahead of the real one.
In an installed tree this directory is `lib/python3.12/lib-dynload/`, which is
where CPython keeps its own C extension modules.

`test/` is the exception, and is not a stand-in: it is the handful of
CPython's `Lib/test` helpers that `tests/cpython/` imports, some modified.
CPython's `Lib/test` is not vendored, so nothing here shadows it.

## Provenance

The files written for apython are covered by the repository's MIT license
(`../LICENSE`).  Each carries a docstring saying what it implements and what
it does not.  The files derived from CPython are covered by the Python
Software Foundation License as well (`LICENSE.python`).

| Origin | Files |
|---|---|
| Generated from CPython | `_ast.py` (by `src/compiler/gen_ast.py`) |
| CPython, modified for apython | `test/` |
| Written for apython | `_ast_build.py`, `atexit.py`, `audioop.py`, `binascii.py`, `_blake2.py`, `_bz2.py`, `_codecs.py`, `_collections.py`, `_contextvars.py`, `_csv.py`, `_datetime.py`, `_decimal.py`, `faulthandler.py`, `fcntl.py`, `_frozen_importlib.py`, `_frozen_importlib_external.py`, `_importlib_bootstrap.py`, `grp.py`, `_hashlib.py`, `_imp.py`, `_io.py`, `itertools.py`, `_json.py`, `_lsprof.py`, `_lzma.py`, `_md5.py`, `mmap.py`, `_operator.py`, `_pickle.py`, `_posixsubprocess.py`, `pwd.py`, `pyexpat.py`, `_random.py`, `_reduce.py`, `resource.py`, `_runmodule.py`, `select.py`, `_sha1.py`, `_sha2.py`, `_sha3.py`, `_signal.py`, `_socket.py`, `_string.py`, `_struct.py`, `_sysconfigdata__linux_.py`, `syslog.py`, `termios.py`, `_testcapi.py`, `_testinternalcapi.py`, `_thread.py`, `_tokenize.py`, `_typing.py`, `_warnings.py`, `zlib.py` |

The table is the licence attribution for this directory, so a file added
here belongs in it.

## The two-halves modules

Several C modules are split between assembly and Python: the syscalls, the
struct layouts and the hot loops are a builtin module named `_<x>core`, and
the object model on top of them is a file here named for the C module CPython
has.  The split is invisible from outside -- the types report the C module's
name in their `__module__`, and CPython's own Python module imports from it
unchanged.

- `_io.py` over `_iocore`: the buffering and text layers over the raw layer
  and the type objects.  It must not be called `_pyio`, which is CPython's
  own Python replica of the C module and would then be found in `stdlib/`.
- `_socket.py` and `select.py` over `_socketcore`: the socket type, the
  sockaddr packing for AF_INET and AF_UNIX, the timeout loop, and `select()`
  over `poll()`.  IPv6, `sendmsg`/`recvmsg` and a real resolver are absent:
  `getaddrinfo` answers for dotted quads and for the names in `/etc/hosts`,
  and `Lib/socket.py` guards the rest with `hasattr`.
- `_signal.py` over `_signalcore`: `ItimerError` and `valid_signals()` over
  the handlers and the trampoline.
- `zlib.py`, `_bz2.py`, `_lzma.py` and `_hashlib.py` over `_zlibcore`,
  `_bz2core`, `_lzmacore` and `_hashlibcore`: shims over the system
  libraries, where the core takes fixed positional arguments and every
  default, keyword and error wording is Python's business.

## The alias modules

`_datetime.py`, `_json.py`, `_pickle.py` and `_decimal.py` exist so that
`test.support.import_fresh_module` does not return None for the accelerator;
none of them is faster than the pure-Python module it re-exports.  See
DIVERGENCES.md, "The alias modules in lib/".
