; opcodes/arith.asm - Arithmetic and comparison opcode handlers
;
; BINARY_OP and COMPARE_OP, the unary operators, and the specialized and fused
; int/float superinstructions the quickening pass emits in their place.
; binary_op_offsets lives here, next to the only handler that reads it.
;
; Register convention (callee-saved, preserved across handlers):
;   rbx = bytecode instruction pointer (current position in co_code[])
;   r12 = current frame pointer (PyFrame*)
;   r13 = value stack top pointer (Value[], one 64-bit word per slot)
;   r14 = co_consts tuple data pointer (&tuple.ob_item[0])
;
; co_names is accessed via the LOAD_CO_NAMES macro (reads a global).
; ecx = opcode argument on entry (set by eval_dispatch)
; rbx has already been advanced past the 2-byte instruction word.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

section .text

extern str_type
extern int_is_integer
extern eval_dispatch
extern obj_is_true
extern bool_true
extern bool_false
extern int_type
extern float_type
extern bool_type
extern float_number_methods
extern raise_exception
extern exc_TypeError_type
extern obj_decref
extern none_singleton
extern obj_dealloc
extern opcode_table
extern opcode_dispatch_table

;; Stack layout constants for binary_op / compare_op generic paths.
;; After 4 pushes: right, right_tag, left, left_tag
;; Offsets relative to rsp immediately after the 4 pushes.
BO_RIGHT equ 0
BO_RTAG  equ 8
BO_LEFT  equ 16
BO_LTAG  equ 24
; The op index, pushed under the operands so the four offsets above are what
; they always were.  It lived in r9d, which is caller-saved: the reflected
; dunder call clobbers it, and that is the path every unsupported pair ends
; up on -- so the message read binary_op_symbols[0] and every operator in the
; interpreter reported itself as '+'.
BO_OP    equ 40
; The pad, put to work.  CPython's PyNumber_Add tries BOTH operands' nb_add --
; the reflected half included -- before it falls back to the left's sq_concat,
; and a sequence's sq_concat raises rather than declining, in this tree as in
; CPython.  So the right operand has to be asked FIRST or it is never asked at
; all.  This says "the right slot was tried for a concat; if it declined, the
; left's sq_concat is still owed a turn", and .binop_try_dunder reads it.
BO_SEQFB equ 32
BO_SIZE  equ 48
; op_compare_op saves the same four words in the same order and needs no op
; index -- its own is in a register nothing calls across.  It had shared
; BO_SIZE, so widening that one would have discarded two words it never
; pushed.
; ...and two words under them, so CO_SIZE is 48 rather than 32.  CO_EXC holds
; the exception that was pending on the way IN, which is what tells a
; comparison that DECLINED from one that RAISED: both report a NULL Value.
; The second word is a pad.  Every `[rsp + BO_*]` in op_compare_op, and every
; `sub rsp, 8` that aligns a call inside it, is written against a base of four
; pushes from an aligned entry -- so anything added has to sit DEEPER than all
; of them and has to come in pairs.
CO_EXC   equ 32
CO_SIZE  equ 48

; Did the comparison just RAISE, or merely decline?
;
; tp_richcompare and dunder_call_2 both report "no opinion" by returning a
; NULL Value, and a raise arrives as the same NULL.  op_compare_op told the
; two apart by not asking, so every exception out of a user __eq__ was
; swallowed and the answer came from the identity fallback: `a == b` was False
; and `a == a` was True where CPython raises, and the ordering operators
; reported "'<' not supported between instances of ..." instead of whatever
; had been raised.  The exception was never cleared either, so it resurfaced
; at interpreter shutdown.
;
; A frame may already be handling an exception -- inside an `except` block it
; is -- so "is anything pending now" is not the question; "is the pending one
; different from the one that was pending before the call" is.  This is
; EXC_RAISED_SINCE's rule; the macro itself cannot be used here because it
; pushes a scratch register, and every operand in this handler is addressed
; through rsp.
;
; %1 = bytes pushed above the four-word base at this point
; %2 = where to go when it really was a decline
;
; rax is the scratch: every path that reaches this had a zero Value, so
; V_UNPACK left rax and edx both zero.  edx is left alone -- the decline paths
; read it.
%macro CMP_DECLINED_OR_RAISED 2
    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jz %2
    cmp rax, [rsp + %1 + CO_EXC]
    je %2
%if %1 != 0
    add rsp, %1
%endif
    jmp .cmp_raised
%endmacro

; A dunder that answers the NotImplemented singleton is DECLINING, exactly as
; a slot declines with a NULL Value -- the protocol is supposed to move on to
; the reflected form and then to TypeError.  All three dunder calls below
; handed it back as the result instead, so `B() + C()` for a B whose __add__
; returns NotImplemented printed NotImplemented rather than calling C.__radd__.
; (rax, edx) hold the returned Value; r9 holds the op code and does not
; survive obj_decref.
%macro DUNDER_NULL_RAISED 0
    cmp qword [gs:ThreadState.current_exception], 0
    jne .binop_subclass_raised
%endmacro

%macro BINOP_DECLINED 1         ; %1 = where to go when it declined
    extern notimpl_singleton
    lea rcx, [rel notimpl_singleton]
    cmp rax, rcx
    jne %%kept
    push r9
    sub rsp, 8
    mov rdi, rax
    call obj_decref
    add rsp, 8
    pop r9
    jmp %1
%%kept:
%endmacro

;; Stack layout constants for op_build_string (DEF_FUNC, 16 bytes).

;; Stack layout constants for op_send (DEF_FUNC, 48 bytes).

;; Stack layout constants for op_match_keys (DEF_FUNC, 32 bytes).

; --- moved to a sibling file by the split ---
extern op_send

section .text

