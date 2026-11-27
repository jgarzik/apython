; native_asyncio.asm - the CPython-facing asyncio accelerator.
;
; The calling thread owns its running loop. The slot is independent of
; _asynciocore's scheduler. A zero slot means no loop is running.
; Also holds shared import/method-call/descriptor helpers and lazy caches
; used by asyncio_future.asm, asyncio_tasks.asm, and asyncio_task.asm.

%include "macros.inc"
%include "object.inc"
%include "threadstate.inc"
%include "value.inc"

extern async_future_init
extern async_task_init
extern async_tasks_init

extern builtin_func_new
extern builtin_getattr
extern dict_new
extern dict_set_str
extern getset_descr_new
extern import_module
extern module_new
extern obj_call_n
extern obj_dealloc
extern obj_decref
extern obj_incref
extern set_exception
extern str_from_cstr_heap
extern tuple_new

extern exc_RuntimeError_type
extern exc_TypeError_type
extern none_singleton

section .bss
alignb 8
async_cache_invalid_state: resq 1
async_cache_cancelled_err: resq 1
async_cache_copy_context:  resq 1
async_cache_extract_stack: resq 1
async_cache_future_repr:   resq 1
async_cache_task_repr:     resq 1
async_cache_task_getstack: resq 1
async_cache_task_prtstack: resq 1
async_cache_iscoroutine:   resq 1
async_cache_ctx_kwnames:   resq 1
async_cache_msg_kwnames:   resq 1

section .text

;; async_get_running_loop(args, nargs) -> running loop or None
;; Fails: 0
DEF_FUNC_LOCAL async_get_running_loop
    NO_KEYWORDS_RET "_get_running_loop() takes no keyword arguments", .failed
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
    NO_KEYWORDS_RET "get_running_loop() takes no keyword arguments", .failed
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
    NO_KEYWORDS_RET "_set_running_loop() takes no keyword arguments", .failed
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

;; async_get_event_loop_internal() -> owned running or policy loop
;; Fails: 0
DEF_FUNC async_get_event_loop_internal
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
.failed:
    xor eax, eax
    leave
    ret
END_FUNC async_get_event_loop_internal

;; async_get_event_loop(args, nargs) -> running or policy loop
;; Fails: 0
DEF_FUNC_LOCAL async_get_event_loop
    NO_KEYWORDS_RET "get_event_loop() takes no keyword arguments", .failed
    test rsi, rsi
    jnz .arity
    call async_get_event_loop_internal ; err: return the result to the caller
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

;; async_import_attr(rdi = C module name, rsi = C attr name) -> owned Value
;; Fails: 0
AIA_ATTR   equ 8
AIA_KEY    equ 16
AIA_OBJ    equ 24
AIA_RESULT equ 32
AIA_FRAME  equ 32
DEF_FUNC async_import_attr, AIA_FRAME
    mov [rbp - AIA_ATTR], rsi
    call async_import
    ERR_NULL .failed
    mov [rbp - AIA_OBJ], rax
    mov rdi, [rbp - AIA_ATTR]
    call str_from_cstr_heap
    mov [rbp - AIA_KEY], rax
    ; builtin_getattr expects args[0]=obj ([rbp-24]), args[1]=name ([rbp-16])
    lea rdi, [rbp - AIA_OBJ]
    mov esi, 2
    call builtin_getattr        ; err: inspect result after releasing temps
    mov [rbp - AIA_RESULT], rax
    mov rdi, [rbp - AIA_KEY]
    call obj_decref
    mov rdi, [rbp - AIA_OBJ]
    call obj_decref
    mov rax, [rbp - AIA_RESULT]
    leave
    ret
.failed:
    xor eax, eax
    leave
    ret
END_FUNC async_import_attr

