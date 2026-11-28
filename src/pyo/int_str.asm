; pyo/int_str.asm - int <-> text
;
; Split out of pyo/int.asm when that file reached the 100k cap.  The seam is
; the one it already had: everything here turns an integer into characters or
; characters into an integer, and nothing here is reached by arithmetic.
;
;   int_from_cstr_base  int("...", base): whitespace, sign, 0b/0o/0x, the
;                       underscores, the int64 fast path and GMP behind it
;   int_base_str        the C string for hex(), oct(), bin() and the b/o/x/X
;                       format types
;   int_repr            str(n) and repr(n), and the 4300-digit conversion
;                       limit CPython raises ValueError at
;
; What stayed in pyo/int.asm is the integer itself: the representation, the
; arithmetic, the comparisons and the lifecycle.

%include "macros.inc"
%include "object.inc"

extern ap_malloc
extern ap_free
extern str_from_cstr
extern int_from_i64
extern int_new_compact
extern int_alloc_raw
extern int_unwrap
extern int_type
extern exc_ValueError_type
extern strlen
extern str_from_cstr_heap
extern int_promote_mpz

; GMP
extern __gmpz_init
extern __gmpz_clear
extern __gmpz_set_str
extern __gmpz_get_str
extern __gmpz_neg
extern __gmpz_sizeinbase
extern __gmpz_fits_slong_p
extern __gmpz_get_si
extern __gmpz_cmp_si

section .text


;; ============================================================================
;; int_from_cstr_base(char *str, int base) -> PyObject* or NULL
;; Parse integer from string with given base (0 = auto-detect, 2-36).
;; Handles leading/trailing whitespace, sign, 0b/0o/0x prefixes, underscores.
;; NULL (rax = 0, edx = TAG_NULL) with nothing pending is "not a number", and
;; the caller words that; NULL with a ValueError pending is the digit limit.
;; Fails: 0?
;; ============================================================================
;; ============================================================================
;; Frame layout for int_from_cstr_base
;; ============================================================================
IB_SRC    equ 8          ; original string ptr
IB_BASE   equ 16         ; resolved base
IB_SIGN   equ 24         ; 0 = positive, 1 = negative
IB_BUF    equ 32         ; cleaned buffer ptr
IB_OBJ    equ 40         ; allocated PyIntObject ptr
IB_FRAME  equ 48            ; + 0 pushes = 48

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
    cmp al, 0xc2
    je .skip_ws_2byte
    cmp al, 0xe2
    je .skip_ws_3byte_e2
    cmp al, 0xe3
    je .skip_ws_3byte_e3
    cmp al, 0xe1
    je .skip_ws_3byte_e1
    jmp .ws_done
.skip_ws_1:
    inc rdi
    jmp .skip_ws
.skip_ws_2byte:
    ; U+00A0 (NBSP): C2 A0
    cmp byte [rdi + 1], 0xa0
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
    cmp byte [rdi + 2], 0x9f
    jne .ws_done
    add rdi, 3
    jmp .skip_ws
.skip_ws_e2_80:
    movzx ecx, byte [rdi + 2]
    ; U+2000-U+200A: third byte 0x80-0x8a
    cmp cl, 0x80
    jb .ws_done
    cmp cl, 0x8a
    jbe .skip_ws_3
    ; U+2028-U+2029: third byte 0xa8-0xa9
    cmp cl, 0xa8
    je .skip_ws_3
    cmp cl, 0xa9
    je .skip_ws_3
    ; U+202F: third byte 0xaf
    cmp cl, 0xaf
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
    cmp byte [rdi + 1], 0x9a
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

    ; ------------------------------------------------------------------
    ; Fast path: an ordinary run of ASCII digits that fits an int64.
    ;
    ; The general path below allocates a cleaned copy of the string, then a
    ; PyIntObject, then an mpz, calls __gmpz_set_str, and finally asks
    ; __gmpz_get_si and __gmpz_cmp_si whether the answer would have fitted an
    ; int64 all along -- before freeing all three again.  int("5") did every
    ; one of those; malloc and free alone were 23% of an int(str) loop.
    ;
    ; This loop reads the source in place and allocates nothing.  It declines
    ; to the general path on ANYTHING it is not sure of -- an underscore, a
    ; Unicode digit, trailing whitespace, a digit out of range for the base,
    ; an empty string, more than 64 digits, or an int64 overflow -- so the
    ; general path remains the only place the error wording and the awkward
    ; cases are written down.
    ;
    ; The digit limit needs no check here: sys.set_int_max_str_digits refuses
    ; anything between 1 and 639, so a number of 64 digits or fewer is under
    ; every limit that can be set.
    mov rsi, [rbp - IB_SRC]
    mov r9, [rbp - IB_BASE]
    cmp r9, 36
    ja .fast_decline
    cmp r9, 2
    jb .fast_decline
    xor eax, eax                ; the accumulating magnitude
    xor r10d, r10d              ; how many digits have been taken
