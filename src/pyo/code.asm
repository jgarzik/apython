; pyo/code.asm - Code object type

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

extern exc_TypeError_type
extern exc_IndexError_type
extern raise_exception
extern none_singleton
extern ap_free
extern ap_malloc
extern ap_memcpy
extern ap_memset
extern ap_strcmp
extern obj_decref
extern obj_dealloc
extern obj_incref
extern str_from_cstr
extern type_type
extern obj_as_index
extern bytes_type
extern tuple_type
extern str_type
; code objects are not GC-tracked (allocated by marshal via ap_malloc)

; --- code_new frame layout ---
CN_SPEC  equ 8
CN_CODE  equ 16
CN_FRAME equ 16             ; + 2 pushes = 32

;; ============================================================================
;; code_new(CodeSpec *spec) -> PyCodeObject*
;;
;; The runtime code-object constructor, used by the source compiler.  Mirrors
;; mdo_code (src/marshal.asm:850) field for field; the two are the only places
;; that build a PyCodeObject, and they must stay in step.
;;
;; Every object reference in the spec is STOLEN.  On the error path the caller
;; calls code_spec_clear(spec) instead, which releases exactly the same set.
;;
;; Two things the layout forces, both of which are silent if got wrong:
;;   - The bytecode lives INLINE at +128.  eval_frame does
;;     `lea rbx, [rax + PyCodeObject.co_code]`, so it cannot be a separate
;;     bytes object.  It must also be writable heap: the interpreter rewrites
;;     opcodes in place to specialize them (opcodes_build.asm:970 turns
;;     FOR_ITER into FOR_ITER_RANGE), so no two code objects may share it.
;;   - CODE_TAIL_PAD zero bytes follow it.  op_load_global writes eight bytes
;;     of inline cache at [rbx+2..rbx+7] and op_compare_op reads byte [rbx+2];
;;     either can sit on the last instruction of the object.
;; ============================================================================

;; ============================================================================
;; code_traverse
;;
;; A code object holds nine owned objects, and one of them -- co_consts -- can
;; hold another code object.  With no tp_traverse the collector could not see
;; through any of them, so a module's code holding a function's code holding
;; a reference back through func_globals was a cycle it could not break.
;;
;; The nine are not contiguous: co_code_len, co_posonlyargcount and
;; co_firstlineno sit between co_exceptiontable and co_linetable, so this
;; cannot be a strided loop the way code_spec_clear is.
;; ============================================================================
global code_traverse
DEF_FUNC code_traverse, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyCodeObject.co_consts]
    VISIT_PTR rdi
    mov rdi, [rbx + PyCodeObject.co_names]
    VISIT_PTR rdi
    mov rdi, [rbx + PyCodeObject.co_localsplusnames]
    VISIT_PTR rdi
    mov rdi, [rbx + PyCodeObject.co_localspluskinds]
    VISIT_PTR rdi
    mov rdi, [rbx + PyCodeObject.co_filename]
    VISIT_PTR rdi
    mov rdi, [rbx + PyCodeObject.co_name]
    VISIT_PTR rdi
    mov rdi, [rbx + PyCodeObject.co_qualname]
    VISIT_PTR rdi
    mov rdi, [rbx + PyCodeObject.co_exceptiontable]
    VISIT_PTR rdi
    mov rdi, [rbx + PyCodeObject.co_linetable]
    VISIT_PTR rdi
    pop rbx
    leave
    ret
END_FUNC code_traverse

;; No tp_clear.  Clearing co_consts is not something a code object can
;; survive: a generator suspended on it keeps the code alive through its frame,
;; and closing that generator later in the same collection -- gen_dealloc runs
;; its finally blocks -- re-enters eval_frame, which loads r14 from co_consts
;; and faulted on the NULL.  Nor does it break anything: co_consts holds
;; constants -- str, bytes, numbers, tuples, frozensets, other code objects --
;; none of which can refer back to the code, so a cycle through a code object
;; is always closed by a function, cell or dict, and their tp_clear breaks it.
;; CPython does not track code objects at all; tracking stays here so the
;; collector can see through co_consts, but nothing is torn down from under a
;; live frame.

DEF_FUNC code_new, CN_FRAME
    push rbx
    push r12

    mov [rbp - CN_SPEC], rdi
    mov rbx, rdi                            ; rbx = spec

    ; ap_malloc(sizeof(header) + code_len + CODE_TAIL_PAD)
    mov rdi, [rbx + CodeSpec.code_len]
    add rdi, PyCodeObject.co_code + CODE_TAIL_PAD
    lea rsi, [rel code_type]
    extern gc_alloc
    call gc_alloc                           ; fatal on OOM, never returns NULL
    mov r12, rax
    mov [rbp - CN_CODE], rax

    ; --- object header ---
    mov qword [r12 + PyObject.ob_refcnt], 1
    lea rax, [rel code_type]
    mov [r12 + PyObject.ob_type], rax

    ; --- scalar fields ---
    mov eax, [rbx + CodeSpec.argcount]
    mov [r12 + PyCodeObject.co_argcount], eax
    mov eax, [rbx + CodeSpec.kwonlyargcount]
    mov [r12 + PyCodeObject.co_kwonlyargcount], eax
    mov eax, [rbx + CodeSpec.posonlyargcount]
    mov [r12 + PyCodeObject.co_posonlyargcount], eax
    mov eax, [rbx + CodeSpec.stacksize]
    mov [r12 + PyCodeObject.co_stacksize], eax
    mov eax, [rbx + CodeSpec.flags]
    mov [r12 + PyCodeObject.co_flags], eax
    mov eax, [rbx + CodeSpec.firstlineno]
    mov [r12 + PyCodeObject.co_firstlineno], eax
    mov dword [r12 + PyCodeObject.co_pad0], 0

    ; co_nlocals is DERIVED from the kinds, not taken from the spec: it is the
    ; number of CO_FAST_LOCAL slots, which is exactly len(co_varnames), and
    ; CPython guarantees the two agree.  Deriving it here is what makes that
    ; hold for a .pyc as well as for our own compiler -- 3.12's marshal does
    ; not store the count at all, and the spec's own field carried
    ; len(varnames), which over-counts a local a nested block captured.
    xor eax, eax
    mov rdx, [rbx + CodeSpec.localspluskinds]
    test rdx, rdx
    jz .nlocals_done
    mov rcx, [rdx + PyBytesObject.ob_size]
    xor esi, esi
.nlocals_scan:
    cmp rsi, rcx
    jae .nlocals_done
    test byte [rdx + PyBytesObject.data + rsi], CO_FAST_LOCAL
    jz .nlocals_next
    inc eax
.nlocals_next:
    inc rsi
    jmp .nlocals_scan
.nlocals_done:
    mov [r12 + PyCodeObject.co_nlocals], eax

    ; co_nlocalsplus is derived from the tuple, exactly as marshal derives it
    xor eax, eax
    mov rdx, [rbx + CodeSpec.localsplusnames]
    test rdx, rdx
    jz .no_lpnames
    mov eax, [rdx + PyVarObject.ob_size]
