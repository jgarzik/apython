; opcodes/build.asm - Opcode handlers for subscript, build, and iteration opcodes
;
; Register convention (callee-saved, preserved across handlers):
;   rbx = bytecode instruction pointer (current position in co_code[])
;   r12 = current frame pointer (PyFrame*)
;   r13 = value stack payload top pointer
;
; ecx = opcode argument on entry (set by eval_dispatch)
; rbx has already been advanced past the 2-byte instruction word.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

section .text

extern get_iterator_opt
extern raise_unpack_count
extern eval_dispatch
extern obj_decref
extern obj_is_true
extern raise_exception
extern exc_TypeError_type
extern eval_exception_unwind
extern exc_ValueError_type
extern int_to_i64
extern type_type
extern tuple_new
extern list_new
extern list_new_filled
extern ap_memcpy
extern list_append
extern dict_new
extern dict_set
extern slice_new
extern none_singleton
extern dict_get
extern str_from_cstr_heap
extern range_iter_type
extern list_iter_type
extern dict_type
extern list_type
extern tuple_type
extern obj_dealloc
extern opcode_table
extern opcode_dispatch_table

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
BSLC_FRAME equ 72            ; + 0 pushes = 64, 16-aligned

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
SSLC_FRAME equ 88            ; + 0 pushes = 80, 16-aligned

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
CN_SIZE  equ 40

;; ============================================================================
;; op_binary_subscr - obj[key]
;;
;; Pop key, pop obj, call mp_subscript or sq_item, push result.
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_binary_subscr
    ; Specialize, then run generically this time.  A list or a tuple indexed
    ; by an int immediate is the overwhelming majority of subscripts, and both
    ; can be read inline; everything else keeps the protocol below.
    ;
    ; The check reads the two operands without touching r13, so a site that
    ; does not qualify has paid four instructions and nothing else.
    mov r8, [r13 - 8]           ; the key Value
    V_IS_INT r8, r9
    jb .bs_no_spec
    mov r8, [r13 - 16]          ; the container Value
    V_TEST_PTR r8, r9
    ja .bs_no_spec
    mov r8, [r8 + PyObject.ob_type]
    lea r9, [rel list_type]
    cmp r8, r9
    je .bs_spec_list
    lea r9, [rel tuple_type]
    cmp r8, r9
    jne .bs_no_spec
    mov byte [rbx - 2], OP_BINARY_SUBSCR_TUPLE_INT
    jmp .bs_no_spec
.bs_spec_list:
    mov byte [rbx - 2], OP_BINARY_SUBSCR_LIST_INT
.bs_no_spec:

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

    ; Call mp_subscript(rdi = obj, rsi = key Value)
    mov rdx, r8                ; rdx = key tag
    V_PACK rsi, rdx
    call rax
    V_UNPACK rax, rdx          ; mp_subscript returns a Value
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
    V_UNPACK rax, rdx          ; sq_item returns a Value
    jmp .subscr_done

.no_subscript:
    ; Try __class_getitem__ on type objects FIRST (for MyClass[args] syntax)
    mov rdi, [rsp+8]              ; obj
    cmp qword [rsp+24], TAG_SMALLINT  ; obj tag
    je .try_getitem_dunder
    ; "Is this object a class?" is TYPE_FLAG_METATYPE on its type, not a
    ; comparison against the two metatypes this tree happens to ship: a class
    ; built by a metaclass of its own answers no to those.  os.PathLike is one
    ; -- an ABC -- and `os.PathLike[str]` was "object is not subscriptable".
    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .try_getitem_dunder
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jnz .try_class_getitem

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
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jnz .subscr_done
    jmp .subscr_error

.try_class_getitem:
    ; `type[int]` is a special case in CPython, taken before any lookup, and
    ; type itself carries no __class_getitem__ -- hasattr(type,
    ; "__class_getitem__") is False there and it is not in type.__dict__.
    ; Registering one to make the subscript work made both answer yes, which
    ; is what typing and the ABCs read to decide whether something is
    ; subscriptable at all.
    mov rdi, [rsp+8]
    lea rax, [rel type_type]
    cmp rdi, rax
    jne .cgi_lookup
    mov rsi, [rsp]                  ; the key
    mov rcx, [rsp + 16]
    V_PACK rsi, rcx
    extern generic_alias_new
    call generic_alias_new
    mov edx, TAG_PTR
    jmp .subscr_done

.cgi_lookup:
    ; obj is a type — look up __class_getitem__ in its tp_dict (walk MRO)
    ; Stack: [rsp]=key, [rsp+8]=obj
    extern dunder_lookup
    extern classmethod_type
    mov rdi, [rsp+8]              ; obj (the type itself)
    CSTRING rsi, "__class_getitem__"
    call dunder_lookup
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
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

    ; Build the args array: [cls, key]
    sub rsp, 16
    mov rax, [rsp + 16 + BSUB_OBJ]  ; obj (type/cls) — always a pointer
    mov [rsp], rax                   ; args[0] = cls
    mov rax, [rsp + 16 + BSUB_KEY]  ; key
    mov r8, [rsp + 16 + BSUB_KTAG]  ; key tag
    V_PACK rax, r8
    mov [rsp + 8], rax               ; args[1] = key
    mov rsi, rsp                     ; args ptr
    mov edx, 2                       ; nargs = 2
    call rcx
    V_UNPACK rax, rdx           ; tp_call returns a Value
    add rsp, 16                      ; pop args
    jmp .subscr_done

.subscr_error:
    ; CPython names what was subscripted, and names a class differently from
    ; an instance: "type 'C' is not subscriptable" against "'C' object is not
    ; subscriptable".  A program reads the first to tell a missing
    ; __class_getitem__ from a missing __getitem__.
    ; The slot holds a PAYLOAD and its tag separately, not a Value: testing
    ; the payload with V_TEST_PTR calls the int 1 a pointer and dereferences
    ; it.  The tag is what says which it is.
    mov rdi, [rsp + BSUB_OBJ]
    cmp qword [rsp + BSUB_OTAG], TAG_PTR
    jne .sub_err_instance
    test rdi, rdi
    jz .sub_err_instance
    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .sub_err_instance
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .sub_err_instance
    mov rsi, rdi
    extern raise_type_error_with_typename
    CSTRING rdi, `type '\x01' is not subscriptable`
    call raise_type_error_with_typename
.sub_err_instance:
    mov rax, [rsp + BSUB_OBJ]
    mov rdx, [rsp + BSUB_OTAG]
    V_PACK rax, rdx
    mov rsi, rax
    extern raise_type_error_with_name
    CSTRING rdi, `'\x01' object is not subscriptable`
    call raise_type_error_with_name

.subscr_done:
    ; rax = result payload, rdx = result tag
    ;
    ; The NULL test comes BEFORE the operands are released.  The unwinder
    ; restores r13 to the stack as it stood before this instruction, so the
    ; operands are back on it and the unwind releases them -- releasing them
    ; here as well frees each twice, which is a crash at whatever touches one
    ; next rather than here.
    test edx, edx
    jz .bs_slot_failed
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

.bs_slot_failed:
    ; A slot that answers NULL is REPORTING, not answering.  This pushed it
    ; and carried on, so `a[3]` as a statement left the exception pending
    ; with nothing to attach it to and it surfaced at whatever ran next --
    ; CPython's BINARY_SUBSCR is `ERROR_IF(res == NULL, error)`.
    ;
    ; It went unnoticed because every mp_subscript in the tree until now
    ; RAISED instead, tail-jumping into the unwinder.  array's cannot: the
    ; sequence iterator has to be able to CATCH the IndexError it raises and
    ; read it as exhaustion, which a tail-jump takes straight past.
    add rsp, BSUB_SIZE
    cmp qword [gs:ThreadState.current_exception], 0
    je .bs_no_exception
    ; No `leave`: this handler is DEF_FUNC_BARE and carves its own space,
    ; which the add above has already given back.
    jmp eval_exception_unwind
.bs_no_exception:
    ; A NULL with nothing pending has no coherent value to stand for either.
    RAISE exc_TypeError_type, "subscript failed without an exception"
END_FUNC op_binary_subscr

;; ============================================================================
;; op_store_subscr - obj[key] = value
;;
;; Stack: value, obj, key (TOS)
;; Pop key, pop obj, pop value.
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_store_subscr
    ; Specialize, then run generically this time -- as op_binary_subscr does,
    ; and for the same operand shape.  Only list is worth it: dict's
    ; mp_ass_subscript is already a two-instruction trampoline into dict_set,
    ; where list's goes through list_ass_subscript and then list_setitem, each
    ; with a prologue of its own.
    mov r8, [r13 - 8]           ; the key Value
    V_IS_INT r8, r9
    jb .ss_no_spec
    mov r8, [r13 - 16]          ; the container Value
    V_TEST_PTR r8, r9
    ja .ss_no_spec
    lea r9, [rel list_type]
    cmp [r8 + PyObject.ob_type], r9
    jne .ss_no_spec
    mov byte [rbx - 2], OP_STORE_SUBSCR_LIST_INT
