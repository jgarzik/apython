; pyo/tuple.asm - Tuple type implementation
; Fat tuples: each element is 16 bytes (payload + tag) inline

%include "macros.inc"
%include "object.inc"

extern exc_TypeError_type
extern bool_true
extern bool_false
extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern ap_free
extern obj_decref
extern obj_dealloc
extern obj_hash
extern int_to_i64
extern fatal_error
extern raise_exception
extern exc_IndexError_type
extern obj_incref
extern slice_type
extern slice_indices
extern ap_memcpy
extern type_type
extern gc_untrack
extern obj_is_true
extern int_type
extern eval_exception_unwind
extern obj_richcompare_bool
extern obj_as_index
extern obj_as_index_seq
extern recursion_limit
extern c_recursion_depth
extern exc_RecursionError_type
extern int_fits_i64
extern exc_OverflowError_type
extern exc_MemoryError_type
extern str_type
extern bool_type
extern none_type

;; ============================================================================
;; tuple_new(int64_t size) -> PyTupleObject*
;; Allocate a tuple with room for 'size' fat items (16 bytes each), zero-filled
;; ============================================================================
DEF_FUNC tuple_new
    push rbx
    push r12

    mov r12, rdi                ; r12 = size (item count)

    ; Try pool for small tuples (size 1-3)
    cmp r12, 1
    je .try_pool_1
    cmp r12, 2
    je .try_pool_2
    cmp r12, 3
    je .try_pool_3
    jmp .alloc_fresh
.try_pool_1:
    lea rcx, [rel tuple_pool_1_head]
    jmp .try_pool
.try_pool_2:
    lea rcx, [rel tuple_pool_2_head]
    jmp .try_pool
.try_pool_3:
    lea rcx, [rel tuple_pool_3_head]
.try_pool:
    mov rax, [rcx + TUPLE_POOL_HEAD]  ; head
    test rax, rax
    jz .alloc_fresh
    mov rdx, [rax + PyObject.ob_refcnt]  ; next link
    mov [rcx + TUPLE_POOL_HEAD], rdx
    dec dword [rcx + 8]         ; count--
    mov qword [rax + PyObject.ob_refcnt], 1
    mov rbx, rax
    mov [rbx + PyTupleObject.ob_size], r12
    mov qword [rbx + PyTupleObject.ob_hash], -1
    jmp .zero_fill              ; zero items, skip gc_alloc+gc_track

.alloc_fresh:
    ; Allocate tuple header (GC-tracked)
    mov edi, PyTupleObject_size
    lea rsi, [rel tuple_type]
    call gc_alloc
    mov rbx, rax                ; rbx = new tuple (ob_refcnt=1, ob_type set)
    mov [rbx + PyTupleObject.ob_size], r12
    mov qword [rbx + PyTupleObject.ob_hash], -1  ; not computed

    ; Allocate the item array (if size > 0)
    test r12, r12
    jnz .alloc_arrays
    mov qword [rbx + PyTupleObject.ob_item], 0
    jmp .zero_fill
.alloc_arrays:
    mov rdi, r12
    shl rdi, 3                  ; size * 8
    call ap_malloc
    mov [rbx + PyTupleObject.ob_item], rax

.zero_fill:
    test r12, r12
    jz .done_pool
    mov rdi, [rbx + PyTupleObject.ob_item]
    xor eax, eax
    mov rcx, r12
.zero_payload_loop:
    mov [rdi], rax
    add rdi, 8
    dec rcx
    jnz .zero_payload_loop

.done_pool:
    ; Only gc_track if freshly allocated (pooled tuples are already tracked)
    ; Check: if tuple came from pool, ob_type is already set from previous use
    ; For fresh alloc, gc_alloc sets ob_type. We can skip gc_track for pooled.
    ; Pooled tuples were gc_untracked in dealloc, so we must gc_track them again.
    ;
    ; ...except an EMPTY one, which holds nothing and so can be part of no
    ; cycle.  CPython does not track it either: `gc.is_tracked(())` is False
    ; there and was True here, and walking every empty tuple in the heap on
    ; every collection buys nothing.
    test r12, r12
    jz .tn_untracked
    mov rdi, rbx
    call gc_track
.tn_untracked:

    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret
END_FUNC tuple_new

;; ============================================================================
;; tuple_getitem(PyTupleObject *tuple, int64_t index) -> (rax=payload, rdx=tag)
;; sq_item: Return fat tuple element with bounds check and INCREF_VAL
;; ============================================================================
DEF_FUNC_BARE tuple_getitem
    ; Handle negative index
    test rsi, rsi
    jns .positive
    add rsi, [rdi + PyTupleObject.ob_size]
