; asyncio_future.asm - native _asyncio.Future and _asyncio.FutureIter types.
;
; Future is a GC-tracked heaptype built via type_from_parts (like _io.FileIO
; and _io.BytesIO) with PyFutureObject fields past the standard 3-word
; PyInstanceObject header (ob_refcnt, ob_type, inst_dict).  This gives Future
; and every subclass (including Task and Python subclasses with or without
; __slots__) native __dict__, weakrefs, GC cycle collection, and finalization.
;
; FutureIter is a static GC-tracked iterator type with gi_return_value at +48,
; matching PyGenObject, so op_send and builtin_next_fn extract Future results
; directly on exhaustion without allocating StopIteration on the await path.

%include "macros.inc"
%include "object.inc"
%include "threadstate.inc"
%include "value.inc"

extern add_class_getitem
extern ap_strcmp
extern async_add_getset
extern async_add_method
extern async_call_method
extern async_call_soon
extern async_get_cancelled_error
extern async_get_copy_context
extern async_get_event_loop_internal
extern async_get_extract_stack
extern async_get_future_repr
extern async_get_invalid_state_error
extern bool_false
extern bool_true
extern deprecation_warn
extern dict_new
extern dict_set_str
extern exc_fetch
extern exc_install
extern exc_isinstance
extern exc_new
extern exc_restore
extern exc_set_context
extern gc_alloc
extern gc_dealloc
extern gc_track
extern instance_clear
extern instance_dealloc
extern instance_traverse
extern list_append
extern list_new
extern list_type
extern none_singleton
extern obj_call_n
extern obj_dealloc
extern obj_decref
extern obj_incref
extern obj_is_true
extern obj_richcompare_bool
extern rbt_append_cstr
extern set_exception
extern str_from_cstr_heap
extern str_intern_cstr
extern str_new_heap
extern traceback_print_unraisable
extern traceback_type
extern tuple_new
extern type_from_parts
extern type_is_exc_subclass
extern type_refresh_attr_flags
extern type_stamp_methods
extern type_type

extern exc_AttributeError_type
extern exc_RuntimeError_type
extern exc_StopIteration_type
extern exc_TypeError_type
extern exc_ValueError_type

section .bss
alignb 8
global future_type
future_type:       resq 1
fut_str_pending:   resq 1
fut_str_cancelled: resq 1
fut_str_finished:  resq 1

section .text

;; ============================================================================
;; future_set_invalid_state(rdi = C message) -> rax = 0
;; Helper: raise asyncio.exceptions.InvalidStateError with a C message.
;; ============================================================================
FSIS_MSG   equ 8
FSIS_FRAME equ 16
DEF_FUNC_LOCAL future_set_invalid_state, FSIS_FRAME
    mov [rbp - FSIS_MSG], rdi
    call async_get_invalid_state_error
    ERR_NULL .failed
    mov rdi, rax
    mov rsi, [rbp - FSIS_MSG]
    call set_exception
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_set_invalid_state

;; ============================================================================
;; future_clear_fields(rdi = PyFutureObject*) -> void
;; Clear all Future-owned fields (NOT inst_dict). Safe if called repeatedly.
;; ============================================================================
DEF_FUNC_LOCAL future_clear_fields, 8
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyFutureObject.fut_loop]
    mov qword [rbx + PyFutureObject.fut_loop], 0
    XDECREF_V rdi, rax

    mov rdi, [rbx + PyFutureObject.fut_callback0]
    mov qword [rbx + PyFutureObject.fut_callback0], 0
    XDECREF_V rdi, rax

    mov rdi, [rbx + PyFutureObject.fut_context0]
    mov qword [rbx + PyFutureObject.fut_context0], 0
    XDECREF_V rdi, rax

    mov rdi, [rbx + PyFutureObject.fut_callbacks]
    mov qword [rbx + PyFutureObject.fut_callbacks], 0
    XDECREF_V rdi, rax

    mov rdi, [rbx + PyFutureObject.fut_result]
    mov qword [rbx + PyFutureObject.fut_result], 0
    XDECREF_V rdi, rax

    mov rdi, [rbx + PyFutureObject.fut_exception]
    mov qword [rbx + PyFutureObject.fut_exception], 0
    XDECREF_V rdi, rax

    mov rdi, [rbx + PyFutureObject.fut_exception_tb]
    mov qword [rbx + PyFutureObject.fut_exception_tb], 0
    XDECREF_V rdi, rax

    mov rdi, [rbx + PyFutureObject.fut_source_tb]
    mov qword [rbx + PyFutureObject.fut_source_tb], 0
    XDECREF_V rdi, rax

    mov rdi, [rbx + PyFutureObject.fut_cancel_msg]
    mov qword [rbx + PyFutureObject.fut_cancel_msg], 0
    XDECREF_V rdi, rax

    mov rdi, [rbx + PyFutureObject.fut_cancelled_exc]
    mov qword [rbx + PyFutureObject.fut_cancelled_exc], 0
    XDECREF_V rdi, rax

    mov dword [rbx + PyFutureObject.fut_state], 0
    mov dword [rbx + PyFutureObject.fut_log_tb], 0
    mov dword [rbx + PyFutureObject.fut_blocking], 0
    mov dword [rbx + PyFutureObject.fut_pad], 0

    pop rbx
    leave
    ret
END_FUNC future_clear_fields

;; ============================================================================
;; future_traverse_fields(rdi = PyFutureObject*, r14 = visit callback) -> void
;; Visit Future's own fields, inst_dict, and heaptype ob_type.
;; ============================================================================
DEF_FUNC future_traverse_fields, 8
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyFutureObject.inst_dict]
    VISIT_PTR rdi
    mov rax, [rbx + PyObject.ob_type]
    test dword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .no_type
    VISIT_PTR rax
.no_type:
    mov rdi, [rbx + PyFutureObject.fut_loop]
    VISIT_V rdi, rax
    mov rdi, [rbx + PyFutureObject.fut_callback0]
    VISIT_V rdi, rax
    mov rdi, [rbx + PyFutureObject.fut_context0]
    VISIT_V rdi, rax
    mov rdi, [rbx + PyFutureObject.fut_callbacks]
    VISIT_V rdi, rax
    mov rdi, [rbx + PyFutureObject.fut_result]
    VISIT_V rdi, rax
    mov rdi, [rbx + PyFutureObject.fut_exception]
    VISIT_V rdi, rax
    mov rdi, [rbx + PyFutureObject.fut_exception_tb]
    VISIT_V rdi, rax
    mov rdi, [rbx + PyFutureObject.fut_source_tb]
    VISIT_V rdi, rax
    mov rdi, [rbx + PyFutureObject.fut_cancel_msg]
    VISIT_V rdi, rax
    mov rdi, [rbx + PyFutureObject.fut_cancelled_exc]
    VISIT_V rdi, rax

    pop rbx
    leave
    ret
END_FUNC future_traverse_fields

;; ============================================================================
;; future_traverse(rdi = PyFutureObject*, r14 = visit callback) -> 0
;; ============================================================================
DEF_FUNC future_traverse
    push rbx
    push r12
    mov rbx, rdi

    call future_traverse_fields

    ; Visit any subclass __slots__ past PyFutureObject_size.
    mov rax, [rbx + PyObject.ob_type]
    mov r12d, PyFutureObject_size
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
END_FUNC future_traverse

;; ============================================================================
;; future_clear(rdi = PyFutureObject*) -> 0
;; ============================================================================
DEF_FUNC future_clear, 8
    push rbx
    mov rbx, rdi
    call future_clear_fields
    mov rdi, rbx
    call instance_clear
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC future_clear

;; ============================================================================
;; future_dealloc(rdi = PyFutureObject*) -> void
;; ============================================================================
DEF_FUNC future_dealloc, 8
    push rbx
    mov rbx, rdi
    call future_clear_fields
    mov rdi, rbx
    call instance_dealloc
    pop rbx
    leave
    ret
END_FUNC future_dealloc

;; ============================================================================
;; future_schedule_callbacks(rdi = PyFutureObject*) -> 0 / -1
;; Fails: -1
;; Transfers callback0/context0 and callbacks ownership out of the Future before
;; calling loop.call_soon so re-entrant Python cannot mutate them mid-loop.
;; ============================================================================
FSC_FUT  equ 8
FSC_CB0  equ 16
FSC_CTX0 equ 24
FSC_LIST equ 32
FSC_IDX  equ 40
FSC_LEN  equ 48
FSC_FRAME equ 48
DEF_FUNC_LOCAL future_schedule_callbacks, FSC_FRAME
    mov [rbp - FSC_FUT], rdi
    mov rax, [rdi + PyFutureObject.fut_callback0]
    test rax, rax
    jz .check_list

    mov [rbp - FSC_CB0], rax
    mov qword [rdi + PyFutureObject.fut_callback0], 0
    mov rcx, [rdi + PyFutureObject.fut_context0]
    mov [rbp - FSC_CTX0], rcx
    mov qword [rdi + PyFutureObject.fut_context0], 0

    mov rdx, rdi                ; arg = fut
    mov rsi, rax                ; func = cb0
    mov rdi, [rdi + PyFutureObject.fut_loop]
    call async_call_soon        ; err: release cb0/ctx0 before checking
    push rax
    sub rsp, 8
    mov rdi, [rbp - FSC_CB0]
    XDECREF_V rdi, rcx
    mov rdi, [rbp - FSC_CTX0]
    XDECREF_V rdi, rcx
    add rsp, 8
    pop rax
    test rax, rax
    jnz .fail_clear_list

