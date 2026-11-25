; exc_str.asm - how an exception renders itself
;
; repr() and str() for every exception, and the two that are not the general
; case: SyntaxError, which shows the file, the line and a caret before it says
; what was wrong, and UnicodeError, whose str() is assembled from five named
; attributes rather than from .args.
;
; Split out of exception.asm when that file reached the hand-written 100k cap,
; along the seam it already had: what stayed is the exception ITSELF -- the
; type table, construction, teardown, attribute access and the methods -- and
; what came here is only the text it produces.  The same split bytes.asm made
; for bytes_decode.asm and dict.asm made for dict_views.asm.

%include "macros.inc"
%include "object.inc"

extern ap_memcpy
extern exc_KeyError_type
extern exc_OSError_type
extern exc_SyntaxError_type
extern exc_UnicodeDecodeError_type
extern exc_UnicodeEncodeError_type
extern exc_isinstance
extern int_to_i64
extern int_type
extern obj_decref
extern obj_repr
extern obj_str
extern oserror_str
extern str_from_cstr
extern str_new_heap
extern str_type
extern tuple_type
extern ues_byte
extern ues_bytes_pl
extern ues_char
extern ues_chars_pl
extern ues_codec
extern ues_colon
extern ues_dash
extern ues_decode_w
extern ues_encode_w
extern ues_in_pos
extern ues_quote

;; ============================================================================
;; exc_repr(PyExceptionObject *exc) -> PyObject* (string)
;; Returns "TypeName(msg)" or just "TypeName()" if no message.
;; ============================================================================
ER_EXC   equ 8
ER_POS   equ 16
ER_BUF   equ 528         ; 512 bytes, [rbp-528, rbp-16)
ER_FRAME equ 552            ; + 3 pushes = 576, 16-aligned
global exc_repr
DEF_FUNC exc_repr, ER_FRAME
    push rbx
    push r12
    push r13

    mov rbx, rdi
    mov [rbp - ER_EXC], rdi

    ; repr(exc) is TypeName(arg_reprs...).  This printed the stored value
    ; unquoted and only ever one of them, so repr(ValueError('a','b')) was
    ; "ValueError(a)".
    lea rdi, [rbp - ER_BUF]
    xor r13d, r13d                  ; output length
    mov rax, [rbx + PyExceptionObject.ob_type]
    mov rsi, [rax + PyTypeObject.tp_name]
.er_copy_name:
    movzx eax, byte [rsi]
    test al, al
    jz .er_name_done
    cmp r13, 480
    jge .er_name_done
    mov [rdi + r13], al
    inc r13
    inc rsi
    jmp .er_copy_name
.er_name_done:
    mov byte [rdi + r13], '('
    inc r13

    mov rax, [rbx + PyExceptionObject.exc_args]
    test rax, rax
    jz .er_close
    mov r12, [rax + PyTupleObject.ob_size]
    xor ecx, ecx
    mov [rbp - ER_POS], rcx
.er_arg_loop:
    mov rcx, [rbp - ER_POS]
    cmp rcx, r12
    jge .er_close
    test rcx, rcx
    jz .er_no_comma
    lea rdi, [rbp - ER_BUF]
    mov byte [rdi + r13], ','
    mov byte [rdi + r13 + 1], ' '
    add r13, 2
.er_no_comma:
    mov rax, [rbx + PyExceptionObject.exc_args]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdi, [rax + rcx * 8]
    call obj_repr
    V_UNPACK rax, rdx
    test rax, rax
    jz .er_next
    push rax
    mov r8, [rax + PyStrObject.ob_size]
    lea rsi, [rax + PyStrObject.data]
    lea rdi, [rbp - ER_BUF]
    xor ecx, ecx
.er_copy_arg:
    cmp rcx, r8
    jge .er_arg_copied
    cmp r13, 500
    jge .er_arg_copied
    movzx eax, byte [rsi + rcx]
    mov [rdi + r13], al
    inc r13
    inc rcx
    jmp .er_copy_arg
.er_arg_copied:
    pop rdi
    call obj_decref
.er_next:
    inc qword [rbp - ER_POS]
    jmp .er_arg_loop

.er_close:
    lea rdi, [rbp - ER_BUF]
    mov byte [rdi + r13], ')'
    inc r13
    mov rsi, r13
    call str_new_heap
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC exc_repr

