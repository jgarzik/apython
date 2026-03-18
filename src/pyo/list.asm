; list_obj.asm - List type implementation
; Phase 9: dynamic array with amortized O(1) append

%include "macros.inc"
%include "object.inc"
%include "types.inc"

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
extern str_from_cstr
extern str_new
extern obj_repr
extern fatal_error
extern raise_exception
extern exc_IndexError_type
extern int_to_i64
extern bool_true
extern bool_false
extern obj_incref
extern slice_type
extern slice_indices
extern type_type
extern list_traverse
extern list_clear
extern int_type
extern str_type
extern float_type
extern bool_type
extern none_type
extern float_compare
extern obj_is_true
extern list_sorting_error

;; ============================================================================
;; list_new(int64_t capacity) -> PyListObject*
;; Allocate a new empty list with given initial capacity
;; ============================================================================
LIST_POOL_MAX equ 16

DEF_FUNC list_new
    push rbx
    push r12

    mov r12, rdi               ; r12 = capacity
    test r12, r12
    jnz .has_cap
    mov r12, 4                 ; minimum capacity
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

    ; Allocate payload array: capacity * 8 (Value64 payloads)
    mov rdi, r12
    shl rdi, 3
    call ap_malloc
    mov [rbx + PyListObject.ob_item], rax

    ; Allocate tag array: capacity * 1 (u8 tags), zeroed
    mov rdi, r12
    call ap_malloc
    mov [rbx + PyListObject.ob_item_tags], rax
    ; Zero tag array (prevents stale tags during slice ops)
    mov rdi, rax
    xor eax, eax
    mov ecx, r12d
    rep stosb

    mov rdi, rbx
    call gc_track

    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_new

;; ============================================================================
;; list_copy(PyListObject *src) -> PyListObject* (shallow copy)
;; Creates a new list with same items, INCREFs each.
;; ============================================================================
global list_copy
DEF_FUNC list_copy
    push rbx
    push r12
    push r13

    mov rbx, rdi               ; src list
    mov r12, [rbx + PyListObject.ob_size]

    ; Allocate new list
    mov rdi, r12
    test rdi, rdi
    jnz .lc_alloc
    mov rdi, 4
.lc_alloc:
    call list_new
    mov r13, rax               ; new list
    mov [r13 + PyListObject.ob_size], r12

    ; Bulk copy payloads
    mov rdi, [r13 + PyListObject.ob_item]
    mov rsi, [rbx + PyListObject.ob_item]
    mov rdx, r12
    shl rdx, 3
    call ap_memcpy

    ; Bulk copy tags
    mov rdi, [r13 + PyListObject.ob_item_tags]
    mov rsi, [rbx + PyListObject.ob_item_tags]
    mov rdx, r12
    call ap_memcpy

    ; INCREF each item
    xor ecx, ecx
.lc_incref:
    cmp rcx, r12
    jge .lc_done
    mov rax, [r13 + PyListObject.ob_item]
    mov rdx, [r13 + PyListObject.ob_item_tags]
    mov rdi, [rax + rcx * 8]
    movzx esi, byte [rdx + rcx]
    push rcx
    INCREF_VAL rdi, rsi
    pop rcx
    inc rcx
    jmp .lc_incref

.lc_done:
    mov rax, r13
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_copy

;; ============================================================================
;; list_append(PyListObject *list, PyObject *item, int item_tag)
;; Append item, grow if needed. INCREF item. rdx = item_tag.
;; ============================================================================
DEF_FUNC list_append
    push rbx
    push r12
    push r13

    mov rbx, rdi               ; list
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, rsi               ; item payload
    mov r13, rdx               ; item tag

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

    ; Realloc tag array
    mov rdi, [rbx + PyListObject.ob_item_tags]
    mov rsi, [rbx + PyListObject.allocated]
    call ap_realloc
    mov [rbx + PyListObject.ob_item_tags], rax

.no_grow:
    ; Append item (payload + tag)
    mov rax, [rbx + PyListObject.ob_size]
    mov rcx, [rbx + PyListObject.ob_item]
    mov rdx, [rbx + PyListObject.ob_item_tags]
    mov [rcx + rax * 8], r12       ; payload
    mov byte [rdx + rax], r13b     ; tag

    ; INCREF item (tag-aware)
    INCREF_VAL r12, r13

    ; Increment size
    inc qword [rbx + PyListObject.ob_size]

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_append

;; ============================================================================
;; list_getitem(PyListObject *list, int64_t index) -> PyObject*
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
    cmp rsi, 0
    jl .index_error

    ; Return item with INCREF (payload + tag)
    mov rax, [rdi + PyListObject.ob_item]
    mov rcx, [rdi + PyListObject.ob_item_tags]
    mov rax, [rax + rsi * 8]      ; payload
    movzx edx, byte [rcx + rsi]   ; tag
    INCREF_VAL rax, rdx

    leave
    ret

.index_error:
    lea rdi, [rel exc_IndexError_type]
    CSTRING rsi, "list index out of range"
    call raise_exception
END_FUNC list_getitem

;; ============================================================================
;; list_setitem(PyListObject *list, int64_t index, PyObject *value, int value_tag)
;; sq_ass_item: set item at index, DECREF old, INCREF new. rcx = value_tag.
;; ============================================================================
DEF_FUNC list_setitem
    push rbx
    push r12
    push r13

    mov rbx, rdi               ; list
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, rdx               ; new value payload
    mov r13, rcx               ; new value tag

    ; Handle negative index
    test rsi, rsi
    jns .positive
    add rsi, [rbx + PyListObject.ob_size]
.positive:

    ; Bounds check
    cmp rsi, [rbx + PyListObject.ob_size]
    jge .index_error
    cmp rsi, 0
    jl .index_error

    ; DECREF old value
    mov rax, [rbx + PyListObject.ob_item]
    mov rdx, [rbx + PyListObject.ob_item_tags]
    mov rdi, [rax + rsi * 8]      ; old value payload
    movzx ecx, byte [rdx + rsi]   ; old value tag
    push rax
    push rdx
    push rsi
    DECREF_VAL rdi, rcx
    pop rsi
    pop rdx
    pop rax

    ; Store new value and INCREF
    mov [rax + rsi * 8], r12      ; payload
    mov byte [rdx + rsi], r13b    ; tag
    INCREF_VAL r12, r13

    pop r13
    pop r12
    pop rbx
    leave
    ret

