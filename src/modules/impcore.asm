; impcore.asm - the `_impcore` module: what lib/_imp.py cannot say in Python
;
; CPython's importlib runs the import system, and lib/_imp.py is the C module
; it is written against.  Two of _imp's functions need the interpreter's own
; hands:
;
;   create_builtin(name)        a builtin module, made WITHOUT importlib.
;       BuiltinImporter.create_module ends here, and the import statement
;       ends in importlib -- so if this went through `__import__` the two
;       would call each other forever.  It goes to the interpreter's own
;       loader instead, which knows the module table and the stand-ins in
;       lib/ that sys.builtin_module_names lists beside it.
;
;   fix_co_filename(code, path) CPython's _imp._fix_co_filename.  A .pyc
;       records the path it was compiled from; when the source has since
;       moved -- or was compiled under a relative name, as `make` compiles
;       stdlib/ -- the loader rewrites co_filename in place, through every
;       nested code object, so tracebacks name the file where it is.  Code
;       objects are immutable to Python, so this cannot be Python.

%include "macros.inc"
%include "object.inc"
%include "value.inc"

extern dict_new
extern module_new
extern obj_decref
extern str_from_cstr_heap
extern str_type
extern code_type
extern tuple_type
extern none_singleton
extern builtin_func_new
extern dict_set
extern ap_memcmp
extern raise_exception
extern exc_TypeError_type
extern exc_ImportError_type
extern import_find_and_load_asm
extern current_exception
extern eval_exception_unwind

section .text

;; ============================================================================
;; impcore_create_builtin(args, nargs) -> the module, a new reference
;;
;; One argument, the module's name.  The interpreter's own loader finds it in
;; the module table or among the lib/ stand-ins; an exception its body raises
;; propagates, and a name it cannot find is an ImportError.
;; ============================================================================
ICB_NAME  equ 8
ICB_EXC   equ 16
ICB_FRAME equ 16
DEF_FUNC impcore_create_builtin, ICB_FRAME
    cmp rsi, 1
    jne .icb_arity
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .icb_type
    test rdi, rdi
    jz .icb_type
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .icb_type
    mov [rbp - ICB_NAME], rdi
    DUNDER_EXC_SAVE [rbp - ICB_EXC]
    call import_find_and_load_asm
    test rax, rax
    jz .icb_failed
    leave
    ret
.icb_failed:
    DUNDER_RAISED [rbp - ICB_EXC], .icb_propagate
    RAISE exc_ImportError_type, "no built-in module by that name"
.icb_propagate:
    jmp eval_exception_unwind
.icb_arity:
    RAISE exc_TypeError_type, "create_builtin() takes exactly one argument"
.icb_type:
    RAISE exc_TypeError_type, "create_builtin() argument must be str"
END_FUNC impcore_create_builtin

;; ============================================================================
;; icf_str_eq(rdi = str, rsi = str) -> eax = 1 when equal, else 0
;; ============================================================================
DEF_FUNC_LOCAL icf_str_eq
    cmp rdi, rsi
    je .ise_yes
    test rdi, rdi
    jz .ise_no
    test rsi, rsi
    jz .ise_no
    mov rdx, [rdi + PyStrObject.ob_size]
    cmp rdx, [rsi + PyStrObject.ob_size]
    jne .ise_no
    lea rdi, [rdi + PyStrObject.data]
    lea rsi, [rsi + PyStrObject.data]
    call ap_memcmp
    test eax, eax
    jnz .ise_no
.ise_yes:
    mov eax, 1
    leave
    ret
.ise_no:
    xor eax, eax
    leave
    ret
END_FUNC icf_str_eq

;; ============================================================================
;; icf_update(rdi = code, rsi = old name, rdx = new name) -> nothing
;;
;; CPython's update_code_filenames: a code object whose co_filename is the
;; old name gets the new one, and so does every code object among its
;; constants, recursively.  One that already has another name is left alone,
;; and so is everything under it.
;; ============================================================================
ICU_CODE  equ 8
ICU_OLD   equ 16
ICU_NEW   equ 24
ICU_I     equ 32
ICU_FRAME equ 32
DEF_FUNC_LOCAL icf_update, ICU_FRAME
    mov [rbp - ICU_CODE], rdi
    mov [rbp - ICU_OLD], rsi
    mov [rbp - ICU_NEW], rdx
    mov rdi, [rdi + PyCodeObject.co_filename]
    call icf_str_eq
    test eax, eax
    jz .icu_out

    mov rcx, [rbp - ICU_CODE]
    mov rax, [rbp - ICU_NEW]
    INCREF rax
    mov rdi, [rcx + PyCodeObject.co_filename]
    mov [rcx + PyCodeObject.co_filename], rax
    call obj_decref

    mov qword [rbp - ICU_I], 0
