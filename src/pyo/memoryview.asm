; pyo/memoryview.asm - the memoryview type
;
; Split out of bytes.asm along with bytearray; see the note there.  A
; memoryview owns nothing: it borrows a buffer from a bytes or a bytearray and
; tells the owner when to let go again, which is why release() and the export
; count are as much of this file as the reading is.

%include "macros.inc"
%include "object.inc"
%include "value.inc"
extern ap_strcmp
extern bool_false
extern bool_true
extern bytearray_export_acquired
extern bytearray_export_released
extern bytearray_type
extern bytes_compare
extern bytes_from_data
extern bytes_like_ptr_len
extern bytes_method_hex
extern bytes_type
extern exc_NotImplementedError_type
extern exc_ValueError_type
extern hash_not_implemented
extern int_is_integer
extern io_buffer_acquired
extern io_buffer_released
extern list_append
extern list_new
extern memoryview_iter_type
extern mv_format_H
extern mv_format_I
extern mv_format_L
extern mv_format_Q
extern none_singleton
extern obj_as_index
extern obj_dealloc
extern str_from_cstr_heap
extern str_type
extern tuple_new
section .text

extern ap_malloc
extern ap_free
extern ap_memcpy
extern type_type
extern obj_incref
extern obj_decref
extern raise_exception
extern exc_TypeError_type
extern int_type
extern bool_type
extern exc_IndexError_type
extern int_to_i64
extern slice_type
extern slice_indices

section .text

;; ============================================================================
;; memoryview_type_call(type, args, nargs) -> PyMemoryViewObject*
;; Constructor: memoryview(bytes_obj)
;; ============================================================================
global memoryview_type_call
MV_ARG   equ 8              ; args[0] as it arrived, for the refusal
MV_BUF   equ 16             ; what a tp_as_buffer slot answered, held across
MV_LEN   equ 24             ;   the allocation and the acquire
MV_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC memoryview_type_call, MV_FRAME
    ; rdi=type, rsi=args, rdx=nargs
    cmp rdx, 1
    jne .mv_nargs_error
    mov rdi, [rsi]                     ; arg0 payload
    mov [rbp - MV_ARG], rdi
    ; Must be a bytes-like object (reject all non-pointer tags)
    V_TEST_PTR_M [rsi], r11      ; args[0] a pointer?
    ja .mv_error
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    jne .mv_check_bytearray

.mv_from_bytes:
    ; rdi = the source, bytes or bytearray
    push rdi
    mov edi, PyMemoryViewObject_size
    call ap_malloc
    pop rdi                            ; source

    ; Init header
    mov qword [rax + PyMemoryViewObject.ob_refcnt], 1
    lea rcx, [rel memoryview_type]
    mov [rax + PyMemoryViewObject.ob_type], rcx
    mov [rax + PyMemoryViewObject.mv_source], rdi
    push rax                           ; save result
    push rdi                           ; save for INCREF
    INCREF rdi
    ; A bytearray source counts this view, so a later resize can refuse.  The
    ; BytesIO sites below already do the equivalent through io_buffer_*; this
    ; arm called neither, which is the hole.
    call bytearray_export_acquired
    pop rdi
    pop rax

    ; A bytes keeps its data inline and a bytearray does not, so the two
    ; cannot share one read -- which is what this did while the layouts
    ; happened to match.
    push rax
    call bytes_like_ptr_len            ; rax = data, r10 = length
    mov rcx, rax
    pop rax
    mov [rax + PyMemoryViewObject.mv_buf], rcx
    mov [rax + PyMemoryViewObject.mv_len], r10

    ; A view starts out over single bytes, and is read-only exactly when its
    ; source is.
    mov qword [rax + PyMemoryViewObject.mv_itemsize], 1
    mov qword [rax + PyMemoryViewObject.mv_stride], 1
    lea rcx, [rel mv_format_B]
    mov [rax + PyMemoryViewObject.mv_format], rcx
    mov rcx, [rdi + PyObject.ob_type]
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    sete cl
    movzx ecx, cl
    mov [rax + PyMemoryViewObject.mv_readonly], rcx

    mov edx, TAG_PTR
    leave
    ret

.mv_check_bytearray:
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .mv_from_bytes
    lea rcx, [rel memoryview_type]
    cmp rax, rcx
    je .mv_from_view
    jmp .mv_error

.mv_from_view:
    ; memoryview(memoryview) shares the same window, as CPython's does -- but
    ; there is no window to share once the original has been released.
    call memoryview_check
    push rdi
    mov edi, PyMemoryViewObject_size
    call ap_malloc
    pop rdi
    mov qword [rax + PyMemoryViewObject.ob_refcnt], 1
    lea rcx, [rel memoryview_type]
    mov [rax + PyMemoryViewObject.ob_type], rcx
    mov rcx, [rdi + PyMemoryViewObject.mv_source]
    mov [rax + PyMemoryViewObject.mv_source], rcx
    test rcx, rcx
    jz .mv_view_no_src
    inc qword [rcx + PyObject.ob_refcnt]
    push rax
    push rdi
    mov rdi, rcx
    call mv_source_acquired     ; a second view is a second export, on every
    pop rdi                     ; counter the dealloc will decrement
    pop rax
.mv_view_no_src:
    mov rcx, [rdi + PyMemoryViewObject.mv_buf]
    mov [rax + PyMemoryViewObject.mv_buf], rcx
    mov rcx, [rdi + PyMemoryViewObject.mv_len]
    mov [rax + PyMemoryViewObject.mv_len], rcx
    mov rcx, [rdi + PyMemoryViewObject.mv_itemsize]
    mov [rax + PyMemoryViewObject.mv_itemsize], rcx
    mov rcx, [rdi + PyMemoryViewObject.mv_format]
    mov [rax + PyMemoryViewObject.mv_format], rcx
    mov rcx, [rdi + PyMemoryViewObject.mv_readonly]
    mov [rax + PyMemoryViewObject.mv_readonly], rcx
    mov rcx, [rdi + PyMemoryViewObject.mv_stride]
    mov [rax + PyMemoryViewObject.mv_stride], rcx
    mov edx, TAG_PTR
    leave
    ret

.mv_nargs_error:
    mov rsi, rdx
    CSTRING rdx, " given)"
    CSTRING rdi, "memoryview() takes at most 1 argument ("
    extern raise_type_error_counted
    jmp raise_type_error_counted

.mv_error:
    ; Before refusing, ask the TYPE.  bytes, bytearray and memoryview each have
    ; an arm above because each needs its own export accounting and its own
    ; readonly answer; anything else that can hand over a run of bytes says so
    ; through tp_as_buffer, and array is the first.
    mov rdi, [rbp - MV_ARG]
    V_TEST_PTR rdi, rax
    ja .mv_really_error
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_buffer]
    test rax, rax
    jnz .mv_from_slot

.mv_really_error:
    ; PEP 688: a class written in Python exports through __buffer__.
    mov rdi, [rbp - MV_ARG]
    call memoryview_from_dunder_buffer
    test rax, rax
    jnz .mv_dunder_done
    test ecx, ecx
    jnz .mv_dunder_done         ; it raised: 0, with the exception pending
    mov rsi, [rbp - MV_ARG]
    CSTRING rdi, `memoryview: a bytes-like object is required, not '\x01'`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
.mv_from_slot:
    ; The generic exporter road: a read-only view of one-byte items over
    ; whatever the slot points at.  Read-only because a buffer reached this way
    ; has told us where its bytes are and nothing about whether they may move
    ; -- array's can, when it grows -- so writing through the view is refused
    ; rather than silently aimed at a stale pointer.
    ;
    ; The buffer is fetched BEFORE the view is allocated, because the slot may
    ; decline: its ecx says whether it answered at all, and building a view
    ; around whatever was left in rax is how a declining exporter would have
    ; become a wild pointer.
    mov [rbp - MV_ARG], rdi
    mov rcx, [rdi + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_as_buffer]
    mov esi, BUF_GET
    call rcx                        ; rax = data, rdx = length, ecx = answered
    test ecx, ecx
    jz .mv_really_error
    mov [rbp - MV_BUF], rax
    mov [rbp - MV_LEN], rdx

    mov edi, PyMemoryViewObject_size
    call ap_malloc
    mov rdi, [rbp - MV_ARG]
    mov qword [rax + PyMemoryViewObject.ob_refcnt], 1
    lea rcx, [rel memoryview_type]
    mov [rax + PyMemoryViewObject.ob_type], rcx
    mov [rax + PyMemoryViewObject.mv_source], rdi
    push rax
    push rdi
    INCREF rdi                      ; the view holds its source
    pop rdi
    pop rax

    ; And the exporter counts it, so that a resize while this view is alive is
    ; refused rather than leaving the pointer below dangling.
    push rax
    push rax
    mov rcx, [rdi + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_as_buffer]
    mov esi, BUF_ACQUIRE
    call rcx
    pop rax
    pop rax

    mov r10, [rbp - MV_BUF]
    mov r11, [rbp - MV_LEN]
    mov [rax + PyMemoryViewObject.mv_buf], r10
    mov [rax + PyMemoryViewObject.mv_len], r11

    ; The defaults, and then the exporter's own answer if it has one.  An
    ; array's items are not bytes: without asking, memoryview(array("i", [1,
    ; 2, 3])) had itemsize 1, format "B", length 12 and tolist() of the
    ; twelve bytes.  An exporter that does not implement BUF_GETINFO answers
    ; 0 and keeps exactly what was assumed of every exporter before the mode
    ; existed.
    mov qword [rax + PyMemoryViewObject.mv_itemsize], 1
    mov qword [rax + PyMemoryViewObject.mv_stride], 1
    lea rcx, [rel mv_format_B]
    mov [rax + PyMemoryViewObject.mv_format], rcx
    mov qword [rax + PyMemoryViewObject.mv_readonly], 1

    push rax
    push rax                        ; an even count keeps rsp 16-aligned
    mov rdi, [rbp - MV_ARG]
    mov rcx, [rdi + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_as_buffer]
    mov esi, BUF_GETINFO
    call rcx                        ; rax = format cstr or 0, rdx = itemsize,
                                    ; ecx = 1 when writable
    mov r10, rax
    mov r11, rdx
    mov r8d, ecx
    pop rax
    pop rax
    test r10, r10
    jz .mv_slot_defaults
    mov [rax + PyMemoryViewObject.mv_format], r10
    mov [rax + PyMemoryViewObject.mv_itemsize], r11
    ; mv_stride stays 1: it is a multiplier in ITEMS, and 1 is what
    ; c_contiguous answers with -- not a byte stride.
    xor ecx, ecx
    test r8d, r8d
    jnz .mv_slot_writable
    mov ecx, 1
