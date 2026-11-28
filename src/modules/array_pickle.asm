; array_pickle.asm - _array_reconstructor and array.array.__reduce_ex__
;
; Split from src/modules/array.asm to keep every hand-written assembly file
; under the 100 KB cap.  Implements CPython's portable pickle protocol for
; array.array across protocols 0-5 and all 22 machine format codes (0..21).

%include "macros.inc"
%include "object.inc"
%include "value.inc"

extern array_type
extern array_find_code
extern array_new_empty_type
extern array_reserve
extern array_frombytes_raw
extern array_append_value
extern array_tolist
extern array_m_tobytes

extern ap_memcpy
extern obj_decref
extern obj_incref
extern obj_as_index
extern obj_getattr_opt
extern type_is_subtype
extern str_new_heap
extern tuple_new
extern type_type
extern str_type
extern bytes_type
extern int_type
extern none_singleton
extern set_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_UnicodeDecodeError_type

section .bss
global array_reconstructor_func
global array_str___dict__
global array_module_obj
array_reconstructor_func: resq 1
array_str___dict__:       resq 1
array_module_obj:         resq 1
array_abc_registered:     resb 1

section .rodata
; Element byte width for each machine format code 0..21 (CPython enum machine_format_code)
ap_mf_size:
    db 1, 1                     ; 0: U8,  1: S8
    db 2, 2, 2, 2               ; 2..5:   U16_LE/BE, S16_LE/BE
    db 4, 4, 4, 4               ; 6..9:   U32_LE/BE, S32_LE/BE
    db 8, 8, 8, 8               ; 10..13: U64_LE/BE, S64_LE/BE
    db 4, 4                     ; 14..15: IEEE754_FLOAT_LE/BE
    db 8, 8                     ; 16..17: IEEE754_DOUBLE_LE/BE
    db 2, 2                     ; 18..19: UTF16_LE/BE
    db 4, 4                     ; 20..21: UTF32_LE/BE

; Selected native LP64 integer typecode for integer machine format codes 0..13
; Matches CPython's descriptors scan (last matching (itemsize, is_signed)).
ap_mf_int_tc:
    db 'B', 'b'                 ; 0: U8 -> B,   1: S8 -> b
    db 'H', 'H', 'h', 'h'       ; 2..3: U16 -> H, 4..5: S16 -> h
    db 'I', 'I', 'i', 'i'       ; 6..7: U32 -> I, 8..9: S32 -> i
    db 'Q', 'Q', 'q', 'q'       ; 10..11: U64 -> Q, 12..13: S64 -> q

section .text

;; ============================================================================
;; ap_typecode_to_mformat(rdi = typecode ASCII byte) -> rax = mformat (0..21) or -1
;; LP64 x86-64 little-endian native machine format codes.
;; ============================================================================
DEF_FUNC_BARE ap_typecode_to_mformat
    cmp dil, 'B'
    je .tm_0
    cmp dil, 'b'
    je .tm_1
    cmp dil, 'H'
    je .tm_2
    cmp dil, 'h'
    je .tm_4
    cmp dil, 'I'
    je .tm_6
    cmp dil, 'i'
    je .tm_8
    cmp dil, 'L'
    je .tm_10
    cmp dil, 'Q'
    je .tm_10
    cmp dil, 'l'
    je .tm_12
    cmp dil, 'q'
    je .tm_12
    cmp dil, 'f'
    je .tm_14
    cmp dil, 'd'
    je .tm_16
    cmp dil, 'u'
    je .tm_20
    mov rax, -1
    ret
.tm_0:  xor eax, eax
        ret
.tm_1:  mov eax, 1
        ret
.tm_2:  mov eax, 2
        ret
.tm_4:  mov eax, 4
        ret
.tm_6:  mov eax, 6
        ret
.tm_8:  mov eax, 8
        ret
.tm_10: mov eax, 10
        ret
.tm_12: mov eax, 12
        ret
.tm_14: mov eax, 14
        ret
.tm_16: mov eax, 16
        ret
.tm_20: mov eax, 20
        ret
