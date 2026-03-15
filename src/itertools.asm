; itertools.asm - Iterator builtins: enumerate, zip, map, filter, reversed, sorted
;
; Each iterator type has: type object, _new(), _iternext(), _dealloc(), iter_self
; Builtin signatures: func(PyObject **args, int64_t nargs) -> PyObject*

%include "macros.inc"
%include "object.inc"
%include "types.inc"


extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern ap_free
extern obj_incref
extern obj_decref
extern obj_dealloc
extern obj_is_true
extern fatal_error
extern raise_exception
extern exc_TypeError_type
extern exc_StopIteration_type
extern kw_names_pending
extern none_singleton
extern current_exception
extern tuple_new
extern list_new
extern list_append
extern int_from_i64
extern int_to_i64
extern list_method_sort
extern type_type

;; ============================================================================
;; Struct definitions (inline)
;; ============================================================================
;; EnumerateIterObject: +0 refcnt, +8 type, +16 it_iter, +24 it_count  (32B)
;; ZipIterObject:       +0 refcnt, +8 type, +16 it_iters, +24 it_count, +32 it_strict (40B)
;; MapIterObject:       +0 refcnt, +8 type, +16 it_func, +24 it_iters, +32 it_count  (40B)
;; FilterIterObject:    +0 refcnt, +8 type, +16 it_func, +24 it_iter   (32B)
;; ReversedIterObject:  +0 refcnt, +8 type, +16 it_seq, +24 it_index   (32B)

; Offsets (all iterator objects)
%define IT_FIELD1  16     ; first custom field
%define IT_FIELD2  24     ; second custom field
%define ITER_OBJ_SIZE 32

; Extended sizes for zip (with strict flag) and map (with array+count)
%define ZIP_OBJ_SIZE    40
%define ZIP_STRICT      32     ; strict flag (0 or 1)
%define MAP_FUNC        16     ; function pointer
%define MAP_ITERS       24     ; iterator array pointer
%define MAP_COUNT       32     ; number of iterators
%define MAP_OBJ_SIZE    40

;; ============================================================================
;; Common: iter_self(self) -> self with INCREF
;; tp_iter for all our iterator types: return self
;; ============================================================================
itertools_iter_self:
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret

;; ============================================================================
;; Helper: call_iternext(rdi=iterator) -> (rax=payload, edx=tag) or NULL
;; Tries tp_iternext first, falls back to __next__ for heaptypes.
;; Clears StopIteration from current_exception (normal exhaustion).
;; Leaves other exceptions (ZeroDivisionError etc.) for callers to propagate.
;; ============================================================================
extern dunder_next
DEF_FUNC call_iternext
    push rbx
    mov rax, [rdi + PyObject.ob_type]
    mov rcx, rax
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jnz .ci_have

    ; tp_iternext NULL — try __next__ on heaptype
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .ci_null
    lea rsi, [rel dunder_next]
    call dunder_call_1
    test edx, edx
    jnz .ci_ret               ; got a value, return it

    ; NULL from __next__ — check for StopIteration
    mov rax, [rel current_exception]
    test rax, rax
    jz .ci_null               ; no exception, clean exhaustion

    ; Check if exception is StopIteration
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel exc_StopIteration_type]
    cmp rcx, rdx
    jne .ci_null              ; other exception: leave it, return NULL

    ; Clear StopIteration: DECREF and reset current_exception
    mov rdi, rax
    call obj_decref
    mov qword [rel current_exception], 0
    jmp .ci_null

.ci_have:
    call rax
.ci_ret:
    pop rbx
    leave
    ret

.ci_null:
    RET_NULL
    pop rbx
    leave
    ret
END_FUNC call_iternext

;; ============================================================================
;; Helper: get_iterator(obj) -> iterator
;; Calls tp_iter on obj, returns iterator. Raises TypeError if no tp_iter.
;; Falls back to __getitem__ sequence protocol for heaptypes.
;; Validates returned iterator has tp_iternext or __next__.
;; Clobbers caller-saved regs.
;; ============================================================================
DEF_FUNC get_iterator
    push rbx
    ; rdi = obj payload, esi = obj tag

    ; Non-pointer tags cannot be iterated (SmallInt, Float, None, Bool)
    test esi, TAG_RC_BIT
    jz .no_iter

    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .no_iter
    mov rcx, rax                   ; save type
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jnz .have_iter

    ; tp_iter NULL — try __iter__ on heaptype (same as op_get_iter)
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .no_iter
    mov rbx, rdi                   ; save obj for __getitem__ fallback
    extern dunder_iter
    lea rsi, [rel dunder_iter]
    extern dunder_call_1
    call dunder_call_1
    test edx, edx
    jnz .validate_iter

    ; __iter__ returned NULL — check if exception pending (vs not found)
    extern current_exception
    mov rax, [rel current_exception]
    test rax, rax
    jnz .iter_exc_pending         ; exception raised by __iter__, propagate

    ; __iter__ not found — try __getitem__ sequence protocol
    mov rdi, rbx
    jmp .try_getitem

.have_iter:
    call rax
    ; rax = iterator — validate it has iternext
    jmp .validate_iter

.validate_iter:
    ; rax = iterator object. Validate it has tp_iternext or __next__.
    mov rbx, rax                   ; save iterator
    mov rcx, [rax + PyObject.ob_type]
    mov rdx, [rcx + PyTypeObject.tp_iternext]
    test rdx, rdx
    jnz .iter_ok                   ; has tp_iternext, good

    ; No tp_iternext — check for __next__ on heaptype
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .iter_bad                   ; not a heaptype and no tp_iternext

    ; Check if __next__ exists via dunder_lookup
    mov rdi, rcx                   ; type
    extern dunder_next
    lea rsi, [rel dunder_next]
    extern dunder_lookup
    call dunder_lookup
    test edx, edx
    jz .iter_bad                   ; no __next__ found
    ; Has __next__, good

.iter_ok:
    mov rax, rbx                   ; restore iterator
    pop rbx
    leave
    ret

.iter_bad:
    ; DECREF the bad iterator, raise TypeError
    mov rdi, rbx
    call obj_decref
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "iter() returned non-iterator"
    call raise_exception

