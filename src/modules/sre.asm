; sre_module.asm - _sre built-in module for apython
; Provides _sre.compile() and SRE constants needed by the re module.

%include "macros.inc"
extern val_to_i64
%include "object.inc"
%include "sre.inc"

extern bool_true
extern bool_false
extern ap_malloc
extern ap_free
extern obj_decref
extern obj_incref
extern obj_dealloc
extern str_from_cstr_heap
extern dict_new
extern dict_set
extern module_new
extern builtin_func_new
extern none_singleton
extern exc_TypeError_type
extern list_type
extern tuple_type

; From sre_pattern.asm
extern sre_pattern_type

;; ============================================================================
;; sre_compile_func(PyObject **args, int64_t nargs) -> (rax, edx)
;; _sre.compile(pattern, flags, code, groups, groupindex, indexgroup)
;;
;; args is a fat value array (16-byte stride):
;;   args[0] = pattern (str)
;;   args[1] = flags (int)
;;   args[2] = code (list of ints)
;;   args[3] = groups (int)
;;   args[4] = groupindex (dict)
;;   args[5] = indexgroup (tuple)
;; ============================================================================
SC_ARGS     equ 8
SC_NARGS    equ 16
SC_PATTERN  equ 24
SC_FLAGS    equ 32
SC_CODE     equ 40
SC_GROUPS   equ 48
SC_GINDEX   equ 56
SC_IGROUP   equ 64
SC_CODEBUF  equ 72
SC_CODELEN  equ 80
SC_FRAME    equ 88          ; + 5 pushes = 128

DEF_FUNC sre_compile_func, SC_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov [rbp - SC_ARGS], rdi
    mov [rbp - SC_NARGS], rsi

    ; Exactly six.  "At least six" let a longer call through.
    cmp rsi, 6
    jb .compile_error_args
    ja .compile_too_many

    ; Extract args (one Value per slot)
    ; args[0] = pattern string
    mov rax, [rdi]
    mov [rbp - SC_PATTERN], rax

    ; args[2] = code (list of ints)
    mov rax, [rdi + 16]
    mov [rbp - SC_CODE], rax

    ; args[1] = flags, args[3] = groups — both ints, immediate or boxed
    mov rdi, [rdi + 8]
    call val_to_i64
    mov [rbp - SC_FLAGS], rax
    mov rdi, [rbp - SC_ARGS]
    mov rdi, [rdi + 24]
    call val_to_i64
    mov [rbp - SC_GROUPS], rax
    mov rdi, [rbp - SC_ARGS]

    ; args[4] = groupindex (dict or None)
    mov rax, [rdi + 32]
    IS_NONE rax, rcx
    jne .have_groupindex
    xor eax, eax               ; NULL for None
.have_groupindex:
    mov [rbp - SC_GINDEX], rax

    ; args[5] = indexgroup (tuple or None)
    mov rax, [rdi + 40]
    IS_NONE rax, rcx
    jne .have_indexgroup
    xor eax, eax
.have_indexgroup:
    mov [rbp - SC_IGROUP], rax

    ; Convert code list to u32 array
    ; Get list size
    mov r12, [rbp - SC_CODE]   ; code list
    mov r13, [r12 + PyListObject.ob_size]  ; code length
    mov [rbp - SC_CODELEN], r13

    ; Allocate u32 array
    lea rdi, [r13*4]
    call ap_malloc
    mov r14, rax               ; r14 = u32* code buffer
    mov [rbp - SC_CODEBUF], r14

    ; Iterate the code list, taking the low 32 bits of each integer.
    ;
    ; "Is it an integer?" and "what is its value?" are two questions, and
    ; asking only the first used to be enough here because every entry was an
    ; int immediate.  It is not: a compiled pattern carries 4294967295 --
    ; MAXREPEAT -- which arithmetic in re._compiler can hand back GMP-backed,
    ; and a _NamedIntConstant is an int subclass besides.  int_unwrap
    ; flattens the compact forms but leaves a GMP-backed one as a pointer, so
    ; testing its tag rejected a perfectly good integer.  `make INT_STRESS=1`
    ; is what surfaced it: every value of eight or more is on the heap there.
    mov r15, [r12 + PyListObject.ob_item]       ; payloads
    xor ecx, ecx               ; index
