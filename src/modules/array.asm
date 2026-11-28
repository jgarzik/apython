; array.asm - the `array` module
;
; array.array: a mutable sequence of C scalars, one typecode for the lot.  It
; is what stands between this tree and multiprocessing, and CPython's own
; suite imports it from the test modules for struct, memoryview, io, bytes,
; socket, re, marshal, codecs and the compression family -- more than the rest
; of the missing C modules together.
;
; The storage is a plain malloc'd buffer of raw scalars, NOT Values: an array
; of 'i' holds four-byte ints, and reading one means widening it at the point
; of access.  That is the whole reason the type exists, and it is why the
; object carries neither tp_traverse nor tp_clear -- there is nothing in the
; buffer for the collector to follow, and handing it one would have it read
; machine integers as pointers.
;
; The buffer can move, so the type takes no __dict__ and no __slots__ at a
; fixed offset, the way bytearray and memoryview do not.
;
; What is here is the surface the stdlib actually uses -- fromfile and tofile
; included.  They were left out on the claim that "every caller in the suite
; reaches for frombytes and tobytes instead", and that was measured and found
; false: CPython's test.datetimetester reads its own data through fromfile on
; the way into its tests, and the missing method accounted for 840 of the 849
; errors the module reported.  They are the file object's own read and write
; seen from the array's side, and what they mostly have to get right is the
; failures -- a short read keeps what it got AND raises.

%include "macros.inc"
%include "object.inc"

extern dict_set_str
extern dict_new
extern dict_set
extern obj_decref
extern obj_incref
extern str_from_cstr_heap
extern builtin_func_new
extern list_new
extern list_append
extern tuple_new
extern int_from_i64
extern obj_as_index
extern obj_as_slice_index
extern none_singleton
extern bool_true
extern bool_false
extern set_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_IndexError_type
extern exc_OverflowError_type
extern type_type
extern str_type
extern int_type
extern int_promote_mpz
extern bool_type
extern float_type
extern bytes_type
extern bytes_from_data
extern ap_malloc
extern ap_free
extern ap_memcpy
extern ap_realloc
extern float_from_f64
extern float_to_f64
extern get_iterator_opt
extern obj_richcompare_bool
extern repr_append_cstr
extern rbt_append_cstr
extern str_cp_at
extern hash_not_implemented
extern obj_dealloc
extern gc_alloc
extern gc_track
extern str_new_heap
extern add_new_staticmethod
extern new_check_class
extern exc_MemoryError_type

;; ============================================================================
;; The typecode table.  Each row is (letter, itemsize, kind), where kind says
;; how a stored scalar becomes a Python object and back:
;;
;;   AK_SIGNED    a signed integer, sign-extended on the way out
;;   AK_UNSIGNED  an unsigned integer, zero-extended
;;   AK_FLOAT     4 or 8 bytes of IEEE, widened to a double
;;   AK_UNICODE   a code point, 4 bytes, which becomes a one-character str
;;
;; 'l' and 'L' are eight bytes here as they are on every LP64 platform, which
;; is what CPython reports for them too.
;; ============================================================================
AK_SIGNED   equ 0
AK_UNSIGNED equ 1
AK_FLOAT    equ 2
AK_UNICODE  equ 3

struc ArrayCode
    .letter:   resq 1
    .itemsize: resq 1
    .kind:     resq 1
endstruc

section .rodata
align 8
array_codes:
    dq 'b', 1, AK_SIGNED
    dq 'B', 1, AK_UNSIGNED
    dq 'u', 4, AK_UNICODE
    dq 'h', 2, AK_SIGNED
    dq 'H', 2, AK_UNSIGNED
    dq 'i', 4, AK_SIGNED
    dq 'I', 4, AK_UNSIGNED
    dq 'l', 8, AK_SIGNED
    dq 'L', 8, AK_UNSIGNED
    dq 'q', 8, AK_SIGNED
    dq 'Q', 8, AK_UNSIGNED
    dq 'f', 4, AK_FLOAT
    dq 'd', 8, AK_FLOAT
array_codes_end:
ARRAY_NCODES equ (array_codes_end - array_codes) / ArrayCode_size

array_name_str:      db "array.array", 0
array_typecodes_str: db "bBuhHiIlLqQfd", 0

section .text

;; ============================================================================
;; array_find_code(rdi = the typecode letter) -> rax = its ArrayCode*, or 0
;; ============================================================================
global array_find_code
DEF_FUNC_BARE array_find_code
    lea rax, [rel array_codes]
    mov rcx, ARRAY_NCODES
.afc_loop:
    test rcx, rcx
    jz .afc_none
    cmp [rax + ArrayCode.letter], rdi
    je .afc_done
    add rax, ArrayCode_size
    dec rcx
    jmp .afc_loop
.afc_none:
    xor eax, eax
.afc_done:
    ret
END_FUNC array_find_code

;; ============================================================================
;; array_new_empty_type(rdi = ArrayCode*, rsi = PyTypeObject*) -> rax or 0
;; Allocates an empty array of the requested type (array_type or a subclass),
;; respecting tp_basicsize and TYPE_FLAG_HAVE_GC, zeroing any subclass tail.
;; ============================================================================
ANET_CODE  equ 8
ANET_TYPE  equ 16
ANET_SIZE  equ 24
ANET_FRAME equ 40            ; + 1 push (rbx) = 48, 16-aligned
global array_new_empty_type
DEF_FUNC array_new_empty_type, ANET_FRAME
    push rbx
    mov [rbp - ANET_CODE], rdi
    mov [rbp - ANET_TYPE], rsi

    mov rdi, [rsi + PyTypeObject.tp_basicsize]
    cmp rdi, PyArrayObject_size
    jge .anet_size_ok
    mov edi, PyArrayObject_size
