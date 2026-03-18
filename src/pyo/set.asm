; set.asm - Set type implementation
; Hash table with open-addressing and linear probing (no values, keys only)

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
extern obj_incref
extern str_type
extern ap_strcmp
extern ap_memset
extern fatal_error
extern str_from_cstr
extern type_type
extern set_traverse
extern set_clear_gc

; Set entry layout constants
SET_ENTRY_HASH    equ 0
SET_ENTRY_KEY     equ 8
SET_ENTRY_KEY_TAG equ 16
SET_ENTRY_SIZE    equ 24

; Initial capacity (must be power of 2)
SET_INIT_CAP equ 8

; Tombstone marker for deleted entries (must not collide with any tag)
SET_TOMBSTONE equ 0xDEAD

;; ============================================================================
;; set_new() -> PySetObject* (uses PyDictObject layout)
;; Allocate a new empty set with initial capacity 8
;; ============================================================================
DEF_FUNC set_new
    push rbx

    ; Allocate set header (GC-tracked, reuses PyDictObject layout)
    mov edi, PyDictObject_size
    lea rsi, [rel set_type]
    call gc_alloc
    mov rbx, rax                ; rbx = set (ob_refcnt=1, ob_type set)

    mov qword [rbx + PyDictObject.ob_size], 0
    mov qword [rbx + PyDictObject.capacity], SET_INIT_CAP
    mov qword [rbx + PyDictObject.dk_version], 0
    mov qword [rbx + PyDictObject.dk_tombstones], 0

    ; Allocate entries array: capacity * SET_ENTRY_SIZE
    mov edi, SET_INIT_CAP * SET_ENTRY_SIZE
    call ap_malloc
    mov [rbx + PyDictObject.entries], rax

    ; Zero out entries (NULL key = empty slot)
    mov rdi, rax
    xor esi, esi
    mov edx, SET_INIT_CAP * SET_ENTRY_SIZE
    call ap_memset

    mov rdi, rbx
    call gc_track

    mov rax, rbx
    pop rbx
    leave
    ret
END_FUNC set_new

;; ============================================================================
;; set_keys_equal(a, b, a_tag, b_tag) -> int (1=equal, 0=not)
;; Internal helper: payload+tag fast path, TAG_PTR guard
;; rdi=a payload, rsi=b payload, rdx=a_tag, rcx=b_tag
;; ============================================================================
DEF_FUNC_LOCAL set_keys_equal
    ; Fast path: both payload AND tag identical → equal
    ; Handles SmallInt==SmallInt, same heap ptr
    cmp rdi, rsi
    jne .ske_diff_payload
    cmp rdx, rcx
    jne .ske_diff_payload
    mov eax, 1
    leave
    ret

.ske_diff_payload:
    ; If either is not TAG_PTR, can't be equal
    cmp edx, TAG_PTR
    jne .ske_not_equal
    cmp ecx, TAG_PTR
    jne .ske_not_equal

    ; Both heap ptrs with different addresses — check string equality
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi

    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .ske_ne_pop2

    mov rax, [r12 + PyObject.ob_type]
    cmp rax, rcx
    jne .ske_ne_pop2

    ; Both strings — compare data
    lea rdi, [rbx + PyStrObject.data]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jnz .ske_ne_pop2

    ; Equal strings
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret

.ske_ne_pop2:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.ske_not_equal:
    xor eax, eax
    leave
    ret
END_FUNC set_keys_equal

