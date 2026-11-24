; slice.asm - Slice type implementation
;
; PySliceObject layout (from object.inc):
;   +0  ob_refcnt (8 bytes)
;   +8  ob_type   (8 bytes)
;   +16 start     (8 bytes: PyObject*)
;   +24 stop      (8 bytes: PyObject*)
;   +32 step      (8 bytes: PyObject*)
;   Total: 40 bytes

%include "macros.inc"
%include "object.inc"

extern set_exception
extern eval_exception_unwind
extern int_promote_mpz
extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_untrack
extern ap_free
extern obj_incref
extern obj_dealloc
extern obj_decref
extern str_from_cstr
extern none_singleton
extern bool_type
extern exc_ValueError_type
extern int_type
extern type_type
extern raise_exception
extern exc_TypeError_type
extern obj_as_index_clamped_msg
extern ap_strcmp

;; ============================================================================
;; slice_new(PyObject *start, PyObject *stop, PyObject *step) -> PySliceObject*
;; INCREFs all three args. Caller should pass none_singleton for missing values.
;; ============================================================================
DEF_FUNC slice_new, 8            ; 5 pushes, so rsp is 16-aligned
    ; rdi=start, rsi=stop, rdx=step, ecx=start_tag, r8d=stop_tag, r9d=step_tag
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi           ; start
    mov r12, rsi           ; stop
    mov r13, rdx           ; step
    mov r14d, ecx          ; start_tag
    mov r15d, r8d          ; stop_tag
    push r9                ; save step_tag across malloc

    ; Check slice pool first
    mov rax, [rel slice_pool_head]
    test rax, rax
    jz .alloc_fresh
    ; Pop from pool: reuse ob_refcnt slot as next-link
    mov rcx, [rax + PyObject.ob_refcnt]
    mov [rel slice_pool_head], rcx
    dec dword [rel slice_pool_count]
    mov qword [rax + PyObject.ob_refcnt], 1  ; reinit refcount
    jmp .fill_fields

.alloc_fresh:
    mov edi, PySliceObject_size
    lea rsi, [rel slice_type]
    call gc_alloc

.fill_fields:
    pop r9                  ; step_tag
    ; ob_refcnt=1, ob_type set by gc_alloc (or still set from pool)
    push rax

    ; INCREF each while its tag is still around, then pack into a Value
    INCREF_VAL rbx, r14
    INCREF_VAL r12, r15
    INCREF_VAL r13, r9
    V_PACK rbx, r14
    V_PACK r12, r15
    V_PACK r13, r9
    mov rax, [rsp]
    mov [rax + PySliceObject.start], rbx
    mov [rax + PySliceObject.stop], r12
    mov [rax + PySliceObject.step], r13

    ; Track in GC
    mov rdi, [rsp]          ; obj ptr saved on stack
    call gc_track
    pop rax

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC slice_new

;; ============================================================================
;; slice_dealloc(PySliceObject *self)
;; ============================================================================
SLICE_POOL_MAX equ 16

DEF_FUNC slice_dealloc, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PySliceObject.start]
    DECREF_V rdi, rsi
    mov rdi, [rbx + PySliceObject.stop]
    DECREF_V rdi, rsi
    mov rdi, [rbx + PySliceObject.step]
    DECREF_V rdi, rsi

    ; Untrack from GC
    mov rdi, rbx
    call gc_untrack

    ; Try to push to pool
    cmp dword [rel slice_pool_count], SLICE_POOL_MAX
    jge .free_it
    ; Push to pool: reuse ob_refcnt as next-pointer
    mov rcx, [rel slice_pool_head]
    mov [rbx + PyObject.ob_refcnt], rcx
    mov [rel slice_pool_head], rbx
    inc dword [rel slice_pool_count]
    pop rbx
    leave
    ret

.free_it:
    lea rdi, [rbx - GC_HEAD_SIZE]
    call ap_free
    pop rbx
    leave
    ret
END_FUNC slice_dealloc

