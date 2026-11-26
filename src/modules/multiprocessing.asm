; multiprocessing.asm - named Linux semaphores for lib/_multiprocessing.py
;
; A private object owns each sem_open reference. Update ownership while
; holding the GIL so a release and its count are visible together.

%include "macros.inc"
%include "object.inc"
%include "gil.inc"

ASM_INIT

extern sem_open
extern sem_close
extern sem_unlink
extern sem_getvalue
extern sem_post
extern pthread_self
extern __errno_location
extern thread_sem_wait
extern posix_embedded_nul
extern posix_int_arg
extern set_oserror
extern set_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_AssertionError_type
extern ap_malloc
extern ap_free
extern type_type
extern object_type
extern dict_new
extern dict_set
extern builtin_func_new
extern str_from_cstr_heap
extern module_new
extern obj_decref
extern none_singleton
extern bool_true
extern bool_false

MP_O_CREAT_EXCL equ 0xc0

struc SemRef
    .ob_refcnt: resq 1
    .ob_type:   resq 1
    .handle:    resq 1
    .owner:     resq 1
    .count:     resq 1
    .kind:      resq 1
endstruc

section .text

;; mp_sem_name(rdi = name Value) -> C string borrowed from the name
;; Fails: 0
DEF_FUNC_LOCAL mp_sem_name, 8
    push rbx
    V_TEST_PTR rdi, rax
    ja .type
    test rdi, rdi
    jz .type
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .type
    lea rbx, [rdi + PyStrObject.data]
    mov rsi, [rdi + PyStrObject.ob_size]
    mov rdi, rbx
    call posix_embedded_nul
    test eax, eax
    jnz .nul
    mov rax, rbx
.out:
    pop rbx
    leave
    ret
.type:
    FAIL exc_TypeError_type, "semaphore name must be str", .fail
.nul:
    FAIL exc_ValueError_type, "embedded null character", .fail
.fail:
    xor eax, eax
    jmp .out
END_FUNC mp_sem_name

;; mp_sem_handle(rdi = SemRef Value) -> borrowed sem_t pointer, rdx = SemRef
;; Fails: 0
DEF_FUNC_LOCAL mp_sem_handle
    V_TEST_PTR rdi, rax
    ja .type
    test rdi, rdi
    jz .type
    lea rax, [rel mp_sem_type]
    cmp [rdi + SemRef.ob_type], rax
    jne .type
    mov rax, [rdi + SemRef.handle]
    test rax, rax
    jz .type
    mov rdx, rdi
    leave
    ret
.type:
    SET_EXC exc_TypeError_type, "expected an open semaphore"
    xor eax, eax
    leave
    ret
END_FUNC mp_sem_handle

;; mp_sem_open(args, nargs) -> owned SemRef or 0
;; Fixed arguments are (name, flags, initial value, kind). The binding layer only
;; requests exclusive creation or reopen. Both supply a private 0600 mode.
MO_ARGS  equ 8
MO_NAME  equ 16
MO_FLAGS equ 24
MO_VALUE equ 32
MO_ERRNO equ 40
MO_KIND  equ 48
MO_FRAME equ 56
DEF_FUNC_LOCAL mp_sem_open, MO_FRAME
    push rbx
    cmp rsi, 4
    jne .arity
    mov [rbp - MO_ARGS], rdi
    mov rdi, [rdi]
    call mp_sem_name
    ERR_NULL .fail
    mov [rbp - MO_NAME], rax
    mov rax, [rbp - MO_ARGS]
    mov rdi, [rax + 8]
    call posix_int_arg
    ERR_M1 .fail
    test rax, rax
    jz .flags_ok
    cmp rax, MP_O_CREAT_EXCL
    jne .invalid