;; ============================================================================
;; set_find_slot(set, key, hash, key_tag)
;;   rdi=set, rsi=key, rdx=hash, rcx=key_tag
;;   -> rax = entry ptr, rdx = 1 if existing key found, 0 if empty slot
;; Internal helper used by set_add and set_contains
;; ============================================================================
SFS_KEY_TAG equ 8
DEF_FUNC_LOCAL set_find_slot
    sub rsp, SFS_KEY_TAG
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi                ; set
    mov r12, rsi                ; key
    mov r13, rdx                ; hash
    mov [rbp - SFS_KEY_TAG], rcx ; save key_tag

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

    ; entry = entries + slot * SET_ENTRY_SIZE
    mov rax, [rbx + PyDictObject.entries]
    imul rdx, rcx, SET_ENTRY_SIZE
    add rax, rdx                ; rax = entry ptr

    ; Empty slot? Check key_tag (TAG_NULL=0 means empty)
    mov rdi, [rax + SET_ENTRY_KEY]
    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .found_empty

    ; Tombstone? Continue probing past deleted entries
    cmp qword [rax + SET_ENTRY_KEY_TAG], SET_TOMBSTONE
    je .find_next

    ; Hash match?
    cmp r13, [rax + SET_ENTRY_HASH]
    jne .find_next

    ; Key equality check
    ; rdi = entry.key (already loaded above)
    push rcx                    ; save slot
    push rax                    ; save entry ptr
    mov rdx, [rax + SET_ENTRY_KEY_TAG]  ; a_tag (entry key)
    mov rsi, r12                        ; b = lookup key
    mov rcx, [rbp - SFS_KEY_TAG]        ; b_tag (lookup key tag)
    call set_keys_equal
    mov edi, eax                ; save equality result (survives pops)
    pop rax                     ; entry ptr
    pop rcx                     ; slot
    test edi, edi
    jnz .found_existing

.find_next:
    inc rcx
    and rcx, r15
    inc r14
    jmp .find_loop

.found_empty:
    ; rax = entry ptr, rdx = 0 (empty)
    xor edx, edx
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
    ; Should never happen if load factor is maintained
    CSTRING rdi, "set: hash table full"
    call fatal_error
END_FUNC set_find_slot

;; ============================================================================
;; set_resize(set)
;; Double capacity and rehash all entries
;; ============================================================================
DEF_FUNC_LOCAL set_resize
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi                ; set

    ; Save old entries and capacity
    mov r12, [rbx + PyDictObject.entries]    ; old entries
    mov r13, [rbx + PyDictObject.capacity]   ; old capacity

    ; New capacity = old * 2
    lea r14, [r13 * 2]          ; r14 = new capacity
    mov [rbx + PyDictObject.capacity], r14
    mov qword [rbx + PyDictObject.dk_tombstones], 0  ; rehash clears tombstones

    ; Allocate new entries array
    imul rdi, r14, SET_ENTRY_SIZE
    call ap_malloc
    mov r15, rax                ; r15 = new entries

    ; Zero new entries
    mov rdi, r15
    xor esi, esi
    imul rdx, r14, SET_ENTRY_SIZE
    call ap_memset

    ; Store new entries pointer
    mov [rbx + PyDictObject.entries], r15

    ; Rehash: iterate old entries, re-insert non-empty ones
    xor ecx, ecx               ; ecx = index into old entries

.rehash_loop:
    cmp rcx, r13                ; compared against old capacity
    jge .rehash_done

    ; old_entry = old_entries + i * SET_ENTRY_SIZE
    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r12                ; rax = old entry ptr

    ; Skip empty slots (TAG_NULL=0) and tombstones (SET_TOMBSTONE)
    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .rehash_next
    cmp qword [rax + SET_ENTRY_KEY_TAG], SET_TOMBSTONE
    je .rehash_next

    ; Compute new slot: hash & (new_capacity - 1)
    push rcx                    ; save outer index
    mov rcx, [rax + SET_ENTRY_HASH]
    mov rdx, r14
    dec rdx                     ; new mask
    and rcx, rdx                ; starting slot

    ; Save entry data
    push qword [rax + SET_ENTRY_HASH]
    push qword [rax + SET_ENTRY_KEY]
    push qword [rax + SET_ENTRY_KEY_TAG]

    ; Linear probe in new table to find empty slot
.rehash_probe:
    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r15                ; new entry ptr
    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .rehash_insert

    inc rcx
    mov rax, r14
    dec rax
    and rcx, rax                ; slot = (slot+1) & new_mask
    jmp .rehash_probe

.rehash_insert:
    ; rax = target entry ptr in new table
    pop qword [rax + SET_ENTRY_KEY_TAG]
    pop qword [rax + SET_ENTRY_KEY]
    pop qword [rax + SET_ENTRY_HASH]

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
END_FUNC set_resize

