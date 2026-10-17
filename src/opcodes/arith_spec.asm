; opcodes/arith_spec.asm - the specialized arithmetic and comparison opcodes
;
; The superinstructions op_binary_op and op_compare_op rewrite themselves into
; once they have seen what their operands actually are.  Each guards the shape
; it was specialized for, does the work in registers, and on a guard failure
; writes the generic opcode back and re-dispatches.
;
;   211/212/221/222/226/227/228/229  int add, subtract, multiply, floor divide,
;                                    and, or, xor, remainder
;   217/218/219/220                  float add, subtract, multiply, divide
;   209/215/216                      int compare, and the two fused with the
;                                    jump that follows
;   223/224/225                      the same three for floats
;
; Split out of arith.asm, which keeps the generic protocol and the error
; messages, because that file reached lint's 100k cap.  Nothing here calls
; into arith.asm's file-local helpers -- the deopts write an opcode byte and
; re-dispatch rather than jumping to a label.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

extern opcode_dispatch_table
extern str_type
extern obj_dealloc
extern ap_realloc
extern ap_memcpy
extern bool_true
extern bool_false
extern op_binary_op
extern op_compare_op

section .text

;; ============================================================================
;; op_binary_op_add_int (211) -> nothing; pushes the sum and dispatches
;;
;; Guard: both TOS and TOS1 must be SmallInt (tag-based).
;; On guard failure: deopt back to BINARY_OP (122).
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_binary_op_add_int
    INT_PAIR_OR_DEOPT .add_int_deopt
    ; vl + vr - bias = (l + r) - bias, the biased sum.  The same
    ; `>= V_INT_LO` test that classified the operands now classifies the
    ; answer, and a sum outside +-2^50 fails it in either direction.
    add rax, rdx
    sub rax, [rel v_int_bias]
    cmp rax, [rel v_int_lo]
    jb .add_int_deopt
    VREPLACE2 rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.add_int_deopt:
    ; Rewrite opcode back to BINARY_OP (122) and re-execute.  Nothing was
    ; popped, so there is nothing to put back.
    ;
    ; Rewinding rbx is only safe because BINARY_OP and COMPARE_OP arguments are
    ; small -- an operator index, and a comparison plus its mask -- so neither
    ; is ever preceded by EXTENDED_ARG.  The deopts that carry a real offset or
    ; a name index cannot do this; see .fir_deopt in opcodes/build.asm.
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_add_int

;; ============================================================================
;; op_binary_op_sub_int (212) -> nothing; pushes the difference and dispatches
;;
;; Guard: both TOS and TOS1 must be SmallInt (tag-based).
;; On guard failure: deopt back to BINARY_OP (122).
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_binary_op_sub_int
    INT_PAIR_OR_DEOPT .sub_int_deopt
    sub rdx, rax
    add rdx, [rel v_int_bias]
    cmp rdx, [rel v_int_lo]
    jb .sub_int_deopt
    VREPLACE2 rdx
    add rbx, 2                 ; skip CACHE
    DISPATCH
.sub_int_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_sub_int

;; ============================================================================
;; op_binary_op_add_float (217) -> nothing; pushes the sum and dispatches
;;
;; Guard: both TOS and TOS1 must be TAG_FLOAT.
;; On guard failure: deopt back to BINARY_OP (122).
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_binary_op_add_float
    FLOAT_PAIR_OR_DEOPT_M .add_float_deopt
    addsd xmm0, xmm1
    movq rax, xmm0
    V_FROM_F64 rax, rdx
    VREPLACE2 rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.add_float_deopt:
    ; Nothing was popped, so there is nothing to put back.
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_add_float

;; ============================================================================
;; op_binary_op_sub_float (218) -> nothing; pushes the difference and dispatches
;; ============================================================================
DEF_FUNC_BARE op_binary_op_sub_float
    FLOAT_PAIR_OR_DEOPT_M .sub_float_deopt
    subsd xmm0, xmm1
    movq rax, xmm0
    V_FROM_F64 rax, rdx
    VREPLACE2 rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.sub_float_deopt:
    ; Nothing was popped, so there is nothing to put back.
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_sub_float

