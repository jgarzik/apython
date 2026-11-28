; parse_stmt.asm - Statement parsing
;
; Statements dispatch on their leading keyword through stmt_table; anything
; that is not a keyword falls through to the expression-or-assignment parser.
;
; Assignment is not decided by lookahead.  A target is parsed as an ordinary
; expression -- `a, b` and `a, b = t` are the same production until the `=`
; appears -- and then re-marked with ast_set_ctx, which is also where "cannot
; assign to a literal" is discovered: a node kind with no store form fails
; there.  Backtracking would work too, and CPython's PEG parser does exactly
; that, but this is smaller and gives a better message.

%include "macros.inc"
%include "object.inc"
%include "value.inc"
%include "opcodes.inc"
%include "compiler.inc"

extern ast_at
extern ast_commit
extern ast_make
extern ast_set_typeparams
extern ast_end_at
extern ast_end_here
extern ast_mark
extern ast_obj
extern ast_obj_at
extern ast_push
extern ast_set_ctx
extern exc_SyntaxError_type
extern comp_msg_start
extern comp_msg_cstr
extern ap_strcmp
extern ast_child
extern comp_error_node
extern str_type
extern par_bad_target
extern comp_msg_i64
extern comp_error_span
extern ast_take_typecomment
extern ast_park_typecomment
extern ast_claim_typecomment
extern exc_IndentationError_type
extern ast_span_at
extern comp_error
extern par_dotted_name
extern buf_free
extern buf_init
extern buf_push_u8

extern par_advance
extern par_expect
extern par_expr
extern par_finish_list
extern par_kind
extern par_peek
extern par_peek_next
extern par_syntax_error
extern par_looks_like_match
extern par_soft_keyword_is
extern ps_match
extern ps_try
extern ps_with
extern in_call_public


BP_NONE equ 0
BP_COMPARE equ 12

; --- Named frame-layout constants ---
PM_MARK  equ 16
PM_LINE  equ 24
PM_FRAME equ 24          ; + 1 push = 32

section .text

;; ============================================================================
;; par_module(Comp *c) -> rax = the AST_MODULE node, 0 on error
;; ============================================================================
DEF_FUNC par_module, PM_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PM_LINE], rcx
    mov rdi, rbx
    call ast_mark
    mov [rbp - PM_MARK], rax

.loop:
    ; A `# type: ignore` on a line of its own is recorded and skipped wherever
    ; it appears -- including after the last statement, where par_statement is
    ; never reached again.
    mov rdi, rbx
    extern ast_take_typeignore
    call ast_take_typeignore
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_ENDMARKER
    je .done
    ; An INDENT where a statement should start is an indentation error, not a
    ; grammar one, and CPython says so: "unexpected indent", at the first
    ; non-blank column and running to the end of the line.
    cmp eax, TOK_INDENT
    je .bad_indent
    cmp eax, TOK_NEWLINE
    jne .stmt
    mov rdi, rbx
    call par_advance
    jmp .loop

.bad_indent:
    mov rdi, rbx
    call par_peek
    mov ecx, [rax + Token.lineno]
    mov r8d, [rax + Token.col]
    mov r9d, ecx
    mov r10d, -2                        ; CPython's end_offset here is -1
    mov rdi, rbx
    lea rsi, [rel exc_IndentationError_type]
    CSTRING rdx, "unexpected indent"
    call comp_error_span
    jmp .fail

.stmt:
    ; par_statement_any, not par_simple_stmts: a compound statement consumes
    ; its own suite and the DEDENT that ends it, so there is no NEWLINE left
    ; for the simple-statement path to demand.
    mov rdi, rbx
    call par_statement_any
    test eax, eax
    jz .fail
    jmp .loop

.done:
    mov rdi, rbx
    mov esi, AST_MODULE
    mov rdx, [rbp - PM_LINE]
    mov rcx, [rbp - PM_MARK]
    call par_finish_list
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_module

;; ============================================================================
;; ps_future_window(rdi = Comp*, esi = the statement just parsed) -> nothing
;;
;; Shuts the window a future statement may appear in.  It stays open across
;; the module docstring and across other future statements, and closes on
;; anything else -- CPython's rule, and it is checked per STATEMENT rather
;; than per line: `from __future__ import x; import y; from __future__ import
;; z` is three of them and the third is late.
;;
;; Comp.future_here is set by ps_note_future while the statement is being
;; parsed, and consumed here; the count of statements already seen is what
;; makes the docstring the FIRST one rather than any string expression.
;; ============================================================================
PID_COMP equ 8
PID_FRAME equ 16            ; + 1 push = 24... padded to 16 below
DEF_FUNC_LOCAL ps_future_window, 24
    push rbx
    mov rbx, rdi
    mov [rbp - PID_COMP], rsi           ; the statement node
    cmp dword [rbx + Comp.future_shut], 0
    jne .pid_out                        ; already shut
    ; EVERY statement counts, including a future one -- `from __future__
    ; import x` followed by a string followed by another future import is
    ; badsyntax_future10, and the string is not a docstring there.
    mov ecx, [rbx + Comp.future_nstmt]
    mov dword [rbx + Comp.future_nstmt], 1
    cmp dword [rbx + Comp.future_here], 0
    je .pid_check
    mov dword [rbx + Comp.future_here], 0
    jmp .pid_out                        ; a future statement keeps it open
.pid_check:
    test ecx, ecx
    jnz .pid_shut                       ; a docstring is only ever the first
    mov rdi, rbx
    mov esi, [rbp - PID_COMP]
    call ast_at
    test rax, rax
    jz .pid_shut
    cmp byte [rax + AstNode.kind], AST_EXPR_STMT
    jne .pid_shut
    mov esi, [rax + AstNode.a]
    mov rdi, rbx
    call ast_at
    test rax, rax
    jz .pid_shut
    cmp byte [rax + AstNode.kind], AST_CONST
    jne .pid_shut
    mov esi, [rax + AstNode.a]
    mov rdi, rbx
    call ast_obj_at
    test rax, rax
    jz .pid_shut
    V_TEST_PTR rax, rcx
    ja .pid_shut
    mov rcx, [rax + PyObject.ob_type]
    lea rax, [rel str_type]
    cmp rcx, rax
    je .pid_out                         ; a docstring; the window stays open
.pid_shut:
    mov dword [rbx + Comp.future_shut], 1
.pid_out:
    pop rbx
    leave
    ret
END_FUNC ps_future_window

;; ============================================================================
;; par_simple_stmts(Comp *c) -> rax = 1 ok, 0 error
;; One logical line: `stmt (';' stmt)* NEWLINE`, each pushed onto the pending
;; stack for whatever list is being built.
;; ============================================================================
PSS_STMT  equ 8
PSS_FRAME equ 16            ; + 1 push = 24... one word more to land right
DEF_FUNC par_simple_stmts, 24           ; + 1 push = 32, 16-aligned
    push rbx
    mov rbx, rdi
    mov qword [rbp - PSS_STMT], 0
.loop:
    mov dword [rbx + Comp.future_here], 0
    mov rdi, rbx
    call par_statement
    test eax, eax
    jz .fail
    mov [rbp - PSS_STMT], rax
    mov rdi, rbx
    mov esi, eax
    call ps_future_window
    mov rdi, rbx
    mov rsi, [rbp - PSS_STMT]           ; reloaded: the call above clobbers rax
    call ast_push

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_SEMI
    jne .end_of_line
    mov rdi, rbx
    call par_advance
    ; A trailing semicolon is allowed: `x = 1;` ends the line.
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NEWLINE
    je .end_of_line
    cmp eax, TOK_ENDMARKER
    je .ok
    jmp .loop

.end_of_line:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_ENDMARKER
    je .ok
    ; Python 2's print and exec are the one shape CPython guesses at:
    ; `print 'hi'` gets "Missing parentheses in call to 'print'. Did you mean
    ; print(...)?", spanning the whole line.  It is worth the special case
    ; because the statement is otherwise a bare name followed by nonsense,
    ; and the message a beginner needs is not "invalid syntax".
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NEWLINE
    je .pss_have_newline
    mov rdi, rbx
    mov rsi, [rbp - PSS_STMT]
    call pss_py2_statement
    test eax, eax
    jnz .fail
.pss_have_newline:
    mov rdi, rbx
    mov esi, TOK_NEWLINE
    CSTRING rdx, "invalid syntax"
    call par_expect
    test eax, eax
    jz .fail
.ok:
    mov eax, 1
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_simple_stmts

;; ============================================================================
;; pss_py2_statement(Comp *c, uint32_t stmt) -> rax = 1 when it reported a
;; Python 2 print or exec statement, 0 when this is not one
;;
;; `print 'hi'` parses as the bare name `print` and then stops, because a
;; string does not follow a name.  CPython recognises exactly that shape and
;; says what to do about it, spanning from the name to the end of the line.
;; ============================================================================
PPS_COMP  equ 8
PPS_STMT  equ 16
PPS_NAME  equ 24
PPS_FRAME equ 32            ; + 1 push = 40... one more word to land right
DEF_FUNC_LOCAL pss_py2_statement, 40    ; + 1 push = 48, 16-aligned
    push rbx
    mov rbx, rdi
    mov [rbp - PPS_COMP], rdi
    mov [rbp - PPS_STMT], rsi
    test rsi, rsi
    jz .pps_no

    ; The statement has to be an expression statement holding a bare name.
    mov rdi, rbx
    mov rsi, [rbp - PPS_STMT]
    call ast_at
    cmp byte [rax + AstNode.kind], AST_EXPR_STMT
    jne .pps_no
    mov esi, [rax + AstNode.a]
    mov rdi, rbx
    call ast_at
    cmp byte [rax + AstNode.kind], AST_NAME
    jne .pps_no
    mov ecx, [rax + AstNode.lineno]
    mov [rbp - PPS_NAME], rcx
    mov r8d, [rax + AstNode.col]
    mov [rbp - PPS_NAME + 4], r8d
    mov esi, [rax + AstNode.a]
    mov rdi, rbx
    call ast_obj_at
    test rax, rax
    jz .pps_no
    mov rbx, rax

    lea rdi, [rbx + PyStrObject.data]
    CSTRING rsi, "print"
    call ap_strcmp
    test eax, eax
    jz .pps_report
    lea rdi, [rbx + PyStrObject.data]
    CSTRING rsi, "exec"
    call ap_strcmp
    test eax, eax
    jnz .pps_no

.pps_report:
    ; "Missing parentheses in call to 'print'. Did you mean print(...)?",
    ; from the name to the end of the line.
    call comp_msg_start
    push rax
    mov rdi, rax
    CSTRING rsi, "Missing parentheses in call to '"
    call comp_msg_cstr
    mov rdi, rax
    lea rsi, [rbx + PyStrObject.data]
    call comp_msg_cstr
    mov rdi, rax
    CSTRING rsi, "'. Did you mean "
    call comp_msg_cstr
    mov rdi, rax
    lea rsi, [rbx + PyStrObject.data]
    call comp_msg_cstr
    mov rdi, rax
    CSTRING rsi, "(...)?"
    call comp_msg_cstr
    pop rdx

    ; The span ends where the token that follows the name does, which for a
    ; whole `print 'hi'` is the end of the line.
    mov rdi, [rbp - PPS_COMP]
    call par_peek
    mov r9d, [rax + Token.lineno]
    mov r10d, [rax + Token.col]
    add r10d, [rax + Token.len]
    mov ecx, [rbp - PPS_NAME]
    mov r8d, [rbp - PPS_NAME + 4]
    mov rdi, [rbp - PPS_COMP]
    lea rsi, [rel exc_SyntaxError_type]
    call comp_error_span
    mov eax, 1
    pop rbx
    leave
    ret
.pps_no:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC pss_py2_statement

;; ============================================================================
;; par_statement(Comp *c) -> rax = a statement node, 0 on error
;; ============================================================================
DEF_FUNC par_statement, 8
    push rbx
    mov rbx, rdi
    ; A `# type: ignore` on a line of its own reaches statement position,
    ; where nothing else will take it: ast_take_typecomment collects one only
    ; when a statement precedes it.  CPython records it on the Module wherever
    ; it appears, so record it here and carry on to the real statement.
    extern ast_take_typeignore
    call ast_take_typeignore
    mov rdi, rbx
    call par_kind
    ; `match` is a soft keyword, so it arrives as a NAME and cannot be in
    ; stmt_table: only its context tells it from a variable of the same name.
    cmp eax, TOK_NAME
    jne .not_soft
    mov rdi, rbx
    call par_looks_like_match
    test eax, eax
    jz .maybe_alias
    mov rdi, rbx
    call ps_match
    pop rbx
    leave
    ret
.maybe_alias:
    ; `type` is a soft keyword as well as a builtin, so only the statement
    ; shape -- `type X =` or `type X[` -- is taken as one.
    mov rdi, rbx
    lea rsi, [rel ps_type_kw]
    mov edx, 4
    call par_soft_keyword_is
    test eax, eax
    jz .as_expr
    mov rdi, rbx
    call par_looks_like_type_alias
    test eax, eax
    jz .as_expr
    mov rdi, rbx
    call ps_type_alias
    pop rbx
    leave
    ret
