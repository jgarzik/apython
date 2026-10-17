; sre_template.asm - the replacement-template mini-language
;
; Match.expand(), and the string form of Pattern.sub()/subn().  Both were
; stubs: expand() handed the template straight back and sub() concatenated the
; replacement verbatim, so `\1`, `\g<name>` and every escape came out as their
; own source text.
;
; A parsed template is an ordinary list whose elements are either a str -- a
; literal run -- or an int, the number of a group to substitute.  That is the
; same shape re._parser.parse_template builds, and it lets sub() parse once
; and expand per match, as CPython's does.
;
; The syntax is _parser.parse_template's, which is NOT the pattern syntax:
;   \g<name>  \g<7>     a group, by name or by number
;   \1 .. \99            a group, by number
;   \0, \012             an octal character (three octal digits after a \0..\7
;                        are an octal escape, not a two-digit group)
;   \n \t \r \v \f \a \b \\   the fixed escapes; \b is a backspace here, not a
;                        word boundary
;   \<anything else>     an ASCII letter is an error, anything else keeps the
;                        backslash and the character both

%include "macros.inc"
%include "object.inc"
%include "sre.inc"

extern ap_malloc
extern ap_free
extern obj_decref
extern sre_new_slice
extern str_type
extern bytes_type
extern list_new
extern list_append
extern dict_get
extern str_method_join
extern sre_match_get_group_str
extern none_singleton
extern obj_as_index
extern raise_exception
extern raise_exception_obj
extern exc_IndexError_type
extern exc_ValueError_type
extern exc_MemoryError_type
extern exc_new
extern str_from_cstr
extern str_from_cstr_heap
extern obj_getattr_opt
extern obj_call_n
extern sys_modules_dict
extern v_int_bias

section .text

;; ============================================================================
;; tp_error(rdi = the message prefix, rsi = extra bytes, rdx = a number, a
;;          length or a character, ecx = how to finish the message,
;;          r8 = the template, r9 = the position) -- raises, and does not return
;;
;;   ecx = 0   the prefix alone                    "missing <"
;;   ecx = 1   the prefix and rdx as a number      "invalid group reference 99"
;;   ecx = 2   the prefix and rsi/rdx quoted       "bad character in group name '1a'"
;;   ecx = 3   the prefix and rdx as an escape     "bad escape \q"
;;
;; With r8 = 0 the message carries no position and the class is IndexError,
;; which is what CPython raises for an unknown group name.
;;
;; The class is re.error, which is defined in Python: it is fetched out of
;; sys.modules the moment it is needed, which is always after `import re`,
;; because a template is only ever parsed through re.sub, re.subn or
;; Match.expand.  Constructing it there rather than here is also what appends
;; " at position N" -- re.error does that itself, out of the pattern and
;; offset it is handed.  With no `re` in sys.modules the message stands on its
;; own as a ValueError.
;; ============================================================================
TPE_MODE  equ 8
TPE_TMPL  equ 16
TPE_POS   equ 24
TPE_MSG   equ 32
TPE_DIGITS equ 56            ; 24 bytes, for the decimal of mode 1
TPE_ARGS  equ 96             ; three Values
TPE_BUF   equ 96 + 256
TPE_FRAME equ TPE_BUF + 8     ; + 1 push = TPE_BUF + 16

DEF_FUNC_LOCAL tp_error, TPE_FRAME
    push rbx
    mov [rbp - TPE_MODE], rcx
    mov [rbp - TPE_TMPL], r8
    mov [rbp - TPE_POS], r9

    ; The prefix.
    lea rbx, [rbp - TPE_BUF]
    xor eax, eax
.tpe_prefix:
    cmp eax, 180
    jge .tpe_prefix_done
    mov r10b, [rdi + rax]
    test r10b, r10b
    jz .tpe_prefix_done
    mov [rbx + rax], r10b
    inc eax
    jmp .tpe_prefix
.tpe_prefix_done:
    add rbx, rax

    mov rcx, [rbp - TPE_MODE]
    cmp rcx, 1
    je .tpe_number
    cmp rcx, 2
    je .tpe_quoted
    cmp rcx, 3
    je .tpe_escape
    jmp .tpe_finish