.ss_no_spec:

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

    ; Call mp_ass_subscript(obj, key Value, value Value)
    mov rcx, r8                ; key tag
    V_PACK rsi, rcx
    mov rcx, r10               ; value tag
    V_PACK rdx, rcx
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
    mov rcx, [rsp + SSUB_VTAG] ; value tag
    V_PACK rdx, rcx            ; sq_ass_item takes a value Value
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
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jz .store_type_error

    ; Call __setitem__(self, key, value) via tp_call
    mov rcx, rax              ; func
    mov rax, [rcx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .store_type_error

    ; Build the args array: [self, key, value]
    sub rsp, 32               ; three Values, rsp stays aligned
    mov r8, [rsp + 32 + SSUB_OBJ]   ; self (a heap instance, so already a Value)
    mov [rsp], r8
    mov r8, [rsp + 32 + SSUB_KEY]   ; key payload
    mov r9, [rsp + 32 + SSUB_KTAG]
    V_PACK r8, r9
    mov [rsp + 8], r8
    mov r8, [rsp + 32 + SSUB_VAL]   ; value payload
    mov r9, [rsp + 32 + SSUB_VTAG]
    V_PACK r8, r9
    mov [rsp + 16], r8
    mov rdi, rcx              ; callable
    mov rsi, rsp              ; args ptr
    mov edx, 3                ; nargs
    call rax
    V_UNPACK rax, rdx           ; tp_call returns a Value
    add rsp, 32               ; pop the args array
    ; rax = result (discard — __setitem__ returns None)
    jmp .store_done

.store_type_error:
    RAISE exc_TypeError_type, "object does not support item assignment"

.store_done:
    ; mp_ass_subscript reports failure with -1, the way tp_setattr does.  It
    ; was never looked at, so `a[5] = 1` on a short array set an IndexError
    ; and carried on, and the exception surfaced at whatever ran next.  The
    ; operands stay on the value stack for the unwinder, which restores r13
    ; to the state before this instruction and releases them there.
    test eax, eax
    js .ss_slot_failed
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

.ss_slot_failed:
    add rsp, SSUB_SIZE
    cmp qword [gs:ThreadState.current_exception], 0
    je .ss_no_exception
    jmp eval_exception_unwind
.ss_no_exception:
    RAISE exc_TypeError_type, \
          "item assignment failed without an exception"
END_FUNC op_store_subscr

;; ============================================================================
;; op_build_tuple - Create tuple from TOS items
;;
;; ecx = count (number of items to pop)
;; Items are on stack bottom-to-top: first item deepest.
;; ============================================================================
BT_COUNT    equ 8
BT_TUPLE    equ 16
DEF_FUNC op_build_tuple, 24   ; + 0 pushes; a handler is entered ALIGNED, so this is 8 mod 16
    ; [rbp - BT_COUNT] = count

    mov [rbp - BT_COUNT], rcx           ; save count

    ; Allocate tuple
    mov rdi, rcx
    call tuple_new
    mov [rbp - BT_TUPLE], rax          ; save tuple

    ; Fill items: tuple[i] = stack[-(count-i)]
    ; Items on stack: [r13 - count*8] = first, [r13 - 8] = last
    mov rcx, [rbp - BT_COUNT]          ; count
    mov rax, [rbp - BT_TUPLE]         ; tuple
    xor edx, edx              ; index
    test rcx, rcx
    jz .build_tuple_done

    ; Calculate base of items on the value stack
    mov rdi, rcx
    shl rdi, 3                 ; count * 8
    sub r13, rdi               ; pop all items at once

.build_tuple_fill:
    mov rax, rdx
    shl rax, 3                 ; index * 8
    mov rsi, [r13 + rax]      ; item from stack
    V_UNPACK rsi, rdi         ; tuples still store (payload, tag)
    mov rax, [rbp - BT_TUPLE]
    mov r8, [rax + PyTupleObject.ob_item]       ; payloads
    V_PACK rsi, rdi
    mov [r8 + rdx * 8], rsi
    inc rdx
    cmp rdx, [rbp - BT_COUNT]
    jb .build_tuple_fill

.build_tuple_done:
    mov rax, [rbp - BT_TUPLE]
    VPUSH_PTR rax
    leave
    DISPATCH
END_FUNC op_build_tuple

;; ============================================================================
;; op_build_list - Create list from TOS items
;;
;; ecx = count
;; ============================================================================
BL_COUNT    equ 8
BL_LIST     equ 16
DEF_FUNC op_build_list, 24   ; + 0 pushes; a handler is entered ALIGNED, so this is 8 mod 16

    mov [rbp - BL_COUNT], rcx           ; save count

    ; The items are already a contiguous array of Values on the value stack,
    ; which is exactly the shape the list's own array has.  So this is one
    ; ap_memcpy and nothing else.
    ;
    ; It was a `call list_append` per item followed by a SECOND pass calling
    ; DECREF_V on every one of them -- because list_append takes a reference
    ; of its own and the stack's reference was being given away, so every
    ; item was incremented and then immediately decremented.  Moving the
    ; references wholesale is what CPython's _PyList_FromArraySteal does, and
    ; it is why that one can memcpy too.
    mov rdi, rcx
    call list_new_filled
    mov [rbp - BL_LIST], rax

    mov rcx, [rbp - BL_COUNT]
    test rcx, rcx
    jz .build_list_push

    mov rdi, rcx
    shl rdi, 3
    sub r13, rdi               ; pop all items; their references move
    mov rsi, r13
    mov rdi, [rbp - BL_LIST]
    mov [rdi + PyListObject.ob_size], rcx
    mov rdi, [rdi + PyListObject.ob_item]
    mov rdx, rcx
    shl rdx, 3
    call ap_memcpy

.build_list_push:
    mov rax, [rbp - BL_LIST]
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
BM_COUNT    equ 8
BM_DICT     equ 16
DEF_FUNC op_build_map, 24   ; + 0 pushes; a handler is entered ALIGNED, so this is 8 mod 16

    mov [rbp - BM_COUNT], rcx           ; save count

    call dict_new
    mov [rbp - BM_DICT], rax          ; save dict

    ; The count is known, so take the room once.  A twenty-key literal grew
    ; its table twice on the way, rehashing everything each time.
    mov rdi, rax
    mov rsi, [rbp - BM_COUNT]
    extern dict_reserve
    call dict_reserve

    ; Total items on stack = count * 2
    mov rcx, [rbp - BM_COUNT]
    shl rcx, 1                 ; count * 2
    test rcx, rcx
    jz .build_map_done

    mov rdi, rcx
    shl rdi, 3                 ; total_items * 8 bytes/slot
    sub r13, rdi               ; pop all items

    xor edx, edx              ; pair index
.build_map_fill:
    cmp rdx, [rbp - BM_COUNT]
    jge .build_map_done
    push rdx
    sub rsp, 8                  ; pad: a handler is entered 16-aligned, so the
                                ; single push above leaves the call 8 out
    mov rdi, [rbp - BM_DICT]         ; dict
    mov rax, rdx
    shl rax, 4                 ; pair_index * 16 (2 payload slots)
    mov rsi, [r13 + rax]      ; key
    mov rdx, [r13 + rax + 8]  ; value
    call dict_set
    add rsp, 8
    pop rdx
    inc rdx
    jmp .build_map_fill

.build_map_done:
    ; dict_set does INCREF on key+value, so DECREF all stack items
    mov rcx, [rbp - BM_COUNT]
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
    push rdx
    push rcx
    DECREF_V rdi, rsi
    pop rcx
    pop rdx
    inc rdx
    jmp .build_map_fixref

.build_map_push:
    mov rax, [rbp - BM_DICT]
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
CKM_COUNT   equ 8
CKM_KEYS    equ 16
CKM_DICT    equ 24
CKM_I       equ 32        ; the loop index, which used to be pushed across
                          ; dict_set -- a lone push leaves the call 8 out
DEF_FUNC op_build_const_key_map, 40   ; + 0 pushes; a handler is entered ALIGNED, so this is 8 mod 16

    mov [rbp - CKM_COUNT], rcx           ; count

    ; Pop keys tuple from TOS
    VPOP rax
    mov [rbp - CKM_KEYS], rax          ; keys tuple

    call dict_new
    mov [rbp - CKM_DICT], rax          ; dict

    ; The keys tuple names them all, so take the room once.
    mov rdi, rax
    mov rsi, [rbp - CKM_COUNT]
    call dict_reserve

    ; Pop values
    mov rcx, [rbp - CKM_COUNT]
    test rcx, rcx
    jz .bckm_done

    mov rdi, rcx
    shl rdi, 3                 ; count * 8 bytes/slot
    sub r13, rdi               ; pop all items

    mov qword [rbp - CKM_I], 0
.bckm_fill:
    mov rdx, [rbp - CKM_I]
    cmp rdx, [rbp - CKM_COUNT]
    jge .bckm_done
    mov rdi, [rbp - CKM_DICT]         ; dict
    mov rax, [rbp - CKM_KEYS]         ; keys tuple
    mov r10, [rax + PyTupleObject.ob_item]       ; payloads
    mov rsi, [r10 + rdx*8]                        ; key payload
    mov r9, rdx
    mov rax, rdx
    shl rax, 3                ; index * 8
    mov rdx, [r13 + rax]      ; value
    call dict_set
    inc qword [rbp - CKM_I]
    jmp .bckm_fill

.bckm_done:
    ; DECREF values from stack
    mov rcx, [rbp - CKM_COUNT]
    test rcx, rcx
    jz .bckm_push
    xor edx, edx
.bckm_fixref:
    cmp rdx, rcx
    jge .bckm_decref_keys
    mov rax, rdx
    shl rax, 3                ; index * 8
    mov rdi, [r13 + rax]
    push rdx
    push rcx
    DECREF_V rdi, rsi
    pop rcx
    pop rdx
    inc rdx
    jmp .bckm_fixref

.bckm_decref_keys:
    ; DECREF keys tuple
    mov rdi, [rbp - CKM_KEYS]
    call obj_decref

.bckm_push:
    mov rax, [rbp - CKM_DICT]
    VPUSH_PTR rax
    leave
    DISPATCH
END_FUNC op_build_const_key_map


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
    V_UNPACK rax, rdx           ; returns a Value
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
    ; A frame of its own for the call, and an odd one: a handler is entered
    ; 16-aligned, so `push rbp` alone leaves rsp 8 out.
    push rbp
    mov rbp, rsp
    sub rsp, 8
    extern seq_iter_new
    call seq_iter_new          ; creates seq_iter wrapping obj
    leave
    jmp .have_iter_result

.not_iterable:
    RAISE exc_TypeError_type, "object is not iterable"
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
    ; Snapshot what was pending before the step.  current_exception doubles
    ; as "the exception being handled", so inside an `except` block it is
    ; non-NULL for reasons that have nothing to do with this iterator; only
    ; a *change* across the call means the iterator raised.
    push qword [gs:ThreadState.current_exception]

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
    test rax, rax
    jnz .check_next_result     ; got a value
    jmp .next_null

.have_iternext:
    call rax
.check_next_result:
    ; rax is the Value tp_iternext or __next__ returned, and 0 means
    ; exhausted.  Both used to be V_UNPACKed here purely so that the tag
    ; could be tested for NULL.  0 is the only NULL encoding -- integer 0 is
    ; V_INT_BIAS -- so the raw test is exact.
    test rax, rax
    jnz .next_got_value

.next_null:
    ; A NULL result means exhaustion unless the step left a *new* exception.
    ; This check used to guard the __next__ path alone, so an exception
    ; raised inside a *generator* -- which has a real tp_iternext -- ended
    ; the loop silently and surfaced only at interpreter exit.
    mov rax, [gs:ThreadState.current_exception]
    cmp rax, [rsp]             ; unchanged from before the step?
    je .exhausted
    test rax, rax
    jz .exhausted

    extern exc_StopIteration_type
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel exc_StopIteration_type]
    cmp rcx, rdx
    jne .next_propagate        ; a real error ends the loop by raising

    ; A StopIteration reaching here is the exhaustion signal itself; put back
    ; whatever was being handled before.
    mov rdi, rax
    call obj_decref
    mov rax, [rsp]
    mov [gs:ThreadState.current_exception], rax
    jmp .exhausted