.code_loop:
    cmp rcx, r13
    jge .code_done
    extern int_unwrap
    mov rdi, [r15 + rcx*8]
    V_UNPACK rdi, rdx
    push rcx
    call int_unwrap            ; bool, a compact heap int and an int subclass
                               ; all flatten to a value here
    cmp edx, TAG_SMALLINT
    je .code_have_value
    ; Still a pointer: a GMP-backed int is an integer too, and taking the tag
    ; as the answer rejected one.
    push rdx
    push rdi
    sub rsp, 8
    extern int_is_integer
    call int_is_integer
    add rsp, 8
    pop rdi
    pop rdx
    test eax, eax
    jz .code_type_error_pop
    extern int_to_i64
    call int_to_i64
    mov rdi, rax
.code_have_value:
    pop rcx
    mov eax, edi
    mov [r14 + rcx*4], eax     ; the low 32 bits, as the engine reads them
    inc rcx
    jmp .code_loop

.code_type_error_pop:
    pop rcx
.code_type_error:
    ; Non-int element in code list — raise TypeError
    mov rdi, r14               ; free code buffer
    call ap_free
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sm_code_type_err]
    extern set_exception
    call set_exception
    jmp .compile_fail
.code_done:

    ; Allocate SRE_PatternObject
    mov edi, SRE_PatternObject_size
    call ap_malloc
    mov rbx, rax               ; rbx = pattern object

    ; Initialize
    mov qword [rbx + PyObject.ob_refcnt], 1
    lea rax, [rel sre_pattern_type]
    mov [rbx + PyObject.ob_type], rax

    ; Set fields
    mov rax, [rbp - SC_PATTERN]
    mov [rbx + SRE_PatternObject.pattern], rax
    inc qword [rax + PyObject.ob_refcnt]  ; INCREF pattern string

    mov rax, [rbp - SC_FLAGS]
    mov [rbx + SRE_PatternObject.flags], eax

    mov rax, [rbp - SC_GROUPS]
    mov [rbx + SRE_PatternObject.groups], eax

    mov rax, [rbp - SC_GINDEX]
    mov [rbx + SRE_PatternObject.groupindex], rax
    test rax, rax
    jz .no_gi_incref
    inc qword [rax + PyObject.ob_refcnt]
.no_gi_incref:

    mov rax, [rbp - SC_IGROUP]
    mov [rbx + SRE_PatternObject.indexgroup], rax
    test rax, rax
    jz .no_ig_incref
    inc qword [rax + PyObject.ob_refcnt]
.no_ig_incref:

    mov [rbx + SRE_PatternObject.code], r14
    mov [rbx + SRE_PatternObject.code_len], r13

    ; A pattern compiled from BYTES matches bytes-like subjects and answers
    ; bytes.  The engine is the same either way -- bytes are byte-indexed,
    ; which is the ASCII path it already has -- so all this records is which
    ; kind was asked for.
    mov qword [rbx + SRE_PatternObject.is_bytes], 0
    mov rax, [rbp - SC_PATTERN]
    V_TEST_PTR rax, rcx
    ja .pattern_kind_done
    test rax, rax
    jz .pattern_kind_done
    mov rcx, [rax + PyObject.ob_type]
    extern bytes_type
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    je .pattern_is_bytes
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_BYTES_SUBCLASS
    jz .pattern_kind_done
.pattern_is_bytes:
    mov qword [rbx + SRE_PatternObject.is_bytes], 1
.pattern_kind_done:

    ; Return pattern object
    mov rax, rbx
    mov edx, TAG_PTR

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.compile_error_args:
    FAIL exc_TypeError_type, "_sre.compile() requires 6 arguments", .compile_fail

.compile_too_many:
    ; Nothing is held yet, so this one returns: the count is in the message,
    ; as CPython's is.
    CSTRING rdi, "compile() takes at most 6 arguments ("
    mov rsi, [rbp - SC_NARGS]
    CSTRING rdx, " given)"
    extern set_type_error_counted
    call set_type_error_counted ; rax = 0
.compile_fail:
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sre_compile_func

;; ============================================================================
;; sre_ascii_iscased_func(PyObject **args, int64_t nargs) -> (rax, edx)
;; ============================================================================
DEF_FUNC sre_ascii_iscased_func
    cmp rsi, 1
    jne .aic_error
    mov rax, [rdi]              ; char value (SmallInt payload)
    ; A-Z or a-z?
    cmp eax, 'A'
    jb .aic_false
    cmp eax, 'Z'
    jbe .aic_true
    cmp eax, 'a'
    jb .aic_false
    cmp eax, 'z'
    jbe .aic_true
.aic_false:
    xor eax, eax
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.aic_true:
    mov eax, 1
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.aic_error:
    SET_EXC exc_TypeError_type, "ascii_iscased() takes 1 argument"
    leave
    ret
END_FUNC sre_ascii_iscased_func

