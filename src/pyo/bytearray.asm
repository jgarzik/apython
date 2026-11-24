; pyo/bytearray.asm - the bytearray type
;
; bytes and bytearray were one file of 178k, against CLAUDE.md's 100k limit
; for a hand-written one.  The seam is the one the file itself marked: a
; bytearray keeps its data OUT of line, in an allocation of its own that
; doubles as it fills, which is the half that grew -- append, extend, insert,
; the slice assignment, the resize and the export count that blocks one.

%include "macros.inc"
%include "object.inc"
%include "value.inc"
extern eval_exception_unwind
extern ap_memcmp
extern ap_memmove
extern ap_realloc
extern bytearray_mod
extern bytearray_range_msg
extern bytearray_repr
extern bytes_compare
extern bytes_like_ptr_len
extern byteslike_source
extern exc_BufferError_type
extern exc_IndexError_type
extern exc_MemoryError_type
extern exc_OverflowError_type
extern exc_ValueError_type
extern hash_not_implemented
extern int_is_integer
extern memoryview_iter_next
extern none_singleton
extern obj_as_index
extern obj_as_index_seq
extern seq_repeat_check_count
extern set_exception
extern slice_indices
extern slice_indices_live
extern slice_type
section .text

extern ap_malloc
extern ap_free
extern ap_memcpy
extern gc_alloc
extern gc_track
extern type_type
extern raise_exception
extern exc_TypeError_type
extern obj_decref
extern v_int_bias

section .text

;; ============================================================================
;; bytearray_type_call(type, args, nargs) -> PyByteArrayObject*
;; Constructor: bytearray(bytes_obj)
;; ============================================================================
global bytearray_type_call
BA_TYPE  equ 8
BA_BUF   equ 16
BA_LEN   equ 24
BA_SIZE  equ 32
BA_FRAME equ 56            ; + 1 push = 64, 16-aligned
DEF_FUNC bytearray_type_call, BA_FRAME
    ; rdi=type, rsi=args, rdx=nargs
    push rbx
    mov [rbp - BA_TYPE], rdi           ; save type
    mov rdi, rsi
    mov rsi, rdx
    lea rdx, [rel bytearray_range_msg]
    lea rcx, [rel bytearray_enc_msg]
    lea r8, [rel bytearray_arity_msg]
    lea r9, [rel bytearray_conv_msg]
    call byteslike_source
    mov [rbp - BA_BUF], rax
    mov [rbp - BA_LEN], rdx

    ; The object is a fixed size now; the bytes live in their own allocation.
    ; The SIZE comes from the type, not from the struct: a subclass carries a
    ; dict word and its __slots__ past this layout, and allocating the base's
    ; size meant the first attribute write landed past the end of the block.
    mov rdx, [rbp - BA_TYPE]
    mov rdi, [rdx + PyTypeObject.tp_basicsize]
    cmp rdi, PyByteArrayObject_size
    jge .ba_size_ok
    mov edi, PyByteArrayObject_size
