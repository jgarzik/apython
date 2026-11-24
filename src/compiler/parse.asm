; parse.asm - Recursive-descent parser with a table-driven expression core
;
; Expressions use precedence climbing over one table indexed by token kind:
; each row gives a prefix handler, an infix handler, and the binding powers.
; Python's awkward corners then fall out of the numbers rather than needing
; special cases:
;
;   **   lbp 28, but its handler recurses at BP_UNARY (26).  That single
;        asymmetry gives right-associativity (2**3**2 == 512), lets the right
;        side take a unary operator (2**-1), and makes -2**2 == -4, because
;        unary minus parses its operand at 26 and ** at 28 binds tighter.
;   not  prefix only, parsing its operand at BP_NOT (10), which is below
;        BP_COMPARE -- so `not a == b` is `not (a == b)`.
;   ,    deliberately NOT in the table.  A comma is handled by the callers
;        that actually permit a tuple; putting it in the table is the classic
;        way to break call arguments, subscripts and target lists.
;
; Contexts that must exclude a ternary or a walrus just pass a higher minimum
; binding power.  That is what the parameter is for, and it means the
; comprehension `for y in z if c` needs no lookahead to leave the `if` alone.
;
; Nothing here raises: an error is recorded through comp_error and reported by
; returning node 0.  After the first error the token cursor reports ENDMARKER
; forever, so every parse loop terminates on its own and most call sites need
; no explicit check.

%include "macros.inc"
%include "object.inc"
%include "value.inc"
%include "opcodes.inc"
%include "compiler.inc"

extern complex_from_doubles
extern ast_at
extern ast_commit
extern ast_make
extern ast_end_here
extern ast_mark
extern ast_obj
extern ast_push
extern comp_msg_i64
extern comp_error

extern ap_free
extern ap_malloc
extern buf_free
extern buf_init
extern buf_push_u8
extern bytes_from_data
extern str_new_heap
extern comp_intern
extern ap_strlen
extern par_for_target
extern par_fstring_pieces
extern par_params
extern int_from_cstr_base
extern strtod

extern bool_false
extern ellipsis_singleton
extern bool_true
extern none_singleton

extern exc_SyntaxError_type
extern par_escape_one
extern par_fstring_piece_any
extern par_hexval
extern par_run_has_fstring
extern par_string_body
extern par_utf8_emit
extern pf_string

;; ============================================================================
;; Binding powers, in steps of two so that a right-associative operator is
;; simply "recurse at lbp - 1" and there is still room between levels.
;; ============================================================================
; The binding powers live in compiler.inc: pattern.asm needs them too.

; PRule and PR_* live in compiler.inc: prule.asm holds the table.
                 ; 24

; --- Named frame-layout constants ---
PE_MINBP equ 16
PE_LEFT  equ 24
PE_RULE  equ 32
PE_START equ 40          ; the token this expression begins at
PE_FRAME equ 56          ; + 1 push = 64

section .text

;; ============================================================================
;; par_peek(Comp *c) -> rax = Token*
;; Once an error has been recorded the cursor reports the final ENDMARKER
;; forever.  That is what lets the parser run to a stop after a syntax error
;; without every loop in the file testing for it.
;; ============================================================================
DEF_FUNC_BARE par_peek
    mov rax, [rdi + Comp.tokens + Buf.data]
    mov ecx, [rdi + Comp.tok_idx]
    cmp dword [rdi + Comp.err + CompErr.set], 0
    jne .at_end
    shl rcx, TOKEN_SHIFT
    add rax, rcx
    ret
.at_end:
    mov rcx, [rdi + Comp.tokens + Buf.len]
    dec rcx
    shl rcx, TOKEN_SHIFT
    add rax, rcx
    ret
END_FUNC par_peek

;; ============================================================================
;; par_kind(Comp *c) -> eax = the current token's kind
;; ============================================================================
DEF_FUNC par_kind
    call par_peek
    movzx eax, word [rax + Token.kind]
    leave
    ret
END_FUNC par_kind

;; ============================================================================
;; par_advance(Comp *c)
;; ============================================================================
DEF_FUNC_BARE par_advance
    mov eax, [rdi + Comp.tok_idx]
    mov rcx, [rdi + Comp.tokens + Buf.len]
    dec rcx
    cmp rax, rcx
    jae .at_end                          ; never step past the ENDMARKER
    inc eax
    mov [rdi + Comp.tok_idx], eax
.at_end:
    ret
END_FUNC par_advance

;; ============================================================================
;; par_target_noun(rdi = Comp*, esi = an expression node) -> rax = the noun
;; CPython names it by in "cannot assign to X"
;;
;; CPython's _PyPegen_get_expr_name.  The noun is not decoration: it is the
;; only part of the message that says WHICH of several targets on a line was
;; the bad one.  Anything not listed is an "expression", as it is there.
;; ============================================================================
global par_target_noun
DEF_FUNC par_target_noun, 16       ; + 0 pushes = 16, 16-aligned
    call ast_at
    movzx eax, byte [rax + AstNode.kind]
    cmp eax, AST_CONST
    je .tn_literal
    cmp eax, AST_JOINEDSTR
    je .tn_fstring
    cmp eax, AST_CALL
    je .tn_call
    cmp eax, AST_LAMBDA
    je .tn_lambda
    cmp eax, AST_COMPARE
    je .tn_comparison
    cmp eax, AST_IFEXP
    je .tn_conditional
    cmp eax, AST_LISTCOMP
    je .tn_listcomp
    cmp eax, AST_SETCOMP
    je .tn_setcomp
    cmp eax, AST_DICTCOMP
    je .tn_dictcomp
    cmp eax, AST_GENEXP
    je .tn_genexp
    cmp eax, AST_DICT
    je .tn_dict
    cmp eax, AST_SET
    je .tn_set
    cmp eax, AST_YIELD
    je .tn_yield
    cmp eax, AST_YIELDFROM
    je .tn_yield
    cmp eax, AST_AWAIT
    je .tn_await
    cmp eax, AST_BOOLOP
    je .tn_expression
    CSTRING rax, "expression"
    leave
    ret
.tn_literal:
    CSTRING rax, "literal"
    leave
    ret
.tn_fstring:
    CSTRING rax, "f-string expression"
    leave
    ret
.tn_call:
    CSTRING rax, "function call"
    leave
    ret
.tn_lambda:
    CSTRING rax, "lambda"
    leave
    ret
.tn_comparison:
    CSTRING rax, "comparison"
    leave
    ret
.tn_conditional:
    CSTRING rax, "conditional expression"
    leave
    ret
.tn_listcomp:
    CSTRING rax, "list comprehension"
    leave
    ret
.tn_setcomp:
    CSTRING rax, "set comprehension"
    leave
    ret
.tn_dictcomp:
    CSTRING rax, "dict comprehension"
    leave
    ret
.tn_genexp:
    CSTRING rax, "generator expression"
    leave
    ret
.tn_dict:
    CSTRING rax, "dict literal"
    leave
    ret
.tn_set:
    CSTRING rax, "set display"
    leave
    ret
.tn_yield:
    CSTRING rax, "yield expression"
    leave
    ret
.tn_await:
    CSTRING rax, "await expression"
    leave
    ret
.tn_expression:
    CSTRING rax, "expression"
    leave
    ret
END_FUNC par_target_noun

;; ============================================================================
;; par_bad_target(rdi = Comp*, esi = the offending target node,
;;                rdx = the tail, or 0 for none) -> rax = 0
;;
;; "cannot assign to literal here. Maybe you meant '==' instead of '='?" --
;; CPython's wording, and CPython's span, which covers the target rather than
;; pointing at whatever token the parser had reached when it noticed.
;; ============================================================================
PBT_COMP equ 8
PBT_NODE equ 16
PBT_TAIL equ 24
PBT_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
global par_bad_target
DEF_FUNC par_bad_target, PBT_FRAME
    mov [rbp - PBT_COMP], rdi
    mov [rbp - PBT_NODE], rsi
    mov [rbp - PBT_TAIL], rdx

    extern comp_msg_start
    extern comp_msg_cstr
    call comp_msg_start
    push rax                    ; the buffer, which becomes the message
    mov rdi, rax
    CSTRING rsi, "cannot assign to "
    call comp_msg_cstr
    push rax
    mov rdi, [rbp - PBT_COMP]
    mov esi, [rbp - PBT_NODE]
    call par_target_noun
    mov rsi, rax
    pop rdi
    call comp_msg_cstr
    mov rdi, rax
    mov rsi, [rbp - PBT_TAIL]
    test rsi, rsi
    jnz .pbt_tail
    CSTRING rsi, ""
.pbt_tail:
    call comp_msg_cstr

    ; The span: the target's own start, and its end from the span table.
    mov rdi, [rbp - PBT_COMP]
    mov esi, [rbp - PBT_NODE]
    call ast_at
    mov ecx, [rax + AstNode.lineno]
    mov r8d, [rax + AstNode.col]
    push rcx
    push r8
    mov rdi, [rbp - PBT_COMP]
    mov esi, [rbp - PBT_NODE]
    extern ast_span_at
    call ast_span_at
    pop r8
    pop rcx
    mov r9d, ecx
    lea r10d, [r8d + 1]
    test rax, rax
    jz .pbt_span
    cmp dword [rax + AstSpan.end_lineno], -1
    je .pbt_span
    mov r9d, [rax + AstSpan.end_lineno]
    mov r10d, [rax + AstSpan.end_col]
.pbt_span:
    pop rdx                     ; the message
    mov rdi, [rbp - PBT_COMP]
    lea rsi, [rel exc_SyntaxError_type]
    extern comp_error_span
    call comp_error_span
    xor eax, eax
    leave
    ret
END_FUNC par_bad_target

;; ============================================================================
;; par_syntax_error(Comp *c, const char *msg) -> rax = 0
;; Stamps the message with the current token's position.
;; ============================================================================
PS_MSG   equ 8
PS_FRAME equ 8           ; + 1 push = 16
DEF_FUNC par_syntax_error, PS_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - PS_MSG], rsi

    ; A bracket still open when the input runs out is the error, whatever the
    ; site thought it was looking for -- CPython's tokenizer reports it and
    ; its parser never gets a chance to say anything else.  The converse
    ; matters too: `class C(object: pass` never closes its paren either, and
    ; CPython says "invalid syntax" there because its parser fails at the
    ; colon before the tokenizer reaches the end.
    ; A NEWLINE counts as the end here too: inside brackets they are
    ; suppressed, so one reached with the depth still up is the synthetic one
    ; the lexer emits at EOF.
    call par_kind
    cmp eax, TOK_ENDMARKER
    je .ps_at_end
    cmp eax, TOK_NEWLINE
    jne .ps_here
.ps_at_end:
    cmp dword [rbx + Comp.lex + Lexer.paren_depth], 0
    je .ps_here
    mov rdi, rbx
    call par_unclosed
    xor eax, eax
    pop rbx
    leave
    ret