.try_getitem:
    ; rdi = original object. Check if it has __getitem__ on heaptype.
    mov rcx, [rdi + PyObject.ob_type]
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .no_iter
    mov rbx, rdi                   ; save obj
    mov rdi, rcx                   ; type
    extern dunder_getitem
    lea rsi, [rel dunder_getitem]
    call dunder_lookup
    test edx, edx
    jz .no_iter                    ; no __getitem__
    ; Has __getitem__ — create seq_iter
    mov rdi, rbx                   ; obj
    call seq_iter_new
    pop rbx
    leave
    ret

.no_iter:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "object is not iterable"
    call raise_exception

.iter_exc_pending:
    ; Exception was raised by __iter__. Propagate it via eval_exception_unwind.
    extern eval_exception_unwind
    extern eval_saved_r13
    extern eval_saved_r15
    mov [rel eval_saved_r13], r13
    mov [rel eval_saved_r15], r15
    pop rbx
    leave
    jmp eval_exception_unwind
END_FUNC get_iterator

;; ============================================================================
;; ENUMERATE
;; ============================================================================

;; builtin_enumerate(args, nargs) -> EnumerateIterObject*
;; nargs=1: enumerate(iterable), start=0
;; nargs=2: enumerate(iterable, start)
;; Supports start= keyword arg
EN_ARGS    equ 8
EN_NPOS    equ 16
EN_START   equ 24
EN_ITER    equ 32     ; local: iterable pointer
EN_ITERTAG equ 40     ; local: iterable tag
EN_FRAME   equ 48
DEF_FUNC builtin_enumerate, EN_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - EN_ARGS], rdi    ; save args
    mov r12, rsi                ; nargs (total including kwargs)
    xor r13d, r13d              ; default start = 0
    mov [rbp - EN_START], r13
    mov qword [rbp - EN_ITER], 0       ; init iterable ptr to 0 (used to detect kwarg case)

    ; Check for kwargs
    mov rax, [rel kw_names_pending]
    test rax, rax
    jnz .enum_parse_kw

    ; No kwargs — positional only path
    mov [rbp - EN_NPOS], r12
    cmp r12, 1
    jl .enum_error
    cmp r12, 2
    jg .enum_error

    ; Save iterable to local (args[0])
    mov rbx, [rbp - EN_ARGS]
    mov rax, [rbx]
    mov [rbp - EN_ITER], rax
    mov rax, [rbx + 8]
    mov [rbp - EN_ITERTAG], rax

    cmp r12, 2
    jne .enum_get_iter

    ; start = int(args[1])  (positional)
    mov rdi, [rbx + 16]
    mov edx, [rbx + 24]
    cmp edx, TAG_SMALLINT
    jne .enum_type_error
    call int_to_i64
    mov [rbp - EN_START], rax
    jmp .enum_get_iter

.enum_parse_kw:
    ; rax = kw_names tuple
    mov rcx, [rax + PyTupleObject.ob_size]   ; n_kw
    mov r8, r12
    sub r8, rcx                              ; n_pos (original, for offset calculations)
    mov [rbp - EN_NPOS], r8                  ; will be updated if iterable= found

    ; Validate: n_pos must be 0 or 1
    cmp r8, 2
    jge .enum_error

    ; Iterate kwarg names
    ; r8 = original n_pos (DO NOT MODIFY during loop - used for offset calc)
    ; [rbp - EN_NPOS] = effective n_pos (updated when iterable= found)
    xor r9d, r9d
.enum_kw_loop:
    cmp r9, rcx
    jge .enum_kw_done

    ; Get kwarg name string ptr from tuple
    mov r10, [rax + PyTupleObject.ob_item]        ; kw names payloads
    mov r10, [r10 + r9*8]

    ; Compute value offset in args: (original_n_pos + kw_idx) * 16
    ; Use r8 (original n_pos), NOT [rbp - EN_NPOS] which may have been updated
    mov r11, r8
    add r11, r9
    shl r11, 4

    ; Compare with "start"
    push rax
    push rcx
    push r8
    push r9
    push r11
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "start"
    call ap_strcmp
    mov r10d, eax
    pop r11
    pop r9
    pop r8
    pop rcx
    pop rax
    test r10d, r10d
    jnz .enum_kw_try_iterable

    ; Found "start" — extract value
    push rax
    push rcx
    push r8
    push r9
    mov rbx, [rbp - EN_ARGS]
    mov rdi, [rbx + r11]           ; value payload
    mov edx, [rbx + r11 + 8]      ; value tag
    cmp edx, TAG_SMALLINT
    jne .enum_type_error
    call int_to_i64
    mov [rbp - EN_START], rax
    pop r9
    pop r8
    pop rcx
    pop rax
    jmp .enum_kw_next

.enum_kw_try_iterable:
    ; Compare with "iterable"
    ; NOTE: r10 was clobbered by strcmp result above, must reload from tuple
    push rax
    push rcx
    push r8
    push r9
    push r11
    ; Reload r10 = kwarg name string ptr from tuple
    mov r10, [rax + PyTupleObject.ob_item]        ; kw names payloads
    mov r10, [r10 + r9*8]
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "iterable"
    call ap_strcmp
    mov r10d, eax
    pop r11
    pop r9
    pop r8
    pop rcx
    pop rax
    test r10d, r10d
    jnz .enum_kw_unknown

    ; Found \"iterable\" — original n_pos must be 0 (no positional iterable)
    cmp r8, 1
    jge .enum_error

    ; Save iterable value to locals (do NOT overwrite args - that corrupts value stack!)
    mov rbx, [rbp - EN_ARGS]
    push rdi
    push rsi
    mov rdi, [rbx + r11]
    mov rsi, [rbx + r11 + 8]
    mov [rbp - EN_ITER], rdi
    mov [rbp - EN_ITERTAG], rsi
    pop rsi
    pop rdi
    ; Mark that we now have 1 effective positional (but don't change r8!)
    mov qword [rbp - EN_NPOS], 1
    jmp .enum_kw_next

.enum_kw_unknown:
    ; Unknown kwarg — raise TypeError
    jmp .enum_error

.enum_kw_next:
    inc r9
    jmp .enum_kw_loop

.enum_kw_done:
    mov qword [rel kw_names_pending], 0

    ; Validate: must have exactly 1 effective positional (the iterable)
    mov rax, [rbp - EN_NPOS]
    cmp rax, 1
    jne .enum_error

    ; If iterable= kwarg was found, EN_ITER is already set.
    ; Otherwise (positional iterable), copy from args[0].
    ; Check if EN_ITER is still 0 (unset).
    cmp qword [rbp - EN_ITER], 0
    jne .enum_get_iter
    ; No iterable= kwarg — iterable is positional args[0]
    mov rbx, [rbp - EN_ARGS]
    mov rax, [rbx]
    mov [rbp - EN_ITER], rax
    mov rax, [rbx + 8]
    mov [rbp - EN_ITERTAG], rax

.enum_get_iter:
    ; Get iterator from saved iterable (locals, not args - args on value stack)
    mov rdi, [rbp - EN_ITER]
    mov rsi, [rbp - EN_ITERTAG]
    call get_iterator
    mov rbx, rax                  ; rbx = underlying iterator

    ; Allocate EnumerateIterObject
    mov edi, ITER_OBJ_SIZE
    call ap_malloc

    ; Fill fields
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel enumerate_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + IT_FIELD1], rbx       ; it_iter
    mov r13, [rbp - EN_START]
    mov [rax + IT_FIELD2], r13       ; it_count (raw i64, not SmallInt)
    mov edx, TAG_PTR

    pop r13
    pop r12
    pop rbx
    leave
    ret

