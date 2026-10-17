; builtins_str.asm - str() and the arguments it takes
;
; str(x[, encoding[, errors]]) and str's own tp_new, split out of
; builtins_obj.asm when that file crossed the 100k cap.  The three-argument
; form is a DECODE, which is why this is longer than a constructor looks:
; the encoding and the errors handler are each checked by name, in CPython's
; wording, before anything is decoded.

%include "macros.inc"
%include "object.inc"

extern str_type
extern obj_repr
extern raise_type_error_counted
extern raise_type_error_with_name
extern bytes_type_call
extern ba_shared_decode
extern _bytes_decode_impl
extern str_from_cstr
extern bytes_type
extern bytearray_type
extern memoryview_type
extern exc_TypeError_type
extern raise_exception
extern rbt_append_cstr
extern value_type
extern none_type
extern obj_str
extern obj_decref
extern obj_incref
extern str_from_cstr_heap
extern bytes_decode_impl
extern ap_strcmp

section .rodata
str_too_many_msg: db "str() takes at most 3 arguments (", 0
str_decode_needs_bytes: db "decoding to str: need a bytes-like object, ", 1, " found", 0

section .text

;; ============================================================================
;; str_type_call(rdi = the type, rsi = args, rdx = nargs) -> rax = Value
;; str's tp_new, which is builtin_str_fn with the type argument dropped.
;; ============================================================================
DEF_FUNC_BARE str_type_call
    mov rdi, rsi
    mov rsi, rdx
    jmp builtin_str_fn
END_FUNC str_type_call

;; ============================================================================
;; 3. builtin_str_fn(rdi = args, rsi = nargs) - str(x[, encoding[, errors]])
;;   -> rax = Value
;;
;; The decoding form was missing outright: `str(b, "utf-8")` was
;; "str() takes at most 1 argument".  CPython's re/_parser.py uses it, which
;; is what kept glob and fnmatch from importing.
;;
;; It is the one builtin whose second argument changes what the first one
;; means: with an encoding, str() is a decode and takes a bytes-like object
;; only -- str("a", "utf-8") is an error, not a copy.
;; ============================================================================
SB_OBJ   equ 8
SB_ENC   equ 16
SB_ERR   equ 24
SB_NPOS  equ 32
SB_NKW   equ 40
SB_ARGS  equ 48
SB_ARGV  equ 80          ; the three-slot array handed to decode:
                         ; [-80] self, [-72] encoding, [-64] errors
SB_FRAME equ 96          ; + 0 pushes = 96

DEF_FUNC builtin_str_fn, SB_FRAME
    mov qword [rbp - SB_OBJ], 0
    mov qword [rbp - SB_ENC], 0
    mov qword [rbp - SB_ERR], 0
    mov [rbp - SB_ARGS], rdi
    mov [rbp - SB_NPOS], rsi
    mov qword [rbp - SB_NKW], 0

    ; Keyword arguments arrive as trailing positional slots, named by
    ; kw_names_pending.  str's three names are object, encoding and errors.
    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jz .str_bind_positional
    mov qword [gs:ThreadState.kw_names_pending], 0     ; consumed, however this ends
    mov rcx, [rax + PyTupleObject.ob_size]
    mov [rbp - SB_NKW], rcx
    sub qword [rbp - SB_NPOS], rcx

    xor r9d, r9d
.str_kw_loop:
    cmp r9, [rbp - SB_NKW]
    jge .str_bind_positional
    mov r10, [rax + PyTupleObject.ob_item]
    mov r10, [r10 + r9*8]                   ; the keyword's name
    mov r11, [rbp - SB_ARGS]
    mov rcx, [rbp - SB_NPOS]
    add rcx, r9
    mov r11, [r11 + rcx*8]                  ; the value that goes with it

    push rax
    push r9
    push r11
    sub rsp, 8
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "object"
    call ap_strcmp
    test eax, eax
    jz .str_kw_object
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "encoding"
    call ap_strcmp
    test eax, eax
    jz .str_kw_encoding
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "errors"
    call ap_strcmp
    test eax, eax
    jz .str_kw_errors
    add rsp, 8
    pop r11
    pop r9
    pop rax
    lea rdi, [r10 + PyStrObject.data]
    call str_raise_bad_keyword
