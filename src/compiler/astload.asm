; compiler/astload.asm - compile() of an AST object
;
; astraw.asm's inverse.  compile(tree, filename, mode) hands lib/_ast_load.py
; the node objects, which checks them the way CPython's validator does and
; folds them back into the raw twelve-tuples astraw.asm's header describes:
;
;   (kind, subkind, lineno, col, end_lineno, end_col, a, b, c, children,
;    type_params, type_comment)
;
; This walks those tuples and rebuilds the parse arena from them -- nodes,
; spans, child lists, objects and the type-parameter side table -- so that
; compile_source can run the rest of its pipeline over the result exactly as
; it does once its own parser has finished.  Symbol table, code generator and
; assembler cannot tell which front end built the arena, and that is the
; point: there is one compiler, and the tree is only a second way into it.
;
; The split is the one astraw.asm makes, for the same reason.  Everything
; about the SHAPE of the tree -- else-tails as blocks, decorators on a
; wrapper, the flat parameter list, private-name mangling, PEP 563's text --
; is list surgery and is done in Python.  What is left here is mechanical:
; ar_fieldkinds, the table astraw.asm reads a node by, says how to write one.
;
; Nodes are made children first, as the parser makes them, so a parent's
; index is always above its children's.

%include "macros.inc"
%include "object.inc"
%include "value.inc"
%include "compiler.inc"

extern ast_make
extern ast_at
extern ast_span_at
extern ast_mark
extern ast_push
extern ast_commit
extern ast_obj
extern ast_set_typeparams
extern ar_fieldkinds
extern comp_intern
extern comp_intern_forced
extern comp_error
extern comp_inherit_future
extern compile_source_ex
extern tuple_type
extern list_type
extern str_type
extern none_singleton
extern bool_true
extern exc_ValueError_type
extern obj_call_n
extern obj_decref
extern obj_dealloc
extern import_module
extern dict_get
extern str_from_cstr_heap
extern int_from_i64

;; ar_fieldkinds' codes, as astraw.asm defines them.
AF_NONE equ 0
AF_NODE equ 1
AF_OBJ  equ 2
AF_INT  equ 3
AC_NONE equ 0
AC_NODE equ 1
AC_OBJ  equ 2
AC_PAIR equ 3
AC_ONE  equ 4

;; How al_obj interns a string.
ALO_IDENT equ 0             ; an identifier: always interned; None is absent
ALO_CONST equ 1             ; a constant: interned when it looks like a name,
                            ; and None is the None constant, not absence

RAW_SIZE equ 12

section .text

;; ============================================================================
;; al_obj(rdi = Comp*, rsi = a Value, edx = ALO_*) -> rax = obj index; 0 for an
;; absent identifier; -1 on failure
;;
;; A string is re-interned the way the parser would have interned it.  The
;; identity matters: op_load_attr_instance guards its cache by the identity of
;; the attribute name, so a name the tree built fresh would miss on every
;; execution -- compile.asm's comp_intern header has the history.
;; ============================================================================
ALO_COMP  equ 8
ALO_VAL   equ 16
ALO_MODE  equ 24
ALO_FRAME equ 32            ; + 0 pushes
DEF_FUNC_LOCAL al_obj, ALO_FRAME
    mov [rbp - ALO_COMP], rdi
    mov [rbp - ALO_VAL], rsi
    mov [rbp - ALO_MODE], rdx

    lea rax, [rel none_singleton]
    cmp rsi, rax
    jne .alo_present
    cmp edx, ALO_IDENT
    je .alo_absent
.alo_present:
    V_TEST_PTR rsi, rax
    ja .alo_keep                ; an int or float immediate
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .alo_keep
    lea rdi, [rsi + PyStrObject.data]
    mov rsi, [rsi + PyStrObject.ob_size]
    cmp qword [rbp - ALO_MODE], ALO_CONST
    je .alo_const_str
    call comp_intern_forced
    jmp .alo_have_str
.alo_const_str:
    call comp_intern
.alo_have_str:
    test rax, rax
    jz .alo_fail
    mov rsi, rax                ; owned: ast_obj takes it
    jmp .alo_store

.alo_keep:
    mov rsi, [rbp - ALO_VAL]
    INCREF_V rsi, rax           ; the arena owns what it holds
.alo_store:
    mov rdi, [rbp - ALO_COMP]
    call ast_obj
    leave
    ret

.alo_absent:
    xor eax, eax
    leave
    ret
