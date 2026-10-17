; pyo/list.asm - List type implementation
; Phase 9: dynamic array with amortized O(1) append

%include "macros.inc"
%include "object.inc"

extern get_iterator_opt
extern int_is_integer
extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern ap_free
extern ap_realloc
extern ap_memmove
extern ap_memcpy
extern obj_decref
extern obj_dealloc
extern fatal_error
extern raise_exception
extern exc_IndexError_type
extern int_to_i64
extern bool_true
extern bool_false
extern obj_incref
extern slice_type
extern slice_indices
extern slice_indices_live
extern type_type
extern int_type
extern eval_exception_unwind
extern obj_richcompare_bool
extern obj_as_index
extern obj_as_index_seq
extern recursion_limit
extern exc_RecursionError_type
extern int_fits_i64
extern str_type
extern bool_type
extern list_sorting_error

;; ============================================================================
;; list_new(int64_t capacity) -> PyListObject*
;; Allocate a new empty list with given initial capacity
;; ============================================================================
LIST_POOL_MAX equ 16

;; ============================================================================
;; list_new(rdi = capacity) -> rax = PyListObject*, every slot zeroed
;; list_new_filled(rdi = n) -> rax = PyListObject* of capacity n, whose n
;;                             slots are UNINITIALISED
;;
;; Both go through list_new_from below; they differ only in where the zeroing
;; starts.  list_new_filled is for the four builders that write every one of
;; the n slots before anything can look -- copy, slice, concat, repeat -- and
;; on those the zeroing was pure waste: the array was filled with zeroes and
;; then immediately overwritten by an ap_memcpy of exactly the same length.
;;
;; The capacity is what was ASKED FOR, not max(n, something).  list_new_from
;; substitutes its minimum only for a request of ZERO -- so list_new(0) gets
;; the minimum and list_new_filled(2) gets exactly two slots and zeroes
;; nothing.  That minimum is 8 rather than 4 since 5501d5b, because a list
;; literal compiles to BUILD_LIST 0 plus LIST_EXTEND and four slots meant
;; every one of them grew immediately.
;; ============================================================================
DEF_FUNC_BARE list_new
    xor esi, esi                ; zero from slot 0: nothing is promised
    jmp list_new_from
END_FUNC list_new

;; ============================================================================
;; list_new_filled(rdi = n) -> rax = PyListObject*; see list_new above
;; ============================================================================
global list_new_filled
DEF_FUNC_BARE list_new_filled
    mov rsi, rdi                ; zero from slot n: the caller writes [0, n)
    jmp list_new_from
END_FUNC list_new_filled

;; ============================================================================
;; list_new_from(rdi = capacity, rsi = first slot to zero) -> rax = the list
;;
;; The body both of the above share.  Not called from anywhere else: the two
;; entry points above are the contract.
;; ============================================================================
DEF_FUNC list_new_from, 8       ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    mov r13, rsi               ; r13 = first slot to zero
    mov r12, rdi               ; r12 = capacity
    test r12, r12
    jnz .has_cap
    mov r12d, 8                     ; minimum capacity
.has_cap:

    ; Try list header pool first
    mov rax, [rel list_pool_head]
    test rax, rax
    jz .alloc_fresh
    ; Pop from pool: reuse ob_refcnt slot as next-link
    mov rcx, [rax + PyObject.ob_refcnt]
    mov [rel list_pool_head], rcx
    dec dword [rel list_pool_count]
    mov qword [rax + PyObject.ob_refcnt], 1  ; reinit refcount
    mov rbx, rax
    jmp .init_fields

.alloc_fresh:
    ; Allocate PyListObject header (GC-tracked)
    mov edi, PyListObject_size
    lea rsi, [rel list_type]
    call gc_alloc
    mov rbx, rax               ; rbx = list (ob_refcnt=1, ob_type set)

.init_fields:
    mov qword [rbx + PyListObject.ob_size], 0
    mov [rbx + PyListObject.allocated], r12

    ; Allocate the item array: capacity * 8, zeroed (an empty slot is 0, and
    ; slice operations can read ahead of ob_size)
    mov rdi, r12
    shl rdi, 3
    call ap_malloc
    mov [rbx + PyListObject.ob_item], rax
    lea rdi, [rax + r13*8]
    mov rcx, r12
    sub rcx, r13               ; the slots the caller does not promise
    jbe .lnf_no_zero
    xor eax, eax
    rep stosq
.lnf_no_zero:

    mov rdi, rbx
    call gc_track

    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_new_from

;; ============================================================================
;; list_copy(PyListObject *src) -> PyListObject* (shallow copy)
;; Creates a new list with same items, INCREFs each.
;; ============================================================================
DEF_FUNC list_copy, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    mov rbx, rdi               ; src list
    mov r12, [rbx + PyListObject.ob_size]

    ; Allocate new list.  Every one of the r12 slots is written by the
    ; ap_memcpy below, so the zeroing is only owed on the tail.
    mov rdi, r12
    call list_new_filled
    mov r13, rax               ; new list
    mov [r13 + PyListObject.ob_size], r12

    ; Bulk copy payloads
    mov rdi, [r13 + PyListObject.ob_item]
    mov rsi, [rbx + PyListObject.ob_item]
    mov rdx, r12
    shl rdx, 3
    call ap_memcpy

    ; INCREF each item.  The array pointer is loaded once and the counter
    ; stays in a register: INCREF_V is a compare, a branch and an increment
    ; and clobbers only the scratch it is given, so the push/pop bracket that
    ; was here protected nothing.
    mov rax, [r13 + PyListObject.ob_item]
    xor ecx, ecx
    jmp .lc_incref_test
.lc_incref:
    mov rdi, [rax + rcx * 8]
    INCREF_V rdi, rsi
    inc rcx
.lc_incref_test:
    cmp rcx, r12
    jb .lc_incref

.lc_done:
    mov rax, r13
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_copy

;; ============================================================================
;; list_extend_from_array(rdi = list, rsi = Value[], rdx = count) -> void
;;
;; Append count Values in one go: grow once, one ap_memcpy, one INCREF pass.
;; Every caller that knows its source's length wants this -- LIST_EXTEND from
;; a list or a tuple, list.extend of either, `+=`, and a list literal, which
;; is what `BUILD_LIST 0; LOAD_CONST tuple; LIST_EXTEND 1` compiles to.  They
;; each called list_append per element, so the destination re-checked its
;; capacity on every one and could realloc log(n) times for a source whose
;; size was sitting in a register.
;;
;; `l.extend(l)` and `l += l` hand this the destination's own array, which the
;; grow may move -- hence the flag.  The copy itself is safe either way: the
;; destination starts at ob_item + ob_size and the source at ob_item, and
;; with count == ob_size those two runs are adjacent, not overlapping.
;; ============================================================================
LEFA_SELF  equ 8
LEFA_FRAME equ 16               ; + 4 pushes = 48, 16-aligned
DEF_FUNC list_extend_from_array, LEFA_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r13, r13
    jz .lefa_done

    ; The sorting sentinel, as every other way into a list checks it.
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error

    xor eax, eax
    cmp r12, [rbx + PyListObject.ob_item]
    sete al
    mov [rbp - LEFA_SELF], rax

    mov r14, [rbx + PyListObject.ob_size]
    add r14, r13                        ; r14 = the size afterwards
    cmp r14, [rbx + PyListObject.allocated]
    jbe .lefa_have_room

    ; Grow to max(2 * allocated, the new size) -- the same rule the slice
    ; assignment path uses, so a repeated extend still doubles.
    mov rax, [rbx + PyListObject.allocated]
    shl rax, 1
    cmp rax, r14
    jae .lefa_cap
    mov rax, r14
.lefa_cap:
    mov [rbx + PyListObject.allocated], rax
    mov rdi, [rbx + PyListObject.ob_item]
    mov rsi, rax
    shl rsi, 3
    call ap_realloc
    mov [rbx + PyListObject.ob_item], rax
    cmp qword [rbp - LEFA_SELF], 0
    je .lefa_have_room
    mov r12, rax                        ; the source moved with the array

.lefa_have_room:
    mov rdi, [rbx + PyListObject.ob_item]
    mov rax, [rbx + PyListObject.ob_size]
    lea rdi, [rdi + rax*8]
    mov rsi, r12
    mov rdx, r13
    shl rdx, 3
    call ap_memcpy
    mov [rbx + PyListObject.ob_size], r14

    ; One INCREF pass over what was copied.
    mov rax, [rbx + PyListObject.ob_item]
    mov rcx, r14
    sub rcx, r13
    lea rax, [rax + rcx*8]
    xor ecx, ecx
    jmp .lefa_incref_test
.lefa_incref:
    mov rdi, [rax + rcx*8]
    INCREF_V rdi, rsi
    inc rcx
.lefa_incref_test:
    cmp rcx, r13
    jb .lefa_incref

.lefa_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_extend_from_array

;; ============================================================================
;; list_append(rdi=list, rsi=item Value)
;; Append item, growing if needed.  INCREFs the item.
;; ============================================================================
DEF_FUNC list_append, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    mov rbx, rdi               ; list
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, rsi               ; item Value

    ; Check if need to grow
    mov rax, [rbx + PyListObject.ob_size]
    cmp rax, [rbx + PyListObject.allocated]
    jl .no_grow

    ; Double capacity
    mov rdi, [rbx + PyListObject.allocated]
    shl rdi, 1                 ; new_cap = old * 2
    mov [rbx + PyListObject.allocated], rdi

    ; Realloc payload array
    mov rdi, [rbx + PyListObject.ob_item]
    mov rsi, [rbx + PyListObject.allocated]
    shl rsi, 3                 ; new_cap * 8
    call ap_realloc
    mov [rbx + PyListObject.ob_item], rax

.no_grow:
    ; Append the item
    mov rax, [rbx + PyListObject.ob_size]
    mov rcx, [rbx + PyListObject.ob_item]
    INCREF_V r12, r13
    mov [rcx + rax * 8], r12

    ; Increment size
    inc qword [rbx + PyListObject.ob_size]

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_append

;; ============================================================================
;; list_getitem(PyListObject *list, int64_t index) -> rax = Value
;; sq_item: return item at index with bounds check and negative index support
;; ============================================================================
DEF_FUNC list_getitem

    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rdi + PyListObject.ob_item], 0
    je list_sorting_error

    ; Handle negative index
    test rsi, rsi
    jns .positive
    add rsi, [rdi + PyListObject.ob_size]
.positive:

    ; Bounds check
    cmp rsi, [rdi + PyListObject.ob_size]
    jge .index_error
    test rsi, rsi
    jl .index_error

    ; Return item with INCREF (payload + tag)
    mov rax, [rdi + PyListObject.ob_item]
    mov rax, [rax + rsi * 8]      ; payload
    V_UNPACK rax, rdx
    INCREF_VAL rax, rdx

    leave
    V_PACK rax, rdx             ; return one Value
    ret

.index_error:
    RAISE exc_IndexError_type, "list index out of range"
END_FUNC list_getitem

