; itertools.asm - Iterator builtins: enumerate, zip, map, filter, reversed, sorted
;
; Each iterator type has: type object, _new(), _iternext(), _dealloc(), iter_self
; Builtin signatures: func(PyObject **args, int64_t nargs) -> PyObject*

%include "macros.inc"
%include "object.inc"

extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern ap_free
extern obj_incref
extern iter_traverse_one
extern iter_clear_one
extern obj_decref
extern obj_dealloc
extern obj_is_true
extern fatal_error
extern raise_exception
extern exc_TypeError_type
extern exc_StopIteration_type
extern none_singleton
extern tuple_new
extern list_new
extern obj_richcompare_bool
extern set_exception
extern int_type
extern float_type
extern list_append
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
DEF_FUNC call_iternext, 8            ; 1 pushes, so rsp is 16-aligned
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
    test rax, rax
    jnz .ci_ret               ; got a value, return it

    ; NULL from __next__ — a StopIteration is exhaustion, anything else is
    ; left for the caller to propagate
.ci_check:
    call clear_stopiteration
    jmp .ci_null

.ci_have:
    call rax
    ; A builtin iterator ends the same way: `map(next, its)` returns NULL
    ; with the StopIteration its function raised still pending, and the
    ; contract above says the caller sees exhaustion, not an error.
    test rax, rax
    jz .ci_check
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
;; clear_stopiteration() -> nothing; a pending StopIteration is dropped.
;; An iternext that calls user code (map's function, filter's
;; predicate) ends when that code raises StopIteration, as CPython's does:
;; there the consumer clears it, and the consumers here -- list(), sorted(),
;; set(), `yield from`, unpacking -- read a NULL with an exception still
;; pending as an error, so the iterator clears it before handing NULL back.
;; Clobbers the caller-saved registers.
;; ============================================================================
DEF_FUNC clear_stopiteration
    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jz .cs_done
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel exc_StopIteration_type]
    cmp rcx, rdx
    jne .cs_done
    mov qword [gs:ThreadState.current_exception], 0
    mov rdi, rax
    call obj_decref
.cs_done:
    leave
    ret
END_FUNC clear_stopiteration

;; ============================================================================
;; get_iterator(rdi = obj payload, esi = obj tag) -> rax = iterator, owned
;;   Raises TypeError when the object is not iterable.
;; get_iterator_opt(same) -> rax = iterator, or 0 with NO exception set
;;
;; Both consult tp_iter, then __iter__ on a heaptype, then the legacy
;; __getitem__ sequence protocol -- an object with __getitem__ and no
;; __iter__ is iterable, and iter() synthesises a counter that stops at
;; IndexError.  An __iter__ that RAISES propagates from either.
;;
;; The _opt form exists because every caller that iterates a user-supplied
;; argument has its own message: "set() argument is not iterable",
;; "list.extend() argument must be iterable", "can only assign an iterable".
;; Seven of them used to read tp_iter off the type themselves and so rejected
;; the legacy protocol outright -- which is what made CPython's re parser fail
;; on every non-capturing group, since its SubPattern has __getitem__ and
;; __len__ and no __iter__.
;;
;; Clobbers caller-saved regs.
;; ============================================================================
DEF_FUNC get_iterator
    push rbx
    push r12
    mov rbx, rdi                ; the payload and tag, kept for the message
    mov r12d, esi
    call get_iterator_opt
    test rax, rax
    jz .gi_not_iterable
    pop r12
    pop rbx
    leave
    ret
.gi_not_iterable:
    ; CPython names the type: "'int' object is not iterable".  A bare
    ; "object is not iterable" is the same sentence with the one word that
    ; identifies the mistake taken out of it.  The type comes from the
    ; (payload, tag) pair directly rather than from V_PACK, which would
    ; ALLOCATE for a large int -- on the error path, and unowned.
    cmp r12d, TAG_SMALLINT
    je .gi_int
    cmp r12d, TAG_FLOAT
    je .gi_float
    test rbx, rbx
    jz .gi_unknown
    mov rsi, [rbx + PyObject.ob_type]
    jmp .gi_raise
.gi_int:
    lea rsi, [rel int_type]
    jmp .gi_raise
.gi_float:
    lea rsi, [rel float_type]
    jmp .gi_raise
.gi_unknown:
    xor esi, esi                ; no type: the helper says "object"
.gi_raise:
    lea rdi, [rel gi_not_iterable_msg]
    extern raise_type_error_with_typename
    call raise_type_error_with_typename
END_FUNC get_iterator

section .rodata
gi_not_iterable_msg: db "'", 1, "' object is not iterable", 0
section .text

DEF_FUNC get_iterator_opt, 8            ; 1 pushes, so rsp is 16-aligned
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
    ; Snapshot rather than test for non-NULL: inside an except block
    ; current_exception is the exception BEING HANDLED, so a plain test said
    ; "__iter__ raised" for every object that simply has no __iter__ -- and
    ; the legacy __getitem__ fallback below was never reached there.
    DUNDER_EXC_SAVE r10
    push r10
    sub rsp, 8
    call dunder_call_1
    add rsp, 8
    pop r10
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jnz .validate_iter

    ; __iter__ returned NULL: did it raise, or is there no __iter__ at all?
    DUNDER_RAISED r10, .iter_exc_pending

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
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jz .iter_bad                   ; no __next__ found
    ; Has __next__, good

.iter_ok:
    mov rax, rbx                   ; restore iterator
    pop rbx
    leave
    ret

.iter_bad:
    ; The type is kept across the DECREF and the object is not: naming it
    ; afterwards would read ob_type out of the block just freed.
    mov rax, [rbx + PyObject.ob_type]
    push rax
    push rax                    ; twice, to keep rsp 16-byte aligned
    mov rdi, rbx
    call obj_decref
    pop rsi
    pop rsi
    extern raise_type_error_with_typename
    CSTRING rdi, `iter() returned non-iterator of type '\x01'`
    call raise_type_error_with_typename

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
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    jz .no_iter                    ; no __getitem__
    ; Has __getitem__ — create seq_iter
    mov rdi, rbx                   ; obj
    call seq_iter_new
    pop rbx
    leave
    ret

.no_iter:
    ; Not iterable.  No exception: the caller names the argument.
    xor eax, eax
    pop rbx
    leave
    ret

.iter_exc_pending:
    ; Exception was raised by __iter__. Propagate it via eval_exception_unwind.
    extern eval_exception_unwind
    PUBLISH_SP
    pop rbx
    leave
    jmp eval_exception_unwind
