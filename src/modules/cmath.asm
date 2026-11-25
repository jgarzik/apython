; cmath.asm - the `cmath` module: the math functions over complex numbers.
;
; The same shape as src/modules/math.asm, which is the file to read first: one
; funnel that turns an argument into the machine's own representation, one
; that turns the result back, and a macro per arity so that each function is
; the two calls and the libm name between them.
;
; What differs is the representation.  A C99 `double complex` is two SSE
; eightbytes under the SysV ABI -- passed in xmm0 and xmm1, returned in xmm0
; and xmm1 -- which is exactly how a PyComplexObject's two doubles already
; arrive from complex_to_parts and leave through complex_from_doubles.  So
; `csqrt` and its sixteen siblings are reached directly, with no marshalling
; at all, the same way math.asm reaches `sqrt`.
;
; The branch cuts are libm's, and they are C99's, which is where CPython took
; its own from: the cut for sqrt and log runs along the negative real axis and
; is continuous with the SECOND quadrant, so csqrt(-1 + 0j) is +1j and
; csqrt(-1 - 0j) is -1j.  That is why the sign of a zero matters here in a way
; it does not in math.asm, and why tests/test_cmath.py is driven from
; CPython's own cmath_testcases.txt rather than from a handful of values.
;
; Not here: `isclose`, which is a comparison rather than a function of one
; complex number, and the four predicates, which are -- but all five read the
; parts rather than calling libm, so they are written out below.

%include "macros.inc"
%include "object.inc"

extern ap_malloc
extern dict_new
extern dict_set
extern module_new
extern obj_decref
extern str_from_cstr_heap
extern builtin_func_new
extern complex_from_doubles
extern complex_to_parts
extern complex_type
extern float_from_f64
extern bool_true
extern bool_false
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_OverflowError_type
extern set_exception
extern math_to_double
extern obj_dealloc

section .text

;; ============================================================================
;; cm_arg1(rdi = args, rsi = nargs, rdx = the name for the message)
;;   -> xmm0 = the real part, xmm1 = the imaginary part
;;
;; The wrong arity and an argument that is not a number are refused there.
;; The accepted set is complex_to_parts': complex, float, int, bool and their
;; subclasses, which is what `complex()` itself takes and what CPython's cmath
;; accepts -- it reaches __complex__ and __float__ too, which this does not.
;; ============================================================================
CM1_PARTS equ 16            ; the two doubles, ascending
CM1_ARG   equ 24            ; the argument, for the message
CM1_OK    equ 32            ; complex_to_parts' verdict, across the release
CM1_TMP   equ 40            ; whatever __complex__ answered, owned
CM1_FRAME equ 48            ; + 0 pushes = 48, 16-aligned

;; ============================================================================
;; cm_to_parts(rdi = a Value, rsi = two doubles out)
;;   -> rax = 1 on success, 0 when it is not a number at all
;; Fails: -1
;;
;; complex_to_parts widened by the protocol CPython's cmath uses: __complex__
;; first, then __float__ or __index__, which is what lets it take a Decimal or
;; a Fraction.  Three answers, not two: 0 leaves the wording to the caller,
;; which knows the function's name, and -1 is an exception already pending --
;; a __complex__, __float__ or __index__ that raised, or a __complex__ that
;; answered something other than a complex, which CPython reports by name.
;; ============================================================================
DEF_FUNC_LOCAL cm_to_parts, CM1_FRAME
    mov [rbp - CM1_ARG], rdi
    mov [rbp - CM1_OK], rsi
    call complex_to_parts
    test eax, eax
    jnz .ctp_done

    mov rdi, [rbp - CM1_ARG]
    CSTRING rsi, "__complex__"
    extern dunder_call_1
    call dunder_call_1          ; err: 0, absent or raised, goes to .ctp_try_real
    test rax, rax
    jz .ctp_try_real
    mov [rbp - CM1_TMP], rax
    mov rdi, rax
    mov rsi, [rbp - CM1_OK]
    call complex_to_parts
    test eax, eax
    jz .ctp_bad_complex                 ; it names the type, so before the release
    mov rdi, [rbp - CM1_TMP]
    DECREF_V rdi, rcx
    mov eax, 1
    jmp .ctp_done

