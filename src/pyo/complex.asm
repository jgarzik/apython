; complex.asm - Complex type (a pair of IEEE 754 doubles)
;
; PyComplexObject layout:
;   +0  ob_refcnt (8 bytes)
;   +8  ob_type   (8 bytes)
;   +16 cval_real (8 bytes: double)
;   +24 cval_imag (8 bytes: double)
;   Total: 32 bytes
;
; The invariant every slot here keeps: a complex holds two raw doubles and no
; references, and every binary slot promotes an int, bool or float operand and
; declines everything else with a NULL Value.  Declining is what lets
; op_binary_op reach this type at all -- `1 + 2j` works because int_add refuses
; the pair and binary_op1 asks complex_add next.
;
; Register discipline worth stating once: SysV has no callee-saved xmm
; register, so every double here lives in a named frame slot across any call.
; That is why complex_to_parts writes through a caller-supplied pointer rather
; than returning a pair in xmm0/xmm1 -- a binop needs four doubles alive across
; two calls, and returning them in registers would only move the spill.

%include "macros.inc"
%include "object.inc"

extern ap_malloc
extern obj_incref
extern obj_decref
extern float_repr
extern float_hash
extern float_to_f64
extern int_type
extern bool_type
extern float_type
extern str_from_cstr
extern ap_strcmp
extern ap_memcpy
extern exc_ZeroDivisionError_type
extern exc_OverflowError_type
extern bool_true
extern bool_false
extern type_type
extern hypot
extern pow
extern atan2
extern exp
extern log
extern cos
extern sin

section .text

;; ============================================================================
;; complex_from_doubles(xmm0 = real, xmm1 = imag) -> rax = PyComplexObject*
;;
;; The one allocator.  It must never raise and must depend on nothing but
;; ap_malloc and the static type object: the source compiler calls it for a
;; `2j` literal, which happens before builtins_init has run -- and under --dis
;; and --selftest-compile, which run only bool_init.  A raise from here would
;; reach eval_exception_unwind with no live frame and become a fatal_error.
;; ============================================================================
CFD_RE    equ 8
CFD_IM    equ 16
CFD_FRAME equ 16            ; + 0 pushes = 16
DEF_FUNC complex_from_doubles, CFD_FRAME
    movsd [rbp - CFD_RE], xmm0
    movsd [rbp - CFD_IM], xmm1
    mov edi, PyComplexObject_size
    call ap_malloc
    INIT_OBJ_RC rax
    lea rcx, [rel complex_type]
    mov [rax + PyObject.ob_type], rcx
    movsd xmm0, [rbp - CFD_RE]
    movsd xmm1, [rbp - CFD_IM]
    movsd [rax + PyComplexObject.cval_real], xmm0
    movsd [rax + PyComplexObject.cval_imag], xmm1
    ; Set the legacy tag as well.  A pointer is its own Value, so rax alone is
    ; the answer for a caller that wants a Value -- but the builtin-call path
    ; reads edx as a tag, and leaving whatever ap_malloc happened to put there
    ; made this correct only by luck.
    mov edx, TAG_PTR
    leave
    ret
END_FUNC complex_from_doubles

;; ============================================================================
;; complex_to_parts(rdi = Value, rsi = &double[2]) -> eax = 1 on success
;;
;; Accepts complex, float, int, bool and int subclasses; writes [rsi] = real
;; and [rsi+8] = imag.  eax = 0 for anything else, which every caller turns
;; into a NULL Value.
;;
;; Classify first, convert second.  float_to_f64 answers 0.0 for a type it does
;; not recognise, so a fall-through would quietly make `2j + None` equal 2j.
;; ============================================================================
CTP_OUT   equ 8
CTP_FRAME equ 16            ; + 0 pushes = 16
DEF_FUNC complex_to_parts, CTP_FRAME
    mov [rbp - CTP_OUT], rsi
    V_TEST_PTR rdi, rax
    ja .ctp_immediate

    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel complex_type]
    cmp rax, rcx
    je .ctp_complex
    ; A complex subclass keeps its two doubles at the base's own offsets, so
    ; the exact-complex arm reads it unchanged.
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_COMPLEX_SUBCLASS
    jnz .ctp_complex
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .ctp_heap_number
    lea rcx, [rel bool_type]
    cmp rax, rcx
    je .ctp_heap_number
    lea rcx, [rel float_type]
    cmp rax, rcx
    je .ctp_heap_number
    test qword [rax + PyTypeObject.tp_flags], \
              TYPE_FLAG_INT_SUBCLASS | TYPE_FLAG_FLOAT_SUBCLASS
    jnz .ctp_heap_number
    jmp .ctp_no

.ctp_complex:
    movsd xmm0, [rdi + PyComplexObject.cval_real]
    movsd xmm1, [rdi + PyComplexObject.cval_imag]
    mov rax, [rbp - CTP_OUT]
    movsd [rax], xmm0
    movsd [rax + 8], xmm1
    mov eax, 1
    leave
    ret

.ctp_heap_number:
    ; A heap int, a bool or a heap float.  float_to_f64 knows all three, and
    ; for a GMP-backed int it is the only correct route (__gmpz_get_d).
    mov esi, TAG_PTR
    jmp .ctp_real

.ctp_immediate:
    V_IS_INT rdi, rax
    jae .ctp_int_immediate
    V_IS_FLOAT rdi, rax
    ja .ctp_no                  ; neither an int nor a float immediate
    V_TO_F64 rdi
    mov esi, TAG_FLOAT
    jmp .ctp_real
.ctp_int_immediate:
    V_TO_I64 rdi
    mov esi, TAG_SMALLINT

.ctp_real:
    ; A real operand: the imaginary part is +0.0.
    call float_to_f64           ; xmm0 = the value as a double
    mov rax, [rbp - CTP_OUT]
    movsd [rax], xmm0
    xorpd xmm1, xmm1
    movsd [rax + 8], xmm1
    mov eax, 1
    leave
    ret

.ctp_no:
    xor eax, eax
    leave
    ret
END_FUNC complex_to_parts

;; ============================================================================
;; complex_parse_string(rdi = PyStrObject *, rsi = &double[2]) -> eax = 1
;;
;; complex("1+2j").  Never implemented: builtin_complex handed a str to
;; complex_to_parts, which classifies and does not parse, so every string was
;; "complex() argument must be a number".
;;
;; CPython's grammar, from complex_from_string_inner:
;;
;;      <float> | <float>j | <float><signed-float>j
;;
;; plus three forms kept for compatibility -- <float><sign>j, <sign>j and a
;; bare j -- all optionally wrapped in one bracket pair and surrounded by
;; whitespace.  No whitespace *inside*: "1 + 2j" is an error, and falls out of
;; the length check at the end rather than needing a rule of its own.
;;
;; Underscores follow PEP 515 and are stripped first, exactly as CPython does
;; through _Py_string_to_number_with_underscores -- and a violation there is a
;; different message from a malformed number, which is why the two are
;; separate raises below.
;;
;; strtod is glibc's and accepts two things CPython's PyOS_string_to_double
;; does not: a hex float and a nan payload.  Both are refused before the call,
;; by reporting that nothing was consumed -- which is how the grammar above
;; already says "this is not a <float>".
;;
;; A parse error is 0 with the ValueError pending.  Nothing it holds is owned
;; except the underscore buffer, which it frees first.
;; Fails: 0
;; ============================================================================
CPS_OBJ   equ 8             ; the PyStrObject, for the underscore message
CPS_OUT   equ 16            ; &double[2]
CPS_BUF   equ 24            ; the underscore-stripped copy, or 0
CPS_S     equ 32            ; the cursor
CPS_START equ 40            ; where it began
CPS_LEN   equ 48            ; the length the cursor must end at
CPS_X     equ 56            ; the real part
CPS_Y     equ 64            ; the imaginary part
CPS_END   equ 72            ; strtod's endptr
CPS_BRK   equ 80            ; whether a '(' was consumed
CPS_XLAT  equ 88            ; the Unicode-to-ASCII copy, or 0
CPS_FRAME equ 96            ; + 0 pushes = 96, 16-byte aligned

