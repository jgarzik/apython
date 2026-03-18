; dict_obj.asm - Dict type implementation
; Phase 4: open-addressing hash table with linear probing

%include "macros.inc"
%include "object.inc"
%include "types.inc"

extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern ap_free
extern obj_hash
extern obj_decref
extern obj_dealloc
extern str_type
extern ap_strcmp
extern ap_memset
extern fatal_error
extern raise_exception
extern exc_KeyError_type
extern obj_incref
extern str_from_cstr
extern type_type
extern tuple_type
extern dict_traverse
extern dict_clear_gc

; Initial capacity (must be power of 2)
DICT_INIT_CAP equ 8

; Tombstone marker for deleted dict entries.
; When an entry is deleted, key_tag is set to this value so that
; linear probing continues past it (instead of stopping as at empty slots).
; Must never match a valid tag value.

;; ============================================================================
;; dict_new() -> PyDictObject*
;; Allocate a new empty dict with initial capacity 8
;; ============================================================================
DEF_FUNC dict_new
    push rbx

    ; Allocate PyDictObject header (GC-tracked)
    mov edi, PyDictObject_size
    lea rsi, [rel dict_type]
    call gc_alloc
    mov rbx, rax                ; rbx = dict (ob_refcnt=1, ob_type set)

    mov qword [rbx + PyDictObject.ob_size], 0
    mov qword [rbx + PyDictObject.capacity], DICT_INIT_CAP
    mov qword [rbx + PyDictObject.dk_version], 1
    mov qword [rbx + PyDictObject.dk_tombstones], 0

    ; Allocate entries array: capacity * DICT_ENTRY_SIZE
    mov edi, DICT_INIT_CAP * DICT_ENTRY_SIZE
    call ap_malloc
    mov [rbx + PyDictObject.entries], rax

    ; Zero out entries (NULL key = empty slot)
    mov rdi, rax
    xor esi, esi
    mov edx, DICT_INIT_CAP * DICT_ENTRY_SIZE
    call ap_memset

    mov rdi, rbx
    call gc_track

    mov rax, rbx
    pop rbx
    leave
    ret
END_FUNC dict_new

;; ============================================================================
;; dict_type_call(PyTypeObject *type, PyObject **args, int64_t nargs) -> PyDictObject*
;; Constructor: dict() or dict(mapping)
;; ============================================================================
extern kw_names_pending
extern ap_strcmp

global dict_type_call
DEF_FUNC dict_type_call
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rsi               ; args
    mov r12, rdx               ; nargs

    ; Check for keyword arguments
    mov r14, [rel kw_names_pending]
    mov qword [rel kw_names_pending], 0  ; clear immediately

    ; Determine positional arg count
    xor r13d, r13d             ; r13 = n_pos = nargs
    mov r13, r12
    test r14, r14
    jz .dtc_no_kw
    mov rax, [r14 + PyTupleObject.ob_size]
    sub r13, rax               ; r13 = n_pos = nargs - n_kw

.dtc_no_kw:
    ; dict() with no pos args (may have kwargs)
    test r13, r13
    jz .dtc_no_pos

    ; dict(arg) - one positional arg (may also have kwargs)
    cmp r13, 1
    jne .dtc_error

    ; Check if arg is a dict
    mov rdi, [rbx]             ; args[0] payload
    mov eax, [rbx + 8]        ; args[0] tag
    cmp eax, TAG_PTR
    jne .dtc_try_iterable
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel dict_type]
    cmp rax, rcx
    jne .dtc_try_iterable

    ; dict(other_dict) → create new dict and copy entries
    push rdi                   ; save source dict
    call dict_new
    mov r15, rax               ; r15 = new dict
    pop rdi                    ; rdi = source dict

    ; Copy all entries from source
    mov r8, [rdi + PyDictObject.capacity]
    xor ecx, ecx
.dtc_copy_loop:
    cmp rcx, r8
    jge .dtc_copy_done
    imul rax, rcx, DICT_ENTRY_SIZE
    add rax, [rdi + PyDictObject.entries]
    cmp byte [rax + DictEntry.value_tag], 0
    je .dtc_copy_next
    push rcx
    push r8
    push rdi
    mov rdi, r15               ; new dict
    mov rsi, [rax + DictEntry.key]
    mov rdx, [rax + DictEntry.value]
    movzx ecx, byte [rax + DictEntry.value_tag]
    movzx r8d, byte [rax + DictEntry.key_tag]
    call dict_set
    pop rdi
    pop r8
    pop rcx
.dtc_copy_next:
    inc rcx
    jmp .dtc_copy_loop
.dtc_copy_done:
    ; Fall through to add kwargs if present
    jmp .dtc_add_kwargs

.dtc_try_iterable:
    ; Not a dict — try iterating as sequence of (key, value) pairs
    mov rdi, [rbx]             ; args[0] payload
    movzx esi, byte [rbx + 8] ; args[0] tag
    cmp esi, TAG_PTR
    jne .dtc_error
    ; Get iterator
    push rdi
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz .dtc_error_pop
    call rax
    test rax, rax
    jz .dtc_error_pop
    add rsp, 8                 ; discard saved iterable
    mov r13, rax               ; r13 = iterator

    ; Create new dict
    call dict_new
    mov r15, rax               ; r15 = new dict

    ; Iterate pairs
.dtc_iter_loop:
    mov rdi, r13
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    test edx, edx
    jz .dtc_iter_done          ; exhausted

    ; rax = item, edx = tag — must be a tuple of length 2
    cmp edx, TAG_PTR
    jne .dtc_iter_type_error
    mov rcx, [rax + PyObject.ob_type]
    lea r8, [rel tuple_type]
    cmp rcx, r8
    jne .dtc_iter_type_error
    cmp qword [rax + PyTupleObject.ob_size], 2
    jne .dtc_iter_type_error

    ; Extract key and value from tuple
    push rax                   ; save tuple for DECREF
    mov rcx, [rax + PyTupleObject.ob_item]
    mov r8, [rax + PyTupleObject.ob_item_tags]
    mov rdi, r15               ; dict
    mov rsi, [rcx]             ; key payload
    mov rdx, [rcx + 8]        ; value payload
    movzx eax, byte [r8 + 1]  ; value tag (index 1)
    push rax                   ; save value tag
    movzx r8d, byte [r8]      ; key tag (index 0)
    pop rcx                    ; rcx = value tag
    call dict_set
    pop rdi                    ; tuple
    call obj_decref
    jmp .dtc_iter_loop

.dtc_iter_done:
    ; DECREF iterator
    mov rdi, r13
    call obj_decref
    jmp .dtc_add_kwargs

.dtc_iter_type_error:
    ; DECREF iterator and raise TypeError
    mov rdi, r13
    call obj_decref
    jmp .dtc_error

.dtc_error_pop:
    add rsp, 8
    jmp .dtc_error

.dtc_no_pos:
    ; No positional args — create empty dict (kwargs will be added below)
    call dict_new
    mov r15, rax

.dtc_add_kwargs:
    ; Add keyword arguments if present
    test r14, r14
    jz .dtc_return_dict

    ; r14 = kw_names tuple, rbx = args, r13 was n_pos (now reuse)
    ; kwargs start at args[n_pos] — reload n_pos
    mov rax, r12               ; total nargs
    mov rcx, [r14 + PyTupleObject.ob_size]
    sub rax, rcx               ; rax = n_pos
    mov r13, rcx               ; r13 = n_kw
    mov rcx, rax               ; rcx = n_pos (index into args)

    ; kw_names.ob_item has the key strings, args[n_pos + i] has values
    mov rax, [r14 + PyTupleObject.ob_item]      ; keys payload array
    mov rdx, [r14 + PyTupleObject.ob_item_tags]  ; keys tag array
    xor r8d, r8d              ; kw index
