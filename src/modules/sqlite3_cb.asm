; sqlite3_cb.asm - the C-to-Python callback side of the _sqlite3core shim.
;
; Everything here is called BY LIBSQLITE3 during sqlite3_step /
; sqlite3_prepare_v2 / sqlite3_close / sqlite3_create_*.  Because blocking
; libsqlite3 calls in sqlite3.asm release the GIL, every entry point here
; checks whether THIS thread already holds the GIL (`[rel gil_holder] ==
; [gs:ThreadState.ts_self]`): if not, it calls `gil_acquire` on entry and
; `gil_release` on exit.  This is safe even when callbacks re-enter SQLite or
; when `xDestroy` fires during a GIL-held registration call.
;
;   **NEVER `RAISE` FROM THIS FILE.**
;
; Raising would longjmp through libsqlite3's frames and corrupt its state.
; All exceptions are caught and converted into sqlite3_result_error* or hook
; return codes, optionally reported via traceback_print_unraisable when
; sq_callback_tracebacks is non-zero.

%include "macros.inc"
%include "object.inc"
%include "gil.inc"
%include "sqlite3.inc"

ASM_INIT

extern gil_holder
extern gil_acquire
extern gil_release
extern sq_callback_tracebacks
extern sq_data_error_type
extern sq_cb_free_if_set
extern sq_arg_int64_strict
extern sq_arg_bytes_like

extern exc_fetch
extern exc_restore
extern exc_isinstance
extern traceback_print_unraisable
extern set_exception
extern obj_call_n
extern obj_getattr_raw
extern obj_getattr_opt
extern obj_is_true
extern obj_decref
extern obj_dealloc
extern obj_incref
extern str_from_cstr_heap
extern str_new_heap
extern bytes_from_data
extern bytes_utf8_check
extern ap_malloc
extern ap_free

extern none_singleton
extern bool_true
extern bool_type
extern int_type
extern float_type
extern str_type
extern bytes_type
extern bytearray_type
extern memoryview_type
extern exc_MemoryError_type
extern exc_OverflowError_type
extern exc_AttributeError_type
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_RuntimeError_type
extern exc_BufferError_type
extern exc_UnicodeEncodeError_type

; libsqlite3 callback-side functions.
extern sqlite3_user_data
extern sqlite3_context_db_handle
extern sqlite3_aggregate_context
extern sqlite3_value_type
extern sqlite3_value_int64
extern sqlite3_value_double
extern sqlite3_value_text
extern sqlite3_value_blob
extern sqlite3_value_bytes
extern sqlite3_result_null
extern sqlite3_result_int64
extern sqlite3_result_double
extern sqlite3_result_text
extern sqlite3_result_blob
extern sqlite3_result_error
extern sqlite3_result_error_nomem
extern sqlite3_result_error_toobig
extern sqlite3_expanded_sql
extern sqlite3_db_handle
extern sqlite3_errcode
extern sqlite3_free

section .rodata
cb_empty_byte:          db 0
cb_s_step:              db "step", 0
cb_s_finalize:          db "finalize", 0
cb_s_value:             db "value", 0
cb_s_inverse:           db "inverse", 0
cb_s_call:              db "__call__", 0

cb_e_func:              db "user-defined function raised exception", 0
cb_e_agg_oom:           db "unable to allocate SQLite aggregate context", 0
cb_e_agg_init:          db "user-defined aggregate's '__init__' method raised error", 0
cb_e_agg_nostep:        db "user-defined aggregate's 'step' method not defined", 0
cb_e_agg_step:          db "user-defined aggregate's 'step' method raised error", 0
cb_e_agg_nofinal:       db "user-defined aggregate's 'finalize' method not defined", 0
cb_e_agg_final:         db "user-defined aggregate's 'finalize' method raised error", 0
cb_e_win_noval:         db "user-defined aggregate's 'value' method not defined", 0
cb_e_win_val:           db "user-defined aggregate's 'value' method raised error", 0
cb_e_win_valres:        db "unable to set result from user-defined aggregate's 'value' method", 0
cb_e_win_noinv:         db "user-defined aggregate's 'inverse' method not defined", 0
cb_e_win_invargs:       db "unable to build arguments for user-defined aggregate's 'inverse' method", 0
cb_e_win_inv:           db "user-defined aggregate's 'inverse' method raised error", 0
cb_e_ret_type:          db "User-defined functions cannot return unsupported type", 0
cb_e_str_big:           db "string is longer than INT_MAX bytes", 0
cb_e_blob_big:          db "BLOB longer than INT_MAX bytes", 0
cb_e_utf8:              db "Could not decode to UTF-8", 0
cb_e_trace_big:         db "Expanded SQL string exceeds the maximum string length", 0
cb_e_oom:               db "out of memory", 0

section .text

;; ============================================================================
;; sq_cb_gil_enter() -> rax = 1 if this call acquired the GIL, 0 if held
;; ============================================================================
DEF_FUNC sq_cb_gil_enter
    mov rax, [gs:ThreadState.ts_self]
    cmp rax, [rel gil_holder]
    je .already_held
    call gil_acquire
    mov eax, 1
    leave
    ret
.already_held:
    xor eax, eax
    leave
    ret
END_FUNC sq_cb_gil_enter

;; ============================================================================
;; sq_cb_gil_leave(rdi = acquired_flag) -> nothing
;; ============================================================================
DEF_FUNC sq_cb_gil_leave
    test rdi, rdi
    jz .done
    call gil_release
.done:
    leave
    ret
END_FUNC sq_cb_gil_leave

;; ============================================================================
;; sq_cb_print_or_clear_pending(rdi = obj_or_0) -> nothing
;;
;; Clears current_exception, printing it via traceback_print_unraisable first
;; if sq_callback_tracebacks is enabled.
;; ============================================================================
POC_OBJ     equ 8
POC_EXC     equ 16
POC_FRAME   equ 16
DEF_FUNC sq_cb_print_or_clear_pending, POC_FRAME
    mov [rbp - POC_OBJ], rdi
    call exc_fetch
    test rax, rax
    jz .done
    mov [rbp - POC_EXC], rax
    cmp qword [rel sq_callback_tracebacks], 0
    je .drop
    mov rdi, rax
    mov rsi, [rbp - POC_OBJ]
    call traceback_print_unraisable
.drop:
    mov rdi, [rbp - POC_EXC]
    DECREF_V rdi, rcx
.done:
    leave
    ret
END_FUNC sq_cb_print_or_clear_pending

;; ============================================================================
;; sq_cb_set_sqlite_error(rdi = sqlite3_context*, rsi = default_msg) -> nothing
;;
;; Maps pending Python exception to sqlite3_result_error{,_nomem,_toobig} and
;; prints/clears the Python exception.
;; ============================================================================
SSE_CTX     equ 8
SSE_MSG     equ 16
SSE_FRAME   equ 16
DEF_FUNC_LOCAL sq_cb_set_sqlite_error, SSE_FRAME
    mov [rbp - SSE_CTX], rdi
    mov [rbp - SSE_MSG], rsi

    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jz .use_default

    mov rdi, rax
    lea rsi, [rel exc_MemoryError_type]
    call exc_isinstance         ; err: static exception type never fails
    cmp eax, 1
    je .is_nomem

    mov rdi, [gs:ThreadState.current_exception]
    lea rsi, [rel exc_OverflowError_type]
    call exc_isinstance         ; err: static exception type never fails
    cmp eax, 1
    je .is_toobig