.ba_size_ok:
    mov [rbp - BA_SIZE], rdi
    test qword [rdx + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .ba_plain_alloc
    mov rsi, rdx
    call gc_alloc
    jmp .ba_alloc_done
.ba_plain_alloc:
    call ap_malloc
    mov qword [rax + PyByteArrayObject.ob_refcnt], 1
    mov rdx, [rbp - BA_TYPE]
    mov [rax + PyByteArrayObject.ob_type], rdx
.ba_alloc_done:
    mov rbx, rax
    mov qword [rbx + PyByteArrayObject.ob_size], 0
    mov qword [rbx + PyByteArrayObject.ob_cap], 0
    mov qword [rbx + PyByteArrayObject.ob_bytes], 0
    mov qword [rbx + PyByteArrayObject.ob_exports], 0
    ; Zero whatever the subclass added: a dict slot and any __slots__ values
    ; are read as Values by instance_dealloc and by the collector.
    mov rcx, [rbp - BA_SIZE]
    sub rcx, PyByteArrayObject_size
    jle .ba_no_tail
    lea rdi, [rbx + PyByteArrayObject_size]
    shr rcx, 3
    xor eax, eax
    rep stosq
.ba_no_tail:
    mov rdx, [rbp - BA_TYPE]
    inc qword [rdx + PyObject.ob_refcnt]

    mov rdi, rbx
    mov rsi, [rbp - BA_LEN]
    call bytearray_resize       ; allocates and NUL-terminates
    test eax, eax
    jz .ba_oom
    mov rcx, [rbp - BA_LEN]
    test rcx, rcx
    jz .ba_no_copy
    mov rdi, [rbx + PyByteArrayObject.ob_bytes]
    mov rsi, [rbp - BA_BUF]
    mov rdx, rcx
    call ap_memcpy
.ba_no_copy:
    mov rdi, [rbp - BA_BUF]
    test rdi, rdi
    jz .ba_no_free
    call ap_free
.ba_no_free:

    mov rdx, [rbp - BA_TYPE]
    test qword [rdx + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .ba_no_track
    mov rdi, rbx
    call gc_track
.ba_no_track:
    mov rax, rbx
    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.ba_oom:
    RAISE exc_MemoryError_type, "out of memory"
END_FUNC bytearray_type_call

;; ============================================================================
;; bytearray_resize(rdi = self, rsi = the new length) -> eax = 1 on success
;;
;; Grows the buffer to hold at least the new length, doubling so that n
;; appends cost O(n) copies in total, and never shrinks the allocation --
;; only ob_size moves down.  One byte past ob_size is always a NUL, so the
;; data pointer can be handed to anything expecting a C string.
;;
;; The bytes between the old and new length are NOT initialised; the caller
;; fills them.  bytearray(n) zeroes them itself.
;; ============================================================================
; Several bytearray mutators move bytes with ap_memmove BEFORE they call
; bytearray_resize, and call it only to settle ob_size afterwards.  For those
; the guard inside resize fires too late -- the view's bytes have already
; shifted under it -- so they ask up front instead.
%macro BA_REFUSE_IF_EXPORTED 1  ; %1 = register holding the bytearray
    cmp qword [%1 + PyByteArrayObject.ob_exports], 0
    jle %%ok
    RAISE exc_BufferError_type, "Existing exports of data: object cannot be re-sized"
%%ok:
%endmacro

BRS_SELF  equ 8
BRS_NEW   equ 16
BRS_CAP   equ 24
BRS_FRAME equ 32            ; + 0 pushes = 32

DEF_FUNC bytearray_resize, BRS_FRAME
    mov [rbp - BRS_SELF], rdi
    mov [rbp - BRS_NEW], rsi

    ; A live memoryview points straight into ob_bytes, so a length change
    ; leaves it dangling.  CPython refuses one; there was nothing here to
    ; refuse it with, and `m = memoryview(ba); ba.extend(b'x'*200)` corrupted
    ; the heap outright.  The same length is always allowed, which is what
    ; keeps reverse() and a same-size slice assignment legal with a view out.
    ;
    ; SET_EXC, not RAISE: bytearray_ass_subscript holds an owned source buffer
    ; and an owned temp bytearray across this call, and a RAISE abandons the C
    ; stack and both of them.  The 0 return already means failure and cannot
    ; be confused with anything -- its only other producer would be
    ; ap_realloc, which calls fatal_error rather than returning NULL.
    cmp rsi, [rdi + PyByteArrayObject.ob_size]
    je .brs_exports_ok
    cmp qword [rdi + PyByteArrayObject.ob_exports], 0
    jle .brs_exports_ok
    SET_EXC exc_BufferError_type, "Existing exports of data: object cannot be re-sized"
    xor eax, eax
    leave
    ret
.brs_exports_ok:
    mov rdi, [rbp - BRS_SELF]
    mov rsi, [rbp - BRS_NEW]
    mov rcx, [rdi + PyByteArrayObject.ob_cap]
    ; A fresh object has no buffer at all, and the NUL below has to go
    ; somewhere -- so allocate even when the requested length is 0.
    cmp qword [rdi + PyByteArrayObject.ob_bytes], 0
    je .brs_grow
    cmp rsi, rcx
    jbe .brs_fits
.brs_grow:

    ; Grow: at least double, and at least the requested size, with a floor
    ; so that a handful of appends does not reallocate every time.
    lea rax, [rcx + rcx]
    cmp rax, rsi
    jae .brs_have_cap
    mov rax, rsi
.brs_have_cap:
    cmp rax, 16
    jae .brs_cap_ok
    mov eax, 16
.brs_cap_ok:
    mov [rbp - BRS_CAP], rax
    mov rdi, [rdi + PyByteArrayObject.ob_bytes]
    lea rsi, [rax + 1]          ; + 1 for the NUL
    call ap_realloc             ; ap_realloc(NULL, n) is malloc(n)
    test rax, rax
    jz .brs_fail
    mov rdi, [rbp - BRS_SELF]
    mov [rdi + PyByteArrayObject.ob_bytes], rax
    mov rcx, [rbp - BRS_CAP]
    mov [rdi + PyByteArrayObject.ob_cap], rcx

.brs_fits:
    mov rdi, [rbp - BRS_SELF]
    mov rsi, [rbp - BRS_NEW]
    mov [rdi + PyByteArrayObject.ob_size], rsi
    mov rax, [rdi + PyByteArrayObject.ob_bytes]
    mov byte [rax + rsi], 0
    mov eax, 1
    leave
    ret

.brs_fail:
    xor eax, eax
    leave
    ret
END_FUNC bytearray_resize

;; ============================================================================
;; bytearray_data(rdi = self) -> rax = the buffer, never NULL
;;
;; An empty bytearray built by something other than the constructor could
;; have a NULL ob_bytes; every reader would then dereference it.  This hands
;; back a pointer to a static NUL instead.
;; ============================================================================
;; ============================================================================
;; bytearray_getitem(rdi = self, rsi = index) -> a Value, the byte as an int
;; sq_item, the counterpart of bytes_getitem.
;; ============================================================================
DEF_FUNC_BARE bytearray_getitem
    test rsi, rsi
    jns .bag_positive
    add rsi, [rdi + PyByteArrayObject.ob_size]
.bag_positive:
    cmp rsi, [rdi + PyByteArrayObject.ob_size]
    jge .bag_index_error
    test rsi, rsi
    jl .bag_index_error

    mov rax, [rdi + PyByteArrayObject.ob_bytes]
    test rax, rax
    jz .bag_index_error         ; empty: every index is out of range
    movzx eax, byte [rax + rsi]
    RET_TAG_SMALLINT
    V_PACK rax, rdx
    ret

.bag_index_error:
    RAISE exc_IndexError_type, "bytearray index out of range"
END_FUNC bytearray_getitem

DEF_FUNC_BARE bytearray_data
    mov rax, [rdi + PyByteArrayObject.ob_bytes]
    test rax, rax
    jnz .bad_have
    lea rax, [rel bytearray_empty_data]
.bad_have:
    ret
END_FUNC bytearray_data

;; ============================================================================
;; bytearray_index_arg(rdi = Value) -> rax = 0..255, or it raises
;;
;; The value side of `b[i] = v` and of append(): CPython takes any object with
;; __index__ and refuses anything outside a byte.
;; ============================================================================
DEF_FUNC bytearray_index_arg
    V_UNPACK rdi, rdx           ; obj_as_index takes the pair, not the Value
    call obj_as_index
    ERR_M1_JUMP
    test rax, rax
    jl .bia_range
    cmp rax, 255
    jg .bia_range
    leave
    ret
.bia_range:
    RAISE exc_ValueError_type, "byte must be in range(0, 256)"
END_FUNC bytearray_index_arg

;; ============================================================================
;; bytearray_new(rdi = data or NULL, rsi = length) -> rax = a new bytearray
;;
;; The one place a bytearray is built from a byte range.  Everything that
;; returns a new bytearray -- a slice, copy(), the concatenations -- goes
;; through it rather than repeating the allocate-resize-copy triple.
;; ============================================================================
BAN_SRC   equ 8
BAN_LEN   equ 16
BAN_OBJ   equ 24
BAN_FRAME equ 32            ; + 0 pushes = 32

DEF_FUNC bytearray_new, BAN_FRAME
    mov [rbp - BAN_SRC], rdi
    mov [rbp - BAN_LEN], rsi
    mov edi, PyByteArrayObject_size
    call ap_malloc
    test rax, rax
    jz .ban_fail
    mov [rbp - BAN_OBJ], rax
    mov qword [rax + PyByteArrayObject.ob_refcnt], 1
    lea rcx, [rel bytearray_type]
    mov [rax + PyByteArrayObject.ob_type], rcx
    mov qword [rax + PyByteArrayObject.ob_size], 0
    mov qword [rax + PyByteArrayObject.ob_cap], 0
    mov qword [rax + PyByteArrayObject.ob_bytes], 0
    mov qword [rax + PyByteArrayObject.ob_exports], 0
    inc qword [rcx + PyObject.ob_refcnt]

    mov rdi, rax
    mov rsi, [rbp - BAN_LEN]
    call bytearray_resize
    test eax, eax
    jz .ban_fail_free

    mov rdx, [rbp - BAN_LEN]
    test rdx, rdx
    jz .ban_done
    mov rsi, [rbp - BAN_SRC]
    test rsi, rsi
    jz .ban_done                ; no source: the caller fills it
    mov rax, [rbp - BAN_OBJ]
    mov rdi, [rax + PyByteArrayObject.ob_bytes]
    call ap_memcpy
.ban_done:
    mov rax, [rbp - BAN_OBJ]
    leave
    ret
.ban_fail_free:
    mov rdi, [rbp - BAN_OBJ]
    call ap_free
.ban_fail:
    xor eax, eax
    leave
    ret
END_FUNC bytearray_new

;; ============================================================================
;; bytearray_subscript(rdi = self, rsi = key Value) -> rax = Value
;;
;; An int gives the byte as an int; a slice gives a new BYTEARRAY, as CPython
;; does -- bytes gives bytes and bytearray gives bytearray.
;; ============================================================================
BSU_SELF  equ 8
BSU_KEY   equ 16
BSU_START equ 24
BSU_STEP  equ 32
BSU_LEN   equ 40
BSU_OUT   equ 48
BSU_KEYTAG equ 56
BSU_FRAME equ 64            ; + 0 pushes = 64

DEF_FUNC bytearray_subscript, BSU_FRAME
    mov [rbp - BSU_SELF], rdi
    ; The key arrives as a Value; obj_as_index and the slice test both want
    ; the (payload, tag) pair, as bytes_subscript unpacks it too.
    V_UNPACK rsi, rdx
    mov [rbp - BSU_KEY], rsi
    mov [rbp - BSU_KEYTAG], rdx

    cmp edx, TAG_PTR
    jne .bsu_int                ; an immediate: an int index
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel slice_type]
    cmp rax, rcx
    je .bsu_slice

.bsu_int:
    mov rdi, [rbp - BSU_KEY]
    mov rdx, [rbp - BSU_KEYTAG]
    lea rsi, [rel bsu_index_msg]
    call obj_as_index_seq
    ERR_M1_JUMP
    mov rcx, [rbp - BSU_SELF]
    mov rdx, [rcx + PyByteArrayObject.ob_size]
    test rax, rax
    jns .bsu_have_index
    add rax, rdx                ; a negative index counts from the end
.bsu_have_index:
    test rax, rax
    jl .bsu_range
    cmp rax, rdx
    jge .bsu_range
    push rax
    mov rdi, rcx
    call bytearray_data
    pop rcx
    movzx eax, byte [rax + rcx]
    V_PACK_I64 rax, rcx
    leave
    ret

.bsu_slice:
    mov rdi, [rbp - BSU_KEY]
    mov rcx, [rbp - BSU_SELF]
    ; The LIVE length: a bound's __index__ can clear this very bytearray.
    lea rsi, [rcx + PyByteArrayObject.ob_size]
    call slice_indices_live     ; rax = start, rdx = stop, rcx = step
    ERR_M1_JUMP
    mov [rbp - BSU_START], rax
    mov [rbp - BSU_STEP], rcx
    ; The element count, which slice_length computes for any step.
    mov rdi, rax
    mov rsi, rdx
    call slice_length           ; rdi = start, rsi = stop, rcx = step
    mov [rbp - BSU_LEN], rax

    xor edi, edi                ; no source: filled below
    mov rsi, rax
    call bytearray_new
    test rax, rax
    jz .bsu_fail
    mov [rbp - BSU_OUT], rax

    mov rdi, [rbp - BSU_SELF]
    call bytearray_data
    mov rsi, rax                ; the source bytes
    mov rdx, [rbp - BSU_OUT]
    mov rdx, [rdx + PyByteArrayObject.ob_bytes]
    mov r8, [rbp - BSU_START]
    mov r9, [rbp - BSU_STEP]
    xor ecx, ecx
.bsu_copy:
    cmp rcx, [rbp - BSU_LEN]
    jge .bsu_copied
    movzx eax, byte [rsi + r8]
    mov [rdx + rcx], al
    add r8, r9
    inc rcx
    jmp .bsu_copy
.bsu_copied:
    mov rax, [rbp - BSU_OUT]
    leave
    ret

.bsu_fail:
    xor eax, eax
    leave
    ret
.bsu_range:
    RAISE exc_IndexError_type, "bytearray index out of range"
END_FUNC bytearray_subscript

section .rodata
bsu_index_msg: db `bytearray indices must be integers or slices, not \x01`, 0
section .text

;; ============================================================================
;; slice_length(rdi = start, rsi = stop, rcx = step) -> rax = element count
;;
;; The count slice_indices does not return.  Shared by every bytearray slice
;; operation, each of which needs it before it can size a buffer.
;; ============================================================================
DEF_FUNC_BARE slice_length
    test rcx, rcx
    js .sln_negative
    mov rax, rsi
    sub rax, rdi                ; stop - start
    jle .sln_zero
    ; ceil(span / step)
    add rax, rcx
    dec rax
    xor edx, edx
    div rcx
    ret
.sln_negative:
    mov rax, rdi
    sub rax, rsi                ; start - stop
    jle .sln_zero
    mov r8, rcx
    neg r8
    add rax, r8
    dec rax
    xor edx, edx
    div r8
    ret
.sln_zero:
    xor eax, eax
    ret
END_FUNC slice_length

;; ============================================================================
;; bytearray_ass_subscript(rdi = self, rsi = key Value, rdx = value Value)
;;   -> rax = 0 on success
;;
;; b[i] = v, b[i:j] = v, b[i:j:k] = v, and all three deletions -- a NULL value
;; Value means del, which is how mp_ass_subscript spells it everywhere.
;;
;; The simple-slice case is the one CPython's regex compiler needs
;; (`data[0:0] = ...`), and it is the only one that changes the length: the
;; tail is moved and the buffer grown or the size dropped.
;; ============================================================================
BAS_SELF  equ 8
BAS_KEY   equ 16
BAS_KTAG  equ 24
BAS_VAL   equ 32
BAS_SRC   equ 40            ; the replacement bytes
BAS_SLEN  equ 48            ; and how many
BAS_START equ 56
BAS_STOP  equ 64
BAS_STEP  equ 72
BAS_N     equ 80            ; the slice's element count
BAS_TMP   equ 88            ; a copy, when source and target are the same object
BAS_SPAN  equ 96            ; bytes the span gives up, across the two calls below
BAS_FRAME equ 96            ; + 1 push = 104... padded to 112 below

DEF_FUNC bytearray_ass_subscript, 104
    push rbx
    mov [rbp - BAS_SELF], rdi
    mov [rbp - BAS_VAL], rdx
    mov qword [rbp - BAS_TMP], 0
    V_UNPACK rsi, rcx
    mov [rbp - BAS_KEY], rsi
    mov [rbp - BAS_KTAG], rcx

    cmp ecx, TAG_PTR
    jne .bas_int
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel slice_type]
    cmp rax, rcx
    je .bas_slice

