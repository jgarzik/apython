; ast.asm - The AST, and the growable buffers it lives in
;
; A node is 32 bytes in a Buf, addressed by u32 index; the tree has no
; allocator of its own beyond that.  Buf and the bump Arena are here because
; the node representation is not separable from them -- ast.asm's entire
; extern list was buf_reserve, buf_push_u32 and buf_push_ptr.
;
; Nodes are fixed 32-byte records in a Buf, addressed by u32 index rather than
; by pointer.  The Buf is reallocated as it grows, so a pointer taken before a
; node is added is stale afterwards; an index never is.  Node 0 is reserved as
; the null node by comp_init, which lets a 0 field read as "absent" with no
; separate presence flag anywhere.
;
; Variable-arity children (call arguments, statement bodies, list elements) go
; in a second u32 array.  They cannot be appended to it directly, because
; nested constructs are under construction at the same time -- f(a, [b, c], d)
; has three lists open at once.  So they are staged on a LIFO pending stack and
; copied into place when the construct closes:
;
;     mark = ast_mark(c)
;     ... ast_push(c, child) for each ...
;     ast_commit(c, mark)      -> (offset, count) stored in .clist / .nchild
;
; Recursive descent always closes lists in the order it opened them, so LIFO is
; exactly right and the staging never needs a search.

%include "macros.inc"
%include "object.inc"
%include "compiler.inc"
extern par_peek
extern par_advance

; --- Named frame-layout constants ---
AM_KIND  equ 16
AM_SUB   equ 24
AM_LINE  equ 32
AM_A     equ 40
AM_B     equ 48
AM_FRAME equ 56          ; + 1 push = 64

section .text

;; ============================================================================
;; ast_at(Comp *c, uint32_t idx) -> AstNode*
;; Valid only until the next ast_make; recompute rather than cache.
;; ============================================================================
DEF_FUNC_BARE ast_at
    mov rax, [rdi + Comp.nodes + Buf.data]
    shl rsi, AST_SHIFT
    add rax, rsi
    ret
END_FUNC ast_at

;; ============================================================================
;; ast_span_from(rdi = Comp*, rsi = AstSpan*, edx = a token cursor) -- fill it
;; from the last real token before that cursor.
;; ============================================================================
DEF_FUNC_LOCAL ast_span_from
    mov eax, edx
    test eax, eax
    jz .ash_none
    mov rdx, [rdi + Comp.tokens + Buf.len]
    mov r8, [rdi + Comp.tokens + Buf.data]
.ash_back:
    dec eax
    js .ash_none
    cmp rax, rdx
    jae .ash_none
    mov rcx, rax
    shl rcx, TOKEN_SHIFT
    add rcx, r8
    ; NEWLINE, INDENT, DEDENT and the end marker are layout, not source text:
    ; a compound statement's last real token is the one before them, and
    ; taking the cursor's own predecessor put a `for`'s end on the line after
    ; the block.
    movzx r9d, word [rcx + Token.kind]
    cmp r9d, TOK_NEWLINE
    je .ash_back
    cmp r9d, TOK_INDENT
    je .ash_back
    cmp r9d, TOK_DEDENT
    je .ash_back
    cmp r9d, TOK_ENDMARKER
    je .ash_back
    ; A token is one line long, except when it is not: a triple-quoted string
    ; carries its START line and a length that runs past it, and adding that
    ; length to its column put every docstring's end on the wrong line at a
    ; column past the end of the file's longest line.  The newlines in the
    ; token's own text are what the end is measured from.
    mov eax, [rcx + Token.lineno]
    mov r9d, [rcx + Token.col]
    add r9d, [rcx + Token.len]      ; the one-line answer
    mov r10, [rcx + Token.start]
    mov r11d, [rcx + Token.len]
    test r11d, r11d
    jz .ash_have_end
    xor edx, edx                    ; index
.ash_scan:
    cmp edx, r11d
    jae .ash_have_end
    cmp byte [r10 + rdx], 10
    jne .ash_scan_next
    inc eax                         ; one more line
    mov r9d, r11d
    sub r9d, edx
    dec r9d                         ; bytes after this newline
.ash_scan_next:
    inc edx
    jmp .ash_scan
.ash_have_end:
    mov [rsi + AstSpan.end_lineno], eax
    mov [rsi + AstSpan.end_col], r9d
    leave
    ret
.ash_none:
    mov dword [rsi + AstSpan.end_lineno], -1
    mov dword [rsi + AstSpan.end_col], -1
    leave
    ret