.use_default:
    mov rdi, [rbp - SSE_CTX]
    mov rsi, [rbp - SSE_MSG]
    mov edx, -1
    call sqlite3_result_error wrt ..plt
    jmp .clear_exc

.is_nomem:
    mov rdi, [rbp - SSE_CTX]
    call sqlite3_result_error_nomem wrt ..plt
    jmp .clear_exc

.is_toobig:
    mov rdi, [rbp - SSE_CTX]
    call sqlite3_result_error_toobig wrt ..plt

.clear_exc:
    mov rdi, [rbp - SSE_CTX]
    call sqlite3_user_data wrt ..plt
    xor edi, edi
    test rax, rax
    jz .do_clear
    mov rdi, [rax + SqlCb.callable]
.do_clear:
    call sq_cb_print_or_clear_pending
    leave
    ret
END_FUNC sq_cb_set_sqlite_error

;; ============================================================================
;; sq_cb_call_args(rdi = callable, rsi = args*, rdx = nargs) -> rax = Value
;; Fails: 0
;;
;; Calls any Python callable with an arbitrary number of positional arguments
;; (unlike obj_call_n's 8-arg limit for __call__ instances).
;; ============================================================================
CCA_FN      equ 8
CCA_ARGS    equ 16
CCA_NARGS   equ 24
CCA_METH    equ 32
CCA_FRAME   equ 32
DEF_FUNC_LOCAL sq_cb_call_args, CCA_FRAME
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov [rbp - CCA_FN], rdi
    mov [rbp - CCA_ARGS], rsi
    mov [rbp - CCA_NARGS], rdx

    V_TEST_PTR rdi, rcx
    ja .use_ocn
    mov rax, [rdi + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_call]
    test rcx, rcx
    jz .check_nargs
    call rcx
    leave
    ret

.check_nargs:
    cmp rdx, 8
    jbe .use_ocn
    ; Instance with __call__ and > 8 args: look up bound __call__ method.
    lea rdi, [rel cb_s_call]
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    mov rdi, [rbp - CCA_FN]
    mov rsi, rax
    call obj_getattr_opt
    mov [rbp - CCA_METH], rax
    add rsp, 8
    pop rdi
    call obj_decref
    mov rdi, [rbp - CCA_METH]
    test rdi, rdi
    jz .not_callable
    mov rsi, [rbp - CCA_ARGS]
    mov rdx, [rbp - CCA_NARGS]
    V_TEST_PTR rdi, rcx
    ja .drop_meth_nc
    mov rax, [rdi + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_call]
    test rcx, rcx
    jz .drop_meth_nc
    call rcx
    push rax
    sub rsp, 8
    mov rdi, [rbp - CCA_METH]
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    leave
    ret
.drop_meth_nc:
    mov rdi, [rbp - CCA_METH]
    DECREF_V rdi, rcx
.not_callable:
    SET_EXC exc_TypeError_type, "object is not callable"
    xor eax, eax
    leave
    ret

.use_ocn:
    mov rdi, [rbp - CCA_FN]
    mov rsi, [rbp - CCA_ARGS]
    mov rdx, [rbp - CCA_NARGS]
    call obj_call_n             ; err: caller checks 0 return
    leave
    ret
END_FUNC sq_cb_call_args

;; ============================================================================
;; sq_cb_build_args(rdi = sqlite3_context*, esi = argc, rdx = sqlite3_value**,
;;                  rcx = Value* out_buf) -> eax = 0 ok / -1 fail
;; Fails: -1
;;
;; Converts sqlite3_value* arguments into owned Python Values in out_buf.
;; On error, releases any already-built Values and leaves exception pending.
;; ============================================================================
CBA_CTX     equ 8
CBA_ARGC    equ 16
CBA_ARGV    equ 24
CBA_OUT     equ 32
CBA_PTR     equ 40
CBA_LEN     equ 48
CBA_FRAME   equ 56              ; + 3 pushes (rbx, r12, r13) = 80, 16-aligned
DEF_FUNC_LOCAL sq_cb_build_args, CBA_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - CBA_CTX], rdi
    movsxd r12, esi
    mov [rbp - CBA_ARGC], r12
    mov [rbp - CBA_ARGV], rdx
    mov r13, rcx
    mov [rbp - CBA_OUT], r13

    xor ebx, ebx
.loop:
    cmp rbx, r12
    jge .ok

    mov rax, [rbp - CBA_ARGV]
    mov rdi, [rax + rbx*8]
    call sqlite3_value_type wrt ..plt
    cmp eax, SQLITE_INTEGER
    je .val_int
    cmp eax, SQLITE_FLOAT
    je .val_float
    cmp eax, SQLITE_TEXT
    je .val_text
    cmp eax, SQLITE_BLOB
    je .val_blob
    ; SQLITE_NULL (or unknown)
    lea rax, [rel none_singleton]
    INCREF rax
    jmp .store

.val_int:
    mov rax, [rbp - CBA_ARGV]
    mov rdi, [rax + rbx*8]
    call sqlite3_value_int64 wrt ..plt
    V_PACK_I64 rax, rcx
    jmp .store

.val_float:
    mov rax, [rbp - CBA_ARGV]
    mov rdi, [rax + rbx*8]
    call sqlite3_value_double wrt ..plt
    movq rax, xmm0
    V_FROM_F64 rax, rcx
    jmp .store

.val_text:
    mov rax, [rbp - CBA_ARGV]
    mov rdi, [rax + rbx*8]
    call sqlite3_value_text wrt ..plt
    mov [rbp - CBA_PTR], rax
    test rax, rax
    jnz .text_len
    ; Check OOM on sqlite3_value_text returning NULL.
    mov rdi, [rbp - CBA_CTX]
    call sqlite3_context_db_handle wrt ..plt
    mov rdi, rax
    call sqlite3_errcode wrt ..plt
    cmp eax, SQLITE_NOMEM
    je .oom
    lea rax, [rel cb_empty_byte]
    mov [rbp - CBA_PTR], rax
    xor esi, esi
    jmp .text_make
.text_len:
    mov rax, [rbp - CBA_ARGV]
    mov rdi, [rax + rbx*8]
    call sqlite3_value_bytes wrt ..plt
    movsxd rsi, eax
.text_make:
    mov [rbp - CBA_LEN], rsi
    mov rdi, [rbp - CBA_PTR]
    call bytes_utf8_check
    cmp rax, -1
    jne .bad_utf8
    mov rdi, [rbp - CBA_PTR]
    mov rsi, [rbp - CBA_LEN]
    call str_new_heap
    jmp .store