.ps_here:
    ; The span covers the WHOLE token, which is what CPython underlines: it
    ; says (1, 1)-(1, 7) for a stray `except` and this said (1, 1)-(1, 2).
    ; A zero-length token -- NEWLINE, ENDMARKER, a DEDENT -- keeps the one
    ; character comp_error would have given.
    mov rdi, rbx
    call par_peek
    TOK_POS rax
    mov r8d, [rax + Token.col]
    mov r9d, ecx
    mov r10d, [rax + Token.len]
    test r10d, r10d
    jnz .ps_have_len
    mov r10d, 1
.ps_have_len:
    add r10d, r8d
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    mov rdx, [rbp - PS_MSG]
    call comp_error_span
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_syntax_error

;; ============================================================================
;; par_expect(Comp *c, int kind, const char *msg) -> rax = 1 ok, 0 error
;; ============================================================================
PX_KIND  equ 8
PX_MSG   equ 16
PX_FRAME equ 24          ; + 1 push = 32
DEF_FUNC par_expect, PX_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - PX_KIND], rsi
    mov [rbp - PX_MSG], rdx
    call par_kind
    cmp rax, [rbp - PX_KIND]
    jne .bad
    mov rdi, rbx
    call par_advance
    mov eax, 1
    pop rbx
    leave
    ret
.bad:
    mov rdi, rbx
    mov rsi, [rbp - PX_MSG]
    call par_syntax_error
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_expect

;; ============================================================================
;; par_unclosed(Comp *c) -> rax = 0, always
;;
;; "'(' was never closed", at the innermost bracket still open when the input
;; ran out.  CPython's end_offset for it is 0 rather than the column after,
;; which is why comp_error_span exists.
;; ============================================================================
PU_BUF   equ 72
PU_FRAME equ 88             ; + 1 push = 96, 16-aligned
DEF_FUNC par_unclosed, PU_FRAME
    push rbx
    mov rbx, rdi

    mov ecx, [rbx + Comp.lex + Lexer.paren_depth]
    dec ecx                             ; the innermost
    cmp ecx, LEX_MAX_BRACKET
    jae .pu_generic
    movzx edx, byte [rbx + Comp.lex + Lexer.open_ch + rcx]
    push rcx
    push rdx
    call comp_msg_start
    push rax
    mov rdi, rax
    CSTRING rsi, "'"
    call comp_msg_cstr
    mov rcx, [rsp + 8]                  ; the bracket character
    mov [rax], cl
    mov byte [rax + 1], 0
    lea rdi, [rax + 1]
    CSTRING rsi, "' was never closed"
    call comp_msg_cstr
    pop rdx                             ; the message
    add rsp, 8                          ; the character
    pop rcx                             ; the index

    mov r8d, [rbx + Comp.lex + Lexer.open_col + rcx*4]
    mov ecx, [rbx + Comp.lex + Lexer.open_line + rcx*4]
    mov r9d, ecx
    mov r10d, -1                        ; CPython's end_offset here is 0
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    call comp_error_span
    xor eax, eax
    pop rbx
    leave
    ret

.pu_generic:
    mov rdi, rbx
    CSTRING rsi, "invalid syntax"
    call par_syntax_error
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_unclosed

;; ============================================================================
;; par_expr(Comp *c, int min_bp) -> rax = node index, 0 on error
;;
;; The precedence-climbing driver.  Everything about Python's expression
;; precedence lives in prule_table, not here.
;; ============================================================================
DEF_FUNC par_expr, PE_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - PE_MINBP], rsi

    ; Guard the machine stack.  apython's recursion_depth counts Python frames
    ; only, so without this a pathological "((((..." walks off the stack long
    ; before anything notices.
    inc dword [rbx + Comp.depth]
    cmp dword [rbx + Comp.depth], COMP_MAX_DEPTH
    jae .too_deep

    ; Where the whole expression begins.  An infix node is built when its
    ; operator is reached, so ast_make stamps it with the operator's position
    ; -- but CPython's is the first TOKEN of the production, which is the
    ; start of the left operand INCLUDING any parentheses around it:
    ; `(a - b) | c` is at the '(', not at `a`, and `(lambda: 1)()` is at the
    ; '(' rather than at `lambda`.  Every infix result is restamped from here.
    mov eax, [rbx + Comp.tok_idx]
    mov [rbp - PE_START], rax

    mov rdi, rbx
    call par_kind
    lea rcx, [rel prule_table]
    imul rax, rax, PRule_size
    add rcx, rax
    mov rax, [rcx + PRule.prefix]
    test rax, rax
    jz .no_prefix

    mov rdi, rbx
    call rax                            ; the prefix handler advances the cursor
    mov [rbp - PE_LEFT], rax
    test rax, rax
    jz .fail

.loop:
    mov rdi, rbx
    call par_kind
    lea rcx, [rel prule_table]
    imul rax, rax, PRule_size
    add rcx, rax
    mov [rbp - PE_RULE], rcx
    movzx eax, byte [rcx + PRule.lbp]
    cmp rax, [rbp - PE_MINBP]
    jbe .done
    mov rax, [rcx + PRule.infix]
    test rax, rax
    jz .done

    mov rdi, rbx
    mov rsi, [rbp - PE_LEFT]
    call rax
    mov [rbp - PE_LEFT], rax
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov esi, eax
    mov edx, [rbp - PE_START]
    extern ast_start_at
    call ast_start_at
    jmp .loop

.done:
    dec dword [rbx + Comp.depth]
    mov rax, [rbp - PE_LEFT]
    pop rbx
    leave
    ret

.no_prefix:
    mov rdi, rbx
    CSTRING rsi, "invalid syntax"
    call par_syntax_error
    jmp .fail

.too_deep:
    mov rdi, rbx
    CSTRING rsi, "too many nested parentheses"
    call par_syntax_error
.fail:
    dec dword [rbx + Comp.depth]
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_expr

;; ============================================================================
;; par_number(Comp *c, Token *t) -> rax = Value, or 0 with an error recorded
;;
;; The literal's text is a slice of the source, so it has to be copied out and
;; NUL-terminated before the converters will look at it.  Both converters take
;; the whole job from there: int_from_cstr_base with base 0 handles 0x/0o/0b
;; and underscores, and strtod handles every float spelling.
;; ============================================================================
PN_TOK   equ 16
PN_BUF   equ 24
PN_HEAP  equ 32
PN_END   equ 40
PN_SMALL equ 176         ; 128 bytes of inline scratch at [rbp - PN_SMALL]
PN_FRAME equ 184         ; + 1 push = 192
DEF_FUNC par_number, PN_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - PN_TOK], rsi

    mov ecx, [rsi + Token.len]
    mov qword [rbp - PN_HEAP], 0
    cmp rcx, 127
    jbe .use_stack
    ; A literal longer than the inline buffer is rare but perfectly legal --
    ; a thousand-digit integer, say -- so fall back to the heap rather than
    ; truncating or refusing.
    lea rdi, [rcx + 1]
    call ap_malloc
    mov [rbp - PN_HEAP], rax
    mov [rbp - PN_BUF], rax
    jmp .have_buf
.use_stack:
    lea rax, [rbp - PN_SMALL]
    mov [rbp - PN_BUF], rax
.have_buf:
    ; Copy the digits, dropping the underscores PEP 515 allows between them.
    ; They reached int_from_cstr_base and strtod verbatim, and both stop at
    ; the first one -- so `1_000` was 1 and `1_000.5` was rejected outright.
    ; Two in a row, or one at either end, is a syntax error, as in CPython.
    mov rax, [rbp - PN_TOK]
    mov rsi, [rax + Token.start]
    mov ecx, [rax + Token.len]
    add rcx, rsi                        ; one past the text
    mov rdi, [rbp - PN_BUF]
    mov r8d, 1                          ; an underscore may not lead
.copy_digit:
    cmp rsi, rcx
    jae .copy_done
    movzx eax, byte [rsi]
    cmp al, '_'
    jne .copy_keep
    test r8d, r8d
    jnz .bad                            ; leading, or doubled
    mov r8d, 1
    inc rsi
    jmp .copy_digit
.copy_keep:
    mov [rdi], al
    inc rdi
    inc rsi
    xor r8d, r8d
    jmp .copy_digit
.copy_done:
    test r8d, r8d
    jnz .bad                            ; trailing underscore, or empty
    mov byte [rdi], 0

    mov rax, [rbp - PN_TOK]
    movzx eax, word [rax + Token.flags]
    test eax, TF_NUM_IMAG
    jnz .imaginary
    test eax, TF_NUM_FLOAT
    jnz .float

    ; int_from_cstr_base raises for a decimal literal past the digit limit,
    ; and raise_exception must never be reached from the compiler: it tail-
    ; jumps into eval_exception_unwind, which calls fatal_error when there is
    ; no interpreter frame.  A 5000-digit literal in a file made ./apython
    ; exit silently.  CPython reports it as a SyntaxError here too.
    mov rdi, [rbp - PN_BUF]
    call ap_strlen
    extern sys_int_max_str_digits
    mov rcx, [rel sys_int_max_str_digits]
    test rcx, rcx
    jz .len_ok
    cmp rax, rcx
    jle .len_ok
    ; A base prefix exempts it: only decimal conversion is quadratic.
    mov rdi, [rbp - PN_BUF]
    cmp byte [rdi], '0'
    jne .too_many_digits
    movzx eax, byte [rdi + 1]
    or eax, 0x20
    cmp al, 'x'
    je .len_ok
    cmp al, 'o'
    je .len_ok
    cmp al, 'b'
    je .len_ok
.too_many_digits:
    mov rdi, rbx
    CSTRING rsi, "Exceeds the limit for integer string conversion"
    call par_syntax_error
    xor eax, eax
    jmp .cleanup
.len_ok:

    mov rdi, [rbp - PN_BUF]
    xor esi, esi                        ; base 0: detect the prefix
    call int_from_cstr_base   ; err: the length was checked above, the digit limit cannot trip
    test edx, edx                       ; TAG_NULL means the parse failed
    jz .bad
    V_PACK rax, rdx
    jmp .done

.float:
    mov rdi, [rbp - PN_BUF]
    lea rsi, [rbp - PN_END]
    call strtod wrt ..plt
    mov rax, [rbp - PN_END]
    cmp byte [rax], 0                   ; strtod must have consumed all of it
    jne .bad
    movq rax, xmm0
    V_FROM_F64 rax, rcx
    jmp .done

.imaginary:
    ; The lexer counts the 'j' in Token.len (lex.asm's .num_imag advances past
    ; it after setting the flag), so it was copied along with the digits and
    ; strtod must not see it.  rdi still points at the NUL that .copy_done
    ; wrote, so the suffix is the byte before.
    mov al, [rdi - 1]
    or al, 0x20
    cmp al, 'j'
    jne .bad
    mov byte [rdi - 1], 0
    mov rdi, [rbp - PN_BUF]
    lea rsi, [rbp - PN_END]
    call strtod wrt ..plt
    mov rax, [rbp - PN_END]
    cmp byte [rax], 0                   ; strtod must have consumed all of it
    jne .bad
    ; strtod leaves the magnitude in xmm0, and complex_from_doubles wants
    ; xmm0 = real, xmm1 = imag.  An imaginary literal's real part is +0.0, so
    ; the two have to be moved in this order -- swapping them yields (2+0j)
    ; for 2j, which reprs differently and is immediately visible.
    movapd xmm1, xmm0
    xorpd xmm0, xmm0
    call complex_from_doubles
    ; A pointer is its own Value.  par_number returns an owned reference and
    ; pf_number hands it to ast_obj, which takes ownership; comp_free releases
    ; the arena with DECREF_V however the compilation ends.  No V_PACK.
    jmp .done