.check_list:
    mov rdi, [rbp - FSC_FUT]
    mov rax, [rdi + PyFutureObject.fut_callbacks]
    test rax, rax
    jz .ok
    mov [rbp - FSC_LIST], rax
    mov qword [rdi + PyFutureObject.fut_callbacks], 0
    mov rcx, [rax + PyListObject.ob_size]
    mov [rbp - FSC_LEN], rcx
    mov qword [rbp - FSC_IDX], 0

.loop:
    mov rcx, [rbp - FSC_IDX]
    cmp rcx, [rbp - FSC_LEN]
    jge .loop_done
    mov rax, [rbp - FSC_LIST]
    mov rax, [rax + PyListObject.ob_item]
    mov rax, [rax + rcx * 8]    ; cb_tup = (cb, ctx)
    mov rax, [rax + PyTupleObject.ob_item]
    mov rsi, [rax]              ; cb
    mov rcx, [rax + 8]          ; ctx
    mov rdx, [rbp - FSC_FUT]
    mov rdi, [rdx + PyFutureObject.fut_loop]
    call async_call_soon
    ERR_M1 .fail_list
    inc qword [rbp - FSC_IDX]
    jmp .loop

.loop_done:
    mov rdi, [rbp - FSC_LIST]
    call obj_decref
.ok:
    xor eax, eax
    leave
    ret

.fail_list:
    mov rdi, [rbp - FSC_LIST]
    call obj_decref
    mov rax, -1
    leave
    ret

.fail_clear_list:
    mov rdi, [rbp - FSC_FUT]
    mov rax, [rdi + PyFutureObject.fut_callbacks]
    mov qword [rdi + PyFutureObject.fut_callbacks], 0
    XDECREF_V rax, rcx
    mov rax, -1
    leave
    ret
END_FUNC future_schedule_callbacks

;; ============================================================================
;; future_init_impl(rdi = PyFutureObject*, rsi = loop Value or 0/None) -> 0/-1
;; Fails: -1
;; ============================================================================
FII_FUT  equ 8
FII_LOOP equ 16
FII_FRAME equ 16
DEF_FUNC future_init_impl, FII_FRAME
    mov [rbp - FII_FUT], rdi
    mov [rbp - FII_LOOP], rsi

    call future_clear_fields

    mov rdi, [rbp - FII_FUT]
    mov dword [rdi + PyFutureObject.fut_state], FUT_STATE_PENDING
    mov dword [rdi + PyFutureObject.fut_log_tb], 0
    mov dword [rdi + PyFutureObject.fut_blocking], 0

    mov rax, [rbp - FII_LOOP]
    test rax, rax
    jz .default_loop
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .default_loop
    INCREF_V rax, rcx
    jmp .have_loop
.default_loop:
    call async_get_event_loop_internal
    ERR_NULL .failed
.have_loop:
    mov rdi, [rbp - FII_FUT]
    mov [rdi + PyFutureObject.fut_loop], rax

    ; Check loop.get_debug()
    mov rdi, rax
    INCREF_V rdi, rcx
    lea rsi, [rel fn_get_debug]
    xor edx, edx
    xor ecx, ecx
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
    jz .ok

    ; Debug mode: capture traceback.extract_stack()
    call async_get_extract_stack
    ERR_NULL .failed
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call obj_call_n
    ERR_NULL .failed
    mov rdi, [rbp - FII_FUT]
    mov rcx, [rdi + PyFutureObject.fut_source_tb]
    mov [rdi + PyFutureObject.fut_source_tb], rax
    XDECREF_V rcx, rdx

.ok:
    xor eax, eax
    leave
    ret
.failed:
    mov rax, -1
    leave
    ret
END_FUNC future_init_impl

;; ============================================================================
;; future_create_cancelled_error(rdi = PyFutureObject*) -> owned CancelledError
;; Fails: 0
;; ============================================================================
FCCE_FUT equ 8
FCCE_ARG equ 16
FCCE_FRAME equ 16
DEF_FUNC future_create_cancelled_error, FCCE_FRAME
    mov rax, [rdi + PyFutureObject.fut_cancelled_exc]
    test rax, rax
    jz .make_new
    mov qword [rdi + PyFutureObject.fut_cancelled_exc], 0
    leave
    ret
.make_new:
    mov [rbp - FCCE_FUT], rdi
    call async_get_cancelled_error
    ERR_NULL .failed
    mov rdi, [rbp - FCCE_FUT]
    mov rcx, [rdi + PyFutureObject.fut_cancel_msg]
    test rcx, rcx
    jz .no_msg
    lea rdx, [rel none_singleton]
    cmp rcx, rdx
    je .no_msg
    mov [rbp - FCCE_ARG], rcx
    mov rdi, rax
    lea rsi, [rbp - FCCE_ARG]
    mov edx, 1
    call obj_call_n             ; err: propagate
    leave
    ret
.no_msg:
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call obj_call_n             ; err: propagate
    leave
    ret
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_create_cancelled_error

;; ============================================================================
;; future_set_cancelled_error(rdi = PyFutureObject*) -> rax = 0 (always sets exc)
;; ============================================================================
DEF_FUNC_LOCAL future_set_cancelled_error
    call future_create_cancelled_error
    ERR_NULL .done
    mov rdi, rax
    call exc_install
.done:
    xor eax, eax
    leave
    ret
END_FUNC future_set_cancelled_error

;; ============================================================================
;; future_get_result_impl(rdi = PyFutureObject*)
;;   -> rax = owned Value, edx = 0 (normal result) or 1 (exception object)
;;   -> rax = 0 with exception pending on error (edx = -1)
;; Fails: 0
;; ============================================================================
FGRI_FUT equ 8
FGRI_FRAME equ 16
DEF_FUNC future_get_result_impl, FGRI_FRAME
    mov [rbp - FGRI_FUT], rdi
    mov eax, [rdi + PyFutureObject.fut_state]
    cmp eax, FUT_STATE_CANCELLED
    je .cancelled
    cmp eax, FUT_STATE_FINISHED
    jne .not_set

    mov dword [rdi + PyFutureObject.fut_log_tb], 0
    mov rax, [rdi + PyFutureObject.fut_exception]
    test rax, rax
    jz .normal_result

    ; Restore saved traceback on the exception and clear fut_exception_tb.
    mov rcx, [rdi + PyFutureObject.fut_exception_tb]
    mov qword [rdi + PyFutureObject.fut_exception_tb], 0
    lea rdx, [rel none_singleton]
    cmp rcx, rdx
    jne .tb_ready
    push rax
    sub rsp, 8
    mov rdi, rcx
    call obj_decref
    add rsp, 8
    pop rax
    xor ecx, ecx
.tb_ready:
    mov rdx, [rax + PyExceptionObject.exc_tb]
    mov [rax + PyExceptionObject.exc_tb], rcx
    test rdx, rdx
    jz .tb_done
    push rax
    sub rsp, 8
    mov rdi, rdx
    call obj_decref
    add rsp, 8
    pop rax
.tb_done:
    INCREF_V rax, rcx
    mov edx, 1
    leave
    ret

.normal_result:
    mov rax, [rdi + PyFutureObject.fut_result]
    INCREF_V rax, rcx
    xor edx, edx
    leave
    ret

.cancelled:
    call future_set_cancelled_error
    xor eax, eax
    mov edx, -1
    leave
    ret

.not_set:
    lea rdi, [rel fmsg_result_not_set]
    call future_set_invalid_state
    xor eax, eax
    mov edx, -1
    leave
    ret
END_FUNC future_get_result_impl

;; ============================================================================
;; future_set_result_impl(rdi = PyFutureObject*, rsi = result Value) -> 0 / -1
;; Fails: -1
;; ============================================================================
FSRI_FUT equ 8
FSRI_FRAME equ 16
DEF_FUNC future_set_result_impl, FSRI_FRAME
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .uninit
    cmp dword [rdi + PyFutureObject.fut_state], FUT_STATE_PENDING
    jne .invalid_state

    mov [rbp - FSRI_FUT], rdi
    INCREF_V rsi, rcx
    mov [rdi + PyFutureObject.fut_result], rsi
    mov dword [rdi + PyFutureObject.fut_state], FUT_STATE_FINISHED
    call future_schedule_callbacks
    ERR_M1 .failed
    xor eax, eax
    leave
    ret
.uninit:
    FAIL exc_RuntimeError_type, "Future object is not initialized.", .failed
.invalid_state:
    lea rdi, [rel fmsg_invalid_state]
    call future_set_invalid_state
.failed:
    mov rax, -1
    leave
    ret
END_FUNC future_set_result_impl

;; ============================================================================
;; future_set_exception_impl(rdi = PyFutureObject*, rsi = exc Value) -> 0 / -1
;; Fails: -1
;; ============================================================================
FSEI_FUT  equ 8
FSEI_EXC  equ 16
FSEI_WRAP equ 24
FSEI_FRAME equ 32
DEF_FUNC future_set_exception_impl, FSEI_FRAME
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .uninit
    cmp dword [rdi + PyFutureObject.fut_state], FUT_STATE_PENDING
    jne .invalid_state

    mov [rbp - FSEI_FUT], rdi
    mov [rbp - FSEI_EXC], rsi

    ; If rsi is an exception class, instantiate it.
    V_TEST_PTR rsi, rax
    ja .bad_exc
    test rsi, rsi
    jz .bad_exc
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel type_type]
    cmp rax, rcx
    je .maybe_exc_class
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .check_instance
.maybe_exc_class:
    mov rdi, rsi
    call type_is_exc_subclass
    test eax, eax
    jz .bad_exc
    mov rdi, [rbp - FSEI_EXC]
    xor esi, esi
    xor edx, edx
    call obj_call_n
    ERR_NULL .failed
    mov [rbp - FSEI_EXC], rax
    ; Re-check state after instantiating user exception class.
    mov rdi, [rbp - FSEI_FUT]
    cmp dword [rdi + PyFutureObject.fut_state], FUT_STATE_PENDING
    jne .invalid_state_owned
    jmp .verify_instance