.dtc_kw_loop:
    cmp r8, r13
    jge .dtc_return_dict

    ; Calculate arg position: args[(n_pos + r8)]
    push r8
    push rcx
    push rax
    push rdx

    ; Get key from kw_names
    mov rsi, [rax + r8*8]         ; key payload (string)
    movzx r8d, byte [rdx + r8]   ; key tag

    ; Get value from args
    lea r9, [rcx + r8]            ; wait, need original r8 (kw index)
    ; Recalculate: value is at args[n_pos + kw_index]
    pop rdx
    pop rax
    pop rcx
    pop r8

    push r8
    push rcx
    push rax
    push rdx

    ; key from kw_names tuple items
    mov r9, [r14 + PyTupleObject.ob_item]
    mov rsi, [r9 + r8*8]         ; key payload
    mov r9, [r14 + PyTupleObject.ob_item_tags]
    movzx r10d, byte [r9 + r8]  ; key tag → r10d (save for later)

    ; value from args: index = n_pos + kw_index
    add rcx, r8                   ; rcx = n_pos + kw_index
    shl rcx, 4                    ; rcx * 16 (each arg is 16 bytes)
    mov rdx, [rbx + rcx]         ; value payload
    movzx eax, byte [rbx + rcx + 8]  ; value tag

    ; dict_set(dict, key, value, value_tag, key_tag)
    mov rdi, r15
    mov ecx, eax                  ; value tag
    mov r8d, r10d                 ; key tag
    call dict_set

    pop rdx
    pop rax
    pop rcx
    pop r8
    inc r8
    jmp .dtc_kw_loop

.dtc_return_dict:
    mov rax, r15
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.dtc_error:
    extern exc_TypeError_type
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "dict() argument must be a mapping or iterable"
    call raise_exception
END_FUNC dict_type_call

;; ============================================================================
;; dict_keys_equal(rdi=a_key, rsi=b_key, edx=a_tag, ecx=b_tag) -> int (1=equal, 0=not)
;; Internal helper: value equality for SmallInts, string comparison for heap ptrs.
;; ============================================================================
extern float_to_f64
extern int_type
extern bool_type

DEF_FUNC_LOCAL dict_keys_equal
    ; Fast path: both payload AND tag identical → equal
    ; Handles SmallInt==SmallInt, same heap ptr
    cmp rdi, rsi
    jne .dke_diff_payload
    cmp rdx, rcx
    jne .dke_diff_payload
    mov eax, 1
    leave
    ret

.dke_diff_payload:
    ; Check cross-type numeric equality
    ; SmallInt(1) == Float(1.0) == Bool(True) in dict keys
    ; Also handles TAG_PTR for heap int/bool objects
    cmp edx, TAG_SMALLINT
    je .dke_a_numeric
    cmp edx, TAG_FLOAT
    je .dke_a_numeric
    cmp edx, TAG_BOOL
    je .dke_a_numeric
    cmp edx, TAG_PTR
    jne .dke_not_numeric
    ; TAG_PTR: check if int_type or bool_type
    mov rax, [rdi + PyObject.ob_type]
    lea r8, [rel int_type]
    cmp rax, r8
    je .dke_a_numeric
    lea r8, [rel bool_type]
    cmp rax, r8
    je .dke_a_numeric
    jmp .dke_not_numeric
.dke_a_numeric:
    cmp ecx, TAG_SMALLINT
    je .dke_both_numeric
    cmp ecx, TAG_FLOAT
    je .dke_both_numeric
    cmp ecx, TAG_BOOL
    je .dke_both_numeric
    cmp ecx, TAG_PTR
    jne .dke_not_equal          ; a numeric, b not → not equal
    ; TAG_PTR: check if int_type or bool_type
    mov rax, [rsi + PyObject.ob_type]
    lea r8, [rel int_type]
    cmp rax, r8
    je .dke_both_numeric
    lea r8, [rel bool_type]
    cmp rax, r8
    je .dke_both_numeric
    jmp .dke_not_equal          ; a numeric, b not numeric → not equal
.dke_both_numeric:
    ; Convert both to f64 and compare
    ; Save b_key and b_tag (caller-saved regs clobbered by float_to_f64)
    push rsi                    ; save b_key
    push rcx                    ; save b_tag
    mov esi, edx                ; a_tag
    ; rdi = a_key (already set)
    call float_to_f64           ; xmm0 = a as double
    sub rsp, 8
    movsd [rsp], xmm0           ; save a's double on stack
    mov rdi, [rsp + 16]         ; restore b_key (+8 sub + 8 push rcx)
    mov esi, [rsp + 8]          ; restore b_tag (ecx saved as qword)
    call float_to_f64           ; xmm0 = b as double
    movsd xmm1, [rsp]          ; restore a's double
    add rsp, 24                 ; pop scratch + saved rcx + saved rsi
    ucomisd xmm0, xmm1
    jne .dke_not_equal
    jp .dke_not_equal           ; NaN ≠ NaN
    mov eax, 1
    leave
    ret
.dke_not_numeric:
    ; Different payloads — if either is not TAG_PTR, can't be equal
    cmp edx, TAG_PTR
    jne .dke_not_equal
    cmp ecx, TAG_PTR
    jne .dke_not_equal

    ; Both heap ptrs with different addresses — check string equality
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi

    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .dke_try_richcompare

    mov rax, [r12 + PyObject.ob_type]
    cmp rax, rcx
    jne .dke_try_richcompare

    ; Both strings — compare data
    lea rdi, [rbx + PyStrObject.data]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jnz .dke_ne_pop

    ; Equal strings
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret

.dke_try_richcompare:
    ; Both heap ptrs, not strings — try tp_richcompare
    extern obj_is_true
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jz .dke_ne_pop
    ; Call tp_richcompare(a, b, PY_EQ, a_tag=TAG_PTR, b_tag=TAG_PTR)
    mov rdi, rbx
    mov rsi, r12
    mov edx, PY_EQ
    mov ecx, TAG_PTR
    mov r8d, TAG_PTR
    call rax
    ; Check result: if NULL/TAG_NULL → not equal
    test edx, edx
    jz .dke_ne_pop
    ; Check if result is truthy
    mov rdi, rax
    mov rsi, rdx
    push rax
    push rdx
    call obj_is_true
    mov ebx, eax           ; save truthiness
    pop rdx
    pop rdi
    push rbx
    mov rsi, rdx
    DECREF_VAL rdi, rsi
    pop rax                 ; truthiness result
    pop r12
    pop rbx
    leave
    ret

.dke_ne_pop:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.dke_not_equal:
    xor eax, eax
    leave
    ret
END_FUNC dict_keys_equal

;; ============================================================================
;; dict_get(rdi=dict, rsi=key, edx=key_tag) -> (rax=value, rdx=value_tag) or (0, TAG_NULL)
;; Linear probing lookup
;; ============================================================================
DG_KTAG equ 8
DEF_FUNC dict_get, 8
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi                ; rbx = dict
    mov r12, rsi                ; r12 = key
    mov [rbp - DG_KTAG], rdx    ; save key_tag

    ; Hash the key
    mov rdi, r12
    mov rsi, rdx                ; key tag
    call obj_hash
    mov r13, rax                ; r13 = hash

    ; capacity mask = capacity - 1 (capacity is power of 2)
    mov r14, [rbx + PyDictObject.capacity]
    lea r15, [r14 - 1]          ; r15 = mask

    ; Starting slot = hash & mask
    mov rcx, r13
    and rcx, r15                ; rcx = slot index

    ; r14 reused as probe counter
    xor r14d, r14d              ; probes done

