; asyncgen.asm - the awaitables an async generator hands out, and what drives
; them.
;
; An async generator yields through objects rather than directly: `__anext__()`
; and `asend(v)` answer an AsyncGenASend, `aclose()` and `athrow(exc)` answer an
; AsyncGenAThrow, and each `yield` inside the generator arrives wrapped in an
; AsyncGenWrappedValue so the machinery can tell "the generator yielded" from
; "the generator awaited something".  This file is those three objects: the two
; drives, the constructors, the by-name send/throw/close, and the wrapped value.
;
; Split off generator.asm when it reached the 100k cap.  The seam is the one the
; names already draw: what stayed is the generator, the coroutine and the async
; generator THEMSELVES -- construction, resumption, throw, close, dealloc and
; the collector's view of them -- and their type tables, which this file reaches
; by name.
;
; The rule that runs through all of it: a wrapped value is the generator's own
; `yield` and COMPLETES the await it arrived in, so by name it becomes
; StopIteration(value); anything else that comes out is an `await` inside the
; generator passing outward, and reaches the caller unchanged.

%include "macros.inc"
%include "object.inc"
%include "value.inc"

extern ap_malloc
extern ap_free
extern obj_decref
extern obj_incref
extern obj_dealloc
extern none_singleton
extern type_type
extern raise_exception
extern raise_exception_obj
extern exc_new
extern exc_TypeError_type
extern exc_StopIteration_type
extern exc_RuntimeError_type
extern exc_GeneratorExit_type
extern exc_StopAsyncIteration_type
extern current_exception
extern eval_exception_unwind
extern builtin_func_new
extern type_is_subtype
extern type_is_exc_subclass
extern user_type_metatype
extern exc_metatype
extern deprecation_warn
extern type_call
extern gen_throw
extern gen_close
extern gen_send
extern async_gen_type
extern async_gen_wrapped_type
extern async_gen_asend_type
extern async_gen_athrow_type
extern eval_frame
extern frame_free
extern async_gen_iternext

; The three lazily built builtins this file's by-name methods are reached
; through; they came over with the methods that fill them.
section .bss
align 8
_agen_asend_cache: resq 1
_agen_aclose_cache: resq 1
_agen_athrow_cache: resq 1

section .text

;; ============================================================================
;; ags_iternext(AsyncGenASend *self) -> one Value, or 0
;; Called by SEND loop. Drives the async generator.
;;
;; State machine:
;;   0 (initial)  → resume async gen, return yielded value, go to state 1
;;   1 (yielded)  → return NULL (SEND sees exhausted, reads gi_return_value)
;;   2 (closed)   → raise StopAsyncIteration
;;
;; rdi = AsyncGenASend wrapper
;; Returns: a Value in rax, or 0 for exhaustion.  tp_iternext's contract is one
;; Value; every producer packs and every consumer unpacks exactly once.
;; ============================================================================
DEF_FUNC ags_iternext
    push rbx
    push r12

    mov rbx, rdi               ; rbx = wrapper

    ; Check state
    mov eax, [rbx + AsyncGenASend.ags_state]
    cmp eax, 1
    je .agsi_second_call
    cmp eax, 2
    jae .agsi_closed

    ; State 0: initial — resume the async generator
    mov r12, [rbx + AsyncGenASend.ags_gen] ; r12 = async generator

    ; Check if generator is exhausted
    mov rdi, [r12 + PyGenObject.gi_frame]
    test rdi, rdi
    jz .agsi_gen_exhausted

    ; Check if already running
    cmp qword [r12 + PyGenObject.gi_running], 1
    je .agsi_error

    ; Mark as running
    mov qword [r12 + PyGenObject.gi_running], 1
    mov qword [r12 + PyGenObject.gi_started], 1

    ; Push the sent value onto the generator's frame stack.  None unless
    ; asend.send(v) put one there, in which case the reference it took moves
    ; onto the frame with it.
    mov rdi, [r12 + PyGenObject.gi_frame]
    mov rax, [rbx + AsyncGenASend.ags_sendval]
    test rax, rax
    jz .agsi_send_none
    mov qword [rbx + AsyncGenASend.ags_sendval], 0
    FRAME_PUSH_VALUE rdi, rax, rcx
    jmp .agsi_sent
.agsi_send_none:
    FRAME_PUSH_NONE rdi, rax
.agsi_sent:

    ; Resume execution of the async generator
    mov rdi, [r12 + PyGenObject.gi_frame]
    ; A generator is its own execution context, and two globals say so in
    ; different ways.  handled_exception -- what an except block installed --
    ; is swapped between the global and PyFrame.exc_state by eval_frame and
    ; eval_return, so a generator suspended inside a handler carries that
    ; state across the suspension and the caller gets its own back.  Nothing
    ; here has to do anything about it.
    ;
    ; current_exception is the other one: an exception in FLIGHT.  It is
    ; cleared for the duration of the resume so that a NULL result means the
    ; body raised and nothing else, and put back if it did not.
    push rax
    mov rax, [rel current_exception]
    push rax
    mov qword [rel current_exception], 0
    call eval_frame
    pop rcx
    ; An exception the async generator body raised is the result, and
    ; restoring over it ended the iteration silently.
    test rax, rax
    jz .agsend_raised
    mov [rel current_exception], rcx
    jmp .agsend_settled
.agsend_raised:
    test rcx, rcx
    jz .agsi_body_raised
    push rax
    push rdx
    mov rdi, rcx
    call obj_decref
    pop rdx
    pop rax
    jmp .agsi_body_raised
