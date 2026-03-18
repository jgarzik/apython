; opcodes_misc.asm - Opcode handlers for return, binary/unary ops, comparisons,
;                    conditional jumps, and unconditional jumps
;
; Register convention (callee-saved, preserved across handlers):
;   rbx = bytecode instruction pointer (current position in co_code[])
;   r12 = current frame pointer (PyFrame*)
;   r13 = value stack payload top pointer
;   r14 = locals_tag_base pointer (frame's tag sidecar for localsplus[])
;   r15 = value stack tag top pointer
;
; ecx = opcode argument on entry (set by eval_dispatch)
; rbx has already been advanced past the 2-byte instruction word.

%include "macros.inc"
%include "object.inc"
%include "types.inc"
%include "opcodes.inc"
%include "frame.inc"

section .text

extern eval_dispatch
extern eval_saved_rbx
extern eval_saved_r13
extern eval_saved_r15
extern eval_co_names
extern eval_co_consts
extern eval_co_consts_tags
extern opcode_table
extern eval_return
extern obj_dealloc
extern obj_is_true
extern fatal_error
extern none_singleton
extern bool_true
extern bool_false
extern int_type
extern float_type
extern float_number_methods
extern cell_new
extern gen_new
extern coro_new
extern async_gen_new
extern raise_exception
extern exc_RuntimeError_type
extern exc_StopIteration_type
extern exc_TypeError_type
extern exc_ZeroDivisionError_type
extern current_exception
extern eval_exception_unwind
extern obj_incref
extern obj_decref
extern prep_reraise_star
extern tuple_new
extern list_type

;; Stack layout constants for binary_op / compare_op generic paths.
;; After 4 pushes: right, right_tag, left, left_tag
;; Offsets relative to rsp immediately after the 4 pushes.
BO_RIGHT equ 0
BO_RTAG  equ 8
BO_LEFT  equ 16
BO_LTAG  equ 24
BO_SIZE  equ 32

;; Stack layout constants for op_format_value (DEF_FUNC, 48 bytes).
FV_ARG     equ 8
FV_HASSPEC equ 16
FV_SPEC    equ 24
FV_VALUE   equ 32
FV_STAG    equ 40    ; fmt_spec tag
FV_VTAG    equ 48    ; value tag
FV_FRAME   equ 48

;; Stack layout constants for op_build_string (DEF_FUNC, 16 bytes).
BS_COUNT   equ 8
BS_ACCUM   equ 16
BS_FRAME   equ 16

;; Stack layout constants for op_send (DEF_FUNC, 48 bytes).
SND_ARG    equ 8
SND_SENT   equ 16
SND_RECV   equ 24
SND_RESULT equ 32
SND_STAG   equ 40    ; sent_value tag
SND_RTAG   equ 48    ; result tag
SND_FRAME  equ 48

;; Stack layout constants for op_match_keys (DEF_FUNC, 32 bytes).
MK_KEYS    equ 8
MK_SUBJ    equ 16
MK_VALS    equ 24
MK_NKEYS   equ 32
MK_FRAME   equ 32

;; ============================================================================
;; op_return_value - Return TOS from current frame
;;
;; Phase 4 (simple case): module-level code, no previous frame.
;; Pop return value and jump to eval_return.
;; ============================================================================
DEF_FUNC_BARE op_return_value
    VPOP_VAL rax, rdx            ; rax = return value (payload), rdx = tag
    mov qword [r12 + PyFrame.instr_ptr], 0  ; mark frame as "returned" (not yielded)
    jmp eval_return
END_FUNC op_return_value

;; ============================================================================
;; op_return_const - Return co_consts[arg] without popping the stack
;;
;; Load constant, INCREF, and jump to eval_return.
;; ============================================================================
DEF_FUNC_BARE op_return_const
    ; ecx = arg (index into co_consts)
    mov rax, [rel eval_co_consts]
    mov rax, [rax + rcx * 8]   ; payload
    mov rdx, [rel eval_co_consts_tags]
    movzx edx, byte [rdx + rcx] ; tag
    INCREF_VAL rax, rdx
    mov qword [r12 + PyFrame.instr_ptr], 0  ; mark frame as "returned" (not yielded)
    jmp eval_return
END_FUNC op_return_const

;; ============================================================================
;; op_binary_op - Perform a binary operation
;;
;; ecx = NB_* argument (operation selector)
;; Pops right (b) then left (a), dispatches through type's tp_as_number.
;; Followed by 1 CACHE entry (2 bytes) that must be skipped.
;; ============================================================================
DEF_FUNC_BARE op_binary_op
    ; ecx = NB_* op code
    ; Save the op index before pops (VPOP doesn't clobber ecx)
    VPOP_VAL rsi, r8            ; rsi = right operand (b), r8 = right tag
    VPOP_VAL rdi, r9            ; rdi = left operand (a), r9 = left tag

    ; Treat TAG_BOOL as smallint for numeric ops (bool is int subclass)
    cmp r9d, TAG_BOOL
    jne .binop_left_ok
    mov r9d, TAG_SMALLINT
.binop_left_ok:
    cmp r8d, TAG_BOOL
    jne .binop_right_ok
    mov r8d, TAG_SMALLINT
.binop_right_ok:

    ; Fast path: SmallInt add (NB_ADD=0, NB_INPLACE_ADD=13)
    cmp ecx, 0                 ; NB_ADD
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

.binop_generic:
    ; Save operands + tags for DECREF after call (push on machine stack)
    ; Stack layout: [rsp+BO_RIGHT], [rsp+BO_RTAG], [rsp+BO_LEFT], [rsp+BO_LTAG]
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

    ; Float coercion: if either operand is TAG_FLOAT, use float methods
    ; This handles int+float, float+int, float+float
    ; Skip for NB_REMAINDER (6) / NB_INPLACE_REMAINDER (19) when left is not float,
    ; because str % value should use str_mod, not float methods.
    cmp qword [rsp + BO_LTAG], TAG_FLOAT
    je .use_float_methods
    cmp qword [rsp + BO_RTAG], TAG_FLOAT
    jne .no_float_coerce
    ; Right is float — check if this is remainder op (str % float should NOT coerce)
    cmp r9d, 6                  ; NB_REMAINDER
    je .no_float_coerce
    cmp r9d, 19                 ; NB_INPLACE_REMAINDER
    je .no_float_coerce
    jmp .use_float_methods

.no_float_coerce:
    ; For NB_ADD (0/13) and NB_MULTIPLY (5/18): if left is int/SmallInt
    ; and right has sq_concat/sq_repeat, use sequence method instead.
    ; This handles: 3 * "ab", 3 * [1,2], etc.
    cmp qword [rsp + BO_LTAG], TAG_SMALLINT
    jne .binop_not_smallint_left
    ; Left is SmallInt — check if right has sequence methods
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
    mov edx, [rsp + BO_LTAG]    ; count tag (left operand)
    mov ecx, edx                 ; also in ecx (nb_multiply convention)
    call rax
    jmp .binop_have_result

.binop_not_smallint_left:
    ; TAG_BOOL: route to int (int_unwrap handles TAG_BOOL)
    cmp qword [rsp + BO_LTAG], TAG_BOOL
    je .binop_smallint_type
    ; Non-pointer guard: TAG_NONE, TAG_FLOAT can't be dereferenced
    test qword [rsp + BO_LTAG], TAG_RC_BIT
    jz .binop_no_method
    ; Check if left has sq_repeat and right is int (e.g. tuple*3, list*3)
    ; Only for NB_MULTIPLY, not INPLACE (imul uses nb_imul/sq_inplace_repeat)
    cmp r9d, 5              ; NB_MULTIPLY
    je .binop_try_left_seq
    jmp .binop_left_seq_done
.binop_try_left_seq:
    cmp qword [rsp + BO_RTAG], TAG_SMALLINT
    jne .binop_left_seq_done
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .binop_left_seq_done
    mov rax, [rax + PySequenceMethods.sq_repeat]
    test rax, rax
    jz .binop_left_seq_done
    ; Call sq_repeat(left=sequence, right=count)
    ; rdi already = left (sequence), rsi already = right (count)
    mov edx, [rsp + BO_RTAG]    ; count tag (right operand)
    mov ecx, edx
    call rax
    jmp .binop_have_result
.binop_left_seq_done:
    mov rax, [rdi + PyObject.ob_type]
    jmp .binop_have_type
.binop_left_type:
    ; Get type's tp_as_number method table from left operand
    ; SmallInt check: use saved left tag
    cmp qword [rsp + BO_LTAG], TAG_SMALLINT
    je .binop_smallint_type
    ; TAG_BOOL: route to int (int_unwrap handles TAG_BOOL)
    cmp qword [rsp + BO_LTAG], TAG_BOOL
    je .binop_smallint_type
    ; Non-pointer guard: TAG_NONE, TAG_FLOAT can't be dereferenced
    test qword [rsp + BO_LTAG], TAG_RC_BIT
    jz .binop_no_method
    mov rax, [rdi + PyObject.ob_type]
    jmp .binop_have_type
.binop_smallint_type:
    lea rax, [rel int_type]
    jmp .binop_have_type
.binop_have_type:
    push rax                   ; save type ptr for sq fallback
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jnz .binop_have_number
    pop rax                    ; restore type ptr
    jmp .binop_try_seq_fallback
.binop_have_number:
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
    jl .binop_try_dunder        ; not inplace, no fallback
    ; Map inplace op to non-inplace offset
    mov ecx, r9d
    sub ecx, 13                 ; inplace → base op
    lea rdx, [rel binary_op_offsets]
    mov rdx, [rdx + rcx*8]     ; non-inplace offset
    ; Float coercion: if either operand is float, use float_number_methods
    ; (mirrors the initial float coercion at .use_float_methods)
    cmp qword [rsp + BO_LTAG], TAG_FLOAT
    je .binop_fallback_float
    cmp qword [rsp + BO_RTAG], TAG_FLOAT
    je .binop_fallback_float
    ; Reload type's tp_as_number
    cmp qword [rsp + BO_LTAG], TAG_SMALLINT
    je .binop_fallback_int
    cmp qword [rsp + BO_LTAG], TAG_BOOL
    je .binop_fallback_int
    test qword [rsp + BO_LTAG], TAG_RC_BIT
    jz .binop_try_dunder
    mov rax, [rdi + PyObject.ob_type]
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
    test rax, rax
    jz .binop_try_dunder
    mov rax, [rax + rdx]
    test rax, rax
    jz .binop_try_dunder

.binop_have_method:

    ; Guard: if left is SmallInt/Bool and right is a heaptype (not int subclass),
    ; the int nb_* methods can't handle it. Skip to dunder dispatch.
    cmp qword [rsp + BO_LTAG], TAG_SMALLINT
    je .binop_guard_int_left
    cmp qword [rsp + BO_LTAG], TAG_BOOL
    je .binop_guard_int_left
    jmp .binop_compat_ok

.binop_guard_int_left:
    ; Left is int/bool. Check if right is an incompatible heaptype.
    test qword [rsp + BO_RTAG], TAG_RC_BIT
    jz .binop_compat_ok          ; right not a heap pointer → compatible
    ; Right is a heap pointer (TAG_PTR)
    push rax                     ; save method ptr
    mov r10, [rsp + 8 + BO_RIGHT]
    mov r10, [r10 + PyObject.ob_type]
    test qword [r10 + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .binop_guard_ok           ; not heaptype → could be GMP int, proceed
    test qword [r10 + PyTypeObject.tp_flags], TYPE_FLAG_INT_SUBCLASS
    jnz .binop_guard_ok          ; int subclass → int methods handle it
    ; Heaptype non-int-subclass → skip to dunders
    pop rax
    jmp .binop_try_dunder
.binop_guard_ok:
    pop rax

.binop_compat_ok:

.binop_do_call:
    ; Call the method: rdi=left, rsi=right, rdx=left_tag, rcx=right_tag
    mov rdx, [rsp + BO_LTAG]
    mov rcx, [rsp + BO_RTAG]
    call rax

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
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .binop_try_dunder
    ; NB_ADD (0) or NB_INPLACE_ADD (13) → sq_concat / sq_inplace_concat
    cmp r9d, 0              ; NB_ADD
    je .binop_seq_concat
    cmp r9d, 13             ; NB_INPLACE_ADD
    je .binop_seq_concat
    ; NB_MULTIPLY (5) or NB_INPLACE_MULTIPLY (18) → sq_repeat
    cmp r9d, 5
    je .binop_seq_repeat_left
    cmp r9d, 18             ; NB_INPLACE_MULTIPLY
    je .binop_seq_repeat_left
    jmp .binop_try_dunder

.binop_seq_concat:
    mov rax, [rax + PySequenceMethods.sq_concat]
    test rax, rax
    jz .binop_try_dunder
    ; sq_concat(left, right): rdi=left, rsi=right already set
    call rax
    jmp .binop_have_result

.binop_seq_repeat_left:
    mov rax, [rax + PySequenceMethods.sq_repeat]
    test rax, rax
    jz .binop_try_dunder
    ; sq_repeat(left=sequence, right=count)
    mov edx, [rsp + BO_RTAG]
    mov ecx, edx
    call rax
    jmp .binop_have_result

.binop_try_dunder:
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
    pop r9
    test edx, edx
    jz .binop_left_dunder      ; not found → fall back to regular dunder
    test edx, TAG_RC_BIT
    jz .binop_no_method        ; found None → blocks fallback (TypeError)

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
    pop r9
    test edx, edx
    jnz .binop_have_result
    ; Inplace dunder call returned NULL unexpectedly — fall through to regular

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
    pop r9
    test edx, edx
    jnz .binop_have_result

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
    test edx, edx
    jnz .binop_have_result

.binop_no_method:
    ; No method found — raise TypeError
    extern raise_exception
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "unsupported operand type(s)"
    call raise_exception

.binop_try_smallint_add:
    ; Check both TAG_SMALLINT
    cmp r9d, TAG_SMALLINT
    jne .binop_try_float_add
    cmp r8d, TAG_SMALLINT
    jne .binop_generic

    ; Both SmallInt: decode, add, check overflow
    mov rax, rdi
    mov rdx, rsi
    add rax, rdx
    jo .binop_generic          ; overflow → fall back to generic
    ; Specialize: rewrite opcode to BINARY_OP_ADD_INT (211)
    mov byte [rbx - 2], 211
    VPUSH_INT rax
    add rbx, 2
    DISPATCH

.binop_try_float_add:
    cmp r9d, TAG_FLOAT
    jne .binop_generic
    cmp r8d, TAG_FLOAT
    jne .binop_generic
    ; Both float: inline add
    mov byte [rbx - 2], 217   ; BINARY_OP_ADD_FLOAT
    movq xmm0, rdi
    movq xmm1, rsi
    addsd xmm0, xmm1
    movq rax, xmm0
    VPUSH_FLOAT rax
    add rbx, 2
    DISPATCH

.binop_try_smallint_sub:
    ; Check both TAG_SMALLINT
    cmp r9d, TAG_SMALLINT
    jne .binop_try_float_sub
    cmp r8d, TAG_SMALLINT
    jne .binop_generic

    ; Both SmallInt: decode, subtract, check overflow
    mov rax, rdi
    mov rdx, rsi
    sub rax, rdx
    jo .binop_generic          ; overflow → fall back to generic
    ; Specialize: rewrite opcode to BINARY_OP_SUBTRACT_INT (212)
    mov byte [rbx - 2], 212
    VPUSH_INT rax
    add rbx, 2
    DISPATCH

.binop_try_float_sub:
    cmp r9d, TAG_FLOAT
    jne .binop_generic
    cmp r8d, TAG_FLOAT
    jne .binop_generic
    ; Both float: inline sub
    mov byte [rbx - 2], 218   ; BINARY_OP_SUB_FLOAT
    movq xmm0, rdi
    movq xmm1, rsi
    subsd xmm0, xmm1
    movq rax, xmm0
    VPUSH_FLOAT rax
    add rbx, 2
    DISPATCH

.binop_try_smallint_mul:
    ; Check both TAG_SMALLINT
    cmp r9d, TAG_SMALLINT
    jne .binop_try_float_mul
    cmp r8d, TAG_SMALLINT
    jne .binop_generic

    ; Both SmallInt: multiply, check overflow
    mov rax, rdi
    imul rsi
    jo .binop_generic          ; overflow → fall back to generic
    ; Specialize: rewrite opcode to BINARY_OP_MULTIPLY_INT (221)
    mov byte [rbx - 2], 221
    VPUSH_INT rax
    add rbx, 2
    DISPATCH

.binop_try_float_mul:
    cmp r9d, TAG_FLOAT
    jne .binop_generic
    cmp r8d, TAG_FLOAT
    jne .binop_generic
    ; Both float: inline mul
    mov byte [rbx - 2], 219   ; BINARY_OP_MUL_FLOAT
    movq xmm0, rdi
    movq xmm1, rsi
    mulsd xmm0, xmm1
    movq rax, xmm0
    VPUSH_FLOAT rax
    add rbx, 2
    DISPATCH

.binop_try_float_truediv:
    cmp r9d, TAG_FLOAT
    jne .binop_generic
    cmp r8d, TAG_FLOAT
    jne .binop_generic
    ; Both float: check for division by zero
    movq xmm1, rsi
    xorpd xmm2, xmm2
    ucomisd xmm1, xmm2
    je .binop_generic          ; zero divisor → generic path raises ZeroDivisionError
    ; Inline truediv
    mov byte [rbx - 2], 220   ; BINARY_OP_TRUEDIV_FLOAT
    movq xmm0, rdi
    divsd xmm0, xmm1
    movq rax, xmm0
    VPUSH_FLOAT rax
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
    VPUSH_INT rax
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
    ; Both SmallInt: decode and compare
    mov rax, rdi
    mov rdx, rsi
    cmp rax, rdx               ; flags survive LEA + jmp [mem]
    lea r8, [rel .cmp_setcc_table]
    jmp [r8 + rcx*8]          ; 1 indirect branch on comparison op

.cmp_set_lt:
    setl al
    jmp .cmp_push_bool
.cmp_set_le:
    setle al
    jmp .cmp_push_bool
.cmp_set_eq:
    sete al
    jmp .cmp_push_bool
.cmp_set_ne:
    setne al
    jmp .cmp_push_bool
.cmp_set_gt:
    setg al
    jmp .cmp_push_bool
.cmp_set_ge:
    setge al
    ; fall through to .cmp_push_bool

.cmp_push_bool:
    movzx eax, al             ; eax = 0 or 1
    VPUSH_BOOL rax             ; (0/1, TAG_BOOL) — no INCREF needed
    add rbx, 2
    DISPATCH

section .data
align 8
.cmp_setcc_table:
    dq .cmp_set_lt             ; PY_LT = 0
    dq .cmp_set_le             ; PY_LE = 1
    dq .cmp_set_eq             ; PY_EQ = 2
    dq .cmp_set_ne             ; PY_NE = 3
    dq .cmp_set_gt             ; PY_GT = 4
    dq .cmp_set_ge             ; PY_GE = 5
section .text

.cmp_slow_path:
    ; Save operands + tags and comparison op
    ; Stack layout: [rsp+BO_RIGHT], [rsp+BO_RTAG], [rsp+BO_LEFT], [rsp+BO_LTAG]
    push r9                    ; save left tag
    push rdi                   ; save left
    push r8                    ; save right tag
    push rsi                   ; save right

    ; Float coercion: if either operand is TAG_FLOAT, use float_compare
    cmp r9d, TAG_FLOAT
    je .cmp_use_float
    cmp r8d, TAG_FLOAT
    je .cmp_use_float

.cmp_no_float:
    ; Get type's tp_richcompare
    cmp r9d, TAG_SMALLINT
    je .cmp_smallint_type
    cmp r9d, TAG_BOOL
    je .cmp_bool_type
    cmp r9d, TAG_NONE
    je .cmp_none_type
    mov rax, [rdi + PyObject.ob_type]
    jmp .cmp_have_type
.cmp_smallint_type:
    lea rax, [rel int_type]
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
    jz .cmp_identity

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
    pop rcx

    test edx, edx
    jz .cmp_identity            ; dunder not found → identity fallback
    jmp .cmp_do_call_result     ; rax = result object

.cmp_use_float:
    extern float_compare
    ; float_compare(left, right, op, left_tag, right_tag)
    mov edx, ecx               ; edx = comparison op
    mov ecx, [rsp + BO_LTAG]   ; ecx = left_tag
    mov r8d, [rsp + BO_RTAG]   ; r8d = right_tag
    push rdx                   ; save comparison op (like .cmp_do_call does)
    call float_compare
    ; Check for NotImplemented (NULL return = tag 0)
    test edx, edx
    jz .cmp_try_right          ; try right operand's tp_richcompare
    add rsp, 8                 ; discard saved comparison op
    jmp .cmp_do_call_result

.cmp_do_call:

    ; Call tp_richcompare(left, right, op, left_tag, right_tag)
    ; rdi = left, rsi = right (already set)
    mov edx, ecx               ; edx = comparison op
    mov rcx, [rsp + BO_LTAG]   ; rcx = left_tag
    mov r8, [rsp + BO_RTAG]    ; r8 = right_tag
    push rdx                   ; save comparison op before call
    call rax
    ; rax = result payload, edx = result tag
    ; Check for NotImplemented (NULL return = tag 0)
    test edx, edx
    jz .cmp_try_right
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
    add rsp, BO_SIZE           ; discard saved operands + tags

    ; Push result
    VPUSH_VAL rax, rdx

    ; Skip 1 CACHE entry = 2 bytes
    add rbx, 2
    DISPATCH

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
    cmp r8d, TAG_BOOL
    je .cmp_right_bool
    cmp r8d, TAG_NONE
    je .cmp_right_none
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
    mov rsi, [rsp + BO_LEFT]   ; other = left payload
    mov ecx, [rsp + BO_LTAG]   ; other_tag = left's tag
    call dunder_call_2

    ; Check if dunder returned NULL
    test edx, edx
    jz .cmp_identity           ; no dunder → identity fallback
    jmp .cmp_do_call_result

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
    call rax
    ; Check for NotImplemented again
    test edx, edx
    jnz .cmp_try_right_ok
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

    ; Ordering comparison with unsupported types → raise TypeError
    ; DECREF both operands first
    mov rdi, [rsp + BO_LEFT]
    mov rsi, [rsp + BO_LTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rsp + BO_RIGHT]
    mov rsi, [rsp + BO_RTAG]
    DECREF_VAL rdi, rsi
    add rsp, BO_SIZE
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "'<' not supported between instances"
    extern raise_exception
    call raise_exception
    DISPATCH

.cmp_id_eq_ne:
    mov rsi, [rsp + BO_RIGHT]
    mov rdi, [rsp + BO_LEFT]
    cmp rdi, rsi
    je .cmp_id_equal
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
    add rsp, BO_SIZE
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
    add rsp, BO_SIZE
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
    cmp r8d, TAG_BOOL
    je .neg_bool_type
    mov rax, [rdi + PyObject.ob_type]
    jmp .neg_have_type
.neg_bool_type:
    lea rax, [rel bool_type]
    jmp .neg_have_type
.neg_smallint_type:
    lea rax, [rel int_type]
.neg_have_type:
    mov rax, [rax + PyTypeObject.tp_as_number]
    mov rax, [rax + PyNumberMethods.nb_negative]

    ; Call nb_negative(payload, tag); rdi already set
    mov rdx, r8                ; tag
    call rax
    ; rax = result payload, rdx = result tag

    ; DECREF old operand (tag-aware)
    SAVE_FAT_RESULT            ; save (rax,rdx) — shifts rsp refs by +16
    mov rdi, [rsp + 16]       ; rdi = old operand (was [rsp + 8])
    mov rsi, [rsp + 24]       ; rsi = operand tag (was [rsp + 16])
    DECREF_VAL rdi, rsi
    RESTORE_FAT_RESULT
    add rsp, 16                ; discard saved operand + tag

    ; Push result
    VPUSH_VAL rax, rdx
    DISPATCH

.neg_float:
    ; Inline float negate: flip sign bit, no refcounting
    btc rdi, 63
    VPUSH_FLOAT rdi
    DISPATCH
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
    cmp r8d, TAG_BOOL
    je .inv_bool_type
    mov rax, [rdi + PyObject.ob_type]
    jmp .inv_have_type
.inv_bool_type:
    lea rax, [rel bool_type]
    jmp .inv_have_type
.inv_smallint_type:
    lea rax, [rel int_type]
.inv_have_type:
    mov rax, [rax + PyTypeObject.tp_as_number]
    mov rax, [rax + PyNumberMethods.nb_invert]

    ; Call nb_invert(operand, tag) — binary op signature
    mov rdx, r8                ; tag
    xor esi, esi
    call rax
    SAVE_FAT_RESULT
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]       ; tag
    DECREF_VAL rdi, rsi
    RESTORE_FAT_RESULT
    add rsp, 16
    VPUSH_VAL rax, rdx
    DISPATCH
END_FUNC op_unary_invert

;; ============================================================================
;; op_unary_not - Logical NOT of TOS
;;
;; Calls obj_is_true, then pushes the inverted boolean.
;; ============================================================================
DEF_FUNC_BARE op_unary_not
    VPOP_VAL rdi, r8            ; rdi = operand, r8 = operand tag

    ; Save operand + tag for DECREF
    push r8
    push rdi

    ; Call obj_is_true(operand, tag) -> 0 or 1
    mov rsi, r8                ; tag
    call obj_is_true
    push rax                   ; save truthiness result

    ; DECREF operand (tag-aware)
    mov rdi, [rsp + 8]        ; reload operand
    mov rsi, [rsp + 16]       ; tag
    DECREF_VAL rdi, rsi
    pop rax                    ; restore truthiness
    add rsp, 16                ; discard saved operand + tag

    ; NOT inverts: if truthy (1), push False; if falsy (0), push True
    test eax, eax
    jnz .push_false
    lea rax, [rel bool_true]
    jmp .push_bool
.push_false:
    lea rax, [rel bool_false]
.push_bool:
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
END_FUNC op_unary_not

;; ============================================================================
;; op_pop_jump_if_false - Pop TOS, jump if falsy
;;
;; Python 3.12: arg is the absolute target offset in instruction words
;; (2-byte units from start of co_code).
;; ============================================================================
DEF_FUNC_BARE op_pop_jump_if_false
    VPOP_VAL rdi, r8            ; rdi = value to test, r8 = value tag

    ; Fast path: TAG_BOOL — payload is 0/1, no DECREF needed
    cmp r8d, TAG_BOOL
    je .pjif_bool_fast

    ; Slow path: call obj_is_true + DECREF
    push rcx                   ; save target offset
    push r8                    ; save tag for DECREF
    push rdi                   ; save value for DECREF
    mov rsi, r8                ; tag
    call obj_is_true
    push rax                   ; save truthiness
    mov rdi, [rsp + 8]        ; reload value
    mov rsi, [rsp + 16]       ; tag
    DECREF_VAL rdi, rsi
    pop rax                    ; restore truthiness
    add rsp, 16                ; discard saved value + tag
    pop rcx                    ; restore target offset
    test eax, eax
    jnz .no_jump
    lea rbx, [rbx + rcx*2]
.no_jump:
    DISPATCH

.pjif_bool_fast:
    test edi, edi
    jnz .pjif_no_jump          ; truthy → don't jump
    lea rbx, [rbx + rcx*2]    ; jump
.pjif_no_jump:
    DISPATCH
END_FUNC op_pop_jump_if_false

;; ============================================================================
;; op_pop_jump_if_true - Pop TOS, jump if truthy
;; ============================================================================
DEF_FUNC_BARE op_pop_jump_if_true
    VPOP_VAL rdi, r8            ; rdi = value to test, r8 = value tag

    ; Fast path: TAG_BOOL — payload is 0/1, no DECREF needed
    cmp r8d, TAG_BOOL
    je .pjit_bool_fast

    ; Slow path: call obj_is_true + DECREF
    push rcx                   ; save target offset
    push r8                    ; save tag for DECREF
    push rdi                   ; save value for DECREF
    mov rsi, r8                ; tag
    call obj_is_true
    push rax                   ; save truthiness
    mov rdi, [rsp + 8]        ; reload value
    mov rsi, [rsp + 16]       ; tag
    DECREF_VAL rdi, rsi
    pop rax                    ; restore truthiness
    add rsp, 16                ; discard saved value + tag
    pop rcx                    ; restore target offset
    test eax, eax
    jz .no_jump
    lea rbx, [rbx + rcx*2]
.no_jump:
    DISPATCH

.pjit_bool_fast:
    test edi, edi
    jz .pjit_no_jump           ; falsy → don't jump
    lea rbx, [rbx + rcx*2]    ; jump
.pjit_no_jump:
    DISPATCH
END_FUNC op_pop_jump_if_true

;; ============================================================================
;; op_pop_jump_if_none - Pop TOS, jump if None
;; ============================================================================
DEF_FUNC_BARE op_pop_jump_if_none
    VPOP_VAL rax, r8            ; rax = value, r8 = value tag

    ; Check for None: TAG_NONE or (TAG_PTR with none_singleton payload)
    cmp r8d, TAG_NONE
    je .is_none
    lea rdx, [rel none_singleton]
    cmp rax, rdx
    jne .not_none

.is_none:
    ; IS None: save jump offset, DECREF, jump
    push rcx                   ; save jump offset
    mov rsi, r8
    DECREF_VAL rax, rsi
    pop rcx                    ; restore jump offset
    lea rbx, [rbx + rcx*2]
    DISPATCH

.not_none:
    ; NOT None: just DECREF and continue
    mov rsi, r8
    DECREF_VAL rax, rsi
    DISPATCH
END_FUNC op_pop_jump_if_none

;; ============================================================================
;; op_pop_jump_if_not_none - Pop TOS, jump if NOT None
;; ============================================================================
DEF_FUNC_BARE op_pop_jump_if_not_none
    VPOP_VAL rax, r8            ; rax = value, r8 = value tag

    ; Check for None: TAG_NONE or (TAG_PTR with none_singleton payload)
    cmp r8d, TAG_NONE
    je .is_none
    lea rdx, [rel none_singleton]
    cmp rax, rdx
    je .is_none

    ; NOT None: save jump offset, DECREF, jump
    push rcx                   ; save jump offset
    mov rsi, r8
    DECREF_VAL rax, rsi
    pop rcx                    ; restore jump offset
    lea rbx, [rbx + rcx*2]
    DISPATCH

.is_none:
    ; IS None: just DECREF and continue
    mov rsi, r8
    DECREF_VAL rax, rsi
    DISPATCH
END_FUNC op_pop_jump_if_not_none

;; ============================================================================
;; op_jump_forward - Unconditional forward jump
;;
;; arg = number of instruction words to skip
;; Each instruction word is 2 bytes, so advance rbx by arg*2 bytes.
;; ============================================================================
DEF_FUNC_BARE op_jump_forward
    ; ecx = arg (instruction words to skip)
    lea rbx, [rbx + rcx*2]
    DISPATCH
END_FUNC op_jump_forward

;; ============================================================================
;; op_jump_backward - Unconditional backward jump
;;
;; arg = number of instruction words to go back
;; Subtract arg*2 bytes from rbx.
;; ============================================================================
DEF_FUNC_BARE op_jump_backward
    ; ecx = arg (instruction words to go back)
    shl ecx, 1                 ; ecx = arg * 2 (zero-extends to rcx)
    sub rbx, rcx
    DISPATCH
END_FUNC op_jump_backward

;; ============================================================================
;; op_format_value - Format a value for f-strings
;;
;; arg & 0x03: conversion (0=none, 1=!s, 2=!r, 3=!a)
;; arg & 0x04: format spec present on stack below value
;; Pops value (and optional fmt_spec), pushes formatted string.
;; ============================================================================
DEF_FUNC op_format_value, FV_FRAME

    mov [rbp - FV_ARG], rcx    ; save arg
    mov rax, rcx
    and eax, 4
    mov [rbp - FV_HASSPEC], rax ; has_fmt_spec
    mov qword [rbp - FV_SPEC], 0 ; fmt_spec ptr (0 if absent)
    mov qword [rbp - FV_STAG], 0 ; fmt_spec tag (0 if absent)

    ; If format spec present, pop it first
    ; Stack order: TOS = fmt_spec, TOS1 = value
    test qword [rbp - FV_HASSPEC], 4
    jz .fv_no_spec
    VPOP_VAL rax, rcx           ; fmt_spec string + tag
    mov [rbp - FV_SPEC], rax   ; save fmt_spec
    mov [rbp - FV_STAG], rcx   ; save fmt_spec tag
.fv_no_spec:

    VPOP_VAL rdi, rax           ; value + tag
    mov [rbp - FV_VALUE], rdi  ; save value
    mov [rbp - FV_VTAG], rax   ; save value tag

    ; If format spec present AND value is float, use float_format_spec
    test qword [rbp - FV_HASSPEC], 4
    jz .fv_no_format_spec

    ; Check if value is a float (TAG_FLOAT)
    extern float_type
    cmp qword [rbp - FV_VTAG], TAG_FLOAT
    jne .fv_no_format_spec

    ; Float with format spec: call float_format_spec(payload, spec_data, spec_len)
    extern float_format_spec
    mov rax, [rbp - FV_SPEC]
    cmp qword [rbp - FV_STAG], TAG_PTR
    jne .fv_type_error
    ; rdi = raw double bits (still set)
    lea rsi, [rax + PyStrObject.data]  ; spec data
    mov rdx, [rax + PyStrObject.ob_size]  ; spec length
    call float_format_spec
    jmp .fv_have_result

.fv_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "format spec must be str"
    call raise_exception

.fv_no_format_spec:
    ; Apply conversion based on arg & 3
    mov rdi, [rbp - FV_VALUE]  ; reload value payload
    mov rsi, [rbp - FV_VTAG]   ; reload value tag
    mov eax, [rbp - FV_ARG]
    and eax, 3
    cmp eax, 2
    je .fv_repr
    ; Default: str() — conversion 0 (none) and 1 (!s) both use str()
    extern obj_str
    call obj_str
    jmp .fv_have_result

.fv_repr:
    extern obj_repr
    call obj_repr

.fv_have_result:
    push rdx                   ; save result tag
    push rax                   ; save result payload

    ; DECREF original value (tag-aware)
    mov rdi, [rbp - FV_VALUE]
    mov rsi, [rbp - FV_VTAG]
    DECREF_VAL rdi, rsi

    ; DECREF fmt_spec if present (tag-aware)
    cmp qword [rbp - FV_SPEC], 0
    je .fv_push
    mov rdi, [rbp - FV_SPEC]
    mov rsi, [rbp - FV_STAG]
    DECREF_VAL rdi, rsi

.fv_push:
    pop rax                    ; result payload
    pop rdx                    ; result tag
    VPUSH_VAL rax, rdx
    leave
    DISPATCH
END_FUNC op_format_value

;; ============================================================================
;; op_build_string - Concatenate N strings from the stack
;;
;; ecx = number of string fragments
;; Pops ecx strings, concatenates in order, pushes result.
;; ============================================================================
DEF_FUNC op_build_string, BS_FRAME

    mov [rbp - BS_COUNT], rcx  ; count

    test ecx, ecx
    jz .bs_zero
    cmp ecx, 1
    je .bs_one

    ; General case: iterate and concatenate
    ; Pop all items, keeping base pointers
    mov rdi, rcx
    shl rdi, 3                 ; count * 8 bytes/slot
    sub r13, rdi               ; pop all payloads at once (r13 = base)
    sub r15, rcx               ; pop all tags at once (r15 = base)

    ; Start with first string
    mov rax, [r13]             ; first fragment payload
    movzx r9d, byte [r15]      ; first fragment tag
    cmp r9d, TAG_PTR
    jne .bs_type_error
    INCREF rax                 ; heap str needs INCREF
    mov [rbp - BS_ACCUM], rax  ; accumulator (heap)

    ; Concatenate remaining
    mov rcx, 1                 ; start from index 1
.bs_loop:
    cmp rcx, [rbp - BS_COUNT]
    jge .bs_decref
    ; Get next fragment — must be heap str
    mov rax, rcx
    mov rsi, [r13 + rax*8]     ; fragment payload
    movzx edx, byte [r15 + rax] ; fragment tag
    cmp edx, TAG_PTR
    jne .bs_type_error
    push rcx
    extern str_concat
    mov rdi, [rbp - BS_ACCUM] ; accumulator
    mov ecx, TAG_PTR           ; right_tag (heap str guaranteed)
    call str_concat
    ; DECREF old accumulator
    push rax                   ; save new result
    mov rdi, [rbp - BS_ACCUM]
    DECREF_REG rdi
    pop rax
    mov [rbp - BS_ACCUM], rax  ; new accumulator
    pop rcx
    inc rcx
    jmp .bs_loop

.bs_decref:
    ; DECREF all original fragments
    xor ecx, ecx
.bs_decref_loop:
    cmp rcx, [rbp - BS_COUNT]
    jge .bs_push
    mov rax, rcx
    mov rdi, [r13 + rax*8]
    movzx rsi, byte [r15 + rax]  ; tag
    push rcx
    DECREF_VAL rdi, rsi
    pop rcx
    inc rcx
    jmp .bs_decref_loop

.bs_push:
    mov rax, [rbp - BS_ACCUM]
    VPUSH_PTR rax
    leave
    DISPATCH

.bs_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "build_string expects str"
    call raise_exception

.bs_zero:
    ; Empty f-string: push empty string
    extern str_from_cstr
    CSTRING rdi, ""
    call str_from_cstr
    VPUSH_VAL rax, rdx
    leave
    DISPATCH

.bs_one:
    ; Shortcut: 1 fragment, just leave it on stack
    leave
    DISPATCH
END_FUNC op_build_string

;; ============================================================================
;; Data section - binary op offset lookup table
;; ============================================================================
section .data

;; Maps NB_* argument (0-25) to the byte offset within PyNumberMethods
;; where the corresponding method function pointer resides.
align 8
binary_op_offsets:
    dq 0    ; NB_ADD (0)              -> nb_add          (+0)
    dq 104  ; NB_AND (1)              -> nb_and          (+104)
    dq 144  ; NB_FLOOR_DIVIDE (2)     -> nb_floor_divide (+144)
    dq 88   ; NB_LSHIFT (3)           -> nb_lshift       (+88)
    dq 0    ; NB_MATRIX_MULTIPLY (4)  -> unsupported (placeholder)
    dq 16   ; NB_MULTIPLY (5)         -> nb_multiply     (+16)
    dq 24   ; NB_REMAINDER (6)        -> nb_remainder    (+24)
    dq 120  ; NB_OR (7)               -> nb_or           (+120)
    dq 40   ; NB_POWER (8)            -> nb_power        (+40)
    dq 96   ; NB_RSHIFT (9)           -> nb_rshift       (+96)
    dq 8    ; NB_SUBTRACT (10)        -> nb_subtract     (+8)
    dq 152  ; NB_TRUE_DIVIDE (11)     -> nb_true_divide  (+152)
    dq 112  ; NB_XOR (12)             -> nb_xor          (+112)
    ; Inplace variants (13-25) map to inplace PyNumberMethods offsets:
    dq 168  ; NB_INPLACE_ADD (13)              -> nb_iadd
    dq 224  ; NB_INPLACE_AND (14)              -> nb_iand
    dq 248  ; NB_INPLACE_FLOOR_DIVIDE (15)     -> nb_ifloor_divide
    dq 208  ; NB_INPLACE_LSHIFT (16)           -> nb_ilshift
    dq 0    ; NB_INPLACE_MATRIX_MULTIPLY (17)  -> unsupported
    dq 184  ; NB_INPLACE_MULTIPLY (18)         -> nb_imul
    dq 192  ; NB_INPLACE_REMAINDER (19)        -> nb_irem
    dq 240  ; NB_INPLACE_OR (20)               -> nb_ior
    dq 200  ; NB_INPLACE_POWER (21)            -> nb_ipow
    dq 216  ; NB_INPLACE_RSHIFT (22)           -> nb_irshift
    dq 176  ; NB_INPLACE_SUBTRACT (23)         -> nb_isub
    dq 256  ; NB_INPLACE_TRUE_DIVIDE (24)      -> nb_itrue_divide
    dq 232  ; NB_INPLACE_XOR (25)              -> nb_ixor

section .text

;; ============================================================================
;; op_make_cell - Wrap localsplus[arg] in a cell object
;;
;; If localsplus[arg] is not already a cell, create one and wrap the value.
;; If localsplus[arg] is NULL, create an empty cell.
;; ============================================================================
DEF_FUNC_BARE op_make_cell
    lea rdx, [rcx*8]              ; slot * 8

    ; Get current value + tag from localsplus
    mov rdi, [r12 + PyFrame.localsplus + rdx]        ; rdi = payload
    movzx rsi, byte [r14 + rcx]                      ; rsi = tag (r14 = locals_tag_base)

    ; Save slot offset
    push rdx

    ; cell_new(payload, tag) - creates cell wrapping value (INCREFs if refcounted)
    call cell_new
    ; rax = new cell

    pop rdx
    mov rcx, rdx
    shr rcx, 3              ; recover slot index from slot*8

    ; DECREF old value (cell_new already INCREFed it; tag-aware, handles NULL)
    mov rdi, [r12 + PyFrame.localsplus + rdx]
    movzx rsi, byte [r14 + rcx]
    push rax
    push rdx
    DECREF_VAL rdi, rsi
    pop rdx
    pop rax

    ; Store cell in localsplus slot (payload + tag)
    mov [r12 + PyFrame.localsplus + rdx], rax
    mov byte [r14 + rcx], TAG_PTR
    DISPATCH
END_FUNC op_make_cell

;; ============================================================================
;; op_copy_free_vars - Copy closure cells into frame's freevar slots
;;
;; arg = count of free vars to copy.
;; Source: current function's func_closure tuple.
;; Destination: localsplus[co_nlocals + ncellvars + i] for i in 0..arg-1
;;
;; In Python 3.12, the function being executed is NOT on the stack.
;; We find it via the calling frame's CALL setup. However, the bytecode
;; compiler ensures COPY_FREE_VARS is the first opcode, and the function
;; object is passed to eval_frame. We need to get it from the frame.
;;
;; Actually, in Python 3.12: the closure tuple is stored in the function
;; object. The function that owns the current frame can be found by
;; looking at the frame's localsplus from the caller. But simpler:
;; we stash the function object in the frame during func_call.
;; ============================================================================
DEF_FUNC_BARE op_copy_free_vars
    ; ecx = number of free vars to copy
    test ecx, ecx
    jz .cfv_done

    ; Get the function object from frame's func_obj slot
    mov rax, [r12 + PyFrame.func_obj]
    test rax, rax
    jz .cfv_done

    ; Get closure tuple from function
    mov rax, [rax + PyFuncObject.func_closure]
    test rax, rax
    jz .cfv_done

    ; rax = closure tuple, ecx = count
    ; Destination: localsplus starts at nlocalsplus - ecx (freevar slots at end)
    ; Actually: Python 3.12 puts freevars after cellvars in localsplus
    ; COPY_FREE_VARS arg tells us the count. The slots are at the END
    ; of localsplus: index [nlocalsplus - arg ... nlocalsplus - 1]
    mov edx, [r12 + PyFrame.nlocalsplus]
    sub edx, ecx                   ; edx = first freevar index

    ; Copy cells from closure tuple to freevar slots
    mov rdi, [rax + PyTupleObject.ob_item]       ; payloads
    mov rsi, [rax + PyTupleObject.ob_item_tags]  ; tags
    xor r8d, r8d                   ; loop counter
.cfv_loop:
    cmp r8d, ecx
    jge .cfv_done

    ; Get cell from closure tuple item[i]
    mov r9, [rdi + r8*8]                               ; payload
    movzx r11d, byte [rsi + r8]                        ; tag

    ; Compute destination index: edx + r8d
    mov r10d, edx
    add r10d, r8d
    mov [r12 + PyFrame.localsplus + r10*8], r9
    mov byte [r14 + r10], r11b                       ; r14 = locals_tag_base

    ; INCREF value (tag-aware)
    INCREF_VAL r9, r11
.cfv_next:
    inc r8d
    jmp .cfv_loop

.cfv_done:
    DISPATCH
END_FUNC op_copy_free_vars

;; ============================================================================
;; op_return_generator - Create generator from current frame
;;
;; RETURN_GENERATOR (75): First instruction in a generator function.
;; Creates a PyGenObject holding the current frame, returns it from eval_frame.
;; The frame is NOT freed by func_call (instr_ptr != 0 signals this).
;; ============================================================================
DEF_FUNC_BARE op_return_generator
    ; Save current execution state in frame for later resumption
    mov [r12 + PyFrame.instr_ptr], rbx
    mov [r12 + PyFrame.stack_ptr], r13
    mov [r12 + PyFrame.stack_tag_ptr], r15

    ; Check co_flags to decide which object type to create
    mov rax, [r12 + PyFrame.code]
    mov eax, [rax + PyCodeObject.co_flags]

    ; Create the appropriate object: gen_new/coro_new/async_gen_new(frame)
    mov rdi, r12
    test eax, CO_COROUTINE
    jnz .ret_gen_coro
    test eax, CO_ASYNC_GENERATOR
    jnz .ret_gen_async

    ; Plain generator
    call gen_new
    jmp .ret_gen_done

.ret_gen_coro:
    call coro_new
    jmp .ret_gen_done

.ret_gen_async:
    call async_gen_new

.ret_gen_done:
    ; rax = new gen/coro/async_gen object
    mov edx, TAG_PTR             ; return tag for fat value protocol

    ; Return from eval_frame
    ; frame->instr_ptr is non-zero, so func_call will skip frame_free
    jmp eval_return
END_FUNC op_return_generator

;; ============================================================================
;; op_yield_value - Yield a value from generator
;;
;; YIELD_VALUE (150): Pop TOS (value to yield), save frame state,
;; return value from eval_frame. The generator is suspended.
;; ============================================================================
DEF_FUNC_BARE op_yield_value
    ; Pop the value to yield (fat: payload + tag)
    VPOP_VAL rax, rdx

    ; Save frame state for resumption
    mov [r12 + PyFrame.instr_ptr], rbx
    mov [r12 + PyFrame.stack_ptr], r13
    mov [r12 + PyFrame.stack_tag_ptr], r15

    ; Return yielded value from eval_frame
    jmp eval_return
END_FUNC op_yield_value

;; ============================================================================
;; op_end_send - End of send operation
;;
;; END_SEND (5): Pop TOS1 (receiver/generator), keep TOS (value).
;; ============================================================================
DEF_FUNC_BARE op_end_send
    ; TOS = value, TOS1 = receiver
    VPOP_VAL rax, r8            ; value payload + tag
    VPOP_VAL rdi, rsi           ; receiver payload + tag
    push r8                    ; save value tag
    push rax                   ; save value payload
    DECREF_VAL rdi, rsi        ; DECREF receiver (tag-aware)
    pop rax
    pop rdx
    VPUSH_VAL rax, rdx         ; push value back with tag
    DISPATCH
END_FUNC op_end_send

;; ============================================================================
;; op_send - Send value to generator/coroutine
;;
;; SEND (123): TOS = value_to_send, TOS1 = receiver (generator)
;; arg = jump offset (relative, used if generator exhausted)
;; Calls gen_send(receiver, value). If yielded: push result.
;; If exhausted (StopIteration): jump forward by arg.
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
extern gen_send
extern gen_type
extern coro_type
extern async_gen_type

DEF_FUNC op_send, SND_FRAME
    ; ecx = arg (jump offset in instructions for StopIteration)
    ; Stack: ... | receiver | sent_value |
    mov [rbp - SND_ARG], rcx   ; save arg

    VPOP_VAL rsi, rax           ; sent_value payload + tag
    mov [rbp - SND_SENT], rsi  ; save sent_value
    mov [rbp - SND_STAG], rax  ; save sent_value tag
    VPEEK rdi                  ; rdi = receiver (TOS1, stay on stack)
    mov [rbp - SND_RECV], rdi  ; save receiver

    ; Check if receiver is a generator with iternext
    cmp byte [r15 - 1], TAG_PTR
    jne .send_error
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .send_error

    ; Check if sent value is None — use iternext, otherwise gen_send
    ; Handle both inline TAG_NONE and pointer-to-none_singleton forms
    cmp qword [rbp - SND_STAG], TAG_NONE
    je .send_use_iternext
    mov rsi, [rbp - SND_SENT]
    lea rcx, [rel none_singleton]
    cmp rsi, rcx
    je .send_use_iternext

    ; Only call gen_send if receiver is gen/coro/async_gen type
    mov rdi, [rbp - SND_RECV]
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel gen_type]
    cmp rax, rcx
    je .send_gen_send
    lea rcx, [rel coro_type]
    cmp rax, rcx
    je .send_gen_send
    lea rcx, [rel async_gen_type]
    cmp rax, rcx
    je .send_gen_send
    ; Not a generator — use tp_iternext (value is discarded)
    jmp .send_use_iternext

.send_gen_send:
    ; gen_send(receiver, value, value_tag)
    mov rdi, [rbp - SND_RECV]
    mov rsi, [rbp - SND_SENT]
    movzx edx, byte [rbp - SND_STAG]
    call gen_send
    jmp .send_check_result

.send_use_iternext:
    ; tp_iternext(receiver)
    mov rdi, [rbp - SND_RECV]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax

.send_check_result:
    mov [rbp - SND_RESULT], rax ; save result payload
    mov [rbp - SND_RTAG], rdx   ; save result tag

    ; DECREF sent value (tag-aware)
    mov rdi, [rbp - SND_SENT]
    movzx esi, byte [rbp - SND_STAG]
    DECREF_VAL rdi, rsi

    mov rax, [rbp - SND_RESULT]
    movzx edx, byte [rbp - SND_RTAG]
    test edx, edx
    jz .send_exhausted

    ; Yielded: push result on top (receiver stays below)
    ; Stack becomes: ... | receiver | yielded_value |
    movzx edx, byte [rbp - SND_RTAG]
    VPUSH_VAL rax, rdx

    ; Skip 1 CACHE entry = 2 bytes
    add rbx, 2
    leave
    DISPATCH

.send_exhausted:
    ; Generator exhausted. Push gi_return_value (for yield-from protocol).
    ; Stack: ... | receiver | → becomes ... | receiver | return_value |
    ; Then jump to END_SEND which will handle cleanup.
    mov rdi, [rbp - SND_RECV]  ; receiver = generator
    mov rax, [rdi + PyGenObject.gi_return_value]
    mov rdx, [rdi + PyGenObject.gi_return_tag]
    test edx, edx
    jnz .send_have_retval
    ; No return value — push None
    lea rax, [rel none_singleton]
    INCREF rax
    VPUSH_PTR rax
    jmp .send_exhausted_jump
.send_have_retval:
    ; INCREF the return value (we're copying it onto the stack)
    INCREF_VAL rax, rdx
    VPUSH_VAL rax, rdx
.send_exhausted_jump:
    ; Skip 1 CACHE entry = 2 bytes, then jump forward by arg * 2 bytes
    add rbx, 2
    mov rcx, [rbp - SND_ARG]
    lea rbx, [rbx + rcx*2]
    leave
    DISPATCH

.send_error:
    ; Unsupported receiver — just push None and continue
    mov rdi, [rbp - SND_SENT]
    mov rsi, [rbp - SND_STAG]
    DECREF_VAL rdi, rsi
    lea rax, [rel none_singleton]
    INCREF rax
    VPUSH_PTR rax
    add rbx, 2
    leave
    DISPATCH
END_FUNC op_send

;; ============================================================================
;; op_get_yield_from_iter - Get iterator for yield-from
;;
;; GET_YIELD_FROM_ITER (69): TOS should be an iterable.
;; If TOS is already a generator, leave it. Otherwise call iter().
;; ============================================================================
DEF_FUNC_BARE op_get_yield_from_iter
    ; TOS = iterable
    VPEEK rdi                  ; rdi = TOS (don't pop)

    ; If it's already a generator or coroutine, done — must be TAG_PTR to check ob_type
    cmp byte [r15 - 1], TAG_PTR
    jne .gyfi_call_iter
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel gen_type]
    cmp rax, rcx
    je .gyfi_done              ; already a generator, leave on stack
    lea rcx, [rel coro_type]
    cmp rax, rcx
    je .gyfi_done              ; already a coroutine, leave on stack

.gyfi_call_iter:
    ; Not a generator — call tp_iter to get an iterator
    VPOP_VAL rdi, r8            ; pop iterable + tag

    ; Must be TAG_PTR to dereference ob_type
    cmp r8, TAG_PTR
    jne .gyfi_error_nopush

    push r8                    ; save tag (deeper)
    push rdi                   ; save payload

    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz .gyfi_error

    call rax                   ; tp_iter(iterable) -> iterator
    push rax                   ; save iterator

    ; DECREF original iterable (tag-aware)
    mov rdi, [rsp + 8]        ; iterable payload
    mov rsi, [rsp + 16]       ; iterable tag
    DECREF_VAL rdi, rsi

    pop rax                    ; restore iterator
    add rsp, 16                ; discard iterable payload + tag
    VPUSH_PTR rax              ; push iterator as new TOS

.gyfi_done:
    DISPATCH

.gyfi_error:
    add rsp, 16                ; discard iterable payload + tag
.gyfi_error_nopush:
    extern exc_TypeError_type
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "object is not iterable"
    call raise_exception
END_FUNC op_get_yield_from_iter

;; ============================================================================
;; op_jump_backward_no_interrupt - Jump backward (no interrupt check)
;;
;; JUMP_BACKWARD_NO_INTERRUPT (134): Same as JUMP_BACKWARD for us.
;; ============================================================================
DEF_FUNC_BARE op_jump_backward_no_interrupt
    shl ecx, 1                 ; arg * 2 = byte offset (zero-extends to rcx)
    sub rbx, rcx
    DISPATCH
END_FUNC op_jump_backward_no_interrupt

;; ============================================================================
;; op_call_intrinsic_1 - Call 1-arg intrinsic function
;;
;; CALL_INTRINSIC_1 (173): arg selects the intrinsic.
;; Pop TOS, call intrinsic, push result.
;; Key intrinsics:
;;   3 = INTRINSIC_STOPITERATION_ERROR (convert StopIteration to RuntimeError)
;;   5 = INTRINSIC_UNARY_POSITIVE (+x)
;;   6 = INTRINSIC_LIST_TO_TUPLE
;; ============================================================================
DEF_FUNC_BARE op_call_intrinsic_1
    cmp ecx, 2
    je .ci1_import_star
    cmp ecx, 3
    je .ci1_stopiter_error
    cmp ecx, 4
    je .ci1_async_gen_wrap
    cmp ecx, 5
    je .ci1_unary_positive
    cmp ecx, 6
    je .ci1_list_to_tuple

    ; Unknown intrinsic — fatal
    CSTRING rdi, "unimplemented CALL_INTRINSIC_1"
    call fatal_error

;; INTRINSIC_IMPORT_STAR (arg=2): import * from module
;; TOS = module object. Copy module's exported names into frame.locals.
;; If module has __all__, use that list. Otherwise copy all non-underscore names.
IS_MOD      equ 16      ; [rbp-16] module ptr
IS_MODDICT  equ 24      ; [rbp-24] module's __dict__
IS_LOCALS   equ 32      ; [rbp-32] frame's locals dict
IS_IDX      equ 40      ; [rbp-40] loop index
IS_LIMIT    equ 48      ; [rbp-48] capacity or count
IS_ITEMS    equ 56      ; [rbp-56] items payload ptr (__all__ path)
IS_ITEM_TAGS equ 64     ; [rbp-64] items tag ptr (__all__ path)
IS_FRAME    equ 64      ; sub rsp, 64 (after push rbp + push rbx = 72 total)
extern dict_get
extern dict_set
extern str_from_cstr_heap
extern obj_decref

.ci1_import_star:
    ; Pop module from TOS (r13 = eval value stack)
    VPOP_VAL rdi, rsi
    cmp rsi, TAG_PTR
    jne .is_done

    ; Set up stack frame
    push rbp
    mov rbp, rsp
    push rbx                          ; [rbp-8] = saved eval-loop bytecode IP
    sub rsp, IS_FRAME
    mov [rbp - IS_MOD], rdi           ; save module ptr

    ; Get mod_dict (+24)
    mov rax, [rdi + PyModuleObject.mod_dict]
    test rax, rax
    jz .is_done
    mov [rbp - IS_MODDICT], rax

    ; Get frame locals
    mov rax, [r12 + PyFrame.locals]
    test rax, rax
    jz .is_done
    mov [rbp - IS_LOCALS], rax

    ; Look up "__all__" in mod_dict
    CSTRING rdi, "__all__"
    call str_from_cstr_heap           ; rax = heap str (owned, refcnt=1)
    mov rbx, rax                      ; save key in callee-saved rbx
    mov rdi, [rbp - IS_MODDICT]
    mov rsi, rax                      ; key = "__all__"
    mov edx, TAG_PTR
    call dict_get                     ; → (rax=value, rdx=tag) or (0, 0)
    ; Save result before DECREF of key
    push rax
    push rdx
    mov rdi, rbx                      ; DECREF "__all__" key string
    call obj_decref
    pop rdx                           ; value tag
    pop rax                           ; value payload

    test edx, edx                     ; TAG_NULL = not found?
    jz .is_no_all

    ;; --- __all__ found: rax = list/tuple ptr ---
    ; Determine items array and count
    mov rbx, rax                      ; rbx = __all__ object
    mov rcx, [rbx + PyVarObject.ob_size]  ; count (same offset for list/tuple)
    mov [rbp - IS_LIMIT], rcx

    ; Check if list or tuple
    extern list_type
    mov rax, [rbx + PyObject.ob_type]
    lea rdx, [rel list_type]
    cmp rax, rdx
    jne .is_all_tuple
    ; List: items = payload/tag arrays
    mov rax, [rbx + PyListObject.ob_item]
    mov rdx, [rbx + PyListObject.ob_item_tags]
    jmp .is_all_have_items
.is_all_tuple:
    ; Tuple: items = payload/tag arrays
    mov rax, [rbx + PyTupleObject.ob_item]
    mov rdx, [rbx + PyTupleObject.ob_item_tags]
.is_all_have_items:
    mov [rbp - IS_ITEMS], rax         ; save payloads ptr
    mov [rbp - IS_ITEM_TAGS], rdx     ; save tags ptr
    mov qword [rbp - IS_IDX], 0

.is_all_loop:
    mov rcx, [rbp - IS_IDX]
    cmp rcx, [rbp - IS_LIMIT]
    jge .is_done

    ; Get name from items[idx]
    mov rax, [rbp - IS_ITEMS]
    mov rdx, [rbp - IS_ITEM_TAGS]
    mov rsi, [rax + rcx * 8]          ; name payload
    movzx edx, byte [rdx + rcx]       ; name tag

    ; Look up name in mod_dict
    mov rdi, [rbp - IS_MODDICT]
    ; rsi = key payload, rdx = key_tag (already set)
    call dict_get                     ; → (rax=value, rdx=value_tag) or (0, 0)
    test edx, edx
    jz .is_all_next                   ; name not in module dict → skip

    ; dict_set(locals, key=name, value, value_tag, key_tag)
    ; Reload name from items array (caller-saved regs clobbered by dict_get)
    mov r9, rax                       ; save value payload
    mov r10, rdx                      ; save value tag
    mov rcx, [rbp - IS_IDX]
    mov rax, [rbp - IS_ITEMS]
    mov rdx, [rbp - IS_ITEM_TAGS]
    mov rsi, [rax + rcx * 8]          ; name payload
    movzx r8d, byte [rdx + rcx]       ; name tag (key_tag)
    mov rdi, [rbp - IS_LOCALS]
    mov rdx, r9                       ; value payload
    mov rcx, r10                      ; value tag
    call dict_set

.is_all_next:
    inc qword [rbp - IS_IDX]
    jmp .is_all_loop

    ;; --- No __all__: walk dict entries, skip _-prefixed names ---
.is_no_all:
    mov rax, [rbp - IS_MODDICT]
    mov rcx, [rax + PyDictObject.capacity]
    mov [rbp - IS_LIMIT], rcx
    mov qword [rbp - IS_IDX], 0

.is_dict_loop:
    mov rcx, [rbp - IS_IDX]
    cmp rcx, [rbp - IS_LIMIT]
    jge .is_done

    ; Entry address: entries + idx * DICT_ENTRY_SIZE (40)
    mov rax, [rbp - IS_MODDICT]
    mov rsi, [rax + PyDictObject.entries]
    imul rcx, DICT_ENTRY_SIZE
    lea rbx, [rsi + rcx]              ; rbx = entry ptr (callee-saved)

    ; Skip empty: key_tag == 0
    movzx r8d, byte [rbx + DictEntry.key_tag]
    test r8d, r8d
    jz .is_dict_next

    ; Get key payload
    mov rsi, [rbx + DictEntry.key]

    ; Skip names starting with '_'
    cmp r8d, TAG_PTR
    jne .is_dict_copy                 ; non-string → copy
    ; Heap string: check first data byte
    cmp byte [rsi + PyStrObject.data], '_'
    je .is_dict_next

.is_dict_copy:
    ; dict_set(locals, key, value, value_tag, key_tag)
    mov rdi, [rbp - IS_LOCALS]
    ; rsi = key payload (already set)
    mov rdx, [rbx + DictEntry.value]
    movzx ecx, byte [rbx + DictEntry.value_tag]
    ; r8 = key_tag (already set)
    call dict_set

.is_dict_next:
    inc qword [rbp - IS_IDX]
    jmp .is_dict_loop

.is_done:
    ; DECREF module
    mov rdi, [rbp - IS_MOD]
    call obj_decref

    ; Restore and return
    mov rbx, [rbp - 8]                ; restore eval-loop bytecode IP
    leave                             ; mov rsp, rbp; pop rbp
    VPUSH_NONE
    DISPATCH

.ci1_async_gen_wrap:
    ; INTRINSIC_ASYNC_GEN_WRAP: wrap yielded value for async generators
    ; In our implementation, this is a no-op — value passes through unchanged.
    ; The async generator protocol is handled by async_gen_iternext.
    DISPATCH

.ci1_stopiter_error:
    ; INTRINSIC_STOPITERATION_ERROR: convert StopIteration to RuntimeError
    ; Only converts if exception IS StopIteration; otherwise re-raise as-is
    mov rax, [r13 - 8]            ; TOS payload (exception)
    test rax, rax
    jz .ci1_si_convert
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel exc_StopIteration_type]
    cmp rcx, rdx
    jne .ci1_si_reraise
.ci1_si_convert:
    ; Pop the exception, raise RuntimeError instead
    VPOP_VAL rdi, rsi
    DECREF_VAL rdi, rsi
    mov [rel eval_saved_r13], r13  ; update — popped and DECREF'd
    mov [rel eval_saved_r15], r15
    lea rdi, [rel exc_RuntimeError_type]
    CSTRING rsi, "generator raised StopIteration"
    call raise_exception
.ci1_si_reraise:
    ; Not StopIteration — pop from TOS, set as current_exception, re-raise
    VPOP_VAL rax, rsi              ; exception (ref transferred from stack)
    mov [rel eval_saved_r13], r13  ; update — popped and transferred
    mov [rel eval_saved_r15], r15
    mov [rel current_exception], rax
    jmp eval_exception_unwind

.ci1_unary_positive:
    ; +x — for most numeric types, no-op. For bool, call nb_positive.
    ; Check if TOS is TAG_BOOL
    cmp byte [r15 - 1], TAG_BOOL
    je .ci1_pos_call
    ; Check if TOS is TAG_PTR pointing to bool_type
    cmp byte [r15 - 1], TAG_PTR
    jne .ci1_pos_done
    mov rax, [r13 - 8]        ; payload
    test rax, rax
    jz .ci1_pos_done
    mov rcx, [rax + PyObject.ob_type]
    extern bool_type
    lea r8, [rel bool_type]
    cmp rcx, r8
    jne .ci1_pos_done
    ; Bool singleton: replace TOS with SmallInt 0 or 1
    extern bool_true
    lea rcx, [rel bool_true]
    xor eax, eax
    cmp qword [r13 - 8], rcx
    sete al
    mov [r13 - 8], rax
    mov byte [r15 - 1], TAG_SMALLINT
.ci1_pos_done:
    DISPATCH

.ci1_pos_call:
    ; TAG_BOOL: payload is 0 or 1 → convert to SmallInt
    mov byte [r15 - 1], TAG_SMALLINT
    DISPATCH

.ci1_list_to_tuple:
    ; Convert list to tuple
    VPOP_VAL rdi, rsi           ; rdi = list, rsi = tag
    cmp rsi, TAG_PTR
    jne .ci1_l2t_error
    push rdi                   ; save for DECREF

    ; Get list size and items
    mov rcx, [rdi + PyListObject.ob_size]
    mov rsi, [rdi + PyListObject.ob_item]
    mov rdx, [rdi + PyListObject.ob_item_tags]
    push rcx
    push rsi
    push rdx

    ; Create tuple of same size
    mov rdi, rcx
    call tuple_new
    ; (tuple in rax — use stack, do NOT clobber rbx which is the bytecode IP)
    pop r11                    ; tags ptr
    pop rsi                    ; payloads ptr
    pop rcx                    ; count
    push rax                   ; save tuple

    ; Copy items from list to tuple, INCREF each
    xor edx, edx
.ci1_l2t_loop:
    cmp rdx, rcx
    jge .ci1_l2t_done
    push rcx
    push rdx
    push rsi

    mov rdi, [rsi + rdx * 8]        ; item payload
    movzx r9d, byte [r11 + rdx]     ; item tag
    mov rax, [rsp + 24]             ; tuple from stack
    mov r8, [rax + PyTupleObject.ob_item]
    mov r10, [rax + PyTupleObject.ob_item_tags]
    mov [r8 + rdx * 8], rdi         ; payload
    mov byte [r10 + rdx], r9b       ; tag
    INCREF_VAL rdi, r9

    pop rsi
    pop rdx
    pop rcx
    inc rdx
    jmp .ci1_l2t_loop

.ci1_l2t_done:
    pop rax                    ; tuple
    VPUSH_PTR rax

    ; DECREF list
    pop rdi
    DECREF_REG rdi

    DISPATCH

.ci1_l2t_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "list expected"
    call raise_exception
END_FUNC op_call_intrinsic_1

;; ============================================================================
;; op_get_len - Push len(TOS) without popping TOS
;;
;; Opcode 30: GET_LEN
;; Used by match statements: push len, keep original on stack.
;; ============================================================================
extern obj_len

DEF_FUNC_BARE op_get_len
    ; PEEK TOS (don't pop, 16 bytes/slot)
    cmp byte [r15 - 1], TAG_PTR
    jne .gl_error_nopop         ; non-pointer has no len()
    mov rdi, [r13 - 8]
    push rdi                    ; save obj

    ; Get length
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .gl_try_mapping
    mov rax, [rax + PySequenceMethods.sq_length]
    test rax, rax
    jz .gl_try_mapping
    call rax
    jmp .gl_got_len

.gl_try_mapping:
    pop rdi
    push rdi
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .gl_error
    mov rax, [rax + PyMappingMethods.mp_length]
    test rax, rax
    jz .gl_error
    call rax

.gl_got_len:
    pop rdi                     ; discard saved obj
    ; Convert length (in rax) to SmallInt and push
    VPUSH_INT rax
    DISPATCH

.gl_error:
    pop rdi
.gl_error_nopop:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "object has no len()"
    call raise_exception
END_FUNC op_get_len

;; ============================================================================
;; op_setup_annotations - Create __annotations__ dict in locals
;;
;; Opcode 85: SETUP_ANNOTATIONS
;; ============================================================================
extern dict_new
extern dict_set
extern str_from_cstr

DEF_FUNC op_setup_annotations
    push rbx
    push r12                    ; save eval loop r12

    ; Check if locals dict exists
    mov rbx, [r12 + PyFrame.locals]
    test rbx, rbx
    jz .sa_done

    ; Create __annotations__ dict
    call dict_new
    mov r12, rax                ; r12 = new annotations dict (saved)

    ; Create key string (heap — dict key, DECREFed)
    extern str_from_cstr_heap
    CSTRING rdi, "__annotations__"
    call str_from_cstr_heap
    ; rax = key string

    ; dict_set(locals, key, value, value_tag)
    mov rdi, rbx                ; dict = locals
    mov rsi, rax                ; key = "__annotations__"
    mov rdx, r12                ; value = new annotations dict
    mov ecx, TAG_PTR            ; value tag
    mov r8d, TAG_PTR            ; key tag
    push rax                    ; save key for DECREF
    push rdx                    ; save value for DECREF
    call dict_set
    pop rdi
    call obj_decref             ; DECREF value (dict_set INCREFs)
    pop rdi
    call obj_decref             ; DECREF key

.sa_done:
    pop r12
    pop rbx
    pop rbp
    DISPATCH
END_FUNC op_setup_annotations

;; ============================================================================
;; op_load_locals - Push locals dict
;;
;; Opcode 87: LOAD_LOCALS
;; ============================================================================
DEF_FUNC_BARE op_load_locals
    mov rax, [r12 + PyFrame.locals]
    test rax, rax
    jz .ll_error
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
.ll_error:
    lea rdi, [rel exc_RuntimeError_type]
    CSTRING rsi, "no locals dict"
    call raise_exception
END_FUNC op_load_locals

;; ============================================================================
;; op_load_from_dict_or_globals - Load from dict on TOS, fallback to globals
;;
;; Opcode 175: LOAD_FROM_DICT_OR_GLOBALS
;; Used in class body comprehensions.
;; ============================================================================
extern dict_get

DEF_FUNC_BARE op_load_from_dict_or_globals
    ; ecx = name index (payload array: 8-byte stride)
    shl ecx, 3
    LOAD_CO_NAMES rsi
    mov rsi, [rsi + rcx]       ; name string
    push rsi

    ; Pop dict from TOS
    VPOP_VAL rdi, r8
    push rdi                    ; save dict
    cmp r8, TAG_PTR
    jne .lfdg_not_dict

    ; Try dict first
    mov rsi, [rsp + 8]         ; name
    mov edx, TAG_PTR
    call dict_get
    test edx, edx
    jnz .lfdg_found

    ; Try globals
    mov rdi, [r12 + PyFrame.globals]
    mov rsi, [rsp + 8]         ; name
    mov edx, TAG_PTR
    call dict_get
    test edx, edx
    jnz .lfdg_found

    ; DECREF dict (owned ref from TOS) before builtins lookup
    pop rdi                     ; saved dict
    DECREF rdi
    pop rsi                     ; name

    ; Try builtins
    mov rdi, [r12 + PyFrame.builtins]
    mov edx, TAG_PTR
    call dict_get
    test edx, edx
    jnz .lfdg_found_no_pop

    ; Not found
    extern exc_NameError_type
    lea rdi, [rel exc_NameError_type]
    CSTRING rsi, "name not found"
    call raise_exception

.lfdg_found:
    ; INCREF result (borrowed ref) before DECREF dict
    INCREF_VAL rax, rdx
    ; Save result across DECREF
    push rax
    push rdx
    mov rdi, [rsp + 16]        ; saved dict (shifted by 2 pushes)
    DECREF rdi
    pop rdx
    pop rax
    add rsp, 16                 ; pop saved dict + name
    VPUSH_VAL rax, rdx
    DISPATCH

.lfdg_not_dict:
    ; Not a dict on TOS
    pop rdi
    pop rsi
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "dict expected"
    call raise_exception

.lfdg_found_no_pop:
    ; dict already DECREFed in builtins path
    INCREF_VAL rax, rdx
    VPUSH_VAL rax, rdx
    DISPATCH
END_FUNC op_load_from_dict_or_globals

;; ============================================================================
;; op_load_from_dict_or_deref - Load from dict on TOS, fallback to cell deref
;;
;; Opcode 176: LOAD_FROM_DICT_OR_DEREF
;; Used in class bodies that access closure variables directly (e.g. val = x).
;; Pop dict from TOS. Try dict[name] first. If not found, fall back to
;; loading through cell at localsplus[arg] (same as LOAD_DEREF).
;; ============================================================================
global op_load_from_dict_or_deref

LFDOD_DICT  equ 8
LFDOD_ARG   equ 16
LFDOD_FRAME equ 16

DEF_FUNC op_load_from_dict_or_deref, LFDOD_FRAME
    mov [rbp - LFDOD_ARG], ecx    ; save arg (localsplus index)

    ; Get name from co_names (payload array: 8-byte stride)
    shl ecx, 3
    LOAD_CO_NAMES rsi
    mov rsi, [rsi + rcx]          ; name string

    ; Pop dict from TOS
    VPOP_VAL rdi, r8
    mov [rbp - LFDOD_DICT], rdi   ; save dict
    cmp r8, TAG_PTR
    jne .lfdod_error

    ; Try dict first
    mov edx, TAG_PTR
    call dict_get
    test edx, edx
    jnz .lfdod_found

    ; Not in dict — fall back to cell deref (like LOAD_DEREF)
    mov ecx, [rbp - LFDOD_ARG]
    mov rax, [r12 + PyFrame.localsplus + rcx*8]  ; cell object
    test rax, rax
    jz .lfdod_error
    mov rdx, [rax + PyCellObject.ob_ref_tag]
    mov rax, [rax + PyCellObject.ob_ref]
    test rdx, rdx                 ; check tag for empty cell
    jz .lfdod_error

.lfdod_found:
    ; INCREF result (borrowed ref) before DECREF dict
    INCREF_VAL rax, rdx
    ; Save result across DECREF of owned dict ref
    push rax
    push rdx
    mov rdi, [rbp - LFDOD_DICT]
    DECREF rdi
    pop rdx
    pop rax
    VPUSH_VAL rax, rdx
    leave
    DISPATCH

.lfdod_error:
    lea rdi, [rel exc_NameError_type]
    CSTRING rsi, "free variable referenced before assignment"
    call raise_exception
END_FUNC op_load_from_dict_or_deref

;; ============================================================================
;; op_match_mapping - Check if TOS is a mapping type
;;
;; Opcode 31: MATCH_MAPPING
;; Push True if TOS is dict/mapping, False otherwise. Don't pop TOS.
;; ============================================================================
extern dict_type

DEF_FUNC_BARE op_match_mapping
    mov rdi, [r13 - 8]            ; peek TOS payload
    cmp byte [r15 - 1], TAG_PTR
    jne .mm_false                  ; non-pointer → not a mapping
    mov rax, [rdi + PyObject.ob_type]
    ; Check if it's a dict or has tp_as_mapping with mp_subscript
    lea rcx, [rel dict_type]
    cmp rax, rcx
    je .mm_true
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .mm_false
    mov rax, [rax + PyMappingMethods.mp_subscript]
    test rax, rax
    jz .mm_false
.mm_true:
    lea rax, [rel bool_true]
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
.mm_false:
    lea rax, [rel bool_false]
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
END_FUNC op_match_mapping

;; ============================================================================
;; op_match_sequence - Check if TOS is a sequence type
;;
;; Opcode 32: MATCH_SEQUENCE
;; Push True if TOS is list/tuple/sequence (not str/bytes/dict). Don't pop TOS.
;; ============================================================================
extern tuple_type
extern str_type
extern bytes_type

DEF_FUNC_BARE op_match_sequence
    mov rdi, [r13 - 8]            ; peek TOS payload
    cmp byte [r15 - 1], TAG_PTR
    jne .ms_false                  ; non-pointer → not a sequence
    mov rax, [rdi + PyObject.ob_type]
    ; Exclude str, bytes, dict
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .ms_false
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .ms_false
    lea rcx, [rel dict_type]
    cmp rax, rcx
    je .ms_false
    ; Check list or tuple type directly
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .ms_true
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .ms_true
    ; Check tp_as_sequence with sq_item
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .ms_false
    mov rax, [rax + PySequenceMethods.sq_item]
    test rax, rax
    jz .ms_false
.ms_true:
    lea rax, [rel bool_true]
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
.ms_false:
    lea rax, [rel bool_false]
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
END_FUNC op_match_sequence

;; ============================================================================
;; op_match_keys - Match mapping keys
;;
;; Opcode 33: MATCH_KEYS
;; TOS = keys tuple, TOS1 = subject (mapping)
;; If all keys in tuple exist in subject, push tuple of values + True
;; Otherwise push False
;; ============================================================================
DEF_FUNC op_match_keys, MK_FRAME

    ; TOS = keys tuple, TOS1 = subject (16 bytes/slot)
    ; Peek at both — don't pop either! Push result on top.
    mov rax, [r13 - 8]            ; keys tuple (TOS)
    mov [rbp - MK_KEYS], rax
    mov rax, [r13 - 16]           ; subject (TOS1)
    mov [rbp - MK_SUBJ], rax

    ; Allocate values tuple
    mov rax, [rbp - MK_KEYS]
    mov rdi, [rax + PyTupleObject.ob_size]
    mov [rbp - MK_NKEYS], rdi     ; save nkeys
    call tuple_new
    mov [rbp - MK_VALS], rax      ; values tuple

    xor edx, edx                   ; index

.mk_loop:
    cmp rdx, [rbp - MK_NKEYS]
    jge .mk_success

    push rdx

    ; Get key
    mov rax, [rbp - MK_KEYS]
    mov rsi, [rax + PyTupleObject.ob_item]        ; payloads
    mov rsi, [rsi + rdx*8]                         ; key payload

    ; Look up in subject
    mov rdi, [rbp - MK_SUBJ]
    mov edx, TAG_PTR
    call dict_get
    test edx, edx
    jz .mk_fail

    ; Save dict_get tag (rdx) before restoring loop index
    mov r9, rdx                 ; r9 = value tag from dict_get

    ; Store value in values tuple
    pop rdx
    push rdx
    INCREF_VAL rax, r9          ; tag-aware INCREF
    mov rcx, [rbp - MK_VALS]
    mov r8, [rcx + PyTupleObject.ob_item]         ; payloads
    mov r10, [rcx + PyTupleObject.ob_item_tags]   ; tags
    mov [r8 + rdx*8], rax
    mov byte [r10 + rdx], r9b                     ; tag from dict_get

    pop rdx
    inc rdx
    jmp .mk_loop

.mk_success:
    ; Push values tuple on top (stack: subject, keys, values_tuple)
    mov rax, [rbp - MK_VALS]
    VPUSH_PTR rax
    jmp .mk_done

.mk_fail:
    pop rdx
    ; DECREF partial values tuple
    mov rdi, [rbp - MK_VALS]
    call obj_decref
    ; Push None on top to indicate failure (stack: subject, keys, None)
    lea rax, [rel none_singleton]
    INCREF rax
    VPUSH_PTR rax

.mk_done:
    leave
    DISPATCH
END_FUNC op_match_keys

;; ============================================================================
;; op_match_class - Structural pattern matching: match class
;;
;; Opcode 152: MATCH_CLASS
;; Stack before: subject(TOS2), class(TOS1), kw_attrs_tuple(TOS)
;; Arg (ecx) = npos (number of positional sub-patterns)
;; Stack after: attrs_tuple (success) or None (failure)
;; All 3 inputs consumed.
;; ============================================================================

;; Stack layout constants (MC_ prefix)
MC_SUBJ      equ 8
MC_CLASS     equ 16
MC_KWATTRS   equ 24
MC_NPOS      equ 32
MC_RESULT    equ 40
MC_MATCHARGS equ 48
MC_IDX       equ 56
MC_SUBJ_TAG  equ 64
MC_FRAME     equ 72

extern none_type
extern str_type

DEF_FUNC op_match_class, MC_FRAME

    ; Pop all 3 inputs
    VPOP rax                        ; kw_attrs tuple (TOS)
    mov [rbp - MC_KWATTRS], rax
    VPOP rax                        ; class (TOS1)
    mov [rbp - MC_CLASS], rax
    VPOP_VAL rax, rdx               ; subject (TOS2) + tag
    mov [rbp - MC_SUBJ], rax
    mov [rbp - MC_SUBJ_TAG], rdx

    mov [rbp - MC_NPOS], rcx        ; save npos
    mov qword [rbp - MC_RESULT], 0  ; result tuple (NULL initially)
    mov qword [rbp - MC_MATCHARGS], 0  ; __match_args__ (NULL initially)

    ;; --- isinstance check ---
    ;; Get subject's type (SmallInt/None-aware)
    mov rax, [rbp - MC_SUBJ]
    cmp qword [rbp - MC_SUBJ_TAG], TAG_SMALLINT
    je .mc_smallint_type
    jz .mc_none_type
    mov rdx, [rax + PyObject.ob_type]
    jmp .mc_got_type

.mc_smallint_type:
    lea rdx, [rel int_type]
    jmp .mc_got_type

.mc_none_type:
    lea rdx, [rel none_type]

.mc_got_type:
    ; rdx = subject's type, walk tp_base chain vs class
    mov rcx, [rbp - MC_CLASS]
.mc_isinstance_walk:
    cmp rdx, rcx
    je .mc_isinstance_ok
    mov rdx, [rdx + PyTypeObject.tp_base]
    test rdx, rdx
    jnz .mc_isinstance_walk
    ; Not an instance of class — fail
    jmp .mc_fail

.mc_isinstance_ok:
    ;; --- Get __match_args__ if npos > 0 ---
    mov rcx, [rbp - MC_NPOS]
    test rcx, rcx
    jz .mc_no_matchargs_needed

    ; Look up __match_args__ on the class via tp_dict chain
    mov r8, [rbp - MC_CLASS]       ; start at class
.mc_matchargs_walk:
    mov rdi, [r8 + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .mc_matchargs_next_base

    ; Look up "__match_args__" in dict
    push r8
    push rdi                        ; save dict
    lea rdi, [rel .mc_matchargs_cstr]
    call str_from_cstr_heap
    mov rsi, rax                    ; rsi = "__match_args__" str obj
    pop rdi                         ; restore dict
    push rsi                        ; save string for DECREF
    mov edx, TAG_PTR
    call dict_get
    pop rsi                         ; rsi = string to DECREF
    push rdx                        ; save dict_get tag
    push rax                        ; save dict_get payload
    mov rdi, rsi
    call obj_decref
    pop rax                         ; restore dict_get payload
    pop rdx                         ; restore dict_get tag
    pop r8                          ; restore type pointer

    test edx, edx
    jnz .mc_matchargs_found

.mc_matchargs_next_base:
    mov r8, [r8 + PyTypeObject.tp_base]
    test r8, r8
    jnz .mc_matchargs_walk

    ; __match_args__ not found and npos > 0 — fail
    jmp .mc_fail

.mc_matchargs_found:
    ; rax = __match_args__ tuple (borrowed ref from dict_get)
    INCREF rax
    mov [rbp - MC_MATCHARGS], rax

    ; Verify length >= npos
    mov rcx, [rbp - MC_NPOS]
    mov rdx, [rax + PyTupleObject.ob_size]
    cmp rdx, rcx
    jl .mc_fail                     ; not enough match_args

.mc_no_matchargs_needed:
    ;; --- Allocate result tuple: npos + len(kw_attrs) ---
    mov rdi, [rbp - MC_NPOS]
    mov rax, [rbp - MC_KWATTRS]
    add rdi, [rax + PyTupleObject.ob_size]
    call tuple_new
    mov [rbp - MC_RESULT], rax

    ;; --- Positional loop: i=0..npos-1 ---
    mov qword [rbp - MC_IDX], 0
.mc_pos_loop:
    mov rcx, [rbp - MC_IDX]
    cmp rcx, [rbp - MC_NPOS]
    jge .mc_kw_start

    ; Get attr name from __match_args__[i]
    mov rax, [rbp - MC_MATCHARGS]
    mov rsi, [rax + PyTupleObject.ob_item]       ; payloads
    mov rsi, [rsi + rcx*8]                       ; name string

    ; Call subject's tp_getattr(subject, name)
    mov rdi, [rbp - MC_SUBJ]
    cmp qword [rbp - MC_SUBJ_TAG], TAG_SMALLINT
    je .mc_fail                     ; SmallInt has no attrs
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_getattr]
    test rax, rax
    jz .mc_fail
    call rax
    test edx, edx
    jz .mc_fail                     ; attr not found

    ; Store in result tuple[i] (already owns a ref from tp_getattr, fat: *16)
    ; rdx = tag from tp_getattr (save before clobbering)
    mov r9, rdx                     ; save tag
    mov rcx, [rbp - MC_IDX]
    mov rdx, [rbp - MC_RESULT]
    mov r8, [rdx + PyTupleObject.ob_item]        ; payloads
    mov r10, [rdx + PyTupleObject.ob_item_tags]  ; tags
    mov [r8 + rcx*8], rax
    mov byte [r10 + rcx], r9b                    ; tag from tp_getattr

    inc qword [rbp - MC_IDX]
    jmp .mc_pos_loop

.mc_kw_start:
    ;; --- Keyword loop: j=0..nkw-1 ---
    mov qword [rbp - MC_IDX], 0
.mc_kw_loop:
    mov rcx, [rbp - MC_IDX]
    mov rax, [rbp - MC_KWATTRS]
    cmp rcx, [rax + PyTupleObject.ob_size]
    jge .mc_success

    ; Get attr name from kw_attrs[j]
    mov r8, [rax + PyTupleObject.ob_item]        ; payloads
    mov rsi, [r8 + rcx*8]                        ; name string

    ; Call subject's tp_getattr(subject, name)
    mov rdi, [rbp - MC_SUBJ]
    cmp qword [rbp - MC_SUBJ_TAG], TAG_SMALLINT
    je .mc_fail                     ; SmallInt has no attrs
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_getattr]
    test rax, rax
    jz .mc_fail
    call rax
    test edx, edx
    jz .mc_fail                     ; attr not found

    ; Store in result tuple[npos + j] (fat: *16)
    ; rdx = tag from tp_getattr (save before clobbering)
    mov r9, rdx                     ; save tag
    mov rcx, [rbp - MC_IDX]
    add rcx, [rbp - MC_NPOS]
    mov rdx, [rbp - MC_RESULT]
    mov r8, [rdx + PyTupleObject.ob_item]        ; payloads
    mov r10, [rdx + PyTupleObject.ob_item_tags]  ; tags
    mov [r8 + rcx*8], rax
    mov byte [r10 + rcx], r9b                    ; tag from tp_getattr

    inc qword [rbp - MC_IDX]
    jmp .mc_kw_loop

.mc_success:
    ; Push result tuple, DECREF inputs
    mov rax, [rbp - MC_RESULT]
    push rax                        ; save result

    ; DECREF __match_args__ if held
    mov rdi, [rbp - MC_MATCHARGS]
    test rdi, rdi
    jz .mc_success_decref_inputs
    call obj_decref

.mc_success_decref_inputs:
    ; DECREF subject (tag-aware, may be SmallInt)
    mov rdi, [rbp - MC_SUBJ]
    mov rsi, [rbp - MC_SUBJ_TAG]
    DECREF_VAL rdi, rsi
    ; DECREF class
    mov rdi, [rbp - MC_CLASS]
    DECREF_REG rdi
    ; DECREF kw_attrs tuple
    mov rdi, [rbp - MC_KWATTRS]
    DECREF_REG rdi

    pop rax                         ; restore result tuple
    VPUSH_PTR rax
    leave
    DISPATCH

.mc_fail:
    ; DECREF partial result tuple if allocated (tuple_new zeros items,
    ; tuple_dealloc skips NULLs, so partial is safe)
    mov rdi, [rbp - MC_RESULT]
    test rdi, rdi
    jz .mc_fail_matchargs
    call obj_decref

.mc_fail_matchargs:
    ; XDECREF __match_args__ if held
    mov rdi, [rbp - MC_MATCHARGS]
    test rdi, rdi
    jz .mc_fail_decref_inputs
    call obj_decref

.mc_fail_decref_inputs:
    ; DECREF subject (tag-aware, may be SmallInt)
    mov rdi, [rbp - MC_SUBJ]
    mov rsi, [rbp - MC_SUBJ_TAG]
    DECREF_VAL rdi, rsi
    ; DECREF class
    mov rdi, [rbp - MC_CLASS]
    DECREF_REG rdi
    ; DECREF kw_attrs tuple
    mov rdi, [rbp - MC_KWATTRS]
    DECREF_REG rdi

    ; Push None
    lea rax, [rel none_singleton]
    INCREF rax
    VPUSH_PTR rax
    leave
    DISPATCH

section .rodata
.mc_matchargs_cstr: db "__match_args__", 0
section .text

END_FUNC op_match_class

;; ============================================================================
;; op_call_intrinsic_2 - Call 2-arg intrinsic function
;;
;; Opcode 174: CALL_INTRINSIC_2
;; arg selects the intrinsic.
;; TOS = arg2, TOS1 = arg1
;; Key intrinsics:
;;   1 = INTRINSIC_PREP_RERAISE - set __traceback__
;;   2 = INTRINSIC_TYPEVAR_WITH_BOUND
;;   3 = INTRINSIC_TYPEVAR_WITH_CONSTRAINTS
;;   4 = INTRINSIC_SET_FUNCTION_TYPE_PARAMS
;; ============================================================================
DEF_FUNC_BARE op_call_intrinsic_2
    cmp ecx, 1
    je .ci2_prep_reraise

    ; For type parameter intrinsics, just keep TOS1 and discard TOS
    ; (a simplification — full type parameter support would need more)
    VPOP_VAL rdi, rsi
    DECREF_VAL rdi, rsi
    ; TOS1 stays
    DISPATCH

.ci2_prep_reraise:
    ; INTRINSIC_PREP_RERAISE_STAR: TOS = exc_list, TOS1 = orig_exc
    ; Delegate to prep_reraise_star(orig, excs_list)
    VPOP_VAL rsi, rdx              ; rsi = exc_list
    VPOP_VAL rdi, rcx              ; rdi = orig_exc
    call prep_reraise_star
    VPUSH_PTR rax
    DISPATCH
END_FUNC op_call_intrinsic_2

;; ============================================================================
;; op_binary_op_add_int - Specialized SmallInt add (opcode 211)
;;
;; Guard: both TOS and TOS1 must be SmallInt (tag-based).
;; On guard failure: deopt back to BINARY_OP (122).
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_binary_op_add_int
    VPOP_VAL rsi, r8            ; right + tag
    VPOP_VAL rdi, r9            ; left + tag
    ; Guard: both SmallInt (tag-based)
    cmp r9d, TAG_SMALLINT
    jne .add_int_deopt_repush
    cmp r8d, TAG_SMALLINT
    jne .add_int_deopt_repush
    ; Add, check overflow
    mov rax, rdi
    mov rdx, rsi
    add rax, rdx
    jo .add_int_deopt_repush
    ; Encode as SmallInt
    VPUSH_INT rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.add_int_deopt_repush:
    ; Overflow: re-push operands and deopt
    VPUSH_VAL rdi, r9
    VPUSH_VAL rsi, r8
.add_int_deopt:
    ; Rewrite opcode back to BINARY_OP (122)
    mov byte [rbx - 2], 122
    sub rbx, 2                 ; back up to re-execute as BINARY_OP
    DISPATCH
END_FUNC op_binary_op_add_int

;; ============================================================================
;; op_binary_op_sub_int - Specialized SmallInt subtract (opcode 212)
;;
;; Guard: both TOS and TOS1 must be SmallInt (tag-based).
;; On guard failure: deopt back to BINARY_OP (122).
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_binary_op_sub_int
    VPOP_VAL rsi, r8            ; right + tag
    VPOP_VAL rdi, r9            ; left + tag
    ; Guard: both SmallInt (tag-based)
    cmp r9d, TAG_SMALLINT
    jne .sub_int_deopt_repush
    cmp r8d, TAG_SMALLINT
    jne .sub_int_deopt_repush
    ; Sub, check overflow
    mov rax, rdi
    mov rdx, rsi
    sub rax, rdx
    jo .sub_int_deopt_repush
    ; Encode as SmallInt
    VPUSH_INT rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.sub_int_deopt_repush:
    ; Overflow or type mismatch: re-push operands and deopt
    VPUSH_VAL rdi, r9
    VPUSH_VAL rsi, r8
.sub_int_deopt:
    ; Rewrite opcode back to BINARY_OP (122)
    mov byte [rbx - 2], 122
    sub rbx, 2                 ; back up to re-execute as BINARY_OP
    DISPATCH
END_FUNC op_binary_op_sub_int

;; ============================================================================
;; op_binary_op_add_float - Specialized float add (opcode 217)
;;
;; Guard: both TOS and TOS1 must be TAG_FLOAT.
;; On guard failure: deopt back to BINARY_OP (122).
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_binary_op_add_float
    VPOP_VAL rsi, r8            ; right + tag
    VPOP_VAL rdi, r9            ; left + tag
    cmp r9d, TAG_FLOAT
    jne .add_float_deopt_repush
    cmp r8d, TAG_FLOAT
    jne .add_float_deopt_repush
    movq xmm0, rdi
    movq xmm1, rsi
    addsd xmm0, xmm1
    movq rax, xmm0
    VPUSH_FLOAT rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.add_float_deopt_repush:
    VUNDROP 2
.add_float_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_add_float

;; ============================================================================
;; op_binary_op_sub_float - Specialized float subtract (opcode 218)
;; ============================================================================
DEF_FUNC_BARE op_binary_op_sub_float
    VPOP_VAL rsi, r8            ; right + tag
    VPOP_VAL rdi, r9            ; left + tag
    cmp r9d, TAG_FLOAT
    jne .sub_float_deopt_repush
    cmp r8d, TAG_FLOAT
    jne .sub_float_deopt_repush
    movq xmm0, rdi
    movq xmm1, rsi
    subsd xmm0, xmm1
    movq rax, xmm0
    VPUSH_FLOAT rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.sub_float_deopt_repush:
    VUNDROP 2
.sub_float_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_sub_float

;; ============================================================================
;; op_binary_op_mul_float - Specialized float multiply (opcode 219)
;; ============================================================================
DEF_FUNC_BARE op_binary_op_mul_float
    VPOP_VAL rsi, r8            ; right + tag
    VPOP_VAL rdi, r9            ; left + tag
    cmp r9d, TAG_FLOAT
    jne .mul_float_deopt_repush
    cmp r8d, TAG_FLOAT
    jne .mul_float_deopt_repush
    movq xmm0, rdi
    movq xmm1, rsi
    mulsd xmm0, xmm1
    movq rax, xmm0
    VPUSH_FLOAT rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.mul_float_deopt_repush:
    VUNDROP 2
.mul_float_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_mul_float

;; ============================================================================
;; op_binary_op_truediv_float - Specialized float truediv (opcode 220)
;; ============================================================================
DEF_FUNC_BARE op_binary_op_truediv_float
    VPOP_VAL rsi, r8            ; right + tag
    VPOP_VAL rdi, r9            ; left + tag
    cmp r9d, TAG_FLOAT
    jne .truediv_float_deopt_repush
    cmp r8d, TAG_FLOAT
    jne .truediv_float_deopt_repush
    ; Check for division by zero
    movq xmm1, rsi
    xorpd xmm2, xmm2
    ucomisd xmm1, xmm2
    je .truediv_float_deopt_repush  ; zero divisor → deopt to generic (raises ZeroDivisionError)
    movq xmm0, rdi
    divsd xmm0, xmm1
    movq rax, xmm0
    VPUSH_FLOAT rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.truediv_float_deopt_repush:
    VUNDROP 2
.truediv_float_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_truediv_float

;; ============================================================================
;; op_binary_op_mul_int - Specialized SmallInt multiply (opcode 221)
;;
;; Guard: both TOS and TOS1 must be SmallInt.
;; On guard failure: deopt back to BINARY_OP (122).
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_binary_op_mul_int
    VPOP_VAL rsi, r8            ; right + tag
    VPOP_VAL rdi, r9            ; left + tag
    cmp r9d, TAG_SMALLINT
    jne .mul_int_deopt_repush
    cmp r8d, TAG_SMALLINT
    jne .mul_int_deopt_repush
    mov rax, rdi
    imul rsi
    jo .mul_int_deopt_repush_vals
    VPUSH_INT rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.mul_int_deopt_repush_vals:
    ; imul clobbered rax/rdx, use saved values
    VPUSH_VAL rdi, r9
    VPUSH_VAL rsi, r8
    jmp .mul_int_deopt
.mul_int_deopt_repush:
    VUNDROP 2
.mul_int_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_mul_int

;; ============================================================================
;; op_binary_op_floordiv_int - Specialized SmallInt floor divide (opcode 222)
;;
;; Guard: both TOS and TOS1 must be SmallInt, right != 0.
;; On guard failure: deopt back to BINARY_OP (122).
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_binary_op_floordiv_int
    VPOP_VAL rsi, r8            ; right + tag
    VPOP_VAL rdi, r9            ; left + tag
    ; Guard: both SmallInt
    cmp r9d, TAG_SMALLINT
    jne .fdiv_int_deopt_repush
    cmp r8d, TAG_SMALLINT
    jne .fdiv_int_deopt_repush
    ; Guard: right != 0
    test rsi, rsi
    jz .fdiv_int_deopt_repush
    ; Floor divide
    mov rax, rdi
    cqo
    idiv rsi                    ; rax=quotient, rdx=remainder
    ; Floor: if remainder != 0 and signs differ, subtract 1
    test rdx, rdx
    jz .fdiv_int_exact
    mov rcx, rdi
    xor rcx, rsi
    jns .fdiv_int_exact         ; same sign → truncation == floor
    dec rax
.fdiv_int_exact:
    VPUSH_INT rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.fdiv_int_deopt_repush:
    VUNDROP 2
.fdiv_int_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_floordiv_int

;; ============================================================================
;; op_compare_op_int - Specialized SmallInt comparison (opcode 209)
;;
;; Guard: both TOS and TOS1 must be SmallInt (tag-based).
;; On guard failure: deopt back to COMPARE_OP (107).
;; ecx = arg (comparison op = arg >> 4)
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_compare_op_int
    shr ecx, 4                 ; ecx = comparison op (0-5)
    VPOP_VAL rsi, r8            ; right + tag
    VPOP_VAL rdi, r9            ; left + tag
    ; Guard: both SmallInt (tag-based)
    cmp r9d, TAG_SMALLINT
    jne .cmp_int_deopt_repush
    cmp r8d, TAG_SMALLINT
    jne .cmp_int_deopt_repush
    ; Compare
    cmp rdi, rsi               ; flags survive LEA + jmp [mem]
    lea r8, [rel .ci_setcc_table]
    jmp [r8 + rcx*8]          ; 1 indirect branch on comparison op

.ci_set_lt:
    setl al
    jmp .ci_push_bool
.ci_set_le:
    setle al
    jmp .ci_push_bool
.ci_set_eq:
    sete al
    jmp .ci_push_bool
.ci_set_ne:
    setne al
    jmp .ci_push_bool
.ci_set_gt:
    setg al
    jmp .ci_push_bool
.ci_set_ge:
    setge al
    ; fall through to .ci_push_bool

.ci_push_bool:
    movzx eax, al             ; eax = 0 or 1
    VPUSH_BOOL rax             ; (0/1, TAG_BOOL) — no INCREF needed
    add rbx, 2                ; skip CACHE
    DISPATCH

section .data
align 8
.ci_setcc_table:
    dq .ci_set_lt              ; PY_LT = 0
    dq .ci_set_le              ; PY_LE = 1
    dq .ci_set_eq              ; PY_EQ = 2
    dq .ci_set_ne              ; PY_NE = 3
    dq .ci_set_gt              ; PY_GT = 4
    dq .ci_set_ge              ; PY_GE = 5
section .text
.cmp_int_deopt_repush:
    ; Re-push operands (slots still intact — just restore stack pointer)
    VUNDROP 2
.cmp_int_deopt:
    ; Rewrite back to COMPARE_OP (107) and re-execute
    mov byte [rbx - 2], 107
    sub rbx, 2
    DISPATCH
END_FUNC op_compare_op_int

;; ============================================================================
;; op_compare_op_int_jump_false - Fused COMPARE_OP_INT + POP_JUMP_IF_FALSE (215)
;;
;; Guard: both TOS and TOS1 must be SmallInt.
;; On guard failure: deopt back to COMPARE_OP (107).
;; ecx = arg (comparison op = arg >> 4).
;; Followed by 1 CACHE entry (2 bytes), then POP_JUMP_IF_FALSE (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_compare_op_int_jump_false
    shr ecx, 4                 ; ecx = comparison op (0-5)
    VPOP_VAL rsi, r8            ; right + tag
    VPOP_VAL rdi, r9            ; left + tag
    ; Guard: both SmallInt
    cmp r9d, TAG_SMALLINT
    jne .cijf_deopt_repush
    cmp r8d, TAG_SMALLINT
    jne .cijf_deopt_repush
    ; Read jump target from POP_JUMP_IF_FALSE arg (at rbx+3)
    movzx r8d, byte [rbx + 3]
    ; Compare
    cmp rdi, rsi
    lea r9, [rel .cijf_setcc_table]
    jmp [r9 + rcx*8]

.cijf_lt:
    setl al
    jmp .cijf_branch
.cijf_le:
    setle al
    jmp .cijf_branch
.cijf_eq:
    sete al
    jmp .cijf_branch
.cijf_ne:
    setne al
    jmp .cijf_branch
.cijf_gt:
    setg al
    jmp .cijf_branch
.cijf_ge:
    setge al
    ; fall through
.cijf_branch:
    ; Skip CACHE (2) + POP_JUMP_IF_FALSE (2) = 4 bytes
    add rbx, 4
    test al, al
    jnz .cijf_no_jump          ; truthy → don't jump (POP_JUMP_IF_FALSE)
    lea rbx, [rbx + r8*2]     ; jump (r8 = target offset)
.cijf_no_jump:
    DISPATCH

section .data
align 8
.cijf_setcc_table:
    dq .cijf_lt                ; PY_LT = 0
    dq .cijf_le                ; PY_LE = 1
    dq .cijf_eq                ; PY_EQ = 2
    dq .cijf_ne                ; PY_NE = 3
    dq .cijf_gt                ; PY_GT = 4
    dq .cijf_ge                ; PY_GE = 5
section .text

.cijf_deopt_repush:
    VUNDROP 2
    mov byte [rbx - 2], 107   ; deopt to COMPARE_OP
    sub rbx, 2
    DISPATCH
END_FUNC op_compare_op_int_jump_false

;; ============================================================================
;; op_compare_op_int_jump_true - Fused COMPARE_OP_INT + POP_JUMP_IF_TRUE (216)
;;
;; Same as above but jumps when comparison is TRUE.
;; ============================================================================
DEF_FUNC_BARE op_compare_op_int_jump_true
    shr ecx, 4                 ; ecx = comparison op (0-5)
    VPOP_VAL rsi, r8            ; right + tag
    VPOP_VAL rdi, r9            ; left + tag
    ; Guard: both SmallInt
    cmp r9d, TAG_SMALLINT
    jne .cijt_deopt_repush
    cmp r8d, TAG_SMALLINT
    jne .cijt_deopt_repush
    ; Read jump target from POP_JUMP_IF_TRUE arg (at rbx+3)
    movzx r8d, byte [rbx + 3]
    ; Compare
    cmp rdi, rsi
    lea r9, [rel .cijt_setcc_table]
    jmp [r9 + rcx*8]

.cijt_lt:
    setl al
    jmp .cijt_branch
.cijt_le:
    setle al
    jmp .cijt_branch
.cijt_eq:
    sete al
    jmp .cijt_branch
.cijt_ne:
    setne al
    jmp .cijt_branch
.cijt_gt:
    setg al
    jmp .cijt_branch
.cijt_ge:
    setge al
    ; fall through
.cijt_branch:
    ; Skip CACHE (2) + POP_JUMP_IF_TRUE (2) = 4 bytes
    add rbx, 4
    test al, al
    jz .cijt_no_jump           ; falsy → don't jump (POP_JUMP_IF_TRUE)
    lea rbx, [rbx + r8*2]     ; jump (r8 = target offset)
.cijt_no_jump:
    DISPATCH

section .data
align 8
.cijt_setcc_table:
    dq .cijt_lt                ; PY_LT = 0
    dq .cijt_le                ; PY_LE = 1
    dq .cijt_eq                ; PY_EQ = 2
    dq .cijt_ne                ; PY_NE = 3
    dq .cijt_gt                ; PY_GT = 4
    dq .cijt_ge                ; PY_GE = 5
section .text

.cijt_deopt_repush:
    VUNDROP 2
    mov byte [rbx - 2], 107   ; deopt to COMPARE_OP
    sub rbx, 2
    DISPATCH
END_FUNC op_compare_op_int_jump_true