.flags_ok:
    mov [rbp - MO_FLAGS], eax
    mov rax, [rbp - MO_ARGS]
    mov rdi, [rax + 16]
    call posix_int_arg
    ERR_M1 .fail
    movsxd rcx, eax
    cmp rcx, rax
    jne .invalid
    mov [rbp - MO_VALUE], eax
    mov rax, [rbp - MO_ARGS]
    mov rdi, [rax + 24]
    call posix_int_arg
    ERR_M1 .fail
    cmp rax, 1
    ja .invalid
    mov [rbp - MO_KIND], rax

    ALLOW_THREADS_BEGIN
    mov rdi, [rbp - MO_NAME]
    mov esi, [rbp - MO_FLAGS]
    mov edx, 0o600
    mov ecx, [rbp - MO_VALUE]
    xor eax, eax
    call sem_open
    mov rbx, rax
    test rax, rax
    jnz .locked
    call __errno_location
    mov eax, [rax]
    mov [rbp - MO_ERRNO], eax
.locked:
    ALLOW_THREADS_END
    test rbx, rbx
    jz .oserror

    mov edi, SemRef_size
    call ap_malloc
    mov qword [rax + SemRef.ob_refcnt], 1
    lea rcx, [rel mp_sem_type]
    mov [rax + SemRef.ob_type], rcx
    mov [rax + SemRef.handle], rbx
    mov qword [rax + SemRef.owner], 0
    mov qword [rax + SemRef.count], 0
    mov rcx, [rbp - MO_KIND]
    mov [rax + SemRef.kind], rcx
.out:
    pop rbx
    leave
    ret
.oserror:
    mov edi, [rbp - MO_ERRNO]
    xor esi, esi
    call set_oserror
    jmp .fail
.invalid:
    FAIL exc_ValueError_type, "invalid semaphore creation arguments", .fail
.arity:
    FAIL exc_TypeError_type, "semaphore open expects four arguments", .fail
.fail:
    xor eax, eax
    jmp .out
END_FUNC mp_sem_open

;; mp_sem_dealloc(rdi = owned SemRef) -> void
DEF_FUNC_LOCAL mp_sem_dealloc, 8
    push rbx
    mov rbx, rdi
    mov rdi, [rdi + SemRef.handle]
    test rdi, rdi
    jz .free
    call sem_close
.free:
    mov rdi, rbx
    call ap_free
    pop rbx
    leave
    ret
END_FUNC mp_sem_dealloc

;; mp_sem_ref_new(type, args, nargs) -> 0 with TypeError
DEF_FUNC_LOCAL mp_sem_ref_new
    SET_EXC exc_TypeError_type, "semaphore references must be opened by the runtime"
    xor eax, eax
    leave
    ret
END_FUNC mp_sem_ref_new

;; mp_sem_current_error() -> 0 with the current libc errno as OSError
DEF_FUNC_LOCAL mp_sem_current_error
    call __errno_location
    mov edi, [rax]
    xor esi, esi
    call set_oserror
    leave
    ret
END_FUNC mp_sem_current_error

;; mp_sem_unlink(args, nargs) -> None, or 0
DEF_FUNC_LOCAL mp_sem_unlink
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    call mp_sem_name
    ERR_NULL .fail
    mov rdi, rax
    call sem_unlink
    test eax, eax
    js .error
    LOAD_NONE rax
    leave
    ret
.error:
    call mp_sem_current_error
.fail:
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "sem_unlink expects one argument", .fail
END_FUNC mp_sem_unlink

MW_TIMEOUT equ 8
MW_OWNER equ 16
MW_FRAME equ 24

;; mp_sem_wait(args, nargs) -> bool for (semaphore, timeout ns), or 0
DEF_FUNC_LOCAL mp_sem_wait, MW_FRAME
    push rbx
    cmp rsi, 2
    jne .arity
    mov rbx, rdi
    mov rdi, [rbx + 8]
    call posix_int_arg
    ERR_M1 .fail
    mov [rbp - MW_TIMEOUT], rax
    mov rdi, [rbx]
    call mp_sem_handle
    ERR_NULL .fail
    mov rbx, rdx
    call pthread_self
    mov [rbp - MW_OWNER], rax
    cmp qword [rbx + SemRef.kind], 0
    jne .wait
    cmp qword [rbx + SemRef.count], 0
    jle .wait
    cmp [rbx + SemRef.owner], rax
    jne .wait
    lea rax, [rel bool_true]
    INCREF rax
    jmp .taken