.agsend_settled:
    add rsp, 8
    V_UNPACK rax, rdx           ; eval_frame returns a Value
    ; rax = result payload, rdx = result tag
    push rax
    push rdx

    ; Mark as not running
    mov qword [r12 + PyGenObject.gi_running], 0

    ; Check if exhausted (instr_ptr == 0)
    mov rdi, [r12 + PyGenObject.gi_frame]
    cmp qword [rdi + PyFrame.instr_ptr], 0
    jne .agsi_yielded

    ; Async gen returned (exhausted).  Clear before freeing, as gen_iternext
    ; does and for the same reason.
    mov qword [r12 + PyGenObject.gi_frame], 0
    call frame_free
    pop rdx                    ; result tag
    pop rax                    ; result payload
    V_PACK rax, rdx
    mov [r12 + PyGenObject.gi_return_value], rax

    ; Mark wrapper as closed
    mov dword [rbx + AsyncGenASend.ags_state], 2

    ; Raise StopAsyncIteration
    lea rdi, [rel exc_StopAsyncIteration_type]
    xor esi, esi
    xor edx, edx
    call exc_new
    mov rdi, rax
    call raise_exception_obj
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

;; --- the body raised ---------------------------------------------------
;; Not a result, and above all not the end of the iteration.  The arm below
;; decides "exhausted or yielded" from instr_ptr, and a body that raised
;; leaves the frame finished -- so it read as exhausted and manufactured a
;; StopAsyncIteration, whose raise_exception_obj then DECREF'd the real
;; exception away.  `async for x in ag()` over a generator that raises ended
;; the loop cleanly and lost the exception outright: not caught by an
;; enclosing except, not reported at exit, the program simply carried on past
;; a `raise`.
;;
;; The exception is pending and already owns its reference.  Do the same
;; bookkeeping the exhausted arm does -- the generator is finished either way
;; -- and unwind with it, which is how that arm reaches END_ASYNC_FOR too.
.agsi_body_raised:
    extern eval_exception_unwind
    extern eval_saved_r13
    add rsp, 8                  ; the scratch pushed before eval_frame
    mov qword [r12 + PyGenObject.gi_running], 0
    mov rdi, [r12 + PyGenObject.gi_frame]
    test rdi, rdi
    jz .agsi_body_raised_closed
    mov qword [r12 + PyGenObject.gi_frame], 0
    call frame_free
.agsi_body_raised_closed:
    mov dword [rbx + AsyncGenASend.ags_state], 2
    pop r12
    pop rbx
    leave
    mov [rel eval_saved_r13], r13
    jmp eval_exception_unwind

.agsi_yielded:
    pop rdx                    ; result tag
    pop rax                    ; result payload
    V_PACK rax, rdx

    ; Only a boxed value is this generator's own item.  Anything else is an
    ; `await` inside the body yielding outward, and has to reach the event loop
    ; unchanged -- with the state left at 0, so the next SEND resumes the
    ; generator rather than reporting it exhausted.
    V_TEST_PTR rax, rcx
    ja .agsi_passthrough
    test rax, rax
    jz .agsi_passthrough
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel async_gen_wrapped_type]
    cmp rcx, rdx
    jne .agsi_passthrough

    ; The item: unwrap it, hand it to SEND through the exhaustion path, and
    ; drop the box.  gi_return_value owns its reference (ags_dealloc frees it),
    ; so the value is INCREF'd before the box that held it goes away.
    mov rcx, [rax + AsyncGenWrapped.agw_value]
    INCREF_V rcx, rdx
    mov [rbx + AsyncGenASend.gi_return_value], rcx
    mov rdi, rax
    DECREF_REG rdi
    mov dword [rbx + AsyncGenASend.ags_state], 1
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.agsi_passthrough:
    ; .agsi_yielded already packed this, and tp_iternext's contract is one
    ; Value -- op_send unpacks what it gets back.  Decoding here as well left a
    ; pointer intact but stripped the tag off the SLEEP and IO_WAIT sentinels,
    ; so the event loop read a nanosecond count as an object pointer.
    pop r12
    pop rbx
    leave
    ret

.agsi_second_call:
    ; State 1: already yielded — return NULL to signal SEND exhaustion
    ; SEND will read gi_return_value from the wrapper (at offset +48)
    ; which holds the yielded value stored during state 0.
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.agsi_gen_exhausted:
    ; Generator already exhausted
    mov dword [rbx + AsyncGenASend.ags_state], 2
    lea rdi, [rel exc_StopAsyncIteration_type]
    xor esi, esi
    xor edx, edx
    call exc_new
    mov rdi, rax
    call raise_exception_obj
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.agsi_closed:
    ; State 2: closed.  CPython refuses a REUSE rather than reporting
    ; exhaustion -- an asend is one step of one iteration, and driving the
    ; same one twice is a bug in the caller, not the end of the generator.
    ; `async for` never reuses one: GET_ANEXT builds a fresh wrapper per turn.
    RAISE exc_RuntimeError_type, "cannot reuse already awaited __anext__()/asend()"

.agsi_closed_unused:
    lea rdi, [rel exc_StopAsyncIteration_type]
    xor esi, esi
    xor edx, edx
    call exc_new
    mov rdi, rax
    call raise_exception_obj
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.agsi_error:
    RET_NULL
    pop r12
    pop rbx
    leave
    ret
END_FUNC ags_iternext

;; ============================================================================
;; ags_iter_self(AsyncGenASend *self) -> self with INCREF
;; tp_iter for AsyncGenASend: return self (it IS the iterator)
;; ============================================================================
DEF_FUNC_BARE ags_iter_self
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    mov edx, TAG_PTR
    ret
END_FUNC ags_iter_self

;; ============================================================================
;; async_gen_wrap_value(Value v) -> PyObject*, stealing v
;; INTRINSIC_ASYNC_GEN_WRAP.  See AsyncGenWrapped in object.inc for why the box
;; exists at all.
;; ============================================================================
DEF_FUNC async_gen_wrap_value, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov edi, AsyncGenWrapped_size
    call ap_malloc
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel async_gen_wrapped_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + AsyncGenWrapped.agw_value], rbx
    pop rbx
    leave
    ret
