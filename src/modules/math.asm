; mathmod.asm - the `math` module
;
; Its absence blocked thirteen CPython stdlib modules outright -- calendar,
; datetime, decimal, fractions, mailbox, mimetypes, selectors, statistics,
; _strptime and urllib.parse among them -- because every one of them opens
; with `import math` and none of them guards it.
;
; The float functions are glibc's.  -lm is already linked (the complex
; implementation calls hypot, pow, atan2, exp, log, cos and sin), and for the
; ordinary finite arguments CPython also calls glibc on Linux, so the answers
; are the same bits.  The exceptions are called out where they arise:
; gamma and lgamma, where CPython uses a Lanczos approximation of its own, and
; the n-ary hypot/dist/sumprod, where it uses a scaled Neumaier sum.
;
; No errno.  CPython's math_1 sets it and then consults it, but every branch
; that matters is decidable from the argument and the result alone:
;
;   a NaN result from an argument that was not NaN   -> ValueError, domain
;   an infinite result from a finite argument        -> OverflowError, range
;                                                       (or the same
;                                                       ValueError, for the
;                                                       functions that cannot
;                                                       legitimately overflow)
;
; CPython's own comment on the errno branch says it is unnecessary on most
; platforms.  math_ret_1 and math_ret_2 are those rules, and every float
; function ends in one of them.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"
%include "value.inc"

ASM_INIT

extern dict_new
extern dict_set
extern module_new
extern str_from_cstr_heap
extern builtin_func_new
extern obj_decref
extern obj_incref
extern obj_dealloc
extern raise_exception
extern raise_type_error_counted
extern value_type
extern type_name_message
extern raise_type_error_with_name
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_OverflowError_type
extern exc_ZeroDivisionError_type
extern dunder_operand_is_int
extern float_to_f64
extern float_from_f64
extern float_int
extern dunder_operand_is_real
extern bool_true
extern bool_false
extern none_singleton
extern tuple_new
extern dunder_lookup
extern dunder_call_1
extern v_int_bias

; libm
extern sqrt
extern exp
extern log
extern log2
extern log10
extern log1p
extern expm1
extern sin
extern cos
extern tan
extern asin
extern acos
extern atan
extern atan2
extern sinh
extern cosh
extern tanh
extern asinh
extern acosh
extern atanh
extern cbrt
extern exp2
extern erf
extern erfc
extern tgamma
extern lgamma
extern fabs
extern fmod
extern remainder
extern copysign
extern pow
extern hypot
extern fma
extern floor
extern ceil
extern trunc
extern ldexp
extern __gmpz_mul
extern kw_names_pending
extern ap_strcmp
extern get_iterator_opt
extern obj_binary_op
extern tuple_type
extern tuple_type_call
extern bool_true
extern bool_false
extern nextafter
extern modf
extern int_is_integer
extern int_unwrap
extern int_from_i64
extern int_shrink
extern int_promote_mpz
extern int_dealloc
extern smallint_to_pyint
extern int_type
extern ap_malloc
extern __gmpz_init
extern __gmpz_gcd
extern __gmpz_set_si
extern __gmpz_addmul
extern __gmpz_lcm
extern __gmpz_sqrt
extern __gmpz_cmp_si
extern __gmpz_fac_ui
extern __gmpz_bin_ui
extern __gmpz_fits_ulong_p
extern __gmpz_fits_slong_p
extern __gmpz_get_si
extern val_from_i64
extern bool_type
extern set_exception
extern __gmpz_get_d_2exp
extern __gmpz_get_ui
extern get_iterator
extern call_iternext
extern ap_realloc
extern ap_free
extern current_exception
extern eval_exception_unwind
extern eval_saved_r13
extern frexp

section .text

;; ============================================================================
;; math_to_double(rdi = a Value) -> xmm0 = the double, eax = 1, or eax = 0
;;
;; Non-raising, so a caller holding owned references can clean up.  The
;; protocol is CPython's: a real number directly, else __float__, else
;; __index__.
;; ============================================================================
MTD_VAL   equ 8
MTD_RES   equ 16
MTD_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC math_to_double, MTD_FRAME
    mov [rbp - MTD_VAL], rdi

    call dunder_operand_is_real
    test eax, eax
    jz .mtd_slow

    mov rdi, [rbp - MTD_VAL]
    V_UNPACK rdi, rsi
    call float_to_f64           ; its mpz arm rounds to nearest, as CPython's
                                ; PyLong_AsDouble does, rather than truncating
    ; An int too large for a double came back as an infinity, and every
    ; caller then answered with it: math.sqrt(10**400) was inf rather than
    ; CPython's OverflowError.  A float infinity is a legitimate argument, so
    ; only the int arm asks.
    movsd [rbp - MTD_RES], xmm0
    mov rdi, [rbp - MTD_VAL]
    call dunder_operand_is_int
    test eax, eax
    jz .mtd_ok
    movsd xmm0, [rbp - MTD_RES]
    andpd xmm0, [rel mm_absmask]
    ucomisd xmm0, [rel mm_inf]
    jp .mtd_ok
    je .mtd_overflow
.mtd_ok:
    movsd xmm0, [rbp - MTD_RES]
    mov eax, 1
    leave
    ret

.mtd_overflow:
    RAISE exc_OverflowError_type, "int too large to convert to float"

.mtd_slow:
    ; Not a number itself.  __float__ first, then __index__, which is the
    ; order CPython's PyFloat_AsDouble takes.
    mov rdi, [rbp - MTD_VAL]
    V_TEST_PTR rdi, rax
    ja .mtd_no
    test rdi, rdi
    jz .mtd_no

    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jz .mtd_no
    mov rcx, [rax + PyNumberMethods.nb_float]
    test rcx, rcx
    jnz .mtd_call
    mov rcx, [rax + PyNumberMethods.nb_index]
    test rcx, rcx
    jz .mtd_no
.mtd_call:
    mov rdi, [rbp - MTD_VAL]
    mov edx, TAG_PTR
    call rcx
    test rax, rax
    jz .mtd_no
    mov [rbp - MTD_VAL], rax    ; the RESULT now, and it is ours to release
    mov rdi, rax
    call dunder_operand_is_real
    test eax, eax
    jz .mtd_drop
    mov rdi, [rbp - MTD_VAL]
    V_UNPACK rdi, rsi
    call float_to_f64
    ; A __float__ that answered a float SUBCLASS handed back a reference; an
    ; immediate owns nothing, and DECREF_V knows the difference.  The double
    ; is parked in the result slot across the release.
    movsd [rbp - MTD_RES], xmm0
    mov rdi, [rbp - MTD_VAL]
    DECREF_V rdi, rcx
    movsd xmm0, [rbp - MTD_RES]
    mov eax, 1
    leave
    ret

.mtd_drop:
    mov rdi, [rbp - MTD_VAL]
    DECREF_V rdi, rcx
.mtd_no:
    xor eax, eax
    leave
    ret
END_FUNC math_to_double

;; ============================================================================
;; math_arg1_double(rdi = args, rsi = nargs, rdx = the function's name)
;;   -> xmm0 = the double.  Raises for the wrong count or a non-number.
;; ============================================================================
MA1_NAME  equ 8
MA1_VAL   equ 16
MA1_N     equ 24
MA1_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC math_arg1_double, MA1_FRAME
    mov [rbp - MA1_NAME], rdx
    mov [rbp - MA1_N], rsi
    cmp rsi, 1
    jne .ma1_args
    mov rdi, [rdi]
    mov [rbp - MA1_VAL], rdi
    call math_to_double
    test eax, eax
    jz .ma1_type
    leave
    ret
.ma1_type:
    mov rsi, [rbp - MA1_VAL]
    CSTRING rdi, `must be real number, not \x01`
    call raise_type_error_with_name
.ma1_args:
    mov rdi, [rbp - MA1_NAME]
    mov rsi, [rbp - MA1_N]
    call math_raise_arity
END_FUNC math_arg1_double

;; ============================================================================
;; math_raise_arity(rdi = the name, rsi = nargs) -- does not return
;;
;; CPython's two wordings, which differ by arity and are what a program
;; matching on the message would be matching on:
;;   math.sqrt() takes exactly one argument (2 given)
;;   atan2 expected 2 arguments, got 1
;; ============================================================================
MRA_NAME  equ 8
MRA_N     equ 16
MRA_BUF   equ 160
MRA_FRAME equ 160           ; + 0 pushes = 160, 16-aligned
DEF_FUNC_LOCAL math_raise_arity, MRA_FRAME
    mov [rbp - MRA_NAME], rdi
    mov [rbp - MRA_N], rsi
    lea rdi, [rbp - MRA_BUF]
    lea rsi, [rel mm_math_dot]
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - MRA_NAME]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel mm_takes_one]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - MRA_N]
    extern msg_append_i64
    call msg_append_i64
    mov rdi, rax
    lea rsi, [rel mm_given]
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - MRA_BUF]
    call raise_exception
END_FUNC math_raise_arity

;; ============================================================================
;; math_raise_arity2(rdi = the name, rsi = nargs) -- the two-argument wording
;; ============================================================================
DEF_FUNC_LOCAL math_raise_arity2, MRA_FRAME
    mov [rbp - MRA_NAME], rdi
    mov [rbp - MRA_N], rsi
    lea rdi, [rbp - MRA_BUF]
    mov rsi, rdi
    mov rsi, [rbp - MRA_NAME]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel mm_expected2]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - MRA_N]
    call msg_append_i64
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - MRA_BUF]
    call raise_exception
END_FUNC math_raise_arity2

;; ============================================================================
;; math_ret_1(xmm0 = the result, xmm1 = the argument, edi = can_overflow)
;;   -> rax = a float Value.  Raises for a domain or range error.
;; ============================================================================
MR1_R     equ 8
MR1_X     equ 16
MR1_OVF   equ 24
MR1_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC math_ret_1, MR1_FRAME
    movsd [rbp - MR1_R], xmm0
    movsd [rbp - MR1_X], xmm1
    mov [rbp - MR1_OVF], edi

    ; A NaN result from an argument that was not NaN is a domain error.
    ucomisd xmm0, xmm0
    jnp .mr1_finite_check
    ucomisd xmm1, xmm1
    jp .mr1_ok                  ; NaN in, NaN out: not an error
    jmp .mr1_domain

.mr1_finite_check:
    ; An infinite result from a finite argument is a range error, or a domain
    ; one for the functions that cannot legitimately reach infinity.
    movapd xmm2, xmm0
    andpd xmm2, [rel mm_absmask]
    ucomisd xmm2, [rel mm_inf]
    jne .mr1_ok
    movapd xmm2, xmm1
    andpd xmm2, [rel mm_absmask]
    ucomisd xmm2, [rel mm_inf]
    je .mr1_ok                  ; infinite in, infinite out
    ucomisd xmm1, xmm1
    jp .mr1_ok
    cmp dword [rbp - MR1_OVF], 0
    je .mr1_domain
    jmp .mr1_range

.mr1_ok:
    movsd xmm0, [rbp - MR1_R]
    call float_from_f64
    leave
    V_PACK rax, rdx
    ret

.mr1_domain:
    RAISE exc_ValueError_type, "math domain error"
.mr1_range:
    RAISE exc_OverflowError_type, "math range error"
END_FUNC math_ret_1

;; ============================================================================
;; math_ret_2(xmm0 = result, xmm1 = x, xmm2 = y) -> rax = a float Value
;;
;; The two-argument rule: an infinite result from two finite arguments is
;; ALWAYS an overflow -- there is no can_overflow flag in CPython's math_2.
;; ============================================================================
MR2_R     equ 8
MR2_X     equ 16
MR2_Y     equ 24
MR2_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC math_ret_2, MR2_FRAME
    movsd [rbp - MR2_R], xmm0
    movsd [rbp - MR2_X], xmm1
    movsd [rbp - MR2_Y], xmm2

    ucomisd xmm0, xmm0
    jnp .mr2_finite_check
    ucomisd xmm1, xmm1
    jp .mr2_ok
    ucomisd xmm2, xmm2
    jp .mr2_ok
    jmp .mr2_domain

.mr2_finite_check:
    movapd xmm3, xmm0
    andpd xmm3, [rel mm_absmask]
    ucomisd xmm3, [rel mm_inf]
    jne .mr2_ok
    movapd xmm3, xmm1
    andpd xmm3, [rel mm_absmask]
    ucomisd xmm3, [rel mm_inf]
    je .mr2_ok
    movapd xmm3, xmm2
    andpd xmm3, [rel mm_absmask]
    ucomisd xmm3, [rel mm_inf]
    je .mr2_ok
    jmp .mr2_range

.mr2_ok:
    movsd xmm0, [rbp - MR2_R]
    call float_from_f64
    leave
    V_PACK rax, rdx
    ret

.mr2_domain:
    RAISE exc_ValueError_type, "math domain error"
.mr2_range:
    RAISE exc_OverflowError_type, "math range error"
END_FUNC math_ret_2

;; ============================================================================
;; MATH_UNARY name, libm_symbol, can_overflow
;;
;; One glibc call, wrapped in the argument protocol and the error rule.  The
;; `and rsp, -16` is the SysV requirement glibc's float paths actually use --
;; see the "call made with rsp misaligned" note in CLAUDE.md -- and `leave`
;; undoes it, so it is done once rather than per call.
;; ============================================================================
MU_X     equ 8
MU_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
%macro MATH_UNARY 3
DEF_FUNC math_%1, MU_FRAME
    lea rdx, [rel mm_n_%1]
    call math_arg1_double
    movsd [rbp - MU_X], xmm0
    and rsp, -16                ; glibc's float paths use aligned SSE
    call %2 wrt ..plt
    movsd xmm1, [rbp - MU_X]
    mov edi, %3
    call math_ret_1
    leave
    ret
END_FUNC math_%1
%endmacro

