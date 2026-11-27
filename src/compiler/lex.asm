; lex.asm - Tokenizer for the Python source compiler
;
; One pass over the source produces the whole token array.  Materializing it up
; front rather than pulling tokens on demand is what makes the parser's
; backtracking cheap: restoring a parse position is `mov [comp+tok_idx], saved`
; instead of a snapshot of the indent stack, paren depth and pending dedents.
;
; Three tables in tables.asm carry the decisions:
;   cc_table  - 256 bytes of character-class flags; every scanning branch is a
;               load and a test against it.
;   kw_table  - keywords matched with one masked 8-byte compare, narrowed by
;               first byte through kw_index.
;   op_table  - operators sorted longest-first within each first byte, so the
;               first match found is already the maximal munch.
;
; Errors are recorded through comp_error and reported by returning 0.  Nothing
; here may call raise_exception: see the header of compiler.inc.

%include "macros.inc"
%include "object.inc"
%include "compiler.inc"

extern buf_reserve
extern comp_msg_start
extern comp_msg_utf8
extern comp_msg_ucode
extern comp_msg_hex2
extern uflags_of
extern comp_msg_cstr
extern comp_msg_i64
extern comp_error_span
extern comp_error

; uflag_starts bits, from src/compiler/gen_unicodecase.py.  Only the three an
; identifier's rule needs; src/methods/str_case.asm has the whole set.
UF_PRINTABLE  equ 256
UF_XID_CONT   equ 512
UF_XID_START  equ 1024

extern cc_table
extern kw_index
extern kw_masks
extern kw_table
extern op_index
extern op_masks
extern op_table

extern exc_IndentationError_type
extern exc_SyntaxError_type

; --- Named frame-layout constants ---
;
; Frame sizes are picked so (frame + 8 * register pushes) is a multiple of 16,
; leaving rsp 16-byte aligned at every call.  It matters here because the
; number scanner will hand token text to strtod, and libc's floating-point
; paths do use aligned SSE stores.
;
; The scan cursor stays in r12 throughout lex_run; everything that has to
; survive a call goes in a frame slot rather than a caller-saved register.
LR_COMP  equ 8
LR_CP    equ 16          ; a non-ASCII character: the code point in the low
                         ; half, how many bytes it took in the high half
LR_KIND  equ 24          ; its token kind
LR_FLAGS equ 32          ; its TF_* flags
LR_STRNL equ 40          ; lines a string literal spanned, not applied yet
LR_STRLS equ 48          ; where the last of those lines starts
LR_SKIP  equ 96          ; an FsSkip, at [rbp-96, rbp-56): the f-string
                         ; scanner's state, derived rather than hand-picked so
                         ; that growing the struct cannot land it on the slots
                         ; above it
LR_FRAME equ 104         ; + 5 pushes = 144
section .bss
;; Set around .sub_type_comment: was the `#` the first thing on its line?
lex_tc_own_line: resb 1

section .text

;; ============================================================================
;; lex_emit(Comp *c, int kind, const char *start, int64_t len, int flags)
;;   -> Token* (never NULL; ap_malloc is fatal on OOM)
;;
;; Appends one token, stamping the line and column from the lexer state.  The
;; column is computed in bytes from line_start, which is what a SyntaxError
;; caret wants; it is not a code-point count.
;; ============================================================================
LE_COMP  equ 8
LE_KIND  equ 16
LE_START equ 24
LE_LEN   equ 32
LE_FLAGS equ 40
LE_FRAME equ 40          ; + 1 push = 48
DEF_FUNC lex_emit, LE_FRAME
    push rbx
    mov [rbp - LE_COMP], rdi
    mov [rbp - LE_KIND], rsi
    mov [rbp - LE_START], rdx
    mov [rbp - LE_LEN], rcx
    mov [rbp - LE_FLAGS], r8
    mov rbx, rdi

    lea rdi, [rbx + Comp.tokens]
    mov esi, 1
    call buf_reserve                    ; rax = the new Token*

    mov rdx, [rbp - LE_KIND]
    mov [rax + Token.kind], dx
    mov rdx, [rbp - LE_FLAGS]
    mov [rax + Token.flags], dx
    mov rdx, [rbp - LE_START]
    mov [rax + Token.start], rdx
    mov rcx, [rbp - LE_LEN]
    mov [rax + Token.len], ecx
    mov qword [rax + Token.val], 0

    mov ecx, [rbx + Comp.lex + Lexer.lineno]
    mov [rax + Token.lineno], ecx
    sub rdx, [rbx + Comp.lex + Lexer.line_start]
    mov [rax + Token.col], edx

    pop rbx
    leave
    ret
END_FUNC lex_emit

;; ============================================================================
;; lex_keyword(const char *s, int64_t len) -> token kind, or TOK_NAME
;;
;; Every keyword is 2..8 bytes, so an identifier in that range is one unaligned
;; 8-byte load masked to its length and compared against a packed constant.
;; The read may cross the end of the identifier but never the end of the
;; buffer: comp.src carries a NUL-padded tail for exactly this.
;; ============================================================================
DEF_FUNC_BARE lex_keyword
    mov eax, TOK_NAME
    cmp rsi, 2
    jb .done
    cmp rsi, 8
    ja .done

    movzx ecx, byte [rdi]               ; first byte selects the bucket
    lea r8, [rel kw_index]
    movzx edx, byte [r8 + rcx*2 + 1]    ; count
    test edx, edx
    jz .done
    movzx r9d, byte [r8 + rcx*2]        ; first entry index

    mov r10, [rdi]                      ; the 8 bytes to match
    lea r8, [rel kw_masks]
    and r10, [r8 + rsi*8]               ; keep only the identifier's own bytes

    lea r8, [rel kw_table]
    shl r9, 4                           ; * KW_ENT_SIZE
    add r8, r9
.scan:
    cmp r10, [r8]
    jne .next
    cmp word [r8 + 10], si              ; the stored length must agree
    jne .next
    movzx eax, word [r8 + 8]
    ret
.next:
    add r8, 16
    dec edx
    jnz .scan
.done:
    ret
END_FUNC lex_keyword

;; ============================================================================
;; lex_operator(const char *s, const char *end) -> (rax = kind, rdx = length)
;;   rax = 0 (TOK_ENDMARKER) when nothing matches.
;;
;; op_table is sorted longest-first within each first byte, so the first hit is
;; the maximal munch.  The 4-byte load can read past `s`, which the NUL-padded
;; tail makes safe; the mask then discards whatever it picked up.
;; ============================================================================
DEF_FUNC_BARE lex_operator
    movzx ecx, byte [rdi]
    lea r8, [rel op_index]
    movzx r9d, byte [r8 + rcx*2 + 1]    ; count
    test r9d, r9d
    jz .none
    movzx r10d, byte [r8 + rcx*2]       ; first entry

    mov r11d, [rdi]                     ; up to 4 bytes at the cursor
    mov rcx, rsi
    sub rcx, rdi                        ; rcx = bytes remaining

    lea r8, [rel op_table]
    shl r10, 3                          ; * OP_ENT_SIZE
    add r8, r10
.scan:
    movzx edx, byte [r8 + 4]            ; candidate length
    cmp rdx, rcx
    ja .next                            ; would run past the end of the source
    mov eax, r11d
    lea r10, [rel op_masks]
    and eax, [r10 + rdx*4]
    cmp eax, [r8]
    jne .next
    movzx eax, byte [r8 + 5]            ; the token kind
    ret
.next:
    add r8, 8
    dec r9d
    jnz .scan
.none:
    xor eax, eax
    xor edx, edx
    ret
END_FUNC lex_operator

;; ============================================================================
;; lex_soft(const char *s, int64_t len) -> rax = TF_SOFT_* bit, or 0
;;
;; The soft keywords stay TOK_NAME -- `match` is an ordinary identifier almost
;; everywhere -- but carrying a flag lets the parser test a bit at each
;; statement boundary instead of doing a string compare.
;; ============================================================================
DEF_FUNC_BARE lex_soft
    xor eax, eax
    cmp rsi, 1
    je .one
    cmp rsi, 4
    je .four
    cmp rsi, 5
    je .five
    ret
.one:
    cmp byte [rdi], '_'
    jne .no
    mov eax, TF_SOFT_UNDER
    ret
.four:
    mov ecx, [rdi]
    cmp ecx, 'case'
    jne .four_type
    mov eax, TF_SOFT_CASE
    ret
.four_type:
    cmp ecx, 'type'
    jne .no
    mov eax, TF_SOFT_TYPE
    ret
.five:
    mov ecx, [rdi]
    cmp ecx, 'matc'
    jne .no
    cmp byte [rdi + 4], 'h'
    jne .no
    mov eax, TF_SOFT_MATCH
    ret
