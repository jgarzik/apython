"""_sqlite3: Python surface over the _sqlite3core native libsqlite3 shim.

Follows the same split as _zlibcore/zlib.py and _pyexpatcore/pyexpat.py:
src/modules/sqlite3*.asm own the libsqlite3 handles, blocking C calls (with
GIL release), and C-to-Python callback trampolines; everything visible to
Python lives here, imported by the unmodified CPython stdlib/sqlite3/ package.
"""

import collections.abc
import functools
import os
import sys
import _thread
import warnings
import weakref

import _sqlite3core as _core

# ---------------------------------------------------------------------------
# Version & module metadata
# ---------------------------------------------------------------------------

sqlite_version = _core.SQLITE_VERSION
_deprecated_version = "2.6.0"

PARSE_DECLTYPES = 1
PARSE_COLNAMES = 2
LEGACY_TRANSACTION_CONTROL = -1

# ---------------------------------------------------------------------------
# DB-API 2.0 Exception hierarchy
# ---------------------------------------------------------------------------


class Warning(Exception):
    __module__ = "sqlite3"


class Error(Exception):
    __module__ = "sqlite3"


class InterfaceError(Error):
    __module__ = "sqlite3"


class DatabaseError(Error):
    __module__ = "sqlite3"


class DataError(DatabaseError):
    __module__ = "sqlite3"


_core.set_data_error_type(DataError)


class OperationalError(DatabaseError):
    __module__ = "sqlite3"


class IntegrityError(DatabaseError):
    __module__ = "sqlite3"


class InternalError(DatabaseError):
    __module__ = "sqlite3"


class ProgrammingError(DatabaseError):
    __module__ = "sqlite3"


class NotSupportedError(DatabaseError):
    __module__ = "sqlite3"


def _compute_threadsafety():
    mode = _core.THREADSAFE
    if mode == 0:
        return 0
    if mode == 1:
        return 3
    if mode == 2:
        return 1
    raise InterfaceError(
        f"Unable to interpret SQLite threadsafety mode. Got {mode}, "
        "expected 0, 1, or 2"
    )


threadsafety = _compute_threadsafety()
del _compute_threadsafety

# ---------------------------------------------------------------------------
# SQLite constants (result codes, authorizer actions, limits, dbconfig)
# ---------------------------------------------------------------------------

# Primary result codes
SQLITE_OK = 0
SQLITE_ERROR = 1
SQLITE_INTERNAL = 2
SQLITE_PERM = 3
SQLITE_ABORT = 4
SQLITE_BUSY = 5
SQLITE_LOCKED = 6
SQLITE_NOMEM = 7
SQLITE_READONLY = 8
SQLITE_INTERRUPT = 9
SQLITE_IOERR = 10
SQLITE_CORRUPT = 11
SQLITE_NOTFOUND = 12
SQLITE_FULL = 13
SQLITE_CANTOPEN = 14
SQLITE_PROTOCOL = 15
SQLITE_EMPTY = 16
SQLITE_SCHEMA = 17
SQLITE_TOOBIG = 18
SQLITE_CONSTRAINT = 19
SQLITE_MISMATCH = 20
SQLITE_MISUSE = 21
SQLITE_NOLFS = 22
SQLITE_AUTH = 23
SQLITE_FORMAT = 24
SQLITE_RANGE = 25
SQLITE_NOTADB = 26
SQLITE_NOTICE = 27
SQLITE_WARNING = 28
SQLITE_ROW = 100
SQLITE_DONE = 101

# Extended result codes
SQLITE_ERROR_MISSING_COLLSEQ = 257
SQLITE_ERROR_RETRY = 513
SQLITE_ERROR_SNAPSHOT = 769
SQLITE_IOERR_READ = 266
SQLITE_IOERR_SHORT_READ = 522
SQLITE_IOERR_WRITE = 778
SQLITE_IOERR_FSYNC = 1034
SQLITE_IOERR_DIR_FSYNC = 1290
SQLITE_IOERR_TRUNCATE = 1546
SQLITE_IOERR_FSTAT = 1802
SQLITE_IOERR_UNLOCK = 2058
SQLITE_IOERR_RDLOCK = 2314
SQLITE_IOERR_DELETE = 2570
SQLITE_IOERR_BLOCKED = 2826
SQLITE_IOERR_NOMEM = 3082
SQLITE_IOERR_ACCESS = 3338
SQLITE_IOERR_CHECKRESERVEDLOCK = 3594
SQLITE_IOERR_LOCK = 3850
SQLITE_IOERR_CLOSE = 4106
SQLITE_IOERR_DIR_CLOSE = 4362
SQLITE_IOERR_SHMOPEN = 4618
SQLITE_IOERR_SHMSIZE = 4874
SQLITE_IOERR_SHMLOCK = 5130
SQLITE_IOERR_SHMMAP = 5386
SQLITE_IOERR_SEEK = 5642
SQLITE_IOERR_DELETE_NOENT = 5898
SQLITE_IOERR_MMAP = 6154
SQLITE_IOERR_GETTEMPPATH = 6410
SQLITE_IOERR_CONVPATH = 6666
SQLITE_IOERR_VNODE = 6922
SQLITE_IOERR_AUTH = 7178
SQLITE_IOERR_BEGIN_ATOMIC = 7434
SQLITE_IOERR_COMMIT_ATOMIC = 7690
SQLITE_IOERR_ROLLBACK_ATOMIC = 7946
SQLITE_IOERR_DATA = 8202
SQLITE_IOERR_CORRUPTFS = 8458
SQLITE_LOCKED_SHAREDCACHE = 262
SQLITE_LOCKED_VTAB = 518
SQLITE_BUSY_RECOVERY = 261
SQLITE_BUSY_SNAPSHOT = 517
SQLITE_BUSY_TIMEOUT = 773
SQLITE_CANTOPEN_NOTEMPDIR = 270
SQLITE_CANTOPEN_ISDIR = 526
SQLITE_CANTOPEN_FULLPATH = 782
SQLITE_CANTOPEN_CONVPATH = 1038
SQLITE_CANTOPEN_DIRTYWAL = 1294
SQLITE_CANTOPEN_SYMLINK = 1550
SQLITE_CORRUPT_VTAB = 267
SQLITE_CORRUPT_SEQUENCE = 523
SQLITE_CORRUPT_INDEX = 779
SQLITE_READONLY_RECOVERY = 264
SQLITE_READONLY_CANTLOCK = 520
SQLITE_READONLY_ROLLBACK = 776
SQLITE_READONLY_DBMOVED = 1032
SQLITE_READONLY_CANTINIT = 1288
SQLITE_READONLY_DIRECTORY = 1544
SQLITE_ABORT_ROLLBACK = 516
SQLITE_CONSTRAINT_CHECK = 275
SQLITE_CONSTRAINT_COMMITHOOK = 531
SQLITE_CONSTRAINT_FOREIGNKEY = 787
SQLITE_CONSTRAINT_FUNCTION = 1043
SQLITE_CONSTRAINT_NOTNULL = 1299
SQLITE_CONSTRAINT_PRIMARYKEY = 1555
SQLITE_CONSTRAINT_TRIGGER = 1811
SQLITE_CONSTRAINT_UNIQUE = 2067
SQLITE_CONSTRAINT_VTAB = 2323
SQLITE_CONSTRAINT_ROWID = 2579
SQLITE_CONSTRAINT_PINNED = 2835
SQLITE_NOTICE_RECOVER_WAL = 283
SQLITE_NOTICE_RECOVER_ROLLBACK = 539
SQLITE_WARNING_AUTOINDEX = 284
SQLITE_AUTH_USER = 279
SQLITE_OK_LOAD_PERMANENTLY = 256
SQLITE_OK_SYMLINK = 512