;; ============================================================================
;; set_add(set, key, key_tag) -> void
;; Add a key to the set. rdx = key_tag.
;; ============================================================================
DEF_FUNC set_add
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi                ; set
    mov r12, rsi                ; key
    mov r14, rdx                ; key_tag

    ; Hash the key
    mov rdi, r12
    mov rsi, r14                ; key_tag (saved from rdx on entry)
    call obj_hash
    mov r13, rax                ; r13 = hash

    ; Find slot
    mov rdi, rbx                ; set
    mov rsi, r12                ; key
    mov rdx, r13                ; hash
    mov rcx, r14                ; key_tag
    call set_find_slot
    ; rax = entry ptr, edx = 1 if existing, 0 if empty

    test edx, edx
    jnz .done                   ; key already exists, do nothing

    ; --- Insert new entry ---
    ; Store hash and key
    mov [rax + SET_ENTRY_HASH], r13
    mov [rax + SET_ENTRY_KEY], r12

    ; Store key tag from caller
    mov [rax + SET_ENTRY_KEY_TAG], r14

    ; INCREF key (tag-aware)
    INCREF_VAL r12, r14

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
    call set_resize

.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_add

;; ============================================================================
;; set_contains(set, key) -> int (0/1)
;; Check if key is in the set
;; ============================================================================
DEF_FUNC set_contains
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi                ; set
    mov r12, rsi                ; key
    mov r14, rdx                ; key_tag

    ; Hash the key
    mov rdi, r12
    mov rsi, r14                ; key_tag
    call obj_hash
    mov r13, rax                ; r13 = hash

    ; Find slot
    mov rdi, rbx                ; set
    mov rsi, r12                ; key
    mov rdx, r13                ; hash
    mov rcx, r14                ; key_tag
    call set_find_slot
    ; rax = entry ptr, edx = 1 if found, 0 if empty slot

    mov eax, edx                ; return 1 if found, 0 if not

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_contains

;; ============================================================================
;; set_richcompare(self, other, op, self_tag, other_tag) -> (rax, edx) fat value
;; Compares two sets. Only PY_EQ and PY_NE implemented.
;; ============================================================================
SRC_SELF  equ 8
SRC_OTHER equ 16
SRC_OP    equ 24
SRC_FRAME equ 24
DEF_FUNC set_richcompare, SRC_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - SRC_SELF], rdi
    mov [rbp - SRC_OTHER], rsi
    mov [rbp - SRC_OP], rdx

    ; Check other is a set or frozenset
    test r8d, TAG_RC_BIT
    jz .src_not_impl
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel set_type]
    cmp rax, rcx
    je .src_is_set
    lea rcx, [rel frozenset_type]
    cmp rax, rcx
    je .src_is_set
    jmp .src_not_impl

.src_is_set:
    cmp edx, PY_EQ
    je .src_eq
    cmp edx, PY_NE
    je .src_ne
    cmp edx, PY_LE
    je .src_le
    cmp edx, PY_GE
    je .src_ge
    cmp edx, PY_LT
    je .src_lt
    cmp edx, PY_GT
    je .src_gt
    jmp .src_not_impl

.src_eq:
    ; Check lengths
    mov rax, [rdi + PyDictObject.ob_size]
    cmp rax, [rsi + PyDictObject.ob_size]
    jne .src_false

    ; Every element of self must be in other
    mov rbx, rdi               ; self (set)
    mov r12, rsi               ; other (set)
    mov r13, [rbx + PyDictObject.capacity]
    xor ecx, ecx               ; index
.src_eq_loop:
    cmp rcx, r13
    jge .src_true

    ; Get entry at index
    imul rax, rcx, SET_ENTRY_SIZE
    add rax, [rbx + PyDictObject.entries]
    ; Check if occupied (key_tag != 0 and != tombstone)
    movzx edx, word [rax + SET_ENTRY_KEY_TAG]
    test edx, edx
    jz .src_eq_next
    cmp edx, SET_TOMBSTONE
    je .src_eq_next

    ; Entry is occupied — check if key is in other set
    push rcx
    mov rdi, r12               ; other set
    mov rsi, [rax + SET_ENTRY_KEY]   ; key
    movzx edx, word [rax + SET_ENTRY_KEY_TAG]
    call set_contains
    pop rcx
    test eax, eax
    jz .src_false              ; not found → not equal