END_FUNC ap_typecode_to_mformat

;; ============================================================================
;; ap_byteswap_buf(rdi = ptr, rsi = itemcount, rdx = itemsize (2, 4, or 8))
;;   -> void; swaps endianness of each scalar in place.
;; ============================================================================
DEF_FUNC_BARE ap_byteswap_buf
    test rsi, rsi
    jle .ab_done
    cmp rdx, 2
    je .ab_2
    cmp rdx, 4
    je .ab_4
    cmp rdx, 8
    je .ab_8
    ret
.ab_2:
    mov ax, [rdi]
    rol ax, 8
    mov [rdi], ax
    add rdi, 2
    dec rsi
    jnz .ab_2
    ret
.ab_4:
    mov eax, [rdi]
    bswap eax
    mov [rdi], eax
    add rdi, 4
    dec rsi
    jnz .ab_4
    ret
.ab_8:
    mov rax, [rdi]
    bswap rax
    mov [rdi], rax
    add rdi, 8
    dec rsi
    jnz .ab_8
.ab_done:
    ret
END_FUNC ap_byteswap_buf

;; ============================================================================
;; array__array_reconstructor(rdi = args, rsi = nargs) -> rax = array or 0
;; array._array_reconstructor(arraytype, typecode, mformat_code, items)
;; ============================================================================
AREC_TYPE  equ 8
AREC_TC    equ 16
AREC_DESCR equ 24
AREC_MF    equ 32
AREC_ITEMS equ 40
AREC_CNT   equ 48
AREC_SIZE  equ 56
AREC_OUT   equ 64
AREC_FRAME equ 80               ; + 2 pushes (rbx, r12) = 96, 16-aligned
global array__array_reconstructor
DEF_FUNC array__array_reconstructor, AREC_FRAME
    push rbx
    push r12
    cmp rsi, 4
    jne .arec_arity

    mov rbx, rdi                ; args

    ; arg 0: arraytype (must be a type object and subtype of array.array)
    mov rdi, [rbx]
    mov [rbp - AREC_TYPE], rdi
    V_TEST_PTR rdi, rax
    ja .arec_not_type
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel type_type]
    call type_is_subtype
    test eax, eax
    jz .arec_not_type
    mov rdi, [rbp - AREC_TYPE]
    lea rsi, [rel array_type]
    call type_is_subtype
    test eax, eax
    jz .arec_not_subtype

    ; arg 1: typecode (1-char str, must be a valid array typecode)
    mov rdi, [rbx + 8]
    V_TEST_PTR rdi, rax
    ja .arec_bad_tc_type
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .arec_tc_str
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .arec_bad_tc_type
.arec_tc_str:
    cmp qword [rdi + PyStrObject.ob_length], 1
    jne .arec_bad_tc_type
    cmp qword [rdi + PyStrObject.ob_size], 1
    jne .arec_bad_tc_val        ; non-ASCII 1-char str -> invalid code
    movzx edi, byte [rdi + PyStrObject.data]
    mov [rbp - AREC_TC], rdi
    call array_find_code
    test rax, rax
    jz .arec_bad_tc_val
    mov [rbp - AREC_DESCR], rax

    ; arg 2: mformat_code (int in 0..21; -1 / UNKNOWN_FORMAT is rejected)
    mov rdi, [rbx + 16]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .arec_fail
    cmp rax, 21
    ja .arec_bad_mf             ; unsigned ja catches both < 0 and > 21
    mov [rbp - AREC_MF], rax

    ; arg 3: items (must be bytes or bytes subclass)
    mov rdi, [rbx + 24]
    mov [rbp - AREC_ITEMS], rdi
    V_TEST_PTR rdi, rax
    ja .arec_not_bytes
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .arec_bytes_ok
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_BYTES_SUBCLASS
    jz .arec_not_bytes
