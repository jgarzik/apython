; asyncio_task.asm - native _asyncio.Task, TaskStepMethWrapper, and TaskWakeup.
;
; Task is a GC-tracked heaptype subclassing _asyncio.Future with PyTaskObject
; fields laid out directly past PyFutureObject.  Coroutines are driven through
; gen_iternext / _gen_throw_impl on the fast path, avoiding StopIteration
; allocation when a native coroutine returns normally.

%include "macros.inc"
%include "object.inc"
%include "threadstate.inc"
%include "value.inc"

extern _gen_throw_impl
extern add_class_getitem
extern ap_strcmp
extern async_add_getset
extern async_add_method
extern async_call_method
extern async_call_method_kw
extern async_call_soon
extern async_enter_task
extern async_get_cancelled_error
extern async_get_context_kwnames
extern async_get_copy_context
extern async_get_invalid_state_error
extern async_get_iscoroutine
extern async_get_task_get_stack
extern async_get_task_print_stack
extern async_get_task_repr
extern async_leave_task
extern async_register_eager_task
extern async_register_task
extern async_swap_task
extern async_unregister_eager_task
extern bool_false
extern bool_true
extern builtin_getattr
extern builtin_setattr
extern coro_type
extern dict_new
extern dict_set_str
extern exc_fetch
extern exc_install
extern exc_isinstance
extern exc_new
extern exc_restore
extern future_add_done_callback_impl
extern future_cancel_impl
extern future_clear
extern future_create_cancelled_error
extern future_dealloc
extern future_finalize_impl
extern future_get_result_impl
extern future_init_impl
extern future_new_iter
extern future_set_exception_impl
extern future_set_result_impl
extern future_traverse_fields
extern future_type
extern gc_alloc
extern gc_dealloc
extern gc_track
extern gen_iternext
extern gen_type
extern list_type
extern none_singleton
extern obj_call_n
extern obj_dealloc
extern obj_decref
extern obj_incref
extern obj_is_true
extern obj_repr
extern obj_str
extern set_exception
extern str_concat
extern str_from_cstr_heap
extern str_type
extern traceback_print_unraisable
extern tuple_new
extern type_from_parts
extern type_is_subtype
extern type_refresh_attr_flags
extern type_stamp_methods
extern type_type

extern exc_AttributeError_type
extern exc_KeyboardInterrupt_type
extern exc_RuntimeError_type
extern exc_StopIteration_type
extern exc_SystemExit_type
extern exc_TypeError_type

section .bss
alignb 8
global async_task_type
async_task_type:         resq 1
task_name_counter: resq 1

section .text

;; ============================================================================
;; task_clear_fields(rdi = PyTaskObject*) -> void
;; Clear Task's own fields (not Future's). Safe if called repeatedly.
;; ============================================================================
DEF_FUNC_LOCAL task_clear_fields, 8
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyTaskObject.task_fut_waiter]
    mov qword [rbx + PyTaskObject.task_fut_waiter], 0
    XDECREF_V rdi, rax

    mov rdi, [rbx + PyTaskObject.task_coro]
    mov qword [rbx + PyTaskObject.task_coro], 0
    XDECREF_V rdi, rax

    mov rdi, [rbx + PyTaskObject.task_name]
    mov qword [rbx + PyTaskObject.task_name], 0
    XDECREF_V rdi, rax

    mov rdi, [rbx + PyTaskObject.task_context]
    mov qword [rbx + PyTaskObject.task_context], 0
    XDECREF_V rdi, rax

    mov dword [rbx + PyTaskObject.task_must_cancel], 0
    mov dword [rbx + PyTaskObject.task_log_destroy], 0
    mov dword [rbx + PyTaskObject.task_num_cancels], 0
    mov dword [rbx + PyTaskObject.task_pad], 0

    pop rbx
    leave
    ret
END_FUNC task_clear_fields

;; ============================================================================
;; task_traverse(rdi = PyTaskObject*, r14 = visit callback) -> 0
;; ============================================================================
DEF_FUNC_LOCAL task_traverse
    push rbx
    push r12
    mov rbx, rdi

    call future_traverse_fields

    mov rdi, [rbx + PyTaskObject.task_fut_waiter]
    VISIT_V rdi, rax
    mov rdi, [rbx + PyTaskObject.task_coro]
    VISIT_V rdi, rax
    mov rdi, [rbx + PyTaskObject.task_name]
    VISIT_V rdi, rax
    mov rdi, [rbx + PyTaskObject.task_context]
    VISIT_V rdi, rax

    ; Visit any subclass __slots__ past PyTaskObject_size.
    mov rax, [rbx + PyObject.ob_type]
    mov r12d, PyTaskObject_size
.slot_loop:
    cmp r12, [rax + PyTypeObject.tp_basicsize]
    jge .done
    mov rdi, [rbx + r12]
    push rax
    sub rsp, 8
    VISIT_V rdi, rcx
    add rsp, 8
    pop rax
    add r12, 8
    jmp .slot_loop
.done:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC task_traverse

;; ============================================================================
;; task_clear(rdi = PyTaskObject*) -> 0
;; ============================================================================
DEF_FUNC_LOCAL task_clear, 8
    push rbx
    mov rbx, rdi
    call task_clear_fields
    mov rdi, rbx
    call future_clear
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC task_clear

;; ============================================================================
;; task_dealloc(rdi = PyTaskObject*) -> void
;; ============================================================================
DEF_FUNC_LOCAL task_dealloc, 8
    push rbx
    mov rbx, rdi
    call task_clear_fields
    mov rdi, rbx
    call future_dealloc
    pop rbx
    leave
    ret
END_FUNC task_dealloc

;; ============================================================================
;; TaskStepMethWrapper — callable scheduled via loop.call_soon for Task._step
;; ============================================================================

;; task_step_wrapper_new(rdi = PyTaskObject*, rsi = exc Value or 0, edx = eager)
;;   -> owned PyTaskStepWrapperObject*
TSWN_TASK  equ 8
TSWN_ARG   equ 16
TSWN_EAGER equ 24
TSWN_FRAME equ 32
DEF_FUNC_LOCAL task_step_wrapper_new, TSWN_FRAME
    mov [rbp - TSWN_TASK], rdi
    mov [rbp - TSWN_ARG], rsi
    mov [rbp - TSWN_EAGER], rdx
    mov edi, PyTaskStepWrapperObject_size
    lea rsi, [rel task_step_wrapper_type]
    call gc_alloc
    mov rcx, [rbp - TSWN_TASK]
    INCREF rcx
    mov [rax + PyTaskStepWrapperObject.sw_task], rcx
    mov rcx, [rbp - TSWN_ARG]
    INCREF_V rcx, rdx
    mov [rax + PyTaskStepWrapperObject.sw_arg], rcx
    mov rcx, [rbp - TSWN_EAGER]
    mov [rax + PyTaskStepWrapperObject.sw_eager], rcx
    push rax
    sub rsp, 8
    mov rdi, rax
    call gc_track
    add rsp, 8
    pop rax
    leave
    ret
END_FUNC task_step_wrapper_new

;; task_step_wrapper_clear(rdi = self) -> 0
DEF_FUNC_LOCAL task_step_wrapper_clear, 8
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyTaskStepWrapperObject.sw_task]
    mov qword [rbx + PyTaskStepWrapperObject.sw_task], 0
    XDECREF_V rdi, rax
    mov rdi, [rbx + PyTaskStepWrapperObject.sw_arg]
    mov qword [rbx + PyTaskStepWrapperObject.sw_arg], 0
    XDECREF_V rdi, rax
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC task_step_wrapper_clear

;; task_step_wrapper_traverse(rdi = self, r14 = visit) -> 0
DEF_FUNC_LOCAL task_step_wrapper_traverse, 8
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyTaskStepWrapperObject.sw_task]
    VISIT_PTR rdi
    mov rdi, [rbx + PyTaskStepWrapperObject.sw_arg]
    VISIT_V rdi, rax
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC task_step_wrapper_traverse

;; task_step_wrapper_dealloc(rdi = self) -> void
DEF_FUNC_LOCAL task_step_wrapper_dealloc, 8
    push rbx
    mov rbx, rdi
    call task_step_wrapper_clear
    mov rdi, rbx
    call gc_dealloc
    pop rbx
    leave
    ret
END_FUNC task_step_wrapper_dealloc

;; task_step_wrapper_get_self(rdi = self) -> task or None
DEF_FUNC_LOCAL task_step_wrapper_get_self
    mov rax, [rdi + PyTaskStepWrapperObject.sw_task]
    test rax, rax
    jz .ret_none
    INCREF rax
    leave
    ret
.ret_none:
    LOAD_NONE rax
    leave
    ret
END_FUNC task_step_wrapper_get_self

;; task_step_wrapper_call(rdi = self, rsi = args, rdx = nargs) -> None or 0
;; Fails: 0
DEF_FUNC_LOCAL task_step_wrapper_call
    NO_KEYWORDS_RET "function takes no keyword arguments", .failed
    test rdx, rdx
    jnz .arity
    mov rax, [rdi + PyTaskStepWrapperObject.sw_eager]
    mov rsi, [rdi + PyTaskStepWrapperObject.sw_arg]
    mov rdi, [rdi + PyTaskStepWrapperObject.sw_task]
    test rax, rax
    jnz .eager
    call async_task_step        ; err: propagate
    leave
    ret
.eager:
    call async_task_step_impl   ; err: propagate
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "function takes no positional arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_step_wrapper_call

;; ============================================================================
;; TaskWakeup — callable passed to future.add_done_callback(task._wakeup)
;; ============================================================================

;; task_wakeup_new(rdi = PyTaskObject*) -> owned PyTaskWakeupObject*
DEF_FUNC_LOCAL task_wakeup_new, 8
    push rbx
    mov rbx, rdi
    mov edi, PyTaskWakeupObject_size
    lea rsi, [rel task_wakeup_type]
    call gc_alloc
    INCREF rbx
    mov [rax + PyTaskWakeupObject.tw_task], rbx
    push rax
    sub rsp, 8
    mov rdi, rax
    call gc_track
    add rsp, 8
    pop rax
    pop rbx
    leave
    ret
END_FUNC task_wakeup_new

;; task_wakeup_clear(rdi = self) -> 0
DEF_FUNC_LOCAL task_wakeup_clear, 8
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyTaskWakeupObject.tw_task]
    mov qword [rbx + PyTaskWakeupObject.tw_task], 0
    XDECREF_V rdi, rax
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC task_wakeup_clear

;; task_wakeup_traverse(rdi = self, r14 = visit) -> 0
DEF_FUNC_LOCAL task_wakeup_traverse, 8
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyTaskWakeupObject.tw_task]
    VISIT_PTR rdi
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC task_wakeup_traverse

;; task_wakeup_dealloc(rdi = self) -> void
DEF_FUNC_LOCAL task_wakeup_dealloc, 8
    push rbx
    mov rbx, rdi
    call task_wakeup_clear
    mov rdi, rbx
    call gc_dealloc
    pop rbx
    leave
    ret
END_FUNC task_wakeup_dealloc

;; task_wakeup_get_self(rdi = self) -> task or None
DEF_FUNC_LOCAL task_wakeup_get_self
    mov rax, [rdi + PyTaskWakeupObject.tw_task]
    test rax, rax
    jz .ret_none
    INCREF rax
    leave
    ret
.ret_none:
    LOAD_NONE rax
    leave
    ret
END_FUNC task_wakeup_get_self