.no:
    xor eax, eax
    ret
END_FUNC lex_soft

;; ============================================================================
;; lex_str_prefix(const char *s, int64_t len) -> rax = TF_STR_* flags, or -1
;;
;; Called only when an identifier of one or two bytes sits directly against a
;; quote.  Returns -1 when the letters are not a legal prefix, so `rb'x'` is a
;; bytes literal while `xy'z'` stays a name followed by a string -- which is
;; what CPython does, and what makes `print'x'` a syntax error rather than a
;; mysterious literal.
;; ============================================================================
DEF_FUNC_BARE lex_str_prefix
    cmp rsi, 1
    je .one
    cmp rsi, 2
    je .two
    mov rax, -1
    ret

.one:
    movzx eax, byte [rdi]
    or eax, 0x20                        ; fold case
    cmp al, 'r'
    je .ret_raw
    cmp al, 'b'
    je .ret_bytes
    cmp al, 'f'
    je .ret_fmt
    cmp al, 'u'
    je .ret_none                        ; u'' is a plain str; the u means nothing
    mov rax, -1
    ret

.two:
    movzx eax, byte [rdi]
    or eax, 0x20
    movzx edx, byte [rdi + 1]
    or edx, 0x20
    ; Exactly four two-letter prefixes exist: br rb fr rf.  'u' never combines.
    cmp al, 'b'
    jne .two_not_b
    cmp dl, 'r'
    jne .bad
    mov eax, TF_STR_BYTES | TF_STR_RAW
    ret
.two_not_b:
    cmp al, 'f'
    jne .two_not_f
    cmp dl, 'r'
    jne .bad
    mov eax, TF_STR_FMT | TF_STR_RAW
    ret
.two_not_f:
    cmp al, 'r'
    jne .bad
    cmp dl, 'b'
    je .ret_rb
    cmp dl, 'f'
    je .ret_rf
.bad:
    mov rax, -1
    ret
.ret_rb:
    mov eax, TF_STR_RAW | TF_STR_BYTES
    ret
.ret_rf:
    mov eax, TF_STR_RAW | TF_STR_FMT
    ret
.ret_raw:
    mov eax, TF_STR_RAW
    ret
.ret_bytes:
    mov eax, TF_STR_BYTES
    ret
.ret_fmt:
    mov eax, TF_STR_FMT
    ret
.ret_none:
    xor eax, eax
    ret
END_FUNC lex_str_prefix

ASM_INIT


;; ============================================================================
;; lex_cp_at(rdi = a source pointer, rsi = one past the last source byte)
;;   -> eax = the code point there, edx = how many bytes it took;
;;      edx = 0 with eax = the offending BYTE when the sequence is not valid
;;      UTF-8
;;
;; A UTF-8 decoder over the raw source, for the one question cc_table cannot
;; answer: whether a non-ASCII character may start or continue an identifier.
;;
;; It VALIDATES, and that is not a nicety.  The first cut checked the length
;; and nothing else, and returned an unrecognised lead byte as its own code
;; point -- several of which (0xAA, 0xB5, 0xBA, 0xF8..0xFF) are XID_Start.
;; So `\xff = 1` compiled, and bound a name whose one code point was U+1C0000:
;; outside Unicode, and a str whose code-point count did not match its bytes,
;; which str_repr then wrote past.  Worse in the quiet direction: a Latin-1
;; source silently compiled to a DIFFERENT PROGRAM -- in `x = caf\xe9\ny = 2`
;; the 0xE9 claimed three bytes, swallowing the newline and the `y`, and two
;; statements became one.
;;
;; Refused: a lead byte that is not one (0x80..0xBF, 0xC0, 0xC1, 0xF5..0xFF),
;; a truncated sequence, a byte in a continuation slot that is not one, an
;; overlong encoding, a surrogate, and anything above U+10FFFF.
;; ============================================================================
DEF_FUNC_BARE lex_cp_at
    movzx eax, byte [rdi]
    mov edx, 1
    test al, 0x80
    jz .lca_done                    ; ASCII: the byte is the code point
    mov ecx, eax
    and ecx, 0xf8
    cmp ecx, 0xf0
    je .lca_four
    mov ecx, eax
    and ecx, 0xf0
    cmp ecx, 0xe0
    je .lca_three
    mov ecx, eax
    and ecx, 0xe0
    cmp ecx, 0xc0
    jne .lca_bad                    ; a continuation byte, or 0xF8 and up
    cmp al, 0xc2
    jb .lca_bad                     ; 0xC0/0xC1: overlong by construction
    lea rcx, [rdi + 2]
    cmp rcx, rsi
    ja .lca_bad                     ; truncated
    movzx ecx, byte [rdi + 1]
    mov r8d, ecx
    and r8d, 0xc0
    cmp r8d, 0x80
    jne .lca_bad
    and eax, 0x1f
    shl eax, 6
    and ecx, 0x3f
    or eax, ecx
    mov edx, 2
    ret
.lca_three:
    lea rcx, [rdi + 3]
    cmp rcx, rsi
    ja .lca_bad
    movzx ecx, byte [rdi + 1]
    mov r8d, ecx
    and r8d, 0xc0
    cmp r8d, 0x80
    jne .lca_bad
    movzx r9d, byte [rdi + 2]
    mov r8d, r9d
    and r8d, 0xc0
    cmp r8d, 0x80
    jne .lca_bad
    and eax, 0x0f
    shl eax, 12
    and ecx, 0x3f
    shl ecx, 6
    or eax, ecx
    and r9d, 0x3f
    or eax, r9d
    cmp eax, 0x800
    jb .lca_bad                     ; overlong
    mov ecx, eax
    and ecx, ~0x7ff
    cmp ecx, 0xd800
    je .lca_bad                     ; a surrogate is not a character
    mov edx, 3
    ret
.lca_four:
    cmp al, 0xf5
    jae .lca_bad                    ; past U+10FFFF by the lead byte alone
    lea rcx, [rdi + 4]
    cmp rcx, rsi
    ja .lca_bad
    movzx ecx, byte [rdi + 1]
    mov r8d, ecx
    and r8d, 0xc0
    cmp r8d, 0x80
    jne .lca_bad
    movzx r9d, byte [rdi + 2]
    mov r8d, r9d
    and r8d, 0xc0
    cmp r8d, 0x80
    jne .lca_bad
    movzx r10d, byte [rdi + 3]
    mov r8d, r10d
    and r8d, 0xc0
    cmp r8d, 0x80
    jne .lca_bad
    and eax, 0x07
    shl eax, 18
    and ecx, 0x3f
    shl ecx, 12
    or eax, ecx
    and r9d, 0x3f
    shl r9d, 6
    or eax, r9d
    and r10d, 0x3f
    or eax, r10d
    cmp eax, 0x10000
    jb .lca_bad                     ; overlong
    cmp eax, 0x110000
    jae .lca_bad
    mov edx, 4
    ret
.lca_bad:
    movzx eax, byte [rdi]           ; the byte itself, for the message
    xor edx, edx
.lca_done:
    ret
END_FUNC lex_cp_at

;; ============================================================================
;; lex_run(Comp *c, const char *start, const char *end, int lineno,
;;         const char *line_start)
;;   -> rax = 1 on success, 0 with comp.err recorded
;;
;; With start == 0 it tokenizes the whole of comp.src.  With a span it appends
;; that span's tokens to the same array, which is how an f-string's replacement
;; fields are parsed: the tokens go on the end, the parser's cursor is pointed
;; at them, and the ordinary expression parser does the rest.
;;
;; Registers held across the whole loop:
;;   rbx = Comp*        r12 = read cursor        r13 = end of source
;;   r14 = &comp.lex    r15 = start of the token being scanned
;;
;; The cursor lives in r12 rather than in memory; it is written back to
;; lex.cur only on the paths that report an error, which is the only place
;; anything else reads it.
;; ============================================================================
DEF_FUNC lex_run, LR_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi
    mov [rbp - LR_COMP], rdi
    lea r14, [rbx + Comp.lex]

    ; lex_run_range passes an explicit span; lex_run covers the whole source.
    test rsi, rsi
    jnz .have_span
    mov r12, [rbx + Comp.src]
    mov r13, r12
    add r13, [rbx + Comp.srclen]
    mov ecx, 1
    xor r8d, r8d
    jmp .set_state
.have_span:
    mov r12, rsi
    mov r13, rdx
    ; The line arrives in ecx, which is where the SysV ABI puts a fourth
    ; argument.  Reading it out of r8d gave every f-string field's tokens
    ; whatever happened to be there -- usually line 0, so an exception raised
    ; inside a replacement field pointed at the first line of the file.