.arec_bytes_ok:

    ; Fast path: native machine format for this typecode
    mov rdi, [rbp - AREC_TC]
    call ap_typecode_to_mformat
    cmp rax, [rbp - AREC_MF]
    jne .arec_slow

    mov rdi, [rbp - AREC_DESCR]
    mov rsi, [rbp - AREC_TYPE]
    call array_new_empty_type
    test rax, rax
    jz .arec_fail
    mov [rbp - AREC_OUT], rax
    mov rdi, rax
    mov rsi, [rbp - AREC_ITEMS]
    call array_frombytes_raw
    ERR_NULL .arec_drop_fail
    mov rax, [rbp - AREC_OUT]
    pop r12
    pop rbx
    leave
    ret

.arec_slow:
    ; Slow path: check items length is a multiple of mformat element size
    mov rcx, [rbp - AREC_MF]
    lea rdx, [rel ap_mf_size]
    movzx r8d, byte [rdx + rcx]
    mov [rbp - AREC_SIZE], r8
    mov rsi, [rbp - AREC_ITEMS]
    mov rax, [rsi + PyBytesObject.ob_size]
    xor edx, edx
    div r8
    test rdx, rdx
    jnz .arec_bad_len
    mov [rbp - AREC_CNT], rax

    cmp rcx, 13
    jbe .arec_int
    cmp rcx, 17
    jbe .arec_float
    jmp .arec_unicode

    ; --- Slow path A: integer machine formats (0..13) ---
.arec_int:
    lea rdx, [rel ap_mf_int_tc]
    movzx edi, byte [rdx + rcx]
    call array_find_code
    mov rdi, rax
    mov rsi, [rbp - AREC_TYPE]
    call array_new_empty_type
    test rax, rax
    jz .arec_fail
    mov [rbp - AREC_OUT], rax
    mov rsi, [rbp - AREC_CNT]
    test rsi, rsi
    jz .arec_ok
    mov rdi, rax
    call array_reserve
    ERR_NULL .arec_drop_fail
    mov rbx, [rbp - AREC_OUT]
    mov r12, [rbp - AREC_ITEMS]
    mov rdi, [rbx + PyArrayObject.ob_data]
    lea rsi, [r12 + PyBytesObject.data]
    mov rdx, [r12 + PyBytesObject.ob_size]
    call ap_memcpy
    mov rax, [rbp - AREC_CNT]
    mov [rbx + PyArrayObject.ob_size], rax
    mov rcx, [rbp - AREC_MF]
    cmp rcx, 2
    jb .arec_ok
    test rcx, 1
    jz .arec_ok
    mov rdi, [rbx + PyArrayObject.ob_data]
    mov rsi, [rbp - AREC_CNT]
    mov rdx, [rbp - AREC_SIZE]
    call ap_byteswap_buf
    jmp .arec_ok

    ; --- Slow path B: IEEE 754 float/double machine formats (14..17) ---
.arec_float:
    mov rdi, [rbp - AREC_DESCR]
    mov rsi, [rbp - AREC_TYPE]
    call array_new_empty_type
    test rax, rax
    jz .arec_fail
    mov [rbp - AREC_OUT], rax
    mov rsi, [rbp - AREC_CNT]
    test rsi, rsi
    jz .arec_ok

    ; Direct copy + optional byteswap when target typecode matches width
    mov rcx, [rbp - AREC_MF]
    mov rax, [rbp - AREC_TC]
    cmp rcx, 15
    jbe .arec_f_chk32
    cmp al, 'd'
    je .arec_f_direct
    jmp .arec_f_convert
.arec_f_chk32:
    cmp al, 'f'
    jne .arec_f_convert
.arec_f_direct:
    mov rdi, [rbp - AREC_OUT]
    mov rsi, [rbp - AREC_CNT]
    call array_reserve
    ERR_NULL .arec_drop_fail
    mov rbx, [rbp - AREC_OUT]
    mov r12, [rbp - AREC_ITEMS]
    mov rdi, [rbx + PyArrayObject.ob_data]
    lea rsi, [r12 + PyBytesObject.data]
    mov rdx, [r12 + PyBytesObject.ob_size]
    call ap_memcpy
    mov rax, [rbp - AREC_CNT]
    mov [rbx + PyArrayObject.ob_size], rax
    mov rcx, [rbp - AREC_MF]
    test rcx, 1
    jz .arec_ok
    mov rdi, [rbx + PyArrayObject.ob_data]
    mov rsi, [rbp - AREC_CNT]
    mov rdx, [rbp - AREC_SIZE]
    call ap_byteswap_buf
    jmp .arec_ok