.tpe_number:
    mov byte [rbx], ' '
    inc rbx
    mov rax, rdx
    lea rcx, [rbp - TPE_DIGITS]
    mov r10d, 10
    xor r8, r8                  ; digits written
.tpe_num_loop:
    xor rdx, rdx
    div r10
    add dl, '0'
    mov [rcx + r8], dl
    inc r8
    test rax, rax
    jnz .tpe_num_loop
.tpe_num_copy:
    dec r8
    mov dl, [rcx + r8]
    mov [rbx], dl
    inc rbx
    test r8, r8
    jnz .tpe_num_copy
    jmp .tpe_finish

.tpe_quoted:
    mov byte [rbx], ' '
    mov byte [rbx + 1], 39      ; '
    add rbx, 2
    cmp rdx, 40
    jbe .tpe_quote_len_ok
    mov edx, 40
.tpe_quote_len_ok:
    xor eax, eax
.tpe_quote_copy:
    cmp rax, rdx
    jge .tpe_quote_close
    mov r10b, [rsi + rax]
    mov [rbx + rax], r10b
    inc rax
    jmp .tpe_quote_copy
.tpe_quote_close:
    add rbx, rax
    mov byte [rbx], 39
    inc rbx
    jmp .tpe_finish

.tpe_escape:
    mov byte [rbx], ' '
    mov byte [rbx + 1], 92      ; backslash
    mov [rbx + 2], dl
    add rbx, 3

.tpe_finish:
    mov byte [rbx], 0
    lea rdi, [rbp - TPE_BUF]
    call str_from_cstr_heap
    mov [rbp - TPE_MSG], rax

    ; re.error, if `re` is loaded and there is a position to report.
    cmp qword [rbp - TPE_TMPL], 0
    je .tpe_index
    mov rax, [rel sys_modules_dict]
    test rax, rax
    jz .tpe_plain
    CSTRING rdi, "re"
    call str_from_cstr_heap
    push rax
    mov rdi, [rel sys_modules_dict]
    mov rsi, rax
    call dict_get
    mov rbx, rax
    pop rdi
    call obj_decref
    test rbx, rbx
    jz .tpe_plain
    V_UNPACK rbx, rdx
    cmp edx, TAG_PTR
    jne .tpe_plain

    CSTRING rdi, "error"
    call str_from_cstr_heap
    push rax
    mov rdi, rbx
    mov rsi, rax
    call obj_getattr_opt
    mov rbx, rax
    pop rdi
    call obj_decref
    test rbx, rbx
    jz .tpe_plain
    V_TEST_PTR rbx, rax
    ja .tpe_plain

    ; error(msg, template, pos)
    mov rax, [rbp - TPE_MSG]
    mov [rbp - TPE_ARGS], rax
    mov rax, [rbp - TPE_TMPL]
    mov [rbp - TPE_ARGS + 8], rax
    mov rax, [rbp - TPE_POS]
    add rax, [rel v_int_bias]
    mov [rbp - TPE_ARGS + 16], rax
    mov rdi, rbx
    lea rsi, [rbp - TPE_ARGS]
    mov edx, 3
    call obj_call_n
    push rax
    mov rdi, rbx
    call obj_decref             ; the error class
    pop rax
    test rax, rax
    jz .tpe_plain
    V_UNPACK rax, rdx
    cmp edx, TAG_PTR
    jne .tpe_plain
    push rax
    mov rdi, [rbp - TPE_MSG]
    call obj_decref
    pop rdi
    call raise_exception_obj

.tpe_index:
    lea rdi, [rel exc_IndexError_type]
    mov rsi, [rbp - TPE_MSG]
    mov edx, TAG_PTR
    call exc_new
    push rax
    mov rdi, [rbp - TPE_MSG]
    call obj_decref
    pop rdi
    call raise_exception_obj

.tpe_plain:
    ; No `re` in sys.modules, or it has no error: the message on its own.
    lea rdi, [rel exc_ValueError_type]
    mov rsi, [rbp - TPE_MSG]
    mov edx, TAG_PTR
    call exc_new
    push rax
    mov rdi, [rbp - TPE_MSG]
    call obj_decref
    pop rdi
    call raise_exception_obj