.check_instance:
    mov rdi, rsi
    INCREF_V rdi, rcx
    mov [rbp - FSEI_EXC], rdi

.verify_instance:
    mov rax, [rbp - FSEI_EXC]
    V_TEST_PTR rax, rcx
    ja .bad_exc_owned
    test rax, rax
    jz .bad_exc_owned
    mov rdi, [rax + PyObject.ob_type]
    call type_is_exc_subclass
    test eax, eax
    jz .bad_exc_owned

    ; StopIteration cannot be raised into a Future; wrap in RuntimeError.
    mov rdi, [rbp - FSEI_EXC]
    lea rsi, [rel exc_StopIteration_type]
    call exc_isinstance         ; err: static type is never refused
    test eax, eax
    jz .store_exc

    lea rdi, [rel fmsg_stopiter_future]
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    lea rdi, [rel exc_RuntimeError_type]
    mov rsi, rax
    call exc_new
    mov [rbp - FSEI_WRAP], rax
    add rsp, 8
    pop rdi
    call obj_decref

    mov rax, [rbp - FSEI_WRAP]
    mov rcx, [rbp - FSEI_EXC]
    INCREF rcx
    mov [rax + PyExceptionObject.exc_cause], rcx
    mov qword [rax + PyExceptionObject.exc_suppress], 1
    mov rdi, rax
    mov rsi, rcx
    call exc_set_context
    mov rdi, [rbp - FSEI_EXC]
    call obj_decref
    mov rax, [rbp - FSEI_WRAP]
    mov [rbp - FSEI_EXC], rax

.store_exc:
    mov rdi, [rbp - FSEI_FUT]
    mov rax, [rbp - FSEI_EXC]
    mov [rdi + PyFutureObject.fut_exception], rax
    mov rcx, [rax + PyExceptionObject.exc_tb]
    test rcx, rcx
    jz .no_tb
    INCREF rcx
.no_tb:
    mov [rdi + PyFutureObject.fut_exception_tb], rcx
    mov dword [rdi + PyFutureObject.fut_state], FUT_STATE_FINISHED
    call future_schedule_callbacks
    ERR_M1 .failed
    mov rdi, [rbp - FSEI_FUT]
    mov dword [rdi + PyFutureObject.fut_log_tb], 1
    xor eax, eax
    leave
    ret

.uninit:
    FAIL exc_RuntimeError_type, "Future object is not initialized.", .failed
.invalid_state_owned:
    mov rdi, [rbp - FSEI_EXC]
    XDECREF_V rdi, rcx
.invalid_state:
    lea rdi, [rel fmsg_invalid_state]
    call future_set_invalid_state
    jmp .failed
.bad_exc_owned:
    mov rdi, [rbp - FSEI_EXC]
    XDECREF_V rdi, rcx
.bad_exc:
    FAIL exc_TypeError_type, "invalid exception object", .failed
.failed:
    mov rax, -1
    leave
    ret
END_FUNC future_set_exception_impl

;; ============================================================================
;; future_cancel_impl(rdi = PyFutureObject*, rsi = msg Value or 0) -> 1 / 0 / -1
;; Fails: -1
;; ============================================================================
FCI_FUT equ 8
FCI_FRAME equ 16
DEF_FUNC future_cancel_impl, FCI_FRAME
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .uninit
    mov dword [rdi + PyFutureObject.fut_log_tb], 0
    cmp dword [rdi + PyFutureObject.fut_state], FUT_STATE_PENDING
    jne .already_done

    mov [rbp - FCI_FUT], rdi
    mov dword [rdi + PyFutureObject.fut_state], FUT_STATE_CANCELLED
    INCREF_V rsi, rcx
    mov rdx, [rdi + PyFutureObject.fut_cancel_msg]
    mov [rdi + PyFutureObject.fut_cancel_msg], rsi
    XDECREF_V rdx, rcx

    mov rdi, [rbp - FCI_FUT]
    call future_schedule_callbacks
    ERR_M1 .failed
    mov eax, 1
    leave
    ret

.already_done:
    xor eax, eax
    leave
    ret
.uninit:
    FAIL exc_RuntimeError_type, "Future object is not initialized.", .failed
.failed:
    mov rax, -1
    leave
    ret
END_FUNC future_cancel_impl

;; ============================================================================
;; future_add_done_callback_impl(rdi = PyFutureObject*, rsi = fn Value,
;;                               rdx = ctx Value) -> 0 / -1
;; Fails: -1
;; ============================================================================
FADC_FUT equ 8
FADC_FN  equ 16
FADC_CTX equ 24
FADC_TUP equ 32
FADC_FRAME equ 32
DEF_FUNC future_add_done_callback_impl, FADC_FRAME
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .uninit
    mov [rbp - FADC_FUT], rdi
    mov [rbp - FADC_FN], rsi
    mov [rbp - FADC_CTX], rdx

    cmp dword [rdi + PyFutureObject.fut_state], FUT_STATE_PENDING
    je .pending

    mov rcx, rdx                ; ctx
    mov rdx, rdi                ; arg = fut
    mov rdi, [rdi + PyFutureObject.fut_loop]
    call async_call_soon        ; err: propagate
    leave
    ret

.pending:
    cmp qword [rdi + PyFutureObject.fut_callbacks], 0
    jne .append_list
    cmp qword [rdi + PyFutureObject.fut_callback0], 0
    jne .append_list

    INCREF_V rsi, rcx
    mov [rdi + PyFutureObject.fut_callback0], rsi
    INCREF_V rdx, rcx
    mov [rdi + PyFutureObject.fut_context0], rdx
    xor eax, eax
    leave
    ret

.append_list:
    mov edi, 2
    call tuple_new
    mov [rbp - FADC_TUP], rax
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rsi, [rbp - FADC_FN]
    INCREF_V rsi, rdx
    mov [rcx], rsi
    mov rsi, [rbp - FADC_CTX]
    INCREF_V rsi, rdx
    mov [rcx + 8], rsi

    mov rdi, [rbp - FADC_FUT]
    mov rax, [rdi + PyFutureObject.fut_callbacks]
    test rax, rax
    jnz .have_list
    xor edi, edi
    call list_new
    mov rdi, [rbp - FADC_FUT]
    mov [rdi + PyFutureObject.fut_callbacks], rax
.have_list:
    mov rdi, rax
    mov rsi, [rbp - FADC_TUP]
    call list_append
    ERR_M1 .fail_tup
    mov rdi, [rbp - FADC_TUP]
    call obj_decref
    xor eax, eax
    leave
    ret

.fail_tup:
    mov rdi, [rbp - FADC_TUP]
    call obj_decref
    mov rax, -1
    leave
    ret
.uninit:
    FAIL exc_RuntimeError_type, "uninitialized Future object", .failed
.failed:
    mov rax, -1
    leave
    ret
END_FUNC future_add_done_callback_impl

;; ============================================================================
;; future_finalize_impl(rdi = PyFutureObject*) -> void
;; ============================================================================
FFIN_FUT  equ 8
FFIN_EXC  equ 16
FFIN_CTX  equ 24
FFIN_MSG  equ 32
FFIN_KEY  equ 40
FFIN_FRAME equ 48
DEF_FUNC future_finalize_impl, FFIN_FRAME
    cmp dword [rdi + PyFutureObject.fut_log_tb], 0
    je .done
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .done
    mov dword [rdi + PyFutureObject.fut_log_tb], 0
    mov [rbp - FFIN_FUT], rdi

    call exc_fetch
    mov [rbp - FFIN_EXC], rax

    call dict_new
    mov [rbp - FFIN_CTX], rax

    ; Build "<TypeName> exception was never retrieved"
    mov rdi, [rbp - FFIN_FUT]
    mov rax, [rdi + PyObject.ob_type]
    mov rsi, [rax + PyTypeObject.tp_name]
    lea rdi, [rel fut_fin_buf]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel fmsg_exc_unretrieved]
    call rbt_append_cstr
    lea rdi, [rel fut_fin_buf]
    call str_from_cstr_heap
    mov [rbp - FFIN_MSG], rax

    lea rdi, [rel fkey_message]
    call str_from_cstr_heap
    mov [rbp - FFIN_KEY], rax
    mov rdi, [rbp - FFIN_CTX]
    mov rsi, rax
    mov rdx, [rbp - FFIN_MSG]
    call dict_set_str
    mov rdi, [rbp - FFIN_KEY]
    call obj_decref
    mov rdi, [rbp - FFIN_MSG]
    call obj_decref

    lea rdi, [rel fkey_exception]
    call str_from_cstr_heap
    mov [rbp - FFIN_KEY], rax
    mov rdi, [rbp - FFIN_CTX]
    mov rsi, rax
    mov rcx, [rbp - FFIN_FUT]
    mov rdx, [rcx + PyFutureObject.fut_exception]
    call dict_set_str
    mov rdi, [rbp - FFIN_KEY]
    call obj_decref

    lea rdi, [rel fkey_future]
    call str_from_cstr_heap
    mov [rbp - FFIN_KEY], rax
    mov rdi, [rbp - FFIN_CTX]
    mov rsi, rax
    mov rdx, [rbp - FFIN_FUT]
    call dict_set_str
    mov rdi, [rbp - FFIN_KEY]
    call obj_decref

    mov rcx, [rbp - FFIN_FUT]
    mov rdx, [rcx + PyFutureObject.fut_source_tb]
    test rdx, rdx
    jz .call_handler
    lea rdi, [rel fkey_source_tb]
    call str_from_cstr_heap
    mov [rbp - FFIN_KEY], rax
    mov rdi, [rbp - FFIN_CTX]
    mov rsi, rax
    mov rcx, [rbp - FFIN_FUT]
    mov rdx, [rcx + PyFutureObject.fut_source_tb]
    call dict_set_str
    mov rdi, [rbp - FFIN_KEY]
    call obj_decref