.mv_slot_writable:
    mov [rax + PyMemoryViewObject.mv_readonly], rcx
.mv_slot_defaults:
    mov edx, TAG_PTR
    leave
    ret
.mv_dunder_done:
    test rax, rax
    jz .mv_dunder_raised
    mov edx, TAG_PTR
    leave
    ret
.mv_dunder_raised:
    ; The exception __buffer__ left is carried out non-locally, as every other
    ; refusal in this constructor is.
    leave
    extern eval_exception_unwind
    jmp eval_exception_unwind
END_FUNC memoryview_type_call

;; ============================================================================
;; memoryview_from_dunder_buffer(rdi = an object Value) -> rax = an owned
;;   memoryview; or rax = 0 with ecx = 0 when its class has no __buffer__,
;;   or rax = 0 with ecx = 1 when __buffer__ raised or answered something
;;   that is not a memoryview (the exception is then pending)
;;
;; PEP 688's Python-level buffer protocol, which memoryview() and bytes() ask
;; after every C-level exporter has declined.  Only a heaptype can define it.
;; The view __buffer__ answers is handed on as it is, rather than wrapped in a
;; second one: every field a wrapper would copy is already right.
;; ============================================================================
MDB_OBJ   equ 8
MDB_ARGS  equ 32                ; [object, flags] at [rbp-32 .. rbp-16]
MDB_FRAME equ 32                ; + 0 pushes = 32, 16-aligned
global memoryview_from_dunder_buffer
DEF_FUNC memoryview_from_dunder_buffer, MDB_FRAME
    mov [rbp - MDB_OBJ], rdi
    V_TEST_PTR rdi, rax
    ja .mdb_none
    test rdi, rdi
    jz .mdb_none
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .mdb_none
    mov rdi, rax
    lea rsi, [rel mv_dunder_buffer]
    extern dunder_lookup
    call dunder_lookup
    test rax, rax
    jz .mdb_none
    mov rcx, [rbp - MDB_OBJ]
    mov [rbp - MDB_ARGS], rcx
    mov rcx, V_INT(0x11C)       ; PyBUF_FULL_RO, what CPython's memoryview asks
    mov [rbp - MDB_ARGS + 8], rcx
    mov rdi, rax
    lea rsi, [rbp - MDB_ARGS]
    mov edx, 2
    extern obj_call_n
    call obj_call_n
    test rax, rax
    jz .mdb_raised
    V_TEST_PTR rax, rcx
    ja .mdb_wrong
    lea rcx, [rel memoryview_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .mdb_wrong_ptr
    xor ecx, ecx
    leave
    ret
.mdb_wrong_ptr:
    mov rdi, rax
    call obj_decref
    jmp .mdb_wrong_msg
.mdb_wrong:
    DECREF_V rax, rcx
.mdb_wrong_msg:
    extern set_exception
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "__buffer__ returned non-memoryview object"
    call set_exception
.mdb_raised:
    xor eax, eax
    mov ecx, 1
    leave
    ret
.mdb_none:
    xor eax, eax
    xor ecx, ecx
    leave
    ret
END_FUNC memoryview_from_dunder_buffer


;; ============================================================================
;; mv_source_acquired(rdi = the object a derived view is now sharing)
;;   -> nothing
;;
;; The three counts an exporter may keep, taken together: bytearray's own,
;; BytesIO's own, and tp_as_buffer's BUF_ACQUIRE.
;;
;; memoryview_dealloc_proper releases all three unconditionally, so a
;; constructor that took only the first two left the slot's count one BELOW
;; what was outstanding -- and the exporter then allowed a resize under a live
;; view.  All three DERIVED constructors did: a slice, a cast, and a view of a
;; view.  `array.array` is the exporter that shows it, and lib/_io.py's
;; readinto does `b = b.cast("B")`, so it is the ordinary path and not a
;; corner.
;; ============================================================================
MSA_FRAME equ 8                 ; + 1 push: rsp is 16-aligned at every call
DEF_FUNC_LOCAL mv_source_acquired, MSA_FRAME
    push rbx
    mov rbx, rdi
    call bytearray_export_acquired
    mov rdi, rbx
    call io_buffer_acquired
    mov rcx, [rbx + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_as_buffer]
    test rcx, rcx
    jz .msa_no_slot
    mov rdi, rbx
    mov esi, BUF_ACQUIRE
    call rcx
.msa_no_slot:
    pop rbx
    leave
    ret
END_FUNC mv_source_acquired

;; Proper dealloc:
DEF_FUNC memoryview_dealloc_proper, 8            ; 1 pushes, so rsp is 16-aligned
    push rdi                           ; save self
    mov rdi, [rdi + PyMemoryViewObject.mv_source]
    test rdi, rdi
    jz .mvd_no_source                  ; already released
    push rdi
    call bytearray_export_released
    call io_buffer_released
    ; A source reached through the slot counts its exports there.  Released
    ; before the decref below, because that may be the source's last reference.
    mov rdi, [rsp]
    mov rcx, [rdi + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_as_buffer]
    test rcx, rcx
    jz .mvd_no_slot
    mov esi, BUF_RELEASE
    call rcx
.mvd_no_slot:
    pop rdi
    call obj_decref
.mvd_no_source:
    pop rdi                            ; restore self
    call ap_free
    leave
    ret
END_FUNC memoryview_dealloc_proper

;; ============================================================================
;; memoryview_check(rdi = self) -> returns, or raises
;;
;; Every operation on a released view raises, which is the whole point of
;; release(): it lets the buffer's owner resize again, so anything still
;; pointing into the old buffer has to be refused rather than read.
;; ============================================================================
DEF_FUNC_BARE memoryview_check
    cmp qword [rdi + PyMemoryViewObject.mv_buf], MV_RELEASED
    je memoryview_released_error
    ret
END_FUNC memoryview_check

DEF_FUNC memoryview_released_error
    RAISE exc_ValueError_type, "operation forbidden on released memoryview object"
END_FUNC memoryview_released_error

;; ============================================================================
;; memoryview_item_value(rdi = self, rsi = item index) -> rax = the item, as a
;;   complete Value
;;
;; It used to read itemsize bytes little-endian and unsigned and hand back a
;; bare integer, because that was all cast()'s five accepted formats needed --
;; and the three callers each stamped TAG_SMALLINT on it themselves.  With the
;; signed, float, bool and char codes the item is no longer always an int, so
;; the Value is built here and handed over whole.
;;
;; The signedness rule is the character's case, which is not a coincidence:
;; the struct module gives every signed code a lowercase letter and its
;; unsigned partner the uppercase one, and c/?/f/d are decided before it.
;; ============================================================================
MIV_SELF  equ 8
MIV_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC memoryview_item_value, MIV_FRAME
    mov r9, [rdi + PyMemoryViewObject.mv_itemsize]
    mov rcx, [rdi + PyMemoryViewObject.mv_format]
    movzx ecx, byte [rcx]
    MV_ITEM_ADDR rax, rdi, rsi, r8

    cmp cl, 'f'
    je .miv_f32
    cmp cl, 'd'
    je .miv_f64
    cmp cl, '?'
    je .miv_bool
    cmp cl, 'c'
    je .miv_char

    cmp cl, 'a'
    jb .miv_unsigned

    ; Signed.
    cmp r9, 1
    je .miv_s1
    cmp r9, 2
    je .miv_s2
    cmp r9, 4
    je .miv_s4
    mov rax, [rax]
    jmp .miv_int
.miv_s1:
    movsx rax, byte [rax]
    jmp .miv_int
.miv_s2:
    movsx rax, word [rax]
    jmp .miv_int
.miv_s4:
    movsxd rax, dword [rax]
    jmp .miv_int

.miv_unsigned:
    cmp r9, 1
    je .miv_u1
    cmp r9, 2
    je .miv_u2
    cmp r9, 4
    je .miv_u4
    ; Eight bytes unsigned is the one width that does not fit an i64: a Q of
    ; all-ones is 18446744073709551615, not -1, and packing it as signed would
    ; be a wrong ANSWER rather than an overflow.
    mov rax, [rax]
    test rax, rax
    js .miv_big
    jmp .miv_int
.miv_u1:
    movzx eax, byte [rax]
    jmp .miv_int
.miv_u2:
    movzx eax, word [rax]
    jmp .miv_int
.miv_u4:
    mov eax, [rax]                      ; a 32-bit load zero-extends
    jmp .miv_int

.miv_int:
    V_PACK_I64 rax, rcx
    leave
    ret

.miv_big:
    mov rdi, rax
    call mv_value_from_u64
    leave
    ret

.miv_f32:
    movss xmm0, [rax]
    cvtss2sd xmm0, xmm0
    movq rax, xmm0
    V_FROM_F64 rax, rcx
    leave
    ret

.miv_f64:
    mov rax, [rax]
    V_FROM_F64 rax, rcx
    leave
    ret

.miv_bool:
    movzx eax, byte [rax]
    test eax, eax
    jz .miv_false
    lea rax, [rel bool_true]
    leave
    ret
.miv_false:
    lea rax, [rel bool_false]
    leave
    ret

.miv_char:
    ; CPython's 'c' is a one-byte BYTES, not an int.
    mov rdi, rax                        ; the item's own address
    mov esi, 1
    extern bytes_from_data
    call bytes_from_data
    leave
    ret
END_FUNC memoryview_item_value

;; ============================================================================
;; mv_value_from_u64(rdi = an unsigned 64-bit value with its top bit set)
;;   -> rax = the value as a Value, or 0
;;
;; The magnitude is above 2**63, so it is not an i64 and not an immediate
;; either; GMP is the only place it fits.  Only reached for Q, L, N and P,
;; and only for the half of their range that a signed pack would answer
;; negative for.
;; ============================================================================
MVU_VAL   equ 8
MVU_M     equ 32            ; the mpz_t, which is 16 bytes
MVU_FRAME equ 56            ; + 1 push = 64, 16-aligned
DEF_FUNC_LOCAL mv_value_from_u64, MVU_FRAME
    push rbx
    mov [rbp - MVU_VAL], rdi
    lea rdi, [rbp - MVU_M]
    extern __gmpz_init
    call __gmpz_init wrt ..plt
    sub rsp, 16
    lea rax, [rbp - MVU_VAL]
    mov [rsp], rax                      ; the seventh argument: the source
    lea rdi, [rbp - MVU_M]
    mov esi, 8                           ; eight "words"...
    mov edx, -1                          ; ...least significant first
    mov ecx, 1                           ; one byte each
    xor r8d, r8d                         ; endian, irrelevant at size 1
    xor r9d, r9d                         ; no nails
    extern __gmpz_import
    call __gmpz_import wrt ..plt
    add rsp, 16

    xor edi, edi
    extern int_new_compact
    call int_new_compact
    test rax, rax
    jz .mvu_fail
    mov rbx, rax
    extern int_promote_mpz
    INT_NEED_MPZ rbx
    lea rdi, [rbx + PyIntObject.mpz]
    lea rsi, [rbp - MVU_M]
    extern __gmpz_set
    call __gmpz_set wrt ..plt
    lea rdi, [rbp - MVU_M]
    extern __gmpz_clear
    call __gmpz_clear wrt ..plt
    mov rdi, rbx
    extern int_shrink
    call int_shrink
    pop rbx
    leave
    ret
.mvu_fail:
    lea rdi, [rbp - MVU_M]
    call __gmpz_clear wrt ..plt
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC mv_value_from_u64

;; ============================================================================
;; memoryview_hash(rdi = self) -> rax = the hash
;;
;; A view over a READ-ONLY buffer hashes as the bytes it holds, which is what
;; makes one usable as a dict key without copying; one over a writable buffer
;; cannot, because the value would change under the table.  This answered
;; "unhashable type: 'memoryview'" for both, which is neither.
;; ============================================================================
DEF_FUNC memoryview_hash, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    call memoryview_check
    cmp qword [rbx + PyMemoryViewObject.mv_readonly], 0
    je .mvh_writable
    ; CPython restricts hashing to the byte-shaped formats, and it is not
    ; fussiness: the hash is over the raw bytes, so two views that compare
    ; EQUAL under a wider format -- which compares items -- would have to hash
    ; the same, and over the raw bytes they need not.
    mov rcx, [rbx + PyMemoryViewObject.mv_format]
    movzx ecx, byte [rcx]
    cmp cl, 'B'
    je .mvh_ok
    cmp cl, 'b'
    je .mvh_ok
    cmp cl, 'c'
    jne .mvh_badfmt
.mvh_ok:
    mov rdi, rbx
    call memoryview_as_bytes
    test rax, rax
    jz .mvh_fail
    push rax
    mov rdi, rax
    extern bytes_hash
    call bytes_hash
    mov rbx, rax
    pop rdi
    call obj_decref
    mov rax, rbx
    pop rbx
    leave
    ret
.mvh_badfmt:
    RAISE exc_ValueError_type, \
        "memoryview: hashing is restricted to formats 'B', 'b' or 'c'"

.mvh_fail:
    xor eax, eax
    pop rbx
    leave
    ret
.mvh_writable:
    RAISE exc_ValueError_type, "cannot hash writable memoryview object"
END_FUNC memoryview_hash

;; ============================================================================
;; memoryview_as_bytes(rdi = self) -> rax = a new bytes with the view's items
;; laid out contiguously, or 0.  What tobytes(), hex() and every comparison
;; need, and the only way a strided view can hand its contents to anything
;; that reads a pointer and a length.
;; ============================================================================
global memoryview_as_bytes
DEF_FUNC memoryview_as_bytes
    ; A released view answers no questions -- that is what release() is for --
    ; and `bytes(m)` reached this straight from bytes_type_call, which read a
    ; buffer that is no longer there.  Asked before the pushes, so the raise
    ; leaves nothing on this frame.
    call memoryview_check
    push rbx
    push r12
    mov rbx, rdi
    mov rdi, [rbx + PyMemoryViewObject.mv_len]
    extern bytes_new
    call bytes_new
    test rax, rax
    jz .mab_done
    mov r12, rax
    mov rdi, rbx
    lea rsi, [r12 + PyBytesObject.data]
    call memoryview_copy_out
    mov rax, r12
.mab_done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC memoryview_as_bytes

;; ============================================================================
;; memoryview_richcompare(rdi = left Value, rsi = right Value, edx = op)
;;
;; bytes_compare over the shared (pointer, length) reader is the whole of it
;; for a contiguous view.  A strided one has no pointer to give, so it is
;; copied out first -- either side may be one, since a comparison between two
;; views reaches here twice.
;; ============================================================================
MRC_LEFT  equ 8
MRC_RIGHT equ 16
MRC_TL    equ 24             ; the temporaries, to release
MRC_TR    equ 32
MRC_OP    equ 40
MRC_FRAME equ 48            ; 40 used + 8 pad = 48, 16-aligned
DEF_FUNC memoryview_richcompare, MRC_FRAME
    mov [rbp - MRC_LEFT], rdi
    mov [rbp - MRC_RIGHT], rsi
    mov [rbp - MRC_OP], rdx
    mov qword [rbp - MRC_TL], 0
    mov qword [rbp - MRC_TR], 0

    mov rdi, [rbp - MRC_LEFT]
    call mrc_substitute
    test rax, rax
    jz .mrc_left_done
    mov [rbp - MRC_TL], rax
    mov [rbp - MRC_LEFT], rax
.mrc_left_done:
    mov rdi, [rbp - MRC_RIGHT]
    call mrc_substitute
    test rax, rax
    jz .mrc_right_done
    mov [rbp - MRC_TR], rax
    mov [rbp - MRC_RIGHT], rax
.mrc_right_done:

    mov rdi, [rbp - MRC_LEFT]
    mov rsi, [rbp - MRC_RIGHT]
    mov rdx, [rbp - MRC_OP]
    call bytes_compare
    push rax
    push rdx
    mov rdi, [rbp - MRC_TL]
    test rdi, rdi
    jz .mrc_no_tl
    call obj_decref
.mrc_no_tl:
    mov rdi, [rbp - MRC_TR]
    test rdi, rdi
    jz .mrc_no_tr
    call obj_decref
.mrc_no_tr:
    pop rdx
    pop rax
    leave
    ret
END_FUNC memoryview_richcompare

;; mrc_substitute(rdi = a Value) -> rax = a bytes standing in for it, owned,
;; or 0 when it is not a strided memoryview and can be compared as it is.
DEF_FUNC_LOCAL mrc_substitute
    V_TEST_PTR rdi, rcx
    ja .mrs_no
    test rdi, rdi
    jz .mrs_no
    mov rcx, [rdi + PyObject.ob_type]
    lea rdx, [rel memoryview_type]
    cmp rcx, rdx
    jne .mrs_no
    cmp qword [rdi + PyMemoryViewObject.mv_buf], MV_RELEASED
    je .mrs_no
    cmp qword [rdi + PyMemoryViewObject.mv_stride], 1
    je .mrs_no
    call memoryview_as_bytes
    leave
    ret
.mrs_no:
    xor eax, eax
    leave
    ret
END_FUNC mrc_substitute

;; ============================================================================
;; memoryview_copy_out(rdi = self, rsi = destination) -> rax = bytes written
;;
;; The view's items laid out contiguously, which is what tobytes(), bytes(),
;; hex() and every comparison want.  A contiguous view is one memcpy; a
;; strided one is a walk, because there is no contiguous run to copy.
;; ============================================================================
MCO_SELF equ 8
MCO_DST  equ 16
MCO_I    equ 24
MCO_N    equ 32
MCO_FRAME equ 48            ; 32 used + 16 pad = 48, 16-aligned
global memoryview_copy_out
DEF_FUNC memoryview_copy_out, MCO_FRAME
    mov [rbp - MCO_SELF], rdi
    mov [rbp - MCO_DST], rsi

    cmp qword [rdi + PyMemoryViewObject.mv_stride], 1
    jne .mco_strided
    mov rdx, [rdi + PyMemoryViewObject.mv_len]
    test rdx, rdx
    jz .mco_done_len
    mov rdi, rsi
    mov rsi, [rbp - MCO_SELF]
    mov rsi, [rsi + PyMemoryViewObject.mv_buf]
    call ap_memcpy
    jmp .mco_done_len

.mco_strided:
    call memoryview_nitems
    mov [rbp - MCO_N], rax
    mov qword [rbp - MCO_I], 0
.mco_loop:
    mov rcx, [rbp - MCO_I]
    cmp rcx, [rbp - MCO_N]
    jge .mco_done_len
    mov rdi, [rbp - MCO_SELF]
    MV_ITEM_ADDR rsi, rdi, rcx, r8
    mov rdx, [rdi + PyMemoryViewObject.mv_itemsize]
    mov rdi, [rbp - MCO_DST]
    mov rax, [rbp - MCO_I]
    imul rax, rdx
    add rdi, rax
    push rdx
    call ap_memcpy
    pop rdx
    inc qword [rbp - MCO_I]
    jmp .mco_loop

.mco_done_len:
    mov rdi, [rbp - MCO_SELF]
    mov rax, [rdi + PyMemoryViewObject.mv_len]
    leave
    ret
END_FUNC memoryview_copy_out

;; ============================================================================
;; memoryview_getattr(rdi = self, rsi = name str) -> rax = Value, or NULL
;;
;; tp_getattr was 0, so a memoryview had no attributes and no methods at all.
;; _pyio reads nbytes and readonly, calls tobytes and cast, and uses `with
;; memoryview(b) as view:` around every readinto.
;;
;; NULL for an unknown name rather than a raise, so op_load_attr falls through
;; to the MRO's tp_dicts -- the contract every other tp_getattr keeps.
;; ============================================================================
MVG_SELF  equ 8
MVG_NAME  equ 16
MVG_FRAME equ 32            ; + 0 pushes = 32

%macro MVG_NAME_IS 2            ; %1 = the C string, %2 = the label
    mov rdi, [rbp - MVG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, %1
    call ap_strcmp
    test eax, eax
    jz %2
%endmacro

DEF_FUNC memoryview_getattr, MVG_FRAME
    mov [rbp - MVG_SELF], rdi
    mov [rbp - MVG_NAME], rsi

    MVG_NAME_IS "nbytes",       .mvg_nbytes
    MVG_NAME_IS "itemsize",     .mvg_itemsize
    MVG_NAME_IS "format",       .mvg_format
    MVG_NAME_IS "readonly",     .mvg_readonly
    MVG_NAME_IS "obj",          .mvg_obj
    MVG_NAME_IS "ndim",         .mvg_ndim
    MVG_NAME_IS "shape",        .mvg_shape
    MVG_NAME_IS "strides",      .mvg_strides
    MVG_NAME_IS "suboffsets",   .mvg_suboffsets
    ; Contiguous unless the view has a stride, which `mv[::2]` and `mv[::-1]`
    ; give it.  All three answered True unconditionally, back when a strided
    ; view could not be built at all.
    MVG_NAME_IS "c_contiguous", .mvg_contiguous
    MVG_NAME_IS "f_contiguous", .mvg_contiguous
    MVG_NAME_IS "contiguous",   .mvg_contiguous

    ; Not an attribute of ours: the methods live in tp_dict.
    RET_NULL
    leave
    V_PACK rax, rdx
    ret

.mvg_contiguous:
    mov rdi, [rbp - MVG_SELF]
    cmp qword [rdi + PyMemoryViewObject.mv_stride], 1
    je .mvg_true
    RET_FALSE
    leave
    V_PACK rax, rdx
    ret

.mvg_nbytes:
    mov rdi, [rbp - MVG_SELF]
    call memoryview_check
    mov rdi, [rbp - MVG_SELF]
    mov rax, [rdi + PyMemoryViewObject.mv_len]
    jmp .mvg_int

.mvg_itemsize:
    mov rdi, [rbp - MVG_SELF]
    call memoryview_check
    mov rdi, [rbp - MVG_SELF]
    mov rax, [rdi + PyMemoryViewObject.mv_itemsize]
    jmp .mvg_int

.mvg_ndim:
    mov eax, 1
.mvg_int:
    V_PACK_I64 rax, rcx
    mov edx, TAG_PTR
    leave
    ret

.mvg_format:
    mov rdi, [rbp - MVG_SELF]
    call memoryview_check
    mov rdi, [rbp - MVG_SELF]
    mov rdi, [rdi + PyMemoryViewObject.mv_format]
    call str_from_cstr_heap
    leave
    ret

.mvg_readonly:
    mov rdi, [rbp - MVG_SELF]
    call memoryview_check
    mov rdi, [rbp - MVG_SELF]
    cmp qword [rdi + PyMemoryViewObject.mv_readonly], 0
    jne .mvg_true
    lea rax, [rel bool_false]
    jmp .mvg_bool_out
.mvg_true:
    lea rax, [rel bool_true]
.mvg_bool_out:
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret

.mvg_obj:
    ; A released view has no .obj to report, and CPython refuses rather than
    ; answering None -- the source is exactly what release() let go of.
    mov rdi, [rbp - MVG_SELF]
    call memoryview_check
    mov rdi, [rbp - MVG_SELF]
    mov rax, [rdi + PyMemoryViewObject.mv_source]
    test rax, rax
    jz .mvg_none
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
.mvg_none:
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret

.mvg_shape:
    ; One dimension, so a 1-tuple of the item count.
    mov rdi, [rbp - MVG_SELF]
    call memoryview_check
    mov edi, 1
    call tuple_new
    test rax, rax
    jz .mvg_none
    mov [rbp - MVG_NAME], rax          ; the name is finished with
    mov rdi, [rbp - MVG_SELF]
    mov rax, [rdi + PyMemoryViewObject.mv_len]
    xor edx, edx
    div qword [rdi + PyMemoryViewObject.mv_itemsize]
    V_PACK_I64 rax, rcx
    mov rcx, [rbp - MVG_NAME]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx], rax
    mov rax, [rbp - MVG_NAME]
    mov edx, TAG_PTR
    leave
    ret

.mvg_strides:
    ; The distance between items, in BYTES: the item size times the view's own
    ; stride, which an extended slice sets.  Reporting the item size alone
    ; made `memoryview(b)[::2].strides` (1,) where CPython says (2,) -- and
    ; the whole point of the field is to say how far apart the items are.
    mov rdi, [rbp - MVG_SELF]
    call memoryview_check
    mov edi, 1
    call tuple_new
    test rax, rax
    jz .mvg_none
    mov [rbp - MVG_NAME], rax
    mov rdi, [rbp - MVG_SELF]
    mov rax, [rdi + PyMemoryViewObject.mv_itemsize]
    imul rax, [rdi + PyMemoryViewObject.mv_stride]
    V_PACK_I64 rax, rcx
    mov rcx, [rbp - MVG_NAME]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx], rax
    mov rax, [rbp - MVG_NAME]
    mov edx, TAG_PTR
    leave
    ret