;; ============================================================================
;; list_setitem(PyListObject *list, int64_t index, PyObject *value, int value_tag)
;; sq_ass_item: set item at index, DECREF old, INCREF new. rcx = value_tag.
;; ============================================================================
DEF_FUNC list_setitem, 8        ; 3 pushes, so rsp is 16-aligned at the
                                ; DECREF_V below -- which calls obj_dealloc.
                                ; The three pushes that used to bracket that
                                ; release supplied this by accident; storing
                                ; before releasing removed them.
    push rbx
    push r12
    push r13

    mov rbx, rdi               ; list
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, rdx               ; new value Value

    ; Handle negative index
    test rsi, rsi
    jns .positive
    add rsi, [rbx + PyListObject.ob_size]
.positive:

    ; Bounds check
    cmp rsi, [rbx + PyListObject.ob_size]
    jge .index_error
    test rsi, rsi
    jl .index_error

    ; Install the new value BEFORE releasing the old one.
    ;
    ; Releasing first was wrong twice over.  A __del__ reached from the release
    ; saw the slot still holding the object being destroyed, where CPython's
    ; list_ass_item -- which stores first -- shows it the replacement.  And the
    ; same __del__ may append to the list or clear it, which reallocates
    ; ob_item: the address computed above was then written through after the
    ; block it pointed into had been freed.
    mov rax, [rbx + PyListObject.ob_item]
    mov rdi, [rax + rsi * 8]      ; the old occupant
    INCREF_V r12, r13
    mov [rax + rsi * 8], r12
    DECREF_V rdi, rcx             ; nothing below reads rsi

    ; 0 is "assigned", and it has to be SET.  This is an mp_ass_subscript-
    ; shaped function: op_store_subscr tests the low half of the answer for a
    ; negative, and what was left in rax here was ob_item -- a heap pointer.
    ; While that came from glibc's brk arena it was a low address with bit 31
    ; clear, so the test passed by luck.  It stops being luck the moment
    ; ob_item comes from anywhere else: a list of two hundred thousand
    ; elements is served by mmap today, and `a[0] = 1` on one raises
    ; "item assignment failed without an exception" about a third of the time.
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret

.index_error:
    RAISE exc_IndexError_type, "list assignment index out of range"
END_FUNC list_setitem

;; ============================================================================
;; list_subscript(PyListObject *list, PyObject *key) -> rax = Value
;; mp_subscript: index with int or slice key (for BINARY_SUBSCR)
;; ============================================================================
DEF_FUNC list_subscript
    V_UNPACK rsi, rdx           ; key Value -> (payload, tag)
    push rbx

    mov rbx, rdi               ; save list
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error

    ; Check if key is a SmallInt (rdx = key tag from caller)
    cmp edx, TAG_SMALLINT
    je .ls_smallint
    cmp edx, TAG_PTR            ; a float key is neither: classify
    jne .ls_index                ; fully before dereferencing, or raw
                                ; f64 bits get used as an address
    ; Check if key is a slice
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel slice_type]
    cmp rax, rcx
    je .ls_slice

.ls_index:
    ; obj_as_index_seq covers int, bool, an int subclass and __index__, and
    ; refuses anything else in the container's own words -- one message for
    ; a float key and a different one for None was two paths saying the same
    ; thing differently, and neither named the type.
    mov rdi, rsi
    lea rsi, [rel ls_index_msg]
    call obj_as_index_seq
    mov rsi, rax
    jmp .ls_do_getitem

.ls_smallint:
    ; SmallInt: payload IS the int64 index
    mov rsi, rsi               ; nop — rsi already = payload

.ls_do_getitem:

    ; Call list_getitem — already returns a Value
    mov rdi, rbx
    call list_getitem

    pop rbx
    leave
    ret

.ls_slice:
    ; Call list_getslice(list, slice)
    mov rdi, rbx
    ; rsi = slice (already set)
    call list_getslice
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

END_FUNC list_subscript

section .rodata
ls_index_msg: db `list indices must be integers or slices, not \x01`, 0
section .text

;; ============================================================================
;; list_ass_subscript(rdi=list, rsi=key Value, rdx=value Value)
;; mp_ass_subscript: set with an int or slice key.
;; A value Value of 0 (NULL) means "delete".
;; ============================================================================
LAS_VTAG  equ 8
LAS_TEMP  equ 16       ; temp list from generic iterable (NULL if not used)
LAS_EXC   equ 24       ; current_exception, to tell "exhausted" from "raised"
LAS_SRCLEN   equ 32    ; the two lengths, for the mismatch message: the
LAS_SLICELEN equ 40    ; registers holding them do not survive its unwind
LAS_FRAME equ 48            ; + 2 pushes = 64, 16-byte aligned
DEF_FUNC list_ass_subscript, LAS_FRAME
    push rbx
    push r12

    ; Decode into the (payload, tag) pairs the body uses
    V_UNPACK rsi, rcx          ; key
    V_UNPACK rdx, r8           ; value (a NULL Value unpacks to tag 0)

    mov rbx, rdi               ; list
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, rdx               ; value
    mov [rbp - LAS_VTAG], r8   ; save value tag

    ; Check if key is a SmallInt (ecx = key tag from caller)
    cmp ecx, TAG_SMALLINT
    je .las_int                ; SmallInt -> int path
    cmp ecx, TAG_PTR           ; a float key is neither: classify fully
    jne .las_int               ; before dereferencing, or its raw f64 bits
                               ; get used as an address -- a[1.5] = 9 was a
                               ; segfault, while a[1.5] already raised
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel slice_type]
    cmp rax, rcx
    je .las_slice
    mov ecx, TAG_PTR           ; the compare just above clobbered the tag

.las_int:
    ; obj_as_index_seq, not int_to_i64: it takes a bool, an int subclass and
    ; anything with __index__, refuses the rest in the container's own
    ; words, and does not truncate an int too wide for an index -- so
    ; `x[2**70] = 1` assigned to x[0] rather than raising.
    mov rdi, rsi
    mov edx, ecx              ; the key's tag
    lea rsi, [rel ls_index_msg]
    extern obj_as_index_seq
    call obj_as_index_seq
    mov rsi, rax
.las_have_key:

    ; Check if this is a delete (value_tag == TAG_NULL)
    cmp qword [rbp - LAS_VTAG], TAG_NULL
    je .las_int_delete

    ; Call list_setitem — it takes the value as a Value
    mov rdi, rbx
    mov rdx, r12
    mov rcx, [rbp - LAS_VTAG]  ; value tag from caller
    V_PACK rdx, rcx
    call list_setitem

    pop r12
    pop rbx
    leave
    ret

.las_int_delete:
    ; Delete item at index rsi from list rbx
    ; Handle negative index
    test rsi, rsi
    jns .lid_positive
    add rsi, [rbx + PyListObject.ob_size]
.lid_positive:
    ; Bounds check
    cmp rsi, [rbx + PyListObject.ob_size]
    jge .lid_index_error
    test rsi, rsi
    jl .lid_index_error

    push rsi                   ; save index

    ; DECREF old value at index
    mov rax, [rbx + PyListObject.ob_item]
    mov rdi, [rax + rsi * 8]      ; old value payload
    V_UNPACK rdi, rcx
    DECREF_VAL rdi, rcx

    pop rsi                    ; restore index

    ; Shift elements down: memmove items[i] = items[i+1] for i..size-2
    mov rcx, [rbx + PyListObject.ob_size]
    dec rcx                    ; new_size = size - 1
    mov r8, rcx
    sub r8, rsi                ; count = new_size - index

    ; Shift payload array
    mov rax, [rbx + PyListObject.ob_item]
    lea rdi, [rax + rsi * 8]      ; dst
    lea r9, [rdi + 8]             ; src = dst + 8
    push rcx
    push rsi
    push r8
    mov rsi, r9               ; src
    ; rdi already = dst
    shl r8, 3                 ; count * 8 bytes
    mov rcx, r8
    cld
    rep movsb
    pop r8
    pop rsi
    pop rcx

    ; Decrement ob_size
    mov [rbx + PyListObject.ob_size], rcx

    xor eax, eax                ; deleted; see list_setitem for why this is set
    pop r12
    pop rbx
    leave
    ret

.lid_index_error:
    RAISE exc_IndexError_type, "list assignment index out of range"

.las_slice:
    ; Slice assignment: a[start:stop] = value
    ; rbx = list, rsi = slice key, r12 = value (new items)
    push r13
    push r14
    push r15
    sub rsp, 8             ; align

    mov qword [rbp - LAS_TEMP], 0  ; no temp list yet

    ; Get slice indices relative to list length
    mov rdi, rsi           ; slice
    ; The LIVE length: a bound's __index__ can empty this very list, so the
    ; clamp has to see the length it left behind, not the one from before.
    lea rsi, [rbx + PyListObject.ob_size]
    call slice_indices_live
    ; rax = start, rdx = stop, rcx = step
    mov r13, rax           ; r13 = start
    mov r14, rdx           ; r14 = stop
    mov r15, rcx           ; r15 = step

    ; Check step
    test r15, r15
    jz .las_step_zero         ; step == 0 → ValueError
    cmp r15, 1
    jne .las_extended_step    ; step != 1 → extended slice

    ; Clamp: if stop < start, set stop = start
    cmp r14, r13
    jge .las_stop_ok
    mov r14, r13
.las_stop_ok:

    ; old_len = stop - start (number of items being replaced)
    mov rcx, r14
    sub rcx, r13           ; rcx = old_len

    ; Check if this is a deletion (value_tag == TAG_NULL means del)
    cmp qword [rbp - LAS_VTAG], TAG_NULL
    je .las_delete_slice

    ; Get new items from value (must be a list)
    ; r12 = value (the new items list/iterable)
    ; For simplicity, require value to be a list
    cmp qword [rbp - LAS_VTAG], TAG_PTR
    jne .las_type_error        ; non-heap value (SmallInt etc.) → type error
    mov rax, [r12 + PyObject.ob_type]
    lea rdx, [rel list_type]
    cmp rax, rdx
    jne .las_try_tuple

    ; Value is a list — check for self-assignment
    cmp r12, rbx
    jne .las_list_direct
    ; Self-assignment: make a shallow copy first
    push rcx                   ; save old_len (clobbered by list_copy)
    mov rdi, r12
    call list_copy
    pop rcx                    ; restore old_len
    mov r12, rax
    mov [rbp - LAS_TEMP], rax  ; store for cleanup at exit
.las_list_direct:
    mov r8, [r12 + PyListObject.ob_size]       ; r8 = new_len
    mov r9, [r12 + PyListObject.ob_item]       ; r9 = new payload ptr
    jmp .las_have_items

.las_try_tuple:
    extern tuple_type
    lea rdx, [rel tuple_type]
    cmp rax, rdx
    jne .las_try_generic

    ; Value is a tuple
    mov r8, [r12 + PyTupleObject.ob_size]
    mov r9, [r12 + PyTupleObject.ob_item]       ; payload ptr
    jmp .las_have_items