.bad:
    mov rdi, rbx
    CSTRING rsi, "invalid numeric literal"
    call par_syntax_error
    xor eax, eax
    jmp .cleanup

.done:
.cleanup:
    mov rdi, [rbp - PN_HEAP]
    test rdi, rdi
    jz .no_heap
    mov [rbp - PN_BUF], rax             ; park the result across the free
    call ap_free
    mov rax, [rbp - PN_BUF]
.no_heap:
    pop rbx
    leave
    ret
END_FUNC par_number

;; ============================================================================
;; Prefix handlers.  Each consumes its own token and returns a node index.

;; pf_unary(Comp *c) -> node   -- +x, -x, ~x, not x
PFU_LINE  equ 16
PFU_OP    equ 24
PFU_RBP   equ 32
PFU_FRAME equ 40         ; + 1 push = 48
global pf_unary
DEF_FUNC pf_unary, PFU_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PFU_LINE], rcx
    movzx eax, word [rax + Token.kind]
    lea rcx, [rel prule_table]
    imul rdx, rax, PRule_size
    movzx edx, byte [rcx + rdx + PRule.rbp]
    mov [rbp - PFU_RBP], rdx

    ; The unary operator comes from the token, NOT from PRule.aux: `+` and `-`
    ; share one row with their binary selves, and that row's aux holds the
    ; BINARY_OP code.  Reading it here turned -5 into `not 5`.
    mov edx, UOP_NEG
    cmp eax, TOK_MINUS
    je .arith_unary
    mov edx, UOP_POS
    cmp eax, TOK_PLUS
    je .arith_unary
    mov edx, UOP_INVERT
    cmp eax, TOK_TILDE
    je .have_op
    mov edx, UOP_NOT
    jmp .have_op
.arith_unary:
    ; The same row's rbp is the BINARY power, which is below `*`, `/`, `//` and
    ; `%` -- so taking it here parsed `-7 // 2` as `-(7 // 2)`, which is -3
    ; rather than -4.  Unary minus binds tighter than a term: the grammar is
    ; `factor: ('+'|'-'|'~') factor`.  BP_UNARY is still below BP_POWER, which
    ; is what keeps `-2**2` equal to -4.
    mov qword [rbp - PFU_RBP], BP_UNARY
.have_op:
    mov [rbp - PFU_OP], rdx

    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov rsi, [rbp - PFU_RBP]
    call par_expr
    test rax, rax
    jz .fail
    mov r8, rax
    mov rdi, rbx
    mov esi, AST_UNARYOP
    mov rdx, [rbp - PFU_OP]
    mov rcx, [rbp - PFU_LINE]
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
END_FUNC pf_unary

;; ============================================================================
;; Infix handlers.  Each is entered with the operator token still current.
;; ============================================================================

;; in_binop(Comp *c, node left) -> node
IB_LEFT  equ 16
IB_LINE  equ 24
IB_OP    equ 32
IB_RBP   equ 40
IB_FRAME equ 40          ; + 1 push = 48
global in_binop
DEF_FUNC in_binop, IB_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - IB_LEFT], rsi
    call par_peek
    TOK_POS rax
    mov [rbp - IB_LINE], rcx
    movzx eax, word [rax + Token.kind]
    lea rcx, [rel prule_table]
    imul rax, rax, PRule_size
    movzx edx, byte [rcx + rax + PRule.aux]
    mov [rbp - IB_OP], rdx
    movzx edx, byte [rcx + rax + PRule.rbp]
    mov [rbp - IB_RBP], rdx

    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov rsi, [rbp - IB_RBP]
    call par_expr
    test rax, rax
    jz .fail
    mov r9, rax

    ; A starred expression is not an operand: `1 +* 2` is CPython's plain
    ; "invalid syntax" at the star.  The check belongs here rather than where
    ; the star is parsed, because the contexts that DO take one -- `[*a]`,
    ; `f(*a)`, `for a, *b in z` -- reach it at every binding power there is.
    push r9
    mov rdi, rbx
    mov esi, r9d
    call ast_at
    movzx ecx, byte [rax + AstNode.kind]
    cmp ecx, AST_STARRED
    je .ib_bad_star
    cmp ecx, AST_DOUBLESTARRED
    je .ib_bad_star
    pop r9
    jmp .ib_build
.ib_bad_star:
    mov ecx, [rax + AstNode.lineno]
    mov r8d, [rax + AstNode.col]
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    CSTRING rdx, "invalid syntax"
    call comp_error
    pop r9
    jmp .fail

.ib_build:
    mov rdi, rbx
    mov esi, AST_BINOP
    mov rdx, [rbp - IB_OP]
    mov rcx, [rbp - IB_LINE]
    mov r8, [rbp - IB_LEFT]
    call ast_make
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC in_binop

;; in_boolop(Comp *c, node left) -> node   -- and / or, folded n-ary
;;
;; `a and b and c` becomes one node with three operands rather than a nest of
;; two, so codegen emits a single exit label and one jump per operand.
IO_LEFT  equ 16
IO_LINE  equ 24
IO_OP    equ 32
IO_MARK  equ 40
IO_NODE  equ 48
IO_FRAME equ 56          ; + 1 push = 64
global in_boolop
DEF_FUNC in_boolop, IO_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - IO_LEFT], rsi
    call par_peek
    TOK_POS rax
    mov [rbp - IO_LINE], rcx
    movzx eax, word [rax + Token.kind]
    mov edx, BOOL_AND
    cmp eax, TOK_OR
    jne .have_op
    mov edx, BOOL_OR
.have_op:
    mov [rbp - IO_OP], rdx

    mov rdi, rbx
    call ast_mark
    mov [rbp - IO_MARK], rax
    mov rdi, rbx
    mov rsi, [rbp - IO_LEFT]
    call ast_push

.more:
    mov rdi, rbx
    call par_advance                    ; consume `and` / `or`
    mov rdi, rbx
    mov rsi, BP_AND
    cmp qword [rbp - IO_OP], BOOL_OR
    jne .have_bp
    mov rsi, BP_OR
.have_bp:
    call par_expr
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push

    ; Absorb a run of the same operator into this one node.
    mov rdi, rbx
    call par_kind
    cmp qword [rbp - IO_OP], BOOL_OR
    je .check_or
    cmp eax, TOK_AND
    je .more
    jmp .finish
.check_or:
    cmp eax, TOK_OR
    je .more

.finish:
    mov rdi, rbx
    mov esi, AST_BOOLOP
    mov rdx, [rbp - IO_OP]
    mov rcx, [rbp - IO_LINE]
    xor r8d, r8d
    xor r9d, r9d
    call ast_make
    mov [rbp - IO_NODE], rax

    mov rdi, rbx
    mov rsi, [rbp - IO_MARK]
    call ast_commit                     ; rax = offset, rdx = count
    mov r8, rax
    mov r9, rdx
    mov rdi, rbx
    mov rsi, [rbp - IO_NODE]
    call ast_at
    mov [rax + AstNode.clist], r8d
    mov [rax + AstNode.nchild], r9d
    mov rax, [rbp - IO_NODE]
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC in_boolop

;; in_ternary(Comp *c, node body) -> node   -- body if test else orelse
;;
;; The condition is parsed at BP_OR so it cannot itself be a ternary, and the
;; alternative one level BELOW the ternary so that `a if b else c if d else e`
;; nests to the right.  Parsing it AT BP_TERNARY does not do that: the driver
;; continues only while lbp > min_bp, so an equal power stops -- and the
;; expression came out left-nested, which for `"pos" if x > 0 else "zero" if
;; x == 0 else "neg"` answers "neg" for a positive x.
IT_BODY  equ 16
IT_LINE  equ 24
IT_TEST  equ 32
IT_ELSE  equ 40
IT_NODE  equ 48
IT_FRAME equ 56          ; + 1 push = 64
global in_ternary
DEF_FUNC in_ternary, IT_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - IT_BODY], rsi
    call par_peek
    TOK_POS rax
    mov [rbp - IT_LINE], rcx

    mov rdi, rbx
    call par_advance                    ; consume `if`
    ; The condition is a `disjunction`, so `or` belongs to it -- and BP_OR is
    ; one too high for that, because the driver continues only while
    ; lbp > min_bp.  BP_TERNARY takes `or` and still leaves TOK_IF, whose lbp
    ; *is* BP_TERNARY, so a nested ternary does not get swallowed.  Same shape
    ; as par_comprehension's.
    mov rdi, rbx
    mov esi, BP_TERNARY
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - IT_TEST], rax

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_ELSE
    je .it_have_else
    ; CPython names the construct as `if` and spans the whole conditional --
    ; from the body it was given to where the test ended -- rather than
    ; pointing at the token that should have been `else`.
    mov rdi, rbx
    mov rsi, [rbp - IT_BODY]
    call ast_at
    mov ecx, [rax + AstNode.lineno]
    mov r8d, [rax + AstNode.col]
    push rcx
    push r8
    mov rdi, rbx
    mov esi, [rbp - IT_TEST]
    call ast_span_at
    pop r8
    pop rcx
    mov r9d, ecx
    lea r10d, [r8d + 1]
    test rax, rax
    jz .it_no_span
    cmp dword [rax + AstSpan.end_lineno], -1
    je .it_no_span
    mov r9d, [rax + AstSpan.end_lineno]
    mov r10d, [rax + AstSpan.end_col]
.it_no_span:
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    CSTRING rdx, "expected 'else' after 'if' expression"
    call comp_error_span
    jmp .fail
.it_have_else:
    mov rdi, rbx
    call par_advance

    mov rdi, rbx
    mov esi, BP_WALRUS
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - IT_ELSE], rax

    mov rdi, rbx
    mov esi, AST_IFEXP
    xor edx, edx
    mov rcx, [rbp - IT_LINE]
    mov r8, [rbp - IT_TEST]
    mov r9, [rbp - IT_BODY]
    call ast_make
    mov [rbp - IT_NODE], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - IT_ELSE]
    mov [rax + AstNode.c], edx
    mov rax, [rbp - IT_NODE]
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC in_ternary

;; in_compare(Comp *c, node left) -> node
;;
;; A comparison chain is one node, not a nest: `a < b < c` evaluates b once and
;; short-circuits, which a left-associative fold cannot express.  The child
;; list holds (operator, operand) pairs, so .nchild counts pairs.
;;
;; `not in` and `is not` are two tokens each and are recognised here rather
;; than in the lexer, because `not` and `is` are ordinary operators elsewhere.
IC_LEFT  equ 16
IC_LINE  equ 24
IC_MARK  equ 32
IC_NODE  equ 40
IC_FRAME equ 48          ; + 2 pushes = 64
global in_compare
DEF_FUNC in_compare, IC_FRAME
    push rbx
    push r12
    mov rbx, rdi
    mov [rbp - IC_LEFT], rsi
    call par_peek
    TOK_POS rax
    mov [rbp - IC_LINE], rcx

    mov rdi, rbx
    call ast_mark
    mov [rbp - IC_MARK], rax