;; ============================================================================
;; op_binary_op - Perform a binary operation
;;
;; ecx = NB_* argument (operation selector)
;; Pops right (b) then left (a), dispatches through type's tp_as_number.
;; Followed by 1 CACHE entry (2 bytes) that must be skipped.
;; ============================================================================
;; ============================================================================
;; binop_is_number(rdi = payload, rsi = tag) -> eax 0/1
;; True for the three things float arithmetic may be coerced with: an int
;; immediate, a float immediate, and a heap int or bool.
;; ============================================================================
DEF_FUNC_BARE binop_is_number
    cmp rsi, TAG_SMALLINT
    je .bn_yes
    cmp rsi, TAG_FLOAT
    je .bn_yes
    test rsi, TAG_RC_BIT
    jz .bn_no
    test rdi, rdi
    jz .bn_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .bn_yes
    lea rcx, [rel bool_type]
    cmp rax, rcx
    je .bn_yes
    lea rcx, [rel float_type]
    cmp rax, rcx
    je .bn_yes
    mov rax, [rax + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_INT_SUBCLASS
    jnz .bn_yes
    ; A float subclass keeps its double inline, where float_to_f64 reads it.
    test rax, TYPE_FLAG_FLOAT_SUBCLASS
    jnz .bn_yes
.bn_no:
    xor eax, eax
    ret
.bn_yes:
    mov eax, 1
    ret
END_FUNC binop_is_number


;; ============================================================================
;; binop_left_wrapper(rdi = left payload, rsi = left tag, edx = op index 0..25)
;;   -> rax = the slots.asm binary wrapper the LEFT operand's type holds for
;;      this op, or 0
;;
;; The question the slot alone can no longer answer.  Every heaptype that
;; overrides an operator now holds the SAME function in its nb_ slot, so
;; "which function is there" says nothing about which type defined what --
;; only whether it is one of ours, and for which op.
;;
;; Clobbers rax, rcx and rdx only: op_binary_op keeps the slot offset in r8
;; and the op index in r9 across the call.
;; ============================================================================
extern slot_binop_wrappers
DEF_FUNC_BARE binop_left_wrapper
    cmp rsi, TAG_PTR
    jne .blw_no
    test rdi, rdi
    jz .blw_no
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jz .blw_no
    mov ecx, edx
    lea rdx, [rel binary_op_offsets]
    mov rdx, [rdx + rcx*8]
    mov rax, [rax + rdx]        ; the function this type holds for the op
    test rax, rax
    jz .blw_no
    lea rdx, [rel slot_binop_wrappers]
    cmp rax, [rdx + rcx*8]
    jne .blw_no
    ret
.blw_no:
    xor eax, eax
    ret
END_FUNC binop_left_wrapper

;; ============================================================================
;; binop_subclass_first(rdi = left payload, rsi = left tag,
;;                      rdx = right payload, rcx = right tag,
;;                      r8 = the byte offset into PyNumberMethods,
;;                      r9 = the reflected dunder's C string, or 0)
;;   -> rax = a result VALUE with ecx = 1, ecx = 0 to carry on,
;;      or ecx = 2 when the reflected call raised
;;
;; The other half of CPython's binary_op1: when the right operand's type is a
;; PROPER SUBCLASS of the left's and overrides the operator, the right side
;; goes first.  1 + MyInt(2) for a MyInt defining __radd__ answered 3 here
;; and answers 'MyInt.radd' in CPython.
;;
;; Only reached when the left operand is not a heaptype holding our own
;; wrapper -- that wrapper runs the same rule itself, in
;; slot_binop_reflect_first, because for two such types the slot functions
;; are one object and CPython's `slotv != slotw` cannot separate them.
;;
;; The test here is likewise the reflected NAME rather than the slot pointer.
;; A class defining only __radd__ inherits int's nb_add, where CPython's
;; slot_nb_add serves both directions and so differs from long_add; and the
;; reflected DUNDER is what has to run, not the inherited slot, which would
;; simply add.
;; ============================================================================
BSF_LEFT  equ 8
BSF_LTAG  equ 16
BSF_RIGHT equ 24
BSF_RTAG  equ 32
BSF_LTYPE equ 40
BSF_RTYPE equ 48
BSF_RNAME equ 56
BSF_LMETH equ 64
BSF_EXC   equ 72
BSF_FRAME equ 80            ; + 0 pushes = 80
extern eval_exception_unwind
DEF_FUNC_LOCAL binop_subclass_first, BSF_FRAME
    mov [rbp - BSF_LEFT], rdi
    mov [rbp - BSF_LTAG], rsi
    mov [rbp - BSF_RIGHT], rdx
    mov [rbp - BSF_RTAG], rcx
    mov [rbp - BSF_RNAME], r9
    test r9, r9
    jz .bsf_no                  ; no reflected form for this operator

    ; The operands arrive as (payload, tag) PAIRS, not as Values, so the tag
    ; is what names the type -- and 1 + MyInt(2), the whole point of the
    ; rule, has an immediate on the left with no ob_type to read.
    mov esi, esi
    call binop_type_of
    test rax, rax
    jz .bsf_no
    mov [rbp - BSF_LTYPE], rax
    mov rdi, [rbp - BSF_RIGHT]
    mov esi, [rbp - BSF_RTAG]
    call binop_type_of
    test rax, rax
    jz .bsf_no
    mov [rbp - BSF_RTYPE], rax
    cmp rax, [rbp - BSF_LTYPE]
    je .bsf_no                  ; same type: nothing to prefer

    mov rdi, [rbp - BSF_RTYPE]
    mov rsi, [rbp - BSF_LTYPE]
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jz .bsf_no                  ; and a PROPER one, the equality above having
                                ; excluded the other case

    ; method_is_overloaded: the right type must define the reflected name,
    ; and not merely inherit the left type's.
    mov rdi, [rbp - BSF_RTYPE]
    mov rsi, [rbp - BSF_RNAME]
    extern dunder_lookup
    call dunder_lookup
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    jz .bsf_no
    mov [rbp - BSF_LMETH], rax
    mov rdi, [rbp - BSF_LTYPE]
    mov rsi, [rbp - BSF_RNAME]
    call dunder_lookup
    V_UNPACK rax, rdx
    test edx, edx
    jz .bsf_call                ; only the right type defines it
    cmp rax, [rbp - BSF_LMETH]
    je .bsf_no                  ; the same object: inherited, not overridden

.bsf_call:
    DUNDER_EXC_SAVE [rbp - BSF_EXC]
    mov rdi, [rbp - BSF_RIGHT]
    mov rsi, [rbp - BSF_LEFT]
    mov rdx, [rbp - BSF_RNAME]
    mov ecx, [rbp - BSF_LTAG]
    extern dunder_call_2
    call dunder_call_2
    V_UNPACK rax, rdx
    test edx, edx
    jz .bsf_none_or_raised

    extern notimpl_singleton
    lea rcx, [rel notimpl_singleton]
    cmp rax, rcx
    je .bsf_drop_notimpl
    V_PACK rax, rdx
    mov ecx, 1
    leave
    ret

.bsf_drop_notimpl:
    mov rdi, rax                ; dunder_call_2 hands back an owned reference
    extern obj_decref
    call obj_decref
.bsf_no:
    xor eax, eax
    xor ecx, ecx
    leave
    ret

.bsf_none_or_raised:
    EXC_RAISED_SINCE [rbp - BSF_EXC], rcx, .bsf_raised
    xor eax, eax
    xor ecx, ecx
    leave
    ret
.bsf_raised:
    xor eax, eax
    mov ecx, 2
    leave
    ret
END_FUNC binop_subclass_first

;; ============================================================================
;; binop_type_of(rdi = payload, esi = tag) -> rax = the PyTypeObject*, or 0
;; The type an operand names, immediates included.  .binop_left_type does the
;; same thing inline; this is the callable form.
;; ============================================================================
DEF_FUNC_LOCAL binop_type_of
    cmp esi, TAG_SMALLINT
    je .bto_int
    cmp esi, TAG_FLOAT
    je .bto_float
    cmp esi, TAG_PTR
    jne .bto_no
    test rdi, rdi
    jz .bto_no
    mov rax, [rdi + PyObject.ob_type]
    leave
    ret
.bto_int:
    lea rax, [rel int_type]
    leave
    ret
.bto_float:
    lea rax, [rel float_type]
    leave
    ret
.bto_no:
    xor eax, eax
    leave
    ret
END_FUNC binop_type_of

;; ============================================================================
;; cmp_subclass_first(rdi = left payload, esi = left tag,
;;                    rdx = right payload, r8d = right tag,
;;                    r15d = the comparison op)
;;   -> rax = a result VALUE with edx = 1, edx = 0 to carry on,
;;      or edx = 2 when the reflected comparison raised
;;
;; CPython's do_richcompare prologue.  Unlike the arithmetic rule this one
;; asks nothing about which method is overridden -- a proper subclass with a
;; tp_richcompare is enough -- so it is the subtype test and the swapped op.
;; ============================================================================
CSF_LEFT  equ 8
CSF_LTAG  equ 16
CSF_RIGHT equ 24
CSF_RTAG  equ 32
CSF_LTYPE equ 40
CSF_RTYPE equ 48
CSF_OP    equ 56
CSF_EXC   equ 64
CSF_FRAME equ 80            ; + 0 pushes = 80
DEF_FUNC_LOCAL cmp_subclass_first, CSF_FRAME
    mov [rbp - CSF_LEFT], rdi
    mov [rbp - CSF_LTAG], rsi
    mov [rbp - CSF_RIGHT], rdx
    mov [rbp - CSF_RTAG], r8
    mov [rbp - CSF_OP], r15

    ; A pointer on the right is the only shape that can be a subclass of
    ; anything: an immediate names a static type, and no static type here is
    ; a proper subclass of another.
    cmp r8d, TAG_PTR
    jne .csf_no
    test rdx, rdx
    jz .csf_no

    mov esi, esi
    call binop_type_of
    test rax, rax
    jz .csf_no
    mov [rbp - CSF_LTYPE], rax
    mov rdi, [rbp - CSF_RIGHT]
    mov rax, [rdi + PyObject.ob_type]
    mov [rbp - CSF_RTYPE], rax
    cmp rax, [rbp - CSF_LTYPE]
    je .csf_no

    mov rdi, [rbp - CSF_RTYPE]
    mov rsi, [rbp - CSF_LTYPE]
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jz .csf_no

    ; It has to be able to answer: a heaptype with the comparison dunder, or
    ; a type with a tp_richcompare of its own.
    mov rax, [rbp - CSF_RTYPE]
    mov rcx, [rax + PyTypeObject.tp_richcompare]
    test rcx, rcx
    jnz .csf_slot

    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .csf_no
    ; The dunder, with the op swapped: LT<->GT, LE<->GE, EQ and NE their own.
    DUNDER_EXC_SAVE [rbp - CSF_EXC]
    mov rax, [rbp - CSF_OP]
    lea rcx, [rel cmp_swap_table_shared]
    mov eax, [rcx + rax*4]
    extern cmp_dunder_table
    lea rcx, [rel cmp_dunder_table]
    mov rdx, [rcx + rax*8]
    test rdx, rdx
    jz .csf_no
    mov rdi, [rbp - CSF_RIGHT]
    mov rsi, [rbp - CSF_LEFT]
    mov ecx, [rbp - CSF_LTAG]
    extern dunder_call_2
    call dunder_call_2
    V_UNPACK rax, rdx
    test edx, edx
    jz .csf_none_or_raised
    extern notimpl_singleton
    lea rcx, [rel notimpl_singleton]
    cmp rax, rcx
    je .csf_drop_notimpl
    V_PACK rax, rdx
    mov edx, 1
    mov r15, [rbp - CSF_OP]
    leave
    ret

.csf_slot:
    ; tp_richcompare(right Value, left Value, swapped_op) -- the shape
    ; .cmp_do_call uses, with the operands the other way round.
    DUNDER_EXC_SAVE [rbp - CSF_EXC]
    mov rax, [rbp - CSF_OP]
    lea rdx, [rel cmp_swap_table_shared]
    mov r10d, [rdx + rax*4]
    mov rdi, [rbp - CSF_RIGHT]
    mov rcx, [rbp - CSF_RTAG]
    V_PACK rdi, rcx
    mov rsi, [rbp - CSF_LEFT]
    mov rcx, [rbp - CSF_LTAG]
    V_PACK rsi, rcx
    mov edx, r10d
    mov rax, [rbp - CSF_RTYPE]
    mov rax, [rax + PyTypeObject.tp_richcompare]
    call rax
    V_UNPACK rax, rdx
    test edx, edx
    jz .csf_none_or_raised
    extern notimpl_singleton
    lea rcx, [rel notimpl_singleton]
    cmp rax, rcx
    je .csf_drop_notimpl
    V_PACK rax, rdx
    mov edx, 1
    mov r15, [rbp - CSF_OP]
    leave
    ret

.csf_drop_notimpl:
    mov rdi, rax
    extern obj_decref
    call obj_decref
.csf_no:
    xor eax, eax
    xor edx, edx
    mov r15, [rbp - CSF_OP]
    leave
    ret

.csf_none_or_raised:
    EXC_RAISED_SINCE [rbp - CSF_EXC], rcx, .csf_raised
    xor eax, eax
    xor edx, edx
    mov r15, [rbp - CSF_OP]
    leave
    ret
.csf_raised:
    xor eax, eax
    mov edx, 2
    mov r15, [rbp - CSF_OP]
    leave
    ret
END_FUNC cmp_subclass_first

section .rodata
align 4
; LT<->GT, LE<->GE, EQ and NE their own; the same permutation op_compare_op's
; own reflected arm uses, hoisted so both can name it.
cmp_swap_table_shared:
    dd PY_GT, PY_GE, PY_EQ, PY_NE, PY_LT, PY_LE
section .text

DEF_FUNC_BARE op_binary_op
    ; ecx = NB_* op code
    ; Save the op index before pops (VPOP doesn't clobber ecx)
    VPOP_VAL rsi, r8            ; rsi = right operand (b), r8 = right tag
    VPOP_VAL rdi, r9            ; rdi = left operand (a), r9 = left tag

    ; Bools are heap singletons shaped like PyIntObject, so they arrive as
    ; TAG_PTR and the ordinary int path handles them -- no tag rewriting.

    ; Fast path: SmallInt add (NB_ADD=0, NB_INPLACE_ADD=13)
    test ecx, ecx                   ; NB_ADD
    je .binop_try_smallint_add
    cmp ecx, 13                ; NB_INPLACE_ADD
    je .binop_try_smallint_add

    ; Fast path: SmallInt subtract (NB_SUBTRACT=10, NB_INPLACE_SUBTRACT=23)
    cmp ecx, 10                ; NB_SUBTRACT
    je .binop_try_smallint_sub
    cmp ecx, 23                ; NB_INPLACE_SUBTRACT
    je .binop_try_smallint_sub

    ; Fast path: SmallInt multiply (NB_MULTIPLY=5, NB_INPLACE_MULTIPLY=18)
    cmp ecx, 5                 ; NB_MULTIPLY
    je .binop_try_smallint_mul
    cmp ecx, 18                ; NB_INPLACE_MULTIPLY
    je .binop_try_smallint_mul

    ; Fast path: float truediv (NB_TRUE_DIVIDE=11, NB_INPLACE_TRUE_DIVIDE=24)
    cmp ecx, 11                ; NB_TRUE_DIVIDE
    je .binop_try_float_truediv
    cmp ecx, 24                ; NB_INPLACE_TRUE_DIVIDE
    je .binop_try_float_truediv

    ; Fast path: SmallInt floor divide (NB_FLOOR_DIVIDE=2, NB_INPLACE_FLOOR_DIVIDE=15)
    cmp ecx, 2                 ; NB_FLOOR_DIVIDE
    je .binop_try_smallint_fdiv
    cmp ecx, 15                ; NB_INPLACE_FLOOR_DIVIDE
    je .binop_try_smallint_fdiv

    ; Fast path: SmallInt remainder (NB_REMAINDER=6, NB_INPLACE_REMAINDER=19).
    ; This was not in the ladder at all, so `i % 7` went straight to the
    ; generic protocol and reached int_mod's own int64 arm three calls deep.
    cmp ecx, 6                 ; NB_REMAINDER
    je .binop_try_smallint_mod
    cmp ecx, 19                ; NB_INPLACE_REMAINDER
    je .binop_try_smallint_mod

    ; Fast path: SmallInt bitwise.  int_and/int_or/int_xor have had int64 arms
    ; all along; they were just reached through the whole generic protocol.
    cmp ecx, 1                 ; NB_AND
    je .binop_try_smallint_and
    cmp ecx, 14                ; NB_INPLACE_AND
    je .binop_try_smallint_and
    cmp ecx, 7                 ; NB_OR
    je .binop_try_smallint_or
    cmp ecx, 20                ; NB_INPLACE_OR
    je .binop_try_smallint_or
    cmp ecx, 12                ; NB_XOR
    je .binop_try_smallint_xor
    cmp ecx, 25                ; NB_INPLACE_XOR
    je .binop_try_smallint_xor

    ; Fast path: SmallInt shifts and power.  int_lshift, int_rshift and
    ; int_power grew int64 arms of their own, but reaching them still cost the
    ; whole generic protocol -- 45% of a shift loop and 33% of a power loop
    ; went on getting there.
    cmp ecx, 3                 ; NB_LSHIFT
    je .binop_try_smallint_lshift
    cmp ecx, 16                ; NB_INPLACE_LSHIFT
    je .binop_try_smallint_lshift
    cmp ecx, 9                 ; NB_RSHIFT
    je .binop_try_smallint_rshift
    cmp ecx, 22                ; NB_INPLACE_RSHIFT
    je .binop_try_smallint_rshift
    cmp ecx, 8                 ; NB_POWER
    je .binop_try_smallint_pow
    cmp ecx, 21                ; NB_INPLACE_POWER
    je .binop_try_smallint_pow

    ; Everything the ladder did not match -- matrix multiply -- is the
    ; generic protocol's.  This jump is load-bearing: the arms below sit
    ; between here and .binop_generic, so falling through reaches the AND arm
    ; and `i << 3` quietly computed `i & 3`.
    jmp .binop_generic

;; ============================================================================
;; The bitwise and remainder arms of op_binary_op.
;;
;; AND, OR and XOR of two immediates cannot leave the immediate range: a value
;; in [-2^50, 2^50) has bits 50..63 all equal to its sign bit, and a bitwise op
;; on two such values leaves those bits uniform too.  So there is no overflow
;; case to fall out of -- unlike add, subtract and multiply.
;; ============================================================================
.binop_try_smallint_and:
    cmp r9d, TAG_SMALLINT
    jne .binop_generic
    cmp r8d, TAG_SMALLINT
    jne .binop_generic
    mov rax, rdi
    and rax, rsi
    mov byte [rbx - 2], 226
    VPUSH_INT rax, r15
    add rbx, 2
    DISPATCH

.binop_try_smallint_or:
    cmp r9d, TAG_SMALLINT
    jne .binop_generic
    cmp r8d, TAG_SMALLINT
    jne .binop_generic
    mov rax, rdi
    or rax, rsi
    mov byte [rbx - 2], 227
    VPUSH_INT rax, r15
    add rbx, 2
    DISPATCH

.binop_try_smallint_xor:
    cmp r9d, TAG_SMALLINT
    jne .binop_generic
    cmp r8d, TAG_SMALLINT
    jne .binop_generic
    mov rax, rdi
    xor rax, rsi
    mov byte [rbx - 2], 228
    VPUSH_INT rax, r15
    add rbx, 2
    DISPATCH

.binop_try_smallint_mod:
    cmp r9d, TAG_SMALLINT
    jne .binop_generic
    cmp r8d, TAG_SMALLINT
    jne .binop_generic
    test rsi, rsi
    jz .binop_generic          ; zero divisor: the generic path raises
    mov rax, rdi
    cqo
    idiv rsi                   ; rdx = remainder, carrying the DIVIDEND's sign
    ; Python's % takes the sign of the DIVISOR, C's takes the dividend's, so
    ; a remainder that disagrees with the divisor gets the divisor added.  The
    ; result's magnitude is below the divisor's, so it stays an immediate.
    test rdx, rdx
    jz .binop_mod_done
    mov rcx, rdx
    xor rcx, rsi
    jns .binop_mod_done        ; signs already agree
    add rdx, rsi
.binop_mod_done:
    mov rax, rdx
    mov byte [rbx - 2], 229
    VPUSH_INT rax, r15
    add rbx, 2
    DISPATCH

;; ============================================================================
;; The shift and power arms of op_binary_op.
;;
;; Each declines to the generic path rather than specializing when the answer
;; would not fit an immediate, so a site that overflows once stays generic
;; instead of rewriting itself into an opcode that must immediately deopt.
;; ============================================================================
.binop_try_smallint_lshift:
    cmp r9d, TAG_SMALLINT
    jne .binop_generic
    cmp r8d, TAG_SMALLINT
    jne .binop_generic
    cmp rsi, V_INT_SHIFT + 1
    jae .binop_generic         ; unsigned: catches a negative count, which
                               ; raises, and any count that cannot fit
    mov r10, rcx               ; the op index, which cl is about to take
    mov rcx, rsi
    mov rax, rdi
    shl rax, cl
    mov rdx, rax
    sar rdx, cl                ; bits that fell off the top do not come back,
                               ; and `sar` brings a negative one back too
    mov rcx, r10               ; restore before any exit
    cmp rdx, rdi
    jne .binop_generic
    mov rdx, rax
    sar rdx, V_INT_SHIFT
    inc rdx
    cmp rdx, 2
    jae .binop_generic         ; fits an int64 but not an immediate
    mov byte [rbx - 2], 230
    VPUSH_INT rax, r15
    add rbx, 2
    DISPATCH

.binop_try_smallint_rshift:
    cmp r9d, TAG_SMALLINT
    jne .binop_generic
    cmp r8d, TAG_SMALLINT
    jne .binop_generic
    cmp rsi, 64
    jae .binop_generic         ; a negative count raises; 64 and up answer
                               ; 0 or -1, which GMP settles rarely enough
    mov r10, rcx
    mov rcx, rsi
    mov rax, rdi
    sar rax, cl                ; already floors, which is what Python wants
    mov rcx, r10
    ; |result| <= |left| < 2^50, so it is always an immediate.
    mov byte [rbx - 2], 231
    VPUSH_INT rax, r15
    add rbx, 2
    DISPATCH

.binop_try_smallint_pow:
    cmp r9d, TAG_SMALLINT
    jne .binop_generic
    cmp r8d, TAG_SMALLINT
    jne .binop_generic
    test rsi, rsi
    js .binop_generic          ; a negative exponent answers a float
    cmp rsi, 64
    jae .binop_generic         ; any base but 0 and +-1 overflows long before
    ; Repeated squaring, checked at every step.  The base is squared only
    ; while another exponent bit remains, so an overflow in a squaring whose
    ; value would never be used cannot send a result that fitted to GMP.
    mov eax, 1                      ; the running result
    mov r10, rdi               ; b, the running square
    mov r11, rsi               ; e, the remaining exponent
.binop_pow_loop:
    test r11, r11
    jz .binop_pow_fits
    test r11b, 1
    jz .binop_pow_square
    imul rax, r10
    jo .binop_generic
.binop_pow_square:
    shr r11, 1
    jz .binop_pow_fits
    imul r10, r10
    jo .binop_generic
    jmp .binop_pow_loop
.binop_pow_fits:
    mov rdx, rax
    sar rdx, V_INT_SHIFT
    inc rdx
    cmp rdx, 2
    jae .binop_generic
    mov byte [rbx - 2], 232
    VPUSH_INT rax, r15
    add rbx, 2
    DISPATCH

.binop_try_smallint_truediv:
    ; Reached only from .binop_try_float_truediv, which has already
    ; established that both operands are integer immediates.
    test rsi, rsi
    jz .binop_generic          ; zero divisor: the generic path raises
    ; Both immediates are inside +-2^50, so both convert to a double EXACTLY,
    ; and IEEE division of two exact doubles is correctly rounded -- the same
    ; answer CPython's long_true_divide works out the long way.  Neither
    ; overflow nor a subnormal is reachable: the quotient is between 2^-50
    ; and 2^50 in magnitude.
    cvtsi2sd xmm0, rdi
    cvtsi2sd xmm1, rsi
    divsd xmm0, xmm1
    movq rax, xmm0
    mov byte [rbx - 2], 233
    VPUSH_FLOAT rax, r15
    add rbx, 2
    DISPATCH

.binop_generic:
    ; Save operands + tags for DECREF after call (push on machine stack)
    ; Stack layout: [rsp+BO_RIGHT], [rsp+BO_RTAG], [rsp+BO_LEFT], [rsp+BO_LTAG]
    push rcx                   ; the op index, for the error path at the end
    push 0                     ; BO_SEQFB, and a pad so the push list stays even
    push r9                    ; save left tag
    push rdi                   ; save left
    push r8                    ; save right tag
    push rsi                   ; save right

    ; Look up offset in binary_op_offsets table
    ; For inplace variants (13-25), map to same slot as non-inplace (0-12)
    ; The table already has entries for indices 0-25
    lea rax, [rel binary_op_offsets]
    mov r8, [rax + rcx*8]      ; r8 = offset into PyNumberMethods
    mov r9d, ecx               ; r9d = save binary op code (survives float check)

    ; A heaptype that overrides this operator carries the slots.asm wrapper
    ; for it, and for a LEFT operand that wrapper is the whole answer: none of
    ; the specialisations below may run ahead of it.  `class D(int)` with an
    ; __add__ took the float-coercion shortcut for D(1) + 2.5 and answered
    ; 3.5, and `class L(list)` with a __mul__ took sq_repeat for L([1]) * 2
    ; and repeated the list -- in both cases running int's or list's operator
    ; over a method the class had written to replace it.
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_LTAG]
    mov edx, r9d
    call binop_left_wrapper
    test rax, rax
    jz .binop_check_subclass_first
    ; .binop_do_call reads the operands out of rdi and rsi, not off the stack.
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_RIGHT]
    jmp .binop_have_method

.binop_check_subclass_first:
    ; The other half of CPython's binary_op1: when the right operand's type
    ; is a proper subclass of the left's and overrides the operator, the
    ; right side goes first.  1 + MyInt(2) for a MyInt defining __radd__
    ; answered 3 here and answers 'MyInt.radd' in CPython.
    ;
    ; Only when the left is NOT a heaptype holding our wrapper: that wrapper
    ; runs the same rule itself, in slot_binop_reflect_first.
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_LTAG]
    mov rdx, [rsp + BO_RIGHT]
    mov rcx, [rsp + BO_RTAG]
    mov r10, r8                 ; the slot offset; the call clobbers r8
    push r9
    push r10
    mov eax, r9d
    cmp eax, 13
    jl .binop_bsf_ridx
    sub eax, 13