.positive:
    ; Bounds check
    cmp rsi, [rdi + PyTupleObject.ob_size]
    jge .index_error
    test rsi, rsi
    jl .index_error
    mov rax, [rdi + PyTupleObject.ob_item]
    mov rax, [rax + rsi * 8]
    INCREF_V rax, rdx
    ret
.index_error:
    RAISE exc_IndexError_type, "tuple index out of range"
END_FUNC tuple_getitem

;; ============================================================================
;; tuple_subscript(PyTupleObject *tuple, PyObject *key) -> rax = Value
;; mp_subscript: index with int or slice key (for BINARY_SUBSCR)
;; Returns (rax=payload, edx=tag) fat value
;; ============================================================================
DEF_FUNC tuple_subscript
    V_UNPACK rsi, rdx           ; key Value -> (payload, tag)
    push rbx
    mov rbx, rdi               ; save tuple

    ; Check if key is a SmallInt (edx = key tag from caller)
    cmp edx, TAG_SMALLINT
    je .ts_int                 ; SmallInt -> int path
    cmp edx, TAG_PTR            ; a float key is neither: classify
    jne .ts_int                 ; fully before dereferencing, or raw
                                ; f64 bits get used as an address
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel slice_type]
    cmp rax, rcx
    je .ts_slice

.ts_int:
    mov rdi, rsi               ; key
    lea rsi, [rel ts_index_msg] ; ...and the refusal names the container
    call obj_as_index_seq          ; int, bool, int subclass or __index__
    mov rsi, rax               ; index
    mov rdi, rbx
    call tuple_getitem         ; already returns a Value
    pop rbx
    leave
    ret

.ts_slice:
    mov rdi, rbx
    ; rsi = slice
    call tuple_getslice
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

END_FUNC tuple_subscript

section .rodata
ts_index_msg: db `tuple indices must be integers or slices, not \x01`, 0
section .text

;; ============================================================================
;; tuple_len(PyTupleObject *tuple) -> int64_t
;; Return tuple->ob_size
;; ============================================================================
DEF_FUNC_BARE tuple_len
    mov rax, [rdi + PyTupleObject.ob_size]
    ret
END_FUNC tuple_len

; tuple_dealloc(PyObject *self)
; DECREF_VAL each fat item, then free self or return to pool
TUPLE_POOL_MAX equ 16

; Same (head, count) record shape as the frame pools, and the same reason to
; name the offset rather than write [rcx + 8].
TUPLE_POOL_HEAD  equ 0
TUPLE_POOL_COUNT equ 8

DEF_FUNC tuple_dealloc, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    mov rbx, rdi                ; rbx = tuple
    mov r12, [rbx + PyTupleObject.ob_size]  ; r12 = item count
    xor r13d, r13d              ; r13 = index

.decref_loop:
    cmp r13, r12
    jge .try_pool
    mov rax, [rbx + PyTupleObject.ob_item]
    mov rdi, [rax + r13 * 8]
    DECREF_V rdi, rsi
    inc r13
    jmp .decref_loop

.try_pool:
    ; Try to pool small tuples (size 1-3)
    cmp r12, 1
    je .pool_1
    cmp r12, 2
    je .pool_2
    cmp r12, 3
    je .pool_3
    jmp .free_self
.pool_1:
    lea rcx, [rel tuple_pool_1_head]
    jmp .try_push
.pool_2:
    lea rcx, [rel tuple_pool_2_head]
    jmp .try_push
.pool_3:
    lea rcx, [rel tuple_pool_3_head]
.try_push:
    cmp dword [rcx + TUPLE_POOL_COUNT], TUPLE_POOL_MAX
    jge .free_self
    ; Untrack from GC before pooling
    push rcx              ; save pool head ptr (caller-saved, clobbered by gc_untrack)
    mov rdi, rbx
    call gc_untrack
    pop rcx               ; restore pool head ptr
    ; Push to pool: reuse ob_refcnt as next-pointer
    mov rdx, [rcx + TUPLE_POOL_HEAD]
    mov [rbx + PyObject.ob_refcnt], rdx
    mov [rcx + TUPLE_POOL_HEAD], rbx
    inc dword [rcx + 8]         ; count++
    pop r13
    pop r12
    pop rbx
    leave
    ret

.free_self:
    mov rdi, [rbx + PyTupleObject.ob_item]
    test rdi, rdi
    jz .free_header
    call ap_free
.free_header:
    mov rdi, rbx
    call gc_dealloc

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC tuple_dealloc

; tuple_repr is in src/repr.asm
extern tuple_repr