align 16
.probe_loop:
    ; Check if we've probed all slots
    cmp r14, [rbx + PyDictObject.capacity]
    jge .not_found

    ; Compute entry address: entries + slot * DICT_ENTRY_SIZE
    mov rax, [rbx + PyDictObject.entries]
    imul rdx, rcx, DICT_ENTRY_SIZE
    add rax, rdx                ; rax = entry ptr

    ; Check if slot is empty (key_tag == 0 means never-used → stop)
    mov rdi, [rax + DictEntry.key]
    cmp byte [rax + DictEntry.key_tag], 0
    je .not_found
    ; Skip tombstoned (deleted) entries
    cmp byte [rax + DictEntry.key_tag], DICT_TOMBSTONE
    je .next_slot

    ; Check hash first (fast reject)
    cmp r13, [rax + DictEntry.hash]
    jne .next_slot

    ; Hash matches - check key equality
    ; rdi already has entry.key
    mov rsi, r12                ; our key
    movzx edx, byte [rax + DictEntry.key_tag]  ; entry's key tag
    push rcx                    ; save slot
    push rax                    ; save entry ptr
    mov rcx, [rbp - DG_KTAG]   ; our key tag
    call dict_keys_equal
    pop rdx                     ; restore entry ptr into rdx
    pop rcx                     ; restore slot
    test eax, eax
    jz .next_slot

    ; Found - return entry.value + tag
    mov rax, [rdx + DictEntry.value]
    movzx edx, byte [rdx + DictEntry.value_tag]
    jmp .done

.next_slot:
    ; Linear probe: slot = (slot + 1) & mask
    inc rcx
    and rcx, r15
    inc r14
    jmp .probe_loop

.not_found:
    RET_NULL

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_get

;; ============================================================================
;; dict_get_index(rdi=dict, rsi=key, edx=key_tag) -> int64
;; Like dict_get but returns the slot index (for IC caching), -1 if not found.
;; ============================================================================
GI_KTAG equ 8
DEF_FUNC dict_get_index, 8
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi                ; rbx = dict
    mov r12, rsi                ; r12 = key
    mov [rbp - GI_KTAG], rdx    ; save key_tag

    mov rdi, r12
    mov rsi, rdx                ; key tag
    call obj_hash
    mov r13, rax                ; r13 = hash

    mov r14, [rbx + PyDictObject.capacity]
    lea r15, [r14 - 1]          ; r15 = mask

    mov rcx, r13
    and rcx, r15                ; rcx = slot index

    xor r14d, r14d              ; probes done

.gi_probe:
    cmp r14, [rbx + PyDictObject.capacity]
    jge .gi_not_found

    mov rax, [rbx + PyDictObject.entries]
    imul rdx, rcx, DICT_ENTRY_SIZE
    add rax, rdx

    mov rdi, [rax + DictEntry.key]
    cmp byte [rax + DictEntry.key_tag], 0
    je .gi_not_found
    cmp byte [rax + DictEntry.key_tag], DICT_TOMBSTONE
    je .gi_next

    cmp r13, [rax + DictEntry.hash]
    jne .gi_next

    mov rsi, r12
    movzx edx, byte [rax + DictEntry.key_tag]
    push rcx
    mov rcx, [rbp - GI_KTAG]
    call dict_keys_equal
    pop rcx
    test eax, eax
    jz .gi_next

    ; Found: return slot index
    mov rax, rcx
    jmp .gi_done

.gi_next:
    inc rcx
    and rcx, r15
    inc r14
    jmp .gi_probe

.gi_not_found:
    mov rax, -1

.gi_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_get_index

;; ============================================================================
;; dict_find_slot(rdi=dict, rsi=key, rdx=hash, rcx=key_tag)
;;   -> rax = entry ptr, rdx = 1 if existing key found, 0 if empty/tombstone slot
;; Internal helper used by dict_set.
;; Tombstone reuse: if no match found but a tombstone was seen, returns it
;; instead of the empty slot, so inserts reclaim deleted entries.
;; ============================================================================
FS_KTAG     equ 8
FS_TOMBPTR  equ 16
DEF_FUNC_LOCAL dict_find_slot, 16
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi                ; dict
    mov r12, rsi                ; key
    mov r13, rdx                ; hash
    mov [rbp - FS_KTAG], rcx    ; save key_tag
    mov qword [rbp - FS_TOMBPTR], 0  ; no tombstone seen yet

    ; mask = capacity - 1
    mov r14, [rbx + PyDictObject.capacity]
    lea r15, [r14 - 1]          ; mask

    ; slot = hash & mask
    mov rcx, r13
    and rcx, r15

    xor r14d, r14d              ; probe counter

.find_loop:
    cmp r14, [rbx + PyDictObject.capacity]
    jge .table_full

    ; entry = entries + slot * DICT_ENTRY_SIZE
    mov rax, [rbx + PyDictObject.entries]
    imul rdx, rcx, DICT_ENTRY_SIZE
    add rax, rdx                ; rax = entry ptr

    ; Empty slot? (check key_tag for TAG_NULL=0)
    mov rdi, [rax + DictEntry.key]
    cmp byte [rax + DictEntry.key_tag], 0
    je .found_empty
    ; Tombstone? Remember first one, keep probing (key may be further)
    cmp byte [rax + DictEntry.key_tag], DICT_TOMBSTONE
    je .find_tombstone

    ; Hash match?
    cmp r13, [rax + DictEntry.hash]
    jne .find_next

    ; Key equality check
    ; rdi = entry.key
    mov rsi, r12
    movzx edx, byte [rax + DictEntry.key_tag]  ; entry's key tag
    push rcx
    push rax
    mov rcx, [rbp - FS_KTAG]   ; our key tag
    call dict_keys_equal
    pop rax                     ; entry ptr
    pop rcx                     ; slot
    test eax, eax
    jnz .found_existing

.find_next:
    inc rcx
    and rcx, r15
    inc r14
    jmp .find_loop

.find_tombstone:
    ; Remember first tombstone for reuse on insert
    cmp qword [rbp - FS_TOMBPTR], 0
    jne .find_next              ; already have one, keep looking
    mov [rbp - FS_TOMBPTR], rax
    jmp .find_next

.found_empty:
    ; No match found — return tombstone slot if we found one, else empty slot
    mov rdx, [rbp - FS_TOMBPTR]
    test rdx, rdx
    jz .return_empty
    mov rax, rdx                ; use tombstone slot
.return_empty:
    xor edx, edx               ; rdx = 0 (new insert)
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.found_existing:
    ; rax = entry ptr, rdx = 1 (existing)
    mov edx, 1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.table_full:
    ; Check if we have a tombstone — use it instead of dying
    mov rax, [rbp - FS_TOMBPTR]
    test rax, rax
    jnz .return_empty
    ; No tombstone and truly full — fatal
    lea rdi, [rel .err_full]
    call fatal_error

section .rodata
.err_full: db "dict: hash table full", 0
section .text
END_FUNC dict_find_slot

;; ============================================================================
;; dict_resize(PyDictObject *dict)
;; Double capacity and rehash all entries
;; ============================================================================
DEF_FUNC_LOCAL dict_resize
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi                ; dict

    ; Save old entries and capacity
    mov r12, [rbx + PyDictObject.entries]    ; old entries
    mov r13, [rbx + PyDictObject.capacity]   ; old capacity

    ; New capacity = old * 2
    lea r14, [r13 * 2]          ; r14 = new capacity
    mov [rbx + PyDictObject.capacity], r14
    mov qword [rbx + PyDictObject.dk_tombstones], 0  ; rehash clears tombstones

    ; Allocate new entries array
    imul rdi, r14, DICT_ENTRY_SIZE
    call ap_malloc
    mov r15, rax                ; r15 = new entries

    ; Zero new entries
    mov rdi, r15
    xor esi, esi
    imul rdx, r14, DICT_ENTRY_SIZE
    call ap_memset

    ; Store new entries pointer
    mov [rbx + PyDictObject.entries], r15

    ; Rehash: iterate old entries, re-insert non-empty ones
    xor ecx, ecx               ; ecx = index into old entries

