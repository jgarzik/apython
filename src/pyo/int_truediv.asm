; pyo/int_truediv.asm - int / int, rounded once
;
; Split out of int.asm, which reached lint's 100k cap for a hand-written file
; the moment this stopped being four instructions.  The seam is clean: this
; calls int_binop_unpack and the GMP entry points and nothing else file-local,
; and int.asm's number table names int_true_divide as an extern.
;
; The arithmetic is CPython's long_true_divide.  The old code turned each
; operand into a double and divided, which rounds THREE times -- mpz_get_d
; truncates toward zero, twice, and the division rounds again -- so
; (10**30) / 7 came back 1.4285714285714283e+29 where CPython answers
; ...285e+29, and 1 / 10**30 was out by an ulp the same way.

%include "macros.inc"
%include "object.inc"

ASM_INIT

extern int_binop_unpack
extern int_promote_mpz
extern raise_exception
extern exc_ZeroDivisionError_type
extern exc_OverflowError_type
extern __gmpz_init
extern __gmpz_clear
extern __gmpz_set
extern __gmpz_set_si
extern __gmpz_neg
extern __gmpz_cmp
extern __gmpz_cmp_si
extern __gmpz_sizeinbase
extern __gmpz_mul_2exp
extern __gmpz_fdiv_q_2exp
extern __gmpz_fdiv_r_2exp
extern __gmpz_tdiv_qr
extern __gmpz_setbit
extern __gmpz_tstbit
extern __gmpz_add_ui
extern __gmpz_get_d
extern ldexp

section .text

;; ============================================================================
;; True divide: int_true_divide(PyObject *a, PyObject *b) -> rax = Value (float)
;; int / int always returns float in Python, and the float is CORRECTLY
;; ROUNDED: the exact rational quotient rounded once, half to even, which is
;; what CPython's long_true_divide computes.
;; Fails: 0
;; ============================================================================
ITD_LTAG   equ 8
ITD_SIGN   equ 16
ITD_SHIFT  equ 24
ITD_DROP   equ 32
ITD_RESULT equ 40
ITD_A      equ 64              ; mpz_t, 16 bytes each
ITD_B      equ 80
ITD_Q      equ 96
ITD_R      equ 112
ITD_FRAME  equ 136             ; + 3 pushes = 160, 16-aligned
DEF_FUNC int_true_divide, ITD_FRAME
    ; This one never called int_unwrap at all, so an int subclass or a compact
    ; heap int on either side took the GMP path unnecessarily; routing through
    ; int_binop_unpack fixes that as well as rejecting foreign operands.
    push rbx
    push r12
    push r13
    call int_binop_unpack       ; rdi/edx = left, rsi/ecx = right, both ints
    test eax, eax
    jnz .itd_operands_ok
    xor eax, eax                ; NULL Value = NotImplemented
    pop r13
    pop r12
    pop rbx
    leave
    ret

.itd_operands_ok:
    mov rbx, rdi                ; left
    mov r12, rsi                ; right
    mov r13d, ecx               ; right tag
    mov [rbp - ITD_LTAG], rdx

    ; --- both operands into mpz_t, whatever they arrived as -------------
    lea rdi, [rbp - ITD_A]
    call __gmpz_init wrt ..plt
    lea rdi, [rbp - ITD_B]
    call __gmpz_init wrt ..plt
    lea rdi, [rbp - ITD_Q]
    call __gmpz_init wrt ..plt
    lea rdi, [rbp - ITD_R]
    call __gmpz_init wrt ..plt

    cmp qword [rbp - ITD_LTAG], TAG_SMALLINT
    jne .itd_a_heap
    lea rdi, [rbp - ITD_A]
    mov rsi, rbx
    call __gmpz_set_si wrt ..plt
    jmp .itd_have_a
.itd_a_heap:
    INT_NEED_MPZ rbx
    lea rdi, [rbp - ITD_A]
    lea rsi, [rbx + PyIntObject.mpz]
    call __gmpz_set wrt ..plt
.itd_have_a:
    cmp r13d, TAG_SMALLINT
    jne .itd_b_heap
    lea rdi, [rbp - ITD_B]
    mov rsi, r12
    call __gmpz_set_si wrt ..plt
    jmp .itd_have_b