END_FUNC ast_span_from

;; ast_span_here(rdi = Comp*, rsi = AstSpan*) -- the same, at the cursor now,
;; which is where the production that just finished ends.
DEF_FUNC_BARE ast_span_here
    mov edx, [rdi + Comp.tok_idx]
    jmp ast_span_from
END_FUNC ast_span_here

;; ============================================================================
;; ast_end_at(rdi = Comp*, esi = a node index, edx = a token cursor) -- move
;; that node's end back to where the cursor was.  For a node built after
;; something that is not part of it: a parameter's node is made once its
;; default has been parsed, and CPython's `arg` ends at the name.
;; ============================================================================
global ast_end_at
DEF_FUNC ast_end_at
    mov rax, [rdi + Comp.spans + Buf.len]
    cmp rsi, rax
    jae .aen_out
    mov rax, [rdi + Comp.spans + Buf.data]
    shl rsi, 3
    add rsi, rax
    call ast_span_from
.aen_out:
    leave
    ret
END_FUNC ast_end_at

;; ============================================================================
;; ast_end_here(rdi = Comp*, esi = a node index) -- move that node's end to
;; the cursor now.  For a node made before the last of its own parts was
;; parsed: a comprehension is built before its closing bracket is consumed,
;; and an AnnAssign before its value.
;; ============================================================================
global ast_end_here
DEF_FUNC_BARE ast_end_here
    mov edx, [rdi + Comp.tok_idx]
    jmp ast_end_at
END_FUNC ast_end_here

;; ============================================================================
;; ast_start_at(rdi = Comp*, esi = a node index, edx = a token index) -- move
;; that node's START to where that token is.  For a node built when its
;; operator was reached, whose production began earlier: CPython's position
;; for an infix expression is its first token, parentheses included.
;; ============================================================================
global ast_start_at
DEF_FUNC ast_start_at
    mov rax, [rdi + Comp.tokens + Buf.len]
    cmp rdx, rax
    jae .asa_out
    mov rax, [rdi + Comp.tokens + Buf.data]
    shl rdx, TOKEN_SHIFT
    add rdx, rax                ; the token
    mov rax, [rdi + Comp.nodes + Buf.len]
    cmp rsi, rax
    jae .asa_out
    mov rax, [rdi + Comp.nodes + Buf.data]
    shl rsi, AST_SHIFT
    add rsi, rax                ; the node
    mov eax, [rdx + Token.lineno]
    mov [rsi + AstNode.lineno], eax
    mov eax, [rdx + Token.col]
    mov [rsi + AstNode.col], eax
.asa_out:
    leave
    ret
END_FUNC ast_start_at

;; ============================================================================
;; ast_span_at(rdi = Comp*, esi = a node index) -> rax = AstSpan*, or 0
;; ============================================================================
global ast_span_at
DEF_FUNC_BARE ast_span_at
    mov rax, [rdi + Comp.spans + Buf.len]
    cmp rsi, rax
    jae .asa_none
    mov rax, [rdi + Comp.spans + Buf.data]
    lea rax, [rax + rsi*8]
    ret
.asa_none:
    xor eax, eax
    ret
END_FUNC ast_span_at