END_FUNC get_iterator_opt

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
; The start= argument as it arrived, for the message when it is not an
; integer: the refusal named no type at all, and carried a literal %s.
EN_BADVAL  equ 48
EN_FRAME   equ 56            ; + 3 pushes = 80, 16-aligned
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
    mov rax, [gs:ThreadState.kw_names_pending]
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
    mov rax, [rbx]              ; args[0] = the iterable
    V_UNPACK rax, rdx
    mov [rbp - EN_ITER], rax
    mov [rbp - EN_ITERTAG], rdx

    cmp r12, 2
    jne .enum_get_iter

    ; start = int(args[1])  (positional)
    mov rdi, [rbx + 8]
    mov [rbp - EN_BADVAL], rdi
    V_UNPACK rdi, rdx       ; args[1]
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

    ; Compute value offset in args: (original_n_pos + kw_idx) * 8
    ; Use r8 (original n_pos), NOT [rbp - EN_NPOS] which may have been updated
    mov r11, r8
    add r11, r9
    shl r11, 3

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
    mov rdi, [rbx + r11]           ; the value Value
    mov [rbp - EN_BADVAL], rdi
    V_UNPACK rdi, rdx
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
    mov rdi, [rbx + r11]           ; the iterable Value
    V_UNPACK rdi, rsi
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
    mov qword [gs:ThreadState.kw_names_pending], 0

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
    mov rax, [rbx]              ; args[0] = the iterable
    V_UNPACK rax, rdx
    mov [rbp - EN_ITER], rax
    mov [rbp - EN_ITERTAG], rdx

.enum_get_iter:
    ; Get iterator from saved iterable (locals, not args - args on value stack)
    mov rdi, [rbp - EN_ITER]
    mov rsi, [rbp - EN_ITERTAG]
    call get_iterator
    mov rbx, rax                  ; rbx = underlying iterator

    ; Allocate EnumerateIterObject
    mov edi, ITER_OBJ_SIZE
    lea rsi, [rel enumerate_iter_type]
    call gc_alloc

    ; Fill fields
    mov [rax + IT_FIELD1], rbx       ; it_iter
    mov r13, [rbp - EN_START]
    mov [rax + IT_FIELD2], r13       ; it_count (raw i64, not SmallInt)
    ; gc_track only after every field is set: it can trigger a
    ; collection, and the traverse would walk uninitialised words.
    push rax
    mov rdi, rax
    call gc_track
    pop rax
    mov edx, TAG_PTR

    pop r13
    pop r12
    pop rbx
    leave
    ret

.enum_type_error:
    mov qword [gs:ThreadState.kw_names_pending], 0
    ; CPython builds the iterator before it looks at start=, so an argument
    ; that is wrong in both ways is reported as the iterable it is not:
    ; enumerate(True, True) is "'bool' object is not iterable" there.
    mov rdi, [rbp - EN_ITER]
    test rdi, rdi
    jnz .enum_te_have_iterable
    mov rax, [rbp - EN_ARGS]
    mov rdi, [rax]
    V_UNPACK rdi, rsi
    mov [rbp - EN_ITER], rdi
    mov [rbp - EN_ITERTAG], rsi
.enum_te_have_iterable:
    mov rdi, [rbp - EN_ITER]
    mov rsi, [rbp - EN_ITERTAG]
    call get_iterator                   ; raises if it is not one
    mov rdi, rax
    V_UNPACK rdi, rdx
    call obj_decref
    mov rsi, [rbp - EN_BADVAL]
    CSTRING rdi, `'\x01' object cannot be interpreted as an integer`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.enum_error:
    mov qword [gs:ThreadState.kw_names_pending], 0
    RAISE exc_TypeError_type, "enumerate() requires 1 or 2 arguments"
END_FUNC builtin_enumerate

;; enumerate_iternext(self) -> PyObject* (2-tuple) or NULL
DEF_FUNC_LOCAL enumerate_iternext, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    mov rbx, rdi            ; self

    ; Call underlying iterator's iternext
    mov rdi, [rbx + IT_FIELD1]       ; it_iter
    call call_iternext
    test rax, rax
    jz .enum_exhausted
    mov r12, rax             ; r12 = value Value from iternext

    mov r13, [rbx + IT_FIELD2]       ; r13 = count
    inc qword [rbx + IT_FIELD2]      ; increment for next time
    V_PACK_I64 r13, rcx              ; the count as a Value

    ; Create 2-tuple
    mov edi, 2
    call tuple_new
    ; Fill: tuple[0] = count, tuple[1] = value
    mov r8, [rax + PyTupleObject.ob_item]
    mov [r8], r13            ; slot 0
    mov [r8 + 8], r12        ; slot 1

    pop r13
    pop r12
    pop rbx
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

;; ============================================================================
;; The traverse/clear pairs for the wrapper iterators.
;;
;; enumerate, zip, map, filter and reversed all came from ap_malloc
;; with tp_flags 0, so a cycle through one leaked: `a = []; z = zip(a, a);
;; a.append(z)` collected nothing where CPython collects six objects.  The
;; simple container iterators were tracked earlier and share one pair, because
;; each keeps exactly one owned pointer at the same offset.  These do not.
;;
;; enumerate and reversed DO fit that shape -- one owned pointer at +16, a raw
;; integer at +24 -- so they use iter_traverse_one and iter_clear_one
;; unchanged.  The other four need their own:
;;
;;   filter  two owned pointers, and the first is legitimately NULL for
;;           filter(None, xs), so a clear must not read 0 as "already done"
;;   zip     an ap_malloc'd array of iterators, walked by a count
;;   map     an array as well, plus a Value -- not a pointer -- for the
;;           function, which needs VISIT_V and DECREF_V rather than the
;;           pointer forms
;;
;; A clear has to leave the object safe for the dealloc that follows: every
;; field it releases is zeroed, and the array pointer with them, which is why
;; each dealloc's NULL checks matter.  ap_free is NULL-safe.
;; ============================================================================
DEF_FUNC_LOCAL filter_traverse, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + IT_FIELD1]  ; the function, or NULL for filter(None, xs)
    V_TEST_PTR rdi, rax         ; a Value: only a pointer is the collector's
    ja .ft_iter
    VISIT_PTR rdi
.ft_iter:
    mov rdi, [rbx + IT_FIELD2]
    VISIT_PTR rdi
    pop rbx
    leave
    ret
END_FUNC filter_traverse