.src_eq_next:
    inc rcx
    jmp .src_eq_loop

.src_le:
    ; self <= other: self is subset of other (every elem of self in other)
    mov rbx, rdi               ; self
    mov r12, rsi               ; other
    mov r13, [rbx + PyDictObject.capacity]
    xor ecx, ecx
.src_le_loop:
    cmp rcx, r13
    jge .src_true
    imul rax, rcx, SET_ENTRY_SIZE
    add rax, [rbx + PyDictObject.entries]
    movzx edx, word [rax + SET_ENTRY_KEY_TAG]
    test edx, edx
    jz .src_le_next
    cmp edx, SET_TOMBSTONE
    je .src_le_next
    push rcx
    mov rdi, r12
    mov rsi, [rax + SET_ENTRY_KEY]
    movzx edx, word [rax + SET_ENTRY_KEY_TAG]
    call set_contains
    pop rcx
    test eax, eax
    jz .src_false
.src_le_next:
    inc rcx
    jmp .src_le_loop

.src_ge:
    ; self >= other: other is subset of self → swap and do <=
    mov rbx, rsi               ; other (check all of other in self)
    mov r12, rdi               ; self
    mov r13, [rbx + PyDictObject.capacity]
    xor ecx, ecx
.src_ge_loop:
    cmp rcx, r13
    jge .src_true
    imul rax, rcx, SET_ENTRY_SIZE
    add rax, [rbx + PyDictObject.entries]
    movzx edx, word [rax + SET_ENTRY_KEY_TAG]
    test edx, edx
    jz .src_ge_next
    cmp edx, SET_TOMBSTONE
    je .src_ge_next
    push rcx
    mov rdi, r12
    mov rsi, [rax + SET_ENTRY_KEY]
    movzx edx, word [rax + SET_ENTRY_KEY_TAG]
    call set_contains
    pop rcx
    test eax, eax
    jz .src_false
.src_ge_next:
    inc rcx
    jmp .src_ge_loop

.src_lt:
    ; self < other: proper subset (self <= other AND len(self) < len(other))
    mov rax, [rdi + PyDictObject.ob_size]
    cmp rax, [rsi + PyDictObject.ob_size]
    jge .src_false             ; not strictly smaller → false
    jmp .src_le                ; then check subset

.src_gt:
    ; self > other: proper superset (self >= other AND len(self) > len(other))
    mov rax, [rdi + PyDictObject.ob_size]
    cmp rax, [rsi + PyDictObject.ob_size]
    jle .src_false             ; not strictly larger → false
    jmp .src_ge                ; then check superset

.src_ne:
    ; PY_NE = not PY_EQ
    push rdi
    push rsi
    mov edx, PY_EQ
    call set_richcompare
    pop rsi
    pop rdi
    ; Negate: if bool_true → return bool_false, vice versa
    test edx, edx
    jz .src_not_impl           ; NULL result → propagate
    lea rcx, [rel bool_true]
    cmp rax, rcx
    je .src_false              ; EQ was True → NE is False
    jmp .src_true              ; EQ was False → NE is True

.src_true:
    extern bool_true
    lea rax, [rel bool_true]
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.src_false:
    extern bool_false
    lea rax, [rel bool_false]
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.src_not_impl:
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_richcompare

;; ============================================================================
;; set_contains_sq(self, key) -> int (0/1)
;; sq_contains wrapper for the sequence methods (for "in" operator)
;; ============================================================================
DEF_FUNC_BARE set_contains_sq
    jmp set_contains
END_FUNC set_contains_sq

;; ============================================================================
;; set_remove(set, key) -> int (0=ok, -1=not found)
;; Remove a key from the set
;; ============================================================================
SR_KEY_TAG equ 8
DEF_FUNC set_remove, SR_KEY_TAG
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi                ; set
    mov r12, rsi                ; key
    mov [rbp - SR_KEY_TAG], rdx ; save key_tag

    ; Hash the key
    mov rdi, r12
    mov rsi, rdx                ; key_tag
    call obj_hash
    mov r13, rax                ; hash

    ; capacity mask
    mov r14, [rbx + PyDictObject.capacity]
    lea r15, [r14 - 1]          ; mask

    ; Starting slot
    mov rcx, r13
    and rcx, r15
    xor r14d, r14d              ; probe counter