.set_state:
    mov [r14 + Lexer.cur], r12
    mov [r14 + Lexer.end], r13
    ; Columns are measured from line_start.  A span that begins in the middle
    ; of a line -- an f-string's replacement field -- is handed where its line
    ; really began, so the columns it reports are the file's and not the
    ; span's.  Zero means the span is its own line.
    mov [r14 + Lexer.line_start], r12
    test r8, r8
    jz .no_base
    mov [r14 + Lexer.line_start], r8
.no_base:
    mov [r14 + Lexer.lineno], ecx
    mov dword [r14 + Lexer.paren_depth], 0
    mov dword [r14 + Lexer.indent_top], 0
    mov dword [r14 + Lexer.indents], 0
    ; A span is a fragment in the middle of a line -- an f-string's replacement
    ; field -- so it does not begin a logical line.  Starting it at one would
    ; read `f'{ x }'`'s leading space as an indent.
    mov dword [r14 + Lexer.atbol], 1
    test rsi, rsi
    jz .whole_file
    mov dword [r14 + Lexer.atbol], 0
    ; A replacement field is scanned as its own span, and PEP 701 lets a
    ; newline inside one be a continuation rather than the end of a statement.
    ; At depth 0 the newline emitted NEWLINE and the next line's leading space
    ; became an INDENT, in the middle of an expression.  Depth 1 is what makes
    ; .newline suppress the token and .top skip the indent measurement;
    ; .op_close already refuses to go below zero, so an unbalanced `)` inside
    ; the span cannot re-enable it.
    mov dword [r14 + Lexer.paren_depth], 1
.whole_file:

.top:
    cmp dword [r14 + Lexer.atbol], 0
    je .scan
    cmp dword [r14 + Lexer.paren_depth], 0
    jne .clear_bol                      ; inside brackets, indentation is not a thing

    ;; --- measure the indentation of a new logical line --------------------
    ; Columns follow CPython: a space advances one, a tab advances to the next
    ; multiple of LEX_TABSIZE, a formfeed resets to zero.
    xor r15d, r15d                      ; r15d = column
.ind_loop:
    cmp r12, r13
    jae .ind_done
    movzx eax, byte [r12]
    cmp al, ' '
    je .ind_space
    cmp al, 9
    je .ind_tab
    cmp al, 12
    je .ind_ff
    jmp .ind_done
.ind_space:
    inc r15d
    inc r12
    jmp .ind_loop
.ind_tab:
    mov eax, r15d
    xor edx, edx
    mov ecx, LEX_TABSIZE
    div ecx
    inc eax
    imul eax, ecx
    mov r15d, eax
    inc r12
    jmp .ind_loop
.ind_ff:
    xor r15d, r15d
    inc r12
    jmp .ind_loop
.ind_done:
    ; A line holding only a comment, or nothing at all, carries no indentation
    ; information and does not end a logical line: it produces no INDENT, no
    ; DEDENT and no NEWLINE, and leaves the lexer still at a line start.
    cmp r12, r13
    jae .eof                            ; the epilogue emits the pending dedents
    movzx eax, byte [r12]
    cmp al, '#'
    je .blank_line
    cmp al, 10
    je .blank_line
    cmp al, 13
    je .blank_line

    ; Compare against the top of the indent stack.
    mov ecx, [r14 + Lexer.indent_top]
    mov edx, [r14 + rcx*4 + Lexer.indents]
    cmp r15d, edx
    je .clear_bol
    ja .do_indent

.do_dedent:
    ; Pop while the new column is below the top of the stack, then require an
    ; exact match.  Landing between two levels is an IndentationError, not a
    ; silent realignment -- which is the whole reason the stack is kept.
    mov ecx, [r14 + Lexer.indent_top]
    mov edx, [r14 + rcx*4 + Lexer.indents]
    cmp r15d, edx
    je .clear_bol                       ; back to a level we know
    ja .dedent_bad                      ; between two levels
    test ecx, ecx
    jz .dedent_bad                      ; below column zero is not reachable
    dec ecx
    mov [r14 + Lexer.indent_top], ecx
    mov rdi, rbx
    mov esi, TOK_DEDENT
    mov rdx, r12
    xor ecx, ecx
    xor r8d, r8d
    call lex_emit
    jmp .do_dedent
.dedent_bad:
    mov rdi, rbx
    lea rsi, [rel exc_IndentationError_type]
    CSTRING rdx, "unindent does not match any outer indentation level"
    mov ecx, [r14 + Lexer.lineno]
    mov r8d, r15d
    call comp_error
    jmp .fail

.do_indent:
    mov ecx, [r14 + Lexer.indent_top]
    cmp ecx, LEX_MAX_INDENT - 1
    jae .indent_deep
    inc ecx
    mov [r14 + Lexer.indent_top], ecx
    mov [r14 + rcx*4 + Lexer.indents], r15d
    mov rdi, rbx
    mov esi, TOK_INDENT
    mov rdx, r12
    xor ecx, ecx
    xor r8d, r8d
    call lex_emit
    jmp .clear_bol
.indent_deep:
    mov rdi, rbx
    lea rsi, [rel exc_IndentationError_type]
    CSTRING rdx, "too many levels of indentation"
    mov ecx, [r14 + Lexer.lineno]
    xor r8d, r8d
    call comp_error
    jmp .fail

.blank_line:
    ; Consume a comment-only or empty line whole, advancing the line counter
    ; but leaving atbol set, so the next real line is still measured for
    ; indentation against the same stack.
    cmp r12, r13
    jae .eof
    cmp byte [r12], '#'
    jne .bl_at_eol
    ; A `# type:` comment on a line of its own is the form a function
    ; signature takes: `def f(a, b):` then `# type: (int, str) -> bool`.  The
    ; token is emitted BETWEEN the NEWLINE and the INDENT, which is where
    ; CPython's grammar looks for it, and the line still counts as blank so
    ; the indentation stack is untouched.
    mov byte [rel lex_tc_own_line], 1
    call .sub_type_comment
    test eax, eax
    jnz .bl_at_eol                      ; r12 is at the end of the line already
.bl_comment:
    inc r12
    cmp r12, r13
    jae .eof
    movzx eax, byte [r12]
    cmp al, 10
    je .bl_at_eol
    cmp al, 13
    je .bl_at_eol
    jmp .bl_comment
.bl_at_eol:
    cmp r12, r13
    jae .eof
    movzx eax, byte [r12]
    cmp al, 13
    jne .bl_lf
    inc r12
    cmp r12, r13
    jae .bl_advance
    cmp byte [r12], 10
    jne .bl_advance
.bl_lf:
    inc r12
.bl_advance:
    inc dword [r14 + Lexer.lineno]
    mov [r14 + Lexer.line_start], r12
    jmp .top

.clear_bol:
    mov dword [r14 + Lexer.atbol], 0

    ;; --- the token scanner -------------------------------------------------
.scan:
    cmp r12, r13
    jae .eof
    movzx eax, byte [r12]

    ; horizontal whitespace
    cmp al, ' '
    je .skip_one
    cmp al, 9
    je .skip_one
    cmp al, 12
    je .skip_one

    cmp al, '#'
    je .comment
    cmp al, 10
    je .newline
    cmp al, 13
    je .newline
    cmp al, 92                          ; backslash: explicit line continuation
    je .continuation

    lea rcx, [rel cc_table]
    movzx edx, byte [rcx + rax]
    test dl, CC_IDSTART
    jnz .ident
    test dl, CC_DIGIT
    jnz .number
    test dl, CC_QUOTE
    jnz .string_plain
    cmp al, '.'
    je .maybe_number
    test dl, CC_OPSTART
    jnz .operator
    jmp .bad_char

.skip_one:
    inc r12
    jmp .scan

.comment:
    ; Run to the end of the line, leaving the newline itself for .newline.
    ;
    ; A `# type: ...` comment is a token of its own when PyCF_TYPE_COMMENTS
    ; asked for one -- the only comment this lexer ever emits.  It is
    ; recognised here rather than in the parser because the parser never sees
    ; a comment at all: everything else about them is that they are skipped.
    mov byte [rel lex_tc_own_line], 0
    call .sub_type_comment
    test eax, eax
    jnz .scan                           ; r12 is at the end of the line already
    jmp .comment_loop

; .sub_type_comment - r12 points at a '#'.  Emit a TOK_TYPE_COMMENT or a
; TOK_TYPE_IGNORE for it if this is one and the flag asked for them, leaving
; r12 at the end of the line.  Falls through harmlessly otherwise.
.sub_type_comment:
    cmp dword [rbx + Comp.want_tc], 0
    je .tc_no
    mov rax, r12
    inc rax                             ; past the '#'