;; async_call_method_kw(rdi = owned object, rsi = C name, rdx = args,
;;                      rcx = nargs, r8 = kwnames tuple or 0) -> Value or 0
;; Consume the object, look up the method, and invoke with optional keywords.
;; Fails: 0
ACN_NAME     equ 8
ACN_OBJECT   equ 16
ACN_CALLABLE equ 24
ACN_RESULT   equ 32
ACN_ARGS     equ 40
ACN_NARGS    equ 48
ACN_KWNAMES  equ 56
ACN_OLDKW    equ 64
ACN_FRAME    equ 64
DEF_FUNC async_call_method_kw, ACN_FRAME
    mov [rbp - ACN_ARGS], rdx
    mov [rbp - ACN_NARGS], rcx
    mov [rbp - ACN_KWNAMES], r8
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
    mov rax, [gs:ThreadState.kw_names_pending]
    mov [rbp - ACN_OLDKW], rax
    mov rax, [rbp - ACN_KWNAMES]
    mov [gs:ThreadState.kw_names_pending], rax
    mov rsi, [rbp - ACN_ARGS]
    mov rdx, [rbp - ACN_NARGS]
    call obj_call_n             ; err: return the result after restoring kw and releasing callable
    mov [rbp - ACN_RESULT], rax
    mov rcx, [rbp - ACN_OLDKW]
    mov [gs:ThreadState.kw_names_pending], rcx
    mov rdi, [rbp - ACN_CALLABLE]
    DECREF_V rdi, rcx
    mov rax, [rbp - ACN_RESULT]
    leave
    ret
.failed:
    xor eax, eax
    leave
    ret
END_FUNC async_call_method_kw

;; async_call_method(rdi = owned object, rsi = C name, rdx = args, rcx = nargs)
;;   -> Value or 0
;; Consume the object and look up the method with ordinary descriptor rules.
;; Fails: 0
DEF_FUNC_BARE async_call_method
    xor r8d, r8d
    jmp async_call_method_kw
END_FUNC async_call_method

;; async_get_kwnames_1(rdi = &cache slot, rsi = C kwname) -> borrowed 1-tuple
;; Fails: 0
AGK_SLOT equ 8
AGK_NAME equ 16
AGK_TUP  equ 24
AGK_FRAME equ 32
DEF_FUNC_LOCAL async_get_kwnames_1, AGK_FRAME
    mov rax, [rdi]
    test rax, rax
    jnz .ready
    mov [rbp - AGK_SLOT], rdi
    mov [rbp - AGK_NAME], rsi
    mov edi, 1
    call tuple_new
    mov [rbp - AGK_TUP], rax
    mov rdi, [rbp - AGK_NAME]
    call str_from_cstr_heap
    mov rcx, [rbp - AGK_TUP]
    mov rdx, [rcx + PyTupleObject.ob_item]
    mov [rdx], rax              ; tuple steals the reference
    mov rdx, [rbp - AGK_SLOT]
    mov [rdx], rcx
    mov rax, rcx
.ready:
    leave
    ret
END_FUNC async_get_kwnames_1

;; async_get_context_kwnames() -> borrowed 1-tuple ("context",)
;; Fails: 0
DEF_FUNC async_get_context_kwnames
    lea rdi, [rel async_cache_ctx_kwnames]
    lea rsi, [rel async_kw_context_name]
    call async_get_kwnames_1    ; err: propagate
    leave
    ret
END_FUNC async_get_context_kwnames

;; async_get_msg_kwnames() -> borrowed 1-tuple ("msg",)
;; Fails: 0
DEF_FUNC async_get_msg_kwnames
    lea rdi, [rel async_cache_msg_kwnames]
    lea rsi, [rel async_kw_msg_name]
    call async_get_kwnames_1    ; err: propagate
    leave
    ret
END_FUNC async_get_msg_kwnames

;; async_call_soon(rdi = loop (borrowed), rsi = func (borrowed),
;;                 rdx = arg (borrowed or 0), rcx = ctx (borrowed or 0)) -> 0 / -1
;; Fails: -1
ACS_LOOP equ 8
ACS_A2   equ 24                 ; 3-element args array at [rbp - 40 .. rbp - 17]
ACS_A1   equ 32
ACS_A0   equ 40
ACS_N    equ 48
ACS_KW   equ 56
ACS_FRAME equ 64
DEF_FUNC async_call_soon, ACS_FRAME
    mov [rbp - ACS_LOOP], rdi
    mov [rbp - ACS_A0], rsi
    test rcx, rcx
    jz .no_ctx
    ; With context=ctx: args = [func, ctx] if arg == 0, else [func, arg, ctx]
    test rdx, rdx
    jz .ctx_no_arg
    mov [rbp - ACS_A1], rdx
    mov [rbp - ACS_A2], rcx
    mov qword [rbp - ACS_N], 3
    jmp .get_kw
.ctx_no_arg:
    mov [rbp - ACS_A1], rcx
    mov qword [rbp - ACS_N], 2
.get_kw:
    call async_get_context_kwnames
    ERR_NULL .failed
    mov [rbp - ACS_KW], rax
    jmp .invoke
