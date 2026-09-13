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
extern raise_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_IndexError_type
extern exc_OverflowError_type
extern type_type
extern str_type
extern int_type
extern int_promote_mpz
extern eval_exception_unwind
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
extern current_exception
extern hash_not_implemented
extern obj_dealloc
extern set_exception

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
;; array_new_empty(rdi = ArrayCode*) -> rax = a new empty array, or 0
;; ============================================================================
ANE_FRAME equ 16            ; + 1 push = 24 ... see below
DEF_FUNC array_new_empty, 8
    push rbx
    mov rbx, rdi
    ; ap_malloc, not gc_alloc: the buffer holds raw scalars, so the type
    ; carries no TYPE_FLAG_HAVE_GC and there is nothing for the collector to
    ; track.  gc_alloc and gc_dealloc are a pair, and using one without the
    ; other handed free() a pointer that was never its to free.
    mov edi, PyArrayObject_size
    call ap_malloc
    test rax, rax
    jz .ane_out
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel array_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyArrayObject.ob_size], 0
    mov qword [rax + PyArrayObject.ob_cap], 0
    mov qword [rax + PyArrayObject.ob_data], 0
    mov rcx, [rbx + ArrayCode.letter]
    mov [rax + PyArrayObject.ob_code], rcx
    mov rcx, [rbx + ArrayCode.itemsize]
    mov [rax + PyArrayObject.ob_isize], rcx
    mov rcx, [rbx + ArrayCode.kind]
    mov [rax + PyArrayObject.ob_kind], rcx
    mov qword [rax + PyArrayObject.ob_exports], 0
.ane_out:
    pop rbx
    leave
    ret
END_FUNC array_new_empty

;; ============================================================================
;; array_reserve(rdi = the array, rsi = items wanted) -> eax = 1, or 0 raising
;;
;; Grows by doubling, as list does.  The buffer MOVES, which is why nothing
;; may hold a pointer into it across an append.
;; ============================================================================
AR_ARR   equ 8
AR_WANT  equ 16
AR_FRAME equ 32             ; + 0 pushes = 32, 16-aligned
DEF_FUNC array_reserve, AR_FRAME
    mov [rbp - AR_ARR], rdi
    mov [rbp - AR_WANT], rsi
    cmp rsi, [rdi + PyArrayObject.ob_cap]
    jle .arr_ok

    ; Nothing may be holding a pointer into the buffer: it is about to move.
    call array_no_exports
    test eax, eax
    jz .arr_raised
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
    extern exc_MemoryError_type
    RAISE exc_MemoryError_type, "out of memory"
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
    call builtin_chr
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
ASI_OBJ   equ 32        ; a heap int too wide for an i64, borrowed
ASI_NEG   equ 40        ; 1 when the refusal is "less than minimum"
ASI_MSG_ROW equ 40      ; five qwords per row of asi_msgs
ASI_WIDE  equ 48        ; 1 when it did not even fit the C conversion type
ASI_FRAME equ 56            ; + 1 push = 64, 16-aligned
DEF_FUNC array_store_item, ASI_FRAME
    push rbx
    mov [rbp - ASI_ARR], rdi
    mov [rbp - ASI_IDX], rsi
    mov [rbp - ASI_VAL], rdx

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
    mov rax, [rdi + PyArrayObject.ob_data]
    mov rcx, [rdi + PyArrayObject.ob_isize]
    mov rsi, [rbp - ASI_IDX]
    imul rsi, rcx
    add rax, rsi
    cmp rcx, 1
    je .asi_w1
    cmp rcx, 2
    je .asi_w2
    cmp rcx, 4
    je .asi_w4
    mov [rax], rbx
    jmp .asi_ok
.asi_w1:
    mov [rax], bl
    jmp .asi_ok
.asi_w2:
    mov [rax], bx
    jmp .asi_ok
.asi_w4:
    mov [rax], ebx
.asi_ok:
    mov eax, 1
    pop rbx
    leave
    ret

.asi_float:
    mov rdi, rdx
    V_UNPACK rdi, rsi           ; float_to_f64 takes the pair as well
    call float_to_f64           ; refuses what is not a number
    cmp qword [rel current_exception], 0
    jne .asi_fail
    mov rdi, [rbp - ASI_ARR]
    mov rax, [rdi + PyArrayObject.ob_data]
    mov rcx, [rdi + PyArrayObject.ob_isize]
    mov rsi, [rbp - ASI_IDX]
    imul rsi, rcx
    add rax, rsi
    cmp rcx, 4
    je .asi_f4
    movsd [rax], xmm0
    jmp .asi_ok