.no_lpnames:
    mov [r12 + PyCodeObject.co_nlocalsplus], eax

    ; --- object fields: references are stolen, so no INCREF ---
    mov rax, [rbx + CodeSpec.consts]
    mov [r12 + PyCodeObject.co_consts], rax
    mov rax, [rbx + CodeSpec.names]
    mov [r12 + PyCodeObject.co_names], rax
    mov rax, [rbx + CodeSpec.localsplusnames]
    mov [r12 + PyCodeObject.co_localsplusnames], rax
    mov rax, [rbx + CodeSpec.localspluskinds]
    mov [r12 + PyCodeObject.co_localspluskinds], rax
    mov rax, [rbx + CodeSpec.filename]
    mov [r12 + PyCodeObject.co_filename], rax
    mov rax, [rbx + CodeSpec.name]
    mov [r12 + PyCodeObject.co_name], rax
    mov rax, [rbx + CodeSpec.qualname]
    mov [r12 + PyCodeObject.co_qualname], rax
    mov rax, [rbx + CodeSpec.exceptiontable]
    mov [r12 + PyCodeObject.co_exceptiontable], rax
    mov rax, [rbx + CodeSpec.linetable]
    mov [r12 + PyCodeObject.co_linetable], rax

    ; --- bytecode, copied inline, then the zeroed tail ---
    mov rax, [rbx + CodeSpec.code_len]
    mov [r12 + PyCodeObject.co_code_len], eax

    lea rdi, [r12 + PyCodeObject.co_code]
    mov rsi, [rbx + CodeSpec.code_bytes]
    mov rdx, [rbx + CodeSpec.code_len]
    test rdx, rdx
    jz .no_code
    call ap_memcpy
.no_code:
    lea rdi, [r12 + PyCodeObject.co_code]
    add rdi, [rbx + CodeSpec.code_len]
    xor esi, esi
    mov edx, CODE_TAIL_PAD
    call ap_memset

    ; gc_track only now: it can trigger a collection, and the traverse would
    ; walk fields that were not yet written.
    mov rdi, r12
    extern gc_track
    call gc_track

    mov rax, r12
    pop r12
    pop rbx
    leave
    ret
END_FUNC code_new

;; ============================================================================
;; code_spec_clear(CodeSpec *spec)
;; Release every object reference the spec holds and zero the slots.  This is
;; the single error path for a half-built spec: because code_new steals exactly
;; this set, "call code_new" and "call code_spec_clear" are the only two ways a
;; spec can be disposed of, and neither can double-free the other's references.
;; ============================================================================
DEF_FUNC code_spec_clear
    push rbx
    push r12
    mov rbx, rdi
    lea r12, [rbx + CodeSpec.consts]        ; first object slot
.loop:
    lea rax, [rbx + CodeSpec.linetable]
    cmp r12, rax
    ja .done
    mov rdi, [r12]
    test rdi, rdi
    jz .next
    mov qword [r12], 0
    call obj_decref
.next:
    add r12, 8
    jmp .loop
.done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC code_spec_clear

;; ============================================================================
;; code_dealloc(PyObject *self)
;; Free code object and decref contained objects
;; ============================================================================
DEF_FUNC code_dealloc, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    mov rbx, rdi

    ; co_consts is a fat tuple — just DECREF it (tuple_dealloc handles elements)
    mov rdi, [rbx + PyCodeObject.co_consts]
    test rdi, rdi
    jz .skip_consts
    call obj_decref
.skip_consts:

    ; DECREF co_names
    mov rdi, [rbx + PyCodeObject.co_names]
    test rdi, rdi
    jz .skip_names
    call obj_decref
.skip_names:

    ; DECREF co_localsplusnames
    mov rdi, [rbx + PyCodeObject.co_localsplusnames]
    test rdi, rdi
    jz .skip_locals
    call obj_decref
.skip_locals:

    ; DECREF co_localspluskinds
    mov rdi, [rbx + PyCodeObject.co_localspluskinds]
    test rdi, rdi
    jz .skip_kinds
    call obj_decref
.skip_kinds:

    ; DECREF co_linetable
    mov rdi, [rbx + PyCodeObject.co_linetable]
    test rdi, rdi
    jz .skip_linetable
    call obj_decref
.skip_linetable:

    ; DECREF co_filename
    mov rdi, [rbx + PyCodeObject.co_filename]
    test rdi, rdi
    jz .skip_filename
    call obj_decref
.skip_filename:

    ; DECREF co_name
    mov rdi, [rbx + PyCodeObject.co_name]
    test rdi, rdi
    jz .skip_name
    call obj_decref
.skip_name:

    ; DECREF co_qualname
    mov rdi, [rbx + PyCodeObject.co_qualname]
    test rdi, rdi
    jz .skip_qualname
    call obj_decref
.skip_qualname:

    ; DECREF co_exceptiontable
    mov rdi, [rbx + PyCodeObject.co_exceptiontable]
    test rdi, rdi
    jz .skip_exc
    call obj_decref
.skip_exc:

    ; Free the code object itself
    mov rdi, rbx
    extern gc_dealloc
    call gc_dealloc

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC code_dealloc

;; ============================================================================
;; code_repr(PyObject *self) -> PyStrObject*
;; ============================================================================
DEF_FUNC_BARE code_repr
    lea rdi, [rel code_repr_str]
    jmp str_from_cstr
END_FUNC code_repr

;; ============================================================================
;; code_getattr(PyCodeObject *self, PyObject *name) -> (rax, edx) or NULL
;; rdi = code object, rsi = name string

;; ============================================================================
;; code_names_of_kind(rdi = a code object, esi = a CO_FAST_* mask)
;;   -> rax = a new tuple of the co_localsplusnames whose kind has that bit,
;;      or 0 on an allocation failure
;;
;; This code object keeps ONE co_localsplusnames with a parallel
;; co_localspluskinds saying which of local, cell and free each entry is --
;; the 3.11 layout, and what the frame's localsplus is addressed by.  CPython
;; keeps three tuples and hands them out directly, so co_varnames,
;; co_cellvars and co_freevars are each a FILTER over the pair here.
;;
;; co_varnames answered the whole of co_localsplusnames, cells and frees
;; included -- `('a','b','z')` where CPython says `('a','b')` -- and the other
;; two were published in the type's dict by init_attrs and then refused as
;; "attribute is not readable", which is exactly what that file's own header
;; forbids.
;;
;; An entry may carry two bits: an argument a nested function captures is both
;; CO_FAST_LOCAL and CO_FAST_CELL, and CPython lists it in co_varnames and in
;; co_cellvars both.  A mask test rather than an equality is what gets that.
;; ============================================================================
CNK_CODE  equ 8
CNK_MASK  equ 16
CNK_TUP   equ 24
CNK_N     equ 32
CNK_FRAME equ 40            ; + 3 pushes = 64, 16-aligned
DEF_FUNC_LOCAL code_names_of_kind, CNK_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - CNK_CODE], rdi
    mov [rbp - CNK_MASK], rsi

    ; Count first: a tuple is allocated at its final size.
    mov rbx, [rdi + PyCodeObject.co_localspluskinds]
    mov r12, [rdi + PyCodeObject.co_localsplusnames]
    xor r13d, r13d                  ; how many match
    test rbx, rbx
    jz .cnk_have_count
    test r12, r12
    jz .cnk_have_count
    mov rcx, [rbx + PyBytesObject.ob_size]
    xor edx, edx