;; task_wakeup_call(rdi = self, rsi = args, rdx = nargs) -> None or 0
;; Fails: 0
DEF_FUNC_LOCAL task_wakeup_call
    NO_KEYWORDS_RET "task_wakeup() takes no keyword arguments", .failed
    cmp rdx, 1
    jne .arity
    mov rdi, [rdi + PyTaskWakeupObject.tw_task]
    mov rsi, [rsi]
    call async_task_wakeup      ; err: propagate
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "task_wakeup() takes exactly one argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_wakeup_call

;; ============================================================================
;; Helpers: call_step_soon, set_error_soon, is_coroutine, get_future_loop
;; ============================================================================

;; task_call_step_soon(rdi = PyTaskObject*, rsi = exc Value or 0) -> 0 / -1
;; Fails: -1
TCSS_TASK equ 8
TCSS_CB   equ 16
TCSS_CTX  equ 24
TCSS_FRAME equ 32
DEF_FUNC_LOCAL task_call_step_soon, TCSS_FRAME
    mov [rbp - TCSS_TASK], rdi
    xor edx, edx                ; eager = 0
    call task_step_wrapper_new
    mov [rbp - TCSS_CB], rax
    mov rdi, [rbp - TCSS_TASK]
    mov rcx, [rdi + PyTaskObject.task_context]
    mov [rbp - TCSS_CTX], rcx
    INCREF_V rcx, rax           ; hold ref across call_soon (CPython GH-126080)
    mov rdi, [rdi + PyTaskObject.fut_loop]
    mov rsi, [rbp - TCSS_CB]
    xor edx, edx                ; no arg
    call async_call_soon        ; err: release cb/ctx before checking
    push rax
    sub rsp, 8
    mov rdi, [rbp - TCSS_CTX]
    XDECREF_V rdi, rcx
    mov rdi, [rbp - TCSS_CB]
    call obj_decref
    add rsp, 8
    pop rax
    leave
    ret
END_FUNC task_call_step_soon

;; task_concat_cstr(rdi = owned PyStrObject*, rsi = C str) -> owned PyStrObject*
;; Consumes rdi and returns concatenated string.
TCC_LHS equ 8
TCC_RHS equ 16
TCC_FRAME equ 16
DEF_FUNC_LOCAL task_concat_cstr, TCC_FRAME
    mov [rbp - TCC_LHS], rdi
    mov rdi, rsi
    call str_from_cstr_heap
    mov [rbp - TCC_RHS], rax
    mov rdi, [rbp - TCC_LHS]
    mov rsi, rax
    call str_concat             ; err: both operands are exact str
    push rax
    sub rsp, 8
    mov rdi, [rbp - TCC_LHS]
    call obj_decref
    mov rdi, [rbp - TCC_RHS]
    call obj_decref
    add rsp, 8
    pop rax
    leave
    ret
END_FUNC task_concat_cstr

;; task_concat_repr(rdi = owned PyStrObject*, rsi = Value) -> owned PyStrObject*
;; Consumes rdi, appends repr(rsi).
;; Fails: 0
TCR_LHS equ 8
TCR_RHS equ 16
TCR_FRAME equ 16
DEF_FUNC_LOCAL task_concat_repr, TCR_FRAME
    mov [rbp - TCR_LHS], rdi
    mov rdi, rsi
    call obj_repr
    ERR_NULL .fail_lhs
    mov [rbp - TCR_RHS], rax
    mov rdi, [rbp - TCR_LHS]
    mov rsi, rax
    call str_concat             ; err: both operands are exact str
    push rax
    sub rsp, 8
    mov rdi, [rbp - TCR_LHS]
    call obj_decref
    mov rdi, [rbp - TCR_RHS]
    call obj_decref
    add rsp, 8
    pop rax
    leave
    ret
.fail_lhs:
    mov rdi, [rbp - TCR_LHS]
    call obj_decref
    xor eax, eax
    leave
    ret
END_FUNC task_concat_repr

;; task_schedule_runtime_error(rdi = PyTaskObject*, rsi = owned msg str) -> None or 0
;; Consumes msg str, creates RuntimeError(msg), schedules task_call_step_soon.
;; Fails: 0
TSRE_TASK equ 8
TSRE_EXC  equ 16
TSRE_FRAME equ 16
DEF_FUNC_LOCAL task_schedule_runtime_error, TSRE_FRAME
    mov [rbp - TSRE_TASK], rdi
    push rsi
    sub rsp, 8
    lea rdi, [rel exc_RuntimeError_type]
    call exc_new
    mov [rbp - TSRE_EXC], rax
    add rsp, 8
    pop rdi
    call obj_decref
    mov rdi, [rbp - TSRE_TASK]
    mov rsi, [rbp - TSRE_EXC]
    call task_call_step_soon    ; err: release exc first, checked by ERR_M1 below
    push rax
    sub rsp, 8
    mov rdi, [rbp - TSRE_EXC]
    call obj_decref
    add rsp, 8
    pop rax
    ERR_M1 .failed
    LOAD_NONE rax
    leave
    ret
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_schedule_runtime_error

;; task_is_coroutine(rdi = Value) -> eax = 1/0/-1
;; Fails: -1
TIC_ARG equ 8
TIC_FRAME equ 16
DEF_FUNC_LOCAL task_is_coroutine, TIC_FRAME
    V_TEST_PTR rdi, rax
    ja .slow
    test rdi, rdi
    jz .slow
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel coro_type]
    cmp rax, rcx
    jne .slow
    mov eax, 1
    leave
    ret
.slow:
    mov [rbp - TIC_ARG], rdi
    call async_get_iscoroutine
    ERR_NULL .failed
    mov rdi, rax
    lea rsi, [rbp - TIC_ARG]
    mov edx, 1
    call obj_call_n
    ERR_NULL .failed
    push rax
    sub rsp, 8
    mov rdi, rax
    call obj_is_true            ; err: decref res first
    mov r8, rax
    add rsp, 8
    pop rdi
    push r8
    sub rsp, 8
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    leave
    ret
.failed:
    mov rax, -1
    leave
    ret
END_FUNC task_is_coroutine

;; task_get_future_loop(rdi = Value) -> owned loop Value or 0
;; Fast path for exact Future / Task; fallback calls get_loop() or reads _loop.
;; Fails: 0
TGFL_OBJ equ 24                 ; [rbp-24]=obj, [rbp-16]=name, [rbp-8]=default
TGFL_KEY equ 16
TGFL_DEF equ 8
TGFL_FRAME equ 32
DEF_FUNC_LOCAL task_get_future_loop, TGFL_FRAME
    mov [rbp - TGFL_OBJ], rdi
    V_TEST_PTR rdi, rax
    ja .lookup
    test rdi, rdi
    jz .lookup
    mov rax, [rdi + PyObject.ob_type]
    cmp rax, [rel future_type]
    je .fast
    cmp rax, [rel async_task_type]
    jne .lookup
.fast:
    mov rax, [rdi + PyFutureObject.fut_loop]
    test rax, rax
    jz .fast_none
    INCREF_V rax, rcx
    leave
    ret
.fast_none:
    LOAD_NONE rax
    leave
    ret

.lookup:
    lea rdi, [rel tn_get_loop]
    call str_from_cstr_heap
    mov [rbp - TGFL_KEY], rax
    lea rcx, [rel none_singleton]
    mov [rbp - TGFL_DEF], rcx
    lea rdi, [rbp - TGFL_OBJ]
    mov esi, 3
    call builtin_getattr        ; err: release key first
    push rax
    sub rsp, 8
    mov rdi, [rbp - TGFL_KEY]
    call obj_decref
    add rsp, 8
    pop rax
    ERR_NULL .failed
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .try_attr_loop
    ; Call get_loop()
    push rax
    sub rsp, 8
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call obj_call_n             ; err: decref method first
    mov r8, rax
    add rsp, 8
    pop rdi
    push r8
    sub rsp, 8
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    leave
    ret

.try_attr_loop:
    DECREF_V rax, rcx
    lea rdi, [rel tn_attr_loop]
    call str_from_cstr_heap
    mov [rbp - TGFL_KEY], rax
    lea rdi, [rbp - TGFL_OBJ]
    mov esi, 2
    call builtin_getattr        ; err: release key first
    push rax
    sub rsp, 8
    mov rdi, [rbp - TGFL_KEY]
    call obj_decref
    add rsp, 8
    pop rax
    leave
    ret
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_get_future_loop

;; ============================================================================
;; task_step, task_step_impl, task_step_handle_result, task_eager_start, task_wakeup
;; ============================================================================

;; async_task_step(rdi = PyTaskObject*, rsi = exc Value or 0) -> owned None or 0
;; Fails: 0
TS_TASK equ 8
TS_EXC  equ 16
TS_A1   equ 24                  ; [rbp-32]=loop, [rbp-24]=task
TS_A0   equ 32
TS_RES  equ 40
TS_SAVED equ 48
TS_FRAME equ 48
DEF_FUNC_LOCAL async_task_step, TS_FRAME
    mov [rbp - TS_TASK], rdi
    mov [rbp - TS_EXC], rsi
    mov rax, [rdi + PyTaskObject.fut_loop]
    mov [rbp - TS_A0], rax
    mov [rbp - TS_A1], rdi
    lea rdi, [rbp - TS_A0]
    mov esi, 2
    call async_enter_task
    ERR_NULL .failed
    DECREF_V rax, rcx

    mov rdi, [rbp - TS_TASK]
    mov rsi, [rbp - TS_EXC]
    call async_task_step_impl
    ERR_NULL .step_failed
    mov [rbp - TS_RES], rax

    lea rdi, [rbp - TS_A0]
    mov esi, 2
    call async_leave_task
    ERR_NULL .leave_failed
    DECREF_V rax, rcx
    mov rax, [rbp - TS_RES]
    leave
    ret

.leave_failed:
    mov rdi, [rbp - TS_RES]
    DECREF_V rdi, rcx
    xor eax, eax
    leave
    ret

.step_failed:
    call exc_fetch
    mov [rbp - TS_SAVED], rax
    lea rdi, [rbp - TS_A0]
    mov esi, 2
    call async_leave_task       ; err: preserve original exception if leave also raises
    test rax, rax
    jz .leave_also_failed
    DECREF_V rax, rcx
    mov rdi, [rbp - TS_SAVED]
    call exc_restore
    xor eax, eax
    leave
    ret
.leave_also_failed:
    ; Keep original exception as context if leave raised, or restore original.
    mov rdi, [rbp - TS_SAVED]
    call exc_restore
.failed:
    xor eax, eax
    leave
    ret
END_FUNC async_task_step

;; task_extract_stopiter_value(rdi = owned StopIteration exc) -> owned value Value
;; Consumes the StopIteration exception.
;; Fails: 0
TESV_EXC equ 24                 ; [rbp-24]=exc, [rbp-16]=key
TESV_KEY equ 16
TESV_FRAME equ 32
DEF_FUNC_LOCAL task_extract_stopiter_value, TESV_FRAME
    mov [rbp - TESV_EXC], rdi
    lea rdi, [rel tn_value]
    call str_from_cstr_heap
    mov [rbp - TESV_KEY], rax
    lea rdi, [rbp - TESV_EXC]
    mov esi, 2
    call builtin_getattr        ; err: release temps before returning
    push rax
    sub rsp, 8
    mov rdi, [rbp - TESV_KEY]
    call obj_decref
    mov rdi, [rbp - TESV_EXC]
    call obj_decref
    add rsp, 8
    pop rax
    leave
    ret
END_FUNC task_extract_stopiter_value

