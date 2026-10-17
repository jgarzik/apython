; methods/num.asm - int and float methods
;
; Methods are registered into each type's tp_dict by methods_init, in
; methods_init.asm.  A method is name(PyObject *self, PyObject **args,
; int64_t nargs); args are borrowed, the result is a new reference.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"


; External functions
extern float_type
extern ap_malloc
extern ap_free
extern ap_strcmp
extern str_from_cstr
extern str_require_str
extern obj_decref
extern obj_dealloc
extern str_new_heap
extern tuple_new
extern obj_call_n
extern int_to_i64
extern raise_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern int_type
extern bytes_new
extern bytes_type
extern bool_false
extern bool_true

; Set entry layout constants (must match set.asm)

; --- moved to a sibling file by the split ---

section .text

;; ############################################################################
;;                       INT METHODS
;; ############################################################################

;; ============================================================================
;; HELPER: int_method_self_to_i64
;; Extract raw i64 from self, handling both SmallInt and heap int (subclasses).
;; Input: rdi = args pointer (args[0] = self)
;; Output: rax = raw i64
;; Clobbers: rcx, rdx
;; ============================================================================
DEF_FUNC int_method_self_to_i64
    ; int_unwrap first.  A bool, a compact heap int and an int SUBCLASS each
    ; keep their value somewhere the raw Value is not: I(7).bit_length() was
    ; 0.  And int_to_i64 reads PyIntObject fields off whatever it is handed,
    ; so int.bit_length(1.5) walked a float object and segfaulted -- the same
    ; shape float_self_bits was written to fix on the other side.
    mov rdi, [rdi]              ; args[0] = self, a Value
    V_UNPACK rdi, rdx
    extern int_unwrap
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .imsi_done
    test edx, TAG_RC_BIT
    jz .imsi_bad
    test rdi, rdi
    jz .imsi_bad
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    jne .imsi_bad
    call int_to_i64
    leave
    ret
.imsi_done:
    mov rax, rdi
    leave
    ret
.imsi_bad:
    V_PACK rdi, rdx
    mov rsi, rdi
    CSTRING rdi, `descriptor for 'int' objects doesn't apply to a '\x01' object`
    extern raise_type_error_with_name
    call raise_type_error_with_name
END_FUNC int_method_self_to_i64

;; ============================================================================
;; num_self_to_mpz(rdi = args, rsi = a 16-byte mpz_t the caller owns)
;;
;; Initialises *rsi with self's exact value, whatever shape it is in: an
;; immediate, a bool, a compact heap int, a GMP-backed one, or an int subclass
;; wrapping any of those.  The caller must __gmpz_clear it.
;;
;; The methods below used to reach for int_method_self_to_i64 instead, which
;; truncates: (2**70).bit_count() was 2 and (2**70+3).to_bytes(16,'big') was
;; sixteen bytes of which only the low eight were the number.
;; ============================================================================
DEF_FUNC num_self_to_mpz, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rsi                ; the destination mpz_t

    mov rdi, [rdi]              ; args[0] = self, a Value
    V_UNPACK rdi, rdx
    extern int_unwrap
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .nsm_from_si
    test edx, TAG_RC_BIT
    jz .nsm_bad
    test rdi, rdi
    jz .nsm_bad
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    jne .nsm_bad
    cmp qword [rdi + PyIntObject.compact], 0
    je .nsm_from_mpz
    mov rdi, [rdi + PyIntObject.ival]
.nsm_from_si:
    mov rsi, rdi
    mov rdi, rbx
    extern __gmpz_init_set_si
    call __gmpz_init_set_si wrt ..plt
    pop rbx
    leave
    ret

.nsm_from_mpz:
    lea rsi, [rdi + PyIntObject.mpz]
    mov rdi, rbx
    extern __gmpz_init_set
    call __gmpz_init_set wrt ..plt
    pop rbx
    leave
    ret

.nsm_bad:
    V_PACK rdi, rdx
    mov rsi, rdi
    CSTRING rdi, `descriptor for 'int' objects doesn't apply to a '\x01' object`
    extern raise_type_error_with_name
    call raise_type_error_with_name
END_FUNC num_self_to_mpz

;; ============================================================================
;; int_method_bit_length(args, nargs) -> SmallInt
;; args[0] = self (SmallInt or heap int subclass)
;; Returns number of bits needed to represent abs(self), excluding sign and
;; leading zeros. bit_length(0) = 0.
;; ============================================================================
IBL_SELF  equ 8             ; the unwrapped int, across the two GMP calls
IBL_FRAME equ 16            ; + 0 pushes = 16, 16-aligned.  IBL_SELF was a
                            ; `push rbx` mid-body, which left both of those
                            ; calls eight bytes out of the alignment the ABI
                            ; wants -- and mid-body is exactly where lint.py's
                            ; own check cannot see a push.
DEF_FUNC int_method_bit_length, IBL_FRAME
    ; A value too large for int64 has to be measured on its mpz: going
    ; through int_to_i64 truncated it, so (2**63).bit_length() was 0.
    ;
    ; Unwrapped first, for the same reason the helper below unwraps: a
    ; subclass instance's own compact/mpz fields are not the wrapped int's,
    ; so I(2**70).bit_length() read compact off the wrapper and answered 0.
    mov rdi, [rdi]
    V_UNPACK rdi, rdx
    extern int_unwrap
    call int_unwrap
    mov rax, rdi
    cmp edx, TAG_SMALLINT
    je .ibl_small
    test edx, TAG_RC_BIT
    jz .ibl_bad
    test rax, rax
    jz .ibl_bad
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel int_type]
    cmp rcx, rdx
    jne .ibl_bad
    cmp qword [rax + PyIntObject.compact], 0
    je .ibl_use_mpz
    mov rax, [rax + PyIntObject.ival]
    jmp .ibl_small
.ibl_bad:
    mov rsi, rax
    CSTRING rdi, `descriptor 'bit_length' for 'int' objects doesn't apply to a '\x01' object`
    extern raise_type_error_with_name
    call raise_type_error_with_name
.ibl_use_mpz:
    mov [rbp - IBL_SELF], rax
    lea rdi, [rax + PyIntObject.mpz]
    xor esi, esi
    extern __gmpz_cmp_si
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    jz .ibl_mpz_zero
    mov rdi, [rbp - IBL_SELF]
    lea rdi, [rdi + PyIntObject.mpz]
    mov esi, 2
    extern __gmpz_sizeinbase
    call __gmpz_sizeinbase wrt ..plt
    RET_TAG_SMALLINT
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.ibl_mpz_zero:
    xor eax, eax
    RET_TAG_SMALLINT
    leave
    V_PACK rax, rdx
    ret

.ibl_small:
    ; rax already holds the i64, unwrapped above.

    ; abs(self)
    mov rcx, rax
    neg rcx
    cmovs rcx, rax              ; rcx = abs(self)

    ; bit_length = 0 for 0
    test rcx, rcx
    jz .ibl_zero

    ; bsr finds highest set bit (0-indexed)
    bsr rax, rcx
    inc rax                     ; bit_length = highest_bit + 1
    RET_TAG_SMALLINT
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.ibl_zero:
    xor eax, eax
    RET_TAG_SMALLINT
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC int_method_bit_length

;; ============================================================================
;; int_method_bit_count(args, nargs) -> SmallInt
;; Returns number of ones in the binary representation of abs(self).
;; ============================================================================
IBC_TMP   equ 16            ; an mpz_t
IBC_FRAME equ 24            ; + 1 push = 32, 16-aligned

DEF_FUNC int_method_bit_count, IBC_FRAME
    push rbx

    ; The whole value, not its low 64 bits: this used to go through
    ; int_method_self_to_i64, so (2**70).bit_count() was 2 and
    ; (2**64-1).bit_count() was 63.
    lea rsi, [rbp - IBC_TMP]
    call num_self_to_mpz

    ; mpz_popcount answers ULONG_MAX for a negative operand, and Python counts
    ; the bits of abs(n), so take the absolute value first.
    lea rdi, [rbp - IBC_TMP]
    mov rsi, rdi
    extern __gmpz_abs
    call __gmpz_abs wrt ..plt
    lea rdi, [rbp - IBC_TMP]
    extern __gmpz_popcount
    call __gmpz_popcount wrt ..plt
    mov rbx, rax
    lea rdi, [rbp - IBC_TMP]
    extern __gmpz_clear
    call __gmpz_clear wrt ..plt
    mov rax, rbx

    RET_TAG_SMALLINT
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC int_method_bit_count


;; ============================================================================
;; int_method_conjugate(args, nargs) -> SmallInt
;; ============================================================================
DEF_FUNC int_method_conjugate
    ; n.conjugate() is n.  Truncating through int_method_self_to_i64 made
    ; (2**70+3).conjugate() answer 3, and an int subclass answer a plain int
    ; -- which is right -- for the wrong reason.
    mov rdi, [rdi]              ; args[0] = self, a Value
    V_UNPACK rdi, rdx
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .icj_done
    test edx, TAG_RC_BIT
    jz .icj_bad
    test rdi, rdi
    jz .icj_bad
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    jne .icj_bad
    INCREF rdi