.chain:
    mov rdi, rbx
    call par_cmpop                      ; -> eax = CMPOP_*, or -1
    cmp eax, -1
    je .finish
    mov r12d, eax                       ; r12 survives the recursive parse

    mov rdi, rbx
    mov esi, BP_COMPARE
    call par_expr
    test rax, rax
    jz .fail

    mov rdi, rbx
    mov rsi, r12
    push rax
    call ast_push                       ; the operator
    pop rsi
    mov rdi, rbx
    call ast_push                       ; then its right operand
    jmp .chain

.finish:
    mov rdi, rbx
    mov esi, AST_COMPARE
    xor edx, edx
    mov rcx, [rbp - IC_LINE]
    mov r8, [rbp - IC_LEFT]
    xor r9d, r9d
    call ast_make
    mov [rbp - IC_NODE], rax

    mov rdi, rbx
    mov rsi, [rbp - IC_MARK]
    call ast_commit
    mov r8, rax
    shr rdx, 1                          ; two u32 per comparator
    mov r9, rdx
    mov rdi, rbx
    mov rsi, [rbp - IC_NODE]
    call ast_at
    mov [rax + AstNode.clist], r8d
    mov [rax + AstNode.nchild], r9d
    mov rax, [rbp - IC_NODE]
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
END_FUNC in_compare

;; ============================================================================
;; par_cmpop(Comp *c) -> eax = CMPOP_*, or -1 when the next token is not one
;; Consumes the operator, including the second word of `not in` and `is not`.
;; ============================================================================
DEF_FUNC par_cmpop, 8           ; + 1 push = 16
    push rbx
    mov rbx, rdi
    call par_kind
    mov ecx, eax

    cmp ecx, TOK_LESS
    je .lt
    cmp ecx, TOK_GREATER
    je .gt
    cmp ecx, TOK_LESSEQUAL
    je .le
    cmp ecx, TOK_GREATEREQUAL
    je .ge
    cmp ecx, TOK_EQEQUAL
    je .eq
    cmp ecx, TOK_NOTEQUAL
    je .ne
    cmp ecx, TOK_IN
    je .in
    cmp ecx, TOK_IS
    je .is
    cmp ecx, TOK_NOT
    je .notin
    mov eax, -1
    pop rbx
    leave
    ret

.lt: mov r8d, CMPOP_LT
     jmp .one
.gt: mov r8d, CMPOP_GT
     jmp .one
.le: mov r8d, CMPOP_LE
     jmp .one
.ge: mov r8d, CMPOP_GE
     jmp .one
.eq: mov r8d, CMPOP_EQ
     jmp .one
.ne: mov r8d, CMPOP_NE
     jmp .one
.in: mov r8d, CMPOP_IN
.one:
    push r8
    mov rdi, rbx
    call par_advance
    pop rax
    pop rbx
    leave
    ret

.is:
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NOT
    jne .is_plain
    mov rdi, rbx
    call par_advance
    mov eax, CMPOP_ISNOT
    pop rbx
    leave
    ret
.is_plain:
    mov eax, CMPOP_IS
    pop rbx
    leave
    ret

.notin:
    ; A bare `not` here can only be the start of `not in`; anything else ends
    ; the chain, and the caller will fail on it in its own right.
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov esi, TOK_IN
    CSTRING rdx, "expected 'in' after 'not'"
    call par_expect
    test eax, eax
    jz .bad
    mov eax, CMPOP_NOTIN
    pop rbx
    leave
    ret
.bad:
    mov eax, -1
    pop rbx
    leave
    ret
END_FUNC par_cmpop

;; ============================================================================
;; Prefix handlers.  Each consumes its own token and returns a node index.
;; ============================================================================

;; pf_number(Comp *c) -> node
PFN_LINE  equ 16
PFN_FRAME equ 24         ; + 1 push = 32
global pf_number
DEF_FUNC pf_number, PFN_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PFN_LINE], rcx
    mov rdi, rbx
    mov rsi, rax
    call par_number
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_obj                        ; takes ownership of the Value
    mov r8, rax
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov esi, AST_CONST
    xor edx, edx
    mov rcx, [rbp - PFN_LINE]
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
END_FUNC pf_number

;; pf_const(Comp *c) -> node   -- True, False, None share one handler
global pf_const
DEF_FUNC pf_const, PFN_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PFN_LINE], rcx
    movzx edx, word [rax + Token.kind]

    lea rsi, [rel none_singleton]
    cmp edx, TOK_TRUE
    jne .not_true
    lea rsi, [rel bool_true]
    jmp .have
.not_true:
    cmp edx, TOK_FALSE
    jne .not_false
    lea rsi, [rel bool_false]
    jmp .have
.not_false:
    cmp edx, TOK_ELLIPSIS
    jne .have
    lea rsi, [rel ellipsis_singleton]
.have:
    ; These are ordinary heap singletons, and a pointer is its own Value.  They
    ; are immortal, but comp_free will DECREF the table entry, so take a
    ; reference to keep the accounting uniform.
    inc qword [rsi + PyObject.ob_refcnt]
    mov rdi, rbx
    call ast_obj
    mov r8, rax
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov esi, AST_CONST
    xor edx, edx
    mov rcx, [rbp - PFN_LINE]
    xor r9d, r9d
    call ast_make
    pop rbx
    leave
    ret
END_FUNC pf_const

;; pf_name(Comp *c) -> node
PFM_LINE  equ 16
PFM_TOK   equ 24
PFM_FRAME equ 24         ; + 1 push = 32
global pf_name
DEF_FUNC pf_name, PFM_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    mov [rbp - PFM_TOK], rax
    TOK_POS rax
    mov [rbp - PFM_LINE], rcx

    mov rdi, rbx
    mov rsi, [rax + Token.start]
    mov edx, [rax + Token.len]
    extern comp_name_obj
    call comp_name_obj                  ; mangled, with the source name kept
    test rax, rax
    jz .fail
    mov r8, rax
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov esi, AST_NAME
    mov edx, CTX_LOAD
    mov rcx, [rbp - PFM_LINE]
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
END_FUNC pf_name

;; ============================================================================
;; par_exprlist(Comp *c, int close, int *saw_comma) -> rax = child-list mark
;;
;; Parses a comma-separated run up to `close`, pushing each element onto the
;; pending stack.  A trailing comma is allowed and recorded, because for a
;; parenthesised run it is the difference between (a) and (a,).
;;
;; Returns the mark to hand to ast_commit; rax = -1 on error.
;; ============================================================================
PL_CLOSE equ 16
PL_FLAG  equ 24
PL_MARK  equ 32
PL_FRAME equ 40          ; + 1 push = 48
DEF_FUNC par_exprlist, PL_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - PL_CLOSE], rsi
    mov [rbp - PL_FLAG], rdx
    mov qword [rdx], 0

    mov rdi, rbx
    call ast_mark
    mov [rbp - PL_MARK], rax

.loop:
    mov rdi, rbx
    call par_kind
    cmp rax, [rbp - PL_CLOSE]
    je .done
    cmp eax, TOK_ENDMARKER
    je .done

    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    push rax
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    pop rsi

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    je .pl_comma
    ; Two expressions with nothing between them: `f(a b)`.  CPython guesses
    ; what was meant, and spans both.
    push rsi
    mov rdi, rbx
    call par_forgot_comma
    pop rsi
    test eax, eax
    jnz .fail
    jmp .done
.pl_comma:
    mov rdx, [rbp - PL_FLAG]
    mov qword [rdx], 1
    mov rdi, rbx
    call par_advance
    jmp .loop

.done:
    mov rax, [rbp - PL_MARK]
    pop rbx
    leave
    ret
.fail:
    mov rax, -1
    pop rbx
    leave
    ret
END_FUNC par_exprlist

;; ============================================================================
;; par_finish_list(Comp *c, int kind, int line, uint64_t mark) -> node
;; Commits the staged children onto a fresh node.
;; ============================================================================
PF_MARK  equ 16
PF_NODE  equ 24
PF_FRAME equ 24          ; + 1 push = 32
DEF_FUNC par_finish_list, PF_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - PF_MARK], rcx
    xor r8d, r8d
    xor r9d, r9d
    mov rcx, rdx                        ; lineno
    xor edx, edx                    ; subkind
    call ast_make
    mov [rbp - PF_NODE], rax
    mov rdi, rbx
    mov rsi, [rbp - PF_MARK]
    call ast_commit
    mov r8, rax
    mov r9, rdx
    mov rdi, rbx
    mov rsi, [rbp - PF_NODE]
    call ast_at
    mov [rax + AstNode.clist], r8d
    mov [rax + AstNode.nchild], r9d
    mov rax, [rbp - PF_NODE]
    pop rbx
    leave
    ret
END_FUNC par_finish_list

;; ============================================================================
;; pf_group(Comp *c) -> node   -- (), (a), (a, b), (a,)
;;
;; A parenthesised single expression is just that expression; it becomes a
;; tuple only when a comma appears.  That is why the trailing-comma flag is
;; tracked: (a) is a, and (a,) is a one-tuple.
;; ============================================================================
PG_LINE  equ 16
PG_MARK  equ 24
PG_COMMA equ 32
PG_FRAME equ 40          ; + 1 push = 48
global pf_group
DEF_FUNC pf_group, PG_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PG_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; consume '('

    ; `(x for ...)` is a generator expression rather than a group; as with a
    ; list, the two are the same production until the token after the element.
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_RPAR
    je .as_list
    mov rdi, rbx
    call par_peek_second_is_for
    test eax, eax
    jz .as_list
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov esi, AST_GENEXP
    mov rdx, rax
    xor ecx, ecx
    mov r8, [rbp - PG_LINE]
    mov r9, TOK_RPAR
    call par_comprehension
    pop rbx
    leave
    ret

.as_list:
    mov rdi, rbx
    mov esi, TOK_RPAR
    lea rdx, [rbp - PG_COMMA]
    call par_exprlist
    cmp rax, -1
    je .fail
    mov [rbp - PG_MARK], rax

    mov rdi, rbx
    mov esi, TOK_RPAR
    CSTRING rdx, "invalid syntax"
    call par_expect
    test eax, eax
    jz .fail

    ; One element and no comma: the parentheses were only grouping.
    mov rax, [rbx + Comp.pending + Buf.len]
    sub rax, [rbp - PG_MARK]
    cmp rax, 1
    jne .make_tuple
    cmp qword [rbp - PG_COMMA], 0
    jne .make_tuple
    mov rax, [rbx + Comp.pending + Buf.data]
    mov rcx, [rbx + Comp.pending + Buf.len]
    dec rcx
    mov eax, [rax + rcx*4]
    mov [rbx + Comp.pending + Buf.len], rcx
    pop rbx
    leave
    ret