.cnk_count:
    cmp rdx, rcx
    jae .cnk_have_count
    movzx eax, byte [rbx + PyBytesObject.data + rdx]
    test eax, [rbp - CNK_MASK]
    jz .cnk_count_next
    inc r13
.cnk_count_next:
    inc rdx
    jmp .cnk_count
.cnk_have_count:
    mov [rbp - CNK_N], r13

    mov rdi, r13
    call tuple_new
    test rax, rax
    jz .cnk_fail
    mov [rbp - CNK_TUP], rax
    cmp qword [rbp - CNK_N], 0
    je .cnk_done

    mov rbx, [rbp - CNK_CODE]
    mov r12, [rbx + PyCodeObject.co_localsplusnames]
    mov rbx, [rbx + PyCodeObject.co_localspluskinds]
    mov rax, [rbp - CNK_TUP]
    mov r8, [rax + PyTupleObject.ob_item]
    mov r9, [r12 + PyTupleObject.ob_item]
    mov rcx, [rbx + PyBytesObject.ob_size]
    xor edx, edx
    xor r13d, r13d                  ; write index
.cnk_fill:
    cmp rdx, rcx
    jae .cnk_done
    movzx eax, byte [rbx + PyBytesObject.data + rdx]
    test eax, [rbp - CNK_MASK]
    jz .cnk_fill_next
    mov rax, [r9 + rdx*8]
    mov [r8 + r13*8], rax
    INCREF_V rax, rsi
    inc r13
.cnk_fill_next:
    inc rdx
    jmp .cnk_fill
.cnk_done:
    mov rax, [rbp - CNK_TUP]
    pop r13
    pop r12
    pop rbx
    leave
    ret
.cnk_fail:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC code_names_of_kind

;; ============================================================================
;; code_getattr(rdi = a code object, rsi = the name) -> rax = a Value, owned,
;;     or 0 for "no such attribute"
;;
;; tp_getattr.  co_varnames, co_cellvars and co_freevars are filters over
;; co_localsplusnames (see code_names_of_kind); co_positions and co_lines are
;; methods; co_code is built on demand because the bytecode lives inside the
;; object; and everything else is a straight field read through
;; code_attr_table.
;; ============================================================================
DEF_FUNC code_getattr
    push rbx
    push r12

    mov rbx, rdi            ; rbx = code
    mov r12, rsi            ; r12 = name

    ; Check for co_kwonlyargcount
    lea rdi, [rel co_attr_kwonlyargcount]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_kwonlyargcount

    ; Check for co_argcount
    lea rdi, [rel co_attr_argcount]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_argcount

    ; co_varnames, co_cellvars and co_freevars are each a FILTER over the one
    ; co_localsplusnames this code object keeps, by the parallel kinds string.
    lea rdi, [rel co_attr_varnames]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_varnames

    lea rdi, [rel co_attr_cellvars]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_cellvars

    lea rdi, [rel co_attr_freevars]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_freevars

    ; co_positions() is a method, not a field.
    lea rdi, [rel co_attr_positions]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_positions

    ; and so is co_lines(), which dis, trace and inspect all walk.
    lea rdi, [rel co_attr_lines]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_lines

    ; _varname_from_oparg(i), which is how dis names the operand of
    ; LOAD_FAST and its family: the oparg indexes co_localsplusnames, not
    ; co_varnames, so a cell or a free variable is reached by the same number.
    lea rdi, [rel co_attr_varname]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_varname

    ; co_code is the bytecode, and it lives INSIDE the code object rather
    ; than behind a pointer -- so it is a copy, made on demand.  dis reads it.
    lea rdi, [rel co_n_code]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_code

    ; co_lnotab is the pre-3.10 line table, computed on demand from the
    ; modern one.  Deprecated since 3.12 and still read: coverage.py,
    ; some debuggers, and test_code itself.
    lea rdi, [rel co_n_lnotab]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_lnotab

    ; Check for replace
    lea rdi, [rel cr_attr_replace]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_replace

    ; Everything else is a straight field read.  Only three of the seventeen
    ; co_* were reachable from Python, which is most of what inspect,
    ; dataclasses and traceback formatting want from a code object.
    lea r8, [rel code_attr_table]
.cg_scan:
    mov rdi, [r8]                   ; name cstr, 0 terminates the table
    test rdi, rdi
    jz .cg_not_found
    push r8
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    pop r8
    test eax, eax
    jz .cg_found
    add r8, 24
    jmp .cg_scan

.cg_found:
    mov rcx, [r8 + 8]               ; byte offset into PyCodeObject
    mov rdx, [r8 + 16]              ; 0 = qword ptr, 1 = dword int
    test rdx, rdx
    jnz .cg_int_field
    mov rax, [rbx + rcx]
    test rax, rax
    jz .cg_none
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.cg_none:
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.cg_int_field:
    movsxd rax, dword [rbx + rcx]
    mov edx, TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.cg_not_found:
    ; Not found
    RET_NULL
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.return_replace:
    ; Bound too, for the same reason: `co.replace` names its own code object.
    call _get_co_replace_builtin
    mov rdi, rax
    mov rsi, rbx
    call method_new
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.return_lnotab:
    mov rdi, rbx
    call code_build_lnotab
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.return_code:
    lea rdi, [rbx + PyCodeObject.co_code]
    mov esi, [rbx + PyCodeObject.co_code_len]
    extern bytes_from_data
    call bytes_from_data
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.return_lines:
    call _get_co_lines_builtin
    mov rdi, rax
    mov rsi, rbx
    call method_new
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.return_varname:
    call _get_varname_builtin
    mov rdi, rax
    mov rsi, rbx
    call method_new
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.return_positions:
    ; A *bound* method: `code.co_positions()` and `f = code.co_positions`
    ; must both know which code object they belong to.
    call _get_co_positions_builtin
    mov rdi, rax
    mov rsi, rbx
    extern method_new
    call method_new
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.return_kwonlyargcount:
    movsxd rax, dword [rbx + PyCodeObject.co_kwonlyargcount]
    mov edx, TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.return_argcount:
    movsxd rax, dword [rbx + PyCodeObject.co_argcount]
    mov edx, TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.return_varnames:
    mov esi, CO_FAST_LOCAL
    jmp .return_of_kind
.return_cellvars:
    mov esi, CO_FAST_CELL
    jmp .return_of_kind
.return_freevars:
    mov esi, CO_FAST_FREE
.return_of_kind:
    mov rdi, rbx
    call code_names_of_kind
    test rax, rax
    jz .return_none
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.return_none:
    xor eax, eax
    RET_NONE
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC code_getattr

