; builtins_pow.asm - pow(), and the modular exponentiation GMP does for it
;
; Split out of builtins_num.asm, which was over the 100k cap that
; src/compiler/lint.py holds hand-written files to.  This is a seam the file
; already had: pow's three-argument form is a self-contained piece of GMP, and
; nothing else in the file reaches its helpers.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

extern int_promote_mpz
extern set_exception
extern __gmpz_add
extern __gmpz_clear
extern __gmpz_cmp_si
extern __gmpz_init
extern __gmpz_invert
extern __gmpz_neg
extern __gmpz_powm
extern __gmpz_set
extern __gmpz_set_si
extern ap_malloc
extern complex_type
extern dunder_lookup
extern exc_TypeError_type
extern exc_ValueError_type
extern float_type
extern int_is_integer
extern int_shrink
extern int_type
extern bool_type

section .text

;; ============================================================================
;; pow_is_plain_int(rdi = payload, edx = tag) -> eax = 1 for an int that is
;;   int or bool EXACTLY, 0 for a subclass or anything else
;;
;; int_is_integer accepts a subclass, which is right for arithmetic and wrong
;; for deciding whether the operator protocol can be skipped.
;; ============================================================================
DEF_FUNC_BARE pow_is_plain_int
    mov eax, 1
    cmp edx, TAG_SMALLINT
    je .pipi_done
    test edx, TAG_RC_BIT
    jz .pipi_no
    test rdi, rdi
    jz .pipi_no
    mov rcx, [rdi + PyObject.ob_type]
    lea rdx, [rel int_type]
    cmp rcx, rdx
    je .pipi_done
    lea rdx, [rel bool_type]
    cmp rcx, rdx
    je .pipi_done
.pipi_no:
    xor eax, eax
.pipi_done:
    ret
END_FUNC pow_is_plain_int

;; ============================================================================
;; builtin_pow_fn(rdi = args Value[], rsi = nargs) -> rax = a Value
;; Fails: 0
;; 2 args: base ** exp
;; 3 args: pow(base, exp, mod) — modular exponentiation
;; ============================================================================
global builtin_pow_fn
POW_BASE equ 8

POW_BTAG equ 16
POW_EXP  equ 24
POW_ETAG equ 32
POW_MOD  equ 40
POW_MTAG equ 48
POW_MB   equ 80             ; four mpz_t, 16 bytes each
POW_MEXP equ 96
POW_MMOD equ 112
POW_MRES equ 128
POW_FRAME equ 136           ; + 3 pushes = 8 + 136 + 24 = 168, 16-aligned
DEF_FUNC builtin_pow_fn, POW_FRAME
    push rbx
    push r12
    push r13

    cmp rsi, 2
    je .pow_two
    cmp rsi, 3
    je .pow_three
    jmp .pow_error

.pow_two:
    ; pow(base, exp) — extract operands and delegate to int_power/float path
    mov rax, [rdi]          ; args[0] = base
    V_UNPACK rax, rcx
    mov rbx, [rdi + 8]      ; args[1] = exp
    V_UNPACK rbx, r8

    ; Both integers?  Delegate to int_power, which handles SmallInt, heap
    ; ints and int subclasses (and GMP overflow) itself.
    extern int_is_integer
    mov [rbp - POW_BTAG], rcx
    mov [rbp - POW_ETAG], r8
    mov r12, rax                ; base payload
    mov r13, rbx                ; exp payload
    mov rdi, rax
    mov edx, ecx
    call int_is_integer
    test eax, eax
    jz .pow_reload_float
    mov rdi, r13
    mov edx, [rbp - POW_ETAG]
    call int_is_integer
    test eax, eax
    jz .pow_reload_float

    ; Two integers, but a SUBCLASS of int gets the protocol anyway: it may
    ; override __pow__ or __rpow__, and int_power would answer 8 for
    ; pow(2, PowRight(3)) where CPython answers PowRight.__rpow__.  A heap
    ; object whose type is neither int nor bool exactly is such a subclass.
    mov rdi, r12
    mov edx, [rbp - POW_BTAG]
    call pow_is_plain_int
    test eax, eax
    jz .pow_reload_float
    mov rdi, r13
    mov edx, [rbp - POW_ETAG]
    call pow_is_plain_int
    test eax, eax
    jz .pow_reload_float

    mov rax, r12
    mov rbx, r13
    mov ecx, [rbp - POW_BTAG]
    mov r8d, [rbp - POW_ETAG]
    jmp .pow_two_int