.asi_f4:
    cvtsd2ss xmm1, xmm0
    movss dword [rax], xmm1
    jmp .asi_ok

.asi_unicode:
    ; 'u' takes a one-character str and stores its code point.
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
    mov rax, [rdi + PyArrayObject.ob_data]
    mov rsi, [rbp - ASI_IDX]
    lea rax, [rax + rsi*4]
    mov [rax], ebx
    jmp .asi_ok

.asi_fail:
    xor eax, eax
    pop rbx
    leave
    ret
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
    call obj_as_index
    cmp qword [rel current_exception], 0
    jne .aia_failed
    mov edx, 1
    leave
    ret
.aia_failed:
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC array_int_arg

;; ============================================================================
;; array_richcompare(rdi = left, rsi = right, edx = op) -> (rax, edx) a Value
;;
;; Element-wise, like a list's -- array('i', [1, 2]) == array('i', [1, 2]) is
;; True in CPython, and with no tp_richcompare at all it was False here, so
;; every array compared by identity and `<` was a TypeError.
;;
;; Delegated to the LISTS, for the reason array_repr is: list_richcompare
;; already has the lexicographic order, the per-element dispatch and the
;; recursion guard, and comparing values rather than bytes is what makes
;; array('i', [1]) == array('f', [1.0]) answer True the way CPython's does.
;; ============================================================================
ARC_RIGHT equ 8
ARC_OP    equ 16
ARC_L1    equ 24
ARC_L2    equ 32
ARC_RES   equ 40
ARC_TAG   equ 48
ARC_FRAME equ 64            ; + 0 pushes = 64, 16-aligned
DEF_FUNC array_richcompare, ARC_FRAME
    V_TEST_PTR rsi, rax
    ja .arc_not_impl
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel array_type]
    cmp rax, rcx
    jne .arc_not_impl

    mov [rbp - ARC_RIGHT], rsi
    mov [rbp - ARC_OP], rdx
    mov qword [rbp - ARC_L1], 0
    mov qword [rbp - ARC_L2], 0

    call array_tolist
    test rax, rax
    jz .arc_error
    mov [rbp - ARC_L1], rax
    mov rdi, [rbp - ARC_RIGHT]
    call array_tolist
    test rax, rax
    jz .arc_error
    mov [rbp - ARC_L2], rax

    mov rdi, [rbp - ARC_L1]
    mov rsi, rax
    mov rdx, [rbp - ARC_OP]
    extern list_richcompare
    call list_richcompare
    mov [rbp - ARC_RES], rax
    mov [rbp - ARC_TAG], rdx
    call .arc_drop
    mov rax, [rbp - ARC_RES]
    mov rdx, [rbp - ARC_TAG]
    leave
    ret

.arc_error:
    call .arc_drop
    leave
    jmp eval_exception_unwind

.arc_not_impl:
    RET_NULL
    leave
    ret

    ;; .arc_drop -- release whichever lists were built
.arc_drop:
    sub rsp, 8
    mov rdi, [rbp - ARC_L1]
    test rdi, rdi
    jz .arc_drop_two
    call obj_decref
.arc_drop_two:
    mov rdi, [rbp - ARC_L2]
    test rdi, rdi
    jz .arc_drop_done
    call obj_decref
.arc_drop_done:
    add rsp, 8
    ret
END_FUNC array_richcompare

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
DEF_FUNC array_sq_item
    test rsi, rsi
    jns .asq_have
    add rsi, [rdi + PyArrayObject.ob_size]
.asq_have:
    test rsi, rsi
    jl .asq_range
    cmp rsi, [rdi + PyArrayObject.ob_size]
    jge .asq_range
    call array_item_value
    leave
    ret
.asq_range:
    ; SET_EXC and a NULL, not RAISE.  RAISE tail-jumps into the unwinder, and
    ; the sequence iterator's whole protocol is to CATCH the IndexError this
    ; raises and read it as exhaustion -- unwinding takes the exception
    ; straight past it and out of the `for`.  The same rule a builtin
    ; __next__ follows for StopIteration.
    SET_EXC exc_IndexError_type, "array index out of range"
    xor eax, eax
    xor edx, edx
    leave
    V_PACK rax, rdx
    ret