;; --- b[i] = v, and del b[i] ------------------------------------------------
.bas_int:
    mov rdi, [rbp - BAS_KEY]
    mov rdx, [rbp - BAS_KTAG]
    lea rsi, [rel bsu_index_msg]
    extern obj_as_index_seq
    call obj_as_index_seq
    ERR_M1_JUMP
    mov rbx, rax
    mov rcx, [rbp - BAS_SELF]
    mov rdx, [rcx + PyByteArrayObject.ob_size]
    test rbx, rbx
    jns .bas_int_bounds
    add rbx, rdx
.bas_int_bounds:
    test rbx, rbx
    jl .bas_range
    cmp rbx, rdx
    jge .bas_range

    cmp qword [rbp - BAS_VAL], 0
    je .bas_del_one

    mov rdi, [rbp - BAS_VAL]
    call bytearray_index_arg    ; 0..255, or it raises
    mov rcx, rax
    mov rdi, [rbp - BAS_SELF]
    push rcx
    call bytearray_data
    pop rcx
    mov [rax + rbx], cl
    xor eax, eax
    pop rbx
    leave
    ret

.bas_del_one:
    mov rdi, [rbp - BAS_SELF]
    BA_REFUSE_IF_EXPORTED rdi   ; the gap is closed before the resize
    ; Close the gap, then drop the length by one.
    mov rdi, [rbp - BAS_SELF]
    call bytearray_data
    mov rcx, [rbp - BAS_SELF]
    mov rdx, [rcx + PyByteArrayObject.ob_size]
    lea rdi, [rax + rbx]
    lea rsi, [rdi + 1]
    sub rdx, rbx
    dec rdx
    call ap_memmove
    mov rdi, [rbp - BAS_SELF]
    mov rsi, [rdi + PyByteArrayObject.ob_size]
    dec rsi
    call bytearray_resize
    xor eax, eax
    pop rbx
    leave
    ret

;; --- the slice forms -------------------------------------------------------
.bas_slice:
    mov rdi, [rbp - BAS_KEY]
    mov rcx, [rbp - BAS_SELF]
    lea rsi, [rcx + PyByteArrayObject.ob_size]      ; the LIVE length
    call slice_indices_live
    ERR_M1_JUMP
    mov [rbp - BAS_START], rax
    mov [rbp - BAS_STOP], rdx
    mov [rbp - BAS_STEP], rcx
    mov rdi, rax
    mov rsi, rdx
    call slice_length
    mov [rbp - BAS_N], rax

    ; The replacement, as a byte range.  A deletion has none.
    mov qword [rbp - BAS_SRC], 0
    mov qword [rbp - BAS_SLEN], 0
    cmp qword [rbp - BAS_VAL], 0
    je .bas_have_src

    ; Assigning a bytearray to a slice of ITSELF would read the buffer while
    ; moving it, so take a copy first.
    mov rdi, [rbp - BAS_VAL]
    cmp rdi, [rbp - BAS_SELF]
    jne .bas_src_from_value
    call bytearray_data
    mov rdi, rax
    mov rcx, [rbp - BAS_SELF]
    mov rsi, [rcx + PyByteArrayObject.ob_size]
    call bytearray_new
    test rax, rax
    jz .bas_fail
    mov [rbp - BAS_TMP], rax
    mov rdi, rax

.bas_src_from_value:
    ; byteslike_source normalises bytes, bytearray, memoryview and any
    ; iterable of ints into a buffer it owns.
    mov [rbp - BAS_VAL], rdi
    lea rdi, [rbp - BAS_VAL]
    mov esi, 1
    lea rdx, [rel bytearray_range_msg]
    lea rcx, [rel bytearray_enc_msg]
    lea r8, [rel bytearray_arity_msg]
    lea r9, [rel bytearray_conv_msg]
    call byteslike_source
    mov [rbp - BAS_SRC], rax
    mov [rbp - BAS_SLEN], rdx

.bas_have_src:
    ; Converting the value may have run Python -- an element's __index__ --
    ; and that may have resized this bytearray under the bounds clamped
    ; above.  Clamp again against the length it has now; an extended slice
    ; that no longer fits selects nothing.
    mov rcx, [rbp - BAS_SELF]
    mov rax, [rcx + PyByteArrayObject.ob_size]
    cmp qword [rbp - BAS_STEP], 1
    jne .bas_ext_reclamp
    cmp [rbp - BAS_START], rax
    jbe .bas_start_live
    mov [rbp - BAS_START], rax
.bas_start_live:
    cmp [rbp - BAS_STOP], rax
    jbe .bas_reclamped
    mov [rbp - BAS_STOP], rax
    jmp .bas_reclamped
.bas_ext_reclamp:
    mov rdx, [rbp - BAS_N]
    test rdx, rdx
    jz .bas_reclamped
    cmp [rbp - BAS_START], rax
    jae .bas_ext_stale
    dec rdx
    imul rdx, [rbp - BAS_STEP]
    add rdx, [rbp - BAS_START]  ; the last index the slice touches
    cmp rdx, rax
    jb .bas_reclamped
.bas_ext_stale:
    mov qword [rbp - BAS_N], 0
.bas_reclamped:
    cmp qword [rbp - BAS_STEP], 1
    jne .bas_extended

;; --- b[i:j] = v: the only form that changes the length ---------------------
    mov r8, [rbp - BAS_STOP]
    mov r9, [rbp - BAS_START]
    cmp r8, r9
    jge .bas_span_ok
    mov r8, r9                  ; an empty span, as slice_indices allows
.bas_span_ok:
    sub r8, r9                  ; how many bytes go away
    ; The only arm that changes the length, and it moves the tail before it
    ; resizes.  Refused here, with the two owned things released first --
    ; .bas_ext_mismatch below does the same for the same reason.
    mov rcx, [rbp - BAS_SELF]
    cmp qword [rcx + PyByteArrayObject.ob_exports], 0
    jle .bas_span_exports_ok
    mov rdx, [rcx + PyByteArrayObject.ob_size]
    sub rdx, r8
    add rdx, [rbp - BAS_SLEN]   ; the length this assignment would produce
    cmp rdx, [rcx + PyByteArrayObject.ob_size]
    je .bas_span_exports_ok     ; same size: legal with a view out
    jmp .bas_span_exported