END_FUNC tp_error

;; ============================================================================
;; sre_template_parse(rdi = the template, rsi = pattern) -> rax = a list
;;
;; Literal runs become str -- or bytes, for a bytes template -- elements, and
;; group references become int elements; element 0 is always a literal.
;; Which kind the pieces are is the template's own, and it is the only
;; difference between the two: the escape syntax is identical, and a bytes
;; template is scanned as bytes because that is what it already does.  Group
;; references are checked against the pattern whatever the kinds.
;; Raises rather than answering NULL: every caller is a builtin method with a
;; live frame above it.
;; ============================================================================
TP_TMPL   equ 8
TP_PAT    equ 16
TP_DATA   equ 24
TP_LEN    equ 32
TP_BUF    equ 40
TP_BLEN   equ 48
TP_LIST   equ 56
TP_POS    equ 64
TP_NGROUP equ 72
TP_SCRATCH equ 80
TP_ISBYTES equ 88           ; the template's kind, which the pieces take
TP_ERRPOS equ 96            ; where an error message says it went wrong
TP_NAMEP  equ 104           ; a group name's bytes, for the message
TP_NAMEL  equ 112
TP_FRAME  equ 128           ; + 0 pushes = 128

DEF_FUNC sre_template_parse, TP_FRAME
    mov [rbp - TP_TMPL], rdi
    mov [rbp - TP_PAT], rsi
    mov qword [rbp - TP_BUF], 0
    mov qword [rbp - TP_LIST], 0

    mov eax, [rsi + SRE_PatternObject.groups]
    mov [rbp - TP_NGROUP], rax

    ; The pieces take the TEMPLATE's kind, not the pattern's: CPython's
    ; parse_template builds its literals from the replacement it scans, so a
    ; str replacement for a bytes pattern parses to str pieces, and the
    ; mismatch surfaces only when a substitution joins them.  The caller has
    ; already refused anything that is neither a str nor a bytes.
    ; bytes keeps its data at +24 and str at +40; the length is at +16 in
    ; both.
    xor ecx, ecx
    mov rax, [rdi + PyObject.ob_type]
    lea rdx, [rel bytes_type]
    cmp rax, rdx
    je .tp_kind_bytes
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_BYTES_SUBCLASS
    jz .tp_kind_have
.tp_kind_bytes:
    mov ecx, 1
.tp_kind_have:
    mov [rbp - TP_ISBYTES], rcx
    test rcx, rcx
    jz .tp_str_data
    lea rax, [rdi + PyBytesObject.data]
    jmp .tp_have_data
.tp_str_data:
    lea rax, [rdi + PyStrObject.data]
.tp_have_data:
    mov [rbp - TP_DATA], rax
    mov rax, [rdi + PyStrObject.ob_size]
    mov [rbp - TP_LEN], rax

    ; A literal is never longer than its source, except that an octal escape
    ; can name a code point above 127 and so take two UTF-8 bytes where it
    ; took four in the source.  Twice the length is comfortably enough.
    lea rdi, [rax + rax + 8]
    call ap_malloc
    test rax, rax
    jz .tp_oom
    mov [rbp - TP_BUF], rax
    mov qword [rbp - TP_BLEN], 0

    xor edi, edi
    call list_new
    test rax, rax
    jz .tp_oom
    mov [rbp - TP_LIST], rax

    mov qword [rbp - TP_POS], 0
.tp_loop:
    mov rcx, [rbp - TP_POS]
    cmp rcx, [rbp - TP_LEN]
    jge .tp_done
    mov rdx, [rbp - TP_DATA]
    movzx eax, byte [rdx + rcx]
    cmp al, '\'
    je .tp_escape
    call .tp_emit
    inc qword [rbp - TP_POS]
    jmp .tp_loop

.tp_done:
    call .tp_flush
    mov rax, [rbp - TP_LIST]
    mov [rbp - TP_SCRATCH], rax
    mov rdi, [rbp - TP_BUF]
    call ap_free
    mov rax, [rbp - TP_SCRATCH]
    leave
    ret