.rehash_loop:
    cmp rcx, r13                ; compared against old capacity
    jge .rehash_done

    ; old_entry = old_entries + i * DICT_ENTRY_SIZE
    imul rax, rcx, DICT_ENTRY_SIZE
    add rax, r12                ; rax = old entry ptr

    ; Skip empty slots (key_tag == 0) and tombstones (key_tag == DICT_TOMBSTONE)
    cmp byte [rax + DictEntry.key_tag], 0
    je .rehash_next
    cmp byte [rax + DictEntry.key_tag], DICT_TOMBSTONE
    je .rehash_next

    ; Compute new slot: hash & (new_capacity - 1)
    push rcx                    ; save outer index
    mov rcx, [rax + DictEntry.hash]
    mov rdx, r14
    dec rdx                     ; new mask
    and rcx, rdx                ; starting slot

    ; Save entry data (including key_tag)
    push qword [rax + DictEntry.hash]
    push qword [rax + DictEntry.key]
    push qword [rax + DictEntry.value]
    movzx edx, byte [rax + DictEntry.value_tag]
    push rdx
    movzx edx, byte [rax + DictEntry.key_tag]
    push rdx

    ; Linear probe in new table to find empty slot
.rehash_probe:
    imul rax, rcx, DICT_ENTRY_SIZE
    add rax, r15                ; new entry ptr
    cmp byte [rax + DictEntry.key_tag], 0
    je .rehash_insert

    inc rcx
    mov rax, r14
    dec rax
    and rcx, rax                ; slot = (slot+1) & new_mask
    jmp .rehash_probe

.rehash_insert:
    ; rax = target entry ptr in new table
    pop rdx
    mov byte [rax + DictEntry.key_tag], dl
    pop rdx
    mov byte [rax + DictEntry.value_tag], dl
    pop qword [rax + DictEntry.value]
    pop qword [rax + DictEntry.key]
    pop qword [rax + DictEntry.hash]

    pop rcx                     ; restore outer index

.rehash_next:
    inc ecx
    jmp .rehash_loop

.rehash_done:
    ; Free old entries array
    mov rdi, r12
    call ap_free

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_resize

;; ============================================================================
;; dict_set(rdi=dict, rsi=key, rdx=value, rcx=value_tag, r8=key_tag)
;; Insert or update a key-value pair.
;; ============================================================================
DS_VTAG equ 8
DS_KTAG equ 16
DEF_FUNC dict_set, 16
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi                ; dict
    mov r12, rsi                ; key
    mov r13, rdx                ; value
    mov [rbp - DS_VTAG], rcx    ; save value_tag
    mov [rbp - DS_KTAG], r8     ; save key_tag

    ; Hash the key
    mov rdi, r12
    mov rsi, r8                 ; key tag
    call obj_hash
    mov r14, rax                ; r14 = hash

    ; Find slot
    mov rdi, rbx                ; dict
    mov rsi, r12                ; key
    mov rdx, r14                ; hash
    mov rcx, [rbp - DS_KTAG]   ; key_tag
    call dict_find_slot
    ; rax = entry ptr, edx = 1 if existing, 0 if empty

    test edx, edx
    jnz .update_existing

    ; --- Insert new entry ---
    ; Store hash, key, key_tag, value, value_tag
    mov [rax + DictEntry.hash], r14
    mov [rax + DictEntry.key], r12
    mov rcx, [rbp - DS_KTAG]
    mov byte [rax + DictEntry.key_tag], cl
    mov [rax + DictEntry.value], r13

    ; Store value tag from caller
    mov rcx, [rbp - DS_VTAG]
    mov byte [rax + DictEntry.value_tag], cl

    ; INCREF key (tag-aware)
    movzx esi, byte [rax + DictEntry.key_tag]
    INCREF_VAL r12, rsi
    ; INCREF value (tag-aware)
    movzx esi, byte [rax + DictEntry.value_tag]
    INCREF_VAL r13, rsi

    ; Increment ob_size
    inc qword [rbx + PyDictObject.ob_size]

    ; Check load factor: (ob_size + tombstones) > capacity * 3/4
    mov rax, [rbx + PyDictObject.capacity]
    mov rcx, rax
    shr rcx, 2                  ; capacity / 4
    imul rcx, rcx, 3            ; capacity * 3/4
    mov rax, [rbx + PyDictObject.ob_size]
    add rax, [rbx + PyDictObject.dk_tombstones]
    cmp rax, rcx
    jle .done

    ; Resize needed
    mov rdi, rbx
    call dict_resize
    jmp .done

.update_existing:
    ; rax = entry ptr with matching key
    ; DECREF old value (fat)
    push rax                    ; save entry ptr
    mov rdi, [rax + DictEntry.value]
    movzx esi, byte [rax + DictEntry.value_tag]
    DECREF_VAL rdi, rsi
    pop rax                     ; restore entry ptr

    ; Store new value and INCREF it
    mov [rax + DictEntry.value], r13
    ; Store new value tag from caller
    mov rcx, [rbp - DS_VTAG]
    mov byte [rax + DictEntry.value_tag], cl
    movzx esi, byte [rax + DictEntry.value_tag]
    INCREF_VAL r13, rsi                ; value may be SmallInt

.done:
    ; Bump version counter (skip 0 on wrap)
    inc qword [rbx + PyDictObject.dk_version]
    cmp qword [rbx + PyDictObject.dk_version], 0
    jne .ver_ok
    mov qword [rbx + PyDictObject.dk_version], 1
.ver_ok:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_set

;; ============================================================================
;; dict_dealloc(PyObject *self)
;; Free all entries, then free dict
;; ============================================================================
DEF_FUNC dict_dealloc
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi                ; self (dict)
    mov r12, [rbx + PyDictObject.entries]
    mov r13, [rbx + PyDictObject.capacity]
    xor r14d, r14d              ; index

.dealloc_loop:
    cmp r14, r13
    jge .dealloc_entries_done

    ; entry = entries + index * DICT_ENTRY_SIZE
    imul rax, r14, DICT_ENTRY_SIZE
    add rax, r12

    ; Skip empty slots and tombstones
    mov rdi, [rax + DictEntry.key]
    cmp byte [rax + DictEntry.key_tag], 0
    je .dealloc_next
    cmp byte [rax + DictEntry.key_tag], DICT_TOMBSTONE
    je .dealloc_next

    ; DECREF key (tag-aware)
    push rax
    movzx esi, byte [rax + DictEntry.key_tag]
    DECREF_VAL rdi, rsi

    ; DECREF value (tag-aware)
    pop rax
    mov rdi, [rax + DictEntry.value]
    movzx esi, byte [rax + DictEntry.value_tag]
    DECREF_VAL rdi, rsi

.dealloc_next:
    inc r14
    jmp .dealloc_loop

.dealloc_entries_done:
    ; Free entries array
    mov rdi, r12
    call ap_free

    ; Free dict object itself (GC-aware)
    mov rdi, rbx
    call gc_dealloc

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_dealloc

;; ============================================================================
;; dict_len(PyObject *self) -> int64_t
;; Returns ob_size (number of items)
;; ============================================================================
dict_len:
    mov rax, [rdi + PyDictObject.ob_size]
    ret

;; ============================================================================
;; dict_subscript(rdi=dict, rsi=key, edx=key_tag) -> (rax=value, edx=value_tag)
;; mp_subscript: look up key, raise KeyError if not found
;; ============================================================================
DEF_FUNC dict_subscript
    push rbx

    mov rbx, rsi               ; save key for error msg

    ; dict_get(dict, key, key_tag) — edx already has key_tag
    call dict_get
    test edx, edx
    jz .key_error

    ; INCREF the returned value (dict_get returns borrowed fat ref)
    INCREF_VAL rax, rdx                ; value may be SmallInt
    pop rbx
    leave
    ret

.key_error:
    lea rdi, [rel exc_KeyError_type]
    CSTRING rsi, "key not found"
    call raise_exception
END_FUNC dict_subscript