.index_error:
    lea rdi, [rel exc_IndexError_type]
    CSTRING rsi, "list assignment index out of range"
    call raise_exception
END_FUNC list_setitem

;; ============================================================================
;; list_subscript(PyListObject *list, PyObject *key) -> PyObject*
;; mp_subscript: index with int or slice key (for BINARY_SUBSCR)
;; ============================================================================
DEF_FUNC list_subscript
    push rbx

    mov rbx, rdi               ; save list
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error

    ; Check if key is a SmallInt (rdx = key tag from caller)
    cmp edx, TAG_SMALLINT
    je .ls_smallint
    ; Check if key is a slice
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel slice_type]
    cmp rax, rcx
    je .ls_slice

    ; Check if it's actually an int type before converting
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    jne .ls_type_error
    ; Heap int -> convert to i64
    mov rdi, rsi
    call int_to_i64
    mov rsi, rax
    jmp .ls_do_getitem

.ls_smallint:
    ; SmallInt: payload IS the int64 index
    mov rsi, rsi               ; nop — rsi already = payload

.ls_do_getitem:

    ; Call list_getitem
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
    ret

.ls_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "list indices must be integers or slices"
    call raise_exception
END_FUNC list_subscript

;; ============================================================================
;; list_ass_subscript(PyListObject *list, PyObject *key, PyObject *value,
;;                    int key_tag, int value_tag)
;; mp_ass_subscript: set with int or slice key
;; rdi=list, rsi=key, rdx=value, ecx=key_tag, r8d=value_tag
;; ============================================================================
LAS_VTAG  equ 8
LAS_TEMP  equ 16       ; temp list from generic iterable (NULL if not used)
LAS_FRAME equ 16
DEF_FUNC list_ass_subscript, LAS_FRAME
    push rbx
    push r12

    mov rbx, rdi               ; list
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, rdx               ; value
    mov [rbp - LAS_VTAG], r8   ; save value tag

    ; Check if key is a SmallInt (ecx = key tag from caller)
    cmp ecx, TAG_SMALLINT
    je .las_int                ; SmallInt -> int path
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel slice_type]
    cmp rax, rcx
    je .las_slice
    ; Validate key is a heap int before converting
    extern int_type
    lea rcx, [rel int_type]
    cmp rax, rcx
    jne .las_key_type_error

.las_int:
    ; Convert key to i64
    mov rdi, rsi
    mov edx, ecx              ; key tag for int_to_i64
    call int_to_i64
    mov rsi, rax

    ; Check if this is a delete (value_tag == TAG_NULL)
    cmp qword [rbp - LAS_VTAG], TAG_NULL
    je .las_int_delete

    ; Call list_setitem
    mov rdi, rbx
    mov rdx, r12
    mov rcx, [rbp - LAS_VTAG]  ; value tag from caller
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
    cmp rsi, 0
    jl .lid_index_error

    push rsi                   ; save index

    ; DECREF old value at index
    mov rax, [rbx + PyListObject.ob_item]
    mov rdx, [rbx + PyListObject.ob_item_tags]
    mov rdi, [rax + rsi * 8]      ; old value payload
    movzx ecx, byte [rdx + rsi]   ; old value tag
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

    ; Shift tag array
    mov rax, [rbx + PyListObject.ob_item_tags]
    lea rdi, [rax + rsi]          ; dst
    lea r9, [rdi + 1]             ; src = dst + 1
    push rcx
    mov rsi, r9               ; src
    mov rcx, r8               ; count bytes (1 byte per tag)
    cld
    rep movsb
    pop rcx

    ; Decrement ob_size
    mov [rbx + PyListObject.ob_size], rcx

    pop r12
    pop rbx
    leave
    ret

.lid_index_error:
    lea rdi, [rel exc_IndexError_type]
    CSTRING rsi, "list assignment index out of range"
    call raise_exception

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
    mov rsi, [rbx + PyListObject.ob_size]
    call slice_indices
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
    mov r10, [r12 + PyListObject.ob_item_tags] ; r10 = new tag ptr
    jmp .las_have_items

.las_try_tuple:
    extern tuple_type
    lea rdx, [rel tuple_type]
    cmp rax, rdx
    jne .las_try_generic

    ; Value is a tuple
    mov r8, [r12 + PyTupleObject.ob_size]
    mov r9, [r12 + PyTupleObject.ob_item]       ; payload ptr
    mov r10, [r12 + PyTupleObject.ob_item_tags] ; tag ptr
    jmp .las_have_items