.icj_done:
    mov rax, rdi
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.icj_bad:
    V_PACK rdi, rdx
    mov rsi, rdi
    CSTRING rdi, `descriptor 'conjugate' for 'int' objects doesn't apply to a '\x01' object`
    call raise_type_error_with_name
END_FUNC int_method_conjugate



;; ============================================================================
;; int_method_to_bytes(args, nargs) -> bytes
;; args[0]=self, args[1]=length, args[2]=byteorder ("big" or "little")
;; Optional kwarg: signed=False (via kw_names_pending)
;; ============================================================================

ITB_V      equ 16       ; mpz_t: self's exact value
ITB_T      equ 32       ; mpz_t: the non-negative form that gets exported
ITB_LEN    equ 40
ITB_ORDER  equ 48       ; 1 = big-endian, -1 = little
ITB_SIGNED equ 56
ITB_COUNT  equ 64       ; mpz_export's countp
ITB_OUT    equ 72       ; the bytes object being filled
ITB_KWNAME equ 88       ; the keyword being matched, and the value given for it
ITB_KWVAL  equ 96
ITB_FRAME  equ 96           ; + 2 pushes = 112, 16-aligned

;; ============================================================================
;; itb_order_from_str -- "big"/"little" as the +-1 mpz_export wants
;;
;; Shared by to_bytes and from_bytes, which both take byteorder positionally
;; or by keyword.  The type check is part of the job: the callers used to
;; accept any pointer and then read PyStrObject.data out of it.
;;
;; rdi = the byteorder argument, as a Value
;; -> rax = 1 (big), -1 (little), 0 for a str that is neither (ValueError),
;;    or 2 for something that is not a str at all (TypeError).  CPython tells
;;    those last two apart and so must we.
;; ============================================================================
OFS_SELF equ 8
OFS_FRAME equ 16