;; ============================================================================
;; slice_richcompare(rdi = left Value, rsi = right Value, edx = op) -> Value
;;
;; CPython compares two slices as the tuple (start, stop, step), so
;; slice(1) < slice(2) is True.  slice_type.tp_richcompare was 0, which sent
;; every comparison to op_compare_op's identity path: ordering was a
;; TypeError, and equality was identity, so slice(1,2,3) == slice(1,2,3) was
;; False as well -- bugs.md recorded that half as working.
;;
;; A NULL Value declines, the way every other tp_richcompare here does.
;; ============================================================================
SLC_T1    equ 8
SLC_T2    equ 16
SLC_OP    equ 24
SLC_FRAME equ 40            ; + 1 push = 48, 16-aligned

DEF_FUNC slice_richcompare, SLC_FRAME
    push rbx
    mov [rbp - SLC_OP], rdx

    ; Both operands must be slices; anything else declines, so the protocol
    ; can try the other side and then report the pair.
    V_TEST_PTR rdi, rax
    ja .slc_decline
    V_TEST_PTR rsi, rax
    ja .slc_decline
    test rdi, rdi
    jz .slc_decline
    test rsi, rsi
    jz .slc_decline
    lea rcx, [rel slice_type]
    cmp [rdi + PyObject.ob_type], rcx
    jne .slc_decline
    cmp [rsi + PyObject.ob_type], rcx
    jne .slc_decline

    mov rbx, rsi
    call .slc_make_tuple            ; rdi = the left slice
    mov [rbp - SLC_T1], rax
    mov rdi, rbx
    call .slc_make_tuple
    mov [rbp - SLC_T2], rax

    mov rdi, [rbp - SLC_T1]
    mov rsi, [rbp - SLC_T2]
    mov rdx, [rbp - SLC_OP]
    extern tuple_richcompare
    call tuple_richcompare    ; err: its 0, declined or raised, is this slot's own answer
    mov rbx, rax
    mov rdi, [rbp - SLC_T1]
    call obj_decref
    mov rdi, [rbp - SLC_T2]
    call obj_decref
    mov rax, rbx
    pop rbx
    leave
    ret

.slc_decline:
    xor eax, eax                    ; a NULL Value = NotImplemented
    pop rbx
    leave
    ret

;; .slc_make_tuple(rdi = a slice) -> rax = a new (start, stop, step) tuple
.slc_make_tuple:
    push rdi
    mov edi, 3
    extern tuple_new
    call tuple_new
    pop rdi
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rdi + PySliceObject.start]
    mov [rcx], rdx
    INCREF_V rdx, rsi
    mov rdx, [rdi + PySliceObject.stop]
    mov [rcx + 8], rdx
    INCREF_V rdx, rsi
    mov rdx, [rdi + PySliceObject.step]
    mov [rcx + 16], rdx
    INCREF_V rdx, rsi
    ret
END_FUNC slice_richcompare

;; ============================================================================
;; slice_hash(rdi = self, edx = tag) -> rax = the hash
;;
;; A slice has been hashable since 3.12, and hashes as its (start, stop, step)
;; tuple does -- which is also what it compares as, so equal slices hash equal.
;; ============================================================================
DEF_FUNC slice_hash
    call slice_richcompare.slc_make_tuple
    push rax
    mov rdi, rax
    extern obj_hash
    call obj_hash
    pop rdi
    push rax
    call obj_decref
    pop rax
    leave
    ret
END_FUNC slice_hash

;; ============================================================================
;; slice_repr(PySliceObject *self) -> PyStrObject*
;; ============================================================================
DEF_FUNC slice_repr, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    ; CPython prints all three fields, always: slice(1) is slice(None, 1,
    ; None).  This answered the fixed string "slice(...)", so no slice ever
    ; printed its own contents.  The tuple that tp_richcompare and tp_hash
    ; already build is exactly the text wanted -- repr((None, 1, None)) is
    ; "(None, 1, None)" -- so the repr is the word and that tuple.
    call slice_richcompare.slc_make_tuple
    mov rbx, rax
    mov rdi, rbx
    extern obj_repr
    call obj_repr
    V_UNPACK rax, rdx
    test rax, rax
    jz .sr_fail
    mov r12, rax                    ; "(start, stop, step)"

    lea rdi, [rel slice_repr_str]
    call str_from_cstr
    mov r13, rax                    ; "slice"

    mov rdi, r13
    mov rsi, r12
    extern str_concat
    call str_concat           ; err: the repr of a tuple is a str
    V_UNPACK rax, rdx

    push rax
    mov rdi, r13
    call obj_decref
    mov rdi, r12
    call obj_decref
    mov rdi, rbx
    call obj_decref
    pop rax

    ; obj_str hands its caller (rax, rdx), and builtin_print reads that tag to
    ; decide whether there is anything to print.  The decrefs above are calls,
    ; so the tag has to be set after them, not before.
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sr_fail:
    mov rdi, rbx
    call obj_decref
    xor eax, eax
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC slice_repr