.call_handler:
    mov rdi, [rbp - FFIN_FUT]
    mov rdi, [rdi + PyFutureObject.fut_loop]
    INCREF_V rdi, rcx
    lea rsi, [rel fn_call_exc_handler]
    lea rdx, [rbp - FFIN_CTX]
    mov ecx, 1
    call async_call_method      ; err: report unraisable on failure
    test rax, rax
    jz .unraisable
    DECREF_V rax, rcx
    jmp .cleanup
.unraisable:
    mov rdi, [gs:ThreadState.current_exception]
    test rdi, rdi
    jz .cleanup
    mov rsi, [rbp - FFIN_FUT]
    call traceback_print_unraisable
    mov rdi, [gs:ThreadState.current_exception]
    mov qword [gs:ThreadState.current_exception], 0
    call obj_decref
.cleanup:
    mov rdi, [rbp - FFIN_CTX]
    call obj_decref
    mov rdi, [rbp - FFIN_EXC]
    call exc_restore
.done:
    leave
    ret
END_FUNC future_finalize_impl

;; ============================================================================
;; Future Python methods
;; ============================================================================

;; Future.__init__(self, *, loop=None) -> None
;; Fails: 0
FI_SELF  equ 8
FI_LOOP  equ 16
FI_FRAME equ 16
DEF_FUNC_LOCAL future_method_init, FI_FRAME
    mov rax, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov r8, [rdi]               ; self
    mov [rbp - FI_SELF], r8
    mov qword [rbp - FI_LOOP], 0

    test rax, rax
    jz .no_kw
    mov rcx, [rax + PyTupleObject.ob_size]
    cmp rcx, 1
    ja .bad_kw
    test rcx, rcx
    jz .no_kw
    cmp rsi, 2
    jne .bad_pos
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rdx, [rdx]              ; kwname str
    mov r9, [rdi + 8]           ; kwval
    mov [rbp - FI_LOOP], r9
    lea rdi, [rdx + PyStrObject.data]
    lea rsi, [rel fkw_loop]
    call ap_strcmp
    test eax, eax
    jnz .bad_kw
    jmp .do_init

.no_kw:
    cmp rsi, 1
    jne .bad_pos

.do_init:
    mov rdi, [rbp - FI_SELF]
    mov rsi, [rbp - FI_LOOP]
    call future_init_impl
    ERR_M1 .failed
    LOAD_NONE rax
    leave
    ret

.bad_pos:
    FAIL exc_TypeError_type, "Future.__init__() takes 1 positional argument", .failed
.bad_kw:
    FAIL exc_TypeError_type, "Future.__init__() got an unexpected keyword argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_method_init

;; Future.__del__(self) -> None
;; Fails: 0
DEF_FUNC_LOCAL future_method_del
    NO_KEYWORDS_RET "__del__() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    call future_finalize_impl
    LOAD_NONE rax
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "__del__() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_method_del

;; Future.__repr__(self) -> str
;; Fails: 0
FR_ARG equ 8
FR_FRAME equ 16
DEF_FUNC_LOCAL future_method_repr, FR_FRAME
    NO_KEYWORDS_RET "__repr__() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov r8, [rdi]
    cmp qword [r8 + PyFutureObject.fut_loop], 0
    je .uninit
    mov [rbp - FR_ARG], r8
    call async_get_future_repr
    ERR_NULL .failed
    mov rdi, rax
    lea rsi, [rbp - FR_ARG]
    mov edx, 1
    call obj_call_n             ; err: propagate
    leave
    ret
.uninit:
    FAIL exc_RuntimeError_type, "Future object is not initialized.", .failed
.arity:
    FAIL exc_TypeError_type, "__repr__() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_method_repr

;; Future.result(self) -> Value
;; Fails: 0
DEF_FUNC_LOCAL future_method_result
    NO_KEYWORDS_RET "result() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .uninit
    call future_get_result_impl
    ERR_NULL .failed
    test edx, edx
    jz .ret_val
    mov rdi, rax
    call exc_install
    xor eax, eax
.ret_val:
    leave
    ret
.uninit:
    lea rdi, [rel fmsg_not_init]
    call future_set_invalid_state
    jmp .failed
.arity:
    FAIL exc_TypeError_type, "result() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_method_result

;; Future.exception(self) -> exception or None
;; Fails: 0
DEF_FUNC_LOCAL future_method_exception
    NO_KEYWORDS_RET "exception() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .uninit
    mov eax, [rdi + PyFutureObject.fut_state]
    cmp eax, FUT_STATE_CANCELLED
    je .cancelled
    cmp eax, FUT_STATE_FINISHED
    jne .not_set
    mov rax, [rdi + PyFutureObject.fut_exception]
    test rax, rax
    jz .ret_none
    mov dword [rdi + PyFutureObject.fut_log_tb], 0
    INCREF_V rax, rcx
    leave
    ret
.ret_none:
    LOAD_NONE rax
    leave
    ret
.cancelled:
    call future_set_cancelled_error
    xor eax, eax
    leave
    ret
.not_set:
    lea rdi, [rel fmsg_exc_not_set]
    call future_set_invalid_state
    xor eax, eax
    leave
    ret
.uninit:
    lea rdi, [rel fmsg_not_init]
    call future_set_invalid_state
    xor eax, eax
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "exception() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_method_exception

;; Future.set_result(self, result) -> None
;; Fails: 0
DEF_FUNC_LOCAL future_method_set_result
    NO_KEYWORDS_RET "set_result() takes no keyword arguments", .failed
    cmp rsi, 2
    jne .arity
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call future_set_result_impl
    ERR_M1 .failed
    LOAD_NONE rax
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "set_result() takes exactly one argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_method_set_result

;; Future.set_exception(self, exception) -> None
;; Fails: 0
DEF_FUNC_LOCAL future_method_set_exception
    NO_KEYWORDS_RET "set_exception() takes no keyword arguments", .failed
    cmp rsi, 2
    jne .arity
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call future_set_exception_impl
    ERR_M1 .failed
    LOAD_NONE rax
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "set_exception() takes exactly one argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_method_set_exception

;; Future.cancel(self, msg=None) -> bool
;; Fails: 0
FC_SELF equ 8
FC_MSG  equ 16
FC_FRAME equ 16
DEF_FUNC_LOCAL future_method_cancel, FC_FRAME
    mov rax, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov r8, [rdi]
    mov [rbp - FC_SELF], r8
    lea r9, [rel none_singleton]
    mov [rbp - FC_MSG], r9

    test rax, rax
    jz .no_kw
    mov rcx, [rax + PyTupleObject.ob_size]
    cmp rcx, 1
    ja .bad_kw
    test rcx, rcx
    jz .no_kw
    cmp rsi, 2
    jne .arity
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rdx, [rdx]
    mov r9, [rdi + 8]
    mov [rbp - FC_MSG], r9
    lea rdi, [rdx + PyStrObject.data]
    lea rsi, [rel fkw_msg]
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
    mov [rbp - FC_MSG], r9

.do_cancel:
    mov rdi, [rbp - FC_SELF]
    mov rsi, [rbp - FC_MSG]
    call future_cancel_impl
    ERR_M1 .failed
    test eax, eax
    jz .ret_false
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
END_FUNC future_method_cancel

;; Future.cancelled(self) -> bool
;; Fails: 0
DEF_FUNC_LOCAL future_method_cancelled
    NO_KEYWORDS_RET "cancelled() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .ret_false
    cmp dword [rdi + PyFutureObject.fut_state], FUT_STATE_CANCELLED
    jne .ret_false
    RET_TRUE
    leave
    ret
.ret_false:
    RET_FALSE
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "cancelled() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_method_cancelled

;; Future.done(self) -> bool
;; Fails: 0
DEF_FUNC_LOCAL future_method_done
    NO_KEYWORDS_RET "done() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .ret_false
    cmp dword [rdi + PyFutureObject.fut_state], FUT_STATE_PENDING
    je .ret_false
    RET_TRUE
    leave
    ret
.ret_false:
    RET_FALSE
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "done() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_method_done

;; Future.get_loop(self) -> loop
;; Fails: 0
DEF_FUNC_LOCAL future_method_get_loop
    NO_KEYWORDS_RET "get_loop() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    mov rax, [rdi + PyFutureObject.fut_loop]
    test rax, rax
    jz .uninit
    INCREF_V rax, rcx
    leave
    ret
.uninit:
    FAIL exc_RuntimeError_type, "Future object is not initialized.", .failed
.arity:
    FAIL exc_TypeError_type, "get_loop() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_method_get_loop

;; Future._make_cancelled_error(self) -> CancelledError
;; Fails: 0
DEF_FUNC_LOCAL future_method_make_cancelled_error
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
END_FUNC future_method_make_cancelled_error

;; Future.add_done_callback(self, fn, *, context=None) -> None
;; Fails: 0
FMA_SELF   equ 8
FMA_FN     equ 16
FMA_CTX    equ 24
FMA_OWNCTX equ 32
FMA_FRAME  equ 32
DEF_FUNC_LOCAL future_method_add_done_callback, FMA_FRAME
    mov rax, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov qword [rbp - FMA_OWNCTX], 0
    mov qword [rbp - FMA_CTX], 0

    test rax, rax
    jz .no_kw
    mov rcx, [rax + PyTupleObject.ob_size]
    cmp rcx, 1
    ja .bad_kw
    test rcx, rcx
    jz .no_kw
    cmp rsi, 3
    jne .arity
    mov r8, [rdi]
    mov [rbp - FMA_SELF], r8
    mov r8, [rdi + 8]
    mov [rbp - FMA_FN], r8
    mov r8, [rdi + 16]
    mov [rbp - FMA_CTX], r8
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rdx, [rdx]
    lea rdi, [rdx + PyStrObject.data]
    lea rsi, [rel fkw_context]
    call ap_strcmp
    test eax, eax
    jnz .bad_kw
    jmp .have_args

