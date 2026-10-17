; compiler/astraw.asm - the parse tree, as ordinary Python objects
;
; compile(src, name, mode, ast.PyCF_ONLY_AST) has to hand back a tree of
; _ast node objects.  The arena the parser builds cannot BE that tree: nodes
; are 32-byte records addressed by a u32 index, identifiers and constants are
; indices into a second table, and comp_free releases the lot the moment the
; compile ends.
;
; So this walks it once, while it is still there, and produces a tree of
; plain tuples and lists.  lib/_ast_build.py turns those into node objects.
; The split is deliberate: the two shapes disagree in a dozen places -- an
; else-tail is a block node here and a bare list there, decorators hang off a
; wrapper rather than on the def, every parameter is in one flat list -- and
; every one of those is list surgery, which is cheap in Python and expensive
; here.
;
; One raw node is an eleven-tuple:
;
;   (kind, subkind, lineno, col, end_lineno, end_col, a, b, c, children,
;    type_params)
;
; type_params is the PEP 695 list, which a def, a class and a type alias carry
; in a side table rather than a field -- AstNode was full before PEP 695
; existed.  It is None for every other kind.
;
; a, b and c are a nested raw node, a Python object, an int, or None,
; according to the kind; `children` is a list, a single nested node, or None,
; likewise.  The table below is what says which, because nothing in the node
; itself distinguishes a node index from an object index -- both are u32.
;
; A position of -1 means "not recorded".  ast.py treats end_lineno and
; end_col_offset as optional and _ast_build maps -1 to None.

%include "macros.inc"
%include "object.inc"
%include "value.inc"
%include "compiler.inc"

extern ast_at
extern ast_child
extern ast_obj_at
extern ast_span_at
extern tuple_new
extern list_new
extern list_append
extern obj_decref
extern int_from_i64
extern none_singleton
extern obj_dealloc

;; How a u32 field is to be read.
AF_NONE equ 0               ; not a field: emit None
AF_NODE equ 1               ; a node index; 0 is absent
AF_OBJ  equ 2               ; an index into comp.objs; 0 is absent
AF_INT  equ 3               ; the number itself

;; And how .clist / .nchild are to be read.
AC_NONE equ 0               ; no child list: emit None
AC_NODE equ 1               ; nchild node indices
AC_OBJ  equ 2               ; nchild object indices
AC_PAIR equ 3               ; nchild PAIRS of (raw int, node index) -- compare
AC_ONE  equ 4               ; .clist is a single node index, nchild unused

section .text

;; ============================================================================
;; ar_int(rdi = value) -> rax = the Value for it
;; ============================================================================
DEF_FUNC_LOCAL ar_int
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret
END_FUNC ar_int

;; ============================================================================
;; ar_field(rdi = Comp*, esi = the u32 field, edx = an AF_* code)
;;   -> rax = an owned Value
;;
;; The bounds checks are not defensive padding: a wrong row in ar_fieldkinds
;; reads a node index as an object index or the other way round, and the whole
;; point of answering None there is that the mistake shows up as a diff
;; against CPython's ast.dump rather than as a wild pointer.
;; ============================================================================
ARF_COMP  equ 8
ARF_FRAME equ 24            ; + 1 push = 32, 16-byte aligned
DEF_FUNC_LOCAL ar_field, ARF_FRAME
    push rbx
    mov [rbp - ARF_COMP], rdi
    mov ebx, esi

    cmp edx, AF_INT
    je .arf_int
    cmp edx, AF_NODE
    je .arf_node
    cmp edx, AF_OBJ
    je .arf_obj

.arf_none:
    LOAD_NONE rax
    INCREF rax
    pop rbx
    leave
    ret

.arf_int:
    mov edi, ebx
    call ar_int
    pop rbx
    leave
    ret

.arf_node:
    test ebx, ebx
    jz .arf_none
    mov rax, [rbp - ARF_COMP]
    mov rcx, [rax + Comp.nodes + Buf.len]
    cmp rbx, rcx
    jae .arf_none
    mov rdi, rax
    mov esi, ebx
    call ar_node
    pop rbx
    leave
    ret

