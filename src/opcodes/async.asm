; opcodes/async.asm - Async/await opcode handlers
;
; Implements: GET_AWAITABLE (131), GET_AITER (50), GET_ANEXT (51),
;             BEFORE_ASYNC_WITH (52), END_ASYNC_FOR (54), CLEANUP_THROW (55)
;
; Register convention (callee-saved, preserved across handlers):
;   rbx = bytecode instruction pointer (IP into co_code[])
;   r12 = current frame pointer (PyFrame*)
;   r13 = value stack payload top pointer
;
; ecx = opcode argument on handler entry (set by eval_dispatch)
; rbx has already been advanced past the 2-byte instruction word.
;
; CRITICAL: Opcode handlers are jumped to (not called) from eval_dispatch.
; They must end with DISPATCH (never leave/ret) and must preserve
; callee-saved registers rbx, r12-r15.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

section .text

extern eval_dispatch
extern obj_decref
extern gen_type
extern coro_type
extern raise_exception
extern raise_exception_obj
extern exc_TypeError_type
extern exc_StopAsyncIteration_type
extern exc_StopIteration_type
extern exc_isinstance
extern exc_new
extern none_singleton
extern str_from_cstr_heap
extern dict_get
extern method_new
extern async_gen_type
extern dunder_call_1
extern dunder_aiter
extern dunder_anext
extern current_exception
extern eval_exception_unwind
extern eval_saved_r13
extern eval_saved_rbx
extern obj_dealloc
extern opcode_table
extern opcode_dispatch_table

;; ============================================================================
;; async_awaitable_iter(rdi = the object) -> rax = an owned awaitable, or 0
;;   On failure edx says why: 0 = not awaitable at all, 1 = __await__ raised
;;   and the exception is pending, 2 = __await__ answered a non-iterator, and
;;   rcx is what it answered.
;;
;; CPython's _PyCoro_GetAwaitableIter, which GET_AWAITABLE and GET_ANEXT both
;; need.  A coroutine is its own awaitable; a plain generator is one only when
;; it carries CO_ITERABLE_COROUTINE, which is how @types.coroutine and the
;; stdlib's generator-based coroutines survive; anything else has to define
;; __await__ and return an ITERATOR from it, which is how asyncio.Future,
;; every asyncio lock and condition, and essentially every third-party
;; awaitable are written.
;;
;; This used to be inlined in GET_AWAITABLE and GET_ANEXT did not do it at
;; all -- it pushed whatever __anext__ answered, so an __anext__ returning a
;; plain int did not raise: the SEND that follows spun on it for ever, and a
;; hang is the one failure that leaves no diagnostic at all.
;;
;; The message is the CALLER's in every failing case, which is why none is
;; raised here.  There are five -- await, async for, __aenter__, __aexit__,
;; and __await__'s non-iterator -- and GET_ANEXT overrides even the last of
;; them: CPython's _PyErr_FormatFromCause replaces whatever went wrong inside
;; with "'async for' received an invalid object from __anext__" and keeps the
;; original as the cause.
;; ============================================================================
AAI_OBJ   equ 8
AAI_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
extern current_exception
extern dunder_lookup
extern dunder_call_1
extern raise_type_error_with_name

DEF_FUNC_LOCAL async_awaitable_iter, AAI_FRAME
    mov [rbp - AAI_OBJ], rdi
    V_TEST_PTR rdi, rax
    ja .aai_no
    test rdi, rdi
    jz .aai_no

    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel coro_type]
    cmp rax, rcx
    je .aai_self

    lea rcx, [rel gen_type]
    cmp rax, rcx
    jne .aai_await
    mov rcx, [rdi + PyGenObject.gi_frame]
    test rcx, rcx
    jz .aai_no
    mov rcx, [rcx + PyFrame.code]
    test rcx, rcx
    jz .aai_no
    mov ecx, [rcx + PyCodeObject.co_flags]
    test ecx, CO_ITERABLE_COROUTINE
    jz .aai_no