.ctp_try_real:
    ; __complex__ is absent -- or it raised, and 0 is the answer to both.
    cmp qword [gs:ThreadState.current_exception], 0
    jne .ctp_fail
    ; math_to_double is the real-number funnel: __float__, then __index__.
    mov rdi, [rbp - CM1_ARG]
    call math_to_double
    ERR_M1 .ctp_fail
    test eax, eax
    jz .ctp_no
    mov rcx, [rbp - CM1_OK]
    movsd [rcx], xmm0
    xorpd xmm0, xmm0
    movsd [rcx + 8], xmm0
    mov eax, 1
.ctp_done:
    leave
    ret
.ctp_no:
    xor eax, eax
    leave
    ret

.ctp_bad_complex:
    ; CPython names what came back, not what went in.
    mov rsi, [rbp - CM1_TMP]
    CSTRING rdi, `__complex__ returned non-complex (type \x01)`
    extern set_type_error_with_name
    call set_type_error_with_name
    mov rdi, [rbp - CM1_TMP]
    DECREF_V rdi, rcx
.ctp_fail:
    mov rax, -1
    leave
    ret
END_FUNC cm_to_parts

;; ============================================================================
;; cm_arg1(rdi = args, rsi = nargs, rdx = the name for the message)
;;   -> xmm0 = the real part, xmm1 = the imaginary part, rax = 0
;; Fails: -1
;;
;; The wrong arity and an argument that is not a number are both refused here.
;; ============================================================================
DEF_FUNC_LOCAL cm_arg1, CM1_FRAME
    cmp rsi, 1
    jne .cm1_arity
    mov rdi, [rdi]
    mov [rbp - CM1_ARG], rdi
    lea rsi, [rbp - CM1_PARTS]
    call cm_to_parts
    ERR_M1 .cm1_fail
    test eax, eax
    jz .cm1_type
    movsd xmm0, [rbp - CM1_PARTS]
    movsd xmm1, [rbp - CM1_PARTS + 8]
    xor eax, eax
    leave
    ret
.cm1_type:
    ; The same sentence math.asm raises, and CPython's cmath raises it too.
    mov rsi, [rbp - CM1_ARG]
    CSTRING rdi, `must be real number, not \x01`
    call set_type_error_with_name
    jmp .cm1_fail
.cm1_arity:
    CSTRING rdi, "cmath function takes exactly one argument ("
    CSTRING rdx, " given)"
    extern set_type_error_counted
    call set_type_error_counted
.cm1_fail:
    mov rax, -1
    leave
    ret
END_FUNC cm_arg1

;; ============================================================================
;; cm_ret(edi = 1 when this function can OVERFLOW, xmm0/xmm1 = the result,
;;        xmm2/xmm3 = the argument it came from)
;;   -> rax = the complex, as a Value
;; Fails: 0
;;
;; math_ret_1's counterpart, and the same rule: the decision is made from the
;; argument and the result alone, with no errno.  A FINITE argument that gives
;; an INFINITE result is an error, and which error is the one thing a function
;; has to declare -- exp, cosh and sinh run out of range, and CPython reports
;; OverflowError for those; log, log10, atan and atanh have a singularity, and
;; it reports ValueError.
;;
;; libm does not raise: clog(0) is -inf and catanh(1) is inf, and handing
;; those back would be a wrong ANSWER where CPython has an exception.
;; ============================================================================
CMR_RES   equ 16            ; the result's two doubles
CMR_OVF   equ 24
CMR_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL cm_ret, CMR_FRAME
    mov [rbp - CMR_OVF], rdi
    movsd [rbp - CMR_RES], xmm0
    movsd [rbp - CMR_RES + 8], xmm1

    ; Was the argument finite?  An infinite one is allowed to give an infinite
    ; answer: cexp(inf+1j) is inf+infj in CPython too.
    mov rcx, 0x7ff0000000000000
    movq rax, xmm2
    btr rax, 63
    cmp rax, rcx
    jae .cmr_build
    movq rax, xmm3
    btr rax, 63
    cmp rax, rcx
    jae .cmr_build

    ; Is either half of the result infinite?
    movq rax, xmm0
    btr rax, 63
    cmp rax, rcx
    je .cmr_error
    movq rax, xmm1
    btr rax, 63
    cmp rax, rcx
    je .cmr_error