;; ============================================================================
;; tuple_hash(PyObject *self) -> int64
;; Combines item hashes using a simple multiply-xor scheme
;; TAG_SMALLINT: hash = payload. TAG_PTR: obj_hash(payload).
;; ============================================================================
DEF_FUNC tuple_hash
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi                ; rbx = tuple

    ; Check cached hash
    mov rax, [rbx + PyTupleObject.ob_hash]
    cmp rax, -1
    jne .cached

    mov r12, [rbx + PyTupleObject.ob_size]  ; r12 = item count
    xor r13d, r13d              ; r13 = index
    mov r14d, 0x345678              ; r14 = hash accumulator

.hash_loop:
    cmp r13, r12
    jge .finalize
    mov rax, [rbx + PyTupleObject.ob_item]
    mov rdi, [rax + r13 * 8]
    V_UNPACK rdi, rsi
    ; Check tag
    cmp esi, TAG_SMALLINT
    je .hash_smallint
    cmp esi, TAG_NULL
    je .skip_null
    ; TAG_PTR or other: call obj_hash on payload
    V_PACK rdi, rsi
    call obj_hash               ; rax = hash of item
    jmp .hash_combine
.hash_smallint:
    mov rax, rdi                ; hash = payload value
.hash_combine:
    ; Combine: hash = hash * 1000003 ^ item_hash
    imul r14, r14, 1000003
    xor r14, rax
.skip_null:
    inc r13
    jmp .hash_loop

.finalize:
    mov rax, r14
    ; Add length to hash
    xor rax, r12

    ; Ensure hash is never -1
    cmp rax, -1
    jne .store
    mov rax, -2
.store:
    mov [rbx + PyTupleObject.ob_hash], rax

.cached:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC tuple_hash

;; ============================================================================
;; tuple_getslice(PyTupleObject *tuple, PySliceObject *slice) -> PyTupleObject*
;; Creates a new tuple from a slice of the original. Fat 16-byte slots.
;; ============================================================================
TGS_NEW   equ 48            ; the tuple being built
TGS_LEN   equ 56            ; its length
DEF_FUNC tuple_getslice
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24                ; [rbp - TGS_LEN]=slicelength, [rbp - TGS_NEW]=newtuple, align

    mov rbx, rdi               ; tuple
    mov r12, rsi               ; slice

    ; Get slice indices
    mov rdi, r12
    mov rsi, [rbx + PyTupleObject.ob_size]
    call slice_indices
    mov r13, rax               ; start
    mov r14, rdx               ; stop
    mov r15, rcx               ; step

    ; Compute slicelength
    test r15, r15
    jg .tgs_pos_step
    ; Negative step: if start <= stop, empty
    mov rax, r13
    sub rax, r14
    jle .tgs_empty
    dec rax
    mov rcx, r15
    neg rcx
    xor edx, edx
    div rcx
    inc rax
    jmp .tgs_have_len

.tgs_pos_step:
    mov rax, r14
    sub rax, r13
    jle .tgs_empty
    dec rax
    xor edx, edx
    div r15
    inc rax
    jmp .tgs_have_len

.tgs_empty:
    xor eax, eax

.tgs_have_len:
    mov [rbp - TGS_LEN], rax          ; slicelength
    mov rdi, rax
    call tuple_new
    mov [rbp - TGS_NEW], rax          ; new tuple

    ; Fill items (payload + tag arrays)
    ; Fast path: step == 1 → contiguous memcpy + bulk INCREF
    cmp r15, 1
    jne .tgs_loop_start

    ; Copy payloads (contiguous)
    mov rsi, [rbx + PyTupleObject.ob_item]
    mov rax, r13
    lea rsi, [rsi + rax*8]              ; src payloads + start*8
    mov rdi, [rbp - TGS_NEW]
    mov rdi, [rdi + PyTupleObject.ob_item]  ; dst payloads
    mov rdx, [rbp - TGS_LEN]         ; slicelength
    shl rdx, 3
    call ap_memcpy

    ; Bulk INCREF all copied elements
    mov rcx, [rbp - TGS_LEN]         ; slicelength
    test rcx, rcx
    jz .tgs_done
    mov rdi, [rbp - TGS_NEW]
    mov rdi, [rdi + PyTupleObject.ob_item]
    xor edx, edx
.tgs_incref_loop:
    cmp rdx, rcx
    jge .tgs_done
    mov r8, [rdi + rdx * 8]
    INCREF_V r8, r9
    inc rdx
    jmp .tgs_incref_loop

.tgs_loop_start:
    xor ecx, ecx
