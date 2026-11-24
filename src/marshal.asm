; marshal.asm - Read Python marshal format from buffer
; Implements the marshal deserialization protocol for .pyc files

%include "macros.inc"
%include "object.inc"
%include "threadstate.inc"
%include "opcodes.inc"

;; ============================================================================
;; The marshal type codes and .pyc header constants
;; (was include/marshal.inc)
;; ============================================================================

; Marshal type codes (from CPython Python/marshal.c)
MARSHAL_TYPE_NULL             equ 0x30  ; '0'
MARSHAL_TYPE_NONE             equ 0x4e  ; 'N'
MARSHAL_TYPE_FALSE            equ 0x46  ; 'F'
MARSHAL_TYPE_TRUE             equ 0x54  ; 'T'
MARSHAL_TYPE_STOPITER         equ 0x53  ; 'S'
MARSHAL_TYPE_ELLIPSIS         equ 0x2e  ; '.'
MARSHAL_TYPE_INT              equ 0x69  ; 'i'
MARSHAL_TYPE_INT64            equ 0x49  ; 'I'
MARSHAL_TYPE_BINARY_FLOAT     equ 0x67  ; 'g'
MARSHAL_TYPE_BINARY_COMPLEX   equ 0x79  ; 'y'
MARSHAL_TYPE_LONG             equ 0x6c  ; 'l'
MARSHAL_TYPE_STRING           equ 0x73  ; 's'
MARSHAL_TYPE_INTERNED         equ 0x74  ; 't'
MARSHAL_TYPE_REF              equ 0x72  ; 'r'
MARSHAL_TYPE_TUPLE            equ 0x28  ; '('
MARSHAL_TYPE_CODE             equ 0x63  ; 'c'
; The most slots a frame will be built for.  frame_new adds co_nlocalsplus and
; co_stacksize in 32 bits, so a crafted pair near 2^31 wrapped to a small
; total and the frame came out far too short; the value stack then ran off the
; end of it.  No compiler produces a million of either.
MARSHAL_MAX_SLOTS             equ 1000000
MARSHAL_TYPE_UNICODE          equ 0x75  ; 'u'
MARSHAL_TYPE_SET              equ 0x3c  ; '<'
; A .pyc never holds a mutable constant, so the reader did not need these
; until `marshal` became a module a program can call.
MARSHAL_TYPE_LIST             equ 0x5b  ; '['
MARSHAL_TYPE_DICT             equ 0x7b  ; '{'
MARSHAL_TYPE_FROZENSET        equ 0x3e  ; '>'
MARSHAL_TYPE_ASCII            equ 0x61  ; 'a'
MARSHAL_TYPE_ASCII_INTERNED   equ 0x41  ; 'A'
MARSHAL_TYPE_SMALL_TUPLE      equ 0x29  ; ')'
MARSHAL_TYPE_SHORT_ASCII      equ 0x7a  ; 'z'
MARSHAL_TYPE_SHORT_ASCII_INTERNED equ 0x5a ; 'Z'

; Flag to indicate object should be added to reference list
MARSHAL_FLAG_REF              equ 0x80

; .pyc file header
PYC_MAGIC_3_12    equ 0x0a0d0dcb  ; 3531 in little-endian with \r\n
PYC_HEADER_SIZE   equ 16          ; magic(4) + flags(4) + timestamp/size(8)
extern str_intern_bytes
extern int_promote_mpz
extern none_singleton
extern bool_true
extern bool_false
extern int_from_i64
extern str_new_heap
extern tuple_new
extern bytes_from_data
extern ap_malloc
extern gc_alloc
extern ap_free
extern str_type
extern bytes_type
extern tuple_type
extern obj_dealloc
extern ap_realloc
extern __gmpz_init
extern int_type
extern fatal_error
extern ap_memcpy
extern code_type
extern obj_decref
extern obj_incref

; Initial capacity for the reference list
MARSHAL_REFS_INIT_CAP equ 64

; What marshal_error holds.
MARSHAL_ERR_NONE equ 0
MARSHAL_ERR_EOF  equ 1          ; the stream stopped early: EOFError
MARSHAL_ERR_BAD  equ 2          ; it says something impossible: ValueError
MARSHAL_ERR_OBJ  equ 3          ; it stopped where an object was due: EOFError

; How much machine stack a nested read is allowed to reach down into.  The
; reader recurses once per level of nesting and a stream can nest as deeply as
; it likes, so `marshal.loads(b"(\x01\x00\x00\x00" * 200000)` walked the C
; stack off its end.  Measuring rsp against a floor set by the entry point
; costs one compare per object and needs no counter to keep balanced across
; the handlers' several exits.
MARSHAL_STACK_ROOM equ 1024 * 1024

;; ============================================================================
;; marshal_fail(rdi = the fatal message, esi = MARSHAL_ERR_*) -> rax = 0
;;
;; A .pyc is read before there is an interpreter frame to raise into, so a
;; malformed one is fatal and always was.  marshal.loads() is different: it is
;; an ordinary call inside a running program, handed bytes that program chose,
;; and CPython answers it with EOFError or ValueError.  It sets marshal_soft,
;; and then every refusal in this file records itself here and unwinds instead
;; of taking the process down.
;;
;; The first failure is the one kept: everything after it is the reader
;; reading zeros on its way out.
;; ============================================================================
DEF_FUNC_LOCAL marshal_fail
    cmp qword [gs:ThreadState.marshal_soft], 0
    je .mf_fatal
    cmp qword [gs:ThreadState.marshal_error], MARSHAL_ERR_NONE
    jne .mf_done
    movsx rsi, esi
    mov [gs:ThreadState.marshal_error], rsi
.mf_done:
    xor eax, eax
    xor edx, edx
    leave
    ret
.mf_fatal:
    call fatal_error
END_FUNC marshal_fail

;; ============================================================================
;; marshal_read_byte() -> byte in al
;; Read one byte from marshal_buf[marshal_pos], increment marshal_pos.
;; ============================================================================
DEF_FUNC marshal_read_byte

    mov rax, [gs:ThreadState.marshal_pos]
    cmp rax, [gs:ThreadState.marshal_len]
    jge mread_byte_eof

    mov rcx, [gs:ThreadState.marshal_buf]
    movzx eax, byte [rcx + rax]
    inc qword [gs:ThreadState.marshal_pos]

    leave
    ret
END_FUNC marshal_read_byte

mread_byte_eof:
    lea rdi, [rel marshal_err_eof]
    mov esi, MARSHAL_ERR_EOF
    call marshal_fail
    xor eax, eax
    leave
    ret

;; ============================================================================
;; marshal_read_long() -> int32 in eax
;; Read 4 bytes little-endian from buffer.
;; ============================================================================
DEF_FUNC marshal_read_long

    mov rax, [gs:ThreadState.marshal_pos]
    lea rcx, [rax + 4]
    cmp rcx, [gs:ThreadState.marshal_len]
    jg mread_long_eof

    mov rcx, [gs:ThreadState.marshal_buf]
    mov eax, [rcx + rax]       ; little-endian read (x86 native)
    add qword [gs:ThreadState.marshal_pos], 4

    leave
    ret
END_FUNC marshal_read_long

mread_long_eof:
    lea rdi, [rel marshal_err_eof]
    mov esi, MARSHAL_ERR_EOF
    call marshal_fail
    xor eax, eax
    leave
    ret

;; ============================================================================
;; marshal_read_long64() -> int64 in rax
;; Read 8 bytes little-endian from buffer.
;; ============================================================================
DEF_FUNC marshal_read_long64

    mov rax, [gs:ThreadState.marshal_pos]
    lea rcx, [rax + 8]
    cmp rcx, [gs:ThreadState.marshal_len]
    jg mread_long64_eof

    mov rcx, [gs:ThreadState.marshal_buf]
    mov rax, [rcx + rax]       ; little-endian read (x86 native)
    add qword [gs:ThreadState.marshal_pos], 8

    leave
    ret
END_FUNC marshal_read_long64

mread_long64_eof:
    lea rdi, [rel marshal_err_eof]
    mov esi, MARSHAL_ERR_EOF
    call marshal_fail
    xor eax, eax
    leave
    ret

;; ============================================================================
;; marshal_read_bytes(int64_t n) -> pointer to bytes in buffer (rax)
;; Returns pointer to current position in buffer, advances pos by n.
;; ============================================================================
DEF_FUNC marshal_read_bytes

    mov rsi, rdi               ; rsi = n
    mov rax, [gs:ThreadState.marshal_pos]
    lea rcx, [rax + rsi]
    cmp rcx, [gs:ThreadState.marshal_len]
    jg mread_bytes_eof

    mov rcx, [gs:ThreadState.marshal_buf]
    lea rax, [rcx + rax]       ; rax = &buf[pos]
    add [gs:ThreadState.marshal_pos], rsi

    leave
    ret
END_FUNC marshal_read_bytes

mread_bytes_eof:
    lea rdi, [rel marshal_err_eof]
    mov esi, MARSHAL_ERR_EOF
    call marshal_fail
    xor eax, eax
    leave
    ret

;; ============================================================================
;; marshal_init_refs() - Initialize the reference list
;; ============================================================================
DEF_FUNC marshal_init_refs

    mov qword [gs:ThreadState.marshal_ref_count], 0

    ; Check if already allocated with sufficient capacity
    cmp qword [gs:ThreadState.marshal_ref_cap], 0
    jne .already_allocated

    ; Allocate the initial ref array (one Value per entry)
    mov rdi, MARSHAL_REFS_INIT_CAP * 8
    call ap_malloc
    mov [gs:ThreadState.marshal_refs], rax
    mov qword [gs:ThreadState.marshal_ref_cap], MARSHAL_REFS_INIT_CAP

.already_allocated:
    leave
    ret
END_FUNC marshal_init_refs

;; ============================================================================
;; marshal_add_ref(rdi=payload, rsi=tag) - Add fat value to reference list
;; ============================================================================
DEF_FUNC marshal_add_ref
    push rbx
    push r12

    mov rbx, rdi               ; rbx = payload
    mov r12, rsi               ; r12 = tag

    ; Check if we need to grow
    mov rax, [gs:ThreadState.marshal_ref_count]
    cmp rax, [gs:ThreadState.marshal_ref_cap]
    jl .store

    ; Grow: double the capacity
    mov rdi, [gs:ThreadState.marshal_refs]
    mov rax, [gs:ThreadState.marshal_ref_cap]
    shl rax, 1                 ; new_cap = old_cap * 2
    mov [gs:ThreadState.marshal_ref_cap], rax
    mov rsi, rax
    shl rsi, 3                 ; new_cap * 8
    call ap_realloc
    mov [gs:ThreadState.marshal_refs], rax