.next_propagate:
    add rsp, 16                ; discard the saved exception and jump offset
    PUBLISH_SP
    extern eval_exception_unwind
    jmp eval_exception_unwind

.next_got_value:

    ; Got a value - push it (iterator stays on stack)
    add rsp, 16                ; discard saved exception and jump offset
    VPUSH rax

    ; Skip 1 CACHE entry = 2 bytes
    add rbx, 2
    DISPATCH

.exhausted:
    ; CPython 3.12: FOR_ITER exhausted pops the iterator and jumps by (arg + 1)
    ; instruction words past the CACHE. The +1 skips the END_FOR instruction.
    add rsp, 8                 ; drop the saved exception snapshot
    pop rcx                    ; restore jump offset
    lea rcx, [rcx + 1]        ; arg + 1 (skip END_FOR too)
    add rbx, 2                 ; skip cache first
    lea rbx, [rbx + rcx*2]    ; then jump forward

    ; Now pop and DECREF the iterator (safe: rbx/r13 are callee-saved)
    VPOP rdi
    DECREF_V rdi, rsi

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
    VPOP rdi
    DECREF_V rdi, rsi
    ; Pop the iterator
    VPOP rdi
    DECREF_V rdi, rsi
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
    V_PACK rsi, rdx         ; list_append takes a Value
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
; CURSOR holds the items pointer on the fast path, the iterator on the slow one
LE_LIST     equ 8
LE_ITERABLE equ 16
LE_COUNT    equ 24
LE_CURSOR   equ 32
LE_EXC      equ 40        ; current_exception before the iteration started
LE_I        equ 48        ; the loop index, which used to be pushed across
                          ; list_append -- a lone push leaves the call 8 out
LE_TYPE     equ 56        ; the operand's type, for the message
DEF_FUNC op_list_extend, 72   ; + 0 pushes; a handler is entered ALIGNED, so this is 8 mod 16
    ; locals: [rbp - LE_LIST]=list, [rbp - LE_ITERABLE]=iterable, [rbp - LE_COUNT]=count, [rbp - LE_CURSOR]=items

    ; TOS = iterable
    VPOP_VAL rsi, r8           ; rsi = iterable (tuple or list)
    mov [rbp - LE_ITERABLE], rsi          ; save iterable
    ; Its type, for the message, resolved from the TAG: an int or a float has
    ; no ob_type to read.
    extern int_type
    extern float_type
    lea rax, [rel int_type]
    cmp r8d, TAG_PTR
    je .le_ptr_type
    cmp r8d, TAG_FLOAT
    jne .le_type_stored
    lea rax, [rel float_type]
    jmp .le_type_stored
.le_ptr_type:
    mov rax, [rsi + PyObject.ob_type]
.le_type_stored:
    mov [rbp - LE_TYPE], rax
    cmp r8d, TAG_PTR
    jne .extend_type_error

    ; list is at stack[-(ecx)] after popping (payload slots)
    neg rcx
    shl rcx, 3                ; -ecx * 8
    mov rdi, [r13 + rcx]      ; rdi = list
    mov [rbp - LE_LIST], rdi           ; save list

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

    ; A tuple and a list are the same shape here -- a contiguous Value array
    ; and a size -- and only the field offsets differ.  Both hand the whole
    ; run to list_extend_from_array, which grows once and copies once; they
    ; used to call list_append per element, so a twenty-item list literal
    ; (which is BUILD_LIST 0 + LOAD_CONST tuple + LIST_EXTEND) walked the
    ; whole doubling curve.
.extend_tuple:
    mov rdx, [rsi + PyTupleObject.ob_size]
    mov rsi, [rsi + PyTupleObject.ob_item]
    jmp .extend_from_array

.extend_list:
    mov rdx, [rsi + PyListObject.ob_size]
    mov rsi, [rsi + PyListObject.ob_item]

.extend_from_array:
    mov rdi, [rbp - LE_LIST]
    extern list_extend_from_array
    call list_extend_from_array
    jmp .extend_done

.extend_generic:
    ; get_iterator_opt, not a tp_iter read: an object with __getitem__
    ; and no __iter__ is iterable, and the slot read rejected it.
    ; This is what `f(*seq)`, `[*seq]` and `(*seq,)` compile to.
    mov rdi, [rbp - LE_ITERABLE]         ; iterable
    mov esi, TAG_PTR
    call get_iterator_opt
    test rax, rax
    jz .extend_type_error
    mov [rbp - LE_CURSOR], rax          ; save iterator (reusing locals slot)

    DUNDER_EXC_SAVE [rbp - LE_EXC]
.extend_generic_loop:
    mov rdi, [rbp - LE_CURSOR]         ; iterator
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .extend_generic_done
    mov rdi, [rbp - LE_CURSOR]
    call rax                   ; tp_iternext(iter) → (payload, tag)
    V_UNPACK rax, rdx           ; tp_iternext returns a Value
    test edx, edx
    jz .extend_generic_done    ; StopIteration

    ; Append to list
    push rax
    push rdx
    mov rdi, [rbp - LE_LIST]          ; list
    mov rsi, rax
    ; edx = tag (already set)
    V_PACK rsi, rdx         ; list_append takes a Value
    call list_append
    ; DECREF item (list_append INCREFs)
    pop rsi                    ; tag
    pop rdi                    ; payload
    DECREF_VAL rdi, rsi
    jmp .extend_generic_loop