.val_blob:
    mov rax, [rbp - CBA_ARGV]
    mov rdi, [rax + rbx*8]
    call sqlite3_value_blob wrt ..plt
    mov [rbp - CBA_PTR], rax
    test rax, rax
    jnz .blob_len
    mov rdi, [rbp - CBA_CTX]
    call sqlite3_context_db_handle wrt ..plt
    mov rdi, rax
    call sqlite3_errcode wrt ..plt
    cmp eax, SQLITE_NOMEM
    je .oom
    lea rax, [rel cb_empty_byte]
    mov [rbp - CBA_PTR], rax
    xor esi, esi
    jmp .blob_make
.blob_len:
    mov rax, [rbp - CBA_ARGV]
    mov rdi, [rax + rbx*8]
    call sqlite3_value_bytes wrt ..plt
    movsxd rsi, eax
.blob_make:
    mov rdi, [rbp - CBA_PTR]
    call bytes_from_data

.store:
    mov [r13 + rbx*8], rax
    inc rbx
    jmp .loop

.ok:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret

.bad_utf8:
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel cb_e_utf8]
    call set_exception
    jmp .cleanup
.oom:
    lea rdi, [rel exc_MemoryError_type]
    lea rsi, [rel cb_e_oom]
    call set_exception
.cleanup:
    ; Release out_buf[0 .. rbx).
    xor r12d, r12d
.free_loop:
    cmp r12, rbx
    jge .fail_ret
    mov rdi, [r13 + r12*8]
    DECREF_V rdi, rcx
    inc r12
    jmp .free_loop
.fail_ret:
    mov rax, -1
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sq_cb_build_args

;; ============================================================================
;; sq_cb_free_args(rdi = Value* buf, rsi = count) -> nothing
;; ============================================================================
CFA_BUF     equ 8
CFA_N       equ 16
CFA_FRAME   equ 24              ; + 1 push (rbx) = 32, 16-aligned
DEF_FUNC_LOCAL sq_cb_free_args, CFA_FRAME
    push rbx
    mov [rbp - CFA_BUF], rdi
    mov [rbp - CFA_N], rsi
    xor ebx, ebx
.loop:
    cmp rbx, [rbp - CFA_N]
    jge .done
    mov rax, [rbp - CFA_BUF]
    mov rdi, [rax + rbx*8]
    DECREF_V rdi, rcx
    inc rbx
    jmp .loop
.done:
    pop rbx
    leave
    ret
END_FUNC sq_cb_free_args

;; ============================================================================
;; sq_cb_set_result(rdi = sqlite3_context*, rsi = Value) -> eax = 0 ok / -1 err
;; Fails: -1
;; ============================================================================
CSR_CTX     equ 8
CSR_VAL     equ 16
CSR_FRAME   equ 16
DEF_FUNC_LOCAL sq_cb_set_result, CSR_FRAME
    mov [rbp - CSR_CTX], rdi
    mov [rbp - CSR_VAL], rsi

    ; None -> NULL
    lea rax, [rel none_singleton]
    cmp rsi, rax
    je .res_null

    ; Int immediate -> int64
    V_IS_INT rsi, rcx
    jb .check_float
    V_TO_I64 rsi
    mov rdi, [rbp - CSR_CTX]
    call sqlite3_result_int64 wrt ..plt
    xor eax, eax
    leave
    ret

.check_float:
    V_IS_FLOAT rsi, rcx
    jae .check_ptr
    V_TO_F64 rsi
    movq xmm0, rsi
    mov rdi, [rbp - CSR_CTX]
    call sqlite3_result_double wrt ..plt
    xor eax, eax
    leave
    ret

.check_ptr:
    V_TEST_PTR rsi, rcx
    ja .bad_type
    mov rax, [rsi + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_flags]

    ; bool
    lea rdx, [rel bool_type]
    cmp rax, rdx
    je .res_bool

    ; int / int subclass
    test rcx, TYPE_FLAG_INT_SUBCLASS
    jnz .res_int_obj
    lea rdx, [rel int_type]
    cmp rax, rdx
    je .res_int_obj

    ; float subclass
    test rcx, TYPE_FLAG_FLOAT_SUBCLASS
    jnz .res_float_sub

    ; str / str subclass
    test rcx, TYPE_FLAG_STR_SUBCLASS
    jnz .res_str
    lea rdx, [rel str_type]
    cmp rax, rdx
    je .res_str

    ; bytes / bytearray / memoryview / tp_as_buffer
    test rcx, TYPE_FLAG_BYTES_SUBCLASS
    jnz .res_bytes_sub
    test rcx, TYPE_FLAG_BYTEARRAY_SUBCLASS
    jnz .res_ba_sub
    lea rdx, [rel bytes_type]
    cmp rax, rdx
    je .res_bytes_sub
    lea rdx, [rel bytearray_type]
    cmp rax, rdx
    je .res_ba_sub
    lea rdx, [rel memoryview_type]
    cmp rax, rdx
    je .res_mv
    mov r8, [rax + PyTypeObject.tp_as_buffer]
    test r8, r8
    jnz .res_buffer

.bad_type:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel cb_e_ret_type]
    call set_exception
    mov rax, -1
    leave
    ret

.res_null:
    mov rdi, [rbp - CSR_CTX]
    call sqlite3_result_null wrt ..plt
    xor eax, eax
    leave
    ret

.res_bool:
    lea rax, [rel bool_true]
    xor edx, edx
    cmp rsi, rax
    sete dl
    mov rdi, [rbp - CSR_CTX]
    mov rsi, rdx
    call sqlite3_result_int64 wrt ..plt
    xor eax, eax
    leave
    ret

.res_int_obj:
    mov rdi, rsi
    call sq_arg_int64_strict
    ERR_M1 .fail
    mov rdi, [rbp - CSR_CTX]
    mov rsi, rax
    call sqlite3_result_int64 wrt ..plt
    xor eax, eax
    leave
    ret

.res_float_sub:
    movsd xmm0, [rsi + PyFloatObject.value]
    mov rdi, [rbp - CSR_CTX]
    call sqlite3_result_double wrt ..plt
    xor eax, eax
    leave
    ret

.res_str:
    mov rdx, [rsi + PyStrObject.ob_size]
    mov eax, 0x7FFFFFFF
    cmp rdx, rax
    ja .str_too_big
    ; Reject lone surrogates (UTF-8 check fails on U+D800..U+DFFF).
    lea rdi, [rsi + PyStrObject.data]
    mov rsi, rdx
    call bytes_utf8_check
    cmp rax, -1
    jne .str_bad_utf8
    mov rsi, [rbp - CSR_VAL]
    mov rdx, [rsi + PyStrObject.ob_size]
    mov rdi, [rbp - CSR_CTX]
    lea rsi, [rsi + PyStrObject.data]
    mov rcx, SQLITE_TRANSIENT
    call sqlite3_result_text wrt ..plt
    xor eax, eax
    leave
    ret