END_FUNC async_gen_wrap_value

;; ============================================================================
;; agw_dealloc(rdi = an AsyncGenWrappedValue) -> nothing
;;
;; The box holds one Value, which is a reference, and nothing else: no GC head,
;; because a box lives only between the `yield` that made it and the drive that
;; unwraps it, and never long enough to be in a cycle.
;; ============================================================================
DEF_FUNC agw_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + AsyncGenWrapped.agw_value]
    DECREF_V rdi, rsi
    mov rdi, rbx
    call ap_free
    pop rbx
    leave
    ret
END_FUNC agw_dealloc

;; ============================================================================
;; ags_dealloc(rdi = an AsyncGenASend or AsyncGenAThrow) -> nothing
;;
;; Both awaitables share the layout and so share this: the generator, the value
;; or exception it was going to deliver, and whatever the last drive parked in
;; gi_return_value.  An athrow whose exception was never delivered -- one that
;; was thrown into instead of awaited -- still owns it here, which is why the
;; field is released rather than assumed consumed.
;; ============================================================================
DEF_FUNC ags_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; DECREF stored return value if present
    mov rdi, [rbx + AsyncGenASend.gi_return_value]
    V_UNPACK rdi, rsi
    DECREF_VAL rdi, rsi

    ; ...and the value the awaitable was going to resume with, which is
    ; asend's argument or athrow's exception.  Both are owned, and neither
    ; was released when the awaitable was dropped unawaited.
    mov rdi, [rbx + AsyncGenASend.ags_sendval]
    mov qword [rbx + AsyncGenASend.ags_sendval], 0
    DECREF_V rdi, rsi

    ; DECREF the async generator
    mov rdi, [rbx + AsyncGenASend.ags_gen]
    call obj_decref

    ; Free the wrapper itself
    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC ags_dealloc

;; ============================================================================
;; agt_iternext(AsyncGenASend *self) -> one Value, or 0
;;
;; What `await agen.aclose()` and `await agen.athrow(exc)` drive.  Both used
;; to be aliases for the SYNCHRONOUS gen_close/gen_throw, which answered None
;; and the raw yielded box respectively -- so `await agen.aclose()` awaited
;; None and raised TypeError, and every `async with` over an
;; @asynccontextmanager generator failed there.  CPython answers an awaitable
;; from both, and this is it: one object, told apart by whether ags_sendval
;; carries an exception.
;;
;; The operation happens on the FIRST drive and its result reaches `await`
;; through the exhaustion path -- tp_iternext answers 0 with gi_return_value
;; set, which is what SEND reads.  A generator that awaits inside its own
;; except or finally passes that outward instead, and ags_started is what
;; makes the next drive resume it rather than throw again.
;; ============================================================================
AGT_EXC   equ 8             ; the exception, across gen_throw
AGT_FRAME equ 16            ; + 2 pushes = 32, 16-aligned
DEF_FUNC agt_iternext, AGT_FRAME
    push rbx
    push r12
    mov rbx, rdi

    ; An aclose or an athrow is ONE awaitable: it completes on the drive that
    ; delivers its result, and driving it again is the caller's bug.  asend
    ; parks at state 1 instead because SEND reads gi_return_value on the same
    ; call and its own by-name path is what marks it used.
    mov eax, [rbx + AsyncGenASend.ags_state]
    cmp eax, 1
    jae .agt_reuse

    cmp dword [rbx + AsyncGenASend.ags_started], 0
    jne .agt_resume

    mov dword [rbx + AsyncGenASend.ags_started], 1
    mov r12, [rbx + AsyncGenASend.ags_gen]

    ; The exception is consumed here: gen_throw takes its own reference, and
    ; leaving it in place would make .agt_resume push it as a SENT value.
    mov rsi, [rbx + AsyncGenASend.ags_sendval]
    mov qword [rbx + AsyncGenASend.ags_sendval], 0
    test rsi, rsi
    jz .agt_close

    mov [rbp - AGT_EXC], rsi    ; a frame slot, not a push: a lone push would
                                ; leave gen_throw -- and every finally body it
                                ; runs -- called eight bytes out
    mov rdi, r12
    call gen_throw
    push rax
    push rdx
    mov rdi, [rbp - AGT_EXC]
    DECREF_V rdi, rsi
    pop rdx
    pop rax

    test edx, edx
    jz .agt_throw_done

    ; A value came out.  The generator's own yield is a wrapped box; anything
    ; else is an `await` inside the handler passing outward, and reaches the
    ; loop unchanged with ags_state left at 0 so the next drive resumes.
    V_PACK rax, rdx
    V_TEST_PTR rax, rcx
    ja .agt_out
    test rax, rax
    jz .agt_out
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel async_gen_wrapped_type]
    cmp rcx, rdx
    jne .agt_out

    mov rcx, [rax + AsyncGenWrapped.agw_value]
    INCREF_V rcx, rdx
    mov [rbx + AsyncGenASend.gi_return_value], rcx
    mov rdi, rax
    DECREF_REG rdi
    mov dword [rbx + AsyncGenASend.ags_state], 2
    jmp .agt_null

.agt_throw_done:
    ; The generator finished.  If it did not handle the throw its exception
    ; is pending and belongs to the awaiting frame; if it swallowed it and
    ; returned, the athrow ends the way an exhausted iteration does.
    mov dword [rbx + AsyncGenASend.ags_state], 2
    cmp qword [rel current_exception], 0
    jne .agt_null
    lea rdi, [rel exc_StopAsyncIteration_type]
    xor esi, esi
    xor edx, edx
    call exc_new
    mov rdi, rax
    call raise_exception_obj
    jmp .agt_null