.extend_generic_done:
    ; DECREF iterator
    mov rdi, [rbp - LE_CURSOR]
    call obj_decref

    ; tp_iternext answers NULL for a clean exhaustion and for a __next__ that
    ; raised alike, and eb7cdce made the second reachable from ordinary code
    ; by enabling the legacy __getitem__ protocol.  Without the distinction
    ; `[*G()]` for a G whose __getitem__ throws built a short list and left
    ; the exception to surface at some later, unrelated instruction.
    EXC_RAISED_SINCE [rbp - LE_EXC], rcx, .extend_generic_raised

.extend_done:
    ; DECREF iterable
    mov rdi, [rbp - LE_ITERABLE]
    call obj_decref

    leave
    DISPATCH

.extend_generic_raised:
    ; The iterable is not released here.  The unwinder restores r13 to the
    ; value stack as it stood before this instruction ran, where VPOP_VAL had
    ; not yet taken the iterable off it, so the unwind owns that reference.
    extern eval_exception_unwind
    leave
    jmp eval_exception_unwind

.extend_type_error:
    ; LIST_EXTEND is what `*x` compiles to in a display and in a call with
    ; more than one positional group, and CPython words its refusal by the
    ; SYNTAX rather than by the opcode: "Value after * must be an iterable,
    ; not int".  list.extend() the method keeps its own message, which is a
    ; different one again.
    mov rsi, [rbp - LE_TYPE]
    CSTRING rdi, `Value after * must be an iterable, not \x01`
    extern raise_type_error_with_typename
    jmp raise_type_error_with_typename
END_FUNC op_list_extend

;; ============================================================================
;; op_is_op - Identity comparison (is / is not)
;;
;; ecx = 0 for 'is', 1 for 'is not'
;; Pop right, pop left, push True/False.
;; ============================================================================
DEF_FUNC_BARE op_is_op
    mov r8d, ecx               ; the invert flag

    VPOP rsi                   ; right
    VPOP rdi                   ; left

    ; A Value is a canonical bit pattern, so identity IS bit equality: a
    ; pointer is its own Value, an integer immediate is unique per value, and
    ; a float per bit pattern.  This used to V_UNPACK both sides and compare
    ; payload and tag separately -- the same question, in twenty times the
    ; instructions -- under a comment saying the tag was needed "for SmallInt
    ; correctness".  It is the encoding that provides that, not the tag.
    xor eax, eax
    cmp rdi, rsi
    sete al

    ; Release both.  DECREF_V reaches obj_dealloc, which clobbers every
    ; caller-saved register, so the answer and the operands go on the machine
    ; stack -- four slots, an even number, because rsp is 16-byte aligned on
    ; entry to a handler.
    push rax
    push r8
    push rdi                   ; left
    push rsi                   ; right
    mov rdi, rsi
    DECREF_V rdi, rdx
    add rsp, 8                 ; the right operand, released
    pop rdi                    ; the left
    DECREF_V rdi, rdx
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
    ; The shape `in` almost always has: a container with an sq_contains, which
    ; is every builtin one -- set, frozenset, dict, list, tuple, str, bytes.
    ;
    ; Both operands are already Values on the stack, and sq_contains takes a
    ; Value, so nothing here needs unpacking or repacking.  The protocol below
    ; keeps the __contains__ and iteration fallbacks and the error wording, and
    ; reaches them having touched neither r13 nor rcx.
    mov rsi, [r13 - 8]              ; the container
    V_TEST_PTR rsi, rax
    ja .contains_generic
    mov rax, [rsi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .contains_generic
    mov rax, [rax + PySequenceMethods.sq_contains]
    test rax, rax
    jz .contains_generic

    mov rdi, rsi                    ; the container
    mov rsi, [r13 - 16]             ; the value to find
    push rcx                        ; the invert flag
    sub rsp, 8                      ; one push is odd; rsp must be 16-aligned
    call rax
    add rsp, 8
    pop rcx
    ; r15 is free by the register convention and callee-saved, so it carries
    ; the answer across the two releases below -- either can call obj_dealloc,
    ; and that clobbers every caller-saved register.
    mov r15d, eax
    xor r15d, ecx                   ; `not in` inverts

    mov rdi, [r13 - 8]
    DECREF_V rdi, rdx
    mov rdi, [r13 - 16]
    DECREF_V rdi, rdx
    sub r13, 16

    lea rax, [rel bool_false]
    test r15d, r15d
    jz .contains_push
    lea rax, [rel bool_true]
    jmp .contains_push

.contains_generic:
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

    ; Call sq_contains(container, value Value) -> 0/1
    mov rdi, [rsp]             ; container
    mov rsi, [rsp + 8]        ; value
    mov rdx, [rsp + CN_LTAG]  ; value tag
    V_PACK rsi, rdx
    ; Five saved words is an odd number of slots, and rsp is 16-byte aligned
    ; on entry to a handler.  The pad is local to the call rather than added
    ; to the prologue, because this handler has a dozen exits and each unwinds
    ; the saved words itself.
    sub rsp, 8
    call rax
    add rsp, 8
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
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx             ; TAG_NULL = not found
    jz .contains_check_blocked

    ; Convert result to boolean (obj_is_true)
    push rdx                   ; save tag
    push rax                   ; save payload
    mov rdi, rax
    mov rsi, rdx
    extern obj_is_true
    extern obj_richcompare_bool
    V_PACK rdi, rsi
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

.contains_check_blocked:
    ; dunder_call_2 answers NULL both for "no __contains__" and for
    ; "__contains__ is None".  In Python the second explicitly disables the
    ; protocol, so it is a TypeError rather than licence to iterate.  The
    ; distinction only became observable once __iter__ reached tp_iter and
    ; the iteration fallback actually worked.
    mov rdi, [rsp]
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel dunder_contains]
    extern dunder_lookup
    call dunder_lookup
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    jz .contains_iter_fallback  ; genuinely not defined
    IS_NONE rax, rcx
    je .contains_type_error

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
    mov rcx, [gs:ThreadState.current_exception]
    push rcx                     ; what was in flight before the loop, so a
                                 ; NULL below can be told from an exhaustion
    push rax                     ; save iterator (+16 shift now)

.contains_iter_loop:
    ; Call tp_iternext(iterator) → (rax=payload, edx=tag) or (0, TAG_NULL)
    mov rdi, [rsp]              ; iterator
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    V_UNPACK rax, rdx           ; tp_iternext returns a Value
    test edx, edx
    jz .contains_iter_not_found  ; TAG_NULL = exhausted

    ; Identity check: payload and tag both match → found
    ; +8 for iterator push on stack
    cmp rax, [rsp + 16 + CN_LEFT]
    jne .contains_iter_try_eq
    cmp edx, [rsp + 16 + CN_LTAG]
    je .contains_iter_found_decref

.contains_iter_try_eq:
    ; obj_richcompare_bool answers for every combination of representations
    ; and propagates a raising __eq__.  What stood here open-coded the
    ; comparison instead, and handled exactly two shapes: both SmallInt, or a
    ; TAG_PTR element.  A SmallInt element against a heap-int value fell
    ; through to identity and answered False -- so `98 in memoryview(b"abc..")`
    ; was False while `98 in list(mv)` was True, and every int outside the
    ; immediate range disagreed with itself depending on which side it sat on.
    push rax                     ; save elem payload
    push rdx                     ; save elem tag
    mov rdi, rax
    mov rsi, rdx
    V_PACK rdi, rsi              ; element -> Value
    mov rsi, [rsp + 16 + 16 + CN_LEFT]
    mov rcx, [rsp + 16 + 16 + CN_LTAG]
    push rdi
    sub rsp, 8                   ; keep rsp 16-aligned across the call
    V_PACK rsi, rcx              ; the searched value -> Value
    mov rdi, [rsp + 8]
    mov edx, 2                   ; PY_EQ, set last: V_PACK can box, and the
                                 ; call that boxes clobbers rdx
    call obj_richcompare_bool
    add rsp, 16
    test eax, eax
    jl .contains_iter_eq_raised
    test eax, eax
    pop rdx                      ; elem tag
    pop rax                      ; elem payload
    jnz .contains_iter_found_decref_elem
    jmp .contains_iter_loop

.contains_iter_eq_raised:
    ; __eq__ raised.  Drop the element and the iterator and let the pending
    ; exception through rather than answering False.
    pop rdx
    pop rax
    mov rdi, rax
    mov rsi, rdx
    DECREF_VAL rdi, rsi
    pop rdi                      ; iterator
    call obj_decref
    ; The two operands stay untouched.  They came off the value stack, and the
    ; unwinder walks that stack and releases what is on it -- releasing them
    ; here as the non-raising exits do would be one decref too many, and for
    ; `x in iter(...)`, where the container IS the iterator, freed the object
    ; the unwinder then read.  rsp needs no repair either: the unwinder
    ; restores it from eval_base_rsp, which is how every RAISE in this file
    ; leaves the machine stack.
    extern eval_exception_unwind
    jmp eval_exception_unwind