.tgs_loop:
    cmp rcx, [rbp - TGS_LEN]
    jge .tgs_done
    ; src_idx = start + i * step
    mov rax, rcx
    imul rax, r15
    add rax, r13
    ; Load element from source
    mov rdx, [rbx + PyTupleObject.ob_item]
    mov rdx, [rdx + rax * 8]
    ; Store in new tuple
    mov rsi, [rbp - TGS_NEW]
    mov r9, [rsi + PyTupleObject.ob_item]
    mov [r9 + rcx * 8], rdx
    push rcx
    INCREF_V rdx, r8
    pop rcx
    inc rcx
    jmp .tgs_loop

.tgs_done:
    mov rax, [rbp - TGS_NEW]

    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov edx, TAG_PTR
    leave
    ret
END_FUNC tuple_getslice

;; ============================================================================
;; tuple_contains(rdi=self, rsi=value Value) -> int (0 or 1)
;; Linear scan with identity then __eq__.
;; ============================================================================
TCN_IDX   equ 8
TCN_FRAME equ 24            ; + 3 pushes = 48, 16-aligned
DEF_FUNC tuple_contains, TCN_FRAME
    push rbx
    push r12
    push r13

    mov rbx, rdi               ; tuple
    mov r12, rsi               ; the value Value
    mov r13, [rbx + PyTupleObject.ob_size]
    mov qword [rbp - TCN_IDX], 0

.tc_loop:
    mov rcx, [rbp - TCN_IDX]
    cmp rcx, r13
    jge .tc_not_found
    mov rax, [rbx + PyTupleObject.ob_item]
    mov rdi, [rax + rcx * 8]   ; the element Value

    ; Membership is PyObject_RichCompareBool, not a word compare: it tries
    ; identity, then the element's __eq__, then the value's reflected one.
    ; Comparing the two Value words only ever found an identical object.
    mov rsi, r12
    mov edx, PY_EQ
    call obj_richcompare_bool
    cmp eax, -1
    je .tc_error
    test eax, eax
    jnz .tc_found

    inc qword [rbp - TCN_IDX]
    jmp .tc_loop

.tc_found:
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    leave
    ret

.tc_not_found:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret

.tc_error:
    ; sq_contains has no error channel, and the exception is already pending.
    leave
    jmp eval_exception_unwind
END_FUNC tuple_contains

;; ============================================================================
;; tuple_concat(PyTupleObject *a, PyObject *b) -> PyTupleObject*
;; Concatenate two tuples with fat 16-byte slots.
;; ============================================================================
DEF_FUNC tuple_concat
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi            ; rbx = tuple a
    mov r12, rsi            ; r12 = tuple b

    ; b is read as a tuple below.  An immediate's payload is not an address,
    ; and this worked on a list only by layout accident -- PyListObject
    ; happens to carry ob_size and ob_item at the same offsets.
    cmp ecx, TAG_PTR
    jne .tc_type_error
    mov rax, [r12 + PyObject.ob_type]
    REQUIRE_TUPLE_TYPE rax, rcx, .tc_type_error_ptr

    mov r13, [rbx + PyTupleObject.ob_size]   ; r13 = len(a)
    mov r14, [r12 + PyTupleObject.ob_size]   ; r14 = len(b)

    ; Allocate new tuple
    lea rdi, [r13 + r14]
    call tuple_new
    push rax                ; save new tuple

    ; Copy items from a
    mov r9, [rbx + PyTupleObject.ob_item]       ; src items
    mov r11, [rsp]                              ; new tuple
    mov r11, [r11 + PyTupleObject.ob_item]      ; dst items
    xor ecx, ecx
.copy_a:
    cmp rcx, r13
    jge .copy_b_start
    mov rdx, [r9 + rcx * 8]
    mov [r11 + rcx * 8], rdx
    INCREF_V rdx, rax
    inc rcx
    jmp .copy_a

.copy_b_start:
    mov r9, [r12 + PyTupleObject.ob_item]       ; src items
    mov r11, [rsp]
    mov r11, [r11 + PyTupleObject.ob_item]      ; dst items
    xor ecx, ecx
.copy_b:
    cmp rcx, r14
    jge .concat_done
    mov rdx, [r9 + rcx * 8]
    lea rsi, [r13 + rcx]        ; dest index
    mov [r11 + rsi * 8], rdx
    INCREF_V rdx, rax
    inc rcx
    jmp .copy_b

.concat_done:
    pop rax
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
.tc_type_error_ptr:
    mov ecx, TAG_PTR            ; REQUIRE_TUPLE_TYPE used rcx as its scratch
.tc_type_error:
    ; The right operand's payload survives in r12; its tag does not always --
    ; REQUIRE_*_TYPE uses rcx as scratch -- so the pointer case is recovered
    ; from the payload itself, which is its own Value.
    mov rdi, r12
    mov rsi, rcx
    VALUE_FOR_TYPE rdi, rsi
    mov rsi, rdi
    CSTRING rdi, `can only concatenate tuple (not "\x01") to tuple`
    extern raise_type_error_with_name
    call raise_type_error_with_name