.agt_close:
    ; aclose().  gen_close runs the finally blocks and answers None; it
    ; leaves through the unwinder itself if one of them raises.
    mov rdi, r12
    call gen_close
    V_PACK rax, rdx
    mov [rbx + AsyncGenASend.gi_return_value], rax
    mov dword [rbx + AsyncGenASend.ags_state], 2
    jmp .agt_null

.agt_out:
    pop r12
    pop rbx
    leave
    ret

.agt_null:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.agt_resume:
    ; The throw has been delivered and the generator suspended on an await of
    ; its own; from here it is an ordinary resume, which is asend's job.
    pop r12
    pop rbx
    leave
    jmp ags_iternext

.agt_reuse:
    RAISE exc_RuntimeError_type, "cannot reuse already awaited aclose()/athrow()"
END_FUNC agt_iternext

;; ============================================================================
;; async_gen_athrow_new(rdi = the async generator, rsi = the exception Value
;;                      or 0 for aclose) -> rax = the awaitable, owned
;; ============================================================================
DEF_FUNC async_gen_athrow_new               ; 2 pushes, so rsp is 16-aligned
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi

    mov edi, AsyncGenASend_size
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel async_gen_athrow_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + AsyncGenASend.ags_gen], rbx
    mov dword [rax + AsyncGenASend.ags_state], 0
    mov [rax + AsyncGenASend.ags_sendval], r12
    mov dword [rax + AsyncGenASend.ags_started], 0
    ; No exception to deliver is what aclose() asks for, and the mode outlives
    ; ags_sendval: a yielded value means something different in each.
    mov ecx, 1
    test r12, r12
    jnz .agan_have_exc
    mov dword [rax + AsyncGenASend.ags_aclose], ecx
    jmp .agan_mode_set
.agan_have_exc:
    mov dword [rax + AsyncGenASend.ags_aclose], 0
.agan_mode_set:
    mov qword [rax + AsyncGenASend.gi_return_value], 0

    inc qword [rbx + PyObject.ob_refcnt]
    INCREF_V r12, rcx

    pop r12
    pop rbx
    leave
    ret
END_FUNC async_gen_athrow_new

;; ============================================================================
;; _agen_aclose_impl(rdi = args, rsi = nargs) -> rax = Value
;;
;; agen.aclose().  Answers the awaitable above rather than doing the work,
;; which is what makes `await` on it legal.
;; ============================================================================
DEF_FUNC_LOCAL _agen_aclose_impl
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    call _agen_check_receiver
    xor esi, esi                ; no exception: this is a close
    call async_gen_athrow_new
    leave
    ret
.arity:
    RAISE exc_TypeError_type, "aclose() takes no arguments"
END_FUNC _agen_aclose_impl

;; ============================================================================
;; _agen_athrow_impl(rdi = args, rsi = nargs) -> rax = Value
;;
;; agen.athrow(exc), the other half of aclose above: the same awaitable,
;; carrying the exception rather than the GeneratorExit aclose implies.
;; ============================================================================
AAT_EXC   equ 8             ; the exception throw_args_exc settled on
AAT_OWNED equ 16            ; non-zero when AAT_EXC is a reference of ours
AAT_RECV  equ 24            ; the async generator
AAT_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL _agen_athrow_impl, AAT_FRAME
    ; The receiver first, as a method descriptor checks it: nothing below
    ; should be built for an object that cannot take it.
    mov [rbp - AAT_RECV], rsi           ; nargs, across the check
    mov [rbp - AAT_EXC], rdi            ; args, likewise
    mov rdi, [rdi]
    call _agen_check_receiver
    mov rdi, [rbp - AAT_EXC]
    mov rsi, [rbp - AAT_RECV]
    mov [rbp - AAT_RECV], rax
    add rdi, 8                          ; self is not one of them
    dec rsi
    lea rdx, [rel aat_name]
    lea rcx, [rel aat_deprecated]
    call throw_args_exc
    mov [rbp - AAT_EXC], rax
    mov [rbp - AAT_OWNED], rdx
    mov rdi, [rbp - AAT_RECV]
    mov rsi, rax
    call async_gen_athrow_new
    cmp qword [rbp - AAT_OWNED], 0
    je .out
    push rax
    sub rsp, 8
    mov rdi, [rbp - AAT_EXC]
    call obj_decref
    add rsp, 8
    pop rax
.out:
    leave
    ret
END_FUNC _agen_athrow_impl

;; ============================================================================
;; throw_args_exc(rdi = the arguments after self, rsi = how many,
;;                rdx = the method's name, a C string,
;;                rcx = the deprecation message, a C string)
;;   -> rax = the exception, a class or an instance; edx = 1 when rax is a
;;      new reference the caller must drop, 0 when it is borrowed from args
;;
;; The argument handling generator.throw(), coroutine.throw() and
;; agen.athrow() share -- CPython's _gen_throw: typ[, val[, tb]], the two
;; longer spellings deprecated, the traceback accepted (None or a traceback)
;; and otherwise ignored as it is everywhere else in this tree, and the pair
;; normalized the way PyErr_NormalizeException does.  A class with no value
;; is answered as the class; the thrower instantiates it.
;;
;; Does not return on failure: every refusal raises.
;; ============================================================================
TA_ARGS  equ 8
TA_N     equ 16
TA_NAME  equ 24
TA_EXC   equ 32             ; typ, borrowed until something is built
TA_VAL   equ 40             ; val, or 0 for absent / None
TA_FRAME equ 48             ; + 0 pushes = 48, 16-aligned
global throw_args_exc
DEF_FUNC throw_args_exc, TA_FRAME
    mov [rbp - TA_ARGS], rdi
    mov [rbp - TA_N], rsi
    mov [rbp - TA_NAME], rdx
    mov qword [rbp - TA_VAL], 0
    cmp rsi, 1
    jl .arity
    cmp rsi, 3
    jg .arity
    mov rax, [rdi]
    mov [rbp - TA_EXC], rax
    cmp rsi, 1
    je .classify

    ; CPython warns before it does anything else, and a suite that turns
    ; warnings into errors reads that as the deprecation firing.  The warning
    ; runs Python code: nothing may be live in a register across it.
    mov rdi, rcx
    call deprecation_warn
    test eax, eax
    jz .raised                  ; a filter made it an error
    mov rdi, [rbp - TA_ARGS]
    mov rax, [rdi + 8]
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .no_value                ; None is no value at all
    mov [rbp - TA_VAL], rax
