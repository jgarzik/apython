; sqlite3.asm - the _sqlite3core module: libsqlite3 behind handle tables.
;
; The same split _zlibcore/lib/zlib.py and _pyexpatcore/lib/pyexpat.py use.
; What is genuinely C lives here -- the sqlite3*, sqlite3_stmt*, sqlite3_blob*,
; sqlite3_backup* handle tables, blocking C calls bracketed with
; ALLOW_THREADS_BEGIN/END, and callback registration -- and everything a Python
; program sees lives in lib/_sqlite3.py (which stdlib/sqlite3/ imports).
;
; Every handle handed to Python is a 1-based INDEX into a handle table, never a
; raw pointer.  Freed slots are zeroed and each struct carries a magic word so
; stale or forged handles are rejected cleanly.
;
; Error discipline: NEVER `RAISE` from this file.  Record the exception with
; `set_exception` / `FAIL` and return 0 (or -1 for internal helpers).

%include "macros.inc"
%include "object.inc"
%include "gil.inc"
%include "sqlite3.inc"

ASM_INIT

extern dict_new
extern dict_set_str
extern module_new
extern str_from_cstr_heap
extern str_new_heap
extern bytes_from_data
extern bytes_utf8_check
extern tuple_new
extern builtin_func_new
extern obj_decref
extern obj_dealloc
extern obj_incref
extern obj_as_index
extern int_fits_i64
extern int_to_i64
extern type_is_subtype
extern set_exception
extern ap_malloc
extern ap_realloc
extern ap_free
extern ap_memset
extern ap_memcpy
extern dlsym

extern sq_cb_destroy
extern sq_cb_func
extern sq_cb_step
extern sq_cb_final
extern sq_cb_value
extern sq_cb_inverse
extern sq_cb_collation
extern sq_cb_authorizer
extern sq_cb_progress
extern sq_cb_trace
extern sq_cb_print_or_clear_pending
extern sq_set_cb_tracebacks
extern sq_create_function
extern sq_create_aggregate
extern sq_create_window
extern sq_create_collation
extern sq_set_authorizer
extern sq_set_progress
extern sq_set_trace
extern sq_limit
extern sq_db_config
extern sq_serialize
extern sq_deserialize
extern sq_enable_load_ext
extern sq_load_ext
extern sq_blob_open
extern sq_blob_close
extern sq_blob_bytes
extern sq_blob_read
extern sq_blob_write
extern sq_backup_init
extern sq_backup_step
extern sq_backup_finish
extern sq_backup_remaining
extern sq_backup_pagecount
extern sq_sleep

extern none_singleton
extern bool_true
extern bool_false
extern int_type
extern bytes_type
extern bytearray_type
extern memoryview_type
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_OverflowError_type
extern exc_MemoryError_type
extern exc_RuntimeError_type
extern exc_BufferError_type

; libsqlite3 entry points (core, present since SQLite 3.7.15).
extern sqlite3_initialize
extern sqlite3_libversion
extern sqlite3_libversion_number
extern sqlite3_threadsafe
extern sqlite3_complete
extern sqlite3_open_v2
extern sqlite3_close
extern sqlite3_close_v2
extern sqlite3_busy_timeout
extern sqlite3_interrupt
extern sqlite3_get_autocommit
extern sqlite3_total_changes
extern sqlite3_changes
extern sqlite3_last_insert_rowid
extern sqlite3_errcode
extern sqlite3_extended_errcode
extern sqlite3_errmsg
extern sqlite3_errstr
extern sqlite3_prepare_v2
extern sqlite3_step
extern sqlite3_reset
extern sqlite3_finalize
extern sqlite3_stmt_busy
extern sqlite3_stmt_readonly
extern sqlite3_column_count
extern sqlite3_data_count
extern sqlite3_column_name
extern sqlite3_column_decltype
extern sqlite3_column_type
extern sqlite3_column_int64
extern sqlite3_column_double
extern sqlite3_column_text
extern sqlite3_column_blob
extern sqlite3_column_bytes
extern sqlite3_bind_parameter_count
extern sqlite3_bind_parameter_name
extern sqlite3_bind_null
extern sqlite3_bind_int64
extern sqlite3_bind_double
extern sqlite3_bind_text
extern sqlite3_bind_blob
extern sqlite3_create_function_v2
extern sqlite3_create_collation_v2
extern sqlite3_set_authorizer
extern sqlite3_progress_handler
extern sqlite3_trace_v2
extern sqlite3_limit
extern sqlite3_db_config
extern sqlite3_malloc64
extern sqlite3_free
extern sqlite3_blob_open
extern sqlite3_blob_close
extern sqlite3_blob_bytes
extern sqlite3_blob_read
extern sqlite3_blob_write
extern sqlite3_backup_init
extern sqlite3_backup_step
extern sqlite3_backup_finish
extern sqlite3_backup_remaining
extern sqlite3_backup_pagecount
extern sqlite3_sleep

; Handle table descriptor layout (24 bytes in .data).
struc SqTable
    .arr:       resq 1          ; void** (slot 0 unused, valid handles >= 1)
    .cap:       resq 1
    .n:         resq 1          ; high-water mark (next fresh slot)
endstruc

section .data
align 64
sq_tbl_lock:    dd 0
align 8
global sq_db_table
sq_db_table:    dq 0, 0, 0
global sq_stmt_table
sq_stmt_table:  dq 0, 0, 0
global sq_blob_table
sq_blob_table:  dq 0, 0, 0
global sq_bkup_table
sq_bkup_table:  dq 0, 0, 0

; Optional libsqlite3 symbols probed via dlsym at module init.
global sq_fn_serialize
sq_fn_serialize:        dq 0
global sq_fn_deserialize
sq_fn_deserialize:      dq 0
global sq_fn_enable_load_ext
sq_fn_enable_load_ext:  dq 0
global sq_fn_load_ext
sq_fn_load_ext:         dq 0
global sq_fn_create_window
sq_fn_create_window:    dq 0

; Global callback traceback flag (toggled by enable_callback_tracebacks).
global sq_callback_tracebacks
sq_callback_tracebacks: dq 0

; Registered sqlite3.DataError type for trace_v2 expanded-SQL overflow.
global sq_data_error_type
sq_data_error_type:     dq 0

section .rodata
sq_empty_byte:          db 0
sq_modname:             db "_sqlite3core", 0

; Module attribute / function names.
sn_version:             db "SQLITE_VERSION", 0
sn_version_num:         db "SQLITE_VERSION_NUMBER", 0
sn_threadsafe:          db "THREADSAFE", 0
sn_has_serialize:       db "HAS_SERIALIZE", 0
sn_has_load_ext:        db "HAS_LOAD_EXTENSION", 0
sn_has_window:          db "HAS_WINDOW_FUNCTIONS", 0

sn_complete:            db "complete", 0
sn_open:                db "open", 0
sn_close:               db "close", 0
sn_busy_timeout:        db "busy_timeout", 0
sn_interrupt:           db "interrupt", 0
sn_get_autocommit:      db "get_autocommit", 0
sn_total_changes:       db "total_changes", 0
sn_changes:             db "changes", 0
sn_last_insert_rowid:   db "last_insert_rowid", 0
sn_errcode:             db "errcode", 0
sn_extended_errcode:    db "extended_errcode", 0
sn_errmsg:              db "errmsg", 0
sn_errstr:              db "errstr", 0
sn_prepare:             db "prepare", 0
sn_step:                db "step", 0
sn_reset:               db "reset", 0
sn_finalize:            db "finalize", 0
sn_stmt_busy:           db "stmt_busy", 0
sn_stmt_readonly:       db "stmt_readonly", 0
sn_column_count:        db "column_count", 0
sn_data_count:          db "data_count", 0
sn_column_name:         db "column_name", 0
sn_column_decltype:     db "column_decltype", 0
sn_column_type:         db "column_type", 0
sn_column_blob:         db "column_blob", 0
sn_fetch_row:           db "fetch_row", 0
sn_bind_count:          db "bind_count", 0
sn_bind_name:           db "bind_name", 0
sn_bind_null:           db "bind_null", 0
sn_bind_int64:          db "bind_int64", 0
sn_bind_double:         db "bind_double", 0
sn_bind_text:           db "bind_text", 0
sn_bind_blob:           db "bind_blob", 0
sn_set_cb_tracebacks:   db "set_callback_tracebacks", 0
sn_create_function:     db "create_function", 0
sn_create_aggregate:    db "create_aggregate", 0
sn_create_window:       db "create_window_function", 0
sn_create_collation:    db "create_collation", 0
sn_set_authorizer:      db "set_authorizer", 0
sn_set_progress:        db "set_progress_handler", 0
sn_set_trace:           db "set_trace_callback", 0
sn_limit:               db "limit", 0
sn_db_config:           db "db_config", 0
sn_serialize:           db "serialize", 0
sn_deserialize:         db "deserialize", 0
sn_enable_load_ext:     db "enable_load_extension", 0
sn_load_ext:            db "load_extension", 0
sn_blob_open:           db "blob_open", 0
sn_blob_close:          db "blob_close", 0
sn_blob_bytes:          db "blob_bytes", 0
sn_blob_read:           db "blob_read", 0
sn_blob_write:          db "blob_write", 0
sn_backup_init:         db "backup_init", 0
sn_backup_step:         db "backup_step", 0
sn_backup_finish:       db "backup_finish", 0
sn_backup_remaining:    db "backup_remaining", 0
sn_backup_pagecount:    db "backup_pagecount", 0
sn_sleep:               db "sleep", 0
sn_set_data_err_type:   db "set_data_error_type", 0

