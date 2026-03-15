; int_obj.asm - Integer type (fat value TAG_SMALLINT + GMP arbitrary precision)
;
; Fat value TAG_SMALLINT: tag=1, payload=raw signed i64, full 64-bit range
; No heap allocation or refcounting needed for inline integers.
;
; PyIntObject layout (GMP-backed, heap-allocated):
;   +0  ob_refcnt (8 bytes)
;   +8  ob_type   (8 bytes)
;   +16 mpz       (16 bytes: _mp_alloc:4, _mp_size:4, _mp_d:8)
;   Total: PyIntObject_size = 32

%include "macros.inc"
%include "object.inc"
%include "types.inc"

extern ap_malloc
extern ap_free
extern str_from_cstr
extern str_from_cstr_heap
extern bool_true
extern bool_false
extern none_singleton
extern bool_from_int
extern type_type

; GMP functions
extern __gmpz_init
extern __gmpz_clear
extern __gmpz_set_si
extern __gmpz_set
extern __gmpz_get_si
extern __gmpz_get_str
extern __gmpz_add
extern __gmpz_sub
extern __gmpz_mul
extern __gmpz_tdiv_q
extern __gmpz_tdiv_r
extern __gmpz_fdiv_q
extern __gmpz_fdiv_r
extern __gmpz_neg
extern __gmpz_cmp
extern __gmpz_cmp_si
extern __gmpz_sizeinbase
extern __gmpz_set_str
extern __gmpz_and
extern __gmpz_ior
extern __gmpz_xor
extern __gmpz_com
extern __gmpz_mul_2exp
extern __gmpz_fdiv_q_2exp
extern __gmpz_pow_ui
extern __gmpz_get_d

extern raise_exception
extern strlen
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_ZeroDivisionError_type
extern float_from_f64

