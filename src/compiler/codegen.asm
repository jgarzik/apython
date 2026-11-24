; codegen.asm - AST to instruction stream
;
; One emitter per node kind, reached through a jump table indexed by AST kind.
; Emitters never write a CACHE word or an EXTENDED_ARG prefix: both are
; synthesized by the assembler from the opcode metadata table, so "I forgot the
; caches on LOAD_ATTR" is not a mistake this file can make.
;
; The invariant every expression emitter keeps is that it leaves exactly one
; value on the stack.  The depth checker in assemble.asm verifies it.

%include "macros.inc"
%include "object.inc"
%include "value.inc"
%include "opcodes.inc"
%include "compiler.inc"

extern ast_at
extern ast_span_at
extern comp_keep
extern ast_child
extern ast_obj_at
extern buf_free
extern buf_init
extern buf_push_u32
extern buf_reserve
extern cg_store
extern cg_e_comprehension
extern cg_e_formattedvalue
extern cg_e_joinedstr
extern cg_e_await
extern cg_e_yield
extern cg_e_yieldfrom
extern cg_e_lambda
extern comp_intern_cstr
extern sym_at
extern sym_str_eq
extern cg_nameop
extern comp_error

extern ap_memcmp
extern none_singleton
extern tuple_new
extern exc_SyntaxError_type

; --- Named frame-layout constants ---
CE_NPTR  equ 32
CE_SLINE equ 40          ; cg_expr only: the caller's location, saved field by
CE_SEND  equ 44          ; field across the emitter it dispatches to
CE_SCOL  equ 48
CE_SECOL equ 52
CE_FRAME equ 56          ; + 3 pushes = 80

section .text

;; ============================================================================
;; cg_set_qualname(rdi = Comp, rsi = the new CompUnit, edx = its scope index)
;;
;; CPython's __qualname__: every enclosing scope's name, outermost first, each
;; followed by "." if that scope is a class body and ".<locals>." otherwise,
;; and then this unit's own name.  This compiler set it to the bare name, so a
;; method compiled from source reported "m" where the same file's .pyc
;; reported "C.m", and a nested function "i" rather than "o.<locals>.i".
;; enum, dataclasses and every traceback read it.
;;
;; The chain comes from the SCOPE tree, not from a parent unit pointer: units
;; are not linked to each other, and Comp.cur_unit is not maintained across
;; the nesting.  The result is handed to the object arena, because
;; CompUnit.qualname is a borrowed reference like the rest of them.
;; ============================================================================
SQ_COMP   equ 8
SQ_UNIT   equ 16
SQ_ACC    equ 24
SQ_DEPTH  equ 32
SQ_I      equ 40
SQ_CHAIN  equ 40 + 16 * 8   ; the enclosing scope indices, innermost first
SQ_FRAME  equ SQ_CHAIN      ; + 0 pushes, 16-aligned
SQ_MAX    equ 16
global cg_set_qualname
DEF_FUNC cg_set_qualname, SQ_FRAME
    mov [rbp - SQ_COMP], rdi
    mov [rbp - SQ_UNIT], rsi
    mov qword [rbp - SQ_DEPTH], 0

    ; Walk out to the module, collecting the scopes in between.
    mov esi, edx
.sq_walk:
    test esi, esi
    jz .sq_have_chain
    mov rdi, [rbp - SQ_COMP]
    extern sym_at
    call sym_at
    cmp dword [rax + Scope.kind], SCOPE_MODULE
    je .sq_have_chain
    mov esi, [rax + Scope.parent]       ; the NEXT one out
    test esi, esi
    jz .sq_have_chain
    mov rdi, [rbp - SQ_COMP]
    push rsi
    call sym_at
    pop rsi
    cmp dword [rax + Scope.kind], SCOPE_MODULE
    je .sq_have_chain
    ; PEP 695 wraps a `def f[T]` or a `class C[T]` in a hidden function scope
    ; that binds T.  It has no name, so it used to reach .sq_drop below and
    ; take the WHOLE chain with it -- `class TopG[T]: class Nested[U]` gave
    ; "Nested" where CPython gives "TopG.Nested", and every generic method
    ; lost its class.  It is not part of the qualname anywhere: CPython's
    ; compiler_set_qualname skips the same block.
    push rsi
    push rax
    mov esi, [rax + Scope.node]
    mov rdi, [rbp - SQ_COMP]
    extern ast_at
    call ast_at
    test rax, rax
    jz .sq_not_wrapper
    cmp byte [rax + AstNode.kind], AST_TYPEPARAMS
    jne .sq_not_wrapper
    pop rax
    pop rsi
    jmp .sq_walk                        ; skipped, and the walk goes on out
.sq_not_wrapper:
    pop rax
    pop rsi
    mov rcx, [rbp - SQ_DEPTH]
    cmp rcx, SQ_MAX
    jge .sq_have_chain                  ; deeper than any qualname anyone reads
    lea rdx, [rbp - SQ_CHAIN]
    mov [rdx + rcx*8], rsi
    inc qword [rbp - SQ_DEPTH]
    jmp .sq_walk

.sq_have_chain:
    cmp qword [rbp - SQ_DEPTH], 0
    je .sq_done                         ; directly inside the module

    ; Build outermost-first: name, separator, name, separator, ... own name.
    lea rdi, [rel cg_qn_empty]
    extern str_from_cstr_heap
    call str_from_cstr_heap
    mov [rbp - SQ_ACC], rax
    mov rcx, [rbp - SQ_DEPTH]
    mov [rbp - SQ_I], rcx

.sq_build:
    mov rcx, [rbp - SQ_I]
    test rcx, rcx
    jz .sq_own_name
    dec rcx
    mov [rbp - SQ_I], rcx
    lea rdx, [rbp - SQ_CHAIN]
    mov rsi, [rdx + rcx*8]
    mov rdi, [rbp - SQ_COMP]
    call sym_at
    mov rsi, [rax + Scope.name]
    test rsi, rsi
    jz .sq_drop                         ; unnamed: give up rather than guess
    push rax
    push rax
    mov rdi, [rbp - SQ_ACC]
    extern str_concat
    call str_concat           ; err: a scope's name is a str
    pop rcx
    pop rcx
    push rax
    mov rdi, [rbp - SQ_ACC]
    extern obj_decref
    call obj_decref
    pop rax
    mov [rbp - SQ_ACC], rax
    test rax, rax
    jz .sq_done

    ; The separator this scope contributes.
    lea rdx, [rbp - SQ_CHAIN]
    mov rcx, [rbp - SQ_I]
    mov rsi, [rdx + rcx*8]
    mov rdi, [rbp - SQ_COMP]
    call sym_at
    cmp dword [rax + Scope.kind], SCOPE_CLASS
    je .sq_dot
    lea rdi, [rel cg_qn_locals]
    jmp .sq_sep
.sq_dot:
    lea rdi, [rel cg_qn_dot]
.sq_sep:
    call str_from_cstr_heap
    push rax
    mov rdi, [rbp - SQ_ACC]
    mov rsi, rax
    call str_concat           ; err: both strs were built from C strings just above
    mov rcx, rax
    pop rdi
    push rcx
    call obj_decref
    mov rdi, [rbp - SQ_ACC]
    call obj_decref
    pop rax
    mov [rbp - SQ_ACC], rax
    test rax, rax
    jz .sq_done
    jmp .sq_build

.sq_own_name:
    mov rdi, [rbp - SQ_ACC]
    mov rdx, [rbp - SQ_UNIT]
    mov rsi, [rdx + CompUnit.name]
    call str_concat           ; err: a scope's name is a str
    push rax
    mov rdi, [rbp - SQ_ACC]
    call obj_decref
    pop rax
    test rax, rax
    jz .sq_done
    mov [rbp - SQ_ACC], rax

    ; The arena owns it; CompUnit.qualname borrows, like every other name.
    mov rdi, [rbp - SQ_COMP]
    mov rsi, rax
    extern comp_keep
    call comp_keep
    mov rax, [rbp - SQ_ACC]
    mov rdx, [rbp - SQ_UNIT]
    mov [rdx + CompUnit.qualname], rax
    leave
    ret

.sq_drop:
    mov rdi, [rbp - SQ_ACC]
    call obj_decref
.sq_done:
    leave
    ret
END_FUNC cg_set_qualname

;; ============================================================================
;; cg_unit_init(CompUnit *u, PyStrObject *filename, PyStrObject *name)
;; ============================================================================
CU_FILE  equ 16
CU_NAME  equ 24
CU_FRAME equ 24          ; + 1 push = 32
DEF_FUNC cg_unit_init, CU_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - CU_FILE], rsi
    mov [rbp - CU_NAME], rdx

    lea rdi, [rbx + CompUnit.instrs]
    mov esi, Instr_size
    call buf_init
    lea rdi, [rbx + CompUnit.loops]
    mov esi, LoopFrame_size
    call buf_init
    lea rdi, [rbx + CompUnit.handlers]
    mov esi, Handler_size
    call buf_init
    lea rdi, [rbx + CompUnit.finallys]
    mov esi, 8
    call buf_init
    mov dword [rbx + CompUnit.cur_handler], -1
    mov qword [rbx + CompUnit.comp], 0
    lea rdi, [rbx + CompUnit.labels]
    mov esi, 4
    call buf_init
    lea rdi, [rbx + CompUnit.consts]
    mov esi, 8
    call buf_init
    lea rdi, [rbx + CompUnit.names]
    mov esi, 8
    call buf_init
    lea rdi, [rbx + CompUnit.prefix]
    mov esi, 1
    call buf_init

    mov dword [rbx + CompUnit.flags], 0
    mov dword [rbx + CompUnit.argcount], 0
    mov dword [rbx + CompUnit.posonly], 0
    mov dword [rbx + CompUnit.kwonly], 0
    mov dword [rbx + CompUnit.nlocals], 0
    mov dword [rbx + CompUnit.stacksize], 0
    mov dword [rbx + CompUnit.firstline], 1
    mov dword [rbx + CompUnit.curline], 0
    mov dword [rbx + CompUnit.curend], 0
    mov dword [rbx + CompUnit.curcol], -1
    mov dword [rbx + CompUnit.curendcol], -1
    ; And the four beside them, which nothing set.  cg_emit only writes these
    ; when it emits an instruction that HAS a line, so a unit that reaches its
    ; implicit `return None` without emitting one -- an empty module, a module
    ; that is only a comment, an empty function body -- read whatever was on
    ; the stack and put it in the line table.  "no location" is the same pair
    ; of defaults the cur* fields get.
    mov dword [rbx + CompUnit.lastline], 0
    mov dword [rbx + CompUnit.lastend], 0
    mov dword [rbx + CompUnit.lastcol], -1
    mov dword [rbx + CompUnit.lastendcol], -1
    mov rax, [rbp - CU_FILE]
    mov [rbx + CompUnit.filename], rax
    mov rax, [rbp - CU_NAME]
    mov [rbx + CompUnit.name], rax
    mov [rbx + CompUnit.qualname], rax

    pop rbx
    leave
    ret
END_FUNC cg_unit_init

;; ============================================================================
;; cg_unit_free(CompUnit *u)
;; The consts and names arrays hold borrowed references -- comp.objs owns every
;; literal -- so there is nothing to release beyond the storage itself.
;; ============================================================================
DEF_FUNC cg_unit_free, 8
    push rbx
    mov rbx, rdi
    lea rdi, [rbx + CompUnit.prefix]
    call buf_free
    lea rdi, [rbx + CompUnit.names]
    call buf_free
    lea rdi, [rbx + CompUnit.consts]
    call buf_free
    lea rdi, [rbx + CompUnit.labels]
    call buf_free
    lea rdi, [rbx + CompUnit.finallys]
    call buf_free
    lea rdi, [rbx + CompUnit.handlers]
    call buf_free
    lea rdi, [rbx + CompUnit.loops]
    call buf_free
    lea rdi, [rbx + CompUnit.instrs]
    call buf_free
    pop rbx
    leave
    ret
END_FUNC cg_unit_free