; Optional dlsym target names.
sym_serialize:          db "sqlite3_serialize", 0
sym_deserialize:        db "sqlite3_deserialize", 0
sym_enable_load_ext:    db "sqlite3_enable_load_extension", 0
sym_load_ext:           db "sqlite3_load_extension", 0
sym_create_window:      db "sqlite3_create_window_function", 0

; Error strings.
sq_e_nargs:             db "_sqlite3core: wrong number of arguments", 0
sq_e_handle:            db "_sqlite3core: stale or invalid handle", 0
sq_e_oom:               db "out of memory", 0
sq_e_bytes:             db "_sqlite3core: expected bytes-like object", 0
sq_e_exact_bytes:       db "_sqlite3core: expected bytes", 0
sq_e_float:             db "_sqlite3core: expected float", 0
sq_e_int:               db "_sqlite3core: expected int", 0
sq_e_int64:             db "Python int too large to convert to SQLite INTEGER", 0
sq_e_cint:              db "Python int too large to convert to C int", 0
sq_e_kw:                db "_sqlite3core functions take no keyword arguments", 0

section .text

;; ============================================================================
;; sq_tbl_alloc(rdi = SqTable*, rsi = elem_ptr) -> rax = handle index (>= 1)
;; Fails: -1
;;
;; Places elem_ptr in the first free slot (>= 1), growing the table if full.
;; ============================================================================
STA_TBL     equ 8
STA_ELEM    equ 16
STA_FRAME   equ 16              ; + 0 pushes = 16
DEF_FUNC sq_tbl_alloc, STA_FRAME
    mov [rbp - STA_TBL], rdi
    mov [rbp - STA_ELEM], rsi
    RT_LOCK_GATED sq_tbl_lock

    mov rax, [rdi + SqTable.arr]
    mov rcx, [rdi + SqTable.n]
    mov edx, 1
.scan:
    cmp rdx, rcx
    jae .grow_check
    cmp qword [rax + rdx*8], 0
    je .store
    inc rdx
    jmp .scan

.grow_check:
    test rcx, rcx
    jnz .check_cap
    ; First allocation: start with 16 slots, reserve slot 0 as NULL.
    mov edx, 1
    mov qword [rdi + SqTable.n], 1
.check_cap:
    mov r8, [rdi + SqTable.cap]
    cmp rdx, r8
    jb .bump_n
    mov r9, r8
    shl r9, 1
    cmp r9, 16
    jae .do_realloc
    mov r9d, 16
.do_realloc:
    mov rdi, [rdi + SqTable.arr]
    lea rsi, [r9*8]
    push rdx
    push r9
    call ap_realloc
    pop r9
    pop rdx
    test rax, rax
    jz .unlock_oom
    mov rdi, [rbp - STA_TBL]
    mov r8, [rdi + SqTable.cap]
    mov [rdi + SqTable.arr], rax
    mov [rdi + SqTable.cap], r9
    ; Zero newly added tail slots [r8 .. r9).
    push rdx
    lea rdi, [rax + r8*8]
    xor esi, esi
    mov rdx, r9
    sub rdx, r8
    shl rdx, 3
    call ap_memset
    pop rdx
    mov rdi, [rbp - STA_TBL]
    mov rax, [rdi + SqTable.arr]
.bump_n:
    lea rcx, [rdx + 1]
    mov [rdi + SqTable.n], rcx
.store:
    mov rsi, [rbp - STA_ELEM]
    mov [rax + rdx*8], rsi
    RT_UNLOCK_GATED sq_tbl_lock
    mov rax, rdx
    leave
    ret
.unlock_oom:
    RT_UNLOCK_GATED sq_tbl_lock
.oom:
    lea rdi, [rel exc_MemoryError_type]
    lea rsi, [rel sq_e_oom]
    call set_exception
    mov rax, -1
    leave
    ret
END_FUNC sq_tbl_alloc

;; ============================================================================
;; sq_tbl_get(rdi = SqTable*, rsi = handle_idx, rdx = magic) -> rax = elem_ptr
;; Fails: 0
;; ============================================================================
DEF_FUNC sq_tbl_get
    cmp rsi, 1
    jl .bad
    RT_LOCK_GATED sq_tbl_lock
    cmp rsi, [rdi + SqTable.n]
    jae .unlock_bad
    mov rax, [rdi + SqTable.arr]
    mov rax, [rax + rsi*8]
    test rax, rax
    jz .unlock_bad
    cmp [rax], rdx
    jne .unlock_bad
    RT_UNLOCK_GATED sq_tbl_lock
    leave
    ret
.unlock_bad:
    RT_UNLOCK_GATED sq_tbl_lock
.bad:
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel sq_e_handle]
    call set_exception
    xor eax, eax
    leave
    ret
END_FUNC sq_tbl_get

;; ============================================================================
;; sq_tbl_pop(rdi = SqTable*, rsi = handle_idx, rdx = magic) -> rax = elem_ptr
;; Fails: 0
;;
;; Validates and removes the slot from the table (setting slot to 0).
;; ============================================================================
DEF_FUNC sq_tbl_pop
    cmp rsi, 1
    jl .bad
    RT_LOCK_GATED sq_tbl_lock
    cmp rsi, [rdi + SqTable.n]
    jae .unlock_bad
    mov rcx, [rdi + SqTable.arr]
    mov rax, [rcx + rsi*8]
    test rax, rax
    jz .unlock_bad
    cmp [rax], rdx
    jne .unlock_bad
    mov qword [rcx + rsi*8], 0
    RT_UNLOCK_GATED sq_tbl_lock
    leave
    ret
.unlock_bad:
    RT_UNLOCK_GATED sq_tbl_lock
.bad:
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel sq_e_handle]
    call set_exception
    xor eax, eax
    leave
    ret
END_FUNC sq_tbl_pop

;; ============================================================================
;; sq_arg_int(rdi = args*, rsi = idx) -> rax = int64
;; Fails: -1
;; ============================================================================
DEF_FUNC sq_arg_int
    mov rdi, [rdi + rsi*8]
    V_IS_INT rdi, rcx
    jb .slow
    mov rax, rdi
    V_TO_I64 rax
    leave
    ret
.slow:
    call obj_as_index
    ERR_M1 .fail
    leave
    ret
.fail:
    mov rax, -1
    leave
    ret
END_FUNC sq_arg_int

;; ============================================================================
;; sq_arg_cint(rdi = args*, rsi = idx) -> rax = sign-extended int32
;; Fails: -1
;; ============================================================================
DEF_FUNC sq_arg_cint
    call sq_arg_int
    ERR_M1 .fail
    movsxd rdx, eax
    cmp rax, rdx
    jne .overflow
    leave
    ret
.overflow:
    lea rdi, [rel exc_OverflowError_type]
    lea rsi, [rel sq_e_cint]
    call set_exception
.fail:
    mov rax, -1
    leave
    ret
END_FUNC sq_arg_cint

;; ============================================================================
;; sq_arg_int64_strict(rdi = Value) -> rax = int64
;; Fails: -1
;;
;; Converts an int (or int subclass) to signed int64, raising OverflowError
;; if outside [-2^63, 2^63 - 1].
;; ============================================================================
SI64_VAL    equ 8
SI64_FRAME  equ 16              ; + 0 pushes = 16
DEF_FUNC sq_arg_int64_strict, SI64_FRAME
    V_IS_INT rdi, rcx
    jb .heap
    mov rax, rdi
    V_TO_I64 rax
    leave
    ret