;; ============================================================================
;; exc_is_syntax(PyObject *exc) -> eax = 1 when it is a SyntaxError carrying a
;; location: args == (msg, (filename, lineno, offset, text)).
;; ============================================================================
global exc_is_syntax
DEF_FUNC exc_is_syntax, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    lea rsi, [rel exc_SyntaxError_type]
    call exc_isinstance     ; err: a static type is never refused
    test eax, eax
    jz .no
    mov rax, [rbx + PyExceptionObject.exc_args]
    test rax, rax
    jz .no
    cmp qword [rax + PyTupleObject.ob_size], 2
    jne .no
    mov rax, [rax + PyTupleObject.ob_item]
    mov rax, [rax + 8]
    V_TEST_PTR rax, rcx
    ja .no
    test rax, rax
    jz .no
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    jne .no
    ; Four fields, or CPython's six with end_lineno and end_offset.
    cmp qword [rax + PyTupleObject.ob_size], 4
    jl .no
    mov eax, 1
    pop rbx
    leave
    ret
.no:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC exc_is_syntax

;; ============================================================================
;; exc_syntax_str(PyObject *exc) -> PyStrObject*
;;
;; "invalid syntax (f.py, line 1)" -- CPython's SyntaxError_str, which appends
;; the basename of the filename and the line number to the message.  Each half
;; is dropped when its field is not there, so `SyntaxError('m', (None, 1, 1,
;; 't'))` renders as "m (line 1)" and one with neither is the bare message.
;;
;; This was the bare message, which is the form every tool that prints a caught
;; SyntaxError itself shows.  The traceback block carries the location
;; separately, so the difference was invisible in tracebacks and present
;; everywhere else.
;; ============================================================================
SS_MSG   equ 8              ; the str() of args[0], owned
SS_LOC   equ 16             ; the location tuple, borrowed
SS_DIG   equ 56             ; 32 bytes: the line number's digits, backwards
SS_BUF   equ 584            ; 512 bytes of assembly space, at the bottom
SS_FRAME equ 584            ; + 3 pushes = 608
global exc_syntax_str
DEF_FUNC exc_syntax_str, SS_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi

    mov rax, [rdi + PyExceptionObject.exc_args]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdi, [rax]
    call obj_str
    V_UNPACK rax, rdx
    test rax, rax
    jz .ss_out
    mov [rbp - SS_MSG], rax

    ; Only a located SyntaxError gets a suffix.
    mov rdi, rbx
    call exc_is_syntax
    test eax, eax
    jz .ss_bare
    mov rax, [rbx + PyExceptionObject.exc_args]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rax, [rax + 8]
    mov [rbp - SS_LOC], rax

    ; The message first, truncated to leave room for the suffix.
    mov r13, [rbp - SS_MSG]
    mov rdx, [r13 + PyStrObject.ob_size]
    cmp rdx, 400
    jle .ss_msg_len
    mov edx, 400
.ss_msg_len:
    lea rdi, [rbp - SS_BUF]
    lea rsi, [r13 + PyStrObject.data]
    mov r12, rdi
    add r12, rdx                        ; where the suffix will start
    call ap_memcpy

    ; " (basename", if there is a filename.  CPython prints the basename only.
    mov rax, [rbp - SS_LOC]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rax, [rax]
    V_TEST_PTR rax, rcx
    ja .ss_no_file
    test rax, rax
    jz .ss_no_file
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .ss_no_file

    mov word [r12], ' ('                ; ' ' then '(' -- NASM is little-endian
    add r12, 2
    lea rsi, [rax + PyStrObject.data]
    mov rcx, [rax + PyStrObject.ob_size]
    add rcx, rsi                        ; one past the end
    mov r8, rsi
.ss_base:
    cmp r8, rcx
    jae .ss_base_done
    cmp byte [r8], '/'
    jne .ss_base_next
    lea rsi, [r8 + 1]
.ss_base_next:
    inc r8
    jmp .ss_base
.ss_base_done:
    sub rcx, rsi                        ; what is left of it is the basename
    cmp rcx, 100
    jle .ss_base_len
    mov ecx, 100
.ss_base_len:
    mov rdx, rcx
    mov rdi, r12
    add r12, rdx
    call ap_memcpy
    mov r13d, 1                         ; the parenthesis is open
    jmp .ss_line

.ss_no_file:
    xor r13d, r13d