;; ============================================================================
;; ast_make(Comp *c, int kind, int subkind, uint64_t pos, uint32_t a,
;;          uint32_t b) -> rax = the new node's index
;;
;; `pos` is the line in its low half and the column in its high half; TOK_POS
;; packs one out of a Token.
;;
;; .c, .clist and .nchild are left zero; the few node kinds that use them fill
;; them in through ast_at once their children are known.
;; ============================================================================
DEF_FUNC ast_make, AM_FRAME
    push rbx
    mov [rbp - AM_KIND], rsi
    mov [rbp - AM_SUB], rdx
    mov [rbp - AM_LINE], rcx
    mov [rbp - AM_A], r8
    mov [rbp - AM_B], r9
    mov rbx, rdi

    lea rdi, [rbx + Comp.nodes]
    mov esi, 1
    call buf_reserve                    ; rax = AstNode*

    mov rdx, [rbp - AM_KIND]
    mov [rax + AstNode.kind], dl
    mov rdx, [rbp - AM_SUB]
    mov [rax + AstNode.subkind], dl
    mov word [rax + AstNode.flags], 0
    ; The line and the column arrive as one word -- line low, column high --
    ; because a seventh argument would be a stack argument at fifty-odd call
    ; sites.  TOK_POS packs it out of a Token.
    mov rdx, [rbp - AM_LINE]
    mov [rax + AstNode.lineno], edx
    shr rdx, 32
    mov [rax + AstNode.col], edx
    mov rdx, [rbp - AM_A]
    mov [rax + AstNode.a], edx
    mov rdx, [rbp - AM_B]
    mov [rax + AstNode.b], edx
    mov dword [rax + AstNode.c], 0
    mov dword [rax + AstNode.clist], 0
    mov dword [rax + AstNode.nchild], 0

    ; Where the node ENDS, in a Buf of its own indexed the same way.  There is
    ; no room in the 32-byte node and a wider one would break the shl 5 that
    ; addresses it, so the span rides alongside -- and because ast_make is the
    ; only thing that ever makes a node, the two cannot drift apart.
    ;
    ; A production calls ast_make once it has consumed its last token, so the
    ; end is tokens[tok_idx - 1] and no call site has to say so.  The few
    ; nodes built before or after the last of their own parts fix it with
    ; ast_end_here or ast_end_at.
    lea rdi, [rbx + Comp.spans]
    mov esi, 1
    call buf_reserve                    ; rax = AstSpan*
    mov rdi, rbx
    mov rsi, rax
    call ast_span_here
    ; And the type-parameter slot, zero until a def, class or alias fills it.
    lea rdi, [rbx + Comp.typeparams]
    xor esi, esi
    call buf_push_u32
    ; And the type-comment slot, likewise, so both stay parallel to .nodes.
    lea rdi, [rbx + Comp.typecomments]
    xor esi, esi
    call buf_push_u32

    ; The index is one less than the new length, since buf_reserve appended it.
    mov rax, [rbx + Comp.nodes + Buf.len]
    dec rax
    pop rbx
    leave
    ret
END_FUNC ast_make

;; ============================================================================
;; ast_mark(Comp *c) -> rax = the current height of the pending stack
;; ============================================================================
DEF_FUNC_BARE ast_mark
    mov rax, [rdi + Comp.pending + Buf.len]
    ret
END_FUNC ast_mark

;; ============================================================================
;; ast_push(Comp *c, uint32_t node)
;; ============================================================================
DEF_FUNC_BARE ast_push
    lea rdi, [rdi + Comp.pending]
    jmp buf_push_u32
END_FUNC ast_push

;; ============================================================================
;; ast_commit(Comp *c, uint64_t mark) -> rax = child-list offset, rdx = count
;;
;; Moves everything pushed since `mark` out of the pending stack and into the
;; child-list array, leaving the stack as it was.  An empty list commits to
;; offset 0 with count 0, which is indistinguishable from "no children" -- and
;; that is fine, because .nchild is what any reader consults.
;; ============================================================================
AC_MARK  equ 8
AC_OFF   equ 16
AC_CNT   equ 24
AC_FRAME equ 24          ; + 3 pushes = 48
DEF_FUNC ast_commit, AC_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov [rbp - AC_MARK], rsi

    mov r13, [rbx + Comp.pending + Buf.len]
    sub r13, rsi                        ; r13 = how many were staged
    jz .empty

    mov [rbp - AC_CNT], r13
    mov rax, [rbx + Comp.children + Buf.len]
    mov [rbp - AC_OFF], rax             ; the offset this list will live at

    lea rdi, [rbx + Comp.children]
    mov rsi, r13
    call buf_reserve
    mov r12, rax                        ; destination

    ; Source is read after the reserve, because growing children cannot move
    ; pending -- but reading it afterwards costs nothing and keeps the two
    ; buffers' lifetimes independent.
    mov rax, [rbp - AC_MARK]
    mov rsi, [rbx + Comp.pending + Buf.data]
    lea rsi, [rsi + rax*4]

    xor ecx, ecx
.copy:
    mov edx, [rsi + rcx*4]
    mov [r12 + rcx*4], edx
    inc rcx
    cmp rcx, r13
    jb .copy

    mov rax, [rbp - AC_MARK]
    mov [rbx + Comp.pending + Buf.len], rax     ; pop the staging area

    mov rax, [rbp - AC_OFF]
    mov rdx, [rbp - AC_CNT]
    pop r13
    pop r12
    pop rbx
    leave
    ret

.empty:
    mov [rbx + Comp.pending + Buf.len], rsi
    xor eax, eax
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC ast_commit

