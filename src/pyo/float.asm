; float.asm - Float type (IEEE 754 double precision)
;
; PyFloatObject layout:
;   +0  ob_refcnt (8 bytes)
;   +8  ob_type   (8 bytes)
;   +16 value     (8 bytes: double)
;   Total: 24 bytes

%include "macros.inc"
%include "object.inc"

extern int_promote_mpz
extern str_from_cstr
extern bool_true
extern bool_false
extern none_singleton
extern int_from_i64
extern int_type
extern raise_exception
extern exc_ZeroDivisionError_type
extern exc_OverflowError_type
extern exc_ValueError_type
extern obj_incref

; libc functions for float formatting
extern snprintf
extern strtod

; GMP for int-to-double conversion
extern __gmpz_get_d

;; ============================================================================
;; float_from_f64 - Create an inline float from a double in xmm0
;; Input:  xmm0 = double value
;; Output: rax = raw double bits (payload), edx = TAG_FLOAT
;; ============================================================================
DEF_FUNC_BARE float_from_f64
    movq rax, xmm0
    mov edx, TAG_FLOAT
    ret
END_FUNC float_from_f64

;; ============================================================================
;; float_to_f64 - Convert numeric value to double
;; Input:  rdi = payload, esi = tag
;; Output: xmm0 = double value
;; Clobbers: rax, rcx, rdx, rdi, rsi, r8-r11
;; ============================================================================
DEF_FUNC_BARE float_to_f64
    ; rdi = payload, esi = tag
    cmp esi, TAG_FLOAT
    je .from_float

    cmp esi, TAG_SMALLINT
    je .from_smallint

    ; TAG_PTR: check for GMP int or bool singleton
    test rdi, rdi
    jz .ret_zero
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .from_gmp_int
    extern bool_type
    lea rcx, [rel bool_type]
    cmp rax, rcx
    je .from_gmp_int           ; bool singletons have embedded mpz
    ; An int subclass wraps its value; unwrap and retry, or 1.0 == MyInt(1)
    ; came out False.
    mov rcx, [rax + PyTypeObject.tp_flags]
    ; A float subclass stores its double inline at the same offset the base
    ; would, which is the whole reason it cannot come from instance_new.
    test rcx, TYPE_FLAG_FLOAT_SUBCLASS
    jnz .from_float_sub
    test rcx, TYPE_FLAG_INT_SUBCLASS
    jz .ret_zero
    mov edx, esi
    extern int_unwrap
    call int_unwrap
    mov esi, edx
    cmp esi, TAG_SMALLINT
    je .from_smallint
    test rdi, rdi
    jz .ret_zero
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .from_gmp_int

    ; Not a number - return 0.0
.ret_zero:
    xorpd xmm0, xmm0
    ret

.from_float:
    movq xmm0, rdi
    ret

.from_float_sub:
    movsd xmm0, [rdi + PyFloatObject.value]
    ret

.from_smallint:
    mov rax, rdi
    cvtsi2sd xmm0, rax
    ret

FTF_RBX equ 8               ; where .from_gmp_int's push of rbx lands

.from_gmp_int:
    ; mpz_get_d TRUNCATES toward zero, and CPython's PyLong_AsDouble rounds to
    ; nearest even: float(10**30) was 9.999999999999999e+29 rather than 1e+30,
    ; and every complex() and comparison of such a value inherited it.
    ;
    ; The decimal string and strtod get it right -- strtod is required to
    ; round to nearest even -- and this path already pays for GMP, so the
    ; conversion costs nothing that matters.
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8
    and rsp, -16
    mov rax, rdi
    mov edx, TAG_PTR
    V_PACK rax, rdx
    mov rdi, rax
    mov esi, 10
    xor edx, edx
    extern int_base_str
    call int_base_str
    test rax, rax
    jz .ftf_gmp_fallback
    mov rbx, rax
    mov rdi, rax
    xor esi, esi
    extern strtod
    call strtod wrt ..plt
    movq rax, xmm0
    push rax
    mov rdi, rbx
    extern ap_free
    call ap_free
    pop rax
    movq xmm0, rax
    lea rsp, [rbp - FTF_RBX]    ; rbx sits just below the saved rbp
    pop rbx
    leave
    ret

.ftf_gmp_fallback:
    ; No string to convert: fall back on the truncating primitive rather than
    ; answering nothing.
    INT_NEED_MPZ rdi
    lea rdi, [rdi + PyIntObject.mpz]
    call __gmpz_get_d wrt ..plt
    lea rsp, [rbp - FTF_RBX]
    pop rbx
    leave
    ret
END_FUNC float_to_f64

;; ============================================================================
;; float_repr(rdi = raw double bits) -> PyStrObject*
;; Uses shortest representation that round-trips.
;; ============================================================================
; Named slots for the second buffer the notation choice needs.
FR_VAL   equ 8
FR_PREC  equ 16
FR_BUF   equ 64          ; 48 bytes, [rbp-64, rbp-16)
FR_EBUF  equ 128         ; 48 bytes, [rbp-128, rbp-80)
FR_EXP   equ 136
FR_BUMP  equ 144         ; the last digit was carried up by one; the frame
                         ; below grew from 160 to 176 to make room