.anet_size_ok:
    mov [rbp - ANET_SIZE], rdi
    test qword [rsi + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .anet_plain_alloc
    call gc_alloc
    jmp .anet_alloc_done
.anet_plain_alloc:
    call ap_malloc
    test rax, rax
    jz .anet_out
    INIT_OBJ_RC rax
    mov rsi, [rbp - ANET_TYPE]
    mov [rax + PyObject.ob_type], rsi
.anet_alloc_done:
    test rax, rax
    jz .anet_out
    mov rbx, rax
    mov qword [rbx + PyArrayObject.ob_size], 0
    mov qword [rbx + PyArrayObject.ob_cap], 0
    mov qword [rbx + PyArrayObject.ob_data], 0
    mov rdx, [rbp - ANET_CODE]
    mov rcx, [rdx + ArrayCode.letter]
    mov [rbx + PyArrayObject.ob_code], rcx
    mov rcx, [rdx + ArrayCode.itemsize]
    mov [rbx + PyArrayObject.ob_isize], rcx
    mov rcx, [rdx + ArrayCode.kind]
    mov [rbx + PyArrayObject.ob_kind], rcx
    mov qword [rbx + PyArrayObject.ob_exports], 0

    ; Zero any subclass tail (__dict__ slot and __slots__ values)
    mov rcx, [rbp - ANET_SIZE]
    sub rcx, PyArrayObject_size
    jle .anet_no_tail
    lea rdi, [rbx + PyArrayObject_size]
    shr rcx, 3
    xor eax, eax
    rep stosq
.anet_no_tail:
    ; Own a ref to the type (no-op for immortal array_type; required for heaptype)
    mov rsi, [rbp - ANET_TYPE]
    INCREF rsi
    test qword [rsi + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .anet_done
    mov rdi, rbx
    call gc_track
.anet_done:
    mov rax, rbx
.anet_out:
    pop rbx
    leave
    ret
END_FUNC array_new_empty_type

;; ============================================================================
;; array_new_empty(rdi = ArrayCode*) -> rax = a new empty array, or 0
;; ============================================================================
global array_new_empty
DEF_FUNC_BARE array_new_empty
    lea rsi, [rel array_type]
    jmp array_new_empty_type
END_FUNC array_new_empty

;; ============================================================================
;; array_reserve(rdi = the array, rsi = items wanted) -> eax = 1
;; Fails: 0
;;
;; Grows by doubling, as list does.  The buffer MOVES, which is why nothing
;; may hold a pointer into it across an append.
;; ============================================================================
AR_ARR   equ 8
AR_WANT  equ 16
AR_FRAME equ 32             ; + 0 pushes = 32, 16-aligned
global array_reserve
DEF_FUNC array_reserve, AR_FRAME
    mov [rbp - AR_ARR], rdi
    mov [rbp - AR_WANT], rsi
    cmp rsi, [rdi + PyArrayObject.ob_cap]
    jle .arr_ok

    ; Nothing may be holding a pointer into the buffer: it is about to move.
    call array_no_exports
    ERR_NULL .arr_raised
    mov rdi, [rbp - AR_ARR]
    mov rsi, [rbp - AR_WANT]

    ; new capacity = max(want, cap * 2, 8)
    mov rax, [rdi + PyArrayObject.ob_cap]
    add rax, rax
    cmp rax, rsi
    jge .arr_have_cap
    mov rax, rsi
.arr_have_cap:
    cmp rax, 8
    jge .arr_cap_ok
    mov eax, 8
.arr_cap_ok:
    push rax
    mov rdi, [rbp - AR_ARR]
    imul rax, [rdi + PyArrayObject.ob_isize]
    mov rsi, rax
    mov rdi, [rdi + PyArrayObject.ob_data]
    call ap_realloc
    pop rcx
    test rax, rax
    jz .arr_nomem
    mov rdi, [rbp - AR_ARR]
    mov [rdi + PyArrayObject.ob_data], rax
    mov [rdi + PyArrayObject.ob_cap], rcx
.arr_ok:
    mov eax, 1
    leave
    ret
.arr_raised:
    xor eax, eax
    leave
    ret
.arr_nomem:
    SET_EXC exc_MemoryError_type, "out of memory"
    leave
    ret
END_FUNC array_reserve

;; ============================================================================
;; array_item_value(rdi = the array, rsi = index) -> rax = a Value
;;
;; Widening is the whole point: a stored 'h' is two bytes and comes out as an
;; int, an 'f' is four and comes out as a float.  The kind says which, and the
;; SIZE says how far to sign- or zero-extend.
;; ============================================================================
AIV_ARG   equ 8          ; the one-element argument array chr() takes
AIV_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
global array_item_value
DEF_FUNC array_item_value, AIV_FRAME
    mov rax, [rdi + PyArrayObject.ob_data]
    mov rcx, [rdi + PyArrayObject.ob_isize]
    imul rsi, rcx
    add rax, rsi                ; rax = &item
    mov rdx, [rdi + PyArrayObject.ob_kind]

    cmp rdx, AK_FLOAT
    je .aiv_float
    cmp rdx, AK_UNICODE
    je .aiv_unicode
    cmp rdx, AK_UNSIGNED
    je .aiv_unsigned

    ; signed
    cmp rcx, 1
    je .aiv_s1
    cmp rcx, 2
    je .aiv_s2
    cmp rcx, 4
    je .aiv_s4
    mov rdi, [rax]
    jmp .aiv_int
.aiv_s1:
    movsx rdi, byte [rax]
    jmp .aiv_int
.aiv_s2:
    movsx rdi, word [rax]
    jmp .aiv_int
.aiv_s4:
    movsxd rdi, dword [rax]
    jmp .aiv_int

.aiv_unsigned:
    cmp rcx, 1
    je .aiv_u1
    cmp rcx, 2
    je .aiv_u2
    cmp rcx, 4
    je .aiv_u4
    mov rdi, [rax]
    test rdi, rdi
    js .aiv_u8_wide             ; above 2**63: an i64 cannot say it
    jmp .aiv_int
.aiv_u1:
    movzx edi, byte [rax]
    jmp .aiv_int
.aiv_u2:
    movzx edi, word [rax]
    jmp .aiv_int
.aiv_u4:
    mov edi, dword [rax]
    jmp .aiv_int

.aiv_u8_wide:
    ; 'L' and 'Q' hold the full u64 range, so reading one back through an i64
    ; answered array('Q', [2**64-1])[0] as -1.
    call array_int_from_u64
    leave
    V_PACK rax, rdx
    ret

.aiv_int:
    ; int_from_i64 answers a (payload, tag) PAIR, not a Value.  Handing the
    ; payload straight back stored a raw 7 where a Value was wanted, and the
    ; next dict_set read it as a pointer.
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret

.aiv_float:
    cmp rcx, 4
    je .aiv_f4
    movsd xmm0, [rax]
    jmp .aiv_mkfloat
.aiv_f4:
    cvtss2sd xmm0, dword [rax]
.aiv_mkfloat:
    ; float_from_f64 takes the double in xmm0, where it already is, and
    ; answers a pair like int_from_i64.
    call float_from_f64
    leave
    V_PACK rax, rdx
    ret

.aiv_unicode:
    ; A stored code point becomes a one-character str, which is exactly what
    ; chr() builds -- and the UTF-8 encoder it needs is written once, there.
    mov edi, dword [rax]
    V_PACK_I64 rdi, rcx
    mov [rbp - AIV_ARG], rdi
    lea rdi, [rbp - AIV_ARG]
    mov esi, 1
    extern builtin_chr
    call builtin_chr            ; err: its 0 is this function's own
    leave
    ret
END_FUNC array_item_value

;; ============================================================================
;; array_int_from_u64(rdi = an unsigned 64-bit value) -> (rax, edx = TAG_PTR)
;;
;; For the half of the u64 range an i64 cannot express.  int_from_i64 would
;; answer a negative number, so the mpz is set from the unsigned value
;; directly.
;; ============================================================================
DEF_FUNC_LOCAL array_int_from_u64, 8            ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, rdi
    xor edi, edi
    extern int_from_i64_gmp
    call int_from_i64_gmp
    mov rdi, rax
    INT_NEED_MPZ rdi
    lea rdi, [rax + PyIntObject.mpz]
    mov rsi, rbx
    mov rbx, rax
    extern __gmpz_set_ui
    call __gmpz_set_ui wrt ..plt
    mov rax, rbx
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
END_FUNC array_int_from_u64

;; ============================================================================
;; array_store_item(rdi = the array, rsi = index, rdx = the Value to store)
;;   -> eax = 1, or 0 with an exception pending
;;
;; The narrowing half of array_item_value, and the half that can refuse: an
;; array of 'b' takes -128..127 and CPython raises OverflowError outside that,
;; rather than truncating.
;; ============================================================================
ASI_ARR   equ 8
ASI_IDX   equ 16
ASI_VAL   equ 24
ASI_OBJ   equ 32        ; a heap int too wide for an i64 (borrowed or owned)
ASI_NEG   equ 40        ; 1 when the refusal is "less than minimum"
ASI_MSG_ROW equ 40      ; five qwords per row of asi_msgs
ASI_WIDE  equ 48        ; 1 when it did not even fit the C conversion type
ASI_OWNED equ 56        ; 1 when ASI_OBJ is an owned ref from __index__
ASI_FRAME equ 72            ; + 1 push = 80, 16-aligned
global array_store_item
DEF_FUNC array_store_item, ASI_FRAME
    push rbx
    mov [rbp - ASI_ARR], rdi
    mov [rbp - ASI_IDX], rsi
    mov [rbp - ASI_VAL], rdx
    mov qword [rbp - ASI_OWNED], 0
    mov qword [rbp - ASI_OBJ], 0

    mov rcx, [rdi + PyArrayObject.ob_kind]
    cmp rcx, AK_FLOAT
    je .asi_float
    cmp rcx, AK_UNICODE
    je .asi_unicode

    ; An integer typecode takes an index-like object, and refuses a float:
    ; CPython says "'float' object cannot be interpreted as an integer".
    mov rdi, rdx
    V_UNPACK rdi, rdx
    call array_int_arg
    test edx, edx
    jz .asi_fail
    mov qword [rbp - ASI_NEG], 0
    mov qword [rbp - ASI_WIDE], 0
    cmp edx, 2
    je .asi_wide
    cmp edx, 3
    je .asi_wide_owned
    mov rbx, rax                ; the value, as an i64

    ; Range, by size and signedness.  Out of range is OverflowError, not a
    ; silent truncation.
    mov rdi, [rbp - ASI_ARR]
    mov rcx, [rdi + PyArrayObject.ob_isize]
    mov rdx, [rdi + PyArrayObject.ob_kind]
    ; The signedness test comes FIRST.  Behind the eight-byte shortcut, 'L'
    ; and 'Q' were never range-checked at all, and array('Q', [-1]) stored
    ; -1 and printed it back.
    cmp rdx, AK_UNSIGNED
    je .asi_range_unsigned
    cmp rcx, 8
    je .asi_store                ; eight signed bytes take any i64

    ; signed: -(1 << (bits-1)) .. (1 << (bits-1)) - 1
    shl rcx, 3                  ; bits
    dec rcx
    mov eax, 1
    shl rax, cl                 ; 1 << (bits-1)
    mov rdx, rax
    neg rdx                     ; the low bound
    cmp rbx, rdx
    jge .asi_hi_check
    mov qword [rbp - ASI_NEG], 1
    jmp .asi_overflow
.asi_hi_check:
    dec rax
    cmp rbx, rax
    jg .asi_overflow
    jmp .asi_store

.asi_range_unsigned:
    test rbx, rbx
    jns .asi_unsigned_hi
    mov qword [rbp - ASI_NEG], 1
    jmp .asi_overflow
.asi_unsigned_hi:
    cmp rcx, 8
    je .asi_store               ; every non-negative i64 fits a u64
    shl rcx, 3                  ; bits
    mov eax, 1
    shl rax, cl
    dec rax
    cmp rbx, rax
    jg .asi_overflow

.asi_store:
    mov rdi, [rbp - ASI_ARR]
    mov rsi, [rbp - ASI_IDX]
    call asi_acquire_slot
    test rax, rax
    jz .asi_fail
    cmp rcx, 1
    je .asi_w1
    cmp rcx, 2
    je .asi_w2
    cmp rcx, 4
    je .asi_w4
    mov [rax], rbx
    jmp .asi_unlock_ok
.asi_w1:
    mov [rax], bl
    jmp .asi_unlock_ok
.asi_w2:
    mov [rax], bx
    jmp .asi_unlock_ok
.asi_w4:
    mov [rax], ebx
.asi_unlock_ok:
    mov rdi, [rbp - ASI_ARR]
    cmp qword [rbp - ASI_IDX], -1
    jne .asi_unlock_only
    inc qword [rdi + PyArrayObject.ob_size]
.asi_unlock_only:
    OBJ_UNLOCK rdi
.asi_ok:
    cmp qword [rbp - ASI_OWNED], 0
    je .asi_ok_ret
    mov rdi, [rbp - ASI_OBJ]
    call obj_decref
.asi_ok_ret:
    mov eax, 1
    pop rbx
    leave
    ret

.asi_float:
    mov rdi, rdx
    extern array_float_arg
    call array_float_arg
    ERR_NULL .asi_fail
    sub rsp, 16
    movsd [rsp], xmm0
    mov rdi, [rbp - ASI_ARR]
    mov rsi, [rbp - ASI_IDX]
    call asi_acquire_slot
    movsd xmm0, [rsp]
    add rsp, 16
    test rax, rax
    jz .asi_fail
    cmp rcx, 4
    je .asi_f4
    movsd [rax], xmm0
    jmp .asi_unlock_ok
.asi_f4:
    cvtsd2ss xmm1, xmm0
    movss dword [rax], xmm1
    jmp .asi_unlock_ok

.asi_unicode:
    mov rdi, rdx
    V_TEST_PTR rdi, rax
    ja .asi_need_char
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .asi_need_char
    cmp qword [rdi + PyStrObject.ob_length], 1
    jne .asi_need_char
    xor esi, esi
    call str_cp_at
    mov rbx, rax
    mov rdi, [rbp - ASI_ARR]
    mov rsi, [rbp - ASI_IDX]
    call asi_acquire_slot
    test rax, rax
    jz .asi_fail
    mov [rax], ebx
    jmp .asi_unlock_ok

.asi_fail:
    cmp qword [rbp - ASI_OWNED], 0
    je .asi_fail_ret
    mov rdi, [rbp - ASI_OBJ]
    call obj_decref
.asi_fail_ret:
    xor eax, eax
    pop rbx
    leave
    ret
.asi_wide_owned:
    mov qword [rbp - ASI_OWNED], 1
.asi_wide:
    ; Wider than an i64.  Only an eight-byte UNSIGNED array can still take it:
    ; array('Q', [2**64-1]) is legal, and obj_as_index cannot express it.
    mov [rbp - ASI_OBJ], rax
    mov rdi, [rbp - ASI_ARR]
    cmp qword [rdi + PyArrayObject.ob_kind], AK_UNSIGNED
    jne .asi_wide_sign
    cmp qword [rdi + PyArrayObject.ob_isize], 8
    jne .asi_wide_sign
    mov rdi, [rbp - ASI_OBJ]
    lea rdi, [rdi + PyIntObject.mpz]
    extern __gmpz_fits_ulong_p
    call __gmpz_fits_ulong_p wrt ..plt
    test eax, eax
    jz .asi_wide_sign
    mov rdi, [rbp - ASI_OBJ]
    lea rdi, [rdi + PyIntObject.mpz]
    extern __gmpz_get_ui
    call __gmpz_get_ui wrt ..plt
    mov rbx, rax
    jmp .asi_store
.asi_wide_sign:
    ; _mp_size carries the sign, and the refusal's wording depends on it.
    mov qword [rbp - ASI_WIDE], 1
    mov rax, [rbp - ASI_OBJ]
    mov eax, [rax + PyIntObject.mpz + 4]
    test eax, eax
    jns .asi_overflow
    mov qword [rbp - ASI_NEG], 1

.asi_overflow:
    ; CPython words this per TYPECODE, and not consistently: 'b' says "signed
    ; char", 'H' says "unsigned short", 'I' names __index__'s own refusal, and
    ; 'q' just says "int too big to convert".  Worse, each code has TWO pairs
    ; of messages: one for a value the C conversion accepted and the range
    ; then refused, and one for a value that never fit the C type at all --
    ; array('b', [2**64]) blames a C long, not a signed char.  A table is the
    ; only honest way to reproduce that.
    ;
    ; SET_EXC: the callers return a failure code and let their own caller
    ; unwind, so a RAISE here would skip the cleanup in between.
    mov rax, [rbp - ASI_ARR]
    mov rcx, [rax + PyArrayObject.ob_code]
    lea rdx, [rel asi_msgs]
.asi_msg_scan:
    mov rax, [rdx]
    test rax, rax
    jz .asi_msg_generic
    cmp rax, rcx
    je .asi_msg_found
    add rdx, ASI_MSG_ROW
    jmp .asi_msg_scan
.asi_msg_found:
    mov eax, 8                      ; past the typecode
    cmp qword [rbp - ASI_WIDE], 0
    je .asi_msg_pair
    add rax, 16                         ; the "did not fit the C type" pair
.asi_msg_pair:
    cmp qword [rbp - ASI_NEG], 0
    jne .asi_msg_take
    add rax, 8                          ; the "greater than maximum" half
.asi_msg_take:
    mov rsi, [rdx + rax]
    jmp .asi_msg_raise
.asi_msg_generic:
    lea rsi, [rel asi_m_toobig]
.asi_msg_raise:
    lea rdi, [rel exc_OverflowError_type]
    call set_exception
    xor eax, eax
    pop rbx
    leave
    ret
.asi_need_char:
    SET_EXC exc_TypeError_type, \
            "array item must be a unicode character"
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC array_store_item

;; asi_acquire_slot(rdi = array, rsi = index or -1 to append)
;;   -> rax = &slot (with OBJ_LOCK rdi HELD), rcx = ob_isize; or rax = 0 (UNLOCKED, exc set)
DEF_FUNC_LOCAL asi_acquire_slot, 16
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    OBJ_LOCK rbx
    cmp r12, -1
    je .aas_append
    test r12, r12
    jl .aas_oor
    cmp r12, [rbx + PyArrayObject.ob_size]
    jge .aas_oor
    jmp .aas_addr
.aas_append:
    mov rdi, rbx
    call array_no_exports
    ERR_NULL .aas_fail
    mov rdi, rbx
    mov rsi, [rbx + PyArrayObject.ob_size]
    mov r12, rsi
    inc rsi
    call array_reserve
    ERR_NULL .aas_fail
.aas_addr:
    mov rax, [rbx + PyArrayObject.ob_data]
    mov rcx, [rbx + PyArrayObject.ob_isize]
    imul r12, rcx
    add rax, r12
    pop r12
    pop rbx
    leave
    ret
.aas_oor:
    OBJ_UNLOCK rbx
    SET_EXC exc_IndexError_type, "array assignment index out of range"
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
.aas_fail:
    OBJ_UNLOCK rbx
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC asi_acquire_slot

section .rodata
asi_m_schar_lo:  db "signed char is less than minimum", 0
asi_m_schar_hi:  db "signed char is greater than maximum", 0
asi_m_ubyte_lo:  db "unsigned byte integer is less than minimum", 0
asi_m_ubyte_hi:  db "unsigned byte integer is greater than maximum", 0
asi_m_short_lo:  db "signed short integer is less than minimum", 0
asi_m_short_hi:  db "signed short integer is greater than maximum", 0
asi_m_ushort_lo: db "unsigned short is less than minimum", 0
asi_m_ushort_hi: db "unsigned short is greater than maximum", 0
asi_m_int_lo:    db "signed integer is less than minimum", 0
asi_m_int_hi:    db "signed integer is greater than maximum", 0
asi_m_uint_neg:  db "can't convert negative value to unsigned int", 0
asi_m_uint_hi:   db "unsigned int is greater than maximum", 0
asi_m_long:      db "Python int too large to convert to C long", 0
asi_m_ulong_hi:  db "Python int too large to convert to C unsigned long", 0
asi_m_toobig:    db "int too big to convert", 0
asi_m_uneg:      db "can't convert negative int to unsigned", 0
align 8
; typecode, then two pairs of (too small, too large): the first for a value
; the C conversion accepted, the second for one that never fit the C type.
asi_msgs:
    dq 'b', asi_m_schar_lo,  asi_m_schar_hi,  asi_m_long,     asi_m_long
    dq 'B', asi_m_ubyte_lo,  asi_m_ubyte_hi,  asi_m_long,     asi_m_long
    dq 'h', asi_m_short_lo,  asi_m_short_hi,  asi_m_long,     asi_m_long
    dq 'H', asi_m_ushort_lo, asi_m_ushort_hi, asi_m_long,     asi_m_long
    dq 'i', asi_m_int_lo,    asi_m_int_hi,    asi_m_long,     asi_m_long
    dq 'I', asi_m_uint_neg,  asi_m_uint_hi,   asi_m_uint_neg, asi_m_ulong_hi
    dq 'l', asi_m_long,      asi_m_long,      asi_m_long,     asi_m_long
    dq 'L', asi_m_uint_neg,  asi_m_ulong_hi,  asi_m_uint_neg, asi_m_ulong_hi
    dq 'q', asi_m_toobig,    asi_m_toobig,    asi_m_toobig,   asi_m_toobig
    dq 'Q', asi_m_uneg,      asi_m_toobig,    asi_m_uneg,     asi_m_toobig
    dq 0, 0, 0, 0, 0
section .text

;; ============================================================================
;; array_int_arg(rdi = payload, edx = tag)
;;   -> edx = 1 and rax = the value as an i64
;;      edx = 2 and rax = a BORROWED PyIntObject* wider than an i64
;;      edx = 0 with an exception pending
;;
;; obj_as_index would do all of this, except that it refuses a value outside
;; i64 with "Python int too large to convert to C ssize_t" -- which is not
;; what any typecode wants to say, and which array('Q', [2**64-1]) should not
;; be refused with at all.  So the int case is unwrapped here, and only what
;; is NOT an int is handed over -- where obj_as_index runs the __index__
;; protocol and words the TypeError.
;; ============================================================================
DEF_FUNC_LOCAL array_int_arg
    cmp edx, TAG_SMALLINT
    je .aia_immediate
    cmp edx, TAG_PTR
    jne .aia_hand_over
    extern int_unwrap
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .aia_immediate
    mov rax, [rdi + PyObject.ob_type]
    REQUIRE_INT_TYPE rax, rcx, .aia_hand_over
    push rdi
    push rdx
    extern int_fits_i64
    call int_fits_i64
    pop rdx
    pop rdi
    test eax, eax
    jz .aia_wide
    extern int_to_i64
    call int_to_i64
    mov edx, 1
    leave
    ret
.aia_wide:
    mov rax, rdi
    mov edx, 2
    leave
    ret
.aia_immediate:
    mov rax, rdi
    mov edx, 1
    leave
    ret
.aia_hand_over:
    ; Use obj_as_index_object so __index__ returning a >63-bit unsigned int
    ; (e.g. Intable(2**64 - 1) for 'L'/'Q') is handled via the wide path
    ; instead of overflowing signed ssize_t in obj_as_index.
    extern obj_as_index_object
    call obj_as_index_object
    ERR_NULL .aia_failed
    V_UNPACK rax, rdx
    cmp edx, TAG_SMALLINT
    je .aia_ho_imm
    push rax
    sub rsp, 8
    mov rdi, rax
    call int_fits_i64
    add rsp, 8
    pop rdi
    test eax, eax
    jz .aia_ho_wide
    push rdi
    sub rsp, 8
    call int_to_i64
    add rsp, 8
    pop rdi
    push rax
    sub rsp, 8
    call obj_decref
    add rsp, 8
    pop rax
    mov edx, 1
    leave
    ret
.aia_ho_wide:
    mov rax, rdi
    mov edx, 3                  ; owned wide PyIntObject*
    leave
    ret
.aia_ho_imm:
    mov edx, 1
    leave
    ret
.aia_failed:
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC array_int_arg

extern array_richcompare_direct

;; ============================================================================
;; array_dealloc(rdi = the array) -> nothing
;; ============================================================================
DEF_FUNC array_dealloc, 8
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyArrayObject.ob_data]
    test rdi, rdi
    jz .ad_no_data
    call ap_free
.ad_no_data:
    mov rdi, rbx
    call ap_free
    pop rbx
    leave
    ret
END_FUNC array_dealloc

;; ============================================================================
;; array_length(rdi = the array) -> rax = the item count
;; ============================================================================
DEF_FUNC_BARE array_length
    mov rax, [rdi + PyArrayObject.ob_size]
    ret
END_FUNC array_length

;; ============================================================================
;; array_sq_item(rdi = the array, rsi = index) -> rax = a Value, or 0 raising
;; Negative indices count from the end, as every sequence here does.
;; ============================================================================
global array_sq_item
DEF_FUNC array_sq_item, 8
    push rbx
    mov rbx, rdi
    OBJ_LOCK rbx
    test rsi, rsi
    jns .asq_have
    add rsi, [rbx + PyArrayObject.ob_size]
.asq_have:
    test rsi, rsi
    jl .asq_unlock_range
    cmp rsi, [rbx + PyArrayObject.ob_size]
    jge .asq_unlock_range
    mov rdi, rbx
    call array_item_value
    OBJ_UNLOCK rbx
    pop rbx
    leave
    ret
.asq_unlock_range:
    OBJ_UNLOCK rbx
.asq_range:
    SET_EXC exc_IndexError_type, "array index out of range"
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    V_PACK rax, rdx
    ret
END_FUNC array_sq_item

;; array_append_value(rdi = the array, rsi = a Value) -> eax = 1
AAV_ARR   equ 8
AAV_VAL   equ 16
AAV_FRAME equ 16
global array_append_value
DEF_FUNC array_append_value, AAV_FRAME
    mov [rbp - AAV_ARR], rdi
    mov [rbp - AAV_VAL], rsi
    call array_no_exports
    ERR_NULL .aav_fail
    mov rdi, [rbp - AAV_ARR]
    mov rsi, -1                     ; append atomically under OBJ_LOCK
    mov rdx, [rbp - AAV_VAL]
    call array_store_item
    test eax, eax
    jz .aav_fail
    mov eax, 1
    leave
    ret
.aav_fail:
    xor eax, eax
    leave
    ret
END_FUNC array_append_value

;; ============================================================================
;; array_extend_iterable(rdi = the array, rsi = a Value) -> eax = 1
;; Fails: 0
;;
;; Another array of the SAME typecode is copied wholesale; anything else is
;; iterated and appended one item at a time, which is what makes the range
;; checks apply to each.
;; ============================================================================
AEI_ARR   equ 8
AEI_ITER  equ 16
AEI_FRAME equ 32            ; + 1 push = 40 ... padded below
global array_extend_iterable
DEF_FUNC array_extend_iterable, 40
    push rbx
    mov [rbp - AEI_ARR], rdi
    mov rbx, rsi

    ; As in array_append_value: the length is about to change.
    call array_no_exports
    ERR_NULL .aei_fail
    mov rdi, [rbp - AEI_ARR]

    ; The same typecode: a straight copy, and the only path that does not go
    ; through the per-item range check -- it cannot need one.
    V_TEST_PTR rbx, rax
    ja .aei_generic
    mov rax, [rbx + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_ARRAY_SUBCLASS
    jz .aei_generic
    mov rcx, [rbx + PyArrayObject.ob_code]
    cmp rcx, [rdi + PyArrayObject.ob_code]
    jne .aei_generic

    OBJ_LOCK2 rdi, rbx
    call array_no_exports
    ERR_NULL .aei_unlock2_fail
    mov rdi, [rbp - AEI_ARR]
    mov rsi, [rdi + PyArrayObject.ob_size]
    add rsi, [rbx + PyArrayObject.ob_size]
    call array_reserve
    ERR_NULL .aei_unlock2_fail
    mov rdi, [rbp - AEI_ARR]
    mov rax, [rdi + PyArrayObject.ob_size]
    imul rax, [rdi + PyArrayObject.ob_isize]
    mov rcx, [rdi + PyArrayObject.ob_data]
    lea rdi, [rcx + rax]
    mov rsi, [rbx + PyArrayObject.ob_data]
    mov rdx, [rbx + PyArrayObject.ob_size]
    imul rdx, [rbx + PyArrayObject.ob_isize]
    test rdx, rdx
    jz .aei_copied
    call ap_memcpy
.aei_copied:
    mov rdi, [rbp - AEI_ARR]
    mov rax, [rbx + PyArrayObject.ob_size]
    add [rdi + PyArrayObject.ob_size], rax
    OBJ_UNLOCK2 rdi, rbx
    mov eax, 1
    pop rbx
    leave
    ret
.aei_unlock2_fail:
    mov rdi, [rbp - AEI_ARR]
    OBJ_UNLOCK2 rdi, rbx
    jmp .aei_fail

.aei_generic:
    ; The real tag, not TAG_PTR: array('i', 5) hands an int IMMEDIATE here,
    ; and calling it a pointer dereferences the number 5.
    mov rdi, rbx
    V_UNPACK rdi, rsi
    call get_iterator_opt
    ERR_PENDING .aei_fail
    test rax, rax
    jz .aei_not_iterable
    mov [rbp - AEI_ITER], rax
.aei_loop:
    mov rdi, [rbp - AEI_ITER]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .aei_done
    call rax
    test rax, rax
    jz .aei_done
    mov rbx, rax
    mov rdi, [rbp - AEI_ARR]
    mov rsi, rax
    call array_append_value     ; err: tested below, once the item is released
    push rax
    ; DECREF_V, not obj_decref: tp_iternext answers a VALUE, and an int
    ; immediate is not a pointer to dereference.
    mov rdi, rbx
    DECREF_V rdi, rcx
    pop rax
    test eax, eax
    jz .aei_iter_fail
    jmp .aei_loop
.aei_done:
    mov rdi, [rbp - AEI_ITER]
    call obj_decref
    cmp qword [gs:ThreadState.current_exception], 0
    jne .aei_fail
    mov eax, 1
    pop rbx
    leave
    ret
.aei_iter_fail:
    mov rdi, [rbp - AEI_ITER]
    call obj_decref
.aei_fail:
    xor eax, eax
    pop rbx
    leave
    ret
.aei_not_iterable:
    FAIL exc_TypeError_type, "cannot extend array from a non-iterable", .aei_fail
END_FUNC array_extend_iterable

;; ============================================================================
;; array_type_new(rdi = the type, rsi = args, rdx = nargs) -> a Value
;;   array(typecode[, initializer])
;;
;; The tp_new signature every builtin constructor takes: the type comes first,
;; and the arguments as written follow it.
;; ============================================================================
ATN_CODE  equ 8
ATN_ARR   equ 16
ATN_ARGS  equ 24
ATN_NARGS equ 32
ATN_TYPE  equ 40
ATN_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
global array_type_new
DEF_FUNC array_type_new, ATN_FRAME
    mov [rbp - ATN_TYPE], rdi
    mov [rbp - ATN_ARGS], rsi
    mov [rbp - ATN_NARGS], rdx

    ; Handle keyword arguments: array.array() refuses them, while a subclass
    ; (e.g. ArraySubclassWithKwargs('b', newarg=1)) passes kwargs through to
    ; __init__, so tp_new strips them from nargs.
    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jz .atn_no_kw
    mov qword [gs:ThreadState.kw_names_pending], 0
    lea rcx, [rel array_type]
    cmp rdi, rcx
    je .atn_kw_err
    mov rcx, [rax + PyTupleObject.ob_size]
    sub rdx, rcx
    mov [rbp - ATN_NARGS], rdx
.atn_no_kw:
    cmp rdx, 1
    jb .atn_arity
    cmp rdx, 2
    ja .atn_arity

    ; args[0] is the typecode.  CPython draws two different lines here: a
    ; one-character str that names no code is a ValueError about the code,
    ; and anything that is not a one-character str at all is a TypeError
    ; about the ARGUMENT, naming the type it got.
    mov rdi, [rsi]
    mov [rbp - ATN_ARR], rdi    ; the argument, for the message
    V_TEST_PTR rdi, rax
    ja .atn_not_a_char
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .atn_str_ok
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .atn_not_a_char
.atn_str_ok:
    cmp qword [rdi + PyStrObject.ob_length], 1
    jne .atn_not_a_char
    movzx edi, byte [rdi + PyStrObject.data]
    call array_find_code
    test rax, rax
    jz .atn_bad_code
    mov [rbp - ATN_CODE], rax

    mov rdi, rax
    mov rsi, [rbp - ATN_TYPE]
    call array_new_empty_type
    test rax, rax
    jz .atn_null
    mov [rbp - ATN_ARR], rax

    cmp qword [rbp - ATN_NARGS], 2
    jb .atn_done
    mov rsi, [rbp - ATN_ARGS]
    mov rsi, [rsi + 8]          ; args[1], one Value per slot

    ; Dispatch initializer like CPython's array_new:
    ;   - bytes / bytearray -> frombytes (raw scalar bytes)
    ;   - str -> fromunicode for 'u', TypeError otherwise
    ;   - unicode array -> TypeError for non-'u'
    ;   - anything else -> extend iterable
    V_TEST_PTR rsi, rcx
    ja .atn_init_iter
    mov rcx, [rsi + PyObject.ob_type]
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    je .atn_init_bytes
    test qword [rcx + PyTypeObject.tp_flags], \
         TYPE_FLAG_BYTES_SUBCLASS | TYPE_FLAG_BYTEARRAY_SUBCLASS
    jnz .atn_init_bytes
    lea rdx, [rel str_type]
    cmp rcx, rdx
    je .atn_init_str
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jnz .atn_init_str
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_ARRAY_SUBCLASS
    jz .atn_init_iter
    ; Another array: refuse unicode array -> non-unicode array
    cmp qword [rsi + PyArrayObject.ob_code], 'u'
    jne .atn_init_iter
    mov rdi, [rbp - ATN_ARR]
    cmp qword [rdi + PyArrayObject.ob_code], 'u'
    jne .atn_bad_uarray
    jmp .atn_init_iter

.atn_init_bytes:
    mov rdi, [rbp - ATN_ARR]
    call array_frombytes_raw
    ERR_NULL .atn_drop
    jmp .atn_done

.atn_init_str:
    mov rdi, [rbp - ATN_ARR]
    cmp qword [rdi + PyArrayObject.ob_code], 'u'
    jne .atn_bad_str
    call array_fromunicode_str
    ERR_NULL .atn_drop
    jmp .atn_done

.atn_init_iter:
    mov rdi, [rbp - ATN_ARR]
    call array_extend_iterable
    ERR_NULL .atn_drop

.atn_done:
    mov rax, [rbp - ATN_ARR]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.atn_bad_str:
    SET_EXC exc_TypeError_type, \
            "cannot use a str to initialize an array with non-'u' typecode"
    jmp .atn_drop
.atn_bad_uarray:
    SET_EXC exc_TypeError_type, \
            "cannot use a unicode array to initialize an array with non-'u' typecode"
.atn_drop:
    mov rdi, [rbp - ATN_ARR]
    call obj_decref
.atn_null:
    RET_NULL                    ; tp_new: rax = 0 and edx = 0
    leave
    ret
.atn_kw_err:
    FAIL exc_TypeError_type, "array.array() takes no keyword arguments", .atn_null
.atn_bad_code:
    FAIL exc_ValueError_type, \
          "bad typecode (must be b, B, u, h, H, i, I, l, L, q, Q, f or d)", \
          .atn_null
.atn_not_a_char:
    ; CPython's \x02 form spells NoneType as "None", which is what this
    ; message wants: "not None", not "not NoneType".
    mov rsi, [rbp - ATN_ARR]
    CSTRING rdi, \
        `array() argument 1 must be a unicode character, not \x02`
    extern set_type_error_with_name
    call set_type_error_with_name
    jmp .atn_null
.atn_arity:
    FAIL exc_TypeError_type, \
          "array() takes 1 or 2 arguments", .atn_null
END_FUNC array_type_new

;; ============================================================================
;; array_tolist(rdi = the array) -> rax = a new list
;; Fails: 0
;; ============================================================================
ATL_ARR   equ 8
ATL_LIST  equ 16
ATL_I     equ 24
ATL_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
global array_tolist
DEF_FUNC array_tolist, ATL_FRAME
    mov [rbp - ATL_ARR], rdi
    xor edi, edi
    call list_new
    test rax, rax
    jz .atl_null
    mov [rbp - ATL_LIST], rax
    mov qword [rbp - ATL_I], 0
.atl_loop:
    mov rdi, [rbp - ATL_ARR]
    OBJ_LOCK rdi
    mov rsi, [rbp - ATL_I]
    cmp rsi, [rdi + PyArrayObject.ob_size]
    jge .atl_unlock_done
    call array_item_value
    mov rcx, [rbp - ATL_ARR]
    OBJ_UNLOCK rcx
    test rax, rax
    jz .atl_drop
    push rax
    mov rdi, [rbp - ATL_LIST]
    mov rsi, rax
    call list_append          ; err: a list built here is not being sorted
    pop rdi
    DECREF_V rdi, rcx
    inc qword [rbp - ATL_I]
    jmp .atl_loop
.atl_unlock_done:
    OBJ_UNLOCK rdi
.atl_done:
    mov rax, [rbp - ATL_LIST]
    leave
    ret
.atl_drop:
    mov rdi, [rbp - ATL_LIST]
    call obj_decref
.atl_null:
    xor eax, eax
    leave
    ret
END_FUNC array_tolist

;; ============================================================================
;; array_repr(rdi = the array) -> (rax = a str, edx = TAG_PTR), or (0, 0)
;;   array('i', [1, 2, 3]), and array('i') when it is empty
;;
;; The TAG matters: print reads it back from obj_str and skips an argument
;; whose tag is zero, so a repr that answers only in rax prints an empty line.
;;
;; Composed from the LIST's repr rather than written out item by item.  An
;; array's repr has no length bound, and list_repr already owns the growable
;; buffer and the recursion guard that needs; duplicating either here would be
;; duplicating the part that is easy to get wrong.
;; ============================================================================
ARP_ARR   equ 8
ARP_LIST  equ 16
ARP_INNER equ 24
ARP_BUF   equ 32
ARP_END   equ 40        ; where the inner repr is copied to
ARP_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC array_repr, ARP_FRAME
    mov [rbp - ARP_ARR], rdi
    mov qword [rbp - ARP_LIST], 0
    mov qword [rbp - ARP_INNER], 0

    cmp qword [rdi + PyArrayObject.ob_size], 0
    jne .arp_with_items

    ; array('X')
    sub rsp, 32
    mov rdi, rsp
    lea rsi, [rel arp_open]
    call rbt_append_cstr
    mov rcx, [rbp - ARP_ARR]
    mov rcx, [rcx + PyArrayObject.ob_code]
    mov [rax], cl
    mov byte [rax + 1], 0
    lea rdi, [rax + 1]
    lea rsi, [rel arp_tail_empty]
    call rbt_append_cstr
    mov rdi, rsp
    call str_from_cstr_heap
    add rsp, 32
    mov edx, TAG_PTR
    leave
    ret

.arp_with_items:
    cmp qword [rdi + PyArrayObject.ob_code], 'u'
    jne .arp_not_unicode
    call array_tounicode_str
    ERR_NULL .arp_null
    jmp .arp_have_obj
.arp_not_unicode:
    call array_tolist
    ERR_NULL .arp_null
.arp_have_obj:
    mov [rbp - ARP_LIST], rax
    mov rdi, rax
    extern obj_repr
    call obj_repr
    test rax, rax
    jz .arp_drop
    mov [rbp - ARP_INNER], rax

    ; "array('X', " + inner + ")"
    mov rcx, [rax + PyStrObject.ob_size]
    lea rdi, [rcx + 32]
    call ap_malloc
    test rax, rax
    jz .arp_drop
    mov [rbp - ARP_BUF], rax
    mov rdi, rax
    lea rsi, [rel arp_open]
    call rbt_append_cstr
    mov rcx, [rbp - ARP_ARR]
    mov rcx, [rcx + PyArrayObject.ob_code]
    mov [rax], cl
    mov byte [rax + 1], 0
    lea rdi, [rax + 1]
    lea rsi, [rel arp_tail_items]
    call rbt_append_cstr

    ; The inner repr is copied, not appended: rbt_append_cstr is bounded at 80
    ; bytes because it builds ERROR messages, where a field that long is a
    ; hostile type name.  An array's repr has no such bound, and going through
    ; it truncated every array of more than about twenty items mid-token.
    mov rsi, [rbp - ARP_INNER]
    mov rdx, [rsi + PyStrObject.ob_size]
    lea rcx, [rax + rdx]
    mov [rbp - ARP_END], rcx
    mov rdi, rax
    lea rsi, [rsi + PyStrObject.data]
    call ap_memcpy
    mov rdi, [rbp - ARP_END]
    lea rsi, [rel arp_close_paren]
    call rbt_append_cstr

    mov rdi, [rbp - ARP_BUF]
    call str_from_cstr_heap
    push rax
    mov rdi, [rbp - ARP_BUF]
    call ap_free
    mov rdi, [rbp - ARP_INNER]
    call obj_decref
    mov rdi, [rbp - ARP_LIST]
    call obj_decref
    pop rax
    mov edx, TAG_PTR
    leave
    ret

.arp_drop:
    mov rdi, [rbp - ARP_INNER]
    test rdi, rdi
    jz .arp_drop_list
    call obj_decref
.arp_drop_list:
    mov rdi, [rbp - ARP_LIST]
    test rdi, rdi
    jz .arp_null
    call obj_decref
.arp_null:
    xor eax, eax
    leave
    ret
END_FUNC array_repr

section .rodata
arp_open:        db "array('", 0
arp_tail_empty:  db "')", 0
arp_tail_items:  db "', ", 0
arp_close_paren: db ")", 0
section .text

;; ============================================================================
;; array_subscript(rdi = the array, rsi = the key Value) -> rax = a Value
;; Integer indices only for now; a slice is the one thing left out.
;; ============================================================================
DEF_FUNC array_subscript, 8   ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, rsi
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .asub_fail
    mov rdi, rbx
    mov rsi, rax
    pop rbx
    leave
    jmp array_sq_item
.asub_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    V_PACK rax, rdx
    ret
END_FUNC array_subscript

extern array_concat
extern array_inplace_concat
extern array_repeat
extern array_inplace_repeat
extern array_contains
extern array_subscript_full
extern array_ass_subscript_full
extern array_m_add
extern array_m_iadd
extern array_m_mul
extern array_m_imul
extern array_m_contains
extern array_m_delitem
extern array_m_iter
extern array_m_insert
extern array_m_pop
extern array_m_remove
extern array_m_index
extern array_m_count
extern array_m_reverse
extern array_m_copy
extern array_m_deepcopy
extern array_m_reduce_ex
extern array__array_reconstructor
extern array_reconstructor_func
extern array_str___dict__

;; ============================================================================
;; array_ass_subscript_int(rdi = the array, rsi = key Value, rdx = value Value)
;;   -> eax = 0 on success, or -1 raising.  A NULL value is `del a[i]`.
;; ============================================================================
AAS_ARR   equ 8
AAS_VAL   equ 16
AAS_IDX   equ 24
AAS_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
global array_ass_subscript_int
DEF_FUNC array_ass_subscript_int, AAS_FRAME
    mov [rbp - AAS_ARR], rdi
    mov [rbp - AAS_VAL], rdx
    mov rdi, rsi
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .aas_fail
    mov rdi, [rbp - AAS_ARR]
    test rax, rax
    jns .aas_have
    add rax, [rdi + PyArrayObject.ob_size]
.aas_have:
    test rax, rax
    jl .aas_range
    cmp rax, [rdi + PyArrayObject.ob_size]
    jge .aas_range
    mov [rbp - AAS_IDX], rax

    cmp qword [rbp - AAS_VAL], 0
    je .aas_delete

    mov rsi, rax
    mov rdx, [rbp - AAS_VAL]
    call array_store_item
    test eax, eax
    jz .aas_fail
    xor eax, eax
    leave
    ret

.aas_delete:
    mov rdi, [rbp - AAS_ARR]
    OBJ_LOCK rdi
    call array_no_exports
    ERR_NULL .aas_unlock_fail
    mov rdi, [rbp - AAS_ARR]
    mov rax, [rbp - AAS_IDX]
    cmp rax, [rdi + PyArrayObject.ob_size]
    jge .aas_unlock_range
    mov rcx, [rdi + PyArrayObject.ob_isize]
    imul rax, rcx
    mov rsi, [rdi + PyArrayObject.ob_data]
    lea rdi, [rsi + rax]        ; dest = &item[i]
    lea rsi, [rdi + rcx]        ; src  = &item[i+1]
    mov rdx, [rbp - AAS_ARR]
    mov rdx, [rdx + PyArrayObject.ob_size]
    sub rdx, [rbp - AAS_IDX]
    dec rdx
    imul rdx, rcx               ; bytes after the hole
    test rdx, rdx
    jz .aas_shrink
    extern ap_memmove
    call ap_memmove
.aas_shrink:
    mov rdi, [rbp - AAS_ARR]
    dec qword [rdi + PyArrayObject.ob_size]
    OBJ_UNLOCK rdi
    xor eax, eax
    leave
    ret

.aas_unlock_fail:
    mov rdi, [rbp - AAS_ARR]
    OBJ_UNLOCK rdi
.aas_fail:
    mov eax, -1
    leave
    ret
.aas_unlock_range:
    mov rdi, [rbp - AAS_ARR]
    OBJ_UNLOCK rdi
.aas_range:
    SET_EXC exc_IndexError_type, "array assignment index out of range"
    mov eax, -1
    leave
    ret
END_FUNC array_ass_subscript_int

section .data
align 8
array_seq_methods:
    dq array_length             ; +0:  sq_length
    dq array_concat             ; +8:  sq_concat
    dq array_repeat             ; +16: sq_repeat
    ; sq_item is what reversed() looks for, and mp_subscript does not cover it.
    dq array_sq_item            ; +24: sq_item
    dq 0                        ; +32: sq_ass_item (mp_ass_subscript covers it)
    dq array_contains           ; +40: sq_contains
    dq array_inplace_concat     ; +48: sq_inplace_concat
    dq array_inplace_repeat     ; +56: sq_inplace_repeat

align 8
array_mapping_methods:
    dq array_length             ; mp_length        +0
    dq array_subscript_full     ; mp_subscript     +8
    dq array_ass_subscript_full ; mp_ass_subscript +16

align 8
global array_type
section .text

;; ============================================================================
;; array_getbuffer(rdi = an array, esi = BUF_GET / BUF_ACQUIRE / BUF_RELEASE)
;;   -> for BUF_GET: rax = data, rdx = length in BYTES, ecx = 1 always
;;
;; The tp_as_buffer slot.  An array is a flat run of fixed-size scalars, which
;; is exactly what a buffer consumer wants; `memoryview(array('i', [1, 2]))`
;; was "a bytes-like object is required" before there was a slot to ask.
;;
;; ob_size counts ITEMS and every consumer counts bytes, so the length is
;; ob_size * ob_isize.  An empty array has no buffer at all, and answers a
;; length of zero over a pointer nothing will read.
;;
;; The other two modes are the accounting a LASTING view needs.  A view keeps
;; the pointer and an array's buffer MOVES when it grows -- array_reserve
;; reallocs -- so `m = memoryview(a)` then `a.append(x)` left the view aimed at
;; freed memory, and reading it printed whatever the allocator had put there.
;; ============================================================================
DEF_FUNC_BARE array_getbuffer
    cmp esi, BUF_GETINFO
    je .agb_info
    cmp esi, BUF_GET
    jne .agb_count
    mov rax, [rdi + PyArrayObject.ob_data]
    mov rdx, [rdi + PyArrayObject.ob_size]
    imul rdx, [rdi + PyArrayObject.ob_isize]
    test rax, rax
    jnz .agb_yes
    xor edx, edx                ; no buffer: nothing to read, and no length
    lea rax, [rel array_empty_data]
.agb_yes:
    mov ecx, 1
    ret
.agb_info:
    ; What a memoryview needs and a byte reader does not: the item size, the
    ; struct format, and whether it may be written through.  Without this the
    ; view was built with the slot's defaults -- one-byte items, format "B",
    ; read-only -- so memoryview(array("i", [1, 2, 3])) had length 12 and
    ; tolist() answered the twelve bytes.
    ;
    ; Writable, because an array's storage moving is what ob_exports is for:
    ; array_reserve refuses to grow while a view is out, so the pointer the
    ; view holds cannot go stale under it.
    mov rdx, [rdi + PyArrayObject.ob_isize]
    mov rax, [rdi + PyArrayObject.ob_code]
    and eax, 0x7f
    shl eax, 1
    lea rcx, [rel array_format_strs]
    add rax, rcx
    mov ecx, 1
    ret
.agb_count:
    OBJ_LOCK rdi
    cmp esi, BUF_ACQUIRE
    jne .agb_release
    inc qword [rdi + PyArrayObject.ob_exports]
    OBJ_UNLOCK rdi
    ret
.agb_release:
    cmp qword [rdi + PyArrayObject.ob_exports], 0
    jle .agb_done
    dec qword [rdi + PyArrayObject.ob_exports]
.agb_done:
    OBJ_UNLOCK rdi
    ret
END_FUNC array_getbuffer

section .rodata
align 2
;; One NUL-terminated string per ASCII typecode letter, so array_getbuffer can
;; hand a memoryview a format pointer without allocating: the string for
;; letter n is at array_format_strs + n*2.  256 bytes of rodata against a
;; fourteen-row table and a search; the letters are the index.
array_format_strs:
%assign afs_i 0
%rep 128
    db afs_i, 0
%assign afs_i afs_i+1
%endrep

section .text

;; ============================================================================
;; array_no_exports(rdi = an array) -> eax = 1 when it may be resized
;; Fails: 0
;; (the BufferError a live export refuses a resize with)
;;
;; CPython's array_resize makes this test first, with this wording.
;; ============================================================================
global array_no_exports
DEF_FUNC array_no_exports
    cmp qword [rdi + PyArrayObject.ob_exports], 0
    jne .anx_exporting
    mov eax, 1
    leave
    ret
.anx_exporting:
    extern exc_BufferError_type
    SET_EXC exc_BufferError_type, "cannot resize an array that is exporting buffers"
    xor eax, eax
    leave
    ret
END_FUNC array_no_exports

section .rodata
array_empty_data: db 0

; Back to the section the table below lives in: it is WRITTEN at start-up --
; array_module_create stores its tp_dict -- so leaving it in .text faults on
; that store.  lint checks for a function emitted in a DATA section; this is
; the mirror of it, and nothing checks for it.
section .data

align 8
array_type:
    dq 0x00000000FFFFFFFF       ; ob_ref_local=IMMORTAL, ob_ref_shared=0
    dq 0                        ; ob_tid=0 (immortal), ob_mutex=0
    dq type_type                ; ob_type
    dq array_name_str           ; tp_name
    dq PyArrayObject_size       ; tp_basicsize (the data is out of line)
    dq array_dealloc            ; tp_dealloc
    dq array_repr               ; tp_repr
    dq array_repr               ; tp_str
    ; Mutable, therefore unhashable -- and a 0 here is not the same thing:
    ; obj_hash falls through to the ADDRESS, so the key could never be found
    ; again.
    dq hash_not_implemented     ; tp_hash
    dq 0                        ; tp_call (set by add_builtin_type)
    dq array_getattr            ; tp_getattr (typecode, itemsize)
    dq 0                        ; tp_setattr
    dq array_richcompare_direct ; tp_richcompare
    dq array_tp_iter            ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new (set by add_builtin_type)
    dq 0                        ; tp_as_number
    dq array_seq_methods        ; tp_as_sequence
    dq array_mapping_methods    ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    ; Subclassable like bytearray (fixed header + out-of-line scalar buffer).
    dq TYPE_FLAG_BASETYPE | TYPE_FLAG_ARRAY_SUBCLASS ; tp_flags
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq array_getbuffer          ; tp_as_buffer -- a flat run of scalars
section .text

;; ============================================================================
;; The methods, each (args, nargs) with args[0] the array.
;; ============================================================================

;; array_m_append(args, nargs) -> None, or 0 raising
DEF_FUNC array_m_append
    cmp rsi, 2
    jne .ama_arity
    mov rdx, [rdi + 8]
    mov rdi, [rdi]
    mov rsi, rdx
    call array_append_value
    ERR_NULL .ama_fail
    LOAD_NONE rax
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.ama_fail:
    xor eax, eax
    xor edx, edx
    leave
    V_PACK rax, rdx
    ret
.ama_arity:
    FAIL exc_TypeError_type, "append() takes exactly one argument", .ama_fail
END_FUNC array_m_append

;; array_m_extend(args, nargs) -> None, or 0 raising
DEF_FUNC array_m_extend
    cmp rsi, 2
    jne .ame_arity
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    ; Extending with another array of a DIFFERENT typecode is a TypeError
    ; (unlike the constructor array(tc1, array(tc2, ...)), which iterates).
    V_TEST_PTR rsi, rax
    ja .ame_go
    mov rax, [rsi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_ARRAY_SUBCLASS
    jz .ame_go
    mov rcx, [rdi + PyArrayObject.ob_code]
    cmp rcx, [rsi + PyArrayObject.ob_code]
    jne .ame_bad_kind
.ame_go:
    call array_extend_iterable
    ERR_NULL .ame_fail
    LOAD_NONE rax
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.ame_bad_kind:
    FAIL exc_TypeError_type, "can only extend with array of same kind", .ame_fail
.ame_fail:
    xor eax, eax
    xor edx, edx
    leave
    V_PACK rax, rdx
    ret
.ame_arity:
    FAIL exc_TypeError_type, "extend() takes exactly one argument", .ame_fail
END_FUNC array_m_extend

;; array_m_tolist(args, nargs) -> a list of the items
DEF_FUNC array_m_tolist
    cmp rsi, 1
    jne .amt_arity
    mov rdi, [rdi]
    call array_tolist           ; err: its 0 is this method's own
    mov edx, TAG_PTR
    test rax, rax
    jnz .amt_ok
    xor edx, edx
.amt_ok:
    leave
    V_PACK rax, rdx
    ret
.amt_arity:
    SET_EXC exc_TypeError_type, "tolist() takes no arguments"
    xor eax, eax
    leave
    ret
END_FUNC array_m_tolist

;; array_m_fromlist(args, nargs) -> None, or 0 raising
;; Requires a list (or list subclass) and rolls back partial appends on error.
AMFL_ARR  equ 8
AMFL_OLD  equ 16
AMFL_FRAME equ 16               ; 0 pushes, 16-aligned
extern list_type
DEF_FUNC array_m_fromlist, AMFL_FRAME
    cmp rsi, 2
    jne .amfl_arity
    mov rax, [rdi]
    mov [rbp - AMFL_ARR], rax
    mov rsi, [rdi + 8]
    V_TEST_PTR rsi, rcx
    ja .amfl_not_list
    mov rcx, [rsi + PyObject.ob_type]
    lea rdx, [rel list_type]
    cmp rcx, rdx
    je .amfl_ok_list
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_LIST_SUBCLASS
    jz .amfl_not_list
.amfl_ok_list:
    mov rdx, [rax + PyArrayObject.ob_size]
    mov [rbp - AMFL_OLD], rdx
    mov rdi, rax
    call array_extend_iterable
    ERR_NULL .amfl_rollback
    LOAD_NONE rax
    INCREF rax
    leave
    ret
.amfl_rollback:
    mov rdi, [rbp - AMFL_ARR]
    OBJ_LOCK rdi
    mov rdx, [rbp - AMFL_OLD]
    mov [rdi + PyArrayObject.ob_size], rdx
    OBJ_UNLOCK rdi
    xor eax, eax
    leave
    ret
.amfl_not_list:
    SET_EXC exc_TypeError_type, "arg must be list"
    xor eax, eax
    leave
    ret
.amfl_arity:
    SET_EXC exc_TypeError_type, "fromlist() takes exactly one argument"
    xor eax, eax
    leave
    ret
END_FUNC array_m_fromlist

;; array_m_tobytes(args, nargs) -> the raw buffer as bytes
global array_m_tobytes
DEF_FUNC array_m_tobytes, 8
    push rbx
    cmp rsi, 1
    jne .amb_arity
    mov rbx, [rdi]
    OBJ_LOCK rbx
    mov rsi, [rbx + PyArrayObject.ob_size]
    imul rsi, [rbx + PyArrayObject.ob_isize]
    mov rdi, [rbx + PyArrayObject.ob_data]
    test rdi, rdi
    jnz .amb_have
    lea rdi, [rel array_empty_byte]
.amb_have:
    call bytes_from_data
    OBJ_UNLOCK rbx
    mov edx, TAG_PTR
    test rax, rax
    jnz .amb_ok
    xor edx, edx
.amb_ok:
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.amb_arity:
    FAIL exc_TypeError_type, "tobytes() takes no arguments", .amb_fail
.amb_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    V_PACK rax, rdx
    ret
END_FUNC array_m_tobytes

;; ============================================================================
;; array_frombytes_raw(rdi = arr, rsi = bytes-like Value) -> eax = 1 or 0
;; Fails: 0
;; ============================================================================
AFB_ARR   equ 8
AFB_SRC   equ 16            ; the incoming data pointer, whatever held it
AFB_LEN   equ 24            ; and its length in bytes
AFB_CNT   equ 32            ; item count coming in
AFB_FRAME equ 40            ; + 1 push (rbx) = 48, 16-aligned
global array_frombytes_raw
DEF_FUNC array_frombytes_raw, AFB_FRAME
    push rbx
    mov [rbp - AFB_ARR], rdi
    mov rbx, rsi

    ; As in array_append_value: the length is about to change.
    call array_no_exports
    ERR_NULL .afb_fail

    ; Anything bytes-LIKE, which is what CPython takes: bytes, bytearray, or
    ; memoryview (including bytes/bytearray subclasses).
    V_TEST_PTR rbx, rax
    ja .afb_need_bytes
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .afb_kind_ok
    test qword [rax + PyTypeObject.tp_flags], \
         TYPE_FLAG_BYTES_SUBCLASS | TYPE_FLAG_BYTEARRAY_SUBCLASS
    jnz .afb_kind_ok
    extern memoryview_type
    lea rcx, [rel memoryview_type]
    cmp rax, rcx
    jne .afb_need_bytes
.afb_kind_ok:
    mov rdi, rbx
    extern bytes_like_ptr_len
    call bytes_like_ptr_len
    test ecx, ecx
    jz .afb_need_bytes
    mov [rbp - AFB_SRC], rax    ; where the incoming bytes are
    mov [rbp - AFB_LEN], r10    ; and how many there are
    mov rdi, [rbp - AFB_ARR]
    mov rax, r10
    xor edx, edx
    mov rcx, [rdi + PyArrayObject.ob_isize]
    div rcx
    test rdx, rdx
    jnz .afb_not_multiple
    mov [rbp - AFB_CNT], rax    ; the item count coming in
    test rax, rax
    jz .afb_done
    mov rdi, [rbp - AFB_ARR]
    OBJ_LOCK rdi
    call array_no_exports
    ERR_NULL .afb_unlock_fail
    mov rdi, [rbp - AFB_ARR]
    mov rsi, [rbp - AFB_CNT]
    add rsi, [rdi + PyArrayObject.ob_size]
    call array_reserve
    ERR_NULL .afb_unlock_fail

    mov rdi, [rbp - AFB_ARR]
    mov rax, [rdi + PyArrayObject.ob_size]
    imul rax, [rdi + PyArrayObject.ob_isize]
    add rax, [rdi + PyArrayObject.ob_data]
    mov rdi, rax
    mov rsi, [rbp - AFB_SRC]
    mov rdx, [rbp - AFB_LEN]
    call ap_memcpy
    mov rsi, [rbp - AFB_CNT]
    mov rdi, [rbp - AFB_ARR]
    add [rdi + PyArrayObject.ob_size], rsi
    OBJ_UNLOCK rdi
    jmp .afb_done
.afb_unlock_fail:
    mov rdi, [rbp - AFB_ARR]
    OBJ_UNLOCK rdi
    jmp .afb_fail

.afb_done:
    mov eax, 1
    pop rbx
    leave
    ret
.afb_fail:
    xor eax, eax
    pop rbx
    leave
    ret
.afb_need_bytes:
    FAIL exc_TypeError_type, "a bytes-like object is required", .afb_fail
.afb_not_multiple:
    FAIL exc_ValueError_type, \
          "bytes length not a multiple of item size", .afb_fail
END_FUNC array_frombytes_raw

;; array_m_frombytes(args, nargs) -> None
global array_m_frombytes
DEF_FUNC array_m_frombytes
    cmp rsi, 2
    jne .amfb_arity
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call array_frombytes_raw
    ERR_NULL .amfb_fail
    LOAD_NONE rax
    INCREF rax
    leave
    ret
.amfb_arity:
    SET_EXC exc_TypeError_type, "frombytes() takes exactly one argument"
.amfb_fail:
    xor eax, eax
    leave
    ret
END_FUNC array_m_frombytes

;; ============================================================================
;; array_fromunicode_str(rdi = arr, rsi = str Value) -> eax = 1 or 0
;; Fails: 0
;; Decodes UTF-8 codepoints from str into a 'u' array's uint32 buffer.
;; ============================================================================
AFU_ARR   equ 8
AFU_STR   equ 16
AFU_NADD  equ 24
AFU_FRAME equ 40            ; + 1 push (rbx) = 48, 16-aligned
global array_fromunicode_str
DEF_FUNC array_fromunicode_str, AFU_FRAME
    push rbx
    mov [rbp - AFU_ARR], rdi
    mov [rbp - AFU_STR], rsi

    cmp qword [rdi + PyArrayObject.ob_code], 'u'
    jne .afu_not_u
    V_TEST_PTR rsi, rax
    ja .afu_not_str
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .afu_str_ok
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .afu_not_str
.afu_str_ok:
    call array_no_exports
    ERR_NULL .afu_fail
    mov rsi, [rbp - AFU_STR]
    mov rax, [rsi + PyStrObject.ob_length]
    mov [rbp - AFU_NADD], rax
    test rax, rax
    jz .afu_ok

    mov rdi, [rbp - AFU_ARR]
    OBJ_LOCK rdi
    call array_no_exports
    ERR_NULL .afu_unlock_fail
    mov rdi, [rbp - AFU_ARR]
    mov rsi, [rdi + PyArrayObject.ob_size]
    add rsi, [rbp - AFU_NADD]
    call array_reserve
    ERR_NULL .afu_unlock_fail

    mov rbx, [rbp - AFU_ARR]
    mov rax, [rbx + PyArrayObject.ob_size]
    shl rax, 2
    add rax, [rbx + PyArrayObject.ob_data]  ; dst = &data[ob_size]
    mov rdi, rax
    mov rdx, [rbp - AFU_STR]
    lea rsi, [rdx + PyStrObject.data]
    mov rcx, [rbp - AFU_NADD]
.afu_loop:
    test rcx, rcx
    jz .afu_done_copy
    movzx eax, byte [rsi]
    cmp eax, 0x80
    jb .afu_1b
    cmp eax, 0xE0
    jb .afu_2b
    cmp eax, 0xF0
    jb .afu_3b
    ; 4-byte UTF-8
    and eax, 0x07
    shl eax, 18
    movzx r8d, byte [rsi + 1]
    and r8d, 0x3F
    shl r8d, 12
    or eax, r8d
    movzx r8d, byte [rsi + 2]
    and r8d, 0x3F
    shl r8d, 6
    or eax, r8d
    movzx r8d, byte [rsi + 3]
    and r8d, 0x3F
    or eax, r8d
    add rsi, 4
    jmp .afu_store
.afu_3b:
    and eax, 0x0F
    shl eax, 12
    movzx r8d, byte [rsi + 1]
    and r8d, 0x3F
    shl r8d, 6
    or eax, r8d
    movzx r8d, byte [rsi + 2]
    and r8d, 0x3F
    or eax, r8d
    add rsi, 3
    jmp .afu_store
.afu_2b:
    and eax, 0x1F
    shl eax, 6
    movzx r8d, byte [rsi + 1]
    and r8d, 0x3F
    or eax, r8d
    add rsi, 2
    jmp .afu_store
.afu_1b:
    inc rsi
.afu_store:
    mov [rdi], eax
    add rdi, 4
    dec rcx
    jmp .afu_loop

.afu_done_copy:
    mov rax, [rbp - AFU_NADD]
    add [rbx + PyArrayObject.ob_size], rax
    OBJ_UNLOCK rbx
.afu_ok:
    mov eax, 1
    pop rbx
    leave
    ret
.afu_unlock_fail:
    mov rdi, [rbp - AFU_ARR]
    OBJ_UNLOCK rdi
.afu_fail:
    xor eax, eax
    pop rbx
    leave
    ret
.afu_not_u:
    FAIL exc_ValueError_type, \
         "fromunicode() may only be called on unicode type arrays", .afu_fail
.afu_not_str:
    FAIL exc_TypeError_type, "fromunicode() argument must be str", .afu_fail
END_FUNC array_fromunicode_str

;; array_m_fromunicode(args, nargs) -> None
DEF_FUNC array_m_fromunicode
    cmp rsi, 2
    jne .amfu_arity
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call array_fromunicode_str
    ERR_NULL .amfu_fail
    LOAD_NONE rax
    INCREF rax
    leave
    ret
.amfu_arity:
    SET_EXC exc_TypeError_type, "fromunicode() takes exactly one argument"
.amfu_fail:
    xor eax, eax
    leave
    ret
END_FUNC array_m_fromunicode

;; ============================================================================
;; array_tounicode_str(rdi = arr) -> rax = PyStrObject*, or 0
;; Fails: 0
;; Encodes a 'u' array's uint32 codepoints into a UTF-8 PyStrObject.
;; ============================================================================
ATU_ARR   equ 8
ATU_BUF   equ 16
ATU_BYTES equ 24
ATU_FRAME equ 40            ; + 1 push (rbx) = 48, 16-aligned
global array_tounicode_str
DEF_FUNC array_tounicode_str, ATU_FRAME
    push rbx
    mov [rbp - ATU_ARR], rdi
    cmp qword [rdi + PyArrayObject.ob_code], 'u'
    jne .atu_not_u

    mov rbx, rdi
    OBJ_LOCK rbx
    mov rcx, [rbx + PyArrayObject.ob_size]
    test rcx, rcx
    jz .atu_unlock_empty

    ; Pass 1: validate codepoints <= 0x10FFFF and compute UTF-8 byte length
    mov rsi, [rbx + PyArrayObject.ob_data]
    xor r8d, r8d                ; total UTF-8 bytes
    xor edx, edx                ; index
.atu_len_loop:
    cmp rdx, rcx
    jge .atu_alloc
    mov eax, [rsi + rdx * 4]
    cmp eax, 0x10FFFF
    ja .atu_unlock_bad_cp
    cmp eax, 0x80
    jb .atu_l1
    cmp eax, 0x800
    jb .atu_l2
    cmp eax, 0x10000
    jb .atu_l3
    add r8, 4
    jmp .atu_lnext
.atu_l1:
    inc r8
    jmp .atu_lnext
.atu_l2:
    add r8, 2
    jmp .atu_lnext
.atu_l3:
    add r8, 3
.atu_lnext:
    inc rdx
    jmp .atu_len_loop

.atu_alloc:
    mov [rbp - ATU_BYTES], r8
    mov rdi, r8
    call ap_malloc
    test rax, rax
    jz .atu_unlock_nomem
    mov [rbp - ATU_BUF], rax

    ; Pass 2: encode UTF-8 into scratch buffer while still holding OBJ_LOCK
    mov rdi, rax
    mov rsi, [rbx + PyArrayObject.ob_data]
    mov rcx, [rbx + PyArrayObject.ob_size]
    xor edx, edx
.atu_enc_loop:
    cmp rdx, rcx
    jge .atu_encoded
    mov eax, [rsi + rdx * 4]
    cmp eax, 0x80
    jb .atu_e1
    cmp eax, 0x800
    jb .atu_e2
    cmp eax, 0x10000
    jb .atu_e3
    ; 4 bytes
    mov r9d, eax
    shr r9d, 18
    or r9d, 0xF0
    mov [rdi], r9b
    mov r9d, eax
    shr r9d, 12
    and r9d, 0x3F
    or r9d, 0x80
    mov [rdi + 1], r9b
    mov r9d, eax
    shr r9d, 6
    and r9d, 0x3F
    or r9d, 0x80
    mov [rdi + 2], r9b
    and eax, 0x3F
    or eax, 0x80
    mov [rdi + 3], al
    add rdi, 4
    jmp .atu_enext
.atu_e1:
    mov [rdi], al
    inc rdi
    jmp .atu_enext
.atu_e2:
    mov r9d, eax
    shr r9d, 6
    or r9d, 0xC0
    mov [rdi], r9b
    and eax, 0x3F
    or eax, 0x80
    mov [rdi + 1], al
    add rdi, 2
    jmp .atu_enext
.atu_e3:
    mov r9d, eax
    shr r9d, 12
    or r9d, 0xE0
    mov [rdi], r9b
    mov r9d, eax
    shr r9d, 6
    and r9d, 0x3F
    or r9d, 0x80
    mov [rdi + 1], r9b
    and eax, 0x3F
    or eax, 0x80
    mov [rdi + 2], al
    add rdi, 3
.atu_enext:
    inc rdx
    jmp .atu_enc_loop

.atu_encoded:
    OBJ_UNLOCK rbx
    mov rdi, [rbp - ATU_BUF]
    mov rsi, [rbp - ATU_BYTES]
    call str_new_heap
    mov rbx, rax
    mov rdi, [rbp - ATU_BUF]
    call ap_free
    mov rax, rbx
    pop rbx
    leave
    ret

.atu_unlock_empty:
    OBJ_UNLOCK rbx
    lea rdi, [rel array_empty_byte]
    xor esi, esi
    call str_new_heap
    pop rbx
    leave
    ret
.atu_unlock_bad_cp:
    OBJ_UNLOCK rbx
    FAIL exc_ValueError_type, \
         "character is not in range [U+0000; U+10ffff]", .atu_fail
.atu_unlock_nomem:
    OBJ_UNLOCK rbx
    FAIL exc_MemoryError_type, "out of memory", .atu_fail
.atu_not_u:
    FAIL exc_ValueError_type, \
         "tounicode() may only be called on unicode type arrays", .atu_fail
.atu_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC array_tounicode_str

;; array_m_tounicode(args, nargs) -> str
DEF_FUNC array_m_tounicode
    cmp rsi, 1
    jne .amtu_arity
    mov rdi, [rdi]
    call array_tounicode_str    ; err: 0 is this method's own
    leave
    ret
.amtu_arity:
    SET_EXC exc_TypeError_type, "tounicode() takes no arguments"
    xor eax, eax
    leave
    ret
END_FUNC array_m_tounicode

;; array_m_new(args, nargs) -> array.array.__new__(cls, typecode[, init])
AMN_ARGS  equ 8
AMN_NARGS equ 16
AMN_FRAME equ 16            ; 0 pushes, 16-aligned
DEF_FUNC array_m_new, AMN_FRAME
    mov [rbp - AMN_ARGS], rdi
    mov [rbp - AMN_NARGS], rsi
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rel array_type]
    call new_check_class
    ERR_NULL .amn_fail
    mov rdi, rax                ; cls
    mov rsi, [rbp - AMN_ARGS]
    add rsi, 8
    mov rdx, [rbp - AMN_NARGS]
    dec rdx
    call array_type_new
    leave
    ret
.amn_fail:
    xor eax, eax
    leave
    ret
END_FUNC array_m_new

;; array_m_init(args, nargs) -> None
;; Matches object.__init__ on array.array (allows subclass __init__ calling
;; array.array.__init__(self) or default init forwarding).
DEF_FUNC array_m_init
    mov qword [gs:ThreadState.kw_names_pending], 0
    cmp rsi, 1
    jb .ami_arity
    LOAD_NONE rax
    INCREF rax
    leave
    ret
.ami_arity:
    SET_EXC exc_TypeError_type, "descriptor '__init__' of 'array.array' object needs an argument"
    xor eax, eax
    leave
    ret
END_FUNC array_m_init

;; ============================================================================
;; The two names fromfile and tofile look up, built once by
;; array_module_create and kept for the life of the process.
;;
;; A missing `read` is reported by set_no_attribute, which READS the name
;; str and does not return -- so a str built per call could not be released
;; before it, and would leak on exactly the path that raises.
;; ============================================================================
section .bss
array_str_read:  resq 1
array_str_write: resq 1
section .text

extern obj_getattr_opt
extern obj_call_n
extern set_no_attribute
extern set_type_error_counted
extern type_is_subtype
extern exc_EOFError_type

;; ============================================================================
;; array_m_fromfile(args, nargs) -> None, or 0 with an exception pending
;;
;; `a.fromfile(f, n)` reads n ITEMS -- n * itemsize bytes -- with ONE call to
;; the file object's own read(), and APPENDS what came back to what the array
;; already holds.  A short read keeps what it got and THEN raises EOFError,
;; which is the half of this that is easy to get wrong: CPython appends first
;; and raises second, and a caller that reads past the end still sees the
;; bytes that were there.
;;
;; One call, not a loop, because the file object's own position is what makes
;; two successive fromfile()s continue rather than repeat.
;;
;; `read` is fetched as an ordinary attribute, so an object that has none
;; fails with the AttributeError any other attribute would raise rather than
;; with a type check of this module's own wording.  The count is converted
;; first, through obj_as_index, because CPython's argument clinic converts it
;; before the file is touched at all.
;;
;; Both the lookup and the call run arbitrary Python, which may append to this
;; very array and MOVE its buffer.  Nothing is held across either: ob_data and
;; ob_size are re-read afterwards, so what arrives is appended to wherever the
;; array has got to by then.
;; ============================================================================
AFF_ARR    equ 8
AFF_FILE   equ 16
AFF_NBYTES equ 24           ; how many bytes were asked for
AFF_FN     equ 32           ; the bound read, owned
AFF_BUF    equ 40           ; what it answered, owned
AFF_ARG    equ 48           ; the one-element argument array obj_call_n reads
AFF_GOT    equ 56           ; how many bytes actually arrived
AFF_ITEMS  equ 64           ; and how many whole items that is
AFF_FRAME  equ 64           ; + 0 pushes = 64, 16-aligned
DEF_FUNC array_m_fromfile, AFF_FRAME
    cmp rsi, 3
    jne .aff_arity
    mov rax, [rdi]
    mov [rbp - AFF_ARR], rax
    mov rax, [rdi + 8]
    mov [rbp - AFF_FILE], rax

    ; The count, before anything is read or even looked up.
    mov rdi, [rdi + 16]
    V_UNPACK rdi, rdx
    call obj_as_index           ; an i64, or it raises and does not return
    ERR_M1 .idx_fail
    test rax, rax
    js .aff_negative
    mov rdi, [rbp - AFF_ARR]
    imul rax, [rdi + PyArrayObject.ob_isize]
    jo .aff_nomem
    mov [rbp - AFF_NBYTES], rax

    mov rdi, [rbp - AFF_FILE]
    mov rsi, [rel array_str_read]
    call obj_getattr_opt
    test rax, rax
    jz .aff_no_read
    mov [rbp - AFF_FN], rax

    mov rdi, [rbp - AFF_NBYTES]
    call int_from_i64
    V_PACK rax, rdx
    mov [rbp - AFF_ARG], rax
    mov rdi, [rbp - AFF_FN]
    lea rsi, [rbp - AFF_ARG]
    mov edx, 1
    call obj_call_n             ; err: .aff_fail, below
    mov [rbp - AFF_BUF], rax
    mov rdi, [rbp - AFF_ARG]
    DECREF_V rdi, rcx           ; the count, which may have been a heap int
    mov rdi, [rbp - AFF_FN]
    DECREF_V rdi, rcx
    mov rax, [rbp - AFF_BUF]
    test rax, rax
    jz .aff_fail                ; read() raised; its exception is the one

    ; bytes and nothing else -- a text-mode file answers a str, and this is
    ; the only place that says so.
    V_TEST_PTR rax, rcx
    ja .aff_not_bytes
    mov rdi, [rax + PyObject.ob_type]
    lea rsi, [rel bytes_type]
    call type_is_subtype
    test eax, eax
    jz .aff_not_bytes

    mov rax, [rbp - AFF_BUF]
    mov rax, [rax + PyBytesObject.ob_size]
    mov [rbp - AFF_GOT], rax
    mov rdi, [rbp - AFF_ARR]
    xor edx, edx
    mov rcx, [rdi + PyArrayObject.ob_isize]
    div rcx
    test rdx, rdx
    jnz .aff_not_multiple       ; a read that stopped mid-item, as frombytes
    mov [rbp - AFF_ITEMS], rax
    test rax, rax
    jz .aff_appended

    mov rdi, [rbp - AFF_ARR]
    OBJ_LOCK rdi
    call array_no_exports
    ERR_NULL .aff_unlock_fail_buf
    mov rdi, [rbp - AFF_ARR]
    mov rsi, [rdi + PyArrayObject.ob_size]
    add rsi, [rbp - AFF_ITEMS]
    call array_reserve
    ERR_NULL .aff_unlock_fail_buf

    mov rdi, [rbp - AFF_ARR]
    mov rax, [rdi + PyArrayObject.ob_size]
    imul rax, [rdi + PyArrayObject.ob_isize]
    add rax, [rdi + PyArrayObject.ob_data]
    mov rdi, rax
    mov rsi, [rbp - AFF_BUF]
    add rsi, PyBytesObject.data
    mov rdx, [rbp - AFF_GOT]
    call ap_memcpy
    mov rdi, [rbp - AFF_ARR]
    mov rax, [rbp - AFF_ITEMS]
    add [rdi + PyArrayObject.ob_size], rax
    OBJ_UNLOCK rdi
    jmp .aff_appended
.aff_unlock_fail_buf:
    mov rdi, [rbp - AFF_ARR]
    OBJ_UNLOCK rdi
    jmp .aff_fail_buf

.aff_appended:
    mov rdi, [rbp - AFF_BUF]
    DECREF_V rdi, rcx
    mov rax, [rbp - AFF_GOT]
    cmp rax, [rbp - AFF_NBYTES]
    jne .aff_short              ; everything is already appended
    LOAD_NONE rax
    leave
    ret

.aff_short:
    ; CPython compares the length it got against the length it asked for, so
    ; a read() that answers MORE is an EOFError too -- and its bytes are kept.
    SET_EXC exc_EOFError_type, "read() didn't return enough bytes"
    xor eax, eax
    leave
    ret
.aff_not_bytes:
    mov rdi, [rbp - AFF_BUF]
    DECREF_V rdi, rcx
    SET_EXC exc_TypeError_type, "read() didn't return bytes"
    xor eax, eax
    leave
    ret
.aff_not_multiple:
    mov rdi, [rbp - AFF_BUF]
    DECREF_V rdi, rcx
    SET_EXC exc_ValueError_type, "bytes length not a multiple of item size"
    xor eax, eax
    leave
    ret
.aff_negative:
    SET_EXC exc_ValueError_type, "negative count"
    xor eax, eax
    leave
    ret
.aff_nomem:
    SET_EXC exc_MemoryError_type, "out of memory"
    xor eax, eax
    leave
    ret
.aff_fail_buf:
    mov rdi, [rbp - AFF_BUF]
    DECREF_V rdi, rcx
.aff_fail:
    xor eax, eax
    leave
    ret
.aff_no_read:
    ; A getter that raised is propagated; absent is the ordinary
    ; AttributeError, which does not return.
    cmp qword [gs:ThreadState.current_exception], 0
    jne .aff_fail
    mov rdi, [rbp - AFF_FILE]
    mov rsi, [rel array_str_read]
    call set_no_attribute
    jmp .aff_fail
.aff_arity:
    ; CPython counts self in the number it wants and not in the number it
    ; got: "takes exactly 2 positional arguments (0 given)" for `a.fromfile()`.
    sub rsi, 1
    jns .aff_arity_count
    xor esi, esi
.aff_arity_count:
    CSTRING rdi, "fromfile() takes exactly 2 positional arguments ("
    CSTRING rdx, " given)"
    call set_type_error_counted
    leave
    ret
.idx_fail:                      ; not an index: the exception is pending
    xor eax, eax
    leave
    ret
END_FUNC array_m_fromfile

;; ============================================================================
;; array_m_tofile(args, nargs) -> None, or 0 with an exception pending
;;
;; tobytes() handed to the file object's own write().  It frames nothing, so
;; two tofile()s to one stream concatenate and only the reader's own typecode
;; says where the items are.
;;
;; An EMPTY array writes nothing and never touches the argument at all --
;; CPython's block loop runs zero times, so `array('i').tofile(42)` answers
;; None rather than raising -- which is why the size is tested before `write`
;; is even looked up.
;;
;; CPython writes in 64K blocks; this writes once.  The difference is visible
;; only to a write() that counts its calls, and one call is what every file
;; object here would rather have.
;;
;; The bytes are snapshotted AFTER the lookup: fetching `write` can run a
;; __getattr__ that mutates the array and moves its buffer.
;; ============================================================================
ATF_ARR   equ 8
ATF_FILE  equ 16
ATF_FN    equ 24             ; the bound write, owned
ATF_ARG   equ 32             ; the bytes, owned, and the argument array
ATF_RES   equ 40             ; what write() answered, owned
ATF_FRAME equ 48             ; + 0 pushes = 48, 16-aligned
DEF_FUNC array_m_tofile, ATF_FRAME
    cmp rsi, 2
    jne .atf_arity
    mov rax, [rdi]
    mov [rbp - ATF_ARR], rax
    mov rcx, [rdi + 8]
    mov [rbp - ATF_FILE], rcx
    cmp qword [rax + PyArrayObject.ob_size], 0
    jle .atf_done

    mov rdi, rcx
    mov rsi, [rel array_str_write]
    call obj_getattr_opt
    test rax, rax
    jz .atf_no_write
    mov [rbp - ATF_FN], rax

    mov rdi, [rbp - ATF_ARR]
    OBJ_LOCK rdi
    mov rsi, [rdi + PyArrayObject.ob_size]
    imul rsi, [rdi + PyArrayObject.ob_isize]
    mov rdi, [rdi + PyArrayObject.ob_data]
    test rdi, rdi
    jnz .atf_have_data
    lea rdi, [rel array_empty_byte]
.atf_have_data:
    call bytes_from_data
    mov rcx, [rbp - ATF_ARR]
    OBJ_UNLOCK rcx
    test rax, rax
    jz .atf_fail_fn
    mov [rbp - ATF_ARG], rax

    mov rdi, [rbp - ATF_FN]
    lea rsi, [rbp - ATF_ARG]
    mov edx, 1
    call obj_call_n             ; err: .atf_fail, below
    mov [rbp - ATF_RES], rax
    mov rdi, [rbp - ATF_ARG]
    DECREF_V rdi, rcx
    mov rdi, [rbp - ATF_FN]
    DECREF_V rdi, rcx
    mov rax, [rbp - ATF_RES]
    test rax, rax
    jz .atf_fail
    mov rdi, rax
    DECREF_V rdi, rcx           ; whatever write() returned is discarded
.atf_done:
    LOAD_NONE rax
    leave
    ret

.atf_fail_fn:
    mov rdi, [rbp - ATF_FN]
    DECREF_V rdi, rcx
.atf_fail:
    xor eax, eax
    leave
    ret
.atf_no_write:
    cmp qword [gs:ThreadState.current_exception], 0
    jne .atf_fail
    mov rdi, [rbp - ATF_FILE]
    mov rsi, [rel array_str_write]
    call set_no_attribute
    jmp .atf_fail
.atf_arity:
    sub rsi, 1
    jns .atf_arity_count
    xor esi, esi
.atf_arity_count:
    CSTRING rdi, "tofile() takes exactly 1 positional argument ("
    CSTRING rdx, " given)"
    call set_type_error_counted
    leave
    ret
END_FUNC array_m_tofile

;; ============================================================================
;; array_m_byteswap(args, nargs) -> None, or 0 with an exception pending
;;
;; Reverses the bytes of every item in place.  It is what reads a file written
;; on the other endianness, and it is the next thing every fromfile() caller
;; does: test.datetimetester's ZoneInfo reader byteswaps each of the three
;; arrays it reads out of a TZif file, which is big-endian.
;;
;; One byte per item is a no-op and anything but 1, 2, 4 or 8 is a
;; RuntimeError, which is CPython's own refusal -- no typecode here has such a
;; size, so it is unreachable until one does.
;; ============================================================================
extern exc_RuntimeError_type
DEF_FUNC array_m_byteswap, 8
    push rbx
    cmp rsi, 1
    jne .abs_arity
    mov rbx, [rdi]
    OBJ_LOCK rbx
    mov rcx, [rbx + PyArrayObject.ob_isize]
    mov rsi, [rbx + PyArrayObject.ob_size]
    mov rdi, [rbx + PyArrayObject.ob_data]
    test rsi, rsi
    jle .abs_unlock_done
    cmp rcx, 1
    je .abs_unlock_done
    cmp rcx, 2
    je .abs_two
    cmp rcx, 4
    je .abs_four
    cmp rcx, 8
    je .abs_eight
    OBJ_UNLOCK rbx
    SET_EXC exc_RuntimeError_type, \
            "don't know how to byteswap this array type"
    xor eax, eax
    pop rbx
    leave
    ret

.abs_two:
    mov ax, [rdi]
    rol ax, 8
    mov [rdi], ax
    add rdi, 2
    dec rsi
    jnz .abs_two
    jmp .abs_unlock_done
.abs_four:
    mov eax, [rdi]
    bswap eax
    mov [rdi], eax
    add rdi, 4
    dec rsi
    jnz .abs_four
    jmp .abs_unlock_done
.abs_eight:
    mov rax, [rdi]
    bswap rax
    mov [rdi], rax
    add rdi, 8
    dec rsi
    jnz .abs_eight

.abs_unlock_done:
    OBJ_UNLOCK rbx
.abs_done:
    LOAD_NONE rax
    pop rbx
    leave
    ret
.abs_arity:
    sub rsi, 1
    jns .abs_arity_count
    xor esi, esi
.abs_arity_count:
    CSTRING rdi, "array.byteswap() takes no arguments ("
    CSTRING rdx, " given)"
    call set_type_error_counted
    pop rbx
    leave
    ret
END_FUNC array_m_byteswap

;; array_m_buffer_info(args, nargs) -> (address, length)
ABI_TUP   equ 8
ABI_FRAME equ 16            ; + 1 push = 24 ... padded below
DEF_FUNC array_m_buffer_info, 24
    push rbx
    cmp rsi, 1
    jne .abi_arity
    mov rbx, [rdi]
    mov edi, 2
    call tuple_new
    test rax, rax
    jz .abi_null
    mov [rbp - ABI_TUP], rax
    OBJ_LOCK rbx
    mov rdi, [rbx + PyArrayObject.ob_data]
    mov rsi, [rbx + PyArrayObject.ob_size]
    OBJ_UNLOCK rbx
    push rsi
    push rsi
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - ABI_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx], rax
    pop rdi
    pop rdi
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - ABI_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + 8], rax
    mov rax, [rbp - ABI_TUP]
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.abi_arity:
    SET_EXC exc_TypeError_type, "buffer_info() takes no arguments"