END_FUNC tuple_concat

;; ============================================================================
;; tuple_repeat(PyTupleObject *tuple, PyObject *count) -> PyTupleObject*
;; Repeat a tuple with fat 16-byte slots.
;; ============================================================================
DEF_FUNC tuple_repeat
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi            ; rbx = tuple
    mov rdi, rsi            ; count (int payload)
    mov edx, ecx            ; count tag (right operand)
    ; A count too large for int64 used to truncate through __gmpz_get_si,
    ; so (1,) * (2**64) quietly returned an empty result.
    ; The count must be an index.  int_fits_i64 and int_to_i64 both read
    ; PyIntObject fields, so a str or a float count was dereferenced as one:
    ; "a" * "2" segfaulted and [1] * None reported an OverflowError.
    mov rsi, rdi
    mov rcx, rdx
    V_PACK rsi, rcx
    ; Not a count at all: DECLINE rather than raise, so the protocol carries
    ; on to the right operand's __rmul__.  This raised, and `x * R()` for an R
    ; with an __rmul__ never reached it.  op_binary_op words the failure when
    ; nothing else answers either.
    mov rdi, rsi
    push rsi
    extern binop_is_count
    call binop_is_count
    pop rsi
    test eax, eax
    jz .trep_decline
    extern seq_repeat_count
    call seq_repeat_count    ; __index__ counts, and one too big to be an
    mov r12, rax             ; index is refused rather than truncated

    test r12, r12
    jg .rep_positive
    xor r12d, r12d
.rep_positive:
    ; t * 1 is t itself.  CPython returns the same object, and seq_tests
    ; asserts id(s) == id(s*1); only an exact tuple qualifies, since a
    ; subclass instance is not interchangeable with a plain tuple.
    cmp r12, 1
    jne .rep_not_one
    lea rax, [rel tuple_type]
    cmp [rbx + PyObject.ob_type], rax
    jne .rep_not_one
    mov rax, rbx
    inc qword [rax + PyObject.ob_refcnt]
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.rep_not_one:
    mov r13, [rbx + PyTupleObject.ob_size]   ; r13 = len(tuple)
    mov r14, r13
    imul r14, r12            ; r14 = total items
    jo .trep_overflow        ; the product wrapped; (1,) * (2**61) wrapped
    cmp r14, 0x10000000      ; 256M items, as list_repeat caps at
    ja .trep_toobig

    ; Allocate new tuple
    mov rdi, r14
    call tuple_new
    push rax                ; save new tuple

    ; Copy tuple r12 times
    mov r9, [rbx + PyTupleObject.ob_item]       ; src items
    mov r11, [rsp]                              ; new tuple
    mov r11, [r11 + PyTupleObject.ob_item]      ; dst items
    xor ecx, ecx            ; repeat counter
    xor r8d, r8d            ; dest index
.rep_outer:
    cmp rcx, r12
    jge .rep_done
    push rcx
    xor edx, edx
.rep_inner:
    cmp rdx, r13
    jge .rep_inner_done
    mov rdi, [r9 + rdx * 8]
    mov [r11 + r8 * 8], rdi
    INCREF_V rdi, rax
    inc r8
    inc rdx
    jmp .rep_inner
.rep_inner_done:
    pop rcx
    inc rcx
    jmp .rep_outer

.rep_done:
    pop rax
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
.trep_toobig:
    ; Too large to allocate is a MemoryError in CPython; only a count that
    ; does not fit an index is an OverflowError.  list and bytes have said so
    ; since they were written; tuple sent both cases to the one label.
    RAISE exc_MemoryError_type, ""
.trep_decline:
    xor eax, eax
    xor edx, edx
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.trep_overflow:
    RAISE exc_OverflowError_type, "too many items for tuple repetition"
END_FUNC tuple_repeat

;; ============================================================================
;; tuple_richcompare(left, right, op, left_tag, right_tag) -> (rax, edx)
;; Compare two tuples. Returns bool fat value.
;; Supports EQ, NE, LT, LE, GT, GE (lexicographic for ordering).
;; ============================================================================
TRC_LEFT     equ 8
TRC_RIGHT    equ 16
TRC_OP       equ 24
TRC_IDX      equ 32
TRC_MINLEN   equ 40
TRC_FRAME    equ 48            ; + 0 pushes = 48, 16-aligned