;; ============================================================================
;; dict_ass_subscript(rdi=dict, rsi=key, rdx=value, ecx=key_tag, r8d=value_tag)
;; mp_ass_subscript: set key=value or delete key from dict
;; ============================================================================
DEF_FUNC_BARE dict_ass_subscript
    ; If value tag is TAG_NULL (0), this is a delete operation
    ; (Can't check payload: SmallInt 0 has payload=0 but tag=TAG_SMALLINT)
    test r8, r8                 ; r8 = value_tag from caller
    jz .das_delete
    ; dict_set wants (rdi=dict, rsi=key, rdx=value, rcx=value_tag, r8=key_tag)
    ; Caller passes rcx=key_tag, r8=value_tag — swap them
    xchg rcx, r8
    jmp dict_set
.das_delete:
    ; dict_del wants (rdi=dict, rsi=key, rdx=key_tag)
    mov rdx, rcx               ; key_tag from caller's rcx
    jmp dict_del
END_FUNC dict_ass_subscript

;; ============================================================================
;; dict_del(rdi=dict, rsi=key, edx=key_tag) -> int (0=ok, -1=not found)
;; Delete key from dict. DECREFs both key and value.
;; ============================================================================
DD_KTAG equ 8
DEF_FUNC dict_del, 8
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi                ; dict
    mov r12, rsi                ; key
    mov [rbp - DD_KTAG], rdx    ; save key_tag

    ; Hash the key
    mov rdi, r12
    mov rsi, rdx                ; key tag
    call obj_hash
    mov r13, rax                ; hash

    ; capacity mask
    mov r14, [rbx + PyDictObject.capacity]
    lea r15, [r14 - 1]          ; mask

    ; Starting slot
    mov rcx, r13
    and rcx, r15
    xor r14d, r14d              ; probe counter

.dd_probe:
    cmp r14, [rbx + PyDictObject.capacity]
    jge .dd_not_found

    mov rax, [rbx + PyDictObject.entries]
    imul rdx, rcx, DICT_ENTRY_SIZE
    add rax, rdx

    mov rdi, [rax + DictEntry.key]
    cmp byte [rax + DictEntry.key_tag], 0
    je .dd_not_found
    ; Skip tombstoned (deleted) entries
    cmp byte [rax + DictEntry.key_tag], DICT_TOMBSTONE
    je .dd_next

    cmp r13, [rax + DictEntry.hash]
    jne .dd_next

    mov rsi, r12
    movzx edx, byte [rax + DictEntry.key_tag]  ; entry's key tag
    push rcx
    push rax
    mov rcx, [rbp - DD_KTAG]   ; our key tag
    call dict_keys_equal
    pop rdx                     ; entry ptr
    pop rcx
    test eax, eax
    jz .dd_next

    ; Found: tombstone entry, DECREF key and value, decrement size
    movzx esi, byte [rdx + DictEntry.key_tag]
    push rsi
    mov rdi, [rdx + DictEntry.key]
    mov qword [rdx + DictEntry.key], 0
    mov byte [rdx + DictEntry.key_tag], DICT_TOMBSTONE  ; tombstone, not empty
    push qword [rdx + DictEntry.value]
    movzx esi, byte [rdx + DictEntry.value_tag]
    push rsi
    mov qword [rdx + DictEntry.value], 0
    mov byte [rdx + DictEntry.value_tag], 0

    ; DECREF key (tag-aware)
    mov rsi, [rsp + 16]         ; key_tag (3 pushes deep)
    DECREF_VAL rdi, rsi
    pop rsi                     ; value_tag
    pop rdi                     ; value payload
    DECREF_VAL rdi, rsi         ; DECREF value (fat)
    add rsp, 8                  ; pop key_tag
    dec qword [rbx + PyDictObject.ob_size]
    inc qword [rbx + PyDictObject.dk_tombstones]
    ; Bump version counter
    inc qword [rbx + PyDictObject.dk_version]
    cmp qword [rbx + PyDictObject.dk_version], 0
    jne .dd_ver_ok
    mov qword [rbx + PyDictObject.dk_version], 1
.dd_ver_ok:
    xor eax, eax               ; return 0 = success
    jmp .dd_done

.dd_next:
    inc rcx
    and rcx, r15
    inc r14
    jmp .dd_probe

.dd_not_found:
    lea rdi, [rel exc_KeyError_type]
    CSTRING rsi, "key not found"
    call raise_exception
    ; raise_exception does not return

.dd_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_del

; dict_repr is in src/repr.asm
extern dict_repr

;; ============================================================================
;; dict_tp_iter(PyDictObject *dict) -> PyDictIterObject*
;; Create a new dict key iterator.
;; rdi = dict
;; ============================================================================
DEF_FUNC dict_tp_iter
    push rbx

    mov rbx, rdi               ; save dict

    mov edi, PyDictIterObject_size
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel dict_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyDictIterObject.it_dict], rbx
    mov qword [rax + PyDictIterObject.it_index], 0
    mov qword [rax + PyDictIterObject.it_kind], 0  ; 0 = keys
    ; Snapshot dk_version for mutation detection
    mov rcx, [rbx + PyDictObject.dk_version]
    mov [rax + PyDictIterObject.it_version], rcx

    ; INCREF the dict
    mov rdi, rbx
    call obj_incref

    pop rbx
    leave
    ret
END_FUNC dict_tp_iter

;; ============================================================================
;; dict_iter_next(PyDictIterObject *self) -> (rax=key, edx=key_tag) or (0, TAG_NULL)
;; Return next key, or (0, TAG_NULL) if exhausted.
;; Scans entries for next non-empty slot.
;; rdi = iterator
;; ============================================================================
extern exc_RuntimeError_type

DEF_FUNC_BARE dict_iter_next
    ; Mutation detection: compare saved version with current
    mov rax, [rdi + PyDictIterObject.it_dict]         ; dict
    mov rcx, [rax + PyDictObject.dk_version]
    cmp rcx, [rdi + PyDictIterObject.it_version]
    jne .di_mutation_error

    mov r10, [rdi + PyDictIterObject.it_kind]         ; 0=keys, 1=values, 2=items
    mov rcx, [rdi + PyDictIterObject.it_index]        ; current index
    mov rdx, [rax + PyDictObject.capacity]            ; capacity
    mov rsi, [rax + PyDictObject.entries]              ; entries ptr

.di_scan:
    cmp rcx, rdx
    jge .di_exhausted

    ; Check if entry at index has a key (key_tag != TAG_NULL)
    imul rax, rcx, DictEntry_size
    add rax, rsi
    cmp byte [rax + DictEntry.key_tag], 0
    je .di_skip
    cmp byte [rax + DictEntry.key_tag], DICT_TOMBSTONE
    je .di_skip

    ; Found a valid entry — advance index
    inc rcx
    mov [rdi + PyDictIterObject.it_index], rcx

    ; Branch on kind
    cmp r10, 1
    je .di_return_value
    ja .di_return_item

    ; kind=0: return key
    movzx edx, byte [rax + DictEntry.key_tag]
    mov rax, [rax + DictEntry.key]
    INCREF_VAL rax, rdx
    ret

.di_return_value:
    ; kind=1: return value
    movzx edx, byte [rax + DictEntry.value_tag]
    mov rax, [rax + DictEntry.value]
    INCREF_VAL rax, rdx
    ret

.di_return_item:
    ; kind=2: return (key, value) 2-tuple
    ; rax = entry ptr — need to allocate tuple, so must save entry
    push rbx
    push r12
    mov rbx, rax                ; save entry ptr

    ; Allocate 2-tuple
    mov edi, 2
    extern tuple_new
    call tuple_new
    mov r12, rax                ; r12 = new tuple

    mov r9, [r12 + PyTupleObject.ob_item]
    mov r10, [r12 + PyTupleObject.ob_item_tags]

    ; tuple[0] = key
    mov rax, [rbx + DictEntry.key]
    movzx edx, byte [rbx + DictEntry.key_tag]
    mov [r9], rax
    mov byte [r10], dl
    INCREF_VAL rax, rdx

    ; tuple[1] = value
    mov rax, [rbx + DictEntry.value]
    movzx edx, byte [rbx + DictEntry.value_tag]
    mov [r9 + 8], rax
    mov byte [r10 + 1], dl
    INCREF_VAL rax, rdx

    mov rax, r12
    mov edx, TAG_PTR

    pop r12
    pop rbx
    ret