.binop_bsf_ridx:
    extern binop_rdunder_table
    lea r9, [rel binop_rdunder_table]
    mov r9, [r9 + rax*8]
    mov r8, r10
    call binop_subclass_first
    mov r11d, ecx               ; the status; the pops clobber nothing else
    pop r10
    pop r9
    mov r8, r10
    test r11d, r11d
    jz .binop_no_left_wrapper
    cmp r11d, 2
    je .binop_subclass_raised
    ; rax is already a Value; .binop_have_result owes it the two DECREFs the
    ; operands came off the stack with.
    mov edx, TAG_PTR
    jmp .binop_have_result
.binop_subclass_raised:
    ; See .cmp_subclass_raised: the unwinder releases the operands.
    add rsp, 32
    jmp eval_exception_unwind
.binop_no_left_wrapper:

    ; Float coercion: if either operand is TAG_FLOAT, use float methods
    ; This handles int+float, float+int, float+float
    ; Skip for NB_REMAINDER (6) / NB_INPLACE_REMAINDER (19) when left is not float,
    ; because str % value should use str_mod, not float methods.
    ; ... but only when the *other* operand is a number too.  Coercing
    ; unconditionally meant "a" + 1.5 evaluated to 1.5 and [1] * 1.5 to 0.0,
    ; reading the string or the list as a double.
    cmp qword [rsp + BO_LTAG], TAG_FLOAT
    jne .binop_check_right_float
    mov rdi, [rsp + BO_RIGHT]
    mov rsi, [rsp + BO_RTAG]
    call binop_is_number
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_RIGHT]
    test eax, eax
    jz .no_float_coerce
    jmp .use_float_methods

.binop_check_right_float:
    cmp qword [rsp + BO_RTAG], TAG_FLOAT
    jne .no_float_coerce
    ; `"fmt" % 1.5` must reach str_mod rather than float division, and it does:
    ; the binop_is_number test below says no for a str.  Excluding NB_REMAINDER
    ; outright said no for an int as well, so `n % 2.0` went to int's
    ; nb_remainder with a float on the right and dereferenced it as a PyInt.
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_LTAG]
    call binop_is_number
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_RIGHT]
    test eax, eax
    jz .no_float_coerce
    jmp .use_float_methods

.no_float_coerce:
    ; For NB_MULTIPLY (5/18): an integer on one side and a sequence on the
    ; other means sq_repeat -- 3 * "ab", 3 * [1,2].
    ;
    ; "Integer" is int_is_integer, not `tag == TAG_SMALLINT`.  True and False
    ; are heap singletons, every int is a heap object under INT_STRESS=1, and
    ; an int subclass instance is a pointer as well; all three arrive as
    ; TAG_PTR.  Gating on the tag sent them past this arm into int_mul, where
    ; INT_NEED_MPZ wrote an mpz_t over the sequence's own header -- and
    ; `True * [1,2]` is ordinary Python, not a type error.
    ;
    ; r15 is the handler scratch register (CLAUDE.md's register table); r9d
    ; holds the op index and does not survive a call.
    mov r15d, r9d
    mov rdi, [rsp + BO_LEFT]
    mov rdx, [rsp + BO_LTAG]
    call int_is_integer
    mov r9d, r15d
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_RIGHT]
    test eax, eax
    jz .binop_not_int_left
    ; Left is an integer — check if right has sequence methods
    cmp r9d, 5              ; NB_MULTIPLY
    je .binop_try_right_seq
    cmp r9d, 18             ; NB_INPLACE_MULTIPLY
    je .binop_try_right_seq
    jmp .binop_left_type

.binop_try_right_seq:
    ; Check right operand's tp_as_sequence->sq_repeat
    cmp qword [rsp + BO_RTAG], TAG_SMALLINT
    je .binop_left_type
    ; Non-pointer guard: TAG_BOOL/TAG_NONE/TAG_FLOAT can't be sequences
    test qword [rsp + BO_RTAG], TAG_RC_BIT
    jz .binop_left_type
    mov rax, [rsi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .binop_left_type
    mov rax, [rax + PySequenceMethods.sq_repeat]
    test rax, rax
    jz .binop_left_type
    ; Call sq_repeat(right=sequence, left=count): swap args
    xchg rdi, rsi
    mov rdx, [rsp + BO_RTAG]    ; sequence tag (now the left argument)
    mov rcx, [rsp + BO_LTAG]    ; count tag
    V_PACK rdi, rdx
    V_PACK rsi, rcx
    call rax
    V_UNPACK rax, rdx           ; sq_repeat returns a Value
    test edx, edx               ; NotImplemented, as above
    jz .binop_try_dunder
    jmp .binop_have_result

.binop_not_int_left:
    ; A float immediate has no ob_type to read but does have slots, and
    ; .binop_left_type names float_type for exactly that.  Anything else that
    ; is not a pointer has neither.
    cmp qword [rsp + BO_LTAG], TAG_FLOAT
    je .binop_left_type
    ; Non-pointer guard: TAG_NONE and the sentinels can't be dereferenced
    test qword [rsp + BO_LTAG], TAG_RC_BIT
    jz .binop_no_method
    ; Check if left has sq_repeat and right is int (e.g. tuple*3, list*3)
    ; Only for NB_MULTIPLY, not INPLACE (imul uses nb_imul/sq_inplace_repeat)
    cmp r9d, 5              ; NB_MULTIPLY
    je .binop_try_left_seq
    jmp .binop_left_seq_done
.binop_try_left_seq:
    ; Same reasoning as the arm above: the count may be a bool or a heap int.
    mov r15d, r9d
    mov rdi, [rsp + BO_RIGHT]
    mov rdx, [rsp + BO_RTAG]
    call int_is_integer
    mov r9d, r15d
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_RIGHT]
    test eax, eax
    jz .binop_left_seq_done
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .binop_left_seq_done
    mov rax, [rax + PySequenceMethods.sq_repeat]
    test rax, rax
    jz .binop_left_seq_done
    ; Call sq_repeat(left=sequence, right=count)
    ; rdi already = left (sequence), rsi already = right (count)
    mov rdx, [rsp + BO_LTAG]
    mov rcx, [rsp + BO_RTAG]    ; count tag (right operand)
    V_PACK rdi, rdx
    V_PACK rsi, rcx
    call rax
    V_UNPACK rax, rdx           ; sq_repeat returns a Value
    test edx, edx               ; NotImplemented, as above
    jz .binop_try_dunder
    jmp .binop_have_result
.binop_left_seq_done:
    mov rax, [rdi + PyObject.ob_type]
    jmp .binop_have_type
.binop_left_type:
    ; Get type's tp_as_number method table from left operand
    ; SmallInt check: use saved left tag
    cmp qword [rsp + BO_LTAG], TAG_SMALLINT
    je .binop_smallint_type
    ; A float immediate has no ob_type to read, so name float_type here.  It
    ; used to reach its slots only through the coercion arm above, which fires
    ; only when the OTHER operand is a number too -- so `1.5 * <any other
    ; type>` never resolved a type at all and went straight to TypeError.
    ; Invisible while every such pair really was a TypeError; not once a type
    ; exists that float should hand the pair on to.
    cmp qword [rsp + BO_LTAG], TAG_FLOAT
    je .binop_float_type
    ; Non-pointer guard: TAG_NONE and the sentinels can't be dereferenced
    test qword [rsp + BO_LTAG], TAG_RC_BIT
    jz .binop_no_method
    mov rax, [rdi + PyObject.ob_type]
    jmp .binop_have_type
.binop_smallint_type:
    lea rax, [rel int_type]
    jmp .binop_have_type
.binop_float_type:
    lea rax, [rel float_type]
    jmp .binop_have_type
.binop_have_type:
    push rax                   ; save type ptr for sq fallback
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jnz .binop_have_number
    pop rax                    ; restore type ptr
    jmp .binop_try_seq_fallback
.binop_have_number:
    ; A type can have a tp_as_number and still not have THIS slot, and then
    ; the sequence protocol may still answer: bytearray's only numeric slot is
    ; nb_remainder, and `ba += b"x"` is sq_inplace_concat.  Giving bytearray a
    ; tp_as_number for % broke every one of its concatenations until this.
    ;
    ; Narrowly: only for + and * and their inplace forms, and only when the
    ; type really has a tp_as_sequence.  complex has neither an nb_iadd nor a
    ; sequence protocol, and its `z += 1.5` must still reach the inplace
    ; remap below rather than being sent off to a fallback with nothing in it.
    mov rcx, [rax + r8]
    test rcx, rcx
    jnz .binop_number_ok
    cmp qword [rsp], 0
    je .binop_number_ok
    mov rcx, [rsp]
    cmp qword [rcx + PyTypeObject.tp_as_sequence], 0
    je .binop_number_ok
    test r9d, r9d                   ; NB_ADD
    je .binop_seq_from_stack
    cmp r9d, 5                  ; NB_MULTIPLY
    je .binop_seq_from_stack
    cmp r9d, 13                 ; NB_INPLACE_ADD
    je .binop_seq_from_stack
    cmp r9d, 18                 ; NB_INPLACE_MULTIPLY
    jne .binop_number_ok
.binop_seq_from_stack:
    pop rax                    ; the type, for the sequence fallback
    jmp .binop_try_seq_fallback
.binop_number_ok:
    add rsp, 8                 ; discard saved type ptr
    jmp .binop_call_method

.use_float_methods:
    lea rax, [rel float_number_methods]

