; repr.asm - Container repr implementations (list, tuple, dict, set)
;
; Uses a heap buffer that grows as needed. Each repr function:
; 1. Allocates initial buffer
; 2. Appends opening bracket
; 3. For each element, calls obj_repr and appends result
; 4. Appends closing bracket
; 5. Converts buffer to PyStrObject

%include "macros.inc"
%include "object.inc"
%include "types.inc"


; Set entry layout (must match set.asm)
SET_ENTRY_HASH    equ 0
SET_ENTRY_KEY     equ 8
SET_ENTRY_KEY_TAG equ 16
SET_ENTRY_SIZE    equ 24
SET_TOMBSTONE     equ 0xDEAD

extern ap_malloc
extern ap_free
extern ap_realloc
extern obj_repr
extern obj_decref
extern str_from_cstr_heap
extern str_type
extern str_repr
extern fat_to_obj

; Recursion detection for container repr
; Simple fixed-size stack of object pointers currently being repr'd.
section .data
align 8
repr_depth: dq 0                  ; current depth (number of entries)
repr_stack: times 64 dq 0         ; up to 64 nested containers

section .text

; Check if ptr is in repr_stack. Returns 1 in eax if found, 0 if not.
; Does NOT clobber rdi.
repr_check_active:
    mov rcx, [rel repr_depth]
    test rcx, rcx
    jz .rca_not_found
    lea rax, [rel repr_stack]
.rca_loop:
    dec rcx
    cmp [rax + rcx*8], rdi
    je .rca_found
    test rcx, rcx
    jnz .rca_loop
.rca_not_found:
    xor eax, eax
    ret
.rca_found:
    mov eax, 1
    ret

; Push ptr onto repr_stack. Raises RecursionError if too deep.
repr_push:
    mov rax, [rel repr_depth]
    cmp rax, 64
    jge .rp_overflow
    lea rcx, [rel repr_stack]
    mov [rcx + rax*8], rdi
    inc qword [rel repr_depth]
    ret
.rp_overflow:
    extern exc_RecursionError_type
    extern raise_exception
    lea rdi, [rel exc_RecursionError_type]
    CSTRING rsi, "maximum recursion depth exceeded while getting the repr of an object"
    call raise_exception

; Pop from repr_stack
repr_pop:
    dec qword [rel repr_depth]
    ret

; Internal buffer struct (on stack):
;   [rbp-8]  = buf ptr
;   [rbp-16] = buf used (length of content)
;   [rbp-24] = buf capacity

; buf_ensure_space(needed)
; Ensures buf has at least 'needed' more bytes available.
; Uses [rbp-8], [rbp-16], [rbp-24]
; Clobbers rdi, rsi, rax
%macro BUF_ENSURE 1
    mov rax, [rbp-16]          ; used
    add rax, %1                ; used + needed
    inc rax                    ; +1 for NUL
    cmp rax, [rbp-24]          ; compare with capacity
    jbe %%ok
    ; Grow: new_cap = max(cap*2, used+needed+1)
    mov rdi, [rbp-24]
    shl rdi, 1                 ; cap * 2
    cmp rdi, rax
    cmovb rdi, rax             ; max(cap*2, needed)
    mov [rbp-24], rdi          ; save new capacity
    mov rsi, rdi               ; new size
    mov rdi, [rbp-8]           ; old ptr
    call ap_realloc
    mov [rbp-8], rax           ; save new ptr
%%ok:
%endmacro

; Append a single byte to buffer
%macro BUF_BYTE 1
    mov rax, [rbp-8]
    mov rcx, [rbp-16]
    mov byte [rax + rcx], %1
    inc qword [rbp-16]
%endmacro

;; ============================================================================
;; list_repr(PyListObject *self) -> PyStrObject*
;; Returns string like "[1, 2, 3]"
;; ============================================================================
DEF_FUNC list_repr, 24                ; buf ptr, used, capacity
    push rbx                   ; self
    push r12                   ; index
    push r13                   ; count

    mov rbx, rdi               ; rbx = list

    ; Recursion check: if already repr'ing this list, return "[...]"
    mov rdi, rbx
    call repr_check_active
    test eax, eax
    jnz .lr_recursive

    ; Push onto repr stack
    mov rdi, rbx
    call repr_push

    ; Get count
    mov r13, [rbx + PyListObject.ob_size]

    ; Allocate initial buffer (256 bytes)
    mov edi, 256
    call ap_malloc
    mov [rbp-8], rax           ; buf ptr
    mov qword [rbp-16], 0      ; used = 0
    mov qword [rbp-24], 256    ; capacity = 256

    ; Append '['
    BUF_BYTE '['

    ; Iterate elements
    xor r12d, r12d             ; index = 0