.icu_const:
    mov rcx, [rbp - ICU_CODE]
    mov rcx, [rcx + PyCodeObject.co_consts]
    test rcx, rcx
    jz .icu_out
    mov rax, [rbp - ICU_I]
    cmp rax, [rcx + PyTupleObject.ob_size]
    jae .icu_out
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov rdi, [rcx + rax * 8]
    inc qword [rbp - ICU_I]
    V_TEST_PTR rdi, rax
    ja .icu_const
    test rdi, rdi
    jz .icu_const
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel code_type]
    cmp rax, rcx
    jne .icu_const
    mov rsi, [rbp - ICU_OLD]
    mov rdx, [rbp - ICU_NEW]
    call icf_update
    jmp .icu_const
.icu_out:
    leave
    ret
END_FUNC icf_update

;; ============================================================================
;; impcore_fix_co_filename(args, nargs) -> None
;;
;; (code, path).  Nothing happens when the code already names that path.
;; ============================================================================
IFC_OLD   equ 8
IFC_ARGS  equ 16
IFC_FRAME equ 16
DEF_FUNC impcore_fix_co_filename, IFC_FRAME
    cmp rsi, 2
    jne .ifc_arity
    mov [rbp - IFC_ARGS], rdi
    mov rax, [rdi]
    V_TEST_PTR rax, rcx
    ja .ifc_type
    test rax, rax
    jz .ifc_type
    lea rcx, [rel code_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .ifc_type
    mov rsi, [rdi + 8]
    V_TEST_PTR rsi, rcx
    ja .ifc_type
    test rsi, rsi
    jz .ifc_type
    lea rcx, [rel str_type]
    cmp [rsi + PyObject.ob_type], rcx
    jne .ifc_type

    mov rdi, [rax + PyCodeObject.co_filename]
    call icf_str_eq
    test eax, eax
    jnz .ifc_none

    ; The old name has to outlive the rewrite that drops the code's own
    ; reference to it, since every nested code is compared against it.
    mov rax, [rbp - IFC_ARGS]
    mov rax, [rax]
    mov rsi, [rax + PyCodeObject.co_filename]
    INCREF rsi
    mov [rbp - IFC_OLD], rsi
    mov rdi, rax
    mov rdx, [rbp - IFC_ARGS]
    mov rdx, [rdx + 8]
    call icf_update
    mov rdi, [rbp - IFC_OLD]
    call obj_decref
.ifc_none:
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.ifc_arity:
    RAISE exc_TypeError_type, "_fix_co_filename() takes exactly two arguments"
.ifc_type:
    RAISE exc_TypeError_type, "_fix_co_filename() takes a code object and a str"
END_FUNC impcore_fix_co_filename

;; ============================================================================
;; impcore_module_create() -> rax = the module object
;; ============================================================================
IMC_FRAME equ 16            ; + 2 pushes = 32, 16-aligned
global impcore_module_create
DEF_FUNC impcore_module_create, IMC_FRAME
    push rbx
    push r12
    call dict_new
    mov r12, rax                ; MODULE_ADD_FUNC reads the dict from r12
    MODULE_ADD_FUNC impcore_create_builtin, imc_n_create_builtin
    MODULE_ADD_FUNC impcore_fix_co_filename, imc_n_fix_co_filename

    lea rdi, [rel imc_name]
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, rax
    mov rsi, r12
    call module_new
    push rax
    push rax
    mov rdi, rbx
    call obj_decref
    mov rdi, r12
    call obj_decref
    pop rax
    pop rcx
    pop r12
    pop rbx
    leave
    ret
END_FUNC impcore_module_create

section .rodata
imc_name:               db "_impcore", 0
imc_n_create_builtin:   db "create_builtin", 0
imc_n_fix_co_filename:  db "fix_co_filename", 0