.sr_probe:
    cmp r14, [rbx + PyDictObject.capacity]
    jge .sr_not_found

    mov rax, [rbx + PyDictObject.entries]
    imul rdx, rcx, SET_ENTRY_SIZE
    add rax, rdx

    mov rdi, [rax + SET_ENTRY_KEY]
    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .sr_not_found

    ; Skip tombstones — continue probing
    cmp qword [rax + SET_ENTRY_KEY_TAG], SET_TOMBSTONE
    je .sr_next

    cmp r13, [rax + SET_ENTRY_HASH]
    jne .sr_next

    ; rdi = entry.key (already loaded)
    push rcx                    ; save slot
    push rax                    ; save entry ptr
    mov rdx, [rax + SET_ENTRY_KEY_TAG]  ; a_tag (entry key)
    mov rsi, r12                        ; b = lookup key
    mov rcx, [rbp - SR_KEY_TAG]         ; b_tag (lookup key tag)
    call set_keys_equal
    pop rdx                     ; entry ptr
    pop rcx
    test eax, eax
    jz .sr_next

    ; Found: tombstone entry, DECREF key, decrement size
    mov rdi, [rdx + SET_ENTRY_KEY]
    mov rsi, [rdx + SET_ENTRY_KEY_TAG]
    mov qword [rdx + SET_ENTRY_KEY], 0
    mov qword [rdx + SET_ENTRY_KEY_TAG], SET_TOMBSTONE  ; tombstone, not empty
    DECREF_VAL rdi, rsi
    dec qword [rbx + PyDictObject.ob_size]
    inc qword [rbx + PyDictObject.dk_tombstones]
    xor eax, eax               ; return 0 = success
    jmp .sr_done

.sr_next:
    inc rcx
    and rcx, r15
    inc r14
    jmp .sr_probe

.sr_not_found:
    mov eax, -1

.sr_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_remove

;; ============================================================================
;; set_dealloc(PyObject *self)
;; Free all entries, then free set
;; ============================================================================
DEF_FUNC set_dealloc
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi                ; self (set)
    mov r12, [rbx + PyDictObject.entries]
    mov r13, [rbx + PyDictObject.capacity]
    xor r14d, r14d              ; index

.dealloc_loop:
    cmp r14, r13
    jge .dealloc_entries_done

    ; entry = entries + index * SET_ENTRY_SIZE
    imul rax, r14, SET_ENTRY_SIZE
    add rax, r12

    ; Skip empty slots (TAG_NULL=0) and tombstones (SET_TOMBSTONE)
    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .dealloc_next
    cmp qword [rax + SET_ENTRY_KEY_TAG], SET_TOMBSTONE
    je .dealloc_next

    ; DECREF key (fat value)
    mov rdi, [rax + SET_ENTRY_KEY]
    mov rsi, [rax + SET_ENTRY_KEY_TAG]
    DECREF_VAL rdi, rsi

.dealloc_next:
    inc r14
    jmp .dealloc_loop

.dealloc_entries_done:
    ; Free entries array
    mov rdi, r12
    call ap_free

    ; Free set object itself (GC-aware)
    mov rdi, rbx
    call gc_dealloc

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_dealloc

;; ============================================================================
;; set_type_call(self, args, nargs) -> new set
;; Constructor: set() or set(iterable)
;; self = set_type, args = arg array, nargs = count
;; ============================================================================
extern raise_exception
extern exc_TypeError_type

STC_FRAME equ 8
DEF_FUNC set_type_call, STC_FRAME
    push rbx
    push r12

    ; nargs can be 0 or 1
    cmp rdx, 0
    je .stc_empty
    cmp rdx, 1
    jne .stc_error

    ; set(iterable): create set, iterate and add
    mov r12, [rsi]          ; iterable payload
    mov rcx, [rsi + 8]     ; iterable tag

    ; Check iterable is a pointer type before dereferencing
    cmp ecx, TAG_PTR
    jne .stc_not_iterable

    call set_new
    mov rbx, rax            ; rbx = new set

    ; Get iterator: tp_iter(iterable)
    mov rdi, r12
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz .stc_not_iterable_decref_set
    call rax
    mov r12, rax            ; r12 = iterator

