; compile.asm - The compiler pipeline, every way into it, and how it fails
;
; Three entry points reach the same passes: code_from_path for `apython foo.py`
; and for importing a .py, and compile()/exec()/eval() for a string.
;
; A pass may not call raise_exception.  That tail-jumps into
; eval_exception_unwind, which calls fatal_error when there is no live frame --
; and the path entry point compiles before any frame exists.  So a failing pass
; records the error with comp_error and returns 0/NULL, the first error wins,
; and the driver turns it into a pending exception once every buffer has been
; freed.  The record side and the raise side are both here now, which is the
; only way to read that contract in one place.  A compiler that raised from
; inside the parser would strand every allocation the parse had made.
;
; The exception is the compile()/exec()/eval() builtins below: those are called
; from a running frame, so raising directly is correct there.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"
%include "value.inc"
%include "compiler.inc"

extern ap_free
extern ap_strcmp
extern dict_get
extern kw_names_pending
extern obj_as_index
extern obj_call_n
extern str_from_cstr_heap
extern ap_malloc
extern ap_memcpy
extern ap_memset
extern buf_free
extern buf_init
extern buf_push_u8
extern buf_reserve
extern exc_SyntaxError_type
extern ast_child
extern exc_IndentationError_type
extern exc_TabError_type
extern tuple_new
extern obj_decref
extern obj_dealloc

extern lex_run
extern sym_build
extern sym_finalize
extern sym_free_all
extern str_new_heap
extern str_intern_bytes
extern str_all_name_chars

extern asm_assemble
extern ast_obj
extern ast_at
extern ast_span_at
extern comp_attach_location
extern comp_emit_warnings
extern comp_error
extern comp_failed
extern ast_obj_at
extern cg_const
extern cg_emit
extern none_singleton
extern cg_expr
extern cg_unit_free
extern cg_unit_init
extern current_exception
extern exc_from_cstr
extern exc_set_context
extern obj_decref
extern par_expect
extern par_expr
extern par_module
extern par_peek
extern ast_mark
extern ast_push
extern par_finish_list
extern cg_body
extern par_kind
extern par_advance
extern str_from_cstr_heap

; --- Named frame-layout constants ---
CI_SRC   equ 16
CI_LEN   equ 24
CI_FILE  equ 32
CI_MODE  equ 40
CI_FRAME equ 40          ; + 1 push = 48

section .text

;; ============================================================================
;; comp_src_normalize(const char *src, int64_t len, int64_t *out_len)
;;   -> char * (owned), NUL-terminated with CODE-style tail padding
;;
;; Three normalizations, all of which the rest of the compiler then gets to
;; ignore:
;;   - a UTF-8 BOM is dropped;
;;   - CRLF and a lone CR both become LF, so the lexer has one line ending;
;;   - the buffer carries 8 trailing NUL bytes, because the keyword matcher
;;     reads 8 bytes at once and the operator matcher 4, either of which can
;;     start on the last byte of the source.
;; ============================================================================
SN_OUT   equ 8
SN_DST   equ 16
SN_FRAME equ 24          ; + 3 pushes = 48
DEF_FUNC comp_src_normalize, SN_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - SN_OUT], rdx
    mov rbx, rdi                        ; source
    mov r12, rsi                        ; length

    ; Drop a UTF-8 byte-order mark.
    cmp r12, 3
    jb .no_bom
    cmp byte [rbx], 0xef
    jne .no_bom
    cmp byte [rbx + 1], 0xbb
    jne .no_bom
    cmp byte [rbx + 2], 0xbf
    jne .no_bom
    add rbx, 3
    sub r12, 3
.no_bom:

    lea rdi, [r12 + 8]
    call ap_malloc
    mov [rbp - SN_DST], rax
    mov r13, rax                        ; write cursor

    xor ecx, ecx                        ; read index
.copy_loop:
    cmp rcx, r12
    jae .copy_done
    movzx eax, byte [rbx + rcx]
    cmp al, 13                          ; CR
    jne .copy_plain
    ; CRLF collapses to one LF; a lone CR becomes one LF.
    inc rcx
    cmp rcx, r12
    jae .emit_lf
    cmp byte [rbx + rcx], 10
    jne .emit_lf
    inc rcx
.emit_lf:
    mov byte [r13], 10
    inc r13
    jmp .copy_loop
.copy_plain:
    mov [r13], al
    inc r13
    inc rcx
    jmp .copy_loop
.copy_done:

    mov rax, r13
    sub rax, [rbp - SN_DST]
    mov rdx, [rbp - SN_OUT]
    mov [rdx], rax                      ; the normalized length

    mov rdi, r13                        ; zero the 8-byte tail
    xor esi, esi
    mov edx, 8
    call ap_memset

    mov rax, [rbp - SN_DST]
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC comp_src_normalize

;; ============================================================================
;; comp_init(Comp *c, const char *src, int64_t len, PyStrObject *filename,
;;           int mode)
;; The filename reference is borrowed; the caller outlives the compilation.
;; ============================================================================
DEF_FUNC comp_init, CI_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - CI_SRC], rsi
    mov [rbp - CI_LEN], rdx
    mov [rbp - CI_FILE], rcx
    mov [rbp - CI_MODE], r8

    mov rdi, rbx
    xor esi, esi
    mov edx, Comp_size
    call ap_memset

    mov rdi, [rbp - CI_SRC]
    mov rsi, [rbp - CI_LEN]
    lea rdx, [rbx + Comp.srclen]
    call comp_src_normalize
    mov [rbx + Comp.src], rax

    mov rax, [rbp - CI_FILE]
    mov [rbx + Comp.filename], rax
    mov rax, [rbp - CI_MODE]
    mov [rbx + Comp.mode], eax

    lea rdi, [rbx + Comp.tokens]
    mov esi, Token_size
    call buf_init
    lea rdi, [rbx + Comp.nodes]
    mov esi, AstNode_size
    call buf_init
    lea rdi, [rbx + Comp.spans]
    mov esi, AstSpan_size
    call buf_init
    lea rdi, [rbx + Comp.children]
    mov esi, 4
    call buf_init
    lea rdi, [rbx + Comp.pending]
    mov esi, 4
    call buf_init
    lea rdi, [rbx + Comp.objs]
    mov esi, 8
    call buf_init
    lea rdi, [rbx + Comp.rawnames]
    mov esi, 4
    call buf_init
    lea rdi, [rbx + Comp.typeparams]
    mov esi, 4
    call buf_init
    lea rdi, [rbx + Comp.typecomments]
    mov esi, 4
    call buf_init
    lea rdi, [rbx + Comp.typeignores]
    mov esi, 4
    call buf_init
    mov dword [rbx + Comp.want_tc], 0
    mov dword [rbx + Comp.pending_tc], 0
    lea rdi, [rbx + Comp.scopes]
    mov esi, Scope_size
    call buf_init

    ; Reserve node 0 as the null node, so a 0 index reads as "absent" without
    ; any call site needing a separate presence flag.  Its span goes with it:
    ; the two Bufs are indexed the same way and must stay in step.
    lea rdi, [rbx + Comp.nodes]
    mov esi, 1
    call buf_reserve
    mov rdi, rax
    xor esi, esi
    mov edx, AstNode_size
    call ap_memset
    lea rdi, [rbx + Comp.spans]
    mov esi, 1
    call buf_reserve
    mov dword [rax + AstSpan.end_lineno], -1
    mov dword [rax + AstSpan.end_col], -1
    ; And its type-parameter slot: typeparams is indexed by node number too,
    ; and ast_make only ever appends for a node it makes itself.
    lea rdi, [rbx + Comp.typeparams]
    mov esi, 1
    call buf_reserve
    mov dword [rax], 0
    lea rdi, [rbx + Comp.typecomments]
    mov esi, 1
    call buf_reserve
    mov dword [rax], 0

    ; Reserve objs[0] for the same reason.  Without it the first literal in a
    ; compilation gets index 0, and every caller that tests an object index for
    ; zero reads it as a failure -- which is exactly what `import sys` hit.
    lea rdi, [rbx + Comp.objs]
    mov esi, 1
    call buf_reserve
    mov qword [rax], 0
    ; rawnames is indexed by the same number and grows with objs in ast_obj,
    ; so slot 0 is reserved here too.
    lea rdi, [rbx + Comp.rawnames]
    mov esi, 1
    call buf_reserve
    mov dword [rax], 0

    pop rbx
    leave
    ret
END_FUNC comp_init

;; ============================================================================
;; comp_free(Comp *c)
;; Releases everything a compilation allocated, on the success and failure
;; paths alike.  comp.objs is the only refcounted holding, which is exactly why
;; every PyObject the front end builds is put there.
;; ============================================================================
DEF_FUNC comp_free, 8
    push rbx
    push r12
    push r13
    mov rbx, rdi

    ; comp.objs holds Values, not pointers.  A small int and a float are
    ; immediates rather than heap objects, so releasing them has to go through
    ; DECREF_V -- which is NULL-safe and a no-op for anything that is not a
    ; pointer.  Using obj_decref here would treat the bits of 1.5 as an
    ; address.
    mov r12, [rbx + Comp.objs + Buf.data]
    mov r13, [rbx + Comp.objs + Buf.len]
.obj_loop:
    test r13, r13
    jz .objs_done
    dec r13
    mov rax, [r12 + r13*8]
    DECREF_V rax, rcx
    mov r12, [rbx + Comp.objs + Buf.data]   ; obj_dealloc clobbers caller-saved
    jmp .obj_loop
.objs_done:

    mov rdi, rbx
    call sym_free_all
    lea rdi, [rbx + Comp.scopes]
    call buf_free
    lea rdi, [rbx + Comp.objs]
    call buf_free
    lea rdi, [rbx + Comp.rawnames]
    call buf_free
    lea rdi, [rbx + Comp.typeparams]
    call buf_free
    lea rdi, [rbx + Comp.typecomments]
    call buf_free
    lea rdi, [rbx + Comp.typeignores]
    call buf_free
    lea rdi, [rbx + Comp.pending]
    call buf_free
    lea rdi, [rbx + Comp.spans]
    call buf_free
    lea rdi, [rbx + Comp.children]
    call buf_free
    lea rdi, [rbx + Comp.nodes]
    call buf_free
    lea rdi, [rbx + Comp.tokens]
    call buf_free

    mov rdi, [rbx + Comp.src]
    call ap_free
    mov qword [rbx + Comp.src], 0

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC comp_free

;; ============================================================================
;; comp_intern(const char *s, int64_t len) -> rax = owned PyStrObject*
;;
;; Every identifier and string LITERAL the front end builds goes through here
;; -- which was not true until 2026-09-06: `par_string_atom` called
;; str_new_heap directly, so a table this never reached could not share a
;; constant with anything.  It is a single entry point on purpose: a PyStrObject carries two lengths -- ob_size
;; in bytes and ob_length in code points -- and a constructor that set only the
;; first would give non-ASCII identifiers and literals a silently wrong len().
;; str_new_heap sets both.
;;
;; It also dedups, through the process-wide intern table -- but only for a
;; string that LOOKS LIKE AN IDENTIFIER, every byte [A-Za-z0-9_].  That is
;; CPython's rule for a string constant and it is the guard rail: over-interning
;; is invisible inside one module and shows up as two modules' unrelated long
;; strings sharing an object.  `"hello"` is shared; `"hello world"` is not.
;;
;; Deduping matters here for a reason beyond memory.  `cg_name` dedups within
;; ONE CompUnit, by linear scan, so `__init__` and a sibling method held two
;; different objects for the same attribute name -- and `op_load_attr_instance`
;; guards its cache by pointer identity between `co_names[i]` and the key the
;; instance dict kept, which is the FIRST writer's.  So `self.x` read from a
;; method other than the one that wrote it failed the guard on every execution,
;; deopted and re-specialized forever.  A .pyc did not show it, because
;; marshal's FLAG_REF happened to share those strings; our own compiler's
;; output did, at about 47% on an attribute loop.
;; ============================================================================
CIN2_S     equ 8
CIN2_LEN   equ 16
CIN2_FRAME equ 16           ; + 0 pushes = 16-aligned at the calls
DEF_FUNC comp_intern, CIN2_FRAME
    mov [rbp - CIN2_S], rdi
    mov [rbp - CIN2_LEN], rsi
    call str_all_name_chars
    mov rdi, [rbp - CIN2_S]
    mov rsi, [rbp - CIN2_LEN]
    test eax, eax
    jz .ci_plain
    call str_intern_bytes
    leave
    ret