.store:
    ; The refs array takes ownership — INCREF, then pack and store
    INCREF_VAL rbx, r12
    V_PACK rbx, r12
    mov rax, [gs:ThreadState.marshal_ref_count]
    mov rcx, [gs:ThreadState.marshal_refs]
    mov [rcx + rax*8], rbx
    inc rax
    mov [gs:ThreadState.marshal_ref_count], rax

    pop r12
    pop rbx
    leave
    ret
END_FUNC marshal_add_ref

;; ============================================================================
;; marshal_cleanup_refs() - DECREF all refs and reset count
;; Called after marshal_read_object completes to release refs array ownership.
;; ============================================================================
DEF_FUNC marshal_cleanup_refs, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    push r12
    push r13

    mov r13, [gs:ThreadState.marshal_ref_count]
    test r13, r13
    jz .cleanup_done

    mov rbx, [gs:ThreadState.marshal_refs]
    xor r12d, r12d             ; index
.cleanup_loop:
    cmp r12, r13
    jge .cleanup_done
    mov rdi, [rbx + r12*8]
    DECREF_V rdi, rsi
    inc r12
    jmp .cleanup_loop
.cleanup_done:
    mov qword [gs:ThreadState.marshal_ref_count], 0
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC marshal_cleanup_refs

;; ============================================================================
;; marshal_count_ok(rdi = a container's element count) -> rax = that count, or
;; 0 with a refusal recorded
;;
;; Every object in the stream is at least one byte, so a container claiming
;; more elements than there are bytes left is claiming something the stream
;; cannot hold.  Without this a count of 0xFFFFFFFF asked list_new for four
;; billion slots before reading the first element, and a refusal recorded
;; part way through left the arm's loop counting down from four billion.
;; ============================================================================
DEF_FUNC_LOCAL marshal_count_ok
    mov rax, [gs:ThreadState.marshal_len]
    sub rax, [gs:ThreadState.marshal_pos]
    cmp rdi, rax
    ja .mco_short
    mov rax, rdi
    leave
    ret
.mco_short:
    lea rdi, [rel marshal_err_eof]
    mov esi, MARSHAL_ERR_EOF
    call marshal_fail
    xor eax, eax
    leave
    ret
END_FUNC marshal_count_ok

;; ============================================================================
;; marshal_read_object() -> rax = Value
;; Main marshal deserialization dispatcher.
;;
;; Register convention within this function and its handlers:
;; rbx = type code (without FLAG_REF)
;; r12 = FLAG_REF indicator (0 or 1)
;; Both are callee-saved and pushed in the prologue.
;; ============================================================================
DEF_FUNC marshal_read_object
    push rbx
    push r12

    ; A failure already recorded: unwind without reading anything more.  The
    ; handlers below go on calling this for their children, and they have to
    ; get an answer rather than a second refusal.
    cmp qword [gs:ThreadState.marshal_error], MARSHAL_ERR_NONE
    jne mdo_soft_fail

    ; And the machine stack, which nesting is what spends.  The floor is set
    ; by whichever entry point is reading; zero, meaning nobody set one, is
    ; below every real rsp and so never fires.
    cmp rsp, [gs:ThreadState.marshal_rsp_floor]
    jb mdo_too_deep

    ; Read type byte.  Nothing was recorded before this read -- the guard
    ; above saw to that -- so if something is now, this read is what stopped,
    ; and CPython words that one case differently.
    call marshal_read_byte
    cmp qword [gs:ThreadState.marshal_error], MARSHAL_ERR_EOF
    je mdo_eof_at_object
    cmp qword [gs:ThreadState.marshal_error], MARSHAL_ERR_NONE
    jne mdo_soft_fail
    movzx eax, al
    mov ebx, eax               ; ebx = full type byte

    ; Check FLAG_REF
    xor r12d, r12d             ; r12 = 0 means no FLAG_REF
    test ebx, MARSHAL_FLAG_REF
    jz .no_flag_ref
    mov r12d, 1                ; r12 = 1 means FLAG_REF set
    and ebx, ~MARSHAL_FLAG_REF ; strip the flag bit
.no_flag_ref:

    ; Dispatch on type code (ebx = type without FLAG_REF)
    cmp ebx, MARSHAL_TYPE_NONE
    je mdo_none
    cmp ebx, MARSHAL_TYPE_TRUE
    je mdo_true
    cmp ebx, MARSHAL_TYPE_FALSE
    je mdo_false
    cmp ebx, MARSHAL_TYPE_INT
    je mdo_int
    cmp ebx, MARSHAL_TYPE_INT64
    je mdo_int64
    cmp ebx, MARSHAL_TYPE_LONG
    je mdo_long
    cmp ebx, MARSHAL_TYPE_BINARY_FLOAT
    je mdo_binary_float
    cmp ebx, MARSHAL_TYPE_BINARY_COMPLEX
    je mdo_binary_complex
    cmp ebx, MARSHAL_TYPE_SHORT_ASCII
    je mdo_short_ascii
    cmp ebx, MARSHAL_TYPE_SHORT_ASCII_INTERNED
    je mdo_short_ascii
    cmp ebx, MARSHAL_TYPE_ASCII
    je mdo_ascii
    cmp ebx, MARSHAL_TYPE_ASCII_INTERNED
    je mdo_ascii
    cmp ebx, MARSHAL_TYPE_UNICODE
    je mdo_unicode
    cmp ebx, MARSHAL_TYPE_STRING
    je mdo_bytes
    ; TYPE_INTERNED is a *str* that happened to be interned when it was
    ; written, not a byte string -- CPython's reader falls it through to
    ; TYPE_UNICODE.  It was decoded as bytes here, so every non-ASCII
    ; identifier came out of a .pyc as bytes.  Which strings are interned
    ; varies between CPython patch releases, so the same source could work
    ; on one machine and not another.
    cmp ebx, MARSHAL_TYPE_INTERNED
    je mdo_unicode
    cmp ebx, MARSHAL_TYPE_SMALL_TUPLE
    je mdo_small_tuple
    cmp ebx, MARSHAL_TYPE_TUPLE
    je mdo_tuple
    cmp ebx, MARSHAL_TYPE_REF
    je mdo_ref
    cmp ebx, MARSHAL_TYPE_CODE
    je mdo_code
    cmp ebx, MARSHAL_TYPE_STOPITER
    je mdo_none                 ; stub: return None
    cmp ebx, MARSHAL_TYPE_ELLIPSIS
    je mdo_ellipsis
    cmp ebx, MARSHAL_TYPE_NULL
    je mdo_null
    cmp ebx, MARSHAL_TYPE_FROZENSET
    je mdo_frozenset
    cmp ebx, MARSHAL_TYPE_SET
    je mdo_set
    cmp ebx, MARSHAL_TYPE_LIST
    je mdo_list
    cmp ebx, MARSHAL_TYPE_DICT
    je mdo_dict

    ; Unknown type
    lea rdi, [rel marshal_err_unknown]
    mov esi, MARSHAL_ERR_BAD
    call marshal_fail
    jmp mdo_soft_fail

;--------------------------------------------------------------------------
; mfinish: common epilogue for marshal_read_object
; rax = the result payload, rdx = tag, r12 = FLAG_REF flag
;--------------------------------------------------------------------------
; The way out for a refusal that has already been recorded: no result, and
; nothing of this object's to release, because nothing of it was built.
mdo_soft_fail:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret

mdo_eof_at_object:
    mov qword [gs:ThreadState.marshal_error], MARSHAL_ERR_OBJ
    jmp mdo_soft_fail

mdo_too_deep:
    lea rdi, [rel marshal_err_deep]
    mov esi, MARSHAL_ERR_BAD
    call marshal_fail
    jmp mdo_soft_fail

; The four length-then-bytes arms, which push r12 and r13 of their own before
; the length can fail to be there.
mdo_str_fail:
    pop r13
    pop r12
    jmp mdo_soft_fail

mfinish:
    ; If FLAG_REF was set, add to reference list
    test r12d, r12d
    jz .no_add_ref
    push rdx                   ; save tag
    push rax                   ; save payload
    mov rdi, rax               ; payload
    mov rsi, rdx               ; tag
    call marshal_add_ref
    pop rax
    pop rdx                    ; restore tag
.no_add_ref:
    pop r12
    pop rbx
    leave
    ret

;--------------------------------------------------------------------------
; TYPE_NONE handler
;--------------------------------------------------------------------------
mdo_none:
    xor eax, eax
    RET_NONE
    jmp mfinish

;--------------------------------------------------------------------------
; TYPE_ELLIPSIS handler
;--------------------------------------------------------------------------
mdo_ellipsis:
    extern ellipsis_singleton
    lea rax, [rel ellipsis_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    jmp mfinish

;--------------------------------------------------------------------------
; TYPE_TRUE handler
;--------------------------------------------------------------------------
mdo_true:
    lea rax, [rel bool_true]
    mov edx, TAG_PTR
    jmp mfinish

;--------------------------------------------------------------------------
; TYPE_FALSE handler
;--------------------------------------------------------------------------
mdo_false:
    lea rax, [rel bool_false]
    mov edx, TAG_PTR
    jmp mfinish

;--------------------------------------------------------------------------
; TYPE_NULL handler - return NULL pointer
;--------------------------------------------------------------------------
mdo_null:
    RET_NULL
    jmp mfinish

;--------------------------------------------------------------------------
; TYPE_INT handler: read 4-byte signed int, create int object
;--------------------------------------------------------------------------
mdo_int:
    call marshal_read_long
    movsx rdi, eax             ; sign-extend to 64-bit
    call int_from_i64
    jmp mfinish

;--------------------------------------------------------------------------
; TYPE_INT64 handler: read 8-byte signed int, create int object
;--------------------------------------------------------------------------
mdo_int64:
    call marshal_read_long64
    mov rdi, rax
    call int_from_i64
    jmp mfinish

;--------------------------------------------------------------------------
; TYPE_LONG handler: read marshal multi-precision integer
; Format: ndigits (signed int32), then |ndigits| 16-bit "digits"
; Each digit is a base-2^15 digit. Sign from ndigits sign.
;--------------------------------------------------------------------------
mdo_long:
    push r13
    push r14
    push r15
    ; 24, not the 16 the two slots need: three pushes and 16 leave rsp eight
    ; bytes out of 16-alignment, and this arm calls into GMP.
    sub rsp, 24                ; [rsp+0] = digit index, [rsp+8] = shift amount

    call marshal_read_long     ; eax = ndigits (signed)
    movsx r13, eax             ; r13 = ndigits (sign-extended)

    ; Compute absolute digit count
    mov r14, r13
    test r14, r14
    jns .long_pos
    neg r14                    ; r14 = |ndigits|
.long_pos:
    ; Two bytes a digit, so that many bytes have to be there.  Zero on
    ; refusal, which is a digit loop that does not run.
    lea rdi, [r14 + r14]
    call marshal_count_ok
    shr rax, 1
    mov r14, rax

    ; If |ndigits| > 4, use GMP path (>60 bits, may overflow int64)
    cmp r14, 4
    ja .long_gmp_path

    ; Small value: reconstruct into int64
    xor r15d, r15d             ; r15 = accumulated value
    mov qword [rsp + 0], 0    ; digit index = 0
    mov qword [rsp + 8], 0    ; shift amount = 0

.long_digit_loop:
    mov rax, [rsp + 0]
    cmp rax, r14
    jge .long_digits_done

    ; Read one 16-bit digit (2 bytes, little-endian)
    call marshal_read_byte     ; low byte
    movzx r8d, al
    call marshal_read_byte     ; high byte
    movzx eax, al
    shl eax, 8
    or r8d, eax               ; r8d = 16-bit digit value

    ; Accumulate: value |= (uint64_t)digit << shift
    mov rax, r8
    mov rcx, [rsp + 8]        ; shift amount in rcx (cl used by shl)
    shl rax, cl
    or r15, rax

    ; Advance
    add qword [rsp + 8], 15   ; shift += 15
    inc qword [rsp + 0]       ; index++
    jmp .long_digit_loop

.long_digits_done:
    ; Apply sign
    test r13, r13
    jns .long_not_neg
    neg r15
.long_not_neg:

    ; Create int object
    mov rdi, r15
    call int_from_i64

    add rsp, 24
    pop r15
    pop r14
    pop r13
    jmp mfinish

; GMP path for large TYPE_LONG values (|ndigits| > 4)
.long_gmp_path:
    ; Allocate PyIntObject
    mov edi, PyIntObject_size
    call ap_malloc
    mov r15, rax               ; r15 = PyIntObject*
    mov qword [r15 + PyObject.ob_refcnt], 1
    lea rax, [rel int_type]
    mov [r15 + PyObject.ob_type], rax
    mov qword [r15 + PyIntObject.compact], 0  ; GMP-backed
    INT_NEED_MPZ r15
    lea rdi, [r15 + PyIntObject.mpz]
    call __gmpz_init wrt ..plt

    ; Read digits and accumulate with GMP
    mov qword [rsp + 0], 0    ; digit index = 0
    mov qword [rsp + 8], 0    ; shift amount = 0

.long_gmp_digit_loop:
    mov rax, [rsp + 0]
    cmp rax, r14
    jge .long_gmp_digits_done

    ; Read one 16-bit digit
    call marshal_read_byte
    movzx r8d, al
    call marshal_read_byte
    movzx eax, al
    shl eax, 8
    or r8d, eax               ; r8d = 16-bit digit

    ; Add digit << shift to the GMP accumulator:
    ; gmpz_import to set a temp, then shift and add
    ; Simpler: use gmpz_set_ui + gmpz_mul_2exp + gmpz_add
    ; But we don't have a temp GMP var. Use gmpz_add_ui if shift=0,
    ; or build via: result = result + (digit << shift)

    ; Alternative approach: use __gmpz_import with the digit
    ; Simplest: manually construct using GMP primitives
    ; gmpz_mul_2exp(result, result, 15) then gmpz_add_ui(result, result, digit)
    ; But digits are little-endian (digit 0 is LSB), so we need reverse order

    ; Actually, digits are in order: digit[0] is least significant.
    ; Accumulate: result += digit << (index * 15)
    ; Using GMP: create temp, set to digit, shift left, add to result.

    ; We'll use a stack-allocated mpz_t for temp
    sub rsp, 16               ; space for temp mpz (16 bytes inline)
    mov rdi, rsp
    call __gmpz_init wrt ..plt
    mov rdi, rsp
    movzx esi, r8w            ; digit value (unsigned)
    extern __gmpz_set_ui
    extern __gmpz_mul_2exp
    extern __gmpz_add
    extern __gmpz_clear
    extern __gmpz_neg
    call __gmpz_set_ui wrt ..plt
    ; Shift: gmpz_mul_2exp(temp, temp, shift_amount)
    mov rdi, rsp
    mov rsi, rsp
    mov rdx, [rsp + 16 + 8]   ; shift amount (from outer stack frame)
    call __gmpz_mul_2exp wrt ..plt
    ; Add: gmpz_add(result, result, temp)
    INT_NEED_MPZ r15
    lea rdi, [r15 + PyIntObject.mpz]
    INT_NEED_MPZ r15
    lea rsi, [r15 + PyIntObject.mpz]
    mov rdx, rsp
    call __gmpz_add wrt ..plt
    ; Clear temp
    mov rdi, rsp
    call __gmpz_clear wrt ..plt
    add rsp, 16                ; the temp mpz, not the arm's own frame

    ; Advance
    add qword [rsp + 8], 15
    inc qword [rsp + 0]
    jmp .long_gmp_digit_loop

.long_gmp_digits_done:
    ; Apply sign
    test r13, r13
    jns .long_gmp_not_neg
    INT_NEED_MPZ r15
    lea rdi, [r15 + PyIntObject.mpz]
    INT_NEED_MPZ r15
    lea rsi, [r15 + PyIntObject.mpz]
    call __gmpz_neg wrt ..plt
.long_gmp_not_neg:
    ; A constant that fits an int64 must not stay mpz-backed: int_binop_unpack
    ; flattens a compact heap int into an immediate and can do nothing with an
    ; mpz.  The GMP arm is taken for anything over four 15-bit digits, so
    ; `1 << 60` -- five digits, and a number that fits in a register -- came
    ; out of here as a bignum and dragged every arithmetic operation on it into
    ; GMP for the life of the program.
    mov rdi, r15
    extern int_shrink
    call int_shrink             ; -> rax, a Value: the same object made
    mov edx, TAG_PTR            ; compact, or an immediate with the object freed
    add rsp, 24
    pop r15
    pop r14
    pop r13
    jmp mfinish

;--------------------------------------------------------------------------
; TYPE_BINARY_FLOAT handler: read 8 bytes as double
; Stub: skip 8 bytes and return None
;--------------------------------------------------------------------------
mdo_binary_float:
    call marshal_read_long64   ; rax = 8 bytes (IEEE 754 double bits)
    movq xmm0, rax            ; move int64 bits to xmm0 as double
    extern float_from_f64
    call float_from_f64
    jmp mfinish

;--------------------------------------------------------------------------
; TYPE_BINARY_COMPLEX handler: two IEEE 754 doubles, real then imaginary.
;
; No r_ref_reserve/r_ref_insert dance.  That protocol exists for containers,
; which can hold a reference back to themselves, so their ref slot has to be
; claimed before their children are read.  A complex has no children -- nothing
; recurses into marshal_read_object between the type byte and the value -- so
; mfinish handling FLAG_REF afterwards is correct, exactly as for a float.
;
; Until this existed, any .pyc carrying a complex literal hit fatal_error on
; the unknown type code rather than raising.
;--------------------------------------------------------------------------
mdo_binary_complex:
    call marshal_read_long64   ; real part, raw bits
    push rax
    call marshal_read_long64   ; imaginary part
    movq xmm1, rax
    pop rax
    movq xmm0, rax
    extern complex_from_doubles
    call complex_from_doubles
    mov edx, TAG_PTR           ; a complex is a heap object; the pointer is
    jmp mfinish                ; its own Value

;--------------------------------------------------------------------------
; TYPE_SHORT_ASCII / TYPE_SHORT_ASCII_INTERNED handler
; Read 1-byte length, then bytes -> str_new
; r12 holds FLAG_REF; we save it on the stack while using r12 as temp.
;--------------------------------------------------------------------------
mdo_short_ascii:
    push r12                   ; save FLAG_REF on stack
    push r13

    call marshal_read_byte     ; al = length
    movzx r13d, al             ; r13 = length

    mov rdi, r13
    call marshal_read_bytes
    test rax, rax
    jz mdo_str_fail    ; rax = pointer to string data in buffer
    mov rdi, rax               ; data ptr
    mov rsi, r13               ; length
    ; CPython recorded in the .pyc which strings IT interned; that answer was
    ; being thrown away.  Taking it means two modules' `self`, `append` and
    ; `__init__` are one object, which is what the LOAD_ATTR cache guard
    ; compares by pointer.  This is before `mfinish`, deliberately: mfinish
    ; calls marshal_add_ref, and recording the duplicate would let a later
    ; TYPE_REF hand out an object the table does not know about.
    cmp ebx, MARSHAL_TYPE_SHORT_ASCII_INTERNED
    jne .msa_plain
    call str_intern_bytes
    jmp .msa_done
.msa_plain:
    call str_new_heap          ; always heap -- co_names readers expect TAG_PTR
.msa_done:

    pop r13
    pop r12                    ; restore FLAG_REF
    jmp mfinish

;--------------------------------------------------------------------------
; TYPE_ASCII / TYPE_ASCII_INTERNED handler
; Read 4-byte length, then bytes -> str_new_heap
;--------------------------------------------------------------------------
mdo_ascii:
    push r12                   ; save FLAG_REF
    push r13

    call marshal_read_long     ; eax = length
    mov r13d, eax              ; r13 = length (unsigned)

    mov rdi, r13
    call marshal_read_bytes
    test rax, rax
    jz mdo_str_fail    ; rax = pointer to string data
    mov rdi, rax               ; data ptr
    mov rsi, r13               ; length
    ; CPython recorded in the .pyc which strings IT interned; that answer was
    ; being thrown away.  Taking it means two modules' `self`, `append` and
    ; `__init__` are one object, which is what the LOAD_ATTR cache guard
    ; compares by pointer.  This is before `mfinish`, deliberately: mfinish
    ; calls marshal_add_ref, and recording the duplicate would let a later
    ; TYPE_REF hand out an object the table does not know about.
    cmp ebx, MARSHAL_TYPE_ASCII_INTERNED
    jne .mas_plain
    call str_intern_bytes
    jmp .mas_done
.mas_plain:
    call str_new_heap          ; always heap -- co_names readers expect TAG_PTR
.mas_done:

    pop r13
    pop r12                    ; restore FLAG_REF
    jmp mfinish

;--------------------------------------------------------------------------
; TYPE_UNICODE / TYPE_INTERNED handler
; Read 4-byte length, then bytes -> str_new_heap (treat as UTF-8)
;--------------------------------------------------------------------------
mdo_unicode:
    push r12                   ; save FLAG_REF
    push r13

    call marshal_read_long     ; eax = length
    mov r13d, eax              ; r13 = length (unsigned)

    mov rdi, r13
    call marshal_read_bytes
    test rax, rax
    jz mdo_str_fail    ; rax = pointer to data
    mov rdi, rax               ; data ptr
    mov rsi, r13               ; length
    ; TYPE_INTERNED reaches here too -- it is a str that happened to be
    ; interned, which CPython's reader also falls through to TYPE_UNICODE.
    ; These bytes may be UTF-8 rather than ASCII, which is why the table
    ; counts code points rather than assuming one per byte.
    cmp ebx, MARSHAL_TYPE_INTERNED
    jne .mun_plain
    call str_intern_bytes
    jmp .mun_done
.mun_plain:
    call str_new_heap          ; always heap -- co_names readers expect TAG_PTR
.mun_done:

    pop r13
    pop r12                    ; restore FLAG_REF
    jmp mfinish

;--------------------------------------------------------------------------
; TYPE_STRING handler
; Read 4-byte length, then bytes -> bytes_from_data
;--------------------------------------------------------------------------
mdo_bytes:
    push r12                   ; save FLAG_REF
    push r13

    call marshal_read_long     ; eax = length
    mov r13d, eax              ; r13 = length (unsigned)

    mov rdi, r13
    call marshal_read_bytes
    test rax, rax
    jz mdo_str_fail    ; rax = pointer to data
    mov rdi, rax               ; data ptr
    mov rsi, r13               ; length
    call bytes_from_data

    pop r13
    pop r12                    ; restore FLAG_REF
    mov edx, TAG_PTR
    jmp mfinish

;--------------------------------------------------------------------------
; TYPE_SMALL_TUPLE handler: 1-byte count, then recursive reads
;--------------------------------------------------------------------------
mdo_small_tuple:
    push r12                   ; save FLAG_REF
    push r13
    push r14
    push r15
    sub rsp, 16                ; [rsp+0]=saved FLAG_REF, [rsp+8]=ref index

    ; Reserve ref slot BEFORE reading children (CPython does the same).
    ; Children will get ref indices after this slot, matching CPython order.
    mov [rsp + 0], r12         ; save FLAG_REF
    test r12d, r12d
    jz .stuple_no_reserve
    xor edi, edi               ; NULL placeholder
    xor esi, esi               ; TAG_NULL
    call marshal_add_ref
    mov rax, [gs:ThreadState.marshal_ref_count]
    dec rax
    mov [rsp + 8], rax         ; save ref index for fixup
.stuple_no_reserve:

    call marshal_read_byte     ; al = count
    movzx r13d, al             ; r13 = count
    mov rdi, r13
    call marshal_count_ok      ; more elements than bytes left is no stream
    mov r13, rax

    ; Allocate tuple
    mov rdi, r13
    call tuple_new
    mov r14, rax               ; r14 = tuple

    ; Read elements
    xor r15d, r15d             ; r15 = index
.stuple_loop:
    ; A refusal already recorded means every read below returns nothing and
    ; consumes nothing, so this loop would never reach its end.
    cmp qword [gs:ThreadState.marshal_error], MARSHAL_ERR_NONE
    jne .stuple_done
    cmp r15, r13
    jge .stuple_done
    push r13
    push r14
    push r15
    sub rsp, 8                 ; the arm's own frame is 16-aligned, so three
                               ; pushes leave this call eight bytes out -- and
                               ; a TYPE_LONG element reaches GMP through it
    call marshal_read_object
    add rsp, 8
    pop r15
    pop r14
    pop r13
    ; Store element in tuple (tag in rdx from marshal_read_object)
    mov r8, [r14 + PyTupleObject.ob_item]       ; payloads
    mov rcx, r15
    shl rcx, 3                 ; index * 8
    V_PACK rax, rdx
    mov [r8 + rcx], rax
    inc r15
    jmp .stuple_loop

.stuple_done:
    ; Fix up reserved ref slot with the actual tuple
    mov rax, [rsp + 0]        ; saved FLAG_REF
    test eax, eax
    jz .stuple_no_fixup
    mov rax, [rsp + 8]        ; ref index
    mov rcx, [gs:ThreadState.marshal_refs]
    mov [rcx + rax*8], r14     ; a pointer is its own Value
    mov rdi, r14
    call obj_incref            ; refs array takes ownership of real object
.stuple_no_fixup:
    mov rax, r14               ; return the tuple
    mov edx, TAG_PTR
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12                    ; restore original r12
    xor r12d, r12d             ; clear FLAG_REF — we handled it ourselves
    jmp mfinish

;--------------------------------------------------------------------------
; TYPE_TUPLE handler: 4-byte count, then recursive reads
;--------------------------------------------------------------------------
mdo_tuple:
    push r12                   ; save FLAG_REF
    push r13
    push r14
    push r15
    sub rsp, 16                ; [rsp+0]=saved FLAG_REF, [rsp+8]=ref index

    ; Reserve ref slot BEFORE reading children (same as CPython)
    mov [rsp + 0], r12
    test r12d, r12d
    jz .tuple_no_reserve
    xor edi, edi               ; NULL placeholder
    xor esi, esi               ; TAG_NULL
    call marshal_add_ref
    mov rax, [gs:ThreadState.marshal_ref_count]
    dec rax
    mov [rsp + 8], rax         ; save ref index for fixup
.tuple_no_reserve:

    call marshal_read_long     ; eax = count
    mov r13d, eax              ; r13 = count (unsigned)
    mov rdi, r13
    call marshal_count_ok      ; more elements than bytes left is no stream
    mov r13, rax

    ; Allocate tuple
    mov rdi, r13
    call tuple_new
    mov r14, rax               ; r14 = tuple

    ; Read elements
    xor r15d, r15d             ; r15 = index
.tuple_loop:
    ; A refusal already recorded means every read below returns nothing and
    ; consumes nothing, so this loop would never reach its end.
    cmp qword [gs:ThreadState.marshal_error], MARSHAL_ERR_NONE
    jne .tuple_done
    cmp r15, r13
    jge .tuple_done
    push r13
    push r14
    push r15
    sub rsp, 8                 ; the arm's own frame is 16-aligned, so three
                               ; pushes leave this call eight bytes out -- and
                               ; a TYPE_LONG element reaches GMP through it
    call marshal_read_object
    add rsp, 8
    pop r15
    pop r14
    pop r13
    ; Store element in tuple (tag in rdx from marshal_read_object)
    mov r8, [r14 + PyTupleObject.ob_item]       ; payloads
    mov rcx, r15
    shl rcx, 3                 ; index * 8
    V_PACK rax, rdx
    mov [r8 + rcx], rax
    inc r15
    jmp .tuple_loop

.tuple_done:
    ; Fix up reserved ref slot with the actual tuple
    mov rax, [rsp + 0]        ; saved FLAG_REF
    test eax, eax
    jz .tuple_no_fixup
    mov rax, [rsp + 8]        ; ref index
    mov rcx, [gs:ThreadState.marshal_refs]
    mov [rcx + rax*8], r14     ; a pointer is its own Value
    mov rdi, r14
    call obj_incref            ; refs array takes ownership of real object
.tuple_no_fixup:
    mov rax, r14
    mov edx, TAG_PTR
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12                    ; restore original r12
    xor r12d, r12d             ; clear FLAG_REF — we handled it ourselves
    jmp mfinish

;--------------------------------------------------------------------------
; TYPE_REF handler: read 4-byte index, return refs[index]
;--------------------------------------------------------------------------
mdo_ref:
    call marshal_read_long     ; eax = index
    mov edi, eax               ; zero-extend to rdi (index is unsigned)
    ; Bounds check
    cmp rdi, [gs:ThreadState.marshal_ref_count]
    jge mdo_ref_oob
    mov rcx, [gs:ThreadState.marshal_refs]
    mov rax, [rcx + rdi*8]
    INCREF_V rax, rdx
    V_UNPACK rax, rdx
.ref_done:
    jmp mfinish

mdo_ref_oob:
    lea rdi, [rel marshal_err_ref_oob]
    mov esi, MARSHAL_ERR_BAD
    call marshal_fail
    jmp mdo_soft_fail

;--------------------------------------------------------------------------
; TYPE_CODE handler: read all code object fields
;
; This handler manages its own FLAG_REF handling: if FLAG_REF was set,
; it adds a NULL placeholder to the ref list before reading sub-objects
; (to handle self-referential structures), then fixes it up at the end.
; It returns directly rather than going through mfinish.
;
; Python 3.12 marshal order for code objects:
;   5 x long: argcount, posonlyargcount, kwonlyargcount, stacksize, flags
;   10 x object: co_code, co_consts, co_names, co_localsplusnames,
;                co_localspluskinds, co_filename, co_name, co_qualname,
;                co_linetable, co_exceptiontable
;   1 x long: co_firstlineno (between co_qualname and co_linetable)
;
; Stack frame layout (relative to rsp after sub rsp, 136):
;   [rsp +  0] co_argcount (4 bytes)
;   [rsp +  4] co_kwonlyargcount (4 bytes)
;   [rsp +  8] co_stacksize (4 bytes)
;   [rsp + 12] co_flags (4 bytes)
;   [rsp + 16] co_code_obj ptr (8 bytes)
;   [rsp + 24] co_consts ptr (8 bytes)
;   [rsp + 32] co_names ptr (8 bytes)
;   [rsp + 40] co_localsplusnames ptr (8 bytes)
;   [rsp + 48] co_localspluskinds ptr (8 bytes)
;   [rsp + 56] co_filename ptr (8 bytes)
;   [rsp + 64] co_name ptr (8 bytes)
;   [rsp + 72] co_qualname ptr (8 bytes)
;   [rsp + 80] co_lnotab ptr (8 bytes)
;   [rsp + 88] co_exceptiontable ptr (8 bytes)
;   [rsp + 96] saved FLAG_REF (8 bytes)
;   [rsp +104] ref index placeholder (8 bytes, used only if FLAG_REF)
;   [rsp +112] co_posonlyargcount (4 bytes)
;   [rsp +116] co_firstlineno (4 bytes)
;   [rsp +120] the failure path's cursor over the ten object slots
; Total: 128 bytes needed, using 136 so rsp is 16-aligned at the arm's calls.
;--------------------------------------------------------------------------
mdo_code:
    push r13                   ; r13 = code object pointer (after alloc)
    push r14                   ; r14 = bytecode length
    push r15                   ; r15 = scratch
    ; 136, not the 120 the layout needs: three pushes and a 128-byte block
    ; leave rsp eight bytes out of 16-alignment, and everything this arm
    ; calls -- gc_alloc, ap_memcpy, and the nested marshal_read_object that
    ; reads a code object out of co_consts -- was called that way.
    sub rsp, 136               ; local storage

    ; The ten object slots, before anything can leave the arm early: the
    ; failure path releases every one that is set, and an unread slot holds
    ; whatever the last call left on the stack.
    xor eax, eax
    mov [rsp + 16], rax
    mov [rsp + 24], rax
    mov [rsp + 32], rax
    mov [rsp + 40], rax
    mov [rsp + 48], rax
    mov [rsp + 56], rax
    mov [rsp + 64], rax
    mov [rsp + 72], rax
    mov [rsp + 80], rax
    mov [rsp + 88], rax

    ; Save FLAG_REF (r12) in our local frame
    mov [rsp + 96], r12

    ; If FLAG_REF was set, add a NULL placeholder to the ref list
    test r12d, r12d
    jz .code_no_placeholder
    xor edi, edi               ; NULL placeholder
    xor esi, esi               ; TAG_NULL
    call marshal_add_ref
    mov rax, [gs:ThreadState.marshal_ref_count]
    dec rax
    mov [rsp + 104], rax       ; save ref index
.code_no_placeholder:

    ; Read fields in marshal order
    call marshal_read_long     ; co_argcount
    mov [rsp + 0], eax

    call marshal_read_long     ; co_posonlyargcount
    mov [rsp + 112], eax       ; save for later

    call marshal_read_long     ; co_kwonlyargcount
    mov [rsp + 4], eax

    call marshal_read_long     ; co_stacksize
    mov [rsp + 8], eax

    call marshal_read_long     ; co_flags
    mov [rsp + 12], eax

    call marshal_read_object   ; co_code
    cmp edx, TAG_PTR
    jne .code_bad_field         ; an immediate is not an object, and
    mov [rsp + 16], rax         ; the slot must never hold one: the
                                ; failure path releases what it finds

    call marshal_read_object   ; co_consts
    cmp edx, TAG_PTR
    jne .code_bad_field         ; an immediate is not an object, and
    mov [rsp + 24], rax         ; the slot must never hold one: the
                                ; failure path releases what it finds

    call marshal_read_object   ; co_names
    cmp edx, TAG_PTR
    jne .code_bad_field         ; an immediate is not an object, and
    mov [rsp + 32], rax         ; the slot must never hold one: the
                                ; failure path releases what it finds

    call marshal_read_object   ; co_localsplusnames
    cmp edx, TAG_PTR
    jne .code_bad_field         ; an immediate is not an object, and
    mov [rsp + 40], rax         ; the slot must never hold one: the
                                ; failure path releases what it finds

    call marshal_read_object   ; co_localspluskinds
    cmp edx, TAG_PTR
    jne .code_bad_field         ; an immediate is not an object, and
    mov [rsp + 48], rax         ; the slot must never hold one: the
                                ; failure path releases what it finds

    call marshal_read_object   ; co_filename
    cmp edx, TAG_PTR
    jne .code_bad_field         ; an immediate is not an object, and
    mov [rsp + 56], rax         ; the slot must never hold one: the
                                ; failure path releases what it finds

    call marshal_read_object   ; co_name
    cmp edx, TAG_PTR
    jne .code_bad_field         ; an immediate is not an object, and
    mov [rsp + 64], rax         ; the slot must never hold one: the
                                ; failure path releases what it finds

    call marshal_read_object   ; co_qualname
    cmp edx, TAG_PTR
    jne .code_bad_field         ; an immediate is not an object, and
    mov [rsp + 72], rax         ; the slot must never hold one: the
                                ; failure path releases what it finds

    call marshal_read_long     ; co_firstlineno
    mov [rsp + 116], eax

    call marshal_read_object   ; co_linetable
    cmp edx, TAG_PTR
    jne .code_bad_field         ; an immediate is not an object, and
    mov [rsp + 80], rax         ; the slot must never hold one: the
                                ; failure path releases what it finds

    call marshal_read_object   ; co_exceptiontable
    cmp edx, TAG_PTR
    jne .code_bad_field         ; an immediate is not an object, and
    mov [rsp + 88], rax         ; the slot must never hold one: the
                                ; failure path releases what it finds

    ; Every field has to BE what the interpreter will read it as.  Marshal
    ; checked offsets and lengths and never types, so a crafted .pyc could
    ; hand co_names a tuple of ints and eval_frame would dereference one as a
    ; PyStrObject, or hand co_code an int and the dispatcher would jump
    ; through it.  A .pyc is not a trusted format -- it is a file on disk,
    ; often written by something other than the program running it -- so the
    ; reader refuses rather than the eval loop crashing.
    ;
    ; The tag was checked as each field was read, above: these slots hold the
    ; PAYLOAD only, so an immediate would look like a small pointer here.
    mov rdi, [rsp + 16]
    call marshal_require_bytes  ; co_code
    mov rdi, [rsp + 24]
    call marshal_require_tuple  ; co_consts: the ITEMS may be anything
    mov rdi, [rsp + 32]
    call marshal_require_strtuple   ; co_names
    mov rdi, [rsp + 40]
    call marshal_require_strtuple   ; co_localsplusnames
    mov rdi, [rsp + 48]
    call marshal_require_bytes  ; co_localspluskinds
    mov rdi, [rsp + 56]
    call marshal_require_str    ; co_filename
    mov rdi, [rsp + 64]
    call marshal_require_str    ; co_name
    mov rdi, [rsp + 72]
    call marshal_require_str    ; co_qualname
    mov rdi, [rsp + 80]
    call marshal_require_bytes  ; co_linetable
    mov rdi, [rsp + 88]
    call marshal_require_bytes  ; co_exceptiontable

    ; And the two counts the frame allocator multiplies out.  frame_new adds
    ; them in 32 bits, so a pair near 2^31 wrapped to a small total and the
    ; frame was allocated far too short; the value stack then ran off the end
    ; of it.  A code object with more than a million slots is not one a
    ; compiler produced.
    mov eax, [rsp + 8]          ; co_stacksize
    cmp eax, MARSHAL_MAX_SLOTS
    ja .code_bad_slots

    ; Compute bytecode length from the co_code bytes object
    mov rax, [rsp + 16]        ; co_code bytes object
    test rax, rax
    jz .code_zero_len
    mov r14, [rax + PyBytesObject.ob_size]  ; r14 = bytecode length
    jmp .code_have_len
.code_zero_len:
    xor r14d, r14d
    jmp .code_have_len
.code_bad_slots:
    lea rdi, [rel marshal_err_slots]
    mov esi, MARSHAL_ERR_BAD
    call marshal_fail
    jmp .code_soft_fail
.code_bad_field:
    lea rdi, [rel marshal_err_field]
    mov esi, MARSHAL_ERR_BAD
    call marshal_fail
    ; fall through

    ; Give back the fields read so far.  Each is a counted reference of this
    ; arm's own -- marshal_add_ref takes its own where FLAG_REF asked for one
    ; -- so this is the same release the finished code object's fields get,
    ; only without the code object.  The ref placeholder stays NULL, which
    ; marshal_cleanup_refs already skips.
.code_soft_fail:
    mov qword [rsp + 120], 16   ; the cursor, in a spare slot: a push here
.code_free_loop:                ; would put obj_decref 8 bytes out of true
    mov rax, [rsp + 120]
    mov rdi, [rsp + rax]
    test rdi, rdi
    jz .code_free_next
    mov qword [rsp + rax], 0
    call obj_decref
.code_free_next:
    mov rax, [rsp + 120]
    add rax, 8
    mov [rsp + 120], rax
    cmp rax, 96
    jb .code_free_loop
    xor eax, eax
    xor edx, edx
    add rsp, 136
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.code_have_len:

    ; Allocate PyCodeObject: fixed header + bytecode.
    ; gc_alloc, matching code_new: a code object is GC-tracked -- co_consts
    ; can hold another code object, and a function's code closes a cycle
    ; through its globals -- and code_dealloc frees it with gc_dealloc, which
    ; would hand free() a pointer sixteen bytes into an ap_malloc'd block.
    lea rdi, [r14 + PyCodeObject.co_code]
    lea rsi, [rel code_type]
    extern gc_alloc
    call gc_alloc
    mov r13, rax               ; r13 = code object

    ; Fill base header
    mov qword [r13 + PyObject.ob_refcnt], 1
    lea rax, [rel code_type]
    mov [r13 + PyObject.ob_type], rax

    ; Fill integer fields
    mov eax, [rsp + 0]
    mov [r13 + PyCodeObject.co_argcount], eax

    mov eax, [rsp + 4]
    mov [r13 + PyCodeObject.co_kwonlyargcount], eax

    ; r15d = len(co_localsplusnames), which IS co_nlocalsplus and is used for
    ; it below.
    mov rax, [rsp + 40]        ; co_localsplusnames tuple
    test rax, rax
    jz .code_nlocals_zero
    mov rax, [rax + PyTupleObject.ob_size]  ; ob_size is qword
    mov r15d, eax              ; truncate to 32-bit count
    jmp .code_nlocals_set
.code_nlocals_zero:
    xor r15d, r15d
.code_nlocals_set:

    ; co_nlocals is NOT that: it is the number of CO_FAST_LOCAL slots, which
    ; is len(co_varnames), and CPython guarantees the two agree.  3.12's
    ; marshal does not store the count -- CPython derives it from the kinds
    ; too -- and storing nlocalsplus here reported a function's cells and free
    ; variables as locals.  code_new derives it the same way for our own
    ; compiler's output.
    xor eax, eax
    mov rdx, [rsp + 48]        ; co_localspluskinds bytes
    test rdx, rdx
    jz .code_nlocals_done
    mov rcx, [rdx + PyBytesObject.ob_size]
    xor esi, esi
.code_nlocals_scan:
    cmp rsi, rcx
    jae .code_nlocals_done
    test byte [rdx + PyBytesObject.data + rsi], CO_FAST_LOCAL
    jz .code_nlocals_next
    inc eax
.code_nlocals_next:
    inc rsi
    jmp .code_nlocals_scan
.code_nlocals_done:
    mov [r13 + PyCodeObject.co_nlocals], eax

    mov eax, [rsp + 8]
    mov [r13 + PyCodeObject.co_stacksize], eax

    mov eax, [rsp + 12]
    mov [r13 + PyCodeObject.co_flags], eax

    ; co_nlocalsplus = len(co_localsplusnames)
    ; r15d already has this from above
    mov [r13 + PyCodeObject.co_nlocalsplus], r15d

    ; co_consts is already a fat tuple — store directly
    mov rax, [rsp + 24]        ; co_consts tuple
    mov [r13 + PyCodeObject.co_consts], rax

    mov rax, [rsp + 32]        ; co_names
    mov [r13 + PyCodeObject.co_names], rax

    mov rax, [rsp + 40]        ; co_localsplusnames
    mov [r13 + PyCodeObject.co_localsplusnames], rax

    mov rax, [rsp + 48]        ; co_localspluskinds
    mov [r13 + PyCodeObject.co_localspluskinds], rax

    mov rax, [rsp + 56]        ; co_filename
    mov [r13 + PyCodeObject.co_filename], rax

    mov rax, [rsp + 64]        ; co_name
    mov [r13 + PyCodeObject.co_name], rax

    mov rax, [rsp + 72]        ; co_qualname
    mov [r13 + PyCodeObject.co_qualname], rax

    mov rax, [rsp + 88]        ; co_exceptiontable
    mov [r13 + PyCodeObject.co_exceptiontable], rax

    ; co_linetable and co_firstlineno are kept now: they are what turns a
    ; bytecode offset back into a source line for tracebacks.
    mov rax, [rsp + 80]        ; co_linetable bytes object (reference kept)
    mov [r13 + PyCodeObject.co_linetable], rax
    mov eax, [rsp + 116]
    mov [r13 + PyCodeObject.co_firstlineno], eax

    ; Bytecode length and positional-only arg count
    mov dword [r13 + PyCodeObject.co_code_len], r14d
    mov eax, [rsp + 112]
    mov [r13 + PyCodeObject.co_posonlyargcount], eax

    ; Copy bytecode from co_code bytes object into inline area
    test r14, r14
    jz .code_no_bytecode
    lea rdi, [r13 + PyCodeObject.co_code]
    mov rax, [rsp + 16]        ; co_code bytes object
    lea rsi, [rax + PyBytesObject.data]
    mov rdx, r14
    call ap_memcpy
.code_no_bytecode:

    ; Every field is written, so it is safe to track: gc_track can trigger a
    ; collection, and code_traverse would otherwise walk uninitialised words.
    mov rdi, r13
    extern gc_track
    call gc_track

    ; DECREF the co_code bytes object (its data was copied inline).
    ; Safe because marshal_add_ref now INCREFs, so refs array holds its own ref.
    mov rdi, [rsp + 16]        ; co_code bytes object
    test rdi, rdi
    jz .code_skip_decref_code
    call obj_decref
.code_skip_decref_code:

    ; Update ref placeholder if FLAG_REF was set
    mov r12, [rsp + 96]        ; restore FLAG_REF into r12
    test r12d, r12d
    jz .code_no_fixup
    mov rax, [rsp + 104]       ; ref index
    mov rcx, [gs:ThreadState.marshal_refs]
    mov [rcx + rax*8], r13     ; a pointer is its own Value
    mov rdi, r13
    call obj_incref            ; refs array takes ownership of real object
.code_no_fixup:

    mov rax, r13               ; return code object
    mov edx, TAG_PTR

    add rsp, 136
    pop r15
    pop r14
    pop r13

    ; We handled FLAG_REF ourselves (placeholder + fixup), so skip mfinish.
    ; But r12 is restored and the marshal_read_object prologue pushed rbx, r12.
    ; We still need to pop those and return.
    pop r12
    pop rbx
    leave
    ret
END_FUNC marshal_read_object

;--------------------------------------------------------------------------
; marshal_require_{str,bytes,tuple,strtuple}(rdi = a field just read)
;
; A .pyc is a file on disk, and often not one written by the program running
; it.  The reader checked offsets and lengths and never types, so a crafted
; stream could hand co_names a tuple of ints and eval_frame would dereference
; one as a PyStrObject, or hand co_code an int and the dispatcher would jump
; through it.  Every field the interpreter later reads without asking is
; checked here instead.
;
; fatal_error rather than an exception, as the unknown-type arm above does:
; this runs before any interpreter frame exists, so there is nothing to raise
; into.
;--------------------------------------------------------------------------
DEF_FUNC_LOCAL marshal_require_str
    V_TEST_PTR rdi, rax
    ja .mrs_bad
    test rdi, rdi
    jz .mrs_bad
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .mrs_bad
    leave
    ret
.mrs_bad:
    lea rdi, [rel marshal_err_field]
    call fatal_error
END_FUNC marshal_require_str

DEF_FUNC_LOCAL marshal_require_bytes
    V_TEST_PTR rdi, rax
    ja .mrb_bad
    test rdi, rdi
    jz .mrb_bad
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    jne .mrb_bad
    leave
    ret
.mrb_bad:
    lea rdi, [rel marshal_err_field]
    call fatal_error
END_FUNC marshal_require_bytes

DEF_FUNC_LOCAL marshal_require_tuple
    V_TEST_PTR rdi, rax
    ja .mrt_bad
    test rdi, rdi
    jz .mrt_bad
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    jne .mrt_bad
    leave
    ret
.mrt_bad:
    lea rdi, [rel marshal_err_field]
    call fatal_error
END_FUNC marshal_require_tuple

;; A tuple, and every item in it a str: co_names and co_localsplusnames are
;; indexed by the opcodes and read as strings without a check.
DEF_FUNC_LOCAL marshal_require_strtuple
    push rbx
    push r12
    mov rbx, rdi
    call marshal_require_tuple
    mov r12, [rbx + PyTupleObject.ob_size]
    mov rbx, [rbx + PyTupleObject.ob_item]
.mrst_loop:
    test r12, r12
    jz .mrst_done
    mov rdi, [rbx]
    call marshal_require_str
    add rbx, 8
    dec r12
    jmp .mrst_loop
.mrst_done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC marshal_require_strtuple

;--------------------------------------------------------------------------
; TYPE_FROZENSET / TYPE_SET handler: 4-byte count, then N objects
; Deserialized as a set object (PyDictObject layout with set_type)
;--------------------------------------------------------------------------
extern set_new
extern set_add

;; A list: the same shape as a tuple, and like a set it has to reserve its
;; ref slot before its elements are read, or a list holding itself would name
;; a slot that is not there yet.
mdo_list:
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16                ; [rsp+0] = saved FLAG_REF, [rsp+8] = ref index

    mov [rsp + 0], r12
    test r12d, r12d
    jz .mlist_no_reserve
    xor edi, edi
    xor esi, esi
    call marshal_add_ref
    mov rax, [gs:ThreadState.marshal_ref_count]
    dec rax
    mov [rsp + 8], rax
.mlist_no_reserve:

    call marshal_read_long
    mov r13d, eax
    mov rdi, r13
    call marshal_count_ok      ; more elements than bytes left is no stream
    mov r13, rax
    xor edi, edi
    extern list_new
    call list_new
    mov r14, rax

    ; Publish the container into its reserved ref slot NOW, not after the
    ; children are read.  A list can hold itself, and the TYPE_REF that says
    ; so is read inside the loop below -- filling the slot at the end left it
    ; NULL for the whole of that read, and the element came back as a NULL
    ; Value that nothing raised on.  CPython's r_ref does the same thing in
    ; the same place.
    mov rax, [rsp + 0]
    test eax, eax
    jz .mlist_no_publish
    test r14, r14
    jz .mlist_no_publish
    mov rax, [rsp + 8]
    mov rcx, [gs:ThreadState.marshal_refs]
    mov [rcx + rax*8], r14
    mov rdi, r14
    call obj_incref
.mlist_no_publish:

    xor r15d, r15d
.mlist_loop:
    ; A refusal already recorded means every read below returns nothing and
    ; consumes nothing, so this loop would never reach its end.
    cmp qword [gs:ThreadState.marshal_error], MARSHAL_ERR_NONE
    jne .mlist_done
    cmp r15, r13
    jge .mlist_done
    push r13
    push r14
    push r15
    sub rsp, 8                 ; the arm's own frame is 16-aligned, so three
                               ; pushes leave this call eight bytes out -- and
                               ; a TYPE_LONG element reaches GMP through it
    call marshal_read_object
    add rsp, 8
    pop r15
    pop r14
    pop r13
    push r13
    push r14
    push r15
    push rdx
    push rax
    sub rsp, 8                 ; five pushes, so the calls below need the pad
    mov rdi, r14
    mov rsi, rax
    V_PACK rsi, rdx
    extern list_append
    call list_append
    add rsp, 8
    pop rdi
    pop rsi
    DECREF_VAL rdi, rsi        ; list_append took its own reference
    pop r15
    pop r14
    pop r13
    inc r15
    jmp .mlist_loop

.mlist_done:
    mov rax, r14
    mov edx, TAG_PTR
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    xor r12d, r12d
    jmp mfinish

;; A dict: key/value pairs until a NULL type byte, which is how the format
;; ends one -- there is no count.
mdo_dict:
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16

    mov [rsp + 0], r12
    test r12d, r12d
    jz .mdict_no_reserve
    xor edi, edi
    xor esi, esi
    call marshal_add_ref
    mov rax, [gs:ThreadState.marshal_ref_count]
    dec rax
    mov [rsp + 8], rax
.mdict_no_reserve:

    extern dict_new
    call dict_new
    mov r14, rax

    ; Publish the container into its reserved ref slot NOW, not after the
    ; children are read.  A dict can hold itself, and the TYPE_REF that says
    ; so is read inside the loop below -- filling the slot at the end left it
    ; NULL for the whole of that read, and the element came back as a NULL
    ; Value that nothing raised on.  CPython's r_ref does the same thing in
    ; the same place.
    mov rax, [rsp + 0]
    test eax, eax
    jz .mdict_no_publish
    test r14, r14
    jz .mdict_no_publish
    mov rax, [rsp + 8]
    mov rcx, [gs:ThreadState.marshal_refs]
    mov [rcx + rax*8], r14
    mov rdi, r14
    call obj_incref
.mdict_no_publish:

.mdict_loop:
    ; A refusal already recorded means every read below returns nothing and
    ; consumes nothing, so this loop would never reach its end.
    cmp qword [gs:ThreadState.marshal_error], MARSHAL_ERR_NONE
    jne .mdict_done
    ; A NULL type byte ends the dict.  Peek rather than read: the key's own
    ; reader has to see its type byte.
    mov rax, [gs:ThreadState.marshal_pos]
    cmp rax, [gs:ThreadState.marshal_len]
    jge .mdict_done
    mov rcx, [gs:ThreadState.marshal_buf]
    movzx eax, byte [rcx + rax]
    and eax, ~MARSHAL_FLAG_REF
    cmp eax, MARSHAL_TYPE_NULL
    jne .mdict_pair
    inc qword [gs:ThreadState.marshal_pos]
    jmp .mdict_done
.mdict_pair:
    push r13
    push r14
    call marshal_read_object
    V_PACK rax, rdx
    mov r15, rax               ; the key
    call marshal_read_object
    V_PACK rax, rdx
    mov r13, rax               ; the value
    mov rdi, [rsp]             ; the dict
    mov rsi, r15
    mov rdx, r13
    extern dict_set
    call dict_set
    mov rdi, r15
    DECREF_V rdi, rcx          ; dict_set took its own references
    mov rdi, r13
    DECREF_V rdi, rcx
    pop r14
    pop r13
    jmp .mdict_loop

.mdict_done:
    mov rax, r14
    mov edx, TAG_PTR
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    xor r12d, r12d
    jmp mfinish

mdo_set:
    push 0                     ; flag: 0 = set_type
    jmp mdo_set_common
mdo_frozenset:
    push 1                     ; flag: 1 = frozenset_type
mdo_set_common:
    push r12                   ; save FLAG_REF
    push r13
    push r14
    push r15
    sub rsp, 16                ; [rsp+0]=saved FLAG_REF, [rsp+8]=ref index

    ; Reserve ref slot BEFORE reading children
    mov [rsp + 0], r12
    test r12d, r12d
    jz .fset_no_reserve
    xor edi, edi               ; NULL placeholder
    xor esi, esi               ; TAG_NULL
    call marshal_add_ref
    mov rax, [gs:ThreadState.marshal_ref_count]
    dec rax
    mov [rsp + 8], rax         ; save ref index for fixup
.fset_no_reserve:

    call marshal_read_long     ; eax = count
    mov r13d, eax              ; r13 = count (unsigned)
    mov rdi, r13
    call marshal_count_ok      ; more elements than bytes left is no stream
    mov r13, rax

    ; Allocate set
    call set_new
    mov r14, rax               ; r14 = set

    ; Read elements and add them
    xor r15d, r15d             ; r15 = index
.fset_loop:
    ; A refusal already recorded means every read below returns nothing and
    ; consumes nothing, so this loop would never reach its end.
    cmp qword [gs:ThreadState.marshal_error], MARSHAL_ERR_NONE
    jne .fset_done
    cmp r15, r13
    jge .fset_done
    push r13
    push r14
    push r15
    sub rsp, 8                 ; the arm's own frame is 16-aligned, so three
                               ; pushes leave this call eight bytes out -- and
                               ; a TYPE_LONG element reaches GMP through it
    call marshal_read_object
    add rsp, 8
    pop r15
    pop r14
    pop r13

    ; Add element to set (set_add does INCREF, marshal gave us owned ref)
    push r13
    push r14
    push r15
    push rdx                   ; save element tag
    push rax                   ; save element payload
    sub rsp, 8                 ; five pushes, so the calls below need the pad;
                               ; set_add hashes its element, and hashing a
                               ; big integer reaches GMP
    mov rdi, r14               ; set
    mov rsi, rax               ; element
    V_PACK rsi, rdx            ; set_add takes a key Value
    call set_add
    add rsp, 8
    pop rdi                    ; element payload
    pop rsi                    ; element tag
    DECREF_VAL rdi, rsi        ; compensate for set_add's INCREF
    pop r15
    pop r14
    pop r13

    inc r15
    jmp .fset_loop

.fset_done:
    ; Fix up reserved ref slot with the actual set
    mov rax, [rsp + 0]        ; saved FLAG_REF
    test eax, eax
    jz .fset_no_fixup
    mov rax, [rsp + 8]        ; ref index
    mov rcx, [gs:ThreadState.marshal_refs]
    mov [rcx + rax*8], r14     ; a pointer is its own Value
    mov rdi, r14
    call obj_incref            ; refs array takes ownership of real object
.fset_no_fixup:
    ; Set ob_type based on frozenset flag
    extern frozenset_type
    cmp qword [rsp + 48], 1
    jne .fset_is_set
    lea rax, [rel frozenset_type]
    mov [r14 + PyObject.ob_type], rax
.fset_is_set:
    mov rax, r14               ; return the set/frozenset
    mov edx, TAG_PTR
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12                    ; restore original r12
    add rsp, 8                 ; pop flag
    xor r12d, r12d             ; clear FLAG_REF -- we handled it ourselves
    jmp mfinish

;--------------------------------------------------------------------------
; The reader's state -- the buffer, the position in it, the ref table, the
; soft-refusal flag and the stack floor -- is per thread, in ThreadState
; (marshal_buf and its neighbours).  It used to be nine process globals, saved
; and restored around a nested call: sound for one thread, but an allocation
; inside a read can start a collection, a finalizer is Python, and Python can
; hand the GIL to a thread that then unmarshals a module of its own.
;--------------------------------------------------------------------------

;--------------------------------------------------------------------------
; Read-only data: error messages
;--------------------------------------------------------------------------
section .rodata
marshal_err_eof:     db "marshal: unexpected end of data", 0
marshal_err_unknown: db "marshal: unknown type code", 0
marshal_err_field:   db "marshal: code object field of the wrong type", 0
marshal_err_slots:   db "marshal: code object wants an impossible number of slots", 0
marshal_err_ref_oob: db "marshal: reference index out of bounds", 0
marshal_err_deep:    db "marshal: nesting too deep", 0

;; ============================================================================
;; (was src/pyc.asm)
;; ============================================================================

section .text

extern sys_open
extern sys_close
extern sys_fstat
extern sys_read
extern ap_malloc
extern ap_free
extern fatal_error
; Global marshal state (defined in marshal.asm)
; struct stat offsets (x86-64 Linux)
STAT_SIZE       equ 144         ; sizeof(struct stat)
STAT_ST_SIZE    equ 48          ; offset of st_size

; open flags
O_RDONLY        equ 0

;; ============================================================================
;; pyc_read_file(const char *filename) -> PyObject*
;; Opens a .pyc file, reads it into memory, validates the header,
;; and returns the code object via marshal_read_object.
;; ============================================================================
DEF_FUNC pyc_read_file
    push rbx
    push r12
    push r13
    sub rsp, STAT_SIZE + 8      ; stat buf + alignment

    mov rbx, rdi            ; rbx = filename

    ; sys_open(filename, O_RDONLY, 0)
    mov esi, O_RDONLY
    xor edx, edx
    call sys_open
    test rax, rax
    js pyc_open_failed      ; negative = error
    mov r12, rax             ; r12 = fd

    ; sys_fstat(fd, &stat_buf) to get file size
    mov rdi, r12
    lea rsi, [rbp - STAT_SIZE - 24]  ; stat buf on stack (after 3 pushes = 24 bytes)
    call sys_fstat
    test rax, rax
    js pyc_stat_failed

    ; Read st_size from stat struct
    mov r13, [rbp - STAT_SIZE - 24 + STAT_ST_SIZE]  ; r13 = file size

    ; Validate minimum size
    cmp r13, PYC_HEADER_SIZE
    jl pyc_too_small

    ; ap_malloc(file_size)
    mov rdi, r13
    call ap_malloc
    mov rbx, rax             ; rbx = buffer

    ; Read entire file: sys_read loop for partial reads
    xor r8d, r8d            ; r8 = total bytes read
.read_loop:
    mov rdi, r12            ; fd
    lea rsi, [rbx + r8]    ; buf + offset
    mov rdx, r13
    sub rdx, r8             ; remaining bytes
    call sys_read
    test rax, rax
    jle pyc_read_failed     ; 0 = EOF too early, negative = error
    add r8, rax
    cmp r8, r13
    jl .read_loop

    ; sys_close(fd)
    mov rdi, r12
    call sys_close

    ; Validate magic number (first 4 bytes)
    mov eax, [rbx]
    cmp eax, PYC_MAGIC_3_12
    jne pyc_bad_magic

    ; Set up marshal read state
    mov [gs:ThreadState.marshal_buf], rbx
    mov qword [gs:ThreadState.marshal_pos], PYC_HEADER_SIZE  ; skip 16-byte header
    mov [gs:ThreadState.marshal_len], r13

    ; Initialize marshal reference list
    call marshal_init_refs

    ; Call marshal_read_object to read the code object
    call marshal_read_object
    mov r12, rax             ; r12 = code object

    ; Release refs array ownership (DECREF all entries)
    extern marshal_cleanup_refs
    call marshal_cleanup_refs

    ; Free the file buffer
    mov rdi, rbx
    call ap_free

    ; Return the code object
    mov rax, r12
    add rsp, STAT_SIZE + 8
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC pyc_read_file

pyc_open_failed:
    lea rdi, [rel pyc_err_open]
    call fatal_error

pyc_stat_failed:
    ; Close fd before error
    mov rdi, r12
    call sys_close
    lea rdi, [rel pyc_err_stat]
    call fatal_error

pyc_too_small:
    ; Close fd before error
    mov rdi, r12
    call sys_close
    lea rdi, [rel pyc_err_small]
    call fatal_error

pyc_read_failed:
    ; Buffer allocated, file open - close and free before error
    mov rdi, r12
    call sys_close
    mov rdi, rbx
    call ap_free
    lea rdi, [rel pyc_err_read]
    call fatal_error

pyc_bad_magic:
    ; Buffer allocated, file closed
    mov rdi, rbx
    call ap_free
    lea rdi, [rel pyc_err_magic]
    call fatal_error

section .rodata
pyc_err_open:  db "pyc: cannot open file", 0
pyc_err_stat:  db "pyc: cannot stat file", 0
pyc_err_small: db "pyc: file too small for header", 0
pyc_err_read:  db "pyc: failed to read file", 0
pyc_err_magic: db "pyc: invalid magic number (expected Python 3.12)", 0

section .text

;; ============================================================================
;; The `marshal` module: loads() over the reader above.
;;
;; The reader exists because a .pyc is marshalled, and importlib -- which
;; twenty-one modules of CPython's Lib/ reach for -- calls marshal.loads on
;; the bytes it read from one.  This is the same reader, driven from Python
;; rather than from the import system, with the globals saved and restored
;; around it the way import_from_file does: a marshalled stream can hold a
;; code object whose own constants marshal, and the reader is not reentrant.
;;
;; dumps() is not here.  Writing the format means writing every type CPython
;; can marshal, and the only caller that would want it is importlib's .pyc
;; WRITER -- which this interpreter never reaches, because it caches through
;; its own loader.
;; ============================================================================
extern raise_exception
extern exc_ValueError_type
extern exc_EOFError_type
extern exc_TypeError_type
extern bytes_like_ptr_len
extern module_new
extern dict_set
extern str_from_cstr_heap
extern obj_decref
extern builtin_func_new
extern str_type

;; ============================================================================
;; marshal_loads_fn(rdi = args, rsi = nargs) -> rax = the object the stream
;; names, as a Value, or does not return
;; ============================================================================
ML_DATA   equ 8
ML_LEN    equ 16
ML_SAVE   equ 96            ; nine saved marshal globals, rbp-96 up to rbp-32
ML_FRAME  equ 104           ; + 1 push = 112, 16-aligned
DEF_FUNC marshal_loads_fn, ML_FRAME
    push rbx
    cmp rsi, 1
    jne .mlf_arity
    mov rdi, [rdi]
    call bytes_like_ptr_len
    test ecx, ecx
    jz .mlf_type
    mov [rbp - ML_DATA], rax
    mov [rbp - ML_LEN], r10

    ; Park the reader's state: a nested marshal is possible, and an import
    ; may already be using it.
    mov rax, [gs:ThreadState.marshal_buf]
    mov [rbp - ML_SAVE], rax
    mov rax, [gs:ThreadState.marshal_pos]
    mov [rbp - ML_SAVE + 8], rax
    mov rax, [gs:ThreadState.marshal_len]
    mov [rbp - ML_SAVE + 16], rax
    mov rax, [gs:ThreadState.marshal_refs]
    mov [rbp - ML_SAVE + 24], rax
    mov rax, [gs:ThreadState.marshal_ref_count]
    mov [rbp - ML_SAVE + 32], rax
    mov rax, [gs:ThreadState.marshal_ref_cap]
    mov [rbp - ML_SAVE + 40], rax
    mov rax, [gs:ThreadState.marshal_soft]
    mov [rbp - ML_SAVE + 48], rax
    mov rax, [gs:ThreadState.marshal_error]
    mov [rbp - ML_SAVE + 56], rax
    mov rax, [gs:ThreadState.marshal_rsp_floor]
    mov [rbp - ML_SAVE + 64], rax

    mov rax, [rbp - ML_DATA]
    mov [gs:ThreadState.marshal_buf], rax
    mov qword [gs:ThreadState.marshal_pos], 0
    mov rax, [rbp - ML_LEN]
    mov [gs:ThreadState.marshal_len], rax
    mov qword [gs:ThreadState.marshal_refs], 0
    mov qword [gs:ThreadState.marshal_ref_count], 0
    mov qword [gs:ThreadState.marshal_ref_cap], 0

    ; Refuse softly from here: there is a frame to raise into, and the bytes
    ; came from the program rather than from a file the interpreter opened
    ; before it had one.
    mov qword [gs:ThreadState.marshal_soft], 1
    mov qword [gs:ThreadState.marshal_error], MARSHAL_ERR_NONE
    mov rax, rsp
    sub rax, MARSHAL_STACK_ROOM
    mov [gs:ThreadState.marshal_rsp_floor], rax
    call marshal_init_refs

    call marshal_read_object
    ; The reader answers the old (payload, tag) pair, not a Value: its own
    ; callers V_PACK each element as they store it.
    V_PACK rax, rdx
    mov rbx, rax

    ; The refs array owns a reference to everything the stream named; give
    ; them back, then free the array, exactly as pyc_read_file does.
    extern marshal_cleanup_refs
    call marshal_cleanup_refs
    mov rdi, [gs:ThreadState.marshal_refs]
    test rdi, rdi
    jz .mlf_no_refs
    call ap_free
.mlf_no_refs:
    mov rax, [rbp - ML_SAVE]
    mov [gs:ThreadState.marshal_buf], rax
    mov rax, [rbp - ML_SAVE + 8]
    mov [gs:ThreadState.marshal_pos], rax
    mov rax, [rbp - ML_SAVE + 16]
    mov [gs:ThreadState.marshal_len], rax
    mov rax, [rbp - ML_SAVE + 24]
    mov [gs:ThreadState.marshal_refs], rax
    mov rax, [rbp - ML_SAVE + 32]
    mov [gs:ThreadState.marshal_ref_count], rax
    mov rax, [rbp - ML_SAVE + 40]
    mov [gs:ThreadState.marshal_ref_cap], rax
    mov rax, [gs:ThreadState.marshal_error]
    mov [rbp - ML_DATA], rax    ; which refusal, before the caller's is back
    mov rax, [rbp - ML_SAVE + 48]
    mov [gs:ThreadState.marshal_soft], rax
    mov rax, [rbp - ML_SAVE + 56]
    mov [gs:ThreadState.marshal_error], rax
    mov rax, [rbp - ML_SAVE + 64]
    mov [gs:ThreadState.marshal_rsp_floor], rax

    cmp qword [rbp - ML_DATA], MARSHAL_ERR_NONE
    jne .mlf_refused
    test rbx, rbx
    jz .mlf_bad
    mov rax, rbx
    pop rbx
    leave
    ret

.mlf_refused:
    ; A refusal does not always come back as nothing: a truncated `i` is a
    ; whole int as far as the arm that read it is concerned, and it is the
    ; recorded refusal, not the shape, that says the stream was no good.
    ; Whatever was built out of it goes back first.
    XDECREF_V rbx, rax

    ; CPython's three answers, and none of them used to be reachable: every
    ; refusal in the reader called fatal_error, so marshal.loads(b"") printed
    ; a message and took the process with it.
    cmp qword [rbp - ML_DATA], MARSHAL_ERR_EOF
    je .mlf_eof
    cmp qword [rbp - ML_DATA], MARSHAL_ERR_OBJ
    je .mlf_eof_obj
.mlf_bad:
    RAISE exc_ValueError_type, "bad marshal data"
.mlf_eof:
    RAISE exc_EOFError_type, "marshal data too short"
.mlf_eof_obj:
    RAISE exc_EOFError_type, "EOF read where object expected"
.mlf_type:
    RAISE exc_TypeError_type, "a bytes-like object is required"
.mlf_arity:
    RAISE exc_TypeError_type, "loads() takes exactly one argument"
END_FUNC marshal_loads_fn

;; ============================================================================
;; marshal_module_init() -> rax = the `marshal` module, owned, or 0
;; ============================================================================
MMI_MOD   equ 8
MMI_FRAME equ 16            ; + 1 push = 24... one word more to land right
global marshal_module_init
DEF_FUNC marshal_module_init, 24        ; + 1 push = 32, 16-aligned
    push rbx
    ; module_new takes a name STRING and a dict, not a C string.
    CSTRING rdi, "marshal"
    call str_from_cstr_heap
    test rax, rax
    jz .mmi_fail
    push rax
    mov rdi, rax
    xor esi, esi                        ; module_new makes the dict
    call module_new
    mov rbx, rax
    pop rdi
    push rbx
    call obj_decref
    pop rbx
    test rbx, rbx
    jz .mmi_fail
    mov [rbp - MMI_MOD], rbx

    extern marshal_load_fn
    lea rdi, [rel marshal_load_fn]
    CSTRING rsi, "load"
    call builtin_func_new
    test rax, rax
    jz .mmi_fail
    push rax
    CSTRING rdi, "load"
    call str_from_cstr_heap
    push rax
    mov rdi, [rbx + PyModuleObject.mod_dict]
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    extern marshal_dump_fn
    lea rdi, [rel marshal_dump_fn]
    CSTRING rsi, "dump"
    call builtin_func_new
    test rax, rax
    jz .mmi_fail
    push rax
    CSTRING rdi, "dump"
    call str_from_cstr_heap
    push rax
    mov rdi, [rbx + PyModuleObject.mod_dict]
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    extern marshal_dumps_fn
    lea rdi, [rel marshal_dumps_fn]
    CSTRING rsi, "dumps"
    call builtin_func_new
    test rax, rax
    jz .mmi_fail
    push rax
    CSTRING rdi, "dumps"
    call str_from_cstr_heap
    push rax
    mov rdi, [rbx + PyModuleObject.mod_dict]
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    lea rdi, [rel marshal_loads_fn]
    CSTRING rsi, "loads"
    call builtin_func_new
    test rax, rax
    jz .mmi_fail
    push rax
    CSTRING rdi, "loads"
    call str_from_cstr_heap
    push rax
    mov rdi, [rbx + PyModuleObject.mod_dict]
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    ; CPython's `version` is 4, and importlib compares against it.
    mov edi, 4
    extern int_from_i64
    call int_from_i64
    V_PACK rax, rdx
    push rax
    CSTRING rdi, "version"
    call str_from_cstr_heap
    push rax
    mov rdi, [rbx + PyModuleObject.mod_dict]
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    add rsp, 8

    mov rax, rbx
    pop rbx
    leave
    ret
.mmi_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC marshal_module_init