_ERROR_NAMES = {
    SQLITE_ABORT: "SQLITE_ABORT",
    SQLITE_AUTH: "SQLITE_AUTH",
    SQLITE_BUSY: "SQLITE_BUSY",
    SQLITE_CANTOPEN: "SQLITE_CANTOPEN",
    SQLITE_CONSTRAINT: "SQLITE_CONSTRAINT",
    SQLITE_CORRUPT: "SQLITE_CORRUPT",
    SQLITE_DONE: "SQLITE_DONE",
    SQLITE_EMPTY: "SQLITE_EMPTY",
    SQLITE_ERROR: "SQLITE_ERROR",
    SQLITE_FORMAT: "SQLITE_FORMAT",
    SQLITE_FULL: "SQLITE_FULL",
    SQLITE_INTERNAL: "SQLITE_INTERNAL",
    SQLITE_INTERRUPT: "SQLITE_INTERRUPT",
    SQLITE_IOERR: "SQLITE_IOERR",
    SQLITE_LOCKED: "SQLITE_LOCKED",
    SQLITE_MISMATCH: "SQLITE_MISMATCH",
    SQLITE_MISUSE: "SQLITE_MISUSE",
    SQLITE_NOLFS: "SQLITE_NOLFS",
    SQLITE_NOMEM: "SQLITE_NOMEM",
    SQLITE_NOTADB: "SQLITE_NOTADB",
    SQLITE_NOTFOUND: "SQLITE_NOTFOUND",
    SQLITE_OK: "SQLITE_OK",
    SQLITE_PERM: "SQLITE_PERM",
    SQLITE_PROTOCOL: "SQLITE_PROTOCOL",
    SQLITE_RANGE: "SQLITE_RANGE",
    SQLITE_READONLY: "SQLITE_READONLY",
    SQLITE_ROW: "SQLITE_ROW",
    SQLITE_SCHEMA: "SQLITE_SCHEMA",
    SQLITE_TOOBIG: "SQLITE_TOOBIG",
    SQLITE_NOTICE: "SQLITE_NOTICE",
    SQLITE_WARNING: "SQLITE_WARNING",
    SQLITE_ABORT_ROLLBACK: "SQLITE_ABORT_ROLLBACK",
    SQLITE_BUSY_RECOVERY: "SQLITE_BUSY_RECOVERY",
    SQLITE_CANTOPEN_FULLPATH: "SQLITE_CANTOPEN_FULLPATH",
    SQLITE_CANTOPEN_ISDIR: "SQLITE_CANTOPEN_ISDIR",
    SQLITE_CANTOPEN_NOTEMPDIR: "SQLITE_CANTOPEN_NOTEMPDIR",
    SQLITE_CORRUPT_VTAB: "SQLITE_CORRUPT_VTAB",
    SQLITE_IOERR_ACCESS: "SQLITE_IOERR_ACCESS",
    SQLITE_IOERR_BLOCKED: "SQLITE_IOERR_BLOCKED",
    SQLITE_IOERR_CHECKRESERVEDLOCK: "SQLITE_IOERR_CHECKRESERVEDLOCK",
    SQLITE_IOERR_CLOSE: "SQLITE_IOERR_CLOSE",
    SQLITE_IOERR_DELETE: "SQLITE_IOERR_DELETE",
    SQLITE_IOERR_DELETE_NOENT: "SQLITE_IOERR_DELETE_NOENT",
    SQLITE_IOERR_DIR_CLOSE: "SQLITE_IOERR_DIR_CLOSE",
    SQLITE_IOERR_DIR_FSYNC: "SQLITE_IOERR_DIR_FSYNC",
    SQLITE_IOERR_FSTAT: "SQLITE_IOERR_FSTAT",
    SQLITE_IOERR_FSYNC: "SQLITE_IOERR_FSYNC",
    SQLITE_IOERR_LOCK: "SQLITE_IOERR_LOCK",
    SQLITE_IOERR_NOMEM: "SQLITE_IOERR_NOMEM",
    SQLITE_IOERR_RDLOCK: "SQLITE_IOERR_RDLOCK",
    SQLITE_IOERR_READ: "SQLITE_IOERR_READ",
    SQLITE_IOERR_SEEK: "SQLITE_IOERR_SEEK",
    SQLITE_IOERR_SHMLOCK: "SQLITE_IOERR_SHMLOCK",
    SQLITE_IOERR_SHMMAP: "SQLITE_IOERR_SHMMAP",
    SQLITE_IOERR_SHMOPEN: "SQLITE_IOERR_SHMOPEN",
    SQLITE_IOERR_SHMSIZE: "SQLITE_IOERR_SHMSIZE",
    SQLITE_IOERR_SHORT_READ: "SQLITE_IOERR_SHORT_READ",
    SQLITE_IOERR_TRUNCATE: "SQLITE_IOERR_TRUNCATE",
    SQLITE_IOERR_UNLOCK: "SQLITE_IOERR_UNLOCK",
    SQLITE_IOERR_WRITE: "SQLITE_IOERR_WRITE",
    SQLITE_LOCKED_SHAREDCACHE: "SQLITE_LOCKED_SHAREDCACHE",
    SQLITE_READONLY_CANTLOCK: "SQLITE_READONLY_CANTLOCK",
    SQLITE_READONLY_RECOVERY: "SQLITE_READONLY_RECOVERY",
    SQLITE_CONSTRAINT_CHECK: "SQLITE_CONSTRAINT_CHECK",
    SQLITE_CONSTRAINT_COMMITHOOK: "SQLITE_CONSTRAINT_COMMITHOOK",
    SQLITE_CONSTRAINT_FOREIGNKEY: "SQLITE_CONSTRAINT_FOREIGNKEY",
    SQLITE_CONSTRAINT_FUNCTION: "SQLITE_CONSTRAINT_FUNCTION",
    SQLITE_CONSTRAINT_NOTNULL: "SQLITE_CONSTRAINT_NOTNULL",
    SQLITE_CONSTRAINT_PRIMARYKEY: "SQLITE_CONSTRAINT_PRIMARYKEY",
    SQLITE_CONSTRAINT_TRIGGER: "SQLITE_CONSTRAINT_TRIGGER",
    SQLITE_CONSTRAINT_UNIQUE: "SQLITE_CONSTRAINT_UNIQUE",
    SQLITE_CONSTRAINT_VTAB: "SQLITE_CONSTRAINT_VTAB",
    SQLITE_READONLY_ROLLBACK: "SQLITE_READONLY_ROLLBACK",
    SQLITE_IOERR_MMAP: "SQLITE_IOERR_MMAP",
    SQLITE_NOTICE_RECOVER_ROLLBACK: "SQLITE_NOTICE_RECOVER_ROLLBACK",
    SQLITE_NOTICE_RECOVER_WAL: "SQLITE_NOTICE_RECOVER_WAL",
    SQLITE_BUSY_SNAPSHOT: "SQLITE_BUSY_SNAPSHOT",
    SQLITE_IOERR_GETTEMPPATH: "SQLITE_IOERR_GETTEMPPATH",
    SQLITE_WARNING_AUTOINDEX: "SQLITE_WARNING_AUTOINDEX",
    SQLITE_CANTOPEN_CONVPATH: "SQLITE_CANTOPEN_CONVPATH",
    SQLITE_IOERR_CONVPATH: "SQLITE_IOERR_CONVPATH",
    SQLITE_CONSTRAINT_ROWID: "SQLITE_CONSTRAINT_ROWID",
    SQLITE_READONLY_DBMOVED: "SQLITE_READONLY_DBMOVED",
    SQLITE_AUTH_USER: "SQLITE_AUTH_USER",
    SQLITE_IOERR_VNODE: "SQLITE_IOERR_VNODE",
    SQLITE_IOERR_AUTH: "SQLITE_IOERR_AUTH",
    SQLITE_OK_LOAD_PERMANENTLY: "SQLITE_OK_LOAD_PERMANENTLY",
    SQLITE_IOERR_BEGIN_ATOMIC: "SQLITE_IOERR_BEGIN_ATOMIC",
    SQLITE_IOERR_COMMIT_ATOMIC: "SQLITE_IOERR_COMMIT_ATOMIC",
    SQLITE_IOERR_ROLLBACK_ATOMIC: "SQLITE_IOERR_ROLLBACK_ATOMIC",
    SQLITE_ERROR_MISSING_COLLSEQ: "SQLITE_ERROR_MISSING_COLLSEQ",
    SQLITE_ERROR_RETRY: "SQLITE_ERROR_RETRY",
    SQLITE_READONLY_CANTINIT: "SQLITE_READONLY_CANTINIT",
    SQLITE_READONLY_DIRECTORY: "SQLITE_READONLY_DIRECTORY",
    SQLITE_CORRUPT_SEQUENCE: "SQLITE_CORRUPT_SEQUENCE",
    SQLITE_LOCKED_VTAB: "SQLITE_LOCKED_VTAB",
    SQLITE_CANTOPEN_DIRTYWAL: "SQLITE_CANTOPEN_DIRTYWAL",
    SQLITE_ERROR_SNAPSHOT: "SQLITE_ERROR_SNAPSHOT",
    SQLITE_CANTOPEN_SYMLINK: "SQLITE_CANTOPEN_SYMLINK",
    SQLITE_CONSTRAINT_PINNED: "SQLITE_CONSTRAINT_PINNED",
    SQLITE_OK_SYMLINK: "SQLITE_OK_SYMLINK",
    SQLITE_BUSY_TIMEOUT: "SQLITE_BUSY_TIMEOUT",
    SQLITE_CORRUPT_INDEX: "SQLITE_CORRUPT_INDEX",
    SQLITE_IOERR_DATA: "SQLITE_IOERR_DATA",
    SQLITE_IOERR_CORRUPTFS: "SQLITE_IOERR_CORRUPTFS",
}

# Authorizer return codes and action codes
SQLITE_DENY = 1
SQLITE_IGNORE = 2
SQLITE_CREATE_INDEX = 1
SQLITE_CREATE_TABLE = 2
SQLITE_CREATE_TEMP_INDEX = 3
SQLITE_CREATE_TEMP_TABLE = 4
SQLITE_CREATE_TEMP_TRIGGER = 5
SQLITE_CREATE_TEMP_VIEW = 6
SQLITE_CREATE_TRIGGER = 7
SQLITE_CREATE_VIEW = 8
SQLITE_DELETE = 9
SQLITE_DROP_INDEX = 10
SQLITE_DROP_TABLE = 11
SQLITE_DROP_TEMP_INDEX = 12
SQLITE_DROP_TEMP_TABLE = 13
SQLITE_DROP_TEMP_TRIGGER = 14
SQLITE_DROP_TEMP_VIEW = 15
SQLITE_DROP_TRIGGER = 16
SQLITE_DROP_VIEW = 17
SQLITE_INSERT = 18
SQLITE_PRAGMA = 19
SQLITE_READ = 20
SQLITE_SELECT = 21
SQLITE_TRANSACTION = 22
SQLITE_UPDATE = 23
SQLITE_ATTACH = 24
SQLITE_DETACH = 25
SQLITE_ALTER_TABLE = 26
SQLITE_REINDEX = 27
SQLITE_ANALYZE = 28
SQLITE_CREATE_VTABLE = 29
SQLITE_DROP_VTABLE = 30
SQLITE_FUNCTION = 31
SQLITE_SAVEPOINT = 32
SQLITE_RECURSIVE = 33