.fast_digit_loop:
    movzx ecx, byte [rsi]
    test cl, cl
    jz .fast_digits_done
    cmp r10d, 64
    jae .fast_decline           ; long enough that the limit could matter
    mov edx, ecx
    sub edx, '0'
    cmp edx, 9
    jbe .fast_have_digit
    ; A letter, in either case.  Anything else -- '_', a space, a UTF-8 lead
    ; byte -- lands above 25 here and declines.
    or ecx, 0x20
    mov edx, ecx
    sub edx, 'a'
    cmp edx, 25
    ja .fast_decline
    add edx, 10
.fast_have_digit:
    cmp rdx, r9
    jae .fast_decline           ; not a digit in THIS base
    imul rax, r9
    jo .fast_decline
    add rax, rdx
    jo .fast_decline
    inc r10d
    inc rsi
    jmp .fast_digit_loop
.fast_digits_done:
    test r10d, r10d
    jz .fast_decline            ; nothing but a sign
    cmp qword [rbp - IB_SIGN], 0
    je .fast_positive
    neg rax
.fast_positive:
    RET_TAG_SMALLINT
    leave
    ret
.fast_decline:

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
    cmp r8b, 0xc2
    je .copy_trail_utf8_c2
    cmp r8b, 0xe2
    je .copy_trail_utf8_e2
    cmp r8b, 0xe3
    je .copy_trail_utf8_e3
    cmp r8b, 0xe1
    je .copy_trail_utf8_e1

    ; Check for underscore
    cmp r8b, '_'
    je .copy_underscore

    ; A SECOND sign.  One leading sign was stripped in step 2; anything after
    ; that is not a digit in any base, and __gmpz_set_str -- which this buffer
    ; is handed to -- would happily parse a sign of its own.  int("+-1")
    ; answered -1.
    cmp r8b, '+'
    je .parse_error
    cmp r8b, '-'
    je .parse_error

    ; Check for Unicode digit (multi-byte UTF-8)
    cmp r8b, 0xd9
    je .copy_digit_arabic
    cmp r8b, 0xe0
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
    cmp r9b, 0xa0
    jb .copy_not_ws         ; not a digit, treat as regular byte
    cmp r9b, 0xa9
    ja .copy_not_ws
    ; Convert to ASCII: r9b - 0xa0 + '0'
    sub r9b, 0xa0
    add r9b, '0'
    mov [rdi + rcx], r9b
    inc rcx
    xor edx, edx
    add rsi, 2              ; skip 2-byte UTF-8
    jmp .copy_loop

.copy_digit_3byte:
    ; Devanagari digits U+0966-096F: E0 A5 A6-AF → '0'-'9'
    cmp byte [rsi + 1], 0xa5
    jne .copy_not_ws        ; not Devanagari, treat as regular byte
    movzx r9d, byte [rsi + 2]
    cmp r9b, 0xa6
    jb .copy_not_ws
    cmp r9b, 0xaf
    ja .copy_not_ws
    ; Convert to ASCII: r9b - 0xa6 + '0'
    sub r9b, 0xa6
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
    cmp byte [rsi + 1], 0xa0
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
    cmp byte [rsi + 2], 0x9f
    jne .copy_not_ws
    add rsi, 3
    jmp .trail_loop
.copy_trail_e2_80:
    movzx r9d, byte [rsi + 2]
    cmp r9b, 0x80
    jb .copy_not_ws
    cmp r9b, 0x8a
    jbe .copy_trail_utf8_3
    cmp r9b, 0xa8
    je .copy_trail_utf8_3
    cmp r9b, 0xa9
    je .copy_trail_utf8_3
    cmp r9b, 0xaf
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
    cmp byte [rsi + 1], 0x9a
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
    cmp r8b, 0xc2
    je .trail_utf8_c2
    cmp r8b, 0xe2
    je .trail_utf8_e2
    cmp r8b, 0xe3
    je .trail_utf8_e3
    cmp r8b, 0xe1
    je .trail_utf8_e1
    ; Non-whitespace after whitespace: error
    jmp .parse_error
.trail_utf8_c2:
    cmp byte [rsi + 1], 0xa0
    jne .parse_error
    add rsi, 2
    jmp .trail_loop