.enum_type_error:
    mov qword [rel kw_names_pending], 0
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "'%s' object cannot be interpreted as an integer"
    call raise_exception

.enum_error:
    mov qword [rel kw_names_pending], 0
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "enumerate() requires 1 or 2 arguments"
    call raise_exception
END_FUNC builtin_enumerate

;; enumerate_iternext(self) -> PyObject* (2-tuple) or NULL
DEF_FUNC_LOCAL enumerate_iternext
    push rbx
    push r12
    push r13

    mov rbx, rdi            ; self

    ; Call underlying iterator's iternext
    mov rdi, [rbx + IT_FIELD1]       ; it_iter
    call call_iternext
    test edx, edx
    jz .enum_exhausted
    mov r12, rax             ; r12 = value payload from iternext
    push rdx                 ; save value tag from iternext

    ; Inline SmallInt for current count (int_from_i64 always returns SmallInt)
    mov r13, [rbx + IT_FIELD2]       ; r13 = count (raw i64 = SmallInt payload)
    inc qword [rbx + IT_FIELD2]      ; increment for next time
    push qword TAG_SMALLINT          ; count tag (always SmallInt)

    ; Create 2-tuple
    mov rdi, 2
    call tuple_new
    ; rax = new tuple
    ; Fill: tuple[0] = count, tuple[1] = value
    mov r8, [rax + PyTupleObject.ob_item]       ; payloads
    mov r9, [rax + PyTupleObject.ob_item_tags]  ; tags
    pop rcx                  ; count tag
    mov [r8], r13            ; count payload (slot 0)
    mov byte [r9], cl        ; count tag
    pop rcx                  ; value tag
    mov [r8 + 8], r12        ; value payload (slot 1)
    mov byte [r9 + 1], cl    ; value tag

    pop r13
    pop r12
    pop rbx
    mov edx, TAG_PTR               ; fat return tag
    leave
    ret

.enum_exhausted:
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC enumerate_iternext

;; enumerate_dealloc(self)
DEF_FUNC_LOCAL enumerate_dealloc
    push rbx
    mov rbx, rdi

    ; DECREF the underlying iterator
    mov rdi, [rbx + IT_FIELD1]
    call obj_decref

    ; Free self
    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC enumerate_dealloc

;; ============================================================================
;; ZIP
;; ============================================================================

;; builtin_zip(args, nargs) -> ZipIterObject*
;; Supports strict= kwarg (PEP 618)
extern ap_strcmp
extern exc_ValueError_type
extern bool_true
ZP_ARGS    equ 8
ZP_NARGS   equ 16
ZP_NPOS    equ 24
ZP_STRICT  equ 32
ZP_FRAME   equ 32
DEF_FUNC builtin_zip, ZP_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov [rbp - ZP_ARGS], rdi     ; save args
    mov [rbp - ZP_NARGS], rsi    ; save nargs
    mov qword [rbp - ZP_STRICT], 0

    ; Check for strict= kwarg
    mov rax, [rel kw_names_pending]
    test rax, rax
    jz .zip_no_kw

    ; Parse kwargs
    mov rcx, [rax + PyTupleObject.ob_size]   ; n_kw
    mov r12, rsi
    sub r12, rcx                              ; n_pos
    mov [rbp - ZP_NPOS], r12

    ; Iterate kwarg names
    xor r9d, r9d
.zip_kw_loop:
    cmp r9, rcx
    jge .zip_kw_done

    ; Get kwarg name string ptr from tuple
    mov r10, [rax + PyTupleObject.ob_item]        ; kw names payloads
    mov r10, [r10 + r9*8]

    ; Compute value offset: (n_pos + kw_idx) * 16
    mov r11, r12
    add r11, r9
    shl r11, 4

    ; Compare with "strict"
    push rax
    push rcx
    push r9
    push r11
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "strict"
    call ap_strcmp
    mov r10d, eax
    pop r11
    pop r9
    pop rcx
    pop rax
    test r10d, r10d
    jnz .zip_kw_next

    ; Extract strict value: compare against bool_true
    mov rdi, [rbp - ZP_ARGS]
    mov r10, [rdi + r11]            ; payload
    lea r8, [rel bool_true]
    cmp r10, r8
    sete r10b
    movzx r10d, r10b
    mov [rbp - ZP_STRICT], r10

.zip_kw_next:
    inc r9
    jmp .zip_kw_loop

.zip_kw_done:
    mov qword [rel kw_names_pending], 0
    jmp .zip_have_npos

.zip_no_kw:
    mov r12, [rbp - ZP_NARGS]
    mov [rbp - ZP_NPOS], r12

.zip_have_npos:
    mov r12, [rbp - ZP_NPOS]       ; r12 = n_pos (number of iterables)
    mov rbx, [rbp - ZP_ARGS]       ; rbx = args

    ; Handle zero positional args: zip() returns empty iterator
    test r12, r12
    jz .zip_zero

    ; Allocate array of iterator pointers: n_pos * 8
    lea rdi, [r12 * 8]
    call ap_malloc
    mov r13, rax             ; r13 = iterator array

    ; For each positional arg, get its iterator
    xor r14d, r14d          ; i = 0