;; ============================================================================
;; ast_child(Comp *c, AstNode *n, uint64_t i) -> rax = the i'th child index
;; ============================================================================
DEF_FUNC_BARE ast_child
    mov eax, [rsi + AstNode.clist]
    add rax, rdx
    mov rdx, [rdi + Comp.children + Buf.data]
    mov eax, [rdx + rax*4]
    ret
END_FUNC ast_child

;; ============================================================================
;; ast_obj(Comp *c, Value v) -> rax = index into comp.objs
;;
;; Takes ownership.  A Value, not a pointer: an int inside +-2^50 and every
;; float are immediates rather than heap objects, and comp_free releases the
;; table with DECREF_V accordingly.
;;
;; Everything the front end allocates goes through here, so comp_free has one
;; loop that releases the lot however the compilation ended -- which is what
;; lets the parser abandon a deeply nested construct without unwinding
;; anything by hand.
;; ============================================================================
DEF_FUNC ast_obj, 8            ; the 8 pads the push to a 16-aligned rsp
    push rbx
    mov rbx, rdi
    lea rdi, [rbx + Comp.objs]
    call buf_push_ptr
    ; rawnames is indexed by the same number, so it grows here and nowhere
    ; else: a zero for every object, overwritten only by comp_name_obj for the
    ; identifiers mangling rewrote.
    lea rdi, [rbx + Comp.rawnames]
    xor esi, esi
    call buf_push_u32
    mov rax, [rbx + Comp.objs + Buf.len]
    dec rax
    pop rbx
    leave
    ret
END_FUNC ast_obj

;; ============================================================================
;; ast_set_typeparams(Comp *c, uint32_t node, uint32_t tp) -> nothing; hangs a
;; PEP 695 parameter list off a def, a class or a type alias
;; ============================================================================
global ast_set_typeparams
DEF_FUNC_BARE ast_set_typeparams
    mov rax, [rdi + Comp.typeparams + Buf.len]
    cmp rsi, rax
    jae .astp_out
    mov rax, [rdi + Comp.typeparams + Buf.data]
    mov [rax + rsi*4], edx
.astp_out:
    ret
END_FUNC ast_set_typeparams

;; ============================================================================
;; ast_take_typecomment(Comp *c, uint32_t node) -> nothing; if the parser is
;; looking at a TOK_TYPE_COMMENT, interns its text and hangs it off the node
;;
;; The comment sits where the tokenizer found it, which for `x = 1  # type:
;; int` is after the value and before the NEWLINE.  Every statement that can
;; carry one calls this at the point it has its node and has not yet consumed
;; the newline.
;; ============================================================================
ATC_NODE  equ 8
ATC_FRAME equ 16            ; + 1 push = 24... one word more to land right
global ast_take_typecomment
DEF_FUNC ast_take_typecomment, 24       ; + 1 push = 32, 16-aligned
    push rbx
    mov rbx, rdi
    mov [rbp - ATC_NODE], rsi
    cmp dword [rdi + Comp.want_tc], 0
    je .atc_none
    call ast_take_typeignore
    mov rdi, rbx

    call par_peek
    cmp word [rax + Token.kind], TOK_TYPE_COMMENT
    jne .atc_none

    push rax
    mov rdi, [rax + Token.start]
    mov esi, [rax + Token.len]
    extern str_new_heap
    call str_new_heap
    pop rcx
    test rax, rax
    jz .atc_none
    mov rdi, rbx
    mov rsi, rax
    call ast_obj                        ; the arena takes the reference
    mov rcx, [rbx + Comp.typecomments + Buf.len]
    cmp qword [rbp - ATC_NODE], rcx
    jae .atc_advance
    mov rcx, [rbx + Comp.typecomments + Buf.data]
    mov rdx, [rbp - ATC_NODE]
    mov [rcx + rdx*4], eax
.atc_advance:
    mov rdi, rbx
    call par_advance
.atc_none:
    pop rbx
    leave
    ret
END_FUNC ast_take_typecomment