;; async_task_step_impl(rdi = PyTaskObject*, rsi = exc Value or 0) -> owned None or 0
;; Fails: 0
TSI_TASK   equ 8
TSI_EXC    equ 16
TSI_OWNEXC equ 24
TSI_CORO   equ 32
TSI_RETVAL equ 40
TSI_A1     equ 48               ; [rbp-56]=coro, [rbp-48]=exc
TSI_A0     equ 56
TSI_FRAME  equ 64
DEF_FUNC_LOCAL async_task_step_impl, TSI_FRAME
    mov [rbp - TSI_TASK], rdi
    mov [rbp - TSI_EXC], rsi
    mov qword [rbp - TSI_OWNEXC], 0

    cmp dword [rdi + PyTaskObject.fut_state], FUT_STATE_PENDING
    jne .already_done

    cmp dword [rdi + PyTaskObject.task_must_cancel], 0
    je .cancel_checked
    mov rax, [rbp - TSI_EXC]
    test rax, rax
    jz .make_cancel_exc
    ; Check isinstance(exc, CancelledError)
    call async_get_cancelled_error
    ERR_NULL .failed
    mov rdi, [rbp - TSI_EXC]
    mov rsi, rax
    call exc_isinstance         ; err: check for -1
    ERR_M1 .failed
    test eax, eax
    jnz .clear_must_cancel
.make_cancel_exc:
    mov rdi, [rbp - TSI_TASK]
    call future_create_cancelled_error
    ERR_NULL .failed
    mov [rbp - TSI_EXC], rax
    mov [rbp - TSI_OWNEXC], rax
.clear_must_cancel:
    mov rdi, [rbp - TSI_TASK]
    mov dword [rdi + PyTaskObject.task_must_cancel], 0

.cancel_checked:
    mov rdi, [rbp - TSI_TASK]
    mov rax, [rdi + PyTaskObject.task_fut_waiter]
    mov qword [rdi + PyTaskObject.task_fut_waiter], 0
    XDECREF_V rax, rcx

    mov rdi, [rbp - TSI_TASK]
    mov rax, [rdi + PyTaskObject.task_coro]
    test rax, rax
    jz .uninit_task
    mov [rbp - TSI_CORO], rax

    ; Drive coroutine: fast path for native coro_type / gen_type.
    V_TEST_PTR rax, rcx
    ja .generic_coro
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel coro_type]
    cmp rcx, rdx
    je .native_coro
    lea rdx, [rel gen_type]
    cmp rcx, rdx
    jne .generic_coro

.native_coro:
    mov rsi, [rbp - TSI_EXC]
    test rsi, rsi
    jnz .native_throw
    mov rdi, rax
    call gen_iternext           ; err: 0 is either normal return or raised exc
    test rax, rax
    jnz .got_yield
    cmp qword [gs:ThreadState.current_exception], 0
    jne .check_exc
    ; Native coroutine returned cleanly: read gi_return_value!
    mov rcx, [rbp - TSI_CORO]
    mov rax, [rcx + PyGenObject.gi_return_value]
    test rax, rax
    jnz .native_have_ret
    LOAD_NONE rax
    jmp .got_return
.native_have_ret:
    INCREF_V rax, rdx
    jmp .got_return

.native_throw:
    mov [rbp - TSI_A0], rax
    mov [rbp - TSI_A1], rsi
    lea rdi, [rbp - TSI_A0]
    mov esi, 2
    call _gen_throw_impl        ; err: handled via .check_exc / StopIteration
    mov [rbp - TSI_RETVAL], rax
    mov rdi, [rbp - TSI_OWNEXC]
    mov qword [rbp - TSI_OWNEXC], 0
    XDECREF_V rdi, rcx
    mov rax, [rbp - TSI_RETVAL]
    test rax, rax
    jnz .got_yield
    jmp .check_exc

.generic_coro:
    mov rdi, rax
    INCREF_V rdi, rcx
    mov rsi, [rbp - TSI_EXC]
    test rsi, rsi
    jnz .generic_throw
    lea rcx, [rel none_singleton]
    mov [rbp - TSI_A0], rcx
    lea rsi, [rel tn_send]
    lea rdx, [rbp - TSI_A0]
    mov ecx, 1
    call async_call_method      ; err: handled via .check_exc
    test rax, rax
    jnz .got_yield
    jmp .check_exc

.generic_throw:
    mov [rbp - TSI_A0], rsi
    lea rsi, [rel tn_throw]
    lea rdx, [rbp - TSI_A0]
    mov ecx, 1
    call async_call_method      ; err: handled via .check_exc
    mov [rbp - TSI_RETVAL], rax
    mov rdi, [rbp - TSI_OWNEXC]
    mov qword [rbp - TSI_OWNEXC], 0
    XDECREF_V rdi, rcx
    mov rax, [rbp - TSI_RETVAL]
    test rax, rax
    jnz .got_yield

.check_exc:
    call exc_fetch
    test rax, rax
    jz .return_none_val
    mov [rbp - TSI_RETVAL], rax

    ; StopIteration -> coroutine returned!
    mov rdi, rax
    lea rsi, [rel exc_StopIteration_type]
    call exc_isinstance         ; err: static type
    test eax, eax
    jz .not_stopiter
    mov rdi, [rbp - TSI_RETVAL]
    call task_extract_stopiter_value
    ERR_NULL .failed
    jmp .got_return

.return_none_val:
    LOAD_NONE rax
.got_return:
    mov [rbp - TSI_RETVAL], rax
    mov rdi, [rbp - TSI_TASK]
    cmp dword [rdi + PyTaskObject.task_must_cancel], 0
    je .set_normal_result
    mov dword [rdi + PyTaskObject.task_must_cancel], 0
    mov rsi, [rdi + PyTaskObject.fut_cancel_msg]
    call future_cancel_impl     ; err: release retval first
    jmp .finish_return
.set_normal_result:
    mov rsi, rax
    call future_set_result_impl ; err: release retval first
.finish_return:
    push rax
    sub rsp, 8
    mov rdi, [rbp - TSI_RETVAL]
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    ERR_M1 .failed
    LOAD_NONE rax
    leave
    ret

.not_stopiter:
    ; CancelledError?
    call async_get_cancelled_error
    ERR_NULL .fail_retval
    mov rdi, [rbp - TSI_RETVAL]
    mov rsi, rax
    call exc_isinstance
    ERR_M1 .fail_retval
    test eax, eax
    jz .other_exc

    ; Store cancelled_exc on task and call future_cancel_impl(task, 0).
    mov rdi, [rbp - TSI_TASK]
    mov rcx, [rdi + PyTaskObject.fut_cancelled_exc]
    mov rax, [rbp - TSI_RETVAL]
    mov [rdi + PyTaskObject.fut_cancelled_exc], rax
    XDECREF_V rcx, rdx
    mov rdi, [rbp - TSI_TASK]
    xor esi, esi
    call future_cancel_impl
    ERR_M1 .failed
    LOAD_NONE rax
    leave
    ret

.other_exc:
    mov rdi, [rbp - TSI_TASK]
    mov rsi, [rbp - TSI_RETVAL]
    call future_set_exception_impl
    ERR_M1 .fail_retval

    ; Re-raise KeyboardInterrupt or SystemExit.
    mov rdi, [rbp - TSI_RETVAL]
    lea rsi, [rel exc_KeyboardInterrupt_type]
    call exc_isinstance         ; err: static type
    test eax, eax
    jnz .reraise_base
    mov rdi, [rbp - TSI_RETVAL]
    lea rsi, [rel exc_SystemExit_type]
    call exc_isinstance         ; err: static type
    test eax, eax
    jnz .reraise_base

    mov rdi, [rbp - TSI_RETVAL]
    call obj_decref
    LOAD_NONE rax
    leave
    ret

.reraise_base:
    mov rdi, [rbp - TSI_RETVAL]
    call exc_install
    xor eax, eax
    leave
    ret

.got_yield:
    mov rdi, [rbp - TSI_TASK]
    mov rsi, rax
    call task_step_handle_result ; err: propagate
    leave
    ret

.already_done:
    lea rdi, [rel tmsg_step_done]
    call str_from_cstr_heap
    mov rdi, rax
    mov rsi, [rbp - TSI_TASK]
    call task_concat_repr
    ERR_NULL .failed
    mov rdi, rax
    lea rsi, [rel tmsg_space]
    call task_concat_cstr
    mov rdi, rax
    mov rsi, [rbp - TSI_EXC]
    test rsi, rsi
    jnz .done_have_exc
    lea rsi, [rel none_singleton]
.done_have_exc:
    call task_concat_repr
    ERR_NULL .failed
    mov [rbp - TSI_RETVAL], rax
    call async_get_invalid_state_error
    ERR_NULL .fail_retval
    mov rdi, rax
    mov rsi, [rbp - TSI_RETVAL]
    call exc_new
    push rax
    sub rsp, 8
    mov rdi, [rbp - TSI_RETVAL]
    call obj_decref
    add rsp, 8
    pop rdi
    call exc_install
    jmp .failed

.uninit_task:
    mov rdi, [rbp - TSI_OWNEXC]
    XDECREF_V rdi, rcx
    FAIL exc_RuntimeError_type, "uninitialized Task object", .failed
.fail_retval:
    mov rdi, [rbp - TSI_RETVAL]
    DECREF_V rdi, rcx
.failed:
    mov rdi, [rbp - TSI_OWNEXC]
    XDECREF_V rdi, rcx
    xor eax, eax
    leave
    ret
END_FUNC async_task_step_impl

;; task_step_handle_result(rdi = PyTaskObject*, rsi = owned yielded Value)
;;   -> owned None or 0 (consumes rsi)
;; Fails: 0
TSHR_TASK equ 8
TSHR_RES  equ 16
TSHR_WK   equ 24
TSHR_A2   equ 32                ; 3-slot scratch array [rbp-48..rbp-25]
TSHR_A1   equ 40
TSHR_A0   equ 48
TSHR_MSG  equ 56
TSHR_FRAME equ 64
DEF_FUNC_LOCAL task_step_handle_result, TSHR_FRAME
    mov [rbp - TSHR_TASK], rdi
    mov [rbp - TSHR_RES], rsi

    ; Self-await check
    cmp rsi, rdi
    je .self_await

    ; Fast path: exact Future or exact Task
    V_TEST_PTR rsi, rax
    ja .check_blocking_attr
    test rsi, rsi
    jz .check_blocking_attr
    mov rax, [rsi + PyObject.ob_type]
    cmp rax, [rel future_type]
    je .fast_future
    cmp rax, [rel async_task_type]
    jne .check_none

.fast_future:
    mov rax, [rsi + PyFutureObject.fut_loop]
    cmp rax, [rdi + PyTaskObject.fut_loop]
    jne .different_loop
    cmp dword [rsi + PyFutureObject.fut_blocking], 0
    je .yield_instead_of_yf
    mov dword [rsi + PyFutureObject.fut_blocking], 0

    call task_wakeup_new
    mov [rbp - TSHR_WK], rax
    mov rdi, [rbp - TSHR_RES]
    mov rsi, rax
    mov rcx, [rbp - TSHR_TASK]
    mov rdx, [rcx + PyTaskObject.task_context]
    call future_add_done_callback_impl ; err: decref wk first
    push rax
    sub rsp, 8
    mov rdi, [rbp - TSHR_WK]
    call obj_decref
    add rsp, 8
    pop rax
    ERR_M1 .fail_res

    ; task._fut_waiter = result (transfer our owned ref!)
    mov rdi, [rbp - TSHR_TASK]
    mov rax, [rbp - TSHR_RES]
    mov [rdi + PyTaskObject.task_fut_waiter], rax
    mov qword [rbp - TSHR_RES], 0

    cmp dword [rdi + PyTaskObject.task_must_cancel], 0
    je .ret_none
    jmp .propagate_cancel

