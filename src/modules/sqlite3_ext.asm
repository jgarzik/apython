; sqlite3_ext.asm - callbacks registration, blob, backup, and admin APIs
; for the _sqlite3core module (split from sqlite3.asm to keep files small).

%include "macros.inc"
%include "object.inc"
%include "gil.inc"
%include "sqlite3.inc"

ASM_INIT

extern sq_db_table
extern sq_blob_table
extern sq_bkup_table
extern sq_fn_serialize
extern sq_fn_deserialize
extern sq_fn_enable_load_ext
extern sq_fn_load_ext
extern sq_fn_create_window
extern sq_callback_tracebacks

extern sq_tbl_alloc
extern sq_tbl_get
extern sq_tbl_pop
extern sq_arg_int
extern sq_arg_cint
extern sq_arg_int64_strict
extern sq_arg_exact_bytes
extern sq_arg_bytes_like
extern sq_cb_free_if_set

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

extern str_from_cstr_heap
extern bytes_from_data
extern tuple_new
extern obj_decref
extern obj_dealloc
extern set_exception
extern ap_malloc
extern ap_free
extern ap_memcpy

extern none_singleton
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_MemoryError_type
extern exc_RuntimeError_type

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

section .rodata
sq_e_nargs:     db "_sqlite3core: wrong number of arguments", 0
sq_e_oom:       db "out of memory", 0

section .text

;; ============================================================================
;; sq_cb_alloc(rdi = callable, rsi = kind, rdx = db_h) -> rax = SqlCb*
;; Fails: 0
;; ============================================================================
SCA_FN      equ 8
SCA_KIND    equ 16
SCA_DBH     equ 24
SCA_FRAME   equ 32
DEF_FUNC_LOCAL sq_cb_alloc, SCA_FRAME
    mov [rbp - SCA_FN], rdi
    mov [rbp - SCA_KIND], rsi
    mov [rbp - SCA_DBH], rdx
    mov edi, SqlCb_size
    call ap_malloc
    test rax, rax
    jz .oom
    mov qword [rax + SqlCb.magic], SQ_CB_MAGIC
    mov rcx, [rbp - SCA_FN]
    INCREF_V rcx, rdx
    mov [rax + SqlCb.callable], rcx
    mov rcx, [rbp - SCA_KIND]
    mov [rax + SqlCb.kind], rcx
    mov rcx, [rbp - SCA_DBH]
    mov [rax + SqlCb.db_h], rcx
    leave
    ret
.oom:
    lea rdi, [rel exc_MemoryError_type]
    lea rsi, [rel sq_e_oom]
    call set_exception
    xor eax, eax
    leave
    ret
END_FUNC sq_cb_alloc

;; ============================================================================
;; sq_set_cb_tracebacks(rdi = args*, rsi = nargs) -> rax = None
;; _sqlite3core.set_callback_tracebacks(flag) -> None
;; ============================================================================
DEF_FUNC sq_set_cb_tracebacks
    NO_KEYWORDS_RET "_sqlite3core.set_callback_tracebacks() takes no keyword arguments", .fail
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    mov [rel sq_callback_tracebacks], rax
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
END_FUNC sq_set_cb_tracebacks

;; ============================================================================
;; sq_create_function(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.create_function(db_h, name_bytes, narg, flags, callable_or_None)
;; ============================================================================
SCF_ARGS    equ 8
SCF_DBH     equ 16
SCF_DB      equ 24
SCF_NAME    equ 32
SCF_NARG    equ 40
SCF_FLAGS   equ 48
SCF_FN      equ 56
SCF_CB      equ 64
SCF_FRAME   equ 64
DEF_FUNC sq_create_function, SCF_FRAME
    NO_KEYWORDS_RET "_sqlite3core.create_function() takes no keyword arguments", .fail
    cmp rsi, 5
    jne .nargs
    mov [rbp - SCF_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    mov [rbp - SCF_DBH], rax
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlDb.db]
    mov [rbp - SCF_DB], rcx

    mov rdi, [rbp - SCF_ARGS]
    mov rdi, [rdi + 8]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SCF_NAME], rax

    mov rdi, [rbp - SCF_ARGS]
    mov esi, 2
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SCF_NARG], rax

    mov rdi, [rbp - SCF_ARGS]
    mov esi, 3
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SCF_FLAGS], rax

    mov rax, [rbp - SCF_ARGS]
    mov rdi, [rax + 32]
    mov [rbp - SCF_FN], rdi
    lea rcx, [rel none_singleton]
    cmp rdi, rcx
    je .clear_fn

    mov esi, SQ_CB_FUNC
    mov rdx, [rbp - SCF_DBH]
    call sq_cb_alloc
    ERR_NULL .fail
    mov [rbp - SCF_CB], rax

    sub rsp, 32
    mov rdi, [rbp - SCF_DB]
    mov rsi, [rbp - SCF_NAME]
    mov edx, [rbp - SCF_NARG]
    mov ecx, [rbp - SCF_FLAGS]
    mov r8, [rbp - SCF_CB]
    lea r9, [rel sq_cb_func]
    mov qword [rsp], 0
    mov qword [rsp + 8], 0
    lea rax, [rel sq_cb_destroy]
    mov [rsp + 16], rax
    call sqlite3_create_function_v2 wrt ..plt
    add rsp, 32
    movsxd rax, eax
    V_PACK_I64 rax, rcx
    leave
    ret

.clear_fn:
    sub rsp, 32
    mov rdi, [rbp - SCF_DB]
    mov rsi, [rbp - SCF_NAME]
    mov edx, [rbp - SCF_NARG]
    mov ecx, [rbp - SCF_FLAGS]
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp], 0
    mov qword [rsp + 8], 0
    mov qword [rsp + 16], 0
    call sqlite3_create_function_v2 wrt ..plt
    add rsp, 32
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
END_FUNC sq_create_function