.tc_blanks:
    cmp rax, r13
    jae .tc_no
    cmp byte [rax], ' '
    jne .tc_have_word
    inc rax
    jmp .tc_blanks
.tc_have_word:
    lea rcx, [rax + 5]
    cmp rcx, r13
    ja .tc_no
    cmp dword [rax], 'type'
    jne .tc_no
    cmp byte [rax + 4], ':'
    jne .tc_no
    add rax, 5
.tc_skip_blanks:
    cmp rax, r13
    jae .tc_emit
    cmp byte [rax], ' '
    jne .tc_emit
    inc rax
    jmp .tc_skip_blanks
.tc_emit:
    ; "ignore" -- as a whole word -- makes this an ignore rather than a type,
    ; and CPython keeps the rest of the line as its tag.
    mov esi, TOK_TYPE_COMMENT
    lea rcx, [rax + 6]
    cmp rcx, r13
    ja .tc_have_kind
    cmp dword [rax], 'igno'
    jne .tc_have_kind
    cmp word [rax + 4], 're'
    jne .tc_have_kind
    ; The word has to end there: `# type: ignoreme` is an ordinary comment.
    cmp rcx, r13
    jae .tc_is_ignore
    push rax
    lea rax, [rel cc_table]
    movzx edx, byte [rcx]
    test byte [rax + rdx], CC_IDCONT
    pop rax
    jnz .tc_have_kind
.tc_is_ignore:
    mov esi, TOK_TYPE_IGNORE
    mov rax, rcx                        ; the tag is what follows the word
.tc_have_kind:
    ; rax is the first byte of the text.  Find the end of the line for its
    ; length, then leave r12 there so the newline is still the parser's.
    push rsi
    mov rcx, rax
.tc_end:
    cmp rcx, r13
    jae .tc_have_end
    movzx edx, byte [rcx]
    cmp dl, 10
    je .tc_have_end
    cmp dl, 13
    je .tc_have_end
    inc rcx
    jmp .tc_end
.tc_have_end:
    ; A `# type: ignore` on a line of ITS OWN carries the line terminator in
    ; its tag; one after a statement does not, and a `# type: <sig>` comment
    ; never does whichever line it is on.  CPython's tokenizer gets that from
    ; which terminator follows -- an NL it has already absorbed, against a
    ; NEWLINE token of its own -- and `ast.parse` reports the difference in
    ; TypeIgnore.tag.
    cmp qword [rsp], TOK_TYPE_IGNORE    ; the kind, pushed above
    jne .tc_no_eol
    cmp byte [rel lex_tc_own_line], 0
    je .tc_no_eol
    cmp rcx, r13
    jae .tc_no_eol
    movzx edx, byte [rcx]
    cmp dl, 10
    jne .tc_no_eol
    inc rcx                             ; the newline belongs to the tag
    push rcx
    push rax
    mov rdi, rbx
    mov rsi, [rsp + 16]
    mov rdx, rax
    sub rcx, rax
    xor r8d, r8d
    call lex_emit
    pop rax
    pop rcx
    add rsp, 8
    dec rcx                             ; but not to the scan: .newline wants it
    mov r12, rcx
    mov eax, 1
    ret
.tc_no_eol:
    push rcx
    push rax
    mov rdi, rbx
    mov rsi, [rsp + 16]                 ; the kind chosen above
    mov rdx, rax
    sub rcx, rax
    xor r8d, r8d
    call lex_emit
    pop rax
    pop rcx
    add rsp, 8                          ; the kind
    mov r12, rcx
    mov eax, 1
    ret
.tc_no:
    xor eax, eax
    ret

.comment_loop:
    cmp r12, r13
    jae .scan
    movzx eax, byte [r12]
    cmp al, 10
    je .scan
    cmp al, 13
    je .scan
    inc r12
    jmp .comment_loop

.continuation:
    ; A backslash joins this line to the next.  It must be the last thing on
    ; the line; anything else is an error.
    inc r12
    cmp r12, r13
    jae .cont_bad
    movzx eax, byte [r12]
    cmp al, 13
    jne .cont_nl
    inc r12
    cmp r12, r13
    jae .cont_advance
    cmp byte [r12], 10
    jne .cont_advance
.cont_nl:
    cmp byte [r12], 10
    jne .cont_bad
    inc r12
.cont_advance:
    inc dword [r14 + Lexer.lineno]
    mov [r14 + Lexer.line_start], r12
    jmp .scan
.cont_bad:
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    CSTRING rdx, "unexpected character after line continuation character"
    mov ecx, [r14 + Lexer.lineno]
    xor r8d, r8d
    call comp_error
    jmp .fail

.newline:
    mov r15, r12                        ; remember where the newline started
    cmp al, 13
    jne .nl_lf
    inc r12
    cmp r12, r13
    jae .nl_done
    cmp byte [r12], 10
    jne .nl_done
.nl_lf:
    inc r12
.nl_done:
    ; Inside brackets a newline is implicit continuation: no token, but the
    ; line counter still has to move or every later diagnostic is wrong.
    cmp dword [r14 + Lexer.paren_depth], 0
    jne .nl_no_token
    mov rdi, rbx
    mov esi, TOK_NEWLINE
    mov rdx, r15
    mov ecx, 1
    xor r8d, r8d
    call lex_emit
    mov dword [r14 + Lexer.atbol], 1
.nl_no_token:
    inc dword [r14 + Lexer.lineno]
    mov [r14 + Lexer.line_start], r12
    jmp .top

.maybe_number:
    ; '.' begins a number only when a digit follows; otherwise it is the
    ; attribute operator, and '...' is handled by the operator table.
    lea rax, [r12 + 1]
    cmp rax, r13
    jae .operator
    movzx edx, byte [rax]
    lea rcx, [rel cc_table]
    test byte [rcx + rdx], CC_DIGIT
    jz .operator
    jmp .number

.bad_char:
    mov r8, r12
    sub r8, [r14 + Lexer.line_start]        ; column, before rdx is claimed
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    mov ecx, [r14 + Lexer.lineno]
    CSTRING rdx, "invalid character in source"
    call comp_error
    jmp .fail

;; --- identifiers, keywords, and prefixed string literals -------------------
;;
;; cc_table marks every byte over 0x7F as an identifier start and continue,
;; which is a permissive UTF-8 lead and nothing more -- so an invisible NBSP
;; or ZWSP, or a lone combining mark, compiled as a NAME.  CPython's rule is
;; XID_Start XID_Continue*, the tables for it are generated already
;; (uflag_starts, via uflags_of), and the bytes below 0x80 keep the one-load
;; fast path they had.
.ident:
    mov r15, r12                        ; r15 = start of the identifier
    movzx eax, byte [r12]
    test al, 0x80
    jz .ident_first_ascii
    mov rdi, r12
    mov rsi, r13
    call lex_cp_at
    test edx, edx
    jz .ident_bad_utf8
    shl rdx, 32
    or rax, rdx
    mov [rbp - LR_CP], rax
    mov edi, eax
    call uflags_of
    test eax, UF_XID_START
    jz .ident_bad_char
    mov rdx, [rbp - LR_CP]
    shr rdx, 32
    add r12, rdx
    lea rcx, [rel cc_table]
    jmp .ident_loop
.ident_first_ascii:
    inc r12
    lea rcx, [rel cc_table]
.ident_loop:
    cmp r12, r13
    jae .ident_done
    movzx eax, byte [r12]
    test al, 0x80
    jnz .ident_cont_wide
    test byte [rcx + rax], CC_IDCONT
    jz .ident_done
    inc r12
    jmp .ident_loop
.ident_cont_wide:
    mov rdi, r12
    mov rsi, r13
    call lex_cp_at
    test edx, edx
    jz .ident_bad_utf8
    shl rdx, 32
    or rax, rdx
    mov [rbp - LR_CP], rax
    mov edi, eax
    call uflags_of
    test eax, UF_XID_CONT
    jz .ident_wide_ends
    mov rdx, [rbp - LR_CP]
    shr rdx, 32
    add r12, rdx
    lea rcx, [rel cc_table]
    jmp .ident_loop
.ident_wide_ends:
    ; Not a continuation: the identifier stops here, and the character is
    ; whatever the next dispatch makes of it -- which, for one that cannot
    ; start an identifier either, is .ident_bad_char on the next pass.
    lea rcx, [rel cc_table]