;; ============================================================================
;; op_binary_op_mul_float (219) -> nothing; pushes the product and dispatches
;; ============================================================================
DEF_FUNC_BARE op_binary_op_mul_float
    FLOAT_PAIR_OR_DEOPT_M .mul_float_deopt
    mulsd xmm0, xmm1
    movq rax, xmm0
    V_FROM_F64 rax, rdx
    VREPLACE2 rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.mul_float_deopt:
    ; Nothing was popped, so there is nothing to put back.
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_mul_float

;; ============================================================================
;; op_binary_op_truediv_float (220) -> nothing; pushes the quotient and dispatches
;; ============================================================================
DEF_FUNC_BARE op_binary_op_truediv_float
    FLOAT_PAIR_OR_DEOPT_M .truediv_float_deopt
    ; A zero divisor has to raise, and the generic path is what raises.
    ; ucomisd sets ZF for UNORDERED too, so parity is consulted first: a NaN
    ; divisor is not a zero one, and treating it as one refused to specialize
    ; the site for the rest of the program.
    xorpd xmm2, xmm2
    ucomisd xmm1, xmm2
    jp .truediv_float_nonzero
    je .truediv_float_deopt
.truediv_float_nonzero:
    divsd xmm0, xmm1
    movq rax, xmm0
    V_FROM_F64 rax, rdx
    VREPLACE2 rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.truediv_float_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_truediv_float

;; ============================================================================
;; op_binary_op_mul_int (221) -> nothing; pushes the product and dispatches
;;
;; Guard: both TOS and TOS1 must be SmallInt.
;; On guard failure: deopt back to BINARY_OP (122).
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_binary_op_mul_int
    INT_PAIR_OR_DEOPT .mul_int_deopt
    ; Multiply is the first of these that has to decode: the product of two
    ; biased Values is not the biased product.  One `sub` a side.
    sub rax, [rel v_int_bias]
    sub rdx, [rel v_int_bias]
    imul rax, rdx
    jo .mul_int_deopt
    ; CPython needs no overflow check here at all -- 30 + 30 fits an int64.
    ; +-2^50 does not, so both the `jo` and the range test are real work.
    V_FROM_I64 rax, rdx, .mul_int_deopt
    VREPLACE2 rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.mul_int_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_mul_int

;; ============================================================================
;; op_binary_op_floordiv_int (222) -> nothing; pushes the quotient and dispatches
;;
;; Guard: both TOS and TOS1 must be SmallInt, right != 0.
;; On guard failure: deopt back to BINARY_OP (122).
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_binary_op_floordiv_int
    INT_PAIR_OR_DEOPT .fdiv_int_deopt
    sub rax, [rel v_int_bias]
    jz .fdiv_int_deopt          ; zero divisor: let the generic path raise
    sub rdx, [rel v_int_bias]
    mov rcx, rax                ; divisor
    mov rax, rdx                ; dividend
    cqo
    idiv rcx                    ; rax = quotient, rdx = remainder
    ; Floor: the remainder carries the DIVIDEND's sign, so a remainder that
    ; disagrees with the divisor means truncation rounded the wrong way.
    test rdx, rdx
    jz .fdiv_int_exact
    xor rdx, rcx
    jns .fdiv_int_exact         ; same sign -> truncation == floor
    dec rax
.fdiv_int_exact:
    ; -2^50 // -1 is 2^50, one past the immediate range: still range-checked.
    V_FROM_I64 rax, rdx, .fdiv_int_deopt
    VREPLACE2 rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.fdiv_int_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_floordiv_int

;; ============================================================================
;; op_compare_op_int (209) -> nothing; pushes the bool and dispatches
;;
;; Guard: both TOS and TOS1 must be SmallInt (tag-based).
;; On guard failure: deopt back to COMPARE_OP (107).
;; ecx = arg (comparison op = arg >> 4)
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================