.itd_b_heap:
    INT_NEED_MPZ r12
    lea rdi, [rbp - ITD_B]
    lea rsi, [r12 + PyIntObject.mpz]
    call __gmpz_set wrt ..plt
.itd_have_b:

    ; --- zero divisor, and a zero dividend ------------------------------
    lea rdi, [rbp - ITD_B]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    jz .itd_divzero

    ; The sign of the answer, and then both operands made positive: the
    ; rounding below is about magnitudes.  The divisor's sign is taken first,
    ; because a zero dividend still carries it: 0 / -1 is -0.0.
    xor r13d, r13d              ; 0 = positive
    lea rdi, [rbp - ITD_B]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    jns .itd_b_pos
    mov r13d, 1
    lea rdi, [rbp - ITD_B]
    lea rsi, [rbp - ITD_B]
    call __gmpz_neg wrt ..plt
.itd_b_pos:
    lea rdi, [rbp - ITD_A]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    js .itd_a_neg
    mov [rbp - ITD_SIGN], r13
    jnz .itd_a_pos
    jmp .itd_zero
.itd_a_neg:
    xor r13d, 1
    mov [rbp - ITD_SIGN], r13
    lea rdi, [rbp - ITD_A]
    lea rsi, [rbp - ITD_A]
    call __gmpz_neg wrt ..plt
.itd_a_pos:

    ; --- one rounding, and it is here -----------------------------------
    ;
    ; The old code turned each operand into a double and divided.  That is
    ; three roundings, not one: __gmpz_get_d TRUNCATES toward zero, twice,
    ; and the division rounds again.  (10**30) / 7 came back
    ; 1.4285714285714283e+29 where CPython answers ...285e+29.
    ;
    ; CPython's long_true_divide computes the quotient of the two exact
    ; integers to a few bits more than a mantissa and rounds once.  So: shift
    ; the numerator until the quotient has 55 bits, divide exactly, fold the
    ; remainder into the low bit as a sticky, and round half to even.
    lea rdi, [rbp - ITD_A]
    mov esi, 2
    call __gmpz_sizeinbase wrt ..plt
    mov rbx, rax                ; bits in a
    lea rdi, [rbp - ITD_B]
    mov esi, 2
    call __gmpz_sizeinbase wrt ..plt
    mov r12, rax                ; bits in b

    ; shift = 55 - (abits - bbits)
    mov rax, rbx
    sub rax, r12
    mov ecx, 55
    sub rcx, rax
    mov [rbp - ITD_SHIFT], rcx
    test rcx, rcx
    jle .itd_shift_den

    lea rdi, [rbp - ITD_A]
    lea rsi, [rbp - ITD_A]
    mov rdx, rcx
    call __gmpz_mul_2exp wrt ..plt
    jmp .itd_divide
.itd_shift_den:
    neg rcx
    lea rdi, [rbp - ITD_B]
    lea rsi, [rbp - ITD_B]
    mov rdx, rcx
    call __gmpz_mul_2exp wrt ..plt
.itd_divide:
    lea rdi, [rbp - ITD_Q]
    lea rsi, [rbp - ITD_R]
    lea rdx, [rbp - ITD_A]
    lea rcx, [rbp - ITD_B]
    call __gmpz_tdiv_qr wrt ..plt

    ; A non-zero remainder is everything below the last bit of the quotient,
    ; and the low bit of a 55-bit quotient is two places below the mantissa,
    ; so setting it is a sticky that cannot change a representable answer.
    lea rdi, [rbp - ITD_R]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    jz .itd_exact
    ; mpz_setbit takes the number and a BIT INDEX, not a destination and a
    ; source: passing three arguments made the source pointer the index.
    lea rdi, [rbp - ITD_Q]
    xor esi, esi
    call __gmpz_setbit wrt ..plt