.not_soft:
    cmp eax, TOK_COUNT
    jae .as_expr
    lea rcx, [rel stmt_table]
    mov rax, [rcx + rax*8]
    test rax, rax
    jz .as_expr
    mov rdi, rbx
    call rax
    pop rbx
    leave
    ret
.as_expr:
    mov rdi, rbx
    call par_expr_stmt
    pop rbx
    leave
    ret
END_FUNC par_statement

;; ============================================================================
;; par_expr_stmt(Comp *c) -> node
;;
;; An expression, an assignment, an augmented assignment or an annotated one --
;; decided by what follows the first expression rather than by lookahead.
;; ============================================================================
PE2_FIRST equ 16
PE2_LINE  equ 24
PE2_MARK  equ 32
PE2_OP    equ 40
PE2_NODE  equ 48
PE2_PAREN equ 56         ; 1 when the statement began with '(' -- see .annassign
PE2_BAD   equ 64         ; the target an assignment was refused for
PE2_FRAME equ 72         ; + 1 push = 80
DEF_FUNC par_expr_stmt, PE2_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PE2_LINE], rcx
    ; Whether the statement began with '(', which is the whole of what
    ; AnnAssign.simple asks -- see .annassign.
    xor ecx, ecx
    movzx edx, word [rax + Token.kind]
    cmp edx, TOK_LPAR
    sete cl
    mov [rbp - PE2_PAREN], rcx

    mov rdi, rbx
    call par_exprlist_stmt              ; an expression, or a bare tuple
    test rax, rax
    jz .fail
    mov [rbp - PE2_FIRST], rax

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_EQUAL
    je .assign
    cmp eax, TOK_COLON
    je .annassign
    call par_augop
    cmp eax, -1
    jne .augassign

    ; A bare expression statement.
    mov rdi, rbx
    mov esi, AST_EXPR_STMT
    xor edx, edx
    mov rcx, [rbp - PE2_LINE]
    mov r8, [rbp - PE2_FIRST]
    xor r9d, r9d
    call ast_make
    pop rbx
    leave
    ret

.assign:
    ; Every `=`-separated item but the last is a target; the last is the value.
    mov rdi, rbx
    call ast_mark
    mov [rbp - PE2_MARK], rax
    mov rdi, rbx
    mov rsi, [rbp - PE2_FIRST]
    call ast_push
.assign_loop:
    mov rdi, rbx
    call par_advance                    ; consume '='
    mov rdi, rbx
    call par_exprlist_stmt
    test rax, rax
    jz .fail
    mov [rbp - PE2_FIRST], rax
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_EQUAL
    jne .assign_done
    mov rdi, rbx
    mov rsi, [rbp - PE2_FIRST]
    call ast_push
    jmp .assign_loop

.assign_done:
    ; Mark everything staged as a store target.
    mov rdi, rbx
    call ast_mark
    mov rcx, rax
    mov rdx, [rbp - PE2_MARK]
.mark_loop:
    cmp rdx, rcx
    jae .marked
    push rcx
    push rdx
    mov rax, [rbx + Comp.pending + Buf.data]
    mov esi, [rax + rdx*4]
    mov [rbp - PE2_BAD], rsi
    mov rdi, rbx
    mov edx, CTX_STORE
    call ast_set_ctx
    pop rdx
    pop rcx
    test eax, eax
    jz .bad_target
    inc rdx
    jmp .mark_loop
.marked:
    mov rdi, rbx
    mov esi, AST_ASSIGN
    mov rdx, [rbp - PE2_LINE]
    mov rcx, [rbp - PE2_MARK]
    call par_finish_list
    test rax, rax
    jz .fail
    mov [rbp - PE2_NODE], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - PE2_FIRST]
    mov [rax + AstNode.b], edx          ; the value
    ; `x = 1  # type: int`.  The comment token sits between the value and the
    ; NEWLINE, which is where the tokenizer found it.
    mov rdi, rbx
    mov rsi, [rbp - PE2_NODE]
    call ast_take_typecomment
    mov rax, [rbp - PE2_NODE]
    pop rbx
    leave
    ret

.augassign:
    mov [rbp - PE2_OP], rax
    mov rdi, rbx
    call par_advance                    ; consume the operator
    mov rdi, rbx
    mov rsi, [rbp - PE2_FIRST]
    mov [rbp - PE2_BAD], rsi
    mov edx, CTX_STORE
    call ast_set_ctx
    test eax, eax
    jz .bad_target
    ; Only a single, simple target may be augmented: `a, b += 1` is illegal.
    mov rdi, rbx
    mov rsi, [rbp - PE2_FIRST]
    call ast_at
    movzx eax, byte [rax + AstNode.kind]
    cmp eax, AST_NAME
    je .aug_ok
    cmp eax, AST_ATTRIBUTE
    je .aug_ok
    cmp eax, AST_SUBSCRIPT
    jne .bad_aug_target
.aug_ok:
    mov rdi, rbx
    call par_exprlist_stmt
    test rax, rax
    jz .fail
    mov r9, rax
    mov rdi, rbx
    mov esi, AST_AUGASSIGN
    mov rdx, [rbp - PE2_OP]
    mov rcx, [rbp - PE2_LINE]
    mov r8, [rbp - PE2_FIRST]
    call ast_make
    pop rbx
    leave
    ret

.annassign:
    mov rdi, rbx
    call par_advance                    ; consume ':'
    mov rdi, rbx
    mov rsi, [rbp - PE2_FIRST]
    mov [rbp - PE2_BAD], rsi
    mov edx, CTX_STORE
    call ast_set_ctx
    test eax, eax
    jz .bad_target
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr                       ; the annotation
    test rax, rax
    jz .fail
    mov [rbp - PE2_OP], rax

    ; subkind = 1 means "the target was parenthesised", which is CPython's
    ; AnnAssign.simple = 0.  `(x): int` and `x: int` produce the identical
    ; Name node -- pf_group hands back the inner one untouched -- so the one
    ; bit has to come from the token stream, and the statement's first token
    ; is the whole answer.  It is not only ast.dump: `simple` is what decides
    ; whether the annotation is RECORDED, so `(x): int = 1` was writing
    ; __annotations__['x'] where CPython writes nothing.
    mov rdi, rbx
    mov esi, AST_ANNASSIGN
    mov rdx, [rbp - PE2_PAREN]
    mov rcx, [rbp - PE2_LINE]
    mov r8, [rbp - PE2_FIRST]
    mov r9, [rbp - PE2_OP]
    call ast_make
    mov [rbp - PE2_NODE], rax

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_EQUAL
    jne .ann_done
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call par_exprlist_stmt
    test rax, rax
    jz .fail
    mov rdx, rax
    mov rdi, rbx
    mov rsi, [rbp - PE2_NODE]
    push rdx
    call ast_at
    pop rdx
    mov [rax + AstNode.c], edx
    ; The node was made before the value: its end is here, not at the
    ; annotation.
    mov rdi, rbx
    mov esi, [rbp - PE2_NODE]
    call ast_end_here
.ann_done:
    mov rax, [rbp - PE2_NODE]
    pop rbx
    leave
    ret

.bad_target:
    ; CPython names the kind of thing that cannot be a target, spans the
    ; target itself, and -- because an `=` where `==` was meant is the usual
    ; cause -- says so.
    mov rdi, rbx
    mov esi, [rbp - PE2_BAD]
    CSTRING rdx, " here. Maybe you meant '==' instead of '='?"
    call par_bad_target
    jmp .fail
.bad_aug_target:
    mov rdi, rbx
    CSTRING rsi, "augmented assignment requires a single simple target"
    call par_syntax_error
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_expr_stmt

;; ============================================================================
;; par_exprlist_stmt(Comp *c) -> node
;; An expression, or a bare comma-separated tuple: `a, b` and `x = 1, 2` both
;; need one, and neither has brackets to delimit it.
;; ============================================================================
PX2_FIRST equ 16
PX2_LINE  equ 24
PX2_MARK  equ 32
PX2_FRAME equ 40         ; + 1 push = 48
DEF_FUNC par_exprlist_stmt, PX2_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PX2_LINE], rcx

    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PX2_FIRST], rax

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    jne .single

    mov rdi, rbx
    call ast_mark
    mov [rbp - PX2_MARK], rax
    mov rdi, rbx
    mov rsi, [rbp - PX2_FIRST]
    call ast_push
.tuple_loop:
    mov rdi, rbx
    call par_advance                    ; consume ','
    mov rdi, rbx
    call par_kind
    ; A trailing comma ends the tuple: `x = 1,` is a one-tuple.
    cmp eax, TOK_NEWLINE
    je .tuple_done
    cmp eax, TOK_ENDMARKER
    je .tuple_done
    cmp eax, TOK_EQUAL
    je .tuple_done
    cmp eax, TOK_SEMI
    je .tuple_done
    cmp eax, TOK_COLON
    je .tuple_done
    cmp eax, TOK_RPAR
    je .tuple_done
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    je .tuple_loop
.tuple_done:
    mov rdi, rbx
    mov esi, AST_TUPLE
    mov rdx, [rbp - PX2_LINE]
    mov rcx, [rbp - PX2_MARK]
    call par_finish_list
    pop rbx
    leave
    ret

.single:
    mov rax, [rbp - PX2_FIRST]
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_exprlist_stmt

;; ============================================================================
;; par_augop(Comp *c) -> eax = the NB_INPLACE_* code, or -1
;; Does not consume the token.
;; ============================================================================
DEF_FUNC par_augop, 8
    push rbx
    mov rbx, rdi
    call par_kind
    lea rcx, [rel augop_table]
    xor edx, edx
.scan:
    mov r8d, [rcx + rdx*8]
    cmp r8d, -1
    je .none
    cmp r8d, eax
    je .found
    inc rdx
    jmp .scan
.found:
    mov eax, [rcx + rdx*8 + 4]
    pop rbx
    leave
    ret
.none:
    mov eax, -1
    pop rbx
    leave
    ret
END_FUNC par_augop

;; ============================================================================
;; Keyword statement parsers.  Each is entered with its keyword current and
;; returns a node, or 0 with an error recorded.
;; ============================================================================

PK_LINE  equ 16
PK_A     equ 24
PK_B     equ 32
PK_MARK  equ 40
PK_NODE  equ 48
PK_ALINE equ 56          ; where one alias starts, which is not where the
                         ; statement does
PK_FRAME equ 72          ; + 1 push = 80, 16-byte aligned
PK2_FRAME equ 64         ; + 2 pushes = 80, 16-byte aligned; for the handlers
                         ; that save r12

;; ps_simple - pass, break and continue: a keyword and nothing else.
DEF_FUNC_LOCAL ps_simple, PK_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PK_LINE], rcx
    movzx eax, word [rax + Token.kind]
    mov esi, AST_PASS
    cmp eax, TOK_BREAK
    jne .not_break
    mov esi, AST_BREAK
    jmp .have
.not_break:
    cmp eax, TOK_CONTINUE
    jne .have
    mov esi, AST_CONTINUE
.have:
    push rsi
    mov rdi, rbx
    call par_advance
    pop rsi
    mov rdi, rbx
    xor edx, edx
    mov rcx, [rbp - PK_LINE]
    xor r8d, r8d
    xor r9d, r9d
    call ast_make
    pop rbx
    leave
    ret
END_FUNC ps_simple

;; ps_del - `del a, b[0], c.d`
DEF_FUNC_LOCAL ps_del, PK_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PK_LINE], rcx
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call ast_mark
    mov [rbp - PK_MARK], rax
.loop:
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov rsi, rax
    mov rdi, rbx
    mov edx, CTX_DEL
    push rsi
    call ast_set_ctx
    pop rsi
    test eax, eax
    jz .bad_target
    mov rdi, rbx
    call ast_push
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    jne .done
    mov rdi, rbx
    call par_advance
    ; A trailing comma adds no target: `del y,` is Delete(targets=[Name('y')])
    ; in CPython -- one DELETE_NAME and no tuple -- and looping back into
    ; par_expr reported `invalid syntax`.  `del ,` and `del y, ,` still error,
    ; because this only fires after a target has been parsed.
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NEWLINE
    je .done
    cmp eax, TOK_SEMI
    je .done
    cmp eax, TOK_ENDMARKER
    je .done
    jmp .loop
.done:
    mov rdi, rbx
    mov esi, AST_DELETE
    mov rdx, [rbp - PK_LINE]
    mov rcx, [rbp - PK_MARK]
    call par_finish_list
    pop rbx
    leave
    ret
.bad_target:
    mov rdi, rbx
    CSTRING rsi, "cannot delete that expression"
    call par_syntax_error
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ps_del

;; ps_scope - `global a, b` and `nonlocal a, b`
DEF_FUNC_LOCAL ps_scope, PK2_FRAME
    push rbx
    push r12
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PK_LINE], rcx
    movzx eax, word [rax + Token.kind]
    mov r12d, AST_GLOBAL
    cmp eax, TOK_GLOBAL
    je .have
    mov r12d, AST_NONLOCAL
.have:
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call ast_mark
    mov [rbp - PK_MARK], rax
