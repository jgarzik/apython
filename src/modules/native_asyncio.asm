; native_asyncio.asm - the CPython-facing asyncio accelerator.
;
; The calling thread owns its running loop. The slot is independent of
; _asynciocore's scheduler. A zero slot means no loop is running.

%include "macros.inc"
%include "object.inc"
%include "threadstate.inc"
%include "value.inc"

extern builtin_func_new
extern builtin_getattr
extern dict_new
extern import_module
extern module_new
extern obj_call_n
extern obj_dealloc
extern obj_decref
extern set_exception
extern str_from_cstr_heap

extern exc_RuntimeError_type
extern exc_TypeError_type
extern none_singleton

section .text

;; async_get_running_loop(args, nargs) -> running loop or None
;; Fails: 0
DEF_FUNC_LOCAL async_get_running_loop
    test rsi, rsi
    jnz .arity
    mov rax, [gs:ThreadState.asyncio_running_loop]
    test rax, rax
    jz .empty
    INCREF_V rax, rcx
    leave
    ret
.empty:
    LOAD_NONE rax
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "_get_running_loop() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC async_get_running_loop

;; async_require_running_loop(args, nargs) -> running loop
;; Fails: 0
DEF_FUNC_LOCAL async_require_running_loop
    test rsi, rsi
    jnz .arity
    mov rax, [gs:ThreadState.asyncio_running_loop]
    test rax, rax
    jz .empty
    INCREF_V rax, rcx
    leave
    ret
.empty:
    FAIL exc_RuntimeError_type, "no running event loop", .failed
.arity:
    FAIL exc_TypeError_type, "get_running_loop() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC async_require_running_loop

;; async_set_running_loop(args, nargs) -> None
;; Fails: 0
DEF_FUNC_LOCAL async_set_running_loop
    cmp rsi, 1
    jne .arity
    mov rax, [rdi]
    lea rcx, [rel none_singleton]
    xor edx, edx
    cmp rax, rcx
    cmove rax, rdx
    INCREF_V rax, rcx
    mov rdi, [gs:ThreadState.asyncio_running_loop]
    mov [gs:ThreadState.asyncio_running_loop], rax
    XDECREF_V rdi, rcx
    LOAD_NONE rax
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "_set_running_loop() takes exactly one argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC async_set_running_loop

;; async_get_event_loop(args, nargs) -> running or policy loop
;; Fails: 0
AGE_NAME   equ 8
AGE_MODULE equ 16
AGE_FRAME  equ 16
DEF_FUNC_LOCAL async_get_event_loop, AGE_FRAME
    test rsi, rsi
    jnz .arity
    mov rax, [gs:ThreadState.asyncio_running_loop]
    test rax, rax
    jz .policy
    INCREF_V rax, rcx
    leave
    ret
.policy:
    lea rdi, [rel async_package_name]
    call str_from_cstr_heap
    mov [rbp - AGE_NAME], rax
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call import_module          ; err: check after releasing the name
    mov [rbp - AGE_MODULE], rax
    mov rdi, [rbp - AGE_NAME]
    call obj_decref
    mov rdi, [rbp - AGE_MODULE]
    test rdi, rdi
    jz .failed
    lea rsi, [rel async_policy_name]
    call async_call_noargs
    ERR_NULL .failed
    mov rdi, rax
    lea rsi, [rel async_get_event_loop_name]
    call async_call_noargs      ; err: return the result to the caller
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "get_event_loop() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC async_get_event_loop

;; async_call_noargs(rdi = owned object, rsi = C method name) -> Value
;; Consume the object and use descriptor lookup for policy overrides.
;; Fails: 0
ACN_NAME     equ 8
ACN_OBJECT   equ 16
ACN_CALLABLE equ 24
ACN_RESULT   equ 32
ACN_FRAME    equ 32
DEF_FUNC_LOCAL async_call_noargs, ACN_FRAME
    mov [rbp - ACN_OBJECT], rdi
    mov rdi, rsi
    call str_from_cstr_heap
    mov [rbp - ACN_NAME], rax
    lea rdi, [rbp - ACN_OBJECT]
    mov esi, 2
    call builtin_getattr        ; err: inspect the result after releasing the arguments
    mov [rbp - ACN_CALLABLE], rax
    mov rdi, [rbp - ACN_NAME]
    call obj_decref
    mov rdi, [rbp - ACN_OBJECT]
    DECREF_V rdi, rcx
    mov rdi, [rbp - ACN_CALLABLE]
    test rdi, rdi
    jz .failed
    xor esi, esi
    xor edx, edx
    call obj_call_n             ; err: return the result after releasing the callable
    mov [rbp - ACN_RESULT], rax
    mov rdi, [rbp - ACN_CALLABLE]
    DECREF_V rdi, rcx
    mov rax, [rbp - ACN_RESULT]
    leave
    ret
.failed:
    xor eax, eax
    leave
    ret
END_FUNC async_call_noargs

;; native_asyncio_clear_running_loop() -> void
;; Publish the empty slot before releasing the previous owner.
DEF_FUNC native_asyncio_clear_running_loop
    mov rdi, [gs:ThreadState.asyncio_running_loop]
    mov qword [gs:ThreadState.asyncio_running_loop], 0
    XDECREF_V rdi, rcx
    leave
    ret
END_FUNC native_asyncio_clear_running_loop

;; native_asyncio_module_create() -> the private accelerator module
NAM_RESULT equ 8
NAM_NAME   equ 16
NAM_FRAME  equ 24
DEF_FUNC native_asyncio_module_create, NAM_FRAME
    push r12
    call dict_new
    mov r12, rax
    MODULE_ADD_FUNC async_get_running_loop, async_get_running_loop_name
    MODULE_ADD_FUNC async_require_running_loop, async_require_running_loop_name
    MODULE_ADD_FUNC async_set_running_loop, async_set_running_loop_name
    MODULE_ADD_FUNC async_get_event_loop, async_get_event_loop_name

    lea rdi, [rel async_module_name]
    call str_from_cstr_heap
    mov [rbp - NAM_NAME], rax
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov [rbp - NAM_RESULT], rax
    mov rdi, [rbp - NAM_NAME]
    call obj_decref
    mov rdi, r12
    call obj_decref
    mov rax, [rbp - NAM_RESULT]
    pop r12
    leave
    ret
END_FUNC native_asyncio_module_create

section .rodata
async_module_name: db "_asyncio_native", 0
async_get_running_loop_name: db "_get_running_loop", 0
async_require_running_loop_name: db "get_running_loop", 0
async_set_running_loop_name: db "_set_running_loop", 0
async_get_event_loop_name: db "get_event_loop", 0
async_package_name: db "asyncio", 0
async_policy_name: db "get_event_loop_policy", 0