DEF_FUNC_LOCAL itb_order_from_str, OFS_FRAME
    extern str_type
    V_TEST_PTR rdi, rcx
    ja .ofs_not_str
    test rdi, rdi
    jz .ofs_not_str
    mov rcx, [rdi + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .ofs_not_str
    mov [rbp - OFS_SELF], rdi
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "big"
    call ap_strcmp
    test eax, eax
    jz .ofs_big
    mov rdi, [rbp - OFS_SELF]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "little"
    call ap_strcmp
    test eax, eax
    jnz .ofs_bad
    mov rax, -1
    leave
    ret
.ofs_big:
    mov eax, 1
    leave
    ret
.ofs_bad:
    xor eax, eax
    leave
    ret
.ofs_not_str:
    mov eax, 2
    leave
    ret
END_FUNC itb_order_from_str

DEF_FUNC int_method_to_bytes, ITB_FRAME
    push rbx
    push r12

    mov rbx, rdi                    ; args
    mov r12, rsi                    ; nargs

    mov qword [rbp - ITB_SIGNED], 0
    mov qword [rbp - ITB_LEN], 1    ; CPython's defaults since 3.11
    mov qword [rbp - ITB_ORDER], 1  ; "big"

    ; length, byteorder and signed may all arrive by keyword -- CPython's
    ; signature is to_bytes(length=1, byteorder='big', *, signed=False), and
    ; pickle calls it with byteorder= spelled out.  Taking only signed= here
    ; made every such call a TypeError.  The keyword values sit in the
    ; trailing argument slots.
    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jz .itb_positional
    mov rcx, [rax + PyTupleObject.ob_size]      ; n_kw
    mov r8, r12
    sub r8, rcx                                 ; n_pos
    xor r9d, r9d
.itb_kw_loop:
    cmp r9, rcx
    jge .itb_kw_done
    mov r10, [rax + PyTupleObject.ob_item]
    mov r10, [r10 + r9*8]                       ; the keyword's name
    mov [rbp - ITB_KWNAME], r10
    mov r11, r8
    add r11, r9
    mov r11, [rbx + r11*8]                      ; the value given for it
    mov [rbp - ITB_KWVAL], r11
    push rax
    push rcx
    push r8
    push r9

    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "signed"
    call ap_strcmp
    test eax, eax
    jnz .itb_kw_not_signed
    mov rdi, [rbp - ITB_KWVAL]
    extern obj_is_true
    call obj_is_true
    mov [rbp - ITB_SIGNED], rax
    jmp .itb_kw_next

.itb_kw_not_signed:
    mov r10, [rbp - ITB_KWNAME]
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "length"
    call ap_strcmp
    test eax, eax
    jnz .itb_kw_not_length
    mov rdi, [rbp - ITB_KWVAL]
    V_UNPACK rdi, rdx
    extern obj_as_index
    call obj_as_index
    mov [rbp - ITB_LEN], rax
    jmp .itb_kw_next

.itb_kw_not_length:
    mov r10, [rbp - ITB_KWNAME]
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "byteorder"
    call ap_strcmp
    test eax, eax
    jnz .itb_kw_unknown
    mov rdi, [rbp - ITB_KWVAL]
    call itb_order_from_str
    test rax, rax
    jz .itb_kw_bad_order
    cmp rax, 2
    je .itb_kw_bad_type
    mov [rbp - ITB_ORDER], rax

.itb_kw_next:
    pop r9
    pop r8
    pop rcx
    pop rax
    inc r9
    jmp .itb_kw_loop

.itb_kw_unknown:
    pop r9
    pop r8
    pop rcx
    pop rax
    jmp .itb_kw_error

.itb_kw_bad_order:
    pop r9
    pop r8
    pop rcx
    pop rax
    jmp .itb_order_error

.itb_kw_bad_type:
    pop r9
    pop r8
    pop rcx
    pop rax
    jmp .itb_error

.itb_kw_done:
    mov r12, r8                                 ; only the positionals remain
    mov qword [gs:ThreadState.kw_names_pending], 0

.itb_positional:
    cmp r12, 1
    jl .itb_error
    cmp r12, 3
    jg .itb_error       ; signed= is keyword-only, as it is in CPython

    cmp r12, 2
    jl .itb_have_args
    ; obj_as_index, not a TAG_SMALLINT test: a length of 9 is a heap int under
    ; INT_STRESS=1, and every int is a pointer to something there.
    mov rdi, [rbx + 8]                          ; args[1] = length
    V_UNPACK rdi, rdx
    extern obj_as_index
    call obj_as_index
    mov [rbp - ITB_LEN], rax

    cmp r12, 3
    jl .itb_have_args
    mov rdi, [rbx + 16]                         ; args[2] = byteorder
    call itb_order_from_str
    test rax, rax
    jz .itb_order_error
    cmp rax, 2
    je .itb_error
    mov [rbp - ITB_ORDER], rax
.itb_order_done:


.itb_have_args:
    cmp qword [rbp - ITB_LEN], 0
    jl .itb_length_error

    mov rdi, rbx
    lea rsi, [rbp - ITB_V]
    call num_self_to_mpz

    ; Does it fit?  nbits = 8 * length; b = the bit length of abs(self).
    ;   unsigned: self >= 0 and b <= nbits
    ;   signed, self >= 0: b <= nbits - 1
    ;   signed, self <  0: b <= nbits - 1, or b == nbits with abs(self) a
    ;                      power of two -- that is exactly -2**(nbits-1)
    ; None of this existed: the value was truncated to 64 bits and shifted out
    ; a byte at a time, so (-1).to_bytes(1, 'big') answered b'\xff' instead of
    ; raising, and a value past 2**64 lost its top.
    lea rdi, [rbp - ITB_V]
    xor esi, esi
    extern __gmpz_cmp_si
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    jz .itb_zero
    mov r12d, 0                         ; lint: flags -- xor would clobber the compare
    jns .itb_have_sign
    mov r12d, 1                                 ; self is negative
.itb_have_sign:
    test r12d, r12d
    jz .itb_magnitude
    cmp qword [rbp - ITB_SIGNED], 0
    je .itb_negative_error

.itb_magnitude:
    lea rdi, [rbp - ITB_T]
    lea rsi, [rbp - ITB_V]
    extern __gmpz_init_set
    call __gmpz_init_set wrt ..plt
    lea rdi, [rbp - ITB_T]
    mov rsi, rdi
    call __gmpz_abs wrt ..plt

    lea rdi, [rbp - ITB_T]
    mov esi, 2
    extern __gmpz_sizeinbase
    call __gmpz_sizeinbase wrt ..plt
    mov rbx, rax                                ; b

    mov rcx, [rbp - ITB_LEN]
    shl rcx, 3                                  ; nbits
    cmp qword [rbp - ITB_SIGNED], 0
    je .itb_fit_unsigned
    dec rcx                                     ; one bit goes to the sign
    cmp rbx, rcx
    jle .itb_fits
    test r12d, r12d
    jz .itb_overflow
    ; -2**(nbits-1) is the one negative value that needs the extra bit.
    inc rcx
    cmp rbx, rcx
    jne .itb_overflow
    lea rdi, [rbp - ITB_T]
    call __gmpz_popcount wrt ..plt
    cmp rax, 1
    jne .itb_overflow
    jmp .itb_fits
.itb_fit_unsigned:
    cmp rbx, rcx
    jg .itb_overflow

.itb_fits:
    ; A negative value is exported as its two's complement, 2**nbits - abs.
    test r12d, r12d
    jz .itb_export
    sub rsp, 16
    mov rdi, rsp
    extern __gmpz_init
    call __gmpz_init wrt ..plt
    mov rdi, rsp
    mov esi, 2
    mov rdx, [rbp - ITB_LEN]
    shl rdx, 3
    extern __gmpz_ui_pow_ui
    call __gmpz_ui_pow_ui wrt ..plt
    lea rdi, [rbp - ITB_T]
    mov rsi, rsp
    lea rdx, [rbp - ITB_T]
    extern __gmpz_sub
    call __gmpz_sub wrt ..plt
    mov rdi, rsp
    call __gmpz_clear wrt ..plt
    add rsp, 16

.itb_export:
    mov rdi, [rbp - ITB_LEN]
    call bytes_new
    mov [rbp - ITB_OUT], rax
    mov rbx, rax
    lea rdi, [rbx + PyBytesObject.data]
    xor esi, esi
    mov rdx, [rbp - ITB_LEN]
    extern ap_memset
    call ap_memset

    ; How many bytes the magnitude occupies, so a big-endian export lands at
    ; the right offset and the leading zeroes stay zero.
    lea rdi, [rbp - ITB_T]
    mov esi, 2
    call __gmpz_sizeinbase wrt ..plt
    add rax, 7
    shr rax, 3                                  ; nbytes
    mov r12, rax

    lea rdi, [rbx + PyBytesObject.data]
    cmp qword [rbp - ITB_ORDER], 0
    jl .itb_export_call                         ; little: LSB first, at offset 0
    add rdi, [rbp - ITB_LEN]
    sub rdi, r12                                ; big: right-aligned
.itb_export_call:
    lea rsi, [rbp - ITB_COUNT]
    mov rdx, [rbp - ITB_ORDER]                  ; 1 = MSB first, -1 = LSB first
    mov ecx, 1                                  ; one byte per "word"
    xor r8d, r8d                                ; endian, irrelevant at size 1
    xor r9d, r9d                                ; no nails
    sub rsp, 16
    lea rax, [rbp - ITB_T]
    mov [rsp], rax                              ; the seventh argument
    extern __gmpz_export
    call __gmpz_export wrt ..plt
    add rsp, 16

    lea rdi, [rbp - ITB_T]
    call __gmpz_clear wrt ..plt
    lea rdi, [rbp - ITB_V]
    call __gmpz_clear wrt ..plt

    mov rax, [rbp - ITB_OUT]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.itb_zero:
    ; Zero fits in any length, including zero bytes.
    lea rdi, [rbp - ITB_V]
    call __gmpz_clear wrt ..plt
    mov rdi, [rbp - ITB_LEN]
    call bytes_new
    mov rbx, rax
    lea rdi, [rbx + PyBytesObject.data]
    xor esi, esi
    mov rdx, [rbp - ITB_LEN]
    call ap_memset
    mov rax, rbx
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.itb_overflow:
    ; RAISE does not return, so an mpz_t initialised above it is never
    ; cleared: a loop probing widths leaked GMP memory linearly.  Both are
    ; live here; only ITB_V is at the negative check.
    lea rdi, [rbp - ITB_T]
    call __gmpz_clear wrt ..plt
    lea rdi, [rbp - ITB_V]
    call __gmpz_clear wrt ..plt
    RAISE exc_OverflowError_type, "int too big to convert"

.itb_negative_error:
    lea rdi, [rbp - ITB_V]
    call __gmpz_clear wrt ..plt
    RAISE exc_OverflowError_type, "can't convert negative int to unsigned"

.itb_length_error:
    RAISE exc_ValueError_type, "length argument must be non-negative"

.itb_kw_error:
    RAISE exc_TypeError_type, "to_bytes() got an unexpected keyword argument"

.itb_error:
    RAISE exc_TypeError_type, "to_bytes() requires (length, byteorder) arguments"

.itb_order_error:
    RAISE exc_ValueError_type, "byteorder must be either 'little' or 'big'"
END_FUNC int_method_to_bytes

;; ============================================================================
;; int_classmethod_from_bytes(args, nargs) -> SmallInt
;; args[0]=cls (type), args[1]=bytes, args[2]=byteorder ("big" or "little")
;; This is a classmethod: cls is passed as first arg.
;; ============================================================================

IFB_BYTES  equ 8
IFB_CLS    equ 16
IFB_VAL    equ 24
IFB_OWNED  equ 32
IFB_NARGS  equ 40
IFB_ARGS   equ 48
IFB_ORDER  equ 56       ; 1 = big-endian, -1 = little
IFB_SIGNED equ 64
IFB_M      equ 80       ; mpz_t: the magnitude read out of the bytes
IFB_KWNAME equ 104      ; the keyword being matched, and the value given for it
IFB_KWVAL  equ 112
IFB_BYTESKW equ 120     ; a bytes= keyword overrides args[1]
IFB_FRAME  equ 128          ; + 2 pushes = 144, 16-aligned

DEF_FUNC int_classmethod_from_bytes, IFB_FRAME
    push rbx
    push r12

    cmp rsi, 2
    jl .ifb_error
    mov [rbp - IFB_ARGS], rdi       ; the conversion below clobbers rdi
    mov rax, [rdi]
    mov [rbp - IFB_CLS], rax        ; cls, for a subclass result
    mov qword [rbp - IFB_OWNED], 0
    mov qword [rbp - IFB_ORDER], 1  ; 'big' since 3.11
    mov qword [rbp - IFB_SIGNED], 0
    mov qword [rbp - IFB_BYTESKW], 0

    ; bytes, byteorder and signed may all arrive by keyword -- CPython's
    ; signature is from_bytes(bytes, byteorder='big', *, signed=False), and
    ; pickle spells byteorder= out.  Taking only signed= here made every such
    ; call a TypeError.  The keyword values sit in the trailing argument
    ; slots.
    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jz .ifb_no_kw
    mov rcx, [rax + PyTupleObject.ob_size]
    mov r8, rsi
    sub r8, rcx                     ; n_pos
    xor r9d, r9d
.ifb_kw_loop:
    cmp r9, rcx
    jge .ifb_kw_done
    mov r10, [rax + PyTupleObject.ob_item]
    mov r10, [r10 + r9*8]
    mov [rbp - IFB_KWNAME], r10
    mov r11, r8
    add r11, r9
    push rax
    mov rax, [rbp - IFB_ARGS]
    mov r11, [rax + r11*8]          ; the value given for it
    pop rax
    mov [rbp - IFB_KWVAL], r11
    push rax
    push rcx
    push r8
    push r9

    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "signed"
    call ap_strcmp
    test eax, eax
    jnz .ifb_kw_not_signed
    mov rdi, [rbp - IFB_KWVAL]
    call obj_is_true
    mov [rbp - IFB_SIGNED], rax
    jmp .ifb_kw_next

.ifb_kw_not_signed:
    mov r10, [rbp - IFB_KWNAME]
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "byteorder"
    call ap_strcmp
    test eax, eax
    jnz .ifb_kw_not_order
    mov rdi, [rbp - IFB_KWVAL]
    call itb_order_from_str
    test rax, rax
    jz .ifb_kw_bad_order
    cmp rax, 2
    je .ifb_kw_bad_type
    mov [rbp - IFB_ORDER], rax
    jmp .ifb_kw_next

.ifb_kw_not_order:
    mov r10, [rbp - IFB_KWNAME]
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "bytes"
    call ap_strcmp
    test eax, eax
    jnz .ifb_kw_unknown
    mov r10, [rbp - IFB_KWVAL]
    mov [rbp - IFB_BYTESKW], r10

.ifb_kw_next:
    pop r9
    pop r8
    pop rcx
    pop rax
    inc r9
    jmp .ifb_kw_loop

.ifb_kw_unknown:
    pop r9
    pop r8
    pop rcx
    pop rax
    jmp .ifb_kw_error

.ifb_kw_bad_order:
    pop r9
    pop r8
    pop rcx
    pop rax
    jmp .ifb_order_error

.ifb_kw_bad_type:
    pop r9
    pop r8
    pop rcx
    pop rax
    jmp .ifb_error

.ifb_kw_done:
    mov rsi, r8                     ; only the positionals remain
    mov qword [gs:ThreadState.kw_names_pending], 0
    cmp rsi, 2
    jge .ifb_no_kw
    cmp qword [rbp - IFB_BYTESKW], 0
    je .ifb_error                   ; the value itself has to come from
                                    ; somewhere: bytes= or args[1]
.ifb_no_kw:

    ; args[1] is any iterable of ints, not only a bytes: ipaddress passes a
    ; map object.  Anything that is not already a bytes goes through bytes()
    ; first, which is where CPython's own conversion lives too.
    mov rax, [rbp - IFB_BYTESKW]
    test rax, rax
    jnz .ifb_have_value
    mov rdi, [rbp - IFB_ARGS]
    mov rax, [rdi + 8]
.ifb_have_value:
    V_TEST_PTR rax, rcx
    ja .ifb_convert
    test rax, rax
    jz .ifb_convert
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    je .ifb_have_bytes
.ifb_convert:
    mov [rbp - IFB_VAL], rax
    mov [rbp - IFB_NARGS], rsi      ; a push here would misalign the call
    lea rdi, [rel bytes_type]
    lea rsi, [rbp - IFB_VAL]
    mov edx, 1
    extern obj_call_n
    call obj_call_n
    mov rsi, [rbp - IFB_NARGS]
    test rax, rax
    jz .ifb_failed
    mov [rbp - IFB_OWNED], rax
.ifb_have_bytes:
    mov [rbp - IFB_BYTES], rax

    ; args[2] = byteorder.  It has defaulted to 'big' since 3.11, and reading
    ; it unconditionally walked off the end of the argument array -- which is
    ; how ipaddress calls it.
    cmp rsi, 3
    jl .ifb_have_order
    mov rdi, [rbp - IFB_ARGS]
    mov rdi, [rdi + 16]            ; args[2] = byteorder
    mov [rbp - IFB_NARGS], rsi
    call itb_order_from_str
    mov rsi, [rbp - IFB_NARGS]
    test rax, rax
    jz .ifb_order_error
    cmp rax, 2
    je .ifb_error
    mov [rbp - IFB_ORDER], rax

.ifb_have_order:
    ; The magnitude, at full width.  This used to accumulate into one 64-bit
    ; register a byte at a time, so anything past eight bytes silently kept
    ; only its low end: int.from_bytes((2**70).to_bytes(16,'big'),'big') was
    ; 0.  signed= was not read at all.
    lea rdi, [rbp - IFB_M]
    extern __gmpz_init
    call __gmpz_init wrt ..plt

    mov rax, [rbp - IFB_BYTES]
    mov r12, [rax + PyBytesObject.ob_size]
    test r12, r12
    jz .ifb_build                   ; b'' is 0, in either order

    lea rax, [rax + PyBytesObject.data]
    sub rsp, 16
    mov [rsp], rax                  ; the seventh argument
    lea rdi, [rbp - IFB_M]
    mov rsi, r12                    ; count
    mov rdx, [rbp - IFB_ORDER]      ; 1 = MSB first, -1 = LSB first
    mov ecx, 1                      ; one byte per "word"
    xor r8d, r8d                    ; endian, irrelevant at size 1
    xor r9d, r9d                    ; no nails
    extern __gmpz_import
    call __gmpz_import wrt ..plt
    add rsp, 16

    ; A signed value whose top bit is set is that magnitude minus 2**(8*n).
    cmp qword [rbp - IFB_SIGNED], 0
    je .ifb_build
    mov rax, [rbp - IFB_BYTES]
    lea rax, [rax + PyBytesObject.data]
    cmp qword [rbp - IFB_ORDER], 0
    jl .ifb_sign_little
    movzx ecx, byte [rax]           ; big-endian: the first byte
    jmp .ifb_sign_test
.ifb_sign_little:
    movzx ecx, byte [rax + r12 - 1] ; little-endian: the last
.ifb_sign_test:
    test cl, 0x80
    jz .ifb_build

    sub rsp, 16
    mov rdi, rsp
    call __gmpz_init wrt ..plt
    mov rdi, rsp
    mov esi, 2
    mov rdx, r12
    shl rdx, 3                      ; 8 * n bits
    extern __gmpz_ui_pow_ui
    call __gmpz_ui_pow_ui wrt ..plt
    lea rdi, [rbp - IFB_M]
    mov rsi, rdi
    mov rdx, rsp
    extern __gmpz_sub
    call __gmpz_sub wrt ..plt
    mov rdi, rsp
    extern __gmpz_clear
    call __gmpz_clear wrt ..plt
    add rsp, 16

.ifb_build:
    ; Hand the mpz to a heap int and let int_shrink decide whether it belongs
    ; in the immediate range.
    xor edi, edi
    extern int_new_compact
    call int_new_compact
    mov rbx, rax
    extern int_promote_mpz
    INT_NEED_MPZ rbx
    lea rdi, [rbx + PyIntObject.mpz]
    lea rsi, [rbp - IFB_M]
    extern __gmpz_set
    call __gmpz_set wrt ..plt
    lea rdi, [rbp - IFB_M]
    call __gmpz_clear wrt ..plt
    mov rdi, rbx
    extern int_shrink
    call int_shrink
    mov [rbp - IFB_VAL], rax        ; the value, as a Value

    mov rdi, [rbp - IFB_OWNED]
    test rdi, rdi
    jz .ifb_no_owned
    mov qword [rbp - IFB_OWNED], 0
    call obj_decref
.ifb_no_owned:
    ; A classmethod builds an instance of the class it was reached through:
    ; `I.from_bytes(b)` is an I, not an int.
    mov rax, [rbp - IFB_CLS]
    V_TEST_PTR rax, rcx
    ja .ifb_plain
    test rax, rax
    jz .ifb_plain
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .ifb_plain
    mov rcx, [rax + PyTypeObject.tp_flags]
    test rcx, TYPE_FLAG_INT_SUBCLASS
    jz .ifb_plain
    mov rdi, [rbp - IFB_CLS]
    lea rsi, [rbp - IFB_VAL]
    mov edx, 1
    extern int_sub_new
    call int_sub_new
    push rax
    push rdx
    mov rdi, [rbp - IFB_VAL]
    DECREF_V rdi, rcx               ; int_sub_new took its own reference
    pop rdx
    pop rax
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.ifb_plain:
    mov rax, [rbp - IFB_VAL]
    mov edx, TAG_PTR
    V_TEST_PTR rax, rcx
    jbe .ifb_plain_done
    xor edx, edx                    ; an immediate: it is its own Value
    mov rdx, TAG_PTR
.ifb_plain_done:
    pop r12
    pop rbx
    leave
    ret

.ifb_failed:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.ifb_kw_error:
    RAISE exc_TypeError_type, "from_bytes() got an unexpected keyword argument"

.ifb_error:
    RAISE exc_TypeError_type, "from_bytes() requires (bytes, byteorder) arguments"

.ifb_order_error:
    RAISE exc_ValueError_type, "byteorder must be either 'little' or 'big'"
END_FUNC int_classmethod_from_bytes




;; ############################################################################
;;                       FLOAT METHODS
;; ############################################################################

;; ============================================================================
;; float_method_is_integer(args, nargs) -> Bool
;; args[0] = self (Float: payload=raw double bits, tag=TAG_FLOAT)
;; Returns True if float has no fractional part.
;; ============================================================================

DEF_FUNC float_method_is_integer
    mov rdi, [rdi]              ; args[0] = self
    call float_self_bits        ; a subclass instance is a pointer, not an
                                ; immediate: see float_self_bits
    movq xmm0, rax

    ; Check for inf/nan — not integer
    movq rax, xmm0
    mov rcx, 0x7ff0000000000000  ; inf exponent mask
    and rax, rcx
    cmp rax, rcx
    je .fii_false               ; inf or nan

    ; Compare floor(x) == x
    roundsd xmm1, xmm0, 1      ; xmm1 = floor(xmm0) (round toward -inf)
    ucomisd xmm0, xmm1
    jp .fii_false               ; NaN
    jne .fii_false              ; not equal

    ; True
    mov eax, 1
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.fii_false:
    xor eax, eax
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC float_method_is_integer

;; ============================================================================
;; float_method_conjugate(args, nargs) -> Float (return self)
;; ============================================================================
;; ============================================================================
;; float_self_bits(rdi = the self Value) -> rax = the raw double bits
;;
;; V_TO_F64 alone is right only for a float IMMEDIATE.  A float subclass
;; instance is a pointer, and subtracting the NaN-box offset from an address
;; produced a number whose bits happen to be a NaN -- which is why F(2.5).hex()
;; answered '-nan' rather than raising anything.
;; ============================================================================
DEF_FUNC_BARE float_self_bits
    V_IS_FLOAT rdi, rax
    ja .fsb_not_immediate
    mov rax, rdi
    V_TO_F64 rax
    ret
.fsb_not_immediate:
    V_TEST_PTR rdi, rax
    ja .fsb_zero                ; an int immediate: 0.0 is as good as anything
    test rdi, rdi
    jz .fsb_zero
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel float_type]
    cmp rax, rcx
    je .fsb_inline
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_FLOAT_SUBCLASS
    jz .fsb_zero