.no_kw:
    cmp rsi, 2
    jne .arity
    mov r8, [rdi]
    mov [rbp - FMA_SELF], r8
    mov r8, [rdi + 8]
    mov [rbp - FMA_FN], r8

.have_args:
    mov rdx, [rbp - FMA_CTX]
    test rdx, rdx
    jnz .have_ctx
    call async_get_copy_context
    ERR_NULL .failed
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call obj_call_n
    ERR_NULL .failed
    mov [rbp - FMA_CTX], rax
    mov [rbp - FMA_OWNCTX], rax
    mov rdx, rax

.have_ctx:
    mov rdi, [rbp - FMA_SELF]
    mov rsi, [rbp - FMA_FN]
    call future_add_done_callback_impl ; err: release ownctx before returning
    mov r8, rax
    mov rdi, [rbp - FMA_OWNCTX]
    XDECREF_V rdi, rcx
    test r8, r8
    jnz .failed
    LOAD_NONE rax
    leave
    ret

.arity:
    FAIL exc_TypeError_type, "add_done_callback() takes exactly 1 positional argument", .failed
.bad_kw:
    FAIL exc_TypeError_type, "add_done_callback() got an unexpected keyword argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_method_add_done_callback

;; Future.remove_done_callback(self, fn) -> int count removed
;; Fails: 0
FMR_SELF   equ 8
FMR_FN     equ 16
FMR_CLEARED equ 24
FMR_NEWL   equ 32
FMR_IDX    equ 40
FMR_ITEM   equ 48
FMR_ORIGLEN equ 56
FMR_FRAME  equ 64
DEF_FUNC_LOCAL future_method_remove_done_callback, FMR_FRAME
    NO_KEYWORDS_RET "remove_done_callback() takes no keyword arguments", .failed
    cmp rsi, 2
    jne .arity
    mov r8, [rdi]
    cmp qword [r8 + PyFutureObject.fut_loop], 0
    je .uninit
    mov [rbp - FMR_SELF], r8
    mov rax, [rdi + 8]
    mov [rbp - FMR_FN], rax
    mov qword [rbp - FMR_CLEARED], 0

    mov rax, [r8 + PyFutureObject.fut_callback0]
    test rax, rax
    jz .check_list
    mov [rbp - FMR_ITEM], rax
    INCREF_V rax, rcx
    mov rdi, rax
    mov rsi, [rbp - FMR_FN]
    mov edx, PY_EQ
    call obj_richcompare_bool   ; err: release item first
    push rax
    sub rsp, 8
    mov rdi, [rbp - FMR_ITEM]
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    ERR_M1 .failed
    test eax, eax
    jz .check_list
    mov r8, [rbp - FMR_SELF]
    mov rdi, [r8 + PyFutureObject.fut_callback0]
    mov qword [r8 + PyFutureObject.fut_callback0], 0
    XDECREF_V rdi, rcx
    mov r8, [rbp - FMR_SELF]
    mov rdi, [r8 + PyFutureObject.fut_context0]
    mov qword [r8 + PyFutureObject.fut_context0], 0
    XDECREF_V rdi, rcx
    mov qword [rbp - FMR_CLEARED], 1

.check_list:
    mov r8, [rbp - FMR_SELF]
    mov rax, [r8 + PyFutureObject.fut_callbacks]
    test rax, rax
    jz .ret_cleared
    mov rcx, [rax + PyListObject.ob_size]
    test rcx, rcx
    jz .clear_empty_list
    mov [rbp - FMR_ORIGLEN], rcx

    xor edi, edi
    call list_new
    mov [rbp - FMR_NEWL], rax
    mov qword [rbp - FMR_IDX], 0

.scan_loop:
    mov r8, [rbp - FMR_SELF]
    mov rax, [r8 + PyFutureObject.fut_callbacks]
    test rax, rax
    jz .scan_done
    mov rcx, [rbp - FMR_IDX]
    cmp rcx, [rax + PyListObject.ob_size]
    jge .scan_done
    mov rdx, [rax + PyListObject.ob_item]
    mov rdx, [rdx + rcx * 8]    ; (cb, ctx) tuple
    mov [rbp - FMR_ITEM], rdx
    INCREF rdx
    mov rdi, [rdx + PyTupleObject.ob_item]
    mov rdi, [rdi]              ; cb
    mov rsi, [rbp - FMR_FN]
    mov edx, PY_EQ
    call obj_richcompare_bool
    ERR_M1 .fail_item_newl
    test eax, eax
    jnz .drop_item
    mov rdi, [rbp - FMR_NEWL]
    mov rsi, [rbp - FMR_ITEM]
    call list_append
    ERR_M1 .fail_item_newl
.drop_item:
    mov rdi, [rbp - FMR_ITEM]
    call obj_decref
    inc qword [rbp - FMR_IDX]
    jmp .scan_loop

.scan_done:
    mov r8, [rbp - FMR_SELF]
    mov rdx, [rbp - FMR_NEWL]
    mov rcx, [rdx + PyListObject.ob_size]
    mov rax, [r8 + PyFutureObject.fut_callbacks]
    test rax, rax
    jz .cleared_during_scan
    test rcx, rcx
    jz .removed_all

    mov r9, [rax + PyListObject.ob_size]
    sub r9, rcx
    test r9, r9
    jz .none_removed
    mov [r8 + PyFutureObject.fut_callbacks], rdx
    mov rdi, rax
    push r9
    sub rsp, 8
    call obj_decref
    add rsp, 8
    pop r9
    add r9, [rbp - FMR_CLEARED]
    mov rax, r9
    V_PACK_I64 rax, rcx
    leave
    ret

.none_removed:
    mov rdi, rdx
    call obj_decref
    jmp .ret_cleared

.removed_all:
    mov r9, [rax + PyListObject.ob_size]
    mov qword [r8 + PyFutureObject.fut_callbacks], 0
    push r9
    sub rsp, 8
    mov rdi, rax
    call obj_decref
    mov rdi, [rbp - FMR_NEWL]
    call obj_decref
    add rsp, 8
    pop r9
    add r9, [rbp - FMR_CLEARED]
    mov rax, r9
    V_PACK_I64 rax, rcx
    leave
    ret

.cleared_during_scan:
    mov rdi, rdx
    call obj_decref
    mov rax, [rbp - FMR_ORIGLEN]
    add rax, [rbp - FMR_CLEARED]
    V_PACK_I64 rax, rcx
    leave
    ret

.clear_empty_list:
    mov qword [r8 + PyFutureObject.fut_callbacks], 0
    mov rdi, rax
    call obj_decref
.ret_cleared:
    mov rax, [rbp - FMR_CLEARED]
    V_PACK_I64 rax, rcx
    leave
    ret

.fail_item_newl:
    mov rdi, [rbp - FMR_ITEM]
    call obj_decref
    mov rdi, [rbp - FMR_NEWL]
    call obj_decref
    jmp .failed
.uninit:
    FAIL exc_RuntimeError_type, "Future object is not initialized.", .failed
.arity:
    FAIL exc_TypeError_type, "remove_done_callback() takes exactly one argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_method_remove_done_callback

;; ============================================================================
;; Future getset getters & setters
;; ============================================================================

;; Future._state getter(rdi = self) -> str
;; Fails: 0
DEF_FUNC_LOCAL future_get_state
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .uninit
    mov eax, [rdi + PyFutureObject.fut_state]
    cmp eax, FUT_STATE_PENDING
    je .pending
    cmp eax, FUT_STATE_CANCELLED
    je .cancelled
    mov rax, [rel fut_str_finished]
    INCREF rax
    leave
    ret
.pending:
    mov rax, [rel fut_str_pending]
    INCREF rax
    leave
    ret
.cancelled:
    mov rax, [rel fut_str_cancelled]
    INCREF rax
    leave
    ret
.uninit:
    FAIL exc_RuntimeError_type, "Future object is not initialized.", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_get_state

;; Future._asyncio_future_blocking getter(rdi = self) -> bool
DEF_FUNC_LOCAL future_get_blocking
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .ret_false
    cmp dword [rdi + PyFutureObject.fut_blocking], 0
    je .ret_false
    RET_TRUE
    leave
    ret
.ret_false:
    RET_FALSE
    leave
    ret
END_FUNC future_get_blocking

;; Future._asyncio_future_blocking setter(rdi = self, rsi = val) -> 0 / -1
;; Fails: -1
FGS_SELF equ 8
FGS_FRAME equ 16
DEF_FUNC_LOCAL future_set_blocking, FGS_FRAME
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .uninit
    test rsi, rsi
    jz .no_del
    mov [rbp - FGS_SELF], rdi
    mov rdi, rsi
    call obj_is_true
    ERR_M1 .failed
    mov rdi, [rbp - FGS_SELF]
    mov [rdi + PyFutureObject.fut_blocking], eax
    xor eax, eax
    leave
    ret
.uninit:
    FAIL exc_RuntimeError_type, "Future object is not initialized.", .failed
.no_del:
    FAIL exc_AttributeError_type, "cannot delete attribute", .failed
.failed:
    mov rax, -1
    leave
    ret
END_FUNC future_set_blocking