.heap:
    V_TEST_PTR rdi, rcx
    ja .bad_type
    mov [rbp - SI64_VAL], rdi
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel int_type]
    cmp rdi, rsi
    je .is_int
    call type_is_subtype
    test eax, eax
    jz .bad_type
.is_int:
    mov rdi, [rbp - SI64_VAL]
    mov edx, TAG_PTR
    call int_fits_i64
    test eax, eax
    jz .overflow
    mov rdi, [rbp - SI64_VAL]
    mov edx, TAG_PTR
    call int_to_i64
    leave
    ret
.bad_type:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_int]
    call set_exception
    mov rax, -1
    leave
    ret
.overflow:
    lea rdi, [rel exc_OverflowError_type]
    lea rsi, [rel sq_e_int64]
    call set_exception
    mov rax, -1
    leave
    ret
END_FUNC sq_arg_int64_strict

;; ============================================================================
;; sq_arg_exact_bytes(rdi = Value) -> rax = data ptr (non-NULL), rdx = len
;; Fails: 0
;; ============================================================================
DEF_FUNC sq_arg_exact_bytes
    V_TEST_PTR rdi, rcx
    ja .bad
    lea rcx, [rel bytes_type]
    cmp [rdi + PyObject.ob_type], rcx
    jne .bad
    mov rdx, [rdi + PyBytesObject.ob_size]
    lea rax, [rdi + PyBytesObject.data]
    leave
    ret
.bad:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_exact_bytes]
    call set_exception
    xor eax, eax
    leave
    ret
END_FUNC sq_arg_exact_bytes

;; ============================================================================
;; sq_arg_bytes_like(rdi = Value) -> rax = data ptr (non-NULL), rdx = len
;; Fails: 0
;;
;; Accepts bytes, bytearray, or a live C-contiguous memoryview.
;; ============================================================================
DEF_FUNC sq_arg_bytes_like
    V_TEST_PTR rdi, rcx
    ja .bad
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .is_bytes
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .is_bytearray
    lea rcx, [rel memoryview_type]
    cmp rax, rcx
    je .is_mv
    mov r8, [rax + PyTypeObject.tp_as_buffer]
    test r8, r8
    jnz .is_buf
.bad:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_bytes]
    call set_exception
    xor eax, eax
    leave
    ret
.is_buf:
    mov esi, BUF_GET
    call r8
    test rax, rax
    jnz .buf_ok
    lea rax, [rel sq_empty_byte]
.buf_ok:
    leave
    ret
.is_bytes:
    mov rdx, [rdi + PyBytesObject.ob_size]
    lea rax, [rdi + PyBytesObject.data]
    leave
    ret
.is_bytearray:
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    mov rax, [rdi + PyByteArrayObject.ob_bytes]
    test rax, rax
    jnz .ba_ok
    lea rax, [rel sq_empty_byte]
.ba_ok:
    leave
    ret
.is_mv:
    mov rax, [rdi + PyMemoryViewObject.mv_buf]
    test rax, rax
    jz .bad
    cmp qword [rdi + PyMemoryViewObject.mv_stride], 1
    jne .non_contig
    mov rdx, [rdi + PyMemoryViewObject.mv_len]
    leave
    ret
.non_contig:
    SET_EXC exc_BufferError_type, "underlying buffer is not C-contiguous"
    xor eax, eax
    leave
    ret
END_FUNC sq_arg_bytes_like

;; ============================================================================
;; sq_complete(rdi = args*, rsi = nargs) -> rax = bool Value
;; _sqlite3core.complete(sql_bytes) -> bool
;; ============================================================================
DEF_FUNC sq_complete
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.complete() takes no keyword arguments", .fail
    cmp rsi, 1
    jne .nargs
    mov rdi, [rdi]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov rdi, rax
    call sqlite3_complete wrt ..plt
    test eax, eax
    jz .ret_false
    lea rax, [rel bool_true]
    INCREF rax
    leave
    ret
.ret_false:
    lea rax, [rel bool_false]
    INCREF rax
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_complete

;; ============================================================================
;; sq_open(rdi = args*, rsi = nargs) -> rax = tuple(rc, db_h)
;; _sqlite3core.open(path_bytes, flags) -> (rc, db_h)
;;
;; Releases the GIL around sqlite3_open_v2.  Returns (rc, db_h) where db_h is
;; 0 if sqlite3_open_v2 returned a NULL db pointer.  On non-OK rc with non-NULL
;; db, db_h is still returned so Python can read errmsg/errcode and close it.
;; ============================================================================
SO_ARGS     equ 8
SO_PATH     equ 16
SO_FLAGS    equ 24
SO_DBPTR    equ 32
SO_RC       equ 40
SO_H        equ 48
SO_FRAME    equ 48              ; + 0 pushes = 48
DEF_FUNC sq_open, SO_FRAME
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.open() takes no keyword arguments", .fail
    cmp rsi, 2
    jne .nargs
    mov [rbp - SO_ARGS], rdi
    mov rdi, [rdi]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SO_PATH], rax
    mov rdi, [rbp - SO_ARGS]
    mov esi, 1
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SO_FLAGS], rax

    mov qword [rbp - SO_DBPTR], 0
    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - SO_PATH]
    lea rsi, [rbp - SO_DBPTR]
    mov edx, [rbp - SO_FLAGS]
    xor ecx, ecx                ; zVfs = NULL
    call sqlite3_open_v2 wrt ..plt
    movsxd rax, eax
    ALLOW_THREADS_END
    mov [rbp - SO_RC], rax

    mov qword [rbp - SO_H], 0
    cmp qword [rbp - SO_DBPTR], 0
    je .build_tuple

    mov edi, SqlDb_size
    call ap_malloc
    test rax, rax
    jz .oom_db
    mov qword [rax + SqlDb.magic], SQ_DB_MAGIC
    mov rcx, [rbp - SO_DBPTR]
    mov [rax + SqlDb.db], rcx
    mov qword [rax + SqlDb.trace_cb], 0
    mov qword [rax + SqlDb.progress_cb], 0
    mov qword [rax + SqlDb.auth_cb], 0
    mov qword [rax + SqlDb.closing], 0
    mov rsi, rax
    lea rdi, [rel sq_db_table]
    push rsi
    sub rsp, 8
    call sq_tbl_alloc
    add rsp, 8
    pop rsi
    ERR_M1 .oom_free_node
    mov [rbp - SO_H], rax

.build_tuple:
    mov edi, 2
    call tuple_new
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbp - SO_RC]
    V_PACK_I64 rdx, r8
    mov [rcx], rdx
    mov rdx, [rbp - SO_H]
    V_PACK_I64 rdx, r8
    mov [rcx + 8], rdx
    leave
    ret

.oom_free_node:
    mov rdi, rsi
    call ap_free
    mov rdi, [rbp - SO_DBPTR]
    call sqlite3_close_v2 wrt ..plt
    jmp .fail
.oom_db:
    mov rdi, [rbp - SO_DBPTR]
    call sqlite3_close_v2 wrt ..plt
    lea rdi, [rel exc_MemoryError_type]
    lea rsi, [rel sq_e_oom]
    call set_exception
    jmp .fail
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_open