;; ============================================================================
;; pyobj_to_i64(PyObject *obj) -> int64 in rax
;; Converts SmallInt or GMP int to int64. For None, returns special sentinel.
;; Fails: -1
;; ============================================================================
DEF_FUNC_BARE pyobj_to_i64
    ; rdi = payload, esi = tag
    cmp esi, TAG_SMALLINT
    je .smallint
    ; Check for None: inline TAG_NONE or pointer-to-none_singleton
    lea rax, [rel none_singleton]
    cmp rdi, rax
    je .is_none
    ; Everything below treats the payload as a PyIntObject, so it has to be
    ; one: a float's payload is raw IEEE bits, and "abc"[::1.5] handed those
    ; to INT_NEED_MPZ.
    cmp esi, TAG_PTR
    jne .not_an_index
    ; An int subclass WRAPS an int rather than being one, so what follows --
    ; INT_NEED_MPZ, which INITIALISES the mpz in place -- would write over the
    ; wrapper's own header.  `a[N(1):]` read the bound as 0 and left the
    ; object with a NULL type, so the next use of it crashed somewhere else.
    extern int_unwrap
    push rbp
    mov rbp, rsp
    mov edx, esi
    call int_unwrap
    mov esi, edx
    pop rbp
    cmp esi, TAG_SMALLINT
    je .smallint
    mov rax, [rdi + PyObject.ob_type]
    REQUIRE_INT_TYPE rax, rcx, .not_an_index
    ; GMP int: check if it fits in i64, clamp if not
    push rbp
    mov rbp, rsp
    push rdi                     ; save obj ptr
    INT_NEED_MPZ rdi
    lea rdi, [rdi + PyIntObject.mpz]
    extern __gmpz_fits_slong_p
    call __gmpz_fits_slong_p wrt ..plt
    test eax, eax
    jz .gmp_clamp               ; doesn't fit → clamp
    pop rdi                      ; restore obj ptr
    INT_NEED_MPZ rdi
    lea rdi, [rdi + PyIntObject.mpz]
    extern __gmpz_get_si
    call __gmpz_get_si wrt ..plt
    leave
    ret
.gmp_clamp:
    ; Value too large for i64 — clamp based on sign
    pop rdi                      ; restore obj ptr
    INT_NEED_MPZ rdi
    lea rdi, [rdi + PyIntObject.mpz]
    extern __gmpz_cmp_si
    xor esi, esi               ; compare with 0
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    js .gmp_clamp_neg
    mov rax, 0x7ffffffffffffffe  ; positive: clamp to near-maxsize (not sentinel)
    leave
    ret
.gmp_clamp_neg:
    mov rax, 0x8000000000000001  ; negative: clamp to near-minsize
    leave
    ret
.smallint:
    mov rax, rdi
    ret
.is_none:
    mov rax, 0x7fffffffffffffff  ; sentinel for "not specified"
    ret
.not_an_index:
    ; Not an int, but __index__ makes an object usable as a slice bound --
    ; numpy's integers, IntEnum members, and the `X` whose __index__ has a
    ; side effect that CPython's own test_mmap builds.  obj_as_index_clamped
    ; is the single funnel for that protocol, and clamping is already what a
    ; bound wants; only the wording is this caller's own.
    mov edx, esi
    lea rsi, [rel slice_index_msg]
    sub rsp, 8                  ; a call, so the refusal can be seen
    call obj_as_index_clamped_msg   ; err: its -1 is this function's own
    add rsp, 8
    ret
END_FUNC pyobj_to_i64

section .rodata
slice_index_msg:
    db "slice indices must be integers or None or have an __index__ method", 0
section .text