.loop:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NAME
    jne .need_name
    mov rdi, rbx
    call par_peek
    mov rsi, [rax + Token.start]
    mov edx, [rax + Token.len]
    ; Mangled, like every other identifier.  CPython mangles the DECLARATION
    ; too -- `global __v` inside a method of C is a declaration about _C__v --
    ; and interning it raw here bound a different name from the one every use
    ; of it resolved to, silently.
    mov rdi, rbx
    call comp_name_obj
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    jne .done
    mov rdi, rbx
    call par_advance
    jmp .loop
.done:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rbp - PK_LINE]
    mov rcx, [rbp - PK_MARK]
    call par_finish_list
    pop r12
    pop rbx
    leave
    ret
.need_name:
    mov rdi, rbx
    CSTRING rsi, "invalid syntax"
    call par_syntax_error
.fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC ps_scope

;; ps_assert - `assert test` or `assert test, message`
DEF_FUNC_LOCAL ps_assert, PK_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PK_LINE], rcx
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PK_A], rax
    mov qword [rbp - PK_B], 0

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    jne .build
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PK_B], rax
.build:
    mov rdi, rbx
    mov esi, AST_ASSERT
    xor edx, edx
    mov rcx, [rbp - PK_LINE]
    mov r8, [rbp - PK_A]
    mov r9, [rbp - PK_B]
    call ast_make
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ps_assert

;; ps_raise - `raise`, `raise E`, `raise E from F`
DEF_FUNC_LOCAL ps_raise, PK_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PK_LINE], rcx
    mov rdi, rbx
    call par_advance
    mov qword [rbp - PK_A], 0
    mov qword [rbp - PK_B], 0

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NEWLINE
    je .build
    cmp eax, TOK_SEMI
    je .build
    cmp eax, TOK_ENDMARKER
    je .build

    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PK_A], rax
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_FROM
    jne .build
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PK_B], rax
.build:
    mov rdi, rbx
    mov esi, AST_RAISE
    xor edx, edx
    mov rcx, [rbp - PK_LINE]
    mov r8, [rbp - PK_A]
    mov r9, [rbp - PK_B]
    call ast_make
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ps_raise

;; ============================================================================
;; par_bound_name(Comp *c, uint32_t dotted) -> rax = obj index of the name the
;;   import binds, or 0 on error.
;;
;; `import a.b` binds `a`, not `a.b`: the submodule is reached through the
;; attribute.  The head is mangled the way every other identifier in a class
;; body is -- CPython puts the raw dotted name in IMPORT_NAME and the mangled
;; head in STORE_NAME -- and here, with Comp.private still live, is the only
;; place that can do it.  By the time the symbol table runs, the class the
;; mangling depends on is gone.
;; ============================================================================
PBN_FRAME equ 24          ; + 1 push = 32
DEF_FUNC_LOCAL par_bound_name, PBN_FRAME
    push rbx
    mov rbx, rdi
    call ast_obj_at                     ; rax = the dotted PyStrObject*
    test rax, rax
    jz .fail
    mov rcx, [rax + PyStrObject.ob_size]
    lea rsi, [rax + PyStrObject.data]
    xor edx, edx
.scan:
    cmp rdx, rcx
    jae .have
    cmp byte [rsi + rdx], '.'
    je .have
    inc rdx
    jmp .scan
.have:
    mov rdi, rbx
    call comp_name_obj                  ; mangled, with the source name kept
    test rax, rax
    jz .fail
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_bound_name

;; ============================================================================
;; ============================================================================
;; par_name_obj(Comp *c) -> rax = obj index for the current NAME, 0 on error
;; ============================================================================
DEF_FUNC par_name_obj, 8
    push rbx
    mov rbx, rdi
    call par_kind
    cmp eax, TOK_NAME
    jne .bad
    mov rdi, rbx
    call par_peek
    mov rdi, rbx
    mov rsi, [rax + Token.start]
    mov edx, [rax + Token.len]
    extern comp_name_obj
    call comp_name_obj
    test rax, rax
    jz .fail
    push rax
    mov rdi, rbx
    call par_advance
    pop rax
    pop rbx
    leave
    ret
.bad:
    mov rdi, rbx
    CSTRING rsi, "invalid syntax"
    call par_syntax_error
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_name_obj

;; ps_import - `import a.b, c as d`
DEF_FUNC_LOCAL ps_import, PK2_FRAME
    push rbx
    push r12
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PK_LINE], rcx
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call ast_mark
    mov [rbp - PK_MARK], rax
.loop:
    ; Each alias starts at its own name.  PK_LINE is the statement's, which
    ; is what `import` is at, and every alias in `import a, b` would take it.
    mov rdi, rbx
    call par_peek
    TOK_POS rax
    mov [rbp - PK_ALINE], rcx
    mov rdi, rbx
    call par_dotted_name
    test rax, rax
    jz .fail
    mov r12, rax
    mov qword [rbp - PK_B], 0
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_AS
    jne .make_alias
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call par_name_obj
    test rax, rax
    jz .fail
    mov [rbp - PK_B], rax
.make_alias:
    mov rdi, rbx
    mov esi, AST_ALIAS
    xor edx, edx
    mov rcx, [rbp - PK_ALINE]
    mov r8, r12
    mov r9, [rbp - PK_B]
    call ast_make
    mov [rbp - PK_NODE], rax
    ; The name this alias binds, decided here rather than in codegen: only the
    ; parser still knows the enclosing class, and mangling needs it.
    mov rdx, [rbp - PK_B]
    test rdx, rdx
    jnz .bound_is_as
    mov rdi, rbx
    mov rsi, r12
    call par_bound_name
    test rax, rax
    jz .fail
    mov rdx, rax
.bound_is_as:
    mov rdi, rbx
    mov rsi, [rbp - PK_NODE]
    push rdx
    call ast_at
    pop rdx
    mov [rax + AstNode.c], edx
    mov rdi, rbx
    mov rsi, [rbp - PK_NODE]
    call ast_push
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    jne .done
    mov rdi, rbx
    call par_advance
    jmp .loop
.done:
    mov rdi, rbx
    mov esi, AST_IMPORT
    mov rdx, [rbp - PK_LINE]
    mov rcx, [rbp - PK_MARK]
    call par_finish_list
    pop r12
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC ps_import

;; ps_from - `from a.b import c, d as e` and `from . import x` and `from m import *`
PFR_LEVEL equ 64
PFR_MOD   equ 72
PFR_FRAME equ 80         ; + 2 pushes = 96
DEF_FUNC_LOCAL ps_from, PFR_FRAME
    push rbx
    push r12
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PK_LINE], rcx
    mov rdi, rbx
    call par_advance
    mov qword [rbp - PFR_LEVEL], 0
    mov qword [rbp - PFR_MOD], 0

    ; Leading dots are the relative-import level; `...` counts as three.
.dots:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_DOT
    je .one_dot
    cmp eax, TOK_ELLIPSIS
    je .three_dots
    jmp .after_dots
.one_dot:
    inc qword [rbp - PFR_LEVEL]
    mov rdi, rbx
    call par_advance
    jmp .dots
.three_dots:
    add qword [rbp - PFR_LEVEL], 3
    mov rdi, rbx
    call par_advance
    jmp .dots
.after_dots:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_IMPORT
    je .no_module
    mov rdi, rbx
    call par_dotted_name
    test rax, rax
    jz .fail
    mov [rbp - PFR_MOD], rax
.no_module:
    mov rdi, rbx
    mov esi, TOK_IMPORT
    CSTRING rdx, "expected 'import'"
    call par_expect
    test eax, eax
    jz .fail

    mov rdi, rbx
    call ast_mark
    mov [rbp - PK_MARK], rax

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_STAR
    je .star_import

    ; An optional parenthesised list: from m import (a, b)
    xor r12d, r12d
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_LPAR
    jne .names
    mov r12d, 1
    mov rdi, rbx
    call par_advance
.names:
    ; As in ps_import: the alias starts at its own name, not at `from`.
    mov rdi, rbx
    call par_peek
    TOK_POS rax
    mov [rbp - PK_ALINE], rcx
    mov rdi, rbx
    call par_name_obj
    test rax, rax
    jz .fail
    mov [rbp - PK_A], rax
    mov qword [rbp - PK_B], 0
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_AS
    jne .make_alias
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call par_name_obj
    test rax, rax
    jz .fail
    mov [rbp - PK_B], rax
.make_alias:
    mov rdi, rbx
    mov esi, AST_ALIAS
    xor edx, edx
    mov rcx, [rbp - PK_ALINE]
    mov r8, [rbp - PK_A]
    mov r9, [rbp - PK_B]
    call ast_make
    ; Both halves are already mangled by par_name_obj, so the bound name is
    ; just the asname when there is one and the imported name otherwise.
    push rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - PK_B]
    test rdx, rdx
    jnz .from_bound_as
    mov rdx, [rbp - PK_A]
.from_bound_as:
    mov [rax + AstNode.c], edx
    pop rax
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    jne .close_names
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_RPAR
    je .close_names                     ; a trailing comma
    jmp .names
.close_names:
    test r12d, r12d
    jz .build
    mov rdi, rbx
    mov esi, TOK_RPAR
    CSTRING rdx, "'(' was never closed"
    call par_expect
    test eax, eax
    jz .fail
    jmp .build

.star_import:
    ; The alias is at the '*', not at `from` -- the same rule as a named one.
    mov rdi, rbx
    call par_peek
    TOK_POS rax
    mov [rbp - PK_ALINE], rcx
    mov rdi, rbx
    call par_advance
    ; A star import is an alias with no name at all; codegen recognises it by
    ; the empty child list plus the star flag.
    mov rdi, rbx
    mov esi, AST_ALIAS
    mov edx, 1                          ; subkind 1 marks the star form
    mov rcx, [rbp - PK_ALINE]
    xor r8d, r8d
    xor r9d, r9d
    call ast_make
    mov rdi, rbx
    mov rsi, rax
    call ast_push

.build:
    mov rdi, rbx
    mov esi, AST_IMPORTFROM
    mov rdx, [rbp - PK_LINE]
    mov rcx, [rbp - PK_MARK]
    call par_finish_list
    test rax, rax
    jz .fail
    mov [rbp - PK_NODE], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - PFR_MOD]
    mov [rax + AstNode.a], edx
    mov rdx, [rbp - PFR_LEVEL]
    mov [rax + AstNode.subkind], dl
    ; PEP 563: `from __future__ import annotations` changes how every
    ; annotation in the FILE is compiled, so it is recorded on the Comp the
    ; moment it is read.  A future import is an ordinary ImportFrom
    ; everywhere else, and still binds its names.
    mov rdi, rbx
    mov rsi, [rbp - PK_NODE]
    call ps_note_future
    mov rax, [rbp - PK_NODE]
    pop r12
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC ps_from

;; ============================================================================
;; ps_note_future(rdi = Comp*, rsi = an AST_IMPORTFROM node) -> nothing
;;
;; What `from __future__ import ...` means to the compiler.  Two things:
;;
;;   - `annotations` sets Comp.future_anno, which is PEP 563 and changes how
;;     every annotation in the file is compiled.  The other nine features are
;;     already the language's behaviour in 3.12, so naming one is a no-op --
;;     but naming something that is NOT one of the ten is a SyntaxError, and
;;     so is the star form, which has no feature name at all.  CPython's
;;     future.c refuses both, and this did neither: `from __future__ import *`
;;     compiled and bound whatever __all__ listed.
;;
;;   - barry_as_FLUFL sets a code flag inherited by later compile() calls.
;;     Lexing this source has already happened by the time we see the import.
;;
;; The level is checked too -- `from .__future__ import annotations` is a
;; relative import of a module that happens to be called that, and CPython
;; treats it as an ordinary one.
;; ============================================================================
PNF_COMP equ 8
PNF_NODE equ 16
PNF_I    equ 24
PNF_N    equ 32
PNF_NAME equ 40             ; the feature name being checked
PNF_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC_LOCAL ps_note_future, PNF_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - PNF_NODE], rsi

    mov rdi, rbx
    mov rsi, [rbp - PNF_NODE]
    call ast_at
    test rax, rax
    jz .pnf_done
    movzx ecx, byte [rax + AstNode.subkind]
    test ecx, ecx
    jnz .pnf_done                       ; a relative import, not __future__
    mov ecx, [rax + AstNode.nchild]
    mov [rbp - PNF_N], rcx
    mov ecx, [rax + AstNode.a]
    test ecx, ecx
    jz .pnf_done                        ; `from . import x` has no module
    mov rdi, rbx
    mov esi, ecx
    call ast_obj_at
    test rax, rax
    jz .pnf_done
    lea rdi, [rax + PyStrObject.data]
    CSTRING rsi, "__future__"
    call ap_strcmp
    test eax, eax
    jnz .pnf_done

    ; It is one, whatever it names -- so the window stays open for the next
    ; statement, and a late one is refused before any name is looked at.
    mov dword [rbx + Comp.future_here], 1
    cmp dword [rbx + Comp.future_shut], 0
    jne .pnf_late

    mov qword [rbp - PNF_I], 0