.zip_iter_loop:
    cmp r14, r12
    jge .zip_create

    mov rax, r14
    shl rax, 4                  ; rax = i * 16
    mov rdi, [rbx + rax]
    mov rsi, [rbx + rax + 8]   ; arg tag
    push r13
    push r14
    call get_iterator
    pop r14
    pop r13
    mov [r13 + r14 * 8], rax    ; store iterator

    inc r14
    jmp .zip_iter_loop

.zip_create:
    ; Allocate ZipIterObject (40 bytes for strict flag)
    mov edi, ZIP_OBJ_SIZE
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel zip_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + IT_FIELD1], r13       ; it_iters (array ptr)
    mov [rax + IT_FIELD2], r12       ; it_count
    mov rcx, [rbp - ZP_STRICT]
    mov [rax + ZIP_STRICT], rcx      ; strict flag
    mov edx, TAG_PTR

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.zip_zero:
    ; Create a zip with 0 iterators (will immediately exhaust)
    mov edi, ZIP_OBJ_SIZE
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel zip_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + IT_FIELD1], 0   ; NULL iters array
    mov qword [rax + IT_FIELD2], 0   ; 0 iterators
    mov qword [rax + ZIP_STRICT], 0  ; not strict
    mov edx, TAG_PTR

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC builtin_zip

;; zip_iternext(self) -> PyObject* (tuple) or NULL
DEF_FUNC_LOCAL zip_iternext
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi            ; self
    mov r12, [rbx + IT_FIELD2]   ; it_count
    mov r13, [rbx + IT_FIELD1]   ; it_iters array

    ; Zero iterators = exhausted
    test r12, r12
    jz .zip_exhausted

    ; Create result tuple of size it_count
    mov rdi, r12
    call tuple_new
    mov r14, rax             ; r14 = result tuple

    ; For each iterator, call iternext
    xor r15d, r15d          ; i = 0
.zip_next_loop:
    cmp r15, r12
    jge .zip_done

    mov rdi, [r13 + r15 * 8]    ; iterator[i]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    test edx, edx
    jz .zip_partial_cleanup

    ; Store value in tuple (rdx = tag from iternext)
    mov r8, [r14 + PyTupleObject.ob_item]        ; payloads
    mov r9, [r14 + PyTupleObject.ob_item_tags]   ; tags
    mov [r8 + r15*8], rax                        ; payload
    mov byte [r9 + r15], dl                      ; tag

    inc r15
    jmp .zip_next_loop

.zip_done:
    mov rax, r14
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov edx, TAG_PTR
    leave
    ret

.zip_partial_cleanup:
    ; One iterator exhausted at index r15.
    ; DECREF items already stored in tuple, then free tuple.
    xor ecx, ecx
.zip_cleanup_loop:
    cmp rcx, r15
    jge .zip_free_tuple
    push rcx
    mov r8, [r14 + PyTupleObject.ob_item]        ; payloads
    mov r9, [r14 + PyTupleObject.ob_item_tags]   ; tags
    mov rdi, [r8 + rcx*8]
    movzx esi, byte [r9 + rcx]
    DECREF_VAL rdi, rsi
    pop rcx
    inc rcx
    jmp .zip_cleanup_loop

.zip_free_tuple:
    ; Zero out remaining items to avoid double-free in tuple_dealloc
    mov rcx, r15
.zip_zero_loop:
    cmp rcx, r12
    jge .zip_do_free
    mov r8, [r14 + PyTupleObject.ob_item]        ; payloads
    mov r9, [r14 + PyTupleObject.ob_item_tags]   ; tags
    mov qword [r8 + rcx*8], 0
    mov byte [r9 + rcx], 0
    inc rcx
    jmp .zip_zero_loop
.zip_do_free:
    mov rdi, r14
    call obj_decref

    ; Check strict flag — if set, verify all iterators exhausted
    cmp qword [rbx + ZIP_STRICT], 0
    jz .zip_exhausted

    ; r15 = index of iterator that returned NULL
    ; If r15 > 0: iterators 0..r15-1 already returned items this round,
    ;   so they are longer than iterator r15 → always error
    test r15, r15
    jnz .zip_strict_mismatch

    ; r15 == 0: first iterator exhausted. Check others for remaining items.
    mov r14, 1
.zip_strict_check:
    cmp r14, r12
    jge .zip_exhausted       ; all exhausted — OK

    mov rdi, [r13 + r14 * 8]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    test edx, edx
    jnz .zip_strict_decref_err  ; non-NULL = this one is longer

    inc r14
    jmp .zip_strict_check

.zip_strict_decref_err:
    ; DECREF the extra value we got from the longer iterator
    mov rdi, rax
    mov rsi, rdx
    DECREF_VAL rdi, rsi
.zip_strict_mismatch:
    ; Set exception without longjmp — return NULL so callers can clean up
    extern exc_from_cstr
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "zip() has arguments with different lengths"
    call exc_from_cstr
    ; rax = exception object
    push rax
    mov rdi, [rel current_exception]
    test rdi, rdi
    jz .zip_strict_no_prev
    call obj_decref
.zip_strict_no_prev:
    pop rax
    mov [rel current_exception], rax
    ; Fall through to .zip_exhausted which returns NULL

.zip_exhausted:
    RET_NULL
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC zip_iternext

;; zip_dealloc(self)
DEF_FUNC_LOCAL zip_dealloc
    push rbx
    push r12
    push r13
    mov rbx, rdi

    mov r12, [rbx + IT_FIELD2]   ; count
    mov r13, [rbx + IT_FIELD1]   ; iters array

    ; DECREF each iterator
    test r13, r13
    jz .zip_dealloc_free

    xor ecx, ecx
.zip_dealloc_loop:
    cmp rcx, r12
    jge .zip_free_array
    push rcx
    mov rdi, [r13 + rcx * 8]
    call obj_decref
    pop rcx
    inc rcx
    jmp .zip_dealloc_loop

.zip_free_array:
    mov rdi, r13
    call ap_free

.zip_dealloc_free:
    mov rdi, rbx
    call ap_free

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC zip_dealloc

;; ============================================================================
;; MAP
;; ============================================================================

;; builtin_map(args, nargs) -> MapIterObject*
;; nargs>=2: map(func, iterable1, ..., iterableN)
DEF_FUNC builtin_map
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi            ; args
    mov r12, rsi            ; nargs

    cmp r12, 2
    jl .map_error

    ; INCREF func (only if refcounted)
    mov r13, [rbx]          ; r13 = func payload
    mov eax, [rbx + 8]      ; func tag (low 32 bits)
    test eax, TAG_RC_BIT
    jz .map_have_func
    INCREF r13