.bas_span_exports_ok:
    ; To the frame, not left in r8: bytearray_resize and bytearray_data are
    ; both ahead, both ordinary calls, and r8 is caller-saved.  rdx and rcx
    ; were already spilled around each of them; this one was not, so the
    ; memmove below read its source from a garbage offset.
    mov [rbp - BAS_SPAN], r8
    mov rcx, [rbp - BAS_SLEN]   ; rcx = how many arrive
    mov rdi, [rbp - BAS_SELF]
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    mov rbx, rdx
    sub rbx, r8
    sub rbx, r9                 ; rbx = the length of the tail after the span
    add rdx, rcx
    sub rdx, r8                 ; rdx = the new length

    ; Grow first when the buffer has to be bigger, so the tail is moved into
    ; space that exists.
    cmp rdx, [rdi + PyByteArrayObject.ob_size]
    jbe .bas_no_grow
    mov rsi, rdx
    push rdx
    push rcx
    call bytearray_resize
    pop rcx
    pop rdx
    test eax, eax
    jz .bas_fail
.bas_no_grow:
    ; Move the tail to where it belongs.
    mov rdi, [rbp - BAS_SELF]
    push rdx
    push rcx
    call bytearray_data
    pop rcx
    pop rdx
    mov rsi, rax
    mov r9, [rbp - BAS_START]
    lea rdi, [rax + r9]
    add rdi, rcx                ; the tail's new home
    lea rsi, [rax + r9]
    add rsi, [rbp - BAS_SPAN]   ; where it is now
    push rdx
    push rcx
    mov rdx, rbx
    call ap_memmove
    pop rcx
    pop rdx

    ; Then drop the replacement in.
    test rcx, rcx
    jz .bas_no_fill
    mov rdi, [rbp - BAS_SELF]
    push rdx
    push rcx
    call bytearray_data
    pop rcx
    pop rdx
    mov r9, [rbp - BAS_START]
    lea rdi, [rax + r9]
    mov rsi, [rbp - BAS_SRC]
    push rdx
    mov rdx, rcx
    call ap_memcpy
    pop rdx
.bas_no_fill:
    mov rdi, [rbp - BAS_SELF]
    mov rsi, rdx
    call bytearray_resize
    jmp .bas_done

;; --- b[i:j:k] = v, which must match the slice length exactly ---------------
.bas_extended:
    cmp qword [rbp - BAS_VAL], 0
    je .bas_ext_delete
    mov rax, [rbp - BAS_SLEN]
    ; An EMPTY right-hand side is the one length that does not have to match:
    ; b[::2] = b'' removes those positions, exactly as del b[::2] does, and
    ; bytearray(b'abcd') becomes bytearray(b'bd').  This is bytearray's alone
    ; -- a list raises for L[::2] = [] in CPython too -- and it read as a
    ; length mismatch here because only a NULL value counted as a delete.
    test rax, rax
    jz .bas_ext_delete
    cmp rax, [rbp - BAS_N]
    jne .bas_ext_mismatch
    mov rdi, [rbp - BAS_SELF]
    call bytearray_data
    mov rdx, [rbp - BAS_SRC]
    mov r8, [rbp - BAS_START]
    mov r9, [rbp - BAS_STEP]
    xor ecx, ecx
.bas_ext_loop:
    cmp rcx, [rbp - BAS_N]
    jge .bas_done
    movzx esi, byte [rdx + rcx]
    mov [rax + r8], sil
    add r8, r9
    inc rcx
    jmp .bas_ext_loop

.bas_ext_delete:
    ; An empty selection removes nothing and never resizes.
    cmp qword [rbp - BAS_N], 0
    jle .bas_ext_delete_go
    mov rdi, [rbp - BAS_SELF]
    BA_REFUSE_IF_EXPORTED rdi   ; the compaction runs before the resize
.bas_ext_delete_go:
    ; Walk forward, copying the bytes that survive down over the gaps.
    mov rdi, [rbp - BAS_SELF]
    call bytearray_data
    mov rcx, [rbp - BAS_SELF]
    mov r10, [rcx + PyByteArrayObject.ob_size]
    mov r8, [rbp - BAS_START]
    mov r9, [rbp - BAS_STEP]
    ; The walk below is forward, so a negative step has to be turned into the
    ; same set of indices counted upward: {start, start+step, ...} with step
    ; negative is {start+(n-1)*step, ..., start} with it positive.  Without
    ; this only the first index ever matched, and `del b[::-2]` removed one
    ; byte instead of three.
    test r9, r9
    jns .bas_extdel_ready
    mov rdx, [rbp - BAS_N]
    dec rdx
    jl .bas_extdel_ready        ; an empty slice deletes nothing
    imul rdx, r9
    add r8, rdx
    neg r9
.bas_extdel_ready:
    xor ecx, ecx                ; how many deleted so far
    xor rsi, rsi                ; the read cursor
    xor rdi, rdi                ; the write cursor
.bas_extdel_loop:
    cmp rsi, r10
    jge .bas_extdel_done
    ; Is this index one of the slice's?
    cmp rcx, [rbp - BAS_N]
    jge .bas_extdel_keep
    cmp rsi, r8
    jne .bas_extdel_keep
    add r8, r9
    inc rcx
    inc rsi
    jmp .bas_extdel_loop
.bas_extdel_keep:
    movzx edx, byte [rax + rsi]
    mov [rax + rdi], dl
    inc rdi
    inc rsi
    jmp .bas_extdel_loop
.bas_extdel_done:
    mov rsi, rdi
    mov rdi, [rbp - BAS_SELF]
    call bytearray_resize

.bas_done:
    mov rdi, [rbp - BAS_SRC]
    test rdi, rdi
    jz .bas_no_src_free
    call ap_free
.bas_no_src_free:
    mov rdi, [rbp - BAS_TMP]
    test rdi, rdi
    jz .bas_ok
    call obj_decref
.bas_ok:
    xor eax, eax
    pop rbx
    leave
    ret

.bas_fail:
    mov rdi, [rbp - BAS_SRC]
    test rdi, rdi
    jz .bas_fail_out
    call ap_free
.bas_fail_out:
    mov eax, -1
    pop rbx
    leave
    ret

.bas_range:
    RAISE exc_IndexError_type, "bytearray index out of range"

.bas_span_exported:
    mov rdi, [rbp - BAS_SRC]
    test rdi, rdi
    jz .bas_span_exported_raise
    call ap_free
.bas_span_exported_raise:
    mov rdi, [rbp - BAS_TMP]
    test rdi, rdi
    jz .bas_span_exported_raise2
    call obj_decref
.bas_span_exported_raise2:
    RAISE exc_BufferError_type, "Existing exports of data: object cannot be re-sized"

.bas_ext_mismatch:
    ; RAISE abandons the C stack, so the buffer byteslike_source owns has to
    ; go first -- .bas_done below never runs from here.
    mov rdi, [rbp - BAS_SRC]
    test rdi, rdi
    jz .bas_mismatch_raise
    call ap_free
.bas_mismatch_raise:
    mov rdi, [rbp - BAS_TMP]
    test rdi, rdi
    jz .bas_mismatch_raise2
    call obj_decref
.bas_mismatch_raise2:
    ; "attempt to assign bytes of size 3 to extended slice of size 2", the two
    ; numbers being BAS_SLEN and BAS_N, both still in the frame.
    sub rsp, 128
    mov rdi, rsp
    lea rsi, [rel bas_msg_size]
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - BAS_SLEN]
    extern msg_append_i64
    call msg_append_i64
    mov rdi, rax
    lea rsi, [rel bas_msg_to]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - BAS_N]
    call msg_append_i64
    lea rdi, [rel exc_ValueError_type]
    mov rsi, rsp
    call raise_exception
    ud2
END_FUNC bytearray_ass_subscript

;; ============================================================================
;; bytearray_contains(rdi = self, rsi = needle Value) -> eax = 0/1
;;
;; An int looks for that byte; a bytes-like looks for the subsequence -- the
;; same two meanings `in` has for bytes.
;; ============================================================================
BCT_SELF  equ 8
BCT_VAL   equ 16
BCT_SRC   equ 24
BCT_SLEN  equ 32
BCT_FRAME equ 32            ; + 2 pushes = 48

DEF_FUNC bytearray_contains, BCT_FRAME
    push rbx
    push r12
    mov [rbp - BCT_SELF], rdi
    mov [rbp - BCT_VAL], rsi

    ; An int looks for the byte -- and "an int" is int_is_integer's answer,
    ; not a tag test: under INT_STRESS=1 every int is a heap object, and a
    ; pointer test sent them all down the bytes-like path.
    mov rdi, rsi
    V_UNPACK rdi, rdx
    call int_is_integer
    test eax, eax
    jz .bct_object
    ; A width obj_as_index would refuse as an index is simply out of range
    ; for a byte, and CPython says so rather than naming a C type.
    mov rdi, [rbp - BCT_VAL]
    V_UNPACK rdi, rdx
    cmp edx, TAG_PTR
    jne .bct_narrow
    extern int_fits_i64
    call int_fits_i64
    test eax, eax
    jz .bct_range