;; ============================================================================
;; int_new_from_mpz - internal: alloc int obj, init mpz, copy source
;; Input:  rdi = ptr to source mpz_t
;; Output: rax = new PyIntObject*
;; ============================================================================
DEF_FUNC_LOCAL int_new_from_mpz
    push rbx
    push r12
    mov rbx, rdi
    mov edi, PyIntObject_size
    call ap_malloc
    mov r12, rax
    mov qword [r12 + PyObject.ob_refcnt], 1
    lea rax, [rel int_type]
    mov [r12 + PyObject.ob_type], rax
    lea rdi, [r12 + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    lea rdi, [r12 + PyIntObject.mpz]
    mov rsi, rbx
    call __gmpz_set wrt ..plt
    mov rax, r12
    pop r12
    pop rbx
    leave
    ret
END_FUNC int_new_from_mpz

;; ============================================================================

;; ============================================================================
;; int_from_i64(int64_t val) -> (rax=payload, edx=TAG_SMALLINT)
;; All i64 values are SmallInt (payload = raw signed 64-bit).
;; ============================================================================
DEF_FUNC_BARE int_from_i64
    mov rax, rdi
    RET_TAG_SMALLINT
    ret
END_FUNC int_from_i64

;; ============================================================================
;; int_from_i64_gmp(int64_t val) -> PyIntObject*
;; Always creates a GMP-backed integer (no SmallInt)
;; ============================================================================
DEF_FUNC int_from_i64_gmp
    push rbx
    push r12
    mov rbx, rdi
    mov edi, PyIntObject_size
    call ap_malloc
    mov r12, rax
    mov qword [r12 + PyObject.ob_refcnt], 1
    lea rax, [rel int_type]
    mov [r12 + PyObject.ob_type], rax
    lea rdi, [r12 + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    lea rdi, [r12 + PyIntObject.mpz]
    mov rsi, rbx
    call __gmpz_set_si wrt ..plt
    mov rax, r12
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC int_from_i64_gmp

;; ============================================================================
;; smallint_to_pyint(SmallInt val) -> PyIntObject*
;; Decode SmallInt and create GMP-backed int
;; ============================================================================
DEF_FUNC_BARE smallint_to_pyint
    jmp int_from_i64_gmp
END_FUNC smallint_to_pyint

;; ============================================================================
;; int_from_cstr(const char *str, int base) -> PyIntObject*
;; Create integer from C string. Returns NULL on parse failure.
;; ============================================================================
DEF_FUNC int_from_cstr
    push rbx
    push r12
    push r13
    and rsp, -16           ; align for GMP calls
    mov rbx, rdi
    mov r13d, esi
    mov edi, PyIntObject_size
    call ap_malloc
    mov r12, rax
    mov qword [r12 + PyObject.ob_refcnt], 1
    lea rax, [rel int_type]
    mov [r12 + PyObject.ob_type], rax
    lea rdi, [r12 + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    lea rdi, [r12 + PyIntObject.mpz]
    mov rsi, rbx
    mov edx, r13d
    call __gmpz_set_str wrt ..plt
    test eax, eax
    jnz .parse_fail
    mov rax, r12
    lea rsp, [rbp - 24]
    pop r13
    pop r12
    pop rbx
    leave
    ret
.parse_fail:
    lea rdi, [r12 + PyIntObject.mpz]
    call __gmpz_clear wrt ..plt
    mov rdi, r12
    call ap_free
    RET_NULL
    lea rsp, [rbp - 24]
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC int_from_cstr

;; ============================================================================
;; int_from_cstr_base(char *str, int base) -> PyObject* or NULL
;; Parse integer from string with given base (0 = auto-detect, 2-36).
;; Handles leading/trailing whitespace, sign, 0b/0o/0x prefixes, underscores.
;; ============================================================================
; Frame layout for int_from_cstr_base
IB_SRC    equ 8          ; original string ptr
IB_BASE   equ 16         ; resolved base
IB_SIGN   equ 24         ; 0 = positive, 1 = negative
IB_BUF    equ 32         ; cleaned buffer ptr
IB_OBJ    equ 40         ; allocated PyIntObject ptr
IB_FRAME  equ 48

global int_from_cstr_base
DEF_FUNC int_from_cstr_base, IB_FRAME

    mov [rbp - IB_SRC], rdi
    mov [rbp - IB_BASE], rsi
    mov qword [rbp - IB_SIGN], 0

    ; Step 1: Skip leading whitespace (ASCII + Unicode)
.skip_ws:
    movzx eax, byte [rdi]
    cmp al, ' '
    je .skip_ws_1
    cmp al, 9             ; \t
    je .skip_ws_1
    cmp al, 10            ; \n
    je .skip_ws_1
    cmp al, 13            ; \r
    je .skip_ws_1
    cmp al, 12            ; \f
    je .skip_ws_1
    cmp al, 11            ; \v
    je .skip_ws_1
    ; Check for UTF-8 multi-byte Unicode whitespace
    cmp al, 0xC2
    je .skip_ws_2byte
    cmp al, 0xE2
    je .skip_ws_3byte_e2
    cmp al, 0xE3
    je .skip_ws_3byte_e3
    cmp al, 0xE1
    je .skip_ws_3byte_e1
    jmp .ws_done
.skip_ws_1:
    inc rdi
    jmp .skip_ws
.skip_ws_2byte:
    ; U+00A0 (NBSP): C2 A0
    cmp byte [rdi + 1], 0xA0
    jne .ws_done
    add rdi, 2
    jmp .skip_ws
.skip_ws_3byte_e2:
    ; U+2000-U+200A: E2 80 {80-8A}
    ; U+2028-U+2029: E2 80 {A8-A9}
    ; U+202F: E2 80 AF
    ; U+205F: E2 81 9F
    movzx ecx, byte [rdi + 1]
    cmp cl, 0x80
    je .skip_ws_e2_80
    cmp cl, 0x81
    jne .ws_done
    ; E2 81 xx: check for U+205F (E2 81 9F)
    cmp byte [rdi + 2], 0x9F
    jne .ws_done
    add rdi, 3
    jmp .skip_ws
.skip_ws_e2_80:
    movzx ecx, byte [rdi + 2]
    ; U+2000-U+200A: third byte 0x80-0x8A
    cmp cl, 0x80
    jb .ws_done
    cmp cl, 0x8A
    jbe .skip_ws_3
    ; U+2028-U+2029: third byte 0xA8-0xA9
    cmp cl, 0xA8
    je .skip_ws_3
    cmp cl, 0xA9
    je .skip_ws_3
    ; U+202F: third byte 0xAF
    cmp cl, 0xAF
    je .skip_ws_3
    jmp .ws_done
.skip_ws_3byte_e3:
    ; U+3000 (IDEOGRAPHIC SPACE): E3 80 80
    cmp byte [rdi + 1], 0x80
    jne .ws_done
    cmp byte [rdi + 2], 0x80
    jne .ws_done
    add rdi, 3
    jmp .skip_ws
.skip_ws_3byte_e1:
    ; U+1680 (OGHAM SPACE): E1 9A 80
    cmp byte [rdi + 1], 0x9A
    jne .ws_done
    cmp byte [rdi + 2], 0x80
    jne .ws_done
    add rdi, 3
    jmp .skip_ws
.skip_ws_3:
    add rdi, 3
    jmp .skip_ws
.ws_done:

    ; Step 2: Handle sign
    movzx eax, byte [rdi]
    cmp al, '+'
    je .sign_plus
    cmp al, '-'
    je .sign_minus
    jmp .sign_done
.sign_plus:
    inc rdi
    jmp .sign_done
.sign_minus:
    mov qword [rbp - IB_SIGN], 1
    inc rdi
.sign_done:
    mov [rbp - IB_SRC], rdi    ; update start past whitespace/sign

    ; Step 3: Base 0 auto-detect or prefix handling
    mov rsi, [rbp - IB_BASE]
    movzx eax, byte [rdi]
    cmp al, '0'
    jne .no_prefix

    ; Starts with '0' — check next char
    movzx ecx, byte [rdi + 1]
    or cl, 0x20            ; lowercase

    cmp cl, 'b'
    je .prefix_bin
    cmp cl, 'o'
    je .prefix_oct
    cmp cl, 'x'
    je .prefix_hex

    ; No prefix: for base 0, check for leading zero ambiguity
    test rsi, rsi
    jz .base0_check_leading_zero
    jmp .no_prefix

.prefix_bin:
    test rsi, rsi
    jz .set_base2
    cmp rsi, 2
    jne .no_prefix         ; base != 2 and != 0: don't strip prefix
.set_base2:
    mov qword [rbp - IB_BASE], 2
    add rdi, 2             ; skip "0b"
    jmp .skip_prefix_underscore

.prefix_oct:
    test rsi, rsi
    jz .set_base8
    cmp rsi, 8
    jne .no_prefix
.set_base8:
    mov qword [rbp - IB_BASE], 8
    add rdi, 2             ; skip "0o"
    jmp .skip_prefix_underscore

.prefix_hex:
    test rsi, rsi
    jz .set_base16
    cmp rsi, 16
    jne .no_prefix
.set_base16:
    mov qword [rbp - IB_BASE], 16
    add rdi, 2             ; skip "0x"
    ; Fall through to skip_prefix_underscore

.skip_prefix_underscore:
    ; Allow (but don't require) underscore after base prefix: '0b_0', '0x_f'
    cmp byte [rdi], '_'
    jne .prefix_no_us
    inc rdi
.prefix_no_us:
    mov [rbp - IB_SRC], rdi
    jmp .no_prefix

.base0_check_leading_zero:
    ; Base 0, starts with '0' but no 0b/0o/0x prefix
    ; CPython rejects '010', '0_7' etc. as ambiguous old-style octal
    ; Only '0', '00...0', '0_0_0' etc. (all zeros) are allowed
    ; Scan: accept '0' and '_' (between zeros), reject non-zero digits
    inc rdi                ; skip first '0'
    xor edx, edx          ; prev_was_underscore = false
.base0_zero_loop:
    movzx ecx, byte [rdi]
    test cl, cl
    jz .base0_check_trail  ; end of string → check trailing underscore
    cmp cl, '0'
    je .base0_zero_digit
    cmp cl, '_'
    je .base0_zero_us
    ; Check for trailing whitespace
    cmp cl, ' '
    je .base0_return_zero
    cmp cl, 9    ; \t
    je .base0_return_zero
    cmp cl, 10   ; \n
    je .base0_return_zero
    cmp cl, 13   ; \r
    je .base0_return_zero
    cmp cl, 12   ; \f
    je .base0_return_zero
    cmp cl, 11   ; \v
    je .base0_return_zero
    ; Non-zero digit or invalid char → error
    RET_NULL
    leave
    ret
.base0_zero_digit:
    xor edx, edx          ; prev_was_underscore = false
    inc rdi
    jmp .base0_zero_loop
.base0_zero_us:
    ; Reject double underscore
    test edx, edx
    jnz .base0_error
    mov edx, 1            ; prev_was_underscore = true
    inc rdi
    jmp .base0_zero_loop
.base0_error:
    RET_NULL
    leave
    ret
.base0_check_trail:
    ; Reject trailing underscore
    test edx, edx
    jnz .base0_error
    jmp .base0_return_zero
.base0_return_zero:
    ; Free nothing (no buffer allocated yet), return SmallInt 0
    xor eax, eax
    RET_TAG_SMALLINT
    leave
    ret

.no_prefix:
    ; If base was 0 and no prefix matched, default to 10
    mov rsi, [rbp - IB_BASE]
    test rsi, rsi
    jnz .base_resolved
    mov qword [rbp - IB_BASE], 10
.base_resolved:

    ; Step 4: Allocate buffer for cleaned string (strip underscores + trailing ws)
    ; First calculate length
    mov rdi, [rbp - IB_SRC]
    call strlen wrt ..plt
    inc rax                ; +1 for null terminator
    mov rdi, rax
    call ap_malloc
    mov [rbp - IB_BUF], rax

    ; Step 5: Copy digits, stripping underscores and trailing whitespace
    mov rsi, [rbp - IB_SRC]   ; source
    mov rdi, rax               ; dest buffer
    xor ecx, ecx              ; dest index
    xor edx, edx              ; prev_was_underscore flag
    movzx r8d, byte [rsi]
    test r8b, r8b
    jz .copy_empty

.copy_loop:
    movzx r8d, byte [rsi]
    test r8b, r8b
    jz .copy_done

    ; Check for whitespace (trailing) — ASCII
    cmp r8b, ' '
    je .copy_trail_ws
    cmp r8b, 9
    je .copy_trail_ws
    cmp r8b, 10
    je .copy_trail_ws
    cmp r8b, 13
    je .copy_trail_ws
    cmp r8b, 12
    je .copy_trail_ws
    cmp r8b, 11
    je .copy_trail_ws
    ; Check for UTF-8 Unicode whitespace
    cmp r8b, 0xC2
    je .copy_trail_utf8_c2
    cmp r8b, 0xE2
    je .copy_trail_utf8_e2
    cmp r8b, 0xE3
    je .copy_trail_utf8_e3
    cmp r8b, 0xE1
    je .copy_trail_utf8_e1

    ; Check for underscore
    cmp r8b, '_'
    je .copy_underscore

    ; Check for Unicode digit (multi-byte UTF-8)
    cmp r8b, 0xD9
    je .copy_digit_arabic
    cmp r8b, 0xE0
    je .copy_digit_3byte

    ; Regular digit: copy it
    mov [rdi + rcx], r8b
    inc rcx
    xor edx, edx          ; prev_was_underscore = false
    inc rsi
    jmp .copy_loop

.copy_digit_arabic:
    ; Arabic-Indic digits U+0660-0669: D9 A0-A9 → '0'-'9'
    movzx r9d, byte [rsi + 1]
    cmp r9b, 0xA0
    jb .copy_not_ws         ; not a digit, treat as regular byte
    cmp r9b, 0xA9
    ja .copy_not_ws
    ; Convert to ASCII: r9b - 0xA0 + '0'
    sub r9b, 0xA0
    add r9b, '0'
    mov [rdi + rcx], r9b
    inc rcx
    xor edx, edx
    add rsi, 2              ; skip 2-byte UTF-8
    jmp .copy_loop

.copy_digit_3byte:
    ; Devanagari digits U+0966-096F: E0 A5 A6-AF → '0'-'9'
    cmp byte [rsi + 1], 0xA5
    jne .copy_not_ws        ; not Devanagari, treat as regular byte
    movzx r9d, byte [rsi + 2]
    cmp r9b, 0xA6
    jb .copy_not_ws
    cmp r9b, 0xAF
    ja .copy_not_ws
    ; Convert to ASCII: r9b - 0xA6 + '0'
    sub r9b, 0xA6
    add r9b, '0'
    mov [rdi + rcx], r9b
    inc rcx
    xor edx, edx
    add rsi, 3              ; skip 3-byte UTF-8
    jmp .copy_loop

.copy_underscore:
    ; Reject leading underscore (rcx == 0)
    test ecx, ecx
    jz .parse_error
    ; Reject double underscore
    test edx, edx
    jnz .parse_error
    mov edx, 1            ; prev_was_underscore = true
    inc rsi
    jmp .copy_loop

.copy_trail_utf8_c2:
    ; U+00A0 (NBSP): C2 A0
    cmp byte [rsi + 1], 0xA0
    jne .copy_not_ws
    add rsi, 2
    jmp .trail_loop
.copy_trail_utf8_e2:
    ; Check E2 80 xx or E2 81 9F
    movzx r9d, byte [rsi + 1]
    cmp r9b, 0x80
    je .copy_trail_e2_80
    cmp r9b, 0x81
    jne .copy_not_ws
    cmp byte [rsi + 2], 0x9F
    jne .copy_not_ws
    add rsi, 3
    jmp .trail_loop
.copy_trail_e2_80:
    movzx r9d, byte [rsi + 2]
    cmp r9b, 0x80
    jb .copy_not_ws
    cmp r9b, 0x8A
    jbe .copy_trail_utf8_3
    cmp r9b, 0xA8
    je .copy_trail_utf8_3
    cmp r9b, 0xA9
    je .copy_trail_utf8_3
    cmp r9b, 0xAF
    je .copy_trail_utf8_3
    jmp .copy_not_ws
.copy_trail_utf8_e3:
    ; U+3000: E3 80 80
    cmp byte [rsi + 1], 0x80
    jne .copy_not_ws
    cmp byte [rsi + 2], 0x80
    jne .copy_not_ws
    add rsi, 3
    jmp .trail_loop
.copy_trail_utf8_e1:
    ; U+1680: E1 9A 80
    cmp byte [rsi + 1], 0x9A
    jne .copy_not_ws
    cmp byte [rsi + 2], 0x80
    jne .copy_not_ws
    add rsi, 3
    jmp .trail_loop
.copy_trail_utf8_3:
    add rsi, 3
    jmp .trail_loop
.copy_not_ws:
    ; Not whitespace — copy as regular byte
    mov [rdi + rcx], r8b
    inc rcx
    xor edx, edx
    inc rsi
    jmp .copy_loop

.copy_trail_ws:
    ; Verify remaining chars are all whitespace (ASCII + Unicode)
    inc rsi
.trail_loop:
    movzx r8d, byte [rsi]
    test r8b, r8b
    jz .copy_done
    cmp r8b, ' '
    je .trail_next
    cmp r8b, 9
    je .trail_next
    cmp r8b, 10
    je .trail_next
    cmp r8b, 13
    je .trail_next
    cmp r8b, 12
    je .trail_next
    cmp r8b, 11
    je .trail_next
    ; Check for UTF-8 Unicode whitespace in trailing
    cmp r8b, 0xC2
    je .trail_utf8_c2
    cmp r8b, 0xE2
    je .trail_utf8_e2
    cmp r8b, 0xE3
    je .trail_utf8_e3
    cmp r8b, 0xE1
    je .trail_utf8_e1
    ; Non-whitespace after whitespace: error
    jmp .parse_error
.trail_utf8_c2:
    cmp byte [rsi + 1], 0xA0
    jne .parse_error
    add rsi, 2
    jmp .trail_loop
.trail_utf8_e2:
    movzx r9d, byte [rsi + 1]
    cmp r9b, 0x80
    je .trail_e2_80
    cmp r9b, 0x81
    jne .parse_error
    cmp byte [rsi + 2], 0x9F
    jne .parse_error
    add rsi, 3
    jmp .trail_loop
.trail_e2_80:
    movzx r9d, byte [rsi + 2]
    cmp r9b, 0x80
    jb .parse_error
    cmp r9b, 0x8A
    jbe .trail_utf8_3
    cmp r9b, 0xA8
    je .trail_utf8_3
    cmp r9b, 0xA9
    je .trail_utf8_3
    cmp r9b, 0xAF
    je .trail_utf8_3
    jmp .parse_error
.trail_utf8_e3:
    cmp byte [rsi + 1], 0x80
    jne .parse_error
    cmp byte [rsi + 2], 0x80
    jne .parse_error
    add rsi, 3
    jmp .trail_loop
.trail_utf8_e1:
    cmp byte [rsi + 1], 0x9A
    jne .parse_error
    cmp byte [rsi + 2], 0x80
    jne .parse_error
    add rsi, 3
    jmp .trail_loop
.trail_utf8_3:
    add rsi, 3
    jmp .trail_loop
.trail_next:
    inc rsi
    jmp .trail_loop

.copy_done:
    ; Reject trailing underscore
    test edx, edx
    jnz .parse_error
    ; Reject empty string
    test ecx, ecx
    jz .parse_error
    mov byte [rdi + rcx], 0    ; null terminate

    ; Check int_max_str_digits limit (only for non-power-of-two bases)
    ; Power-of-two bases (2, 4, 8, 16, 32) are exempt
    mov rax, [rbp - IB_BASE]
    cmp rax, 2
    je .digits_ok
    cmp rax, 4
    je .digits_ok
    cmp rax, 8
    je .digits_ok
    cmp rax, 16
    je .digits_ok
    cmp rax, 32
    je .digits_ok
    ; Non-power-of-two base — check limit
    extern sys_int_max_str_digits
    mov rax, [rel sys_int_max_str_digits]
    test rax, rax
    jz .digits_ok              ; limit=0 means unlimited
    cmp rcx, rax
    jg .digits_exceeded
.digits_ok:
    jmp .gmp_parse

.copy_empty:
    jmp .parse_error

.gmp_parse:
    ; Allocate PyIntObject
    mov edi, PyIntObject_size
    call ap_malloc
    mov [rbp - IB_OBJ], rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt

    ; Parse with GMP
    mov rax, [rbp - IB_OBJ]
    lea rdi, [rax + PyIntObject.mpz]
    mov rsi, [rbp - IB_BUF]
    mov rdx, [rbp - IB_BASE]
    call __gmpz_set_str wrt ..plt
    test eax, eax
    jnz .gmp_parse_fail

    ; Apply sign
    cmp qword [rbp - IB_SIGN], 0
    je .no_negate
    mov rax, [rbp - IB_OBJ]
    lea rdi, [rax + PyIntObject.mpz]
    lea rsi, [rax + PyIntObject.mpz]
    call __gmpz_neg wrt ..plt
.no_negate:

    ; Free cleaned buffer
    mov rdi, [rbp - IB_BUF]
    call ap_free

    ; Try to normalize to SmallInt if small enough
    mov rax, [rbp - IB_OBJ]
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_get_si wrt ..plt
    mov rcx, rax

    ; Check if value fits in SmallInt range and roundtrips
    ; Save small int value now — rcx will be clobbered by call
    mov [rbp - IB_SIGN], rcx
    mov rdi, [rbp - IB_OBJ]
    lea rdi, [rdi + PyIntObject.mpz]
    mov rsi, rcx
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    jnz .return_gmp         ; doesn't roundtrip: keep GMP

    ; Fits in i64: free GMP object, return as SmallInt
    mov rdi, [rbp - IB_OBJ]
    lea rdi, [rdi + PyIntObject.mpz]
    call __gmpz_clear wrt ..plt
    mov rdi, [rbp - IB_OBJ]
    call ap_free
    mov rax, [rbp - IB_SIGN]
    RET_TAG_SMALLINT
    leave
    ret

.return_gmp:
    mov rax, [rbp - IB_OBJ]
    mov edx, TAG_PTR
    leave
    ret

.gmp_parse_fail:
    ; Clean up allocated object and return parse error (NULL)
    mov rdi, [rbp - IB_OBJ]
    lea rdi, [rdi + PyIntObject.mpz]
    call __gmpz_clear wrt ..plt
    mov rdi, [rbp - IB_OBJ]
    call ap_free
    jmp .parse_error

.digits_exceeded:
    ; Free cleaned buffer, then raise ValueError for digit limit
    mov rdi, [rbp - IB_BUF]
    call ap_free
    extern raise_exception
    extern exc_ValueError_type
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "Exceeds the limit for integer string conversion"
    call raise_exception

.parse_error:
    ; Free cleaned buffer if allocated
    mov rdi, [rbp - IB_BUF]
    call ap_free
    RET_NULL
    leave
    ret

END_FUNC int_from_cstr_base

;; ============================================================================
;; int_to_i64(PyObject *obj) -> int64_t
;; Extract integer value as C int64. Handles SmallInt.
;; ============================================================================
DEF_FUNC_BARE int_to_i64
    cmp edx, TAG_SMALLINT
    je .smallint
    push rbp
    mov rbp, rsp
    lea rdi, [rdi + PyIntObject.mpz]
    call __gmpz_get_si wrt ..plt
    pop rbp
    ret
.smallint:
    mov rax, rdi
    ret
END_FUNC int_to_i64

;; ============================================================================
;; int_repr(PyObject *self) -> PyStrObject*
;; String representation. SmallInt uses snprintf, GMP uses gmpz_get_str.
;; ============================================================================
DEF_FUNC_BARE int_repr
    cmp edx, TAG_SMALLINT
    je .smallint
    ; Check if int subclass (TYPE_FLAG_INT_SUBCLASS) — extract int_value
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .repr_gmp                 ; exact int_type → proceed to GMP path
    mov rax, [rax + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_INT_SUBCLASS
    jz .repr_gmp                 ; not int subclass → treat as GMP
    ; Extract int_value from PyIntSubclassObject
    mov rdi, [rdi + PyIntSubclassObject.int_value]
    cmp edx, TAG_SMALLINT
    je .smallint
.repr_gmp:
    ; GMP path
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    and rsp, -16           ; dynamically align RSP to 16 bytes
    mov rbx, rdi
    lea rdi, [rbx + PyIntObject.mpz]
    mov esi, 10
    call __gmpz_sizeinbase wrt ..plt
    ; Check int_max_str_digits limit
    mov rcx, [rel sys_int_max_str_digits]
    test rcx, rcx
    jz .repr_no_limit              ; limit=0 means unlimited
    cmp rax, rcx
    ja .repr_limit_exceeded
.repr_no_limit:
    lea rdi, [rax + 3]
    call ap_malloc
    mov r12, rax               ; r12 = C string buffer
    mov rdi, r12
    mov esi, 10
    lea rdx, [rbx + PyIntObject.mpz]
    call __gmpz_get_str wrt ..plt
    mov rdi, r12
    call str_from_cstr_heap
    mov rbx, rax               ; save str result (done with original obj)
    mov rdi, r12
    call ap_free               ; free C buffer
    mov rax, rbx               ; return str object
    mov edx, TAG_PTR
    lea rsp, [rbp - 16]   ; restore RSP to before alignment (rbp-16 = after push rbx, push r12)
    pop r12
    pop rbx
    pop rbp
    ret

.smallint:
    ; Direct SmallInt repr: manual int-to-string, no GMP allocation
    push rbp
    mov rbp, rsp
    sub rsp, 32                ; 24 bytes buffer + alignment
    mov rax, rdi

    ; Convert int64 to decimal string in stack buffer
    ; Write digits backwards from buf[23], then reverse
    lea rdi, [rbp - 32]       ; rdi = buffer start
    xor ecx, ecx              ; ecx = 0 (negative flag)
    test rax, rax
    jns .si_positive
    neg rax
    mov ecx, 1                ; mark negative
.si_positive:
    ; rax = absolute value, ecx = negative flag
    lea rsi, [rbp - 9]        ; rsi = write position (end of buffer area)
    mov byte [rsi], 0          ; null terminator
    dec rsi

    mov r8, 10
.si_digit_loop:
    xor edx, edx
    div r8                     ; rax = quotient, rdx = remainder
    add dl, '0'
    mov [rsi], dl
    dec rsi
    test rax, rax
    jnz .si_digit_loop

    ; Add minus sign if negative
    test ecx, ecx
    jz .si_no_minus
    mov byte [rsi], '-'
    dec rsi
.si_no_minus:
    ; rsi+1 points to start of string
    inc rsi
    mov rdi, rsi
    call str_from_cstr
    leave
    ret

.repr_limit_exceeded:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "Exceeds the limit for integer string conversion"
    call raise_exception
END_FUNC int_repr

;; ============================================================================
;; int_hash(PyObject *self) -> int64
;; SmallInt: decoded value. GMP: low bits via get_si. Never returns -1.
;; ============================================================================
DEF_FUNC_BARE int_hash
    ; Unwrap int subclass instances
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .smallint

    push rbp
    mov rbp, rsp
    push rbx
    mov rbx, rdi
    lea rdi, [rbx + PyIntObject.mpz]
    call __gmpz_get_si wrt ..plt
    cmp rax, -1
    jne .done
    mov rax, -2
.done:
    pop rbx
    pop rbp
    ret

.smallint:
    mov rax, rdi
    cmp rax, -1
    jne .si_done
    mov rax, -2
.si_done:
    ret
END_FUNC int_hash

;; ============================================================================
;; int_bool(PyObject *self) -> int (0 or 1)
;; SmallInt: decoded != 0. GMP: cmp_si(0) != 0.
;; ============================================================================
DEF_FUNC_BARE int_bool
    ; Unwrap int subclass instances
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .smallint

    push rbp
    mov rbp, rsp
    lea rdi, [rdi + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    setne al
    movzx eax, al
    pop rbp
    ret

.smallint:
    test rdi, rdi
    setnz al
    movzx eax, al
    ret
END_FUNC int_bool

;; ============================================================================
;; int_add(PyObject *a, PyObject *b) -> PyObject*
;; SmallInt x SmallInt fast path with overflow check.
;; ============================================================================
DEF_FUNC_BARE int_add
    ; Unwrap int subclass instances
    push rcx                ; save right_tag
    push rsi
    call int_unwrap
    pop rsi
    pop rcx                 ; restore right_tag
    push rdx                ; save unwrapped left_tag
    push rdi
    mov rdi, rsi
    mov edx, ecx            ; pass right_tag to int_unwrap
    call int_unwrap
    mov rsi, rdi
    mov ecx, edx            ; ecx = unwrapped right_tag
    pop rdi
    pop rdx                 ; edx = unwrapped left_tag
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp_path
    cmp ecx, TAG_SMALLINT
    jne .gmp_path

    ; Both SmallInt: decode and add
    mov rax, rdi
    mov rcx, rsi
    add rax, rcx
    jo .gmp_path            ; overflow, fall back to GMP

    ; Result fits: encode as SmallInt
    RET_TAG_SMALLINT
    ret

.gmp_path:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi

    ; Convert SmallInt args to GMP if needed
    push rcx                ; save right_tag across left conversion
    cmp edx, TAG_SMALLINT
    jne .a_ready
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1             ; flag: a was converted
    jmp .check_b
.a_ready:
    xor r13d, r13d
.check_b:
    pop rcx                 ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ready
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2              ; flag: b was converted
.b_ready:
    ; Allocate result
    mov edi, PyIntObject_size
    call ap_malloc
    push rax                ; save result ptr
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]          ; reload result ptr
    lea rdi, [rax + PyIntObject.mpz]
    lea rsi, [rbx + PyIntObject.mpz]
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_add wrt ..plt

    ; Free any temp GMP ints
    test r13b, 1
    jz .no_free_a
    mov rdi, rbx
    call int_dealloc
.no_free_a:
    test r13b, 2
    jz .no_free_b
    mov rdi, r12
    call int_dealloc
.no_free_b:
    pop rax
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
END_FUNC int_add

;; ============================================================================
;; int_sub(PyObject *a, PyObject *b) -> PyObject*
;; ============================================================================
DEF_FUNC_BARE int_sub
    ; Unwrap int subclass instances
    push rcx                ; save right_tag
    push rsi
    call int_unwrap
    pop rsi
    pop rcx                 ; restore right_tag
    push rdx                ; save unwrapped left_tag
    push rdi
    mov rdi, rsi
    mov edx, ecx            ; pass right_tag to int_unwrap
    call int_unwrap
    mov rsi, rdi
    mov ecx, edx            ; ecx = unwrapped right_tag
    pop rdi
    pop rdx                 ; edx = unwrapped left_tag
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp_path
    cmp ecx, TAG_SMALLINT
    jne .gmp_path

    mov rax, rdi
    mov rcx, rsi
    sub rax, rcx
    jo .gmp_path
    RET_TAG_SMALLINT
    ret

.gmp_path:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    push rcx                ; save right_tag
    cmp edx, TAG_SMALLINT
    jne .a_ready
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1
    jmp .check_b
.a_ready:
    xor r13d, r13d
.check_b:
    pop rcx                 ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ready
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2
.b_ready:
    mov edi, PyIntObject_size
    call ap_malloc
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    lea rdi, [rax + PyIntObject.mpz]
    lea rsi, [rbx + PyIntObject.mpz]
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_sub wrt ..plt
    test r13b, 1
    jz .no_free_a
    mov rdi, rbx
    call int_dealloc
.no_free_a:
    test r13b, 2
    jz .no_free_b
    mov rdi, r12
    call int_dealloc
.no_free_b:
    pop rax
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
END_FUNC int_sub

;; ============================================================================
;; int_mul(PyObject *a, PyObject *b) -> PyObject*
;; SmallInt x SmallInt: use imul with overflow detection
;; ============================================================================
DEF_FUNC_BARE int_mul
    ; Unwrap int subclass instances
    push rcx                ; save right_tag
    push rsi
    call int_unwrap
    pop rsi
    pop rcx                 ; restore right_tag
    push rdx                ; save unwrapped left_tag
    push rdi
    mov rdi, rsi
    mov edx, ecx            ; pass right_tag to int_unwrap
    call int_unwrap
    mov rsi, rdi
    mov ecx, edx            ; ecx = unwrapped right_tag
    pop rdi
    pop rdx                 ; edx = unwrapped left_tag
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp_path
    cmp ecx, TAG_SMALLINT
    jne .gmp_path

    mov rax, rdi
    push rcx                ; save right_tag (ecx) before clobber
    mov rcx, rsi
    imul rax, rcx
    jo .gmp_path_pop
    add rsp, 8             ; discard saved right_tag
    RET_TAG_SMALLINT
    ret

.gmp_path_pop:
    pop rcx                 ; restore right_tag
.gmp_path:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    push rcx                ; save right_tag
    cmp edx, TAG_SMALLINT
    jne .a_ready
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1
    jmp .check_b
.a_ready:
    xor r13d, r13d
.check_b:
    pop rcx                 ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ready
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2
.b_ready:
    mov edi, PyIntObject_size
    call ap_malloc
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    lea rdi, [rax + PyIntObject.mpz]
    lea rsi, [rbx + PyIntObject.mpz]
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_mul wrt ..plt
    test r13b, 1
    jz .no_free_a
    mov rdi, rbx
    call int_dealloc
.no_free_a:
    test r13b, 2
    jz .no_free_b
    mov rdi, r12
    call int_dealloc
.no_free_b:
    pop rax
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
END_FUNC int_mul

;; ============================================================================
;; int_floordiv(PyObject *a, PyObject *b) -> PyObject*
;; ============================================================================
DEF_FUNC_BARE int_floordiv
    ; Unwrap int subclass instances
    push rcx                ; save right_tag
    push rsi
    call int_unwrap
    pop rsi
    pop rcx                 ; restore right_tag
    push rdx                ; save unwrapped left_tag
    push rdi
    mov rdi, rsi
    mov edx, ecx            ; pass right_tag to int_unwrap
    call int_unwrap
    mov rsi, rdi
    mov ecx, edx            ; ecx = unwrapped right_tag
    pop rdi
    pop rdx                 ; edx = unwrapped left_tag
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp_path
    cmp ecx, TAG_SMALLINT
    jne .gmp_path

    ; SmallInt fast path
    mov rax, rdi
    mov rcx, rsi
    test rcx, rcx
    jz .zdiv_error          ; div by zero -> raise ZeroDivisionError
    cqo
    idiv rcx
    ; Python floored division: if remainder != 0 and has different sign from divisor, adjust
    test rdx, rdx
    jz .smallint_done
    mov r8, rdx
    xor r8, rcx
    jns .smallint_done
    dec rax
.smallint_done:
    RET_TAG_SMALLINT
    ret

.zdiv_error:
    push rbp
    mov rbp, rsp
    lea rdi, [rel exc_ZeroDivisionError_type]
    CSTRING rsi, "integer division or modulo by zero"
    call raise_exception

.gmp_path:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    push rcx                ; save right_tag
    cmp edx, TAG_SMALLINT
    jne .a_ready
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1
    jmp .check_b
.a_ready:
    xor r13d, r13d
.check_b:
    pop rcx                 ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ready
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2
.b_ready:
    ; Check for division by zero (GMP path)
    lea rdi, [r12 + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    jz .gmp_zdiv_error

    mov edi, PyIntObject_size
    call ap_malloc
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    lea rdi, [rax + PyIntObject.mpz]
    lea rsi, [rbx + PyIntObject.mpz]
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_fdiv_q wrt ..plt
    test r13b, 1
    jz .no_free_a
    mov rdi, rbx
    call int_dealloc
.no_free_a:
    test r13b, 2
    jz .no_free_b
    mov rdi, r12
    call int_dealloc
.no_free_b:
    pop rax
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

.gmp_zdiv_error:
    ; Free temp allocs if any
    test r13b, 1
    jz .gmp_zdiv_na
    mov rdi, rbx
    call int_dealloc
.gmp_zdiv_na:
    test r13b, 2
    jz .gmp_zdiv_nb
    mov rdi, r12
    call int_dealloc
.gmp_zdiv_nb:
    lea rdi, [rel exc_ZeroDivisionError_type]
    CSTRING rsi, "integer division or modulo by zero"
    call raise_exception
END_FUNC int_floordiv

;; ============================================================================
;; int_mod(PyObject *a, PyObject *b) -> PyObject*
;; ============================================================================
DEF_FUNC_BARE int_mod
    ; Unwrap int subclass instances
    push rcx                ; save right_tag
    push rsi
    call int_unwrap
    pop rsi
    pop rcx                 ; restore right_tag
    push rdx                ; save unwrapped left_tag
    push rdi
    mov rdi, rsi
    mov edx, ecx            ; pass right_tag to int_unwrap
    call int_unwrap
    mov rsi, rdi
    mov ecx, edx            ; ecx = unwrapped right_tag
    pop rdi
    pop rdx                 ; edx = unwrapped left_tag
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp_path
    cmp ecx, TAG_SMALLINT
    jne .gmp_path

    mov rax, rdi
    mov rcx, rsi
    test rcx, rcx
    jz .mod_zdiv_error
    cqo
    idiv rcx
    mov rax, rdx            ; remainder is in rdx
    ; Python floored mod: if remainder != 0 and has different sign from divisor, adjust
    test rax, rax
    jz .smallint_done
    mov r8, rax
    xor r8, rcx
    jns .smallint_done
    add rax, rcx            ; remainder += divisor
.smallint_done:
    RET_TAG_SMALLINT
    ret

.mod_zdiv_error:
    push rbp
    mov rbp, rsp
    lea rdi, [rel exc_ZeroDivisionError_type]
    CSTRING rsi, "integer division or modulo by zero"
    call raise_exception

.gmp_path:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    push rcx                ; save right_tag
    cmp edx, TAG_SMALLINT
    jne .a_ready
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1
    jmp .check_b
.a_ready:
    xor r13d, r13d
.check_b:
    pop rcx                 ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ready
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2
.b_ready:
    ; Check for division by zero (GMP path)
    lea rdi, [r12 + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    jz .gmp_mod_zdiv_error

    mov edi, PyIntObject_size
    call ap_malloc
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    lea rdi, [rax + PyIntObject.mpz]
    lea rsi, [rbx + PyIntObject.mpz]
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_fdiv_r wrt ..plt
    test r13b, 1
    jz .no_free_a
    mov rdi, rbx
    call int_dealloc
.no_free_a:
    test r13b, 2
    jz .no_free_b
    mov rdi, r12
    call int_dealloc
.no_free_b:
    pop rax
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

.gmp_mod_zdiv_error:
    test r13b, 1
    jz .gmp_mod_zdiv_na
    mov rdi, rbx
    call int_dealloc
.gmp_mod_zdiv_na:
    test r13b, 2
    jz .gmp_mod_zdiv_nb
    mov rdi, r12
    call int_dealloc
.gmp_mod_zdiv_nb:
    lea rdi, [rel exc_ZeroDivisionError_type]
    CSTRING rsi, "integer division or modulo by zero"
    call raise_exception
END_FUNC int_mod

;; ============================================================================
;; int_neg(PyObject *a) -> PyObject*
;; ============================================================================
DEF_FUNC_BARE int_neg
    cmp edx, TAG_SMALLINT
    je .smallint
    ; Unwrap int subclass
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .smallint

    ; GMP path
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    mov rbx, rdi
    mov edi, PyIntObject_size
    call ap_malloc
    mov r12, rax
    mov qword [r12 + PyObject.ob_refcnt], 1
    lea rax, [rel int_type]
    mov [r12 + PyObject.ob_type], rax
    lea rdi, [r12 + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    lea rdi, [r12 + PyIntObject.mpz]
    lea rsi, [rbx + PyIntObject.mpz]
    call __gmpz_neg wrt ..plt
    mov rax, r12
    mov edx, TAG_PTR
    pop r12
    pop rbx
    pop rbp
    ret

.smallint:
    mov rax, rdi
    neg rax
    jo .neg_overflow            ; only -(-2^63) overflows
    RET_TAG_SMALLINT
    ret
.neg_overflow:
    ; -(-2^63) = 2^63, doesn't fit i64. Create GMP and negate.
    push rbp
    mov rbp, rsp
    push rbx
    call int_from_i64_gmp       ; rdi still has original -2^63
    ; rax = GMP PyIntObject* with value -2^63
    mov rbx, rax
    lea rdi, [rax + PyIntObject.mpz]
    mov rsi, rdi
    call __gmpz_neg wrt ..plt   ; negate in place → +2^63
    mov rax, rbx
    mov edx, TAG_PTR
    pop rbx
    pop rbp
    ret
END_FUNC int_neg

;; ============================================================================
;; int_unwrap(rdi) -> rdi
;; If rdi is a PyIntSubclassObject, extract the int_value.
;; If rdi is a SmallInt or GMP int, leave unchanged.
global int_unwrap
DEF_FUNC_BARE int_unwrap
    ; rdi = payload, edx = tag -> rdi = unwrapped payload, edx = unwrapped tag
    cmp edx, TAG_SMALLINT
    je .iuw_done
    cmp edx, TAG_BOOL
    je .iuw_bool
    ; Only dereference if TAG_PTR (heap pointer); other tags return unchanged
    test edx, TAG_RC_BIT
    jz .iuw_done                 ; TAG_FLOAT, TAG_NONE, TAG_NULL → not an int
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .iuw_done                 ; exact int_type, edx already TAG_PTR
    mov rax, [rax + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_INT_SUBCLASS
    jz .iuw_done                 ; not int subclass
    mov rdx, [rdi + PyIntSubclassObject.int_value_tag]   ; unwrapped tag
    mov rdi, [rdi + PyIntSubclassObject.int_value]       ; unwrapped payload
.iuw_done:
    ret
.iuw_bool:
    ; TAG_BOOL payload (0 or 1) -> TAG_SMALLINT (same payload)
    mov edx, TAG_SMALLINT
    ret
END_FUNC int_unwrap

;; int_compare(PyObject *a, PyObject *b, int op) -> PyObject*
;; op: PY_LT=0 PY_LE=1 PY_EQ=2 PY_NE=3 PY_GT=4 PY_GE=5
;; ============================================================================
DEF_FUNC int_compare
    push rbx
    push r12
    push r13
    push r14

    mov ebx, edx            ; save op
    mov r12, rdi             ; a
    mov r13, rsi             ; b
    mov r14d, r8d            ; r14d = b_tag (right operand tag from caller)

    ; Unwrap int subclass instances
    ; int_unwrap(rdi=payload, edx=tag) -> rdi=unwrapped, edx=tag
    ; For tp_richcompare callers: rcx=right_tag, r8d or edx has left_tag
    ; Since tp_richcompare passes edx=op, we need to determine tags ourselves
    ; The caller (op_compare_op) passes tags in stack/regs before calling tp_richcompare
    ; but tp_richcompare only gets (left, right, op). We detect SmallInt by checking
    ; if value could be a heap pointer (presence of valid ob_type).
    ; Simpler: since nb_ callers pass rdx=left_tag, rcx=right_tag, but tp_richcompare
    ; passes edx=op, we check if edx looks like a tag or a comparison op.
    ; Tags: 0,1,2,3,4,0x105. Ops: 0-5. Overlap at 0-4!
    ; So we can't distinguish. Instead, just check ob_type validity for heap pointers.

    ; Strategy: try to detect SmallInt by checking if pointer dereference would be valid.
    ; Since caller already handles both-SmallInt, at least one is a real pointer.
    ; We use a different approach: check if the value is in a plausible heap range.
    ; Actually, the simplest: the caller's compare_op fast path catches both-SmallInt.
    ; For int_compare, we can just assume at least one is a heap int. We need to handle
    ; int subclass unwrapping and SmallInt-to-GMP conversion.

    ; Check a: is it a heap pointer? (ob_type at +8 would be a valid pointer)
    ; For SmallInt raw values (arbitrary int64), accessing [rdi+8] would segfault
    ; on most values. We need a reliable way to detect.
    ; Use: the caller passes rdx=left_tag for nb_ calls, but edx=op for tp_richcompare.
    ; Since we saved ebx=edx, we lost the distinction.
    ;
    ; NEW APPROACH: Check if ob_type points to int_type or its subclass
    ; This only works for heap pointers. For SmallInt payloads, we'd crash.
    ; Since the caller already eliminated both-SmallInt, at least one is heap.
    ; We can't know WHICH one is SmallInt without tags.
    ;
    ; SAFE APPROACH: Make tp_richcompare callers pass tags.
    ; For now: assume the compare_op caller already handles both-SmallInt,
    ; so both args are heap pointers (TAG_PTR). Skip int_unwrap tag check.
    ; int_unwrap with edx=TAG_PTR will do type checking and unwrap subclasses.

    ; Unwrap a
    mov rdi, r12
    mov edx, ecx                 ; left_tag from caller
    call int_unwrap
    mov r12, rdi                 ; unwrapped a
    mov eax, edx                 ; a_tag after unwrap

    ; Unwrap b
    push rax                     ; save a_tag
    mov rdi, r13
    mov edx, r14d                ; right_tag from caller
    call int_unwrap
    mov r13, rdi                 ; unwrapped b
    ; edx = b_tag after unwrap
    pop rax                      ; rax = a_tag

    ; Validate both operands are actually ints (TAG_SMALLINT or TAG_PTR with int_type/bool_type)
    ; If either is not an int, return NULL (NotImplemented)
    extern bool_type
    cmp eax, TAG_SMALLINT
    je .a_valid
    cmp eax, TAG_PTR
    jne .ret_notimpl             ; a is not int (e.g., str, float obj, etc.)
    mov rcx, [r12 + PyObject.ob_type]
    lea r8, [rel int_type]
    cmp rcx, r8
    je .a_valid
    lea r8, [rel bool_type]
    cmp rcx, r8
    jne .ret_notimpl             ; a is TAG_PTR but not int_type or bool_type
.a_valid:
    cmp edx, TAG_SMALLINT
    je .b_valid
    cmp edx, TAG_PTR
    jne .ret_notimpl             ; b is not int
    mov rcx, [r13 + PyObject.ob_type]
    lea r8, [rel int_type]
    cmp rcx, r8
    je .b_valid
    lea r8, [rel bool_type]
    cmp rcx, r8
    jne .ret_notimpl             ; b is TAG_PTR but not int_type or bool_type
.b_valid:

    ; Check if both SmallInt (could happen after unwrapping int subclasses)
    cmp eax, TAG_SMALLINT
    jne .a_not_smallint
    cmp edx, TAG_SMALLINT
    je .both_smallint
.a_not_smallint:

    ; At least one is GMP - use __gmpz_cmp_si to avoid heap allocation
    cmp eax, TAG_SMALLINT
    jne .a_is_gmp
    ; a is SmallInt, b is GMP: cmp_si(b->mpz, a) then negate
    lea rdi, [r13 + PyIntObject.mpz]
    mov rsi, r12               ; SmallInt raw value
    call __gmpz_cmp_si wrt ..plt
    neg eax                    ; negate: cmp_si(b,a) → want cmp(a,b)
    mov r12d, eax
    jmp .dispatch_op
.a_is_gmp:
    cmp edx, TAG_SMALLINT
    jne .both_gmp
    ; a is GMP, b is SmallInt: cmp_si(a->mpz, b)
    lea rdi, [r12 + PyIntObject.mpz]
    mov rsi, r13               ; SmallInt raw value
    call __gmpz_cmp_si wrt ..plt
    mov r12d, eax
    jmp .dispatch_op
.both_gmp:
    lea rdi, [r12 + PyIntObject.mpz]
    lea rsi, [r13 + PyIntObject.mpz]
    call __gmpz_cmp wrt ..plt
    mov r12d, eax
    jmp .dispatch_op

.both_smallint:
    ; Compare SmallInt payloads directly
    mov rax, r12
    mov rcx, r13
    cmp rax, rcx
    ; Set r12d to cmp-style result: -1, 0, or 1
    mov r12d, 0
    jz .dispatch_op
    mov r12d, -1
    jl .dispatch_op
    mov r12d, 1

.dispatch_op:
    cmp ebx, PY_LT
    je .do_lt
    cmp ebx, PY_LE
    je .do_le
    cmp ebx, PY_EQ
    je .do_eq
    cmp ebx, PY_NE
    je .do_ne
    cmp ebx, PY_GT
    je .do_gt
    jmp .do_ge

.do_lt:
    test r12d, r12d
    js .ret_true
    jmp .ret_false
.do_le:
    test r12d, r12d
    jle .ret_true
    jmp .ret_false
.do_eq:
    test r12d, r12d
    jz .ret_true
    jmp .ret_false
.do_ne:
    test r12d, r12d
    jnz .ret_true
    jmp .ret_false
.do_gt:
    test r12d, r12d
    jg .ret_true
    jmp .ret_false
.do_ge:
    test r12d, r12d
    jge .ret_true
    jmp .ret_false

.ret_notimpl:
    ; Operand is not an int — return NULL (NotImplemented)
    RET_NULL
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ret_true:
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.ret_false:
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC int_compare

;; ============================================================================
;; int_dealloc(PyObject *self)
;; Free GMP data + object. SmallInt guard.
;; ============================================================================
DEF_FUNC_BARE int_dealloc
    ; tp_dealloc(rdi=obj) — edx is NOT passed, so no tag check.
    ; SmallInts never reach here (no TAG_RC_BIT, so DECREF_VAL skips them).
    push rbp
    mov rbp, rsp
    push rbx
    mov rbx, rdi
    lea rdi, [rbx + PyIntObject.mpz]
    call __gmpz_clear wrt ..plt
    mov rdi, rbx
    call ap_free
    pop rbx
    pop rbp
    ret
END_FUNC int_dealloc

;; ============================================================================
;; Bitwise AND: int_and(PyObject *a, PyObject *b) -> PyObject*
;; ============================================================================
DEF_FUNC_BARE int_and
    ; Unwrap int subclass instances
    push rcx                ; save right_tag
    push rsi
    call int_unwrap
    pop rsi
    pop rcx                 ; restore right_tag
    push rdx                ; save unwrapped left_tag
    push rdi
    mov rdi, rsi
    mov edx, ecx            ; pass right_tag to int_unwrap
    call int_unwrap
    mov rsi, rdi
    mov ecx, edx            ; ecx = unwrapped right_tag
    pop rdi
    pop rdx                 ; edx = unwrapped left_tag
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp
    cmp ecx, TAG_SMALLINT
    jne .gmp

    ; Both SmallInt
    mov rax, rdi
    and rax, rsi           ; AND preserves tag bit, result is valid SmallInt
    RET_TAG_SMALLINT
    ret

.gmp:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    push rcx                ; save right_tag
    cmp edx, TAG_SMALLINT
    jne .a_ok
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1
    jmp .chk_b
.a_ok:
    xor r13d, r13d
.chk_b:
    pop rcx                 ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ok
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2
.b_ok:
    mov edi, PyIntObject_size
    call ap_malloc
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    lea rdi, [rax + PyIntObject.mpz]
    lea rsi, [rbx + PyIntObject.mpz]
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_and wrt ..plt
    test r13b, 1
    jz .na
    mov rdi, rbx
    call int_dealloc
.na:
    test r13b, 2
    jz .nb
    mov rdi, r12
    call int_dealloc
.nb:
    pop rax
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
END_FUNC int_and

;; ============================================================================
;; Bitwise OR: int_or(PyObject *a, PyObject *b) -> PyObject*
;; ============================================================================
DEF_FUNC_BARE int_or
    ; Unwrap int subclass instances
    push rcx                ; save right_tag
    push rsi
    call int_unwrap
    pop rsi
    pop rcx                 ; restore right_tag
    push rdx                ; save unwrapped left_tag
    push rdi
    mov rdi, rsi
    mov edx, ecx            ; pass right_tag to int_unwrap
    call int_unwrap
    mov rsi, rdi
    mov ecx, edx            ; ecx = unwrapped right_tag
    pop rdi
    pop rdx                 ; edx = unwrapped left_tag
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp
    cmp ecx, TAG_SMALLINT
    jne .gmp

    ; Both SmallInt
    mov rax, rdi
    or rax, rsi            ; OR preserves tag bit
    RET_TAG_SMALLINT
    ret

.gmp:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    push rcx                ; save right_tag
    cmp edx, TAG_SMALLINT
    jne .a_ok
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1
    jmp .chk_b
.a_ok:
    xor r13d, r13d
.chk_b:
    pop rcx                 ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ok
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2
.b_ok:
    mov edi, PyIntObject_size
    call ap_malloc
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    lea rdi, [rax + PyIntObject.mpz]
    lea rsi, [rbx + PyIntObject.mpz]
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_ior wrt ..plt
    test r13b, 1
    jz .na
    mov rdi, rbx
    call int_dealloc
.na:
    test r13b, 2
    jz .nb
    mov rdi, r12
    call int_dealloc
.nb:
    pop rax
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
END_FUNC int_or

;; ============================================================================
;; Bitwise XOR: int_xor(PyObject *a, PyObject *b) -> PyObject*
;; ============================================================================
DEF_FUNC_BARE int_xor
    ; Unwrap int subclass instances
    push rcx                ; save right_tag
    push rsi
    call int_unwrap
    pop rsi
    pop rcx                 ; restore right_tag
    push rdx                ; save unwrapped left_tag
    push rdi
    mov rdi, rsi
    mov edx, ecx            ; pass right_tag to int_unwrap
    call int_unwrap
    mov rsi, rdi
    mov ecx, edx            ; ecx = unwrapped right_tag
    pop rdi
    pop rdx                 ; edx = unwrapped left_tag
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp
    cmp ecx, TAG_SMALLINT
    jne .gmp

    ; Both SmallInt: XOR values, must re-set tag bit
    mov rax, rdi
    mov rcx, rsi
    xor rax, rcx
    RET_TAG_SMALLINT
    ret

.gmp:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    push rcx                ; save right_tag
    cmp edx, TAG_SMALLINT
    jne .a_ok
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1
    jmp .chk_b
.a_ok:
    xor r13d, r13d
.chk_b:
    pop rcx                 ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ok
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2
.b_ok:
    mov edi, PyIntObject_size
    call ap_malloc
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    lea rdi, [rax + PyIntObject.mpz]
    lea rsi, [rbx + PyIntObject.mpz]
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_xor wrt ..plt
    test r13b, 1
    jz .na
    mov rdi, rbx
    call int_dealloc
.na:
    test r13b, 2
    jz .nb
    mov rdi, r12
    call int_dealloc
.nb:
    pop rax
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
END_FUNC int_xor

;; ============================================================================
;; Bitwise NOT: int_invert(PyObject *a, PyObject *b_unused) -> PyObject*
;; ~x = -(x+1)
;; ============================================================================
DEF_FUNC_BARE int_invert
    ; Unwrap int subclass instances
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .smallint

    ; GMP path
    push rbp
    mov rbp, rsp
    push rbx
    mov rbx, rdi
    mov edi, PyIntObject_size
    call ap_malloc
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    lea rdi, [rax + PyIntObject.mpz]
    lea rsi, [rbx + PyIntObject.mpz]
    call __gmpz_com wrt ..plt
    pop rax
    mov edx, TAG_PTR
    pop rbx
    pop rbp
    ret

.smallint:
    mov rax, rdi
    not rax                ; ~x = -(x+1), always fits i64
    RET_TAG_SMALLINT
    ret
END_FUNC int_invert

;; ============================================================================
;; Left shift: int_lshift(PyObject *a, PyObject *b) -> PyObject*
;; ============================================================================
DEF_FUNC int_lshift
    push rbx
    push r12
    push r13
    push r14

    ; Save tags
    mov r14d, edx           ; r14d = left_tag
    ; ecx = right_tag

    ; Unwrap int subclass instances
    push rsi
    push rcx                ; save right_tag
    call int_unwrap          ; rdi, edx -> unwrapped rdi, edx
    mov r14d, edx            ; update left_tag
    pop rcx                  ; right_tag
    pop rsi
    push rdi
    mov rdi, rsi
    mov edx, ecx
    call int_unwrap          ; rdi, edx -> unwrapped rdi, edx
    mov rsi, rdi             ; rsi = unwrapped right
    mov ecx, edx             ; ecx = right_tag
    pop rdi                  ; rdi = unwrapped left

    mov rbx, rdi           ; left operand
    mov r12, rsi           ; right operand (shift amount)

    ; Get shift amount as int64
    cmp ecx, TAG_SMALLINT
    je .shift_smallint
    ; GMP right operand: get as int64
    lea rdi, [r12 + PyIntObject.mpz]
    call __gmpz_get_si wrt ..plt
    mov r13, rax
    jmp .have_shift
.shift_smallint:
    mov r13, r12

.have_shift:
    ; r13 = shift amount
    test r13, r13
    js .neg_shift

    ; Convert left to GMP if needed
    xor ecx, ecx           ; flag: converted
    cmp r14d, TAG_SMALLINT
    jne .a_gmp
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov cl, 1
.a_gmp:
    push rcx
    mov edi, PyIntObject_size
    call ap_malloc
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    lea rdi, [rax + PyIntObject.mpz]
    lea rsi, [rbx + PyIntObject.mpz]
    mov rdx, r13           ; shift count
    call __gmpz_mul_2exp wrt ..plt
    pop rax
    pop rcx
    test cl, cl
    jz .lsh_done
    push rax
    mov rdi, rbx
    call int_dealloc
    pop rax
.lsh_done:
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.neg_shift:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "negative shift count"
    call raise_exception
END_FUNC int_lshift

;; ============================================================================
;; Right shift: int_rshift(PyObject *a, PyObject *b) -> PyObject*
;; ============================================================================
DEF_FUNC int_rshift
    push rbx
    push r12
    push r13
    push r14

    ; Save tags
    mov r14d, edx           ; r14d = left_tag
    ; ecx = right_tag

    ; Unwrap int subclass instances
    push rsi
    push rcx                ; save right_tag
    call int_unwrap
    mov r14d, edx            ; update left_tag
    pop rcx
    pop rsi
    push rdi
    mov rdi, rsi
    mov edx, ecx
    call int_unwrap
    mov rsi, rdi
    mov ecx, edx             ; ecx = right_tag
    pop rdi

    mov rbx, rdi
    mov r12, rsi

    ; Get shift amount
    cmp ecx, TAG_SMALLINT
    je .shift_smallint
    lea rdi, [r12 + PyIntObject.mpz]
    call __gmpz_get_si wrt ..plt
    mov r13, rax
    jmp .have_shift
.shift_smallint:
    mov r13, r12

.have_shift:
    test r13, r13
    js .neg_shift

    ; SmallInt fast path
    cmp r14d, TAG_SMALLINT
    jne .gmp_path
    mov rax, rbx
    ; Arithmetic right shift
    mov rcx, r13
    cmp rcx, 63
    jge .max_shift
    sar rax, cl
    RET_TAG_SMALLINT
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.max_shift:
    ; Shift >= 63: result is 0 or -1 depending on sign
    sar rax, 63
    RET_TAG_SMALLINT
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.gmp_path:
    mov edi, PyIntObject_size
    call ap_malloc
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    lea rdi, [rax + PyIntObject.mpz]
    lea rsi, [rbx + PyIntObject.mpz]
    mov rdx, r13
    call __gmpz_fdiv_q_2exp wrt ..plt
    pop rax
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.neg_shift:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "negative shift count"
    call raise_exception
END_FUNC int_rshift

;; ============================================================================
;; Power: int_power(PyObject *a, PyObject *b) -> PyObject*
;; For small positive exponents, use GMP mpz_pow_ui
;; ============================================================================
DEF_FUNC int_power
    push rbx
    push r12
    push r13
    push r14

    ; Calling convention: rdi=left, rsi=right, rdx=left_tag, rcx=right_tag
    ; Unwrap int subclass instances, tracking tags
    push rsi                ; save right
    push rcx                ; save right_tag
    call int_unwrap         ; rdi=unwrapped left, edx=left_tag
    pop rcx                 ; restore right_tag
    pop rsi                 ; restore right
    mov r14d, edx           ; r14d = base_tag (left tag after unwrap)
    push rdi                ; save unwrapped left
    push r14                ; save base_tag
    mov rdi, rsi
    mov edx, ecx            ; right_tag
    call int_unwrap         ; rdi=unwrapped right, edx=right_tag
    mov rsi, rdi            ; rsi = unwrapped right (exponent)
    mov ecx, edx            ; ecx = exp_tag (right tag after unwrap)
    pop r14                 ; r14d = base_tag
    pop rdi                 ; rdi = unwrapped left (base)

    mov rbx, rdi           ; rbx = base
    mov r12, rsi           ; r12 = exponent

    ; Get exponent as int64
    cmp ecx, TAG_SMALLINT
    je .exp_smallint
    push rbx                ; save base across GMP call
    push r14                ; save base_tag
    lea rdi, [r12 + PyIntObject.mpz]
    call __gmpz_get_si wrt ..plt
    pop r14                 ; restore base_tag
    pop rbx                 ; restore base
    mov r13, rax
    jmp .have_exp
.exp_smallint:
    mov r13, r12

.have_exp:
    ; Negative exponent: return float (int ** -n = 1/int**n)
    test r13, r13
    js .neg_exp

    ; Convert base to GMP if needed
    ; r14d = base_tag from int_unwrap
    xor ecx, ecx
    cmp r14d, TAG_SMALLINT
    jne .base_gmp
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov cl, 1
.base_gmp:
    push rcx
    mov edi, PyIntObject_size
    call ap_malloc
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    lea rdi, [rax + PyIntObject.mpz]
    lea rsi, [rbx + PyIntObject.mpz]
    mov rdx, r13           ; exponent (unsigned)
    call __gmpz_pow_ui wrt ..plt
    pop rax
    pop rcx
    test cl, cl
    jz .pow_done
    push rax
    mov rdi, rbx
    call int_dealloc
    pop rax
.pow_done:
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.neg_exp:
    ; int ** negative → float result (1.0 / base**abs(exp))
    ; For simplicity, convert both to double and use pow
    ; Actually, just raise a TypeError for now (like many impls)
    ; Python returns float for negative int power
    ; Convert base to double (r14d = base_tag)
    cmp r14d, TAG_SMALLINT
    je .neg_exp_smallint
    lea rdi, [rbx + PyIntObject.mpz]
    call __gmpz_get_d wrt ..plt
    jmp .neg_exp_have_base
.neg_exp_smallint:
    mov rax, rbx
    cvtsi2sd xmm0, rax
.neg_exp_have_base:
    ; xmm0 = base as double
    ; Compute base ** exp using repeated multiply (simple)
    ; For now: 1.0 / (base ** abs(exp))
    neg r13                ; abs(exp)
    movsd xmm1, [rel one_double]    ; xmm1 = result = 1.0
.pow_loop:
    test r13, r13
    jz .pow_loop_done
    mulsd xmm1, xmm0
    dec r13
    jmp .pow_loop
.pow_loop_done:
    ; result = 1.0 / xmm1
    movsd xmm0, [rel one_double]
    divsd xmm0, xmm1
    call float_from_f64
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC int_power

;; ============================================================================
;; True divide: int_true_divide(PyObject *a, PyObject *b) -> PyObject* (float)
;; int / int always returns float in Python
;; ============================================================================
DEF_FUNC int_true_divide
    ; rdi=left, rsi=right, rdx=left_tag, rcx=right_tag
    and rsp, -16           ; align for potential libc calls
    push rbx
    push r12
    push r13

    mov rbx, rdi           ; left
    mov r12, rsi           ; right
    mov r13d, ecx          ; r13d = right_tag

    ; Convert left to double (edx = left_tag, still valid)
    cmp edx, TAG_SMALLINT
    je .td_left_small
    lea rdi, [rbx + PyIntObject.mpz]
    call __gmpz_get_d wrt ..plt
    jmp .td_have_left
.td_left_small:
    mov rax, rbx
    cvtsi2sd xmm0, rax
.td_have_left:
    movsd [rsp-8], xmm0   ; save left double

    ; Convert right to double (r13d = right_tag)
    cmp r13d, TAG_SMALLINT
    je .td_right_small
    lea rdi, [r12 + PyIntObject.mpz]
    call __gmpz_get_d wrt ..plt
    jmp .td_have_right
.td_right_small:
    mov rax, r12
    cvtsi2sd xmm0, rax
.td_have_right:
    ; xmm0 = right double
    ; Check division by zero
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    je .td_divzero

    movsd xmm1, xmm0      ; xmm1 = right
    movsd xmm0, [rsp-8]   ; xmm0 = left
    divsd xmm0, xmm1
    call float_from_f64

    pop r13
    pop r12
    pop rbx
    leave
    ret

.td_divzero:
    lea rdi, [rel exc_ZeroDivisionError_type]
    CSTRING rsi, "division by zero"
    call raise_exception
END_FUNC int_true_divide

;; ============================================================================
;; Data
;; ============================================================================
section .data

align 8
one_double: dq 0x3FF0000000000000  ; 1.0

int_name_str: db "int", 0

section .data

align 8
global int_number_methods
int_number_methods:
    dq int_add              ; nb_add          +0
    dq int_sub              ; nb_subtract     +8
    dq int_mul              ; nb_multiply     +16
    dq int_mod              ; nb_remainder    +24
    dq 0                    ; nb_divmod       +32
    dq int_power            ; nb_power        +40
    dq int_neg              ; nb_negative     +48
    dq 0                    ; nb_positive     +56
    dq 0                    ; nb_absolute     +64
    dq int_bool             ; nb_bool         +72
    dq int_invert           ; nb_invert       +80
    dq int_lshift           ; nb_lshift       +88
    dq int_rshift           ; nb_rshift       +96
    dq int_and              ; nb_and          +104
    dq int_xor              ; nb_xor          +112
    dq int_or               ; nb_or           +120
    dq 0                    ; nb_int          +128
    dq 0                    ; nb_float        +136
    dq int_floordiv         ; nb_floor_divide +144
    dq int_true_divide      ; nb_true_divide  +152
    dq 0                    ; nb_index        +160
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

align 8
global int_type
int_type:
    dq 1                    ; ob_refcnt (immortal)
    dq type_type            ; ob_type
    dq int_name_str         ; tp_name
    dq PyIntObject_size     ; tp_basicsize
    dq int_dealloc          ; tp_dealloc
    dq int_repr             ; tp_repr
    dq int_repr             ; tp_str
    dq int_hash             ; tp_hash
    dq 0                    ; tp_call
    dq 0                    ; tp_getattr
    dq 0                    ; tp_setattr
    dq int_compare          ; tp_richcompare
    dq 0                    ; tp_iter
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq 0                    ; tp_new
    dq int_number_methods   ; tp_as_number
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq TYPE_FLAG_INT_SUBCLASS ; tp_flags
    dq 0                    ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