.contains_iter_raised:
    ; Same reasoning as .contains_iter_eq_raised: the operands came off the
    ; value stack and the unwinder releases them, and it restores rsp from
    ; eval_base_rsp, so the saved slot needs no repair.
    jmp eval_exception_unwind

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
    add rsp, 8                   ; the saved exception
    mov eax, 1                   ; found
    jmp .contains_iter_result

.contains_iter_not_found:
    ; DECREF iterator
    pop rdi                      ; iterator
    call obj_decref
    ; NULL from tp_iternext is a clean exhaustion and a raise alike, and
    ; answering False for the second buried it: `99 in gen()` for a generator
    ; that throws returned False, and the exception surfaced later at some
    ; unrelated instruction.  The comparison is against what was in flight
    ; before the loop, not against 0 -- inside an `except` block
    ; current_exception already holds the exception being handled.
    mov rcx, [gs:ThreadState.current_exception]
    test rcx, rcx
    jz .contains_iter_nf_done
    cmp rcx, [rsp]
    jne .contains_iter_raised
.contains_iter_nf_done:
    add rsp, 8                   ; the saved exception
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
    ; The exception that was already pending, if any: current_exception is
    ; also the exception BEING HANDLED, so a bare test for non-NULL below said
    ; "__getitem__ raised" for every lookup made inside an `except` block.
    ; r15 is the handler scratch register the eval loop leaves free, and a
    ; call preserves it.
    DUNDER_EXC_SAVE r15
    ; Probe __getitem__ exists by trying index 0
    push qword 0                 ; push index counter (+8 shift)

.contains_gi_loop:
    mov rdi, [rsp + 8 + CN_RIGHT]  ; container
    mov rsi, [rsp]                  ; index (SmallInt value)
    extern dunder_getitem
    lea rdx, [rel dunder_getitem]
    mov ecx, TAG_SMALLINT           ; index is SmallInt
    call dunder_call_2
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jz .contains_gi_null_result
    ; Check for exception (IndexError = stop)
    EXC_RAISED_SINCE r15, rcx, .contains_gi_check_exc
    jmp .contains_gi_got_elem

.contains_gi_null_result:
    ; TAG_NULL: either dunder not found, or exception raised
    EXC_RAISED_SINCE r15, rcx, .contains_gi_check_exc
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
    V_PACK rdi, rcx             ; left  -> Value
    V_PACK rsi, r8              ; right -> Value
    call rax
    V_UNPACK rax, rdx           ; tp_richcompare returns a Value
    push rax
    push rdx
    mov rdi, rax
    mov rsi, rdx
    V_PACK rdi, rsi
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
    mov rax, [gs:ThreadState.current_exception]
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel exc_IndexError_type]
    cmp rcx, rdx
    jne .contains_gi_reraise
    ; IndexError: clear exception and return not found
    mov rdi, rax
    mov qword [gs:ThreadState.current_exception], 0
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
    ; CPython names the type: "argument of type 'ValueError' is not iterable".
    ; The container is on the push frame as a (payload, tag) PAIR -- this
    ; handler is not converted -- so it has to become a Value before anything
    ; reads its type.  Only the NAME is wanted, so an immediate is replaced by
    ; a canonical one of its own kind rather than boxed: V_PACK on a wide
    ; smallint allocates, and this path raises rather than returning.
    mov rdi, [rsp + CN_RIGHT]
    mov rdx, [rsp + CN_RTAG]
    cmp edx, TAG_PTR
    je .cte_named
    cmp edx, TAG_FLOAT
    je .cte_float
    mov rdi, V_INT(0)           ; any int immediate names `int`
    jmp .cte_named
.cte_float:
    xor edi, edi                ; 0.0 names `float`
    V_FROM_F64 rdi, rax
.cte_named:
    CSTRING rsi, "argument of type '"
    CSTRING rdx, "' is not iterable"
    sub rsp, 8                  ; five pushes: realign before the call, which
                                ; does not return, so nothing undoes this
    extern raise_typed_message
    call raise_typed_message
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

    ; Call mp_subscript(obj, slice, key_tag).  All three of these loads ran
    ; unguarded: the object may be an immediate, whose payload is not an
    ; address, and a real object may have no mapping methods at all.  5[0:1]
    ; and obj[1:2] on any user class were both SIGSEGV.
    mov rdi, [rbp - BSLC_OBJ]
    cmp qword [rbp - BSLC_OTAG], TAG_PTR
    jne .bslc_not_subscriptable
    mov rsi, rax           ; slice as key
    mov edx, TAG_PTR       ; key tag = slice (always TAG_PTR)
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .bslc_try_dunder
    mov rax, [rax + PyMappingMethods.mp_subscript]
    test rax, rax
    jz .bslc_try_dunder
    call rax               ; rsi is a slice pointer, already a Value
    V_UNPACK rax, rdx      ; mp_subscript returns a Value

.bslc_have_result:
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

.bslc_try_dunder:
    ; A user class defines __getitem__ instead of filling mp_subscript.
    mov rdi, [rbp - BSLC_OBJ]
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .bslc_not_subscriptable
    mov rsi, [rbp - BSLC_SLICE]
    lea rdx, [rel dunder_getitem]
    mov ecx, TAG_PTR
    call dunder_call_2
    V_UNPACK rax, rdx
    test edx, edx
    jz .bslc_not_subscriptable
    jmp .bslc_have_result

.bslc_not_subscriptable:
    RAISE exc_TypeError_type, "object is not subscriptable"
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

    ; Call mp_ass_subscript(obj, slice, value, key_tag, value_tag).  As in
    ; op_binary_slice, none of these three loads was guarded.
    mov rdi, [rbp - SSLC_OBJ]
    cmp qword [rbp - SSLC_OTAG], TAG_PTR
    jne .sslc_no_ass
    mov rsi, rax           ; slice
    mov rdx, [rbp - SSLC_VAL]
    mov r8, [rbp - SSLC_VTAG]     ; value tag
    V_PACK rdx, r8                 ; mp_ass_subscript takes a value Value
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .sslc_try_dunder
    mov rax, [rax + PyMappingMethods.mp_ass_subscript]
    test rax, rax
    jz .sslc_try_dunder
    call rax

.sslc_stored:

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

.sslc_try_dunder:
    ; A user class defines __setitem__ instead of filling mp_ass_subscript.
    mov rdi, [rbp - SSLC_OBJ]
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .sslc_no_ass
    mov rsi, [rbp - SSLC_SLICE]
    mov rdx, [rbp - SSLC_VAL]   ; dunder_call_3 takes the value's payload and
    mov r8, [rbp - SSLC_VTAG]   ; tag separately, not a packed Value
    extern dunder_setitem
    extern dunder_call_3
    lea rcx, [rel dunder_setitem]
    call dunder_call_3
    jmp .sslc_stored

.sslc_no_ass:
    RAISE exc_TypeError_type, "object does not support slice assignment"
END_FUNC op_store_slice

;; ============================================================================
;; op_map_add - Add key:value to dict at stack position
;;
;; MAP_ADD (147): used by dict comprehensions
;; TOS = value, TOS1 = key
;; dict is at stack[-(ecx+2)] relative to current TOS (before pops)
;; ============================================================================
DEF_FUNC op_map_add, 8    ; + 4 pushes at the call; a handler is entered ALIGNED,
                          ; so frame + pushes must be 8 mod 16
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
    mov rcx, [rsp + MA_VTAG]  ; value tag
    mov r8, [rsp + MA_KTAG]   ; key tag
    V_PACK rsi, r8            ; dict_set takes Values
    V_PACK rdx, rcx
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

DU_SOURCE   equ 24
DU_DICT     equ 32
DU_SRC      equ 40          ; the source dict; entries and the bound are read
                            ;   from it every turn, never cached
DU_KEYV     equ 48          ; key and value, held across dict_set: both are
DU_VALV     equ 56          ;   borrowed from a table user code can empty
DU_ORIGN    equ 64          ; the source's dk_nentries when the walk started
DEF_FUNC op_dict_update
    push rbx
    push r14                   ; extra callee-saved
    sub rsp, 64                ; locals + alignment

    VPOP_VAL rsi, r8           ; rsi = mapping to merge from
    cmp r8d, TAG_PTR
    jne .du_not_mapping_val    ; an int or a float is not a mapping either
    mov [rbp - DU_SOURCE], rsi

    ; dict is at stack[-(ecx)] after pop (payload slots)
    neg rcx
    shl rcx, 3                ; -ecx * 8
    mov rdi, [r13 + rcx]
    mov [rbp - DU_DICT], rdi          ; target dict

    ; A real dict takes the dense walk below.  Anything else is read the way
    ; dict.update reads it -- through keys() and indexing -- which is the same
    ; resolution DICT_MERGE reaches for `f(**m)`, and the same one CPython's
    ; BUILD_MAP/DICT_UPDATE pair makes.  Gating on "must be a dict" meant
    ; `{**os.environ, 'K': v}`, which is how a child environment is built, was
    ; a TypeError.
    mov rax, [rsi + PyObject.ob_type]
    REQUIRE_DICT_TYPE rax, rdx, .du_mapping

    ; Iterate over the source's DENSE array, with room taken once.
    mov rdi, [rbp - DU_DICT]
    push rsi                    ; ONE push: these handlers carve an odd frame,
                                ; so a single push is what re-aligns the call
    mov rsi, [rsi + PyDictObject.ob_size]
    call dict_reserve
    pop rsi
    mov [rbp - DU_SRC], rsi
    mov rax, [rsi + PyDictObject.dk_nentries]
    mov [rbp - DU_ORIGN], rax
    xor ebx, ebx              ; index