;; ============================================================================
;; sq_close(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.close(db_h, use_v2) -> rc
;;
;; Releases the GIL around sqlite3_close / sqlite3_close_v2.  Frees the handle
;; slot and associated callback contexts when rc == SQLITE_OK.
;; ============================================================================
SC_ARGS     equ 8
SC_H        equ 16
SC_V2       equ 24
SC_NODE     equ 32
SC_DB       equ 40
SC_RC       equ 48
SC_FRAME    equ 48              ; + 0 pushes = 48
DEF_FUNC sq_close, SC_FRAME
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.close() takes no keyword arguments", .fail
    cmp rsi, 2
    jne .nargs
    mov [rbp - SC_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    mov [rbp - SC_H], rax
    mov rdi, [rbp - SC_ARGS]
    mov esi, 1
    call sq_arg_int
    ERR_M1 .fail
    mov [rbp - SC_V2], rax

    lea rdi, [rel sq_db_table]
    mov rsi, [rbp - SC_H]
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov [rbp - SC_NODE], rax
    cmp qword [rax + SqlDb.closing], 0
    jne .already_closing
    mov qword [rax + SqlDb.closing], 1
    mov rcx, [rax + SqlDb.db]
    mov [rbp - SC_DB], rcx

    ; Detach trace/progress/authorizer hooks before closing so SQLite cannot
    ; invoke a freed SqlCb during close.
    mov rdi, rcx
    mov esi, SQLITE_TRACE_STMT
    xor edx, edx
    xor ecx, ecx
    call sqlite3_trace_v2 wrt ..plt
    mov rdi, [rbp - SC_DB]
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call sqlite3_progress_handler wrt ..plt
    mov rdi, [rbp - SC_DB]
    xor esi, esi
    xor edx, edx
    call sqlite3_set_authorizer wrt ..plt

    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - SC_DB]
    cmp qword [rbp - SC_V2], 0
    jne .call_v2
    call sqlite3_close wrt ..plt
    jmp .after_close
.call_v2:
    call sqlite3_close_v2 wrt ..plt
.after_close:
    movsxd rax, eax
    ALLOW_THREADS_END
    mov [rbp - SC_RC], rax

    cmp qword [rbp - SC_RC], SQLITE_OK
    je .finish_close
    mov rax, [rbp - SC_NODE]
    mov qword [rax + SqlDb.closing], 0
    jmp .ret_rc
.already_closing:
    mov qword [rbp - SC_RC], SQLITE_BUSY
    jmp .ret_rc
.finish_close:

    ; Remove slot and free SqlDb plus any stored hook SqlCb structs.
    lea rdi, [rel sq_db_table]
    mov rsi, [rbp - SC_H]
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_pop             ; err: already validated above
    test rax, rax
    jz .ret_rc
    mov [rbp - SC_NODE], rax
    mov qword [rax + SqlDb.magic], 0

    mov rdi, [rax + SqlDb.trace_cb]
    call sq_cb_free_if_set
    mov rax, [rbp - SC_NODE]
    mov rdi, [rax + SqlDb.progress_cb]
    call sq_cb_free_if_set
    mov rax, [rbp - SC_NODE]
    mov rdi, [rax + SqlDb.auth_cb]
    call sq_cb_free_if_set

    mov rdi, [rbp - SC_NODE]
    call ap_free

.ret_rc:
    mov rax, [rbp - SC_RC]
    V_PACK_I64 rax, rcx
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_close

;; ============================================================================
;; sq_cb_free_if_set(rdi = SqlCb* or 0) -> nothing
;;
;; Releases a SqlCb's Python callable and frees the struct.  Shared with
;; sqlite3_cb.asm in Commit 2.
;; ============================================================================
SBF_CB      equ 8
SBF_FRAME   equ 16              ; + 0 pushes = 16
DEF_FUNC sq_cb_free_if_set, SBF_FRAME
    test rdi, rdi
    jz .done
    mov [rbp - SBF_CB], rdi
    mov qword [rdi + SqlCb.magic], 0
    mov rax, [rdi + SqlCb.callable]
    mov qword [rdi + SqlCb.callable], 0
    test rax, rax
    jz .free_mem
    DECREF_V rax, rcx
.free_mem:
    mov rdi, [rbp - SBF_CB]
    call ap_free
.done:
    leave
    ret
END_FUNC sq_cb_free_if_set

;; ============================================================================
;; sq_busy_timeout(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.busy_timeout(db_h, ms) -> rc
;; ============================================================================
SBT_ARGS    equ 8
SBT_MS      equ 16
SBT_FRAME   equ 16
DEF_FUNC sq_busy_timeout, SBT_FRAME
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.busy_timeout() takes no keyword arguments", .fail
    cmp rsi, 2
    jne .nargs
    mov [rbp - SBT_ARGS], rdi
    mov esi, 1
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SBT_MS], rax
    mov rdi, [rbp - SBT_ARGS]
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rdi, [rax + SqlDb.db]
    mov esi, [rbp - SBT_MS]
    call sqlite3_busy_timeout wrt ..plt
    movsxd rax, eax
    V_PACK_I64 rax, rcx
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_busy_timeout

;; ============================================================================
;; sq_interrupt(rdi = args*, rsi = nargs) -> rax = None
;; _sqlite3core.interrupt(db_h) -> None
;; ============================================================================
DEF_FUNC sq_interrupt
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.interrupt() takes no keyword arguments", .fail
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rdi, [rax + SqlDb.db]
    call sqlite3_interrupt wrt ..plt
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_interrupt

;; Macro for simple 1-arg DB queries returning an int32/int64:
;;   SQ_DB_INT_GETTER func_name, sqlite3_fn, is_64bit
%macro SQ_DB_INT_GETTER 3
;; %1(rdi = args*, rsi = nargs) -> rax = int Value
DEF_FUNC %1
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core function takes no keyword arguments", %%fail
    cmp rsi, 1
    jne %%nargs
    xor esi, esi
    call sq_arg_int
    ERR_M1 %%fail
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL %%fail
    mov rdi, [rax + SqlDb.db]
    call %2 wrt ..plt
%if %3 == 0
    movsxd rax, eax
%endif
    V_PACK_I64 rax, rcx
    leave
    ret
%%nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
%%fail:
    xor eax, eax
    leave
    ret
END_FUNC %1
%endmacro

SQ_DB_INT_GETTER sq_get_autocommit,    sqlite3_get_autocommit,    0
SQ_DB_INT_GETTER sq_total_changes,     sqlite3_total_changes,     0
SQ_DB_INT_GETTER sq_changes,           sqlite3_changes,           0
SQ_DB_INT_GETTER sq_last_insert_rowid, sqlite3_last_insert_rowid, 1
SQ_DB_INT_GETTER sq_errcode,           sqlite3_errcode,           0
SQ_DB_INT_GETTER sq_extended_errcode,  sqlite3_extended_errcode,  0

;; ============================================================================
;; sq_errmsg(rdi = args*, rsi = nargs) -> rax = str
;; _sqlite3core.errmsg(db_h) -> str
;; ============================================================================
DEF_FUNC sq_errmsg
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.errmsg() takes no keyword arguments", .fail
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rdi, [rax + SqlDb.db]
    call sqlite3_errmsg wrt ..plt
    test rax, rax
    jz .empty
    mov rdi, rax
    call str_from_cstr_heap
    leave
    ret
.empty:
    lea rdi, [rel sq_empty_byte]
    call str_from_cstr_heap
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_errmsg

;; ============================================================================
;; sq_errstr(rdi = args*, rsi = nargs) -> rax = str
;; _sqlite3core.errstr(code) -> str
;; ============================================================================
DEF_FUNC sq_errstr
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.errstr() takes no keyword arguments", .fail
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call sq_arg_cint
    ERR_M1 .fail
    mov edi, eax
    call sqlite3_errstr wrt ..plt
    test rax, rax
    jz .empty
    mov rdi, rax
    call str_from_cstr_heap
    leave
    ret
.empty:
    lea rdi, [rel sq_empty_byte]
    call str_from_cstr_heap
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_errstr

;; ============================================================================
;; sq_prepare(rdi = args*, rsi = nargs) -> rax = tuple(rc, stmt_h, tail_off)
;; _sqlite3core.prepare(db_h, sql_bytes) -> (rc, stmt_h, tail_offset)
;;
;; Releases the GIL around sqlite3_prepare_v2.  sql_bytes must be exact bytes
;; (immutable, so safe across GIL release while caller holds a ref).
;; ============================================================================
SP_ARGS     equ 8
SP_DBH      equ 16
SP_DB       equ 24
SP_SQL      equ 32
SP_LEN      equ 40
SP_STMT     equ 48
SP_TAIL     equ 56
SP_RC       equ 64
SP_SH       equ 72
SP_FRAME    equ 80              ; + 0 pushes = 80
DEF_FUNC sq_prepare, SP_FRAME
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.prepare() takes no keyword arguments", .fail
    cmp rsi, 2
    jne .nargs
    mov [rbp - SP_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    mov [rbp - SP_DBH], rax
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlDb.db]
    mov [rbp - SP_DB], rcx

    mov rdi, [rbp - SP_ARGS]
    mov rdi, [rdi + 8]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SP_SQL], rax
    mov [rbp - SP_LEN], rdx
    ; Check length fits in signed int32 (sqlite3_prepare_v2 nByte parameter).
    mov eax, 0x7FFFFFFF
    cmp rdx, rax
    ja .too_big

    mov qword [rbp - SP_STMT], 0
    mov qword [rbp - SP_TAIL], 0
    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - SP_DB]
    mov rsi, [rbp - SP_SQL]
    mov edx, [rbp - SP_LEN]
    lea rcx, [rbp - SP_STMT]
    lea r8, [rbp - SP_TAIL]
    call sqlite3_prepare_v2 wrt ..plt
    movsxd rax, eax
    ALLOW_THREADS_END
    mov [rbp - SP_RC], rax

    mov qword [rbp - SP_SH], 0
    cmp qword [rbp - SP_STMT], 0
    je .build_tuple

    mov edi, SqlStmt_size
    call ap_malloc
    test rax, rax
    jz .oom_stmt
    mov qword [rax + SqlStmt.magic], SQ_STMT_MAGIC
    mov rcx, [rbp - SP_STMT]
    mov [rax + SqlStmt.stmt], rcx
    mov rcx, [rbp - SP_DBH]
    mov [rax + SqlStmt.db_h], rcx
    mov rsi, rax
    lea rdi, [rel sq_stmt_table]
    push rsi
    sub rsp, 8
    call sq_tbl_alloc
    add rsp, 8
    pop rsi
    ERR_M1 .oom_free_node
    mov [rbp - SP_SH], rax