;; ============================================================================
;; ast_typecomment_at(Comp *c, uint32_t node) -> rax = the obj index of that
;; node's `# type:` comment, or 0
;; ============================================================================
;; ============================================================================
;; ast_park_typecomment(Comp *c) -- take the type comment the parser is
;; looking at, if any, and hold it until a statement claims it
;;
;; A compound statement's comment comes after its colon, which is inside
;; par_suite -- long before the node exists.
;; ============================================================================
;; ============================================================================
;; ast_take_typeignore(Comp *c) -> nothing; records every `# type: ignore` the
;; parser is looking at on the module
;;
;; Not attached to any statement: CPython puts every one of them in
;; Module.type_ignores as TypeIgnore(lineno, tag), where the tag is whatever
;; followed the word -- "" for a bare ignore, "[misc]" for a coded one.
;; ============================================================================
ATI_LINE  equ 8
ATI_FRAME equ 24            ; + 1 push = 32, 16-aligned
global ast_take_typeignore
DEF_FUNC ast_take_typeignore, ATI_FRAME
    push rbx
    mov rbx, rdi
    cmp dword [rdi + Comp.want_tc], 0
    je .ati_done
.ati_loop:
    mov rdi, rbx
    call par_peek
    cmp word [rax + Token.kind], TOK_TYPE_IGNORE
    jne .ati_done
    mov ecx, [rax + Token.lineno]
    mov [rbp - ATI_LINE], rcx
    mov rdi, [rax + Token.start]
    mov esi, [rax + Token.len]
    call str_new_heap
    test rax, rax
    jz .ati_done
    mov rdi, rbx
    mov rsi, rax
    call ast_obj
    push rax
    lea rdi, [rbx + Comp.typeignores]
    mov esi, [rbp - ATI_LINE]
    call buf_push_u32
    pop rsi
    lea rdi, [rbx + Comp.typeignores]
    call buf_push_u32
    mov rdi, rbx
    call par_advance
    jmp .ati_loop
.ati_done:
    pop rbx
    leave
    ret
END_FUNC ast_take_typeignore

;; ============================================================================
;; ast_park_typecomment(Comp *c) -> nothing; the comment, if there was one, is
;; held on the Comp until a statement claims it
;;
;; A compound statement's comment comes after its colon, which is inside
;; par_suite -- long before the node exists.
;; ============================================================================
global ast_park_typecomment
DEF_FUNC ast_park_typecomment, 24       ; + 1 push = 32, 16-aligned
    push rbx
    mov rbx, rdi
    cmp dword [rdi + Comp.want_tc], 0
    je .apt_done
    call ast_take_typeignore
    mov rdi, rbx
    call par_peek
    cmp word [rax + Token.kind], TOK_TYPE_COMMENT
    jne .apt_done
    mov rdi, [rax + Token.start]
    mov esi, [rax + Token.len]
    call str_new_heap
    test rax, rax
    jz .apt_done
    mov rdi, rbx
    mov rsi, rax
    call ast_obj
    mov [rbx + Comp.pending_tc], eax
    mov rdi, rbx
    call par_advance
.apt_done:
    pop rbx
    leave
    ret
END_FUNC ast_park_typecomment

;; ============================================================================
;; ast_claim_typecomment(Comp *c, uint32_t node) -> nothing; moves the parked
;; comment, if there is one, onto this node
;; ============================================================================
global ast_claim_typecomment
DEF_FUNC_BARE ast_claim_typecomment
    mov eax, [rdi + Comp.pending_tc]
    test eax, eax
    jz .act_none
    mov dword [rdi + Comp.pending_tc], 0
    mov rcx, [rdi + Comp.typecomments + Buf.len]
    cmp rsi, rcx
    jae .act_none
    mov rcx, [rdi + Comp.typecomments + Buf.data]
    mov [rcx + rsi*4], eax
.act_none:
    ret
END_FUNC ast_claim_typecomment

;; ============================================================================
;; ast_typecomment_at(Comp *c, uint32_t node) -> rax = the obj index of that
;; node's `# type:` comment, or 0
;; ============================================================================
global ast_typecomment_at
DEF_FUNC_BARE ast_typecomment_at
    mov rax, [rdi + Comp.typecomments + Buf.len]
    cmp rsi, rax
    jae .atca_none
    mov rax, [rdi + Comp.typecomments + Buf.data]
    mov eax, [rax + rsi*4]
    ret
.atca_none:
    xor eax, eax
    ret
END_FUNC ast_typecomment_at

;; ============================================================================
;; ast_typeparams_at(Comp *c, uint32_t node) -> rax = the AST_TYPEPARAMS node
;; hung off it, or 0
;; ============================================================================
global ast_typeparams_at
DEF_FUNC_BARE ast_typeparams_at
    mov rax, [rdi + Comp.typeparams + Buf.len]
    cmp rsi, rax
    jae .atpa_none
    mov rax, [rdi + Comp.typeparams + Buf.data]
    mov eax, [rax + rsi*4]
    ret