.las_try_generic:
    ; Generic iterable: iterate into a temp list, then use it.
    ; get_iterator_opt, not a tp_iter read: an object with __getitem__
    ; and no __iter__ is iterable, and the slot read rejected it.
    ; This is the one that made CPython's re parser fail on every `(?:...)`:
    ; its SubPattern has __len__ and __getitem__ and no __iter__, and
    ; _parser.py splices with `self.data[i:i+1] = p`.
    mov rdi, r12
    mov esi, TAG_PTR
    push rcx                    ; old_len; the call below clobbers rcx
    call get_iterator_opt
    test rax, rax
    jz .las_type_error_pop
    push rax                    ; save iterator

    ; Create temp list
    xor edi, edi
    call list_new
    push rax                    ; save temp list [rsp]=templist, [rsp+8]=iter, [rsp+16]=old_len
    DUNDER_EXC_SAVE [rbp - LAS_EXC]

.las_gen_loop:
    mov rdi, [rsp + 8]         ; iterator
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .las_gen_done
    mov rdi, [rsp + 8]
    call rax
    V_UNPACK rax, rdx           ; tp_iternext returns a Value
    test edx, edx
    jz .las_gen_done
    push rax
    push rdx
    mov rdi, [rsp + 16]       ; temp list (2 pushes deeper)
    mov rsi, rax
    V_PACK rsi, rdx         ; list_append takes a Value
    call list_append
    pop rsi
    pop rdi
    DECREF_VAL rdi, rsi
    jmp .las_gen_loop

.las_gen_done:
    ; tp_iternext answers NULL for "exhausted" and for a raise alike, so the
    ; two are told apart by the pending exception.  Without this a
    ; __getitem__ that raised was read as the end of the sequence and the
    ; assignment quietly succeeded with a short list.
    EXC_RAISED_SINCE [rbp - LAS_EXC], rcx, .las_gen_raised
    pop r12                     ; temp list (becomes new value)
    pop rdi                     ; iterator
    pop rcx                     ; old_len (restore)
    push rcx                    ; save old_len (obj_decref clobbers rcx)
    push r12                    ; save temp list for DECREF later
    call obj_decref             ; DECREF iterator
    pop r12                     ; restore temp list
    pop rcx                     ; restore old_len

    ; Use temp list as value — jump to list path
    mov r8, [r12 + PyListObject.ob_size]
    mov r9, [r12 + PyListObject.ob_item]       ; payload ptr
    mov [rbp - LAS_TEMP], r12      ; save for DECREF after copy
    jmp .las_have_items

.las_delete_slice:
    ; Deletion: new_len = 0, no new items to copy
    xor r8d, r8d               ; r8 = 0 (new_len)
    xor r9d, r9d               ; r9 = 0 (new payload ptr, unused)
    xor r10d, r10d             ; r10 = 0 (new tag ptr, unused)
    jmp .las_have_items

.las_gen_raised:
    ; An exception from inside the iteration.  Release the temp list and the
    ; iterator and hand the pending exception back to the caller.
    ;
    ; Everything is popped BEFORE either call: a `call` with one push still
    ; on the stack is 8 bytes out of alignment, and obj_dealloc reaches
    ; glibc, which uses aligned SSE.
    pop rdi                     ; temp list
    mov [rbp - LAS_TEMP], rdi
    pop rdi                     ; iterator
    mov [rbp - LAS_EXC], rdi    ; the snapshot is finished with
    pop rcx                     ; the saved old_len, discarded
    jmp .las_gen_release

.ext_gen_raised:
    pop rdi                     ; temp list
    mov [rbp - LAS_TEMP], rdi
    pop rdi                     ; iterator
    mov [rbp - LAS_EXC], rdi

.las_gen_release:
    mov rdi, [rbp - LAS_TEMP]
    call obj_decref
    mov qword [rbp - LAS_TEMP], 0
    mov rdi, [rbp - LAS_EXC]
    call obj_decref

.las_gen_fail:
    ; Restore exactly what .las_slice pushed -- r13, r14, r15 and the
    ; alignment pad -- then hand the pending exception to the unwinder.
    ; Returning NULL would signal nothing: op_store_subscr calls
    ; mp_ass_subscript and never looks at the result, so the exception would
    ; sit pending until some later opcode tripped over it.  get_iterator
    ; propagates the same way.
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    PUBLISH_SP
    leave
    jmp eval_exception_unwind

.las_type_error_pop:
    ; This used to FALL THROUGH into .las_have_items with r8 and r9 undefined,
    ; so a non-iterable value ran the insert with a garbage length and pointer.
    ; It was unreachable in practice while the arm above read tp_iter itself --
    ; a NULL from tp_iter is rare -- and became reachable the moment the arm
    ; started asking get_iterator_opt, which answers NULL for "not iterable".
    pop rcx                     ; discard saved old_len
    jmp .las_type_error

.las_have_items:
    ; rcx = old_len (items being removed)
    ; r8 = new_len (items being inserted)
    ; r9 = pointer to new items array
    ; r13 = start, r14 = stop
    ; rbx = list

    ; Save new items info on stack
    push r8                ; [rsp+0] = new_len
    push r9                ; [rsp+0] = new_payload_ptr, [rsp+8] = new_len
    push r10               ; [rsp+0] = new_tag_ptr, [rsp+8] = new_payload_ptr
    push rcx               ; [rsp+0] = old_len

    ; 1. DECREF old items in slice range [start..stop)
    mov rcx, r13           ; i = start
.las_decref_loop:
    cmp rcx, r14           ; i < stop?
    jge .las_decref_done
    push rcx
    push rcx                      ; twice: rsp keeps its alignment
    mov rax, [rbx + PyListObject.ob_item]
    mov rdi, [rax + rcx * 8]
    XDECREF_V rdi, rsi
    pop rcx
    pop rcx
    inc rcx
    jmp .las_decref_loop
.las_decref_done:

    ; 2. Shift elements if old_len != new_len
    pop rcx                ; old_len
    pop r10                ; new_tag_ptr
    pop r9                 ; new_payload_ptr
    pop r8                 ; new_len

    mov rax, r8
    sub rax, rcx           ; delta = new_len - old_len
    test rax, rax
    jz .las_no_shift

    ; New list size
    mov rdi, [rbx + PyListObject.ob_size]
    add rdi, rax           ; new_size = ob_size + delta
    push rdi               ; save new_size
    push r8                ; save new_len
    push r9                ; save new_items_ptr
    push r10               ; save new_tag_ptr (caller-saved, clobbered by ap_realloc)
    push rax               ; save delta
    sub rsp, 8             ; alignment

    ; Ensure capacity
    cmp rdi, [rbx + PyListObject.allocated]
    jle .las_no_realloc

    ; Grow: at least new_size, double if bigger
    mov rsi, [rbx + PyListObject.allocated]
    shl rsi, 1             ; double
    cmp rdi, rsi
    jle .las_use_double
    mov rsi, rdi           ; use new_size if larger
.las_use_double:
    mov [rbx + PyListObject.allocated], rsi
    mov rdi, [rbx + PyListObject.ob_item]
    shl rsi, 3             ; bytes (capacity * 8)
    call ap_realloc
    mov [rbx + PyListObject.ob_item], rax

.las_no_realloc:
    add rsp, 8             ; alignment
    pop rax                ; delta
    pop r10                ; new_tag_ptr
    pop r9                 ; new_items_ptr
    pop r8                 ; new_len
    pop rdi                ; new_size

    ; Shift tail: memmove(items[start+new_len], items[stop], tail_count * 16)
    ; tail_count = ob_size - stop
    push r8
    push r9
    push r10
    push rdi               ; new_size

    mov rcx, [rbx + PyListObject.ob_size]
    sub rcx, r14           ; tail_count = ob_size - stop

    test rcx, rcx
    jz .las_shift_done

    ; Shift payloads
    mov rdi, [rbx + PyListObject.ob_item]
    ; dst = payloads + (start + new_len) * 8
    mov rax, r13
    add rax, r8
    lea rdi, [rdi + rax*8]
    ; src = payloads + stop * 8
    mov rsi, [rbx + PyListObject.ob_item]
    mov rax, r14
    lea rsi, [rsi + rax*8]
    push rcx
    shl rcx, 3                ; bytes = tail_count * 8
    mov rdx, rcx
    call ap_memmove
    pop rcx

.las_shift_done:
    pop rdi                ; new_size
    mov [rbx + PyListObject.ob_size], rdi
    pop r10
    pop r9
    pop r8
    jmp .las_copy_new

.las_no_shift:
    ; Size stays the same, already correct

.las_copy_new:
    ; 3. Copy new items into [start..start+new_len), INCREF each
    test r8, r8
    jz .las_insert_done

    ; Bulk memcpy payloads: dst = list.ob_item + start*8, src = r9, len = new_len*8
    push r8                   ; save new_len [rsp+16]
    push r9                   ; save new_payload_ptr [rsp+8]
    push r10                  ; save new_tag_ptr [rsp+0]
    mov rdi, [rbx + PyListObject.ob_item]
    mov rax, r13
    lea rdi, [rdi + rax*8]              ; dst = ob_item + start*8
    mov rsi, r9               ; src = new payloads ptr
    mov rdx, r8
    shl rdx, 3
    call ap_memcpy
    mov r8, [rsp + 16]       ; restore new_len
    ; Restore all saved values for INCREF loop
    pop r10                   ; new_tag_ptr
    pop r9                    ; new_payload_ptr
    pop r8                    ; new_len
    ; Bulk INCREF all new items
    xor ecx, ecx
.las_incref_loop:
    cmp rcx, r8
    jge .las_insert_done
    mov rdi, [r9 + rcx * 8]
    INCREF_V rdi, rax
    inc rcx
    jmp .las_incref_loop

.las_insert_done:
    ; DECREF temp list if generic iterable path created one
    mov rdi, [rbp - LAS_TEMP]
    test rdi, rdi
    jz .las_no_temp
    call obj_decref
.las_no_temp:
    xor eax, eax                ; assigned; see list_setitem for why this is set
    add rsp, 8             ; undo alignment
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.las_step_zero:
    extern exc_ValueError_type
    add rsp, 8
    pop r15
    pop r14
    pop r13
    RAISE exc_ValueError_type, "slice step cannot be zero"

;; Extended slice assignment: a[start:stop:step] = iterable (step != 0, step != 1)
;; Registers on entry: rbx=list, r12=value, r13=start, r14=stop, r15=step
.las_extended_step:
    ; Compute slicelength
    test r15, r15
    js .ext_neg_step

    ; step > 0: slicelength = (stop - start - 1) / step + 1 if stop > start, else 0
    mov rax, r14
    sub rax, r13
    jle .ext_empty
    dec rax
    xor edx, edx
    idiv r15
    inc rax
    jmp .ext_have_len

.ext_neg_step:
    ; step < 0: slicelength = (start - stop - 1) / (-step) + 1 if start > stop, else 0
    mov rax, r13
    sub rax, r14
    jle .ext_empty
    dec rax
    mov rcx, r15
    neg rcx
    xor edx, edx
    idiv rcx
    inc rax
    jmp .ext_have_len

.ext_empty:
    xor eax, eax