;; ============================================================================
;; The integer comparison superinstructions (209, 215, 216)
;;
;; These decode nothing.  An integer immediate is `i - 2^50` modulo 2^64, and
;; over i in [-2^50, 2^50) that encoding is strictly increasing as an UNSIGNED
;; 64-bit number without wrapping -- so `cmp` on the two raw Values, read
;; unsigned, already IS the signed comparison of the integers they stand for.
;; The old form unpacked both into (payload, tag) pairs first, twenty
;; instructions, purely to synthesise a TAG_SMALLINT the next two compared
;; against.
;;
;; The answer is then taken branchlessly, after CPython's COMPARISON_BIT
;; (Include/internal/pycore_code.h).  `2*(x>=y) + (x<=y)` is 1 for less, 2 for
;; greater and 3 for equal -- 0 means unordered, which only floats produce --
;; so one byte table indexed by `op*4 + that` answers all six operators with a
;; single load, no branch, and no BTB entry for the indirect jump the setcc
;; table used to need.
;;
;; The bool is selected with cmov for the same reason: an `i < 1000` whose
;; answer changes once in a loop should not cost a mispredict where a cmov
;; costs nothing.
;; ============================================================================
section .rodata
align 16
;; op*4 + (2*(x>=y) + (x<=y)).  Column 0 is the unordered case, which only a
;; NaN produces, so the integer forms never index it and the float forms
;; always do when either operand is a NaN.
global int_cmp_result
int_cmp_result:
    db 0, 1, 0, 0               ; PY_LT = 0
    db 0, 1, 0, 1               ; PY_LE = 1
    db 0, 0, 0, 1               ; PY_EQ = 2
    db 1, 1, 1, 0               ; PY_NE = 3  -- 1 in the unordered column,
                                ;   because NaN != anything is the one
                                ;   comparison a NaN answers True
    db 0, 0, 1, 0               ; PY_GT = 4
    db 0, 0, 1, 1               ; PY_GE = 5
section .text

;; ============================================================================
;; op_compare_op_int (209) -> nothing; replaces the pair with a bool
;;
;; ecx = arg (comparison op = arg >> 4).  Followed by 1 CACHE entry.
;; On guard failure: deopt back to COMPARE_OP (107).
;; ============================================================================
DEF_FUNC_BARE op_compare_op_int
    shr ecx, 4                  ; ecx = comparison op (0-5)
    INT_PAIR_OR_DEOPT .cmp_int_deopt
    ; cmp on the biased Values, read unsigned, is the signed comparison
    cmp rdx, rax
    setae al                    ; x >= y
    setbe dl                    ; x <= y
    movzx eax, al
    movzx edx, dl
    lea eax, [rdx + rax*2]      ; 1 = less, 2 = greater, 3 = equal
    lea eax, [rax + rcx*4]      ; + op*4
    lea rdx, [rel int_cmp_result]
    movzx eax, byte [rdx + rax]
    VREPLACE2_BOOL rax, rdx
    add rbx, 2                  ; skip CACHE
    DISPATCH
.cmp_int_deopt:
    ; Rewrite back to COMPARE_OP (107) and re-execute; the operands are
    ; untouched, because nothing was popped.
    mov byte [rbx - 2], 107
    sub rbx, 2
    DISPATCH
END_FUNC op_compare_op_int

;; ============================================================================
;; op_binary_op_and_int (226) -> nothing; pushes the result and dispatches
;;
;; Guard: both operands TAG_SMALLINT.  There is no overflow arm -- see the
;; note on .binop_try_smallint_and above for why a bitwise op on two
;; immediates is always an immediate.
;; ============================================================================
DEF_FUNC_BARE op_binary_op_and_int
    INT_PAIR_OR_DEOPT .and_int_deopt
    sub rax, [rel v_int_bias]
    sub rdx, [rel v_int_bias]
    and rax, rdx
    add rax, [rel v_int_bias]
    VREPLACE2 rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.and_int_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_and_int