.build_tuple:
    ; Compute tail_offset = (tail ? tail - sql_ptr : len).
    mov rdx, [rbp - SP_TAIL]
    test rdx, rdx
    jz .tail_end
    sub rdx, [rbp - SP_SQL]
    jmp .make_tup
.tail_end:
    mov rdx, [rbp - SP_LEN]
.make_tup:
    push rdx
    sub rsp, 8
    mov edi, 3
    call tuple_new
    add rsp, 8
    pop rdx
    mov rcx, [rax + PyTupleObject.ob_item]
    mov r8, [rbp - SP_RC]
    V_PACK_I64 r8, r9
    mov [rcx], r8
    mov r8, [rbp - SP_SH]
    V_PACK_I64 r8, r9
    mov [rcx + 8], r8
    V_PACK_I64 rdx, r9
    mov [rcx + 16], rdx
    leave
    ret

.too_big:
    mov qword [rbp - SP_RC], SQLITE_TOOBIG
    mov qword [rbp - SP_SH], 0
    mov rdx, [rbp - SP_LEN]
    jmp .make_tup
.oom_free_node:
    mov rdi, rsi
    call ap_free
    mov rdi, [rbp - SP_STMT]
    call sqlite3_finalize wrt ..plt
    jmp .fail
.oom_stmt:
    mov rdi, [rbp - SP_STMT]
    call sqlite3_finalize wrt ..plt
    lea rdi, [rel exc_MemoryError_type]
    lea rsi, [rel sq_e_oom]
    call set_exception
    jmp .fail
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_prepare

;; ============================================================================
;; sq_step(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.step(stmt_h) -> rc
;;
;; Releases the GIL around sqlite3_step.
;; ============================================================================
SST_STMT    equ 8
SST_FRAME   equ 16
DEF_FUNC sq_step, SST_FRAME
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.step() takes no keyword arguments", .fail
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_stmt_table]
    mov rsi, rax
    mov rdx, SQ_STMT_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlStmt.stmt]
    mov [rbp - SST_STMT], rcx

    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - SST_STMT]
    call sqlite3_step wrt ..plt
    movsxd rax, eax
    ALLOW_THREADS_END

    ; If a collation callback left a Python exception pending:
    ;   - on SQLITE_ROW / SQLITE_DONE, propagate it directly (return 0)
    ;   - on SQLite error, print/clear it and return rc for SQLite error
    cmp qword [gs:ThreadState.current_exception], 0
    je .ret_rc
    cmp rax, SQLITE_ROW
    je .fail
    cmp rax, SQLITE_DONE
    je .fail
    push rax
    sub rsp, 8
    xor edi, edi
    call sq_cb_print_or_clear_pending
    add rsp, 8
    pop rax
.ret_rc:
    V_PACK_I64 rax, rcx
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_step

;; ============================================================================
;; sq_reset(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.reset(stmt_h) -> rc
;; ============================================================================
SR_STMT     equ 8
SR_FRAME    equ 16
DEF_FUNC sq_reset, SR_FRAME
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.reset() takes no keyword arguments", .fail
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_stmt_table]
    mov rsi, rax
    mov rdx, SQ_STMT_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlStmt.stmt]
    mov [rbp - SR_STMT], rcx
    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - SR_STMT]
    call sqlite3_reset wrt ..plt
    movsxd rax, eax
    ALLOW_THREADS_END
    V_PACK_I64 rax, rcx
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_reset

;; ============================================================================
;; sq_finalize(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.finalize(stmt_h) -> rc
;;
;; Always pops and frees the SqlStmt handle slot, then finalizes the C stmt.
;; ============================================================================
SF_NODE     equ 8
SF_STMT     equ 16
SF_RC       equ 24
SF_FRAME    equ 32
DEF_FUNC sq_finalize, SF_FRAME
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.finalize() takes no keyword arguments", .fail
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_stmt_table]
    mov rsi, rax
    mov rdx, SQ_STMT_MAGIC
    call sq_tbl_pop
    ERR_NULL .fail
    mov [rbp - SF_NODE], rax
    mov rcx, [rax + SqlStmt.stmt]
    mov [rbp - SF_STMT], rcx
    mov qword [rax + SqlStmt.magic], 0

    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - SF_STMT]
    call sqlite3_finalize wrt ..plt
    movsxd rax, eax
    ALLOW_THREADS_END
    mov [rbp - SF_RC], rax

    mov rdi, [rbp - SF_NODE]
    call ap_free

    mov rax, [rbp - SF_RC]
    V_PACK_I64 rax, rcx
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_finalize

;; Macro for simple 1-arg stmt queries returning an int32:
;;   SQ_STMT_INT_GETTER func_name, sqlite3_fn
%macro SQ_STMT_INT_GETTER 2
;; %1(rdi = args*, rsi = nargs) -> rax = int Value
DEF_FUNC %1
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core function takes no keyword arguments", %%fail
    cmp rsi, 1
    jne %%nargs
    xor esi, esi
    call sq_arg_int
    ERR_M1 %%fail
    lea rdi, [rel sq_stmt_table]
    mov rsi, rax
    mov rdx, SQ_STMT_MAGIC
    call sq_tbl_get
    ERR_NULL %%fail
    mov rdi, [rax + SqlStmt.stmt]
    call %2 wrt ..plt
    movsxd rax, eax
    V_PACK_I64 rax, rcx
    leave
    ret
%%nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
%%fail:
    xor eax, eax
    leave
    ret
END_FUNC %1
%endmacro

SQ_STMT_INT_GETTER sq_stmt_busy,     sqlite3_stmt_busy
SQ_STMT_INT_GETTER sq_stmt_readonly, sqlite3_stmt_readonly
SQ_STMT_INT_GETTER sq_column_count,  sqlite3_column_count
SQ_STMT_INT_GETTER sq_data_count,    sqlite3_data_count
SQ_STMT_INT_GETTER sq_bind_count,    sqlite3_bind_parameter_count

;; Macro for 2-arg (stmt_h, idx) queries returning const char* -> str | None:
SSSI_ARGS   equ 8
SSSI_IDX    equ 16
SSSI_FRAME  equ 16
%macro SQ_STMT_STR_BY_IDX 2
;; %1(rdi = args*, rsi = nargs) -> rax = str or None
DEF_FUNC %1, SSSI_FRAME
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core function takes no keyword arguments", %%fail
    cmp rsi, 2
    jne %%nargs
    mov [rbp - SSSI_ARGS], rdi
    mov esi, 1
    call sq_arg_cint
    ERR_M1 %%fail
    mov [rbp - SSSI_IDX], rax
    mov rdi, [rbp - SSSI_ARGS]
    xor esi, esi
    call sq_arg_int
    ERR_M1 %%fail
    lea rdi, [rel sq_stmt_table]
    mov rsi, rax
    mov rdx, SQ_STMT_MAGIC
    call sq_tbl_get
    ERR_NULL %%fail
    mov rdi, [rax + SqlStmt.stmt]
    mov esi, [rbp - SSSI_IDX]
    call %2 wrt ..plt
    test rax, rax
    jz %%ret_none
    mov rdi, rax
    call str_from_cstr_heap
    leave
    ret
%%ret_none:
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
%%nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
%%fail:
    xor eax, eax
    leave
    ret
END_FUNC %1
%endmacro