;; ============================================================================
;; code.co_positions() -> an iterable of (lineno, end_lineno, col, end_col)
;;
;; CPython's traceback.py calls this on every traceback entry, to underline
;; the failing expression.  This tree records lines and not columns yet (the
;; caret work is its own job), and CPython's own format allows None for a
;; missing column -- so what comes back is one (line, line, None, None) per
;; code unit, which is enough for traceback.py to run and gives it exactly
;; the information there is.
;;
;; A list rather than a generator: the caller indexes into it with
;; islice, and a list is the shortest thing that supports that.
;; ============================================================================
CPO_CODE  equ 8
CPO_LIST  equ 16
CPO_I     equ 24
CPO_N     equ 32
CPO_TUP   equ 40
; The four out-slots code_addr2location fills, ASCENDING from CPO_L0.
CPO_L0    equ 80            ; start line
CPO_L1    equ 72            ; end line
CPO_L2    equ 64            ; start column, or -1
CPO_L3    equ 56            ; end column, or -1
CPO_CUR   equ 120           ; the three-word resume cursor, ascending from here
CPO_FRAME equ 128           ; + 0 pushes = 128
DEF_FUNC code_method_co_positions, CPO_FRAME
    cmp rsi, 1                  ; bound, so self is the only argument
    jne .cpo_args
    mov rdi, [rdi]
    mov [rbp - CPO_CODE], rdi
    mov eax, [rdi + PyCodeObject.co_code_len]
    shr eax, 1                  ; code units, two bytes each
    mov [rbp - CPO_N], rax

    mov rdi, rax
    extern list_new
    call list_new
    test rax, rax
    jz .cpo_failed
    mov [rbp - CPO_LIST], rax
    mov qword [rbp - CPO_I], 0
    ; The walk asks about ascending offsets, so it carries a cursor: without
    ; one, every code unit rescans the whole line table and co_positions()
    ; costs the square of the code object's length.
    mov qword [rbp - CPO_CUR], 0
    mov qword [rbp - CPO_CUR + 8], 0
    mov qword [rbp - CPO_CUR + 16], 0

.cpo_loop:
    mov rax, [rbp - CPO_I]
    cmp rax, [rbp - CPO_N]
    jge .cpo_done
    ; What a table miss should read as: line 0 and no columns.
    mov qword [rbp - CPO_L0], 0
    mov qword [rbp - CPO_L1], 0
    mov qword [rbp - CPO_L2], -1
    mov qword [rbp - CPO_L3], -1
    mov rdi, [rbp - CPO_CODE]
    mov rsi, rax
    lea rdx, [rbp - CPO_L0]
    lea rcx, [rbp - CPO_CUR]
    extern code_addr2location_at
    call code_addr2location_at

    mov edi, 4
    extern tuple_new
    call tuple_new
    test rax, rax
    jz .cpo_drop
    mov [rbp - CPO_TUP], rax
    mov rdx, [rax + PyTupleObject.ob_item]
    ; A -1 line is a NO_LOCATION entry, and CPython reports None for all
    ; four of its fields, not just the columns.
    mov rcx, [rbp - CPO_L0]
    test rcx, rcx
    jns .cpo_l0
    LOAD_NONE rcx
    jmp .cpo_l0_set
.cpo_l0:
    V_PACK_I64 rcx, r8
.cpo_l0_set:
    mov [rdx], rcx
    mov rcx, [rbp - CPO_L1]
    test rcx, rcx
    jns .cpo_l1
    LOAD_NONE rcx
    jmp .cpo_l1_set
.cpo_l1:
    V_PACK_I64 rcx, r8
.cpo_l1_set:
    mov [rdx + 8], rcx
    mov rcx, [rbp - CPO_L2]
    test rcx, rcx
    jns .cpo_c2
    LOAD_NONE rcx
    jmp .cpo_c2_set
.cpo_c2:
    V_PACK_I64 rcx, r8
.cpo_c2_set:
    mov [rdx + 16], rcx
    mov rcx, [rbp - CPO_L3]
    test rcx, rcx
    jns .cpo_c3
    LOAD_NONE rcx
    jmp .cpo_c3_set
.cpo_c3:
    V_PACK_I64 rcx, r8
.cpo_c3_set:
    mov [rdx + 24], rcx
    mov rax, [rbp - CPO_TUP]

    push rax
    sub rsp, 8
    mov rdi, [rbp - CPO_LIST]
    mov rsi, rax
    extern list_append
    call list_append
    add rsp, 8
    pop rdi
    extern obj_decref
    call obj_decref             ; list_append took its own reference
    inc qword [rbp - CPO_I]
    jmp .cpo_loop

.cpo_done:
    mov rax, [rbp - CPO_LIST]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.cpo_drop:
    mov rdi, [rbp - CPO_LIST]
    call obj_decref
.cpo_failed:
    xor eax, eax
    leave
    ret
.cpo_args:
    RAISE exc_TypeError_type, "co_positions() takes no arguments"
END_FUNC code_method_co_positions

section .rodata
align 8
; {name, offset, is_int} -- 0 name terminates
co_n_name:        db "co_name", 0
co_n_qualname:    db "co_qualname", 0
co_n_filename:    db "co_filename", 0
co_n_consts:      db "co_consts", 0
co_n_names:       db "co_names", 0
co_n_localsplusnames: db "co_localsplusnames", 0
co_n_firstlineno: db "co_firstlineno", 0
co_n_flags:       db "co_flags", 0
co_n_nlocals:     db "co_nlocals", 0
co_n_stacksize:   db "co_stacksize", 0
co_n_posonly:     db "co_posonlyargcount", 0
co_n_linetable:   db "co_linetable", 0
co_n_lnotab:      db "co_lnotab", 0
co_n_exctable:    db "co_exceptiontable", 0
co_n_code:        db "co_code", 0
align 8
code_attr_table:
    dq co_n_name,        PyCodeObject.co_name,        0
    dq co_n_qualname,    PyCodeObject.co_qualname,    0
    dq co_n_filename,    PyCodeObject.co_filename,    0
    dq co_n_consts,      PyCodeObject.co_consts,      0
    dq co_n_names,       PyCodeObject.co_names,       0
    dq co_n_localsplusnames, PyCodeObject.co_localsplusnames, 0
    dq co_n_firstlineno, PyCodeObject.co_firstlineno, 1
    dq co_n_flags,       PyCodeObject.co_flags,       1
    dq co_n_nlocals,     PyCodeObject.co_nlocals,     1
    dq co_n_stacksize,   PyCodeObject.co_stacksize,   1
    dq co_n_posonly,     PyCodeObject.co_posonlyargcount, 1
    dq co_n_linetable,   PyCodeObject.co_linetable,   0
    dq co_n_exctable,    PyCodeObject.co_exceptiontable, 0
    dq 0, 0, 0
section .text


section .data

co_attr_kwonlyargcount: db "co_kwonlyargcount", 0
co_attr_argcount:       db "co_argcount", 0
co_attr_varnames:       db "co_varnames", 0
co_attr_cellvars:       db "co_cellvars", 0
co_attr_freevars:       db "co_freevars", 0
code_repr_str: db "<code object>", 0
code_type_name: db "code", 0