.aai_self:
    ; The caller gets a reference of its own, so every road out of here is
    ; owned and the two call sites need no special case for this one.
    mov rax, [rbp - AAI_OBJ]
    INCREF rax
    xor edx, edx
    leave
    ret

.aai_await:
    ; __await__ if the type defines it; otherwise tp_iter, which is what the
    ; awaitables this interpreter builds for itself use -- an async
    ; generator's asend object is an iterator with no dunder of its own.
    ; CPython's tp_as_async->am_await covers both; there is one slot fewer
    ; here, so the two are asked in turn.
    mov rdi, [rbp - AAI_OBJ]
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel gaw_await_name]
    call dunder_lookup
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    jz .aai_try_iter

    mov rdi, [rbp - AAI_OBJ]
    lea rsi, [rel gaw_await_name]
    call dunder_call_1
    test rax, rax               ; 0 is absent-or-raised
    jz .aai_failed
    jmp .aai_check

.aai_try_iter:
    ; tp_iter stands in for CPython's am_await, which this tree has no slot
    ; for -- but ONLY for the awaitables the interpreter builds for itself,
    ; and TYPE_FLAG_AWAITABLE is what says so.  Without that test every
    ; ordinary iterable passed: `__anext__` returning an empty tuple gave
    ; `async for` a perfectly good tuple iterator to drive, and the loop spun
    ; for ever where CPython raises.
    mov rdi, [rbp - AAI_OBJ]
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_AWAITABLE
    jz .aai_no
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz .aai_no
    call rax                    ; tp_iter(obj) -> the iterator, or NULL
    test rax, rax
    jz .aai_failed

.aai_check:
    ; It has to be an iterator, and not a coroutine: CPython refuses
    ; __await__ returning a coroutine because awaiting it would recurse.
    V_TEST_PTR rax, rcx
    ja .aai_not_iter
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel coro_type]
    cmp rcx, rdx
    je .aai_not_iter
    cmp qword [rcx + PyTypeObject.tp_iternext], 0
    je .aai_not_iter
    xor edx, edx
    leave
    ret

.aai_failed:
    ; __await__ raised, or tp_iter did.  A pending exception is the caller's
    ; to propagate or to chain; say which happened rather than guess for it.
    cmp qword [rel current_exception], 0
    jne .aai_pending
.aai_no:
    xor eax, eax
    xor edx, edx
    leave
    ret
.aai_pending:
    xor eax, eax
    mov edx, 1
    leave
    ret

.aai_not_iter:
    ; rax holds what __await__ answered, owned.  It is handed back in rcx and
    ; not released: every caller's road from here ends in a TypeError that
    ; names its TYPE and does not return, so there is no moment at which a
    ; decref would be safe.  One object on a path that raises.
    mov rcx, rax
    xor eax, eax
    mov edx, 2
    leave
    ret
END_FUNC async_awaitable_iter

;; ============================================================================
;; op_get_awaitable - GET_AWAITABLE (131)
;;
;; TOS = the object to await, replaced by the iterator that awaits it.
;;
;; The oparg says which syntax asked, and CPython words the refusal
;; differently for each: 0 is a bare `await`, 1 is the value `__aenter__`
;; returned and 2 is `__aexit__`'s.  Both `async with` messages read "does not
;; implement __await__", which is the actual advice; the bare one does not,
;; because `await 5` has no dunder to add.
;; ============================================================================
DEF_FUNC_BARE op_get_awaitable
    VPEEK rdi                  ; the object; not popped until it is resolved

    push rcx                   ; the oparg, across the call below
    sub rsp, 8                 ; pad: rsp is 16-aligned on entry to a handler
    call async_awaitable_iter
    add rsp, 8
    mov r8, rcx                ; what __await__ answered, when edx says 2 --
    pop rcx                    ; read before the oparg comes back into rcx
    test rax, rax
    jz .gaw_failed

    ; Replace the original on the value stack with what it awaits.  Its
    ; reference is released exactly once, here: an iterator's own tp_iter
    ; hands back self, so releasing it earlier and then using the result was
    ; a use-after-free that surfaced two opcodes later inside SEND.
    VPOP rdi
    push rax
    sub rsp, 8
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    VPUSH_PTR rax
    DISPATCH