;; ============================================================================
;; sq_create_aggregate(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.create_aggregate(db_h, name_bytes, narg, cls_or_None)
;; ============================================================================
SCAG_ARGS   equ 8
SCAG_DBH    equ 16
SCAG_DB     equ 24
SCAG_NAME   equ 32
SCAG_NARG   equ 40
SCAG_CB     equ 48
SCAG_FRAME  equ 48
DEF_FUNC sq_create_aggregate, SCAG_FRAME
    NO_KEYWORDS_RET "_sqlite3core.create_aggregate() takes no keyword arguments", .fail
    cmp rsi, 4
    jne .nargs
    mov [rbp - SCAG_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    mov [rbp - SCAG_DBH], rax
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlDb.db]
    mov [rbp - SCAG_DB], rcx

    mov rdi, [rbp - SCAG_ARGS]
    mov rdi, [rdi + 8]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SCAG_NAME], rax

    mov rdi, [rbp - SCAG_ARGS]
    mov esi, 2
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SCAG_NARG], rax

    mov rax, [rbp - SCAG_ARGS]
    mov rdi, [rax + 24]
    lea rcx, [rel none_singleton]
    cmp rdi, rcx
    je .clear_agg

    mov esi, SQ_CB_AGGREGATE
    mov rdx, [rbp - SCAG_DBH]
    call sq_cb_alloc
    ERR_NULL .fail
    mov [rbp - SCAG_CB], rax

    sub rsp, 32
    mov rdi, [rbp - SCAG_DB]
    mov rsi, [rbp - SCAG_NAME]
    mov edx, [rbp - SCAG_NARG]
    mov ecx, SQLITE_UTF8
    mov r8, [rbp - SCAG_CB]
    xor r9d, r9d                ; xFunc = NULL
    lea rax, [rel sq_cb_step]
    mov [rsp], rax
    lea rax, [rel sq_cb_final]
    mov [rsp + 8], rax
    lea rax, [rel sq_cb_destroy]
    mov [rsp + 16], rax
    call sqlite3_create_function_v2 wrt ..plt
    add rsp, 32
    movsxd rax, eax
    V_PACK_I64 rax, rcx
    leave
    ret

.clear_agg:
    sub rsp, 32
    mov rdi, [rbp - SCAG_DB]
    mov rsi, [rbp - SCAG_NAME]
    mov edx, [rbp - SCAG_NARG]
    mov ecx, SQLITE_UTF8
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp], 0
    mov qword [rsp + 8], 0
    mov qword [rsp + 16], 0
    call sqlite3_create_function_v2 wrt ..plt
    add rsp, 32
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
END_FUNC sq_create_aggregate

;; ============================================================================
;; sq_create_window(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.create_window_function(db_h, name_bytes, narg, cls_or_None)
;; ============================================================================
SCW_ARGS    equ 8
SCW_DBH     equ 16
SCW_DB      equ 24
SCW_NAME    equ 32
SCW_NARG    equ 40
SCW_CB      equ 48
SCW_FRAME   equ 48
DEF_FUNC sq_create_window, SCW_FRAME
    NO_KEYWORDS_RET "_sqlite3core.create_window_function() takes no keyword arguments", .fail
    cmp rsi, 4
    jne .nargs
    cmp qword [rel sq_fn_create_window], 0
    je .unsupported
    mov [rbp - SCW_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    mov [rbp - SCW_DBH], rax
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlDb.db]
    mov [rbp - SCW_DB], rcx

    mov rdi, [rbp - SCW_ARGS]
    mov rdi, [rdi + 8]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SCW_NAME], rax

    mov rdi, [rbp - SCW_ARGS]
    mov esi, 2
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SCW_NARG], rax

    mov rax, [rbp - SCW_ARGS]
    mov rdi, [rax + 24]
    lea rcx, [rel none_singleton]
    cmp rdi, rcx
    je .clear_win

    mov esi, SQ_CB_WINDOW
    mov rdx, [rbp - SCW_DBH]
    call sq_cb_alloc
    ERR_NULL .fail
    mov [rbp - SCW_CB], rax

    sub rsp, 32
    mov rdi, [rbp - SCW_DB]
    mov rsi, [rbp - SCW_NAME]
    mov edx, [rbp - SCW_NARG]
    mov ecx, SQLITE_UTF8
    mov r8, [rbp - SCW_CB]
    lea r9, [rel sq_cb_step]
    lea rax, [rel sq_cb_final]
    mov [rsp], rax
    lea rax, [rel sq_cb_value]
    mov [rsp + 8], rax
    lea rax, [rel sq_cb_inverse]
    mov [rsp + 16], rax
    lea rax, [rel sq_cb_destroy]
    mov [rsp + 24], rax
    mov rax, [rel sq_fn_create_window]
    call rax
    add rsp, 32
    movsxd rax, eax
    V_PACK_I64 rax, rcx
    leave
    ret

.clear_win:
    sub rsp, 32
    mov rdi, [rbp - SCW_DB]
    mov rsi, [rbp - SCW_NAME]
    mov edx, [rbp - SCW_NARG]
    mov ecx, SQLITE_UTF8
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp], 0
    mov qword [rsp + 8], 0
    mov qword [rsp + 16], 0
    mov qword [rsp + 24], 0
    mov rax, [rel sq_fn_create_window]
    call rax
    add rsp, 32
    movsxd rax, eax
    V_PACK_I64 rax, rcx
    leave
    ret
.unsupported:
    FAIL exc_RuntimeError_type, "window functions not supported by libsqlite3", .fail
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_create_window

