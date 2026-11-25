; pyo/iter.asm - Iterator types and range object
; Phase 9: list_iter, tuple_iter, range_iter, range_obj

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"
extern set_exception
extern none_singleton
extern int_promote_mpz
extern obj_dealloc
global range_new_v
extern obj_richcompare_bool

extern ap_malloc
extern gc_alloc
extern ap_free
extern obj_decref
extern fatal_error
extern list_type
extern tuple_type
extern type_type
extern bool_true
extern bool_false
extern int_type
extern bool_type
extern exc_ValueError_type
extern exc_TypeError_type

;; ============================================================================
;; list_iter_new(PyListObject *list) -> PyListIterObject*
;; Create a new list iterator
;; ============================================================================
;; ============================================================================
;; The shared traverse and clear for the simple iterators and views.
;;
;; Every one of them -- list, tuple, str, bytes, set and dict iterators, the
;; three dict views, and the sequence-protocol iterator -- keeps exactly one
;; owned pointer, at the same offset: the thing it is walking.  None of them
;; was GC-tracked, so `a = []; a.append(iter(a))` was a cycle the collector
;; could not see, and neither could `d["k"] = d.keys()`.
;;
;; The offset is named for the list iterator because that is the struct these
;; all agree with; it is 16 in every one of them.
;; ============================================================================
global iter_traverse_one
DEF_FUNC iter_traverse_one
    mov rdi, [rdi + PyListIterObject.it_seq]
    VISIT_PTR rdi
    leave
    ret
END_FUNC iter_traverse_one

global iter_clear_one
DEF_FUNC iter_clear_one, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyListIterObject.it_seq]
    test rdi, rdi
    jz .ico_done
    mov qword [rbx + PyListIterObject.it_seq], 0
    call obj_decref
.ico_done:
    pop rbx
    leave
    ret
END_FUNC iter_clear_one

DEF_FUNC list_iter_new, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx

    mov rbx, rdi               ; save list

    ; gc_alloc, not ap_malloc: an iterator holds the thing it walks, and a
    ; container holding its own iterator is a cycle only the collector can
    ; break.  gc_alloc fills ob_refcnt and ob_type itself.
    mov edi, PyListIterObject_size
    lea rsi, [rel list_iter_type]
    call gc_alloc

    mov [rax + PyListIterObject.it_seq], rbx
    mov qword [rax + PyListIterObject.it_index], 0

    ; INCREF the list
    INCREF rbx

    push rax
    mov rdi, rax
    extern gc_track
    call gc_track
    pop rax

    pop rbx
    leave
    ret
END_FUNC list_iter_new

;; ============================================================================
;; list_iter_next(PyListIterObject *self) -> PyObject* or NULL
;; Return next item or NULL if exhausted
;; ============================================================================
DEF_FUNC_BARE list_iter_next
    mov rax, [rdi + PyListIterObject.it_seq]      ; list
    test rax, rax
    jz .exhausted                                  ; already exhausted
    mov rcx, [rdi + PyListIterObject.it_index]     ; index

    ; Check bounds
    cmp rcx, [rax + PyListObject.ob_size]
    jge .exhausted_mark

    ; Get item
    mov rdx, [rax + PyListObject.ob_item]
    mov rax, [rdx + rcx * 8]     ; item Value
    INCREF_V rax, rdx

    ; Advance index
    inc qword [rdi + PyListIterObject.it_index]
    ret

.exhausted_mark:
    ; Drop the reference BEFORE releasing it.  Releasing first runs the
    ; list's __del__ inside obj_decref, and a __del__ that calls next() on
    ; this same iterator then read it_seq while the list was being freed --
    ; CPython issue 26494, and a segfault here.  Clearing first makes that
    ; re-entrant next() see an exhausted iterator, which is what it is.
    mov rax, [rdi + PyListIterObject.it_seq]
    mov qword [rdi + PyListIterObject.it_seq], 0
    push rdi
    mov rdi, rax
    call obj_decref
    pop rdi
.exhausted:
    RET_NULL
    ret
END_FUNC list_iter_next

;; ============================================================================
;; list_iter_dealloc(PyObject *self)
;; ============================================================================
DEF_FUNC_LOCAL list_iter_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; DECREF the list (if not already exhausted)
    mov rdi, [rbx + PyListIterObject.it_seq]
    test rdi, rdi
    jz .lid_no_decref
    call obj_decref
.lid_no_decref:

    ; Free self
    mov rdi, rbx
    extern gc_dealloc
    call gc_dealloc

    pop rbx
    leave
    ret
END_FUNC list_iter_dealloc

;; ============================================================================
;; list_iter_self(PyObject *self) -> PyObject*
;; tp_iter for iterators: return self with INCREF
;; ============================================================================
DEF_FUNC_BARE iter_self
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret
END_FUNC iter_self

;; ============================================================================
;; list_tp_iter(PyListObject *list) -> PyListIterObject*
;; tp_iter for list type: create a new list iterator
;; This is called when GET_ITER is used on a list.
;; ============================================================================
DEF_FUNC_BARE list_tp_iter
    jmp list_iter_new
END_FUNC list_tp_iter

;; ============================================================================
;; tuple_iter_new(PyTupleObject *tuple) -> PyTupleIterObject*
;; Create a new tuple iterator
;; ============================================================================
DEF_FUNC tuple_iter_new, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx

    mov rbx, rdi

    mov edi, PyTupleIterObject_size
    lea rsi, [rel tuple_iter_type]
    call gc_alloc

    mov [rax + PyTupleIterObject.it_seq], rbx
    mov qword [rax + PyTupleIterObject.it_index], 0

    INCREF rbx

    push rax
    mov rdi, rax
    call gc_track
    pop rax

    pop rbx
    leave
    ret
END_FUNC tuple_iter_new

;; ============================================================================
;; tuple_iter_next(PyTupleIterObject *self) -> rax = item Value, 0 when exhausted
;; ============================================================================
DEF_FUNC_BARE tuple_iter_next
    mov rax, [rdi + PyTupleIterObject.it_seq]
    test rax, rax
    jz .exhausted               ; already dropped, or cleared by the collector
    mov rcx, [rdi + PyTupleIterObject.it_index]

    cmp rcx, [rax + PyTupleObject.ob_size]
    jge .exhausted_mark

    ; Get item
    mov rax, [rax + PyTupleObject.ob_item]
    mov rax, [rax + rcx * 8]       ; item Value
    INCREF_V rax, rdx

    inc qword [rdi + PyTupleIterObject.it_index]
    ret

.exhausted_mark:
    ; Drop the tuple at exhaustion, the way list_iter_next does and the way
    ; CPython's tupleiter_next does -- it is what lets a __del__ on the last
    ; reference run while the iterator can still answer "exhausted".  Clear
    ; before releasing, for the reason list_iter_next carries in full.
    mov rax, [rdi + PyTupleIterObject.it_seq]
    mov qword [rdi + PyTupleIterObject.it_seq], 0
    push rdi
    mov rdi, rax
    call obj_decref
    pop rdi
.exhausted:
    RET_NULL
    ret
END_FUNC tuple_iter_next

;; ============================================================================
;; tuple_iter_dealloc(PyObject *self)
;; ============================================================================
DEF_FUNC_LOCAL tuple_iter_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyTupleIterObject.it_seq]
    call obj_decref

    mov rdi, rbx
    call gc_dealloc

    pop rbx
    leave
    ret
END_FUNC tuple_iter_dealloc

;; ============================================================================
;; tuple_tp_iter(PyTupleObject *tuple) -> PyTupleIterObject*
;; tp_iter for tuple type
;; ============================================================================
DEF_FUNC_BARE tuple_tp_iter
    jmp tuple_iter_new
END_FUNC tuple_tp_iter

;; ============================================================================
;; range_new(int64_t start, int64_t stop, int64_t step) -> PyRangeObject*
;; Create a range SEQUENCE object (reusable; tp_iter creates fresh iterators)
;;
;; The int64 form, which is every range a program writes.  The Values are
;; built from the same numbers, and .wide stays 0 because they are exact.
;; ============================================================================
RN_START  equ 8
RN_STOP   equ 16
RN_STEP   equ 24
RN_FRAME  equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC range_new, RN_FRAME
    push rbx

    mov [rbp - RN_START], rdi
    mov [rbp - RN_STOP], rsi
    mov [rbp - RN_STEP], rdx

    mov edi, PyRangeObject_size
    call ap_malloc
    mov rbx, rax

    mov qword [rbx + PyObject.ob_refcnt], 1
    lea rcx, [rel range_obj_type]
    mov [rbx + PyObject.ob_type], rcx
    mov qword [rbx + PyRangeObject.wide], 0

    mov rax, [rbp - RN_START]
    mov [rbx + PyRangeObject.start], rax
    V_PACK_I64 rax, rcx
    mov [rbx + PyRangeObject.vstart], rax
    mov rax, [rbp - RN_STOP]
    mov [rbx + PyRangeObject.stop], rax
    V_PACK_I64 rax, rcx
    mov [rbx + PyRangeObject.vstop], rax
    mov rax, [rbp - RN_STEP]
    mov [rbx + PyRangeObject.step], rax
    V_PACK_I64 rax, rcx
    mov [rbx + PyRangeObject.vstep], rax

    mov rax, rbx
    pop rbx
    leave
    ret
END_FUNC range_new

;; ============================================================================
;; range_new_v(Value start, Value stop, Value step) -> PyRangeObject*
;;
;; The general form: the three bounds as int Values, each an OWNED reference
;; this takes over.  A bound too wide for an int64 sets .wide, and the int64
;; fields are then clamped -- nothing reads them in that state, but a garbage
;; value there would be worse than a saturated one.
;; ============================================================================
RNV_STEP  equ 8             ; the step, across ap_malloc
RNV_FRAME equ 16            ; + 2 pushes = 32, 16-aligned
DEF_FUNC range_new_v, RNV_FRAME
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov [rbp - RNV_STEP], rdx

    mov edi, PyRangeObject_size
    call ap_malloc
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel range_obj_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyRangeObject.vstart], rbx
    mov [rax + PyRangeObject.vstop], r12
    mov rcx, [rbp - RNV_STEP]
    mov [rax + PyRangeObject.vstep], rcx
    mov qword [rax + PyRangeObject.wide], 0

    mov rbx, rax
    mov rdi, [rbx + PyRangeObject.vstart]
    call range_bound_i64
    mov [rbx + PyRangeObject.start], rax
    or [rbx + PyRangeObject.wide], rdx
    mov rdi, [rbx + PyRangeObject.vstop]
    call range_bound_i64
    mov [rbx + PyRangeObject.stop], rax
    or [rbx + PyRangeObject.wide], rdx
    mov rdi, [rbx + PyRangeObject.vstep]
    call range_bound_i64
    mov [rbx + PyRangeObject.step], rax
    or [rbx + PyRangeObject.wide], rdx

    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret
END_FUNC range_new_v

;; ============================================================================
;; range_bound_i64(Value v) -> rax = the int64, rdx = 1 when it did not fit
;; ============================================================================
RBI_V     equ 8             ; the bound, across int_fits_i64
RBI_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL range_bound_i64, RBI_FRAME
    V_IS_INT rdi, rax
    jae .rbi_immediate
    mov [rbp - RBI_V], rdi
    mov edx, TAG_PTR
    extern int_fits_i64
    call int_fits_i64
    test eax, eax
    jz .rbi_wide
    mov rdi, [rbp - RBI_V]
    mov edx, TAG_PTR
    extern int_to_i64
    call int_to_i64
    xor edx, edx
    leave
    ret