.gaw_failed:
    cmp edx, 1
    je .gaw_propagate
    cmp edx, 2
    je .gaw_not_iter
    VPEEK rsi
    cmp ecx, 1
    je .gaw_aenter
    cmp ecx, 2
    je .gaw_aexit
    CSTRING rdi, `object \x01 can't be used in 'await' expression`
    jmp raise_type_error_with_name
.gaw_aenter:
    CSTRING rdi, `'async with' received an object from __aenter__ that does not implement __await__: \x01`
    jmp raise_type_error_with_name
.gaw_aexit:
    CSTRING rdi, `'async with' received an object from __aexit__ that does not implement __await__: \x01`
    jmp raise_type_error_with_name

.gaw_not_iter:
    mov rsi, r8
    CSTRING rdi, `__await__() returned non-iterator of type '\x01'`
    jmp raise_type_error_with_name

.gaw_propagate:
    extern eval_exception_unwind
    jmp eval_exception_unwind


section .rodata
gaw_await_name: db "__await__", 0
section .text
END_FUNC op_get_awaitable

;; ============================================================================
;; op_get_aiter - GET_AITER (50)
;;
;; Pop TOS, call __aiter__, push the async iterator it returns.
;;
;; __aiter__ is looked up BY NAME first, and only then as tp_iter.  A class
;; that implements the asynchronous iterator protocol itself -- __aiter__
;; returning self, and an `async def __anext__` -- has neither tp_iter nor
;; tp_iternext, because slot_table has no row for either name, so reading the
;; slot alone refused the very objects that define the protocol: every
;; hand-written async iterator, and every asyncio stream.  The slot stays as
;; the fallback because that is what the builtin async generator has, and it
;; keeps no __aiter__ in its tp_dict.
;; ============================================================================
DEF_FUNC_BARE op_get_aiter
    ; Pop TOS = async iterable
    VPOP_VAL rdi, rsi

    ; Must be TAG_PTR to dereference
    cmp esi, TAG_PTR
    jne .gai_error

    ; --- by name ---
    ; r15 is the eval loop's scratch and is callee-saved, so it carries the
    ; snapshot across the call.  A NULL result is "no such dunder" or "it
    ; raised", and those are not the same answer.
    sub rsp, 8                 ; pad: rsp is 16-aligned on entry to a
                               ; handler, so a call needs an even push list
    push rdi
    DUNDER_EXC_SAVE r15
    lea rsi, [rel dunder_aiter]
    call dunder_call_1
    pop rdi
    add rsp, 8
    test rax, rax               ; dunder_call_1 answers with a Value; 0 is the miss
    jnz .gai_by_name
    EXC_RAISED_SINCE r15, rcx, .gai_propagate

    ; --- the slot, for the builtin async generator only ---
    ; Its tp_iter returns self and it keeps no __aiter__ in its tp_dict, so it
    ; needs this road.  Nothing else may take it: tp_iter is the SYNC
    ; protocol, and accepting it here made `async for x in [1, 2]` hand a
    ; list_iterator to the send loop, which then tried to await an int and
    ; span forever.  CPython answers a TypeError, and reads a slot of its own
    ; -- am_aiter -- that a list simply does not have.
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel async_gen_type]
    cmp rax, rcx
    jne .gai_error_noattr
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz .gai_error_noattr

    ; Save original for DECREF after call
    sub rsp, 8                 ; pad: rsp is 16-aligned on entry to a
                               ; handler, so a call needs an even push list
    push rdi
    call rax                   ; tp_iter(obj) -> rax = async iterator (ptr)

    ; DECREF original object.  The result is parked in the original's own slot
    ; rather than pushed, so both calls sit at the same aligned depth.
    mov rdi, [rsp]
    mov [rsp], rax
    call obj_decref

    pop rax                    ; restore result
    add rsp, 8                 ; discard the pad

    ; tp_iter returns a pointer — validate not NULL
    test rax, rax
    jz .gai_iter_error

    VPUSH_PTR rax              ; tp_iter returns pointer, use TAG_PTR

    DISPATCH