;; ============================================================================
;; sq_create_collation(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.create_collation(db_h, name_bytes, callable_or_None)
;; ============================================================================
SCC_ARGS    equ 8
SCC_DBH     equ 16
SCC_DB      equ 24
SCC_NAME    equ 32
SCC_CB      equ 40
SCC_FRAME   equ 48
DEF_FUNC sq_create_collation, SCC_FRAME
    NO_KEYWORDS_RET "_sqlite3core.create_collation() takes no keyword arguments", .fail
    cmp rsi, 3
    jne .nargs
    mov [rbp - SCC_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    mov [rbp - SCC_DBH], rax
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlDb.db]
    mov [rbp - SCC_DB], rcx

    mov rdi, [rbp - SCC_ARGS]
    mov rdi, [rdi + 8]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SCC_NAME], rax

    mov rax, [rbp - SCC_ARGS]
    mov rdi, [rax + 16]
    lea rcx, [rel none_singleton]
    cmp rdi, rcx
    je .clear_coll

    mov esi, SQ_CB_COLLATION
    mov rdx, [rbp - SCC_DBH]
    call sq_cb_alloc
    ERR_NULL .fail
    mov [rbp - SCC_CB], rax

    mov rdi, [rbp - SCC_DB]
    mov rsi, [rbp - SCC_NAME]
    mov edx, SQLITE_UTF8
    mov rcx, [rbp - SCC_CB]
    lea r8, [rel sq_cb_collation]
    lea r9, [rel sq_cb_destroy]
    call sqlite3_create_collation_v2 wrt ..plt
    movsxd rax, eax
    cmp rax, SQLITE_OK
    je .ret_rc
    ; sqlite3_create_collation_v2 does NOT invoke xDestroy on failure.
    push rax
    sub rsp, 8
    mov rdi, [rbp - SCC_CB]
    call sq_cb_free_if_set
    add rsp, 8
    pop rax
    jmp .ret_rc

.clear_coll:
    mov rdi, [rbp - SCC_DB]
    mov rsi, [rbp - SCC_NAME]
    mov edx, SQLITE_UTF8
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call sqlite3_create_collation_v2 wrt ..plt
    movsxd rax, eax
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
END_FUNC sq_create_collation