;; Future._log_traceback getter(rdi = self) -> bool
;; Fails: 0
DEF_FUNC_LOCAL future_get_log_tb
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .uninit
    cmp dword [rdi + PyFutureObject.fut_log_tb], 0
    je .ret_false
    RET_TRUE
    leave
    ret
.ret_false:
    RET_FALSE
    leave
    ret
.uninit:
    FAIL exc_RuntimeError_type, "Future object is not initialized.", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_get_log_tb

;; Future._log_traceback setter(rdi = self, rsi = val) -> 0 / -1
;; Fails: -1
DEF_FUNC_LOCAL future_set_log_tb, FGS_FRAME
    test rsi, rsi
    jz .no_del
    mov [rbp - FGS_SELF], rdi
    mov rdi, rsi
    call obj_is_true
    ERR_M1 .failed
    test eax, eax
    jnz .only_false
    mov rdi, [rbp - FGS_SELF]
    mov dword [rdi + PyFutureObject.fut_log_tb], 0
    xor eax, eax
    leave
    ret
.only_false:
    FAIL exc_ValueError_type, "_log_traceback can only be set to False", .failed
.no_del:
    FAIL exc_AttributeError_type, "cannot delete attribute", .failed
.failed:
    mov rax, -1
    leave
    ret
END_FUNC future_set_log_tb

;; Future._loop getter(rdi = self) -> loop or None
DEF_FUNC_LOCAL future_get_loop
    mov rax, [rdi + PyFutureObject.fut_loop]
    test rax, rax
    jz .ret_none
    INCREF_V rax, rcx
    leave
    ret
.ret_none:
    LOAD_NONE rax
    leave
    ret
END_FUNC future_get_loop

;; Future._callbacks getter(rdi = self) -> list of (cb, ctx) or None
;; Fails: 0
FGC_FUT  equ 8
FGC_LIST equ 16
FGC_TUP  equ 24
FGC_IDX  equ 32
FGC_FRAME equ 32
DEF_FUNC_LOCAL future_get_callbacks, FGC_FRAME
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .uninit
    mov [rbp - FGC_FUT], rdi
    xor ecx, ecx
    cmp qword [rdi + PyFutureObject.fut_callback0], 0
    je .no_cb0_len
    inc rcx
.no_cb0_len:
    mov rax, [rdi + PyFutureObject.fut_callbacks]
    test rax, rax
    jz .have_len
    add rcx, [rax + PyListObject.ob_size]
.have_len:
    test rcx, rcx
    jz .ret_none

    xor edi, edi
    call list_new
    mov [rbp - FGC_LIST], rax

    mov rdi, [rbp - FGC_FUT]
    cmp qword [rdi + PyFutureObject.fut_callback0], 0
    je .copy_list
    mov edi, 2
    call tuple_new
    mov [rbp - FGC_TUP], rax
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdi, [rbp - FGC_FUT]
    mov rdx, [rdi + PyFutureObject.fut_callback0]
    INCREF_V rdx, rsi
    mov [rcx], rdx
    mov rdx, [rdi + PyFutureObject.fut_context0]
    INCREF_V rdx, rsi
    mov [rcx + 8], rdx
    mov rdi, [rbp - FGC_LIST]
    mov rsi, rax
    call list_append            ; err: list_append on fresh list cannot fail
    mov rdi, [rbp - FGC_TUP]
    call obj_decref

.copy_list:
    mov rdi, [rbp - FGC_FUT]
    mov rax, [rdi + PyFutureObject.fut_callbacks]
    test rax, rax
    jz .done
    mov qword [rbp - FGC_IDX], 0
.copy_loop:
    mov rdi, [rbp - FGC_FUT]
    mov rax, [rdi + PyFutureObject.fut_callbacks]
    mov rcx, [rbp - FGC_IDX]
    cmp rcx, [rax + PyListObject.ob_size]
    jge .done
    mov rdx, [rax + PyListObject.ob_item]
    mov rsi, [rdx + rcx * 8]
    mov rdi, [rbp - FGC_LIST]
    call list_append            ; err: list_append on fresh list cannot fail
    inc qword [rbp - FGC_IDX]
    jmp .copy_loop

.done:
    mov rax, [rbp - FGC_LIST]
    leave
    ret
.ret_none:
    LOAD_NONE rax
    leave
    ret
.uninit:
    FAIL exc_RuntimeError_type, "Future object is not initialized.", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_get_callbacks

;; Future._result getter(rdi = self) -> result or None
;; Fails: 0
DEF_FUNC_LOCAL future_get_result_attr
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .uninit
    mov rax, [rdi + PyFutureObject.fut_result]
    test rax, rax
    jz .ret_none
    INCREF_V rax, rcx
    leave
    ret
.ret_none:
    LOAD_NONE rax
    leave
    ret
.uninit:
    FAIL exc_RuntimeError_type, "Future object is not initialized.", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_get_result_attr

;; Future._exception getter(rdi = self) -> exception or None
;; Fails: 0
DEF_FUNC_LOCAL future_get_exception_attr
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .uninit
    mov rax, [rdi + PyFutureObject.fut_exception]
    test rax, rax
    jz .ret_none
    INCREF_V rax, rcx
    leave
    ret
.ret_none:
    LOAD_NONE rax
    leave
    ret
.uninit:
    FAIL exc_RuntimeError_type, "Future object is not initialized.", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_get_exception_attr

;; Future._source_traceback getter(rdi = self) -> list or None
DEF_FUNC_LOCAL future_get_source_tb
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .ret_none
    mov rax, [rdi + PyFutureObject.fut_source_tb]
    test rax, rax
    jz .ret_none
    INCREF_V rax, rcx
    leave
    ret
.ret_none:
    LOAD_NONE rax
    leave
    ret
END_FUNC future_get_source_tb

;; Future._cancel_message getter(rdi = self) -> Value or None
DEF_FUNC_LOCAL future_get_cancel_msg
    mov rax, [rdi + PyFutureObject.fut_cancel_msg]
    test rax, rax
    jz .ret_none
    INCREF_V rax, rcx
    leave
    ret
.ret_none:
    LOAD_NONE rax
    leave
    ret
END_FUNC future_get_cancel_msg

;; Future._cancel_message setter(rdi = self, rsi = msg) -> 0 / -1
;; Fails: -1
DEF_FUNC_LOCAL future_set_cancel_msg
    test rsi, rsi
    jz .no_del
    INCREF_V rsi, rcx
    mov rdx, [rdi + PyFutureObject.fut_cancel_msg]
    mov [rdi + PyFutureObject.fut_cancel_msg], rsi
    XDECREF_V rdx, rcx
    xor eax, eax
    leave
    ret
.no_del:
    FAIL exc_AttributeError_type, "cannot delete attribute", .failed
.failed:
    mov rax, -1
    leave
    ret
END_FUNC future_set_cancel_msg

;; ============================================================================
;; FutureIter — native iterator returned by Future.__await__ / Future.__iter__
;; ============================================================================

;; future_new_iter(rdi = PyFutureObject*) -> owned PyFutureIterObject*
;; Fails: 0
DEF_FUNC future_new_iter, 8
    push rbx
    mov rbx, rdi
    cmp qword [rbx + PyFutureObject.fut_loop], 0
    je .uninit
    mov edi, PyFutureIterObject_size
    lea rsi, [rel future_iter_type]
    call gc_alloc
    INCREF rbx
    mov [rax + PyFutureIterObject.fi_future], rbx
    mov qword [rax + PyFutureIterObject.fi_pad1], 0
    mov qword [rax + PyFutureIterObject.fi_pad2], 0
    mov qword [rax + PyFutureIterObject.fi_pad3], 0
    mov qword [rax + PyFutureIterObject.gi_return_value], 0
    push rax
    sub rsp, 8
    mov rdi, rax
    call gc_track
    add rsp, 8
    pop rax
    pop rbx
    leave
    ret
.uninit:
    FAIL exc_RuntimeError_type, "Future object is not initialized.", .failed
.failed:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC future_new_iter

;; Future.__await__(self) / Future.__iter__(self) -> FutureIter
;; Fails: 0
DEF_FUNC_LOCAL future_method_await
    NO_KEYWORDS_RET "__await__() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    call future_new_iter        ; err: propagate
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "__await__() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_method_await

;; future_iter_self(rdi = self) -> owned self
DEF_FUNC_LOCAL future_iter_self
    INCREF rdi
    mov rax, rdi
    leave
    ret
END_FUNC future_iter_self

;; future_iter_clear(rdi = PyFutureIterObject*) -> 0
DEF_FUNC_LOCAL future_iter_clear, 8
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyFutureIterObject.fi_future]
    mov qword [rbx + PyFutureIterObject.fi_future], 0
    XDECREF_V rdi, rax
    mov rdi, [rbx + PyFutureIterObject.gi_return_value]
    mov qword [rbx + PyFutureIterObject.gi_return_value], 0
    XDECREF_V rdi, rax
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC future_iter_clear

;; future_iter_traverse(rdi = PyFutureIterObject*, r14 = visit) -> 0
DEF_FUNC_LOCAL future_iter_traverse, 8
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyFutureIterObject.fi_future]
    VISIT_PTR rdi
    mov rdi, [rbx + PyFutureIterObject.gi_return_value]
    VISIT_V rdi, rax
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC future_iter_traverse

;; future_iter_dealloc(rdi = PyFutureIterObject*) -> void
DEF_FUNC_LOCAL future_iter_dealloc, 8
    push rbx
    mov rbx, rdi
    call future_iter_clear
    mov rdi, rbx
    call gc_dealloc
    pop rbx
    leave
    ret
END_FUNC future_iter_dealloc