END_FUNC array_sq_item

;; ============================================================================
;; array_append_value(rdi = the array, rsi = a Value) -> eax = 1, or 0 raising
;; ============================================================================
AAV_ARR   equ 8
AAV_VAL   equ 16
AAV_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC array_append_value, AAV_FRAME
    mov [rbp - AAV_ARR], rdi
    mov [rbp - AAV_VAL], rsi
    ; Any change to the LENGTH is refused while a view is out, not only one
    ; that moves the buffer: CPython's array_resize makes this test first, and
    ; an append that happens to fit the spare capacity is a resize all the same.
    call array_no_exports
    test eax, eax
    jz .aav_fail
    mov rdi, [rbp - AAV_ARR]
    mov rsi, [rdi + PyArrayObject.ob_size]
    inc rsi
    call array_reserve
    test eax, eax
    jz .aav_fail
    mov rdi, [rbp - AAV_ARR]
    mov rsi, [rdi + PyArrayObject.ob_size]
    mov rdx, [rbp - AAV_VAL]
    call array_store_item
    test eax, eax
    jz .aav_fail
    mov rdi, [rbp - AAV_ARR]
    inc qword [rdi + PyArrayObject.ob_size]
    mov eax, 1
    leave
    ret
.aav_fail:
    xor eax, eax
    leave
    ret
END_FUNC array_append_value

;; ============================================================================
;; array_extend_iterable(rdi = the array, rsi = a Value) -> eax = 1, or 0
;;
;; Another array of the SAME typecode is copied wholesale; anything else is
;; iterated and appended one item at a time, which is what makes the range
;; checks apply to each.
;; ============================================================================
AEI_ARR   equ 8
AEI_ITER  equ 16
AEI_FRAME equ 32            ; + 1 push = 40 ... padded below
DEF_FUNC array_extend_iterable, 40
    push rbx
    mov [rbp - AEI_ARR], rdi
    mov rbx, rsi

    ; As in array_append_value: the length is about to change.
    call array_no_exports
    test eax, eax
    jz .aei_fail
    mov rdi, [rbp - AEI_ARR]

    ; The same typecode: a straight copy, and the only path that does not go
    ; through the per-item range check -- it cannot need one.
    V_TEST_PTR rbx, rax
    ja .aei_generic
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel array_type]
    cmp rax, rcx
    jne .aei_generic
    mov rcx, [rbx + PyArrayObject.ob_code]
    cmp rcx, [rdi + PyArrayObject.ob_code]
    jne .aei_generic

    mov rsi, [rdi + PyArrayObject.ob_size]
    add rsi, [rbx + PyArrayObject.ob_size]
    call array_reserve
    test eax, eax
    jz .aei_fail
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
    mov eax, 1
    pop rbx
    leave
    ret

.aei_generic:
    ; The real tag, not TAG_PTR: array('i', 5) hands an int IMMEDIATE here,
    ; and calling it a pointer dereferences the number 5.
    mov rdi, rbx
    V_UNPACK rdi, rsi
    call get_iterator_opt
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
    call array_append_value
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
    cmp qword [rel current_exception], 0
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
    pop rbx
    RAISE exc_TypeError_type, "cannot extend array from a non-iterable"
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
ATN_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC array_type_new, ATN_FRAME
    mov [rbp - ATN_ARGS], rsi
    mov [rbp - ATN_NARGS], rdx
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
    jne .atn_not_a_char
    cmp qword [rdi + PyStrObject.ob_length], 1
    jne .atn_not_a_char
    movzx edi, byte [rdi + PyStrObject.data]
    call array_find_code
    test rax, rax
    jz .atn_bad_code
    mov [rbp - ATN_CODE], rax

    mov rdi, rax
    call array_new_empty
    test rax, rax
    jz .atn_null
    mov [rbp - ATN_ARR], rax

    cmp qword [rbp - ATN_NARGS], 2
    jb .atn_done
    mov rdi, rax
    mov rsi, [rbp - ATN_ARGS]
    mov rsi, [rsi + 8]          ; args[1], one Value per slot
    call array_extend_iterable
    test eax, eax
    jz .atn_drop

.atn_done:
    mov rax, [rbp - ATN_ARR]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.atn_drop:
    mov rdi, [rbp - ATN_ARR]
    call obj_decref