;; ============================================================================
;; op_binary_op_or_int (227) -> nothing; pushes the result and dispatches
;;
;; Guard: both operands TAG_SMALLINT.  There is no overflow arm -- see the
;; note on .binop_try_smallint_and above for why a bitwise op on two
;; immediates is always an immediate.
;; ============================================================================
DEF_FUNC_BARE op_binary_op_or_int
    INT_PAIR_OR_DEOPT .or_int_deopt
    sub rax, [rel v_int_bias]
    sub rdx, [rel v_int_bias]
    or rax, rdx
    add rax, [rel v_int_bias]
    VREPLACE2 rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.or_int_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_or_int

;; ============================================================================
;; op_binary_op_xor_int (228) -> nothing; pushes the result and dispatches
;;
;; Guard: both operands TAG_SMALLINT.  There is no overflow arm -- see the
;; note on .binop_try_smallint_and above for why a bitwise op on two
;; immediates is always an immediate.
;; ============================================================================
DEF_FUNC_BARE op_binary_op_xor_int
    INT_PAIR_OR_DEOPT .xor_int_deopt
    sub rax, [rel v_int_bias]
    sub rdx, [rel v_int_bias]
    xor rax, rdx
    add rax, [rel v_int_bias]
    VREPLACE2 rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.xor_int_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_xor_int

;; ============================================================================
;; op_binary_op_mod_int (229) -> nothing; pushes the result and dispatches
;;
;; Guards: both operands TAG_SMALLINT, and a non-zero divisor -- a zero one
;; deopts so the generic path raises ZeroDivisionError.
;;
;; `idiv` gives C's remainder, which carries the DIVIDEND's sign; Python's
;; carries the DIVISOR's.  A remainder that disagrees with the divisor gets the
;; divisor added.  The magnitude stays below the divisor's, so the answer is
;; still an immediate.
;;
;; INT64_MIN / -1 would fault, but neither operand can be INT64_MIN: an
;; immediate is inside +-2^50.
;; ============================================================================
DEF_FUNC_BARE op_binary_op_mod_int
    INT_PAIR_OR_DEOPT .mod_int_deopt
    sub rax, [rel v_int_bias]
    jz .mod_int_deopt           ; zero divisor: let the generic path raise
    sub rdx, [rel v_int_bias]
    mov rcx, rax                ; divisor
    mov rax, rdx                ; dividend
    cqo
    idiv rcx
    test rdx, rdx
    jz .mod_int_done
    mov rsi, rdx
    xor rsi, rcx
    jns .mod_int_done
    add rdx, rcx
.mod_int_done:
    ; |result| < |divisor| <= 2^50, so the answer is always an immediate.
    add rdx, [rel v_int_bias]
    VREPLACE2 rdx
    add rbx, 2
    DISPATCH
.mod_int_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_mod_int

;; ============================================================================
;; op_binary_op_lshift_int (230) -> nothing; pushes the result and dispatches
;;
;; Guards: both operands immediates, a shift count in [0, 51), and no bits
;; lost off the top.  A count of 51 or more cannot fit even a left operand of
;; 1, and a negative one raises, so both go to the generic path.
;;
;; The loss check shifts the answer arithmetically back and compares: bits
;; that fell off the top do not come back, and `sar` restores a negative left
;; operand correctly too.  A shift that survives it can still be outside
;; +-2^50, so the immediate range is checked after.
;; ============================================================================
DEF_FUNC_BARE op_binary_op_lshift_int
    INT_PAIR_OR_DEOPT .lsh_int_deopt
    sub rax, [rel v_int_bias]   ; the shift count
    cmp rax, V_INT_SHIFT + 1
    jae .lsh_int_deopt
    sub rdx, [rel v_int_bias]   ; the left operand
    mov rcx, rax
    mov r8, rdx
    shl rdx, cl
    mov rsi, rdx
    sar rsi, cl
    cmp rsi, r8
    jne .lsh_int_deopt          ; bits fell off the top
    V_FROM_I64 rdx, rax, .lsh_int_deopt
    VREPLACE2 rdx
    add rbx, 2                 ; skip CACHE
    DISPATCH
.lsh_int_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_lshift_int