.rbi_wide:
    ; Saturate at the end the sign points to; nothing reads this field on a
    ; wide range, and a saturated value is at least ordered correctly.
    mov rdi, [rbp - RBI_V]
    INT_NEED_MPZ rdi
    lea rdi, [rdi + PyIntObject.mpz]
    extern __gmpz_cmp_si
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    mov rax, 0x7FFFFFFFFFFFFFFF
    jns .rbi_saturated
    mov rax, 0x8000000000000000
.rbi_saturated:
    mov edx, 1
    leave
    ret
.rbi_immediate:
    V_TO_I64 rdi
    mov rax, rdi
    xor edx, edx
    leave
    ret
END_FUNC range_bound_i64

;; ============================================================================
;; range_iter_next(PyRangeIterObject *self) -> PyObject* or NULL
;; Returns SmallInt for current value, advances by step
;; ============================================================================
DEF_FUNC_BARE range_iter_next
    ; Decode current, stop, step
    mov rax, [rdi + PyRangeIterObject.it_current]

    mov rcx, [rdi + PyRangeIterObject.it_stop]

    mov rdx, [rdi + PyRangeIterObject.it_step]

    ; Check if exhausted
    test rdx, rdx
    js .negative_step

    ; Positive step: current >= stop means exhausted
    cmp rax, rcx
    jge .exhausted
    jmp .has_value

.negative_step:
    ; Negative step: current <= stop means exhausted
    cmp rax, rcx
    jle .exhausted

.has_value:
    ; Return current as SmallInt
    mov r8, rax

    ; Advance: current += step.  A SIGNED overflow means the next value is
    ; past anything an int64 holds, so the run is over -- where wrapping round
    ; to the other end put current back below stop and started it again:
    ; `range(2**63-2, 2**63-1, 2)` yielded for ever, and `range(1, 2, 2**63-1)`
    ; answered [1, -2**63].  Saturating at stop makes the next call report
    ; exhaustion, in either direction.
    add rax, rdx
    jno .no_overflow
    mov rax, rcx
.no_overflow:
    mov [rdi + PyRangeIterObject.it_current], rax

    mov rax, r8
    V_PACK_I64 rax, rdx         ; range values can exceed the immediate range
    ret

.exhausted:
    RET_NULL
    ret
END_FUNC range_iter_next

;; ============================================================================
;; range_iter_dealloc(PyObject *self)
;; ============================================================================
DEF_FUNC_BARE range_iter_dealloc
    jmp ap_free                ; no references to DECREF, just free
END_FUNC range_iter_dealloc

;; ============================================================================
;; range_iter_self(PyObject *self) -> PyObject*
;; Range iterator returns itself
;; ============================================================================
DEF_FUNC_BARE range_iter_self
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret
END_FUNC range_iter_self

;; ============================================================================
;; range_obj_tp_iter(PyRangeObject *self) -> PyRangeIterObject*
;; Creates a NEW range iterator from the range sequence object.
;; ============================================================================
DEF_FUNC range_obj_tp_iter, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi               ; save range object

    ; A wide range gets a second iterator type, as CPython's does:
    ; type(iter(range(1 << 1000))) is longrange_iterator there, and its
    ; values are objects rather than int64s.
    cmp qword [rbx + PyRangeObject.wide], 0
    je .roti_narrow
    mov rdi, rbx
    call range_longiter_new
    pop rbx
    leave
    ret

.roti_narrow:
    mov edi, PyRangeIterObject_size
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel range_iter_type]
    mov [rax + PyObject.ob_type], rcx

    ; Copy start → current, stop, step from range object
    mov rcx, [rbx + PyRangeObject.start]
    mov [rax + PyRangeIterObject.it_current], rcx
    mov rcx, [rbx + PyRangeObject.stop]
    mov [rax + PyRangeIterObject.it_stop], rcx
    mov rcx, [rbx + PyRangeObject.step]
    mov [rax + PyRangeIterObject.it_step], rcx

    pop rbx
    leave
    ret
END_FUNC range_obj_tp_iter

;; ============================================================================
;; range_longiter_new(PyRangeObject *self) -> PyLongRangeIterObject*, or 0
;;
;; The iterator over a range whose bounds do not fit an int64.  It counts
;; DOWN from the length rather than comparing against a stop, because the
;; comparison would have to be object arithmetic on every step and the count
;; is one subtraction either way -- which is why CPython's does the same.
;; ============================================================================
RLN_LEN   equ 8             ; the length as a Value, across ap_malloc
RLN_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC range_longiter_new, RLN_FRAME
    push rbx
    mov rbx, rdi
    call range_len_value
    test rax, rax
    jz .rln_fail
    mov [rbp - RLN_LEN], rax

    mov edi, PyLongRangeIterObject_size
    call ap_malloc
    test rax, rax
    jz .rln_fail_len
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel longrange_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov rcx, [rbx + PyRangeObject.vstart]
    mov [rax + PyLongRangeIterObject.it_current], rcx
    INCREF_V rcx, rdx
    mov rcx, [rbx + PyRangeObject.vstep]
    mov [rax + PyLongRangeIterObject.it_step], rcx
    INCREF_V rcx, rdx
    mov rcx, [rbp - RLN_LEN]
    mov [rax + PyLongRangeIterObject.it_len], rcx
    pop rbx
    leave
    ret

.rln_fail_len:
    mov rdi, [rbp - RLN_LEN]
    DECREF_V rdi, rcx
.rln_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC range_longiter_new

;; ============================================================================
;; range_longiter_next(PyLongRangeIterObject *self) -> rax = Value, or 0
;; ============================================================================
RLIN_CUR  equ 8             ; the value being handed out
RLIN_FRAME equ 24           ; + 1 push = 32, 16-aligned
DEF_FUNC range_longiter_next, RLIN_FRAME
    push rbx
    mov rbx, rdi

    ; Exhausted when nothing is left.
    xor eax, eax
    V_PACK_I64 rax, rcx
    mov rsi, rax
    mov rdi, [rbx + PyLongRangeIterObject.it_len]
    mov edx, PY_GT
    call obj_richcompare_bool
    test eax, eax
    jle .rlin_done              ; 0 = exhausted, -1 = a comparison raised

    mov rax, [rbx + PyLongRangeIterObject.it_current]
    mov [rbp - RLIN_CUR], rax          ; the answer, whose reference goes to the caller

    ; current += step
    mov rdi, rax
    mov rsi, [rbx + PyLongRangeIterObject.it_step]
    mov edx, NB_ADD
    call range_binop
    test rax, rax
    jz .rlin_error
    mov [rbx + PyLongRangeIterObject.it_current], rax

    ; len -= 1
    mov rdi, [rbx + PyLongRangeIterObject.it_len]
    mov rax, V_INT(1)
    mov rsi, rax
    mov edx, NB_SUBTRACT
    call range_binop
    test rax, rax
    jz .rlin_error
    mov rdi, [rbx + PyLongRangeIterObject.it_len]
    mov [rbx + PyLongRangeIterObject.it_len], rax
    DECREF_V rdi, rcx

    mov rax, [rbp - RLIN_CUR]          ; the old current, whose reference is handed on
    pop rbx
    leave
    ret

.rlin_error:
    mov rdi, [rbp - RLIN_CUR]
    DECREF_V rdi, rcx
.rlin_done:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC range_longiter_next

;; ============================================================================
;; range_longiter_dealloc(PyObject *self) -> nothing
;; Gives back the three Values it holds, then the object.
;; ============================================================================
DEF_FUNC range_longiter_dealloc, 8  ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyLongRangeIterObject.it_current]
    DECREF_V rdi, rax
    mov rdi, [rbx + PyLongRangeIterObject.it_step]
    DECREF_V rdi, rax
    mov rdi, [rbx + PyLongRangeIterObject.it_len]
    DECREF_V rdi, rax
    mov rdi, rbx
    pop rbx
    leave
    jmp ap_free
END_FUNC range_longiter_dealloc

;; ============================================================================
;; range_obj_dealloc(PyObject *self)
;; ============================================================================
DEF_FUNC range_obj_dealloc, 8       ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyRangeObject.vstart]
    DECREF_V rdi, rax           ; a wide bound is a heap int
    mov rdi, [rbx + PyRangeObject.vstop]
    DECREF_V rdi, rax
    mov rdi, [rbx + PyRangeObject.vstep]
    DECREF_V rdi, rax
    mov rdi, rbx
    pop rbx
    leave
    jmp ap_free
END_FUNC range_obj_dealloc

;; ============================================================================
;; range_obj_sq_length(PyRangeObject *self) -> int64_t
;; Returns max(0, ceil((stop - start) / step))
;; Fails: -1
;; Only for a WIDE range, whose length may not fit: a narrow one's is
;; arithmetic, and a caller that has ruled the wide form out says so.
;; ============================================================================
DEF_FUNC_BARE range_obj_sq_length
    cmp qword [rdi + PyRangeObject.wide], 0
    jne range_wide_length
    mov rax, [rdi + PyRangeObject.stop]
    mov rcx, [rdi + PyRangeObject.start]
    mov rdx, [rdi + PyRangeObject.step]

    test rdx, rdx
    js .neg_step

    ; Positive step: len = max(0, (stop - start - 1) / step + 1) if stop > start
    sub rax, rcx               ; rax = stop - start
    jle .zero
    dec rax                    ; rax = stop - start - 1
    xor edx, edx              ; clear for div (but we need signed)
    mov rcx, [rdi + PyRangeObject.step]
    cqo                        ; sign-extend rax into rdx:rax
    idiv rcx                   ; rax = quotient
    inc rax                    ; +1
    ret

.neg_step:
    ; Negative step: len = max(0, (start - stop - 1) / (-step) + 1) if start > stop
    xchg rax, rcx             ; rax = start, rcx = stop
    sub rax, rcx              ; rax = start - stop
    jle .zero
    dec rax                   ; rax = start - stop - 1
    mov rcx, [rdi + PyRangeObject.step]
    neg rcx                   ; -step
    cqo
    idiv rcx
    inc rax
    ret

.zero:
    xor eax, eax
    ret
END_FUNC range_obj_sq_length

;; ============================================================================
;; range_wide_length(PyRangeObject *self) -> int64_t
;; Fails: -1
;;
;; A wide range's length is an ordinary int, and it may still fit: only
;; `len()` needs an int64, and CPython raises when it does not.  The message
;; is PyNumber_AsSsize_t's, which is what its len() ends up calling.
;; ============================================================================
RWL_LEN   equ 8             ; the length as a Value
RWL_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL range_wide_length, RWL_FRAME
    call range_len_value
    test rax, rax
    jz .rwl_pending
    mov [rbp - RWL_LEN], rax
    V_IS_INT rax, rcx
    jae .rwl_immediate
    mov rdi, rax
    mov edx, TAG_PTR
    call int_fits_i64
    test eax, eax
    jz .rwl_too_wide
    mov rdi, [rbp - RWL_LEN]
    push rdi
    mov edx, TAG_PTR
    call int_to_i64
    pop rdi
    push rax
    DECREF_V rdi, rcx
    pop rax
    leave
    ret
.rwl_immediate:
    V_TO_I64 rax
    leave
    ret
.rwl_too_wide:
    mov rdi, [rbp - RWL_LEN]
    DECREF_V rdi, rcx
    extern exc_OverflowError_type
    SET_EXC exc_OverflowError_type, \
          "Python int too large to convert to C ssize_t"