# Run-time limit categories
SQLITE_LIMIT_LENGTH = 0
SQLITE_LIMIT_SQL_LENGTH = 1
SQLITE_LIMIT_COLUMN = 2
SQLITE_LIMIT_EXPR_DEPTH = 3
SQLITE_LIMIT_COMPOUND_SELECT = 4
SQLITE_LIMIT_VDBE_OP = 5
SQLITE_LIMIT_FUNCTION_ARG = 6
SQLITE_LIMIT_ATTACHED = 7
SQLITE_LIMIT_LIKE_PATTERN_LENGTH = 8
SQLITE_LIMIT_VARIABLE_NUMBER = 9
SQLITE_LIMIT_TRIGGER_DEPTH = 10
SQLITE_LIMIT_WORKER_THREADS = 11

# Database connection configuration options
SQLITE_DBCONFIG_ENABLE_FKEY = 1002
SQLITE_DBCONFIG_ENABLE_TRIGGER = 1003
SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER = 1004
SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION = 1005
SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE = 1006
SQLITE_DBCONFIG_ENABLE_QPSG = 1007
SQLITE_DBCONFIG_TRIGGER_EQP = 1008
SQLITE_DBCONFIG_RESET_DATABASE = 1009
SQLITE_DBCONFIG_DEFENSIVE = 1010
SQLITE_DBCONFIG_WRITABLE_SCHEMA = 1011
SQLITE_DBCONFIG_LEGACY_ALTER_TABLE = 1012
SQLITE_DBCONFIG_DQS_DML = 1013
SQLITE_DBCONFIG_DQS_DDL = 1014
SQLITE_DBCONFIG_ENABLE_VIEW = 1015
SQLITE_DBCONFIG_LEGACY_FILE_FORMAT = 1016
SQLITE_DBCONFIG_TRUSTED_SCHEMA = 1017

_VALID_DBCONFIG_OPS = frozenset({
    SQLITE_DBCONFIG_ENABLE_FKEY,
    SQLITE_DBCONFIG_ENABLE_TRIGGER,
    SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER,
    SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION,
    SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE,
    SQLITE_DBCONFIG_ENABLE_QPSG,
    SQLITE_DBCONFIG_TRIGGER_EQP,
    SQLITE_DBCONFIG_RESET_DATABASE,
    SQLITE_DBCONFIG_DEFENSIVE,
    SQLITE_DBCONFIG_WRITABLE_SCHEMA,
    SQLITE_DBCONFIG_LEGACY_ALTER_TABLE,
    SQLITE_DBCONFIG_DQS_DML,
    SQLITE_DBCONFIG_DQS_DDL,
    SQLITE_DBCONFIG_ENABLE_VIEW,
    SQLITE_DBCONFIG_LEGACY_FILE_FORMAT,
    SQLITE_DBCONFIG_TRUSTED_SCHEMA,
})

# Internal SQLite constants (not exported by import *)
_SQLITE_INTEGER = 1
_SQLITE_FLOAT = 2
_SQLITE_TEXT = 3
_SQLITE_BLOB = 4
_SQLITE_NULL = 5

_SQLITE_OPEN_READWRITE = 0x00000002
_SQLITE_OPEN_CREATE = 0x00000004
_SQLITE_OPEN_URI = 0x00000040
_SQLITE_UTF8 = 1
_SQLITE_DETERMINISTIC = 0x00000800

_SENTINEL = object()

# ---------------------------------------------------------------------------
# Error mapping helper
# ---------------------------------------------------------------------------

_EXC_MAP = {
    SQLITE_INTERNAL: InternalError,
    SQLITE_NOTFOUND: InternalError,
    SQLITE_ERROR: OperationalError,
    SQLITE_PERM: OperationalError,
    SQLITE_ABORT: OperationalError,
    SQLITE_BUSY: OperationalError,
    SQLITE_LOCKED: OperationalError,
    SQLITE_READONLY: OperationalError,
    SQLITE_INTERRUPT: OperationalError,
    SQLITE_IOERR: OperationalError,
    SQLITE_FULL: OperationalError,
    SQLITE_CANTOPEN: OperationalError,
    SQLITE_PROTOCOL: OperationalError,
    SQLITE_EMPTY: OperationalError,
    SQLITE_SCHEMA: OperationalError,
    SQLITE_CORRUPT: DatabaseError,
    SQLITE_TOOBIG: DataError,
    SQLITE_CONSTRAINT: IntegrityError,
    SQLITE_MISMATCH: IntegrityError,
    SQLITE_MISUSE: InterfaceError,
    SQLITE_RANGE: InterfaceError,
}


def _make_sqlite_error(db_h):
    code = _core.errcode(db_h)
    if code == SQLITE_OK:
        return None
    if code == SQLITE_NOMEM:
        return MemoryError()
    ext = _core.extended_errcode(db_h)
    msg = _core.errmsg(db_h)
    cls = _EXC_MAP.get(code, DatabaseError)
    exc = cls(msg)
    exc.sqlite_errorcode = ext
    exc.sqlite_errorname = _ERROR_NAMES.get(ext, "unknown")
    return exc


def _raise_sqlite_error(db_h):
    exc = _make_sqlite_error(db_h)
    if exc is not None:
        raise exc


def _encode_cstr(val, name="argument"):
    if not isinstance(val, str):
        raise TypeError(f"{name} must be str, not {type(val).__name__}")
    raw = str.encode(val, "utf-8")
    if b"\x00" in raw:
        raise ValueError("embedded null character")
    return raw


# ---------------------------------------------------------------------------
# Microprotocols (adapters & converters)
# ---------------------------------------------------------------------------


class PrepareProtocol:
    __module__ = "sqlite3"


adapters = {}
converters = {}
_base_type_adapted = False


def register_adapter(type_, adapter, /):
    """Register a function to adapt Python objects to SQLite values."""
    global _base_type_adapted
    if not isinstance(type_, type):
        raise TypeError(
            f"register_adapter() argument 1 must be type, not {type(type_).__name__}"
        )
    if type_ in (int, float, str, bytearray):
        _base_type_adapted = True
    adapters[(type_, PrepareProtocol)] = adapter


def register_converter(typename, converter, /):
    """Register a function to convert SQLite values to Python objects."""
    if not isinstance(typename, str):
        raise TypeError(
            f"register_converter() argument 1 must be str, not {type(typename).__name__}"
        )
    converters[typename.upper()] = converter


def adapt(obj, proto=PrepareProtocol, alt=_SENTINEL, /):
    """Adapt given object to given protocol."""
    adapter = adapters.get((type(obj), proto))
    if adapter is not None:
        return adapter(obj)

    adapt_fn = getattr(proto, "__adapt__", None)
    if adapt_fn is not None:
        try:
            adapted = adapt_fn(obj)
        except TypeError:
            pass
        else:
            if adapted is not None:
                return adapted

    conform_fn = getattr(obj, "__conform__", None)
    if conform_fn is not None:
        try:
            adapted = conform_fn(proto)
        except TypeError:
            pass
        else:
            if adapted is not None:
                return adapted

    if alt is not _SENTINEL:
        return alt
    raise ProgrammingError("can't adapt")


def _need_adapt(obj):
    if _base_type_adapted:
        return True
    t = type(obj)
    return t is not int and t is not float and t is not str and t is not bytearray


def complete_statement(statement):
    """Checks if a string contains a complete SQL statement."""
    raw = _encode_cstr(statement, "statement")
    return _core.complete(raw)


def enable_callback_tracebacks(flag, /):
    """Enable or disable callback functions throwing errors to stderr."""
    _core.set_callback_tracebacks(1 if flag else 0)


# ---------------------------------------------------------------------------
# SQL comment/whitespace stripping & DML detection (matches statement.c)
# ---------------------------------------------------------------------------

_DML_PREFIXES = ("insert", "update", "delete", "replace")


def _lstrip_sql_bytes(b, pos=0):
    n = len(b)
    while pos < n:
        c = b[pos]
        if c in (32, 9, 12, 10, 13):  # ' ', '\t', '\f', '\n', '\r'
            pos += 1
        elif c == 45 and pos + 1 < n and b[pos + 1] == 45:  # '--'
            pos += 2
            while pos < n and b[pos] != 10:
                pos += 1
            if pos >= n:
                return -1
            pos += 1
        elif c == 47 and pos + 1 < n and b[pos + 1] == 42:  # '/*'
            pos += 2
            while pos < n and not (b[pos] == 42 and pos + 1 < n and b[pos + 1] == 47):
                pos += 1
            if pos >= n:
                return -1
            pos += 2
        else:
            return pos
    return -1