.str_kw_object:
    mov rcx, [rsp + 8]
    mov [rbp - SB_OBJ], rcx
    jmp .str_kw_next
.str_kw_encoding:
    mov rcx, [rsp + 8]
    mov [rbp - SB_ENC], rcx
    jmp .str_kw_next
.str_kw_errors:
    mov rcx, [rsp + 8]
    mov [rbp - SB_ERR], rcx
.str_kw_next:
    add rsp, 8
    pop r11
    pop r9
    pop rax
    inc r9
    jmp .str_kw_loop

.str_bind_positional:
    ; The positional slots fill object, encoding and errors in that order.
    mov rcx, [rbp - SB_NPOS]
    cmp rcx, 3
    jg .str_too_many
    mov rdi, [rbp - SB_ARGS]
    test rcx, rcx
    jle .str_bound
    mov rax, [rdi]
    mov [rbp - SB_OBJ], rax
    cmp rcx, 2
    jl .str_bound
    mov rax, [rdi + 8]
    mov [rbp - SB_ENC], rax
    cmp rcx, 3
    jl .str_bound
    mov rax, [rdi + 16]
    mov [rbp - SB_ERR], rax

.str_bound:
    ; No encoding and no errors is the ordinary str(): str() is "", and
    ; str(x) is x's __str__.
    cmp qword [rbp - SB_ENC], 0
    jne .str_decode
    cmp qword [rbp - SB_ERR], 0
    jne .str_decode
    cmp qword [rbp - SB_OBJ], 0
    je .str_no_args
    mov rdi, [rbp - SB_OBJ]
    call obj_str
    leave
    ret

.str_no_args:
    CSTRING rdi, ""
    call str_from_cstr
    leave
    ret

.str_decode:
    ; With an encoding, str() decodes -- and takes a bytes-like object only.
    ; str() with errors= and no object is still "", as CPython's is.
    cmp qword [rbp - SB_OBJ], 0
    je .str_no_args
    mov rdi, [rbp - SB_OBJ]
    V_TEST_PTR rdi, rax
    ja .str_not_bytes
    test rdi, rdi
    jz .str_not_bytes
    mov rax, [rdi + PyObject.ob_type]

    lea rcx, [rel str_type]
    cmp rax, rcx
    je .str_decoding_str
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jnz .str_decoding_str

    ; Default the encoding to utf-8, which is what CPython does when only
    ; errors= was given.
    cmp qword [rbp - SB_ENC], 0
    jne .str_have_enc
    push rax
    CSTRING rdi, "utf-8"
    call str_from_cstr
    mov [rbp - SB_ENC], rax
    pop rax
    ; The temporary is dropped below, once the decode has read it.
.str_have_enc:
    ; CPython checks both here and names str(), not the decode underneath.
    push rax
    sub rsp, 8
    mov rdi, [rbp - SB_ENC]
    CSTRING rsi, "encoding"
    call str_require_str_arg
    mov rdi, [rbp - SB_ERR]
    CSTRING rsi, "errors"
    call str_require_str_arg
    add rsp, 8
    pop rax

    mov rcx, [rbp - SB_OBJ]
    mov [rbp - SB_ARGV], rcx
    mov rcx, [rbp - SB_ENC]
    mov [rbp - SB_ARGV + 8], rcx
    mov rcx, [rbp - SB_ERR]
    mov [rbp - SB_ARGV + 16], rcx
    mov esi, 2
    cmp qword [rbp - SB_ERR], 0
    je .str_argc_set
    mov esi, 3
.str_argc_set:
    lea rdi, [rbp - SB_ARGV]

    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .str_call_bytes
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_BYTES_SUBCLASS
    jnz .str_call_bytes
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .str_call_bytearray
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_BYTEARRAY_SUBCLASS
    jnz .str_call_bytearray
    lea rcx, [rel memoryview_type]
    cmp rax, rcx
    je .str_call_memoryview
    jmp .str_not_bytes

