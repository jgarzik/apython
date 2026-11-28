; pyo/bytes_decode.asm - bytes -> str, and why it sometimes cannot be
;
; b.decode() for the three codecs that are not a table -- utf-8, ascii and
; latin-1 -- the UTF-8 validator underneath them, and the UnicodeDecodeError
; that reports a failure the way CPython words it.
;
; Split out of pyo/bytes.asm when that file reached the 100k cap.  The seam is
; a real one: nothing here is reached except through decode, and nothing here
; touches the bytes object except to read its data.  What stayed behind is
; bytes ITSELF -- the type, the sequence protocol, repr, comparison, the `%`
; operator and the constructors.
;
; The invariant the whole file is built on: bytes_utf8_check answers WHERE the
; first malformed byte is and WHY, in CPython's three words, and every error
; path here is that answer formatted.  A codec that decides on its own what
; went wrong will disagree with CPython on the message even when it agrees on
; the exception.

%include "macros.inc"
%include "object.inc"

extern str_new_heap
extern str_new
extern str_from_cstr
extern str_from_cstr_heap
extern exc_UnicodeDecodeError_type
extern exc_new
extern exc_setattr
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_MemoryError_type
extern exc_LookupError_type
extern tuple_type
extern tuple_new
extern set_exception
extern obj_incref
extern obj_decref
extern obj_dealloc
extern none_singleton
extern str_type
extern bytes_type
extern ap_malloc
extern ap_free
extern ap_realloc
extern ap_memcpy
extern ap_memcmp
extern ap_strcmp
extern ap_strlen
extern int_to_i64
extern type_is_subtype
extern codec_error_id

section .text

;; ============================================================================
;; bytes_check_errors_type(rdi = the errors= Value) -> rax = 0
;; Fails: -1
;;
;; Absent is "strict"; anything present must be a str, None included --
;; which is what CPython requires here, unlike open()'s errors=.
;; ============================================================================
DEF_FUNC bytes_check_errors_type
    test rdi, rdi
    jz .bcet_ok                 ; the argument was not passed at all
    V_TEST_PTR rdi, rax
    ja .bcet_bad
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .bcet_ok
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jnz .bcet_ok
.bcet_bad:
    ; CPython names the type: "must be str, not None".
    push rdi
    TS_LEA rdi, ts_errbuf
    lea rsi, [rel bd_msg_errtype]
    call bd_copy
    pop rsi
    mov rdi, rax
    call bd_append_typename
    lea rdi, [rel exc_TypeError_type]
    TS_LEA rsi, ts_errbuf
    extern set_exception
    call set_exception
    mov rax, -1
    leave
    ret
.bcet_ok:
    xor eax, eax
    leave
    ret
END_FUNC bytes_check_errors_type

;; ============================================================================
;; bytes_set_decode_error(rdi = the bytes, rsi = position, rdx = reason,
;;   rcx = span, r8 = codec name) -> rax = 0, with the UnicodeDecodeError
;;   pending.  It only ever fails, so it carries no Fails: line; a caller goes
;;   to its own error exit.
;;
;; "'utf-8' codec can't decode byte 0xff in position 3: invalid start byte" --
;; CPython's wording, built here because str() of a UnicodeDecodeError does
;; not render its fields (once in the old bug list).  Without the text the exception says
;; nothing about which byte or where.
;; ============================================================================
BRD_POS   equ 8
BRD_SPAN  equ 16
BRD_SELF  equ 24
BRD_CODEC equ 32
BRD_REASON equ 40
BRD_FRAME equ 56            ; + 1 push = 64, 16-aligned

DEF_FUNC bytes_set_decode_error, BRD_FRAME
    push rbx
    mov [rbp - BRD_POS], rsi
    mov [rbp - BRD_SPAN], rcx
    mov [rbp - BRD_SELF], rdi
    mov rbx, rdx                ; the reason
    ; The codec is a parameter now: the ascii arm raised
    ; "byte not in range for this encoding", which says neither which byte
    ; nor where, and named no codec at all.
    lea rax, [rel bd_codec_utf8]
    test r8, r8
    jz .brd_have_codec
    mov rax, r8