.arf_obj:
    test ebx, ebx
    jz .arf_none
    mov rax, [rbp - ARF_COMP]
    mov rcx, [rax + Comp.objs + Buf.len]
    cmp rbx, rcx
    jae .arf_none
    ; The name as it was WRITTEN, when private-name mangling rewrote it.  The
    ; compiler wants `_C__x` and this tree wants `__x`, which is what CPython's
    ; carries -- it mangles later, where the class is still in hand.
    mov rdi, rax
    mov esi, ebx
    extern ast_rawname_at
    call ast_rawname_at
    test eax, eax
    jz .arf_obj_have
    mov ebx, eax
.arf_obj_have:
    mov rdi, [rbp - ARF_COMP]
    mov esi, ebx
    call ast_obj_at             ; a BORROWED Value: comp_free releases the table
    INCREF_V rax, rcx
    pop rbx
    leave
    ret
END_FUNC ar_field

;; ============================================================================
;; ar_children(rdi = Comp*, rsi = the node, edx = an AC_* code)
;;   -> rax = an owned Value: a list, a nested node, or None
;; ============================================================================
ARC_COMP  equ 8
ARC_NODE  equ 16
ARC_KIND  equ 24
ARC_LIST  equ 32
ARC_N     equ 40
ARC_I     equ 48
ARC_FRAME equ 56            ; + 1 push = 64, 16-byte aligned
DEF_FUNC_LOCAL ar_children, ARC_FRAME
    push rbx
    mov [rbp - ARC_COMP], rdi
    mov [rbp - ARC_NODE], rsi
    mov [rbp - ARC_KIND], rdx

    cmp edx, AC_NONE
    je .arc_none
    cmp edx, AC_ONE
    je .arc_one

    mov eax, [rsi + AstNode.nchild]
    mov [rbp - ARC_N], rax
    xor edi, edi
    call list_new
    test rax, rax
    jz .arc_none
    mov [rbp - ARC_LIST], rax
    mov qword [rbp - ARC_I], 0

.arc_loop:
    mov rax, [rbp - ARC_I]
    mov rcx, [rbp - ARC_N]
    cmp rax, rcx
    jge .arc_done
    ; AC_PAIR walks two entries at a time: the operator, then the operand.
    cmp qword [rbp - ARC_KIND], AC_PAIR
    je .arc_pair

    mov rdi, [rbp - ARC_COMP]
    mov rsi, [rbp - ARC_NODE]
    mov rdx, rax
    call ast_child
    mov esi, eax
    mov rdi, [rbp - ARC_COMP]
    mov edx, AF_NODE
    cmp qword [rbp - ARC_KIND], AC_OBJ
    jne .arc_have_kind
    mov edx, AF_OBJ
.arc_have_kind:
    call ar_field
    mov rbx, rax
    mov rdi, [rbp - ARC_LIST]
    mov rsi, rax
    call list_append
    mov rdi, rbx
    DECREF_V rdi, rcx           ; the list took its own
    inc qword [rbp - ARC_I]
    jmp .arc_loop

.arc_pair:
    ; The operator, as a plain int.
    mov rdi, [rbp - ARC_COMP]
    mov rsi, [rbp - ARC_NODE]
    mov rdx, rax
    shl rdx, 1
    call ast_child
    mov edi, eax
    call ar_int
    mov rbx, rax
    mov rdi, [rbp - ARC_LIST]
    mov rsi, rax
    call list_append
    mov rdi, rbx
    DECREF_V rdi, rcx
    ; Then the operand.
    mov rdi, [rbp - ARC_COMP]
    mov rsi, [rbp - ARC_NODE]
    mov rdx, [rbp - ARC_I]
    shl rdx, 1
    inc rdx
    call ast_child
    mov esi, eax
    mov rdi, [rbp - ARC_COMP]
    mov edx, AF_NODE
    call ar_field
    mov rbx, rax
    mov rdi, [rbp - ARC_LIST]
    mov rsi, rax
    call list_append
    mov rdi, rbx
    DECREF_V rdi, rcx
    inc qword [rbp - ARC_I]
    jmp .arc_loop

.arc_done:
    mov rax, [rbp - ARC_LIST]
    pop rbx
    leave
    ret

.arc_one:
    ; `for`'s else block hides in .clist with nchild at 0 -- a child-list walk
    ; reaches none of it, which is the trap CLAUDE.md records about sym_visit.
    mov eax, [rsi + AstNode.clist]
    mov esi, eax
    mov rdi, [rbp - ARC_COMP]
    mov edx, AF_NODE
    call ar_field
    pop rbx
    leave
    ret

.arc_none:
    LOAD_NONE rax
    INCREF rax
    pop rbx
    leave
    ret