;; ============================================================================
;; sq_set_authorizer(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.set_authorizer(db_h, callable_or_None)
;; ============================================================================
SSA_ARGS    equ 8
SSA_DBH     equ 16
SSA_NODE    equ 24
SSA_CB      equ 32
SSA_RC      equ 40
SSA_FRAME   equ 48
DEF_FUNC sq_set_authorizer, SSA_FRAME
    NO_KEYWORDS_RET "_sqlite3core.set_authorizer() takes no keyword arguments", .fail
    cmp rsi, 2
    jne .nargs
    mov [rbp - SSA_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    mov [rbp - SSA_DBH], rax
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov [rbp - SSA_NODE], rax

    mov rax, [rbp - SSA_ARGS]
    mov rdi, [rax + 8]
    lea rcx, [rel none_singleton]
    cmp rdi, rcx
    je .clear_auth

    mov esi, SQ_CB_AUTHORIZER
    mov rdx, [rbp - SSA_DBH]
    call sq_cb_alloc
    ERR_NULL .fail
    mov [rbp - SSA_CB], rax

    mov rcx, [rbp - SSA_NODE]
    mov rdi, [rcx + SqlDb.db]
    lea rsi, [rel sq_cb_authorizer]
    mov rdx, rax
    call sqlite3_set_authorizer wrt ..plt
    movsxd rax, eax
    mov [rbp - SSA_RC], rax

    mov rcx, [rbp - SSA_NODE]
    mov rdi, [rcx + SqlDb.auth_cb]
    cmp qword [rbp - SSA_RC], SQLITE_OK
    jne .auth_err
    mov rdx, [rbp - SSA_CB]
    mov [rcx + SqlDb.auth_cb], rdx
    call sq_cb_free_if_set
    jmp .ret_rc

.auth_err:
    mov qword [rcx + SqlDb.auth_cb], 0
    call sq_cb_free_if_set
    mov rdi, [rbp - SSA_CB]
    call sq_cb_free_if_set
    jmp .ret_rc

.clear_auth:
    mov rcx, [rbp - SSA_NODE]
    mov rdi, [rcx + SqlDb.db]
    xor esi, esi
    xor edx, edx
    call sqlite3_set_authorizer wrt ..plt
    movsxd rax, eax
    mov [rbp - SSA_RC], rax
    mov rcx, [rbp - SSA_NODE]
    mov rdi, [rcx + SqlDb.auth_cb]
    mov qword [rcx + SqlDb.auth_cb], 0
    call sq_cb_free_if_set

.ret_rc:
    mov rax, [rbp - SSA_RC]
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
END_FUNC sq_set_authorizer

;; ============================================================================
;; sq_set_progress(rdi = args*, rsi = nargs) -> rax = None
;; _sqlite3core.set_progress_handler(db_h, callable_or_None, n)
;; ============================================================================
SSP_ARGS    equ 8
SSP_DBH     equ 16
SSP_NODE    equ 24
SSP_N       equ 32
SSP_CB      equ 40
SSP_FRAME   equ 48
DEF_FUNC sq_set_progress, SSP_FRAME
    NO_KEYWORDS_RET "_sqlite3core.set_progress_handler() takes no keyword arguments", .fail
    cmp rsi, 3
    jne .nargs
    mov [rbp - SSP_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    mov [rbp - SSP_DBH], rax
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov [rbp - SSP_NODE], rax

    mov rdi, [rbp - SSP_ARGS]
    mov esi, 2
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SSP_N], rax

    mov rax, [rbp - SSP_ARGS]
    mov rdi, [rax + 8]
    lea rcx, [rel none_singleton]
    cmp rdi, rcx
    je .clear_prog

    mov esi, SQ_CB_PROGRESS
    mov rdx, [rbp - SSP_DBH]
    call sq_cb_alloc
    ERR_NULL .fail
    mov [rbp - SSP_CB], rax

    mov rcx, [rbp - SSP_NODE]
    mov rdi, [rcx + SqlDb.db]
    mov esi, [rbp - SSP_N]
    lea rdx, [rel sq_cb_progress]
    mov rcx, rax
    call sqlite3_progress_handler wrt ..plt

    mov rcx, [rbp - SSP_NODE]
    mov rdi, [rcx + SqlDb.progress_cb]
    mov rdx, [rbp - SSP_CB]
    mov [rcx + SqlDb.progress_cb], rdx
    call sq_cb_free_if_set
    jmp .ret_none

.clear_prog:
    mov rcx, [rbp - SSP_NODE]
    mov rdi, [rcx + SqlDb.db]
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call sqlite3_progress_handler wrt ..plt
    mov rcx, [rbp - SSP_NODE]
    mov rdi, [rcx + SqlDb.progress_cb]
    mov qword [rcx + SqlDb.progress_cb], 0
    call sq_cb_free_if_set

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
END_FUNC sq_set_progress

;; ============================================================================
;; sq_set_trace(rdi = args*, rsi = nargs) -> rax = None
;; _sqlite3core.set_trace_callback(db_h, callable_or_None)
;; ============================================================================
SSTC_ARGS   equ 8
SSTC_DBH    equ 16
SSTC_NODE   equ 24
SSTC_CB     equ 32
SSTC_FRAME  equ 32
DEF_FUNC sq_set_trace, SSTC_FRAME
    NO_KEYWORDS_RET "_sqlite3core.set_trace_callback() takes no keyword arguments", .fail
    cmp rsi, 2
    jne .nargs
    mov [rbp - SSTC_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    mov [rbp - SSTC_DBH], rax
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov [rbp - SSTC_NODE], rax

    mov rax, [rbp - SSTC_ARGS]
    mov rdi, [rax + 8]
    lea rcx, [rel none_singleton]
    cmp rdi, rcx
    je .clear_trace

    mov esi, SQ_CB_TRACE
    mov rdx, [rbp - SSTC_DBH]
    call sq_cb_alloc
    ERR_NULL .fail
    mov [rbp - SSTC_CB], rax

    mov rcx, [rbp - SSTC_NODE]
    mov rdi, [rcx + SqlDb.db]
    mov esi, SQLITE_TRACE_STMT
    lea rdx, [rel sq_cb_trace]
    mov rcx, rax
    call sqlite3_trace_v2 wrt ..plt

    mov rcx, [rbp - SSTC_NODE]
    mov rdi, [rcx + SqlDb.trace_cb]
    mov rdx, [rbp - SSTC_CB]
    mov [rcx + SqlDb.trace_cb], rdx
    call sq_cb_free_if_set
    jmp .ret_none

.clear_trace:
    mov rcx, [rbp - SSTC_NODE]
    mov rdi, [rcx + SqlDb.db]
    mov esi, SQLITE_TRACE_STMT
    xor edx, edx
    xor ecx, ecx
    call sqlite3_trace_v2 wrt ..plt
    mov rcx, [rbp - SSTC_NODE]
    mov rdi, [rcx + SqlDb.trace_cb]
    mov qword [rcx + SqlDb.trace_cb], 0
    call sq_cb_free_if_set

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
END_FUNC sq_set_trace

;; ============================================================================
;; sq_limit(rdi = args*, rsi = nargs) -> rax = int prev_limit
;; _sqlite3core.limit(db_h, category, new_val) -> int
;; ============================================================================
SLM_ARGS    equ 8
SLM_CAT     equ 16
SLM_VAL     equ 24
SLM_FRAME   equ 32
DEF_FUNC sq_limit, SLM_FRAME
    NO_KEYWORDS_RET "_sqlite3core.limit() takes no keyword arguments", .fail
    cmp rsi, 3
    jne .nargs
    mov [rbp - SLM_ARGS], rdi
    mov esi, 1
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SLM_CAT], rax
    mov rdi, [rbp - SLM_ARGS]
    mov esi, 2
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SLM_VAL], rax
    mov rdi, [rbp - SLM_ARGS]
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rdi, [rax + SqlDb.db]
    mov esi, [rbp - SLM_CAT]
    mov edx, [rbp - SLM_VAL]
    call sqlite3_limit wrt ..plt
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
END_FUNC sq_limit

;; ============================================================================
;; sq_db_config(rdi = args*, rsi = nargs) -> rax = tuple(rc, actual)
;; _sqlite3core.db_config(db_h, op, val) -> (rc, actual)
;; ============================================================================
SDC_ARGS    equ 8
SDC_OP      equ 16
SDC_VAL     equ 24
SDC_ACT     equ 32
SDC_RC      equ 40
SDC_FRAME   equ 48
DEF_FUNC sq_db_config, SDC_FRAME
    NO_KEYWORDS_RET "_sqlite3core.db_config() takes no keyword arguments", .fail
    cmp rsi, 3
    jne .nargs
    mov [rbp - SDC_ARGS], rdi
    mov esi, 1
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SDC_OP], rax
    mov rdi, [rbp - SDC_ARGS]
    mov esi, 2
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SDC_VAL], rax
    mov rdi, [rbp - SDC_ARGS]
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov dword [rbp - SDC_ACT], 0
    mov rdi, [rax + SqlDb.db]
    mov esi, [rbp - SDC_OP]
    mov edx, [rbp - SDC_VAL]
    lea rcx, [rbp - SDC_ACT]
    xor eax, eax                ; variadic ABI: 0 vector args
    call sqlite3_db_config wrt ..plt
    movsxd rax, eax
    mov [rbp - SDC_RC], rax

    mov edi, 2
    call tuple_new
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbp - SDC_RC]
    V_PACK_I64 rdx, r8
    mov [rcx], rdx
    movsxd rdx, dword [rbp - SDC_ACT]
    V_PACK_I64 rdx, r8
    mov [rcx + 8], rdx
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
END_FUNC sq_db_config

;; ============================================================================
;; sq_serialize(rdi = args*, rsi = nargs) -> rax = bytes or None
;; _sqlite3core.serialize(db_h, name_bytes) -> bytes | None
;; ============================================================================
SSER_ARGS   equ 8
SSER_DB     equ 16
SSER_NAME   equ 24
SSER_SIZE   equ 32
SSER_DATA   equ 40
SSER_NOCOPY equ 48
SSER_FRAME  equ 48
DEF_FUNC sq_serialize, SSER_FRAME
    NO_KEYWORDS_RET "_sqlite3core.serialize() takes no keyword arguments", .fail
    cmp rsi, 2
    jne .nargs
    cmp qword [rel sq_fn_serialize], 0
    je .unsupported
    mov [rbp - SSER_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlDb.db]
    mov [rbp - SSER_DB], rcx

    mov rdi, [rbp - SSER_ARGS]
    mov rdi, [rdi + 8]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SSER_NAME], rax

    mov qword [rbp - SSER_SIZE], 0
    mov qword [rbp - SSER_NOCOPY], 1
    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - SSER_DB]
    mov rsi, [rbp - SSER_NAME]
    lea rdx, [rbp - SSER_SIZE]
    mov ecx, 1                  ; SQLITE_SERIALIZE_NOCOPY
    mov rax, [rel sq_fn_serialize]
    call rax
    test rax, rax
    jnz .ser_got
    mov qword [rbp - SSER_NOCOPY], 0
    mov rdi, [rbp - SSER_DB]
    mov rsi, [rbp - SSER_NAME]
    lea rdx, [rbp - SSER_SIZE]
    xor ecx, ecx
    mov rax, [rel sq_fn_serialize]
    call rax