.map_have_func:

    ; Number of iterables = nargs - 1
    lea r14, [r12 - 1]      ; r14 = iter_count

    ; Allocate array of iterator pointers: iter_count * 8
    lea rdi, [r14 * 8]
    call ap_malloc
    push rax                 ; save iters array ptr

    ; For each iterable arg[1..nargs-1], get its iterator
    xor ecx, ecx            ; i = 0
.map_iter_loop:
    cmp rcx, r14
    jge .map_create

    lea rax, [rcx + 1]
    shl rax, 4                  ; (i+1) * 16
    mov rdi, [rbx + rax]        ; args[i+1] payload
    mov rsi, [rbx + rax + 8]    ; args[i+1] tag
    push rcx
    call get_iterator
    pop rcx
    mov rdx, [rsp]              ; iters array ptr
    mov [rdx + rcx * 8], rax    ; store iterator
    inc rcx
    jmp .map_iter_loop

.map_create:
    pop rbx                  ; rbx = iters array ptr

    ; Allocate MapIterObject (40 bytes)
    mov edi, MAP_OBJ_SIZE
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel map_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + MAP_FUNC], r13        ; it_func
    mov [rax + MAP_ITERS], rbx       ; it_iters (array ptr)
    mov [rax + MAP_COUNT], r14       ; it_count
    mov edx, TAG_PTR

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.map_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "map() requires at least 2 arguments"
    call raise_exception
END_FUNC builtin_map

;; map_iternext(self) -> PyObject* or NULL
;; Supports multiple iterables: calls func(next(it1), next(it2), ...)
;; IMPORTANT: Do not clobber r12 before calling tp_call, because func_call
;; reads r12 expecting the eval loop's current frame pointer.
MI_SELF    equ 8
MI_ARGS    equ 16     ; pointer to fat args array on stack
MI_FRAME   equ 16
DEF_FUNC_LOCAL map_iternext, MI_FRAME
    push rbx
    push r13
    push r14
    push r15

    mov rbx, rdi                     ; self
    mov r14, [rbx + MAP_COUNT]       ; iter count
    mov r15, [rbx + MAP_ITERS]       ; iters array

    ; Allocate fat args on stack: count * 16 bytes
    mov rax, r14
    shl rax, 4                       ; count * 16
    sub rsp, rax
    mov [rbp - MI_ARGS], rsp         ; save args base

    ; For each iterator, get next value
    xor r13d, r13d                   ; i = 0
.map_next_loop:
    cmp r13, r14
    jge .map_call_func

    mov rdi, [r15 + r13 * 8]        ; iterator[i]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    test edx, edx
    jz .map_partial_cleanup

    ; Store value in fat args array
    mov rcx, r13
    shl rcx, 4
    mov r8, [rbp - MI_ARGS]
    mov [r8 + rcx], rax              ; payload
    mov [r8 + rcx + 8], rdx          ; tag

    inc r13
    jmp .map_next_loop

.map_call_func:
    ; Call func(item1, item2, ...): tp_call(func, args, count)
    mov rdi, [rbx + MAP_FUNC]       ; func
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    mov rsi, [rbp - MI_ARGS]         ; args pointer
    mov rdx, r14                     ; nargs = count
    call rax
    push rax                         ; save result payload
    push rdx                         ; save result tag

    ; DECREF_VAL each arg
    xor r13d, r13d
.map_decref_loop:
    cmp r13, r14
    jge .map_decref_done
    mov rcx, r13
    shl rcx, 4
    mov r8, [rbp - MI_ARGS]
    mov rdi, [r8 + rcx]
    mov rsi, [r8 + rcx + 8]
    push r13
    DECREF_VAL rdi, rsi
    pop r13
    inc r13
    jmp .map_decref_loop

.map_decref_done:
    pop rdx                          ; restore result tag
    pop rax                          ; restore result payload

    ; Deallocate fat args from stack
    mov rcx, r14
    shl rcx, 4
    add rsp, rcx

    pop r15
    pop r14
    pop r13
    pop rbx
    leave
    ret

.map_partial_cleanup:
    ; One iterator exhausted at index r13. DECREF items 0..r13-1
    xor ecx, ecx
.map_cleanup_loop:
    cmp rcx, r13
    jge .map_cleanup_done
    push rcx
    mov rax, rcx
    shl rax, 4
    mov r8, [rbp - MI_ARGS]
    mov rdi, [r8 + rax]
    mov rsi, [r8 + rax + 8]
    DECREF_VAL rdi, rsi
    pop rcx
    inc rcx
    jmp .map_cleanup_loop

.map_cleanup_done:
    ; Deallocate fat args from stack
    mov rcx, r14
    shl rcx, 4
    add rsp, rcx

    RET_NULL
    pop r15
    pop r14
    pop r13
    pop rbx
    leave
    ret
END_FUNC map_iternext

;; map_dealloc(self)
DEF_FUNC_LOCAL map_dealloc
    push rbx
    push r12
    push r13
    mov rbx, rdi

    ; DECREF func
    mov rdi, [rbx + MAP_FUNC]
    call obj_decref

    ; DECREF each iterator in array
    mov r12, [rbx + MAP_COUNT]
    mov r13, [rbx + MAP_ITERS]
    xor ecx, ecx
.map_dealloc_loop:
    cmp rcx, r12
    jge .map_free_array
    push rcx
    mov rdi, [r13 + rcx * 8]
    call obj_decref
    pop rcx
    inc rcx
    jmp .map_dealloc_loop

.map_free_array:
    mov rdi, r13
    call ap_free

    ; Free self
    mov rdi, rbx
    call ap_free

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC map_dealloc

;; ============================================================================
;; FILTER
;; ============================================================================

;; builtin_filter(args, nargs) -> FilterIterObject*
;; nargs=2: filter(func_or_none, iterable)
DEF_FUNC builtin_filter
    push rbx
    push r12
    push r13

    mov rbx, rdi            ; args
    mov r12, rsi            ; nargs

    cmp r12, 2
    jne .filter_error

    ; Check if func is None
    mov r13, [rbx]          ; r13 = func_or_none
    lea rax, [rel none_singleton]
    cmp r13, rax
    je .filter_none_func

    ; INCREF func
    INCREF r13
    jmp .filter_get_iter

.filter_none_func:
    xor r13d, r13d          ; it_func = NULL for identity/truthiness