.str_bad_utf8:
    SET_EXC exc_UnicodeEncodeError_type, "surrogates not allowed"
    mov rax, -1
    leave
    ret

.res_bytes_sub:
    mov rdx, [rsi + PyBytesObject.ob_size]
    lea rsi, [rsi + PyBytesObject.data]
    jmp .emit_blob

.res_ba_sub:
    mov rdx, [rsi + PyByteArrayObject.ob_size]
    mov rsi, [rsi + PyByteArrayObject.ob_bytes]
    test rsi, rsi
    jnz .emit_blob
    lea rsi, [rel cb_empty_byte]
    jmp .emit_blob

.res_mv:
    mov rdx, [rsi + PyMemoryViewObject.mv_len]
    mov rax, [rsi + PyMemoryViewObject.mv_buf]
    test rax, rax
    jz .bad_type
    cmp qword [rsi + PyMemoryViewObject.mv_stride], 1
    jne .non_contig
    mov rsi, rax
    jmp .emit_blob
.non_contig:
    SET_EXC exc_BufferError_type, "underlying buffer is not C-contiguous"
    mov rax, -1
    leave
    ret

.res_buffer:
    mov rdi, rsi
    mov esi, BUF_GET
    call r8
    mov rsi, rax
    ; rdx = len

.emit_blob:
    mov eax, 0x7FFFFFFF
    cmp rdx, rax
    ja .blob_too_big
    mov rdi, [rbp - CSR_CTX]
    mov rcx, SQLITE_TRANSIENT
    call sqlite3_result_blob wrt ..plt
    xor eax, eax
    leave
    ret

.str_too_big:
    lea rdi, [rel exc_OverflowError_type]
    lea rsi, [rel cb_e_str_big]
    call set_exception
    mov rax, -1
    leave
    ret

.blob_too_big:
    lea rdi, [rel exc_OverflowError_type]
    lea rsi, [rel cb_e_blob_big]
    call set_exception
.fail:
    mov rax, -1
    leave
    ret
END_FUNC sq_cb_set_result

;; ============================================================================
;; sq_cb_destroy(rdi = void* ctx) -> nothing
;;
;; SQLite xDestroy destructor for functions, aggregates, windows, collations.
;; ============================================================================
CD_CTX      equ 8
CD_GIL      equ 16
CD_FRAME    equ 16
DEF_FUNC sq_cb_destroy, CD_FRAME
    test rdi, rdi
    jz .done
    mov [rbp - CD_CTX], rdi
    call sq_cb_gil_enter
    mov [rbp - CD_GIL], rax
    mov rdi, [rbp - CD_CTX]
    call sq_cb_free_if_set
    mov rdi, [rbp - CD_GIL]
    call sq_cb_gil_leave
.done:
    leave
    ret
END_FUNC sq_cb_destroy

;; ============================================================================
;; sq_cb_func(rdi = sqlite3_context*, esi = argc, rdx = sqlite3_value**) -> void
;;
;; Scalar UDF trampoline.
;; ============================================================================
CF_CTX      equ 8
CF_ARGC     equ 16
CF_ARGV     equ 24
CF_GIL      equ 32
CF_BUF      equ 40
CF_HEAP     equ 48
CF_RES      equ 56
CF_INLINE   equ 184             ; 16 Values (128 bytes) at [rbp-184 .. rbp-64]
CF_FRAME    equ 192             ; + 0 pushes = 192, 16-aligned
DEF_FUNC sq_cb_func, CF_FRAME
    mov [rbp - CF_CTX], rdi
    movsxd rax, esi
    mov [rbp - CF_ARGC], rax
    mov [rbp - CF_ARGV], rdx
    mov qword [rbp - CF_HEAP], 0

    call sq_cb_gil_enter
    mov [rbp - CF_GIL], rax

    ; Choose inline or heap arg buffer.
    mov rax, [rbp - CF_ARGC]
    cmp rax, 16
    ja .alloc_buf
    lea rcx, [rbp - CF_INLINE]
    jmp .have_buf
.alloc_buf:
    lea rdi, [rax*8]
    call ap_malloc
    test rax, rax
    jz .oom
    mov [rbp - CF_HEAP], rax
    mov rcx, rax
.have_buf:
    mov [rbp - CF_BUF], rcx
    mov rdi, [rbp - CF_CTX]
    mov esi, [rbp - CF_ARGC]
    mov rdx, [rbp - CF_ARGV]
    call sq_cb_build_args
    ERR_M1 .err_noargs

    mov rdi, [rbp - CF_CTX]
    call sqlite3_user_data wrt ..plt
    mov rdi, [rax + SqlCb.callable]
    mov rsi, [rbp - CF_BUF]
    mov rdx, [rbp - CF_ARGC]
    call sq_cb_call_args        ; err: checked below after releasing args
    mov [rbp - CF_RES], rax

    mov rdi, [rbp - CF_BUF]
    mov rsi, [rbp - CF_ARGC]
    call sq_cb_free_args

    mov rsi, [rbp - CF_RES]
    test rsi, rsi
    jz .err_called
    mov rdi, [rbp - CF_CTX]
    call sq_cb_set_result       ; err: checked below after decref
    push rax
    sub rsp, 8
    mov rdi, [rbp - CF_RES]
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    test eax, eax
    js .err_called
    jmp .exit

.oom:
    lea rdi, [rel exc_MemoryError_type]
    lea rsi, [rel cb_e_oom]
    call set_exception
.err_noargs:
.err_called:
    mov rdi, [rbp - CF_CTX]
    lea rsi, [rel cb_e_func]
    call sq_cb_set_sqlite_error

.exit:
    mov rdi, [rbp - CF_HEAP]
    test rdi, rdi
    jz .leave_gil
    call ap_free
.leave_gil:
    mov rdi, [rbp - CF_GIL]
    call sq_cb_gil_leave
    leave
    ret
END_FUNC sq_cb_func

;; ============================================================================
;; sq_cb_getattr_cstr(rdi = obj, rsi = attr_cstr) -> rax = Value or 0
;; Fails: 0
;;
;; Looks up an attribute by C string name; ensures AttributeError is pending
;; if missing.
;; ============================================================================
GAC_OBJ     equ 8
GAC_RES     equ 16
GAC_FRAME   equ 16
DEF_FUNC_LOCAL sq_cb_getattr_cstr, GAC_FRAME
    mov [rbp - GAC_OBJ], rdi
    mov rdi, rsi
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    mov rdi, [rbp - GAC_OBJ]
    mov rsi, rax
    call obj_getattr_raw
    mov [rbp - GAC_RES], rax
    add rsp, 8
    pop rdi
    call obj_decref
    mov rax, [rbp - GAC_RES]
    test rax, rax
    jnz .ok
    cmp qword [gs:ThreadState.current_exception], 0
    jne .fail
    SET_EXC exc_AttributeError_type, "missing aggregate method"
.fail:
    xor eax, eax
.ok:
    leave
    ret
END_FUNC sq_cb_getattr_cstr