.check_none:
    lea rcx, [rel none_singleton]
    cmp rsi, rcx
    jne .check_blocking_attr
    xor esi, esi
    call task_call_step_soon
    ERR_M1 .fail_res
    mov rax, [rbp - TSHR_RES]   ; return our owned None
    leave
    ret

.check_blocking_attr:
    ; Look up _asyncio_future_blocking with default None.
    mov rax, [rbp - TSHR_RES]
    mov [rbp - TSHR_A0], rax
    lea rdi, [rel tn_future_blocking]
    call str_from_cstr_heap
    mov [rbp - TSHR_A1], rax
    lea rcx, [rel none_singleton]
    mov [rbp - TSHR_A2], rcx
    lea rdi, [rbp - TSHR_A0]
    mov esi, 3
    call builtin_getattr        ; err: release key first
    push rax
    sub rsp, 8
    mov rdi, [rbp - TSHR_A1]
    call obj_decref
    add rsp, 8
    pop rax
    ERR_NULL .fail_res

    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .not_future_compat

    ; Duck-typed Future!
    push rax
    sub rsp, 8
    mov rdi, rax
    call obj_is_true            ; err: decref attr first
    mov r8, rax
    add rsp, 8
    pop rdi
    push r8
    sub rsp, 8
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    ERR_M1 .fail_res
    mov [rbp - TSHR_MSG], rax   ; save blocking bool (0 or 1)

    ; Check loop match
    mov rdi, [rbp - TSHR_RES]
    call task_get_future_loop
    ERR_NULL .fail_res
    mov rcx, [rbp - TSHR_TASK]
    mov rdx, [rcx + PyTaskObject.fut_loop]
    push rax
    sub rsp, 8
    cmp rax, rdx
    sete r8b
    pop rcx                     ; alignment pad
    pop rdi
    push r8
    sub rsp, 8
    DECREF_V rdi, rcx
    add rsp, 8
    pop r8
    test r8b, r8b
    jz .different_loop

    cmp qword [rbp - TSHR_MSG], 0
    je .yield_instead_of_yf

    ; result._asyncio_future_blocking = False
    mov rax, [rbp - TSHR_RES]
    mov [rbp - TSHR_A0], rax
    lea rdi, [rel tn_future_blocking]
    call str_from_cstr_heap
    mov [rbp - TSHR_A1], rax
    lea rcx, [rel bool_false]
    mov [rbp - TSHR_A2], rcx
    lea rdi, [rbp - TSHR_A0]
    mov esi, 3
    call builtin_setattr        ; err: release key first
    push rax
    sub rsp, 8
    mov rdi, [rbp - TSHR_A1]
    call obj_decref
    add rsp, 8
    pop rax
    ERR_NULL .fail_res
    DECREF_V rax, rcx

    ; result.add_done_callback(task._wakeup, context=task._context)
    mov rdi, [rbp - TSHR_TASK]
    call task_wakeup_new
    mov [rbp - TSHR_WK], rax
    mov [rbp - TSHR_A0], rax
    mov rdi, [rbp - TSHR_TASK]
    mov rcx, [rdi + PyTaskObject.task_context]
    mov [rbp - TSHR_A1], rcx
    call async_get_context_kwnames
    ERR_NULL .fail_wk_res
    mov r8, rax
    mov rdi, [rbp - TSHR_RES]
    INCREF_V rdi, rcx
    lea rsi, [rel tn_add_done_cb]
    lea rdx, [rbp - TSHR_A0]
    mov ecx, 2
    call async_call_method_kw   ; err: decref wk first
    push rax
    sub rsp, 8
    mov rdi, [rbp - TSHR_WK]
    call obj_decref
    add rsp, 8
    pop rax
    ERR_NULL .fail_res
    DECREF_V rax, rcx

    ; task._fut_waiter = result (transfer our owned ref!)
    mov rdi, [rbp - TSHR_TASK]
    mov rax, [rbp - TSHR_RES]
    mov [rdi + PyTaskObject.task_fut_waiter], rax
    mov qword [rbp - TSHR_RES], 0

    cmp dword [rdi + PyTaskObject.task_must_cancel], 0
    je .ret_none

.propagate_cancel:
    ; Call result.cancel(msg=cancel_msg) (or positional cancel_msg)
    mov rdi, [rbp - TSHR_TASK]
    mov rcx, [rdi + PyTaskObject.fut_cancel_msg]
    test rcx, rcx
    jnz .have_cmsg
    lea rcx, [rel none_singleton]
.have_cmsg:
    mov [rbp - TSHR_MSG], rcx
    INCREF_V rcx, rdx
    mov [rbp - TSHR_A0], rcx
    mov rdi, [rdi + PyTaskObject.task_fut_waiter]
    INCREF_V rdi, rdx
    lea rsi, [rel tn_cancel]
    lea rdx, [rbp - TSHR_A0]
    mov ecx, 1
    call async_call_method      ; err: release saved cmsg first
    push rax
    sub rsp, 8
    mov rdi, [rbp - TSHR_MSG]
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    ERR_NULL .failed
    push rax
    sub rsp, 8
    mov rdi, rax
    call obj_is_true            ; err: decref return value first
    mov r8, rax
    add rsp, 8
    pop rdi
    push r8
    sub rsp, 8
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    ERR_M1 .failed
    test eax, eax
    jz .ret_none
    mov rdi, [rbp - TSHR_TASK]
    mov dword [rdi + PyTaskObject.task_must_cancel], 0
.ret_none:
    LOAD_NONE rax
    leave
    ret

.not_future_compat:
    DECREF_V rax, rcx
    ; Generator check
    mov rsi, [rbp - TSHR_RES]
    V_TEST_PTR rsi, rax
    ja .bad_yield
    test rsi, rsi
    jz .bad_yield
    mov rdi, [rsi + PyObject.ob_type]
    lea rsi, [rel gen_type]
    call type_is_subtype
    test eax, eax
    jnz .yield_gen

.bad_yield:
    lea rdi, [rel tmsg_bad_yield]
    call str_from_cstr_heap
    mov rdi, rax
    mov rsi, [rbp - TSHR_RES]
    call task_concat_repr
    ERR_NULL .fail_res
    jmp .schedule_err_and_drop_res

.self_await:
    lea rdi, [rel tmsg_self_await]
    call str_from_cstr_heap
    mov rdi, rax
    mov rsi, [rbp - TSHR_TASK]
    call task_concat_repr
    ERR_NULL .fail_res
    jmp .schedule_err_and_drop_res

.yield_instead_of_yf:
    lea rdi, [rel tmsg_yield_fut_1]
    call str_from_cstr_heap
    mov rdi, rax
    mov rsi, [rbp - TSHR_TASK]
    call task_concat_repr
    ERR_NULL .fail_res
    mov rdi, rax
    lea rsi, [rel tmsg_with]
    call task_concat_cstr
    mov rdi, rax
    mov rsi, [rbp - TSHR_RES]
    call task_concat_repr
    ERR_NULL .fail_res
    jmp .schedule_err_and_drop_res

.yield_gen:
    lea rdi, [rel tmsg_yield_gen_1]
    call str_from_cstr_heap
    mov rdi, rax
    mov rsi, [rbp - TSHR_TASK]
    call task_concat_repr
    ERR_NULL .fail_res
    mov rdi, rax
    lea rsi, [rel tmsg_with]
    call task_concat_cstr
    mov rdi, rax
    mov rsi, [rbp - TSHR_RES]
    call task_concat_repr
    ERR_NULL .fail_res
    jmp .schedule_err_and_drop_res

.different_loop:
    lea rdi, [rel tmsg_diff_loop_1]
    call str_from_cstr_heap
    mov rdi, rax
    mov rsi, [rbp - TSHR_TASK]
    call task_concat_repr
    ERR_NULL .fail_res
    mov rdi, rax
    lea rsi, [rel tmsg_diff_loop_2]
    call task_concat_cstr
    mov rdi, rax
    mov rsi, [rbp - TSHR_RES]
    call task_concat_repr
    ERR_NULL .fail_res
    mov rdi, rax
    lea rsi, [rel tmsg_diff_loop_3]
    call task_concat_cstr

.schedule_err_and_drop_res:
    mov [rbp - TSHR_MSG], rax
    mov rdi, [rbp - TSHR_RES]
    mov qword [rbp - TSHR_RES], 0
    DECREF_V rdi, rcx
    mov rdi, [rbp - TSHR_TASK]
    mov rsi, [rbp - TSHR_MSG]
    call task_schedule_runtime_error ; err: propagate
    leave
    ret

.fail_wk_res:
    mov rdi, [rbp - TSHR_WK]
    call obj_decref
.fail_res:
    mov rdi, [rbp - TSHR_RES]
    XDECREF_V rdi, rcx
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_step_handle_result

;; task_eager_start(rdi = PyTaskObject*) -> 0 / -1
;; Fails: -1
TES_TASK  equ 8
TES_PREV  equ 16
TES_WRAP  equ 24
TES_A1    equ 32                ; [rbp-40]=loop/arg0, [rbp-32]=task/arg1
TES_A0    equ 40
TES_RET   equ 48
TES_EXC   equ 56
TES_FRAME equ 64
DEF_FUNC_LOCAL task_eager_start, TES_FRAME
    mov [rbp - TES_TASK], rdi
    mov qword [rbp - TES_RET], 0
    mov qword [rbp - TES_EXC], 0

    ; prev = _swap_current_task(loop, task)
    mov rax, [rdi + PyTaskObject.fut_loop]
    mov [rbp - TES_A0], rax
    mov [rbp - TES_A1], rdi
    lea rdi, [rbp - TES_A0]
    mov esi, 2
    call async_swap_task
    ERR_NULL .failed
    mov [rbp - TES_PREV], rax

    ; _register_eager_task(task)
    mov rdi, [rbp - TES_TASK]
    mov [rbp - TES_A0], rdi
    lea rdi, [rbp - TES_A0]
    mov esi, 1
    call async_register_eager_task
    ERR_NULL .fail_restore_prev
    DECREF_V rax, rcx

    ; wrapper = TaskStepMethWrapper(task, 0, eager=1)
    mov rdi, [rbp - TES_TASK]
    xor esi, esi
    mov edx, 1
    call task_step_wrapper_new
    mov [rbp - TES_WRAP], rax

    ; task_context.run(wrapper)
    mov [rbp - TES_A0], rax
    mov rdi, [rbp - TES_TASK]
    mov rdi, [rdi + PyTaskObject.task_context]
    INCREF_V rdi, rcx
    lea rsi, [rel tn_run]
    lea rdx, [rbp - TES_A0]
    mov ecx, 1
    call async_call_method      ; err: save exc and still restore state
    test rax, rax
    jnz .step_ok
    call exc_fetch
    mov [rbp - TES_EXC], rax
    mov qword [rbp - TES_RET], -1
    jmp .cleanup_eager
.step_ok:
    DECREF_V rax, rcx

.cleanup_eager:
    mov rdi, [rbp - TES_WRAP]
    call obj_decref

    ; _unregister_eager_task(task)
    mov rdi, [rbp - TES_TASK]
    mov [rbp - TES_A0], rdi
    lea rdi, [rbp - TES_A0]
    mov esi, 1
    call async_unregister_eager_task ; err: preserve first failure
    test rax, rax
    jz .unreg_err
    DECREF_V rax, rcx
    jmp .swap_back