;; --- the escape sequences -------------------------------------------------
.tp_escape:
    ; rcx = the index of the backslash
    inc rcx
    cmp rcx, [rbp - TP_LEN]
    jge .tp_trailing
    movzx eax, byte [rdx + rcx]
    mov [rbp - TP_POS], rcx     ; the escape character's own index
    mov [rbp - TP_ERRPOS], rcx  ; and where a message about it points

    cmp al, 'g'
    je .tp_gref
    cmp al, '0'
    je .tp_octal
    cmp al, '1'
    jb .tp_fixed
    cmp al, '9'
    jbe .tp_digit

.tp_fixed:
    cmp al, 'n'
    je .tp_fix_n
    cmp al, 't'
    je .tp_fix_t
    cmp al, 'r'
    je .tp_fix_r
    cmp al, 'v'
    je .tp_fix_v
    cmp al, 'f'
    je .tp_fix_f
    cmp al, 'a'
    je .tp_fix_a
    cmp al, 'b'
    je .tp_fix_b
    cmp al, '\'
    je .tp_fix_bs

    ; An ASCII letter with no meaning is an error; anything else keeps both
    ; characters, so that r'\.' stays a backslash and a dot.
    mov cl, al
    or  cl, 0x20
    cmp cl, 'a'
    jb .tp_keep_both
    cmp cl, 'z'
    jbe .tp_bad_escape
.tp_keep_both:
    push rax
    mov al, '\'
    call .tp_emit
    pop rax
    call .tp_emit
    inc qword [rbp - TP_POS]
    jmp .tp_loop

.tp_fix_n:
    mov al, 10
    jmp .tp_fix_emit
.tp_fix_t:
    mov al, 9
    jmp .tp_fix_emit
.tp_fix_r:
    mov al, 13
    jmp .tp_fix_emit
.tp_fix_v:
    mov al, 11
    jmp .tp_fix_emit
.tp_fix_f:
    mov al, 12
    jmp .tp_fix_emit
.tp_fix_a:
    mov al, 7
    jmp .tp_fix_emit
.tp_fix_b:
    mov al, 8
    jmp .tp_fix_emit
.tp_fix_bs:
    mov al, '\'
.tp_fix_emit:
    call .tp_emit
    inc qword [rbp - TP_POS]
    jmp .tp_loop

;; \0 opens an octal escape of up to three digits in total.
.tp_octal:
    xor r8d, r8d                ; the value
    mov r9d, 1                  ; digits taken, counting the 0
.tp_oct_more:
    cmp r9d, 3
    jge .tp_oct_done
    mov rcx, [rbp - TP_POS]
    inc rcx
    cmp rcx, [rbp - TP_LEN]
    jge .tp_oct_done
    mov rdx, [rbp - TP_DATA]
    movzx eax, byte [rdx + rcx]
    cmp al, '0'
    jb .tp_oct_done
    cmp al, '7'
    ja .tp_oct_done
    sub al, '0'
    shl r8d, 3
    movzx eax, al
    or  r8d, eax
    mov [rbp - TP_POS], rcx
    inc r9d
    jmp .tp_oct_more
.tp_oct_done:
    mov eax, r8d
    call .tp_emit_cp
    inc qword [rbp - TP_POS]
    jmp .tp_loop

;; \1..\9 is a group number -- unless three octal digits follow the
;; backslash, which is an octal escape instead.
.tp_digit:
    movzx r8d, al
    sub r8d, '0'                ; the first digit
    mov r10d, 1                 ; how many digits taken

    mov rcx, [rbp - TP_POS]
    inc rcx
    cmp rcx, [rbp - TP_LEN]
    jge .tp_dig_have
    mov rdx, [rbp - TP_DATA]
    movzx eax, byte [rdx + rcx]
    cmp al, '0'
    jb .tp_dig_have
    cmp al, '9'
    ja .tp_dig_have
    ; A second digit.  Both it and the first must be octal, and a third octal
    ; digit must follow, for this to be an octal escape rather than a group.
    movzx r9d, al
    sub r9d, '0'
    mov [rbp - TP_POS], rcx
    mov r10d, 2
    cmp r8d, 7
    ja .tp_dig_two
    cmp r9d, 7
    ja .tp_dig_two
    inc rcx
    cmp rcx, [rbp - TP_LEN]
    jge .tp_dig_two
    movzx eax, byte [rdx + rcx]
    cmp al, '0'
    jb .tp_dig_two
    cmp al, '7'
    ja .tp_dig_two
    ; Three octal digits.
    movzx eax, al
    sub eax, '0'
    mov [rbp - TP_POS], rcx
    mov ecx, r8d
    shl ecx, 6
    mov edx, r9d
    shl edx, 3
    or  ecx, edx
    or  ecx, eax
    mov eax, ecx
    call .tp_emit_cp
    inc qword [rbp - TP_POS]
    jmp .tp_loop