.du_loop:
    ; The bound AND the entry array come from the source header every turn.
    ; dict_set runs user code -- __hash__ and __eq__ on the target's keys --
    ; and that code can clear the source, which frees the table this used to
    ; hold in a frame slot and points the dict at the one-slot read-only
    ; dict_empty_entries.  Cached, the walk then read a freed array to a
    ; stale bound and inserted what it found.
    mov rax, [rbp - DU_SRC]
    cmp rbx, [rax + PyDictObject.dk_nentries]
    jge .du_done

    ; Check if entry has a key and value_tag != TAG_NULL
    mov rax, [rax + PyDictObject.entries]
    imul rcx, rbx, DictEntry_size
    add rax, rcx
    mov rsi, [rax + DictEntry.key]
    test rsi, rsi
    jz .du_next
    mov rdx, [rax + DictEntry.value]

    ; Both are borrowed out of that table, so both are held for the call.
    mov [rbp - DU_KEYV], rsi
    mov [rbp - DU_VALV], rdx
    INCREF_V rsi, rcx
    INCREF_V rdx, rcx

    ; dict_set(target, key, value, value_tag, key_tag)
    push rbx
    mov rdi, [rbp - DU_DICT]
    call dict_set
    pop rbx
    push rbx
    mov rdi, [rbp - DU_KEYV]
    DECREF_V rdi, rcx
    mov rdi, [rbp - DU_VALV]
    DECREF_V rdi, rcx
    pop rbx

    ; And say so.  CPython's dict_merge compares the source's dk_nentries
    ; against what it was after every insert, with this wording.
    mov rax, [rbp - DU_SRC]
    mov rax, [rax + PyDictObject.dk_nentries]
    cmp rax, [rbp - DU_ORIGN]
    jne .du_mutated

.du_next:
    inc rbx
    jmp .du_loop

.du_done:
    ; DECREF the mapping.  The pad is the alignment: the loop above reaches
    ; its calls one push deep, so the frame is sized for that, and a call made
    ; at depth zero is the odd one out.
    mov rdi, [rbp - DU_SOURCE]
    push rdi
    call obj_decref
    pop rdi

    add rsp, 64
    pop r14
    pop rbx
    leave
    DISPATCH

.du_mapping:
    ; This handler carves an odd frame, so everything below it calls eight
    ; bytes out without a pad -- the same reason the dense walk above pushes
    ; one.  `leave` puts rsp back, so no exit has to undo this.
    sub rsp, 8
    ; `{**x}` wants a MAPPING.  dict.update also takes a sequence of pairs,
    ; and letting it have that here would make `{**"ab"}` a ValueError about
    ; element lengths where CPython says the str is not a mapping -- so the
    ; keys() test is made first, as DICT_MERGE makes it.
    CSTRING rdi, "keys"
    extern str_from_cstr_heap
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, [rbp - DU_SOURCE]
    mov rsi, rbx
    extern obj_getattr_opt
    call obj_getattr_opt
    mov r14, rax
    mov rdi, rbx
    extern obj_decref
    call obj_decref
    test r14, r14
    jz .du_keys_missing
    ; A Value, so DECREF_V: obj_decref writes through what it is handed, and
    ; `class M: keys = 1` then `{**M()}` decremented address 1.
    DECREF_V r14, rcx           ; the bound keys, wanted only as a test

    ; dict_method_update(args, nargs) with args = [target, source].  It owns
    ; how a mapping is read -- keys() and indexing -- so that is not repeated.
    sub rsp, 16
    mov rax, [rbp - DU_DICT]
    mov [rsp], rax
    mov rax, [rbp - DU_SOURCE]
    mov [rsp + 8], rax
    ; kw_names_pending belongs to whatever CALL is in flight; dict.update
    ; consumes it, so park it across the call rather than letting the callee
    ; eat a keyword tuple that is not its own.
    mov rbx, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov rdi, rsp
    mov esi, 2
    extern dict_method_update
    call dict_method_update
    mov [gs:ThreadState.kw_names_pending], rbx
    add rsp, 16
    test rax, rax
    jz .du_propagate
    DECREF_V rax, rcx           ; update() answers None
    ; And the SOURCE, whose reference came off the stack with the pop.  The
    ; dense walk above releases it at .du_done and this arm did not, so every
    ; `{**m}` over anything but a dict pinned the mapping: five of them took a
    ; refcount from 2 to 7.  Only this exit needs it -- an unwind releases what
    ; the frame was holding, which is why the refusal below does not.
    mov rdi, [rbp - DU_SOURCE]
    DECREF_V rdi, rcx
    add rsp, 72                 ; 64 + the alignment pad taken at .du_mapping
    pop r14
    pop rbx
    leave
    DISPATCH

.du_keys_missing:
    ; obj_getattr_opt answers 0 both for "there is no keys" and for "looking
    ; for it raised", so the two have to be told apart here: a `keys` property
    ; that raises is not a report that the object is not a mapping.
    cmp qword [gs:ThreadState.current_exception], 0
    jne .du_propagate
    jmp .du_not_mapping

.du_propagate:
    add rsp, 72                 ; as above: rbx is the bytecode IP, so the
    pop r14                     ; pops must come off at the right depth
    pop rbx
    leave
    jmp eval_exception_unwind

.du_mutated:
    extern exc_RuntimeError_type
    RAISE exc_RuntimeError_type, "dict mutated during update"

.du_not_mapping_val:
    ; A non-pointer operand, still named by its type: V_PACK rebuilds the
    ; Value that raise_type_error_with_name wants.
    mov rdx, r8
    V_PACK rsi, rdx
    jmp .du_name_it

.du_not_mapping:
    ; CPython's wording for `{**x}` where x has no keys().
    mov rsi, [rbp - DU_SOURCE]
.du_name_it:
    CSTRING rdi, `'\x01' object is not a mapping`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.du_type_error:
    RAISE exc_TypeError_type, "dict.update() argument must be a dict"
END_FUNC op_dict_update

;; ============================================================================
;; op_dict_merge - Merge dict (like dict_update but for **kwargs)
;;
;; DICT_MERGE (164): like DICT_UPDATE but raises TypeError on duplicate keys
;; Used for f(**a, **b) — duplicate keys across ** spreads are errors.
;; ============================================================================
extern dict_get

DM_SOURCE   equ 24
DM_DICT     equ 32
DM_SRC      equ 40          ; the source dict; see DU_SRC above
DM_KEYV     equ 48          ; key and value, held across dict_get/dict_set
DM_VALV     equ 56
DM_ORIGN    equ 64          ; the source's dk_nentries when the walk started
DM_FUNC     equ 80          ; the callable, for the message
DM_TEMP     equ 88          ; a dict built from a non-dict mapping, or 0
DM_TYPE     equ 96          ; the source's type, for the message
DEF_FUNC op_dict_merge
    push rbx
    push r14
    ; 64, not 48: the two pushes above put the first slot at [rbp - 24], so
    ; the last one -- DM_TYPE at 72 -- needs 72 - 16 bytes of frame under it.
    ; The parity is unchanged, which is what the handler rule cares about.
    sub rsp, 96

    mov qword [rbp - DM_TEMP], 0

    VPOP_VAL rsi, r8           ; rsi = mapping to merge from
    mov [rbp - DM_SOURCE], rsi

    ; The callable sits under the map, the args tuple and its own NULL, which
    ; is where CPython peeks for it: every refusal CALL_FUNCTION_EX makes
    ; names the callable, and this one is made on its behalf.
    mov rax, rcx
    add rax, 2
    neg rax
    shl rax, 3
    mov rax, [r13 + rax]
    mov [rbp - DM_FUNC], rax

    ; ...and the source's TYPE, resolved from the tag: an int or a float is
    ; not an object with an ob_type to read.
    cmp r8d, TAG_PTR
    jne .dm_immediate_type
    mov rax, [rsi + PyObject.ob_type]
    mov [rbp - DM_TYPE], rax

    ; dict is at stack[-(ecx)] after pop (payload slots)
    neg rcx
    shl rcx, 3
    mov rdi, [r13 + rcx]
    mov [rbp - DM_DICT], rdi          ; target dict

    ; A dict merges directly.  Anything ELSE with a `keys` is a mapping, and
    ; `f(**mapping)` is legal over one: CPython's DICT_MERGE takes the same
    ; path dict.update() does.  Building a dict from it is what dict.update
    ; would do anyway, and keeps one merge loop rather than two.
    REQUIRE_DICT_TYPE rax, rdx, .dm_try_mapping