.rwl_pending:
    ; range_len_value left an exception; -1 is what a failing sq_length is.
    mov rax, -1
    leave
    ret
END_FUNC range_wide_length

;; ============================================================================
;; range_obj_sq_item(PyRangeObject *self, int64_t index) -> fat(rax, edx)
;; Returns start + index * step as SmallInt. Raises IndexError if out of range.
;; Fails: 0
;; ============================================================================
extern exc_IndexError_type
DEF_FUNC range_obj_sq_item
    push rbx
    push r12
    mov rbx, rdi               ; self
    mov r12, rsi               ; index

    ; Get length
    call range_obj_sq_length
    ERR_M1 .sq_item_fail
    ; rax = length

    ; Handle negative index
    test r12, r12
    jns .pos_idx
    add r12, rax               ; index += length
.pos_idx:
    ; Bounds check
    test r12, r12
    jl .index_error
    cmp r12, rax
    jge .index_error

    ; Compute: start + index * step
    mov rax, [rbx + PyRangeObject.step]
    imul rax, r12              ; index * step
    add rax, [rbx + PyRangeObject.start]  ; + start
    RET_TAG_SMALLINT

    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.index_error:
    SET_EXC exc_IndexError_type, "range object index out of range"
.sq_item_fail:
    RET_NULL
    pop r12
    pop rbx
    leave
    ret
END_FUNC range_obj_sq_item

;; ============================================================================
;; range_obj_mp_subscript(PyRangeObject *self, Value key, int keytag) -> Value
;;
;; r[i] and r[a:b:c].  Only integer indexing existed, so a slice reached
;; sq_item and came back as "range object index out of range" --
;; `range(len(x))[::-1]`, which re/_compiler.py uses to walk a subpattern
;; backwards, could not run.  Slicing a range gives a range, computed the way
;; CPython's compute_slice does: the slice's resolved indices are positions in
;; this range, so each maps back through start + i*step.
;; Fails: 0
;; ============================================================================
extern slice_type
extern slice_indices
extern obj_as_index
RMS_SELF  equ 8
RMS_START equ 16
RMS_STEP  equ 24
RMS_FRAME equ 40          ; + 1 push = 56
DEF_FUNC range_obj_mp_subscript, RMS_FRAME
    push rbx
    mov rbx, rdi
    ; Classify from the Value, not from the tag in edx: BINARY_SUBSCR builds
    ; the Value with V_PACK, which clobbers the register the tag was in.
    mov rax, rsi
    V_TEST_PTR rax, rcx
    ja .rms_int                     ; an immediate can only be an index
    test rax, rax
    jz .rms_int
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel slice_type]
    cmp rcx, rdx
    je .rms_slice

.rms_int:
    cmp qword [rbx + PyRangeObject.wide], 0
    je .rms_int_narrow
    ; A wide range indexes over objects: there is no int64 length to check
    ; against and no int64 element to answer with.
    mov rdi, rsi
    V_UNPACK rdi, rdx
    extern obj_as_index_object
    call obj_as_index_object
    ERR_NULL .rms_pending
    mov rdi, rbx
    mov rsi, rax
    call range_wide_item            ; err: its 0 is this slot's own answer
    pop rbx
    leave
    ret
.rms_pending:
    xor eax, eax
    pop rbx
    leave
    ret

.rms_int_narrow:
    ; obj_as_index covers int, bool, an int subclass and __index__.
    mov rdi, rsi
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .rms_pending
    mov rdi, rbx
    mov rsi, rax
    call range_obj_sq_item          ; already a Value -- err: its 0 is this slot's own
    pop rbx
    leave
    ret

.rms_slice:
    cmp qword [rbx + PyRangeObject.wide], 0
    je .rms_slice_narrow
    mov rdi, rbx
    call range_wide_slice           ; err: its 0 is this slot's own answer
    pop rbx
    leave
    ret

.rms_slice_narrow:
    mov [rbp - RMS_SELF], rbx
    mov [rbp - RMS_START], rsi      ; the slice, across the length call
    mov rdi, rbx
    call range_obj_sq_length        ; err: a narrow range, whose length is arithmetic
    mov rdi, [rbp - RMS_START]      ; the slice
    mov rsi, rax                    ; the range's length
    call slice_indices              ; rax = start, rdx = stop, rcx = step
    ERR_M1 .rms_pending

    ; substart = r.start + start * r.step,  substop = r.start + stop * r.step,
    ; substep  = r.step * step.
    mov r8, [rbx + PyRangeObject.step]
    imul rax, r8
    add rax, [rbx + PyRangeObject.start]
    mov [rbp - RMS_START], rax
    imul rdx, r8
    add rdx, [rbx + PyRangeObject.start]
    imul rcx, r8
    mov [rbp - RMS_STEP], rcx

    mov rdi, [rbp - RMS_START]
    mov rsi, rdx
    mov rdx, [rbp - RMS_STEP]
    call range_new
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
END_FUNC range_obj_mp_subscript

;; ============================================================================
;; range_obj_reversed: __reversed__ for range objects
;; Returns a new range_iterator that iterates in reverse.
;; ============================================================================
RREV_SELF equ 8
RREV_LEN  equ 16
RREV_CUR  equ 24
RREV_FRAME equ 40           ; + 1 push = 48, 16-aligned
DEF_FUNC range_obj_reversed, RREV_FRAME
    push rbx
    mov rbx, rdi               ; self = range object

    cmp qword [rbx + PyRangeObject.wide], 0
    jne .rev_wide

    ; Get length
    call range_obj_sq_length  ; err: a narrow range, whose length is arithmetic
    ; rax = length
    test rax, rax
    jz .rev_empty

    ; Last element = start + (length-1) * step
    dec rax
    imul rax, [rbx + PyRangeObject.step]
    add rax, [rbx + PyRangeObject.start]
    push rax                   ; save last_element

    ; Compute new stop = start - step (one before the first element)
    mov rcx, [rbx + PyRangeObject.start]
    mov rdx, [rbx + PyRangeObject.step]
    sub rcx, rdx
    push rcx                   ; save new_stop

    ; New step = -step
    neg rdx
    push rdx                   ; save new_step

    ; Allocate range iterator
    mov edi, PyRangeIterObject_size
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel range_iter_type]
    mov [rax + PyObject.ob_type], rcx

    pop rcx                    ; new_step
    mov [rax + PyRangeIterObject.it_step], rcx
    pop rcx                    ; new_stop
    mov [rax + PyRangeIterObject.it_stop], rcx
    pop rcx                    ; last_element = current
    mov [rax + PyRangeIterObject.it_current], rcx

    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.rev_wide:
    ; The reverse of a wide range: start at the last element and step the
    ; other way, for as many elements as there are.
    mov [rbp - RREV_SELF], rbx
    mov qword [rbp - RREV_LEN], 0
    mov qword [rbp - RREV_CUR], 0
    mov rdi, rbx
    call range_len_value
    test rax, rax
    jz .rev_wide_fail
    mov [rbp - RREV_LEN], rax

    ; last = start + (len - 1) * step
    mov rax, V_INT(1)
    mov rsi, rax
    mov rdi, [rbp - RREV_LEN]
    mov edx, NB_SUBTRACT
    call range_binop
    test rax, rax
    jz .rev_wide_fail
    mov [rbp - RREV_CUR], rax
    mov rdi, rax
    mov rsi, [rbx + PyRangeObject.vstep]
    mov edx, NB_MULTIPLY
    call range_binop
    push rax
    mov rdi, [rbp - RREV_CUR]
    DECREF_V rdi, rcx
    pop rax
    test rax, rax
    jz .rev_wide_fail
    mov [rbp - RREV_CUR], rax
    mov rdi, rax
    mov rsi, [rbx + PyRangeObject.vstart]
    mov edx, NB_ADD
    call range_binop
    push rax
    mov rdi, [rbp - RREV_CUR]
    DECREF_V rdi, rcx
    pop rax
    test rax, rax
    jz .rev_wide_fail
    mov [rbp - RREV_CUR], rax

    mov edi, PyLongRangeIterObject_size
    call ap_malloc
    test rax, rax
    jz .rev_wide_fail
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel longrange_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov rcx, [rbp - RREV_CUR]
    mov [rax + PyLongRangeIterObject.it_current], rcx
    mov rcx, [rbp - RREV_LEN]
    mov [rax + PyLongRangeIterObject.it_len], rcx
    push rax
    ; -step, which is a subtraction from zero: negation over objects has no
    ; slot of its own here.
    xor eax, eax
    V_PACK_I64 rax, rcx
    mov rdi, rax
    mov rsi, [rbx + PyRangeObject.vstep]
    mov edx, NB_SUBTRACT
    call range_binop
    pop rcx
    test rax, rax
    jz .rev_wide_fail_iter
    mov [rcx + PyLongRangeIterObject.it_step], rax
    mov rax, rcx
    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.rev_wide_fail_iter:
    mov qword [rbp - RREV_CUR], 0   ; the iterator owns them now
    mov qword [rbp - RREV_LEN], 0
    mov rdi, rcx
    call ap_free
.rev_wide_fail:
    mov rdi, [rbp - RREV_LEN]
    XDECREF_V rdi, rcx
    mov rdi, [rbp - RREV_CUR]
    XDECREF_V rdi, rcx
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret

.rev_empty:
    ; Empty range: create iterator that's immediately exhausted
    mov edi, PyRangeIterObject_size
    call ap_malloc
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel range_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyRangeIterObject.it_current], 0
    mov qword [rax + PyRangeIterObject.it_stop], 0
    mov qword [rax + PyRangeIterObject.it_step], 1
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
END_FUNC range_obj_reversed

;; ============================================================================
;; range's own protocol: ==, hash, index, count, and start/stop/step.
;;
;; range had none of it.  `range(3) == range(3)` was False, because with no
;; tp_richcompare the comparison fell back to identity; `{range(3),
;; range(0, 3, 1)}` held two elements where CPython holds one; and
;; `r.start`, `r.index(x)` and `r.count(x)` were all AttributeError.  A range
;; is a value, and the stdlib treats it as one.
;; ============================================================================

;; range_obj_richcompare(rdi = self, rsi = other, edx = op) -> Value
;;
;; CPython's rule, which is NOT field-by-field: two ranges are equal when
;; they generate the same sequence.  Empty ranges are all equal to each
;; other -- range(0) == range(5, 3) -- a one-element range ignores its step,
;; and only from two elements up does the step matter.  So range(0, 3, 1)
;; == range(3) even though the objects differ.
DEF_FUNC range_obj_richcompare, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx

    cmp r13d, PY_EQ
    je .rrc_eq
    cmp r13d, PY_NE
    je .rrc_eq
    jmp .rrc_notimpl            ; ranges are unordered, as CPython has them