END_FUNC ar_children

;; ============================================================================
;; ar_node(rdi = Comp*, esi = a node index) -> rax = the ten-tuple, owned
;;
;; Recursion is bounded by the parser's own COMP_MAX_DEPTH: a tree it could
;; not build is a tree this cannot be handed.
;; ============================================================================
ARN_COMP  equ 8
ARN_IDX   equ 16
ARN_TUP   equ 24
ARN_KIND  equ 32
ARN_SPAN  equ 40
ARN_FRAME equ 48            ; + 2 pushes = 64

global ar_node
DEF_FUNC ar_node, ARN_FRAME
    push rbx
    push r12
    mov [rbp - ARN_COMP], rdi
    mov [rbp - ARN_IDX], rsi

    mov rdi, [rbp - ARN_COMP]
    mov rsi, [rbp - ARN_IDX]
    call ast_at
    mov rbx, rax                ; rbx = the AstNode*, stable: nothing allocates
                                ; into Comp.nodes from here on

    movzx eax, byte [rbx + AstNode.kind]
    mov [rbp - ARN_KIND], rax

    mov edi, 12
    call tuple_new
    test rax, rax
    jz .arn_fail
    mov [rbp - ARN_TUP], rax
    mov r12, [rax + PyTupleObject.ob_item]

    ; 0 kind, 1 subkind
    mov rdi, [rbp - ARN_KIND]
    call ar_int
    mov [r12], rax
    movzx edi, byte [rbx + AstNode.subkind]
    call ar_int
    mov [r12 + 8], rax

    ; 2 lineno, 3 col, 4 end_lineno, 5 end_col.  The end pair comes out of the
    ; parallel span Buf; -1 there means the parser did not record it, and
    ; _ast_build reads that as None.
    mov edi, [rbx + AstNode.lineno]
    call ar_int
    mov [r12 + 16], rax
    mov edi, [rbx + AstNode.col]
    call ar_int
    mov [r12 + 24], rax
    mov rdi, [rbp - ARN_COMP]
    mov rsi, [rbp - ARN_IDX]
    call ast_span_at
    test rax, rax
    jz .arn_no_span
    mov [rbp - ARN_SPAN], rax
    movsxd rdi, dword [rax + AstSpan.end_lineno]
    call ar_int
    mov [r12 + 32], rax
    mov rcx, [rbp - ARN_SPAN]
    movsxd rdi, dword [rcx + AstSpan.end_col]
    call ar_int
    mov [r12 + 40], rax
    jmp .arn_have_pos
.arn_no_span:
    mov rdi, -1
    call ar_int
    mov [r12 + 32], rax
    mov rdi, -1
    call ar_int
    mov [r12 + 40], rax
.arn_have_pos:

    ; 6 a, 7 b, 8 c -- each read the way this kind's row says.
    lea rcx, [rel ar_fieldkinds]
    mov rdx, [rbp - ARN_KIND]
    lea rcx, [rcx + rdx*4]
    mov rdi, [rbp - ARN_COMP]
    mov esi, [rbx + AstNode.a]
    movzx edx, byte [rcx]
    push rcx
    call ar_field
    pop rcx
    mov [r12 + 48], rax
    mov rdi, [rbp - ARN_COMP]
    mov esi, [rbx + AstNode.b]
    movzx edx, byte [rcx + 1]
    push rcx
    call ar_field
    pop rcx
    mov [r12 + 56], rax
    mov rdi, [rbp - ARN_COMP]
    mov esi, [rbx + AstNode.c]
    movzx edx, byte [rcx + 2]
    push rcx
    call ar_field
    pop rcx
    mov [r12 + 64], rax

    ; 9 children
    mov rdi, [rbp - ARN_COMP]
    mov rsi, rbx
    movzx edx, byte [rcx + 3]
    call ar_children
    mov [r12 + 72], rax

    ; 10 type_params: the children of the AST_TYPEPARAMS node hung off this
    ; one, or None.  Read through the node rather than a field because a def
    ; has none free.
    mov rdi, [rbp - ARN_COMP]
    mov rsi, [rbp - ARN_IDX]
    extern ast_typeparams_at
    call ast_typeparams_at
    test eax, eax
    jz .arn_no_typeparams
    mov rdi, [rbp - ARN_COMP]
    mov esi, eax
    mov edx, AF_NODE
    call ar_field
    jmp .arn_have_typeparams