.alo_fail:
    mov rax, -1
    leave
    ret
END_FUNC al_obj

;; ============================================================================
;; al_field(rdi = Comp*, rsi = a Value, edx = an AF_* code, ecx = ALO_* for an
;; object field) -> rax = the u32 the node stores, or -1 on failure
;; ============================================================================
DEF_FUNC_LOCAL al_field
    cmp edx, AF_NODE
    je .alf_node
    cmp edx, AF_OBJ
    je .alf_obj
    cmp edx, AF_INT
    je .alf_int
    xor eax, eax                ; AF_NONE: not a field
    leave
    ret
.alf_node:
    call al_node
    leave
    ret
.alf_obj:
    mov edx, ecx
    call al_obj
    leave
    ret
.alf_int:
    lea rax, [rel none_singleton]
    cmp rsi, rax
    je .alf_zero
    V_IS_INT rsi, rax
    jb .alf_fail
    mov rax, rsi
    V_TO_I64 rax
    mov eax, eax                ; the u32 the field holds
    leave
    ret
.alf_zero:
    xor eax, eax
    leave
    ret
.alf_fail:
    mov rax, -1
    leave
    ret
END_FUNC al_field

;; AL_INT dest, m64, fail -- the int immediate in a raw tuple slot, as an
;; int64; a jump to `fail` when the slot holds anything else.  rdx is the
;; scratch, so dest may be any other register.
%macro AL_INT 3                 ; %1 = dest, %2 = source m64, %3 = fail label
    mov %1, %2
    V_IS_INT %1, rdx
    jb %3
    V_TO_I64 %1
%endmacro

;; ============================================================================
;; al_node(rdi = Comp*, rsi = a raw node Value) -> rax = the node index, 0 for
;; None, -1 on failure
;;
;; Recursion is bounded by the depth of the tree _ast_load.py already walked
;; in Python, under Python's own recursion limit.
;; ============================================================================
ALN_KIND   equ 8
ALN_SUB    equ 16
ALN_POS    equ 24
ALN_A      equ 32
ALN_B      equ 40
ALN_C      equ 48
ALN_CLIST  equ 56
ALN_NCHILD equ 64
ALN_TP     equ 72
ALN_MARK   equ 80
ALN_I      equ 88
ALN_N      equ 96
ALN_LIST   equ 104
ALN_CHCODE equ 112
ALN_ELINE  equ 120
ALN_ECOL   equ 128
ALN_IDX    equ 136
ALN_CONST  equ 144
ALN_FRAME  equ 144          ; + 2 pushes = 160, 16-aligned
DEF_FUNC_LOCAL al_node, ALN_FRAME
    push rbx
    push r12
    mov rbx, rdi                ; rbx = Comp*

    lea rax, [rel none_singleton]
    cmp rsi, rax
    je .aln_none
    V_TEST_PTR rsi, rax
    ja .aln_fail
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    jne .aln_fail
    cmp qword [rsi + PyTupleObject.ob_size], RAW_SIZE
    jne .aln_fail
    mov r12, [rsi + PyTupleObject.ob_item]     ; stable: a tuple never moves
                                               ; its items, and the caller
                                               ; holds the tree

    ; The kind, and the kinds no statement or expression may be: the gaps in
    ; the numbering, and the roots, which only al_root places.
    AL_INT rax, [r12], .aln_fail
    cmp rax, 1
    jl .aln_fail
    cmp rax, AST_COUNT
    ja .aln_fail
    cmp rax, AST_COMPREHENSION
    jbe .aln_kind_ok
    cmp rax, AST_MODULE
    jb .aln_fail
    cmp rax, AST_EXPRESSION
    je .aln_fail
    cmp rax, AST_INTERACTIVE
    je .aln_fail
    cmp rax, AST_FUNCTIONTYPE
    je .aln_fail