;; ============================================================================
;; slice_indices(PySliceObject *slice, int64 length)
;;   -> (start, stop, step) in rax, rdx, rcx
;; slice_indices_live(PySliceObject *slice, int64 *length)
;;   -> the same, reading the length AFTER the bounds are resolved
;; Fails: -1
;;
;; A start of -1 is an answer (a downward walk over nothing), so a failure is
;; -1 in rax AND an exception pending: a bound that is not an index, a bound
;; whose __index__ raised, or a step of zero.
;;
;; Resolves None, handles negatives, clamps to bounds -- CPython's
;; PySlice_Unpack followed by PySlice_AdjustIndices, and the order of those
;; two is the point.
;;
;; A bound may be any object with __index__, so resolving one RUNS PYTHON
;; CODE, and that code can empty the very container being sliced.  CPython
;; splits the work for exactly this reason: Unpack converts, then the caller
;; reads the length, then AdjustIndices clamps.  This function does all three,
;; so it has to convert all three bounds before it looks at the length --
;; which the `_live` entry point then loads through a pointer to the
;; container's own size field.
;;
;; The plain entry point is for the immutable sequences and for
;; slice.indices(n), where the length is a number and cannot change.
;;
;; A caller that took the `_live` form must also RE-READ its data pointer
;; afterwards: a list that shrank has been reallocated, and the pointer it
;; held is the old one.  CPython's issue #27863 is this same shape, and
;; `e[0:10:X()] = []` with an X whose __index__ empties e is the test that
;; found it here.
;; ============================================================================
SLI_LENP  equ 8             ; the live length pointer, or 0
SLI_SNONE equ 16            ; start was None
SLI_TNONE equ 24            ; stop was None
SLI_FRAME equ 40            ; + 5 pushes = 80, 16-aligned
DEF_FUNC slice_indices, SLI_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r14, rsi                ; the length, already known
    mov qword [rbp - SLI_LENP], 0
    jmp sli_body
END_FUNC slice_indices


;; ============================================================================
;; slice_indices_live(PySliceObject *slice, int64 *length)
;;   -> (start, stop, step) in rax, rdx, rcx
;; Fails: -1
;;
;; The same body, sharing it from `sli_body`: the only difference is that the
;; length is loaded through the pointer once every bound is resolved.  See the
;; block above slice_indices for why that matters.
;; ============================================================================
global slice_indices_live
DEF_FUNC slice_indices_live, SLI_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov [rbp - SLI_LENP], rsi   ; read it once the bounds are resolved
    xor r14d, r14d
sli_body:
    mov rbx, rdi                ; slice

    extern none_singleton

    ; --- convert, which is where user code may run -------------------------
    ; step (default 1)
    mov rdi, [rbx + PySliceObject.step]
    IS_NONE rdi, rcx
    je .step_is_none
    V_UNPACK rdi, rsi
    call pyobj_to_i64
    ERR_M1 .sli_fail
    jmp .have_step
.step_is_none:
    mov eax, 1
.have_step:
    ; A zero step reaches `neg rcx` and then `div rcx` in every caller's
    ; slice loop: "abc"[::0] and [10,11][10:0:0] were SIGFPE.  One check
    ; here covers all six callers.
    test rax, rax
    jz .step_is_zero
    mov r15, rax                ; r15 = step

    ; start
    mov qword [rbp - SLI_SNONE], 0
    mov rdi, [rbx + PySliceObject.start]
    IS_NONE rdi, rcx
    je .start_is_none
    V_UNPACK rdi, rsi
    call pyobj_to_i64
    ERR_M1 .sli_fail
    mov r12, rax
    jmp .have_start
.start_is_none:
    mov qword [rbp - SLI_SNONE], 1
    xor r12d, r12d
.have_start:

    ; stop
    mov qword [rbp - SLI_TNONE], 0
    mov rdi, [rbx + PySliceObject.stop]
    IS_NONE rdi, rcx
    je .stop_is_none
    V_UNPACK rdi, rsi
    call pyobj_to_i64
    ERR_M1 .sli_fail
    mov r13, rax
    jmp .have_stop
.stop_is_none:
    mov qword [rbp - SLI_TNONE], 1
    xor r13d, r13d
.have_stop:

    ; --- the length, now that nothing more can run -------------------------
    mov rcx, [rbp - SLI_LENP]
    test rcx, rcx
    jz .have_length
    mov r14, [rcx]