.lr_loop:
    cmp r12, r13
    jge .lr_done

    ; If not first element, append ", "
    test r12, r12
    jz .lr_no_comma
    BUF_ENSURE 2
    BUF_BYTE ','
    BUF_BYTE ' '
.lr_no_comma:

    ; Get element (payload + tag arrays)
    mov rax, [rbx + PyListObject.ob_item]
    mov rcx, [rbx + PyListObject.ob_item_tags]
    mov rdi, [rax + r12 * 8]      ; payload
    movzx esi, byte [rcx + r12]   ; tag

    ; Call obj_repr(payload, tag)
    call obj_repr
    test rax, rax
    jz .lr_next

    ; Append repr string to buffer
    push rax                   ; save repr str for DECREF
    mov rcx, [rax + PyStrObject.ob_size]
    BUF_ENSURE rcx
    ; Copy repr data into buffer
    mov rsi, [rsp]             ; repr str
    lea rsi, [rsi + PyStrObject.data]
    mov rdi, [rbp-8]
    add rdi, [rbp-16]          ; buf + used
    mov rcx, [rsp]
    mov rcx, [rcx + PyStrObject.ob_size]
    add [rbp-16], rcx          ; used += len
    ; memcpy
    rep movsb

    ; DECREF repr str
    pop rdi
    call obj_decref

.lr_next:
    inc r12
    jmp .lr_loop

.lr_done:
    ; Append ']' and NUL
    BUF_ENSURE 2
    BUF_BYTE ']'
    mov rax, [rbp-8]
    mov rcx, [rbp-16]
    mov byte [rax + rcx], 0    ; NUL terminate

    ; Convert to PyStrObject
    mov rdi, [rbp-8]
    call str_from_cstr_heap
    push rax                   ; save result

    ; Free buffer
    mov rdi, [rbp-8]
    call ap_free

    pop rax                    ; return str
    mov edx, TAG_PTR           ; ap_free clobbers rdx

    ; Pop from repr stack
    call repr_pop

    pop r13
    pop r12
    pop rbx
    leave
    ret

.lr_recursive:
    ; Return "[...]" for recursive reference
    CSTRING rdi, "[...]"
    call str_from_cstr_heap
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_repr

;; ============================================================================
;; tuple_repr(PyTupleObject *self) -> PyStrObject*
;; Returns string like "(1, 2, 3)" or "(1,)" for single-element
;; ============================================================================
DEF_FUNC tuple_repr, 24
    push rbx
    push r12
    push r13

    mov rbx, rdi               ; rbx = tuple

    mov r13, [rbx + PyTupleObject.ob_size]

    ; Allocate buffer
    mov edi, 256
    call ap_malloc
    mov [rbp-8], rax
    mov qword [rbp-16], 0
    mov qword [rbp-24], 256

    BUF_BYTE '('

    xor r12d, r12d
.tr_loop:
    cmp r12, r13
    jge .tr_done

    test r12, r12
    jz .tr_no_comma
    BUF_ENSURE 2
    BUF_BYTE ','
    BUF_BYTE ' '
.tr_no_comma:

    ; Get element at index r12
    mov rax, [rbx + PyTupleObject.ob_item]
    mov rcx, [rbx + PyTupleObject.ob_item_tags]
    mov rdi, [rax + r12 * 8]       ; payload
    movzx esi, byte [rcx + r12]    ; tag
    ; TAG_FLOAT shortcut: call float_repr directly (no heap float object)
    cmp esi, TAG_FLOAT
    je .tr_float_elem
    call fat_to_obj                ; rax = PyObject* (owned ref)
    push rax                       ; save for DECREF later
    mov rdi, rax
    mov esi, TAG_PTR               ; fat_to_obj always returns heap ptr
    call obj_repr
    test rax, rax
    jz .tr_decref_elem

    push rax
    mov rcx, [rax + PyStrObject.ob_size]
    BUF_ENSURE rcx
    mov rsi, [rsp]
    lea rsi, [rsi + PyStrObject.data]
    mov rdi, [rbp-8]
    add rdi, [rbp-16]
    mov rcx, [rsp]
    mov rcx, [rcx + PyStrObject.ob_size]
    add [rbp-16], rcx
    rep movsb

    pop rdi
    call obj_decref                ; DECREF repr string
    jmp .tr_decref_elem