.filter_get_iter:
    ; Get iterator from args[1]
    mov rdi, [rbx + 16]
    mov rsi, [rbx + 24]       ; args[1] tag
    call get_iterator
    mov rbx, rax             ; rbx = underlying iterator

    ; Allocate FilterIterObject
    mov edi, ITER_OBJ_SIZE
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel filter_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + IT_FIELD1], r13       ; it_func (or NULL)
    mov [rax + IT_FIELD2], rbx       ; it_iter
    mov edx, TAG_PTR

    pop r13
    pop r12
    pop rbx
    leave
    ret

.filter_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "filter() requires exactly 2 arguments"
    call raise_exception
END_FUNC builtin_filter

;; filter_iternext(self) -> PyObject* or NULL
;; IMPORTANT: Do not clobber r12 before calling tp_call, because func_call
;; reads r12 expecting the eval loop's current frame pointer.
DEF_FUNC_LOCAL filter_iternext
    push rbx
    push r13
    push r14
    push r15

    mov rbx, rdi            ; self

.filter_loop:
    ; Get next item from underlying iterator
    mov rdi, [rbx + IT_FIELD2]       ; it_iter
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    test edx, edx
    jz .filter_exhausted
    mov r13, rax             ; r13 = item payload (we own ref)
    push rdx                 ; save item tag from iternext

    ; Check if func is NULL (identity/truthiness test)
    mov r14, [rbx + IT_FIELD1]   ; it_func
    test r14, r14
    jz .filter_identity

    ; Call func(item) and test truthiness of result
    sub rsp, 16             ; args[0] (16B slot)
    mov [rsp], r13          ; args[0].payload = item
    mov rax, [rsp + 16]    ; item tag (saved above push)
    mov [rsp + 8], rax     ; args[0].tag
    mov rdi, r14             ; func
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    mov rsi, rsp             ; &args[0]
    mov edx, 1
    call rax
    add rsp, 16             ; pop args
    mov r14, rax             ; r14 = result payload
    mov r15, rdx             ; r15 = result tag

    ; Test truthiness of result
    mov rdi, r14
    mov esi, r15d
    call obj_is_true
    push rax                 ; save truthiness

    ; DECREF result
    mov rdi, r14
    mov rsi, r15
    DECREF_VAL rdi, rsi

    pop rax                  ; restore truthiness
    test eax, eax
    jnz .filter_accept

    ; Not truthy: DECREF item, continue
    pop rsi                  ; item tag
    mov rdi, r13
    DECREF_VAL rdi, rsi
    jmp .filter_loop

.filter_identity:
    ; Test truthiness of item itself
    mov rdi, r13
    mov esi, [rsp]           ; item tag (saved on stack)
    call obj_is_true
    test eax, eax
    jnz .filter_accept

    ; Not truthy: DECREF item, continue
    pop rsi                  ; item tag
    mov rdi, r13
    DECREF_VAL rdi, rsi
    jmp .filter_loop

.filter_accept:
    mov rax, r13             ; payload
    pop rdx                  ; tag from iternext
    pop r15
    pop r14
    pop r13
    pop rbx
    leave
    ret

.filter_exhausted:
    RET_NULL
    pop r15
    pop r14
    pop r13
    pop rbx
    leave
    ret
END_FUNC filter_iternext

;; filter_dealloc(self)
DEF_FUNC_LOCAL filter_dealloc
    push rbx
    mov rbx, rdi

    ; DECREF func (if not NULL)
    mov rdi, [rbx + IT_FIELD1]
    test rdi, rdi
    jz .filter_dealloc_iter
    call obj_decref

.filter_dealloc_iter:
    ; DECREF iterator
    mov rdi, [rbx + IT_FIELD2]
    call obj_decref

    ; Free self
    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC filter_dealloc

;; ============================================================================
;; REVERSED
;; ============================================================================

;; builtin_reversed(args, nargs) -> ReversedIterObject*
;; nargs=1: reversed(sequence)
extern dunder_call_1

DEF_FUNC builtin_reversed
    push rbx
    push r12
    push r13

    mov rbx, rdi            ; args
    mov r12, rsi            ; nargs

    cmp r12, 1
    jne .rev_error

    mov r12, [rbx]          ; r12 = sequence

    ; Non-pointer tag — cannot reverse
    test dword [rbx + 8], TAG_RC_BIT
    jz .rev_type_error

    ; Check for range_obj_type — use specialized __reversed__
    mov rax, [r12 + PyObject.ob_type]
    extern range_obj_type
    lea rcx, [rel range_obj_type]
    cmp rax, rcx
    je .rev_range

    ; Check for __reversed__ dunder (heaptypes and builtins)
    ; First use dunder_lookup to see if __reversed__ exists
    mov rdi, [r12 + PyObject.ob_type]
    lea rsi, [rel .dunder_reversed_name]
    extern dunder_lookup
    call dunder_lookup
    test edx, edx
    jz .rev_no_dunder      ; not found at all

    ; Found __reversed__. Check if it's None (blocked).
    cmp eax, 0
    jne .rev_call_dunder
    cmp edx, TAG_NONE
    je .rev_type_error      ; __reversed__ = None means blocked
    ; Check for bool_false (payload=0, TAG_PTR pointing to bool_false)
    ; If payload is 0 with TAG_PTR, it might be a None-like block...actually skip for now.

.rev_call_dunder:
    ; Call __reversed__ via dunder_call_1
    mov rdi, r12
    lea rsi, [rel .dunder_reversed_name]
    call dunder_call_1
    test edx, edx
    jnz .rev_dunder_ok      ; got a result
    jmp .rev_type_error     ; __reversed__ raised

.rev_dunder_ok:
    pop r13
    pop r12
    pop rbx
    leave
    ret

section .rodata
.dunder_reversed_name: db "__reversed__", 0
section .text

.rev_range:
    ; reversed(range) — use range_obj_reversed
    mov rdi, r12
    extern range_obj_reversed
    call range_obj_reversed
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.rev_no_dunder:
    ; No __reversed__ — check sequence protocol (__len__ + __getitem__)
    mov rax, [r12 + PyObject.ob_type]

    ; Try sq_length from tp_as_sequence (builtins like list, tuple, str)
    mov rcx, [rax + PyTypeObject.tp_as_sequence]
    test rcx, rcx
    jz .rev_try_heap_len
    mov rcx, [rcx + PySequenceMethods.sq_length]
    test rcx, rcx
    jz .rev_try_heap_len
    ; Also need sq_item for iteration
    mov rdx, [rax + PyTypeObject.tp_as_sequence]
    mov rdx, [rdx + PySequenceMethods.sq_item]
    test rdx, rdx
    jz .rev_type_error
    mov rdi, r12
    call rcx
    jmp .rev_have_len