.binop_call_method:
    ; Get the specific method function pointer
    mov rax, [rax + r8]
    test rax, rax
    jnz .binop_have_method

    ; If inplace slot was NULL, fall back to non-inplace slot
    cmp r9d, 13
    jl .binop_try_right_slot    ; not inplace: the left type simply has no
                                ; such slot, so the right type gets its turn

    ; For a HEAPTYPE that fallback goes through the dunder arm instead of
    ; through the slots.  The two cases the slot cannot tell apart are "this
    ; class never defined __iadd__" and "this class set __iadd__ = None to
    ; block the inherited one" -- the slot is absent either way -- and
    ; remapping straight to nb_add takes the class's __add__ without ever
    ; noticing the block.  The dunder arm asks by name and sees the None.
    ;
    ; It costs nothing that matters: the arm it goes to does the same
    ; __i<op>__-then-__op__ sequence, by name, which is where a heaptype's
    ; answer comes from in the end anyway.
    cmp qword [rsp + BO_LTAG], TAG_PTR
    jne .binop_fb_remap
    mov rcx, [rsp + BO_LEFT]
    test rcx, rcx
    jz .binop_fb_remap
    mov rcx, [rcx + PyObject.ob_type]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jnz .binop_try_dunder

.binop_fb_remap:
    ; Map inplace op to non-inplace offset
    mov ecx, r9d
    sub ecx, 13                 ; inplace → base op
    lea rdx, [rel binary_op_offsets]
    mov rdx, [rdx + rcx*8]     ; non-inplace offset
    ; Float coercion, on the same terms the primary path uses at
    ; .use_float_methods: only when the OTHER operand is something float
    ; arithmetic can actually be coerced with.  This tested the tags alone and
    ; took the coercion for any partner at all -- and since
    ; complex_number_methods leaves every nb_inplace_* NULL, EVERY augmented
    ; assignment between a complex and a float arrived here and left as
    ; "unsupported operand type(s)", while the same operands written `z + 1.5`
    ; worked.
    cmp qword [rsp + BO_LTAG], TAG_FLOAT
    jne .binop_fb_right_float
    push rdx                    ; the slot offset, and the op index: both are
    push r9                     ; caller-saved, and both are needed below
    mov rdi, [rsp + 16 + BO_RIGHT]
    mov rsi, [rsp + 16 + BO_RTAG]
    call binop_is_number
    pop r9
    pop rdx
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_RIGHT]
    test eax, eax
    jnz .binop_fallback_float
    jmp .binop_fb_no_float
.binop_fb_right_float:
    cmp qword [rsp + BO_RTAG], TAG_FLOAT
    jne .binop_fb_no_float
    push rdx
    push r9
    mov rdi, [rsp + 16 + BO_LEFT]
    mov rsi, [rsp + 16 + BO_LTAG]
    call binop_is_number
    pop r9
    pop rdx
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_RIGHT]
    test eax, eax
    jnz .binop_fallback_float
.binop_fb_no_float:
    ; Reload type's tp_as_number
    cmp qword [rsp + BO_LTAG], TAG_SMALLINT
    je .binop_fallback_int
    ; A float immediate whose partner float cannot coerce: float's own slot
    ; still gets to decline, and that is what hands the pair to the right
    ; type.  Without this arm `x = 1.5; x += 2j` went straight to the dunder
    ; arm, which asks nothing of a static type, and was a TypeError while
    ; `1.5 + 2j` was not.
    cmp qword [rsp + BO_LTAG], TAG_FLOAT
    je .binop_fallback_float_type
    test qword [rsp + BO_LTAG], TAG_RC_BIT
    jz .binop_try_dunder
    mov rax, [rdi + PyObject.ob_type]
    jmp .binop_fallback_have_type
.binop_fallback_float_type:
    lea rax, [rel float_type]
    jmp .binop_fallback_have_type
.binop_fallback_float:
    lea rax, [rel float_number_methods]
    jmp .binop_fallback_have_methods
.binop_fallback_int:
    lea rax, [rel int_type]
    jmp .binop_fallback_have_type
.binop_fallback_have_type:
    mov rax, [rax + PyTypeObject.tp_as_number]
.binop_fallback_have_methods:
    mov r8, rdx                ; the effective slot offset, for the right-slot try
    test rax, rax
    jz .binop_try_right_slot
    mov rax, [rax + rdx]
    test rax, rax
    jz .binop_try_right_slot

.binop_have_method:
    ; There is deliberately no guard here on what the right operand is.  There
    ; used to be one, and it tested TYPE_FLAG_HEAPTYPE -- which no builtin
    ; static type carries, so str, list, dict, tuple, bytes, None, range and
    ; slice all walked straight into int's slots.  Deciding whether a slot can
    ; handle a pair is the slot's own job now; each declines with a NULL Value.

.binop_do_call:
    ; Call the method: rdi = left Value, rsi = right Value
    mov rdx, [rsp + BO_LTAG]
    mov rcx, [rsp + BO_RTAG]
    V_PACK rdi, rdx
    V_PACK rsi, rcx
    ; r8 (slot offset) and r9 (op index) are caller-saved and both are needed
    ; after the call now that it can decline.  Two pushes also keep rsp's
    ; 16-byte alignment across the call.
    push r9
    push r8
    call rax
    pop r8
    pop r9
    V_UNPACK rax, rdx           ; the nb_ slot returns a Value
    ; A NULL Value is NotImplemented: the slot does not handle this pair, so
    ; the protocol carries on rather than pushing NULL as the answer.  Without
    ; this test a slot cannot decline, which is why the int slots used to
    ; dereference whatever they were handed instead of refusing it.
    test edx, edx
    jz .binop_try_right_slot

.binop_have_result:
    ; rax = result payload, rdx = result tag
    ; Save result, DECREF operands (tag-aware)
    SAVE_FAT_RESULT            ; save (rax,rdx) result — shifts rsp refs by +16
    mov rdi, [rsp + 16 + BO_RIGHT]
    mov rsi, [rsp + 16 + BO_RTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rsp + 16 + BO_LEFT]
    mov rsi, [rsp + 16 + BO_LTAG]
    DECREF_VAL rdi, rsi
    RESTORE_FAT_RESULT
    add rsp, BO_SIZE           ; discard saved operands + tags

    ; Push result
    VPUSH_VAL rax, rdx

    ; Skip 1 CACHE entry = 2 bytes
    add rbx, 2
    DISPATCH

.binop_try_seq_fallback:
    ; rax = type ptr. Check if type has tp_as_sequence for ADD/MUL ops.
    ; Every exit from here that finds no slot goes to .binop_try_right_slot,
    ; not to the dunder arm: the left type has nothing to offer this pair, and
    ; that is exactly the case where CPython asks the right type.
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .binop_try_right_slot
    ; NB_ADD (0) or NB_INPLACE_ADD (13) → sq_concat / sq_inplace_concat
    test r9d, r9d                   ; NB_ADD
    je .binop_seq_concat
    cmp r9d, 13             ; NB_INPLACE_ADD
    je .binop_seq_iconcat
    ; NB_MULTIPLY (5) or NB_INPLACE_MULTIPLY (18) → sq_repeat
    cmp r9d, 5
    je .binop_seq_repeat_left
    cmp r9d, 18             ; NB_INPLACE_MULTIPLY
    je .binop_seq_irepeat
    jmp .binop_try_right_slot

.binop_seq_iconcat:
    ; The right operand's own nb_add gets its turn before this does; see
    ; .binop_seq_concat.  `a += obj` for an obj with only an __radd__ is
    ; obj.__radd__(a) in CPython, and reaching sq_inplace_concat first made it
    ; "'obj' object is not iterable".
    cmp qword [rsp + BO_SEQFB], 0
    jne .binop_seq_iconcat_direct
    mov qword [rsp + BO_SEQFB], 1
    jmp .binop_try_right_slot
.binop_seq_iconcat_direct:
    mov qword [rsp + BO_SEQFB], 0
    mov rdi, [rsp + BO_LEFT]    ; as .binop_seq_concat_direct: both clobbered
    mov rsi, [rsp + BO_RIGHT]
    mov rax, rdi
    mov rax, [rax + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    ; The comment above said sq_inplace_concat and the code read sq_concat, so
    ; `ba += b"x"` built a NEW bytearray and rebound the name: an alias never
    ; saw the change, and `c is d` went False across it.  bytearray's
    ; sq_inplace_concat has existed all along and nothing reached it.
    mov rcx, [rax + PySequenceMethods.sq_inplace_concat]
    test rcx, rcx
    jz .binop_seq_concat_direct ; the right slot has had its turn already
    mov rax, rcx
    jmp .binop_seq_have_concat

.binop_seq_irepeat:
    mov rcx, [rax + PySequenceMethods.sq_inplace_repeat]
    test rcx, rcx
    jz .binop_seq_repeat_left
    mov rax, rcx
    jmp .binop_seq_have_repeat

.binop_seq_concat:
    ; CPython asks the RIGHT operand's nb_add before it falls back to the
    ; left's sq_concat, and a sequence's sq_concat raises instead of
    ; declining -- so asking it first meant `[1] + obj` for an obj with an
    ; __radd__ never reached the __radd__ at all.  Go round by the right slot
    ; once, and come back here when it declines.
    cmp qword [rsp + BO_SEQFB], 0
    jne .binop_seq_concat_direct
    mov qword [rsp + BO_SEQFB], 1
    jmp .binop_try_right_slot
.binop_seq_concat_direct:
    mov qword [rsp + BO_SEQFB], 0
    ; .binop_seq_have_concat takes the operands out of rdi and rsi, not off
    ; the stack, and the trip through .binop_try_right_slot clobbers both.
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_RIGHT]
    mov rax, rdi
    mov rax, [rax + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .binop_try_dunder
    mov rax, [rax + PySequenceMethods.sq_concat]
    test rax, rax
    jz .binop_try_right_slot
.binop_seq_have_concat:
    ; sq_concat(left, right): rdi=left, rsi=right already set
    mov rdx, [rsp + BO_LTAG]
    mov rcx, [rsp + BO_RTAG]
    V_PACK rdi, rdx
    V_PACK rsi, rcx
    call rax
    V_UNPACK rax, rdx           ; sq_concat returns a Value
    ; A NULL Value is NotImplemented here too, exactly as it is for the nb_
    ; slots.  Untested, a declining sq_concat or sq_repeat pushed NULL onto
    ; the value stack -- which is what `bytearray(b"ab") + [1, 2]` did the
    ; moment bytearray's sq_concat learned to refuse a non-bytes-like.
    test edx, edx
    jz .binop_try_dunder
    jmp .binop_have_result

.binop_seq_repeat_left:
    mov rax, [rax + PySequenceMethods.sq_repeat]
    test rax, rax
    jz .binop_try_right_slot
.binop_seq_have_repeat:
    ; sq_repeat(left=sequence, right=count)
    mov rdx, [rsp + BO_LTAG]
    mov rcx, [rsp + BO_RTAG]
    V_PACK rdi, rdx
    V_PACK rsi, rcx
    call rax
    V_UNPACK rax, rdx           ; sq_repeat returns a Value
    test edx, edx               ; NotImplemented, as above
    jz .binop_try_dunder
    jmp .binop_have_result

.binop_try_right_slot:
    ; The second half of CPython's binary_op1: the LEFT type had no slot, or
    ; had one and declined, so the RIGHT type gets its turn at the same slot,
    ; with the operands still in their original order.
    ;
    ; The "had no slot" half was missing, and every path that found nothing on
    ; the left jumped past this to the dunder arm -- which requires
    ; TYPE_FLAG_HEAPTYPE and therefore refuses every builtin static type.  So
    ; `None | int` was a TypeError: NoneType's nb_or is 0, type's is
    ; union_type_or, and nothing ever asked it.
    ;
    ; This is what lets a type serve an operand the other side has never heard
    ; of, and it is the only route by which a numeric type added later can
    ; answer `1 + <that type>` -- int's slot declines, and the new type's slot
    ; is asked next.  Without it a builtin static type on the right can never
    ; be reached at all: the dunder arm below requires TYPE_FLAG_HEAPTYPE.
    ;
    ; CPython also skips this when both types resolve to the same slot
    ; function.  Not worth a compare here: the only builtins that share one are
    ; int and bool, whose slot declines a second time just as cheaply.
    ;
    ; An inplace op asks the right type for its BINARY slot, never its inplace
    ; one -- that is what CPython's binary_iop1 does when it falls back to
    ; binary_op1.  An nb_i* slot is written for a left operand of its own type
    ; and does not check: `range(3) += [1]` reached list_inplace_concat with a
    ; range as self and dereferenced it as a list.
    cmp r9d, 13
    jl .brs_have_offset
    mov ecx, r9d
    sub ecx, 13                 ; inplace -> base op
    lea rax, [rel binary_op_offsets]
    mov r8, [rax + rcx*8]
.brs_have_offset:
    mov rsi, [rsp + BO_RIGHT]
    mov rcx, [rsp + BO_RTAG]
    cmp rcx, TAG_SMALLINT
    je .brs_int_type
    cmp rcx, TAG_FLOAT
    je .brs_float_type
    test rcx, TAG_RC_BIT
    jz .binop_try_dunder        ; not a pointer: no type to ask
    mov rax, [rsi + PyObject.ob_type]
    jmp .brs_have_type
.brs_int_type:
    lea rax, [rel int_type]
    jmp .brs_have_type
.brs_float_type:
    lea rax, [rel float_type]
.brs_have_type:
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jz .binop_try_dunder
    mov rax, [rax + r8]         ; r8 = the effective nb_* slot offset
    test rax, rax
    jz .binop_try_dunder

    ; CPython's binary_op1 drops this half when both types resolve to the same
    ; slot function.  That used to be unreachable here -- only int and bool
    ; shared one -- and it stopped being unreachable the moment every heaptype
    ; overriding an operator started holding the same wrapper.  Calling it
    ; again would run the LEFT object's __op__ a second time, because the
    ; wrapper speaks for whichever operand is on the left.
    ;
    ; The test is for OUR wrapper on both sides, not merely for two equal
    ; pointers: two operands of the same builtin type trivially share a slot
    ; function, and skipping there would be wrong.  It broke `s += t` for two
    ; plain strs, whose nb_add is str_concat on both sides -- and the left's
    ; nb_iadd, which is what was actually tried, is absent.
    push r9
    push rax
    mov ecx, r9d
    cmp ecx, 13
    jl .brs_have_base
    sub ecx, 13                 ; the same remap .brs_have_offset made
.brs_have_base:
    mov rdi, [rsp + 16 + BO_LEFT]
    mov rsi, [rsp + 16 + BO_LTAG]
    mov edx, ecx
    call binop_left_wrapper
    test rax, rax
    jz .brs_not_shared
    cmp rax, [rsp]
    je .brs_shared
.brs_not_shared:
    pop rax
    pop r9

    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_RIGHT]
    mov rdx, [rsp + BO_LTAG]
    mov rcx, [rsp + BO_RTAG]
    V_PACK rdi, rdx
    V_PACK rsi, rcx
    push r9
    push r8
    call rax
    pop r8
    pop r9
    V_UNPACK rax, rdx
    test edx, edx
    jz .binop_try_dunder        ; both sides declined
    jmp .binop_have_result