.arec_f_convert:
    ; Cross-type float decode (e.g. float32 -> 'd' or float64 -> 'f')
    mov r12, [rbp - AREC_ITEMS]
    lea r12, [r12 + PyBytesObject.data]
    xor ebx, ebx
.arec_fc_loop:
    cmp rbx, [rbp - AREC_CNT]
    jge .arec_ok
    mov rcx, [rbp - AREC_MF]
    cmp rcx, 15
    ja .arec_fc_64
    mov eax, [r12 + rbx * 4]
    test rcx, 1
    jz .arec_fc_32_le
    bswap eax
.arec_fc_32_le:
    movd xmm0, eax
    cvtss2sd xmm0, xmm0
    movq rax, xmm0
    jmp .arec_fc_append
.arec_fc_64:
    mov rax, [r12 + rbx * 8]
    test rcx, 1
    jz .arec_fc_append
    bswap rax
.arec_fc_append:
    mov edx, TAG_FLOAT
    V_PACK rax, rdx
    mov rdi, [rbp - AREC_OUT]
    mov rsi, rax
    call array_append_value
    ERR_NULL .arec_drop_fail
    inc rbx
    jmp .arec_fc_loop

    ; --- Slow path C: UTF-16 / UTF-32 machine formats (18..21) ---
.arec_unicode:
    cmp qword [rbp - AREC_TC], 'u'
    jne .arec_bad_u_tc
    mov rdi, [rbp - AREC_DESCR]
    mov rsi, [rbp - AREC_TYPE]
    call array_new_empty_type
    test rax, rax
    jz .arec_fail
    mov [rbp - AREC_OUT], rax
    mov rsi, [rbp - AREC_CNT]
    test rsi, rsi
    jz .arec_ok
    mov rdi, rax
    call array_reserve
    ERR_NULL .arec_drop_fail

    mov rbx, [rbp - AREC_OUT]
    mov rdi, [rbx + PyArrayObject.ob_data]
    mov r12, [rbp - AREC_ITEMS]
    lea rsi, [r12 + PyBytesObject.data]
    mov r8, [rbp - AREC_CNT]
    mov rcx, [rbp - AREC_MF]
    cmp rcx, 20
    jae .arec_utf32

    ; UTF-16 LE (18) or BE (19) -> uint32 codepoints
    xor r9d, r9d                ; input unit index
    xor r10d, r10d              ; output codepoint count
.arec_u16_loop:
    cmp r9, r8
    jge .arec_u_done
    movzx eax, word [rsi + r9 * 2]
    test rcx, 1
    jz .arec_u16_w1
    rol ax, 8
.arec_u16_w1:
    inc r9
    cmp eax, 0xD800
    jb .arec_u16_store
    cmp eax, 0xDBFF
    ja .arec_u16_chk_lo
    ; High surrogate: require following low surrogate
    cmp r9, r8
    jge .arec_u_bad
    movzx edx, word [rsi + r9 * 2]
    test rcx, 1
    jz .arec_u16_w2
    rol dx, 8
.arec_u16_w2:
    inc r9
    cmp edx, 0xDC00
    jb .arec_u_bad
    cmp edx, 0xDFFF
    ja .arec_u_bad
    sub eax, 0xD800
    shl eax, 10
    sub edx, 0xDC00
    add eax, edx
    add eax, 0x10000
    jmp .arec_u16_store
.arec_u16_chk_lo:
    cmp eax, 0xDFFF
    jbe .arec_u_bad             ; unpaired low surrogate
.arec_u16_store:
    mov [rdi + r10 * 4], eax
    inc r10
    jmp .arec_u16_loop