.bct_narrow:
    mov rdi, [rbp - BCT_VAL]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1_JUMP
    mov rdi, rax
    test rdi, rdi
    jl .bct_range
    cmp rdi, 255
    jg .bct_range
    mov rbx, rdi
    mov rdi, [rbp - BCT_SELF]
    mov r12, [rdi + PyByteArrayObject.ob_size]
    call bytearray_data
    xor ecx, ecx
.bct_byte_loop:
    cmp rcx, r12
    jge .bct_no
    movzx edx, byte [rax + rcx]
    cmp rdx, rbx
    je .bct_yes
    inc rcx
    jmp .bct_byte_loop

.bct_object:
    ; A bytes-like: look for the subsequence.  byteslike_source is the
    ; CONSTRUCTOR's rule and its refusal says "cannot convert ... to
    ; bytearray"; membership asks for a bytes-like and says so.
    mov rdi, [rbp - BCT_VAL]
    call bytes_like_ptr_len
    test ecx, ecx
    jz .bct_arg_type
    lea rdi, [rbp - BCT_VAL]
    mov esi, 1
    lea rdx, [rel bytearray_range_msg]
    lea rcx, [rel bytearray_enc_msg]
    lea r8, [rel bytearray_arity_msg]
    lea r9, [rel bytearray_conv_msg]
    call byteslike_source
    mov [rbp - BCT_SRC], rax
    mov [rbp - BCT_SLEN], rdx

    mov rdi, [rbp - BCT_SELF]
    mov r12, [rdi + PyByteArrayObject.ob_size]
    call bytearray_data
    mov rbx, rax
    mov r8, [rbp - BCT_SLEN]
    test r8, r8
    jz .bct_yes_free            ; the empty subsequence is in everything
    cmp r8, r12
    ja .bct_no_free
    xor ecx, ecx
.bct_scan:
    mov rax, r12
    sub rax, rcx
    cmp rax, r8
    jl .bct_no_free
    lea rdi, [rbx + rcx]
    mov rsi, [rbp - BCT_SRC]
    mov rdx, r8
    push rcx
    push r8
    call ap_memcmp
    pop r8
    pop rcx
    test eax, eax
    jz .bct_yes_free
    inc rcx
    jmp .bct_scan

.bct_yes_free:
    mov rdi, [rbp - BCT_SRC]
    test rdi, rdi
    jz .bct_yes
    call ap_free
.bct_yes:
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret
.bct_no_free:
    mov rdi, [rbp - BCT_SRC]
    test rdi, rdi
    jz .bct_no
    call ap_free
.bct_no:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
.bct_range:
    RAISE exc_ValueError_type, "byte must be in range(0, 256)"
.bct_arg_type:
    mov rsi, [rbp - BCT_VAL]
    CSTRING rdi, `a bytes-like object is required, not '\x01'`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
.bct_type_error:
    RAISE exc_TypeError_type, "a bytes-like object is required"
END_FUNC bytearray_contains

;; ============================================================================
;; The mutators.  Each takes (rdi = args Value[], rsi = nargs) with args[0] as
;; self, which is the method calling convention everywhere here.
;;
;; They share one shape: work out the new length, resize, then move bytes.
;; bytearray_resize never shrinks the allocation, so removing and re-adding
;; does not thrash.
;; ============================================================================
BAM_SELF  equ 8
BAM_ARG   equ 16
BAM_SRC   equ 24
BAM_SLEN  equ 32
BAM_OLD   equ 40
BAM_IDX   equ 48
BAM_FRAME equ 48            ; + 0 pushes = 48

;; bytearray.append(b)
DEF_FUNC bytearray_method_append, BAM_FRAME
    cmp rsi, 2
    jne .bap_argerr
    mov rax, [rdi]
    mov [rbp - BAM_SELF], rax
    mov rdi, [rdi + 8]
    call bytearray_index_arg
    mov [rbp - BAM_ARG], rax
    mov rdi, [rbp - BAM_SELF]
    mov rsi, [rdi + PyByteArrayObject.ob_size]
    mov [rbp - BAM_OLD], rsi
    inc rsi
    call bytearray_resize
    test eax, eax
    jz .bap_oom
    mov rdi, [rbp - BAM_SELF]
    call bytearray_data
    mov rcx, [rbp - BAM_OLD]
    mov rdx, [rbp - BAM_ARG]
    mov [rax + rcx], dl
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
.bap_oom:
    ; bytearray_resize's 0 now means "a live memoryview blocks this", with a
    ; BufferError already recorded -- raising a MemoryError over it would
    ; bury the real one.  Propagate the pending exception instead.
    xor eax, eax
    xor edx, edx
    leave
    ret
.bap_argerr:
    RAISE exc_TypeError_type, "append() takes exactly one argument"
END_FUNC bytearray_method_append

;; bytearray.extend(iterable) -- and the body sq_inplace_concat shares.
;;
;; bytearray_extend_from(rdi = self, rsi = a Value) -> eax = 1 on success
DEF_FUNC bytearray_extend_from, BAM_FRAME
    mov [rbp - BAM_SELF], rdi
    mov [rbp - BAM_ARG], rsi
    ; byteslike_source takes an args array, so hand it the one slot.
    lea rdi, [rbp - BAM_ARG]
    mov esi, 1
    lea rdx, [rel bytearray_range_msg]
    lea rcx, [rel bytearray_enc_msg]
    lea r8, [rel bytearray_arity_msg]
    lea r9, [rel bytearray_conv_msg]
    call byteslike_source
    mov [rbp - BAM_SRC], rax
    mov [rbp - BAM_SLEN], rdx

    mov rdi, [rbp - BAM_SELF]
    mov rsi, [rdi + PyByteArrayObject.ob_size]
    mov [rbp - BAM_OLD], rsi
    add rsi, rdx
    call bytearray_resize
    test eax, eax
    jz .bef_fail

    mov rcx, [rbp - BAM_SLEN]
    test rcx, rcx
    jz .bef_done
    mov rdi, [rbp - BAM_SELF]
    call bytearray_data
    mov rdi, rax
    add rdi, [rbp - BAM_OLD]
    mov rsi, [rbp - BAM_SRC]
    mov rdx, [rbp - BAM_SLEN]
    call ap_memcpy
.bef_done:
    mov rdi, [rbp - BAM_SRC]
    test rdi, rdi
    jz .bef_ok
    call ap_free
.bef_ok:
    mov eax, 1
    leave
    ret
.bef_fail:
    mov rdi, [rbp - BAM_SRC]
    test rdi, rdi
    jz .bef_fail_out
    call ap_free
.bef_fail_out:
    xor eax, eax
    leave
    ret
END_FUNC bytearray_extend_from

DEF_FUNC bytearray_method_extend, BAM_FRAME
    cmp rsi, 2
    jne .bex_argerr
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call bytearray_extend_from
    test eax, eax
    jz .bex_oom
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
.bex_oom:
    ; bytearray_resize's 0 now means "a live memoryview blocks this", with a
    ; BufferError already recorded -- raising a MemoryError over it would
    ; bury the real one.  Propagate the pending exception instead.
    xor eax, eax
    xor edx, edx
    leave
    ret
.bex_argerr:
    RAISE exc_TypeError_type, "extend() takes exactly one argument"
END_FUNC bytearray_method_extend

;; bytearray.insert(i, b)
DEF_FUNC bytearray_method_insert, BAM_FRAME
    cmp rsi, 3
    jne .bin_argerr
    mov rax, [rdi]
    mov [rbp - BAM_SELF], rax
    mov [rbp - BAM_ARG], rdi
    mov rdi, [rdi + 8]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .idx_fail
    mov [rbp - BAM_IDX], rax
    mov rdi, [rbp - BAM_ARG]
    mov rdi, [rdi + 16]
    call bytearray_index_arg
    mov [rbp - BAM_ARG], rax

    ; Clamp, as list.insert does: any index past either end lands at that end.
    mov rdi, [rbp - BAM_SELF]
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    mov rcx, [rbp - BAM_IDX]
    test rcx, rcx
    jns .bin_positive
    add rcx, rdx
    jns .bin_positive
    xor ecx, ecx
.bin_positive:
    cmp rcx, rdx
    jle .bin_have_idx
    mov rcx, rdx
