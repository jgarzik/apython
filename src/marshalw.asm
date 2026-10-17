;; ============================================================================
;; marshalw.asm -- marshal, going out.
;;
;; src/marshal.asm reads a .pyc and answers marshal.loads(); this writes.
;; They share a format and nothing else: there is no output buffer on the read
;; side, no writers, and marshal_refs is an INDEXED ARRAY -- it answers "what
;; was object number 7" and cannot answer "have I written this object before",
;; which is the question FLAG_REF asks on the way out.  So the memo here is an
;; identity table of its own.
;;
;; A separate file because marshal.asm is large and because the two directions
;; share no code; posixdir.asm and posixid.asm sit beside posix.asm for the
;; same reason.
;;
;; What this does NOT do, and CPython does: version 0 and 1 of the format
;; (this always writes version 4, which is what 3.12 writes and what its own
;; reader prefers), and the out-of-band buffer protocol, which marshal has
;; never had.
;; ============================================================================

%include "src/include/object.inc"
%include "src/include/macros.inc"
%include "src/include/value.inc"

MARSHAL_TYPE_NULL             equ 0x30
MARSHAL_TYPE_NONE             equ 0x4e
MARSHAL_TYPE_FALSE            equ 0x46
MARSHAL_TYPE_TRUE             equ 0x54
MARSHAL_TYPE_STOPITER         equ 0x53
MARSHAL_TYPE_ELLIPSIS         equ 0x2e
MARSHAL_TYPE_INT              equ 0x69
MARSHAL_TYPE_INT64            equ 0x49
MARSHAL_TYPE_BINARY_FLOAT     equ 0x67
MARSHAL_TYPE_BINARY_COMPLEX   equ 0x79
MARSHAL_TYPE_LONG             equ 0x6c
MARSHAL_TYPE_STRING           equ 0x73
MARSHAL_TYPE_REF              equ 0x72
MARSHAL_TYPE_TUPLE            equ 0x28
MARSHAL_TYPE_CODE             equ 0x63
MARSHAL_TYPE_SET              equ 0x3c
MARSHAL_TYPE_LIST             equ 0x5b
MARSHAL_TYPE_DICT             equ 0x7b
MARSHAL_TYPE_FROZENSET        equ 0x3e
MARSHAL_TYPE_ASCII            equ 0x61
MARSHAL_TYPE_SMALL_TUPLE      equ 0x29
MARSHAL_TYPE_SHORT_ASCII      equ 0x7a
MARSHAL_TYPE_UNICODE          equ 0x75
MARSHAL_TYPE_INTERNED         equ 0x74
MARSHAL_TYPE_ASCII_INTERNED   equ 0x41
MARSHAL_TYPE_SHORT_ASCII_INTERNED equ 0x5a
MARSHAL_FLAG_REF              equ 0x80
; A set's entries are sixteen bytes and a dict's twenty-four; the two share a
; header and nothing else.
MW_SET_ENTRY_KEY              equ 8

extern ap_malloc
extern ap_realloc
extern ap_free
extern ap_memcpy
extern obj_decref
extern obj_incref
extern bytes_from_data
extern str_is_interned
extern none_singleton
extern bool_true
extern bool_false
extern ellipsis_singleton
extern int_type
extern str_type
extern bytes_type
extern bytearray_type
extern tuple_type
extern list_type
extern dict_type
extern set_type
extern frozenset_type
extern float_type
extern complex_type
extern code_type
extern exc_ValueError_type
extern exc_TypeError_type
extern raise_exception
extern int_to_i64
extern int_is_compact
extern __gmpz_sizeinbase
extern __gmpz_getlimbn

section .bss
;; The output.  One buffer for the whole dump, grown by doubling; a nested
;; object writes into the same one, which is why these are globals rather
;; than a parameter threaded through every writer.
mw_buf:   resq 1
mw_len:   resq 1
mw_cap:   resq 1
mw_error: resq 1            ; non-zero once a refusal has been recorded

;; The FLAG_REF memo: object pointer -> the index it was written at.  A flat
;; array searched linearly.  CPython uses a hash table; this is a dump, the
;; arrays are short in every real case, and a wrong answer here is a wrong
;; FILE rather than a slow one.
mw_memo:     resq 1         ; {ptr, index} pairs
mw_memo_len: resq 1
mw_memo_cap: resq 1

section .text

;; ============================================================================
;; mw_reserve(rdi = how many more bytes) -> rax = 1 ok, 0 out of memory
;; ============================================================================
MWR_NEED  equ 8             ; the size the buffer must reach
MWR_CAP   equ 16            ; the capacity being asked for, across the realloc
MWR_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL mw_reserve, MWR_FRAME
    mov rax, [rel mw_len]
    add rax, rdi
    cmp rax, [rel mw_cap]
    jbe .mwr_ok
    mov [rbp - MWR_NEED], rax
    mov rax, [rel mw_cap]
    test rax, rax
    jnz .mwr_grow
    mov eax, 256
.mwr_grow:
    add rax, rax
    cmp rax, [rbp - MWR_NEED]
    jb .mwr_grow
    mov [rbp - MWR_CAP], rax
    mov rdi, [rel mw_buf]
    mov rsi, rax
    call ap_realloc
    test rax, rax
    jz .mwr_fail
    mov [rel mw_buf], rax
    mov rax, [rbp - MWR_CAP]
    mov [rel mw_cap], rax
.mwr_ok:
    mov eax, 1
    leave
    ret
.mwr_fail:
    mov qword [rel mw_error], 1
    xor eax, eax
    leave
    ret
END_FUNC mw_reserve

;; ============================================================================
;; mw_byte(rdi = the byte) -> nothing
;; ============================================================================
MWV_VAL   equ 8             ; the value, across the reserve
MWV_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL mw_byte, MWV_FRAME
    mov [rbp - MWV_VAL], rdi
    mov edi, 1
    call mw_reserve
    test eax, eax
    jz .mwb_out
    mov rax, [rel mw_buf]
    mov rcx, [rel mw_len]
    mov rdx, [rbp - MWV_VAL]
    mov [rax + rcx], dl
    inc qword [rel mw_len]
.mwb_out:
    leave
    ret
END_FUNC mw_byte

;; ============================================================================
;; mw_long(rdi = an int32) -> nothing; four bytes, little-endian
;; ============================================================================
DEF_FUNC_LOCAL mw_long, MWV_FRAME
    mov [rbp - MWV_VAL], rdi
    mov edi, 4
    call mw_reserve
    test eax, eax
    jz .mwl_out
    mov rax, [rel mw_buf]
    mov rcx, [rel mw_len]
    mov rdx, [rbp - MWV_VAL]
    mov [rax + rcx], edx
    add qword [rel mw_len], 4