.pnf_loop:
    mov rax, [rbp - PNF_I]
    cmp rax, [rbp - PNF_N]
    jae .pnf_done
    mov rdi, rbx
    mov rsi, [rbp - PNF_NODE]
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - PNF_I]
    mov rdi, rbx
    call ast_child
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    test rax, rax
    jz .pnf_next
    mov ecx, [rax + AstNode.a]          ; the imported name
    test ecx, ecx
    jz .pnf_star                        ; `from __future__ import *`
    mov rdi, rbx
    mov esi, ecx
    call ast_obj_at
    test rax, rax
    jz .pnf_next
    mov [rbp - PNF_NAME], rax

    ; `braces` has had its own answer since 3.0 and is not "is not defined".
    lea rdi, [rax + PyStrObject.data]
    CSTRING rsi, "braces"
    call ap_strcmp
    test eax, eax
    jz .pnf_braces

    ; Every other name has to be one of the ten features.
    mov rax, [rbp - PNF_NAME]
    lea rdi, [rax + PyStrObject.data]
    lea rsi, [rel pnf_feature_names]
    call pnf_known
    test eax, eax
    jz .pnf_unknown

    mov rax, [rbp - PNF_NAME]
    lea rdi, [rax + PyStrObject.data]
    CSTRING rsi, "annotations"
    call ap_strcmp
    test eax, eax
    jnz .pnf_barry
    mov dword [rbx + Comp.future_anno], 1
    jmp .pnf_next
.pnf_barry:
    mov rax, [rbp - PNF_NAME]
    lea rdi, [rax + PyStrObject.data]
    CSTRING rsi, "barry_as_FLUFL"
    call ap_strcmp
    test eax, eax
    jnz .pnf_next
    mov dword [rbx + Comp.future_barry], CO_FUTURE_BARRY_AS_BDFL
.pnf_next:
    inc qword [rbp - PNF_I]
    jmp .pnf_loop
.pnf_done:
    pop rbx
    leave
    ret

.pnf_late:
    mov rdi, rbx
    mov esi, [rbp - PNF_NODE]
    CSTRING rdx, "from __future__ imports must occur at the beginning of the file"
    call comp_error_node
    pop rbx
    leave
    ret

.pnf_star:
    mov rdi, rbx
    mov esi, [rbp - PNF_NODE]
    CSTRING rdx, "future feature * is not defined"
    call comp_error_node
    pop rbx
    leave
    ret

.pnf_braces:
    ; CPython's own wording, and it has never been anything else.
    mov rdi, rbx
    mov esi, [rbp - PNF_NODE]
    CSTRING rdx, "not a chance"
    call comp_error_node
    pop rbx
    leave
    ret

.pnf_unknown:
    ; "future feature <name> is not defined", with the name in it.  The buffer
    ; is static because CompErr keeps the POINTER rather than a copy, so a
    ; stack one is freed before the message is ever read -- which showed as
    ; three bytes of stack garbage where the feature name belonged.
    TS_LEA rdi, ts_errbuf
    CSTRING rsi, "future feature "
    call pnf_append
    mov rdi, rax
    mov rax, [rbp - PNF_NAME]
    lea rsi, [rax + PyStrObject.data]
    call pnf_append
    mov rdi, rax
    CSTRING rsi, " is not defined"
    call pnf_append
    mov rdi, rbx
    mov esi, [rbp - PNF_NODE]
    TS_LEA rdx, ts_errbuf
    call comp_error_node
    pop rbx
    leave
    ret
END_FUNC ps_note_future

;; ============================================================================
;; pnf_known(rdi = a NUL-terminated name, rsi = a NUL-separated, NUL-NUL
;;           terminated list) -> eax = 1 when the name is in the list
;; ============================================================================
DEF_FUNC_LOCAL pnf_known, 8
    push rbx
    mov rbx, rdi
.pk_next:
    cmp byte [rsi], 0
    je .pk_no
    mov rdi, rbx
    push rsi
    call ap_strcmp
    pop rsi
    test eax, eax
    jz .pk_yes
    ; past this entry's NUL
.pk_skip:
    cmp byte [rsi], 0
    je .pk_skipped
    inc rsi
    jmp .pk_skip
.pk_skipped:
    inc rsi
    jmp .pk_next
.pk_yes:
    mov eax, 1
    pop rbx
    leave
    ret
.pk_no:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC pnf_known

;; ============================================================================
;; pnf_append(rdi = where to write, rsi = a C string) -> rax = the NUL
;; Bounded by pnf_buf's end; a feature name is an identifier and short, but
;; the bound is what keeps a long one from running past it.
;; ============================================================================
DEF_FUNC_LOCAL pnf_append
    mov rax, rdi
    TS_LEA rcx, ts_errbuf
    add rcx, PNF_BUFLEN - 1
.pa_loop:
    cmp rax, rcx
    jae .pa_done
    mov dl, [rsi]
    test dl, dl
    jz .pa_done
    mov [rax], dl
    inc rax
    inc rsi
    jmp .pa_loop
.pa_done:
    mov byte [rax], 0
    leave
    ret
END_FUNC pnf_append

section .bss
PNF_BUFLEN equ 128
pnf_buf: resb PNF_BUFLEN

section .rodata
; The ten, NUL-separated and NUL-NUL terminated.  CPython's __future__.py
; lists the same names in all_feature_names.
pnf_feature_names:
    db "nested_scopes", 0, "generators", 0, "division", 0
    db "absolute_import", 0, "with_statement", 0, "print_function", 0
    db "unicode_literals", 0, "barry_as_FLUFL", 0, "generator_stop", 0
    db "annotations", 0
    db 0
section .text



section .bss
; par_suite reads these, and the SUITE_FOR macros in compiler.inc write them
; -- which is any file with a compound statement in it, parse_try.asm included.
global psu_what
global psu_line
psu_what: resq 1
psu_line: resd 1
psu_pad:  resd 1
section .text

;; ============================================================================
;; psu_no_block(Comp *c) -> rax = 0, always
;;
;; "expected an indented block after <what> on line <n>", spanning the token
;; that turned up instead -- CPython covers the whole of it, not its first
;; character.
;; ============================================================================
PNB_COMP equ 8
PNB_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL psu_no_block, PNB_FRAME
    mov [rbp - PNB_COMP], rdi
    call comp_msg_start
    push rax
    mov rdi, rax
    CSTRING rsi, "expected an indented block"
    call comp_msg_cstr
    cmp qword [gs:ThreadState.ts_psu_what], 0
    je .pnb_done
    mov rdi, rax
    CSTRING rsi, " after "
    call comp_msg_cstr
    mov rdi, rax
    mov rsi, [gs:ThreadState.ts_psu_what]
    call comp_msg_cstr
    mov rdi, rax
    CSTRING rsi, " on line "
    call comp_msg_cstr
    mov rdi, rax
    mov esi, [gs:ThreadState.ts_psu_line]
    call comp_msg_i64
.pnb_done:
    pop rdx                     ; the message

    mov rdi, [rbp - PNB_COMP]
    push rdx
    call par_peek
    pop rdx
    mov ecx, [rax + Token.lineno]
    mov r8d, [rax + Token.col]
    mov r9d, ecx
    mov r10d, [rax + Token.len]
    add r10d, r8d               ; the end of the token, not the next column
    mov rdi, [rbp - PNB_COMP]
    lea rsi, [rel exc_SyntaxError_type]
    call comp_error_span
    xor eax, eax
    leave
    ret
END_FUNC psu_no_block

;; ============================================================================
;; par_suite(Comp *c) -> rax = an AST_BLOCK node, 0 on error
;;
;; Either `: stmt; stmt` on one line, or `: NEWLINE INDENT stmts DEDENT`.  The
;; block node exists so an empty `else` and a missing one stay distinguishable:
;; node 0 means there was no clause at all.
;; ============================================================================
PSU_MARK  equ 16
PSU_LINE  equ 24
PSU_HARD  equ 32          ; the caller is at a grammar cut
PSU_FRAME equ 40          ; + 1 push = 48
DEF_FUNC par_suite, PSU_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PSU_LINE], rcx

    ; A missing colon and a LEFTOVER token are different errors: `if 1\n` is
    ; "expected ':'", `if 1 2:` is plain "invalid syntax".  A NEWLINE is what
    ; separates the two.  esi = 1 says the caller is at a grammar CUT -- `try`
    ; and `def` commit to the colon -- and keeps the first message either way.
    mov [rbp - PSU_HARD], rsi
    mov rdi, rbx
    call par_kind
    CSTRING rdx, "expected ':'"
    cmp qword [rbp - PSU_HARD], 0
    jne .psu_have_msg
    cmp eax, TOK_NEWLINE
    je .psu_have_msg
    cmp eax, TOK_ENDMARKER
    je .psu_have_msg
    CSTRING rdx, "invalid syntax"
.psu_have_msg:
    mov rdi, rbx
    mov esi, TOK_COLON
    call par_expect
    test eax, eax
    jz .fail
    ; `for x in y:  # type: int` -- the comment belongs to the statement, and
    ; the statement's node does not exist yet.
    mov rdi, rbx
    call ast_park_typecomment

    mov rdi, rbx
    call ast_mark
    mov [rbp - PSU_MARK], rax

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NEWLINE
    je .block

    ; A one-line suite: `if x: a; b`
    mov rdi, rbx
    call par_simple_stmts
    test eax, eax
    jz .fail
    jmp .done

.block:
    mov rdi, rbx
    call par_advance                    ; the NEWLINE
    ; A `# type:` comment on its own line sits between the NEWLINE and the
    ; INDENT, and belongs to the statement whose suite this is.  Only the
    ; first is taken, so an inline one on the header wins -- as CPython's
    ; grammar makes it.
    mov rdi, rbx
    call ast_park_typecomment
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_INDENT
    je .have_indent
    mov rdi, rbx
    call psu_no_block
    jmp .fail
.have_indent:
    mov rdi, rbx
    call par_advance
.stmts:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_DEDENT
    je .end_block
    cmp eax, TOK_ENDMARKER
    je .end_block
    cmp eax, TOK_NEWLINE
    jne .one
    mov rdi, rbx
    call par_advance
    jmp .stmts
.one:
    mov rdi, rbx
    call par_statement_any
    test eax, eax
    jz .fail
    jmp .stmts
.end_block:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_ENDMARKER
    je .done
    mov rdi, rbx
    call par_advance                    ; the DEDENT

.done:
    mov rdi, rbx
    mov esi, AST_BLOCK
    mov rdx, [rbp - PSU_LINE]
    mov rcx, [rbp - PSU_MARK]
    call par_finish_list
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_suite

;; ============================================================================
;; par_statement_any(Comp *c) -> rax = 1 ok, 0 error
;; One statement, compound or simple, pushed onto the pending stack.  A
;; compound statement is a whole logical unit and consumes its own NEWLINEs; a
;; simple one is part of a `;`-separated line.
;; ============================================================================
DEF_FUNC par_statement_any, 8
    push rbx
    mov rbx, rdi
    call par_kind
    cmp eax, TOK_IF
    je .compound
    cmp eax, TOK_WHILE
    je .compound
    cmp eax, TOK_FOR
    je .compound
    cmp eax, TOK_DEF
    je .compound
    cmp eax, TOK_TRY
    je .compound
    cmp eax, TOK_WITH
    je .compound
    cmp eax, TOK_CLASS
    je .compound
    cmp eax, TOK_AT
    je .compound
    cmp eax, TOK_ASYNC
    je .compound
    ; `match` is a soft keyword: an ordinary name everywhere but here.
    cmp eax, TOK_NAME
    jne .simple
    mov rdi, rbx
    call par_looks_like_match
    test eax, eax
    jnz .compound
.simple:
    mov rdi, rbx
    call par_simple_stmts
    pop rbx
    leave
    ret
.compound:
    ; A compound statement is never a future import and never a docstring, so
    ; it shuts the window -- before its body is parsed, which is what refuses
    ; one written inside a def at the top of a file.
    mov dword [rbx + Comp.future_shut], 1
    mov rdi, rbx
    call par_statement
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    mov eax, 1
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_statement_any

;; ============================================================================
;; ps_if - `if`, `elif` chains and `else`
;; An `elif` is parsed as an `if` nested inside the outer one's else block,
;; which is what makes an arbitrarily long chain need no special handling in
;; either the parser or the code generator.
;; ============================================================================
PIF_LINE  equ 16
PIF_TEST  equ 24
PIF_BODY  equ 32
PIF_ELSE  equ 40
PIF_NODE  equ 48
PIF_MARK  equ 56
PIF_FRAME equ 56          ; + 1 push = 64
DEF_FUNC_LOCAL ps_if, PIF_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PIF_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; `if` or `elif`

    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PIF_TEST], rax

    SUITE_FOR "'if' statement", dword [rbp - PIF_LINE]
    mov rdi, rbx
    xor esi, esi
    call par_suite
    test rax, rax
    jz .fail
    mov [rbp - PIF_BODY], rax
    mov qword [rbp - PIF_ELSE], 0

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_ELIF
    je .elif
    cmp eax, TOK_ELSE
    jne .build

    SUITE_FOR_HERE "'else' statement"
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    xor esi, esi
    call par_suite
    test rax, rax
    jz .fail
    mov [rbp - PIF_ELSE], rax
    jmp .build

