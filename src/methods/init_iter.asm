; init_iter.asm - the builtin iterators' tp_dict, built from one table
;
; Every one of these types has a live tp_iternext and a tp_iter and, until
; this file, no way to reach either by NAME.  The stdlib asks by name
; constantly -- heapq.py has `next = it.__next__` at module level, inspect.py
; has `iter(lines).__next__` -- and CLAUDE.md's "a builtin's behaviour that
; lives only in a slot" is exactly this failure: `hasattr(it, '__next__')` was
; False for every builtin iterator in the tree.
;
; A table rather than twenty-two open-coded blocks, on the model of
; set_add_operator_methods in init.asm: each is otherwise the same four lines,
; and a block per type is where a missing type_stamp_methods hides.  It lives
; in its own file because init.asm is within a couple of kilobytes of the
; hand-written 100k cap.
;
; The thunks themselves are DEF_DUNDER_ITER / DEF_DUNDER_NEXT in
; methods/object.asm, beside every other dunder generator -- a NASM macro does
; not cross a file boundary, and that is where the macros are.  Both read the
; DEFINING type's slot, so a subclass that defines __next__ does not
; re-dispatch into itself.

%include "macros.inc"
%include "object.inc"

extern dict_new
extern dict_add_builtin_func
extern type_stamp_methods

extern mn___iter__
extern mn___next__
extern mn___reduce__
extern mn___setstate__
extern mn___length_hint__

;; ============================================================================
;; iter_types_init() -> nothing; every builtin iterator gains a tp_dict
;;
;; Called from methods_init, after the types it names are all in place.  A
;; type that already HAS a tp_dict is left alone and given its two entries in
;; the block that built it -- scandir_iter_type is the one, and building a
;; second dict here would drop close/__enter__/__exit__ on the floor.
;; ============================================================================
ITI_IDX   equ 8
ITI_DICT  equ 16
ITI_FRAME equ 40            ; + 1 push = 48, 16-aligned

global iter_types_init
DEF_FUNC iter_types_init, ITI_FRAME
    push rbx
    mov qword [rbp - ITI_IDX], 0

.iti_loop:
    mov rax, [rbp - ITI_IDX]
    cmp rax, ITER_TYPE_COUNT
    jge .iti_done

    imul rax, rax, ITER_ROW_SIZE
    lea rbx, [rel iter_type_table]
    add rbx, rax

    call dict_new
    mov [rbp - ITI_DICT], rax

    mov rdi, rax
    lea rsi, [rel mn___iter__]
    mov rdx, [rbx + ITER_ROW_ITER]
    call dict_add_builtin_func

    mov rdi, [rbp - ITI_DICT]
    lea rsi, [rel mn___next__]
    mov rdx, [rbx + ITER_ROW_NEXT]
    call dict_add_builtin_func

    ; The pickle half, for the rows that have one.  A 0 means this iterator
    ; cannot be rebuilt from its state and CPython refuses to pickle it too.
    mov rdx, [rbx + ITER_ROW_REDUCE]
    test rdx, rdx
    jz .iti_no_reduce
    mov rdi, [rbp - ITI_DICT]
    lea rsi, [rel mn___reduce__]
    call dict_add_builtin_func
.iti_no_reduce:
    mov rdx, [rbx + ITER_ROW_SETSTATE]
    test rdx, rdx
    jz .iti_no_setstate
    mov rdi, [rbp - ITI_DICT]
    lea rsi, [rel mn___setstate__]
    call dict_add_builtin_func
.iti_no_setstate:
    mov rdx, [rbx + ITER_ROW_HINT]
    test rdx, rdx
    jz .iti_no_hint
    mov rdi, [rbp - ITI_DICT]
    lea rsi, [rel mn___length_hint__]
    call dict_add_builtin_func
.iti_no_hint:

    ; The dict goes on the type, and then type_stamp_methods walks it to give
    ; every entry its func_owner -- which is what makes builtin_func_call
    ; refuse a wrong receiver, and what gives these two the slot-wrapper
    ; spelling in a repr.
    mov rax, [rbx + ITER_ROW_TYPE]
    mov rcx, [rbp - ITI_DICT]
    mov [rax + PyTypeObject.tp_dict], rcx
    mov rdi, rax
    call type_stamp_methods

    inc qword [rbp - ITI_IDX]
    jmp .iti_loop