.arn_no_typeparams:
    LOAD_NONE rax
    INCREF rax
.arn_have_typeparams:
    mov r12, [rbp - ARN_TUP]
    mov r12, [r12 + PyTupleObject.ob_item]
    mov [r12 + 80], rax

    ; 11 type_comment: the text of a `# type:` comment, when one was asked
    ; for and one was there.  A side table like type_params, and for the same
    ; reason: AstNode has no field left.
    ;
    ; A Module has no type comment of its own and carries the file's
    ; `# type: ignore` list in this slot instead, which is where CPython puts
    ; them too -- on the Module, not on any statement.
    cmp qword [rbp - ARN_KIND], AST_MODULE
    jne .arn_ordinary_tc
    mov rdi, [rbp - ARN_COMP]
    call ar_typeignores
    jmp .arn_have_typecomment
.arn_ordinary_tc:
    mov rdi, [rbp - ARN_COMP]
    mov rsi, [rbp - ARN_IDX]
    extern ast_typecomment_at
    call ast_typecomment_at
    test eax, eax
    jz .arn_no_typecomment
    mov rdi, [rbp - ARN_COMP]
    mov esi, eax
    mov edx, AF_OBJ
    call ar_field
    jmp .arn_have_typecomment
.arn_no_typecomment:
    LOAD_NONE rax
    INCREF rax
.arn_have_typecomment:
    mov r12, [rbp - ARN_TUP]
    mov r12, [r12 + PyTupleObject.ob_item]
    mov [r12 + 88], rax

    mov rax, [rbp - ARN_TUP]
    pop r12
    pop rbx
    leave
    ret

.arn_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC ar_node