DEF_FUNC_LOCAL filter_clear, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + IT_FIELD1]
    test rdi, rdi
    jz .fc_iter
    mov qword [rbx + IT_FIELD1], 0
    XDECREF_V rdi, rax
.fc_iter:
    mov rdi, [rbx + IT_FIELD2]
    test rdi, rdi
    jz .fc_done
    mov qword [rbx + IT_FIELD2], 0
    call obj_decref
.fc_done:
    pop rbx
    leave
    ret
END_FUNC filter_clear

;; zip: an iterator array at +16 walked by a count at +24.
DEF_FUNC_LOCAL iters_array_traverse, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    push r12
    push r13
    mov rbx, [rdi + IT_FIELD1]
    mov r12, [rdi + IT_FIELD2]
    test rbx, rbx
    jz .iat_done
    xor r13d, r13d
.iat_loop:
    cmp r13, r12
    jge .iat_done
    mov rdi, [rbx + r13 * 8]
    VISIT_PTR rdi
    inc r13
    jmp .iat_loop
.iat_done:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC iters_array_traverse

DEF_FUNC_LOCAL iters_array_clear, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, [rbx + IT_FIELD1]
    mov r13, [rbx + IT_FIELD2]
    test r12, r12
    jz .iac_done
    ; Unhook first, so a decref that re-enters cannot walk the array again.
    mov qword [rbx + IT_FIELD1], 0
    mov qword [rbx + IT_FIELD2], 0
    xor ecx, ecx
.iac_loop:
    cmp rcx, r13
    jge .iac_free
    push rcx
    mov rdi, [r12 + rcx * 8]
    call obj_decref
    pop rcx
    inc rcx
    jmp .iac_loop
.iac_free:
    mov rdi, r12
    call ap_free
.iac_done:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC iters_array_clear

;; map: a Value function at +16, then the same array shape one slot along.
DEF_FUNC_LOCAL map_traverse, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov rax, [rbx + MAP_FUNC]
    VISIT_V rax, rcx
    mov r12, [rbx + MAP_ITERS]
    mov r13, [rbx + MAP_COUNT]
    test r12, r12
    jz .mt_done
    xor ecx, ecx
.mt_loop:
    cmp rcx, r13
    jge .mt_done
    push rcx
    mov rdi, [r12 + rcx * 8]
    VISIT_PTR rdi
    pop rcx
    inc rcx
    jmp .mt_loop
.mt_done:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC map_traverse

DEF_FUNC_LOCAL map_clear, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov rax, [rbx + MAP_FUNC]
    test rax, rax
    jz .mc_iters
    mov qword [rbx + MAP_FUNC], 0
    DECREF_V rax, rcx
.mc_iters:
    mov r12, [rbx + MAP_ITERS]
    mov r13, [rbx + MAP_COUNT]
    test r12, r12
    jz .mc_done
    mov qword [rbx + MAP_ITERS], 0
    mov qword [rbx + MAP_COUNT], 0
    xor ecx, ecx
.mc_loop:
    cmp rcx, r13
    jge .mc_free
    push rcx
    mov rdi, [r12 + rcx * 8]
    call obj_decref
    pop rcx
    inc rcx
    jmp .mc_loop
.mc_free:
    mov rdi, r12
    call ap_free
.mc_done:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC map_clear

DEF_FUNC_LOCAL enumerate_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; DECREF the underlying iterator
    mov rdi, [rbx + IT_FIELD1]
    call obj_decref

    ; Free self
    mov rdi, rbx
    call gc_dealloc

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
ZP_FRAME   equ 32           ; + 4 pushes = 64
DEF_FUNC builtin_zip, ZP_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov [rbp - ZP_ARGS], rdi     ; save args
    mov [rbp - ZP_NARGS], rsi    ; save nargs
    mov qword [rbp - ZP_STRICT], 0

    ; Check for strict= kwarg
    mov rax, [gs:ThreadState.kw_names_pending]
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

    ; Compute value offset: (n_pos + kw_idx) * 8
    mov r11, r12
    add r11, r9
    shl r11, 3

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
    mov qword [gs:ThreadState.kw_names_pending], 0
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
    shl rax, 3                  ; one Value per slot
    mov rdi, [rbx + rax]
    V_UNPACK rdi, rsi
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
    lea rsi, [rel zip_iter_type]
    call gc_alloc

    mov [rax + IT_FIELD1], r13       ; it_iters (array ptr)
    mov [rax + IT_FIELD2], r12       ; it_count
    mov rcx, [rbp - ZP_STRICT]
    mov [rax + ZIP_STRICT], rcx      ; strict flag
    ; gc_track only after every field is set: it can trigger a
    ; collection, and the traverse would walk uninitialised words.
    push rax
    mov rdi, rax
    call gc_track
    pop rax
    mov edx, TAG_PTR

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.zip_zero:
    ; Create a zip with 0 iterators (will immediately exhaust)
    mov edi, ZIP_OBJ_SIZE
    lea rsi, [rel zip_iter_type]
    call gc_alloc

    mov qword [rax + IT_FIELD1], 0   ; NULL iters array
    mov qword [rax + IT_FIELD2], 0   ; 0 iterators
    mov qword [rax + ZIP_STRICT], 0  ; not strict
    ; gc_track only after every field is set: it can trigger a
    ; collection, and the traverse would walk uninitialised words.
    push rax
    mov rdi, rax
    call gc_track
    pop rax
    mov edx, TAG_PTR

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC builtin_zip

;; zip_iternext(self) -> PyObject* (tuple) or NULL
DEF_FUNC_LOCAL zip_iternext, 8            ; 5 pushes, so rsp is 16-aligned
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
    test rax, rax
    jz .zip_partial_cleanup

    ; Store the item Value in the tuple
    mov r8, [r14 + PyTupleObject.ob_item]
    mov [r8 + r15 * 8], rax

    inc r15
    jmp .zip_next_loop

.zip_done:
    mov rax, r14
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.zip_partial_cleanup:
    ; One iterator exhausted at index r15, so slots 0..r15-1 hold this round's
    ; items and the rest are still the zeros tuple_new left.  Releasing the
    ; tuple is the whole cleanup: tuple_dealloc walks those same slots and
    ; DECREF_Vs each, and a NULL is a no-op there.
    ;
    ; This used to DECREF 0..r15-1 by hand FIRST and then release the tuple,
    ; which released each of them twice -- so every element of a longer
    ; iterable that landed in the last, incomplete round lost a reference it
    ; still had.  It needs the SECOND iterable to be the short one to bite:
    ; with the first exhausted, nothing has been stored yet.
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
    mov r14d, 1