.fsb_inline:
    mov rax, [rdi + PyFloatObject.value]
    ret
.fsb_zero:
    xor eax, eax
    ret
END_FUNC float_self_bits

DEF_FUNC_BARE float_method_conjugate
    mov rdi, [rdi]              ; args[0] = self
    call float_self_bits        ; a subclass instance is a pointer, not an
                                ; immediate: see float_self_bits
    mov edx, TAG_FLOAT
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC float_method_conjugate





;; ============================================================================
;; fir_pow2_scale(rdi = a signed int64, rsi = a shift) -> rax = a Value
;;   holding exactly `value * 2**shift`
;;
;; The one arithmetic float.as_integer_ratio() cannot do in a register.  A
;; shift that stays inside an int64 is done inline, which is the common case --
;; 0.5 is (1, 2) -- and anything wider goes through GMP and comes back through
;; int_shrink, exactly as every other operator that can overflow does.
;; ============================================================================
extern int_new_compact
extern int_shrink
extern __gmpz_set_si
extern __gmpz_mul_2exp

FPS_MANT  equ 8
FPS_SHIFT equ 16
FPS_FRAME equ 24            ; + 1 push = 32, 16-aligned for the GMP calls
DEF_FUNC_LOCAL fir_pow2_scale, FPS_FRAME
    ; rbx is saved in the prologue rather than inside .fps_wide, so that the
    ; alignment check can see the push: the GMP calls below need rsp 16-byte
    ; aligned and 24 + 8 is what does it.
    push rbx

    ; The inline arm: shift, shift back, and see whether the value survived.
    mov rax, rdi
    mov rcx, rsi
    cmp rcx, 62
    ja .fps_wide
    mov rdx, rax
    shl rax, cl
    sar rax, cl
    cmp rax, rdx
    jne .fps_wide
    mov rax, rdx
    shl rax, cl
    V_PACK_I64 rax, rcx
    pop rbx
    leave
    ret