.brd_have_codec:
    mov [rbp - BRD_CODEC], rax
    cmp rcx, 1
    jg .brd_range               ; more than one byte is reported as a range

    ; The offending byte, as two lowercase hex digits.
    movzx eax, byte [rdi + PyBytesObject.data + rsi]
    mov rcx, rax
    shr rcx, 4
    and eax, 0x0f
    lea rdx, [rel bd_hexdigits]
    movzx ecx, byte [rdx + rcx]     ; the high digit
    movzx eax, byte [rdx + rax]     ; the low one
    push rcx
    push rax
    TS_LEA rdi, ts_errbuf
    lea rsi, [rel bd_quote]
    call bd_copy
    mov rdi, rax
    mov rsi, [rbp - BRD_CODEC]
    call bd_copy
    mov rdi, rax
    lea rsi, [rel bd_quote]
    call bd_copy
    mov rdi, rax
    lea rsi, [rel bd_msg_head]
    call bd_copy
    pop rdx                         ; low
    pop rcx                         ; high
    mov [rax], cl
    mov [rax + 1], dl
    add rax, 2
    mov byte [rax], 0
    mov rdi, rax
    lea rsi, [rel bd_msg_inpos]
    call bd_copy
    mov rdi, rax
    mov rsi, [rbp - BRD_POS]
    call bd_append_i64
    mov rdi, rax
    lea rsi, [rel bd_msg_colon]
    call bd_copy
    mov rdi, rax
    call .brd_reason_text
    mov [rbp - BRD_REASON], rsi
    call bd_copy
    jmp .brd_finish

.brd_range:
    ; "can't decode bytes in position 0-1", which is what CPython says when
    ; the input ends in the middle of a sequence.
    TS_LEA rdi, ts_errbuf
    lea rsi, [rel bd_quote]
    call bd_copy
    mov rdi, rax
    mov rsi, [rbp - BRD_CODEC]
    call bd_copy
    mov rdi, rax
    lea rsi, [rel bd_quote]
    call bd_copy
    mov rdi, rax
    lea rsi, [rel bd_msg_bytes]
    call bd_copy
    mov rdi, rax
    mov rsi, [rbp - BRD_POS]
    call bd_append_i64
    mov rdi, rax
    lea rsi, [rel bd_msg_dash]
    call bd_copy
    mov rdi, rax
    mov rsi, [rbp - BRD_POS]
    add rsi, [rbp - BRD_SPAN]
    dec rsi
    call bd_append_i64
    mov rdi, rax
    lea rsi, [rel bd_msg_colon]
    call bd_copy
    mov rdi, rax
    call .brd_reason_text
    mov [rbp - BRD_REASON], rsi
    call bd_copy

.brd_finish:
    ; The five fields CPython puts on a UnicodeDecodeError.  The stdlib's
    ; error handlers read every one of them: `e.start`, `e.end` and
    ; `e.object` are how a replacement handler knows what to replace.  This
    ; raised a bare message with none of them.
    TS_LEA rdi, ts_errbuf
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    mov rsi, rax
    lea rdi, [rel exc_UnicodeDecodeError_type]
    mov edx, TAG_PTR
    call exc_new
    add rsp, 8
    pop rdi
    push rax                    ; the exception
    sub rsp, 8
    call obj_decref             ; exc_new took its own reference to the message
    mov rbx, [rsp + 8]

    CSTRING rdi, "encoding"
    mov rsi, [rbp - BRD_CODEC]
    call .brd_set_str_field
    CSTRING rdi, "reason"
    mov rsi, [rbp - BRD_REASON]
    call .brd_set_str_field

    CSTRING rdi, "object"
    mov rsi, [rbp - BRD_SELF]
    INCREF rsi
    call .brd_set_field

    CSTRING rdi, "start"
    mov rsi, [rbp - BRD_POS]
    V_PACK_I64 rsi, rcx
    call .brd_set_field
    CSTRING rdi, "end"
    mov rsi, [rbp - BRD_POS]
    add rsi, [rbp - BRD_SPAN]
    V_PACK_I64 rsi, rcx
    call .brd_set_field

    add rsp, 8
    pop rdi
    extern exc_install
    call exc_install            ; takes the reference
    xor eax, eax
    pop rbx
    leave
    ret

;; .brd_reason_text -- rbx = the reason id -> rsi = the text
.brd_reason_text:
    lea rsi, [rel bd_reason_start]
    cmp rbx, 1
    jne .brd_reason_2
    lea rsi, [rel bd_reason_cont]
    ret
.brd_reason_2:
    cmp rbx, 2
    jne .brd_reason_3
    lea rsi, [rel bd_reason_end]
    ret
.brd_reason_3:
    cmp rbx, 3
    jne .brd_reason_done
    lea rsi, [rel bd_reason_ascii]