.ext_have_len:
    mov r14, rax           ; r14 = slicelength (repurpose, stop no longer needed)

    ; Check for deletion (del a[::step])
    cmp qword [rbp - LAS_VTAG], TAG_NULL
    je .ext_delete

    ; Get replacement items from r12 (value)
    cmp qword [rbp - LAS_VTAG], TAG_PTR
    jne .las_type_error

    mov rax, [r12 + PyObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .ext_from_list
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .ext_from_tuple

.ext_from_iterable:
    ; Anything else iterable, materialised into a temp list.  CPython accepts
    ; any iterable for an extended slice and counts it before comparing
    ; lengths; this arm used to accept only a list or a tuple.
    mov rdi, r12
    mov esi, TAG_PTR
    call get_iterator_opt
    test rax, rax
    jz .las_type_error
    push rax                    ; the iterator
    xor edi, edi
    call list_new
    push rax                    ; [rsp] = temp list, [rsp+8] = iterator
    DUNDER_EXC_SAVE [rbp - LAS_EXC]
.ext_gen_loop:
    mov rdi, [rsp + 8]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .ext_gen_done
    mov rdi, [rsp + 8]
    call rax
    test rax, rax
    jz .ext_gen_done
    push rax
    push rax                    ; twice, to keep rsp 16-byte aligned
    mov rdi, [rsp + 16]         ; the temp list, two pushes deeper
    mov rsi, rax
    call list_append
    pop rdi
    pop rdi
    DECREF_V rdi, rsi           ; list_append took its own reference
    jmp .ext_gen_loop
.ext_gen_done:
    EXC_RAISED_SINCE [rbp - LAS_EXC], rcx, .ext_gen_raised
    pop r12                     ; the temp list becomes the value
    pop rdi                     ; the iterator
    push r12
    push r12
    call obj_decref
    pop r12
    pop r12
    mov [rbp - LAS_TEMP], r12   ; released at the shared exit
    mov r8, [r12 + PyListObject.ob_size]
    mov r12, [r12 + PyListObject.ob_item]
    jmp .ext_check_len

.ext_from_list:
    ; Self-assignment check: if source == target, make a shallow copy
    cmp r12, rbx
    jne .ext_list_direct
    ; Create temp copy of the list for self-assignment
    mov rdi, r12
    extern list_copy
    call list_copy
    mov r12, rax               ; r12 = temp copy list
    mov [rbp - LAS_TEMP], rax  ; store for cleanup at exit
.ext_list_direct:
    mov r8, [r12 + PyListObject.ob_size]
    mov r12, [r12 + PyListObject.ob_item]
    jmp .ext_check_len

.ext_from_tuple:
    mov r8, [r12 + PyTupleObject.ob_size]
    mov r12, [r12 + PyTupleObject.ob_item]

.ext_check_len:
    mov [rbp - LAS_SRCLEN], r8
    mov [rbp - LAS_SLICELEN], r14
    cmp r8, r14
    jne .ext_len_mismatch

    ; Loop: for each position in the slice, replace value
    ; rbx = list, r12 = source items ptr, r13 = current list index
    ; r14 = remaining count, r15 = step
    test r14, r14
    jz .las_insert_done        ; jump to shared exit

.ext_loop:
    ; DECREF old value at list[r13]
    mov rax, [rbx + PyListObject.ob_item]
    mov rdi, [rax + r13 * 8]      ; old Value
    sub rsp, 8                     ; alignment
    XDECREF_V rdi, rsi        ; may call obj_dealloc, clobbers caller-saved
    add rsp, 8

    ; INCREF the new value from the source
    mov rdi, [r12]
    INCREF_V rdi, rsi

    ; Store at list[r13]
    mov rax, [rbx + PyListObject.ob_item]
    mov [rax + r13 * 8], rdi

    ; Advance
    add r13, r15               ; next list index (start + i*step)
    add r12, 8                 ; next source item
    dec r14                    ; remaining--
    jnz .ext_loop

    jmp .las_insert_done       ; shared exit

;; Extended slice deletion: del a[start:stop:step]
;; r13 = start, r14 = slicelength, r15 = step, rbx = list
.ext_delete:
    test r14, r14
    jz .las_insert_done        ; empty slice → no-op

    ; Phase 1: DECREF items at each slice position
    mov rcx, r13               ; cur = start
    mov r8, r14                ; remaining = slicelength
.ext_del_decref:
    push rcx
    push r8
    mov rax, [rbx + PyListObject.ob_item]
    mov rdi, [rax + rcx * 8]
    XDECREF_V rdi, rsi
    pop r8
    pop rcx
    add rcx, r15              ; cur += step
    dec r8
    jnz .ext_del_decref

    ; Phase 2: Compact by shifting remaining items into gaps
    ; For step>0: deleted indices are start, start+step, start+2*step, ...
    ; For step<0: normalize to ascending order
    mov rcx, r13               ; first_del = start
    mov r8, r15                ; abs_step = step
    test r15, r15
    jns .ext_del_pos
    ; Negative step: lowest index = start + (slicelength-1)*step
    mov rax, r14
    dec rax
    imul rax, r15
    add rcx, rax              ; first_del = start + (slicelength-1)*step
    neg r8                    ; abs_step = -step
.ext_del_pos:
    ; Two-pointer compact: src walks 0..ob_size, dst skips deleted positions
    ; rcx = next_del, r8 = abs_step
    mov r10, [rbx + PyListObject.ob_size]
    mov r11, [rbx + PyListObject.ob_item]       ; payloads
    xor r9d, r9d              ; dst = 0
    mov rdi, r14               ; del_remaining = slicelength
    xor esi, esi               ; src = 0
.ext_compact_loop:
    cmp rsi, r10
    jge .ext_compact_done
    ; Check if src is a deleted position
    cmp rsi, rcx
    jne .ext_compact_copy
    test rdi, rdi
    jz .ext_compact_copy
    ; Skip this position
    add rcx, r8               ; next_del += abs_step
    dec rdi                    ; del_remaining--
    inc rsi                    ; src++
    jmp .ext_compact_loop
.ext_compact_copy:
    cmp rsi, r9
    je .ext_compact_nocopy     ; src == dst, no copy needed
    push rcx
    mov rax, [r11 + rsi * 8]
    mov [r11 + r9 * 8], rax
    pop rcx
.ext_compact_nocopy:
    inc rsi
    inc r9
    jmp .ext_compact_loop
.ext_compact_done:
    mov [rbx + PyListObject.ob_size], r9
    jmp .las_insert_done

.ext_len_mismatch:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    ; The materialised iterable is ours, and RAISE abandons the C stack:
    ; `L[::2] = G()` for any generic iterable leaked the temp list built to
    ; hold it every time the lengths disagreed.
    mov rdi, [rbp - LAS_TEMP]
    test rdi, rdi
    jz .ext_len_mismatch_raise
    mov qword [rbp - LAS_TEMP], 0
    call obj_decref
.ext_len_mismatch_raise:
    ; "attempt to assign sequence of size 3 to extended slice of size 2".
    ; The two numbers were known thirty lines up and gone by here; naming them
    ; also needed an int-to-decimal helper another file could reach, which
    ; until msg_append_i64 there was not one of.
    sub rsp, 128
    mov rdi, rsp
    lea rsi, [rel las_msg_size]
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - LAS_SRCLEN]
    extern msg_append_i64
    call msg_append_i64
    mov rdi, rax
    lea rsi, [rel las_msg_to]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - LAS_SLICELEN]
    call msg_append_i64
    lea rdi, [rel exc_ValueError_type]
    mov rsi, rsp
    extern raise_exception
    call raise_exception
    ud2

.las_type_error:
    extern exc_TypeError_type
    add rsp, 8
    pop r15
    pop r14
    pop r13
    RAISE exc_TypeError_type, "can only assign an iterable"
END_FUNC list_ass_subscript

;; ============================================================================
;; list_len(PyObject *self) -> int64_t
;; ============================================================================
DEF_FUNC_BARE list_len
    mov rax, [rdi + PyListObject.ob_size]
    ret
END_FUNC list_len

;; ============================================================================
;; list_contains(PyListObject *list, PyObject *value, int value_tag) -> int (0/1)
;; sq_contains: linear scan with identity check then __eq__ protocol
;; ============================================================================
LC_LIST    equ 8
LC_VALUE   equ 16    ; the value being searched for, as a Value
LC_IDX     equ 32
LC_SIZE    equ 40
LC_FRAME   equ 48           ; + 0 pushes = 48
DEF_FUNC list_contains, LC_FRAME
    mov [rbp - LC_LIST], rdi   ; list
    mov [rbp - LC_VALUE], rsi  ; the value Value
    mov rax, [rdi + PyListObject.ob_size]
    mov [rbp - LC_SIZE], rax
    mov qword [rbp - LC_IDX], 0

.loop:
    mov rax, [rbp - LC_IDX]
    ; Re-read the size each pass: an __eq__ running below can mutate the
    ; list, and CPython's own test_equal_operator_modifying_operand relies on
    ; the search noticing.
    mov rcx, [rbp - LC_LIST]
    mov rdx, [rcx + PyListObject.ob_size]
    cmp rax, rdx
    jge .not_found

    mov rcx, [rcx + PyListObject.ob_item]
    mov rdi, [rcx + rax * 8]        ; the element Value
    mov rsi, [rbp - LC_VALUE]

    ; The two questions a Value can answer without calling anything.  See
    ; VALUE_EQ_FAST in src/include/value.inc; index, count and remove use the
    ; same macro, and until they did they were the slow half of a family whose
    ; other half was three times CPython's speed.
    VALUE_EQ_FAST rdi, rsi, rdx, .found, .lc_next
    mov edx, PY_EQ
    call obj_richcompare_bool
    cmp eax, -1
    je .contains_error
    test eax, eax
    jnz .found

.lc_next:
    inc qword [rbp - LC_IDX]
    jmp .loop

.found:
    mov eax, 1
    leave
    ret

.not_found:
    xor eax, eax
    leave
    ret

.contains_error:
    ; sq_contains has no error channel; the exception is already pending.
    leave
    jmp eval_exception_unwind
END_FUNC list_contains

;; ============================================================================
;; list_dealloc(PyObject *self)
;; DECREF all items, free items array, free or pool list header
;; ============================================================================
DEF_FUNC list_dealloc, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    mov rbx, rdi
    mov r12, [rbx + PyListObject.ob_size]
    xor r13d, r13d

.dealloc_loop:
    cmp r13, r12
    jge .free_items
    mov rax, [rbx + PyListObject.ob_item]
    mov rdi, [rax + r13 * 8]
    XDECREF_V rdi, rsi
    inc r13
    jmp .dealloc_loop

.free_items:
    mov rdi, [rbx + PyListObject.ob_item]
    call ap_free

    ; Try to pool list header
    cmp dword [rel list_pool_count], LIST_POOL_MAX
    jge .free_header
    ; Untrack from GC before pooling
    mov rdi, rbx
    extern gc_untrack
    call gc_untrack
    ; Push to pool: reuse ob_refcnt as next-pointer
    mov rcx, [rel list_pool_head]
    mov [rbx + PyObject.ob_refcnt], rcx
    mov [rel list_pool_head], rbx
    inc dword [rel list_pool_count]
    pop r13
    pop r12
    pop rbx
    leave
    ret