; Comparing two structures that reach each other -- a=[]; a.append(a);
; b=[]; b.append(b); a==b -- recursed until the machine stack ran out; the
; identity fast path inside only catches a==a.  The body is wrapped so its
; several exits need not each be touched.
DEF_FUNC tuple_richcompare
    C_RECURSION_ENTER .trc_too_deep
    call tuple_richcompare_inner
    C_RECURSION_LEAVE
    leave
    ret
.trc_too_deep:
    C_RECURSION_LEAVE
    RAISE exc_RecursionError_type, "maximum recursion depth exceeded in comparison"
END_FUNC tuple_richcompare

DEF_FUNC_LOCAL tuple_richcompare_inner, TRC_FRAME
    V_UNPACK rdi, rcx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, r8            ; right Value -> (payload, tag)
    ; Verify right is TAG_PTR and a tuple.  A subclass counts: this asked for
    ; the exact type, so T([1,2]) == T([1,2]) was False and sorted() over a
    ; mixed list raised -- both sides declined and the protocol ran out.  It
    ; is the one comparison in the family that was not using the macro.
    cmp r8d, TAG_PTR
    jne .trc_not_impl
    mov rax, [rsi + PyObject.ob_type]
    REQUIRE_TUPLE_TYPE rax, r9, .trc_not_impl

    mov [rbp - TRC_LEFT], rdi
    mov [rbp - TRC_RIGHT], rsi
    mov [rbp - TRC_OP], edx

    ; Get lengths
    mov rcx, [rdi + PyTupleObject.ob_size]   ; left_len
    mov r8, [rsi + PyTupleObject.ob_size]    ; right_len

    ; min_len = min(left_len, right_len).  Read once, unlike list's, which
    ; re-reads both every iteration: an element's __eq__ can empty a list and
    ; cannot shorten a tuple.
    mov rax, rcx
    cmp rax, r8
    jle .trc_have_min
    mov rax, r8
.trc_have_min:
    mov [rbp - TRC_MINLEN], rax

    ; Compare elements 0..min_len-1
    mov qword [rbp - TRC_IDX], 0

.trc_elem_loop:
    mov rax, [rbp - TRC_IDX]
    cmp rax, [rbp - TRC_MINLEN]
    jge .trc_elements_equal

    ; Get left[i] and right[i], as Values
    mov rcx, [rbp - TRC_LEFT]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov rdi, [rcx + rax * 8]
    mov rcx, [rbp - TRC_RIGHT]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov rsi, [rcx + rax * 8]
    ; The two questions a Value can answer without calling anything; see
    ; VALUE_EQ_FAST.  For tuples of small integers this is the whole
    ; comparison, which is what CPython's per-element `if (vitem == witem)`
    ; buys it.
    VALUE_EQ_FAST rdi, rsi, rdx, .trc_elem_next, .trc_elem_differ
    mov edx, PY_EQ
    call obj_richcompare_bool
    cmp eax, -1
    je .trc_error
    test eax, eax
    jz .trc_elem_differ             ; first differing element

.trc_elem_next:
    inc qword [rbp - TRC_IDX]
    jmp .trc_elem_loop

.trc_elem_differ:
    ; Elements at index i differ.
    ; For EQ: return False. For NE: return True.
    ; For ordering: compare these elements with the requested op.
    mov ecx, [rbp - TRC_OP]
    cmp ecx, PY_EQ
    je .trc_return_false
    cmp ecx, PY_NE
    je .trc_return_true

    mov rax, [rbp - TRC_IDX]
    mov rcx, [rbp - TRC_LEFT]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov rdi, [rcx + rax * 8]
    mov rcx, [rbp - TRC_RIGHT]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov rsi, [rcx + rax * 8]
    mov edx, [rbp - TRC_OP]
    call obj_richcompare_bool
    cmp eax, -1
    je .trc_error
    RET_BOOL_RAX
    leave
    ret

.trc_error:
    ; The element comparison raised; obj_richcompare_bool left it pending.
    RET_NULL
    leave
    ret

.trc_elements_equal:
    ; All min_len elements are equal.
    ; Result depends on lengths and comparison op.
    mov rcx, [rbp - TRC_LEFT]
    mov rcx, [rcx + PyTupleObject.ob_size]    ; left_len
    mov r8, [rbp - TRC_RIGHT]
    mov r8, [r8 + PyTupleObject.ob_size]      ; right_len
    mov edx, [rbp - TRC_OP]

    cmp edx, PY_EQ
    je .trc_len_eq
    cmp edx, PY_NE
    je .trc_len_ne
    cmp edx, PY_LT
    je .trc_len_lt
    cmp edx, PY_LE
    je .trc_len_le
    cmp edx, PY_GT
    je .trc_len_gt
    ; PY_GE
    cmp rcx, r8
    jge .trc_return_true
    jmp .trc_return_false