.di_skip:
    inc rcx
    jmp .di_scan

.di_exhausted:
    mov [rdi + PyDictIterObject.it_index], rcx
    RET_NULL
    ret

.di_mutation_error:
    lea rdi, [rel exc_RuntimeError_type]
    CSTRING rsi, "dictionary changed size during iteration"
    call raise_exception
END_FUNC dict_iter_next

;; ============================================================================
;; dict_iter_dealloc(PyObject *self)
;; ============================================================================
DEF_FUNC_LOCAL dict_iter_dealloc
    push rbx
    mov rbx, rdi

    ; DECREF the dict
    mov rdi, [rbx + PyDictIterObject.it_dict]
    call obj_decref

    ; Free self
    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC dict_iter_dealloc

;; ============================================================================
;; dict_iter_self(PyObject *self) -> self with INCREF
;; ============================================================================
dict_iter_self:
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret

;; ============================================================================
;; dict_contains(rdi=dict, rsi=key, edx=key_tag) -> int (0 or 1)
;; For the 'in' operator: checks if key exists in dict.
;; ============================================================================
DEF_FUNC_BARE dict_contains
    ; edx already has key_tag, pass through to dict_get
    call dict_get
    test edx, edx
    jz .dc_no
    mov eax, 1
    ret
.dc_no:
    xor eax, eax
    ret
END_FUNC dict_contains

;; ============================================================================
;; Dict View Objects
;; dict.keys(), dict.values(), dict.items() return view objects.
;; Views hold a reference to the dict and support iteration + len().
;; ============================================================================

;; ============================================================================
;; dict_view_new(rdi=dict, rsi=kind, rdx=type_ptr) -> PyDictViewObject*
;; Create a new dict view. kind: 0=keys, 1=values, 2=items
;; ============================================================================
global dict_view_new
DEF_FUNC dict_view_new
    push rbx
    push r12
    push r13

    mov rbx, rdi               ; dict
    mov r12, rsi               ; kind
    mov r13, rdx               ; view type

    mov edi, PyDictViewObject_size
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    mov [rax + PyObject.ob_type], r13
    mov [rax + PyDictViewObject.dv_dict], rbx
    mov [rax + PyDictViewObject.dv_kind], r12

    ; INCREF dict
    mov rdi, rbx
    call obj_incref

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_view_new

;; ============================================================================
;; dict_view_dealloc(PyObject *self)
;; ============================================================================
DEF_FUNC_LOCAL dict_view_dealloc
    push rbx
    mov rbx, rdi

    ; DECREF dict
    mov rdi, [rbx + PyDictViewObject.dv_dict]
    call obj_decref

    ; Free self
    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC dict_view_dealloc

;; ============================================================================
;; dict_view_len(rdi=view) -> i64
;; Returns the number of items in the underlying dict.
;; ============================================================================
DEF_FUNC_BARE dict_view_len
    mov rax, [rdi + PyDictViewObject.dv_dict]
    mov rax, [rax + PyDictObject.ob_size]
    ret
END_FUNC dict_view_len

;; ============================================================================
;; dict_view_iter(rdi=view) -> PyDictIterObject*
;; Create an iterator for this view, using the view's kind.
;; ============================================================================
global dict_view_iter
DEF_FUNC dict_view_iter
    push rbx
    push r12

    mov rbx, rdi               ; view

    mov edi, PyDictIterObject_size
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel dict_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov rdi, [rbx + PyDictViewObject.dv_dict]
    mov [rax + PyDictIterObject.it_dict], rdi
    mov qword [rax + PyDictIterObject.it_index], 0
    mov rcx, [rbx + PyDictViewObject.dv_kind]
    mov [rax + PyDictIterObject.it_kind], rcx
    ; Snapshot dk_version for mutation detection
    mov rcx, [rdi + PyDictObject.dk_version]
    mov [rax + PyDictIterObject.it_version], rcx

    ; INCREF dict
    push rax                    ; save iterator
    call obj_incref
    pop rax                     ; restore iterator

    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_view_iter


;; ============================================================================
;; dict_keys_view_contains(rdi=view, rsi=key, rdx=key_tag) -> int (0 or 1)
;; sq_contains for dict_keys view: delegates to dict_contains on underlying dict.
;; ============================================================================
DEF_FUNC_BARE dict_keys_view_contains
    mov rdi, [rdi + PyDictViewObject.dv_dict]
    jmp dict_contains           ; (rdi=dict, rsi=key, rdx=key_tag)
END_FUNC dict_keys_view_contains

;; ============================================================================
;; dict_nb_or(left, right, ltag, rtag) -> new dict (merge)
;; Implements dict | dict -> new dict containing all items from both.
;; Right dict values override left on key collision.
;; ============================================================================
DNO_LEFT  equ 8
DNO_RIGHT equ 16
DNO_NEW   equ 24
DNO_FRAME equ 32

DEF_FUNC dict_nb_or, DNO_FRAME
    mov [rbp - DNO_LEFT], rdi       ; left dict
    mov [rbp - DNO_RIGHT], rsi      ; right dict

    ; Create new dict
    call dict_new
    mov [rbp - DNO_NEW], rax

    ; Copy all entries from left dict
    mov rdi, [rbp - DNO_LEFT]
    mov r8, [rdi + PyDictObject.capacity]
    xor ecx, ecx                    ; index = 0
.dno_copy_left:
    cmp rcx, r8
    jge .dno_copy_right_start

    imul rax, rcx, DICT_ENTRY_SIZE
    add rax, [rdi + PyDictObject.entries]
    ; Check if entry is occupied (value_tag != 0)
    cmp byte [rax + DictEntry.value_tag], 0
    je .dno_left_next

    ; dict_set(dict, key, value, value_tag, key_tag)
    push rcx
    push r8
    push rdi
    mov rdi, [rbp - DNO_NEW]
    mov rsi, [rax + DictEntry.key]
    mov rdx, [rax + DictEntry.value]
    movzx ecx, byte [rax + DictEntry.value_tag]    ; value_tag
    movzx r8d, byte [rax + DictEntry.key_tag]      ; key_tag
    call dict_set
    pop rdi
    pop r8
    pop rcx

.dno_left_next:
    inc rcx
    jmp .dno_copy_left

.dno_copy_right_start:
    ; Copy all entries from right dict (overrides left)
    mov rdi, [rbp - DNO_RIGHT]
    mov r8, [rdi + PyDictObject.capacity]
    xor ecx, ecx
.dno_copy_right:
    cmp rcx, r8
    jge .dno_done

    imul rax, rcx, DICT_ENTRY_SIZE
    add rax, [rdi + PyDictObject.entries]
    cmp byte [rax + DictEntry.value_tag], 0
    je .dno_right_next

    push rcx
    push r8
    push rdi
    mov rdi, [rbp - DNO_NEW]
    mov rsi, [rax + DictEntry.key]
    mov rdx, [rax + DictEntry.value]
    movzx ecx, byte [rax + DictEntry.value_tag]    ; value_tag
    movzx r8d, byte [rax + DictEntry.key_tag]      ; key_tag
    call dict_set
    pop rdi
    pop r8
    pop rcx

.dno_right_next:
    inc rcx
    jmp .dno_copy_right

.dno_done:
    mov rax, [rbp - DNO_NEW]
    mov edx, TAG_PTR
    leave
    ret
END_FUNC dict_nb_or

;; ============================================================================
;; dict_nb_ior(left, right, ltag, rtag) -> left dict (inplace merge |=)
;; Iterates right dict entries and dict_set each into left.
;; Returns (left, TAG_PTR) with INCREF on left.
;; ============================================================================
DIO_LEFT  equ 8
DIO_RIGHT equ 16
DIO_FRAME equ 24