.unreg_err:
    cmp qword [rbp - TES_RET], 0
    jne .drop_unreg_err
    call exc_fetch
    mov [rbp - TES_EXC], rax
    mov qword [rbp - TES_RET], -1
    jmp .swap_back
.drop_unreg_err:
    call exc_fetch
    XDECREF_V rax, rcx

.swap_back:
    mov rdi, [rbp - TES_TASK]
    mov rax, [rdi + PyTaskObject.fut_loop]
    mov [rbp - TES_A0], rax
    mov rax, [rbp - TES_PREV]
    mov [rbp - TES_A1], rax
    lea rdi, [rbp - TES_A0]
    mov esi, 2
    call async_swap_task        ; err: preserve first failure
    test rax, rax
    jz .swap_err
    DECREF_V rax, rcx
    jmp .drop_prev
.swap_err:
    cmp qword [rbp - TES_RET], 0
    jne .drop_swap_err
    call exc_fetch
    mov [rbp - TES_EXC], rax
    mov qword [rbp - TES_RET], -1
    jmp .drop_prev
.drop_swap_err:
    call exc_fetch
    XDECREF_V rax, rcx

.drop_prev:
    mov rdi, [rbp - TES_PREV]
    DECREF_V rdi, rcx

    mov rdi, [rbp - TES_TASK]
    cmp dword [rdi + PyTaskObject.fut_state], FUT_STATE_PENDING
    jne .clear_coro
    ; Still pending -> register in scheduled_tasks
    mov [rbp - TES_A0], rdi
    lea rdi, [rbp - TES_A0]
    mov esi, 1
    call async_register_task    ; err: preserve first failure
    test rax, rax
    jz .reg_err
    DECREF_V rax, rcx
    jmp .finish
.reg_err:
    cmp qword [rbp - TES_RET], 0
    jne .drop_reg_err
    call exc_fetch
    mov [rbp - TES_EXC], rax
    mov qword [rbp - TES_RET], -1
    jmp .finish
.drop_reg_err:
    call exc_fetch
    XDECREF_V rax, rcx
    jmp .finish

.clear_coro:
    mov rdi, [rbp - TES_TASK]
    mov rax, [rdi + PyTaskObject.task_coro]
    mov qword [rdi + PyTaskObject.task_coro], 0
    XDECREF_V rax, rcx

.finish:
    mov rdi, [rbp - TES_EXC]
    test rdi, rdi
    jz .ret_status
    call exc_restore
.ret_status:
    mov rax, [rbp - TES_RET]
    leave
    ret

.fail_restore_prev:
    call exc_fetch
    mov [rbp - TES_EXC], rax
    mov rdi, [rbp - TES_TASK]
    mov rax, [rdi + PyTaskObject.fut_loop]
    mov [rbp - TES_A0], rax
    mov rax, [rbp - TES_PREV]
    mov [rbp - TES_A1], rax
    lea rdi, [rbp - TES_A0]
    mov esi, 2
    call async_swap_task        ; err: best-effort restore
    XDECREF_V rax, rcx
    mov rdi, [rbp - TES_PREV]
    DECREF_V rdi, rcx
    mov rdi, [rbp - TES_EXC]
    call exc_restore
.failed:
    mov rax, -1
    leave
    ret
END_FUNC task_eager_start

;; async_task_wakeup(rdi = PyTaskObject*, rsi = future Value) -> owned None or 0
;; Fails: 0
TW_TASK equ 8
TW_VAL  equ 16
TW_FRAME equ 16
DEF_FUNC_LOCAL async_task_wakeup, TW_FRAME
    mov [rbp - TW_TASK], rdi
    V_TEST_PTR rsi, rax
    ja .generic
    test rsi, rsi
    jz .generic
    mov rax, [rsi + PyObject.ob_type]
    cmp rax, [rel future_type]
    je .fast
    cmp rax, [rel async_task_type]
    jne .generic
.fast:
    mov rdi, rsi
    call future_get_result_impl ; err: 0 means exception is pending
    test rax, rax
    jz .fetch_and_step
    test edx, edx
    jnz .step_with_exc_val
    DECREF_V rax, rcx
    mov rdi, [rbp - TW_TASK]
    xor esi, esi
    call async_task_step        ; err: propagate
    leave
    ret

.generic:
    mov rdi, rsi
    INCREF_V rdi, rcx
    lea rsi, [rel tn_result]
    xor edx, edx
    xor ecx, ecx
    call async_call_method      ; err: 0 means exception is pending
    test rax, rax
    jz .fetch_and_step
    DECREF_V rax, rcx
    mov rdi, [rbp - TW_TASK]
    xor esi, esi
    call async_task_step        ; err: propagate
    leave
    ret

.fetch_and_step:
    call exc_fetch
.step_with_exc_val:
    mov [rbp - TW_VAL], rax
    mov rdi, [rbp - TW_TASK]
    mov rsi, rax
    call async_task_step        ; err: release exc after step
    push rax
    sub rsp, 8
    mov rdi, [rbp - TW_VAL]
    XDECREF_V rdi, rcx
    add rsp, 8
    pop rax
    leave
    ret
END_FUNC async_task_wakeup

;; ============================================================================
;; Task.__del__ finalizer
;; ============================================================================

;; task_finalize_impl(rdi = PyTaskObject*) -> void
TFIN_TASK equ 8
TFIN_EXC  equ 16
TFIN_CTX  equ 24
TFIN_KEY  equ 32
TFIN_MSG  equ 40
TFIN_FRAME equ 48
DEF_FUNC_LOCAL task_finalize_impl, TFIN_FRAME
    mov [rbp - TFIN_TASK], rdi
    cmp dword [rdi + PyTaskObject.fut_state], FUT_STATE_PENDING
    jne .call_future_fin
    cmp dword [rdi + PyTaskObject.task_log_destroy], 0
    je .call_future_fin
    cmp qword [rdi + PyTaskObject.fut_loop], 0
    je .call_future_fin

    call exc_fetch
    mov [rbp - TFIN_EXC], rax

    call dict_new
    mov [rbp - TFIN_CTX], rax

    lea rdi, [rel tmsg_destroyed_pending]
    call str_from_cstr_heap
    mov [rbp - TFIN_MSG], rax
    lea rdi, [rel tkey_message]
    call str_from_cstr_heap
    mov [rbp - TFIN_KEY], rax
    mov rdi, [rbp - TFIN_CTX]
    mov rsi, rax
    mov rdx, [rbp - TFIN_MSG]
    call dict_set_str
    mov rdi, [rbp - TFIN_KEY]
    call obj_decref
    mov rdi, [rbp - TFIN_MSG]
    call obj_decref

    lea rdi, [rel tkey_task]
    call str_from_cstr_heap
    mov [rbp - TFIN_KEY], rax
    mov rdi, [rbp - TFIN_CTX]
    mov rsi, rax
    mov rdx, [rbp - TFIN_TASK]
    call dict_set_str
    mov rdi, [rbp - TFIN_KEY]
    call obj_decref

    mov rcx, [rbp - TFIN_TASK]
    mov rdx, [rcx + PyTaskObject.fut_source_tb]
    test rdx, rdx
    jz .call_handler
    lea rdi, [rel tkey_source_tb]
    call str_from_cstr_heap
    mov [rbp - TFIN_KEY], rax
    mov rdi, [rbp - TFIN_CTX]
    mov rsi, rax
    mov rcx, [rbp - TFIN_TASK]
    mov rdx, [rcx + PyTaskObject.fut_source_tb]
    call dict_set_str
    mov rdi, [rbp - TFIN_KEY]
    call obj_decref

.call_handler:
    mov rdi, [rbp - TFIN_TASK]
    mov rdi, [rdi + PyTaskObject.fut_loop]
    INCREF_V rdi, rcx
    lea rsi, [rel tn_call_exc_handler]
    lea rdx, [rbp - TFIN_CTX]
    mov ecx, 1
    call async_call_method      ; err: print unraisable if handler fails
    test rax, rax
    jz .unraisable
    DECREF_V rax, rcx
    jmp .cleanup
.unraisable:
    mov rdi, [gs:ThreadState.current_exception]
    test rdi, rdi
    jz .cleanup
    mov rsi, [rbp - TFIN_TASK]
    call traceback_print_unraisable
    mov rdi, [gs:ThreadState.current_exception]
    mov qword [gs:ThreadState.current_exception], 0
    call obj_decref
.cleanup:
    mov rdi, [rbp - TFIN_CTX]
    call obj_decref
    mov rdi, [rbp - TFIN_EXC]
    call exc_restore

.call_future_fin:
    mov rdi, [rbp - TFIN_TASK]
    call future_finalize_impl
    leave
    ret
END_FUNC task_finalize_impl

;; ============================================================================
;; Task Python methods
;; ============================================================================

;; Task.__init__(self, coro, *, loop=None, name=None, context=None, eager_start=False) -> None
;; Fails: 0
TI_SELF  equ 8
TI_CORO  equ 16
TI_LOOP  equ 24
TI_NAME  equ 32
TI_CTX   equ 40
TI_EAGER equ 48
TI_ARGS  equ 56
TI_KW    equ 64
TI_NKW   equ 72
TI_NPOS  equ 80
TI_IDX   equ 88
TI_TMP   equ 96
TI_FRAME equ 96
DEF_FUNC_LOCAL task_method_init, TI_FRAME
    mov rax, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov [rbp - TI_ARGS], rdi
    mov [rbp - TI_KW], rax
    mov qword [rbp - TI_LOOP], 0
    mov qword [rbp - TI_NAME], 0
    mov qword [rbp - TI_CTX], 0
    mov qword [rbp - TI_EAGER], 0
    mov qword [rbp - TI_NKW], 0

    test rax, rax
    jz .no_kw
    mov rcx, [rax + PyTupleObject.ob_size]
    mov [rbp - TI_NKW], rcx
    sub rsi, rcx
.no_kw:
    mov [rbp - TI_NPOS], rsi
    cmp rsi, 1
    jb .arity
    cmp rsi, 2
    ja .arity

    mov r8, [rdi]               ; self
    mov [rbp - TI_SELF], r8
    mov qword [rbp - TI_CORO], 0
    cmp rsi, 2
    jne .parse_kw
    mov r8, [rdi + 8]           ; coro
    mov [rbp - TI_CORO], r8

.parse_kw:
    mov qword [rbp - TI_IDX], 0
.kw_loop:
    mov rcx, [rbp - TI_IDX]
    cmp rcx, [rbp - TI_NKW]
    jge .kw_done
    mov rax, [rbp - TI_KW]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdx, [rax + rcx * 8]    ; kw name str
    mov [rbp - TI_TMP], rdx
    mov r8, [rbp - TI_NPOS]
    add r8, rcx
    mov r9, [rbp - TI_ARGS]
    mov r9, [r9 + r8 * 8]       ; kw value

    ; Check "coro"
    lea rdi, [rdx + PyStrObject.data]
    lea rsi, [rel tkw_coro]
    push r9
    sub rsp, 8
    call ap_strcmp
    add rsp, 8
    pop r9
    test eax, eax
    jnz .try_loop
    cmp qword [rbp - TI_CORO], 0
    jne .dup_coro
    mov [rbp - TI_CORO], r9
    jmp .kw_next

.try_loop:
    mov rdx, [rbp - TI_TMP]
    lea rdi, [rdx + PyStrObject.data]
    lea rsi, [rel tkw_loop]
    push r9
    sub rsp, 8
    call ap_strcmp
    add rsp, 8
    pop r9
    test eax, eax
    jnz .try_name
    mov [rbp - TI_LOOP], r9
    jmp .kw_next