.fps_wide:
    mov [rbp - FPS_MANT], rdi
    mov [rbp - FPS_SHIFT], rsi
    ; int_new_compact, not int_from_i64: the latter answers an IMMEDIATE for a
    ; small value, and there is no mpz on an immediate to scale.
    xor edi, edi
    call int_new_compact
    mov rbx, rax
    INT_NEED_MPZ rbx
    lea rdi, [rbx + PyIntObject.mpz]
    mov rsi, [rbp - FPS_MANT]
    call __gmpz_set_si wrt ..plt
    lea rdi, [rbx + PyIntObject.mpz]
    mov rsi, rdi
    mov rdx, [rbp - FPS_SHIFT]
    call __gmpz_mul_2exp wrt ..plt
    mov rdi, rbx
    call int_shrink
    pop rbx
    leave
    ret
END_FUNC fir_pow2_scale

;; ============================================================================
;; float_method_as_integer_ratio(rdi = args, rsi = nargs)
;;   -> rax = a Value: the 2-tuple (numerator, denominator)
;;
;; Exact for every finite float.  This used to build both halves in one 64-bit
;; register, which was wrong three ways at once:
;;
;;   - anything needing a shift past 62 raised OverflowError wearing the
;;     message meant for inf and NaN.  (1e300) and (2.0**70) both did, and
;;     21,998 of CPython's test_statistics errors were this one line.
;;   - a SUBNORMAL was decoded as if it were normal: the exponent came out one
;;     too low and the implicit mantissa bit was set, which a subnormal does
;;     not have.  Both were invisible only because the range check rejected
;;     every subnormal first.
;;   - and between 2**63 and about 2**115, where the shift still passed the
;;     guard but not the register, it silently WRAPPED.  3.0 * 2**62 is the
;;     smallest case.
;;
;; inf and NaN are also two different refusals in CPython, not one.
;; ============================================================================
extern exc_OverflowError_type
extern exc_MemoryError_type

FIR_MANT  equ 8             ; the mantissa, across the calls that build the pair
FIR_FRAME equ 8             ; + 1 push = 16
DEF_FUNC float_method_as_integer_ratio, FIR_FRAME
    push rbx

    mov rdi, [rdi]              ; args[0] = self
    call float_self_bits        ; a subclass instance is a pointer, not an
                                ; immediate: see float_self_bits

    ; inf and NaN: OverflowError for the infinities, ValueError for a NaN,
    ; each naming what it was handed rather than both at once.
    mov rcx, rax
    mov rdx, 0x7ff0000000000000
    and rcx, rdx
    cmp rcx, rdx
    jne .fir_finite
    mov rcx, rax
    mov rdx, 0x000fffffffffffff
    and rcx, rdx
    jnz .fir_nan
    jmp .fir_inf

.fir_finite:
    mov r8, rax                 ; the raw bits
    mov r10d, eax
    shr rax, 52
    and eax, 0x7ff              ; the biased exponent
    mov r10d, eax
    mov rax, r8
    mov rdx, 0x000fffffffffffff
    and rax, rdx                ; the mantissa field
    test r10d, r10d
    jz .fir_subnormal

    ; Normal: the implicit bit is there, and the value is M * 2**(biased-1075)
    ; -- 1023 of bias and 52 of mantissa.
    bts rax, 52
    sub r10d, 1075
    jmp .fir_have_parts

.fir_subnormal:
    ; No implicit bit, and the exponent is -1074 rather than the -1075 the
    ; normal formula gives: a subnormal's leading digit is 0, not 1.  A zero
    ; mantissa here is the zero itself, either sign of it.
    test rax, rax
    jz .fir_zero
    mov r10d, -1074

.fir_have_parts:
    ; Strip the trailing zeros, so the pair comes out fully reduced.
    tzcnt rdx, rax
    mov ecx, edx
    shr rax, cl
    add r10d, edx

    ; The sign belongs to the numerator.
    bt r8, 63
    jnc .fir_signed
    neg rax
.fir_signed:

    ; value = rax * 2**r10d, with rax odd and inside 54 bits.
    test r10d, r10d
    js .fir_neg_exp

    ; numerator = mantissa << exp, denominator = 1
    mov rdi, rax
    movsxd rsi, r10d
    call fir_pow2_scale
    mov rbx, rax                ; the numerator, a Value
    mov edi, 2
    call tuple_new
    mov r9, [rax + PyTupleObject.ob_item]
    mov [r9], rbx
    mov rcx, V_INT(1)
    mov [r9 + 8], rcx
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.fir_neg_exp:
    ; numerator = mantissa, denominator = 1 << -exp.  The numerator always
    ; fits an int64 here: it is what is left of a 53-bit mantissa.
    neg r10d
    mov [rbp - FIR_MANT], rax
    mov edi, 1
    movsxd rsi, r10d
    call fir_pow2_scale
    mov rbx, rax                ; the denominator, a Value
    mov edi, 2
    call tuple_new
    mov r9, [rax + PyTupleObject.ob_item]
    mov rcx, [rbp - FIR_MANT]
    V_PACK_I64 rcx, r10
    mov [r9], rcx
    mov [r9 + 8], rbx
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.fir_zero:
    ; Return (0, 1)
    mov edi, 2
    call tuple_new
    mov rbx, rax

    mov r9, [rbx + PyTupleObject.ob_item]
    xor ecx, ecx
    V_PACK_I64 rcx, r10
    mov [r9], rcx
    mov rcx, V_INT(1)
    mov [r9 + 8], rcx

    mov rax, rbx
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.fir_inf:
    RAISE exc_OverflowError_type, "cannot convert Infinity to integer ratio"
.fir_nan:
    RAISE exc_ValueError_type, "cannot convert NaN to integer ratio"
END_FUNC float_method_as_integer_ratio

;; ============================================================================
;; float_method_hex(args, nargs) -> str
;; Format double as CPython's '[-]0xH.HHHHHHHHHHHHHp[+-]D' hex string.
;;
;; A SUBNORMAL has no implicit leading 1 and its exponent is the smallest
;; NORMAL one rather than one below it, which is what CPython's float_hex
;; arrives at by frexp and a shift.  This hardcoded the leading '1' and
;; subtracted the bias unconditionally, so 5e-324 came out as
;; '0x1.0000000000001p-1023' -- a different NUMBER, and the hex()/fromhex()
;; round trip did not close for any subnormal.
;; ============================================================================
FH_BUF    equ 8
FH_EXP    equ 16            ; the unbiased exponent, across the digit loop
FH_FRAME  equ 32            ; + 2 pushes: rsp is 16-aligned at every call

DEF_FUNC float_method_hex, FH_FRAME
    push rbx
    push r12

    mov rdi, [rdi]              ; args[0] = self
    call float_self_bits        ; a subclass instance is a pointer, not an
                                ; immediate: see float_self_bits
    mov rbx, rax                ; save bits

    ; Allocate temp buffer (64 bytes is enough for any hex float)
    mov edi, 64
    call ap_malloc
    mov [rbp - FH_BUF], rax
    mov r12, rax                ; write pointer

    ; Check sign
    bt rbx, 63
    jnc .fh_nosign
    mov byte [r12], '-'
    inc r12
.fh_nosign:

    ; Clear sign for analysis
    mov rax, rbx
    btr rax, 63

    ; Check for zero
    test rax, rax
    jz .fh_zero

    ; Check for inf
    mov rcx, 0x7ff0000000000000
    cmp rax, rcx
    je .fh_inf

    ; Check for NaN
    mov rdx, rax
    and rdx, rcx
    cmp rdx, rcx
    je .fh_nan

    ; Extract exponent and mantissa.
    mov rdx, rax
    shr rdx, 52
    and edx, 0x7ff              ; biased exponent
    mov r9d, '1'                ; the implicit leading bit, when there is one
    test edx, edx
    jnz .fh_have_exp
    mov r9d, '0'                ; subnormal: no implicit 1 ...
    mov edx, 1                  ; ... and the exponent is -1022, not -1023