.trail_utf8_e2:
    movzx r9d, byte [rsi + 1]
    cmp r9b, 0x80
    je .trail_e2_80
    cmp r9b, 0x81
    jne .parse_error
    cmp byte [rsi + 2], 0x9f
    jne .parse_error
    add rsi, 3
    jmp .trail_loop
.trail_e2_80:
    movzx r9d, byte [rsi + 2]
    cmp r9b, 0x80
    jb .parse_error
    cmp r9b, 0x8a
    jbe .trail_utf8_3
    cmp r9b, 0xa8
    je .trail_utf8_3
    cmp r9b, 0xa9
    je .trail_utf8_3
    cmp r9b, 0xaf
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
    cmp byte [rsi + 1], 0x9a
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
    call int_alloc_raw
    mov [rbp - IB_OBJ], rax
    INIT_OBJ_RC rax
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyIntObject.compact], 0  ; GMP-backed
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt

    ; Parse with GMP
    mov rax, [rbp - IB_OBJ]
    INT_NEED_MPZ rax
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
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    INT_NEED_MPZ rax
    lea rsi, [rax + PyIntObject.mpz]
    call __gmpz_neg wrt ..plt
.no_negate:

    ; Free cleaned buffer
    mov rdi, [rbp - IB_BUF]
    call ap_free

    ; Try to normalize to SmallInt if small enough
    mov rax, [rbp - IB_OBJ]
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_get_si wrt ..plt
    mov rcx, rax

    ; Check if value fits in SmallInt range and roundtrips
    ; Save small int value now — rcx will be clobbered by call
    mov [rbp - IB_SIGN], rcx
    mov rdi, [rbp - IB_OBJ]
    INT_NEED_MPZ rdi
    lea rdi, [rdi + PyIntObject.mpz]
    mov rsi, rcx
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    jnz .return_gmp         ; doesn't roundtrip: keep GMP

    ; Fits in i64: free GMP object, return as SmallInt
    mov rdi, [rbp - IB_OBJ]
    INT_NEED_MPZ rdi
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
    INT_NEED_MPZ rdi
    lea rdi, [rdi + PyIntObject.mpz]
    call __gmpz_clear wrt ..plt
    mov rdi, [rbp - IB_OBJ]
    call ap_free
    jmp .parse_error

.digits_exceeded:
    ; Free cleaned buffer, then raise ValueError for digit limit
    mov rdi, [rbp - IB_BUF]
    call ap_free
    extern set_exception
    extern exc_ValueError_type
    SET_EXC exc_ValueError_type, "Exceeds the limit for integer string conversion"
    RET_NULL
    leave
    ret

.parse_error:
    ; Free cleaned buffer if allocated
    mov rdi, [rbp - IB_BUF]
    call ap_free
    RET_NULL
    leave
    ret

END_FUNC int_from_cstr_base


;; ============================================================================
;; int_base_str(rdi = int Value, esi = base 2..36, edx = 1 for uppercase)
;;   -> rax = ap_malloc'd NUL-terminated C string, '-' prefixed when negative
;;
;; hex(), oct(), bin() and the b/o/x/X format types all truncated a value too
;; wide for int64 -- hex(2**70) was "0x0" -- or refused it outright.  GMP can
;; render any base directly; a negative base asks it for uppercase digits.
;; ============================================================================
IBS_BASE  equ 8
IBS_UPPER equ 16
IBS_RSP   equ 24
IBS_FRAME equ 32            ; + 2 pushes = 48
DEF_FUNC int_base_str, IBS_FRAME
    push rbx
    push r12
    mov [rbp - IBS_BASE], rsi
    mov [rbp - IBS_UPPER], rdx
    ; GMP reaches SSE code that faults on a misaligned stack, and this is
    ; called from paths whose alignment differs.
    mov [rbp - IBS_RSP], rsp
    and rsp, -16

    V_UNPACK rdi, rdx
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .ibs_small

    mov rbx, rdi
    INT_NEED_MPZ rbx
    lea rdi, [rbx + PyIntObject.mpz]
    mov rsi, [rbp - IBS_BASE]
    call __gmpz_sizeinbase wrt ..plt
    lea rdi, [rax + 3]
    call ap_malloc
    mov r12, rax
    mov rdi, r12
    mov rsi, [rbp - IBS_BASE]
    cmp qword [rbp - IBS_UPPER], 0
    je .ibs_lower
    neg rsi                     ; a negative base gives uppercase digits