section .rodata
align 4
global ar_fieldkinds          ; astload.asm writes a node by the same rows
;; One row per AST kind: how to read .a, .b, .c and the child list.
;;
;; This is the only place that knows a node index from an object index -- the
;; node itself does not, both are bare u32 -- so a wrong row here is a wrong
;; tree.  Every row is checked by tests/test_ast.py, which diffs ast.dump
;; against CPython over every construct the parser produces.
ar_fieldkinds:
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ;  0 NULL
    db AF_OBJ , AF_NONE, AF_NONE, AC_NONE ;  1 CONST
    db AF_OBJ , AF_NONE, AF_NONE, AC_NONE ;  2 NAME
    db AF_NODE, AF_NODE, AF_NONE, AC_NONE ;  3 BINOP
    db AF_NODE, AF_NONE, AF_NONE, AC_NONE ;  4 UNARYOP
    db AF_NONE, AF_NONE, AF_NONE, AC_NODE ;  5 BOOLOP
    db AF_NODE, AF_NONE, AF_NONE, AC_PAIR ;  6 COMPARE
    db AF_NODE, AF_NODE, AF_NODE, AC_NONE ;  7 IFEXP
    db AF_NODE, AF_NODE, AF_NODE, AC_NONE ;  8 LAMBDA
    db AF_NONE, AF_NONE, AF_NONE, AC_NODE ;  9 TUPLE
    db AF_NONE, AF_NONE, AF_NONE, AC_NODE ; 10 LIST
    db AF_NONE, AF_NONE, AF_NONE, AC_NODE ; 11 SET
    db AF_NONE, AF_NONE, AF_NONE, AC_NODE ; 12 DICT
    db AF_NODE, AF_NODE, AF_NONE, AC_NODE ; 13 CALL
    db AF_NODE, AF_OBJ , AF_NONE, AC_NONE ; 14 ATTRIBUTE
    db AF_NODE, AF_NODE, AF_NONE, AC_NONE ; 15 SUBSCRIPT
    db AF_NODE, AF_NODE, AF_NODE, AC_NONE ; 16 SLICE
    db AF_NODE, AF_NONE, AF_NONE, AC_NONE ; 17 STARRED
    db AF_NODE, AF_NONE, AF_NONE, AC_NONE ; 18 DOUBLESTARRED
    db AF_OBJ , AF_NODE, AF_NONE, AC_NONE ; 19 KEYWORD
    db AF_NODE, AF_NODE, AF_NONE, AC_NONE ; 20 NAMEDEXPR
    db AF_NODE, AF_NONE, AF_NONE, AC_NONE ; 21 YIELD
    db AF_NODE, AF_NONE, AF_NONE, AC_NONE ; 22 YIELDFROM
    db AF_NODE, AF_NONE, AF_NONE, AC_NONE ; 23 AWAIT
    db AF_NONE, AF_NONE, AF_NONE, AC_NODE ; 24 JOINEDSTR
    db AF_NODE, AF_NODE, AF_NONE, AC_NONE ; 25 FORMATTEDVALUE
    db AF_NODE, AF_NONE, AF_NONE, AC_NODE ; 26 LISTCOMP
    db AF_NODE, AF_NONE, AF_NONE, AC_NODE ; 27 SETCOMP
    db AF_NODE, AF_NODE, AF_NONE, AC_NODE ; 28 DICTCOMP
    db AF_NODE, AF_NONE, AF_NONE, AC_NODE ; 29 GENEXP
    db AF_NODE, AF_NODE, AF_NONE, AC_NODE ; 30 COMPREHENSION
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 31 --
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 32 --
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 33 --
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 34 --
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 35 --
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 36 --
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 37 --
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 38 --
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 39 --
    db AF_NONE, AF_NONE, AF_NONE, AC_NODE ; 40 MODULE
    db AF_NODE, AF_NONE, AF_NONE, AC_NONE ; 41 EXPRESSION
    db AF_NODE, AF_NONE, AF_NONE, AC_NONE ; 42 EXPR_STMT
    db AF_NONE, AF_NODE, AF_NONE, AC_NODE ; 43 ASSIGN
    db AF_NODE, AF_NODE, AF_NONE, AC_NONE ; 44 AUGASSIGN
    db AF_NODE, AF_NODE, AF_NODE, AC_NONE ; 45 ANNASSIGN
    db AF_NODE, AF_NODE, AF_NODE, AC_NONE ; 46 IF
    db AF_NODE, AF_NODE, AF_NODE, AC_NONE ; 47 WHILE
    db AF_NODE, AF_NODE, AF_NODE, AC_ONE  ; 48 FOR
    db AF_NONE, AF_NONE, AF_NONE, AC_NODE ; 49 BLOCK
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 50 PASS
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 51 BREAK
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 52 CONTINUE
    db AF_NODE, AF_NONE, AF_NONE, AC_NONE ; 53 RETURN
    db AF_NONE, AF_NONE, AF_NONE, AC_NODE ; 54 DELETE
    db AF_NODE, AF_NODE, AF_NONE, AC_NONE ; 55 RAISE
    db AF_NODE, AF_NODE, AF_NONE, AC_NONE ; 56 ASSERT
    db AF_NONE, AF_NONE, AF_NONE, AC_OBJ  ; 57 GLOBAL
    db AF_NONE, AF_NONE, AF_NONE, AC_OBJ  ; 58 NONLOCAL
    db AF_NONE, AF_NONE, AF_NONE, AC_NODE ; 59 IMPORT
    db AF_OBJ , AF_NONE, AF_NONE, AC_NODE ; 60 IMPORTFROM
    db AF_OBJ , AF_OBJ , AF_OBJ , AC_NONE ; 61 ALIAS
    db AF_OBJ , AF_NODE, AF_NODE, AC_NODE ; 62 FUNCTIONDEF
    db AF_OBJ , AF_NODE, AF_NODE, AC_NODE ; 63 CLASSDEF
    db AF_NODE, AF_NODE, AF_NODE, AC_NODE ; 64 TRY
    db AF_NODE, AF_OBJ , AF_NONE, AC_NODE ; 65 HANDLER
    db AF_NODE, AF_NONE, AF_NONE, AC_NODE ; 66 WITH
    db AF_NODE, AF_NODE, AF_NONE, AC_NONE ; 67 WITHITEM
    db AF_NODE, AF_NODE, AF_NODE, AC_NODE ; 68 ARGUMENTS
    db AF_OBJ , AF_NODE, AF_NODE, AC_NONE ; 69 ARG
    db AF_NODE, AF_NONE, AF_NONE, AC_NODE ; 70 MATCH
    db AF_INT , AF_INT , AF_INT , AC_NONE ; 71 EXTRA
    db AF_NODE, AF_NONE, AF_NONE, AC_NODE ; 72 DECORATED
    db AF_NODE, AF_NODE, AF_NONE, AC_NODE ; 73 CASE
    db AF_NODE, AF_NONE, AF_NONE, AC_NONE ; 74 PAT_VALUE
    db AF_OBJ , AF_NONE, AF_NONE, AC_NONE ; 75 PAT_CAPTURE
    db AF_NONE, AF_INT , AF_NONE, AC_NODE ; 76 PAT_SEQUENCE
    db AF_NONE, AF_OBJ , AF_NONE, AC_NODE ; 77 PAT_MAPPING
    db AF_NODE, AF_INT , AF_NONE, AC_NODE ; 78 PAT_CLASS
    db AF_OBJ , AF_NODE, AF_NONE, AC_NONE ; 79 PAT_KEYWORD
    db AF_NONE, AF_NONE, AF_NONE, AC_NODE ; 80 PAT_OR
    db AF_NODE, AF_OBJ , AF_NONE, AC_NONE ; 81 PAT_AS
    db AF_NONE, AF_NONE, AF_NONE, AC_NODE ; 82 INTERACTIVE
    db AF_NODE, AF_NODE, AF_NONE, AC_NONE ; 83 TYPEALIAS
    db AF_NONE, AF_NONE, AF_NONE, AC_NODE ; 84 TYPEPARAMS
    db AF_OBJ , AF_NODE, AF_NONE, AC_NONE ; 85 TYPEVAR
    db AF_OBJ , AF_NONE, AF_NONE, AC_NONE ; 86 PARAMSPEC
    db AF_OBJ , AF_NONE, AF_NONE, AC_NONE ; 87 TYPEVARTUPLE
    db AF_NODE, AF_NONE, AF_NONE, AC_NODE ; 88 FUNCTIONTYPE
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 83 --
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 84 --
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 85 --
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 86 --
    db AF_NONE, AF_NONE, AF_NONE, AC_NONE ; 87 --