.tp_dig_two:
    imul r8d, r8d, 10
    add r8d, r9d
.tp_dig_have:
    mov eax, r8d
    call .tp_addgroup
    inc qword [rbp - TP_POS]
    jmp .tp_loop

;; \g<name> or \g<number>
.tp_gref:
    mov rcx, [rbp - TP_POS]
    inc rcx
    cmp rcx, [rbp - TP_LEN]
    jge .tp_missing_lt
    mov rdx, [rbp - TP_DATA]
    cmp byte [rdx + rcx], '<'
    jne .tp_missing_lt
    inc rcx
    mov r9, rcx                 ; the name's first byte
    mov [rbp - TP_ERRPOS], rcx
    mov [rbp - TP_NAMEP], rcx
.tp_gref_scan:
    cmp rcx, [rbp - TP_LEN]
    jge .tp_gref_ran_out
    cmp byte [rdx + rcx], '>'
    je .tp_gref_end
    inc rcx
    jmp .tp_gref_scan
.tp_gref_ran_out:
    ; No '>' at all.  An empty name is "missing group name"; a name that
    ; started is "missing >, unterminated name".  CPython reports both at the
    ; name's own position.
    cmp rcx, r9
    je .tp_bad_name
    jmp .tp_unterminated

.tp_gref_end:
    mov [rbp - TP_POS], rcx     ; the '>' itself; the tail step passes it
    mov r10, rcx
    sub r10, r9                 ; the name's length
    mov [rbp - TP_NAMEL], r10
    test r10, r10
    jz .tp_bad_name

    ; All digits: a number, not a name.
    mov r8, r9
    xor r11d, r11d              ; the accumulated number
.tp_gref_digits:
    cmp r8, rcx
    jge .tp_gref_number
    movzx eax, byte [rdx + r8]
    cmp al, '0'
    jb .tp_gref_byname
    cmp al, '9'
    ja .tp_gref_byname
    imul r11d, r11d, 10
    movzx eax, al
    sub eax, '0'
    add r11d, eax
    inc r8
    jmp .tp_gref_digits
.tp_gref_number:
    mov eax, r11d
    call .tp_addgroup
    inc qword [rbp - TP_POS]
    jmp .tp_loop

.tp_gref_byname:
    ; A name that is not an identifier never had a chance of being a group:
    ; CPython says so rather than calling it unknown.
    ; A byte at or above 0x80 is part of a non-ASCII identifier, which Python
    ; allows: `(?P<\u00e9>a)` is a legal group name.  Only the ASCII range is
    ; classified here; anything else is left to the groupindex lookup, which
    ; is the real answer to whether the name exists.
    mov r8, [rbp - TP_NAMEP]
    add r8, [rbp - TP_DATA]
    movzx eax, byte [r8]
    cmp al, 0x80
    jae .tp_name_head_ok
    cmp al, '_'
    je .tp_name_head_ok
    mov cl, al
    or  cl, 0x20
    cmp cl, 'a'
    jb .tp_bad_char
    cmp cl, 'z'
    ja .tp_bad_char
.tp_name_head_ok:
    mov r11d, 1
.tp_name_scan:
    cmp r11, [rbp - TP_NAMEL]
    jge .tp_name_ok
    movzx eax, byte [r8 + r11]
    cmp al, 0x80
    jae .tp_name_next
    cmp al, '_'
    je .tp_name_next
    cmp al, '0'
    jb .tp_bad_char
    cmp al, '9'
    jbe .tp_name_next
    mov cl, al
    or  cl, 0x20
    cmp cl, 'a'
    jb .tp_bad_char
    cmp cl, 'z'
    ja .tp_bad_char