.mvg_suboffsets:
    xor edi, edi
    call tuple_new
    mov edx, TAG_PTR
    leave
    ret
END_FUNC memoryview_getattr

;; ============================================================================
;; memoryview_repr(rdi = self, edx = tag) -> a str
;;
;; tp_repr was 0, so printing one reached obj_repr's fallback and raised
;; "build_string expects str".
;; ============================================================================
DEF_FUNC memoryview_repr
    cmp qword [rdi + PyMemoryViewObject.mv_buf], MV_RELEASED
    je .mvr_released
    CSTRING rdi, "<memory>"
    call str_from_cstr_heap
    leave
    ret
.mvr_released:
    CSTRING rdi, "<released memory>"
    call str_from_cstr_heap
    leave
    ret
END_FUNC memoryview_repr

;; ============================================================================
;; The methods.  Each takes (rdi = args Value[], rsi = nargs), args[0] = self.
;; ============================================================================
MVM_SELF  equ 8
MVM_ARG   equ 16
MVM_TMP   equ 24
MVM_FRAME equ 32            ; + 0 pushes = 32

DEF_FUNC memoryview_method_tobytes, MVM_FRAME
    test rsi, rsi
    jz .mvt_argerr
    mov rdi, [rdi]
    mov [rbp - MVM_SELF], rdi
    call memoryview_check
    ; A strided view has no contiguous run to hand over, so the bytes are
    ; built empty and filled item by item.
    mov rdi, [rbp - MVM_SELF]
    mov rdi, [rdi + PyMemoryViewObject.mv_len]
    extern bytes_new
    call bytes_new
    test rax, rax
    jz .mvt_fail
    push rax
    mov rdi, [rbp - MVM_SELF]
    lea rsi, [rax + PyBytesObject.data]
    call memoryview_copy_out
    pop rax
    mov edx, TAG_PTR
    leave
    ret
