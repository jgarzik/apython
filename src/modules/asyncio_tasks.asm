; asyncio_tasks.asm - current, scheduled and eager asyncio task registries.

%include "macros.inc"
%include "object.inc"
%include "threadstate.inc"
%include "value.inc"

extern ap_strcmp
extern async_call_method
extern async_import
extern builtin_func_new
extern dict_del
extern dict_get
extern dict_new
extern dict_set
extern obj_dealloc
extern obj_decref
extern set_exception
extern set_new
extern str_from_cstr_heap

extern exc_RuntimeError_type
extern exc_TypeError_type
extern none_singleton

section .bss
alignb 8
async_current_tasks: resq 1
async_eager_tasks: resq 1
async_scheduled_tasks: resq 1

section .text

;; async_tasks_init(r12 = private module dictionary) -> void
;; Module bindings and the registry each keep a reference.
DEF_FUNC async_tasks_init
    call dict_new
    mov [rel async_current_tasks], rax
    mov rdx, rax
    lea rdi, [rel async_current_tasks_name]
    call async_publish_registry
    call set_new
    mov [rel async_eager_tasks], rax
    mov rdx, rax
    lea rdi, [rel async_eager_tasks_name]
    call async_publish_registry
    MODULE_ADD_FUNC async_current_task, async_current_task_name
    MODULE_ADD_FUNC async_enter_task, async_enter_task_name
    MODULE_ADD_FUNC async_leave_task, async_leave_task_name
    MODULE_ADD_FUNC async_swap_task, async_swap_task_name
    MODULE_ADD_FUNC async_scheduled_registry, async_scheduled_registry_name
    MODULE_ADD_FUNC async_register_task, async_register_task_name
    MODULE_ADD_FUNC async_unregister_task, async_unregister_task_name
    MODULE_ADD_FUNC async_register_eager_task, async_register_eager_task_name
    MODULE_ADD_FUNC async_unregister_eager_task, async_unregister_eager_task_name
    leave
    ret
END_FUNC async_tasks_init

;; async_publish_registry(rdi = name, rdx = registry, r12 = module dict) -> void
APR_VALUE equ 8
APR_NAME  equ 16
APR_FRAME equ 16
DEF_FUNC_LOCAL async_publish_registry, APR_FRAME
    mov [rbp - APR_VALUE], rdx
    call str_from_cstr_heap
    mov [rbp - APR_NAME], rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rbp - APR_VALUE]
    call dict_set_str
    mov rdi, [rbp - APR_NAME]
    call obj_decref
    leave
    ret
END_FUNC async_publish_registry

;; async_scheduled_registry(args, nargs) -> owned WeakSet
;; Fails: 0
DEF_FUNC_LOCAL async_scheduled_registry
    test rsi, rsi
    jnz .arity
    mov rax, [rel async_scheduled_tasks]
    test rax, rax
    jnz .ready
    lea rdi, [rel async_weakref_name]
    call async_import
    ERR_NULL .failed
    mov rdi, rax
    lea rsi, [rel async_weakset_name]
    xor edx, edx
    xor ecx, ecx
    call async_call_method
    ERR_NULL .failed
    ; Import or construction can re-enter Python. Retain the first registry.
    mov rdi, [rel async_scheduled_tasks]
    test rdi, rdi
    jnz .already_ready
    mov [rel async_scheduled_tasks], rax
    jmp .ready
.already_ready:
    mov rdi, rax
    call obj_decref
    mov rax, [rel async_scheduled_tasks]
.ready:
    INCREF rax
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "_get_scheduled_tasks() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC async_scheduled_registry

;; async_current_task(args, nargs) -> running task or None
;; Fails: 0
ACT_LOOP  equ 8
ACT_FRAME equ 16
DEF_FUNC_LOCAL async_current_task, ACT_FRAME
    mov rax, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov qword [rbp - ACT_LOOP], 0
    test rax, rax
    jz .no_kw
    mov rcx, [rax + PyTupleObject.ob_size]
    cmp rcx, 1
    ja .bad_kw
    test rcx, rcx
    jz .no_kw
    cmp rsi, 1
    jne .arity
    mov rdx, [rdi]
    mov [rbp - ACT_LOOP], rdx
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rdx, [rdx]
    lea rdi, [rdx + PyStrObject.data]
    lea rsi, [rel async_kw_loop_name]
    call ap_strcmp
    test eax, eax
    jnz .bad_kw
    mov rsi, [rbp - ACT_LOOP]
    jmp .have_loop_arg
.no_kw:
    cmp rsi, 1
    ja .arity
    test rsi, rsi
    jz .running_loop
    mov rsi, [rdi]
.have_loop_arg:
    lea rax, [rel none_singleton]
    cmp rsi, rax
    jne .lookup
.running_loop:
    mov rsi, [gs:ThreadState.asyncio_running_loop]
    test rsi, rsi
    jz .no_loop
.lookup:
    mov rdi, [rel async_current_tasks]
    call dict_get
    ERR_DICT_GET .failed
    test rax, rax
    jz .empty
    leave
    ret
.empty:
    LOAD_NONE rax
    leave
    ret
.no_loop:
    FAIL exc_RuntimeError_type, "no running event loop", .failed
.bad_kw:
    FAIL exc_TypeError_type, "current_task() got an unexpected keyword argument", .failed
.arity:
    FAIL exc_TypeError_type, "current_task() takes at most one argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC async_current_task

TASK_ENTER equ 0
TASK_LEAVE equ 1
TASK_SWAP equ 2