.rev_try_heap_len:
    ; Heaptype: check for __len__ and __getitem__
    mov rdx, [rax + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .rev_try_ob_size

    ; Check __len__ exists
    push rax                ; save type
    mov rdi, rax            ; type
    extern dunder_len
    lea rsi, [rel dunder_len]
    call dunder_lookup
    test edx, edx
    pop rcx                 ; restore type
    jz .rev_type_error      ; no __len__

    ; Check __getitem__ exists
    mov rdi, rcx            ; type
    extern dunder_getitem
    lea rsi, [rel dunder_getitem]
    call dunder_lookup
    test edx, edx
    jz .rev_type_error      ; no __getitem__

    ; Call __len__ to get length
    mov rdi, r12
    extern dunder_len
    lea rsi, [rel dunder_len]
    call dunder_call_1
    ; rax = length (SmallInt payload), edx = TAG_SMALLINT
    jmp .rev_have_len

.rev_try_ob_size:
    ; Fallback: read ob_size at +16 (tuples, lists already handled above)
    mov rax, [r12 + PyVarObject.ob_size]

.rev_have_len:
    ; rax = length
    mov r13, rax             ; r13 = length
    dec r13                  ; it_index = length - 1

    ; INCREF the sequence
    INCREF r12

    ; Allocate ReversedIterObject
    mov edi, ITER_OBJ_SIZE
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel reversed_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + IT_FIELD1], r12       ; it_seq
    mov [rax + IT_FIELD2], r13       ; it_index
    mov edx, TAG_PTR

    pop r13
    pop r12
    pop rbx
    leave
    ret

.rev_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "reversed() takes exactly 1 argument"
    call raise_exception

.rev_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "argument to reversed() must be a sequence"
    call raise_exception
END_FUNC builtin_reversed

;; reversed_iternext(self) -> PyObject* or NULL
DEF_FUNC_LOCAL reversed_iternext
    push rbx

    mov rbx, rdi            ; self

    ; Check if index < 0
    mov rax, [rbx + IT_FIELD2]   ; it_index
    test rax, rax
    js .revi_exhausted

    ; Get item at index using sq_item or __getitem__
    mov rdi, [rbx + IT_FIELD1]   ; it_seq
    mov rsi, [rbx + IT_FIELD2]   ; index
    mov rax, [rdi + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_as_sequence]
    test rcx, rcx
    jz .revi_try_getitem
    mov rcx, [rcx + PySequenceMethods.sq_item]
    test rcx, rcx
    jz .revi_try_getitem
    call rcx
    ; rax = item (with INCREF from sq_item), rdx = tag
    jmp .revi_got_item

.revi_try_getitem:
    ; Heaptype: call __getitem__(seq, index)
    mov rdi, [rbx + IT_FIELD1]   ; seq
    mov rsi, [rbx + IT_FIELD2]   ; index (raw i64 = SmallInt payload)
    extern dunder_getitem
    lea rdx, [rel dunder_getitem]
    mov ecx, TAG_SMALLINT
    extern dunder_call_2
    call dunder_call_2
    test edx, edx
    jz .revi_exhausted           ; __getitem__ failed

.revi_got_item:
    ; Decrement index
    dec qword [rbx + IT_FIELD2]

    ; rax = payload, rdx = tag from sq_item/dunder_call_2
    pop rbx
    leave
    ret

.revi_exhausted:
    RET_NULL
    pop rbx
    leave
    ret
END_FUNC reversed_iternext

;; reversed_dealloc(self)
DEF_FUNC_LOCAL reversed_dealloc
    push rbx
    mov rbx, rdi

    ; DECREF the sequence
    mov rdi, [rbx + IT_FIELD1]
    call obj_decref

    ; Free self
    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC reversed_dealloc

;; ============================================================================
;; SORTED
;; ============================================================================

;; builtin_sorted(args, nargs) -> PyListObject*
;; nargs=1: sorted(iterable) -> new sorted list
; sorted() frame layout: fixed-size args buffer for list_method_sort
; Max 3 args (list + key + reverse) = 48 bytes
SO_ARGS       equ 8
SO_NARGS      equ 16
SO_SORT_BUF   equ 72     ; END of sort args buffer (grows down from here)
SO_FRAME      equ 72     ; 24 + 48
DEF_FUNC builtin_sorted, SO_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - SO_ARGS], rdi    ; save original args
    mov [rbp - SO_NARGS], rsi   ; save original nargs

    ; Get iterator from args[0]
    mov rax, rdi
    mov rdi, [rax]              ; args[0] payload
    mov esi, [rax + 8]         ; args[0] tag
    call get_iterator
    mov rbx, rax               ; rbx = iterator

    ; Create new empty list
    xor edi, edi
    call list_new
    mov r12, rax               ; r12 = new list

.sorted_loop:
    mov rdi, rbx
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    test edx, edx
    jz .sorted_done_iter

    push rdx
    push rax
    mov rdi, r12
    mov rsi, rax
    call list_append
    pop rdi
    pop rsi
    DECREF_VAL rdi, rsi
    jmp .sorted_loop

.sorted_done_iter:
    mov rdi, rbx
    call obj_decref

    ; Build args for list_method_sort in fixed frame buffer
    ; args[0] = list
    mov [rbp - SO_SORT_BUF], r12
    mov qword [rbp - SO_SORT_BUF + 8], TAG_PTR

    mov rax, [rel kw_names_pending]
    test rax, rax
    jz .sorted_no_kw

    ; Copy kwarg values into sort args buffer
    mov rcx, [rax + PyTupleObject.ob_size]  ; n_kw
    mov r13, rcx
    mov rsi, [rbp - SO_NARGS]
    sub rsi, rcx              ; n_pos

    xor r9d, r9d
.sorted_kw_copy:
    cmp r9, r13
    jge .sorted_kw_copy_done
    mov rax, [rbp - SO_ARGS]
    mov r10, rsi
    add r10, r9
    shl r10, 4
    lea r8, [r9 + 1]
    shl r8, 4
    mov r11, [rax + r10]
    mov [rbp - SO_SORT_BUF + r8], r11
    mov r11, [rax + r10 + 8]
    mov [rbp - SO_SORT_BUF + r8 + 8], r11
    inc r9
    jmp .sorted_kw_copy