.ibs_lower:
    INT_NEED_MPZ rbx
    lea rdx, [rbx + PyIntObject.mpz]
    call __gmpz_get_str wrt ..plt
    mov rax, r12
    mov rsp, [rbp - IBS_RSP]
    pop r12
    pop rbx
    leave
    ret

.ibs_small:
    mov rbx, rdi
    mov edi, 72
    call ap_malloc
    mov r12, rax
    test rbx, rbx
    jnz .ibs_nonzero
    mov byte [r12], '0'
    mov byte [r12 + 1], 0
    mov rax, r12
    mov rsp, [rbp - IBS_RSP]
    pop r12
    pop rbx
    leave
    ret
.ibs_nonzero:
    mov r8, rbx
    xor r9d, r9d                ; negative?
    test r8, r8
    jns .ibs_abs
    mov r9d, 1
    neg r8
.ibs_abs:
    lea rdi, [r12 + 71]
    mov byte [rdi], 0
.ibs_digit:
    mov rax, r8
    xor edx, edx
    div qword [rbp - IBS_BASE]
    mov r8, rax
    cmp dl, 10
    jb .ibs_num
    sub dl, 10
    cmp qword [rbp - IBS_UPPER], 0
    je .ibs_alpha_lower
    add dl, 'A'
    jmp .ibs_put
.ibs_alpha_lower:
    add dl, 'a'
    jmp .ibs_put
.ibs_num:
    add dl, '0'
.ibs_put:
    dec rdi
    mov [rdi], dl
    test r8, r8
    jnz .ibs_digit
    test r9d, r9d
    jz .ibs_move
    dec rdi
    mov byte [rdi], '-'
.ibs_move:
    mov rsi, rdi
    mov rdi, r12
.ibs_shift:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .ibs_shifted
    inc rsi
    inc rdi
    jmp .ibs_shift
.ibs_shifted:
    mov rax, r12
    mov rsp, [rbp - IBS_RSP]
    pop r12
    pop rbx
    leave
    ret
END_FUNC int_base_str

;; ============================================================================
;; int_repr(PyObject *self) -> PyStrObject*
;; String representation. SmallInt uses snprintf, GMP uses gmpz_get_str.
;; Fails: 0
;; ============================================================================
IR_SAVED  equ 16            ; rbp less the two callee-saved pushes
IR_BUF    equ 32            ; 24-byte digit buffer, written backwards
IR_FRAME  equ 32            ; the frame is built by hand
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
    ; Extract int_value from PyIntSubclassObject.  It is a Value, so its own
    ; tag has to come out of it -- edx still describes the wrapper, which is
    ; a pointer, so a wrapped small int fell into the GMP path and had its
    ; encoded form dereferenced.  MyInt() with no argument wraps 0 and
    ; printing it crashed.
    mov rdi, [rdi + PyIntSubclassObject.int_value]
    V_UNPACK rdi, rdx
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
    INT_NEED_MPZ rbx
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
    INT_NEED_MPZ rbx
    lea rdx, [rbx + PyIntObject.mpz]
    call __gmpz_get_str wrt ..plt
    mov rdi, r12
    call str_from_cstr_heap
    mov rbx, rax               ; save str result (done with original obj)
    mov rdi, r12
    call ap_free               ; free C buffer
    mov rax, rbx               ; return str object
    mov edx, TAG_PTR
    lea rsp, [rbp - IR_SAVED] ; undo the alignment, back to the two pushes
    pop r12
    pop rbx
    pop rbp
    ret

.smallint:
    ; Direct SmallInt repr: manual int-to-string, no GMP allocation
    push rbp
    mov rbp, rsp
    sub rsp, IR_FRAME          ; 24 bytes buffer + alignment
    mov rax, rdi

    ; Convert int64 to decimal string in stack buffer
    ; Write digits backwards from buf[23], then reverse
    lea rdi, [rbp - IR_BUF]   ; rdi = buffer start
    xor ecx, ecx              ; ecx = 0 (negative flag)
    test rax, rax
    jns .si_positive
    neg rax
    mov ecx, 1                ; mark negative
.si_positive:
    ; rax = absolute value, ecx = negative flag
    lea rsi, [rbp - IR_BUF + 23]  ; rsi = write position, one past the last byte
    mov byte [rsi], 0          ; null terminator
    dec rsi

    mov r8d, 10
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
    SET_EXC exc_ValueError_type, "Exceeds the limit for integer string conversion"
    RET_NULL
    lea rsp, [rbp - IR_SAVED] ; undo the alignment, back to the two pushes
    pop r12
    pop rbx
    pop rbp
    ret
END_FUNC int_repr