.zip_strict_check:
    cmp r14, r12
    jge .zip_exhausted       ; all exhausted — OK

    mov rdi, [r13 + r14 * 8]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    test rax, rax
    jnz .zip_strict_decref_err  ; non-NULL = this one is longer

    inc r14
    jmp .zip_strict_check

.zip_strict_decref_err:
    ; DECREF the extra value we got from the longer iterator
    mov rdi, rax
    push r14
    sub rsp, 8
    DECREF_V rdi, rsi
    add rsp, 8
    pop r14
    mov r15, r14                ; the index of the LONGER one
    mov r14d, 1
    jmp .zip_strict_build
.zip_strict_mismatch:
    ; r15 already holds the index of the SHORTER one.
    xor r14d, r14d

.zip_strict_build:
    ; CPython says WHICH argument and in which direction:
    ;   zip() argument 2 is shorter than argument 1
    ;   zip() argument 3 is shorter than arguments 1-2
    ; and the same two shapes for "longer".  This said "zip() has arguments
    ; with different lengths" whichever happened -- and the index and the
    ; direction are both in hand at the raise, so it was wording rather than
    ; machinery.  The plural arrives with the third argument.
    lea rdi, [rel zip_msg_buf]
    extern rbt_append_cstr
    CSTRING rsi, "zip() argument "
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [r15 + 1]
    extern msg_append_i64
    call msg_append_i64
    mov rdi, rax
    test r14d, r14d
    jz .zip_msg_shorter
    CSTRING rsi, " is longer than argument"
    jmp .zip_msg_joined
.zip_msg_shorter:
    CSTRING rsi, " is shorter than argument"
.zip_msg_joined:
    call rbt_append_cstr
    mov rdi, rax
    cmp r15, 1
    je .zip_msg_one
    CSTRING rsi, "s 1-"
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, r15
    call msg_append_i64
    jmp .zip_msg_done
.zip_msg_one:
    CSTRING rsi, " 1"
    call rbt_append_cstr
.zip_msg_done:

    ; Set exception without longjmp — return NULL so callers can clean up
    extern exc_from_cstr
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel zip_msg_buf]
    call exc_from_cstr
    ; rax = exception object
    push rax
    mov rdi, [gs:ThreadState.current_exception]
    test rdi, rdi
    jz .zip_strict_no_prev
    call obj_decref
.zip_strict_no_prev:
    pop rax
    mov [gs:ThreadState.current_exception], rax
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

section .bss
;; Where zip(strict=True) composes its refusal.  A raise follows immediately,
;; so nothing outlives the call.
zip_msg_buf: resb 96
section .text

;; zip_dealloc(self)
DEF_FUNC_LOCAL zip_dealloc, 8            ; 3 pushes, so rsp is 16-aligned
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
    call gc_dealloc

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
    mov r13, [rbx]          ; r13 = func Value
    V_TEST_PTR r13, rax
    ja .map_have_func
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
    shl rax, 3                  ; one Value per slot
    mov rdi, [rbx + rax]        ; args[i+1]
    V_UNPACK rdi, rsi
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
    lea rsi, [rel map_iter_type]
    call gc_alloc

    mov [rax + MAP_FUNC], r13        ; it_func
    mov [rax + MAP_ITERS], rbx       ; it_iters (array ptr)
    mov [rax + MAP_COUNT], r14       ; it_count
    ; gc_track only after every field is set: it can trigger a
    ; collection, and the traverse would walk uninitialised words.
    push rax
    mov rdi, rax
    call gc_track
    pop rax
    mov edx, TAG_PTR

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.map_error:
    RAISE exc_TypeError_type, "map() must have at least two arguments."
END_FUNC builtin_map

;; map_iternext(self) -> rax = Value or NULL
;; Supports multiple iterables: calls func(next(it1), next(it2), ...)
;; IMPORTANT: Do not clobber r12 before calling tp_call, because func_call
;; reads r12 expecting the eval loop's current frame pointer.
MI_ARGS    equ 16     ; pointer to the Value args array on the stack
MI_ASIZE   equ 24     ; bytes reserved for it
MI_FRAME   equ 32           ; + 4 pushes = 64
DEF_FUNC_LOCAL map_iternext, MI_FRAME
    push rbx
    push r13
    push r14
    push r15

    mov rbx, rdi                     ; self
    mov r14, [rbx + MAP_COUNT]       ; iter count
    mov r15, [rbx + MAP_ITERS]       ; iters array

    ; Allocate the args array on the stack: count Values, 16-byte aligned
    lea rax, [r14*8 + 15]
    and rax, -16
    sub rsp, rax
    mov [rbp - MI_ARGS], rsp         ; save args base
    mov [rbp - MI_ASIZE], rax

    ; For each iterator, get next value
    xor r13d, r13d                   ; i = 0
.map_next_loop:
    cmp r13, r14
    jge .map_call_func

    mov rdi, [r15 + r13 * 8]        ; iterator[i]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    test rax, rax
    jz .map_partial_cleanup

    ; Store the item Value in the args array
    mov rcx, r13
    shl rcx, 3
    mov r8, [rbp - MI_ARGS]
    mov [r8 + rcx], rax

    inc r13
    jmp .map_next_loop

.map_call_func:
    ; obj_call_n, not the tp_call slot: `map(0, [1])` read a small integer's
    ; Value as a type pointer, and a type with no tp_call called through a
    ; NULL.  CPython refuses it here, on the first next(), and names it.  A
    ; failure comes back as a NULL Value, which the arguments are released
    ; around exactly as a result is.
    mov rdi, [rbx + MAP_FUNC]       ; func, as a Value
    mov rsi, [rbp - MI_ARGS]         ; args pointer
    mov rdx, r14                     ; nargs = count
    extern obj_call_n
    call obj_call_n
    test rax, rax
    jnz .map_called
    call clear_stopiteration         ; func raised StopIteration: map ends
    xor eax, eax
.map_called:
    V_UNPACK rax, rdx
    push rax                         ; save result payload
    push rdx                         ; save result tag

    ; DECREF_VAL each arg
    xor r13d, r13d
.map_decref_loop:
    cmp r13, r14
    jge .map_decref_done
    mov rcx, r13
    shl rcx, 3
    mov r8, [rbp - MI_ARGS]
    mov rdi, [r8 + rcx]
    push r13
    DECREF_V rdi, rsi
    pop r13
    inc r13
    jmp .map_decref_loop