.rrc_eq:
    V_TEST_PTR r12, rax
    ja .rrc_notimpl
    test r12, r12
    jz .rrc_notimpl
    mov rax, [r12 + PyObject.ob_type]
    lea rcx, [rel range_obj_type]
    cmp rax, rcx
    jne .rrc_notimpl

    ; A wide range on either side is compared over objects: neither its
    ; length nor its bounds fit an int64.
    cmp qword [rbx + PyRangeObject.wide], 0
    jne .rrc_wide
    cmp qword [r12 + PyRangeObject.wide], 0
    jne .rrc_wide

    mov rdi, rbx
    call range_obj_sq_length  ; err: a narrow range, whose length is arithmetic
    mov rdi, rax                ; our length
    push rdi
    mov rdi, r12
    call range_obj_sq_length  ; err: a narrow range, whose length is arithmetic
    pop rdi
    cmp rdi, rax
    jne .rrc_false
    test rdi, rdi
    jz .rrc_true                ; both empty: equal whatever the fields say

    mov rax, [rbx + PyRangeObject.start]
    cmp rax, [r12 + PyRangeObject.start]
    jne .rrc_false
    cmp rdi, 1
    je .rrc_true                ; one element: the step cannot be observed

    mov rax, [rbx + PyRangeObject.step]
    cmp rax, [r12 + PyRangeObject.step]
    jne .rrc_false

.rrc_wide:
    mov rdi, rbx
    mov rsi, r12
    call range_wide_eq
    test eax, eax
    js .rrc_notimpl             ; a comparison raised; it is pending
    jz .rrc_false
    jmp .rrc_true

.rrc_true:
    cmp r13d, PY_NE
    je .rrc_ret_false
.rrc_ret_true:
    RET_TRUE
    jmp .rrc_out
.rrc_false:
    cmp r13d, PY_NE
    je .rrc_ret_true
.rrc_ret_false:
    RET_FALSE
.rrc_out:
    pop r13
    pop r12
    pop rbx
    leave
    ret
.rrc_notimpl:
    ; tp_richcompare declines with NULL and nothing pending -- not with the
    ; NotImplemented object.  Returning the object made `range(1) < range(2)`
    ; answer NotImplemented instead of raising, because the caller took it
    ; for the result.
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC range_obj_richcompare

;; range_obj_hash(rdi = self) -> rax = the hash
;;
;; Equal ranges must hash alike, so this hashes exactly what the comparison
;; looks at: the length, then the start once there is an element, then the
;; step once there are two.  CPython hashes the tuple (len, start, step) with
;; None standing in for the fields that do not count; the mixing here is the
;; same shape without building the tuple.
ROH_LEN   equ 8             ; the length as a Value, on the wide path
ROH_ACC   equ 16            ; the hash so far, across the calls that mix it
ROH_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC range_obj_hash, ROH_FRAME
    push rbx
    mov rbx, rdi
    cmp qword [rdi + PyRangeObject.wide], 0
    jne .roh_wide
    call range_obj_sq_length  ; err: a narrow range, whose length is arithmetic
    mov rcx, rax                ; the length

    mov eax, 0x345678
    imul rax, 1000003
    xor rax, rcx
    test rcx, rcx
    jz .roh_done

    mov rdx, [rbx + PyRangeObject.start]
    imul rax, 1000003
    xor rax, rdx
    cmp rcx, 1
    je .roh_done

    mov rdx, [rbx + PyRangeObject.step]
    imul rax, 1000003
    xor rax, rdx
.roh_wide:
    ; The same three, hashed as objects: a wide range has no int64 length and
    ; no int64 bounds, and equal ranges must still hash alike.
    call range_len_value
    test rax, rax
    jz .roh_failed
    mov [rbp - ROH_LEN], rax
    mov rdi, rax
    extern obj_hash
    call obj_hash               ; err: an int, whose hash cannot raise
    mov rcx, rax

    mov eax, 0x345678
    imul rax, 1000003
    xor rax, rcx
    mov [rbp - ROH_ACC], rax

    xor eax, eax
    V_PACK_I64 rax, rcx
    mov rdi, [rbp - ROH_LEN]
    mov rsi, rax
    mov edx, PY_EQ
    call obj_richcompare_bool
    test eax, eax
    jnz .roh_wide_done          ; empty, or the comparison raised

    mov rdi, [rbx + PyRangeObject.vstart]
    call obj_hash               ; err: an int, whose hash cannot raise
    mov rcx, rax
    mov rax, [rbp - ROH_ACC]
    imul rax, 1000003
    xor rax, rcx
    mov [rbp - ROH_ACC], rax

    mov rax, V_INT(1)
    mov rdi, [rbp - ROH_LEN]
    mov rsi, rax
    mov edx, PY_EQ
    call obj_richcompare_bool
    test eax, eax
    jnz .roh_wide_done          ; one element: the step cannot be observed

    mov rdi, [rbx + PyRangeObject.vstep]
    call obj_hash               ; err: an int, whose hash cannot raise
    mov rcx, rax
    mov rax, [rbp - ROH_ACC]
    imul rax, 1000003
    xor rax, rcx
    mov [rbp - ROH_ACC], rax
.roh_wide_done:
    mov rdi, [rbp - ROH_LEN]
    DECREF_V rdi, rcx
    mov rax, [rbp - ROH_ACC]
    jmp .roh_done
.roh_failed:
    mov rax, -1
    pop rbx
    leave
    ret

.roh_done:
    ; -1 is the error signal everywhere a hash is consumed.
    cmp rax, -1
    jne .roh_out
    mov rax, -2
.roh_out:
    pop rbx
    leave
    ret
END_FUNC range_obj_hash

;; range_index_of(rdi = self, rsi = the value as an i64, rdx = out flag)
;;   -> rax = the index, or -1 when the value is not in the range
DEF_FUNC_BARE range_index_of
    mov rcx, [rdi + PyRangeObject.start]
    sub rsi, rcx                ; value - start
    mov rcx, [rdi + PyRangeObject.step]
    mov rax, rsi
    cqo
    idiv rcx                    ; rax = quotient, rdx = remainder
    test rdx, rdx
    jnz .rio_no                 ; not on the step grid
    test rax, rax
    js .rio_no                  ; before the start
    push rax
    call range_obj_sq_length  ; err: a narrow range, whose length is arithmetic
    pop rcx
    cmp rcx, rax
    jge .rio_no                 ; past the end
    mov rax, rcx
    ret
.rio_no:
    mov rax, -1
    ret
END_FUNC range_index_of

;; range_arg_i64(rdi = a Value, rsi = out) -> eax = 1 and [rsi] = the number,
;; or eax = 0 when the value is not an integer at all.
DEF_FUNC range_arg_i64, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rsi
    V_IS_INT rdi, rax
    jb .rai_not_immediate
    V_TO_I64 rdi
    mov [rbx], rdi
    mov eax, 1
    pop rbx
    leave
    ret
.rai_not_immediate:
    V_TEST_PTR rdi, rax
    ja .rai_no
    test rdi, rdi
    jz .rai_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .rai_heap_int
    lea rcx, [rel bool_type]
    cmp rax, rcx
    je .rai_heap_int
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_INT_SUBCLASS
    jz .rai_no
.rai_heap_int:
    extern int_to_i64
    call int_to_i64
    mov [rbx], rax
    mov eax, 1
    pop rbx
    leave
    ret
.rai_no:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC range_arg_i64
;; ============================================================================
;; range_obj_sq_contains(rdi = the range, rsi = a Value) -> eax = 0 or 1
;;
;; `x in range(n)` is arithmetic, not a walk: range_index_of already answers
;; where a value would sit, and -1 for one that is not a member.  Without the
;; slot, `x in r` fell through to CONTAINS_OP's iterating fallback -- correct
;; but O(n) -- and `r.__contains__(x)` raised, because generic_method_contains
;; has nothing to call.  Anything that is not an integer is compared the slow
;; way, as CPython does, so `1.0 in range(3)` is still True.
;; Fails: -1
;; ============================================================================
RSC_VAL   equ 8
RSC_SELF  equ 16
RSC_ARG   equ 24             ; the argument as a Value, for the walk below
RSC_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL range_obj_sq_contains, RSC_FRAME
    mov [rbp - RSC_SELF], rdi
    mov [rbp - RSC_ARG], rsi
    cmp qword [rdi + PyRangeObject.wide], 0
    jne .rsc_wide
    mov rdi, rsi
    lea rsi, [rbp - RSC_VAL]
    call range_arg_i64
    test eax, eax
    jz .rsc_walk
    mov rdi, [rbp - RSC_SELF]
    mov rsi, [rbp - RSC_VAL]
    call range_index_of
    cmp rax, -1
    je .rsc_no
    mov eax, 1
    leave
    ret

.rsc_wide:
    ; A wide range answers by arithmetic over objects; a member of one does
    ; not fit an int64 either.
    call range_wide_index
    test rax, rax
    jz .rsc_no
    mov rdi, rax
    DECREF_V rdi, rcx
    mov eax, 1
    leave
    ret

.rsc_walk:
    ; Not an integer.  A float or a bool can still equal a member, and
    ; CPython answers by walking.
    push rbx
    push r12
    push r13
    sub rsp, 8                  ; 3 pushes + this = 32, so rsp stays aligned
    mov r13, [rbp - RSC_ARG]    ; range_arg_i64 clobbered rsi
    mov rbx, [rbp - RSC_SELF]
    mov rdi, rbx
    call range_obj_sq_length  ; err: a narrow range, whose length is arithmetic
    mov r12, rax                ; the count
.rsc_loop:
    test r12, r12
    jle .rsc_walk_no
    dec r12
    mov rdi, rbx
    mov rsi, r12
    call range_obj_sq_item      ; returns a Value -- err: the index is below the length
    mov rdi, rax
    mov rsi, r13
    mov edx, CMP_EQ
    call obj_richcompare_bool
    test eax, eax
    jg .rsc_walk_yes
    js .rsc_walk_raised         ; the comparison raised: -1, as sq_contains says it
    jmp .rsc_loop
.rsc_walk_yes:
    mov eax, 1
    jmp .rsc_walk_done
.rsc_walk_raised:
    mov rax, -1
    jmp .rsc_walk_done
.rsc_walk_no:
    xor eax, eax
.rsc_walk_done:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    leave
    ret

.rsc_no:
    xor eax, eax
    leave
    ret
END_FUNC range_obj_sq_contains


;; range_method_index(args, nargs) -> the index of the value
;; Fails: 0
RMI_VAL   equ 8
RMI_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC range_method_index, RMI_FRAME
    push rbx
    cmp rsi, 2
    jne .rmi_arity
    mov rbx, [rdi]              ; self
    mov rdi, [rdi + 8]
    cmp qword [rbx + PyRangeObject.wide], 0
    jne .rmi_wide
    lea rsi, [rbp - RMI_VAL]
    call range_arg_i64
    test eax, eax
    jz .rmi_not_integer         ; a non-integer could never be a member
    mov rdi, rbx
    mov rsi, [rbp - RMI_VAL]
    call range_index_of
    cmp rax, -1
    je .rmi_missing
    mov edx, TAG_SMALLINT
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.rmi_wide:
    ; A wide range answers with an index object, which is what CPython's
    ; range_index does over a long: `range(1 << 71).index(1 << 70)` is not an
    ; int64 either.
    mov rsi, rdi
    mov rdi, rbx
    call range_wide_index
    test rax, rax
    jz .rmi_wide_missing
    pop rbx
    leave
    ret
.rmi_wide_missing:
.rmi_not_integer:
    SET_EXC exc_ValueError_type, "sequence.index(x): x not in sequence"
    jmp .rmi_fail

.rmi_missing:
    ; CPython has two wordings here and they differ by what was asked for:
    ; an integer that is simply not a member names itself, and anything that
    ; could never be a member at all gets the generic sequence message.
    mov rsi, [rbp - RMI_VAL]
    call range_set_not_in
    jmp .rmi_fail
.rmi_arity:
    SET_EXC exc_TypeError_type, "index() takes exactly one argument"
.rmi_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC range_method_index