.brs_shared:
    pop rax
    pop r9
    jmp .binop_try_dunder

.binop_try_dunder:
    ; A concat that went round by the right slot first is owed its own turn
    ; now that the right slot has declined.
    cmp qword [rsp + BO_SEQFB], 0
    je .binop_dunder_start
    mov ecx, r9d
    cmp ecx, 13
    je .binop_seq_iconcat_direct
    jmp .binop_seq_concat_direct

.binop_dunder_start:
    ; Try dunder method on heaptype objects
    extern binop_dunder_table
    extern binop_rdunder_table
    extern binop_inplace_dunder_table
    extern dunder_call_2
    extern dunder_lookup

    ; Check if left is heaptype
    cmp qword [rsp + BO_LTAG], TAG_SMALLINT
    je .binop_try_right_dunder ; SmallInt has no dunders
    ; Non-pointer guard: TAG_BOOL/TAG_NONE/TAG_FLOAT can't have dunders
    test qword [rsp + BO_LTAG], TAG_RC_BIT
    jz .binop_try_right_dunder
    mov rdi, [rsp + BO_LEFT]
    mov rax, [rdi + PyObject.ob_type]
    mov rdx, [rax + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .binop_try_right_dunder

    ; The nb_ slot wrapper already called this type's __op__ by name, and it
    ; declined -- asking again here would run the user's method a SECOND time.
    ; Invisible while the method is pure, and a real bug the moment it prints,
    ; counts or mutates anything.
    ;
    ; For a binary op that settles the left side entirely.  For an in-place
    ; one it settles only the in-place probe: the slot asked __iadd__, nobody
    ; has asked __add__ yet, and the fallback below is the only place that
    ; will.
    push r9
    mov rdi, [rsp + 8 + BO_LEFT]
    mov rsi, [rsp + 8 + BO_LTAG]
    mov edx, r9d
    call binop_left_wrapper
    pop r9
    test rax, rax
    jz .binop_dunder_no_wrapper
    cmp r9d, 13
    jl .binop_try_right_dunder  ; binary: the slot has spoken for this side
    jmp .binop_left_dunder      ; in-place: skip the probe, keep the fallback

.binop_dunder_no_wrapper:
    ; For inplace ops, try inplace dunder first
    cmp r9d, 13
    jl .binop_left_dunder

    ; --- Inplace dunder probe ---
    ; Look up inplace dunder on left's type via dunder_lookup
    push r9                    ; save op code (+8 shifts BO_ offsets)
    mov rdi, [rsp + 8 + BO_LEFT]
    mov rdi, [rdi + PyObject.ob_type]
    mov eax, r9d
    sub eax, 13
    lea rsi, [rel binop_inplace_dunder_table]
    mov rsi, [rsi + rax*8]    ; inplace dunder name
    call dunder_lookup
    V_UNPACK rax, rdx           ; returns a Value
    pop r9
    test edx, edx
    jz .binop_left_dunder      ; not found → fall back to regular dunder
    test edx, TAG_RC_BIT
    jz .binop_no_method        ; non-pointer: cannot be called
    IS_NONE rax, rcx
    je .binop_no_method        ; __i<op>__ = None blocks the fallback (TypeError)

    ; Inplace dunder exists and is callable — call via dunder_call_2
    push r9
    mov eax, r9d
    sub eax, 13
    lea rdx, [rel binop_inplace_dunder_table]
    mov rdx, [rdx + rax*8]    ; inplace dunder name
    mov rdi, [rsp + 8 + BO_LEFT]
    mov rsi, [rsp + 8 + BO_RIGHT]
    mov rcx, [rsp + 8 + BO_RTAG]
    call dunder_call_2
    V_UNPACK rax, rdx           ; returns a Value
    pop r9
    test edx, edx
    jz .binop_idunder_null
    BINOP_DECLINED .binop_left_dunder
    jmp .binop_have_result

.binop_left_dunder:
    ; Map op code to regular dunder name
    mov eax, r9d
    cmp eax, 13
    jl .binop_dunder_idx
    sub eax, 13               ; inplace → base op
.binop_dunder_idx:
    lea rdx, [rel binop_dunder_table]
    mov rdx, [rdx + rax*8]
    test rdx, rdx
    jz .binop_try_right_dunder

    ; dunder_call_2(left, right, name, right_tag)
    push r9                    ; save op code (+8 shifts BO_ offsets)
    mov rdi, [rsp + 8 + BO_LEFT]
    mov rsi, [rsp + 8 + BO_RIGHT]
    mov rcx, [rsp + 8 + BO_RTAG]   ; other_tag = right's tag
    call dunder_call_2
    V_UNPACK rax, rdx           ; returns a Value
    pop r9
    test edx, edx
    jz .binop_ldunder_null
    BINOP_DECLINED .binop_try_right_dunder
    jmp .binop_have_result

.binop_try_right_dunder:
    ; Try reflected dunder on right operand
    cmp qword [rsp + BO_RTAG], TAG_SMALLINT
    je .binop_no_method
    ; Non-pointer guard: TAG_BOOL/TAG_NONE/TAG_FLOAT can't have dunders
    test qword [rsp + BO_RTAG], TAG_RC_BIT
    jz .binop_no_method
    mov rdi, [rsp + BO_RIGHT]
    mov rax, [rdi + PyObject.ob_type]
    mov rdx, [rax + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .binop_no_method

    mov eax, r9d
    cmp eax, 13
    jl .binop_rdunder_idx
    sub eax, 13
.binop_rdunder_idx:
    lea rdx, [rel binop_rdunder_table]
    mov rdx, [rdx + rax*8]
    test rdx, rdx
    jz .binop_no_method

    ; dunder_call_2(right, left, rname, left_tag) — right is self for reflected
    mov rdi, [rsp + BO_RIGHT]
    mov rsi, [rsp + BO_LEFT]
    mov rcx, [rsp + BO_LTAG]       ; other_tag = left's tag
    call dunder_call_2
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jz .binop_rdunder_null
    BINOP_DECLINED .binop_no_method
    jmp .binop_have_result

; A dunder that RAISED answers NULL just as an absent one does, and the
; protocol used to carry on to the next candidate and finally report
; "unsupported operand type(s)" over the real exception: `t += x` with t an
; int subclass whose __add__ raised OverflowError said TypeError, while
; `t + x`, which goes through the slot wrapper, did not.  Nothing is in
; flight when an opcode starts (the handler that caught the last one cleared
; it), so a non-zero current_exception here is this call's.
.binop_idunder_null:
    DUNDER_NULL_RAISED
    jmp .binop_left_dunder
.binop_ldunder_null:
    DUNDER_NULL_RAISED
    jmp .binop_try_right_dunder
.binop_rdunder_null:
    DUNDER_NULL_RAISED
    jmp .binop_no_method
.binop_no_method:
    ; Whatever the last call left in r9.
    mov r9d, [rsp + BO_OP]
    ; A sequence multiplied by something that is not an index gets CPython's
    ; own wording, which names only the offending count: "can't multiply
    ; sequence by non-int of type 'float'".
    cmp r9d, 5                  ; NB_MULTIPLY
    je .bnm_mul
    cmp r9d, 18                 ; NB_INPLACE_MULTIPLY
    jne .bnm_generic
.bnm_mul:
    ; The LEFT operand is asked first, which is the order CPython's
    ; PyNumber_Multiply asks in: whichever side has sq_repeat is the
    ; sequence, and the OTHER one is the count the message names.  Asking the
    ; right first names the wrong operand whenever both are sequences, and
    ; `bytearray(b"ab") * "3"` said the bytearray was the non-int.
    mov rdi, [rsp + BO_LEFT]
    mov rcx, [rsp + BO_LTAG]
    cmp rcx, TAG_PTR
    jne .bnm_mul_try_right
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .bnm_mul_try_right
    cmp qword [rax + PySequenceMethods.sq_repeat], 0
    je .bnm_mul_try_right
    mov rdi, [rsp + BO_RIGHT]   ; the left is the sequence, so the right is
    mov rdx, [rsp + BO_RTAG]    ; the count that is not an index
    VALUE_FOR_TYPE rdi, rdx
    jmp .bnm_mul_msg
.bnm_mul_try_right:
    mov rdi, [rsp + BO_RIGHT]
    mov rcx, [rsp + BO_RTAG]
    cmp rcx, TAG_PTR
    jne .bnm_generic
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .bnm_generic
    cmp qword [rax + PySequenceMethods.sq_repeat], 0
    je .bnm_generic
    mov rdi, [rsp + BO_LEFT]
    mov rdx, [rsp + BO_LTAG]
    VALUE_FOR_TYPE rdi, rdx
.bnm_mul_msg:
    mov rsi, rdi
    CSTRING rdi, `can't multiply sequence by non-int of type '\x01'`
    extern raise_type_error_with_name
    call raise_type_error_with_name
    ud2

.bnm_generic:
    ; "unsupported operand type(s) for +: 'int' and 'str'", which is how
    ; CPython words it.  The prefix and the operator go into a stack buffer,
    ; and raise_binop_type_error_ex appends the two type names -- the helper
    ; has been there all along with a single caller in divmod.
    mov r10d, r9d
    cmp r10d, 26
    jb .bnm_have_op
    xor r10d, r10d
.bnm_have_op:
    lea rax, [rel binary_op_symbols]
    mov r10, [rax + r10*8]      ; the operator, as it is written
    sub rsp, 64
    mov rdi, rsp
    lea rsi, [rel binop_msg_prefix]
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, r10
    call rbt_append_cstr
    ; The message needs a Value of each operand's TYPE, and the frame holds
    ; payloads.  Packing a large int here would box it, and the raise below
    ; abandons the stack that would have freed it -- zero has the same type
    ; and allocates nothing.
    mov rdi, [rsp + 64 + BO_LEFT]
    mov rdx, [rsp + 64 + BO_LTAG]
    VALUE_FOR_TYPE rdi, rdx
    mov rsi, [rsp + 64 + BO_RIGHT]
    mov rcx, [rsp + 64 + BO_RTAG]
    VALUE_FOR_TYPE rsi, rcx
    mov rdx, rsp
    extern raise_binop_type_error
    call raise_binop_type_error
    ud2

.binop_try_smallint_add:
    ; Check both TAG_SMALLINT
    cmp r9d, TAG_SMALLINT
    jne .binop_try_float_add
    cmp r8d, TAG_SMALLINT
    jne .binop_try_float_add     ; an int against a float is the mixed arm's

    ; Both SmallInt: decode, add, check overflow
    mov rax, rdi
    mov rdx, rsi
    add rax, rdx
    jo .binop_generic          ; overflow → fall back to generic
    ; Specialize: rewrite opcode to BINARY_OP_ADD_INT (211)
    mov byte [rbx - 2], 211
    VPUSH_INT rax, r15
    add rbx, 2
    DISPATCH

.binop_try_float_add:
    FLOAT_PAIR_OR_DEOPT .binop_try_str_add
    mov byte [rbx - 2], 217
    addsd xmm0, xmm1
    movq rax, xmm0
    VPUSH_FLOAT rax, r15
    add rbx, 2
    DISPATCH

.binop_try_str_add:
    ; `s = s + t` and `s += t` into a local.  Every other arm here answers the
    ; operation; this one only decides that the operands have the shape
    ; BINARY_OP_INPLACE_ADD_UNICODE wants and lets the generic path do the
    ; work this once, exactly as CPython's specializer does.
    ;
    ; The guards it can check now are checked now, including the two that
    ; change from one execution to the next -- the refcount and the hash.  A
    ; loop that hashes its accumulator every iteration would otherwise
    ; specialize and deopt forever, writing an opcode byte twice a turn.
    ; op_binary_op still works in (payload, tag) pairs, so the operands here
    ; are NOT Values and STR_PAIR_OR_DEOPT must not be used on them: a small
    ; int arrives as the bare number 1, which passes a pointer test and is
    ; then dereferenced.  The tags answer the same question exactly.
    cmp r9d, TAG_PTR
    jne .binop_generic
    cmp r8d, TAG_PTR
    jne .binop_generic
    lea r10, [rel str_type]
    cmp [rdi + PyObject.ob_type], r10
    jne .binop_generic
    cmp [rsi + PyObject.ob_type], r10
    jne .binop_generic
    ; A pointer is its own Value, so the target test needs no conversion.
    INPLACE_ADD_TARGET_OR_DEOPT rdi, .binop_generic
    mov byte [rbx - 2], 234
    jmp .binop_generic

.binop_try_smallint_sub:
    ; Check both TAG_SMALLINT
    cmp r9d, TAG_SMALLINT
    jne .binop_try_float_sub
    cmp r8d, TAG_SMALLINT
    jne .binop_try_float_sub     ; an int against a float is the mixed arm's

    ; Both SmallInt: decode, subtract, check overflow
    mov rax, rdi
    mov rdx, rsi
    sub rax, rdx
    jo .binop_generic          ; overflow → fall back to generic
    ; Specialize: rewrite opcode to BINARY_OP_SUBTRACT_INT (212)
    mov byte [rbx - 2], 212
    VPUSH_INT rax, r15
    add rbx, 2
    DISPATCH

.binop_try_float_sub:
    FLOAT_PAIR_OR_DEOPT .binop_generic
    mov byte [rbx - 2], 218
    subsd xmm0, xmm1
    movq rax, xmm0
    VPUSH_FLOAT rax, r15
    add rbx, 2
    DISPATCH

.binop_try_smallint_mul:
    ; Check both TAG_SMALLINT
    cmp r9d, TAG_SMALLINT
    jne .binop_try_float_mul
    cmp r8d, TAG_SMALLINT
    jne .binop_try_float_mul     ; an int against a float is the mixed arm's

    ; Both SmallInt: multiply, check overflow
    mov rax, rdi
    imul rsi
    jo .binop_generic          ; overflow → fall back to generic
    ; Specialize: rewrite opcode to BINARY_OP_MULTIPLY_INT (221)
    mov byte [rbx - 2], 221
    VPUSH_INT rax, r15
    add rbx, 2
    DISPATCH

.binop_try_float_mul:
    FLOAT_PAIR_OR_DEOPT .binop_generic
    mov byte [rbx - 2], 219
    mulsd xmm0, xmm1
    movq rax, xmm0
    VPUSH_FLOAT rax, r15
    add rbx, 2
    DISPATCH

.binop_try_float_truediv:
    ; Two integers belong to the INT arm: FLOAT_PAIR_OR_DEOPT refuses that pair
    ; on purpose -- answering it as floats would be right here and wrong for
    ; every other operator that shares the macro -- so it has to be picked off
    ; before the macro sees it, or `i / 7` goes to the generic path forever.
    cmp r9d, TAG_SMALLINT
    jne .binop_tfd_not_int_pair
    cmp r8d, TAG_SMALLINT
    je .binop_try_smallint_truediv
.binop_tfd_not_int_pair:
    FLOAT_PAIR_OR_DEOPT .binop_generic
    ; A zero divisor has to raise, and the generic path is what raises.
    ; ucomisd sets ZF for UNORDERED too, so parity is consulted first: a NaN
    ; divisor is not a zero one, and treating it as one refused to specialize
    ; the site for the rest of the program.
    xorpd xmm2, xmm2
    ucomisd xmm1, xmm2
    jp .binop_tfd_nonzero
    je .binop_generic
.binop_tfd_nonzero:
    mov byte [rbx - 2], 220   ; BINARY_OP_TRUEDIV_FLOAT
    divsd xmm0, xmm1
    movq rax, xmm0
    VPUSH_FLOAT rax, r15
    add rbx, 2
    DISPATCH

.binop_try_smallint_fdiv:
    ; Check both TAG_SMALLINT
    cmp r9d, TAG_SMALLINT
    jne .binop_generic
    cmp r8d, TAG_SMALLINT
    jne .binop_generic
    test rsi, rsi
    jz .binop_generic          ; zero divisor → generic raises error
    mov rax, rdi
    cqo
    idiv rsi                    ; rax=quotient, rdx=remainder
    ; Floor: if remainder != 0 and signs differ, subtract 1
    test rdx, rdx
    jz .fdiv_exact
    mov rcx, rdi
    xor rcx, rsi
    jns .fdiv_exact             ; same sign → truncation == floor
    dec rax
.fdiv_exact:
    mov byte [rbx - 2], 222    ; specialize to BINARY_OP_FLOORDIV_INT
    VPUSH_INT rax, r15
    add rbx, 2
    DISPATCH
END_FUNC op_binary_op

;; ============================================================================
;; op_compare_op - Rich comparison
;;
;; Python 3.12: comparison op = arg >> 4
;; ecx = arg, extract comparison op by shifting right 4.
;; Calls type's tp_richcompare(left, right, op).
;; Followed by 1 CACHE entry (2 bytes) that must be skipped.
;; ============================================================================
DEF_FUNC_BARE op_compare_op
    ; ecx = arg; comparison op = arg >> 4
    shr ecx, 4                 ; ecx = PY_LT/LE/EQ/NE/GT/GE (0-5)

    VPOP_VAL rsi, r8            ; rsi = right operand, r8 = right tag
    VPOP_VAL rdi, r9            ; rdi = left operand, r9 = left tag

    ; Fast path: both SmallInt — inline compare, no type dispatch
    cmp r9d, TAG_SMALLINT
    jne .cmp_slow_path
    cmp r8d, TAG_SMALLINT
    jne .cmp_slow_path

    ; Both SmallInt: specialize — check if next opcode is POP_JUMP_IF_FALSE/TRUE
    ; rbx points past 2-byte instruction; CACHE at [rbx], next opcode at [rbx+2]
    cmp byte [rbx + 2], 114    ; POP_JUMP_IF_FALSE
    je .cmp_specialize_jump_false
    cmp byte [rbx + 2], 115    ; POP_JUMP_IF_TRUE
    je .cmp_specialize_jump_true
    mov byte [rbx - 2], 209   ; plain COMPARE_OP_INT
    jmp .cmp_do_compare
.cmp_specialize_jump_false:
    mov byte [rbx - 2], 215   ; COMPARE_OP_INT_JUMP_FALSE
    jmp .cmp_do_compare
.cmp_specialize_jump_true:
    mov byte [rbx - 2], 216   ; COMPARE_OP_INT_JUMP_TRUE
    ; fall through

.cmp_do_compare:
    ; Both SmallInt.  This reached one of six `setcc` arms through an indirect
    ; jump on a six-entry table -- a BTB entry, a table load, and a `jmp` back
    ; to the merge point, with a comment about the flags having to survive the
    ; `lea` in between.  arith_spec.asm already replaced exactly that with
    ; int_cmp_result: `2*(x>=y) + (x<=y)` is 1 for less, 2 for greater and 3
    ; for equal, so one byte table indexed by `op*4 + that` answers all six
    ; operators branchlessly.  Six handlers there share the 24 bytes; this is
    ; the seventh, and it takes the `.data` section out of a `.text` file with
    ; it.
    cmp rdi, rsi
    setge al                   ; a >= b
    setle dl                   ; a <= b
    movzx eax, al
    movzx edx, dl
    lea eax, [rdx + rax*2]     ; 1 = less, 2 = greater, 3 = equal
    lea eax, [rax + rcx*4]     ; + op*4
    extern int_cmp_result
    lea rdx, [rel int_cmp_result]
    movzx eax, byte [rdx + rax]
    VPUSH_BOOL rax             ; no INCREF needed: the singletons are immortal
    add rbx, 2
    DISPATCH

.cmp_slow_path:
    ; Both float: specialize, the same way the SmallInt arm above does, and
    ; fuse with the jump that follows when there is one.  This has to come
    ; before the general protocol below, but it is safe there for the reason
    ; the arithmetic superinstructions are: a TAG_FLOAT immediate is never a
    ; heaptype instance, so no user __lt__ can be bypassed.
    ; A float on one side and an integer immediate on the other counts too:
    ; the specialized handlers take that pair now, as the arithmetic ones have
    ; since 34c0596.  `x < 0` for a float x used to reach the general protocol
    ; on every execution with nothing ever rewritten.  TWO integers are not
    ; this arm's -- they belong to the SmallInt arm above, which has already
    ; had its chance.
    cmp r9d, TAG_FLOAT
    je .cmp_float_left_ok
    cmp r9d, TAG_SMALLINT
    jne .cmp_slow_real
    cmp r8d, TAG_FLOAT          ; int on the left needs a float on the right
    jne .cmp_slow_real
    jmp .cmp_float_pair_ok
.cmp_float_left_ok:
    cmp r8d, TAG_FLOAT
    je .cmp_float_pair_ok
    cmp r8d, TAG_SMALLINT
    jne .cmp_slow_real
.cmp_float_pair_ok:
    cmp byte [rbx + 2], 114     ; POP_JUMP_IF_FALSE
    je .cmp_spec_float_jf
    cmp byte [rbx + 2], 115     ; POP_JUMP_IF_TRUE
    je .cmp_spec_float_jt
    mov byte [rbx - 2], 223
    jmp .cmp_float_rerun
.cmp_spec_float_jf:
    mov byte [rbx - 2], 224
    jmp .cmp_float_rerun
.cmp_spec_float_jt:
    mov byte [rbx - 2], 225
.cmp_float_rerun:
    ; The operands are still on the stack -- VPOP_VAL only moved r13 -- so
    ; putting it back and re-dispatching runs the new opcode on them.  The
    ; argument is wide-safe here: COMPARE_OP never carries an EXTENDED_ARG.
    VUNDROP 2
    sub rbx, 2
    DISPATCH

.cmp_slow_real:
    ; Save operands + tags and comparison op
    ; Stack layout: [rsp+BO_RIGHT], [rsp+BO_RTAG], [rsp+BO_LEFT], [rsp+BO_LTAG]
    ;
    ; ...and, under all four, the exception that is pending on the way in.
    ; CMP_DECLINED_OR_RAISED reads it to tell a comparison that declined from
    ; one that raised; see the comment on CO_EXC.
    push rax                   ; the pad, so CO_SIZE stays a multiple of 16
    push rax                   ; CO_EXC, written two lines below
    push r9                    ; save left tag
    push rdi                   ; save left
    push r8                    ; save right tag
    push rsi                   ; save right
    mov rax, [gs:ThreadState.current_exception]
    mov [rsp + CO_EXC], rax

    ; Float coercion: use float_compare when one operand is a float AND the
    ; other is something it accepts.  Short-circuiting on the tag alone sent
    ; float-versus-anything to float_compare, which declines; the retry then
    ; asked the float side again rather than the OTHER operand's
    ; tp_richcompare, so a type that knows how to compare itself to a float
    ; never got the question and the answer came from the identity fallback.
    cmp r9d, TAG_FLOAT
    je .cmp_probe_right
    cmp r8d, TAG_FLOAT
    jne .cmp_no_float
    mov rdi, [rsp + BO_LEFT]
    mov esi, [rsp + BO_LTAG]
    jmp .cmp_probe
.cmp_probe_right:
    mov rdi, [rsp + BO_RIGHT]
    mov esi, [rsp + BO_RTAG]
.cmp_probe:
    ; A HEAPTYPE gets no shortcut.  float_binop_accepts says yes to a float
    ; subclass and to an int subclass -- they ARE numbers -- so this went
    ; straight to float_compare, which answers by value, and
    ; `F(1.5) < 2.0` for an F defining __lt__ never called it.  The general
    ; path below is the one that knows the order to ask in, and CPython
    ; consults such a type's tp_richcompare first as well.
    ;
    ; Nothing legitimate is lost: the only heaptypes float_binop_accepts
    ; accepts are int and float subclasses.  A plain one still compares by
    ; value, one step further along.
    cmp esi, TAG_PTR
    jne .cmp_probe_not_heap
    test rdi, rdi
    jz .cmp_probe_not_heap
    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .cmp_probe_not_heap
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jnz .cmp_no_float
.cmp_probe_not_heap:
    extern float_binop_accepts
    mov r15d, ecx               ; r15 is the handler scratch; ecx holds the op
    call float_binop_accepts
    mov ecx, r15d
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_RIGHT]
    mov r9d, [rsp + BO_LTAG]
    mov r8d, [rsp + BO_RTAG]
    test eax, eax
    jnz .cmp_use_float

.cmp_no_float:
    ; CPython's do_richcompare tries the RIGHT operand first when its type is
    ; a proper subclass of the left's -- the same subclass-priority rule the
    ; arithmetic operators have, and the half bugs.md did not record.
    ; `P() < Q()` for a Q(P) defining __gt__ called P.__lt__ here and calls
    ; Q.__gt__ in CPython.
    mov r15d, ecx               ; r15 is the handler scratch; ecx holds the op
    mov rdi, [rsp + BO_LEFT]
    mov esi, [rsp + BO_LTAG]
    mov rdx, [rsp + BO_RIGHT]
    mov r10d, [rsp + BO_RTAG]
    mov r8d, r10d
    call cmp_subclass_first     ; r15 = op, in and out
    mov ecx, r15d
    test edx, edx
    jz .cmp_no_subclass_first
    cmp edx, 2
    je .cmp_subclass_raised
    ; Both operands came off the value stack owning a reference, so this exit
    ; owes the same two DECREFs every other one does.  Dropping the saved
    ; words without them leaked an object per comparison, which is invisible
    ; until something has a __del__.
    mov edx, TAG_PTR
    jmp .cmp_do_call_result
.cmp_subclass_raised:
.cmp_raised:
    ; No DECREFs here: the unwinder cleans up from PyFrame.disp_sp, which is
    ; where the stack was BEFORE these two came off it, so it releases them.
    add rsp, CO_SIZE
    jmp eval_exception_unwind
.cmp_no_subclass_first:
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_RIGHT]
    mov r9d, [rsp + BO_LTAG]
    mov r8d, [rsp + BO_RTAG]

    ; Get type's tp_richcompare
    cmp r9d, TAG_SMALLINT
    je .cmp_smallint_type
    ; A float immediate has no ob_type; name float_type for it, the same way
    ; .binop_left_type does for arithmetic.
    cmp r9d, TAG_FLOAT
    je .cmp_float_type
    mov rax, [rdi + PyObject.ob_type]
    jmp .cmp_have_type