extern ap_malloc
extern ap_free
extern strtod
extern exc_ValueError_type

DEF_FUNC complex_parse_string, CPS_FRAME
    mov [rbp - CPS_OBJ], rdi
    mov [rbp - CPS_OUT], rsi
    mov qword [rbp - CPS_BUF], 0
    mov qword [rbp - CPS_BRK], 0
    pxor xmm0, xmm0
    movsd [rbp - CPS_X], xmm0
    movsd [rbp - CPS_Y], xmm0

    ; A Unicode decimal digit is a digit and a Unicode space is a space, as
    ; CPython's _PyUnicode_TransformDecimalAndSpaceToASCII has it.  The copy
    ; is all-ASCII where it could be, and whatever it could not map is left
    ; alone and rejected below exactly as before.
    mov qword [rbp - CPS_XLAT], 0
    extern str_decimal_ascii
    call str_decimal_ascii
    test rax, rax
    jz .cps_ascii
    mov [rbp - CPS_XLAT], rax
    mov rsi, rax
    mov rcx, rdx                ; its length: strlen would stop at an
                                ; embedded NUL, which the end-of-string check
                                ; below is there to catch
    jmp .cps_have_data
.cps_ascii:
    mov rdi, [rbp - CPS_OBJ]
    mov rcx, [rdi + PyStrObject.ob_size]     ; the length in bytes
    lea rsi, [rdi + PyStrObject.data]
.cps_have_data:
    mov [rbp - CPS_START], rsi
    mov [rbp - CPS_LEN], rcx

    ; Any byte past ASCII, and any underscore.
    xor edx, edx                ; saw an underscore
    xor r8, r8
.cps_scan:
    cmp r8, rcx
    jge .cps_scanned
    movzx eax, byte [rsi + r8]
    test al, 0x80
    jnz .cps_malformed
    cmp al, '_'
    jne .cps_scan_next
    mov edx, 1
.cps_scan_next:
    inc r8
    jmp .cps_scan
.cps_scanned:
    test edx, edx
    jz .cps_ready

    ; --- PEP 515: an underscore only between two digits ---
    lea rdi, [rcx + 1]
    call ap_malloc
    mov [rbp - CPS_BUF], rax
    mov [rbp - CPS_START], rax
    mov rsi, [rbp - CPS_OBJ]
    lea rsi, [rsi + PyStrObject.data]
    mov rcx, [rbp - CPS_LEN]
    mov rdi, rax                ; the write cursor
    xor r8, r8                  ; the read index
    xor r9d, r9d                ; the previous byte
.cps_us:
    cmp r8, rcx
    jge .cps_us_done
    movzx eax, byte [rsi + r8]
    test al, al
    jz .cps_us_embedded_nul
    cmp al, '_'
    je .cps_us_sep
    ; A digit must follow an underscore.
    cmp r9d, '_'
    jne .cps_us_keep
    cmp al, '0'
    jb .cps_underscore_error
    cmp al, '9'
    ja .cps_underscore_error
.cps_us_keep:
    mov [rdi], al
    inc rdi
    jmp .cps_us_next
.cps_us_sep:
    ; ...and a digit must precede one.
    cmp r9d, '0'
    jb .cps_underscore_error
    cmp r9d, '9'
    ja .cps_underscore_error
.cps_us_next:
    mov r9d, eax
    inc r8
    jmp .cps_us
.cps_us_done:
    cmp r9d, '_'
    je .cps_underscore_error    ; nor at the end
    mov byte [rdi], 0
    sub rdi, [rbp - CPS_START]
    mov [rbp - CPS_LEN], rdi    ; the length the cursor must now reach

.cps_ready:
    mov rax, [rbp - CPS_START]
    mov [rbp - CPS_S], rax

    ; --- leading whitespace, then one optional bracket ---
    mov rdi, [rbp - CPS_S]
    call cps_skip_space
    mov [rbp - CPS_S], rax
    cmp byte [rax], '('
    jne .cps_body
    inc rax
    mov [rbp - CPS_S], rax
    mov qword [rbp - CPS_BRK], 1
    mov rdi, rax
    call cps_skip_space
    mov [rbp - CPS_S], rax

.cps_body:
    ; z = <float> at the cursor, if there is one.
    mov rdi, [rbp - CPS_S]
    lea rsi, [rbp - CPS_END]
    call cps_strtod             ; xmm0 = z
    mov rax, [rbp - CPS_END]
    cmp rax, [rbp - CPS_S]
    je .cps_no_leading_float

    ; Every form that starts with a <float> lands here.
    mov [rbp - CPS_S], rax
    movsd [rbp - CPS_X], xmm0   ; park z; which part it is is decided below
    movzx ecx, byte [rax]
    cmp cl, '+'
    je .cps_signed_tail
    cmp cl, '-'
    je .cps_signed_tail
    cmp cl, 'j'
    je .cps_imag_only
    cmp cl, 'J'
    je .cps_imag_only
    ; <float>: z was the real part, which is where it already is.
    jmp .cps_tail

.cps_imag_only:
    ; <float>j
    inc rax
    mov [rbp - CPS_S], rax
    movsd xmm0, [rbp - CPS_X]
    movsd [rbp - CPS_Y], xmm0
    pxor xmm0, xmm0
    movsd [rbp - CPS_X], xmm0
    jmp .cps_tail

.cps_signed_tail:
    ; <float><signed-float>j, or <float><sign>j
    mov rdi, [rbp - CPS_S]
    lea rsi, [rbp - CPS_END]
    call cps_strtod
    mov rax, [rbp - CPS_END]
    cmp rax, [rbp - CPS_S]
    je .cps_bare_sign
    movsd [rbp - CPS_Y], xmm0
    mov [rbp - CPS_S], rax
    jmp .cps_want_j
.cps_bare_sign:
    ; <float><sign>j: the sign alone stands for 1.0 or -1.0.
    mov rax, [rbp - CPS_S]
    movzx ecx, byte [rax]
    inc rax
    mov [rbp - CPS_S], rax
    movsd xmm0, [rel cps_one]
    cmp cl, '-'
    jne .cps_bare_sign_store
    movsd xmm1, [rel cps_neg_one]
    movsd xmm0, xmm1
.cps_bare_sign_store:
    movsd [rbp - CPS_Y], xmm0

.cps_want_j:
    mov rax, [rbp - CPS_S]
    movzx ecx, byte [rax]
    cmp cl, 'j'
    je .cps_eat_j
    cmp cl, 'J'
    jne .cps_malformed