.atn_null:
    xor eax, eax
    xor edx, edx
    leave
    V_PACK rax, rdx
    ret
.atn_bad_code:
    RAISE exc_ValueError_type, \
          "bad typecode (must be b, B, u, h, H, i, I, l, L, q, Q, f or d)"
.atn_not_a_char:
    ; CPython's \x02 form spells NoneType as "None", which is what this
    ; message wants: "not None", not "not NoneType".
    mov rsi, [rbp - ATN_ARR]
    CSTRING rdi, \
        `array() argument 1 must be a unicode character, not \x02`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
.atn_arity:
    RAISE exc_TypeError_type, \
          "array() takes 1 or 2 arguments"
END_FUNC array_type_new

;; ============================================================================
;; array_tolist(rdi = the array) -> rax = a new list, or 0 raising
;; ============================================================================
ATL_ARR   equ 8
ATL_LIST  equ 16
ATL_I     equ 24
ATL_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
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
    mov rsi, [rbp - ATL_I]
    cmp rsi, [rdi + PyArrayObject.ob_size]
    jge .atl_done
    call array_item_value
    test rax, rax
    jz .atl_drop
    push rax
    mov rdi, [rbp - ATL_LIST]
    mov rsi, rax
    call list_append
    pop rdi
    DECREF_V rdi, rcx           ; a Value; list_append took its own reference
    inc qword [rbp - ATL_I]
    jmp .atl_loop
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
    call array_tolist
    test rax, rax
    jz .arp_null
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
    cmp qword [rel current_exception], 0
    jne .asub_fail
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

;; ============================================================================
;; array_ass_subscript(rdi = the array, rsi = key Value, rdx = value Value)
;;   -> eax = 0 on success, or -1 raising.  A NULL value is `del a[i]`.
;; ============================================================================
AAS_ARR   equ 8
AAS_VAL   equ 16
AAS_IDX   equ 24
AAS_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC array_ass_subscript, AAS_FRAME
    mov [rbp - AAS_ARR], rdi
    mov [rbp - AAS_VAL], rdx
    mov rdi, rsi
    V_UNPACK rdi, rdx
    call obj_as_index
    cmp qword [rel current_exception], 0
    jne .aas_fail
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
    ; Shift the tail down one item.  The buffer does not shrink: capacity is
    ; not what ob_size means.  It is still a resize, and a view over the array
    ; would be left describing bytes that have moved.
    mov rdi, [rbp - AAS_ARR]
    call array_no_exports
    test eax, eax
    jz .aas_fail
    mov rdi, [rbp - AAS_ARR]
    mov rcx, [rdi + PyArrayObject.ob_isize]
    mov rax, [rbp - AAS_IDX]
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
    xor eax, eax
    leave
    ret

.aas_fail:
    mov eax, -1
    leave
    ret
.aas_range:
    SET_EXC exc_IndexError_type, "array assignment index out of range"
    mov eax, -1
    leave
    ret
END_FUNC array_ass_subscript

section .data
align 8
array_seq_methods:
    dq array_length             ; +0:  sq_length
    dq 0                        ; +8:  sq_concat
    dq 0                        ; +16: sq_repeat
    ; sq_item is what reversed() looks for, and mp_subscript does not cover it.
    dq array_sq_item            ; +24: sq_item
    dq 0                        ; +32: sq_ass_item (mp_ass_subscript covers it)
    dq 0                        ; +40: sq_contains
    dq 0                        ; +48: sq_inplace_concat
    dq 0                        ; +56: sq_inplace_repeat

align 8
array_mapping_methods:
    dq array_length             ; mp_length        +0
    dq array_subscript          ; mp_subscript     +8
    dq array_ass_subscript      ; mp_ass_subscript +16

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
.agb_count:
    cmp esi, BUF_ACQUIRE
    jne .agb_release
    inc qword [rdi + PyArrayObject.ob_exports]
    ret
.agb_release:
    ; Clamped: a release that is somehow not paired must not make the count
    ; negative and silently permit every resize after it.
    cmp qword [rdi + PyArrayObject.ob_exports], 0
    jle .agb_done
    dec qword [rdi + PyArrayObject.ob_exports]
.agb_done:
    ret
END_FUNC array_getbuffer

