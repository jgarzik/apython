; opcodes/exc.asm - The exception opcodes
;
; PUSH_EXC_INFO, POP_EXCEPT, CHECK_EXC_MATCH, CHECK_EG_MATCH, RAISE_VARARGS and
; RERAISE.  They lived in eval.asm, which CLAUDE.md describes as the dispatch
; loop and nothing else; the unwinder they cooperate with -- and which does
; belong there -- is eval_exception_unwind.
;
; Register convention (callee-saved, preserved across handlers):
;   rbx = bytecode instruction pointer (current position in co_code[])
;   r12 = current frame pointer (PyFrame*)
;   r13 = value stack top pointer (Value[], one 64-bit word per slot)
;   r14 = co_consts tuple data pointer (&tuple.ob_item[0])
;   r15 = free
;
; co_names is accessed via the LOAD_CO_NAMES macro (reads a global).
; ecx = opcode argument on entry (set by eval_dispatch)
; rbx has already been advanced past the 2-byte instruction word.

%include "macros.inc"
%include "object.inc"

extern opcode_table
extern opcode_dispatch_table


extern eg_is_base_exception_group

extern eg_new

extern eg_split

extern eval_exception_unwind

extern exc_ExceptionGroup_type

extern exc_isinstance

extern exc_new

extern exc_set_context

extern exc_TypeError_type

extern none_singleton

extern obj_dealloc

extern obj_decref

extern raise_exception


extern tuple_new

section .text

;; ============================================================================
;; Exception-related opcode handlers (inline in eval.asm for access to globals)
;; ============================================================================

;; ============================================================================
;; op_push_exc_info (35) - Push exception info for try/except
;; TOS has the exception. Save the handled-exception state, install the new one.
;; Stack effect: exc -> prev_exc, exc
;;
;; The whole of the saved state is one word on the value stack, with None
;; standing for "nothing was being handled".  The global's reference goes with
;; it, so the stack slot owns it until POP_EXCEPT hands it back -- which is why
;; a generator suspended inside an except block keeps the caller's exception
;; alive on its own stack, and why frame_free releasing that stack is what
;; releases it if the generator never resumes.
;; ============================================================================
DEF_FUNC_BARE op_push_exc_info
    ; TOS = new exception
    VPOP rax                 ; rax = new exception

    ; One more exception this frame is handling and has not put down.  What
    ; eval_return reads to decide whether the frame keeps the global on its
    ; way out, or merely gives back the one it borrowed from its caller.
    inc dword [r12 + PyFrame.exc_depth]

    ; Push the previous handled_exception (or None if NULL)
    mov rdx, [gs:ThreadState.handled_exception]
    test rdx, rdx
    jnz .have_prev
    lea rdx, [rel none_singleton]
    INCREF rdx
.have_prev:
    VPUSH_PTR rdx            ; push prev_exc

    ; Set new exception as handled and push it too
    ; INCREF for the value stack copy
    INCREF rax
    mov [gs:ThreadState.handled_exception], rax
    VPUSH_PTR rax            ; push new exc

    DISPATCH
END_FUNC op_push_exc_info

;; ============================================================================
;; op_pop_except (89) - Restore the previous handled-exception state
;; TOS = the exception to restore
;; ============================================================================
DEF_FUNC_BARE op_pop_except
    VPOP rax                 ; rax = exception to restore
    dec dword [r12 + PyFrame.exc_depth]

    ; Install the restored exception FIRST, and only then release the one it
    ; replaces.  That release runs arbitrary code -- a __del__ on anything the
    ; dying exception still holds -- and entering a Python frame swaps
    ; handled_exception into PyFrame.exc_state and back, counting it both
    ; times.  With the global still pointing at an object at refcount 0, that
    ; took it 0 -> 1 -> 0 and ran obj_dealloc on it a SECOND time; the symptom
    ; was a SIGSEGV in gc_list_remove from the outer dealloc, whose block had
    ; been freed and reused underneath it.  `AttributeError.obj` is what made
    ; it reachable -- it is the first thing to put an arbitrary object, and so
    ; an arbitrary __del__, inside an exception.
    mov rcx, [gs:ThreadState.handled_exception]    ; the one being taken down
    lea rdx, [rel none_singleton]
    cmp rax, rdx
    je .pe_none
    mov [gs:ThreadState.handled_exception], rax    ; the stack's reference moves into it
    xor eax, eax                        ; and nothing is left over to release
    jmp .pe_release