.make_tuple:
    mov rdi, rbx
    mov esi, AST_TUPLE
    mov rdx, [rbp - PG_LINE]
    mov rcx, [rbp - PG_MARK]
    call par_finish_list
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC pf_group

;; ============================================================================
;; pf_list(Comp *c) -> node   -- [a, b] or [e for x in it]
;;
;; A display and a comprehension are the same production until the token after
;; the first element, so the element is parsed once and the shape decided
;; afterwards.
;; ============================================================================
global pf_list
DEF_FUNC pf_list, PG_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PG_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; consume '['
    mov qword [rbp - PG_COMMA], 0

    mov rdi, rbx
    call ast_mark
    mov [rbp - PG_MARK], rax

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_RSQB
    je .close                           ; []

    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov r8, rax

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_FOR
    je .comp
    cmp eax, TOK_ASYNC
    je .comp

    mov rdi, rbx
    mov rsi, r8
    call ast_push
.more:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    je .comma_ok
    mov rdi, rbx
    call par_last_pushed
    mov rsi, rax
    mov rdi, rbx
    call par_forgot_comma
    test eax, eax
    jnz .fail
    jmp .close
.comma_ok:
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_RSQB
    je .close                           ; a trailing comma
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    jmp .more

.close:
    mov rdi, rbx
    mov esi, TOK_RSQB
    CSTRING rdx, "invalid syntax"
    call par_expect
    test eax, eax
    jz .fail
    mov rdi, rbx
    mov esi, AST_LIST
    mov rdx, [rbp - PG_LINE]
    mov rcx, [rbp - PG_MARK]
    call par_finish_list
    pop rbx
    leave
    ret

.comp:
    mov rdi, rbx
    mov esi, AST_LISTCOMP
    mov rdx, r8
    xor ecx, ecx
    mov r8, [rbp - PG_LINE]
    mov r9, TOK_RSQB
    call par_comprehension
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC pf_list

;; ============================================================================
;; pf_dictset(Comp *c) -> node   -- {}, {a: b}, {a, b}, {**m}
;;
;; One opening brace, three possible displays.  Which it is is decided by the
;; token after the first element: a colon means a dict, anything else a set, and
;; a bare `**` means a dict too.  An empty {} is a dict, not a set, because
;; there is no set literal for the empty set.
;; ============================================================================
PD_LINE  equ 16
PD_MARK  equ 24
PD_ISDICT equ 32
PD_KEY    equ 40
PD_VALUE  equ 48
PD_FRAME equ 56          ; + 1 push = 64
global pf_dictset
DEF_FUNC pf_dictset, PD_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PD_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; consume '{'

    mov rdi, rbx
    call ast_mark
    mov [rbp - PD_MARK], rax
    mov qword [rbp - PD_ISDICT], 1      ; an empty {} is a dict

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_RBRACE
    je .close

    ; The first element decides the shape.
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_DOUBLESTAR
    je .dict_unpack                     ; {**m, ...}: a dict, and parse it now
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov r8, rax
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COLON
    je .dict_first
    cmp eax, TOK_FOR
    je .setcomp
    cmp eax, TOK_ASYNC
    je .setcomp
    ; A set: push what we already parsed and carry on.
    mov qword [rbp - PD_ISDICT], 0
    mov rdi, rbx
    mov rsi, r8
    call ast_push
    jmp .more
.setcomp:
    mov rdi, rbx
    mov esi, AST_SETCOMP
    mov rdx, r8
    xor ecx, ecx
    mov r8, [rbp - PD_LINE]
    mov r9, TOK_RBRACE
    call par_comprehension
    pop rbx
    leave
    ret
.dict_first:
    mov [rbp - PD_KEY], r8
    mov rdi, rbx
    call par_peek
    mov ecx, [rax + Token.lineno]
    mov r8d, [rax + Token.col]
    push rcx
    push r8
    mov rdi, rbx
    call par_advance                    ; consume ':'
    ; CPython names what is missing rather than saying "invalid syntax", and
    ; blames the colon it should have followed.
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_RBRACE
    jne .dict_value
    pop r8
    pop rcx
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    CSTRING rdx, "expression expected after dictionary key and ':'"
    call comp_error
    jmp .fail
.dict_value:
    add rsp, 16
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PD_VALUE], rax
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_FOR
    je .dictcomp
    cmp eax, TOK_ASYNC
    je .dictcomp
    mov rdi, rbx
    mov rsi, [rbp - PD_KEY]
    call ast_push
    mov rdi, rbx
    mov rsi, [rbp - PD_VALUE]
    call ast_push
    jmp .more
.dictcomp:
    mov rdi, rbx
    mov esi, AST_DICTCOMP
    mov rdx, [rbp - PD_KEY]
    mov rcx, [rbp - PD_VALUE]
    mov r8, [rbp - PD_LINE]
    mov r9, TOK_RBRACE
    call par_comprehension
    pop rbx
    leave
    ret

.more:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    je .comma_ok
    mov rdi, rbx
    call par_last_pushed
    mov rsi, rax
    mov rdi, rbx
    call par_forgot_comma
    test eax, eax
    jnz .fail
    jmp .close
.comma_ok:
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_RBRACE
    je .close                           ; a trailing comma

    cmp qword [rbp - PD_ISDICT], 0
    je .set_item

    ; dict: either `**m` or `key: value`
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_DOUBLESTAR
    je .dict_unpack
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    mov rdi, rbx
    mov esi, TOK_COLON
    CSTRING rdx, "expected ':' in dict display"
    call par_expect
    test eax, eax
    jz .fail
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    jmp .more
.dict_unpack:
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr                       ; pf_starred builds the ** node
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    ; A ** entry occupies one slot where a pair occupies two; pushing the node
    ; twice keeps the list in key/value pairs so codegen can walk it uniformly.
    mov rdi, rbx
    xor esi, esi
    call ast_push
    jmp .more

.set_item:
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    jmp .more

.close:
    mov rdi, rbx
    mov esi, TOK_RBRACE
    CSTRING rdx, "invalid syntax"
    call par_expect
    test eax, eax
    jz .fail

    mov esi, AST_SET
    cmp qword [rbp - PD_ISDICT], 0
    je .have_kind
    mov esi, AST_DICT
.have_kind:
    mov rdi, rbx
    mov rdx, [rbp - PD_LINE]
    mov rcx, [rbp - PD_MARK]
    call par_finish_list
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC pf_dictset

;; ============================================================================
;; pf_starred(Comp *c) -> node   -- *x and **x
;; Legal only inside a display, a call or a target list; the emitters reject it
;; anywhere else, which is what makes `*x + 1` a syntax error.
;; ============================================================================
;; ============================================================================
;; pf_starred_call(Comp *c) -> node   -- the same, for a CALL's argument list
;;
;; CPython has two productions and they take different operands.  A display,
;; an assignment target and a for target use `star_expressions`, whose star
;; takes a bitwise_or -- which is what the note below is about, and why
;; BP_STAROP cannot simply be lowered.  A call argument uses
;; `starred_expression: '*' expression`, which admits or/and/not, a
;; comparison and a ternary, and stops only at the walrus.  So `d(*() or (1,))`
;; is legal there and `[*a or b]` is not, and one binding power cannot say
;; both.
;; ============================================================================
PST_LINE  equ 16
PST_KIND  equ 24
PST_BP    equ 32
PST_FRAME equ 40         ; + 1 push = 48
;; The prefix rule the grammar table names: a display, an assignment target
;; or a for target.  pf_starred(Comp *c) -> node
global pf_starred
DEF_FUNC_BARE pf_starred
    mov esi, BP_STAROP
    jmp pf_starred_bp
END_FUNC pf_starred

;; The same star inside a call's argument list, whose operand reaches further.
;; pf_starred_call(Comp *c) -> node
global pf_starred_call
DEF_FUNC_BARE pf_starred_call
    mov esi, BP_WALRUS
    jmp pf_starred_bp
END_FUNC pf_starred_call

;; The body both reach.
;; pf_starred_bp(Comp *c, esi = the operand's binding power) -> node, or 0
DEF_FUNC pf_starred_bp, PST_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - PST_BP], rsi
    call par_peek
    TOK_POS rax
    mov [rbp - PST_LINE], rcx
    movzx eax, word [rax + Token.kind]
    mov edx, AST_STARRED
    cmp eax, TOK_DOUBLESTAR
    jne .have
    mov edx, AST_DOUBLESTARRED
.have:
    mov [rbp - PST_KIND], rdx
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    ; A star takes an or_expr: `[*a | b]` is `[*(a | b)]`, while `[*a in b]`
    ; and `[*a or b]` are syntax errors.  Recursing below BP_COMPARE swallowed
    ; the `in` of a for statement, so `for a, *b in z` had no loop keyword left
    ; -- while `for *a, b in z` parsed, because there the star was not the
    ; element the `in` followed.
    ; A star with nothing after it: `f(*)`.  CPython refuses it by name, and
    ; capitalises it, which nothing else in its messages does.
    call par_kind
    cmp eax, TOK_RPAR
    je .pst_bare
    cmp eax, TOK_RSQB
    je .pst_bare
    cmp eax, TOK_RBRACE
    je .pst_bare
    cmp eax, TOK_COMMA
    je .pst_bare
    mov rdi, rbx
    mov rsi, [rbp - PST_BP]
    call par_expr
    test rax, rax
    jz .fail
    mov r8, rax
    mov rdi, rbx
    mov rsi, [rbp - PST_KIND]
    xor edx, edx
    mov rcx, [rbp - PST_LINE]
    xor r9d, r9d
    call ast_make
    pop rbx
    leave
    ret
.pst_bare:
    ; `f(*)` is CPython's "Invalid star expression", capital and all; `f(**)`
    ; and `{**}` are only "invalid syntax", so the wording follows which of
    ; the two stars this was.  A trailing comma -- `x = *,` -- is the plain
    ; message too.
    mov rdi, rbx
    CSTRING rsi, "invalid syntax"
    cmp qword [rbp - PST_KIND], AST_STARRED
    jne .pst_say
    cmp eax, TOK_COMMA
    je .pst_say
    CSTRING rsi, "Invalid star expression"
.pst_say:
    call par_syntax_error
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC pf_starred_bp