.atpa_none:
    xor eax, eax
    ret
END_FUNC ast_typeparams_at

;; ============================================================================
;; ast_rawname_at(Comp *c, uint32_t idx) -> rax = the unmangled name index or 0
;; ============================================================================
global ast_rawname_at
DEF_FUNC_BARE ast_rawname_at
    mov rax, [rdi + Comp.rawnames + Buf.len]
    cmp rsi, rax
    jae .arn_none
    mov rax, [rdi + Comp.rawnames + Buf.data]
    mov eax, [rax + rsi*4]
    ret
.arn_none:
    xor eax, eax
    ret
END_FUNC ast_rawname_at

;; ============================================================================
;; ast_obj_at(Comp *c, uint32_t idx) -> rax = the borrowed Value, or 0 when
;;   the index is past the end
;;
;; BOUNDS-CHECKED, as ast_rawname_at above it is.  Object indices and node
;; indices come from different arenas and overlap freely, so a caller that
;; reads a NODE field as an object index -- which is the oldest bug pattern in
;; this compiler -- was a wild read here rather than a miss.  Every caller
;; already treats 0 as "not a name".
;; ============================================================================
DEF_FUNC_BARE ast_obj_at
    cmp rsi, [rdi + Comp.objs + Buf.len]
    jae .aoa_none
    mov rax, [rdi + Comp.objs + Buf.data]
    mov rax, [rax + rsi*8]
    ret
.aoa_none:
    xor eax, eax
    ret
END_FUNC ast_obj_at

;; ============================================================================
;; ast_set_ctx(Comp *c, uint32_t node, int ctx) -> rax = 1 ok, 0 not assignable
;;
;; Python parses an assignment target as an ordinary expression and only then
;; decides it was a target -- `a, b = t` and `a, b` are the same production
;; until the `=` appears.  This walks the parsed expression and re-marks it,
;; which is also where "cannot assign to a literal" is discovered: a node kind
;; with no store form simply fails here.
;;
;; Only the container kinds recurse: `[a, b] = t` and `(a, b) = t` both unpack,
;; while `f(x) = 1` does not, because a call has no store form.
;; ============================================================================
SC_CTX   equ 24
SC_I     equ 32
SC_N     equ 40
SC_FRAME equ 40          ; + 3 pushes = 64
DEF_FUNC ast_set_ctx, SC_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov [rbp - SC_CTX], rdx

    test r12, r12
    jz .bad
    mov rdi, rbx
    mov rsi, r12
    call ast_at
    mov r13, rax
    movzx eax, byte [r13 + AstNode.kind]

    cmp eax, AST_NAME
    je .simple
    cmp eax, AST_ATTRIBUTE
    je .simple
    cmp eax, AST_SUBSCRIPT
    je .simple
    cmp eax, AST_TUPLE
    je .container
    cmp eax, AST_LIST
    je .container
    cmp eax, AST_STARRED
    je .starred
    jmp .bad

.simple:
    mov rdx, [rbp - SC_CTX]
    mov [r13 + AstNode.subkind], dl
    mov eax, 1
    jmp .ret

.starred:
    mov rdx, [rbp - SC_CTX]
    mov [r13 + AstNode.subkind], dl
    mov edx, [r13 + AstNode.a]
    mov rdi, rbx
    mov rsi, rdx
    mov rdx, [rbp - SC_CTX]
    call ast_set_ctx
    jmp .ret

.container:
    mov rdx, [rbp - SC_CTX]
    mov [r13 + AstNode.subkind], dl
    mov ecx, [r13 + AstNode.nchild]
    mov [rbp - SC_N], rcx
    mov qword [rbp - SC_I], 0
.loop:
    mov rax, [rbp - SC_I]
    cmp rax, [rbp - SC_N]
    jae .ok
    mov rdi, rbx
    mov rsi, r12
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - SC_I]
    mov rdi, rbx
    call ast_child
    mov rsi, rax
    mov rdi, rbx
    mov rdx, [rbp - SC_CTX]
    call ast_set_ctx
    test eax, eax
    jz .bad
    inc qword [rbp - SC_I]
    jmp .loop
.ok:
    mov eax, 1
    jmp .ret
.bad:
    xor eax, eax
.ret:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC ast_set_ctx

;; ============================================================================
;; (was compiler/arena.asm)
;; ============================================================================

section .text

extern ap_malloc
extern ap_realloc
extern ap_free