.bin_have_idx:
    mov [rbp - BAM_IDX], rcx
    mov [rbp - BAM_OLD], rdx
    lea rsi, [rdx + 1]
    call bytearray_resize
    test eax, eax
    jz .bin_oom

    mov rdi, [rbp - BAM_SELF]
    call bytearray_data
    mov rcx, [rbp - BAM_IDX]
    lea rdi, [rax + rcx + 1]
    lea rsi, [rax + rcx]
    mov rdx, [rbp - BAM_OLD]
    sub rdx, rcx
    call ap_memmove
    mov rdi, [rbp - BAM_SELF]
    call bytearray_data
    mov rcx, [rbp - BAM_IDX]
    mov rdx, [rbp - BAM_ARG]
    mov [rax + rcx], dl
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
.bin_oom:
    ; bytearray_resize's 0 now means "a live memoryview blocks this", with a
    ; BufferError already recorded -- raising a MemoryError over it would
    ; bury the real one.  Propagate the pending exception instead.
    xor eax, eax
    xor edx, edx
    leave
    ret
.bin_argerr:
    RAISE exc_TypeError_type, "insert() takes exactly 2 arguments"
.idx_fail:                      ; not an index: the exception is pending
    xor eax, eax
    leave
    ret
END_FUNC bytearray_method_insert

;; bytearray.pop([i]) -> the byte removed
DEF_FUNC bytearray_method_pop, BAM_FRAME
    cmp rsi, 1
    jl .bpo_argerr
    cmp rsi, 2
    jg .bpo_argerr
    mov rax, [rdi]
    mov [rbp - BAM_SELF], rax
    BA_REFUSE_IF_EXPORTED rax   ; the memmove below runs before the resize
    mov rdx, [rax + PyByteArrayObject.ob_size]
    test rdx, rdx
    jz .bpo_empty
    mov rcx, rdx
    dec rcx                     ; the default is the last byte
    cmp rsi, 2
    jne .bpo_have_idx
    push rdx
    mov rdi, [rdi + 8]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1_JUMP
    pop rdx
    mov rcx, rax
    test rcx, rcx
    jns .bpo_have_idx
    add rcx, rdx
.bpo_have_idx:
    test rcx, rcx
    jl .bpo_range
    cmp rcx, rdx
    jge .bpo_range
    mov [rbp - BAM_IDX], rcx
    mov [rbp - BAM_OLD], rdx

    mov rdi, [rbp - BAM_SELF]
    call bytearray_data
    mov rcx, [rbp - BAM_IDX]
    movzx edx, byte [rax + rcx]
    mov [rbp - BAM_ARG], rdx    ; the answer, before the move
    lea rdi, [rax + rcx]
    lea rsi, [rdi + 1]
    mov rdx, [rbp - BAM_OLD]
    sub rdx, rcx
    dec rdx
    call ap_memmove
    mov rdi, [rbp - BAM_SELF]
    mov rsi, [rbp - BAM_OLD]
    dec rsi
    call bytearray_resize
    mov rax, [rbp - BAM_ARG]
    V_PACK_I64 rax, rcx
    mov edx, TAG_PTR
    leave
    ret
.bpo_empty:
    RAISE exc_IndexError_type, "pop from empty bytearray"
.bpo_range:
    RAISE exc_IndexError_type, "pop index out of range"
.bpo_argerr:
    RAISE exc_TypeError_type, "pop() takes at most 1 argument"
END_FUNC bytearray_method_pop

;; bytearray.remove(b) -- the first occurrence, or ValueError
DEF_FUNC bytearray_method_remove, BAM_FRAME
    cmp rsi, 2
    jne .brm_argerr
    mov rax, [rdi]
    mov [rbp - BAM_SELF], rax
    BA_REFUSE_IF_EXPORTED rax   ; the memmove below runs before the resize
    mov rdi, [rdi + 8]
    call bytearray_index_arg
    mov [rbp - BAM_ARG], rax

    mov rdi, [rbp - BAM_SELF]
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    mov [rbp - BAM_OLD], rdx
    call bytearray_data
    mov rcx, [rbp - BAM_ARG]
    xor esi, esi
.brm_scan:
    cmp rsi, [rbp - BAM_OLD]
    jge .brm_missing
    movzx edx, byte [rax + rsi]
    cmp rdx, rcx
    je .brm_found
    inc rsi
    jmp .brm_scan
.brm_found:
    lea rdi, [rax + rsi]
    push rsi
    lea rsi, [rdi + 1]
    mov rdx, [rbp - BAM_OLD]
    pop rcx
    sub rdx, rcx
    dec rdx
    call ap_memmove
    mov rdi, [rbp - BAM_SELF]
    mov rsi, [rbp - BAM_OLD]
    dec rsi
    call bytearray_resize
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
.brm_missing:
    RAISE exc_ValueError_type, "value not found in bytearray"
.brm_argerr:
    RAISE exc_TypeError_type, "remove() takes exactly one argument"
END_FUNC bytearray_method_remove

;; bytearray.clear()
DEF_FUNC bytearray_method_clear, BAM_FRAME
    mov rdi, [rdi]
    xor esi, esi
    call bytearray_resize
    test eax, eax
    jz .bcl_failed              ; the return was ignored outright
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
.bcl_failed:
    xor eax, eax                ; a NULL Value, with the exception pending
    xor edx, edx
    leave
    ret
END_FUNC bytearray_method_clear

;; bytearray.reverse()
DEF_FUNC bytearray_method_reverse, BAM_FRAME
    mov rdi, [rdi]
    mov rsi, [rdi + PyByteArrayObject.ob_size]
    call bytearray_data
    xor ecx, ecx
    mov rdx, rsi
    dec rdx
.brv_loop:
    cmp rcx, rdx
    jge .brv_done
    movzx esi, byte [rax + rcx]
    movzx edi, byte [rax + rdx]
    mov [rax + rcx], dil
    mov [rax + rdx], sil
    inc rcx
    dec rdx
    jmp .brv_loop
.brv_done:
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
END_FUNC bytearray_method_reverse

;; bytearray.copy() -> a new bytearray
DEF_FUNC bytearray_method_copy, BAM_FRAME
    mov rdi, [rdi]
    mov [rbp - BAM_SELF], rdi
    mov rsi, [rdi + PyByteArrayObject.ob_size]
    mov [rbp - BAM_SLEN], rsi
    call bytearray_data
    mov rdi, rax
    mov rsi, [rbp - BAM_SLEN]
    call bytearray_new
    mov edx, TAG_PTR
    leave
    ret
END_FUNC bytearray_method_copy

;; ============================================================================
;; The operators: +, *, += and *=.
;;
;; sq_concat and sq_repeat build a new bytearray; the inplace pair mutate and
;; hand back the same object, which is what makes `b += x` in a loop O(n).
;; ============================================================================
BAO_SELF  equ 8
BAO_ARG   equ 16
BAO_SRC   equ 24
BAO_SLEN  equ 32
BAO_OUT   equ 40
BAO_OWNED equ 48
BAO_FRAME equ 64            ; + 0 pushes = 64

DEF_FUNC bytearray_concat, BAO_FRAME
    mov [rbp - BAO_SELF], rdi
    mov [rbp - BAO_ARG], rsi
    ; A bytes-like only.  byteslike_source is the CONSTRUCTOR's rule and takes
    ; any iterable of ints, so using it here made `bytearray(b"ab") + [1, 2]`
    ; succeed where CPython raises.  extend() keeps the looser rule.
    mov rdi, rsi
    call bytes_like_ptr_len
    test ecx, ecx
    jz .bco_not_impl
    mov [rbp - BAO_SRC], rax
    mov [rbp - BAO_SLEN], r10
    mov qword [rbp - BAO_OWNED], 0

    mov rdi, [rbp - BAO_SELF]
    mov rsi, [rdi + PyByteArrayObject.ob_size]
    add rsi, [rbp - BAO_SLEN]
    xor edi, edi
    call bytearray_new
    test rax, rax
    jz .bco_fail
    mov [rbp - BAO_OUT], rax

    mov rdi, [rbp - BAO_SELF]
    mov r8, [rdi + PyByteArrayObject.ob_size]
    push r8
    call bytearray_data
    pop r8
    mov rsi, rax
    mov rax, [rbp - BAO_OUT]
    mov rdi, [rax + PyByteArrayObject.ob_bytes]
    mov rdx, r8
    push r8
    push r8
    call ap_memcpy
    pop r8
    pop r8
    mov rax, [rbp - BAO_OUT]
    mov rdi, [rax + PyByteArrayObject.ob_bytes]
    add rdi, r8
    mov rsi, [rbp - BAO_SRC]
    mov rdx, [rbp - BAO_SLEN]
    call ap_memcpy
.bco_done:
    mov rax, [rbp - BAO_OUT]
    mov edx, TAG_PTR
    leave
    ret
.bco_not_impl:
    ; CPython's bytearray_concat RAISES rather than declining, and names
    ; both types: "can't concat NoneType to bytearray".  Declining left the
    ; generic operand message, which says nothing about bytearray's rule.
    mov rsi, [rbp - BAO_ARG]
    CSTRING rdi, `can't concat \x01 to bytearray`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
.bco_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC bytearray_concat