.gai_by_name:
    ; __aiter__ answered.  Its result is a new reference; the popped iterable
    ; is still ours to release.
    push rax
    push rdx
    call obj_decref             ; rdi is still the iterable
    pop rdx
    pop rax
    VPUSH_VAL rax, rdx
    DISPATCH

.gai_propagate:
    ; __aiter__ ran and raised.  The iterable is ours and the unwinder will
    ; not release it, so drop it before leaving.
    call obj_decref
    mov [rel eval_saved_r13], r13
    jmp eval_exception_unwind

.gai_error:
    ; Not a pointer at all, so there is no type to read and nothing to
    ; release; V_PACK it back into a Value for the message.
    V_PACK rdi, rsi
    mov rsi, rdi
    jmp .gai_raise

.gai_error_noattr:
    ; The message names this object's type, and raise_type_error_with_name
    ; does not return -- so the reference cannot simply be dropped here first,
    ; which freed the object and left the message reading a dangling type
    ; pointer.  Hand it back to the value stack instead: the unwinder releases
    ; everything above the handler's depth, so it is freed exactly once and
    ; not before the message is composed.
    mov rsi, rdi
    VPUSH_PTR rdi
    mov [rel eval_saved_r13], r13
    jmp .gai_raise

.gai_iter_error:
    ; Only the async generator reaches the slot, and its gen_iter_self cannot
    ; answer NULL -- so this is a guard, not a path.  It says nothing about a
    ; type because the object it would have named is already released.
    RAISE exc_TypeError_type, "'async for' got a NULL async iterator"

.gai_raise:
    CSTRING rdi, `'async for' requires an object with __aiter__ method, got \x01`
    extern raise_type_error_with_name
    call raise_type_error_with_name
END_FUNC op_get_aiter

;; ============================================================================
;; op_get_anext - GET_ANEXT (51)
;;
;; Peek TOS (async iterator), call __anext__ on it, then push the result.
;; The result needs to be awaitable (SEND loop follows in bytecode).
;; ============================================================================
DEF_FUNC_BARE op_get_anext
    ; Peek TOS = async iterator (don't pop — async for loop needs it)
    VPEEK rdi

    ; Must be a real object
    V_TEST_PTR rdi, rax
    ja .gan_error

    ; A NULL from either road below means one of two things, and they are not
    ; the same: the iterator is exhausted, or it RAISED.  Snapshot the pending
    ; exception so the two can be told apart.  r15 is the eval loop's scratch
    ; register and is callee-saved, so it survives both calls.
    DUNDER_EXC_SAVE r15

    ; --- by name ---
    ; __anext__ first, for the same reason GET_AITER looks up __aiter__ that
    ; way: a class implementing the protocol itself has no tp_iternext, so
    ; reading the slot alone refused it.  What comes back is an AWAITABLE --
    ; normally the coroutine an `async def __anext__` returns -- and raising
    ; StopAsyncIteration is that coroutine's business, not this handler's.
    sub rsp, 8                 ; pad: rsp is 16-aligned on entry to a
                               ; handler, so a call needs an even push list
    push rdi
    lea rsi, [rel dunder_anext]
    call dunder_call_1
    pop rdi
    add rsp, 8
    test rax, rax               ; dunder_call_1 answers with a Value; 0 is the miss
    jnz .gan_by_name
    EXC_RAISED_SINCE r15, rcx, .gan_propagate

    ; --- the slot, again for the builtin async generator only ---
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel async_gen_type]
    cmp rax, rcx
    jne .gan_error
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .gan_error

    call rax                   ; tp_iternext(aiter) -> awaitable or NULL
    ; rax = result payload, edx = tag
    V_UNPACK rax, rdx           ; tp_iternext returns a Value
    test edx, edx
    jz .gan_null

    ; Push result (the awaitable from __anext__)
    VPUSH_VAL rax, rdx
    DISPATCH