class _Statement:
    __module__ = "sqlite3"
    __slots__ = ("_h", "_is_dml")

    def __new__(cls, *args, **kwargs):
        raise TypeError(f"cannot create '{cls.__module__}.{cls.__name__}' instances")

    @classmethod
    def _from_handle(cls, stmt_h, is_dml):
        self = object.__new__(cls)
        self._h = stmt_h
        self._is_dml = is_dml
        return self

    def _reset(self):
        h = getattr(self, "_h", 0)
        if h:
            return _core.reset(h)
        return SQLITE_OK

    def _finalize(self):
        h = getattr(self, "_h", 0)
        if h:
            self._h = 0
            try:
                _core.finalize(h)
            except Exception:
                pass

    def __del__(self):
        self._finalize()


# ---------------------------------------------------------------------------
# Isolation level & autocommit validation
# ---------------------------------------------------------------------------

_ALLOWED_ISOLATION = {
    "": "",
    "deferred": "DEFERRED",
    "immediate": "IMMEDIATE",
    "exclusive": "EXCLUSIVE",
}


def _convert_isolation_level(val):
    if val is None:
        return None
    if not isinstance(val, str):
        raise TypeError("isolation_level must be str or None")
    if "\x00" in val:
        raise ValueError("embedded null character")
    key = val.lower()
    if key in _ALLOWED_ISOLATION:
        return _ALLOWED_ISOLATION[key]
    raise ValueError(
        "isolation_level string must be '', 'DEFERRED', 'IMMEDIATE', or 'EXCLUSIVE'"
    )


def _convert_autocommit(val):
    if val is True:
        return True
    if val is False:
        return False
    if isinstance(val, int) and val == LEGACY_TRANSACTION_CONTROL:
        return LEGACY_TRANSACTION_CONTROL
    raise ValueError(
        "autocommit must be True, False, or sqlite3.LEGACY_TRANSACTION_CONTROL"
    )


def _check_cint(val):
    if not isinstance(val, int):
        raise TypeError(f"'{type(val).__name__}' object cannot be interpreted as an integer")
    if val < -2147483648 or val > 2147483647:
        raise OverflowError("Python int too large to convert to C int")
    return int(val)


def _to_bytes_like(data, allow_str=False):
    if allow_str and isinstance(data, str):
        return str.encode(data, "utf-8")
    t = type(data)
    if t is bytes or t is bytearray:
        return data
    if t is memoryview:
        if not data.c_contiguous:
            raise BufferError("underlying buffer is not C-contiguous")
        return data
    mv = memoryview(data)
    try:
        if not mv.c_contiguous:
            raise BufferError("underlying buffer is not C-contiguous")
        return mv.tobytes()
    finally:
        mv.release()


# ---------------------------------------------------------------------------
# Blob (incremental BLOB I/O)
# ---------------------------------------------------------------------------


class Blob:
    __module__ = "sqlite3"
    __iter__ = None

    def __new__(cls, *args, **kwargs):
        raise TypeError("cannot create 'sqlite3.Blob' instances")

    @classmethod
    def _from_handle(cls, connection, blob_h):
        self = object.__new__(cls)
        self._connection = connection
        self._h = blob_h
        self._offset = 0
        return self

    def _close_raw(self):
        h = getattr(self, "_h", 0)
        if h:
            self._h = 0
            try:
                _core.blob_close(h)
            except Exception:
                pass

    def _check_blob(self):
        self._connection._check_connection()
        self._connection._check_thread()
        if not self._h:
            raise ProgrammingError("Cannot operate on a closed blob.")

    def close(self):
        """Close the blob."""
        self._connection._check_connection()
        self._connection._check_thread()
        self._close_raw()

    def __del__(self):
        self._close_raw()

    def __enter__(self):
        self._check_blob()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb, /):
        self._check_blob()
        self._close_raw()
        return False

    def __len__(self):
        self._check_blob()
        return _core.blob_bytes(self._h)

    def _read_multiple(self, length, offset):
        if length == 0:
            return b""
        rc, data = _core.blob_read(self._h, length, offset)
        if rc != SQLITE_OK:
            _raise_sqlite_error(self._connection._db)
        return data

    def _write_raw(self, data, offset):
        blob_len = _core.blob_bytes(self._h)
        if len(data) > blob_len - offset:
            raise ValueError("data longer than blob length")
        rc = _core.blob_write(self._h, data, offset)
        if rc != SQLITE_OK:
            _raise_sqlite_error(self._connection._db)

    def read(self, length=-1, /):
        """Read data at the current offset position."""
        self._check_blob()
        length = _check_cint(length)
        blob_len = _core.blob_bytes(self._h)
        max_read = blob_len - self._offset
        if length < 0 or length > max_read:
            length = max_read
        if length == 0:
            return b""
        data = self._read_multiple(length, self._offset)
        self._offset += length
        return data

    def write(self, data, /):
        """Write data at the current offset."""
        self._check_blob()
        buf = _to_bytes_like(data)
        self._write_raw(buf, self._offset)
        self._offset += len(buf)

    def seek(self, offset, origin=0, /):
        """Set the current access position to offset."""
        self._check_blob()
        offset = _check_cint(offset)
        origin = _check_cint(origin)
        blob_len = _core.blob_bytes(self._h)
        if origin == 0:  # SEEK_SET
            pos = offset
        elif origin == 1:  # SEEK_CUR
            if offset > 2147483647 - self._offset:
                raise OverflowError("seek offset results in overflow")
            pos = self._offset + offset
        elif origin == 2:  # SEEK_END
            if offset > 2147483647 - blob_len:
                raise OverflowError("seek offset results in overflow")
            pos = blob_len + offset
        else:
            raise ValueError(
                "'origin' should be os.SEEK_SET, os.SEEK_CUR, or os.SEEK_END"
            )
        if pos < 0 or pos > blob_len:
            raise ValueError("offset out of blob range")
        self._offset = pos

    def tell(self):
        """Return the current access position for the blob."""
        self._check_blob()
        return self._offset

    def _norm_index(self, item):
        try:
            idx = item.__index__()
        except AttributeError:
            raise TypeError("Blob indices must be integers") from None
        if idx > sys.maxsize or idx < -sys.maxsize - 1:
            raise IndexError("cannot fit 'int' into an index-sized integer")
        blob_len = _core.blob_bytes(self._h)
        if idx < 0:
            idx += blob_len
        if idx < 0 or idx >= blob_len:
            raise IndexError("Blob index out of range")
        return idx

    def __getitem__(self, item):
        self._check_blob()
        if isinstance(item, slice):
            blob_len = _core.blob_bytes(self._h)
            start, stop, step = item.indices(blob_len)
            indices = range(start, stop, step)
            slicelen = len(indices)
            if slicelen == 0:
                return b""
            if step == 1:
                return self._read_multiple(slicelen, start)
            lo = min(indices[0], indices[-1])
            hi = max(indices[0], indices[-1])
            chunk = self._read_multiple(hi - lo + 1, lo)
            return bytes(chunk[i - lo] for i in indices)
        if hasattr(item, "__index__"):
            idx = self._norm_index(item)
            return self._read_multiple(1, idx)[0]
        raise TypeError("Blob indices must be integers")

    def __setitem__(self, item, value):
        self._check_blob()
        if isinstance(item, slice):
            blob_len = _core.blob_bytes(self._h)
            start, stop, step = item.indices(blob_len)
            indices = range(start, stop, step)
            slicelen = len(indices)
            if slicelen == 0:
                return
            buf = _to_bytes_like(value)
            if len(buf) != slicelen:
                raise IndexError("Blob slice assignment is wrong size")
            if step == 1:
                self._write_raw(buf, start)
                return
            lo = min(indices[0], indices[-1])
            hi = max(indices[0], indices[-1])
            chunk = bytearray(self._read_multiple(hi - lo + 1, lo))
            for src_i, dst_i in enumerate(indices):
                chunk[dst_i - lo] = buf[src_i]
            self._write_raw(chunk, lo)
            return
        if hasattr(item, "__index__"):
            if not isinstance(value, int):
                raise TypeError(
                    f"'{type(value).__name__}' object cannot be interpreted as an integer"
                )
            idx = self._norm_index(item)
            if value < 0 or value > 255:
                raise ValueError("byte must be in range(0, 256)")
            self._write_raw(bytes((value,)), idx)
            return
        raise TypeError("Blob indices must be integers")

    def __delitem__(self, item):
        self._check_blob()
        if isinstance(item, slice):
            raise TypeError("Blob doesn't support slice deletion")
        if hasattr(item, "__index__"):
            raise TypeError("Blob doesn't support item deletion")
        raise TypeError("Blob indices must be integers")


# ---------------------------------------------------------------------------
# Row
# ---------------------------------------------------------------------------