.pe_none:
    ; None on the stack means there was nothing being handled; the None is
    ; still this handler's to release.
    mov qword [gs:ThreadState.handled_exception], 0

.pe_release:
    sub rsp, 8                 ; pad: rsp is 16-aligned on entry to a
                               ; handler, so a call needs an even push list
    push rax
    mov rdi, rcx
    test rdi, rdi
    jz .no_old
    call obj_decref
.no_old:
    pop rdi
    add rsp, 8
    test rdi, rdi
    jz .pe_done
    call obj_decref
.pe_done:
    DISPATCH
END_FUNC op_pop_except

;; ============================================================================
;; op_check_exc_match (36) - Check if exception matches a type
;; TOS = type to match against, TOS1 = exception
;; Push True/False, don't pop the exception
;; ============================================================================
DEF_FUNC_BARE op_check_exc_match
    VPOP rsi                 ; rsi = type to match
    VPEEK rdi                ; rdi = exception (don't pop)

    ; The slot just popped is about to be released, so the unwinder must not
    ; still believe it is live: exc_isinstance raises for `except (1,)`, and
    ; its pop loop would DECREF the same reference a second time.  Every
    ; handler that pops and releases owes this store; this one did not make it.
    PUBLISH_SP

    ; Save type for DECREF
    sub rsp, 8                 ; pad: rsp is 16-aligned on entry to a
                               ; handler, so a call needs an even push list
    push rsi

    ; Call exc_isinstance(exc, type)
    call exc_isinstance
    ; eax = 0 or 1

    ; DECREF the type
    mov rdi, [rsp]             ; the type
    mov [rsp], rax             ; park the answer in its slot
    call obj_decref
    pop rax
    add rsp, 8

    ; Push bool result
    test eax, eax
    jz .no_match
    extern bool_true
    lea rax, [rel bool_true]
    jmp .push_result
.no_match:
    extern bool_false
    lea rax, [rel bool_false]
.push_result:
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
END_FUNC op_check_exc_match

;; op_check_eg_match (37) - Check exception group match for except*
;; Stack in:  [..., exc_value, match_type]
;; On match:  [..., rest_or_None, match_eg]  (pop exc_value, push rest, push match)
;; No match:  [..., exc_value, None]          (keep exc_value, push None)
;;
;; Cases:
;; 1. exc_value isinstance match_type AND is ExceptionGroup → eg_split
;; 2. exc_value isinstance match_type AND is NOT ExceptionGroup → wrap in EG, rest=None
;; 3. exc_value is ExceptionGroup but NOT isinstance → eg_split (may return NULL match)
;; 4. No match at all → push None

CEM_EXC    equ 8
CEM_MTYPE  equ 16
CEM_MATCH  equ 24
CEM_REST   equ 32
CEM_TMP1   equ 40
CEM_TMP2   equ 48
CEM_FRAME  equ 56           ; + 0 pushes = 48
DEF_FUNC op_check_eg_match, CEM_FRAME

    VPOP rsi                 ; rsi = match_type
    VPEEK rdi                ; rdi = exc_value (don't pop yet)
    mov [rbp - CEM_EXC], rdi
    mov [rbp - CEM_MTYPE], rsi

    ; Check if exc_value is None → no match
    lea rax, [rel none_singleton]
    cmp rdi, rax
    je .cem_no_match

    ; Case 1/2: isinstance(exc_value, match_type)?
    ; rdi = exc, rsi = type already set
    call exc_isinstance
    test eax, eax
    jz .cem_check_group_split

    ; Match! Check if exc_value is an ExceptionGroup
    mov rdi, [rbp - CEM_EXC]
    call eg_is_base_exception_group
    test eax, eax
    jnz .cem_full_group_match

    ; Case 2: Naked exception matches — wrap in ExceptionGroup
    ; Create a 1-element tuple containing the exception
    mov edi, 1
    call tuple_new
    mov [rbp - CEM_TMP1], rax ; TMP1 = tuple
    mov rcx, [rbp - CEM_EXC]
    INCREF rcx
    mov rdx, [rax + PyTupleObject.ob_item]
    mov [rdx], rcx

    ; Create empty message string (heap — stored in exception struct)
    extern str_from_cstr_heap
    CSTRING rdi, ""
    call str_from_cstr_heap
    mov [rbp - CEM_TMP2], rax ; TMP2 = empty msg str

    ; eg_new(ExceptionGroup_type, empty_str, tuple)
    lea rdi, [rel exc_ExceptionGroup_type]
    mov rsi, [rbp - CEM_TMP2]
    mov rdx, [rbp - CEM_TMP1]
    call eg_new
    mov [rbp - CEM_MATCH], rax  ; match_eg

    ; DECREF temp empty str (eg_new INCREFed it)
    mov rdi, [rbp - CEM_TMP2]
    call obj_decref
    ; DECREF temp tuple (eg_new INCREFed it)
    mov rdi, [rbp - CEM_TMP1]
    call obj_decref

    ; Pop exc_value from stack, push None (rest), push match_eg
    VPOP rdi                 ; pop exc_value
    call obj_decref

    lea rax, [rel none_singleton]
    INCREF rax
    VPUSH_PTR rax            ; push rest = None

    mov rax, [rbp - CEM_MATCH]
    VPUSH_PTR rax            ; push match_eg (owns ref from eg_new)

    ; DECREF match_type
    mov rdi, [rbp - CEM_MTYPE]
    call obj_decref

    leave
    DISPATCH

.cem_full_group_match:
    ; Case 1: exc_value is ExceptionGroup and isinstance matches entirely
    ; Do eg_split to separate matching from non-matching
    mov rdi, [rbp - CEM_EXC]
    mov rsi, [rbp - CEM_MTYPE]
    call eg_split
    ; rax = match_eg (or NULL), rdx = rest_eg (or NULL)
    mov [rbp - CEM_MATCH], rax
    mov [rbp - CEM_REST], rdx

    ; Pop exc_value, push rest, push match
    VPOP rdi
    call obj_decref

    ; Push rest (or None if NULL)
    mov rax, [rbp - CEM_REST]
    test rax, rax
    jnz .cem_push_rest
    lea rax, [rel none_singleton]
    INCREF rax
.cem_push_rest:
    VPUSH_PTR rax

    ; Push match (or None if NULL — shouldn't happen since isinstance matched)
    mov rax, [rbp - CEM_MATCH]
    test rax, rax
    jnz .cem_push_match
    lea rax, [rel none_singleton]
    INCREF rax
.cem_push_match:
    VPUSH_PTR rax

    ; DECREF match_type
    mov rdi, [rbp - CEM_MTYPE]
    call obj_decref

    leave
    DISPATCH

.cem_check_group_split:
    ; Not a direct isinstance match. Check if exc_value is an ExceptionGroup
    ; and split by match_type.
    mov rdi, [rbp - CEM_EXC]
    call eg_is_base_exception_group
    test eax, eax
    jz .cem_no_match

    ; It IS an ExceptionGroup — split it
    mov rdi, [rbp - CEM_EXC]
    mov rsi, [rbp - CEM_MTYPE]
    call eg_split
    ; rax = match_eg (or NULL), rdx = rest_eg (or NULL)
    mov [rbp - CEM_MATCH], rax
    mov [rbp - CEM_REST], rdx

    ; If match is NULL, no match at all
    test rax, rax
    jz .cem_split_no_match

    ; Pop exc_value, push rest, push match
    VPOP rdi
    call obj_decref

    ; Push rest (or None if NULL)
    mov rax, [rbp - CEM_REST]
    test rax, rax
    jnz .cem_split_push_rest
    lea rax, [rel none_singleton]
    INCREF rax
.cem_split_push_rest:
    VPUSH_PTR rax

    ; Push match
    mov rax, [rbp - CEM_MATCH]
    VPUSH_PTR rax

    ; DECREF match_type
    mov rdi, [rbp - CEM_MTYPE]
    call obj_decref

    leave
    DISPATCH

.cem_split_no_match:
    ; Split returned no match — clean up and push None
    ; rest_eg might be non-NULL, DECREF it
    mov rdi, [rbp - CEM_REST]
    test rdi, rdi
    jz .cem_no_match
    call obj_decref
    ; Fall through to no_match

.cem_no_match:
    ; No match — keep exc_value on stack, push None
    lea rax, [rel none_singleton]
    INCREF rax
    VPUSH_PTR rax

    ; DECREF match_type
    mov rdi, [rbp - CEM_MTYPE]
    call obj_decref

    leave
    DISPATCH
END_FUNC op_check_eg_match

;; ============================================================================
;; op_raise_varargs (130) - Raise an exception
;; arg 0: reraise current exception
;; arg 1: raise TOS
;; arg 2: raise TOS1 from TOS (chaining, simplified)
;; ============================================================================
DEF_FUNC_BARE op_raise_varargs
    test ecx, ecx
    je .reraise
    cmp ecx, 1
    je .raise_exc
    cmp ecx, 2
    je .raise_from

    ; Invalid arg
    CSTRING rdi, "SystemError: bad RAISE_VARARGS arg"
    extern fatal_error
    call fatal_error

.reraise:
    ; A bare `raise` re-raises the exception being HANDLED, not one in flight:
    ; it is only legal inside an except block, and what it names is that
    ; block's exception.  Reading current_exception instead made it a
    ; RuntimeError everywhere the handler had suspended and come back --
    ; across an `await`, most visibly.
    mov rax, [gs:ThreadState.handled_exception]
    test rax, rax
    jnz .do_reraise
    ; Nothing is being handled - raise RuntimeError
    extern exc_RuntimeError_type
    RAISE exc_RuntimeError_type, "No active exception to re-raise"
    ; does not return here

.do_reraise:
    ; It stays installed -- the handler is still running -- so the in-flight
    ; copy needs a reference of its own.  No traceback entry: a bare `raise`
    ; re-raises what this frame is already in the traceback for, and CPython's
    ; RAISE_VARARGS 0 goes straight to the unwind rather than through the
    ; label that records one.  Without this every re-raise added a second
    ; entry for the same frame, pointing at the `raise` line.
    INCREF rax
    mov rdi, [gs:ThreadState.current_exception]
    mov [gs:ThreadState.current_exception], rax
    test rdi, rdi
    jz .do_reraise_go
    call obj_decref
.do_reraise_go:
    mov byte [gs:ThreadState.tb_suppress_frame], 1
    jmp eval_exception_unwind

.raise_exc:
    ; TOS is the exception to raise
    xor r15d, r15d                 ; no `from` clause
    VPOP_VAL rdi, r8
    PUBLISH_SP  ; update saved stack — VPOP consumed the item

.raise_normalize:
    ; rdi/r8 = the exception operand, r15 = the raw `from` operand as a Value
    ; (0 when there is no `from`).  Both forms of the opcode arrive here, and
    ; the exception is normalised BEFORE the cause is looked at -- which is
    ; the order CPython reports the two errors in, so `raise 5 from 5`
    ; complains about the exception rather than about the cause.

    ; Check if it's already an exception object or a type
    ; If it's a type, create an instance with no args
    cmp r8d, TAG_PTR
    jne .raise_bad_no_decref  ; non-pointer can't be an exception
    test rdi, rdi
    jz .raise_bad_no_decref   ; NULL can't be an exception

    ; Check INSTANCE first (most common case: raise SomeException("msg"))
    ; An instance's ob_type chain might be an exception type
    extern type_is_exc_subclass
    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .raise_bad
    push rdi
    push rdi                  ; and a pad: this handler carves no frame,
                              ; so a lone push leaves the call 8 out
    mov rdi, rax
    call type_is_exc_subclass
    pop rdi
    pop rdi
    test eax, eax
    jnz .raise_exc_obj

    ; Check if rdi is an exception TYPE (e.g., bare "raise ValueError")
    ; First verify rdi is actually a type object (ob_type == type_type, exc_metatype,
    ; or user_type_metatype) to avoid segfault on non-type objects like strings
    mov rax, [rdi + PyObject.ob_type]
    extern type_type
    lea rcx, [rel type_type]
    cmp rax, rcx
    je .raise_check_type
    extern exc_metatype
    lea rcx, [rel exc_metatype]
    cmp rax, rcx
    je .raise_check_type
    extern user_type_metatype
    lea rcx, [rel user_type_metatype]
    cmp rax, rcx
    jne .raise_bad               ; not a type object at all

.raise_check_type:
    ; rdi is a type object — check if it's an exception subclass
    push rdi
    push rdi                  ; and a pad: this handler carves no frame,
                              ; so a lone push leaves the call 8 out
    call type_is_exc_subclass
    pop rdi
    pop rdi
    test eax, eax
    jnz .raise_type

    jmp .raise_bad

.raise_type:
    ; rdi = exception type.  CALL it, rather than assembling an instance
    ; behind its back.
    ;
    ; exc_new allocates the object and builds its args tuple directly: it
    ; never consults tp_new and never runs __init__.  So a class with a
    ; constructor of its own got none of it, and `raise OSError` produced an
    ; object with no errno attribute at all -- OSError's whole constructor,
    ; the one that rewrites the class from the errno and fills the four named
    ; fields, is a tp_new this was stepping around.
    ;
    ; The metatype's tp_call is the one call that is right for both kinds of
    ; exception class: exc_metatype's is exc_type_call, which finds a builtin
    ; tp_new along tp_base, and user_type_metatype's is type_call, which runs
    ; the Python __init__ afterwards.  .raise_check_type has already proved
    ; the metatype is one of the three, so the load is safe.
    ;
    ; kw_names_pending is 0 here: RAISE_VARARGS always follows a CALL that
    ; consumed it, and exc_type_call subtracts it from nargs.
    ; The second push is the pad this frameless handler needs, and it carries
    ; the exception in flight before the construction -- a Python __init__
    ; that raises comes BACK here with the object built and its own exception
    ; pending, so rax alone does not say whether the construction succeeded.
    push rdi
    mov rax, [gs:ThreadState.current_exception]
    push rax
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    xor esi, esi              ; no arguments
    xor edx, edx              ; nargs = 0
    call rax
    pop rcx                   ; the snapshot
    pop rdi                   ; discard type (immortal, no DECREF needed)
    test rax, rax
    jz .raise_propagate
    cmp rcx, [gs:ThreadState.current_exception]
    jne .raise_ctor_raised    ; __new__ or __init__ raised; THAT is the
                              ; exception now, and it is already pending
    mov rdi, rax

    ; And what came back has to BE an exception.  A __new__ that answers
    ; something else has taken the construction over, and type_call hands that
    ; back untouched -- `class E(Exception): __new__ = lambda cls, *a: object()`
    ; then `raise E` would otherwise install a plain object as the exception
    ; in flight, and the first thing to read its __cause__ would not find one.
    ; CPython refuses it with the message the non-exception operand gets, and
    ; has a named test for it.
    V_TEST_PTR rdi, rax
    ja .raise_bad
    test rdi, rdi
    jz .raise_bad_no_decref
    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .raise_bad
    push rdi
    push rdi                  ; and a pad, as above
    mov rdi, rax
    call type_is_exc_subclass
    pop rdi
    pop rdi
    test eax, eax
    jz .raise_bad
    jmp .raise_exc_obj

.raise_ctor_raised:
    ; The half-built object is dropped, as CPython drops it.
    mov rdi, rax
    call obj_decref
.raise_propagate:
    PUBLISH_SP
    jmp eval_exception_unwind

.raise_exc_obj:
    ; rdi = exception object, owned -- the value stack's reference, which
    ; exc_install takes over along with the __context__ rule.
    test r15, r15
    jz .raise_install              ; plain `raise X`

    ; `raise X from Y`.  The cause is applied HERE, and not where it was
    ; popped, because until now rdi may still have been the exception CLASS:
    ; PyExceptionObject.exc_suppress and PyTypeObject.tp_getattr are both at
    ; +72, so writing the suppress flag into a class stored 1 in its getattr
    ; slot and the next attribute access on that class called address 1.
    push rdi
    push rdi                      ; and a pad: this handler carves no frame
    mov rdi, r15
    call raise_coerce_cause
    pop rdi
    pop rdi
    cmp rax, -1
    je .raise_bad_cause
    mov qword [rdi + PyExceptionObject.exc_suppress], 1
    mov [rdi + PyExceptionObject.exc_cause], rax

.raise_install:
    extern exc_install
    call exc_install
    jmp eval_exception_unwind

.raise_bad_cause:
    ; The exception itself was fine; only the cause was not.  Release it and
    ; report the cause, the way CPython words it.
    call obj_decref
    RAISE exc_TypeError_type, "exception causes must derive from BaseException"

.raise_bad:
    ; DECREF the bad value (pointer guaranteed here) and raise TypeError
    call obj_decref
.raise_bad_no_decref:
    XDECREF_V r15, rax            ; a `from` operand this raise never reached
    RAISE exc_TypeError_type, "exceptions must derive from BaseException"

.raise_from:
    ; TOS = cause, TOS1 = exception.  The cause is carried in r15 (callee-saved,
    ; so it survives the normaliser's calls) and applied at .raise_exc_obj.
    VPOP r15                  ; cause, as an encoded Value; never 0 here
    VPOP_VAL rdi, r8          ; exception
    PUBLISH_SP  ; update saved stack — VPOPs consumed both
    jmp .raise_normalize
END_FUNC op_raise_varargs


;; ============================================================================
;; raise_coerce_cause(rdi = the `from` operand as a Value, an owned reference
;;   when it is a pointer) -> rax
;;
;;   0    the operand was None: no __cause__, though the clause still
;;        suppresses the implicit __context__
;;   -1   the operand is not an exception at all; the caller raises TypeError
;;   else an OWNED exception instance to store as __cause__
;;
;; The reference handed in is consumed either way.  A CLASS is instantiated,
;; exactly as the exception operand of `raise` is -- `raise X from KeyError`
;; must store a KeyError(), not the class, or the traceback printer reads a
;; traceback out of a type object.
;; ============================================================================
RCC_FRAME equ 8               ; + 1 push = 16, so the calls below are aligned
DEF_FUNC_LOCAL raise_coerce_cause, RCC_FRAME
    push rbx
    mov rbx, rdi

    ; None is a singleton, so identity is the whole test.
    lea rax, [rel none_singleton]
    cmp rbx, rax
    je .rcc_none

    ; An int, a float or a NULL cannot be an exception.
    V_TEST_PTR rbx, rax
    ja .rcc_bad
    test rbx, rbx
    jz .rcc_bad

    ; An INSTANCE of an exception is the cause itself.
    mov rdi, [rbx + PyObject.ob_type]
    test rdi, rdi
    jz .rcc_bad
    call type_is_exc_subclass
    test eax, eax
    jnz .rcc_instance

    ; Otherwise it has to be an exception CLASS.  Verify it is a type at all
    ; before asking whether it is one: type_is_exc_subclass walks tp_mro.
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel type_type]
    cmp rax, rcx
    je .rcc_is_type
    lea rcx, [rel exc_metatype]
    cmp rax, rcx
    je .rcc_is_type
    lea rcx, [rel user_type_metatype]
    cmp rax, rcx
    jne .rcc_bad

.rcc_is_type:
    mov rdi, rbx
    call type_is_exc_subclass
    test eax, eax
    jz .rcc_bad
    ; CALL it with no arguments, for the reason .raise_type does: a cause
    ; spelled as a class deserves its own constructor as much as the exception
    ; being raised does, and `raise X from OSError` was reaching exc_new too.
    ; raise_coerce_cause is entered with a real frame, so no pad is needed.
    mov rdi, rbx
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    xor esi, esi
    xor edx, edx
    call rax
    jmp .rcc_out

.rcc_instance:
    mov rax, rbx                  ; keep the reference we were handed
    jmp .rcc_out

.rcc_none:
    mov rdi, rbx
    call obj_decref
    xor eax, eax
    jmp .rcc_out

.rcc_bad:
    DECREF_V rbx, rax
    mov rax, -1

.rcc_out:
    pop rbx
    leave
    ret
END_FUNC raise_coerce_cause

;; ============================================================================
;; op_reraise (119) - Re-raise the current exception
;; TOS = exception to re-raise
;; ============================================================================
DEF_FUNC_BARE op_reraise
    ; Pop the exception from value stack
    VPOP_VAL rdi, r8
    PUBLISH_SP  ; update saved stack — VPOP consumed the item

    ; Store it as current exception
    push rdi
    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jz .no_prev_rr
    push rdi
    mov rdi, rax
    call obj_decref
    pop rdi
.no_prev_rr:
    pop rdi
    mov [gs:ThreadState.current_exception], rdi
    ; RERAISE must not add a traceback entry: CPython records one at its
    ; `error:` label, which RERAISE skips by jumping straight to the unwind.
    ; Without this the implicit cleanup handler at the end of every `except`
    ; block added a second entry for the same frame, pointing at the
    ; `except` line.
    mov byte [gs:ThreadState.tb_suppress_frame], 1
    jmp eval_exception_unwind
END_FUNC op_reraise