.cmr_build:
    movsd xmm0, [rbp - CMR_RES]
    movsd xmm1, [rbp - CMR_RES + 8]
    call complex_from_doubles
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.cmr_error:
    cmp qword [rbp - CMR_OVF], 0
    jne .cmr_overflow
    SET_EXC exc_ValueError_type, "math domain error"
    jmp .cmr_fail
.cmr_overflow:
    SET_EXC exc_OverflowError_type, "math range error"
.cmr_fail:
    xor eax, eax
    leave
    ret
END_FUNC cm_ret

;; ============================================================================
;; One function per libm entry point.  `%2 wrt ..plt` is how math.asm reaches
;; glibc, and `and rsp, -16` before it is why: glibc's float paths use aligned
;; SSE stores, and a handler is entered at the opposite parity from a function.
;; ============================================================================
CM_A      equ 16            ; the argument's two doubles, kept for cm_ret
CM_FRAME  equ 32            ; + 0 pushes = 32, 16-aligned

%macro CMATH_UNARY 3        ; %1 = python name, %2 = libm symbol,
                            ; %3 = 1 when an infinite result is an OVERFLOW
DEF_FUNC cmath_%1, CM_FRAME
    lea rdx, [rel cm_n_%1]
    call cm_arg1
    ERR_M1 %%fail
    movsd [rbp - CM_A], xmm0
    movsd [rbp - CM_A + 8], xmm1
    and rsp, -16
    extern %2
    call %2 wrt ..plt
    mov edi, %3
    movsd xmm2, [rbp - CM_A]
    movsd xmm3, [rbp - CM_A + 8]
    call cm_ret                 ; err: its 0 is this function's 0
    leave
    ret
%%fail:
    xor eax, eax
    leave
    ret
END_FUNC cmath_%1
%endmacro

CMATH_UNARY sqrt,  csqrt,  0
CMATH_UNARY exp,   cexp,   1
CMATH_UNARY log10, clog10, 0
CMATH_UNARY acos,  cacos,  0
CMATH_UNARY asin,  casin,  0
CMATH_UNARY atan,  catan,  0
CMATH_UNARY cos,   ccos,   1
CMATH_UNARY sin,   csin,   1
CMATH_UNARY tan,   ctan,   0
CMATH_UNARY acosh, cacosh, 0
CMATH_UNARY asinh, casinh, 0
CMATH_UNARY atanh, catanh, 0
CMATH_UNARY cosh,  ccosh,  1
CMATH_UNARY sinh,  csinh,  1
CMATH_UNARY tanh,  ctanh,  0

;; ============================================================================
;; cmath.log(z[, base]) -> the natural logarithm, or the one to that base
;;
;; The two-argument form is log(z)/log(base), as CPython computes it -- and
;; not clog(z)/clog(base) with a real base, because the division would lose
;; the exactness of log(1000, 10).
;; ============================================================================
CML_Z     equ 16
CML_B     equ 32
CML_ARG   equ 48            ; the argument, for cm_ret's domain rule
CML_FRAME equ 64            ; + 0 pushes = 64, 16-aligned
DEF_FUNC cmath_log, CML_FRAME
    cmp rsi, 1
    jl .cml_arity
    cmp rsi, 2
    jg .cml_arity
    mov [rbp - CML_B], rsi      ; the count, kept across the first conversion
    mov [rbp - CML_B + 8], rdi  ; and the args pointer

    mov esi, 1
    lea rdx, [rel cm_n_log]
    call cm_arg1
    ERR_M1 .cml_fail
    ; The ARGUMENT is kept too, not just the running value: cm_ret's domain
    ; rule reads it, and log(0) -- a finite argument giving an infinite
    ; answer -- is exactly the case it exists for.
    movsd [rbp - CML_ARG], xmm0
    movsd [rbp - CML_ARG + 8], xmm1

    and rsp, -16
    extern clog
    call clog wrt ..plt
    movsd [rbp - CML_Z], xmm0
    movsd [rbp - CML_Z + 8], xmm1

    cmp qword [rbp - CML_B], 2
    jne .cml_done

    mov rdi, [rbp - CML_B + 8]
    mov rdi, [rdi + 8]          ; args[1], the base
    lea rsi, [rbp - CML_B]
    call cm_to_parts
    ERR_M1 .cml_fail
    test eax, eax
    jz .cml_type
    movsd xmm0, [rbp - CML_B]
    movsd xmm1, [rbp - CML_B + 8]
    and rsp, -16
    call clog wrt ..plt
    ; (a+bi) / (c+di), with the numerator in the frame.
    movsd xmm2, xmm0            ; c
    movsd xmm3, xmm1            ; d
    movsd xmm0, [rbp - CML_Z]   ; a
    movsd xmm1, [rbp - CML_Z + 8]
    call cm_div