class Row:
    __module__ = "sqlite3"
    __slots__ = ("_data", "_description")

    def __new__(cls, cursor, data, /):
        if not issubclass(type(cursor), Cursor):
            raise TypeError(
                f"Row() argument 1 must be sqlite3.Cursor, not {type(cursor).__name__}"
            )
        if not issubclass(type(data), tuple):
            raise TypeError(
                f"Row() argument 2 must be tuple, not {type(data).__name__}"
            )
        self = super().__new__(cls)
        self._data = data
        self._description = cursor.description
        return self

    def __len__(self):
        return len(self._data)

    def __iter__(self):
        return iter(self._data)

    def keys(self):
        desc = self._description
        if desc is None:
            return []
        return [col[0] for col in desc]

    def __getitem__(self, idx):
        if isinstance(idx, int):
            return self._data[idx]
        if isinstance(idx, str):
            desc = self._description
            if desc is not None:
                is_ascii = idx.isascii()
                idx_low = idx.lower() if is_ascii else None
                for i, col in enumerate(desc):
                    name = col[0]
                    if idx == name:
                        return self._data[i]
                    if is_ascii and isinstance(name, str) and name.isascii():
                        if idx_low == name.lower():
                            return self._data[i]
            raise IndexError("No item with that key")
        if isinstance(idx, slice):
            return self._data[idx]
        raise IndexError("Index must be int or string")

    def __hash__(self):
        return hash(self._description) ^ hash(self._data)

    def __eq__(self, other):
        if isinstance(other, Row):
            return self._description == other._description and self._data == other._data
        return NotImplemented

    def __ne__(self, other):
        if isinstance(other, Row):
            return self._description != other._description or self._data != other._data
        return NotImplemented


# ---------------------------------------------------------------------------
# Cursor
# ---------------------------------------------------------------------------


class Cursor:
    """SQLite database cursor class."""

    __module__ = "sqlite3"

    def __init__(self, connection, /):
        if getattr(self, "_locked", False):
            raise ProgrammingError("Recursive use of cursors not allowed.")
        if not isinstance(connection, Connection):
            raise TypeError(
                f"Cursor() argument 1 must be sqlite3.Connection, not "
                f"{type(connection).__name__}"
            )
        self._connection = connection
        self._statement = None
        self._row_cast_map = None
        self._description = None
        self._lastrowid = None
        self._arraysize = 1
        self._closed = False
        self._locked = False
        self._rowcount = -1
        self.row_factory = None
        self._initialized = False

        connection._check_thread()
        connection._register_cursor(self)
        self._initialized = True

    @property
    def connection(self):
        return getattr(self, "_connection", None)

    @property
    def description(self):
        return getattr(self, "_description", None)

    @property
    def lastrowid(self):
        return getattr(self, "_lastrowid", None)

    @property
    def rowcount(self):
        return getattr(self, "_rowcount", -1)

    @property
    def arraysize(self):
        return getattr(self, "_arraysize", 0)

    @arraysize.setter
    def arraysize(self, val):
        if not isinstance(val, int):
            raise TypeError("an integer is required")
        if val < -2147483648 or val > 2147483647:
            raise OverflowError("Python int too large to convert to C int")
        self._arraysize = int(val)

    def _check_locked(self):
        if getattr(self, "_locked", False):
            raise ProgrammingError("Recursive use of cursors not allowed.")

    def _check_cursor(self):
        if not getattr(self, "_initialized", False):
            raise ProgrammingError("Base Cursor.__init__ not called.")
        self._connection._check_thread()
        self._connection._check_connection()
        if self._closed:
            raise ProgrammingError("Cannot operate on a closed cursor.")
        self._check_locked()

    def _get_converter(self, name):
        return converters.get(name.upper())

    def _build_row_cast_map(self):
        detect = self._connection._detect_types
        if not detect:
            self._row_cast_map = None
            return
        stmt_h = self._statement._h
        ncols = _core.column_count(stmt_h)
        cast_map = []
        for i in range(ncols):
            conv = None
            if detect & PARSE_COLNAMES:
                colname = _core.column_name(stmt_h, i)
                if colname is not None:
                    start = colname.find("[")
                    if start != -1:
                        end = colname.find("]", start + 1)
                        if end != -1:
                            conv = self._get_converter(colname[start + 1 : end])
            if conv is None and (detect & PARSE_DECLTYPES):
                decl = _core.column_decltype(stmt_h, i)
                if decl is not None:
                    # Split at first space or '('
                    idx_sp = decl.find(" ")
                    idx_lp = decl.find("(")
                    if idx_sp == -1:
                        cut = idx_lp
                    elif idx_lp == -1:
                        cut = idx_sp
                    else:
                        cut = idx_sp if idx_sp < idx_lp else idx_lp
                    key = decl if cut == -1 else decl[:cut]
                    conv = self._get_converter(key)
            cast_map.append(conv)
        self._row_cast_map = cast_map

    def _build_column_name(self, colname):
        if self._connection._detect_types & PARSE_COLNAMES:
            pos = colname.find("[")
            if pos != -1:
                if pos > 0 and colname[pos - 1] == " ":
                    pos -= 1
                return colname[:pos]
        return colname

    def _bind_param(self, stmt_h, pos, val):
        if val is None:
            return _core.bind_null(stmt_h, pos)
        t = type(val)
        if t is int or isinstance(val, int):
            return _core.bind_int64(stmt_h, pos, val)
        if t is float or isinstance(val, float):
            return _core.bind_double(stmt_h, pos, float(val))
        if t is str or isinstance(val, str):
            raw = str.encode(val, "utf-8")
            return _core.bind_text(stmt_h, pos, raw)
        if t is bytes or t is bytearray:
            return _core.bind_blob(stmt_h, pos, val)
        if t is memoryview:
            if not val.c_contiguous:
                raise BufferError("underlying buffer is not C-contiguous")
            return _core.bind_blob(stmt_h, pos, val)
        # Generic buffer protocol fallback (array.array, custom __buffer__, etc.)
        try:
            mv = memoryview(val)
        except TypeError:
            raise ProgrammingError(
                f"Error binding parameter {pos}: type '{type(val).__name__}' is not supported"
            ) from None
        try:
            if not mv.c_contiguous:
                raise BufferError("underlying buffer is not C-contiguous")
            return _core.bind_blob(stmt_h, pos, mv)
        finally:
            mv.release()

    def _bind_parameters(self, stmt_h, parameters, warn_stacklevel):
        db_h = self._connection._db
        needed = _core.bind_count(stmt_h)
        t = type(parameters)
        if t is tuple or t is list or (
            not isinstance(parameters, dict)
            and hasattr(parameters, "__getitem__")
            and hasattr(parameters, "__len__")
            and not isinstance(parameters, (str, bytes, bytearray))
        ):
            num_params = len(parameters)
            if num_params != needed:
                raise ProgrammingError(
                    f"Incorrect number of bindings supplied. The current "
                    f"statement uses {needed}, and there are {num_params} supplied."
                )
            for i in range(num_params):
                name = _core.bind_name(stmt_h, i + 1)
                if name is not None and not name.startswith("?"):
                    warnings.warn(
                        f"Binding {i + 1} ('{name}') is a named parameter, but you "
                        "supplied a sequence which requires nameless (qmark) "
                        "placeholders. Starting with Python 3.14 an "
                        "sqlite3.ProgrammingError will be raised.",
                        DeprecationWarning,
                        stacklevel=warn_stacklevel,
                    )
                val = parameters[i]
                if _need_adapt(val):
                    val = adapt(val, PrepareProtocol, val)
                rc = self._bind_param(stmt_h, i + 1, val)
                if rc != SQLITE_OK:
                    _raise_sqlite_error(db_h)
        elif isinstance(parameters, dict):
            for i in range(1, needed + 1):
                bname = _core.bind_name(stmt_h, i)
                if not bname:
                    raise ProgrammingError(
                        f"Binding {i} has no name, but you supplied a "
                        "dictionary (which has only names)."
                    )
                key = bname[1:]
                try:
                    val = parameters[key]
                except LookupError:
                    raise ProgrammingError(
                        f"You did not supply a value for binding parameter :{key}."
                    ) from None
                if _need_adapt(val):
                    val = adapt(val, PrepareProtocol, val)
                rc = self._bind_param(stmt_h, i, val)
                if rc != SQLITE_OK:
                    _raise_sqlite_error(db_h)
        else:
            raise ProgrammingError("parameters are of unsupported type")

    def _get_statement_from_cache(self, operation):
        con = self._connection
        if con._statement_cache is not None:
            return con._statement_cache(operation)
        return con._prepare_statement(operation)

    def _query_execute(self, multiple, operation, parameters, warn_stacklevel=3):
        self._check_cursor()
        if not isinstance(operation, str):
            raise TypeError(
                f"operation parameter must be str, not {type(operation).__name__}"
            )
        self._locked = True
        try:
            if multiple:
                params_iter = iter(parameters)
            else:
                if parameters is None:
                    params_iter = iter(((),))
                else:
                    params_iter = iter((parameters,))

            self._description = None
            if self._statement is not None:
                self._statement._reset()

            stmt = self._get_statement_from_cache(operation)
            if not stmt._h:
                # Empty SQL or comments only: nothing to execute.
                self._statement = None
                self._rowcount = -1
                return self
            self._statement = stmt

            if multiple and _core.stmt_readonly(stmt._h):
                raise ProgrammingError(
                    "executemany() can only execute DML statements."
                )

            if _core.stmt_busy(stmt._h):
                stmt = self._connection._prepare_statement(operation)
                self._statement = stmt

            stmt._reset()
            self._rowcount = 0 if stmt._is_dml else -1

            con = self._connection
            db_h = con._db
            if (
                con._autocommit == LEGACY_TRANSACTION_CONTROL
                and con._isolation_level is not None
                and stmt._is_dml
                and _core.get_autocommit(db_h)
            ):
                con._begin_transaction()

            for param_set in params_iter:
                self._bind_parameters(stmt._h, param_set, warn_stacklevel)
                rc = _core.step(stmt._h)
                if rc != SQLITE_DONE and rc != SQLITE_ROW:
                    _raise_sqlite_error(db_h)

                try:
                    self._build_row_cast_map()
                except Exception as exc:
                    raise OperationalError(
                        "Error while building row_cast_map"
                    ) from exc

                ncols = _core.column_count(stmt._h)
                if self._description is None and ncols > 0:
                    desc = []
                    for i in range(ncols):
                        cname = _core.column_name(stmt._h, i)
                        if cname is None:
                            raise MemoryError()
                        cname = self._build_column_name(cname)
                        desc.append((cname, None, None, None, None, None, None))
                    self._description = tuple(desc)

                if rc == SQLITE_DONE:
                    if stmt._is_dml:
                        self._rowcount += _core.changes(db_h)
                    stmt._reset()

            if not multiple:
                self._lastrowid = _core.last_insert_rowid(db_h)

            if self._statement is not None and not _core.stmt_busy(self._statement._h):
                self._statement = None
            return self
        except BaseException:
            if self._statement is not None:
                self._statement._reset()
                self._statement = None
            self._rowcount = -1
            raise
        finally:
            self._locked = False

    def execute(self, sql, parameters=(), /):
        """Executes an SQL statement."""
        return self._query_execute(False, sql, parameters, warn_stacklevel=4)

    def executemany(self, sql, seq_of_parameters, /):
        """Repeatedly executes an SQL statement."""
        return self._query_execute(True, sql, seq_of_parameters, warn_stacklevel=4)

    def executescript(self, sql_script, /):
        """Executes multiple SQL statements at once."""
        self._check_cursor()
        if not isinstance(sql_script, str):
            raise TypeError(
                f"script argument must be unicode, not {type(sql_script).__name__}"
            )
        raw = str.encode(sql_script, "utf-8")
        if b"\x00" in raw:
            raise ValueError("embedded null character")

        con = self._connection
        db_h = con._db
        max_len = _core.limit(db_h, SQLITE_LIMIT_SQL_LENGTH, -1)
        if len(raw) > max_len:
            raise DataError("query string is too large")

        if con._autocommit == LEGACY_TRANSACTION_CONTROL and not _core.get_autocommit(db_h):
            con._exec_stmt(b"COMMIT")

        tail = raw
        while tail:
            rc, stmt_h, tail_off = _core.prepare(db_h, tail)
            if rc != SQLITE_OK:
                if stmt_h:
                    _core.finalize(stmt_h)
                _raise_sqlite_error(db_h)
            if stmt_h:
                try:
                    rc = _core.step(stmt_h)
                    while rc == SQLITE_ROW:
                        rc = _core.step(stmt_h)
                finally:
                    frc = _core.finalize(stmt_h)
                if frc != SQLITE_OK:
                    _raise_sqlite_error(db_h)
                if rc != SQLITE_DONE and rc != SQLITE_OK:
                    _raise_sqlite_error(db_h)
            if tail_off <= 0:
                break
            tail = tail[tail_off:]

        return self

    def _fetch_one_row(self):
        stmt_h = self._statement._h
        con = self._connection
        tf = con.text_factory
        cast_map = self._row_cast_map if con._detect_types else None
        has_conv = cast_map is not None and any(c is not None for c in cast_map)

        if not has_conv:
            if tf is str:
                row = _core.fetch_row(stmt_h, 0)
                if type(row) is int:
                    col_idx = row
                    cname = _core.column_name(stmt_h, col_idx) or ""
                    raw = _core.column_blob(stmt_h, col_idx)
                    if raw is None:
                        raw = b""
                    text_preview = raw.decode("latin1")
                    raise OperationalError(
                        f"Could not decode to UTF-8 column '{cname}' "
                        f"with text '{text_preview}'"
                    )
                return row
            if tf is bytes:
                return _core.fetch_row(stmt_h, 1)
            vals, types = _core.fetch_row(stmt_h, 2)
            out = list(vals)
            for i, coltype in enumerate(types):
                if coltype == _SQLITE_TEXT:
                    out[i] = tf(out[i])
            return tuple(out)

        # Converters active for at least one column.
        vals, types = _core.fetch_row(stmt_h, 2)
        out = list(vals)
        ncast = len(cast_map)
        for i in range(len(out)):
            conv = cast_map[i] if i < ncast else None
            if conv is not None:
                blob = _core.column_blob(stmt_h, i)
                if blob is None:
                    out[i] = None
                else:
                    out[i] = conv(blob)
            elif types[i] == _SQLITE_TEXT:
                raw = out[i]
                if tf is str:
                    try:
                        out[i] = raw.decode("utf-8")
                    except UnicodeDecodeError:
                        cname = _core.column_name(stmt_h, i) or ""
                        text_preview = raw.decode("latin1")
                        raise OperationalError(
                            f"Could not decode to UTF-8 column '{cname}' "
                            f"with text '{text_preview}'"
                        ) from None
                elif tf is bytes:
                    pass
                else:
                    out[i] = tf(raw)
        return tuple(out)

    def __iter__(self):
        return self

    def __next__(self):
        self._check_cursor()
        if self._statement is None:
            raise StopIteration

        stmt = self._statement
        self._locked = True
        try:
            row = self._fetch_one_row()
        finally:
            self._locked = False

        rc = _core.step(stmt._h)
        if rc == SQLITE_DONE:
            if stmt._is_dml:
                self._rowcount = _core.changes(self._connection._db)
            stmt._reset()
            self._statement = None
        elif rc != SQLITE_ROW:
            stmt._reset()
            self._statement = None
            _raise_sqlite_error(self._connection._db)

        rf = self.row_factory
        if rf is not None:
            row = rf(self, row)
        return row

    def fetchone(self):
        """Fetches one row from the resultset."""
        try:
            return self.__next__()
        except StopIteration:
            return None

    def fetchmany(self, size=None):
        """Fetches several rows from the resultset."""
        if size is None:
            maxrows = self.arraysize
        else:
            if not isinstance(size, int):
                raise TypeError("an integer is required")
            maxrows = int(size)
        rows = []
        if maxrows == 0:
            self._check_cursor()
            return rows
        count = 0
        while True:
            try:
                row = self.__next__()
            except StopIteration:
                break
            rows.append(row)
            count += 1
            if count == maxrows:
                break
        return rows

    def fetchall(self):
        """Fetches all rows from the resultset."""
        rows = []
        while True:
            try:
                row = self.__next__()
            except StopIteration:
                break
            rows.append(row)
        return rows

    def setinputsizes(self, sizes, /):
        """Required by DB-API. Does nothing in sqlite3."""
        return None

    def setoutputsize(self, size, column=None, /):
        """Required by DB-API. Does nothing in sqlite3."""
        return None

    def close(self):
        """Closes the cursor."""
        self._check_locked()
        if not getattr(self, "_initialized", False):
            raise ProgrammingError("Base Cursor.__init__ not called.")
        self._connection._check_thread()
        self._connection._check_connection()
        if self._statement is not None:
            self._statement._reset()
            self._statement = None
        self._closed = True

    def __del__(self):
        stmt = getattr(self, "_statement", None)
        if stmt is not None:
            self._statement = None
            try:
                stmt._reset()
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------