; code type object
align 8
global code_type
code_type:
    dq 1                ; ob_refcnt
    dq type_type        ; ob_type
    dq code_type_name   ; tp_name
    dq PyCodeObject_size ; tp_basicsize
    dq code_dealloc     ; tp_dealloc
    dq code_repr        ; tp_repr
    dq code_repr        ; tp_str
    dq 0                ; tp_hash
    dq 0                ; tp_call
    dq code_getattr     ; tp_getattr
    dq 0                ; tp_setattr
    dq 0                ; tp_richcompare
    dq 0                ; tp_iter
    dq 0                ; tp_iternext
    dq 0                ; tp_init
    dq 0                ; tp_new
    dq 0                ; tp_as_number
    dq 0                ; tp_as_sequence
    dq 0                ; tp_as_mapping
    dq 0                ; tp_base
    dq 0                ; tp_dict
    dq 0                ; tp_mro
    dq TYPE_FLAG_HAVE_GC ; tp_flags
    dq 0                ; tp_bases
    dq code_traverse    ; tp_traverse
    dq 0                ; tp_clear -- see code_traverse
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer


section .rodata
;; The keyword names code.replace() takes, each with the CodeSpec field it
;; writes and how to read it.  Kinds: 0 int, 1 tuple, 2 str, 3 bytes, 4 the
;; bytecode itself, which is a length and a borrowed pointer rather than a
;; stored reference.
CRK_INT   equ 0
CRK_TUPLE equ 1
CRK_STR   equ 2
CRK_BYTES equ 3
CRK_CODE  equ 4

cr_n_argcount:       db "co_argcount", 0
cr_n_posonlyargcount: db "co_posonlyargcount", 0
cr_n_kwonlyargcount: db "co_kwonlyargcount", 0
cr_n_nlocals:        db "co_nlocals", 0
cr_n_stacksize:      db "co_stacksize", 0
cr_n_flags:          db "co_flags", 0
cr_n_firstlineno:    db "co_firstlineno", 0
cr_n_consts:         db "co_consts", 0
cr_n_names:          db "co_names", 0
cr_n_filename:       db "co_filename", 0
cr_n_name:           db "co_name", 0
cr_n_qualname:       db "co_qualname", 0
cr_n_linetable:      db "co_linetable", 0
cr_n_exceptiontable: db "co_exceptiontable", 0
cr_n_code:           db "co_code", 0

align 8
;; name, CodeSpec offset, kind
cr_field_table:
    dq cr_n_argcount,        CodeSpec.argcount,        CRK_INT
    dq cr_n_posonlyargcount, CodeSpec.posonlyargcount, CRK_INT
    dq cr_n_kwonlyargcount,  CodeSpec.kwonlyargcount,  CRK_INT
    dq cr_n_nlocals,         CodeSpec.nlocals,         CRK_INT
    dq cr_n_stacksize,       CodeSpec.stacksize,       CRK_INT
    dq cr_n_flags,           CodeSpec.flags,           CRK_INT
    dq cr_n_firstlineno,     CodeSpec.firstlineno,     CRK_INT
    dq cr_n_consts,          CodeSpec.consts,          CRK_TUPLE
    dq cr_n_names,           CodeSpec.names,           CRK_TUPLE
    dq cr_n_filename,        CodeSpec.filename,        CRK_STR
    dq cr_n_name,            CodeSpec.name,            CRK_STR
    dq cr_n_qualname,        CodeSpec.qualname,        CRK_STR
    dq cr_n_linetable,       CodeSpec.linetable,       CRK_BYTES
    dq cr_n_exceptiontable,  CodeSpec.exceptiontable,  CRK_BYTES
    dq cr_n_code,            0,                        CRK_CODE
    dq 0, 0, 0
CR_ROW equ 24

cr_attr_replace: db "replace", 0

section .bss
_co_positions_cache: resq 1
_co_lines_cache: resq 1
_co_replace_cache: resq 1
_varname_cache: resq 1

section .text

;; ============================================================================
;; _get_co_replace_builtin() -> rax = the one builtin behind code.replace
;;
;; Built on first use and kept: `co.replace` is a bound method made fresh for
;; each code object, but the callable underneath it is the same one.
;; ============================================================================
DEF_FUNC_LOCAL _get_co_replace_builtin
    mov rax, [rel _co_replace_cache]
    test rax, rax
    jnz .ret
    lea rdi, [rel code_method_replace]
    lea rsi, [rel cr_attr_replace]
    extern builtin_func_new
    call builtin_func_new
    mov [rel _co_replace_cache], rax
.ret:
    leave
    ret
END_FUNC _get_co_replace_builtin

;; ============================================================================
;; code_method_replace(args, nargs)
;;   -> rax = a new PyCodeObject with some fields changed, rdx = TAG_PTR
;;
;;
;; `co.replace(co_flags=...)`, which is how types.coroutine marks a generator
;; function as a coroutine -- and so how asyncio gets imported at all.  Every
;; argument is keyword-only, as CPython's is; what is not named is copied.
;;
;; co_varnames, co_freevars and co_cellvars are refused rather than silently
;; ignored: this code object keeps one localsplusnames tuple with a parallel
;; kinds string, so replacing one of the three means rebuilding both, and a
;; caller that changes them without changing the bytecode has broken the
;; object anyway.  DIVERGENCES.md records it.
;; ============================================================================
CR_ARGS   equ 8
CR_NARGS  equ 16
CR_KW     equ 24
CR_NKW    equ 32
CR_I      equ 40
CR_SRC    equ 48
CR_OFF    equ 56          ; the CodeSpec offset the current keyword writes
CR_SPEC   equ 64 + CodeSpec_size
CR_FRAME  equ ((CR_SPEC + 15) / 16) * 16 + 8    ; + 3 pushes = 16-aligned
global code_method_replace
DEF_FUNC code_method_replace, CR_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - CR_ARGS], rdi
    mov [rbp - CR_NARGS], rsi
    mov qword [rbp - CR_KW], 0
    mov qword [rbp - CR_NKW], 0

    ; The keywords, and how many of the arguments are actually positional.
    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jz .cr_no_kw
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov [rbp - CR_KW], rax
    mov rcx, [rax + PyTupleObject.ob_size]
    mov [rbp - CR_NKW], rcx
    sub [rbp - CR_NARGS], rcx