.cml_done:
    xor edi, edi                ; a singularity, not an overflow
    movsd xmm2, [rbp - CML_ARG]
    movsd xmm3, [rbp - CML_ARG + 8]
    call cm_ret                 ; err: its 0 is this function's 0
    leave
    ret

.cml_type:
    mov rdi, [rbp - CML_B + 8]
    mov rsi, [rdi + 8]
    CSTRING rdi, `must be real number, not \x01`
    call set_type_error_with_name
    jmp .cml_fail
.cml_arity:
    SET_EXC exc_TypeError_type, "log() takes 1 or 2 arguments"
.cml_fail:
    xor eax, eax
    leave
    ret
END_FUNC cmath_log

;; ============================================================================
;; cm_div(xmm0/xmm1 = the numerator, xmm2/xmm3 = the denominator)
;;   -> xmm0/xmm1 = the quotient
;;
;; The textbook form rather than Smith's, because both operands here are
;; logarithms and neither is near the range where the naive one overflows.
;; ============================================================================
DEF_FUNC_BARE cm_div
    movsd xmm4, xmm2
    mulsd xmm4, xmm2
    movsd xmm5, xmm3
    mulsd xmm5, xmm3
    addsd xmm4, xmm5            ; c*c + d*d
    movsd xmm5, xmm0
    mulsd xmm5, xmm2            ; a*c
    movsd xmm6, xmm1
    mulsd xmm6, xmm3            ; b*d
    addsd xmm5, xmm6
    movsd xmm6, xmm1
    mulsd xmm6, xmm2            ; b*c
    movsd xmm7, xmm0
    mulsd xmm7, xmm3            ; a*d
    subsd xmm6, xmm7
    divsd xmm5, xmm4
    divsd xmm6, xmm4
    movsd xmm0, xmm5
    movsd xmm1, xmm6
    ret
END_FUNC cm_div

;; ============================================================================
;; cmath.phase(z) -> the argument, in radians: atan2(imag, real)
;; ============================================================================
DEF_FUNC cmath_phase
    lea rdx, [rel cm_n_phase]
    call cm_arg1
    ERR_M1 .cph_fail
    movsd xmm2, xmm0
    movsd xmm0, xmm1            ; atan2 takes (y, x)
    movsd xmm1, xmm2
    and rsp, -16
    extern atan2
    call atan2 wrt ..plt
    movq rdi, xmm0
    call float_from_f64
    V_PACK rax, rdx
    leave
    ret
.cph_fail:
    xor eax, eax
    leave
    ret
END_FUNC cmath_phase

;; ============================================================================
;; cmath.polar(z) -> (abs(z), phase(z))
;; ============================================================================
CMP_R     equ 16
CMP_TUP   equ 24
CMP_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC cmath_polar, CMP_FRAME
    lea rdx, [rel cm_n_polar]
    call cm_arg1
    ERR_M1 .cmp_fail
    movsd [rbp - CMP_R], xmm0
    movsd [rbp - CMP_R + 8], xmm1
    and rsp, -16
    extern hypot
    call hypot wrt ..plt
    movq rdi, xmm0
    call float_from_f64
    V_PACK rax, rdx
    mov [rbp - CMP_TUP], rax

    movsd xmm0, [rbp - CMP_R + 8]
    movsd xmm1, [rbp - CMP_R]
    and rsp, -16
    call atan2 wrt ..plt
    movq rdi, xmm0
    call float_from_f64
    V_PACK rax, rdx
    mov [rbp - CMP_R], rax

    mov edi, 2
    extern tuple_new
    call tuple_new
    test rax, rax
    jz .cmp_fail
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbp - CMP_TUP]
    mov [rcx], rdx
    mov rdx, [rbp - CMP_R]
    mov [rcx + 8], rdx
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.cmp_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC cmath_polar