;; ============================================================================
;; cg_emit(CompUnit *u, int opcode, uint32_t oparg, int lineno) -> Instr*
;; ============================================================================
CM_OP    equ 16
CM_ARG   equ 24
CM_LINE  equ 32
CM_FRAME equ 40          ; + 1 push = 48
DEF_FUNC cg_emit, CM_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - CM_OP], rsi
    mov [rbp - CM_ARG], rdx
    mov [rbp - CM_LINE], rcx

    lea rdi, [rbx + CompUnit.instrs]
    mov esi, 1
    call buf_reserve

    mov rdx, [rbp - CM_OP]
    mov [rax + Instr.opcode], dl
    mov byte [rax + Instr.flags], 0
    ; Stamp the innermost active handler, biased by one so 0 means "none".
    mov edx, [rbx + CompUnit.cur_handler]
    inc edx
    mov [rax + Instr.handler], dx
    mov rdx, [rbp - CM_ARG]
    mov [rax + Instr.oparg], edx
    mov rdx, [rbp - CM_LINE]
    mov [rax + Instr.line], edx
    ; Where the code actually got to, for the emitters that run after
    ; cg_stmt has restored .curline to the enclosing statement's.
    test edx, edx
    jz .cm_no_line
    mov [rbx + CompUnit.lastline], edx
    ; The columns go with it, cleared here and filled in below when this
    ; instruction turns out to carry any.
    mov dword [rbx + CompUnit.lastcol], -1
    mov dword [rbx + CompUnit.lastendcol], -1
    mov [rbx + CompUnit.lastend], edx
.cm_no_line:
    mov dword [rax + Instr.offset], 0

    ; The columns come from the location the dispatcher set, and only when the
    ; caller is emitting for that same line.  An emitter that attributes an
    ; instruction to some other line -- a loop's jump back, a prologue, the
    ; sites that pass 0 for "no line" -- would otherwise pair one node's line
    ; with another node's columns, which reads as a caret under the wrong text.
    mov dword [rax + Instr.end_line], 0
    mov dword [rax + Instr.col], -1
    mov dword [rax + Instr.end_col], -1
    mov dword [rax + Instr.pad], 0
    test edx, edx
    jz .cm_done
    cmp edx, [rbx + CompUnit.curline]
    jne .cm_done
    mov ecx, [rbx + CompUnit.curcol]
    test ecx, ecx
    jl .cm_done
    mov [rax + Instr.col], ecx
    mov [rbx + CompUnit.lastcol], ecx
    mov ecx, [rbx + CompUnit.curendcol]
    mov [rax + Instr.end_col], ecx
    mov [rbx + CompUnit.lastendcol], ecx
    mov ecx, [rbx + CompUnit.curend]
    mov [rax + Instr.end_line], ecx
    mov [rbx + CompUnit.lastend], ecx
.cm_done:

    pop rbx
    leave
    ret
END_FUNC cg_emit

;; ============================================================================
;; cg_const(CompUnit *u, Value v) -> rax = index into co_consts
;;
;; Deduplicates on the raw Value word.  That is exactly conservative: identical
;; words are the same object or the same immediate, so nothing is merged that
;; must stay distinct -- notably 1 and 1.0 and True, whose encodings differ,
;; and 0.0 and -0.0, whose bit patterns do.  Two equal heap constants stay
;; separate, which costs a slot and is never wrong.
;; ============================================================================
DEF_FUNC cg_const, 8
    push rbx
    mov rbx, rdi
    mov rdx, [rbx + CompUnit.consts + Buf.data]
    mov rcx, [rbx + CompUnit.consts + Buf.len]
    xor eax, eax
.scan:
    cmp rax, rcx
    jae .append
    cmp [rdx + rax*8], rsi
    je .found
    inc rax
    jmp .scan
.append:
    lea rdi, [rbx + CompUnit.consts]
    call buf_push_ptr_local
    mov rax, [rbx + CompUnit.consts + Buf.len]
    dec rax
.found:
    pop rbx
    leave
    ret
END_FUNC cg_const

;; ============================================================================
;; cg_name(CompUnit *u, PyStrObject *s) -> rax = index into co_names
;;
;; Names must deduplicate by text, not by identity: the same identifier is
;; interned into a fresh object at each occurrence, and without this co_names
;; would grow one entry per mention.
;; ============================================================================
CN_STR   equ 16
CN_I     equ 24
CN_FRAME equ 24          ; + 3 pushes = 48
DEF_FUNC cg_name, CN_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov [rbp - CN_STR], rsi
    mov r12, [rbx + CompUnit.names + Buf.len]
    xor r13d, r13d
.scan:
    cmp r13, r12
    jae .append
    mov rax, [rbx + CompUnit.names + Buf.data]
    mov rdi, [rax + r13*8]
    mov rsi, [rbp - CN_STR]
    mov rdx, [rdi + PyStrObject.ob_size]
    cmp rdx, [rsi + PyStrObject.ob_size]
    jne .next
    lea rdi, [rdi + PyStrObject.data]
    lea rsi, [rsi + PyStrObject.data]
    mov [rbp - CN_I], r13
    call ap_memcmp
    mov r13, [rbp - CN_I]
    test eax, eax
    jz .found
.next:
    inc r13
    jmp .scan
.append:
    lea rdi, [rbx + CompUnit.names]
    mov rsi, [rbp - CN_STR]
    call buf_push_ptr_local
    mov r13, [rbx + CompUnit.names + Buf.len]
    dec r13
.found:
    mov rax, r13
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_name

;; ============================================================================
;; buf_push_ptr_local(Buf *b, uint64_t v)
;; A local alias so this file does not pull in the whole arena interface just
;; for one append.
;; ============================================================================
DEF_FUNC_BARE buf_push_ptr_local
    extern buf_push_ptr
    jmp buf_push_ptr
END_FUNC buf_push_ptr_local

;; ============================================================================
;; cg_label_new(CompUnit *u) -> rax = label id
;; A label names the position before the next instruction emitted, which makes
;; forward references the natural case: create it, jump to it, bind it later.
;; ============================================================================
DEF_FUNC cg_label_new, 8
    push rbx
    mov rbx, rdi
    lea rdi, [rbx + CompUnit.labels]
    mov esi, -1                          ; unbound
    call buf_push_u32
    mov rax, [rbx + CompUnit.labels + Buf.len]
    dec rax
    pop rbx
    leave
    ret
END_FUNC cg_label_new

;; ============================================================================
;; cg_label_bind(CompUnit *u, uint64_t label)
;; ============================================================================
DEF_FUNC_BARE cg_label_bind
    mov rax, [rdi + CompUnit.labels + Buf.data]
    mov rdx, [rdi + CompUnit.instrs + Buf.len]
    mov [rax + rsi*4], edx
    ret
END_FUNC cg_label_bind

;; ============================================================================
;; cg_emit_jump(CompUnit *u, int opcode, uint64_t label, int lineno)
;; Records the label id in the oparg; the assembler turns it into a delta once
;; every instruction's size is known.
;; ============================================================================
CJ_FRAME equ 24          ; + 1 push = 32
DEF_FUNC cg_emit_jump, CJ_FRAME
    push rbx
    mov rbx, rsi
    call cg_emit                        ; rdi/rsi/rdx/rcx already in place
    mov byte [rax + Instr.flags], IF_LABELARG | IF_JREL_FWD
    ; An unconditional jump ends the fallthrough edge; the depth pass needs to
    ; know that or it propagates a bogus depth into whatever follows.
    cmp rbx, OP_JUMP_FORWARD
    jne .done
    or byte [rax + Instr.flags], IF_NOFALL
.done:
    pop rbx
    leave
    ret
END_FUNC cg_emit_jump

;; ============================================================================
;; cg_emit_jump_back(CompUnit *u, int opcode, uint64_t label, int lineno)
;; A backward jump.  The delta is measured the other way round, so the flag
;; matters: with IF_JREL_FWD the assembler would compute a negative delta and
;; the fixpoint's sanity check would reject it.
;; ============================================================================
DEF_FUNC cg_emit_jump_back, CJ_FRAME
    push rbx
    mov rbx, rsi
    call cg_emit
    mov byte [rax + Instr.flags], IF_LABELARG | IF_JREL_BACK
    cmp rbx, OP_JUMP_BACKWARD
    jne .done
    or byte [rax + Instr.flags], IF_NOFALL
.done:
    pop rbx
    leave
    ret
END_FUNC cg_emit_jump_back

;; ============================================================================
;; cg_loop_push(CompUnit *u, uint64_t brk, uint64_t cont, uint64_t npop)
;; cg_loop_pop(CompUnit *u)
;; cg_loop_top(CompUnit *u) -> rax = LoopFrame*, or 0 outside any loop
;; ============================================================================
CLP_CONT  equ 8              ; continue target, across buf_reserve
CLP_NPOP  equ 16             ; pops needed to leave the loop
DEF_FUNC cg_loop_push, 16
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov [rbp - CLP_CONT], rdx
    mov [rbp - CLP_NPOP], rcx
    lea rdi, [rbx + CompUnit.loops]
    mov esi, 1
    call buf_reserve
    mov [rax + LoopFrame.brk], r12d
    mov rdx, [rbp - CLP_CONT]
    mov [rax + LoopFrame.cont], edx
    mov rdx, [rbp - CLP_NPOP]
    mov [rax + LoopFrame.npop], edx
    mov edx, [rbx + CompUnit.finallys + Buf.len]
    mov [rax + LoopFrame.fdepth], edx
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_loop_push

DEF_FUNC_BARE cg_loop_pop
    dec qword [rdi + CompUnit.loops + Buf.len]
    ret
END_FUNC cg_loop_pop

DEF_FUNC_BARE cg_loop_top
    mov rax, [rdi + CompUnit.loops + Buf.len]
    test rax, rax
    jz .none
    dec rax
    shl rax, 4                          ; sizeof(LoopFrame)
    add rax, [rdi + CompUnit.loops + Buf.data]
    ret
.none:
    xor eax, eax
    ret
END_FUNC cg_loop_top

;; ============================================================================
;; cg_push_handler(CompUnit *u, uint64_t target, uint64_t lasti)
;; cg_pop_handler(CompUnit *u)
;; Everything emitted between the two is covered by this handler.
;; ============================================================================
CPH_HANDLER equ 8            ; handler target, across buf_reserve
DEF_FUNC cg_push_handler, 16
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov [rbp - CPH_HANDLER], rdx
    lea rdi, [rbx + CompUnit.handlers]
    mov esi, 1
    call buf_reserve
    mov [rax + Handler.target], r12d
    mov rdx, [rbp - CPH_HANDLER]
    mov [rax + Handler.lasti], edx
    mov dword [rax + Handler.depth], -1
    mov edx, [rbx + CompUnit.cur_handler]
    mov [rax + Handler.parent], edx
    ; Where the region opens, rather than where its stamp first appears.  A
    ; cleanup block emitted later carries the ENCLOSING handler's stamp and
    ; runs at a different depth, so scanning for the first stamped instruction
    ; would read that block's depth instead of the body's -- and if the body
    ; always raises, the first stamped instruction is unreachable dead code.
    mov edx, [rbx + CompUnit.instrs + Buf.len]
    mov [rax + Handler.open], edx
    mov dword [rax + Handler.bias], 0
    mov rax, [rbx + CompUnit.handlers + Buf.len]
    dec rax
    mov [rbx + CompUnit.cur_handler], eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_push_handler

DEF_FUNC_BARE cg_pop_handler
    mov eax, [rdi + CompUnit.cur_handler]
    cmp eax, -1
    je .none
    mov rdx, [rdi + CompUnit.handlers + Buf.data]
    imul rax, rax, Handler_size
    mov eax, [rdx + rax + Handler.parent]
    mov [rdi + CompUnit.cur_handler], eax
.none:
    ret
END_FUNC cg_pop_handler