.no_ctx:
    mov qword [rbp - ACS_KW], 0
    test rdx, rdx
    jz .no_arg
    mov [rbp - ACS_A1], rdx
    mov qword [rbp - ACS_N], 2
    jmp .invoke
.no_arg:
    mov qword [rbp - ACS_N], 1
.invoke:
    mov rdi, [rbp - ACS_LOOP]
    INCREF_V rdi, rax
    lea rsi, [rel async_call_soon_name]
    lea rdx, [rbp - ACS_A0]
    mov rcx, [rbp - ACS_N]
    mov r8, [rbp - ACS_KW]
    call async_call_method_kw
    ERR_NULL .failed
    DECREF_V rax, rcx
    xor eax, eax
    leave
    ret
.failed:
    mov rax, -1
    leave
    ret
END_FUNC async_call_soon

;; async_get_cached_attr(rdi = &cache slot, rsi = C mod, rdx = C attr) -> borrowed Value
;; Fails: 0
AGCA_SLOT equ 8
AGCA_FRAME equ 16
DEF_FUNC_LOCAL async_get_cached_attr, AGCA_FRAME
    mov rax, [rdi]
    test rax, rax
    jnz .hit
    mov [rbp - AGCA_SLOT], rdi
    mov rdi, rsi
    mov rsi, rdx
    call async_import_attr
    ERR_NULL .failed
    mov rcx, [rbp - AGCA_SLOT]
    mov rdx, [rcx]
    test rdx, rdx
    jnz .raced
    mov [rcx], rax
.hit:
    leave
    ret
.raced:
    push rdx
    sub rsp, 8
    DECREF_V rax, rcx
    add rsp, 8
    pop rax
    leave
    ret
.failed:
    xor eax, eax
    leave
    ret
END_FUNC async_get_cached_attr

;; async_get_invalid_state_error() -> borrowed asyncio.exceptions.InvalidStateError
;; Fails: 0
DEF_FUNC async_get_invalid_state_error
    lea rdi, [rel async_cache_invalid_state]
    lea rsi, [rel async_mod_exceptions]
    lea rdx, [rel async_attr_invalid_state]
    call async_get_cached_attr  ; err: propagate
    leave
    ret
END_FUNC async_get_invalid_state_error

;; async_get_cancelled_error() -> borrowed asyncio.exceptions.CancelledError
;; Fails: 0
DEF_FUNC async_get_cancelled_error
    lea rdi, [rel async_cache_cancelled_err]
    lea rsi, [rel async_mod_exceptions]
    lea rdx, [rel async_attr_cancelled_err]
    call async_get_cached_attr  ; err: propagate
    leave
    ret
END_FUNC async_get_cancelled_error

;; async_get_copy_context() -> borrowed contextvars.copy_context
;; Fails: 0
DEF_FUNC async_get_copy_context
    lea rdi, [rel async_cache_copy_context]
    lea rsi, [rel async_mod_contextvars]
    lea rdx, [rel async_attr_copy_context]
    call async_get_cached_attr  ; err: propagate
    leave
    ret
END_FUNC async_get_copy_context

;; async_get_extract_stack() -> borrowed traceback.extract_stack
;; Fails: 0
DEF_FUNC async_get_extract_stack
    lea rdi, [rel async_cache_extract_stack]
    lea rsi, [rel async_mod_traceback]
    lea rdx, [rel async_attr_extract_stack]
    call async_get_cached_attr  ; err: propagate
    leave
    ret
END_FUNC async_get_extract_stack

;; async_get_future_repr() -> borrowed asyncio.base_futures._future_repr
;; Fails: 0
DEF_FUNC async_get_future_repr
    lea rdi, [rel async_cache_future_repr]
    lea rsi, [rel async_mod_base_futures]
    lea rdx, [rel async_attr_future_repr]
    call async_get_cached_attr  ; err: propagate
    leave
    ret
END_FUNC async_get_future_repr

;; async_get_task_repr() -> borrowed asyncio.base_tasks._task_repr
;; Fails: 0
DEF_FUNC async_get_task_repr
    lea rdi, [rel async_cache_task_repr]
    lea rsi, [rel async_mod_base_tasks]
    lea rdx, [rel async_attr_task_repr]
    call async_get_cached_attr  ; err: propagate
    leave
    ret
END_FUNC async_get_task_repr

;; async_get_task_get_stack() -> borrowed asyncio.base_tasks._task_get_stack
;; Fails: 0
DEF_FUNC async_get_task_get_stack
    lea rdi, [rel async_cache_task_getstack]
    lea rsi, [rel async_mod_base_tasks]
    lea rdx, [rel async_attr_task_getstack]
    call async_get_cached_attr  ; err: propagate
    leave
    ret