%macro TASK_SWITCH 2
;; %1(args, nargs) -> None, or the previous task when swapping
DEF_FUNC_BARE %1
    mov edx, %2
    jmp async_task_switch
END_FUNC %1
%endmacro
TASK_SWITCH async_enter_task, TASK_ENTER
TASK_SWITCH async_leave_task, TASK_LEAVE
TASK_SWITCH async_swap_task, TASK_SWAP

;; async_task_switch(args, nargs, mode) -> None or previous task
;; Fails: 0
ATS_LOOP  equ 8
ATS_TASK  equ 16
ATS_MODE  equ 24
ATS_OLD   equ 32
ATS_FRAME equ 32
DEF_FUNC_LOCAL async_task_switch, ATS_FRAME
    cmp rsi, 2
    jne .arity
    mov [rbp - ATS_MODE], rdx
    mov rsi, [rdi]
    mov [rbp - ATS_LOOP], rsi
    mov rax, [rdi + 8]
    mov [rbp - ATS_TASK], rax
    mov rdi, [rel async_current_tasks]
    call dict_get
    ERR_DICT_GET .failed
    mov [rbp - ATS_OLD], rax
    cmp qword [rbp - ATS_MODE], TASK_SWAP
    je .swap
    cmp qword [rbp - ATS_MODE], TASK_LEAVE
    je .leave_task
    test rax, rax
    jnz .already_running
    call .store
    ERR_M1 .failed
    jmp .none
.leave_task:
    cmp rax, [rbp - ATS_TASK]
    jne .wrong_task
    call .delete
    ERR_M1 .leave_failed
    mov rdi, [rbp - ATS_OLD]
    XDECREF_V rdi, rcx
.none:
    LOAD_NONE rax
    leave
    ret
.swap:
    ; ATS_OLD is already owned from dict_get (or 0)
    lea rcx, [rel none_singleton]
    cmp [rbp - ATS_TASK], rcx
    jne .swap_store
    call .delete
    jmp .swap_result
.swap_store:
    call .store
.swap_result:
    ERR_M1 .swap_failed
    mov rax, [rbp - ATS_OLD]
    test rax, rax
    jz .none
    leave
    ret
.leave_failed:
.swap_failed:
    mov rdi, [rbp - ATS_OLD]
    XDECREF_V rdi, rcx
    jmp .failed
.already_running:
    mov rdi, [rbp - ATS_OLD]
    XDECREF_V rdi, rcx
    FAIL exc_RuntimeError_type, "Cannot enter into task while another task is being executed.", .failed
.wrong_task:
    mov rdi, [rbp - ATS_OLD]
    XDECREF_V rdi, rcx
    FAIL exc_RuntimeError_type, "Leaving task does not match the current task.", .failed
.arity:
    FAIL exc_TypeError_type, "task bookkeeping requires a loop and a task", .failed
.failed:
    xor eax, eax
    leave
    ret
.store:
    mov rdi, [rel async_current_tasks]
    mov rsi, [rbp - ATS_LOOP]
    mov rdx, [rbp - ATS_TASK]
    jmp dict_set
.delete:
    mov rdi, [rel async_current_tasks]
    mov rsi, [rbp - ATS_LOOP]
    jmp dict_del
END_FUNC async_task_switch

%macro TASK_REGISTER 3
;; %1(args, nargs) -> None
;; Fails: 0
DEF_FUNC_BARE %1
    lea rdx, [rel %2]
    mov ecx, %3
    jmp async_task_registration
END_FUNC %1
%endmacro
TASK_REGISTER async_register_task, async_add_name, 0
TASK_REGISTER async_unregister_task, async_discard_name, 0
TASK_REGISTER async_register_eager_task, async_add_name, 1
TASK_REGISTER async_unregister_eager_task, async_discard_name, 1

;; async_task_registration(args, nargs, method name, eager) -> None
;; Fails: 0
ATR_ARGS   equ 8
ATR_METHOD equ 16
ATR_FRAME  equ 16
DEF_FUNC_LOCAL async_task_registration, ATR_FRAME
    cmp rsi, 1
    jne .arity
    mov [rbp - ATR_ARGS], rdi
    mov [rbp - ATR_METHOD], rdx
    test ecx, ecx
    jz .scheduled
    mov rax, [rel async_eager_tasks]
    INCREF rax
    jmp .call
.scheduled:
    xor esi, esi
    call async_scheduled_registry
    ERR_NULL .failed
.call:
    mov rdi, rax
    mov rsi, [rbp - ATR_METHOD]
    mov rdx, [rbp - ATR_ARGS]
    mov ecx, 1
    call async_call_method      ; err: propagate as returned
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "task registration takes one argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC async_task_registration

section .rodata
async_current_tasks_name: db "_current_tasks", 0
async_eager_tasks_name: db "_eager_tasks", 0
async_current_task_name: db "current_task", 0
async_enter_task_name: db "_enter_task", 0
async_leave_task_name: db "_leave_task", 0
async_swap_task_name: db "_swap_current_task", 0
async_scheduled_registry_name: db "_get_scheduled_tasks", 0
async_register_task_name: db "_register_task", 0
async_unregister_task_name: db "_unregister_task", 0
async_register_eager_task_name: db "_register_eager_task", 0
async_unregister_eager_task_name: db "_unregister_eager_task", 0
async_add_name: db "add", 0
async_discard_name: db "discard", 0
async_weakref_name: db "weakref", 0
async_weakset_name: db "WeakSet", 0
async_kw_loop_name: db "loop", 0