.pow_reload_float:
    ; Not two integers.  Everything else goes through obj_binary_op, the same
    ; protocol `base ** exp` uses, so pow() answers whatever the operator
    ; answers -- for float subclasses, for complex, and for any class with
    ; __pow__.  The hand-rolled float path that used to be here tested
    ; `ob_type == float_type` exactly and knew nothing of complex, so
    ; pow(F(2.0), 2) raised where F(2.0) ** 2 worked, and pow(1+2j, 2) raised
    ; where (1+2j) ** 2 worked.
    mov rdi, r12
    mov esi, [rbp - POW_BTAG]
    V_PACK rdi, rsi
    mov rsi, r13
    mov edx, [rbp - POW_ETAG]
    V_PACK rsi, rdx
    mov edx, NB_POWER
    extern obj_binary_op
    call obj_binary_op
    test rax, rax
    jz .pow_propagate
    V_UNPACK rax, rdx
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.pow_propagate:
    xor eax, eax                ; a NULL Value, with the exception pending
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    leave
    ret
.pow_two_int:

    ; int ** int — call int_power(base, exp, base_tag, exp_tag)
    extern int_power
    mov rdi, rax            ; base payload
    mov rsi, rbx            ; exp payload
    mov edx, ecx            ; base tag (TAG_SMALLINT)
    mov ecx, r8d            ; exp tag (TAG_SMALLINT)
    V_PACK rdi, rdx
    V_PACK rsi, rcx
    call int_power
    V_UNPACK rax, rdx       ; int_power returns a Value
    ; rax = result payload, edx = result tag
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

; The hand-rolled float path that used to live here is gone with it: one
; implementation of `**` rather than two that disagreed about what a float is.

.pow_three:
    ; pow(base, exp, mod) -- modular exponentiation, in GMP.
    ;
    ; It used to be an int64 square-and-multiply, so every operand had to be
    ; an immediate: pow(2, 10**20, 7) and pow(10**30, 3, 10**7) were both
    ; "pow() arguments must be numeric".  It also rejected a negative
    ; exponent outright, where CPython since 3.8 answers the modular
    ; INVERSE, and it tested the exponent's sign before the modulus, so
    ; pow(2, -1, 0) named the wrong argument.
    extern int_unwrap
    mov r13, rdi                ; args array
    mov rdi, [r13]
    V_UNPACK rdi, rdx
    call int_unwrap
    mov [rbp - POW_BASE], rdi
    mov [rbp - POW_BTAG], rdx
    mov rdi, [r13 + 8]
    V_UNPACK rdi, rdx
    call int_unwrap
    mov [rbp - POW_EXP], rdi
    mov [rbp - POW_ETAG], rdx
    mov rdi, [r13 + 16]
    V_UNPACK rdi, rdx
    call int_unwrap
    mov [rbp - POW_MOD], rdi
    mov [rbp - POW_MTAG], rdx

    ; A base that is not an int is asked for its own three-argument __pow__,
    ; which is how pow(x, y, z) works on a class that defines one.  Nothing
    ; consulted it, so every such call was "pow() arguments must be numeric".
    mov rdi, [rbp - POW_BASE]
    mov esi, [rbp - POW_BTAG]
    call pow_is_int_operand
    test eax, eax
    jz .pow_three_dunder

    ; With an int base, all three have to be ints, and CPython words that
    ; refusal specifically.
    mov rdi, [rbp - POW_EXP]
    mov esi, [rbp - POW_ETAG]
    call pow_is_int_operand
    test eax, eax
    jz .pow_not_all_ints
    mov rdi, [rbp - POW_MOD]
    mov esi, [rbp - POW_MTAG]
    call pow_is_int_operand
    test eax, eax
    jz .pow_not_all_ints

    ; Into GMP.  The modulus is checked FIRST: pow(2, -1, 0) is about the
    ; third argument, not the second.
    lea rdi, [rbp - POW_MB]
    call __gmpz_init wrt ..plt
    lea rdi, [rbp - POW_MEXP]
    call __gmpz_init wrt ..plt
    lea rdi, [rbp - POW_MMOD]
    call __gmpz_init wrt ..plt
    lea rdi, [rbp - POW_MRES]
    call __gmpz_init wrt ..plt

    lea rdi, [rbp - POW_MB]
    mov rsi, [rbp - POW_BASE]
    mov edx, [rbp - POW_BTAG]
    call pow_load_mpz
    ERR_M1 .pow_fail_clear
    lea rdi, [rbp - POW_MEXP]
    mov rsi, [rbp - POW_EXP]
    mov edx, [rbp - POW_ETAG]
    call pow_load_mpz
    ERR_M1 .pow_fail_clear
    lea rdi, [rbp - POW_MMOD]
    mov rsi, [rbp - POW_MOD]
    mov edx, [rbp - POW_MTAG]
    call pow_load_mpz
    ERR_M1 .pow_fail_clear

    lea rdi, [rbp - POW_MMOD]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    jz .pow_zero_mod

    lea rdi, [rbp - POW_MEXP]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    js .pow_mod_inverse

    lea rdi, [rbp - POW_MRES]
    lea rsi, [rbp - POW_MB]
    lea rdx, [rbp - POW_MEXP]
    lea rcx, [rbp - POW_MMOD]
    call __gmpz_powm wrt ..plt
    jmp .pow_mod_sign