.have_length:

    ; --- clamp -------------------------------------------------------------
    ; start: default 0 for a positive step, length - 1 for a negative one
    cmp qword [rbp - SLI_SNONE], 0
    je .start_given
    test r15, r15
    js .start_default_neg
    xor r12d, r12d
    jmp .start_done
.start_default_neg:
    mov r12, r14
    dec r12
    jmp .start_done
.start_given:
    test r12, r12
    jns .start_high
    add r12, r14                ; start += length
    test r12, r12
    jns .start_high
    ; Still below the start of the sequence.  The lower bound is 0 for a
    ; positive step and -1 for a negative one -- -1 is "one before the first
    ; index", which is where a downward walk stops.
    xor r12d, r12d
    test r15, r15
    jns .start_done
    mov r12, -1
    jmp .start_done
.start_high:
    cmp r12, r14
    jl .start_done
    ; At or past the end: length for a positive step, length - 1 for a
    ; negative one.
    mov r12, r14
    test r15, r15
    jns .start_done
    dec r12
.start_done:

    ; stop: default length for a positive step, -1 for a negative one
    cmp qword [rbp - SLI_TNONE], 0
    je .stop_given
    test r15, r15
    js .stop_default_neg
    mov r13, r14
    jmp .stop_done
.stop_default_neg:
    mov r13, -1
    jmp .stop_done
.stop_given:
    test r13, r13
    jns .stop_high
    add r13, r14
    test r13, r13
    jns .stop_high
    xor r13d, r13d
    test r15, r15
    jns .stop_done
    mov r13, -1
    jmp .stop_done
.stop_high:
    cmp r13, r14
    jl .stop_done
    mov r13, r14
    test r15, r15
    jns .stop_done
    dec r13
.stop_done:

    mov rax, r12
    mov rdx, r13
    mov rcx, r15

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.step_is_zero:
    SET_EXC exc_ValueError_type, "slice step cannot be zero"
.sli_fail:
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC slice_indices_live

;; ============================================================================
;; slice_getattr(PySliceObject *self, PyObject *name) -> (rax, edx) fat value
;; Returns start, stop, step attributes.
;; rdi = self, rsi = name (PyStrObject*)
;; ============================================================================
DEF_FUNC slice_getattr
    push rbx
    push r12
    mov rbx, rdi               ; rbx = self (slice object)
    mov r12, rsi               ; r12 = name string

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "start"
    call ap_strcmp
    test eax, eax
    jz .sg_start

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "stop"
    call ap_strcmp
    test eax, eax
    jz .sg_stop

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "step"
    call ap_strcmp
    test eax, eax
    jz .sg_step

    ; Unknown attribute.  Every other tp_getattr signals "not found" with a
    ; NULL return and lets the caller decide; raising here meant
    ; hasattr(slice(1,2), "indices") propagated the AttributeError instead of
    ; answering False, and getattr(s, "x", default) could not reach its
    ; default -- raise_exception never comes back.
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.sg_start:
    mov rax, [rbx + PySliceObject.start]
    INCREF_V rax, rdx
    V_UNPACK rax, rdx
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.sg_stop:
    mov rax, [rbx + PySliceObject.stop]
    INCREF_V rax, rdx
    V_UNPACK rax, rdx
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.sg_step:
    mov rax, [rbx + PySliceObject.step]
    INCREF_V rax, rdx
    V_UNPACK rax, rdx
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC slice_getattr

;; ============================================================================
;; slice.indices(length) -> (start, stop, step)
;;
;; The method did not exist -- only the internal slice_indices behind the
;; subscript operators did -- so `slice(1, 10, 2).indices(20)` was an
;; AttributeError.  It is how anything implementing __getitem__ for slices in
;; Python resolves one, and _pyio and the ABCs both do that.
;; Fails: 0
;; ============================================================================
SMI_SELF  equ 8
SMI_START equ 16
SMI_STOP  equ 24
SMI_STEP  equ 32
SMI_FRAME equ 48            ; + 0 pushes = 48