.aln_kind_ok:
    mov [rbp - ALN_KIND], rax
    xor ecx, ecx
    cmp rax, AST_CONST
    sete cl
    mov [rbp - ALN_CONST], rcx

    AL_INT rax, [r12 + 8], .aln_fail
    mov [rbp - ALN_SUB], rax
    ; The line low and the column high, as ast_make takes them.
    AL_INT rax, [r12 + 16], .aln_fail
    mov eax, eax
    AL_INT rcx, [r12 + 24], .aln_fail
    shl rcx, 32
    or rax, rcx
    mov [rbp - ALN_POS], rax
    AL_INT rax, [r12 + 32], .aln_fail
    mov [rbp - ALN_ELINE], rax
    AL_INT rax, [r12 + 40], .aln_fail
    mov [rbp - ALN_ECOL], rax

    ; a, b and c, each the way this kind's row in ar_fieldkinds says.
    lea rcx, [rel ar_fieldkinds]
    mov rax, [rbp - ALN_KIND]
    movzx edx, byte [rcx + rax*4]
    mov rsi, [r12 + 48]
    mov rdi, rbx
    mov rcx, [rbp - ALN_CONST]
    call al_field
    cmp rax, -1
    je .aln_fail
    mov [rbp - ALN_A], rax

    lea rcx, [rel ar_fieldkinds]
    mov rax, [rbp - ALN_KIND]
    movzx edx, byte [rcx + rax*4 + 1]
    mov rsi, [r12 + 56]
    mov rdi, rbx
    mov ecx, ALO_IDENT
    call al_field
    cmp rax, -1
    je .aln_fail
    mov [rbp - ALN_B], rax

    lea rcx, [rel ar_fieldkinds]
    mov rax, [rbp - ALN_KIND]
    movzx edx, byte [rcx + rax*4 + 2]
    mov rsi, [r12 + 64]
    mov rdi, rbx
    mov ecx, ALO_IDENT
    call al_field
    cmp rax, -1
    je .aln_fail
    mov [rbp - ALN_C], rax

    ; The child list.
    mov qword [rbp - ALN_CLIST], 0
    mov qword [rbp - ALN_NCHILD], 0
    lea rcx, [rel ar_fieldkinds]
    mov rax, [rbp - ALN_KIND]
    movzx eax, byte [rcx + rax*4 + 3]
    mov [rbp - ALN_CHCODE], rax
    cmp eax, AC_NONE
    je .aln_tp
    mov rsi, [r12 + 72]
    cmp eax, AC_ONE
    jne .aln_list
    ; `for`'s else block: .clist is a node index and nchild stays 0.
    mov rdi, rbx
    call al_node
    cmp rax, -1
    je .aln_fail
    mov [rbp - ALN_CLIST], rax
    jmp .aln_tp

.aln_list:
    lea rax, [rel none_singleton]
    cmp rsi, rax
    je .aln_tp
    V_TEST_PTR rsi, rax
    ja .aln_fail
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    jne .aln_fail
    mov [rbp - ALN_LIST], rsi
    mov rax, [rsi + PyListObject.ob_size]
    mov [rbp - ALN_N], rax
    mov rdi, rbx
    call ast_mark
    mov [rbp - ALN_MARK], rax
    mov qword [rbp - ALN_I], 0
.aln_loop:
    mov rcx, [rbp - ALN_I]
    cmp rcx, [rbp - ALN_N]
    jae .aln_commit
    ; Re-read the items every time: nothing here runs Python code, but the
    ; list's storage is the list's to move.
    mov rax, [rbp - ALN_LIST]
    mov rax, [rax + PyListObject.ob_item]
    mov rsi, [rax + rcx*8]
    mov rax, [rbp - ALN_CHCODE]
    cmp eax, AC_OBJ
    je .aln_ch_obj
    cmp eax, AC_PAIR
    jne .aln_ch_node
    test ecx, 1
    jnz .aln_ch_node
    ; A compare's operator: the raw int itself goes in the child list.
    mov rax, rsi
    V_IS_INT rax, rdx
    jb .aln_fail
    V_TO_I64 rax
    jmp .aln_ch_push
.aln_ch_obj:
    mov rdi, rbx
    mov edx, ALO_IDENT
    call al_obj
    jmp .aln_ch_check
.aln_ch_node:
    mov rdi, rbx
    call al_node
.aln_ch_check:
    cmp rax, -1
    je .aln_fail
.aln_ch_push:
    mov rdi, rbx
    mov esi, eax
    call ast_push
    inc qword [rbp - ALN_I]
    jmp .aln_loop
.aln_commit:
    mov rdi, rbx
    mov rsi, [rbp - ALN_MARK]
    call ast_commit
    mov [rbp - ALN_CLIST], rax
    cmp qword [rbp - ALN_CHCODE], AC_PAIR
    jne .aln_have_n
    shr rdx, 1                  ; nchild counts the (operator, operand) pairs
.aln_have_n:
    mov [rbp - ALN_NCHILD], rdx