.cmp_smallint_type:
    lea rax, [rel int_type]
    jmp .cmp_have_type
.cmp_float_type:
    lea rax, [rel float_type]
    jmp .cmp_have_type
.cmp_bool_type:
    lea rax, [rel bool_type]
    jmp .cmp_have_type
.cmp_none_type:
    lea rax, [rel none_type]
    jmp .cmp_have_type
.cmp_have_type:
    mov r9, rax                 ; r9 = type (save for dunder check)
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jnz .cmp_do_call

    ; No tp_richcompare — try dunder on heaptype
    mov rdx, [r9 + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .cmp_left_declines       ; a static type with nothing to say

    ; Map compare op to dunder name via lookup table
    extern cmp_dunder_table
    extern dunder_call_2
    lea rax, [rel cmp_dunder_table]
    movsxd rdx, ecx
    mov rdx, [rax + rdx*8]     ; rdx = dunder name C string

    ; Save ecx (comparison op) since dunder_call_2 clobbers it
    push rcx
    ; dunder_call_2(self=left, other=right, name, right_tag)
    ; rdi = left (still set from above)
    ; rsi = right (still set)
    mov ecx, [rsp + 16]            ; right_tag from stack
    call dunder_call_2
    V_UNPACK rax, rdx           ; returns a Value
    pop rcx

    test edx, edx
    jnz .cmp_have_dunder_result ; got result, proceed
    CMP_DECLINED_OR_RAISED 0, .cmp_dunder_absent

.cmp_dunder_absent:
    ; Dunder not found. If NE, try __eq__ + negate (auto-derivation)
    cmp ecx, PY_NE
    jne .cmp_decline_left       ; not NE → ask the other operand

    ; Every class inherits object's comparison dunders now, and object's
    ; answer for two different objects is NotImplemented.  That is not a
    ; result: it means "no opinion", so the identity fallback below is what
    ; must run, exactly as when the dunder was absent.
.cmp_have_dunder_result:
    cmp edx, TAG_PTR
    jne .cmp_do_call_result
    lea r8, [rel notimpl_singleton]
    cmp rax, r8
    jne .cmp_do_call_result
    push rcx
    mov rdi, rax
    extern obj_decref
    call obj_decref
    pop rcx
    cmp ecx, PY_NE
    je .cmp_ne_from_eq

.cmp_decline_left:
    ; NotImplemented from the left operand is a DECLINE, not an answer:
    ; do_richcompare asks the OTHER operand before it falls back to identity.
    ; This jumped straight to the fallback, so a reflected ordering dunder was
    ; never reached at all -- `R() < Ord()` raised TypeError where CPython
    ; calls Ord.__gt__, for every plain class on the left.  The
    ; tp_richcompare path beside it has always gone on to .cmp_try_right.
    push rcx
    jmp .cmp_try_right

.cmp_ne_from_eq:
    ; Try __eq__ on left's heaptype
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_RIGHT]
    lea rax, [rel cmp_dunder_table]
    mov rdx, [rax + PY_EQ*8]   ; rdx = "__eq__" name
    push rcx
    mov ecx, [rsp + 8 + BO_RTAG]  ; right_tag (+8 for push rcx)
    call dunder_call_2
    V_UNPACK rax, rdx           ; returns a Value
    pop rcx
    test edx, edx
    jnz .cmp_ne_from_eq_have
    CMP_DECLINED_OR_RAISED 0, .cmp_decline_left
