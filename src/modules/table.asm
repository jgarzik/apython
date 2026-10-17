; modtable.asm - the built-in modules, in one place
;
; A module compiled into the interpreter rather than found on sys.path.  Two
; things need this list and each used to carry its own copy: import_init, which
; registers every module in sys.modules, and sys.builtin_module_names, which
; os.py reads to decide which platform module to import.
;
; They disagreed.  import_init wired six modules through six byte-identical
; blocks; sys.builtin_module_names was a hand-written array that had never
; grown `asyncio` or `errno`, so `'errno' in sys.builtin_module_names` was
; False for a module that was right there in sys.modules.  os.py's own gate is
; `if 'posix' in sys.builtin_module_names`, so a stale list is not cosmetic:
; the platform module can exist and os.py will still say "no os specific
; module found".
;
; A create_fn of 0 means import_init registers that module some other way --
; sys builds itself, and builtins wraps a dict that already exists -- but the
; name still belongs in builtin_module_names.

%include "macros.inc"
%include "object.inc"

ASM_INIT

extern array_module_create
extern impcore_module_create
extern time_module_create
extern asyncio_module_create
extern sre_module_create
extern abc_module_create
extern weakref_module_create
extern errno_module_create
extern posix_module_create
extern io_module_create
extern gc_module_create
extern cmath_module_create
extern math_module_create
extern random_module_create
extern mmap_module_create
extern bz2_module_create
extern lzma_module_create
extern unicodedata_module_create
extern socket_module_create
extern marshal_module_init
extern signal_module_create
extern zlib_module_create
extern hashlib_module_create
extern pyexpat_module_create

section .rodata

bm_n_builtins: db "builtins", 0
bm_n_sys:      db "sys", 0
bm_n_time:     db "time", 0
bm_n_asyncio:  db "_asynciocore", 0
bm_n_sre:      db "_sre", 0
bm_n_array:    db "array", 0
bm_n_abc:      db "_abc", 0
bm_n_errno:    db "errno", 0
bm_n_weakref:  db "_weakref", 0
bm_n_posix:    db "posix", 0
bm_n_io:       db "_iocore", 0
bm_n_gc:       db "gc", 0
bm_n_cmath:    db "cmath", 0
bm_n_math:     db "math", 0
bm_n_randomcore: db "_randomcore", 0
bm_n_mmapcore: db "_mmapcore", 0
bm_n_bz2core: db "_bz2core", 0
bm_n_lzmacore: db "_lzmacore", 0
bm_n_unicodedata: db "unicodedata", 0
bm_n_socket:   db "_socketcore", 0
bm_n_marshal:  db "marshal", 0
bm_n_signal:   db "_signalcore", 0
bm_n_zlib:     db "_zlibcore", 0
bm_n_hashlib:  db "_hashlibcore", 0
bm_n_impcore:  db "_impcore", 0
bm_n_pyexpat:  db "_pyexpatcore", 0

align 8
global builtin_module_table
; Sorted by name, because sys.builtin_module_names is built straight from it
; and CPython's is sorted.  Nothing here depends on creation order; the two
; rows that would -- sys and builtins -- are wired before the loop runs.
builtin_module_table:
    dq bm_n_abc,      abc_module_create
    dq bm_n_array,    array_module_create
    dq bm_n_asyncio,  asyncio_module_create
    dq bm_n_randomcore, random_module_create
    dq bm_n_mmapcore, mmap_module_create
    dq bm_n_bz2core, bz2_module_create
    dq bm_n_lzmacore, lzma_module_create
    dq bm_n_hashlib,  hashlib_module_create
    dq bm_n_impcore,  impcore_module_create
    dq bm_n_io,       io_module_create
    dq bm_n_pyexpat,  pyexpat_module_create
    dq bm_n_socket,   socket_module_create
    dq bm_n_signal,   signal_module_create
    dq bm_n_sre,      sre_module_create
    dq bm_n_weakref,  weakref_module_create
    dq bm_n_zlib,     zlib_module_create
    dq bm_n_builtins, 0                 ; wraps builtins_dict_global
    dq bm_n_cmath,    cmath_module_create
    dq bm_n_errno,    errno_module_create
    dq bm_n_gc,       gc_module_create
    dq bm_n_marshal,  marshal_module_init
    dq bm_n_math,     math_module_create
    dq bm_n_posix,    posix_module_create
    dq bm_n_sys,      0                 ; built by sys_module_init
    dq bm_n_time,     time_module_create
    dq bm_n_unicodedata, unicodedata_module_create
bmt_end:

; The row count, computed rather than declared.  It used to be a hand-kept
; equ in object.inc, and adding `math` without touching it truncated the
; table one row short: `time` fell off the end, so `import time` failed and
; sys.builtin_module_names did not list it.  Nothing to keep in step now.
align 8
global builtin_module_count
builtin_module_count:
    dq (bmt_end - builtin_module_table) / BuiltinModule_size