.mwl_out:
    leave
    ret
END_FUNC mw_long

;; ============================================================================
;; mw_short(rdi = a 15-bit digit) -> nothing; two bytes, little-endian
;; ============================================================================
DEF_FUNC_LOCAL mw_short, MWV_FRAME
    mov [rbp - MWV_VAL], rdi
    mov edi, 2
    call mw_reserve
    test eax, eax
    jz .mws_out
    mov rax, [rel mw_buf]
    mov rcx, [rel mw_len]
    mov rdx, [rbp - MWV_VAL]
    mov [rax + rcx], dx
    add qword [rel mw_len], 2
.mws_out:
    leave
    ret
END_FUNC mw_short

;; ============================================================================
;; mw_long64(rdi = an int64) -> nothing; eight bytes, little-endian
;; ============================================================================
DEF_FUNC_LOCAL mw_long64, MWV_FRAME
    mov [rbp - MWV_VAL], rdi
    mov edi, 8
    call mw_reserve
    test eax, eax
    jz .mwq_out
    mov rax, [rel mw_buf]
    mov rcx, [rel mw_len]
    mov rdx, [rbp - MWV_VAL]
    mov [rax + rcx], rdx
    add qword [rel mw_len], 8
.mwq_out:
    leave
    ret
END_FUNC mw_long64

;; ============================================================================
;; mw_bytes(rdi = the data, rsi = how many) -> nothing; the bytes alone, with
;;   no length in front -- every caller writes its own first
;; ============================================================================
MWB_DATA  equ 8
MWB_LEN   equ 16
MWB_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL mw_bytes, MWB_FRAME
    mov [rbp - MWB_DATA], rdi
    mov [rbp - MWB_LEN], rsi
    mov rdi, rsi
    call mw_reserve
    test eax, eax
    jz .mwbs_out
    mov rdi, [rel mw_buf]
    add rdi, [rel mw_len]
    mov rsi, [rbp - MWB_DATA]
    mov rdx, [rbp - MWB_LEN]
    call ap_memcpy
    mov rax, [rbp - MWB_LEN]
    add [rel mw_len], rax
.mwbs_out:
    leave
    ret
END_FUNC mw_bytes

;; ============================================================================
;; mw_memo_find(rdi = an object pointer) -> rax = its index + 1, or 0
;;
;; The FLAG_REF memo.  CPython keeps a hash table keyed by identity; this is a
;; flat array searched linearly, because a dump's shared objects are few and
;; a wrong answer here is a wrong FILE rather than a slow one.  The read side
;; cannot supply this: marshal_refs is an INDEXED ARRAY, answering "what was
;; object number 7", which is the opposite question.
;; ============================================================================
DEF_FUNC_LOCAL mw_memo_find, 16
    mov rsi, [rel mw_memo]
    test rsi, rsi
    jz .mmf_no
    mov rcx, [rel mw_memo_len]
    xor edx, edx
.mmf_loop:
    cmp rdx, rcx
    jae .mmf_no
    mov rax, rdx
    shl rax, 4                          ; sixteen bytes a pair; the scale
                                        ; factor only goes up to eight
    cmp [rsi + rax], rdi
    je .mmf_yes
    inc rdx
    jmp .mmf_loop
.mmf_yes:
    mov rax, [rsi + rax + 8]
    inc rax
    leave
    ret
.mmf_no:
    xor eax, eax
    leave
    ret
END_FUNC mw_memo_find

;; ============================================================================
;; mw_memo_add(rdi = an object pointer) -> nothing; remembers where it went
;; ============================================================================
MMA_OBJ   equ 8
MMA_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL mw_memo_add, MMA_FRAME
    mov [rbp - MMA_OBJ], rdi
    mov rax, [rel mw_memo_len]
    cmp rax, [rel mw_memo_cap]
    jb .mma_room
    mov rax, [rel mw_memo_cap]
    test rax, rax
    jnz .mma_double
    mov eax, 16
    jmp .mma_alloc
.mma_double:
    add rax, rax
.mma_alloc:
    push rax
    push rax
    mov rdi, [rel mw_memo]
    mov rsi, rax
    shl rsi, 4
    call ap_realloc
    pop rcx
    pop rcx
    test rax, rax
    jz .mma_fail
    mov [rel mw_memo], rax
    mov [rel mw_memo_cap], rcx
.mma_room:
    mov rax, [rel mw_memo]
    mov rcx, [rel mw_memo_len]
    mov rsi, rcx
    shl rsi, 4
    add rax, rsi
    mov rdx, [rbp - MMA_OBJ]
    mov [rax], rdx
    ; The index a reference will name is how many objects have been memoised,
    ; which is the position CPython's w_ref assigns.
    mov [rax + 8], rcx
    inc qword [rel mw_memo_len]
.mma_fail:
    leave
    ret
END_FUNC mw_memo_add

;; ============================================================================
;; mw_ref(rdi = the object, rsi = its type byte) -> rax = 1 when a back
;;   reference was written and the caller has nothing more to do
;;
;; CPython memoises every object big enough to be worth sharing -- which is
;; everything but the singletons and the small scalars -- and writes the type
;; byte with FLAG_REF set the first time.  Writing the byte is this
;; function's job either way, so a caller that comes here writes no byte of
;; its own.
;; ============================================================================
MWF_OBJ   equ 8
MWF_TYPE  equ 16
MWF_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL mw_ref, MWF_FRAME
    mov [rbp - MWF_OBJ], rdi
    mov [rbp - MWF_TYPE], rsi
    call mw_memo_find
    test rax, rax
    jz .mwf_first
    dec rax
    push rax
    push rax
    mov edi, MARSHAL_TYPE_REF
    call mw_byte
    pop rdi
    pop rcx
    call mw_long
    mov eax, 1
    leave
    ret
.mwf_first:
    mov rdi, [rbp - MWF_TYPE]
    or rdi, MARSHAL_FLAG_REF
    call mw_byte
    mov rdi, [rbp - MWF_OBJ]
    call mw_memo_add
    xor eax, eax
    leave
    ret
END_FUNC mw_ref