.wait:
    mov rdi, [rbx + SemRef.handle]
    mov rsi, [rbp - MW_TIMEOUT]
    call thread_sem_wait
    lea rcx, [rel bool_true]
    cmp rax, rcx
    jne .out
.taken:
    mov rcx, [rbp - MW_OWNER]
    mov [rbx + SemRef.owner], rcx
    inc qword [rbx + SemRef.count]
.out:
    pop rbx
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "semaphore wait expects two arguments", .fail
.fail:
    xor eax, eax
    jmp .out
END_FUNC mp_sem_wait

MV_VALUE equ 4
MV_FRAME equ 16

;; mp_sem_value(args, nargs) -> current semaphore value, or 0
DEF_FUNC_LOCAL mp_sem_value, MV_FRAME
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    call mp_sem_handle
    ERR_NULL .fail
    mov rdi, rax
    lea rsi, [rbp - MV_VALUE]
    call sem_getvalue
    test eax, eax
    js .error
    movsxd rax, dword [rbp - MV_VALUE]
    V_PACK_I64 rax, rdx
    leave
    ret
.error:
    call mp_sem_current_error
.fail:
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "semaphore value expects one argument", .fail
END_FUNC mp_sem_value

;; mp_sem_id(args, nargs) -> semaphore handle as a Value, or 0
DEF_FUNC_LOCAL mp_sem_id
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    call mp_sem_handle
    ERR_NULL .fail
    V_PACK_I64 rax, rdx
.fail:
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "semaphore handle expects one argument", .fail
END_FUNC mp_sem_id

MR_MAX equ 8
MR_VALUE equ 12
MR_FRAME equ 24

;; mp_sem_release(args, nargs) -> None for (semaphore, maximum), or 0
;;
;; Check and post under the GIL, as CPython does. Another process may release
;; between the two calls. The kernel owns the semaphore's storage either way.
DEF_FUNC_LOCAL mp_sem_release, MR_FRAME
    push rbx
    cmp rsi, 2
    jne .arity
    mov rbx, rdi
    mov rdi, [rbx + 8]
    call posix_int_arg
    ERR_M1 .fail
    mov [rbp - MR_MAX], rax
    mov rdi, [rbx]
    call mp_sem_handle
    ERR_NULL .fail
    mov rbx, rdx
    cmp qword [rbx + SemRef.kind], 0
    je .recursive
    mov rdi, rax
    lea rsi, [rbp - MR_VALUE]
    call sem_getvalue
    test eax, eax
    js .error
    movsxd rax, dword [rbp - MR_VALUE]
    cmp rax, [rbp - MR_MAX]
    jge .over
.post:
    mov rdi, [rbx + SemRef.handle]
    call sem_post
    test eax, eax
    js .error
.decrement:
    dec qword [rbx + SemRef.count]
    LOAD_NONE rax
.out:
    pop rbx
    leave
    ret
.recursive:
    call pthread_self
    cmp [rbx + SemRef.owner], rax
    jne .unowned
    cmp qword [rbx + SemRef.count], 1
    jl .unowned
    je .post
    jmp .decrement
.error:
    call mp_sem_current_error
.fail:
    xor eax, eax
    jmp .out
.arity:
    FAIL exc_TypeError_type, "semaphore release expects two arguments", .fail
.over:
    FAIL exc_ValueError_type, "semaphore or lock released too many times", .fail
.unowned:
    FAIL exc_AssertionError_type, "attempt to release recursive lock not owned by thread", .fail
END_FUNC mp_sem_release

;; mp_sem_count(args, nargs) -> the handle's local acquisition count
DEF_FUNC_LOCAL mp_sem_count
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    call mp_sem_handle
    ERR_NULL .fail
    mov rax, [rdx + SemRef.count]
    V_PACK_I64 rax, rcx