; --- Named frame-layout constants ---

; buf_push_* save their two arguments across the buf_grow call: buf_grow
; clobbers rdi (it passes Buf.data to ap_realloc), and a bare push/pop pair
; would leave rsp misaligned for libc's SSE stores.
BP_BUF   equ 8
BP_VAL   equ 16
BP_FRAME equ 16             ; + 0 pushes = 16

section .text

;; ============================================================================
;; buf_init(Buf *b, size_t elsz)
;; Start empty with no allocation.  The first buf_reserve does the malloc, so
;; a Buf that is never written costs nothing.
;; ============================================================================
DEF_FUNC_BARE buf_init
    mov qword [rdi + Buf.data], 0
    mov qword [rdi + Buf.len], 0
    mov qword [rdi + Buf.cap], 0
    mov [rdi + Buf.elsz], rsi
    ret
END_FUNC buf_init

;; ============================================================================
;; buf_free(Buf *b)
;; Release the storage and reset to empty.  Does not touch element contents --
;; a Buf holding owned references must be drained by its owner first.
;; ============================================================================
DEF_FUNC buf_free, 8            ; the 8 pads to a 16-aligned rsp at the call
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + Buf.data]
    call ap_free
    mov qword [rbx + Buf.data], 0
    mov qword [rbx + Buf.len], 0
    mov qword [rbx + Buf.cap], 0
    pop rbx
    leave
    ret
END_FUNC buf_free

;; ============================================================================
;; buf_grow(Buf *b, size_t need)
;; Ensure capacity for at least `need` elements.  Doubles, with a floor of
;; BUF_MIN_CAP, so appending n elements costs O(n) copies total.
;; ============================================================================
DEF_FUNC buf_grow
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi                        ; r12 = needed capacity

    cmp r12, [rbx + Buf.cap]
    jbe .done                           ; already large enough

    mov rax, [rbx + Buf.cap]
    test rax, rax
    jnz .have_cap
    mov eax, BUF_MIN_CAP
.have_cap:
.double:
    cmp rax, r12
    jae .got_cap
    add rax, rax                        ; cap *= 2
    jmp .double
.got_cap:
    mov r12, rax                        ; r12 = new capacity

    mov rdi, [rbx + Buf.data]
    mov rsi, r12
    imul rsi, [rbx + Buf.elsz]
    call ap_realloc                      ; ap_realloc(NULL, n) == malloc(n)
    mov [rbx + Buf.data], rax
    mov [rbx + Buf.cap], r12

.done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC buf_grow

;; ============================================================================
;; buf_reserve(Buf *b, size_t n) -> void *first_new_element
;; Append n uninitialised elements and return a pointer to the first.  The
;; pointer is invalidated by the next reserve, so callers must not hold it
;; across one -- store an index instead.
;; ============================================================================
DEF_FUNC buf_reserve
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi

    mov rsi, [rbx + Buf.len]
    add rsi, r12
    call buf_grow                        ; rdi is still b here

    mov rax, [rbx + Buf.len]
    mov rdx, rax
    add rdx, r12
    mov [rbx + Buf.len], rdx             ; len += n

    imul rax, [rbx + Buf.elsz]
    add rax, [rbx + Buf.data]            ; &data[old_len]

    pop r12
    pop rbx
    leave
    ret
END_FUNC buf_reserve

;; ============================================================================
;; buf_push_u32(Buf *b, uint32_t v)
;; The child-list and label arenas are dense u32 arrays; this is their hot
;; path, so it inlines the capacity check rather than calling buf_reserve.
;; ============================================================================
DEF_FUNC buf_push_u32, BP_FRAME
    mov rax, [rdi + Buf.len]
    cmp rax, [rdi + Buf.cap]
    jb .fast
    mov [rbp - BP_BUF], rdi
    mov [rbp - BP_VAL], rsi
    lea rsi, [rax + 1]
    call buf_grow
    mov rdi, [rbp - BP_BUF]
    mov rsi, [rbp - BP_VAL]
    mov rax, [rdi + Buf.len]
.fast:
    mov rdx, [rdi + Buf.data]
    mov [rdx + rax*4], esi
    inc rax
    mov [rdi + Buf.len], rax
    leave
    ret
END_FUNC buf_push_u32