;; ============================================================================
;; sq_cb_step(rdi = sqlite3_context*, esi = argc, rdx = sqlite3_value**) -> void
;;
;; Aggregate and window xStep trampoline.
;; ============================================================================
CS_CTX      equ 8
CS_ARGC     equ 16
CS_ARGV     equ 24
CS_GIL      equ 32
CS_AGG      equ 40
CS_METH     equ 48
CS_BUF      equ 56
CS_HEAP     equ 64
CS_INLINE   equ 192             ; 16 Values at [rbp-192 .. rbp-72]
CS_FRAME    equ 208             ; + 0 pushes = 208, 16-aligned
DEF_FUNC sq_cb_step, CS_FRAME
    mov [rbp - CS_CTX], rdi
    movsxd rax, esi
    mov [rbp - CS_ARGC], rax
    mov [rbp - CS_ARGV], rdx
    mov qword [rbp - CS_METH], 0
    mov qword [rbp - CS_HEAP], 0

    call sq_cb_gil_enter
    mov [rbp - CS_GIL], rax

    mov rdi, [rbp - CS_CTX]
    mov esi, SqlAggCtx_size
    call sqlite3_aggregate_context wrt ..plt
    test rax, rax
    jz .agg_oom
    mov [rbp - CS_AGG], rax

    cmp qword [rax + SqlAggCtx.instance], 0
    jne .have_inst
    ; Instantiate aggregate class with 0 args.
    mov rdi, [rbp - CS_CTX]
    call sqlite3_user_data wrt ..plt
    mov rdi, [rax + SqlCb.callable]
    xor esi, esi
    xor edx, edx
    call sq_cb_call_args
    ERR_NULL .err_init
    mov rcx, [rbp - CS_AGG]
    mov [rcx + SqlAggCtx.instance], rax

.have_inst:
    mov rcx, [rbp - CS_AGG]
    mov rdi, [rcx + SqlAggCtx.instance]
    lea rsi, [rel cb_s_step]
    call sq_cb_getattr_cstr
    ERR_NULL .err_nostep
    mov [rbp - CS_METH], rax

    mov rax, [rbp - CS_ARGC]
    cmp rax, 16
    ja .alloc_buf
    lea rcx, [rbp - CS_INLINE]
    jmp .have_buf
.alloc_buf:
    lea rdi, [rax*8]
    call ap_malloc
    test rax, rax
    jz .oom_step
    mov [rbp - CS_HEAP], rax
    mov rcx, rax
.have_buf:
    mov [rbp - CS_BUF], rcx
    mov rdi, [rbp - CS_CTX]
    mov esi, [rbp - CS_ARGC]
    mov rdx, [rbp - CS_ARGV]
    call sq_cb_build_args
    ERR_M1 .err_step

    mov rdi, [rbp - CS_METH]
    mov rsi, [rbp - CS_BUF]
    mov rdx, [rbp - CS_ARGC]
    call sq_cb_call_args        ; err: checked after freeing args
    push rax
    sub rsp, 8
    mov rdi, [rbp - CS_BUF]
    mov rsi, [rbp - CS_ARGC]
    call sq_cb_free_args
    add rsp, 8
    pop rax
    test rax, rax
    jz .err_step
    mov rdi, rax
    DECREF_V rdi, rcx
    jmp .exit

.agg_oom:
    lea rdi, [rel exc_MemoryError_type]
    lea rsi, [rel cb_e_oom]
    call set_exception
    mov rdi, [rbp - CS_CTX]
    lea rsi, [rel cb_e_agg_oom]
    call sq_cb_set_sqlite_error
    jmp .exit

.err_init:
    mov rdi, [rbp - CS_CTX]
    lea rsi, [rel cb_e_agg_init]
    call sq_cb_set_sqlite_error
    jmp .exit

.err_nostep:
    mov rdi, [rbp - CS_CTX]
    lea rsi, [rel cb_e_agg_nostep]
    call sq_cb_set_sqlite_error
    jmp .exit

.oom_step:
    lea rdi, [rel exc_MemoryError_type]
    lea rsi, [rel cb_e_oom]
    call set_exception
.err_step:
    mov rdi, [rbp - CS_CTX]
    lea rsi, [rel cb_e_agg_step]
    call sq_cb_set_sqlite_error

.exit:
    mov rdi, [rbp - CS_METH]
    test rdi, rdi
    jz .free_heap
    DECREF_V rdi, rcx
.free_heap:
    mov rdi, [rbp - CS_HEAP]
    test rdi, rdi
    jz .leave_gil
    call ap_free
.leave_gil:
    mov rdi, [rbp - CS_GIL]
    call sq_cb_gil_leave
    leave
    ret
END_FUNC sq_cb_step

;; ============================================================================
;; sq_cb_final(rdi = sqlite3_context*) -> void
;;
;; Aggregate and window xFinal trampoline.
;; ============================================================================
CFI_CTX     equ 8
CFI_GIL     equ 16
CFI_INST    equ 24
CFI_EXC     equ 32
CFI_METH    equ 40
CFI_RES     equ 48
CFI_FRAME   equ 48
DEF_FUNC sq_cb_final, CFI_FRAME
    mov [rbp - CFI_CTX], rdi
    call sq_cb_gil_enter
    mov [rbp - CFI_GIL], rax

    mov rdi, [rbp - CFI_CTX]
    xor esi, esi                ; nBytes = 0: do not allocate if step never ran
    call sqlite3_aggregate_context wrt ..plt
    test rax, rax
    jz .leave_gil
    mov rcx, [rax + SqlAggCtx.instance]
    test rcx, rcx
    jz .leave_gil
    mov [rbp - CFI_INST], rcx
    mov qword [rax + SqlAggCtx.instance], 0

    ; Save any pending exception (e.g. from collation) while running finalize.
    call exc_fetch
    mov [rbp - CFI_EXC], rax

    mov rdi, [rbp - CFI_INST]
    lea rsi, [rel cb_s_finalize]
    call sq_cb_getattr_cstr
    ERR_NULL .err_attr
    mov [rbp - CFI_METH], rax

    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call sq_cb_call_args        ; err: checked below after cleanup
    mov [rbp - CFI_RES], rax
    mov rdi, [rbp - CFI_METH]
    DECREF_V rdi, rcx
    mov rdi, [rbp - CFI_INST]
    DECREF_V rdi, rcx

    mov rsi, [rbp - CFI_RES]
    test rsi, rsi
    jz .err_final
    mov rdi, [rbp - CFI_CTX]
    call sq_cb_set_result       ; err: checked below
    push rax
    sub rsp, 8
    mov rdi, [rbp - CFI_RES]
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    test eax, eax
    js .err_final

    ; Success: restore saved exception (if any).
    mov rdi, [rbp - CFI_EXC]
    test rdi, rdi
    jz .leave_gil
    call exc_restore
    jmp .leave_gil

.err_attr:
    mov rdi, [rbp - CFI_INST]
    DECREF_V rdi, rcx
    mov rdi, [rbp - CFI_CTX]
    lea rsi, [rel cb_e_agg_nofinal]
    call sq_cb_set_sqlite_error
    jmp .drop_saved_exc