;; ============================================================================
;; array_no_exports(rdi = an array) -> eax = 1 when it may be resized, or 0
;;                                     with BufferError set
;;
;; CPython's array_resize makes this test first, with this wording.
;; ============================================================================
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
    dq 1                        ; ob_refcnt (immortal)
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
    dq array_richcompare        ; tp_richcompare
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
    ; No BASETYPE: the buffer moves, so a subclass could take neither a
    ; __dict__ nor __slots__ at a fixed offset, which is the rule bytearray
    ; and memoryview follow.
    dq TYPE_FLAG_FINAL          ; tp_flags
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
    test eax, eax
    jz .ama_fail
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
    RAISE exc_TypeError_type, "append() takes exactly one argument"
END_FUNC array_m_append

;; array_m_extend(args, nargs) -> None, or 0 raising
DEF_FUNC array_m_extend
    cmp rsi, 2
    jne .ame_arity
    mov rdx, [rdi + 8]
    mov rdi, [rdi]
    mov rsi, rdx
    call array_extend_iterable
    test eax, eax
    jz .ame_fail
    LOAD_NONE rax
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.ame_fail:
    xor eax, eax
    xor edx, edx
    leave
    V_PACK rax, rdx
    ret
.ame_arity:
    RAISE exc_TypeError_type, "extend() takes exactly one argument"
END_FUNC array_m_extend

;; array_m_tolist(args, nargs) -> a list of the items
DEF_FUNC array_m_tolist
    mov rdi, [rdi]
    call array_tolist
    mov edx, TAG_PTR
    test rax, rax
    jnz .amt_ok
    xor edx, edx
.amt_ok:
    leave
    V_PACK rax, rdx
    ret
END_FUNC array_m_tolist

;; array_m_fromlist(args, nargs) -> None, or 0 raising
;;
;; extend() by another name, which is what CPython's is once the list check
;; has passed.
DEF_FUNC_BARE array_m_fromlist
    jmp array_m_extend
END_FUNC array_m_fromlist

;; array_m_tobytes(args, nargs) -> the raw buffer as bytes
DEF_FUNC array_m_tobytes
    mov rdi, [rdi]
    mov rsi, [rdi + PyArrayObject.ob_size]
    imul rsi, [rdi + PyArrayObject.ob_isize]
    mov rdi, [rdi + PyArrayObject.ob_data]
    test rdi, rdi
    jnz .amb_have
    lea rdi, [rel array_empty_byte]
.amb_have:
    call bytes_from_data
    mov edx, TAG_PTR
    test rax, rax
    jnz .amb_ok
    xor edx, edx
.amb_ok:
    leave
    V_PACK rax, rdx
    ret
END_FUNC array_m_tobytes

;; array_m_frombytes(args, nargs) -> None
;;   The bytes must be a whole number of items, which is what CPython checks.
AFB_ARR   equ 8
AFB_FRAME equ 16            ; + 1 push = 24 ... padded below
AFB_SRC equ 24              ; the incoming data pointer, whatever held it
AFB_LEN equ 32              ; and its length in bytes
DEF_FUNC array_m_frombytes, 40
    push rbx
    cmp rsi, 2
    jne .afb_arity
    mov rbx, [rdi + 8]          ; the bytes
    mov rdi, [rdi]
    mov [rbp - AFB_ARR], rdi

    ; As in array_append_value: the length is about to change.
    call array_no_exports
    test eax, eax
    jz .afb_fail

    ; Anything bytes-LIKE, which is what CPython takes: a bytes, a bytearray or
    ; a memoryview.  An exact-bytes test refused the other two.
    ;
    ; NOT a generic buffer exporter, and not another array: CPython asks for
    ; PyBUF_SIMPLE, which an exporter carrying its own format refuses, so
    ; `a.frombytes(other_array)` is a TypeError there.  This slot does not model
    ; the request flags, so the three are named instead.
    V_TEST_PTR rbx, rax
    ja .afb_need_bytes
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .afb_kind_ok
    extern bytearray_type
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .afb_kind_ok
    extern memoryview_type
    lea rcx, [rel memoryview_type]
    cmp rax, rcx
    jne .afb_need_bytes