SQ_STMT_STR_BY_IDX sq_column_name,     sqlite3_column_name
SQ_STMT_STR_BY_IDX sq_column_decltype, sqlite3_column_decltype
SQ_STMT_STR_BY_IDX sq_bind_name,       sqlite3_bind_parameter_name

;; ============================================================================
;; sq_column_type(rdi = args*, rsi = nargs) -> rax = int
;; _sqlite3core.column_type(stmt_h, col_idx) -> SQLITE_*
;; ============================================================================
SCT_ARGS    equ 8
SCT_IDX     equ 16
SCT_FRAME   equ 16
DEF_FUNC sq_column_type, SCT_FRAME
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.column_type() takes no keyword arguments", .fail
    cmp rsi, 2
    jne .nargs
    mov [rbp - SCT_ARGS], rdi
    mov esi, 1
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SCT_IDX], rax
    mov rdi, [rbp - SCT_ARGS]
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_stmt_table]
    mov rsi, rax
    mov rdx, SQ_STMT_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rdi, [rax + SqlStmt.stmt]
    mov esi, [rbp - SCT_IDX]
    call sqlite3_column_type wrt ..plt
    movsxd rax, eax
    V_PACK_I64 rax, rcx
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_column_type

;; ============================================================================
;; sq_column_blob(rdi = args*, rsi = nargs) -> rax = bytes or None
;; _sqlite3core.column_blob(stmt_h, col_idx) -> bytes | None
;;
;; Matches CPython's converter path: calls sqlite3_column_blob followed by
;; sqlite3_column_bytes.  Returns None when the column is SQL NULL.
;; ============================================================================
SCB_ARGS    equ 8
SCB_IDX     equ 16
SCB_STMT    equ 24
SCB_PTR     equ 32
SCB_FRAME   equ 32
DEF_FUNC sq_column_blob, SCB_FRAME
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.column_blob() takes no keyword arguments", .fail
    cmp rsi, 2
    jne .nargs
    mov [rbp - SCB_ARGS], rdi
    mov esi, 1
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SCB_IDX], rax
    mov rdi, [rbp - SCB_ARGS]
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_stmt_table]
    mov rsi, rax
    mov rdx, SQ_STMT_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rdi, [rax + SqlStmt.stmt]
    mov [rbp - SCB_STMT], rdi
    mov esi, [rbp - SCB_IDX]
    call sqlite3_column_blob wrt ..plt
    test rax, rax
    jz .check_null
    mov [rbp - SCB_PTR], rax
    mov rdi, [rbp - SCB_STMT]
    mov esi, [rbp - SCB_IDX]
    call sqlite3_column_bytes wrt ..plt
    movsxd rsi, eax
    mov rdi, [rbp - SCB_PTR]
    call bytes_from_data
    leave
    ret
.check_null:
    ; CPython treats sqlite3_column_blob() == NULL (both SQL NULL and 0-byte
    ; blobs) as None when running converters.
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_column_blob

;; ============================================================================
;; sq_fetch_row(rdi = args*, rsi = nargs) -> rax = tuple | (tuple, tuple) | int
;; _sqlite3core.fetch_row(stmt_h, mode)
;;
;; Reads all columns of the current row in one call:
;;   mode == 0: text_factory is str -> returns tuple; validates UTF-8 and
;;              returns the offending column index (int) if invalid UTF-8.
;;   mode == 1: text_factory is bytes -> returns tuple (TEXT & BLOB as bytes).
;;   mode == 2: custom text_factory -> returns (values_tuple, types_tuple)
;;              with TEXT as bytes so Python can run text_factory on TEXT only.
;; ============================================================================
FR_ARGS     equ 8
FR_MODE     equ 16
FR_STMT     equ 24
FR_NCOLS    equ 32
FR_VALS     equ 40
FR_TYPES    equ 48
FR_PTR      equ 56
FR_LEN      equ 64
FR_SAVED    equ 72
FR_FRAME    equ 72              ; + 3 pushes (rbx, r12, r13) = 96, 16-aligned
DEF_FUNC sq_fetch_row, FR_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - FR_SAVED], rsp
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.fetch_row() takes no keyword arguments", .fail
    cmp rsi, 2
    jne .nargs
    mov [rbp - FR_ARGS], rdi
    mov esi, 1
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - FR_MODE], rax
    mov rdi, [rbp - FR_ARGS]
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_stmt_table]
    mov rsi, rax
    mov rdx, SQ_STMT_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov r12, [rax + SqlStmt.stmt]
    mov [rbp - FR_STMT], r12

    mov rdi, r12
    call sqlite3_data_count wrt ..plt
    movsxd r13, eax
    mov [rbp - FR_NCOLS], r13

    mov qword [rbp - FR_VALS], 0
    mov qword [rbp - FR_TYPES], 0

    mov rdi, r13
    call tuple_new
    mov [rbp - FR_VALS], rax

    cmp qword [rbp - FR_MODE], 2
    jne .start_loop
    mov rdi, r13
    call tuple_new
    mov [rbp - FR_TYPES], rax

.start_loop:
    xor ebx, ebx                ; col index 0 .. r13-1
.col_loop:
    cmp rbx, r13
    jge .loop_done

    mov rdi, r12
    mov esi, ebx
    call sqlite3_column_type wrt ..plt
    movsxd rdx, eax

    cmp qword [rbp - FR_MODE], 2
    jne .switch_type
    mov rcx, [rbp - FR_TYPES]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov r8, rdx
    V_PACK_I64 r8, r9
    mov [rcx + rbx*8], r8

.switch_type:
    cmp edx, SQLITE_NULL
    je .col_null
    cmp edx, SQLITE_INTEGER
    je .col_int
    cmp edx, SQLITE_FLOAT
    je .col_float
    cmp edx, SQLITE_TEXT
    je .col_text
    ; Otherwise SQLITE_BLOB
.col_blob:
    mov rdi, r12
    mov esi, ebx
    call sqlite3_column_blob wrt ..plt
    mov [rbp - FR_PTR], rax
    mov rdi, r12
    mov esi, ebx
    call sqlite3_column_bytes wrt ..plt
    movsxd rsi, eax
    mov rdi, [rbp - FR_PTR]
    test rdi, rdi
    jnz .blob_make
    lea rdi, [rel sq_empty_byte]
    xor esi, esi
.blob_make:
    call bytes_from_data
    jmp .store_val

.col_null:
    lea rax, [rel none_singleton]
    INCREF rax
    jmp .store_val

.col_int:
    mov rdi, r12
    mov esi, ebx
    call sqlite3_column_int64 wrt ..plt
    V_PACK_I64 rax, rcx
    jmp .store_val

.col_float:
    mov rdi, r12
    mov esi, ebx
    call sqlite3_column_double wrt ..plt
    movq rax, xmm0
    V_FROM_F64 rax, rcx
    jmp .store_val

.col_text:
    mov rdi, r12
    mov esi, ebx
    call sqlite3_column_text wrt ..plt
    mov [rbp - FR_PTR], rax
    mov rdi, r12
    mov esi, ebx
    call sqlite3_column_bytes wrt ..plt
    movsxd rsi, eax
    mov [rbp - FR_LEN], rsi
    mov rdi, [rbp - FR_PTR]
    test rdi, rdi
    jnz .text_have_ptr
    lea rdi, [rel sq_empty_byte]
    mov [rbp - FR_PTR], rdi
    xor esi, esi
    mov [rbp - FR_LEN], rsi
.text_have_ptr:
    cmp qword [rbp - FR_MODE], 0
    jne .text_as_bytes
    ; mode 0: validate UTF-8 strictly before building str.
    call bytes_utf8_check
    cmp rax, -1
    jne .bad_utf8
    mov rdi, [rbp - FR_PTR]
    mov rsi, [rbp - FR_LEN]
    call str_new_heap
    jmp .store_val
.text_as_bytes:
    mov rdi, [rbp - FR_PTR]
    mov rsi, [rbp - FR_LEN]
    call bytes_from_data

.store_val:
    mov rcx, [rbp - FR_VALS]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + rbx*8], rax
    inc rbx
    jmp .col_loop

.loop_done:
    cmp qword [rbp - FR_MODE], 2
    jne .ret_vals
    mov edi, 2
    call tuple_new
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbp - FR_VALS]
    mov [rcx], rdx
    mov rdx, [rbp - FR_TYPES]
    mov [rcx + 8], rdx
    mov rsp, [rbp - FR_SAVED]
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ret_vals:
    mov rax, [rbp - FR_VALS]
    mov rsp, [rbp - FR_SAVED]
    pop r13
    pop r12
    pop rbx
    leave
    ret