section .text

;; ============================================================================
;; ar_typeignores(rdi = Comp*) -> rax = a list of (lineno, tag) tuples, owned
;;
;; Every `# type: ignore` in the file, in source order.  It is a list rather
;; than a tuple because the builder turns each pair into a TypeIgnore and
;; CPython's Module.type_ignores is a list.
;; ============================================================================
ATI2_COMP equ 8
ATI2_LIST equ 16
ATI2_I    equ 24
ATI2_N    equ 32
ATI2_FRAME equ 48           ; + 2 pushes = 64, 16-aligned
global ar_typeignores
DEF_FUNC ar_typeignores, ATI2_FRAME
    push rbx
    push r12
    mov rbx, rdi
    mov [rbp - ATI2_COMP], rdi

    extern list_new
    xor edi, edi
    call list_new
    test rax, rax
    jz .ati2_none
    mov [rbp - ATI2_LIST], rax

    mov rcx, [rbx + Comp.typeignores + Buf.len]
    mov [rbp - ATI2_N], rcx
    mov qword [rbp - ATI2_I], 0
.ati2_loop:
    mov rcx, [rbp - ATI2_I]
    cmp rcx, [rbp - ATI2_N]
    jae .ati2_done
    mov edi, 2
    extern tuple_new
    call tuple_new
    test rax, rax
    jz .ati2_done
    mov r12, rax
    mov rax, [rbx + Comp.typeignores + Buf.data]
    mov rcx, [rbp - ATI2_I]
    mov edx, [rax + rcx*4]              ; the line
    push rax
    push rcx
    mov rdi, rdx
    extern int_from_i64
    call int_from_i64
    V_PACK rax, rdx             ; a tuple slot holds a Value, not a payload
    pop rcx
    pop rdx
    mov rdx, [r12 + PyTupleObject.ob_item]
    mov [rdx], rax
    ; The tag, an obj index into the arena.
    mov rax, [rbx + Comp.typeignores + Buf.data]
    inc rcx
    mov esi, [rax + rcx*4]
    mov rdi, rbx
    extern ast_obj_at
    call ast_obj_at
    INCREF rax
    mov rdx, [r12 + PyTupleObject.ob_item]
    mov [rdx + 8], rax
    mov rdi, [rbp - ATI2_LIST]
    mov rsi, r12
    extern list_append
    call list_append
    mov rdi, r12
    extern obj_decref
    call obj_decref
    add qword [rbp - ATI2_I], 2
    jmp .ati2_loop
.ati2_done:
    mov rax, [rbp - ATI2_LIST]
    pop r12
    pop rbx
    leave
    ret
.ati2_none:
    LOAD_NONE rax
    INCREF rax
    pop r12
    pop rbx
    leave
    ret
END_FUNC ar_typeignores