;; ============================================================================
;; mw_object(rdi = a Value) -> nothing; writes it, whatever it is
;;
;; The dispatch is on the OBJECT rather than on a byte, which is the one way
;; this is not a mirror of the reader.  A Value that is not a pointer is an
;; int or a float immediate and is settled first; everything else is a type
;; compare, and an EXACT type -- CPython refuses a subclass with
;; "unmarshallable object", because the reader would answer with the base and
;; the round trip would not hold.
;; ============================================================================
MWO_VAL   equ 8
MWO_OBJ   equ 16
MWO_I     equ 24
MWO_N     equ 32
MWO_DIGITS equ 40           ; the big-int fields, which need four more slots
MWO_ACC   equ 48
MWO_BIT   equ 56
MWO_FRAME equ 72            ; + 1 push = 80, 16-aligned
global mw_object
DEF_FUNC mw_object, MWO_FRAME
    push rbx
    mov [rbp - MWO_VAL], rdi
    cmp qword [rel mw_error], 0
    jne .mwo_out

    ; An immediate: an int in +-2^50, or a float.
    V_TEST_PTR rdi, rcx
    jbe .mwo_pointer
    ; V_IS_INT answers in the CARRY flag, not in ZF: CF=0 means it is one.
    V_IS_INT rdi, rcx
    jb .mwo_immediate_float
    V_TO_I64 rdi
    jmp .mwo_write_i64
.mwo_immediate_float:
    V_TO_F64 rdi
    mov [rbp - MWO_OBJ], rdi
    mov edi, MARSHAL_TYPE_BINARY_FLOAT
    call mw_byte
    mov rdi, [rbp - MWO_OBJ]
    call mw_long64
    jmp .mwo_out

.mwo_pointer:
    test rdi, rdi
    jz .mwo_null
    mov [rbp - MWO_OBJ], rdi
    mov rbx, rdi

    ; The singletons, which are identities rather than types.
    lea rax, [rel none_singleton]
    cmp rbx, rax
    je .mwo_none
    lea rax, [rel bool_true]
    cmp rbx, rax
    je .mwo_true
    lea rax, [rel bool_false]
    cmp rbx, rax
    je .mwo_false
    lea rax, [rel ellipsis_singleton]
    cmp rbx, rax
    je .mwo_ellipsis
    ; StopIteration is the one exception CLASS the format names.  CPython
    ; writes it because a generator's marshalled return path used to need it;
    ; nothing else in the type table is an object rather than a shape.
    extern exc_StopIteration_type
    lea rax, [rel exc_StopIteration_type]
    cmp rbx, rax
    je .mwo_stopiter

    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .mwo_int
    lea rcx, [rel float_type]
    cmp rax, rcx
    je .mwo_float
    lea rcx, [rel complex_type]
    cmp rax, rcx
    je .mwo_complex
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .mwo_str
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .mwo_bytes
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .mwo_tuple
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .mwo_list
    lea rcx, [rel dict_type]
    cmp rax, rcx
    je .mwo_dict
    lea rcx, [rel set_type]
    cmp rax, rcx
    je .mwo_set
    lea rcx, [rel frozenset_type]
    cmp rax, rcx
    je .mwo_frozenset
    lea rcx, [rel code_type]
    cmp rax, rcx
    je .mwo_code
    jmp .mwo_unmarshallable

.mwo_null:
    mov edi, MARSHAL_TYPE_NULL
    call mw_byte
    jmp .mwo_out
.mwo_none:
    mov edi, MARSHAL_TYPE_NONE
    call mw_byte
    jmp .mwo_out
.mwo_true:
    mov edi, MARSHAL_TYPE_TRUE
    call mw_byte
    jmp .mwo_out
.mwo_false:
    mov edi, MARSHAL_TYPE_FALSE
    call mw_byte
    jmp .mwo_out
.mwo_ellipsis:
    mov edi, MARSHAL_TYPE_ELLIPSIS
    call mw_byte
    jmp .mwo_out
.mwo_stopiter:
    mov edi, MARSHAL_TYPE_STOPITER
    call mw_byte
    jmp .mwo_out

.mwo_float:
    mov edi, MARSHAL_TYPE_BINARY_FLOAT
    call mw_byte
    mov rdi, [rbx + PyFloatObject.value]
    call mw_long64
    jmp .mwo_out

.mwo_complex:
    mov edi, MARSHAL_TYPE_BINARY_COMPLEX
    call mw_byte
    mov rdi, [rbx + PyComplexObject.cval_real]
    call mw_long64
    mov rdi, [rbx + PyComplexObject.cval_imag]
    call mw_long64
    jmp .mwo_out

.mwo_int:
    ; A compact int is one the reader can take as 'i' or 'I'; anything wider
    ; is GMP-backed and becomes the 15-bit-digit 'l' form.
    cmp qword [rbx + PyIntObject.compact], 0
    je .mwo_bigint
    mov rdi, [rbx + PyIntObject.ival]
.mwo_write_i64:
    ; 'i' holds a signed 32-bit value and 'I' a signed 64-bit one; CPython
    ; writes the narrower whenever it fits, and its own reader sign-extends.
    mov [rbp - MWO_OBJ], rdi
    movsxd rax, edi
    cmp rax, rdi
    jne .mwo_write_i64_wide
    mov edi, MARSHAL_TYPE_INT
    call mw_byte
    mov rdi, [rbp - MWO_OBJ]
    call mw_long
    jmp .mwo_out
.mwo_write_i64_wide:
    mov edi, MARSHAL_TYPE_INT64
    call mw_byte
    mov rdi, [rbp - MWO_OBJ]
    call mw_long64
    jmp .mwo_out

.mwo_bigint:
    ; CPython's 'l': a signed digit count, then that many 15-bit digits,
    ; least significant first.  The sign is the COUNT's, which is why the
    ; magnitude and the sign are read apart here.
    ;
    ; Frame slots and not r12-r15: this runs inside the eval loop, where
    ; those four hold the frame, the value stack, the constants and the
    ; scratch.  Saving them is not enough -- `xor r12d, r12d` before the
    ; push saves a zero, and the frame pointer is gone from there to the
    ; next return.  That is the bug this paragraph is standing in for.
    mov edi, MARSHAL_TYPE_LONG
    call mw_byte
    ; mpz_sgn is a C macro rather than a function, so the sign is read where
    ; the macro reads it: mpz_t is {alloc:4, size:4, *d:8} and `size` is
    ; NEGATIVE for a negative number.
    movsxd rax, dword [rbx + PyIntObject.mpz + 4]
    mov [rbp - MWO_N], rax              ; the sign, for the count below
    lea rdi, [rbx + PyIntObject.mpz]
    mov esi, 2
    call __gmpz_sizeinbase              ; bits, rounded up
    add rax, 14
    xor edx, edx
    mov ecx, 15
    div rcx
    mov [rbp - MWO_DIGITS], rax
    mov rdi, rax
    cmp qword [rbp - MWO_N], 0
    jge .mwo_long_count
    neg rdi