.dm_have_dict:

    ; Iterate over the source's DENSE array, with room taken once.
    mov rdi, [rbp - DM_DICT]
    push rsi                    ; ONE push: these handlers carve an odd frame,
                                ; so a single push is what re-aligns the call
    mov rsi, [rsi + PyDictObject.ob_size]
    call dict_reserve
    pop rsi
    mov [rbp - DM_SRC], rsi
    mov rax, [rsi + PyDictObject.dk_nentries]
    mov [rbp - DM_ORIGN], rax
    xor ebx, ebx              ; index

.dm_loop:
    ; Read from the source header every turn, and hold the two Values across
    ; both calls; see op_dict_update above for what a cached table costs.
    ; This loop makes TWO calls into user code per entry, dict_get's probe
    ; and dict_set's, so it had two chances at it.
    mov rax, [rbp - DM_SRC]
    cmp rbx, [rax + PyDictObject.dk_nentries]
    jge .dm_done

    mov rax, [rax + PyDictObject.entries]
    imul rcx, rbx, DictEntry_size
    add rax, rcx
    mov rsi, [rax + DictEntry.key]
    test rsi, rsi
    jz .dm_next
    mov rdx, [rax + DictEntry.value]
    mov [rbp - DM_KEYV], rsi
    mov [rbp - DM_VALV], rdx
    INCREF_V rsi, rcx
    INCREF_V rdx, rcx

    ; Check for duplicate: dict_get(target, key, key_tag).  dict_get returns
    ; its tag in edx, so the key tag must not be restored over it.
    push rbx
    mov rdi, [rbp - DM_DICT]          ; target dict
    call dict_get
    test rax, rax               ; dict_get answers with a Value; 0 is the miss
    jnz .dm_dup_error          ; key already exists in target

    ; dict_set(target, key, value, value_tag, key_tag)
    pop rbx
    mov rsi, [rbp - DM_KEYV]
    mov rdx, [rbp - DM_VALV]
    push rbx
    mov rdi, [rbp - DM_DICT]
    call dict_set
    pop rbx
    push rbx
    mov rdi, [rbp - DM_KEYV]
    DECREF_V rdi, rcx
    mov rdi, [rbp - DM_VALV]
    DECREF_V rdi, rcx
    pop rbx

    mov rax, [rbp - DM_SRC]
    mov rax, [rax + PyDictObject.dk_nentries]
    cmp rax, [rbp - DM_ORIGN]
    jne .dm_mutated

.dm_next:
    inc rbx
    jmp .dm_loop

.dm_done:
    ; DECREF the mapping.  The pad is the alignment: the loop above reaches
    ; its calls one push deep, so the frame is sized for that, and a call made
    ; at depth zero is the odd one out.
    mov rdi, [rbp - DM_TEMP]
    test rdi, rdi
    jz .dm_no_temp
    push rdi
    call obj_decref
    pop rdi
.dm_no_temp:
    mov rdi, [rbp - DM_SOURCE]
    push rdi
    call obj_decref
    pop rdi

    add rsp, 96
    pop r14
    pop rbx
    leave
    DISPATCH

.dm_try_mapping:
    ; `keys` is what makes something a mapping here, as it is for dict().
    CSTRING rdi, "keys"
    call str_from_cstr_heap
    push rax
    push rax                            ; pad
    mov rdi, [rbp - DM_SOURCE]
    mov rsi, rax
    extern obj_getattr_opt
    call obj_getattr_opt
    mov rbx, rax
    pop rdi
    pop rdi
    call obj_decref                     ; the name
    test rbx, rbx
    jz .dm_type_error
    mov rdi, rbx
    DECREF_V rdi, rcx                   ; the bound method; dict() calls it again

    ; dict(source) -- which honours keys() and __getitem__, and raises with
    ; its own wording if the mapping misbehaves halfway.
    sub rsp, 16
    mov rax, [rbp - DM_SOURCE]
    mov [rsp], rax
    extern dict_type_call
    extern dict_type
    lea rdi, [rel dict_type]
    mov rsi, rsp
    mov edx, 1
    call dict_type_call
    add rsp, 16
    test rax, rax
    jz .dm_propagate
    mov [rbp - DM_TEMP], rax
    mov rsi, rax
    jmp .dm_have_dict

.dm_propagate:
    PUBLISH_SP
    add rsp, 96
    pop r14
    pop rbx
    leave
    extern eval_exception_unwind
    jmp eval_exception_unwind

.dm_mutated:
    RAISE exc_RuntimeError_type, "dict mutated during update"

.dm_dup_error:
    pop rbx                    ; balance push from before dict_get
    ; The value's reference goes back now; the key's is wanted one line
    ; further on, and goes back after obj_str has read it.
    mov rdi, [rbp - DM_VALV]
    DECREF_V rdi, rcx
    ; CPython names the callable and the key: "f() got multiple values for
    ; keyword argument 'a'".  The key goes through str(), which is what
    ; CPython's %S does, so a non-str key reads as itself rather than
    ; crashing the formatter.
    mov rdi, [rbp - DM_KEYV]            ; still held; the table may be gone
    sub rsp, 8                  ; this handler carves an odd frame
    extern obj_str
    call obj_str
    add rsp, 8
    push rax
    push rax                            ; pad
    mov rdi, [rbp - DM_KEYV]
    DECREF_V rdi, rcx
    pop rax
    pop rax
    test rax, rax
    jz .dm_dup_plain
    mov [rbp - DM_TYPE], rax            ; the str, held while it is read
    mov rdi, [rbp - DM_FUNC]
    lea rsi, [rax + PyStrObject.data]
    CSTRING rdx, " got multiple values for keyword argument '"
    CSTRING rcx, "'"
    extern raise_callable_arg
    jmp raise_callable_arg
.dm_dup_plain:
    RAISE exc_TypeError_type, "got multiple values for keyword argument"

.dm_immediate_type:
    extern float_type
    extern int_type
    lea rax, [rel int_type]
    cmp r8d, TAG_FLOAT
    jne .dm_immediate_stored
    lea rax, [rel float_type]
.dm_immediate_stored:
    mov [rbp - DM_TYPE], rax
    jmp .dm_type_error

.dm_type_error:
    mov rdi, [rbp - DM_FUNC]
    mov rsi, [rbp - DM_TYPE]
    mov rsi, [rsi + PyTypeObject.tp_name]
    CSTRING rdx, " argument after ** must be a mapping, not "
    xor ecx, ecx
    extern raise_callable_arg
    jmp raise_callable_arg
END_FUNC op_dict_merge


;; ============================================================================
;; op_kw_names - Store keyword argument names for next CALL
;;
;; KW_NAMES (172): Store co_consts[arg] as pending kw_names tuple.
;; The next CALL opcode will use this tuple.
;; ============================================================================

DEF_FUNC_BARE op_kw_names
    ; ecx = arg (index into co_consts)
    mov rax, [gs:ThreadState.eval_co_consts]
    mov rax, [rax + rcx * 8]   ; payload (tuple ptr for kw_names)
    mov [gs:ThreadState.kw_names_pending], rax
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
extern frozenset_type
extern set_reserve

BSE_COUNT   equ 8
BSE_SET     equ 16
BSE_I       equ 24        ; the loop index, which used to be pushed across
                          ; set_add and DECREF_V -- a lone push leaves the
                          ; call 8 out, and that propagates
DEF_FUNC op_build_set, 24   ; + 0 pushes; a handler is entered ALIGNED, so this is 8 mod 16

    mov [rbp - BSE_COUNT], rcx           ; save count

    ; Allocate empty set
    call set_new
    mov [rbp - BSE_SET], rax          ; save set

    ; The element count is known, so take the room once.  A twenty-element
    ; literal grew its table twice on the way, rehashing everything each time.
    mov rdi, rax
    mov rsi, [rbp - BSE_COUNT]
    call set_reserve

    ; Pop items and add to set
    mov rcx, [rbp - BSE_COUNT]
    test rcx, rcx
    jz .build_set_done

    ; Calculate base of items on the value stack
    mov rdi, rcx
    shl rdi, 3
    sub r13, rdi               ; pop all items

    mov qword [rbp - BSE_I], 0