;; range_set_not_in(rsi = the value) -> rax = 0, always, with it pending
;; "6 is not in range", CPython's wording for an integer that is not a member.
RRN_N     equ 8
RRN_BUF   equ 176
RRN_FRAME equ 176           ; + 0 pushes = 176, 16-aligned
DEF_FUNC_LOCAL range_set_not_in, RRN_FRAME
    mov [rbp - RRN_N], rsi
    lea rdi, [rbp - RRN_BUF]
    CSTRING rsi, ""
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RRN_N]
    extern msg_append_i64
    call msg_append_i64
    mov rdi, rax
    CSTRING rsi, " is not in range"
    call rbt_append_cstr
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rbp - RRN_BUF]
    call set_exception
    leave
    ret                         ; rax = 0, with it pending
END_FUNC range_set_not_in

;; range_method_count(args, nargs) -> 1 when the value is in the range, else 0
;; Fails: 0
RMC_VAL   equ 8
RMC_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC range_method_count, RMC_FRAME
    push rbx
    cmp rsi, 2
    jne .rmc_arity
    mov rbx, [rdi]
    mov rdi, [rdi + 8]
    cmp qword [rbx + PyRangeObject.wide], 0
    jne .rmc_wide
    lea rsi, [rbp - RMC_VAL]
    call range_arg_i64
    test eax, eax
    jz .rmc_zero
    mov rdi, rbx
    mov rsi, [rbp - RMC_VAL]
    call range_index_of
    cmp rax, -1
    je .rmc_zero
    mov eax, 1
    jmp .rmc_out
.rmc_zero:
    xor eax, eax
.rmc_out:
    mov edx, TAG_SMALLINT
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.rmc_wide:
    mov rsi, rdi
    mov rdi, rbx
    call range_wide_index
    test rax, rax
    jz .rmc_zero
    mov rdi, rax
    DECREF_V rdi, rcx
    mov eax, 1
    mov edx, TAG_SMALLINT
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.rmc_arity:
    SET_EXC exc_TypeError_type, "count() takes exactly one argument"
    pop rbx
    leave
    ret
END_FUNC range_method_count

;; The three fields, as getset descriptors.  A range is immutable, so there
;; is no setter.
%macro DEF_RANGE_GETTER 1
DEF_FUNC range_get_%1
    ; The Value, not the int64 beside it: a wide bound has no int64.
    mov rax, [rdi + PyRangeObject.v%1]
    INCREF_V rax, rcx
    leave
    ret
END_FUNC range_get_%1
%endmacro
DEF_RANGE_GETTER start
DEF_RANGE_GETTER stop
DEF_RANGE_GETTER step

;; The by-name protocol.  range answered `hasattr(range, "index")` and
;; `hasattr(range, "__getitem__")` with False, because range_obj_type had no
;; tp_dict at all -- every one of these lived only in a slot.  The stdlib asks
;; by name: collections.abc.Sequence.register(range) leans on __getitem__ and
;; __len__ being there, and reversed(range(n)) goes through __reversed__.
;; Fails: 0
DEF_FUNC range_dunder_getitem
    cmp rsi, 2
    jne .rdg_bad
    mov rax, [rdi]
    mov rsi, [rdi + 8]
    mov rdi, rax
    call range_obj_mp_subscript ; err: its 0 is this builtin's own answer
    leave
    ret
.rdg_bad:
    SET_EXC exc_TypeError_type, "__getitem__() takes exactly one argument"
    leave
    ret
END_FUNC range_dunder_getitem

DEF_FUNC range_dunder_reversed
    test rsi, rsi
    jz .rdr_bad
    mov rdi, [rdi]
    call range_obj_reversed
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.rdr_bad:
    SET_EXC exc_TypeError_type, "__reversed__() takes no arguments"
    leave
    ret
END_FUNC range_dunder_reversed

;; ============================================================================
;; range_binop(Value left, Value right, int op) -> rax = Value, owned, or 0
;; The arithmetic a wide range's bounds need, over objects rather than
;; int64s.  Neither operand is consumed.
;; ============================================================================
DEF_FUNC_LOCAL range_binop, 16      ; + 0 pushes = 16, 16-aligned
    INCREF_V rdi, rax
    INCREF_V rsi, rax
    extern obj_binary_op
    call obj_binary_op          ; consumes both
    leave
    ret
END_FUNC range_binop