DEF_FUNC bytearray_repeat, BAO_FRAME
    mov [rbp - BAO_SELF], rdi
    mov [rbp - BAO_ARG], rsi        ; the count Value, across binop_is_count
    ; sq_repeat is handed two VALUES, not a count -- op_binary_op packs both
    ; operands before the call, as bytes_repeat's own V_UNPACK shows.
    ;
    ; The count goes through the three checks bytes_repeat and list_repeat
    ; both make, none of which this one had.  It called obj_as_index straight
    ; away, so a non-int with an __index__ was accepted where CPython raises;
    ; int_to_i64 truncated a count past 2^63 rather than refusing it, which is
    ; how bytearray(b'x') * (2**70) answered bytearray(b''); and the product
    ; was neither checked for overflow nor capped, so bytearray(b'xy') *
    ; (2**40) went to the allocator and aborted the process.
    ; Not a count at all: DECLINE rather than raise, so the protocol carries
    ; on to the right operand's __rmul__, as the other four sequences do.
    mov rdi, rsi
    extern binop_is_count
    call binop_is_count
    test eax, eax
    jz .brp_fail
    mov rsi, [rbp - BAO_ARG]
    extern seq_repeat_count
    call seq_repeat_count           ; takes __index__, and refuses a count
    mov rsi, rax                    ; too big to be an index

    mov rdi, [rbp - BAO_SELF]
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    mov [rbp - BAO_SLEN], rdx
    mov rax, rsi
    test rax, rax
    jns .brp_count_ok
    xor eax, eax
.brp_count_ok:
    mov [rbp - BAO_ARG], rax
    imul rax, rdx
    jo .brp_toobig              ; as sq_inplace_repeat: the COUNT is what
    cmp rax, 0x10000000         ; OverflowError is for, and it was checked
    ja .brp_toobig
    mov rsi, rax
    xor edi, edi
    call bytearray_new
    test rax, rax
    jz .brp_fail
    mov [rbp - BAO_OUT], rax

    mov rdi, [rbp - BAO_SELF]
    call bytearray_data
    mov r9, rax                 ; the source
    mov rax, [rbp - BAO_OUT]
    mov r10, [rax + PyByteArrayObject.ob_bytes]
    xor ecx, ecx
.brp_loop:
    cmp rcx, [rbp - BAO_ARG]
    jge .brp_done
    mov rax, rcx
    imul rax, [rbp - BAO_SLEN]
    lea rdi, [r10 + rax]
    mov rsi, r9
    mov rdx, [rbp - BAO_SLEN]
    push rcx
    push r9
    push r10
    push r10
    call ap_memcpy
    pop r10
    pop r10
    pop r9
    pop rcx
    inc rcx
    jmp .brp_loop
.brp_done:
    mov rax, [rbp - BAO_OUT]
    mov edx, TAG_PTR
    leave
    ret
.brp_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
.brp_toobig:
    RAISE exc_MemoryError_type, ""
.brp_overflow:
    RAISE exc_OverflowError_type, "repeated bytes are too long"
END_FUNC bytearray_repeat

DEF_FUNC bytearray_inplace_concat, BAO_FRAME
    mov [rbp - BAO_SELF], rdi
    ; As sq_concat: a bytes-like only.
    mov [rbp - BAO_ARG], rsi
    mov rdi, rsi
    call bytes_like_ptr_len
    test ecx, ecx
    jz .bic2_not_impl
    ; Refused here rather than deeper down: bytearray_extend_from reports the
    ; block with a 0 return, and op_binary_op reads a slot's NULL as
    ; "declined" and reports "unsupported operand type(s)" -- burying the
    ; BufferError.  Only when there is actually something to append; `ba +=
    ; b""` changes no length and stays legal, as it does in CPython.
    test r10, r10
    jz .bic2_do_extend
    mov rdi, [rbp - BAO_SELF]
    BA_REFUSE_IF_EXPORTED rdi
.bic2_do_extend:
    mov rdi, [rbp - BAO_SELF]
    mov rsi, [rbp - BAO_ARG]
    call bytearray_extend_from
    test eax, eax
    jz .bic2_fail
    mov rax, [rbp - BAO_SELF]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
.bic2_not_impl:
    ; The same refusal sq_concat gives, and for the same reason: declining
    ; leaves the generic operand message, which says nothing about
    ; bytearray's rule.
    mov rsi, [rbp - BAO_ARG]
    CSTRING rdi, `can't concat \x01 to bytearray`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
.bic2_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC bytearray_inplace_concat

DEF_FUNC bytearray_inplace_repeat, BAO_FRAME
    mov [rbp - BAO_SELF], rdi
    BA_REFUSE_IF_EXPORTED rdi   ; its shrink-to-0 arm ignores the resize result
    ; The same funnel sq_repeat uses.  obj_as_index took anything with an
    ; __index__ but truncated a count past 2^63, so `b *= 2**64` emptied the
    ; bytearray, and it named the argument rather than saying what a count
    ; has to be.  A decline, so `b *= R()` still reaches R.__rmul__.
    mov [rbp - BAO_ARG], rsi
    mov rdi, rsi
    extern binop_is_count
    call binop_is_count
    test eax, eax
    jz .bir_fail
    mov rsi, [rbp - BAO_ARG]
    call seq_repeat_count
    mov rsi, rax
    mov [rbp - BAO_ARG], rsi
    mov rdi, [rbp - BAO_SELF]
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    mov [rbp - BAO_SLEN], rdx
    test rsi, rsi
    jg .bir_grow
    ; Zero or negative empties it, as it does for a list.
    mov rdi, [rbp - BAO_SELF]
    xor esi, esi
    call bytearray_resize
    jmp .bir_done
.bir_grow:
    mov rax, rsi
    imul rax, rdx
    ; The two checks sq_repeat has and this did not.  bytearray_resize hands
    ; the size to ap_malloc, which does not answer failure -- it calls
    ; fatal_error -- so `bytearray(b"ab") *= 2**40` printed "Fatal: out of
    ; memory" and ended the process where every other repetition in the tree
    ; raises MemoryError.
    ; A product that overflows is a MemoryError, not an OverflowError:
    ; CPython keeps OverflowError for a COUNT that will not fit an index,
    ; which obj_as_index above has already refused.
    jo .bir_toobig
    cmp rax, 0x10000000
    ja .bir_toobig
    mov rdi, [rbp - BAO_SELF]
    mov rsi, rax
    call bytearray_resize
    test eax, eax
    jz .bir_fail
    mov rdi, [rbp - BAO_SELF]
    call bytearray_data
    mov r10, rax
    mov ecx, 1                  ; copy 0 is already in place
.bir_loop:
    cmp rcx, [rbp - BAO_ARG]
    jge .bir_done
    mov rax, rcx
    imul rax, [rbp - BAO_SLEN]
    lea rdi, [r10 + rax]
    mov rsi, r10
    mov rdx, [rbp - BAO_SLEN]
    push rcx
    push r10
    call ap_memcpy
    pop r10
    pop rcx
    inc rcx
    jmp .bir_loop
.bir_done:
    mov rax, [rbp - BAO_SELF]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
.bir_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
.bir_toobig:
    RAISE exc_MemoryError_type, ""
END_FUNC bytearray_inplace_repeat




;; ============================================================================
;; bytearray_export_acquired(rdi = any source object or Value)
;; bytearray_export_released(rdi = the same)
;;
;; The BytesIO pair next door, for the other resizable buffer a memoryview can
;; point into.  Both are no-ops unless the source really is a bytearray, so
;; every memoryview site can call them unconditionally beside the io_buffer_*
;; ones; the two are mutually exclusive by type.
;; ============================================================================
DEF_FUNC_BARE bytearray_export_acquired
    test rdi, rdi
    jz .bea_out
    V_TEST_PTR rdi, rax
    ja .bea_out
    lea rax, [rel bytearray_type]
    cmp [rdi + PyObject.ob_type], rax
    jne .bea_out
    inc qword [rdi + PyByteArrayObject.ob_exports]
.bea_out:
    ret
END_FUNC bytearray_export_acquired

DEF_FUNC_BARE bytearray_export_released
    test rdi, rdi
    jz .ber_out
    V_TEST_PTR rdi, rax
    ja .ber_out
    lea rax, [rel bytearray_type]
    cmp [rdi + PyObject.ob_type], rax
    jne .ber_out
    cmp qword [rdi + PyByteArrayObject.ob_exports], 0
    jle .ber_out
    dec qword [rdi + PyByteArrayObject.ob_exports]
.ber_out:
    ret
END_FUNC bytearray_export_released

;; ============================================================================
;; bytearray_dealloc(obj)
;; ============================================================================
;; The buffer is a separate allocation now, so freeing the object is not
;; enough.  ob_bytes is NULL for an object whose constructor failed part way.
DEF_FUNC bytearray_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyByteArrayObject.ob_bytes]
    test rdi, rdi
    jz .bad_no_buf
    call ap_free
    mov qword [rbx + PyByteArrayObject.ob_bytes], 0