.no_value:
    cmp qword [rbp - TA_N], 3
    jl .classify
    mov rax, [rdi + 16]         ; the traceback: None, or one
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .classify
    V_TEST_PTR rax, rcx
    ja .bad_tb
    test rax, rax
    jz .bad_tb
    mov rcx, [rax + PyObject.ob_type]
    extern traceback_type
    lea rdx, [rel traceback_type]
    cmp rcx, rdx
    jne .bad_tb

.classify:
    ; It has to BE an exception class or instance.  The thrower is going to
    ; raise it, and a type_call would otherwise jump through whatever sits at
    ; tp_call in an object of another shape -- `athrow(5, 6)` was a segfault
    ; from ordinary Python.  A class is anything whose type is a metatype,
    ; not one of the three metatypes we ship by pointer.
    mov rax, [rbp - TA_EXC]
    V_TEST_PTR rax, rcx
    ja .not_an_exception
    test rax, rax
    jz .not_an_exception
    mov rcx, [rax + PyObject.ob_type]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jnz .a_class

    ; An INSTANCE: its type must derive from BaseException, and a separate
    ; value is refused rather than used.
    mov rdi, rcx
    call type_is_exc_subclass
    test eax, eax
    jz .not_an_exception
    cmp qword [rbp - TA_VAL], 0
    jne .separate_value
    jmp .borrowed

.a_class:
    mov rdi, rax
    call type_is_exc_subclass
    test eax, eax
    jz .not_an_exception
    mov rdx, [rbp - TA_VAL]
    test rdx, rdx
    jz .borrowed

    ; A value that is ALREADY an instance of the class is the exception, not
    ; an argument to build one from -- _PyErr_SetObject's rule, and without it
    ; `athrow(ValueError, ValueError('z'))` raised ValueError(ValueError('z')).
    V_TEST_PTR rdx, rcx
    ja .build_one
    mov rdi, [rdx + PyObject.ob_type]
    mov rsi, [rbp - TA_EXC]
    call type_is_subtype
    test eax, eax
    jz .not_instance
    mov rax, [rbp - TA_VAL]
    mov [rbp - TA_EXC], rax
    jmp .borrowed

.not_instance:
    ; A tuple is the argument list, anything else the one argument.
    mov rdx, [rbp - TA_VAL]
    mov rdi, [rdx + PyObject.ob_type]
    extern tuple_type
    lea rsi, [rel tuple_type]
    call type_is_subtype
    test eax, eax
    jz .build_one
    mov rdx, [rbp - TA_VAL]
    mov rdi, [rbp - TA_EXC]
    mov rsi, [rdx + PyTupleObject.ob_item]
    mov rdx, [rdx + PyTupleObject.ob_size]
    jmp .build
.build_one:
    mov rdi, [rbp - TA_EXC]
    lea rsi, [rbp - TA_VAL]     ; a one-Value array
    mov edx, 1
.build:
    call type_call
    test rax, rax
    jz .raised
    mov edx, 1                  ; ours: the caller drops it
    leave
    ret

.borrowed:
    mov rax, [rbp - TA_EXC]
    xor edx, edx
    leave
    ret

.raised:
    ; The warning filter or the type refused; its exception is the caller's.
    leave
    jmp eval_exception_unwind

.separate_value:
    RAISE exc_TypeError_type, "instance exception may not have a separate value"

.bad_tb:
    RAISE exc_TypeError_type, "throw() third argument must be a traceback object"

.not_an_exception:
    mov rsi, [rbp - TA_EXC]
    CSTRING rdi, `exceptions must be classes or instances deriving from BaseException, not \x01`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name      ; does not return

.arity:
    ; _PyArg_CheckPositional's wording, which names the count it got.
    lea rdi, [rel aat_buf]
    mov rsi, [rbp - TA_NAME]
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    cmp qword [rbp - TA_N], 1
    jl .too_few
    CSTRING rsi, " expected at most 3 arguments, got "
    jmp .say
.too_few:
    CSTRING rsi, " expected at least 1 argument, got "
.say:
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - TA_N]
    extern msg_append_i64
    call msg_append_i64
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel aat_buf]
    call raise_exception        ; does not return
END_FUNC throw_args_exc

section .rodata
aat_name: db "athrow", 0
aat_deprecated: db "the (type, exc, tb) signature of athrow() is deprecated, use the single-arg signature instead.", 0
section .bss
aat_buf: resb 96
section .text

;; ============================================================================
;; _agen_check_receiver(rdi = the candidate) -> rax = it, unchanged
;;
;; Raises rather than returning when it is not an async generator, so every
;; caller can ignore the failing case.
;; ============================================================================
DEF_FUNC_LOCAL _agen_check_receiver
    V_TEST_PTR rdi, rcx
    ja .bad
    test rdi, rdi
    jz .bad
    mov rcx, [rdi + PyObject.ob_type]
    lea rdx, [rel async_gen_type]
    cmp rcx, rdx
    jne .bad
    mov rax, rdi
    leave
    ret
.bad:
    RAISE exc_TypeError_type, "descriptor requires an async_generator object"
END_FUNC _agen_check_receiver