.free_header:
    mov rdi, rbx
    call gc_dealloc

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_dealloc

; list_repr is in src/repr.asm
extern list_repr

;; ============================================================================
;; list_bool(PyObject *self) -> int (0/1)
;; ============================================================================
DEF_FUNC_BARE list_bool
    cmp qword [rdi + PyListObject.ob_size], 0
    setne al
    movzx eax, al
    ret
END_FUNC list_bool

;; ============================================================================
;; list_getslice(PyListObject *list, PySliceObject *slice) -> PyListObject*
;; Creates a new list from a slice of the original.
;; ============================================================================
DEF_FUNC list_getslice
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8                 ; align

    mov rbx, rdi               ; list
    mov r12, rsi               ; slice

    ; Get slice indices
    mov rdi, r12               ; slice
    lea rsi, [rbx + PyListObject.ob_size]  ; the LIVE length; see above
    call slice_indices_live
    ; rax = start, rdx = stop, rcx = step
    mov r13, rax               ; r13 = start
    mov r14, rdx               ; r14 = stop
    mov r15, rcx               ; r15 = step

    ; Compute slicelength
    test r15, r15
    jg .lgs_pos_step
    ; Negative step: if start <= stop, empty
    mov rax, r13
    sub rax, r14               ; start - stop
    jle .lgs_empty
    dec rax                    ; start - stop - 1
    mov rcx, r15
    neg rcx                    ; abs(step)
    xor edx, edx
    div rcx                    ; (start-stop-1) / abs(step)
    inc rax                    ; +1
    jmp .lgs_have_len

.lgs_pos_step:
    mov rax, r14
    sub rax, r13               ; stop - start
    jle .lgs_empty
    dec rax                    ; stop - start - 1
    xor edx, edx
    div r15                    ; (stop-start-1) / step
    inc rax                    ; +1
    jmp .lgs_have_len

.lgs_empty:
    xor eax, eax

.lgs_have_len:
    ; rax = slicelength
    push rax                   ; save slicelength
    mov rdi, rax
    call list_new_filled       ; every slot below the length is written below
    push rax                   ; save the new list

    ; Fill items: for i = 0..slicelength-1, idx = start + i*step
    ; Set new list size to slicelength (capacity already >= slicelength)
    mov rcx, [rsp + 8]        ; slicelength
    mov rdi, [rsp]             ; new list
    mov [rdi + PyListObject.ob_size], rcx

    ; Fast path: step == 1 → contiguous memcpy + bulk INCREF
    cmp r15, 1
    je .lgs_memcpy_fwd
    ; Fast path: step == -1 → contiguous memcpy + reverse + bulk INCREF
    cmp r15, -1
    je .lgs_reversed
    jmp .lgs_loop_start

.lgs_reversed:
    ; For step=-1: source is contiguous [stop+1 .. start] (slicelength elements)
    ; Copy forward, then reverse in place
    mov rax, r14               ; stop
    inc rax                    ; stop+1 = source start index
    ; Copy payloads
    mov rsi, [rbx + PyListObject.ob_item]
    mov rcx, rax
    lea rsi, [rsi + rcx*8]              ; src payloads + (stop+1)*8
    mov rdi, [rsp]            ; new list
    mov rdi, [rdi + PyListObject.ob_item]  ; dst payloads
    push rax                   ; save source start index
    mov rdx, [rsp + 16]       ; slicelength (rsp+8=saved_idx, rsp+16=slicelength)
    shl rdx, 3
    call ap_memcpy

    pop rax                    ; restore source start index

    ; Reverse in place: a[::-1] is the forward block, turned round.
    mov rsi, [rsp + 8]        ; slicelength
    mov rdi, [rsp]            ; new list
    mov rdi, [rdi + PyListObject.ob_item]
    call list_reverse_values
.lgs_rev_done:
    ; Bulk INCREF (reuse common path)
    jmp .lgs_incref_start

.lgs_memcpy_fwd:
    ; Copy payloads (contiguous)
    mov rsi, [rbx + PyListObject.ob_item]
    mov rax, r13
    lea rsi, [rsi + rax*8]              ; src payloads
    mov rdi, [rsp]            ; new list
    mov rdi, [rdi + PyListObject.ob_item]  ; dst payloads
    mov rdx, [rsp + 8]        ; slicelength
    shl rdx, 3
    call ap_memcpy

    ; Bulk INCREF all copied elements
.lgs_incref_start:
    mov rcx, [rsp + 8]        ; slicelength
    test rcx, rcx
    jz .lgs_done
    mov rdi, [rsp]             ; new list
    mov rdi, [rdi + PyListObject.ob_item]
    xor edx, edx
.lgs_incref_loop:
    cmp rdx, rcx
    jge .lgs_done
    mov r8, [rdi + rdx * 8]
    INCREF_V r8, r9
    inc rdx
    jmp .lgs_incref_loop

.lgs_loop_start:
    xor ecx, ecx              ; i = 0
.lgs_loop:
    cmp rcx, [rsp + 8]        ; slicelength
    jge .lgs_done
    ; idx = start + i * step
    mov rax, rcx
    imul rax, r15              ; i * step
    add rax, r13               ; start + i * step
    ; Get item from source list
    mov rdx, [rbx + PyListObject.ob_item]
    mov r8, [rdx + rax * 8]       ; item Value
    INCREF_V r8, r9
    ; Store item into new list
    mov rdi, [rsp]             ; new list
    mov rdi, [rdi + PyListObject.ob_item]
    mov [rdi + rcx * 8], r8
    inc rcx
    jmp .lgs_loop

.lgs_done:
    pop rax                    ; new list
    add rsp, 8                 ; discard slicelength

    add rsp, 8                 ; undo alignment
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov edx, TAG_PTR
    leave
    ret
END_FUNC list_getslice

;; ============================================================================
;; list_reverse_values(rdi = Value[], rsi = n) -> void
;;
;; Reverse a run of Values in place.  No refcount traffic: the array owns
;; exactly what it owned before.
;;
;; Four elements an iteration, two from each end: a 16-byte load holds two
;; Values, pshufd exchanges them, and the two halves are stored crosswise.
;; The scalar loop that was here moved two, and gcc vectorises CPython's
;; reverse_slice the same way, which is the whole of why list.reverse() was
;; half CPython's speed on a thousand-element list.
;; ============================================================================
global list_reverse_values
DEF_FUNC_BARE list_reverse_values
    cmp rsi, 2
    jb .lrv_done
    lea rdx, [rdi + rsi*8]      ; one past the last

.lrv_wide:
    lea rax, [rdi + 32]         ; the two 16-byte windows must not overlap
    cmp rax, rdx
    ja .lrv_narrow
    movdqu xmm0, [rdi]
    movdqu xmm1, [rdx - 16]
    pshufd xmm0, xmm0, 0x4E     ; swap the two Values within each window
    pshufd xmm1, xmm1, 0x4E
    movdqu [rdi], xmm1
    movdqu [rdx - 16], xmm0
    add rdi, 16
    sub rdx, 16
    jmp .lrv_wide

.lrv_narrow:
    sub rdx, 8                  ; the last element
.lrv_loop:
    cmp rdi, rdx
    jae .lrv_done
    mov rax, [rdi]
    mov rcx, [rdx]
    mov [rdi], rcx
    mov [rdx], rax
    add rdi, 8
    sub rdx, 8
    jmp .lrv_loop
.lrv_done:
    ret
END_FUNC list_reverse_values

;; ============================================================================
;; list_incref_range(rdi = Value[], rsi = count) -> void
;;
;; One reference for each element of a run.  A Value that is not a pointer
;; owns nothing and is skipped, which is the whole of INCREF_V.  The array
;; pointer and the end are in registers, so the loop is a load, a test, an
;; increment and a compare.
;; ============================================================================
DEF_FUNC_LOCAL list_incref_range
    test rsi, rsi
    jz .lir_done
    lea rsi, [rdi + rsi*8]
.lir_loop:
    mov rax, [rdi]
    INCREF_V rax, rcx
    add rdi, 8
    cmp rdi, rsi
    jb .lir_loop
.lir_done:
    leave
    ret
END_FUNC list_incref_range

;; ============================================================================
;; list_incref_range_by(rdi = Value[], rsi = count, rdx = n) -> void
;;
;; n references for each element, in one addition rather than n increments --
;; CPython's _Py_RefcntAdd, and for the same caller: a repeat puts every
;; source element into the result exactly n times.
;; ============================================================================
DEF_FUNC_LOCAL list_incref_range_by
    test rsi, rsi
    jz .lirb_done
    lea rsi, [rdi + rsi*8]
.lirb_loop:
    mov rax, [rdi]
    lea rcx, [rax - 1]
    cmp rcx, [rel v_ptr_max_m1]
    ja .lirb_next
    add [rax + PyObject.ob_refcnt], rdx
.lirb_next:
    add rdi, 8
    cmp rdi, rsi
    jb .lirb_loop
.lirb_done:
    leave
    ret
END_FUNC list_incref_range_by

;; ============================================================================
;; list_concat(PyListObject *a, PyObject *b) -> PyListObject*
;; Concatenate two lists: [1,2] + [3,4] -> [1,2,3,4]
;; ============================================================================
LCC_NEW   equ 8                 ; the new list, across the two memcpys
LCC_FRAME equ 16                ; + 4 pushes = 48, 16-aligned
DEF_FUNC list_concat, LCC_FRAME
    BINOP_REQUIRE_LEFT list_type, TYPE_FLAG_LIST_SUBCLASS, 1
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi            ; rbx = list a
    mov r12, rsi            ; r12 = list b

    ; b is read as a list below.  An immediate's payload is not an address,
    ; and this worked on a tuple only by layout accident -- PyTupleObject
    ; happens to carry ob_size and ob_item at the same offsets.
    cmp ecx, TAG_PTR
    jne .lc_type_error
    mov rax, [r12 + PyObject.ob_type]
    REQUIRE_LIST_TYPE rax, rcx, .lc_type_error_ptr

    ; Get sizes
    mov r13, [rbx + PyListObject.ob_size]   ; r13 = len(a)
    mov r14, [r12 + PyListObject.ob_size]   ; r14 = len(b)

    ; Allocate new list with total capacity.  Both halves are written in
    ; full below, so only the tail is owed a zero.
    lea rdi, [r13 + r14]
    call list_new_filled
    mov [rbp - LCC_NEW], rax    ; one slot, read three times: the loop that
                            ; used to be here reloaded the list from the stack
                            ; and then ob_item off it, once per element

    lea rcx, [r13 + r14]
    mov [rax + PyListObject.ob_size], rcx

    ; Both halves move as blocks; the references are taken afterwards, in one
    ; pass over the result.  Values, so the two are independent -- there is no
    ; per-element interleaving of a copy with a refcount.
    mov rdi, [rbp - LCC_NEW]
    mov rdi, [rdi + PyListObject.ob_item]
    mov rsi, [rbx + PyListObject.ob_item]
    mov rdx, r13
    shl rdx, 3
    call ap_memcpy

    mov rdi, [rbp - LCC_NEW]
    mov rdi, [rdi + PyListObject.ob_item]
    lea rdi, [rdi + r13*8]
    mov rsi, [r12 + PyListObject.ob_item]
    mov rdx, r14
    shl rdx, 3
    call ap_memcpy

    mov rdi, [rbp - LCC_NEW]
    mov rdi, [rdi + PyListObject.ob_item]
    lea rsi, [r13 + r14]
    call list_incref_range

    mov rax, [rbp - LCC_NEW]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
