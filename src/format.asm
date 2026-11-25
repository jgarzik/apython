; format.asm - The format-spec mini-language.
;
; builtin_format_fn ignored its spec entirely and fell through to str(), and
; op_format_value had a partial float path that handled only precision and a
; type letter.  So format(255, "08b") returned "255", f"{5:>5}" returned "5",
; and f"{1234:_}" returned "1234" -- confident wrong answers on some of the
; most common formatting there is.
;
; The grammar implemented here is CPython's:
;
;   [[fill]align][sign][#][0][width][grouping][.precision][type]
;
; align  < > ^ =        fill defaults to a space, or to '0' after a leading 0
; sign   + - space      only meaningful for numbers
; #      alternate form: the 0b/0o/0x prefix
; group  , or _         inserted every three digits
; type   b o x X d n    integer
;        e E f F g G %  float
;        s              string
;
; The body is rendered first and padded afterwards, which is what makes '='
; alignment (pad between the sign and the digits) fall out naturally.

%include "macros.inc"
%include "object.inc"

extern str_new_heap
extern ap_malloc
extern obj_str
extern obj_as_index
extern int_fits_i64
extern float_format_spec
extern ap_memcpy
extern obj_decref
extern set_exception
extern exc_ValueError_type
extern str_type
extern int_type
extern bool_type
extern float_type
extern value_type

section .text

;; Parsed spec, kept in the caller's frame.
FS_FILL   equ 8          ; fill character
FS_ALIGN  equ 16         ; '<' '>' '^' '=' or 0 when unset
FS_SIGN   equ 24         ; '+' '-' ' '
FS_ALT    equ 32         ; the # flag
FS_ZERO   equ 40         ; a leading 0 was given
FS_WIDTH  equ 48
FS_GROUP  equ 56         ; ',' '_' or 0
FS_PREC   equ 64         ; -1 when unset
FS_TYPE   equ 72         ; type letter, or 0
FS_VALUE  equ 80
FS_BODY   equ 88         ; rendered body, a str object
FS_SIGNCH equ 96         ; the sign actually emitted, or 0
FS_SPECLEN equ 104       ; length of the spec as given
FS_OWNED  equ 112        ; a box V_PACK made for a wide int subclass, or 0
FS_CHBUF  equ 128        ; the eight bytes the `c` type encodes into
FS_SIGNGIVEN equ 136     ; 1 when a sign was actually written in the spec.
                         ; FS_SIGN defaults to '-', so it cannot answer this,
                         ; and `c` refuses an explicit sign of any kind.
FS_FILLGIVEN equ 144     ; 1 when a fill character was WRITTEN.  The `0` flag
                         ; supplies one only when none was, which FS_FILL
                         ; cannot answer for itself: it defaults to a space.
FS_PRINTF equ 160        ; 1 when the caller is str_mod rather than format().
                         ; The two mini-languages agree on everything except
                         ; what a precision means for an integer: format()
                         ; refuses one, printf zero-pads the digits to it.
FS_ZCOERCE equ 152       ; PEP 682's `z`: a result that rounds to zero loses
                         ; its sign.  Only a float presentation takes it.
FS_FRAME  equ 184           ; + 5 pushes = 224, 16-aligned

; The widest field this will build.  See .fs_after_width.
FS_MAX_WIDTH equ 0x10000000

section .bss
; Set by format_apply_spec_printf and read once, at the top of
; format_apply_spec, which zeroes it again immediately -- so a nested format
; (a __format__ that formats something of its own) cannot inherit it.
fs_printf_pending: resq 1
section .text

;; ============================================================================
;; format_apply_spec_printf(rdi = value Value, rsi = spec str) -> Value
;; Fails: 0
;;
;; format_apply_spec, with printf's reading of a precision on an integer
;; conversion.  `'%.3d' % 5` is '005' and `'%#.4x' % 255` is '0x00ff'; the
;; same spec written for format() is a ValueError, and stays one.
;;
;; str_mod has no integer path of its own -- it rewrites the printf spec into
;; a format() spec and calls here -- so this is where the one difference
;; between the two languages has to live.
;; ============================================================================
global format_apply_spec_printf
DEF_FUNC format_apply_spec_printf
    mov qword [rel fs_printf_pending], 1
    leave
    jmp format_apply_spec
END_FUNC format_apply_spec_printf

;; ============================================================================
;; format_apply_spec(rdi = value Value, rsi = spec str) -> Value (a str)
;; Fails: 0
;; ============================================================================
DEF_FUNC format_apply_spec, FS_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15
    ; Zeroed here and not where it is set: every arm reaches the release in
    ; .fs_body_int, and only the int-subclass arm assigns it, so a frame slot
    ; left holding whatever was on the stack was handed to obj_decref.
    mov qword [rbp - FS_OWNED], 0

    mov [rbp - FS_VALUE], rdi
    mov qword [rbp - FS_BODY], 0
    mov qword [rbp - FS_SIGNCH], 0
    mov rax, [rel fs_printf_pending]
    mov [rbp - FS_PRINTF], rax
    mov qword [rel fs_printf_pending], 0

    ; ---- defaults ----------------------------------------------------------
    mov qword [rbp - FS_FILL], ' '
    mov qword [rbp - FS_ALIGN], 0
    mov qword [rbp - FS_SIGN], '-'
    mov qword [rbp - FS_SIGNGIVEN], 0
    mov qword [rbp - FS_ALT], 0
    mov qword [rbp - FS_ZERO], 0
    mov qword [rbp - FS_WIDTH], 0
    mov qword [rbp - FS_GROUP], 0
    mov qword [rbp - FS_PREC], -1
    mov qword [rbp - FS_TYPE], 0
    mov qword [rbp - FS_FILLGIVEN], 0
    mov qword [rbp - FS_ZCOERCE], 0

    mov rbx, rsi                        ; spec str
    mov r12, [rbx + PyStrObject.ob_size]
    mov [rbp - FS_SPECLEN], r12
    lea r13, [rbx + PyStrObject.data]
    xor r14d, r14d                      ; position

    ; ---- [[fill]align] -----------------------------------------------------
    ; A two-character lookahead: any character followed by an alignment code
    ; is a fill.
    mov rax, r12
    sub rax, r14
    cmp rax, 2
    jl .fs_try_align_only
    movzx ecx, byte [r13 + r14 + 1]
    call .fs_is_align
    test eax, eax
    jz .fs_try_align_only
    movzx ecx, byte [r13 + r14]
    mov [rbp - FS_FILL], rcx
    mov qword [rbp - FS_FILLGIVEN], 1
    movzx ecx, byte [r13 + r14 + 1]
    mov [rbp - FS_ALIGN], rcx
    add r14, 2
    jmp .fs_after_align

.fs_try_align_only:
    cmp r14, r12
    jge .fs_after_align
    movzx ecx, byte [r13 + r14]
    call .fs_is_align
    test eax, eax
    jz .fs_after_align
    movzx ecx, byte [r13 + r14]
    mov [rbp - FS_ALIGN], rcx
    inc r14

.fs_after_align:
    ; ---- [sign] ------------------------------------------------------------
    cmp r14, r12
    jge .fs_after_sign
    movzx ecx, byte [r13 + r14]
    cmp cl, '+'
    je .fs_take_sign
    cmp cl, '-'
    je .fs_take_sign
    cmp cl, ' '
    jne .fs_after_sign
.fs_take_sign:
    mov [rbp - FS_SIGN], rcx
    mov qword [rbp - FS_SIGNGIVEN], 1
    inc r14

.fs_after_sign:
    ; ---- [z] ---------------------------------------------------------------
    ; PEP 682, 3.11: a result that rounds to zero is reported without its
    ; sign, so format(-0.0001, "z.2f") is '0.00' where a plain ".2f" gives
    ; '-0.00'.  It was not parsed at all, so `z` read as a type letter and
    ; every spec carrying one was "Unknown format code 'z'".
    cmp r14, r12
    jge .fs_after_zcoerce
    cmp byte [r13 + r14], 'z'
    jne .fs_after_zcoerce
    mov qword [rbp - FS_ZCOERCE], 1
    inc r14
.fs_after_zcoerce:

    ; ---- [#] ---------------------------------------------------------------
    cmp r14, r12
    jge .fs_after_alt
    cmp byte [r13 + r14], '#'
    jne .fs_after_alt
    mov qword [rbp - FS_ALT], 1
    inc r14

.fs_after_alt:
    ; ---- [0] ---------------------------------------------------------------
    cmp r14, r12
    jge .fs_after_zero
    cmp byte [r13 + r14], '0'
    jne .fs_after_zero
    mov qword [rbp - FS_ZERO], 1
    ; The `0` flag supplies a fill only when none was written.  CPython guards
    ; this with fill_char_specified, and without it `format(-7, "*^-05d")`
    ; answered '0-700': the 0 overwrote the '*' that was given two characters
    ; earlier.
    cmp qword [rbp - FS_FILLGIVEN], 0
    jne .fs_zero_keep_fill
    mov qword [rbp - FS_FILL], '0'
.fs_zero_keep_fill:
    cmp qword [rbp - FS_ALIGN], 0
    jne .fs_zero_taken
    mov qword [rbp - FS_ALIGN], '='
.fs_zero_taken:
    inc r14

.fs_after_zero:
    ; Zero padding is not a flag of its own in CPython: it IS fill '0' with
    ; align '=', which is what the `0` above supplies when nothing else did.
    ; Deriving it here rather than trusting the flag is what makes an explicit
    ; fill win -- `format(255, "*=06,")` pads with '*' and has nothing to
    ; group, where the flag alone zero-padded and then grouped the padding
    ; into '00,255'.
    mov qword [rbp - FS_ZERO], 0
    cmp qword [rbp - FS_FILL], '0'
    jne .fs_zero_settled
    cmp qword [rbp - FS_ALIGN], '='
    jne .fs_zero_settled
    mov qword [rbp - FS_ZERO], 1
.fs_zero_settled:
    ; ---- [width] -----------------------------------------------------------
    xor r15d, r15d
.fs_width_loop:
    cmp r14, r12
    jge .fs_after_width
    movzx ecx, byte [r13 + r14]
    cmp cl, '0'
    jb .fs_after_width
    cmp cl, '9'
    ja .fs_after_width
    imul r15, r15, 10
    jo .fs_too_many_digits
    sub rcx, '0'
    add r15, rcx
    jo .fs_too_many_digits
    inc r14
    jmp .fs_width_loop
.fs_after_width:
    ; A width is padding, and padding is a buffer.  CPython has no cap and
    ; simply asks the allocator, which answers MemoryError; ap_malloc has no
    ; way to answer at all -- it calls fatal_error -- so `"%*d" % (2**40, 5)`
    ; printed "Fatal: out of memory" and ended the process.  The cap is
    ; list_repeat's, 256M, and the divergence it buys is a MemoryError where
    ; CPython would have spent a quarter of a gigabyte building a field of
    ; spaces.
    cmp r15, FS_MAX_WIDTH
    ja .fs_width_too_big
    mov [rbp - FS_WIDTH], r15

    ; ---- [grouping] --------------------------------------------------------
    cmp r14, r12
    jge .fs_after_group
    movzx ecx, byte [r13 + r14]
    cmp cl, ','
    je .fs_take_group
    cmp cl, '_'
    jne .fs_after_group
.fs_take_group:
    mov [rbp - FS_GROUP], rcx
    inc r14

.fs_after_group:
    ; ---- [.precision] ------------------------------------------------------
    cmp r14, r12
    jge .fs_after_prec
    cmp byte [r13 + r14], '.'
    jne .fs_after_prec
    inc r14
    xor r15d, r15d
.fs_prec_loop:
    cmp r14, r12
    jge .fs_prec_done
    movzx ecx, byte [r13 + r14]
    cmp cl, '0'
    jb .fs_prec_done
    cmp cl, '9'
    ja .fs_prec_done
    imul r15, r15, 10
    jo .fs_too_many_digits
    sub rcx, '0'
    add r15, rcx
    jo .fs_too_many_digits
    inc r14
    jmp .fs_prec_loop
.fs_prec_done:
    ; CPython's precision is a C int, and it says so.
    cmp r15, 0x7FFFFFFF
    ja .fs_prec_too_big
    ; And a precision is a buffer, the same as a width: float_format_spec
    ; renders through snprintf, whose answer is an int, and a precision near
    ; INT_MAX makes it return -1 rather than a length.  The cap is the width's
    ; and the divergence is the same shape -- a MemoryError where CPython
    ; would have spent two gigabytes on decimal places.
    cmp r15, FS_MAX_WIDTH
    ja .fs_width_too_big
    mov [rbp - FS_PREC], r15

.fs_after_prec:
    ; ---- [type] ------------------------------------------------------------
    cmp r14, r12
    jge .fs_parsed
    ; The type is one CHARACTER, not one byte: format(0.0, "\u00e9") answered
    ; "Invalid format specifier" because the two bytes of the letter looked
    ; like a type followed by trailing junk.
    mov rdi, r13
    mov rsi, r14
    extern ucase_utf8_get
    call ucase_utf8_get
    mov [rbp - FS_TYPE], rax
    add r14, rcx
    cmp r14, r12
    jne .fs_bad_spec

.fs_parsed:
    ; ---- render the body ---------------------------------------------------
    mov rdi, [rbp - FS_VALUE]
    call value_type
    mov r15, rax                        ; the value's type

    ; A subclass formats as its base does: every arm below compares r15
    ; against an exact type, so format(F(2.5), ".2f") for `class F(float)`
    ; found no arm and fell out as "unsupported format string passed to
    ; object.__format__".  The family flags say which base to answer as.
    ; The family flags live on the BASE types too, so that a subclass
    ; inherits them: float_type itself carries TYPE_FLAG_FLOAT_SUBCLASS.
    ; Anything keyed off the flag alone therefore fires for the exact type as
    ; well, and unwrapping an immediate as if it were an instance reads a
    ; NaN-boxed double as an address.  Ask whether it IS one of the four
    ; first, and only then whether it derives from one.
    test r15, r15
    jz .fs_family_done
    lea rax, [rel complex_type]
    cmp r15, rax
    je .fs_family_done
    lea rax, [rel float_type]
    cmp r15, rax
    je .fs_family_done
    lea rax, [rel int_type]
    cmp r15, rax
    je .fs_family_done
    lea rax, [rel str_type]
    cmp r15, rax
    je .fs_family_done
    extern bool_type
    mov rdx, [r15 + PyTypeObject.tp_flags]
    lea rax, [rel bool_type]
    cmp r15, rax
    je .fs_bool

    test rdx, TYPE_FLAG_COMPLEX_SUBCLASS
    jz .fs_not_complex_sub
    lea r15, [rel complex_type]     ; complex_to_parts unwraps the value
    jmp .fs_family_done
.fs_not_complex_sub:
    test rdx, TYPE_FLAG_FLOAT_SUBCLASS
    jz .fs_not_float_sub
    lea r15, [rel float_type]
    ; The double lives inline in the instance, and the float arm below wants
    ; an immediate.
    mov rdi, [rbp - FS_VALUE]
    mov rax, [rdi + PyFloatObject.value]
    V_FROM_F64 rax, rcx
    mov [rbp - FS_VALUE], rax
    jmp .fs_family_done
.fs_not_int_sub:
    test rdx, TYPE_FLAG_STR_SUBCLASS
    jz .fs_family_done
    lea r15, [rel str_type]         ; a str subclass has str's layout
    jmp .fs_family_done
.fs_bool:
    ; A COMPLETELY empty spec is object.__format__, which is str(): CPython
    ; makes format(True) "True" and format(True, ">5") "    1", and this
    ; took the int path either way -- so f"{True}" printed 1.
    cmp qword [rbp - FS_SPECLEN], 0
    je .fs_body_str
    ; Otherwise bool formats as an int, which is what CPython does:
    ; format(True, "d") is "1".  Its value is a singleton, not an int, so it is unwrapped too.
    ; tp_flags is loaded BEFORE the jump here, because this falls straight
    ; into a test of rdx and nothing else on this path writes it -- it held
    ; whatever the caller had left in it.
    lea r15, [rel int_type]
.fs_not_float_sub:
    test rdx, TYPE_FLAG_INT_SUBCLASS
    jz .fs_not_int_sub
    lea r15, [rel int_type]
    mov rdi, [rbp - FS_VALUE]
    mov edx, TAG_PTR
    extern int_unwrap
    call int_unwrap
    ; V_PACK on a SmallInt outside +-2^50 ALLOCATES, and FS_VALUE is a slot
    ; this function neither owns nor releases: one boxed int leaked per
    ; format() of such a subclass instance.  Note whether it boxed, and give
    ; the box back once the body has been rendered.
    ;
    ; "It is a pointer now" does not say it boxed.  A value past int64 comes
    ; out of int_unwrap as the GMP int the instance WRAPS, borrowed, and
    ; V_PACK hands a pointer straight through -- so releasing it took a
    ; reference from the instance on every format(), and the second one
    ; freed its value.  Only a SmallInt can have been boxed; the tag is
    ; parked in FS_OWNED across the pack, which clobbers its register.
    mov [rbp - FS_OWNED], rdx
    V_PACK rdi, rdx
    mov [rbp - FS_VALUE], rdi
    cmp qword [rbp - FS_OWNED], TAG_SMALLINT
    mov qword [rbp - FS_OWNED], 0       ; mov leaves the flags alone
    jne .fs_family_done         ; the wrapped GMP int: not ours
    V_TEST_PTR rdi, rax
    ja .fs_family_done          ; still an immediate: nothing was allocated
    mov [rbp - FS_OWNED], rdi
.fs_family_done:

    mov rcx, [rbp - FS_TYPE]
    ; complex is asked first: format(1+2j, 's') is a ValueError in CPython, so
    ; it must not reach the 's' short-circuit below.
    extern complex_type
    lea rax, [rel complex_type]
    cmp r15, rax
    je .fs_typed
    cmp rcx, 's'
    je .fs_str_code             ; not straight to the body: a string
    test rcx, rcx               ; presentation has three flags to refuse
    jnz .fs_typed

    ; No type letter: a str formats as a string, a number as itself.
    lea rax, [rel str_type]
    cmp r15, rax
    je .fs_str_code
    lea rax, [rel float_type]
    cmp r15, rax
    je .fs_body_float
    extern complex_type
    lea rax, [rel complex_type]
    cmp r15, rax
    je .fs_body_complex
    ; Through .fs_int_code, not straight to the body: an integer presentation
    ; takes no precision whether or not a letter was written, so
    ; format(255, "#020.7") has to be refused here as well.
    lea rax, [rel int_type]
    cmp r15, rax
    je .fs_int_code
    lea rax, [rel bool_type]
    cmp r15, rax
    je .fs_int_code
    ; Anything else uses object.__format__, which accepts only an empty
    ; spec.  format(None, ">5") padded None instead of raising.
    cmp qword [rbp - FS_SPECLEN], 0
    jne .fs_unsupported
    jmp .fs_body_str

.fs_bad_numeric_type:
    ; A numeric type letter on a non-number: format("abc", "f") converted the
    ; string through float_to_f64 and printed 0.000000.  CPython names both
    ; the code and the type, and this named neither.
    jmp .fs_unknown_code

.fs_unknown_code:
    ; "Unknown format code 'x' for object of type 'str'" -- the code is one
    ; character, so the buffer is built here rather than in a raiser.
    sub rsp, 128
    mov rdi, rsp
    CSTRING rsi, "Unknown format code '"
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rcx, [rbp - FS_TYPE]
    cmp rcx, 32
    jbe .fs_uc_escape
    cmp rcx, 128
    jae .fs_uc_escape
    mov [rax], cl
    mov byte [rax + 1], 0
    lea rdi, [rax + 1]
    jmp .fs_uc_typename
.fs_uc_escape:
    ; Outside (32, 128) CPython writes \x and the hex, unpadded --
    ; unknown_presentation_type() in Objects/stringlib/unicode_format.h.
    ; Emitting the raw byte instead made a tab or a NUL vanish from the
    ; message, and a non-ASCII letter arrive as half of its encoding.
    mov rdi, rax
    CSTRING rsi, "\x"
    call rbt_append_cstr
    mov r11, [rbp - FS_TYPE]
    mov ecx, 60                         ; the top nibble's shift
    xor r9d, r9d                        ; nothing emitted yet
.fs_uc_nibble:
    mov rdx, r11
    shr rdx, cl
    and edx, 15
    jnz .fs_uc_digit
    test r9d, r9d
    jz .fs_uc_next                      ; a leading zero
.fs_uc_digit:
    mov r9d, 1
    cmp edx, 10
    jb .fs_uc_dec
    add edx, 'a' - 10
    jmp .fs_uc_put
.fs_uc_dec:
    add edx, '0'
.fs_uc_put:
    mov [rax], dl
    inc rax
.fs_uc_next:
    sub ecx, 4
    jns .fs_uc_nibble
    test r9d, r9d
    jnz .fs_uc_zdone
    mov byte [rax], '0'                 ; the code point was 0
    inc rax
.fs_uc_zdone:
    mov byte [rax], 0
    mov rdi, rax
.fs_uc_typename:
    CSTRING rsi, "' for object of type '"
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [r15 + PyTypeObject.tp_name]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "'"
    call rbt_append_cstr
    extern exc_ValueError_type
    lea rdi, [rel exc_ValueError_type]
    mov rsi, rsp
    extern set_exception
    call set_exception
    jmp .fs_fail

.fs_unsupported:
    mov rsi, [rbp - FS_VALUE]
    CSTRING rdi, `unsupported format string passed to \x01.__format__`
    call set_type_error_with_name
    jmp .fs_fail

.fs_typed:
    ; complex is checked before the 's' arm: format(1+2j, 's') is a ValueError
    ; in CPython, not a string.  The accepted letters are exactly e E f F g G n.
    lea rax, [rel complex_type]
    cmp r15, rax
    jne .fs_typed_not_complex
    test rcx, rcx
    jz .fs_body_complex             ; no type letter: repr, handled there
    cmp rcx, 'e'
    je .fs_body_complex
    cmp rcx, 'E'
    je .fs_body_complex
    cmp rcx, 'f'
    je .fs_body_complex
    cmp rcx, 'F'
    je .fs_body_complex
    cmp rcx, 'g'
    je .fs_body_complex
    cmp rcx, 'G'
    je .fs_body_complex
    cmp rcx, 'n'
    je .fs_body_complex
    jmp .fs_unknown_code
.fs_typed_not_complex:
    ; A numeric type letter needs a number.
    cmp rcx, 's'
    je .fs_str_code
    lea rax, [rel str_type]
    cmp r15, rax
    je .fs_bad_numeric_type

    ; `,` names a thousands separator, and a base that is not ten has no
    ; thousands: CPython refuses it before formatting anything.  `_` is
    ; allowed on all of them and groups in fours.
    cmp qword [rbp - FS_GROUP], ','
    jne .fs_group_ok
    cmp rcx, 'b'
    je .fs_bad_group
    cmp rcx, 'o'
    je .fs_bad_group
    cmp rcx, 'x'
    je .fs_bad_group
    cmp rcx, 'X'
    je .fs_bad_group
.fs_group_ok:
    ; `c` refuses BOTH separators, where a base only refuses the comma -- and
    ; so does `n`, which takes its separator from the locale.
    cmp rcx, 'c'
    je .fs_no_sep_at_all
    cmp rcx, 'n'
    jne .fs_type_ok
.fs_no_sep_at_all:
    cmp qword [rbp - FS_GROUP], 0
    jne .fs_bad_group
.fs_type_ok:
    ; An INTEGER presentation needs an integer.  This is asked after the
    ; separator checks, which CPython performs first -- format(0.0, ",x")
    ; is "Cannot specify ',' with 'x'." and not a complaint about the type
    ; -- and before the precision check, so format(1.5, ".0d") is "Unknown
    ; format code 'd' for object of type 'float'".
    ;
    ; Reaching the int body with a float in hand produced "'float' object
    ; cannot be interpreted as an integer" instead, from far enough away
    ; that the spec was not mentioned at all.
    ;
    ; `n` is not in this list: it is the one code both families accept, and
    ; CPython formats a float with it as a float.
    lea rax, [rel float_type]
    cmp r15, rax
    jne .fs_not_float_value
    cmp rcx, 'b'
    je .fs_bad_numeric_type
    cmp rcx, 'o'
    je .fs_bad_numeric_type
    cmp rcx, 'x'
    je .fs_bad_numeric_type
    cmp rcx, 'X'
    je .fs_bad_numeric_type
    cmp rcx, 'd'
    je .fs_bad_numeric_type
    cmp rcx, 'c'
    je .fs_bad_numeric_type
    cmp rcx, 'n'
    je .fs_body_float           ; a float formats as a float under `n`
.fs_not_float_value:
    cmp rcx, 'b'
    je .fs_int_code
    cmp rcx, 'o'
    je .fs_int_code
    cmp rcx, 'x'
    je .fs_int_code
    cmp rcx, 'X'
    je .fs_int_code
    cmp rcx, 'd'
    je .fs_int_code
    cmp rcx, 'n'
    je .fs_int_code
    cmp rcx, 'c'
    je .fs_body_char

    ; Every remaining letter must be a real float code.  This fell through to
    ; .fs_body_float for ANY of them, so format(42, "Z") answered '42' where
    ; CPython raises -- and a mistyped spec formatted silently, which is how
    ; one is usually found.
    cmp rcx, 'e'
    je .fs_body_float
    cmp rcx, 'E'
    je .fs_body_float
    cmp rcx, 'f'
    je .fs_body_float
    cmp rcx, 'F'
    je .fs_body_float
    cmp rcx, 'g'
    je .fs_body_float
    cmp rcx, 'G'
    je .fs_body_float
    cmp rcx, '%'
    je .fs_body_float
    jmp .fs_unknown_code

.fs_int_code:
    ; `z` is a float thing: CPython names the family it was asked of.
    cmp qword [rbp - FS_ZCOERCE], 0
    jne .fs_z_on_int
    ; An integer presentation takes no precision.  CPython refuses it rather
    ; than ignoring it, and `n` is an integer presentation for this purpose.
    cmp qword [rbp - FS_PREC], -1
    je .fs_body_int
    cmp qword [rbp - FS_PRINTF], 0
    je .fs_int_precision
    jmp .fs_body_int

.fs_int_precision:
    extern exc_ValueError_type
    FAIL exc_ValueError_type, \
          "Precision not allowed in integer format specifier", .fs_fail

.fs_z_on_int:
    FAIL exc_ValueError_type, \
          "Negative zero coercion (z) not allowed in integer format specifier", .fs_fail
.fs_z_on_str:
    FAIL exc_ValueError_type, \
          "Negative zero coercion (z) not allowed in string format specifier", .fs_fail

.fs_str_code:
    cmp qword [rbp - FS_ZCOERCE], 0
    jne .fs_z_on_str
    ; Everything below is format()'s rule and NOT printf's.  `%s` takes any
    ; object and str()s it, and takes a sign, an alternate form and a '0'
    ; flag and ignores all three -- so `'%+5s' % 'x'` and `'%s' % (1, 2)` are
    ; both legal where the same spec written for format() is not.
    cmp qword [rbp - FS_PRINTF], 0
    jne .fs_body_str
    ; `s` is the STRING presentation, so it wants a string.  CPython says
    ; "Unknown format code 's' for object of type 'int'"; this reached the
    ; body and rendered the number, because the 's' arm short-circuited
    ; straight there before any of these checks existed.
    cmp qword [rbp - FS_TYPE], 's'
    jne .fs_str_typed_ok
    lea rax, [rel str_type]
    cmp r15, rax
    je .fs_str_typed_ok
    test qword [r15 + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .fs_unknown_code
.fs_str_typed_ok:
    cmp qword [rbp - FS_SIGNGIVEN], 0
    jne .fs_sign_on_str
    cmp qword [rbp - FS_ALT], 0
    jne .fs_alt_on_str
    cmp qword [rbp - FS_ALIGN], '='
    je .fs_equals_on_str
    jmp .fs_body_str

.fs_sign_on_str:
    FAIL exc_ValueError_type, "Sign not allowed in string format specifier", .fs_fail
.fs_alt_on_str:
    FAIL exc_ValueError_type, \
          "Alternate form (#) not allowed in string format specifier", .fs_fail
.fs_equals_on_str:
    FAIL exc_ValueError_type, \
          "'=' alignment not allowed in string format specifier", .fs_fail

.fs_bad_group:
    ; "Cannot specify ',' with 'x'." -- the type letter goes in.
    sub rsp, 64
    mov rdi, rsp
    CSTRING rsi, "Cannot specify '"
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rcx, [rbp - FS_GROUP]
    mov [rax], cl
    mov byte [rax + 1], 0x27
    mov byte [rax + 2], 0
    lea rdi, [rax + 3]
    mov rdi, rax
    add rdi, 2
    CSTRING rsi, " with '"
    call rbt_append_cstr
    mov rcx, [rbp - FS_TYPE]
    mov [rax], cl
    mov byte [rax + 1], 0x27        ; a closing quote
    mov byte [rax + 2], '.'
    mov byte [rax + 3], 0
    lea rdi, [rel exc_ValueError_type]
    mov rsi, rsp
    call set_exception
    jmp .fs_fail

.fs_body_char:
    ; `c` is the character the number names, and CPython refuses every flag
    ; that only makes sense for a number beside it: a sign, an alternate form,
    ; a separator and a precision.
    ;
    ; A float never reaches the integer formatter at all in CPython, so it
    ; gets the type's own complaint rather than the index protocol's.
    lea rax, [rel float_type]
    cmp r15, rax
    je .fs_bad_numeric_type
    cmp qword [rbp - FS_SIGNGIVEN], 0
    jne .fs_char_sign
    cmp qword [rbp - FS_ALT], 0
    jne .fs_char_alt
    cmp qword [rbp - FS_PREC], -1
    jne .fs_char_prec
    mov rdi, [rbp - FS_VALUE]
    V_UNPACK rdi, rdx
    extern obj_as_index
    call obj_as_index
    ERR_M1 .fs_fail
    test rax, rax
    jl .fs_char_range
    cmp rax, 0x110000
    jae .fs_char_range
    lea rdi, [rbp - FS_CHBUF]
    extern ucase_utf8_put
    call ucase_utf8_put         ; eax already holds the code point; ecx = width
    lea rdi, [rbp - FS_CHBUF]
    movsxd rsi, ecx
    call str_new_heap
    test rax, rax
    jz .fs_failed
    mov [rbp - FS_BODY], rax
    jmp .fs_pad

.fs_char_sign:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "Sign not allowed with integer format specifier 'c'"
    call set_exception
    jmp .fs_fail
.fs_char_alt:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "Alternate form (#) not allowed with integer format specifier 'c'"
    call set_exception
    jmp .fs_fail
.fs_char_prec:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "Precision not allowed in integer format specifier"
    call set_exception
    jmp .fs_fail
.fs_char_range:
    extern exc_OverflowError_type
    lea rdi, [rel exc_OverflowError_type]
    CSTRING rsi, "%c arg not in range(0x110000)"
    call set_exception
    jmp .fs_fail

.fs_body_str:
    mov rdi, [rbp - FS_VALUE]
    call obj_str
    V_UNPACK rax, rdx
    test edx, edx
    jz .fs_failed
    mov [rbp - FS_BODY], rax
    ; A precision truncates a string, and it counts characters: cutting at a
    ; byte offset would split a multi-byte one in half.
    mov rcx, [rbp - FS_PREC]
    test rcx, rcx
    jl .fs_pad
    cmp rcx, [rax + PyStrObject.ob_length]
    jge .fs_pad
    push rax
    mov rdi, rax
    mov rsi, rcx
    extern str_cp_offset
    call str_cp_offset
    mov rsi, rax
    mov rdi, [rsp]
    add rdi, PyStrObject.data
    call str_new_heap
    mov [rbp - FS_BODY], rax
    pop rdi
    call obj_decref
    jmp .fs_pad

.fs_body_float:
    call format_float_body
    mov [rbp - FS_BODY], rax
    call fs_apply_grouping
    jmp .fs_pad

.fs_body_int:
    call format_int_body
    ERR_NULL .fs_fail
    mov [rbp - FS_BODY], rax
    call fs_apply_grouping
    call fs_printf_precision
    mov rdi, [rbp - FS_OWNED]
    test rdi, rdi
    jz .fs_pad
    mov qword [rbp - FS_OWNED], 0
    push rax
    sub rsp, 8
    call obj_decref             ; the box V_PACK made for a wide subclass
    add rsp, 8
    pop rax
    jmp .fs_pad

.fs_body_complex:
    ; CPython rejects these two for a complex before it formats anything, and
    ; the messages are its own.
    cmp qword [rbp - FS_ZERO], 0
    jne .fs_complex_zero_pad
    cmp qword [rbp - FS_ALIGN], '='
    je .fs_complex_equals_align
    call format_complex_body
    mov [rbp - FS_BODY], rax
    jmp .fs_pad

.fs_too_many_digits:
    FAIL exc_ValueError_type, "Too many decimal digits in format string", .fs_fail
.fs_prec_too_big:
    FAIL exc_ValueError_type, "precision too big", .fs_fail
.fs_width_too_big:
    extern exc_MemoryError_type
    FAIL exc_MemoryError_type, "", .fs_fail
.fs_complex_zero_pad:
    FAIL exc_ValueError_type, "Zero padding is not allowed in complex format specifier", .fs_fail
.fs_complex_equals_align:
    FAIL exc_ValueError_type, "'=' alignment flag is not allowed in complex format specifier", .fs_fail

    ; ---- pad to width ------------------------------------------------------
.fs_pad:
    ; A width counts characters.  r12 stays the body's byte length -- it is
    ; what gets copied -- but the comparison and the padding count are in code
    ; points, and the buffer is the body's bytes plus that many ASCII pads.
    mov rbx, [rbp - FS_BODY]
    mov r12, [rbx + PyStrObject.ob_size]
    mov rax, [rbx + PyStrObject.ob_length]
    mov r13, [rbp - FS_WIDTH]
    cmp rax, r13
    jge .fs_return_body

    mov r14, r13
    sub r14, rax                        ; total padding, in characters
    mov r13, r12
    add r13, r14                        ; the buffer, in bytes

    ; Default alignment: '>' for numbers, '<' for everything else.
    mov rcx, [rbp - FS_ALIGN]
    test rcx, rcx
    jnz .fs_have_align
    mov rcx, '<'
    mov rax, [rbp - FS_TYPE]
    test rax, rax
    jz .fs_align_by_value
    cmp rax, 's'
    je .fs_have_align
    mov rcx, '>'
    jmp .fs_have_align
.fs_align_by_value:
    mov rdi, [rbp - FS_VALUE]
    call value_type
    lea rdx, [rel str_type]
    cmp rax, rdx
    je .fs_have_align_lt
    mov rcx, '>'
    jmp .fs_have_align
.fs_align_by_value_str:
.fs_have_align_lt:
    mov rcx, '<'
.fs_have_align:
    mov [rbp - FS_ALIGN], rcx

    ; Build the padded result.
    mov rdi, r13
    add rdi, PyStrObject.data + 8
    call ap_malloc
    mov r15, rax
    mov qword [r15 + PyObject.ob_refcnt], 1
    lea rcx, [rel str_type]
    mov [r15 + PyObject.ob_type], rcx
    mov qword [r15 + PyStrObject.ob_hash], -1
    mov [r15 + PyStrObject.ob_size], r13
    mov [r15 + PyStrObject.ob_length], r13   ; corrected once the bytes are in

    mov rcx, [rbp - FS_ALIGN]
    cmp rcx, '<'
    je .fs_pad_left_aligned
    cmp rcx, '^'
    je .fs_pad_center
    cmp rcx, '='
    je .fs_pad_after_sign

    ; '>' : all padding first
    lea rdi, [r15 + PyStrObject.data]
    mov rsi, r14
    call .fs_fill_run
    lea rdi, [r15 + PyStrObject.data]
    add rdi, r14
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, r12
    call ap_memcpy
    jmp .fs_pad_done

.fs_pad_left_aligned:
    lea rdi, [r15 + PyStrObject.data]
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, r12
    call ap_memcpy
    lea rdi, [r15 + PyStrObject.data]
    add rdi, r12
    mov rsi, r14
    call .fs_fill_run
    jmp .fs_pad_done

.fs_pad_center:
    mov rax, r14
    shr rax, 1                          ; left half, rounded down
    push rax
    lea rdi, [r15 + PyStrObject.data]
    mov rsi, rax
    call .fs_fill_run
    pop rax
    push rax
    lea rdi, [r15 + PyStrObject.data]
    add rdi, rax
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, r12
    call ap_memcpy
    pop rax
    lea rdi, [r15 + PyStrObject.data]
    add rdi, rax
    add rdi, r12
    mov rsi, r14
    sub rsi, rax
    call .fs_fill_run
    jmp .fs_pad_done

.fs_pad_after_sign:
    ; Padding goes between the sign (and any 0x prefix) and the digits.
    mov r8, [rbp - FS_SIGNCH]
    lea rdi, [r15 + PyStrObject.data]
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, r8
    test r8, r8
    jz .fs_eq_no_prefix
    call ap_memcpy
.fs_eq_no_prefix:
    lea rdi, [r15 + PyStrObject.data]
    add rdi, r8
    mov rsi, r14
    call .fs_fill_run
    lea rdi, [r15 + PyStrObject.data]
    add rdi, r8
    add rdi, r14
    lea rsi, [rbx + PyStrObject.data]
    add rsi, r8
    mov rdx, r12
    sub rdx, r8
    call ap_memcpy

.fs_pad_done:
    lea rcx, [r15 + PyStrObject.data]
    add rcx, r13
    mov qword [rcx], 0                  ; NUL plus padding for ap_strcmp
    mov rdi, r15
    extern str_set_length
    call str_set_length
    mov rdi, rbx
    call obj_decref
    mov rax, r15
    jmp .fs_return

.fs_return_body:
    mov rax, [rbp - FS_BODY]

.fs_return:
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.fs_fail:
    ; The error exit for everything this function refuses itself.  Several
    ; sites build their message in space carved below the saved registers,
    ; so rsp goes back first; and the int-subclass arm may have left its box
    ; in FS_OWNED, which only .fs_body_int released.
    lea rsp, [rbp - FS_FRAME - 40]
    mov rdi, [rbp - FS_OWNED]
    test rdi, rdi
    jz .fs_failed
    mov qword [rbp - FS_OWNED], 0
    call obj_decref
.fs_failed:
    RET_NULL
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.fs_bad_spec:
    ; CPython names both the spec and the type: "Invalid format specifier
    ; '*#012' for object of type 'int'".  This named neither, so the one
    ; message a mistyped spec produces said nothing about what was mistyped.
    ; r15 does not hold the value's type yet: it is assigned after the parse,
    ; and this is reached from inside it.
    mov rdi, [rbp - FS_VALUE]
    extern value_type
    call value_type
    mov r14, rax                ; the parse is over; r14 is free

    ; A type with no __format__ of its own never gets this far in CPython:
    ; format(obj, spec) calls type(obj).__format__, and object's refuses any
    ; non-empty spec without looking at it.  So the message for a list is
    ; "unsupported format string passed to list.__format__" and not a report
    ; about the spec, however malformed the spec is.
    lea rax, [rel str_type]
    cmp r14, rax
    je .fs_bad_spec_report
    lea rax, [rel int_type]
    cmp r14, rax
    je .fs_bad_spec_report
    lea rax, [rel bool_type]
    cmp r14, rax
    je .fs_bad_spec_report
    lea rax, [rel float_type]
    cmp r14, rax
    je .fs_bad_spec_report
    lea rax, [rel complex_type]
    cmp r14, rax
    jne .fs_unsupported
.fs_bad_spec_report:
    sub rsp, 256
    mov rdi, rsp
    CSTRING rsi, "Invalid format specifier '"
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rbx + PyStrObject.data]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "' for object of type '"
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [r14 + PyTypeObject.tp_name]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "'"
    call rbt_append_cstr
    lea rdi, [rel exc_ValueError_type]
    mov rsi, rsp
    call set_exception
    jmp .fs_fail

;; rdi = destination, rsi = count.  Writes the fill character.
.fs_fill_run:
    test rsi, rsi
    jle .fs_fill_done
    mov rax, [rbp - FS_FILL]
    xor ecx, ecx
.fs_fill_loop:
    mov [rdi + rcx], al
    inc rcx
    cmp rcx, rsi
    jl .fs_fill_loop
.fs_fill_done:
    ret

;; ecx = character; returns eax = 1 when it is an alignment code.
.fs_is_align:
    cmp cl, '<'
    je .fs_align_yes
    cmp cl, '>'
    je .fs_align_yes
    cmp cl, '^'
    je .fs_align_yes
    cmp cl, '='
    je .fs_align_yes
    xor eax, eax
    ret
.fs_align_yes:
    mov eax, 1
    ret
END_FUNC format_apply_spec

;; ============================================================================
;; format_int_body -> rax = str, the digits with sign, prefix and grouping
;; Fails: 0
;;
;; Reads the parsed spec out of the caller's frame, so it is a local helper of
;; format_apply_spec rather than a general entry point.  FS_SIGNCH is set to
;; the number of leading characters that '=' alignment must keep in front of
;; the padding.
;; ============================================================================
; The digit buffer is indexed upward from its base, so its *base* must sit
; low enough that the whole thing stays below rbp: [rbp-136, rbp-8).  Putting
; the base at rbp-8 let nine digits or more run over the saved registers.
FIB_BUF   equ 136        ; 128 bytes of digits, for a value that fits int64
FIB_LEN   equ 144
FIB_NEG   equ 152
FIB_HEAP  equ 160        ; heap digit buffer to free, or 0 (wide values)
FIB_OUTSZ equ 168        ; bytes reserved for the assembled output
FIB_FRAME equ 200            ; + 5 pushes = 240, 16-aligned

DEF_FUNC_LOCAL format_int_body, FIB_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rbp                        ; our frame

    ; The caller's frame holds the spec.  rbp of format_apply_spec is the
    ; saved rbp at [rbp].
    mov r14, [rbp]                      ; caller's rbp
    mov qword [rbp - FIB_HEAP], 0

    ; Value -> i64.  A value too wide for int64 is out of scope for the
    ; non-decimal bases here; base 10 goes through str() instead.
    mov rdi, [r14 - FS_VALUE]
    V_UNPACK rdi, rdx
    push rdi
    push rdx
    call int_fits_i64
    pop rdx
    pop rdi
    test eax, eax
    jz .fib_wide
    call obj_as_index
    ERR_M1 .fib_fail
    mov r12, rax                        ; the value

    ; base and digit set from the type letter
    mov r13d, 10
    mov rcx, [r14 - FS_TYPE]
    cmp rcx, 'b'
    je .fib_base2
    cmp rcx, 'o'
    je .fib_base8
    cmp rcx, 'x'
    je .fib_base16
    cmp rcx, 'X'
    je .fib_base16
    jmp .fib_have_base
.fib_base2:
    mov r13d, 2
    jmp .fib_have_base
.fib_base8:
    mov r13d, 8
    jmp .fib_have_base
.fib_base16:
    mov r13d, 16
.fib_have_base:

    mov qword [rbp - FIB_NEG], 0
    test r12, r12
    jns .fib_positive
    mov qword [rbp - FIB_NEG], 1
    neg r12
.fib_positive:

    ; Digits, least significant first, into a scratch buffer.
    lea rbx, [rbp - FIB_BUF]
    xor ecx, ecx
    test r12, r12
    jnz .fib_digits
    mov byte [rbx], '0'
    mov ecx, 1
    jmp .fib_digits_done
.fib_digits:
    mov rax, r12
    xor edx, edx
    div r13
    mov r12, rax
    cmp dl, 10
    jb .fib_digit_num
    add dl, 'a' - 10
    mov rax, [r14 - FS_TYPE]
    cmp rax, 'X'
    jne .fib_digit_store
    add dl, 'A' - 'a'
    jmp .fib_digit_store
.fib_digit_num:
    add dl, '0'
.fib_digit_store:
    mov [rbx + rcx], dl
    inc rcx
    test r12, r12
    jnz .fib_digits
.fib_digits_done:
    mov [rbp - FIB_LEN], rcx

.fib_assemble:
    ; Assemble: sign, prefix, grouped digits (reversed).  The output is sized
    ; from the digit count -- grouping adds one separator per three digits --
    ; because a fixed 256-byte buffer overflowed the stack on any value with
    ; more than about 250 digits.
    mov rax, [rbp - FIB_LEN]
    mov rcx, rax
    shr rcx, 1
    add rax, rcx
    add rax, 64
    and rax, -16
    mov [rbp - FIB_OUTSZ], rax
    sub rsp, rax
    mov rdi, rsp
    xor r8d, r8d                        ; output length

    ; sign
    cmp qword [rbp - FIB_NEG], 0
    je .fib_sign_positive
    mov byte [rdi], '-'
    inc r8
    jmp .fib_sign_done
.fib_sign_positive:
    mov rax, [r14 - FS_SIGN]
    cmp rax, '+'
    je .fib_sign_plus
    cmp rax, ' '
    je .fib_sign_space
    jmp .fib_sign_done
.fib_sign_plus:
    mov byte [rdi], '+'
    inc r8
    jmp .fib_sign_done
.fib_sign_space:
    mov byte [rdi], ' '
    inc r8
.fib_sign_done:

    ; alternate-form prefix
    cmp qword [r14 - FS_ALT], 0
    je .fib_prefix_done
    mov rax, [r14 - FS_TYPE]
    cmp rax, 'b'
    je .fib_pfx_b
    cmp rax, 'o'
    je .fib_pfx_o
    cmp rax, 'x'
    je .fib_pfx_x
    cmp rax, 'X'
    je .fib_pfx_X
    jmp .fib_prefix_done
.fib_pfx_b:
    mov byte [rdi + r8], '0'
    mov byte [rdi + r8 + 1], 'b'
    add r8, 2
    jmp .fib_prefix_done
.fib_pfx_o:
    mov byte [rdi + r8], '0'
    mov byte [rdi + r8 + 1], 'o'
    add r8, 2
    jmp .fib_prefix_done
.fib_pfx_x:
    mov byte [rdi + r8], '0'
    mov byte [rdi + r8 + 1], 'x'
    add r8, 2
    jmp .fib_prefix_done
.fib_pfx_X:
    mov byte [rdi + r8], '0'
    mov byte [rdi + r8 + 1], 'X'
    add r8, 2
.fib_prefix_done:
    mov [rbp - FIB_NEG], r8             ; reuse: chars before the digits

    ; digits, most significant first.  The grouping is NOT done here: it is
    ; format_group_body's, which the float path needs too and which is the
    ; only place that knows how a zero pad and a separator interact.
    mov rcx, [rbp - FIB_LEN]
.fib_emit:
    test rcx, rcx
    jz .fib_emit_done
    dec rcx
    movzx eax, byte [rbx + rcx]
    mov [rdi + r8], al
    inc r8
    jmp .fib_emit
.fib_emit_done:

    mov rsi, r8
    mov r13, [rbp - FIB_NEG]
    call str_new_heap
    add rsp, [rbp - FIB_OUTSZ]
    mov [r14 - FS_SIGNCH], r13
    mov rcx, [rbp - FIB_HEAP]
    test rcx, rcx
    jz .fib_no_heap
    push rax
    mov rdi, rcx
    call ap_free
    pop rax
    jmp .fib_no_heap
.fib_fail:
    ; Both refusals come before a heap digit buffer exists.
    xor eax, eax
.fib_no_heap:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.fib_wide:
    ; Too wide for int64.  Decimal comes straight from str(); the other bases
    ; used to be refused outright ("integer too large for this format"), so
    ; f"{2**70:x}" raised.  int_base_str renders any of them through GMP; the
    ; digits are reversed into FIB_BUF so the assembly stage below -- sign,
    ; prefix, grouping, padding -- runs unchanged.
    mov rax, [r14 - FS_TYPE]
    xor edx, edx                        ; uppercase?
    mov esi, 10
    test rax, rax
    jz .fib_wb_go
    cmp rax, 'd'
    je .fib_wb_go
    cmp rax, 'n'
    je .fib_wb_go
    mov esi, 2
    cmp rax, 'b'
    je .fib_wb_go
    mov esi, 8
    cmp rax, 'o'
    je .fib_wb_go
    mov esi, 16
    cmp rax, 'x'
    je .fib_wb_go
    mov edx, 1
    cmp rax, 'X'
    je .fib_wb_go
    jmp .fib_wide_error
.fib_wb_go:
    mov rdi, [r14 - FS_VALUE]
    extern int_base_str
    call int_base_str
    mov r12, rax                        ; the C string

    mov qword [rbp - FIB_NEG], 0
    mov rsi, r12
    cmp byte [rsi], '-'
    jne .fib_wb_scan
    mov qword [rbp - FIB_NEG], 1
    inc rsi
.fib_wb_scan:
    xor ecx, ecx
.fib_wb_len:
    cmp byte [rsi + rcx], 0
    je .fib_wb_reverse
    inc rcx
    jmp .fib_wb_len
.fib_wb_reverse:
    ; The digits go least-significant first into FIB_BUF, which holds 128 --
    ; enough for any int64 but not for a GMP value, whose string is
    ; unbounded.  format(10**140, 'd') wrote past the saved rbp.
    lea rbx, [rbp - FIB_BUF]
    cmp rcx, 120
    jb .fib_wb_have_buf
    push rcx
    push rsi
    lea rdi, [rcx + 16]
    extern ap_malloc
    call ap_malloc
    mov [rbp - FIB_HEAP], rax
    mov rbx, rax
    pop rsi
    pop rcx
.fib_wb_have_buf:
    xor edx, edx
.fib_wb_rev_loop:
    cmp rdx, rcx
    jge .fib_wb_reversed
    mov r8, rcx
    sub r8, rdx
    dec r8
    mov al, [rsi + r8]
    mov [rbx + rdx], al
    inc rdx
    jmp .fib_wb_rev_loop
.fib_wb_reversed:
    mov [rbp - FIB_LEN], rcx
    push rcx
    mov rdi, r12
    extern ap_free
    call ap_free
    pop rcx
    jmp .fib_assemble

.fib_wide_error:
    extern exc_OverflowError_type
    FAIL exc_OverflowError_type, "%c arg not in range(0x110000)", .fib_fail
END_FUNC format_int_body

;; ============================================================================
;; fs_apply_grouping() -> nothing (FS_BODY replaced when a separator was asked
;;   for)
;;
;; A local, not a function: it reads and writes the caller's FS_* slots, which
;; is why it takes nothing.  Both number formatters end here, so the rule
;; about how a zero pad and a separator interact is written once.
;; ============================================================================
fs_apply_grouping:
    cmp qword [rbp - FS_GROUP], 0
    je .fag_done
    push rbx
    sub rsp, 8
    mov rdi, [rbp - FS_BODY]
    mov rsi, [rbp - FS_GROUP]
    ; Hexadecimal, octal and binary group in fours; everything else in threes.
    xor edx, edx
    mov rax, [rbp - FS_TYPE]
    cmp rax, 'x'
    je .fag_wide
    cmp rax, 'X'
    je .fag_wide
    cmp rax, 'o'
    je .fag_wide
    cmp rax, 'b'
    jne .fag_have_base
.fag_wide:
    mov edx, 1
.fag_have_base:
    ; A zero pad is grouped into; any other fill is applied afterwards, by
    ; the ordinary padding stage, and must not reach here as a width.
    xor ecx, ecx
    cmp qword [rbp - FS_ZERO], 0
    je .fag_have_width
    cmp qword [rbp - FS_ALIGN], '='
    jne .fag_have_width
    mov rcx, [rbp - FS_WIDTH]
.fag_have_width:
    call format_group_body
    mov rbx, rax
    mov rdi, [rbp - FS_BODY]
    call obj_decref
    mov [rbp - FS_BODY], rbx
    add rsp, 8
    pop rbx
.fag_done:
    ret

;; ============================================================================
;; format_group_body(rdi = the formatted body, esi = the separator character,
;;                   edx = 1 when the digits are hexadecimal, rcx = the field
;;                   width when a zero pad has to be grouped into, else 0)
;;   -> rax = a NEW str, owned; the caller releases the body it passed
;;
;; One implementation for both formatters.  format_int_body used to group as
;; it emitted, and format_float_body did not group at all, so
;; format(1234567, ",") was right and format(1234567.5, ",.2f") answered
;; '1234567.50'.
;;
;; Two things beyond inserting a character every three digits:
;;
;;   * `_` on a hex, octal or binary presentation groups every FOUR, which is
;;     what a machine word is read in.  `,` is refused on those before it
;;     reaches here.
;;
;;   * A zero pad is filled INTO the grouping, not before it: format(0, "012,")
;;     is '0,000,000,000', which is thirteen characters for a width of twelve,
;;     because the separators do not count toward the digits the pad owes.
;;     The digit count grows until digits + separators reaches what is left of
;;     the width once the sign, the base prefix and the fraction have taken
;;     their share.
;; ============================================================================
FGB_BODY  equ 8
FGB_SEP   equ 16
FGB_GS    equ 24            ; 3, or 4 when the digits are hexadecimal
FGB_WIDTH equ 32
FGB_HEAD  equ 40            ; bytes before the digits: sign, and any 0x
FGB_NDIG  equ 48            ; digits the body actually has
FGB_TAIL  equ 56            ; where the digits end
FGB_OUT   equ 64
FGB_D     equ 72            ; digit positions to emit, once the pad is in
FGB_FRAME equ 96            ; + 2 pushes = 112, 16-aligned
DEF_FUNC_LOCAL format_group_body, FGB_FRAME
    push rbx
    push r12
    mov [rbp - FGB_BODY], rdi
    mov [rbp - FGB_SEP], rsi
    mov [rbp - FGB_WIDTH], rcx
    ; `_` on a hex, octal or binary presentation groups every FOUR digits,
    ; which is how a machine word is read.  `,` is refused on those before it
    ; reaches here, so the separator itself need not be consulted.
    mov eax, 3
    test rdx, rdx
    jz .fgb_have_gs
    mov eax, 4
.fgb_have_gs:
    mov [rbp - FGB_GS], rax
    mov [rbp - FGB_D], rdx      ; parked: whether the digits are hexadecimal
    mov rbx, rdi
    mov r12, [rbx + PyStrObject.ob_size]

    ; --- the head: a sign, then a base prefix ---------------------------
    xor ecx, ecx
    test r12, r12
    jz .fgb_asis
    movzx eax, byte [rbx + PyStrObject.data]
    cmp al, '-'
    je .fgb_sign
    cmp al, '+'
    je .fgb_sign
    cmp al, ' '
    jne .fgb_no_sign
.fgb_sign:
    mov ecx, 1
.fgb_no_sign:
    lea rax, [rcx + 2]
    cmp rax, r12
    ja .fgb_no_prefix
    cmp byte [rbx + PyStrObject.data + rcx], '0'
    jne .fgb_no_prefix
    movzx eax, byte [rbx + PyStrObject.data + rcx + 1]
    or al, 0x20
    cmp al, 'x'
    je .fgb_prefix
    cmp al, 'o'
    je .fgb_prefix
    cmp al, 'b'
    jne .fgb_no_prefix
.fgb_prefix:
    add rcx, 2
.fgb_no_prefix:
    mov [rbp - FGB_HEAD], rcx

    ; --- the digits ------------------------------------------------------
    mov rdx, rcx
.fgb_scan:
    cmp rdx, r12
    jge .fgb_scanned
    movzx eax, byte [rbx + PyStrObject.data + rdx]
    cmp al, '0'
    jb .fgb_scanned
    cmp al, '9'
    jbe .fgb_digit
    cmp qword [rbp - FGB_D], 0      ; hexadecimal?
    je .fgb_scanned
    or al, 0x20
    cmp al, 'a'
    jb .fgb_scanned
    cmp al, 'f'
    ja .fgb_scanned
.fgb_digit:
    inc rdx
    jmp .fgb_scan
.fgb_scanned:
    mov [rbp - FGB_TAIL], rdx
    sub rdx, rcx
    mov [rbp - FGB_NDIG], rdx
    test rdx, rdx
    jle .fgb_asis

    ; --- how many digit positions, once the zero pad is folded in --------
    mov [rbp - FGB_D], rdx
    mov rcx, [rbp - FGB_WIDTH]
    test rcx, rcx
    jz .fgb_have_d
    ; What the digits owe: the width, less the head and everything after
    ; them.  The separators do not count toward it, which is why
    ; format(0, "012,") is thirteen characters for a width of twelve.
    sub rcx, [rbp - FGB_HEAD]
    mov rax, r12
    sub rax, [rbp - FGB_TAIL]
    sub rcx, rax
    jle .fgb_have_d
.fgb_grow:
    mov rsi, [rbp - FGB_GS]
    mov rax, [rbp - FGB_D]
    add rax, rsi
    dec rax
    xor edx, edx
    div rsi                     ; groups = ceil(d / size)
    add rax, [rbp - FGB_D]
    dec rax                     ; total = d + groups - 1
    cmp rax, rcx
    jge .fgb_have_d
    inc qword [rbp - FGB_D]
    jmp .fgb_grow
.fgb_have_d:

    ; --- the new string ---------------------------------------------------
    mov rsi, [rbp - FGB_GS]
    mov rax, [rbp - FGB_D]
    add rax, rsi
    dec rax
    xor edx, edx
    div rsi
    dec rax                     ; separators = groups - 1
    add rax, [rbp - FGB_D]
    add rax, [rbp - FGB_HEAD]
    mov rcx, r12
    sub rcx, [rbp - FGB_TAIL]
    add rax, rcx                ; the whole length

    ; The result is ASCII whatever the body was: digits, a separator and the
    ; body's own tail, which for a number is a dot, an exponent or a percent.
    mov rdi, rax
    mov rsi, rax
    extern str_alloc_bytes
    call str_alloc_bytes
    test rax, rax
    jz .fgb_asis
    mov [rbp - FGB_OUT], rax

    lea rdi, [rax + PyStrObject.data]
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, [rbp - FGB_HEAD]
    test rdx, rdx
    jz .fgb_head_done
    call ap_memcpy
.fgb_head_done:

    ; digits, most significant first, with a separator every group and a
    ; zero for any position the body itself does not have
    mov rax, [rbp - FGB_OUT]
    lea r8, [rax + PyStrObject.data]
    add r8, [rbp - FGB_HEAD]
    mov rcx, [rbp - FGB_D]
.fgb_emit:
    test rcx, rcx
    jz .fgb_emit_done
    dec rcx
    mov eax, '0'
    cmp rcx, [rbp - FGB_NDIG]
    jae .fgb_emit_ch
    mov rdx, [rbp - FGB_TAIL]
    sub rdx, rcx
    dec rdx
    movzx eax, byte [rbx + PyStrObject.data + rdx]
.fgb_emit_ch:
    mov [r8], al
    inc r8
    test rcx, rcx
    jz .fgb_emit
    mov rax, rcx
    xor edx, edx
    div qword [rbp - FGB_GS]
    test rdx, rdx
    jnz .fgb_emit
    mov rax, [rbp - FGB_SEP]
    mov [r8], al
    inc r8
    jmp .fgb_emit
.fgb_emit_done:

    ; whatever followed the digits
    mov rdi, r8
    lea rsi, [rbx + PyStrObject.data]
    add rsi, [rbp - FGB_TAIL]
    mov rdx, r12
    sub rdx, [rbp - FGB_TAIL]
    test rdx, rdx
    jz .fgb_tail_done
    call ap_memcpy
.fgb_tail_done:
    mov rax, [rbp - FGB_OUT]
    pop r12
    pop rbx
    leave
    ret

.fgb_asis:
    mov rax, [rbp - FGB_BODY]
    INCREF rax
    pop r12
    pop rbx
    leave
    ret
END_FUNC format_group_body

;; ============================================================================
;; format_float_body -> rax = str
;;
;; Delegates the digits to float_format_spec, which already knows how to
;; render a double to a precision and a type letter, then leaves padding to
;; the caller.
;; ============================================================================
FFB_ADDDOT equ 8         ; 1 when an empty type needs its ".0" put back
FFB_PCT   equ 16         ; 1 when the type letter was '%'
; The synthesised ".<prec><type>" spec.  32 bytes, because the precision is
; whatever fits a C int and that is ten digits; four used to be assumed, and
; the cap that kept it to three was the reason format(1.0, ".5000f") came back
; with a thousand decimal places instead of five thousand.
FFB_SPEC  equ 48
FFB_GPREC equ 72         ; the 'g' digit count for an empty type
FFB_EPREC equ 80         ; the 'e' probe's digit count, one lower
FFB_EBUF  equ 88         ; that probe's result, which is also the answer when
                         ; the exponent form wins
FFB_FRAME equ 96            ; + 2 pushes = 112, 16-aligned

DEF_FUNC_LOCAL format_float_body, FFB_FRAME
    push rbx
    push r12
    mov r12, [rbp]                      ; caller's rbp

    ; The value has to be a float for float_format_spec; an int with a float
    ; type letter is converted first, as CPython does.
    mov rdi, [r12 - FS_VALUE]
    V_UNPACK rdi, rdx
    cmp edx, TAG_FLOAT
    je .ffb_have_double
    ; An int with a float type letter is converted first, as CPython does.
    mov rsi, rdx                        ; the tag
    extern float_to_f64
    call float_to_f64
    movq rdi, xmm0                      ; raw double bits

.ffb_have_double:
    ; The '%' type is 'f' applied to a hundred times the value, with a '%'
    ; put on the end.  Neither half was done: the letter reached
    ; float_format_spec, matched none of its six, and fell to the %g default,
    ; so format(1/3, ".2%") was "0.33" -- not the right number, and not
    ; carrying the sign that says what it is.
    mov qword [rbp - FFB_PCT], 0
    mov rax, [r12 - FS_TYPE]
    cmp rax, '%'
    jne .ffb_not_pct
    mov qword [rbp - FFB_PCT], 1
    mov qword [r12 - FS_TYPE], 'f'      ; and 'f' pads the same way '%' does
    movq xmm0, rdi
    mulsd xmm0, [rel ffb_hundred]
    movq rdi, xmm0
.ffb_not_pct:

    ; An empty type letter is repr, not %g.  format_float_body used to write a
    ; one-byte spec "r" on the strength of a comment claiming
    ; float_format_spec had a repr default; it has none, so the letter was
    ; ignored and the defaults %.6g rendered format(1.0, "") as "1".
    ;
    ; CPython's rule: with no precision an empty type is exactly repr(x); with
    ; one it is 'g' but with at least one digit after the point, so
    ; format(1.0, ".3") is "1.0" rather than "1".
    mov qword [rbp - FFB_ADDDOT], 0
    mov rax, [r12 - FS_TYPE]
    test rax, rax
    jnz .ffb_build_spec
    mov rax, [r12 - FS_PREC]
    test rax, rax
    jge .ffb_empty_with_prec
    extern float_repr
    call float_repr             ; rdi = the raw bits, still
    ; With `#` and no precision the point is kept even when repr did not need
    ; one: format(1e20, "#6") is '1.e+20' in CPython and repr alone gives
    ; '1e+20'.  It goes BEFORE the exponent, which is why this is an insert
    ; and not the ".0" append below.
    cmp qword [r12 - FS_ALT], 0
    je .ffb_have_string
    mov rbx, rax
    mov r8, [rbx + PyStrObject.ob_size]
    lea rcx, [rbx + PyStrObject.data]
    xor r9d, r9d
.ffb_alt_scan:
    cmp r9, r8
    jge .ffb_alt_at_end
    movzx eax, byte [rcx + r9]
    cmp al, '.'
    je .ffb_alt_none            ; already has one
    cmp al, 'n'                 ; nan
    je .ffb_alt_none
    cmp al, 'i'                 ; inf
    je .ffb_alt_none
    cmp al, 'e'
    je .ffb_alt_at_end
    cmp al, 'E'
    je .ffb_alt_at_end
    inc r9
    jmp .ffb_alt_scan
.ffb_alt_at_end:
    ; r9 is where the point goes.
    sub rsp, 128
    mov rsi, rsp
    xor edx, edx
.ffb_alt_head:
    cmp rdx, r9
    jge .ffb_alt_point
    mov al, [rcx + rdx]
    mov [rsi + rdx], al
    inc rdx
    jmp .ffb_alt_head
.ffb_alt_point:
    mov byte [rsi + rdx], '.'
    mov r11, rdx
    inc r11
.ffb_alt_tail:
    cmp r9, r8
    jge .ffb_alt_built
    mov al, [rcx + r9]
    mov [rsi + r11], al
    inc r9
    inc r11
    jmp .ffb_alt_tail
.ffb_alt_built:
    mov byte [rsi + r11], 0
    mov rdi, rsi
    call str_from_cstr_heap
    add rsp, 128
    test rax, rax
    jz .ffb_alt_none
    push rax
    mov rdi, rbx
    call obj_decref
    pop rax
    jmp .ffb_have_string
.ffb_alt_none:
    mov rax, rbx
    jmp .ffb_have_string
.ffb_empty_with_prec:
    ; An empty type with a precision is 'g', but CPython lowers the threshold
    ; at which it switches to an exponent by one:
    ;
    ;     decpt <= -4 || decpt > (add_dot_0 ? precision-1 : precision)
    ;
    ; (pystrtod.c, format_float_short).  C's %g uses the un-lowered form, so
    ; format(1.5, ".0") came back '2.0' where CPython answers '2e+00'.  The
    ; two cannot be asked of one %g call -- the threshold moves but the digit
    ; count does not -- so the exponent is measured first, with a render that
    ; is also the answer whenever the exponent form wins.
    ;
    ; Precision 0 counts as 1 throughout, which is what CPython's own
    ; bump to at least one significant digit amounts to.
    mov qword [rbp - FFB_ADDDOT], 1
    mov rax, [r12 - FS_PREC]
    cmp rax, 1
    jge .ffb_ewp_have_p
    mov eax, 1
.ffb_ewp_have_p:
    mov [rbp - FFB_GPREC], rax
    dec rax
    mov [rbp - FFB_EPREC], rax          ; the 'e' render's digit count

    ; Render "[#].<p-1>e" and read the exponent off the end of it.
    lea rbx, [rbp - FFB_SPEC]
    xor ecx, ecx
    cmp qword [r12 - FS_ALT], 0
    je .ffb_ewp_no_alt
    mov byte [rbx], '#'
    mov ecx, 1
.ffb_ewp_no_alt:
    mov byte [rbx + rcx], '.'
    inc rcx
    mov rax, [rbp - FFB_EPREC]
    call .ffb_emit_number
    mov byte [rbx + rcx], 'e'
    inc rcx
    push rdi                            ; the raw double bits
    mov rsi, rbx
    mov rdx, rcx
    call float_format_spec
    V_UNPACK rax, rdx
    pop rdi
    test rax, rax
    jz .ffb_ewp_fixed
    mov [rbp - FFB_EBUF], rax

    ; The exponent is the tail after the last 'e'.
    mov rsi, [rax + PyStrObject.ob_size]
    lea rcx, [rax + PyStrObject.data]
    dec rsi
.ffb_ewp_scan:
    test rsi, rsi
    jl .ffb_ewp_fixed_rel
    cmp byte [rcx + rsi], 'e'
    je .ffb_ewp_found
    dec rsi
    jmp .ffb_ewp_scan
.ffb_ewp_found:
    inc rsi
    xor r8d, r8d                        ; sign
    cmp byte [rcx + rsi], '-'
    jne .ffb_ewp_sign_done
    mov r8d, 1
    inc rsi
.ffb_ewp_sign_done:
    cmp byte [rcx + rsi], '+'
    jne .ffb_ewp_digits
    inc rsi
.ffb_ewp_digits:
    xor eax, eax
    mov r9, [rbp - FFB_EBUF]
    mov r9, [r9 + PyStrObject.ob_size]
.ffb_ewp_digit:
    cmp rsi, r9
    jge .ffb_ewp_exp_done
    movzx edx, byte [rcx + rsi]
    sub edx, '0'
    cmp edx, 9
    ja .ffb_ewp_exp_done
    imul rax, rax, 10
    add rax, rdx
    inc rsi
    jmp .ffb_ewp_digit
.ffb_ewp_exp_done:
    test r8d, r8d
    jz .ffb_ewp_positive
    neg rax
.ffb_ewp_positive:
    inc rax                             ; decpt = exponent + 1

    ; decpt <= -4 || decpt > precision-1 means the exponent form wins, and
    ; the render just made IS that form.
    cmp rax, -4
    jle .ffb_ewp_use_exp
    mov rdx, [rbp - FFB_GPREC]
    dec rdx
    cmp rax, rdx
    jg .ffb_ewp_use_exp

.ffb_ewp_fixed_rel:
    mov rdi, [rbp - FFB_EBUF]
    push rdi
    call obj_decref
    pop rdi
.ffb_ewp_fixed:
    ; The ordinary 'g' path below, with ADD_DOT_0 still set.
    mov rdi, [r12 - FS_VALUE]
    V_UNPACK rdi, rdx
    cmp edx, TAG_FLOAT
    je .ffb_build_spec
    mov rsi, rdx
    call float_to_f64
    movq rdi, xmm0
    jmp .ffb_build_spec

.ffb_ewp_use_exp:
    mov qword [rbp - FFB_ADDDOT], 0     ; it already has its point
    mov rax, [rbp - FFB_EBUF]
    ; 'g' drops trailing zeros in the mantissa and 'e' does not, so the probe
    ; render has to be trimmed: format(1e20, ".3") is '1e+20' in CPython and
    ; the raw %.2e is '1.00e+20'.  With `#` they stay, which is the whole of
    ; what alternate formatting means here.
    cmp qword [r12 - FS_ALT], 0
    jne .ffb_ewp_no_trim
    push rax
    sub rsp, 128
    mov rsi, rsp                        ; the trimmed copy
    mov r8, [rax + PyStrObject.ob_size]
    lea rcx, [rax + PyStrObject.data]
    ; Find the 'e'.
    xor r9d, r9d
.ffb_trim_find:
    cmp r9, r8
    jge .ffb_trim_give_up
    cmp byte [rcx + r9], 'e'
    je .ffb_trim_found
    inc r9
    jmp .ffb_trim_find
.ffb_trim_found:
    mov r10, r9                         ; one past the mantissa
    ; Where the mantissa's first digit is: one in, when the render carries a
    ; sign.  Stopping at a fixed index 1 ate the digit of a signed zero --
    ; format(-0.0, ".0") trimmed "-0e+00" down to "-e+00".
    xor edi, edi
    cmp byte [rcx], '-'
    jne .ffb_trim_limit
    mov edi, 1
.ffb_trim_limit:
    inc rdi                             ; one digit always survives
    ; Walk back over zeros, then the point.
.ffb_trim_zeros:
    cmp r10, rdi
    jle .ffb_trim_copy
    cmp byte [rcx + r10 - 1], '0'
    jne .ffb_trim_dot
    dec r10
    jmp .ffb_trim_zeros
.ffb_trim_dot:
    cmp byte [rcx + r10 - 1], '.'
    jne .ffb_trim_copy
    dec r10
.ffb_trim_copy:
    ; mantissa[0..r10) then the exponent from r9.
    xor edx, edx
.ffb_trim_m:
    cmp rdx, r10
    jge .ffb_trim_e
    mov al, [rcx + rdx]
    mov [rsi + rdx], al
    inc rdx
    jmp .ffb_trim_m
.ffb_trim_e:
    mov r11, rdx
.ffb_trim_ecopy:
    cmp r9, r8
    jge .ffb_trim_done
    mov al, [rcx + r9]
    mov [rsi + r11], al
    inc r9
    inc r11
    jmp .ffb_trim_ecopy
.ffb_trim_done:
    mov byte [rsi + r11], 0
    mov rdi, rsi
    extern str_from_cstr_heap
    call str_from_cstr_heap
    add rsp, 128
    mov rdi, [rsp]
    mov [rsp], rax
    call obj_decref                     ; the untrimmed probe
    pop rax
    test rax, rax
    jz .ffb_ewp_no_trim
    jmp .ffb_ewp_trimmed
.ffb_trim_give_up:
    add rsp, 128
    pop rax
.ffb_ewp_no_trim:
.ffb_ewp_trimmed:
    mov edx, TAG_PTR
    jmp .ffb_have_string

    ;; .ffb_emit_number -- append rax as decimal digits at [rbx + rcx].
.ffb_emit_number:
    sub rsp, 8
    mov r8, rax
    mov r9d, 10
    xor r10d, r10d
.ffb_en_split:
    xor edx, edx
    mov rax, r8
    div r9
    mov r8, rax
    add rdx, '0'
    push rdx
    inc r10
    test r8, r8
    jnz .ffb_en_split
.ffb_en_emit:
    pop rax
    mov [rbx + rcx], al
    inc rcx
    dec r10
    jnz .ffb_en_emit
    add rsp, 8
    ret

.ffb_build_spec:
    ; Build "[#].<precision><type>" in a small buffer.
    lea rbx, [rbp - FFB_SPEC]
    xor ecx, ecx
    ; The `#` flag was parsed and then never read by this function, so it was
    ; silently dropped for every float type: format(1.5, "#.0f") answered '2'
    ; where CPython answers '2.'.  snprintf's own '#' is exactly the rule --
    ; keep the point, and keep trailing zeros for g -- so it goes into the
    ; spec rather than being reimplemented after the fact.
    cmp qword [r12 - FS_ALT], 0
    je .ffb_no_alt
    mov byte [rbx], '#'
    mov ecx, 1
.ffb_no_alt:
    mov rax, [r12 - FS_PREC]
    test rax, rax
    jge .ffb_have_prec
    ; e, f and g default to six digits; only a bare spec means repr.  Without
    ; this f"{1.5:f}" was "1.5" rather than "1.500000".
    mov rdx, [r12 - FS_TYPE]
    cmp rdx, 'e'
    je .ffb_default_prec
    cmp rdx, 'E'
    je .ffb_default_prec
    cmp rdx, 'f'
    je .ffb_default_prec
    cmp rdx, 'F'
    je .ffb_default_prec
    cmp rdx, 'g'
    je .ffb_default_prec
    cmp rdx, 'G'
    je .ffb_default_prec
    cmp rdx, '%'
    jne .ffb_no_prec
.ffb_default_prec:
    mov eax, 6
.ffb_have_prec:
    mov byte [rbx + rcx], '.'
    inc rcx
    ; However many digits it takes.  float_format_spec renders through
    ; snprintf and falls back to a heap buffer of whatever size snprintf
    ; names, so the number here is the only limit -- and the spec parser has
    ; already refused anything that does not fit a C int.  Three digits used
    ; to be all this could write, and rather than say so it silently used 999
    ; instead: format(1.0, ".5000f") came back one thousand places long.
    mov r8, rax
    mov r9d, 10
    xor r10d, r10d                      ; digits on the machine stack
.ffb_prec_split:
    xor edx, edx
    mov rax, r8
    div r9                              ; rax = quotient, rdx = digit
    mov r8, rax
    add rdx, '0'
    push rdx
    inc r10
    test r8, r8
    jnz .ffb_prec_split
.ffb_prec_emit:                         ; least significant went on last
    pop rax
    mov [rbx + rcx], al
    inc rcx
    dec r10
    jnz .ffb_prec_emit
.ffb_no_prec:
    mov rax, [r12 - FS_TYPE]
    test rax, rax
    jnz .ffb_have_type
    mov rax, 'g'                        ; an empty type, with a precision
.ffb_have_type:
    mov [rbx + rcx], al
    inc rcx

    mov rsi, rbx
    mov rdx, rcx
    call float_format_spec
    V_UNPACK rax, rdx

    cmp qword [rbp - FFB_PCT], 0
    jne .ffb_add_pct
    cmp qword [rbp - FFB_ADDDOT], 0
    je .ffb_have_string

    ; Put the ".0" back when %g dropped it.  A point, an exponent, or the
    ; letters of inf and nan all mean there is nothing to put back.
    mov rbx, rax
    mov rcx, [rbx + PyStrObject.ob_size]
    xor esi, esi
.ffb_dot_scan:
    cmp rsi, rcx
    jge .ffb_dot_append
    movzx eax, byte [rbx + PyStrObject.data + rsi]
    cmp al, '.'
    je .ffb_dot_none
    cmp al, 'e'
    je .ffb_dot_none
    cmp al, 'E'
    je .ffb_dot_none
    cmp al, 'n'                         ; nan
    je .ffb_dot_none
    cmp al, 'i'                         ; inf
    je .ffb_dot_none
    inc rsi
    jmp .ffb_dot_scan
.ffb_dot_none:
    mov rax, rbx
    jmp .ffb_have_string
.ffb_dot_append:
    lea rdi, [rcx + PyStrObject.data + 9]
    call ap_malloc
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rdx, [rel str_type]
    mov [rax + PyObject.ob_type], rdx
    mov qword [rax + PyStrObject.ob_hash], -1
    mov rcx, [rbx + PyStrObject.ob_size]
    lea rdx, [rcx + 2]
    mov [rax + PyStrObject.ob_size], rdx
    mov [rax + PyStrObject.ob_length], rdx
    push rax
    lea rdi, [rax + PyStrObject.data]
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, rcx
    call ap_memcpy
    pop rax
    mov rcx, [rbx + PyStrObject.ob_size]
    mov byte [rax + PyStrObject.data + rcx], '.'
    mov byte [rax + PyStrObject.data + rcx + 1], '0'
    mov byte [rax + PyStrObject.data + rcx + 2], 0
    push rax
    mov rdi, rbx
    call obj_decref
    pop rax

    jmp .ffb_have_string

.ffb_add_pct:
    ; The '%' on the end.  It goes over the NUL that terminates the rendered
    ; body -- a str always has one -- and str_new_heap copies from there with
    ; an explicit length, so the body is released untouched a line later.
    mov rbx, rax
    mov rcx, [rbx + PyStrObject.ob_size]
    mov byte [rbx + PyStrObject.data + rcx], '%'
    lea rdi, [rbx + PyStrObject.data]
    lea rsi, [rcx + 1]
    call str_new_heap
    push rax
    mov rdi, rbx
    call obj_decref
    pop rax

.ffb_have_string:
    ; The sign, in the order PEP 682 needs: a leading '-' may be COERCED away
    ; first, and only then is an explicit '+' or ' ' applied.  Running the two
    ; the other way round meant a coerced result lost the sign the spec asked
    ; for -- format(-0.0001, "+z.2f") answered '0.00' where CPython gives
    ; '+0.00' -- and, worse, the add-sign arm fell THROUGH into the coercion,
    ; so `format(0.0, "+z")` had its own '+' read as the sign to strip.
    mov qword [r12 - FS_SIGNCH], 0
    cmp qword [rax + PyStrObject.ob_size], 0
    jle .ffb_done
    cmp byte [rax + PyStrObject.data], '-'
    jne .ffb_no_minus

    cmp qword [r12 - FS_ZCOERCE], 0
    je .ffb_keep_minus

    ; With `z`, a result whose digits are all zero loses its sign.  The test
    ; is on the RENDERED text, not the value: -0.0001 at two decimal places
    ; rounds to -0.00 and is coerced, while -0.4 is not.  inf and nan are
    ; never coerced -- CPython guards this with Py_IS_FINITE, and a scan that
    ; only recognises '1'..'9' as "a real digit" walks their letters and calls
    ; them zero.
    mov rcx, [rax + PyStrObject.ob_size]
    lea rsi, [rax + PyStrObject.data]
    mov r8d, 1                      ; skip the '-'
.ffb_z_scan:
    cmp r8, rcx
    jge .ffb_z_all_zero
    movzx edx, byte [rsi + r8]
    cmp dl, 'e'
    je .ffb_z_all_zero                  ; the exponent's digits do not count
    cmp dl, 'E'
    je .ffb_z_all_zero
    or  dl, 0x20                        ; inf/nan, in either case
    cmp dl, 'i'
    je .ffb_keep_minus
    cmp dl, 'n'
    je .ffb_keep_minus
    movzx edx, byte [rsi + r8]
    cmp dl, '1'
    jb .ffb_z_next
    cmp dl, '9'
    jbe .ffb_keep_minus                 ; a real digit: the sign stays
.ffb_z_next:
    inc r8
    jmp .ffb_z_scan

.ffb_z_all_zero:
    ; Re-render without the leading '-', then let the sign rules below run
    ; over the result: a coerced zero still takes an explicit '+' or ' '.
    mov rbx, rax
    lea rdi, [rbx + PyStrObject.data + 1]
    call str_from_cstr_heap
    test rax, rax
    jz .ffb_z_kept
    push rax
    mov rdi, rbx
    call obj_decref
    pop rax
    jmp .ffb_no_minus
.ffb_z_kept:
    mov rax, rbx
.ffb_keep_minus:
    mov qword [r12 - FS_SIGNCH], 1
    jmp .ffb_done

.ffb_no_minus:
    ; float_format_spec knows nothing about the sign flag, so a '+' or a
    ; leading space has to be put on here: "%+.1f" % 1.25 was "1.2".
    mov rcx, [r12 - FS_SIGN]
    cmp rcx, '+'
    je .ffb_add_sign
    cmp rcx, ' '
    jne .ffb_done
.ffb_add_sign:
    mov rbx, rax                    ; the unsigned digits
    mov rsi, [rbx + PyStrObject.ob_size]
    lea rdi, [rsi + PyStrObject.data + 9]
    call ap_malloc
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rdx, [rel str_type]
    mov [rax + PyObject.ob_type], rdx
    mov qword [rax + PyStrObject.ob_hash], -1
    mov rcx, [rbx + PyStrObject.ob_size]
    inc rcx
    mov [rax + PyStrObject.ob_size], rcx
    mov [rax + PyStrObject.ob_length], rcx
    mov rcx, [r12 - FS_SIGN]
    mov [rax + PyStrObject.data], cl
    push rax
    lea rdi, [rax + PyStrObject.data + 1]
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, [rbx + PyStrObject.ob_size]
    call ap_memcpy
    pop rax
    mov rcx, [rax + PyStrObject.ob_size]
    mov qword [rax + PyStrObject.data + rcx], 0
    push rax
    mov rdi, rbx
    call obj_decref
    pop rax
    mov qword [r12 - FS_SIGNCH], 1

.ffb_done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC format_float_body

;; ============================================================================
;; format_complex_body() -> rax = PyStrObject*
;;
;; Reached with the caller's format_apply_spec frame live, the same way
;; format_float_body is: r12 addresses it and the FS_* slots are read through
;; that.
;;
;; With no type letter the body is exactly repr(z) -- CPython's
;; format_complex_internal sets type 'r' and precision 0 and applies the same
;; skip-the-real-part rule, which is what repr already is.  With a letter, both
;; halves go through float_format_spec with the same synthesised ".<prec><t>"
;; spec and are joined as `re` + signed(`im`) + "j", with no parentheses.
;;
;; The sign flag applies to the real part only; the imaginary part always
;; carries its own explicit sign.
;; ============================================================================
FCB_SPEC    equ 16          ; the synthesised ".<prec><type>", at most 6 bytes
FCB_SPECLEN equ 24
FCB_RE      equ 32          ; the real part's rendered str
FCB_IM      equ 40          ; the imaginary part's
FCB_SELF    equ 48
FCB_OUT     equ 56
FCB_FRAME   equ 64          ; + 2 pushes = 80
DEF_FUNC_LOCAL format_complex_body, FCB_FRAME
    push rbx
    push r12
    mov r12, [rbp]                      ; the caller's rbp
    mov rax, [r12 - FS_VALUE]
    mov [rbp - FCB_SELF], rax

    mov rax, [r12 - FS_TYPE]
    test rax, rax
    jz .fcb_repr                        ; an empty spec is repr, exactly

    ; ---- build ".<prec><type>" ---------------------------------------------
    lea rbx, [rbp - FCB_SPEC]
    mov rax, [r12 - FS_PREC]
    test rax, rax
    jge .fcb_prec_given
    mov eax, 6                      ; e E f F g G n all default to six
.fcb_prec_given:
    cmp rax, 999
    jle .fcb_prec_ok
    mov eax, 999
.fcb_prec_ok:
    mov byte [rbx], '.'
    mov ecx, 1
    xor r8d, r8d                        ; a digit has been emitted
    mov r9d, 100
    xor edx, edx
    div r9                              ; rax = hundreds, rdx = rest
    test rax, rax
    jz .fcb_tens
    add al, '0'
    mov [rbx + rcx], al
    inc rcx
    mov r8d, 1
.fcb_tens:
    mov rax, rdx
    xor edx, edx
    mov r9d, 10
    div r9                              ; rax = tens, rdx = units
    mov r10, rdx
    test rax, rax
    jnz .fcb_emit_tens
    test r8d, r8d
    jz .fcb_units
.fcb_emit_tens:
    add al, '0'
    mov [rbx + rcx], al
    inc rcx
.fcb_units:
    mov rax, r10
    add al, '0'
    mov [rbx + rcx], al
    inc rcx
    ; 'n' is 'g' with locale grouping, which we do not do; format it as 'g'.
    mov rax, [r12 - FS_TYPE]
    cmp rax, 'n'
    jne .fcb_type_ok
    mov rax, 'g'
.fcb_type_ok:
    mov [rbx + rcx], al
    inc rcx
    mov [rbp - FCB_SPECLEN], rcx

    ; ---- render both halves ------------------------------------------------
    mov rax, [rbp - FCB_SELF]
    mov rdi, [rax + PyComplexObject.cval_real]
    lea rsi, [rbp - FCB_SPEC]
    mov rdx, [rbp - FCB_SPECLEN]
    extern float_format_spec
    call float_format_spec
    V_UNPACK rax, rdx
    mov [rbp - FCB_RE], rax

    mov rax, [rbp - FCB_SELF]
    mov rdi, [rax + PyComplexObject.cval_imag]
    lea rsi, [rbp - FCB_SPEC]
    mov rdx, [rbp - FCB_SPECLEN]
    call float_format_spec
    V_UNPACK rax, rdx
    mov [rbp - FCB_IM], rax

    ; ---- join: [sign] re [+] im 'j' ----------------------------------------
    ; Room for both halves, an explicit sign on each, the 'j' and a NUL.
    mov rdi, [rbp - FCB_RE]
    mov rdi, [rdi + PyStrObject.ob_size]
    mov rax, [rbp - FCB_IM]
    add rdi, [rax + PyStrObject.ob_size]
    add rdi, 8
    extern ap_malloc
    call ap_malloc
    mov [rbp - FCB_OUT], rax
    mov rbx, rax                        ; rbx = write cursor

    ; The sign flag is the real part's; float_format_spec knows nothing of it.
    mov rax, [rbp - FCB_RE]
    cmp qword [rax + PyStrObject.ob_size], 0
    jle .fcb_no_sign
    cmp byte [rax + PyStrObject.data], '-'
    je .fcb_no_sign
    mov rcx, [r12 - FS_SIGN]
    cmp rcx, '+'
    je .fcb_put_sign
    cmp rcx, ' '
    jne .fcb_no_sign
.fcb_put_sign:
    mov [rbx], cl
    inc rbx
.fcb_no_sign:
    mov rdi, rbx
    mov rax, [rbp - FCB_RE]
    lea rsi, [rax + PyStrObject.data]
    mov rdx, [rax + PyStrObject.ob_size]
    add rbx, rdx
    extern ap_memcpy
    call ap_memcpy

    ; The imaginary part is always signed.
    mov rax, [rbp - FCB_IM]
    cmp qword [rax + PyStrObject.ob_size], 0
    jle .fcb_im_signed
    cmp byte [rax + PyStrObject.data], '-'
    je .fcb_im_signed
    mov byte [rbx], '+'
    inc rbx
.fcb_im_signed:
    mov rdi, rbx
    mov rax, [rbp - FCB_IM]
    lea rsi, [rax + PyStrObject.data]
    mov rdx, [rax + PyStrObject.ob_size]
    add rbx, rdx
    call ap_memcpy
    mov byte [rbx], 'j'
    inc rbx

    ; ---- wrap up -----------------------------------------------------------
    mov rdi, [rbp - FCB_OUT]
    mov rsi, rbx
    sub rsi, rdi                        ; the byte length
    extern str_new_heap
    call str_new_heap
    mov rbx, rax                        ; the finished body

    mov rdi, [rbp - FCB_OUT]
    extern ap_free
    call ap_free
    mov rdi, [rbp - FCB_RE]
    extern obj_decref
    call obj_decref
    mov rdi, [rbp - FCB_IM]
    call obj_decref

    ; '=' alignment is rejected for a complex, so there is no sign to hoist.
    mov qword [r12 - FS_SIGNCH], 0
    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret

.fcb_repr:
    mov rdi, [rbp - FCB_SELF]
    extern complex_repr
    call complex_repr
    V_UNPACK rax, rdx
    mov qword [r12 - FS_SIGNCH], 0
    pop r12
    pop rbx
    leave
    ret
END_FUNC format_complex_body


;; ############################################################################
;;            %-FORMATTING: CHECKING THE ARGUMENT AGAINST THE CONVERSION
;; ############################################################################
;;
;; Every numeric conversion in str_mod used to format whatever it was handed,
;; so "%d" % "x" answered 'x' and "%i" % [] answered '[]' -- a wrong answer
;; with nothing to say anything was wrong.  This is the check, and the
;; coercion that goes with it: %d takes a float and truncates, %f takes an int
;; and widens, and both take an object that offers __index__ or __float__.

extern int_is_integer
extern int_from_i64
extern int_float
extern float_int
extern float_type
extern obj_as_index
extern dunder_lookup
extern dunder_call_1
extern type_is_subtype

FPC_VAL   equ 8
FPC_CONV  equ 16
FPC_FRAME equ 32            ; + 0 pushes = 32

;; ============================================================================
;; fmt_percent_coerce(rdi = the argument Value, esi = the conversion character)
;;   -> rax = a Value the conversion can use, edx = 1 when it is a NEW
;;      reference the caller must release with DECREF_V
;; Fails: 0
;; The TypeError is for an argument that cannot be used at all.
;; ============================================================================
global fmt_percent_coerce
DEF_FUNC fmt_percent_coerce, FPC_FRAME
    mov [rbp - FPC_VAL], rdi
    mov [rbp - FPC_CONV], rsi

    mov eax, esi
    cmp al, 'd'
    je .fpc_int_like
    cmp al, 'i'
    je .fpc_int_like
    cmp al, 'u'
    je .fpc_int_like
    cmp al, 'x'
    je .fpc_int_strict
    cmp al, 'X'
    je .fpc_int_strict
    cmp al, 'o'
    je .fpc_int_strict
    cmp al, 'b'
    je .fpc_int_strict
    cmp al, 'e'
    je .fpc_float
    cmp al, 'E'
    je .fpc_float
    cmp al, 'f'
    je .fpc_float
    cmp al, 'F'
    je .fpc_float
    cmp al, 'g'
    je .fpc_float
    cmp al, 'G'
    je .fpc_float

.fpc_pass:
    mov rax, [rbp - FPC_VAL]
    xor edx, edx
    leave
    ret

;; %d, %i and %u: an integer, a float truncated toward zero, or __index__.
.fpc_int_like:
    call .fpc_arg_is_int
    test eax, eax
    jnz .fpc_pass
    call .fpc_arg_is_float
    test eax, eax
    jz .fpc_int_dunder
    mov rdi, [rbp - FPC_VAL]
    call float_int            ; err: the 0 is this function's own answer
    mov edx, 1
    leave
    ret

;; %x, %X, %o and %b: an integer only.  A float is a TypeError, not a
;; truncation -- CPython is strict here and lax for %d.
.fpc_int_strict:
    call .fpc_arg_is_int
    test eax, eax
    jnz .fpc_pass

.fpc_int_dunder:
    mov rdi, [rbp - FPC_VAL]
    V_TEST_PTR rdi, rax
    ja .fpc_int_bad
    test rdi, rdi
    jz .fpc_int_bad
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel fpc_name_index]
    call dunder_lookup
    test rax, rax
    jz .fpc_int_bad
    mov rdi, [rbp - FPC_VAL]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .fpc_fail
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    mov edx, 1
    leave
    ret

;; %e, %f, %g and their uppercase forms: a real number, or __float__.
.fpc_float:
    call .fpc_arg_is_float
    test eax, eax
    jnz .fpc_pass
    call .fpc_arg_is_int
    test eax, eax
    jz .fpc_float_dunder
    mov rdi, [rbp - FPC_VAL]
    call int_float            ; err: its 0 is this function's own answer
    mov edx, 1
    leave
    ret

.fpc_float_dunder:
    mov rdi, [rbp - FPC_VAL]
    V_TEST_PTR rdi, rax
    ja .fpc_float_bad
    test rdi, rdi
    jz .fpc_float_bad
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel fpc_name_float]
    call dunder_lookup
    test rax, rax
    jz .fpc_float_bad
    mov rdi, [rbp - FPC_VAL]
    lea rsi, [rel fpc_name_float]
    call dunder_call_1          ; err: 0 goes to the caller as it stands
    mov edx, 1
    leave
    ret