.stc_iter_loop:
    ; Get next: tp_iternext(iterator)
    mov rdi, r12
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    test edx, edx           ; check tag (NULL = exhausted)
    jz .stc_iter_done

    ; Add to set (set_add INCREFs, so DECREF the iternext ref after)
    mov rdi, rbx            ; set
    mov rsi, rax            ; key payload
    ; edx = key tag (from tp_iternext)
    push rax                ; save key payload
    push rdx                ; save key tag
    push rdx                ; alignment padding (3 pushes = odd, matches ABI)
    call set_add
    add rsp, 8              ; drop alignment padding
    pop rsi                 ; key tag
    pop rdi                 ; key payload
    DECREF_VAL rdi, rsi     ; release iternext's reference
    jmp .stc_iter_loop

.stc_iter_done:
    ; DECREF iterator
    mov rdi, r12
    call obj_decref

    mov rax, rbx            ; return new set
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.stc_empty:
    call set_new
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.stc_not_iterable_decref_set:
    ; set was already allocated but iterable has no tp_iter — free set
    mov rdi, rbx
    call obj_decref

.stc_not_iterable:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "set() argument is not iterable"
    call raise_exception

.stc_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "set() takes at most 1 argument"
    call raise_exception
END_FUNC set_type_call

; set_repr is in src/repr.asm
extern set_repr

;; ============================================================================
;; set_len(PyObject *self) -> int64_t
;; Returns ob_size (number of items)
;; ============================================================================
DEF_FUNC_BARE set_len
    mov rax, [rdi + PyDictObject.ob_size]
    ret
END_FUNC set_len

;; ============================================================================
;; set_tp_iter(set) -> SetIterObject*
;; Create a new set iterator.
;; rdi = set
;; ============================================================================
DEF_FUNC set_tp_iter
    push rbx

    mov rbx, rdi               ; save set

    ; Reuse PyDictIterObject layout (same structure: refcnt, type, source, index)
    mov edi, PyDictIterObject_size
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel set_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyDictIterObject.it_dict], rbx     ; store set ptr
    mov qword [rax + PyDictIterObject.it_index], 0
    mov qword [rax + PyDictIterObject.it_kind], 0

    ; INCREF the set
    push rax
    mov rdi, rbx
    call obj_incref
    pop rax

    pop rbx
    leave
    ret
END_FUNC set_tp_iter

;; ============================================================================
;; set_iter_next(iter) -> PyObject* or NULL
;; Return next key, or NULL if exhausted.
;; Scans entries for next non-empty slot.
;; rdi = iterator
;; ============================================================================
DEF_FUNC_BARE set_iter_next
    mov rax, [rdi + PyDictIterObject.it_dict]      ; set
    mov rcx, [rdi + PyDictIterObject.it_index]      ; current index
    mov rdx, [rax + PyDictObject.capacity]          ; capacity
    mov rsi, [rax + PyDictObject.entries]            ; entries ptr

.si_scan:
    cmp rcx, rdx
    jge .si_exhausted

    ; Check if entry at index has a key
    imul rax, rcx, SET_ENTRY_SIZE
    add rax, rsi
    mov r8, [rax + SET_ENTRY_KEY]
    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .si_skip
    ; Skip tombstones
    cmp qword [rax + SET_ENTRY_KEY_TAG], SET_TOMBSTONE
    je .si_skip

    ; Found a valid entry -- return the key with tag
    inc rcx
    mov [rdi + PyDictIterObject.it_index], rcx
    mov rdx, [rax + SET_ENTRY_KEY_TAG]  ; key tag
    mov rax, r8
    INCREF_VAL rax, rdx
    ret

.si_skip:
    inc rcx
    jmp .si_scan

.si_exhausted:
    mov [rdi + PyDictIterObject.it_index], rcx
    RET_NULL
    ret
END_FUNC set_iter_next

;; ============================================================================
;; set_iter_dealloc(PyObject *self)
;; ============================================================================
DEF_FUNC_LOCAL set_iter_dealloc
    push rbx
    mov rbx, rdi

    ; DECREF the set
    mov rdi, [rbx + PyDictIterObject.it_dict]
    call obj_decref

    ; Free self
    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC set_iter_dealloc