.elif:
    ; Wrap the nested `if` in a block so the else branch has a uniform shape.
    mov rdi, rbx
    call ast_mark
    mov [rbp - PIF_MARK], rax
    mov rdi, rbx
    call ps_if
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    mov rdi, rbx
    mov esi, AST_BLOCK
    mov rdx, [rbp - PIF_LINE]
    mov rcx, [rbp - PIF_MARK]
    call par_finish_list
    test rax, rax
    jz .fail
    mov [rbp - PIF_ELSE], rax

.build:
    mov rdi, rbx
    mov esi, AST_IF
    xor edx, edx
    mov rcx, [rbp - PIF_LINE]
    mov r8, [rbp - PIF_TEST]
    mov r9, [rbp - PIF_ELSE]
    call ast_make
    mov [rbp - PIF_NODE], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - PIF_BODY]
    mov [rax + AstNode.c], edx
    mov rax, [rbp - PIF_NODE]
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ps_if

;; ============================================================================
;; ps_while - `while test: body [else: body]`
;; ============================================================================
DEF_FUNC_LOCAL ps_while, PIF_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PIF_LINE], rcx
    mov rdi, rbx
    call par_advance

    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PIF_TEST], rax

    SUITE_FOR "'while' statement", dword [rbp - PIF_LINE]
    mov rdi, rbx
    xor esi, esi
    call par_suite
    test rax, rax
    jz .fail
    mov [rbp - PIF_BODY], rax
    mov qword [rbp - PIF_ELSE], 0

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_ELSE
    jne .build
    SUITE_FOR_HERE "'else' statement"
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    xor esi, esi
    call par_suite
    test rax, rax
    jz .fail
    mov [rbp - PIF_ELSE], rax

.build:
    mov rdi, rbx
    mov esi, AST_WHILE
    xor edx, edx
    mov rcx, [rbp - PIF_LINE]
    mov r8, [rbp - PIF_TEST]
    mov r9, [rbp - PIF_ELSE]
    call ast_make
    mov [rbp - PIF_NODE], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - PIF_BODY]
    mov [rax + AstNode.c], edx
    mov rax, [rbp - PIF_NODE]
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ps_while

;; ============================================================================
;; ps_for - `for target in iter: body [else: body]`
;; The target is parsed as an expression and re-marked, exactly as an
;; assignment target is -- `for a, b in pairs` unpacks for the same reason
;; `a, b = pair` does.
;; ============================================================================
DEF_FUNC_LOCAL ps_for, PIF_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PIF_LINE], rcx
    mov rdi, rbx
    call par_advance

    mov rdi, rbx
    call par_for_target
    test rax, rax
    jz .fail
    mov [rbp - PIF_TEST], rax           ; the target

    mov rdi, rbx
    mov esi, TOK_IN
    CSTRING rdx, "expected 'in' after the loop target"
    call par_expect
    test eax, eax
    jz .fail

    mov rdi, rbx
    call par_exprlist_stmt              ; `for x in a, b` iterates the tuple
    test rax, rax
    jz .fail
    mov [rbp - PIF_NODE], rax           ; the iterable

    SUITE_FOR "'for' statement", dword [rbp - PIF_LINE]
    mov rdi, rbx
    xor esi, esi
    call par_suite
    test rax, rax
    jz .fail
    mov [rbp - PIF_BODY], rax
    mov qword [rbp - PIF_ELSE], 0

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_ELSE
    jne .build
    SUITE_FOR_HERE "'else' statement"
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    xor esi, esi
    call par_suite
    test rax, rax
    jz .fail
    mov [rbp - PIF_ELSE], rax

.build:
    mov rdi, rbx
    mov esi, AST_FOR
    xor edx, edx
    mov rcx, [rbp - PIF_LINE]
    mov r8, [rbp - PIF_TEST]            ; a = target
    mov r9, [rbp - PIF_NODE]            ; b = iterable
    call ast_make
    mov [rbp - PIF_MARK], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - PIF_BODY]
    mov [rax + AstNode.c], edx          ; c = body block
    mov rdx, [rbp - PIF_ELSE]
    mov [rax + AstNode.clist], edx      ; clist doubles as the else block here
    mov rdi, rbx
    mov rsi, [rbp - PIF_MARK]
    call ast_claim_typecomment
    mov rax, [rbp - PIF_MARK]
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ps_for

;; ============================================================================
;; par_for_target(Comp *c) -> node, marked for storing
;; Stops at `in`, which par_expr would otherwise take as a comparison.
;; ============================================================================
PFT_FIRST equ 16
PFT_LINE  equ 24
PFT_MARK  equ 32
PFT_FRAME equ 40          ; + 1 push = 48
DEF_FUNC par_for_target, PFT_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PFT_LINE], rcx

    mov rdi, rbx
    mov esi, BP_COMPARE                 ; above `in`, so the loop keyword ends it
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PFT_FIRST], rax

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    jne .single

    mov rdi, rbx
    call ast_mark
    mov [rbp - PFT_MARK], rax
    mov rdi, rbx
    mov rsi, [rbp - PFT_FIRST]
    call ast_push
.loop:
    mov rdi, rbx
    call par_advance                    ; the comma
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_IN
    je .close
    mov rdi, rbx
    mov esi, BP_COMPARE
    call par_expr
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    je .loop
.close:
    mov rdi, rbx
    mov esi, AST_TUPLE
    mov rdx, [rbp - PFT_LINE]
    mov rcx, [rbp - PFT_MARK]
    call par_finish_list
    test rax, rax
    jz .fail
    mov [rbp - PFT_FIRST], rax
.single:
    mov rdi, rbx
    mov rsi, [rbp - PFT_FIRST]
    mov edx, CTX_STORE
    call ast_set_ctx
    test eax, eax
    jz .bad
    mov rax, [rbp - PFT_FIRST]
    pop rbx
    leave
    ret
.bad:
    mov rdi, rbx
    CSTRING rsi, "cannot assign to that loop target"
    call par_syntax_error
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_for_target

;; ============================================================================
;; par_params(Comp *c, int close) -> rax = an AST_ARGUMENTS node, 0 on error
;;
;; The child list holds the positional parameters followed by the keyword-only
;; ones -- the order co_varnames needs -- while `*args` and `**kwargs` hang off
;; .b and .c.  They cannot go in the list: localsplus puts them after the
;; keyword-only slots, and func_call finds them by arithmetic on co_argcount
;; and co_kwonlyargcount rather than by searching.
;;
;;   .a      an AST_EXTRA node carrying argcount / posonly / kwonly
;;   .b      the *args parameter, or 0
;;   .c      the **kwargs parameter, or 0
;;   .clist  positional parameters, then keyword-only ones
;; ============================================================================
PP_CLOSE  equ 16
PP_LINE   equ 24
PP_MARK   equ 32
PP_NPOS   equ 40
PP_NKW    equ 48
PP_POSONLY equ 56
PP_STAR   equ 64
PP_VARARG equ 72
PP_VARKW  equ 80
PP_NODE   equ 88
PP_DEFLT  equ 96          ; have we passed a parameter with a default?
PP_BAD    equ 104         ; the parameter an error is about
PP_FRAME  equ 120         ; + 1 push = 128, 16-aligned
DEF_FUNC par_params, PP_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - PP_CLOSE], rsi
    call par_peek
    TOK_POS rax
    mov [rbp - PP_LINE], rcx
    mov rdi, rbx
    call ast_mark
    mov [rbp - PP_MARK], rax
    mov qword [rbp - PP_NPOS], 0
    mov qword [rbp - PP_NKW], 0
    mov qword [rbp - PP_POSONLY], 0
    mov qword [rbp - PP_STAR], 0        ; have we passed the * marker?
    mov qword [rbp - PP_VARARG], 0
    mov qword [rbp - PP_VARKW], 0
    mov qword [rbp - PP_DEFLT], 0
    mov qword [rbp - PP_BAD], 0

.loop:
    mov rdi, rbx
    call par_kind
    cmp rax, [rbp - PP_CLOSE]
    je .build
    cmp eax, TOK_ENDMARKER
    je .build

    ; `**kwargs` is the last thing a parameter list may hold.
    cmp qword [rbp - PP_VARKW], 0
    je .not_after_varkw
    CSTRING rdx, "arguments cannot follow var-keyword argument"
    jmp .param_error
.not_after_varkw:
    cmp eax, TOK_SLASH
    je .posonly_marker
    cmp eax, TOK_STAR
    je .star_marker
    cmp eax, TOK_DOUBLESTAR
    je .varkw

    ; An ordinary parameter.
    mov rdi, rbx
    mov esi, 1
    cmp qword [rbp - PP_CLOSE], TOK_COLON
    jne .ann_ok1
    xor esi, esi
.ann_ok1:
    call par_param_here
    test rax, rax
    jz .fail
    mov [rbp - PP_BAD], rax
    push rax
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rbp - PP_MARK]
    mov rcx, [rbp - PP_VARARG]
    mov r8, [rbp - PP_VARKW]
    call pp_duplicate
    test rax, rax
    jnz .dup_param
    pop rsi
    push rsi
    mov rdi, rbx
    call ast_push
    pop rsi
    cmp qword [rbp - PP_STAR], 0
    je .count_pos
    inc qword [rbp - PP_NKW]
    jmp .comma
.count_pos:
    ; A default makes every positional parameter after it optional, so one
    ; without a default cannot follow.  Keyword-only parameters are exempt:
    ; `def f(*, a=1, b)` is legal, because they are named at the call.
    mov rdi, rbx
    mov rsi, [rbp - PP_BAD]
    call ast_at
    cmp dword [rax + AstNode.c], 0
    je .no_default
    mov qword [rbp - PP_DEFLT], 1
    jmp .counted
.no_default:
    cmp qword [rbp - PP_DEFLT], 0
    je .counted
    CSTRING rdx, "parameter without a default follows parameter with a default"
    jmp .param_error_prev
.counted:
    inc qword [rbp - PP_NPOS]
    jmp .comma

.dup_param:
    ; "duplicate argument 'a' in function definition", blamed at the repeat.
    ; rax is the name pp_duplicate found, a str in the object arena.
    push rax
    call comp_msg_start
    push rax                    ; the buffer, which becomes the message
    mov rdi, rax
    CSTRING rsi, "duplicate argument '"
    call comp_msg_cstr
    mov rdi, rax
    mov rsi, [rsp + 8]
    add rsi, PyStrObject.data
    call comp_msg_cstr
    mov rdi, rax
    CSTRING rsi, "' in function definition"
    call comp_msg_cstr
    pop rdx                     ; the message
    add rsp, 8                  ; the name
    jmp .param_error_prev

.posonly_marker:
    ; `/` marks the end of the positional-only run, so it cannot come after
    ; the `*` that ends the positional one.
    cmp qword [rbp - PP_STAR], 0
    je .posonly_ok
    CSTRING rdx, "/ must be ahead of *"
    jmp .param_error
.posonly_ok:
    ; Everything so far was positional-any.
    mov rax, [rbp - PP_NPOS]
    mov [rbp - PP_POSONLY], rax
    mov rdi, rbx
    call par_advance
    jmp .comma

.star_marker:
    mov rdi, rbx
    call par_advance
    mov qword [rbp - PP_STAR], 1
    ; A bare `*` only separates; `*args` also collects.
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    je .comma
    cmp rax, [rbp - PP_CLOSE]
    je .build
    ; 2, not 1: this is the *args parameter, and PEP 646 lets ITS annotation
    ; be starred -- `def g(*rest: *Ts)` -- where no other parameter's may be.
    mov rdi, rbx
    mov esi, 2
    cmp qword [rbp - PP_CLOSE], TOK_COLON
    jne .ann_ok2
    xor esi, esi
.ann_ok2:
    call par_param_here
    test rax, rax
    jz .fail
    mov [rbp - PP_BAD], rax
    push rax
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rbp - PP_MARK]
    xor ecx, ecx
    mov r8, [rbp - PP_VARKW]
    call pp_duplicate
    pop rcx
    test rax, rax
    jnz .dup_param
    mov [rbp - PP_VARARG], rcx
    jmp .comma

.varkw:
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov esi, 1
    cmp qword [rbp - PP_CLOSE], TOK_COLON
    jne .ann_ok3
    xor esi, esi
.ann_ok3:
    call par_param_here
    test rax, rax
    jz .fail
    mov [rbp - PP_BAD], rax
    push rax
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rbp - PP_MARK]
    mov rcx, [rbp - PP_VARARG]
    xor r8d, r8d
    call pp_duplicate
    pop rcx
    test rax, rax
    jnz .dup_param
    mov [rbp - PP_VARKW], rcx
    jmp .comma

.comma:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    jne .build
    mov rdi, rbx
    call par_advance
    ; `def g(a,  # type: int` -- the comment follows the comma and belongs to
    ; the parameter before it, which PP_BAD is already holding.
    cmp qword [rbp - PP_BAD], 0
    je .comma_no_tc
    mov rdi, rbx
    mov rsi, [rbp - PP_BAD]
    call ast_take_typecomment