;; ============================================================================
;; in_attr(Comp *c, node value) -> node   -- value.name
;; ============================================================================
IA_VAL   equ 16
IA_LINE  equ 24
IA_FRAME equ 24          ; + 1 push = 32
global in_attr
DEF_FUNC in_attr, IA_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - IA_VAL], rsi
    call par_peek
    TOK_POS rax
    mov [rbp - IA_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; consume '.'

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NAME
    jne .need_name
    mov rdi, rbx
    call par_peek
    mov rdi, rbx
    mov rsi, [rax + Token.start]
    mov edx, [rax + Token.len]
    call comp_name_obj                  ; an attribute name mangles too
    test rax, rax
    jz .fail
    mov r9, rax
    mov rdi, rbx
    call par_advance

    mov rdi, rbx
    mov esi, AST_ATTRIBUTE
    mov edx, CTX_LOAD
    mov rcx, [rbp - IA_LINE]
    mov r8, [rbp - IA_VAL]
    call ast_make
    pop rbx
    leave
    ret
.need_name:
    mov rdi, rbx
    CSTRING rsi, "invalid syntax"
    call par_syntax_error
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC in_attr

;; ============================================================================
;; par_slice_piece(Comp *c) -> node, or 0 for an omitted bound
;; ============================================================================
DEF_FUNC par_slice_piece, 8
    push rbx
    mov rbx, rdi
    call par_kind
    cmp eax, TOK_COLON
    je .omitted
    cmp eax, TOK_RSQB
    je .omitted
    cmp eax, TOK_COMMA
    je .omitted
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    pop rbx
    leave
    ret
.omitted:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_slice_piece

;; ============================================================================
;; par_subscript_item(Comp *c) -> node   -- one index or one slice
;; The piece between the brackets, or between two commas: `a`, `a:b`, `a:b:c`,
;; `:`, `::2` all land here.
;; ============================================================================
SI_LOWER equ 8
SI_UPPER equ 16
SI_STEP  equ 24
SI_SLICE equ 32
SI_LINE  equ 40
SI_FRAME equ 40           ; + 1 push = 48
DEF_FUNC_LOCAL par_subscript_item, SI_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - SI_LINE], rcx
    mov qword [rbp - SI_UPPER], 0
    mov qword [rbp - SI_STEP], 0
    mov qword [rbp - SI_SLICE], 0

    mov rdi, rbx
    call par_slice_piece
    mov [rbp - SI_LOWER], rax

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COLON
    jne .plain

    mov qword [rbp - SI_SLICE], 2       ; at least lower:upper
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call par_slice_piece
    mov [rbp - SI_UPPER], rax

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COLON
    jne .make_slice
    mov qword [rbp - SI_SLICE], 3
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call par_slice_piece
    mov [rbp - SI_STEP], rax
    jmp .make_slice

.plain:
    ; A missing index is only legal as part of a slice: `d[]` is not.
    cmp qword [rbp - SI_LOWER], 0
    je .need_index
    mov rax, [rbp - SI_LOWER]
    pop rbx
    leave
    ret

.make_slice:
    mov rdi, rbx
    mov esi, AST_SLICE
    mov rdx, [rbp - SI_SLICE]           ; subkind: 2 or 3 pieces
    mov rcx, [rbp - SI_LINE]
    mov r8, [rbp - SI_LOWER]
    mov r9, [rbp - SI_UPPER]
    call ast_make
    test rax, rax
    jz .fail
    mov [rbp - SI_LOWER], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - SI_STEP]
    mov [rax + AstNode.c], edx
    mov rax, [rbp - SI_LOWER]
    pop rbx
    leave
    ret

.need_index:
    mov rdi, rbx
    CSTRING rsi, "expected an index expression"
    call par_syntax_error
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_subscript_item

;; ============================================================================
;; in_subscript(Comp *c, node value) -> node   -- value[index]
;;
;; A comma inside the brackets makes the index a tuple: `d[1, 2]` subscripts
;; with `(1, 2)`, and `d[a:b, c]` with `(slice(a, b), c)`.  There is no
;; separate n-ary subscript node -- the tuple IS the index, which is why
;; `d[1,]` and `d[(1,)]` are the same expression.
;; ============================================================================
IS_VAL   equ 16
IS_LINE  equ 24
IS_IDX   equ 32
IS_MARK  equ 40
IS_ILINE equ 48           ; the first index item, where an implicit tuple starts
IS_FRAME equ 56           ; + 1 push = 64
global in_subscript
DEF_FUNC in_subscript, IS_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - IS_VAL], rsi
    call par_peek
    TOK_POS rax
    mov [rbp - IS_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; consume '['

    ; An implicit tuple index starts at the first item, not at the bracket.
    mov rdi, rbx
    call par_peek
    TOK_POS rax
    mov [rbp - IS_ILINE], rcx
    mov rdi, rbx
    call par_subscript_item
    test rax, rax
    jz .fail
    mov [rbp - IS_IDX], rax

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    jne .lone_item

    ; A tuple index.  The first item is already parsed, so it is pushed before
    ; the loop rather than inside it.
    mov rdi, rbx
    call ast_mark
    mov [rbp - IS_MARK], rax
    mov rdi, rbx
    mov rsi, [rbp - IS_IDX]
    call ast_push
.comma_loop:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    jne .finish_tuple
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_RSQB
    je .finish_tuple                    ; a trailing comma
    mov rdi, rbx
    call par_subscript_item
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    jmp .comma_loop

.lone_item:
    ; `Generic[*Ts]` is Subscript(slice=Tuple(elts=[Starred(...)])) in CPython,
    ; the shape `Generic[*Ts,]` and `Generic[int, *Ts]` already take here.  A
    ; bare Starred reached cg_expr instead, which has no emitter for one and
    ; reported "can't use starred expression here".  Confined to a subscript,
    ; so `x = *Ts` keeps its own, correct error.
    mov rdi, rbx
    mov esi, [rbp - IS_IDX]
    call ast_at
    movzx ecx, byte [rax + AstNode.kind]
    cmp ecx, AST_STARRED
    jne .close
    mov rdi, rbx
    call ast_mark
    mov [rbp - IS_MARK], rax
    mov rdi, rbx
    mov rsi, [rbp - IS_IDX]
    call ast_push

.finish_tuple:
    mov rdi, rbx
    mov esi, AST_TUPLE
    mov rdx, [rbp - IS_ILINE]
    mov rcx, [rbp - IS_MARK]
    call par_finish_list
    test rax, rax
    jz .fail
    mov [rbp - IS_IDX], rax

.close:
    mov rdi, rbx
    mov esi, TOK_RSQB
    CSTRING rdx, "invalid syntax"
    call par_expect
    test eax, eax
    jz .fail

    mov rdi, rbx
    mov esi, AST_SUBSCRIPT
    mov edx, CTX_LOAD
    mov rcx, [rbp - IS_LINE]
    mov r8, [rbp - IS_VAL]
    mov r9, [rbp - IS_IDX]
    call ast_make
    pop rbx
    leave
    ret

.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC in_subscript

;; ============================================================================
;; in_call(Comp *c, node func) -> node   -- func(args)
;;
;; The child list holds the arguments in source order.  A keyword argument is
;; an AST_KEYWORD node carrying its name, and `*a` / `**k` are AST_STARRED and
;; AST_DOUBLESTARRED; codegen decides from what it finds whether a plain CALL
;; will do or whether the call has to be assembled through CALL_FUNCTION_EX.
;; ============================================================================
ICL_FUNC  equ 16
ICL_LINE  equ 24
ICL_MARK  equ 32
ICL_NAME  equ 40
ICL_GEN   equ 48         ; a bare genexp argument, which ends at the call's ')'
ICL_KWLINE equ 56        ; where one keyword argument's own name is
ICL_SAWKW  equ 64        ; a named keyword has gone by
ICL_SAWKWU equ 72        ; and a `**kwds`
ICL_ERRMSG equ 80        ; the out-of-order message, held until the ')'
ICL_ERRPOS equ 88        ; where its span starts, or 0 for the ')' itself
ICL_COMMA  equ 96        ; the separator before the argument being parsed
ICL_NODE   equ 104       ; the argument just built
ICL_RPAR   equ 112       ; where the closing ')' is
ICL_FRAME equ 120        ; + 1 push = 128
global in_call
DEF_FUNC in_call, ICL_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - ICL_FUNC], rsi
    mov qword [rbp - ICL_GEN], 0
    mov qword [rbp - ICL_SAWKW], 0
    mov qword [rbp - ICL_SAWKWU], 0
    mov qword [rbp - ICL_ERRMSG], 0
    mov qword [rbp - ICL_COMMA], 0
    call par_peek
    TOK_POS rax
    mov [rbp - ICL_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; consume '('

    mov rdi, rbx
    call ast_mark
    mov [rbp - ICL_MARK], rax

.arg_loop:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_RPAR
    je .close
    cmp eax, TOK_ENDMARKER
    je .close

    ; A keyword argument is NAME '=' expr, and only that: the '=' has to be
    ; the very next token, or `f(a == b)` would be misread.
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NAME
    jne .positional
    mov rdi, rbx
    call par_peek_next
    cmp eax, TOK_EQUAL
    jne .positional

    mov rdi, rbx
    call par_peek
    ; The keyword is at its own name, not at the call's '('.
    TOK_POS rax
    mov [rbp - ICL_KWLINE], rcx
    mov rdi, [rax + Token.start]
    mov esi, [rax + Token.len]
    call comp_intern
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_obj
    mov [rbp - ICL_NAME], rax
    mov rdi, rbx
    call par_advance                    ; the name
    mov rdi, rbx
    call par_advance                    ; the '='
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov r9, rax
    mov rdi, rbx
    mov esi, AST_KEYWORD
    xor edx, edx
    mov rcx, [rbp - ICL_KWLINE]
    mov r8, [rbp - ICL_NAME]
    call ast_make
    jmp .push_arg

.positional:
    ; A star in an ARGUMENT list takes a whole expression, not a bitwise_or --
    ; see pf_starred_call.  par_expr would reach pf_starred, which is the
    ; display and target-list rule, so the star is consumed here instead.
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_STAR
    je .star_arg
    cmp eax, TOK_DOUBLESTAR
    je .star_arg
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    jmp .arg_parsed
.star_arg:
    mov rdi, rbx
    extern pf_starred_call
    call pf_starred_call
    test rax, rax
    jz .fail
.arg_parsed:
    ; `f(x for x in y)` is a generator expression as the sole argument, with no
    ; parentheses of its own -- the call's own brackets serve.
    push rax
    mov rdi, rbx
    call par_kind
    mov ecx, eax
    pop rax
    cmp ecx, TOK_FOR
    je .genexp_arg
    cmp ecx, TOK_ASYNC
    je .genexp_arg
    jmp .push_arg
.genexp_arg:
    mov rdi, rbx
    mov esi, AST_GENEXP
    mov rdx, rax
    xor ecx, ecx
    mov r8, [rbp - ICL_LINE]
    xor r9d, r9d                        ; the caller consumes the ')'
    call par_comprehension
    test rax, rax
    jz .fail
    mov [rbp - ICL_GEN], rax
.push_arg:
    ; Argument order.  CPython's parser rejects a positional after a keyword
    ; and a `*a` after a `**k`; ours accepted `f(a=1, b)` outright, and the
    ; class statement reported its own half of this from codegen, where it
    ; also fired on the legal `class C(metaclass=M, *bs)`.  The message is
    ; held until the ')' because that is where CPython's span points.
    mov [rbp - ICL_NODE], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    movzx eax, byte [rax + AstNode.kind]
    cmp eax, AST_KEYWORD
    je .ord_kw
    cmp eax, AST_DOUBLESTARRED
    je .ord_kwunpack
    cmp eax, AST_STARRED
    je .ord_star
    cmp qword [rbp - ICL_SAWKWU], 0
    jne .ord_after_kwunpack
    cmp qword [rbp - ICL_SAWKW], 0
    jne .ord_after_kw
    jmp .ord_done
.ord_kw:
    mov qword [rbp - ICL_SAWKW], 1
    jmp .ord_done
.ord_kwunpack:
    mov qword [rbp - ICL_SAWKWU], 1
    mov qword [rbp - ICL_SAWKW], 1
    jmp .ord_done
.ord_star:
    cmp qword [rbp - ICL_SAWKWU], 0
    je .ord_done
    ; This one's span starts at the separating comma, not at the ')'.
    CSTRING rax, "iterable argument unpacking follows keyword argument unpacking"
    cmp qword [rbp - ICL_ERRMSG], 0
    jne .ord_done
    mov [rbp - ICL_ERRMSG], rax
    mov rax, [rbp - ICL_COMMA]
    mov [rbp - ICL_ERRPOS], rax
    jmp .ord_done
.ord_after_kwunpack:
    CSTRING rax, "positional argument follows keyword argument unpacking"
    jmp .ord_record
.ord_after_kw:
    CSTRING rax, "positional argument follows keyword argument"
.ord_record:
    cmp qword [rbp - ICL_ERRMSG], 0
    jne .ord_done
    mov [rbp - ICL_ERRMSG], rax
    mov qword [rbp - ICL_ERRPOS], 0
.ord_done:
    mov rdi, rbx
    mov rsi, [rbp - ICL_NODE]
    call ast_push

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    je .comma_ok
    mov rdi, rbx
    call par_last_pushed
    mov rsi, rax
    mov rdi, rbx
    call par_forgot_comma
    test eax, eax
    jnz .fail
    jmp .close
.comma_ok:
    mov rdi, rbx
    call par_peek
    TOK_POS rax
    mov [rbp - ICL_COMMA], rcx
    mov rdi, rbx
    call par_advance
    jmp .arg_loop

.close:
    mov rdi, rbx
    call par_peek
    TOK_POS rax
    mov [rbp - ICL_RPAR], rcx
    mov rdi, rbx
    mov esi, TOK_RPAR
    CSTRING rdx, "invalid syntax"
    call par_expect
    test eax, eax
    jz .fail

    cmp qword [rbp - ICL_ERRMSG], 0
    je .ord_ok
    mov rdx, [rbp - ICL_ERRMSG]
    mov r9, [rbp - ICL_RPAR]
    mov r10, r9
    shr r10, 32                         ; the ')' column
    mov r9d, r9d                        ; and its line
    mov rax, [rbp - ICL_ERRPOS]
    test rax, rax
    jnz .ord_start
    ; With no span of its own the error points AT the ')', one character
    ; wide; a span ENDS where the ')' begins, just past the last argument.
    mov rax, [rbp - ICL_RPAR]
    inc r10d
.ord_start:
    mov r8, rax
    shr r8, 32                          ; the span's column
    mov ecx, eax                        ; and its line
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    extern comp_error_span
    call comp_error_span
    jmp .fail
.ord_ok:

    ; An unparenthesised genexp argument borrows the call's own ')'.
    cmp qword [rbp - ICL_GEN], 0
    je .no_genexp
    mov rdi, rbx
    mov esi, [rbp - ICL_GEN]
    call ast_end_here