.mwo_long_count:
    call mw_long

    ; The digits.  mpz_tstbit answers the INFINITE-PRECISION TWO'S COMPLEMENT
    ; bit, so a negative number's came out as the complement of its magnitude
    ; -- the header was right and the body was a different number.
    ; mpz_getlimbn is the accessor that reads the MAGNITUDE, which is what a
    ; sign-and-digits format wants, and it answers 0 past the end so the last
    ; digit needs no special case.
    mov qword [rbp - MWO_I], 0
.mwo_long_digit:
    mov rax, [rbp - MWO_I]
    cmp rax, [rbp - MWO_DIGITS]
    jae .mwo_out
    ; The digit starts at bit 15*k, which is limb 15*k/64, shift 15*k%64.
    mov rax, [rbp - MWO_I]
    imul rax, rax, 15
    mov [rbp - MWO_BIT], rax
    mov rsi, rax
    shr rsi, 6
    lea rdi, [rbx + PyIntObject.mpz]
    call __gmpz_getlimbn
    mov rcx, [rbp - MWO_BIT]
    and rcx, 63
    shr rax, cl
    mov [rbp - MWO_ACC], rax
    ; When fewer than fifteen bits are left in this limb, the rest are the
    ; low bits of the next one.
    cmp rcx, 64 - 15
    jbe .mwo_long_one_limb
    mov rsi, [rbp - MWO_BIT]
    shr rsi, 6
    inc rsi
    lea rdi, [rbx + PyIntObject.mpz]
    call __gmpz_getlimbn
    mov rcx, [rbp - MWO_BIT]
    and rcx, 63
    neg rcx
    add rcx, 64
    shl rax, cl
    or [rbp - MWO_ACC], rax
.mwo_long_one_limb:
    mov rdi, [rbp - MWO_ACC]
    and rdi, 0x7fff
    call mw_short
    inc qword [rbp - MWO_I]
    jmp .mwo_long_digit

.mwo_str:
    ; CPython's choice, in its order: interned or not, then ASCII or not,
    ; then for ASCII whether the length fits the SHORT form's one byte.  The
    ; INTERNED codes are what make the reader intern it again -- without them
    ; a .pyc we write ourselves hands back identifiers that are not `is` the
    ; same literal elsewhere.  ob_size is the BYTE length and ob_length the
    ; code points; equal means ASCII.
    mov rdi, rbx
    call str_is_interned
    mov [rbp - MWO_I], rax              ; 1 = interned
    mov qword [rbp - MWO_N], 0          ; 1 = the SHORT form's one-byte length
    mov rax, [rbx + PyStrObject.ob_size]
    cmp rax, [rbx + PyStrObject.ob_length]
    jne .mwo_str_unicode
    cmp rax, 256
    jae .mwo_str_ascii
    mov qword [rbp - MWO_N], 1
    mov esi, MARSHAL_TYPE_SHORT_ASCII
    cmp qword [rbp - MWO_I], 0
    je .mwo_str_ref
    mov esi, MARSHAL_TYPE_SHORT_ASCII_INTERNED
    jmp .mwo_str_ref
.mwo_str_ascii:
    mov esi, MARSHAL_TYPE_ASCII
    cmp qword [rbp - MWO_I], 0
    je .mwo_str_ref
    mov esi, MARSHAL_TYPE_ASCII_INTERNED
    jmp .mwo_str_ref
.mwo_str_unicode:
    mov esi, MARSHAL_TYPE_UNICODE
    cmp qword [rbp - MWO_I], 0
    je .mwo_str_ref
    mov esi, MARSHAL_TYPE_INTERNED
.mwo_str_ref:
    mov rdi, rbx
    call mw_ref
    test eax, eax
    jnz .mwo_out                        ; a back reference; nothing more
    mov rdi, [rbx + PyStrObject.ob_size]
    cmp qword [rbp - MWO_N], 0
    je .mwo_str_long_len
    call mw_byte
    jmp .mwo_str_data
.mwo_str_long_len:
    call mw_long
.mwo_str_data:
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, [rbx + PyStrObject.ob_size]
    call mw_bytes
    jmp .mwo_out

.mwo_bytes:
    mov rdi, rbx
    mov esi, MARSHAL_TYPE_STRING
    call mw_ref
    test eax, eax
    jnz .mwo_out
    mov rdi, [rbx + PyBytesObject.ob_size]
    call mw_long
    lea rdi, [rbx + PyBytesObject.data]
    mov rsi, [rbx + PyBytesObject.ob_size]
    call mw_bytes
    jmp .mwo_out

.mwo_tuple:
    mov rdi, rbx
    mov esi, MARSHAL_TYPE_TUPLE
    call mw_ref
    test eax, eax
    jnz .mwo_out
    mov rax, [rbx + PyTupleObject.ob_size]
    mov [rbp - MWO_N], rax
    mov rdi, rax
    call mw_long
    jmp .mwo_items

.mwo_list:
    mov rdi, rbx
    mov esi, MARSHAL_TYPE_LIST
    call mw_ref
    test eax, eax
    jnz .mwo_out
    mov rax, [rbx + PyListObject.ob_size]
    mov [rbp - MWO_N], rax
    mov rdi, rax
    call mw_long
    jmp .mwo_items

;; The items of a tuple or a list, which are laid out the same way: a
;; pointer to a Value[] and a count.
.mwo_items:
    mov qword [rbp - MWO_I], 0
.mwo_item_loop:
    mov rcx, [rbp - MWO_I]
    cmp rcx, [rbp - MWO_N]
    jae .mwo_out
    mov rax, [rbx + PyTupleObject.ob_item]
    mov rdi, [rax + rcx*8]
    call mw_object
    inc qword [rbp - MWO_I]
    jmp .mwo_item_loop

.mwo_dict:
    mov rdi, rbx
    mov esi, MARSHAL_TYPE_DICT
    call mw_ref
    test eax, eax
    jnz .mwo_out
    ; A dict is written as key, value, key, value and terminated by a NULL,
    ; which is why there is no count.
    mov qword [rbp - MWO_I], 0