DEF_FUNC slice_method_indices, SMI_FRAME
    cmp rsi, 2
    jne .smi_arity
    mov rax, [rdi]
    mov [rbp - SMI_SELF], rax
    mov rdi, [rdi + 8]
    V_UNPACK rdi, rdx
    extern obj_as_index
    call obj_as_index
    ERR_M1 .smi_failed
    ; obj_as_index reports a non-integer by raising, and comes back 0 on the
    ; paths that do not.  A negative length is CPython's own check.
    test rax, rax
    js .smi_negative
    mov rsi, rax
    mov rdi, [rbp - SMI_SELF]
    call slice_indices          ; -> rax = start, rdx = stop, rcx = step
    ERR_M1 .smi_failed
    mov [rbp - SMI_START], rax
    mov [rbp - SMI_STOP], rdx
    mov [rbp - SMI_STEP], rcx

    mov edi, 3
    extern tuple_new
    call tuple_new
    test rax, rax
    jz .smi_failed
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbp - SMI_START]
    V_PACK_I64 rdx, rsi
    mov [rcx], rdx
    mov rdx, [rbp - SMI_STOP]
    V_PACK_I64 rdx, rsi
    mov [rcx + 8], rdx
    mov rdx, [rbp - SMI_STEP]
    V_PACK_I64 rdx, rsi
    mov [rcx + 16], rdx
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.smi_failed:
    xor eax, eax
    leave
    ret
.smi_negative:
    FAIL exc_ValueError_type, "length should not be negative", .smi_failed
.smi_arity:
    dec rsi                     ; self does not count
    lea rdi, [rel smi_arity_msg]
    CSTRING rdx, " given)"
    extern set_type_error_counted
    call set_type_error_counted
    jmp .smi_failed

section .rodata
smi_arity_msg: db "slice.indices() takes exactly one argument (", 0
section .text
END_FUNC slice_method_indices

;; The three fields as getset descriptors, so they are on the TYPE as well as
;; on the instance.  slice_getattr answers them for an instance and is faster,
;; but `hasattr(slice, "start")` and dir(slice) go through the type's dict.
%macro DEF_SLICE_GETTER 1
DEF_FUNC slice_get_%1
    mov rax, [rdi + PySliceObject.%1]
    INCREF_V rax, rdx
    leave
    ret
END_FUNC slice_get_%1
%endmacro
DEF_SLICE_GETTER start
DEF_SLICE_GETTER stop
DEF_SLICE_GETTER step

;; ============================================================================
;; slice_type_call(self, args, nargs) -> (rax, edx) fat value
;; slice(stop), slice(start, stop), slice(start, stop, step)
;; rdi = self (slice_type), rsi = args (16-byte fat slots), rdx = nargs
;; Fails: 0
;; ============================================================================
DEF_FUNC slice_type_call, 8            ; 1 push, so rsp is 16-aligned
    push rbx

    mov rbx, rsi               ; rbx = args ptr

    cmp rdx, 1
    je .stc_one
    cmp rdx, 2
    je .stc_two
    cmp rdx, 3
    je .stc_three
    test rdx, rdx
    jz .stc_too_few
    jmp .stc_error

.stc_one:
    ; slice(stop) → slice(None, stop, None)
    lea rdi, [rel none_singleton]  ; start = None
    mov ecx, TAG_PTR               ; start_tag
    mov rsi, [rbx]                 ; args[0] = stop
    V_UNPACK rsi, r8
    lea rdx, [rel none_singleton]  ; step = None
    mov r9d, TAG_PTR               ; step_tag
    call slice_new
    mov edx, TAG_PTR
    jmp .stc_done

.stc_two:
    ; slice(start, stop) → slice(start, stop, None)
    mov rdi, [rbx]             ; args[0] = start
    V_UNPACK rdi, rcx
    mov rsi, [rbx + 8]         ; args[1] = stop
    V_UNPACK rsi, r8
    lea rdx, [rel none_singleton]  ; step = None
    mov r9d, TAG_PTR           ; step_tag
    call slice_new
    mov edx, TAG_PTR
    jmp .stc_done

.stc_three:
    ; slice(start, stop, step)
    mov rdi, [rbx]             ; args[0] = start
    V_UNPACK rdi, rcx
    mov rsi, [rbx + 8]         ; args[1] = stop
    V_UNPACK rsi, r8
    mov rdx, [rbx + 16]       ; step payload
    V_UNPACK rdx, r9       ; args[2]
    call slice_new
    mov edx, TAG_PTR
    jmp .stc_done