;; ============================================================================
;; ============================================================================
;; cg_e_namedexpr(Comp *c, CompUnit *u, uint32_t node) -> 1 ok, 0 error
;;
;;     <value>; COPY 1; <store name>
;;
;; The walrus is an expression whose value is what it assigned, so the value is
;; duplicated rather than stored and reloaded -- `if (n := f()) > 5` must call
;; f once.
;; ============================================================================
CNE_LINE  equ 32
CNE_FRAME equ 40          ; + 3 pushes = 64
DEF_FUNC_LOCAL cg_e_namedexpr, CNE_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov ecx, [rax + AstNode.lineno]
    mov [rbp - CNE_LINE], rcx
    mov edx, [rax + AstNode.b]          ; the value
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail

    mov rdi, r12
    mov esi, OP_COPY
    mov edx, 1
    mov rcx, [rbp - CNE_LINE]
    call cg_emit

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov edx, [rax + AstNode.a]          ; the target name
    mov rdi, rbx
    mov rsi, r12
    call cg_store
    jmp .ret
.fail:
    xor eax, eax
.ret:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_e_namedexpr

;; ============================================================================
;; cg_cmpop(CompUnit *u, int cmpop, int lineno) -> emits one comparison
;;
;; Only the six ordering comparisons are COMPARE_OP.  `is` and `in` are
;; separate opcodes, which is why the compiler's comparison enum is wider than
;; CPython's CMP_* codes.
;;
;; COMPARE_OP's oparg is (index << 4) | mask.  apython ignores the low nibble
;; (op_compare_op does `shr ecx, 4`), but CPython's exact values are emitted so
;; that disassembling our output against CPython's stays a clean diff.
;; ============================================================================
CC_OP    equ 16
CC_LINE  equ 24
CC_FRAME equ 24          ; + 1 push = 32
DEF_FUNC cg_cmpop, CC_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - CC_OP], rsi
    mov [rbp - CC_LINE], rdx

    cmp rsi, CMPOP_GE
    ja .not_compare
    lea rax, [rel cmp_oparg_table]
    movzx edx, byte [rax + rsi]
    mov rdi, rbx
    mov esi, OP_COMPARE_OP
    mov rcx, [rbp - CC_LINE]
    call cg_emit
    jmp .done

.not_compare:
    cmp rsi, CMPOP_NOTIN
    ja .identity
    ; CMPOP_IN -> CONTAINS_OP 0, CMPOP_NOTIN -> CONTAINS_OP 1
    mov rdx, rsi
    sub rdx, CMPOP_IN
    mov rdi, rbx
    mov esi, OP_CONTAINS_OP
    mov rcx, [rbp - CC_LINE]
    call cg_emit
    jmp .done

.identity:
    ; CMPOP_IS -> IS_OP 0, CMPOP_ISNOT -> IS_OP 1
    mov rdx, rsi
    sub rdx, CMPOP_IS
    mov rdi, rbx
    mov esi, OP_IS_OP
    mov rcx, [rbp - CC_LINE]
    call cg_emit
.done:
    mov eax, 1
    pop rbx
    leave
    ret
END_FUNC cg_cmpop

;; ============================================================================
;; cg_set_loc(Comp *c, CompUnit *u, uint32_t node)
;;
;; Point the unit's current location at one node.  cg_expr and cg_stmt call it
;; on the way in and put back what was there on the way out, so every
;; instruction an emitter produces without saying anything about position
;; inherits the node being compiled -- which is what gives the line table
;; columns, and the traceback its caret row.
;;
;; A node whose span was never filled in has -1 ends; the columns are dropped
;; rather than half-reported, and cg_emit then writes the line-only form.
;; ============================================================================
SLOC_NODE  equ 8
SLOC_FRAME equ 32         ; + 2 pushes = 48
DEF_FUNC cg_set_loc, SLOC_FRAME
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov [rbp - SLOC_NODE], rdx

    mov rdi, rbx
    mov rsi, rdx
    call ast_at
    test rax, rax
    jz .csl_none
    mov ecx, [rax + AstNode.lineno]
    mov [r12 + CompUnit.curline], ecx
    mov ecx, [rax + AstNode.col]
    mov [r12 + CompUnit.curcol], ecx
    test ecx, ecx
    jl .csl_none

    mov rdi, rbx
    mov rsi, [rbp - SLOC_NODE]
    call ast_span_at
    test rax, rax
    jz .csl_none
    mov ecx, [rax + AstSpan.end_lineno]
    mov edx, [rax + AstSpan.end_col]
    test ecx, ecx
    jl .csl_none
    test edx, edx
    jl .csl_none
    mov [r12 + CompUnit.curend], ecx
    mov [r12 + CompUnit.curendcol], edx
    pop r12
    pop rbx
    leave
    ret
.csl_none:
    mov dword [r12 + CompUnit.curcol], -1
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_set_loc

;; ============================================================================
;; cg_error(Comp *c, const char *msg) -> rax = 0
;;
;; A codegen-time SyntaxError, at the location the emitters are generating
;; for.  Every one of these used to pass a literal ZERO for the line, and
;; comp_attach_location derives the source TEXT from the line -- so
;; "'break' outside loop" came out as line 0, offset 1, no source line and no
;; caret, where CPython underlines the keyword.
;;
;; Nothing new is tracked for it.  Comp.cur_unit is the unit cg_stmt is
;; dispatching into, and the four CompUnit.cur* fields are what cg_set_loc
;; already maintains from the node for the line table; curcol == -1 is its
;; "no location", and then there is nothing better to say than what the old
;; code said.
;; ============================================================================
CGE_COMP  equ 8
CGE_MSG   equ 16
CGE_FRAME equ 24                ; + 1 push = 32, 16-aligned
global cg_error
DEF_FUNC cg_error, CGE_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - CGE_MSG], rsi

    mov rax, [rdi + Comp.cur_unit]
    test rax, rax
    jz .cge_nowhere
    cmp dword [rax + CompUnit.curcol], -1
    je .cge_nowhere
    mov ecx, [rax + CompUnit.curline]
    mov r8d, [rax + CompUnit.curcol]
    mov r9d, [rax + CompUnit.curend]
    mov r10d, [rax + CompUnit.curendcol]
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    mov rdx, [rbp - CGE_MSG]
    call comp_error_span
    xor eax, eax
    pop rbx
    leave
    ret

.cge_nowhere:
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    mov rdx, [rbp - CGE_MSG]
    xor ecx, ecx
    xor r8d, r8d
    call comp_error
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC cg_error

;; ============================================================================
;; cg_expr(Comp *c, CompUnit *u, uint32_t node) -> rax = 1 ok, 0 error
;;
;; Dispatches on the node kind.  Every emitter reached from here leaves exactly
;; one value on the stack; assemble.asm's depth pass is what holds them to it.
;; ============================================================================
DEF_FUNC cg_expr, CE_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi                        ; Comp*
    mov r12, rsi                        ; CompUnit*
    mov r13, rdx                        ; node index

    test r13, r13
    jz .bad_node

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    movzx eax, byte [rax + AstNode.kind]
    cmp eax, AST_COUNT
    jae .bad_node
    lea rcx, [rel cg_expr_table]
    mov rax, [rcx + rax*8]
    test rax, rax
    jz .unsupported

    mov ecx, [r12 + CompUnit.curline]
    mov [rbp - CE_SLINE], ecx
    mov ecx, [r12 + CompUnit.curend]
    mov [rbp - CE_SEND], ecx
    mov ecx, [r12 + CompUnit.curcol]
    mov [rbp - CE_SCOL], ecx
    mov ecx, [r12 + CompUnit.curendcol]
    mov [rbp - CE_SECOL], ecx
    mov [rbp - CE_NPTR], rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call cg_set_loc

    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call qword [rbp - CE_NPTR]
    mov ecx, [rbp - CE_SLINE]
    mov [r12 + CompUnit.curline], ecx
    mov ecx, [rbp - CE_SEND]
    mov [r12 + CompUnit.curend], ecx
    mov ecx, [rbp - CE_SCOL]
    mov [r12 + CompUnit.curcol], ecx
    mov ecx, [rbp - CE_SECOL]
    mov [r12 + CompUnit.curendcol], ecx
    pop r13
    pop r12
    pop rbx
    leave
    ret

.unsupported:
    ; A starred expression reaches here when it is in a place no emitter takes
    ; it -- `x = *a`, which CPython refuses by name.  Everything else is a
    ; node kind with no emitter at all, which is this compiler's own gap and
    ; says so.  Either way the position is the node's: it was 0 before, and a
    ; syntax error on line 0 is not a location.
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov ecx, [rax + AstNode.lineno]
    mov r8d, [rax + AstNode.col]
    push rcx
    push r8
    movzx eax, byte [rax + AstNode.kind]
    push rax
    mov rdi, rbx
    mov esi, r13d
    extern ast_span_at
    call ast_span_at
    pop rdx                             ; the kind
    pop r8
    pop rcx
    mov r9d, ecx
    lea r10d, [r8d + 1]
    test rax, rax
    jz .cgu_no_span
    cmp dword [rax + AstSpan.end_lineno], -1
    je .cgu_no_span
    mov r9d, [rax + AstSpan.end_lineno]
    mov r10d, [rax + AstSpan.end_col]
.cgu_no_span:
    push rdx
    CSTRING rdx, "this expression is not supported yet"
    pop rax
    cmp eax, AST_STARRED
    jne .cgu_have_msg
    CSTRING rdx, "can't use starred expression here"
.cgu_have_msg:
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    extern comp_error_span
    call comp_error_span
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret

.bad_node:
    mov rdi, rbx
    CSTRING rsi, "invalid syntax"
    call cg_error
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_expr

;; ============================================================================
;; Expression emitters.  All share the signature
;;     fn(Comp *c, CompUnit *u, uint32_t node) -> rax = 1 ok, 0 error
;; ============================================================================

;; cg_e_const - LOAD_CONST
DEF_FUNC_LOCAL cg_e_const, CE_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov [rbp - CE_NPTR], rax
    mov esi, [rax + AstNode.a]
    mov rdi, rbx
    call ast_obj_at                     ; rax = the borrowed Value
    mov rdi, r12
    mov rsi, rax
    call cg_const
    mov rdx, rax
    mov rax, [rbp - CE_NPTR]
    mov ecx, [rax + AstNode.lineno]
    mov rdi, r12
    mov esi, OP_LOAD_CONST
    call cg_emit
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_e_const

;; cg_e_name - a name load, through cg_nameop
;;
;; Which opcode that becomes is the symbol table's decision, not the syntax's.
DEF_FUNC_LOCAL cg_e_name, CE_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov ecx, [rax + AstNode.lineno]
    mov [r12 + CompUnit.curline], ecx
    mov esi, [rax + AstNode.a]
    mov rdi, rbx
    call ast_obj_at
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    mov ecx, CTX_LOAD
    xor r8d, r8d
    call cg_nameop
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_e_name

;; cg_e_binop - left, right, BINARY_OP
DEF_FUNC_LOCAL cg_e_binop, CE_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov edx, [rax + AstNode.a]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov edx, [rax + AstNode.b]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    movzx edx, byte [rax + AstNode.subkind]
    mov ecx, [rax + AstNode.lineno]
    mov rdi, r12
    mov esi, OP_BINARY_OP
    call cg_emit
    mov eax, 1
.fail:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_e_binop

;; cg_e_unaryop - operand, then the unary opcode
;;
;; Unary plus emits nothing at all: CPython drops it, and there is no
;; UNARY_POSITIVE opcode in 3.12 to emit even if we wanted one.
DEF_FUNC_LOCAL cg_e_unaryop, CE_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov edx, [rax + AstNode.a]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    movzx edx, byte [rax + AstNode.subkind]
    mov ecx, [rax + AstNode.lineno]
    ; `+x` is not the identity: it calls __pos__, which a numeric class is free
    ; to define as anything.  CPython routes it through an intrinsic rather
    ; than a dedicated opcode.
    cmp edx, UOP_POS
    jne .not_pos
    mov rdi, r12
    mov esi, OP_CALL_INTRINSIC_1
    mov edx, INTRINSIC_UNARY_POSITIVE
    call cg_emit
    jmp .done