.pow_mod_inverse:
    ; A negative exponent: invert the base, then raise the inverse to |exp|.
    lea rdi, [rbp - POW_MRES]
    lea rsi, [rbp - POW_MB]
    lea rdx, [rbp - POW_MMOD]
    call __gmpz_invert wrt ..plt
    test eax, eax
    jz .pow_not_invertible
    lea rdi, [rbp - POW_MEXP]
    lea rsi, [rbp - POW_MEXP]
    call __gmpz_neg wrt ..plt
    lea rdi, [rbp - POW_MRES]
    lea rsi, [rbp - POW_MRES]
    lea rdx, [rbp - POW_MEXP]
    lea rcx, [rbp - POW_MMOD]
    call __gmpz_powm wrt ..plt

.pow_mod_sign:
    ; GMP's powm answers in [0, |mod|); Python's result carries the sign of
    ; the modulus, so a negative modulus needs the representative shifted
    ; down by |mod| unless the result is already zero.
    lea rdi, [rbp - POW_MMOD]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    jns .pow_mod_build
    lea rdi, [rbp - POW_MRES]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    jz .pow_mod_build
    lea rdi, [rbp - POW_MRES]
    lea rsi, [rbp - POW_MRES]
    lea rdx, [rbp - POW_MMOD]
    call __gmpz_add wrt ..plt