.ci_plain:
    call str_new_heap
    leave
    ret
END_FUNC comp_intern

;; ============================================================================
;; comp_intern_forced(const char *s, int64_t len) -> rax = owned PyStrObject*
;;
;; The same, without the identifier-shaped test: a NAME is interned whatever
;; it is written in, as CPython interns every identifier including a non-ASCII
;; one.  `comp_intern_name` is the only caller, and names are the whole point.
;; ============================================================================
DEF_FUNC_BARE comp_intern_forced
    jmp str_intern_bytes
END_FUNC comp_intern_forced


;; ============================================================================
;; comp_name_obj(Comp *c, const char *s, int64_t len) -> rax = obj index, 0 on
;; failure
;;
;; Every identifier in the tree goes through here: intern it with private-name
;; mangling applied, hand it to the object arena, and -- when the mangling
;; actually rewrote it -- record the name as it was WRITTEN alongside.
;;
;; The compiler wants the mangled name and the AST wants the source one.
;; CPython gets both by mangling later, in the symbol table and the code
;; generator; here the class is only in hand while the parser is inside its
;; body, so the mangling has to happen now and the other half is kept rather
;; than recomputed.  Without it `self.__x` inside `class C` read back from
;; ast.parse as `_C__x`.
;;
;; Mangling always lengthens -- it prepends `_` and at least one character of
;; the class name -- so the two are told apart by the length alone.
;; ============================================================================
CNO_COMP  equ 8
CNO_STR   equ 16
CNO_LEN   equ 24
CNO_IDX   equ 32
CNO_FRAME equ 48            ; + 0 pushes = 48
global comp_name_obj
DEF_FUNC comp_name_obj, CNO_FRAME
    mov [rbp - CNO_COMP], rdi
    mov [rbp - CNO_STR], rsi
    mov [rbp - CNO_LEN], rdx

    call comp_intern_name
    test rax, rax
    jz .cno_fail
    mov rsi, rax
    mov rdi, [rbp - CNO_COMP]
    call ast_obj                ; takes ownership
    test rax, rax
    jz .cno_fail
    mov [rbp - CNO_IDX], rax

    ; Did it mangle?  The interned string is longer than the source text
    ; exactly when it did.
    mov rdi, [rbp - CNO_COMP]
    mov esi, eax
    call ast_obj_at             ; borrowed
    mov rcx, [rax + PyStrObject.ob_size]
    cmp rcx, [rbp - CNO_LEN]
    je .cno_done

    mov rdi, [rbp - CNO_STR]
    mov rsi, [rbp - CNO_LEN]
    call comp_intern
    test rax, rax
    jz .cno_done                ; the mangled name alone is still usable
    mov rsi, rax
    mov rdi, [rbp - CNO_COMP]
    call ast_obj
    test rax, rax
    jz .cno_done
    mov rdx, [rbp - CNO_COMP]
    mov rcx, [rdx + Comp.rawnames + Buf.data]
    mov rdx, [rbp - CNO_IDX]
    mov [rcx + rdx*4], eax

.cno_done:
    mov rax, [rbp - CNO_IDX]
    leave
    ret
.cno_fail:
    xor eax, eax
    leave
    ret
END_FUNC comp_name_obj

;; ============================================================================
;; comp_set_pending(Comp *c)
;;
;; Turn the recorded error into a real exception object and make it the pending
;; one -- WITHOUT unwinding.  raise_exception would tail-jump into
;; eval_exception_unwind, which calls fatal_error when there is no interpreter
;; frame, and `./apython foo.py` compiles before any frame exists.  Setting
;; current_exception directly leaves the caller free to clean up and return
;; a failure the ordinary way.
;; ============================================================================
DEF_FUNC comp_set_pending, 8
    push rbx
    mov rbx, rdi
    cmp dword [rbx + Comp.err + CompErr.set], 0
    je .none

    mov rdi, [rbx + Comp.err + CompErr.type]
    mov rsi, [rbx + Comp.err + CompErr.msg]
    call exc_from_cstr

    ; A syntax error carries where it happened, in CPython's shape:
    ; args = (msg, (filename, lineno, offset, text)).  The traceback printer
    ; reads that tuple to produce the File/line/caret block, and str() reads it
    ; for the "(file, line N)" suffix; without it a syntax error is a bare
    ; message with nothing to locate it by.
    push rax
    mov rdi, rbx
    mov rsi, rax
    call comp_attach_location
    pop rax

    ; Chain onto whatever was already being handled, as a raise would.
    mov rsi, [rel current_exception]
    test rsi, rsi
    jz .no_prev
    push rax
    mov rdi, rax
    call exc_set_context
    mov rdi, [rel current_exception]
    call obj_decref
    pop rax
.no_prev:
    mov [rel current_exception], rax
.none:
    pop rbx
    leave
    ret
END_FUNC comp_set_pending

;; ============================================================================
;; per_star_check(Comp *c, uint32_t node) -> eax = 1 when the node is not a
;;     starred element, 0 after recording the SyntaxError that says it is
;;
;; eval's start symbol is `testlist` where a statement's is
;; `testlist_star_expr`, so `eval("*a")` and `eval("1, *a")` are syntax errors
;; while `exec` takes both.  CPython blames the star itself, one character
;; wide, which is what the node's own line and column are: par_starred_bp
;; takes them from the star token.
;; ============================================================================
DEF_FUNC_LOCAL per_star_check, 8        ; + 1 push = 16
    push rbx
    mov rbx, rdi
    call ast_at
    cmp byte [rax + AstNode.kind], AST_STARRED
    je .star
    mov eax, 1
    pop rbx
    leave
    ret
.star:
    mov ecx, [rax + AstNode.lineno]
    mov r8d, [rax + AstNode.col]
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    CSTRING rdx, "invalid syntax"
    call comp_error                     ; answers 0, which is our answer too
    pop rbx
    leave
    ret
END_FUNC per_star_check