.err_final:
    mov rdi, [gs:ThreadState.current_exception]
    test rdi, rdi
    jz .err_final_generic
    lea rsi, [rel exc_AttributeError_type]
    call exc_isinstance         ; err: static type
    cmp eax, 1
    je .err_final_attr
.err_final_generic:
    mov rdi, [rbp - CFI_CTX]
    lea rsi, [rel cb_e_agg_final]
    call sq_cb_set_sqlite_error
    jmp .drop_saved_exc
.err_final_attr:
    mov rdi, [rbp - CFI_CTX]
    lea rsi, [rel cb_e_agg_nofinal]
    call sq_cb_set_sqlite_error

.drop_saved_exc:
    mov rdi, [rbp - CFI_EXC]
    test rdi, rdi
    jz .leave_gil
    DECREF_V rdi, rcx

.leave_gil:
    mov rdi, [rbp - CFI_GIL]
    call sq_cb_gil_leave
    leave
    ret
END_FUNC sq_cb_final

;; ============================================================================
;; sq_cb_value(rdi = sqlite3_context*) -> void
;;
;; Window xValue trampoline.
;; ============================================================================
CV_CTX      equ 8
CV_GIL      equ 16
CV_METH     equ 24
CV_RES      equ 32
CV_FRAME    equ 32
DEF_FUNC sq_cb_value, CV_FRAME
    mov [rbp - CV_CTX], rdi
    call sq_cb_gil_enter
    mov [rbp - CV_GIL], rax

    mov rdi, [rbp - CV_CTX]
    mov esi, SqlAggCtx_size
    call sqlite3_aggregate_context wrt ..plt
    test rax, rax
    jz .leave_gil
    mov rdi, [rax + SqlAggCtx.instance]
    test rdi, rdi
    jz .leave_gil

    lea rsi, [rel cb_s_value]
    call sq_cb_getattr_cstr
    ERR_NULL .err_noval
    mov [rbp - CV_METH], rax

    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call sq_cb_call_args        ; err: checked below
    mov [rbp - CV_RES], rax
    mov rdi, [rbp - CV_METH]
    DECREF_V rdi, rcx

    mov rsi, [rbp - CV_RES]
    test rsi, rsi
    jz .err_val
    mov rdi, [rbp - CV_CTX]
    call sq_cb_set_result       ; err: checked below
    push rax
    sub rsp, 8
    mov rdi, [rbp - CV_RES]
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    test eax, eax
    js .err_valres
    jmp .leave_gil

.err_noval:
    mov rdi, [rbp - CV_CTX]
    lea rsi, [rel cb_e_win_noval]
    call sq_cb_set_sqlite_error
    jmp .leave_gil
.err_val:
    mov rdi, [gs:ThreadState.current_exception]
    test rdi, rdi
    jz .err_val_msg
    lea rsi, [rel exc_AttributeError_type]
    call exc_isinstance         ; err: static type
    cmp eax, 1
    je .err_noval
.err_val_msg:
    mov rdi, [rbp - CV_CTX]
    lea rsi, [rel cb_e_win_val]
    call sq_cb_set_sqlite_error
    jmp .leave_gil
.err_valres:
    mov rdi, [rbp - CV_CTX]
    lea rsi, [rel cb_e_win_valres]
    call sq_cb_set_sqlite_error

.leave_gil:
    mov rdi, [rbp - CV_GIL]
    call sq_cb_gil_leave
    leave
    ret
END_FUNC sq_cb_value

;; ============================================================================
;; sq_cb_inverse(rdi = sqlite3_context*, esi = argc, rdx = sqlite3_value**) -> void
;;
;; Window xInverse trampoline.
;; ============================================================================
CI_CTX      equ 8
CI_ARGC     equ 16
CI_ARGV     equ 24
CI_GIL      equ 32
CI_METH     equ 40
CI_BUF      equ 48
CI_HEAP     equ 56
CI_INLINE   equ 184
CI_FRAME    equ 192
DEF_FUNC sq_cb_inverse, CI_FRAME
    mov [rbp - CI_CTX], rdi
    movsxd rax, esi
    mov [rbp - CI_ARGC], rax
    mov [rbp - CI_ARGV], rdx
    mov qword [rbp - CI_METH], 0
    mov qword [rbp - CI_HEAP], 0

    call sq_cb_gil_enter
    mov [rbp - CI_GIL], rax

    mov rdi, [rbp - CI_CTX]
    mov esi, SqlAggCtx_size
    call sqlite3_aggregate_context wrt ..plt
    test rax, rax
    jz .exit
    mov rdi, [rax + SqlAggCtx.instance]
    test rdi, rdi
    jz .exit

    lea rsi, [rel cb_s_inverse]
    call sq_cb_getattr_cstr
    ERR_NULL .err_noinv
    mov [rbp - CI_METH], rax

    mov rax, [rbp - CI_ARGC]
    cmp rax, 16
    ja .alloc_buf
    lea rcx, [rbp - CI_INLINE]
    jmp .have_buf
.alloc_buf:
    lea rdi, [rax*8]
    call ap_malloc
    test rax, rax
    jz .oom_inv
    mov [rbp - CI_HEAP], rax
    mov rcx, rax
.have_buf:
    mov [rbp - CI_BUF], rcx
    mov rdi, [rbp - CI_CTX]
    mov esi, [rbp - CI_ARGC]
    mov rdx, [rbp - CI_ARGV]
    call sq_cb_build_args
    ERR_M1 .err_invargs

    mov rdi, [rbp - CI_METH]
    mov rsi, [rbp - CI_BUF]
    mov rdx, [rbp - CI_ARGC]
    call sq_cb_call_args        ; err: checked below
    push rax
    sub rsp, 8
    mov rdi, [rbp - CI_BUF]
    mov rsi, [rbp - CI_ARGC]
    call sq_cb_free_args
    add rsp, 8
    pop rax
    test rax, rax
    jz .err_inv
    mov rdi, rax
    DECREF_V rdi, rcx
    jmp .exit

.err_noinv:
    mov rdi, [rbp - CI_CTX]
    lea rsi, [rel cb_e_win_noinv]
    call sq_cb_set_sqlite_error
    jmp .exit
.oom_inv:
    lea rdi, [rel exc_MemoryError_type]
    lea rsi, [rel cb_e_oom]
    call set_exception
.err_invargs:
    mov rdi, [rbp - CI_CTX]
    lea rsi, [rel cb_e_win_invargs]
    call sq_cb_set_sqlite_error
    jmp .exit
.err_inv:
    mov rdi, [rbp - CI_CTX]
    lea rsi, [rel cb_e_win_inv]
    call sq_cb_set_sqlite_error

.exit:
    mov rdi, [rbp - CI_METH]
    test rdi, rdi
    jz .free_heap
    DECREF_V rdi, rcx