.lc_type_error_ptr:
    mov ecx, TAG_PTR            ; REQUIRE_LIST_TYPE used rcx as its scratch
.lc_type_error:
    ; The right operand's payload survives in r12; its tag does not always --
    ; REQUIRE_*_TYPE uses rcx as scratch -- so the pointer case is recovered
    ; from the payload itself, which is its own Value.
    mov rdi, r12
    mov rsi, rcx
    VALUE_FOR_TYPE rdi, rsi
    mov rsi, rdi
    CSTRING rdi, `can only concatenate list (not "\x01") to list`
    extern raise_type_error_with_name
    call raise_type_error_with_name
END_FUNC list_concat

;; ============================================================================
;; list_repeat(PyListObject *list, PyObject *count) -> PyListObject*
;; Repeat a list: [1,2] * 3 -> [1,2,1,2,1,2]
;; ============================================================================
LRP_NEW   equ 8                 ; the new list, across the copies
LRP_DONE  equ 16                ; how much of it is written
LRP_FRAME equ 16                ; + 4 pushes = 48, 16-aligned
DEF_FUNC list_repeat, LRP_FRAME
    BINOP_REQUIRE_LEFT list_type, TYPE_FLAG_LIST_SUBCLASS, 1
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi            ; rbx = list
    mov rdi, rsi            ; count (int payload)
    mov edx, ecx            ; count tag (right operand)
    ; A count too large for int64 truncates through __gmpz_get_si, so
    ; [0] * (2**64) quietly returned [].
    ; The count must be an index.  int_fits_i64 and int_to_i64 both read
    ; PyIntObject fields, so a str or a float count was dereferenced as one:
    ; "a" * "2" segfaulted and [1] * None reported an OverflowError.
    mov rsi, rdi
    mov rcx, rdx
    V_PACK rsi, rcx
    ; Not a count at all: DECLINE rather than raise, so the protocol carries
    ; on to the right operand's __rmul__.  This raised, and `[1] * R()` for an
    ; R with an __rmul__ never reached it.  op_binary_op words the failure
    ; when nothing else answers either.
    mov rdi, rsi
    push rsi
    push rsi                    ; twice: rsp keeps its alignment
    extern binop_is_count
    call binop_is_count
    pop rsi
    pop rsi
    test eax, eax
    jz .rep_decline
    extern seq_repeat_count
    call seq_repeat_count    ; __index__ counts, and one too big to be an
    mov r12, rax             ; index is refused rather than truncated

    ; Clamp negative to 0
    test r12, r12
    jg .rep_positive
    xor r12d, r12d
.rep_positive:

    mov r13, [rbx + PyListObject.ob_size]   ; r13 = len(list)
    mov r14, r13
    imul r14, r12                            ; r14 = total items
    jo .rep_overflow                         ; signed overflow → MemoryError
    ; Sanity check: total_items * 8 must fit in address space
    cmp r14, 0x10000000                      ; 256M items limit (~2GB)
    ja .rep_toobig                           ; too large to allocate

    ; Allocate new list.  The copies below write every slot.
    mov rdi, r14
    call list_new_filled
    mov [rbp - LRP_NEW], rax
    mov [rax + PyListObject.ob_size], r14
    test r14, r14
    jz .rep_done

    ; One copy of the source, and then the RESULT copied onto itself, each
    ; time doubling what is written -- CPython's _Py_memory_repeat.  The
    ; element-at-a-time nest that was here ran the source r12 times and
    ; touched a refcount at every step; this touches each refcount once and
    ; moves the rest in log2(r12) block copies.
    mov rdi, [rax + PyListObject.ob_item]
    mov rsi, [rbx + PyListObject.ob_item]
    mov rdx, r13
    shl rdx, 3
    call ap_memcpy

    ; Every source element lands in the result r12 times, so its refcount
    ; rises by r12 -- one addition, not r12 increments.
    mov rdi, [rbx + PyListObject.ob_item]
    mov rsi, r13
    mov rdx, r12
    call list_incref_range_by

    mov [rbp - LRP_DONE], r13
.rep_double:
    mov rcx, [rbp - LRP_DONE]
    cmp rcx, r14
    jae .rep_done
    mov rdx, rcx                ; as much again as is already written,
    mov rax, r14                ; or only what is left
    sub rax, rcx
    cmp rdx, rax
    cmova rdx, rax
    mov rdi, [rbp - LRP_NEW]
    mov rdi, [rdi + PyListObject.ob_item]
    mov rsi, rdi
    lea rdi, [rdi + rcx*8]
    add [rbp - LRP_DONE], rdx
    shl rdx, 3
    call ap_memcpy
    jmp .rep_double

.rep_done:
    mov rax, [rbp - LRP_NEW]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.rep_decline:
    xor eax, eax
    xor edx, edx
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.rep_toobig:
    ; Too large to allocate is a MemoryError in CPython; only a count that
    ; does not fit an index is an OverflowError.
    extern exc_MemoryError_type
    RAISE exc_MemoryError_type, ""
.rep_overflow:
    extern exc_OverflowError_type
    RAISE exc_OverflowError_type, "too many items for list repetition"
END_FUNC list_repeat