;; ============================================================================
;; MATH_BINARY name, libm_symbol
;; ============================================================================
MB_X     equ 8
MB_Y     equ 16
MB_NAME  equ 24
MB_N     equ 32
MB_FRAME equ 48             ; + 0 pushes = 48, 16-aligned
%macro MATH_BINARY 2
DEF_FUNC math_%1, MB_FRAME
    lea rax, [rel mm_n_%1]
    mov [rbp - MB_NAME], rax
    mov [rbp - MB_N], rsi
    cmp rsi, 2
    jne %%args
    push rdi
    mov rdi, [rdi]
    call math_to_double
    test eax, eax
    jz %%type0
    movsd [rbp - MB_X], xmm0
    mov rdi, [rsp]
    mov rdi, [rdi + 8]
    call math_to_double
    test eax, eax
    jz %%type1
    add rsp, 8
    movsd [rbp - MB_Y], xmm0
    movsd xmm0, [rbp - MB_X]
    movsd xmm1, [rbp - MB_Y]
    and rsp, -16
    call %2 wrt ..plt
    movsd xmm1, [rbp - MB_X]
    movsd xmm2, [rbp - MB_Y]
    call math_ret_2
    leave
    ret
%%type0:
    pop rsi
    mov rsi, [rsi]
    jmp %%type
%%type1:
    pop rsi
    mov rsi, [rsi + 8]
%%type:
    CSTRING rdi, `must be real number, not \x01`
    call raise_type_error_with_name
%%args:
    mov rdi, [rbp - MB_NAME]
    mov rsi, [rbp - MB_N]
    call math_raise_arity2
END_FUNC math_%1
%endmacro

; can_overflow is 1 for exactly these five: everything else either cannot
; reach infinity from a finite argument, or reaching it is a domain error.
MATH_UNARY sqrt,   sqrt,   0
MATH_UNARY exp,    exp,    1
MATH_UNARY expm1,  expm1,  1
MATH_UNARY exp2,   exp2,   1
MATH_UNARY sinh,   sinh,   1
MATH_UNARY cosh,   cosh,   1
MATH_UNARY log2,   log2,   0
MATH_UNARY log10,  log10,  0
MATH_UNARY log1p,  log1p,  0
MATH_UNARY sin,    sin,    0
MATH_UNARY cos,    cos,    0
MATH_UNARY tan,    tan,    0
MATH_UNARY asin,   asin,   0
MATH_UNARY acos,   acos,   0
MATH_UNARY atan,   atan,   0
MATH_UNARY tanh,   tanh,   0
MATH_UNARY asinh,  asinh,  0
MATH_UNARY acosh,  acosh,  0
MATH_UNARY atanh,  atanh,  0
MATH_UNARY cbrt,   cbrt,   0
MATH_UNARY erf,    erf,    0
MATH_UNARY erfc,   erfc,   0
MATH_UNARY gamma,  tgamma, 1
MATH_UNARY lgamma, lgamma, 1
MATH_UNARY fabs,   fabs,   0

MATH_BINARY atan2,     atan2
MATH_BINARY copysign,  copysign
MATH_BINARY fmod,      fmod
MATH_BINARY remainder, remainder
MATH_BINARY nextafter, nextafter

;; ============================================================================
;; MATH_ROUNDER name, libm_symbol, dunder_name_symbol
;;
;; floor, ceil and trunc all return an INT, and all three honour a dunder of
;; the same name.  The int case is answered natively BEFORE that lookup, which
;; is what int.__floor__ returning self amounts to -- and matters, because
;; neither int nor float carries __floor__ in its tp_dict here, so a lookup
;; would miss and send math.floor(10**30 + 1) through a double, losing the 1.
;; ============================================================================
MRD_VAL   equ 8
MRD_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
%macro MATH_ROUNDER 3
DEF_FUNC math_%1, MRD_FRAME
    cmp rsi, 1
    jne %%args
    mov rdi, [rdi]
    mov [rbp - MRD_VAL], rdi

    V_IS_FLOAT rdi, rax
    jbe %%from_float

    ; An int is its own answer, exactly.  That is what int.__floor__ amounts
    ; to, and it has to be answered here: neither int nor float carries
    ; __floor__ in its tp_dict, so the lookup below would miss and send
    ; math.floor(10**30 + 1) through a double, losing the 1.
    V_UNPACK rdi, rdx
    push rdi
    push rdx
    call int_is_integer
    pop rdx
    pop rdi
    test eax, eax
    jz %%try_dunder
    ; int_unwrap rewrites the TAG as well as the payload -- it flattens a
    ; bool and a compact heap int to TAG_SMALLINT -- so the tag it returns is
    ; the one to use.  That is also what normalises math.floor(True) to 1 and
    ; math.floor(IntSubclass(5)) to a plain 5, as CPython does.
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je %%as_smallint
    mov rax, rdi                ; a GMP-backed int: our own reference
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
%%as_smallint:
    ; int_from_i64, not V_PACK: a flattened ival outside +-2^50 has to be
    ; boxed, and V_PACK would box it and then INCREF_V would count it twice.
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret

%%try_dunder:
    mov rdi, [rbp - MRD_VAL]
    V_TEST_PTR rdi, rax
    ja %%coerce
    test rdi, rdi
    jz %%coerce
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel %3]
    call dunder_lookup
    test rax, rax
    jz %%coerce
    mov rdi, [rbp - MRD_VAL]
    lea rsi, [rel %3]
    call dunder_call_1
    leave
    ret

%%coerce:
    mov rdi, [rbp - MRD_VAL]
    call math_to_double
    test eax, eax
    jz %%type
    jmp %%do

%%from_float:
    V_TO_F64 rdi
    movq xmm0, rdi

%%do:
    and rsp, -16
    call %2 wrt ..plt
    call float_from_f64
    V_PACK rax, rdx
    mov rdi, rax
    call float_int              ; == PyLong_FromDouble, wording included
    leave
    ret

%%type:
    mov rsi, [rbp - MRD_VAL]
    CSTRING rdi, `must be real number, not \x01`
    call raise_type_error_with_name
%%args:
    lea rdi, [rel mm_n_%1]
    call math_raise_arity
END_FUNC math_%1
%endmacro

MATH_ROUNDER floor, floor, mm_d_floor
MATH_ROUNDER ceil,  ceil,  mm_d_ceil

;; trunc is the same shape without the float fallback: CPython answers a
;; TypeError naming __trunc__ for anything that is neither a float nor an int
;; nor defines it, rather than coercing.
MTR_VAL   equ 8
MTR_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC math_trunc, MTR_FRAME
    cmp rsi, 1
    jne .mtr_args
    mov rdi, [rdi]
    mov [rbp - MTR_VAL], rdi

    V_IS_FLOAT rdi, rax
    jbe .mtr_float

    V_UNPACK rdi, rdx
    push rdi
    push rdx
    call int_is_integer
    pop rdx
    pop rdi
    test eax, eax
    jz .mtr_dunder
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .mtr_as_smallint
    mov rax, rdi
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.mtr_as_smallint:
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret

.mtr_dunder:
    mov rdi, [rbp - MTR_VAL]
    V_TEST_PTR rdi, rax
    ja .mtr_type
    test rdi, rdi
    jz .mtr_type
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel mm_d_trunc]
    call dunder_lookup
    test rax, rax
    jz .mtr_type
    mov rdi, [rbp - MTR_VAL]
    lea rsi, [rel mm_d_trunc]
    call dunder_call_1
    leave
    ret

.mtr_float:
    V_TO_F64 rdi
    movq xmm0, rdi
    and rsp, -16
    call trunc wrt ..plt
    call float_from_f64
    V_PACK rax, rdx
    mov rdi, rax
    call float_int
    leave
    ret

.mtr_type:
    mov rsi, [rbp - MTR_VAL]
    CSTRING rdi, `type \x01 doesn't define __trunc__ method`
    call raise_type_error_with_name
.mtr_args:
    lea rdi, [rel mm_n_trunc]
    call math_raise_arity
END_FUNC math_trunc

;; ============================================================================
;; math_modf(x) -> (fractional, integral), both floats
;;
;; The non-finite cases are decided before the libm call, as CPython does:
;; +-inf gives (copysign(0, x), x) and NaN gives (x, x), where glibc's modf
;; would answer differently.
;; ============================================================================
MMF_INT   equ 8
MMF_X     equ 16
MMF_TUP   equ 24
MMF_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC math_modf, MMF_FRAME
    lea rdx, [rel mm_n_modf]
    call math_arg1_double
    movsd [rbp - MMF_X], xmm0

    movapd xmm1, xmm0
    andpd xmm1, [rel mm_absmask]
    ucomisd xmm1, [rel mm_inf]
    jp .mmf_nan
    je .mmf_inf

    lea rdi, [rbp - MMF_INT]
    and rsp, -16
    call modf wrt ..plt
    jmp .mmf_build

.mmf_nan:
    movsd xmm1, [rbp - MMF_X]
    movsd [rbp - MMF_INT], xmm1
    jmp .mmf_build

.mmf_inf:
    ; (copysign(0.0, x), x)
    movsd xmm1, [rbp - MMF_X]
    movsd [rbp - MMF_INT], xmm1
    xorpd xmm0, xmm0
    movsd xmm1, [rbp - MMF_X]
    and rsp, -16
    call copysign wrt ..plt

.mmf_build:
    movsd [rbp - MMF_X], xmm0   ; the fractional part
    mov edi, 2
    call tuple_new
    mov [rbp - MMF_TUP], rax
    movsd xmm0, [rbp - MMF_X]
    call float_from_f64
    V_PACK rax, rdx
    mov rcx, [rbp - MMF_TUP]
    mov rdx, [rcx + PyTupleObject.ob_item]
    mov [rdx], rax
    movsd xmm0, [rbp - MMF_INT]
    call float_from_f64
    V_PACK rax, rdx
    mov rcx, [rbp - MMF_TUP]
    mov rdx, [rcx + PyTupleObject.ob_item]
    mov [rdx + 8], rax
    mov rax, rcx
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
END_FUNC math_modf

;; ============================================================================
;; math_degrees / math_radians -- the two conversions, which are pure
;; arithmetic and cannot fail for a finite argument.
;; ============================================================================
%macro MATH_SCALE 2             ; %1 = name, %2 = the factor's label
DEF_FUNC math_%1, MU_FRAME
    lea rdx, [rel mm_n_%1]
    call math_arg1_double
    movsd [rbp - MU_X], xmm0
    mulsd xmm0, [rel %2]
    movsd xmm1, [rbp - MU_X]
    xor edi, edi
    call math_ret_1
    leave
    ret
END_FUNC math_%1
%endmacro

MATH_SCALE degrees, mm_v_rad2deg
MATH_SCALE radians, mm_v_deg2rad

;; ============================================================================
;; The integer functions.  All of them are mpz-backed, because their whole
;; point is exactness -- math.gcd(2**100, 2**60) has no double in it anywhere.
;;
;; math_index turns a Value into a PyIntObject with a live mpz, and says
;; whether the caller has to release it: an int IMMEDIATE has no PyIntObject
;; at all, so one is made for it.
;; ============================================================================
MIX_VAL   equ 8
MIX_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL math_index, MIX_FRAME
    ; rdi = a Value -> rax = PyIntObject* with a live mpz, ecx = 1 when the
    ; caller must int_dealloc it.  rax = 0 when it is not an integer.
    mov [rbp - MIX_VAL], rdi
    V_UNPACK rdi, rdx
    push rdi
    push rdx
    call int_is_integer
    pop rdx
    pop rdi
    test eax, eax
    jz .mix_no

    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .mix_from_small
    mov rax, rdi
    INT_NEED_MPZ rax
    xor ecx, ecx
    leave
    ret
.mix_from_small:
    call smallint_to_pyint
    INT_NEED_MPZ rax
    mov ecx, 1
    leave
    ret
.mix_no:
    xor eax, eax
    xor ecx, ecx
    leave
    ret
END_FUNC math_index

;; math_int_result(rdi = a PyIntObject with a live mpz) -> rax = a Value.
;; Shrinks it, because an integer inside +-2^50 IS its Value: a boxed 2 is not
;; the 2 every other operation produces, and `math.gcd(4, 6) is 2` would be
;; False.
DEF_FUNC_LOCAL math_int_result
    call int_shrink
    leave
    ret
END_FUNC math_int_result