.abi_null:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    V_PACK rax, rdx
    ret
END_FUNC array_m_buffer_info

section .rodata
array_empty_byte: db 0
section .text

;; ============================================================================
;; array_getattr(rdi = the array, rsi = the name str) -> rax = a Value
;;
;; typecode and itemsize are attributes, not methods, and the rest of the
;; surface is bound out of the type's tp_dict by the ordinary machinery -- so
;; this only has to answer the two and hand everything else back.
;; ============================================================================
AGA_ARR   equ 8
AGA_NAME  equ 16
AGA_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC array_getattr, AGA_FRAME
    mov [rbp - AGA_ARR], rdi
    mov [rbp - AGA_NAME], rsi

    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "typecode"
    extern ap_strcmp
    call ap_strcmp
    test eax, eax
    jz .aga_typecode

    mov rsi, [rbp - AGA_NAME]
    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "itemsize"
    call ap_strcmp
    test eax, eax
    jz .aga_itemsize

    ; Not one of ours: the generic path, which finds the methods in tp_dict.
    mov rdi, [rbp - AGA_ARR]
    mov rsi, [rbp - AGA_NAME]
    extern obj_generic_attr
    leave
    jmp obj_generic_attr

.aga_typecode:
    ; A one-character str, which chr() knows how to build.
    mov rdi, [rbp - AGA_ARR]
    mov rdi, [rdi + PyArrayObject.ob_code]
    V_PACK_I64 rdi, rcx
    mov [rbp - AGA_NAME], rdi
    lea rdi, [rbp - AGA_NAME]
    mov esi, 1
    extern builtin_chr
    call builtin_chr            ; err: its 0 is this function's own
    leave
    ret

