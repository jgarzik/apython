; native_asyncio.asm - the CPython-facing asyncio accelerator.
;
; The calling thread owns its running loop. The slot is independent of
; _asynciocore's scheduler. A zero slot means no loop is running.

%include "macros.inc"
%include "object.inc"
%include "threadstate.inc"
%include "value.inc"

extern async_future_init
extern async_tasks_init

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
DEF_FUNC_LOCAL async_get_event_loop
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
    call async_import
    ERR_NULL .failed
    mov rdi, rax
    lea rsi, [rel async_policy_name]
    xor edx, edx
    xor ecx, ecx
    call async_call_method
    ERR_NULL .failed
    mov rdi, rax
    lea rsi, [rel async_get_event_loop_name]
    xor edx, edx
    xor ecx, ecx
    call async_call_method      ; err: return the result to the caller
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "get_event_loop() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC async_get_event_loop

;; async_import(rdi = C module name) -> owned module
;; Fails: 0
AI_NAME   equ 8
AI_RESULT equ 16
AI_FRAME  equ 16
DEF_FUNC async_import, AI_FRAME
    call str_from_cstr_heap
    mov [rbp - AI_NAME], rax
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call import_module          ; err: propagate after releasing the name
    mov [rbp - AI_RESULT], rax
    mov rdi, [rbp - AI_NAME]
    call obj_decref
    mov rax, [rbp - AI_RESULT]
    leave
    ret
END_FUNC async_import

;; async_call_method(rdi = owned object, rsi = C name, rdx = args, rcx = nargs)
;;   -> Value or 0
;; Consume the object and look up the method with ordinary descriptor rules.
;; Fails: 0
ACN_NAME     equ 8
ACN_OBJECT   equ 16
ACN_CALLABLE equ 24
ACN_RESULT   equ 32
ACN_ARGS     equ 40
ACN_NARGS    equ 48
ACN_FRAME    equ 48
DEF_FUNC async_call_method, ACN_FRAME
    mov [rbp - ACN_ARGS], rdx
    mov [rbp - ACN_NARGS], rcx
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
    mov rsi, [rbp - ACN_ARGS]
    mov rdx, [rbp - ACN_NARGS]
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
END_FUNC async_call_method

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
    call async_tasks_init
    call async_future_init

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