.cr_no_kw:
    cmp qword [rbp - CR_NARGS], 1
    jne .cr_positional

    mov rax, [rbp - CR_ARGS]
    mov rax, [rax]
    mov [rbp - CR_SRC], rax
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel code_type]
    cmp rcx, rdx
    jne .cr_positional

    ; --- the spec, filled from the source; code_new steals what is in it ---
    lea rdi, [rbp - CR_SPEC]
    xor esi, esi
    mov edx, CodeSpec_size
    call ap_memset
    mov rbx, [rbp - CR_SRC]
    lea r12, [rbp - CR_SPEC]

    lea rax, [rbx + PyCodeObject.co_code]
    mov [r12 + CodeSpec.code_bytes], rax
    movsxd rax, dword [rbx + PyCodeObject.co_code_len]
    mov [r12 + CodeSpec.code_len], rax
    mov eax, [rbx + PyCodeObject.co_argcount]
    mov [r12 + CodeSpec.argcount], eax
    mov eax, [rbx + PyCodeObject.co_posonlyargcount]
    mov [r12 + CodeSpec.posonlyargcount], eax
    mov eax, [rbx + PyCodeObject.co_kwonlyargcount]
    mov [r12 + CodeSpec.kwonlyargcount], eax
    mov eax, [rbx + PyCodeObject.co_nlocals]
    mov [r12 + CodeSpec.nlocals], eax
    mov eax, [rbx + PyCodeObject.co_stacksize]
    mov [r12 + CodeSpec.stacksize], eax
    mov eax, [rbx + PyCodeObject.co_flags]
    mov [r12 + CodeSpec.flags], eax
    mov eax, [rbx + PyCodeObject.co_firstlineno]
    mov [r12 + CodeSpec.firstlineno], eax

    ; consts through exceptiontable sit in the same order in both structs,
    ; 24 bytes apart; linetable does not -- PyCodeObject keeps it past two
    ; 32-bit fields -- so it is copied on its own rather than by the stride.
    mov r13, CodeSpec.consts
.cr_copy_objs:
    cmp r13, CodeSpec.exceptiontable
    ja .cr_copied
    mov rdi, [rbx + (PyCodeObject.co_consts - CodeSpec.consts) + r13]
    mov [r12 + r13], rdi
    test rdi, rdi
    jz .cr_copy_next
    call obj_incref
.cr_copy_next:
    add r13, 8
    jmp .cr_copy_objs
.cr_copied:
    mov rdi, [rbx + PyCodeObject.co_linetable]
    mov [r12 + CodeSpec.linetable], rdi
    test rdi, rdi
    jz .cr_no_linetable
    call obj_incref
.cr_no_linetable:

    ; --- the keywords, one at a time ---
    mov qword [rbp - CR_I], 0
.cr_kw_loop:
    mov rax, [rbp - CR_I]
    cmp rax, [rbp - CR_NKW]
    jae .cr_build
    mov rcx, [rbp - CR_KW]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov r13, [rcx + rax*8]              ; the keyword's name
    mov rcx, [rbp - CR_NARGS]
    add rcx, rax
    mov rdx, [rbp - CR_ARGS]
    mov rbx, [rdx + rcx*8]              ; the value, as a Value
    lea r8, [rel cr_field_table]
.cr_scan:
    mov rdi, [r8]
    test rdi, rdi
    jz .cr_unknown_kw
    push r8
    lea rsi, [r13 + PyStrObject.data]
    call ap_strcmp
    pop r8
    test eax, eax
    jz .cr_apply
    add r8, CR_ROW
    jmp .cr_scan

.cr_apply:
    mov r9, [r8 + 8]                    ; the CodeSpec offset
    mov [rbp - CR_OFF], r9
    mov r10, [r8 + 16]                  ; the kind
    lea r12, [rbp - CR_SPEC]
    cmp r10, CRK_INT
    je .cr_set_int
    cmp r10, CRK_CODE
    je .cr_set_code
    ; every other kind is one object reference, type-checked first
    mov rdi, rbx
    V_TEST_PTR rdi, rax
    ja .cr_bad_type
    test rdi, rdi
    jz .cr_bad_type
    mov rax, [rdi + PyObject.ob_type]
    cmp r10, CRK_TUPLE
    jne .cr_chk_str
    lea rcx, [rel tuple_type]
    jmp .cr_chk_cmp
.cr_chk_str:
    cmp r10, CRK_STR
    jne .cr_chk_bytes
    lea rcx, [rel str_type]
    jmp .cr_chk_cmp
.cr_chk_bytes:
    lea rcx, [rel bytes_type]
.cr_chk_cmp:
    cmp rax, rcx
    jne .cr_bad_type
    call obj_incref
    lea r12, [rbp - CR_SPEC]
    mov r9, [rbp - CR_OFF]
    mov rax, [r12 + r9]
    mov [r12 + r9], rbx
    test rax, rax
    jz .cr_kw_next
    mov rdi, rax
    call obj_decref
    jmp .cr_kw_next

.cr_set_int:
    mov rdi, rbx
    V_UNPACK rdi, rdx
    call obj_as_index
    lea r12, [rbp - CR_SPEC]
    mov r9, [rbp - CR_OFF]
    mov [r12 + r9], eax
    jmp .cr_kw_next

.cr_set_code:
    mov rdi, rbx
    V_TEST_PTR rdi, rax
    ja .cr_bad_type
    test rdi, rdi
    jz .cr_bad_type
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    jne .cr_bad_type
    lea rax, [rdi + PyBytesObject.data]
    mov [r12 + CodeSpec.code_bytes], rax
    mov rax, [rdi + PyBytesObject.ob_size]
    mov [r12 + CodeSpec.code_len], rax

.cr_kw_next:
    inc qword [rbp - CR_I]
    jmp .cr_kw_loop

.cr_build:
    lea rdi, [rbp - CR_SPEC]
    call code_new
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.cr_unknown_kw:
    ; The three that cannot be replaced are named separately, because "no
    ; such keyword" would be a lie about them.
    lea rdi, [r13 + PyStrObject.data]
    CSTRING rsi, "co_varnames"
    call ap_strcmp
    test eax, eax
    jz .cr_refused
    lea rdi, [r13 + PyStrObject.data]
    CSTRING rsi, "co_freevars"
    call ap_strcmp
    test eax, eax
    jz .cr_refused
    lea rdi, [r13 + PyStrObject.data]
    CSTRING rsi, "co_cellvars"
    call ap_strcmp
    test eax, eax
    jz .cr_refused
    lea rdi, [rbp - CR_SPEC]
    call code_spec_clear
    RAISE exc_TypeError_type, "replace() got an unexpected keyword argument"
.cr_refused:
    lea rdi, [rbp - CR_SPEC]
    call code_spec_clear
    RAISE exc_TypeError_type, \
        "replace() cannot change co_varnames, co_freevars or co_cellvars"
.cr_bad_type:
    lea rdi, [rbp - CR_SPEC]
    call code_spec_clear
    RAISE exc_TypeError_type, "replace() got the wrong type for a field"
.cr_positional:
    RAISE exc_TypeError_type, "replace() takes no positional arguments"
END_FUNC code_method_replace