.mwo_dict_loop:
    mov rcx, [rbp - MWO_I]
    cmp rcx, [rbx + PyDictObject.capacity]
    jae .mwo_dict_done
    mov rax, [rbx + PyDictObject.entries]
    imul rdx, rcx, DictEntry_size
    add rax, rdx
    cmp qword [rax + DictEntry.key], 0
    je .mwo_dict_next
    mov [rbp - MWO_OBJ], rax
    mov rdi, [rax + DictEntry.key]
    call mw_object
    mov rax, [rbp - MWO_OBJ]
    mov rdi, [rax + DictEntry.value]
    call mw_object
.mwo_dict_next:
    inc qword [rbp - MWO_I]
    jmp .mwo_dict_loop
.mwo_dict_done:
    mov edi, MARSHAL_TYPE_NULL
    call mw_byte
    jmp .mwo_out

.mwo_set:
    mov rdi, rbx
    mov esi, MARSHAL_TYPE_SET
    jmp .mwo_set_common
.mwo_frozenset:
    mov rdi, rbx
    mov esi, MARSHAL_TYPE_FROZENSET
.mwo_set_common:
    call mw_ref
    test eax, eax
    jnz .mwo_out
    mov rdi, [rbx + PyDictObject.ob_size]
    call mw_long
    mov qword [rbp - MWO_I], 0
.mwo_set_loop:
    mov rcx, [rbp - MWO_I]
    cmp rcx, [rbx + PyDictObject.capacity]
    jae .mwo_out
    mov rax, [rbx + PyDictObject.entries]
    mov rdx, rcx
    shl rdx, 4                          ; SET_ENTRY_SIZE, and not DictEntry's
    add rax, rdx
    mov rdi, [rax + MW_SET_ENTRY_KEY]
    test rdi, rdi
    jz .mwo_set_next
    call mw_object
.mwo_set_next:
    inc qword [rbp - MWO_I]
    jmp .mwo_set_loop

.mwo_code:
    mov rdi, rbx
    mov esi, MARSHAL_TYPE_CODE
    call mw_ref
    test eax, eax
    jnz .mwo_out
    call mw_code_fields
    jmp .mwo_out

.mwo_out:
    pop rbx
    leave
    ret

.mwo_unmarshallable:
    mov qword [rel mw_error], 2
    pop rbx
    leave
    ret
END_FUNC mw_object

;; ============================================================================
;; mw_code_fields(rbx = the code object) -> nothing
;;
;; The seventeen fields, in the order the reader takes them.  That order is
;; the format: mdo_code in marshal.asm read backwards is this function, and
;; the two must be edited together or a .pyc written here will not load.
;;
;; co_code is not a field of PyCodeObject here -- the bytecode lives INLINE
;; at the end of the object, with co_code_len saying how much -- so it is
;; written as a bytes object built for the purpose rather than passed along.
;; ============================================================================
MCF_TMP   equ 8
MCF_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL mw_code_fields, MCF_FRAME
    mov edi, [rbx + PyCodeObject.co_argcount]
    call mw_long
    mov edi, [rbx + PyCodeObject.co_posonlyargcount]
    call mw_long
    mov edi, [rbx + PyCodeObject.co_kwonlyargcount]
    call mw_long
    mov edi, [rbx + PyCodeObject.co_stacksize]
    call mw_long
    mov edi, [rbx + PyCodeObject.co_flags]
    call mw_long

    ; co_code, as bytes.  The code is stored INLINE in the code object, so
    ; there is no bytes object to hand over and one is built here.
    ;
    ; It is written UNFLAGGED -- straight through mw_byte rather than through
    ; mw_ref -- because it is a temporary.  Memoising it puts its address in
    ; the table and then frees it, and the next code object's temporary is
    ; allocated at the same address; mw_memo_find matched, and the inner code
    ; object of `class A(property)` was handed the OUTER one's bytecode.  It
    ; read back as a valid code object running the wrong instructions, which
    ; is how it surfaced: a class body that stored its own docstring onto
    ; `property.__doc__`.  Nothing is lost by not memoising it -- no two code
    ; objects share one co_code, so the entry could never have been hit.
    mov edi, MARSHAL_TYPE_STRING
    call mw_byte
    movsxd rdi, dword [rbx + PyCodeObject.co_code_len]
    call mw_long
    lea rdi, [rbx + PyCodeObject.co_code]
    movsxd rsi, dword [rbx + PyCodeObject.co_code_len]
    call mw_bytes

    mov rdi, [rbx + PyCodeObject.co_consts]
    call mw_object
    mov rdi, [rbx + PyCodeObject.co_names]
    call mw_object
    mov rdi, [rbx + PyCodeObject.co_localsplusnames]
    call mw_object
    mov rdi, [rbx + PyCodeObject.co_localspluskinds]
    call mw_object
    mov rdi, [rbx + PyCodeObject.co_filename]
    call mw_object
    mov rdi, [rbx + PyCodeObject.co_name]
    call mw_object
    mov rdi, [rbx + PyCodeObject.co_qualname]
    call mw_object
    mov edi, [rbx + PyCodeObject.co_firstlineno]
    call mw_long
    mov rdi, [rbx + PyCodeObject.co_linetable]
    call mw_object
    mov rdi, [rbx + PyCodeObject.co_exceptiontable]
    call mw_object
    leave
    ret
.mcf_oom:
    mov qword [rel mw_error], 1
    leave
    ret
END_FUNC mw_code_fields

;; ============================================================================
;; mw_begin() -> nothing; starts a dump
;;
;; One dump's lifetime.  The buffer and the memo are globals because a nested
;; object writes into the same ones; this and mw_end are what make a dump a
;; unit, and they are what a caller must bracket every top-level write with.
;; ============================================================================
DEF_FUNC_LOCAL mw_begin, 16
    mov qword [rel mw_buf], 0
    mov qword [rel mw_len], 0
    mov qword [rel mw_cap], 0
    mov qword [rel mw_error], 0
    mov qword [rel mw_memo], 0
    mov qword [rel mw_memo_len], 0
    mov qword [rel mw_memo_cap], 0
    leave
    ret
END_FUNC mw_begin

;; ============================================================================
;; mw_end() -> rax = the bytes written, owned, or 0 when something refused
;; ============================================================================
MWE_OUT   equ 8
MWE_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL mw_end, MWE_FRAME
    mov qword [rbp - MWE_OUT], 0
    cmp qword [rel mw_error], 0
    jne .mwe_free
    mov rdi, [rel mw_buf]
    mov rsi, [rel mw_len]
    call bytes_from_data
    mov [rbp - MWE_OUT], rax
.mwe_free:
    mov rdi, [rel mw_buf]
    test rdi, rdi
    jz .mwe_no_buf
    call ap_free
.mwe_no_buf:
    mov rdi, [rel mw_memo]
    test rdi, rdi
    jz .mwe_no_memo
    call ap_free