.str_call_bytes:
    call _bytes_decode_impl
    leave
    ret
.str_call_bytearray:
    call ba_shared_decode
    leave
    ret
.str_call_memoryview:
    ; A memoryview has no decode of its own; CPython's str() reads its buffer.
    ; Copying it to a bytes first is the same answer for the contiguous views
    ; this build can make.
    push rdi
    push rsi
    lea rsi, [rbp - SB_ARGV]
    mov edx, 1
    lea rdi, [rel bytes_type]
    call bytes_type_call
    pop rsi
    pop rdi
    test rax, rax
    jz .str_failed
    mov [rbp - SB_ARGV], rax
    push rax
    sub rsp, 8
    lea rdi, [rbp - SB_ARGV]
    call _bytes_decode_impl
    add rsp, 8
    pop rdi
    push rax
    call obj_decref
    pop rax
    leave
    ret
.str_failed:
    xor eax, eax
    leave
    ret

.str_decoding_str:
    RAISE exc_TypeError_type, "decoding str is not supported"
.str_not_bytes:
    mov rsi, [rbp - SB_OBJ]
    lea rdi, [rel str_decode_needs_bytes]
    call raise_type_error_with_name
.str_too_many:
    mov rsi, [rbp - SB_NPOS]
    add rsi, [rbp - SB_NKW]
    lea rdi, [rel str_too_many_msg]
    CSTRING rdx, " given)"
    call raise_type_error_counted
END_FUNC builtin_str_fn

;; ============================================================================
;; str_require_str_arg(rdi = the argument, or 0 when it was not given,
;;                     rsi = the parameter's name)
;;   -> returns, or raises TypeError
;; Raises "str() argument 'encoding' must be str, not int", CPython's wording.
;; ============================================================================
SRA_NAME  equ 8
SRA_ARG   equ 16
SRA_BUF   equ 176
SRA_FRAME equ 176           ; + 0 pushes = 176, 16-aligned
DEF_FUNC_LOCAL str_require_str_arg, SRA_FRAME
    test rdi, rdi
    jz .sras_ok                 ; not given at all
    mov [rbp - SRA_ARG], rdi
    mov [rbp - SRA_NAME], rsi
    V_TEST_PTR rdi, rax
    ja .sras_bad
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .sras_ok
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jnz .sras_ok
.sras_bad:
    lea rdi, [rbp - SRA_BUF]
    CSTRING rsi, "str() argument '"
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - SRA_NAME]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "' must be str, not "
    call rbt_append_cstr
    mov rdi, rax
    push rax
    mov rdi, [rbp - SRA_ARG]
    call value_type
    test rax, rax
    jz .sras_unknown
    ; CPython's _PyArg_BadArgument writes "None" and not "NoneType".
    extern none_type
    lea rcx, [rel none_type]
    cmp rax, rcx
    je .sras_none
    mov rsi, [rax + PyTypeObject.tp_name]
    jmp .sras_named
.sras_none:
    CSTRING rsi, "None"
    jmp .sras_named
.sras_unknown:
    CSTRING rsi, "object"
.sras_named:
    pop rdi
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - SRA_BUF]
    call raise_exception
.sras_ok:
    leave
    ret
END_FUNC str_require_str_arg


;; ============================================================================
;; str_raise_bad_keyword(rdi = the keyword's name, as a C string)
;;   -> does not return
;; "'foo' is an invalid keyword argument for str()".
;; ============================================================================
SRK_NAME  equ 8
SRK_BUF   equ 176
SRK_FRAME equ 176           ; + 0 pushes = 176, 16-aligned
DEF_FUNC_LOCAL str_raise_bad_keyword, SRK_FRAME
    mov [rbp - SRK_NAME], rdi
    lea rdi, [rbp - SRK_BUF]
    CSTRING rsi, "'"
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - SRK_NAME]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "' is an invalid keyword argument for str()"
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - SRK_BUF]
    call raise_exception
END_FUNC str_raise_bad_keyword