.tr_float_elem:
    ; rdi = raw double bits; call float_repr directly
    extern float_repr
    call float_repr                ; rax = payload, edx = tag
    test edx, edx
    jz .tr_next                    ; skip on error
    push rax
    mov rcx, [rax + PyStrObject.ob_size]
    BUF_ENSURE rcx
    mov rsi, [rsp]
    lea rsi, [rsi + PyStrObject.data]
    mov rdi, [rbp-8]
    add rdi, [rbp-16]
    mov rcx, [rsp]
    mov rcx, [rcx + PyStrObject.ob_size]
    add [rbp-16], rcx
    rep movsb
    pop rdi
    call obj_decref                ; DECREF repr string
    jmp .tr_next

.tr_decref_elem:
    pop rdi                        ; fat_to_obj result
    call obj_decref                ; DECREF fat_to_obj result

.tr_next:
    inc r12
    jmp .tr_loop

.tr_done:
    ; Single-element tuple needs trailing comma
    cmp r13, 1
    jne .tr_no_trailing
    BUF_ENSURE 1
    BUF_BYTE ','
.tr_no_trailing:

    BUF_ENSURE 2
    BUF_BYTE ')'
    mov rax, [rbp-8]
    mov rcx, [rbp-16]
    mov byte [rax + rcx], 0

    mov rdi, [rbp-8]
    call str_from_cstr_heap
    push rax

    mov rdi, [rbp-8]
    call ap_free

    pop rax
    mov edx, TAG_PTR           ; ap_free clobbers rdx
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC tuple_repr

;; ============================================================================
;; dict_repr(PyDictObject *self) -> PyStrObject*
;; Returns string like "{'a': 1, 'b': 2}"
;; Iterates the entries array directly.
;; ============================================================================
DEF_FUNC dict_repr, 24
    push rbx                   ; self
    push r12                   ; entry index
    push r13                   ; capacity
    push r14                   ; items printed count

    mov rbx, rdi

    ; Allocate buffer
    mov edi, 256
    call ap_malloc
    mov [rbp-8], rax
    mov qword [rbp-16], 0
    mov qword [rbp-24], 256

    BUF_BYTE '{'

    mov r13, [rbx + PyDictObject.capacity]
    xor r12d, r12d             ; entry index = 0
    xor r14d, r14d             ; items printed = 0

.dr_loop:
    cmp r12, r13
    jge .dr_done

    ; Check if entry is occupied (key_tag != 0 and != TOMBSTONE)
    mov rax, [rbx + PyDictObject.entries]
    imul rcx, r12, DICT_ENTRY_SIZE
    cmp byte [rax + rcx + DictEntry.key_tag], 0
    je .dr_next_entry
    cmp byte [rax + rcx + DictEntry.key_tag], DICT_TOMBSTONE
    je .dr_next_entry

    ; Print separator if not first
    test r14, r14
    jz .dr_no_comma
    BUF_ENSURE 2
    BUF_BYTE ','
    BUF_BYTE ' '
.dr_no_comma:

    ; Reload entry data (BUF macros clobber rax, rcx, rdi)
    mov rax, [rbx + PyDictObject.entries]
    imul rcx, r12, DICT_ENTRY_SIZE
    mov rdi, [rax + rcx + DictEntry.key]
    movzx esi, byte [rax + rcx + DictEntry.key_tag]
    push r12                   ; save entry index across calls
    call obj_repr
    test rax, rax
    jz .dr_after_key

    push rax
    mov rcx, [rax + PyStrObject.ob_size]
    BUF_ENSURE rcx
    mov rsi, [rsp]
    lea rsi, [rsi + PyStrObject.data]
    mov rdi, [rbp-8]
    add rdi, [rbp-16]
    mov rcx, [rsp]
    mov rcx, [rcx + PyStrObject.ob_size]
    add [rbp-16], rcx
    rep movsb
    pop rdi
    call obj_decref