.ident_done:
    ; An identifier butted straight against a quote is a string prefix, not a
    ; name: rb"..", f'..'.  Only 1- and 2-character prefixes exist, so anything
    ; longer is unambiguously an identifier.
    cmp r12, r13
    jae .ident_word
    movzx eax, byte [r12]
    lea rcx, [rel cc_table]
    test byte [rcx + rax], CC_QUOTE
    jz .ident_word
    mov rsi, r12
    sub rsi, r15                        ; rsi = length of the candidate prefix
    cmp rsi, 2
    ja .ident_word
    mov rdi, r15
    call lex_str_prefix                 ; -> rax = TF_STR_* flags, or -1
    cmp rax, -1
    je .ident_word
    mov [rbp - LR_FLAGS], rax
    jmp .string_scan

.ident_word:
    mov rdi, r15
    mov rsi, r12
    sub rsi, r15
    call lex_keyword                    ; rax = keyword kind, or TOK_NAME
    mov [rbp - LR_KIND], rax
    mov qword [rbp - LR_FLAGS], 0
    cmp rax, TOK_NAME
    jne .ident_emit
    ; Soft keywords stay TOK_NAME but carry a flag, so the parser tests a bit
    ; rather than doing a string compare at every statement boundary.
    mov rdi, r15
    mov rsi, r12
    sub rsi, r15
    call lex_soft
    mov [rbp - LR_FLAGS], rax
.ident_emit:
    mov rdi, rbx
    mov rsi, [rbp - LR_KIND]
    mov rdx, r15
    mov rcx, r12
    sub rcx, r15
    mov r8, [rbp - LR_FLAGS]
    call lex_emit
    jmp .scan

.ident_bad_utf8:
    ; Not valid UTF-8 at all: eax is the offending byte.  CPython refuses the
    ; whole file for this, as a codec error with a position of its own --
    ; "(unicode error) 'utf-8' codec can't decode byte 0xe9 in position 3" --
    ; and ROADMAP.md records the wording difference.  What matters is that the
    ; byte is refused rather than becoming part of a name: a Latin-1 source
    ; used to compile to a different program.
    mov [rbp - LR_CP], rax
    call comp_msg_start
    mov [rbp - LR_FLAGS], rax
    mov rdi, rax
    CSTRING rsi, "invalid non-UTF-8 byte 0x"
    call comp_msg_cstr
    mov rdi, rax
    mov esi, [rbp - LR_CP]
    call comp_msg_hex2
    jmp .ibc_raise

.ident_bad_char:
    ; eax = the character's flags, [rbp - LR_CP] its code point.  CPython
    ; names the character when it is PRINTABLE and gives only the code point
    ; when it is not -- an NBSP or a ZWSP would otherwise be reported with
    ; nothing to see.  r12 still points at it, and the span, like the other
    ; per-character ones here, ends where it begins.
    mov [rbp - LR_KIND], rax            ; the flags, across comp_msg_start
    call comp_msg_start
    mov [rbp - LR_FLAGS], rax           ; the message
    mov rdi, rax
    test dword [rbp - LR_KIND], UF_PRINTABLE
    jz .ibc_nonprint
    CSTRING rsi, "invalid character '"
    call comp_msg_cstr
    mov rdi, rax
    mov esi, [rbp - LR_CP]
    call comp_msg_utf8
    mov rdi, rax
    CSTRING rsi, "' ("
    call comp_msg_cstr
    mov rdi, rax
    mov esi, [rbp - LR_CP]
    call comp_msg_ucode
    mov rdi, rax
    CSTRING rsi, ")"
    call comp_msg_cstr
    jmp .ibc_raise
.ibc_nonprint:
    CSTRING rsi, "invalid non-printable character "
    call comp_msg_cstr
    mov rdi, rax
    mov esi, [rbp - LR_CP]
    call comp_msg_ucode
.ibc_raise:
    mov rdx, [rbp - LR_FLAGS]
    mov r8, r12
    sub r8, [r14 + Lexer.line_start]
    mov ecx, [r14 + Lexer.lineno]
    mov r9d, ecx
    mov r10d, r8d
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    call comp_error_span
    jmp .fail

;; --- numeric literals ------------------------------------------------------
; The extent is scanned here; the value is built later from the token text, so
; that a literal in a construct that fails to parse never allocates.
.number:
    mov r15, r12
    mov qword [rbp - LR_FLAGS], 0
    cmp byte [r12], '.'
    je .num_fraction

    cmp byte [r12], '0'
    jne .num_decimal
    lea rax, [r12 + 1]
    cmp rax, r13
    jae .num_decimal
    movzx eax, byte [r12 + 1]
    or eax, 0x20                        ; fold case
    cmp al, 'x'
    je .num_radix
    cmp al, 'o'
    je .num_radix
    cmp al, 'b'
    je .num_radix
    jmp .num_decimal

.num_radix:
    ; Scan permissively over hex digits and underscores; whether the digits
    ; actually suit the radix is the converter's problem, and it gives a better
    ; message than the lexer could.
    add r12, 2
    lea rcx, [rel cc_table]
.num_radix_loop:
    cmp r12, r13
    jae .num_done
    movzx eax, byte [r12]
    cmp al, '_'
    je .num_radix_next
    test byte [rcx + rax], CC_HEX
    jz .num_done
.num_radix_next:
    inc r12
    jmp .num_radix_loop

.num_decimal:
    call .sub_digits
    cmp r12, r13
    jae .num_done
    cmp byte [r12], '.'
    jne .num_exponent
.num_fraction:
    or qword [rbp - LR_FLAGS], TF_NUM_FLOAT
    inc r12
    call .sub_digits
.num_exponent:
    cmp r12, r13
    jae .num_imag
    movzx eax, byte [r12]
    or eax, 0x20
    cmp al, 'e'
    jne .num_imag
    ; Only an exponent if a digit follows, optionally signed -- otherwise the
    ; 'e' begins an identifier, as in `1if x else 2` or `0e` as a name.
    lea rax, [r12 + 1]
    cmp rax, r13
    jae .num_imag
    movzx edx, byte [rax]
    cmp dl, '+'
    je .num_exp_signed
    cmp dl, '-'
    je .num_exp_signed
    jmp .num_exp_check
.num_exp_signed:
    inc rax
    cmp rax, r13
    jae .num_imag
    movzx edx, byte [rax]
.num_exp_check:
    lea rcx, [rel cc_table]
    test byte [rcx + rdx], CC_DIGIT
    jz .num_imag
    or qword [rbp - LR_FLAGS], TF_NUM_FLOAT
    mov r12, rax
    call .sub_digits

.num_imag:
    cmp r12, r13
    jae .num_done
    movzx eax, byte [r12]
    or eax, 0x20
    cmp al, 'j'
    jne .num_done
    or qword [rbp - LR_FLAGS], TF_NUM_IMAG
    inc r12

.num_done:
    call .sub_num_check
    test eax, eax
    jz .fail
    mov rdi, rbx
    mov esi, TOK_NUMBER
    mov rdx, r15
    mov rcx, r12
    sub rcx, r15
    mov r8, [rbp - LR_FLAGS]
    call lex_emit
    jmp .scan

; .sub_num_check - is the number that was just scanned actually one?
;   r15 = its first byte, r12 = one past its last, r13 = end of input.
;   -> eax = 1 when it is, or 0 with the error recorded.  r12 may come back
;      SHORTER: the scan takes hex digits whatever the radix, so `0b1and 2`
;      arrives as `0b1a` and the literal really ends at the `a`.
;
; The scan is permissive on purpose -- it takes hex digits for every radix and
; underscores anywhere -- so the four things CPython refuses are decided here,
; where the whole token is in hand.  Each carries CPython's own wording and
; its own column, which is the offending CHARACTER for three of them and the
; start of the literal for the fourth.
.sub_num_check:
    push rbx
    push r14
    push r15
    push r13                    ; r12 is an in/out now; r13 keeps the count
    sub rsp, 8

    ; A radix literal's digits have to suit its radix.  The scan takes hex
    ; digits whatever the prefix, so `0b2` and `0o9` arrive here whole -- and
    ; with nothing after them, which is why this comes before the check for a
    ; trailing character.
    cmp byte [r15], '0'
    jne .snc_not_radix_digits
    lea rax, [r15 + 2]
    cmp rax, r12
    ja .snc_not_radix_digits
    movzx eax, byte [r15 + 1]
    or eax, 0x20
    mov qword [rsp], 2
    cmp al, 'b'
    je .snc_scan_digits
    mov qword [rsp], 8
    cmp al, 'o'
    je .snc_scan_digits
    jmp .snc_not_radix_digits   ; hex takes every digit the scan took
.snc_scan_digits:
    lea rcx, [r15 + 2]