.brd_reason_done:
    ret

;; .brd_set_str_field(rdi = the field's name, rsi = a C string) -- makes the
;; string and hands it to .brd_set_field, which takes over the reference.
.brd_set_str_field:
    push rdi
    sub rsp, 8
    mov rdi, rsi
    call str_from_cstr_heap
    mov rsi, rax
    add rsp, 8
    pop rdi
    ; fall through

;; .brd_set_field(rdi = the field's name, rsi = an owned Value)
;; rbx holds the exception.
.brd_set_field:
    push rsi                    ; [rsp] = the value
    push rdi
    sub rsp, 8
    mov rdi, [rsp + 8]
    call str_from_cstr_heap
    add rsp, 8
    pop rdi                     ; the name cstring, done with
    push rax                    ; [rsp] = the key, [rsp+8] = the value
    sub rsp, 8
    mov rdi, rbx
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    xor ecx, ecx
    call exc_setattr        ; err: no field name, so no refusal
    add rsp, 8
    pop rdi
    call obj_decref             ; the key
    pop rdi
    DECREF_V rdi, rcx           ; exc_setattr took its own reference
    ret
END_FUNC bytes_set_decode_error

;; ============================================================================
;; bd_append_typename(rdi = dest, rsi = a Value) -> rax = the new NUL
;;
;; Appends the argument's type NAME, which is what CPython's message ends
;; with.  int, float and None are answered without a type object, because
;; an immediate int and None arrive as a Value that has none to read.
;; ============================================================================
DEF_FUNC_LOCAL bd_append_typename   ; (rdi = dest, rsi = a Value) -> rax
    V_TEST_PTR rsi, rax
    ja .bdt_immediate
    test rsi, rsi
    jz .bdt_int
    LOAD_NONE rax
    cmp rsi, rax
    je .bdt_none                ; CPython prints "not None", not "not NoneType"
    mov rsi, [rsi + PyObject.ob_type]
    mov rsi, [rsi + PyTypeObject.tp_name]
    jmp .bdt_have
.bdt_immediate:
    V_IS_FLOAT rsi, rax
    ja .bdt_int
    lea rsi, [rel bd_name_float]
    jmp .bdt_have
.bdt_none:
    lea rsi, [rel bd_name_none]
    jmp .bdt_have
.bdt_int:
    lea rsi, [rel bd_name_int]
.bdt_have:
    call bd_copy
    leave
    ret
END_FUNC bd_append_typename

;; ============================================================================
;; bd_copy(rdi = dest, rsi = a C string) -> rax = the NUL it wrote
;;
;; Bounded at 100 bytes: every caller is appending into bd_msgbuf, which is
;; fixed, and a message is assembled from several of these in sequence.
;; ============================================================================
DEF_FUNC_LOCAL bd_copy          ; (rdi = dest, rsi = src) -> rax = the NUL
    xor ecx, ecx
.bdc_loop:
    cmp rcx, 100
    jge .bdc_done
    mov al, [rsi + rcx]
    test al, al
    jz .bdc_done
    mov [rdi + rcx], al
    inc rcx
    jmp .bdc_loop
.bdc_done:
    lea rax, [rdi + rcx]
    mov byte [rax], 0
    leave
    ret
END_FUNC bd_copy

;; ============================================================================
;; bd_append_i64(rdi = dest, rsi = n) -> rax = the NUL it wrote
;;
;; Renders a non-negative integer -- a byte position -- in decimal.  It
;; builds backwards into bd_numbuf and then copies, so no caller has to know
;; how many digits it will take.
;; ============================================================================
DEF_FUNC_LOCAL bd_append_i64    ; (rdi = dest, rsi = n) -> rax = the NUL
    mov rax, rsi
    TS_LEA r8, ts_numbuf
    add r8, 24
    mov byte [r8], 0
    mov r9d, 10
.bda_loop:
    xor edx, edx
    div r9
    dec r8
    add dl, '0'
    mov [r8], dl
    test rax, rax
    jnz .bda_loop
    mov rsi, r8
    call bd_copy
    leave
    ret
END_FUNC bd_append_i64

;; ============================================================================
;; bytes_utf8_check(rdi = data, rsi = length) -> rax = the index of the first
;;   byte that is not part of a well-formed sequence, or -1; edx = why
;;
;; 0 = invalid start byte, 1 = invalid continuation byte, 2 = unexpected end
;; of data -- CPython's three reasons, in its words -- and r8 = how many bytes
;; the offending subpart spans, which is 1 for everything except a sequence
;; cut short by the end of the input.  CPython reports that one as a RANGE and
;; replaces the whole of it with a single U+FFFD.  The ranges are UTF-8's
;; and not "anything with the high bit set": overlong forms, surrogates and
;; anything past U+10FFFF are rejected too, which is what makes `strict` mean
;; something.
;; ============================================================================
DEF_FUNC_BARE bytes_utf8_check
    xor rcx, rcx                ; index
.buc_loop:
    cmp rcx, rsi
    jge .buc_valid
    ; ASCII runs, sixteen bytes at a time.  Every byte below 0x80 is a valid
    ; one-byte character with nothing to check, and real input is mostly or
    ; entirely such bytes -- this validator was 70% of a decode.  The moment a
    ; high bit turns up the block is abandoned and the byte ladder below
    ; resumes at the same index, so nothing about the multi-byte cases moves.
    ;
    ; pmovmskb collects the high bit of each byte, so the vector arm needs no
    ; mask constant at all.  That matters more than the width does: the 8-byte
    ; arm's constant cannot be hoisted out of .buc_loop, because the 3-byte
    ; arms below spend r11 on their own bounds -- so a long ASCII run used to
    ; re-execute a ten-byte movabs after every multi-byte character.  Now that
    ; happens only on the way out of the vector arm.
.buc_ascii_vec:
    lea r8, [rcx + 16]
    cmp r8, rsi
    ja .buc_ascii_word_setup
    movdqu xmm0, [rdi + rcx]
    pmovmskb r9d, xmm0
    test r9d, r9d
    jnz .buc_ascii_word_setup
    mov rcx, r8
    cmp rcx, rsi
    jl .buc_ascii_vec
    jmp .buc_valid
.buc_ascii_word_setup:
    mov r11, 0x8080808080808080
.buc_ascii_word:
    lea r8, [rcx + 8]
    cmp r8, rsi
    ja .buc_ascii_done
    mov r9, [rdi + rcx]
    test r9, r11
    jnz .buc_ascii_done
    mov rcx, r8
    cmp rcx, rsi
    jl .buc_ascii_word
    jmp .buc_valid
.buc_ascii_done:
    cmp rcx, rsi
    jge .buc_valid
    movzx eax, byte [rdi + rcx]
    cmp al, 0x80
    jb .buc_one                 ; ASCII
    cmp al, 0xc2
    jb .buc_bad_start           ; a continuation byte, or an overlong C0/C1
    cmp al, 0xe0
    jb .buc_two
    cmp al, 0xf0
    jb .buc_three
    cmp al, 0xf5
    jb .buc_four
.buc_bad_start:
    jmp .buc_bad_start_out

.buc_one:
    inc rcx
    jmp .buc_loop

.buc_two:
    lea r8, [rcx + 1]
    cmp r8, rsi
    jge .buc_short
    movzx r9d, byte [rdi + r8]
    cmp r9d, 0x80
    jb .buc_bad_cont
    cmp r9d, 0xbf
    ja .buc_bad_cont
    add rcx, 2
    jmp .buc_loop

.buc_three:
    ; The second byte's range narrows for E0 (overlong) and ED (surrogates).
    mov r10d, 0x80
    mov r11d, 0xbf
    cmp al, 0xe0
    jne .buc_three_ed
    mov r10d, 0xa0
    jmp .buc_three_go
.buc_three_ed:
    cmp al, 0xed
    jne .buc_three_go
    mov r11d, 0x9f
.buc_three_go:
    lea r8, [rcx + 1]
    cmp r8, rsi
    jge .buc_short
    movzx r9d, byte [rdi + r8]
    cmp r9d, r10d
    jb .buc_bad_cont
    cmp r9d, r11d
    ja .buc_bad_cont
    lea r8, [rcx + 2]
    cmp r8, rsi
    jge .buc_short
    movzx r9d, byte [rdi + r8]
    cmp r9d, 0x80
    jb .buc_bad_cont
    cmp r9d, 0xbf
    ja .buc_bad_cont
    add rcx, 3
    jmp .buc_loop

.buc_four:
    ; F0 is overlong below U+10000; F4 runs past U+10FFFF above 0x8F.
    mov r10d, 0x80
    mov r11d, 0xbf
    cmp al, 0xf0
    jne .buc_four_f4
    mov r10d, 0x90
    jmp .buc_four_go
.buc_four_f4:
    cmp al, 0xf4
    jne .buc_four_go
    mov r11d, 0x8f
.buc_four_go:
    lea r8, [rcx + 1]
    cmp r8, rsi
    jge .buc_short
    movzx r9d, byte [rdi + r8]
    cmp r9d, r10d
    jb .buc_bad_cont
    cmp r9d, r11d
    ja .buc_bad_cont
    lea r8, [rcx + 2]
    cmp r8, rsi
    jge .buc_short
    movzx r9d, byte [rdi + r8]
    cmp r9d, 0x80
    jb .buc_bad_cont
    cmp r9d, 0xbf
    ja .buc_bad_cont
    lea r8, [rcx + 3]
    cmp r8, rsi
    jge .buc_short
    movzx r9d, byte [rdi + r8]
    cmp r9d, 0x80
    jb .buc_bad_cont
    cmp r9d, 0xbf
    ja .buc_bad_cont
    add rcx, 4
    jmp .buc_loop

.buc_bad_start_out:
    mov rax, rcx
    xor edx, edx
    mov r8d, 1
    ret
.buc_bad_cont:
    ; The subpart is the lead byte plus every continuation already accepted,
    ; which is what CPython reports and replaces with ONE U+FFFD.  Counting
    ; it as a single byte gave "byte 0xf0 in position 2" where CPython says
    ; "bytes in position 2-4", and replace emitted three U+FFFD where CPython
    ; emits one.  r8 is the index of the offending continuation, so the run
    ; is however far past the lead it had got.
    mov rax, rcx
    mov edx, 1
    sub r8, rcx
    cmp r8, 1
    jge .buc_cont_span
    mov r8d, 1
.buc_cont_span:
    ret
.buc_short:
    mov rax, rcx
    mov edx, 2
    mov r8, rsi
    sub r8, rcx                 ; everything that is there of the sequence
    ret
.buc_valid:
    mov rax, -1
    xor edx, edx
    mov r8d, 1
    ret
END_FUNC bytes_utf8_check

;; ============================================================================
;; _bytes_decode_impl(rdi = args, rsi = nargs) -> rax = a str Value,
;;   or 0 with an exception set -- b.decode([encoding[, errors]])
;; Fails: 0
;;
;; utf-8 is the bytes as they stand; ascii is that with a range check; latin-1
;; turns each byte into a code point, which is where the byte string and the
;; text stop being the same thing.
;; ============================================================================
BD_SELF   equ 8
BD_OUT    equ 16
BD_POS    equ 24
BD_ERRORS equ 32            ; the errors= argument, a Value
BD_WHY    equ 40            ; which of the three malformations
BD_ERRID  equ 48            ; 1 = ignore, 2 = replace
BD_READ   equ 56            ; the read cursor, while rebuilding
BD_SPAN   equ 64            ; how many bytes the bad subpart covers
BD_ENC    equ 72            ; the encoding argument, for the Python path
BD_FRAME  equ 80            ; + 2 pushes = 96, 16-aligned
DEF_FUNC _bytes_decode_impl, BD_FRAME
    push rbx
    push r12
    mov qword [rbp - BD_ERRORS], 0
    cmp rsi, 3
    jl .bd_no_errors
    mov rax, [rdi + 16]
    mov [rbp - BD_ERRORS], rax
.bd_no_errors:
    ; Checked here rather than on the error path.  It used to be validated
    ; only once a malformation had been found, so a clean decode never looked
    ; at it and b"ab".decode("utf-8", 5) answered 'ab' where CPython raises.
    push rdi
    sub rsp, 8
    mov rdi, [rbp - BD_ERRORS]
    call bytes_check_errors_type
    add rsp, 8
    pop rdi
    ERR_M1 .bd_fail

    mov rbx, [rdi]
    mov [rbp - BD_SELF], rbx
    mov r12, [rbx + PyBytesObject.ob_size]

    ; decode([encoding[, errors]]).  An encoding that is not a str is a
    ; TypeError in CPython, not a silent fall back to utf-8 -- and None is
    ; not a str: `b"ab".decode(None)` is refused there and was taken here as
    ; "use the default".
    cmp rsi, 3
    jg .bd_too_many
    xor eax, eax
    cmp rsi, 2
    jl .bd_have_enc
    mov rax, [rdi + 8]
    V_TEST_PTR rax, rcx
    ja .bd_bad_enc
    test rax, rax
    jz .bd_bad_enc
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .bd_bad_enc
    jmp .bd_have_enc
.bd_have_enc:
    mov [rbp - BD_ENC], rax
    ; Empty input is the empty string whatever the encoding was called:
    ; CPython's PyUnicode_Decode answers before it resolves the codec, so
    ; `b"".decode("nope")` is '' rather than a LookupError.
    test r12, r12
    jz .bd_empty
    mov rdi, rax
    extern codec_id
    call codec_id
    cmp eax, -1
    je .bd_python               ; not one of the three: ask the registry
    cmp eax, 1
    je .bd_ascii
    cmp eax, 2
    je .bd_latin1

.bd_utf8:
    ; Validate before building.  str_new copied the bytes through untouched,
    ; so an invalid sequence became an invalid str: errors="strict" never
    ; raised, and every text file opened here accepted corrupt input in
    ; silence, which is the dangerous half of ignoring the handler.
    mov rbx, [rbp - BD_SELF]
    lea rdi, [rbx + PyBytesObject.data]
    mov rsi, r12
    call bytes_utf8_check
    cmp rax, -1
    je .bd_utf8_ok
    mov [rbp - BD_POS], rax
    mov [rbp - BD_WHY], rdx
    mov [rbp - BD_SPAN], r8
    ; The type was checked in the prologue: codec_error_id answers -1 for
    ; anything that is not one of the three names, including a non-str, and
    ; the message builder then read PyStrObject.data off it.
    mov rdi, [rbp - BD_ERRORS]
    call codec_error_id         ; 0 strict, 1 ignore, 2 replace, -1 unknown
    cmp eax, -1
    je .bd_bad_errors
    test eax, eax
    jz .bd_utf8_strict
    mov [rbp - BD_ERRID], rax
    jmp .bd_utf8_fixup

.bd_utf8_ok:
    mov rbx, [rbp - BD_SELF]
    lea rdi, [rbx + PyBytesObject.data]
    mov rsi, r12
    call str_new
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.bd_utf8_strict:
    mov rdi, [rbp - BD_SELF]
    mov rsi, [rbp - BD_POS]
    mov rdx, [rbp - BD_WHY]
    mov rcx, [rbp - BD_SPAN]
    xor r8d, r8d                ; the default codec name, 'utf-8'
    call bytes_set_decode_error
    jmp .bd_fail

.bd_utf8_fixup:
    ; ignore drops each offending byte, replace puts U+FFFD where it was, so
    ; the result can be three times as long as the input.
    lea rdi, [r12 + r12*2]
    add rdi, PyStrObject.data + 8
    call ap_malloc
    test rax, rax
    jz .bd_nomem
    mov [rbp - BD_OUT], rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel str_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyStrObject.ob_hash], -1
    mov qword [rbp - BD_POS], 0     ; write cursor
    mov qword [rbp - BD_READ], 0    ; read cursor

.bd_fix_loop:
    mov rbx, [rbp - BD_SELF]
    lea rdi, [rbx + PyBytesObject.data]
    add rdi, [rbp - BD_READ]
    mov rsi, r12
    sub rsi, [rbp - BD_READ]
    jle .bd_fix_finish
    call bytes_utf8_check
    cmp rax, -1
    je .bd_fix_tail
    mov [rbp - BD_SPAN], r8

    ; The good run up to the bad byte, then the substitution.
    mov [rbp - BD_WHY], rax         ; the run length, reusing the slot
    mov rdi, [rbp - BD_OUT]
    add rdi, PyStrObject.data
    add rdi, [rbp - BD_POS]
    mov rbx, [rbp - BD_SELF]
    lea rsi, [rbx + PyBytesObject.data]
    add rsi, [rbp - BD_READ]
    mov rdx, rax
    call ap_memcpy
    mov rax, [rbp - BD_WHY]
    add [rbp - BD_POS], rax
    add [rbp - BD_READ], rax
    mov rax, [rbp - BD_SPAN]
    add [rbp - BD_READ], rax        ; step over the whole offending subpart
    cmp qword [rbp - BD_ERRID], 2
    jne .bd_fix_loop
    mov rdx, [rbp - BD_OUT]
    mov r8, [rbp - BD_POS]
    mov byte [rdx + PyStrObject.data + r8], 0xef
    mov byte [rdx + PyStrObject.data + r8 + 1], 0xbf
    mov byte [rdx + PyStrObject.data + r8 + 2], 0xbd
    add qword [rbp - BD_POS], 3
    jmp .bd_fix_loop

.bd_fix_tail:
    ; Everything from the cursor on is well formed.
    mov rdi, [rbp - BD_OUT]
    add rdi, PyStrObject.data
    add rdi, [rbp - BD_POS]
    mov rbx, [rbp - BD_SELF]
    lea rsi, [rbx + PyBytesObject.data]
    add rsi, [rbp - BD_READ]
    mov rdx, r12
    sub rdx, [rbp - BD_READ]
    mov [rbp - BD_WHY], rdx
    call ap_memcpy
    mov rax, [rbp - BD_WHY]
    add [rbp - BD_POS], rax

.bd_fix_finish:
    mov rax, [rbp - BD_OUT]
    mov rcx, [rbp - BD_POS]
    mov [rax + PyStrObject.ob_size], rcx
    mov qword [rax + PyStrObject.data + rcx], 0
    mov rdi, rax
    call str_set_length
    mov rax, [rbp - BD_OUT]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.bd_nomem:
    SET_EXC exc_MemoryError_type, "out of memory"
    ; Every refusal arrives here before anything has been built.
.bd_fail:
    RET_NULL
    pop r12
    pop rbx
    leave
    ret
.bd_python:
    ; Everything this file cannot do itself: an encoding the registry has to
    ; find, and an error handler that is not one of the three built in here.
    ; The second is reached only once a malformation has been found, which is
    ; where CPython looks a handler up as well.
    mov rdi, [rbp - BD_SELF]
    mov rsi, [rbp - BD_ENC]
    mov rdx, [rbp - BD_ERRORS]
    mov ecx, 1                  ; decode
    extern codec_via_python
    call codec_via_python
    pop r12
    pop rbx
    leave
    test edx, edx
    jz .bd_python_failed
    V_PACK rax, rdx
    ret
.bd_python_failed:
    xor eax, eax
    ret

.bd_bad_errors:
    jmp .bd_python

.bd_ascii:
    xor ecx, ecx
.bd_ascii_scan:
    cmp rcx, r12
    jge .bd_utf8
    movzx eax, byte [rbx + PyBytesObject.data + rcx]
    test al, 0x80
    jnz .bd_ascii_bad
    inc rcx
    jmp .bd_ascii_scan

.bd_ascii_bad:
    ; The handler, looked up only now that something has actually failed.
    ; This arm jumped straight to the raise, so `b"a\xffb".decode("ascii",
    ; "ignore")` raised where CPython answers 'ab' -- and an unknown handler
    ; name was never reported as a LookupError on this path either.
    mov [rbp - BD_POS], rcx     ; where it failed, for the message
    mov rdi, [rbp - BD_ERRORS]
    call codec_error_id         ; 0 strict, 1 ignore, 2 replace, -1 unknown
    cmp eax, -1
    je .bd_bad_errors
    test eax, eax
    jz .bd_not_decodable
    mov [rbp - BD_ERRID], rax

    ; replace writes U+FFFD, three bytes, for each byte dropped -- so the
    ; result can be three times as long as the input.
    lea rdi, [r12 + r12*2]
    add rdi, PyStrObject.data + 8
    call ap_malloc
    test rax, rax
    jz .bd_nomem
    mov [rbp - BD_OUT], rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel str_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyStrObject.ob_hash], -1
    mov qword [rbp - BD_POS], 0
    mov rbx, [rbp - BD_SELF]
    xor ecx, ecx