.not_pos:
    mov esi, OP_UNARY_NEGATIVE
    cmp edx, UOP_NEG
    je .have_op
    mov esi, OP_UNARY_INVERT
    cmp edx, UOP_INVERT
    je .have_op
    mov esi, OP_UNARY_NOT
.have_op:
    mov rdi, r12
    xor edx, edx
    call cg_emit
.done:
    mov eax, 1
.fail:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_e_unaryop

;; cg_e_boolop - `and` / `or`, short-circuiting through one shared exit
;;
;;     <operand>            for each but the last
;;     COPY 1
;;     POP_JUMP_IF_FALSE end        (IF_TRUE for `or`)
;;     POP_TOP
;;     <last operand>
;;   end:
;;
;; The value that decided the result is what the expression evaluates to, which
;; is why the operand is duplicated rather than tested and discarded.
CB_ALT   equ 8           ; the else / cleanup label
CB_END   equ 32
CB_I     equ 40
CB_N     equ 48
CB_OP    equ 56
CB_LINE  equ 64
CB_FRAME equ 72          ; + 3 pushes = 96
DEF_FUNC_LOCAL cg_e_boolop, CB_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov ecx, [rax + AstNode.nchild]
    mov [rbp - CB_N], rcx
    mov ecx, [rax + AstNode.lineno]
    mov [rbp - CB_LINE], rcx
    movzx ecx, byte [rax + AstNode.subkind]
    mov esi, OP_POP_JUMP_IF_FALSE
    cmp ecx, BOOL_OR
    jne .have_op
    mov esi, OP_POP_JUMP_IF_TRUE
.have_op:
    mov [rbp - CB_OP], rsi

    mov rdi, r12
    call cg_label_new
    mov [rbp - CB_END], rax

    mov qword [rbp - CB_I], 0
.loop:
    mov rax, [rbp - CB_I]
    mov rcx, [rbp - CB_N]
    cmp rax, rcx
    jae .finish

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - CB_I]
    mov rdi, rbx
    call ast_child
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail

    mov rax, [rbp - CB_I]
    inc rax
    mov [rbp - CB_I], rax
    cmp rax, [rbp - CB_N]
    jae .finish                         ; the last operand needs no test

    mov rdi, r12
    mov esi, OP_COPY
    mov edx, 1
    mov rcx, [rbp - CB_LINE]
    call cg_emit
    mov rdi, r12
    mov rsi, [rbp - CB_OP]
    mov rdx, [rbp - CB_END]
    mov rcx, [rbp - CB_LINE]
    call cg_emit_jump
    mov rdi, r12
    mov esi, OP_POP_TOP
    xor edx, edx
    mov rcx, [rbp - CB_LINE]
    call cg_emit
    jmp .loop

.finish:
    mov rdi, r12
    mov rsi, [rbp - CB_END]
    call cg_label_bind
    mov eax, 1
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
END_FUNC cg_e_boolop

;; cg_e_ifexp - body if test else orelse
DEF_FUNC_LOCAL cg_e_ifexp, CB_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov ecx, [rax + AstNode.lineno]
    mov [rbp - CB_LINE], rcx

    mov rdi, r12
    call cg_label_new
    mov [rbp - CB_I], rax               ; the `else` label
    mov rdi, r12
    call cg_label_new
    mov [rbp - CB_END], rax

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov edx, [rax + AstNode.a]          ; test
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail

    mov rdi, r12
    mov esi, OP_POP_JUMP_IF_FALSE
    mov rdx, [rbp - CB_I]
    mov rcx, [rbp - CB_LINE]
    call cg_emit_jump

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov edx, [rax + AstNode.b]          ; body
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail

    mov rdi, r12
    mov esi, OP_JUMP_FORWARD
    mov rdx, [rbp - CB_END]
    mov rcx, [rbp - CB_LINE]
    call cg_emit_jump

    mov rdi, r12
    mov rsi, [rbp - CB_I]
    call cg_label_bind

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov edx, [rax + AstNode.c]          ; orelse
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail

    mov rdi, r12
    mov rsi, [rbp - CB_END]
    call cg_label_bind
    mov eax, 1
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
END_FUNC cg_e_ifexp

;; cg_e_compare - a chain, evaluated left to right with each operand once
;;
;;     <left> <operand 0>
;;     for each but the last comparison:
;;         SWAP 2 ; COPY 2 ; <compare> ; COPY 1
;;         POP_JUMP_IF_FALSE cleanup
;;         POP_TOP
;;         <next operand>
;;     <compare>
;;     JUMP_FORWARD end
;;   cleanup: SWAP 2 ; POP_TOP
;;   end:
;;
;; The dance keeps the operand that is about to be reused underneath the result
;; of the comparison just made, so `a < b < c` evaluates b exactly once -- which
;; is the whole reason a chain is one node rather than a fold.
section .bss
cwil_buf: resb 128
section .text

;; ============================================================================
;; ============================================================================
;; cg_check_compare(Comp *c, uint32_t node, int lineno) -> nothing
;;
;; CPython's check_compare: over each (op, operand) pair, an `is` or `is not`
;; against a literal gets one warning, naming the left operand if that is the
;; literal and the right otherwise.  It returns after the first, so a chain
;; warns once however many of its comparisons qualify.
;; ============================================================================
CCC_C     equ 8
CCC_NODE  equ 16
CCC_LINE  equ 24
CCC_LEFT  equ 32
CCC_I     equ 40
CCC_N     equ 48
CCC_FRAME equ 64            ; + 0 pushes = 64, 16-aligned
DEF_FUNC_LOCAL cg_check_compare, CCC_FRAME
    mov [rbp - CCC_C], rdi
    mov [rbp - CCC_NODE], rsi
    mov [rbp - CCC_LINE], rdx
    call ast_at
    mov ecx, [rax + AstNode.nchild]
    mov [rbp - CCC_N], rcx
    mov edx, [rax + AstNode.a]
    mov [rbp - CCC_LEFT], rdx
    mov qword [rbp - CCC_I], 0
.ccc_loop:
    mov rax, [rbp - CCC_I]
    cmp rax, [rbp - CCC_N]
    jae .ccc_done
    mov rdi, [rbp - CCC_C]
    mov rsi, [rbp - CCC_NODE]
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - CCC_I]
    shl rdx, 1
    mov rdi, [rbp - CCC_C]
    call ast_child
    push rax                            ; the operator
    mov rdi, [rbp - CCC_C]
    mov rsi, [rbp - CCC_NODE]
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - CCC_I]
    shl rdx, 1
    inc rdx
    mov rdi, [rbp - CCC_C]
    call ast_child
    pop rcx
    push rax                            ; the right operand
    push rcx                            ; the operator
    cmp rcx, CMPOP_IS
    je .ccc_is
    cmp rcx, CMPOP_ISNOT
    jne .ccc_next
.ccc_is:
    mov rdi, [rbp - CCC_C]
    mov rsi, rcx
    mov rdx, [rbp - CCC_LEFT]
    mov rcx, [rbp - CCC_LINE]
    call cg_warn_is_literal
    test eax, eax
    jnz .ccc_stop
    mov rdi, [rbp - CCC_C]
    mov rsi, [rsp]                      ; the operator
    mov rdx, [rsp + 8]                  ; the right operand
    mov rcx, [rbp - CCC_LINE]
    call cg_warn_is_literal
    test eax, eax
    jnz .ccc_stop
.ccc_next:
    pop rcx
    pop rax
    mov [rbp - CCC_LEFT], rax
    inc qword [rbp - CCC_I]
    jmp .ccc_loop
.ccc_stop:
    add rsp, 16
.ccc_done:
    leave
    ret
END_FUNC cg_check_compare

;; cg_warn_is_literal(Comp *c, int op, uint32_t node, int lineno)
;;   -> eax = 1 if it warned, 0 if the operand is not a literal
;;
;; CPython's check_is_arg: `x is 1` compares identity where almost everyone
;; means equality, so it warns and names the literal's type.  None, True,
;; False and Ellipsis are the identities `is` is FOR, and say nothing.
;; ============================================================================
CWIL_C     equ 8
CWIL_OP    equ 16
CWIL_LINE  equ 24
CWIL_NODE  equ 32
CWIL_I     equ 40
CWIL_FRAME equ 56           ; + 1 push = 64, 16-aligned
DEF_FUNC_LOCAL cg_warn_is_literal, CWIL_FRAME
    push rbx
    mov [rbp - CWIL_C], rdi
    mov [rbp - CWIL_OP], rsi
    mov [rbp - CWIL_LINE], rcx
    mov rsi, rdx
    mov [rbp - CWIL_NODE], rdx
    call ast_at
    ; A tuple display of constants is a constant in CPython -- its folder
    ; settles `()` and `(1,)` before the check runs -- and nothing folds
    ; here, so the shape is recognised instead.
    cmp byte [rax + AstNode.kind], AST_TUPLE
    je .cwil_tuple
    cmp byte [rax + AstNode.kind], AST_CONST
    jne .cwil_no
    mov edx, [rax + AstNode.a]
    mov rdi, [rbp - CWIL_C]
    mov rsi, rdx
    call ast_obj_at
    ; The arena holds Values, so an immediate is its own type.
    V_IS_INT rax, rcx
    jae .cwil_int
    V_IS_FLOAT rax, rcx
    jbe .cwil_float
    test rax, rax
    jz .cwil_no
    mov rax, [rax + PyObject.ob_type]
    ; None, True and False are what `is` exists for.
    extern none_type
    lea rcx, [rel none_type]
    cmp rax, rcx
    je .cwil_no
    extern bool_type
    lea rcx, [rel bool_type]
    cmp rax, rcx
    je .cwil_no
    extern ellipsis_type
    lea rcx, [rel ellipsis_type]
    cmp rax, rcx
    je .cwil_no
    mov rbx, [rax + PyTypeObject.tp_name]
    jmp .cwil_have_name
.cwil_tuple:
    ; ...and only when every element is one: `(x,)` is not a constant.
    mov ecx, [rax + AstNode.nchild]
    mov [rbp - CWIL_I], rcx
    xor edx, edx
.cwil_tuple_loop:
    cmp rdx, [rbp - CWIL_I]
    jae .cwil_tuple_ok
    push rdx
    mov rdi, [rbp - CWIL_C]
    mov rsi, [rbp - CWIL_NODE]
    call ast_at
    mov rsi, rax
    mov rdx, [rsp]
    mov rdi, [rbp - CWIL_C]
    call ast_child
    mov rsi, rax
    mov rdi, [rbp - CWIL_C]
    call ast_at
    pop rdx
    cmp byte [rax + AstNode.kind], AST_CONST
    jne .cwil_no
    inc rdx
    jmp .cwil_tuple_loop
.cwil_tuple_ok:
    CSTRING rbx, "tuple"
    jmp .cwil_have_name

.cwil_int:
    CSTRING rbx, "int"
    jmp .cwil_have_name
.cwil_float:
    CSTRING rbx, "float"
.cwil_have_name:
    lea rdi, [rel cwil_buf]
    cmp qword [rbp - CWIL_OP], CMPOP_IS
    je .cwil_is
    CSTRING rsi, `"is not" with '`
    jmp .cwil_open
.cwil_is:
    CSTRING rsi, `"is" with '`
.cwil_open:
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, rbx
    call rbt_append_cstr
    mov rdi, rax
    cmp qword [rbp - CWIL_OP], CMPOP_IS
    je .cwil_tail_is
    CSTRING rsi, `' literal. Did you mean "!="?`
    jmp .cwil_tail
.cwil_tail_is:
    CSTRING rsi, `' literal. Did you mean "=="?`
.cwil_tail:
    call rbt_append_cstr
    mov rdi, [rbp - CWIL_C]
    lea rsi, [rel cwil_buf]
    mov rdx, [rbp - CWIL_LINE]
    extern comp_warn
    call comp_warn
    mov eax, 1
    pop rbx
    leave
    ret