.itd_exact:

    ; --- round the quotient to 53 bits, half to even --------------------
    lea rdi, [rbp - ITD_Q]
    mov esi, 2
    call __gmpz_sizeinbase wrt ..plt
    sub rax, 53
    mov [rbp - ITD_DROP], rax
    jle .itd_no_drop

    ; hi = q >> drop, and what is left decides the rounding.
    lea rdi, [rbp - ITD_R]
    lea rsi, [rbp - ITD_Q]
    mov rdx, [rbp - ITD_DROP]
    call __gmpz_fdiv_r_2exp wrt ..plt       ; the dropped bits
    lea rdi, [rbp - ITD_Q]
    lea rsi, [rbp - ITD_Q]
    mov rdx, [rbp - ITD_DROP]
    call __gmpz_fdiv_q_2exp wrt ..plt

    ; half = 1 << (drop - 1)
    lea rdi, [rbp - ITD_A]
    mov esi, 1
    call __gmpz_set_si wrt ..plt
    lea rdi, [rbp - ITD_A]
    lea rsi, [rbp - ITD_A]
    mov rdx, [rbp - ITD_DROP]
    dec rdx
    call __gmpz_mul_2exp wrt ..plt

    lea rdi, [rbp - ITD_R]
    lea rsi, [rbp - ITD_A]
    call __gmpz_cmp wrt ..plt
    test eax, eax
    js .itd_no_drop             ; below half: the quotient stands
    jnz .itd_round_up
    ; Exactly half: up only when that makes the last bit even.
    lea rdi, [rbp - ITD_Q]
    xor esi, esi
    call __gmpz_tstbit wrt ..plt
    test eax, eax
    jz .itd_no_drop
.itd_round_up:
    lea rdi, [rbp - ITD_Q]
    lea rsi, [rbp - ITD_Q]
    mov edx, 1
    call __gmpz_add_ui wrt ..plt
.itd_no_drop:

    ; --- assemble: q * 2 ** (drop - shift) ------------------------------
    lea rdi, [rbp - ITD_Q]
    call __gmpz_get_d wrt ..plt     ; exact: q has at most 54 bits by here
    mov rax, [rbp - ITD_DROP]
    test rax, rax
    jns .itd_have_drop
    xor eax, eax                    ; a negative drop meant no shift at all
.itd_have_drop:
    sub rax, [rbp - ITD_SHIFT]
    mov edi, eax
    extern ldexp
    call ldexp wrt ..plt
    movq rax, xmm0
    mov [rbp - ITD_RESULT], rax

    ; Infinity here is an overflow, not an answer: CPython raises rather than
    ; hand back a float that is not the quotient.
    mov rax, [rbp - ITD_RESULT]
    mov rcx, 0x7FFFFFFFFFFFFFFF
    and rax, rcx
    mov rcx, 0x7FF0000000000000
    cmp rax, rcx
    jae .itd_overflow

    mov rax, [rbp - ITD_SIGN]
    test rax, rax
    jz .itd_signed
    mov rax, [rbp - ITD_RESULT]
    btc rax, 63
    mov [rbp - ITD_RESULT], rax
.itd_signed:
    call itd_clear
    mov rax, [rbp - ITD_RESULT]
    V_FROM_F64 rax, rcx
    pop r13
    pop r12
    pop rbx
    leave
    ret

.itd_zero:
    call itd_clear
    xor eax, eax
    cmp qword [rbp - ITD_SIGN], 0
    je .itd_zero_signed
    mov rax, 0x8000000000000000     ; -0.0, which 0 / -1 is
.itd_zero_signed:
    V_FROM_F64 rax, rcx
    pop r13
    pop r12
    pop rbx
    leave
    ret

.itd_overflow:
    call itd_clear
    pop r13
    pop r12
    pop rbx
    extern exc_OverflowError_type
    extern set_exception
    SET_EXC exc_OverflowError_type, "integer division result too large for a float"
    leave
    ret

.itd_divzero:
    call itd_clear
    pop r13
    pop r12
    pop rbx
    SET_EXC exc_ZeroDivisionError_type, "division by zero"
    leave
    ret

;; The four mpz_t this frame owns.  A local rather than a function, because it
;; addresses the caller's frame.
itd_clear:
    push rax
    sub rsp, 8
    lea rdi, [rbp - ITD_A]
    call __gmpz_clear wrt ..plt
    lea rdi, [rbp - ITD_B]
    call __gmpz_clear wrt ..plt
    lea rdi, [rbp - ITD_Q]
    call __gmpz_clear wrt ..plt
    lea rdi, [rbp - ITD_R]
    call __gmpz_clear wrt ..plt
    add rsp, 8
    pop rax
    ret
END_FUNC int_true_divide