.mvt_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
.mvt_argerr:
    RAISE exc_TypeError_type, "tobytes() takes no arguments"
END_FUNC memoryview_method_tobytes

;; ============================================================================
;; memoryview_method_toreadonly(rdi = args Value[], rsi = nargs)
;;   -> (rax = a read-only view over the same window, rdx = TAG_PTR)
;;
;; _pyio hands a caller a view of its buffer this way, and without it the
;; caller could write through it.  The copy is memoryview(memoryview)'s, with
;; the one field changed.
;; ============================================================================
DEF_FUNC memoryview_method_toreadonly, MVM_FRAME
    test rsi, rsi
    jz .mvro_argerr
    mov rdi, [rdi]
    mov [rbp - MVM_SELF], rdi
    call memoryview_check
    mov rdi, [rbp - MVM_SELF]
    mov rsi, rdi
    lea rdi, [rel memoryview_type]
    mov edx, 1                      ; nargs
    lea rsi, [rbp - MVM_SELF]
    call memoryview_type_call
    V_UNPACK rax, rdx
    test rax, rax
    jz .mvro_fail
    mov qword [rax + PyMemoryViewObject.mv_readonly], 1
    mov edx, TAG_PTR
    leave
    ret
.mvro_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
.mvro_argerr:
    RAISE exc_TypeError_type, "toreadonly() takes no arguments"