;; ============================================================================
;; cmath.rect(r, phi) -> r * (cos(phi) + sin(phi)j)
;; ============================================================================
CRT_R     equ 8
CRT_PHI   equ 16
CRT_COS   equ 24
CRT_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC cmath_rect, CRT_FRAME
    cmp rsi, 2
    jne .cmr_arity
    mov rax, rdi
    mov rdi, [rax]
    mov [rbp - CRT_PHI], rax
    call math_to_double
    ERR_M1 .cmr_fail
    test eax, eax
    jz .cmr_type
    movsd [rbp - CRT_R], xmm0
    mov rax, [rbp - CRT_PHI]
    mov rdi, [rax + 8]
    call math_to_double
    ERR_M1 .cmr_fail
    test eax, eax
    jz .cmr_type
    movsd [rbp - CRT_PHI], xmm0

    and rsp, -16
    extern cos
    call cos wrt ..plt
    movsd [rbp - CRT_COS], xmm0
    movsd xmm0, [rbp - CRT_PHI]
    and rsp, -16
    extern sin
    call sin wrt ..plt
    mulsd xmm0, [rbp - CRT_R]   ; the imaginary part
    movsd xmm1, xmm0
    movsd xmm0, [rbp - CRT_COS]
    mulsd xmm0, [rbp - CRT_R]   ; the real part
    mov edi, 1                  ; r * cos(phi) can run out of range
    movsd xmm2, [rbp - CRT_R]
    movsd xmm3, [rbp - CRT_PHI]
    call cm_ret                 ; err: its 0 is this function's 0
    leave
    ret
.cmr_type:
    SET_EXC exc_TypeError_type, "rect() arguments must be real numbers"
    jmp .cmr_fail
.cmr_arity:
    SET_EXC exc_TypeError_type, "rect() takes exactly two arguments"
.cmr_fail:
    xor eax, eax
    leave
    ret
END_FUNC cmath_rect

;; ============================================================================
;; The three predicates, which read the parts rather than calling libm.
;; isnan is true when EITHER part is, isinf when either is, and isfinite only
;; when both are -- which is not the same as "not isinf", because a nan is
;; neither.
;; ============================================================================
%macro CMATH_PRED 2             ; %1 = python name, %2 = the test label
DEF_FUNC cmath_%1
    lea rdx, [rel cm_n_%1]
    call cm_arg1
    ERR_M1 %%fail
    call cm_%2
    leave
    ret
%%fail:
    xor eax, eax
    leave
    ret
END_FUNC cmath_%1
%endmacro

CMATH_PRED isnan, isnan_test
CMATH_PRED isinf, isinf_test
CMATH_PRED isfinite, isfinite_test

;; ============================================================================
;; cm_isnan_test(xmm0 = real, xmm1 = imag) -> rax = True or False, as a Value
;;
;; A complex is a nan when EITHER part is.
;; ============================================================================
DEF_FUNC_BARE cm_isnan_test
    ucomisd xmm0, xmm0
    jp .cint_yes
    ucomisd xmm1, xmm1
    jp .cint_yes
    lea rax, [rel bool_false]
    ret
.cint_yes:
    lea rax, [rel bool_true]
    ret
END_FUNC cm_isnan_test

;; ============================================================================
;; cm_isinf_test(xmm0 = real, xmm1 = imag) -> rax = True or False, as a Value
;;
;; Infinite when either part is, whatever the other one holds.
;; ============================================================================
DEF_FUNC_BARE cm_isinf_test
    movq rax, xmm0
    btr rax, 63                 ; drop the sign
    mov rcx, 0x7ff0000000000000
    cmp rax, rcx
    je .ciit_yes
    movq rax, xmm1
    btr rax, 63
    cmp rax, rcx
    je .ciit_yes
    lea rax, [rel bool_false]
    ret