.afb_kind_ok:
    push rbx
    mov rdi, rbx
    extern bytes_like_ptr_len
    call bytes_like_ptr_len
    pop rbx
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
    mov rsi, rax                ; the item count coming in
    test rsi, rsi
    jz .afb_done
    push rsi
    add rsi, [rdi + PyArrayObject.ob_size]
    call array_reserve
    pop rsi
    test eax, eax
    jz .afb_fail

    mov rdi, [rbp - AFB_ARR]
    mov rax, [rdi + PyArrayObject.ob_size]
    imul rax, [rdi + PyArrayObject.ob_isize]
    add rax, [rdi + PyArrayObject.ob_data]
    push rsi
    mov rdi, rax
    mov rsi, [rbp - AFB_SRC]    ; wherever the source keeps its bytes
    mov rdx, [rbp - AFB_LEN]
    call ap_memcpy
    pop rsi
    mov rdi, [rbp - AFB_ARR]
    add [rdi + PyArrayObject.ob_size], rsi

.afb_done:
    LOAD_NONE rax
    INCREF rax
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.afb_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.afb_arity:
    pop rbx
    RAISE exc_TypeError_type, "frombytes() takes exactly one argument"
.afb_need_bytes:
    pop rbx
    RAISE exc_TypeError_type, "a bytes-like object is required"
.afb_not_multiple:
    pop rbx
    RAISE exc_ValueError_type, \
          "bytes length not a multiple of item size"
END_FUNC array_m_frombytes

;; ============================================================================
;; The two names fromfile and tofile look up, built once by
;; array_module_create and kept for the life of the process.
;;
;; A missing `read` is reported by raise_no_attribute, which READS the name
;; str and does not return -- so a str built per call could not be released
;; before it, and would leak on exactly the path that raises.
;; ============================================================================
section .bss
array_str_read:  resq 1
array_str_write: resq 1
section .text

extern obj_getattr_opt
extern obj_call_n
extern raise_no_attribute
extern raise_type_error_counted
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
    call obj_call_n
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

    ; The same growth frombytes does, and the same refusal when a live view
    ; would be left pointing at the old buffer.
    mov rdi, [rbp - AFF_ARR]
    call array_no_exports
    test eax, eax
    jz .aff_fail_buf
    mov rdi, [rbp - AFF_ARR]
    mov rsi, [rdi + PyArrayObject.ob_size]
    add rsi, [rbp - AFF_ITEMS]
    call array_reserve
    test eax, eax
    jz .aff_fail_buf

    ; The destination is read AFTER the reserve: the buffer has just moved.
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
    cmp qword [rel current_exception], 0
    jne .aff_fail
    mov rdi, [rbp - AFF_FILE]
    mov rsi, [rel array_str_read]
    xor edx, edx
    call raise_no_attribute
.aff_arity:
    ; CPython counts self in the number it wants and not in the number it
    ; got: "takes exactly 2 positional arguments (0 given)" for `a.fromfile()`.
    sub rsi, 1
    jns .aff_arity_count
    xor esi, esi
.aff_arity_count:
    CSTRING rdi, "fromfile() takes exactly 2 positional arguments ("
    CSTRING rdx, " given)"
    call raise_type_error_counted
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
    mov rsi, [rdi + PyArrayObject.ob_size]
    imul rsi, [rdi + PyArrayObject.ob_isize]
    mov rdi, [rdi + PyArrayObject.ob_data]
    test rdi, rdi
    jnz .atf_have_data
    lea rdi, [rel array_empty_byte]
.atf_have_data:
    call bytes_from_data
    test rax, rax
    jz .atf_fail_fn
    mov [rbp - ATF_ARG], rax

    mov rdi, [rbp - ATF_FN]
    lea rsi, [rbp - ATF_ARG]
    mov edx, 1
    call obj_call_n
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
    cmp qword [rel current_exception], 0
    jne .atf_fail
    mov rdi, [rbp - ATF_FILE]
    mov rsi, [rel array_str_write]
    xor edx, edx
    call raise_no_attribute     ; does not return
.atf_arity:
    sub rsi, 1
    jns .atf_arity_count
    xor esi, esi