END_FUNC memoryview_method_toreadonly

DEF_FUNC memoryview_method_release, MVM_FRAME
    test rsi, rsi
    jz .mvrl_argerr
    mov rdi, [rdi]
    ; Releasing twice is not an error, as CPython has it.
    cmp qword [rdi + PyMemoryViewObject.mv_buf], MV_RELEASED
    je .mvrl_done
    mov qword [rdi + PyMemoryViewObject.mv_buf], MV_RELEASED
    mov rax, [rdi + PyMemoryViewObject.mv_source]
    mov qword [rdi + PyMemoryViewObject.mv_source], 0
    test rax, rax
    jz .mvrl_done
    push rax                    ; io_buffer_released returns in rax, so the
    push rax                    ; source has to survive the calls; and a pad
    mov rdi, rax
    call bytearray_export_released
    call io_buffer_released     ; a BytesIO counts its live views
    ; And tp_as_buffer's own count, which the dealloc releases and this did
    ; not -- so `m.release()` and `with memoryview(a):` left an array pinned
    ; for good, and the append after them was a BufferError where CPython
    ; allows it.  mv_source was zeroed above, so the dealloc will not release
    ; it a second time.
    mov rdi, [rsp]
    mov rcx, [rdi + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_as_buffer]
    test rcx, rcx
    jz .mvrl_no_slot
    mov esi, BUF_RELEASE
    call rcx
.mvrl_no_slot:
    pop rdi
    pop rdi
    call obj_decref
.mvrl_done:
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
.mvrl_argerr:
    RAISE exc_TypeError_type, "release() takes no arguments"
END_FUNC memoryview_method_release

;; __enter__ hands the view back; __exit__ releases it.  `with memoryview(b)
;; as view:` is how _pyio wraps every readinto.
DEF_FUNC memoryview_method_enter, MVM_FRAME
    test rsi, rsi
    jz .mve_argerr
    mov rax, [rdi]
    push rax
    mov rdi, rax
    call memoryview_check
    pop rax
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
.mve_argerr:
    RAISE exc_TypeError_type, "__enter__() takes no arguments"
END_FUNC memoryview_method_enter

DEF_FUNC memoryview_method_exit, MVM_FRAME
    test rsi, rsi
    jz .mvx_argerr
    mov esi, 1
    call memoryview_method_release
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
.mvx_argerr:
    RAISE exc_TypeError_type, "__exit__() takes three arguments"
END_FUNC memoryview_method_exit

;; memoryview.cast(fmt) -- what re._compiler._bytes_to_codes calls with 'I'.
MVC_SELF  equ 8
MVC_FMT   equ 16
MVC_SIZE  equ 24
MVC_STR   equ 32
MVC_FRAME equ 48            ; + 0 pushes = 48

DEF_FUNC memoryview_method_cast, MVC_FRAME
    cmp rsi, 2
    jl .mvc_argerr
    mov rax, [rdi]
    mov [rbp - MVC_SELF], rax
    mov rcx, [rdi + 8]
    mov [rbp - MVC_STR], rcx
    mov rdi, rax
    call memoryview_check

    ; A cast reinterprets a contiguous run of bytes, so a strided view has
    ; nothing to cast; CPython refuses it with this wording.
    mov rdi, [rbp - MVC_SELF]
    cmp qword [rdi + PyMemoryViewObject.mv_stride], 1
    jne .mvc_not_contiguous

    ; One character, and only the unsigned formats: those are what
    ; memoryview_item_value reads, and what CPython's own callers use here.
    mov rcx, [rbp - MVC_STR]
    V_TEST_PTR rcx, rax
    ja .mvc_badfmt
    mov rax, [rcx + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rax, rdx
    jne .mvc_badfmt
    cmp qword [rcx + PyStrObject.ob_size], 1
    jne .mvc_badfmt
    movzx eax, byte [rcx + PyStrObject.data]

    lea rcx, [rel mv_format_table]
.mvc_scan:
    movzx edx, byte [rcx]
    test dl, dl
    jz .mvc_badfmt
    cmp dl, al
    je .mvc_row
    add rcx, 16
    jmp .mvc_scan
.mvc_row:
    movzx esi, byte [rcx + 1]           ; the itemsize
    mov rdx, [rcx + 8]                  ; the string the view reports
.mvc_have_fmt:
    mov [rbp - MVC_SIZE], rsi
    mov [rbp - MVC_FMT], rdx

    ; The byte length must divide evenly, as CPython requires.
    mov rdi, [rbp - MVC_SELF]
    mov rax, [rdi + PyMemoryViewObject.mv_len]
    xor edx, edx
    div qword [rbp - MVC_SIZE]
    test rdx, rdx
    jnz .mvc_badlen

    mov edi, PyMemoryViewObject_size
    call ap_malloc
    test rax, rax
    jz .mvc_badlen
    mov qword [rax + PyMemoryViewObject.ob_refcnt], 1
    lea rcx, [rel memoryview_type]
    mov [rax + PyMemoryViewObject.ob_type], rcx
    mov rdi, [rbp - MVC_SELF]
    mov rcx, [rdi + PyMemoryViewObject.mv_source]
    mov [rax + PyMemoryViewObject.mv_source], rcx
    test rcx, rcx
    jz .mvc_no_src
    inc qword [rcx + PyObject.ob_refcnt]
    ; cast() is the fourth place a view takes a share of another's source, and
    ; release and dealloc decrement for every view that has one -- so without
    ; the matching acquire this view's release drove a BytesIO's export count
    ; below what is outstanding, and the next write reallocated the storage
    ; underneath it.  lib/_io.py's readinto does `b = b.cast("B")`, so it is
    ; on the ordinary path, not a corner.
    push rax
    push rdi
    mov rdi, rcx
    call mv_source_acquired
    pop rdi
    pop rax
.mvc_no_src:
    mov rcx, [rdi + PyMemoryViewObject.mv_buf]
    mov [rax + PyMemoryViewObject.mv_buf], rcx
    mov rcx, [rdi + PyMemoryViewObject.mv_len]
    mov [rax + PyMemoryViewObject.mv_len], rcx
    mov rcx, [rdi + PyMemoryViewObject.mv_readonly]
    mov [rax + PyMemoryViewObject.mv_readonly], rcx
    mov rcx, [rbp - MVC_SIZE]
    mov [rax + PyMemoryViewObject.mv_itemsize], rcx
    mov rcx, [rbp - MVC_FMT]
    mov [rax + PyMemoryViewObject.mv_format], rcx
    ; cast() is refused on a non-contiguous view below, so this is always 1.
    mov qword [rax + PyMemoryViewObject.mv_stride], 1
    mov edx, TAG_PTR
    leave
    ret

.mvc_not_contiguous:
    RAISE exc_TypeError_type, "memoryview: casts are restricted to C-contiguous views"
.mvc_badfmt:
    RAISE exc_ValueError_type, "memoryview: destination format must be a native single character format prefixed with an optional '@'"
.mvc_badlen:
    RAISE exc_TypeError_type, "memoryview: length is not a multiple of itemsize"
.mvc_argerr:
    RAISE exc_TypeError_type, "cast() takes at least 1 argument"
END_FUNC memoryview_method_cast

;; memoryview.tolist() and .hex()
MVL_SELF  equ 8
MVL_OUT   equ 16
MVL_N     equ 24
MVL_FRAME equ 32            ; + 1 push = 40

DEF_FUNC memoryview_method_tolist, 40
    push rbx
    test rsi, rsi
    jz .mvtl_argerr
    mov rdi, [rdi]
    mov [rbp - MVL_SELF], rdi
    call memoryview_check
    mov rdi, [rbp - MVL_SELF]
    mov rax, [rdi + PyMemoryViewObject.mv_len]
    xor edx, edx
    div qword [rdi + PyMemoryViewObject.mv_itemsize]
    mov [rbp - MVL_N], rax
    xor edi, edi
    call list_new
    test rax, rax
    jz .mvtl_fail
    mov [rbp - MVL_OUT], rax
    xor ebx, ebx
.mvtl_loop:
    cmp rbx, [rbp - MVL_N]
    jge .mvtl_done
    mov rdi, [rbp - MVL_SELF]
    mov rsi, rbx
    call memoryview_item_value
    mov rsi, rax
    mov rdi, [rbp - MVL_OUT]
    push rsi
    push rsi
    call list_append
    pop rsi
    pop rsi
    DECREF_V rsi, rcx           ; V_PACK may have boxed it
    inc rbx
    jmp .mvtl_loop
.mvtl_done:
    mov rax, [rbp - MVL_OUT]
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.mvtl_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.mvtl_argerr:
    RAISE exc_TypeError_type, "tolist() takes no arguments"
END_FUNC memoryview_method_tolist

;; ============================================================================
;; memoryview iteration.  tp_iter was 0, so `for b in mv` and list(mv) both
;; failed -- and _pyio iterates a view in more than one place.  The index is
;; checked against the current length each time, as the bytes iterator does.
;; ============================================================================
DEF_FUNC memoryview_tp_iter, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    call memoryview_check
    mov edi, PyBytesIterObject_size
    call ap_malloc
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel memoryview_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyBytesIterObject.it_seq], rbx
    mov qword [rax + PyBytesIterObject.it_index], 0
    inc qword [rbx + PyObject.ob_refcnt]
    pop rbx
    leave
    ret