.ss_line:
    ; ", line N", or " (line N" when there was no filename to open with.
    mov rax, [rbp - SS_LOC]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rax, [rax + 8]
    ; The line may be an immediate or a heap int: the exception's args are
    ; whatever the caller put there, and past +-2^50 -- or under INT_STRESS,
    ; past 8 -- an ordinary line number is boxed.
    V_IS_INT rax, rcx
    jae .ss_line_imm
    V_TEST_PTR rax, rcx
    ja .ss_close
    test rax, rax
    jz .ss_close
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel int_type]
    cmp rcx, rdx
    jne .ss_close
    mov rdi, rax
    mov edx, TAG_PTR
    call int_to_i64
    jmp .ss_line_have
.ss_line_imm:
    V_TO_I64 rax
.ss_line_have:
    test r13d, r13d
    jnz .ss_line_sep
    mov word [r12], ' ('
    add r12, 2
    mov r13d, 1
    jmp .ss_line_word
.ss_line_sep:
    mov word [r12], ', '                ; ',' then ' '
    add r12, 2
.ss_line_word:
    mov dword [r12], 'line'
    mov byte [r12 + 4], ' '
    add r12, 5

    ; The digits, least significant first into a scratch and then reversed.
    xor r8d, r8d
.ss_digit:
    xor edx, edx
    mov ecx, 10
    div rcx                             ; rax = rax/10, rdx = the digit
    add dl, '0'
    mov [rbp - SS_DIG + r8], dl
    inc r8
    test rax, rax
    jnz .ss_digit
.ss_emit:
    dec r8
    mov dl, [rbp - SS_DIG + r8]
    mov [r12], dl
    inc r12
    test r8, r8
    jnz .ss_emit

.ss_close:
    test r13d, r13d
    jz .ss_finish
    mov byte [r12], ')'
    inc r12
.ss_finish:
    lea rdi, [rbp - SS_BUF]
    mov rsi, r12
    sub rsi, rdi                        ; the length written
    call str_new_heap
    test rax, rax
    jz .ss_bare
    mov rdi, [rbp - SS_MSG]
    mov [rbp - SS_MSG], rax
    call obj_decref
.ss_bare:
    mov rax, [rbp - SS_MSG]
.ss_out:
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC exc_syntax_str


;; ============================================================================
;; exc_str(PyExceptionObject *exc) -> PyObject* (string)
;; Returns the message string, or type name if no message.
;; ============================================================================
ES_EXC   equ 8
ES_FRAME equ 24            ; + 1 push = 32, 16-aligned
global exc_str
DEF_FUNC exc_str, ES_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - ES_EXC], rdi

    ; str(exc) is defined by args, not by a single stored value: '' for none,
    ; str(args[0]) for one, and the tuple's repr for more.  This returned the
    ; stored value when it happened to be a string and the *type name*
    ; otherwise, so str(ValueError()) was "ValueError" and
    ; str(ValueError("a","b")) was "a".
    mov rax, [rbx + PyExceptionObject.exc_args]
    test rax, rax
    jz .es_empty
    mov rcx, [rax + PyTupleObject.ob_size]
    test rcx, rcx
    jz .es_empty
    ; An OSError renders as "[Errno N] strerror: 'file' -> 'file2'".  The test
    ; is exc_isinstance, not the exact-pointer compare the KeyError arm below
    ; uses, or every subclass -- which is what os actually raises -- would miss
    ; it.  Fixing this fixes the uncaught-OSError traceback line too, since
    ; traceback.asm renders tp_name + ": " + obj_str(exc).
    mov rdi, rbx
    lea rsi, [rel exc_OSError_type]
    call exc_isinstance     ; err: a static type is never refused
    test eax, eax
    jz .es_check_syntax
    mov rdi, rbx
    call oserror_str
    cmp rax, -1
    je .es_raised
    test rax, rax
    jz .es_check_syntax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.es_raised:
    xor eax, eax                    ; a NULL Value, with the exception pending
    xor edx, edx
    pop rbx
    leave
    ret