.trc_len_eq:
    cmp rcx, r8
    je .trc_return_true
    jmp .trc_return_false
.trc_len_ne:
    cmp rcx, r8
    jne .trc_return_true
    jmp .trc_return_false
.trc_len_lt:
    cmp rcx, r8
    jl .trc_return_true
    jmp .trc_return_false
.trc_len_le:
    cmp rcx, r8
    jle .trc_return_true
    jmp .trc_return_false
.trc_len_gt:
    cmp rcx, r8
    jg .trc_return_true
    jmp .trc_return_false

.trc_return_true:
    mov eax, 1
    RET_BOOL_RAX
    leave
    ret

.trc_return_false:
    xor eax, eax
    RET_BOOL_RAX
    leave
    ret

.trc_not_impl:
    ; Return NotImplemented (NULL) so COMPARE_OP can try right operand
    RET_NULL
    leave
    ret

END_FUNC tuple_richcompare_inner

;; ============================================================================
;; tuple_type_call(PyTypeObject *type, PyObject **args, int64_t nargs)
;; Constructor: tuple() or tuple(iterable)
;; ============================================================================
TTC_LIST    equ 8       ; temp list
TTC_ITER    equ 16      ; iterator
TTC_EXC     equ 24      ; current_exception on entry, to tell "raised" from
                        ; "already being handled"
TTC_FRAME   equ 32          ; + 4 pushes = 64, 16-aligned

DEF_FUNC tuple_type_call, TTC_FRAME
    NO_KEYWORDS "tuple() takes no keyword arguments"
    push rbx
    push r12
    push r13
    push r14
    DUNDER_EXC_SAVE [rbp - TTC_EXC]

    mov r12, rsi            ; args
    mov r13, rdx            ; nargs

    ; tuple() — no args: return empty tuple
    test r13, r13
    jz .ttc_empty

    ; tuple(iterable) — exactly 1 arg
    cmp r13, 1
    jne .ttc_error

    ; tuple(t) is t.  A tuple is immutable, so CPython hands an exact one
    ; straight back rather than copying it.  Both halves have to be exact: a
    ; subclass constructor must build its own object, and a tuple subclass
    ; instance must not escape from tuple() as itself.  rdi still holds the
    ; type -- nothing above has touched it.
    lea rax, [rel tuple_type]
    cmp rdi, rax
    jne .ttc_build
    mov rcx, [r12]              ; args[0]
    V_TEST_PTR rcx, rdx
    ja .ttc_build
    test rcx, rcx
    jz .ttc_build
    cmp [rcx + PyObject.ob_type], rax
    jne .ttc_build
    INCREF rcx
    mov rax, rcx
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.ttc_build:
    ; Create empty list, iterate into it, convert to tuple
    xor edi, edi
    extern list_new
    call list_new
    mov [rbp - TTC_LIST], rax
    mov rbx, rax            ; rbx = temp list

    ; Get iterator from arg
    mov rdi, [r12]          ; args[0]
    V_UNPACK rdi, rsi
    extern get_iterator
    call get_iterator
    mov [rbp - TTC_ITER], rax

    ; Iterate and append to list
.ttc_loop:
    mov rdi, [rbp - TTC_ITER]
    extern call_iternext
    call call_iternext
    V_UNPACK rax, rdx           ; call_iternext returns a Value
    test edx, edx
    jz .ttc_done

    push rax                ; save item payload
    push rdx                ; save item tag
    mov rdi, rbx
    mov rsi, rax
    ; edx = tag
    extern list_append
    V_PACK rsi, rdx         ; list_append takes a Value
    call list_append
    pop rsi                 ; item tag
    pop rdi                 ; item payload
    DECREF_VAL rdi, rsi
    jmp .ttc_loop

.ttc_done:
    ; DECREF iterator
    mov rdi, [rbp - TTC_ITER]
    call obj_decref

    ; Did iternext raise, or was something already being handled?  Inside an
    ; `except` block current_exception is the exception being handled, so a
    ; bare test made tuple(x) there re-raise it.
    extern current_exception
    EXC_RAISED_SINCE [rbp - TTC_EXC], rax, .ttc_exc_cleanup

    ; Convert list to tuple
    mov rcx, [rbx + PyListObject.ob_size]
    mov rsi, [rbx + PyListObject.ob_item]       ; list items
    push rbx                ; save list for DECREF

    mov rdi, rcx
    push rcx
    push rsi
    push rsi                ; keep the stack balanced (pair of pushes)
    extern tuple_new
    call tuple_new
    pop rsi
    pop rsi                 ; list items
    pop rcx                 ; count
    mov r12, rax             ; r12 = new tuple
    mov r11, [r12 + PyTupleObject.ob_item]

    ; Copy items from list to tuple, INCREF each
    xor edx, edx