;; ============================================================================
;; buf_push_u8(Buf *b, uint8_t v)
;; Used by the bytecode, exception-table and line-table emitters.
;; ============================================================================
DEF_FUNC buf_push_u8, BP_FRAME
    mov rax, [rdi + Buf.len]
    cmp rax, [rdi + Buf.cap]
    jb .fast
    mov [rbp - BP_BUF], rdi
    mov [rbp - BP_VAL], rsi
    lea rsi, [rax + 1]
    call buf_grow
    mov rdi, [rbp - BP_BUF]
    mov rsi, [rbp - BP_VAL]
    mov rax, [rdi + Buf.len]
.fast:
    mov rdx, [rdi + Buf.data]
    mov [rdx + rax], sil
    inc rax
    mov [rdi + Buf.len], rax
    leave
    ret
END_FUNC buf_push_u8

;; ============================================================================
;; buf_push_ptr(Buf *b, void *v)
;; The object table (comp.objs) is a Buf of owned PyObject*.
;; ============================================================================
DEF_FUNC buf_push_ptr, BP_FRAME
    mov rax, [rdi + Buf.len]
    cmp rax, [rdi + Buf.cap]
    jb .fast
    mov [rbp - BP_BUF], rdi
    mov [rbp - BP_VAL], rsi
    lea rsi, [rax + 1]
    call buf_grow
    mov rdi, [rbp - BP_BUF]
    mov rsi, [rbp - BP_VAL]
    mov rax, [rdi + Buf.len]
.fast:
    mov rdx, [rdi + Buf.data]
    mov [rdx + rax*8], rsi
    inc rax
    mov [rdi + Buf.len], rax
    leave
    ret
END_FUNC buf_push_ptr

;; ============================================================================
;; arena_init(Arena *a)
;; ============================================================================
DEF_FUNC_BARE arena_init
    mov qword [rdi + Arena.cur], 0
    mov qword [rdi + Arena.end], 0
    mov qword [rdi + Arena.chunks], 0
    mov qword [rdi + Arena.total], 0
    ret
END_FUNC arena_init

;; ============================================================================
;; arena_alloc(Arena *a, size_t n) -> void *
;; Bump allocate, 8-byte aligned.  The fast path is five instructions; the slow
;; path links a fresh chunk, sized to whichever is larger of ARENA_CHUNK and
;; the request itself, so an oversized single allocation still works.
;; ============================================================================
DEF_FUNC arena_alloc, 8         ; lint: pushes=3 -- the slow path's, at .new_chunk
    add rsi, 7
    and rsi, -8                         ; round the request up to 8

    mov rax, [rdi + Arena.cur]
    lea rdx, [rax + rsi]
    cmp rdx, [rdi + Arena.end]
    ja .new_chunk
    mov [rdi + Arena.cur], rdx
    add [rdi + Arena.total], rsi
    leave
    ret

.new_chunk:
    push rbx
    push r12
    push r13
    mov rbx, rdi                        ; arena
    mov r12, rsi                        ; rounded request

    mov r13, ARENA_CHUNK
    lea rax, [r12 + 16]                 ; payload + link header
    cmp r13, rax
    jae .have_size
    mov r13, rax
.have_size:
    mov rdi, r13
    call ap_malloc
    ; chunk layout: [0]=next [8]=size [16..]=payload
    mov rdx, [rbx + Arena.chunks]
    mov [rax], rdx
    mov [rax + 8], r13
    mov [rbx + Arena.chunks], rax

    lea rdx, [rax + 16]                 ; payload start
    lea rcx, [rax + r13]                ; chunk end
    mov [rbx + Arena.end], rcx

    lea rcx, [rdx + r12]
    mov [rbx + Arena.cur], rcx
    add [rbx + Arena.total], r12
    mov rax, rdx                        ; return the payload start

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC arena_alloc

;; ============================================================================
;; arena_free(Arena *a)
;; Walk the chunk list and release everything.  This is the whole point of the
;; arena: one call disposes of every AST node and symbol the parse produced,
;; however the compilation ended.
;; ============================================================================
DEF_FUNC arena_free
    push rbx
    push r12
    mov rbx, rdi
    mov r12, [rbx + Arena.chunks]
.loop:
    test r12, r12
    jz .done
    mov rdi, r12
    mov r12, [r12]                      ; next, before the free
    call ap_free
    jmp .loop
.done:
    mov qword [rbx + Arena.cur], 0
    mov qword [rbx + Arena.end], 0
    mov qword [rbx + Arena.chunks], 0
    pop r12
    pop rbx
    leave
    ret
END_FUNC arena_free

ASM_INIT