.aga_itemsize:
    mov rdi, [rbp - AGA_ARR]
    mov rdi, [rdi + PyArrayObject.ob_isize]
    call int_from_i64
    ; The tag int_from_i64 set, not TAG_PTR: overwriting it made V_PACK read
    ; a small integer as a pointer.
    leave
    V_PACK rax, rdx
    ret
END_FUNC array_getattr

;; ============================================================================
;; array_module_create() -> rax = the module object
;; ============================================================================
AMC_DICT  equ 8
AMC_KEY   equ 16
AMC_FN    equ 24
AMC_FRAME equ 32            ; + 2 pushes = 48, 16-aligned

;; AM_ADD_METHOD impl, "name" -- one entry in array's tp_dict, which rbx holds.
%macro AM_ADD_METHOD 2
    CSTRING rdi, %2
    call str_from_cstr_heap
    mov [rbp - AMC_KEY], rax
    lea rdi, [rel %1]
    CSTRING rsi, %2
    call builtin_func_new
    mov [rbp - AMC_FN], rax
    mov rdi, rbx
    mov rsi, [rbp - AMC_KEY]
    mov rdx, rax
    call dict_set
    mov rdi, [rbp - AMC_KEY]
    call obj_decref
    mov rdi, [rbp - AMC_FN]
    call obj_decref