;; ============================================================================
;; range_len_value(PyRangeObject *self) -> rax = the length as a Value, owned,
;;                                         or 0 with an exception pending
;;
;; max(0, (stop - start + step -/+ 1) // step), in object arithmetic.  A wide
;; range has no int64 length -- that is what makes len() an OverflowError in
;; CPython -- but the length itself is an ordinary int, and indexing,
;; iteration and reversal all need it.
;; ============================================================================
RLV_SELF  equ 8
RLV_A     equ 16
RLV_B     equ 24
RLV_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC_LOCAL range_len_value, RLV_FRAME
    push rbx
    mov [rbp - RLV_SELF], rdi
    mov qword [rbp - RLV_A], 0
    mov qword [rbp - RLV_B], 0

    ; d = stop - start
    mov rax, [rbp - RLV_SELF]
    mov rdi, [rax + PyRangeObject.vstop]
    mov rsi, [rax + PyRangeObject.vstart]
    mov edx, NB_SUBTRACT
    call range_binop
    test rax, rax
    jz .rlv_fail
    mov [rbp - RLV_A], rax

    ; ...adjusted toward zero by one step, so the division rounds up.
    mov rdi, [rbp - RLV_SELF]
    mov rsi, [rdi + PyRangeObject.vstep]
    mov rdi, [rbp - RLV_A]
    mov edx, NB_ADD
    call range_binop
    test rax, rax
    jz .rlv_fail
    mov [rbp - RLV_B], rax
    mov rdi, [rbp - RLV_A]
    DECREF_V rdi, rcx
    mov qword [rbp - RLV_A], 0

    ; ...minus the sign of the step, which is what "-/+ 1" amounts to.
    mov rdi, [rbp - RLV_SELF]
    cmp qword [rdi + PyRangeObject.step], 0
    mov eax, 1
    jg .rlv_have_one
    mov rax, -1                 ; the 32-bit form zero-extends
.rlv_have_one:
    V_PACK_I64 rax, rcx
    mov rsi, rax
    mov rdi, [rbp - RLV_B]
    mov edx, NB_SUBTRACT
    call range_binop
    test rax, rax
    jz .rlv_fail
    mov [rbp - RLV_A], rax
    mov rdi, [rbp - RLV_B]
    DECREF_V rdi, rcx
    mov qword [rbp - RLV_B], 0

    ; // step
    mov rdi, [rbp - RLV_SELF]
    mov rsi, [rdi + PyRangeObject.vstep]
    mov rdi, [rbp - RLV_A]
    mov edx, NB_FLOOR_DIVIDE
    call range_binop
    test rax, rax
    jz .rlv_fail
    mov [rbp - RLV_B], rax
    mov rdi, [rbp - RLV_A]
    DECREF_V rdi, rcx
    mov qword [rbp - RLV_A], 0

    ; ...and never below zero.
    xor eax, eax
    V_PACK_I64 rax, rcx
    mov rdi, [rbp - RLV_B]
    mov rsi, rax
    mov edx, PY_LT
    extern obj_richcompare_bool
    call obj_richcompare_bool
    test eax, eax
    jle .rlv_done               ; -1 is an error, 0 is "not negative"
    mov rdi, [rbp - RLV_B]
    DECREF_V rdi, rcx
    xor eax, eax
    V_PACK_I64 rax, rcx
    mov [rbp - RLV_B], rax
.rlv_done:
    mov rax, [rbp - RLV_B]
    pop rbx
    leave
    ret

.rlv_fail:
    mov rdi, [rbp - RLV_A]
    XDECREF_V rdi, rcx
    mov rdi, [rbp - RLV_B]
    XDECREF_V rdi, rcx
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC range_len_value

;; ============================================================================
;; range_wide_item(PyRangeObject *self, Value i) -> rax = Value, owned, or 0
;;
;; r[i] over objects.  The index is an OWNED reference this consumes.  A
;; negative one counts from the end, which needs the length -- itself an
;; object, because a wide range has no int64 one.
;; Fails: 0
;; ============================================================================
RWI_SELF  equ 8
RWI_I     equ 16
RWI_LEN   equ 24
RWI_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL range_wide_item, RWI_FRAME
    mov [rbp - RWI_SELF], rdi
    mov [rbp - RWI_I], rsi
    mov qword [rbp - RWI_LEN], 0
    call range_len_value
    test rax, rax
    jz .rwi_fail
    mov [rbp - RWI_LEN], rax

    ; A negative index counts from the end.
    xor eax, eax
    V_PACK_I64 rax, rcx
    mov rdi, [rbp - RWI_I]
    mov rsi, rax
    mov edx, PY_LT
    call obj_richcompare_bool
    test eax, eax
    js .rwi_fail
    jz .rwi_have_i
    mov rdi, [rbp - RWI_I]
    mov rsi, [rbp - RWI_LEN]
    mov edx, NB_ADD
    call range_binop
    test rax, rax
    jz .rwi_fail
    mov rdi, [rbp - RWI_I]
    mov [rbp - RWI_I], rax
    DECREF_V rdi, rcx

.rwi_have_i:
    ; 0 <= i < len
    xor eax, eax
    V_PACK_I64 rax, rcx
    mov rdi, [rbp - RWI_I]
    mov rsi, rax
    mov edx, PY_LT
    call obj_richcompare_bool
    test eax, eax
    js .rwi_fail
    jnz .rwi_out_of_range
    mov rdi, [rbp - RWI_I]
    mov rsi, [rbp - RWI_LEN]
    mov edx, PY_LT
    call obj_richcompare_bool
    test eax, eax
    js .rwi_fail
    jz .rwi_out_of_range

    ; start + i * step
    mov rax, [rbp - RWI_SELF]
    mov rdi, [rbp - RWI_I]
    mov rsi, [rax + PyRangeObject.vstep]
    mov edx, NB_MULTIPLY
    call range_binop
    test rax, rax
    jz .rwi_fail
    mov rdi, [rbp - RWI_I]
    mov [rbp - RWI_I], rax
    DECREF_V rdi, rcx
    mov rax, [rbp - RWI_SELF]
    mov rdi, [rbp - RWI_I]
    mov rsi, [rax + PyRangeObject.vstart]
    mov edx, NB_ADD
    call range_binop
    push rax
    mov rdi, [rbp - RWI_I]
    DECREF_V rdi, rcx
    mov rdi, [rbp - RWI_LEN]
    DECREF_V rdi, rcx
    pop rax
    leave
    ret

.rwi_out_of_range:
    mov rdi, [rbp - RWI_I]
    DECREF_V rdi, rcx
    mov rdi, [rbp - RWI_LEN]
    DECREF_V rdi, rcx
    SET_EXC exc_IndexError_type, "range object index out of range"
    leave
    ret

.rwi_fail:
    mov rdi, [rbp - RWI_I]
    XDECREF_V rdi, rcx
    mov rdi, [rbp - RWI_LEN]
    XDECREF_V rdi, rcx
    xor eax, eax
    leave
    ret
END_FUNC range_wide_item

;; ============================================================================
;; range_wide_index(PyRangeObject *self, Value v) -> rax = the index as a
;;   Value, owned, or 0 when v is not a member
;;
;; (v - start) // step, when that division is exact and the quotient is in
;; range.  Neither operand is consumed.  Over objects, because a wide range's
;; members do not fit an int64 -- `(1 << 70) in range(1 << 71)` reached the
;; int64 path and asked a saturated question.
;; ============================================================================
RWX_SELF  equ 8
RWX_D     equ 16
RWX_I     equ 24
RWX_LEN   equ 32
RWX_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC_LOCAL range_wide_index, RWX_FRAME
    mov [rbp - RWX_SELF], rdi
    mov qword [rbp - RWX_D], 0
    mov qword [rbp - RWX_I], 0
    mov qword [rbp - RWX_LEN], 0

    ; d = v - start
    mov rdi, rsi
    mov rax, [rbp - RWX_SELF]
    mov rsi, [rax + PyRangeObject.vstart]
    mov edx, NB_SUBTRACT
    call range_binop
    test rax, rax
    jz .rwx_no
    mov [rbp - RWX_D], rax

    ; ...which has to be a whole number of steps.
    mov rdi, rax
    mov rax, [rbp - RWX_SELF]
    mov rsi, [rax + PyRangeObject.vstep]
    mov edx, NB_REMAINDER
    call range_binop
    test rax, rax
    jz .rwx_no
    mov [rbp - RWX_I], rax
    xor eax, eax
    V_PACK_I64 rax, rcx
    mov rdi, [rbp - RWX_I]
    mov rsi, rax
    mov edx, PY_EQ
    call obj_richcompare_bool
    push rax
    mov rdi, [rbp - RWX_I]
    mov qword [rbp - RWX_I], 0
    DECREF_V rdi, rcx
    pop rax
    test eax, eax
    jle .rwx_no

    ; i = d // step
    mov rdi, [rbp - RWX_D]
    mov rax, [rbp - RWX_SELF]
    mov rsi, [rax + PyRangeObject.vstep]
    mov edx, NB_FLOOR_DIVIDE
    call range_binop
    test rax, rax
    jz .rwx_no
    mov [rbp - RWX_I], rax

    ; 0 <= i < len
    mov rdi, [rbp - RWX_SELF]
    call range_len_value
    test rax, rax
    jz .rwx_no
    mov [rbp - RWX_LEN], rax
    xor eax, eax
    V_PACK_I64 rax, rcx
    mov rdi, [rbp - RWX_I]
    mov rsi, rax
    mov edx, PY_LT
    call obj_richcompare_bool
    test eax, eax
    jnz .rwx_no                 ; negative, or the comparison raised
    mov rdi, [rbp - RWX_I]
    mov rsi, [rbp - RWX_LEN]
    mov edx, PY_LT
    call obj_richcompare_bool
    test eax, eax
    jle .rwx_no

    mov rdi, [rbp - RWX_D]
    DECREF_V rdi, rcx
    mov rdi, [rbp - RWX_LEN]
    DECREF_V rdi, rcx
    mov rax, [rbp - RWX_I]
    leave
    ret

.rwx_no:
    mov rdi, [rbp - RWX_D]
    XDECREF_V rdi, rcx
    mov rdi, [rbp - RWX_I]
    XDECREF_V rdi, rcx
    mov rdi, [rbp - RWX_LEN]
    XDECREF_V rdi, rcx
    xor eax, eax
    leave
    ret
END_FUNC range_wide_index

;; ============================================================================
;; range_wide_eq(PyRangeObject *a, PyRangeObject *b) -> eax = 1, 0, or -1
;;
;; CPython's rule over objects: same length, then same start once there is an
;; element, then same step once there are two.
;; ============================================================================
RWE_A     equ 8
RWE_B     equ 16
RWE_LA    equ 24
RWE_LB    equ 32
RWE_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC_LOCAL range_wide_eq, RWE_FRAME
    mov [rbp - RWE_A], rdi
    mov [rbp - RWE_B], rsi
    mov qword [rbp - RWE_LA], 0
    mov qword [rbp - RWE_LB], 0
    call range_len_value
    test rax, rax
    jz .rwe_err
    mov [rbp - RWE_LA], rax
    mov rdi, [rbp - RWE_B]
    call range_len_value
    test rax, rax
    jz .rwe_err
    mov [rbp - RWE_LB], rax

    mov rdi, [rbp - RWE_LA]
    mov rsi, [rbp - RWE_LB]
    mov edx, PY_EQ
    call obj_richcompare_bool
    test eax, eax
    js .rwe_err
    jz .rwe_no

    xor eax, eax
    V_PACK_I64 rax, rcx
    mov rdi, [rbp - RWE_LA]
    mov rsi, rax
    mov edx, PY_EQ
    call obj_richcompare_bool
    test eax, eax
    js .rwe_err
    jnz .rwe_yes                ; both empty: equal whatever the fields say

    mov rax, [rbp - RWE_A]
    mov rcx, [rbp - RWE_B]
    mov rdi, [rax + PyRangeObject.vstart]
    mov rsi, [rcx + PyRangeObject.vstart]
    mov edx, PY_EQ
    call obj_richcompare_bool
    test eax, eax
    js .rwe_err
    jz .rwe_no

    mov rax, V_INT(1)
    mov rdi, [rbp - RWE_LA]
    mov rsi, rax
    mov edx, PY_EQ
    call obj_richcompare_bool
    test eax, eax
    js .rwe_err
    jnz .rwe_yes                ; one element: the step cannot be observed

    mov rax, [rbp - RWE_A]
    mov rcx, [rbp - RWE_B]
    mov rdi, [rax + PyRangeObject.vstep]
    mov rsi, [rcx + PyRangeObject.vstep]
    mov edx, PY_EQ
    call obj_richcompare_bool
    test eax, eax
    js .rwe_err
    jz .rwe_no
.rwe_yes:
    mov eax, 1
    jmp .rwe_out
.rwe_no:
    xor eax, eax
    jmp .rwe_out
.rwe_err:
    mov eax, -1
.rwe_out:
    push rax
    mov rdi, [rbp - RWE_LA]
    XDECREF_V rdi, rcx
    mov rdi, [rbp - RWE_LB]
    XDECREF_V rdi, rcx
    pop rax
    leave
    ret
END_FUNC range_wide_eq

;; ============================================================================
;; range_obj_bool(PyRangeObject *self) -> eax = 1, 0, or -1
;; Whether it has any elements, which for a wide range is an object question.
;; ============================================================================
ROB_LEN   equ 8             ; the length as a Value
ROB_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL range_obj_bool, ROB_FRAME
    cmp qword [rdi + PyRangeObject.wide], 0
    jne .rob_wide
    call range_obj_sq_length  ; err: a narrow range, whose length is arithmetic
    test rax, rax
    setne al
    movzx eax, al
    leave
    ret
.rob_wide:
    call range_len_value
    test rax, rax
    jz .rob_failed
    mov [rbp - ROB_LEN], rax
    xor ecx, ecx
    V_PACK_I64 rcx, rdx
    mov rdi, rax
    mov rsi, rcx
    mov edx, PY_EQ
    call obj_richcompare_bool
    push rax
    mov rdi, [rbp - ROB_LEN]
    DECREF_V rdi, rcx
    pop rax
    test eax, eax
    js .rob_failed
    xor eax, 1                  ; equal to zero means false
    leave
    ret
.rob_failed:
    mov eax, -1
    leave
    ret
END_FUNC range_obj_bool

;; ============================================================================
;; range_clamp_bound(Value given, Value len, Value lower, Value upper,
;;                   int negative_step) -> rax = a Value, owned, or 0
;;
;; One bound of a slice, resolved against a length that is an object.  None
;; means the end the step comes from; a negative index counts back from the
;; length; and the result is clamped to [lower, upper].  This is
;; _PySlice_GetLongIndices' inner half, which CPython does over objects for
;; exactly this reason.  Nothing here is consumed.
;; ============================================================================
RCB_GIVEN equ 8
RCB_LEN   equ 16
RCB_LOWER equ 24
RCB_UPPER equ 32
RCB_NEG   equ 40
RCB_CUR   equ 48
RCB_FRAME equ 64            ; + 0 pushes = 64, 16-aligned
DEF_FUNC_LOCAL range_clamp_bound, RCB_FRAME
    mov [rbp - RCB_GIVEN], rdi
    mov [rbp - RCB_LEN], rsi
    mov [rbp - RCB_LOWER], rdx
    mov [rbp - RCB_UPPER], rcx
    mov [rbp - RCB_NEG], r8

    IS_NONE rdi, rax
    jne .rcb_given
    ; None: the end the step comes from.
    cmp qword [rbp - RCB_NEG], 0
    je .rcb_none_forward
    mov rax, [rbp - RCB_UPPER]
    jmp .rcb_keep
.rcb_none_forward:
    mov rax, [rbp - RCB_LOWER]
.rcb_keep:
    INCREF_V rax, rcx
    leave
    ret

.rcb_given:
    mov rax, rdi
    INCREF_V rax, rcx
    mov [rbp - RCB_CUR], rax

    ; A negative index counts back from the length.
    xor eax, eax
    V_PACK_I64 rax, rcx
    mov rdi, [rbp - RCB_CUR]
    mov rsi, rax
    mov edx, PY_LT
    call obj_richcompare_bool
    test eax, eax
    js .rcb_fail
    jz .rcb_clamp
    mov rdi, [rbp - RCB_CUR]
    mov rsi, [rbp - RCB_LEN]
    mov edx, NB_ADD
    call range_binop
    push rax
    mov rdi, [rbp - RCB_CUR]
    DECREF_V rdi, rcx
    pop rax
    test rax, rax
    jz .rcb_fail_cleared
    mov [rbp - RCB_CUR], rax

.rcb_clamp:
    mov rdi, [rbp - RCB_CUR]
    mov rsi, [rbp - RCB_LOWER]
    mov edx, PY_LT
    call obj_richcompare_bool
    test eax, eax
    js .rcb_fail
    jz .rcb_clamp_high
    mov rdi, [rbp - RCB_CUR]
    DECREF_V rdi, rcx
    mov rax, [rbp - RCB_LOWER]
    INCREF_V rax, rcx
    leave
    ret
.rcb_clamp_high:
    mov rdi, [rbp - RCB_UPPER]
    mov rsi, [rbp - RCB_CUR]
    mov edx, PY_LT
    call obj_richcompare_bool
    test eax, eax
    js .rcb_fail
    jz .rcb_done
    mov rdi, [rbp - RCB_CUR]
    DECREF_V rdi, rcx
    mov rax, [rbp - RCB_UPPER]
    INCREF_V rax, rcx
    leave
    ret
.rcb_done:
    mov rax, [rbp - RCB_CUR]
    leave
    ret

.rcb_fail:
    mov rdi, [rbp - RCB_CUR]
    XDECREF_V rdi, rcx
.rcb_fail_cleared:
    xor eax, eax
    leave
    ret
END_FUNC range_clamp_bound

;; ============================================================================
;; range_wide_slice(PyRangeObject *self, PySliceObject *slice)
;;   -> rax = a new range Value, or 0
;;
;; r[a:b:c] where r's bounds do not fit an int64.  CPython's compute_slice,
;; over objects: resolve the slice against the length, then map each position
;; back through start + i*step.
;; Fails: 0
;; ============================================================================
RWS_SELF  equ 8
RWS_SLICE equ 16
RWS_LEN   equ 24
RWS_STEP  equ 32
RWS_START equ 40
RWS_STOP  equ 48
RWS_TMP   equ 56
RWS_FRAME equ 64            ; + 0 pushes = 64, 16-aligned
DEF_FUNC_LOCAL range_wide_slice, RWS_FRAME
    mov [rbp - RWS_SELF], rdi
    mov [rbp - RWS_SLICE], rsi
    mov qword [rbp - RWS_LEN], 0
    mov qword [rbp - RWS_STEP], 0
    mov qword [rbp - RWS_START], 0
    mov qword [rbp - RWS_STOP], 0

    call range_len_value
    test rax, rax
    jz .rws_fail
    mov [rbp - RWS_LEN], rax

    ; The slice's own step, defaulting to 1.
    mov rsi, [rbp - RWS_SLICE]
    mov rdi, [rsi + PySliceObject.step]
    IS_NONE rdi, rax
    jne .rws_step_given
    mov rax, V_INT(1)
    mov rdi, rax
.rws_step_given:
    V_UNPACK rdi, rdx
    extern obj_as_index_object
    call obj_as_index_object
    ERR_NULL .rws_fail
    mov [rbp - RWS_STEP], rax
    xor ecx, ecx
    V_PACK_I64 rcx, rdx
    mov rdi, rax
    mov rsi, rcx
    mov edx, PY_EQ
    call obj_richcompare_bool
    test eax, eax
    js .rws_fail
    jnz .rws_zero_step

    ; lower and upper depend on the direction: a backward slice walks
    ; [len-1, -1] where a forward one walks [0, len].
    xor eax, eax
    V_PACK_I64 rax, rcx
    mov rsi, rax
    mov rdi, [rbp - RWS_STEP]
    mov edx, PY_LT
    call obj_richcompare_bool
    test eax, eax
    js .rws_fail
    mov [rbp - RWS_TMP], rax    ; 1 when the step is negative

    ; Both bounds, resolved and clamped.
    mov r8, [rbp - RWS_TMP]
    call .rws_bounds
    test eax, eax
    jz .rws_fail

    ; substart = start + slice_start * step, and the same for the stop.
    mov rdi, [rbp - RWS_START]
    call .rws_item
    test rax, rax
    jz .rws_fail
    mov rdi, [rbp - RWS_START]
    mov [rbp - RWS_START], rax
    DECREF_V rdi, rcx
    mov rdi, [rbp - RWS_STOP]
    call .rws_item
    test rax, rax
    jz .rws_fail
    mov rdi, [rbp - RWS_STOP]
    mov [rbp - RWS_STOP], rax
    DECREF_V rdi, rcx

    ; substep = r.step * slice_step
    mov rax, [rbp - RWS_SELF]
    mov rdi, [rax + PyRangeObject.vstep]
    mov rsi, [rbp - RWS_STEP]
    mov edx, NB_MULTIPLY
    call range_binop
    test rax, rax
    jz .rws_fail
    mov rdi, [rbp - RWS_STEP]
    mov [rbp - RWS_STEP], rax
    DECREF_V rdi, rcx

    mov rdi, [rbp - RWS_LEN]
    DECREF_V rdi, rcx
    mov rdi, [rbp - RWS_START]
    mov rsi, [rbp - RWS_STOP]
    mov rdx, [rbp - RWS_STEP]
    call range_new_v            ; adopts all three
    leave
    ret

;; Resolve both bounds against the length.  r8 = 1 for a negative step.
.rws_bounds:
    push r8
    push r8
    xor eax, eax
    V_PACK_I64 rax, rcx
    mov rdx, rax                ; lower = 0
    mov rcx, [rbp - RWS_LEN]    ; upper = len
    test r8, r8
    jz .rws_forward
    ; lower = -1, upper = len - 1
    mov rax, V_INT(-1)          ; the 32-bit form zero-extends
    mov rdx, rax
    mov rdi, [rbp - RWS_LEN]
    mov rax, V_INT(1)
    mov rsi, rax
    push rdx
    push rdx
    mov edx, NB_SUBTRACT
    call range_binop
    pop rdx
    pop rdx
    test rax, rax
    jz .rws_bounds_fail
    mov [rbp - RWS_TMP], rax    ; upper, owned
    mov rcx, rax
.rws_forward:
    mov rax, [rbp - RWS_SLICE]
    mov rdi, [rax + PySliceObject.start]
    mov rsi, [rbp - RWS_LEN]
    mov r8, [rsp]
    push rdx
    push rcx
    call range_clamp_bound
    pop rcx
    pop rdx
    test rax, rax
    jz .rws_bounds_fail
    mov [rbp - RWS_START], rax
    mov rax, [rbp - RWS_SLICE]
    mov rdi, [rax + PySliceObject.stop]
    mov rsi, [rbp - RWS_LEN]
    mov r8, [rsp]
    ; ...and the None default is the OTHER end for the stop.
    xor r8, 1
    push rdx
    push rcx
    call range_clamp_bound
    pop rcx
    pop rdx
    test rax, rax
    jz .rws_bounds_fail
    mov [rbp - RWS_STOP], rax
    mov eax, 1
    add rsp, 16
    ret
.rws_bounds_fail:
    xor eax, eax
    add rsp, 16
    ret

;; start + i * step, for a position i already resolved.
.rws_item:
    push rdi
    mov rax, [rbp - RWS_SELF]
    mov rsi, [rax + PyRangeObject.vstep]
    mov edx, NB_MULTIPLY
    call range_binop
    pop rdi
    test rax, rax
    jz .rws_item_fail
    push rax
    mov rdi, rax
    mov rax, [rbp - RWS_SELF]
    mov rsi, [rax + PyRangeObject.vstart]
    mov edx, NB_ADD
    call range_binop
    pop rdi
    push rax
    DECREF_V rdi, rcx
    pop rax
    ret
.rws_item_fail:
    xor eax, eax
    ret

.rws_zero_step:
    mov rdi, [rbp - RWS_LEN]
    XDECREF_V rdi, rcx
    mov rdi, [rbp - RWS_STEP]
    XDECREF_V rdi, rcx
    SET_EXC exc_ValueError_type, "slice step cannot be zero"
    leave
    ret

.rws_fail:
    mov rdi, [rbp - RWS_LEN]
    XDECREF_V rdi, rcx
    mov rdi, [rbp - RWS_STEP]
    XDECREF_V rdi, rcx
    mov rdi, [rbp - RWS_START]
    XDECREF_V rdi, rcx
    mov rdi, [rbp - RWS_STOP]
    XDECREF_V rdi, rcx
    xor eax, eax
    leave
    ret
END_FUNC range_wide_slice

;; ============================================================================
;; range_repr_wide(PyRangeObject *self) -> PyStrObject*
;;
;; The repr of a range whose bounds do not fit an int64.  Each bound's own
;; repr is asked for and the three are pasted together, because there is no
;; int64 to format: `range(1 << 1000)` printed its clamped stop.
;; ============================================================================
RRW_SELF  equ 8
RRW_A     equ 16
RRW_B     equ 24
RRW_C     equ 32
RRW_BUF   equ 40
RRW_POS   equ 48
RRW_FRAME equ 72            ; + 1 push = 80, 16-aligned
DEF_FUNC_LOCAL range_repr_wide, RRW_FRAME
    push rbx
    mov [rbp - RRW_SELF], rdi
    mov qword [rbp - RRW_A], 0
    mov qword [rbp - RRW_B], 0
    mov qword [rbp - RRW_C], 0
    mov qword [rbp - RRW_BUF], 0

    mov rdi, [rdi + PyRangeObject.vstart]
    extern obj_repr
    call obj_repr
    test rax, rax
    jz .rrw_fail
    mov [rbp - RRW_A], rax
    mov rdi, [rbp - RRW_SELF]
    mov rdi, [rdi + PyRangeObject.vstop]
    call obj_repr
    test rax, rax
    jz .rrw_fail
    mov [rbp - RRW_B], rax

    ; The step is printed only when it is not 1, as the narrow repr does.
    mov rdi, [rbp - RRW_SELF]
    mov rax, [rdi + PyRangeObject.vstep]
    mov rcx, V_INT(1)
    cmp rax, rcx
    je .rrw_sized
    mov rdi, rax
    call obj_repr
    test rax, rax
    jz .rrw_fail
    mov [rbp - RRW_C], rax

.rrw_sized:
    mov rax, [rbp - RRW_A]
    mov rbx, [rax + PyStrObject.ob_size]
    mov rax, [rbp - RRW_B]
    add rbx, [rax + PyStrObject.ob_size]
    cmp qword [rbp - RRW_C], 0
    je .rrw_alloc
    mov rax, [rbp - RRW_C]
    add rbx, [rax + PyStrObject.ob_size]
.rrw_alloc:
    lea rdi, [rbx + 16]         ; "range(" ", " ", " ")" and the NUL
    call ap_malloc
    test rax, rax
    jz .rrw_fail
    mov [rbp - RRW_BUF], rax
    mov qword [rbp - RRW_POS], 6
    mov dword [rax], 'rang'
    mov word [rax + 4], 'e('

    mov rdi, [rbp - RRW_A]
    call .rrw_append
    CSTRING rdi, ", "
    mov esi, 2
    call .rrw_append_raw
    mov rdi, [rbp - RRW_B]
    call .rrw_append
    cmp qword [rbp - RRW_C], 0
    je .rrw_close
    CSTRING rdi, ", "
    mov esi, 2
    call .rrw_append_raw
    mov rdi, [rbp - RRW_C]
    call .rrw_append
.rrw_close:
    CSTRING rdi, ")"
    mov esi, 1
    call .rrw_append_raw
    mov rax, [rbp - RRW_BUF]
    mov rcx, [rbp - RRW_POS]
    mov byte [rax + rcx], 0
    mov rdi, rax
    call str_from_cstr_heap
    mov [rbp - RRW_SELF], rax   ; the answer, across the releases
    call .rrw_release
    mov rax, [rbp - RRW_SELF]
    pop rbx
    leave
    ret

.rrw_fail:
    call .rrw_release
    xor eax, eax
    pop rbx
    leave
    ret

;; Append a str object's bytes.
.rrw_append:
    mov rsi, [rdi + PyStrObject.ob_size]
    lea rdi, [rdi + PyStrObject.data]
;; Append rsi bytes at rdi.
.rrw_append_raw:
    push rsi
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, [rbp - RRW_BUF]
    add rdi, [rbp - RRW_POS]
    extern ap_memcpy
    call ap_memcpy
    pop rsi
    add [rbp - RRW_POS], rsi
    ret

;; Give back the three reprs and the buffer, whichever are live.
.rrw_release:
    mov rdi, [rbp - RRW_A]
    test rdi, rdi
    jz .rrw_rel_b
    mov qword [rbp - RRW_A], 0
    call obj_decref
.rrw_rel_b:
    mov rdi, [rbp - RRW_B]
    test rdi, rdi
    jz .rrw_rel_c
    mov qword [rbp - RRW_B], 0
    call obj_decref
.rrw_rel_c:
    mov rdi, [rbp - RRW_C]
    test rdi, rdi
    jz .rrw_rel_buf
    mov qword [rbp - RRW_C], 0
    call obj_decref
.rrw_rel_buf:
    mov rdi, [rbp - RRW_BUF]
    test rdi, rdi
    jz .rrw_rel_done
    mov qword [rbp - RRW_BUF], 0
    call ap_free
.rrw_rel_done:
    ret
END_FUNC range_repr_wide

;; ============================================================================
;; range_obj_repr(PyRangeObject *self) -> PyStrObject*
;; Returns "range(start, stop)" or "range(start, stop, step)" if step != 1
;; ============================================================================
extern str_from_cstr_heap
ROR_BUF equ 8
ROR_POS equ 16
ROR_FRAME equ 16            ; + 4 pushes = 48
DEF_FUNC range_obj_repr, ROR_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi               ; self (range object)
    cmp qword [rbx + PyRangeObject.wide], 0
    jne .ror_wide
    mov r12, [rbx + PyRangeObject.start]
    mov r13, [rbx + PyRangeObject.stop]
    mov r14, [rbx + PyRangeObject.step]

    ; Allocate buffer (128 bytes is plenty for "range(i64, i64, i64)")
    mov edi, 128
    call ap_malloc
    mov [rbp - ROR_BUF], rax
    mov qword [rbp - ROR_POS], 0

    ; Write "range("
    mov rdi, rax
    mov byte [rdi], 'r'
    mov byte [rdi+1], 'a'
    mov byte [rdi+2], 'n'
    mov byte [rdi+3], 'g'
    mov byte [rdi+4], 'e'
    mov byte [rdi+5], '('
    mov qword [rbp - ROR_POS], 6

    ; Format start
    mov rdi, r12               ; start value (i64)
    call .ror_format_i64

    ; Write ", "
    mov rdi, [rbp - ROR_BUF]
    mov rcx, [rbp - ROR_POS]
    mov byte [rdi + rcx], ','
    mov byte [rdi + rcx + 1], ' '
    add qword [rbp - ROR_POS], 2

    ; Format stop
    mov rdi, r13               ; stop value (i64)
    call .ror_format_i64

    ; If step != 1, add ", step"
    cmp r14, 1
    je .ror_close
    mov rdi, [rbp - ROR_BUF]
    mov rcx, [rbp - ROR_POS]
    mov byte [rdi + rcx], ','
    mov byte [rdi + rcx + 1], ' '
    add qword [rbp - ROR_POS], 2
    mov rdi, r14               ; step value (i64)
    call .ror_format_i64

.ror_close:
    ; Write ")"
    mov rdi, [rbp - ROR_BUF]
    mov rcx, [rbp - ROR_POS]
    mov byte [rdi + rcx], ')'
    mov byte [rdi + rcx + 1], 0  ; NUL terminate
    inc qword [rbp - ROR_POS]

    ; Create string from buffer
    mov rdi, [rbp - ROR_BUF]
    call str_from_cstr_heap
    push rax                   ; save string
    push rax                   ; ...and keep the call below 16-aligned

    ; Free buffer
    mov rdi, [rbp - ROR_BUF]
    call ap_free

    pop rax
    pop rax                    ; return string
    ; A tp_repr answers with a tag beside the pointer, and this one never set
    ; it -- so the answer was whatever ap_free happened to leave in rdx.  While
    ; that was libc free it was reliably non-zero and the accident held; the
    ; pool allocator leaves the class's previous free-list head there, which is
    ; ZERO the first time a block of that size comes back.  A zero tag is
    ; TAG_NULL, and builtin_print reads TAG_NULL as "skip this argument", so
    ; `print(r, ...)` printed nothing at all for r.  repr.asm has said
    ; "ap_free clobbers rdx" at each of its own exits for as long as it has
    ; existed; this file did not.
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ror_wide:
    mov rdi, rbx
    call range_repr_wide
    ; range_repr_wide answers 0 when obj_repr of a bound raised, and a caller
    ; that classifies the result by its TAG -- builtins_obj's ascii() does --
    ; would then read PyStrObject.data off NULL.  The tag stays TAG_NULL for
    ; that answer, which is what "there is no string here" means.
    xor edx, edx
    test rax, rax
    jz .ror_out
    mov edx, TAG_PTR
.ror_out:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

; Helper: format i64 in rdi to buffer, appending at current position
.ror_format_i64:
    push rbx
    push r12
    mov rbx, rdi               ; value
    mov r12, [rbp - ROR_BUF]
    mov rcx, [rbp - ROR_POS]

    ; Handle negative
    test rbx, rbx
    jns .ror_fi_pos
    mov byte [r12 + rcx], '-'
    inc rcx
    mov [rbp - ROR_POS], rcx
    neg rbx

.ror_fi_pos:
    ; Convert to decimal digits (reversed)
    sub rsp, 24                ; temp digit buffer on stack
    mov rdi, rsp
    xor r8d, r8d               ; digit count
    mov rax, rbx
.ror_fi_loop:
    xor edx, edx
    mov ecx, 10
    div rcx                    ; rax = quotient, rdx = remainder
    add dl, '0'
    mov [rdi + r8], dl
    inc r8
    test rax, rax
    jnz .ror_fi_loop

    ; Copy reversed digits to buffer
    mov rcx, [rbp - ROR_POS]
    mov rdi, [rbp - ROR_BUF]
.ror_fi_copy:
    dec r8
    movzx eax, byte [rsp + r8]
    mov [rdi + rcx], al
    inc rcx
    test r8, r8
    jnz .ror_fi_copy

    add rsp, 24
    mov [rbp - ROR_POS], rcx
    pop r12
    pop rbx
    ret

END_FUNC range_obj_repr

;; ============================================================================
;; init_iter_types
;; Patches list_type.tp_iter and tuple_type.tp_iter at startup
;; Called from main.asm or builtins_init
;; ============================================================================
DEF_FUNC_BARE init_iter_types
    ; Set list_type.tp_iter = list_tp_iter
    lea rax, [rel list_tp_iter]
    lea rcx, [rel list_type]
    mov [rcx + PyTypeObject.tp_iter], rax

    ; Set tuple_type.tp_iter = tuple_tp_iter
    lea rax, [rel tuple_tp_iter]
    lea rcx, [rel tuple_type]
    mov [rcx + PyTypeObject.tp_iter], rax

    ret
END_FUNC init_iter_types

;; ============================================================================
;; Data section
;; ============================================================================
section .data

list_iter_name: db "list_iterator", 0
tuple_iter_name: db "tuple_iterator", 0
range_iter_name: db "range_iterator", 0
longrange_iter_name: db "longrange_iterator", 0
range_obj_name: db "range", 0

; List iterator type
align 8
global list_iter_type
list_iter_type:
    dq 1                    ; ob_refcnt
    dq type_type            ; ob_type
    dq list_iter_name       ; tp_name
    dq PyListIterObject_size ; tp_basicsize
    dq list_iter_dealloc    ; tp_dealloc
    dq 0                    ; tp_repr
    dq 0                    ; tp_str
    dq 0                    ; tp_hash
    dq 0                    ; tp_call
    dq 0                    ; tp_getattr
    dq 0                    ; tp_setattr
    dq 0                    ; tp_richcompare
    dq iter_self            ; tp_iter (return self)
    dq list_iter_next       ; tp_iternext
    dq 0                    ; tp_init
    dq 0                    ; tp_new
    dq 0                    ; tp_as_number
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq TYPE_FLAG_HAVE_GC                    ; tp_flags
    dq 0                    ; tp_bases
    dq iter_traverse_one                        ; tp_traverse
    dq iter_clear_one                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; Tuple iterator type
align 8
global tuple_iter_type
tuple_iter_type:
    dq 1
    dq type_type
    dq tuple_iter_name
    dq PyTupleIterObject_size
    dq tuple_iter_dealloc
    dq 0                    ; tp_repr
    dq 0                    ; tp_str
    dq 0                    ; tp_hash
    dq 0                    ; tp_call
    dq 0                    ; tp_getattr
    dq 0                    ; tp_setattr
    dq 0                    ; tp_richcompare
    dq iter_self            ; tp_iter
    dq tuple_iter_next      ; tp_iternext
    dq 0                    ; tp_init
    dq 0                    ; tp_new
    dq 0                    ; tp_as_number
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq TYPE_FLAG_HAVE_GC                    ; tp_flags
    dq 0                    ; tp_bases
    dq iter_traverse_one                        ; tp_traverse
    dq iter_clear_one                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; Range iterator type
align 8
global longrange_iter_type
longrange_iter_type:
    dq 1
    dq type_type
    dq longrange_iter_name
    dq PyLongRangeIterObject_size
    dq range_longiter_dealloc
    dq 0                    ; tp_repr
    dq 0                    ; tp_str
    dq 0                    ; tp_hash
    dq 0                    ; tp_call
    dq 0                    ; tp_getattr
    dq 0                    ; tp_setattr
    dq 0                    ; tp_richcompare
    dq range_iter_self      ; tp_iter (return self)
    dq range_longiter_next  ; tp_iternext
    dq 0                    ; tp_init
    dq 0                    ; tp_new
    dq 0                    ; tp_as_number
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq 0                    ; tp_flags
    dq 0                    ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

align 8
global range_iter_type
range_iter_type:
    dq 1
    dq type_type
    dq range_iter_name
    dq PyRangeIterObject_size
    dq range_iter_dealloc
    dq 0                    ; tp_repr
    dq 0                    ; tp_str
    dq 0                    ; tp_hash
    dq 0                    ; tp_call
    dq 0                    ; tp_getattr
    dq 0                    ; tp_setattr
    dq 0                    ; tp_richcompare
    dq range_iter_self      ; tp_iter (return self)
    dq range_iter_next      ; tp_iternext
    dq 0                    ; tp_init
    dq 0                    ; tp_new
    dq 0                    ; tp_as_number
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq 0                    ; tp_flags
    dq 0                    ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; Range object type (reusable sequence, creates fresh iterators)
align 8
global range_obj_type
; A range answers bool() from its LENGTH, and a wide one has no int64
; length: without this, `if range(1 << 70):` went through sq_length and
; raised the OverflowError that len() is supposed to raise.
align 8
range_obj_num_methods:
    dq 0                    ; nb_add
    dq 0                    ; nb_subtract
    dq 0                    ; nb_multiply
    dq 0                    ; nb_remainder
    dq 0                    ; nb_divmod
    dq 0                    ; nb_power
    dq 0                    ; nb_negative
    dq 0                    ; nb_positive
    dq 0                    ; nb_absolute
    dq range_obj_bool       ; nb_bool
    times PyNumberMethods_size / 8 - 10 dq 0

align 8
range_obj_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq range_obj_name           ; tp_name
    dq PyRangeObject_size       ; tp_basicsize
    dq range_obj_dealloc        ; tp_dealloc
    dq range_obj_repr           ; tp_repr
    dq range_obj_repr           ; tp_str
    dq range_obj_hash           ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq range_obj_richcompare    ; tp_richcompare
    dq range_obj_tp_iter        ; tp_iter (creates new iterator)
    dq 0                        ; tp_iternext (NOT an iterator)
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq range_obj_num_methods    ; tp_as_number
    dq range_obj_seq_methods    ; tp_as_sequence
    dq range_obj_map_methods    ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_FINAL          ; tp_flags -- CPython gives this type no
                                ; Py_TPFLAGS_BASETYPE
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; Range object sequence methods
align 8
range_obj_map_methods:
    dq range_obj_sq_length      ; mp_length
    dq range_obj_mp_subscript   ; mp_subscript
    dq 0                        ; mp_ass_subscript

align 8
range_obj_seq_methods:
    dq range_obj_sq_length      ; sq_length
    dq 0                        ; sq_concat
    dq 0                        ; sq_repeat
    dq range_obj_sq_item        ; sq_item
    dq 0                        ; sq_ass_item
    dq range_obj_sq_contains    ; sq_contains
    dq 0                        ; sq_inplace_concat
    dq 0                        ; sq_inplace_repeat