.iti_done:
    pop rbx
    leave
    ret
END_FUNC iter_types_init

section .rodata
ITER_ROW_TYPE     equ 0
ITER_ROW_ITER     equ 8
ITER_ROW_NEXT     equ 16
ITER_ROW_REDUCE   equ 24
ITER_ROW_SETSTATE equ 32
ITER_ROW_HINT     equ 40
ITER_ROW_SIZE     equ 48

;; ITER_ROW type -- __iter__ and __next__ only, for an iterator pickle cannot
;; rebuild.  ITER_ROW_PICKLE adds the three that make one picklable: CPython
;; gives every iterator it can reconstruct a __reduce__, and pickle, copy and
;; deepcopy all go through it.
%macro ITER_ROW 1
    extern %1_type
    extern %1_dunder_iter
    extern %1_dunder_next
    dq %1_type, %1_dunder_iter, %1_dunder_next, 0, 0, 0
%endmacro

%macro ITER_ROW_PICKLE 4        ; type, __reduce__, __setstate__, __length_hint__
    extern %1_type
    extern %1_dunder_iter
    extern %1_dunder_next
    dq %1_type, %1_dunder_iter, %1_dunder_next, %2, %3, %4
%endmacro

; The __reduce__ implementations the rows above name.  They used to be
; declared by the macro itself, which cannot work now that a row may have
; none: `extern 0` is not a declaration.
extern list_iter_reduce
extern tuple_iter_reduce
extern range_iter_reduce
extern str_iter_reduce
extern bytes_iter_reduce
extern bytearray_iter_reduce
extern seqiter_setstate
extern seqiter_length_hint
extern range_iter_length_hint
extern dictiter_length_hint
extern setiter_length_hint
extern dictrev_length_hint
extern reversed_length_hint
extern seq_iter_reduce
extern reversed_iter_reduce
extern reversed_iter_setstate

align 8
iter_type_table:
    ITER_ROW_PICKLE list_iter, list_iter_reduce, seqiter_setstate, seqiter_length_hint
    ITER_ROW_PICKLE tuple_iter, tuple_iter_reduce, seqiter_setstate, seqiter_length_hint
    ITER_ROW_PICKLE range_iter, range_iter_reduce, 0, range_iter_length_hint
    ITER_ROW longrange_iter
    ITER_ROW_PICKLE str_iter, str_iter_reduce, seqiter_setstate, seqiter_length_hint
    ITER_ROW_PICKLE bytes_iter, bytes_iter_reduce, seqiter_setstate, seqiter_length_hint
    ITER_ROW_PICKLE bytearray_iter, bytearray_iter_reduce, seqiter_setstate, seqiter_length_hint
    ITER_ROW memoryview_iter
    ; The four that walk a sparse entry table, plus the set's: what is left
    ; is the occupied slots from the index on, which is what
    ; dictiter_length_hint counts.  They have no __reduce__ of their own --
    ; CPython's pickles such an iterator by draining it into a list, and
    ; nothing here does that yet -- so the row carries the hint alone.
    ITER_ROW_PICKLE set_iter, 0, 0, setiter_length_hint
    ITER_ROW_PICKLE dict_iter, 0, 0, dictiter_length_hint
    ITER_ROW_PICKLE dict_value_iter, 0, 0, dictiter_length_hint
    ITER_ROW_PICKLE dict_item_iter, 0, 0, dictiter_length_hint
    ITER_ROW_PICKLE dict_rev_iter, 0, 0, dictrev_length_hint
    ITER_ROW enumerate_iter
    ITER_ROW zip_iter
    ITER_ROW map_iter
    ITER_ROW filter_iter
    ITER_ROW callable_iter
    ITER_ROW_PICKLE seq_iter, seq_iter_reduce, seqiter_setstate, 0
    ITER_ROW_PICKLE reversed_iter, reversed_iter_reduce, reversed_iter_setstate, reversed_length_hint
    ITER_ROW sre_scanner
ITER_TYPE_COUNT equ ($ - iter_type_table) / ITER_ROW_SIZE