.map_decref_done:
    pop rdx                          ; restore result tag
    pop rax                          ; restore result payload

    ; Deallocate the args array from the stack
    add rsp, [rbp - MI_ASIZE]
    V_PACK rax, rdx

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
    shl rax, 3
    mov r8, [rbp - MI_ARGS]
    mov rdi, [r8 + rax]
    DECREF_V rdi, rsi
    pop rcx
    inc rcx
    jmp .map_cleanup_loop

.map_cleanup_done:
    ; Deallocate the args array from the stack
    add rsp, [rbp - MI_ASIZE]

    RET_NULL
    pop r15
    pop r14
    pop r13
    pop rbx
    leave
    ret
END_FUNC map_iternext

;; map_dealloc(self)
DEF_FUNC_LOCAL map_dealloc, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    mov rbx, rdi

    ; DECREF func.  DECREF_V, not obj_decref: MAP_FUNC holds a VALUE, and
    ; map(1, [1]) stores an int immediate there -- which the constructor was
    ; careful not to INCREF and which this released as a pointer.  map_clear
    ; and map_traverse beside it already use the Value-aware forms; this one
    ; did not, and the crash was in the collector rather than in map.
    mov rdi, [rbx + MAP_FUNC]
    DECREF_V rdi, rax

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
    call gc_dealloc

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
DEF_FUNC builtin_filter, 8            ; 3 pushes, so rsp is 16-aligned
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

    ; A VALUE, not a pointer: `filter(0, xs)` is an ordinary call -- CPython
    ; refuses the 0 on the first next(), not here -- and INCREF on a small
    ; integer's Value writes through the number.
    mov rax, r13
    INCREF_V rax, rcx
    jmp .filter_get_iter

.filter_none_func:
    xor r13d, r13d          ; it_func = NULL for identity/truthiness

.filter_get_iter:
    ; Get iterator from args[1]
    mov rdi, [rbx + 8]
    V_UNPACK rdi, rsi       ; args[1]
    call get_iterator
    mov rbx, rax             ; rbx = underlying iterator

    ; Allocate FilterIterObject
    mov edi, ITER_OBJ_SIZE
    lea rsi, [rel filter_iter_type]
    call gc_alloc

    mov [rax + IT_FIELD1], r13       ; it_func (or NULL)
    mov [rax + IT_FIELD2], rbx       ; it_iter
    ; gc_track only after every field is set: it can trigger a
    ; collection, and the traverse would walk uninitialised words.
    push rax
    mov rdi, rax
    call gc_track
    pop rax
    mov edx, TAG_PTR

    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.filter_error:
    CSTRING rdi, "filter expected 2 arguments, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_filter

;; filter_iternext(self) -> rax = Value or NULL
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
    test rax, rax
    jz .filter_exhausted
    V_UNPACK rax, rdx
    mov r13, rax             ; r13 = item payload (we own ref)
    push rdx                 ; save item tag from iternext

    ; Check if func is NULL (identity/truthiness test)
    mov r14, [rbx + IT_FIELD1]   ; it_func
    test r14, r14
    jz .filter_identity

    ; Call func(item) and test truthiness of result.  obj_call_n, not the
    ; tp_call slot: `filter(0, [1])` read a small integer's Value as a type
    ; pointer, and a type with no tp_call called through a NULL.  CPython
    ; refuses it here, on the first next(), and names it.
    sub rsp, 16             ; one Value; 16 keeps rsp aligned
    mov rax, [rsp + 16]     ; item tag (pushed above)
    mov rcx, r13
    V_PACK rcx, rax         ; args[0] = item
    mov [rsp], rcx
    mov rdi, r14             ; func, as a Value
    mov rsi, rsp             ; &args[0]
    mov edx, 1
    extern obj_call_n
    call obj_call_n
    add rsp, 16             ; pop args
    test rax, rax
    jz .filter_call_failed
    V_UNPACK rax, rdx
    mov r14, rax             ; r14 = result payload
    mov r15, rdx             ; r15 = result tag

    ; Test truthiness of result
    mov rdi, r14
    mov esi, r15d
    V_PACK rdi, rsi
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
    V_PACK rdi, rsi
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
    V_PACK rax, rdx
    pop r15
    pop r14
    pop r13
    pop rbx
    leave
    ret

.filter_call_failed:
    ; The exception is recorded; release the item and hand NULL back, which
    ; is what a raising iternext looks like -- unless it is StopIteration,
    ; which ends the filter instead.
    pop rsi                  ; the item tag
    mov rdi, r13
    DECREF_VAL rdi, rsi
    call clear_stopiteration
    RET_NULL
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
DEF_FUNC_LOCAL filter_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; DECREF func (if not NULL).  A Value, so a non-pointer is nobody's.
    mov rdi, [rbx + IT_FIELD1]
    test rdi, rdi
    jz .filter_dealloc_iter
    XDECREF_V rdi, rax

.filter_dealloc_iter:
    ; DECREF iterator
    mov rdi, [rbx + IT_FIELD2]
    call obj_decref

    ; Free self
    mov rdi, rbx
    call gc_dealloc

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

DEF_FUNC builtin_reversed, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    mov rbx, rdi            ; args
    mov r12, rsi            ; nargs

    cmp r12, 1
    jne .rev_error

    mov r12, [rbx]          ; r12 = sequence

    ; Only a heap pointer can be reversed
    V_TEST_PTR r12, rax
    ja .rev_type_error

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
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    jz .rev_no_dunder      ; not found at all

    ; Found __reversed__.  Setting it to None blocks reversal.
    IS_NONE rax, rcx
    je .rev_type_error
    test rax, rax
    jz .rev_type_error

.rev_call_dunder:
    ; Call __reversed__ via dunder_call_1
    mov rdi, r12
    lea rsi, [rel .dunder_reversed_name]
    call dunder_call_1
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jnz .rev_dunder_ok      ; got a result
    jmp .rev_type_error     ; __reversed__ raised