.cps_eat_j:
    inc rax
    mov [rbp - CPS_S], rax
    jmp .cps_tail

.cps_no_leading_float:
    ; Not a <float>: only <sign>j and a bare j are left.
    mov rax, [rbp - CPS_S]
    movzx ecx, byte [rax]
    movsd xmm0, [rel cps_one]
    cmp cl, '+'
    je .cps_sign_j
    cmp cl, '-'
    jne .cps_bare_j
    movsd xmm0, [rel cps_neg_one]
.cps_sign_j:
    inc rax
    mov [rbp - CPS_S], rax
.cps_bare_j:
    movsd [rbp - CPS_Y], xmm0
    jmp .cps_want_j

.cps_tail:
    ; trailing whitespace, the closing bracket, more whitespace
    mov rdi, [rbp - CPS_S]
    call cps_skip_space
    mov [rbp - CPS_S], rax
    cmp qword [rbp - CPS_BRK], 0
    je .cps_at_end
    mov rax, [rbp - CPS_S]
    cmp byte [rax], ')'
    jne .cps_malformed
    inc rax
    mov rdi, rax
    call cps_skip_space
    mov [rbp - CPS_S], rax

.cps_at_end:
    ; The cursor has to be at the end of the string, not merely at a NUL:
    ; that is what rejects "1 + 2j", "1+2j)" and an embedded NUL alike.
    mov rax, [rbp - CPS_S]
    sub rax, [rbp - CPS_START]
    cmp rax, [rbp - CPS_LEN]
    jne .cps_malformed

    mov rdi, [rbp - CPS_BUF]
    test rdi, rdi
    jz .cps_no_buf
    call ap_free
.cps_no_buf:
    mov rdi, [rbp - CPS_XLAT]
    test rdi, rdi
    jz .cps_no_xlat
    call ap_free
.cps_no_xlat:
    mov rax, [rbp - CPS_OUT]
    movsd xmm0, [rbp - CPS_X]
    movsd xmm1, [rbp - CPS_Y]
    movsd [rax], xmm0
    movsd [rax + 8], xmm1
    mov eax, 1
    leave
    ret

.cps_us_embedded_nul:
    ; CPython's underscore pass rejects an embedded NUL outright; without an
    ; underscore the length check at the end catches it instead.
    jmp .cps_underscore_error

.cps_malformed:
    mov rdi, [rbp - CPS_BUF]
    test rdi, rdi
    jz .cps_malformed_xlat
    call ap_free
.cps_malformed_xlat:
    mov rdi, [rbp - CPS_XLAT]
    test rdi, rdi
    jz .cps_malformed_raise
    call ap_free
.cps_malformed_raise:
    extern set_exception
    SET_EXC exc_ValueError_type, "complex() arg is a malformed string"
    leave
    ret

.cps_underscore_error:
    mov rdi, [rbp - CPS_BUF]
    test rdi, rdi
    jz .cps_underscore_xlat
    call ap_free
.cps_underscore_xlat:
    mov rdi, [rbp - CPS_XLAT]
    test rdi, rdi
    jz .cps_underscore_raise
    call ap_free
.cps_underscore_raise:
    mov rsi, [rbp - CPS_OBJ]
    CSTRING rdi, "could not convert string to complex: "
    extern set_value_error_with_repr
    call set_value_error_with_repr
    leave
    ret
END_FUNC complex_parse_string

;; cps_skip_space(rdi = s) -> rax = s advanced past ASCII whitespace.
;; The set is Py_ISSPACE's: space, \t, \n, \v, \f, \r.
DEF_FUNC_BARE cps_skip_space
    mov rax, rdi
.css_loop:
    movzx ecx, byte [rax]
    cmp cl, ' '
    je .css_next
    cmp cl, 9                   ; \t
    jb .css_done
    cmp cl, 13                  ; \r ... and \n, \v, \f between
    ja .css_done
.css_next:
    inc rax
    jmp .css_loop
.css_done:
    ret
END_FUNC cps_skip_space

;; cps_strtod(rdi = s, rsi = &endptr) -> xmm0 = the value
;;
;; strtod, minus the two things glibc accepts and CPython does not: a hex
;; float ("0x10" is a malformed complex, not 16) and a nan payload.  Both are
;; refused by reporting that nothing was consumed, which is already how the
;; grammar says "not a <float>".
DEF_FUNC_LOCAL cps_strtod
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rax, rdi
    movzx ecx, byte [rax]
    cmp cl, '+'
    je .cst_signed
    cmp cl, '-'
    jne .cst_unsigned
.cst_signed:
    inc rax
.cst_unsigned:
    cmp byte [rax], '0'
    jne .cst_check_nan
    movzx ecx, byte [rax + 1]
    or cl, 0x20
    cmp cl, 'x'
    je .cst_reject
.cst_check_nan:
    movzx ecx, byte [rax]
    or cl, 0x20
    cmp cl, 'n'
    jne .cst_call
    movzx ecx, byte [rax + 1]
    or cl, 0x20
    cmp cl, 'a'
    jne .cst_call
    movzx ecx, byte [rax + 2]
    or cl, 0x20
    cmp cl, 'n'
    jne .cst_call
    cmp byte [rax + 3], '('
    je .cst_reject

.cst_call:
    mov rdi, rbx
    mov rsi, r12
    call strtod wrt ..plt
    pop r12
    pop rbx
    leave
    ret

.cst_reject:
    mov [r12], rbx              ; nothing consumed
    pxor xmm0, xmm0
    pop r12
    pop rbx
    leave
    ret
END_FUNC cps_strtod

section .rodata
align 8
cps_one:     dq 0x3FF0000000000000      ;  1.0
cps_neg_one: dq 0xBFF0000000000000      ; -1.0
section .text

;; ============================================================================
;; The binary slots.  Each takes (rdi = left Value, rsi = right Value) and
;; returns one Value, or a NULL Value when either operand is not a number.
;; ============================================================================
CB_A     equ 16              ; a.real at [rbp-16], a.imag at [rbp-8]
CB_B     equ 32              ; b.real at [rbp-32], b.imag at [rbp-24]
CB_RSAVE equ 40              ; the right operand across the first conversion
CB_FRAME equ 48              ; + 0 pushes = 48

; Fill CB_A and CB_B from the two operand Values, or return a NULL Value.
%macro COMPLEX_BINOP_SETUP 0
    mov [rbp - CB_RSAVE], rsi
    lea rsi, [rbp - CB_A]
    call complex_to_parts
    test eax, eax
    jz %%decline
    mov rdi, [rbp - CB_RSAVE]
    lea rsi, [rbp - CB_B]
    call complex_to_parts
    test eax, eax
    jnz %%ok
%%decline:
    xor eax, eax                ; NULL Value = NotImplemented
    leave
    ret
%%ok:
%endmacro

DEF_FUNC complex_add, CB_FRAME
    COMPLEX_BINOP_SETUP
    movsd xmm0, [rbp - CB_A]
    addsd xmm0, [rbp - CB_B]
    movsd xmm1, [rbp - CB_A + 8]
    addsd xmm1, [rbp - CB_B + 8]
    call complex_from_doubles
    leave
    ret
END_FUNC complex_add