;; ============================================================================
;; code.co_lines() -> an iterable of (start, end, lineno)
;;
;; One entry per RUN of code units on the same line: CPython's own
;; co_lines() coalesces, and `dis`, `trace` and `inspect` all read it that
;; way.  A line of None marks a run the table does not cover, which is what
;; CPython reports for a NO_LOCATION entry.
;;
;; Built from code_addr2line rather than from the line table directly: the
;; walk is the same one every other reader here uses, and a second decoder
;; would be a second thing to get wrong.
;; ============================================================================
COL_CODE  equ 8
COL_LIST  equ 16
COL_I     equ 24
COL_N     equ 32
COL_START equ 40            ; where the current run began, in code units
COL_LINE  equ 48            ; the line that run is on
COL_TUP   equ 56
COL_LOC   equ 96            ; the four out-slots, ascending from here
COL_CUR   equ 136           ; the three-word resume cursor, ascending from here
COL_FRAME equ 144           ; + 0 pushes = 144
DEF_FUNC code_method_co_lines, COL_FRAME
    cmp rsi, 1                  ; bound, so self is the only argument
    jne .col_args
    mov rdi, [rdi]
    mov [rbp - COL_CODE], rdi
    mov eax, [rdi + PyCodeObject.co_code_len]
    shr eax, 1                  ; code units, two bytes each
    mov [rbp - COL_N], rax

    mov rdi, rax
    extern list_new
    call list_new
    test rax, rax
    jz .col_failed
    mov [rbp - COL_LIST], rax

    mov qword [rbp - COL_I], 0
    mov qword [rbp - COL_START], 0
    mov qword [rbp - COL_LINE], -2      ; neither a line nor "no location"
    ; Ascending offsets, so the walk carries a cursor; see co_positions.
    mov qword [rbp - COL_CUR], 0
    mov qword [rbp - COL_CUR + 8], 0
    mov qword [rbp - COL_CUR + 16], 0

.col_loop:
    mov rax, [rbp - COL_I]
    cmp rax, [rbp - COL_N]
    jge .col_flush
    ; code_addr2location, not code_addr2line: only the first can say that an
    ; entry carries NO location, and CPython's co_lines() breaks its run
    ; there and reports None for the line.
    mov qword [rbp - COL_LOC], 0
    mov rdi, [rbp - COL_CODE]
    mov rsi, rax
    lea rdx, [rbp - COL_LOC]
    lea rcx, [rbp - COL_CUR]
    extern code_addr2location_at
    call code_addr2location_at
    mov rcx, [rbp - COL_LOC]
    cmp qword [rbp - COL_I], 0
    je .col_first
    cmp rcx, [rbp - COL_LINE]
    je .col_next
    ; A different line: close the run that ended here.
    push rcx
    sub rsp, 8
    call col_emit
    add rsp, 8
    pop rcx
    mov rax, [rbp - COL_I]
    mov [rbp - COL_START], rax
.col_first:
    mov [rbp - COL_LINE], rcx
.col_next:
    inc qword [rbp - COL_I]
    jmp .col_loop

.col_flush:
    cmp qword [rbp - COL_N], 0
    je .col_done
    call col_emit
.col_done:
    mov rax, [rbp - COL_LIST]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.col_failed:
    xor eax, eax
    xor edx, edx
    leave
    ret
.col_args:
    RAISE exc_TypeError_type, "co_lines() takes no arguments"

;; One (start, end, line) triple, from COL_START to COL_I.  A local, because
;; it reads the caller's frame.  It sits after every dotted label that names
;; it: a non-dotted label ends their scope.
col_emit:
    mov edi, 3
    extern tuple_new
    call tuple_new
    test rax, rax
    jz .ce_done
    mov [rbp - COL_TUP], rax
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rcx, [rbp - COL_START]
    add rcx, rcx                ; co_lines reports BYTE offsets
    V_PACK_I64 rcx, r8
    mov [rdx], rcx
    mov rcx, [rbp - COL_I]
    add rcx, rcx
    V_PACK_I64 rcx, r8
    mov [rdx + 8], rcx
    mov rcx, [rbp - COL_LINE]
    test rcx, rcx
    js .ce_none
    V_PACK_I64 rcx, r8
    jmp .ce_line
.ce_none:
    LOAD_NONE rcx
.ce_line:
    mov [rdx + 16], rcx
    mov rdi, [rbp - COL_LIST]
    mov rsi, [rbp - COL_TUP]
    extern list_append
    call list_append
    mov rdi, [rbp - COL_TUP]
    extern obj_decref
    call obj_decref
.ce_done:
    ret
END_FUNC code_method_co_lines

;; ============================================================================
;; code_build_lnotab(rdi = a PyCodeObject*) -> rax = a bytes object, owned
;;
;; co_lnotab: the line table as 3.9 and earlier wrote it, built from the one
;; 3.12 actually carries.  Pairs of (bytecode delta, signed line delta), a
;; pair per line CHANGE -- a delta too wide for its byte is split, with the
;; bytecode delta spent on the first piece and zero on the rest.
;;
;; Built from co_lines() rather than from the line table, for the reason
;; co_lines() itself gives: one decoder.  What co_lines reports as a run with
;; no line -- a NO_LOCATION entry -- changes nothing here, which is what
;; CPython's code_getlnotab does with the same entries.
;; ============================================================================
CBL_CODE     equ 8
CBL_LIST     equ 16
CBL_BUF      equ 24
CBL_LEN      equ 32
CBL_CAP      equ 40
CBL_I        equ 48
CBL_N        equ 56
CBL_PREVADDR equ 64
CBL_LINE     equ 72
CBL_BD       equ 80
CBL_LD       equ 88
CBL_ARGS     equ 96         ; the one Value handed to co_lines()
CBL_FRAME    equ 104        ; + 1 push = 112, 16-aligned
DEF_FUNC_LOCAL code_build_lnotab, CBL_FRAME
    push rbx
    mov [rbp - CBL_CODE], rdi
    mov [rbp - CBL_ARGS], rdi
    lea rdi, [rbp - CBL_ARGS]
    mov esi, 1
    call code_method_co_lines
    test rax, rax
    jz .cbl_fail
    mov [rbp - CBL_LIST], rax

    mov edi, 64
    extern ap_malloc
    call ap_malloc
    test rax, rax
    jz .cbl_free_list
    mov [rbp - CBL_BUF], rax
    mov qword [rbp - CBL_CAP], 64
    mov qword [rbp - CBL_LEN], 0
    mov qword [rbp - CBL_PREVADDR], 0
    mov rax, [rbp - CBL_CODE]
    movsxd rax, dword [rax + PyCodeObject.co_firstlineno]
    mov [rbp - CBL_LINE], rax
    mov qword [rbp - CBL_I], 0
    mov rax, [rbp - CBL_LIST]
    mov rax, [rax + PyListObject.ob_size]
    mov [rbp - CBL_N], rax

.cbl_loop:
    mov rax, [rbp - CBL_I]
    cmp rax, [rbp - CBL_N]
    jge .cbl_done
    mov rcx, [rbp - CBL_LIST]
    mov rcx, [rcx + PyListObject.ob_item]
    mov rbx, [rcx + rax*8]              ; the (start, end, line) tuple
    mov rcx, [rbx + PyTupleObject.ob_item]
    mov rdx, [rcx + 16]                 ; the line
    lea rax, [rel none_singleton]
    cmp rdx, rax
    je .cbl_next
    V_TO_I64 rdx
    cmp rdx, [rbp - CBL_LINE]
    je .cbl_next

    mov [rbp - CBL_LD], rdx             ; the new line, for a moment
    mov rax, [rcx]                      ; the run's first byte offset
    V_TO_I64 rax
    mov rsi, rax
    sub rsi, [rbp - CBL_PREVADDR]
    mov [rbp - CBL_BD], rsi
    mov [rbp - CBL_PREVADDR], rax
    mov rdx, [rbp - CBL_LD]
    mov rsi, rdx
    sub rsi, [rbp - CBL_LINE]
    mov [rbp - CBL_LD], rsi
    mov [rbp - CBL_LINE], rdx