.ciit_yes:
    lea rax, [rel bool_true]
    ret
END_FUNC cm_isinf_test

;; ============================================================================
;; cm_isfinite_test(xmm0 = real, xmm1 = imag) -> rax = True or False, as a Value
;;
;; Finite only when BOTH parts are, which is not "not isinf": a nan is
;; neither infinite nor finite.
;; ============================================================================
DEF_FUNC_BARE cm_isfinite_test
    movq rax, xmm0
    btr rax, 63
    mov rcx, 0x7ff0000000000000
    cmp rax, rcx
    jae .cift_no                ; an infinity or a nan
    movq rax, xmm1
    btr rax, 63
    cmp rax, rcx
    jae .cift_no
    lea rax, [rel bool_true]
    ret
.cift_no:
    lea rax, [rel bool_false]
    ret
END_FUNC cm_isfinite_test

;; ============================================================================
;; cmath.isclose(a, b, *, rel_tol=1e-09, abs_tol=0.0) -> True or False
;;
;; math.isclose over the complex magnitude, and it shares that function's
;; keyword binder rather than growing a second one.  The rule is CPython's,
;; and so is the ORDER it applies it in: both tolerances are converted and
;; range-checked before anything is decided, so isclose(1, 1, rel_tol="x") is
;; a TypeError and not True, and a negative tolerance is a ValueError even
;; when the two values are equal.
;;
;; Equal is close, which also settles two identical infinities; an infinity
;; against anything else never is, because the difference is then a nan and a
;; nan compares false against every tolerance.
;; ============================================================================
CIC_A     equ 16            ; a's two doubles
CIC_B     equ 32            ; b's
CIC_REL   equ 40
CIC_ABS   equ 48
CIC_KWOUT equ 64            ; two slots, ascending
CIC_DIFF  equ 72
CIC_FRAME equ 80            ; + 0 pushes = 80, 16-aligned
DEF_FUNC cmath_isclose, CIC_FRAME
    mov qword [rbp - CIC_KWOUT], 0
    mov qword [rbp - CIC_KWOUT + 8], 0
    mov [rbp - CIC_DIFF], rdi   ; the args array, across the binder
    lea rdx, [rel cm_isclose_kwnames]
    lea rcx, [rbp - CIC_KWOUT]
    extern math_bind_kw
    call math_bind_kw
    ERR_M1 .cic_fail
    cmp rax, 2
    jne .cic_args

    mov rdi, [rbp - CIC_DIFF]
    mov rdi, [rdi]
    lea rsi, [rbp - CIC_A]
    call cm_to_parts
    ERR_M1 .cic_fail
    test eax, eax
    jz .cic_type
    mov rdi, [rbp - CIC_DIFF]
    mov rdi, [rdi + 8]
    lea rsi, [rbp - CIC_B]
    call cm_to_parts
    ERR_M1 .cic_fail
    test eax, eax
    jz .cic_type

    mov rdi, [rbp - CIC_KWOUT]
    test rdi, rdi
    jz .cic_default_rel
    call math_to_double
    ERR_M1 .cic_fail
    test eax, eax
    jz .cic_type
    jmp .cic_have_rel
.cic_default_rel:
    movsd xmm0, [rel cm_default_rel_tol]
.cic_have_rel:
    movsd [rbp - CIC_REL], xmm0

    mov rdi, [rbp - CIC_KWOUT + 8]
    test rdi, rdi
    jz .cic_default_abs
    call math_to_double
    ERR_M1 .cic_fail
    test eax, eax
    jz .cic_type
    jmp .cic_have_abs
.cic_default_abs:
    xorpd xmm0, xmm0
.cic_have_abs:
    movsd [rbp - CIC_ABS], xmm0

    xorpd xmm1, xmm1
    ucomisd xmm1, [rbp - CIC_REL]
    ja .cic_negative
    ucomisd xmm1, [rbp - CIC_ABS]
    ja .cic_negative

    ; Equal in both parts is close.
    movsd xmm0, [rbp - CIC_A]
    ucomisd xmm0, [rbp - CIC_B]
    jp .cic_measure
    jne .cic_measure
    movsd xmm0, [rbp - CIC_A + 8]
    ucomisd xmm0, [rbp - CIC_B + 8]
    jp .cic_measure
    je .cic_true