.dr_after_key:
    ; Append ": "
    BUF_ENSURE 2
    BUF_BYTE ':'
    BUF_BYTE ' '

    ; repr(value)
    pop r12                    ; restore entry index
    mov rax, [rbx + PyDictObject.entries]
    imul rcx, r12, DICT_ENTRY_SIZE
    movzx esi, byte [rax + rcx + DictEntry.value_tag]  ; value tag
    mov rdi, [rax + rcx + DictEntry.value]      ; value payload
    push r12
    call obj_repr
    test rax, rax
    jz .dr_after_val

    push rax
    mov rcx, [rax + PyStrObject.ob_size]
    BUF_ENSURE rcx
    mov rsi, [rsp]
    lea rsi, [rsi + PyStrObject.data]
    mov rdi, [rbp-8]
    add rdi, [rbp-16]
    mov rcx, [rsp]
    mov rcx, [rcx + PyStrObject.ob_size]
    add [rbp-16], rcx
    rep movsb
    pop rdi
    call obj_decref

.dr_after_val:
    pop r12                    ; restore entry index
    inc r14                    ; items printed++

.dr_next_entry:
    inc r12
    jmp .dr_loop

.dr_done:
    BUF_ENSURE 2
    BUF_BYTE '}'
    mov rax, [rbp-8]
    mov rcx, [rbp-16]
    mov byte [rax + rcx], 0

    mov rdi, [rbp-8]
    call str_from_cstr_heap
    push rax

    mov rdi, [rbp-8]
    call ap_free

    pop rax
    mov edx, TAG_PTR           ; ap_free clobbers rdx
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_repr

;; ============================================================================
;; set_repr(PySetObject *self) -> PyStrObject*
;; Returns string like "{1, 2, 3}" or "set()" for empty
;; ============================================================================
DEF_FUNC set_repr, 24
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi

    ; Check empty set
    cmp qword [rbx + PyDictObject.ob_size], 0
    jne .sr_notempty
    lea rdi, [rel set_repr_empty_str]
    call str_from_cstr_heap
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sr_notempty:
    mov edi, 256
    call ap_malloc
    mov [rbp-8], rax
    mov qword [rbp-16], 0
    mov qword [rbp-24], 256

    BUF_BYTE '{'

    mov r13, [rbx + PyDictObject.capacity]
    xor r12d, r12d
    xor r14d, r14d

.sr_loop:
    cmp r12, r13
    jge .sr_done

    ; SetEntry is SET_ENTRY_SIZE bytes: hash(8) + key(8) + key_tag(8)
    mov rax, [rbx + PyDictObject.entries]
    imul rcx, r12, SET_ENTRY_SIZE
    cmp qword [rax + rcx + SET_ENTRY_KEY_TAG], 0              ; empty
    je .sr_next
    cmp qword [rax + rcx + SET_ENTRY_KEY_TAG], SET_TOMBSTONE  ; deleted
    je .sr_next
    mov rdi, [rax + rcx + SET_ENTRY_KEY]                      ; key payload

    ; Print separator if not first
    test r14, r14
    jz .sr_no_comma
    BUF_ENSURE 2
    BUF_BYTE ','
    BUF_BYTE ' '
.sr_no_comma:

    ; Reload entry data (BUF macros may clobber rdi, esi)
    mov rax, [rbx + PyDictObject.entries]
    imul rcx, r12, 24
    mov rdi, [rax + rcx + 8]     ; key
    mov rsi, [rax + rcx + 16]    ; key_tag (full 64-bit)
    push r12
    call obj_repr
    test rax, rax
    jz .sr_after_elem

    push rax
    mov rcx, [rax + PyStrObject.ob_size]
    BUF_ENSURE rcx
    mov rsi, [rsp]
    lea rsi, [rsi + PyStrObject.data]
    mov rdi, [rbp-8]
    add rdi, [rbp-16]
    mov rcx, [rsp]
    mov rcx, [rcx + PyStrObject.ob_size]
    add [rbp-16], rcx
    rep movsb
    pop rdi
    call obj_decref

.sr_after_elem:
    pop r12
    inc r14

.sr_next:
    inc r12
    jmp .sr_loop

.sr_done:
    BUF_ENSURE 2
    BUF_BYTE '}'
    mov rax, [rbp-8]
    mov rcx, [rbp-16]
    mov byte [rax + rcx], 0

    mov rdi, [rbp-8]
    call str_from_cstr_heap
    push rax

    mov rdi, [rbp-8]
    call ap_free

    pop rax
    mov edx, TAG_PTR           ; ap_free clobbers rdx
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_repr

section .rodata
set_repr_empty_str: db "set()", 0