END_FUNC async_get_task_get_stack

;; async_get_task_print_stack() -> borrowed asyncio.base_tasks._task_print_stack
;; Fails: 0
DEF_FUNC async_get_task_print_stack
    lea rdi, [rel async_cache_task_prtstack]
    lea rsi, [rel async_mod_base_tasks]
    lea rdx, [rel async_attr_task_prtstack]
    call async_get_cached_attr  ; err: propagate
    leave
    ret
END_FUNC async_get_task_print_stack

;; async_get_iscoroutine() -> borrowed asyncio.coroutines.iscoroutine
;; Fails: 0
DEF_FUNC async_get_iscoroutine
    lea rdi, [rel async_cache_iscoroutine]
    lea rsi, [rel async_mod_coroutines]
    lea rdx, [rel async_attr_iscoroutine]
    call async_get_cached_attr  ; err: propagate
    leave
    ret
END_FUNC async_get_iscoroutine

;; async_add_method(rdi = dict, rsi = C name, rdx = func_ptr) -> void
AAM_DICT equ 8
AAM_NAME equ 16
AAM_FN   equ 24
AAM_KEY  equ 32
AAM_FRAME equ 32
DEF_FUNC async_add_method, AAM_FRAME
    mov [rbp - AAM_DICT], rdi
    mov [rbp - AAM_NAME], rsi
    mov rdi, rdx
    call builtin_func_new
    mov [rbp - AAM_FN], rax
    mov rdi, [rbp - AAM_NAME]
    call str_from_cstr_heap
    mov [rbp - AAM_KEY], rax
    mov rdi, [rbp - AAM_DICT]
    mov rsi, rax
    mov rdx, [rbp - AAM_FN]
    call dict_set_str
    mov rdi, [rbp - AAM_FN]
    call obj_decref
    mov rdi, [rbp - AAM_KEY]
    call obj_decref
    leave
    ret
END_FUNC async_add_method

;; async_add_getset(rdi = dict, rsi = C name, rdx = getter, rcx = setter,
;;                  r8 = owner_type or 0) -> void
AAG_DICT  equ 8
AAG_GET   equ 16
AAG_SET   equ 24
AAG_OWNER equ 32
AAG_KEY   equ 40
AAG_DESC  equ 48
AAG_FRAME equ 48
DEF_FUNC async_add_getset, AAG_FRAME
    mov [rbp - AAG_DICT], rdi
    mov [rbp - AAG_GET], rdx
    mov [rbp - AAG_SET], rcx
    mov [rbp - AAG_OWNER], r8
    mov rdi, rsi
    call str_from_cstr_heap
    mov [rbp - AAG_KEY], rax
    mov rdi, [rbp - AAG_GET]
    mov rsi, [rbp - AAG_SET]
    mov rdx, rax
    call getset_descr_new
    mov [rbp - AAG_DESC], rax
    mov rcx, [rbp - AAG_OWNER]
    mov [rax + PyGetSetDescrObject.gs_owner], rcx
    mov rdi, [rbp - AAG_DICT]
    mov rsi, [rbp - AAG_KEY]
    mov rdx, rax
    call dict_set_str
    mov rdi, [rbp - AAG_DESC]
    call obj_decref
    mov rdi, [rbp - AAG_KEY]
    call obj_decref
    leave
    ret
END_FUNC async_add_getset

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
    call async_task_init

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
async_call_soon_name: db "call_soon", 0
async_kw_context_name: db "context", 0
async_kw_msg_name: db "msg", 0
async_mod_exceptions: db "asyncio.exceptions", 0
async_attr_invalid_state: db "InvalidStateError", 0
async_attr_cancelled_err: db "CancelledError", 0
async_mod_contextvars: db "contextvars", 0
async_attr_copy_context: db "copy_context", 0
async_mod_traceback: db "traceback", 0
async_attr_extract_stack: db "extract_stack", 0
async_mod_base_futures: db "asyncio.base_futures", 0
async_attr_future_repr: db "_future_repr", 0
async_mod_base_tasks: db "asyncio.base_tasks", 0
async_attr_task_repr: db "_task_repr", 0
async_attr_task_getstack: db "_task_get_stack", 0
async_attr_task_prtstack: db "_task_print_stack", 0
async_mod_coroutines: db "asyncio.coroutines", 0
async_attr_iscoroutine: db "iscoroutine", 0