FR_VALUE equ 8              ; the double being rendered
FR_PREC  equ 16             ; precision counter (low 4 bytes)
FR_BUF   equ 64             ; 48-byte render buffer
                            ; (the frame is built by hand below: `and rsp,-16`
                            ; then `sub rsp,176`, for libc's aligned SSE)
;; ============================================================================
;; fr_bump_last(rdi = a NUL-terminated "d.ddd[e+dd]") -> eax = 1 on success
;;
;; Carry one into the last significant digit.  The exponent part, if any, is
;; left alone; a carry that escapes the leading digit would change the
;; exponent, and that candidate is refused rather than fixed up -- it can
;; only arise from an all-nines mantissa, where the next precision answers.
;; ============================================================================
DEF_FUNC_BARE fr_bump_last
    ; Find the end of the mantissa: the 'e', or the terminator.
    xor ecx, ecx
.fbl_scan:
    movzx eax, byte [rdi + rcx]
    test al, al
    jz .fbl_at_end
    cmp al, 'e'
    je .fbl_at_end
    cmp al, 'E'
    je .fbl_at_end
    inc rcx
    jmp .fbl_scan
.fbl_at_end:
    dec rcx                     ; the last character of the mantissa
.fbl_carry:
    test rcx, rcx
    js .fbl_overflow
    movzx eax, byte [rdi + rcx]
    cmp al, '.'
    je .fbl_skip
    cmp al, '0'
    jb .fbl_overflow
    cmp al, '9'
    ja .fbl_overflow
    cmp al, '9'
    je .fbl_nine
    inc al
    mov [rdi + rcx], al
    mov eax, 1
    ret
.fbl_nine:
    mov byte [rdi + rcx], '0'
.fbl_skip:
    dec rcx
    jmp .fbl_carry
.fbl_overflow:
    xor eax, eax
    ret
END_FUNC fr_bump_last

DEF_FUNC float_repr
    ; A float subclass arrives as a pointer with its double inline, and only
    ; the tag can say so: a subnormal's bit pattern is a small integer, which
    ; is exactly what a pointer looks like.  Every caller supplies edx.
    cmp edx, TAG_PTR
    jne .fr_have_bits
    mov rdi, [rdi + PyFloatObject.value]
.fr_have_bits:
    and rsp, -16              ; ensure 16-byte alignment for libc calls
    sub rsp, 176
    ; Stack layout:
    ;   [rbp - FR_VALUE]   = original double value (8 bytes)
    ;   [rbp - FR_PREC]  = precision counter (8 bytes, only low 4 used)
    ;   [rbp - FR_BUF]  = the 48-byte render buffer

    movq xmm0, rdi
    movsd [rbp - FR_VALUE], xmm0       ; save original value

    ; Check for NaN
    ucomisd xmm0, xmm0
    jp .is_nan

    ; Check for infinity
    movsd xmm1, [rel pos_inf]
    ucomisd xmm0, xmm1
    je .is_pos_inf
    movsd xmm1, [rel neg_inf]
    ucomisd xmm0, xmm1
    je .is_neg_inf

    ; The general case.  dtoa_shortest computes the shortest decimal that
    ; reads back as this double directly, in one pass over a table of powers
    ; of five -- where this used to search "%.1e" through "%.17e", twice each,
    ; with a strtod after every attempt to see whether it round-tripped.  That
    ; search cost up to 34 snprintf and 34 strtod calls and was linear in the
    ; digit count; this is flat, as CPython's dtoa is.
    ;
    ; Zero is rendered here rather than there: the shortest-decimal question is
    ; about the gap to the neighbouring doubles, and zero has no meaningful
    ; interval of its own.
    mov rax, [rbp - FR_VALUE]
    mov rdx, rax
    add rdx, rdx                    ; drop the sign bit
    jnz .fr_general
    lea rdi, [rel str_zero]
    test rax, rax
    jns .fr_zero_emit
    lea rdi, [rel str_neg_zero]
.fr_zero_emit:
    call str_from_cstr
    leave
    ret

.fr_general:
    mov rdi, rax
    extern dtoa_shortest
    call dtoa_shortest              ; rax = the digits, edx = the exponent
    mov rdi, rax
    movsxd rsi, edx
    mov rdx, [rbp - FR_VALUE]
    shr rdx, 63                     ; negative?
    lea rcx, [rbp - FR_BUF]
    extern dtoa_format
    call dtoa_format
    lea rdi, [rbp - FR_BUF]
    call str_from_cstr
    leave
    ret

.has_dot:
    lea rdi, [rbp - FR_BUF]
    call str_from_cstr
    leave
    ret

.is_nan:
    lea rdi, [rel str_nan]
    call str_from_cstr
    leave
    ret

.is_pos_inf:
    lea rdi, [rel str_inf]
    call str_from_cstr
    leave
    ret

.is_neg_inf:
    lea rdi, [rel str_neg_inf]
    call str_from_cstr
    leave
    ret
END_FUNC float_repr

;; ============================================================================
;; float_format_spec(rdi = raw double bits, rsi = spec data ptr, edx = spec length) -> PyStrObject*
;; Format float using a format spec string like ".2f", ".4e", etc.
;; ============================================================================
FS_VALUE   equ 8            ; the double being formatted
FS_SPEC    equ 16           ; spec data pointer
FS_SPECLEN equ 20           ; spec length (4 bytes)
FS_PREC    equ 24           ; precision (4 bytes)
FS_TYPE    equ 25           ; the type character
FS_ALT     equ 26           ; 1 when the spec opened with '#'
FS_BUF     equ 76           ; 48-byte render buffer, for the ordinary case
FS_BUFSZ   equ 48
FS_FMT     equ 88           ; the snprintf format, across the retry
FS_HEAP    equ 96           ; a bigger buffer, when 48 bytes will not do
FS_HEAPN   equ 104
FS_FRAME   equ 112          ; + 0 pushes = 112
DEF_FUNC float_format_spec, FS_FRAME
    and rsp, -16              ; ensure alignment

    movq xmm0, rdi
    movsd [rbp - FS_VALUE], xmm0      ; save value

    ; Parse spec: look for optional '.', digits, then type char (f/e/g)
    ; Simple parser: find precision and type
    mov [rbp - FS_SPEC], rsi         ; spec data
    mov [rbp - FS_SPECLEN], edx         ; spec len

    ; Default: precision=6, type='f'
    mov dword [rbp - FS_PREC], 6     ; precision
    mov byte [rbp - FS_TYPE], 'g'    ; type
    mov byte [rbp - FS_ALT], 0
    ; The spec may open with '#'.  It was not looked for at all, so the flag
    ; was parsed by the caller and then dropped: format(1.5, "#.0f") answered
    ; '2' where CPython answers '2.'.
    test edx, edx
    jz .ffs_no_alt
    cmp byte [rsi], '#'
    jne .ffs_no_alt
    mov byte [rbp - FS_ALT], 1
.ffs_no_alt:

    ; Scan spec
    xor ecx, ecx              ; pos
    mov rsi, [rbp - FS_SPEC]

    ; Skip fill/align/sign/width for now — just look for '.' and type
.ffs_scan:
    cmp ecx, edx
    jge .ffs_have_spec
    movzx eax, byte [rsi + rcx]
    cmp al, '.'
    je .ffs_dot
    ; Check if it's a type char at the end
    cmp ecx, edx
    jge .ffs_have_spec
    inc ecx
    jmp .ffs_scan

.ffs_dot:
    ; Found '.': read precision digits
    inc ecx                   ; skip '.'
    xor eax, eax              ; precision = 0
.ffs_prec_loop:
    cmp ecx, edx
    jge .ffs_store_prec
    movzx edi, byte [rsi + rcx]
    sub edi, '0'
    cmp edi, 9
    ja .ffs_prec_done         ; not a digit
    imul eax, eax, 10
    add eax, edi
    inc ecx
    jmp .ffs_prec_loop
.ffs_prec_done:
    ; Next char should be type
    cmp ecx, edx
    jge .ffs_store_prec
    movzx edi, byte [rsi + rcx]
    mov [rbp - FS_TYPE], dil         ; type char
.ffs_store_prec:
    mov [rbp - FS_PREC], eax

.ffs_have_spec:
    ; Format using snprintf with appropriate format string

    ; Each of the six letters has its own conversion.  The uppercase ones are
    ; not cosmetic: C99's %F and %G spell a non-finite result INF and NAN,
    ; which is the whole difference CPython draws between 'f' and 'F'.  'F'
    ; used to share fmt_f, so format(float('inf'), 'F') was "inf"; 'G' had no
    ; case at all and fell to the %g default, so format(1e20, 'G') was
    ; "1e+20".  'E' was right by accident of already having fmt_E.
    movzx eax, byte [rbp - FS_TYPE]  ; type char
    cmp byte [rbp - FS_ALT], 0
    jne .ffs_alt_table
    cmp al, 'f'
    je .ffs_use_f
    cmp al, 'F'
    je .ffs_use_F
    cmp al, 'e'
    je .ffs_use_e
    cmp al, 'E'
    je .ffs_use_E
    cmp al, 'G'
    je .ffs_use_G
    ; Default: use %.*g
    lea rdx, [rel fmt_g]
    jmp .ffs_do_snprintf
.ffs_alt_table:
    cmp al, 'f'
    je .ffs_alt_f
    cmp al, 'F'
    je .ffs_alt_F
    cmp al, 'e'
    je .ffs_alt_e
    cmp al, 'E'
    je .ffs_alt_E
    cmp al, 'G'
    je .ffs_alt_G
    lea rdx, [rel fmt_alt_g]
    jmp .ffs_do_snprintf
.ffs_alt_f:
    lea rdx, [rel fmt_alt_f]
    jmp .ffs_do_snprintf
.ffs_alt_F:
    lea rdx, [rel fmt_alt_F]
    jmp .ffs_do_snprintf
.ffs_alt_e:
    lea rdx, [rel fmt_alt_e]
    jmp .ffs_do_snprintf
.ffs_alt_E:
    lea rdx, [rel fmt_alt_E]
    jmp .ffs_do_snprintf
.ffs_alt_G:
    lea rdx, [rel fmt_alt_G]
    jmp .ffs_do_snprintf

.ffs_use_f:
    lea rdx, [rel fmt_f]
    jmp .ffs_do_snprintf
.ffs_use_F:
    lea rdx, [rel fmt_F]
    jmp .ffs_do_snprintf
.ffs_use_e:
    lea rdx, [rel fmt_e]
    jmp .ffs_do_snprintf
.ffs_use_G:
    lea rdx, [rel fmt_G]
    jmp .ffs_do_snprintf
.ffs_use_E:
    lea rdx, [rel fmt_E]

.ffs_do_snprintf:
    mov [rbp - FS_FMT], rdx
    lea rdi, [rbp - FS_BUF]         ; the 48-byte stack buffer
    mov esi, FS_BUFSZ
    mov ecx, [rbp - FS_PREC]         ; precision
    movsd xmm0, [rbp - FS_VALUE]      ; value
    mov eax, 1                ; 1 xmm register
    call snprintf wrt ..plt

    ; snprintf reports what it WOULD have written, and the buffer is 48
    ; bytes: format(1e300, '.2f') needs 305 and used to come back truncated
    ; at 46 digits, with the fractional part it was asked for missing
    ; entirely, and format(1e16, '.30f') was one zero short.  Anything that
    ; does not fit is rendered again into a heap buffer of the size snprintf
    ; just named.  The stack path is untouched, which is every ordinary
    ; magnitude and every repr.
    cmp eax, FS_BUFSZ
    jae .ffs_needs_heap

    lea rdi, [rbp - FS_BUF]
    call str_from_cstr
    leave
    ret

.ffs_needs_heap:
    inc eax                     ; room for the NUL
    mov [rbp - FS_HEAPN], eax
    mov edi, eax
    extern ap_malloc
    call ap_malloc
    mov [rbp - FS_HEAP], rax
    mov rdi, rax
    mov esi, [rbp - FS_HEAPN]
    mov rdx, [rbp - FS_FMT]
    mov ecx, [rbp - FS_PREC]
    movsd xmm0, [rbp - FS_VALUE]
    mov eax, 1
    call snprintf wrt ..plt
    mov rdi, [rbp - FS_HEAP]
    call str_from_cstr
    mov [rbp - FS_VALUE], rax   ; the string, across the free
    mov rdi, [rbp - FS_HEAP]
    extern ap_free
    call ap_free
    mov rax, [rbp - FS_VALUE]
    leave
    ret
END_FUNC float_format_spec

;; ============================================================================
;; float_hash(rdi = raw double bits) -> int64 in rax
;; For integer-valued floats, returns hash(int(x)) to match PEP requirement:
;;   hash(float(n)) == hash(n)
;; For non-integer floats, returns a hash derived from the raw bits.
;; ============================================================================
;; _Py_HashDouble, exactly.  The old code returned the truncated integer for
;; an integral float and an xor of the raw bits otherwise, so hash(1.5) bore
;; no relation to CPython's and hash(2**61) != hash(float(2**61)) -- an int
;; and an equal float landed in different dict slots.
FH_EXP   equ 8
FH_M     equ 16
FH_FRAME equ 40            ; + 3 pushes = 64, 16-aligned
DEF_FUNC float_hash, FH_FRAME
    push rbx
    push r12
    push r13
    ; As float_repr: a subclass instance is a pointer, and the tag is the only
    ; thing that distinguishes it from the bits of a subnormal.
    cmp edx, TAG_PTR
    jne .fh_have_bits
    mov rdi, [rdi + PyFloatObject.value]
.fh_have_bits:
    movq xmm0, rdi

    ; Check NaN (unordered with itself)
    ucomisd xmm0, xmm0
    jp .fh_nan

    ; Check infinity
    movsd xmm1, [rel pos_inf]
    ucomisd xmm0, xmm1
    je .fh_pos_inf
    movsd xmm1, [rel neg_inf]
    ucomisd xmm0, xmm1
    je .fh_neg_inf

    ; sign, then frexp: v = m * 2^e with |m| in [0.5, 1)
    xor r13d, r13d                      ; sign = +1
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    jae .fh_positive
    mov r13d, 1                         ; sign = -1
    movsd xmm1, [rel fh_sign_mask]
    xorpd xmm0, xmm1                    ; m = -m
.fh_positive:
    lea rdi, [rbp - FH_EXP]
    extern frexp
    call frexp wrt ..plt
    movsd [rbp - FH_M], xmm0
    movsxd r12, dword [rbp - FH_EXP]    ; r12 = e

    xor ebx, ebx                        ; x = 0
    mov r10, PYHASH_MODULUS
.fh_loop:
    movsd xmm0, [rbp - FH_M]
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    jp .fh_loop_done
    je .fh_loop_done

    ; x = ((x << 28) & MODULUS) | (x >> 33)
    mov rax, rbx
    shl rax, 28
    and rax, r10
    mov rcx, rbx
    shr rcx, 33
    or rax, rcx
    mov rbx, rax

    ; m *= 2**28; e -= 28
    mulsd xmm0, [rel fh_two28]
    sub r12, 28

    ; y = (uint64)m; m -= y; x += y
    cvttsd2si rax, xmm0
    mov r11, rax
    cvtsi2sd xmm1, rax
    subsd xmm0, xmm1
    movsd [rbp - FH_M], xmm0
    add rbx, r11
    cmp rbx, r10
    jb .fh_loop
    sub rbx, r10
    jmp .fh_loop
.fh_loop_done:

    ; e mod 61, taken toward -infinity
    test r12, r12
    js .fh_neg_exp
    mov rax, r12
    xor edx, edx
    mov ecx, 61
    div rcx
    mov r12, rdx
    jmp .fh_rotate
.fh_neg_exp:
    mov rax, r12
    not rax                             ; -1 - e
    xor edx, edx
    mov ecx, 61
    div rcx
    mov r12d, 60
    sub r12, rdx
.fh_rotate:
    ; x = ((x << e) & MODULUS) | (x >> (61 - e))
    mov rax, rbx
    mov rcx, r12
    shl rax, cl
    and rax, r10
    mov rdx, rbx
    mov ecx, 61
    sub rcx, r12
    shr rdx, cl
    or rax, rdx

    test r13d, r13d
    jz .fh_signed
    neg rax
.fh_signed:
    cmp rax, -1
    jne .fh_done
    mov rax, -2
.fh_done:
    pop r13
    pop r12
    pop rbx
    leave
    ret

.fh_nan:
    xor eax, eax              ; hash(nan) = 0
    pop r13
    pop r12
    pop rbx
    leave
    ret

.fh_pos_inf:
    mov eax, 314159                 ; hash(inf) = 314159 (CPython convention)
    pop r13
    pop r12
    pop rbx
    leave
    ret

.fh_neg_inf:
    mov rax, -314159           ; hash(-inf) = -314159
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC float_hash

section .rodata
align 16
fh_sign_mask: dq 0x8000000000000000, 0
align 16
frn_absmask:  dq 0x7fffffffffffffff, 0x7fffffffffffffff

;; 5**0 through 5**22.  5**22 is 2384185791015625, under 2**52, so a 53-bit
;; mantissa times any of them stays inside 128 bits.
align 8
frn_pow5:
    dq 1
    dq 5
    dq 25
    dq 125
    dq 625
    dq 3125
    dq 15625
    dq 78125
    dq 390625
    dq 1953125
    dq 9765625
    dq 48828125
    dq 244140625
    dq 1220703125
    dq 6103515625
    dq 30517578125
    dq 152587890625
    dq 762939453125
    dq 3814697265625
    dq 19073486328125
    dq 95367431640625
    dq 476837158203125
    dq 2384185791015625

;; 10**0 through 10**22, every one of them exact as a double.
align 8
frn_pow10:
    dq 0x3ff0000000000000        ; 1e0
    dq 0x4024000000000000        ; 1e1
    dq 0x4059000000000000        ; 1e2
    dq 0x408f400000000000        ; 1e3
    dq 0x40c3880000000000        ; 1e4
    dq 0x40f86a0000000000        ; 1e5
    dq 0x412e848000000000        ; 1e6
    dq 0x416312d000000000        ; 1e7
    dq 0x4197d78400000000        ; 1e8
    dq 0x41cdcd6500000000        ; 1e9
    dq 0x4202a05f20000000        ; 1e10
    dq 0x42374876e8000000        ; 1e11
    dq 0x426d1a94a2000000        ; 1e12
    dq 0x42a2309ce5400000        ; 1e13
    dq 0x42d6bcc41e900000        ; 1e14
    dq 0x430c6bf526340000        ; 1e15
    dq 0x4341c37937e08000        ; 1e16
    dq 0x4376345785d8a000        ; 1e17
    dq 0x43abc16d674ec800        ; 1e18
    dq 0x43e158e460913d00        ; 1e19
    dq 0x4415af1d78b58c40        ; 1e20
    dq 0x444b1ae4d6e2ef50        ; 1e21
    dq 0x4480f0cf064dd592        ; 1e22
align 8
fh_two28:     dq 0x41b0000000000000      ; 2.0**28
section .text

;; ============================================================================
;; float_bool(rdi = raw double bits) -> int (0 or 1) in eax
;; ============================================================================
DEF_FUNC_BARE float_bool
    ; A subclass instance arrives as a pointer; nb_bool takes a Value, so an
    ; immediate arrives boxed rather than as raw bits.
    V_TEST_PTR rdi, rax
    ja .fbool_immediate
    mov rdi, [rdi + PyFloatObject.value]
    jmp .fbool_have_bits
.fbool_immediate:
    V_TO_F64 rdi
.fbool_have_bits:
    movq xmm0, rdi
    xorpd xmm1, xmm1         ; xmm1 = 0.0
    ucomisd xmm0, xmm1
    jp .fbool_true           ; UNORDERED sets ZF too: bool(nan) is True, and
    je .is_zero              ; the je alone made it False for a float subclass
.fbool_true:
    mov eax, 1
    ret
.is_zero:
    ; -0.0 compares equal to 0.0, so it lands here too, which is right.
    xor eax, eax
    ret
END_FUNC float_bool

;; float_dealloc removed — floats are inline (TAG_FLOAT), no heap allocation

;; ============================================================================
;; float_binop_accepts(rdi = payload, esi = tag) -> eax = 1 when this operand
;; is one float arithmetic can consume: a float or an int in any of its shapes.
;;
;; The single definition of what float arithmetic accepts.  It used to be
;; written out twice inside float_compare and a third time, differently, as
;; binop_is_number in src/opcodes/arith.asm; the point of naming it is that a
;; fourth copy cannot now drift from the others.
;; ============================================================================
DEF_FUNC_BARE float_binop_accepts
    cmp esi, TAG_FLOAT
    je .fba_yes
    cmp esi, TAG_SMALLINT
    je .fba_yes
    cmp esi, TAG_PTR
    jne .fba_no
    test rdi, rdi
    jz .fba_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .fba_yes
    lea rcx, [rel float_type]
    cmp rax, rcx
    je .fba_yes
    ; A bool is an int, and float_to_f64 already handles one; only the
    ; whitelist was missing it, so True < 2.5 raised and 1.0 == True was
    ; False -- which also put True and 1.0 in different dict slots.
    lea rcx, [rel bool_type]
    cmp rax, rcx
    je .fba_yes
    mov rax, [rax + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_INT_SUBCLASS
    jnz .fba_yes
    ; A float subclass keeps its double where float_to_f64 can read it.
    test rax, TYPE_FLAG_FLOAT_SUBCLASS
    jnz .fba_yes
.fba_no:
    xor eax, eax
    ret
.fba_yes:
    mov eax, 1
    ret
END_FUNC float_binop_accepts

;; ============================================================================
;; Binary arithmetic: float_add, float_sub, float_mul, float_truediv,
;;                    float_floordiv, float_mod, float_neg
;; All take (PyObject *a, PyObject *b) -> PyObject*
;; Convert both to double, perform operation, return new float.
;; ============================================================================

; Helper macro: convert both args to doubles.  Every float binop shares this
; frame, so it is named once here rather than per function.
FB_LEFT   equ 8             ; left operand, as a double
FB_RIGHT  equ 16            ; right operand, as a double
FB_RSAVE  equ 24            ; the right operand across the first conversion
FB_RTAG   equ 32            ; and its tag
FB_LSAVE  equ 40            ; the left operand across the acceptance checks
FB_LTAG   equ 48            ; and its tag
FB_FRAME  equ 48            ; + 0 pushes = 48
%macro FLOAT_BINOP_SETUP 0
    ; rdi=left, rsi=right, edx=left_tag, ecx=right_tag
    ;
    ; Both operands are classified BEFORE either is converted.  float_to_f64
    ; answers 0.0 for anything it does not recognise (.ret_zero below), so a
    ; slot that converted first read a foreign object's bytes as a double and
    ; returned a number: `a = "s"; a %= 1.5` was 0.0 rather than a TypeError.
    ; Declining with a NULL Value hands the pair back to the protocol, which
    ; then tries the other operand and finally raises.
    mov [rbp - FB_RSAVE], rsi
    mov dword [rbp - FB_RTAG], ecx
    mov [rbp - FB_LSAVE], rdi
    mov dword [rbp - FB_LTAG], edx
    mov esi, edx                       ; esi = left_tag
    call float_binop_accepts
    test eax, eax
    jz %%decline
    mov rdi, [rbp - FB_RSAVE]
    mov esi, dword [rbp - FB_RTAG]
    call float_binop_accepts
    test eax, eax
    jnz %%accepted
%%decline:
    xor eax, eax                       ; NULL Value = NotImplemented
    leave
    ret
%%accepted:
    mov rdi, [rbp - FB_LSAVE]
    mov esi, dword [rbp - FB_LTAG]
    call float_to_f64          ; rdi = left → xmm0
    FB_INT_OVERFLOW_CHECK FB_LSAVE, FB_LTAG
    movsd [rbp - FB_LEFT], xmm0
    mov rdi, [rbp - FB_RSAVE]
    mov esi, dword [rbp - FB_RTAG]    ; esi = right_tag
    call float_to_f64          ; xmm0 = right as double
    FB_INT_OVERFLOW_CHECK FB_RSAVE, FB_RTAG
    movsd [rbp - FB_RIGHT], xmm0
%endmacro

; An int operand too large for a double converts to an infinity, and CPython
; refuses it there rather than computing with it: `10**400 * 1.0` is
; OverflowError, not inf -- which is also what math.sumprod's generic path
; has to see.  A float infinity, or a float subclass holding one, is a value.
; %1 = the operand's save slot, %2 = its tag slot; xmm0 = the converted double.
%macro FB_INT_OVERFLOW_CHECK 2
    cmp dword [rbp - %2], TAG_PTR
    jne %%ok
    movapd xmm1, xmm0
    andpd xmm1, [rel frn_absmask]
    ucomisd xmm1, [rel pos_inf]
    jp %%ok
    jne %%ok
    mov rax, [rbp - %1]
    mov rax, [rax + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_FLOAT_SUBCLASS
    jnz %%ok
    RAISE exc_OverflowError_type, "int too large to convert to float"
%%ok:
%endmacro

DEF_FUNC float_add, FB_FRAME
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    FLOAT_BINOP_SETUP
    movsd xmm0, [rbp - FB_LEFT]
    addsd xmm0, [rbp - FB_RIGHT]
    call float_from_f64
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC float_add

DEF_FUNC float_sub, FB_FRAME
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    FLOAT_BINOP_SETUP
    movsd xmm0, [rbp - FB_LEFT]
    subsd xmm0, [rbp - FB_RIGHT]
    call float_from_f64
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC float_sub

DEF_FUNC float_mul, FB_FRAME
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    FLOAT_BINOP_SETUP
    movsd xmm0, [rbp - FB_LEFT]
    mulsd xmm0, [rbp - FB_RIGHT]
    call float_from_f64
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC float_mul

DEF_FUNC float_truediv, FB_FRAME
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    FLOAT_BINOP_SETUP

    ; Check for division by zero.  ucomisd sets ZF for UNORDERED too, so the
    ; je alone read a NaN divisor as a zero one and 1.0 / float("nan") raised
    ; instead of answering nan.
    movsd xmm1, [rbp - FB_RIGHT]
    xorpd xmm2, xmm2
    ucomisd xmm1, xmm2
    jp .div_nonzero
    je .div_zero
.div_nonzero:

    movsd xmm0, [rbp - FB_LEFT]
    divsd xmm0, xmm1
    call float_from_f64
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.div_zero:
    RAISE exc_ZeroDivisionError_type, "float division by zero"
END_FUNC float_truediv

DEF_FUNC float_floordiv, FB_FRAME
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    FLOAT_BINOP_SETUP

    ; Check for division by zero; jp first, as in float_truediv.
    movsd xmm1, [rbp - FB_RIGHT]
    xorpd xmm2, xmm2
    ucomisd xmm1, xmm2
    jp .floordiv_nonzero
    je .floordiv_zero
.floordiv_nonzero:

    movsd xmm0, [rbp - FB_LEFT]
    divsd xmm0, xmm1
    ; Floor: round toward negative infinity
    roundsd xmm0, xmm0, 1     ; 1 = floor
    call float_from_f64
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.floordiv_zero:
    RAISE exc_ZeroDivisionError_type, "float floor division by zero"
END_FUNC float_floordiv

DEF_FUNC float_mod, FB_FRAME
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    FLOAT_BINOP_SETUP

    ; Check for division by zero; jp first, as in float_truediv.
    movsd xmm1, [rbp - FB_RIGHT]
    xorpd xmm2, xmm2
    ucomisd xmm1, xmm2
    jp .mod_nonzero
    je .mod_zero
.mod_nonzero:

    ; a % b = a - floor(a/b) * b
    movsd xmm0, [rbp - FB_LEFT]       ; a
    movsd xmm1, [rbp - FB_RIGHT]      ; b
    movapd xmm2, xmm0         ; save a
    divsd xmm0, xmm1          ; a/b
    roundsd xmm0, xmm0, 1     ; floor(a/b)
    mulsd xmm0, xmm1          ; floor(a/b)*b
    subsd xmm2, xmm0          ; a - floor(a/b)*b
    movapd xmm0, xmm2
    call float_from_f64
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.mod_zero:
    RAISE exc_ZeroDivisionError_type, "float modulo"
END_FUNC float_mod

;; ============================================================================
;; float_neg / float_pos / float_abs (rdi = operand Value) -> a float Value
;;
;; Only a float subclass instance reaches these.  op_unary_negative flips an
;; immediate's sign bit itself and never consults the slot for one, and until
;; float had a subclass nothing else could arrive -- which is why these used
;; to return a fat pair into a caller that reads a Value, harmlessly, because
;; they were unreachable.  CPython gives -F(x) and abs(F(x)) a plain float
;; rather than an F, which is what returning an immediate does here.
;; ============================================================================
DEF_FUNC_BARE float_neg
    V_TEST_PTR rdi, rax
    ja .fneg_immediate
    mov rdi, [rdi + PyFloatObject.value]
    btc rdi, 63
    mov rax, rdi
    V_FROM_F64 rax, rdx
    mov edx, TAG_FLOAT
    ret
.fneg_immediate:
    V_TO_F64 rdi
    btc rdi, 63
    mov rax, rdi
    V_FROM_F64 rax, rdx
    mov edx, TAG_FLOAT
    ret
END_FUNC float_neg

DEF_FUNC_BARE float_abs
    V_TEST_PTR rdi, rax
    ja .fabs_immediate
    mov rdi, [rdi + PyFloatObject.value]
    jmp .fabs_have_bits
.fabs_immediate:
    V_TO_F64 rdi
.fabs_have_bits:
    btr rdi, 63                 ; clear the sign; abs(-0.0) is 0.0
    mov rax, rdi
    V_FROM_F64 rax, rdx
    mov edx, TAG_FLOAT
    ret
END_FUNC float_abs

;; ============================================================================
;; float_pos(rdi = left, rsi = right, edx = left_tag, ecx = right_tag)
;; Unary positive: identity for floats.
;; Note: called via nb_positive slot — only left operand matters.
;; ============================================================================
DEF_FUNC_BARE float_pos
    V_TEST_PTR rdi, rax
    ja .fpos_immediate
    mov rdi, [rdi + PyFloatObject.value]
    mov rax, rdi
    V_FROM_F64 rax, rdx
    mov edx, TAG_FLOAT
    ret
.fpos_immediate:
    mov rax, rdi                ; already a float Value
    mov edx, TAG_FLOAT
    ret
END_FUNC float_pos

;; ============================================================================
;; float_pow(rdi = left, rsi = right, edx = left_tag, ecx = right_tag)
;;
;; CPython's float_pow, followed clause by clause, because the answers this
;; has to give are almost all special cases and none of them fall out of a
;; general formula.  What used to be here was x**y = 2**(y*log2(x)) on the
;; x87, plus fast paths for 0.5 and 2.0 and repeated squaring for an integral
;; exponent, and it got every one of the IEEE corners wrong:
;;
;;   0.0 ** -1        inf, where CPython raises ZeroDivisionError
;;   (-7.5) ** 2.5    nan -- fyl2x's invalid-operation result, handed back
;;                    unexamined -- where CPython promotes to complex
;;   (-1.0) ** inf    nan, where the answer is 1.0
;;   1.0 ** nan       nan, where the answer is 1.0
;;   0.0 ** inf       nan, where the answer is 0.0
;;   2 ** -1074       0.0, because 1/base**1074 overflows on the way
;;   2.0 ** 10000     inf, where CPython raises OverflowError
;;
;; libm's pow is the one that is specified for all of them (C99 Annex F), so
;; the guards below are only the cases CPython settles before calling it.
;; ============================================================================
FP_LEFT   equ 8             ; iv
FP_RIGHT  equ 16            ; iw
FP_NEG    equ 24            ; negate the result?
FP_FRAME  equ 32            ; + 0 pushes = 32
DEF_FUNC float_pow, FB_FRAME
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    FLOAT_BINOP_SETUP
    ; [rbp - FB_LEFT] = iv, [rbp - FB_RIGHT] = iw.  FB_FRAME is 48 and the
    ; three slots below reuse the ones the setup has finished with.

    movsd xmm0, [rbp - FB_LEFT]
    movsd xmm1, [rbp - FB_RIGHT]
    mov qword [rbp - FB_RSAVE], 0       ; negate_result

    ; v ** 0 is 1.0, even 0.0 ** 0.0 and nan ** 0.0.
    xorpd xmm2, xmm2
    ucomisd xmm1, xmm2
    jp .fpow_iw_not_zero
    jne .fpow_iw_not_zero
    jmp .fpow_one
.fpow_iw_not_zero:

    ; nan ** w is nan (w == 0 is already gone).
    ucomisd xmm0, xmm0
    jp .fpow_return_iv

    ; v ** nan is nan, unless v is 1.0.
    ucomisd xmm1, xmm1
    jnp .fpow_iw_not_nan
    movsd xmm2, [rel const_one_f]
    ucomisd xmm0, xmm2
    je .fpow_one
    jmp .fpow_return_iw
.fpow_iw_not_nan:

    ; v ** +-inf: 0.0 when |v| < 1, 1.0 when |v| == 1, inf when |v| > 1 --
    ; and the other way round for -inf.
    movapd xmm3, xmm1
    andpd xmm3, [rel frn_absmask]
    movsd xmm2, [rel pos_inf]
    ucomisd xmm3, xmm2
    jne .fpow_iw_finite
    movapd xmm3, xmm0
    andpd xmm3, [rel frn_absmask]       ; |v|
    movsd xmm2, [rel const_one_f]
    ucomisd xmm3, xmm2
    je .fpow_one                        ; |v| == 1
    ja .fpow_v_gt_one
    ; |v| < 1: inf for a negative exponent, 0.0 for a positive one
    xorpd xmm2, xmm2
    ucomisd xmm1, xmm2
    ja .fpow_zero
    jmp .fpow_inf
.fpow_v_gt_one:
    xorpd xmm2, xmm2
    ucomisd xmm1, xmm2
    ja .fpow_inf
    jmp .fpow_zero
.fpow_iw_finite:

    ; (+-inf) ** w: inf for a positive w, 0.0 for a negative one, and the
    ; sign is v's when w is an odd integer.
    movapd xmm3, xmm0
    andpd xmm3, [rel frn_absmask]
    movsd xmm2, [rel pos_inf]
    ucomisd xmm3, xmm2
    jne .fpow_iv_finite
    movsd xmm0, [rbp - FB_RIGHT]
    call float_is_odd_integer          ; -> eax
    mov r8d, eax
    xorpd xmm2, xmm2
    movsd xmm1, [rbp - FB_RIGHT]
    ucomisd xmm1, xmm2
    jbe .fpow_inf_negexp
    test r8d, r8d
    jz .fpow_inf
    movsd xmm0, [rbp - FB_LEFT]        ; keeps v's sign
    jmp .fpow_out
.fpow_inf_negexp:
    test r8d, r8d
    jz .fpow_zero
    ; copysign(0.0, v)
    xorpd xmm0, xmm0
    movsd xmm1, [rbp - FB_LEFT]
    andpd xmm1, [rel fh_sign_mask]
    orpd xmm0, xmm1
    jmp .fpow_out
.fpow_iv_finite:

    ; 0.0 ** w: an error for a negative w, and otherwise 0.0 with v's sign
    ; when w is an odd integer.
    xorpd xmm2, xmm2
    movsd xmm0, [rbp - FB_LEFT]
    ucomisd xmm0, xmm2
    jp .fpow_iv_not_zero
    jne .fpow_iv_not_zero
    movsd xmm1, [rbp - FB_RIGHT]
    ucomisd xmm1, xmm2
    jb .fpow_zero_div
    movsd xmm0, [rbp - FB_RIGHT]
    call float_is_odd_integer
    test eax, eax
    jz .fpow_zero
    movsd xmm0, [rbp - FB_LEFT]
    jmp .fpow_out
.fpow_iv_not_zero:

    ; A negative base with a non-integral exponent has no real answer, and
    ; CPython's float_pow hands the pair to complex's nb_power rather than
    ; returning the invalid-operation nan.
    xorpd xmm2, xmm2
    ucomisd xmm0, xmm2
    jae .fpow_iv_positive
    movsd xmm0, [rbp - FB_RIGHT]
    roundsd xmm1, xmm0, 1               ; floor(iw)
    ucomisd xmm0, xmm1
    je .fpow_iw_integral
    ; Fractional: complex_pow, which already answers correctly for these.
    mov rdi, [rbp - FB_LEFT]
    V_FROM_F64 rdi, rax
    mov rsi, [rbp - FB_RIGHT]
    V_FROM_F64 rsi, rax
    extern complex_pow
    leave
    jmp complex_pow
.fpow_iw_integral:
    ; |v| ** w, negated afterwards when w is odd.
    movsd xmm0, [rbp - FB_RIGHT]
    call float_is_odd_integer
    mov [rbp - FB_RSAVE], rax
    movsd xmm0, [rbp - FB_LEFT]
    xorpd xmm1, xmm1
    subsd xmm1, xmm0
    movsd [rbp - FB_LEFT], xmm1         ; iv = -iv
    movapd xmm0, xmm1
.fpow_iv_positive:

    ; 1.0 ** w is 1.0 for every w, including the infinities and nan -- and
    ; (-1) ** a large integer arrives here as well, with negate_result set.
    movsd xmm2, [rel const_one_f]
    ucomisd xmm0, xmm2
    jne .fpow_call_libm
    movsd xmm0, [rel const_one_f]
    jmp .fpow_apply_negate

.fpow_call_libm:
    ; iv is finite and positive and not 1.0; iw is finite and not 0.0.
    movsd xmm0, [rbp - FB_LEFT]
    movsd xmm1, [rbp - FB_RIGHT]
    extern pow
    call pow wrt ..plt
.fpow_apply_negate:
    cmp qword [rbp - FB_RSAVE], 0
    je .fpow_check_range
    xorpd xmm1, xmm1
    subsd xmm1, xmm0
    movapd xmm0, xmm1
.fpow_check_range:
    ; Both operands were finite, so an infinite result is an overflow.
    ; CPython reports it through errno as OverflowError.
    movapd xmm3, xmm0
    andpd xmm3, [rel frn_absmask]
    movsd xmm2, [rel pos_inf]
    ucomisd xmm3, xmm2
    je .fpow_overflow
.fpow_out:
    movq rdi, xmm0
    call float_from_f64
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.fpow_one:
    movsd xmm0, [rel const_one_f]
    jmp .fpow_out
.fpow_zero:
    xorpd xmm0, xmm0
    jmp .fpow_out
.fpow_inf:
    movsd xmm0, [rel pos_inf]
    jmp .fpow_out
.fpow_return_iv:
    movsd xmm0, [rbp - FB_LEFT]
    jmp .fpow_out
.fpow_return_iw:
    movsd xmm0, [rbp - FB_RIGHT]
    jmp .fpow_out

.fpow_zero_div:
    RAISE exc_ZeroDivisionError_type, "0.0 cannot be raised to a negative power"

.fpow_overflow:
    ; CPython builds this one from errno, so its args are the pair
    ; (34, 'Numerical result out of range') and str() renders the tuple.
    RAISE exc_OverflowError_type, "(34, 'Numerical result out of range')"
END_FUNC float_pow

;; ============================================================================
;; float_is_odd_integer(xmm0 = x) -> eax = 1 when x is an odd integer
;;
;; CPython's DOUBLE_IS_ODD_INTEGER.  A double at or above 2**53 has no odd
;; values left, so fmod against 2.0 settles it without overflowing anything.
;; ============================================================================
DEF_FUNC_LOCAL float_is_odd_integer
    ; floor(x) == x, and fmod(x, 2.0) is +-1
    roundsd xmm1, xmm0, 1
    ucomisd xmm0, xmm1
    jp .fio_no
    jne .fio_no
    movapd xmm1, xmm0
    andpd xmm1, [rel frn_absmask]
    movsd xmm2, [rel fio_two53]
    ucomisd xmm1, xmm2
    jae .fio_no                 ; every double this large is even
    cvttsd2si rax, xmm0
    and eax, 1
    leave
    ret
.fio_no:
    xor eax, eax
    leave
    ret
END_FUNC float_is_odd_integer

section .rodata
align 8
fio_two53: dq 0x4340000000000000      ; 2.0**53
section .text

;; ============================================================================
;; float_round_ndigits(xmm0 = x, edi = ndigits) -> xmm0 = the rounded double
;;
;; round(x, n) for a finite double.  CPython rounds the DECIMAL
;; representation, not the scaled binary value: double_round hands the value
;; to _Py_dg_dtoa in mode 3 and reads the digits back with _Py_dg_strtod.
;; Scaling by 10**n and rounding the product is a different function --
;; round(2.675, 2) is 2.68 that way and 2.67 CPython's -- and it is also
;; where every one of round()'s wrong answers came from: 10**n overflowed
;; int64 at n >= 19, x * 10**n overflowed to infinity for a large x, and
;; cvtsd2si answered the integer indefinite value for both.
;;
;; glibc's snprintf and strtod are the same pair of correctly-rounded
;; conversions dtoa/strtod are, and float_repr already leans on exactly that
;; to find the shortest round-tripping repr.  So: ask for the value at k
;; significant digits and read it back.
;;
;;   k = (decimal exponent of x) + ndigits + 1
;;
;; k >= 17 means the request is finer than a double can hold and x is its own
;; answer.  k <= 0 means the rounding position is at or left of the leading
;; digit, so the answer is zero or a single power of ten.
;;
;; Frame: aligned for libc's SSE, as float_repr's is.
;; ============================================================================
FRN_X     equ 8               ; the original double
FRN_ND    equ 16              ; ndigits
FRN_BUF   equ 64              ; 40-byte render buffer, [rbp-64, rbp-24)
FRN_FRAME equ 64              ; + 0 pushes = 64
global float_round_ndigits
DEF_FUNC float_round_ndigits, FRN_FRAME
    and rsp, -16
    sub rsp, 96
    movsd [rbp - FRN_X], xmm0
    mov [rbp - FRN_ND], edi

    ; A NaN or an infinity is its own answer, and so is a zero -- which also
    ; keeps its sign, where a round trip through cvtsd2si lost it.
    ucomisd xmm0, xmm0
    jp .frn_identity
    movsd xmm1, [rel pos_inf]
    ucomisd xmm0, xmm1
    je .frn_identity
    movsd xmm1, [rel neg_inf]
    ucomisd xmm0, xmm1
    je .frn_identity
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    jp .frn_not_zero
    jne .frn_not_zero
    jmp .frn_identity           ; +-0.0, sign intact
.frn_not_zero:

    ; CPython's NDIGITS_MAX / NDIGITS_MIN: past either bound the answer is
    ; settled without looking at the digits.
    cmp dword [rbp - FRN_ND], 323
    jg .frn_identity
    cmp dword [rbp - FRN_ND], -308
    jl .frn_zero

    ; ---- the exact integer fast path ------------------------------------
    ;
    ; round(x, n) is the nearest multiple of 10**-n to x, ties to even, and
    ; then the nearest double to THAT.  Write the multiple as N / 10**n with N
    ; an integer.  When
    ;
    ;     0 <= n <= 22    and    N < 2**53
    ;
    ; both halves are exact machine work and no decimal string is needed at
    ; all.  |x| is m * 2**e with m a 53-bit integer, so
    ;
    ;     |x| * 10**n  =  m * 5**n * 2**(e+n)
    ;
    ; -- a 128-bit product and one shift, and the shift is where ties to even
    ; is decided.  5**n through 5**22 fits in 52 bits, so the product fits in
    ; 128.  Then 10**n for n <= 22 and N below 2**53 are both exactly
    ; representable, so `(double)N / (double)10**n` is one IEEE division and
    ; the hardware rounds it correctly.
    ;
    ; This is the same answer the rendering below computes, arrived at without
    ; glibc: its two `%.*e` calls were 66% of a round(x, 2) loop's
    ; instructions and its strtod another 9%.  Everything the bounds exclude
    ; -- a negative n, a value so small that N shifts away to nothing, a value
    ; so large that N will not fit -- falls through to it unchanged, which is
    ; also where round(2.675, 2) = 2.67 goes on being settled by the exact
    ; value rather than by the shortest decimal.
    mov esi, [rbp - FRN_ND]
    test esi, esi
    jl .frn_slow
    cmp esi, 22
    jg .frn_slow

    mov rax, [rbp - FRN_X]
    mov r9, rax
    mov r10, 0x7fffffffffffffff
    and r9, r10                     ; |x| bits
    mov r8, r9
    shr r8, 52                      ; the biased exponent
    mov r10, 0x000fffffffffffff
    and r9, r10                     ; the fraction
    test r8, r8
    jz .frn_fp_subnormal
    bts r9, 52                      ; m = fraction | 1 << 52
    sub r8, 1075                    ; e
    jmp .frn_fp_have
.frn_fp_subnormal:
    mov r8, -1074                   ; and m is the fraction as it stands
.frn_fp_have:
    lea r10, [rel frn_pow5]
    mov rax, [r10 + rsi*8]          ; 5**n
    mul r9                          ; rdx:rax = u = m * 5**n
    add r8, rsi                     ; e + n
    neg r8                          ; s: u is shifted RIGHT by this much
    jle .frn_fp_left

    ; Right by s, half to even.  Do it as "right by s-1, remembering whether
    ; anything was lost", after which the bit falling off next IS the guard
    ; bit and everything lost so far is the sticky.
    cmp r8, 127
    jg .frn_slow                    ; nothing survives; the slow path has the
                                    ; underflow rules and the round-up-to-
                                    ; 10**-n case with them
    xor r11d, r11d                  ; sticky
    sub r8, 1                       ; t = s - 1
    cmp r8, 64
    jb .frn_fp_t_low
    test rax, rax
    setnz r11b
    mov rax, rdx
    xor edx, edx
    sub r8, 64                      ; t < 64 now: s <= 127 means t <= 62 here
.frn_fp_t_low:
    test r8, r8
    jz .frn_fp_guard
    mov rcx, r8
    mov r10d, 1
    shl r10, cl
    sub r10, 1                      ; the low t bits
    test r10, rax
    jz .frn_fp_no_lost
    mov r11b, 1
.frn_fp_no_lost:
    shrd rax, rdx, cl
    shr rdx, cl
.frn_fp_guard:
    ; the guard bit is now bit 0
    mov r10, rax
    and r10, 1
    shrd rax, rdx, 1
    shr rdx, 1
    test r10, r10
    jz .frn_fp_have_n               ; below half: down
    test r11b, r11b
    jnz .frn_fp_round_up            ; above half
    test al, 1
    jz .frn_fp_have_n               ; an exact tie, and N is already even
.frn_fp_round_up:
    add rax, 1
    adc rdx, 0
    jmp .frn_fp_have_n

.frn_fp_left:
    ; s <= 0: N = u << -s exactly, and it has to stay inside 53 bits, so
    ; anything in the high word already disqualifies it and so does a value
    ; the shift would carry past bit 52.
    test rdx, rdx
    jnz .frn_slow
    neg r8                          ; the left shift, >= 0
    cmp r8, 53
    jge .frn_slow
    mov ecx, 53
    sub rcx, r8
    mov r10d, 1
    shl r10, cl                     ; 1 << (53 - shift): the room there is
    cmp rax, r10
    jae .frn_slow
    mov rcx, r8
    shl rax, cl
    xor edx, edx

.frn_fp_have_n:
    test rdx, rdx
    jnz .frn_slow                   ; 2**64 and up: far outside 53 bits
    mov r10d, 1
    shl r10, 53
    cmp rax, r10
    jae .frn_slow

    ; N / 10**n, one correctly-rounded division of two exact operands.
    cvtsi2sd xmm0, rax
    lea r10, [rel frn_pow10]
    divsd xmm0, [r10 + rsi*8]
    jmp .frn_apply_sign             ; and x's sign back on top

.frn_slow:
    ; The decimal exponent, read out of a "%.17e" rendering.  It has to be 17
    ; and not 1: a short precision ROUNDS, and 9.995 at one digit is
    ; "1.0e+01", an exponent one too high -- which made round(9.995, 1)
    ; answer 9.99 where CPython says 10.0, and round(99.5, -3) answer 1000.0
    ; where CPython says 0.0.  Seventeen digits is enough that no double can
    ; round up across a decade: one that close to a power of ten IS that
    ; power of ten.
    lea rdi, [rbp - FRN_BUF]
    mov esi, 40
    lea rdx, [rel fmt_e]
    mov ecx, 17
    movsd xmm0, [rbp - FRN_X]
    mov eax, 1
    call snprintf wrt ..plt

    lea rsi, [rbp - FRN_BUF]
    call float_parse_exp10       ; -> eax = the decimal exponent
    add eax, [rbp - FRN_ND]
    inc eax                      ; eax = k, the significant digits to keep

    cmp eax, 17
    jge .frn_identity            ; finer than a double: x is its own answer
    test eax, eax
    jle .frn_underflow           ; at or left of the leading digit

    ; k significant digits is "%.*e" with k-1 after the point.  glibc rounds
    ; half-even on the exact value, which is what dtoa mode 3 does.
    dec eax
    mov r8d, eax
    lea rdi, [rbp - FRN_BUF]
    mov esi, 40
    lea rdx, [rel fmt_e]
    mov ecx, r8d
    movsd xmm0, [rbp - FRN_X]
    mov eax, 1
    call snprintf wrt ..plt

    lea rdi, [rbp - FRN_BUF]
    xor esi, esi
    call strtod wrt ..plt
    ; A finite x whose rounded value is not finite: round(DBL_MAX, -308) is
    ; 2e308.  CPython raises rather than answering an infinity it was not
    ; given.
    movsd xmm1, [rel pos_inf]
    andpd xmm1, [rel frn_absmask]
    movapd xmm2, xmm0
    andpd xmm2, [rel frn_absmask]
    ucomisd xmm2, xmm1
    je .frn_overflow
    leave
    ret

.frn_overflow:
    RAISE exc_OverflowError_type, "rounded value too large to represent"

.frn_underflow:
    ; k <= 0.  Everything rounds to a signed zero except the one case where
    ; the leading digit is 5 or more AND k is exactly 0: then the value is at
    ; least half of 10**-ndigits and rounds up to it.  A leading 5 with
    ; nothing behind it is a tie, and half-even sends a tie to the even side,
    ; which here is the zero.
    test eax, eax
    jnz .frn_zero
    lea rdi, [rbp - FRN_BUF]
    mov esi, 40
    lea rdx, [rel fmt_e]
    mov ecx, 17
    movsd xmm0, [rbp - FRN_X]
    mov eax, 1
    call snprintf wrt ..plt

    lea rsi, [rbp - FRN_BUF]
    xor ecx, ecx
    movzx eax, byte [rsi]
    cmp al, '-'
    jne .frn_uf_lead
    inc rsi
.frn_uf_lead:
    movzx eax, byte [rsi]        ; the leading digit
    cmp al, '5'
    jl .frn_zero
    jg .frn_round_up
    ; Exactly 5 so far: a tie only if every digit behind it is a zero.
    add rsi, 2                   ; skip "5."
.frn_uf_scan:
    movzx eax, byte [rsi]
    cmp al, 'e'
    je .frn_zero                 ; ran out of digits: a true tie
    test al, al
    jz .frn_zero
    cmp al, '0'
    jne .frn_round_up
    inc rsi
    jmp .frn_uf_scan

.frn_round_up:
    ; The answer is 10**-ndigits with x's sign.  Build it through strtod so
    ; the exponent is exact for every reachable ndigits.
    lea rdi, [rbp - FRN_BUF]
    mov esi, 40
    lea rdx, [rel fmt_pow10]
    mov ecx, [rbp - FRN_ND]
    neg ecx
    xor eax, eax
    call snprintf wrt ..plt
    lea rdi, [rbp - FRN_BUF]
    xor esi, esi
    call strtod wrt ..plt
    jmp .frn_apply_sign

.frn_zero:
    xorpd xmm0, xmm0
.frn_apply_sign:
    ; copysign(result, x)
    movsd xmm1, [rbp - FRN_X]
    movsd xmm2, [rel fh_sign_mask]
    andpd xmm1, xmm2
    andnpd xmm2, xmm0
    orpd xmm2, xmm1
    movapd xmm0, xmm2
    leave
    ret

.frn_identity:
    movsd xmm0, [rbp - FRN_X]
    leave
    ret
END_FUNC float_round_ndigits

;; ============================================================================
;; float_parse_exp10(rsi = "d.dde[+-]ddd") -> eax = the signed exponent
;;
;; The exponent field of a %e rendering.  Its own function because both arms
;; of float_round_ndigits want it and neither can spare the registers.
;; ============================================================================
DEF_FUNC_LOCAL float_parse_exp10
    xor ecx, ecx
.fpe_find:
    movzx eax, byte [rsi + rcx]
    test al, al
    jz .fpe_none
    cmp al, 'e'
    je .fpe_found
    inc rcx
    jmp .fpe_find
.fpe_found:
    inc rcx
    xor r8d, r8d                ; negative?
    movzx eax, byte [rsi + rcx]
    cmp al, '-'
    jne .fpe_check_plus
    mov r8d, 1
    inc rcx
    jmp .fpe_digits
.fpe_check_plus:
    cmp al, '+'
    jne .fpe_digits
    inc rcx
.fpe_digits:
    xor eax, eax
.fpe_loop:
    movzx edx, byte [rsi + rcx]
    test dl, dl
    jz .fpe_end
    sub edx, '0'
    cmp edx, 9
    ja .fpe_end
    imul eax, eax, 10
    add eax, edx
    inc rcx
    jmp .fpe_loop
.fpe_end:
    test r8d, r8d
    jz .fpe_out
    neg eax
.fpe_out:
    leave
    ret
.fpe_none:
    xor eax, eax
    leave
    ret
END_FUNC float_parse_exp10

;; ============================================================================
;; float_int(rdi = self Value) -> SmallInt or GMP int
;; Convert float to int by truncation.
;;
;; A Value, as every other nb_ slot takes: an immediate, or a subclass
;; instance whose double sits inline at the base's offset.  It used to take
;; raw double bits, which every caller had to know and which made it the one
;; slot a generic thunk could not call.
;; ============================================================================
DEF_FUNC float_int
    V_TEST_PTR rdi, rax
    ja .fi_immediate
    mov rdi, [rdi + PyFloatObject.value]
    jmp .fi_have_bits
.fi_immediate:
    V_TO_F64 rdi
.fi_have_bits:
    movq xmm0, rdi

    ; Check for NaN/inf.  CPython words and TYPES these differently: a NaN is
    ; a ValueError, an infinity an OverflowError.  Both were the ValueError.
    ucomisd xmm0, xmm0
    jp .not_a_number

    movsd xmm1, [rel pos_inf]
    ucomisd xmm0, xmm1
    je .is_infinite
    movsd xmm1, [rel neg_inf]
    ucomisd xmm0, xmm1
    je .is_infinite

    ; Out of int64's range, cvttsd2si answers INT64_MIN and says nothing about
    ; it -- int(1e300) and int(2.0**70) were both -9223372036854775808.  A
    ; double is exactly representable as an integer whenever it has no
    ; fractional part, so the big ones go through GMP, which converts it
    ; exactly.
    movsd xmm1, [rel fi_two63]
    ucomisd xmm0, xmm1
    jae .fi_big
    movsd xmm1, [rel fi_neg_two63]
    ucomisd xmm0, xmm1
    jb .fi_big

    ; Truncate to int64
    cvttsd2si rdi, xmm0
    call int_from_i64
    leave
    V_PACK rax, rdx             ; one Value out, as the slot's callers expect
    ret

.fi_big:
    push rbx
    sub rsp, 24
    movsd [rsp], xmm0
    ; int_new_compact, not int_from_i64: the latter answers an IMMEDIATE for a
    ; small value, and there is no mpz on an immediate to set.
    xor edi, edi
    extern int_new_compact
    call int_new_compact        ; a compact zero, promoted below
    mov rbx, rax
    INT_NEED_MPZ rbx            ; initialises the mpz and clears compact
    lea rdi, [rbx + PyIntObject.mpz]
    movsd xmm0, [rsp]
    extern __gmpz_set_d
    call __gmpz_set_d wrt ..plt
    mov rax, rbx
    mov edx, TAG_PTR
    add rsp, 24
    pop rbx
    leave
    V_PACK rax, rdx             ; a pointer is its own Value; symmetry with above
    ret

.not_a_number:
    RAISE exc_ValueError_type, "cannot convert float NaN to integer"
.is_infinite:
    extern exc_OverflowError_type
    RAISE exc_OverflowError_type, "cannot convert float infinity to integer"
END_FUNC float_int

;; ============================================================================
;; float_compare(PyObject *a, PyObject *b, int op) -> PyObject*
;; op: PY_LT=0, PY_LE=1, PY_EQ=2, PY_NE=3, PY_GT=4, PY_GE=5
;; Handles mixed int/float comparisons.
;; ============================================================================
FC_LEFT  equ 8              ; left operand, as a double
FC_RIGHT equ 16             ; right operand, as a double
FC_OP    equ 24             ; the comparison opcode (4 bytes)
FC_RTAG  equ 28             ; right operand's tag (4 bytes)
FC_LTAG  equ 32             ; left operand's tag (4 bytes; 33..36 unused)
FC_RSAVE equ 40             ; the right operand across the first conversion
FC_LSAVE equ 48             ; and the left, across the two acceptance checks
FC_FRAME equ 48             ; + 0 pushes = 48
DEF_FUNC float_compare, FC_FRAME
    V_UNPACK rdi, rcx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, r8            ; right Value -> (payload, tag)
    ; rdi=left, rsi=right, edx=op, ecx=left_tag, r8d=right_tag
    ;
    ; Both operands must be numeric.  The whitelist lives in
    ; float_binop_accepts, which the arithmetic slots share; comparison used to
    ; carry its own two copies of it.
    ; Everything the code below still needs goes to the frame first: the calls
    ; clobber every caller-saved register, and ecx (the left tag) and r8d (the
    ; right tag) are both read again after this block.
    mov [rbp - FC_OP], edx
    mov [rbp - FC_LSAVE], rdi
    mov [rbp - FC_RSAVE], rsi
    mov [rbp - FC_LTAG], ecx
    mov [rbp - FC_RTAG], r8d
    mov esi, ecx                    ; esi = left_tag
    call float_binop_accepts
    test eax, eax
    jz .fc_not_impl
    mov rdi, [rbp - FC_RSAVE]
    mov esi, [rbp - FC_RTAG]
    call float_binop_accepts
    test eax, eax
    jz .fc_not_impl
    mov rdi, [rbp - FC_LSAVE]
    mov rsi, [rbp - FC_RSAVE]
    mov edx, [rbp - FC_OP]
    mov ecx, [rbp - FC_LTAG]
    mov r8d, [rbp - FC_RTAG]
.fc_right_ok:
    ; An int too large for a double to hold exactly cannot be compared through
    ; one: the conversion rounds, and `10**30 == 1e30` would answer True where
    ; CPython compares the two exactly and says False.  float_to_f64 rounds to
    ; nearest now rather than truncating, which makes that visible; before, the
    ; truncation happened to fall the other way.
    mov rdi, [rbp - FC_LSAVE]
    mov esi, [rbp - FC_LTAG]
    call fc_wide_int
    test eax, eax
    jnz .fc_exact_left
    mov rdi, [rbp - FC_RSAVE]
    mov esi, [rbp - FC_RTAG]
    call fc_wide_int
    test eax, eax
    jnz .fc_exact_right
    mov rdi, [rbp - FC_LSAVE]
    mov rsi, [rbp - FC_RSAVE]
    mov ecx, [rbp - FC_LTAG]
    mov r8d, [rbp - FC_RTAG]
    jmp .fc_by_double

.fc_exact_left:
    ; The wide int is on the left; the other side becomes the double.
    mov rdi, [rbp - FC_RSAVE]
    mov esi, [rbp - FC_RTAG]
    call float_to_f64
    ; A NaN is unordered against everything, this int included.  The double
    ; path below reaches that conclusion from ucomisd's parity flag; this one
    ; has to ask, because fc_int_vs_double compares in GMP and __gmpz_set_d is
    ; undefined for a NaN.  Its +-inf shortcuts do not catch one either: a NaN
    ; is unordered against both infinities, so neither `je` fires.
    ucomisd xmm0, xmm0
    jp .unordered
    mov rdi, [rbp - FC_LSAVE]
    mov esi, [rbp - FC_LTAG]
    call fc_int_vs_double
    mov r8d, eax
    jmp .float_cmp_dispatch

.fc_exact_right:
    mov rdi, [rbp - FC_LSAVE]
    mov esi, [rbp - FC_LTAG]
    call float_to_f64
    ucomisd xmm0, xmm0
    jp .unordered
    mov rdi, [rbp - FC_RSAVE]
    mov esi, [rbp - FC_RTAG]
    call fc_int_vs_double
    neg eax                     ; the comparison was made the other way round
    mov r8d, eax
    jmp .float_cmp_dispatch

.fc_by_double:
    ; Convert both to doubles
    mov [rbp - FC_RSAVE], rsi          ; save right (8 bytes)
    mov dword [rbp - FC_RTAG], r8d    ; save right_tag (4 bytes, no overlap)
    mov esi, ecx               ; left_tag for float_to_f64
    call float_to_f64          ; left → xmm0
    movsd [rbp - FC_LEFT], xmm0
    mov rdi, [rbp - FC_RSAVE]
    mov esi, dword [rbp - FC_RTAG]    ; right_tag
    call float_to_f64          ; right → xmm0
    movsd [rbp - FC_RIGHT], xmm0

    ; Compare
    movsd xmm0, [rbp - FC_LEFT]
    ucomisd xmm0, [rbp - FC_RIGHT]

    ; Handle NaN: unordered (PF set) → everything False except NE
    jp .unordered

    ; Save ucomisd result as three-way (-1=below, 0=equal, 1=above)
    ; Must do this BEFORE cmp instructions overwrite flags
    mov r8d, 0                          ; lint: flags -- xor would clobber the compare
    je .float_cmp_dispatch
    mov r8d, -1
    jb .float_cmp_dispatch
    mov r8d, 1

.float_cmp_dispatch:
    mov ecx, [rbp - FC_OP]          ; op
    cmp ecx, PY_LT
    je .do_lt
    cmp ecx, PY_LE
    je .do_le
    cmp ecx, PY_EQ
    je .do_eq
    cmp ecx, PY_NE
    je .do_ne
    cmp ecx, PY_GT
    je .do_gt
    ; PY_GE
    test r8d, r8d
    jge .ret_true
    jmp .ret_false

.do_lt:
    test r8d, r8d
    js .ret_true
    jmp .ret_false
.do_le:
    test r8d, r8d
    jle .ret_true
    jmp .ret_false
.do_eq:
    test r8d, r8d
    jz .ret_true
    jmp .ret_false
.do_ne:
    test r8d, r8d
    jnz .ret_true
    jmp .ret_false
.do_gt:
    test r8d, r8d
    jg .ret_true
    jmp .ret_false

.unordered:
    ; NaN comparisons: only NE returns True
    cmp dword [rbp - FC_OP], PY_NE
    je .ret_true
    jmp .ret_false

.fc_not_impl:
    ; Operand is not numeric — return NULL (NotImplemented)
    RET_NULL
    leave
    ret

.ret_true:
    RET_TRUE
    leave
    ret
.ret_false:
    RET_FALSE
    leave
    ret
END_FUNC float_compare

;; ============================================================================
;; fc_wide_int(rdi = payload, esi = tag) -> eax = 1 when this is an integer a
;; double cannot hold exactly, so the comparison has to be made in GMP.
;; ============================================================================
DEF_FUNC_LOCAL fc_wide_int
    cmp esi, TAG_PTR
    jne .fcw_no                 ; an immediate int is inside +-2^50
    test rdi, rdi
    jz .fcw_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .fcw_int
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_INT_SUBCLASS
    jz .fcw_no
    ; An int subclass WRAPS an int rather than being one -- buildclass gives
    ; it a PyInstanceObject layout -- so .compact is past the end of the
    ; object.  Reading it there was an out-of-bounds read AND a wrong answer:
    ; whatever byte followed decided whether the comparison went through GMP,
    ; so `I(2**60 + 1) == float(I(2**60 + 1))` came out True where the float
    ; has rounded and CPython says False.
    extern int_unwrap
    mov edx, esi
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .fcw_flat                ; NOT necessarily inside +-2^50 -- see below
    test rdi, rdi
    jz .fcw_no
.fcw_int:
    cmp qword [rdi + PyIntObject.compact], 0
    je .fcw_yes                 ; GMP-backed: always wider than a double
    mov rax, [rdi + PyIntObject.ival]
    jmp .fcw_magnitude

.fcw_flat:
    ; int_unwrap hands back TAG_SMALLINT for a COMPACT HEAP INT as well as for
    ; a true immediate, and a compact heap int covers the whole int64 range --
    ; not just +-2^50.  Treating that tag as "small enough for a double to be
    ; exact" answered `I(2**60 + 1) == float(...)` with True inside list.sort,
    ; which calls float_compare directly, while the ordinary comparison path
    ; got it right.  It only showed once 2**60 started arriving compact rather
    ; than GMP-backed; the magnitude has to be checked either way.
    mov rax, rdi

.fcw_magnitude:
    mov rcx, rax
    sar rcx, 63
    xor rax, rcx
    sub rax, rcx                ; |ival|
    mov rcx, 1 << 53
    cmp rax, rcx
    jae .fcw_yes
.fcw_no:
    xor eax, eax
    leave
    ret
.fcw_yes:
    mov eax, 1
    leave
    ret
END_FUNC fc_wide_int

;; ============================================================================
;; fc_int_vs_double(rdi = the int's payload, esi = its tag, xmm0 = the double)
;;   -> eax = -1, 0 or 1 for int < d, int == d, int > d
;;
;; Exactly, in GMP: the double's integer part is set into an mpz -- mpz_set_d
;; truncates toward zero, which is what is wanted -- and the fraction breaks
;; a tie.  A NaN or an infinity never reaches here; float_compare's ucomisd
;; arm handles those.
;;
;; The int arrives as a Value pair and is unwrapped HERE.  An int subclass
;; wraps an int rather than being one, so it has no mpz of its own; and a
;; compact heap int flattens to an immediate, which has no fields at all --
;; unwrapping in the caller and passing the result on as a pointer was a
;; dereference of the number itself.
;; ============================================================================
FIV_D     equ 8
FIV_TAG   equ 16
FIV_TMP   equ 48            ; an mpz_t
FIV_INT   equ 80            ; a second, for an immediate that has no mpz
FIV_HAVE  equ 88            ; ...and whether it was initialised
FIV_FRAME equ 96            ; + 1 push = 104... one more word to land right
DEF_FUNC_LOCAL fc_int_vs_double, 104
    push rbx
    movsd [rbp - FIV_D], xmm0
    mov edx, esi
    call int_unwrap
    mov [rbp - FIV_TAG], rdx
    mov rbx, rdi
    mov qword [rbp - FIV_HAVE], 0
    movsd xmm0, [rbp - FIV_D]

    ; An infinity compares by sign alone.  A NaN cannot get here: both
    ; callers test the double for one first, because GMP has no answer for it.
    movsd xmm1, [rel pos_inf]
    ucomisd xmm0, xmm1
    je .fiv_minus                ; every finite int is below +inf
    movsd xmm1, [rel neg_inf]
    ucomisd xmm0, xmm1
    je .fiv_plus

    lea rdi, [rbp - FIV_TMP]
    extern __gmpz_init
    call __gmpz_init wrt ..plt
    lea rdi, [rbp - FIV_TMP]
    movsd xmm0, [rbp - FIV_D]
    extern __gmpz_set_d
    call __gmpz_set_d wrt ..plt  ; truncates toward zero

    cmp dword [rbp - FIV_TAG], TAG_SMALLINT
    je .fiv_int_immediate
    INT_NEED_MPZ rbx
    lea rdi, [rbx + PyIntObject.mpz]
    jmp .fiv_have_int
.fiv_int_immediate:
    mov qword [rbp - FIV_HAVE], 1
    lea rdi, [rbp - FIV_INT]
    call __gmpz_init wrt ..plt
    lea rdi, [rbp - FIV_INT]
    mov rsi, rbx
    extern __gmpz_set_si
    call __gmpz_set_si wrt ..plt
    lea rdi, [rbp - FIV_INT]
.fiv_have_int:
    lea rsi, [rbp - FIV_TMP]
    extern __gmpz_cmp
    call __gmpz_cmp wrt ..plt
    mov r8d, eax
    push r8
    lea rdi, [rbp - FIV_TMP]
    extern __gmpz_clear
    call __gmpz_clear wrt ..plt
    cmp qword [rbp - FIV_HAVE], 0
    je .fiv_no_int_mpz
    lea rdi, [rbp - FIV_INT]
    call __gmpz_clear wrt ..plt
.fiv_no_int_mpz:
    pop r8
    test r8d, r8d
    jl .fiv_minus
    jg .fiv_plus

    ; Equal against the truncated part: the fraction decides.
    movsd xmm0, [rbp - FIV_D]
    roundsd xmm1, xmm0, 3        ; 3 = truncate toward zero
    ucomisd xmm0, xmm1
    je .fiv_zero
    ja .fiv_minus                ; d has a positive fraction: the int is below
    jmp .fiv_plus

.fiv_minus:
    mov eax, -1
    pop rbx
    leave
    ret
.fiv_plus:
    mov eax, 1
    pop rbx
    leave
    ret
.fiv_zero:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC fc_int_vs_double

;; ============================================================================
;; float_getattr(rdi = self Value, rsi = name str) -> rax = Value, or NULL
;;
;; real and imag, the two numbers.py asks for.  float has no numerator or
;; denominator -- CPython raises for those -- so the chain is shorter than
;; int's.  See int_getattr for why this is a strcmp chain and not a
;; descriptor.
;; ============================================================================
FG_SELF   equ 8
FG_NAME   equ 16
FG_FRAME  equ 16            ; + 0 pushes = 16

extern ap_strcmp
DEF_FUNC float_getattr, FG_FRAME
    mov [rbp - FG_SELF], rdi
    mov [rbp - FG_NAME], rsi

    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "real"
    call ap_strcmp
    test eax, eax
    jz .fg_real

    mov rdi, [rbp - FG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "imag"
    call ap_strcmp
    test eax, eax
    jz .fg_imag

    RET_NULL
    leave
    V_PACK rax, rdx
    ret

.fg_real:
    mov rdi, [rbp - FG_SELF]
    call float_get_real
    leave
    ret

.fg_imag:
    mov rdi, [rbp - FG_SELF]
    call float_get_imag
    leave
    ret
END_FUNC float_getattr

;; ============================================================================
;; float_get_real(rdi = self Value) -> rax = Value
;;
;; Behind float.real, reached from the chain above and from the getset
;; descriptor in float_type.tp_dict.  A subclass instance answers with a
;; plain float, as CPython does.
;; ============================================================================
DEF_FUNC float_get_real
    mov rax, rdi
    V_TEST_PTR rax, rcx
    ja .fgr_out                 ; already a float immediate
    mov rax, [rax + PyFloatObject.value]
    V_FROM_F64 rax, rcx
.fgr_out:
    mov edx, TAG_FLOAT
    leave
    ret
END_FUNC float_get_real

;; ============================================================================
;; float_get_imag(rdi = self Value) -> rax = Value.  Always 0.0.
;; ============================================================================
DEF_FUNC float_get_imag
    xorpd xmm0, xmm0
    movq rax, xmm0
    V_FROM_F64 rax, rcx
    mov edx, TAG_FLOAT
    leave
    ret
END_FUNC float_get_imag


;; ============================================================================
;; Data
;; ============================================================================
section .data

float_name_str: db "float", 0
str_zero: db "0.0", 0
str_neg_zero: db "-0.0", 0
str_nan: db "nan", 0
str_inf: db "inf", 0
str_neg_inf: db "-inf", 0
fmt_g: db "%.*g", 0
fmt_f: db "%.*f", 0
fmt_e: db "%.*e", 0
; The `#` forms.  CPython's alternate flag on a float means "keep the decimal
; point", and for g "keep the trailing zeros as well" -- which is exactly what
; C's own # does, so the conversion carries it rather than this patching the
; result afterwards.
fmt_alt_g: db "%#.*g", 0
fmt_alt_f: db "%#.*f", 0
fmt_alt_e: db "%#.*e", 0
fmt_alt_E: db "%#.*E", 0
fmt_alt_F: db "%#.*F", 0
fmt_alt_G: db "%#.*G", 0
fmt_pow10: db "1e%d", 0
fmt_E: db "%.*E", 0
fmt_F: db "%.*F", 0
fmt_G: db "%.*G", 0

align 8
fi_two63:     dq 0x43e0000000000000   ; 2.0**63
fi_neg_two63: dq 0xc3e0000000000000   ; -(2.0**63)
pos_inf:     dq 0x7ff0000000000000
neg_inf:     dq 0xfff0000000000000
const_one_f:  dq 0x3ff0000000000000   ; 1.0 in IEEE 754
const_half_f: dq 0x3fe0000000000000   ; 0.5
const_two_f:  dq 0x4000000000000000   ; 2.0

align 8
global float_number_methods
float_number_methods:
    dq float_add              ; nb_add          +0
    dq float_sub              ; nb_subtract     +8
    dq float_mul              ; nb_multiply     +16
    dq float_mod              ; nb_remainder    +24
    dq 0                      ; nb_divmod       +32
    dq float_pow              ; nb_power        +40
    dq float_neg              ; nb_negative     +48
    dq float_pos              ; nb_positive     +56
    dq float_abs              ; nb_absolute     +64
    dq float_bool             ; nb_bool         +72
    dq 0                      ; nb_invert       +80
    dq 0                      ; nb_lshift       +88
    dq 0                      ; nb_rshift       +96
    dq 0                      ; nb_and          +104
    dq 0                      ; nb_xor          +112
    dq 0                      ; nb_or           +120
    dq float_int              ; nb_int          +128
    dq float_get_real       ; nb_float        +136 (a float is its own float)
    dq float_floordiv         ; nb_floor_divide +144
    dq float_truediv          ; nb_true_divide  +152
    dq 0                      ; nb_index        +160
    dq 0                        ; nb_iadd         +168
    dq 0                        ; nb_isub         +176
    dq 0                        ; nb_imul         +184
    dq 0                        ; nb_irem         +192
    dq 0                        ; nb_ipow         +200
    dq 0                        ; nb_ilshift      +208
    dq 0                        ; nb_irshift      +216
    dq 0                        ; nb_iand         +224
    dq 0                        ; nb_ixor         +232
    dq 0                        ; nb_ior          +240
    dq 0                        ; nb_ifloor_divide +248
    dq 0                        ; nb_itrue_divide +256
    dq 0 ; nb_matmul
    dq 0 ; nb_imatmul

align 8
extern type_type

global float_type
float_type:
    dq 1                      ; ob_refcnt (immortal)
    dq type_type              ; ob_type
    dq float_name_str         ; tp_name
    dq PyFloatObject_size     ; tp_basicsize
    dq 0                      ; tp_dealloc (inline floats, no heap alloc)
    dq float_repr             ; tp_repr
    dq float_repr             ; tp_str (same as repr for float)
    dq float_hash             ; tp_hash
    dq 0                      ; tp_call
    dq float_getattr          ; tp_getattr (.real / .imag)
    dq 0                      ; tp_setattr
    dq float_compare          ; tp_richcompare
    dq 0                      ; tp_iter
    dq 0                      ; tp_iternext
    dq 0                      ; tp_init
    dq 0                      ; tp_new
    dq float_number_methods   ; tp_as_number
    dq 0                      ; tp_as_sequence
    dq 0                      ; tp_as_mapping
    dq 0                      ; tp_base
    dq 0                      ; tp_dict
    dq 0                      ; tp_mro
    dq TYPE_FLAG_FLOAT_SUBCLASS ; tp_flags -- the family bit type_from_parts
                                ; hands down, so a subclass is recognisable
    dq 0                      ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