;; ============================================================================
;; set_iter_self(PyObject *self) -> self with INCREF
;; ============================================================================
set_iter_self:
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret
END_FUNC set_iter_self

;; ============================================================================
;; frozenset_type_call(self, args, nargs) -> frozenset
;; Same as set_type_call but creates frozenset (reuses set_new, sets ob_type)
;; rdi = self (frozenset_type), rsi = args (16-byte fat slots), rdx = nargs
;; ============================================================================
global frozenset_type_call
FTC_FRAME equ 8
DEF_FUNC frozenset_type_call, FTC_FRAME
    push rbx
    push r12

    ; nargs can be 0 or 1
    cmp rdx, 0
    je .ftc_empty
    cmp rdx, 1
    jne .ftc_error

    ; frozenset(iterable): create set, iterate and add, then set type
    mov r12, [rsi]          ; iterable payload
    mov rcx, [rsi + 8]     ; iterable tag
    cmp ecx, TAG_PTR
    jne .ftc_not_iterable

    call set_new
    mov rbx, rax

    ; Get iterator
    mov rdi, r12
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz .ftc_not_iterable_decref
    call rax
    mov r12, rax

.ftc_iter_loop:
    mov rdi, r12
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    test edx, edx
    jz .ftc_iter_done

    mov rdi, rbx
    mov rsi, rax
    push rax
    push rdx
    push rdx
    call set_add
    add rsp, 8
    pop rsi
    pop rdi
    DECREF_VAL rdi, rsi
    jmp .ftc_iter_loop

.ftc_iter_done:
    mov rdi, r12
    call obj_decref

    ; Set type to frozenset_type
    lea rax, [rel frozenset_type]
    mov [rbx + PyObject.ob_type], rax
    mov rax, rbx
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.ftc_empty:
    call set_new
    lea rcx, [rel frozenset_type]
    mov [rax + PyObject.ob_type], rcx
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.ftc_not_iterable_decref:
    mov rdi, rbx
    call obj_decref
.ftc_not_iterable:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "frozenset() argument is not iterable"
    call raise_exception
.ftc_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "frozenset() takes at most 1 argument"
    call raise_exception
END_FUNC frozenset_type_call


;; ============================================================================
;; Set number method wrappers (nb_* convention -> set_method_* convention)
;; nb_* calling convention: rdi=left, rsi=right, rdx=ltag, rcx=rtag
;; set_method calling convention: rdi=args_array, rsi=nargs
;; ============================================================================

extern set_method_union
extern set_method_intersection
extern set_method_difference
extern set_method_symmetric_difference

SNB_FRAME equ 32

;; set_nb_or(left, right, ltag, rtag) -> new set (union)
DEF_FUNC set_nb_or, SNB_FRAME
    mov [rbp - 32], rdi         ; args[0].payload = left
    mov [rbp - 24], rdx         ; args[0].tag = ltag
    mov [rbp - 16], rsi         ; args[1].payload = right
    mov [rbp - 8], rcx          ; args[1].tag = rtag
    lea rdi, [rbp - 32]
    mov esi, 2
    call set_method_union
    leave
    ret
END_FUNC set_nb_or

;; set_nb_and(left, right, ltag, rtag) -> new set (intersection)
DEF_FUNC set_nb_and, SNB_FRAME
    mov [rbp - 32], rdi
    mov [rbp - 24], rdx
    mov [rbp - 16], rsi
    mov [rbp - 8], rcx
    lea rdi, [rbp - 32]
    mov esi, 2
    call set_method_intersection
    leave
    ret
END_FUNC set_nb_and

;; set_nb_sub(left, right, ltag, rtag) -> new set (difference)
DEF_FUNC set_nb_sub, SNB_FRAME
    mov [rbp - 32], rdi
    mov [rbp - 24], rdx
    mov [rbp - 16], rsi
    mov [rbp - 8], rcx
    lea rdi, [rbp - 32]
    mov esi, 2
    call set_method_difference
    leave
    ret
END_FUNC set_nb_sub