.cmp_ne_from_eq_have:
    cmp edx, TAG_PTR
    jne .cmp_ne_negate
    extern notimpl_singleton
    lea r8, [rel notimpl_singleton]
    cmp rax, r8
    jne .cmp_ne_negate
    push rcx
    mov rdi, rax
    call obj_decref
    pop rcx
    jmp .cmp_decline_left
.cmp_ne_negate:

    ; Negate __eq__ result: if True → False, if False → True
    ; Check for TAG_PTR bool (bool_true/bool_false singletons)
    cmp edx, TAG_PTR
    jne .cmp_do_call_result     ; non-bool result, just use as-is
    extern bool_true
    extern bool_false
    lea rcx, [rel bool_true]
    cmp rax, rcx
    je .ne_return_false
    lea rcx, [rel bool_false]
    cmp rax, rcx
    je .ne_return_true
    jmp .cmp_do_call_result     ; not a bool ptr → use as-is
.ne_negate_tag_bool:
    xor eax, 1                  ; flip 0↔1 for TAG_BOOL
    jmp .cmp_do_call_result
.ne_return_false:
    lea rax, [rel bool_false]
    jmp .cmp_do_call_result
.ne_return_true:
    lea rax, [rel bool_true]
    jmp .cmp_do_call_result

.cmp_use_float:
    extern float_compare
    ; float_compare(left, right, op, left_tag, right_tag)
    mov edx, ecx               ; edx = comparison op
    mov ecx, [rsp + BO_LTAG]   ; ecx = left_tag
    mov r8d, [rsp + BO_RTAG]   ; r8d = right_tag
    push rdx                   ; save comparison op (like .cmp_do_call does)
    V_PACK rdi, rcx             ; left  -> Value
    V_PACK rsi, r8              ; right -> Value
    call float_compare
    V_UNPACK rax, rdx           ; float_compare returns a Value
    ; Check for NotImplemented (NULL return = tag 0)
    test edx, edx
    jnz .cmp_float_have
    CMP_DECLINED_OR_RAISED 8, .cmp_try_right
.cmp_float_have:
    add rsp, 8                 ; discard saved comparison op
    jmp .cmp_do_call_result

.cmp_do_call:

    ; Call tp_richcompare(left, right, op, left_tag, right_tag)
    ; rdi = left, rsi = right (already set)
    mov edx, ecx               ; edx = comparison op
    mov rcx, [rsp + BO_LTAG]   ; rcx = left_tag
    mov r8, [rsp + BO_RTAG]    ; r8 = right_tag
    push rdx                   ; save comparison op before call
    V_PACK rdi, rcx             ; left  -> Value
    V_PACK rsi, r8              ; right -> Value
    ; A handler is entered ALIGNED, and BO_SIZE is a multiple of 16, so the
    ; lone push above leaves this call eight out -- and tp_richcompare for an
    ; int is int_compare, which reaches GMP.  451 of the 1,609 misaligned GMP
    ; calls in the tree came through here.  The pad is inside the call rather
    ; than around the push, so every `[rsp + 8 + BO_*]` below stays right.
    sub rsp, 8
    call rax
    add rsp, 8
    V_UNPACK rax, rdx           ; tp_richcompare returns a Value
    ; rax = result payload, edx = result tag
    ; Check for NotImplemented (NULL return = tag 0)
    test edx, edx
    jnz .cmp_slot_have
    CMP_DECLINED_OR_RAISED 8, .cmp_try_right
.cmp_slot_have:
    add rsp, 8                 ; discard saved comparison op

.cmp_do_call_result:
    ; Save result, DECREF operands (tag-aware)
    SAVE_FAT_RESULT            ; save (rax,rdx) result — shifts rsp refs by +16
    mov rdi, [rsp + 16 + BO_RIGHT]
    mov rsi, [rsp + 16 + BO_RTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rsp + 16 + BO_LEFT]
    mov rsi, [rsp + 16 + BO_LTAG]
    DECREF_VAL rdi, rsi
    RESTORE_FAT_RESULT
    add rsp, CO_SIZE           ; discard saved operands + tags

    ; Push result
    VPUSH_VAL rax, rdx

    ; Skip 1 CACHE entry = 2 bytes
    add rbx, 2
    DISPATCH

.cmp_left_declines:
    ; The left operand's type has no comparison at all.  That is a DECLINE,
    ; not an answer: do_richcompare asks the other operand before it falls
    ; back to identity.  Jumping straight to .cmp_identity meant
    ; `None == S()` was False for a class defining __eq__, where CPython
    ; calls S.__eq__.
    ;
    ; .cmp_try_right opens by popping the op that .cmp_do_call pushed before
    ; calling the slot, so this path has to push it too.
    push rcx
    jmp .cmp_try_right

.cmp_try_right:
    ; Left's tp_richcompare returned NotImplemented (NULL).
    ; Try right operand's tp_richcompare with swapped args and swapped op.
    ; Stack: [rsp]=saved_op, [rsp+8+BO_*]=operands
    pop rcx                    ; ecx = original comparison op

    ; Resolve right operand's type
    mov rdi, [rsp + BO_RIGHT] ; right payload (will become left arg)
    mov r8, [rsp + BO_RTAG]   ; right tag
    cmp r8d, TAG_SMALLINT
    je .cmp_right_int
    cmp r8d, TAG_FLOAT
    je .cmp_right_float
    mov rax, [rdi + PyObject.ob_type]
    jmp .cmp_right_have_type
.cmp_right_int:
    lea rax, [rel int_type]
    jmp .cmp_right_have_type
.cmp_right_float:
    lea rax, [rel float_type]
    jmp .cmp_right_have_type
.cmp_right_bool:
    extern bool_type
    lea rax, [rel bool_type]
    jmp .cmp_right_have_type
.cmp_right_none:
    extern none_type
    lea rax, [rel none_type]
.cmp_right_have_type:
    mov r9, rax                ; r9 = right type
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jnz .cmp_right_do_call

    ; No tp_richcompare — try dunder on heaptype (right side)
    mov rdx, [r9 + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .cmp_identity           ; not a heaptype, no dunder → identity

    ; Swap comparison op: LT↔GT, LE↔GE, EQ↔EQ, NE↔NE
    lea rax, [rel .cmp_swap_table]
    movsxd rdx, ecx
    mov edx, [rax + rdx*4]    ; edx = swapped op

    ; Map swapped op to dunder name
    extern cmp_dunder_table
    extern dunder_call_2
    lea rax, [rel cmp_dunder_table]
    movsxd rdx, edx
    mov rdx, [rax + rdx*8]    ; rdx = dunder name C string

    ; dunder_call_2(self=right, other=left, name, other_tag)
    ; rdi = right (already set)
    ;
    ; The op goes on the stack first.  It is in ecx, which is BOTH the
    ; register the other_tag argument goes in and one dunder_call_2 clobbers,
    ; and `.cmp_identity` reads ecx to decide whether the pair is orderable
    ; and to name the operator.  The left-hand path above has always saved it;
    ; this one had not, so every unsupported ordering that got this far
    ; reported itself as '<' -- and whether it raised at all depended on what
    ; dunder_call_2 happened to leave behind.
    push rcx
    sub rsp, 8                     ; a pad: this call is made at an EVEN depth
                                   ; elsewhere in the function, and
                                   ; dunder_call_2 dispatches into Python
    mov rsi, [rsp + 16 + BO_LEFT]  ; other = left payload
    mov ecx, [rsp + 16 + BO_LTAG]  ; other_tag = left's tag
    call dunder_call_2
    V_UNPACK rax, rdx           ; returns a Value
    add rsp, 8
    pop rcx

    ; Check if dunder returned NULL
    test edx, edx
    jnz .cmp_right_dunder_have
    CMP_DECLINED_OR_RAISED 0, .cmp_identity
.cmp_right_dunder_have:

    ; ...and the NotImplemented SINGLETON is a decline too, not a result.
    ; Only NULL was tested here, so a reflected __eq__ that answered
    ; NotImplemented -- which is what object's does for two different
    ; objects, and therefore what every plain class answers -- was pushed
    ; onto the stack as though it were the comparison's value.  `1 == p` and
    ; `c.m == c` both printed NotImplemented instead of False.  The left-hand
    ; path has always tested for it; this one had not.
    cmp edx, TAG_PTR
    jne .cmp_do_call_result
    lea r8, [rel notimpl_singleton]
    cmp rax, r8
    jne .cmp_do_call_result
    push rcx
    mov rdi, rax
    call obj_decref
    pop rcx
    jmp .cmp_identity

.cmp_right_do_call:
    ; Swap comparison op: LT↔GT, LE↔GE, EQ↔EQ, NE↔NE
    ; Save original op for potential identity fallback
    push rcx                   ; [rsp] = original comparison op
    lea r9, [rel .cmp_swap_table]
    movsxd rcx, ecx
    mov ecx, [r9 + rcx*4]     ; ecx = swapped op

    ; Call tp_richcompare(right, left, swapped_op, right_tag, left_tag)
    ; rdi = right (already set above)
    mov rsi, [rsp + 8 + BO_LEFT]  ; rsi = left (becomes right arg) (+8 for push)
    mov edx, ecx               ; swapped op
    mov rcx, [rsp + 8 + BO_RTAG]  ; right_tag (now left_tag arg)
    mov r8, [rsp + 8 + BO_LTAG]   ; left_tag (now right_tag arg)
    V_PACK rdi, rcx             ; left  -> Value
    V_PACK rsi, r8              ; right -> Value
    call rax
    V_UNPACK rax, rdx           ; tp_richcompare returns a Value
    ; Check for NotImplemented again
    test edx, edx
    jnz .cmp_try_right_ok
    CMP_DECLINED_OR_RAISED 8, .cmp_right_both_decline
.cmp_right_both_decline:
    ; Both sides returned NotImplemented → identity fallback
    pop rcx                    ; restore original comparison op (ecx) for .cmp_identity
    jmp .cmp_identity
.cmp_try_right_ok:
    add rsp, 8                 ; discard saved original op
    jmp .cmp_do_call_result    ; got a result, proceed normally

section .data
align 4
.cmp_swap_table:
    dd 4                       ; PY_LT(0) → PY_GT(4)
    dd 5                       ; PY_LE(1) → PY_GE(5)
    dd 2                       ; PY_EQ(2) → PY_EQ(2)
    dd 3                       ; PY_NE(3) → PY_NE(3)
    dd 0                       ; PY_GT(4) → PY_LT(0)
    dd 1                       ; PY_GE(5) → PY_LE(1)
section .text

.cmp_identity:
    ; Fallback: identity comparison (pointer equality)
    ; For ordering ops (LT, LE, GT, GE) with non-identical objects, raise TypeError
    ; For EQ/NE, use identity comparison
    cmp ecx, PY_EQ
    je .cmp_id_eq_ne
    cmp ecx, PY_NE
    je .cmp_id_eq_ne

    ; Ordering comparison with unsupported types → raise TypeError.
    ;
    ; The operands are deliberately NOT DECREFed here.  eval_exception_unwind
    ; releases the frame's value stack, and it unwinds from above the slots
    ; these operands were VPOPped out of -- so DECREFing them first freed them
    ; and the unwinder then decremented the refcount field of memory malloc had
    ; already put on its tcache free list, overwriting the list's forward
    ; pointer.  The symptom was "malloc(): unaligned tcache chunk detected" in
    ; whatever allocated next, arbitrarily far away: `object() < object()`,
    ; `range(1) < range(2)` and `int < str` all corrupted the heap.
    ; op_binary_op's .binop_no_method has always left this to the unwinder too.
    ; "'<' not supported between instances of 'int' and 'str'", which is how
    ; CPython words it.  The operands have to be read BEFORE the frame goes,
    ; and they are payloads, so each becomes a Value of the same type.
    mov r10d, ecx
    cmp r10d, 6
    jb .cmp_have_op
    xor r10d, r10d
.cmp_have_op:
    lea rax, [rel compare_op_symbols]
    mov r10, [rax + r10*8]
    mov rdi, [rsp + BO_LEFT]
    mov rdx, [rsp + BO_LTAG]
    VALUE_FOR_TYPE rdi, rdx
    mov rsi, [rsp + BO_RIGHT]
    mov rdx, [rsp + BO_RTAG]
    VALUE_FOR_TYPE rsi, rdx
    add rsp, CO_SIZE
    sub rsp, 64
    mov [rsp + 48], rdi
    mov [rsp + 56], rsi
    mov rdi, rsp
    lea rsi, [rel cmp_msg_quote]
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, r10
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel cmp_msg_tail]
    call rbt_append_cstr
    mov rdi, [rsp + 48]
    mov rsi, [rsp + 56]
    mov rdx, rsp
    lea rcx, [rel cmp_msg_open]
    extern raise_binop_type_error_ex
    call raise_binop_type_error_ex
    ud2
    DISPATCH