.es_check_syntax:
    mov rax, [rbx + PyExceptionObject.exc_args]
    mov rcx, [rax + PyTupleObject.ob_size]

    ; A syntax error's args are (msg, (filename, lineno, offset, text)), and
    ; str() renders the pair the way CPython does rather than showing the
    ; tuple: "msg (filename, line N)".
    cmp rcx, 2
    jne .es_not_syntax
    mov rdi, rbx
    call exc_is_syntax
    test eax, eax
    jz .es_not_syntax
    mov rdi, rbx
    call exc_syntax_str
    test rax, rax
    jz .es_not_syntax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.es_not_syntax:
    ; exc_is_syntax is a call, so the args pointer and the count it left in rax
    ; and rcx are gone; both have to come back before the ordinary paths use
    ; them.
    mov rax, [rbx + PyExceptionObject.exc_args]
    mov rcx, [rax + PyTupleObject.ob_size]

    ; A Unicode{Decode,Encode}Error carries five arguments -- encoding,
    ; object, start, end, reason -- and CPython renders them into a sentence.
    ; Falling through to .es_tuple printed the tuple instead, so str() of one
    ; raised from lib/_codecs.py was "('ascii', b'abc', 1, 2, 'ordinal not in
    ; range(128)')".  The asm sites that raise these build the sentence
    ; themselves for exactly that reason; now they need not.
    cmp rcx, 5
    jne .es_not_unicode
    mov rdi, rbx
    call unicode_error_str
    test rax, rax
    jz .es_not_unicode
    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.es_not_unicode:
    mov rax, [rbx + PyExceptionObject.exc_args]
    mov rcx, [rax + PyTupleObject.ob_size]

    cmp rcx, 1
    jne .es_tuple

    ; KeyError is the one that shows its single argument's repr, so that a
    ; missing key prints with its quotes -- and so does a SUBCLASS of it.
    ; CPython gives KeyError its own tp_str and subclasses inherit it; this
    ; was an exact-pointer compare, so `class K(KeyError)` lost the quotes.
    push rax
    push rax                        ; exc_args, and a pad for the alignment
    mov rdi, [rbx + PyExceptionObject.ob_type]
    lea rsi, [rel exc_KeyError_type]
    extern type_is_subtype
    call type_is_subtype
    pop rcx
    pop rcx                         ; exc_args back
    test eax, eax
    mov rax, rcx
    jnz .es_one_repr

    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdi, [rcx]
    call obj_str
    V_UNPACK rax, rdx
    pop rbx
    leave
    ret

.es_one_repr:
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdi, [rcx]
    call obj_repr
    V_UNPACK rax, rdx
    pop rbx
    leave
    ret

.es_tuple:
    mov rdi, rax
    call obj_repr
    V_UNPACK rax, rdx
    pop rbx
    leave
    ret

.es_empty:
    ; A SyntaxError renders its msg, and with no args at all the msg is None:
    ; CPython's str(SyntaxError()) is "None", not the empty string every other
    ; argument-less exception gives.
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    call exc_isinstance     ; err: a static type is never refused
    test eax, eax
    jz .es_empty_str
    CSTRING rdi, "None"
    call str_from_cstr
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.es_empty_str:
    CSTRING rdi, ""
    call str_from_cstr
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
END_FUNC exc_str

;; ============================================================================
;; unicode_error_str(rdi = the exception) -> rax = PyStrObject*, or 0
;;
;; CPython's wording for a UnicodeDecodeError or UnicodeEncodeError, out of the
;; five arguments the exception carries:
;;
;;   'ascii' codec can't decode byte 0xc3 in position 1: ordinal not in range(128)
;;   'ascii' codec can't encode character '\u1234' in position 1: <reason>
;;
;; and the plural forms when the span is wider than one.  Answers 0 for
;; anything that is not one of the two types, or whose arguments are not the
;; shapes below, so exc_str falls back to the tuple repr.
;; ============================================================================
UES_EXC   equ 8
UES_ARGS  equ 16
UES_START equ 24
UES_END   equ 32
UES_BUF   equ 288           ; the sentence, built in place
UES_FRAME equ 296            ; + 1 push = 304, 16-aligned

extern rbt_append_cstr
extern msg_append_i64
extern msg_append_hex2
extern msg_append_escaped_cp
extern str_cp_at
global unicode_error_str
DEF_FUNC unicode_error_str, UES_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - UES_EXC], rdi

    ; Which of the two, and therefore which verb?
    mov rdi, rbx
    lea rsi, [rel exc_UnicodeDecodeError_type]
    call exc_isinstance     ; err: a static type is never refused
    test eax, eax
    jnz .ues_decode
    mov rdi, rbx
    lea rsi, [rel exc_UnicodeEncodeError_type]
    call exc_isinstance     ; err: a static type is never refused
    test eax, eax
    jz .ues_no
    xor r9d, r9d                ; encode
    jmp .ues_have_kind
.ues_decode:
    mov r9d, 1                  ; decode