%endmacro

;; ============================================================================
;; array_module_create() -> rax = the module object, or 0
;;
;; Builds the type's tp_dict, then the module dict around it.  import_init
;; puts what this returns straight into sys.modules, so it has to be the
;; module and not the dict.
;; ============================================================================
global array_module_create
DEF_FUNC array_module_create, AMC_FRAME
    push rbx
    push r12

    ; The type's own dict, which is where the methods are found by name.
    call dict_new
    test rax, rax
    jz .amc_out
    mov rbx, rax
    AM_ADD_METHOD array_m_append,      "append"
    AM_ADD_METHOD array_m_extend,      "extend"
    AM_ADD_METHOD array_m_tolist,      "tolist"
    AM_ADD_METHOD array_m_fromlist,    "fromlist"
    AM_ADD_METHOD array_m_tobytes,     "tobytes"
    AM_ADD_METHOD array_m_frombytes,   "frombytes"
    AM_ADD_METHOD array_m_fromunicode, "fromunicode"
    AM_ADD_METHOD array_m_tounicode,   "tounicode"
    AM_ADD_METHOD array_m_tofile,      "tofile"
    AM_ADD_METHOD array_m_fromfile,    "fromfile"
    AM_ADD_METHOD array_m_byteswap,    "byteswap"
    AM_ADD_METHOD array_m_buffer_info, "buffer_info"
    AM_ADD_METHOD array_m_insert,      "insert"
    AM_ADD_METHOD array_m_pop,         "pop"
    AM_ADD_METHOD array_m_remove,      "remove"
    AM_ADD_METHOD array_m_index,       "index"
    AM_ADD_METHOD array_m_count,       "count"
    AM_ADD_METHOD array_m_reverse,     "reverse"
    AM_ADD_METHOD array_m_copy,        "__copy__"
    AM_ADD_METHOD array_m_deepcopy,    "__deepcopy__"
    AM_ADD_METHOD array_m_reduce_ex,   "__reduce_ex__"
    AM_ADD_METHOD array_m_getitem,     "__getitem__"
    AM_ADD_METHOD array_m_setitem,     "__setitem__"
    AM_ADD_METHOD array_m_delitem,     "__delitem__"
    AM_ADD_METHOD array_m_len,         "__len__"
    AM_ADD_METHOD array_m_iter,        "__iter__"
    AM_ADD_METHOD array_m_contains,    "__contains__"
    AM_ADD_METHOD array_m_add,         "__add__"
    AM_ADD_METHOD array_m_iadd,        "__iadd__"
    AM_ADD_METHOD array_m_mul,         "__mul__"
    AM_ADD_METHOD array_m_mul,         "__rmul__"
    AM_ADD_METHOD array_m_imul,        "__imul__"
    AM_ADD_METHOD array_m_init,        "__init__"
    mov rdi, rbx
    lea rsi, [rel array_m_new]
    call add_new_staticmethod
    lea rax, [rel array_type]
    mov [rax + PyTypeObject.tp_dict], rbx
    mov rdi, rax
    extern type_stamp_methods
    call type_stamp_methods

    ; The two names fromfile and tofile look up.  Built here rather than per
    ; call because the error path reads the str and has nothing to release.
    CSTRING rdi, "read"
    call str_from_cstr_heap
    test rax, rax
    jz .amc_out
    mov [rel array_str_read], rax
    CSTRING rdi, "write"
    call str_from_cstr_heap
    test rax, rax
    jz .amc_out
    mov [rel array_str_write], rax
    CSTRING rdi, "__dict__"
    call str_from_cstr_heap
    test rax, rax
    jz .amc_out
    mov [rel array_str___dict__], rax

    ; ...and the module dict, holding the type and the typecode string.
    call dict_new
    test rax, rax
    jz .amc_out
    mov r12, rax
    mov [rbp - AMC_DICT], rax

    CSTRING rdi, "array"
    call str_from_cstr_heap
    mov [rbp - AMC_KEY], rax
    lea rcx, [rel array_type]
    mov qword [rcx + PyTypeObject.tp_new], 0
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rel array_type]
    call dict_set_str
    mov rdi, [rbp - AMC_KEY]
    call obj_decref

    ; array.array is callable through tp_new, the way every builtin type is.
    lea rax, [rel array_type]
    lea rcx, [rel array_type_new]
    mov [rax + PyTypeObject.tp_new], rcx

    ; ArrayType is the legacy alias for array.array
    CSTRING rdi, "ArrayType"
    call str_from_cstr_heap
    mov [rbp - AMC_KEY], rax
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rel array_type]
    call dict_set_str
    mov rdi, [rbp - AMC_KEY]
    call obj_decref

    ; _array_reconstructor (with __module__ = "array" for pickle)
    CSTRING rdi, "_array_reconstructor"
    call str_from_cstr_heap
    mov [rbp - AMC_KEY], rax
    lea rdi, [rel array__array_reconstructor]
    CSTRING rsi, "_array_reconstructor"
    call builtin_func_new
    mov [rbp - AMC_FN], rax
    mov [rel array_reconstructor_func], rax
    CSTRING rdi, "array"
    call str_from_cstr_heap
    mov rcx, [rbp - AMC_FN]
    mov [rcx + PyBuiltinObject.func_module], rax
    mov rdi, r12
    mov rsi, [rbp - AMC_KEY]
    mov rdx, rcx
    call dict_set_str
    mov rdi, [rbp - AMC_KEY]
    call obj_decref
    mov rdi, [rbp - AMC_FN]
    call obj_decref

    CSTRING rdi, "typecodes"
    call str_from_cstr_heap
    mov [rbp - AMC_KEY], rax
    lea rdi, [rel array_typecodes_str]
    call str_from_cstr_heap
    mov [rbp - AMC_FN], rax
    mov rdi, r12
    mov rsi, [rbp - AMC_KEY]
    mov rdx, rax
    call dict_set_str
    mov rdi, [rbp - AMC_KEY]
    call obj_decref
    mov rdi, [rbp - AMC_FN]
    call obj_decref

    ; And the module object around it, as every builtin module does: the
    ; table's create_fn goes straight into sys.modules, so a bare dict there
    ; makes `array.typecodes` an attribute lookup on a dict.
    CSTRING rdi, "array"
    call str_from_cstr_heap
    mov [rbp - AMC_KEY], rax
    mov rdi, rax
    mov rsi, r12
    extern module_new
    call module_new
    mov [rbp - AMC_FN], rax
    mov rdi, [rbp - AMC_KEY]
    call obj_decref             ; module_new took its own
    mov rdi, r12
    call obj_decref
    mov rax, [rbp - AMC_FN]
    extern array_module_obj
    mov [rel array_module_obj], rax