.no_genexp:
    mov rdi, rbx
    mov esi, AST_CALL
    xor edx, edx
    mov rcx, [rbp - ICL_LINE]
    mov r8, [rbp - ICL_FUNC]
    xor r9d, r9d
    call ast_make
    mov [rbp - ICL_NAME], rax
    mov rdi, rbx
    mov rsi, [rbp - ICL_MARK]
    call ast_commit
    mov r8, rax
    mov r9, rdx
    mov rdi, rbx
    mov rsi, [rbp - ICL_NAME]
    call ast_at
    mov [rax + AstNode.clist], r8d
    mov [rax + AstNode.nchild], r9d
    mov rax, [rbp - ICL_NAME]
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC in_call

;; ============================================================================
;; in_call_public(Comp *c, node func) -> node
;; The class statement's base list is an argument list, keywords and all, so it
;; is parsed by the same code rather than a near-copy of it.
;; ============================================================================
DEF_FUNC_BARE in_call_public
    jmp in_call
END_FUNC in_call_public

;; ============================================================================
;; par_peek_next(Comp *c) -> eax = the kind of the token after the current one
;; One token of lookahead, which is all the grammar needs at a point where an
;; array of tokens makes it free.
;; ============================================================================
DEF_FUNC_BARE par_peek_next
    mov eax, [rdi + Comp.tok_idx]
    inc eax
    mov rcx, [rdi + Comp.tokens + Buf.len]
    dec rcx
    cmp rax, rcx
    jbe .ok
    mov eax, ecx
.ok:
    mov rdx, [rdi + Comp.tokens + Buf.data]
    shl rax, TOKEN_SHIFT
    movzx eax, word [rdx + rax + Token.kind]
    ret
END_FUNC par_peek_next

;; ============================================================================
;; pf_lambda(Comp *c) -> node   -- `lambda params: expr`
;;
;; The body is parsed one level below the ternary, so `lambda x: a if c else b`
;; is a lambda returning a conditional -- at BP_TERNARY the `if` binds no
;; tighter than the minimum and stops, leaving the lambda as the conditional's
;; body and its parameter out of scope.  A comma is still not part of the body,
;; because a comma is not in the table at all: `lambda: a, b` is a tuple
;; containing a lambda.
;; ============================================================================
PLM_LINE  equ 16
PLM_ARGS  equ 24
PLM_NODE  equ 32
PLM_FRAME equ 40          ; + 1 push = 48
global pf_lambda
DEF_FUNC pf_lambda, PLM_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PLM_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; `lambda`

    mov rdi, rbx
    mov esi, TOK_COLON
    call par_params
    test rax, rax
    jz .fail
    mov [rbp - PLM_ARGS], rax

    mov rdi, rbx
    mov esi, TOK_COLON
    CSTRING rdx, "expected ':' after the lambda parameters"
    call par_expect
    test eax, eax
    jz .fail

    mov rdi, rbx
    mov esi, BP_WALRUS
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PLM_NODE], rax

    mov rdi, rbx
    mov esi, AST_LAMBDA
    xor edx, edx
    mov rcx, [rbp - PLM_LINE]
    xor r8d, r8d
    mov r9, [rbp - PLM_ARGS]
    call ast_make
    mov [rbp - PLM_ARGS], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - PLM_NODE]
    mov [rax + AstNode.c], edx          ; the body expression
    mov rax, [rbp - PLM_ARGS]
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC pf_lambda

;; ============================================================================
;; par_comprehension(Comp *c, int kind, uint32_t elt, uint32_t val, int line,
;;                   int close) -> node
;;
;; The `for` clauses of a comprehension, after its element has been parsed.
;; Each clause is an AST_COMPREHENSION carrying a target, an iterable and any
;; number of conditions; nesting is left to right, so `[x for a in b for x in a]`
;; is two clauses in that order.
;;
;; The iterable of each clause is parsed at BP_OR so a trailing `if` belongs to
;; the comprehension rather than becoming a conditional expression -- that is
;; what the minimum binding power is for.
;; ============================================================================
PCM_KIND  equ 8
PCM_ELT   equ 16
PCM_VAL   equ 24
PCM_LINE  equ 32
PCM_CLOSE equ 40
PCM_MARK  equ 48
PCM_TGT   equ 56
PCM_ITER  equ 64
PCM_CMARK equ 72
PCM_NODE  equ 80
PCM_ASYNC equ 88
PCM_FRAME equ 88          ; + 1 push = 96
DEF_FUNC par_comprehension, PCM_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - PCM_KIND], rsi
    mov [rbp - PCM_ELT], rdx
    mov [rbp - PCM_VAL], rcx
    mov [rbp - PCM_LINE], r8
    mov [rbp - PCM_CLOSE], r9

    mov rdi, rbx
    call ast_mark
    mov [rbp - PCM_MARK], rax

.clause:
    mov qword [rbp - PCM_ASYNC], 0
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_ASYNC
    jne .not_async
    mov qword [rbp - PCM_ASYNC], 1
    mov rdi, rbx
    call par_advance
.not_async:
    mov rdi, rbx
    mov esi, TOK_FOR
    CSTRING rdx, "expected 'for' in comprehension"
    call par_expect
    test eax, eax
    jz .fail

    mov rdi, rbx
    call par_for_target
    test rax, rax
    jz .fail
    mov [rbp - PCM_TGT], rax

    mov rdi, rbx
    mov esi, TOK_IN
    CSTRING rdx, "expected 'in' in comprehension"
    call par_expect
    test eax, eax
    jz .fail

    ; Both the iterable and each condition are a `disjunction`, so `or` and
    ; `and` belong to them and the ternary `if` does not.  BP_TERNARY is
    ; exactly that line: the driver continues while lbp > min_bp, so `or` (6)
    ; is taken and TOK_IF, whose lbp *is* BP_TERNARY, is left to us.  Asking
    ; for BP_OR here stopped one operator too early and reported the `or` as
    ; an unclosed comprehension.
    mov rdi, rbx
    mov esi, BP_TERNARY
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PCM_ITER], rax

    ; Any number of conditions.
    mov rdi, rbx
    call ast_mark
    mov [rbp - PCM_CMARK], rax
.conds:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_IF
    jne .close_clause
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    mov esi, BP_TERNARY                 ; a disjunction; see above
    call par_expr
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    jmp .conds

.close_clause:
    mov rdi, rbx
    mov esi, AST_COMPREHENSION
    mov rdx, [rbp - PCM_LINE]
    mov rcx, [rbp - PCM_CMARK]
    call par_finish_list
    test rax, rax
    jz .fail
    mov [rbp - PCM_NODE], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - PCM_TGT]
    mov [rax + AstNode.a], edx
    mov rdx, [rbp - PCM_ITER]
    mov [rax + AstNode.b], edx
    mov rdx, [rbp - PCM_ASYNC]
    mov [rax + AstNode.subkind], dl
    mov rdi, rbx
    mov rsi, [rbp - PCM_NODE]
    call ast_push

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_FOR
    je .clause
    cmp eax, TOK_ASYNC
    je .clause

    ; Close the comprehension itself.
    mov rdi, rbx
    mov rsi, [rbp - PCM_KIND]
    mov rdx, [rbp - PCM_LINE]
    mov rcx, [rbp - PCM_MARK]
    call par_finish_list
    test rax, rax
    jz .fail
    mov [rbp - PCM_NODE], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov rdx, [rbp - PCM_ELT]
    mov [rax + AstNode.a], edx
    mov rdx, [rbp - PCM_VAL]
    mov [rax + AstNode.b], edx

    cmp qword [rbp - PCM_CLOSE], 0
    je .done
    mov rdi, rbx
    mov rsi, [rbp - PCM_CLOSE]
    CSTRING rdx, "invalid syntax"
    call par_expect
    test eax, eax
    jz .fail
.done:
    ; The node was made before the bracket that closes it; CPython's span
    ; takes that bracket in.
    mov rdi, rbx
    mov esi, [rbp - PCM_NODE]
    call ast_end_here
    mov rax, [rbp - PCM_NODE]
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_comprehension