.fh_have_exp:
    sub edx, 1023               ; unbiased
    mov [rbp - FH_EXP], edx

    mov rcx, rax
    mov r8, 0x000fffffffffffff
    and rcx, r8                 ; mantissa bits (52 bits)

    ; Write "0x1." or, for a subnormal, "0x0."
    mov byte [r12], '0'
    mov byte [r12+1], 'x'
    mov [r12+2], r9b
    mov byte [r12+3], '.'
    add r12, 4

    ; Convert mantissa to 13 hex digits (52 bits / 4 = 13 digits)
    ; Write hex digits from high nibble to low
    mov rax, rcx
    mov ecx, 13                 ; 13 hex digits
    mov r8d, 48                 ; shift = 48 (start from high)
.fh_hex_loop:
    test ecx, ecx
    jz .fh_hex_done
    push rcx
    mov cl, r8b
    mov rdx, rax
    shr rdx, cl
    and edx, 0x0f
    pop rcx
    cmp edx, 10
    jb .fh_digit
    add edx, ('a' - 10)
    jmp .fh_store_digit
.fh_digit:
    add edx, '0'
.fh_store_digit:
    mov [r12], dl
    inc r12
    sub r8d, 4
    dec ecx
    jmp .fh_hex_loop

.fh_hex_done:

    ; Write 'p' and exponent
    mov byte [r12], 'p'
    inc r12

    ; The digit loop needed edx, so the exponent came from a frame slot: it
    ; used to be recomputed here, and the recomputation was the second place
    ; the subnormal rule had to be applied and was not.
    mov eax, [rbp - FH_EXP]

    ; Write sign of exponent
    test eax, eax
    js .fh_exp_neg
    mov byte [r12], '+'
    inc r12
    jmp .fh_exp_write
.fh_exp_neg:
    mov byte [r12], '-'
    inc r12
    neg eax
.fh_exp_write:
    ; Convert exponent to decimal string
    ; eax = absolute exponent value
    ; Use simple div loop
    push r12                    ; save start of exponent digits
    mov ecx, 10
    xor r8d, r8d               ; digit count
    test eax, eax
    jnz .fh_exp_digits
    ; Zero exponent
    mov byte [r12], '0'
    inc r12
    jmp .fh_exp_done
.fh_exp_digits:
    ; Push digits in reverse
    xor edx, edx
    div ecx                     ; eax = quotient, edx = remainder
    push rdx
    inc r8d
    test eax, eax
    jnz .fh_exp_digits
    ; Pop digits into buffer
.fh_exp_pop:
    test r8d, r8d
    jz .fh_exp_done
    pop rax
    add eax, '0'
    mov [r12], al
    inc r12
    dec r8d
    jmp .fh_exp_pop
.fh_exp_done:
    pop rax                     ; discard saved start pos

    ; Create string from buffer
    mov rdi, [rbp - FH_BUF]
    mov rsi, r12
    sub rsi, rdi                ; length
    call str_new_heap
    push rax

    mov rdi, [rbp - FH_BUF]
    call ap_free

    pop rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.fh_zero:
    ; Write "0x0.0p+0"
    mov byte [r12], '0'
    mov byte [r12+1], 'x'
    mov byte [r12+2], '0'
    mov byte [r12+3], '.'
    mov byte [r12+4], '0'
    mov byte [r12+5], 'p'
    mov byte [r12+6], '+'
    mov byte [r12+7], '0'
    add r12, 8
    jmp .fh_make_str

.fh_inf:
    mov byte [r12], 'i'
    mov byte [r12+1], 'n'
    mov byte [r12+2], 'f'
    add r12, 3
    jmp .fh_make_str

.fh_nan:
    mov byte [r12], 'n'
    mov byte [r12+1], 'a'
    mov byte [r12+2], 'n'
    add r12, 3

.fh_make_str:
    mov rdi, [rbp - FH_BUF]
    mov rsi, r12
    sub rsi, rdi
    call str_new_heap
    push rax

    mov rdi, [rbp - FH_BUF]
    call ap_free

    pop rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC float_method_hex

;; ============================================================================
;; ffh_isspace(ecx = one byte) -> eax = 1 when it is ASCII whitespace, else 0
;;
;; Py_ISSPACE's set, which is what float.fromhex skips at both ends: space and
;; \t \n \v \f \r.  Not the Unicode set -- CPython's is ASCII here too.
;; ============================================================================
DEF_FUNC_BARE ffh_isspace
    mov eax, 1
    cmp cl, ' '
    je .yes
    lea edx, [rcx - 9]
    cmp edx, 4                  ; 9..13 inclusive
    jbe .yes
    xor eax, eax
.yes:
    ret
END_FUNC ffh_isspace

;; ============================================================================
;; ffh_ishex(ecx = one byte) -> eax = 1 when it is a hex digit, else 0
;; ============================================================================
DEF_FUNC_BARE ffh_ishex
    mov eax, 1
    lea edx, [rcx - '0']
    cmp edx, 9
    jbe .yes
    mov edx, ecx
    or dl, 0x20
    sub edx, 'a'
    cmp edx, 5
    jbe .yes
    xor eax, eax
.yes:
    ret
END_FUNC ffh_ishex

;; ============================================================================
;; float_classmethod_fromhex(args, nargs) -> Value: a float, or cls(float)
;; args[0] = cls, args[1] = the string
;;
;; CPython's grammar, in CPython's order
;; (~/tmp/repo/cpython/Objects/floatobject.c, float_fromhex):
;;
;;     [ws] [sign] ( inf | infinity | nan
;;                 | [0x] hexdigits [ . hexdigits ] [ p [sign] decdigits ] )
;;     [ws] EOS
;;
;; with at least one hex digit overall, at least one exponent digit after a
;; `p`, and the whole string consumed.  Nearly all of that was missing.  `0x`
;; and `p` were both MANDATORY, so '0x1.8', '0x10', '1p3', 'inf' and 'nan'
;; were refused; nothing checked the digit counts or the end of the string, so
;; '0x1p', '0x1p+', '0xp1' and '0x1p1zzz' were accepted; there was no
;; whitespace skipping; and the mantissa was accumulated into a 64-bit
;; register with one `shl 4` per digit, so past 16 hex digits it silently
;; WRAPPED -- '0x1.0000000000000000000001p+0' answered 3.2311742677852644e-27
;; where CPython answers 1.0, and '0x1234567890abcdef123p0' was out by three
;; orders of magnitude.  Those two were wrong ANSWERS, not refusals.
;;
;; The arithmetic is glibc's strtod, which parses C99 hex floats with correct
;; round-half-even and which this tree already uses for every decimal float
;; (src/compiler/parse.asm).  What the validation above buys is exactly the
;; two places the grammars differ -- C99 requires the `0x` prefix and, for a
;; hex significand, a `p` exponent, and CPython requires neither -- so the
;; span is copied into a canonical `[-]0x<digits>p<exp>` before it is handed
;; over.
;;
;; Overflow is read off the RESULT rather than out of errno: an infinity that
;; no `inf` was spelled is CPython's OverflowError, and an underflow to zero
;; is a zero there as it is here ('0x1p-1075' is 0.0 in both, by
;; round-half-even at the subnormal boundary).
;; ============================================================================
FFH_STR    equ 8
FFH_CLS    equ 16
FFH_BUF    equ 24
FFH_DSTART equ 32
FFH_DLEN   equ 40
FFH_ESTART equ 48
FFH_ELEN   equ 56
FFH_SIGN   equ 64
FFH_RES    equ 72
FFH_LIT    equ 80               ; 1 when inf/nan was spelled, so no strtod
FFH_FRAME  equ 88               ; + 3 pushes: rsp is 16-aligned at every call

extern strtod
extern ap_memcpy
extern exc_OverflowError_type
extern exc_MemoryError_type

DEF_FUNC float_classmethod_fromhex, FFH_FRAME
    push rbx
    push r12
    push r13

    mov rax, [rdi]                  ; args[0] = cls
    mov [rbp - FFH_CLS], rax

    ; Read as a PyStrObject whatever it was, so `float.fromhex(0)` refuses the
    ; TYPE rather than reading a small integer's Value as a pointer.
    mov rdi, [rdi + 8]              ; args[1]
    CSTRING rsi, "bad argument type for built-in operation"
    call str_require_str
    mov [rbp - FFH_STR], rax
    mov qword [rbp - FFH_BUF], 0
    mov qword [rbp - FFH_ESTART], 0
    mov qword [rbp - FFH_ELEN], 0
    mov qword [rbp - FFH_LIT], 0
    mov byte [rbp - FFH_SIGN], 0

    ; rbx = cursor, r12 = one past the last byte.  The length is ob_size and
    ; not a strlen, so an embedded NUL fails the "consumed it all" test below
    ; rather than ending the parse early.
    mov r12, [rax + PyStrObject.ob_size]
    lea rbx, [rax + PyStrObject.data]
    add r12, rbx

.ffh_lead_ws:
    cmp rbx, r12
    jae .ffh_bad                    ; nothing but whitespace
    movzx ecx, byte [rbx]
    call ffh_isspace
    test eax, eax
    jz .ffh_sign
    inc rbx
    jmp .ffh_lead_ws