.pow_mod_build:
    mov edi, PyIntObject_size
    call ap_malloc
    mov rbx, rax
    mov qword [rbx + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rbx + PyObject.ob_type], rcx
    mov qword [rbx + PyIntObject.compact], 0
    INT_NEED_MPZ rbx
    lea rdi, [rbx + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    lea rdi, [rbx + PyIntObject.mpz]
    lea rsi, [rbp - POW_MRES]
    call __gmpz_set wrt ..plt
    call pow_clear_mpz
    mov rdi, rbx
    call int_shrink
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.pow_three_dunder:
    ; __pow__(self, exp, mod).  No nb_ slot can carry a third operand, so the
    ; name is looked up and called directly.
    mov rdi, [rbp - POW_BASE]
    cmp dword [rbp - POW_BTAG], TAG_PTR
    jne .pow_not_all_ints
    mov rdi, [rdi + PyObject.ob_type]

    ; complex is decided here and not by its __pow__: CPython's answer for a
    ; modulus is ValueError "complex modulo", and complex.__pow__ is the
    ; generated three-argument wrapper, which calls this -- so looking it up
    ; would be a recursion with no floor.  A float never reaches this at all,
    ; being TAG_FLOAT rather than a pointer.
    extern complex_type
    lea rcx, [rel complex_type]
    cmp rdi, rcx
    je .pow_complex_modulo
    push rdi
    lea rsi, [rel complex_type]
    extern type_is_subtype
    call type_is_subtype
    pop rdi
    test eax, eax
    jnz .pow_complex_modulo

    CSTRING rsi, "__pow__"
    extern dunder_lookup
    call dunder_lookup
    V_UNPACK rax, rdx
    test edx, edx
    jz .pow_not_all_ints
    test edx, TAG_RC_BIT
    jz .pow_not_all_ints
    mov r12, rax                ; the function

    mov rax, [r12 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .pow_not_all_ints

    sub rsp, 32                 ; 3 Values, padded to keep rsp 16-aligned
    mov rdi, [rbp - POW_BASE]
    mov esi, [rbp - POW_BTAG]
    V_PACK rdi, rsi
    mov [rsp], rdi
    mov rdi, [rbp - POW_EXP]
    mov esi, [rbp - POW_ETAG]
    V_PACK rdi, rsi
    mov [rsp + 8], rdi
    mov rdi, [rbp - POW_MOD]
    mov esi, [rbp - POW_MTAG]
    V_PACK rdi, rsi
    mov [rsp + 16], rdi
    mov rdi, r12
    mov rsi, rsp
    mov edx, 3
    call rax
    add rsp, 32
    V_UNPACK rax, rdx
    test edx, edx
    jz .pow_propagate
    ; NotImplemented from a by-name call means the type declined the pair.
    extern notimpl_singleton
    lea rcx, [rel notimpl_singleton]
    cmp rax, rcx
    je .pow_not_all_ints
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.pow_complex_modulo:
    extern exc_ValueError_type
    FAIL exc_ValueError_type, "complex modulo", .pow_propagate

.pow_not_all_ints:
    FAIL exc_TypeError_type, "pow() 3rd argument not allowed unless all arguments are integers", .pow_propagate

.pow_not_invertible:
    SET_EXC exc_ValueError_type, "base is not invertible for the given modulus"
    jmp .pow_fail_clear

.pow_zero_mod:
    SET_EXC exc_ValueError_type, "pow() 3rd argument cannot be 0"
    ; fall through
.pow_fail_clear:
    ; The error exit for everything after the four mpz_t were initialised.
    call pow_clear_mpz
    jmp .pow_propagate

.pow_error:
    FAIL exc_TypeError_type, "pow() takes 2 or 3 arguments", .pow_propagate
END_FUNC builtin_pow_fn

;; ============================================================================
;; pow_is_int_operand(rdi = payload, esi = tag) -> eax = 1 when it is an int
;;
;; int_unwrap has already flattened bool, a compact heap int and an int
;; subclass to TAG_SMALLINT; what is left as a pointer is either a GMP-backed
;; int or something that is not an int at all, so the type has to be read.
;; ============================================================================
DEF_FUNC_LOCAL pow_is_int_operand
    cmp esi, TAG_SMALLINT
    je .poi_yes
    cmp esi, TAG_PTR
    jne .poi_no
    lea rax, [rel int_type]
    cmp [rdi + PyObject.ob_type], rax
    jne .poi_no
.poi_yes:
    mov eax, 1
    leave
    ret
.poi_no:
    xor eax, eax
    leave
    ret
END_FUNC pow_is_int_operand

;; ============================================================================
;; pow_load_mpz(rdi = an initialised mpz_t, rsi = payload, edx = tag)
;;   -> rax = 0
;; Fails: -1
;; Sets the mpz from an int in either representation.
;; ============================================================================
DEF_FUNC_LOCAL pow_load_mpz
    cmp edx, TAG_SMALLINT
    je .plm_small
    mov rax, rsi
    lea rcx, [rel int_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .plm_bad
    push rdi
    sub rsp, 8
    INT_NEED_MPZ rax
    add rsp, 8
    pop rdi
    mov rax, rsi
    add rax, PyIntObject.mpz
    mov rsi, rax
    call __gmpz_set wrt ..plt
    xor eax, eax
    leave
    ret
.plm_small:
    call __gmpz_set_si wrt ..plt
    xor eax, eax
    leave
    ret
.plm_bad:
    SET_EXC exc_TypeError_type, "pow() arguments must be numeric"
    mov rax, -1
    leave
    ret
END_FUNC pow_load_mpz

;; ============================================================================
;; pow_clear_mpz() -> void -- releases the four mpz_t in builtin_pow_fn's frame.
;;
;; Reads its CALLER's frame through the saved rbp, because DEF_FUNC gives it
;; one of its own.  Four calls in a row otherwise, at every exit and at both
;; raises.
;; ============================================================================
DEF_FUNC_LOCAL pow_clear_mpz
    push rbx
    sub rsp, 8
    mov rbx, [rbp]              ; the caller's rbp
    lea rdi, [rbx - POW_MB]
    call __gmpz_clear wrt ..plt
    lea rdi, [rbx - POW_MEXP]
    call __gmpz_clear wrt ..plt
    lea rdi, [rbx - POW_MMOD]
    call __gmpz_clear wrt ..plt
    lea rdi, [rbx - POW_MRES]
    call __gmpz_clear wrt ..plt
    add rsp, 8
    pop rbx
    leave
    ret
END_FUNC pow_clear_mpz