;; ============================================================================
;; sre_ascii_tolower_func(PyObject **args, int64_t nargs) -> (rax, edx)
;; ============================================================================
DEF_FUNC sre_ascii_tolower_func
    cmp rsi, 1
    jne .atl_error
    mov eax, [rdi]              ; char value
    cmp eax, 'A'
    jb .atl_done
    cmp eax, 'Z'
    ja .atl_done
    add eax, 32
.atl_done:
    RET_TAG_SMALLINT
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.atl_error:
    SET_EXC exc_TypeError_type, "ascii_tolower() takes 1 argument"
    leave
    ret
END_FUNC sre_ascii_tolower_func

;; ============================================================================
;; sre_unicode_iscased_func(PyObject **args, int64_t nargs) -> (rax, edx)
;; ============================================================================
DEF_FUNC sre_unicode_iscased_func
    cmp rsi, 1
    jne .uic_error
    mov eax, [rdi]
    ; Check if char has a case mapping
    cmp eax, 'A'
    jb .uic_check_ext
    cmp eax, 'Z'
    jbe .uic_true
    cmp eax, 'a'
    jb .uic_check_ext
    cmp eax, 'z'
    jbe .uic_true
.uic_check_ext:
    ; Extended Latin
    cmp eax, 0xc0
    jb .uic_false
    cmp eax, 0xff
    jbe .uic_true
    ; Basic check for common Unicode ranges
    cmp eax, 0x100
    jb .uic_false
    ; Simplified: assume cased if in Latin Extended or other letter ranges
    mov eax, 1
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.uic_false:
    xor eax, eax
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.uic_true:
    mov eax, 1
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.uic_error:
    SET_EXC exc_TypeError_type, "unicode_iscased() takes 1 argument"
    leave
    ret
END_FUNC sre_unicode_iscased_func

;; ============================================================================
;; sre_unicode_tolower_func(PyObject **args, int64_t nargs) -> (rax, edx)
;; ============================================================================
DEF_FUNC sre_unicode_tolower_func
    cmp rsi, 1
    jne .utl_error
    mov eax, [rdi]
    cmp eax, 'A'
    jb .utl_done
    cmp eax, 'Z'
    jbe .utl_lower
    cmp eax, 0xc0
    jb .utl_done
    cmp eax, 0xd6
    jbe .utl_lower
    cmp eax, 0xd8
    jb .utl_done
    cmp eax, 0xde
    jbe .utl_lower
    jmp .utl_done
.utl_lower:
    add eax, 32
.utl_done:
    RET_TAG_SMALLINT
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.utl_error:
    SET_EXC exc_TypeError_type, "unicode_tolower() takes 1 argument"
    leave
    ret
END_FUNC sre_unicode_tolower_func

;; ============================================================================
;; sre_getlower_func(PyObject **args, int64_t nargs) -> (rax, edx)
;; _sre.getlower(char, flags) — same as tolower with flag check
;; ============================================================================
DEF_FUNC sre_getlower_func
    cmp rsi, 2
    jne .gl_error
    push rdi
    mov rdi, [rdi]             ; args[0] = char
    call val_to_i64
    pop rdi
    push rax
    mov rdi, [rdi + 8]         ; args[1] = flags
    call val_to_i64
    mov ecx, eax
    pop rax                    ; char
    ; If ASCII flag, use ASCII tolower
    test ecx, SRE_FLAG_ASCII
    jnz .gl_ascii
    ; Default: unicode tolower
    cmp eax, 'A'
    jb .gl_done
    cmp eax, 'Z'
    ja .gl_check_ext
    add eax, 32
    jmp .gl_done
.gl_check_ext:
    cmp eax, 0xc0
    jb .gl_done
    cmp eax, 0xd6
    jbe .gl_do_lower
    cmp eax, 0xd8
    jb .gl_done
    cmp eax, 0xde
    ja .gl_done
.gl_do_lower:
    add eax, 32
    jmp .gl_done
.gl_ascii:
    cmp eax, 'A'
    jb .gl_done
    cmp eax, 'Z'
    ja .gl_done
    add eax, 32
.gl_done:
    RET_TAG_SMALLINT
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.gl_error:
    SET_EXC exc_TypeError_type, "getlower() takes 2 arguments"
    leave
    ret
END_FUNC sre_getlower_func