.cic_measure:
    ; An infinity that is not equal to the other value is never close, and the
    ; arithmetic below cannot say so: inf - 1 is inf, and inf <= inf*rel_tol
    ; is True.  math.isclose carries the same explicit test for the same
    ; reason.
    mov rcx, 0x7ff0000000000000
    mov rax, [rbp - CIC_A]
    btr rax, 63
    cmp rax, rcx
    je .cic_false
    mov rax, [rbp - CIC_A + 8]
    btr rax, 63
    cmp rax, rcx
    je .cic_false
    mov rax, [rbp - CIC_B]
    btr rax, 63
    cmp rax, rcx
    je .cic_false
    mov rax, [rbp - CIC_B + 8]
    btr rax, 63
    cmp rax, rcx
    je .cic_false

    movsd xmm0, [rbp - CIC_A]
    subsd xmm0, [rbp - CIC_B]
    movsd xmm1, [rbp - CIC_A + 8]
    subsd xmm1, [rbp - CIC_B + 8]
    and rsp, -16
    extern hypot
    call hypot wrt ..plt
    movsd [rbp - CIC_DIFF], xmm0

    movsd xmm0, [rbp - CIC_A]
    movsd xmm1, [rbp - CIC_A + 8]
    and rsp, -16
    call hypot wrt ..plt
    movsd [rbp - CIC_A], xmm0

    movsd xmm0, [rbp - CIC_B]
    movsd xmm1, [rbp - CIC_B + 8]
    and rsp, -16
    call hypot wrt ..plt

    maxsd xmm0, [rbp - CIC_A]       ; max(|a|, |b|)
    mulsd xmm0, [rbp - CIC_REL]
    maxsd xmm0, [rbp - CIC_ABS]
    movsd xmm1, [rbp - CIC_DIFF]
    ucomisd xmm1, xmm0
    jp .cic_false                   ; a nan difference: an infinity is in play
    jbe .cic_true
.cic_false:
    lea rax, [rel bool_false]
    INCREF rax
    leave
    ret
.cic_true:
    lea rax, [rel bool_true]
    INCREF rax
    leave
    ret

.cic_negative:
    SET_EXC exc_ValueError_type, "tolerances must be non-negative"
    jmp .cic_fail
.cic_type:
    SET_EXC exc_TypeError_type, "must be real number"
    jmp .cic_fail
.cic_args:
    SET_EXC exc_TypeError_type, "isclose() takes exactly two positional arguments"
.cic_fail:
    xor eax, eax
    leave
    ret
END_FUNC cmath_isclose

;; ============================================================================
;; cmath_module_create() -> rax = the module object
;; ============================================================================

;; CM_ADD_FLOAT name_cstr, the raw bits.  r12 = the dict, as MODULE_ADD_FUNC
;; wants it.
%macro CM_ADD_FLOAT 2
    lea rdi, [rel %1]
    call str_from_cstr_heap
    mov rbx, rax
    mov rax, %2
    V_FROM_F64 rax, rcx
    mov rdi, r12
    mov rsi, rbx
    mov rdx, rax
    call dict_set
    mov rdi, rbx
    call obj_decref
%endmacro

;; CM_ADD_COMPLEX name_cstr, the imaginary part's raw bits.
%macro CM_ADD_COMPLEX 2
    lea rdi, [rel %1]
    call str_from_cstr_heap
    mov rbx, rax
    xorpd xmm0, xmm0
    mov rax, %2
    movq xmm1, rax
    call complex_from_doubles
    mov r13, rax
    mov rdi, r12
    mov rsi, rbx
    mov rdx, rax
    call dict_set
    mov rdi, r13
    call obj_decref
    mov rdi, rbx
    call obj_decref
%endmacro