.ser_got:
    ALLOW_THREADS_END
    mov [rbp - SSER_DATA], rax
    test rax, rax
    jz .ret_none

    mov rdi, rax
    mov rsi, [rbp - SSER_SIZE]
    call bytes_from_data
    push rax
    sub rsp, 8
    cmp qword [rbp - SSER_NOCOPY], 0
    jne .skip_free
    mov rdi, [rbp - SSER_DATA]
    call sqlite3_free wrt ..plt
.skip_free:
    add rsp, 8
    pop rax
    leave
    ret

.ret_none:
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.unsupported:
    FAIL exc_RuntimeError_type, "serialize not supported by libsqlite3", .fail
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_serialize

;; ============================================================================
;; sq_deserialize(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.deserialize(db_h, name_bytes, data_bytes_like) -> rc
;; ============================================================================
SDES_ARGS   equ 8
SDES_DB     equ 16
SDES_NAME   equ 24
SDES_SRC    equ 32
SDES_LEN    equ 40
SDES_BUF    equ 48
SDES_FRAME  equ 48
DEF_FUNC sq_deserialize, SDES_FRAME
    NO_KEYWORDS_RET "_sqlite3core.deserialize() takes no keyword arguments", .fail
    cmp rsi, 3
    jne .nargs
    cmp qword [rel sq_fn_deserialize], 0
    je .unsupported
    mov [rbp - SDES_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlDb.db]
    mov [rbp - SDES_DB], rcx

    mov rdi, [rbp - SDES_ARGS]
    mov rdi, [rdi + 8]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SDES_NAME], rax

    mov rdi, [rbp - SDES_ARGS]
    mov rdi, [rdi + 16]
    call sq_arg_bytes_like
    ERR_NULL .fail
    mov [rbp - SDES_SRC], rax
    mov [rbp - SDES_LEN], rdx

    mov rdi, rdx
    call sqlite3_malloc64 wrt ..plt
    test rax, rax
    jz .oom
    mov [rbp - SDES_BUF], rax

    mov rdi, rax
    mov rsi, [rbp - SDES_SRC]
    mov rdx, [rbp - SDES_LEN]
    call ap_memcpy

    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - SDES_DB]
    mov rsi, [rbp - SDES_NAME]
    mov rdx, [rbp - SDES_BUF]
    mov rcx, [rbp - SDES_LEN]
    mov r8, [rbp - SDES_LEN]
    mov r9d, SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE
    mov rax, [rel sq_fn_deserialize]
    call rax
    movsxd rax, eax
    ALLOW_THREADS_END

    V_PACK_I64 rax, rcx
    leave
    ret
.oom:
    lea rdi, [rel exc_MemoryError_type]
    lea rsi, [rel sq_e_oom]
    call set_exception
    jmp .fail
.unsupported:
    FAIL exc_RuntimeError_type, "deserialize not supported by libsqlite3", .fail
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_deserialize

;; ============================================================================
;; sq_enable_load_ext(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.enable_load_extension(db_h, onoff) -> rc
;; ============================================================================
SELE_ARGS   equ 8
SELE_ON     equ 16
SELE_FRAME  equ 16
DEF_FUNC sq_enable_load_ext, SELE_FRAME
    NO_KEYWORDS_RET "_sqlite3core.enable_load_extension() takes no keyword arguments", .fail
    cmp rsi, 2
    jne .nargs
    cmp qword [rel sq_fn_enable_load_ext], 0
    je .unsupported
    mov [rbp - SELE_ARGS], rdi
    mov esi, 1
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SELE_ON], rax
    mov rdi, [rbp - SELE_ARGS]
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rdi, [rax + SqlDb.db]
    mov esi, [rbp - SELE_ON]
    mov rax, [rel sq_fn_enable_load_ext]
    call rax
    movsxd rax, eax
    V_PACK_I64 rax, rcx
    leave
    ret
.unsupported:
    FAIL exc_RuntimeError_type, "load_extension not supported by libsqlite3", .fail
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_enable_load_ext

;; ============================================================================
;; sq_load_ext(rdi = args*, rsi = nargs) -> rax = tuple(rc, errmsg_or_None)
;; _sqlite3core.load_extension(db_h, path_bytes, entry_bytes_or_None)
;; ============================================================================
SLE_ARGS    equ 8
SLE_DB      equ 16
SLE_PATH    equ 24
SLE_ENTRY   equ 32
SLE_ERR     equ 40
SLE_RC      equ 48
SLE_MSG     equ 56
SLE_FRAME   equ 64
DEF_FUNC sq_load_ext, SLE_FRAME
    NO_KEYWORDS_RET "_sqlite3core.load_extension() takes no keyword arguments", .fail
    cmp rsi, 3
    jne .nargs
    cmp qword [rel sq_fn_load_ext], 0
    je .unsupported
    mov [rbp - SLE_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlDb.db]
    mov [rbp - SLE_DB], rcx

    mov rdi, [rbp - SLE_ARGS]
    mov rdi, [rdi + 8]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SLE_PATH], rax

    mov rax, [rbp - SLE_ARGS]
    mov rdi, [rax + 16]
    lea rcx, [rel none_singleton]
    cmp rdi, rcx
    je .no_entry
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SLE_ENTRY], rax
    jmp .do_load
.no_entry:
    mov qword [rbp - SLE_ENTRY], 0