.bd_af_loop:
    cmp rcx, r12
    jge .bd_af_done
    movzx eax, byte [rbx + PyBytesObject.data + rcx]
    test al, 0x80
    jnz .bd_af_bad
    mov rdx, [rbp - BD_OUT]
    mov r8, [rbp - BD_POS]
    mov [rdx + PyStrObject.data + r8], al
    inc qword [rbp - BD_POS]
    inc rcx
    jmp .bd_af_loop
.bd_af_bad:
    inc rcx
    cmp qword [rbp - BD_ERRID], 2
    jne .bd_af_loop             ; ignore
    mov rdx, [rbp - BD_OUT]
    mov r8, [rbp - BD_POS]
    mov byte [rdx + PyStrObject.data + r8], 0xef
    mov byte [rdx + PyStrObject.data + r8 + 1], 0xbf
    mov byte [rdx + PyStrObject.data + r8 + 2], 0xbd
    add qword [rbp - BD_POS], 3
    jmp .bd_af_loop
.bd_af_done:
    mov rax, [rbp - BD_OUT]
    mov rcx, [rbp - BD_POS]
    mov [rax + PyStrObject.ob_size], rcx
    mov qword [rax + PyStrObject.data + rcx], 0
    mov rdi, rax
    extern str_set_length
    call str_set_length
    mov rax, [rbp - BD_OUT]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.bd_latin1:
    ; Each byte is one code point, so a byte at or above 0x80 becomes two
    ; bytes of UTF-8: the result can be twice as long.
    lea rdi, [r12 + r12]
    add rdi, PyStrObject.data + 8
    call ap_malloc
    mov [rbp - BD_OUT], rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel str_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyStrObject.ob_hash], -1
    mov [rax + PyStrObject.ob_length], r12
    mov qword [rbp - BD_POS], 0
    xor ecx, ecx