;; ============================================================================
;; par_eval_root(Comp *c) -> rax = the root expression node, 0 on error
;; The `eval` start symbol: CPython's is `eval_input: testlist NEWLINE*
;; ENDMARKER`, and a testlist is COMMA-SEPARATED -- so `eval("1, 2")` is a
;; tuple, not a syntax error.  This called par_expr, which parses one `test`
;; and stops at the comma, and the ENDMARKER check below then refused the
;; rest; ast.literal_eval of any tuple went the same way.
;;
;; The loop is par_exprlist_stmt's, not a call to it, because the two start
;; symbols differ in one place: a statement's is `testlist_star_expr` and
;; takes `*a`, and eval's does not.  Calling it and rejecting starred children
;; afterwards cannot tell `eval("1, *a")`, which is an error, from
;; `eval("(*a,)")`, which is not -- both arrive as a tuple with a starred
;; child, and only the first one's star is at the top level.
;;
;; Trailing junk is still an error rather than being ignored, which is what
;; makes eval("1 2") a syntax error.
;; ============================================================================
PER_FIRST equ 8
PER_LINE  equ 16
PER_MARK  equ 24
PER_FRAME equ 32                ; + 2 pushes = 48
DEF_FUNC par_eval_root, PER_FRAME
    push rbx
    push r12
    mov rbx, rdi

    call par_peek
    TOK_POS rax
    mov [rbp - PER_LINE], rcx

    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov [rbp - PER_FIRST], rax
    mov rdi, rbx
    mov esi, eax
    call per_star_check
    test eax, eax
    jz .fail

    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    jne .single

    mov rdi, rbx
    call ast_mark
    mov [rbp - PER_MARK], rax
    mov rdi, rbx
    mov rsi, [rbp - PER_FIRST]
    call ast_push
.tuple_loop:
    mov rdi, rbx
    call par_advance                    ; consume ','
    mov rdi, rbx
    call par_kind
    ; A trailing comma ends the tuple: eval("1,") is a one-tuple.
    cmp eax, TOK_NEWLINE
    je .tuple_done
    cmp eax, TOK_ENDMARKER
    je .tuple_done
    mov rdi, rbx
    mov esi, BP_NONE
    call par_expr
    test rax, rax
    jz .fail
    mov r12, rax
    mov rdi, rbx
    mov esi, eax
    call per_star_check
    test eax, eax
    jz .fail
    mov rdi, rbx
    mov rsi, r12
    call ast_push
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    je .tuple_loop
.tuple_done:
    mov rdi, rbx
    mov esi, AST_TUPLE
    mov rdx, [rbp - PER_LINE]
    mov rcx, [rbp - PER_MARK]
    call par_finish_list
    test rax, rax
    jz .fail
    mov r12, rax
    jmp .skip_newlines

.single:
    mov r12, [rbp - PER_FIRST]

.skip_newlines:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NEWLINE
    jne .at_end
    mov rdi, rbx
    call par_advance
    jmp .skip_newlines

.at_end:
    mov rdi, rbx
    mov esi, TOK_ENDMARKER
    CSTRING rdx, "invalid syntax"
    call par_expect
    test eax, eax
    jz .fail
    mov rax, r12
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
END_FUNC par_eval_root

;; ============================================================================
;; par_func_type_root(Comp *c) -> rax = an AST_FUNCTIONTYPE node, 0 on error
;;
;; The "func_type" start symbol: `(int, str) -> bool`, or `(...) -> bool` for
;; a signature whose arguments are not spelled out.  It is the type comment a
;; stub file carries, and the only mode whose grammar is not a subset of the
;; module's -- a bare `->` is not an expression anywhere else.
;; ============================================================================
PFT_MARK  equ 16
PFT_RET   equ 24
PFT_LINE  equ 32
PFT_FRAME equ 40            ; + 2 pushes = 56... one word more to land right
DEF_FUNC par_func_type_root, 48         ; + 2 pushes = 64, 16-aligned
    push rbx
    push r12
    mov rbx, rdi

    call par_peek
    TOK_POS rax
    mov [rbp - PFT_LINE], rcx

    mov rdi, rbx
    mov esi, TOK_LPAR
    CSTRING rdx, "invalid syntax"
    call par_expect
    test eax, eax
    jz .pft_fail

    mov rdi, rbx
    call ast_mark
    mov [rbp - PFT_MARK], rax

    ; `(...)` means "any arguments"; CPython answers an empty argtypes list
    ; with an Ellipsis constant in it, which ast.dump shows as [Constant(...)].
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_RPAR
    je .pft_args_done

.pft_arg_loop:
    mov rdi, rbx
    xor esi, esi                    ; BP_NONE
    call par_expr
    test rax, rax
    jz .pft_fail
    mov rdi, rbx
    mov rsi, rax
    call ast_push
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_COMMA
    jne .pft_args_done
    mov rdi, rbx
    call par_advance
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_RPAR
    je .pft_args_done
    jmp .pft_arg_loop

.pft_args_done:
    mov rdi, rbx
    mov esi, TOK_RPAR
    CSTRING rdx, "invalid syntax"
    call par_expect
    test eax, eax
    jz .pft_fail

    mov rdi, rbx
    mov esi, TOK_RARROW
    CSTRING rdx, "invalid syntax"
    call par_expect
    test eax, eax
    jz .pft_fail

    mov rdi, rbx
    xor esi, esi                    ; BP_NONE
    call par_expr
    test rax, rax
    jz .pft_fail
    mov [rbp - PFT_RET], rax

.pft_skip_newlines:
    mov rdi, rbx
    call par_kind
    cmp eax, TOK_NEWLINE
    jne .pft_at_end
    mov rdi, rbx
    call par_advance
    jmp .pft_skip_newlines

.pft_at_end:
    mov rdi, rbx
    mov esi, TOK_ENDMARKER
    CSTRING rdx, "invalid syntax"
    call par_expect
    test eax, eax
    jz .pft_fail

    mov rdi, rbx
    mov esi, AST_FUNCTIONTYPE
    mov rdx, [rbp - PFT_LINE]
    mov rcx, [rbp - PFT_MARK]
    call par_finish_list
    test rax, rax
    jz .pft_fail
    mov r12, rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    mov edx, [rbp - PFT_RET]
    mov [rax + AstNode.a], edx          ; the return type
    mov rax, r12
    pop r12
    pop rbx
    leave
    ret
.pft_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC par_func_type_root

;; ============================================================================
;; ============================================================================
;; compile_ast_raw(const char *src, i64 len, PyStrObject *filename, int mode,
;;                  int want_type_comments) -> rax = the raw tree, or 0 with
;;                  the exception already pending
;;
;; compile_source's sibling, stopping where the AST is complete.  It runs
;; comp_init, the lexer and the parser, hands the arena to ar_node, and then
;; tears the Comp down exactly as compile_source does -- so nothing about the
;; arena's lifetime changes: the tree ar_node builds is made of ordinary
;; Python objects that own themselves, and by the time this returns there is
;; no arena left to point into.
;;
;; No symbol table, no CompUnit, no codegen.  Those decide how names are
;; stored and what bytecode says it; neither is a question about the tree.
;; ============================================================================
CAR_SRC   equ 8
CAR_LEN   equ 16
CAR_FILE  equ 24
CAR_MODE  equ 32
CAR_ROOT  equ 40
CAR_TREE  equ 48
CAR_COMP  equ 56
CAR_WANTTC equ 64           ; PyCF_TYPE_COMMENTS
CAR_FRAME equ 72            ; + 1 push = 80, 16-byte aligned

global compile_ast_raw
DEF_FUNC compile_ast_raw, CAR_FRAME
    push rbx
    mov [rbp - CAR_SRC], rdi
    mov [rbp - CAR_LEN], rsi
    mov [rbp - CAR_FILE], rdx
    mov [rbp - CAR_MODE], rcx
    mov [rbp - CAR_WANTTC], r8
    mov qword [rbp - CAR_TREE], 0

    mov edi, Comp_size
    call ap_malloc
    mov rbx, rax
    mov [rbp - CAR_COMP], rax

    mov rdi, rbx
    mov rsi, [rbp - CAR_SRC]
    mov rdx, [rbp - CAR_LEN]
    mov rcx, [rbp - CAR_FILE]
    mov r8, [rbp - CAR_MODE]
    call comp_init
    mov rax, [rbp - CAR_WANTTC]
    mov [rbx + Comp.want_tc], eax

    mov rdi, rbx
    xor esi, esi                        ; the whole source
    xor edx, edx
    xor ecx, ecx
    call lex_run
    test eax, eax
    jz .car_failed

    cmp qword [rbp - CAR_MODE], CMODE_EVAL
    je .car_parse_eval
    cmp qword [rbp - CAR_MODE], CMODE_FUNC_TYPE
    je .car_parse_func_type
    mov rdi, rbx
    call par_module
    test rax, rax
    jz .car_failed
    ; "single" is exec with a different root: CPython's is Interactive, whose
    ; body is a statement list exactly as Module's is, so the node the parser
    ; already built only needs its kind changed.  Nothing compiles this tree,
    ; so the kind is never dispatched on.
    cmp qword [rbp - CAR_MODE], CMODE_SINGLE
    jne .car_parsed
    push rax
    mov rdi, rbx
    mov esi, eax
    call ast_at
    mov byte [rax + AstNode.kind], AST_INTERACTIVE
    mov rdi, rbx
    mov rsi, rax
    call par_single_check
    pop rax
    test eax, eax
    jz .car_failed
    jmp .car_parsed
.car_parse_func_type:
    mov rdi, rbx
    call par_func_type_root
    test rax, rax
    jz .car_failed
    jmp .car_parsed

.car_parse_eval:
    mov rdi, rbx
    call par_eval_root
    test rax, rax
    jz .car_failed
    ; par_eval_root answers the bare expression, because that is all codegen
    ; needs; CPython's `eval` mode root is an Expression around it, and
    ; AST_EXPRESSION exists for exactly this and had no producer.
    mov r8d, eax                    ; a = the expression
    mov rdi, rbx
    mov esi, AST_EXPRESSION
    xor edx, edx                    ; subkind
    mov ecx, 1                      ; lineno
    xor r9d, r9d                    ; b
    extern ast_make
    call ast_make
.car_parsed:
    test rax, rax
    jz .car_failed
    mov [rbp - CAR_ROOT], rax

    mov rdi, rbx
    mov esi, eax
    extern ar_node
    call ar_node
    mov [rbp - CAR_TREE], rax

.car_cleanup:
    mov rdi, rbx
    call comp_free
    mov rdi, rbx
    call ap_free
    mov rax, [rbp - CAR_TREE]
    pop rbx
    leave
    ret

.car_failed:
    mov rdi, rbx
    call comp_set_pending
    mov qword [rbp - CAR_TREE], 0
    jmp .car_cleanup
END_FUNC compile_ast_raw

section .bss
;; PEP 563: whether the code that called compile(), exec() or eval() was
;; itself compiled under `from __future__ import annotations`.  CPython
;; inherits the future flags of the calling frame into a nested compile
;; unless dont_inherit says otherwise, so the three builtins read their
;; caller's co_flags and leave the answer here.  A global rather than a
;; parameter because compile_source has four callers that are not builtins --
;; `./apython foo.py` among them -- and none of them has a frame to inherit
;; from.  CONSUMED by the next compile, so it can never leak into one that
;; did not ask.
global comp_inherit_future
comp_inherit_future: resq 1
section .text


;; compile_source(const char *src, int64_t len, PyStrObject *filename, int mode)
;;   -> rax = PyCodeObject*, or 0 with the exception already pending
;; compile_source_ex(..., Value raw)
;;   -- the same, with r8 a raw tree from lib/_ast_load.py to build the arena
;;      from in place of lexing and parsing `src`: compile() of an AST object.
;;      See astload.asm.  0 is compile_source.
;;
;; The whole pipeline, and the only place that disposes of it.  Every pass
;; below returns a failure rather than raising, so there is exactly one exit
;; path that frees the buffers and exactly one that turns a recorded error into
;; an exception.
;; ============================================================================
CS_SRC   equ 8
CS_LEN   equ 16
CS_FILE  equ 24
CS_MODE  equ 32
CS_ROOT  equ 40
CS_CODE  equ 48
; The CompUnit is a large struct living in this frame, so its offset is derived
; from its size rather than written out: a hand-picked number silently overlaps
; the scalar slots above the first time the struct grows, and the symptom is a
; field reading as garbage rather than anything that looks like a layout bug.
CS_UNIT  equ 48 + CompUnit_size
CS_COMP  equ CS_UNIT + 8
CS_RAW   equ CS_COMP + 8
CS_FRAME equ ((CS_RAW + 15) / 16) * 16 + 8       ; + 3 pushes = 16-aligned
DEF_FUNC_BARE compile_source
    xor r8d, r8d
    jmp compile_source_ex
END_FUNC compile_source

;; ============================================================================
;; compile_source_ex(src, len, filename, mode, Value raw) -> rax = PyCodeObject*,
;;   or 0 with the exception already pending
;;
;; The body of compile_source.  `raw` is 0 for source text, or the raw tree
;; astload.asm's al_root builds the arena from in place of the lexer and the
;; parser.
;; ============================================================================
DEF_FUNC compile_source_ex, CS_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - CS_RAW], r8
    mov [rbp - CS_SRC], rdi
    mov [rbp - CS_LEN], rsi
    mov [rbp - CS_FILE], rdx
    mov [rbp - CS_MODE], rcx
    mov qword [rbp - CS_CODE], 0

    mov edi, Comp_size
    call ap_malloc
    mov rbx, rax
    mov [rbp - CS_COMP], rax

    mov rdi, rbx
    mov rsi, [rbp - CS_SRC]
    mov rdx, [rbp - CS_LEN]
    mov rcx, [rbp - CS_FILE]
    mov r8, [rbp - CS_MODE]
    call comp_init

    ; PEP 563 is inherited from the code that called compile()/exec()/eval(),
    ; which is CPython's rule.  Consumed here, so it cannot leak into a
    ; compile that did not ask.
    mov rax, [rel comp_inherit_future]
    mov qword [rel comp_inherit_future], 0
    test rax, rax
    jz .cs_no_inherit
    mov dword [rbx + Comp.future_anno], 1
.cs_no_inherit:

    lea r12, [rbp - CS_UNIT]
    mov rdi, r12
    mov rsi, [rbp - CS_FILE]
    lea rdx, [rel cs_module_name]
    call cs_unit_setup

    ; An AST object's tree stands in for the lexer and the parser both.
    cmp qword [rbp - CS_RAW], 0
    je .cs_lex
    mov rdi, rbx
    mov rsi, [rbp - CS_RAW]
    extern al_root
    call al_root
    jmp .parsed
.cs_lex:
    mov rdi, rbx
    xor esi, esi                        ; the whole source
    xor edx, edx
    xor ecx, ecx
    call lex_run
    test eax, eax
    jz .failed

    cmp qword [rbp - CS_MODE], CMODE_EVAL
    je .parse_eval
    mov rdi, rbx
    call par_module
    test rax, rax
    jz .parsed
    cmp qword [rbp - CS_MODE], CMODE_SINGLE
    jne .parsed
    ; `single` is exec with a narrower start symbol; par_single_check is what
    ; enforces the narrowing, and compile_ast_raw applies it to the tree it
    ; hands back for the same reason.
    push rax
    mov rdi, rbx
    mov esi, eax
    call ast_at
    mov rdi, rbx
    mov rsi, rax
    call par_single_check
    pop rcx
    test eax, eax
    jz .failed
    mov rax, rcx
    jmp .parsed
.parse_eval:
    mov rdi, rbx
    call par_eval_root
.parsed:
    test rax, rax
    jz .failed
    mov [rbp - CS_ROOT], rax

    ; The symbol table has to run before anything is emitted: it is what
    ; decides whether each name is a fast local, a cell, a free variable or a
    ; global, and no emitter can answer that from the syntax alone.
    mov rdi, rbx
    mov rsi, [rbp - CS_ROOT]
    mov rdx, [rbp - CS_MODE]
    call sym_build
    test eax, eax
    jz .failed
    mov [r12 + CompUnit.scope], eax
    mov [r12 + CompUnit.comp], rbx
    mov [rbx + Comp.cur_scope], eax
    ; The future import is parsed by now, so the module's code object can
    ; carry the flag a nested compile() reads back.
    cmp dword [rbx + Comp.future_anno], 0
    je .cs_no_future_flag
    or dword [r12 + CompUnit.flags], CO_FUTURE_ANNOTATIONS
.cs_no_future_flag:
    mov rdi, rbx
    mov rsi, rax
    xor edx, edx                        ; a module has no parameters
    call sym_finalize
    test eax, eax
    jz .failed

    ; RESUME must be the first instruction of every code object: the frame
    ; setup, the eval breaker and the tracing hook all key off it.  A module's
    ; carries line ZERO, which is what CPython gives it -- co_lines() on
    ; `x=1` answers (0, 2, 0) -- and which is not the same as no location at
    ; all.  A tracer seeds itself from the frame's line at the 'call' event,
    ; so a RESUME claiming line 1 swallowed the module's first real line.
    mov rdi, r12
    mov esi, OP_RESUME
    xor edx, edx
    xor ecx, ecx
    call cg_emit
    or byte [rax + Instr.flags], IF_LINE0
    ; CPython's module RESUME is (0, 1, 0, 0): line zero, ending at line one,
    ; with an empty column span at the start of the file.  cg_emit attaches no
    ; columns to it because the line it is emitted for is zero and .curline is
    ; not, so they are written here.
    mov dword [rax + Instr.end_line], 1
    mov dword [rax + Instr.col], 0
    mov dword [rax + Instr.end_col], 0

    cmp qword [rbp - CS_MODE], CMODE_EVAL
    je .gen_eval

    ; A module that annotates anything needs __annotations__ to exist first.
    mov rdi, rbx
    mov rsi, [rbp - CS_ROOT]
    extern cg_has_annotation
    call cg_has_annotation
    test eax, eax
    jz .no_annotations
    mov rdi, r12
    mov esi, OP_SETUP_ANNOTATIONS
    xor edx, edx
    xor ecx, ecx
    call cg_emit
    or byte [rax + Instr.flags], IF_NOLINE
.no_annotations:

    ; A leading string literal is the module's __doc__, not a statement whose
    ; value is thrown away.
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rbp - CS_ROOT]
    extern cg_docstring
    call cg_docstring
    test eax, eax
    jz .failed

    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rbp - CS_ROOT]
    call cg_body
    test eax, eax
    jz .failed
    ; A module body has no value of its own: it always returns None, and exec()
    ; discards even that.
    mov rdi, r12
    mov rsi, [rbp - CS_ROOT]
    call cs_return_none
    jmp .assemble

.gen_eval:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rbp - CS_ROOT]
    call cg_expr
    test eax, eax
    jz .failed
    ; An eval-mode code object returns the expression's own value.
    mov rdi, r12
    mov esi, OP_RETURN_VALUE
    xor edx, edx
    mov ecx, 1
    call cg_emit

.assemble:
    ; A recorded error that no return value carried is still an error.  Every
    ; emitter is supposed to answer 0 for one, but cg_e_attribute handed back
    ; cg_super_attr's -1 instead and every caller read that as success, so the
    ; module assembled and ran with the offending expression simply missing.
    ; Asking comp_failed here closes the whole class rather than that instance.
    mov rdi, rbx
    call comp_failed
    test eax, eax
    jnz .failed

    mov rdi, rbx
    mov rsi, r12
    call asm_assemble
    mov [rbp - CS_CODE], rax
    test rax, rax
    jz .failed

.cleanup:
    ; The warnings the tokenizer recorded, emitted now that the code object
    ; exists and there is an interpreter to emit them from.  Only on success:
    ; a compile that failed has an exception of its own pending, and a
    ; warning raised over it would replace it.  A filter set to "error" turns
    ; one into a raise, and then this compile fails with it.
    cmp qword [rbp - CS_CODE], 0
    je .cleanup_free
    mov rdi, rbx
    call comp_emit_warnings
    test eax, eax
    jnz .cleanup_free
    mov rdi, [rbp - CS_CODE]
    call obj_decref
    mov qword [rbp - CS_CODE], 0

.cleanup_free:
    mov rdi, r12
    call cg_unit_free
    mov rdi, [rbp - CS_UNIT + CompUnit.name]
    call obj_decref
    mov rdi, rbx
    call comp_free
    mov rdi, rbx
    call ap_free
    mov rax, [rbp - CS_CODE]
    pop r13
    pop r12
    pop rbx
    leave
    ret
.failed:
    mov rdi, rbx
    call comp_set_pending
    mov qword [rbp - CS_CODE], 0
    jmp .cleanup
END_FUNC compile_source_ex

;; ============================================================================
;; cs_unit_setup(CompUnit *u, PyStrObject *filename, const char *name)
;; Wraps cg_unit_init, interning the code object's name.  The unit borrows the
;; filename from the caller and owns the name it makes here.
;; ============================================================================
DEF_FUNC cs_unit_setup, 16      ; + 2 pushes = 32
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rdx
    call str_from_cstr_heap
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call cg_unit_init
    pop r12
    pop rbx
    leave
    ret
END_FUNC cs_unit_setup

;; ============================================================================
;; cs_return_none(CompUnit *u, uint32_t root)
;; The implicit `return None` every module body ends with.
;; ============================================================================
DEF_FUNC cs_return_none, 8
    push rbx
    mov rbx, rdi
    ; No INCREF: cg_const stores a borrowed reference and
    ; asm_tuple_from_values takes co_consts' own, so incrementing here just
    ; leaked one per module compiled.  None outlives everything regardless.
    lea rsi, [rel none_singleton]
    mov rdi, rbx
    call cg_const
    mov rdx, rax
    mov rdi, rbx
    mov esi, OP_RETURN_CONST
    ; CPython gives the implicit return the line of the last statement, not
    ; "no location": `compile("x = 1\ny = 2\n")` ends its line table with a
    ; run for line 2, where this produced a trailing run with none at all.
    mov ecx, [rbx + CompUnit.lastline]
    ; ...and the columns with it, which means positioning the unit there so
    ; cg_emit's own column logic applies.  CPython gives the implicit return
    ; the last statement's extent, not "no location".
    mov [rbx + CompUnit.curline], ecx
    mov edx, [rbx + CompUnit.lastend]
    mov [rbx + CompUnit.curend], edx
    mov edx, [rbx + CompUnit.lastcol]
    mov [rbx + CompUnit.curcol], edx
    mov edx, [rbx + CompUnit.lastendcol]
    mov [rbx + CompUnit.curendcol], edx
    mov rdx, rax                ; the const index, saved above
    call cg_emit
    ; An EMPTY body leaves lastline at 0, and line 0 is what CPython gives
    ; that return -- `compile("")` has the single run (0, 4, 0), covering the
    ; RESUME and the RETURN_CONST together.  IF_LINE0 is how an instruction
    ; says "line zero, and I mean it", which IF_NOLINE is not: marked as
    ; having no location the return was trace-invisible, sys.settrace fired no
    ; `line` event at all for an empty module, and nothing ever set pdb's
    ; _user_requested_quit -- so `pdb empty.py` printed "The program finished
    ; and will be restarted" for ever.
    cmp dword [rax + Instr.line], 0     ; cg_emit clobbered rcx
    jnz .crn_have_line
    or byte [rax + Instr.flags], IF_LINE0
.crn_have_line:
    pop rbx
    leave
    ret
END_FUNC cs_return_none

;; ============================================================================
;; comp_intern_cstr(Comp *c, const char *s) -> rax = a borrowed PyStrObject*
;;
;; For names the compiler invents rather than reads from the source --
;; __module__, __qualname__, the leading component of a dotted import.  They go
;; into comp.objs like every other literal, because CompUnit.names holds
;; BORROWED references: a string created and released at the call site leaves a
;; dangling pointer in co_names, and the failure surfaces as a wild jump inside
;; dict_lookup at run time.
;; ============================================================================
DEF_FUNC comp_intern_cstr, 16
    push rbx
    push r12
    mov rbx, rdi
    mov rdi, rsi
    call str_from_cstr_heap
    test rax, rax
    jz .fail
    mov rdi, rbx
    mov rsi, rax
    call ast_obj
    mov rdi, rbx
    mov rsi, rax
    call ast_obj_at
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
END_FUNC comp_intern_cstr

;; ============================================================================
;; comp_intern_name(Comp *c, const char *s, int64_t len)
;;   -> rax = owned PyStrObject*, the identifier after private-name mangling
;;
;; An identifier of the form __spam written inside `class C` is _C__spam --
;; which is what keeps a base's private attribute from colliding with a
;; subclass's.  Nothing mangled at all here, so `self.__x` in A and in B named
;; the same slot.  CPython's rule: two leading underscores, not two trailing
;; ones, and a class name with its own leading underscores stripped off.
;; ============================================================================
CIN_COMP  equ 8
CIN_P     equ 16
CIN_LEN   equ 24
CIN_BUF   equ 56
DEF_FUNC comp_intern_name, 80
    push rbx
    push r12
    mov [rbp - CIN_COMP], rdi
    mov [rbp - CIN_P], rsi
    mov [rbp - CIN_LEN], rdx

    mov rax, [rdi + Comp.private]
    test rax, rax
    jz .plain
    cmp rdx, 2
    jl .plain
    cmp byte [rsi], '_'
    jne .plain
    cmp byte [rsi + 1], '_'
    jne .plain
    ; ...but not one that also ends in two underscores.  There is no length
    ; floor on that: `__` is two leading underscores AND two trailing ones,
    ; and CPython does not mangle it, nor `___`.  Skipping the check below
    ; four characters mangled both, so a class body's `__ = 2` was stored as
    ; `_C__` and `C.__` was an AttributeError.
    mov rcx, rdx
    cmp byte [rsi + rcx - 1], '_'
    jne .mangle_ok
    cmp byte [rsi + rcx - 2], '_'
    je .plain
.mangle_ok:
    ; Strip the class name's own leading underscores; an all-underscore class
    ; name mangles nothing.
    mov rbx, [rdi + Comp.private]
    lea rbx, [rbx + PyStrObject.data]
    mov rax, [rdi + Comp.private]
    mov r12, [rax + PyStrObject.ob_size]
.strip:
    test r12, r12
    jz .plain
    cmp byte [rbx], '_'
    jne .stripped
    inc rbx
    dec r12
    jmp .strip
.stripped:

    lea rdi, [rbp - CIN_BUF]
    mov esi, 1
    call buf_init
    lea rdi, [rbp - CIN_BUF]
    mov esi, '_'
    call buf_push_u8
.copy_cls:
    test r12, r12
    jz .copy_name
    lea rdi, [rbp - CIN_BUF]
    movzx esi, byte [rbx]
    call buf_push_u8
    inc rbx
    dec r12
    jmp .copy_cls
.copy_name:
    mov rbx, [rbp - CIN_P]
    mov r12, [rbp - CIN_LEN]
.copy_name_loop:
    test r12, r12
    jz .copy_done
    lea rdi, [rbp - CIN_BUF]
    movzx esi, byte [rbx]
    call buf_push_u8
    inc rbx
    dec r12
    jmp .copy_name_loop
.copy_done:
    mov rdi, [rbp - CIN_BUF + Buf.data]
    mov rsi, [rbp - CIN_BUF + Buf.len]
    call comp_intern_forced
    push rax
    lea rdi, [rbp - CIN_BUF]
    call buf_free
    pop rax
    pop r12
    pop rbx
    leave
    ret

.plain:
    mov rdi, [rbp - CIN_P]
    mov rsi, [rbp - CIN_LEN]
    call comp_intern_forced
    pop r12
    pop rbx
    leave
    ret
END_FUNC comp_intern_name

;; ============================================================================
;; comp_keep(Comp *c, Value v) -> rax = the same value, now arena-owned
;;
;; CompUnit.consts holds BORROWED references and asm_tuple_from_values takes
;; its own when it builds co_consts, so an owned object built for one constant
;; and handed to cg_const is simply leaked.  Handing it to the object arena
;; first is what gives it an owner -- comp_free releases the arena however the
;; compilation ended, which also covers the error paths that used to abandon
;; it.  Takes ownership of v.
;; ============================================================================
DEF_FUNC comp_keep, 16
    push rbx
    push r12
    mov rbx, rdi
    call ast_obj                        ; rsi already holds the value
    mov rdi, rbx
    mov rsi, rax
    call ast_obj_at
    pop r12
    pop rbx
    leave
    ret
END_FUNC comp_keep

;; ============================================================================
;; comp_intern_keep(Comp *c, const char *s, int64_t len)
;;   -> rax = a borrowed PyStrObject*
;;
;; comp_intern_cstr for a counted slice: the components of a dotted import
;; name.  Same reason it exists -- CompUnit.names holds BORROWED references,
;; so a string created and released at the call site leaves a dangling pointer
;; in co_names and the failure surfaces as a wild jump inside dict_lookup.
;; ============================================================================
DEF_FUNC comp_intern_keep, 16
    push rbx
    push r12
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    call comp_intern
    test rax, rax
    jz .ik_fail
    mov rdi, rbx
    mov rsi, rax
    call ast_obj
    mov rdi, rbx
    mov rsi, rax
    call ast_obj_at
    pop r12
    pop rbx
    leave
    ret
.ik_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC comp_intern_keep

;; ============================================================================
;; comp_empty_string(Comp *c) -> rax = a borrowed empty PyStrObject*
;; `from . import x` has no module name, but IMPORT_NAME still needs one.
;; ============================================================================
DEF_FUNC comp_empty_string, 8
    push rbx
    mov rbx, rdi
    lea rdi, [rel cs_empty]
    call str_from_cstr_heap
    mov rdi, rbx
    mov rsi, rax
    call ast_obj                        ; parked in comp.objs, so it is freed
    mov rdi, rbx
    mov rsi, rax
    call ast_obj_at
    pop rbx
    leave
    ret
END_FUNC comp_empty_string

section .rodata
cs_empty: db "", 0

cs_module_name: db "<module>", 0

section .text

;; ============================================================================
;; comp_lex_span(Comp *c, const char *start, const char *end, int lineno,
;;               const char *line_start)
;;   -> rax = the token index the span's tokens start at, or -1
;;
;; Appends a span's tokens to the array and hands back where they begin, so a
;; caller can point the parser's cursor at them.  The lexer state is saved and
;; restored around it: an f-string's field is lexed in the middle of a file
;; whose own indent stack and paren depth must survive.
;; ============================================================================
CLS_START equ 16
CLS_END   equ 24
CLS_LINE  equ 32
CLS_IDX   equ 40
CLS_BASE  equ 48          ; where the span's line begins, for its columns
CLS_SAVE  equ 56 + Lexer_size
CLS_FRAME equ ((CLS_SAVE + 15) / 16) * 16 + 8      ; + 1 push = 16-aligned
DEF_FUNC comp_lex_span, CLS_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - CLS_START], rsi
    mov [rbp - CLS_END], rdx
    mov [rbp - CLS_LINE], rcx
    mov [rbp - CLS_BASE], r8

    mov rax, [rbx + Comp.tokens + Buf.len]
    mov [rbp - CLS_IDX], rax

    lea rdi, [rbp - CLS_SAVE]
    lea rsi, [rbx + Comp.lex]
    mov edx, Lexer_size
    call ap_memcpy

    mov rdi, rbx
    mov rsi, [rbp - CLS_START]
    mov rdx, [rbp - CLS_END]
    mov rcx, [rbp - CLS_LINE]
    mov r8, [rbp - CLS_BASE]
    call lex_run
    push rax
    lea rdi, [rbx + Comp.lex]
    lea rsi, [rbp - CLS_SAVE]
    mov edx, Lexer_size
    call ap_memcpy
    pop rax
    test eax, eax
    jz .fail
    mov rax, [rbp - CLS_IDX]
    pop rbx
    leave
    ret
.fail:
    mov rax, -1
    pop rbx
    leave
    ret
END_FUNC comp_lex_span

;; ============================================================================
;; par_single_check(Comp *c, AstNode *root) -> rax = 1 ok, 0 with an error set
;;
;; CPython's `single` start symbol is `NEWLINE | simple_stmt | compound_stmt
;; NEWLINE`, and this ran the full module grammar and then relabelled the
;; root -- so it accepted three things CPython refuses, and the tree it built
;; for them was fine.  Nothing else here notices, which is why this is a
;; check rather than a second parser.
;;
;;   * nothing at all.  "" and "\n" and "# comment\n" are all a SyntaxError
;;     there, despite NEWLINE being one of the three alternatives.
;;   * more than one statement, which has a message of its own.
;;   * a compound statement whose last suite is on the same line as its
;;     header, without a trailing newline: `def f(): pass` is an error and
;;     `def f(): pass\n` is not, and so are `if 1: pass` and
;;     `if 1:\n pass\nelse: pass`, where the LAST line is the inline one.
;;     The tokenizer's NEWLINE is what CPython is really testing for; the
;;     readable equivalent is that the last non-blank line is indented, which
;;     is what an inline suite is not.
;; ============================================================================
PSC_COMP  equ 8
PSC_ROOT  equ 16
PSC_COMPOUND equ 24         ; is the FIRST statement a compound one?
PSC_FRAME equ 40            ; 24 used + 16 pad = 40, + 1 push = 16-aligned
DEF_FUNC_LOCAL par_single_check, PSC_FRAME
    push rbx
    mov [rbp - PSC_COMP], rdi
    mov [rbp - PSC_ROOT], rsi
    mov rbx, rsi                    ; the Interactive root
    mov qword [rbp - PSC_COMPOUND], 0

    mov ecx, [rbx + AstNode.nchild]
    test ecx, ecx
    jz .psc_empty

    ; Is the first statement a compound one?  Which of the two messages a
    ; second statement gets depends on it: CPython's grammar fails at the
    ; parse for `compound_stmt` followed by anything, and only reaches its
    ; "multiple statements" check for a simple one.
    mov rdi, [rbp - PSC_COMP]
    mov rsi, rbx
    xor edx, edx
    call ast_child
    mov rdi, [rbp - PSC_COMP]
    mov esi, eax
    call ast_at
    movzx ecx, byte [rax + AstNode.kind]
    cmp ecx, AST_IF
    je .psc_is_compound
    cmp ecx, AST_WHILE
    je .psc_is_compound
    cmp ecx, AST_FOR
    je .psc_is_compound
    cmp ecx, AST_TRY
    je .psc_is_compound
    cmp ecx, AST_WITH
    je .psc_is_compound
    cmp ecx, AST_FUNCTIONDEF
    je .psc_is_compound
    cmp ecx, AST_CLASSDEF
    je .psc_is_compound
    cmp ecx, AST_MATCH
    jne .psc_have_kind
.psc_is_compound:
    mov qword [rbp - PSC_COMPOUND], 1
.psc_have_kind:

    mov ecx, [rbx + AstNode.nchild]
    cmp ecx, 1
    jbe .psc_one

    ; More than one node is still ONE statement when they are the halves of a
    ; `;`-separated simple_stmt: `x=1; y=2` is a single statement to that
    ; grammar and two children to this parser.  What CPython refuses is a
    ; second LOGICAL line, so the test is whether they all start on one.
    mov r9d, ecx                    ; the count
    xor r10d, r10d                  ; i
    mov r11d, -1                    ; the first child's line
.psc_line_loop:
    cmp r10d, r9d
    jge .psc_ok
    push r9
    push r10
    push r11
    sub rsp, 8
    mov rdi, [rbp - PSC_COMP]
    mov rsi, rbx
    mov edx, r10d
    call ast_child
    mov rdi, [rbp - PSC_COMP]
    mov esi, eax
    call ast_at
    mov ecx, [rax + AstNode.lineno]
    add rsp, 8
    pop r11
    pop r10
    pop r9
    cmp r11d, -1
    jne .psc_line_cmp
    mov r11d, ecx
.psc_line_cmp:
    cmp r11d, ecx
    jne .psc_multiple
    inc r10d
    jmp .psc_line_loop

.psc_one:
    cmp qword [rbp - PSC_COMPOUND], 0
    je .psc_ok

    ; A trailing newline settles it.
    mov rdi, [rbp - PSC_COMP]
    mov rsi, [rdi + Comp.src]
    mov rcx, [rdi + Comp.srclen]
    test rcx, rcx
    jz .psc_empty
    cmp byte [rsi + rcx - 1], 10
    je .psc_ok
    ; Otherwise the last non-blank line has to be indented, which an inline
    ; suite is not: `if 1:\n pass` ends on an indented line and is legal,
    ; `if 1: pass` and `if 1:\n pass\nelse: pass` do not and are not.
.psc_back:
    dec rcx
    jz .psc_invalid                 ; the whole source is one line
    cmp byte [rsi + rcx - 1], 10
    jne .psc_back
    movzx eax, byte [rsi + rcx]
    cmp al, ' '
    je .psc_ok
    cmp al, 9                       ; tab
    je .psc_ok
    jmp .psc_invalid

.psc_ok:
    mov eax, 1
    pop rbx
    leave
    ret

.psc_multiple:
    cmp qword [rbp - PSC_COMPOUND], 0
    jne .psc_invalid
    mov rdi, [rbp - PSC_COMP]
    lea rsi, [rel exc_SyntaxError_type]
    CSTRING rdx, "multiple statements found while compiling a single statement"
    mov ecx, 1
    xor r8d, r8d
    call comp_error
    xor eax, eax
    pop rbx
    leave
    ret

.psc_empty:
.psc_invalid:
    mov rdi, [rbp - PSC_COMP]
    lea rsi, [rel exc_SyntaxError_type]
    CSTRING rdx, "invalid syntax"
    mov ecx, 1
    xor r8d, r8d
    call comp_error
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC par_single_check


;; ============================================================================
;; (was compiler/srcfile.asm)
;; ============================================================================

section .text

extern ap_free
extern ap_malloc
extern ap_strlen
extern obj_decref
extern pyc_read_file
extern str_from_cstr_heap
extern sys_close
extern sys_fstat
extern sys_open
extern sys_read

global code_from_path
global path_is_source
global src_read_file

STAT_SIZE    equ 144
PYC_MAGIC    equ 0x0a0d0dcb     ; 3531 and \r\n, as marshal.asm checks it
STAT_ST_SIZE equ 48

section .text

;; ============================================================================
;; path_is_source(const char *path) -> rax = 1 if it ends in ".py", else 0
;; ".pyc" ends in "yc", so the test is exact rather than a prefix match.
;; ============================================================================
DEF_FUNC_BARE path_is_source
    push rbx
    mov rbx, rdi
    call ap_strlen
    xor ecx, ecx
    cmp rax, 3
    jb .done
    cmp byte [rbx + rax - 3], '.'
    jne .done
    cmp byte [rbx + rax - 2], 'p'
    jne .done
    cmp byte [rbx + rax - 1], 'y'
    jne .done
    mov ecx, 1
.done:
    mov eax, ecx
    pop rbx
    ret
END_FUNC path_is_source

;; ============================================================================
;; src_read_file(const char *path, int64_t *out_len) -> rax = buffer, or 0
;; The whole file in one ap_malloc'd block, NUL-terminated.  The caller frees.
;; ============================================================================
SR_OUT   equ 16
SR_FD    equ 24
SR_SIZE  equ 32
SR_BUF   equ 40
SR_GOT   equ 48
SR_STAT  equ 56 + STAT_SIZE
SR_FRAME equ ((SR_STAT + 15) / 16) * 16 + 8      ; + 1 push = 16-aligned
DEF_FUNC src_read_file, SR_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - SR_OUT], rsi

    mov rdi, rbx
    xor esi, esi                        ; O_RDONLY
    xor edx, edx
    call sys_open
    test rax, rax
    js .fail
    mov [rbp - SR_FD], rax

    mov rdi, rax
    lea rsi, [rbp - SR_STAT]
    call sys_fstat
    test rax, rax
    js .close_fail
    mov rax, [rbp - SR_STAT + STAT_ST_SIZE]
    mov [rbp - SR_SIZE], rax

    ; One extra byte for the NUL, so an empty file still gets a valid buffer.
    lea rdi, [rax + 1]
    call ap_malloc
    test rax, rax
    jz .close_fail
    mov [rbp - SR_BUF], rax
    mov qword [rbp - SR_GOT], 0

.read_loop:
    mov rax, [rbp - SR_GOT]
    cmp rax, [rbp - SR_SIZE]
    jae .read_done
    mov rdi, [rbp - SR_FD]
    mov rsi, [rbp - SR_BUF]
    add rsi, rax
    mov rdx, [rbp - SR_SIZE]
    sub rdx, rax
    call sys_read
    test rax, rax
    jz .read_done
    cmp rax, -4                         ; -EINTR: interrupted, not finished
    je .read_loop
    js .read_error
    add [rbp - SR_GOT], rax
    jmp .read_loop
    ; A zero read is the real length: /proc and other synthetic files report a
    ; size of 0 from fstat and still have contents, and a file that shrank
    ; between the fstat and the read is not an error either.  A NEGATIVE one is
    ; not that -- folding EISDIR or EIO in here reported a directory as an
    ; empty module, and a failed read partway through as a truncated one.
.read_error:
    mov rdi, [rbp - SR_BUF]
    call ap_free
    jmp .close_fail

.read_done:
    mov rdi, [rbp - SR_FD]
    call sys_close
    mov rax, [rbp - SR_BUF]
    mov rcx, [rbp - SR_GOT]
    mov byte [rax + rcx], 0
    mov rdx, [rbp - SR_OUT]
    test rdx, rdx
    jz .no_out
    mov [rdx], rcx
.no_out:
    pop rbx
    leave
    ret

.close_fail:
    mov rdi, [rbp - SR_FD]
    call sys_close
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC src_read_file

;; ============================================================================
;; path_is_pyc(const char *path) -> eax = 1 when it is marshalled bytecode
;;
;; CPython's maybe_pyc_file: a ".pyc" name, or a file that opens with the
;; 3.12 magic number.  Anything else is source, whatever it is called -- a
;; script with no extension, like the bin/pip a venv installs, used to be
;; read as a .pyc and refused for its magic number.
;; ============================================================================
PIP_PATH  equ 8
PIP_FD    equ 16
PIP_BUF   equ 24
PIP_FRAME equ 32
DEF_FUNC path_is_pyc, PIP_FRAME
    mov [rbp - PIP_PATH], rdi
    call ap_strlen
    mov rcx, [rbp - PIP_PATH]
    cmp rax, 4
    jb .pip_probe
    cmp dword [rcx + rax - 4], '.pyc'
    je .pip_yes
.pip_probe:
    mov rdi, [rbp - PIP_PATH]
    xor esi, esi                    ; O_RDONLY
    xor edx, edx
    call sys_open
    test rax, rax
    js .pip_yes                     ; unopenable: pyc_read_file says so
    mov [rbp - PIP_FD], rax
    mov dword [rbp - PIP_BUF], 0
    mov rdi, rax
    lea rsi, [rbp - PIP_BUF]
    mov edx, 4
    call sys_read
    mov rdi, [rbp - PIP_FD]
    call sys_close
    cmp dword [rbp - PIP_BUF], PYC_MAGIC
    jne .pip_no
.pip_yes:
    mov eax, 1
    leave
    ret
.pip_no:
    xor eax, eax
    leave
    ret
END_FUNC path_is_pyc

;; ============================================================================
;; code_from_path(const char *path) -> rax = PyCodeObject*, or 0
;; A .py is compiled; anything else is read as marshalled bytecode.  A failed
;; compile leaves its exception pending, exactly as pyc_read_file's callers
;; already expect.
;; ============================================================================
CP_SRC   equ 16
CP_LEN   equ 24
CP_FILE  equ 32
CP_FRAME equ 40           ; + 1 push = 48
DEF_FUNC code_from_path, CP_FRAME
    push rbx
    mov rbx, rdi
    call path_is_source
    test eax, eax
    jnz .source
    mov rdi, rbx
    call path_is_pyc
    test eax, eax
    jz .source
    mov rdi, rbx
    call pyc_read_file
    pop rbx
    leave
    ret

.source:
    mov rdi, rbx
    lea rsi, [rbp - CP_LEN]
    call src_read_file
    test rax, rax
    jz .fail
    mov [rbp - CP_SRC], rax

    mov rdi, rbx
    call str_from_cstr_heap
    test rax, rax
    jz .free_src
    mov [rbp - CP_FILE], rax

    mov rdi, [rbp - CP_SRC]
    mov rsi, [rbp - CP_LEN]
    mov rdx, rax
    mov ecx, CMODE_EXEC
    call compile_source
    mov rbx, rax
    mov rdi, [rbp - CP_FILE]
    call obj_decref
    mov rdi, [rbp - CP_SRC]
    call ap_free
    mov rax, rbx
    pop rbx
    leave
    ret

.free_src:
    mov rdi, [rbp - CP_SRC]
    call ap_free
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC code_from_path

;; ============================================================================
;; (was compiler/evalexec.asm)
;; ============================================================================

section .text

extern builtins_dict_global
extern type_is_subtype
extern current_exception
extern dict_get
extern dict_set
extern dict_type
extern eval_frame
extern eval_saved_r12
extern frame_free
extern frame_new
extern obj_dealloc
extern obj_decref
extern none_singleton
extern obj_incref
extern raise_exception
extern str_from_cstr_heap
extern str_type
extern code_type
extern bytes_type

extern exc_TypeError_type
extern exc_ValueError_type

; --- Named frame-layout constants ---
EV_ARGS  equ 8
EV_NARGS equ 16
EV_CODE  equ 24
EV_GLOB  equ 32
EV_LOC   equ 40
EV_BLT   equ 48
EV_OWNLOC equ 56         ; a locals dict we materialised, ours to release
EV_FRAME equ 72          ; + 3 pushes = 96

section .bss
; Set by ev_resolve_ns when it had to build the locals mapping itself; the
; caller takes it from here and releases it.  Read immediately after the call,
; so a nested eval cannot race it.
ev_locals_owned: resq 1

section .text

;; ============================================================================
;; ev_resolve_ns(Comp-less) - shared globals/locals resolution
;;   rdi = args, rsi = nargs
;;   -> rax = globals, rdx = locals, or rax = 0 on a type error already raised
;;
;; Defaults follow CPython exactly:
;;   neither given  -> the calling frame's globals and locals
;;   globals only   -> locals = globals
;;   both given     -> used as they are
;; ============================================================================
NS_ARGS  equ 8
NS_NARGS equ 16
NS_GLOB  equ 24
NS_LOC   equ 32
NS_FRAME equ 40          ; + 1 push = 48
DEF_FUNC ev_resolve_ns, NS_FRAME
    push rbx
    mov qword [rel ev_locals_owned], 0
    mov [rbp - NS_ARGS], rdi
    mov [rbp - NS_NARGS], rsi
    mov qword [rbp - NS_GLOB], 0
    mov qword [rbp - NS_LOC], 0

    cmp rsi, 2
    jb .defaults
    mov rax, [rdi + 8]
    lea rcx, [rel none_singleton]       ; a pointer is its own Value
    cmp rax, rcx
    je .check_locals
    mov [rbp - NS_GLOB], rax
.check_locals:
    cmp qword [rbp - NS_NARGS], 3
    jb .defaults
    mov rdi, [rbp - NS_ARGS]
    mov rax, [rdi + 16]
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .defaults
    mov [rbp - NS_LOC], rax

.defaults:
    cmp qword [rbp - NS_GLOB], 0
    jne .have_globals
    ; Nothing supplied: fall back to the calling frame, the same source
    ; globals() and locals() use.
    mov rax, [rel eval_saved_r12]
    test rax, rax
    jz .no_frame
    mov rdx, [rax + PyFrame.globals]
    mov [rbp - NS_GLOB], rdx
    cmp qword [rbp - NS_LOC], 0
    jne .have_globals
    mov rdx, [rax + PyFrame.locals]
    test rdx, rdx
    jnz .use_frame_locals
    ; A function frame keeps its locals in the localsplus array rather than in
    ; a mapping, and substituting globals here is why eval("lv + 1") inside a
    ; function raised NameError for a name two words away, and why
    ; exec("out = ...") wrote to the module.  Materialise them instead.  The
    ; dict is ours; ev_locals_owned hands it to the caller to release.
    push rax
    mov rdi, rax
    extern frame_fast_to_locals
    call frame_fast_to_locals
    pop rcx
    test rax, rax
    jz .ftl_failed
    mov [rel ev_locals_owned], rax
    mov rdx, rax
    jmp .use_frame_locals
.ftl_failed:
    mov rdx, [rcx + PyFrame.globals]
.use_frame_locals:
    mov [rbp - NS_LOC], rdx
    jmp .have_globals

.have_globals:
    ; With globals given but no locals, the two are the same mapping.  This is
    ; the case eval(expr, ns) takes, and it is why names resolve against ns.
    cmp qword [rbp - NS_LOC], 0
    jne .check_type
    mov rax, [rbp - NS_GLOB]
    mov [rbp - NS_LOC], rax

.check_type:
    mov rax, [rbp - NS_GLOB]
    test rax, rax
    jz .no_frame
    ; PyDict_Check accepts a subclass, and an exact-type test rejected one --
    ; `exec(src, MyDict())` is ordinary Python.
    mov rdi, [rax + PyObject.ob_type]
    lea rsi, [rel dict_type]
    call type_is_subtype
    test eax, eax
    jz .globals_not_dict

    mov rax, [rbp - NS_GLOB]
    mov rdx, [rbp - NS_LOC]
    pop rbx
    leave
    ret

.globals_not_dict:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "globals must be a real dict"
    call raise_exception
.no_frame:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "eval must be given globals and locals when called without a frame"
    call raise_exception
END_FUNC ev_resolve_ns

;; ============================================================================
;; ev_inject_builtins(PyObject *globals) -> rax = the builtins mapping to use
;;
;; Only injected when absent -- a caller that provides its own __builtins__ is
;; making a deliberate choice about what the evaluated code can reach.  The
;; value that ends up there is also what the frame gets, so honouring it costs
;; nothing and is what makes a restricted namespace actually restricted.
;; ============================================================================
DEF_FUNC ev_inject_builtins, 16 ; + 2 pushes = 32
    push rbx
    push r12
    mov rbx, rdi
    lea rdi, [rel ev_builtins_name]
    call str_from_cstr_heap
    mov r12, rax

    mov rdi, rbx
    mov rsi, r12
    call dict_get
    test rax, rax
    jnz .present

    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rel builtins_dict_global]
    call dict_set
    mov rax, [rel builtins_dict_global]
.present:
    mov rbx, rax
    mov rdi, r12
    call obj_decref
    mov rax, rbx

    ; The frame's builtins slot has to be a dict; anything else falls back to
    ; the interpreter's own.  It holds whatever the caller put there, which
    ; may be an immediate -- reading ob_type off one dereferences the number.
    test rax, rax
    jz .fallback
    V_TEST_PTR rax, rdx
    ja .fallback
    mov rdx, [rax + PyObject.ob_type]
    lea rcx, [rel dict_type]
    cmp rdx, rcx
    je .done
.fallback:
    mov rax, [rel builtins_dict_global]
.done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC ev_inject_builtins

;; ============================================================================
;; ev_run_code(PyCodeObject *code, globals, locals, builtins) -> Value
;; The module-body pattern from src/import.asm: build a frame, run it, free it.
;; ============================================================================
RC_CODE  equ 8
RC_FRAME_P equ 16
RC_RET   equ 24
RC_FRAME equ 24          ; + 1 push = 32
DEF_FUNC ev_run_code, RC_FRAME
    push rbx
    mov [rbp - RC_CODE], rdi
    call frame_new                      ; (code, globals, builtins, locals)
    mov [rbp - RC_FRAME_P], rax
    mov rbx, rax

    mov rdi, rbx
    call eval_frame
    mov [rbp - RC_RET], rax

    mov rdi, rbx
    call frame_free

    mov rax, [rbp - RC_RET]
    pop rbx
    leave
    ret
END_FUNC ev_run_code

;; ============================================================================
;; comp_note_caller_future() -> nothing
;;
;; Seeds comp_inherit_future from the code object of the frame that called
;; compile(), exec() or eval().  CPython inherits the caller's __future__
;; flags into a nested compile unless dont_inherit says otherwise, so
;;
;;     from __future__ import annotations
;;     exec("def f(x: Missing): pass", ns)
;;
;; stores 'Missing' rather than raising NameError -- and without this the
;; two halves of one file disagreed about what an annotation is.
;; ============================================================================
DEF_FUNC_LOCAL comp_note_caller_future
    mov qword [rel comp_inherit_future], 0
    mov rax, [rel eval_saved_r12]
    test rax, rax
    jz .cncf_done
    mov rax, [rax + PyFrame.code]
    test rax, rax
    jz .cncf_done
    test dword [rax + PyCodeObject.co_flags], CO_FUTURE_ANNOTATIONS
    jz .cncf_done
    mov qword [rel comp_inherit_future], 1
.cncf_done:
    leave
    ret
END_FUNC comp_note_caller_future

;; ============================================================================
;; builtin_eval_fn(args, nargs) -> Value
;; ============================================================================
DEF_FUNC builtin_eval_fn, EV_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - EV_ARGS], rdi
    mov [rbp - EV_NARGS], rsi

    test rsi, rsi
    jz .bad_nargs
    cmp rsi, 3
    ja .bad_nargs

    call ev_resolve_ns
    mov [rbp - EV_GLOB], rax
    mov [rbp - EV_LOC], rdx
    mov rcx, [rel ev_locals_owned]
    mov [rbp - EV_OWNLOC], rcx

    mov rdi, rax
    call ev_inject_builtins
    mov [rbp - EV_BLT], rax

    mov rdi, [rbp - EV_ARGS]
    mov rbx, [rdi]                      ; the source argument
    ; V_TEST_PTR, not `test rbx, rbx`: a Value is one word and an int inside
    ; +-2^50 or any float is an IMMEDIATE with no ob_type to read.  The load
    ; below dereferenced the number, so eval(1) was a SIGSEGV rather than a
    ; TypeError.  The macro rejects NULL in the same compare.
    V_TEST_PTR rbx, rax
    ja .bad_source
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel code_type]
    cmp rax, rcx
    je .have_code
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .ev_bytes_src
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .bad_source

    ; eval() strips leading spaces and tabs from a source string -- and only
    ; those two, and only at the front.  That is why eval("  1+2") works while
    ; exec("  x=1") is an IndentationError.
    lea r12, [rbx + PyStrObject.data]
    mov r13, [rbx + PyStrObject.ob_size]
    jmp .strip
.ev_bytes_src:
    ; bytes is source too, and CPython says so: the text is read as UTF-8
    ; either way, and a bytes carries the same two fields at its own offsets.
    lea r12, [rbx + PyBytesObject.data]
    mov r13, [rbx + PyBytesObject.ob_size]
.strip:
    test r13, r13
    jz .stripped
    movzx eax, byte [r12]
    cmp al, ' '
    je .strip_one
    cmp al, 9
    jne .stripped
.strip_one:
    inc r12
    dec r13
    jmp .strip
.stripped:

    lea rdi, [rel ev_string_name]
    call str_from_cstr_heap
    mov [rbp - EV_CODE], rax            ; parked: the filename, "<string>"

    call comp_note_caller_future        ; PEP 563 is inherited; see the helper
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rbp - EV_CODE]
    mov ecx, CMODE_EVAL
    call compile_source
    mov r12, rax                        ; the code object, or 0
    mov rdi, [rbp - EV_CODE]
    call obj_decref                     ; the code object took its own reference
    test r12, r12
    jz .propagate
    mov [rbp - EV_CODE], r12
    jmp .run

.have_code:
    INCREF rbx
    mov [rbp - EV_CODE], rbx

.run:
    mov rdi, [rbp - EV_CODE]
    mov rsi, [rbp - EV_GLOB]
    mov rdx, [rbp - EV_BLT]
    mov rcx, [rbp - EV_LOC]
    call ev_run_code
    mov rbx, rax
    mov rdi, [rbp - EV_CODE]
    call obj_decref
    ; The locals mapping, if we built it rather than being handed one.
    mov rdi, [rbp - EV_OWNLOC]
    test rdi, rdi
    jz .ev_own_run
    mov qword [rbp - EV_OWNLOC], 0
    call obj_decref
.ev_own_run:
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    leave
    ret

.propagate:
    ; compile_source has already made the exception pending; a NULL Value is
    ; how a builtin reports that, and op_call unwinds from there.
    ; The locals mapping, if we built it rather than being handed one.
    mov rdi, [rbp - EV_OWNLOC]
    test rdi, rdi
    jz .ev_own_prop_0
    mov qword [rbp - EV_OWNLOC], 0
    call obj_decref
.ev_own_prop_0:
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret

.bad_nargs:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "eval() takes 1 to 3 arguments"
    call raise_exception
.bad_source:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "eval() arg 1 must be a string, bytes or code object"
    call raise_exception
END_FUNC builtin_eval_fn

;; ============================================================================
;; co_ast_builder() -> rax = _ast._from_raw, borrowed, or 0 with an exception
;;
;; Looked up lazily and cached for the life of the process, the way
;; builtin_open_fn caches _io.open.  It cannot be resolved at startup:
;; builtins are built before the import system can run, and _ast is an
;; ordinary module in lib/.
;; ============================================================================
section .data
co_from_raw: dq 0
section .rodata
co_ast_mod:  db "_ast", 0
co_ast_attr: db "_from_raw", 0
PYCF_ONLY_AST equ 0x400
PYCF_TYPE_COMMENTS equ 0x1000
section .text

CAB_KEY   equ 8             ; the name being looked up
CAB_MOD   equ 16            ; the _ast module, while its dict is read
CAB_FRAME equ 16            ; + 0 pushes = 16

DEF_FUNC_LOCAL co_ast_builder, CAB_FRAME
    mov rax, [rel co_from_raw]
    test rax, rax
    jnz .cab_out

    ; The import must not inherit this call's keywords; compile() has already
    ; consumed them, so there is nothing to park.
    lea rdi, [rel co_ast_mod]
    call str_from_cstr_heap
    mov [rbp - CAB_KEY], rax
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    extern import_module
    call import_module
    mov [rbp - CAB_MOD], rax
    mov rdi, [rbp - CAB_KEY]
    call obj_decref
    mov rax, [rbp - CAB_MOD]
    test rax, rax
    jz .cab_fail

    lea rdi, [rel co_ast_attr]
    call str_from_cstr_heap
    mov [rbp - CAB_KEY], rax
    mov rdi, [rbp - CAB_MOD]
    mov rdi, [rdi + PyModuleObject.mod_dict]
    mov rsi, rax
    call dict_get
    push rax
    mov rdi, [rbp - CAB_KEY]
    call obj_decref
    mov rdi, [rbp - CAB_MOD]
    call obj_decref             ; sys.modules keeps the module alive
    pop rax
    test rax, rax
    jz .cab_fail
    V_UNPACK rax, rdx
    cmp edx, TAG_PTR
    jne .cab_fail
    INCREF rax                  ; the cache holds it for the process's life --
                                ; sys.modules is not an owner anyone can rely
                                ; on, and import_fresh_module drops entries
    mov [rel co_from_raw], rax
.cab_out:
    leave
    ret

.cab_fail:
    xor eax, eax
    leave
    ret
END_FUNC co_ast_builder

; compile()'s parameter names, in signature order: builtin_compile_fn
; gathers its keywords against these.
section .rodata
co_kw_source:   db "source", 0
co_kw_filename: db "filename", 0
co_kw_mode:     db "mode", 0
co_kw_flags:    db "flags", 0
co_kw_inherit:  db "dont_inherit", 0
co_kw_optimize: db "optimize", 0
align 8
co_kw_names:
    dq co_kw_source, co_kw_filename, co_kw_mode, co_kw_flags, co_kw_inherit
    dq co_kw_optimize
CO_NSLOTS equ 6
section .text

;; ============================================================================
;; builtin_compile_fn(args, nargs) -> Value
;;   compile(source, filename, mode[, flags[, dont_inherit[, optimize]]])
;;
;; dont_inherit and optimize are accepted and ignored: there are no __future__
;; features to inherit here and no optimization levels to select.  flags is
;; read for one bit, PyCF_ONLY_AST, which is what ast.parse passes: with it
;; set the answer is the parse tree rather than a code object.
;;
;; A source that is neither str nor bytes may be an AST object, and
;; compile_ast_input in astload.asm is what compiles one.
;;
;; Every parameter may be passed by name, as CPython's are: ast.parse calls
;; compile(src, fn, mode, flags, _feature_version=n), and pytest's mark
;; expressions compile(tree, filename=..., mode="eval").  So the positional
;; arguments and the keywords are gathered into one six-slot array first, in
;; signature order, and everything below reads that.  A keyword not in the
;; signature -- _feature_version -- is ignored.  kw_names_pending is consumed
;; however this call ends, or it would name the next call's arguments.
;; ============================================================================

CO_ARGS  equ 8
CO_NARGS equ 16
CO_MODE  equ 24
CO_FLAGS equ 32
CO_NPOS  equ 40
CO_RAW   equ 48          ; the raw tree, while _ast._from_raw runs on it
CO_KWNAMES equ 56        ; the pending keyword names, while they are scanned
CO_KWI   equ 64
CO_SRC   equ 72          ; the source bytes, str or bytes: only the two
CO_SRCLEN equ 80         ;   fields differ, and the offsets differ with them
CO_KWJ   equ 88          ; which signature name a keyword is being tried at
CO_SLOTS equ 144         ; the six arguments, at -144 .. -104
CO_FRAME equ 152         ; + 3 pushes = 176, 16-byte aligned
DEF_FUNC builtin_compile_fn, CO_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - CO_ARGS], rdi
    mov [rbp - CO_NARGS], rsi
    mov qword [rbp - CO_FLAGS], 0
    xor eax, eax
.co_clear:
    mov qword [rbp - CO_SLOTS + rax*8], 0
    inc eax
    cmp eax, CO_NSLOTS
    jb .co_clear

    ; The keywords sit after the positional arguments and are named in order
    ; by kw_names_pending.
    mov [rbp - CO_NPOS], rsi
    mov qword [rbp - CO_KWNAMES], 0
    mov rax, [rel kw_names_pending]
    test rax, rax
    jz .co_positional
    mov qword [rel kw_names_pending], 0
    mov [rbp - CO_KWNAMES], rax
    mov rcx, [rax + PyTupleObject.ob_size]
    sub [rbp - CO_NPOS], rcx

.co_positional:
    mov rcx, [rbp - CO_NPOS]
    cmp rcx, CO_NSLOTS
    ja .bad_nargs
    mov rdx, [rbp - CO_ARGS]
    xor eax, eax
.co_copy_pos:
    cmp rax, rcx
    jae .co_keywords
    mov r8, [rdx + rax*8]
    mov [rbp - CO_SLOTS + rax*8], r8
    inc rax
    jmp .co_copy_pos

.co_keywords:
    ; Each keyword against each signature name.  The index lives in the frame
    ; because ap_strcmp is a call.
    cmp qword [rbp - CO_KWNAMES], 0
    je .co_have_args
    mov qword [rbp - CO_KWI], 0
.co_kw_loop:
    mov rax, [rbp - CO_KWNAMES]
    mov rcx, [rbp - CO_KWI]
    cmp rcx, [rax + PyTupleObject.ob_size]
    jge .co_have_args
    mov qword [rbp - CO_KWJ], 0
.co_kw_name:
    mov rax, [rbp - CO_KWNAMES]
    mov rcx, [rbp - CO_KWI]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdx, [rax + rcx*8]
    lea rdi, [rdx + PyStrObject.data]
    lea rax, [rel co_kw_names]
    mov rcx, [rbp - CO_KWJ]
    mov rsi, [rax + rcx*8]
    call ap_strcmp
    test eax, eax
    jz .co_kw_match
    inc qword [rbp - CO_KWJ]
    cmp qword [rbp - CO_KWJ], CO_NSLOTS
    jb .co_kw_name
    jmp .co_kw_next                     ; not compile()'s: ignored
.co_kw_match:
    mov rax, [rbp - CO_NPOS]
    add rax, [rbp - CO_KWI]
    mov rdx, [rbp - CO_ARGS]
    mov rax, [rdx + rax*8]
    mov rcx, [rbp - CO_KWJ]
    mov [rbp - CO_SLOTS + rcx*8], rax
.co_kw_next:
    inc qword [rbp - CO_KWI]
    jmp .co_kw_loop

.co_have_args:
    ; source, filename and mode are required.
    cmp qword [rbp - CO_SLOTS], 0
    je .bad_nargs
    cmp qword [rbp - CO_SLOTS + 8], 0
    je .bad_nargs
    cmp qword [rbp - CO_SLOTS + 16], 0
    je .bad_nargs

    ; flags, by position or by name.  obj_as_index can reach a heap integer
    ; and clobber every caller-saved register, which under INT_STRESS=1 is
    ; every value of eight or more -- so nothing is held in one across it.
    mov rdi, [rbp - CO_SLOTS + 24]
    test rdi, rdi
    jz .co_have_flags
    V_UNPACK rdi, rdx
    call obj_as_index
    mov [rbp - CO_FLAGS], rax
.co_have_flags:
    mov rbx, [rbp - CO_SLOTS]           ; source
    mov r12, [rbp - CO_SLOTS + 8]       ; filename
    mov r13, [rbp - CO_SLOTS + 16]      ; mode

    ; All three are Values, and an int or float immediate has no ob_type to
    ; read -- compile(1, "a", "exec") dereferenced the number.  V_TEST_PTR
    ; rejects NULL and both immediate kinds in one compare.
    V_TEST_PTR rbx, rax
    ja .bad_source
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .co_bytes_src
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .co_not_text
    lea rax, [rbx + PyStrObject.data]
    mov [rbp - CO_SRC], rax
    mov rax, [rbx + PyStrObject.ob_size]
    mov [rbp - CO_SRCLEN], rax
    jmp .co_have_src
.co_bytes_src:
    lea rax, [rbx + PyBytesObject.data]
    mov [rbp - CO_SRC], rax
    mov rax, [rbx + PyBytesObject.ob_size]
    mov [rbp - CO_SRCLEN], rax
    jmp .co_have_src
.co_not_text:
    ; Perhaps an AST object; compile_ast_input decides, once the filename and
    ; the mode have been checked as they are for text.  A str's or bytes'
    ; data pointer is never 0, so 0 marks this case.
    mov qword [rbp - CO_SRC], 0
.co_have_src:
    lea rcx, [rel str_type]
    V_TEST_PTR r12, rax
    ja .bad_filename
    mov rax, [r12 + PyObject.ob_type]
    cmp rax, rcx
    jne .bad_filename
    V_TEST_PTR r13, rax
    ja .bad_mode
    mov rax, [r13 + PyObject.ob_type]
    cmp rax, rcx
    jne .bad_mode

    ; "eval", "exec" or "single".  Interactive echo is not reproducible here --
    ; apython has no PRINT_EXPR -- so "single" compiles as "exec", and differs
    ; only in the AST root PyCF_ONLY_AST hands back.
    mov ecx, CMODE_EXEC
    cmp qword [r13 + PyStrObject.ob_size], 4
    jne .check_single
    mov eax, [r13 + PyStrObject.data]
    cmp eax, 'eval'
    je .mode_eval
    cmp eax, 'exec'
    je .have_mode
    jmp .unsupported_mode
.mode_eval:
    mov ecx, CMODE_EVAL
    jmp .have_mode
.check_single:
    cmp qword [r13 + PyStrObject.ob_size], 9
    jne .check_single6
    ; "func_type": `(int, str) -> bool`, the stub-file signature form.
    mov eax, [r13 + PyStrObject.data]
    cmp eax, 'func'
    jne .unsupported_mode
    mov eax, [r13 + PyStrObject.data + 5]
    cmp eax, 'type'
    jne .unsupported_mode
    mov ecx, CMODE_FUNC_TYPE
    jmp .have_mode
.check_single6:
    cmp qword [r13 + PyStrObject.ob_size], 6
    jne .unsupported_mode
    mov eax, [r13 + PyStrObject.data]
    cmp eax, 'sing'
    jne .unsupported_mode
    mov eax, [r13 + PyStrObject.data + 2]
    cmp eax, 'ngle'
    jne .unsupported_mode
    mov ecx, CMODE_SINGLE
.have_mode:
    mov [rbp - CO_MODE], rcx
    call comp_note_caller_future        ; PEP 563 is inherited; see the helper
    cmp qword [rbp - CO_SRC], 0
    jne .co_text
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, [rbp - CO_MODE]
    mov r8, [rbp - CO_FLAGS]
    extern compile_ast_input
    call compile_ast_input
    test rax, rax
    jz .propagate
    pop r13
    pop r12
    pop rbx
    leave
    ret
.co_text:
    mov rdi, [rbp - CO_SRC]
    mov rsi, [rbp - CO_SRCLEN]
    mov rdx, r12
    mov rcx, [rbp - CO_MODE]
    test qword [rbp - CO_FLAGS], PYCF_ONLY_AST
    jnz .co_only_ast
    call compile_source
    test rax, rax
    jz .propagate
    pop r13
    pop r12
    pop rbx
    leave
    ret

.propagate:
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret

.co_only_ast:
    ; The parse tree, not a code object.  _ast is imported here rather than at
    ; startup for the reason builtin_open_fn gives about _io: builtins are
    ; built before the import system can run.
    xor r8d, r8d
    test qword [rbp - CO_FLAGS], PYCF_TYPE_COMMENTS
    jz .co_no_tc
    mov r8d, 1
.co_no_tc:
    call compile_ast_raw
    test rax, rax
    jz .propagate
    push rax
    call co_ast_builder
    test rax, rax
    jz .co_no_builder
    mov rdi, rax
    pop rsi
    mov [rbp - CO_RAW], rsi
    lea rsi, [rbp - CO_RAW]
    mov edx, 1
    call obj_call_n
    push rax
    mov rdi, [rbp - CO_RAW]
    call obj_decref
    pop rax
    test rax, rax
    jz .propagate               ; a pointer is its own Value, as compile_source's
    pop r13                     ; code object is a few lines above
    pop r12
    pop rbx
    leave
    ret
.co_no_builder:
    pop rdi
    call obj_decref
    jmp .propagate

.bad_nargs:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "compile() takes 3 to 6 arguments"
    call raise_exception
.bad_source:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "compile() arg 1 must be a string, bytes or AST object"
    call raise_exception
.bad_filename:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "compile() arg 2 must be a string"
    call raise_exception
.bad_mode:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "compile() arg 3 must be a string"
    call raise_exception
.unsupported_mode:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "compile() mode must be 'exec', 'eval' or 'single'"
    call raise_exception
END_FUNC builtin_compile_fn

;; ============================================================================
;; builtin_exec_fn(args, nargs) -> Value
;;   exec(source[, globals[, locals]])
;;
;; The same namespace rules as eval, with two differences that matter: exec
;; does NOT strip leading whitespace from its source -- exec("  x=1") is an
;; IndentationError where eval("  1+1") is fine -- and it always returns None,
;; discarding whatever the module body's implicit return produced.
;; ============================================================================
DEF_FUNC builtin_exec_fn, EV_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - EV_ARGS], rdi
    mov [rbp - EV_NARGS], rsi

    test rsi, rsi
    jz .bad_nargs
    cmp rsi, 3
    ja .bad_nargs

    call ev_resolve_ns
    mov [rbp - EV_GLOB], rax
    mov [rbp - EV_LOC], rdx
    mov rcx, [rel ev_locals_owned]
    mov [rbp - EV_OWNLOC], rcx

    mov rdi, rax
    call ev_inject_builtins
    mov [rbp - EV_BLT], rax

    mov rdi, [rbp - EV_ARGS]
    mov rbx, [rdi]
    V_TEST_PTR rbx, rax                 ; an immediate has no ob_type; see eval
    ja .bad_source
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel code_type]
    cmp rax, rcx
    je .have_code
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .ex_bytes_src
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .bad_source
    lea r12, [rbx + PyStrObject.data]
    mov r13, [rbx + PyStrObject.ob_size]
    jmp .ex_have_src
.ex_bytes_src:
    lea r12, [rbx + PyBytesObject.data]
    mov r13, [rbx + PyBytesObject.ob_size]
.ex_have_src:

    lea rdi, [rel ev_string_name]
    call str_from_cstr_heap
    mov [rbp - EV_CODE], rax
    call comp_note_caller_future        ; PEP 563 is inherited; see the helper
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rbp - EV_CODE]
    mov ecx, CMODE_EXEC
    call compile_source
    mov r12, rax
    mov rdi, [rbp - EV_CODE]
    call obj_decref
    test r12, r12
    jz .propagate
    mov [rbp - EV_CODE], r12
    jmp .run

.have_code:
    INCREF rbx
    mov [rbp - EV_CODE], rbx

.run:
    mov rdi, [rbp - EV_CODE]
    mov rsi, [rbp - EV_GLOB]
    mov rdx, [rbp - EV_BLT]
    mov rcx, [rbp - EV_LOC]
    call ev_run_code
    mov rbx, rax
    mov rdi, [rbp - EV_CODE]
    call obj_decref
    ; The locals mapping, if we built it rather than being handed one.
    mov rdi, [rbp - EV_OWNLOC]
    test rdi, rdi
    jz .ev_own_run
    mov qword [rbp - EV_OWNLOC], 0
    call obj_decref
.ev_own_run:
    ; A NULL result means the body raised; propagate it rather than returning
    ; None over the top of a live exception.
    test rbx, rbx
    jz .propagate
    DECREF_V rbx, rcx                   ; the body's None; exec has no result
    RET_NONE
    pop r13
    pop r12
    pop rbx
    leave
    ret

.propagate:
    ; The locals mapping, if we built it rather than being handed one.
    mov rdi, [rbp - EV_OWNLOC]
    test rdi, rdi
    jz .ev_own_prop_2
    mov qword [rbp - EV_OWNLOC], 0
    call obj_decref
.ev_own_prop_2:
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret

.bad_nargs:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "exec() takes 1 to 3 arguments"
    call raise_exception
.bad_source:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "exec() arg 1 must be a string, bytes or code object"
    call raise_exception
END_FUNC builtin_exec_fn

section .rodata
ev_builtins_name: db "__builtins__", 0
ev_string_name:   db "<string>", 0

ASM_INIT