.mwe_no_memo:
    mov qword [rel mw_buf], 0
    mov qword [rel mw_memo], 0
    mov qword [rel mw_cap], 0
    mov qword [rel mw_memo_cap], 0
    mov rax, [rbp - MWE_OUT]
    leave
    ret
END_FUNC mw_end

;; ============================================================================
;; marshal_dumps_fn(rdi = the argument array, rsi = how many)
;;   -> rax = the bytes, as a Value
;;
;; marshal.dumps(value, version=4).  The version is accepted and ignored:
;; this writes version 4, which is what 3.12 writes and what every reader
;; since 3.4 prefers.  Writing 0 or 1 would mean a second set of writers for
;; a format nothing reads.
;; ============================================================================
MDS_VAL   equ 8             ; the object, across mw_begin
MDS_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
global marshal_dumps_fn
DEF_FUNC marshal_dumps_fn, MDS_FRAME
    test rsi, rsi
    jz .mds_args
    cmp rsi, 2
    ja .mds_args
    mov rdi, [rdi]
    mov [rbp - MDS_VAL], rdi
    call mw_begin
    mov rdi, [rbp - MDS_VAL]
    call mw_object
    call mw_end
    test rax, rax
    jz .mds_failed
    mov edx, TAG_PTR
    leave
    ret
.mds_failed:
    ; mw_error 2 is "this object has no marshal form"; anything else is the
    ; allocator.  CPython words the first "unmarshallable object".
    cmp qword [rel mw_error], 2
    jne .mds_oom
    RAISE exc_ValueError_type, "unmarshallable object"
.mds_oom:
    xor eax, eax
    xor edx, edx
    leave
    ret
.mds_args:
    RAISE exc_TypeError_type, "dumps() takes 1 or 2 arguments"
END_FUNC marshal_dumps_fn

;; ============================================================================
;; marshal_dump_fn(value, file, version=4) -> None
;;
;; marshal.dump().  The file is anything with a .write that takes bytes,
;; which is what CPython's accepts once its own fast path for a real file
;; object declines -- and the only kind this has.
;; ============================================================================
extern obj_getattr_opt
extern obj_dealloc
extern str_from_cstr_heap
extern obj_call_n
extern raise_no_attribute
extern str_intern_cstr
MDP_ARGS  equ 24            ; the one Value handed to .write; see the note on
                            ; an argument array growing upward
MDP_FILE  equ 32
MDP_BYTES equ 40
MDP_NAME  equ 48
MDP_FRAME equ 56            ; + 1 push = 64, 16-aligned
global marshal_dump_fn
DEF_FUNC marshal_dump_fn, MDP_FRAME
    push rbx
    cmp rsi, 2
    jb .mdp_args
    cmp rsi, 3
    ja .mdp_args
    mov rbx, rdi
    mov rax, [rbx + 8]
    mov [rbp - MDP_FILE], rax

    call mw_begin
    mov rdi, [rbx]
    call mw_object
    call mw_end
    test rax, rax
    jz .mdp_failed
    mov [rbp - MDP_BYTES], rax
    mov [rbp - MDP_ARGS], rax

    ; obj_getattr_opt takes the name as a str and runs the descriptor
    ; protocol, which is what turns file.write into a BOUND method --
    ; obj_getattr_str_opt beside it answers only str attributes and would
    ; call this absent.
    CSTRING rdi, "write"
    call str_intern_cstr
    test rax, rax
    jz .mdp_release
    mov [rbp - MDP_NAME], rax
    mov rdi, [rbp - MDP_FILE]
    mov rsi, rax
    call obj_getattr_opt
    push rax
    push rax
    mov rdi, [rbp - MDP_NAME]
    call obj_decref                     ; ours; the intern table keeps one
    pop rax
    pop rcx
    test rax, rax
    jz .mdp_no_write
    mov [rbp - MDP_FILE], rax           ; the bound method, ours
    mov rdi, rax
    lea rsi, [rbp - MDP_ARGS]
    mov edx, 1
    call obj_call_n
    push rax
    push rax
    mov rdi, [rbp - MDP_FILE]
    call obj_decref
    mov rdi, [rbp - MDP_BYTES]
    call obj_decref
    pop rax
    pop rcx
    test rax, rax
    jz .mdp_propagate
    ; .write answers the byte count, an int immediate as often as not, so
    ; this has to go through the Value-aware decref rather than a raw one.
    mov rdi, rax
    DECREF_V rdi, rsi
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.mdp_no_write:
    ; CPython's dump() reaches .write with a plain getattr, so a file without
    ; one fails as an ordinary AttributeError naming the type -- not as a
    ; TypeError of marshal's own.
    mov rdi, [rbp - MDP_BYTES]
    call obj_decref
    mov rdi, [rbp - MDP_FILE]
    mov rsi, [rbp - MDP_NAME]
    xor edx, edx
    pop rbx
    call raise_no_attribute
.mdp_release:
    mov rdi, [rbp - MDP_BYTES]
    call obj_decref
.mdp_propagate:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.mdp_failed:
    cmp qword [rel mw_error], 2
    jne .mdp_propagate
    RAISE exc_ValueError_type, "unmarshallable object"
.mdp_args:
    RAISE exc_TypeError_type, "dump() takes 2 or 3 arguments"
END_FUNC marshal_dump_fn

;; ============================================================================
;; marshal_load_fn(rdi = the argument array, rsi = how many)
;;   -> rax = the object the stream named, as a Value
;;
;; marshal.load(file).  CPython's reads the stream incrementally, so a file
;; holding two marshalled objects can be walked with two calls; this one
;; reads it whole and hands the bytes to the same reader `loads` uses, which
;; is right for the one caller anybody has -- a .pyc, or a file holding one
;; object -- and wrong for the other.  DIVERGENCES.md carries it.
;; ============================================================================
extern marshal_loads_fn
MDL_ARGS  equ 24            ; the one Value handed on to loads
MDL_DATA  equ 32
MDL_FILE  equ 40
MDL_NAME  equ 48
MDL_FRAME equ 64            ; + 0 pushes = 64, 16-aligned
global marshal_load_fn
DEF_FUNC marshal_load_fn, MDL_FRAME
    test rsi, rsi
    jz .mdl_args
    cmp rsi, 2
    ja .mdl_args
    mov rdi, [rdi]

    mov [rbp - MDL_FILE], rdi
    CSTRING rdi, "read"
    call str_intern_cstr
    test rax, rax
    jz .mdl_fail
    mov [rbp - MDL_NAME], rax
    mov rdi, [rbp - MDL_FILE]
    mov rsi, rax
    call obj_getattr_opt
    push rax
    push rax
    mov rdi, [rbp - MDL_NAME]
    call obj_decref                     ; ours; the intern table keeps one
    pop rax
    pop rcx
    test rax, rax
    jz .mdl_no_read

    mov rdi, rax
    xor esi, esi
    xor edx, edx
    push rdi
    push rdi
    call obj_call_n
    pop rdi
    pop rcx
    mov [rbp - MDL_DATA], rax
    call obj_decref                     ; the bound method
    mov rax, [rbp - MDL_DATA]
    test rax, rax
    jz .mdl_fail

    mov [rbp - MDL_ARGS], rax
    lea rdi, [rbp - MDL_ARGS]
    mov esi, 1
    call marshal_loads_fn
    mov [rbp - MDL_ARGS], rax
    mov rdi, [rbp - MDL_DATA]
    DECREF_V rdi, rsi
    mov rax, [rbp - MDL_ARGS]
    mov edx, TAG_PTR
    leave
    ret