.gan_by_name:
    ; What __anext__ answered has to be an awaitable ITERATOR before the SEND
    ; that follows can drive it -- CPython's GET_ANEXT runs
    ; _PyCoro_GetAwaitableIter over it here.  Pushing it raw is what made an
    ; __anext__ returning a plain int spin for ever rather than raise.
    ;
    ; The async generator's own slot, below, is exempt for the same reason it
    ; is in CPython: am_anext already hands back an awaitable.
    sub rsp, 8                  ; pad: rsp is 16-aligned on entry to a handler
    push rax                    ; the raw result, owned
    mov rdi, rax
    call async_awaitable_iter
    pop rdi
    add rsp, 8
    test rax, rax
    jz .gan_not_awaitable

    push rax
    sub rsp, 8
    DECREF_V rdi, rcx           ; what __anext__ answered, now converted
    add rsp, 8
    pop rax

    ; The aiter was peeked, not popped, so the stack still owns it; the
    ; awaitable is a new reference and goes on top.
    VPUSH_PTR rax
    DISPATCH

.gan_not_awaitable:
    ; rdi is what __anext__ answered.  CPython replaces whatever __await__
    ; may have left pending with this message and chains the old one as the
    ; cause; raise_exception already sets __context__, which is the half of
    ; that a reader sees.
    mov rsi, rdi
    CSTRING rdi, `'async for' received an invalid object from __anext__: \x01`
    jmp raise_type_error_with_name

.gan_null:
    ; Exhausted, or raised.  Manufacturing a StopAsyncIteration for both is
    ; what made `async for x in ag()` over a generator that raises end the
    ; loop cleanly and DISCARD the exception -- not caught, not reported, the
    ; program simply carried on past a `raise`.  A real exception is already
    ; pending and already owns its reference: leave it alone and unwind.
    EXC_RAISED_SINCE r15, rcx, .gan_propagate
.gan_stop:
    ; Genuinely exhausted.  Raise StopAsyncIteration, which END_ASYNC_FOR
    ; reads as the end of the loop.
    lea rdi, [rel exc_StopAsyncIteration_type]
    xor esi, esi
    xor edx, edx
    call exc_new
    mov rdi, rax
    call raise_exception_obj

.gan_propagate:
    ; The stack is as DISPATCH published it -- nothing was popped -- so
    ; eval_saved_r13 needs no correction here.
    jmp eval_exception_unwind

.gan_error:
    ; The aiter is still on the stack, so it is safe to name.
    mov rsi, rdi
    CSTRING rdi, `'async for' received an object from __aiter__ that does not implement __anext__: \x01`
    call raise_type_error_with_name
END_FUNC op_get_anext

;; ============================================================================
;; op_before_async_with - BEFORE_ASYNC_WITH (52)
;;
;; Clone of BEFORE_WITH but looks up __aexit__/__aenter__ instead.
;; Stack: ... | mgr  ->  ... | bound_aexit | result_of___aenter__()
;;
;; Uses DEF_FUNC with rbp-relative locals (same pattern as op_before_with).
;; ============================================================================
BAW_RETTAG equ 8
BAW_MGR    equ 16
BAW_EXIT   equ 24
BAW_ENTER  equ 32
BAW_FRAME  equ 40           ; + 2 pushes; a handler is entered ALIGNED, so this is 8 mod 16

