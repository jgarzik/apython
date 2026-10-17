; methods/str.asm - str: case, strip, search, replace, join, split, format
;
; Methods are registered into each type's tp_dict by methods_init, in
; methods_init.asm.  A method is name(PyObject *self, PyObject **args,
; int64_t nargs); args are borrowed, the result is a new reference.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"


; External functions
extern str_alloc_bytes
extern str_cp_width
extern ap_malloc
extern ap_free
extern ap_realloc
extern ap_memcpy
extern ap_memcmp
extern obj_decref
extern obj_repr
extern obj_str
extern str_from_cstr_heap
extern str_new_heap
extern list_new
extern list_append
extern obj_as_index
extern list_type
extern tuple_type
extern dict_get
extern none_singleton
extern bool_true
extern bool_false
extern int_from_i64
extern raise_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_IndexError_type
extern exc_KeyError_type
extern obj_dealloc
extern str_type

; Set entry layout constants (must match set.asm)

; --- moved to a sibling file by the split ---
extern list_method_insert

section .text

;; ############################################################################
;;                         STRING METHODS
;; ############################################################################

;; ============================================================================
;; str_method_upper(args, nargs) -> new uppercase string
;; args[0] = self (PyStrObject*)
;; ============================================================================
DEF_FUNC str_method_upper
    ; The whole of it is str_case_map in methods/str_case.asm: the six differ
    ; only in which of the four Unicode mappings each character takes.
    mov rax, [rdi]
    mov rdi, rax
    xor esi, esi
    extern str_case_map
    call str_case_map
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_upper

;; ============================================================================
;; str_method_lower(args, nargs) -> new lowercase string
;; ============================================================================
DEF_FUNC str_method_lower
    ; The whole of it is str_case_map in methods/str_case.asm: the six differ
    ; only in which of the four Unicode mappings each character takes.
    mov rax, [rdi]
    mov rdi, rax
    mov esi, 1
    extern str_case_map
    call str_case_map
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_lower

;; ============================================================================
section .rodata
;; One byte per possible byte value: 1 when it is whitespace as str.split()
;; and str.strip() understand the term, 0 otherwise.  It replaces a six-way
;; compare ladder that ran once per character of the haystack, reached through
;; a call.  The set is the ASCII one -- tab, newline, vertical tab, form feed,
;; carriage return and space -- which is what the code it replaces tested; the
;; wider Unicode spaces are not, and cannot be: U+0085 and U+00A0 are two
;; bytes each in UTF-8, so no byte table can see them.  What the table DOES
;; add over the ladder it replaces is the four ASCII separators \x1c-\x1f,
;; which CPython's str.split() and str.strip() treat as whitespace and which
;; the ladder had simply left out.  bugs.md records the rest.
global str_ws_class
str_ws_class:
    db 0,0,0,0,0,0,0,0,0,1,1,1,1,1,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1
    db 1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
section .text

;; ============================================================================
;; strip_char_matches(dil = byte, rsi = chars data or 0, rdx = chars len)
;;   -> eax = 1 when the byte should be stripped
;;
;; With no chars argument the set is whitespace, as before.  The argument was
;; accepted and then ignored outright, so "xxaxx".strip("x") returned the
;; string unchanged.
;; ============================================================================
DEF_FUNC_BARE strip_char_matches
    test rsi, rsi
    jz .scm_whitespace
    xor ecx, ecx
.scm_loop:
    cmp rcx, rdx
    jge .scm_no
    cmp dil, [rsi + rcx]
    je .scm_yes
    inc rcx
    jmp .scm_loop

.scm_whitespace:
    lea rcx, [rel str_ws_class]
    movzx eax, dil
    movzx eax, byte [rcx + rax]
    ret
.scm_no:
    xor eax, eax
    ret
.scm_yes:
    mov eax, 1
    ret
END_FUNC strip_char_matches

section .rodata
ssi_name_strip:  db "strip", 0
ssi_name_lstrip: db "lstrip", 0
ssi_name_rstrip: db "rstrip", 0
ssi_arg_msg:     db " arg must be None or str", 0
section .text

;; ============================================================================
;; str_ws_at(rdi = data, rsi = byte offset) -> eax = 1 when the character
;;   there is whitespace, ecx = its width in bytes
;;
;; The scan primitive split() needs.  ASCII is one compare and one table load,
;; which is what the byte loops this replaces cost; anything wider decodes and
;; asks uflags_of, which is the only thing that knows about U+00A0 and the
;; U+2000 block.
;; ============================================================================
DEF_FUNC str_ws_at
    movzx eax, byte [rdi + rsi]
    cmp al, 0x80
    jae .swa_wide
    lea rcx, [rel str_ws_class]
    movzx eax, byte [rcx + rax]
    mov ecx, 1
    leave
    ret
.swa_wide:
    extern ucase_utf8_get
    call ucase_utf8_get         ; eax = code point, ecx = width
    push rcx
    sub rsp, 8
    mov edi, eax
    extern uflags_of
    call uflags_of
    add rsp, 8
    pop rcx
    and eax, 16                 ; UF_SPACE; see str_cp_matches
    shr eax, 4
    leave
    ret
END_FUNC str_ws_at

;; ============================================================================
;; str_ws_before(rdi = data, rsi = the offset just PAST a character)
;;   -> eax = 1 when that character is whitespace, rcx = where it starts
;;
;; The same question asked backwards, which rsplit() and rstrip() need and
;; which a byte loop answered by subtracting one.  A character is found by
;; stepping back over its continuation bytes.
;; ============================================================================
SWB_DATA equ 8
SWB_END  equ 16
SWB_POS  equ 24
SWB_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC str_ws_before, SWB_FRAME
    mov [rbp - SWB_DATA], rdi
    mov [rbp - SWB_END], rsi
    mov rcx, rsi
.swb_back:
    dec rcx
    test rcx, rcx
    jle .swb_have
    mov al, [rdi + rcx]
    and al, 0xC0
    cmp al, 0x80
    je .swb_back
.swb_have:
    mov [rbp - SWB_POS], rcx
    mov rdi, [rbp - SWB_DATA]
    mov rsi, rcx
    call str_ws_at
    mov rcx, [rbp - SWB_POS]
    leave
    ret
END_FUNC str_ws_before

;; ============================================================================
;; str_cp_matches(edi = a code point, rsi = chars data or 0, rdx = chars byte
;;   length) -> eax = 1 when the character should be stripped
;;
;; The code-point twin of strip_char_matches, and the reason there has to be
;; one.  A byte table cannot answer for whitespace: U+00A0, U+2028 and U+3000
;; are two and three bytes in UTF-8, so no entry in a 256-byte array can name
;; them.  uflags_of can, and its UF_SPACE bit is exactly CPython's set --
;; gen_unicodecase.py generated it from str.isspace(), which is why
;; "\xa0".isspace() was already True while "a\xa0b".split() was not.
;;
;; With an explicit `chars` the comparison is by CODE POINT as well, and that
;; was not a refinement: comparing bytes made "\xe9\xe8x".strip("\xe8") strip
;; the 0xC3 lead byte the two characters share, and hand back a string that
;; is not valid UTF-8.
;; ============================================================================
SCM_CP    equ 8
SCM_CHARS equ 16
SCM_CLEN  equ 24
SCM_POS   equ 32
SCM_FRAME equ 48            ; + 0 pushes = 48
DEF_FUNC str_cp_matches, SCM_FRAME
    mov [rbp - SCM_CP], rdi
    mov [rbp - SCM_CHARS], rsi
    mov [rbp - SCM_CLEN], rdx
    test rsi, rsi
    jz .scpm_space

    mov qword [rbp - SCM_POS], 0
.scpm_loop:
    mov rsi, [rbp - SCM_POS]
    cmp rsi, [rbp - SCM_CLEN]
    jge .scpm_no
    mov rdi, [rbp - SCM_CHARS]
    extern ucase_utf8_get
    call ucase_utf8_get         ; eax = code point, ecx = width
    movsxd rcx, ecx
    add [rbp - SCM_POS], rcx
    cmp eax, [rbp - SCM_CP]
    jne .scpm_loop
    mov eax, 1
    leave
    ret

.scpm_space:
    ; ASCII is the overwhelming majority and the byte table answers it in one
    ; load; only a wider character needs the flag tables.
    mov eax, [rbp - SCM_CP]
    cmp eax, 128
    jae .scpm_wide
    lea rcx, [rel str_ws_class]
    movzx eax, byte [rcx + rax]
    leave
    ret
.scpm_wide:
    mov edi, eax
    extern uflags_of
    call uflags_of
    ; UF_SPACE, the fifth bit of the flag word gen_unicodecase.py builds.
    ; Named here rather than included: str_case.asm owns the enum and nothing
    ; else in this file needs it.
    and eax, 16
    shr eax, 4                  ; answer 0 or 1
    leave
    ret

.scpm_no:
    xor eax, eax
    leave
    ret
END_FUNC str_cp_matches

;; ============================================================================
;; str_strip_impl(rdi = args, rsi = nargs, edx = mode) -> Value
;; mode: bit 0 = strip the left, bit 1 = strip the right.
;; ============================================================================
SSI_CHARS equ 8
SSI_CLEN  equ 16
SSI_MODE  equ 24
; Which of the three this is, so the refusal can name it: CPython says
; "lstrip arg must be None or str", not "strip".
SSI_NAME  equ 32
SSI_W     equ 40            ; a character's width, or where it starts
SSI_FRAME equ 48            ; + 4 pushes = 80, 16-aligned

DEF_FUNC_LOCAL str_strip_impl, SSI_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov [rbp - SSI_MODE], rdx
    ; The name comes from the mode: 3 = strip, 1 = lstrip, 2 = rstrip.
    lea rax, [rel ssi_name_strip]
    cmp rdx, 1
    jne .ssi_not_l
    lea rax, [rel ssi_name_lstrip]
.ssi_not_l:
    cmp rdx, 2
    jne .ssi_not_r
    lea rax, [rel ssi_name_rstrip]
.ssi_not_r:
    mov [rbp - SSI_NAME], rax
    mov qword [rbp - SSI_CHARS], 0
    mov qword [rbp - SSI_CLEN], 0

    mov rbx, [rdi]              ; self
    mov r12, [rbx + PyStrObject.ob_size]

    cmp rsi, 2
    jl .ssi_have_chars
    mov rax, [rdi + 8]          ; the chars argument
    ; None is the DEFAULT, not a refusal: `" a ".strip(None)` is " a ".strip()
    ; in CPython and was a TypeError here.
    IS_NONE rax, rcx
    je .ssi_have_chars
    V_TEST_PTR rax, rcx
    ja .ssi_type_error
    mov rcx, [rax + PyObject.ob_type]
    REQUIRE_STR_TYPE rcx, rdx, .ssi_type_error
    lea rcx, [rax + PyStrObject.data]
    mov [rbp - SSI_CHARS], rcx
    mov rcx, [rax + PyStrObject.ob_size]
    mov [rbp - SSI_CLEN], rcx

.ssi_have_chars:
    xor r13d, r13d              ; start
    mov r14, r12                ; end, exclusive

    ; Pure ASCII takes the byte loops below: every character is one byte, and
    ; a `chars` holding wider ones cannot match a byte under 0x80, so the
    ; comparison stays honest.  Anything else decodes.
    mov rax, [rbx + PyStrObject.ob_size]
    cmp rax, [rbx + PyStrObject.ob_length]
    jne .ssi_wide

    test qword [rbp - SSI_MODE], 1
    jz .ssi_right
.ssi_left_loop:
    cmp r13, r14
    jge .ssi_make
    movzx edi, byte [rbx + PyStrObject.data + r13]
    mov rsi, [rbp - SSI_CHARS]
    mov rdx, [rbp - SSI_CLEN]
    call strip_char_matches
    test eax, eax
    jz .ssi_right
    inc r13
    jmp .ssi_left_loop

.ssi_right:
    test qword [rbp - SSI_MODE], 2
    jz .ssi_make
.ssi_right_loop:
    cmp r14, r13
    jle .ssi_make
    movzx edi, byte [rbx + PyStrObject.data + r14 - 1]
    mov rsi, [rbp - SSI_CHARS]
    mov rdx, [rbp - SSI_CLEN]
    call strip_char_matches
    test eax, eax
    jz .ssi_make
    dec r14
    jmp .ssi_right_loop

; --- the same two scans, one code point at a time ------------------------
.ssi_wide:
    test qword [rbp - SSI_MODE], 1
    jz .ssi_wide_right