.mdl_no_read:
    mov rdi, [rbp - MDL_FILE]
    mov rsi, [rbp - MDL_NAME]
    xor edx, edx
    call raise_no_attribute
.mdl_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
.mdl_args:
    RAISE exc_TypeError_type, "load() takes 1 or 2 arguments"
END_FUNC marshal_load_fn

;; ============================================================================
;; pyc_cache_path(rdi = a source path as a C string)
;;   -> rax = the cache path, in a static buffer, or 0 when there is none
;;
;; "<dir>/foo.py" becomes "<dir>/__pycache__/foo.apython-312.pyc".  Anything
;; not ending in ".py" has no cache path: a sourceless .pyc IS its own cache
;; file, and the finder hands over other things besides.
;;
;; The answer lives in one static buffer, so a caller that needs to keep it
;; must copy.  pycw_dirlen is left holding the offset of the '/' after
;; "__pycache__", which is where the directory name ends for the mkdir.
;; ============================================================================
PCP_SRC   equ 8
PCP_LEN   equ 16
PCP_STEM  equ 24
PCP_FRAME equ 40            ; + 1 push = 48, 16-aligned
global pyc_cache_path
DEF_FUNC pyc_cache_path, PCP_FRAME
    push rbx
    mov [rbp - PCP_SRC], rdi
    test rdi, rdi
    jz .pcp_no
    call ap_strlen
    mov [rbp - PCP_LEN], rax
    cmp rax, 4
    jb .pcp_no
    cmp rax, PYCW_PATHMAX
    ja .pcp_no
    mov rdi, [rbp - PCP_SRC]
    mov ecx, dword [rdi + rax - 3]
    and ecx, 0x00ffffff
    cmp ecx, 0x0079702e                 ; ".py", little-endian
    jne .pcp_no

    ; Split at the last '/': everything before it is the directory, and what
    ; follows is the stem the cache file is named for.
    mov rcx, [rbp - PCP_LEN]
    mov qword [rbp - PCP_STEM], 0
.pcp_scan:
    test rcx, rcx
    jz .pcp_scanned
    dec rcx
    mov rdi, [rbp - PCP_SRC]
    cmp byte [rdi + rcx], '/'
    jne .pcp_scan
    inc rcx
    mov [rbp - PCP_STEM], rcx
.pcp_scanned:

    lea rdi, [rel pycw_path]
    mov rsi, [rbp - PCP_SRC]
    mov rdx, [rbp - PCP_STEM]
    call ap_memcpy
    mov rbx, [rbp - PCP_STEM]
    lea rdi, [rel pycw_path]
    add rdi, rbx
    lea rsi, [rel pycw_dirname]
    mov edx, pycw_dirname_len
    call ap_memcpy
    add rbx, pycw_dirname_len
    mov [rel pycw_dirlen], rbx

    lea rdi, [rel pycw_path]
    mov byte [rdi + rbx], '/'
    inc rbx
    mov rdx, [rbp - PCP_LEN]
    sub rdx, [rbp - PCP_STEM]
    sub rdx, 3                          ; the stem, without its ".py"
    lea rdi, [rel pycw_path]
    add rdi, rbx
    mov rsi, [rbp - PCP_SRC]
    add rsi, [rbp - PCP_STEM]
    push rdx
    call ap_memcpy
    pop rdx
    add rbx, rdx
    lea rdi, [rel pycw_path]
    add rdi, rbx
    lea rsi, [rel pycw_suffix]
    mov edx, pycw_suffix_len + 1        ; the NUL too
    call ap_memcpy
    add rbx, pycw_suffix_len
    cmp rbx, PYCW_PATHMAX
    ja .pcp_no
    mov [rel pycw_len], rbx
    lea rax, [rel pycw_path]
    pop rbx
    leave
    ret
.pcp_no:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC pyc_cache_path

;; ============================================================================
;; pyc_write_cache(rdi = the source path as a C string, rsi = the code object)
;;   -> nothing.  Every failure is silent.
;;
;; What stops lib/ being recompiled from source on every start.  The layout is
;; CPython's: "<dir>/__pycache__/<stem>.apython-312.pyc", a sixteen-byte header
;; of magic / flags / source mtime / source size, then the marshalled code --
;; the same header pyc_read_file validates, read from the other side.
;;
;; The bytes go to a temporary beside the target and are renamed into place, so
;; a reader never sees a half-written file, and two interpreters starting at
;; once cannot interleave into one.  Nothing here reports: a read-only
;; directory is the ordinary case for a system install, and CPython is silent
;; about it too.
;; ============================================================================
extern sys_open
extern sys_write
extern sys_close
extern sys_stat
extern sys_mkdir
extern sys_unlink
extern sys_rename
extern sys_getpid
extern ap_strlen
extern ap_memset
extern dict_get
extern sys_module_obj

PYCW_MAGIC       equ 0x0a0d0dcb
PYCW_STAT_SIZE   equ 144
PYCW_ST_SIZE     equ 48
PYCW_ST_MODE     equ 24
PYCW_ST_MTIME    equ 88
PYCW_PATHMAX     equ 4000