END_FUNC memoryview_tp_iter

;; ============================================================================
;; memoryview_method_hex(rdi = args, rsi = nargs) -> rax = Value
;;
;; Through a temporary bytes, as bytearray's read-only methods do, for the
;; same reason: bytes_method_hex reads a bytes layout.  The separator and
;; the group size go through with it -- they were dropped here, so
;; `memoryview(b"abcd").hex(":")` answered without any separators.
;; ============================================================================
MVH_TMP   equ 8
MVH_ARGS  equ 40            ; three Values: the temporary bytes and the two
                            ; optional arguments, ending here
MVH_NARGS equ 48
MVH_FRAME equ 64            ; + 0 pushes = 64, 16-aligned

DEF_FUNC memoryview_method_hex, MVH_FRAME
    test rsi, rsi
    jz .mvh_argerr
    cmp rsi, 3
    ja .mvh_too_many
    lea rdx, [rsi - 1]          ; how many beyond self
    lea rsi, [rdi + 8]          ; and where they start
    mov rdi, [rdi]
    push rsi
    push rdx
    call memoryview_check
    pop rdx
    pop rsi
    call memoryview_method_hex_self
    leave
    ret
.mvh_argerr:
    RAISE exc_TypeError_type, "hex() takes no arguments"
.mvh_too_many:
    RAISE exc_TypeError_type, "hex() takes at most 2 arguments"
END_FUNC memoryview_method_hex

DEF_FUNC memoryview_method_hex_self, MVH_FRAME
    ; rdi = the memoryview, rsi = the arguments beyond self, rdx = how many.
    mov [rbp - MVH_NARGS], rdx
    xor eax, eax
    cmp rdx, 1
    jb .mvhs_have_extra
    mov rax, [rsi]
.mvhs_have_extra:
    mov [rbp - MVH_ARGS + 8], rax
    xor eax, eax
    cmp rdx, 2
    jb .mvhs_have_extra2
    mov rax, [rsi + 8]
.mvhs_have_extra2:
    mov [rbp - MVH_ARGS + 16], rax
    call memoryview_as_bytes
    test rax, rax
    jz .mvhs_fail
    mov [rbp - MVH_TMP], rax
    mov [rbp - MVH_ARGS], rax
    lea rdi, [rbp - MVH_ARGS]
    mov rsi, [rbp - MVH_NARGS]
    inc rsi                     ; plus the temporary bytes standing in for self
    call bytes_method_hex
    push rax
    push rax
    mov rdi, [rbp - MVH_TMP]
    call obj_decref
    pop rax
    pop rax
    mov edx, TAG_PTR
    leave
    ret
.mvhs_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC memoryview_method_hex_self

DEF_FUNC_BARE memoryview_iter_next
    mov rax, [rdi + PyBytesIterObject.it_seq]
    cmp qword [rax + PyMemoryViewObject.mv_buf], MV_RELEASED
    je .mvin_done
    mov rcx, [rdi + PyBytesIterObject.it_index]
    mov rdx, [rax + PyMemoryViewObject.mv_len]
    push rdi
    push rax
    mov r8, [rax + PyMemoryViewObject.mv_itemsize]
    mov rax, rdx
    xor edx, edx
    div r8                      ; the item count
    pop rdi                     ; the view
    cmp rcx, rax
    jge .mvin_pop_done
    mov rsi, rcx
    call memoryview_item_value
    pop rdi                     ; the iterator
    inc qword [rdi + PyBytesIterObject.it_index]
    ret
.mvin_pop_done:
    pop rdi
.mvin_done:
    xor eax, eax
    ret
END_FUNC memoryview_iter_next




;; ============================================================================
;; memoryview_subscript(obj, key) -> PyMemoryViewObject* (slice)
;; ============================================================================
MS_OBJ   equ 8
MS_KEY   equ 16
MS_START equ 24
MS_COUNT equ 32
MS_STEP  equ 40
MS_FRAME equ 48             ; 40 used + 8 pad = 48, + 0 pushes
DEF_FUNC memoryview_subscript, MS_FRAME
    ; A view indexes in ITEMS, not bytes.  They are the same thing until
    ; cast() has been called, which is why the byte length stood in for the
    ; item count here and the count was one divide away from being wrong.
    mov [rbp - MS_OBJ], rdi
    call memoryview_check
    V_UNPACK rsi, rdx           ; key Value -> (payload, tag)
    mov [rbp - MS_KEY], rsi

    cmp edx, TAG_SMALLINT
    je .ms_int_index
    cmp edx, TAG_PTR            ; a float key is neither: classify
    jne .ms_type_error          ; fully before dereferencing, or raw
                                ; f64 bits get used as an address
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel slice_type]
    cmp rax, rcx
    jne .ms_int_index_heap

    ; --- slice ---
    mov rdi, [rbp - MS_OBJ]            ; the length slice_indices clamps
    call memoryview_nitems             ; against is the VIEW's, in items
    mov rsi, rax
    mov rdi, [rbp - MS_KEY]            ; slice obj
    call slice_indices                 ; rax=start, rdx=stop, rcx=step

    ; The item count for a step of any sign: ceil((stop - start) / step),
    ; clamped at zero, which is what range() answers for the same three.
    mov [rbp - MS_STEP], rcx
    mov [rbp - MS_START], rax
    sub rdx, rax                       ; the span
    test rcx, rcx
    js .ms_count_negative
    test rdx, rdx
    jle .ms_count_zero
    add rdx, rcx
    dec rdx
    jmp .ms_count_div
.ms_count_negative:
    test rdx, rdx
    jge .ms_count_zero
    add rdx, rcx
    inc rdx
.ms_count_div:
    mov rax, rdx
    cqo
    idiv rcx
    mov rdx, rax
    jmp .ms_have_count
.ms_count_zero:
    xor edx, edx
.ms_have_count:
    mov [rbp - MS_COUNT], rdx

    mov edi, PyMemoryViewObject_size
    call ap_malloc
    test rax, rax
    jz .ms_fail

    mov qword [rax + PyMemoryViewObject.ob_refcnt], 1
    lea rcx, [rel memoryview_type]
    mov [rax + PyMemoryViewObject.ob_type], rcx

    ; Every field the source carries has to come across.  A missed itemsize
    ; left the new view with 0, and memoryview_len divides by it.
    mov rdi, [rbp - MS_OBJ]
    mov rcx, [rdi + PyMemoryViewObject.mv_itemsize]
    mov [rax + PyMemoryViewObject.mv_itemsize], rcx
    mov rdx, [rdi + PyMemoryViewObject.mv_format]
    mov [rax + PyMemoryViewObject.mv_format], rdx
    mov rdx, [rdi + PyMemoryViewObject.mv_readonly]
    mov [rax + PyMemoryViewObject.mv_readonly], rdx

    ; mv_buf points at the slice's FIRST item, which for a negative step is
    ; the highest address in it -- the source's own stride is what turns an
    ; index into an offset, and a slice of a slice multiplies the two.
    push rcx
    mov rdx, [rbp - MS_START]
    MV_ITEM_ADDR rcx, rdi, rdx, r8
    mov [rax + PyMemoryViewObject.mv_buf], rcx
    pop rcx
    mov rdx, [rbp - MS_COUNT]
    imul rdx, rcx
    mov [rax + PyMemoryViewObject.mv_len], rdx
    mov rdx, [rbp - MS_STEP]
    imul rdx, [rdi + PyMemoryViewObject.mv_stride]
    mov [rax + PyMemoryViewObject.mv_stride], rdx

    ; The slice shares the ORIGINAL owner, not the view it came from: a
    ; chain of slices would otherwise keep every intermediate alive.
    mov rcx, [rdi + PyMemoryViewObject.mv_source]
    mov [rax + PyMemoryViewObject.mv_source], rcx
    test rcx, rcx
    jz .ms_no_source
    inc qword [rcx + PyObject.ob_refcnt]
    push rax
    push rax                    ; and a pad: the call below stays aligned
    mov rdi, rcx
    call mv_source_acquired
    pop rax
    pop rax
.ms_no_source:
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.ms_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret

.ms_int_index:
    ; rsi = the index, as an i64
    mov rdi, [rbp - MS_OBJ]
    push rsi
    call memoryview_nitems             ; rax = item count
    pop rsi
    mov rcx, rax
    test rsi, rsi
    jns .ms_check_bounds
    add rsi, rcx
.ms_check_bounds:
    test rsi, rsi
    jl .ms_index_error
    cmp rsi, rcx
    jge .ms_index_error
    mov rdi, [rbp - MS_OBJ]
    call memoryview_item_value
    mov edx, TAG_PTR
    leave
    ret

.ms_int_index_heap:
    mov rax, [rsi + PyObject.ob_type]   ; int_to_i64 reads PyIntObject.compact
    REQUIRE_INT_TYPE rax, rcx, .ms_type_error   ; unconditionally
    mov rdi, rsi
    mov edx, TAG_PTR
    ; obj_as_index_seq, not int_to_i64: that truncates through
    ; __gmpz_get_si, so `memoryview(b"ab")[2**70]` answered the first byte.
    lea rsi, [rel ms_index_msg]
    extern obj_as_index_seq
    call obj_as_index_seq
    mov rsi, rax
    jmp .ms_int_index

.ms_index_error:
    RAISE exc_IndexError_type, "index out of bounds on dimension 1"