DEF_FUNC complex_sub, CB_FRAME
    COMPLEX_BINOP_SETUP
    movsd xmm0, [rbp - CB_A]
    subsd xmm0, [rbp - CB_B]
    movsd xmm1, [rbp - CB_A + 8]
    subsd xmm1, [rbp - CB_B + 8]
    call complex_from_doubles
    leave
    ret
END_FUNC complex_sub

;; _Py_c_prod: (ar*br - ai*bi, ar*bi + ai*br).  The full form is used even when
;; one side was promoted from a real, because CPython does: that is why
;; complex(inf,0) * 2 is (inf+nanj) and not (inf+0j).
DEF_FUNC complex_mul, CB_FRAME
    COMPLEX_BINOP_SETUP
    movsd xmm0, [rbp - CB_A]        ; ar
    movsd xmm1, [rbp - CB_A + 8]    ; ai
    movsd xmm2, [rbp - CB_B]        ; br
    movsd xmm3, [rbp - CB_B + 8]    ; bi
    movapd xmm4, xmm0
    mulsd xmm4, xmm2                ; ar*br
    movapd xmm5, xmm1
    mulsd xmm5, xmm3                ; ai*bi
    subsd xmm4, xmm5                ; real
    mulsd xmm0, xmm3                ; ar*bi
    mulsd xmm1, xmm2                ; ai*br
    addsd xmm0, xmm1                ; imag
    movapd xmm1, xmm0
    movapd xmm0, xmm4
    call complex_from_doubles
    leave
    ret
END_FUNC complex_mul

;; _Py_c_quot, Smith's algorithm verbatim.  Not the (a*conj(b))/|b|^2 form: the
;; last bits of (1+2j)/(3-4j) differ between the two, and this is the one
;; CPython computes.
;; Fails: 0?
DEF_FUNC complex_truediv, CB_FRAME
    COMPLEX_BINOP_SETUP
    movsd xmm2, [rbp - CB_B]        ; br
    movsd xmm3, [rbp - CB_B + 8]    ; bi
    movapd xmm6, xmm2
    andpd xmm6, [rel cx_absmask]    ; |br|
    movapd xmm7, xmm3
    andpd xmm7, [rel cx_absmask]    ; |bi|
    ucomisd xmm6, xmm7
    jp .ctd_nan                     ; unordered: a NaN in the denominator
    jb .ctd_bi_bigger

    ; |br| >= |bi|.  Both zero is the only way to reach a zero denominator
    ; here, which is what makes this the division-by-zero test.
    xorpd xmm5, xmm5
    ucomisd xmm6, xmm5
    je .ctd_zero
    movapd xmm4, xmm3
    divsd xmm4, xmm2                ; ratio = bi/br
    movapd xmm5, xmm3
    mulsd xmm5, xmm4
    addsd xmm5, xmm2                ; denom = br + bi*ratio
    movsd xmm0, [rbp - CB_A]        ; ar
    movsd xmm1, [rbp - CB_A + 8]    ; ai
    movapd xmm6, xmm1
    mulsd xmm6, xmm4
    addsd xmm6, xmm0
    divsd xmm6, xmm5                ; (ar + ai*ratio)/denom
    movapd xmm7, xmm0
    mulsd xmm7, xmm4
    movapd xmm0, xmm1
    subsd xmm0, xmm7
    divsd xmm0, xmm5                ; (ai - ar*ratio)/denom
    movapd xmm1, xmm0
    movapd xmm0, xmm6
    call complex_from_doubles
    leave
    ret

.ctd_bi_bigger:
    movapd xmm4, xmm2
    divsd xmm4, xmm3                ; ratio = br/bi
    movapd xmm5, xmm2
    mulsd xmm5, xmm4
    addsd xmm5, xmm3                ; denom = br*ratio + bi
    movsd xmm0, [rbp - CB_A]        ; ar
    movsd xmm1, [rbp - CB_A + 8]    ; ai
    movapd xmm6, xmm0
    mulsd xmm6, xmm4
    addsd xmm6, xmm1
    divsd xmm6, xmm5                ; (ar*ratio + ai)/denom
    movapd xmm7, xmm1
    mulsd xmm7, xmm4
    subsd xmm7, xmm0
    divsd xmm7, xmm5                ; (ai*ratio - ar)/denom
    movapd xmm0, xmm6
    movapd xmm1, xmm7
    call complex_from_doubles
    leave
    ret

.ctd_nan:
    movsd xmm0, [rel cx_nan]
    movapd xmm1, xmm0
    call complex_from_doubles
    leave
    ret

.ctd_zero:
    SET_EXC exc_ZeroDivisionError_type, "complex division by zero"
    leave
    ret
END_FUNC complex_truediv

DEF_FUNC complex_neg, CB_FRAME
    lea rsi, [rbp - CB_A]
    call complex_to_parts
    test eax, eax
    jz .cn_decline
    movsd xmm0, [rbp - CB_A]
    movsd xmm1, [rbp - CB_A + 8]
    xorpd xmm0, [rel cx_signmask]
    xorpd xmm1, [rel cx_signmask]
    call complex_from_doubles
    leave
    ret
.cn_decline:
    xor eax, eax
    leave
    ret
END_FUNC complex_neg

DEF_FUNC complex_pos, CB_FRAME
    ; +z is z itself -- for a subclass too, which is why this is not an exact
    ; type test.  Declining left the call site storing a NULL Value on the
    ; value stack, and a raw NULL then circulated through globals, lists and
    ; dicts: `x = +C(1, 2)` bound nothing and reading x back was a NameError.
    V_TEST_PTR rdi, rax
    ja .cp_decline
    test rdi, rdi
    jz .cp_decline
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel complex_type]
    cmp rax, rcx
    je .cp_have
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_COMPLEX_SUBCLASS
    jz .cp_decline
    ; A subclass gets an exact complex back, as CPython's does: +x is a
    ; numeric operation, not an identity one.
    lea rsi, [rbp - CB_A]
    call complex_to_parts
    test eax, eax
    jz .cp_decline
    movsd xmm0, [rbp - CB_A]
    movsd xmm1, [rbp - CB_A + 8]
    call complex_from_doubles
    leave
    ret
.cp_have:
    push rdi
    call obj_incref
    pop rax
    leave
    ret
.cp_decline:
    xor eax, eax
    leave
    ret
END_FUNC complex_pos

;; bool(z) is False only when both parts are zero.  -0.0 is falsy, so this
;; compares against zero rather than testing the sign bit.
;;
;; nb_bool answers with eax = 0/1, not a bool object -- see float_bool.
DEF_FUNC complex_bool, CB_FRAME
    lea rsi, [rbp - CB_A]
    call complex_to_parts
    test eax, eax
    jz .cbl_false               ; not a complex: cannot happen through the slot
    xorpd xmm2, xmm2
    movsd xmm0, [rbp - CB_A]
    ucomisd xmm0, xmm2
    jp .cbl_true                ; a NaN part is truthy
    jne .cbl_true
    movsd xmm1, [rbp - CB_A + 8]
    ucomisd xmm1, xmm2
    jp .cbl_true
    jne .cbl_true
.cbl_false:
    xor eax, eax
    leave
    ret
.cbl_true:
    mov eax, 1
    leave
    ret
END_FUNC complex_bool