.las_try_generic:
    ; Generic iterable: iterate into a temp list, then use it
    mov rax, [r12 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz .las_type_error
    mov rdi, r12
    ; Save rcx (old_len) since it may be clobbered
    push rcx
    call rax                    ; tp_iter(iterable) → iterator
    test rax, rax
    jz .las_type_error_pop
    push rax                    ; save iterator

    ; Create temp list
    xor edi, edi
    call list_new
    push rax                    ; save temp list [rsp]=templist, [rsp+8]=iter, [rsp+16]=old_len

.las_gen_loop:
    mov rdi, [rsp + 8]         ; iterator
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .las_gen_done
    mov rdi, [rsp + 8]
    call rax
    test edx, edx
    jz .las_gen_done
    push rax
    push rdx
    mov rdi, [rsp + 16]       ; temp list (2 pushes deeper)
    mov rsi, rax
    call list_append
    pop rsi
    pop rdi
    DECREF_VAL rdi, rsi
    jmp .las_gen_loop

.las_gen_done:
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
    mov r10, [r12 + PyListObject.ob_item_tags] ; tag ptr
    mov [rbp - LAS_TEMP], r12      ; save for DECREF after copy
    jmp .las_have_items

.las_delete_slice:
    ; Deletion: new_len = 0, no new items to copy
    xor r8d, r8d               ; r8 = 0 (new_len)
    xor r9d, r9d               ; r9 = 0 (new payload ptr, unused)
    xor r10d, r10d             ; r10 = 0 (new tag ptr, unused)
    jmp .las_have_items

.las_type_error_pop:
    pop rcx                     ; discard saved old_len

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
    mov rax, [rbx + PyListObject.ob_item]
    mov rdx, [rbx + PyListObject.ob_item_tags]
    mov rdi, [rax + rcx * 8]      ; payload
    movzx esi, byte [rdx + rcx]   ; tag
    XDECREF_VAL rdi, rsi
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
    mov rdi, [rbx + PyListObject.ob_item_tags]
    mov rsi, [rbx + PyListObject.allocated]
    call ap_realloc
    mov [rbx + PyListObject.ob_item_tags], rax

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
    shl rax, 3
    add rdi, rax
    ; src = payloads + stop * 8
    mov rsi, [rbx + PyListObject.ob_item]
    mov rax, r14
    shl rax, 3
    add rsi, rax
    push rcx
    shl rcx, 3                ; bytes = tail_count * 8
    mov rdx, rcx
    call ap_memmove
    pop rcx

    ; Shift tags
    mov rdi, [rbx + PyListObject.ob_item_tags]
    ; dst = tags + (start + new_len)
    mov rax, r13
    add rax, r8
    add rdi, rax
    ; src = tags + stop
    mov rsi, [rbx + PyListObject.ob_item_tags]
    mov rax, r14
    add rsi, rax
    mov rdx, rcx              ; bytes = tail_count
    call ap_memmove

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
    shl rax, 3
    add rdi, rax              ; dst = ob_item + start*8
    mov rsi, r9               ; src = new payloads ptr
    mov rdx, r8
    shl rdx, 3
    call ap_memcpy
    ; Bulk memcpy tags: dst = list.ob_item_tags + start, src = r10, len = new_len
    mov r10, [rsp]            ; restore new_tag_ptr (don't pop yet)
    mov r8, [rsp + 16]       ; restore new_len
    mov rdi, [rbx + PyListObject.ob_item_tags]
    add rdi, r13              ; dst = ob_item_tags + start
    mov rsi, r10              ; src = new tags ptr
    mov rdx, r8               ; len = new_len
    call ap_memcpy
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
    movzx eax, byte [r10 + rcx]
    INCREF_VAL rdi, rax
    inc rcx
    jmp .las_incref_loop

.las_insert_done:
    ; DECREF temp list if generic iterable path created one
    mov rdi, [rbp - LAS_TEMP]
    test rdi, rdi
    jz .las_no_temp
    call obj_decref
.las_no_temp:
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
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "slice step cannot be zero"
    call raise_exception

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
    jmp .las_type_error

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
    mov r11, [r12 + PyListObject.ob_item_tags]
    mov r12, [r12 + PyListObject.ob_item]
    jmp .ext_check_len

.ext_from_tuple:
    mov r8, [r12 + PyTupleObject.ob_size]
    mov r11, [r12 + PyTupleObject.ob_item_tags]
    mov r12, [r12 + PyTupleObject.ob_item]

.ext_check_len:
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
    mov rdx, [rbx + PyListObject.ob_item_tags]
    mov rdi, [rax + r13 * 8]      ; old payload
    movzx esi, byte [rdx + r13]   ; old tag
    push r11                       ; save source tag ptr (caller-saved)
    sub rsp, 8                     ; alignment
    XDECREF_VAL rdi, rsi      ; may call obj_dealloc, clobbers caller-saved
    add rsp, 8
    pop r11

    ; INCREF new value from source
    mov rdi, [r12]            ; new payload
    movzx esi, byte [r11]     ; new tag
    INCREF_VAL rdi, rsi       ; inline inc, no call

    ; Store at list[r13]
    mov rax, [rbx + PyListObject.ob_item]
    mov rdx, [rbx + PyListObject.ob_item_tags]
    mov [rax + r13 * 8], rdi      ; payload
    mov byte [rdx + r13], sil     ; tag

    ; Advance
    add r13, r15               ; next list index (start + i*step)
    add r12, 8                 ; next source payload
    inc r11                    ; next source tag
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
    mov rdx, [rbx + PyListObject.ob_item_tags]
    mov rdi, [rax + rcx * 8]      ; payload
    movzx esi, byte [rdx + rcx]   ; tag
    XDECREF_VAL rdi, rsi
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
    mov r12, [rbx + PyListObject.ob_item_tags]  ; tags
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
    movzx ecx, byte [r12 + rsi]
    mov byte [r12 + r9], cl
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
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "attempt to assign sequence of wrong size to extended slice"
    call raise_exception

.las_key_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "list indices must be integers or slices"
    call raise_exception

.las_type_error:
    extern exc_TypeError_type
    add rsp, 8
    pop r15
    pop r14
    pop r13
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "can only assign an iterable"
    call raise_exception
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
LC_VPAY    equ 16    ; value payload
LC_VTAG    equ 24    ; value tag
LC_IDX     equ 32
LC_SIZE    equ 40
LC_FRAME   equ 40
DEF_FUNC list_contains, LC_FRAME
    push rbx
    push r12

    mov [rbp - LC_LIST], rdi   ; list
    mov [rbp - LC_VPAY], rsi   ; value payload
    mov [rbp - LC_VTAG], rdx   ; value tag
    mov rax, [rdi + PyListObject.ob_size]
    mov [rbp - LC_SIZE], rax
    mov qword [rbp - LC_IDX], 0

.loop:
    mov rax, [rbp - LC_IDX]
    cmp rax, [rbp - LC_SIZE]
    jge .not_found

    ; Load element payload+tag
    mov rbx, [rbp - LC_LIST]
    mov rbx, [rbx + PyListObject.ob_item]
    mov rdx, [rbp - LC_LIST]
    mov rdx, [rdx + PyListObject.ob_item_tags]
    mov rcx, rax
    mov rdi, [rbx + rcx * 8]        ; elem payload
    movzx r8d, byte [rdx + rcx]     ; elem tag

    ; Fast identity check: both payload and tag match → found
    cmp rdi, [rbp - LC_VPAY]
    jne .try_eq
    cmp r8, [rbp - LC_VTAG]
    je .found

.try_eq:
    ; Use tp_richcompare for __eq__ protocol
    ; Resolve element type from tag
    mov r12, r8                 ; save elem tag
    cmp r8d, TAG_SMALLINT
    je .elem_int_type
    cmp r8d, TAG_FLOAT
    je .elem_float_type
    cmp r8d, TAG_BOOL
    je .elem_bool_type
    cmp r8d, TAG_NONE
    je .next                    ; None: identity-only
    test r8d, TAG_RC_BIT
    jz .next                    ; non-pointer non-known tag: skip
    mov rax, [rdi + PyObject.ob_type]
    jmp .elem_have_type
.elem_int_type:
    lea rax, [rel int_type]
    jmp .elem_have_type
.elem_float_type:
    lea rax, [rel float_type]
    jmp .elem_have_type
.elem_bool_type:
    lea rax, [rel bool_type]
.elem_have_type:
    mov rbx, rax                ; save type ptr
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jnz .elem_do_richcmp

    ; No tp_richcompare — try dunder on heaptype
    mov rdx, [rbx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .next

    ; dunder_call_2(self=elem, other=value, "__eq__", other_tag)
    extern dunder_call_2
    ; rdi = elem payload (already set)
    mov rsi, [rbp - LC_VPAY]   ; other = value
    CSTRING rdx, "__eq__"
    mov ecx, [rbp - LC_VTAG]   ; other_tag = value tag
    call dunder_call_2
    ; if NULL, skip
    test edx, edx
    jz .next
    jmp .elem_check_result

.elem_do_richcmp:
    ; tp_richcompare(elem, value, PY_EQ, elem_tag, value_tag)
    ; rdi = elem payload (already set)
    mov rsi, [rbp - LC_VPAY]
    mov edx, PY_EQ
    mov rcx, r12                ; elem tag
    mov r8, [rbp - LC_VTAG]     ; value tag
    call rax
    ; Check for NotImplemented (NULL return = tag 0)
    test edx, edx
    jnz .elem_check_result
    ; Element's __eq__ returned NotImplemented — try reflected (value.__eq__(elem))
    jmp .try_reflected

.try_reflected:
    ; Try the VALUE's __eq__ (reflected comparison: value.__eq__(elem))
    mov rdi, [rbp - LC_VPAY]      ; value payload
    mov r8d, [rbp - LC_VTAG]      ; value tag
    ; Resolve value type
    cmp r8d, TAG_PTR
    jne .try_reflected_nonptr
    mov rax, [rdi + PyObject.ob_type]
    jmp .try_reflected_have_type
.try_reflected_nonptr:
    cmp r8d, TAG_SMALLINT
    jne .next
    lea rax, [rel int_type]
.try_reflected_have_type:
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jnz .try_reflected_richcmp
    ; No tp_richcompare — try dunder on heaptype
    mov rax, [rdi + PyObject.ob_type]
    mov rdx, [rax + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .next
    ; Reload elem payload + tag for the reflected call
    mov rax, [rbp - LC_IDX]
    mov rbx, [rbp - LC_LIST]
    mov rbx, [rbx + PyListObject.ob_item]
    mov rdx, [rbp - LC_LIST]
    mov rdx, [rdx + PyListObject.ob_item_tags]
    mov rsi, [rbx + rax * 8]        ; elem payload
    movzx ecx, byte [rdx + rax]     ; elem tag
    ; dunder_call_2(self=value, other=elem, "__eq__", other_tag=elem_tag)
    ; rdi = value (already set)
    CSTRING rdx, "__eq__"
    call dunder_call_2
    test edx, edx
    jz .next
    jmp .elem_check_result
.try_reflected_richcmp:
    ; Reload elem for reflected call
    push rax                         ; save richcompare func
    mov rcx, [rbp - LC_IDX]
    mov rbx, [rbp - LC_LIST]
    mov rbx, [rbx + PyListObject.ob_item]
    mov rdx, [rbp - LC_LIST]
    mov rdx, [rdx + PyListObject.ob_item_tags]
    mov rsi, [rbx + rcx * 8]        ; elem payload
    movzx r12d, byte [rdx + rcx]    ; elem tag
    pop rax
    ; tp_richcompare(value, elem, PY_EQ, value_tag, elem_tag)
    ; rdi = value (already set)
    mov edx, PY_EQ
    mov rcx, [rbp - LC_VTAG]        ; self_tag = value_tag
    mov r8, r12                      ; other_tag = elem_tag
    call rax
    test edx, edx
    jz .next

.elem_check_result:

    ; Check result truthiness
    push rax
    push rdx
    mov rdi, rax
    mov rsi, rdx
    call obj_is_true
    mov ebx, eax               ; save truthiness
    pop rdx
    pop rdi                    ; result payload
    push rbx                   ; save truthiness
    mov rsi, rdx
    DECREF_VAL rdi, rsi
    pop rbx                    ; restore truthiness
    test ebx, ebx
    jnz .found

.next:
    inc qword [rbp - LC_IDX]
    jmp .loop

.found:
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret

.not_found:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_contains

;; ============================================================================
;; list_dealloc(PyObject *self)
;; DECREF all items, free items array, free or pool list header
;; ============================================================================
DEF_FUNC list_dealloc
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
    mov rcx, [rbx + PyListObject.ob_item_tags]
    mov rdi, [rax + r13 * 8]      ; payload
    movzx esi, byte [rcx + r13]   ; tag
    XDECREF_VAL rdi, rsi
    inc r13
    jmp .dealloc_loop

.free_items:
    mov rdi, [rbx + PyListObject.ob_item]
    call ap_free
    mov rdi, [rbx + PyListObject.ob_item_tags]
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
    mov rsi, [rbx + PyListObject.ob_size]  ; length
    call slice_indices
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
    push rax                   ; save slicelength [rbp-56]
    mov rdi, rax
    test rdi, rdi
    jnz .lgs_alloc
    mov rdi, 4                 ; min capacity
.lgs_alloc:
    call list_new
    push rax                   ; save new list [rbp-64]

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
    shl rcx, 3
    add rsi, rcx              ; src payloads + (stop+1)*8
    mov rdi, [rsp]            ; new list
    mov rdi, [rdi + PyListObject.ob_item]  ; dst payloads
    push rax                   ; save source start index
    mov rdx, [rsp + 16]       ; slicelength (rsp+8=saved_idx, rsp+16=slicelength)
    shl rdx, 3
    call ap_memcpy

    ; Copy tags
    pop rax                    ; restore source start index
    mov rsi, [rbx + PyListObject.ob_item_tags]
    add rsi, rax              ; src tags + (stop+1)
    mov rdi, [rsp]            ; new list
    mov rdi, [rdi + PyListObject.ob_item_tags] ; dst tags
    mov rdx, [rsp + 8]        ; slicelength (bytes)
    call ap_memcpy

    ; Reverse payloads in place (lo/hi swap loop)
    mov rcx, [rsp + 8]        ; slicelength
    cmp rcx, 2
    jl .lgs_rev_tags           ; 0 or 1 elements, no swap needed
    mov rdi, [rsp]             ; new list
    mov rdi, [rdi + PyListObject.ob_item]  ; payload array
    mov rsi, rcx
    dec rsi
    shl rsi, 3
    add rsi, rdi               ; rsi = &payloads[slicelength-1]
    ; rdi = lo, rsi = hi
.lgs_rev_payload_loop:
    cmp rdi, rsi
    jge .lgs_rev_tags
    mov rax, [rdi]
    mov rdx, [rsi]
    mov [rdi], rdx
    mov [rsi], rax
    add rdi, 8
    sub rsi, 8
    jmp .lgs_rev_payload_loop

.lgs_rev_tags:
    ; Reverse tags in place
    mov rcx, [rsp + 8]        ; slicelength
    cmp rcx, 2
    jl .lgs_rev_done
    mov rdi, [rsp]             ; new list
    mov rdi, [rdi + PyListObject.ob_item_tags] ; tag array
    mov rsi, rcx
    dec rsi
    add rsi, rdi               ; rsi = &tags[slicelength-1]
    ; rdi = lo, rsi = hi
.lgs_rev_tag_loop:
    cmp rdi, rsi
    jge .lgs_rev_done
    mov al, [rdi]
    mov dl, [rsi]
    mov [rdi], dl
    mov [rsi], al
    inc rdi
    dec rsi
    jmp .lgs_rev_tag_loop

.lgs_rev_done:
    ; Bulk INCREF (reuse common path)
    jmp .lgs_incref_start

.lgs_memcpy_fwd:
    ; Copy payloads (contiguous)
    mov rsi, [rbx + PyListObject.ob_item]
    mov rax, r13
    shl rax, 3
    add rsi, rax              ; src payloads
    mov rdi, [rsp]            ; new list
    mov rdi, [rdi + PyListObject.ob_item]  ; dst payloads
    mov rdx, [rsp + 8]        ; slicelength
    shl rdx, 3
    call ap_memcpy

    ; Copy tags
    mov rsi, [rbx + PyListObject.ob_item_tags]
    mov rax, r13
    add rsi, rax              ; src tags
    mov rdi, [rsp]            ; new list
    mov rdi, [rdi + PyListObject.ob_item_tags] ; dst tags
    mov rdx, [rsp + 8]        ; slicelength (bytes)
    call ap_memcpy
    ; Bulk INCREF all copied elements
.lgs_incref_start:
    mov rcx, [rsp + 8]        ; slicelength
    test rcx, rcx
    jz .lgs_done
    mov rdi, [rsp]             ; new list
    mov rdi, [rdi + PyListObject.ob_item]       ; payloads
    mov rsi, [rsp]             ; new list
    mov rsi, [rsi + PyListObject.ob_item_tags]  ; tags
    xor edx, edx
.lgs_incref_loop:
    cmp rdx, rcx
    jge .lgs_done
    mov r8, [rdi + rdx * 8]       ; payload
    movzx r9d, byte [rsi + rdx]   ; tag
    INCREF_VAL r8, r9
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
    mov r11, [rbx + PyListObject.ob_item_tags]
    mov r8, [rdx + rax * 8]       ; item payload
    movzx r9d, byte [r11 + rax]   ; item tag
    INCREF_VAL r8, r9
    ; Store item into new list
    mov rdi, [rsp]             ; new list
    mov rdi, [rdi + PyListObject.ob_item]
    mov rsi, [rsp]             ; new list
    mov rsi, [rsi + PyListObject.ob_item_tags]
    mov [rdi + rcx * 8], r8    ; payload
    mov byte [rsi + rcx], r9b  ; tag
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
;; list_concat(PyListObject *a, PyObject *b) -> PyListObject*
;; Concatenate two lists: [1,2] + [3,4] -> [1,2,3,4]
;; ============================================================================
DEF_FUNC list_concat
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi            ; rbx = list a
    mov r12, rsi            ; r12 = list b

    ; Get sizes
    mov r13, [rbx + PyListObject.ob_size]   ; r13 = len(a)
    mov r14, [r12 + PyListObject.ob_size]   ; r14 = len(b)

    ; Allocate new list with total capacity
    lea rdi, [r13 + r14]
    call list_new
    push rax                ; save new list

    ; Set size
    lea rcx, [r13 + r14]
    mov [rax + PyListObject.ob_size], rcx

    ; Copy items from a
    mov rdi, [rax + PyListObject.ob_item]       ; dest payloads
    mov rdx, [rax + PyListObject.ob_item_tags]  ; dest tags
    mov rsi, [rbx + PyListObject.ob_item]       ; src payloads
    mov r8, [rbx + PyListObject.ob_item_tags]   ; src tags
    xor ecx, ecx
.copy_a:
    cmp rcx, r13
    jge .copy_b_start
    mov r9, [rsi + rcx * 8]       ; payload from source
    movzx r10d, byte [r8 + rcx]   ; tag from source
    mov [rdi + rcx * 8], r9       ; payload to dest
    mov byte [rdx + rcx], r10b    ; tag to dest
    INCREF_VAL r9, r10
    inc rcx
    jmp .copy_a

.copy_b_start:
    ; Copy items from b
    mov rsi, [r12 + PyListObject.ob_item]       ; src payloads
    mov r8, [r12 + PyListObject.ob_item_tags]   ; src tags
    xor ecx, ecx
.copy_b:
    cmp rcx, r14
    jge .concat_done
    mov r9, [rsi + rcx * 8]       ; payload from source b
    movzx r10d, byte [r8 + rcx]   ; tag from source b
    lea r11, [r13 + rcx]          ; dest index
    mov rax, [rsp]                ; new list
    mov rax, [rax + PyListObject.ob_item]
    mov rdi, [rsp]
    mov rdi, [rdi + PyListObject.ob_item_tags]
    mov [rax + r11 * 8], r9       ; payload
    mov byte [rdi + r11], r10b    ; tag
    INCREF_VAL r9, r10
    inc rcx
    jmp .copy_b

.concat_done:
    pop rax                 ; return new list
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_concat

;; ============================================================================
;; list_repeat(PyListObject *list, PyObject *count) -> PyListObject*
;; Repeat a list: [1,2] * 3 -> [1,2,1,2,1,2]
;; ============================================================================
DEF_FUNC list_repeat
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi            ; rbx = list
    mov rdi, rsi            ; count (int payload)
    mov edx, ecx            ; count tag (right operand)
    call int_to_i64
    mov r12, rax             ; r12 = repeat count

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
    ja .rep_overflow

    ; Allocate new list
    mov rdi, r14
    test rdi, rdi
    jnz .rep_has_size
    mov rdi, 1              ; min capacity
.rep_has_size:
    call list_new
    push rax                ; save new list
    mov [rax + PyListObject.ob_size], r14

    ; Copy list r12 times
    mov rdi, [rax + PyListObject.ob_item]       ; dest payloads
    mov r10, [rax + PyListObject.ob_item_tags]  ; dest tags
    xor ecx, ecx            ; ecx = repeat counter
.rep_outer:
    cmp rcx, r12
    jge .rep_done
    push rcx
    ; Copy all items from source list
    mov rsi, [rbx + PyListObject.ob_item]       ; src payloads
    mov r11, [rbx + PyListObject.ob_item_tags]  ; src tags
    xor edx, edx
.rep_inner:
    cmp rdx, r13
    jge .rep_inner_done
    mov r8, [rsi + rdx * 8]       ; payload
    movzx r9d, byte [r11 + rdx]   ; tag
    mov [rdi], r8                 ; payload to dest
    mov byte [r10], r9b           ; tag to dest
    INCREF_VAL r8, r9
    add rdi, 8                    ; advance dest payload
    inc r10                       ; advance dest tag
    inc rdx
    jmp .rep_inner
.rep_inner_done:
    pop rcx
    inc rcx
    jmp .rep_outer

.rep_done:
    pop rax                 ; return new list
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.rep_overflow:
    extern exc_OverflowError_type
    lea rdi, [rel exc_OverflowError_type]
    CSTRING rsi, "too many items for list repetition"
    call raise_exception
END_FUNC list_repeat

;; ============================================================================
;; list_inplace_concat(left, right, left_tag, right_tag) -> (rax, edx)
;; nb_iadd / sq_inplace_concat: extend left list in-place with right iterable
;; Returns (left, TAG_PTR) — same object.
;; ============================================================================
LIC_SELF   equ 8
LIC_ITER   equ 16
LIC_FRAME  equ 16
DEF_FUNC list_inplace_concat, LIC_FRAME
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

.lic_list:
    mov r13, [r12 + PyListObject.ob_size]
    xor ecx, ecx
.lic_list_loop:
    cmp rcx, r13
    jge .lic_done
    push rcx
    mov rax, [r12 + PyListObject.ob_item]
    mov rdx, [r12 + PyListObject.ob_item_tags]
    mov rsi, [rax + rcx * 8]
    movzx edx, byte [rdx + rcx]
    mov rdi, rbx
    call list_append
    pop rcx
    inc rcx
    jmp .lic_list_loop

.lic_tuple:
    mov r13, [r12 + PyTupleObject.ob_size]
    xor ecx, ecx
.lic_tuple_loop:
    cmp rcx, r13
    jge .lic_done
    push rcx
    mov rax, [r12 + PyTupleObject.ob_item]
    mov rdx, [r12 + PyTupleObject.ob_item_tags]
    mov rsi, [rax + rcx * 8]
    movzx edx, byte [rdx + rcx]
    mov rdi, rbx
    call list_append
    pop rcx
    inc rcx
    jmp .lic_tuple_loop

.lic_generic:
    ; Use tp_iter/tp_iternext
    mov rax, [r12 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz .lic_type_error
    mov rdi, r12
    call rax
    test rax, rax
    jz .lic_type_error
    mov [rbp - LIC_ITER], rax

.lic_gen_loop:
    mov rdi, [rbp - LIC_ITER]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .lic_gen_done
    mov rdi, [rbp - LIC_ITER]
    call rax
    test edx, edx
    jz .lic_gen_done

    push rax
    push rdx
    mov rdi, rbx
    mov rsi, rax
    call list_append
    pop rsi
    pop rdi
    DECREF_VAL rdi, rsi
    jmp .lic_gen_loop

.lic_gen_done:
    mov rdi, [rbp - LIC_ITER]
    call obj_decref

.lic_done:
    ; Return (self, TAG_PTR) — INCREF self
    INCREF rbx
    mov rax, rbx
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.lic_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "can only concatenate list (not other) to list"
    call raise_exception
END_FUNC list_inplace_concat

;; ============================================================================
;; list_inplace_repeat(left, right, left_tag, right_tag) -> (rax, edx)
;; nb_imul / sq_inplace_repeat: repeat left list in-place by right integer
;; Returns (left, TAG_PTR) — same object.
;; ============================================================================
LIR_SELF    equ 8
LIR_OLDSIZE equ 16
LIR_FRAME   equ 16
DEF_FUNC list_inplace_repeat, LIR_FRAME
    push rbx
    push r12
    push r13

    mov rbx, rdi              ; self (list)
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, rsi              ; right payload
    mov r13, rcx              ; right_tag

    ; Convert right to i64 count
    mov rdi, r12
    mov edx, r13d             ; int_to_i64 expects tag in edx
    call int_to_i64
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
    jo .lir_overflow           ; signed overflow → OverflowError
    cmp rax, 0x10000000        ; 256M items limit
    ja .lir_overflow
    push rax                  ; save new_size

    ; Realloc payloads
    mov rdi, [rbx + PyListObject.ob_item]
    mov rsi, rax
    shl rsi, 3                ; new_size * 8
    call ap_realloc
    mov [rbx + PyListObject.ob_item], rax
    ; Realloc tags
    mov rdi, [rbx + PyListObject.ob_item_tags]
    mov rsi, [rsp]            ; new_size from stack (not rax which is realloc result)
    call ap_realloc
    mov [rbx + PyListObject.ob_item_tags], rax
    pop rax                   ; new_size
    mov [rbx + PyListObject.ob_size], rax
    mov [rbx + PyListObject.allocated], rax

    ; Copy items (count - 1) more times + INCREF each copy
    mov rax, [rbx + PyListObject.ob_item]       ; payloads
    mov r11, [rbx + PyListObject.ob_item_tags]  ; tags
    mov rcx, 1                ; copy number (1-based)
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
    ; Copy payload + tag
    mov r9, [rax + rcx * 8]       ; src payload
    movzx r10d, byte [r11 + rcx]  ; src tag
    mov [rax + rdx * 8], r9       ; dst payload
    mov byte [r11 + rdx], r10b    ; dst tag

    ; INCREF copied item
    push rax
    push rcx
    push rdx
    INCREF_VAL r9, r10
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
    mov rdx, [rbx + PyListObject.ob_item_tags]
    push rcx
    mov rdi, [rax + rcx * 8]
    movzx esi, byte [rdx + rcx]
    DECREF_VAL rdi, rsi
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
    ret
.lir_overflow:
    extern exc_OverflowError_type
    lea rdi, [rel exc_OverflowError_type]
    CSTRING rsi, "too many items for list repetition"
    call raise_exception
END_FUNC list_inplace_repeat

;; ============================================================================
;; list_type_call(PyTypeObject *type, PyObject **args, int64_t nargs) -> PyListObject*
;; Constructor: list() or list(iterable)
;; ============================================================================
; Frame layout
LTC_LIST    equ 8       ; new list object
LTC_ITER    equ 16      ; iterator object
LTC_FRAME   equ 24

DEF_FUNC list_type_call, LTC_FRAME
    push rbx
    push r12
    push r13

    mov r12, rsi            ; args
    mov r13, rdx            ; nargs

    ; Reject keyword arguments
    extern kw_names_pending
    mov rax, [rel kw_names_pending]
    test rax, rax
    jnz .ltc_kwarg_error

    ; list() — no args: return empty list
    test r13, r13
    jz .ltc_empty

    ; list(iterable) — exactly 1 arg
    cmp r13, 1
    jne .ltc_error

    ; Create empty list, then extend from iterable
    xor edi, edi
    call list_new
    mov [rbp - LTC_LIST], rax
    mov rbx, rax            ; rbx = new list

    ; Get iterator from arg (supports heaptypes with __iter__)
    mov rdi, [r12]          ; iterable payload
    mov esi, [r12 + 8]      ; iterable tag
    extern get_iterator
    call get_iterator
    mov [rbp - LTC_ITER], rax

    ; Iterate and append (call_iternext handles heaptype __next__)
.ltc_loop:
    mov rdi, [rbp - LTC_ITER]
    extern call_iternext
    call call_iternext
    test edx, edx
    jz .ltc_done            ; StopIteration

    ; Append item to list (preserve actual tag from iternext)
    push rax                ; save item payload
    push rdx                ; save item tag
    mov rdi, rbx
    mov rsi, rax
    ; edx = tag from tp_iternext (already set)
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

    ; Check for pending exception from iternext (e.g. zip strict ValueError)
    extern current_exception
    mov rax, [rel current_exception]
    test rax, rax
    jnz .ltc_exc_cleanup

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
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "list() argument must be an iterable"
    call raise_exception

.ltc_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "list expected at most 1 argument"
    call raise_exception

.ltc_kwarg_error:
    ; Clear kw_names_pending to avoid stale state
    mov qword [rel kw_names_pending], 0
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "list() takes no keyword arguments"
    call raise_exception
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
    dq list_concat          ; nb_add (list concatenation)
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
    dq list_inplace_concat      ; nb_iadd         +168
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
LRC_LEFT     equ 8
LRC_RIGHT    equ 16
LRC_OP       equ 24
LRC_IDX      equ 32
LRC_MINLEN   equ 40
LRC_FRAME    equ 40

DEF_FUNC list_richcompare, LRC_FRAME
    ; Verify right is TAG_PTR and a list
    cmp r8d, TAG_PTR
    jne .lrc_not_impl
    mov rax, [rsi + PyObject.ob_type]
    lea r9, [rel list_type]
    cmp rax, r9
    jne .lrc_not_impl

    mov [rbp - LRC_LEFT], rdi
    mov [rbp - LRC_RIGHT], rsi
    mov [rbp - LRC_OP], edx

    ; Get lengths
    mov rcx, [rdi + PyListObject.ob_size]   ; left_len
    mov r8, [rsi + PyListObject.ob_size]    ; right_len

    ; min_len = min(left_len, right_len)
    mov rax, rcx
    cmp rax, r8
    jle .lrc_have_min
    mov rax, r8
.lrc_have_min:
    mov [rbp - LRC_MINLEN], rax

    ; Compare elements 0..min_len-1
    mov qword [rbp - LRC_IDX], 0

.lrc_elem_loop:
    mov rax, [rbp - LRC_IDX]
    cmp rax, [rbp - LRC_MINLEN]
    jge .lrc_elements_equal

    ; Get left[i] and right[i] (payload + tag arrays)
    mov rdi, [rbp - LRC_LEFT]
    mov r10, [rdi + PyListObject.ob_item]       ; left payloads
    mov rdx, [rdi + PyListObject.ob_item_tags]  ; left tags
    mov rdi, [rbp - LRC_RIGHT]
    mov rsi, [rdi + PyListObject.ob_item]       ; right payloads
    mov r9, [rdi + PyListObject.ob_item_tags]   ; right tags
    mov rdi, [r10 + rax * 8]        ; left_payload
    movzx ecx, byte [rdx + rax]     ; left_tag
    mov rsi, [rsi + rax * 8]        ; right_payload
    movzx r8d, byte [r9 + rax]      ; right_tag

    ; Fast path: both same tag and same payload → elements equal, skip
    cmp rcx, r8
    jne .lrc_elem_compare
    cmp rdi, rsi
    je .lrc_elem_next

.lrc_elem_compare:
    ; Compare elements for EQ using element type's tp_richcompare
    ; Save caller state
    push rdi                        ; left_payload
    push rcx                        ; left_tag
    push rsi                        ; right_payload
    push r8                         ; right_tag

    ; Float coercion: if either is TAG_FLOAT, use float_compare
    cmp ecx, TAG_FLOAT
    je .lrc_elem_float
    cmp r8d, TAG_FLOAT
    je .lrc_elem_float

    ; Resolve left type
    cmp ecx, TAG_SMALLINT
    je .lrc_elem_int_type
    cmp ecx, TAG_BOOL
    je .lrc_elem_bool_type
    cmp ecx, TAG_NONE
    je .lrc_elem_none_type
    ; TAG_PTR: get ob_type
    mov rax, [rdi + PyObject.ob_type]
    jmp .lrc_elem_have_type

.lrc_elem_int_type:
    lea rax, [rel int_type]
    jmp .lrc_elem_have_type
.lrc_elem_bool_type:
    lea rax, [rel bool_type]
    jmp .lrc_elem_have_type
.lrc_elem_none_type:
    lea rax, [rel none_type]
    jmp .lrc_elem_have_type
.lrc_elem_have_type:
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jz .lrc_elem_not_equal          ; no richcompare → not equal

    ; Call tp_richcompare(left, right, PY_EQ, left_tag, right_tag)
    pop r8                          ; right_tag
    pop rsi                         ; right_payload
    pop rcx                         ; left_tag
    pop rdi                         ; left_payload
    mov edx, PY_EQ
    call rax
    ; Check for NotImplemented (NULL return = tag 0)
    test edx, edx
    jz .lrc_elem_not_equal_nopop

    ; Check result for truthiness — handle both TAG_BOOL and TAG_PTR(bool_true)
    ; DECREF the result if TAG_PTR, then use obj_is_true
    push rax
    push rdx
    mov rdi, rax
    mov rsi, rdx
    call obj_is_true
    mov ecx, eax                    ; ecx = truthiness (0/1)
    pop rdx                         ; result tag
    pop rdi                         ; result payload
    push rcx                        ; save truthiness
    mov rsi, rdx
    DECREF_VAL rdi, rsi
    pop rcx                         ; restore truthiness
    test ecx, ecx
    jnz .lrc_elem_next              ; equal → continue

    ; Elements not equal: for EQ/NE we know the answer
    ; For ordering ops, need to compare with LT
    jmp .lrc_elem_not_equal_nopop

.lrc_elem_float:
    ; float_compare(left, right, PY_EQ, left_tag, right_tag)
    pop r8
    pop rsi
    pop rcx
    pop rdi
    mov edx, PY_EQ
    call float_compare
    ; Check for NotImplemented (NULL return = tag 0)
    test edx, edx
    jz .lrc_elem_not_equal_nopop
    ; Check result for truthiness
    push rax
    push rdx
    mov rdi, rax
    mov rsi, rdx
    call obj_is_true
    mov ecx, eax
    pop rdx
    pop rdi
    push rcx
    mov rsi, rdx
    DECREF_VAL rdi, rsi
    pop rcx
    test ecx, ecx
    jnz .lrc_elem_next
    test rax, rax
    jnz .lrc_elem_next
    jmp .lrc_elem_not_equal_nopop

.lrc_elem_not_equal:
    add rsp, 32                     ; clean up 4 pushes
.lrc_elem_not_equal_nopop:
    ; Elements at index i differ.
    ; For EQ: return False. For NE: return True.
    ; For ordering: compare these elements with the requested op.
    mov ecx, [rbp - LRC_OP]
    cmp ecx, PY_EQ
    je .lrc_return_false
    cmp ecx, PY_NE
    je .lrc_return_true

    ; Ordering ops: compare the differing elements with the actual op
    mov rax, [rbp - LRC_IDX]

    mov rdi, [rbp - LRC_LEFT]
    mov r10, [rdi + PyListObject.ob_item]
    mov rdx, [rdi + PyListObject.ob_item_tags]
    mov rdi, [rbp - LRC_RIGHT]
    mov rsi, [rdi + PyListObject.ob_item]
    mov r9, [rdi + PyListObject.ob_item_tags]
    mov rdi, [r10 + rax * 8]        ; left_payload
    movzx ecx, byte [rdx + rax]     ; left_tag
    mov rsi, [rsi + rax * 8]        ; right_payload
    movzx r8d, byte [r9 + rax]      ; right_tag

    ; Resolve left type (again)
    push rcx
    push r8
    ; Float coercion: if either operand is TAG_FLOAT, use float_compare
    cmp ecx, TAG_FLOAT
    je .lrc_order_float
    cmp r8d, TAG_FLOAT
    je .lrc_order_float
    cmp ecx, TAG_SMALLINT
    je .lrc_order_int_type
    cmp ecx, TAG_BOOL
    je .lrc_order_bool_type
    cmp ecx, TAG_NONE
    je .lrc_order_none_type
    test rcx, rcx
    js .lrc_order_str_type
    mov rax, [rdi + PyObject.ob_type]
    jmp .lrc_order_have_type
.lrc_order_int_type:
    lea rax, [rel int_type]
    jmp .lrc_order_have_type
.lrc_order_bool_type:
    lea rax, [rel bool_type]
    jmp .lrc_order_have_type
.lrc_order_none_type:
    lea rax, [rel none_type]
    jmp .lrc_order_have_type
.lrc_order_str_type:
    lea rax, [rel str_type]
.lrc_order_have_type:
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jz .lrc_order_fallback
    pop r8
    pop rcx
    mov edx, [rbp - LRC_OP]
    call rax
    ; Return the result directly
    leave
    ret
.lrc_order_float:
    pop r8
    pop rcx
    mov edx, [rbp - LRC_OP]
    call float_compare
    leave
    ret
.lrc_order_fallback:
    add rsp, 16                     ; clean up 2 pushes
    jmp .lrc_return_false

.lrc_elem_next:
    inc qword [rbp - LRC_IDX]
    jmp .lrc_elem_loop

.lrc_elements_equal:
    ; All min_len elements are equal.
    ; Result depends on lengths and comparison op.
    mov rcx, [rbp - LRC_LEFT]
    mov rcx, [rcx + PyListObject.ob_size]    ; left_len
    mov r8, [rbp - LRC_RIGHT]
    mov r8, [r8 + PyListObject.ob_size]      ; right_len
    mov edx, [rbp - LRC_OP]

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
    ; PY_GE
    cmp rcx, r8
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
    mov edx, TAG_BOOL
    leave
    ret

.lrc_return_false:
    xor eax, eax
    mov edx, TAG_BOOL
    leave
    ret

.lrc_not_impl:
    ; Return NotImplemented (NULL) so COMPARE_OP can try right operand
    RET_NULL
    leave
    ret

END_FUNC list_richcompare

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
    dq list_type_call       ; tp_call
    dq 0                    ; tp_getattr
    dq 0                    ; tp_setattr
    dq list_richcompare     ; tp_richcompare
    dq 0                    ; tp_iter (set by iter_obj.asm)
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq 0                    ; tp_new
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