PW_SRC    equ 8
PW_CODE   equ 16
PW_CLEN   equ 48            ; the cache path's full length
PW_BYTES  equ 56            ; the marshalled code, as a bytes object
PW_FD     equ 64
PW_STAT   equ 64 + PYCW_STAT_SIZE
PW_FRAME  equ PW_STAT + 8   ; + 1 push = 224, 16-aligned
global pyc_write_cache
DEF_FUNC pyc_write_cache, PW_FRAME
    push rbx
    mov [rbp - PW_SRC], rdi
    mov [rbp - PW_CODE], rsi
    test rdi, rdi
    jz .pw_out
    test rsi, rsi
    jz .pw_out

    ; sys.dont_write_bytecode, read here rather than cached: a program may set
    ; it, and -B is only the initial value.
    mov rax, [rel sys_module_obj]
    test rax, rax
    jz .pw_out
    mov rdi, [rax + PyModuleObject.mod_dict]
    test rdi, rdi
    jz .pw_out
    CSTRING rsi, "dont_write_bytecode"
    push rdi
    mov rdi, rsi
    call str_intern_cstr
    pop rdi
    test rax, rax
    jz .pw_out
    mov rsi, rax
    push rax
    push rax
    call dict_get
    pop rcx
    pop rdi
    push rax
    push rax
    call obj_decref                     ; the interned name; ours only
    pop rax
    pop rcx
    test rax, rax
    jz .pw_have_flag                    ; absent means write
    lea rcx, [rel bool_false]
    cmp rax, rcx
    jne .pw_out
.pw_have_flag:

    mov rdi, [rbp - PW_SRC]
    call pyc_cache_path
    test rax, rax
    jz .pw_out
    mov rax, [rel pycw_len]
    mov [rbp - PW_CLEN], rax

    ; The source's mtime, size and MODE.  The first two are what the header
    ; records and what a reader compares against; the third is what the cache
    ; file is created with, because CPython gives the .pyc the source's
    ; permissions rather than the umask's default.
    mov rdi, [rbp - PW_SRC]
    lea rsi, [rbp - PW_STAT]
    call sys_stat
    test rax, rax
    js .pw_out

    ; The directory, which usually exists; EEXIST is the ordinary answer.
    lea rdi, [rel pycw_path]
    mov rbx, [rel pycw_dirlen]
    mov byte [rdi + rbx], 0
    mov esi, 0o777
    call sys_mkdir
    lea rdi, [rel pycw_path]
    mov rbx, [rel pycw_dirlen]
    mov byte [rdi + rbx], '/'

    ; The temporary: the target plus ".<pid>", renamed into place at the end.
    lea rdi, [rel pycw_tmp]
    lea rsi, [rel pycw_path]
    mov rdx, [rbp - PW_CLEN]
    call ap_memcpy
    call sys_getpid
    mov rbx, [rbp - PW_CLEN]
    lea rdi, [rel pycw_tmp]
    mov byte [rdi + rbx], '.'
    inc rbx
    ; the pid in decimal, written backwards into the buffer then reversed is
    ; more code than it is worth: five hex digits name it as well.
    mov ecx, 5
.pw_pid:
    mov rdx, rax
    shr rdx, 16
    and edx, 15
    add dl, '0'
    cmp dl, '9'
    jbe .pw_pid_digit
    add dl, 'a' - '0' - 10
.pw_pid_digit:
    lea rdi, [rel pycw_tmp]
    mov [rdi + rbx], dl
    inc rbx
    shl rax, 4
    dec ecx
    jnz .pw_pid
    lea rdi, [rel pycw_tmp]
    mov byte [rdi + rbx], 0

    ; The payload.  mw_begin/mw_end are the same pair marshal.dumps uses, so
    ; an unmarshallable code object simply produces nothing here.
    call mw_begin
    mov rdi, [rbp - PW_CODE]
    call mw_object
    call mw_end
    test rax, rax
    jz .pw_out
    mov [rbp - PW_BYTES], rax

    ; The mode is the source's, with the write bit forced on and the execute
    ; bits masked off -- CPython's _bootstrap_external does exactly this, so
    ; that a read-only source still yields a .pyc that can be replaced.
    mov edx, dword [rbp - PW_STAT + PYCW_ST_MODE]
    or edx, 0o200
    and edx, 0o666
    lea rdi, [rel pycw_tmp]
    mov esi, 0o1101                     ; O_WRONLY|O_CREAT|O_TRUNC
    call sys_open
    test rax, rax
    js .pw_free
    mov [rbp - PW_FD], rax

    ; The header.  A 32-bit mtime is what the format carries; CPython truncates
    ; it the same way and the reader only ever compares it for equality.
    mov dword [rel pycw_hdr], PYCW_MAGIC
    mov dword [rel pycw_hdr + 4], 0
    mov rax, [rbp - PW_STAT + PYCW_ST_MTIME]
    mov dword [rel pycw_hdr + 8], eax
    mov rax, [rbp - PW_STAT + PYCW_ST_SIZE]
    mov dword [rel pycw_hdr + 12], eax

    mov rdi, [rbp - PW_FD]
    lea rsi, [rel pycw_hdr]
    mov edx, 16
    call sys_write
    cmp rax, 16
    jne .pw_close_fail

    mov rbx, [rbp - PW_BYTES]
    mov rdi, [rbp - PW_FD]
    lea rsi, [rbx + PyBytesObject.data]
    mov rdx, [rbx + PyBytesObject.ob_size]
    call sys_write
    cmp rax, [rbx + PyBytesObject.ob_size]
    jne .pw_close_fail

    mov rdi, [rbp - PW_FD]
    call sys_close
    lea rdi, [rel pycw_tmp]
    lea rsi, [rel pycw_path]
    call sys_rename
    test rax, rax
    jns .pw_free
    lea rdi, [rel pycw_tmp]
    call sys_unlink
    jmp .pw_free

.pw_close_fail:
    mov rdi, [rbp - PW_FD]
    call sys_close
    lea rdi, [rel pycw_tmp]
    call sys_unlink
.pw_free:
    mov rdi, [rbp - PW_BYTES]
    call obj_decref
.pw_out:
    pop rbx
    leave
    ret
END_FUNC pyc_write_cache

section .rodata
pycw_dirname:     db "__pycache__", 0
pycw_dirname_len  equ 11
; The tag is this interpreter's, not CPython's.  import.asm READS both and
; writes only this one: bytecode from our compiler under CPython's tag would
; be picked up by a python3 running in the same tree, and the sweeps in tests/
; measure apython against exactly such a shared tree.
pycw_suffix:      db ".apython-312.pyc", 0
pycw_suffix_len   equ 17

section .bss
pycw_path:  resb PYCW_PATHMAX + 64
pycw_tmp:   resb PYCW_PATHMAX + 64
pycw_hdr:   resb 16
pycw_dirlen: resq 1
pycw_len:   resq 1

section .text