.do_load:
    mov qword [rbp - SLE_ERR], 0
    mov rdi, [rbp - SLE_DB]
    mov rsi, [rbp - SLE_PATH]
    mov rdx, [rbp - SLE_ENTRY]
    lea rcx, [rbp - SLE_ERR]
    mov rax, [rel sq_fn_load_ext]
    call rax
    movsxd rax, eax
    mov [rbp - SLE_RC], rax

    mov rdi, [rbp - SLE_ERR]
    test rdi, rdi
    jz .err_none
    call str_from_cstr_heap
    mov [rbp - SLE_MSG], rax
    mov rdi, [rbp - SLE_ERR]
    call sqlite3_free wrt ..plt
    jmp .build_tup
.err_none:
    lea rax, [rel none_singleton]
    INCREF rax
    mov [rbp - SLE_MSG], rax
.build_tup:
    mov edi, 2
    call tuple_new
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbp - SLE_RC]
    V_PACK_I64 rdx, r8
    mov [rcx], rdx
    mov rdx, [rbp - SLE_MSG]
    mov [rcx + 8], rdx
    leave
    ret
.unsupported:
    FAIL exc_RuntimeError_type, "load_extension not supported by libsqlite3", .fail
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sq_e_nargs]
    call set_exception
.fail:
    xor eax, eax
    leave
    ret
END_FUNC sq_load_ext

;; ============================================================================
;; sq_blob_open(rdi = args*, rsi = nargs) -> rax = tuple(rc, blob_h)
;; _sqlite3core.blob_open(db_h, db_name, table, column, rowid, flags)
;; ============================================================================
SBO_ARGS    equ 8
SBO_DBH     equ 16
SBO_DB      equ 24
SBO_DBN     equ 32
SBO_TBL     equ 40
SBO_COL     equ 48
SBO_ROWID   equ 56
SBO_FLAGS   equ 64
SBO_BLOB    equ 72
SBO_RC      equ 80
SBO_BH      equ 88
SBO_FRAME   equ 96
DEF_FUNC sq_blob_open, SBO_FRAME
    NO_KEYWORDS_RET "_sqlite3core.blob_open() takes no keyword arguments", .fail
    cmp rsi, 6
    jne .nargs
    mov [rbp - SBO_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    mov [rbp - SBO_DBH], rax
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlDb.db]
    mov [rbp - SBO_DB], rcx

    mov rdi, [rbp - SBO_ARGS]
    mov rdi, [rdi + 8]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SBO_DBN], rax

    mov rdi, [rbp - SBO_ARGS]
    mov rdi, [rdi + 16]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SBO_TBL], rax

    mov rdi, [rbp - SBO_ARGS]
    mov rdi, [rdi + 24]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SBO_COL], rax

    mov rdi, [rbp - SBO_ARGS]
    mov rdi, [rdi + 32]
    call sq_arg_int64_strict
    ERR_M1 .fail
    mov [rbp - SBO_ROWID], rax

    mov rdi, [rbp - SBO_ARGS]
    mov esi, 5
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SBO_FLAGS], rax

    mov qword [rbp - SBO_BLOB], 0
    ALLOW_THREADS_BEGIN
    sub rsp, 16
    mov rdi, [rbp - SBO_DB]
    mov rsi, [rbp - SBO_DBN]
    mov rdx, [rbp - SBO_TBL]
    mov rcx, [rbp - SBO_COL]
    mov r8, [rbp - SBO_ROWID]
    mov r9d, [rbp - SBO_FLAGS]
    lea rax, [rbp - SBO_BLOB]
    mov [rsp], rax
    call sqlite3_blob_open wrt ..plt
    add rsp, 16
    movsxd rax, eax
    ALLOW_THREADS_END
    mov [rbp - SBO_RC], rax

    mov qword [rbp - SBO_BH], 0
    cmp rax, SQLITE_OK
    jne .make_tup
    cmp qword [rbp - SBO_BLOB], 0
    je .make_tup

    mov edi, SqlBlob_size
    call ap_malloc
    test rax, rax
    jz .oom_blob
    mov qword [rax + SqlBlob.magic], SQ_BLOB_MAGIC
    mov rcx, [rbp - SBO_BLOB]
    mov [rax + SqlBlob.blob], rcx
    mov rcx, [rbp - SBO_DBH]
    mov [rax + SqlBlob.db_h], rcx
    mov rsi, rax
    lea rdi, [rel sq_blob_table]
    push rsi
    sub rsp, 8
    call sq_tbl_alloc
    add rsp, 8
    pop rsi
    ERR_M1 .oom_free_node
    mov [rbp - SBO_BH], rax

.make_tup:
    mov edi, 2
    call tuple_new
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbp - SBO_RC]
    V_PACK_I64 rdx, r8
    mov [rcx], rdx
    mov rdx, [rbp - SBO_BH]
    V_PACK_I64 rdx, r8
    mov [rcx + 8], rdx
    leave
    ret
.oom_free_node:
    mov rdi, rsi
    call ap_free
    mov rdi, [rbp - SBO_BLOB]
    call sqlite3_blob_close wrt ..plt
    jmp .fail
.oom_blob:
    mov rdi, [rbp - SBO_BLOB]
    call sqlite3_blob_close wrt ..plt
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
END_FUNC sq_blob_open

;; ============================================================================
;; sq_blob_close(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.blob_close(blob_h) -> rc
;; ============================================================================
SBC_NODE    equ 8
SBC_BLOB    equ 16
SBC_RC      equ 24
SBC_FRAME   equ 32
DEF_FUNC sq_blob_close, SBC_FRAME
    NO_KEYWORDS_RET "_sqlite3core.blob_close() takes no keyword arguments", .fail
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_blob_table]
    mov rsi, rax
    mov rdx, SQ_BLOB_MAGIC
    call sq_tbl_pop
    ERR_NULL .fail
    mov [rbp - SBC_NODE], rax
    mov rcx, [rax + SqlBlob.blob]
    mov [rbp - SBC_BLOB], rcx
    mov qword [rax + SqlBlob.magic], 0

    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - SBC_BLOB]
    call sqlite3_blob_close wrt ..plt
    movsxd rax, eax
    ALLOW_THREADS_END
    mov [rbp - SBC_RC], rax

    mov rdi, [rbp - SBC_NODE]
    call ap_free

    mov rax, [rbp - SBC_RC]
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
END_FUNC sq_blob_close

