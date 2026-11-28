; parse_try.asm - the two compound statements that are one unwinder
;
; `try` and `with` share a frame layout -- the PT2_* block below is theirs
; together -- because they are the same shape: a suite, then clauses that have
; to run whether it finished or not.  They came out of parse_stmt.asm when it
; reached the 100k cap that src/compiler/lint.py enforces, along the seam
; src/compiler/codegen_try.asm already uses on the other side of the compiler.
;
; Nothing else moved and nothing changed: par_suite, par_suite_into and
; par_name_obj stay in parse_stmt.asm, and the SUITE_FOR macros moved to
; compiler.inc so both files can reach the two words par_suite reads.

%include "macros.inc"
%include "object.inc"
%include "value.inc"
%include "opcodes.inc"
%include "compiler.inc"

extern ast_at
extern ast_make
extern ast_mark
extern ast_push
extern ast_set_ctx
extern exc_SyntaxError_type
extern comp_error_span
extern ast_claim_typecomment
extern ast_span_at
extern par_advance
extern par_expr
extern par_finish_list
extern par_kind
extern par_peek
extern par_syntax_error
extern par_suite
extern par_suite_into
extern par_name_obj
extern par_last_pushed

section .text

;; ============================================================================
;; ps_try(Comp *c) -> rax = an AST_TRY node, 0 with the error recorded
;;
;; `try` / `except` / `else` / `finally`, and `except*` with it: all of a try's
;; handlers are star handlers or none are, so the kind is a flag on the try and
;; not on the clause.  The node:
;;
;;   .clist   = body statements
;;   .a       = a block of AST_HANDLER clauses
;;   .b       = the else block
;;   .c       = the finally block
;;   .subkind = 1 for `except*`
;; ============================================================================
PT2_LINE  equ 8
PT2_MARK  equ 16
PT2_HAND  equ 24
PT2_ELSE  equ 32
PT2_FIN   equ 40
PT2_NODE  equ 48
PT2_HMARK equ 56
PT2_TYPE  equ 64
PT2_NAME  equ 72
PT2_BODY  equ 80
PT2_SAVET equ 88          ; token index, for the parenthesised with-items try
PT2_SAVEP equ 96          ; pending-stack height
PT2_SAVEE equ 104         ; whether an error was already recorded
PT2_PAREN equ 112         ; 1 while inside a parenthesised item list
PT2_STAR  equ 88
PT2_HLINE equ 120         ; where THIS handler's `except` is, not the `try`
PT2_LAST  equ 128         ; the body's last statement, to blame a missing clause
PT2_FRAME equ 152         ; + 1 push = 160, 16-byte aligned
DEF_FUNC ps_try, PT2_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PT2_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; `try`

    mov rdi, rbx
    call ast_mark
    mov [rbp - PT2_MARK], rax
    SUITE_FOR "'try' statement", dword [rbp - PT2_LINE]
    mov rdi, rbx
    mov esi, 1
    call par_suite_into
    test eax, eax
    jz .fail
    ; The body's last statement, for the message below.  It has to be sampled
    ; HERE: the else and finally suites push onto the same stack.
    mov rdi, rbx
    call par_last_pushed
    mov [rbp - PT2_LAST], rax
    mov qword [rbp - PT2_HAND], 0
    mov qword [rbp - PT2_ELSE], 0
    mov qword [rbp - PT2_FIN], 0
    mov qword [rbp - PT2_STAR], 0

    ; CPython's grammar is `'try' ':' block (except_block+ [else] [finally]
    ; | finally_block)`, so the token after the body MUST be `except` or
    ; `finally`.  This used to be checked at the very END of the statement
    ; instead, after the else and finally clauses had been parsed, and it
    ; blamed a node index in a frame slot that only the handler loop ever
    ; wrote -- so on the one path that reached it the slot held stack garbage.
    ; valgrind saw the branch on it; when the garbage happened to be a valid
    ; index it reported an unrelated node's line, and `try:\n pass\nelse:`
    ; reported a line PAST the end of the file.
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_EXCEPT
    je .have_except
    cmp eax, TOK_FINALLY
    je .else_clause                     ; no handlers, but a finally
    jmp .no_clause

.have_except:

    mov rdi, rbx
    call ast_mark
    mov [rbp - PT2_HMARK], rax
.except_loop:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_EXCEPT
    jne .close_handlers
    ; A handler is at its own `except`, not at the `try` above it.
    mov rdi, rbx
    call par_peek
    TOK_POS rax
    mov [rbp - PT2_HLINE], rcx
    mov rdi, rbx
    call par_advance
    mov qword [rbp - PT2_TYPE], 0
    mov qword [rbp - PT2_NAME], 0

    ; `except*` is a different statement, not a variant of one clause: all of
    ; a try's handlers are star handlers or none are, and the flag belongs to
    ; the try.  The mixed form is a syntax error CPython also rejects.
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_STAR
    jne .not_star
    mov rdi, rbx
    call par_advance
    mov qword [rbp - PT2_STAR], 1
.not_star:

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COLON
    je .handler_suite
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PT2_TYPE], rax
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_AS
    jne .handler_suite
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call par_name_obj
    test rax, rax
    jz .fail
    mov [rbp - PT2_NAME], rax

.handler_suite:
    mov rdi, rbx
    call ast_mark
    mov [rbp - PT2_BODY], rax
    SUITE_FOR "'except' statement", dword [rbp - PT2_HLINE]
    mov rdi, rbx
    mov esi, 1
    call par_suite_into
    test eax, eax
    jz .fail
    mov rdi, rbx
    mov esi, AST_HANDLER
    mov rdx, [rbp - PT2_HLINE]
    mov rcx, [rbp - PT2_BODY]
    call par_finish_list
    test rax, rax
    jz .fail
    mov [rbp - PT2_BODY], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - PT2_TYPE]
    mov [rax + AstNode.a], edx
    mov rdx, [rbp - PT2_NAME]
    mov [rax + AstNode.b], edx
    mov rdi, rbx
    mov rsi, [rbp - PT2_BODY]
    call ast_push
    jmp .except_loop

.close_handlers:
    mov rdi, rbx
    mov esi, AST_BLOCK
    mov rdx, [rbp - PT2_LINE]
    mov rcx, [rbp - PT2_HMARK]
    call par_finish_list
    test rax, rax
    jz .fail
    mov [rbp - PT2_HAND], rax

.else_clause:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_ELSE
    jne .finally_clause
    SUITE_FOR_HERE "'else' statement"
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov esi, 1
    call par_suite
    test rax, rax
    jz .fail
    mov [rbp - PT2_ELSE], rax

.finally_clause:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_FINALLY
    jne .build
    SUITE_FOR_HERE "'finally' statement"
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov esi, 1
    call par_suite
    test rax, rax
    jz .fail
    mov [rbp - PT2_FIN], rax
    jmp .build

.no_clause:
    ; A real token there is blamed whole -- `else` is (col, col+4), which is
    ; what CPython reports.  At the end of the block there is no token to
    ; blame, so it is the END of the body, with the span running off the line
    ; (CPython's end_offset is -1 there, so end_col is -2).
    cmp eax, TOK_ENDMARKER
    je .no_clause_at_end
    cmp eax, TOK_DEDENT
    je .no_clause_at_end
    cmp eax, TOK_NEWLINE
    je .no_clause_at_end
    mov rdi, rbx
    call par_peek
    mov ecx, [rax + Token.lineno]
    mov r8d, [rax + Token.col]
    mov r9d, ecx
    mov r10d, [rax + Token.len]
    add r10d, r8d
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    CSTRING rdx, "expected 'except' or 'finally' block"
    call comp_error_span
    jmp .fail

.no_clause_at_end:
    mov rdi, rbx
    mov esi, [rbp - PT2_LAST]
    call ast_span_at
    test rax, rax
    jz .try_no_span
    cmp dword [rax + AstSpan.end_lineno], -1
    je .try_no_span
    mov ecx, [rax + AstSpan.end_lineno]
    mov r8d, [rax + AstSpan.end_col]
    mov r9d, ecx
    mov r10d, -2                        ; CPython's end_offset here is -1
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    CSTRING rdx, "expected 'except' or 'finally' block"
    call comp_error_span
    jmp .fail
.try_no_span:
    mov rdi, rbx
    CSTRING rsi, "expected 'except' or 'finally' block"
    call par_syntax_error
    jmp .fail

.build:
    mov rdi, rbx
    mov esi, AST_TRY
    mov rdx, [rbp - PT2_LINE]
    mov rcx, [rbp - PT2_MARK]
    call par_finish_list
    test rax, rax
    jz .fail
    mov [rbp - PT2_NODE], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - PT2_HAND]
    mov [rax + AstNode.a], edx
    mov rdx, [rbp - PT2_ELSE]
    mov [rax + AstNode.b], edx
    mov rdx, [rbp - PT2_FIN]
    mov [rax + AstNode.c], edx
    mov rdx, [rbp - PT2_STAR]
    mov [rax + AstNode.subkind], dl
    mov rax, [rbp - PT2_NODE]
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ps_try

;; ============================================================================
;; ps_with(Comp *c) -> rax = an AST_WITH node, 0 with the error recorded
;;
;; `with a as x, b: body`, and the parenthesised item list PEP 617 allows --
;; which cannot be told from a parenthesised expression until the `as` or the
;; closing paren arrives, so the token index and the pending-stack height are
;; saved and the parse is retried.  The node:
;;
;;   .clist   = AST_WITHITEM nodes
;;   .a       = the body block
;;   .subkind = 1 for `async with`, which ps_async stamps on the way out
;; ============================================================================
DEF_FUNC ps_with, PT2_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PT2_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; `with`

    mov rdi, rbx
    call ast_mark
    mov [rbp - PT2_MARK], rax
    mov qword [rbp - PT2_PAREN], 0

    ; A `(` here may open a parenthesised item list -- `with (a as x, b):` --
    ; or an ordinary parenthesised expression, and only trying it tells them
    ; apart.  CPython's PEG parser backtracks here too; the state to restore
    ; is the token index, the pending-node height and the recorded error.
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_LPAR
    jne .item_loop
    mov eax, [rbx + Comp.tok_idx]
    mov [rbp - PT2_SAVET], rax
    mov rax, [rbx + Comp.pending + Buf.len]
    mov [rbp - PT2_SAVEP], rax
    mov eax, [rbx + Comp.err + CompErr.set]
    mov [rbp - PT2_SAVEE], rax
    mov qword [rbp - PT2_PAREN], 1
    mov rdi, rbx
    call par_advance                    ; `(`
    jmp .item_loop

.restore_plain:
    ; Not an item list after all: put everything back and parse the `(` as
    ; the start of an ordinary expression.
    mov rax, [rbp - PT2_SAVET]
    mov [rbx + Comp.tok_idx], eax
    mov rax, [rbp - PT2_SAVEP]
    mov [rbx + Comp.pending + Buf.len], rax
    mov rax, [rbp - PT2_SAVEE]
    mov [rbx + Comp.err + CompErr.set], eax
    mov qword [rbp - PT2_PAREN], 0

.item_loop:
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .item_failed
    mov [rbp - PT2_TYPE], rax
    mov qword [rbp - PT2_NAME], 0
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_AS
    jne .make_item
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov esi, BP_COMPARE
    call par_expr
    test rax, rax
    jz .fail
    mov rsi, rax
    mov [rbp - PT2_NAME], rax
    mov rdi, rbx
    mov edx, CTX_STORE
    call ast_set_ctx
    test eax, eax
    jz .bad_target
.make_item:
    mov rdi, rbx
    mov esi, AST_WITHITEM
    xor edx, edx
    mov rcx, [rbp - PT2_LINE]
    mov r8, [rbp - PT2_TYPE]
    mov r9, [rbp - PT2_NAME]
    call ast_make
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    jne .items_end
    mov rdi, rbx
    call par_advance
    ; A trailing comma before the `)` ends the list.
    cmp qword [rbp - PT2_PAREN], 0
    je .item_loop
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_RPAR
    jne .item_loop

.items_end:
    cmp qword [rbp - PT2_PAREN], 0
    je .with_body
    ; The list has to close and be followed by the suite's colon; anything
    ; else means this was a parenthesised expression all along.
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_RPAR
    jne .restore_plain
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COLON
    jne .restore_plain
    mov qword [rbp - PT2_PAREN], 0

.with_body:
    SUITE_FOR "'with' statement", dword [rbp - PT2_LINE]
    mov rdi, rbx
    xor esi, esi
    call par_suite
    test rax, rax
    jz .fail
    mov [rbp - PT2_BODY], rax

    mov rdi, rbx
    mov esi, AST_WITH
    mov rdx, [rbp - PT2_LINE]
    mov rcx, [rbp - PT2_MARK]
    call par_finish_list
    push rax
    mov rdi, rbx
    mov rsi, rax
    call ast_claim_typecomment
    pop rax
    test rax, rax
    jz .fail
    mov [rbp - PT2_NODE], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - PT2_BODY]
    mov [rax + AstNode.a], edx
    mov rax, [rbp - PT2_NODE]
    pop rbx
    leave
    ret
.item_failed:
    ; Inside the parenthesised attempt a failure is not fatal -- it just means
    ; the `(` opened an expression.
    cmp qword [rbp - PT2_PAREN], 0
    jne .restore_plain
    jmp .fail
.bad_target:
    mov rdi, rbx
    CSTRING rsi, "cannot assign to that with-target"
    call par_syntax_error
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ps_with