.arec_utf32:
    ; UTF-32 LE (20) or BE (21) -> uint32 codepoints
    xor r10d, r10d
.arec_u32_loop:
    cmp r10, r8
    jge .arec_u_done
    mov eax, [rsi + r10 * 4]
    test rcx, 1
    jz .arec_u32_chk
    bswap eax
.arec_u32_chk:
    cmp eax, 0x10FFFF
    ja .arec_u_bad
    mov edx, eax
    and edx, 0xF800
    cmp edx, 0xD800
    je .arec_u_bad
    mov [rdi + r10 * 4], eax
    inc r10
    jmp .arec_u32_loop

.arec_u_done:
    mov [rbx + PyArrayObject.ob_size], r10
.arec_ok:
    mov rax, [rbp - AREC_OUT]
    pop r12
    pop rbx
    leave
    ret

.arec_u_bad:
    SET_EXC exc_UnicodeDecodeError_type, "invalid unicode data in _array_reconstructor"
.arec_drop_fail:
    mov rdi, [rbp - AREC_OUT]
    call obj_decref
.arec_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
.arec_arity:
    FAIL exc_TypeError_type, "_array_reconstructor() takes exactly 4 arguments", .arec_fail
.arec_not_type:
    FAIL exc_TypeError_type, "first argument must be a type object", .arec_fail
.arec_not_subtype:
    FAIL exc_TypeError_type, "first argument is not a subtype of array.array", .arec_fail
.arec_bad_tc_type:
    FAIL exc_TypeError_type, "second argument must be a unicode character", .arec_fail
.arec_bad_tc_val:
    FAIL exc_ValueError_type, "second argument must be a valid type code", .arec_fail
.arec_bad_mf:
    FAIL exc_ValueError_type, "third argument must be a valid machine format code.", .arec_fail
.arec_not_bytes:
    FAIL exc_TypeError_type, "fourth argument should be bytes", .arec_fail
.arec_bad_len:
    FAIL exc_ValueError_type, "string length not a multiple of item size", .arec_fail
.arec_bad_u_tc:
    FAIL exc_TypeError_type, "cannot use a str to initialize an array with non-'u' typecode", .arec_fail
END_FUNC array__array_reconstructor

;; ============================================================================
;; array_m_reduce_ex(rdi = args, rsi = nargs) -> rax = 3-tuple or 0
;; a.__reduce_ex__(protocol):
;;   protocol < 3  -> (type(self), (typecode, self.tolist()), dict_or_None)
;;   protocol >= 3 -> (_array_reconstructor, (type(self), typecode, mformat,
;;                     self.tobytes()), dict_or_None)
;; ============================================================================
ARE_SELF  equ 8
ARE_PROTO equ 16
ARE_DICT  equ 24
ARE_TCSTR equ 32
ARE_PAYLOAD equ 40
ARE_ARGS  equ 48
ARE_OUT   equ 56
ARE_CH    equ 64
ARE_FRAME equ 72                ; + 1 push (rbx) = 80, 16-aligned
global array_m_reduce_ex
DEF_FUNC array_m_reduce_ex, ARE_FRAME
    push rbx
    cmp rsi, 2
    jne .are_arity
    mov rbx, [rdi]
    mov [rbp - ARE_SELF], rbx
    mov qword [rbp - ARE_DICT], 0
    mov qword [rbp - ARE_TCSTR], 0
    mov qword [rbp - ARE_PAYLOAD], 0
    mov qword [rbp - ARE_ARGS], 0

    ; Validate protocol is an int (or int subclass, including bool)
    mov rdi, [rdi + 8]
    V_IS_INT rdi, rax
    jae .are_proto_int
    V_TEST_PTR rdi, rax
    ja .are_bad_proto
    push rdi
    sub rsp, 8
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel int_type]
    call type_is_subtype
    add rsp, 8
    pop rdi
    test eax, eax
    jz .are_bad_proto