.snc_digit_loop:
    cmp rcx, r12
    jae .snc_not_radix_digits
    movzx eax, byte [rcx]
    cmp al, '_'
    je .snc_digit_next
    sub eax, '0'
    cmp eax, 10
    jae .snc_radix_ends         ; a letter: the literal stopped before it
    cmp rax, [rsp]
    jb .snc_digit_next
    ; A DIGIT out of range for the base.  CPython names it -- "invalid digit
    ; '2' in binary literal" -- and keeps "invalid binary literal" for a
    ; letter, which is not a digit of any base and so ends the literal.
    mov r15, rcx
    cmp qword [rsp], 2
    je .snc_binary
    jmp .snc_octal

.snc_radix_ends:
    ; The scan takes hex digits whatever the prefix, so `0b1and` came in as
    ; `0b1a`; the literal is `0b1` and the rest is the tail, which the checks
    ; below judge -- including the keyword lookahead that makes `0b1and 2`
    ; the number 1 and the operator, as CPython has it.
    mov r12, rcx
.snc_digit_next:
    inc rcx
    jmp .snc_digit_loop
.snc_not_radix_digits:

    ; A radix prefix with no digits behind it: `0x`, `0b_`, `0o1_`.  CPython
    ; names the base -- "invalid hexadecimal literal" -- and this let the
    ; token through for the parser to call an "invalid numeric literal",
    ; which names neither the base nor the reason.
    cmp byte [r15], '0'
    jne .snc_not_empty_radix
    lea rax, [r15 + 1]
    cmp rax, r12
    jae .snc_not_empty_radix
    movzx eax, byte [r15 + 1]
    or eax, 0x20
    cmp al, 'b'
    je .snc_radix_digits_needed
    cmp al, 'o'
    je .snc_radix_digits_needed
    cmp al, 'x'
    jne .snc_not_empty_radix
.snc_radix_digits_needed:
    ; The last character has to be a digit; an underscore may separate them
    ; but may not end them, and there has to be at least one.
    lea rax, [r15 + 2]
    cmp rax, r12
    jae .snc_empty_radix        ; the prefix and nothing else
    cmp byte [r12 - 1], '_'
    jne .snc_not_empty_radix
.snc_empty_radix:
    movzx eax, byte [r15 + 1]
    or eax, 0x20
    cmp al, 'b'
    je .snc_bad_binary
    cmp al, 'o'
    je .snc_bad_octal
    jmp .snc_bad_hex

.snc_not_empty_radix:
    ; A trailing underscore: `1_` is not a number.  It is the last byte of the
    ; token, and it is what CPython blames.
    cmp byte [r12 - 1], '_'
    jne .snc_underscores
    lea r15, [r12 - 1]
    CSTRING rax, "invalid decimal literal"
    jmp .snc_at_r15

.snc_underscores:

    ; An underscore has to SEPARATE digits: `1__2` and `12__` are not numbers,
    ; and CPython points at the underscore that is not followed by one.  The
    ; scan takes underscores anywhere, so this is where they are judged; the
    ; parser used to see the token, fail to convert it, and call it an
    ; "invalid numeric literal", which names neither the reason nor the base.
    ;
    ; The radix cases are already gone -- the check above wants the last
    ; character to be a digit -- so what is left is decimal, and hex, whose
    ; digits are the ones the permissive scan takes anyway.
    mov rcx, r15
.snc_us_loop:
    cmp rcx, r12
    jae .snc_no_trailing
    cmp byte [rcx], '_'
    jne .snc_us_next
    lea rax, [rcx + 1]
    cmp rax, r12
    jae .snc_us_bad             ; nothing after it at all
    movzx eax, byte [rax]
    lea rdx, [rel cc_table]
    test byte [rdx + rax], CC_DIGIT
    jnz .snc_us_next
    ; A hex literal's digits include a-f, which CC_DIGIT does not.
    cmp byte [r15], '0'
    jne .snc_us_bad
    lea rdx, [r15 + 1]
    cmp rdx, r12
    jae .snc_us_bad
    movzx edx, byte [r15 + 1]
    or edx, 0x20
    cmp dl, 'x'
    jne .snc_us_bad
    or eax, 0x20
    cmp al, 'a'
    jb .snc_us_bad
    cmp al, 'f'
    jbe .snc_us_next
.snc_us_bad:
    ; The column is the underscore, and the wording names the base: `0b1__0`
    ; is an invalid BINARY literal, not a decimal one.
    mov rax, r15
    mov r15, rcx
    cmp byte [rax], '0'
    jne .snc_us_decimal
    lea rdx, [rax + 1]
    cmp rdx, r12
    jae .snc_us_decimal
    movzx edx, byte [rax + 1]
    or edx, 0x20
    cmp dl, 'b'
    je .snc_bad_binary
    cmp dl, 'o'
    je .snc_bad_octal
    cmp dl, 'x'
    je .snc_bad_hex
.snc_us_decimal:
    CSTRING rax, "invalid decimal literal"
    jmp .snc_at_r15
.snc_us_next:
    inc rcx
    jmp .snc_us_loop

.snc_no_trailing:
    ; An identifier character straight after the literal.  `1e` is the shape
    ; that reaches here as a bare `1` followed by a name, and CPython blames
    ; the literal rather than the letter; every other trailing character is
    ; blamed where it stands.
    cmp r12, r13
    jae .snc_leading_zero
    lea rcx, [rel cc_table]
    movzx eax, byte [r12]
    test byte [rcx + rax], CC_IDCONT
    jz .snc_leading_zero

    ; ...unless what follows is one of the keywords that can come after an
    ; expression.  `1if True else 2` is 1 in CPython, and so are `1and 2`,
    ; `[1for i in x]` and `0x1if True else 2`; its tokenizer ends the number
    ; at the letter and warns rather than refusing.  This refused all of them
    ; -- and they turn up in real code, because a formatter that strips
    ; spaces produces them.
    ;
    ; The warning is recorded rather than emitted: the compiler runs before
    ; there is an interpreter frame, which is the same reason it may not
    ; raise.  comp_emit_warnings hands the lot to warn_explicit at the end.
    movzx eax, byte [r12]
    cmp al, 'i'
    jne .snc_kw_table
    ; if, in and is: CPython looks at the pair and no further, so `1ifx` is
    ; the number 1 and the name `ifx`, and the error comes from the parser.
    lea rcx, [r12 + 1]
    cmp rcx, r13
    jae .snc_kw_no
    movzx eax, byte [rcx]
    cmp al, 'f'
    je .snc_kw_warn
    cmp al, 'n'
    je .snc_kw_warn
    cmp al, 's'
    je .snc_kw_warn
    jmp .snc_kw_no

.snc_kw_table:
    ; The rest have to match whole, and not be the start of a longer name:
    ; `1andx` is an error where `1and x` is not.
    lea rsi, [rel snc_num_keywords]
.snc_kw_loop:
    mov rdi, [rsi]
    test rdi, rdi
    jz .snc_kw_no
    add rsi, 8
    xor edx, edx
.snc_kw_char:
    movzx eax, byte [rdi + rdx]
    test al, al
    jz .snc_kw_end
    lea rcx, [r12 + rdx]
    cmp rcx, r13
    jae .snc_kw_loop
    cmp al, [rcx]
    jne .snc_kw_loop
    inc rdx
    jmp .snc_kw_char
.snc_kw_end:
    lea rcx, [r12 + rdx]
    cmp rcx, r13
    jae .snc_kw_warn            ; the source ends with it
    lea rax, [rel cc_table]
    movzx edx, byte [rcx]
    test byte [rax + rdx], CC_IDCONT
    jz .snc_kw_warn
    jmp .snc_kw_loop

.snc_kw_warn:
    ; CPython's tokenizer ends the number at the letter and WARNS, with the
    ; same wording the error would have carried: "invalid decimal literal"
    ; for `1if True else 2` and "invalid hexadecimal literal" for `0x1if`.
    push r12
    push r13
    CSTRING rax, "invalid decimal literal"
    cmp byte [r15], '0'
    jne .snc_kww_have
    lea rcx, [r15 + 1]
    cmp rcx, r12
    jae .snc_kww_have
    movzx ecx, byte [r15 + 1]
    or ecx, 0x20
    cmp cl, 'b'
    je .snc_kww_bin
    cmp cl, 'o'
    je .snc_kww_oct
    cmp cl, 'x'
    je .snc_kww_hex
    jmp .snc_kww_have
.snc_kww_bin:
    CSTRING rax, "invalid binary literal"
    jmp .snc_kww_have
.snc_kww_oct:
    CSTRING rax, "invalid octal literal"
    jmp .snc_kww_have
.snc_kww_hex:
    CSTRING rax, "invalid hexadecimal literal"