.bd_l1_loop:
    cmp rcx, r12
    jge .bd_l1_done
    mov rbx, [rbp - BD_SELF]
    movzx eax, byte [rbx + PyBytesObject.data + rcx]
    mov rdx, [rbp - BD_OUT]
    mov r8, [rbp - BD_POS]
    test al, 0x80
    jnz .bd_l1_two
    mov [rdx + PyStrObject.data + r8], al
    inc qword [rbp - BD_POS]
    jmp .bd_l1_next
.bd_l1_two:
    mov r9d, eax
    shr r9d, 6
    or r9b, 0xc0
    mov [rdx + PyStrObject.data + r8], r9b
    and eax, 0x3f
    or al, 0x80
    mov [rdx + PyStrObject.data + r8 + 1], al
    add qword [rbp - BD_POS], 2
.bd_l1_next:
    inc rcx
    jmp .bd_l1_loop
.bd_l1_done:
    mov rax, [rbp - BD_OUT]
    mov rcx, [rbp - BD_POS]
    mov [rax + PyStrObject.ob_size], rcx
    mov qword [rax + PyStrObject.data + rcx], 0
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.bd_bad_enc:
    ; Composed rather than handed to raise_type_error_with_name, because
    ; CPython's argument clinic writes "not None" here where the tp_name is
    ; "NoneType" -- and it is the clinic's wording a program greps for.
    push rax
    TS_LEA rdi, ts_errbuf
    lea rsi, [rel bd_msg_enctype]
    call bd_copy
    pop rsi
    mov rdi, rax
    call bd_append_typename
    lea rdi, [rel exc_TypeError_type]
    TS_LEA rsi, ts_errbuf
    call set_exception
    jmp .bd_fail