.are_proto_int:
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .are_fail
    mov [rbp - ARE_PROTO], rax

    ; Fetch self.__dict__ (or None if absent)
    mov rdi, rbx
    mov rsi, [rel array_str___dict__]
    call obj_getattr_opt
    test rax, rax
    jnz .are_have_dict
    cmp qword [gs:ThreadState.current_exception], 0
    jne .are_fail
    lea rax, [rel none_singleton]
    INCREF rax
.are_have_dict:
    mov [rbp - ARE_DICT], rax

    ; Build 1-char typecode str
    mov al, byte [rbx + PyArrayObject.ob_code]
    mov [rbp - ARE_CH], al
    lea rdi, [rbp - ARE_CH]
    mov esi, 1
    call str_new_heap
    test rax, rax
    jz .are_drop_fail
    mov [rbp - ARE_TCSTR], rax

    cmp qword [rbp - ARE_PROTO], 3
    jl .are_proto_old

    ; Protocol >= 3: (_array_reconstructor, (type(self), tc, mf, tobytes), dict)
    lea rdi, [rbp - ARE_SELF]
    mov esi, 1
    call array_m_tobytes        ; err: checked via test rax, rax below
    test rax, rax
    jz .are_drop_fail
    mov [rbp - ARE_PAYLOAD], rax

    mov edi, 4
    call tuple_new
    test rax, rax
    jz .are_drop_fail
    mov [rbp - ARE_ARGS], rax
    mov rcx, [rax + PyTupleObject.ob_item]

    mov rdx, [rbx + PyObject.ob_type]
    INCREF rdx
    mov [rcx], rdx
    mov rdx, [rbp - ARE_TCSTR]
    mov qword [rbp - ARE_TCSTR], 0
    mov [rcx + 8], rdx

    mov rdi, [rbx + PyArrayObject.ob_code]
    call ap_typecode_to_mformat
    V_PACK_I64 rax, r8
    mov rdx, [rbp - ARE_ARGS]
    mov rcx, [rdx + PyTupleObject.ob_item]
    mov [rcx + 16], rax
    mov rdx, [rbp - ARE_PAYLOAD]
    mov qword [rbp - ARE_PAYLOAD], 0
    mov [rcx + 24], rdx

    mov edi, 3
    call tuple_new
    test rax, rax
    jz .are_drop_fail
    mov [rbp - ARE_OUT], rax
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rel array_reconstructor_func]
    INCREF rdx
    mov [rcx], rdx
    mov rdx, [rbp - ARE_ARGS]
    mov [rcx + 8], rdx
    mov rdx, [rbp - ARE_DICT]
    mov [rcx + 16], rdx
    pop rbx
    leave
    ret

.are_proto_old:
    ; Protocol < 3: (type(self), (tc, tolist), dict)
    mov rdi, rbx
    call array_tolist
    ERR_NULL .are_drop_fail
    mov [rbp - ARE_PAYLOAD], rax

    mov edi, 2
    call tuple_new
    test rax, rax
    jz .are_drop_fail
    mov [rbp - ARE_ARGS], rax
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbp - ARE_TCSTR]
    mov qword [rbp - ARE_TCSTR], 0
    mov [rcx], rdx
    mov rdx, [rbp - ARE_PAYLOAD]
    mov qword [rbp - ARE_PAYLOAD], 0
    mov [rcx + 8], rdx

    mov edi, 3
    call tuple_new
    test rax, rax
    jz .are_drop_fail
    mov [rbp - ARE_OUT], rax
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbx + PyObject.ob_type]
    INCREF rdx
    mov [rcx], rdx
    mov rdx, [rbp - ARE_ARGS]
    mov [rcx + 8], rdx
    mov rdx, [rbp - ARE_DICT]
    mov [rcx + 16], rdx
    pop rbx
    leave
    ret

.are_drop_fail:
    mov rdi, [rbp - ARE_ARGS]
    test rdi, rdi
    jz .are_d1
    call obj_decref
.are_d1:
    mov rdi, [rbp - ARE_PAYLOAD]
    test rdi, rdi
    jz .are_d2
    call obj_decref
.are_d2:
    mov rdi, [rbp - ARE_TCSTR]
    test rdi, rdi
    jz .are_d3
    call obj_decref