;; ============================================================================
;; op_binary_op_rshift_int (231) -> nothing; pushes the result and dispatches
;;
;; Guards: both operands immediates and a shift count in [0, 64).  `sar`
;; floors, which is what Python's `>>` does, and the result cannot leave the
;; immediate range because its magnitude never exceeds the left operand's.
;; ============================================================================
DEF_FUNC_BARE op_binary_op_rshift_int
    INT_PAIR_OR_DEOPT .rsh_int_deopt
    sub rax, [rel v_int_bias]   ; the shift count
    cmp rax, 64
    jae .rsh_int_deopt          ; negative (which raises), or 64 and up
    sub rdx, [rel v_int_bias]
    mov rcx, rax
    sar rdx, cl
    add rdx, [rel v_int_bias]
    VREPLACE2 rdx
    add rbx, 2                 ; skip CACHE
    DISPATCH
.rsh_int_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_rshift_int

;; ============================================================================
;; op_binary_op_pow_int (232) -> nothing; pushes the result and dispatches
;;
;; Guards: both operands immediates, a non-negative exponent below 64, and no
;; overflow in the squaring.  A negative exponent answers a float and belongs
;; to the generic path; CPython specializes `**` for nothing at all.
;;
;; The base is squared only while another exponent bit remains, so an overflow
;; in a squaring whose value would never have been used cannot send a result
;; that fitted to GMP.
;; ============================================================================
DEF_FUNC_BARE op_binary_op_pow_int
    INT_PAIR_OR_DEOPT .pow_int_deopt
    sub rax, [rel v_int_bias]   ; the exponent
    js .pow_int_deopt
    cmp rax, 64
    jae .pow_int_deopt
    sub rdx, [rel v_int_bias]   ; the base
    mov rsi, rdx                ; b, the running square
    mov rcx, rax                ; e, the remaining exponent
    mov eax, 1                      ; the running result
.pow_int_loop:
    test rcx, rcx
    jz .pow_int_fits
    test cl, 1
    jz .pow_int_square
    imul rax, rsi
    jo .pow_int_deopt
.pow_int_square:
    shr rcx, 1
    jz .pow_int_fits
    imul rsi, rsi
    jo .pow_int_deopt
    jmp .pow_int_loop
.pow_int_fits:
    V_FROM_I64 rax, rdx, .pow_int_deopt
    VREPLACE2 rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.pow_int_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_pow_int

;; ============================================================================
;; op_binary_op_truediv_int (233) -> nothing; pushes the quotient, a float
;;
;; Guards: both operands immediates and a non-zero divisor.  Both are inside
;; +-2^50, so each converts to a double exactly, and IEEE division of two
;; exact doubles is correctly rounded -- the same answer CPython's
;; long_true_divide reaches by scaling and rounding by hand.  The quotient is
;; between 2^-50 and 2^50 in magnitude, so neither an overflow nor a
;; subnormal is reachable.
;; ============================================================================
DEF_FUNC_BARE op_binary_op_truediv_int
    INT_PAIR_OR_DEOPT .tdiv_int_deopt
    sub rax, [rel v_int_bias]
    jz .tdiv_int_deopt          ; zero divisor: let the generic path raise
    sub rdx, [rel v_int_bias]
    cvtsi2sd xmm0, rdx
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    movq rax, xmm0
    V_FROM_F64 rax, rdx
    VREPLACE2 rax
    add rbx, 2                 ; skip CACHE
    DISPATCH
.tdiv_int_deopt:
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_truediv_int

