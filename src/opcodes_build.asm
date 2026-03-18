; opcodes_build.asm - Opcode handlers for subscript, build, and iteration opcodes
;
; Register convention (callee-saved, preserved across handlers):
;   rbx = bytecode instruction pointer (current position in co_code[])
;   r12 = current frame pointer (PyFrame*)
;   r13 = value stack payload top pointer
;   r14 = locals_tag_base pointer (frame's tag sidecar for localsplus[])
;   r15 = value stack tag top pointer
;
; ecx = opcode argument on entry (set by eval_dispatch)
; rbx has already been advanced past the 2-byte instruction word.

%include "macros.inc"
%include "object.inc"
%include "types.inc"
%include "opcodes.inc"
%include "frame.inc"

section .text

extern eval_dispatch
extern eval_saved_rbx
extern eval_saved_r13
extern eval_saved_r15
extern eval_co_consts
extern opcode_table
extern obj_dealloc
extern obj_decref
extern obj_is_true
extern fatal_error
extern raise_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern int_to_i64
extern tuple_new
extern list_new
extern list_append
extern dict_new
extern dict_set
extern slice_new
extern slice_type
extern slice_indices
extern none_singleton
extern obj_incref
extern dict_get
extern range_iter_type
extern list_iter_type

;; Stack/frame layout constants for tag-aware handlers.
;; Push-based: "tags behind payloads" — payload offsets match old code.
;; When result is pushed on top, add 8 to all offsets.

; op_binary_subscr: 2-operand push layout [rsp+...]
BSUB_KEY   equ 0     ; key payload (pushed last)
BSUB_OBJ   equ 8     ; obj payload
BSUB_KTAG  equ 16    ; key tag
BSUB_OTAG  equ 24    ; obj tag
BSUB_SIZE  equ 32

; op_store_subscr: 3-operand push layout [rsp+...]
SSUB_VAL   equ 0     ; value payload (pushed last)
SSUB_KEY   equ 8     ; key payload
SSUB_OBJ   equ 16    ; obj payload
SSUB_KTAG  equ 24    ; key tag
SSUB_OTAG  equ 32    ; obj tag
SSUB_VTAG  equ 40    ; value tag (pushed first)
SSUB_SIZE  equ 48

; op_build_slice 2-arg: [rsp+...]
BSL2_STOP  equ 0     ; stop payload
BSL2_START equ 8     ; start payload
BSL2_PTAG  equ 16    ; stop tag
BSL2_STAG  equ 24    ; start tag
BSL2_SIZE  equ 32

; op_build_slice 3-arg: [rsp+...]
BSL3_STEP  equ 0     ; step payload
BSL3_STOP  equ 8     ; stop payload
BSL3_START equ 16    ; start payload
BSL3_EPTAG equ 24    ; step tag
BSL3_PTAG  equ 32    ; stop tag
BSL3_STAG  equ 40    ; start tag
BSL3_SIZE  equ 48

; op_binary_slice: rbp-frame layout [rbp - ...]
BSLC_START equ 8
BSLC_STOP  equ 16
BSLC_OBJ   equ 24
BSLC_SLICE equ 32
BSLC_STAG  equ 40    ; start tag
BSLC_PTAG  equ 48    ; stop tag
BSLC_OTAG  equ 56    ; obj tag
BSLC_FRAME equ 56

; op_store_slice: rbp-frame layout [rbp - ...]
SSLC_START equ 8
SSLC_STOP  equ 16
SSLC_OBJ   equ 24
SSLC_VAL   equ 32
SSLC_SLICE equ 40
SSLC_STAG  equ 48    ; start tag
SSLC_PTAG  equ 56    ; stop tag
SSLC_OTAG  equ 64    ; obj tag
SSLC_VTAG  equ 72    ; value tag
SSLC_FRAME equ 72

; op_map_add: 2-operand push layout [rsp+...]
MA_VAL   equ 0     ; value (TOS, pushed last)
MA_KEY   equ 8     ; key (TOS1)
MA_VTAG  equ 16    ; value tag
MA_KTAG  equ 24    ; key tag
MA_SIZE  equ 32

; op_contains_op: push layout with invert at bottom [rsp+...]
CN_RIGHT equ 0     ; container payload
CN_LEFT  equ 8     ; value payload
CN_RTAG  equ 16    ; container tag
CN_LTAG  equ 24    ; value tag
CN_INV   equ 32    ; invert flag
CN_SIZE  equ 40

;; ============================================================================
;; op_binary_subscr - obj[key]
;;
;; Pop key, pop obj, call mp_subscript or sq_item, push result.
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_binary_subscr
    VPOP_VAL rsi, r8            ; rsi = key, r8 = key tag
    VPOP_VAL rdi, r9            ; rdi = obj, r9 = obj tag

    ; Tags behind payloads: intermediate [rsp] refs unchanged
    push r9                    ; save obj tag (deepest)
    push r8                    ; save key tag
    push rdi                   ; save obj
    push rsi                   ; save key

    ; Non-pointer tags can't be subscripted (SmallInt, Float, None, Bool)
    cmp r9d, TAG_PTR
    jne .subscr_error
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .try_sequence
    mov rax, [rax + PyMappingMethods.mp_subscript]
    test rax, rax
    jz .try_sequence

    ; Call mp_subscript(obj, key, key_tag)
    ; rdi = obj, rsi = key (already set)
    mov rdx, r8                ; rdx = key tag
    call rax
    jmp .subscr_done

.try_sequence:
    ; Try sq_item (need to convert key to int64)
    mov rdi, [rsp + 8]        ; reload obj
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .no_subscript
    mov rcx, [rax + PySequenceMethods.sq_item]
    test rcx, rcx
    jz .no_subscript

    ; Convert key to int64
    cmp qword [rsp + 16], TAG_SMALLINT   ; key tag
    je .seq_key_smallint
    mov rdi, [rsp]             ; key (heap object)
    mov rdx, [rsp + 16]       ; key tag
    call int_to_i64
    mov rsi, rax               ; rsi = int64 index
    jmp .seq_key_ready
.seq_key_smallint:
    mov rsi, [rsp]             ; key payload IS the int64 index
.seq_key_ready:

    mov rdi, [rsp + 8]        ; reload obj
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    mov rax, [rax + PySequenceMethods.sq_item]
    call rax
    jmp .subscr_done

.no_subscript:
    ; Try __class_getitem__ on type objects FIRST (for MyClass[args] syntax)
    mov rdi, [rsp+8]              ; obj
    cmp qword [rsp+24], TAG_SMALLINT  ; obj tag
    je .try_getitem_dunder
    mov rax, [rdi + PyObject.ob_type]
    extern user_type_metatype
    extern type_type
    lea rcx, [rel user_type_metatype]
    cmp rax, rcx
    je .try_class_getitem
    lea rcx, [rel type_type]
    cmp rax, rcx
    je .try_class_getitem

.try_getitem_dunder:
    ; Try __getitem__ on heaptype
    mov rdi, [rsp+8]          ; obj
    cmp qword [rsp+24], TAG_PTR
    jne .subscr_error
    mov rax, [rdi + PyObject.ob_type]
    mov rdx, [rax + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .subscr_error
    extern dunder_getitem
    extern dunder_call_2
    mov rsi, [rsp]            ; key = other
    lea rdx, [rel dunder_getitem]
    mov ecx, [rsp + 16]      ; key tag = other_tag
    call dunder_call_2
    test edx, edx
    jnz .subscr_done
    jmp .subscr_error

.try_class_getitem:
    ; obj is a type — look up __class_getitem__ in its tp_dict (walk MRO)
    ; Stack: [rsp]=key, [rsp+8]=obj
    extern dunder_lookup
    extern classmethod_type
    mov rdi, [rsp+8]              ; obj (the type itself)
    CSTRING rsi, "__class_getitem__"
    call dunder_lookup
    test edx, edx
    jz .subscr_error

    ; rax = __class_getitem__ attr (borrowed ref)
    ; Check if it's a classmethod wrapper — unwrap if so
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel classmethod_type]
    cmp rcx, rdx
    jne .cgi_not_classmethod

    ; Unwrap classmethod: get cm_callable, call with (cls, key)
    mov rax, [rax + PyClassMethodObject.cm_callable]

.cgi_not_classmethod:
    ; Call func(cls, key): tp_call(func, &[cls, key], 2)
    mov rdi, rax
    mov rcx, [rdi + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .subscr_error

    ; Build fat args: [cls, key] — 2×16 = 32 bytes
    sub rsp, 32
    mov rax, [rsp + 32 + BSUB_OBJ]  ; obj (type/cls)
    mov [rsp], rax                    ; args[0] payload = cls
    mov qword [rsp + 8], TAG_PTR     ; args[0] tag (type is always heap)
    mov rax, [rsp + 32 + BSUB_KEY]  ; key
    mov [rsp + 16], rax              ; args[1] payload = key
    mov rax, [rsp + 32 + BSUB_KTAG] ; key tag
    mov [rsp + 24], rax              ; args[1] tag
    mov rsi, rsp                     ; args ptr
    mov edx, 2                       ; nargs = 2
    call rcx
    add rsp, 32                      ; pop fat args
    jmp .subscr_done

.subscr_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "object is not subscriptable"
    call raise_exception

.subscr_done:
    ; rax = result payload, rdx = result tag
    SAVE_FAT_RESULT            ; save (rax,rdx) — shifts rsp refs by +16
    mov rdi, [rsp + 16 + BSUB_KEY]
    mov rsi, [rsp + 16 + BSUB_KTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rsp + 16 + BSUB_OBJ]
    mov rsi, [rsp + 16 + BSUB_OTAG]
    DECREF_VAL rdi, rsi
    RESTORE_FAT_RESULT
    add rsp, BSUB_SIZE

    VPUSH_VAL rax, rdx

    ; Skip 1 CACHE entry = 2 bytes
    add rbx, 2
    DISPATCH
END_FUNC op_binary_subscr

;; ============================================================================
;; op_store_subscr - obj[key] = value
;;
;; Stack: value, obj, key (TOS)
;; Pop key, pop obj, pop value.
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_store_subscr
    VPOP_VAL rsi, r8            ; key + tag
    VPOP_VAL rdi, r9            ; obj + tag
    VPOP_VAL rdx, r10           ; value + tag

    ; Tags behind payloads: intermediate [rsp] refs unchanged
    push r10                   ; save value tag (deepest)
    push r9                    ; save obj tag
    push r8                    ; save key tag
    push rdi                   ; save obj
    push rsi                   ; save key
    push rdx                   ; save value

    ; Non-pointer tags can't be subscript-assigned
    cmp r9d, TAG_PTR
    jne .store_type_error

    ; Try mp_ass_subscript first
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .store_try_seq
    mov rax, [rax + PyMappingMethods.mp_ass_subscript]
    test rax, rax
    jz .store_try_seq

    ; Call mp_ass_subscript(obj, key, value, key_tag, value_tag)
    ; rdi = obj, rsi = key, rdx = value (already set)
    mov rcx, r8                ; key tag (4th arg)
    ; r8 = value tag (5th arg) — use r10 which holds value tag
    mov r8, r10
    call rax
    jmp .store_done

.store_try_seq:
    ; Try sq_ass_item
    mov rdi, [rsp + 16]       ; obj
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .store_error
    mov rcx, [rax + PySequenceMethods.sq_ass_item]
    test rcx, rcx
    jz .store_error

    ; Convert key to int64
    mov rdi, [rsp + 8]        ; key
    mov rdx, [rsp + SSUB_KTAG] ; key tag
    call int_to_i64
    mov rsi, rax               ; index

    mov rdi, [rsp + 16]       ; obj
    mov rdx, [rsp]             ; value
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    mov rax, [rax + PySequenceMethods.sq_ass_item]
    call rax
    jmp .store_done

.store_error:
    ; Try __setitem__ on heaptype
    mov rdi, [rsp+16]         ; obj
    mov rax, [rdi + PyObject.ob_type]
    mov rdx, [rax + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .store_type_error

    ; Look up __setitem__
    extern dunder_setitem
    extern dunder_lookup
    mov rdi, [rsp+16]         ; obj
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel dunder_setitem]
    call dunder_lookup
    test edx, edx
    jz .store_type_error

    ; Call __setitem__(self, key, value) via tp_call
    mov rcx, rax              ; func
    mov rax, [rcx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .store_type_error

    ; Build fat args array: [self, key, value] — 3×16 = 48 bytes
    sub rsp, 48
    mov r8, [rsp + 48 + SSUB_OBJ]   ; self payload
    mov [rsp], r8
    mov qword [rsp + 8], TAG_PTR    ; self tag (heap instance)
    mov r8, [rsp + 48 + SSUB_KEY]   ; key payload
    mov [rsp + 16], r8
    mov r8, [rsp + 48 + SSUB_KTAG]  ; key tag
    mov [rsp + 24], r8
    mov r8, [rsp + 48 + SSUB_VAL]   ; value payload
    mov [rsp + 32], r8
    mov r8, [rsp + 48 + SSUB_VTAG]  ; value tag
    mov [rsp + 40], r8
    mov rdi, rcx              ; callable
    mov rsi, rsp              ; args ptr
    mov edx, 3                ; nargs
    call rax
    add rsp, 48               ; pop fat args array
    ; rax = result (discard — __setitem__ returns None)
    jmp .store_done

.store_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "object does not support item assignment"
    call raise_exception

.store_done:
    mov rdi, [rsp + SSUB_VAL]
    mov rsi, [rsp + SSUB_VTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rsp + SSUB_KEY]
    mov rsi, [rsp + SSUB_KTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rsp + SSUB_OBJ]
    mov rsi, [rsp + SSUB_OTAG]
    DECREF_VAL rdi, rsi
    add rsp, SSUB_SIZE

    ; Skip 1 CACHE entry = 2 bytes
    add rbx, 2
    DISPATCH
END_FUNC op_store_subscr

;; ============================================================================
;; op_build_tuple - Create tuple from TOS items
;;
;; ecx = count (number of items to pop)
;; Items are on stack bottom-to-top: first item deepest.
;; ============================================================================
DEF_FUNC op_build_tuple, 16
    ; [rbp-8] = count

    mov [rbp-8], rcx           ; save count

    ; Allocate tuple
    mov rdi, rcx
    call tuple_new
    mov [rbp-16], rax          ; save tuple

    ; Fill items: tuple[i] = stack[-(count-i)]
    ; Items on stack: [r13 - count*8] = first, [r13 - 8] = last
    mov rcx, [rbp-8]          ; count
    mov rax, [rbp-16]         ; tuple
    xor edx, edx              ; index
    test rcx, rcx
    jz .build_tuple_done

    ; Calculate base of items on value stack (payload + tag arrays)
    mov rdi, rcx
    shl rdi, 3                 ; count * 8 (payloads)
    sub r13, rdi               ; pop all payloads at once
    sub r15, rcx               ; pop all tags at once

.build_tuple_fill:
    mov rax, rdx
    shl rax, 3                 ; index * 8
    mov rsi, [r13 + rax]      ; item payload from stack
    movzx edi, byte [r15 + rdx] ; item tag from stack
    mov rax, [rbp-16]
    mov r8, [rax + PyTupleObject.ob_item]       ; payloads
    mov r9, [rax + PyTupleObject.ob_item_tags]  ; tags
    mov [r8 + rdx*8], rsi                        ; payload
    mov byte [r9 + rdx], dil                     ; tag
    inc rdx
    cmp rdx, [rbp-8]
    jb .build_tuple_fill

.build_tuple_done:
    mov rax, [rbp-16]
    VPUSH_PTR rax
    leave
    DISPATCH
END_FUNC op_build_tuple

;; ============================================================================
;; op_build_list - Create list from TOS items
;;
;; ecx = count
;; ============================================================================
DEF_FUNC op_build_list, 16

    mov [rbp-8], rcx           ; save count

    ; Allocate list with capacity
    mov rdi, rcx
    test rdi, rdi
    jnz .bl_has_cap
    mov rdi, 4                 ; minimum capacity
.bl_has_cap:
    call list_new
    mov [rbp-16], rax          ; save list

    ; Pop items and append
    mov rcx, [rbp-8]
    test rcx, rcx
    jz .build_list_done

    ; Calculate base (payload + tag arrays)
    mov rdi, rcx
    shl rdi, 3
    sub r13, rdi               ; pop all payloads
    sub r15, rcx               ; pop all tags

    xor edx, edx
.build_list_fill:
    cmp rdx, [rbp-8]
    jge .build_list_done
    push rdx
    mov rdi, [rbp-16]         ; list
    mov rax, rdx
    shl rax, 3                ; index * 8
    mov rsi, [r13 + rax]      ; item payload (ownership transfers, no extra INCREF)
    movzx edx, byte [r15 + rdx] ; item tag
    call list_append
    pop rdx
    inc rdx
    jmp .build_list_fill

.build_list_done:
    ; list_append does INCREF, but we're transferring ownership from stack
    ; so we need to adjust: items already had a ref from the stack, list_append
    ; adds another. We should DECREF each to compensate.
    ; Actually: stack items have a ref, list_append INCREFs, so now refcount is
    ; one too high. We need to DECREF each.
    mov rcx, [rbp-8]
    test rcx, rcx
    jz .build_list_push
    xor edx, edx
.build_list_fixref:
    cmp rdx, [rbp-8]
    jge .build_list_push
    mov rax, rdx
    shl rax, 3                ; index * 8
    mov rdi, [r13 + rax]
    movzx esi, byte [r15 + rdx]  ; tag
    push rdx
    DECREF_VAL rdi, rsi
    pop rdx
    inc rdx
    jmp .build_list_fixref

.build_list_push:
    mov rax, [rbp-16]
    VPUSH_PTR rax
    leave
    DISPATCH
END_FUNC op_build_list

;; ============================================================================
;; op_build_map - Create dict from TOS key/value pairs
;;
;; ecx = count (number of key/value pairs)
;; Stack (bottom to top): key0, val0, key1, val1, ...
;; ============================================================================
DEF_FUNC op_build_map, 16

    mov [rbp-8], rcx           ; save count

    call dict_new
    mov [rbp-16], rax          ; save dict

    ; Total items on stack = count * 2
    mov rcx, [rbp-8]
    shl rcx, 1                 ; count * 2
    test rcx, rcx
    jz .build_map_done

    mov rdi, rcx
    shl rdi, 3                 ; total_items * 8 bytes/slot
    sub r13, rdi               ; pop all payloads
    sub r15, rcx               ; pop all tags

    xor edx, edx              ; pair index
.build_map_fill:
    cmp rdx, [rbp-8]
    jge .build_map_done
    push rdx
    mov rdi, [rbp-16]         ; dict
    mov rax, rdx
    shl rax, 4                 ; pair_index * 16 (2 payload slots)
    mov rsi, [r13 + rax]      ; key payload
    lea r9, [rdx + rdx]       ; tag base index = pair_index * 2
    movzx r8d, byte [r15 + r9]     ; key tag
    mov rdx, [r13 + rax + 8]       ; value payload
    movzx ecx, byte [r15 + r9 + 1] ; value tag
    call dict_set
    pop rdx
    inc rdx
    jmp .build_map_fill

.build_map_done:
    ; dict_set does INCREF on key+value, so DECREF all stack items
    mov rcx, [rbp-8]
    shl rcx, 1
    test rcx, rcx
    jz .build_map_push
    xor edx, edx
.build_map_fixref:
    cmp rdx, rcx
    jge .build_map_push
    mov rax, rdx
    shl rax, 3                ; index * 8
    mov rdi, [r13 + rax]
    movzx esi, byte [r15 + rdx]  ; tag
    push rdx
    push rcx
    DECREF_VAL rdi, rsi
    pop rcx
    pop rdx
    inc rdx
    jmp .build_map_fixref

.build_map_push:
    mov rax, [rbp-16]
    VPUSH_PTR rax
    leave
    DISPATCH
END_FUNC op_build_map

;; ============================================================================
;; op_build_const_key_map - Build dict from const keys tuple + TOS values
;;
;; ecx = count
;; Stack: val0, val1, ..., valN-1, keys_tuple (TOS)
;; ============================================================================
DEF_FUNC op_build_const_key_map, 32

    mov [rbp-8], rcx           ; count

    ; Pop keys tuple from TOS
    VPOP rax
    mov [rbp-16], rax          ; keys tuple

    call dict_new
    mov [rbp-24], rax          ; dict

    ; Pop values
    mov rcx, [rbp-8]
    test rcx, rcx
    jz .bckm_done

    mov rdi, rcx
    shl rdi, 3                 ; count * 8 bytes/slot
    sub r13, rdi               ; pop all payloads
    sub r15, rcx               ; pop all tags

    xor edx, edx
.bckm_fill:
    cmp rdx, [rbp-8]
    jge .bckm_done
    push rdx
    mov rdi, [rbp-24]         ; dict
    mov rax, [rbp-16]         ; keys tuple
    mov r10, [rax + PyTupleObject.ob_item]       ; payloads
    mov r11, [rax + PyTupleObject.ob_item_tags]  ; tags
    mov rsi, [r10 + rdx*8]                        ; key payload
    movzx r8d, byte [r11 + rdx]                   ; key tag from tuple
    mov r9, rdx
    mov rax, rdx
    shl rax, 3                ; index * 8
    mov rdx, [r13 + rax]      ; value payload
    movzx ecx, byte [r15 + r9]  ; value tag
    call dict_set
    pop rdx
    inc rdx
    jmp .bckm_fill

.bckm_done:
    ; DECREF values from stack
    mov rcx, [rbp-8]
    test rcx, rcx
    jz .bckm_push
    xor edx, edx
.bckm_fixref:
    cmp rdx, rcx
    jge .bckm_decref_keys
    mov rax, rdx
    shl rax, 3                ; index * 8
    mov rdi, [r13 + rax]
    movzx esi, byte [r15 + rdx]  ; tag
    push rdx
    push rcx
    DECREF_VAL rdi, rsi
    pop rcx
    pop rdx
    inc rdx
    jmp .bckm_fixref

.bckm_decref_keys:
    ; DECREF keys tuple
    mov rdi, [rbp-16]
    call obj_decref

.bckm_push:
    mov rax, [rbp-24]
    VPUSH_PTR rax
    leave
    DISPATCH
END_FUNC op_build_const_key_map

;; ============================================================================
;; op_unpack_sequence - Unpack iterable into N items on stack
;;
;; ecx = count
;; Pop TOS (tuple/list/str), push items[count-1], ..., items[0] (reverse order)
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
extern str_new
extern str_type
DEF_FUNC_BARE op_unpack_sequence
    VPOP_VAL rdi, r8           ; rdi = sequence (tuple or list), r8 = tag
    cmp r8d, TAG_PTR
    jne .unpack_type_error

    ; Determine if tuple or list and get item array + size
    push r8                    ; save tag (deeper)
    push rdi                   ; save payload

    mov rax, [rdi + PyObject.ob_type]

    extern tuple_type
    lea rdx, [rel tuple_type]
    cmp rax, rdx
    je .unpack_tuple

    extern list_type
    lea rdx, [rel list_type]
    cmp rax, rdx
    je .unpack_list

    lea rdx, [rel str_type]
    cmp rax, rdx
    je .unpack_str

.unpack_type_error:
    ; Unknown type
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "cannot unpack non-sequence"
    call raise_exception

.unpack_tuple:
    ; Validate count matches size
    cmp rcx, [rdi + PyTupleObject.ob_size]
    jne .unpack_count_error
    ; Items are in payload/tag arrays
    mov rsi, [rdi + PyTupleObject.ob_item]
    mov r8, [rdi + PyTupleObject.ob_item_tags]
    jmp .unpack_fill

.unpack_list:
    ; Validate count matches size
    cmp rcx, [rdi + PyListObject.ob_size]
    jne .unpack_count_error
    ; Items in payload/tag arrays
    mov rsi, [rdi + PyListObject.ob_item]
    mov r8, [rdi + PyListObject.ob_item_tags]

.unpack_fill:
    ; Pre-advance stack by count (ecx)
    mov edx, ecx
    shl edx, 3
    add r13, rdx              ; payload stack += count * 8
    add r15, rcx              ; tag stack += count
    ; r10 = negative offset from pre-advanced pointers, starts at -count
    mov r10, rcx
    neg r10
    mov edx, ecx
    dec edx                    ; edx = source index (count-1 down to 0)
.unpack_fill_loop:
    test edx, edx
    js .unpack_done
    mov eax, edx
    mov rax, [rsi + rax * 8]  ; payload = items[edx]
    movzx r9d, byte [r8 + rdx] ; tag = tags[edx]
    INCREF_VAL rax, r9
    mov [r13 + r10*8], rax
    mov byte [r15 + r10], r9b
    inc r10
    dec edx
    jmp .unpack_fill_loop

.unpack_done:
    ; DECREF the sequence (payload + tag)
    pop rdi                    ; sequence payload
    pop rsi                    ; sequence tag
    DECREF_VAL rdi, rsi

    ; Skip 1 CACHE entry = 2 bytes
    add rbx, 2
    DISPATCH

.unpack_count_error:
    ; Count mismatch: expected ecx items, got different size
    pop rdi                    ; sequence payload
    pop rsi                    ; sequence tag
    DECREF_VAL rdi, rsi
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "not enough values to unpack"
    call raise_exception

.unpack_str:
    ; String unpacking: a, b, c = "xyz"
    ; Validate length matches count
    cmp rcx, [rdi + PyStrObject.ob_size]
    jne .unpack_count_error

    ; Use rbp-frame for the string unpacking loop
    ; Save callee-saved regs
    push rbx                   ; save bytecode IP
    push r12                   ; save frame
    push r14                   ; spare

    mov r12, rcx               ; r12 = count
    mov r14, rdi               ; r14 = string object

    ; Pre-advance stack by count
    mov edx, ecx
    shl edx, 3
    add r13, rdx              ; payload stack += count * 8
    add r15, rcx              ; tag stack += count

    ; Create single-char strings in reverse order (count-1 down to 0)
    mov ebx, ecx
    dec ebx                    ; ebx = source index (count-1)
    mov rcx, r12
    neg rcx                    ; rcx = -count (negative offset)

.unpack_str_loop:
    test ebx, ebx
    js .unpack_str_done

    ; Create single-char string: str_new(&data[ebx], 1)
    lea rdi, [r14 + PyStrObject.data]
    movsxd rax, ebx
    add rdi, rax               ; rdi = &str.data[ebx]
    mov rsi, 1                 ; length = 1
    push rcx                   ; save negative offset
    push rbx                   ; save source index
    call str_new
    pop rbx
    pop rcx
    ; rax = new string (TAG_PTR, refcount=1, ownership transferred to stack)
    mov [r13 + rcx*8], rax
    mov byte [r15 + rcx], TAG_PTR
    inc rcx
    dec ebx
    jmp .unpack_str_loop

.unpack_str_done:
    pop r14
    pop r12
    pop rbx                    ; restore bytecode IP

    ; DECREF the string
    pop rdi                    ; string payload
    pop rsi                    ; string tag
    DECREF_VAL rdi, rsi

    ; Skip 1 CACHE entry = 2 bytes
    add rbx, 2
    DISPATCH
END_FUNC op_unpack_sequence

;; ============================================================================
;; op_get_iter - Get iterator from TOS
;;
;; Pop obj, call tp_iter, push iterator.
;; ============================================================================
DEF_FUNC_BARE op_get_iter
    VPOP_VAL rdi, r8           ; rdi = iterable obj, r8 = tag
    cmp r8d, TAG_PTR
    jne .not_iterable

    push r8                    ; save tag (deeper)
    push rdi                   ; save payload

    ; Get tp_iter from type
    mov rax, [rdi + PyObject.ob_type]
    mov rcx, rax               ; save type
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jnz .have_iter

    ; tp_iter NULL — try __iter__ on heaptype
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .not_iterable
    extern dunder_iter
    lea rsi, [rel dunder_iter]
    extern dunder_call_1
    call dunder_call_1
    test edx, edx
    jnz .have_iter_result
    ; __iter__ not found — try __getitem__ sequence protocol
    mov rdi, [rsp]             ; restore obj
    jmp .try_getitem

.have_iter:
    ; Call tp_iter(obj) -> iterator
    call rax
.have_iter_result:
    push rax                   ; save iterator on machine stack

    ; DECREF the original iterable (tag-aware)
    mov rdi, [rsp + 8]        ; iterable payload
    mov rsi, [rsp + 16]       ; iterable tag
    DECREF_VAL rdi, rsi
    pop rax                    ; restore iterator
    add rsp, 16                ; discard iterable payload + tag

    VPUSH_PTR rax
    DISPATCH

.try_getitem:
    ; rdi = original obj. Check if heaptype has __getitem__
    mov rcx, [rdi + PyObject.ob_type]
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .not_iterable
    push rbp
    mov rbp, rsp
    extern seq_iter_new
    call seq_iter_new          ; creates seq_iter wrapping obj
    leave
    jmp .have_iter_result

.not_iterable:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "object is not iterable"
    call raise_exception
END_FUNC op_get_iter

;; ============================================================================
;; op_for_iter - Advance iterator, or jump if exhausted
;;
;; ecx = jump offset (instruction words) if exhausted
;; TOS = iterator
;; If iterator has next: push value (iterator stays on stack)
;; If exhausted: pop iterator, jump forward by arg
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
align 16
DEF_FUNC_BARE op_for_iter
    push rcx                   ; save jump offset on machine stack

    ; Peek at iterator (don't pop yet)
    VPEEK rdi

    ; Try to specialize (first execution)
    mov rax, [rdi + PyObject.ob_type]
    lea rdx, [rel range_iter_type]
    cmp rax, rdx
    je .fi_specialize_range
    lea rdx, [rel list_iter_type]
    cmp rax, rdx
    je .fi_specialize_list
    jmp .fi_no_specialize

.fi_specialize_range:
    mov byte [rbx - 2], 214    ; rewrite to FOR_ITER_RANGE
    jmp .fi_no_specialize      ; continue with normal execution this time

.fi_specialize_list:
    mov byte [rbx - 2], 213    ; rewrite to FOR_ITER_LIST
    ; fall through to normal execution

.fi_no_specialize:
    ; Call tp_iternext(iterator)
    mov rax, [rdi + PyObject.ob_type]
    mov rcx, rax               ; save type
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jnz .have_iternext

    ; tp_iternext NULL — try __next__ on heaptype
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .exhausted
    extern dunder_next
    lea rsi, [rel dunder_next]
    extern dunder_call_1
    call dunder_call_1
    test edx, edx
    jnz .check_next_result     ; got a value

    ; NULL from __next__ — check for StopIteration
    extern current_exception
    mov rax, [rel current_exception]
    test rax, rax
    jz .exhausted              ; no exception, clean exhaustion

    extern exc_StopIteration_type
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel exc_StopIteration_type]
    cmp rcx, rdx
    jne .exhausted             ; other exception: leave it, propagate later

    ; Clear StopIteration
    mov rdi, rax
    call obj_decref
    mov qword [rel current_exception], 0
    jmp .exhausted

.have_iternext:
    call rax
.check_next_result:
    ; rax = payload, rdx = tag (TAG_NULL if exhausted)

    test edx, edx
    jz .exhausted

    ; Got a value - push it (iterator stays on stack)
    add rsp, 8                 ; discard saved jump offset
    VPUSH_VAL rax, rdx

    ; Skip 1 CACHE entry = 2 bytes
    add rbx, 2
    DISPATCH

.exhausted:
    ; CPython 3.12: FOR_ITER exhausted pops the iterator and jumps by (arg + 1)
    ; instruction words past the CACHE. The +1 skips the END_FOR instruction.
    pop rcx                    ; restore jump offset
    lea rcx, [rcx + 1]        ; arg + 1 (skip END_FOR too)
    add rbx, 2                 ; skip cache first
    lea rbx, [rbx + rcx*2]    ; then jump forward

    ; Now pop and DECREF the iterator (safe: rbx/r13 are callee-saved)
    VPOP_VAL rdi, rsi
    DECREF_VAL rdi, rsi

    DISPATCH
END_FUNC op_for_iter

;; ============================================================================
;; op_end_for - End of for loop cleanup
;;
;; In Python 3.12, END_FOR (opcode 4) pops TOS (the exhausted iterator value).
;; Actually END_FOR pops 2 items in 3.12.
;; ============================================================================
DEF_FUNC_BARE op_end_for
    ; Pop TOS (end-of-iteration sentinel / last value)
    VPOP_VAL rdi, rsi
    DECREF_VAL rdi, rsi
    ; Pop the iterator
    VPOP_VAL rdi, rsi
    DECREF_VAL rdi, rsi
    DISPATCH
END_FUNC op_end_for

;; ============================================================================
;; op_list_append - Append TOS to list at stack position
;;
;; ecx = position (1-based from TOS before the value to append)
;; list is at stack[-(ecx+1)] relative to current TOS
;; Pop TOS (value), append to list.
;; ============================================================================
DEF_FUNC_BARE op_list_append
    ; TOS = value to append
    VPOP_VAL rsi, r8           ; rsi = value, r8 = value tag

    ; list is at stack[-(ecx)] after popping (payload slots)
    neg rcx
    shl rcx, 3                ; -ecx * 8
    mov rdi, [r13 + rcx]      ; rdi = list

    push r8                    ; save value tag (deeper)
    push rsi                   ; save value payload
    mov rdx, r8                ; item tag for list_append
    call list_append
    ; list_append does INCREF, so DECREF to compensate
    pop rdi                    ; value payload
    pop rsi                    ; value tag
    DECREF_VAL rdi, rsi

    DISPATCH
END_FUNC op_list_append

;; ============================================================================
;; op_list_extend - Extend list with iterable
;;
;; ecx = position (list at stack[-(ecx)] after pop)
;; Pop TOS (iterable), extend list.
;; ============================================================================
DEF_FUNC op_list_extend, 32
    ; locals: [rbp-8]=list, [rbp-16]=iterable, [rbp-24]=count, [rbp-32]=items

    ; TOS = iterable
    VPOP_VAL rsi, r8           ; rsi = iterable (tuple or list)
    cmp r8d, TAG_PTR
    jne .extend_type_error
    mov [rbp-16], rsi          ; save iterable

    ; list is at stack[-(ecx)] after popping (payload slots)
    neg rcx
    shl rcx, 3                ; -ecx * 8
    mov rdi, [r13 + rcx]      ; rdi = list
    mov [rbp-8], rdi           ; save list

    ; Get iterable type to extract items
    mov rax, [rsi + PyObject.ob_type]

    extern tuple_type
    lea rdx, [rel tuple_type]
    cmp rax, rdx
    je .extend_tuple

    extern list_type
    lea rdx, [rel list_type]
    cmp rax, rdx
    je .extend_list

    ; Generic iterable: use tp_iter/tp_iternext
    jmp .extend_generic

.extend_tuple:
    mov rcx, [rsi + PyTupleObject.ob_size]
    mov [rbp-24], rcx          ; count
    test rcx, rcx
    jz .extend_done
    xor r8d, r8d               ; index
.extend_tuple_loop:
    mov rdi, [rbp-8]          ; list
    mov rax, [rbp-16]         ; iterable (tuple)
    mov r9, [rax + PyTupleObject.ob_item]
    mov r10, [rax + PyTupleObject.ob_item_tags]
    mov rsi, [r9 + r8 * 8]    ; payload
    movzx edx, byte [r10 + r8] ; tag
    push r8
    call list_append
    pop r8
    inc r8
    cmp r8, [rbp-24]
    jb .extend_tuple_loop
    jmp .extend_done

.extend_list:
    mov rcx, [rsi + PyListObject.ob_size]
    mov rdx, [rsi + PyListObject.ob_item]

    mov [rbp-24], rcx          ; count
    mov [rbp-32], rdx          ; items ptr

    test rcx, rcx
    jz .extend_done
    xor r8d, r8d               ; index
.extend_list_loop:
    mov rdi, [rbp-8]          ; list
    mov rdx, [rbp-32]         ; payloads ptr
    mov rax, [rbp-16]         ; iterable list
    mov r11, [rax + PyListObject.ob_item_tags]
    mov rsi, [rdx + r8 * 8]   ; item payload
    movzx edx, byte [r11 + r8] ; item tag
    push r8
    call list_append
    pop r8
    inc r8
    cmp r8, [rbp-24]          ; count
    jb .extend_list_loop

.extend_generic:
    ; Generic iterable: tp_iter + tp_iternext loop
    mov rsi, [rbp-16]         ; iterable
    mov rax, [rsi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz .extend_type_error
    mov rdi, rsi
    call rax                   ; tp_iter(iterable) → iterator
    test rax, rax
    jz .extend_type_error
    mov [rbp-32], rax          ; save iterator (reusing locals slot)

.extend_generic_loop:
    mov rdi, [rbp-32]         ; iterator
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .extend_generic_done
    mov rdi, [rbp-32]
    call rax                   ; tp_iternext(iter) → (payload, tag)
    test edx, edx
    jz .extend_generic_done    ; StopIteration

    ; Append to list
    push rax
    push rdx
    mov rdi, [rbp-8]          ; list
    mov rsi, rax
    ; edx = tag (already set)
    call list_append
    ; DECREF item (list_append INCREFs)
    pop rsi                    ; tag
    pop rdi                    ; payload
    DECREF_VAL rdi, rsi
    jmp .extend_generic_loop

.extend_generic_done:
    ; DECREF iterator
    mov rdi, [rbp-32]
    call obj_decref

.extend_done:
    ; DECREF iterable
    mov rdi, [rbp-16]
    call obj_decref

    leave
    DISPATCH

.extend_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "list.extend() argument must be iterable"
    call raise_exception
END_FUNC op_list_extend

;; ============================================================================
;; op_is_op - Identity comparison (is / is not)
;;
;; ecx = 0 for 'is', 1 for 'is not'
;; Pop right, pop left, push True/False.
;; ============================================================================
DEF_FUNC_BARE op_is_op
    mov r8d, ecx               ; save invert flag

    VPOP_VAL rsi, r9           ; right
    VPOP_VAL rdi, r10          ; left

    ; Normalize None: (none_singleton, TAG_PTR) → (0, TAG_NONE)
    ; so that inline and pointer None representations compare equal
    extern none_singleton
    lea rcx, [rel none_singleton]
    cmp rsi, rcx
    jne .is_no_norm_right
    xor esi, esi
    mov r9, TAG_NONE
.is_no_norm_right:
    cmp rdi, rcx
    jne .is_no_norm_left
    xor edi, edi
    mov r10, TAG_NONE
.is_no_norm_left:

    ; Compare both payload AND tag (for SmallInt correctness)
    xor eax, eax
    cmp rdi, rsi
    jne .is_cmp_done
    cmp r10, r9
    jne .is_cmp_done
    mov eax, 1
.is_cmp_done:

    ; DECREF both (tag-aware) — save left before DECREF right
    push rax
    push r8
    push r10                   ; save left tag
    push rdi                   ; save left payload
    DECREF_VAL rsi, r9         ; DECREF right (regs live before call)
    pop rdi                    ; restore left payload
    pop rsi                    ; restore left tag
    DECREF_VAL rdi, rsi        ; DECREF left
    pop r8
    pop rax

    ; Invert if 'is not'
    xor eax, r8d

    ; Push bool result
    extern bool_true
    extern bool_false
    test eax, eax
    jz .is_false
    lea rax, [rel bool_true]
    jmp .is_push
.is_false:
    lea rax, [rel bool_false]
.is_push:
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
END_FUNC op_is_op

;; ============================================================================
;; op_contains_op - 'in' / 'not in' test
;;
;; ecx = 0 for 'in', 1 for 'not in'
;; Stack: right (container), left (value)
;; Pop right (container), pop left (value to find).
;; ============================================================================
DEF_FUNC_BARE op_contains_op
    mov r8d, ecx               ; save invert flag

    VPOP_VAL rsi, r9           ; rsi = right (container), r9 = tag
    VPOP_VAL rdi, r10          ; rdi = left (value to find), r10 = tag

    ; Tags behind payloads, invert at bottom
    push r8                    ; save invert (deepest)
    push r10                   ; left tag
    push r9                    ; right tag
    push rdi                   ; save left
    push rsi                   ; save right

    ; Check sq_contains
    cmp r9d, TAG_PTR
    jne .contains_type_error
    mov rax, [rsi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .contains_error
    mov rax, [rax + PySequenceMethods.sq_contains]
    test rax, rax
    jz .contains_error

    ; Call sq_contains(container, value, value_tag) -> 0/1
    mov rdi, [rsp]             ; container
    mov rsi, [rsp + 8]        ; value
    mov rdx, [rsp + CN_LTAG]  ; value tag
    call rax
    push rax                   ; save result on machine stack

    ; DECREF both (tag-aware, +8 for push rax)
    mov rdi, [rsp + 8 + CN_RIGHT]
    mov rsi, [rsp + 8 + CN_RTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rsp + 8 + CN_LEFT]
    mov rsi, [rsp + 8 + CN_LTAG]
    DECREF_VAL rdi, rsi
    pop rax                    ; result
    add rsp, CN_SIZE - 8       ; discard payloads + tags (CN_INV popped next)
    pop rcx                    ; invert

    ; Invert if 'not in'
    xor eax, ecx

    ; Push bool
    test eax, eax
    jz .contains_false
    lea rax, [rel bool_true]
    jmp .contains_push
.contains_false:
    lea rax, [rel bool_false]
.contains_push:
    INCREF rax
    VPUSH_PTR rax
    DISPATCH

.contains_error:
    ; Try __contains__ on heaptype
    mov rdi, [rsp]            ; container
    mov rax, [rdi + PyObject.ob_type]
    mov rdx, [rax + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .contains_iter_fallback

    extern dunder_contains
    extern dunder_call_2
    mov rdi, [rsp]            ; container = self
    mov rsi, [rsp+8]          ; value = other
    lea rdx, [rel dunder_contains]
    mov rcx, [rsp+24]         ; value tag = other_tag
    call dunder_call_2
    test edx, edx             ; TAG_NULL = not found
    jz .contains_iter_fallback

    ; Convert result to boolean (obj_is_true)
    push rdx                   ; save tag
    push rax                   ; save payload
    mov rdi, rax
    mov rsi, rdx
    extern obj_is_true
    call obj_is_true
    mov ecx, eax              ; save truthiness
    pop rdi                    ; payload
    pop rsi                    ; tag
    DECREF_VAL rdi, rsi
    mov eax, ecx

    ; Continue with result in eax — DECREF operands (tag-aware)
    push rax                   ; +8 shifts CN_ offsets
    mov rdi, [rsp + 8 + CN_RIGHT]
    mov rsi, [rsp + 8 + CN_RTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rsp + 8 + CN_LEFT]
    mov rsi, [rsp + 8 + CN_LTAG]
    DECREF_VAL rdi, rsi
    pop rax
    add rsp, CN_SIZE - 8      ; discard payloads + tags
    pop rcx                    ; invert
    xor eax, ecx
    test eax, eax
    jz .contains_false
    lea rax, [rel bool_true]
    jmp .contains_push

.contains_iter_fallback:
    ; Fallback: iterate container via tp_iter, compare each element
    mov rdi, [rsp + CN_RIGHT]   ; container
    cmp qword [rsp + CN_RTAG], TAG_PTR
    jne .contains_type_error
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz .contains_getitem_fallback
    call rax                     ; tp_iter(container) → iterator
    test rax, rax
    jz .contains_getitem_fallback
    push rax                     ; save iterator (+8 shift)

.contains_iter_loop:
    ; Call tp_iternext(iterator) → (rax=payload, edx=tag) or (0, TAG_NULL)
    mov rdi, [rsp]              ; iterator
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    test edx, edx
    jz .contains_iter_not_found  ; TAG_NULL = exhausted

    ; Identity check: payload and tag both match → found
    ; +8 for iterator push on stack
    cmp rax, [rsp + 8 + CN_LEFT]
    jne .contains_iter_try_eq
    cmp edx, [rsp + 8 + CN_LTAG]
    je .contains_iter_found_decref

.contains_iter_try_eq:
    ; Both SmallInt → direct value compare
    push rax                     ; save elem payload
    push rdx                     ; save elem tag
    mov r8d, edx                ; elem tag
    mov ecx, [rsp + 16 + 8 + CN_LTAG]  ; value tag
    cmp r8d, TAG_SMALLINT
    jne .contains_iter_slow_eq
    cmp ecx, TAG_SMALLINT
    jne .contains_iter_slow_eq
    ; Both SmallInt
    cmp rax, [rsp + 16 + 8 + CN_LEFT]
    pop rdx
    pop rax
    je .contains_iter_found_decref_elem
    jmp .contains_iter_loop

.contains_iter_slow_eq:
    ; Use tp_richcompare for equality
    ; rdi = elem (already on stack[+8]), rsi = value, edx = PY_EQ, rcx = elem_tag, r8 = value_tag
    mov rdi, [rsp + 8]            ; elem payload
    mov rsi, [rsp + 16 + 8 + CN_LEFT]  ; value payload
    mov edx, 2                     ; PY_EQ
    mov ecx, [rsp]                 ; elem tag
    mov r8d, [rsp + 16 + 8 + CN_LTAG] ; value tag
    ; Resolve element type
    cmp ecx, TAG_PTR
    jne .contains_iter_skip_eq     ; for non-PTR non-SmallInt, skip (identity only)
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jz .contains_iter_skip_eq
    call rax                        ; tp_richcompare(left, right, PY_EQ, left_tag, right_tag)
    ; Result: (rax=payload, edx=tag). Check if True
    push rax
    push rdx
    mov rdi, rax
    mov rsi, rdx
    extern obj_is_true
    call obj_is_true
    mov r8d, eax
    pop rsi                         ; result tag
    pop rdi                         ; result payload
    DECREF_VAL rdi, rsi
    pop rdx                         ; elem tag
    pop rax                         ; elem payload
    test r8d, r8d
    jnz .contains_iter_found_decref_elem
    jmp .contains_iter_loop

.contains_iter_skip_eq:
    pop rdx
    pop rax
    jmp .contains_iter_loop

.contains_iter_found_decref_elem:
    ; DECREF element if needed
    mov rdi, rax
    mov rsi, rdx
    DECREF_VAL rdi, rsi
    jmp .contains_iter_found

.contains_iter_found_decref:
    ; Element matched by identity, DECREF it
    mov rdi, rax
    mov rsi, rdx
    DECREF_VAL rdi, rsi

.contains_iter_found:
    ; DECREF iterator
    pop rdi                      ; iterator
    call obj_decref
    mov eax, 1                   ; found
    jmp .contains_iter_result

.contains_iter_not_found:
    ; DECREF iterator
    pop rdi                      ; iterator
    call obj_decref
    xor eax, eax                ; not found

.contains_iter_result:
    ; DECREF operands (tag-aware)
    push rax
    mov rdi, [rsp + 8 + CN_RIGHT]
    mov rsi, [rsp + 8 + CN_RTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rsp + 8 + CN_LEFT]
    mov rsi, [rsp + 8 + CN_LTAG]
    DECREF_VAL rdi, rsi
    pop rax
    add rsp, CN_SIZE - 8         ; discard payloads + tags
    pop rcx                       ; invert
    xor eax, ecx
    test eax, eax
    jz .contains_false
    lea rax, [rel bool_true]
    jmp .contains_push

.contains_getitem_fallback:
    ; Fallback: iterate via __getitem__(0), __getitem__(1), ... until IndexError
    ; Check if container is a heaptype with __getitem__
    mov rdi, [rsp + CN_RIGHT]
    cmp qword [rsp + CN_RTAG], TAG_PTR
    jne .contains_type_error
    mov rax, [rdi + PyObject.ob_type]
    mov rdx, [rax + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .contains_type_error
    ; Probe __getitem__ exists by trying index 0
    push qword 0                 ; push index counter (+8 shift)

.contains_gi_loop:
    mov rdi, [rsp + 8 + CN_RIGHT]  ; container
    mov rsi, [rsp]                  ; index (SmallInt value)
    extern dunder_getitem
    lea rdx, [rel dunder_getitem]
    mov ecx, TAG_SMALLINT           ; index is SmallInt
    call dunder_call_2
    test edx, edx
    jz .contains_gi_null_result
    ; Check for exception (IndexError = stop)
    extern current_exception
    mov rcx, [rel current_exception]
    test rcx, rcx
    jnz .contains_gi_check_exc
    jmp .contains_gi_got_elem

.contains_gi_null_result:
    ; TAG_NULL: either dunder not found, or exception raised
    mov rcx, [rel current_exception]
    test rcx, rcx
    jnz .contains_gi_check_exc     ; exception → check if IndexError
    ; First call with index 0: if no exception and TAG_NULL, dunder not found
    cmp qword [rsp], 0
    je .contains_gi_no_dunder
    ; For index > 0, TAG_NULL without exception means iteration done
    add rsp, 8
    xor eax, eax
    jmp .contains_iter_result

.contains_gi_got_elem:

    ; Got element: (rax=payload, edx=tag). Compare with search value.
    push rax
    push rdx
    ; Identity check
    cmp rax, [rsp + 16 + 8 + CN_LEFT]
    jne .contains_gi_try_eq
    cmp edx, [rsp + 16 + 8 + CN_LTAG]
    je .contains_gi_found_pop2

.contains_gi_try_eq:
    ; SmallInt fast path
    mov r8d, [rsp]                     ; elem tag
    mov ecx, [rsp + 16 + 8 + CN_LTAG] ; value tag
    cmp r8d, TAG_SMALLINT
    jne .contains_gi_slow_eq
    cmp ecx, TAG_SMALLINT
    jne .contains_gi_slow_eq
    cmp rax, [rsp + 16 + 8 + CN_LEFT]
    pop rdx
    pop rax
    je .contains_gi_found
    jmp .contains_gi_next

.contains_gi_slow_eq:
    ; Use tp_richcompare for PTR types
    mov rdi, [rsp + 8]                ; elem payload
    mov rsi, [rsp + 16 + 8 + CN_LEFT] ; value payload
    mov edx, 2                         ; PY_EQ
    mov ecx, [rsp]                     ; elem tag
    mov r8d, [rsp + 16 + 8 + CN_LTAG] ; value tag
    cmp ecx, TAG_PTR
    jne .contains_gi_no_match
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jz .contains_gi_no_match
    call rax
    push rax
    push rdx
    mov rdi, rax
    mov rsi, rdx
    call obj_is_true
    mov r8d, eax
    pop rsi
    pop rdi
    DECREF_VAL rdi, rsi
    pop rdx                            ; elem tag
    pop rax                            ; elem payload
    test r8d, r8d
    jnz .contains_gi_found_decref_elem
    jmp .contains_gi_next_decref

.contains_gi_no_match:
    pop rdx
    pop rax

.contains_gi_next_decref:
    ; DECREF element
    mov rdi, rax
    mov rsi, rdx
    DECREF_VAL rdi, rsi

.contains_gi_next:
    inc qword [rsp]                    ; index++
    jmp .contains_gi_loop

.contains_gi_found_pop2:
    pop rdx
    pop rax
.contains_gi_found_decref_elem:
    mov rdi, rax
    mov rsi, rdx
    DECREF_VAL rdi, rsi
.contains_gi_found:
    add rsp, 8                         ; pop index counter
    mov eax, 1
    jmp .contains_iter_result

.contains_gi_check_exc:
    ; Exception raised. If IndexError → not found. Otherwise re-raise.
    ; DECREF the NULL result if any
    extern exc_IndexError_type
    mov rax, [rel current_exception]
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel exc_IndexError_type]
    cmp rcx, rdx
    jne .contains_gi_reraise
    ; IndexError: clear exception and return not found
    mov rdi, rax
    mov qword [rel current_exception], 0
    call obj_decref
    add rsp, 8                         ; pop index counter
    xor eax, eax
    jmp .contains_iter_result

.contains_gi_reraise:
    ; Re-raise the exception
    add rsp, 8                         ; pop index counter
    ; Exception is already set in current_exception
    extern eval_exception_unwind
    jmp eval_exception_unwind

.contains_gi_no_dunder:
    add rsp, 8                         ; pop index counter
    ; Fall through to type error

.contains_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "argument of type is not iterable"
    call raise_exception
END_FUNC op_contains_op

;; ============================================================================
;; op_build_slice - Build a slice object
;;
;; arg = 2: pop stop, pop start, step=None
;; arg = 3: pop step, pop stop, pop start
;; ============================================================================
DEF_FUNC_BARE op_build_slice
    cmp ecx, 3
    je .bs_three

    ; arg=2: TOS=stop, TOS1=start
    VPOP_VAL rsi, r8          ; stop
    VPOP_VAL rdi, r9          ; start
    ; Save payloads+tags for later DECREF
    push r9                ; start tag (deepest)
    push r8                ; stop tag
    push rdi               ; start
    push rsi               ; stop
    ; slice_new(rdi=start, rsi=stop, rdx=step, ecx=start_tag, r8d=stop_tag, r9d=step_tag)
    lea rdx, [rel none_singleton]  ; step = None
    mov ecx, r9d           ; start_tag
    ; r8 already = stop_tag
    mov r9d, TAG_PTR       ; step_tag = TAG_PTR (none_singleton)
    call slice_new
    push rax               ; save slice (+8 shifts BSL2_ offsets)
    mov rdi, [rsp + 8 + BSL2_STOP]
    mov rsi, [rsp + 8 + BSL2_PTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rsp + 8 + BSL2_START]
    mov rsi, [rsp + 8 + BSL2_STAG]
    DECREF_VAL rdi, rsi
    pop rax
    add rsp, BSL2_SIZE
    VPUSH_PTR rax
    DISPATCH

.bs_three:
    ; arg=3: TOS=step, TOS1=stop, TOS2=start
    VPOP_VAL rdx, r8          ; step
    VPOP_VAL rsi, r9          ; stop
    VPOP_VAL rdi, r10         ; start
    ; Save payloads+tags for later DECREF
    push r10               ; start tag (deepest)
    push r9                ; stop tag
    push r8                ; step tag
    push rdi               ; start
    push rsi               ; stop
    push rdx               ; step
    ; slice_new(rdi=start, rsi=stop, rdx=step, ecx=start_tag, r8d=stop_tag, r9d=step_tag)
    mov ecx, r10d          ; start_tag
    ; r8=step_tag, r9=stop_tag from above. Swap for slice_new convention.
    xchg r8, r9            ; now r8=stop_tag, r9=step_tag
    call slice_new
    push rax               ; save slice (+8 shifts BSL3_ offsets)
    mov rdi, [rsp + 8 + BSL3_STEP]
    mov rsi, [rsp + 8 + BSL3_EPTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rsp + 8 + BSL3_STOP]
    mov rsi, [rsp + 8 + BSL3_PTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rsp + 8 + BSL3_START]
    mov rsi, [rsp + 8 + BSL3_STAG]
    DECREF_VAL rdi, rsi
    pop rax
    add rsp, BSL3_SIZE
    VPUSH_PTR rax
    DISPATCH
END_FUNC op_build_slice

;; ============================================================================
;; op_binary_slice - obj[start:stop]
;;
;; Python 3.12: pops stop, start, obj from stack.
;; Creates a slice(start, stop), calls mp_subscript(obj, slice).
;; ============================================================================
DEF_FUNC op_binary_slice, BSLC_FRAME

    ; Pop stop (TOS), start (TOS1), obj (TOS2) — save payloads + tags
    VPOP_VAL rsi, rax          ; stop
    mov [rbp - BSLC_PTAG], rax
    VPOP_VAL rdi, rax          ; start
    mov [rbp - BSLC_STAG], rax
    mov [rbp - BSLC_START], rdi
    mov [rbp - BSLC_STOP], rsi
    VPOP_VAL rax, rcx
    mov [rbp - BSLC_OTAG], rcx
    mov [rbp - BSLC_OBJ], rax

    ; Create slice(start, stop, None) with tags
    mov rdi, [rbp - BSLC_START]
    mov rsi, [rbp - BSLC_STOP]
    lea rdx, [rel none_singleton]  ; step = None
    mov ecx, [rbp - BSLC_STAG]    ; start_tag
    mov r8d, [rbp - BSLC_PTAG]    ; stop_tag
    mov r9d, TAG_PTR               ; step_tag (None)
    call slice_new
    mov [rbp - BSLC_SLICE], rax

    ; Call mp_subscript(obj, slice, key_tag)
    mov rdi, [rbp - BSLC_OBJ]
    mov rsi, rax           ; slice as key
    mov edx, TAG_PTR       ; key tag = slice (always TAG_PTR)
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    mov rax, [rax + PyMappingMethods.mp_subscript]
    call rax
    SAVE_FAT_RESULT        ; save (rax,rdx) result

    ; DECREF slice (heap ptr, no tag needed)
    mov rdi, [rbp - BSLC_SLICE]
    DECREF_REG rdi
    ; DECREF start, stop, obj (tag-aware)
    mov rdi, [rbp - BSLC_START]
    mov rsi, [rbp - BSLC_STAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rbp - BSLC_STOP]
    mov rsi, [rbp - BSLC_PTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rbp - BSLC_OBJ]
    mov rsi, [rbp - BSLC_OTAG]
    DECREF_VAL rdi, rsi

    RESTORE_FAT_RESULT
    VPUSH_VAL rax, rdx
    leave
    DISPATCH
END_FUNC op_binary_slice

;; ============================================================================
;; op_store_slice - obj[start:stop] = value
;;
;; Python 3.12: pops stop, start, obj, value from stack.
;; ============================================================================
DEF_FUNC op_store_slice, SSLC_FRAME

    ; Pop stop (TOS), start (TOS1), obj (TOS2), value (TOS3) — save tags
    VPOP_VAL rsi, rax          ; stop
    mov [rbp - SSLC_PTAG], rax
    VPOP_VAL rdi, rax          ; start
    mov [rbp - SSLC_STAG], rax
    mov [rbp - SSLC_START], rdi
    mov [rbp - SSLC_STOP], rsi
    VPOP_VAL rax, rcx
    mov [rbp - SSLC_OTAG], rcx
    mov [rbp - SSLC_OBJ], rax
    VPOP_VAL rax, rcx
    mov [rbp - SSLC_VTAG], rcx
    mov [rbp - SSLC_VAL], rax

    ; Create slice(start, stop, None) with tags
    mov rdi, [rbp - SSLC_START]
    mov rsi, [rbp - SSLC_STOP]
    lea rdx, [rel none_singleton]  ; step = None
    mov ecx, [rbp - SSLC_STAG]    ; start_tag
    mov r8d, [rbp - SSLC_PTAG]    ; stop_tag
    mov r9d, TAG_PTR               ; step_tag (None)
    call slice_new
    mov [rbp - SSLC_SLICE], rax

    ; Call mp_ass_subscript(obj, slice, value, key_tag, value_tag)
    mov rdi, [rbp - SSLC_OBJ]
    mov rsi, rax           ; slice
    mov rdx, [rbp - SSLC_VAL]
    mov ecx, TAG_PTR               ; key tag = slice (always TAG_PTR)
    mov r8, [rbp - SSLC_VTAG]     ; value tag
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    mov rax, [rax + PyMappingMethods.mp_ass_subscript]
    call rax

    ; DECREF slice (heap ptr, no tag needed)
    mov rdi, [rbp - SSLC_SLICE]
    DECREF_REG rdi
    ; DECREF start, stop, obj, value (tag-aware)
    mov rdi, [rbp - SSLC_START]
    mov rsi, [rbp - SSLC_STAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rbp - SSLC_STOP]
    mov rsi, [rbp - SSLC_PTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rbp - SSLC_OBJ]
    mov rsi, [rbp - SSLC_OTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rbp - SSLC_VAL]
    mov rsi, [rbp - SSLC_VTAG]
    DECREF_VAL rdi, rsi

    leave
    DISPATCH
END_FUNC op_store_slice

;; ============================================================================
;; op_map_add - Add key:value to dict at stack position
;;
;; MAP_ADD (147): used by dict comprehensions
;; TOS = value, TOS1 = key
;; dict is at stack[-(ecx+2)] relative to current TOS (before pops)
;; ============================================================================
DEF_FUNC op_map_add
    push rcx                   ; save oparg

    VPOP_VAL rdx, r8           ; rdx = value (TOS), r8 = value tag
    VPOP_VAL rsi, r9           ; rsi = key (TOS1), r9 = key tag

    ; dict is at stack[-(ecx)] after the 2 pops (payload slots)
    pop rcx                    ; restore oparg
    neg rcx
    shl rcx, 3                ; -ecx * 8
    mov rdi, [r13 + rcx]      ; rdi = dict

    ; Save key and value with tags behind payloads
    push r9                    ; key tag (deepest)
    push r8                    ; value tag
    push rsi                   ; key
    push rdx                   ; value
    mov rcx, [rsp + MA_VTAG]  ; value tag for dict_set
    mov r8, [rsp + MA_KTAG]   ; key tag for dict_set
    call dict_set

    ; DECREF key and value (tag-aware, dict_set INCREF'd them)
    mov rdi, [rsp + MA_VAL]
    mov rsi, [rsp + MA_VTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rsp + MA_KEY]
    mov rsi, [rsp + MA_KTAG]
    DECREF_VAL rdi, rsi
    add rsp, MA_SIZE

    leave
    DISPATCH
END_FUNC op_map_add

;; ============================================================================
;; op_dict_update - Update dict with another mapping
;;
;; DICT_UPDATE (165): dict.update(mapping)
;; TOS = mapping, dict at stack[-(ecx+1)] after pop
;; Pop TOS, merge all key:value pairs into dict.
;; ============================================================================
extern dict_type

DEF_FUNC op_dict_update
    push rbx
    push r14                   ; extra callee-saved
    sub rsp, 32                ; locals + alignment

    VPOP_VAL rsi, r8           ; rsi = mapping to merge from
    cmp r8d, TAG_PTR
    jne .du_type_error
    mov [rbp-24], rsi

    ; dict is at stack[-(ecx)] after pop (payload slots)
    neg rcx
    shl rcx, 3                ; -ecx * 8
    mov rdi, [r13 + rcx]
    mov [rbp-32], rdi          ; target dict

    ; mapping must be a dict (for now)
    mov rax, [rsi + PyObject.ob_type]
    lea rdx, [rel dict_type]
    cmp rax, rdx
    jne .du_type_error

    ; Iterate over source dict entries and copy to target
    ; Source dict: entries at [rsi + PyDictObject.entries], capacity at +24
    mov rax, [rsi + PyDictObject.capacity]
    mov [rbp-40], rax          ; capacity
    mov rax, [rsi + PyDictObject.entries]
    mov [rbp-48], rax          ; entries ptr
    xor ebx, ebx              ; index

.du_loop:
    cmp rbx, [rbp-40]
    jge .du_done

    ; Check if entry has a key and value_tag != TAG_NULL
    mov rax, [rbp-48]
    imul rcx, rbx, DictEntry_size
    add rax, rcx
    mov rsi, [rax + DictEntry.key]
    test rsi, rsi
    jz .du_next

    cmp byte [rax + DictEntry.value_tag], 0
    je .du_next
    mov rdx, [rax + DictEntry.value]

    ; dict_set(target, key, value, value_tag, key_tag)
    movzx ecx, byte [rax + DictEntry.value_tag]
    movzx r8d, byte [rax + DictEntry.key_tag]
    push rbx
    mov rdi, [rbp-32]
    call dict_set
    pop rbx

.du_next:
    inc rbx
    jmp .du_loop

.du_done:
    ; DECREF the mapping
    mov rdi, [rbp-24]
    call obj_decref

    add rsp, 32
    pop r14
    pop rbx
    leave
    DISPATCH

.du_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "dict.update() argument must be a dict"
    call raise_exception
END_FUNC op_dict_update

;; ============================================================================
;; op_dict_merge - Merge dict (like dict_update but for **kwargs)
;;
;; DICT_MERGE (164): like DICT_UPDATE but raises TypeError on duplicate keys
;; Used for f(**a, **b) — duplicate keys across ** spreads are errors.
;; ============================================================================
extern dict_get

DEF_FUNC op_dict_merge
    push rbx
    push r14
    sub rsp, 32                ; locals + alignment

    VPOP_VAL rsi, r8           ; rsi = mapping to merge from
    cmp r8d, TAG_PTR
    jne .dm_type_error
    mov [rbp-24], rsi

    ; dict is at stack[-(ecx)] after pop (payload slots)
    neg rcx
    shl rcx, 3
    mov rdi, [r13 + rcx]
    mov [rbp-32], rdi          ; target dict

    ; mapping must be a dict
    mov rax, [rsi + PyObject.ob_type]
    lea rdx, [rel dict_type]
    cmp rax, rdx
    jne .dm_type_error

    ; Iterate over source dict entries
    mov rax, [rsi + PyDictObject.capacity]
    mov [rbp-40], rax          ; capacity
    mov rax, [rsi + PyDictObject.entries]
    mov [rbp-48], rax          ; entries ptr
    xor ebx, ebx              ; index

.dm_loop:
    cmp rbx, [rbp-40]
    jge .dm_done

    mov rax, [rbp-48]
    imul rcx, rbx, DictEntry_size
    add rax, rcx
    mov rsi, [rax + DictEntry.key]
    test rsi, rsi
    jz .dm_next

    cmp byte [rax + DictEntry.value_tag], 0
    je .dm_next

    ; Check for duplicate: dict_get(target, key, key_tag)
    push rbx
    mov rdi, [rbp-32]          ; target dict
    ; rsi = key (already set)
    mov rax, [rbp-48]
    imul rcx, rbx, DictEntry_size
    add rax, rcx
    movzx edx, byte [rax + DictEntry.key_tag]
    call dict_get
    test edx, edx
    jnz .dm_dup_error          ; key already exists in target

    ; dict_set(target, key, value, value_tag, key_tag)
    pop rbx
    mov rax, [rbp-48]
    imul rcx, rbx, DictEntry_size
    add rax, rcx
    mov rsi, [rax + DictEntry.key]
    mov rdx, [rax + DictEntry.value]
    movzx ecx, byte [rax + DictEntry.value_tag]
    movzx r8d, byte [rax + DictEntry.key_tag]
    push rbx
    mov rdi, [rbp-32]
    call dict_set
    pop rbx

.dm_next:
    inc rbx
    jmp .dm_loop

.dm_done:
    ; DECREF the mapping
    mov rdi, [rbp-24]
    call obj_decref

    add rsp, 32
    pop r14
    pop rbx
    leave
    DISPATCH

.dm_dup_error:
    pop rbx                    ; balance push from before dict_get
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "got multiple values for keyword argument"
    call raise_exception

.dm_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "dict.update() argument must be a dict"
    call raise_exception
END_FUNC op_dict_merge

;; ============================================================================
;; op_unpack_ex - Unpack with *rest
;;
;; UNPACK_EX (94): arg encodes (count_before | count_after << 8)
;; Pop iterable from TOS, push count_after items, then a list of remaining,
;; then count_before items (in reverse order on stack).
;; ============================================================================
extern list_type
extern list_getitem
extern tuple_getitem

DEF_FUNC op_unpack_ex
    push rbx
    push r14
    ; NOTE: do NOT push/pop r15 — VPUSH_VAL/VPUSH_PTR macros advance r15
    ; (tag stack top) and restoring it would desync from r13 (payload stack top)
    sub rsp, 40                ; locals: [rbp-32]=total_len, [rbp-40]=rest_count,
                               ;         [rbp-48]=iter_tag, [rbp-56]=iterable payload

    ; Decode arg: count_before = ecx & 0xFF, count_after = ecx >> 8
    mov eax, ecx
    and eax, 0xFF
    mov ebx, eax               ; ebx = count_before
    mov eax, ecx
    shr eax, 8
    mov r14d, eax              ; r14 = count_after

    ; Pop iterable
    VPOP_VAL rdi, rax
    mov [rbp-48], rax          ; iterable tag
    mov [rbp-56], rdi          ; iterable payload

    ; Get length
    mov rdi, [rbp-56]
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .ue_list

    extern tuple_type
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .ue_tuple

    ; Generic iterable: iterate into a temp list, then unpack from it
    jmp .ue_generic

.ue_list:
    mov rax, [rdi + PyListObject.ob_size]
    jmp .ue_have_len
.ue_tuple:
    mov rax, [rdi + PyTupleObject.ob_size]

.ue_have_len:
    ; rax = total length
    ; We need: count_before + count_after <= total_length
    lea rcx, [rbx + r14]      ; count_before + count_after
    cmp rax, rcx
    jl .ue_not_enough

    mov [rbp-32], rax          ; save total_len

    ; Compute rest_count = total_len - count_before - count_after
    sub rax, rbx
    sub rax, r14
    mov [rbp-40], rax          ; rest_count

    ; Push in reverse order (top of stack = last pushed = first in sequence)
    ; Stack order (bottom to top):
    ;   last after_item, ..., first after_item, rest_list, last before_item, ..., first before_item
    ; Wait, Python actually pushes in this order:
    ;   Push count_after items in reverse (items from end)
    ;   Push rest list
    ;   Push count_before items in reverse (items from start)
    ; So TOS = first_before, TOS1 = second_before, ..., then rest, then after items

    ; 1. Push count_after items (from end, in reverse)
    mov rcx, r14
    test rcx, rcx
    jz .ue_no_after

    ; after items are at indices [total_len - count_after .. total_len - 1]
    ; Push them in reverse: index total_len-1, total_len-2, ..., total_len-count_after
    mov rax, [rbp-32]          ; total_len
    dec rax                    ; start from total_len - 1
.ue_after_loop:
    test rcx, rcx
    jz .ue_no_after
    push rcx
    push rax

    ; Get item at index rax from iterable
    mov rdi, [rbp-56]
    mov rsi, rax
    call .ue_getitem           ; rax = payload, rdx = tag (borrowed)
    INCREF_VAL rax, rdx
    VPUSH_VAL rax, rdx

    pop rax
    pop rcx
    dec rax
    dec rcx
    jmp .ue_after_loop

.ue_no_after:
    ; 2. Build rest list
    mov rdi, [rbp-40]          ; rest_count as initial capacity
    call list_new
    push rax                   ; save rest list

    ; Add items at indices [count_before .. count_before + rest_count - 1]
    mov rcx, [rbp-40]          ; rest_count
    test rcx, rcx
    jz .ue_rest_done
    mov rax, rbx               ; start index = count_before
.ue_rest_loop:
    test rcx, rcx
    jz .ue_rest_done
    push rcx
    push rax

    mov rdi, [rbp-56]
    mov rsi, rax
    call .ue_getitem           ; rax = payload, rdx = tag (borrowed)
    mov rsi, rax
    mov rdi, [rsp + 16]        ; rest list (2 pushes deep)
    push rsi
    ; edx = item tag from .ue_getitem (already set)
    call list_append           ; list_append does INCREF
    pop rsi                    ; discard
    pop rax
    pop rcx
    inc rax
    dec rcx
    jmp .ue_rest_loop

.ue_rest_done:
    pop rax                    ; rest list
    VPUSH_PTR rax              ; push rest list

    ; 3. Push count_before items in reverse (from index count_before-1 down to 0)
    mov rcx, rbx
    test rcx, rcx
    jz .ue_no_before
    dec rcx                    ; start from count_before - 1
.ue_before_loop:
    push rcx

    mov rdi, [rbp-56]
    mov rsi, rcx
    call .ue_getitem           ; rax = payload, rdx = tag (borrowed)
    INCREF_VAL rax, rdx
    VPUSH_VAL rax, rdx

    pop rcx
    test rcx, rcx
    jz .ue_no_before
    dec rcx
    jmp .ue_before_loop

.ue_no_before:
    ; DECREF iterable (tag-aware)
    mov rdi, [rbp-56]
    mov rsi, [rbp-48]         ; iterable tag
    DECREF_VAL rdi, rsi

    add rsp, 40
    pop r14
    pop rbx
    leave
    DISPATCH

.ue_generic:
    ; Generic iterable: iterate into a temp list, then unpack from it
    ; [rbp-56] = iterable payload, [rbp-48] = iterable tag
    ; ebx = count_before, r14 = count_after (must preserve)
    mov rdi, [rbp-56]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz .ue_type_error
    mov rdi, [rbp-56]
    call rax                   ; tp_iter(iterable) → iterator
    test rax, rax
    jz .ue_type_error
    push rax                   ; [rsp] = iterator

    ; Create temp list
    xor edi, edi
    extern list_new
    call list_new
    push rax                   ; [rsp] = temp_list, [rsp+8] = iterator

.ue_gen_loop:
    mov rdi, [rsp + 8]        ; iterator
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .ue_gen_done
    mov rdi, [rsp + 8]
    call rax                   ; tp_iternext(iter) → (payload, tag)
    test edx, edx
    jz .ue_gen_done

    ; Append to temp list
    push rax
    push rdx
    mov rdi, [rsp + 16]       ; temp_list (2 pushes deeper)
    mov rsi, rax
    call list_append
    pop rsi                    ; tag
    pop rdi                    ; payload
    DECREF_VAL rdi, rsi
    jmp .ue_gen_loop

.ue_gen_done:
    pop rax                    ; temp_list
    pop rdi                    ; iterator
    push rax                   ; save temp_list
    call obj_decref            ; DECREF iterator

    ; DECREF original iterable
    mov rdi, [rbp-56]
    mov rsi, [rbp-48]
    DECREF_VAL rdi, rsi

    ; Replace iterable with temp list, update tag
    pop rax                    ; rax = temp_list
    mov [rbp-56], rax
    mov qword [rbp-48], TAG_PTR

    ; Now fall through to .ue_list path (reload rdi — clobbered by DECREF_VAL above)
    mov rdi, rax
    jmp .ue_list

.ue_not_enough:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "not enough values to unpack"
    call raise_exception

.ue_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "cannot unpack non-sequence"
    call raise_exception

; Helper: get item at index rsi from iterable rdi (returns borrowed ref: rax=payload, rdx=tag)
.ue_getitem:
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .ue_gi_list
    ; tuple: payload + tag arrays
    mov rax, [rdi + PyTupleObject.ob_item]
    mov rdx, [rdi + PyTupleObject.ob_item_tags]
    mov rax, [rax + rsi * 8]       ; payload
    movzx edx, byte [rdx + rsi]    ; tag
    ret
.ue_gi_list:
    mov rax, [rdi + PyListObject.ob_item]
    mov rcx, [rdi + PyListObject.ob_item_tags]
    mov rax, [rax + rsi * 8]      ; payload
    movzx edx, byte [rcx + rsi]   ; tag
    ret
END_FUNC op_unpack_ex

;; ============================================================================
;; op_kw_names - Store keyword argument names for next CALL
;;
;; KW_NAMES (172): Store co_consts[arg] as pending kw_names tuple.
;; The next CALL opcode will use this tuple.
;; ============================================================================
extern kw_names_pending

DEF_FUNC_BARE op_kw_names
    ; ecx = arg (index into co_consts)
    mov rax, [rel eval_co_consts]
    mov rax, [rax + rcx * 8]   ; payload (tuple ptr for kw_names)
    mov [rel kw_names_pending], rax
    DISPATCH
END_FUNC op_kw_names

;; ============================================================================
;; op_build_set - Create set from TOS items
;;
;; ecx = count (number of items to pop)
;; Items are on stack bottom-to-top: first item deepest.
;; ============================================================================
extern set_new
extern set_add
extern set_type

DEF_FUNC op_build_set, 16

    mov [rbp-8], rcx           ; save count

    ; Allocate empty set
    call set_new
    mov [rbp-16], rax          ; save set

    ; Pop items and add to set
    mov rcx, [rbp-8]
    test rcx, rcx
    jz .build_set_done

    ; Calculate base (payload + tag arrays)
    mov rdi, rcx
    shl rdi, 3
    sub r13, rdi               ; pop all payloads
    sub r15, rcx               ; pop all tags

    xor edx, edx
.build_set_fill:
    cmp rdx, [rbp-8]
    jge .build_set_done
    push rdx
    mov rdi, [rbp-16]         ; set
    mov rax, rdx
    shl rax, 3                ; index * 8
    mov rsi, [r13 + rax]     ; item payload
    movzx edx, byte [r15 + rdx] ; item tag
    call set_add               ; set_add does INCREF
    pop rdx
    inc rdx
    jmp .build_set_fill

.build_set_done:
    ; set_add does INCREF on key, so DECREF all stack items to compensate
    mov rcx, [rbp-8]
    test rcx, rcx
    jz .build_set_push
    xor edx, edx
.build_set_fixref:
    cmp rdx, [rbp-8]
    jge .build_set_push
    mov rax, rdx
    shl rax, 3                ; index * 8
    mov rdi, [r13 + rax]
    movzx esi, byte [r15 + rdx]  ; tag
    push rdx
    DECREF_VAL rdi, rsi
    pop rdx
    inc rdx
    jmp .build_set_fixref

.build_set_push:
    mov rax, [rbp-16]
    VPUSH_PTR rax
    leave
    DISPATCH
END_FUNC op_build_set

;; ============================================================================
;; op_set_add - Add TOS to set at stack position
;;
;; SET_ADD (146): used by set comprehensions
;; ecx = position (1-based from TOS before the value to add)
;; Pop TOS (value), add to set.
;; ============================================================================
DEF_FUNC_BARE op_set_add

    ; TOS = value to add
    VPOP_VAL rsi, r8           ; rsi = value, r8 = value tag

    ; set is at stack[-(ecx)] after popping (payload slots)
    neg rcx
    shl rcx, 3                ; -ecx * 8
    mov rdi, [r13 + rcx]      ; rdi = set

    push r8                    ; save value tag (deeper)
    push rsi                   ; save value payload
    mov rdx, r8                ; key tag for set_add
    call set_add
    ; set_add does INCREF, so DECREF to compensate
    pop rdi                    ; value payload
    pop rsi                    ; value tag
    DECREF_VAL rdi, rsi

    DISPATCH
END_FUNC op_set_add

;; ============================================================================
;; op_set_update - Update set with iterable
;;
;; SET_UPDATE (163): set.update(iterable)
;; ecx = position (set at stack[-(ecx)] after pop)
;; Pop TOS (iterable), add each item to set.
;; ============================================================================
DEF_FUNC op_set_update
    push rbx
    push r14
    sub rsp, 40                ; locals: [rbp-24]=set, [rbp-32]=iterable, [rbp-40]=iter, [rbp-48]=iter_tag

    ; TOS = iterable
    VPOP_VAL rsi, rax          ; rsi = iterable
    mov [rbp-48], rax          ; iterable tag
    cmp eax, TAG_PTR
    jne .su_type_error
    mov [rbp-32], rsi          ; save iterable

    ; set is at stack[-(ecx)] after popping (payload slots)
    neg rcx
    shl rcx, 3                ; -ecx * 8
    mov rdi, [r13 + rcx]      ; rdi = set
    mov [rbp-24], rdi          ; save set

    ; Check if iterable is a set (direct iteration over entries)
    mov rax, [rsi + PyObject.ob_type]
    lea rdx, [rel set_type]
    cmp rax, rdx
    je .su_from_set

    ; Generic approach: get iterator via tp_iter, then loop tp_iternext
    mov rdi, rsi
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz .su_type_error
    call rax
    mov [rbp-40], rax          ; save iterator

.su_iter_loop:
    mov rdi, [rbp-40]          ; iterator
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    test edx, edx
    jz .su_iter_done

    ; rax = next item (owned ref), rdx = tag from tp_iternext
    push rdx                   ; save item tag
    push rax                   ; save item payload
    mov rdi, [rbp-24]          ; set
    mov rsi, rax               ; item
    ; rdx = tag already set by tp_iternext
    call set_add               ; set_add does INCREF
    pop rdi                    ; item payload
    pop rsi                    ; item tag
    DECREF_VAL rdi, rsi        ; DECREF to compensate (set_add INCREF'd)
    jmp .su_iter_loop

.su_iter_done:
    ; DECREF iterator (heap ptr, no tag needed)
    mov rdi, [rbp-40]
    call obj_decref

    ; DECREF iterable (tag-aware)
    mov rdi, [rbp-32]
    mov rsi, [rbp-48]
    DECREF_VAL rdi, rsi

    add rsp, 40
    pop r14
    pop rbx
    leave
    DISPATCH

.su_from_set:
    ; Iterable is a set - iterate entries directly
    mov rax, [rsi + PyDictObject.capacity]
    mov [rbp-40], rax          ; capacity (reuse slot)
    xor ebx, ebx              ; index

.su_set_loop:
    cmp rbx, [rbp-40]
    jge .su_set_done

    mov rax, [rbp-32]         ; source set
    mov rax, [rax + PyDictObject.entries]
    imul rcx, rbx, 24         ; SET_ENTRY_SIZE = 24
    add rax, rcx

    ; Check if entry has a key
    mov rsi, [rax + 8]        ; SET_ENTRY_KEY offset = 8
    test rsi, rsi
    jz .su_set_next

    ; set_add(target_set, key, key_tag)
    mov rdx, [rax + 16]       ; SET_ENTRY_KEY_TAG offset = 16
    push rbx
    mov rdi, [rbp-24]
    call set_add
    pop rbx

.su_set_next:
    inc rbx
    jmp .su_set_loop

.su_set_done:
    ; DECREF iterable (tag-aware)
    mov rdi, [rbp-32]
    mov rsi, [rbp-48]
    DECREF_VAL rdi, rsi

    add rsp, 40
    pop r14
    pop rbx
    leave
    DISPATCH

.su_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "object is not iterable"
    call raise_exception
END_FUNC op_set_update

;; ============================================================================
;; op_for_iter_range - Specialized range iterator (opcode 214)
;;
;; Guard: TOS ob_type == range_iter_type
;; Inlines range_iter_next logic: decode current/stop/step, check bounds,
;; return SmallInt, advance current.
;; ecx = jump offset. Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_for_iter_range
    VPEEK rdi                      ; iterator (don't pop)
    ; Guard: must be range_iter_type
    lea rax, [rel range_iter_type]
    cmp [rdi + PyObject.ob_type], rax
    jne .fir_deopt

    ; Inline range_iter_next
    mov rax, [rdi + PyRangeIterObject.it_current]

    mov r8, [rdi + PyRangeIterObject.it_stop]

    mov r9, [rdi + PyRangeIterObject.it_step]

    ; Check exhaustion
    test r9, r9
    js .fir_neg_step
    ; Positive step: current >= stop -> exhausted
    cmp rax, r8
    jge .fir_exhausted
    jmp .fir_has_value
.fir_neg_step:
    ; Negative step: current <= stop -> exhausted
    cmp rax, r8
    jle .fir_exhausted

.fir_has_value:
    ; Return current as SmallInt (no INCREF needed for SmallInt)
    mov rdx, rax

    ; Advance: current += step
    add rax, r9
    mov [rdi + PyRangeIterObject.it_current], rax

    VPUSH_INT rdx                  ; push value
    add rbx, 2                     ; skip CACHE
    DISPATCH

.fir_exhausted:
    ; Pop iterator, skip CACHE + jump by (arg + 1)
    ; ecx = saved arg (from instruction word)
    lea rcx, [rcx + 1]            ; arg + 1
    add rbx, 2                     ; skip CACHE
    lea rbx, [rbx + rcx*2]        ; jump forward
    VPOP_VAL rdi, rsi
    DECREF_VAL rdi, rsi
    DISPATCH

.fir_deopt:
    ; Type mismatch: rewrite to FOR_ITER (93) and re-execute
    mov byte [rbx - 2], 93
    sub rbx, 2
    DISPATCH
END_FUNC op_for_iter_range

;; ============================================================================
;; op_for_iter_list - Specialized list iterator (opcode 213)
;;
;; Guard: TOS ob_type == list_iter_type
;; Inlines list_iter_next: check index < list.ob_size, load item, INCREF,
;; advance index.
;; ecx = jump offset. Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_for_iter_list
    push rcx                       ; save jump offset (ecx will be clobbered)
    VPEEK rdi                      ; iterator (don't pop)
    ; Guard: must be list_iter_type
    lea rax, [rel list_iter_type]
    cmp [rdi + PyObject.ob_type], rax
    jne .fil_deopt

    ; Inline list_iter_next
    mov rax, [rdi + PyListIterObject.it_seq]       ; list ptr
    mov rcx, [rdi + PyListIterObject.it_index]     ; current index

    ; Check bounds
    cmp rcx, [rax + PyListObject.ob_size]
    jge .fil_exhausted

    ; Get item and INCREF (payload + tag arrays)
    mov rdx, [rax + PyListObject.ob_item]
    mov r9, [rax + PyListObject.ob_item_tags]
    mov rax, [rdx + rcx * 8]      ; payload
    movzx r8d, byte [r9 + rcx]    ; tag
    INCREF_VAL rax, r8

    ; Advance index
    inc qword [rdi + PyListIterObject.it_index]

    add rsp, 8                     ; discard saved jump offset
    VPUSH_VAL rax, r8              ; push fat value
    add rbx, 2                     ; skip CACHE
    DISPATCH

.fil_exhausted:
    ; Mark iterator as exhausted: DECREF list, clear it_seq
    push rdi                       ; save iterator ptr
    mov rdi, [rdi + PyListIterObject.it_seq]
    test rdi, rdi
    jz .fil_already_exhausted
    call obj_decref
.fil_already_exhausted:
    pop rdi
    mov qword [rdi + PyListIterObject.it_seq], 0

    ; Restore the original arg (jump offset)
    pop rcx                        ; restore jump offset
    lea rcx, [rcx + 1]            ; arg + 1
    add rbx, 2                     ; skip CACHE
    lea rbx, [rbx + rcx*2]        ; jump forward
    VPOP_VAL rdi, rsi
    DECREF_VAL rdi, rsi
    DISPATCH

.fil_deopt:
    pop rcx                        ; restore jump offset (for re-execute)
    ; Type mismatch: rewrite to FOR_ITER (93) and re-execute
    mov byte [rbx - 2], 93
    sub rbx, 2
    DISPATCH
END_FUNC op_for_iter_list