.try_name:
    mov rdx, [rbp - TI_TMP]
    lea rdi, [rdx + PyStrObject.data]
    lea rsi, [rel tkw_name]
    push r9
    sub rsp, 8
    call ap_strcmp
    add rsp, 8
    pop r9
    test eax, eax
    jnz .try_ctx
    mov [rbp - TI_NAME], r9
    jmp .kw_next

.try_ctx:
    mov rdx, [rbp - TI_TMP]
    lea rdi, [rdx + PyStrObject.data]
    lea rsi, [rel tkw_context]
    push r9
    sub rsp, 8
    call ap_strcmp
    add rsp, 8
    pop r9
    test eax, eax
    jnz .try_eager
    mov [rbp - TI_CTX], r9
    jmp .kw_next

.try_eager:
    mov rdx, [rbp - TI_TMP]
    lea rdi, [rdx + PyStrObject.data]
    lea rsi, [rel tkw_eager_start]
    push r9
    sub rsp, 8
    call ap_strcmp
    add rsp, 8
    pop r9
    test eax, eax
    jnz .bad_kw
    mov rdi, r9
    call obj_is_true
    ERR_M1 .failed
    mov [rbp - TI_EAGER], rax

.kw_next:
    inc qword [rbp - TI_IDX]
    jmp .kw_loop

.kw_done:
    cmp qword [rbp - TI_CORO], 0
    je .missing_coro

    ; Initialize Future base first (so __del__ sees a valid Future if coro check raises).
    mov rdi, [rbp - TI_SELF]
    mov dword [rdi + PyTaskObject.task_log_destroy], 0
    mov rsi, [rbp - TI_LOOP]
    call future_init_impl
    ERR_M1 .failed

    ; Validate coro via is_coroutine.
    mov rdi, [rbp - TI_CORO]
    call task_is_coroutine
    ERR_M1 .failed
    test eax, eax
    jz .not_coro

    ; Context: copy_context() if None/omitted, else use provided.
    mov rax, [rbp - TI_CTX]
    test rax, rax
    jz .copy_ctx
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .copy_ctx
    INCREF_V rax, rcx
    jmp .store_ctx
.copy_ctx:
    call async_get_copy_context
    ERR_NULL .failed
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call obj_call_n
    ERR_NULL .failed
.store_ctx:
    mov rdi, [rbp - TI_SELF]
    mov rcx, [rdi + PyTaskObject.task_context]
    mov [rdi + PyTaskObject.task_context], rax
    XDECREF_V rcx, rdx

    ; Clear waiter, reset counters, store coro.
    mov rdi, [rbp - TI_SELF]
    mov rcx, [rdi + PyTaskObject.task_fut_waiter]
    mov qword [rdi + PyTaskObject.task_fut_waiter], 0
    XDECREF_V rcx, rdx
    mov dword [rdi + PyTaskObject.task_must_cancel], 0
    mov dword [rdi + PyTaskObject.task_log_destroy], 1
    mov dword [rdi + PyTaskObject.task_num_cancels], 0

    mov rax, [rbp - TI_CORO]
    INCREF_V rax, rcx
    mov rdx, [rdi + PyTaskObject.task_coro]
    mov [rdi + PyTaskObject.task_coro], rax
    XDECREF_V rdx, rcx

    ; Task name: deferred int counter if None/omitted, else str(name).
    mov rax, [rbp - TI_NAME]
    test rax, rax
    jz .auto_name
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .auto_name
    V_TEST_PTR rax, rcx
    ja .conv_name
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .conv_name
    INCREF rax
    jmp .store_name
.conv_name:
    mov rdi, rax
    call obj_str
    ERR_NULL .failed
    jmp .store_name
.auto_name:
    mov rax, [rel task_name_counter]
    inc rax
    mov [rel task_name_counter], rax
    V_PACK_I64 rax, rcx
.store_name:
    mov rdi, [rbp - TI_SELF]
    mov rcx, [rdi + PyTaskObject.task_name]
    mov [rdi + PyTaskObject.task_name], rax
    XDECREF_V rcx, rdx

    ; Eager start check
    cmp qword [rbp - TI_EAGER], 0
    je .schedule_normal
    mov rdi, [rbp - TI_SELF]
    mov rdi, [rdi + PyTaskObject.fut_loop]
    INCREF_V rdi, rcx
    lea rsi, [rel tn_is_running]
    xor edx, edx
    xor ecx, ecx
    call async_call_method
    ERR_NULL .failed
    lea rcx, [rel bool_true]
    cmp rax, rcx
    sete r8b
    push r8
    sub rsp, 8
    DECREF_V rax, rcx
    add rsp, 8
    pop r8
    test r8b, r8b
    jz .schedule_normal
    mov rdi, [rbp - TI_SELF]
    call task_eager_start
    ERR_M1 .failed
    LOAD_NONE rax
    leave
    ret

.schedule_normal:
    mov rdi, [rbp - TI_SELF]
    xor esi, esi
    call task_call_step_soon
    ERR_M1 .failed
    mov rdi, [rbp - TI_SELF]
    mov [rbp - TI_TMP], rdi
    lea rdi, [rbp - TI_TMP]
    mov esi, 1
    call async_register_task
    ERR_NULL .failed
    DECREF_V rax, rcx
    LOAD_NONE rax
    leave
    ret

.not_coro:
    mov rdi, [rbp - TI_SELF]
    mov dword [rdi + PyTaskObject.task_log_destroy], 0
    lea rdi, [rel tmsg_coro_expected]
    call str_from_cstr_heap
    mov rdi, rax
    mov rsi, [rbp - TI_CORO]
    call task_concat_repr
    ERR_NULL .failed
    mov [rbp - TI_TMP], rax
    lea rdi, [rel exc_TypeError_type]
    mov rsi, rax
    call exc_new
    push rax
    sub rsp, 8
    mov rdi, [rbp - TI_TMP]
    call obj_decref
    add rsp, 8
    pop rdi
    call exc_install
    jmp .failed

.dup_coro:
    FAIL exc_TypeError_type, "Task.__init__() got multiple values for argument 'coro'", .failed
.missing_coro:
    FAIL exc_TypeError_type, "Task.__init__() missing required argument 'coro'", .failed
.arity:
    FAIL exc_TypeError_type, "Task.__init__() takes 2 positional arguments", .failed
.bad_kw:
    FAIL exc_TypeError_type, "Task.__init__() got an unexpected keyword argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_method_init

;; Task.__del__(self) -> None
;; Fails: 0
DEF_FUNC_LOCAL task_method_del
    NO_KEYWORDS_RET "__del__() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    call task_finalize_impl
    LOAD_NONE rax
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "__del__() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_method_del

;; Task.__repr__(self) -> str
;; Fails: 0
TR_ARG equ 8
TR_FRAME equ 16
DEF_FUNC_LOCAL task_method_repr, TR_FRAME
    NO_KEYWORDS_RET "__repr__() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rax, [rdi]
    mov [rbp - TR_ARG], rax
    call async_get_task_repr
    ERR_NULL .failed
    mov rdi, rax
    lea rsi, [rbp - TR_ARG]
    mov edx, 1
    call obj_call_n             ; err: propagate
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "__repr__() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_method_repr

;; Task.set_result(self, result) -> raises RuntimeError
;; Fails: 0
DEF_FUNC_LOCAL task_method_set_result
    NO_KEYWORDS_RET "set_result() takes no keyword arguments", .failed
    cmp rsi, 2
    jne .arity
    FAIL exc_RuntimeError_type, "Task does not support set_result operation", .failed
.arity:
    FAIL exc_TypeError_type, "set_result() takes exactly one argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_method_set_result

;; Task.set_exception(self, exception) -> raises RuntimeError
;; Fails: 0
DEF_FUNC_LOCAL task_method_set_exception
    NO_KEYWORDS_RET "set_exception() takes no keyword arguments", .failed
    cmp rsi, 2
    jne .arity
    FAIL exc_RuntimeError_type, "Task does not support set_exception operation", .failed
.arity:
    FAIL exc_TypeError_type, "set_exception() takes exactly one argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_method_set_exception

;; Task.cancel(self, msg=None) -> bool
;; Fails: 0
TC_SELF equ 8
TC_MSG  equ 16
TC_FRAME equ 16
DEF_FUNC_LOCAL task_method_cancel, TC_FRAME
    mov rax, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov r8, [rdi]
    mov [rbp - TC_SELF], r8
    lea r9, [rel none_singleton]
    mov [rbp - TC_MSG], r9

    test rax, rax
    jz .no_kw
    mov rcx, [rax + PyTupleObject.ob_size]
    cmp rcx, 1
    ja .bad_kw
    test rcx, rcx
    jz .no_kw
    cmp rsi, 2
    jne .arity
    mov r9, [rdi + 8]
    mov [rbp - TC_MSG], r9
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rdx, [rdx]
    lea rdi, [rdx + PyStrObject.data]
    lea rsi, [rel tkw_msg]
    call ap_strcmp
    test eax, eax
    jnz .bad_kw
    jmp .do_cancel

.no_kw:
    cmp rsi, 1
    je .do_cancel
    cmp rsi, 2
    jne .arity
    mov r9, [rdi + 8]
    mov [rbp - TC_MSG], r9

.do_cancel:
    mov rdi, [rbp - TC_SELF]
    mov dword [rdi + PyTaskObject.fut_log_tb], 0
    cmp dword [rdi + PyTaskObject.fut_state], FUT_STATE_PENDING
    jne .ret_false

    inc dword [rdi + PyTaskObject.task_num_cancels]

    mov rax, [rdi + PyTaskObject.task_fut_waiter]
    test rax, rax
    jz .mark_must_cancel

    ; Call waiter.cancel(msg)
    mov rdi, rax
    INCREF_V rdi, rcx
    lea rsi, [rel tn_cancel]
    lea rdx, [rbp - TC_MSG]
    mov ecx, 1
    call async_call_method
    ERR_NULL .failed
    push rax
    sub rsp, 8
    mov rdi, rax
    call obj_is_true            ; err: decref res first
    mov r8, rax
    add rsp, 8
    pop rdi
    push r8
    sub rsp, 8
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    ERR_M1 .failed
    test eax, eax
    jnz .ret_true

.mark_must_cancel:
    mov rdi, [rbp - TC_SELF]
    mov dword [rdi + PyTaskObject.task_must_cancel], 1
    mov rsi, [rbp - TC_MSG]
    INCREF_V rsi, rcx
    mov rdx, [rdi + PyTaskObject.fut_cancel_msg]
    mov [rdi + PyTaskObject.fut_cancel_msg], rsi
    XDECREF_V rdx, rcx
.ret_true:
    RET_TRUE
    leave
    ret
.ret_false:
    RET_FALSE
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "cancel() takes at most 1 argument", .failed
.bad_kw:
    FAIL exc_TypeError_type, "cancel() got an unexpected keyword argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_method_cancel

;; Task.cancelling(self) -> int
;; Fails: 0
DEF_FUNC_LOCAL task_method_cancelling
    NO_KEYWORDS_RET "cancelling() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    movsxd rax, dword [rdi + PyTaskObject.task_num_cancels]
    V_PACK_I64 rax, rcx
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "cancelling() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_method_cancelling

;; Task.uncancel(self) -> int
;; Fails: 0
DEF_FUNC_LOCAL task_method_uncancel
    NO_KEYWORDS_RET "uncancel() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    mov eax, [rdi + PyTaskObject.task_num_cancels]
    test eax, eax
    jle .pack
    dec eax
    mov [rdi + PyTaskObject.task_num_cancels], eax