.ssi_wide_left:
    cmp r13, r14
    jge .ssi_wide_right_check
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r13
    call ucase_utf8_get         ; eax = code point, ecx = width
    movsxd rcx, ecx
    mov [rbp - SSI_W], rcx
    mov edi, eax
    mov rsi, [rbp - SSI_CHARS]
    mov rdx, [rbp - SSI_CLEN]
    call str_cp_matches
    test eax, eax
    jz .ssi_wide_right_check
    add r13, [rbp - SSI_W]
    jmp .ssi_wide_left

.ssi_wide_right_check:
.ssi_wide_right:
    test qword [rbp - SSI_MODE], 2
    jz .ssi_make
.ssi_wide_rloop:
    cmp r14, r13
    jle .ssi_make
    ; Back up over continuation bytes to the lead byte of the last character.
    mov rcx, r14
.ssi_wide_back:
    dec rcx
    cmp rcx, r13
    jle .ssi_wide_have
    mov al, [rbx + PyStrObject.data + rcx]
    and al, 0xC0
    cmp al, 0x80
    je .ssi_wide_back
.ssi_wide_have:
    mov [rbp - SSI_W], rcx      ; where that character starts
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, rcx
    call ucase_utf8_get
    mov edi, eax
    mov rsi, [rbp - SSI_CHARS]
    mov rdx, [rbp - SSI_CLEN]
    call str_cp_matches
    test eax, eax
    jz .ssi_make
    mov r14, [rbp - SSI_W]
    jmp .ssi_wide_rloop

.ssi_make:
    ; The result is a run of the subject's own bytes, and str_new_slice is
    ; where that is worth saying: when the subject is ASCII the result's
    ; code-point count is its byte count, and str_new_heap would rescan for
    ; it -- str_count_codepoints was 17% of a strip() loop.
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    sub rdx, r13
    extern str_new_slice
    call str_new_slice
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.ssi_type_error:
    mov rdi, [rbp - SSI_NAME]
    lea rsi, [rel ssi_arg_msg]
    sub rsp, 128
    mov rdi, rsp
    mov rsi, [rbp - SSI_NAME]
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel ssi_arg_msg]
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    mov rsi, rsp
    extern raise_exception
    call raise_exception
END_FUNC str_strip_impl

;; ============================================================================
;; str_method_strip(args, nargs) -> new string with both ends stripped
;; args[0]=self, args[1]=chars (optional)
;; ============================================================================
DEF_FUNC_BARE str_method_strip
    mov edx, 3
    jmp str_strip_impl
END_FUNC str_method_strip

;; ============================================================================
;; str_method_startswith(args, nargs) -> bool_true/bool_false
;; args[0]=self, args[1]=prefix
;; ============================================================================
;; ============================================================================
;; str_affix_dispatch(rdi = args, rsi = nargs, rdx = single-affix function)
;;   -> True when any element of a tuple argument matches
;;
;; startswith and endswith accept a tuple of candidates in Python.  Only a
;; single str was accepted here, so "He".startswith(("X", "He")) raised
;; TypeError.
;; ============================================================================
SAD_ARGS  equ 8
SAD_NARGS equ 16
SAD_FN    equ 24
SAD_TUP   equ 32
SAD_IDX   equ 40
SAD_NAME  equ 48            ; the message for an argument that is neither
SAD_FRAME equ 64            ; + 0 pushes = 64

DEF_FUNC_LOCAL str_affix_dispatch, SAD_FRAME
    mov [rbp - SAD_ARGS], rdi
    mov [rbp - SAD_NARGS], rsi
    mov [rbp - SAD_FN], rdx
    mov [rbp - SAD_NAME], rcx

    cmp rsi, 2
    jl .sad_single
    mov rax, [rdi + 8]
    V_TEST_PTR rax, rcx
    ja .sad_first_arg
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    je .sad_have_tuple
    ; Neither a tuple nor -- as far as this can tell -- a str.  The helper
    ; below checks that, but its message is the one for a TUPLE'S ELEMENT;
    ; CPython words the argument itself differently, and this is where the
    ; two can still be told apart.
    REQUIRE_STR_TYPE rcx, rdx, .sad_first_arg
    jmp .sad_single
.sad_first_arg:
    mov rsi, [rbp - SAD_ARGS]
    mov rsi, [rsi + 8]
    mov rdi, [rbp - SAD_NAME]
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
.sad_have_tuple:

    mov [rbp - SAD_TUP], rax
    mov qword [rbp - SAD_IDX], 0

.sad_loop:
    mov rax, [rbp - SAD_TUP]
    mov rcx, [rbp - SAD_IDX]
    cmp rcx, [rax + PyTupleObject.ob_size]
    jge .sad_false

    ; Build (self, candidate) plus any start/stop the caller passed.
    sub rsp, 64
    mov rdx, [rbp - SAD_ARGS]
    mov r8, [rdx]
    mov [rsp], r8                       ; self
    mov r9, [rax + PyTupleObject.ob_item]
    mov r9, [r9 + rcx * 8]
    mov [rsp + 8], r9                   ; the candidate
    mov r10, [rbp - SAD_NARGS]
    cmp r10, 3
    jl .sad_no_extra
    mov r8, [rdx + 16]
    mov [rsp + 16], r8
    cmp r10, 4
    jl .sad_no_extra
    mov r8, [rdx + 24]
    mov [rsp + 24], r8
.sad_no_extra:
    mov rdi, rsp
    mov rsi, [rbp - SAD_NARGS]
    call [rbp - SAD_FN]
    add rsp, 64

    V_UNPACK rax, rdx
    lea rcx, [rel bool_true]
    cmp rax, rcx
    je .sad_true

    inc qword [rbp - SAD_IDX]
    jmp .sad_loop

.sad_single:
    mov rdi, [rbp - SAD_ARGS]
    mov rsi, [rbp - SAD_NARGS]
    call [rbp - SAD_FN]
    leave
    ret

.sad_true:
    RET_TRUE
    leave
    V_PACK rax, rdx
    ret

.sad_false:
    RET_FALSE
    leave
    V_PACK rax, rdx
    ret
END_FUNC str_affix_dispatch

AFF_ARGS  equ 8
AFF_NARGS equ 16
AFF_WPTR  equ 40            ; the 3-word window str_search_window fills
AFF_WLEN  equ 32
AFF_WOFF  equ 24
AFF_FRAME equ 64            ; + 4 pushes = 96, 16-aligned
; startswith keeps three callee-saved registers where endswith keeps four,
; so it needs one more word of frame to land on the same boundary.
AFF_FRAME3 equ 72           ; + 3 pushes = 96, 16-aligned
DEF_FUNC_LOCAL str_startswith_one, AFF_FRAME3
    push rbx
    push r12
    push r13
    mov [rbp - AFF_ARGS], rdi
    mov [rbp - AFF_NARGS], rsi

    ; Validate args[1] is a string
    mov rax, [rdi + 8]         ; args[1]
    V_TEST_PTR rax, rcx
    ja .sw_type_error
    mov rcx, [rax + PyObject.ob_type]
    REQUIRE_STR_TYPE rcx, rdx, .sw_type_error

    mov rbx, [rdi]          ; self
    mov r12, [rdi + 8]     ; prefix (args[1])

    mov r13, [r12 + PyStrObject.ob_size]  ; prefix length

    ; start and end narrow the region examined.  They are *code point* indices
    ; and were applied as byte offsets, so "αβαβ".startswith("β", 1) was False:
    ; offset 1 landed inside alpha's two bytes.  str_search_window converts.
    push r14
    push r15
    mov rdi, rbx
    mov rsi, [rbp - AFF_ARGS]
    mov rdx, [rbp - AFF_NARGS]
    lea rcx, [rbp - AFF_WPTR]
    call str_search_window
    test eax, eax
    jz .sw_false_pop
    mov r14, [rbp - AFF_WOFF]       ; window start, in bytes
    mov r15, [rbp - AFF_WLEN]       ; window length, in bytes

    ; The prefix must fit inside the window
    cmp r13, r15
    jg .sw_false_pop

    mov rdi, [rbp - AFF_WPTR]
    lea rsi, [r12 + PyStrObject.data]
    xor ecx, ecx
.sw_cmp:
    cmp rcx, r13
    jge .sw_true_pop
    movzx eax, byte [rdi + rcx]
    cmp al, [rsi + rcx]
    jne .sw_false_pop
    inc rcx
    jmp .sw_cmp

.sw_true_pop:
    pop r15
    pop r14
    jmp .sw_true
.sw_false_pop:
    pop r15
    pop r14
    jmp .sw_false

.sw_true:
    RET_TRUE
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.sw_false:
    RET_FALSE
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.sw_type_error:
    ; CPython names the type and says which of the two shapes was wrong: the
    ; dispatcher hands a tuple's elements here one at a time, so this is the
    ; element wording, and the dispatcher itself has the other.
    mov rsi, [rbp - AFF_ARGS]
    mov rsi, [rsi + 8]
    CSTRING rdi, `tuple for startswith must only contain str, not \x01`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
END_FUNC str_startswith_one

DEF_FUNC_BARE str_method_startswith
    lea rdx, [rel str_startswith_one]
    lea rcx, [rel sad_msg_startswith]
    jmp str_affix_dispatch
END_FUNC str_method_startswith

section .rodata
sad_msg_startswith: db `startswith first arg must be str or a tuple of str, not \x01`, 0
sad_msg_endswith:   db `endswith first arg must be str or a tuple of str, not \x01`, 0
section .text

;; ============================================================================
;; str_method_endswith(args, nargs) -> bool_true/bool_false
;; args[0]=self, args[1]=suffix
;; ============================================================================
DEF_FUNC_LOCAL str_endswith_one, AFF_FRAME
    push rbx
    push r12
    push r13
    push r14
    mov [rbp - AFF_ARGS], rdi
    mov [rbp - AFF_NARGS], rsi

    ; Validate args[1] is a string
    mov rax, [rdi + 8]         ; args[1]
    V_TEST_PTR rax, rcx
    ja .ew_type_error
    mov rcx, [rax + PyObject.ob_type]
    REQUIRE_STR_TYPE rcx, rdx, .ew_type_error

    mov rbx, [rdi]          ; self
    mov r12, [rdi + 8]     ; suffix
    mov r13, [r12 + PyStrObject.ob_size]  ; suffix length
    mov r14, [rbx + PyStrObject.ob_size]  ; self length

    ; start and end narrow the region examined.  Code point indices, applied as
    ; byte offsets until now -- the same bug startswith had.
    push r15
    mov rdi, rbx
    mov rsi, [rbp - AFF_ARGS]
    mov rdx, [rbp - AFF_NARGS]
    lea rcx, [rbp - AFF_WPTR]
    call str_search_window
    test eax, eax
    jz .ew_false_pop
    mov r14, [rbp - AFF_WPTR]       ; window base pointer
    mov r15, [rbp - AFF_WLEN]       ; window length, in bytes

    ; The suffix must fit inside the window
    cmp r13, r15
    jg .ew_false_pop

    lea rdi, [r14 + r15]
    sub rdi, r13                    ; the window's last suffix_len bytes
    lea rsi, [r12 + PyStrObject.data]
    xor ecx, ecx
.ew_cmp:
    cmp rcx, r13
    jge .ew_true_pop
    movzx eax, byte [rdi + rcx]
    cmp al, [rsi + rcx]
    jne .ew_false_pop
    inc rcx
    jmp .ew_cmp

.ew_true_pop:
    pop r15
    jmp .ew_true
.ew_false_pop:
    pop r15
    jmp .ew_false

.ew_true:
    RET_TRUE
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.ew_false:
    RET_FALSE
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.ew_type_error:
    ; CPython names the type and says which of the two shapes was wrong: the
    ; dispatcher hands a tuple's elements here one at a time, so this is the
    ; element wording, and the dispatcher itself has the other.
    mov rsi, [rbp - AFF_ARGS]
    mov rsi, [rsi + 8]
    CSTRING rdi, `tuple for endswith must only contain str, not \x01`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
END_FUNC str_endswith_one

DEF_FUNC_BARE str_method_endswith
    lea rdx, [rel str_endswith_one]
    lea rcx, [rel sad_msg_endswith]
    jmp str_affix_dispatch
END_FUNC str_method_endswith