;; ============================================================================
;; sq_blob_bytes(rdi = args*, rsi = nargs) -> rax = int len
;; _sqlite3core.blob_bytes(blob_h) -> int
;; ============================================================================
DEF_FUNC sq_blob_bytes
    NO_KEYWORDS_RET "_sqlite3core.blob_bytes() takes no keyword arguments", .fail
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_blob_table]
    mov rsi, rax
    mov rdx, SQ_BLOB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rdi, [rax + SqlBlob.blob]
    call sqlite3_blob_bytes wrt ..plt
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
END_FUNC sq_blob_bytes

;; ============================================================================
;; sq_blob_read(rdi = args*, rsi = nargs) -> rax = tuple(rc, bytes_or_None)
;; _sqlite3core.blob_read(blob_h, length, offset) -> (rc, bytes | None)
;; ============================================================================
SBR_ARGS    equ 8
SBR_BLOB    equ 16
SBR_LEN     equ 24
SBR_OFF     equ 32
SBR_BUF     equ 40
SBR_RC      equ 48
SBR_OBJ     equ 56
SBR_FRAME   equ 64
DEF_FUNC sq_blob_read, SBR_FRAME
    NO_KEYWORDS_RET "_sqlite3core.blob_read() takes no keyword arguments", .fail
    cmp rsi, 3
    jne .nargs
    mov [rbp - SBR_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_blob_table]
    mov rsi, rax
    mov rdx, SQ_BLOB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlBlob.blob]
    mov [rbp - SBR_BLOB], rcx

    mov rdi, [rbp - SBR_ARGS]
    mov esi, 1
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SBR_LEN], rax
    test rax, rax
    js .bad_len

    mov rdi, [rbp - SBR_ARGS]
    mov esi, 2
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SBR_OFF], rax

    mov rdi, [rbp - SBR_LEN]
    test rdi, rdi
    jnz .alloc_buf
    mov edi, 1
.alloc_buf:
    call ap_malloc
    test rax, rax
    jz .oom
    mov [rbp - SBR_BUF], rax

    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - SBR_BLOB]
    mov rsi, [rbp - SBR_BUF]
    mov edx, [rbp - SBR_LEN]
    mov ecx, [rbp - SBR_OFF]
    call sqlite3_blob_read wrt ..plt
    movsxd rax, eax
    ALLOW_THREADS_END
    mov [rbp - SBR_RC], rax

    cmp rax, SQLITE_OK
    jne .read_err

    mov rdi, [rbp - SBR_BUF]
    mov rsi, [rbp - SBR_LEN]
    call bytes_from_data
    mov [rbp - SBR_OBJ], rax
    mov rdi, [rbp - SBR_BUF]
    call ap_free
    jmp .build_tup

.read_err:
    mov rdi, [rbp - SBR_BUF]
    call ap_free
    lea rax, [rel none_singleton]
    INCREF rax
    mov [rbp - SBR_OBJ], rax

.build_tup:
    mov edi, 2
    call tuple_new
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbp - SBR_RC]
    V_PACK_I64 rdx, r8
    mov [rcx], rdx
    mov rdx, [rbp - SBR_OBJ]
    mov [rcx + 8], rdx
    leave
    ret
.bad_len:
    FAIL exc_ValueError_type, "length must be non-negative", .fail
.oom:
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
END_FUNC sq_blob_read

;; ============================================================================
;; sq_blob_write(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.blob_write(blob_h, data_bytes_like, offset) -> rc
;; ============================================================================
SBW_ARGS    equ 8
SBW_BLOB    equ 16
SBW_SRC     equ 24
SBW_LEN     equ 32
SBW_OFF     equ 40
SBW_COPY    equ 48
SBW_FRAME   equ 48
DEF_FUNC sq_blob_write, SBW_FRAME
    NO_KEYWORDS_RET "_sqlite3core.blob_write() takes no keyword arguments", .fail
    cmp rsi, 3
    jne .nargs
    mov [rbp - SBW_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_blob_table]
    mov rsi, rax
    mov rdx, SQ_BLOB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlBlob.blob]
    mov [rbp - SBW_BLOB], rcx

    mov rdi, [rbp - SBW_ARGS]
    mov rdi, [rdi + 8]
    call sq_arg_bytes_like
    ERR_NULL .fail
    mov [rbp - SBW_SRC], rax
    mov [rbp - SBW_LEN], rdx

    mov rdi, [rbp - SBW_ARGS]
    mov esi, 2
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SBW_OFF], rax

    ; Copy mutable buffer before releasing GIL so another thread cannot resize it.
    mov rdi, [rbp - SBW_LEN]
    test rdi, rdi
    jnz .alloc_copy
    mov edi, 1
.alloc_copy:
    call ap_malloc
    test rax, rax
    jz .oom
    mov [rbp - SBW_COPY], rax
    mov rdi, rax
    mov rsi, [rbp - SBW_SRC]
    mov rdx, [rbp - SBW_LEN]
    call ap_memcpy

    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - SBW_BLOB]
    mov rsi, [rbp - SBW_COPY]
    mov edx, [rbp - SBW_LEN]
    mov ecx, [rbp - SBW_OFF]
    call sqlite3_blob_write wrt ..plt
    movsxd rax, eax
    ALLOW_THREADS_END

    push rax
    sub rsp, 8
    mov rdi, [rbp - SBW_COPY]
    call ap_free
    add rsp, 8
    pop rax
    V_PACK_I64 rax, rcx
    leave
    ret
.oom:
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
END_FUNC sq_blob_write