;; ============================================================================
;; complex_abs(rdi = Value) -> float Value
;;
;; _Py_c_abs: an infinite part wins over a NaN one (C99), and a finite pair
;; whose hypot overflows is an OverflowError rather than an inf.
;; Fails: 0?
;; ============================================================================
CA_RE    equ 16              ; real at [rbp-16], imag at [rbp-8]
CA_FRAME equ 32              ; + 0 pushes = 32
DEF_FUNC complex_abs, CA_FRAME
    lea rsi, [rbp - CA_RE]
    call complex_to_parts
    test eax, eax
    jz .cab_decline

    movsd xmm0, [rbp - CA_RE]
    andpd xmm0, [rel cx_absmask]
    ucomisd xmm0, [rel cx_inf]
    jp .cab_try_imag            ; ucomisd sets ZF for UNORDERED as well as
    je .cab_ret_xmm0            ; equal, so a NaN part took the `inf` arm and
.cab_try_imag:                  ; abs(complex(nan, inf)) answered nan
    movsd xmm0, [rbp - CA_RE + 8]
    andpd xmm0, [rel cx_absmask]
    ucomisd xmm0, [rel cx_inf]
    jp .cab_hypot
    je .cab_ret_xmm0
.cab_hypot:

    movsd xmm0, [rbp - CA_RE]
    movsd xmm1, [rbp - CA_RE + 8]
    and rsp, -16                ; glibc's float paths use aligned SSE
    call hypot wrt ..plt
    movapd xmm1, xmm0
    andpd xmm1, [rel cx_absmask]
    ucomisd xmm1, [rel cx_inf]
    jp .cab_ret_xmm0            ; a NaN result is a NaN, not an overflow
    je .cab_overflow            ; finite inputs, infinite result
.cab_ret_xmm0:
    movq rax, xmm0
    V_FROM_F64 rax, rcx
    leave
    ret
.cab_overflow:
    SET_EXC exc_OverflowError_type, "absolute value too large"
    leave
    ret
.cab_decline:
    xor eax, eax
    leave
    ret
END_FUNC complex_abs

;; ============================================================================
;; complex_pow(rdi = left Value, rsi = right Value) -> Value
;;
;; CPython takes a repeated-squaring path when the exponent is real, integral
;; and within +-100, and the general exp/log form otherwise.  The boundary is
;; exact: 100 and -100 use the integer path, 101 and -101 do not.
;; Fails: 0?
;; ============================================================================
CPW_A     equ 16             ; base:     real at [rbp-16], imag at [rbp-8]
CPW_B     equ 32             ; exponent: real at [rbp-32], imag at [rbp-24]
CPW_RR    equ 48             ; running result
CPW_RI    equ 40
CPW_PR    equ 64             ; running power of the base
CPW_PI    equ 56
CPW_N     equ 72             ; the integer exponent
CPW_RSAVE equ 80
CPW_FRAME equ 80             ; + 0 pushes = 80, 16-aligned for libc
DEF_FUNC complex_pow, CPW_FRAME
    mov [rbp - CPW_RSAVE], rsi
    lea rsi, [rbp - CPW_A]
    call complex_to_parts
    test eax, eax
    jz .cpw_decline
    mov rdi, [rbp - CPW_RSAVE]
    lea rsi, [rbp - CPW_B]
    call complex_to_parts
    test eax, eax
    jz .cpw_decline

    ; An integral, real exponent within +-100 takes the exact path.
    xorpd xmm2, xmm2
    movsd xmm1, [rbp - CPW_B + 8]
    ucomisd xmm1, xmm2
    jp .cpw_general
    jne .cpw_general
    movsd xmm0, [rbp - CPW_B]
    cvttsd2si rax, xmm0
    cvtsi2sd xmm3, rax
    ucomisd xmm3, xmm0
    jp .cpw_general
    jne .cpw_general            ; not integral
    cmp rax, 100
    jg .cpw_general
    cmp rax, -100
    jl .cpw_general
    mov [rbp - CPW_N], rax

    ; r = 1+0j, p = base
    movsd xmm0, [rel cx_one]
    movsd [rbp - CPW_RR], xmm0
    xorpd xmm0, xmm0
    movsd [rbp - CPW_RI], xmm0
    movsd xmm0, [rbp - CPW_A]
    movsd [rbp - CPW_PR], xmm0
    movsd xmm0, [rbp - CPW_A + 8]
    movsd [rbp - CPW_PI], xmm0

    mov rax, [rbp - CPW_N]
    test rax, rax
    jns .cpw_squaring
    neg rax
.cpw_squaring:
    ; while (n) { if (n & 1) r *= p;  p *= p;  n >>= 1; }
    test rax, rax
    jz .cpw_squaring_done
    test rax, 1
    jz .cpw_square_only
    ; r = r * p
    push rax
    movsd xmm0, [rbp - CPW_RR]
    movsd xmm1, [rbp - CPW_RI]
    movsd xmm2, [rbp - CPW_PR]
    movsd xmm3, [rbp - CPW_PI]
    call complex_cmul_raw
    movsd [rbp - CPW_RR], xmm0
    movsd [rbp - CPW_RI], xmm1
    pop rax
.cpw_square_only:
    push rax
    movsd xmm0, [rbp - CPW_PR]
    movsd xmm1, [rbp - CPW_PI]
    movapd xmm2, xmm0
    movapd xmm3, xmm1
    call complex_cmul_raw
    movsd [rbp - CPW_PR], xmm0
    movsd [rbp - CPW_PI], xmm1
    pop rax
    shr rax, 1
    jmp .cpw_squaring

.cpw_squaring_done:
    cmp qword [rbp - CPW_N], 0
    jge .cpw_finish
    ; A negative exponent divides 1+0j by the result.
    xorpd xmm2, xmm2
    movsd xmm0, [rbp - CPW_RR]
    ucomisd xmm0, xmm2
    jp .cpw_neg_div
    jne .cpw_neg_div
    movsd xmm1, [rbp - CPW_RI]
    ucomisd xmm1, xmm2
    jp .cpw_neg_div
    je .cpw_zero_neg_power
.cpw_neg_div:
    movsd xmm0, [rel cx_one]
    xorpd xmm1, xmm1
    movsd xmm2, [rbp - CPW_RR]
    movsd xmm3, [rbp - CPW_RI]
    call complex_cdiv_raw
    movsd [rbp - CPW_RR], xmm0
    movsd [rbp - CPW_RI], xmm1

.cpw_finish:
    ; A non-finite result from finite inputs is an overflow, on both paths.
    ; jp before je at both: ucomisd sets ZF for UNORDERED too, so a NaN part
    ; read as infinity and complex(nan, 0) ** 3 raised OverflowError.
    movsd xmm0, [rbp - CPW_RR]
    andpd xmm0, [rel cx_absmask]
    ucomisd xmm0, [rel cx_inf]
    jp .cpw_check_imag
    je .cpw_overflow
.cpw_check_imag:
    movsd xmm0, [rbp - CPW_RI]
    andpd xmm0, [rel cx_absmask]
    ucomisd xmm0, [rel cx_inf]
    jp .cpw_no_overflow
    je .cpw_overflow
.cpw_no_overflow:
    movsd xmm0, [rbp - CPW_RR]
    movsd xmm1, [rbp - CPW_RI]
    call complex_from_doubles
    leave
    ret