;; ============================================================================
;; str_method_find(args, nargs) -> SmallInt code point index, or -1
;; args[0]=self, args[1]=substr, args[2]=start, args[3]=end
;;
;; str_find_impl carries find, rfind, index and rindex; they differ only in
;; which direction the scan runs and in what a miss does.  Both of those used
;; to ignore start and end outright -- "abcabc".find("b", 3) was 1 -- and both
;; searched with the C-string ap_strstr, so they also stopped at the first NUL:
;; "a\x00b".find("b") was -1.
;;
;; edx on entry is a bitmask: bit 0 = scan in reverse, bit 1 = raise
;; ValueError on a miss instead of returning -1.  So 0 = find, 1 = rfind,
;; 2 = index, 3 = rindex.
;; ============================================================================
extern str_search_window
extern ap_memfind
extern ap_memrfind
extern str_byte_to_cp

FND_ARGS  equ 8
FND_NARGS equ 16
FND_SELF  equ 24
FND_DIR   equ 32
FND_WPTR  equ 56            ; the 3-word window: 56, 48, 40
FND_WLEN  equ 48
FND_FRAME equ 64            ; + 0 pushes = 64
DEF_FUNC str_find_impl, FND_FRAME
    mov [rbp - FND_ARGS], rdi
    mov [rbp - FND_NARGS], rsi
    mov [rbp - FND_DIR], rdx

    mov rax, [rdi + 8]              ; args[1]
    V_TEST_PTR rax, rcx
    ja .find_type_error
    mov rcx, [rax + PyObject.ob_type]
    REQUIRE_STR_TYPE rcx, rdx, .find_type_error

    mov rcx, [rdi]                  ; self
    mov [rbp - FND_SELF], rcx

    mov rdi, rcx
    mov rsi, [rbp - FND_ARGS]
    mov rdx, [rbp - FND_NARGS]
    lea rcx, [rbp - FND_WPTR]
    call str_search_window
    test eax, eax
    jz .find_not_found

    mov rdi, [rbp - FND_WPTR]
    mov rsi, [rbp - FND_WLEN]
    mov rdx, [rbp - FND_ARGS]
    mov rdx, [rdx + 8]              ; the needle
    mov rcx, [rdx + PyStrObject.ob_size]
    lea rdx, [rdx + PyStrObject.data]
    test qword [rbp - FND_DIR], 1
    jnz .find_reverse
    call ap_memfind
    jmp .find_have_hit
.find_reverse:
    call ap_memrfind
.find_have_hit:
    test rax, rax
    jz .find_not_found

    ; A pointer into self.data; Python wants a code point index.
    mov rdi, [rbp - FND_SELF]
    sub rax, rdi
    sub rax, PyStrObject.data
    mov rsi, rax
    call str_byte_to_cp
    mov rdi, rax
    call int_from_i64
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.find_not_found:
    test qword [rbp - FND_DIR], 2
    jnz .find_missing
    mov rdi, -1
    call int_from_i64
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.find_missing:
    RAISE exc_ValueError_type, "substring not found"

.find_type_error:
    mov rsi, [rbp - AFF_ARGS]
    mov rsi, [rsi + 8]
    CSTRING rdi, `must be str, not \x01`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
END_FUNC str_find_impl

DEF_FUNC_BARE str_method_find
    xor edx, edx
    jmp str_find_impl
END_FUNC str_method_find

;; ============================================================================
;; str_method_replace(args, nargs) -> new string with replacements
;; args[0]=self, args[1]=old, args[2]=new
;; Uses callee-saved regs for key state, stack locals for buffer management.
;; ============================================================================
RPL_BUF    equ 48           ; the growing result buffer
RPL_ALLOC  equ 56           ; its allocated size
RPL_WPOS   equ 64           ; how much of it is written
RPL_SLEN   equ 72           ; self's length in bytes
RPL_LEFT   equ 80           ; replacements still allowed, -1 = unlimited
RPL_ARGS   equ 88
RPL_LOCALS equ 56           ; + 5 pushes = 96
DEF_FUNC str_method_replace
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, RPL_LOCALS

    ; Validate args[1] is a string
    mov rax, [rdi + 8]         ; args[1]
    V_TEST_PTR rax, rcx
    ja .repl_type_error1
    mov rcx, [rax + PyObject.ob_type]
    REQUIRE_STR_TYPE rcx, rdx, .repl_type_error1

    ; Validate args[2] is a string
    mov rax, [rdi + 16]         ; args[2]
    V_TEST_PTR rax, rcx
    ja .repl_type_error2
    mov rcx, [rax + PyObject.ob_type]
    REQUIRE_STR_TYPE rcx, rdx, .repl_type_error2

    ; The third argument caps how many replacements happen, and was ignored:
    ; "aXbXc".replace("X", "-", 1) replaced both.  A negative count means
    ; unlimited, which is also what its absence means.
    mov qword [rbp - RPL_LEFT], -1
    cmp rsi, 4
    jl .repl_count_done
    mov [rbp - RPL_ARGS], rdi
    mov rdi, [rdi + 24]         ; args[3]
    V_UNPACK rdi, rdx
    call obj_as_index
    mov rdi, [rbp - RPL_ARGS]
    test rax, rax
    js .repl_count_done
    mov [rbp - RPL_LEFT], rax
.repl_count_done:

    ; rbx = self, r12 = old_str, r13 = new_str, r14 = self_len, r15 = scan_pos
    mov rbx, [rdi]          ; self
    mov r12, [rdi + 8]     ; old
    mov r13, [rdi + 16]     ; new
    mov r14, [rbx + PyStrObject.ob_size]
    mov [rbp - RPL_SLEN], r14

    ; If old_str is empty, interleave new_str between each char
    cmp qword [r12 + PyStrObject.ob_size], 0
    je .replace_interleave

    ; Allocate initial buffer: self_len * 2 + 64
    lea rdi, [r14 * 2 + 64]
    mov [rbp - RPL_ALLOC], rdi       ; buf_alloc
    call ap_malloc
    mov [rbp - RPL_BUF], rax       ; buf_ptr
    mov qword [rbp - RPL_WPOS], 0   ; write_pos = 0

    xor r15d, r15d          ; r15 = scan position

.replace_scan:
    cmp qword [rbp - RPL_LEFT], 0
    je .replace_copy_tail       ; the count is spent; the rest stays as it is

    ; Check if remaining text is long enough for old_str
    mov rax, r14
    sub rax, r15
    cmp rax, [r12 + PyStrObject.ob_size]
    jl .replace_copy_tail

    ; Search for old_str from scan pos.  ap_strstr stopped at the first NUL,
    ; so "a\x00b".replace("b", "!") left the string alone.
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r15
    mov rsi, r14
    sub rsi, r15
    lea rdx, [r12 + PyStrObject.data]
    mov rcx, [r12 + PyStrObject.ob_size]
    call ap_memfind
    test rax, rax
    jz .replace_copy_tail

    ; Found at rax; compute found_pos relative to self.data start
    lea rcx, [rbx + PyStrObject.data]
    sub rax, rcx            ; rax = found_pos (absolute index in self)
    push rax                ; save found_pos on stack

    ; --- ensure buffer space ---
    mov rcx, rax
    sub rcx, r15            ; prefix_len = found_pos - scan_pos
    mov rdx, [rbp - RPL_WPOS]       ; write_pos
    add rdx, rcx
    add rdx, [r13 + PyStrObject.ob_size]
    add rdx, r14            ; generous upper bound for rest
    cmp rdx, [rbp - RPL_ALLOC]
    jl .replace_space_ok
    shl rdx, 1
    mov [rbp - RPL_ALLOC], rdx
    mov rdi, [rbp - RPL_BUF]
    mov rsi, rdx
    call ap_realloc
    mov [rbp - RPL_BUF], rax
.replace_space_ok:

    ; --- copy prefix: bytes from scan_pos to found_pos ---
    pop rax                 ; found_pos
    push rax                ; keep on stack
    mov rcx, rax
    sub rcx, r15            ; prefix_len
    test rcx, rcx
    jz .replace_no_prefix

    mov rdi, [rbp - RPL_BUF]
    add rdi, [rbp - RPL_WPOS]
    lea rsi, [rbx + PyStrObject.data]
    add rsi, r15
    mov rdx, rcx
    push rcx
    call ap_memcpy
    pop rcx
    add [rbp - RPL_WPOS], rcx

.replace_no_prefix:
    ; --- copy new_str ---
    mov rcx, [r13 + PyStrObject.ob_size]
    test rcx, rcx
    jz .replace_adv

    mov rdi, [rbp - RPL_BUF]
    add rdi, [rbp - RPL_WPOS]
    lea rsi, [r13 + PyStrObject.data]
    mov rdx, rcx
    push rcx
    call ap_memcpy
    pop rcx
    add [rbp - RPL_WPOS], rcx

.replace_adv:
    cmp qword [rbp - RPL_LEFT], 0
    jl .replace_adv_unlimited
    dec qword [rbp - RPL_LEFT]
.replace_adv_unlimited:
    pop rax                 ; found_pos
    add rax, [r12 + PyStrObject.ob_size]
    mov r15, rax            ; advance scan past old_str
    jmp .replace_scan

.replace_copy_tail:
    ; Copy remaining bytes from scan_pos to end
    mov rcx, r14
    sub rcx, r15
    test rcx, rcx
    jz .replace_make_str

    mov rdi, [rbp - RPL_BUF]
    add rdi, [rbp - RPL_WPOS]
    lea rsi, [rbx + PyStrObject.data]
    add rsi, r15
    mov rdx, rcx
    push rcx
    call ap_memcpy
    pop rcx
    add [rbp - RPL_WPOS], rcx

.replace_make_str:
    mov rdi, [rbp - RPL_BUF]
    mov rsi, [rbp - RPL_WPOS]       ; result length
    call str_new_heap
    push rax

    mov rdi, [rbp - RPL_BUF]
    call ap_free

    pop rax
    mov edx, TAG_PTR
    add rsp, RPL_LOCALS
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.replace_interleave:
    ; Interleave: insert new_str before each char and after last
    ; Result = new + ch0 + new + ch1 + ... + ch(n-1) + new
    ; Result len = (self_len + 1) * new_len + self_len
    mov rcx, [r13 + PyStrObject.ob_size]  ; new_len
    lea rax, [r14 + 1]         ; self_len + 1
    imul rax, rcx              ; (self_len + 1) * new_len
    add rax, r14               ; + self_len
    inc rax                         ; + NUL
    mov [rbp - RPL_ALLOC], rax          ; buf_alloc
    mov rdi, rax
    call ap_malloc
    mov [rbp - RPL_BUF], rax          ; buf_ptr
    mov qword [rbp - RPL_WPOS], 0      ; write_pos = 0

    xor r15d, r15d             ; scan_pos = 0

.ri_loop:
    cmp qword [rbp - RPL_LEFT], 0
    je .ri_tail                 ; the count is spent
    ; Copy new_str
    mov rcx, [r13 + PyStrObject.ob_size]
    test rcx, rcx
    jz .ri_skip_new
    mov rdi, [rbp - RPL_BUF]
    add rdi, [rbp - RPL_WPOS]
    lea rsi, [r13 + PyStrObject.data]
    mov rdx, rcx
    push rcx
    call ap_memcpy
    pop rcx
    add [rbp - RPL_WPOS], rcx
.ri_skip_new:
    cmp qword [rbp - RPL_LEFT], 0
    jl .ri_unlimited
    dec qword [rbp - RPL_LEFT]
.ri_unlimited:
    ; Check if all chars copied
    cmp r15, r14
    jge .replace_make_str

    ; Copy one *code point* from self, not one byte: inserting between the
    ; bytes of a multi-byte character split it, so "αβ".replace("", "-") came
    ; back as four mojibake halves instead of "-α-β-".  r15 is callee-saved,
    ; so str_cp_width preserves it.
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r14
    mov rdx, r15
    call str_cp_width
    mov rcx, rax                ; the character's width in bytes
    mov rdi, [rbp - RPL_BUF]
    add rdi, [rbp - RPL_WPOS]
    lea rsi, [rbx + PyStrObject.data]
    add rsi, r15
    mov rdx, rcx
    push rcx
    call ap_memcpy
    pop rcx
    add [rbp - RPL_WPOS], rcx
    add r15, rcx
    jmp .ri_loop

.ri_tail:
    ; The count ran out; everything still unscanned is copied verbatim.
    mov rcx, r14
    sub rcx, r15
    test rcx, rcx
    jz .replace_make_str
    mov rdi, [rbp - RPL_BUF]
    add rdi, [rbp - RPL_WPOS]
    lea rsi, [rbx + PyStrObject.data]
    add rsi, r15
    mov rdx, rcx
    push rcx
    call ap_memcpy
    pop rcx
    add [rbp - RPL_WPOS], rcx
    jmp .replace_make_str