;; ============================================================================
;; cmath_module_create() -> rax = the module object
;; ============================================================================
CMC_FRAME equ 24            ; + 3 pushes = 48, 16-aligned
DEF_FUNC cmath_module_create, CMC_FRAME
    push rbx
    push r12
    push r13
    call dict_new
    mov r12, rax

    MODULE_ADD_FUNC cmath_sqrt,     cm_n_sqrt
    MODULE_ADD_FUNC cmath_exp,      cm_n_exp
    MODULE_ADD_FUNC cmath_log,      cm_n_log
    MODULE_ADD_FUNC cmath_log10,    cm_n_log10
    MODULE_ADD_FUNC cmath_acos,     cm_n_acos
    MODULE_ADD_FUNC cmath_asin,     cm_n_asin
    MODULE_ADD_FUNC cmath_atan,     cm_n_atan
    MODULE_ADD_FUNC cmath_cos,      cm_n_cos
    MODULE_ADD_FUNC cmath_sin,      cm_n_sin
    MODULE_ADD_FUNC cmath_tan,      cm_n_tan
    MODULE_ADD_FUNC cmath_acosh,    cm_n_acosh
    MODULE_ADD_FUNC cmath_asinh,    cm_n_asinh
    MODULE_ADD_FUNC cmath_atanh,    cm_n_atanh
    MODULE_ADD_FUNC cmath_cosh,     cm_n_cosh
    MODULE_ADD_FUNC cmath_sinh,     cm_n_sinh
    MODULE_ADD_FUNC cmath_tanh,     cm_n_tanh
    MODULE_ADD_FUNC cmath_phase,    cm_n_phase
    MODULE_ADD_FUNC cmath_polar,    cm_n_polar
    MODULE_ADD_FUNC cmath_rect,     cm_n_rect
    MODULE_ADD_FUNC cmath_isnan,    cm_n_isnan
    MODULE_ADD_FUNC cmath_isinf,    cm_n_isinf
    MODULE_ADD_FUNC cmath_isfinite, cm_n_isfinite
    MODULE_ADD_FUNC cmath_isclose,  cm_n_isclose

    CM_ADD_FLOAT cm_n_pi,  0x400921FB54442D18
    CM_ADD_FLOAT cm_n_e,   0x4005BF0A8B145769
    CM_ADD_FLOAT cm_n_tau, 0x401921FB54442D18
    CM_ADD_FLOAT cm_n_inf, 0x7FF0000000000000
    CM_ADD_FLOAT cm_n_nan, 0x7FF8000000000000
    CM_ADD_COMPLEX cm_n_infj, 0x7FF0000000000000
    CM_ADD_COMPLEX cm_n_nanj, 0x7FF8000000000000

    lea rdi, [rel cm_name]
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov rbx, rax
    mov rdi, r12
    call obj_decref
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cmath_module_create

section .rodata
cm_name:       db "cmath", 0
cm_n_sqrt:     db "sqrt", 0
cm_n_exp:      db "exp", 0
cm_n_log:      db "log", 0
cm_n_log10:    db "log10", 0
cm_n_acos:     db "acos", 0
cm_n_asin:     db "asin", 0
cm_n_atan:     db "atan", 0
cm_n_cos:      db "cos", 0
cm_n_sin:      db "sin", 0
cm_n_tan:      db "tan", 0
cm_n_acosh:    db "acosh", 0
cm_n_asinh:    db "asinh", 0
cm_n_atanh:    db "atanh", 0
cm_n_cosh:     db "cosh", 0
cm_n_sinh:     db "sinh", 0
cm_n_tanh:     db "tanh", 0
cm_n_phase:    db "phase", 0
cm_n_polar:    db "polar", 0
cm_n_rect:     db "rect", 0
cm_n_isnan:    db "isnan", 0
cm_n_isinf:    db "isinf", 0
cm_n_isfinite: db "isfinite", 0
cm_n_isclose:  db "isclose", 0
cm_kw_rel_tol: db "rel_tol", 0
cm_kw_abs_tol: db "abs_tol", 0
align 8
cm_isclose_kwnames:
    dq cm_kw_rel_tol
    dq cm_kw_abs_tol
    dq 0
cm_default_rel_tol: dq 0x3E112E0BE826D695      ; 1e-09
cm_n_pi:       db "pi", 0
cm_n_e:        db "e", 0
cm_n_tau:      db "tau", 0
cm_n_inf:      db "inf", 0
cm_n_nan:      db "nan", 0
cm_n_infj:     db "infj", 0
cm_n_nanj:     db "nanj", 0

ASM_INIT