.ffh_sign:
    movzx eax, byte [rbx]
    cmp al, '-'
    je .ffh_sign_take
    cmp al, '+'
    jne .ffh_maybe_lit
.ffh_sign_take:
    mov [rbp - FFH_SIGN], al
    inc rbx

.ffh_maybe_lit:
    ; inf / infinity / nan, case-insensitively, before anything numeric --
    ; CPython's _Py_parse_inf_or_nan runs first for the same reason.
    mov rax, r12
    sub rax, rbx
    cmp rax, 3
    jb .ffh_number
    movzx ecx, byte [rbx]
    or cl, 0x20
    cmp cl, 'i'
    je .ffh_try_inf
    cmp cl, 'n'
    je .ffh_try_nan
    jmp .ffh_number

.ffh_try_inf:
    movzx ecx, byte [rbx + 1]
    or cl, 0x20
    cmp cl, 'n'
    jne .ffh_number
    movzx ecx, byte [rbx + 2]
    or cl, 0x20
    cmp cl, 'f'
    jne .ffh_number
    add rbx, 3
    ; "inity" may follow, and nothing else may take its place.
    mov rax, r12
    sub rax, rbx
    cmp rax, 5
    jb .ffh_inf_value
    movzx ecx, byte [rbx]
    or cl, 0x20
    cmp cl, 'i'
    jne .ffh_inf_value
    movzx ecx, byte [rbx + 1]
    or cl, 0x20
    cmp cl, 'n'
    jne .ffh_inf_value
    movzx ecx, byte [rbx + 2]
    or cl, 0x20
    cmp cl, 'i'
    jne .ffh_inf_value
    movzx ecx, byte [rbx + 3]
    or cl, 0x20
    cmp cl, 't'
    jne .ffh_inf_value
    movzx ecx, byte [rbx + 4]
    or cl, 0x20
    cmp cl, 'y'
    jne .ffh_inf_value
    add rbx, 5
.ffh_inf_value:
    mov rax, 0x7ff0000000000000
    jmp .ffh_lit_value

.ffh_try_nan:
    movzx ecx, byte [rbx + 1]
    or cl, 0x20
    cmp cl, 'a'
    jne .ffh_number
    movzx ecx, byte [rbx + 2]
    or cl, 0x20
    cmp cl, 'n'
    jne .ffh_number
    add rbx, 3
    mov rax, 0x7ff8000000000000

.ffh_lit_value:
    cmp byte [rbp - FFH_SIGN], '-'
    jne .ffh_lit_store
    mov rcx, 0x8000000000000000
    xor rax, rcx
.ffh_lit_store:
    mov [rbp - FFH_RES], rax
    mov qword [rbp - FFH_LIT], 1
    jmp .ffh_trailing_ws

.ffh_number:
    ; The `0x` prefix is OPTIONAL, and a lone leading `0` is just a digit --
    ; CPython backtracks over it, and so does this.
    mov rax, r12
    sub rax, rbx
    cmp rax, 2
    jb .ffh_digits
    cmp byte [rbx], '0'
    jne .ffh_digits
    movzx ecx, byte [rbx + 1]
    or cl, 0x20
    cmp cl, 'x'
    jne .ffh_digits
    add rbx, 2

.ffh_digits:
    mov [rbp - FFH_DSTART], rbx
    xor r13d, r13d                  ; r13 = hex digits seen, point aside
.ffh_int_loop:
    cmp rbx, r12
    jae .ffh_digits_end
    movzx ecx, byte [rbx]
    call ffh_ishex
    test eax, eax
    jz .ffh_int_done
    inc r13
    inc rbx
    jmp .ffh_int_loop
.ffh_int_done:
    cmp byte [rbx], '.'
    jne .ffh_digits_end
    inc rbx
.ffh_frac_loop:
    cmp rbx, r12
    jae .ffh_digits_end
    movzx ecx, byte [rbx]
    call ffh_ishex
    test eax, eax
    jz .ffh_digits_end
    inc r13
    inc rbx
    jmp .ffh_frac_loop

.ffh_digits_end:
    mov rax, rbx
    sub rax, [rbp - FFH_DSTART]
    mov [rbp - FFH_DLEN], rax
    test r13, r13
    jz .ffh_bad                     ; at least one hex digit, anywhere

    ; The `p` exponent is OPTIONAL too, but if it is there it needs a digit:
    ; '0x1p' and '0x1p+' were both accepted as exponent zero.
    cmp rbx, r12
    jae .ffh_trailing_ws
    movzx ecx, byte [rbx]
    or cl, 0x20
    cmp cl, 'p'
    jne .ffh_trailing_ws
    inc rbx
    mov [rbp - FFH_ESTART], rbx
    cmp rbx, r12
    jae .ffh_bad
    movzx ecx, byte [rbx]
    cmp cl, '-'
    je .ffh_exp_sign
    cmp cl, '+'
    jne .ffh_exp_first
.ffh_exp_sign:
    inc rbx
.ffh_exp_first:
    cmp rbx, r12
    jae .ffh_bad
    movzx ecx, byte [rbx]
    sub ecx, '0'
    cmp ecx, 9
    ja .ffh_bad
.ffh_exp_loop:
    inc rbx
    cmp rbx, r12
    jae .ffh_exp_done
    movzx ecx, byte [rbx]
    sub ecx, '0'
    cmp ecx, 9
    jbe .ffh_exp_loop
.ffh_exp_done:
    mov rax, rbx
    sub rax, [rbp - FFH_ESTART]
    mov [rbp - FFH_ELEN], rax

.ffh_trailing_ws:
    cmp rbx, r12
    jae .ffh_consumed
    movzx ecx, byte [rbx]
    call ffh_isspace
    test eax, eax
    jz .ffh_bad                     ; trailing junk: '0x1p1zzz' was accepted
    inc rbx
    jmp .ffh_trailing_ws

.ffh_consumed:
    cmp qword [rbp - FFH_LIT], 0
    jne .ffh_finish                 ; inf or nan: no arithmetic to do

    ; Canonicalise for strtod: sign, "0x", the digit span verbatim, then "p"
    ; and either the exponent span or a zero.
    mov rdi, [rbp - FFH_DLEN]
    add rdi, [rbp - FFH_ELEN]
    add rdi, 16                     ; sign, "0x", 'p', "0", NUL, and slack
    call ap_malloc
    test rax, rax
    jz .ffh_nomem
    mov [rbp - FFH_BUF], rax
    mov r13, rax
    movzx eax, byte [rbp - FFH_SIGN]
    test al, al
    jz .ffh_no_sign
    mov [r13], al
    inc r13
.ffh_no_sign:
    mov byte [r13], '0'
    mov byte [r13 + 1], 'x'
    add r13, 2
    mov rdi, r13
    mov rsi, [rbp - FFH_DSTART]
    mov rdx, [rbp - FFH_DLEN]
    call ap_memcpy
    add r13, [rbp - FFH_DLEN]
    mov byte [r13], 'p'
    inc r13
    cmp qword [rbp - FFH_ELEN], 0
    jne .ffh_copy_exp
    mov byte [r13], '0'
    inc r13
    jmp .ffh_buf_done
.ffh_copy_exp:
    mov rdi, r13
    mov rsi, [rbp - FFH_ESTART]
    mov rdx, [rbp - FFH_ELEN]
    call ap_memcpy
    add r13, [rbp - FFH_ELEN]
.ffh_buf_done:
    mov byte [r13], 0

    mov rdi, [rbp - FFH_BUF]
    xor esi, esi                    ; no endptr: the span is already validated
    call strtod wrt ..plt
    movq [rbp - FFH_RES], xmm0
    mov rdi, [rbp - FFH_BUF]
    call ap_free
    mov qword [rbp - FFH_BUF], 0

    ; An infinity nobody spelled overflowed.
    mov rax, [rbp - FFH_RES]
    mov rcx, 0x7fffffffffffffff
    and rcx, rax
    mov rdx, 0x7ff0000000000000
    cmp rcx, rdx
    je .ffh_overflow

.ffh_finish:
    ; A subclass gets cls(result), as CPython's does.
    mov rax, [rbp - FFH_CLS]
    lea rcx, [rel float_type]
    cmp rax, rcx
    jne .ffh_wrap
    mov rax, [rbp - FFH_RES]
    mov edx, TAG_FLOAT
    V_PACK rax, rdx                 ; before the leave: its cold path is a call
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ffh_wrap:
    mov rax, [rbp - FFH_RES]
    mov edx, TAG_FLOAT
    V_PACK rax, rdx
    mov [rbp - FFH_RES], rax        ; the float as a Value, the one argument
    mov rdi, [rbp - FFH_CLS]
    lea rsi, [rbp - FFH_RES]
    mov edx, 1
    call obj_call_n
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ffh_nomem:
    RAISE exc_MemoryError_type, "out of memory"

.ffh_overflow:
    RAISE exc_OverflowError_type, "hexadecimal value too large to represent as a float"

.ffh_bad:
    mov rdi, [rbp - FFH_BUF]
    test rdi, rdi
    jz .ffh_bad_raise
    call ap_free