DEF_FUNC op_before_async_with, BAW_FRAME
    push rbx
    push r12

    ; Pop mgr (must be TAG_PTR to dereference)
    VPOP_VAL rax, rdx
    cmp edx, TAG_PTR
    jne .baw_not_ptr
    mov [rbp - BAW_MGR], rax
    mov rbx, rax               ; rbx = mgr

    ; __aexit__, through the descriptor protocol -- CPython's
    ; _PyObject_LookupSpecial, which is what the synchronous BEFORE_WITH was
    ; converted to and this was left out of.  Reading the type's OWN tp_dict
    ; meant an INHERITED __aexit__ was invisible, so every mixin-based async
    ; context manager -- asyncio.Lock, Condition, Semaphore, all of which get
    ; theirs from _ContextManagerMixin -- was "'async with' requires __aexit__
    ; method".  And calling method_new on whatever came back bound a
    ; DESCRIPTOR as the method rather than asking it for __get__.
    mov rdi, rbx
    lea rsi, [rel baw_str_aexit]
    extern dunder_lookup_special
    call dunder_lookup_special
    test rax, rax
    jz .baw_exit_missing
    mov [rbp - BAW_EXIT], rax

    ; Push bound __aexit__ method
    VPUSH_PTR rax

    ; And __aenter__ the same way.  It is already bound, so there is no
    ; receiver to prepend below.
    mov rdi, rbx
    lea rsi, [rel baw_str_aenter]
    call dunder_lookup_special
    test rax, rax
    jz .baw_enter_missing

    ; Got the bound __aenter__.  It carries its receiver already -- that is
    ; what dunder_lookup_special returns -- so it is called with NO arguments,
    ; where the old open-coded lookup had to prepend mgr by hand.
    mov [rbp - BAW_ENTER], rax
    mov rdi, rax
    xor esi, esi                    ; no args array
    xor edx, edx                    ; nargs = 0
    extern obj_call_n
    call obj_call_n
    V_UNPACK rax, rdx
    push rax
    push rdx
    mov rdi, [rbp - BAW_ENTER]
    call obj_decref                 ; the bound aenter
    pop rdx
    pop rax
    test rax, rax
    jz .baw_enter_raised
    mov [rbp - BAW_ENTER], rax
    mov edx, edx               ; zero-extend 32-bit tag to 64-bit
    mov [rbp - BAW_RETTAG], rdx

    ; DECREF mgr
    mov rdi, [rbp - BAW_MGR]
    call obj_decref

    ; Push __aenter__ result
    mov rax, [rbp - BAW_ENTER]
    mov rdx, [rbp - BAW_RETTAG]
    VPUSH_VAL rax, rdx

    pop r12
    pop rbx
    leave
    DISPATCH

.baw_exit_missing:
    ; dunder_lookup_special answers 0 for "absent" and for "the lookup itself
    ; raised"; only the first is a TypeError of our own.
    cmp qword [rel current_exception], 0
    jne .baw_lookup_raised
.baw_no_exit:
    ; The same two wordings op_before_with uses, and for the same reason:
    ; CPython looks __aenter__ up FIRST, so an object with neither gets the
    ; plain sentence and one with only __aenter__ gets the "(missed __aexit__
    ; method)" suffix.  This looks __aexit__ up first -- it is what goes on
    ; the value stack -- so the cheap question is asked again here, on the one
    ; failing path.
    ;
    ; Nothing is released on the way out and nothing may be: this is reached
    ; BEFORE the push, with mgr still in the value-stack slot VPOP_VAL read it
    ; from, and the unwinder gives that slot back.  A first attempt added a
    ; decref here and segfaulted for exactly that reason.
    mov rdi, [rbx + PyObject.ob_type]
    lea rsi, [rel baw_str_aenter]
    extern dunder_lookup
    call dunder_lookup
    mov rsi, rbx
    V_TEST_PTR rax, rcx
    ja .baw_no_either
    CSTRING rdi, `'\x01' object does not support the asynchronous context manager protocol (missed __aexit__ method)`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