.ms_step_error:
    RAISE exc_NotImplementedError_type, "memoryview: only step 1 is supported"

.ms_type_error:
    RAISE exc_TypeError_type, "memoryview: invalid slice key"
END_FUNC memoryview_subscript

section .rodata
ms_index_msg: db "memoryview: invalid slice key", 0
section .text

;; ============================================================================
;; memoryview_nitems(rdi = self) -> rax = the length in ITEMS
;; ============================================================================
DEF_FUNC_BARE memoryview_nitems
    mov rax, [rdi + PyMemoryViewObject.mv_len]
    mov r8, [rdi + PyMemoryViewObject.mv_itemsize]
    cmp r8, 1
    je .mvn_done
    push rdx
    xor edx, edx
    div r8
    pop rdx
.mvn_done:
    ret
END_FUNC memoryview_nitems

;; ============================================================================
;; memoryview_ass_subscript(rdi = self, rsi = key Value, rdx = value Value)
;;
;; mp_ass_subscript was 0, so a view over a bytearray was read-only in
;; practice -- and readinto(), which is the whole reason _pyio takes a view,
;; is nothing but writes through one.
;;
;; A slice assignment must be the same size: a view cannot resize its owner.
;; ============================================================================
MA_OBJ    equ 8
MA_KEY    equ 16
MA_VAL    equ 24
MA_START  equ 32
MA_COUNT  equ 40
MA_STEP   equ 48
MA_SRC    equ 56
MA_I      equ 64
MA_FMT    equ 72            ; the format character, kept across the range checks
MA_FRAME  equ 80            ; 72 used + 8 pad = 80, + 0 pushes

DEF_FUNC memoryview_ass_subscript, MA_FRAME
    mov [rbp - MA_OBJ], rdi
    mov [rbp - MA_KEY], rsi
    mov [rbp - MA_VAL], rdx
    call memoryview_check
    test rdx, rdx
    jz .ma_del_error
    cmp qword [rdi + PyMemoryViewObject.mv_readonly], 0
    jne .ma_readonly

    mov rsi, [rbp - MA_KEY]
    V_TEST_PTR rsi, rax
    jbe .ma_maybe_slice
.ma_int_key:
    ; An item assignment: one integer, range-checked like bytearray's.
    mov rdi, [rbp - MA_KEY]
    V_UNPACK rdi, rdx
    call obj_as_index
    mov rsi, rax
    mov rdi, [rbp - MA_OBJ]
    push rsi
    call memoryview_nitems
    pop rsi
    mov rcx, rax
    test rsi, rsi
    jns .ma_bounds
    add rsi, rcx
.ma_bounds:
    test rsi, rsi
    jl .ma_index_error
    cmp rsi, rcx
    jge .ma_index_error
    mov [rbp - MA_START], rsi

    ; The encode side of the format table.  It used to range-check 0..255 and
    ; store itemsize bytes whatever the format said, so a cast('b') refused -1
    ; and a cast('f') stored an integer.
    mov rdi, [rbp - MA_OBJ]
    mov rcx, [rdi + PyMemoryViewObject.mv_format]
    movzx ecx, byte [rcx]
    mov [rbp - MA_FMT], rcx

    cmp cl, 'f'
    je .ma_put_float
    cmp cl, 'd'
    je .ma_put_float
    cmp cl, 'c'
    je .ma_put_char
    cmp cl, '?'
    je .ma_put_bool

    mov rdi, [rbp - MA_VAL]
    V_UNPACK rdi, rdx
    call int_is_integer         ; not a tag test: a heap int, a bool and an
    test eax, eax               ; int subclass are all integers here
    jz .ma_value_type
    mov rdi, [rbp - MA_VAL]
    V_UNPACK rdi, rdx
    call obj_as_index

    ; The range is the format's, not the byte's.  An eight-byte field takes
    ; whatever obj_as_index answered, which is already an i64.
    mov rdi, [rbp - MA_OBJ]
    mov r9, [rdi + PyMemoryViewObject.mv_itemsize]
    cmp r9, 8
    je .ma_range_ok
    mov rcx, [rbp - MA_FMT]
    cmp cl, 'a'
    jb .ma_range_unsigned
    ; Signed: -(1 << (8n-1)) .. (1 << (8n-1)) - 1
    mov edx, 1
    lea rcx, [r9 * 8 - 1]
    shl rdx, cl                 ; 1 << (8n - 1)
    cmp rax, rdx
    jge .ma_value_range
    neg rdx
    cmp rax, rdx
    jl .ma_value_range
    jmp .ma_range_ok
.ma_range_unsigned:
    test rax, rax
    jl .ma_value_range
    mov edx, 1
    lea rcx, [r9 * 8]
    shl rdx, cl                 ; 1 << 8n
    cmp rax, rdx
    jge .ma_value_range
.ma_range_ok:

    mov rdi, [rbp - MA_OBJ]
    mov rcx, [rbp - MA_START]
    MV_ITEM_ADDR rsi, rdi, rcx, r8
    mov rcx, [rdi + PyMemoryViewObject.mv_itemsize]
.ma_store_sized:
    cmp rcx, 1
    je .ma_store1
    cmp rcx, 2
    je .ma_store2
    cmp rcx, 4
    je .ma_store4
    mov [rsi], rax
    jmp .ma_ok
.ma_store1:
    mov [rsi], al
    jmp .ma_ok
.ma_store2:
    mov [rsi], ax
    jmp .ma_ok
.ma_store4:
    mov [rsi], eax
.ma_ok:
    xor eax, eax
    leave
    ret

.ma_put_float:
    mov rdi, [rbp - MA_VAL]
    extern math_to_double
    call math_to_double         ; xmm0, eax = 0 when it is not a number
    test eax, eax
    jz .ma_value_type
    mov rdi, [rbp - MA_OBJ]
    mov rcx, [rbp - MA_START]
    MV_ITEM_ADDR rsi, rdi, rcx, r8
    mov rcx, [rbp - MA_FMT]
    cmp cl, 'd'
    je .ma_put_f64
    cvtsd2ss xmm0, xmm0
    movss [rsi], xmm0
    jmp .ma_ok
.ma_put_f64:
    movsd [rsi], xmm0
    jmp .ma_ok

.ma_put_bool:
    mov rdi, [rbp - MA_VAL]
    extern obj_is_true
    call obj_is_true
    mov rdi, [rbp - MA_OBJ]
    mov rcx, [rbp - MA_START]
    push rax
    MV_ITEM_ADDR rsi, rdi, rcx, r8
    pop rax
    mov [rsi], al
    jmp .ma_ok

.ma_put_char:
    ; 'c' takes a one-byte bytes, as CPython's does.
    mov rax, [rbp - MA_VAL]
    V_TEST_PTR rax, rcx
    ja .ma_value_type
    test rax, rax
    jz .ma_value_type
    mov rcx, [rax + PyObject.ob_type]
    extern bytes_type
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    jne .ma_value_type
    cmp qword [rax + PyBytesObject.ob_size], 1
    jne .ma_value_range
    movzx r10d, byte [rax + PyBytesObject.data]
    mov rdi, [rbp - MA_OBJ]
    mov rcx, [rbp - MA_START]
    MV_ITEM_ADDR rsi, rdi, rcx, r8
    mov [rsi], r10b
    jmp .ma_ok

.ma_maybe_slice:
    test rsi, rsi
    jz .ma_key_type
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel slice_type]
    cmp rax, rcx
    jne .ma_int_key

    mov rdi, [rbp - MA_OBJ]
    call memoryview_nitems
    mov rsi, rax
    mov rdi, [rbp - MA_KEY]
    call slice_indices                 ; rax=start, rdx=stop, rcx=step
    ; The count for a step of any sign, as memoryview_subscript computes it.
    mov [rbp - MA_STEP], rcx
    mov [rbp - MA_START], rax
    sub rdx, rax
    test rcx, rcx
    js .ma_count_negative
    test rdx, rdx
    jle .ma_count_zero
    add rdx, rcx
    dec rdx
    jmp .ma_count_div
.ma_count_negative:
    test rdx, rdx
    jge .ma_count_zero
    add rdx, rcx
    inc rdx
.ma_count_div:
    mov rax, rdx
    cqo
    idiv rcx
    mov rdx, rax
    jmp .ma_have_count
.ma_count_zero:
    xor edx, edx
.ma_have_count:
    mov [rbp - MA_COUNT], rdx

    mov rdi, [rbp - MA_VAL]
    call bytes_like_ptr_len            ; rax = data, r10 = length, ecx = ok
    test ecx, ecx
    jz .ma_value_type
    mov [rbp - MA_SRC], rax
    mov rdi, [rbp - MA_OBJ]
    mov rdx, [rbp - MA_COUNT]
    imul rdx, [rdi + PyMemoryViewObject.mv_itemsize]
    cmp r10, rdx
    jne .ma_size_error

    ; One item at a time: the destination items are mv_stride apart, and for
    ; a slice with a step of its own they are that many further again.  The
    ; SOURCE is contiguous either way.
    mov qword [rbp - MA_I], 0
.ma_write_loop:
    mov rcx, [rbp - MA_I]
    cmp rcx, [rbp - MA_COUNT]
    jge .ma_ok
    mov rdi, [rbp - MA_OBJ]
    mov rax, [rbp - MA_STEP]
    imul rax, rcx
    add rax, [rbp - MA_START]
    MV_ITEM_ADDR rdi, rdi, rax, r8
    mov rax, [rbp - MA_OBJ]
    mov rdx, [rax + PyMemoryViewObject.mv_itemsize]
    mov rsi, [rbp - MA_I]
    imul rsi, rdx
    add rsi, [rbp - MA_SRC]
    call ap_memcpy
    inc qword [rbp - MA_I]
    jmp .ma_write_loop