.bad_no_buf:
    mov rdi, rbx
    pop rbx
    leave
    jmp ap_free
END_FUNC bytearray_dealloc

;; ============================================================================
;; bytearray_len(obj) -> int64
;; ============================================================================
DEF_FUNC_BARE bytearray_len
    mov rax, [rdi + PyByteArrayObject.ob_size]
    ret
END_FUNC bytearray_len

;; ============================================================================
;; bytearray_tp_iter / bytearray_iter_next
;; A bytearray was not iterable at all, so `for b in ba` and every stdlib
;; census that does type(iter(bytearray())) stopped here.  Same shape as the
;; bytes iterator; the index is checked against the current length each time,
;; so a bytearray that shrinks under the iterator just ends early.
;; ============================================================================
DEF_FUNC bytearray_tp_iter, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov edi, PyBytesIterObject_size
    call ap_malloc
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel bytearray_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyBytesIterObject.it_seq], rbx
    mov qword [rax + PyBytesIterObject.it_index], 0
    inc qword [rbx + PyObject.ob_refcnt]
    pop rbx
    leave
    ret
END_FUNC bytearray_tp_iter

DEF_FUNC_BARE bytearray_iter_next
    mov rax, [rdi + PyBytesIterObject.it_seq]
    test rax, rax
    jz .exhausted               ; already dropped, or cleared by the collector
    mov rcx, [rdi + PyBytesIterObject.it_index]
    cmp rcx, [rax + PyByteArrayObject.ob_size]
    jge .exhausted_mark
    mov rax, [rax + PyByteArrayObject.ob_bytes]
    movzx eax, byte [rax + rcx]
    add rax, [rel v_int_bias]
    inc qword [rdi + PyBytesIterObject.it_index]
    ret
.exhausted_mark:
    ; Drop the bytearray at exhaustion, as bytes_iter_next does.
    mov rax, [rdi + PyBytesIterObject.it_seq]
    mov qword [rdi + PyBytesIterObject.it_seq], 0
    push rdi
    mov rdi, rax
    call obj_decref
    pop rdi
.exhausted:
    xor eax, eax
    ret
END_FUNC bytearray_iter_next

DEF_FUNC bytearray_iter_self
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    leave
    ret
END_FUNC bytearray_iter_self

DEF_FUNC bytearray_iter_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyBytesIterObject.it_seq]
    test rdi, rdi
    jz .free
    call obj_decref
.free:
    mov rdi, rbx
    call ap_free
    pop rbx
    leave
    ret
END_FUNC bytearray_iter_dealloc

;; ============================================================================
;; Type object
;; ============================================================================
section .data

align 8
ba_name_str:  db "bytearray", 0

align 8
align 8
bytearray_mapping_methods:
    dq bytearray_len            ; mp_length       +0
    dq bytearray_subscript      ; mp_subscript    +8
    dq bytearray_ass_subscript  ; mp_ass_subscript +16

align 8
bytearray_seq_methods:
    dq bytearray_len       ; +0: sq_length
    dq bytearray_concat    ; +8: sq_concat
    dq bytearray_repeat    ; +16: sq_repeat
    ; sq_item is what reversed() looks for: it walks a sequence backwards
    ; through sq_length and sq_item, and declines outright when either is 0.
    ; mp_subscript covers indexing itself, but not that.
    dq bytearray_getitem   ; +24: sq_item
    dq 0                   ; +32: sq_ass_item (mp_ass_subscript covers it)
    dq bytearray_contains  ; +40: sq_contains
    dq bytearray_inplace_concat ; +48
    dq bytearray_inplace_repeat ; +56

align 8
; bytearray's only numeric slot: `%`.  Everything else it does through
; tp_as_sequence.
bytearray_number_methods:
    dq 0                        ; nb_add          +0
    dq 0                        ; nb_subtract     +8
    dq 0                        ; nb_multiply     +16
    dq bytearray_mod            ; nb_remainder    +24
    times 32 dq 0               ; through nb_imatmul

align 8
global bytearray_type
bytearray_type:
    dq 1                            ; ob_refcnt
    dq type_type                    ; ob_type
    dq ba_name_str                  ; tp_name
    dq PyByteArrayObject_size       ; tp_basicsize (the data is out of line)
    dq bytearray_dealloc            ; tp_dealloc
    dq bytearray_repr               ; tp_repr
    dq bytearray_repr               ; tp_str
    ; Mutable, therefore unhashable.  A 0 here is not the same thing: obj_hash
    ; falls through to the object's ADDRESS, so `{bytearray(b"ab"): 1}` was
    ; accepted and the key could never be found again.
    dq hash_not_implemented         ; tp_hash
    dq 0                            ; tp_call (set by add_builtin_type)
    dq 0                            ; tp_getattr
    dq 0                            ; tp_setattr
    dq bytes_compare                ; tp_richcompare (shared with bytes)
    dq bytearray_tp_iter            ; tp_iter
    dq 0                            ; tp_iternext
    dq 0                            ; tp_init
    dq 0                            ; tp_new
    dq bytearray_number_methods     ; tp_as_number (just nb_remainder)
    dq bytearray_seq_methods        ; tp_as_sequence
    dq bytearray_mapping_methods    ; tp_as_mapping
    dq 0                            ; tp_base
    dq 0                            ; tp_dict
    dq 0                            ; tp_mro
    dq TYPE_FLAG_BASETYPE | TYPE_FLAG_BYTEARRAY_SUBCLASS           ; tp_flags (allow subclassing)
    dq 0                            ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; What bytearray_data hands back when ob_bytes is NULL, so no reader has to
; test for it.
align 8
global bytearray_empty_data
bytearray_empty_data: db 0

align 8
ba_iter_name_str: db "bytearray_iterator", 0

align 8
mv_iter_name_str: db "memory_iterator", 0

align 8
global memoryview_iter_type
memoryview_iter_type:
    dq 1                            ; ob_refcnt
    dq type_type                    ; ob_type
    dq mv_iter_name_str             ; tp_name
    dq PyBytesIterObject_size       ; tp_basicsize
    dq bytearray_iter_dealloc       ; tp_dealloc (the same shape)
    dq 0                            ; tp_repr
    dq 0                            ; tp_str
    dq 0                            ; tp_hash
    dq 0                            ; tp_call
    dq 0                            ; tp_getattr
    dq 0                            ; tp_setattr
    dq 0                            ; tp_richcompare
    dq bytearray_iter_self          ; tp_iter
    dq memoryview_iter_next         ; tp_iternext
    dq 0                            ; tp_init
    dq 0                            ; tp_new
    dq 0                            ; tp_as_number
    dq 0                            ; tp_as_sequence
    dq 0                            ; tp_as_mapping
    dq 0                            ; tp_base
    dq 0                            ; tp_dict
    dq 0                            ; tp_mro
    dq 0                            ; tp_flags
    dq 0                            ; tp_bases
    dq 0                            ; tp_traverse
    dq 0                            ; tp_clear
    dq 0                            ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

align 8
global bytearray_iter_type
bytearray_iter_type:
    dq 1                            ; ob_refcnt
    dq type_type                    ; ob_type
    dq ba_iter_name_str             ; tp_name
    dq PyBytesIterObject_size       ; tp_basicsize
    dq bytearray_iter_dealloc       ; tp_dealloc
    dq 0                            ; tp_repr
    dq 0                            ; tp_str
    dq 0                            ; tp_hash
    dq 0                            ; tp_call
    dq 0                            ; tp_getattr
    dq 0                            ; tp_setattr
    dq 0                            ; tp_richcompare
    dq bytearray_iter_self          ; tp_iter
    dq bytearray_iter_next          ; tp_iternext
    dq 0                            ; tp_init
    dq 0                            ; tp_new
    dq 0                            ; tp_as_number
    dq 0                            ; tp_as_sequence
    dq 0                            ; tp_as_mapping
    dq 0                            ; tp_base
    dq 0                            ; tp_dict
    dq 0                            ; tp_mro
    dq 0                            ; tp_flags
    dq 0                            ; tp_bases
    dq 0                            ; tp_traverse
    dq 0                            ; tp_clear
    dq 0                            ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

section .rodata
; The extended-slice assignment's two-part message, and the constructor's.
; The \x01 is raise_type_error_with_name's placeholder for the argument's type.
bas_msg_size: db "attempt to assign bytes of size ", 0
bas_msg_to:   db " to extended slice of size ", 0
bytearray_enc_msg: db `bytearray() argument 'encoding' must be str, not \x01`, 0
bytearray_arity_msg: db "bytearray() takes at most 3 arguments (", 0
bytearray_conv_msg: db `cannot convert '\x01' object to bytearray`, 0