.bad_utf8:
    ; Release partially-filled values tuple (remaining slots are NULL/zeroed)
    ; and return the offending column index as an int Value.
    mov rdi, [rbp - FR_VALS]
    call obj_decref
    mov rax, rbx
    V_PACK_I64 rax, rcx
    mov rsp, [rbp - FR_SAVED]
    pop r13
    pop r12
    pop rbx
    leave
    ret

.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    mov rsp, [rbp - FR_SAVED]
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sq_fetch_row

;; ============================================================================
;; sq_bind_null(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.bind_null(stmt_h, idx) -> rc
;; ============================================================================
SBN_ARGS    equ 8
SBN_IDX     equ 16
SBN_FRAME   equ 16
DEF_FUNC sq_bind_null, SBN_FRAME
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.bind_null() takes no keyword arguments", .fail
    cmp rsi, 2
    jne .nargs
    mov [rbp - SBN_ARGS], rdi
    mov esi, 1
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SBN_IDX], rax
    mov rdi, [rbp - SBN_ARGS]
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_stmt_table]
    mov rsi, rax
    mov rdx, SQ_STMT_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rdi, [rax + SqlStmt.stmt]
    mov esi, [rbp - SBN_IDX]
    call sqlite3_bind_null wrt ..plt
    movsxd rax, eax
    V_PACK_I64 rax, rcx
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_bind_null

;; ============================================================================
;; sq_bind_int64(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.bind_int64(stmt_h, idx, val) -> rc
;; ============================================================================
SBI_ARGS    equ 8
SBI_IDX     equ 16
SBI_VAL     equ 24
SBI_FRAME   equ 32
DEF_FUNC sq_bind_int64, SBI_FRAME
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.bind_int64() takes no keyword arguments", .fail
    cmp rsi, 3
    jne .nargs
    mov [rbp - SBI_ARGS], rdi
    mov esi, 1
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SBI_IDX], rax
    mov rdi, [rbp - SBI_ARGS]
    mov rdi, [rdi + 16]
    call sq_arg_int64_strict
    ERR_M1 .fail
    mov [rbp - SBI_VAL], rax
    mov rdi, [rbp - SBI_ARGS]
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_stmt_table]
    mov rsi, rax
    mov rdx, SQ_STMT_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rdi, [rax + SqlStmt.stmt]
    mov esi, [rbp - SBI_IDX]
    mov rdx, [rbp - SBI_VAL]
    call sqlite3_bind_int64 wrt ..plt
    movsxd rax, eax
    V_PACK_I64 rax, rcx
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_bind_int64

;; ============================================================================
;; sq_bind_double(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.bind_double(stmt_h, idx, float_val) -> rc
;; ============================================================================
SBD_ARGS    equ 8
SBD_IDX     equ 16
SBD_VAL     equ 24
SBD_FRAME   equ 32
DEF_FUNC sq_bind_double, SBD_FRAME
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.bind_double() takes no keyword arguments", .fail
    cmp rsi, 3
    jne .nargs
    mov [rbp - SBD_ARGS], rdi
    mov esi, 1
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SBD_IDX], rax
    mov rdi, [rbp - SBD_ARGS]
    mov rax, [rdi + 16]
    V_IS_FLOAT rax, rcx
    jae .bad_float
    V_TO_F64 rax
    mov [rbp - SBD_VAL], rax
    mov rdi, [rbp - SBD_ARGS]
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_stmt_table]
    mov rsi, rax
    mov rdx, SQ_STMT_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rdi, [rax + SqlStmt.stmt]
    mov esi, [rbp - SBD_IDX]
    movsd xmm0, [rbp - SBD_VAL]
    call sqlite3_bind_double wrt ..plt
    movsxd rax, eax
    V_PACK_I64 rax, rcx
    leave
    ret
.bad_float:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_float]
    call set_exception
    jmp .fail
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_bind_double

;; ============================================================================
;; sq_bind_text(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.bind_text(stmt_h, idx, utf8_bytes) -> rc
;; ============================================================================
SBTX_ARGS   equ 8
SBTX_IDX    equ 16
SBTX_PTR    equ 24
SBTX_LEN    equ 32
SBTX_FRAME  equ 32
DEF_FUNC sq_bind_text, SBTX_FRAME
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.bind_text() takes no keyword arguments", .fail
    cmp rsi, 3
    jne .nargs
    mov [rbp - SBTX_ARGS], rdi
    mov esi, 1
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SBTX_IDX], rax
    mov rdi, [rbp - SBTX_ARGS]
    mov rdi, [rdi + 16]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SBTX_PTR], rax
    mov [rbp - SBTX_LEN], rdx
    mov eax, 0x7FFFFFFF
    cmp rdx, rax
    ja .too_big
    mov rdi, [rbp - SBTX_ARGS]
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_stmt_table]
    mov rsi, rax
    mov rdx, SQ_STMT_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rdi, [rax + SqlStmt.stmt]
    mov esi, [rbp - SBTX_IDX]
    mov rdx, [rbp - SBTX_PTR]
    mov ecx, [rbp - SBTX_LEN]
    mov r8, SQLITE_TRANSIENT
    call sqlite3_bind_text wrt ..plt
    movsxd rax, eax
    V_PACK_I64 rax, rcx
    leave
    ret
.too_big:
    mov rax, SQLITE_TOOBIG
    V_PACK_I64 rax, rcx
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_bind_text

;; ============================================================================
;; sq_bind_blob(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.bind_blob(stmt_h, idx, bytes_like) -> rc
;; ============================================================================
SBBL_ARGS   equ 8
SBBL_IDX    equ 16
SBBL_PTR    equ 24
SBBL_LEN    equ 32
SBBL_FRAME  equ 32
DEF_FUNC sq_bind_blob, SBBL_FRAME
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.bind_blob() takes no keyword arguments", .fail
    cmp rsi, 3
    jne .nargs
    mov [rbp - SBBL_ARGS], rdi
    mov esi, 1
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SBBL_IDX], rax
    mov rdi, [rbp - SBBL_ARGS]
    mov rdi, [rdi + 16]
    call sq_arg_bytes_like
    ERR_NULL .fail
    mov [rbp - SBBL_PTR], rax
    mov [rbp - SBBL_LEN], rdx
    mov eax, 0x7FFFFFFF
    cmp rdx, rax
    ja .too_big
    mov rdi, [rbp - SBBL_ARGS]
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_stmt_table]
    mov rsi, rax
    mov rdx, SQ_STMT_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rdi, [rax + SqlStmt.stmt]
    mov esi, [rbp - SBBL_IDX]
    mov rdx, [rbp - SBBL_PTR]
    mov ecx, [rbp - SBBL_LEN]
    mov r8, SQLITE_TRANSIENT
    call sqlite3_bind_blob wrt ..plt
    movsxd rax, eax
    V_PACK_I64 rax, rcx
    leave
    ret
.too_big:
    mov rax, SQLITE_TOOBIG
    V_PACK_I64 rax, rcx
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_bind_blob

;; ============================================================================
;; sq_set_data_error_type(rdi = args*, rsi = nargs) -> rax = None
;; _sqlite3core.set_data_error_type(cls) -> None
;; ============================================================================
DEF_FUNC sq_set_data_error_type
    and rsp, -16
    NO_KEYWORDS_RET "_sqlite3core.set_data_error_type() takes no keyword arguments", .fail
    cmp rsi, 1
    jne .nargs
    mov rax, [rdi]
    mov rcx, [rel sq_data_error_type]
    INCREF_V rax, rdx
    mov [rel sq_data_error_type], rax
    test rcx, rcx
    jz .ret_none
    DECREF_V rcx, rdx
.ret_none:
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_set_data_error_type

;; ============================================================================
;; sq_set_bool_attr(rdi = dict, rsi = name_cstr, rdx = ptr_nonzero) -> nothing
;; ============================================================================
SBA_DICT    equ 8
SBA_VAL     equ 16
SBA_FRAME   equ 16
DEF_FUNC_LOCAL sq_set_bool_attr, SBA_FRAME
    mov [rbp - SBA_DICT], rdi
    lea rax, [rel bool_false]
    test rdx, rdx
    jz .got_val
    lea rax, [rel bool_true]
.got_val:
    mov [rbp - SBA_VAL], rax
    mov rdi, rsi
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    mov rdi, [rbp - SBA_DICT]
    mov rsi, rax
    mov rdx, [rbp - SBA_VAL]
    call dict_set_str
    add rsp, 8
    pop rdi
    call obj_decref
    leave
    ret