DEF_FUNC dict_nb_ior, DIO_FRAME
    mov [rbp - DIO_LEFT], rdi       ; left dict
    mov [rbp - DIO_RIGHT], rsi      ; right dict

    ; Iterate right dict entries, set each into left
    mov rdi, [rbp - DIO_RIGHT]
    mov r8, [rdi + PyDictObject.capacity]
    xor ecx, ecx
.dio_loop:
    cmp rcx, r8
    jge .dio_done

    imul rax, rcx, DICT_ENTRY_SIZE
    add rax, [rdi + PyDictObject.entries]
    cmp byte [rax + DictEntry.value_tag], 0
    je .dio_next

    push rcx
    push r8
    push rdi
    mov rdi, [rbp - DIO_LEFT]
    mov rsi, [rax + DictEntry.key]
    mov rdx, [rax + DictEntry.value]
    movzx ecx, byte [rax + DictEntry.value_tag]
    movzx r8d, byte [rax + DictEntry.key_tag]
    call dict_set
    pop rdi
    pop r8
    pop rcx

.dio_next:
    inc rcx
    jmp .dio_loop

.dio_done:
    ; Return left dict with INCREF (caller will DECREF both operands)
    mov rax, [rbp - DIO_LEFT]
    INCREF rax
    mov edx, TAG_PTR
    leave
    ret
END_FUNC dict_nb_ior


;; ============================================================================
;; dict_richcompare(left, right, op, left_tag, right_tag) -> (payload, tag)
;; rdi=left, rsi=right, edx=op, rcx=left_tag, r8=right_tag
;; Only supports Py_EQ (2) and Py_NE (3).
;; Two dicts are equal if they have the same size and all key-value pairs match.
;; ============================================================================

DRC_LEFT  equ 8
DRC_RIGHT equ 16
DRC_OP    equ 24
DRC_LVAL  equ 32
DRC_LTAG  equ 40
DRC_FRAME equ 48

DEF_FUNC dict_richcompare, DRC_FRAME
    ; edx = op (PY_EQ=2, PY_NE=3)
    mov [rbp - DRC_LEFT], rdi
    mov [rbp - DRC_RIGHT], rsi
    mov [rbp - DRC_OP], edx

    ; Only handle EQ (2) and NE (3)
    cmp edx, 2
    je .drc_do_eq
    cmp edx, 3
    je .drc_do_eq
    ; Unsupported op — return NotImplemented (NULL)
    RET_NULL
    leave
    ret

.drc_do_eq:
    ; Compare sizes
    mov rdi, [rbp - DRC_LEFT]
    mov rsi, [rbp - DRC_RIGHT]
    mov rax, [rdi + PyDictObject.ob_size]
    mov rcx, [rsi + PyDictObject.ob_size]
    cmp rax, rcx
    jne .drc_not_equal

    ; Same size — check all key-value pairs from left exist in right with same value
    mov r9, [rdi + PyDictObject.capacity]
    xor r10d, r10d                  ; index = 0

.drc_loop:
    cmp r10, r9
    jge .drc_equal

    mov rdi, [rbp - DRC_LEFT]
    imul rax, r10, DICT_ENTRY_SIZE
    add rax, [rdi + PyDictObject.entries]

    ; Skip empty entries
    cmp byte [rax + DictEntry.value_tag], 0
    je .drc_next

    ; Save entry data to stack slots (safe across function calls)
    push r9
    push r10
    mov r11, [rax + DictEntry.value]        ; left value
    movzx r9d, byte [rax + DictEntry.value_tag]    ; left value tag
    mov [rbp - DRC_LVAL], r11               ; save to stack slot
    mov [rbp - DRC_LTAG], r9                ; save to stack slot

    ; Lookup key in right dict
    mov rdi, [rbp - DRC_RIGHT]
    mov rsi, [rax + DictEntry.key]
    movzx edx, byte [rax + DictEntry.key_tag]
    call dict_get
    ; rax = right value, edx = tag (0 = not found)
    ; NOTE: r11 and r9 are caller-saved and may be clobbered by dict_get
    test edx, edx
    jz .drc_not_equal_pop           ; key not in right

    ; Reload left value and tag from stack slots
    mov r11, [rbp - DRC_LVAL]
    mov r9d, [rbp - DRC_LTAG]

    ; Quick compare: same payload and same tag → equal
    cmp rax, r11
    jne .drc_values_differ
    cmp edx, r9d
    je .drc_values_match

.drc_values_differ:
    ; For SmallInt: both TAG_SMALLINT, compare payloads directly
    cmp r9d, TAG_SMALLINT
    jne .drc_ptr_compare
    cmp edx, TAG_SMALLINT
    jne .drc_not_equal_pop
    ; Both SmallInt, payloads differ → not equal
    jmp .drc_not_equal_pop

.drc_ptr_compare:
    ; Both TAG_PTR: use tp_richcompare
    cmp r9d, TAG_PTR
    jne .drc_not_equal_pop
    cmp edx, TAG_PTR
    jne .drc_not_equal_pop
    ; Call tp_richcompare(left_val, right_val, PY_EQ, TAG_PTR, TAG_PTR)
    mov rdi, r11                    ; left value
    mov rsi, rax                    ; right value
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jz .drc_not_equal_pop           ; no tp_richcompare
    mov edx, 2                      ; PY_EQ
    mov ecx, TAG_PTR
    mov r8d, TAG_PTR
    call rax
    ; Result: (rax=payload, edx=tag)
    ; Check if result is True (TAG_BOOL with payload=1)
    cmp edx, TAG_BOOL
    jne .drc_not_equal_pop
    test eax, eax
    jz .drc_not_equal_pop
    jmp .drc_values_match

.drc_not_equal_pop:
    pop r10
    pop r9
.drc_not_equal:
    ; Return based on op: EQ→False, NE→True
    cmp dword [rbp - DRC_OP], 3     ; NE?
    je .drc_ret_true
    xor eax, eax                    ; False
    mov edx, TAG_BOOL
    leave
    ret

.drc_values_match:
    pop r10
    pop r9

.drc_next:
    inc r10
    jmp .drc_loop

.drc_equal:
    ; Return based on op: EQ→True, NE→False
    cmp dword [rbp - DRC_OP], 3     ; NE?
    je .drc_ret_false
.drc_ret_true:
    mov eax, 1                      ; True
    mov edx, TAG_BOOL
    leave
    ret

.drc_ret_false:
    xor eax, eax                    ; False
    mov edx, TAG_BOOL
    leave
    ret
END_FUNC dict_richcompare


;; ============================================================================
;; dict_reversed(args, nargs) -> PyDictIterObject* (reverse key iterator)
;; Called as dict.__reversed__(self).
;; args[0] = dict (self), nargs = 1
;; ============================================================================
DEF_FUNC dict_reversed
    ; args[0] = self (dict)
    mov rax, [rdi]             ; dict payload
    push rbx

    mov rbx, rax               ; rbx = dict

    mov edi, PyDictIterObject_size
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel dict_rev_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyDictIterObject.it_dict], rbx
    ; Set it_index to capacity - 1 (start from end)
    mov rcx, [rbx + PyDictObject.capacity]
    dec rcx
    mov [rax + PyDictIterObject.it_index], rcx
    mov qword [rax + PyDictIterObject.it_kind], 0  ; 0 = keys
    ; Snapshot dk_version for mutation detection
    mov rcx, [rbx + PyDictObject.dk_version]
    mov [rax + PyDictIterObject.it_version], rcx

    ; INCREF the dict
    push rax
    mov rdi, rbx
    call obj_incref
    pop rax

    mov edx, TAG_PTR
    pop rbx
    leave
    ret
END_FUNC dict_reversed