.cwil_no:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC cg_warn_is_literal

DEF_FUNC_LOCAL cg_e_compare, CB_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov ecx, [rax + AstNode.nchild]
    mov [rbp - CB_N], rcx
    mov ecx, [rax + AstNode.lineno]
    mov [rbp - CB_LINE], rcx

    ; `x is 1` compares identity where almost everyone means equality, and
    ; CPython warns.  Done over the whole comparison before anything is
    ; emitted, so a chained one is covered by the same pass.
    mov rdi, rbx
    mov rsi, r13
    mov rdx, [rbp - CB_LINE]
    call cg_check_compare

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov edx, [rax + AstNode.a]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr                        ; the left operand
    test eax, eax
    jz .fail

    cmp qword [rbp - CB_N], 1
    jne .chained

    ; The common case: one comparison, no bookkeeping at all.
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov rsi, rax
    xor edx, edx
    mov rdi, rbx
    call ast_child                      ; child 0 is the operator
    mov [rbp - CB_OP], rax
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov rsi, rax
    mov edx, 1
    mov rdi, rbx
    call ast_child                      ; child 1 is its operand
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    mov rdi, r12
    mov rsi, [rbp - CB_OP]
    mov rdx, [rbp - CB_LINE]
    call cg_cmpop
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    leave
    ret

.chained:
    mov rdi, r12
    call cg_label_new
    mov [rbp - CB_ALT], rax            ; cleanup label
    mov rdi, r12
    call cg_label_new
    mov [rbp - CB_END], rax

    ; Emit the first right-hand operand, then loop over the comparisons.
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov rsi, rax
    mov edx, 1
    mov rdi, rbx
    call ast_child
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail

    mov qword [rbp - CB_I], 0
.chain_loop:
    ; operator index i lives at child 2*i, its operand at child 2*i + 1
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - CB_I]
    shl rdx, 1
    mov rdi, rbx
    call ast_child
    mov [rbp - CB_OP], rax

    mov rax, [rbp - CB_I]
    inc rax
    cmp rax, [rbp - CB_N]
    jae .chain_last

    mov rdi, r12
    mov esi, OP_SWAP
    mov edx, 2
    mov rcx, [rbp - CB_LINE]
    call cg_emit
    mov rdi, r12
    mov esi, OP_COPY
    mov edx, 2
    mov rcx, [rbp - CB_LINE]
    call cg_emit
    mov rdi, r12
    mov rsi, [rbp - CB_OP]
    mov rdx, [rbp - CB_LINE]
    call cg_cmpop
    mov rdi, r12
    mov esi, OP_COPY
    mov edx, 1
    mov rcx, [rbp - CB_LINE]
    call cg_emit
    mov rdi, r12
    mov esi, OP_POP_JUMP_IF_FALSE
    mov rdx, [rbp - CB_ALT]
    mov rcx, [rbp - CB_LINE]
    call cg_emit_jump
    mov rdi, r12
    mov esi, OP_POP_TOP
    xor edx, edx
    mov rcx, [rbp - CB_LINE]
    call cg_emit

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - CB_I]
    shl rdx, 1
    add rdx, 3                          ; the next comparison's operand
    mov rdi, rbx
    call ast_child
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail

    mov rax, [rbp - CB_I]
    inc rax
    mov [rbp - CB_I], rax
    jmp .chain_loop

.chain_last:
    mov rdi, r12
    mov rsi, [rbp - CB_OP]
    mov rdx, [rbp - CB_LINE]
    call cg_cmpop
    mov rdi, r12
    mov esi, OP_JUMP_FORWARD
    mov rdx, [rbp - CB_END]
    mov rcx, [rbp - CB_LINE]
    call cg_emit_jump

    mov rdi, r12
    mov rsi, [rbp - CB_ALT]
    call cg_label_bind
    mov rdi, r12
    mov esi, OP_SWAP
    mov edx, 2
    mov rcx, [rbp - CB_LINE]
    call cg_emit
    mov rdi, r12
    mov esi, OP_POP_TOP
    xor edx, edx
    mov rcx, [rbp - CB_LINE]
    call cg_emit
    mov rdi, r12
    mov rsi, [rbp - CB_END]
    call cg_label_bind

    mov eax, 1
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
END_FUNC cg_e_compare

;; ============================================================================
;; cg_children(Comp *c, CompUnit *u, uint32_t node) -> rax = 1 ok, 0 error
;; Emit every child of a node in order, each leaving one value on the stack.
;; ============================================================================
CH_I     equ 32
CH_N     equ 40
CH_FRAME equ 40          ; + 3 pushes = 64
DEF_FUNC cg_children, CH_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov ecx, [rax + AstNode.nchild]
    mov [rbp - CH_N], rcx
    mov qword [rbp - CH_I], 0
.loop:
    mov rax, [rbp - CH_I]
    cmp rax, [rbp - CH_N]
    jae .done
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - CH_I]
    mov rdi, rbx
    call ast_child
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    inc qword [rbp - CH_I]
    jmp .loop
.done:
    mov eax, 1
.fail:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_children

;; ============================================================================
;; cg_has_star(Comp *c, uint32_t node, int kind) -> rax = 1 if any child has it
;; ============================================================================
DEF_FUNC cg_has_star, 8
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    mov rsi, r12
    call ast_at
    mov ecx, [rax + AstNode.nchild]
    xor edx, edx
.loop:
    cmp rdx, rcx
    jae .no
    push rcx
    push rdx
    mov rdi, rbx
    mov rsi, r12
    call ast_at
    mov rsi, rax
    mov rdx, [rsp]
    mov rdi, rbx
    call ast_child
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    movzx eax, byte [rax + AstNode.kind]
    pop rdx
    pop rcx
    cmp eax, r13d
    je .yes
    inc rdx
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
END_FUNC cg_has_star

;; ============================================================================
;; cg_e_seq - tuple, list and set displays
;;
;; Without any unpacking this is just the elements followed by one BUILD_*.
;; With a `*x` among them the container is built empty and extended, because
;; BUILD_* takes a fixed count and cannot absorb an iterable of unknown length.
;; A tuple takes the list route and is converted at the end, which is what
;; CPython does and why INTRINSIC_LIST_TO_TUPLE exists.
;; ============================================================================
CS_I     equ 32
CS_N     equ 40
CS_LINE  equ 48
CS_KIND  equ 56
CS_OPEN  equ 64
CS_ADD   equ 72
CS_EXT   equ 80
; The element being emitted.  It was a bare r14 -- which is the caller's, and
; main keeps argv there across the compile, so a display anywhere in the file
; handed back a different argv and the crash landed in sys.argv construction.
CS_ELT   equ 88
CS_FRAME equ 104         ; + 3 pushes = 128
DEF_FUNC_LOCAL cg_e_seq, CS_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    movzx ecx, byte [rax + AstNode.kind]
    mov [rbp - CS_KIND], rcx
    mov ecx, [rax + AstNode.nchild]
    mov [rbp - CS_N], rcx
    mov ecx, [rax + AstNode.lineno]
    mov [rbp - CS_LINE], rcx

    ; Pick the opcode trio for this container kind.
    mov rax, [rbp - CS_KIND]
    cmp eax, AST_LIST
    je .as_list
    cmp eax, AST_SET
    je .as_set
    ; a tuple
    mov qword [rbp - CS_OPEN], OP_BUILD_LIST
    mov qword [rbp - CS_ADD], OP_LIST_APPEND
    mov qword [rbp - CS_EXT], OP_LIST_EXTEND
    jmp .have_ops
.as_list:
    mov qword [rbp - CS_OPEN], OP_BUILD_LIST
    mov qword [rbp - CS_ADD], OP_LIST_APPEND
    mov qword [rbp - CS_EXT], OP_LIST_EXTEND
    jmp .have_ops
.as_set:
    mov qword [rbp - CS_OPEN], OP_BUILD_SET
    mov qword [rbp - CS_ADD], OP_SET_ADD
    mov qword [rbp - CS_EXT], OP_SET_UPDATE
.have_ops:

    mov rdi, rbx
    mov rsi, r13
    mov edx, AST_STARRED
    call cg_has_star
    test eax, eax
    jnz .unpacked

    ; The simple shape: every element, then one BUILD_*.
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call cg_children
    test eax, eax
    jz .fail
    mov rax, [rbp - CS_KIND]
    mov esi, OP_BUILD_TUPLE
    cmp eax, AST_TUPLE
    je .emit_build
    mov esi, OP_BUILD_LIST
    cmp eax, AST_LIST
    je .emit_build
    mov esi, OP_BUILD_SET
.emit_build:
    mov rdi, r12
    mov rdx, [rbp - CS_N]
    mov rcx, [rbp - CS_LINE]
    call cg_emit
    mov eax, 1
    jmp .ret

.unpacked:
    mov rdi, r12
    mov rsi, [rbp - CS_OPEN]
    xor edx, edx
    mov rcx, [rbp - CS_LINE]
    call cg_emit

    mov qword [rbp - CS_I], 0
.up_loop:
    mov rax, [rbp - CS_I]
    cmp rax, [rbp - CS_N]
    jae .up_done
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - CS_I]
    mov rdi, rbx
    call ast_child
    mov [rbp - CS_ELT], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    movzx eax, byte [rax + AstNode.kind]
    cmp eax, AST_STARRED
    je .up_star

    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rbp - CS_ELT]
    call cg_expr
    test eax, eax
    jz .fail
    mov rdi, r12
    mov rsi, [rbp - CS_ADD]
    mov edx, 1
    mov rcx, [rbp - CS_LINE]
    call cg_emit
    jmp .up_next

.up_star:
    mov rdi, rbx
    mov rsi, [rbp - CS_ELT]
    call ast_at
    mov edx, [rax + AstNode.a]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    mov rdi, r12
    mov rsi, [rbp - CS_EXT]
    mov edx, 1
    mov rcx, [rbp - CS_LINE]
    call cg_emit

.up_next:
    inc qword [rbp - CS_I]
    jmp .up_loop
.up_done:
    ; A tuple was accumulated as a list; convert it.
    cmp qword [rbp - CS_KIND], AST_TUPLE
    jne .up_ok
    mov rdi, r12
    mov esi, OP_CALL_INTRINSIC_1
    mov edx, INTRINSIC_LIST_TO_TUPLE
    mov rcx, [rbp - CS_LINE]
    call cg_emit
.up_ok:
    mov eax, 1
    jmp .ret
.fail:
    xor eax, eax
.ret:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_e_seq

;; ============================================================================
;; cg_e_dict - {k: v, **m}
;; The child list is key/value pairs; a `**m` entry occupies a pair whose value
;; slot is unused, so the walk stays uniform.  Runs of literal pairs are built
;; with one BUILD_MAP and merged in, which is what keeps {**a, 1: 2} to two
;; DICT_UPDATEs rather than one per key.
;; ============================================================================
CD_I     equ 32
CD_N     equ 40
CD_LINE  equ 48
CD_RUN   equ 56
CD_ANY   equ 64
CD_ELT   equ 72          ; see CS_ELT: this was a bare r14 too
CD_FRAME equ 88          ; + 3 pushes = 112
DEF_FUNC_LOCAL cg_e_dict, CD_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov ecx, [rax + AstNode.nchild]
    shr rcx, 1                          ; pairs
    mov [rbp - CD_N], rcx
    mov ecx, [rax + AstNode.lineno]
    mov [rbp - CD_LINE], rcx

    mov rdi, rbx
    mov rsi, r13
    mov edx, AST_DOUBLESTARRED
    call cg_has_star
    mov [rbp - CD_ANY], rax
    test rax, rax
    jnz .with_unpack

    ; No ** at all: keys and values in order, then one BUILD_MAP.
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call cg_children
    test eax, eax
    jz .fail
    mov rdi, r12
    mov esi, OP_BUILD_MAP
    mov rdx, [rbp - CD_N]
    mov rcx, [rbp - CD_LINE]
    call cg_emit
    mov eax, 1
    jmp .ret