.comma_no_tc:
    jmp .loop

.build:
    ; A bare `*` separates the positional parameters from the keyword-only
    ; ones, so there has to BE a keyword-only one: `def f(*): pass` is a
    ; SyntaxError, and was accepted here.
    cmp qword [rbp - PP_STAR], 0
    je .build_ok
    cmp qword [rbp - PP_VARARG], 0
    jne .build_ok
    cmp qword [rbp - PP_NKW], 0
    jne .build_ok
    CSTRING rdx, "named arguments must follow bare *"
    jmp .param_error
.build_ok:
    mov rdi, rbx
    mov esi, AST_ARGUMENTS
    mov rdx, [rbp - PP_LINE]
    mov rcx, [rbp - PP_MARK]
    call par_finish_list
    test rax, rax
    jz .fail
    mov [rbp - PP_NODE], rax

    ; The counts live on an auxiliary node: five fields are not enough.
    mov rdi, rbx
    mov esi, AST_EXTRA
    xor edx, edx
    mov rcx, [rbp - PP_LINE]
    mov r8, [rbp - PP_NPOS]
    mov r9, [rbp - PP_POSONLY]
    call ast_make
    mov rsi, rax
    push rsi
    mov rdi, rbx
    call ast_at
    pop rsi
    mov rdx, [rbp - PP_NKW]
    mov [rax + AstNode.c], edx

    mov rdi, rbx
    push rsi
    mov rsi, [rbp - PP_NODE]
    call ast_at
    pop rsi
    mov [rax + AstNode.a], esi
    mov rdx, [rbp - PP_VARARG]
    mov [rax + AstNode.b], edx
    mov rdx, [rbp - PP_VARKW]
    mov [rax + AstNode.c], edx

    mov rax, [rbp - PP_NODE]
    pop rbx
    leave
    ret
;; rdx = the message, PP_BAD = the parameter it is about.  The parser is
;; already past that parameter, and CPython blames the parameter itself, so
;; the position comes off its node rather than off the cursor.
.param_error_prev:
    push rdx
    mov rdi, rbx
    mov rsi, [rbp - PP_BAD]
    call ast_at
    mov r8d, [rax + AstNode.col]
    mov ecx, [rax + AstNode.lineno]
    pop rdx
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    call comp_error
    jmp .fail

;; rdx = the message.  CPython blames the token the list has reached, and
;; gives it a one-character span, which is comp_error's default.
.param_error:
    push rdx
    mov rdi, rbx
    call par_peek
    mov r8d, [rax + Token.col]
    mov ecx, [rax + Token.lineno]
    pop rdx
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    call comp_error
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_params

;; ============================================================================
;; pp_duplicate(rdi = Comp*, rsi = a new AST_ARG node, rdx = the pending-stack
;;              mark, rcx = the *args node or 0, r8 = the **kwargs node or 0)
;;   -> rax = the name str it repeats, or 0
;;
;; `def f(a, a)` is a SyntaxError, and every name in the list counts -- the
;; starred ones included, so `def f(a, *a)` is one too.  The comparison is on
;; the characters: the object arena holds a str per occurrence rather than one
;; per distinct name, so two `a`s are two objects.
;; ============================================================================
PD_COMP   equ 8
PD_NAME   equ 16
PD_MARK   equ 24
PD_VARARG equ 32
PD_VARKW  equ 40
PD_I      equ 48
PD_FRAME  equ 48            ; + 2 pushes = 64, 16-aligned
DEF_FUNC_LOCAL pp_duplicate, PD_FRAME
    push rbx
    push r12
    mov rbx, rdi
    mov [rbp - PD_COMP], rdi
    mov [rbp - PD_MARK], rdx
    mov [rbp - PD_VARARG], rcx
    mov [rbp - PD_VARKW], r8

    mov rdi, rbx
    call ast_at
    mov esi, [rax + AstNode.a]
    mov rdi, rbx
    call ast_obj_at
    mov r12, rax                        ; the new parameter's name
    mov [rbp - PD_NAME], rax

    mov rcx, [rbp - PD_VARARG]
    test rcx, rcx
    jz .pd_no_vararg
    mov rsi, rcx
    call .pd_name_of
    call .pd_same
    test eax, eax
    jnz .pd_found
.pd_no_vararg:
    mov rcx, [rbp - PD_VARKW]
    test rcx, rcx
    jz .pd_no_varkw
    mov rsi, rcx
    call .pd_name_of
    call .pd_same
    test eax, eax
    jnz .pd_found
.pd_no_varkw:
    mov rax, [rbp - PD_MARK]
    mov [rbp - PD_I], rax
.pd_loop:
    mov rdi, [rbp - PD_COMP]
    mov rcx, [rbp - PD_I]
    cmp rcx, [rdi + Comp.pending + Buf.len]
    jge .pd_none
    mov rax, [rdi + Comp.pending + Buf.data]
    mov esi, [rax + rcx*4]
    call .pd_name_of
    call .pd_same
    test eax, eax
    jnz .pd_found
    inc qword [rbp - PD_I]
    jmp .pd_loop

.pd_found:
    mov rax, [rbp - PD_NAME]
    pop r12
    pop rbx
    leave
    ret
.pd_none:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

; Local: is the str in rax the same NAME as the one in r12?  The arena holds
; one object per occurrence, not one per distinct name, so this compares the
; characters.
.pd_same:
    test rax, rax
    jz .pd_same_no
    lea rdi, [rax + PyStrObject.data]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jnz .pd_same_no
    mov eax, 1
    ret
.pd_same_no:
    xor eax, eax
    ret

; Local: the name object of the AST_ARG node whose index is in esi.
.pd_name_of:
    mov rdi, [rbp - PD_COMP]
    call ast_at
    mov esi, [rax + AstNode.a]
    mov rdi, [rbp - PD_COMP]
    call ast_obj_at
    ret
END_FUNC pp_duplicate

;; ============================================================================
;; par_one_param(Comp *c) -> rax = an AST_ARG node, 0 on error
;;   .a = the name, .b = its annotation node, .c = its default expression
;; ============================================================================
POP_LINE  equ 16
POP_NAME  equ 24
POP_ANN   equ 32
POP_DEF   equ 40
POP_NODE  equ 48
POP_END   equ 56          ; the token cursor where the parameter itself ends
POP_FRAME equ 72          ; + 3 pushes = 96, 16-aligned
DEF_FUNC par_one_param, POP_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi                        ; 0 none, 1 allowed, 2 star allowed
    call par_peek
    TOK_POS rax
    mov [rbp - POP_LINE], rcx
    mov qword [rbp - POP_ANN], 0
    mov qword [rbp - POP_DEF], 0

    mov rdi, rbx
    call par_name_obj
    test rax, rax
    jz .fail
    mov [rbp - POP_NAME], rax

    ; A lambda's parameter list is terminated by a colon, so a colon there is
    ; the end of the list rather than an annotation -- and lambda parameters
    ; cannot be annotated at all.
    test r12, r12
    jz .no_ann
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COLON
    jne .no_ann
    mov rdi, rbx
    call par_advance

    ; PEP 646: the *args parameter's annotation may itself be starred, and
    ; `*Ts` is the whole reason a TypeVarTuple exists.  par_expr will not
    ; take a leading `*`, so the star is consumed here and the expression
    ; wrapped, exactly as CPython's star_annotation rule has it.
    xor r13d, r13d
    cmp r12, 2
    jne .ann_expr
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_STAR
    jne .ann_expr
    mov rdi, rbx
    call par_advance
    mov r13d, 1
.ann_expr:
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    test r13d, r13d
    jz .ann_plain
    mov r8d, eax                        ; a = the expression
    mov rdi, rbx
    mov esi, AST_STARRED
    xor edx, edx
    mov rcx, [rbp - POP_LINE]
    xor r9d, r9d
    call ast_make
    test rax, rax
    jz .fail
.ann_plain:
    mov [rbp - POP_ANN], rax
.no_ann:
    ; A parameter ends at its name, or at its annotation; the default that
    ; may follow is not part of it, and this node is not made until after it
    ; has been parsed.
    mov eax, [rbx + Comp.tok_idx]
    mov [rbp - POP_END], rax
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_EQUAL
    jne .build
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - POP_DEF], rax

.build:
    mov rdi, rbx
    mov esi, AST_ARG
    xor edx, edx
    mov rcx, [rbp - POP_LINE]
    mov r8, [rbp - POP_NAME]
    mov r9, [rbp - POP_ANN]
    call ast_make
    mov [rbp - POP_NODE], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - POP_DEF]
    mov [rax + AstNode.c], edx
    mov rdi, rbx
    mov rsi, [rbp - POP_NODE]
    mov edx, [rbp - POP_END]
    call ast_end_at
    mov rax, [rbp - POP_NODE]
    pop r13
    pop r12
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC par_one_param

;; ============================================================================
;; par_param_here(Comp *c) -> one parameter, annotations allowed only when the
;; list is not a lambda's.  par_params keeps the terminator in PP_CLOSE, and a
;; colon terminator means a lambda.
;; ============================================================================
DEF_FUNC_BARE par_param_here
    ; PP_CLOSE lives in the caller's frame; par_params passes it through rsi.
    jmp par_one_param
END_FUNC par_param_here

;; ============================================================================
;; ps_def - `def name(params) [-> ann]: body`
;;   .a = the name, .b = the AST_ARGUMENTS node, .clist = the body statements
;; ============================================================================
PDF_LINE  equ 16
PDF_NAME  equ 24
PDF_ARGS  equ 32
PDF_MARK  equ 40
PDF_NODE  equ 48
PDF_RET   equ 56          ; the return annotation, kept but never generated
PDF_TP    equ 64          ; the PEP 695 type parameters, likewise
PDF_ARROW equ 72          ; the `->`'s line and column, for "expected ':'"
PDF_FRAME equ 88          ; + 1 push = 96, 16-aligned
DEF_FUNC_LOCAL ps_def, PDF_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PDF_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; `def`

    mov rdi, rbx
    call par_name_obj
    test rax, rax
    jz .fail
    mov [rbp - PDF_NAME], rax

    mov rdi, rbx
    lea rsi, [rbp - PDF_TP]
    call par_type_params
    test eax, eax
    jz .fail

    mov rdi, rbx
    mov esi, TOK_LPAR
    CSTRING rdx, "expected '(' after the function name"
    call par_expect
    test eax, eax
    jz .fail
    mov rdi, rbx
    mov esi, TOK_RPAR
    call par_params
    test rax, rax
    jz .fail
    mov [rbp - PDF_ARGS], rax
    mov rdi, rbx
    mov esi, TOK_RPAR
    CSTRING rdx, "'(' was never closed"
    call par_expect
    test eax, eax
    jz .fail

    ; `.c` is the return annotation.  cg_annotations emits it under the name
    ; "return", sym_visit_defaults classifies the names in it -- both in the
    ; enclosing scope, where it is evaluated -- and `_ast` reports it as
    ; `returns`.
    mov qword [rbp - PDF_RET], 0
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_RARROW
    jne .suite
    ; `def f(x) -> : pass` -- CPython treats the whole `-> expr` as optional
    ; and, finding no expression, asks for the colon AT THE ARROW rather than
    ; blaming whatever followed it.
    mov rdi, rbx
    call par_peek
    mov ecx, [rax + Token.lineno]
    mov [rbp - PDF_ARROW], ecx
    mov ecx, [rax + Token.col]
    mov [rbp - PDF_ARROW + 4], ecx
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COLON
    jne .pdf_ann
    mov ecx, [rbp - PDF_ARROW]
    mov r8d, [rbp - PDF_ARROW + 4]
    mov r9d, ecx
    lea r10d, [r8d + 2]                 ; the arrow is two characters
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    CSTRING rdx, "expected ':'"
    call comp_error_span
    jmp .fail
.pdf_ann:
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PDF_RET], rax

.suite:
    ; The body is collected directly into the def's own child list.
    mov rdi, rbx
    call ast_mark
    mov [rbp - PDF_MARK], rax
    SUITE_FOR "function definition", dword [rbp - PDF_LINE]
    mov rdi, rbx
    mov esi, 1
    call par_suite_into
    test eax, eax
    jz .fail

    mov rdi, rbx
    mov esi, AST_FUNCTIONDEF
    mov rdx, [rbp - PDF_LINE]
    mov rcx, [rbp - PDF_MARK]
    call par_finish_list
    test rax, rax
    jz .fail
    mov [rbp - PDF_NODE], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - PDF_NAME]
    mov [rax + AstNode.a], edx
    mov rdx, [rbp - PDF_ARGS]
    mov [rax + AstNode.b], edx
    mov rdx, [rbp - PDF_RET]
    mov [rax + AstNode.c], edx
    ; The type parameters go in the side table: every field is spoken for.
    mov rdi, rbx
    mov esi, [rbp - PDF_NODE]
    mov edx, [rbp - PDF_TP]
    call ast_set_typeparams
    mov rdi, rbx
    mov rsi, [rbp - PDF_NODE]
    call ast_claim_typecomment
    mov rax, [rbp - PDF_NODE]
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ps_def