.rev_dunder_ok:
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
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
    V_PACK rax, rdx             ; builtins return one Value
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
    ; Also need sq_item for iteration.  A heaptype with __len__ now carries
    ; sq_length from the slot wiring but no sq_item, so erroring here refused
    ; reversed() on the ordinary __len__ + __getitem__ class it used to work
    ; for; that class is handled below.
    mov rdx, [rax + PyTypeObject.tp_as_sequence]
    mov rdx, [rdx + PySequenceMethods.sq_item]
    test rdx, rdx
    jz .rev_try_heap_len
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
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    pop rcx                 ; restore type
    jz .rev_type_error      ; no __len__

    ; Check __getitem__ exists
    mov rdi, rcx            ; type
    extern dunder_getitem
    lea rsi, [rel dunder_getitem]
    call dunder_lookup
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    jz .rev_type_error      ; no __getitem__

    ; Call __len__ to get length
    mov rdi, r12
    extern dunder_len
    lea rsi, [rel dunder_len]
    call dunder_call_1
    V_UNPACK rax, rdx           ; returns a Value
    ; rax = length (SmallInt payload), edx = TAG_SMALLINT
    jmp .rev_have_len

.rev_try_ob_size:
    ; No __reversed__, no sequence protocol: not reversible.  Reading ob_size
    ; off whatever this is made reversed(None) and reversed(True) return an
    ; empty iterator instead of raising.
    jmp .rev_type_error

.rev_have_len:
    ; rax = length
    mov r13, rax             ; r13 = length
    dec r13                  ; it_index = length - 1

    ; INCREF the sequence
    INCREF r12

    ; Allocate ReversedIterObject
    mov edi, ITER_OBJ_SIZE
    lea rsi, [rel reversed_iter_type]
    call gc_alloc

    mov [rax + IT_FIELD1], r12       ; it_seq
    mov [rax + IT_FIELD2], r13       ; it_index
    ; gc_track only after every field is set: it can trigger a
    ; collection, and the traverse would walk uninitialised words.
    push rax
    mov rdi, rax
    call gc_track
    pop rax
    mov edx, TAG_PTR

    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.rev_error:
    CSTRING rdi, "reversed expected 1 argument, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted

.rev_type_error:
    mov rsi, r12
    CSTRING rdi, `'\x01' object is not reversible`
    extern raise_type_error_with_name
    call raise_type_error_with_name
END_FUNC builtin_reversed

;; reversed_iternext(self) -> rax = Value or NULL
DEF_FUNC_LOCAL reversed_iternext, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx

    mov rbx, rdi            ; self

    ; Check if index < 0
    mov rax, [rbx + IT_FIELD2]   ; it_index
    test rax, rax
    js .revi_exhausted
    ; iter_clear_one is this type's tp_clear, so the sequence can already be
    ; gone; and it is dropped at exhaustion below.  Either way a NULL here
    ; means exhausted, not something to dereference.
    cmp qword [rbx + IT_FIELD1], 0
    je .revi_done

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
    V_UNPACK rax, rdx          ; sq_item returns a Value
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
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jz .revi_exhausted           ; __getitem__ failed

.revi_got_item:
    ; Decrement index
    dec qword [rbx + IT_FIELD2]

    ; sq_item and dunder_call_2 both still return a fat pair
    V_PACK rax, rdx
    pop rbx
    leave
    ret

.revi_exhausted:
    ; Drop the sequence at exhaustion, as CPython's listreviter does and as
    ; every forward iterator here now does.  Clear before releasing --
    ; list_iter_next carries the reason in full.  reversed_dealloc still
    ; releases it_seq afterwards, which is fine: obj_decref is NULL-safe.
    mov rdi, [rbx + IT_FIELD1]
    mov qword [rbx + IT_FIELD1], 0
    call obj_decref
.revi_done:
    RET_NULL
    pop rbx
    leave
    ret
END_FUNC reversed_iternext

;; reversed_dealloc(self)
DEF_FUNC_LOCAL reversed_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; DECREF the sequence
    mov rdi, [rbx + IT_FIELD1]
    call obj_decref

    ; Free self
    mov rdi, rbx
    call gc_dealloc

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
SO_EXC        equ 80     ; the exception pending before iteration began
SO_FRAME      equ 104       ; + 3 pushes = 128, 16-aligned.  It said "+ 0
                            ; pushes" and there are three below, so every call
                            ; in this body was eight bytes out -- including
                            ; list.sort, whose comparisons reach int_compare
                            ; and so GMP.
DEF_FUNC builtin_sorted, SO_FRAME
    push rbx                    ; before DUNDER_EXC_SAVE, not after: a push
    push r12                    ; that follows any other instruction is a push
    push r13                    ; lint.py's check_alignment cannot count
    DUNDER_EXC_SAVE [rbp - SO_EXC]

    mov [rbp - SO_ARGS], rdi    ; save original args
    mov [rbp - SO_NARGS], rsi   ; save original nargs

    ; key= and reverse= are keyword-only, so exactly one POSITIONAL argument
    ; is allowed -- the keyword values arrive in the same array and have to
    ; be discounted.  `sorted([], 1)` sorted the [] and dropped the 1.
    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jz .sorted_npos_is_nargs
    mov rax, [rax + PyTupleObject.ob_size]
.sorted_npos_is_nargs:
    neg rax
    add rax, rsi                ; positional count
    cmp rax, 1
    jne .sorted_error

    ; Get iterator from args[0]
    mov rax, rdi
    mov rdi, [rax]              ; args[0]
    V_UNPACK rdi, rsi
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
    V_UNPACK rax, rdx           ; tp_iternext returns a Value
    test edx, edx
    jz .sorted_done_iter

    push rdx
    push rax
    mov rdi, r12
    mov rsi, rax
    V_PACK rsi, rdx         ; list_append takes a Value
    call list_append
    pop rdi
    pop rsi
    DECREF_VAL rdi, rsi
    jmp .sorted_loop

.sorted_done_iter:
    mov rdi, rbx
    call obj_decref

    ; call_iternext answers NULL both for a clean exhaustion and for a
    ; __next__ that raised something other than StopIteration -- it clears
    ; StopIteration itself and leaves anything else pending.  list() checks;
    ; sorted() did not, so sorted(x) quietly returned a partial result while
    ; the exception waited to surface somewhere unrelated.  The comparison is
    ; against the value saved on entry, not against 0: current_exception is
    ; also the exception *being handled*, so inside an `except` block a bare
    ; test made sorted() re-raise it.
    EXC_RAISED_SINCE [rbp - SO_EXC], rax, .sorted_propagate

    ; Build args for list_method_sort in the fixed frame buffer
    ; args[0] = list (a pointer is its own Value)
    mov [rbp - SO_SORT_BUF], r12

    mov rax, [gs:ThreadState.kw_names_pending]
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
    shl r10, 3
    lea r8, [r9 + 1]
    shl r8, 3
    mov r11, [rax + r10]
    mov [rbp - SO_SORT_BUF + r8], r11
    inc r9
    jmp .sorted_kw_copy