.with_unpack:
    mov rdi, r12
    mov esi, OP_BUILD_MAP
    xor edx, edx
    mov rcx, [rbp - CD_LINE]
    call cg_emit
    mov qword [rbp - CD_I], 0
    mov qword [rbp - CD_RUN], 0

.loop:
    mov rax, [rbp - CD_I]
    cmp rax, [rbp - CD_N]
    jae .flush_last

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - CD_I]
    shl rdx, 1
    mov rdi, rbx
    call ast_child
    mov [rbp - CD_ELT], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    movzx eax, byte [rax + AstNode.kind]
    cmp eax, AST_DOUBLESTARRED
    je .unpack_entry

    ; A literal pair: emit key and value, and count it into the pending run.
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rbp - CD_ELT]
    call cg_expr
    test eax, eax
    jz .fail
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - CD_I]
    shl rdx, 1
    inc rdx
    mov rdi, rbx
    call ast_child
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    inc qword [rbp - CD_RUN]
    inc qword [rbp - CD_I]
    jmp .loop

.unpack_entry:
    call .flush_run
    mov rdi, rbx
    mov rsi, [rbp - CD_ELT]
    call ast_at
    mov edx, [rax + AstNode.a]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    mov rdi, r12
    mov esi, OP_DICT_UPDATE
    mov edx, 1
    mov rcx, [rbp - CD_LINE]
    call cg_emit
    inc qword [rbp - CD_I]
    jmp .loop

.flush_last:
    call .flush_run
    mov eax, 1
    jmp .ret

; Local: turn any pending literal pairs into a map and merge it in.
; `call .flush_run` pushes a return address, so rsp is 8 out for the calls
; below; correct it rather than leave libc a misaligned stack.
.flush_run:
    sub rsp, 8
    cmp qword [rbp - CD_RUN], 0
    je .flush_none
    mov rdi, r12
    mov esi, OP_BUILD_MAP
    mov rdx, [rbp - CD_RUN]
    mov rcx, [rbp - CD_LINE]
    call cg_emit
    mov rdi, r12
    mov esi, OP_DICT_UPDATE
    mov edx, 1
    mov rcx, [rbp - CD_LINE]
    call cg_emit
    mov qword [rbp - CD_RUN], 0
.flush_none:
    add rsp, 8
    ret

.fail:
    xor eax, eax
.ret:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_e_dict

;; ============================================================================
;; cg_e_attribute - value.name -> LOAD_ATTR (index << 1)
;; Bit 0 of the oparg is the method-call form, which pushes self alongside the
;; function; it is set by cg_e_call, not here.
;; ============================================================================
DEF_FUNC_LOCAL cg_e_attribute, CE_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    ; A bare super().x goes through LOAD_SUPER_ATTR as well.
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx                        ; not a method call
    call cg_super_attr
    cmp rax, -1
    je .fail
    test rax, rax
    jnz .ret_ok
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov edx, [rax + AstNode.a]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov [rbp - CE_NPTR], rax
    mov esi, [rax + AstNode.b]
    mov rdi, rbx
    call ast_obj_at
    mov rdi, r12
    mov rsi, rax
    call cg_name
    lea rdx, [rax + rax]                ; index << 1; bit 0 stays clear
    mov rax, [rbp - CE_NPTR]
    mov ecx, [rax + AstNode.lineno]
    mov rdi, r12
    mov esi, OP_LOAD_ATTR
    call cg_emit
.ret_ok:
    mov eax, 1
    jmp .ret
.fail:
    ; cg_super_attr answers -1 for an error it has already recorded, and this
    ; label is reached with that -1 still in rax.  Falling into the epilogue
    ; without zeroing handed it back, and every caller tests for zero -- so the
    ; recorded SyntaxError was dropped and code was emitted for an expression
    ; that was never built.
    xor eax, eax
.ret:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_e_attribute

;; ============================================================================
;; cg_e_subscript - value[index] -> BINARY_SUBSCR
;; ============================================================================
DEF_FUNC_LOCAL cg_e_subscript, CE_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov edx, [rax + AstNode.a]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov edx, [rax + AstNode.b]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov ecx, [rax + AstNode.lineno]
    mov rdi, r12
    mov esi, OP_BINARY_SUBSCR
    xor edx, edx
    call cg_emit
    mov eax, 1
.fail:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_e_subscript

;; ============================================================================
;; cg_e_slice - a:b or a:b:c, as the operand of a subscript
;; An omitted bound is None, which is what makes x[:n] and x[None:n] the same
;; thing to the sequence protocol.
;; ============================================================================
CSL_LINE  equ 32
CSL_N     equ 40
CSL_FRAME equ 40          ; + 3 pushes = 64
DEF_FUNC_LOCAL cg_e_slice, CSL_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    movzx ecx, byte [rax + AstNode.subkind]
    mov [rbp - CSL_N], rcx
    mov ecx, [rax + AstNode.lineno]
    mov [rbp - CSL_LINE], rcx

    mov edx, AstNode.a
    call .piece
    test eax, eax
    jz .fail
    mov edx, AstNode.b
    call .piece
    test eax, eax
    jz .fail
    cmp qword [rbp - CSL_N], 3
    jne .build
    mov edx, AstNode.c
    call .piece
    test eax, eax
    jz .fail
.build:
    mov rdi, r12
    mov esi, OP_BUILD_SLICE
    mov rdx, [rbp - CSL_N]
    mov rcx, [rbp - CSL_LINE]
    call cg_emit
    mov eax, 1
    jmp .ret

; Local: emit one bound, or None when it was omitted.  See the note in
; cg_e_dict about `call .label` and stack alignment.
.piece:
    sub rsp, 8
    push rdx
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    pop rdx
    mov edx, [rax + rdx]
    test edx, edx
    jz .piece_none
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    add rsp, 8
    ret
.piece_none:
    lea rsi, [rel none_singleton]
    INCREF rsi
    mov rdi, r12
    call cg_const
    mov rdx, rax
    mov rdi, r12
    mov esi, OP_LOAD_CONST
    mov rcx, [rbp - CSL_LINE]
    call cg_emit
    mov eax, 1
    add rsp, 8
    ret

.fail:
    xor eax, eax
.ret:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_e_slice

;; ============================================================================
;; cg_e_call - func(args)
;;
;; Two shapes, chosen by whether the call has any `*a` or `**k`.
;;
;; Plain: PUSH_NULL, the callable, the arguments, an optional KW_NAMES naming
;; the trailing keyword ones, then CALL n.  The NULL slot is where a bound
;; method's self goes; when the callable is an attribute, LOAD_ATTR's bit 0
;; fills it instead and no PUSH_NULL is emitted -- that is the whole point of
;; the method-call form, and it is why `o.m(1)` is three instructions.
;;
;; Unpacked: the positional arguments are gathered into a list, extended by
;; each `*a`, converted to a tuple, and the keywords into a dict merged by each
;; `**k`; then CALL_FUNCTION_EX.  A fixed-count CALL cannot absorb an iterable
;; whose length is unknown until run time.
;; ============================================================================
CC2_I     equ 32
CC2_N     equ 40
CC2_LINE  equ 48
CC2_NPOS  equ 56
CC2_NKW   equ 64
CC2_CHILD equ 72
CC2_EX    equ 88
CC2_FRAME equ 104         ; + 3 pushes = 128
DEF_FUNC_LOCAL cg_e_call, CC2_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov ecx, [rax + AstNode.nchild]
    mov [rbp - CC2_N], rcx
    mov ecx, [rax + AstNode.lineno]
    mov [rbp - CC2_LINE], rcx

    ; Whether the call is unpacked has to be settled before the callable is
    ; emitted.  CALL_FUNCTION_EX reads [NULL, callable, args], and the
    ; method-call form fills that NULL slot with the instance instead -- so an
    ; unpacked call cannot use it.  Deciding this down at .args, after
    ; LOAD_ATTR had already gone out with bit 0 set, left `o.m(*a)` calling
    ; the object rather than the method.
    mov rdi, rbx
    mov rsi, r13
    mov edx, AST_STARRED
    call cg_has_star
    mov [rbp - CC2_EX], rax
    test eax, eax
    jnz .ex_known
    mov rdi, rbx
    mov rsi, r13
    mov edx, AST_DOUBLESTARRED
    call cg_has_star
    mov [rbp - CC2_EX], rax
.ex_known:

    ; --- the callable, with the method-call shortcut where it applies ---
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov edx, [rax + AstNode.a]
    mov [rbp - CC2_CHILD], rdx
    mov rdi, rbx
    mov rsi, rdx
    call ast_at
    movzx eax, byte [rax + AstNode.kind]
    cmp eax, AST_ATTRIBUTE
    je .method_call

    mov rdi, r12
    mov esi, OP_PUSH_NULL
    xor edx, edx
    mov rcx, [rbp - CC2_LINE]
    call cg_emit
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rbp - CC2_CHILD]
    call cg_expr
    test eax, eax
    jz .fail
    jmp .args

.method_call:
    ; An unpacked call needs the NULL slot the method form would consume, and
    ; nothing else emits one here: LOAD_GLOBAL for `super` goes out without
    ; bit 0 set, so the PUSH_NULL has to be ours.
    cmp qword [rbp - CC2_EX], 0
    je .method_have_null
    mov rdi, r12
    mov esi, OP_PUSH_NULL
    xor edx, edx
    mov rcx, [rbp - CC2_LINE]
    call cg_emit
.method_have_null:

    ; super().m(...) is not an ordinary attribute load: LOAD_SUPER_ATTR takes
    ; the place of both the call to super and the attribute lookup.
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rbp - CC2_CHILD]
    mov ecx, 1                          ; the method form
    cmp qword [rbp - CC2_EX], 0
    je .method_super_form
    xor ecx, ecx
.method_super_form:
    call cg_super_attr
    cmp rax, -1
    je .fail
    test rax, rax
    jnz .args

    ; LOAD_ATTR with bit 0 set pushes the function and the instance, filling
    ; the slot PUSH_NULL would otherwise occupy.
    mov rdi, rbx
    mov rsi, [rbp - CC2_CHILD]
    call ast_at
    mov edx, [rax + AstNode.a]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    ; The load belongs to the ATTRIBUTE, not to the call around it: CPython
    ; underlines `v.upper().nope` and not `v.upper().nope()` when it raises.
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rbp - CC2_CHILD]
    call cg_set_loc
    mov rdi, rbx
    mov rsi, [rbp - CC2_CHILD]
    call ast_at
    mov esi, [rax + AstNode.b]
    mov rdi, rbx
    call ast_obj_at
    mov rdi, r12
    mov rsi, rax
    call cg_name
    lea rdx, [rax + rax]                ; index << 1
    cmp qword [rbp - CC2_EX], 0
    jne .attr_oparg_ready
    inc rdx                             ; bit 0: the method form
.attr_oparg_ready:
    mov rdi, r12
    mov esi, OP_LOAD_ATTR
    mov rcx, [rbp - CC2_LINE]
    call cg_emit
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call cg_set_loc

.args:
    cmp qword [rbp - CC2_EX], 0
    jne .unpacked

    ; --- the plain shape ---
    ; Positional arguments must all precede the keyword ones; CALL's oparg is a
    ; single count and KW_NAMES names only a suffix of it.
    mov qword [rbp - CC2_NPOS], 0
    mov qword [rbp - CC2_NKW], 0
    mov qword [rbp - CC2_I], 0
.plain_loop:
    mov rax, [rbp - CC2_I]
    cmp rax, [rbp - CC2_N]
    jae .plain_kwnames
    call .child_at
    mov [rbp - CC2_CHILD], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    movzx eax, byte [rax + AstNode.kind]
    cmp eax, AST_KEYWORD
    je .plain_kw

    cmp qword [rbp - CC2_NKW], 0
    jne .pos_after_kw
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rbp - CC2_CHILD]
    call cg_expr
    test eax, eax
    jz .fail
    inc qword [rbp - CC2_NPOS]
    inc qword [rbp - CC2_I]
    jmp .plain_loop