.baw_no_either:
    CSTRING rdi, `'\x01' object does not support the asynchronous context manager protocol`
    jmp raise_type_error_with_name

.baw_lookup_raised:
    ; A __get__ raised.  This is reached only from .baw_exit_missing, which is
    ; BEFORE anything is pushed -- so mgr is still in the value-stack slot
    ; VPOP_VAL read it from, and the unwinder releases that.  Releasing it
    ; here as well took one reference per failure, and the third `async with`
    ; over the same manager segfaulted in gc_list_remove.  The synchronous
    ; twin's .bw_lookup_raised records the same rule.
    leave
    jmp eval_exception_unwind

.baw_not_ptr:
    DECREF_VAL rax, rdx
    RAISE exc_TypeError_type, "'async with' requires a context manager object"
.baw_enter_raised:
    ; __aenter__ itself raised.  The bound __aexit__ pushed above stands where
    ; mgr did, so the unwinder releases that; mgr's own reference is this
    ; handler's to drop.
    mov rdi, [rbp - BAW_MGR]
    call obj_decref
    leave
    jmp eval_exception_unwind

.baw_enter_missing:
    cmp qword [rel current_exception], 0
    jne .baw_enter_raised
.baw_no_enter:
    ; The __aexit__ method pushed above has taken mgr's slot, so the unwinder
    ; releases that and not mgr.  Same shape as op_before_with's .bw_no_enter.
    mov rdi, [rbp - BAW_MGR]
    call obj_decref
    RAISE exc_TypeError_type, "'async with' requires __aenter__ method"
END_FUNC op_before_async_with

;; ============================================================================
;; op_end_async_for - END_ASYNC_FOR (54)
;;
;; Exception handler for async for loops.
;; If the exception is StopAsyncIteration: pop TOS + TOS1, jump forward by arg.
;; Otherwise: re-raise.
;;
;; Stack: ... | aiter | exc_val | (after except push)
;; arg = jump offset
;; ============================================================================
DEF_FUNC_BARE op_end_async_for
    ; ecx = arg (jump offset in instructions)

    ; TOS = exc_val (the exception that was raised)
    VPEEK rdi                  ; peek at the exception Value

    ; Check if it's StopAsyncIteration
    V_TEST_PTR rdi, rsi
    ja .eaf_reraise

    ; Get exception type
    mov rax, [rdi + PyObject.ob_type]
    lea rdx, [rel exc_StopAsyncIteration_type]
    cmp rax, rdx
    je .eaf_stop

    ; Check via isinstance (for subclasses)
    sub rsp, 8                 ; pad: rsp is 16-aligned on entry to a
                               ; handler, so a call needs an even push list
    push rcx                   ; save arg
    mov rsi, rdx
    call exc_isinstance
    pop rcx                    ; restore arg
    add rsp, 8
    test eax, eax
    jnz .eaf_stop

.eaf_reraise:
    ; Not StopAsyncIteration — re-raise the original exception.
    VPOP_VAL rdi, rsi          ; exc payload+tag
    ; DISPATCH published eval_saved_r13 at the depth this handler was ENTERED
    ; with, and eval_exception_unwind restores r13 from it -- so the pop above
    ; has to be published too, or the unwinder brings the exception's slot
    ; back to life while current_exception also points at it.  Its release
    ; loop then drops the only reference and the global is left dangling: an
    ; async for over a generator that raises lost the exception outright,
    ; neither caught nor reported, and the program carried on.
    ;
    ; Every other pop-then-raise handler in the tree already does this --
    ; RAISE_VARARGS, RERAISE, SEND's propagate arm, the two intrinsics.  This
    ; was the one that did not.  (CLEANUP_THROW below reaches the same place
    ; from the other side, by peeking and taking a second reference.)
    mov [rel eval_saved_r13], r13
    ; raise_exception_obj TAKES the reference VPOP_VAL just transferred off
    ; the stack -- it does not add one.  The comment that used to sit here
    ; said the opposite.
    call raise_exception_obj