.ues_have_kind:
    mov [rbp - UES_START], r9   ; borrow the slot until the args are read

    mov rax, [rbx + PyExceptionObject.exc_args]
    mov rax, [rax + PyTupleObject.ob_item]
    mov [rbp - UES_ARGS], rax

    ; args[0] must be a str, args[2] and args[3] ints, args[4] a str.
    mov rdi, [rax]
    V_TEST_PTR rdi, rcx
    ja .ues_no
    mov rcx, [rdi + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .ues_no
    mov rdi, [rax + 32]
    V_TEST_PTR rdi, rcx
    ja .ues_no
    mov rcx, [rdi + PyObject.ob_type]
    cmp rcx, rdx
    jne .ues_no

    mov r9, [rbp - UES_START]   ; the kind, before the slot is reused
    mov rdi, [rax + 16]
    V_IS_INT rdi, rcx
    jb .ues_no
    V_TO_I64 rdi
    mov [rbp - UES_START], rdi
    mov rax, [rbp - UES_ARGS]
    mov rdi, [rax + 24]
    V_IS_INT rdi, rcx
    jb .ues_no
    V_TO_I64 rdi
    mov [rbp - UES_END], rdi

    ; "'<encoding>' codec can't "
    lea rdi, [rbp - UES_BUF]
    lea rsi, [rel ues_quote]
    call rbt_append_cstr
    mov rdi, rax
    mov rcx, [rbp - UES_ARGS]
    mov rsi, [rcx]
    lea rsi, [rsi + PyStrObject.data]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel ues_codec]
    call rbt_append_cstr
    mov rdi, rax
    test r9d, r9d
    jz .ues_verb_encode
    lea rsi, [rel ues_decode_w]
    jmp .ues_verb_done
.ues_verb_encode:
    lea rsi, [rel ues_encode_w]
.ues_verb_done:
    push r9
    call rbt_append_cstr
    pop r9

    ; One position, or a span?
    mov rcx, [rbp - UES_START]
    inc rcx
    cmp rcx, [rbp - UES_END]
    jne .ues_span

    ; "byte 0xNN " or "character 'X' "
    mov rdi, rax
    test r9d, r9d
    jz .ues_one_char
    lea rsi, [rel ues_byte]
    call rbt_append_cstr
    mov rdi, rax
    mov rcx, [rbp - UES_ARGS]
    mov rsi, [rcx + 8]          ; the bytes
    V_TEST_PTR rsi, rcx
    ja .ues_no
    mov rcx, [rbp - UES_START]
    cmp rcx, [rsi + PyBytesObject.ob_size]
    jae .ues_no
    movzx esi, byte [rsi + PyBytesObject.data + rcx]
    call msg_append_hex2
    jmp .ues_position
.ues_one_char:
    lea rsi, [rel ues_char]
    call rbt_append_cstr
    mov rdi, rax
    mov rcx, [rbp - UES_ARGS]
    mov rsi, [rcx + 8]          ; the str
    mov rdx, [rbp - UES_START]
    call msg_append_escaped_cp
    jmp .ues_position

.ues_span:
    mov rdi, rax
    test r9d, r9d
    jz .ues_span_chars
    lea rsi, [rel ues_bytes_pl]
    jmp .ues_span_emit
.ues_span_chars:
    lea rsi, [rel ues_chars_pl]
.ues_span_emit:
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel ues_in_pos]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - UES_START]
    call msg_append_i64
    mov rdi, rax
    lea rsi, [rel ues_dash]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - UES_END]
    dec rsi
    call msg_append_i64
    jmp .ues_reason

.ues_position:
    mov rdi, rax
    lea rsi, [rel ues_in_pos]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - UES_START]
    call msg_append_i64

.ues_reason:
    mov rdi, rax
    lea rsi, [rel ues_colon]
    call rbt_append_cstr
    mov rdi, rax
    mov rcx, [rbp - UES_ARGS]
    mov rsi, [rcx + 32]
    lea rsi, [rsi + PyStrObject.data]
    call rbt_append_cstr

    lea rdi, [rbp - UES_BUF]
    call str_from_cstr
    pop rbx
    leave
    ret

.ues_no:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC unicode_error_str



section .rodata
; The pieces unicode_error_str assembles its message from -- "'utf-8' codec
; can't decode byte 0xff in position 3: invalid start byte" and the four
; other shapes of it.  They came over with the function that is their only
; reader.
ues_quote:    db "'", 0
ues_codec:    db "' codec can't ", 0
ues_decode_w: db "decode ", 0
ues_encode_w: db "encode ", 0
ues_byte:     db "byte 0x", 0
ues_char:     db "character ", 0
ues_bytes_pl: db "bytes", 0
ues_chars_pl: db "characters", 0
ues_in_pos:   db " in position ", 0
ues_dash:     db "-", 0
ues_colon:    db ": ", 0