.snc_kww_have:
    mov rdi, rbx
    mov rsi, rax
    mov edx, [r14 + Lexer.lineno]
    extern comp_warn
    call comp_warn
    pop r13
    pop r12
    jmp .snc_leading_zero

.snc_kw_no:

    ; Which literal was it?  A radix prefix names its base, and blames the
    ; literal rather than the character: CPython's "invalid hexadecimal
    ; literal" for `0x1z`, against "invalid digit '2' in binary literal" for
    ; a digit that is a digit but not one of that base's.
    cmp byte [r15], '0'
    jne .snc_not_radix
    lea rax, [r15 + 1]
    cmp rax, r12
    jae .snc_not_radix
    movzx eax, byte [r15 + 1]
    or eax, 0x20
    cmp al, 'b'
    je .snc_bad_binary
    cmp al, 'o'
    je .snc_bad_octal
    cmp al, 'x'
    je .snc_bad_hex
.snc_not_radix:
    test qword [rbp - LR_FLAGS], TF_NUM_IMAG
    jz .snc_decimal_junk
    ; `1j2`: the literal ended at the `j`, and that is where CPython points.
    lea r15, [r12 - 1]
    CSTRING rax, "invalid imaginary literal"
    jmp .snc_at_r15
.snc_decimal_junk:
    ; `1e`, `1if`, `2and`: CPython spans the literal itself, from its start.
    CSTRING rax, "invalid decimal literal"
    jmp .snc_at_r15

.snc_bad_binary:
    CSTRING rax, "invalid binary literal"
    jmp .snc_at_r15
.snc_bad_octal:
    CSTRING rax, "invalid octal literal"
    jmp .snc_at_r15
.snc_bad_hex:
    CSTRING rax, "invalid hexadecimal literal"
    jmp .snc_at_r15

.snc_binary:
    CSTRING rax, "binary"
    jmp .snc_radix_msg
.snc_octal:
    CSTRING rax, "octal"
    jmp .snc_radix_msg
.snc_hex:
    CSTRING rax, "hexadecimal"
.snc_radix_msg:
    ; "invalid digit '2' in binary literal", at the character that is wrong.
    push rax
    call comp_msg_start
    push rax
    mov rdi, rax
    CSTRING rsi, "invalid digit '"
    call comp_msg_cstr
    movzx ecx, byte [r15]
    mov [rax], cl
    mov byte [rax + 1], 0
    lea rdi, [rax + 1]
    CSTRING rsi, "' in "
    call comp_msg_cstr
    mov rdi, rax
    mov rsi, [rsp + 8]
    call comp_msg_cstr
    mov rdi, rax
    CSTRING rsi, " literal"
    call comp_msg_cstr
    pop rax                     ; the buffer
    add rsp, 8                  ; the base's name
    jmp .snc_at_r15

.snc_leading_zero:
    ; `08`: a decimal integer may not have a leading zero, and CPython spans
    ; the whole literal rather than one character of it.
    test qword [rbp - LR_FLAGS], TF_NUM_FLOAT | TF_NUM_IMAG
    jnz .snc_ok
    cmp byte [r15], '0'
    jne .snc_ok
    lea rax, [r15 + 1]
    cmp rax, r12
    jae .snc_ok                 ; a lone 0
    ; 0x/0o/0b are radix prefixes, and 00000 is still zero.
    movzx ecx, byte [r15 + 1]
    or ecx, 0x20
    cmp cl, 'b'
    je .snc_ok
    cmp cl, 'o'
    je .snc_ok
    cmp cl, 'x'
    je .snc_ok
    mov rcx, r15
.snc_zero_loop:
    cmp rcx, r12
    jae .snc_ok                 ; every digit was a zero
    movzx eax, byte [rcx]
    cmp al, '0'
    jne .snc_leading_bad
    inc rcx
    jmp .snc_zero_loop
.snc_leading_bad:
    cmp al, '_'
    je .snc_ok
    CSTRING rax, \
        "leading zeros in decimal integer literals are not permitted; use an 0o prefix for octal integers"
    ; The span runs from the literal's start to its end, unlike the three
    ; above, whose end is where they begin.
    mov rdx, rax
    mov r8, r15
    sub r8, [r14 + Lexer.line_start]
    mov ecx, [r14 + Lexer.lineno]
    mov r9d, ecx
    mov r10, r12
    sub r10, [r14 + Lexer.line_start]
    dec r10d
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    call comp_error_span
    jmp .snc_fail

.snc_at_r15:
    ; rax = the message, r15 = the character it is about.  CPython's span for
    ; all three of these ends where it begins.
    mov rdx, rax
    mov r8, r15
    sub r8, [r14 + Lexer.line_start]
    mov ecx, [r14 + Lexer.lineno]
    mov r9d, ecx
    mov r10d, r8d
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    call comp_error_span
.snc_fail:
    xor eax, eax
    jmp .snc_ret
.snc_ok:
    mov eax, 1
.snc_ret:
    add rsp, 8
    pop r13
    pop r15
    pop r14
    pop rbx
    ret

;; --- string literals -------------------------------------------------------
.string_plain:
    mov r15, r12                        ; no prefix; the literal starts here
    mov qword [rbp - LR_FLAGS], 0
.string_scan:
    ; r15 is the start of the whole token (prefix included), r12 points at the
    ; opening quote, and LR_FLAGS holds the prefix bits.
    ;
    ; A triple-quoted literal spans lines, but the token belongs to the line it
    ; STARTED on: lex_emit stamps Token.lineno from the counter and computes
    ; Token.col as start - line_start, which goes NEGATIVE once line_start has
    ; moved past the token.  As a u32 that is about 4.29e9, and the traceback's
    ; caret pads to it one space at a time.  So .sub_string counts the lines
    ; here and they are applied below, after the token is stamped.
    mov qword [rbp - LR_STRNL], 0
    call .sub_string                    ; advances r12 past the closing quote
    test eax, eax
    jnz .string_ok
    mov r8, r15
    sub r8, [r14 + Lexer.line_start]    ; the column, before rdx is claimed
    push r8
    ; CPython names the line the scan gave up on, which for a triple-quoted
    ; literal is not the line the token started on, and ends the span where it
    ; begins rather than one character later.
    call comp_msg_start
    push rax                    ; the buffer, which is the message
    mov rdi, rax
    CSTRING rsi, "unterminated string literal (detected at line "
    call comp_msg_cstr
    mov rdi, rax
    mov esi, [r14 + Lexer.lineno]
    mov rax, [rbp - LR_STRNL]
    add rsi, rax
    call comp_msg_i64
    mov rdi, rax
    CSTRING rsi, ")"
    call comp_msg_cstr
    pop rdx                     ; the message
    pop r8
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    mov ecx, [r14 + Lexer.lineno]
    mov r9d, ecx
    mov r10d, r8d               ; end_offset == offset, as CPython's is
    call comp_error_span
    jmp .fail
.string_ok:
    mov rdi, rbx
    mov esi, TOK_STRING
    mov rdx, r15
    mov rcx, r12
    sub rcx, r15
    mov r8, [rbp - LR_FLAGS]
    call lex_emit
    ; Only now do the lines the literal spanned move the counter.
    mov rax, [rbp - LR_STRNL]
    test rax, rax
    jz .scan
    add [r14 + Lexer.lineno], eax
    mov rax, [rbp - LR_STRLS]
    mov [r14 + Lexer.line_start], rax
    jmp .scan

;; --- operators and delimiters ---------------------------------------------
.operator:
    mov r15, r12
    cmp dword [rbx + Comp.future_barry], 0
    je .normal_operator
    lea rax, [r12 + 1]
    cmp rax, r13
    jae .normal_operator
    cmp word [r12], '<>'
    je .barry_notequal
    cmp word [r12], '!='
    jne .normal_operator
    mov r8, r12
    sub r8, [r14 + Lexer.line_start]
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    mov ecx, [r14 + Lexer.lineno]
    CSTRING rdx, "with Barry as BDFL, use '<>' instead of '!='"
    call comp_error
    jmp .fail
.barry_notequal:
    mov eax, TOK_NOTEQUAL
    mov edx, 2
    jmp .operator_kind
.normal_operator:
    mov rdi, r12
    mov rsi, r13
    call lex_operator                   ; rax = kind, rdx = length
    test eax, eax
    jz .bad_char
.operator_kind:
    add r12, rdx
    mov [rbp - LR_KIND], rax

    ; Bracket depth drives implicit line joining, so it is maintained here
    ; rather than in the parser: the lexer is what has to know.
    cmp eax, TOK_LPAR
    je .op_open
    cmp eax, TOK_LSQB
    je .op_open
    cmp eax, TOK_LBRACE
    je .op_open
    cmp eax, TOK_RPAR
    je .op_close
    cmp eax, TOK_RSQB
    je .op_close
    cmp eax, TOK_RBRACE
    je .op_close
    jmp .op_emit