;; set_nb_xor(left, right, ltag, rtag) -> new set (symmetric_difference)
DEF_FUNC set_nb_xor, SNB_FRAME
    mov [rbp - 32], rdi
    mov [rbp - 24], rdx
    mov [rbp - 16], rsi
    mov [rbp - 8], rcx
    lea rdi, [rbp - 32]
    mov esi, 2
    call set_method_symmetric_difference
    leave
    ret
END_FUNC set_nb_xor


;; ============================================================================
;; Data section
;; ============================================================================
section .data

; set_repr_str removed - repr now in src/repr.asm
set_iter_name: db "set_iterator", 0

set_name_str: db "set", 0
frozenset_name_str: db "frozenset", 0

; Set number methods (for |, &, -, ^ operators)
align 8
set_number_methods:
    dq 0                        ; nb_add          +0
    dq set_nb_sub               ; nb_subtract     +8  (set difference -)
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
    dq set_nb_and               ; nb_and          +104 (set intersection &)
    dq set_nb_xor               ; nb_xor          +112 (set symmetric_difference ^)
    dq set_nb_or                ; nb_or           +120 (set union |)
    dq 0                        ; nb_int          +128
    dq 0                        ; nb_float        +136
    dq 0                        ; nb_floor_divide +144
    dq 0                        ; nb_true_divide  +152
    dq 0                        ; nb_index        +160
    dq 0                        ; nb_iadd         +168
    dq 0                        ; nb_isub         +176
    dq 0                        ; nb_imul         +184
    dq 0                        ; nb_irem         +192
    dq 0                        ; nb_ipow         +200
    dq 0                        ; nb_ilshift      +208
    dq 0                        ; nb_irshift      +216
    dq 0                        ; nb_iand         +224
    dq 0                        ; nb_ixor         +232
    dq 0                        ; nb_ior          +240
    dq 0                        ; nb_ifloor_divide +248
    dq 0                        ; nb_itrue_divide +256

; Set sequence methods (for sq_contains -> "in" operator, and sq_length -> len())
align 8
global set_seq_methods
set_seq_methods:
    dq set_len                  ; sq_length       +0
    dq 0                        ; sq_concat       +8
    dq 0                        ; sq_repeat       +16
    dq 0                        ; sq_item          +24
    dq 0                        ; sq_ass_item      +32
    dq set_contains_sq          ; sq_contains      +40
    dq 0                        ; sq_inplace_concat +48
    dq 0                        ; sq_inplace_repeat +56

; Set type object
align 8
global set_type
set_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq set_name_str             ; tp_name
    dq PyDictObject_size        ; tp_basicsize (reuse dict layout)
    dq set_dealloc              ; tp_dealloc
    dq set_repr                 ; tp_repr
    dq set_repr                 ; tp_str
    extern hash_not_implemented
    dq hash_not_implemented     ; tp_hash (raises TypeError)
    dq set_type_call            ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq set_richcompare          ; tp_richcompare
    dq set_tp_iter              ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq set_number_methods       ; tp_as_number
    dq set_seq_methods          ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC                        ; tp_flags
    dq 0                        ; tp_bases
    dq set_traverse                        ; tp_traverse
    dq set_clear_gc                        ; tp_clear

; Frozenset type object
align 8
global frozenset_type
frozenset_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq frozenset_name_str       ; tp_name
    dq PyDictObject_size        ; tp_basicsize (reuse dict layout)
    dq set_dealloc              ; tp_dealloc (same as set)
    dq set_repr                 ; tp_repr (TODO: frozenset({...}) format)
    dq set_repr                 ; tp_str
    dq 0                        ; tp_hash (TODO: implement)
    dq frozenset_type_call      ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq set_richcompare          ; tp_richcompare
    dq set_tp_iter              ; tp_iter (reuse set iter)
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq set_number_methods       ; tp_as_number
    dq set_seq_methods          ; tp_as_sequence (reuse set methods)
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC                        ; tp_flags
    dq 0                        ; tp_bases
    dq set_traverse                        ; tp_traverse
    dq set_clear_gc                        ; tp_clear

; Set iterator type
align 8
global set_iter_type
set_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq set_iter_name            ; tp_name
    dq PyDictIterObject_size    ; tp_basicsize
    dq set_iter_dealloc         ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq set_iter_self            ; tp_iter (return self)
    dq set_iter_next            ; tp_iternext
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