.free_heap:
    mov rdi, [rbp - CI_HEAP]
    test rdi, rdi
    jz .leave_gil
    call ap_free
.leave_gil:
    mov rdi, [rbp - CI_GIL]
    call sq_cb_gil_leave
    leave
    ret
END_FUNC sq_cb_inverse

;; ============================================================================
;; sq_cb_collation(rdi = SqlCb*, esi = len1, rdx = p1, ecx = len2, r8 = p2)
;;   -> eax = -1, 0, or 1
;;
;; Leaves any Python exception pending so sq_step can propagate it cleanly.
;; ============================================================================
CC_CB       equ 8
CC_LEN1     equ 16
CC_P1       equ 24
CC_LEN2     equ 32
CC_P2       equ 40
CC_GIL      equ 48
CC_ARGS     equ 64              ; 2 Values at [rbp-64], [rbp-56]
CC_RES      equ 72
CC_RET      equ 80
CC_FRAME    equ 80
DEF_FUNC sq_cb_collation, CC_FRAME
    mov [rbp - CC_CB], rdi
    movsxd rax, esi
    mov [rbp - CC_LEN1], rax
    mov [rbp - CC_P1], rdx
    movsxd rax, ecx
    mov [rbp - CC_LEN2], rax
    mov [rbp - CC_P2], r8
    mov qword [rbp - CC_RET], 0

    call sq_cb_gil_enter
    mov [rbp - CC_GIL], rax

    ; Bail immediately if a prior collation invocation raised.
    cmp qword [gs:ThreadState.current_exception], 0
    jne .leave_gil

    mov rdi, [rbp - CC_P1]
    mov rsi, [rbp - CC_LEN1]
    call bytes_utf8_check
    cmp rax, -1
    jne .bad_utf8
    mov rdi, [rbp - CC_P1]
    mov rsi, [rbp - CC_LEN1]
    call str_new_heap
    mov [rbp - CC_ARGS], rax

    mov rdi, [rbp - CC_P2]
    mov rsi, [rbp - CC_LEN2]
    call bytes_utf8_check
    cmp rax, -1
    jne .bad_utf8_2
    mov rdi, [rbp - CC_P2]
    mov rsi, [rbp - CC_LEN2]
    call str_new_heap
    mov [rbp - CC_ARGS + 8], rax

    mov rcx, [rbp - CC_CB]
    mov rdi, [rcx + SqlCb.callable]
    lea rsi, [rbp - CC_ARGS]
    mov edx, 2
    call sq_cb_call_args        ; err: leaves exception pending for sq_step
    mov [rbp - CC_RES], rax

    mov rdi, [rbp - CC_ARGS]
    call obj_decref
    mov rdi, [rbp - CC_ARGS + 8]
    call obj_decref

    mov rax, [rbp - CC_RES]
    test rax, rax
    jz .leave_gil

    ; Map any Python int (including arbitrary-precision GMP ints) to -1/0/1.
    V_IS_INT rax, rcx
    jb .heap_int
    V_TO_I64 rax
    test rax, rax
    jz .set_zero
    js .set_neg
    jmp .set_pos

.heap_int:
    V_TEST_PTR rax, rcx
    ja .drop_res
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel int_type]
    cmp rcx, rdx
    je .int_obj
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_INT_SUBCLASS
    jz .drop_res
    ; Unwrap int subclass if needed.
    mov rdx, [rax + PyIntSubclassObject.int_value]
    V_IS_INT rdx, rcx
    jb .unwrapped_ptr
    V_TO_I64 rdx
    test rdx, rdx
    jz .drop_res
    js .drop_neg
    jmp .drop_pos
.unwrapped_ptr:
    V_TEST_PTR rdx, rcx
    ja .drop_res
    mov rax, rdx
.int_obj:
    cmp qword [rax + PyIntObject.compact], 0
    je .gmp_sign
    mov rdx, [rax + PyIntObject.ival]
    test rdx, rdx
    jz .drop_res
    js .drop_neg
    jmp .drop_pos
.gmp_sign:
    ; mpz._mp_size is a signed 32-bit int at PyIntObject.mpz + 4.
    mov edx, [rax + PyIntObject.mpz + 4]
    test edx, edx
    jz .drop_res
    js .drop_neg
.drop_pos:
    mov qword [rbp - CC_RET], 1
    jmp .drop_res
.drop_neg:
    mov qword [rbp - CC_RET], -1
.drop_res:
    mov rdi, [rbp - CC_RES]
    DECREF_V rdi, rcx
    jmp .leave_gil

.set_pos:
    mov qword [rbp - CC_RET], 1
    jmp .leave_gil
.set_neg:
    mov qword [rbp - CC_RET], -1
.set_zero:
    jmp .leave_gil

.bad_utf8_2:
    mov rdi, [rbp - CC_ARGS]
    call obj_decref
.bad_utf8:
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel cb_e_utf8]
    call set_exception

.leave_gil:
    mov rdi, [rbp - CC_GIL]
    call sq_cb_gil_leave
    mov eax, [rbp - CC_RET]
    leave
    ret
END_FUNC sq_cb_collation

;; ============================================================================
;; sq_cb_cstr_or_none(rdi = const char* or 0) -> rax = str or None (owned)
;; ============================================================================
DEF_FUNC_LOCAL sq_cb_cstr_or_none
    test rdi, rdi
    jz .ret_none
    call str_from_cstr_heap
    leave
    ret
.ret_none:
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
END_FUNC sq_cb_cstr_or_none

;; ============================================================================
;; sq_cb_authorizer(rdi = SqlCb*, esi = action, rdx = a1, rcx = a2,
;;                  r8 = dbname, r9 = src) -> eax = SQLITE_OK/DENY/IGNORE
;; ============================================================================
CA_CB       equ 8
CA_ACT      equ 16
CA_A1       equ 24
CA_A2       equ 32
CA_DB       equ 40
CA_SRC      equ 48
CA_GIL      equ 56
CA_RES      equ 64
CA_RET      equ 72
CA_ARGS     equ 112             ; 5 Values at [rbp-112 .. rbp-80]
CA_FRAME    equ 112
DEF_FUNC sq_cb_authorizer, CA_FRAME
    mov [rbp - CA_CB], rdi
    movsxd rax, esi
    mov [rbp - CA_ACT], rax
    mov [rbp - CA_A1], rdx
    mov [rbp - CA_A2], rcx
    mov [rbp - CA_DB], r8
    mov [rbp - CA_SRC], r9
    mov qword [rbp - CA_RET], SQLITE_DENY

    call sq_cb_gil_enter
    mov [rbp - CA_GIL], rax

    mov rax, [rbp - CA_ACT]
    V_PACK_I64 rax, rcx
    mov [rbp - CA_ARGS], rax

    mov rdi, [rbp - CA_A1]
    call sq_cb_cstr_or_none
    mov [rbp - CA_ARGS + 8], rax

    mov rdi, [rbp - CA_A2]
    call sq_cb_cstr_or_none
    mov [rbp - CA_ARGS + 16], rax

    mov rdi, [rbp - CA_DB]
    call sq_cb_cstr_or_none
    mov [rbp - CA_ARGS + 24], rax

    mov rdi, [rbp - CA_SRC]
    call sq_cb_cstr_or_none
    mov [rbp - CA_ARGS + 32], rax

    mov rcx, [rbp - CA_CB]
    mov rdi, [rcx + SqlCb.callable]
    lea rsi, [rbp - CA_ARGS]
    mov edx, 5
    call sq_cb_call_args        ; err: checked below after releasing args
    mov [rbp - CA_RES], rax

    lea rdi, [rbp - CA_ARGS]
    mov esi, 5
    call sq_cb_free_args

    mov rax, [rbp - CA_RES]
    test rax, rax
    jz .raised

    ; Accept int fitting C int32; anything else (or overflow) -> SQLITE_DENY.
    V_IS_INT rax, rcx
    jb .check_heap_int
    V_TO_I64 rax
    movsxd rdx, eax
    cmp rax, rdx
    jne .overflow
    mov [rbp - CA_RET], rax
    jmp .leave_gil