.fail:
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "semaphore count expects one argument", .fail
END_FUNC mp_sem_count

;; mp_sem_owned(args, nargs) -> whether this thread owns the handle
DEF_FUNC_LOCAL mp_sem_owned, 8
    push rbx
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    call mp_sem_handle
    ERR_NULL .out
    mov rbx, rdx
    call pthread_self
    cmp [rbx + SemRef.owner], rax
    jne .unowned
    cmp qword [rbx + SemRef.count], 0
    jle .unowned
    lea rax, [rel bool_true]
    jmp .return_bool
.unowned:
    lea rax, [rel bool_false]
.return_bool:
    INCREF rax
.out:
    pop rbx
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "semaphore ownership expects one argument", .out
END_FUNC mp_sem_owned

;; mp_sem_reset(args, nargs) -> reset process-local ownership after fork
DEF_FUNC_LOCAL mp_sem_reset
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    call mp_sem_handle
    ERR_NULL .fail
    mov qword [rdx + SemRef.owner], 0
    mov qword [rdx + SemRef.count], 0
    LOAD_NONE rax
.fail:
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "semaphore reset expects one argument", .fail
END_FUNC mp_sem_reset

;; multiprocessing_module_create() -> module object
DEF_FUNC multiprocessing_module_create, 8
    push rbx
    push r12
    push r13
    call dict_new
    mov r12, rax
    MODULE_ADD_FUNC mp_sem_open, mp_n_open
    MODULE_ADD_FUNC mp_sem_unlink, mp_n_unlink
    MODULE_ADD_FUNC mp_sem_wait, mp_n_wait
    MODULE_ADD_FUNC mp_sem_value, mp_n_value
    MODULE_ADD_FUNC mp_sem_id, mp_n_handle
    MODULE_ADD_FUNC mp_sem_release, mp_n_release
    MODULE_ADD_FUNC mp_sem_count, mp_n_count
    MODULE_ADD_FUNC mp_sem_owned, mp_n_owned
    MODULE_ADD_FUNC mp_sem_reset, mp_n_reset

    lea rdi, [rel mp_n_module]
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
END_FUNC multiprocessing_module_create

section .rodata
mp_n_module:  db "_multiprocessingcore", 0
mp_n_type:    db "_multiprocessingcore.SemRef", 0
mp_n_open:    db "open", 0
mp_n_unlink:  db "unlink", 0
mp_n_wait:    db "wait", 0
mp_n_value:   db "value", 0
mp_n_handle:  db "handle", 0
mp_n_release: db "release", 0
mp_n_count:   db "count", 0
mp_n_owned:   db "owned", 0
mp_n_reset:   db "reset", 0

section .data
align 8
mp_sem_type:
    dq 1                         ; ob_refcnt
    dq type_type                 ; ob_type
    dq mp_n_type                 ; tp_name
    dq SemRef_size               ; tp_basicsize
    dq mp_sem_dealloc            ; tp_dealloc
    dq 0                         ; tp_repr
    dq 0                         ; tp_str
    dq 0                         ; tp_hash
    dq 0                         ; tp_call
    dq 0                         ; tp_getattr
    dq 0                         ; tp_setattr
    dq 0                         ; tp_richcompare
    dq 0                         ; tp_iter
    dq 0                         ; tp_iternext
    dq 0                         ; tp_init
    dq mp_sem_ref_new            ; tp_new
    dq 0                         ; tp_as_number
    dq 0                         ; tp_as_sequence
    dq 0                         ; tp_as_mapping
    dq object_type               ; tp_base
    dq 0                         ; tp_dict
    dq 0                         ; tp_mro
    dq TYPE_FLAG_FINAL           ; tp_flags
    dq 0                         ; tp_bases
    dq 0                         ; tp_traverse
    dq 0                         ; tp_clear
    dq 0                         ; tp_dictoffset
    dq 0                         ; tp_tailslots
    dq 0                         ; tp_as_buffer