.sorted_kw_copy_done:
    lea rdi, [rbp - SO_SORT_BUF]
    lea rsi, [r13 + 1]        ; nargs = 1 + n_kw
    call list_method_sort
    jmp .sorted_return

.sorted_no_kw:
    lea rdi, [rbp - SO_SORT_BUF]
    mov esi, 1
    call list_method_sort

.sorted_return:
    ; list_method_sort answers None on success and a NULL Value with the
    ; exception pending on failure -- a comparison that raised, or a key=
    ; that did.  Handing the list back regardless made sorted() answer a
    ; half-sorted list where L.sort() over the same items correctly raised,
    ; and left the exception to surface at interpreter exit.
    test rax, rax
    jz .sorted_sort_raised
    DECREF_V rax, rdx

    mov rax, r12
    mov edx, TAG_PTR

    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.sorted_error:
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov rsi, rax
    CSTRING rdi, "sorted expected 1 argument, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted
.sorted_sort_raised:
    mov rdi, r12                ; the list we built and were about to return
    call obj_decref
    xor eax, eax                ; a NULL Value, with the exception pending
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sorted_propagate:
    mov rdi, r12
    call obj_decref             ; the partially built list
    leave
    PUBLISH_SP
    jmp eval_exception_unwind
END_FUNC builtin_sorted

;; ============================================================================
;; Type call wrappers: tp_call(callable, args, nargs) -> builtin_*(args, nargs)
;; ============================================================================
DEF_FUNC_BARE enumerate_type_call
    mov rdi, rsi
    mov rsi, rdx
    jmp builtin_enumerate
END_FUNC enumerate_type_call

; range, zip, map, filter and reversed are types in CPython, not functions:
; `Sequence.register(range)` and `Iterator.register(zip)` in _collections_abc
; both fail outright if they are anything else, and `isinstance(x, range)`
; needs a type to test against.  The object types already existed; these
; wrappers are what let the name be bound to the type instead of the
; constructor function.
DEF_FUNC_BARE range_type_call
    mov rdi, rsi
    mov rsi, rdx
    extern builtin_range
    jmp builtin_range
END_FUNC range_type_call

DEF_FUNC_BARE zip_type_call
    mov rdi, rsi
    mov rsi, rdx
    jmp builtin_zip
END_FUNC zip_type_call

DEF_FUNC_BARE map_type_call
    mov rdi, rsi
    mov rsi, rdx
    jmp builtin_map
END_FUNC map_type_call

DEF_FUNC_BARE filter_type_call
    mov rdi, rsi
    mov rsi, rdx
    jmp builtin_filter
END_FUNC filter_type_call

DEF_FUNC_BARE reversed_type_call
    mov rdi, rsi
    mov rsi, rdx
    jmp builtin_reversed
END_FUNC reversed_type_call

;; ============================================================================
;; Sequence iterator (__getitem__ protocol)
;; Layout: +0 refcnt, +8 type, +16 it_obj (source), +24 it_index (i64)
;; ============================================================================

;; seq_iter_new(rdi=obj) -> seq_iter_type instance
;; obj must be INCREFed by caller (we take ownership)
global seq_iter_new
DEF_FUNC seq_iter_new, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi                   ; save obj

    ; gc_alloc, not ap_malloc: this iterator holds the object it walks, and an
    ; object holding its own iterator is a cycle only the collector can break.
    mov rdi, ITER_OBJ_SIZE
    lea rsi, [rel seq_iter_type]
    extern gc_alloc
    call gc_alloc
    INCREF rbx
    mov [rax + IT_FIELD1], rbx     ; it_obj
    mov qword [rax + IT_FIELD2], 0 ; it_index = 0
    push rax
    mov rdi, rax
    extern gc_track
    call gc_track
    pop rax

    pop rbx
    leave
    ret
END_FUNC seq_iter_new

;; ============================================================================
;; The two-argument iter(): iter(callable, sentinel).
;;
;; It did not exist -- `iter(f, 0)` was "iter() takes exactly one argument" --
;; and it is the ordinary way to read a file or a queue until a marker turns
;; up: `for chunk in iter(lambda: f.read(4096), b"")`.
;;
;; Layout: +16 the callable (owned), +24 the sentinel (an owned Value).
;; ============================================================================
CI_CALL equ IT_FIELD1
CI_SENT equ IT_FIELD2

;; callable_iter_new(rdi = the callable, rsi = the sentinel Value) -> the iterator
DEF_FUNC callable_iter_new
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rdi, ITER_OBJ_SIZE
    lea rsi, [rel callable_iter_type]
    call gc_alloc
    INCREF rbx
    mov [rax + CI_CALL], rbx
    mov rdi, r12
    INCREF_V rdi, rcx
    mov [rax + CI_SENT], r12
    push rax
    mov rdi, rax
    call gc_track
    pop rax
    pop r12
    pop rbx
    leave
    ret
END_FUNC callable_iter_new

;; callable_iter_iternext(self) -> rax = a Value, or 0 for exhaustion
;;
;; Exhaustion is a NULL return with no exception pending, which is what every
;; other builtin iterator here does; a real error returns NULL with one set.
;; RAISE is wrong either way -- it tail-jumps into the unwinder, and a builtin
;; has no Python frame of its own for it to stop at.
CIN_SELF  equ 8
CIN_RES   equ 16
CIN_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC_LOCAL callable_iter_iternext, CIN_FRAME
    mov [rbp - CIN_SELF], rdi
    mov rdi, [rdi + CI_CALL]
    test rdi, rdi
    jz .cin_exhausted           ; already finished; stay finished

    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .cin_not_callable
    xor esi, esi                ; no arguments
    xor edx, edx
    call rax
    test rax, rax
    jz .cin_failed              ; the callable raised; hand it on
    mov [rbp - CIN_RES], rax

    ; CPython compares with ==, not identity, and a comparison that itself
    ; raises propagates.
    mov rdi, rax
    mov rax, [rbp - CIN_SELF]
    mov rsi, [rax + CI_SENT]
    mov edx, PY_EQ
    call obj_richcompare_bool
    cmp eax, -1
    je .cin_cmp_failed
    test eax, eax
    jnz .cin_reached

    mov rax, [rbp - CIN_RES]    ; tp_iternext hands back a Value, not a pair
    leave
    ret