;; ============================================================================
;; _get_agen_aclose_builtin() -> rax = the `aclose` builtin, borrowed
;; ============================================================================
DEF_FUNC _get_agen_aclose_builtin
    mov rax, [rel _agen_aclose_cache]
    test rax, rax
    jnz .ret
    lea rdi, [rel _agen_aclose_impl]
    CSTRING rsi, "aclose"
    call builtin_func_new
    mov [rel _agen_aclose_cache], rax
.ret:
    leave
    ret
END_FUNC _get_agen_aclose_builtin

;; ============================================================================
;; _get_agen_athrow_builtin() -> rax = the `athrow` builtin, borrowed
;; ============================================================================
DEF_FUNC _get_agen_athrow_builtin
    mov rax, [rel _agen_athrow_cache]
    test rax, rax
    jnz .ret
    lea rdi, [rel _agen_athrow_impl]
    CSTRING rsi, "athrow"
    call builtin_func_new
    mov [rel _agen_athrow_cache], rax
.ret:
    leave
    ret
END_FUNC _get_agen_athrow_builtin

;; ============================================================================
;; _ags_send_impl(rdi = args, rsi = nargs) -> rax = Value
;;
;; asend.send(value) and asend.__next__(), which are one function in CPython
;; too.  The asend object had a live tp_iternext and no tp_dict at all, so
;; `agen.__anext__().send(None)` -- the only way to drive an async generator
;; without an event loop, and exactly what CPython's own test_asyncgen does
;; -- raised AttributeError, and the whole "compare a sync generator with an
;; async one" half of that file with it.
;;
;; ags_iternext answers NULL for the generator's own item and leaves it in
;; gi_return_value, because that is the shape op_send's exhaustion path
;; reads.  By NAME the protocol is the other one: StopIteration carrying the
;; value, the same as a generator's own send().
;;
;; send() wants its argument and __next__() refuses one, so the arity check
;; cannot be shared even though everything after it is.
;; ============================================================================
AGSS_SELF  equ 8
AGSS_VAL   equ 16           ; the item, held across exc_new so it can be freed
AGSS_FRAME equ 32           ; + 0 pushes = 32, 16-aligned

global _ags_send_impl
DEF_FUNC_BARE _ags_send_impl
    cmp rsi, 2
    jne .send_arity
    jmp ags_send_core
.send_arity:
    RAISE exc_TypeError_type, "send() takes exactly one argument"
END_FUNC _ags_send_impl

;; ============================================================================
;; _ags_next_impl(rdi = args, rsi = nargs) -> rax = Value
;;
;; asend.__next__(), which is send(None) under the name a for-loop uses.
;; ============================================================================
global _ags_next_impl
DEF_FUNC_BARE _ags_next_impl
    cmp rsi, 1
    jne .next_arity
    jmp ags_send_core
.next_arity:
    RAISE exc_TypeError_type, "__next__() takes no arguments"
END_FUNC _ags_next_impl

;; ============================================================================
;; ags_send_core(rdi = args, rsi = nargs) -> rax = Value
;;
;; Everything send() and __next__() share, past the arity check that is all
;; that separates them.  Drives the awaitable through its own tp_iternext:
;; the aclose/athrow object shares this method and has a different one.
;; ============================================================================
DEF_FUNC_LOCAL ags_send_core, AGSS_FRAME
    mov rax, [rdi]              ; self
    V_TEST_PTR rax, rcx
    ja .agss_receiver
    test rax, rax
    jz .agss_receiver
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel async_gen_asend_type]
    cmp rcx, rdx
    je .agss_asend
    lea rdx, [rel async_gen_athrow_type]
    cmp rcx, rdx
    jne .agss_receiver

    ; --- the aclose/athrow awaitable ---
    ; ags_sendval is NOT a resume value here: it is the exception agt_iternext
    ; is going to throw.  Storing the sent value over it handed gen_throw a
    ; plain int to raise -- a segfault from ordinary Python -- and dropped the
    ; exception's reference on the way.  CPython refuses the send instead.
    mov [rbp - AGSS_SELF], rax
    cmp rsi, 2
    jne .agss_go
    mov rdx, [rdi + 8]
    lea rcx, [rel none_singleton]
    cmp rdx, rcx
    je .agss_go
    cmp dword [rax + AsyncGenASend.ags_started], 0
    jne .agss_store             ; already thrown: this is an ordinary resume
    RAISE exc_RuntimeError_type, "can't send non-None value to a just-started coroutine"

.agss_asend:
    ; The sent value.  ags_iternext resumes with None; anything else is
    ; stashed for it to push instead, and the reference goes with it.
    mov [rbp - AGSS_SELF], rax
    cmp rsi, 2
    jne .agss_go
    mov rdx, [rdi + 8]
    lea rcx, [rel none_singleton]
    cmp rdx, rcx
    je .agss_go

.agss_store:
    ; asend(v).send(w) is CPython's "w wins", so what asend() left here is
    ; released rather than leaked.
    push rdx
    sub rsp, 8                  ; a pad: XDECREF_V expands to a call, and a
                                ; lone push leaves it eight out
    mov rdi, [rax + AsyncGenASend.ags_sendval]
    mov qword [rax + AsyncGenASend.ags_sendval], 0
    XDECREF_V rdi, rcx
    add rsp, 8
    pop rdx
    mov rax, [rbp - AGSS_SELF]
    INCREF_V rdx, rcx
    mov [rax + AsyncGenASend.ags_sendval], rdx