;; ============================================================================
;; par_peek_second_is_for(Comp *c) -> rax = 1 when a `for` follows the first
;; element of the bracketed run, without consuming anything.
;;
;; A generator expression cannot be told from a parenthesised expression by one
;; token of lookahead, so this scans ahead to the matching depth.  It is the
;; only place the parser looks further than the next token, and having the
;; whole token array is what makes it a loop rather than a re-lex.
;; ============================================================================
DEF_FUNC par_peek_second_is_for, 8
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, [rdi + Comp.tok_idx]
    mov r13, [rdi + Comp.tokens + Buf.len]
    xor ecx, ecx                        ; bracket depth
    ; Start AT the current token, not after it: `([x for x in y], z)` opens a
    ; bracket first, and skipping it would leave the inner `for` looking like a
    ; top-level one.
.loop:
    cmp r12, r13
    jae .no
    mov rax, [rbx + Comp.tokens + Buf.data]
    mov rdx, r12
    shl rdx, TOKEN_SHIFT
    movzx eax, word [rax + rdx + Token.kind]
    cmp eax, TOK_ENDMARKER
    je .no
    cmp eax, TOK_LPAR
    je .deeper
    cmp eax, TOK_LSQB
    je .deeper
    cmp eax, TOK_LBRACE
    je .deeper
    cmp eax, TOK_RPAR
    je .shallower
    cmp eax, TOK_RSQB
    je .shallower
    cmp eax, TOK_RBRACE
    je .shallower
    test ecx, ecx
    jnz .next                           ; inside brackets: keep scanning
    cmp eax, TOK_FOR
    je .yes
    cmp eax, TOK_COMMA
    je .no                              ; a tuple, not a comprehension
    jmp .next
.deeper:
    inc ecx
    jmp .next
.shallower:
    test ecx, ecx
    jz .no                              ; the closing bracket of our own run
    dec ecx
.next:
    inc r12
    jmp .loop
.yes:
    mov eax, 1
    jmp .ret
.no:
    xor eax, eax
.ret:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC par_peek_second_is_for

;; ============================================================================
;; pf_yield(Comp *c) -> node   -- `yield`, `yield x`, `yield from x`
;;
;; A yield is an expression, not a statement: `x = yield v` is how a generator
;; receives what send() passes back.
;; ============================================================================
PY_LINE  equ 8
PY_KIND  equ 16
PY_FIRST equ 24
PY_MARK  equ 32
PY_VLINE equ 40          ; where the yielded value begins, past the keyword
PY_FRAME equ 56          ; + 1 push = 64
global pf_yield
DEF_FUNC pf_yield, PY_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PY_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; `yield`

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_FROM
    je .from

    ; A bare `yield` ends wherever an expression would not start.
    mov qword [rbp - PY_KIND], AST_YIELD
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NEWLINE
    je .bare
    cmp eax, TOK_SEMI
    je .bare
    cmp eax, TOK_ENDMARKER
    je .bare
    cmp eax, TOK_RPAR
    je .bare
    cmp eax, TOK_RSQB
    je .bare
    cmp eax, TOK_RBRACE
    je .bare
    cmp eax, TOK_COMMA
    je .bare
    cmp eax, TOK_COLON
    je .bare
    cmp eax, TOK_DEDENT
    je .bare

    ; Where the value starts, for the tuple below: `yield a, b` puts the
    ; tuple at `a`, not at `yield`.
    mov rdi, rbx
    call par_peek
    TOK_POS rax
    mov [rbp - PY_VLINE], rcx
    mov rdi, rbx
    mov esi, BP_WALRUS
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PY_FIRST], rax

    ; `yield a, b` yields the tuple, the way a bare `a, b` builds one.
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    jne .one
    mov rdi, rbx
    call ast_mark
    mov [rbp - PY_MARK], rax
    mov rdi, rbx
    mov rsi, [rbp - PY_FIRST]
    call ast_push
.tuple_loop:
    mov rdi, rbx
    call par_advance                    ; the comma
    mov rdi, rbx
    call par_kind
    ; A trailing comma ends it: `yield 1,` is a one-tuple.
    cmp eax, TOK_NEWLINE
    je .tuple_done
    cmp eax, TOK_ENDMARKER
    je .tuple_done
    cmp eax, TOK_SEMI
    je .tuple_done
    cmp eax, TOK_RPAR
    je .tuple_done
    cmp eax, TOK_RSQB
    je .tuple_done
    cmp eax, TOK_RBRACE
    je .tuple_done
    cmp eax, TOK_DEDENT
    je .tuple_done
    mov rdi, rbx
    mov esi, BP_WALRUS
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
    mov rdx, [rbp - PY_VLINE]
    mov rcx, [rbp - PY_MARK]
    call par_finish_list
    test rax, rax
    jz .fail
    mov [rbp - PY_FIRST], rax
.one:
    mov r8, [rbp - PY_FIRST]
    jmp .build
.bare:
    xor r8d, r8d
    jmp .build

.from:
    mov rdi, rbx
    call par_advance
    mov qword [rbp - PY_KIND], AST_YIELDFROM
    mov rdi, rbx
    mov esi, BP_WALRUS
    call par_expr
    test rax, rax
    jz .fail
    mov r8, rax

.build:
    mov rdi, rbx
    mov rsi, [rbp - PY_KIND]
    xor edx, edx
    mov rcx, [rbp - PY_LINE]
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
END_FUNC pf_yield

;; ============================================================================
;; pf_await(Comp *c) -> node   -- `await x`
;;
;; The operand is a *primary*, not a unary expression: the grammar is
;; `await_primary: AWAIT primary`.  Recursing at BP_AWAIT gets that from the
;; table alone -- calls, subscripts and attributes (BP_POSTFIX) bind into the
;; operand, while `**` (BP_POWER, just below) does not, so `await f() ** 2` is
;; `(await f()) ** 2` and `await -x` is rejected.
;;
;; What the table does NOT get is `await await x`: the recursion re-enters the
;; PREFIX table, where AWAIT maps back to this function, so it parsed as
;; `await (await x)` where CPython refuses it.  The parenthesised form stays
;; legal, which is why the refusal is on the token and not on the node.
;; ============================================================================
PAW_LINE  equ 8
PAW_FRAME equ 24          ; + 1 push = 24
global pf_await
DEF_FUNC pf_await, PAW_FRAME
    push rbx
    mov rbx, rdi
    call par_peek
    TOK_POS rax
    mov [rbp - PAW_LINE], rcx
    mov rdi, rbx
    call par_advance                    ; `await`

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_AWAIT
    je .double
    mov rdi, rbx
    mov esi, BP_AWAIT
    call par_expr
    test rax, rax
    jz .fail
    mov r8, rax

    mov rdi, rbx
    mov esi, AST_AWAIT
    xor edx, edx
    mov rcx, [rbp - PAW_LINE]
    xor r9d, r9d
    call ast_make
    pop rbx
    leave
    ret
.double:
    mov rdi, rbx
    CSTRING rsi, "invalid syntax"
    call par_syntax_error
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC pf_await

;; ============================================================================
;; in_walrus(Comp *c, node left) -> node   -- `name := value`
;;
;; Only a plain name may be assigned to.  `(a.b := 1)` and `(a[0] := 1)` are
;; syntax errors in CPython too, which is why the check is here rather than in
;; the code generator: there is nothing sensible to emit for them.
;; ============================================================================
IW_LINE  equ 8
IW_LEFT  equ 16
IW_FRAME equ 24           ; + 1 push = 32
global in_walrus
DEF_FUNC in_walrus, IW_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - IW_LEFT], rsi
    call par_peek
    TOK_POS rax
    mov [rbp - IW_LINE], rcx

    mov rdi, rbx
    mov rsi, [rbp - IW_LEFT]
    call ast_at
    movzx ecx, byte [rax + AstNode.kind]
    cmp ecx, AST_NAME
    jne .bad_target
    mov byte [rax + AstNode.subkind], CTX_STORE

    mov rdi, rbx
    call par_advance                    ; `:=`
    mov rdi, rbx
    mov esi, BP_LAMBDA
    call par_expr
    test rax, rax
    jz .fail
    mov r9, rax
    mov rdi, rbx
    mov esi, AST_NAMEDEXPR
    xor edx, edx
    mov rcx, [rbp - IW_LINE]
    mov r8, [rbp - IW_LEFT]
    call ast_make
    pop rbx
    leave
    ret
.bad_target:
    mov rdi, rbx
    CSTRING rsi, "cannot use ':=' with that target"
    call par_syntax_error
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC in_walrus
extern prule_table

ASM_INIT

section .text

;; ============================================================================
;; par_forgot_comma(rdi = Comp*, rsi = the element just parsed)
;;   -> rax = 1 when it reported one, 0 when this is not that shape
;;
;; "invalid syntax. Perhaps you forgot a comma?", CPython's guess when one
;; expression in a bracketed list is followed straight by another.  The test
;; is whether the token that follows could START an expression, which is
;; exactly what prule_table's prefix column says.  The span runs from the
;; element to the end of that token, as CPython's does.
;; ============================================================================
PFC_COMP  equ 8
PFC_NODE  equ 16
PFC_LINE  equ 24
PFC_COL   equ 32
PFC_FRAME equ 40            ; + 1 push = 48, 16-aligned
global par_forgot_comma
DEF_FUNC par_forgot_comma, PFC_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - PFC_COMP], rdi
    mov [rbp - PFC_NODE], rsi

    call par_kind
    lea rcx, [rel prule_table]
    imul rax, rax, PRule_size
    cmp qword [rcx + rax + PRule.prefix], 0
    je .pfc_no

    mov rdi, rbx
    mov rsi, [rbp - PFC_NODE]
    call ast_at
    mov ecx, [rax + AstNode.lineno]
    mov [rbp - PFC_LINE], ecx
    mov ecx, [rax + AstNode.col]
    mov [rbp - PFC_COL], ecx

    mov rdi, rbx
    call par_peek
    mov r9d, [rax + Token.lineno]
    mov r10d, [rax + Token.col]
    add r10d, [rax + Token.len]
    mov ecx, [rbp - PFC_LINE]
    mov r8d, [rbp - PFC_COL]
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    CSTRING rdx, "invalid syntax. Perhaps you forgot a comma?"
    call comp_error_span
    mov eax, 1
    pop rbx
    leave
    ret
.pfc_no:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_forgot_comma

;; ============================================================================
;; par_last_pushed(rdi = Comp*) -> rax = the node most recently pushed onto the
;; pending stack, or 0 when it is empty
;;
;; The element a "forgot a comma" message should span from.  Reading it back
;; is what lets the three bracketed loops share the check without each one
;; keeping the node in a register across the push.
;; ============================================================================
global par_last_pushed
DEF_FUNC_BARE par_last_pushed
    mov rcx, [rdi + Comp.pending + Buf.len]
    test rcx, rcx
    jz .plp_none
    mov rax, [rdi + Comp.pending + Buf.data]
    mov eax, [rax + rcx*4 - 4]
    ret
.plp_none:
    xor eax, eax
    ret
END_FUNC par_last_pushed