.ttc_copy_loop:
    cmp rdx, rcx
    jge .ttc_copy_done
    push rcx
    push rdx
    push rsi
    push rsi                ; keep the stack balanced (pair of pushes)
    push r11

    mov rdi, [rsi + rdx * 8]      ; Value from list
    mov [r11 + rdx * 8], rdi
    INCREF_V rdi, r9

    pop r11
    pop rsi
    pop rsi
    pop rdx
    pop rcx
    inc rdx
    jmp .ttc_copy_loop

.ttc_copy_done:
    ; DECREF the temp list
    pop rdi                 ; temp list
    call obj_decref

    mov rax, r12
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ttc_exc_cleanup:
    ; DECREF the temp list, return NULL
    mov rdi, rbx
    call obj_decref
    RET_NULL
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ttc_empty:
    xor edi, edi
    extern tuple_new
    call tuple_new
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ttc_error:
    mov rsi, r13
    CSTRING rdi, "tuple expected at most 1 argument, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC tuple_type_call

section .data

; Tuple object pools (freelist per size class, singly-linked via ob_refcnt)
align 8
tuple_pool_1_head:  dq 0       ; 1-tuple freelist head
tuple_pool_1_count: dd 0       ; current count
                    dd 0       ; padding
tuple_pool_2_head:  dq 0       ; 2-tuple freelist head
tuple_pool_2_count: dd 0
                    dd 0
tuple_pool_3_head:  dq 0       ; 3-tuple freelist head
tuple_pool_3_count: dd 0
                    dd 0

tuple_name_str: db "tuple", 0
; tuple_repr_str removed - repr now in src/repr.asm

; Tuple sequence methods
align 8
tuple_sequence_methods:
    dq tuple_len            ; sq_length
    dq tuple_concat         ; sq_concat
    dq tuple_repeat         ; sq_repeat
    dq tuple_getitem        ; sq_item
    dq 0                    ; sq_ass_item
    dq tuple_contains       ; sq_contains
    dq 0                    ; sq_inplace_concat
    dq 0                    ; sq_inplace_repeat

; Tuple mapping methods
align 8
tuple_mapping_methods:
    dq tuple_len            ; mp_length
    dq tuple_subscript      ; mp_subscript
    dq 0                    ; mp_ass_subscript

; tuple type object
align 8
global tuple_type
tuple_type:
    dq 1                    ; ob_refcnt
    dq type_type            ; ob_type
    dq tuple_name_str       ; tp_name
    dq PyTupleObject_size    ; tp_basicsize (header)
    dq tuple_dealloc        ; tp_dealloc
    dq tuple_repr           ; tp_repr
    dq tuple_repr           ; tp_str
    dq tuple_hash           ; tp_hash
    dq 0                ; tp_call  (instances are not callable)
    dq 0                    ; tp_getattr
    dq 0                    ; tp_setattr
    dq tuple_richcompare    ; tp_richcompare
    dq 0                    ; tp_iter (set by init_iter_types)
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq tuple_type_call      ; tp_new  (constructor)
    dq 0                    ; tp_as_number
    dq tuple_sequence_methods ; tp_as_sequence
    dq tuple_mapping_methods ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq TYPE_FLAG_HAVE_GC | TYPE_FLAG_TUPLE_SUBCLASS ; tp_flags
    dq 0                    ; tp_bases
    dq tuple_traverse                        ; tp_traverse
    dq 0                                  ; tp_clear -- see tuple_traverse
    dq 0        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

section .text

;; ============================================================================
;; GC traverse and clear.  These lived in gc.asm, which left the collector
;; holding the reference graph of every type in the system; a type's own
;; file is the only place that knows which of its fields are owned.
;; ============================================================================

;; ============================================================================
;; ---- tuple_traverse ----
;; ============================================================================
DEF_FUNC tuple_traverse
    push rbx
    push r12
    push r13
    push r15

    mov rbx, rdi
    mov r13, [rbx + PyTupleObject.ob_size]
    mov r12, [rbx + PyTupleObject.ob_item]       ; payloads
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
END_FUNC tuple_traverse

;; No tuple_clear, as CPython has none.  A tuple is immutable, so every cycle
;; through one also runs through a mutable object whose own tp_clear breaks it.
;; Emptying a tuple instead tears its items out from under a reader that is
;; still running: a code object's co_consts is a tuple, and a generator
;; suspended on that code is closed -- its finally run -- later in the same
;; collection, where LOAD_CONST indexes the emptied tuple and reads freed
;; objects.  tests/test_gc_suspended_generator_consts.py is the shape.