class Connection:
    """SQLite database connection object."""

    __module__ = "sqlite3"

    Warning = Warning
    Error = Error
    InterfaceError = InterfaceError
    DatabaseError = DatabaseError
    DataError = DataError
    OperationalError = OperationalError
    IntegrityError = IntegrityError
    InternalError = InternalError
    ProgrammingError = ProgrammingError
    NotSupportedError = NotSupportedError

    def __init__(
        self,
        database,
        timeout=5.0,
        detect_types=0,
        isolation_level="",
        check_same_thread=True,
        factory=None,
        cached_statements=128,
        uri=False,
        *,
        autocommit=LEGACY_TRANSACTION_CONTROL,
    ):
        db_bytes = os.fsencode(database)
        if b"\x00" in db_bytes:
            raise ValueError("embedded null byte")
        if not isinstance(timeout, (int, float)):
            raise TypeError("must be real number, not " + type(timeout).__name__)
        if not isinstance(detect_types, int):
            raise TypeError("an integer is required")
        if not isinstance(cached_statements, int):
            raise TypeError("an integer is required")

        iso = _convert_isolation_level(isolation_level)
        ac = _convert_autocommit(autocommit)

        # Handle re-initialization of an already-initialized Connection.
        if getattr(self, "_initialized", False):
            self._initialized = False
            self._close_all_blobs()
            self._statement_cache = None
            self._close_db()

        flags = _SQLITE_OPEN_READWRITE | _SQLITE_OPEN_CREATE
        if uri:
            flags |= _SQLITE_OPEN_URI

        rc, db_h = _core.open(db_bytes, flags)
        if db_h == 0 and rc == SQLITE_NOMEM:
            raise MemoryError()
        if rc != SQLITE_OK:
            exc = _make_sqlite_error(db_h) if db_h else OperationalError("unable to open database file")
            if db_h:
                _core.close(db_h, 0)
            raise exc

        _core.busy_timeout(db_h, int(float(timeout) * 1000))

        self._db = db_h
        self._detect_types = int(detect_types)
        self._isolation_level = iso
        self._autocommit = ac
        self._check_same_thread = bool(check_same_thread)
        self._thread_ident = _thread.get_ident()
        self._cursors = []
        self._blobs = []
        self._created_cursors = 0
        self.row_factory = None
        self.text_factory = str
        self._callbacks = {}
        self._statement_cache = functools.lru_cache(maxsize=int(cached_statements))(self)
        self._initialized = True

        if ac is False:
            self._exec_stmt(b"BEGIN")

    def _check_thread(self):
        if getattr(self, "_check_same_thread", False):
            cur_id = _thread.get_ident()
            if cur_id != self._thread_ident:
                raise ProgrammingError(
                    "SQLite objects created in a thread can only be used in that same thread. "
                    f"The object was created in thread id {self._thread_ident} and "
                    f"this is thread id {cur_id}."
                )

    def _check_connection(self):
        if not getattr(self, "_initialized", False):
            raise ProgrammingError("Base Connection.__init__ not called.")
        if not self._db:
            raise ProgrammingError("Cannot operate on a closed database.")

    def _register_cursor(self, cursor):
        self._cursors.append(weakref.ref(cursor))

    def _drop_unused_cursors(self):
        self._created_cursors += 1
        if self._created_cursors < 200:
            return
        self._created_cursors = 0
        self._cursors = [ref for ref in self._cursors if ref() is not None]

    def _close_all_blobs(self):
        blobs = getattr(self, "_blobs", None)
        if not blobs:
            return
        for ref in blobs:
            b = ref()
            if b is not None:
                b._close_raw()
        self._blobs = []

    def _exec_stmt(self, sql_bytes):
        db_h = self._db
        rc, stmt_h, _ = _core.prepare(db_h, sql_bytes)
        if rc == SQLITE_OK and stmt_h:
            _core.step(stmt_h)
            rc = _core.finalize(stmt_h)
        if rc != SQLITE_OK:
            _raise_sqlite_error(db_h)

    def _begin_transaction(self):
        iso = self._isolation_level
        if iso:
            sql = ("BEGIN " + iso).encode("ascii")
        else:
            sql = b"BEGIN "
        self._exec_stmt(sql)

    def _prepare_statement(self, sql):
        if not isinstance(sql, str):
            raise TypeError(f"must be str, not {type(sql).__name__}")
        raw = str.encode(sql, "utf-8")
        db_h = self._db
        max_len = _core.limit(db_h, SQLITE_LIMIT_SQL_LENGTH, -1)
        if len(raw) > max_len:
            raise DataError("query string is too large")
        if b"\x00" in raw:
            raise ProgrammingError("the query contains a null character")

        rc, stmt_h, tail_off = _core.prepare(db_h, raw)
        if rc != SQLITE_OK:
            if stmt_h:
                _core.finalize(stmt_h)
            _raise_sqlite_error(db_h)

        if _lstrip_sql_bytes(raw, tail_off) != -1:
            if stmt_h:
                _core.finalize(stmt_h)
            raise ProgrammingError("You can only execute one statement at a time.")

        start = _lstrip_sql_bytes(raw, 0)
        is_dml = False
        if start != -1:
            head = raw[start : start + 7].lower()
            is_dml = (
                head.startswith(b"insert")
                or head.startswith(b"update")
                or head.startswith(b"delete")
                or head.startswith(b"replace")
            )
        return _Statement._from_handle(stmt_h, is_dml)

    def __call__(self, *args):
        self._check_thread()
        self._check_connection()
        if len(args) != 1:
            raise TypeError(
                f"Connection.__call__() takes exactly 1 argument ({len(args)} given)"
            )
        return self._prepare_statement(args[0])

    def _close_db(self):
        db_h = getattr(self, "_db", 0)
        if not db_h:
            return
        err = None
        if self._autocommit is False and not _core.get_autocommit(db_h):
            try:
                self._exec_stmt(b"ROLLBACK")
            except Exception as e:
                err = e
        self._db = 0
        self._callbacks = {}
        _core.close(db_h, 1)  # sqlite3_close_v2
        if err is not None:
            raise err

    def close(self):
        """Close the database connection."""
        self._check_thread()
        if not getattr(self, "_initialized", False):
            raise ProgrammingError("Base Connection.__init__ not called.")
        self._close_all_blobs()
        cache = self._statement_cache
        self._statement_cache = None
        if cache is not None:
            cache.cache_clear()
        self._close_db()

    def __del__(self):
        try:
            if getattr(self, "_db", 0):
                self._close_all_blobs()
                cache = getattr(self, "_statement_cache", None)
                self._statement_cache = None
                if cache is not None:
                    cache.cache_clear()
                self._close_db()
        except Exception:
            pass

    @property
    def isolation_level(self):
        self._check_connection()
        return self._isolation_level

    @isolation_level.setter
    def isolation_level(self, val):
        self._check_connection()
        if val is None:
            self._isolation_level = None
            self.commit()
            return
        self._isolation_level = _convert_isolation_level(val)

    @property
    def autocommit(self):
        self._check_thread()
        self._check_connection()
        return self._autocommit

    @autocommit.setter
    def autocommit(self, val):
        self._check_thread()
        self._check_connection()
        ac = _convert_autocommit(val)
        self._autocommit = ac
        db_h = self._db
        if ac is True:
            if not _core.get_autocommit(db_h):
                self._exec_stmt(b"COMMIT")
        elif ac is False:
            if _core.get_autocommit(db_h):
                self._exec_stmt(b"BEGIN")

    @property
    def total_changes(self):
        self._check_connection()
        return _core.total_changes(self._db)

    @property
    def in_transaction(self):
        self._check_connection()
        return not _core.get_autocommit(self._db)

    def commit(self):
        """Commit any pending transaction to the database."""
        self._check_thread()
        self._check_connection()
        db_h = self._db
        if self._autocommit == LEGACY_TRANSACTION_CONTROL:
            if not _core.get_autocommit(db_h):
                self._exec_stmt(b"COMMIT")
        elif self._autocommit is False:
            self._exec_stmt(b"COMMIT")
            self._exec_stmt(b"BEGIN")

    def rollback(self):
        """Roll back to the start of any pending transaction."""
        self._check_thread()
        self._check_connection()
        db_h = self._db
        if self._autocommit == LEGACY_TRANSACTION_CONTROL:
            if not _core.get_autocommit(db_h):
                self._exec_stmt(b"ROLLBACK")
        elif self._autocommit is False:
            self._exec_stmt(b"ROLLBACK")
            self._exec_stmt(b"BEGIN")

    def cursor(self, factory=Cursor):
        """Return a cursor for the connection."""
        self._check_thread()
        self._check_connection()
        cur = factory(self)
        if not issubclass(type(cur), Cursor):
            raise TypeError(
                f"factory must return a cursor, not {type(cur).__name__}"
            )
        self._drop_unused_cursors()
        if self.row_factory is not None:
            cur.row_factory = self.row_factory
        return cur

    def execute(self, sql, parameters=(), /):
        """Executes an SQL statement."""
        cur = self.cursor()
        return cur._query_execute(False, sql, parameters, warn_stacklevel=4)

    def executemany(self, sql, parameters, /):
        """Repeatedly executes an SQL statement."""
        cur = self.cursor()
        return cur._query_execute(True, sql, parameters, warn_stacklevel=4)

    def executescript(self, sql_script, /):
        """Executes multiple SQL statements at once."""
        cur = self.cursor()
        return cur.executescript(sql_script)

    def interrupt(self):
        """Abort any pending database operation."""
        self._check_connection()
        _core.interrupt(self._db)

    def iterdump(self):
        """Returns iterator to the dump of the database in an SQL text format."""
        self._check_connection()
        from sqlite3.dump import _iterdump
        return _iterdump(self)

    def blobopen(self, table, column, row, /, *, readonly=False, name="main"):
        """Open and return a BLOB object."""
        self._check_thread()
        self._check_connection()
        tbl_b = _encode_cstr(table, "table")
        col_b = _encode_cstr(column, "column")
        name_b = _encode_cstr(name, "name")
        if not isinstance(row, int):
            raise TypeError("expected 'int'")
        if row < -9223372036854775808 or row > 9223372036854775807:
            raise OverflowError("Python int too large to convert to SQLite INTEGER")
        flags = 0 if readonly else 1
        rc, blob_h = _core.blob_open(self._db, name_b, tbl_b, col_b, int(row), flags)
        if rc == SQLITE_MISUSE:
            raise InterfaceError(_core.errstr(rc))
        if rc != SQLITE_OK:
            _raise_sqlite_error(self._db)
        blob = Blob._from_handle(self, blob_h)
        self._blobs.append(weakref.ref(blob))
        return blob

    def create_function(self, name, narg, func, *, deterministic=False):
        """Creates a new function."""
        self._check_thread()
        self._check_connection()
        name_b = _encode_cstr(name, "name")
        narg = _check_cint(narg)
        flags = _SQLITE_UTF8
        if deterministic:
            if _core.SQLITE_VERSION_NUMBER < 3008003:
                raise NotSupportedError(
                    "deterministic=True requires SQLite 3.8.3 or higher"
                )
            flags |= _SQLITE_DETERMINISTIC
        rc = _core.create_function(self._db, name_b, narg, flags, func)
        if rc != SQLITE_OK:
            raise OperationalError("Error creating function")
        key = ("func", name_b.lower(), narg)
        if func is None:
            self._callbacks.pop(key, None)
        else:
            self._callbacks[key] = func

    def create_aggregate(self, name, n_arg, aggregate_class):
        """Creates a new aggregate."""
        self._check_thread()
        self._check_connection()
        name_b = _encode_cstr(name, "name")
        n_arg = _check_cint(n_arg)
        rc = _core.create_aggregate(self._db, name_b, n_arg, aggregate_class)
        if rc != SQLITE_OK:
            raise OperationalError("Error creating aggregate")
        key = ("agg", name_b.lower(), n_arg)
        if aggregate_class is None:
            self._callbacks.pop(key, None)
        else:
            self._callbacks[key] = aggregate_class

    if _core.HAS_WINDOW_FUNCTIONS:
        def create_window_function(self, name, num_params, aggregate_class, /):
            """Creates or redefines an aggregate window function."""
            if _core.SQLITE_VERSION_NUMBER < 3025000:
                raise NotSupportedError(
                    "create_window_function() requires SQLite 3.25.0 or higher"
                )
            self._check_thread()
            self._check_connection()
            name_b = _encode_cstr(name, "name")
            num_params = _check_cint(num_params)
            rc = _core.create_window_function(
                self._db, name_b, num_params, aggregate_class
            )
            if rc != SQLITE_OK:
                raise ProgrammingError(_core.errstr(rc))
            key = ("win", name_b.lower(), num_params)
            if aggregate_class is None:
                self._callbacks.pop(key, None)
            else:
                self._callbacks[key] = aggregate_class

    def create_collation(self, name, callback, /):
        """Creates a collation function."""
        self._check_thread()
        self._check_connection()
        name_b = _encode_cstr(name, "name")
        if callback is not None and not callable(callback):
            raise TypeError("parameter must be callable")
        rc = _core.create_collation(self._db, name_b, callback)
        if rc != SQLITE_OK:
            _raise_sqlite_error(self._db)
        key = ("coll", name_b.lower())
        if callback is None:
            self._callbacks.pop(key, None)
        else:
            self._callbacks[key] = callback

    def set_authorizer(self, authorizer_callback, /):
        """Sets authorizer callback."""
        self._check_thread()
        self._check_connection()
        rc = _core.set_authorizer(self._db, authorizer_callback)
        if rc != SQLITE_OK:
            self._callbacks.pop("auth", None)
            raise OperationalError("Error setting authorizer callback")
        if authorizer_callback is None:
            self._callbacks.pop("auth", None)
        else:
            self._callbacks["auth"] = authorizer_callback

    def set_progress_handler(self, progress_handler, n):
        """Sets progress handler callback."""
        self._check_thread()
        self._check_connection()
        n = _check_cint(n)
        _core.set_progress_handler(self._db, progress_handler, n)
        if progress_handler is None:
            self._callbacks.pop("progress", None)
        else:
            self._callbacks["progress"] = progress_handler

    def set_trace_callback(self, trace_callback, /):
        """Sets a trace callback called for each SQL statement."""
        self._check_thread()
        self._check_connection()
        _core.set_trace_callback(self._db, trace_callback)
        if trace_callback is None:
            self._callbacks.pop("trace", None)
        else:
            self._callbacks["trace"] = trace_callback

    def setlimit(self, category, limit, /):
        """Set connection run-time limits."""
        self._check_thread()
        self._check_connection()
        category = _check_cint(category)
        limit = _check_cint(limit)
        old = _core.limit(self._db, category, limit)
        if old < 0:
            raise ProgrammingError("'category' is out of bounds")
        return old

    def getlimit(self, category, /):
        """Get connection run-time limits."""
        return self.setlimit(category, -1)

    def setconfig(self, op, enable=True, /):
        """Set a boolean connection configuration option."""
        self._check_thread()
        self._check_connection()
        op = _check_cint(op)
        if op not in _VALID_DBCONFIG_OPS:
            raise ValueError(f"unknown config 'op': {op}")
        en = 1 if enable else 0
        rc, actual = _core.db_config(self._db, op, en)
        if rc != SQLITE_OK:
            _raise_sqlite_error(self._db)
        if en != actual:
            raise OperationalError("Unable to set config")

    def getconfig(self, op, /):
        """Query a boolean connection configuration option."""
        self._check_thread()
        self._check_connection()
        op = _check_cint(op)
        if op not in _VALID_DBCONFIG_OPS:
            raise ValueError(f"unknown config 'op': {op}")
        rc, current = _core.db_config(self._db, op, -1)
        if rc != SQLITE_OK:
            _raise_sqlite_error(self._db)
        return bool(current)

    if _core.HAS_SERIALIZE:
        def serialize(self, *, name="main"):
            """Serialize a database into a byte string."""
            self._check_thread()
            self._check_connection()
            name_b = _encode_cstr(name, "name")
            data = _core.serialize(self._db, name_b)
            if data is None:
                raise OperationalError(f"unable to serialize '{name}'")
            return data

        def deserialize(self, data, /, *, name="main"):
            """Load a serialized database."""
            self._check_thread()
            self._check_connection()
            name_b = _encode_cstr(name, "name")
            buf = _to_bytes_like(data, allow_str=True)
            rc = _core.deserialize(self._db, name_b, buf)
            if rc != SQLITE_OK:
                _raise_sqlite_error(self._db)

    if _core.HAS_LOAD_EXTENSION:
        def enable_load_extension(self, enable, /):
            """Enable dynamic loading of SQLite extension modules."""
            self._check_thread()
            self._check_connection()
            rc = _core.enable_load_extension(self._db, 1 if enable else 0)
            if rc != SQLITE_OK:
                raise OperationalError("Error enabling load extension")

        def load_extension(self, name, /, *, entrypoint=None):
            """Load SQLite extension module."""
            self._check_thread()
            self._check_connection()
            name_b = _encode_cstr(name, "name")
            entry_b = None if entrypoint is None else _encode_cstr(entrypoint, "entrypoint")
            rc, errmsg = _core.load_extension(self._db, name_b, entry_b)
            if rc != SQLITE_OK:
                raise OperationalError(errmsg if errmsg is not None else _core.errstr(rc))

    def backup(self, target, *, pages=-1, progress=None, name="main", sleep=0.250):
        """Makes a backup of the database."""
        if not issubclass(type(target), Connection):
            raise TypeError(
                f"backup() argument 'target' must be sqlite3.Connection, not "
                f"{type(target).__name__}"
            )
        pages = _check_cint(pages)
        name_b = _encode_cstr(name, "name")
        if not isinstance(sleep, (int, float)):
            raise TypeError(f"must be real number, not {type(sleep).__name__}")
        sleep_ms = int(float(sleep) * 1000.0)

        self._check_thread()
        self._check_connection()
        target._check_connection()
        if target is self:
            raise ValueError("target cannot be the same connection instance")
        if progress is not None and not callable(progress):
            raise TypeError("progress argument must be a callable")
        if pages == 0:
            pages = -1

        bkh = _core.backup_init(target._db, b"main", self._db, name_b)
        if not bkh:
            _raise_sqlite_error(target._db)
        try:
            while True:
                rc = _core.backup_step(bkh, pages)
                if progress is not None:
                    rem = _core.backup_remaining(bkh)
                    total = _core.backup_pagecount(bkh)
                    progress(rc, rem, total)
                if rc == SQLITE_BUSY or rc == SQLITE_LOCKED:
                    _core.sleep(sleep_ms)
                elif rc != SQLITE_OK:
                    break
        except BaseException:
            _core.backup_finish(bkh)
            raise
        rc = _core.backup_finish(bkh)
        if rc != SQLITE_OK:
            _raise_sqlite_error(target._db)

    def __enter__(self):
        self._check_connection()
        return self

    def __exit__(self, exc_type, exc_value, exc_tb, /):
        if exc_type is None and exc_value is None and exc_tb is None:
            try:
                self.commit()
            except BaseException:
                self.rollback()
                raise
        else:
            self.rollback()
        return False


def connect(
    database,
    timeout=5.0,
    detect_types=0,
    isolation_level="",
    check_same_thread=True,
    factory=Connection,
    cached_statements=128,
    uri=False,
    *,
    autocommit=LEGACY_TRANSACTION_CONTROL,
):
    """Opens a connection to the SQLite database file database."""
    return factory(
        database,
        timeout=timeout,
        detect_types=detect_types,
        isolation_level=isolation_level,
        check_same_thread=check_same_thread,
        factory=factory,
        cached_statements=cached_statements,
        uri=uri,
        autocommit=autocommit,
    )