;; .fpc_arg_is_int -> eax = 1 when the argument is an int, a bool or an int
;; subclass instance.  Reads the caller's slot, so it is not standalone.
.fpc_arg_is_int:
    sub rsp, 8
    mov rdi, [rbp - FPC_VAL]
    V_UNPACK rdi, rdx
    call int_is_integer
    add rsp, 8
    ret

;; .fpc_arg_is_float -> eax = 1 for a float immediate, a float, or a subclass.
.fpc_arg_is_float:
    sub rsp, 8
    mov rdi, [rbp - FPC_VAL]
    V_IS_FLOAT rdi, rax
    jb .fpc_aif_yes             ; CF=1 is the float immediate
    V_TEST_PTR rdi, rax
    ja .fpc_aif_no
    test rdi, rdi
    jz .fpc_aif_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel float_type]
    cmp rax, rcx
    je .fpc_aif_yes
    mov rdi, rax
    lea rsi, [rel float_type]
    call type_is_subtype
    test eax, eax
    jz .fpc_aif_no
.fpc_aif_yes:
    mov eax, 1
    add rsp, 8
    ret
.fpc_aif_no:
    xor eax, eax
    add rsp, 8
    ret

;; The messages carry the conversion character, so they are assembled rather
;; than picked from a list.  \x01 is raise_type_error_with_name's placeholder
;; for the argument's type name.
.fpc_int_bad:
    lea rsi, [rel fpc_msg_real]
    cmp qword [rbp - FPC_CONV], 'd'
    je .fpc_bad_build
    cmp qword [rbp - FPC_CONV], 'i'
    je .fpc_bad_build
    cmp qword [rbp - FPC_CONV], 'u'
    je .fpc_bad_build
    lea rsi, [rel fpc_msg_integer]