.plain_kw:
    mov rdi, rbx
    mov rsi, [rbp - CC2_CHILD]
    call ast_at
    mov edx, [rax + AstNode.b]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    inc qword [rbp - CC2_NKW]
    inc qword [rbp - CC2_I]
    jmp .plain_loop

.plain_kwnames:
    cmp qword [rbp - CC2_NKW], 0
    je .plain_call
    ; KW_NAMES takes a constant tuple naming the trailing arguments.
    mov rdi, rbx
    mov rsi, r13
    call cg_kwnames_tuple
    test eax, eax
    jz .fail
    ; The tuple is owned and cg_const stores a borrowed reference, so hand it
    ; to the arena: comp_free releases it however the compilation ended.
    mov rdi, rbx
    mov rsi, rax
    call comp_keep
    mov rdi, r12
    mov rsi, rax
    call cg_const
    mov rdx, rax
    mov rdi, r12
    mov esi, OP_KW_NAMES
    mov rcx, [rbp - CC2_LINE]
    call cg_emit
.plain_call:
    mov rdi, r12
    mov esi, OP_CALL
    mov rdx, [rbp - CC2_NPOS]
    add rdx, [rbp - CC2_NKW]
    mov rcx, [rbp - CC2_LINE]
    call cg_emit
    mov eax, 1
    jmp .ret

.unpacked:
    ; CPython compiles a call whose positional arguments are exactly one `*x`
    ; to a BARE CALL_FUNCTION_EX: the expression IS the argument sequence, with
    ; no list built around it.  That is not cosmetic -- the refusal then comes
    ; from the call, which knows the callee, so `f(*5)` reads
    ; "__main__.f() argument after * must be an iterable, not int" instead of
    ; the anonymous sentence LIST_EXTEND words for `f(*a, *b)` and `[*5]`.
    mov qword [rbp - CC2_NPOS], 0       ; plain positional arguments seen
    mov qword [rbp - CC2_NKW], 0        ; reused here as the count of *a
    mov qword [rbp - CC2_I], 0
.lone_scan:
    mov rax, [rbp - CC2_I]
    cmp rax, [rbp - CC2_N]
    jae .lone_decide
    call .child_at
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    movzx eax, byte [rax + AstNode.kind]
    cmp eax, AST_KEYWORD
    je .lone_next
    cmp eax, AST_DOUBLESTARRED
    je .lone_next
    cmp eax, AST_STARRED
    je .lone_star
    inc qword [rbp - CC2_NPOS]
    jmp .lone_next
.lone_star:
    inc qword [rbp - CC2_NKW]
.lone_next:
    inc qword [rbp - CC2_I]
    jmp .lone_scan
.lone_decide:
    cmp qword [rbp - CC2_NPOS], 0
    jne .build_args
    cmp qword [rbp - CC2_NKW], 1
    jne .build_args
    mov qword [rbp - CC2_I], 0
.lone_find:
    call .child_at
    mov [rbp - CC2_CHILD], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    movzx ecx, byte [rax + AstNode.kind]
    cmp ecx, AST_STARRED
    je .lone_emit
    inc qword [rbp - CC2_I]
    jmp .lone_find
.lone_emit:
    mov edx, [rax + AstNode.a]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    jmp .kwargs

.build_args:
    ; Positional arguments become a list, extended by each *a, then a tuple.
    mov rdi, r12
    mov esi, OP_BUILD_LIST
    xor edx, edx
    mov rcx, [rbp - CC2_LINE]
    call cg_emit
    mov qword [rbp - CC2_I], 0
.pos_loop:
    mov rax, [rbp - CC2_I]
    cmp rax, [rbp - CC2_N]
    jae .pos_done
    call .child_at
    mov [rbp - CC2_CHILD], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    movzx eax, byte [rax + AstNode.kind]
    cmp eax, AST_KEYWORD
    je .pos_next
    cmp eax, AST_DOUBLESTARRED
    je .pos_next
    cmp eax, AST_STARRED
    je .pos_star

    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rbp - CC2_CHILD]
    call cg_expr
    test eax, eax
    jz .fail
    mov rdi, r12
    mov esi, OP_LIST_APPEND
    mov edx, 1
    mov rcx, [rbp - CC2_LINE]
    call cg_emit
    jmp .pos_next
.pos_star:
    mov rdi, rbx
    mov rsi, [rbp - CC2_CHILD]
    call ast_at
    mov edx, [rax + AstNode.a]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    mov rdi, r12
    mov esi, OP_LIST_EXTEND
    mov edx, 1
    mov rcx, [rbp - CC2_LINE]
    call cg_emit
.pos_next:
    inc qword [rbp - CC2_I]
    jmp .pos_loop
.pos_done:
    mov rdi, r12
    mov esi, OP_CALL_INTRINSIC_1
    mov edx, INTRINSIC_LIST_TO_TUPLE
    mov rcx, [rbp - CC2_LINE]
    call cg_emit

.kwargs:
    ; Keywords become a dict, merged by each **k.  It is emitted only when
    ; there are any: CALL_FUNCTION_EX's bit 0 says whether one is present.
    mov rdi, rbx
    mov rsi, r13
    mov edx, AST_DOUBLESTARRED
    call cg_has_star
    mov [rbp - CC2_NKW], rax
    test rax, rax
    jnz .need_kwdict
    mov rdi, rbx
    mov rsi, r13
    call cg_call_has_keyword
    mov [rbp - CC2_NKW], rax
    test rax, rax
    jz .ex_call

.need_kwdict:
    mov rdi, r12
    mov esi, OP_BUILD_MAP
    xor edx, edx
    mov rcx, [rbp - CC2_LINE]
    call cg_emit
    mov qword [rbp - CC2_I], 0
.kw_loop:
    mov rax, [rbp - CC2_I]
    cmp rax, [rbp - CC2_N]
    jae .ex_call
    call .child_at
    mov [rbp - CC2_CHILD], rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    movzx eax, byte [rax + AstNode.kind]
    cmp eax, AST_KEYWORD
    je .kw_named
    cmp eax, AST_DOUBLESTARRED
    je .kw_unpack
    jmp .kw_next

.kw_named:
    ; One key and one value, built into a one-entry map and merged.
    mov rdi, rbx
    mov rsi, [rbp - CC2_CHILD]
    call ast_at
    mov esi, [rax + AstNode.a]
    mov rdi, rbx
    call ast_obj_at
    mov rdi, r12
    mov rsi, rax
    call cg_const
    mov rdx, rax
    mov rdi, r12
    mov esi, OP_LOAD_CONST
    mov rcx, [rbp - CC2_LINE]
    call cg_emit
    mov rdi, rbx
    mov rsi, [rbp - CC2_CHILD]
    call ast_at
    mov edx, [rax + AstNode.b]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    mov rdi, r12
    mov esi, OP_BUILD_MAP
    mov edx, 1
    mov rcx, [rbp - CC2_LINE]
    call cg_emit
    mov rdi, r12
    mov esi, OP_DICT_MERGE
    mov edx, 1
    mov rcx, [rbp - CC2_LINE]
    call cg_emit
    jmp .kw_next

.kw_unpack:
    mov rdi, rbx
    mov rsi, [rbp - CC2_CHILD]
    call ast_at
    mov edx, [rax + AstNode.a]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    mov rdi, r12
    mov esi, OP_DICT_MERGE
    mov edx, 1
    mov rcx, [rbp - CC2_LINE]
    call cg_emit
.kw_next:
    inc qword [rbp - CC2_I]
    jmp .kw_loop

.ex_call:
    mov rdi, r12
    mov esi, OP_CALL_FUNCTION_EX
    xor edx, edx
    cmp qword [rbp - CC2_NKW], 0
    je .ex_emit
    mov edx, 1
.ex_emit:
    mov rcx, [rbp - CC2_LINE]
    call cg_emit
    mov eax, 1
    jmp .ret

.pos_after_kw:
    mov rdi, rbx
    CSTRING rsi, "positional argument follows keyword argument"
    call cg_error
.fail:
    xor eax, eax
    jmp .ret

; Local: the i'th argument node.  Only leaf calls follow, so the 8-byte skew
; from `call .child_at` does not reach libc.
.child_at:
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - CC2_I]
    mov rdi, rbx
    call ast_child
    ret

.ret_ok:
    mov eax, 1
.ret:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_e_call

;; ============================================================================
;; cg_try_zero_super(Comp *c, CompUnit *u, uint32_t call)
;;   -> rax = 1 if it emitted the call, 0 if this is not one, -1 on error
;;
;; Emits  PUSH_NULL; LOAD_GLOBAL super; LOAD_DEREF __class__; LOAD_FAST self;
;;        CALL 2
;; for a bare `super()` inside a method.  The first parameter is whatever the
;; method called it -- `self` by convention only -- so it comes from the
;; scope's first varname rather than from a hard-coded name.
;; ============================================================================
ZS_ATTR   equ 8
ZS_METH   equ 16
ZS_LINE   equ 24
ZS_CALL   equ 32
ZS_NARGS  equ 40
ZS_TWOARG equ 48
ZS_I      equ 56
ZS_FRAME  equ 56          ; + 3 pushes = 80
DEF_FUNC cg_super_attr, ZS_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov [rbp - ZS_ATTR], rdx
    mov [rbp - ZS_METH], rcx

    ; The attribute's value has to be a call to the name `super`.
    mov rdi, rbx
    mov rsi, rdx
    call ast_at
    mov ecx, [rax + AstNode.lineno]
    mov [rbp - ZS_LINE], rcx
    mov ecx, [rax + AstNode.a]
    mov [rbp - ZS_CALL], rcx
    test ecx, ecx
    jz .no
    mov rdi, rbx
    mov rsi, rcx
    call ast_at
    movzx ecx, byte [rax + AstNode.kind]
    cmp ecx, AST_CALL
    jne .no
    mov ecx, [rax + AstNode.nchild]
    mov [rbp - ZS_NARGS], rcx
    cmp rcx, 2
    ja .no                              ; super() takes zero or two arguments
    cmp rcx, 1
    je .no
    mov edx, [rax + AstNode.a]
    mov rdi, rbx
    mov rsi, rdx
    call ast_at
    movzx ecx, byte [rax + AstNode.kind]
    cmp ecx, AST_NAME
    jne .no
    mov esi, [rax + AstNode.a]
    mov rdi, rbx
    call ast_obj_at
    mov r13, rax
    mov rdi, rbx
    lea rsi, [rel cg_super_name]
    call comp_intern_cstr
    test rax, rax
    jz .no
    mov rdi, r13
    mov rsi, rax
    call sym_str_eq
    test eax, eax
    jz .no

    ; LOAD_SUPER_ATTR wants the super builtin, the class and the instance, in
    ; that order.  apython has no callable super type -- this opcode is the
    ; only way it is reachable -- so the zero-argument form is expanded here
    ; into the class cell and the method's first parameter.
    mov rdi, rbx
    lea rsi, [rel cg_super_name]
    call comp_intern_cstr
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    mov ecx, CTX_LOAD
    xor r8d, r8d
    call cg_nameop
    test eax, eax
    jz .err

    cmp qword [rbp - ZS_NARGS], 2
    je .explicit

    ; Zero-argument: __class__ from the cell, and the first parameter.
    cmp dword [r12 + CompUnit.argcount], 0
    je .bad_context
    mov rdi, rbx
    lea rsi, [rel cg_classvar_name]
    call comp_intern_cstr
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    mov ecx, CTX_LOAD
    xor r8d, r8d
    call cg_nameop
    test eax, eax
    jz .err

    mov rdi, rbx
    mov esi, [r12 + CompUnit.scope]
    call sym_at
    mov rcx, [rax + Scope.varnames + Buf.len]
    test rcx, rcx
    jz .bad_context
    mov rax, [rax + Scope.varnames + Buf.data]
    mov rdx, [rax]
    mov rdi, rbx
    mov rsi, r12
    mov ecx, CTX_LOAD
    xor r8d, r8d
    call cg_nameop
    test eax, eax
    jz .err
    mov qword [rbp - ZS_TWOARG], 0
    jmp .emit