.amc_out:
    pop r12
    pop rbx
    leave
    ret
END_FUNC array_module_create

;; ============================================================================
;; array_tp_iter(rdi = the array) -> rax = an iterator over it, or 0
;;
;; The generic sequence iterator, which walks through sq_item.  CPython's
;; array has an iterator type of its own; this one answers the same items in
;; the same order, and it is the one already written.
;; ============================================================================
global array_tp_iter
DEF_FUNC array_tp_iter
    extern seq_iter_new
    call seq_iter_new
    leave
    ret
END_FUNC array_tp_iter

;; ============================================================================
;; array_m_getitem(args, nargs) -> the item at args[1], as a Value
;;
;; The sequence iterator walks through `__getitem__` by NAME, and the stdlib
;; asks by name too, so the slot is not enough on its own.
;; ============================================================================
DEF_FUNC array_m_getitem
    cmp rsi, 2
    jne .amg_arity
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    leave
    jmp array_subscript_full
.amg_arity:
    SET_EXC exc_TypeError_type, "__getitem__() takes exactly one argument"
    leave
    ret
END_FUNC array_m_getitem

;; ============================================================================
;; array_m_setitem(args, nargs) -> None, or 0 raising
;; ============================================================================
DEF_FUNC array_m_setitem
    cmp rsi, 3
    jne .ams_arity
    mov rdx, [rdi + 16]
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call array_ass_subscript_full
    test eax, eax
    js .ams_fail
    LOAD_NONE rax
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.ams_fail:
    xor eax, eax
    xor edx, edx
    leave
    V_PACK rax, rdx
    ret
.ams_arity:
    FAIL exc_TypeError_type, "__setitem__() takes exactly two arguments", .ams_fail
END_FUNC array_m_setitem

;; ============================================================================
;; array_m_len(args, nargs) -> the item count, as a Value
;; ============================================================================
DEF_FUNC array_m_len
    cmp rsi, 1
    jne .aml_arity
    mov rdi, [rdi]
    mov rdi, [rdi + PyArrayObject.ob_size]
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
.aml_arity:
    SET_EXC exc_TypeError_type, "__len__() takes no arguments"
    xor eax, eax
    leave
    ret
END_FUNC array_m_len