.tp_name_next:
    inc r11
    jmp .tp_name_scan
.tp_name_ok:

    ; Look the name up in the pattern's groupindex.
    mov rdi, [rbp - TP_PAT]
    mov rdi, [rdi + SRE_PatternObject.groupindex]
    test rdi, rdi
    jz .tp_unknown_name
    mov [rbp - TP_SCRATCH], rdi
    ; The key is a str even for a bytes pattern: groupindex is built by
    ; lib/re, whose names are str whatever the pattern is made of.  Slicing
    ; it as bytes made `re.sub(b'(?P<a>a)', rb'[\g<a>]', b'a')` an
    ; IndexError for a group that was right there.
    mov rdi, [rbp - TP_DATA]
    add rdi, r9
    mov rsi, r10
    xor edx, edx
    call sre_new_slice
    test rax, rax
    jz .tp_oom
    mov rsi, rax                ; the name, ours
    mov rdi, [rbp - TP_SCRATCH]
    push rsi
    sub rsp, 8
    call dict_get
    add rsp, 8
    pop rdi
    push rax
    sub rsp, 8
    call obj_decref             ; the name string
    add rsp, 8
    pop rax
    test rax, rax
    jz .tp_unknown_name
    V_UNPACK rax, rdx
    mov rdi, rax
    call obj_as_index           ; the index may be a heap int
    call .tp_addgroup
    inc qword [rbp - TP_POS]
    jmp .tp_loop

;; --- the buffer, and the pieces it becomes --------------------------------

;; .tp_emit(al = one byte)
.tp_emit:
    mov rdx, [rbp - TP_BUF]
    mov rcx, [rbp - TP_BLEN]
    mov [rdx + rcx], al
    inc qword [rbp - TP_BLEN]
    ret

;; .tp_emit_cp(eax = a code point, 0..255) -- UTF-8, so an octal escape above
;; 127 is one character and not one byte.
.tp_emit_cp:
    cmp eax, 0x80
    jb .tp_emit
    ; In a BYTES template an escape is one raw byte, not a code point:
    ; `re.sub(b'(a)', b'\\377', b'a')` is b'\xff', where UTF-8 encoding it
    ; gave b'\xc3\xbf'.  The str template is the one that encodes.
    cmp qword [rbp - TP_ISBYTES], 0
    jne .tp_emit
    push rax
    shr eax, 6
    or  al, 0xC0
    call .tp_emit
    pop rax
    and al, 0x3F
    or  al, 0x80
    jmp .tp_emit

;; .tp_flush -- the pending literal, if any, becomes the next list element.
;; The FIRST element is always a literal, even an empty one: it is CPython's
;; template literal, whose kind is the kind the expansion joins in, and which
;; is always the expansion's item 0 -- the index a mismatch is reported at
;; counts it.
;; Reached by `call`, so rsp arrives 8 below alignment; the sub/add pair is
;; what keeps every call below it on a 16-byte boundary.
.tp_flush:
    sub rsp, 8
    cmp qword [rbp - TP_BLEN], 0
    jne .tp_flush_some
    mov rax, [rbp - TP_LIST]
    cmp qword [rax + PyListObject.ob_size], 0
    jne .tp_flush_none
.tp_flush_some:
    mov rdi, [rbp - TP_BUF]
    mov rsi, [rbp - TP_BLEN]
    mov edx, [rbp - TP_ISBYTES]
    call sre_new_slice
    test rax, rax
    jz .tp_oom
    push rax
    sub rsp, 8
    mov rdi, [rbp - TP_LIST]
    mov rsi, rax
    call list_append
    add rsp, 8
    pop rdi
    call obj_decref
    mov qword [rbp - TP_BLEN], 0
.tp_flush_none:
    add rsp, 8
    ret

;; .tp_addgroup(eax = group number) -- flush the literal, then record it.
.tp_addgroup:
    cmp rax, [rbp - TP_NGROUP]
    ja .tp_bad_group
    push rax                    ; and this restores the 16-byte alignment
    call .tp_flush
    pop rax
    push rax
    V_PACK_I64 rax, rcx
    mov rsi, rax
    mov rdi, [rbp - TP_LIST]
    call list_append
    pop rax
    ret