.explicit:
    mov qword [rbp - ZS_I], 0
.explicit_loop:
    mov rax, [rbp - ZS_I]
    cmp rax, 2
    jae .two_done
    mov rdi, rbx
    mov rsi, [rbp - ZS_CALL]
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - ZS_I]
    mov rdi, rbx
    call ast_child
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .err
    inc qword [rbp - ZS_I]
    jmp .explicit_loop
.two_done:
    mov qword [rbp - ZS_TWOARG], 2

.emit:
    mov rdi, rbx
    mov rsi, [rbp - ZS_ATTR]
    call ast_at
    mov esi, [rax + AstNode.b]
    mov rdi, rbx
    call ast_obj_at
    mov rdi, r12
    mov rsi, rax
    call cg_name
    shl rax, 2
    or rax, [rbp - ZS_TWOARG]
    or rax, [rbp - ZS_METH]
    mov rdx, rax
    mov rdi, r12
    mov esi, OP_LOAD_SUPER_ATTR
    mov rcx, [rbp - ZS_LINE]
    call cg_emit
    mov eax, 1
    jmp .ret

.bad_context:
    mov rdi, rbx
    CSTRING rsi, "super(): no arguments and no enclosing method"
    call cg_error
.err:
    mov rax, -1
    jmp .ret
.no:
    xor eax, eax
.ret:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_super_attr

section .rodata
cg_super_name:    db "super", 0
cg_classvar_name: db "__class__", 0
section .text

;; ============================================================================
;; cg_call_has_keyword(Comp *c, uint32_t call) -> rax = 1 if any named argument
;; ============================================================================
; DEF_FUNC_BARE, not DEF_FUNC: this tail-jumps into another function that sets
; up its own frame, so pushing rbp here would leak it.
DEF_FUNC_BARE cg_call_has_keyword
    mov edx, AST_KEYWORD
    jmp cg_has_star
END_FUNC cg_call_has_keyword

;; ============================================================================
;; cg_kwnames_tuple(Comp *c, uint32_t call) -> rax = an owned tuple Value, or 0
;;
;; The names of the trailing keyword arguments, in order, as one constant.  The
;; tuple takes its own reference to each name, so it survives independently of
;; the compilation that produced it.
;; ============================================================================
KT_TUP   equ 24
KT_I     equ 32
KT_N     equ 40
KT_K     equ 48
KT_FRAME equ 56          ; + 3 pushes = 80
DEF_FUNC cg_kwnames_tuple, KT_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r13, rsi

    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov ecx, [rax + AstNode.nchild]
    mov [rbp - KT_N], rcx

    ; Count the keyword arguments first, so the tuple is sized exactly.
    xor r12d, r12d
    mov qword [rbp - KT_I], 0
.count:
    mov rax, [rbp - KT_I]
    cmp rax, [rbp - KT_N]
    jae .counted
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - KT_I]
    mov rdi, rbx
    call ast_child
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    movzx eax, byte [rax + AstNode.kind]
    cmp eax, AST_KEYWORD
    jne .count_next
    inc r12
.count_next:
    inc qword [rbp - KT_I]
    jmp .count
.counted:

    mov rdi, r12
    call tuple_new
    test rax, rax
    jz .fail
    mov [rbp - KT_TUP], rax

    mov qword [rbp - KT_I], 0
    mov qword [rbp - KT_K], 0
.fill:
    mov rax, [rbp - KT_I]
    cmp rax, [rbp - KT_N]
    jae .done
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - KT_I]
    mov rdi, rbx
    call ast_child
    mov r12, rax
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    movzx ecx, byte [rax + AstNode.kind]
    cmp ecx, AST_KEYWORD
    jne .fill_next
    mov esi, [rax + AstNode.a]
    mov rdi, rbx
    call ast_obj_at
    mov rdx, [rbp - KT_TUP]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov rcx, [rbp - KT_K]
    mov [rdx + rcx*8], rax
    INCREF_V rax, rdx
    inc qword [rbp - KT_K]
.fill_next:
    inc qword [rbp - KT_I]
    jmp .fill
.done:
    mov rax, [rbp - KT_TUP]
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
END_FUNC cg_kwnames_tuple

;; ============================================================================
;; cg_call_args_only(Comp *c, CompUnit *u, uint32_t call) -> rax = argument
;;   count, or -1 on error
;;
;; The positional and keyword arguments of a parsed call, without the callable
;; or the CALL itself.  The class statement's base list is an argument list, so
;; it reuses this rather than a near-copy; a keyword there is `metaclass=M`,
;; which __build_class__ takes like any other.
;;
;; rcx = 1 when this is a PEP 695 class's base list, which gets one more
;; positional base -- Generic[*type_params] -- emitted after the last written
;; one and BEFORE the first keyword.  Only this loop knows where that seam
;; is, which is why the flag comes here rather than staying with the caller.
;; ============================================================================
CA_I     equ 32
CA_N     equ 40
CA_LINE  equ 48
CA_NKW   equ 56
CA_GENERIC equ 64        ; PEP 695: one extra positional base is owed
CA_NPOS  equ 72          ; how many positional ones are on the stack
CA_KWNODE equ 80         ; the keyword node, across the call that pays the
                         ; PEP 695 base -- a slot rather than a push, because
                         ; a push here flips the parity the calls inside that
                         ; subroutine were aligned for
CA_EXTRA equ 88          ; the PEP 695 base, counted apart from CA_N -- which
                         ; is the LOOP BOUND, so adding to it walks one child
                         ; past the end and hands cg_expr a node that is not
                         ; one
CA_FRAME equ 104         ; + 3 pushes = 128
DEF_FUNC cg_call_args_only, CA_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rbp - CA_GENERIC], rcx
    mov qword [rbp - CA_NPOS], 0
    mov qword [rbp - CA_EXTRA], 0
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov ecx, [rax + AstNode.nchild]
    mov [rbp - CA_N], rcx
    mov ecx, [rax + AstNode.lineno]
    mov [rbp - CA_LINE], rcx
    mov qword [rbp - CA_NKW], 0
    mov qword [rbp - CA_I], 0
.loop:
    mov rax, [rbp - CA_I]
    cmp rax, [rbp - CA_N]
    jae .kwnames
    mov rdi, rbx
    mov rsi, r13
    call ast_at
    mov rsi, rax
    mov rdx, [rbp - CA_I]
    mov rdi, rbx
    call ast_child
    mov r13, r13
    mov rdx, rax
    push rdx
    mov rdi, rbx
    mov rsi, rax
    call ast_at
    movzx eax, byte [rax + AstNode.kind]
    pop rdx
    cmp eax, AST_KEYWORD
    je .keyword
    cmp eax, AST_STARRED
    je .unsupported
    cmp eax, AST_DOUBLESTARRED
    je .unsupported
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    inc qword [rbp - CA_NPOS]
    jmp .next
.keyword:
    ; rdx is the keyword node and .pay_generic calls through to cg_emit.
    mov [rbp - CA_KWNODE], rdx
    call .pay_generic                   ; before the first keyword, if owed
    mov rdx, [rbp - CA_KWNODE]
    mov rdi, rbx
    mov rsi, rdx
    call ast_at
    mov edx, [rax + AstNode.b]
    mov rdi, rbx
    mov rsi, r12
    call cg_expr
    test eax, eax
    jz .fail
    inc qword [rbp - CA_NKW]
.next:
    inc qword [rbp - CA_I]
    jmp .loop

.kwnames:
    call .pay_generic                   ; no keywords at all: it goes last
    cmp qword [rbp - CA_NKW], 0
    je .done
    mov rdi, rbx
    mov rsi, r13
    call cg_kwnames_tuple
    test rax, rax
    jz .fail
    ; The tuple is owned and cg_const stores a borrowed reference, so hand it
    ; to the arena: comp_free releases it however the compilation ended.
    mov rdi, rbx
    mov rsi, rax
    call comp_keep
    mov rdi, r12
    mov rsi, rax
    call cg_const
    mov rdx, rax
    mov rdi, r12
    mov esi, OP_KW_NAMES
    mov rcx, [rbp - CA_LINE]
    call cg_emit
    jmp .done

;; The PEP 695 extra base, paid once, at whichever seam comes first: just
;; before the first keyword argument, or after the last positional when there
;; are no keywords.  A local subroutine because both sites want it and
;; neither is the other's fallthrough.
.pay_generic:
    cmp qword [rbp - CA_GENERIC], 0
    je .pg_done
    mov qword [rbp - CA_GENERIC], 0     ; once
    sub rsp, 8
    mov rdi, r12
    mov esi, [rbp - CA_NPOS]
    mov rdx, [rbp - CA_LINE]
    extern cg_emit_generic_base
    call cg_emit_generic_base
    add rsp, 8
    inc qword [rbp - CA_NPOS]
    inc qword [rbp - CA_EXTRA]          ; it is an argument like any other
.pg_done:
    ret

.done:
    mov rax, [rbp - CA_N]
    add rax, [rbp - CA_EXTRA]
    jmp .ret
.unsupported:
    mov rdi, rbx
    CSTRING rsi, "unpacking is not supported in a class base list"
    call cg_error
.fail:
    mov rax, -1
.ret:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC cg_call_args_only

section .rodata

;; COMPARE_OP oparg = (index << 4) | mask.  apython reads only the high nibble,
;; but CPython's exact bytes are emitted so a disassembly diff stays clean.
align 8
cmp_oparg_table:
    db 2        ; <
    db 26       ; <=
    db 40       ; ==
    db 55       ; !=
    db 68       ; >
    db 92       ; >=

;; AST kind -> expression emitter.  A zero entry means "not an expression, or
;; not implemented yet", and cg_expr reports it rather than emitting nothing.
align 8
cg_expr_table:
    dq 0                ;  0 AST_NULL
    dq cg_e_const       ;  1 AST_CONST
    dq cg_e_name        ;  2 AST_NAME
    dq cg_e_binop       ;  3 AST_BINOP
    dq cg_e_unaryop     ;  4 AST_UNARYOP
    dq cg_e_boolop      ;  5 AST_BOOLOP
    dq cg_e_compare     ;  6 AST_COMPARE
    dq cg_e_ifexp       ;  7 AST_IFEXP
    dq cg_e_lambda                     ;  8 AST_LAMBDA
    dq cg_e_seq         ;  9 AST_TUPLE
    dq cg_e_seq         ; 10 AST_LIST
    dq cg_e_seq         ; 11 AST_SET
    dq cg_e_dict        ; 12 AST_DICT
    dq cg_e_call        ; 13 AST_CALL
    dq cg_e_attribute   ; 14 AST_ATTRIBUTE
    dq cg_e_subscript   ; 15 AST_SUBSCRIPT
    dq cg_e_slice       ; 16 AST_SLICE
    dq 0                ; 17 AST_STARRED
    dq 0                ; 18 AST_DOUBLESTARRED
    dq 0                ; 19 AST_KEYWORD
    dq cg_e_namedexpr   ; 20 AST_NAMEDEXPR
    dq cg_e_yield                      ; 21 AST_YIELD
    dq cg_e_yieldfrom                  ; 22 AST_YIELDFROM
    dq cg_e_await       ; 23 AST_AWAIT
    dq cg_e_joinedstr                  ; 24 AST_JOINEDSTR
    dq cg_e_formattedvalue                ; 25 AST_FORMATTEDVALUE
    dq cg_e_comprehension                ; 26 AST_LISTCOMP
    dq cg_e_comprehension                ; 27 AST_SETCOMP
    dq cg_e_comprehension                ; 28 AST_DICTCOMP
    dq cg_e_comprehension                ; 29 AST_GENEXP
    dq 0                ; 30 AST_COMPREHENSION
    times (AST_COUNT - 31) dq 0

ASM_INIT

section .rodata
cg_qn_empty:  db "", 0
cg_qn_dot:    db ".", 0
cg_qn_locals: db ".<locals>.", 0