.cmp_id_eq_ne:
    mov rsi, [rsp + BO_RIGHT]
    mov rdi, [rsp + BO_LEFT]
    cmp rdi, rsi
    jne .cmp_id_not_equal
    ; Payloads match — also check tags (None payload=0 vs SmallInt 0)
    mov rdi, [rsp + BO_LTAG]
    cmp rdi, [rsp + BO_RTAG]
    je .cmp_id_equal
.cmp_id_not_equal:
    ; Not equal
    cmp ecx, PY_NE
    je .cmp_id_true
    jmp .cmp_id_false
.cmp_id_equal:
    cmp ecx, PY_EQ
    je .cmp_id_true
.cmp_id_false:
    ; DECREF both operands (tag-aware), push False
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_LTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rsp + BO_RIGHT]
    mov rsi, [rsp + BO_RTAG]
    DECREF_VAL rdi, rsi
    add rsp, CO_SIZE
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    VPUSH_PTR rax
    add rbx, 2
    DISPATCH
.cmp_id_true:
    ; DECREF both operands (tag-aware), push True
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_LTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rsp + BO_RIGHT]
    mov rsi, [rsp + BO_RTAG]
    DECREF_VAL rdi, rsi
    add rsp, CO_SIZE
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    VPUSH_PTR rax
    add rbx, 2
    DISPATCH
END_FUNC op_compare_op

;; ============================================================================
;; op_unary_negative - Negate TOS
;;
;; Calls type's nb_negative from tp_as_number.
;; ============================================================================
DEF_FUNC_BARE op_unary_negative
    VPOP_VAL rdi, r8            ; rdi = operand, r8 = operand tag

    ; TAG_FLOAT fast path: inline sign flip, no DECREF needed
    cmp r8d, TAG_FLOAT
    je .neg_float

    ; Save operand + tag for DECREF after call
    push r8
    push rdi

    ; Get nb_negative: type -> tp_as_number -> nb_negative (SmallInt-aware)
    cmp r8d, TAG_SMALLINT
    je .neg_smallint_type
    cmp r8d, TAG_PTR            ; a float took the fast path above; anything
    jne .neg_type_error         ; else that is not a pointer has no type
    mov rax, [rdi + PyObject.ob_type]
    jmp .neg_have_type
.neg_smallint_type:
    lea rax, [rel int_type]
.neg_have_type:
    ; Neither of these loads was guarded.  A type with no numeric protocol
    ; -- None, str, and every user class, whose tp_as_number is zero -- read
    ; nb_negative from address 0 and called it.
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jz .neg_type_error
    mov rax, [rax + PyNumberMethods.nb_negative]
    test rax, rax
    jz .neg_type_error

    ; Call nb_negative(rdi = operand Value)
    mov rdx, r8                ; tag
    V_PACK rdi, rdx
    call rax                   ; rax = result Value

    ; DECREF old operand (tag-aware)
    push rax                   ; save result Value
    push rax                   ; keep the stack 16-byte aligned
    mov rdi, [rsp + 16]       ; rdi = old operand
    mov rsi, [rsp + 24]       ; rsi = operand tag
    DECREF_VAL rdi, rsi
    add rsp, 8
    pop rax
    add rsp, 16                ; discard saved operand + tag

    ; Push result
    VPUSH rax
    DISPATCH

.neg_float:
    ; Inline float negate: flip sign bit, no refcounting
    btc rdi, 63
    VPUSH_FLOAT rdi, r15
    DISPATCH

.neg_type_error:
    RAISE exc_TypeError_type, "bad operand type for unary -"
END_FUNC op_unary_negative

;; ============================================================================
;; op_unary_invert - Bitwise NOT of TOS (~x)
;;
;; Calls type's nb_invert from tp_as_number.
;; ============================================================================
DEF_FUNC_BARE op_unary_invert
    VPOP_VAL rdi, r8            ; rdi = operand, r8 = operand tag
    push r8
    push rdi

    cmp r8d, TAG_SMALLINT
    je .inv_smallint_type
    cmp r8d, TAG_PTR            ; ~ has no float case at all, so a float's
    jne .inv_type_error         ; raw bits were used as an address
    mov rax, [rdi + PyObject.ob_type]
    jmp .inv_have_type
.inv_smallint_type:
    lea rax, [rel int_type]
.inv_have_type:
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jz .inv_type_error
    mov rax, [rax + PyNumberMethods.nb_invert]
    test rax, rax
    jz .inv_type_error

    ; Call nb_invert(rdi = operand Value)
    mov rdx, r8                ; tag
    V_PACK rdi, rdx
    xor esi, esi
    call rax                   ; rax = result Value
    push rax
    push rax                   ; alignment
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]       ; tag
    DECREF_VAL rdi, rsi
    add rsp, 8
    pop rax
    add rsp, 16
    VPUSH rax
    DISPATCH

.inv_type_error:
    RAISE exc_TypeError_type, "bad operand type for unary ~"
END_FUNC op_unary_invert

;; ============================================================================
;; op_unary_not - Logical NOT of TOS
;;
;; Calls obj_is_true, then pushes the inverted boolean.
;; ============================================================================
DEF_FUNC_BARE op_unary_not
    VPOP rdi                    ; the Value

    ; The two bool singletons invert with no call.  Both are immortal -- their
    ; refcount starts at 2^63-1 and cannot reach zero -- so releasing the
    ; operand is a bare `dec` with no zero check.  It is a DIFFERENT object
    ; from the one being pushed, so it does need releasing.
    lea rax, [rel bool_true]
    cmp rdi, rax
    je .not_of_true
    lea rax, [rel bool_false]
    cmp rdi, rax
    je .not_of_false

    ; Anything else.  obj_is_true takes a Value, which is what VPOP left in
    ; rdi -- this used to unpack into a (payload, tag) pair and V_PACK it
    ; straight back to make the call.
    ; rsp is 16-byte aligned on entry to a handler -- they are reached by
    ; `jmp`, not `call` -- so a call inside one needs an EVEN number of pushed
    ; slots.  Two, with the answer parked in the operand's slot.
    sub rsp, 8                  ; the second of the two
    push rdi                    ; the operand, for the release below
    call obj_is_true
    mov rdi, [rsp]
    mov [rsp], rax              ; park the answer where it was
    DECREF_V rdi, rsi
    pop rax
    add rsp, 8

    ; NOT inverts: truthy pushes False, falsy pushes True.  The explicit jump
    ; is load-bearing -- the two bool arms below release their operand, and
    ; falling into one of them from here would `dec` through the truthiness
    ; result, which for a falsy value is 0.
    test eax, eax
    jnz .push_false
    jmp .push_true
.not_of_false:
    dec qword [rax + PyObject.ob_refcnt]    ; rax is the operand, bool_false
.push_true:
    lea rax, [rel bool_true]
    jmp .push_bool
.not_of_true:
    dec qword [rax + PyObject.ob_refcnt]    ; rax is the operand, bool_true
.push_false:
    lea rax, [rel bool_false]
.push_bool:
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
END_FUNC op_unary_not
section .data

;; Maps NB_* argument (0-25) to the byte offset within PyNumberMethods
;; where the corresponding method function pointer resides.
align 8
; Also read by obj_binary_op (src/object.asm), which is the same protocol made
; callable from a builtin.
global binary_op_offsets
binary_op_offsets:
    ; Symbolic, not literal: these are byte offsets into PyNumberMethods, and
    ; a reorder of that struc used to mis-dispatch every binary operator in
    ; silence.  NB_MATRIX_MULTIPLY was a literal 0 -- nb_add -- so 3 @ 4
    ; returned 7.
    dq PyNumberMethods.nb_add            ; NB_ADD (0)
    dq PyNumberMethods.nb_and            ; NB_AND (1)
    dq PyNumberMethods.nb_floor_divide   ; NB_FLOOR_DIVIDE (2)
    dq PyNumberMethods.nb_lshift         ; NB_LSHIFT (3)
    dq PyNumberMethods.nb_matmul         ; NB_MATRIX_MULTIPLY (4)
    dq PyNumberMethods.nb_multiply       ; NB_MULTIPLY (5)
    dq PyNumberMethods.nb_remainder      ; NB_REMAINDER (6)
    dq PyNumberMethods.nb_or             ; NB_OR (7)
    dq PyNumberMethods.nb_power          ; NB_POWER (8)
    dq PyNumberMethods.nb_rshift         ; NB_RSHIFT (9)
    dq PyNumberMethods.nb_subtract       ; NB_SUBTRACT (10)
    dq PyNumberMethods.nb_true_divide    ; NB_TRUE_DIVIDE (11)
    dq PyNumberMethods.nb_xor            ; NB_XOR (12)
    dq PyNumberMethods.nb_iadd           ; NB_INPLACE_ADD (13)
    dq PyNumberMethods.nb_iand           ; NB_INPLACE_AND (14)
    dq PyNumberMethods.nb_ifloor_divide  ; NB_INPLACE_FLOOR_DIVIDE (15)
    dq PyNumberMethods.nb_ilshift        ; NB_INPLACE_LSHIFT (16)
    dq PyNumberMethods.nb_imatmul        ; NB_INPLACE_MATRIX_MULTIPLY (17)
    dq PyNumberMethods.nb_imul           ; NB_INPLACE_MULTIPLY (18)
    dq PyNumberMethods.nb_irem           ; NB_INPLACE_REMAINDER (19)
    dq PyNumberMethods.nb_ior            ; NB_INPLACE_OR (20)
    dq PyNumberMethods.nb_ipow           ; NB_INPLACE_POWER (21)
    dq PyNumberMethods.nb_irshift        ; NB_INPLACE_RSHIFT (22)
    dq PyNumberMethods.nb_isub           ; NB_INPLACE_SUBTRACT (23)
    dq PyNumberMethods.nb_itrue_divide   ; NB_INPLACE_TRUE_DIVIDE (24)
    dq PyNumberMethods.nb_ixor           ; NB_INPLACE_XOR (25)

; The same 26 rows again, as the operator writes.  CPython's TypeError names
; the operator -- "unsupported operand type(s) for +: 'int' and 'str'" -- and
; ours was the bare prefix, because nothing anywhere mapped an op index to its
; symbol.
; The six comparison operators, indexed by PY_LT..PY_GE.
global compare_op_symbols
compare_op_symbols:
    dq cops_lt, cops_le, cops_eq, cops_ne, cops_gt, cops_ge

global binary_op_symbols
binary_op_symbols:
    dq bops_add, bops_and, bops_floordiv, bops_lshift, bops_matmul
    dq bops_mul, bops_mod, bops_or, bops_pow, bops_rshift
    dq bops_sub, bops_truediv, bops_xor
    dq bops_iadd, bops_iand, bops_ifloordiv, bops_ilshift, bops_imatmul
    dq bops_imul, bops_imod, bops_ior, bops_ipow, bops_irshift
    dq bops_isub, bops_itruediv, bops_ixor

section .rodata
cops_lt:        db "<", 0
cops_le:        db "<=", 0
cops_eq:        db "==", 0
cops_ne:        db "!=", 0
cops_gt:        db ">", 0
cops_ge:        db ">=", 0
bops_add:       db "+", 0
bops_and:       db "&", 0
bops_floordiv:  db "//", 0
bops_lshift:    db "<<", 0
bops_matmul:    db "@", 0
bops_mul:       db "*", 0
bops_mod:       db "%", 0
bops_or:        db "|", 0
bops_pow:       db "** or pow()", 0
bops_rshift:    db ">>", 0
bops_sub:       db "-", 0
bops_truediv:   db "/", 0
bops_xor:       db "^", 0
bops_iadd:      db "+=", 0
bops_iand:      db "&=", 0
bops_ifloordiv: db "//=", 0
bops_ilshift:   db "<<=", 0
bops_imatmul:   db "@=", 0
bops_imul:      db "*=", 0
bops_imod:      db "%=", 0
bops_ior:       db "|=", 0
bops_ipow:      db "**=", 0
bops_irshift:   db ">>=", 0
bops_isub:      db "-=", 0
bops_itruediv:  db "/=", 0
bops_ixor:      db "^=", 0
bops_unknown:   db "?", 0
cmp_msg_quote:  db "'", 0
cmp_msg_tail:   db "' not supported between instances", 0
global binop_msg_prefix
binop_msg_prefix: db "unsupported operand type(s) for ", 0
global cmp_msg_open
cmp_msg_open:     db " of '", 0
section .data

section .text