.ma_del_error:
    RAISE exc_TypeError_type, "cannot delete memory"
.ma_readonly:
    RAISE exc_TypeError_type, "cannot modify read-only memory"
.ma_index_error:
    RAISE exc_IndexError_type, "index out of bounds on dimension 1"
.ma_value_range:
    RAISE exc_ValueError_type, "memoryview: invalid value for format 'B'"
.ma_value_type:
    RAISE exc_TypeError_type, "memoryview: invalid type for assignment"
.ma_size_error:
    RAISE exc_ValueError_type, "memoryview assignment: lvalue and rvalue have different structures"
.ma_step_error:
    RAISE exc_NotImplementedError_type, "memoryview: only step 1 is supported"
.ma_key_type:
    RAISE exc_TypeError_type, "memoryview: invalid slice key"
END_FUNC memoryview_ass_subscript

;; ============================================================================
;; memoryview_len(obj) -> int64
;; ============================================================================
;; len() counts ITEMS, so a view cast to 'I' is a quarter as long as its
;; bytes; and a released view answers no questions at all.
DEF_FUNC memoryview_len
    call memoryview_check
    call memoryview_nitems
    leave
    ret
END_FUNC memoryview_len

;; The by-name half of the two slots above.  A slot with no matching entry in
;; tp_dict answers hasattr() and getattr() wrong, and _pyio reaches
;; __setitem__ through the abstract base classes rather than the syntax.
DEF_FUNC memoryview_dunder_getitem
    REQUIRE_SELF memoryview_type, "__getitem__"
    cmp rsi, 2
    jne .mdg_bad
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call memoryview_subscript
    leave
    ret
.mdg_bad:
    RAISE exc_TypeError_type, "expected exactly one argument"
END_FUNC memoryview_dunder_getitem

DEF_FUNC memoryview_dunder_setitem
    REQUIRE_SELF memoryview_type, "__setitem__"
    cmp rsi, 3
    jne .mds_bad
    mov rdx, [rdi + 16]
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call memoryview_ass_subscript
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
.mds_bad:
    RAISE exc_TypeError_type, "expected exactly two arguments"
END_FUNC memoryview_dunder_setitem

DEF_FUNC memoryview_dunder_len
    REQUIRE_SELF memoryview_type, "__len__"
    test rsi, rsi
    jz .mdl_bad
    mov rdi, [rdi]
    call memoryview_len
    mov rdx, rax
    V_PACK_I64 rdx, rcx
    mov rax, rdx
    leave
    ret
.mdl_bad:
    RAISE exc_TypeError_type, "__len__() takes no arguments"
END_FUNC memoryview_dunder_len

;; ============================================================================
;; Type object
;; ============================================================================
;; ============================================================================
;; memoryview_sq_item(rdi = self, rsi = the item index) -> rax = the item Value,
;;   or 0 with an IndexError pending
;;
;; The sequence protocol's single-item read.  It was 0, so `reversed(mv)` was
;; "'memoryview' object is not reversible" -- builtin_reversed asks for
;; sq_item, and a mapping's mp_subscript is not it.  CPython's memoryview
;; carries both for the same reason.
;;
;; The index arrives already adjusted for a negative, as sq_item's does.
;; ============================================================================
MSQ_SELF  equ 8
MSQ_IDX   equ 16            ; the index, across the two calls
MSQ_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL memoryview_sq_item, MSQ_FRAME
    ; Frame slots, not pushes: a lone push before a call leaves it eight bytes
    ; out of alignment, and everything under it inherits that.
    mov [rbp - MSQ_SELF], rdi
    mov [rbp - MSQ_IDX], rsi
    call memoryview_check
    mov rdi, [rbp - MSQ_SELF]
    call memoryview_nitems
    mov rsi, [rbp - MSQ_IDX]
    test rsi, rsi
    jl .msqi_range
    cmp rsi, rax
    jge .msqi_range
    mov rdi, [rbp - MSQ_SELF]
    call memoryview_item_value
    mov edx, TAG_PTR
    leave
    ret
.msqi_range:
    RAISE exc_IndexError_type, "index out of bounds"
END_FUNC memoryview_sq_item

section .data

align 8
mv_name_str:  db "memoryview", 0

align 8
memoryview_seq_methods:
    dq memoryview_len       ; +0: sq_length
    dq 0                    ; +8: sq_concat
    dq 0                    ; +16: sq_repeat
    dq memoryview_sq_item   ; +24: sq_item
    dq 0                    ; +32: sq_ass_item
    dq 0                    ; +40: sq_contains
    dq 0                    ; +48: sq_inplace_concat
    dq 0                    ; +56: sq_inplace_repeat

align 8
memoryview_mapping_methods:
    dq memoryview_len       ; +0: mp_length
    dq memoryview_subscript ; +8: mp_subscript
    dq memoryview_ass_subscript ; +16: mp_ass_subscript

align 8
global memoryview_type
memoryview_type:
    dq 1                             ; ob_refcnt
    dq type_type                     ; ob_type
    dq mv_name_str                   ; tp_name
    dq PyMemoryViewObject_size       ; tp_basicsize
    dq memoryview_dealloc_proper     ; tp_dealloc
    dq memoryview_repr               ; tp_repr
    dq memoryview_repr               ; tp_str
    ; Unhashable while the buffer is writable, which is the only kind that
    ; reaches here in practice; a 0 would fall through to the object address.
    dq memoryview_hash               ; tp_hash (read-only views only)
    dq 0                             ; tp_call (set by add_builtin_type)
    dq memoryview_getattr            ; tp_getattr
    dq 0                             ; tp_setattr
    dq memoryview_richcompare        ; tp_richcompare (bytes_compare, over a
                                     ; copy when the view is strided)
    dq memoryview_tp_iter            ; tp_iter
    dq 0                             ; tp_iternext
    dq 0                             ; tp_init
    dq 0                             ; tp_new
    dq 0                             ; tp_as_number
    dq memoryview_seq_methods        ; tp_as_sequence
    dq memoryview_mapping_methods    ; tp_as_mapping
    dq 0                             ; tp_base
    dq 0                             ; tp_dict
    dq 0                             ; tp_mro
    dq TYPE_FLAG_FINAL          ; tp_flags -- CPython gives this type no
                                ; Py_TPFLAGS_BASETYPE
    dq 0                             ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

section .rodata
; The one-character format codes a view can carry, and the itemsize each one
; means in NATIVE terms -- which is the only mode cast() has, so `l` and `L`
; are eight bytes here as they are on any LP64 CPython.
;
; The table is what the decoder reads, and the two have to be widened
; together: cast() used to accept only the five unsigned codes because reading
; itemsize bytes little-endian and unsigned was all memoryview_item_value
; could do, and it ALIASED `b` onto `B` rather than refusing it -- so
; `memoryview(b'\xff').cast('b')[0]` was 255, and `.format` then said 'B'.
;
; `e`, the half-float, is the one native code CPython accepts that this does
; not: its decode is a bit layout rather than a load, and nothing in the
; corpus asks for it.
global mv_format_B
mv_format_c: db "c", 0
mv_format_b: db "b", 0
mv_format_B: db "B", 0
mv_format_bool: db "?", 0
mv_format_h: db "h", 0
mv_format_H: db "H", 0
mv_format_i: db "i", 0
mv_format_I: db "I", 0
mv_format_l: db "l", 0
mv_format_L: db "L", 0
mv_format_q: db "q", 0
mv_format_Q: db "Q", 0
mv_format_n: db "n", 0
mv_format_N: db "N", 0
mv_format_f: db "f", 0
mv_format_d: db "d", 0
mv_format_P: db "P", 0

align 8
; One row per accepted code: the character, its itemsize, and the string the
; view reports.  Terminated by a zero character.
mv_format_table:
    db 'c', 1, 0, 0, 0, 0, 0, 0
    dq mv_format_c
    db 'b', 1, 0, 0, 0, 0, 0, 0
    dq mv_format_b
    db 'B', 1, 0, 0, 0, 0, 0, 0
    dq mv_format_B
    db '?', 1, 0, 0, 0, 0, 0, 0
    dq mv_format_bool
    db 'h', 2, 0, 0, 0, 0, 0, 0
    dq mv_format_h
    db 'H', 2, 0, 0, 0, 0, 0, 0
    dq mv_format_H
    db 'i', 4, 0, 0, 0, 0, 0, 0
    dq mv_format_i
    db 'I', 4, 0, 0, 0, 0, 0, 0
    dq mv_format_I
    db 'l', 8, 0, 0, 0, 0, 0, 0
    dq mv_format_l
    db 'L', 8, 0, 0, 0, 0, 0, 0
    dq mv_format_L
    db 'q', 8, 0, 0, 0, 0, 0, 0
    dq mv_format_q
    db 'Q', 8, 0, 0, 0, 0, 0, 0
    dq mv_format_Q
    db 'n', 8, 0, 0, 0, 0, 0, 0
    dq mv_format_n
    db 'N', 8, 0, 0, 0, 0, 0, 0
    dq mv_format_N
    db 'f', 4, 0, 0, 0, 0, 0, 0
    dq mv_format_f
    db 'd', 8, 0, 0, 0, 0, 0, 0
    dq mv_format_d
    db 'P', 8, 0, 0, 0, 0, 0, 0
    dq mv_format_P
    db 0, 0, 0, 0, 0, 0, 0, 0
    dq 0

section .rodata
mv_dunder_buffer: db "__buffer__", 0