.aln_tp:
    ; PEP 695's parameters, which ride in a side table rather than a field.
    mov rdi, rbx
    mov rsi, [r12 + 80]
    call al_node
    cmp rax, -1
    je .aln_fail
    mov [rbp - ALN_TP], rax

    ; The node itself, last, as the parser makes it.
    mov rdi, rbx
    mov rsi, [rbp - ALN_KIND]
    mov rdx, [rbp - ALN_SUB]
    mov rcx, [rbp - ALN_POS]
    mov r8, [rbp - ALN_A]
    mov r9, [rbp - ALN_B]
    call ast_make
    mov [rbp - ALN_IDX], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rcx, [rbp - ALN_C]
    mov [rax + AstNode.c], ecx
    mov rcx, [rbp - ALN_CLIST]
    mov [rax + AstNode.clist], ecx
    mov rcx, [rbp - ALN_NCHILD]
    mov [rax + AstNode.nchild], ecx
    ; Where it ends.  ast_make took the span from the token cursor, and there
    ; are no tokens: the tree's own end is the answer.
    mov rdi, rbx
    mov rsi, [rbp - ALN_IDX]
    call ast_span_at
    test rax, rax
    jz .aln_no_span
    mov rcx, [rbp - ALN_ELINE]
    mov [rax + AstSpan.end_lineno], ecx
    mov rcx, [rbp - ALN_ECOL]
    mov [rax + AstSpan.end_col], ecx
.aln_no_span:
    cmp qword [rbp - ALN_TP], 0
    je .aln_done
    mov rdi, rbx
    mov rsi, [rbp - ALN_IDX]
    mov rdx, [rbp - ALN_TP]
    call ast_set_typeparams
.aln_done:
    mov rax, [rbp - ALN_IDX]
    pop r12
    pop rbx
    leave
    ret

.aln_none:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
.aln_fail:
    mov rax, -1
    pop r12
    pop rbx
    leave
    ret
END_FUNC al_node

;; ============================================================================
;; al_root(rdi = Comp*, rsi = the raw tree) -> rax = the root node index, or
;; 0 with an error recorded
;;
;; What compile_source calls in place of the lexer and the parser.  The raw
;; root is what the parser's own would have been: a MODULE for "exec" and
;; "single", the bare expression for "eval".  _ast_load.py is what checks the
;; mode against the node type; a malformed raw tree here is a bug there, and
;; it is reported rather than compiled.
;; ============================================================================
ALR_COMP  equ 8
ALR_FRAME equ 16            ; + 0 pushes
global al_root
DEF_FUNC al_root, ALR_FRAME
    mov [rbp - ALR_COMP], rdi
    call al_node
    cmp rax, -1
    je .alr_bad
    test rax, rax
    jz .alr_bad
    leave
    ret
.alr_bad:
    mov rdi, [rbp - ALR_COMP]
    lea rsi, [rel exc_ValueError_type]
    CSTRING rdx, "compile(): malformed AST"
    xor ecx, ecx
    xor r8d, r8d
    call comp_error
    xor eax, eax
    leave
    ret
END_FUNC al_root

section .data
al_prep_cache: dq 0
section .rodata
al_mod_name:  db "_ast_load", 0
al_attr_name: db "_compile_prep", 0
al_empty_src: db 0
section .text

;; ============================================================================
;; al_prep_fn() -> rax = _ast_load._compile_prep, borrowed, or 0 with an
;; exception pending
;;
;; Looked up lazily and cached for the life of the process, as compile.asm's
;; co_ast_builder caches _ast._from_raw.
;; ============================================================================
ALP_KEY   equ 8
ALP_MOD   equ 16
ALP_FRAME equ 16            ; + 0 pushes
DEF_FUNC_LOCAL al_prep_fn, ALP_FRAME
    mov rax, [rel al_prep_cache]
    test rax, rax
    jnz .alp_out

    lea rdi, [rel al_mod_name]
    call str_from_cstr_heap
    mov [rbp - ALP_KEY], rax
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call import_module
    mov [rbp - ALP_MOD], rax
    mov rdi, [rbp - ALP_KEY]
    call obj_decref
    mov rax, [rbp - ALP_MOD]
    test rax, rax
    jz .alp_fail

    lea rdi, [rel al_attr_name]
    call str_from_cstr_heap
    mov [rbp - ALP_KEY], rax
    mov rdi, [rbp - ALP_MOD]
    mov rdi, [rdi + PyModuleObject.mod_dict]
    mov rsi, rax
    call dict_get
    push rax
    push rax                    ; twice: keeps rsp 16-aligned for the calls
    mov rdi, [rbp - ALP_KEY]
    call obj_decref
    mov rdi, [rbp - ALP_MOD]
    call obj_decref             ; sys.modules keeps the module alive
    pop rax
    pop rax
    test rax, rax
    jz .alp_fail
    V_TEST_PTR rax, rcx
    ja .alp_fail
    INCREF rax                  ; the cache's own, for the process's life
    mov [rel al_prep_cache], rax
