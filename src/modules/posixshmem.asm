; posixshmem.asm - libc's named shared memory operations
;
; Keep the original name alive across the libc call and attach it to any
; OSError.  lib/_posixshmem.py binds keywords and supplies the defaults.

%include "macros.inc"
%include "object.inc"
%include "gil.inc"

ASM_INIT

extern shm_open
extern shm_unlink
extern __errno_location
extern signal_run_pending
extern posix_embedded_nul
extern posix_int_arg
extern set_oserror
extern set_exception
extern exc_OverflowError_type
extern exc_TypeError_type
extern exc_ValueError_type
extern dict_new
extern dict_set
extern builtin_func_new
extern str_from_cstr_heap
extern module_new
extern obj_decref
extern none_singleton

SHM_EINTR equ 4

section .text

;; shm_core_open(args, nargs) -> fd Value, or 0 with an exception
DEF_FUNC_BARE shm_core_open
    xor ecx, ecx
    jmp shm_core_call
END_FUNC shm_core_open

;; shm_core_unlink(args, nargs) -> None Value, or 0 with an exception
DEF_FUNC_BARE shm_core_unlink
    mov ecx, 1
    jmp shm_core_call
END_FUNC shm_core_unlink

SH_ARGS equ 8
SH_PATH equ 16
SH_FLAGS equ 24
SH_MODE equ 32
SH_UNLINK equ 40
SH_RESULT equ 44
SH_ERRNO equ 48
SH_NAME equ 56
SH_FRAME equ 64

;; shm_core_call(args, nargs, ecx = unlink selector) -> Value or 0
DEF_FUNC_LOCAL shm_core_call, SH_FRAME
    mov [rbp - SH_UNLINK], ecx
    mov [rbp - SH_ARGS], rdi
    test ecx, ecx
    jnz .one_arg
    cmp rsi, 3
    jne .arity
    jmp .path
.one_arg:
    cmp rsi, 1
    jne .arity
.path:
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .path_type
    test rdi, rdi
    jz .path_type
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .path_type
    mov [rbp - SH_PATH], rdi

    cmp dword [rbp - SH_UNLINK], 0
    jne .check_name
    mov rax, [rbp - SH_ARGS]
    mov rdi, [rax + 8]
    call posix_int_arg
    ERR_M1 .fail
    movsxd rcx, eax
    cmp rax, rcx
    jne .range
    mov [rbp - SH_FLAGS], eax
    mov rax, [rbp - SH_ARGS]
    mov rdi, [rax + 16]
    call posix_int_arg
    ERR_M1 .fail
    movsxd rcx, eax
    cmp rax, rcx
    jne .range
    mov [rbp - SH_MODE], eax
.check_name:
    mov rax, [rbp - SH_PATH]
    lea rdi, [rax + PyStrObject.data]
    mov [rbp - SH_NAME], rdi
    mov rsi, [rax + PyStrObject.ob_size]
    call posix_embedded_nul
    test eax, eax
    jnz .embedded_nul
.retry:
    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - SH_NAME]
    cmp dword [rbp - SH_UNLINK], 0
    jne .unlink
    mov esi, [rbp - SH_FLAGS]
    mov edx, [rbp - SH_MODE]
    call shm_open
    jmp .result
.unlink:
    call shm_unlink
.result:
    mov [rbp - SH_RESULT], eax
    test eax, eax
    jns .locked
    call __errno_location
    mov eax, [rax]
    mov [rbp - SH_ERRNO], eax
.locked:
    ALLOW_THREADS_END
    mov eax, [rbp - SH_RESULT]
    test eax, eax
    js .error
    cmp dword [rbp - SH_UNLINK], 0
    jne .none
    V_PACK_I64 rax, rdx
    leave
    ret
.none:
    LOAD_NONE rax
    leave
    ret
.error:
    cmp dword [rbp - SH_ERRNO], SHM_EINTR
    jne .oserror
    call signal_run_pending
    test eax, eax
    jz .retry
    jmp .fail
.oserror:
    mov edi, [rbp - SH_ERRNO]
    mov rsi, [rbp - SH_PATH]
    call set_oserror
    jmp .fail
.embedded_nul:
    FAIL exc_ValueError_type, "embedded null character", .fail
.path_type:
    FAIL exc_TypeError_type, "path must be str", .fail
.range:
    FAIL exc_OverflowError_type, "Python int too large to convert to C int", .fail
.arity:
    FAIL exc_TypeError_type, "_posixshmemcore: wrong number of arguments", .fail
.fail:
    xor eax, eax
    leave
    ret
END_FUNC shm_core_call

;; posixshmem_module_create() -> module object
DEF_FUNC posixshmem_module_create, 8
    push rbx
    push r12
    push r13
    call dict_new
    mov r12, rax
    MODULE_ADD_FUNC shm_core_open, shm_n_open
    MODULE_ADD_FUNC shm_core_unlink, shm_n_unlink

    lea rdi, [rel shm_n_module]
    call str_from_cstr_heap
    mov r13, rax
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov rbx, rax
    mov rdi, r13
    call obj_decref
    mov rdi, r12
    call obj_decref
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC posixshmem_module_create

section .rodata
shm_n_module: db "_posixshmemcore", 0
shm_n_open:   db "shm_open", 0
shm_n_unlink: db "shm_unlink", 0