.ffh_bad_raise:
    RAISE exc_ValueError_type, "invalid hexadecimal floating-point string"
END_FUNC float_classmethod_fromhex

;; ============================================================================
;; float_classmethod_getformat(args, nargs) -> str
;; float.__getformat__('double') and ('float').
;;
;; CPython declares it METH_O|METH_CLASS, so args[0] is the class and args[1]
;; the type name.  Both answer the same thing here: x86-64 doubles and floats
;; are IEEE 754 and the machine is little-endian.  CPython 3.12 documents it
;; as being for its own test suite, which is exactly what wanted it -- one
;; line of test.support reads it, and every one of CPython's 406 test modules
;; imports test.support.
;; ============================================================================
DEF_FUNC float_classmethod_getformat, 8   ; 1 pushes, so rsp is 16-aligned
    push rbx

    mov rdi, [rdi + 8]              ; args[1]
    ; CPython's _PyArg_BadArgument names None as "None" and every other type by
    ; tp_name, so the \x01 composer -- which always answers tp_name, and is
    ; right to, since "'NoneType' object is not callable" is CPython's own
    ; wording elsewhere -- is one case short here.
    extern none_singleton
    lea rax, [rel none_singleton]
    cmp rdi, rax
    je .fgf_none
    CSTRING rsi, `__getformat__() argument must be str, not \x01`
    call str_require_str
    lea rbx, [rax + PyStrObject.data]

    mov rdi, rbx
    CSTRING rsi, "double"
    call ap_strcmp
    test eax, eax
    jz .fgf_ieee

    mov rdi, rbx
    CSTRING rsi, "float"
    call ap_strcmp
    test eax, eax
    jnz .fgf_bad

.fgf_ieee:
    CSTRING rdi, "IEEE, little-endian"
    call str_from_cstr
    pop rbx
    leave
    ret

.fgf_none:
    RAISE exc_TypeError_type, "__getformat__() argument must be str, not None"

.fgf_bad:
    RAISE exc_ValueError_type, "__getformat__() argument 1 must be 'double' or 'float'"
END_FUNC float_classmethod_getformat

;; ============================================================================
;; complex_method_conjugate(args, nargs) -> complex with the imaginary part
;; negated.
;; ============================================================================
DEF_FUNC complex_method_conjugate
    mov rdi, [rdi]              ; args[0] = self
    movsd xmm0, [rdi + PyComplexObject.cval_real]
    movsd xmm1, [rdi + PyComplexObject.cval_imag]
    xorpd xmm1, [rel cx_meth_signmask]
    extern complex_from_doubles
    call complex_from_doubles
    leave
    ret
END_FUNC complex_method_conjugate

;; ============================================================================
;; complex_method_complex(args, nargs) -> self.  complex.__complex__().
;; ============================================================================
DEF_FUNC complex_method_complex
    mov rdi, [rdi]
    push rdi
    extern obj_incref
    call obj_incref
    pop rax
    mov edx, TAG_PTR
    leave
    ret
END_FUNC complex_method_complex

;; ============================================================================
;; complex_method_getnewargs(args, nargs) -> (real, imag)
;; copyreg pickles a complex as `complex, (c.real, c.imag)`; pickle protocol 2
;; asks for this by name.
;; ============================================================================
CMG_SELF  equ 8
CMG_TUP   equ 16
CMG_FRAME equ 16            ; + 0 pushes = 16
DEF_FUNC complex_method_getnewargs, CMG_FRAME
    mov rdi, [rdi]
    mov [rbp - CMG_SELF], rdi
    mov edi, 2
    extern tuple_new
    call tuple_new
    mov [rbp - CMG_TUP], rax
    mov rcx, [rbp - CMG_SELF]
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rax, [rcx + PyComplexObject.cval_real]
    V_FROM_F64 rax, rsi
    mov [rdx], rax
    mov rax, [rcx + PyComplexObject.cval_imag]
    V_FROM_F64 rax, rsi
    mov [rdx + 8], rax
    mov rax, [rbp - CMG_TUP]
    mov edx, TAG_PTR
    leave
    ret
END_FUNC complex_method_getnewargs

;; ============================================================================
;; The names int and float were short of.  dir(int) was missing is_integer,
;; as_integer_ratio, __round__, __ceil__, __floor__ and __getnewargs__, and
;; dir(float) the last four -- so (5).is_integer() was an AttributeError, and
;; anything in the stdlib that classifies a number by asking for one of them
;; got the wrong answer about a builtin.
;;
;; Each is a thin wrapper over work that already exists.  __round__ IS
;; builtin_round_fn: a method's (args, nargs) is the same shape round()'s
;; own arguments arrive in, and round() reaches int and float natively rather
;; than through the dunder, so there is no recursion to worry about.
;; ============================================================================

;; int.__round__(self[, ndigits]) and float.__round__(self[, ndigits])
global int_method_round
DEF_FUNC_BARE int_method_round
    extern builtin_round_fn
    jmp builtin_round_fn
END_FUNC int_method_round

;; int.is_integer(self) -> True, always
global int_method_is_integer
NII_FRAME equ 16            ; + 0 pushes = 16
DEF_FUNC int_method_is_integer, NII_FRAME
    mov eax, 1
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC int_method_is_integer

;; int.as_integer_ratio(self) -> (self, 1)
global int_method_as_integer_ratio
NIR_SELF  equ 8
NIR_TUP   equ 16
NIR_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC int_method_as_integer_ratio, NIR_FRAME
    ; int_unwrap flattens bool and an int subclass, so True and I(5) answer
    ; with a plain int the way CPython's do.
    mov rdi, [rdi]
    V_UNPACK rdi, rdx
    extern int_unwrap
    call int_unwrap
    V_PACK rdi, rdx
    mov [rbp - NIR_SELF], rdi
    mov edi, 2
    extern tuple_new
    call tuple_new
    mov [rbp - NIR_TUP], rax
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rcx, [rbp - NIR_SELF]
    INCREF_V rcx, rsi
    mov [rdx], rcx
    mov rcx, V_INT(1)
    mov [rdx + 8], rcx
    mov rax, [rbp - NIR_TUP]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC int_method_as_integer_ratio

;; int.__floor__(self) / int.__ceil__(self) / int.__trunc__(self) -> self
global int_method_identity
NID_FRAME equ 16            ; + 0 pushes = 16
DEF_FUNC int_method_identity, NID_FRAME
    mov rdi, [rdi]
    V_UNPACK rdi, rdx
    call int_unwrap
    V_PACK rdi, rdx
    mov rax, rdi
    INCREF_V rax, rcx
    leave
    ret
END_FUNC int_method_identity

;; int.__getnewargs__(self) -> (self,)
global int_method_getnewargs
NGA_SELF  equ 8
NGA_TUP   equ 16
NGA_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC int_method_getnewargs, NGA_FRAME
    mov rdi, [rdi]
    V_UNPACK rdi, rdx
    call int_unwrap
    V_PACK rdi, rdx
    mov [rbp - NGA_SELF], rdi
    mov edi, 1
    call tuple_new
    mov [rbp - NGA_TUP], rax
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rcx, [rbp - NGA_SELF]
    INCREF_V rcx, rsi
    mov [rdx], rcx
    mov rax, [rbp - NGA_TUP]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC int_method_getnewargs

;; float.__getnewargs__(self) -> (float(self),)
;; A subclass answers with a plain float: F(2.5).__getnewargs__() is (2.5,).
global float_method_getnewargs
DEF_FUNC float_method_getnewargs, NGA_FRAME
    mov rdi, [rdi]
    call float_self_bits
    V_FROM_F64 rax, rcx
    mov [rbp - NGA_SELF], rax
    mov edi, 1
    call tuple_new
    mov [rbp - NGA_TUP], rax
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rcx, [rbp - NGA_SELF]
    mov [rdx], rcx
    mov rax, [rbp - NGA_TUP]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC float_method_getnewargs

;; float.__floor__(self) and float.__ceil__(self) -> int
;;
;; The same work math.floor and math.ceil do for a float: round the double the
;; right way and hand it to float_int, which knows about the infinities, NaN
;; and the values that need GMP.  It has to be the same work: adding these
;; names newly routes a float SUBCLASS instance through the dunder in
;; MATH_ROUNDER, which reaches its native arm only for an immediate.
global float_method_floor
DEF_FUNC float_method_floor
    mov rdi, [rdi]
    call float_self_bits
    movq xmm0, rax
    roundsd xmm0, xmm0, 1       ; toward -inf
    jmp float_method_to_int
END_FUNC float_method_floor

global float_method_ceil
DEF_FUNC float_method_ceil
    mov rdi, [rdi]
    call float_self_bits
    movq xmm0, rax
    roundsd xmm0, xmm0, 2       ; toward +inf
    jmp float_method_to_int
END_FUNC float_method_ceil

;; The tail both share.  Not a DEF_FUNC: it inherits its caller's frame and
;; returns through its caller's leave.
float_method_to_int:
    movq rdi, xmm0
    V_FROM_F64 rdi, rax
    extern float_int
    call float_int
    leave
    ret


section .rodata
align 16
cx_meth_signmask: dq 0x8000000000000000, 0x8000000000000000
section .text