.cbl_bchunk:
    cmp qword [rbp - CBL_BD], 255
    jle .cbl_lchunk
    mov edi, 255
    xor esi, esi
    call cbl_pair
    sub qword [rbp - CBL_BD], 255
    jmp .cbl_bchunk
.cbl_lchunk:
    cmp qword [rbp - CBL_LD], 127
    jle .cbl_lneg
    mov rdi, [rbp - CBL_BD]
    mov esi, 127
    call cbl_pair
    mov qword [rbp - CBL_BD], 0
    sub qword [rbp - CBL_LD], 127
    jmp .cbl_lchunk
.cbl_lneg:
    cmp qword [rbp - CBL_LD], -128
    jge .cbl_emit
    mov rdi, [rbp - CBL_BD]
    mov esi, 128                        ; -128, as the byte it is written as
    call cbl_pair
    mov qword [rbp - CBL_BD], 0
    add qword [rbp - CBL_LD], 128
    jmp .cbl_lneg
.cbl_emit:
    mov rdi, [rbp - CBL_BD]
    mov rsi, [rbp - CBL_LD]
    call cbl_pair
.cbl_next:
    inc qword [rbp - CBL_I]
    jmp .cbl_loop

.cbl_done:
    mov rdi, [rbp - CBL_BUF]
    mov rsi, [rbp - CBL_LEN]
    call bytes_from_data
    mov rbx, rax
    mov rdi, [rbp - CBL_BUF]
    extern ap_free
    call ap_free
    mov rdi, [rbp - CBL_LIST]
    call obj_decref
    mov rax, rbx
    pop rbx
    leave
    ret

.cbl_free_list:
    mov rdi, [rbp - CBL_LIST]
    call obj_decref
.cbl_fail:
    xor eax, eax
    pop rbx
    leave
    ret

;; One (bytecode delta, line delta) pair.  A local, because it reads and
;; writes the caller's frame; it sits after every dotted label that names it.
cbl_pair:
    mov rax, [rbp - CBL_LEN]
    add rax, 2
    cmp rax, [rbp - CBL_CAP]
    jbe .cp_room
    push rdi
    push rsi
    sub rsp, 8                          ; three slots, so the call is aligned
    mov rdi, [rbp - CBL_BUF]
    mov rsi, [rbp - CBL_CAP]
    add rsi, rsi
    extern ap_realloc
    call ap_realloc
    add rsp, 8
    pop rsi
    pop rdi
    test rax, rax
    jz .cp_done                         ; out of memory: the pair is dropped
    mov [rbp - CBL_BUF], rax
    mov rcx, [rbp - CBL_CAP]
    add rcx, rcx
    mov [rbp - CBL_CAP], rcx
.cp_room:
    mov rax, [rbp - CBL_BUF]
    mov rcx, [rbp - CBL_LEN]
    mov [rax + rcx], dil
    mov [rax + rcx + 1], sil
    add qword [rbp - CBL_LEN], 2
.cp_done:
    ret
END_FUNC code_build_lnotab

;; ============================================================================
;; _get_co_lines_builtin() -> rax = the co_lines builtin, borrowed
;;
;; Made once and cached, the way the co_positions one is.
;; ============================================================================
DEF_FUNC_LOCAL _get_co_lines_builtin
    mov rax, [rel _co_lines_cache]
    test rax, rax
    jnz .gcl_ret
    lea rdi, [rel code_method_co_lines]
    lea rsi, [rel co_attr_lines]
    extern builtin_func_new
    call builtin_func_new
    mov [rel _co_lines_cache], rax
.gcl_ret:
    leave
    ret
END_FUNC _get_co_lines_builtin

;; ============================================================================
;; code_method_varname_from_oparg(args, nargs) -> rax = a Value
;;   -- code._varname_from_oparg(i)
;;
;; The name an oparg of the LOAD_FAST family stands for.  CPython's
;; co_localsplusnames is one tuple over the locals, the cells and the free
;; variables in that order, and the oparg indexes it directly; dis and
;; test_dis both read this rather than reassembling the three tuples.
;;
;; Out of range is an IndexError, which is what PyTuple_GetItem raises there.
;; ============================================================================
global code_method_varname_from_oparg
DEF_FUNC code_method_varname_from_oparg, 8   ; 1 push, so rsp is 16-aligned
    push rbx
    cmp rsi, 2
    jne .vfo_argerr
    mov rbx, [rdi]                      ; self, always a pointer
    mov rdi, [rdi + 8]
    V_UNPACK rdi, rdx                   ; obj_as_index takes the pair
    extern obj_as_index
    call obj_as_index                   ; names the type for a non-integer
    mov rbx, [rbx + PyCodeObject.co_localsplusnames]
    test rbx, rbx
    jz .vfo_range
    test rax, rax
    js .vfo_range
    cmp rax, [rbx + PyTupleObject.ob_size]
    jge .vfo_range
    mov rcx, [rbx + PyTupleObject.ob_item]
    mov rax, [rcx + rax*8]
    INCREF_V rax, rcx
    pop rbx
    leave
    ret
.vfo_range:
    pop rbx
    RAISE exc_IndexError_type, "tuple index out of range"
.vfo_argerr:
    pop rbx
    RAISE exc_TypeError_type, "_varname_from_oparg() takes exactly 1 argument"
END_FUNC code_method_varname_from_oparg

;; ============================================================================
;; _get_varname_builtin() -> rax = the _varname_from_oparg builtin, borrowed
;; ============================================================================
DEF_FUNC_LOCAL _get_varname_builtin
    mov rax, [rel _varname_cache]
    test rax, rax
    jnz .gvn_ret
    lea rdi, [rel code_method_varname_from_oparg]
    lea rsi, [rel co_attr_varname]
    call builtin_func_new
    mov [rel _varname_cache], rax
.gvn_ret:
    leave
    ret
END_FUNC _get_varname_builtin

DEF_FUNC_LOCAL _get_co_positions_builtin
    mov rax, [rel _co_positions_cache]
    test rax, rax
    jnz .ret
    lea rdi, [rel code_method_co_positions]
    lea rsi, [rel co_attr_positions]
    extern builtin_func_new
    call builtin_func_new
    mov [rel _co_positions_cache], rax
.ret:
    leave
    ret
END_FUNC _get_co_positions_builtin

section .rodata
co_attr_positions: db "co_positions", 0
co_attr_lines: db "co_lines", 0
co_attr_varname: db "_varname_from_oparg", 0