;; ============================================================================
;; op_compare_op_float (223) -> nothing; pushes the bool and dispatches
;;
;; The float comparison superinstructions (223, 224, 225).
;;
;; op_compare_op had a both-SmallInt arm and nothing else, so a pair of float
;; immediates fell through to the general protocol: float_binop_accepts, then
;; float_compare, which calls float_binop_accepts twice more, fc_wide_int
;; twice and float_to_f64 twice -- about nine calls and four pack/unpack round
;; trips to reach one ucomisd.  It was the only float operation not already
;; ahead of CPython.
;;
;; These read the two Values straight off the stack and guard on the raw
;; high16, so nothing is unpacked into a (payload, tag) pair and re-packed;
;; the deopt is therefore just a rewrite, with the operands still in place.
;;
;; NaN is the one thing the integer forms do not have to think about.
;; `ucomisd` reports unordered as ZF=1, PF=1, CF=1, so `seta`/`setae` are
;; already false for it, while `setb`/`setbe`/`sete` would each be wrongly
;; true and `setne` wrongly false.  Those four are corrected with the parity
;; flag: AND with `setnp` for the three that must become false, OR with
;; `setp` for the one that must become true.
;; ============================================================================
DEF_FUNC_BARE op_compare_op_float
    shr ecx, 4                  ; ecx = PY_LT/LE/EQ/NE/GT/GE (0-5)
    FLOAT_PAIR_OR_DEOPT_M .cf_deopt
    ucomisd xmm0, xmm1
    setae al                    ; x >= y -- already false when unordered
    setbe dl                    ; x <= y -- wrongly TRUE when unordered, so
    setnp r8b                   ;   mask it with "the pair was ordered"
    and dl, r8b
    movzx eax, al
    movzx edx, dl
    lea eax, [rdx + rax*2]      ; 0 = unordered, 1 = less, 2 = greater, 3 = equal
    lea eax, [rax + rcx*4]      ; + op*4
    lea rdx, [rel int_cmp_result]
    movzx eax, byte [rdx + rax]
    VREPLACE2_BOOL rax, rdx
    add rbx, 2                  ; skip CACHE
    DISPATCH
.cf_deopt:
    ; Nothing was popped, so there is nothing to put back.
    mov byte [rbx - 2], 107     ; COMPARE_OP
    sub rbx, 2
    DISPATCH
END_FUNC op_compare_op_float

;; ============================================================================
;; op_compare_op_float_jump_false (224) -> nothing; branches and dispatches
;;
;; COMPARE_OP_FLOAT fused with the POP_JUMP_IF_FALSE that follows.  No bool
;; object is built at all: the flags decide the branch directly.
;; ============================================================================
DEF_FUNC_BARE op_compare_op_float_jump_false
    shr ecx, 4
    FLOAT_PAIR_OR_DEOPT_M .cfjf_deopt
    ucomisd xmm0, xmm1
    setae al                    ; x >= y -- already false when unordered
    setbe dl                    ; x <= y -- wrongly TRUE when unordered, so
    setnp r8b                   ;   mask it with "the pair was ordered"
    and dl, r8b
    movzx eax, al
    movzx edx, dl
    lea eax, [rdx + rax*2]      ; 0 = unordered, 1 = less, 2 = greater, 3 = equal
    lea eax, [rax + rcx*4]      ; + op*4
    lea rdx, [rel int_cmp_result]
    movzx eax, byte [rdx + rax]
    ; Skip CACHE (2) + POP_JUMP_IF_FALSE (2) = 4 bytes; its arg is at rbx+3.
    movzx edx, byte [rbx + 3]
    add rbx, 4
    test al, al
    jnz .cfjf_no_jump              ; truthy -> do not jump
    lea rbx, [rbx + rdx*2]
.cfjf_no_jump:
    VDROP 2                     ; both operands are immediates
    DISPATCH
.cfjf_deopt:
    mov byte [rbx - 2], 107
    sub rbx, 2
    DISPATCH
END_FUNC op_compare_op_float_jump_false

;; ============================================================================
;; op_compare_op_float_jump_true (225) -> nothing; branches and dispatches
;;
;; The same fused with POP_JUMP_IF_TRUE, so the branch is taken when the
;; comparison holds rather than when it does not.
;; ============================================================================
DEF_FUNC_BARE op_compare_op_float_jump_true
    shr ecx, 4
    FLOAT_PAIR_OR_DEOPT_M .cfjt_deopt
    ucomisd xmm0, xmm1
    setae al                    ; x >= y -- already false when unordered
    setbe dl                    ; x <= y -- wrongly TRUE when unordered, so
    setnp r8b                   ;   mask it with "the pair was ordered"
    and dl, r8b
    movzx eax, al
    movzx edx, dl
    lea eax, [rdx + rax*2]      ; 0 = unordered, 1 = less, 2 = greater, 3 = equal
    lea eax, [rax + rcx*4]      ; + op*4
    lea rdx, [rel int_cmp_result]
    movzx eax, byte [rdx + rax]
    ; Skip CACHE (2) + POP_JUMP_IF_TRUE (2) = 4 bytes; its arg is at rbx+3.
    movzx edx, byte [rbx + 3]
    add rbx, 4
    test al, al
    jz .cfjt_no_jump              ; falsy -> do not jump
    lea rbx, [rbx + rdx*2]