;; ============================================================================
;; par_suite_into(Comp *c) -> rax = 1 ok, 0 error
;; Like par_suite, but pushes the statements onto the caller's pending list
;; instead of wrapping them in a block node.
;; ============================================================================
PSI_HARD  equ 8
PSI_FRAME equ 24          ; + 1 push = 32, 16-aligned
DEF_FUNC par_suite_into, PSI_FRAME
    push rbx
    mov rbx, rdi
    ; par_suite's two errors and its cut flag.
    mov [rbp - PSI_HARD], rsi
    call par_kind
    CSTRING rdx, "expected ':'"
    cmp qword [rbp - PSI_HARD], 0
    jne .psi_have_msg
    cmp eax, TOK_NEWLINE
    je .psi_have_msg
    cmp eax, TOK_ENDMARKER
    je .psi_have_msg
    CSTRING rdx, "invalid syntax"
.psi_have_msg:
    mov rdi, rbx
    mov esi, TOK_COLON
    call par_expect
    test eax, eax
    jz .fail
    ; `for x in y:  # type: int` -- the comment belongs to the statement, and
    ; the statement's node does not exist yet.
    mov rdi, rbx
    call ast_park_typecomment
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NEWLINE
    je .block
    mov rdi, rbx
    call par_simple_stmts
    pop rbx
    leave
    ret
.block:
    mov rdi, rbx
    call par_advance
    ; A `# type:` comment on its own line sits between the NEWLINE and the
    ; INDENT, and belongs to the statement whose suite this is.  Only the
    ; first is taken, so an inline one on the header wins -- as CPython's
    ; grammar makes it.
    mov rdi, rbx
    call ast_park_typecomment
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_INDENT
    je .have_indent
    mov rdi, rbx
    call psu_no_block
    jmp .fail
.have_indent:
    mov rdi, rbx
    call par_advance
.stmts:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_DEDENT
    je .close
    cmp eax, TOK_ENDMARKER
    je .close
    cmp eax, TOK_NEWLINE
    jne .one
    mov rdi, rbx
    call par_advance
    jmp .stmts
.one:
    mov rdi, rbx
    call par_statement_any
    test eax, eax
    jz .fail
    jmp .stmts
.close:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_ENDMARKER
    je .ok
    mov rdi, rbx
    call par_advance
.ok:
    mov eax, 1
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_suite_into

;; ============================================================================
;; ps_async(Comp *c) -> node   -- `async def`, `async for`, `async with`
;;
;; `async` only ever prefixes one of three statements, and each of the three
;; already has a parser.  So consume the keyword, run the ordinary parser, and
;; stamp subkind=1 on what comes back; every consumer of AST_FUNCTIONDEF,
;; AST_FOR and AST_WITH reads that one bit rather than a parallel node kind.
;; ============================================================================
PAS_LINE  equ 8           ; the `async` keyword's own position
PAS_FRAME equ 24          ; + 1 push = 32
DEF_FUNC_LOCAL ps_async, PAS_FRAME
    push rbx
    mov rbx, rdi
    mov rdi, rbx
    call par_peek
    TOK_POS rax
    mov [rbp - PAS_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; `async`

    mov rdi, rbx
    call par_kind
    mov rdi, rbx
    cmp eax, TOK_DEF
    je .def
    cmp eax, TOK_FOR
    je .for
    cmp eax, TOK_WITH
    je .with

    mov rdi, rbx
    CSTRING rsi, "expected 'def', 'for' or 'with' after 'async'"
    call par_syntax_error
    xor eax, eax
    pop rbx
    leave
    ret

.def:
    call ps_def
    jmp .stamp
.for:
    call ps_for
    jmp .stamp
.with:
    call ps_with
.stamp:
    test rax, rax
    jz .done
    push rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov byte [rax + AstNode.subkind], 1
    ; The statement begins at `async`, not at the `def`/`for`/`with` that the
    ; inner parser saw first.
    mov rcx, [rbp - PAS_LINE]
    mov [rax + AstNode.lineno], ecx
    shr rcx, 32
    mov [rax + AstNode.col], ecx
    pop rax
.done:
    pop rbx
    leave
    ret
END_FUNC ps_async

;; ============================================================================
;; par_type_params(Comp *c, uint32_t *out) -> rax = 1 ok, 0 error
;;
;; PEP 695's `def f[T](...)`, `class C[T]:` and `type X[T] = ...`.
;;
;;   type_params: '[' type_param (',' type_param)* [','] ']'
;;   type_param:  NAME [':' expression] | '*' NAME | '**' NAME
;;
;; *out is an AST_TYPEPARAMS node, or 0 when there were no brackets.  The
;; parameters are parsed and then ignored by everything downstream: a type
;; parameter is visible only to annotations, and annotations are not evaluated
;; here at all -- op_make_function pops and discards them -- so there is
;; nothing for the names to be bound for.  What the tree says is the point:
;; this was a bracket-depth token skipper that interned nothing, so
;; `type X = int` was indistinguishable from `X = int` in the AST, and
;; `def f[1, +]()` was accepted.
;; ============================================================================
PTP_OUT   equ 8
PTP_MARK  equ 16
PTP_LINE  equ 24
PTP_NAME  equ 32
PTP_ILINE equ 40          ; where the item itself starts: the '*' or the name
PTP_N     equ 48          ; items so far, so that `[]` is rejected
PTP_FRAME equ 56          ; + 1 push = 64
DEF_FUNC par_type_params, PTP_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - PTP_OUT], rsi
    mov qword [rsi], 0

    call par_kind
    cmp eax, TOK_LSQB
    jne .ptp_none

    mov rdi, rbx
    call par_peek
    TOK_POS rax
    mov [rbp - PTP_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; the '['

    mov rdi, rbx
    call ast_mark
    mov [rbp - PTP_MARK], rax
    mov qword [rbp - PTP_N], 0

.ptp_item:
    ; Each parameter carries its own position, and it is the '*' or the '**'
    ; that starts a starred one -- CPython's TypeVarTuple begins at the star.
    ; Taken before par_kind, which returns in the same register par_peek does.
    mov rdi, rbx
    call par_peek
    TOK_POS rax
    mov [rbp - PTP_ILINE], rcx

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_RSQB
    je .ptp_maybe_close
    cmp eax, TOK_ENDMARKER
    je .ptp_unterminated
    cmp eax, TOK_NEWLINE
    je .ptp_unterminated

    ; `*Ts` and `**P` are the two starred forms; anything else is a plain name.
    mov qword [rbp - PTP_NAME], AST_TYPEVAR
    cmp eax, TOK_STAR
    je .ptp_star
    cmp eax, TOK_DOUBLESTAR
    je .ptp_doublestar
    jmp .ptp_name
.ptp_star:
    mov qword [rbp - PTP_NAME], AST_TYPEVARTUPLE
    mov rdi, rbx
    call par_advance
    jmp .ptp_name
.ptp_doublestar:
    mov qword [rbp - PTP_NAME], AST_PARAMSPEC
    mov rdi, rbx
    call par_advance

.ptp_name:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NAME
    jne .ptp_expected_name
    mov rdi, rbx
    call par_name_obj                   ; interns and advances
    test rax, rax
    jz .ptp_fail
    mov r8d, eax                        ; a = the name

    ; A bound belongs to a plain TypeVar only: `*Ts: int` is a syntax error.
    xor r9d, r9d
    mov rdi, rbx
    push r8
    call par_kind
    pop r8
    cmp eax, TOK_COLON
    jne .ptp_build
    cmp qword [rbp - PTP_NAME], AST_TYPEVAR
    jne .ptp_bad_bound
    push r8
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    pop r8
    test rax, rax
    jz .ptp_fail
    mov r9d, eax                        ; b = the bound

.ptp_build:
    mov rdi, rbx
    mov rsi, [rbp - PTP_NAME]
    xor edx, edx
    mov rcx, [rbp - PTP_ILINE]
    call ast_make
    test rax, rax
    jz .ptp_fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    inc qword [rbp - PTP_N]

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    jne .ptp_close
    mov rdi, rbx
    call par_advance
    jmp .ptp_item

.ptp_maybe_close:
    ; `[]` is not an empty list of parameters, it is a syntax error.
    cmp qword [rbp - PTP_N], 0
    je .ptp_expected_name

.ptp_close:
    mov rdi, rbx
    mov esi, TOK_RSQB
    CSTRING rdx, "'[' was never closed"
    call par_expect
    test eax, eax
    jz .ptp_fail

    mov rdi, rbx
    mov esi, AST_TYPEPARAMS
    mov rdx, [rbp - PTP_LINE]
    mov rcx, [rbp - PTP_MARK]
    call par_finish_list
    test rax, rax
    jz .ptp_fail
    mov rcx, [rbp - PTP_OUT]
    mov [rcx], rax
    mov eax, 1
    pop rbx
    leave
    ret

.ptp_expected_name:
    mov rdi, rbx
    CSTRING rsi, "expected a type parameter name"
    call par_syntax_error
    jmp .ptp_fail
.ptp_bad_bound:
    mov rdi, rbx
    CSTRING rsi, "cannot use bound with TypeVarTuple or ParamSpec"
    call par_syntax_error
    jmp .ptp_fail
.ptp_unterminated:
    mov rdi, rbx
    CSTRING rsi, "'[' was never closed"
    call par_syntax_error
.ptp_fail:
    xor eax, eax
    pop rbx
    leave
    ret

.ptp_none:
    mov eax, 1
    pop rbx
    leave
    ret
END_FUNC par_type_params

;; ============================================================================
;; par_looks_like_type_alias(Comp *c) -> rax = 1 for a PEP 695 `type X = ...`
;; `type` is a soft keyword and also a builtin, so `type(x)`, `type = f` and
;; `type.mro` all have to keep working: the statement form is NAME NAME, or
;; NAME NAME '[', and nothing else is.
;; ============================================================================
DEF_FUNC_BARE par_looks_like_type_alias
    mov eax, [rdi + Comp.tok_idx]
    inc eax
    mov rdx, [rdi + Comp.tokens + Buf.len]
    cmp rax, rdx
    jae .no
    mov rcx, [rdi + Comp.tokens + Buf.data]
    mov rsi, rax
    imul rsi, rsi, Token_size
    movzx esi, word [rcx + rsi + Token.kind]
    cmp esi, TOK_NAME
    jne .no
    ; The token after the alias name settles it: '=' or a parameter list.
    inc rax
    cmp rax, rdx
    jae .no
    imul rax, rax, Token_size
    movzx eax, word [rcx + rax + Token.kind]
    cmp eax, TOK_EQUAL
    je .yes
    cmp eax, TOK_LSQB
    je .yes
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret
END_FUNC par_looks_like_type_alias

;; ============================================================================
;; ps_type_alias(Comp *c) -> node   -- `type X = V` and `type X[T] = V`
;;
;; Compiled as the assignment `X = V`.  CPython makes X a TypeAliasType whose
;; value is evaluated lazily; there is no such type here, and nothing that
;; would observe the difference, since annotations are never evaluated.  The
;; alias is the value, which is what code that reads it back expects.
;; ============================================================================
PTA_LINE  equ 8
PTA_NAME  equ 16
PTA_MARK  equ 24
PTA_VALUE equ 32
PTA_NODE  equ 40
PTA_TP    equ 48          ; the PEP 695 type parameters
PTA_NLINE equ 56          ; where the alias's own name starts
PTA_FRAME equ 72          ; + 1 push = 80
DEF_FUNC_LOCAL ps_type_alias, PTA_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PTA_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; the soft keyword `type`

    mov rdi, rbx
    call par_peek
    TOK_POS rax
    mov [rbp - PTA_NLINE], rcx
    mov rdi, rbx
    call par_name_obj
    test rax, rax
    jz .fail
    mov r8, rax
    mov rdi, rbx
    mov esi, AST_NAME
    mov edx, CTX_STORE
    mov rcx, [rbp - PTA_NLINE]
    xor r9d, r9d
    call ast_make
    test rax, rax
    jz .fail
    mov [rbp - PTA_NAME], rax

    mov rdi, rbx
    lea rsi, [rbp - PTA_TP]
    call par_type_params
    test eax, eax
    jz .fail

    mov rdi, rbx
    mov esi, TOK_EQUAL
    CSTRING rdx, "expected '=' in a type alias"
    call par_expect
    test eax, eax
    jz .fail

    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PTA_VALUE], rax

    ; A node of its own, which the code generator lowers to the assignment
    ; this used to build directly.  CPython's TypeAlias is not an assignment:
    ; its value is evaluated lazily, inside a TypeAliasType.  That is the
    ; runtime half, and it was in the old bug list; the tree is what says what was
    ; written.
    mov rdi, rbx
    mov esi, AST_TYPEALIAS
    xor edx, edx
    mov rcx, [rbp - PTA_LINE]
    mov r8d, [rbp - PTA_NAME]
    mov r9d, [rbp - PTA_VALUE]
    call ast_make
    test rax, rax
    jz .fail
    mov [rbp - PTA_NODE], rax
    mov rdi, rbx
    mov esi, eax
    mov edx, [rbp - PTA_TP]
    call ast_set_typeparams
    mov rax, [rbp - PTA_NODE]
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ps_type_alias