.agss_go:
    ; Through the slot, not through ags_iternext: the athrow awaitable shares
    ; this method and has a tp_iternext of its own.
    mov rdi, [rbp - AGSS_SELF]
    mov rax, [rdi + PyObject.ob_type]
    call [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jnz .agss_out               ; an `await` passing outward: hand it back

    ; NULL means the item is ready, unless the body raised or the generator
    ; is finished -- ags_iternext raises StopAsyncIteration for the second,
    ; and a pending exception is the caller's either way.
    cmp qword [rel current_exception], 0
    jne .agss_propagate

    ; The item, and with it the end of this awaitable: a second send() on the
    ; same asend is the reuse CPython refuses.  Only the name path marks it,
    ; because op_send reads state 1 and gi_return_value for its own
    ; exhaustion arm and must keep finding them.
    mov rcx, [rbp - AGSS_SELF]
    mov rsi, [rcx + AsyncGenASend.gi_return_value]
    mov qword [rcx + AsyncGenASend.gi_return_value], 0   ; the reference moves
    mov [rbp - AGSS_VAL], rsi   ; ...to here, and is released below
    mov dword [rcx + AsyncGenASend.ags_state], 2
    lea rdi, [rel exc_StopIteration_type]
    test rsi, rsi
    jz .agss_no_val
    ; A bare StopIteration for None, as a generator returning None raises,
    ; so str(e) is "" rather than "None".
    lea rax, [rel none_singleton]
    cmp rsi, rax
    jne .agss_have_val
.agss_no_val:
    xor esi, esi
.agss_have_val:
    call exc_new
    ; exc_new took a reference of its own, so the one moved out of the
    ; wrapper is this function's to drop.  Leaving it held leaked the yielded
    ; item once per drive -- five objects for five turns of a hand-driven
    ; `async for`, invisible to every gate because nothing crashed.
    push rax
    sub rsp, 8                  ; a pad, as above
    mov rdi, [rbp - AGSS_VAL]
    XDECREF_V rdi, rcx
    add rsp, 8
    pop rdi
    call raise_exception_obj

.agss_propagate:
    extern eval_exception_unwind
    leave
    jmp eval_exception_unwind

.agss_out:
    leave
    ret                         ; ags_iternext already answers one Value

.agss_receiver:
    RAISE exc_TypeError_type, "send() requires an async_generator_asend"
END_FUNC ags_send_core

;; ============================================================================
;; _agt_throw_impl(rdi = args, rsi = nargs) -> rax = Value
;;
;; asend.throw(exc) and aclose()/athrow().throw(exc): what CANCELLING a task
;; that awaits one of these does.  Neither awaitable had it, and
;; collections.abc.Coroutine is a STRUCTURAL check -- send, throw, close and
;; __await__ -- so the missing name made `isinstance(agen.aclose(), Coroutine)`
;; False and asyncio's create_task refused the object with "a coroutine was
;; expected".  That is what stopped the finalizer hook's own aclose from
;; running, which is the whole reason the hook exists.
;;
;; The exception goes into the GENERATOR, as CPython's async_gen_asend_throw
;; and async_gen_athrow_throw both do, and what comes back is converted the way
;; send() converts it: the generator's own yield is a wrapped box and is
;; unwrapped, an exhausted generator becomes StopIteration, and anything the
;; generator did not handle propagates.
;; ============================================================================
AGTT_SELF  equ 8
AGTT_GEN   equ 16
AGTT_VAL   equ 24           ; the unwrapped yield, across the box's release
AGTT_FRAME equ 32           ; + 0 pushes = 32, 16-aligned
global _agt_throw_impl
DEF_FUNC _agt_throw_impl, AGTT_FRAME
    cmp rsi, 2
    jne .agtt_arity
    mov rax, [rdi]              ; self
    V_TEST_PTR rax, rcx
    ja .agtt_receiver
    test rax, rax
    jz .agtt_receiver
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel async_gen_asend_type]
    cmp rcx, rdx
    je .agtt_ok
    lea rdx, [rel async_gen_athrow_type]
    cmp rcx, rdx
    jne .agtt_receiver
.agtt_ok:
    cmp dword [rax + AsyncGenASend.ags_state], 1
    jae .agtt_reuse
    mov [rbp - AGTT_SELF], rax
    mov rcx, [rax + AsyncGenASend.ags_gen]
    mov [rbp - AGTT_GEN], rcx
    ; An athrow's own exception will never be delivered now; ags_dealloc still
    ; owns it, and the flag is what keeps a later drive from throwing it.
    mov dword [rax + AsyncGenASend.ags_started], 1

    mov rsi, [rdi + 8]          ; the exception, a class or an instance
    mov rdi, rcx
    call gen_throw
    test edx, edx
    jz .agtt_finished

    ; A value came out.  A wrapped box is the generator's own `yield`, and from
    ; the awaiting side that COMPLETES the await -- so it becomes
    ; StopIteration(value), which is what CPython's async_gen_unwrap_value does
    ; with one.  Anything else is an `await` inside the handler passing outward,
    ; and reaches the caller unchanged.
    V_PACK rax, rdx
    V_TEST_PTR rax, rcx
    ja .agtt_out
    test rax, rax
    jz .agtt_out
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel async_gen_wrapped_type]
    cmp rcx, rdx
    jne .agtt_out
    mov rcx, [rax + AsyncGenWrapped.agw_value]
    INCREF_V rcx, rdx
    ; A frame slot and not a push: DECREF_REG is `call obj_dealloc`, and a
    ; lone push before it made that call at rsp % 16 == 8.  The value has a
    ; name, so it gets a slot -- which is what bugs.md prescribes for this
    ; shape rather than a pad.
    mov [rbp - AGTT_VAL], rcx
    mov rdi, rax
    DECREF_REG rdi
    mov rsi, [rbp - AGTT_VAL]
    mov rcx, [rbp - AGTT_SELF]
    mov dword [rcx + AsyncGenASend.ags_state], 2
    ; In ACLOSE mode a yield is not an answer: the generator was told to shut
    ; down and kept going.  CPython says so in as many words, and the value is
    ; dropped rather than handed back.
    cmp dword [rcx + AsyncGenASend.ags_aclose], 0
    jne .agtt_ignored_exit
    jmp .agtt_stop_with