;; ============================================================================
;; dict_rev_iter_next(PyDictIterObject *self) -> (rax=key, edx=key_tag) or NULL
;; Like dict_iter_next but scans backwards (decrements index).
;; ============================================================================
DEF_FUNC_BARE dict_rev_iter_next
    ; Mutation detection
    mov rax, [rdi + PyDictIterObject.it_dict]
    mov rcx, [rax + PyDictObject.dk_version]
    cmp rcx, [rdi + PyDictIterObject.it_version]
    jne .dri_mutation_error

    mov rcx, [rdi + PyDictIterObject.it_index]        ; current index
    mov rsi, [rax + PyDictObject.entries]              ; entries ptr

.dri_scan:
    test rcx, rcx
    js .dri_exhausted           ; index < 0 → done

    ; Check if entry at index has a valid key
    imul rax, rcx, DictEntry_size
    add rax, rsi
    cmp byte [rax + DictEntry.key_tag], 0
    je .dri_skip
    cmp byte [rax + DictEntry.key_tag], DICT_TOMBSTONE
    je .dri_skip

    ; Found a valid entry — save decremented index
    dec rcx
    mov [rdi + PyDictIterObject.it_index], rcx

    ; Return key
    movzx edx, byte [rax + DictEntry.key_tag]
    mov rax, [rax + DictEntry.key]
    INCREF_VAL rax, rdx
    ret

.dri_skip:
    dec rcx
    jmp .dri_scan

.dri_exhausted:
    mov [rdi + PyDictIterObject.it_index], rcx
    RET_NULL
    ret

.dri_mutation_error:
    lea rdi, [rel exc_RuntimeError_type]
    CSTRING rsi, "dictionary changed size during iteration"
    call raise_exception
END_FUNC dict_rev_iter_next

;; ============================================================================
;; Data section
;; ============================================================================
section .data

; dict_repr_str removed - repr now in src/repr.asm
dict_iter_name: db "dict_keyiterator", 0
dict_rev_iter_name: db "dict_reversekeyiterator", 0
dict_keys_view_name: db "dict_keys", 0
dict_values_view_name: db "dict_values", 0
dict_items_view_name: db "dict_items", 0

dict_name_str: db "dict", 0

; Dict mapping methods
align 8
global dict_mapping_methods
dict_mapping_methods:
    dq dict_len                 ; mp_length
    dq dict_subscript           ; mp_subscript
    dq dict_ass_subscript       ; mp_ass_subscript

; Dict number methods (for | operator)
align 8
dict_number_methods:
    dq 0                        ; nb_add          +0
    dq 0                        ; nb_subtract     +8
    dq 0                        ; nb_multiply     +16
    dq 0                        ; nb_remainder    +24
    dq 0                        ; nb_divmod       +32
    dq 0                        ; nb_power        +40
    dq 0                        ; nb_negative     +48
    dq 0                        ; nb_positive     +56
    dq 0                        ; nb_absolute     +64
    dq 0                        ; nb_bool         +72
    dq 0                        ; nb_invert       +80
    dq 0                        ; nb_lshift       +88
    dq 0                        ; nb_rshift       +96
    dq 0                        ; nb_and          +104
    dq 0                        ; nb_xor          +112
    dq dict_nb_or               ; nb_or           +120 (dict merge |)
    dq 0                        ; nb_int          +128
    dq 0                        ; nb_float        +136
    dq 0                        ; nb_floor_divide +144
    dq 0                        ; nb_true_divide  +152
    dq 0                        ; nb_index        +160
    ; Inplace slots
    dq 0                        ; nb_iadd         +168
    dq 0                        ; nb_isub         +176
    dq 0                        ; nb_imul         +184
    dq 0                        ; nb_irem         +192
    dq 0                        ; nb_ipow         +200
    dq 0                        ; nb_ilshift      +208
    dq 0                        ; nb_irshift      +216
    dq 0                        ; nb_iand         +224
    dq 0                        ; nb_ixor         +232
    dq dict_nb_ior              ; nb_ior          +240 (dict inplace merge |=)
    dq 0                        ; nb_ifloor_divide +248
    dq 0                        ; nb_itrue_divide +256

; Dict sequence methods (for 'in' operator)
align 8
dict_sequence_methods:
    dq dict_len                 ; sq_length
    dq 0                        ; sq_concat
    dq 0                        ; sq_repeat
    dq 0                        ; sq_item
    dq 0                        ; sq_ass_item
    dq dict_contains            ; sq_contains
    dq 0                        ; sq_inplace_concat
    dq 0                        ; sq_inplace_repeat

; Dict type object
align 8
global dict_type
dict_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq dict_name_str            ; tp_name
    dq PyDictObject_size        ; tp_basicsize
    dq dict_dealloc             ; tp_dealloc
    dq dict_repr                ; tp_repr
    dq dict_repr                ; tp_str
    extern hash_not_implemented
    dq hash_not_implemented     ; tp_hash (raises TypeError)
    dq dict_type_call           ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq dict_richcompare         ; tp_richcompare
    dq dict_tp_iter             ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq dict_number_methods      ; tp_as_number
    dq dict_sequence_methods    ; tp_as_sequence (for 'in' operator)
    dq dict_mapping_methods     ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC | TYPE_FLAG_DICT_SUBCLASS  ; tp_flags
    dq 0                        ; tp_bases
    dq dict_traverse                        ; tp_traverse
    dq dict_clear_gc                        ; tp_clear

; Dict key iterator type
align 8
global dict_iter_type
dict_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq dict_iter_name           ; tp_name
    dq PyDictIterObject_size    ; tp_basicsize
    dq dict_iter_dealloc        ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq dict_iter_self           ; tp_iter (return self)
    dq dict_iter_next           ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq 0                        ; tp_flags
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear

; Dict reverse key iterator type
align 8
global dict_rev_iter_type
dict_rev_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq dict_rev_iter_name       ; tp_name
    dq PyDictIterObject_size    ; tp_basicsize
    dq dict_iter_dealloc        ; tp_dealloc (reuse forward iter dealloc)
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq dict_iter_self           ; tp_iter (return self)
    dq dict_rev_iter_next       ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq 0                        ; tp_flags
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear

; Dict keys view sequence methods (len + contains)
align 8
dict_keys_view_seq_methods:
    dq dict_view_len            ; sq_length
    dq 0                        ; sq_concat
    dq 0                        ; sq_repeat
    dq 0                        ; sq_item
    dq 0                        ; sq_ass_item
    dq dict_keys_view_contains  ; sq_contains
    dq 0                        ; sq_inplace_concat
    dq 0                        ; sq_inplace_repeat

; Dict view sequence methods (for len(), values/items views)
align 8
dict_view_sequence_methods:
    dq dict_view_len            ; sq_length
    dq 0                        ; sq_concat
    dq 0                        ; sq_repeat
    dq 0                        ; sq_item
    dq 0                        ; sq_ass_item
    dq 0                        ; sq_contains
    dq 0                        ; sq_inplace_concat
    dq 0                        ; sq_inplace_repeat

; Dict keys view type
align 8
global dict_keys_view_type
dict_keys_view_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq dict_keys_view_name      ; tp_name
    dq PyDictViewObject_size    ; tp_basicsize
    dq dict_view_dealloc        ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq dict_view_iter           ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq dict_keys_view_seq_methods ; tp_as_sequence (with sq_contains)
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq 0                        ; tp_flags
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear

; Dict values view type
align 8
global dict_values_view_type
dict_values_view_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq dict_values_view_name    ; tp_name
    dq PyDictViewObject_size    ; tp_basicsize
    dq dict_view_dealloc        ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq dict_view_iter           ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq dict_view_sequence_methods ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq 0                        ; tp_flags
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear

; Dict items view type
align 8
global dict_items_view_type
dict_items_view_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq dict_items_view_name     ; tp_name
    dq PyDictViewObject_size    ; tp_basicsize
    dq dict_view_dealloc        ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq dict_view_iter           ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq dict_view_sequence_methods ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq 0                        ; tp_flags
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