.cfjt_no_jump:
    VDROP 2                     ; both operands are immediates
    DISPATCH
.cfjt_deopt:
    mov byte [rbx - 2], 107
    sub rbx, 2
    DISPATCH
END_FUNC op_compare_op_float_jump_true

;; ============================================================================
;; op_compare_op_int_jump_false (215) -> nothing; branches and dispatches
;;
;; Guard: both TOS and TOS1 must be SmallInt.
;; On guard failure: deopt back to COMPARE_OP (107).
;; ecx = arg (comparison op = arg >> 4).
;; Followed by 1 CACHE entry (2 bytes), then POP_JUMP_IF_FALSE (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_compare_op_int_jump_false
    shr ecx, 4                  ; ecx = comparison op (0-5)
    INT_PAIR_OR_DEOPT .cijf_deopt
    ; cmp on the biased Values, read unsigned, is the signed comparison
    cmp rdx, rax
    setae al                    ; x >= y
    setbe dl                    ; x <= y
    movzx eax, al
    movzx edx, dl
    lea eax, [rdx + rax*2]      ; 1 = less, 2 = greater, 3 = equal
    lea eax, [rax + rcx*4]      ; + op*4
    lea rdx, [rel int_cmp_result]
    movzx eax, byte [rdx + rax]
    ; Skip CACHE (2) + POP_JUMP_IF_FALSE (2) = 4 bytes; its arg is at rbx+3.
    movzx edx, byte [rbx + 3]
    add rbx, 4
    test al, al
    jnz .cijf_no_jump           ; truthy -> do not jump
    lea rbx, [rbx + rdx*2]
.cijf_no_jump:
    VDROP 2                     ; both operands are immediates
    DISPATCH
.cijf_deopt:
    mov byte [rbx - 2], 107     ; deopt to COMPARE_OP
    sub rbx, 2
    DISPATCH
END_FUNC op_compare_op_int_jump_false

;; ============================================================================
;; op_compare_op_int_jump_true (216) -> nothing; branches and dispatches
;;
;; Same as above but jumps when comparison is TRUE.
;; ============================================================================
DEF_FUNC_BARE op_compare_op_int_jump_true
    shr ecx, 4                  ; ecx = comparison op (0-5)
    INT_PAIR_OR_DEOPT .cijt_deopt
    ; cmp on the biased Values, read unsigned, is the signed comparison
    cmp rdx, rax
    setae al                    ; x >= y
    setbe dl                    ; x <= y
    movzx eax, al
    movzx edx, dl
    lea eax, [rdx + rax*2]      ; 1 = less, 2 = greater, 3 = equal
    lea eax, [rax + rcx*4]      ; + op*4
    lea rdx, [rel int_cmp_result]
    movzx eax, byte [rdx + rax]
    movzx edx, byte [rbx + 3]
    add rbx, 4
    test al, al
    jz .cijt_no_jump            ; falsy -> do not jump
    lea rbx, [rbx + rdx*2]
.cijt_no_jump:
    VDROP 2                     ; both operands are immediates
    DISPATCH
.cijt_deopt:
    mov byte [rbx - 2], 107     ; deopt to COMPARE_OP
    sub rbx, 2
    DISPATCH
END_FUNC op_compare_op_int_jump_true

;; ============================================================================
;; op_binary_op_inplace_add_unicode (234) -> nothing; appends and dispatches
;;
;; `s = s + t` and `s += t` where s is a local.  Building a new string each
;; time makes an accumulation loop quadratic; appending into the one the local
;; already holds makes it amortized linear, because realloc grows in place
;; when it can.  This is CPython's BINARY_OP_INPLACE_ADD_UNICODE.
;;
;; It swallows the STORE_FAST that follows it, which is what makes the whole
;; thing legal: the local is the only owner left after the stack reference is
;; dropped, so the object can be resized where it stands and the store the
;; STORE_FAST would have done has already happened.
;;
;; Guards, all of them load-bearing:
;;   - both operands are EXACT str.  A subclass may override __add__, and
;;     resizing one would not give it its own type back anyway.
;;   - the next instruction really is the STORE_FAST this was specialized
;;     for, and its local still holds the left operand.  The bytecode can be
;;     reached by a jump, and the specializer only ever saw one path to it.
;;   - refcount is exactly 2: this stack slot and that local, and nothing
;;     else.  `s += s` pushes s twice and so arrives at 3, which is the
;;     answer that keeps it correct.
;;   - ob_hash is -1.  A string that has ever been hashed may be sitting in
;;     some dict's bucket or some set, and the bucket describes bytes that
;;     are about to change.  This one is easy to leave out and impossible to
;;     find afterwards.
;;
;; Followed by 1 CACHE entry, then the 2-byte STORE_FAST: rbx advances by 4.
;; ============================================================================
DEF_FUNC_BARE op_binary_op_inplace_add_unicode
    mov rax, [r13 - 16]         ; left
    mov rdx, [r13 - 8]          ; right
    STR_PAIR_OR_DEOPT rax, rdx, .biau_deopt
    INPLACE_ADD_TARGET_OR_DEOPT rax, .biau_deopt

    ; --- append in place -----------------------------------------------
    ; The right operand has to survive both calls, and r15 is the handler
    ; scratch register that does.
    mov r15, rdx
    mov rdi, rax
    mov rsi, [rax + PyStrObject.ob_size]
    add rsi, [rdx + PyStrObject.ob_size]
    add rsi, PyStrObject.data + 8       ; header, and the readers' padding
    call ap_realloc                     ; fatal on failure; never returns 0

    ; realloc may have moved the object, and its header still describes the
    ; string as it was -- which is exactly what the copy offset needs.
    push rax
    push rax                            ; two slots: rsp stays 16-aligned
    mov rcx, [rax + PyStrObject.ob_size]
    lea rdi, [rax + PyStrObject.data + rcx]
    lea rsi, [r15 + PyStrObject.data]
    mov rdx, [r15 + PyStrObject.ob_size]
    call ap_memcpy
    pop rax
    pop rax

    ; Both lengths are additions.  Concatenating whole strings concatenates
    ; their code points, so nothing is rescanned.
    mov rcx, [r15 + PyStrObject.ob_size]
    add [rax + PyStrObject.ob_size], rcx
    mov rcx, [r15 + PyStrObject.ob_length]
    add [rax + PyStrObject.ob_length], rcx
    mov rcx, [rax + PyStrObject.ob_size]
    mov qword [rax + PyStrObject.data + rcx], 0
    ; ob_hash stays -1; the guard above is what says it already was.

    ; The local is the owner and the object may have moved, so it is the local
    ; that has to be rewritten -- which is the store the STORE_FAST would have
    ; made.  Its reference is the same one, relocated: no refcount change.
    movzx ecx, byte [rbx + 3]
    mov [r12 + PyFrame.localsplus + rcx*8], rax
    ; The stack's own reference to the left operand goes away.  It was 2 and
    ; the local holds the other, so this can never reach zero.
    dec qword [rax + PyObject.ob_refcnt]

    sub r13, 16                 ; both operands leave the stack
    DECREF_V r15, rcx
    add rbx, 4                  ; the CACHE, and the STORE_FAST just performed
    DISPATCH

.biau_deopt:
    ; Rewrite to BINARY_OP (122) and re-execute.  Nothing has been popped and
    ; nothing has been written; the guards are all reads.  Rewinding rbx is
    ; safe here for the same reason it is for the int arms: a BINARY_OP
    ; argument is an operator index and is never preceded by EXTENDED_ARG.
    mov byte [rbx - 2], 122
    sub rbx, 2
    DISPATCH
END_FUNC op_binary_op_inplace_add_unicode