.fpc_bad_build:
    lea rdi, [rel fpc_msgbuf]
    mov rax, [rbp - FPC_CONV]
    mov byte [rdi], '%'
    mov [rdi + 1], al
    add rdi, 2
    xor ecx, ecx
.fpc_bad_copy:
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    test al, al
    jz .fpc_bad_raise
    inc rcx
    jmp .fpc_bad_copy
.fpc_bad_raise:
    lea rdi, [rel fpc_msgbuf]
    mov rsi, [rbp - FPC_VAL]
    call set_type_error_with_name
    jmp .fpc_fail

.fpc_float_bad:
    lea rdi, [rel fpc_msg_notreal]
    mov rsi, [rbp - FPC_VAL]
    call set_type_error_with_name
.fpc_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret

section .rodata
align 8
ffb_hundred:     dq 100.0
fpc_name_index:  db "__index__", 0
fpc_name_float:  db "__float__", 0
fpc_msg_real:    db ` format: a real number is required, not \x01`, 0
fpc_msg_integer: db ` format: an integer is required, not \x01`, 0
fpc_msg_notreal: db `must be real number, not \x01`, 0

section .bss
fpc_msgbuf: resb 96

section .text
END_FUNC fmt_percent_coerce

;; ============================================================================
;; format_require_str(rdi = the payload __format__ answered, rsi = its tag)
;;   -> rax = 0 when it is a str or a str subclass
;; Fails: -1
;;
;; CPython's "__format__ must return a str, not int".  Nothing checked, so a
;; __format__ answering an int reached the f-string machinery, which read a
;; string out of it.
;; ============================================================================
extern set_type_error_with_name
extern str_type
global format_require_str
DEF_FUNC_BARE format_require_str
    cmp rsi, TAG_PTR
    jne .frs_bad
    mov rcx, [rdi + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    je .frs_ok
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .frs_bad
.frs_ok:
    xor eax, eax
    ret
.frs_bad:
    mov rdx, rsi
    mov rsi, rdi
    VALUE_FOR_TYPE rsi, rdx     ; a payload, back to something that names a type
    CSTRING rdi, `__format__ must return a str, not \x01`
    sub rsp, 8                  ; bare: realign for the call
    call set_type_error_with_name
    add rsp, 8
    mov rax, -1
    ret
END_FUNC format_require_str

;; ============================================================================
;; fs_printf_precision() -> nothing (FS_BODY replaced when it has to grow)
;;
;; A local, not a function, exactly as fs_apply_grouping beside it is: it
;; reads and writes the caller's FS_* slots, so it must not push a frame of
;; its own -- one that did read FS_PRINTF out of its own locals and padded
;; nothing.  Everything it needs lives in registers for the same reason.
;;
;; printf's precision on `d i u o x X` is a MINIMUM DIGIT COUNT, not a
;; truncation: '%.3d' % 5 is '005'.  The digits start FS_SIGNCH bytes into the
;; body -- format_int_body records exactly that, the count of leading
;; characters before the first digit, so a sign and an 0x prefix are both
;; already accounted for -- and the zeros go in right there, before .fs_pad
;; applies the field width on top.
;;
;; A precision of zero takes nothing away: '%.0d' % 0 is '0' in Python, where
;; C's printf gives the empty string.  Measured, not assumed -- the first
;; version followed C here and was wrong.
;; ============================================================================
fs_printf_precision:
    cmp qword [rbp - FS_PRINTF], 0
    je .fpp_done
    cmp qword [rbp - FS_PREC], -1
    je .fpp_done
    cmp qword [rbp - FS_BODY], 0
    je .fpp_done
    push rbx
    push r12
    push r13
    ; NO `sub rsp, 8`.  This is a bare label reached by `call`, so rsp arrives
    ; 8 mod 16 and three pushes put it back at 0 -- already what the ABI wants
    ; before a call.  The pad MADE the calls below misaligned rather than
    ; aligning them, and lint cannot see it: it checks DEF_FUNC prologues and
    ; opcode handlers, not a local label with a push list of its own.
    mov rbx, [rbp - FS_BODY]

    ; digits already present = length - the leading characters
    mov r12, [rbx + PyStrObject.ob_size]
    sub r12, [rbp - FS_SIGNCH]
    js .fpp_out

    mov r13, [rbp - FS_PREC]

.fpp_pad:
    sub r13, r12                ; how many zeros to insert
    jle .fpp_out
    mov rdi, [rbx + PyStrObject.ob_size]
    add rdi, r13
    mov rsi, rdi                ; all ASCII, so bytes and code points agree
    call str_alloc_bytes
    test rax, rax
    jz .fpp_out
    push rax                    ; the new body, while the copies run
    sub rsp, 8

    ; the leading characters, as they were
    mov rdx, [rbp - FS_SIGNCH]
    test rdx, rdx
    jz .fpp_zeros
    lea rdi, [rax + PyStrObject.data]
    lea rsi, [rbx + PyStrObject.data]
    call ap_memcpy

.fpp_zeros:
    mov rax, [rsp + 8]
    lea rdi, [rax + PyStrObject.data]
    add rdi, [rbp - FS_SIGNCH]
    mov rcx, r13
.fpp_zero_loop:
    test rcx, rcx
    jz .fpp_digits
    mov byte [rdi], '0'
    inc rdi
    dec rcx
    jmp .fpp_zero_loop

.fpp_digits:
    mov rdx, r12
    test rdx, rdx
    jz .fpp_copied
    mov rax, [rsp + 8]
    lea rdi, [rax + PyStrObject.data]
    add rdi, [rbp - FS_SIGNCH]
    add rdi, r13
    lea rsi, [rbx + PyStrObject.data]
    add rsi, [rbp - FS_SIGNCH]
    call ap_memcpy
.fpp_copied:
    add rsp, 8
    pop r13                     ; r13 = the new body

.fpp_swap:
    mov rdi, rbx
    call obj_decref
    mov [rbp - FS_BODY], r13
.fpp_out:
    pop r13
    pop r12
    pop rbx
.fpp_done:
    ret