;; ============================================================================
;; sq_backup_init(rdi = args*, rsi = nargs) -> rax = int bkup_h (0 if failed)
;; _sqlite3core.backup_init(dst_h, dst_name, src_h, src_name) -> bkup_h
;; ============================================================================
SBI2_ARGS   equ 8
SBI2_DST    equ 16
SBI2_DN     equ 24
SBI2_SRC    equ 32
SBI2_SN     equ 40
SBI2_BK     equ 48
SBI2_FRAME  equ 48
DEF_FUNC sq_backup_init, SBI2_FRAME
    NO_KEYWORDS_RET "_sqlite3core.backup_init() takes no keyword arguments", .fail
    cmp rsi, 4
    jne .nargs
    mov [rbp - SBI2_ARGS], rdi
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlDb.db]
    mov [rbp - SBI2_DST], rcx

    mov rdi, [rbp - SBI2_ARGS]
    mov rdi, [rdi + 8]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SBI2_DN], rax

    mov rdi, [rbp - SBI2_ARGS]
    mov esi, 2
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_db_table]
    mov rsi, rax
    mov rdx, SQ_DB_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlDb.db]
    mov [rbp - SBI2_SRC], rcx

    mov rdi, [rbp - SBI2_ARGS]
    mov rdi, [rdi + 24]
    call sq_arg_exact_bytes
    ERR_NULL .fail
    mov [rbp - SBI2_SN], rax

    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - SBI2_DST]
    mov rsi, [rbp - SBI2_DN]
    mov rdx, [rbp - SBI2_SRC]
    mov rcx, [rbp - SBI2_SN]
    call sqlite3_backup_init wrt ..plt
    ALLOW_THREADS_END
    mov [rbp - SBI2_BK], rax
    test rax, rax
    jz .ret_zero

    mov edi, SqlBackup_size
    call ap_malloc
    test rax, rax
    jz .oom_bk
    mov qword [rax + SqlBackup.magic], SQ_BKUP_MAGIC
    mov rcx, [rbp - SBI2_BK]
    mov [rax + SqlBackup.bkup], rcx
    mov rsi, rax
    lea rdi, [rel sq_bkup_table]
    push rsi
    sub rsp, 8
    call sq_tbl_alloc
    add rsp, 8
    pop rsi
    ERR_M1 .oom_free
    V_PACK_I64 rax, rcx
    leave
    ret

.ret_zero:
    mov rax, V_INT(0)
    leave
    ret
.oom_free:
    mov rdi, rsi
    call ap_free
    mov rdi, [rbp - SBI2_BK]
    call sqlite3_backup_finish wrt ..plt
    jmp .fail
.oom_bk:
    mov rdi, [rbp - SBI2_BK]
    call sqlite3_backup_finish wrt ..plt
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
END_FUNC sq_backup_init

;; ============================================================================
;; sq_backup_step(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.backup_step(bkup_h, pages) -> rc
;; ============================================================================
SBS_ARGS    equ 8
SBS_PAGES   equ 16
SBS_BK      equ 24
SBS_FRAME   equ 32
DEF_FUNC sq_backup_step, SBS_FRAME
    NO_KEYWORDS_RET "_sqlite3core.backup_step() takes no keyword arguments", .fail
    cmp rsi, 2
    jne .nargs
    mov [rbp - SBS_ARGS], rdi
    mov esi, 1
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SBS_PAGES], rax
    mov rdi, [rbp - SBS_ARGS]
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_bkup_table]
    mov rsi, rax
    mov rdx, SQ_BKUP_MAGIC
    call sq_tbl_get
    ERR_NULL .fail
    mov rcx, [rax + SqlBackup.bkup]
    mov [rbp - SBS_BK], rcx

    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - SBS_BK]
    mov esi, [rbp - SBS_PAGES]
    call sqlite3_backup_step wrt ..plt
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
END_FUNC sq_backup_step

;; ============================================================================
;; sq_backup_finish(rdi = args*, rsi = nargs) -> rax = int rc
;; _sqlite3core.backup_finish(bkup_h) -> rc
;; ============================================================================
SBF2_NODE   equ 8
SBF2_BK     equ 16
SBF2_RC     equ 24
SBF2_FRAME  equ 32
DEF_FUNC sq_backup_finish, SBF2_FRAME
    NO_KEYWORDS_RET "_sqlite3core.backup_finish() takes no keyword arguments", .fail
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call sq_arg_int
    ERR_M1 .fail
    lea rdi, [rel sq_bkup_table]
    mov rsi, rax
    mov rdx, SQ_BKUP_MAGIC
    call sq_tbl_pop
    ERR_NULL .fail
    mov [rbp - SBF2_NODE], rax
    mov rcx, [rax + SqlBackup.bkup]
    mov [rbp - SBF2_BK], rcx
    mov qword [rax + SqlBackup.magic], 0

    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - SBF2_BK]
    call sqlite3_backup_finish wrt ..plt
    movsxd rax, eax
    ALLOW_THREADS_END
    mov [rbp - SBF2_RC], rax

    mov rdi, [rbp - SBF2_NODE]
    call ap_free

    mov rax, [rbp - SBF2_RC]
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
END_FUNC sq_backup_finish

;; Macro for 1-arg backup integer getters:
%macro SQ_BKUP_INT_GETTER 2
;; %1(rdi = args*, rsi = nargs) -> rax = int Value
DEF_FUNC %1
    NO_KEYWORDS_RET "_sqlite3core function takes no keyword arguments", %%fail
    cmp rsi, 1
    jne %%nargs
    xor esi, esi
    call sq_arg_int
    ERR_M1 %%fail
    lea rdi, [rel sq_bkup_table]
    mov rsi, rax
    mov rdx, SQ_BKUP_MAGIC
    call sq_tbl_get
    ERR_NULL %%fail
    mov rdi, [rax + SqlBackup.bkup]
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

SQ_BKUP_INT_GETTER sq_backup_remaining, sqlite3_backup_remaining
SQ_BKUP_INT_GETTER sq_backup_pagecount, sqlite3_backup_pagecount

;; ============================================================================
;; sq_sleep(rdi = args*, rsi = nargs) -> rax = int ms_slept
;; _sqlite3core.sleep(ms) -> int
;; ============================================================================
SSL_MS      equ 8
SSL_FRAME   equ 16
DEF_FUNC sq_sleep, SSL_FRAME
    NO_KEYWORDS_RET "_sqlite3core.sleep() takes no keyword arguments", .fail
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call sq_arg_cint
    ERR_M1 .fail
    mov [rbp - SSL_MS], rax
    ALLOW_THREADS_BEGIN
    mov edi, [rbp - SSL_MS]
    call sqlite3_sleep wrt ..plt
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
END_FUNC sq_sleep