.cin_reached:
    ; The sentinel came back.  Drop the value, release the callable so a
    ; second next() cannot call it again, and report exhaustion.
    mov rdi, [rbp - CIN_RES]
    DECREF_V rdi, rsi
    mov rax, [rbp - CIN_SELF]
    mov rdi, [rax + CI_CALL]
    mov qword [rax + CI_CALL], 0
    test rdi, rdi
    jz .cin_exhausted
    call obj_decref
.cin_exhausted:
    ; A builtin tp_iternext reports clean exhaustion as NULL with NOTHING
    ; pending -- setting StopIteration here made `list(it)` propagate it
    ; instead of stopping.  next() is what turns the NULL into the exception.
    xor eax, eax
    xor edx, edx
    leave
    ret

.cin_cmp_failed:
    mov rdi, [rbp - CIN_RES]
    DECREF_V rdi, rsi
.cin_failed:
    xor eax, eax
    xor edx, edx
    leave
    ret

.cin_not_callable:
    SET_EXC exc_TypeError_type, "iter(v, w): v must be callable"
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC callable_iter_iternext

DEF_FUNC_LOCAL callable_iter_traverse, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + CI_CALL]
    VISIT_PTR rdi
    mov rdi, [rbx + CI_SENT]
    VISIT_V rdi, rcx
    pop rbx
    leave
    ret
END_FUNC callable_iter_traverse

DEF_FUNC_LOCAL callable_iter_clear, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + CI_CALL]
    mov qword [rbx + CI_CALL], 0
    test rdi, rdi
    jz .cic_sent
    call obj_decref
.cic_sent:
    mov rdi, [rbx + CI_SENT]
    mov qword [rbx + CI_SENT], 0
    XDECREF_V rdi, rcx
    pop rbx
    leave
    ret
END_FUNC callable_iter_clear

DEF_FUNC_LOCAL callable_iter_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    call callable_iter_clear    ; drops the callable and the sentinel
    mov rdi, rbx
    extern gc_dealloc
    call gc_dealloc             ; untracks AND frees; ap_free here too was a
                                ; double free
    pop rbx
    leave
    ret
END_FUNC callable_iter_dealloc

;; seq_iter_iternext(self) -> (rax=payload, edx=tag) or NULL
;; Calls self.it_obj.__getitem__(self.it_index); catches IndexError as exhaustion.
SI_EXC   equ 8
SI_FRAME equ 24            ; + 1 push = 32, 16-aligned

DEF_FUNC_LOCAL seq_iter_iternext, SI_FRAME
    push rbx
    mov rbx, rdi                   ; self

    ; Snapshot first.  current_exception is also the exception BEING HANDLED,
    ; so inside an `except` block this saw one on the very first item, decided
    ; it was not an IndexError, and reported exhaustion: sorted(seq) answered
    ; [] for an object with __getitem__ and no __iter__.  And when the handled
    ; exception WAS an IndexError, the clear below threw it away.
    DUNDER_EXC_SAVE [rbp - SI_EXC]

    ; Call __getitem__(it_obj, it_index)
    mov rdi, [rbx + IT_FIELD1]     ; obj
    mov rsi, [rbx + IT_FIELD2]     ; index (raw i64 = SmallInt payload)
    extern dunder_getitem
    lea rdx, [rel dunder_getitem]
    mov ecx, TAG_SMALLINT          ; other_tag for index
    extern dunder_call_2
    call dunder_call_2
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jz .si_check_exc               ; NULL — check for IndexError

    ; Got a value — increment index
    inc qword [rbx + IT_FIELD2]
    V_PACK rax, rdx
    pop rbx
    leave
    ret

.si_check_exc:
    ; Only an exception THIS call raised counts; anything that was already
    ; pending belongs to whoever is handling it.
    DUNDER_RAISED [rbp - SI_EXC], .si_raised
    jmp .si_exhausted
.si_raised:
    mov rax, [gs:ThreadState.current_exception]
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
    ; Put back what was being handled when this call started, with a
    ; reference of its own: installing the IndexError released the global's
    ; old one, so storing the bare pointer back would leave the global
    ; holding a reference nobody owns.
    push rax
    mov rdi, [rbp - SI_EXC]
    test rdi, rdi
    jz .si_no_restore
    call obj_incref
.si_no_restore:
    mov rcx, [rbp - SI_EXC]
    mov [gs:ThreadState.current_exception], rcx
    pop rdi
    call obj_decref
.si_exhausted:
    RET_NULL
    pop rbx
    leave
    ret
END_FUNC seq_iter_iternext

;; seq_iter_dealloc(self)
DEF_FUNC_LOCAL seq_iter_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; DECREF the source object
    mov rdi, [rbx + IT_FIELD1]
    call obj_decref

    ; Free self
    mov rdi, rbx
    extern gc_dealloc
    call gc_dealloc

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
callable_iter_name:  db "callable_iterator", 0

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
    dq TYPE_FLAG_HAVE_GC        ; tp_flags
    dq 0                        ; tp_bases
    dq iter_traverse_one                        ; tp_traverse
    dq iter_clear_one                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

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
    dq TYPE_FLAG_HAVE_GC        ; tp_flags
    dq 0                        ; tp_bases
    dq iters_array_traverse                        ; tp_traverse
    dq iters_array_clear                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

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
    dq TYPE_FLAG_HAVE_GC        ; tp_flags
    dq 0                        ; tp_bases
    dq map_traverse                        ; tp_traverse
    dq map_clear                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

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
    dq TYPE_FLAG_HAVE_GC        ; tp_flags
    dq 0                        ; tp_bases
    dq filter_traverse                        ; tp_traverse
    dq filter_clear                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; Sequence iterator type (__getitem__ protocol)
align 8
align 8
global callable_iter_type
callable_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq callable_iter_name       ; tp_name
    dq ITER_OBJ_SIZE            ; tp_basicsize
    dq callable_iter_dealloc    ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq itertools_iter_self      ; tp_iter
    dq callable_iter_iternext   ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC        ; tp_flags
    dq 0                        ; tp_bases
    dq callable_iter_traverse   ; tp_traverse
    dq callable_iter_clear      ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

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
    dq TYPE_FLAG_HAVE_GC                        ; tp_flags
    dq 0                        ; tp_bases
    dq iter_traverse_one                        ; tp_traverse
    dq iter_clear_one                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

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
    dq TYPE_FLAG_HAVE_GC        ; tp_flags
    dq 0                        ; tp_bases
    dq iter_traverse_one                        ; tp_traverse
    dq iter_clear_one                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