.pack:
    movsxd rax, eax
    V_PACK_I64 rax, rcx
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "uncancel() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_method_uncancel

;; Task.get_coro(self) -> coro or None
;; Fails: 0
DEF_FUNC_LOCAL task_method_get_coro
    NO_KEYWORDS_RET "get_coro() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    mov rax, [rdi + PyTaskObject.task_coro]
    test rax, rax
    jz .ret_none
    INCREF_V rax, rcx
    leave
    ret
.ret_none:
    LOAD_NONE rax
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "get_coro() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_method_get_coro

;; Task.get_context(self) -> Context or None
;; Fails: 0
DEF_FUNC_LOCAL task_method_get_context
    NO_KEYWORDS_RET "get_context() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    mov rax, [rdi + PyTaskObject.task_context]
    test rax, rax
    jz .ret_none
    INCREF_V rax, rcx
    leave
    ret
.ret_none:
    LOAD_NONE rax
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "get_context() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_method_get_context

;; Task.get_name(self) -> str or None
;; Lazily formats deferred integer task counters into "Task-<N>".
;; Fails: 0
TGN_SELF equ 8
TGN_PREF equ 16
TGN_NUM  equ 24
TGN_FRAME equ 32
DEF_FUNC_LOCAL task_method_get_name, TGN_FRAME
    NO_KEYWORDS_RET "get_name() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    mov [rbp - TGN_SELF], rdi
    mov rax, [rdi + PyTaskObject.task_name]
    test rax, rax
    jz .ret_none
    ; If task_name is an exact str, return it directly.
    V_TEST_PTR rax, rcx
    ja .format_counter
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .format_counter
    INCREF rax
    leave
    ret

.format_counter:
    mov rdi, rax
    call obj_str
    ERR_NULL .failed
    mov [rbp - TGN_NUM], rax
    lea rdi, [rel tmsg_task_prefix]
    call str_from_cstr_heap
    mov [rbp - TGN_PREF], rax
    mov rdi, rax
    mov rsi, [rbp - TGN_NUM]
    call str_concat             ; err: both operands are exact str
    push rax
    sub rsp, 8
    mov rdi, [rbp - TGN_PREF]
    call obj_decref
    mov rdi, [rbp - TGN_NUM]
    call obj_decref
    add rsp, 8
    pop rax
    mov rdi, [rbp - TGN_SELF]
    mov rcx, [rdi + PyTaskObject.task_name]
    mov [rdi + PyTaskObject.task_name], rax
    INCREF rax
    push rax
    sub rsp, 8
    XDECREF_V rcx, rdx
    add rsp, 8
    pop rax
    leave
    ret

.ret_none:
    LOAD_NONE rax
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "get_name() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_method_get_name

;; Task.set_name(self, value) -> None
;; Fails: 0
TSN_SELF equ 8
TSN_FRAME equ 16
DEF_FUNC_LOCAL task_method_set_name, TSN_FRAME
    NO_KEYWORDS_RET "set_name() takes no keyword arguments", .failed
    cmp rsi, 2
    jne .arity
    mov rax, [rdi]
    mov [rbp - TSN_SELF], rax
    mov rax, [rdi + 8]
    V_TEST_PTR rax, rcx
    ja .conv
    test rax, rax
    jz .conv
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .conv
    INCREF rax
    jmp .store
.conv:
    mov rdi, rax
    call obj_str
    ERR_NULL .failed
.store:
    mov rdi, [rbp - TSN_SELF]
    mov rcx, [rdi + PyTaskObject.task_name]
    mov [rdi + PyTaskObject.task_name], rax
    XDECREF_V rcx, rdx
    LOAD_NONE rax
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "set_name() takes exactly one argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_method_set_name

;; Task.get_stack(self, *, limit=None) -> list
;; Fails: 0
TGS_A1   equ 8                  ; [rbp-16]=self, [rbp-8]=limit
TGS_A0   equ 16
TGS_FRAME equ 16
DEF_FUNC_LOCAL task_method_get_stack, TGS_FRAME
    mov rax, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov r8, [rdi]
    mov [rbp - TGS_A0], r8
    lea r9, [rel none_singleton]
    mov [rbp - TGS_A1], r9

    test rax, rax
    jz .no_kw
    mov rcx, [rax + PyTupleObject.ob_size]
    cmp rcx, 1
    ja .bad_kw
    test rcx, rcx
    jz .no_kw
    cmp rsi, 2
    jne .arity
    mov r9, [rdi + 8]
    mov [rbp - TGS_A1], r9
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rdx, [rdx]
    lea rdi, [rdx + PyStrObject.data]
    lea rsi, [rel tkw_limit]
    call ap_strcmp
    test eax, eax
    jnz .bad_kw
    jmp .invoke
.no_kw:
    cmp rsi, 1
    jne .arity
.invoke:
    call async_get_task_get_stack
    ERR_NULL .failed
    mov rdi, rax
    lea rsi, [rbp - TGS_A0]
    mov edx, 2
    call obj_call_n             ; err: propagate
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "get_stack() takes 1 positional argument", .failed
.bad_kw:
    FAIL exc_TypeError_type, "get_stack() got an unexpected keyword argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_method_get_stack

;; Task.print_stack(self, *, limit=None, file=None) -> None
;; Fails: 0
TPS_A2   equ 8                  ; [rbp-24]=self, [rbp-16]=limit, [rbp-8]=file
TPS_A1   equ 16
TPS_A0   equ 24
TPS_KW   equ 32
TPS_NKW  equ 40
TPS_ARGS equ 48
TPS_IDX  equ 56
TPS_TMP  equ 64
TPS_FRAME equ 64
DEF_FUNC_LOCAL task_method_print_stack, TPS_FRAME
    mov rax, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov [rbp - TPS_ARGS], rdi
    mov [rbp - TPS_KW], rax
    mov r8, [rdi]
    mov [rbp - TPS_A0], r8
    lea r9, [rel none_singleton]
    mov [rbp - TPS_A1], r9
    mov [rbp - TPS_A2], r9
    mov qword [rbp - TPS_NKW], 0

    test rax, rax
    jz .no_kw
    mov rcx, [rax + PyTupleObject.ob_size]
    mov [rbp - TPS_NKW], rcx
    sub rsi, rcx
.no_kw:
    cmp rsi, 1
    jne .arity
    mov qword [rbp - TPS_IDX], 0
.kw_loop:
    mov rcx, [rbp - TPS_IDX]
    cmp rcx, [rbp - TPS_NKW]
    jge .invoke
    mov rax, [rbp - TPS_KW]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdx, [rax + rcx * 8]
    mov [rbp - TPS_TMP], rdx
    mov r8, [rbp - TPS_ARGS]
    mov r9, [r8 + 8 + rcx * 8]

    lea rdi, [rdx + PyStrObject.data]
    lea rsi, [rel tkw_limit]
    push r9
    sub rsp, 8
    call ap_strcmp
    add rsp, 8
    pop r9
    test eax, eax
    jnz .try_file
    mov [rbp - TPS_A1], r9
    jmp .kw_next
.try_file:
    mov rdx, [rbp - TPS_TMP]
    lea rdi, [rdx + PyStrObject.data]
    lea rsi, [rel tkw_file]
    push r9
    sub rsp, 8
    call ap_strcmp
    add rsp, 8
    pop r9
    test eax, eax
    jnz .bad_kw
    mov [rbp - TPS_A2], r9
.kw_next:
    inc qword [rbp - TPS_IDX]
    jmp .kw_loop

.invoke:
    call async_get_task_print_stack
    ERR_NULL .failed
    mov rdi, rax
    lea rsi, [rbp - TPS_A0]
    mov edx, 3
    call obj_call_n             ; err: propagate
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "print_stack() takes 1 positional argument", .failed
.bad_kw:
    FAIL exc_TypeError_type, "print_stack() got an unexpected keyword argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_method_print_stack

;; Task._make_cancelled_error(self) -> CancelledError
;; Fails: 0
DEF_FUNC_LOCAL task_method_make_cancelled_error
    NO_KEYWORDS_RET "_make_cancelled_error() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    call future_create_cancelled_error ; err: propagate
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "_make_cancelled_error() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC task_method_make_cancelled_error

;; ============================================================================
;; Task getset descriptors
;; ============================================================================

;; Task._log_destroy_pending getter(rdi = self) -> bool
DEF_FUNC_LOCAL task_get_log_destroy
    cmp dword [rdi + PyTaskObject.task_log_destroy], 0
    je .ret_false
    RET_TRUE
    leave
    ret
.ret_false:
    RET_FALSE
    leave
    ret
END_FUNC task_get_log_destroy

;; Task._log_destroy_pending setter(rdi = self, rsi = val) -> 0 / -1
;; Fails: -1
TLDS_SELF equ 8
TLDS_FRAME equ 16
DEF_FUNC_LOCAL task_set_log_destroy, TLDS_FRAME
    test rsi, rsi
    jz .no_del
    mov [rbp - TLDS_SELF], rdi
    mov rdi, rsi
    call obj_is_true
    ERR_M1 .failed
    mov rdi, [rbp - TLDS_SELF]
    mov [rdi + PyTaskObject.task_log_destroy], eax
    xor eax, eax
    leave
    ret
.no_del:
    FAIL exc_AttributeError_type, "cannot delete attribute", .failed
.failed:
    mov rax, -1
    leave
    ret
END_FUNC task_set_log_destroy

;; Task._must_cancel getter(rdi = self) -> bool
DEF_FUNC_LOCAL task_get_must_cancel
    cmp dword [rdi + PyTaskObject.task_must_cancel], 0
    je .ret_false
    RET_TRUE
    leave
    ret
.ret_false:
    RET_FALSE
    leave
    ret
END_FUNC task_get_must_cancel

;; Task._coro getter(rdi = self) -> coro or None
DEF_FUNC_LOCAL task_get_coro
    mov rax, [rdi + PyTaskObject.task_coro]
    test rax, rax
    jz .ret_none
    INCREF_V rax, rcx
    leave
    ret
.ret_none:
    LOAD_NONE rax
    leave
    ret
END_FUNC task_get_coro

;; Task._fut_waiter getter(rdi = self) -> waiter or None
DEF_FUNC_LOCAL task_get_fut_waiter
    mov rax, [rdi + PyTaskObject.task_fut_waiter]
    test rax, rax
    jz .ret_none
    INCREF_V rax, rcx
    leave
    ret
.ret_none:
    LOAD_NONE rax
    leave
    ret
END_FUNC task_get_fut_waiter