;; future_iter_iternext(rdi = PyFutureIterObject*) -> yielded Value, or 0
;; On completion of a resolved Future, stores result in gi_return_value and
;; returns 0 without setting StopIteration (so op_send and builtin_next_fn
;; both see the result cleanly). On error/exception, sets current_exception
;; and returns 0.
;; Fails: 0?
FIIX_IT  equ 8
FIIX_FUT equ 16
FIIX_FRAME equ 16
DEF_FUNC_LOCAL future_iter_iternext, FIIX_FRAME
    mov [rbp - FIIX_IT], rdi
    mov rax, [rdi + PyFutureIterObject.fi_future]
    test rax, rax
    jz .exhausted

    cmp dword [rax + PyFutureObject.fut_state], FUT_STATE_PENDING
    jne .done_future

    cmp dword [rax + PyFutureObject.fut_blocking], 0
    jne .not_awaited
    mov dword [rax + PyFutureObject.fut_blocking], 1
    INCREF rax
    leave
    ret

.not_awaited:
    FAIL exc_RuntimeError_type, "await wasn't used with future", .ret_zero

.done_future:
    mov [rbp - FIIX_FUT], rax
    mov qword [rdi + PyFutureIterObject.fi_future], 0
    mov rdi, rax
    cmp qword [rdi + PyFutureObject.fut_loop], 0
    je .uninit_fut
    call future_get_result_impl
    ERR_NULL .release_fut_zero
    test edx, edx
    jnz .install_exc

    ; Normal result: store in it->gi_return_value (replacing any old one).
    mov rdi, [rbp - FIIX_IT]
    mov rcx, [rdi + PyFutureIterObject.gi_return_value]
    mov [rdi + PyFutureIterObject.gi_return_value], rax
    XDECREF_V rcx, rdx
    mov rdi, [rbp - FIIX_FUT]
    call obj_decref
    xor eax, eax
    leave
    ret

.install_exc:
    mov rdi, rax
    call exc_install
.release_fut_zero:
    mov rdi, [rbp - FIIX_FUT]
    call obj_decref
    mov rdi, [rbp - FIIX_IT]
    mov rax, [rdi + PyFutureIterObject.gi_return_value]
    mov qword [rdi + PyFutureIterObject.gi_return_value], 0
    XDECREF_V rax, rcx
    xor eax, eax
    leave
    ret

.uninit_fut:
    lea rdi, [rel fmsg_not_init]
    call future_set_invalid_state
    jmp .release_fut_zero

.exhausted:
    mov rax, [rdi + PyFutureIterObject.gi_return_value]
    mov qword [rdi + PyFutureIterObject.gi_return_value], 0
    XDECREF_V rax, rcx
.ret_zero:
    xor eax, eax
    leave
    ret
END_FUNC future_iter_iternext

;; future_iter_raise_stop(rdi = PyFutureIterObject*) -> rax = 0 (StopIteration pending)
DEF_FUNC_LOCAL future_iter_raise_stop
    mov rsi, [rdi + PyFutureIterObject.gi_return_value]
    test rsi, rsi
    jz .bare
    lea rax, [rel none_singleton]
    cmp rsi, rax
    jne .with_val
.bare:
    xor esi, esi
.with_val:
    lea rdi, [rel exc_StopIteration_type]
    call exc_new
    mov rdi, rax
    call exc_install
    xor eax, eax
    leave
    ret
END_FUNC future_iter_raise_stop

;; FutureIter.send(self, value) -> yielded Value
;; Fails: 0
FIS_IT equ 8
FIS_FRAME equ 16
DEF_FUNC_LOCAL future_iter_method_send, FIS_FRAME
    NO_KEYWORDS_RET "send() takes no keyword arguments", .failed
    cmp rsi, 2
    jne .arity
    mov rdi, [rdi]
    mov [rbp - FIS_IT], rdi
    call future_iter_iternext
    ERR_PENDING .failed
    test rax, rax
    jnz .ok
    mov rdi, [rbp - FIS_IT]
    call future_iter_raise_stop
.ok:
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "send() takes exactly one argument", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_iter_method_send

;; FutureIter.__next__(self) -> yielded Value
;; Fails: 0
DEF_FUNC_LOCAL future_iter_method_next, FIS_FRAME
    NO_KEYWORDS_RET "__next__() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    mov [rbp - FIS_IT], rdi
    call future_iter_iternext
    ERR_PENDING .failed
    test rax, rax
    jnz .ok
    mov rdi, [rbp - FIS_IT]
    call future_iter_raise_stop
.ok:
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "__next__() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_iter_method_next

;; FutureIter.__iter__(self) -> self
;; Fails: 0
DEF_FUNC_LOCAL future_iter_method_iter
    NO_KEYWORDS_RET "__iter__() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rax, [rdi]
    INCREF rax
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "__iter__() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_iter_method_iter

;; FutureIter.close(self) -> None
;; Fails: 0
DEF_FUNC_LOCAL future_iter_method_close
    NO_KEYWORDS_RET "close() takes no keyword arguments", .failed
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    call future_iter_clear
    LOAD_NONE rax
    leave
    ret
.arity:
    FAIL exc_TypeError_type, "close() takes no arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_iter_method_close

;; FutureIter.throw(self, type[, val[, tb]]) -> 0 (raises exception)
;; Fails: 0
FIT_SELF equ 8
FIT_TYPE equ 16
FIT_VAL  equ 24
FIT_TB   equ 32
FIT_EXC  equ 40
FIT_FRAME equ 48
DEF_FUNC_LOCAL future_iter_method_throw, FIT_FRAME
    NO_KEYWORDS_RET "throw() takes no keyword arguments", .failed
    cmp rsi, 2
    jb .arity
    cmp rsi, 4
    ja .arity

    mov rax, [rdi]
    mov [rbp - FIT_SELF], rax
    mov rax, [rdi + 8]
    mov [rbp - FIT_TYPE], rax
    mov qword [rbp - FIT_VAL], 0
    mov qword [rbp - FIT_TB], 0
    cmp rsi, 3
    jb .args_read
    mov rax, [rdi + 16]
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .check_tb
    mov [rbp - FIT_VAL], rax
.check_tb:
    cmp rsi, 4
    jb .warn_throw
    mov rax, [rdi + 24]
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .warn_throw
    mov [rbp - FIT_TB], rax
.warn_throw:
    lea rdi, [rel fmsg_throw_deprecated]
    call deprecation_warn
    ERR_NULL .failed
    mov rax, [rbp - FIT_TB]
    test rax, rax
    jz .args_read
    V_TEST_PTR rax, rdx
    ja .bad_tb
    mov rdx, [rax + PyObject.ob_type]
    lea rcx, [rel traceback_type]
    cmp rdx, rcx
    jne .bad_tb

.args_read:
    mov rax, [rbp - FIT_TYPE]
    V_TEST_PTR rax, rcx
    ja .bad_exc_type
    test rax, rax
    jz .bad_exc_type

    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel type_type]
    cmp rcx, rdx
    je .is_class
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jnz .is_class

    ; Exception instance?
    mov rdi, rcx
    call type_is_exc_subclass
    test eax, eax
    jz .bad_exc_type
    cmp qword [rbp - FIT_VAL], 0
    jne .inst_with_val
    mov rax, [rbp - FIT_TYPE]
    INCREF rax
    mov [rbp - FIT_EXC], rax
    jmp .apply_tb

.is_class:
    mov rdi, rax
    call type_is_exc_subclass
    test eax, eax
    jz .bad_exc_type
    mov rax, [rbp - FIT_VAL]
    test rax, rax
    jz .call_no_val
    V_TEST_PTR rax, rcx
    ja .call_one_val
    mov rdi, rax
    mov rsi, [rbp - FIT_TYPE]
    call exc_isinstance         ; err: type is validated exc class
    test eax, eax
    jz .call_one_val
    mov rax, [rbp - FIT_VAL]
    INCREF rax
    mov [rbp - FIT_EXC], rax
    jmp .apply_tb

.call_one_val:
    mov rdi, [rbp - FIT_TYPE]
    lea rsi, [rbp - FIT_VAL]
    mov edx, 1
    call obj_call_n
    ERR_NULL .failed
    mov [rbp - FIT_EXC], rax
    jmp .apply_tb

.call_no_val:
    mov rdi, [rbp - FIT_TYPE]
    xor esi, esi
    xor edx, edx
    call obj_call_n
    ERR_NULL .failed
    mov [rbp - FIT_EXC], rax

.apply_tb:
    mov rcx, [rbp - FIT_TB]
    test rcx, rcx
    jz .finish_throw
    INCREF rcx
    mov rax, [rbp - FIT_EXC]
    mov rdx, [rax + PyExceptionObject.exc_tb]
    mov [rax + PyExceptionObject.exc_tb], rcx
    test rdx, rdx
    jz .finish_throw
    mov rdi, rdx
    call obj_decref

.finish_throw:
    mov rdi, [rbp - FIT_SELF]
    call future_iter_clear
    mov rdi, [rbp - FIT_EXC]
    call exc_install
    xor eax, eax
    leave
    ret

.bad_tb:
    FAIL exc_TypeError_type, "throw() third argument must be a traceback", .failed
.inst_with_val:
    FAIL exc_TypeError_type, "instance exception may not have a separate value", .failed
.bad_exc_type:
    FAIL exc_TypeError_type, "exceptions must be classes deriving BaseException or instances of such a class", .failed
.arity:
    FAIL exc_TypeError_type, "throw() takes from 1 to 3 positional arguments", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC future_iter_method_throw