.eaf_stop:
    ; StopAsyncIteration — pop exc and aiter, jump forward
    ; Pop exc
    VPOP_VAL rdi, rsi
    sub rsp, 8                 ; pad: rsp is 16-aligned on entry to a
                               ; handler, so a call needs an even push list
    push rcx                   ; save arg
    DECREF_VAL rdi, rsi

    ; Pop aiter
    VPOP rdi
    DECREF_V rdi, rsi
    pop rcx                    ; restore arg
    add rsp, 8

    ; Jump forward by arg instructions (each = 2 bytes)
    shl ecx, 1
    add rbx, rcx

    DISPATCH
END_FUNC op_end_async_for

;; ============================================================================
;; op_cleanup_throw - CLEANUP_THROW (55)
;;
;; Called after a throw into a subgenerator/coroutine via eval_exception_unwind.
;; eval_exception_unwind pushes the exception onto TOS and clears current_exception.
;; If the exception is StopIteration: extract .value and replace TOS.
;; Otherwise: re-raise by setting current_exception and re-entering unwind.
;;
;; Stack after eval_exception_unwind: ... | sub_iter(depth-preserved) | exception(TOS)
;; ============================================================================
DEF_FUNC_BARE op_cleanup_throw
    ; TOS = exception (pushed by eval_exception_unwind)
    ; Below TOS: sub-iterator (preserved to handler depth)
    ; current_exception = 0 (cleared by eval_exception_unwind)

    ; Read exception from TOS
    mov rax, [r13 - 8]          ; exception payload
    test rax, rax
    jz .ct_no_exc

    ; Is it StopIteration?
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel exc_StopIteration_type]
    cmp rcx, rdx
    jne .ct_reraise

    ; === StopIteration: sub-iterator returned normally ===
    ; Extract .value (exc_args[0] or None)
    mov rdi, [rax + PyExceptionObject.exc_args]
    test rdi, rdi
    jz .ct_si_none
    cmp qword [rdi + PyTupleObject.ob_size], 0
    je .ct_si_none
    ; value = args[0] (fat value in 16-byte slot)
    mov r8, [rdi + PyTupleObject.ob_item]
    mov r8, [r8]                                ; value Value
    INCREF_V r8, r9
    V_UNPACK r8, r9
    jmp .ct_si_got_val
.ct_si_none:
    lea r8, [rel none_singleton]
    INCREF r8
    mov r9d, TAG_PTR
.ct_si_got_val:
    ; Save extracted value across DECREFs
    push r8
    push r9
    ; Pop and DECREF the StopIteration exception (TOS)
    VPOP rdi
    call obj_decref
    ; Pop and DECREF_VAL the sub-iterator
    VPOP rdi
    DECREF_V rdi, rsi
    ; Restore extracted value and push
    pop r9
    pop r8
    VPUSH_VAL r8, r9
    DISPATCH

.ct_no_exc:
    ; No exception — just dispatch
    DISPATCH

.ct_reraise:
    ; Not StopIteration — re-raise
    ; INCREF for current_exception (stack still owns its ref;
    ; eval_exception_unwind will restore r13 from saved value and
    ; XDECREF_VAL items when adjusting to the next handler's depth)
    INCREF rax
    mov [rel current_exception], rax
    ; No traceback entry: the throw that reached this handler already
    ; recorded this frame, and CPython's CLEANUP_THROW goes straight to
    ; exception_unwind rather than through the label that records one.
    ; Without this every frame delegating a throw appeared twice.
    extern tb_suppress_frame
    mov byte [rel tb_suppress_frame], 1
    jmp eval_exception_unwind
END_FUNC op_cleanup_throw

;; ============================================================================
;; Data section
;; ============================================================================
section .rodata
baw_str_aexit:  db "__aexit__", 0
baw_str_aenter: db "__aenter__", 0
section .text