.stc_done:
    pop rbx
    leave
    ret

.stc_too_few:
    xor esi, esi
    CSTRING rdi, "slice expected at least 1 argument, got "
    xor edx, edx
    call set_type_error_counted
    RET_NULL
    jmp .stc_done

.stc_error:
    mov rsi, rdx
    CSTRING rdi, "slice expected at most 3 arguments, got "
    xor edx, edx
    call set_type_error_counted
    RET_NULL
    jmp .stc_done
END_FUNC slice_type_call

;; ============================================================================
;; Data
;; ============================================================================
section .data

slice_name_str: db "slice", 0
slice_repr_str: db "slice", 0

; Slice object pool (freelist)
align 8
slice_pool_head:  dq 0       ; freelist head (singly-linked via ob_refcnt slot)
slice_pool_count: dd 0       ; current count
                  dd 0       ; padding

align 8
global slice_type
slice_type:
    dq 1                      ; ob_refcnt (immortal)
    dq type_type              ; ob_type
    dq slice_name_str         ; tp_name
    dq PySliceObject_size     ; tp_basicsize
    dq slice_dealloc          ; tp_dealloc
    dq slice_repr             ; tp_repr
    dq slice_repr             ; tp_str
    dq slice_hash             ; tp_hash
    dq 0                ; tp_call  (instances are not callable)
    dq slice_getattr          ; tp_getattr
    dq 0                      ; tp_setattr
    dq slice_richcompare      ; tp_richcompare
    dq 0                      ; tp_iter
    dq 0                      ; tp_iternext
    dq 0                      ; tp_init
    dq slice_type_call      ; tp_new  (constructor)
    dq 0                      ; tp_as_number
    dq 0                      ; tp_as_sequence
    dq 0                      ; tp_as_mapping
    dq 0                      ; tp_base
    dq 0                      ; tp_dict
    dq 0                      ; tp_mro
    dq TYPE_FLAG_HAVE_GC | TYPE_FLAG_FINAL  ; tp_flags -- no Py_TPFLAGS_BASETYPE
    dq 0                      ; tp_bases
    dq slice_traverse                        ; tp_traverse
    dq slice_clear_gc                        ; tp_clear
    dq 0           ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

section .text

;; ============================================================================
;; GC traverse and clear.  These lived in gc.asm, which left the collector
;; holding the reference graph of every type in the system; a type's own
;; file is the only place that knows which of its fields are owned.
;; ============================================================================

;; ============================================================================
;; ---- slice_traverse / slice_clear ----
;; ============================================================================
DEF_FUNC slice_traverse, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PySliceObject.start]
    VISIT_V rdi, rsi
    mov rdi, [rbx + PySliceObject.stop]
    VISIT_V rdi, rsi
    mov rdi, [rbx + PySliceObject.step]
    VISIT_V rdi, rsi

    pop rbx
    leave
    ret
END_FUNC slice_traverse

DEF_FUNC slice_clear_gc, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PySliceObject.start]
    mov qword [rbx + PySliceObject.start], 0
    DECREF_V rdi, rsi

    mov rdi, [rbx + PySliceObject.stop]
    mov qword [rbx + PySliceObject.stop], 0
    DECREF_V rdi, rsi

    mov rdi, [rbx + PySliceObject.step]
    mov qword [rbx + PySliceObject.step], 0
    DECREF_V rdi, rsi

    pop rbx
    leave
    ret
END_FUNC slice_clear_gc

extern new_from_slot

;; ============================================================================
;; slice_dunder_new(args, nargs) -> Value    -- slice.__new__
;;
;; slice keeps its constructor in tp_new and had no entry of its own in
;; tp_dict, so `slice.__new__` resolved along the MRO to object.__new__ and
;; was refused.  That is every `super().__new__(cls, ...)` in a subclass, and
;; every copy, deepcopy and pickle of one, since the reduce protocol
;; reconstructs through __new__.  The slot called is the OWNER's, so a Python
;; subclass defining __new__ does not re-enter itself.
;; ============================================================================
DEF_FUNC slice_dunder_new
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rel slice_type]
    call new_from_slot          ; err: its 0 is this __new__'s own
    leave
    ret
END_FUNC slice_dunder_new