.agtt_ignored_exit:
    mov rdi, rsi
    DECREF_V rdi, rcx
    RAISE exc_RuntimeError_type, "async generator ignored GeneratorExit"

.agtt_finished:
    mov rcx, [rbp - AGTT_SELF]
    mov dword [rcx + AsyncGenASend.ags_state], 2
    cmp qword [rel current_exception], 0
    je .agtt_stop_iteration

    ; aclose() swallows the two exits that mean "it is closed now" and reports
    ; the await as finished instead, which is CPython's rule for that mode; an
    ; athrow, and anything else, propagates.
    mov rcx, [rbp - AGTT_SELF]
    mov rdx, [rcx + PyObject.ob_type]
    lea rcx, [rel async_gen_athrow_type]
    cmp rdx, rcx
    jne .agtt_propagate
    mov rdi, [rel current_exception]
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel exc_GeneratorExit_type]
    call type_is_subtype
    test eax, eax
    jnz .agtt_swallow
    mov rdi, [rel current_exception]
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel exc_StopAsyncIteration_type]
    call type_is_subtype
    test eax, eax
    jz .agtt_propagate
.agtt_swallow:
    mov rdi, [rel current_exception]
    mov qword [rel current_exception], 0
    call obj_decref

.agtt_stop_iteration:
    ; Exhausted: StopIteration carrying whatever the generator returned, the
    ; same protocol a generator's own throw() answers by name.
    mov rcx, [rbp - AGTT_GEN]
    mov rsi, [rcx + PyGenObject.gi_return_value]
.agtt_stop_with:
    ; rsi = the value the await completes with, a Value; a reference of ours
    ; where it came from a wrapped box, and borrowed where it came from
    ; gi_return_value -- exc_new takes its own either way.
    lea rdi, [rel exc_StopIteration_type]
    test rsi, rsi
    jz .agtt_bare
    lea rax, [rel none_singleton]
    cmp rsi, rax
    jne .agtt_have_val
.agtt_bare:
    xor esi, esi
.agtt_have_val:
    xor edx, edx
    call exc_new
    mov rdi, rax
    call raise_exception_obj
    ; does not return

.agtt_propagate:
    xor eax, eax
    leave
    jmp eval_exception_unwind

.agtt_out:
    leave
    ret

.agtt_reuse:
    RAISE exc_RuntimeError_type, "cannot reuse already awaited aclose()/athrow()"
.agtt_arity:
    RAISE exc_TypeError_type, "throw() takes exactly one argument"
.agtt_receiver:
    RAISE exc_TypeError_type, "throw() requires an async generator awaitable"
END_FUNC _agt_throw_impl

;; ============================================================================
;; _ags_close_impl(rdi = args, rsi = nargs) -> rax = Value
;;
;; asend.close().  CPython's does nothing but mark the awaitable closed --
;; the generator behind it is not touched, because closing THAT is aclose()'s
;; job and this object is one step of one iteration.
;; ============================================================================
global _ags_close_impl
DEF_FUNC _ags_close_impl
    cmp rsi, 1
    jne .agsc_arity
    mov rax, [rdi]
    V_TEST_PTR rax, rcx
    ja .agsc_receiver
    test rax, rax
    jz .agsc_receiver
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel async_gen_asend_type]
    cmp rcx, rdx
    je .agsc_ok
    lea rdx, [rel async_gen_athrow_type]
    cmp rcx, rdx
    jne .agsc_receiver
.agsc_ok:
    mov dword [rax + AsyncGenASend.ags_state], 2
    RET_NONE
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.agsc_receiver:
    RAISE exc_TypeError_type, "close() requires an async_generator_asend"
.agsc_arity:
    RAISE exc_TypeError_type, "close() takes no arguments"
END_FUNC _ags_close_impl

;; _agen_asend_impl(rdi = args, rsi = nargs) -> rax = Value (AsyncGenASend*)
;;
;; agen.asend(value).  It answers an AWAITABLE, the same object
;; `agen.__anext__()` answers, carrying the value the generator will resume
;; with -- it does not resume anything itself.  It used to be an alias for
;; the sync `send`, which resumed the generator immediately and handed back
;; the wrapped yield, so `await agen.asend(v)` awaited an
;; async_generator_wrapped_value and the value never reached the generator
;; at all.
;; ============================================================================
DEF_FUNC_LOCAL _agen_asend_impl
    cmp rsi, 2
    jne .arity
    mov rax, [rdi]              ; the async generator
    V_TEST_PTR rax, rcx
    ja .receiver
    test rax, rax
    jz .receiver
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel async_gen_type]
    cmp rcx, rdx
    jne .receiver

    push rbx
    push r12
    mov rbx, rax
    mov r12, [rdi + 8]          ; the value to resume with, borrowed

    mov rdi, rbx
    call async_gen_iternext     ; the wrapper, with ags_sendval clear

    lea rcx, [rel none_singleton]
    cmp r12, rcx
    je .done                    ; None is what the wrapper already resumes with
    INCREF_V r12, rcx
    mov [rax + AsyncGenASend.ags_sendval], r12
.done:
    pop r12
    pop rbx
    leave
    ret

.receiver:
    RAISE exc_TypeError_type, "asend() requires an async_generator"
.arity:
    RAISE exc_TypeError_type, "asend() takes exactly one argument"
END_FUNC _agen_asend_impl

;; ============================================================================
;; _get_agen_asend_builtin() -> rax = the `asend` builtin, borrowed
;; Built once and cached, as every other generator method is.
;; ============================================================================
DEF_FUNC _get_agen_asend_builtin
    mov rax, [rel _agen_asend_cache]
    test rax, rax
    jnz .ret
    lea rdi, [rel _agen_asend_impl]
    CSTRING rsi, "asend"
    call builtin_func_new
    mov [rel _agen_asend_cache], rax
.ret:
    leave
    ret
END_FUNC _get_agen_asend_builtin