.cpw_general:
    ; b == 0+0j  ->  1+0j
    xorpd xmm2, xmm2
    movsd xmm0, [rbp - CPW_B]
    ucomisd xmm0, xmm2
    jp .cpw_general_body
    jne .cpw_general_body
    movsd xmm1, [rbp - CPW_B + 8]
    ucomisd xmm1, xmm2
    jp .cpw_general_body
    jne .cpw_general_body
    movsd xmm0, [rel cx_one]
    xorpd xmm1, xmm1
    call complex_from_doubles
    leave
    ret

.cpw_general_body:
    ; a == 0+0j: the result is 0, unless the exponent is complex or negative.
    xorpd xmm2, xmm2
    movsd xmm0, [rbp - CPW_A]
    ucomisd xmm0, xmm2
    jp .cpw_general_math
    jne .cpw_general_math
    movsd xmm1, [rbp - CPW_A + 8]
    ucomisd xmm1, xmm2
    jp .cpw_general_math
    jne .cpw_general_math
    movsd xmm1, [rbp - CPW_B + 8]
    ucomisd xmm1, xmm2
    jp .cpw_zero_neg_power
    jne .cpw_zero_neg_power
    movsd xmm0, [rbp - CPW_B]
    ucomisd xmm0, xmm2
    jp .cpw_zero_result      ; UNORDERED sets CF too, so the jb alone sent a
    jb .cpw_zero_neg_power   ; NaN exponent to the raise; C's nan < 0 is false
.cpw_zero_result:
    xorpd xmm0, xmm0
    xorpd xmm1, xmm1
    call complex_from_doubles
    leave
    ret

.cpw_general_math:
    ; vabs = hypot(ar,ai);  len = pow(vabs,br);  at = atan2(ai,ar)
    ; phase = at*br;  if bi: len /= exp(at*bi), phase += bi*log(vabs)
    and rsp, -16
    movsd xmm0, [rbp - CPW_A]
    movsd xmm1, [rbp - CPW_A + 8]
    call hypot wrt ..plt
    movsd [rbp - CPW_PR], xmm0          ; vabs
    movsd xmm1, [rbp - CPW_B]
    call pow wrt ..plt
    movsd [rbp - CPW_RR], xmm0          ; len
    movsd xmm0, [rbp - CPW_A + 8]
    movsd xmm1, [rbp - CPW_A]
    call atan2 wrt ..plt
    movsd [rbp - CPW_PI], xmm0          ; at
    mulsd xmm0, [rbp - CPW_B]
    movsd [rbp - CPW_RI], xmm0          ; phase

    xorpd xmm2, xmm2
    movsd xmm1, [rbp - CPW_B + 8]
    ucomisd xmm1, xmm2
    jp .cpw_have_polar
    je .cpw_have_polar
    movsd xmm0, [rbp - CPW_PI]
    mulsd xmm0, [rbp - CPW_B + 8]
    call exp wrt ..plt
    movsd xmm1, [rbp - CPW_RR]
    divsd xmm1, xmm0
    movsd [rbp - CPW_RR], xmm1
    movsd xmm0, [rbp - CPW_PR]
    call log wrt ..plt
    mulsd xmm0, [rbp - CPW_B + 8]
    addsd xmm0, [rbp - CPW_RI]
    movsd [rbp - CPW_RI], xmm0

.cpw_have_polar:
    movsd xmm0, [rbp - CPW_RI]
    call cos wrt ..plt
    mulsd xmm0, [rbp - CPW_RR]
    movsd [rbp - CPW_N], xmm0           ; the real part, reusing the slot
    movsd xmm0, [rbp - CPW_RI]
    call sin wrt ..plt
    mulsd xmm0, [rbp - CPW_RR]
    movsd [rbp - CPW_RI], xmm0
    movsd xmm0, [rbp - CPW_N]
    movsd [rbp - CPW_RR], xmm0
    jmp .cpw_finish

.cpw_zero_neg_power:
    SET_EXC exc_ZeroDivisionError_type, "0.0 to a negative or complex power"
    leave
    ret
.cpw_overflow:
    SET_EXC exc_OverflowError_type, "complex exponentiation"
    leave
    ret
.cpw_decline:
    xor eax, eax
    leave
    ret
END_FUNC complex_pow

;; ============================================================================
;; complex_cmul_raw(xmm0,xmm1 = a) (xmm2,xmm3 = b) -> xmm0,xmm1 = a*b
;; complex_cdiv_raw(xmm0,xmm1 = a) (xmm2,xmm3 = b) -> xmm0,xmm1 = a/b
;;
;; Raw double arithmetic, no allocation and no error channel, for use inside
;; complex_pow's loop.  cdiv_raw's caller has already excluded a zero divisor.
;; ============================================================================
DEF_FUNC_BARE complex_cmul_raw
    movapd xmm4, xmm0
    mulsd xmm4, xmm2                ; ar*br
    movapd xmm5, xmm1
    mulsd xmm5, xmm3                ; ai*bi
    subsd xmm4, xmm5
    mulsd xmm0, xmm3                ; ar*bi
    mulsd xmm1, xmm2                ; ai*br
    addsd xmm0, xmm1
    movapd xmm1, xmm0
    movapd xmm0, xmm4
    ret
END_FUNC complex_cmul_raw

DEF_FUNC_BARE complex_cdiv_raw
    movapd xmm6, xmm2
    andpd xmm6, [rel cx_absmask]
    movapd xmm7, xmm3
    andpd xmm7, [rel cx_absmask]
    ucomisd xmm6, xmm7
    jb .cdr_bi_bigger
    movapd xmm4, xmm3
    divsd xmm4, xmm2                ; ratio = bi/br
    movapd xmm5, xmm3
    mulsd xmm5, xmm4
    addsd xmm5, xmm2                ; denom
    movapd xmm6, xmm1
    mulsd xmm6, xmm4
    addsd xmm6, xmm0
    divsd xmm6, xmm5
    movapd xmm7, xmm0
    mulsd xmm7, xmm4
    movapd xmm0, xmm1
    subsd xmm0, xmm7
    divsd xmm0, xmm5
    movapd xmm1, xmm0
    movapd xmm0, xmm6
    ret
.cdr_bi_bigger:
    movapd xmm4, xmm2
    divsd xmm4, xmm3                ; ratio = br/bi
    movapd xmm5, xmm2
    mulsd xmm5, xmm4
    addsd xmm5, xmm3
    movapd xmm6, xmm0
    mulsd xmm6, xmm4
    addsd xmm6, xmm1
    divsd xmm6, xmm5
    movapd xmm7, xmm1
    mulsd xmm7, xmm4
    subsd xmm7, xmm0
    divsd xmm7, xmm5
    movapd xmm0, xmm6
    movapd xmm1, xmm7
    ret
END_FUNC complex_cdiv_raw