.alp_out:
    leave
    ret
.alp_fail:
    xor eax, eax
    leave
    ret
END_FUNC al_prep_fn

;; ============================================================================
;; compile_ast_input(rdi = the source object, rsi = filename, rdx = the mode
;;                   string, rcx = CMODE_*, r8 = flags)
;;   -> rax = a code object, the tree itself under PyCF_ONLY_AST, or 0 with
;;      the exception pending
;;
;; builtin_compile_fn's answer for a source that is neither str nor bytes.
;; _ast_load._compile_prep decides what it is: not an AST at all (the
;; TypeError compile() has always raised), the tree to hand straight back, or
;; a (raw tree, future-annotations) pair to compile.
;;
;; PEP 563 is the one future the tree itself can turn on, and CPython reads it
;; from the tree's own leading imports as well as inheriting it from the
;; caller; comp_inherit_future is the channel compile_source already reads
;; the inherited half from, so the tree's half goes in the same way.  Every
;; path that does not compile clears it, since it is consumed only by a
;; compile.
;; ============================================================================
CAI_SRC    equ 8
CAI_FILE   equ 16
CAI_MODE   equ 24
CAI_CMODE  equ 32
CAI_FLAGS  equ 40
CAI_ARGS   equ 64           ; three Values, at -64, -56 and -48
CAI_RES    equ 72
CAI_FN     equ 80
CAI_FRAME  equ 80           ; + 0 pushes
global compile_ast_input
DEF_FUNC compile_ast_input, CAI_FRAME
    mov [rbp - CAI_SRC], rdi
    mov [rbp - CAI_FILE], rsi
    mov [rbp - CAI_MODE], rdx
    mov [rbp - CAI_CMODE], rcx
    mov [rbp - CAI_FLAGS], r8

    call al_prep_fn
    test rax, rax
    jz .cai_fail
    mov [rbp - CAI_FN], rax

    mov rax, [rbp - CAI_SRC]
    mov [rbp - CAI_ARGS], rax
    mov rax, [rbp - CAI_MODE]
    mov [rbp - CAI_ARGS + 8], rax
    mov rdi, [rbp - CAI_FLAGS]
    call int_from_i64
    V_PACK rax, rdx
    mov [rbp - CAI_ARGS + 16], rax

    mov rdi, [rbp - CAI_FN]
    lea rsi, [rbp - CAI_ARGS]
    mov edx, 3
    call obj_call_n
    mov [rbp - CAI_RES], rax
    mov rdi, [rbp - CAI_ARGS + 16]
    DECREF_V rdi, rcx           ; the flags, ours
    mov rax, [rbp - CAI_RES]
    test rax, rax
    jz .cai_fail

    ; A pair is something to compile; anything else is the answer.
    V_TEST_PTR rax, rcx
    ja .cai_hand_back
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    jne .cai_hand_back
    cmp qword [rax + PyTupleObject.ob_size], 2
    jne .cai_hand_back

    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rcx + 8]
    lea rsi, [rel bool_true]
    cmp rdx, rsi
    jne .cai_no_future
    mov qword [rel comp_inherit_future], 1
.cai_no_future:
    mov r8, [rcx]               ; the raw tree, borrowed: the pair holds it
    lea rdi, [rel al_empty_src]
    xor esi, esi
    mov rdx, [rbp - CAI_FILE]
    mov rcx, [rbp - CAI_CMODE]
    call compile_source_ex
    mov [rbp - CAI_FN], rax     ; the code object; the cache keeps the function
    mov rdi, [rbp - CAI_RES]
    call obj_decref
    mov rax, [rbp - CAI_FN]
    leave
    ret

.cai_hand_back:
    mov qword [rel comp_inherit_future], 0
    mov rax, [rbp - CAI_RES]    ; owned, and now the caller's
    leave
    ret

.cai_fail:
    mov qword [rel comp_inherit_future], 0
    xor eax, eax
    leave
    ret
END_FUNC compile_ast_input