;; --- the ways it can go wrong ---------------------------------------------
;; Every one of these abandons the frame, so the buffer and the list have to
;; go first or a loop that keeps catching the error keeps leaking them.
.tp_release:
    sub rsp, 8
    mov rdi, [rbp - TP_BUF]
    test rdi, rdi
    jz .tp_release_list
    mov qword [rbp - TP_BUF], 0
    call ap_free
.tp_release_list:
    mov rdi, [rbp - TP_LIST]
    test rdi, rdi
    jz .tp_released
    mov qword [rbp - TP_LIST], 0
    call obj_decref
.tp_released:
    add rsp, 8
    ret

.tp_bad_group:
    ; rax is the group number the template asked for.
    mov [rbp - TP_SCRATCH], rax
    call .tp_release
    CSTRING rdi, "invalid group reference"
    xor esi, esi
    mov rdx, [rbp - TP_SCRATCH]
    mov ecx, 1
    mov r8, [rbp - TP_TMPL]
    mov r9, [rbp - TP_ERRPOS]
    call tp_error

.tp_bad_char:
    call .tp_release
    CSTRING rdi, "bad character in group name"
    mov rsi, [rbp - TP_NAMEP]
    add rsi, [rbp - TP_DATA]
    mov rdx, [rbp - TP_NAMEL]
    mov ecx, 2
    mov r8, [rbp - TP_TMPL]
    mov r9, [rbp - TP_ERRPOS]
    call tp_error

.tp_unknown_name:
    ; The one CPython leaves as an IndexError, and the one with no position.
    call .tp_release
    CSTRING rdi, "unknown group name"
    mov rsi, [rbp - TP_NAMEP]
    add rsi, [rbp - TP_DATA]
    mov rdx, [rbp - TP_NAMEL]
    mov ecx, 2
    xor r8d, r8d                ; no template: an IndexError, as CPython has it
    xor r9d, r9d
    call tp_error

.tp_bad_name:
    call .tp_release
    CSTRING rdi, "missing group name"
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    mov r8, [rbp - TP_TMPL]
    mov r9, [rbp - TP_ERRPOS]
    call tp_error

.tp_missing_lt:
    call .tp_release
    CSTRING rdi, "missing <"
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    mov r8, [rbp - TP_TMPL]
    mov r9, [rbp - TP_ERRPOS]
    inc r9                      ; just past the 'g'
    call tp_error

.tp_unterminated:
    call .tp_release
    CSTRING rdi, "missing >, unterminated name"
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    mov r8, [rbp - TP_TMPL]
    mov r9, [rbp - TP_ERRPOS]
    call tp_error

.tp_trailing:
    ; rcx is one past the trailing backslash, which is what the message points
    ; at; .tp_release does not preserve it.
    dec rcx
    mov [rbp - TP_SCRATCH], rcx
    call .tp_release
    CSTRING rdi, "bad escape (end of pattern)"
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    mov r8, [rbp - TP_TMPL]
    mov r9, [rbp - TP_SCRATCH]
    call tp_error

.tp_bad_escape:
    ; al is the escape character; the position is the backslash before it.
    movzx eax, al
    mov [rbp - TP_SCRATCH], rax
    call .tp_release
    CSTRING rdi, "bad escape"
    xor esi, esi
    mov rdx, [rbp - TP_SCRATCH]
    mov ecx, 3
    mov r8, [rbp - TP_TMPL]
    mov r9, [rbp - TP_ERRPOS]
    dec r9
    call tp_error
.tp_oom:
    call .tp_release
    RAISE exc_MemoryError_type, "out of memory"
END_FUNC sre_template_parse


;; ============================================================================
;; sre_template_expand(rdi = a parsed template, rsi = a match) -> rax = str
;;
;; A group that did not match contributes nothing, as in expand_template.
;; The pieces are joined in the TEMPLATE's kind -- that of its element 0,
;; always a literal -- which is CPython's: a str template over a bytes match
;; fails in the join, "sequence item 1: expected str instance, bytes found",
;; at the first group that matched, and comes back a str when none did.
;; ============================================================================
TE_TMPL   equ 8
TE_MATCH  equ 16
TE_OUT    equ 24
TE_SEP    equ 32
TE_IDX    equ 40
TE_ISBYTES equ 48           ; the template's kind: the join takes it
TE_FRAME  equ 64            ; + 0 pushes = 64