END_FUNC sq_set_bool_attr

;; ============================================================================
;; sqlite3_module_create() -> rax = PyModuleObject* (_sqlite3core)
;; ============================================================================
SM_FRAME    equ 8               ; + 3 pushes (rbx, r12, r13) = 32, 16-aligned
DEF_FUNC sqlite3_module_create, SM_FRAME
    push rbx
    push r12
    push r13

    call sqlite3_initialize wrt ..plt

    call dict_new
    mov r12, rax                ; MODULE_ADD_FUNC reads dict from r12

    MODULE_ADD_FUNC sq_complete,          sn_complete
    MODULE_ADD_FUNC sq_open,              sn_open
    MODULE_ADD_FUNC sq_close,             sn_close
    MODULE_ADD_FUNC sq_busy_timeout,      sn_busy_timeout
    MODULE_ADD_FUNC sq_interrupt,         sn_interrupt
    MODULE_ADD_FUNC sq_get_autocommit,    sn_get_autocommit
    MODULE_ADD_FUNC sq_total_changes,     sn_total_changes
    MODULE_ADD_FUNC sq_changes,           sn_changes
    MODULE_ADD_FUNC sq_last_insert_rowid, sn_last_insert_rowid
    MODULE_ADD_FUNC sq_errcode,           sn_errcode
    MODULE_ADD_FUNC sq_extended_errcode,  sn_extended_errcode
    MODULE_ADD_FUNC sq_errmsg,            sn_errmsg
    MODULE_ADD_FUNC sq_errstr,            sn_errstr
    MODULE_ADD_FUNC sq_prepare,           sn_prepare
    MODULE_ADD_FUNC sq_step,              sn_step
    MODULE_ADD_FUNC sq_reset,             sn_reset
    MODULE_ADD_FUNC sq_finalize,          sn_finalize
    MODULE_ADD_FUNC sq_stmt_busy,         sn_stmt_busy
    MODULE_ADD_FUNC sq_stmt_readonly,     sn_stmt_readonly
    MODULE_ADD_FUNC sq_column_count,      sn_column_count
    MODULE_ADD_FUNC sq_data_count,        sn_data_count
    MODULE_ADD_FUNC sq_column_name,       sn_column_name
    MODULE_ADD_FUNC sq_column_decltype,   sn_column_decltype
    MODULE_ADD_FUNC sq_column_type,       sn_column_type
    MODULE_ADD_FUNC sq_column_blob,       sn_column_blob
    MODULE_ADD_FUNC sq_fetch_row,         sn_fetch_row
    MODULE_ADD_FUNC sq_bind_count,        sn_bind_count
    MODULE_ADD_FUNC sq_bind_name,         sn_bind_name
    MODULE_ADD_FUNC sq_bind_null,         sn_bind_null
    MODULE_ADD_FUNC sq_bind_int64,        sn_bind_int64
    MODULE_ADD_FUNC sq_bind_double,       sn_bind_double
    MODULE_ADD_FUNC sq_bind_text,         sn_bind_text
    MODULE_ADD_FUNC sq_bind_blob,         sn_bind_blob
    MODULE_ADD_FUNC sq_set_cb_tracebacks, sn_set_cb_tracebacks
    MODULE_ADD_FUNC sq_create_function,   sn_create_function
    MODULE_ADD_FUNC sq_create_aggregate,  sn_create_aggregate
    MODULE_ADD_FUNC sq_create_window,     sn_create_window
    MODULE_ADD_FUNC sq_create_collation,  sn_create_collation
    MODULE_ADD_FUNC sq_set_authorizer,    sn_set_authorizer
    MODULE_ADD_FUNC sq_set_progress,      sn_set_progress
    MODULE_ADD_FUNC sq_set_trace,         sn_set_trace
    MODULE_ADD_FUNC sq_limit,             sn_limit
    MODULE_ADD_FUNC sq_db_config,         sn_db_config
    MODULE_ADD_FUNC sq_serialize,         sn_serialize
    MODULE_ADD_FUNC sq_deserialize,       sn_deserialize
    MODULE_ADD_FUNC sq_enable_load_ext,   sn_enable_load_ext
    MODULE_ADD_FUNC sq_load_ext,          sn_load_ext
    MODULE_ADD_FUNC sq_blob_open,         sn_blob_open
    MODULE_ADD_FUNC sq_blob_close,        sn_blob_close
    MODULE_ADD_FUNC sq_blob_bytes,        sn_blob_bytes
    MODULE_ADD_FUNC sq_blob_read,         sn_blob_read
    MODULE_ADD_FUNC sq_blob_write,        sn_blob_write
    MODULE_ADD_FUNC sq_backup_init,       sn_backup_init
    MODULE_ADD_FUNC sq_backup_step,       sn_backup_step
    MODULE_ADD_FUNC sq_backup_finish,     sn_backup_finish
    MODULE_ADD_FUNC sq_backup_remaining,  sn_backup_remaining
    MODULE_ADD_FUNC sq_backup_pagecount,  sn_backup_pagecount
    MODULE_ADD_FUNC sq_sleep,             sn_sleep
    MODULE_ADD_FUNC sq_set_data_error_type, sn_set_data_err_type

    ; Probe optional libsqlite3 entry points via dlsym(RTLD_DEFAULT, name).
    xor edi, edi
    lea rsi, [rel sym_serialize]
    call dlsym wrt ..plt
    mov [rel sq_fn_serialize], rax

    xor edi, edi
    lea rsi, [rel sym_deserialize]
    call dlsym wrt ..plt
    mov [rel sq_fn_deserialize], rax

    xor edi, edi
    lea rsi, [rel sym_enable_load_ext]
    call dlsym wrt ..plt
    mov [rel sq_fn_enable_load_ext], rax

    xor edi, edi
    lea rsi, [rel sym_load_ext]
    call dlsym wrt ..plt
    mov [rel sq_fn_load_ext], rax

    xor edi, edi
    lea rsi, [rel sym_create_window]
    call dlsym wrt ..plt
    mov [rel sq_fn_create_window], rax

    ; Expose capability flags so lib/_sqlite3.py mirrors linked libsqlite3.
    mov rdi, r12
    lea rsi, [rel sn_has_serialize]
    mov rdx, [rel sq_fn_serialize]
    test rdx, rdx
    jz .set_ser
    mov rdx, [rel sq_fn_deserialize]
.set_ser:
    call sq_set_bool_attr

    mov rdi, r12
    lea rsi, [rel sn_has_load_ext]
    mov rdx, [rel sq_fn_enable_load_ext]
    test rdx, rdx
    jz .set_ext
    mov rdx, [rel sq_fn_load_ext]
.set_ext:
    call sq_set_bool_attr

    mov rdi, r12
    lea rsi, [rel sn_has_window]
    mov rdx, [rel sq_fn_create_window]
    call sq_set_bool_attr

    ; SQLITE_VERSION (str)
    lea rdi, [rel sn_version]
    call str_from_cstr_heap
    mov rbx, rax
    call sqlite3_libversion wrt ..plt
    mov rdi, rax
    call str_from_cstr_heap
    mov r13, rax
    mov rdi, r12
    mov rsi, rbx
    mov rdx, r13
    call dict_set_str
    mov rdi, rbx
    call obj_decref
    mov rdi, r13
    call obj_decref

    ; SQLITE_VERSION_NUMBER (int)
    lea rdi, [rel sn_version_num]
    call str_from_cstr_heap
    mov rbx, rax
    call sqlite3_libversion_number wrt ..plt
    movsxd rdx, eax
    V_PACK_I64 rdx, rcx
    mov rdi, r12
    mov rsi, rbx
    call dict_set_str
    mov rdi, rbx
    call obj_decref

    ; THREADSAFE (int)
    lea rdi, [rel sn_threadsafe]
    call str_from_cstr_heap
    mov rbx, rax
    call sqlite3_threadsafe wrt ..plt
    movsxd rdx, eax
    V_PACK_I64 rdx, rcx
    mov rdi, r12
    mov rsi, rbx
    call dict_set_str
    mov rdi, rbx
    call obj_decref

    ; Build the module object.
    lea rdi, [rel sq_modname]
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r12
    call module_new
    mov r13, rax
    mov rdi, rbx
    call obj_decref
    mov rdi, r12
    call obj_decref
    mov rax, r13

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sqlite3_module_create