;; ============================================================================
;; complex_repr(rdi = PyComplexObject*) -> rax = PyStrObject*, edx = TAG_PTR
;;
;; CPython's rule: a real part of exactly +0.0 is not printed and the result is
;; bare (`2j`); anything else is parenthesised with an explicit sign on the
;; imaginary part (`(1+2j)`, `(-0+2j)`).  So a NEGATIVE zero real part does
;; print -- which is why the test below is on the raw bits and not a compare.
;;
;; Both parts render through float_repr, whole.  It is the most delicate
;; function in float.asm -- a shortest-round-trip loop plus a second pass to
;; choose notation -- and reusing it entire is what guarantees the parts of a
;; complex print byte-identically to the equivalent floats.
;; ============================================================================
CR_SELF  equ 8
CR_BUF   equ 128            ; 112 bytes: two 24-byte reprs plus "(", "+", "j)"
CR_FRAME equ 136            ; + 1 push = 144, 16-aligned
DEF_FUNC complex_repr, CR_FRAME
    push rbx
    mov [rbp - CR_SELF], rdi
    lea rbx, [rbp - CR_BUF]     ; rbx = write cursor

    mov rax, [rbp - CR_SELF]
    mov rax, [rax + PyComplexObject.cval_real]
    test rax, rax               ; +0.0 is the only double whose bits are all
    jz .cr_imag_only            ; zero, so this is "== 0 and not signbit"

    mov byte [rbx], '('
    inc rbx
    mov rax, [rbp - CR_SELF]
    mov rdi, [rax + PyComplexObject.cval_real]
    call .cr_append             ; the real part
    ; The imaginary part always carries an explicit sign.
    mov rax, [rbp - CR_SELF]
    mov rax, [rax + PyComplexObject.cval_imag]
    bt rax, 63
    jnc .cr_imag_plus
    ; A negative NaN keeps its sign bit but float_repr prints it unsigned, so
    ; delegating the '-' loses the separator entirely and (nan-nanj) rendered
    ; as (nannanj).  CPython formats the part with Py_DTSF_SIGN, which gives
    ; a NaN '+' whatever its sign.  Only reachable through complex("nan-nanj"):
    ; a float immediate cannot hold a negative NaN, since V_FROM_F64
    ; canonicalises one, but a complex stores raw doubles.
    movq xmm0, rax
    ucomisd xmm0, xmm0
    jnp .cr_imag_signed         ; ordered: a real negative, sign and all
.cr_imag_plus:
    mov byte [rbx], '+'
    inc rbx
.cr_imag_signed:
    mov rax, [rbp - CR_SELF]
    mov rdi, [rax + PyComplexObject.cval_imag]
    call .cr_append
    mov word [rbx], ')' * 256 + 'j'
    add rbx, 2
    jmp .cr_done

.cr_imag_only:
    mov rax, [rbp - CR_SELF]
    mov rdi, [rax + PyComplexObject.cval_imag]
    call .cr_append
    mov byte [rbx], 'j'
    inc rbx

.cr_done:
    mov byte [rbx], 0
    lea rdi, [rbp - CR_BUF]
    call str_from_cstr
    pop rbx
    leave
    ret

.cr_append:
    ; A tail call into the helper below, with the cursor in rbx.
    mov rsi, rdi
    mov rdi, rbx
    call complex_repr_append
    mov rbx, rax
    ret
END_FUNC complex_repr

;; ============================================================================
;; complex_repr_append(rdi = cursor, rsi = raw double bits) -> rax = new cursor
;; Renders one part with float_repr and copies its bytes to the cursor.
;; ============================================================================
CRA_CUR   equ 8
CRA_STR   equ 16
CRA_LEN   equ 24
CRA_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC_LOCAL complex_repr_append, CRA_FRAME
    mov [rbp - CRA_CUR], rdi
    mov rdi, rsi
    mov edx, TAG_FLOAT          ; a raw part, not a float subclass instance
    call float_repr             ; rax = PyStrObject*
    mov [rbp - CRA_STR], rax
    mov rdx, [rax + PyStrObject.ob_size]
    mov [rbp - CRA_LEN], rdx
    mov rdi, [rbp - CRA_CUR]
    lea rsi, [rax + PyStrObject.data]
    call ap_memcpy
    mov rdi, [rbp - CRA_STR]
    call obj_decref
    mov rax, [rbp - CRA_CUR]
    add rax, [rbp - CRA_LEN]

    ; float_repr appends ".0" to an integral float, because repr(3.0) is
    ; "3.0".  A complex part is rendered without that -- CPython formats the
    ; two halves with Py_DTSF_ADD_DOT_0 clear, which is why repr(complex(3))
    ; is "(3+0j)" and not "(3.0+0.0j)".  Undoing it here is exact: float_repr
    ; only ever adds those two characters when the digits carry no '.', 'e',
    ; 'n' or 'i' of their own, so a trailing ".0" is always the one it added.
    cmp qword [rbp - CRA_LEN], 2
    jb .cra_done
    cmp word [rax - 2], '0' * 256 + '.'
    jne .cra_done
    sub rax, 2
.cra_done:
    leave
    ret
END_FUNC complex_repr_append

;; ============================================================================
;; complex_hash(rdi = PyComplexObject*) -> rax = hash
;;
;; CPython's complex_hash is plain 64-bit wrapping arithmetic:
;;   combined = hash(real) + _PyHASH_IMAG * hash(imag), with _PyHASH_IMAG =
;;   1000003, then -1 -> -2.
;; The 2^61-1 reduction people remember belongs to _Py_HashDouble, which
;; float_hash already implements exactly.  hash(complex(2,0)) == hash(2) falls
;; out of hash(0.0) being 0.
;;
;; Divergence worth knowing: CPython hashes a NaN by object identity, so
;; hash(complex(nan,0)) differs per object there.  float_hash returns 0 for a
;; NaN here (a pre-existing choice), so ours is stable -- no test may print it.
;; ============================================================================
CH_IMAG  equ 8
CH_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC complex_hash, CH_FRAME
    push rbx
    mov rax, [rdi + PyComplexObject.cval_imag]
    mov [rbp - CH_IMAG], rax
    mov rdi, [rdi + PyComplexObject.cval_real]
    mov edx, TAG_FLOAT          ; raw parts, not float subclass instances
    call float_hash
    mov rbx, rax
    mov rdi, [rbp - CH_IMAG]
    mov edx, TAG_FLOAT
    call float_hash
    mov ecx, 1000003
    imul rax, rcx
    add rax, rbx
    cmp rax, -1
    jne .chs_done
    mov rax, -2
.chs_done:
    pop rbx
    leave
    ret
END_FUNC complex_hash

;; ============================================================================
;; complex_compare(rdi = left Value, rsi = right Value, edx = op) -> Value
;;
;; Equality only.  Ordering returns a NULL Value; both sides then decline and
;; op_compare_op raises, which is what CPython does for complex.
;; ============================================================================
CC_A     equ 16
CC_B     equ 32
CC_OP    equ 40
CC_RSAVE equ 48
CC_FRAME equ 48             ; + 0 pushes = 48
DEF_FUNC complex_compare, CC_FRAME
    cmp edx, PY_EQ
    je .cc_ok
    cmp edx, PY_NE
    jne .cc_decline
.cc_ok:
    mov [rbp - CC_OP], edx
    mov [rbp - CC_RSAVE], rsi
    lea rsi, [rbp - CC_A]
    call complex_to_parts
    test eax, eax
    jz .cc_decline
    mov rdi, [rbp - CC_RSAVE]
    lea rsi, [rbp - CC_B]
    call complex_to_parts
    test eax, eax
    jz .cc_decline

    movsd xmm0, [rbp - CC_A]
    ucomisd xmm0, [rbp - CC_B]
    jp .cc_false                ; a NaN part is never equal
    jne .cc_false
    movsd xmm0, [rbp - CC_A + 8]
    ucomisd xmm0, [rbp - CC_B + 8]
    jp .cc_false
    jne .cc_false