.replace_copy_self:
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r14
    call str_new_heap
    mov edx, TAG_PTR
    add rsp, RPL_LOCALS
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.repl_type_error1:
    ; The offending object is still in rax: neither the tag test nor
    ; REQUIRE_STR_TYPE touches it.  CPython names it, and says WHICH
    ; argument.
    mov rsi, rax
    CSTRING rdi, `replace() argument 1 must be str, not \x01`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
.repl_type_error2:
    mov rsi, rax
    CSTRING rdi, `replace() argument 2 must be str, not \x01`
    jmp raise_type_error_with_name
END_FUNC str_method_replace

;; ============================================================================
;; str_method_join(args, nargs) -> new string
;; args[0]=self (separator), args[1]=list
;; self.join(iterable)
;; Regs: rbx=self(sep), r12=list, r13=count, r14=sep_len
;; Stack: the SJ_* slots below
;; ============================================================================
extern tuple_type_call

; Release the sequence join() materialised for itself, if it made one.
%macro JOIN_RELEASE_TMP 0
    mov rdi, [rbp - SJ_TMP]
    test rdi, rdi
    jz %%no_tmp
    mov qword [rbp - SJ_TMP], 0
    call obj_decref
%%no_tmp:
%endmacro

SJ_TOTAL equ 48
SJ_BUF   equ 56
SJ_POS   equ 64
SJ_TMP   equ 72         ; materialised sequence, owned, or 0
SJ_CPLEN equ 80         ; code points in the result, summed rather than rescanned
SJ_RESULT equ 88        ; the PyStrObject being built
DEF_FUNC str_method_join
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56             ; 4 locals, and the pad five pushes need

    ; Load separator
    mov r15, rdi             ; save args ptr (r15 free until later)
    mov rbx, [rdi]           ; self (separator)
    INCREF rbx               ; borrow → own
    mov r12, [r15 + 8]       ; args[1] = the sequence Value

    ; The loop below indexes ob_item directly, which only a list or a tuple
    ; has.  join() takes any iterable, so materialise anything else -- that
    ; includes a generator, a set, a str and a dict, all of which used to
    ; read [obj+16] as a count and [obj+32] as an item array.
    mov qword [rbp - SJ_TMP], 0
    V_TEST_PTR_M [r15 + 8], rax
    ja .join_materialise
    mov rax, [r12 + PyObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .join_seq_ready
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .join_seq_ready
.join_materialise:
    ; A non-iterable is join's own refusal, not the iterator protocol's:
    ; CPython says "can only join an iterable" where tuple() would say
    ; "'int' object is not iterable".
    mov rdi, [r15 + 8]
    V_UNPACK rdi, rsi
    push rdi
    push rsi
    extern get_iterator_opt
    call get_iterator_opt       ; 0 when there is no iterator to be had
    pop rsi
    pop rdi
    test rax, rax
    jz .join_not_iterable
    mov rdi, rax
    call obj_decref             ; only the answer was wanted
    lea rdi, [rel tuple_type]
    lea rsi, [r15 + 8]
    mov edx, 1
    call tuple_type_call
    ; It can fail: draining the iterable runs whatever produced it, and a
    ; generator that raises part way through leaves NULL here with the
    ; exception already pending.  `"".join(codecs.iterdecode(gen, "idna"))`
    ; is exactly that, and this read ob_size off the NULL.
    test rax, rax
    jz .join_materialise_failed
    mov [rbp - SJ_TMP], rax
    mov r12, rax
.join_seq_ready:

    mov r13, [r12 + PyListObject.ob_size]  ; item count
    mov r14, [rbx + PyStrObject.ob_size]   ; sep length

    ; If list is empty, return empty string
    test r13, r13
    jz .join_empty

    ; One item, already exactly a str: hand back the item itself.  The
    ; separator never appears between one thing, so there is nothing to build
    ; and nothing to copy.  CPython takes the same exit in
    ; _PyUnicode_JoinArray, and for the same reason it is limited to an EXACT
    ; str -- a subclass has to be converted, or join would return the subclass.
    cmp r13, 1
    jne .join_sized
    mov rax, [r12 + PyListObject.ob_item]
    mov rax, [rax]
    V_TEST_PTR rax, rcx
    ja .join_sized
    test rax, rax
    jz .join_sized
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .join_sized
    INCREF rax
    mov [rbp - SJ_RESULT], rax
    jmp .join_return

.join_sized:
    ; First pass: compute total length
    xor r15d, r15d          ; r15 = total data length
    mov qword [rbp - SJ_CPLEN], 0
    xor ecx, ecx
.join_len_loop:
    cmp rcx, r13
    jge .join_len_done
    push rcx
    mov rax, [r12 + PyListObject.ob_item]
    mov rax, [rax + rcx * 8]    ; payload
    V_UNPACK rax, rsi
    ; Verify element is TAG_PTR and a str
    cmp esi, TAG_PTR
    jne .join_type_error
    mov rdi, [rax + PyObject.ob_type]
    REQUIRE_STR_TYPE rdi, r8, .join_type_error
    add r15, [rax + PyStrObject.ob_size]
    ; Joining whole strings joins their code points too, so the count is
    ; arithmetic.  str_new_heap used to rescan the finished buffer for it.
    mov rdi, [rax + PyStrObject.ob_length]
    add [rbp - SJ_CPLEN], rdi
    pop rcx
    inc rcx
    jmp .join_len_loop

.join_len_done:
    ; Add separator lengths: sep_len * (count - 1)
    mov rax, r13
    dec rax
    imul rax, r14
    add r15, rax
    mov [rbp - SJ_TOTAL], r15   ; total_len
    ; and the separator's code points, the same way
    mov rax, r13
    dec rax
    imul rax, [rbx + PyStrObject.ob_length]
    add [rbp - SJ_CPLEN], rax

    ; Allocate the RESULT, not a scratch buffer.  The pieces are copied into
    ; it once; there is no second malloc, no second copy and no rescan.
    mov rdi, r15
    mov rsi, [rbp - SJ_CPLEN]
    call str_alloc_bytes
    mov [rbp - SJ_RESULT], rax
    lea rax, [rax + PyStrObject.data]
    mov [rbp - SJ_BUF], rax     ; the write cursor's base
    mov qword [rbp - SJ_POS], 0 ; write_pos = 0

    ; Second pass: copy data
    xor ecx, ecx
.join_copy_loop:
    cmp rcx, r13
    jge .join_make_str
    push rcx

    ; If not the first item, copy separator
    test rcx, rcx
    jz .join_no_sep

    mov rdi, [rbp - SJ_BUF]
    add rdi, [rbp - SJ_POS]
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, r14
    call ap_memcpy
    add [rbp - SJ_POS], r14

.join_no_sep:
    mov rcx, [rsp]          ; reload index
    mov rax, [r12 + PyListObject.ob_item]
    mov rax, [rax + rcx * 8]    ; item payload

    ; Heap string element
    mov rdx, [rax + PyStrObject.ob_size]
    push rdx                ; save item_len
    mov rdi, [rbp - SJ_BUF]
    add rdi, [rbp - SJ_POS]
    lea rsi, [rax + PyStrObject.data]
    call ap_memcpy
    pop rdx                 ; item_len
    add [rbp - SJ_POS], rdx
    pop rcx
    inc rcx
    jmp .join_copy_loop

.join_make_str:
.join_return:
    ; DECREF owned separator
    mov rdi, rbx
    call obj_decref
    JOIN_RELEASE_TMP

    mov rax, [rbp - SJ_RESULT]
    mov edx, TAG_PTR
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.join_empty:
    ; DECREF owned separator
    mov rdi, rbx
    call obj_decref
    JOIN_RELEASE_TMP

    lea rdi, [rel empty_str_cstr]
    call str_from_cstr_heap
    mov edx, TAG_PTR
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.join_materialise_failed:
    ; Nothing to raise: whatever the iterable did is already pending, and this
    ; hands back the NULL that says so.
    mov rdi, rbx
    call obj_decref             ; the separator this borrowed
    xor eax, eax
    xor edx, edx
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.join_not_iterable:
    mov rdi, rbx
    call obj_decref             ; the separator this borrowed
    RAISE exc_TypeError_type, "can only join an iterable"

.join_type_error:
    ; "sequence item 0: expected str instance, int found" -- CPython names the
    ; item AND its type, and this said neither.  The item's Value is in rax
    ; and the index on the machine stack; the tail is composed first, into a
    ; buffer raise_type_error_counted does not use.
    pop rcx                 ; the pushed index from len_loop
    ; The item as it is STORED -- a Value -- read back through the index,
    ; because the unpacked pair is gone and the temporary tuple is about to
    ; be.
    mov rax, [r12 + PyListObject.ob_item]
    mov rax, [rax + rcx * 8]
    push rcx
    push rax
    ; A reference of OUR OWN on the offending item before anything is
    ; released.  The temporary sequence holds the only one when the argument
    ; was a generator -- `"".join(C() for _ in range(1))` -- and the message
    ; names the item's TYPE, so releasing it first read ob_type out of the
    ; block just freed.  It is not given back: this path ends in a raise that
    ; does not return, and there is no moment between reading the type and
    ; unwinding at which a decref would be safe.  One object on a path that
    ; raises, as GET_AWAITABLE's own non-iterator arm says.
    mov rdi, rax
    INCREF_V rdi, rdx
    mov rdi, rbx
    call obj_decref         ; DECREF owned separator
    JOIN_RELEASE_TMP
    pop rdi                 ; the offending item, held by the count above
    extern value_type
    call value_type
    mov rsi, rax
    CSTRING rdi, `: expected str instance, \x01 found`
    extern type_name_message
    call type_name_message
    mov rdx, rax
    pop rsi                 ; the index
    CSTRING rdi, "sequence item "
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC str_method_join

;; ============================================================================
;; str_method_split(args, nargs) -> list of strings
;; If nargs==1: split by whitespace
;; If nargs==2: split by args[1]
;; ============================================================================
;; ============================================================================
;; str_split_impl(rdi = args, rsi = nargs, edx = from_right) -> list
;;
;; One implementation for split and rsplit.  maxsplit was accepted and
;; ignored by both, and rsplit was a plain jump to split -- so
;; "a-b-c".rsplit("-", 1) returned three pieces instead of ['a-b', 'c'].
;;
;; With no separator the split is on runs of whitespace and leading and
;; trailing whitespace produce no empty pieces; with one, every occurrence
;; separates, so "a,,b".split(",") is three pieces.
;; ============================================================================
SPI_SELF   equ 8
SPI_SEP    equ 16        ; separator data, or 0 for whitespace
SPI_SEPLEN equ 24
SPI_MAX    equ 32        ; remaining splits allowed, -1 for no limit
SPI_LIST   equ 40
SPI_RIGHT  equ 48
SPI_LEN    equ 56
SPI_ASCII  equ 64           ; the haystack is ASCII, so every piece is too
SPI_FRAME  equ 80           ; + 4 pushes = 112, still 16-aligned

DEF_FUNC_LOCAL str_split_impl, SPI_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov [rbp - SPI_RIGHT], rdx
    mov rbx, [rdi]                  ; self
    mov [rbp - SPI_SELF], rbx
    mov rax, [rbx + PyStrObject.ob_size]
    mov [rbp - SPI_LEN], rax
    mov qword [rbp - SPI_SEP], 0
    mov qword [rbp - SPI_SEPLEN], 0
    mov qword [rbp - SPI_MAX], -1

    cmp rsi, 2
    jl .spi_ready
    mov rax, [rdi + 8]              ; separator, or None
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .spi_check_max
    V_TEST_PTR rax, rcx
    ja .spi_type_error
    mov rcx, [rax + PyObject.ob_type]
    REQUIRE_STR_TYPE rcx, rdx, .spi_type_error
    mov rcx, [rax + PyStrObject.ob_size]
    test rcx, rcx
    jz .spi_empty_sep
    mov [rbp - SPI_SEPLEN], rcx
    lea rcx, [rax + PyStrObject.data]
    mov [rbp - SPI_SEP], rcx

.spi_check_max:
    cmp rsi, 3
    jl .spi_ready
    push rdi
    mov rdi, [rdi + 16]
    V_UNPACK rdi, rdx
    call obj_as_index
    pop rdi
    test rax, rax
    js .spi_ready                   ; a negative maxsplit means no limit
    mov [rbp - SPI_MAX], rax

.spi_ready:
    ; If the haystack is ASCII then so is every piece of it, and each piece's
    ; code-point count is its byte count.  Without this every piece went
    ; through str_new_heap -> str_set_length -> str_count_codepoints, whose
    ; ASCII probe is cheap per byte and expensive per CALL -- pieces are short,
    ; and it was 11% of a split.
    mov rax, [rbx + PyStrObject.ob_size]
    xor ecx, ecx
    cmp rax, [rbx + PyStrObject.ob_length]
    sete cl
    mov [rbp - SPI_ASCII], rcx

    xor edi, edi
    call list_new
    mov [rbp - SPI_LIST], rax

    cmp qword [rbp - SPI_SEP], 0
    je .spi_whitespace

    ; ---- explicit separator ------------------------------------------------
    cmp qword [rbp - SPI_RIGHT], 0
    jne .spi_sep_right

    xor r12d, r12d                  ; start of the current piece
.spi_sep_loop:
    cmp qword [rbp - SPI_MAX], 0
    je .spi_sep_tail
.spi_sep_scan:
    ; One search per PIECE.  This was an ap_memcmp call for every byte offset
    ; of the haystack: a call, with a primitive's fixed startup, to compare
    ; bytes that almost never match.  ap_memfind scans for the separator's
    ; first byte eight at a time and only compares the rest on a candidate.
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r12
    mov rsi, [rbp - SPI_LEN]
    sub rsi, r12
    mov rdx, [rbp - SPI_SEP]
    mov rcx, [rbp - SPI_SEPLEN]
    call ap_memfind
    test rax, rax
    jz .spi_sep_tail
    lea rcx, [rbx + PyStrObject.data]
    sub rax, rcx
    mov r13, rax                    ; byte offset of the separator

.spi_sep_hit:
    mov r14, r13
    sub r14, r12                    ; piece length
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r12
    mov rsi, r14
    call .spi_emit
    mov r12, r13
    add r12, [rbp - SPI_SEPLEN]
    cmp qword [rbp - SPI_MAX], 0
    jl .spi_sep_loop
    dec qword [rbp - SPI_MAX]
    jmp .spi_sep_loop

.spi_sep_tail:
    mov r14, [rbp - SPI_LEN]
    sub r14, r12
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r12
    mov rsi, r14
    call .spi_emit
    jmp .spi_done

    ; ---- explicit separator, scanning from the right ----------------------
.spi_sep_right:
    mov r12, [rbp - SPI_LEN]        ; end of the current piece, exclusive
.spi_sepr_loop:
    cmp qword [rbp - SPI_MAX], 0
    je .spi_sepr_tail
    mov r13, r12
    sub r13, [rbp - SPI_SEPLEN]
.spi_sepr_scan:
    ; One search per PIECE, as on the forward path above.  This was an
    ; ap_memcmp CALL for every byte offset, walking backwards -- the same
    ; anti-pattern .spi_sep_scan's comment names, left behind when the forward
    ; half was fixed.  ap_memrfind over the part not yet split off finds the
    ; last separator directly.
    test r13, r13
    js .spi_sepr_tail
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r12                    ; only what is still unsplit
    mov rdx, [rbp - SPI_SEP]
    mov rcx, [rbp - SPI_SEPLEN]
    call ap_memrfind
    test rax, rax
    jz .spi_sepr_tail
    lea rcx, [rbx + PyStrObject.data]
    sub rax, rcx
    mov r13, rax                    ; byte offset of the separator

.spi_sepr_hit:
    mov r14, r13
    add r14, [rbp - SPI_SEPLEN]
    mov rsi, r12
    sub rsi, r14                    ; piece length
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r14
    call .spi_emit_front
    mov r12, r13
    cmp qword [rbp - SPI_MAX], 0
    jl .spi_sepr_loop
    dec qword [rbp - SPI_MAX]
    jmp .spi_sepr_loop

.spi_sepr_tail:
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r12
    call .spi_emit_front
    jmp .spi_done

    ; ---- whitespace --------------------------------------------------------
.spi_whitespace:
    cmp qword [rbp - SPI_RIGHT], 0
    jne .spi_ws_right
    xor r12d, r12d
.spi_ws_loop:
    ; skip leading whitespace
    cmp r12, [rbp - SPI_LEN]
    jge .spi_done
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r12
    call str_ws_at
    test eax, eax
    jz .spi_ws_piece
    add r12, rcx
    jmp .spi_ws_loop

.spi_ws_piece:
    cmp qword [rbp - SPI_MAX], 0
    jne .spi_ws_scan
    ; Out of splits: the rest is one piece, *including* its trailing
    ; whitespace.  CPython skips only the whitespace before the remainder --
    ; ' a b '.split(None, 1) is ['a', 'b '], not ['a', 'b'].
    mov r13, [rbp - SPI_LEN]
.spi_ws_emit_last:
    mov rsi, r13
    sub rsi, r12
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r12
    call .spi_emit
    jmp .spi_done

.spi_ws_scan:
    mov r13, r12
.spi_ws_find_end:
    cmp r13, [rbp - SPI_LEN]
    jge .spi_ws_emit
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r13
    call str_ws_at
    test eax, eax
    jnz .spi_ws_emit
    add r13, rcx
    jmp .spi_ws_find_end
.spi_ws_emit:
    mov rsi, r13
    sub rsi, r12
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r12
    call .spi_emit
    mov r12, r13
    cmp qword [rbp - SPI_MAX], 0
    jl .spi_ws_loop
    dec qword [rbp - SPI_MAX]
    jmp .spi_ws_loop

.spi_ws_right:
    ; rsplit() with no separator: same pieces, but maxsplit counts from the
    ; right, so collect from the right and prepend.
    mov r12, [rbp - SPI_LEN]
.spi_wsr_loop:
    ; skip trailing whitespace
    test r12, r12
    jle .spi_done
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r12
    call str_ws_before          ; eax = whitespace?, rcx = where it starts
    test eax, eax
    jz .spi_wsr_piece
    mov r12, rcx
    jmp .spi_wsr_loop

.spi_wsr_piece:
    cmp qword [rbp - SPI_MAX], 0
    jne .spi_wsr_scan
    ; Likewise from the other end: ' a b '.rsplit(None, 1) is [' a', 'b'].
    xor r13d, r13d
.spi_wsr_emit_last:
    mov rsi, r12
    sub rsi, r13
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r13
    call .spi_emit_front
    jmp .spi_done

.spi_wsr_scan:
    mov r13, r12
.spi_wsr_find:
    test r13, r13
    jle .spi_wsr_emit
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r13
    call str_ws_before
    test eax, eax
    jnz .spi_wsr_emit
    mov r13, rcx
    jmp .spi_wsr_find
.spi_wsr_emit:
    mov rsi, r12
    sub rsi, r13
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r13
    call .spi_emit_front
    mov r12, r13
    cmp qword [rbp - SPI_MAX], 0
    jl .spi_wsr_loop
    dec qword [rbp - SPI_MAX]
    jmp .spi_wsr_loop

.spi_done:
    mov rax, [rbp - SPI_LIST]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.spi_empty_sep:
    RAISE exc_ValueError_type, "empty separator"

.spi_type_error:
    mov rsi, rax
    CSTRING rdi, `must be str or None, not \x01`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

;; Append a piece (rdi = data, rsi = length) to the result list.
;; A piece, as a new str.  rdi = its bytes, rsi = its length.
.spi_piece:
    cmp qword [rbp - SPI_ASCII], 0
    je .spi_piece_general
    ; This is reached by `call`, so rsp is 8 past aligned on entry and the
    ; push counts below are ODD where a function's would be even.
    push rdi                    ; source
    push rsi                    ; length
    push rsi                    ; pad
    mov rdi, rsi                ; bytes and code points are the same number
    call str_alloc_bytes
    pop rdx                     ; pad
    pop rdx                     ; length
    pop rsi                     ; source
    push rax
    lea rdi, [rax + PyStrObject.data]
    call ap_memcpy
    pop rax
    ret
.spi_piece_general:
    jmp str_new_heap

.spi_emit:
    push r12
    push r13
    call .spi_piece
    push rax
    mov rdi, [rbp - SPI_LIST]
    mov rsi, rax
    call list_append
    pop rdi
    call obj_decref
    pop r13
    pop r12
    ret

;; The same, but inserted at the front: the right-hand scans produce pieces
;; in reverse.
.spi_emit_front:
    push r12
    push r13
    call .spi_piece
    ; list.insert(0, piece), through the method's own args-array interface
    sub rsp, 32
    mov rcx, [rbp - SPI_LIST]
    mov [rsp], rcx
    mov rcx, [rel v_int_bias]       ; the Value for 0
    mov [rsp + 8], rcx
    mov [rsp + 16], rax
    push rax
    lea rdi, [rsp + 8]
    mov esi, 3
    call list_method_insert
    pop rdi
    add rsp, 32
    call obj_decref
    pop r13
    pop r12
    ret
END_FUNC str_split_impl

DEF_FUNC_BARE str_method_split
    xor edx, edx                ; scan from the left
    jmp str_split_impl
END_FUNC str_method_split


;; ============================================================================
;; fmtbuf_append(rdi = &{buf, used, cap}, rsi = data, rdx = length)
;; ============================================================================
DEF_FUNC_LOCAL fmtbuf_append, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r13, r13
    jz .fa_done
    mov rax, [rbx + 8]
    add rax, r13
    cmp rax, [rbx + 16]
    jbe .fa_room
.fa_grow:
    mov rcx, [rbx + 16]
    shl rcx, 1
    cmp rcx, rax
    jae .fa_have_cap
    mov rcx, rax
.fa_have_cap:
    mov [rbx + 16], rcx
    mov rdi, [rbx]
    mov rsi, rcx
    call ap_realloc
    mov [rbx], rax
.fa_room:
    mov rdi, [rbx]
    add rdi, [rbx + 8]
    mov rsi, r12
    mov rdx, r13
    call ap_memcpy
    add [rbx + 8], r13
.fa_done:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC fmtbuf_append

;; ============================================================================
;; str_method_format(args, nargs) -> new formatted string
;;
;; The whole replacement-field grammar: {}, {2}, {name}, an optional !r/!s/!a
;; conversion and an optional :spec, which is handed to the same formatter an
;; f-string uses.  Only {} and {N} were understood before, and anything else
;; made the function bail and return whatever it had accumulated -- so
;; "{:>6}".format("ab") was the empty string.
;; ============================================================================
SF_STATE  equ 24            ; {buf, used, cap} as three consecutive qwords
SF_ARGS   equ 32
SF_NPOS   equ 40
SF_AUTO   equ 48
SF_KWN    equ 56            ; the kw_names tuple, or 0
SF_NKW    equ 64
SF_FSTART equ 72
SF_FEND   equ 80
SF_CONV   equ 88
SF_SSTART equ 96
SF_SEND   equ 104
SF_VALUE  equ 112
SF_FRAME  equ 136            ; + 5 pushes = 176, 16-aligned
DEF_FUNC str_method_format, SF_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov [rbp - SF_ARGS], rdi
    mov rbx, rdi

    ; Keyword arguments arrive as trailing values with their names in
    ; kw_names_pending; clear it so a nested call cannot see ours.
    mov rax, [gs:ThreadState.kw_names_pending]
    mov [rbp - SF_KWN], rax
    mov qword [rbp - SF_NKW], 0
    test rax, rax
    jz .fm_no_kw
    mov rcx, [rax + PyTupleObject.ob_size]
    mov [rbp - SF_NKW], rcx
    sub rsi, rcx
    mov qword [gs:ThreadState.kw_names_pending], 0
.fm_no_kw:
    dec rsi                     ; drop self
    mov [rbp - SF_NPOS], rsi

    mov rax, [rbx]
    lea r12, [rax + PyStrObject.data]
    mov r13, [rax + PyStrObject.ob_size]

    lea rdi, [r13 + 64]
    call ap_malloc
    mov [rbp - SF_STATE], rax
    mov qword [rbp - SF_STATE + 8], 0
    lea rax, [r13 + 64]
    mov [rbp - SF_STATE + 16], rax

    xor r15d, r15d              ; cursor
    mov qword [rbp - SF_AUTO], 0

.fm_loop:
    cmp r15, r13
    jge .fm_done
    movzx eax, byte [r12 + r15]
    cmp al, '{'
    je .fm_open
    cmp al, '}'
    je .fm_close
.fm_literal:
    lea rdi, [rbp - SF_STATE]
    lea rsi, [r12 + r15]
    mov edx, 1
    call fmtbuf_append
    inc r15
    jmp .fm_loop

.fm_close:
    ; "}}" is a literal brace; a lone one is an error, as in CPython.
    lea rcx, [r15 + 1]
    cmp rcx, r13
    jge .fm_lone_brace
    cmp byte [r12 + rcx], '}'
    jne .fm_lone_brace
    lea rdi, [rbp - SF_STATE]
    lea rsi, [r12 + r15]
    mov edx, 1
    call fmtbuf_append
    add r15, 2
    jmp .fm_loop

.fm_open:
    lea rcx, [r15 + 1]
    cmp rcx, r13
    jge .fm_unterminated
    cmp byte [r12 + rcx], '{'
    jne .fm_field
    lea rdi, [rbp - SF_STATE]
    lea rsi, [r12 + r15]
    mov edx, 1
    call fmtbuf_append
    add r15, 2
    jmp .fm_loop

.fm_field:
    inc r15
    mov [rbp - SF_FSTART], r15
    mov qword [rbp - SF_CONV], 0
    mov qword [rbp - SF_SSTART], 0
    mov qword [rbp - SF_SEND], 0
    xor r14d, r14d              ; bracket depth
.fm_scan_field:
    cmp r15, r13
    jge .fm_unterminated
    movzx eax, byte [r12 + r15]
    cmp al, '['
    jne .fm_scan_not_open
    inc r14
    jmp .fm_scan_next
.fm_scan_not_open:
    cmp al, ']'
    jne .fm_scan_check_end
    dec r14
    jmp .fm_scan_next
.fm_scan_check_end:
    test r14, r14
    jnz .fm_scan_next
    cmp al, '!'
    je .fm_field_end
    cmp al, ':'
    je .fm_field_end
    cmp al, '}'
    je .fm_field_end
.fm_scan_next:
    inc r15
    jmp .fm_scan_field

.fm_field_end:
    mov [rbp - SF_FEND], r15
    movzx eax, byte [r12 + r15]
    cmp al, '!'
    jne .fm_after_conv
    inc r15
    cmp r15, r13
    jge .fm_unterminated
    movzx eax, byte [r12 + r15]
    mov [rbp - SF_CONV], rax
    inc r15
.fm_after_conv:
    cmp r15, r13
    jge .fm_unterminated
    movzx eax, byte [r12 + r15]
    cmp al, ':'
    jne .fm_after_spec
    inc r15
    mov [rbp - SF_SSTART], r15
    xor r14d, r14d
.fm_scan_spec:
    cmp r15, r13
    jge .fm_unterminated
    movzx eax, byte [r12 + r15]
    cmp al, '{'
    jne .fm_spec_not_open
    inc r14
    jmp .fm_spec_next
.fm_spec_not_open:
    cmp al, '}'
    jne .fm_spec_next
    test r14, r14
    jz .fm_spec_end
    dec r14
.fm_spec_next:
    inc r15
    jmp .fm_scan_spec
.fm_spec_end:
    mov [rbp - SF_SEND], r15
.fm_after_spec:
    cmp r15, r13
    jge .fm_unterminated
    cmp byte [r12 + r15], '}'
    jne .fm_unterminated
    inc r15                     ; past the closing brace

    mov rdi, [rbp - SF_ARGS]
    mov rsi, [rbp - SF_NPOS]
    mov rdx, [rbp - SF_KWN]
    mov rcx, r12
    add rcx, [rbp - SF_FSTART]
    mov r8, [rbp - SF_FEND]
    sub r8, [rbp - SF_FSTART]
    lea r9, [rbp - SF_AUTO]
    call fm_resolve_full
    mov [rbp - SF_VALUE], rax

    ; !r and !a render the repr; !s the str.  Anything else is left alone.
    mov rcx, [rbp - SF_CONV]
    test rcx, rcx
    jz .fm_no_conv
    cmp rcx, 'r'
    je .fm_conv_repr
    cmp rcx, 'a'
    je .fm_conv_repr
    cmp rcx, 's'
    jne .fm_no_conv
    mov rdi, [rbp - SF_VALUE]
    call obj_str
    jmp .fm_conv_done
.fm_conv_repr:
    mov rdi, [rbp - SF_VALUE]
    call obj_repr
.fm_conv_done:
    push rax
    mov rdi, [rbp - SF_VALUE]
    DECREF_V rdi, rcx
    pop rax
    mov [rbp - SF_VALUE], rax
.fm_no_conv:

    ; The spec, as a str, handed to the formatter f-strings use.
    mov rcx, [rbp - SF_SEND]
    sub rcx, [rbp - SF_SSTART]
    jle .fm_plain_str
    mov rdi, r12
    add rdi, [rbp - SF_SSTART]
    mov rsi, rcx
    call str_new_heap
    push rax
    ; A spec can hold fields of its own -- "{:{}}" and "{:>{width}}" -- and
    ; they are formatted with the same arguments before the spec is applied.
    ; The scanner already counts braces to find the end of the spec; nothing
    ; substituted them, so format_apply_spec was handed "{}" and rejected it.
    mov rdi, rax
    mov rsi, [rbp - SF_ARGS]
    mov rdx, [rbp - SF_NPOS]
    mov rcx, [rbp - SF_KWN]
    lea r8, [rbp - SF_AUTO]
    call fm_expand_spec
    test rax, rax
    jz .fm_spec_plain
    mov rdi, [rsp]
    mov [rsp], rax              ; the expansion is what gets released
    call obj_decref
.fm_spec_plain:
    ; format(value, spec), not format_apply_spec: a class formats ITSELF
    ; through __format__, and this went straight to the spec machinery -- so
    ; "{:x}".format(obj) for a class with a __format__ of its own reported
    ; that the object could not be interpreted as an integer, and "{}" of it
    ; printed the default repr.  f-strings have always called the dunder;
    ; str.format is the same operation and now shares its funnel.
    ;
    ; 24, because this arm is reached with the SPEC pushed: the function's
    ; body runs 16-byte aligned, that push leaves it eight out, and the frame
    ; is what puts it back.  The plain arm below is reached with nothing
    ; pushed and takes 16.
    sub rsp, 24
    mov rax, [rbp - SF_VALUE]
    mov [rsp], rax              ; args[0] = the value
    mov rax, [rsp + 24]
    mov [rsp + 8], rax          ; args[1] = the spec
    mov rdi, rsp
    mov esi, 2
    extern builtin_format_fn
    call builtin_format_fn
    V_UNPACK rax, rdx
    add rsp, 24
    mov r14, rax
    pop rdi
    call obj_decref
    jmp .fm_have_text

.fm_plain_str:
    ; 16, because this arm is reached with nothing pushed: the body is already
    ; aligned and the array is all the room it needs.
    sub rsp, 16
    mov rax, [rbp - SF_VALUE]
    mov [rsp], rax              ; args[0] = the value, and no spec
    mov rdi, rsp
    mov esi, 1
    call builtin_format_fn
    V_UNPACK rax, rdx
    add rsp, 16
    mov r14, rax

.fm_have_text:
    mov rdi, [rbp - SF_VALUE]
    DECREF_V rdi, rcx
    test r14, r14
    jz .fm_loop
    lea rdi, [rbp - SF_STATE]
    lea rsi, [r14 + PyStrObject.data]
    mov rdx, [r14 + PyStrObject.ob_size]
    call fmtbuf_append
    mov rdi, r14
    call obj_decref
    jmp .fm_loop

.fm_lone_brace:
    RAISE exc_ValueError_type, "Single '}' encountered in format string"

.fm_unterminated:
    RAISE exc_ValueError_type, "Single '{' encountered in format string"

.fm_done:
    mov rdi, [rbp - SF_STATE]
    mov rsi, [rbp - SF_STATE + 8]
    call str_new_heap
    push rax
    mov rdi, [rbp - SF_STATE]
    call ap_free
    pop rax
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret
END_FUNC str_method_format

;; ============================================================================
;; fm_resolve_field(rdi = args, rsi = npos, rdx = kw_names or 0,
;;                  rcx = field bytes, r8 = field length, r9 = &auto counter)
;;   -> rax = the argument the field names, a new reference
;; Empty means the next positional, all digits an explicit one, anything else
;; a keyword.
;; ============================================================================
RF_ARGS  equ 8
RF_NPOS  equ 16
RF_KWN   equ 24
RF_NAME  equ 32
RF_LEN   equ 40
RF_AUTO  equ 48
RF_FRAME equ 64             ; + 2 pushes = 80
DEF_FUNC_LOCAL fm_resolve_field, RF_FRAME
    push rbx
    push r12
    mov [rbp - RF_ARGS], rdi
    mov [rbp - RF_NPOS], rsi
    mov [rbp - RF_KWN], rdx
    mov [rbp - RF_NAME], rcx
    mov [rbp - RF_LEN], r8
    mov [rbp - RF_AUTO], r9

    test r8, r8
    jz .rf_auto

    ; All digits?
    xor r12d, r12d              ; the parsed index
    xor ecx, ecx
.rf_digits:
    cmp rcx, [rbp - RF_LEN]
    jge .rf_positional
    mov rdx, [rbp - RF_NAME]
    movzx eax, byte [rdx + rcx]
    cmp al, '0'
    jb .rf_keyword
    cmp al, '9'
    ja .rf_keyword
    imul r12, r12, 10
    sub eax, '0'
    add r12, rax
    inc rcx
    jmp .rf_digits

.rf_auto:
    mov rax, [rbp - RF_AUTO]
    mov r12, [rax]
    inc qword [rax]
.rf_positional:
    cmp r12, [rbp - RF_NPOS]
    jge .rf_index_error
    mov rax, [rbp - RF_ARGS]
    lea rcx, [r12 + 1]          ; args[0] is self
    mov rax, [rax + rcx*8]
    INCREF_V rax, rcx
    pop r12
    pop rbx
    leave
    ret

.rf_keyword:
    mov rax, [rbp - RF_KWN]
    test rax, rax
    jz .rf_key_error
    mov rbx, [rax + PyTupleObject.ob_size]
    xor r12d, r12d
.rf_kw_scan:
    cmp r12, rbx
    jge .rf_key_error
    mov rax, [rbp - RF_KWN]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdi, [rax + r12*8]
    add rdi, PyStrObject.data
    mov rsi, [rbp - RF_NAME]
    mov rdx, [rbp - RF_LEN]
    call fm_name_equals
    test eax, eax
    jnz .rf_kw_found
    inc r12
    jmp .rf_kw_scan
.rf_kw_found:
    ; The keyword values sit after the positional ones.
    mov rax, [rbp - RF_ARGS]
    mov rcx, [rbp - RF_NPOS]
    add rcx, r12
    inc rcx                     ; past self
    mov rax, [rax + rcx*8]
    INCREF_V rax, rcx
    pop r12
    pop rbx
    leave
    ret

.rf_index_error:
    RAISE exc_IndexError_type, "Replacement index out of range for positional args tuple"
.rf_key_error:
    RAISE exc_KeyError_type, "format() got no such keyword argument"
END_FUNC fm_resolve_field

;; ============================================================================
;; fm_resolve_full(rdi = args, rsi = npos, rdx = kw_names or 0,
;;                 rcx = field bytes, r8 = field length, r9 = &auto counter)
;;   -> rax = the object the field names, a new reference
;;
;; The field id, then the `.name` and `[key]` suffixes CPython allows after it:
;; "{0.attr}", "{0[key]}", "{name.a[0].b}".  fm_resolve_field saw the whole
;; text as one name and raised KeyError for any of them; the scanner above
;; already counts bracket depth so that a ':' inside [] is not a spec, so the
;; text arrived here intact and unread.
;; ============================================================================
FRF_ARGS  equ 8
FRF_NPOS  equ 16
FRF_KWN   equ 24
FRF_NAME  equ 32
FRF_LEN   equ 40
FRF_AUTO  equ 48
FRF_POS   equ 56
FRF_START equ 64
FRF_FRAME equ 80            ; + 2 pushes = 96, 16-aligned

extern exc_AttributeError_type
DEF_FUNC_LOCAL fm_resolve_full, FRF_FRAME
    push rbx
    push r12
    mov [rbp - FRF_ARGS], rdi
    mov [rbp - FRF_NPOS], rsi
    mov [rbp - FRF_KWN], rdx
    mov [rbp - FRF_NAME], rcx
    mov [rbp - FRF_LEN], r8
    mov [rbp - FRF_AUTO], r9

    ; The field id runs to the first '.' or '['.
    xor ecx, ecx
.frf_scan:
    cmp rcx, [rbp - FRF_LEN]
    jge .frf_base
    mov rdx, [rbp - FRF_NAME]
    movzx eax, byte [rdx + rcx]
    cmp al, '.'
    je .frf_base
    cmp al, '['
    je .frf_base
    inc rcx
    jmp .frf_scan
.frf_base:
    mov [rbp - FRF_POS], rcx
    mov rdi, [rbp - FRF_ARGS]
    mov rsi, [rbp - FRF_NPOS]
    mov rdx, [rbp - FRF_KWN]
    mov r8, rcx
    mov rcx, [rbp - FRF_NAME]
    mov r9, [rbp - FRF_AUTO]
    call fm_resolve_field

    ; The suffixes, if any, are the same walk format_map needs.
    mov rdi, rax
    mov rsi, [rbp - FRF_NAME]
    mov rdx, [rbp - FRF_LEN]
    mov rcx, [rbp - FRF_POS]
    call fm_apply_suffix
    pop r12
    pop rbx
    leave
    ret
END_FUNC fm_resolve_full

;; ============================================================================
;; fm_apply_suffix(rdi = the object so far (owned), rsi = field bytes,
;;                 rdx = field length, rcx = where the suffixes start)
;;   -> rax = the object the chain names, a new reference
;;
;; ".name" and "[key]", repeated: "{0.a[1].b}".  Shared by format() and
;; format_map(), which parse the field id differently and the suffix the same.
;; ============================================================================
DEF_FUNC_LOCAL fm_apply_suffix, FRF_FRAME
    push rbx
    push r12
    mov rbx, rdi
    mov [rbp - FRF_NAME], rsi
    mov [rbp - FRF_LEN], rdx
    mov [rbp - FRF_POS], rcx

.frf_suffix:
    mov rcx, [rbp - FRF_POS]
    cmp rcx, [rbp - FRF_LEN]
    jge .frf_done
    mov rdx, [rbp - FRF_NAME]
    movzx eax, byte [rdx + rcx]
    inc rcx
    mov [rbp - FRF_POS], rcx
    cmp al, '.'
    je .frf_attr
    cmp al, '['
    je .frf_item
    jmp .frf_done

.frf_attr:
    mov rax, [rbp - FRF_POS]
    mov [rbp - FRF_START], rax
.frf_attr_scan:
    mov rcx, [rbp - FRF_POS]
    cmp rcx, [rbp - FRF_LEN]
    jge .frf_attr_end
    mov rdx, [rbp - FRF_NAME]
    movzx eax, byte [rdx + rcx]
    cmp al, '.'
    je .frf_attr_end
    cmp al, '['
    je .frf_attr_end
    inc qword [rbp - FRF_POS]
    jmp .frf_attr_scan
.frf_attr_end:
    mov rdi, [rbp - FRF_NAME]
    add rdi, [rbp - FRF_START]
    mov rsi, [rbp - FRF_POS]
    sub rsi, [rbp - FRF_START]
    call str_new_heap
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    extern obj_getattr_opt
    call obj_getattr_opt
    push rax
    mov rdi, r12
    call obj_decref
    pop rax
    test rax, rax
    jz .frf_no_attr
    DECREF_V rbx, rcx
    mov rbx, rax
    jmp .frf_suffix

.frf_item:
    mov rax, [rbp - FRF_POS]
    mov [rbp - FRF_START], rax
.frf_item_scan:
    mov rcx, [rbp - FRF_POS]
    cmp rcx, [rbp - FRF_LEN]
    jge .frf_bad_item
    mov rdx, [rbp - FRF_NAME]
    movzx eax, byte [rdx + rcx]
    cmp al, ']'
    je .frf_item_end
    inc qword [rbp - FRF_POS]
    jmp .frf_item_scan
.frf_item_end:
    ; All digits is an integer key, anything else a string one -- CPython's
    ; rule, which is why "{0[key]}" needs no quotes.
    mov rcx, [rbp - FRF_START]
    mov r12, [rbp - FRF_POS]
    cmp rcx, r12
    je .frf_key_str
    xor r8d, r8d                ; the parsed index
.frf_key_digits:
    cmp rcx, r12
    jge .frf_key_int
    mov rdx, [rbp - FRF_NAME]
    movzx eax, byte [rdx + rcx]
    cmp al, '0'
    jb .frf_key_str
    cmp al, '9'
    ja .frf_key_str
    imul r8, r8, 10
    sub eax, '0'
    add r8, rax
    inc rcx
    jmp .frf_key_digits
.frf_key_int:
    mov rax, r8
    V_PACK_I64 rax, rcx
    mov r12, rax
    jmp .frf_have_key
.frf_key_str:
    mov rdi, [rbp - FRF_NAME]
    add rdi, [rbp - FRF_START]
    mov rsi, [rbp - FRF_POS]
    sub rsi, [rbp - FRF_START]
    call str_new_heap
    mov r12, rax
.frf_have_key:
    inc qword [rbp - FRF_POS]   ; past the ']'
    mov rdi, rbx
    mov rsi, r12
    call fm_subscript
    push rax
    DECREF_V r12, rcx
    pop rax
    cmp rax, -1
    je .frf_not_subscriptable
    test rax, rax
    jz .frf_bad_item
    DECREF_V rbx, rcx
    mov rbx, rax
    jmp .frf_suffix

.frf_done:
    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret

.frf_no_attr:
    RAISE exc_AttributeError_type, "no such attribute in a format field"
.frf_not_subscriptable:
    RAISE exc_TypeError_type, "object is not subscriptable"
.frf_bad_item:
    RAISE exc_KeyError_type, "no such item in a format field"
END_FUNC fm_apply_suffix

;; ============================================================================
;; fm_subscript(rdi = the object, rsi = the key Value) -> rax = Value, or 0
;; A "{0[k]}" lookup: the mapping protocol when the object has one, and
;; nothing otherwise.
;; ============================================================================
DEF_FUNC_LOCAL fm_subscript
    V_TEST_PTR rdi, rax
    ja .fms_no_protocol
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .fms_no_protocol
    mov rax, [rax + PyMappingMethods.mp_subscript]
    test rax, rax
    jz .fms_no_protocol
    call rax
    leave
    ret
.fms_no_protocol:
    ; -1, not 0: "this object cannot be subscripted at all" is a TypeError in
    ; CPython and "no such key" is a KeyError.
    mov rax, -1
    leave
    ret
END_FUNC fm_subscript

;; ============================================================================
;; fm_expand_spec(rdi = the spec str, rsi = args, rdx = npos, rcx = kw_names,
;;                r8 = &auto counter) -> rax = a new str, or 0 when the spec
;; holds no fields at all and can be used as it stands.
;;
;; "{:{}}" and "{:>{width}}": the spec is itself a format string, formatted
;; with the same arguments one level down.
;; ============================================================================
FES_SPEC  equ 8
FES_ARGS  equ 16
FES_NPOS  equ 24
FES_KWN   equ 32
FES_AUTO  equ 40
FES_POS   equ 48
FES_START equ 56
FES_STATE equ 80            ; {buf, used, cap} for fmtbuf_append
FES_FRAME equ 96            ; + 2 pushes = 112, 16-aligned

DEF_FUNC_LOCAL fm_expand_spec, FES_FRAME
    push rbx
    push r12
    mov [rbp - FES_SPEC], rdi
    mov [rbp - FES_ARGS], rsi
    mov [rbp - FES_NPOS], rdx
    mov [rbp - FES_KWN], rcx
    mov [rbp - FES_AUTO], r8

    ; Nothing to do unless there is a brace.
    mov rbx, rdi
    mov r12, [rbx + PyStrObject.ob_size]
    xor ecx, ecx
.fes_look:
    cmp rcx, r12
    jge .fes_nothing
    cmp byte [rbx + PyStrObject.data + rcx], '{'
    je .fes_build
    inc rcx
    jmp .fes_look
.fes_nothing:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.fes_build:
    mov qword [rbp - FES_STATE], 0
    mov qword [rbp - FES_STATE + 8], 0
    mov qword [rbp - FES_STATE + 16], 0
    mov qword [rbp - FES_POS], 0
.fes_loop:
    mov rcx, [rbp - FES_POS]
    cmp rcx, r12
    jge .fes_finish
    movzx eax, byte [rbx + PyStrObject.data + rcx]
    cmp al, '{'
    je .fes_field
    inc qword [rbp - FES_POS]
    lea rdi, [rbp - FES_STATE]
    lea rsi, [rbx + PyStrObject.data + rcx]
    mov edx, 1
    call fmtbuf_append
    jmp .fes_loop

.fes_field:
    inc rcx
    mov [rbp - FES_START], rcx
.fes_field_scan:
    cmp rcx, r12
    jge .fes_unterminated
    cmp byte [rbx + PyStrObject.data + rcx], '}'
    je .fes_field_end
    inc rcx
    jmp .fes_field_scan
.fes_field_end:
    mov [rbp - FES_POS], rcx
    mov rdi, [rbp - FES_ARGS]
    mov rsi, [rbp - FES_NPOS]
    mov rdx, [rbp - FES_KWN]
    lea rcx, [rbx + PyStrObject.data]
    add rcx, [rbp - FES_START]
    mov r8, [rbp - FES_POS]
    sub r8, [rbp - FES_START]
    mov r9, [rbp - FES_AUTO]
    call fm_resolve_full
    push rax
    mov rdi, rax
    call obj_str
    mov r12, rax
    pop rdi
    DECREF_V rdi, rcx
    mov r12, r12
    lea rdi, [rbp - FES_STATE]
    lea rsi, [r12 + PyStrObject.data]
    mov rdx, [r12 + PyStrObject.ob_size]
    call fmtbuf_append
    mov rdi, r12
    call obj_decref
    mov r12, [rbx + PyStrObject.ob_size]
    inc qword [rbp - FES_POS]   ; past the '}'
    jmp .fes_loop

.fes_finish:
    mov rdi, [rbp - FES_STATE]
    mov rsi, [rbp - FES_STATE + 8]
    call str_new_heap
    push rax
    mov rdi, [rbp - FES_STATE]
    test rdi, rdi
    jz .fes_out
    extern ap_free
    call ap_free
.fes_out:
    pop rax
    pop r12
    pop rbx
    leave
    ret

.fes_unterminated:
    RAISE exc_ValueError_type, "unmatched '{' in format spec"
END_FUNC fm_expand_spec

;; fm_name_equals(rdi = NUL-terminated name, rsi = bytes, rdx = length) -> eax
DEF_FUNC_LOCAL fm_name_equals
    xor ecx, ecx
.ne_loop:
    cmp rcx, rdx
    jge .ne_at_end
    movzx eax, byte [rdi + rcx]
    test al, al
    jz .ne_no
    movzx r8d, byte [rsi + rcx]
    cmp al, r8b
    jne .ne_no
    inc rcx
    jmp .ne_loop
.ne_at_end:
    cmp byte [rdi + rcx], 0
    jne .ne_no
    mov eax, 1
    leave
    ret
.ne_no:
    xor eax, eax
    leave
    ret
END_FUNC fm_name_equals

FM_ARGS   equ 8
FM_MAP    equ 16
FM_BUF    equ 24
FM_USED   equ 32
FM_CAP    equ 40
FM_VALUE  equ 48            ; the Value the lookup answered, still packed
FM_OWNED  equ 56            ; ...and whether the reference is ours to release
FM_FRAME  equ 72            ; + 5 pushes = 112, 16-aligned

;; ============================================================================
;; fm_lookup(rdi = the mapping, rsi = the key str)
;;   -> (rax = a Value, edx = its tag, r8d = 1 when the reference is OWNED)
;;
;; str.format_map takes ANY mapping, and CPython's is PyObject_GetItem: its
;; own test suite calls `'{a1}'.format_map(match_object)`.  This read whatever
;; it was handed as a PyDictObject and probed the object's header as a hash
;; table, which is what killed test_re.
;;
;; A dict keeps the direct lookup, whose miss is a NULL Value with nothing
;; pending; anything else goes through mp_subscript, which RAISES on a miss --
;; and hands back an OWNED reference where dict_get's is borrowed, which is
;; what r8 is for.
;; ============================================================================
DEF_FUNC_LOCAL fm_lookup
    xor r8d, r8d
    V_TEST_PTR rdi, rax
    ja .fml_none
    test rdi, rdi
    jz .fml_none
    mov rax, [rdi + PyObject.ob_type]
    extern dict_type
    lea rcx, [rel dict_type]
    cmp rax, rcx
    je .fml_dict
    REQUIRE_DICT_TYPE rax, rcx, .fml_generic
.fml_dict:
    extern dict_get
    call dict_get
    xor r8d, r8d
    leave
    ret
.fml_generic:
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .fml_none
    mov rax, [rax + PyMappingMethods.mp_subscript]
    test rax, rax
    jz .fml_none
    call rax
    mov r8d, 1
    leave
    ret
.fml_none:
    ; Not subscriptable at all.  CPython's PyObject_GetItem names the type;
    ; falling through to the caller's "no such key" KeyError named the wrong
    ; problem, and `'{a}'.format_map(5)` came out as a KeyError.
    push rdi
    push rdi                    ; and a pad: this frame carves nothing
    extern value_type
    call value_type             ; rdi is the mapping, as a Value
    mov rsi, rax
    CSTRING rdi, `'\x01' object is not subscriptable`
    extern type_name_message
    call type_name_message
    mov rsi, rax
    extern exc_TypeError_type
    lea rdi, [rel exc_TypeError_type]
    extern set_exception
    call set_exception
    pop rdi
    pop rdi
    xor eax, eax
    xor edx, edx
    xor r8d, r8d
    leave
    ret
END_FUNC fm_lookup

;; ============================================================================
;; str_method_format_map(rdi = args, rsi = nargs) -> rax = a formatted str
;; args[0] = self (the format string), args[1] = the mapping.
;; Replaces {key} with mapping[key].
;; ============================================================================
DEF_FUNC str_method_format_map, FM_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    cmp rsi, 2
    jne .fmap_error

    mov [rbp - FM_ARGS], rdi
    mov rax, [rdi]              ; self = format string
    mov rcx, [rdi + 8]         ; mapping dict
    mov [rbp - FM_MAP], rcx

    lea r12, [rax + PyStrObject.data]   ; r12 = fmt data
    mov r13d, [rax + PyStrObject.ob_size] ; r13 = fmt len

    ; Allocate output buffer
    lea rdi, [r13 + 64]
    call ap_malloc
    mov [rbp - FM_BUF], rax
    mov qword [rbp - FM_USED], 0
    lea rax, [r13 + 64]
    mov [rbp - FM_CAP], rax

    xor ecx, ecx               ; source index

.fmap_loop:
    cmp ecx, r13d
    jge .fmap_done
    movzx eax, byte [r12 + rcx]
    cmp al, '{'
    je .fmap_brace
    cmp al, '}'
    je .fmap_close_brace

    ; Regular char — append
    push rcx
    mov rdi, [rbp - FM_BUF]
    mov rax, [rbp - FM_USED]
    movzx edx, byte [r12 + rcx]
    mov [rdi + rax], dl
    inc qword [rbp - FM_USED]
    pop rcx
    inc ecx
    jmp .fmap_loop

.fmap_brace:
    inc ecx
    cmp ecx, r13d
    jge .fmap_done
    movzx eax, byte [r12 + rcx]
    cmp al, '{'
    je .fmap_literal_open

    ; Extract key name until '}'
    mov r14d, ecx              ; key start
.fmap_key_scan:
    cmp ecx, r13d
    jge .fmap_done
    movzx eax, byte [r12 + rcx]
    cmp al, '}'
    je .fmap_have_key
    inc ecx
    jmp .fmap_key_scan

.fmap_base_scan:
    ; The key ends at the first '.' or '[': what follows is the suffix chain
    ; fm_apply_suffix walks, exactly as it does for format().
    cmp esi, ecx
    jge .fmap_base_done
    movzx eax, byte [r12 + rsi]
    cmp al, '.'
    je .fmap_base_done
    cmp al, '['
    je .fmap_base_done
    inc esi
    jmp .fmap_base_scan
.fmap_base_done:
    ret

.fmap_key_error:
    RAISE exc_KeyError_type, "format_map() got no such key"

.fmap_lookup_failed:
    ; A dict miss answers a NULL Value with nothing pending, and the KeyError
    ; is ours to raise.  A mapping of its own has already raised -- the
    ; IndexError a match object gives for an unknown group, say -- and that
    ; exception is the answer.
    cmp qword [gs:ThreadState.current_exception], 0
    je .fmap_key_error
    ; Reached with the two source-position pushes of .fmap_have_key still on
    ; the stack, so the pops below would have handed the caller its callee-
    ; saved registers shifted by two -- r12 among them, which op_call then
    ; wrote through on its way to the unwinder.  Cut back to the five pushes.
    lea rsp, [rbp - FM_FRAME - 40]
    mov rdi, [rbp - FM_BUF]
    call ap_free
    xor eax, eax
    xor edx, edx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.fmap_have_key:
    ; Key is from r14 to ecx (exclusive); the base key stops at the first
    ; '.' or '[' within that.
    push rcx
    mov esi, r14d
    call .fmap_base_scan        ; esi = the end of the base key
    mov r15d, esi               ; where the suffixes start
    pop rcx
    push rcx
    inc ecx                     ; skip '}'
    push rcx                    ; save next source pos

    ; Create key string
    lea rdi, [r12 + r14]
    mov esi, r15d
    sub esi, r14d               ; base key length
    movzx esi, si               ; zero-extend
    call str_new_heap
    push rax                    ; save key str

    ; Look up in the mapping -- any mapping, not only a dict.
    mov rdi, [rbp - FM_MAP]
    mov rsi, rax
    call fm_lookup
    mov [rbp - FM_VALUE], rax   ; the Value, before it is taken apart
    mov [rbp - FM_OWNED], r8
    V_UNPACK rax, rdx
    ; A miss answers a NULL Value.  Nothing checked, and obj_str below then
    ; dereferenced it: every missing key was a segfault rather than a KeyError.
    test edx, edx
    jz .fmap_lookup_failed
    ; rax = value payload, edx = value tag
    push rax
    push rdx

    ; DECREF key
    mov rdi, [rsp + 16]         ; key str
    call obj_decref

    ; Convert value to string
    pop rsi                     ; value tag
    pop rdi                     ; value payload
    V_PACK rdi, rsi
    ; The suffixes, when the field had any.  dict_get answered a borrowed
    ; reference, so it is INCREF'd first and fm_apply_suffix owns it.
    mov rax, [rsp + 16]         ; the '}' position: key, next, '}' on the stack
    cmp r15d, eax
    jge .fmap_no_suffix
    push rdi
    INCREF_V rdi, rcx
    pop rdi
    mov rsi, r12
    mov edx, eax
    mov ecx, r15d
    push rax
    call fm_apply_suffix
    pop rcx
    push rax
    mov rdi, rax
    call obj_str
    pop rdi
    DECREF_V rdi, rcx
    jmp .fmap_have_text
.fmap_no_suffix:
    call obj_str
.fmap_have_text:
    ; rax = result payload, edx = tag
    push rax                    ; save str obj for DECREF

    ; Copy string data to buffer
    mov edx, [rax + PyStrObject.ob_size]
    ; Ensure buffer space
    mov rdi, [rbp - FM_USED]
    add rdi, rdx
    cmp rdi, [rbp - FM_CAP]
    jbe .fmap_copy_ok
    mov rdi, [rbp - FM_CAP]
    shl rdi, 1
    add rdi, rdx
    mov [rbp - FM_CAP], rdi
    push rdx
    mov rsi, rdi
    mov rdi, [rbp - FM_BUF]
    call ap_realloc
    mov [rbp - FM_BUF], rax
    pop rdx
    mov rax, [rsp]              ; re-read str obj
.fmap_copy_ok:
    test edx, edx
    jz .fmap_val_done
    push rdx
    mov rdi, [rbp - FM_BUF]
    add rdi, [rbp - FM_USED]
    lea rsi, [rax + PyStrObject.data]
    movzx edx, dx
    call ap_memcpy
    pop rdx
    movzx eax, dx
    add [rbp - FM_USED], rax

.fmap_val_done:
    ; DECREF temp str
    pop rdi
    call obj_decref
    ; mp_subscript hands back an OWNED reference where dict_get's is borrowed.
    cmp qword [rbp - FM_OWNED], 0
    je .fmap_not_owned
    mov qword [rbp - FM_OWNED], 0
    mov rdi, [rbp - FM_VALUE]
    DECREF_V rdi, rcx
.fmap_not_owned:
    pop rax                     ; discard saved key str slot
    pop rcx                     ; next source pos
    pop rax                     ; discard saved old ecx
    jmp .fmap_loop

.fmap_literal_open:
    push rcx
    mov rdi, [rbp - FM_BUF]
    mov rax, [rbp - FM_USED]
    mov byte [rdi + rax], '{'
    inc qword [rbp - FM_USED]
    pop rcx
    inc ecx
    jmp .fmap_loop

.fmap_close_brace:
    inc ecx
    cmp ecx, r13d
    jge .fmap_done
    movzx eax, byte [r12 + rcx]
    cmp al, '}'
    jne .fmap_loop
    push rcx
    mov rdi, [rbp - FM_BUF]
    mov rax, [rbp - FM_USED]
    mov byte [rdi + rax], '}'
    inc qword [rbp - FM_USED]
    pop rcx
    inc ecx
    jmp .fmap_loop

.fmap_done:
    mov rdi, [rbp - FM_BUF]
    mov rsi, [rbp - FM_USED]
    call str_new_heap
    push rax

    mov rdi, [rbp - FM_BUF]
    call ap_free

    pop rax
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.fmap_error:
    RAISE exc_TypeError_type, "format_map() takes exactly one argument"
END_FUNC str_method_format_map

;; ============================================================================
;; str_method_lstrip(args, nargs) -> new string with the left end stripped
;; args[0]=self, args[1]=chars (optional)
;; ============================================================================
DEF_FUNC_BARE str_method_lstrip
    mov edx, 1
    jmp str_strip_impl
END_FUNC str_method_lstrip

;; ============================================================================
;; str_method_rstrip(args, nargs) -> new string with the right end stripped
;; args[0]=self, args[1]=chars (optional)
;; ============================================================================
DEF_FUNC_BARE str_method_rstrip
    mov edx, 2
    jmp str_strip_impl
END_FUNC str_method_rstrip

;; ============================================================================
;; str_method_rsplit(args, nargs) -> list
;; Like split but from right. args[0]=self, args[1]=sep (optional)
;; For simplicity, implements same as split (no maxsplit from right)
;; ============================================================================
DEF_FUNC_BARE str_method_rsplit
    mov edx, 1                  ; scan from the right
    jmp str_split_impl
END_FUNC str_method_rsplit

;; ============================================================================
;; str.__getnewargs__(self) -> (str(self),)
;;
;; What makes a str SUBCLASS survive copy and pickle.  The reduction protocol
;; rebuilds an object as cls.__new__(cls, *args), and without these args it
;; rebuilds empty -- copy.deepcopy of a str subclass used to hand back the
;; same object uncopied, and once copy dispatched on the exact type instead it
;; handed back S('').
;;
;; The argument is a PLAIN str even when self is exact, as CPython's is: the
;; constructor is about to be given it, and handing a subclass instance back
;; into its own constructor is a different thing to ask for.
;; ============================================================================
global str_method_getnewargs
SGNA_STR   equ 8
SGNA_TUP   equ 16
SGNA_FRAME equ 32           ; + 0 pushes = 32, 16-aligned
DEF_FUNC str_method_getnewargs, SGNA_FRAME
    mov rdi, [rdi]                      ; args[0] = self, always a pointer
    mov rsi, [rdi + PyStrObject.ob_size]
    lea rdi, [rdi + PyStrObject.data]
    extern str_new_heap
    call str_new_heap
    test rax, rax
    jz .sgna_failed
    mov [rbp - SGNA_STR], rax
    mov edi, 1
    extern tuple_new
    call tuple_new
    test rax, rax
    jz .sgna_drop
    mov [rbp - SGNA_TUP], rax
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rcx, [rbp - SGNA_STR]
    mov [rdx], rcx                      ; the tuple takes the copy's reference
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx                     ; builtins return one Value
    ret
.sgna_drop:
    mov rdi, [rbp - SGNA_STR]
    extern obj_decref
    call obj_decref
.sgna_failed:
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC str_method_getnewargs

section .rodata
empty_str_cstr: db 0