.atf_arity_count:
    CSTRING rdi, "tofile() takes exactly 1 positional argument ("
    CSTRING rdx, " given)"
    call raise_type_error_counted
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
DEF_FUNC array_m_byteswap
    cmp rsi, 1
    jne .abs_arity
    mov rdi, [rdi]
    mov rcx, [rdi + PyArrayObject.ob_isize]
    mov rsi, [rdi + PyArrayObject.ob_size]
    mov rdi, [rdi + PyArrayObject.ob_data]
    test rsi, rsi
    jle .abs_done
    cmp rcx, 1
    je .abs_done
    cmp rcx, 2
    je .abs_two
    cmp rcx, 4
    je .abs_four
    cmp rcx, 8
    je .abs_eight
    SET_EXC exc_RuntimeError_type, \
            "don't know how to byteswap this array type"
    xor eax, eax
    leave
    ret

.abs_two:
    mov ax, [rdi]
    rol ax, 8
    mov [rdi], ax
    add rdi, 2
    dec rsi
    jnz .abs_two
    jmp .abs_done
.abs_four:
    mov eax, [rdi]
    bswap eax
    mov [rdi], eax
    add rdi, 4
    dec rsi
    jnz .abs_four
    jmp .abs_done
.abs_eight:
    mov rax, [rdi]
    bswap rax
    mov [rdi], rax
    add rdi, 8
    dec rsi
    jnz .abs_eight

.abs_done:
    LOAD_NONE rax
    leave
    ret
.abs_arity:
    sub rsi, 1
    jns .abs_arity_count
    xor esi, esi
.abs_arity_count:
    CSTRING rdi, "array.byteswap() takes no arguments ("
    CSTRING rdx, " given)"
    call raise_type_error_counted
END_FUNC array_m_byteswap

;; array_m_buffer_info(args, nargs) -> (address, length)
ABI_TUP   equ 8
ABI_FRAME equ 16            ; + 1 push = 24 ... padded below
DEF_FUNC array_m_buffer_info, 24
    push rbx
    mov rbx, [rdi]
    mov edi, 2
    call tuple_new
    test rax, rax
    jz .abi_null
    mov [rbp - ABI_TUP], rax
    ; V_PACK each: a tuple slot holds a VALUE, and int_from_i64 answers a
    ; (payload, tag) pair.  Storing the payload put a raw integer where the
    ; collector expects a pointer, and tuple_traverse followed it.
    mov rdi, [rbx + PyArrayObject.ob_data]
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - ABI_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx], rax
    mov rdi, [rbx + PyArrayObject.ob_size]
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
    call builtin_chr
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
    AM_ADD_METHOD array_m_tofile,      "tofile"
    AM_ADD_METHOD array_m_fromfile,    "fromfile"
    AM_ADD_METHOD array_m_byteswap,    "byteswap"
    AM_ADD_METHOD array_m_buffer_info, "buffer_info"
    AM_ADD_METHOD array_m_getitem,     "__getitem__"
    AM_ADD_METHOD array_m_setitem,     "__setitem__"
    AM_ADD_METHOD array_m_len,         "__len__"
    lea rax, [rel array_type]
    mov [rax + PyTypeObject.tp_dict], rbx
    mov rdi, rax
    extern type_stamp_methods
    call type_stamp_methods

    ; The two names fromfile and tofile look up.  Built here rather than per
    ; call because raise_no_attribute reads the str and never returns.
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
    call dict_set
    mov rdi, [rbp - AMC_KEY]
    call obj_decref

    ; array.array is callable through tp_new, the way every builtin type is.
    lea rax, [rel array_type]
    lea rcx, [rel array_type_new]
    mov [rax + PyTypeObject.tp_new], rcx

    CSTRING rdi, "typecodes"
    call str_from_cstr_heap
    mov [rbp - AMC_KEY], rax
    lea rdi, [rel array_typecodes_str]
    call str_from_cstr_heap
    mov [rbp - AMC_FN], rax
    mov rdi, r12
    mov rsi, [rbp - AMC_KEY]
    mov rdx, rax
    call dict_set
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
DEF_FUNC array_tp_iter
    call obj_incref             ; seq_iter_new takes ownership
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
    jmp array_subscript
.amg_arity:
    RAISE exc_TypeError_type, "__getitem__() takes exactly one argument"
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
    call array_ass_subscript
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
    RAISE exc_TypeError_type, "__setitem__() takes exactly two arguments"
END_FUNC array_m_setitem

;; ============================================================================
;; array_m_len(args, nargs) -> the item count, as a Value
;; ============================================================================
DEF_FUNC array_m_len
    mov rdi, [rdi]
    mov rdi, [rdi + PyArrayObject.ob_size]
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
END_FUNC array_m_len