.cc_true:
    cmp dword [rbp - CC_OP], PY_EQ
    je .cc_ret_true
    jmp .cc_ret_false
.cc_false:
    cmp dword [rbp - CC_OP], PY_EQ
    je .cc_ret_false
.cc_ret_true:
    lea rax, [rel bool_true]
    leave
    ret
.cc_ret_false:
    lea rax, [rel bool_false]
    leave
    ret
.cc_decline:
    xor eax, eax                ; NULL Value = NotImplemented
    leave
    ret
END_FUNC complex_compare

;; ============================================================================
;; complex_getattr(rdi = self, rsi = name str) -> rax = Value, or NULL
;;
;; .real and .imag.  Not a getset descriptor: getset_descr_new is a stub with a
;; NULL accessor, created once so types.py can name the type, and nothing in
;; the tree ever reads gs_get.  bool_getattr does exactly this for the same two
;; names.  Returning NULL rather than raising lets op_load_attr fall through to
;; the MRO's tp_dicts, which is how conjugate() coexists with this chain.
;; ============================================================================
CG_SELF  equ 8
CG_NAME  equ 16             ; the attribute name's char data, across the calls
CG_FRAME equ 16             ; + 0 pushes = 16
DEF_FUNC complex_getattr, CG_FRAME
    mov [rbp - CG_SELF], rdi
    lea rax, [rsi + PyStrObject.data]
    mov [rbp - CG_NAME], rax

    mov rdi, rax
    lea rsi, [rel cx_name_real]
    call ap_strcmp
    test eax, eax
    jz .cg_real

    mov rdi, [rbp - CG_NAME]
    lea rsi, [rel cx_name_imag]
    call ap_strcmp
    test eax, eax
    jz .cg_imag

    xor eax, eax                ; not ours: op_load_attr walks tp_dict next
    leave
    ret

.cg_real:
    mov rdi, [rbp - CG_SELF]
    call complex_get_real
    leave
    ret
.cg_imag:
    mov rdi, [rbp - CG_SELF]
    call complex_get_imag
    leave
    ret
END_FUNC complex_getattr

;; ============================================================================
;; complex_get_real(rdi = self) -> rax = Value
;; complex_get_imag(rdi = self) -> rax = Value
;;
;; Behind complex.real and complex.imag, reached from the chain above and from
;; the getset descriptors in complex_type.tp_dict.
;; ============================================================================
DEF_FUNC complex_get_real
    mov rax, [rdi + PyComplexObject.cval_real]
    V_FROM_F64 rax, rcx
    leave
    ret
END_FUNC complex_get_real

DEF_FUNC complex_get_imag
    mov rax, [rdi + PyComplexObject.cval_imag]
    V_FROM_F64 rax, rcx
    leave
    ret
END_FUNC complex_get_imag

section .rodata
cx_name_real: db "real", 0
cx_name_imag: db "imag", 0
complex_name_str: db "complex", 0

align 16
cx_absmask:  dq 0x7FFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF
align 16
cx_signmask: dq 0x8000000000000000, 0x8000000000000000
align 8
cx_inf:      dq 0x7FF0000000000000
cx_nan:      dq 0x7FF8000000000000
cx_one:      dq 1.0

;; ============================================================================
;; The number-methods table.  Written out one slot per line rather than with
;; `times N dq 0` runs: which slot is which has to be readable, and a silent
;; misalignment here mis-dispatches an operator.
;;
;; nb_floor_divide, nb_remainder and nb_divmod stay 0 on purpose -- `z // 2`,
;; `z % 2` and `divmod(z, 2)` are TypeErrors in 3.12.  So do nb_int, nb_float
;; and nb_index: int(z) and float(z) raise.
;; ============================================================================
section .data
align 8
global complex_number_methods
complex_number_methods:
    dq complex_add            ; nb_add          +0
    dq complex_sub            ; nb_subtract     +8
    dq complex_mul            ; nb_multiply     +16
    dq 0                      ; nb_remainder    +24
    dq 0                      ; nb_divmod       +32
    dq complex_pow            ; nb_power        +40
    dq complex_neg            ; nb_negative     +48
    dq complex_pos            ; nb_positive     +56
    dq complex_abs            ; nb_absolute     +64
    dq complex_bool           ; nb_bool         +72
    dq 0                      ; nb_invert       +80
    dq 0                      ; nb_lshift       +88
    dq 0                      ; nb_rshift       +96
    dq 0                      ; nb_and          +104
    dq 0                      ; nb_or           +112
    dq 0                      ; nb_xor          +120
    dq 0                      ; nb_int          +128
    dq 0                      ; nb_float        +136
    dq 0                      ; nb_floor_divide +144
    dq complex_truediv        ; nb_true_divide  +152
    dq 0                      ; nb_index        +160
    dq 0                      ; nb_inplace_add
    dq 0                      ; nb_inplace_subtract
    dq 0                      ; nb_inplace_multiply
    dq 0                      ; nb_inplace_remainder
    dq 0                      ; nb_inplace_power
    dq 0                      ; nb_inplace_lshift
    dq 0                      ; nb_inplace_rshift
    dq 0                      ; nb_inplace_and
    dq 0                      ; nb_inplace_or
    dq 0                      ; nb_inplace_xor
    dq 0                      ; nb_inplace_floor_divide
    dq 0                      ; nb_inplace_true_divide
    dq 0                      ; nb_matrix_multiply
    dq 0                      ; nb_inplace_matrix_multiply

align 8
global complex_type
complex_type:
    dq 0x00000000FFFFFFFF       ; ob_ref_local=IMMORTAL, ob_ref_shared=0
    dq 0                        ; ob_tid=0 (immortal), ob_mutex=0
    dq type_type              ; ob_type
    dq complex_name_str       ; tp_name
    dq PyComplexObject_size   ; tp_basicsize
    dq 0                      ; tp_dealloc (no owned children; obj_dealloc frees)
    dq complex_repr           ; tp_repr
    dq complex_repr           ; tp_str
    dq complex_hash           ; tp_hash
    dq 0                      ; tp_call
    dq complex_getattr        ; tp_getattr
    dq 0                      ; tp_setattr
    dq complex_compare        ; tp_richcompare
    dq 0                      ; tp_iter
    dq 0                      ; tp_iternext
    dq 0                      ; tp_init
    dq 0                      ; tp_new (installed by add_builtin_type)
    dq complex_number_methods ; tp_as_number
    dq 0                      ; tp_as_sequence
    dq 0                      ; tp_as_mapping
    dq 0                      ; tp_base
    dq 0                      ; tp_dict (installed by methods_init)
    dq 0                      ; tp_mro
    dq TYPE_FLAG_COMPLEX_SUBCLASS ; tp_flags -- the family bit, and no
                                  ; HAVE_GC: a complex owns nothing
    dq 0                      ; tp_bases
    dq 0                      ; tp_traverse
    dq 0                      ; tp_clear
    dq 0                      ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