;; ============================================================================
;; sre_template_func(PyObject **args, int64_t nargs) -> (rax, edx)
;; _sre.template(pattern, template) -> template (passthrough stub)
;; CPython uses this for optimized sub replacement expansion.
;; We return the template list/string as-is; re module handles expansion.
;; ============================================================================
DEF_FUNC sre_template_func
    cmp rsi, 2
    jb .tmpl_error
    ; Return the template argument (args[1]) with INCREF
    mov rax, [rdi + 8]       ; template payload
    V_UNPACK rax, rdx       ; args[1]
    INCREF_VAL rax, rdx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.tmpl_error:
    SET_EXC exc_TypeError_type, "template() requires 2 arguments"
    leave
    ret
END_FUNC sre_template_func

;; ============================================================================
;; sre_getcodesize_func(PyObject **args, int64_t nargs) -> (rax, edx)
;; _sre.getcodesize() -> 4
;; ============================================================================
DEF_FUNC sre_getcodesize_func
    mov eax, SRE_CODESIZE
    RET_TAG_SMALLINT
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC sre_getcodesize_func

;; ============================================================================
;; Helper macros for adding entries to module dict
;; r12 = dict, preserved across calls
;; ============================================================================

; SRE_ADD_FUNC func_impl, name_cstr
; Add a builtin function to the module dict

; SRE_ADD_INT name_cstr, value
; Add a SmallInt constant to the module dict
%macro SRE_ADD_INT 2
    lea rdi, [rel %1]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, %2
    V_PACK_I64 rdx, rcx      ; dict_set takes Values
    call dict_set
    pop rdi
    call obj_decref
%endmacro

; SRE_ADD_STR key_cstr, val_cstr
; Add a string constant to the module dict
%macro SRE_ADD_STR 2
    lea rdi, [rel %1]
    call str_from_cstr_heap
    push rax
    lea rdi, [rel %2]
    call str_from_cstr_heap
    mov rdx, rax
    mov rdi, r12
    pop rsi
    push rdx
    push rsi
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref
%endmacro

;; ============================================================================
;; sre_module_create() -> PyObject*
;; Creates and returns the _sre module with all functions and constants.
;; ============================================================================
SMC_FRAME   equ 8           ; + 3 pushes = 32

DEF_FUNC sre_module_create, SMC_FRAME
    push rbx
    push r12
    push r13

    ; Create module dict
    call dict_new
    mov r12, rax               ; r12 = module dict

    ; Functions
    MODULE_ADD_FUNC sre_compile_func,        sm_compile_name
    MODULE_ADD_FUNC sre_ascii_iscased_func,  sm_ascii_iscased
    MODULE_ADD_FUNC sre_ascii_tolower_func,  sm_ascii_tolower
    MODULE_ADD_FUNC sre_unicode_iscased_func, sm_unicode_iscased
    MODULE_ADD_FUNC sre_unicode_tolower_func, sm_unicode_tolower
    MODULE_ADD_FUNC sre_getlower_func,       sm_getlower
    MODULE_ADD_FUNC sre_getcodesize_func,    sm_getcodesize
    MODULE_ADD_FUNC sre_template_func,       sm_template

    ; Integer constants
    SRE_ADD_INT sm_MAGIC,     SRE_MAGIC
    SRE_ADD_INT sm_CODESIZE,  SRE_CODESIZE
    SRE_ADD_INT sm_MAXREPEAT, SRE_MAXREPEAT
    SRE_ADD_INT sm_MAXGROUPS, SRE_MAXGROUPS

    ; String constants
    SRE_ADD_STR sm_copyright, sm_copyright_val

    ; Create module object
    lea rdi, [rel sm_sre_name]
    call str_from_cstr_heap
    push rax                    ; save name for DECREF
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov r13, rax                ; save module
    pop rdi                     ; name string
    call obj_decref
    ; DECREF the dict — module_new INCREF'd it, so our original ref is extra
    mov rdi, r12
    call obj_decref
    mov rax, r13                ; restore module

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sre_module_create

;; ============================================================================
;; Data
;; ============================================================================
section .rodata

sm_sre_name:        db "_sre", 0
sm_compile_name:    db "compile", 0
sm_ascii_iscased:   db "ascii_iscased", 0
sm_ascii_tolower:   db "ascii_tolower", 0
sm_unicode_iscased: db "unicode_iscased", 0
sm_unicode_tolower: db "unicode_tolower", 0
sm_getlower:        db "getlower", 0
sm_getcodesize:     db "getcodesize", 0

sm_template:        db "template", 0
sm_MAGIC:           db "MAGIC", 0
sm_CODESIZE:        db "CODESIZE", 0
sm_MAXREPEAT:       db "MAXREPEAT", 0
sm_MAXGROUPS:       db "MAXGROUPS", 0
sm_copyright:       db "copyright", 0
sm_copyright_val:   db "_sre for apython", 0
sm_code_type_err:   db "expected int in code list", 0