;; ============================================================================
;; list_inplace_concat(left, right, left_tag, right_tag) -> (rax, edx)
;; nb_iadd / sq_inplace_concat: extend left list in-place with right iterable
;; Returns (left, TAG_PTR) — same object.
;; ============================================================================
LIC_SELF   equ 8
LIC_ITER   equ 16
LIC_EXC    equ 24           ; current_exception before the iteration started
; The right operand as it ARRIVED.  The refusal names its type, and the
; (payload, tag) pair it was unpacked into does not survive the fast paths:
; .lic_list reuses r13 for a length, so the tag read there was a size.
LIC_RIGHT  equ 32
LIC_FRAME  equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC list_inplace_concat, LIC_FRAME
    mov [rbp - LIC_RIGHT], rsi
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    push rbx
    push r12
    push r13

    mov rbx, rdi              ; left = self (list)
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, rsi              ; right (iterable payload)
    mov r13, rcx              ; right_tag
    mov [rbp - LIC_SELF], rdi

    ; Check right type for fast paths
    test r13d, TAG_RC_BIT
    jz .lic_type_error         ; non-pointer → error

    mov rax, [r12 + PyObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .lic_list
    extern tuple_type
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .lic_tuple
    jmp .lic_generic

    ; Both shapes are a contiguous Value array and a size; only the field
    ; offsets differ.  list_extend_from_array grows once and copies once, and
    ; it is the same helper LIST_EXTEND and list.extend use -- `l += l`
    ; included, which is why it handles a source that is the destination's
    ; own array.
.lic_list:
    mov rdx, [r12 + PyListObject.ob_size]
    mov rsi, [r12 + PyListObject.ob_item]
    jmp .lic_from_array

.lic_tuple:
    mov rdx, [r12 + PyTupleObject.ob_size]
    mov rsi, [r12 + PyTupleObject.ob_item]

.lic_from_array:
    mov rdi, rbx
    call list_extend_from_array
    jmp .lic_done

.lic_generic:
    ; get_iterator_opt, not a tp_iter read: an object with __getitem__
    ; and no __iter__ is iterable, and the slot read rejected it.
    mov rdi, r12
    mov esi, TAG_PTR
    call get_iterator_opt
    test rax, rax
    jz .lic_type_error
    mov [rbp - LIC_ITER], rax

    DUNDER_EXC_SAVE [rbp - LIC_EXC]
.lic_gen_loop:
    mov rdi, [rbp - LIC_ITER]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .lic_gen_done
    mov rdi, [rbp - LIC_ITER]
    call rax
    V_UNPACK rax, rdx           ; tp_iternext returns a Value
    test edx, edx
    jz .lic_gen_done

    push rax
    push rdx
    mov rdi, rbx
    mov rsi, rax
    V_PACK rsi, rdx         ; list_append takes a Value
    call list_append
    pop rsi
    pop rdi
    DECREF_VAL rdi, rsi
    jmp .lic_gen_loop

.lic_gen_done:
    mov rdi, [rbp - LIC_ITER]
    call obj_decref

    ; NULL is exhaustion or a raise alike: `L += G()` for a raising
    ; __getitem__ appended a short run and handed L back as a success.
    EXC_RAISED_SINCE [rbp - LIC_EXC], rcx, .lic_gen_raised

.lic_done:
    ; Return (self, TAG_PTR) — INCREF self
    INCREF rbx
    mov rax, rbx
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.lic_gen_raised:
    ; Not a NULL return: this is an nb_inplace_add slot, and op_binary_op
    ; reads NULL from a slot as "declined", which it reports as
    ; "unsupported operand type(s)" -- burying the exception the iterator
    ; raised.  Unwind directly, exactly as .lic_type_error's RAISE does.
    ; The operands are back on the value stack once the unwinder restores
    ; r13, so they are not released here either.
    extern eval_exception_unwind
    pop r13
    pop r12
    pop rbx
    leave
    jmp eval_exception_unwind

.lic_type_error:
    ; `L += x` is L.extend(x), so what it needs of x is that it be ITERABLE --
    ; and that is what CPython says when it is not: "'N' object is not
    ; iterable".  The concatenation wording belongs to `L + x`, where the
    ; right operand has to be a list and not merely iterable; this reported
    ; the wrong requirement for the wrong operator.
    ;
    mov rsi, [rbp - LIC_RIGHT]
    CSTRING rdi, `'\x01' object is not iterable`
    extern raise_type_error_with_name
    call raise_type_error_with_name
END_FUNC list_inplace_concat

;; ============================================================================
;; list_inplace_repeat(left, right, left_tag, right_tag) -> (rax, edx)
;; nb_imul / sq_inplace_repeat: repeat left list in-place by right integer
;; Returns (left, TAG_PTR) — same object.
;; ============================================================================
LIR_OLDSIZE equ 16
LIR_FRAME   equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC list_inplace_repeat, LIR_FRAME
    ; The count must be an integer, or something with an __index__: `[1] *
    ; Index()` is a list of three in CPython and this declined it, and the
    ; caller then reported the failure as an unsupported `*`.  Anything else
    ; still declines, so a right operand with an __rmul__ of its own is still
    ; asked -- which is the order CPython's PyNumber_InPlaceMultiply keeps.
    ; Checked before the pushes, so the decline is a bare leave/ret.
    push rdi                    ; save the left Value (both are leaves, so the
    mov rdi, rsi                ; odd rsp across the calls is harmless)
    V_UNPACK rdi, rdx           ; right Value -> (payload, tag)
    call int_is_integer
    pop rdi
    test eax, eax
    jnz .lir_have_count
    push rdi
    mov rdi, rsi
    extern binop_is_count
    call binop_is_count
    pop rdi
    test eax, eax
    jz .lir_decline
.lir_have_count:
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    push rbx
    push r12
    push r13

    mov rbx, rdi              ; self (list)
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error

    ; The same funnel sq_repeat uses.  int_to_i64 truncated, so `a *= 2**64`
    ; emptied the list instead of refusing.
    extern seq_repeat_count
    call seq_repeat_count
    mov r12, rax              ; r12 = count

    ; Handle count <= 0: clear list
    test r12, r12
    jle .lir_clear

    ; count == 1: no-op
    cmp r12, 1
    je .lir_done

    ; count >= 2: replicate items
    mov rax, [rbx + PyListObject.ob_size]
    mov [rbp - LIR_OLDSIZE], rax
    test rax, rax
    jz .lir_done              ; empty list * n = empty list

    ; Grow items array: new_cap = old_size * count
    mov r13, rax              ; r13 = old_size
    imul rax, r12             ; rax = old_size * count = new_size
    ; As sq_repeat: a product too big to allocate is a MemoryError, and
    ; OverflowError is kept for a COUNT that will not fit an index -- which
    ; seq_repeat_count above has already refused.
    jo .lir_toobig
    cmp rax, 0x10000000        ; 256M items limit
    ja .lir_toobig
    push rax                  ; save new_size

    ; Realloc payloads
    mov rdi, [rbx + PyListObject.ob_item]
    mov rsi, rax
    shl rsi, 3                ; new_size * 8
    call ap_realloc
    mov [rbx + PyListObject.ob_item], rax
    pop rax                   ; new_size
    mov [rbx + PyListObject.ob_size], rax
    mov [rbx + PyListObject.allocated], rax

    ; Copy items (count - 1) more times + INCREF each copy
    mov rax, [rbx + PyListObject.ob_item]       ; payloads
    mov ecx, 1                      ; copy number (1-based)
.lir_copy_outer:
    cmp rcx, r12
    jge .lir_done
    push rcx

    ; Destination base index = copy_num * old_size
    mov rdx, rcx
    imul rdx, r13             ; dest base index

    ; Copy old_size elements (16 bytes each)
    xor ecx, ecx
.lir_copy_inner:
    cmp rcx, r13
    jge .lir_copy_next
    mov r9, [rax + rcx * 8]       ; src item
    mov [rax + rdx * 8], r9

    ; INCREF copied item
    push rax
    push rcx
    push rdx
    INCREF_V r9, r10
    pop rdx
    pop rcx
    pop rax

    inc rdx
    inc rcx
    jmp .lir_copy_inner

.lir_copy_next:
    pop rcx
    inc rcx
    jmp .lir_copy_outer

.lir_clear:
    ; DECREF all items, set size=0
    mov r13, [rbx + PyListObject.ob_size]
    xor ecx, ecx
.lir_clear_loop:
    cmp rcx, r13
    jge .lir_clear_done
    mov rax, [rbx + PyListObject.ob_item]
    push rcx
    push rcx                      ; twice: rsp keeps its alignment
    mov rdi, [rax + rcx * 8]
    DECREF_V rdi, rsi
    pop rcx
    pop rcx
    inc rcx
    jmp .lir_clear_loop
.lir_clear_done:
    mov qword [rbx + PyListObject.ob_size], 0

.lir_done:
    INCREF rbx
    mov rax, rbx
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
.lir_toobig:
    extern exc_MemoryError_type
    RAISE exc_MemoryError_type, ""
.lir_decline:
    ; Reached before the pushes, so there is no mirror to unwind.
    xor eax, eax                ; NULL Value = NotImplemented
    leave
    ret
END_FUNC list_inplace_repeat

;; ============================================================================
;; list_type_call(PyTypeObject *type, PyObject **args, int64_t nargs) -> PyListObject*
;; Constructor: list() or list(iterable)
;; ============================================================================
; Frame layout
LTC_LIST    equ 8       ; new list object
LTC_ITER    equ 16      ; iterator object
LTC_EXC     equ 24      ; current_exception on entry, to tell "raised" from
                        ; "already being handled"
LTC_FRAME   equ 40          ; + 3 pushes = 64, 16-aligned -- this frame
                            ; reaches glibc through ap_malloc

DEF_FUNC list_type_call, LTC_FRAME
    push rbx
    push r12
    push r13
    DUNDER_EXC_SAVE [rbp - LTC_EXC]

    mov r12, rsi            ; args
    mov r13, rdx            ; nargs

    ; Reject keyword arguments
    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jnz .ltc_kwarg_error

    ; list() — no args: return empty list
    test r13, r13
    jz .ltc_empty

    ; list(iterable) — exactly 1 arg
    cmp r13, 1
    jne .ltc_error

    ; An EXACT list or tuple is a contiguous Value array and a size, so no
    ; iterator is needed at all: one allocation and one memcpy.  A subclass
    ; is not eligible -- it may define __iter__ -- which is what the exact
    ; type compares are for.
    mov rdi, [r12]
    V_TEST_PTR rdi, rax
    ja .ltc_make_list
    test rdi, rdi
    jz .ltc_make_list
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .ltc_from_list
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    jne .ltc_make_list
    mov r13, [rdi + PyTupleObject.ob_size]
    mov rbx, [rdi + PyTupleObject.ob_item]
    jmp .ltc_from_array
.ltc_from_list:
    mov r13, [rdi + PyListObject.ob_size]
    mov rbx, [rdi + PyListObject.ob_item]
.ltc_from_array:
    mov rdi, r13
    call list_new_filled
    mov [rbp - LTC_LIST], rax
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r13
    mov rbx, [rbp - LTC_LIST]
    call list_extend_from_array
    mov rax, rbx
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ltc_make_list:
    ; A length the source cannot report is a failure, not a hint to skip:
    ; CPython asks PyObject_LengthHint first, so `list(range(1 << 70))`
    ; raises the OverflowError its __len__ raises rather than looping until
    ; the machine runs out of memory.
    ;
    ; The answer is also used, which it was not before: it is the capacity to
    ; start at, so `list(range(1000))` stops walking the doubling curve.
    xor r13d, r13d          ; the length hint, 0 when there is none
    mov rdi, [r12]
    V_TEST_PTR rdi, rax
    ja .ltc_no_length
    test rdi, rdi
    jz .ltc_no_length
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .ltc_no_length
    mov rax, [rax + PySequenceMethods.sq_length]
    test rax, rax
    jz .ltc_no_length
    mov rdi, [r12]
    call rax
    test rax, rax
    jl .ltc_length_hint_failed
    mov r13, rax
.ltc_no_length:
    mov rdi, r13
    call list_new
    mov [rbp - LTC_LIST], rax
    mov rbx, rax            ; rbx = new list

    ; Get iterator from arg (supports heaptypes with __iter__)
    mov rdi, [r12]          ; args[0]
    V_UNPACK rdi, rsi
    extern get_iterator
    call get_iterator
    mov [rbp - LTC_ITER], rax

    ; Iterate and append (call_iternext handles heaptype __next__)
.ltc_loop:
    mov rdi, [rbp - LTC_ITER]
    extern call_iternext
    call call_iternext
    V_UNPACK rax, rdx           ; call_iternext returns a Value
    test edx, edx
    jz .ltc_done            ; StopIteration

    ; Append item to list (preserve actual tag from iternext)
    push rax                ; save item payload
    push rdx                ; save item tag
    mov rdi, rbx
    mov rsi, rax
    ; edx = tag from tp_iternext (already set)
    V_PACK rsi, rdx         ; list_append takes a Value
    call list_append
    ; DECREF item (list_append INCREFs internally, tag-aware)
    pop rsi                 ; item tag
    pop rdi                 ; item payload
    DECREF_VAL rdi, rsi
    jmp .ltc_loop

.ltc_done:
    ; DECREF iterator
    mov rdi, [rbp - LTC_ITER]
    call obj_decref

    ; Did iternext raise (a zip strict ValueError, say), or was something
    ; already being handled?  A bare test against 0 cannot tell: inside an
    ; `except` block current_exception is the exception being handled, so
    ; list(x) there re-raised it.
    EXC_RAISED_SINCE [rbp - LTC_EXC], rax, .ltc_exc_cleanup

    mov rax, rbx            ; return the list
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ltc_exc_cleanup:
    ; DECREF the partially-built list, return NULL to propagate exception
    mov rdi, rbx
    call obj_decref
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ltc_empty:
    xor edi, edi
    call list_new
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ltc_not_iterable:
    extern exc_TypeError_type
    RAISE exc_TypeError_type, "list() argument must be an iterable"

.ltc_length_hint_failed:
    ; sq_length answered -1 and left an exception; hand it on.  The list does
    ; not exist yet -- the probe now runs before it is made, so that its
    ; answer can be the capacity -- so there is nothing to release.
    xor eax, eax
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ltc_error:
    mov rsi, r13
    CSTRING rdi, "list expected at most 1 argument, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted

.ltc_kwarg_error:
    ; Clear kw_names_pending to avoid stale state
    mov qword [gs:ThreadState.kw_names_pending], 0
    RAISE exc_TypeError_type, "list() takes no keyword arguments"
END_FUNC list_type_call

;; ============================================================================
;; Data section
;; ============================================================================
section .data

; List header pool (freelist, singly-linked via ob_refcnt)
align 8
list_pool_head:  dq 0       ; freelist head
list_pool_count: dd 0       ; current count
                 dd 0       ; padding

list_name_str: db "list", 0
; list_repr_str removed - repr now in src/repr.asm

; List number methods (just bool)
align 8
list_number_methods:
    dq 0                    ; nb_add -- concatenation is sq_concat, as in
                            ; CPython, so that PyNumber_Add can ask the RIGHT
                            ; operand before falling back to it
    dq 0                    ; nb_subtract
    dq list_repeat          ; nb_multiply (list repetition)
    dq 0                    ; nb_remainder
    dq 0                    ; nb_divmod
    dq 0                    ; nb_power
    dq 0                    ; nb_negative
    dq 0                    ; nb_positive
    dq 0                    ; nb_absolute
    dq list_bool            ; nb_bool
    dq 0                    ; nb_invert
    dq 0                    ; nb_lshift
    dq 0                    ; nb_rshift
    dq 0                    ; nb_and
    dq 0                    ; nb_xor
    dq 0                    ; nb_or
    dq 0                    ; nb_int
    dq 0                    ; nb_float
    dq 0                    ; nb_floor_divide
    dq 0                    ; nb_true_divide
    dq 0                    ; nb_index
    dq 0                        ; nb_iadd -- `l += x` is sq_inplace_concat, as
                                ; in CPython.  Through nb_iadd it ran ahead of
                                ; the reflected half, so `l += obj` for an obj
                                ; with only an __radd__ reported that the obj
                                ; was not iterable instead of asking it.
    dq 0                        ; nb_isub         +176
    dq list_inplace_repeat      ; nb_imul         +184
    dq 0                        ; nb_irem         +192
    dq 0                        ; nb_ipow         +200
    dq 0                        ; nb_ilshift      +208
    dq 0                        ; nb_irshift      +216
    dq 0                        ; nb_iand         +224
    dq 0                        ; nb_ixor         +232
    dq 0                        ; nb_ior          +240
    dq 0                        ; nb_ifloor_divide +248
    dq 0                        ; nb_itrue_divide +256
    dq 0 ; nb_matmul
    dq 0 ; nb_imatmul

; List sequence methods
align 8
list_sequence_methods:
    dq list_len             ; sq_length
    dq list_concat          ; sq_concat
    dq list_repeat          ; sq_repeat
    dq list_getitem         ; sq_item
    dq list_setitem         ; sq_ass_item
    dq list_contains        ; sq_contains
    dq list_inplace_concat  ; sq_inplace_concat
    dq list_inplace_repeat  ; sq_inplace_repeat

section .text

;; ============================================================================
;; list_richcompare(left, right, op, left_tag, right_tag) -> (rax, edx)
;; Compare two lists. Returns bool fat value.
;; Supports EQ, NE, LT, LE, GT, GE (lexicographic for ordering).
;; ============================================================================
; Comparing two structures that reach each other -- a=[]; a.append(a);
; b=[]; b.append(b); a==b -- recursed until the machine stack ran out; the
; identity fast path inside only catches a==a.  The body is wrapped so its
; several exits need not each be touched.
DEF_FUNC list_richcompare
    C_RECURSION_ENTER .lrc_too_deep
    call list_richcompare_inner
    C_RECURSION_LEAVE
    leave
    ret
.lrc_too_deep:
    C_RECURSION_LEAVE
    RAISE exc_RecursionError_type, "maximum recursion depth exceeded in comparison"
END_FUNC list_richcompare

LRC_LEFT     equ 8
LRC_RIGHT    equ 16
LRC_OP       equ 24
LRC_IDX      equ 32
LRC_FRAME    equ 48         ; + 0 pushes = 48

;; CPython's list_richcompare, followed exactly.  The old version precomputed
;; min(len) once and, on finding an unequal element, returned that element's
;; verdict.  CPython instead re-reads both sizes -- an element's __eq__ can
;; clear either list, and bpo-38588 is the test for it -- and if the index has
;; run off the end of what is left, compares the *current* sizes instead.  So
;; [X()] == [Y()], where each __eq__ empties the other list, is True.
DEF_FUNC_LOCAL list_richcompare_inner, LRC_FRAME
    ; Verify right is a list; anything else is NotImplemented.
    V_TEST_PTR rsi, rax
    ja .lrc_not_impl
    mov rax, [rsi + PyObject.ob_type]
    REQUIRE_LIST_TYPE rax, r9, .lrc_not_impl

    mov [rbp - LRC_LEFT], rdi
    mov [rbp - LRC_RIGHT], rsi
    mov [rbp - LRC_OP], rdx
    mov qword [rbp - LRC_IDX], 0

    ; Lengths that differ settle == and != without looking at an element,
    ; which is CPython's first line here too.  It is not merely a shortcut:
    ; the loop below cannot reach this answer cheaply, because it compares
    ; min(len) elements first and only then falls out to the size compare.
    mov edx, [rbp - LRC_OP]
    cmp edx, PY_EQ
    je .lrc_len_shortcut
    cmp edx, PY_NE
    jne .lrc_elem_loop
.lrc_len_shortcut:
    mov rax, [rdi + PyListObject.ob_size]
    cmp rax, [rsi + PyListObject.ob_size]
    jne .lrc_ran_out            ; which compares the sizes for this op

.lrc_elem_loop:
    ; while (i < len(v) && i < len(w))
    mov rax, [rbp - LRC_IDX]
    mov rcx, [rbp - LRC_LEFT]
    cmp rax, [rcx + PyListObject.ob_size]
    jge .lrc_ran_out
    mov rcx, [rbp - LRC_RIGHT]
    cmp rax, [rcx + PyListObject.ob_size]
    jge .lrc_ran_out

    mov rcx, [rbp - LRC_LEFT]
    mov rcx, [rcx + PyListObject.ob_item]
    mov rdi, [rcx + rax * 8]
    mov rcx, [rbp - LRC_RIGHT]
    mov rcx, [rcx + PyListObject.ob_item]
    mov rsi, [rcx + rax * 8]
    ; The two questions a Value can answer without calling anything -- see
    ; VALUE_EQ_FAST.  For two lists of small integers this is the whole
    ; comparison, and `a == b` over interned or immediate elements becomes a
    ; pointer scan with no refcount traffic, which is what CPython's own
    ; per-element `if (vitem == witem) continue;` buys it.
    VALUE_EQ_FAST rdi, rsi, rdx, .lrc_next, .lrc_differ
    mov edx, PY_EQ
    call obj_richcompare_bool
    cmp eax, -1
    je .lrc_error
    test eax, eax
    jz .lrc_differ               ; first differing element

.lrc_next:
    inc qword [rbp - LRC_IDX]
    jmp .lrc_elem_loop

.lrc_differ:
    ; The comparison may have shortened either list.  If the index is now
    ; past the end of one of them, there is no element left to compare and
    ; the sizes decide.
    mov rax, [rbp - LRC_IDX]
    mov rcx, [rbp - LRC_LEFT]
    cmp rax, [rcx + PyListObject.ob_size]
    jge .lrc_ran_out
    mov rcx, [rbp - LRC_RIGHT]
    cmp rax, [rcx + PyListObject.ob_size]
    jge .lrc_ran_out

    ; Elements differ and both are still there: == is False, != is True, and
    ; an ordering op is decided by this element.
    mov rdx, [rbp - LRC_OP]
    cmp edx, PY_EQ
    je .lrc_return_false
    cmp edx, PY_NE
    je .lrc_return_true

    mov rcx, [rbp - LRC_LEFT]
    mov rcx, [rcx + PyListObject.ob_item]
    mov rdi, [rcx + rax * 8]
    mov rcx, [rbp - LRC_RIGHT]
    mov rcx, [rcx + PyListObject.ob_item]
    mov rsi, [rcx + rax * 8]
    mov edx, [rbp - LRC_OP]
    call obj_richcompare_bool
    cmp eax, -1
    je .lrc_error
    RET_BOOL_RAX
    leave
    ret

.lrc_ran_out:
    ; No element decided it: compare the current lengths.
    mov rcx, [rbp - LRC_LEFT]
    mov rcx, [rcx + PyListObject.ob_size]
    mov r8, [rbp - LRC_RIGHT]
    mov r8, [r8 + PyListObject.ob_size]
    mov rdx, [rbp - LRC_OP]

    cmp edx, PY_EQ
    je .lrc_len_eq
    cmp edx, PY_NE
    je .lrc_len_ne
    cmp edx, PY_LT
    je .lrc_len_lt
    cmp edx, PY_LE
    je .lrc_len_le
    cmp edx, PY_GT
    je .lrc_len_gt
    cmp rcx, r8                 ; PY_GE
    jge .lrc_return_true
    jmp .lrc_return_false

.lrc_len_eq:
    cmp rcx, r8
    je .lrc_return_true
    jmp .lrc_return_false
.lrc_len_ne:
    cmp rcx, r8
    jne .lrc_return_true
    jmp .lrc_return_false
.lrc_len_lt:
    cmp rcx, r8
    jl .lrc_return_true
    jmp .lrc_return_false
.lrc_len_le:
    cmp rcx, r8
    jle .lrc_return_true
    jmp .lrc_return_false
.lrc_len_gt:
    cmp rcx, r8
    jg .lrc_return_true
    jmp .lrc_return_false

.lrc_return_true:
    mov eax, 1
    RET_BOOL_RAX
    leave
    ret

.lrc_return_false:
    xor eax, eax
    RET_BOOL_RAX
    leave
    ret

.lrc_not_impl:
    RET_NULL
    leave
    ret

.lrc_error:
    leave
    jmp eval_exception_unwind
END_FUNC list_richcompare_inner

section .data

; List mapping methods
align 8
list_mapping_methods:
    dq list_len             ; mp_length
    dq list_subscript       ; mp_subscript
    dq list_ass_subscript   ; mp_ass_subscript

; List type object
align 8
global list_type
list_type:
    dq 1                    ; ob_refcnt (immortal)
    dq type_type            ; ob_type
    dq list_name_str        ; tp_name
    dq PyListObject_size    ; tp_basicsize
    dq list_dealloc         ; tp_dealloc
    dq list_repr            ; tp_repr
    dq list_repr            ; tp_str
    extern hash_not_implemented
    dq hash_not_implemented ; tp_hash (raises TypeError)
    dq 0                ; tp_call  (instances are not callable)
    dq 0                    ; tp_getattr
    dq 0                    ; tp_setattr
    dq list_richcompare     ; tp_richcompare
    dq 0                    ; tp_iter (set by iter_obj.asm)
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq list_type_call       ; tp_new  (constructor)
    dq list_number_methods  ; tp_as_number
    dq list_sequence_methods ; tp_as_sequence
    dq list_mapping_methods ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq TYPE_FLAG_HAVE_GC | TYPE_FLAG_LIST_SUBCLASS ; tp_flags
    dq 0                    ; tp_bases
    dq list_traverse                        ; tp_traverse
    dq list_clear                        ; tp_clear
    dq 0       ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

section .text

;; ============================================================================
;; GC traverse and clear.  These lived in gc.asm, which left the collector
;; holding the reference graph of every type in the system; a type's own
;; file is the only place that knows which of its fields are owned.
;; ============================================================================

;; ============================================================================
;; TRAVERSE AND CLEAR FUNCTIONS
;; ============================================================================
; Convention: tp_traverse(rdi=obj, r14=visit_callback)
;             tp_clear(rdi=obj)
; The VISIT_* macros use r14 as the callback.

;; ============================================================================
;; ---- list_traverse / list_clear ----
;; ============================================================================
DEF_FUNC list_traverse
    push rbx
    push r12
    push r13
    push r15

    mov rbx, rdi                       ; obj
    mov r12, [rbx + PyListObject.ob_item]       ; payloads
    mov r13, [rbx + PyListObject.ob_size]
    test r13, r13
    jz .done

.loop:
    dec r13
    mov rdi, [r12]
    VISIT_V rdi, rsi
    add r12, 8
    test r13, r13
    jnz .loop
.done:
    pop r15
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_traverse

DEF_FUNC list_clear
    push rbx
    push r12
    push r13
    push r15

    mov rbx, rdi
    mov r12, [rbx + PyListObject.ob_item]       ; payloads
    mov r13, [rbx + PyListObject.ob_size]
    mov qword [rbx + PyListObject.ob_size], 0

    test r13, r13
    jz .done
.loop:
    dec r13
    mov rdi, [r12]
    push r12
    push r12
    DECREF_V rdi, rsi
    pop r12
    pop r12
    add r12, 8
    test r13, r13
    jnz .loop
.done:
    pop r15
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_clear

section .rodata
las_msg_size: db "attempt to assign sequence of size ", 0
las_msg_to:   db " to extended slice of size ", 0