.build_set_fill:
    mov rdx, [rbp - BSE_I]
    cmp rdx, [rbp - BSE_COUNT]
    jge .build_set_done
    mov rdi, [rbp - BSE_SET]         ; set
    mov rax, rdx
    shl rax, 3                ; index * 8
    mov rsi, [r13 + rax]     ; item
    call set_add               ; set_add does INCREF
    inc qword [rbp - BSE_I]
    jmp .build_set_fill

.build_set_done:
    ; set_add does INCREF on key, so DECREF all stack items to compensate
    mov rcx, [rbp - BSE_COUNT]
    test rcx, rcx
    jz .build_set_push
    mov qword [rbp - BSE_I], 0
.build_set_fixref:
    mov rdx, [rbp - BSE_I]
    cmp rdx, [rbp - BSE_COUNT]
    jge .build_set_push
    mov rax, rdx
    shl rax, 3                ; index * 8
    mov rdi, [r13 + rax]
    DECREF_V rdi, rsi
    inc qword [rbp - BSE_I]
    jmp .build_set_fixref

.build_set_push:
    mov rax, [rbp - BSE_SET]
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
    mov rdx, r8
    V_PACK rsi, rdx            ; set_add takes a key Value
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
SU_SOURCE   equ 24
SU_SET      equ 32
SU_CAP      equ 40
SU_ENTRIES  equ 48
SU_EXC      equ 56        ; current_exception before the iteration started
SU_ITEM     equ 64        ; the item held across set_add, and its tag.  They
SU_ITAG     equ 72        ; used to be pushed, which left the call 8 out
DEF_FUNC op_set_update
    push rbx
    push r14
    sub rsp, 72                ; 56 plus the two slots above, which keeps
                               ; the parity: a handler is entered 16-byte
                               ; ALIGNED, so `push rbp` plus these two pushes
                               ; leave rsp 8 out and the frame is what puts it
                               ; back.  48 computed the ordinary-function rule.
                               ; locals: [rbp - SU_SOURCE]=set, [rbp - SU_SET]=iterable, [rbp - SU_CAP]=iter, [rbp - SU_ENTRIES]=iter_tag

    ; TOS = iterable
    VPOP_VAL rsi, rax          ; rsi = iterable
    mov [rbp - SU_ENTRIES], rax          ; iterable tag
    mov [rbp - SU_SET], rsi              ; ...and the value, for the message
    cmp eax, TAG_PTR
    jne .su_type_error
    mov [rbp - SU_SET], rsi          ; save iterable

    ; set is at stack[-(ecx)] after popping (payload slots)
    neg rcx
    shl rcx, 3                ; -ecx * 8
    mov rdi, [r13 + rcx]      ; rdi = set
    mov [rbp - SU_SOURCE], rdi          ; save set

    ; Take the room in one step whenever the source can say how big it is.
    ;
    ; A set literal of constants is a FROZENSET in co_consts plus BUILD_SET 0
    ; and SET_UPDATE, so `{1, 2, 3, 4, 5}` arrives here as an empty set and a
    ; five-element source -- and the empty set had to grow from the shared
    ; one-slot table to eight and then to thirty-two, two mallocs and two
    ; rehashes, to hold five ints.  set/frozenset/list/tuple all keep their
    ; element count at ob_size, and none of the four can lie about it.
    mov rax, [rsi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_SET_SUBCLASS
    jnz .su_presize
    lea rdx, [rel list_type]
    cmp rax, rdx
    je .su_presize
    lea rdx, [rel tuple_type]
    cmp rax, rdx
    jne .su_sized
.su_presize:
    mov rdi, [rbp - SU_SOURCE]              ; the set being updated
    mov rsi, [rsi + PyDictObject.ob_size]   ; +16 on all four types
    call set_reserve
    mov rsi, [rbp - SU_SET]                 ; the iterable again
.su_sized:

    ; A set or a frozenset is walked slot by slot: its own entry array is
    ; already the list of its elements, so an iterator object would be an
    ; allocation to answer a question the table answers.
    mov rax, [rsi + PyObject.ob_type]
    ; A set or a frozenset -- or a SUBCLASS of either.  Both static types
    ; carry TYPE_FLAG_SET_SUBCLASS and every subclass inherits it, so one
    ; test asks the whole question; the two exact-pointer compares this
    ; replaces sent a subclass down the generic iterator path, where its own
    ; __iter__ was asked.  CPython never asks: PyAnySet_Check sends every one
    ; of them to the table.
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_SET_SUBCLASS
    jnz .su_from_set

    ; Generic: get_iterator_opt, which also accepts the legacy __getitem__
    ; protocol.  `{*seq}` compiles to this.
    mov rdi, rsi
    mov esi, TAG_PTR
    call get_iterator_opt
    test rax, rax
    jz .su_type_error
    mov [rbp - SU_CAP], rax          ; save iterator

    DUNDER_EXC_SAVE [rbp - SU_EXC]
.su_iter_loop:
    mov rdi, [rbp - SU_CAP]          ; iterator
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    V_UNPACK rax, rdx           ; tp_iternext returns a Value
    test edx, edx
    jz .su_iter_done

    ; rax = next item (owned ref), rdx = tag from tp_iternext
    mov [rbp - SU_ITAG], rdx   ; save item tag
    mov [rbp - SU_ITEM], rax   ; save item payload
    mov rdi, [rbp - SU_SOURCE]          ; set
    mov rsi, rax               ; item
    V_PACK rsi, rdx            ; set_add takes a key Value
    call set_add               ; set_add does INCREF
    mov rdi, [rbp - SU_ITEM]
    mov rsi, [rbp - SU_ITAG]
    DECREF_VAL rdi, rsi        ; DECREF to compensate (set_add INCREF'd)
    jmp .su_iter_loop

.su_iter_done:
    ; DECREF iterator (heap ptr, no tag needed)
    mov rdi, [rbp - SU_CAP]
    call obj_decref

    ; NULL is exhaustion or a raise, and only the pending exception tells
    ; them apart: `{*G()}` for a raising __getitem__ built a short set.
    EXC_RAISED_SINCE [rbp - SU_EXC], rcx, .su_iter_raised

    ; DECREF iterable (tag-aware)
    mov rdi, [rbp - SU_SET]
    mov rsi, [rbp - SU_ENTRIES]
    DECREF_VAL rdi, rsi

    add rsp, 72
    pop r14
    pop rbx
    leave
    DISPATCH

.su_iter_raised:
    ; The iterable is left alone: the unwinder restores r13 to the stack as
    ; it stood before this instruction, where VPOP_VAL had not taken it off.
    extern eval_exception_unwind
    add rsp, 72
    pop r14
    pop rbx
    leave
    jmp eval_exception_unwind

.su_from_set:
    ; Iterable is a set or frozenset - iterate entries directly
    mov rax, [rsi + PyDictObject.capacity]
    mov [rbp - SU_CAP], rax          ; capacity (reuse slot)
    ; The source is a quarter full at most -- set_resize sizes from the live
    ; count and overshoots by four -- so the capacity is the wrong bound.
    ; r14 counts the live elements down; the capacity stays as the backstop,
    ; because set_add runs __eq__ and __eq__ can mutate the source.
    mov r14, [rsi + PyDictObject.ob_size]
    xor ebx, ebx              ; index

.su_set_loop:
    test r14, r14
    jz .su_set_done
    cmp rbx, [rbp - SU_CAP]
    jge .su_set_done

    mov rax, [rbp - SU_SET]         ; source set
    mov rax, [rax + PyDictObject.entries]
    lea rcx, [rbx + rbx]      ; SET_ENTRY_SIZE = 16, which two lea reach

    ; Check if entry has a key
    mov rsi, [rax + rcx*8 + 8]      ; SET_ENTRY_KEY offset = 8
    test rsi, rsi
    jz .su_set_next
    dec r14

    ; set_add(target_set, key Value)
    push rbx
    mov rdi, [rbp - SU_SOURCE]
    call set_add
    pop rbx

.su_set_next:
    inc rbx
    jmp .su_set_loop

.su_set_done:
    ; DECREF iterable (tag-aware)
    mov rdi, [rbp - SU_SET]
    mov rsi, [rbp - SU_ENTRIES]
    DECREF_VAL rdi, rsi

    add rsp, 72
    pop r14
    pop rbx
    leave
    DISPATCH

.su_type_error:
    ; CPython names the type: "'int' object is not iterable", which is what
    ; `{*5}` and `s.update(5)` both say.
    extern int_type
    extern float_type
    lea rsi, [rel int_type]
    mov rax, [rbp - SU_ENTRIES]
    cmp eax, TAG_PTR
    je .su_ptr_type
    cmp eax, TAG_FLOAT
    jne .su_have_type
    lea rsi, [rel float_type]
    jmp .su_have_type
.su_ptr_type:
    mov rsi, [rbp - SU_SET]
    mov rsi, [rsi + PyObject.ob_type]
.su_have_type:
    CSTRING rdi, `'\x01' object is not iterable`
    extern raise_type_error_with_typename
    jmp raise_type_error_with_typename
END_FUNC op_set_update