;; ============================================================================
;; async_future_init(r12 = module dict) -> void
;; Builds the native Future heaptype and FutureIter static type's dict, and
;; exports Future into the module dict.
;; ============================================================================
AFI_NS   equ 8
AFI_NAME equ 16
AFI_KEY  equ 24
AFI_VAL  equ 32
AFI_FRAME equ 40            ; + 1 push (rbx) = 48
DEF_FUNC async_future_init, AFI_FRAME
    push rbx

    ; Intern the three state strings once.
    lea rdi, [rel fstr_pending]
    call str_intern_cstr
    mov [rel fut_str_pending], rax
    lea rdi, [rel fstr_cancelled]
    call str_intern_cstr
    mov [rel fut_str_cancelled], rax
    lea rdi, [rel fstr_finished]
    call str_intern_cstr
    mov [rel fut_str_finished], rax

    ; Populate FutureIter's tp_dict.
    call dict_new
    mov rbx, rax
    mov [rel future_iter_type + PyTypeObject.tp_dict], rbx
    mov rdi, rbx
    lea rsi, [rel fn_send]
    lea rdx, [rel future_iter_method_send]
    call async_add_method
    mov rdi, rbx
    lea rsi, [rel fn_throw]
    lea rdx, [rel future_iter_method_throw]
    call async_add_method
    mov rdi, rbx
    lea rsi, [rel fn_close]
    lea rdx, [rel future_iter_method_close]
    call async_add_method
    mov rdi, rbx
    lea rsi, [rel fn_dunder_iter]
    lea rdx, [rel future_iter_method_iter]
    call async_add_method
    mov rdi, rbx
    lea rsi, [rel fn_dunder_next]
    lea rdx, [rel future_iter_method_next]
    call async_add_method
    lea rdi, [rel future_iter_type]
    call type_stamp_methods

    ; Build Future namespace dict.
    call dict_new
    mov rbx, rax
    mov [rbp - AFI_NS], rax

    ; __module__ = "_asyncio"
    lea rdi, [rel fn_dunder_module]
    call str_from_cstr_heap
    mov [rbp - AFI_KEY], rax
    lea rdi, [rel fmod_asyncio]
    call str_from_cstr_heap
    mov [rbp - AFI_VAL], rax
    mov rdi, rbx
    mov rsi, [rbp - AFI_KEY]
    mov rdx, rax
    call dict_set_str
    mov rdi, [rbp - AFI_VAL]
    call obj_decref
    mov rdi, [rbp - AFI_KEY]
    call obj_decref

    ; __qualname__ = "Future"
    lea rdi, [rel fn_dunder_qualname]
    call str_from_cstr_heap
    mov [rbp - AFI_KEY], rax
    lea rdi, [rel fname_future]
    call str_from_cstr_heap
    mov [rbp - AFI_VAL], rax
    mov rdi, rbx
    mov rsi, [rbp - AFI_KEY]
    mov rdx, rax
    call dict_set_str
    mov rdi, [rbp - AFI_VAL]
    call obj_decref
    mov rdi, [rbp - AFI_KEY]
    call obj_decref

    ; Register Future methods.
%macro FUT_METHOD 2
    mov rdi, rbx
    lea rsi, [rel %1]
    lea rdx, [rel %2]
    call async_add_method
%endmacro
    FUT_METHOD fn_dunder_init,   future_method_init
    FUT_METHOD fn_dunder_del,    future_method_del
    FUT_METHOD fn_dunder_repr,   future_method_repr
    FUT_METHOD fn_dunder_await,  future_method_await
    FUT_METHOD fn_dunder_iter,   future_method_await
    FUT_METHOD fn_result,        future_method_result
    FUT_METHOD fn_exception,     future_method_exception
    FUT_METHOD fn_set_result,    future_method_set_result
    FUT_METHOD fn_set_exception, future_method_set_exception
    FUT_METHOD fn_add_cb,        future_method_add_done_callback
    FUT_METHOD fn_rem_cb,        future_method_remove_done_callback
    FUT_METHOD fn_cancel,        future_method_cancel
    FUT_METHOD fn_cancelled,     future_method_cancelled
    FUT_METHOD fn_done,          future_method_done
    FUT_METHOD fn_get_loop,      future_method_get_loop
    FUT_METHOD fn_make_canc_err, future_method_make_cancelled_error

    mov rdi, rbx
    call add_class_getitem

    ; Build the Future heaptype via type_from_parts.
    lea rdi, [rel fname_future]
    call str_from_cstr_heap
    mov [rbp - AFI_NAME], rax
    mov rdi, rax
    xor esi, esi                ; bases = (object,)
    mov rdx, [rbp - AFI_NS]     ; ownership transferred to type_from_parts
    call type_from_parts        ; err: cannot fail with valid static namespace
    mov rbx, rax
    mov [rel future_type], rbx
    mov rdi, [rbp - AFI_NAME]
    call obj_decref

    ; Register getset descriptors now that future_type exists as gs_owner.
%macro FUT_GETSET 3
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
    FUT_GETSET fgs_state,        future_get_state,          0
    FUT_GETSET fgs_blocking,     future_get_blocking,       future_set_blocking
    FUT_GETSET fgs_loop,         future_get_loop,           0
    FUT_GETSET fgs_callbacks,    future_get_callbacks,      0
    FUT_GETSET fgs_result,       future_get_result_attr,    0
    FUT_GETSET fgs_exception,    future_get_exception_attr, 0
    FUT_GETSET fgs_log_tb,       future_get_log_tb,         future_set_log_tb
    FUT_GETSET fgs_source_tb,    future_get_source_tb,      0
    FUT_GETSET fgs_cancel_msg,   future_get_cancel_msg,     future_set_cancel_msg

    ; Stamp methods and refresh attribute/del flags after adding getsets.
    mov rdi, rbx
    call type_stamp_methods
    mov rdi, rbx
    call type_refresh_attr_flags

    ; Patch layout and lifecycle slots on Future.
    mov qword [rbx + PyTypeObject.tp_basicsize], PyFutureObject_size
    lea rax, [rel future_dealloc]
    mov [rbx + PyTypeObject.tp_dealloc], rax
    lea rax, [rel future_traverse]
    mov [rbx + PyTypeObject.tp_traverse], rax
    lea rax, [rel future_clear]
    mov [rbx + PyTypeObject.tp_clear], rax
    lea rax, [rel future_new_iter]
    mov [rbx + PyTypeObject.tp_iter], rax
    or qword [rbx + PyTypeObject.tp_flags], TYPE_FLAG_AWAITABLE

    ; Export Future in the module dictionary.
    lea rdi, [rel fname_future]
    call str_from_cstr_heap
    mov [rbp - AFI_KEY], rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, rbx
    call dict_set_str
    mov rdi, [rbp - AFI_KEY]
    call obj_decref

    pop rbx
    leave
    ret
END_FUNC async_future_init

section .data
align 8
global future_iter_type
future_iter_type:
    dq 1                        ; ob_refcnt
    dq type_type                ; ob_type
    dq fname_future_iter        ; tp_name
    dq PyFutureIterObject_size  ; tp_basicsize
    dq future_iter_dealloc      ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq future_iter_self         ; tp_iter
    dq future_iter_iternext     ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict (populated in async_future_init)
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC        ; tp_flags
    dq 0                        ; tp_bases
    dq future_iter_traverse     ; tp_traverse
    dq future_iter_clear        ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

section .bss
alignb 8
fut_fin_buf: resb 256

section .rodata
fmod_asyncio:       db "_asyncio", 0
fname_future:       db "Future", 0
fname_future_iter:  db "_asyncio.FutureIter", 0
fstr_pending:       db "PENDING", 0
fstr_cancelled:     db "CANCELLED", 0
fstr_finished:      db "FINISHED", 0

fn_dunder_module:   db "__module__", 0
fn_dunder_qualname: db "__qualname__", 0
fn_dunder_init:     db "__init__", 0
fn_dunder_del:      db "__del__", 0
fn_dunder_repr:     db "__repr__", 0
fn_dunder_await:    db "__await__", 0
fn_dunder_iter:     db "__iter__", 0
fn_dunder_next:     db "__next__", 0
fn_result:          db "result", 0
fn_exception:       db "exception", 0
fn_set_result:      db "set_result", 0
fn_set_exception:   db "set_exception", 0
fn_add_cb:          db "add_done_callback", 0
fn_rem_cb:          db "remove_done_callback", 0
fn_cancel:          db "cancel", 0
fn_cancelled:       db "cancelled", 0
fn_done:            db "done", 0
fn_get_loop:        db "get_loop", 0
fn_make_canc_err:   db "_make_cancelled_error", 0
fn_send:            db "send", 0
fn_throw:           db "throw", 0
fn_close:           db "close", 0
fn_get_debug:       db "get_debug", 0
fn_call_exc_handler: db "call_exception_handler", 0

fgs_state:          db "_state", 0
fgs_blocking:       db "_asyncio_future_blocking", 0
fgs_loop:           db "_loop", 0
fgs_callbacks:      db "_callbacks", 0
fgs_result:         db "_result", 0
fgs_exception:      db "_exception", 0
fgs_log_tb:         db "_log_traceback", 0
fgs_source_tb:      db "_source_traceback", 0
fgs_cancel_msg:     db "_cancel_message", 0

fkw_loop:           db "loop", 0
fkw_msg:            db "msg", 0
fkw_context:        db "context", 0

fkey_message:       db "message", 0
fkey_exception:     db "exception", 0
fkey_future:        db "future", 0
fkey_source_tb:     db "source_traceback", 0

fmsg_not_init:      db "Future object is not initialized.", 0
fmsg_invalid_state: db "invalid state", 0
fmsg_result_not_set: db "Result is not set.", 0
fmsg_exc_not_set:   db "Exception is not set.", 0
fmsg_stopiter_future: db "StopIteration interacts badly with generators and cannot be raised into a Future", 0
fmsg_exc_unretrieved: db " exception was never retrieved", 0
fmsg_throw_deprecated: db "the (type, exc, tb) signature of throw() is deprecated, use the single-arg signature instead.", 0