.are_d3:
    mov rdi, [rbp - ARE_DICT]
    test rdi, rdi
    jz .are_fail
    call obj_decref
.are_fail:
    xor eax, eax
    pop rbx
    leave
    ret
.are_arity:
    FAIL exc_TypeError_type, "__reduce_ex__() takes exactly one argument", .are_fail
.are_bad_proto:
    FAIL exc_TypeError_type, "__reduce_ex__ argument should be an integer", .are_fail
END_FUNC array_m_reduce_ex

;; ============================================================================
;; array_register_abc() -> void
;; Registers array.array with _collections_abc.MutableSequence (matching
;; CPython's array_modexec in Modules/arraymodule.c).  Silently clears any
;; ImportError if stdlib is unavailable.
;; ============================================================================
ARA_MOD   equ 8
ARA_ABC   equ 16
ARA_REG   equ 24
ARA_ARG   equ 32
ARA_NAME  equ 40
ARA_FRAME equ 48                ; 0 pushes, 16-aligned
extern import_module
extern str_from_cstr_heap
extern obj_call_n
global array_register_abc
DEF_FUNC array_register_abc, ARA_FRAME
    cmp byte [rel array_abc_registered], 0
    jne .ara_done
    mov byte [rel array_abc_registered], 1
    mov qword [rbp - ARA_MOD], 0
    mov qword [rbp - ARA_ABC], 0
    mov qword [rbp - ARA_REG], 0

    CSTRING rdi, "_collections_abc"
    call str_from_cstr_heap
    test rax, rax
    jz .ara_done
    mov [rbp - ARA_NAME], rax
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call import_module          ; err: cleared below if stdlib absent
    mov [rbp - ARA_MOD], rax
    mov rdi, [rbp - ARA_NAME]
    call obj_decref
    mov rax, [rbp - ARA_MOD]
    test rax, rax
    jz .ara_clear_exc

    CSTRING rdi, "MutableSequence"
    call str_from_cstr_heap
    test rax, rax
    jz .ara_cleanup
    mov [rbp - ARA_NAME], rax
    mov rdi, [rbp - ARA_MOD]
    mov rsi, rax
    call obj_getattr_opt
    mov [rbp - ARA_ABC], rax
    mov rdi, [rbp - ARA_NAME]
    call obj_decref
    mov rax, [rbp - ARA_ABC]
    test rax, rax
    jz .ara_clear_exc

    CSTRING rdi, "register"
    call str_from_cstr_heap
    test rax, rax
    jz .ara_cleanup
    mov [rbp - ARA_NAME], rax
    mov rdi, [rbp - ARA_ABC]
    mov rsi, rax
    call obj_getattr_opt
    mov [rbp - ARA_REG], rax
    mov rdi, [rbp - ARA_NAME]
    call obj_decref
    mov rax, [rbp - ARA_REG]
    test rax, rax
    jz .ara_clear_exc

    lea rcx, [rel array_type]
    mov [rbp - ARA_ARG], rcx
    mov rdi, rax
    lea rsi, [rbp - ARA_ARG]
    mov edx, 1
    call obj_call_n             ; err: cleared below if failed
    test rax, rax
    jz .ara_clear_exc
    mov rdi, rax
    DECREF_V rdi, rcx
    jmp .ara_cleanup

.ara_clear_exc:
    mov byte [rel array_abc_registered], 0
    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jz .ara_cleanup
    mov qword [gs:ThreadState.current_exception], 0
    mov rdi, rax
    call obj_decref
.ara_cleanup:
    mov rdi, [rbp - ARA_REG]
    test rdi, rdi
    jz .ara_c1
    DECREF_V rdi, rcx
.ara_c1:
    mov rdi, [rbp - ARA_ABC]
    test rdi, rdi
    jz .ara_c2
    DECREF_V rdi, rcx
.ara_c2:
    mov rdi, [rbp - ARA_MOD]
    test rdi, rdi
    jz .ara_done
    call obj_decref
.ara_done:
    leave
    ret
END_FUNC array_register_abc