;; ============================================================================
;; ps_return - `return` and `return value`
;; ============================================================================
DEF_FUNC_LOCAL ps_return, PK_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PK_LINE], rcx
    mov rdi, rbx
    call par_advance
    mov qword [rbp - PK_A], 0
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NEWLINE
    je .build
    cmp eax, TOK_SEMI
    je .build
    cmp eax, TOK_ENDMARKER
    je .build
    cmp eax, TOK_DEDENT
    je .build
    mov rdi, rbx
    call par_exprlist_stmt
    test rax, rax
    jz .fail
    mov [rbp - PK_A], rax
.build:
    mov rdi, rbx
    mov esi, AST_RETURN
    xor edx, edx
    mov rcx, [rbp - PK_LINE]
    mov r8, [rbp - PK_A]
    xor r9d, r9d
    call ast_make
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ps_return


;; ============================================================================
;; ps_class - `class C(bases, **kw): body`
;;   .a = the name, .b = an AST_CALL holding the bases and keywords,
;;   .clist = the body statements
;; ============================================================================
PC_LINE   equ 8
PC_NAME   equ 16
PC_BASES  equ 24
PC_MARK   equ 32
PC_NODE   equ 40
PC_PRIV   equ 48          ; Comp.private, saved across the body
PC_TP     equ 56          ; the PEP 695 type parameters
PC_FRAME  equ 72          ; + 1 push = 80
DEF_FUNC_LOCAL ps_class, PC_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PC_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; `class`

    mov rdi, rbx
    call par_name_obj
    test rax, rax
    jz .fail
    mov [rbp - PC_NAME], rax
    mov qword [rbp - PC_BASES], 0

    mov rdi, rbx
    lea rsi, [rbp - PC_TP]
    call par_type_params
    test eax, eax
    jz .fail

    ; The base list is an argument list, keywords and all -- `class C(B,
    ; metaclass=M)` -- so it is parsed by the same code that parses a call.
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_LPAR
    jne .body
    mov rdi, rbx
    xor esi, esi                    ; a placeholder callee
    call in_call_public
    test rax, rax
    jz .fail
    mov [rbp - PC_BASES], rax

.body:
    mov rdi, rbx
    call ast_mark
    mov [rbp - PC_MARK], rax

    ; Private names inside the body mangle against this class.  The bases and
    ; keywords above are evaluated in the enclosing scope and do not.  A
    ; nested class replaces the name for its own body, which is why this is
    ; saved and restored rather than set once.
    mov rax, [rbx + Comp.private]
    mov [rbp - PC_PRIV], rax
    mov rdi, rbx
    mov rsi, [rbp - PC_NAME]
    call ast_obj_at
    mov [rbx + Comp.private], rax

    SUITE_FOR "class definition", dword [rbp - PC_LINE]
    mov rdi, rbx
    xor esi, esi
    call par_suite_into
    push rax
    mov rax, [rbp - PC_PRIV]
    mov [rbx + Comp.private], rax
    pop rax
    test eax, eax
    jz .fail

    mov rdi, rbx
    mov esi, AST_CLASSDEF
    mov rdx, [rbp - PC_LINE]
    mov rcx, [rbp - PC_MARK]
    call par_finish_list
    test rax, rax
    jz .fail
    mov [rbp - PC_NODE], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - PC_NAME]
    mov [rax + AstNode.a], edx
    mov rdx, [rbp - PC_BASES]
    mov [rax + AstNode.b], edx
    mov rdi, rbx
    mov esi, [rbp - PC_NODE]
    mov edx, [rbp - PC_TP]
    call ast_set_typeparams
    mov rax, [rbp - PC_NODE]
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ps_class

;; ============================================================================
;; ps_decorated - one or more `@decorator` lines, then a def or class
;;
;; The decorators are evaluated top to bottom and applied bottom to top, which
;; is why they are collected in order and the calls emitted in reverse.
;; ============================================================================
PDC_LINE  equ 8
PDC_MARK  equ 16
PDC_TARGET equ 24
PDC_NODE  equ 32
PDC_FRAME equ 40          ; + 1 push = 48
DEF_FUNC_LOCAL ps_decorated, PDC_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PDC_LINE], rcx

    mov rdi, rbx
    call ast_mark
    mov [rbp - PDC_MARK], rax
.loop:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_AT
    jne .target
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    mov rdi, rbx
    mov esi, TOK_NEWLINE
    CSTRING rdx, "expected a newline after the decorator"
    call par_expect
    test eax, eax
    jz .fail
.skip_blank:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NEWLINE
    jne .loop
    mov rdi, rbx
    call par_advance
    jmp .skip_blank

.target:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_DEF
    je .have_target
    cmp eax, TOK_CLASS
    je .have_target
    ; `async def` is decoratable and `async for` / `async with` are not, so the
    ; one token of lookahead decides it here rather than after the statement is
    ; parsed -- the error then points at the `async`, not at the end of a loop.
    ; @wraps over an async def is how contextlib.py and a hundred other Lib/
    ; sites are written, and this rejected every one of them.
    cmp eax, TOK_ASYNC
    jne .bad_target
    mov rdi, rbx
    call par_peek_next
    cmp eax, TOK_DEF
    je .have_target
.bad_target:
    mov rdi, rbx
    CSTRING rsi, "expected 'def', 'class' or 'async def' after a decorator"
    call par_syntax_error
    jmp .fail
.have_target:
    mov rdi, rbx
    call par_statement
    test rax, rax
    jz .fail
    mov [rbp - PDC_TARGET], rax

    ; The decorated node carries the decorator list; the emitter applies them.
    mov rdi, rbx
    mov esi, AST_DECORATED
    mov rdx, [rbp - PDC_LINE]
    mov rcx, [rbp - PDC_MARK]
    call par_finish_list
    test rax, rax
    jz .fail
    mov [rbp - PDC_NODE], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - PDC_TARGET]
    mov [rax + AstNode.a], edx
    mov rax, [rbp - PDC_NODE]
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ps_decorated

section .rodata

;; ============================================================================
;; stmt_table - leading token -> statement parser.  A zero entry means the
;; statement does not begin with a keyword, and falls through to the
;; expression-or-assignment parser.
;; ============================================================================
align 8
stmt_table:
    dq 0            ;  0 TOK_ENDMARKER
    dq 0            ;  1 TOK_NEWLINE
    dq 0            ;  2 TOK_INDENT
    dq 0            ;  3 TOK_DEDENT
    dq 0            ;  4 TOK_NAME
    dq 0            ;  5 TOK_NUMBER
    dq 0            ;  6 TOK_STRING
    dq 0            ;  7 TOK_FSTRING
    dq 0            ;  8 TOK_LPAR
    dq 0            ;  9 TOK_RPAR
    dq 0            ; 10 TOK_LSQB
    dq 0            ; 11 TOK_RSQB
    dq 0            ; 12 TOK_LBRACE
    dq 0            ; 13 TOK_RBRACE
    dq 0            ; 14 TOK_COLON
    dq 0            ; 15 TOK_COMMA
    dq 0            ; 16 TOK_SEMI
    dq 0            ; 17 TOK_DOT
    dq 0            ; 18 TOK_ELLIPSIS
    dq 0            ; 19 TOK_PLUS
    dq 0            ; 20 TOK_MINUS
    dq 0            ; 21 TOK_STAR
    dq 0            ; 22 TOK_DOUBLESTAR
    dq 0            ; 23 TOK_SLASH
    dq 0            ; 24 TOK_DOUBLESLASH
    dq 0            ; 25 TOK_PERCENT
    dq ps_decorated            ; 26 TOK_AT
    dq 0            ; 27 TOK_VBAR
    dq 0            ; 28 TOK_AMPER
    dq 0            ; 29 TOK_CIRCUMFLEX
    dq 0            ; 30 TOK_TILDE
    dq 0            ; 31 TOK_LEFTSHIFT
    dq 0            ; 32 TOK_RIGHTSHIFT
    dq 0            ; 33 TOK_LESS
    dq 0            ; 34 TOK_GREATER
    dq 0            ; 35 TOK_LESSEQUAL
    dq 0            ; 36 TOK_GREATEREQUAL
    dq 0            ; 37 TOK_EQEQUAL
    dq 0            ; 38 TOK_NOTEQUAL
    dq 0            ; 39 TOK_EQUAL
    dq 0            ; 40 TOK_COLONEQUAL
    dq 0            ; 41 TOK_RARROW
    dq 0            ; 42 TOK_PLUSEQUAL
    dq 0            ; 43 TOK_MINEQUAL
    dq 0            ; 44 TOK_STAREQUAL
    dq 0            ; 45 TOK_DOUBLESTAREQUAL
    dq 0            ; 46 TOK_SLASHEQUAL
    dq 0            ; 47 TOK_DOUBLESLASHEQUAL
    dq 0            ; 48 TOK_PERCENTEQUAL
    dq 0            ; 49 TOK_ATEQUAL
    dq 0            ; 50 TOK_VBAREQUAL
    dq 0            ; 51 TOK_AMPEREQUAL
    dq 0            ; 52 TOK_CIRCUMFLEXEQUAL
    dq 0            ; 53 TOK_LEFTSHIFTEQUAL
    dq 0            ; 54 TOK_RIGHTSHIFTEQUAL
    dq 0            ; 55 TOK_FALSE
    dq 0            ; 56 TOK_NONE
    dq 0            ; 57 TOK_TRUE
    dq 0            ; 58 TOK_AND
    dq 0            ; 59 TOK_AS
    dq ps_assert    ; 60 TOK_ASSERT
    dq ps_async                ; 61 TOK_ASYNC
    dq 0            ; 62 TOK_AWAIT
    dq ps_simple    ; 63 TOK_BREAK
    dq ps_class                ; 64 TOK_CLASS
    dq ps_simple    ; 65 TOK_CONTINUE
    dq ps_def                  ; 66 TOK_DEF
    dq ps_del       ; 67 TOK_DEL
    dq 0            ; 68 TOK_ELIF
    dq 0            ; 69 TOK_ELSE
    dq 0            ; 70 TOK_EXCEPT
    dq 0            ; 71 TOK_FINALLY
    dq ps_for                  ; 72 TOK_FOR
    dq ps_from      ; 73 TOK_FROM
    dq ps_scope     ; 74 TOK_GLOBAL
    dq ps_if                   ; 75 TOK_IF
    dq ps_import    ; 76 TOK_IMPORT
    dq 0            ; 77 TOK_IN
    dq 0            ; 78 TOK_IS
    dq 0            ; 79 TOK_LAMBDA
    dq ps_scope     ; 80 TOK_NONLOCAL
    dq 0            ; 81 TOK_NOT
    dq 0            ; 82 TOK_OR
    dq ps_simple    ; 83 TOK_PASS
    dq ps_raise     ; 84 TOK_RAISE
    dq ps_return               ; 85 TOK_RETURN
    dq ps_try                  ; 86 TOK_TRY
    dq ps_while                ; 87 TOK_WHILE
    dq ps_with                 ; 88 TOK_WITH
    dq 0            ; 89 TOK_YIELD
    dq 0            ; 90 TOK_TYPE_COMMENT
    dq 0            ; 91 TOK_TYPE_IGNORE
stmt_table_end:

;; The dispatch above bounds against TOK_COUNT, so the table has to have that
;; many rows -- and it did not: the two type-comment tokens were added to the
;; token set without rows here, so a `# type:` comment in statement position
;; read past the end and called whatever followed it.  Nothing catches a
;; short table at run time, so the assembler catches it here.
%if (stmt_table_end - stmt_table) / 8 != TOK_COUNT
    %error "stmt_table must have one row per token kind"
%endif

section .rodata

;; Augmented-assignment operators, paired with their BINARY_OP in-place codes.
align 8
augop_table:
    dd TOK_PLUSEQUAL,        NB_INPLACE_ADD
    dd TOK_MINEQUAL,         NB_INPLACE_SUBTRACT
    dd TOK_STAREQUAL,        NB_INPLACE_MULTIPLY
    dd TOK_SLASHEQUAL,       NB_INPLACE_TRUE_DIVIDE
    dd TOK_DOUBLESLASHEQUAL, NB_INPLACE_FLOOR_DIVIDE
    dd TOK_PERCENTEQUAL,     NB_INPLACE_REMAINDER
    dd TOK_DOUBLESTAREQUAL,  NB_INPLACE_POWER
    dd TOK_LEFTSHIFTEQUAL,   NB_INPLACE_LSHIFT
    dd TOK_RIGHTSHIFTEQUAL,  NB_INPLACE_RSHIFT
    dd TOK_AMPEREQUAL,       NB_INPLACE_AND
    dd TOK_VBAREQUAL,        NB_INPLACE_OR
    dd TOK_CIRCUMFLEXEQUAL,  NB_INPLACE_XOR
    dd TOK_ATEQUAL,          NB_INPLACE_MATRIX_MULTIPLY
    dd -1, 0

ASM_INIT

section .rodata
ps_type_kw: db "type", 0