.sorted_kw_copy_done:
    lea rdi, [rbp - SO_SORT_BUF]
    lea rsi, [r13 + 1]        ; nargs = 1 + n_kw
    call list_method_sort
    jmp .sorted_return

.sorted_no_kw:
    lea rdi, [rbp - SO_SORT_BUF]
    mov rsi, 1
    call list_method_sort

.sorted_return:
    DECREF_VAL rax, rdx

    mov rax, r12
    mov edx, TAG_PTR

    pop r13
    pop r12
    pop rbx
    leave
    ret

.sorted_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "sorted() requires exactly 1 argument"
    call raise_exception
END_FUNC builtin_sorted

;; ============================================================================
;; Type call wrappers: tp_call(callable, args, nargs) -> builtin_*(args, nargs)
;; ============================================================================
global enumerate_type_call
DEF_FUNC_BARE enumerate_type_call
    mov rdi, rsi
    mov rsi, rdx
    jmp builtin_enumerate
END_FUNC enumerate_type_call

;; ============================================================================
;; Sequence iterator (__getitem__ protocol)
;; Layout: +0 refcnt, +8 type, +16 it_obj (source), +24 it_index (i64)
;; ============================================================================

;; seq_iter_new(rdi=obj) -> seq_iter_type instance
;; obj must be INCREFed by caller (we take ownership)
DEF_FUNC seq_iter_new
    push rbx
    mov rbx, rdi                   ; save obj

    ; Allocate seq_iter object
    mov rdi, ITER_OBJ_SIZE
    call ap_malloc
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel seq_iter_type]
    mov [rax + PyObject.ob_type], rcx
    INCREF rbx
    mov [rax + IT_FIELD1], rbx     ; it_obj
    mov qword [rax + IT_FIELD2], 0 ; it_index = 0

    pop rbx
    leave
    ret
END_FUNC seq_iter_new

;; seq_iter_iternext(self) -> (rax=payload, edx=tag) or NULL
;; Calls self.it_obj.__getitem__(self.it_index); catches IndexError as exhaustion.
DEF_FUNC_LOCAL seq_iter_iternext
    push rbx
    mov rbx, rdi                   ; self

    ; Call __getitem__(it_obj, it_index)
    mov rdi, [rbx + IT_FIELD1]     ; obj
    mov rsi, [rbx + IT_FIELD2]     ; index (raw i64 = SmallInt payload)
    extern dunder_getitem
    lea rdx, [rel dunder_getitem]
    mov ecx, TAG_SMALLINT          ; other_tag for index
    extern dunder_call_2
    call dunder_call_2
    test edx, edx
    jz .si_check_exc               ; NULL — check for IndexError

    ; Got a value — increment index
    inc qword [rbx + IT_FIELD2]
    pop rbx
    leave
    ret

.si_check_exc:
    ; Check if exception is IndexError or StopIteration
    mov rax, [rel current_exception]
    test rax, rax
    jz .si_exhausted               ; no exception, clean exhaustion
    mov rcx, [rax + PyObject.ob_type]
    extern exc_IndexError_type
    lea rdx, [rel exc_IndexError_type]
    cmp rcx, rdx
    je .si_clear_exc               ; IndexError → normal exhaustion
    lea rdx, [rel exc_StopIteration_type]
    cmp rcx, rdx
    je .si_clear_exc               ; StopIteration → normal exhaustion
    ; Other exception — leave it, return NULL
    jmp .si_exhausted

.si_clear_exc:
    mov rdi, rax
    call obj_decref
    mov qword [rel current_exception], 0
.si_exhausted:
    RET_NULL
    pop rbx
    leave
    ret
END_FUNC seq_iter_iternext

;; seq_iter_dealloc(self)
DEF_FUNC_LOCAL seq_iter_dealloc
    push rbx
    mov rbx, rdi

    ; DECREF the source object
    mov rdi, [rbx + IT_FIELD1]
    call obj_decref

    ; Free self
    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC seq_iter_dealloc

;; ============================================================================
;; Data section - type name strings and type objects
;; ============================================================================
section .data

enumerate_iter_name: db "enumerate", 0
zip_iter_name:       db "zip", 0
map_iter_name:       db "map", 0
filter_iter_name:    db "filter", 0
reversed_iter_name:  db "reversed", 0
seq_iter_name:       db "iterator", 0

; Enumerate iterator type
align 8
global enumerate_iter_type
enumerate_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq enumerate_iter_name      ; tp_name
    dq ITER_OBJ_SIZE            ; tp_basicsize
    dq enumerate_dealloc        ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq itertools_iter_self      ; tp_iter (return self)
    dq enumerate_iternext       ; tp_iternext
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

; Zip iterator type
align 8
global zip_iter_type
zip_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq zip_iter_name            ; tp_name
    dq ZIP_OBJ_SIZE             ; tp_basicsize
    dq zip_dealloc              ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq itertools_iter_self      ; tp_iter
    dq zip_iternext             ; tp_iternext
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

; Map iterator type
align 8
global map_iter_type
map_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq map_iter_name            ; tp_name
    dq MAP_OBJ_SIZE             ; tp_basicsize
    dq map_dealloc              ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq itertools_iter_self      ; tp_iter
    dq map_iternext             ; tp_iternext
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

; Filter iterator type
align 8
global filter_iter_type
filter_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq filter_iter_name         ; tp_name
    dq ITER_OBJ_SIZE            ; tp_basicsize
    dq filter_dealloc           ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq itertools_iter_self      ; tp_iter
    dq filter_iternext          ; tp_iternext
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

; Sequence iterator type (__getitem__ protocol)
align 8
global seq_iter_type
seq_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq seq_iter_name            ; tp_name
    dq ITER_OBJ_SIZE            ; tp_basicsize
    dq seq_iter_dealloc         ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq itertools_iter_self      ; tp_iter
    dq seq_iter_iternext        ; tp_iternext
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

; Reversed iterator type
align 8
global reversed_iter_type
reversed_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq reversed_iter_name       ; tp_name
    dq ITER_OBJ_SIZE            ; tp_basicsize
    dq reversed_dealloc         ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq itertools_iter_self      ; tp_iter
    dq reversed_iternext        ; tp_iternext
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