;; ============================================================================
;; async_task_init(r12 = module dict) -> void
;; Builds TaskStepMethWrapper, TaskWakeup, and Task (subclassing Future), and
;; exports Task into the module dict.
;; ============================================================================
ATI_BASES equ 8
ATI_NS    equ 16
ATI_NAME  equ 24
ATI_KEY   equ 32
ATI_VAL   equ 40
ATI_FRAME equ 40            ; + 1 push (rbx) = 48
DEF_FUNC async_task_init, ATI_FRAME
    push rbx

    ; Populate TaskStepMethWrapper's tp_dict with __self__ getset.
    call dict_new
    mov [rel task_step_wrapper_type + PyTypeObject.tp_dict], rax
    mov rdi, rax
    lea rsi, [rel tn_dunder_self]
    lea rdx, [rel task_step_wrapper_get_self]
    xor ecx, ecx
    lea r8, [rel task_step_wrapper_type]
    call async_add_getset

    ; Populate TaskWakeup's tp_dict with __self__ getset.
    call dict_new
    mov [rel task_wakeup_type + PyTypeObject.tp_dict], rax
    mov rdi, rax
    lea rsi, [rel tn_dunder_self]
    lea rdx, [rel task_wakeup_get_self]
    xor ecx, ecx
    lea r8, [rel task_wakeup_type]
    call async_add_getset

    ; Build bases tuple (Future,).
    mov edi, 1
    call tuple_new
    mov [rbp - ATI_BASES], rax
    mov rcx, [rel future_type]
    INCREF rcx
    mov rdx, [rax + PyTupleObject.ob_item]
    mov [rdx], rcx

    ; Build Task namespace dict.
    call dict_new
    mov rbx, rax
    mov [rbp - ATI_NS], rax

    ; __module__ = "_asyncio"
    lea rdi, [rel tn_dunder_module]
    call str_from_cstr_heap
    mov [rbp - ATI_KEY], rax
    lea rdi, [rel tmod_asyncio]
    call str_from_cstr_heap
    mov [rbp - ATI_VAL], rax
    mov rdi, rbx
    mov rsi, [rbp - ATI_KEY]
    mov rdx, rax
    call dict_set_str
    mov rdi, [rbp - ATI_VAL]
    call obj_decref
    mov rdi, [rbp - ATI_KEY]
    call obj_decref

    ; __qualname__ = "Task"
    lea rdi, [rel tn_dunder_qualname]
    call str_from_cstr_heap
    mov [rbp - ATI_KEY], rax
    lea rdi, [rel tname_task]
    call str_from_cstr_heap
    mov [rbp - ATI_VAL], rax
    mov rdi, rbx
    mov rsi, [rbp - ATI_KEY]
    mov rdx, rax
    call dict_set_str
    mov rdi, [rbp - ATI_VAL]
    call obj_decref
    mov rdi, [rbp - ATI_KEY]
    call obj_decref

    ; Register Task methods.
%macro TASK_METHOD 2
    mov rdi, rbx
    lea rsi, [rel %1]
    lea rdx, [rel %2]
    call async_add_method
%endmacro
    TASK_METHOD tn_dunder_init,   task_method_init
    TASK_METHOD tn_dunder_del,    task_method_del
    TASK_METHOD tn_dunder_repr,   task_method_repr
    TASK_METHOD tn_set_result,    task_method_set_result
    TASK_METHOD tn_set_exception, task_method_set_exception
    TASK_METHOD tn_cancel,        task_method_cancel
    TASK_METHOD tn_cancelling,    task_method_cancelling
    TASK_METHOD tn_uncancel,      task_method_uncancel
    TASK_METHOD tn_get_stack,     task_method_get_stack
    TASK_METHOD tn_print_stack,   task_method_print_stack
    TASK_METHOD tn_get_coro,      task_method_get_coro
    TASK_METHOD tn_get_context,   task_method_get_context
    TASK_METHOD tn_get_name,      task_method_get_name
    TASK_METHOD tn_set_name,      task_method_set_name
    TASK_METHOD tn_make_canc_err, task_method_make_cancelled_error

    mov rdi, rbx
    call add_class_getitem

    ; Build Task heaptype via type_from_parts.
    lea rdi, [rel tname_task]
    call str_from_cstr_heap
    mov [rbp - ATI_NAME], rax
    mov rdi, rax
    mov rsi, [rbp - ATI_BASES]
    mov rdx, [rbp - ATI_NS]
    call type_from_parts        ; err: static valid namespace
    mov rbx, rax
    mov [rel async_task_type], rbx
    mov rdi, [rbp - ATI_NAME]
    call obj_decref
    mov rdi, [rbp - ATI_BASES]
    call obj_decref

    ; Register Task-specific getsets.
%macro TASK_GETSET 3
    mov rdi, [rbx + PyTypeObject.tp_dict]
    lea rsi, [rel %1]
    lea rdx, [rel %2]
%ifidni %3, 0
    xor ecx, ecx
%else
    lea rcx, [rel %3]
%endif
    mov r8, rbx
    call async_add_getset
%endmacro
    TASK_GETSET tgs_log_destroy, task_get_log_destroy, task_set_log_destroy
    TASK_GETSET tgs_must_cancel, task_get_must_cancel, 0
    TASK_GETSET tgs_coro,        task_get_coro,        0
    TASK_GETSET tgs_fut_waiter,  task_get_fut_waiter,  0

    ; Stamp methods and refresh flags.
    mov rdi, rbx
    call type_stamp_methods
    mov rdi, rbx
    call type_refresh_attr_flags

    ; Patch layout and lifecycle slots on Task.
    mov qword [rbx + PyTypeObject.tp_basicsize], PyTaskObject_size
    lea rax, [rel task_dealloc]
    mov [rbx + PyTypeObject.tp_dealloc], rax
    lea rax, [rel task_traverse]
    mov [rbx + PyTypeObject.tp_traverse], rax
    lea rax, [rel task_clear]
    mov [rbx + PyTypeObject.tp_clear], rax
    lea rax, [rel future_new_iter]
    mov [rbx + PyTypeObject.tp_iter], rax
    or qword [rbx + PyTypeObject.tp_flags], TYPE_FLAG_AWAITABLE

    ; Export Task in the module dictionary.
    lea rdi, [rel tname_task]
    call str_from_cstr_heap
    mov [rbp - ATI_KEY], rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, rbx
    call dict_set_str
    mov rdi, [rbp - ATI_KEY]
    call obj_decref

    pop rbx
    leave
    ret
END_FUNC async_task_init

section .data
align 8
task_step_wrapper_type:
    dq 0x00000000FFFFFFFF       ; ob_ref_local=IMMORTAL, ob_ref_shared=0
    dq 0                        ; ob_tid=0 (immortal), ob_mutex=0
    dq type_type                    ; ob_type
    dq tname_step_wrapper           ; tp_name
    dq PyTaskStepWrapperObject_size ; tp_basicsize
    dq task_step_wrapper_dealloc    ; tp_dealloc
    dq 0                            ; tp_repr
    dq 0                            ; tp_str
    dq 0                            ; tp_hash
    dq task_step_wrapper_call       ; tp_call
    dq 0                            ; tp_getattr
    dq 0                            ; tp_setattr
    dq 0                            ; tp_richcompare
    dq 0                            ; tp_iter
    dq 0                            ; tp_iternext
    dq 0                            ; tp_init
    dq 0                            ; tp_new
    dq 0                            ; tp_as_number
    dq 0                            ; tp_as_sequence
    dq 0                            ; tp_as_mapping
    dq 0                            ; tp_base
    dq 0                            ; tp_dict
    dq 0                            ; tp_mro
    dq TYPE_FLAG_HAVE_GC            ; tp_flags
    dq 0                            ; tp_bases
    dq task_step_wrapper_traverse   ; tp_traverse
    dq task_step_wrapper_clear      ; tp_clear
    dq 0                            ; tp_dictoffset
    dq 0                            ; tp_tailslots
    dq 0                            ; tp_as_buffer

align 8
task_wakeup_type:
    dq 0x00000000FFFFFFFF       ; ob_ref_local=IMMORTAL, ob_ref_shared=0
    dq 0                        ; ob_tid=0 (immortal), ob_mutex=0
    dq type_type                    ; ob_type
    dq tname_wakeup                 ; tp_name
    dq PyTaskWakeupObject_size      ; tp_basicsize
    dq task_wakeup_dealloc          ; tp_dealloc
    dq 0                            ; tp_repr
    dq 0                            ; tp_str
    dq 0                            ; tp_hash
    dq task_wakeup_call             ; tp_call
    dq 0                            ; tp_getattr
    dq 0                            ; tp_setattr
    dq 0                            ; tp_richcompare
    dq 0                            ; tp_iter
    dq 0                            ; tp_iternext
    dq 0                            ; tp_init
    dq 0                            ; tp_new
    dq 0                            ; tp_as_number
    dq 0                            ; tp_as_sequence
    dq 0                            ; tp_as_mapping
    dq 0                            ; tp_base
    dq 0                            ; tp_dict
    dq 0                            ; tp_mro
    dq TYPE_FLAG_HAVE_GC            ; tp_flags
    dq 0                            ; tp_bases
    dq task_wakeup_traverse         ; tp_traverse
    dq task_wakeup_clear            ; tp_clear
    dq 0                            ; tp_dictoffset
    dq 0                            ; tp_tailslots
    dq 0                            ; tp_as_buffer

section .rodata
tmod_asyncio:        db "_asyncio", 0
tname_task:          db "Task", 0
tname_step_wrapper:  db "_asyncio.TaskStepMethWrapper", 0
tname_wakeup:        db "_asyncio.TaskWakeup", 0

tn_dunder_module:    db "__module__", 0
tn_dunder_qualname:  db "__qualname__", 0
tn_dunder_init:      db "__init__", 0
tn_dunder_del:       db "__del__", 0
tn_dunder_repr:      db "__repr__", 0
tn_dunder_self:      db "__self__", 0
tn_set_result:       db "set_result", 0
tn_set_exception:    db "set_exception", 0
tn_cancel:           db "cancel", 0
tn_cancelling:       db "cancelling", 0
tn_uncancel:         db "uncancel", 0
tn_get_stack:        db "get_stack", 0
tn_print_stack:      db "print_stack", 0
tn_get_coro:         db "get_coro", 0
tn_get_context:      db "get_context", 0
tn_get_name:         db "get_name", 0
tn_set_name:         db "set_name", 0
tn_make_canc_err:    db "_make_cancelled_error", 0
tn_get_loop:         db "get_loop", 0
tn_attr_loop:        db "_loop", 0
tn_send:             db "send", 0
tn_throw:            db "throw", 0
tn_value:            db "value", 0
tn_run:              db "run", 0
tn_result:           db "result", 0
tn_is_running:       db "is_running", 0
tn_add_done_cb:      db "add_done_callback", 0
tn_future_blocking:  db "_asyncio_future_blocking", 0
tn_call_exc_handler: db "call_exception_handler", 0

tgs_log_destroy:     db "_log_destroy_pending", 0
tgs_must_cancel:     db "_must_cancel", 0
tgs_coro:            db "_coro", 0
tgs_fut_waiter:      db "_fut_waiter", 0

tkw_coro:            db "coro", 0
tkw_loop:            db "loop", 0
tkw_name:            db "name", 0
tkw_context:         db "context", 0
tkw_eager_start:     db "eager_start", 0
tkw_msg:             db "msg", 0
tkw_limit:           db "limit", 0
tkw_file:            db "file", 0

tkey_message:        db "message", 0
tkey_task:           db "task", 0
tkey_source_tb:      db "source_traceback", 0

tmsg_task_prefix:    db "Task-", 0
tmsg_space:          db " ", 0
tmsg_step_done:      db "_step(): already done: ", 0
tmsg_coro_expected:  db "a coroutine was expected, got ", 0
tmsg_bad_yield:      db "Task got bad yield: ", 0
tmsg_self_await:     db "Task cannot await on itself: ", 0
tmsg_yield_fut_1:    db "yield was used instead of yield from in task ", 0
tmsg_yield_gen_1:    db "yield was used instead of yield from for generator in task ", 0
tmsg_with:           db " with ", 0
tmsg_diff_loop_1:    db "Task ", 0
tmsg_diff_loop_2:    db " got Future ", 0
tmsg_diff_loop_3:    db " attached to a different loop", 0
tmsg_destroyed_pending: db "Task was destroyed but it is pending!", 0