;; math_new_mpz() -> rax = a fresh GMP-backed PyIntObject, refcount 1
DEF_FUNC_LOCAL math_new_mpz, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov edi, PyIntObject_size
    call ap_malloc
    mov rbx, rax
    mov qword [rbx + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rbx + PyObject.ob_type], rcx
    mov qword [rbx + PyIntObject.compact], 0
    lea rdi, [rbx + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, rbx
    pop rbx
    leave
    ret
END_FUNC math_new_mpz

;; math_drop_temp(rdi = the PyIntObject, rsi = the owned flag)
DEF_FUNC_LOCAL math_drop_temp
    test rsi, rsi
    jz .mdt_done
    call int_dealloc
.mdt_done:
    leave
    ret
END_FUNC math_drop_temp

;; ============================================================================
;; MATH_INTVAR name, gmp_symbol, identity
;;
;; gcd and lcm take ANY number of arguments in CPython -- gcd() is 0, gcd(x)
;; is abs(x), and more than two chain -- so both fold over the argument list
;; from an identity.  GMP's gcd(0, x) and lcm(1, x) are |x|, which is what
;; makes the fold work with no special case for the first argument.
;; ============================================================================
MIV_ACC   equ 8
MIV_ARGS  equ 16
MIV_N     equ 24
MIV_IDX   equ 32
MIV_TMP   equ 40
MIV_OWN   equ 48
MIV_FRAME equ 64            ; + 0 pushes = 64, 16-aligned
%macro MATH_INTVAR 3
DEF_FUNC math_%1, MIV_FRAME
    mov [rbp - MIV_ARGS], rdi
    mov [rbp - MIV_N], rsi
    mov qword [rbp - MIV_IDX], 0

    call math_new_mpz
    mov [rbp - MIV_ACC], rax
    lea rdi, [rax + PyIntObject.mpz]
    mov esi, %3
    call __gmpz_set_si wrt ..plt

%%loop:
    mov rcx, [rbp - MIV_IDX]
    cmp rcx, [rbp - MIV_N]
    jge %%done
    mov rax, [rbp - MIV_ARGS]
    mov rdi, [rax + rcx*8]
    inc qword [rbp - MIV_IDX]
    call math_index
    test rax, rax
    jz %%type
    mov [rbp - MIV_TMP], rax
    mov [rbp - MIV_OWN], rcx

    mov rdi, [rbp - MIV_ACC]
    add rdi, PyIntObject.mpz
    mov rsi, rdi
    mov rdx, [rbp - MIV_TMP]
    add rdx, PyIntObject.mpz
    call %2 wrt ..plt

    mov rdi, [rbp - MIV_TMP]
    mov rsi, [rbp - MIV_OWN]
    call math_drop_temp
    jmp %%loop

%%done:
    mov rdi, [rbp - MIV_ACC]
    call math_int_result
    leave
    ret

%%type:
    mov rcx, [rbp - MIV_IDX]
    dec rcx
    mov rax, [rbp - MIV_ARGS]
    mov rsi, [rax + rcx*8]
    push rsi
    mov rdi, [rbp - MIV_ACC]
    call int_dealloc
    pop rsi
    CSTRING rdi, `'\x01' object cannot be interpreted as an integer`
    call raise_type_error_with_name
END_FUNC math_%1
%endmacro

MATH_INTVAR gcd, __gmpz_gcd, 0
MATH_INTVAR lcm, __gmpz_lcm, 1

;; ============================================================================
;; math_isqrt(n) -> the integer square root, for n >= 0
;; ============================================================================
MIS_N     equ 8
MIS_OWN   equ 16
MIS_RES   equ 24
MIS_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC math_isqrt, MIS_FRAME
    cmp rsi, 1
    jne .mis_args
    mov rdi, [rdi]
    mov [rbp - MIS_RES], rdi    ; keep the argument for the error message
    call math_index
    test rax, rax
    jz .mis_type
    mov [rbp - MIS_N], rax
    mov [rbp - MIS_OWN], rcx

    lea rdi, [rax + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    js .mis_negative

    call math_new_mpz
    mov [rbp - MIS_RES], rax    ; the result.  A `push` here would leave
                                ; __gmpz_sqrt below eight bytes out of
                                ; 16-alignment, and MIS_RES is free: the
                                ; argument it held is read only by .mis_type,
                                ; which is above math_index's success test.
    lea rdi, [rax + PyIntObject.mpz]
    mov rsi, [rbp - MIS_N]
    add rsi, PyIntObject.mpz
    call __gmpz_sqrt wrt ..plt
    mov rdi, [rbp - MIS_N]
    mov rsi, [rbp - MIS_OWN]
    call math_drop_temp
    mov rdi, [rbp - MIS_RES]
    call math_int_result
    leave
    ret

.mis_negative:
    mov rdi, [rbp - MIS_N]
    mov rsi, [rbp - MIS_OWN]
    call math_drop_temp
    RAISE exc_ValueError_type, "isqrt() argument must be nonnegative"
.mis_type:
    mov rsi, [rbp - MIS_RES]
    CSTRING rdi, `'\x01' object cannot be interpreted as an integer`
    call raise_type_error_with_name
.mis_args:
    lea rdi, [rel mm_n_isqrt]
    call math_raise_arity
END_FUNC math_isqrt

;; ============================================================================
;; math_factorial(n) -> n!, for a non-negative n that fits an unsigned long
;; ============================================================================
MFA_N     equ 8
MFA_OWN   equ 16
MFA_ARG   equ 24
MFA_K     equ 32            ; the count, across math_new_mpz's call
MFA_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC math_factorial, MFA_FRAME
    cmp rsi, 1
    jne .mfa_args
    mov rdi, [rdi]
    mov [rbp - MFA_ARG], rdi
    call math_index
    test rax, rax
    jz .mfa_type
    mov [rbp - MFA_N], rax
    mov [rbp - MFA_OWN], rcx

    lea rdi, [rax + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    js .mfa_negative

    mov rdi, [rbp - MFA_N]
    lea rdi, [rdi + PyIntObject.mpz]
    call __gmpz_fits_ulong_p wrt ..plt
    test eax, eax
    jz .mfa_toobig

    mov rdi, [rbp - MFA_N]
    lea rdi, [rdi + PyIntObject.mpz]
    call __gmpz_get_ui wrt ..plt
    mov [rbp - MFA_K], rax      ; a `push` here left math_new_mpz's own GMP
                                ; call eight bytes out of 16-alignment
    call math_new_mpz
    mov [rbp - MFA_ARG], rax
    lea rdi, [rax + PyIntObject.mpz]
    mov rsi, [rbp - MFA_K]
    call __gmpz_fac_ui wrt ..plt

    mov rdi, [rbp - MFA_N]
    mov rsi, [rbp - MFA_OWN]
    call math_drop_temp
    mov rdi, [rbp - MFA_ARG]
    call math_int_result
    leave
    ret

.mfa_negative:
    mov rdi, [rbp - MFA_N]
    mov rsi, [rbp - MFA_OWN]
    call math_drop_temp
    RAISE exc_ValueError_type, "factorial() not defined for negative values"
.mfa_toobig:
    mov rdi, [rbp - MFA_N]
    mov rsi, [rbp - MFA_OWN]
    call math_drop_temp
    RAISE exc_OverflowError_type, "factorial() argument should not exceed 20000000000000000"
.mfa_type:
    mov rsi, [rbp - MFA_ARG]
    CSTRING rdi, `'\x01' object cannot be interpreted as an integer`
    call raise_type_error_with_name
.mfa_args:
    lea rdi, [rel mm_n_factorial]
    call math_raise_arity
END_FUNC math_factorial

;; ============================================================================
;; math_comb(n, k) -> the binomial coefficient, 0 when k > n
;; ============================================================================
MCB_N     equ 8
MCB_OWNN  equ 16
MCB_K     equ 24
MCB_OWNK  equ 32
MCB_RES   equ 40
MCB_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC math_comb, MCB_FRAME
    cmp rsi, 2
    jne .mcb_args
    push rdi
    mov rdi, [rdi]
    call math_index
    test rax, rax
    jz .mcb_type_n
    mov [rbp - MCB_N], rax
    mov [rbp - MCB_OWNN], rcx
    mov rdi, [rsp]
    mov rdi, [rdi + 8]
    call math_index
    test rax, rax
    jz .mcb_type_k
    add rsp, 8
    mov [rbp - MCB_K], rax
    mov [rbp - MCB_OWNK], rcx

    ; Both have to be non-negative, and CPython names which one is not.
    mov rdi, [rbp - MCB_N]
    lea rdi, [rdi + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    js .mcb_neg_n
    mov rdi, [rbp - MCB_K]
    lea rdi, [rdi + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    js .mcb_neg_k

    ; k beyond an unsigned long means k > n for any n that exists, so the
    ; answer is 0 rather than an allocation the size of the universe.
    mov rdi, [rbp - MCB_K]
    lea rdi, [rdi + PyIntObject.mpz]
    call __gmpz_fits_ulong_p wrt ..plt
    test eax, eax
    jz .mcb_zero

    mov rdi, [rbp - MCB_K]
    lea rdi, [rdi + PyIntObject.mpz]
    call __gmpz_get_ui wrt ..plt
    push rax
    call math_new_mpz
    mov [rbp - MCB_RES], rax
    lea rdi, [rax + PyIntObject.mpz]
    mov rsi, [rbp - MCB_N]
    add rsi, PyIntObject.mpz
    pop rdx
    call __gmpz_bin_ui wrt ..plt
    jmp .mcb_done

.mcb_zero:
    call math_new_mpz
    mov [rbp - MCB_RES], rax

.mcb_done:
    mov rdi, [rbp - MCB_N]
    mov rsi, [rbp - MCB_OWNN]
    call math_drop_temp
    mov rdi, [rbp - MCB_K]
    mov rsi, [rbp - MCB_OWNK]
    call math_drop_temp
    mov rdi, [rbp - MCB_RES]
    call math_int_result
    leave
    ret

.mcb_neg_n:
    mov rdi, [rbp - MCB_N]
    mov rsi, [rbp - MCB_OWNN]
    call math_drop_temp
    mov rdi, [rbp - MCB_K]
    mov rsi, [rbp - MCB_OWNK]
    call math_drop_temp
    RAISE exc_ValueError_type, "n must be a non-negative integer"
.mcb_neg_k:
    mov rdi, [rbp - MCB_N]
    mov rsi, [rbp - MCB_OWNN]
    call math_drop_temp
    mov rdi, [rbp - MCB_K]
    mov rsi, [rbp - MCB_OWNK]
    call math_drop_temp
    RAISE exc_ValueError_type, "k must be a non-negative integer"
.mcb_type_n:
    pop rsi
    mov rsi, [rsi]
    jmp .mcb_type
.mcb_type_k:
    mov rdi, [rbp - MCB_N]
    mov rsi, [rbp - MCB_OWNN]
    call math_drop_temp
    pop rsi
    mov rsi, [rsi + 8]
.mcb_type:
    CSTRING rdi, `'\x01' object cannot be interpreted as an integer`
    call raise_type_error_with_name
.mcb_args:
    lea rdi, [rel mm_n_comb]
    call math_raise_arity2
END_FUNC math_comb

;; ============================================================================
;; math.perm(n, k=None) -> n! / (n - k)!, and n! when k is omitted.
;;
;; comb was here and perm was not, which is the odd half of the pair to be
;; missing: perm is the one the sampling and combinatorics code in the stdlib
;; actually calls.  GMP has no falling factorial, so this is bin(n, k) * k!,
;; which is exact and needs one temporary.
;; ============================================================================
MPM_N     equ 8
MPM_OWNN  equ 16
MPM_K     equ 24
MPM_OWNK  equ 32
MPM_RES   equ 40
MPM_TMP   equ 48
MPM_KUI   equ 56
MPM_FRAME equ 64            ; + 0 pushes = 64, 16-aligned
DEF_FUNC math_perm, MPM_FRAME
    cmp rsi, 1
    jl .mpm_args
    cmp rsi, 2
    jg .mpm_args
    push rdi
    push rsi
    mov rdi, [rdi]
    call math_index
    test rax, rax
    jz .mpm_type_n
    mov [rbp - MPM_N], rax
    mov [rbp - MPM_OWNN], rcx

    mov rsi, [rsp]
    cmp rsi, 2
    jl .mpm_k_is_n              ; perm(n) is n!
    mov rdi, [rsp + 8]
    mov rdi, [rdi + 8]
    ; perm(n, None) is n! as well.
    lea rax, [rel none_singleton]
    cmp rdi, rax
    je .mpm_k_is_n
    call math_index
    test rax, rax
    jz .mpm_type_k
    mov [rbp - MPM_K], rax
    mov [rbp - MPM_OWNK], rcx
    jmp .mpm_have_k

.mpm_k_is_n:
    ; k = n, which makes bin(n, n) * n! = n!.
    mov rax, [rbp - MPM_N]
    mov [rbp - MPM_K], rax
    mov qword [rbp - MPM_OWNK], 0

.mpm_have_k:
    add rsp, 16

    mov rdi, [rbp - MPM_N]
    lea rdi, [rdi + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    js .mpm_neg_n
    mov rdi, [rbp - MPM_K]
    lea rdi, [rdi + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    js .mpm_neg_k

    ; k larger than an unsigned long means k > n, so the answer is 0.
    mov rdi, [rbp - MPM_K]
    lea rdi, [rdi + PyIntObject.mpz]
    call __gmpz_fits_ulong_p wrt ..plt
    test eax, eax
    jz .mpm_zero

    mov rdi, [rbp - MPM_K]
    lea rdi, [rdi + PyIntObject.mpz]
    call __gmpz_get_ui wrt ..plt
    mov [rbp - MPM_KUI], rax

    call math_new_mpz
    mov [rbp - MPM_RES], rax
    lea rdi, [rax + PyIntObject.mpz]
    mov rsi, [rbp - MPM_N]
    add rsi, PyIntObject.mpz
    mov rdx, [rbp - MPM_KUI]
    call __gmpz_bin_ui wrt ..plt

    call math_new_mpz
    mov [rbp - MPM_TMP], rax
    lea rdi, [rax + PyIntObject.mpz]
    mov rsi, [rbp - MPM_KUI]
    call __gmpz_fac_ui wrt ..plt

    mov rdi, [rbp - MPM_RES]
    lea rdi, [rdi + PyIntObject.mpz]
    mov rsi, rdi
    mov rdx, [rbp - MPM_TMP]
    add rdx, PyIntObject.mpz
    call __gmpz_mul wrt ..plt

    mov rdi, [rbp - MPM_TMP]
    call int_dealloc
    jmp .mpm_done

.mpm_zero:
    call math_new_mpz
    mov [rbp - MPM_RES], rax

.mpm_done:
    call .mpm_release
    mov rdi, [rbp - MPM_RES]
    call math_int_result
    leave
    ret

.mpm_release:
    mov rdi, [rbp - MPM_N]
    mov rsi, [rbp - MPM_OWNN]
    call math_drop_temp
    mov rdi, [rbp - MPM_K]
    mov rsi, [rbp - MPM_OWNK]
    call math_drop_temp
    ret

.mpm_neg_n:
    call .mpm_release
    RAISE exc_ValueError_type, "n must be a non-negative integer"
.mpm_neg_k:
    call .mpm_release
    RAISE exc_ValueError_type, "k must be a non-negative integer"
.mpm_type_n:
    pop rsi
    pop rsi
    mov rsi, [rsi]
    jmp .mpm_type
.mpm_type_k:
    mov rdi, [rbp - MPM_N]
    mov rsi, [rbp - MPM_OWNN]
    call math_drop_temp
    pop rsi
    pop rsi
    mov rsi, [rsi + 8]
.mpm_type:
    CSTRING rdi, `'\x01' object cannot be interpreted as an integer`
    call raise_type_error_with_name
.mpm_args:
    lea rdi, [rel mm_n_perm]
    call math_raise_arity2
END_FUNC math_perm

;; ============================================================================
;; math.ulp(x) -> the distance from x to the next representable double
;;
;; CPython's m_ulp, including the top-of-range case where stepping upward
;; overflows to infinity and the step has to be taken downward instead.
;; ============================================================================
MUL_X     equ 8
MUL_OBJ   equ 16            ; the argument, for the type error
MUL_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC math_ulp, MUL_FRAME
    cmp rsi, 1
    jne .mul_args
    mov rdi, [rdi]
    ; The argument, kept for the error message.  MUL_X is written only once
    ; the conversion has succeeded -- and with the double, not the object --
    ; so the message read uninitialised stack as a Value.
    mov [rbp - MUL_OBJ], rdi
    call math_to_double
    test eax, eax
    jz .mul_type
    ; A NaN is its own ulp, and so is an infinity.
    ucomisd xmm0, xmm0
    jp .mul_self
    andpd xmm0, [rel mm_absmask]
    ucomisd xmm0, [rel mm_inf]
    je .mul_self
    movsd [rbp - MUL_X], xmm0
    movsd xmm1, [rel mm_inf]
    call nextafter wrt ..plt
    ; Stepping up from the largest finite double overflows; step down instead.
    movapd xmm2, xmm0
    andpd xmm2, [rel mm_absmask]
    ucomisd xmm2, [rel mm_inf]
    je .mul_top
    subsd xmm0, [rbp - MUL_X]
    call float_from_f64
    leave
    V_PACK rax, rdx
    ret
.mul_top:
    movsd xmm0, [rbp - MUL_X]
    movsd xmm1, [rel mm_inf]
    xorpd xmm2, xmm2
    subsd xmm2, xmm1
    movapd xmm1, xmm2           ; -inf
    call nextafter wrt ..plt
    movsd xmm1, xmm0
    movsd xmm0, [rbp - MUL_X]
    subsd xmm0, xmm1
    call float_from_f64
    leave
    V_PACK rax, rdx
    ret
.mul_self:
    call float_from_f64
    leave
    V_PACK rax, rdx
    ret
.mul_type:
    mov rsi, [rbp - MUL_OBJ]
    CSTRING rdi, `must be real number, not \x01`
    call raise_type_error_with_name
.mul_args:
    lea rdi, [rel mm_n_ulp]
    call math_raise_arity
END_FUNC math_ulp

;; ============================================================================
;; math_bind_kw(rdi = args, rsi = nargs, rdx = a NULL-terminated table of
;;              keyword names, rcx = an array of out slots, one per name)
;;   -> rax = the positional count
;;
;; math's three keyword-taking functions -- prod(start=), isclose(rel_tol=,
;; abs_tol=) -- all bind the same way, and nothing else in this module took a
;; keyword at all.  An unknown one raises.
;;
;; math_bind_kw_named is the same with r8 = the function's name as a C string,
;; so an unknown keyword is worded as CPython words it:
;; "'x' is an invalid keyword argument for print()".
;; ============================================================================
MBK_ARGS  equ 8
MBK_NPOS  equ 16
MBK_NAMES equ 24
MBK_OUT   equ 32
MBK_KW    equ 40
MBK_I     equ 48
MBK_FN    equ 56            ; the function's name, or 0 for the bare wording
MBK_BUF   equ 320           ; the message: four appends of at most 80 bytes
MBK_FRAME equ 320           ; + 0 pushes = 320, 16-aligned
global math_bind_kw
DEF_FUNC_BARE math_bind_kw
    xor r8d, r8d
    jmp math_bind_kw_named
END_FUNC math_bind_kw

;; math_bind_kw_named(rdi, rsi, rdx, rcx as math_bind_kw; r8 = the name)
;;   -> rax = the positional count
global math_bind_kw_named
DEF_FUNC math_bind_kw_named, MBK_FRAME
    mov [rbp - MBK_FN], r8
    mov [rbp - MBK_ARGS], rdi
    mov [rbp - MBK_NPOS], rsi
    mov [rbp - MBK_NAMES], rdx
    mov [rbp - MBK_OUT], rcx
    mov rax, [rel kw_names_pending]
    test rax, rax
    jz .mbk_done
    mov qword [rel kw_names_pending], 0
    mov [rbp - MBK_KW], rax
    mov rcx, [rax + PyTupleObject.ob_size]
    sub [rbp - MBK_NPOS], rcx
    mov qword [rbp - MBK_I], 0
.mbk_loop:
    mov rax, [rbp - MBK_KW]
    mov rcx, [rbp - MBK_I]
    cmp rcx, [rax + PyTupleObject.ob_size]
    jge .mbk_done
    mov rdx, [rax + PyTupleObject.ob_item]
    mov r8, [rdx + rcx*8]           ; the keyword's name
    mov rax, [rbp - MBK_NPOS]
    add rax, rcx
    mov rdx, [rbp - MBK_ARGS]
    mov r9, [rdx + rax*8]           ; the value

    xor r10d, r10d                  ; the name-table index
.mbk_match:
    mov rax, [rbp - MBK_NAMES]
    mov rax, [rax + r10*8]
    test rax, rax
    jz .mbk_unknown
    push r8
    push r9
    push r10
    sub rsp, 8
    lea rdi, [r8 + PyStrObject.data]
    mov rsi, rax
    call ap_strcmp
    add rsp, 8
    pop r10
    pop r9
    pop r8
    test eax, eax
    jz .mbk_hit
    inc r10
    jmp .mbk_match
.mbk_hit:
    mov rax, [rbp - MBK_OUT]
    mov [rax + r10*8], r9
    inc qword [rbp - MBK_I]
    jmp .mbk_loop
.mbk_unknown:
    cmp qword [rbp - MBK_FN], 0
    jne .mbk_named
    RAISE exc_TypeError_type, "invalid keyword argument"
.mbk_named:
    extern rbt_append_cstr
    mov [rbp - MBK_KW], r8          ; the offending name, for the message
    lea rdi, [rbp - MBK_BUF]
    CSTRING rsi, "'"
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - MBK_KW]
    lea rsi, [rsi + PyStrObject.data]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "' is an invalid keyword argument for "
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - MBK_FN]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "()"
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - MBK_BUF]
    call raise_exception
.mbk_done:
    mov rax, [rbp - MBK_NPOS]
    leave
    ret
END_FUNC math_bind_kw_named

;; ============================================================================
;; math.prod(iterable, *, start=1)
;;
;; Exact for integers, because it multiplies through the ordinary binary
;; operator rather than through a double: math.prod(range(1, 30)) is the same
;; integer CPython answers, not a float that lost the low bits.
;; ============================================================================
MPR_ACC   equ 8
MPR_ITER  equ 16
MPR_ITEM  equ 24
MPR_NEW   equ 32
MPR_EXC   equ 40
MPR_KWOUT equ 48            ; one slot: start
MPR_FRAME equ 64            ; + 2 pushes = 80, 16-aligned
DEF_FUNC math_prod, MPR_FRAME
    push rbx
    push r12
    mov rbx, rdi                    ; args, before math_bind_kw clobbers rdi
    mov qword [rbp - MPR_KWOUT], 0
    lea rdx, [rel mm_prod_kwnames]
    lea rcx, [rbp - MPR_KWOUT]
    call math_bind_kw
    mov r12, rax                    ; the positional count
    cmp r12, 1
    jne .mpr_args

    ; start defaults to the int 1.  It is keyword-only -- prod(iterable, /,
    ; *, start=1) -- so a second positional argument is a TypeError, which
    ; CPython's own test_prod checks.
    mov rax, [rbp - MPR_KWOUT]
    test rax, rax
    jnz .mpr_have_start
    mov rax, V_INT(1)
.mpr_have_start:
    mov [rbp - MPR_ACC], rax
    INCREF_V rax, rcx

    mov rdi, [rbx]
    V_TEST_PTR rdi, rax
    ja .mpr_not_iterable
    mov esi, TAG_PTR
    call get_iterator_opt
    test rax, rax
    jz .mpr_not_iterable
    mov [rbp - MPR_ITER], rax
    mov rbx, rax
    DUNDER_EXC_SAVE [rbp - MPR_EXC]

.mpr_loop:
    mov rdi, rbx
    call call_iternext
    test rax, rax
    jz .mpr_stop
    mov [rbp - MPR_ITEM], rax
    mov rdi, [rbp - MPR_ACC]
    mov rsi, rax
    mov edx, NB_MULTIPLY
    call obj_binary_op
    mov [rbp - MPR_NEW], rax
    mov rdi, [rbp - MPR_ITEM]
    DECREF_V rdi, rdx
    mov rdi, [rbp - MPR_ACC]
    DECREF_V rdi, rdx
    mov rax, [rbp - MPR_NEW]
    mov [rbp - MPR_ACC], rax
    test rax, rax
    jz .mpr_fail
    jmp .mpr_loop

.mpr_stop:
    EXC_RAISED_SINCE [rbp - MPR_EXC], rcx, .mpr_fail
    mov rdi, rbx
    call obj_decref
    mov rax, [rbp - MPR_ACC]
    pop r12
    pop rbx
    leave
    ret
.mpr_fail:
    mov rdi, rbx
    call obj_decref
    mov rdi, [rbp - MPR_ACC]
    XDECREF_V rdi, rcx
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
.mpr_not_iterable:
    mov rdi, [rbp - MPR_ACC]
    XDECREF_V rdi, rcx
    mov rsi, [rbx]
    CSTRING rdi, `'\x01' object is not iterable`
    call raise_type_error_with_name
.mpr_args:
    ; CPython's two wordings: the positional rule up to two, then the total.
    mov rsi, r12
    cmp r12, 2
    jg .mpr_too_many
    CSTRING rdi, "prod() takes exactly 1 positional argument ("
    CSTRING rdx, " given)"
    call raise_type_error_counted
.mpr_too_many:
    CSTRING rdi, "prod() takes at most 2 arguments ("
    CSTRING rdx, " given)"
    call raise_type_error_counted
END_FUNC math_prod

;; ============================================================================
;; math.isclose(a, b, *, rel_tol=1e-09, abs_tol=0.0)
;; PEP 485's definition, including the identity and infinity short-circuits.
;; ============================================================================
MIC_A     equ 8
MIC_B     equ 16
MIC_KWOUT equ 32            ; two slots: rel_tol and abs_tol, at -32 and -24
MIC_REL   equ 40            ; both tolerances, converted
MIC_ABS   equ 48
MIC_FRAME equ 64            ; + 0 pushes = 64
DEF_FUNC math_isclose, MIC_FRAME
    mov qword [rbp - MIC_KWOUT], 0
    mov qword [rbp - MIC_KWOUT + 8], 0
    lea rdx, [rel mm_isclose_kwnames]
    lea rcx, [rbp - MIC_KWOUT]
    push rdi
    sub rsp, 8
    call math_bind_kw
    add rsp, 8
    pop rdi
    cmp rax, 2
    jne .mic_args

    push rdi
    sub rsp, 8
    mov rdi, [rdi]
    call math_to_double
    test eax, eax
    jz .mic_type
    movsd [rbp - MIC_A], xmm0
    mov rdi, [rsp + 8]
    mov rdi, [rdi + 8]
    call math_to_double
    test eax, eax
    jz .mic_type
    add rsp, 16
    movsd [rbp - MIC_B], xmm0

    ; Both tolerances are converted and range-checked BEFORE anything is
    ; decided, which is the order CPython's argument clinic gives it:
    ; isclose(1.0, 1.0, rel_tol="x") is a TypeError, not True, and a negative
    ; tolerance is a ValueError even when the two values are equal.
    mov rdi, [rbp - MIC_KWOUT]
    test rdi, rdi
    jz .mic_default_rel
    mov [rbp - MIC_REL], rdi    ; the object, for the message if it is not one
    call math_to_double
    test eax, eax
    jz .mic_type_tol
    jmp .mic_have_rel
.mic_default_rel:
    movsd xmm0, [rel mm_default_rel_tol]
.mic_have_rel:
    movsd [rbp - MIC_REL], xmm0

    mov rdi, [rbp - MIC_KWOUT + 8]
    test rdi, rdi
    jz .mic_default_abs
    mov [rbp - MIC_ABS], rdi
    call math_to_double
    test eax, eax
    jz .mic_type_tol
    jmp .mic_have_abs
.mic_default_abs:
    xorpd xmm0, xmm0
.mic_have_abs:
    movsd [rbp - MIC_ABS], xmm0

    xorpd xmm1, xmm1
    ucomisd xmm1, [rbp - MIC_REL]
    ja .mic_negative_tol        ; 0 > rel_tol
    ucomisd xmm1, [rbp - MIC_ABS]
    ja .mic_negative_tol

    ; Equal is close, and that arm also settles two infinities of the
    ; same sign; an infinity against anything else never is.
    movsd xmm0, [rbp - MIC_A]
    ucomisd xmm0, [rbp - MIC_B]
    jp .mic_have_values         ; a NaN is close to nothing, including itself
    je .mic_true
.mic_have_values:
    movsd xmm0, [rbp - MIC_A]
    andpd xmm0, [rel mm_absmask]
    ucomisd xmm0, [rel mm_inf]
    je .mic_false
    movsd xmm0, [rbp - MIC_B]
    andpd xmm0, [rel mm_absmask]
    ucomisd xmm0, [rel mm_inf]
    je .mic_false

    ; |a - b| <= max(rel_tol * max(|a|, |b|), abs_tol).  Nothing below calls
    ; anything, so the working values stay in registers.
    movsd xmm0, [rbp - MIC_A]
    subsd xmm0, [rbp - MIC_B]
    andpd xmm0, [rel mm_absmask]
    movsd xmm3, xmm0            ; the difference

    movsd xmm1, [rbp - MIC_B]
    andpd xmm1, [rel mm_absmask]
    movsd xmm2, [rbp - MIC_A]
    andpd xmm2, [rel mm_absmask]
    maxsd xmm1, xmm2            ; max(|a|, |b|)
    movsd xmm4, [rbp - MIC_REL]
    mulsd xmm4, xmm1
    maxsd xmm4, [rbp - MIC_ABS]
    ucomisd xmm3, xmm4
    jbe .mic_true
.mic_false:
    lea rax, [rel bool_false]
    INCREF rax
    leave
    ret
.mic_true:
    lea rax, [rel bool_true]
    INCREF rax
    leave
    ret
.mic_type:
    add rsp, 16
    RAISE exc_TypeError_type, "must be real number"
.mic_type_tol:
    ; rdi still holds the tolerance that would not convert.
    mov rsi, rdi
    CSTRING rdi, `must be real number, not \x01`
    call raise_type_error_with_name
.mic_negative_tol:
    RAISE exc_ValueError_type, "tolerances must be non-negative"
.mic_args:
    RAISE exc_TypeError_type, "isclose() takes exactly 2 positional arguments"
END_FUNC math_isclose

;; ============================================================================
;; math.dist(p, q) -> the Euclidean distance between two points
;;
;; The differences are handed to the same routine hypot uses, so the two
;; always agree with each other.  (bugs.md records that our n-ary hypot rounds
;; differently from CPython's, which uses a compensated sum; dist inherits
;; that, and inherits the fix when it comes.)
;; ============================================================================
MDS_P     equ 8
MDS_Q     equ 16
MDS_BUF   equ 24
MDS_N     equ 32
MDS_I     equ 40
MDS_FRAME equ 48            ; + 2 pushes = 64, 16-aligned
DEF_FUNC math_dist, MDS_FRAME
    push rbx
    push r12
    cmp rsi, 2
    jne .mds_args
    mov qword [rbp - MDS_P], 0
    mov qword [rbp - MDS_Q], 0
    mov qword [rbp - MDS_BUF], 0

    push rdi
    sub rsp, 8
    mov rsi, rdi
    mov edx, 1
    lea rdi, [rel tuple_type]
    call tuple_type_call        ; materialise p; raises for a non-iterable
    test rax, rax
    jz .mds_failed_args
    mov [rbp - MDS_P], rax
    mov rsi, [rsp + 8]
    add rsi, 8                  ; &args[1]
    mov edx, 1
    lea rdi, [rel tuple_type]
    call tuple_type_call
    add rsp, 16
    test rax, rax
    jz .mds_failed
    mov [rbp - MDS_Q], rax

    mov rbx, [rbp - MDS_P]
    mov r12, [rbp - MDS_Q]
    mov rax, [rbx + PyTupleObject.ob_size]
    cmp rax, [r12 + PyTupleObject.ob_size]
    jne .mds_len_mismatch
    mov [rbp - MDS_N], rax
    test rax, rax
    jz .mds_zero

    ; One Value per coordinate difference, handed to the same routine hypot
    ; uses so the two always agree.
    lea rdi, [rax * 8]
    call ap_malloc
    test rax, rax
    jz .mds_failed
    mov [rbp - MDS_BUF], rax

    mov qword [rbp - MDS_I], 0
.mds_loop:
    mov rcx, [rbp - MDS_I]
    cmp rcx, [rbp - MDS_N]
    jge .mds_have_diffs
    mov rax, [rbx + PyTupleObject.ob_item]
    mov rdi, [rax + rcx*8]
    call math_to_double
    test eax, eax
    jz .mds_type
    movsd [rbp - MDS_FRAME], xmm0   ; scratch below the named slots
    mov rcx, [rbp - MDS_I]
    mov rax, [r12 + PyTupleObject.ob_item]
    mov rdi, [rax + rcx*8]
    call math_to_double
    test eax, eax
    jz .mds_type
    movsd xmm1, xmm0
    movsd xmm0, [rbp - MDS_FRAME]
    subsd xmm0, xmm1
    call float_from_f64
    V_PACK rax, rdx
    mov rcx, [rbp - MDS_I]
    mov rdx, [rbp - MDS_BUF]
    mov [rdx + rcx*8], rax
    inc qword [rbp - MDS_I]
    jmp .mds_loop

.mds_have_diffs:
    mov rdi, [rbp - MDS_BUF]
    mov rsi, [rbp - MDS_N]
    call math_hypot
    push rax
    call .mds_release
    pop rax
    pop r12                     ; rbx is the eval loop's bytecode IP and r12
    pop rbx                     ; its frame: `leave` alone discards both
    leave
    ret

.mds_zero:
    call .mds_release
    xorpd xmm0, xmm0
    call float_from_f64
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.mds_release:
    mov rdi, [rbp - MDS_BUF]
    test rdi, rdi
    jz .mds_rel_p
    call ap_free
    mov qword [rbp - MDS_BUF], 0
.mds_rel_p:
    mov rdi, [rbp - MDS_P]
    test rdi, rdi
    jz .mds_rel_q
    mov qword [rbp - MDS_P], 0
    call obj_decref
.mds_rel_q:
    mov rdi, [rbp - MDS_Q]
    test rdi, rdi
    jz .mds_rel_done
    mov qword [rbp - MDS_Q], 0
    call obj_decref
.mds_rel_done:
    ret

.mds_failed_args:
    add rsp, 16
.mds_failed:
    call .mds_release
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
.mds_type:
    call .mds_release
    pop r12
    pop rbx
    RAISE exc_TypeError_type, "must be real number"
.mds_len_mismatch:
    call .mds_release
    pop r12
    pop rbx
    RAISE exc_ValueError_type, "both points must have the same number of dimensions"
.mds_args:
    pop r12
    pop rbx
    lea rdi, [rel mm_n_dist]
    call math_raise_arity2
END_FUNC math_dist

section .rodata
align 8
mm_prod_kwnames:
    dq mm_kw_start
    dq 0
mm_isclose_kwnames:
    dq mm_kw_rel_tol
    dq mm_kw_abs_tol
    dq 0
mm_kw_start:   db "start", 0
mm_kw_rel_tol: db "rel_tol", 0
mm_kw_abs_tol: db "abs_tol", 0
align 8
mm_default_rel_tol: dq 0x3E112E0BE826D695      ; 1e-09
section .text

;; ============================================================================
;; math_log(x[, base]) -- one argument is the natural log, two is a ratio.
;; ============================================================================
MLG_X     equ 8
MLG_B     equ 16
MLG_ARGS  equ 24
MLG_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
;; ============================================================================
;; math_log_oversized(rdi = a Value, esi = 0 log, 1 log2, 2 log10)
;;   -> eax = 1 and xmm0 = the answer, or eax = 0 meaning "not an int that
;;      overflows a double, take the ordinary path"
;;
;; math.log(10**400) is 921.034..., not an error: CPython's loghelper splits
;; the integer into a mantissa and an exponent with frexp and computes
;; func(m) + func(2.0)*e, which needs no double large enough to hold the
;; argument.  Without it the conversion overflowed and the answer was an
;; infinity -- and once math_to_double started reporting that overflow
;; honestly, an OverflowError.
;;
;; Only the mpz arm can overflow; an int that fits an i64 is at most 9.2e18
;; and converts exactly enough.
;; ============================================================================
MLO_VAL   equ 8
MLO_OWN   equ 16
MLO_EXP   equ 24
MLO_KIND  equ 32
MLO_FRAME equ 48            ; + 0 pushes = 48, 16-aligned

DEF_FUNC_LOCAL math_log_oversized, MLO_FRAME
    mov [rbp - MLO_KIND], rsi
    call math_index
    test rax, rax
    jz .mlo_no
    mov [rbp - MLO_VAL], rax
    mov [rbp - MLO_OWN], rcx

    ; Does it fit a double?  If it does, nothing here is needed.
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_fits_slong_p wrt ..plt
    test eax, eax
    jnz .mlo_drop_no

    mov rdi, [rbp - MLO_VAL]
    lea rdi, [rdi + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    jle .mlo_domain             ; log of a non-positive integer

    lea rdi, [rbp - MLO_EXP]
    mov rsi, [rbp - MLO_VAL]
    lea rsi, [rsi + PyIntObject.mpz]
    call __gmpz_get_d_2exp wrt ..plt    ; xmm0 = m in [0.5, 1), MLO_EXP = e

    mov rdi, [rbp - MLO_VAL]
    mov rsi, [rbp - MLO_OWN]
    call math_drop_temp

    mov rax, [rbp - MLO_KIND]
    cmp rax, 1
    je .mlo_log2
    cmp rax, 2
    je .mlo_log10
    call log wrt ..plt
    movsd xmm1, [rel mm_ln2]
    jmp .mlo_combine
.mlo_log2:
    call log2 wrt ..plt
    movsd xmm1, [rel mm_log2_2]
    jmp .mlo_combine
.mlo_log10:
    call log10 wrt ..plt
    movsd xmm1, [rel mm_log10_2]
.mlo_combine:
    cvtsi2sd xmm2, qword [rbp - MLO_EXP]
    mulsd xmm1, xmm2
    addsd xmm0, xmm1
    mov eax, 1
    leave
    ret

.mlo_drop_no:
    mov rdi, [rbp - MLO_VAL]
    mov rsi, [rbp - MLO_OWN]
    call math_drop_temp
.mlo_no:
    xor eax, eax
    leave
    ret

.mlo_domain:
    mov rdi, [rbp - MLO_VAL]
    mov rsi, [rbp - MLO_OWN]
    call math_drop_temp
    RAISE exc_ValueError_type, "math domain error"
END_FUNC math_log_oversized

;; log2 and log10 wrap the generated one-argument forms so an oversized int
;; reaches the helper above before the conversion can overflow.
%macro MATH_LOG_WRAP 2          ; %1 = suffix, %2 = kind
DEF_FUNC_BARE math_%1_big
    cmp rsi, 1
    jne math_%1                 ; arity and type errors are its to word
    push rdi
    push rsi
    sub rsp, 8
    mov rdi, [rdi]
    mov esi, %2
    call math_log_oversized
    add rsp, 8
    pop rsi
    pop rdi
    test eax, eax
    jz math_%1
    sub rsp, 8
    call float_from_f64
    add rsp, 8
    V_PACK rax, rdx
    ret
END_FUNC math_%1_big
%endmacro

MATH_LOG_WRAP log2,  1
MATH_LOG_WRAP log10, 2

;; mlg_natural_log(rdi = a Value) -> eax = 1 and xmm0 = its natural log, or
;; eax = 0 when the argument is not a real number at all.  A domain error it
;; raises itself; the caller words the type error, which names the operand.
MNL_VAL   equ 8
MNL_FRAME equ 16            ; + 0 pushes = 16, 16-aligned

DEF_FUNC_LOCAL mlg_natural_log, MNL_FRAME
    mov [rbp - MNL_VAL], rdi
    xor esi, esi
    call math_log_oversized
    test eax, eax
    jnz .mnl_out
    mov rdi, [rbp - MNL_VAL]
    call math_to_double
    test eax, eax
    jz .mnl_no
    ; A NaN propagates; anything else must be strictly positive.
    ucomisd xmm0, xmm0
    jp .mnl_call
    pxor xmm1, xmm1
    ucomisd xmm0, xmm1
    jbe .mnl_domain
.mnl_call:
    call log wrt ..plt
.mnl_out:
    mov eax, 1
    leave
    ret
.mnl_no:
    xor eax, eax
    leave
    ret
.mnl_domain:
    RAISE exc_ValueError_type, "math domain error"
END_FUNC mlg_natural_log

DEF_FUNC math_log, MLG_FRAME
    cmp rsi, 1
    je .mlg_one
    cmp rsi, 2
    jne .mlg_args

    ; log(x, base) is two logs and a division, and each has its own way of
    ; going wrong.  This path took none of them: math.log(0, 10) answered
    ; -inf, math.log(-1, 2) answered nan and math.log(10, 1) answered inf,
    ; where CPython raises ValueError, ValueError and ZeroDivisionError.
    push rdi
    mov rdi, [rdi]
    call mlg_natural_log
    test eax, eax
    jz .mlg_type0
    movsd [rbp - MLG_X], xmm0

    mov rdi, [rsp]
    mov rdi, [rdi + 8]
    call mlg_natural_log
    test eax, eax
    jz .mlg_type1
    add rsp, 8

    ; base 1.0 gives log(base) == 0 exactly, which is CPython's
    ; ZeroDivisionError rather than an infinity.
    pxor xmm1, xmm1
    ucomisd xmm0, xmm1
    jp .mlg_two_div
    je .mlg_zerodiv
.mlg_two_div:
    movsd xmm1, xmm0
    movsd xmm0, [rbp - MLG_X]
    divsd xmm0, xmm1
    call float_from_f64
    leave
    V_PACK rax, rdx
    ret

.mlg_zerodiv:
    RAISE exc_ZeroDivisionError_type, "float division by zero"


.mlg_one:
    mov [rbp - MLG_ARGS], rdi
    mov rdi, [rdi]
    xor esi, esi
    call math_log_oversized
    test eax, eax
    jz .mlg_one_plain
    call float_from_f64
    leave
    V_PACK rax, rdx
    ret
.mlg_one_plain:
    mov rdi, [rbp - MLG_ARGS]
    mov esi, 1
    lea rdx, [rel mm_n_log]
    call math_arg1_double
    movsd [rbp - MLG_X], xmm0
    and rsp, -16
    call log wrt ..plt
    movsd xmm1, [rbp - MLG_X]
    xor edi, edi
    call math_ret_1
    leave
    ret

.mlg_type0:
    pop rsi
    mov rsi, [rsi]
    jmp .mlg_type
.mlg_type1:
    pop rsi
    mov rsi, [rsi + 8]
.mlg_type:
    CSTRING rdi, `must be real number, not \x01`
    call raise_type_error_with_name
.mlg_args:
    lea rdi, [rel mm_n_log]
    call math_raise_arity
END_FUNC math_log

;; ============================================================================
;; math_pow(x, y) -- glibc's pow, with CPython's special cases left to it:
;; for finite arguments the two agree, and math_ret_2 supplies the domain and
;; range errors.
;; ============================================================================
MATH_BINARY pow, pow

;; ============================================================================
;; math_ldexp(x, i) -> x * 2**i.  The exponent is an integer, not a double.
;; ============================================================================
MLD_X     equ 8
MLD_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC math_ldexp, MLD_FRAME
    cmp rsi, 2
    jne .mld_args
    push rdi
    mov rdi, [rdi]
    call math_to_double
    test eax, eax
    jz .mld_type
    movsd [rbp - MLD_X], xmm0
    pop rdi
    mov rdi, [rdi + 8]
    V_UNPACK rdi, rdx
    push rdi
    push rdx
    call int_is_integer
    pop rdx
    pop rdi
    test eax, eax
    jz .mld_exp_type
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .mld_have_exp
    ; A heap int that int_unwrap did not flatten is GMP-backed -- which does
    ; NOT mean it is large.  int.from_bytes promotes, and every arithmetic
    ; result built from one stays promoted, so `math.ldexp(m, e)` with an `e`
    ; computed from unpacked bytes was "math range error" for e = -23.  Ask
    ; the number, not its representation.
    push rdi
    sub rsp, 8
    lea rdi, [rdi + PyIntObject.mpz]
    extern __gmpz_fits_slong_p
    call __gmpz_fits_slong_p wrt ..plt
    add rsp, 8
    pop rdi
    test eax, eax
    jz .mld_overflow
    lea rdi, [rdi + PyIntObject.mpz]
    extern __gmpz_get_si
    call __gmpz_get_si wrt ..plt
    mov rdi, rax
.mld_have_exp:
    mov rsi, rdi
    cmp rsi, 2147483647
    jg .mld_overflow
    cmp rsi, -2147483648
    jl .mld_overflow
    movsd xmm0, [rbp - MLD_X]
    and rsp, -16
    call ldexp wrt ..plt
    movsd xmm1, [rbp - MLD_X]
    mov edi, 1                  ; ldexp can legitimately overflow
    call math_ret_1
    leave
    ret

.mld_overflow:
    RAISE exc_OverflowError_type, "math range error"
.mld_exp_type:
    RAISE exc_TypeError_type, "Expected an int as second argument to ldexp."
.mld_type:
    pop rsi
    mov rsi, [rsi]
    CSTRING rdi, `must be real number, not \x01`
    call raise_type_error_with_name
.mld_args:
    lea rdi, [rel mm_n_ldexp]
    call math_raise_arity2
END_FUNC math_ldexp

;; ============================================================================
;; math_frexp(x) -> (mantissa, exponent), with the non-finite cases settled
;; before the libm call as CPython settles them.
;; ============================================================================
MFR_E     equ 8
MFR_M     equ 16
MFR_TUP   equ 24
MFR_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC math_frexp, MFR_FRAME
    lea rdx, [rel mm_n_frexp]
    call math_arg1_double
    movsd [rbp - MFR_M], xmm0
    mov dword [rbp - MFR_E], 0

    movapd xmm1, xmm0
    andpd xmm1, [rel mm_absmask]
    ucomisd xmm1, [rel mm_inf]
    jp .mfr_build               ; NaN: (x, 0)
    je .mfr_build               ; inf: (x, 0)
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    je .mfr_build               ; +-0.0: (x, 0)

    lea rdi, [rbp - MFR_E]
    and rsp, -16
    call frexp wrt ..plt
    movsd [rbp - MFR_M], xmm0

.mfr_build:
    mov edi, 2
    call tuple_new
    mov [rbp - MFR_TUP], rax
    movsd xmm0, [rbp - MFR_M]
    call float_from_f64
    V_PACK rax, rdx
    mov rcx, [rbp - MFR_TUP]
    mov rdx, [rcx + PyTupleObject.ob_item]
    mov [rdx], rax
    ; A 32-bit field read into a 32-bit register, which zero-extends -- a
    ; 64-bit read here would OR in whatever sits above it.
    movsxd rdi, dword [rbp - MFR_E]
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - MFR_TUP]
    mov rdx, [rcx + PyTupleObject.ob_item]
    mov [rdx + 8], rax
    mov rax, rcx
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
END_FUNC math_frexp

;; ============================================================================
;; math_fsum(iterable) -> an exactly-rounded sum
;;
;; Shewchuk's algorithm, as CPython uses: a list of non-overlapping partial
;; sums, each new term folded into every partial with two-sum, so nothing is
;; ever rounded away.  Exactness is the whole reason fsum exists -- a
;; compensated sum would be very accurate and still not this -- which is why
;; it is done properly rather than approximated.
;; ============================================================================
FSM_ITER  equ 8
FSM_N     equ 16             ; how many partials are live
FSM_CAP   equ 24
FSM_P     equ 32             ; the partials array
FSM_X     equ 40
FSM_HI    equ 48
FSM_LO    equ 56
FSM_I     equ 64
FSM_SPEC  equ 72             ; a running inf/nan special, or 0.0
FSM_FRAME equ 80            ; + 0 pushes = 80, 16-aligned
FSUM_INITIAL equ 16
DEF_FUNC math_fsum, FSM_FRAME
    cmp rsi, 1
    jne .fsm_args
    mov rdi, [rdi]
    V_UNPACK rdi, rsi           ; get_iterator wants (payload, tag)
    call get_iterator
    test rax, rax
    jz .fsm_propagate
    mov [rbp - FSM_ITER], rax

    mov qword [rbp - FSM_N], 0
    mov qword [rbp - FSM_CAP], FSUM_INITIAL
    mov edi, FSUM_INITIAL * 8
    call ap_malloc
    mov [rbp - FSM_P], rax
    pxor xmm0, xmm0
    movsd [rbp - FSM_SPEC], xmm0

.fsm_next:
    mov rdi, [rbp - FSM_ITER]
    call call_iternext
    test rax, rax
    jz .fsm_end
    push rax
    mov rdi, rax
    call math_to_double
    pop rdi
    test eax, eax
    jz .fsm_type_item           ; the item is still ours, for the message
    movsd [rbp - FSM_X], xmm0
    DECREF_V rdi, rcx

    ; A non-finite term is carried separately: CPython adds them up and lets
    ; the ordinary float rules decide inf - inf.
    movsd xmm0, [rbp - FSM_X]
    movapd xmm1, xmm0
    andpd xmm1, [rel mm_absmask]
    ucomisd xmm1, [rel mm_inf]
    jp .fsm_special
    je .fsm_special

    ; Fold x into every partial, keeping the exact low halves.
    mov qword [rbp - FSM_I], 0
    xor r8d, r8d                ; how many partials survive
.fsm_fold:
    mov rcx, [rbp - FSM_I]
    cmp rcx, [rbp - FSM_N]
    jge .fsm_folded
    mov rdx, [rbp - FSM_P]
    movsd xmm1, [rdx + rcx*8]   ; y = partials[i]
    inc qword [rbp - FSM_I]

    ; two-sum(x, y): hi = x + y, lo = the part that did not fit
    movsd xmm0, [rbp - FSM_X]
    movapd xmm2, xmm0
    addsd xmm2, xmm1            ; hi
    movapd xmm3, xmm2
    subsd xmm3, xmm0            ; hi - x
    movapd xmm4, xmm1
    subsd xmm4, xmm3            ; y - (hi - x)
    movapd xmm5, xmm2
    subsd xmm5, xmm3            ; hi - (hi - x)
    movapd xmm6, xmm0
    subsd xmm6, xmm5            ; x - that
    addsd xmm4, xmm6            ; lo
    movsd [rbp - FSM_X], xmm2   ; x = hi

    ; A non-zero low half is a partial in its own right.
    pxor xmm7, xmm7
    ucomisd xmm4, xmm7
    jp .fsm_keep
    je .fsm_fold
.fsm_keep:
    mov rdx, [rbp - FSM_P]
    movsd [rdx + r8*8], xmm4
    inc r8
    jmp .fsm_fold

.fsm_folded:
    ; Every term that reached the fold was finite, so an infinite running sum
    ; means the partials themselves overflowed -- CPython reports that rather
    ; than letting it become a NaN two terms later.
    movsd xmm0, [rbp - FSM_X]
    movapd xmm1, xmm0
    andpd xmm1, [rel mm_absmask]
    ucomisd xmm1, [rel mm_inf]
    je .fsm_intermediate

    ; x itself becomes the last partial.  Grow first if the fold filled the
    ; array: it can produce one partial per existing one, plus x.
    mov rcx, r8
    inc rcx
    cmp rcx, [rbp - FSM_CAP]
    jl .fsm_room
    mov rcx, [rbp - FSM_CAP]
    shl rcx, 1
    mov [rbp - FSM_CAP], rcx
    mov rdi, [rbp - FSM_P]
    lea rsi, [rcx * 8]
    push r8
    call ap_realloc
    pop r8
    mov [rbp - FSM_P], rax
.fsm_room:
    mov rdx, [rbp - FSM_P]
    movsd xmm0, [rbp - FSM_X]
    movsd [rdx + r8*8], xmm0
    inc r8
    mov [rbp - FSM_N], r8
    jmp .fsm_next

.fsm_special:
    movsd xmm0, [rbp - FSM_SPEC]
    addsd xmm0, [rbp - FSM_X]
    movsd [rbp - FSM_SPEC], xmm0
    jmp .fsm_next

.fsm_end:
    ; An exception from the iterator is not the end of it.
    cmp qword [rel current_exception], 0
    jne .fsm_drop_propagate

    ; Sum the partials from the smallest up, which is what makes the last
    ; addition the only one that can round.
    pxor xmm0, xmm0
    mov rcx, [rbp - FSM_N]
.fsm_total:
    dec rcx
    js .fsm_have_total
    mov rdx, [rbp - FSM_P]
    addsd xmm0, [rdx + rcx*8]
    jmp .fsm_total
.fsm_have_total:
    addsd xmm0, [rbp - FSM_SPEC]
    movsd [rbp - FSM_X], xmm0
    mov rdi, [rbp - FSM_P]
    call ap_free
    mov rdi, [rbp - FSM_ITER]
    call obj_decref
    movsd xmm0, [rbp - FSM_X]
    call float_from_f64
    leave
    V_PACK rax, rdx
    ret

.fsm_intermediate:
    mov rdi, [rbp - FSM_P]
    call ap_free
    mov rdi, [rbp - FSM_ITER]
    call obj_decref
    RAISE exc_OverflowError_type, "intermediate overflow in fsum"
.fsm_type_item:
    ; CPython names the type, and the item is the last thing that knows it:
    ; the message is composed before the item is released.
    mov [rbp - FSM_X], rdi
    call value_type
    mov rsi, rax
    CSTRING rdi, `must be real number, not \x01`
    call type_name_message
    mov [rbp - FSM_HI], rax
    mov rdi, [rbp - FSM_X]
    DECREF_V rdi, rcx
    mov rdi, [rbp - FSM_P]
    call ap_free
    mov rdi, [rbp - FSM_ITER]
    call obj_decref
    lea rdi, [rel exc_TypeError_type]
    mov rsi, [rbp - FSM_HI]
    call raise_exception
.fsm_drop_propagate:
    mov rdi, [rbp - FSM_P]
    call ap_free
    mov rdi, [rbp - FSM_ITER]
    call obj_decref
.fsm_propagate:
    mov [rel eval_saved_r13], r13
    jmp eval_exception_unwind
.fsm_args:
    lea rdi, [rel mm_n_fsum]
    call math_raise_arity
END_FUNC math_fsum

;; ============================================================================
;; math_hypot(*coords) / math_dist(p, q) -- the Euclidean norm.
;;
;; Scaled: the sum of squares is formed after dividing by the largest
;; magnitude, so hypot(1e200, 1e200) does not overflow on the way to its
;; answer.  CPython's vector_norm does more than this -- Veltkamp-Dekker
;; splitting and a Neumaier sum -- so the last bit can differ for the n-ary
;; form.  The two-argument case goes to glibc's hypot, which agrees with
;; CPython's for every ordinary input.
;; ============================================================================
MHY_MAX   equ 8
MHY_SUM   equ 16
MHY_ARGS  equ 24
MHY_N     equ 32
MHY_I     equ 40
MHY_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC math_hypot, MHY_FRAME
    mov [rbp - MHY_ARGS], rdi
    mov [rbp - MHY_N], rsi
    cmp rsi, 2
    jne .mhy_general

    ; The two-argument case is glibc's, bit for bit.
    push rdi
    mov rdi, [rdi]
    call math_to_double
    test eax, eax
    jz .mhy_type0
    movsd [rbp - MHY_MAX], xmm0
    mov rdi, [rsp]
    mov rdi, [rdi + 8]
    call math_to_double
    test eax, eax
    jz .mhy_type1
    add rsp, 8
    movsd xmm1, xmm0
    movsd xmm0, [rbp - MHY_MAX]
    and rsp, -16
    call hypot wrt ..plt
    call float_from_f64
    leave
    V_PACK rax, rdx
    ret

.mhy_general:
    ; First pass: the largest magnitude, and any infinity wins outright.
    pxor xmm0, xmm0
    movsd [rbp - MHY_MAX], xmm0
    mov qword [rbp - MHY_I], 0
.mhy_max_loop:
    mov rcx, [rbp - MHY_I]
    cmp rcx, [rbp - MHY_N]
    jge .mhy_have_max
    mov rax, [rbp - MHY_ARGS]
    mov rdi, [rax + rcx*8]
    inc qword [rbp - MHY_I]
    call math_to_double
    test eax, eax
    jz .mhy_type_i
    andpd xmm0, [rel mm_absmask]
    ucomisd xmm0, [rel mm_inf]
    jp .mhy_not_inf             ; unordered: a NaN is not an infinity, and
    je .mhy_infinite            ; ucomisd sets ZF for both
.mhy_not_inf:
    ucomisd xmm0, [rbp - MHY_MAX]
    jbe .mhy_max_loop
    movsd [rbp - MHY_MAX], xmm0
    jmp .mhy_max_loop

.mhy_have_max:
    ; All zeros, or a single zero: the answer is 0.0 with no division.
    pxor xmm1, xmm1
    ucomisd xmm1, [rbp - MHY_MAX]
    je .mhy_zero
    movapd xmm1, xmm1
    ucomisd xmm1, [rbp - MHY_MAX]
    jp .mhy_zero                ; a NaN maximum: the sum will be NaN anyway

    pxor xmm0, xmm0
    movsd [rbp - MHY_SUM], xmm0
    mov qword [rbp - MHY_I], 0
.mhy_sum_loop:
    mov rcx, [rbp - MHY_I]
    cmp rcx, [rbp - MHY_N]
    jge .mhy_total
    mov rax, [rbp - MHY_ARGS]
    mov rdi, [rax + rcx*8]
    inc qword [rbp - MHY_I]
    call math_to_double
    divsd xmm0, [rbp - MHY_MAX]
    mulsd xmm0, xmm0
    addsd xmm0, [rbp - MHY_SUM]
    movsd [rbp - MHY_SUM], xmm0
    jmp .mhy_sum_loop

.mhy_total:
    movsd xmm0, [rbp - MHY_SUM]
    and rsp, -16
    call sqrt wrt ..plt
    mulsd xmm0, [rbp - MHY_MAX]
    call float_from_f64
    leave
    V_PACK rax, rdx
    ret

.mhy_zero:
    movsd xmm0, [rbp - MHY_MAX]
    call float_from_f64
    leave
    V_PACK rax, rdx
    ret

.mhy_infinite:
    movsd xmm0, [rel mm_inf]
    call float_from_f64
    leave
    V_PACK rax, rdx
    ret

.mhy_type_i:
    mov rcx, [rbp - MHY_I]
    dec rcx
    mov rax, [rbp - MHY_ARGS]
    mov rsi, [rax + rcx*8]
    jmp .mhy_type
.mhy_type0:
    pop rsi
    mov rsi, [rsi]
    jmp .mhy_type
.mhy_type1:
    pop rsi
    mov rsi, [rsi + 8]
.mhy_type:
    CSTRING rdi, `must be real number, not \x01`
    call raise_type_error_with_name
END_FUNC math_hypot

;; ============================================================================
;; math_sumprod(p, q) -> sum(a * b for a, b in zip(p, q, strict=True))
;;
;; statistics imports it by name, so its absence would fail that import
;; outright.
;;
;; CPython's math_sumprod_impl, path for path, because which path a pair takes
;; is observable.  The running total starts as the int 0 and is only ever
;; grown by the ordinary binary `+`.  Beside it run two fast paths, each of
;; which, once it declines a pair, is switched off for good and its partial sum
;; folded into the total:
;;
;;   int    -- both exact ints fitting an int64, summed in an int64 for as long
;;             as neither the product nor the sum overflows;
;;   float  -- an exact float with an exact float, int or bool, summed in
;;             triple-length arithmetic (CPython's tl_fma over an fma()) for as
;;             long as the running sum stays finite.
;;
;; Everything else is `total = total + p * q`, so a Fraction stays a Fraction,
;; a Decimal a Decimal and a complex a complex -- it used to be converted to a
;; double, so sumprod of two Fractions answered a float.  And because the fast
;; paths never come back, the float sum is the same double CPython's is:
;; [0.1, 2, 3] . [0.1, 4, 5] is 0.010000000000000002 + 8 + 15, added as
;; Python objects, not one compensated sum.
;; ============================================================================
MSF_INT_EN  equ 1
MSF_INT_USE equ 2
MSF_FLT_EN  equ 4
MSF_FLT_USE equ 8

; dl_sum(a, b): the error-free transformation of a sum (Ogita, Rump, Oishi
; Algorithm 3.1).  %1 = a, %2 = b (both kept), %3 = sum out, %4 = error out,
; %5 and %6 scratch.  Every operand is a distinct xmm register.
%macro MSP_DL_SUM 6
    movapd %3, %1
    addsd %3, %2                ; x = a + b
    movapd %5, %3
    subsd %5, %1                ; z = x - a
    movapd %6, %3
    subsd %6, %5                ; x - z
    movapd %4, %1
    subsd %4, %6                ; a - (x - z)
    movapd %6, %2
    subsd %6, %5                ; b - z
    addsd %4, %6                ; y = (a - (x - z)) + (b - z)
%endmacro

;; msp_exact_long(rdi = a Value) -> eax = 1 and rdx = its int64 when it is an
;; EXACT int (not a bool, not a subclass) that fits; eax = 0 otherwise.
;; CPython's PyLong_CheckExact plus PyLong_AsLongAndOverflow.
MEL_INT   equ 8
MEL_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL msp_exact_long, MEL_FRAME
    V_IS_INT rdi, rax
    jb .mel_ptr
    mov rdx, rdi
    V_TO_I64 rdx
    mov eax, 1
    leave
    ret
.mel_ptr:
    V_TEST_PTR rdi, rax
    ja .mel_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    jne .mel_no
    cmp qword [rdi + PyIntObject.compact], 0
    je .mel_mpz
    mov rdx, [rdi + PyIntObject.ival]
    mov eax, 1
    leave
    ret
.mel_mpz:
    mov [rbp - MEL_INT], rdi
    lea rdi, [rdi + PyIntObject.mpz]
    call __gmpz_fits_slong_p wrt ..plt
    test eax, eax
    jz .mel_no
    mov rdi, [rbp - MEL_INT]
    lea rdi, [rdi + PyIntObject.mpz]
    call __gmpz_get_si wrt ..plt
    mov rdx, rax
    mov eax, 1
    leave
    ret
.mel_no:
    xor eax, eax
    leave
    ret
END_FUNC msp_exact_long

;; msp_flt_kind(rdi = a Value) -> eax = 2 for an exact float, 1 for an exact
;; int or a bool whose double is finite, 0 for anything else; xmm0 = the
;; double for the first two.  An int too large for a double is 0, which is
;; where CPython's PyLong_AsDouble raised and sumprod cleared it.
MFK_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL msp_flt_kind, MFK_FRAME
    V_IS_FLOAT rdi, rax
    jae .mfk_not_float
    V_TO_F64 rdi
    movq xmm0, rdi
    mov eax, 2
    leave
    ret
.mfk_not_float:
    V_IS_INT rdi, rax
    jb .mfk_ptr
    V_TO_I64 rdi
    cvtsi2sd xmm0, rdi
    mov eax, 1
    leave
    ret
.mfk_ptr:
    V_TEST_PTR rdi, rax
    ja .mfk_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .mfk_heap_int
    lea rcx, [rel bool_type]
    cmp rax, rcx
    jne .mfk_no
.mfk_heap_int:
    mov esi, TAG_PTR
    call float_to_f64           ; rounds to nearest, as PyLong_AsDouble does
    movapd xmm1, xmm0
    andpd xmm1, [rel mm_absmask]
    ucomisd xmm1, [rel mm_inf]
    jae .mfk_no                 ; too large for a double
    mov eax, 1
    leave
    ret
.mfk_no:
    xor eax, eax
    leave
    ret
END_FUNC msp_flt_kind

;; msp_add_into(rdi = &total, rsi = term, owned) -> eax = 1, or 0 with an
;; exception pending.  *total = *total + term through the ordinary binary
;; operator; the term is released either way, the old total only on success.
MAI_SLOT  equ 8
MAI_TERM  equ 16
MAI_NEW   equ 24
MAI_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL msp_add_into, MAI_FRAME
    mov [rbp - MAI_SLOT], rdi
    mov [rbp - MAI_TERM], rsi
    mov rdi, [rdi]
    mov edx, NB_ADD
    call obj_binary_op
    mov [rbp - MAI_NEW], rax
    mov rdi, [rbp - MAI_TERM]
    DECREF_V rdi, rcx
    mov rax, [rbp - MAI_NEW]
    test rax, rax
    jz .mai_fail
    mov rcx, [rbp - MAI_SLOT]
    mov rdi, [rcx]
    mov [rcx], rax
    DECREF_V rdi, rcx
    mov eax, 1
    leave
    ret
.mai_fail:
    xor eax, eax
    leave
    ret
END_FUNC msp_add_into

;; math_sumprod(rdi = args, rsi = nargs) -> rax = the total Value, or 0 with
;; an exception pending.  The paths are described above msp_exact_long.
MSP_ARGS  equ 8
MSP_IP    equ 16
MSP_IQ    equ 24
MSP_A     equ 32
MSP_B     equ 40
MSP_TOTAL equ 48            ; the Python-level total, a Value we own
MSP_ITOT  equ 56            ; the int path's int64
MSP_HI    equ 64            ; the float path's triple-length sum
MSP_LO    equ 72
MSP_TINY  equ 80
MSP_FLAGS equ 88            ; MSF_*
MSP_STOP  equ 96            ; bit 0: p is exhausted, bit 1: q is
MSP_EXC   equ 104
MSP_X     equ 112
MSP_Y     equ 120
MSP_Z     equ 128
MSP_KIND  equ 136
MSP_FRAME equ 144           ; + 0 pushes = 144, 16-aligned
DEF_FUNC math_sumprod, MSP_FRAME
    cmp rsi, 2
    jne .msp_args
    mov [rbp - MSP_ARGS], rdi
    xor eax, eax
    mov [rbp - MSP_IP], rax
    mov [rbp - MSP_IQ], rax
    mov [rbp - MSP_A], rax
    mov [rbp - MSP_B], rax
    mov [rbp - MSP_ITOT], rax
    mov [rbp - MSP_HI], rax     ; +0.0, bit for bit
    mov [rbp - MSP_LO], rax
    mov [rbp - MSP_TINY], rax
    mov qword [rbp - MSP_FLAGS], MSF_INT_EN | MSF_FLT_EN
    mov rax, V_INT(0)
    mov [rbp - MSP_TOTAL], rax
    DUNDER_EXC_SAVE [rbp - MSP_EXC]

    mov rdi, [rbp - MSP_ARGS]
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .msp_p_not_iter
    mov esi, TAG_PTR
    call get_iterator_opt
    test rax, rax
    jz .msp_p_not_iter
    mov [rbp - MSP_IP], rax
    mov rdi, [rbp - MSP_ARGS]
    mov rdi, [rdi + 8]
    V_TEST_PTR rdi, rax
    ja .msp_q_not_iter
    mov esi, TAG_PTR
    call get_iterator_opt
    test rax, rax
    jz .msp_q_not_iter
    mov [rbp - MSP_IQ], rax

.msp_loop:
    mov qword [rbp - MSP_STOP], 0
    mov rdi, [rbp - MSP_IP]
    call call_iternext
    mov [rbp - MSP_A], rax
    test rax, rax
    jnz .msp_next_q
    EXC_RAISED_SINCE [rbp - MSP_EXC], rcx, .msp_fail
    or qword [rbp - MSP_STOP], 1
.msp_next_q:
    mov rdi, [rbp - MSP_IQ]
    call call_iternext
    mov [rbp - MSP_B], rax
    test rax, rax
    jnz .msp_have_pair
    EXC_RAISED_SINCE [rbp - MSP_EXC], rcx, .msp_fail
    or qword [rbp - MSP_STOP], 2
.msp_have_pair:
    mov rax, [rbp - MSP_STOP]
    cmp rax, 1
    je .msp_length
    cmp rax, 2
    je .msp_length

    ; --- the int path ---
    test qword [rbp - MSP_FLAGS], MSF_INT_EN
    jz .msp_flt
    test rax, rax
    jnz .msp_int_fin
    mov rdi, [rbp - MSP_A]
    call msp_exact_long
    test eax, eax
    jz .msp_int_fin
    mov [rbp - MSP_X], rdx
    mov rdi, [rbp - MSP_B]
    call msp_exact_long
    test eax, eax
    jz .msp_int_fin
    imul rdx, [rbp - MSP_X]
    jo .msp_int_fin
    add rdx, [rbp - MSP_ITOT]
    jo .msp_int_fin
    mov [rbp - MSP_ITOT], rdx
    or qword [rbp - MSP_FLAGS], MSF_INT_USE
    jmp .msp_release
.msp_int_fin:
    ; Finished, overflowed, or not an int: the int path is over for good.
    and qword [rbp - MSP_FLAGS], ~MSF_INT_EN
    test qword [rbp - MSP_FLAGS], MSF_INT_USE
    jz .msp_flt
    and qword [rbp - MSP_FLAGS], ~MSF_INT_USE
    mov rdi, [rbp - MSP_ITOT]
    call val_from_i64
    mov rsi, rax
    lea rdi, [rbp - MSP_TOTAL]
    call msp_add_into
    test eax, eax
    jz .msp_fail

.msp_flt:
    ; --- the float path ---
    test qword [rbp - MSP_FLAGS], MSF_FLT_EN
    jz .msp_generic
    cmp qword [rbp - MSP_STOP], 0
    jne .msp_flt_fin
    mov rdi, [rbp - MSP_A]
    call msp_flt_kind
    mov [rbp - MSP_KIND], rax
    movsd [rbp - MSP_X], xmm0
    mov rdi, [rbp - MSP_B]
    call msp_flt_kind
    movsd [rbp - MSP_Y], xmm0
    ; A float with a float, int or bool: both kinds non-zero, one of them 2.
    mov rcx, [rbp - MSP_KIND]
    test eax, eax
    jz .msp_flt_fin
    test ecx, ecx
    jz .msp_flt_fin
    cmp eax, 2
    je .msp_flt_take
    cmp ecx, 2
    jne .msp_flt_fin
.msp_flt_take:
    ; tl_fma: the product exactly, as z + zz ...
    movsd xmm0, [rbp - MSP_X]
    mulsd xmm0, [rbp - MSP_Y]
    movsd [rbp - MSP_Z], xmm0
    movapd xmm2, xmm0
    xorpd xmm2, [rel mm_signbit]
    movsd xmm0, [rbp - MSP_X]
    movsd xmm1, [rbp - MSP_Y]
    call fma wrt ..plt          ; zz = fma(x, y, -z)
    ; ... then SumKVert with K=3 into (hi, lo, tiny).
    movapd xmm9, xmm0
    movsd xmm8, [rbp - MSP_LO]
    MSP_DL_SUM xmm8, xmm9, xmm12, xmm13, xmm14, xmm15     ; r1
    movsd xmm8, [rbp - MSP_HI]
    movsd xmm9, [rbp - MSP_Z]
    MSP_DL_SUM xmm8, xmm9, xmm10, xmm11, xmm14, xmm15     ; sm
    MSP_DL_SUM xmm12, xmm11, xmm8, xmm9, xmm14, xmm15     ; r2 = dl_sum(r1.hi, sm.lo)
    movsd xmm0, [rbp - MSP_TINY]
    addsd xmm0, xmm13
    addsd xmm0, xmm9
    ; Only a finite sum is kept; an infinity or a NaN goes the generic way.
    movapd xmm1, xmm10
    andpd xmm1, [rel mm_absmask]
    ucomisd xmm1, [rel mm_inf]
    jp .msp_flt_fin
    jae .msp_flt_fin
    movsd [rbp - MSP_HI], xmm10
    movsd [rbp - MSP_LO], xmm8
    movsd [rbp - MSP_TINY], xmm0
    or qword [rbp - MSP_FLAGS], MSF_FLT_USE
    jmp .msp_release
.msp_flt_fin:
    and qword [rbp - MSP_FLAGS], ~MSF_FLT_EN
    test qword [rbp - MSP_FLAGS], MSF_FLT_USE
    jz .msp_generic
    and qword [rbp - MSP_FLAGS], ~MSF_FLT_USE
    ; tl_to_d: tiny + last.lo + last.hi, last = dl_sum(lo, hi)
    movsd xmm8, [rbp - MSP_LO]
    movsd xmm9, [rbp - MSP_HI]
    MSP_DL_SUM xmm8, xmm9, xmm10, xmm11, xmm14, xmm15
    movsd xmm0, [rbp - MSP_TINY]
    addsd xmm0, xmm11
    addsd xmm0, xmm10
    movq rsi, xmm0
    V_FROM_F64 rsi, rax
    lea rdi, [rbp - MSP_TOTAL]
    call msp_add_into
    test eax, eax
    jz .msp_fail

.msp_generic:
    cmp qword [rbp - MSP_STOP], 0
    jne .msp_done
    mov rdi, [rbp - MSP_A]
    mov rsi, [rbp - MSP_B]
    mov edx, NB_MULTIPLY
    call obj_binary_op
    test rax, rax
    jz .msp_fail
    mov rsi, rax
    lea rdi, [rbp - MSP_TOTAL]
    call msp_add_into
    test eax, eax
    jz .msp_fail

.msp_release:
    mov rdi, [rbp - MSP_A]
    mov qword [rbp - MSP_A], 0
    DECREF_V rdi, rcx
    mov rdi, [rbp - MSP_B]
    mov qword [rbp - MSP_B], 0
    DECREF_V rdi, rcx
    jmp .msp_loop

.msp_done:
    mov rdi, [rbp - MSP_IP]
    call obj_decref
    mov rdi, [rbp - MSP_IQ]
    call obj_decref
    mov rax, [rbp - MSP_TOTAL]
    leave
    ret

.msp_length:
    SET_EXC exc_ValueError_type, "Inputs are not the same length"
.msp_fail:
    mov rdi, [rbp - MSP_A]
    DECREF_V rdi, rcx
    mov rdi, [rbp - MSP_B]
    DECREF_V rdi, rcx
    mov rdi, [rbp - MSP_TOTAL]
    DECREF_V rdi, rcx
    mov rdi, [rbp - MSP_IP]
    test rdi, rdi
    jz .msp_fail_q
    call obj_decref
.msp_fail_q:
    mov rdi, [rbp - MSP_IQ]
    test rdi, rdi
    jz .msp_fail_ret
    call obj_decref
.msp_fail_ret:
    xor eax, eax
    leave
    ret

.msp_q_not_iter:
    EXC_RAISED_SINCE [rbp - MSP_EXC], rcx, .msp_fail
    mov rdi, [rbp - MSP_IP]
    call obj_decref
    mov rsi, [rbp - MSP_ARGS]
    mov rsi, [rsi + 8]
    CSTRING rdi, `'\x01' object is not iterable`
    call raise_type_error_with_name
.msp_p_not_iter:
    EXC_RAISED_SINCE [rbp - MSP_EXC], rcx, .msp_fail
    mov rsi, [rbp - MSP_ARGS]
    mov rsi, [rsi]
    CSTRING rdi, `'\x01' object is not iterable`
    call raise_type_error_with_name
.msp_args:
    lea rdi, [rel mm_n_sumprod]
    call math_raise_arity2
END_FUNC math_sumprod

;; ============================================================================
;; The predicates.  They take a DOUBLE in CPython, so math.isnan(1) is legal
;; and answers False; and they answer a bool rather than going through the
;; error rule, since neither NaN nor infinity is an error to ask about.
;; ============================================================================
%macro MATH_PREDICATE 1
DEF_FUNC math_is%1
    lea rdx, [rel mm_n_is%1]
    call math_arg1_double
    movapd xmm1, xmm0
    andpd xmm1, [rel mm_absmask]
%ifidn %1, nan
    ucomisd xmm0, xmm0
    setp al
    movzx eax, al
%elifidn %1, inf
    ucomisd xmm1, [rel mm_inf]
    sete al
    setnp cl
    and al, cl
    movzx eax, al
%else
    ; finite: neither NaN nor infinite.  setb alone is not enough -- ucomisd
    ; sets CF for UNORDERED as well as for below, so a NaN read as finite.
    ucomisd xmm1, [rel mm_inf]
    setb al
    setnp cl
    and al, cl
    movzx eax, al
%endif
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx
    ret
END_FUNC math_is%1
%endmacro

MATH_PREDICATE nan
MATH_PREDICATE inf
MATH_PREDICATE finite

;; ============================================================================
;; math_module_create() -> PyObject*
;; ============================================================================
;; MATH_ADD_FLOAT name_cstr, label holding the raw bits.  r12 = the dict.
;; A float Value owns nothing, so there is no DECREF for the value -- unlike
;; the int form, where V_PACK on anything outside +-2^50 allocates.
%macro MATH_ADD_FLOAT 2
    lea rdi, [rel %1]
    call str_from_cstr_heap
    push rax
    mov rdx, [rel %2]
    V_FROM_F64 rdx, rcx
    mov rdi, r12
    mov rsi, [rsp]
    call dict_set
    pop rdi
    call obj_decref
%endmacro

MMC_FRAME equ 8             ; + 3 pushes = 32, 16-aligned
DEF_FUNC math_module_create, MMC_FRAME
    push rbx
    push r12
    push r13

    call dict_new
    mov r12, rax                ; MODULE_ADD_FUNC reads the dict from r12

    MODULE_ADD_FUNC math_sqrt,      mm_n_sqrt
    MODULE_ADD_FUNC math_perm,      mm_n_perm
    MODULE_ADD_FUNC math_ulp,       mm_n_ulp
    MODULE_ADD_FUNC math_prod,      mm_n_prod
    MODULE_ADD_FUNC math_isclose,   mm_n_isclose
    MODULE_ADD_FUNC math_dist,      mm_n_dist
    MODULE_ADD_FUNC math_exp,       mm_n_exp
    MODULE_ADD_FUNC math_expm1,     mm_n_expm1
    MODULE_ADD_FUNC math_exp2,      mm_n_exp2
    MODULE_ADD_FUNC math_log2_big,  mm_n_log2
    MODULE_ADD_FUNC math_log10_big, mm_n_log10
    MODULE_ADD_FUNC math_log1p,     mm_n_log1p
    MODULE_ADD_FUNC math_sin,       mm_n_sin
    MODULE_ADD_FUNC math_cos,       mm_n_cos
    MODULE_ADD_FUNC math_tan,       mm_n_tan
    MODULE_ADD_FUNC math_asin,      mm_n_asin
    MODULE_ADD_FUNC math_acos,      mm_n_acos
    MODULE_ADD_FUNC math_atan,      mm_n_atan
    MODULE_ADD_FUNC math_sinh,      mm_n_sinh
    MODULE_ADD_FUNC math_cosh,      mm_n_cosh
    MODULE_ADD_FUNC math_tanh,      mm_n_tanh
    MODULE_ADD_FUNC math_asinh,     mm_n_asinh
    MODULE_ADD_FUNC math_acosh,     mm_n_acosh
    MODULE_ADD_FUNC math_atanh,     mm_n_atanh
    MODULE_ADD_FUNC math_cbrt,      mm_n_cbrt
    MODULE_ADD_FUNC math_erf,       mm_n_erf
    MODULE_ADD_FUNC math_erfc,      mm_n_erfc
    MODULE_ADD_FUNC math_gamma,     mm_n_gamma
    MODULE_ADD_FUNC math_lgamma,    mm_n_lgamma
    MODULE_ADD_FUNC math_fabs,      mm_n_fabs
    MODULE_ADD_FUNC math_atan2,     mm_n_atan2
    MODULE_ADD_FUNC math_copysign,  mm_n_copysign
    MODULE_ADD_FUNC math_fmod,      mm_n_fmod
    MODULE_ADD_FUNC math_remainder, mm_n_remainder
    MODULE_ADD_FUNC math_nextafter, mm_n_nextafter
    MODULE_ADD_FUNC math_isnan,     mm_n_isnan
    MODULE_ADD_FUNC math_isinf,     mm_n_isinf
    MODULE_ADD_FUNC math_isfinite,  mm_n_isfinite
    MODULE_ADD_FUNC math_floor,     mm_n_floor
    MODULE_ADD_FUNC math_ceil,      mm_n_ceil
    MODULE_ADD_FUNC math_trunc,     mm_n_trunc
    MODULE_ADD_FUNC math_modf,      mm_n_modf
    MODULE_ADD_FUNC math_degrees,   mm_n_degrees
    MODULE_ADD_FUNC math_radians,   mm_n_radians
    MODULE_ADD_FUNC math_gcd,       mm_n_gcd
    MODULE_ADD_FUNC math_lcm,       mm_n_lcm
    MODULE_ADD_FUNC math_isqrt,     mm_n_isqrt
    MODULE_ADD_FUNC math_factorial, mm_n_factorial
    MODULE_ADD_FUNC math_comb,      mm_n_comb
    MODULE_ADD_FUNC math_log,       mm_n_log
    MODULE_ADD_FUNC math_pow,       mm_n_pow
    MODULE_ADD_FUNC math_ldexp,     mm_n_ldexp
    MODULE_ADD_FUNC math_frexp,     mm_n_frexp
    MODULE_ADD_FUNC math_fsum,      mm_n_fsum
    MODULE_ADD_FUNC math_hypot,     mm_n_hypot
    MODULE_ADD_FUNC math_sumprod,   mm_n_sumprod

    MATH_ADD_FLOAT mm_n_pi,  mm_v_pi
    MATH_ADD_FLOAT mm_n_e,   mm_v_e
    MATH_ADD_FLOAT mm_n_tau, mm_v_tau
    MATH_ADD_FLOAT mm_n_inf_c, mm_v_inf
    MATH_ADD_FLOAT mm_n_nan_c, mm_v_nan

    lea rdi, [rel mm_n_math]
    call str_from_cstr_heap
    push rax
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov r13, rax
    pop rdi
    call obj_decref             ; module_new took its own
    mov rdi, r12
    call obj_decref
    mov rax, r13

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC math_module_create

section .rodata
; andpd is a 128-bit operation and its memory operand must be 16-byte
; aligned, so the mask is a full xmm word.  An 8-byte `dq` at `align 8` here
; faulted on the first call -- SIGSEGV inside math_ret_1, not a wrong answer.
align 16
mm_absmask: dq 0x7fffffffffffffff, 0x7fffffffffffffff
mm_signbit: dq 0x8000000000000000, 0x8000000000000000
align 8
mm_inf:     dq 0x7ff0000000000000
mm_ln2:     dq 0.6931471805599453      ; log(2.0), log2(2.0), log10(2.0):
mm_log2_2:  dq 1.0                     ; the second term of CPython's
mm_log10_2: dq 0.30102999566398120     ; loghelper, one per base
mm_math_dot:  db "math.", 0
mm_takes_one: db "() takes exactly one argument (", 0
mm_given:     db " given)", 0
mm_expected2: db " expected 2 arguments, got ", 0

mm_n_sqrt: db "sqrt", 0
mm_n_exp: db "exp", 0
mm_n_expm1: db "expm1", 0
mm_n_exp2: db "exp2", 0
mm_n_sinh: db "sinh", 0
mm_n_cosh: db "cosh", 0
mm_n_log2: db "log2", 0
mm_n_log10: db "log10", 0
mm_n_log1p: db "log1p", 0
mm_n_sin: db "sin", 0
mm_n_cos: db "cos", 0
mm_n_tan: db "tan", 0
mm_n_asin: db "asin", 0
mm_n_acos: db "acos", 0
mm_n_atan: db "atan", 0
mm_n_tanh: db "tanh", 0
mm_n_asinh: db "asinh", 0
mm_n_acosh: db "acosh", 0
mm_n_atanh: db "atanh", 0
mm_n_cbrt: db "cbrt", 0
mm_n_erf: db "erf", 0
mm_n_erfc: db "erfc", 0
mm_n_gamma: db "gamma", 0
mm_n_lgamma: db "lgamma", 0
mm_n_fabs: db "fabs", 0
mm_n_atan2: db "atan2", 0
mm_n_copysign: db "copysign", 0
mm_n_fmod: db "fmod", 0
mm_n_remainder: db "remainder", 0
mm_n_nextafter: db "nextafter", 0

mm_n_math:  db "math", 0
mm_n_pi:    db "pi", 0
mm_n_e:     db "e", 0
mm_n_tau:   db "tau", 0
mm_n_inf_c: db "inf", 0
mm_n_nan_c: db "nan", 0
mm_n_isnan:    db "isnan", 0
mm_n_isinf:    db "isinf", 0
mm_n_isfinite: db "isfinite", 0

align 8
mm_v_pi:  dq 0x400921fb54442d18     ; 3.141592653589793
mm_v_e:   dq 0x4005bf0a8b145769     ; 2.718281828459045
mm_v_tau: dq 0x401921fb54442d18     ; 6.283185307179586
mm_v_inf: dq 0x7ff0000000000000
; A POSITIVE quiet NaN: V_FROM_F64 canonicalises only the negative ones, so
; this survives unchanged and copysign(1.0, math.nan) is 1.0, as CPython has.
mm_v_nan: dq 0x7ff8000000000000

mm_d_floor: db "__floor__", 0
mm_d_ceil:  db "__ceil__", 0
mm_d_trunc: db "__trunc__", 0
mm_n_floor: db "floor", 0
mm_n_ceil:  db "ceil", 0
mm_n_trunc: db "trunc", 0
mm_n_modf:  db "modf", 0
mm_n_degrees: db "degrees", 0
mm_n_radians: db "radians", 0

align 8
mm_v_rad2deg: dq 0x404ca5dc1a63c1f8  ; 180/pi
mm_v_deg2rad: dq 0x3f91df46a2529d39  ; pi/180
mm_n_isqrt: db "isqrt", 0
mm_n_factorial: db "factorial", 0
mm_n_comb: db "comb", 0
mm_n_perm: db "perm", 0
mm_n_ulp: db "ulp", 0
mm_n_prod: db "prod", 0
mm_n_isclose: db "isclose", 0
mm_n_dist: db "dist", 0
mm_n_gcd: db "gcd", 0
mm_n_lcm: db "lcm", 0
mm_n_log: db "log", 0
mm_n_pow: db "pow", 0
mm_n_ldexp: db "ldexp", 0
mm_n_frexp: db "frexp", 0
mm_n_fsum: db "fsum", 0
mm_n_hypot: db "hypot", 0
mm_n_sumprod: db "sumprod", 0