DEF_FUNC sre_template_expand, TE_FRAME
    mov [rbp - TE_TMPL], rdi
    mov [rbp - TE_MATCH], rsi
    mov qword [rbp - TE_OUT], 0
    mov qword [rbp - TE_SEP], 0
    ; The join's kind is the template's: its element 0 is always a literal.
    xor eax, eax
    mov rcx, [rdi + PyListObject.ob_item]
    mov rcx, [rcx]
    mov rcx, [rcx + PyObject.ob_type]
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    sete al
    mov [rbp - TE_ISBYTES], rax

    xor edi, edi
    call list_new
    test rax, rax
    jz .te_oom
    mov [rbp - TE_OUT], rax

    mov qword [rbp - TE_IDX], 0
.te_loop:
    mov rdi, [rbp - TE_TMPL]
    mov rcx, [rbp - TE_IDX]
    cmp rcx, [rdi + PyListObject.ob_size]
    jge .te_join
    mov rdx, [rdi + PyListObject.ob_item]
    mov rax, [rdx + rcx*8]

    ; A str is a literal; anything else is the int naming a group.
    V_TEST_PTR rax, rcx
    ja .te_group
    ; A literal piece is a str -- or a bytes, for a bytes template.  Testing
    ; only for str sent every bytes literal down the group branch, where it
    ; was read as an index.
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    je .te_literal
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    jne .te_group
.te_literal:

    mov rdi, [rbp - TE_OUT]
    mov rsi, rax
    call list_append            ; takes its own reference
    jmp .te_next

.te_group:
    V_UNPACK rax, rdx
    mov rdi, rax
    call obj_as_index           ; boxed whenever INT_STRESS=1 is on
    mov rsi, rax
    mov rdi, [rbp - TE_MATCH]
    call sre_match_get_group_str
    ; None is an ordinary singleton and so arrives with TAG_PTR like any other
    ; pointer -- the tag says nothing about which object it is.
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    jne .te_group_have
    mov rdi, rax
    call obj_decref             ; the reference get_group_str just took
    ; Unmatched: no piece at all, so the join's item numbers stay CPython's.
    jmp .te_next
.te_group_have:
    mov [rbp - TE_SEP], rax     ; borrow the slot: it is free until the join
    mov rdi, [rbp - TE_OUT]
    mov rsi, rax
    call list_append
    mov rdi, [rbp - TE_SEP]
    call obj_decref
    mov qword [rbp - TE_SEP], 0

.te_next:
    inc qword [rbp - TE_IDX]
    jmp .te_loop

.te_join:
    ; "".join(pieces) -- or b"".join, for a bytes pattern.
    lea rdi, [rel te_nothing]
    xor esi, esi
    mov edx, [rbp - TE_ISBYTES]
    call sre_new_slice
    test rax, rax
    jz .te_oom
    mov [rbp - TE_SEP], rax

    sub rsp, 16
    mov [rsp], rax
    mov rax, [rbp - TE_OUT]
    mov [rsp + 8], rax
    mov rdi, rsp
    mov esi, 2
    cmp qword [rbp - TE_ISBYTES], 0
    jne .te_join_bytes
    call str_method_join
    jmp .te_joined
.te_join_bytes:
    extern bytes_method_join
    call bytes_method_join
.te_joined:
    add rsp, 16
    V_UNPACK rax, rdx
    mov [rbp - TE_IDX], rax

    mov rdi, [rbp - TE_SEP]
    call obj_decref
    mov rdi, [rbp - TE_OUT]
    call obj_decref
    mov rax, [rbp - TE_IDX]
    leave
    ret

.te_oom:
    mov rdi, [rbp - TE_OUT]
    test rdi, rdi
    jz .te_oom_raise
    mov qword [rbp - TE_OUT], 0
    call obj_decref
.te_oom_raise:
    RAISE exc_MemoryError_type, "out of memory"

section .rodata
te_nothing: db 0
section .text
END_FUNC sre_template_expand