.bd_empty:
    CSTRING rdi, ""
    xor esi, esi
    extern str_new_heap
    call str_new_heap
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.bd_too_many:
    FAIL exc_TypeError_type, "decode() takes at most 2 arguments", .bd_fail

.bd_not_decodable:
    ; "'ascii' codec can't decode byte 0xff in position 2: ordinal not in
    ; range(128)".  This said "byte not in range for this encoding", which
    ; names neither the codec, nor the byte, nor where it was.
    mov rdi, [rbp - BD_SELF]
    mov rsi, [rbp - BD_POS]
    mov edx, 3                  ; "ordinal not in range(128)"
    mov ecx, 1
    lea r8, [rel bd_codec_ascii]
    call bytes_set_decode_error
    jmp .bd_fail
END_FUNC _bytes_decode_impl

section .rodata

bd_hexdigits:     db "0123456789abcdef"
bd_codec_utf8:    db "utf-8", 0
bd_codec_ascii:   db "ascii", 0
bd_quote:         db "'", 0
bd_msg_head:      db " codec can't decode byte 0x", 0
bd_msg_inpos:     db " in position ", 0
bd_msg_colon:     db ": ", 0
bd_msg_bytes:     db " codec can't decode bytes in position ", 0
bd_msg_dash:      db "-", 0
bd_msg_handler:   db "unknown error handler name '", 0
bd_msg_errtype:   db "decode() argument 'errors' must be str, not ", 0
bd_msg_enctype:   db "decode() argument 'encoding' must be str, not ", 0
bd_reason_start:  db "invalid start byte", 0
bd_reason_cont:   db "invalid continuation byte", 0
bd_reason_end:    db "unexpected end of data", 0
bd_reason_ascii:  db "ordinal not in range(128)", 0
bd_name_int:      db "int", 0
bd_name_float:    db "float", 0
bd_name_none:     db "None", 0

section .bss
bd_msgbuf: resb 192
bd_numbuf: resb 32

section .text