.check_heap_int:
    V_TEST_PTR rax, rcx
    ja .drop_res
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel int_type]
    cmp rcx, rdx
    je .is_int
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_INT_SUBCLASS
    jz .drop_res
.is_int:
    mov rdi, rax
    call sq_arg_int64_strict
    ERR_M1 .drop_and_clear
    movsxd rdx, eax
    cmp rax, rdx
    jne .overflow_drop
    mov [rbp - CA_RET], rax
    jmp .drop_res

.overflow_drop:
    SET_EXC exc_OverflowError_type, "Python int too large to convert to C int"
.drop_and_clear:
    mov rdi, [rbp - CA_RES]
    DECREF_V rdi, rcx
    jmp .raised
.overflow:
    SET_EXC exc_OverflowError_type, "Python int too large to convert to C int"
.raised:
    mov rcx, [rbp - CA_CB]
    mov rdi, [rcx + SqlCb.callable]
    call sq_cb_print_or_clear_pending
    mov qword [rbp - CA_RET], SQLITE_DENY
    jmp .leave_gil

.drop_res:
    mov rdi, [rbp - CA_RES]
    DECREF_V rdi, rcx

.leave_gil:
    mov rdi, [rbp - CA_GIL]
    call sq_cb_gil_leave
    mov eax, [rbp - CA_RET]
    leave
    ret
END_FUNC sq_cb_authorizer

;; ============================================================================
;; sq_cb_progress(rdi = SqlCb*) -> eax = 0 (continue), 1 (abort), -1 (error)
;; ============================================================================
CP_CB       equ 8
CP_GIL      equ 16
CP_RET      equ 24
CP_FRAME    equ 32
DEF_FUNC sq_cb_progress, CP_FRAME
    mov [rbp - CP_CB], rdi
    mov qword [rbp - CP_RET], -1

    call sq_cb_gil_enter
    mov [rbp - CP_GIL], rax

    mov rcx, [rbp - CP_CB]
    mov rdi, [rcx + SqlCb.callable]
    xor esi, esi
    xor edx, edx
    call sq_cb_call_args
    ERR_NULL .raised

    push rax
    sub rsp, 8
    mov rdi, rax
    call obj_is_true            ; err: negative return handled below
    movsxd rdx, eax
    mov [rbp - CP_RET], rdx
    add rsp, 8
    pop rdi
    DECREF_V rdi, rcx

    cmp qword [rbp - CP_RET], 0
    jge .leave_gil
.raised:
    mov rcx, [rbp - CP_CB]
    mov rdi, [rcx + SqlCb.callable]
    call sq_cb_print_or_clear_pending
    mov qword [rbp - CP_RET], -1

.leave_gil:
    mov rdi, [rbp - CP_GIL]
    call sq_cb_gil_leave
    mov eax, [rbp - CP_RET]
    leave
    ret
END_FUNC sq_cb_progress

;; ============================================================================
;; sq_cb_trace(edi = type, rsi = SqlCb*, rdx = sqlite3_stmt*, rcx = sql)
;;   -> eax = 0
;;
;; sqlite3_trace_v2 callback for SQLITE_TRACE_STMT.
;; ============================================================================
CT_CB       equ 8
CT_STMT     equ 16
CT_SQL      equ 24
CT_GIL      equ 32
CT_EXP      equ 40
CT_ARG      equ 48
CT_FRAME    equ 48
DEF_FUNC sq_cb_trace, CT_FRAME
    cmp edi, SQLITE_TRACE_STMT
    jne .ret_zero

    mov [rbp - CT_CB], rsi
    mov [rbp - CT_STMT], rdx
    mov [rbp - CT_SQL], rcx

    call sq_cb_gil_enter
    mov [rbp - CT_GIL], rax

    mov rdi, [rbp - CT_STMT]
    call sqlite3_expanded_sql wrt ..plt
    mov [rbp - CT_EXP], rax
    test rax, rax
    jnz .from_expanded

    ; Expanded SQL was NULL: check OOM vs SQLITE_LIMIT_LENGTH exceeded.
    mov rdi, [rbp - CT_STMT]
    call sqlite3_db_handle wrt ..plt
    mov rdi, rax
    call sqlite3_errcode wrt ..plt
    cmp eax, SQLITE_NOMEM
    je .leave_gil

    mov rdi, [rel sq_data_error_type]
    test rdi, rdi
    jnz .trace_set_exc
    lea rdi, [rel exc_RuntimeError_type]
.trace_set_exc:
    lea rsi, [rel cb_e_trace_big]
    call set_exception
    mov rcx, [rbp - CT_CB]
    mov rdi, [rcx + SqlCb.callable]
    call sq_cb_print_or_clear_pending

    mov rdi, [rbp - CT_SQL]
    test rdi, rdi
    jz .leave_gil
    call str_from_cstr_heap
    jmp .invoke

.from_expanded:
    mov rdi, rax
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    mov rdi, [rbp - CT_EXP]
    call sqlite3_free wrt ..plt
    add rsp, 8
    pop rax

.invoke:
    mov [rbp - CT_ARG], rax
    mov rcx, [rbp - CT_CB]
    mov rdi, [rcx + SqlCb.callable]
    lea rsi, [rbp - CT_ARG]
    mov edx, 1
    call sq_cb_call_args        ; err: checked below
    push rax
    sub rsp, 8
    mov rdi, [rbp - CT_ARG]
    call obj_decref
    add rsp, 8
    pop rax
    test rax, rax
    jz .raised
    mov rdi, rax
    DECREF_V rdi, rcx
    jmp .leave_gil

.raised:
    mov rcx, [rbp - CT_CB]
    mov rdi, [rcx + SqlCb.callable]
    call sq_cb_print_or_clear_pending

.leave_gil:
    mov rdi, [rbp - CT_GIL]
    call sq_cb_gil_leave
.ret_zero:
    xor eax, eax
    leave
    ret
END_FUNC sq_cb_trace