.op_open:
    ; Remember where it was opened, for the "never closed" message.
    mov ecx, [r14 + Lexer.paren_depth]
    cmp ecx, LEX_MAX_BRACKET
    jae .op_open_deep
    movzx edx, byte [r15]
    mov [r14 + Lexer.open_ch + rcx], dl
    mov edx, [r14 + Lexer.lineno]
    mov [r14 + Lexer.open_line + rcx*4], edx
    mov rdx, r15
    sub rdx, [r14 + Lexer.line_start]
    mov [r14 + Lexer.open_col + rcx*4], edx
.op_open_deep:
    inc dword [r14 + Lexer.paren_depth]
    jmp .op_emit
.op_close:
    cmp dword [r14 + Lexer.paren_depth], 0
    je .op_emit                         ; unbalanced; the parser reports it
    dec dword [r14 + Lexer.paren_depth]
.op_emit:
    mov rdi, rbx
    mov rsi, [rbp - LR_KIND]
    mov rdx, r15
    mov rcx, r12
    sub rcx, r15
    xor r8d, r8d
    call lex_emit
    jmp .scan

;; --- end of input ----------------------------------------------------------
; CPython's shape: a NEWLINE if the last logical line was not terminated, then
; one DEDENT per open level, then ENDMARKER.  The parser relies on every suite
; being closed before it sees ENDMARKER.
.eof:
    mov rax, [rbx + Comp.tokens + Buf.len]
    test rax, rax
    jz .eof_dedents
    dec rax
    shl rax, TOKEN_SHIFT
    add rax, [rbx + Comp.tokens + Buf.data]
    movzx eax, word [rax + Token.kind]
    cmp eax, TOK_NEWLINE
    je .eof_dedents
    cmp eax, TOK_INDENT
    je .eof_dedents
    cmp eax, TOK_DEDENT
    je .eof_dedents
    mov rdi, rbx
    mov esi, TOK_NEWLINE
    mov rdx, r13
    xor ecx, ecx
    xor r8d, r8d
    call lex_emit

.eof_dedents:
    mov ecx, [r14 + Lexer.indent_top]
    test ecx, ecx
    jz .eof_end
    dec ecx
    mov [r14 + Lexer.indent_top], ecx
    mov rdi, rbx
    mov esi, TOK_DEDENT
    mov rdx, r13
    xor ecx, ecx
    xor r8d, r8d
    call lex_emit
    jmp .eof_dedents

.eof_end:
    mov rdi, rbx
    mov esi, TOK_ENDMARKER
    mov rdx, r13
    xor ecx, ecx
    xor r8d, r8d
    call lex_emit
    mov eax, 1
    jmp .ret

;; --- local subroutines -----------------------------------------------------
; These run inside lex_run's register world: r12 is the cursor, r13 the end,
; r14 the lexer state.  They advance r12 and touch nothing else.

; .sub_digits - advance over decimal digits and the underscores between them.
.sub_digits:
    lea rcx, [rel cc_table]
.sd_loop:
    cmp r12, r13
    jae .sd_done
    movzx eax, byte [r12]
    cmp al, '_'
    je .sd_next
    test byte [rcx + rax], CC_DIGIT
    jz .sd_done
.sd_next:
    inc r12
    jmp .sd_loop
.sd_done:
    ret

; .sub_string - advance past a string literal, r12 pointing at its open quote.
;   -> eax = 1, or 0 for an unterminated literal (the caller reports it).
; A backslash escapes the next byte even in a raw string: r"\" is unterminated
; in Python too, because rawness affects the *value*, not where the token ends.
.sub_string:
    ; PEP 701 made an f-string's end depend on its whole grammar rather than on
    ; the next copy of its quote: a replacement field may hold that quote, a
    ; nested f-string, a comment, a backslash and a newline.
    ; src/compiler/fstrscan.asm answers that, for this scanner and for the two
    ; in fstring.asm both.  Anything without an f is still the plain loop
    ; below, which is what every other literal in the file takes.
    test qword [rbp - LR_FLAGS], TF_STR_FMT
    jz .ss_plain
    mov rax, [rbp - LR_STRNL]
    mov [rbp - LR_SKIP + FsSkip.nl], rax
    mov rax, [r14 + Lexer.line_start]
    mov [rbp - LR_SKIP + FsSkip.lstart], rax
    mov qword [rbp - LR_SKIP + FsSkip.level], 0
    mov qword [rbp - LR_SKIP + FsSkip.err], FSE_OK
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rbp - LR_SKIP]
    mov rcx, [rbp - LR_FLAGS]
    and ecx, FS_LIT_RAW | FS_LIT_FMT
    sub rsp, 8                          ; this subroutine is itself one call deep
    extern fs_skip_literal
    call fs_skip_literal
    add rsp, 8
    test rax, rax
    jz .ss_plain
    ; Only on success.  A failure leaves the counters alone because .ss_plain
    ; is about to count from the opening quote again.
    mov rcx, [rbp - LR_SKIP + FsSkip.nl]
    mov [rbp - LR_STRNL], rcx
    mov rcx, [rbp - LR_SKIP + FsSkip.lstart]
    mov [rbp - LR_STRLS], rcx
    mov r12, rax
    mov eax, 1
    ret

    ; A failure falls through to the plain scan rather than reporting: an
    ; f-string that does not parse then ends where it always did, and
    ; fstring.asm reports it with the message and the position it always had.
    ; `f'{'` is the case that matters -- CPython calls that
    ; `f-string: expecting '}'`, which is fstring.asm's answer and not a
    ; lexer's, and reporting an unterminated literal here instead lost it.
    ; Acceptance improves; no error message moves.

.ss_plain:
    movzx r10d, byte [r12]              ; the quote character
    mov r11d, 1                         ; quote run length
    lea rax, [r12 + 2]
    cmp rax, r13
    ja .ss_single
    movzx edx, byte [r12 + 1]
    cmp edx, r10d
    jne .ss_single
    movzx edx, byte [r12 + 2]
    cmp edx, r10d
    jne .ss_empty                       ; '' or "" -- an empty short string
    mov r11d, 3
.ss_single:
    add r12, r11
.ss_loop:
    cmp r12, r13
    jae .ss_unterminated
    movzx eax, byte [r12]
    cmp al, 92                          ; backslash
    je .ss_escape
    cmp al, 10
    je .ss_newline
    cmp eax, r10d
    je .ss_maybe_close
    inc r12
    jmp .ss_loop

.ss_escape:
    ; Skip the escaped byte.  A backslash-newline inside a literal still ends
    ; a source line, so the line counter has to move with it.
    inc r12
    cmp r12, r13
    jae .ss_unterminated
    cmp byte [r12], 10
    jne .ss_escape_done
    inc qword [rbp - LR_STRNL]
    lea rax, [r12 + 1]
    mov [rbp - LR_STRLS], rax
.ss_escape_done:
    inc r12
    jmp .ss_loop

.ss_newline:
    ; Only a triple-quoted literal may span lines.
    cmp r11d, 3
    jne .ss_unterminated
    inc qword [rbp - LR_STRNL]
    inc r12
    mov [rbp - LR_STRLS], r12
    jmp .ss_loop

.ss_maybe_close:
    cmp r11d, 3
    je .ss_close3
    inc r12
    mov eax, 1
    ret
.ss_close3:
    lea rax, [r12 + 2]
    cmp rax, r13
    jae .ss_close3_short
    movzx edx, byte [r12 + 1]
    cmp edx, r10d
    jne .ss_close3_no
    movzx edx, byte [r12 + 2]
    cmp edx, r10d
    jne .ss_close3_no
    add r12, 3
    mov eax, 1
    ret
.ss_close3_short:
.ss_close3_no:
    inc r12
    jmp .ss_loop

.ss_empty:
    add r12, 2
    mov eax, 1
    ret

.ss_unterminated:
    xor eax, eax
    ret

.fail:
    mov [r14 + Lexer.cur], r12
    xor eax, eax
    jmp .ret

.ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC lex_run

; The keywords a number may end against.  CPython's tokenizer takes `if`, `in`
; and `is` from the first two characters and these five whole; anything else
; after a literal is an error.
section .rodata
snc_kw_and:  db "and", 0
snc_kw_else: db "else", 0
snc_kw_for:  db "for", 0
snc_kw_not:  db "not", 0
snc_kw_or:   db "or", 0
align 8
snc_num_keywords:
    dq snc_kw_and, snc_kw_else, snc_kw_for, snc_kw_not, snc_kw_or, 0

section .text
