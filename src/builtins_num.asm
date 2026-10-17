; builtins_num.asm - The numeric builtins
;
; abs, divmod, int(), bool(), float(), ord, chr, hex, bin, oct, round, pow.
; Each: name(PyObject **args, int64_t nargs) -> PyObject*, args borrowed,
; return a new reference.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

extern complex_to_parts
extern obj_incref
extern complex_from_doubles
extern complex_type

; External symbols used
extern int_to_i64
extern obj_as_index
extern int_base_str
extern int_is_integer
extern __gmpz_fits_slong_p
extern int_neg
extern int_from_cstr_base
extern float_from_f64
extern float_int
extern ap_malloc
extern ap_free
extern ap_memcpy
extern strlen
extern str_new
extern str_from_cstr
extern str_from_cstr_heap
extern obj_repr
extern obj_decref
extern raise_exception
extern exc_new
extern eval_exception_unwind
extern int_promote_mpz

extern int_type
extern float_type
extern builtin_bool
extern builtin_float
extern str_type
extern bool_type
extern bool_true
extern bool_false

extern exc_TypeError_type
extern exc_ValueError_type
extern dunder_lookup
extern builtin_int_fn
extern ap_strcmp

;; ============================================================================
;; 1. builtin_abs(args, nargs) - abs(x)
;; ============================================================================

; --- moved to a sibling file by the split ---

section .text

DEF_FUNC builtin_abs
    push rbx
    sub rsp, 8

    cmp rsi, 1
    jne .abs_error

    mov rbx, [rdi]

    V_TEST_INT_M [rdi], r11      ; args[0] an int immediate?
    jae .abs_smallint

    V_TEST_F64_M [rdi], r11      ; args[0] a float?
    jbe .abs_inline_float

    V_TEST_PTR_M [rdi], r11      ; args[0] a pointer?
    ja .abs_type_error

    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel float_type]
    cmp rax, rcx
    je .abs_float

    lea rcx, [rel int_type]
    cmp rax, rcx
    je .abs_gmp_check

    ; Check bool_type (bool singletons: payload is 0 or 1 in mpz)
    extern bool_type
    lea rcx, [rel bool_type]
    cmp rax, rcx
    je .abs_bool

    ; Anything else goes through the numeric protocol, which now carries
    ; __abs__ for a user class.  abs(obj) used to be a flat TypeError.
    mov rcx, [rax + PyTypeObject.tp_as_number]
    test rcx, rcx
    jz .abs_type_error
    mov rcx, [rcx + PyNumberMethods.nb_absolute]
    test rcx, rcx
    jz .abs_type_error
    mov rdi, rbx                ; a pointer is its own Value
    call rcx
    V_UNPACK rax, rdx
    add rsp, 8
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.abs_bool:
    ; Bool singleton: check if True (mpz=1) or False (mpz=0), both non-negative
    ; Return as SmallInt: True.abs = 1, False.abs = 0
    extern bool_true
    lea rcx, [rel bool_true]
    xor eax, eax
    cmp rbx, rcx
    sete al                    ; rax = 1 if True, 0 if False
    RET_TAG_SMALLINT
    add rsp, 8
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.abs_gmp_check:

    ; GMP int: check _mp_size at PyIntObject.mpz + 4
    INT_NEED_MPZ rbx
    mov eax, [rbx + PyIntObject.mpz + 4]
    test eax, eax
    jl .abs_gmp_neg

    inc qword [rbx + PyObject.ob_refcnt]
    mov rax, rbx
    mov edx, TAG_PTR
    add rsp, 8
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.abs_gmp_neg:
    mov rdi, rbx               ; a heap int pointer is its own Value
    call int_neg
    V_UNPACK rax, rdx           ; int_neg returns a Value
    add rsp, 8
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.abs_smallint:
    mov rax, rbx
    V_TO_I64 rax
    test rax, rax
    jns .abs_si_pos
    neg rax
.abs_si_pos:
    RET_TAG_SMALLINT
    add rsp, 8
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.abs_bool_tag:
    ; TAG_BOOL: payload is 0 or 1, already non-negative → return as SmallInt
    mov rax, rbx
    RET_TAG_SMALLINT
    add rsp, 8
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.abs_inline_float:
    ; A float immediate: clear the sign bit inline
    V_TO_F64 rbx
    btr rbx, 63
    mov rax, rbx
    mov edx, TAG_FLOAT
    add rsp, 8
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.abs_float:
    movsd xmm0, [rbx + PyFloatObject.value]
    mov rax, 0x7fffffffffffffff
    movq xmm1, rax
    andpd xmm0, xmm1
    call float_from_f64
    add rsp, 8
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.abs_type_error:
    mov rsi, rbx
    CSTRING rdi, `bad operand type for abs(): '\x01'`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.abs_error:
    CSTRING rdx, " given)"
    CSTRING rdi, "abs() takes exactly one argument ("
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_abs

;; ============================================================================
;; builtin_divmod(args, nargs) - divmod(a, b) -> (a // b, a % b)
;; ============================================================================
DM_QTAG equ 8               ; the quotient's tag, across the remainder's call
DM_FRAME equ 8              ; + 5 pushes = 48, 16-aligned.  DM_QTAG is a frame
                            ; slot and not a `push` because a push here flips
                            ; the parity for the whole remainder half of the
                            ; body -- and nb_remainder for an int is int_mod,
                            ; which calls GMP.  157 of the misaligned GMP
                            ; calls in the tree arrived through here.
DEF_FUNC builtin_divmod, DM_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    cmp rsi, 2
    jne .divmod_error

    mov rbx, [rdi]              ; args[0] = a
    V_UNPACK rbx, r13
    mov r12, [rdi + 8]          ; args[1] = b
    V_UNPACK r12, r14

    ; nb_divmod first, where the type has one.  Building the pair out of //
    ; and % is only a stand-in for types that do not define __divmod__, and
    ; it answered ('floordiv', 'mod') for a class that did -- calling two
    ; methods the program had written for other operators and never the one
    ; it had written for this.  No builtin here fills nb_divmod, so this arm
    ; exists for classes, which reach it through the slot wrapper.
    mov rdi, rbx
    mov edx, r13d
    extern value_number_methods
    call value_number_methods
    test rax, rax
    jz .divmod_type_error
    mov rax, [rax + PyNumberMethods.nb_divmod]
    test rax, rax
    jz .divmod_no_slot
    mov rdi, rbx
    mov edx, r13d
    mov rsi, r12
    mov ecx, r14d
    V_PACK rdi, rdx
    V_PACK rsi, rcx
    call rax
    test rax, rax
    jz .divmod_no_slot          ; declined: fall back to // and %
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.divmod_no_slot:
    ; A zero float divisor is diagnosed here rather than left to the two
    ; slots below.  divmod(1.0, 0.0) is "float divmod()" in CPython, and
    ; reaching it through nb_floor_divide reported the floor division's own
    ; message instead.
    mov rdi, r12
    mov esi, r14d
    call divmod_is_zero
    test eax, eax
    jz .divmod_no_float_zero
    mov rdi, rbx
    mov esi, r13d
    call divmod_is_float
    test eax, eax
    jnz .divmod_float_zero
    mov rdi, r12
    mov esi, r14d
    call divmod_is_float
    test eax, eax
    jnz .divmod_float_zero
.divmod_no_float_zero:

    ; Dispatch through the left operand's numeric protocol, the way the //
    ; and % operators do.  This used to call int_floordiv unconditionally,
    ; so divmod(1.5, 1.5) handed raw f64 bits to integer code.
    mov rdi, rbx
    mov edx, r13d
    call value_number_methods
    test rax, rax
    jz .divmod_type_error
    mov rax, [rax + PyNumberMethods.nb_floor_divide]
    test rax, rax
    jz .divmod_type_error

    mov rdi, rbx
    mov edx, r13d
    mov rsi, r12
    mov ecx, r14d
    V_PACK rdi, rdx
    V_PACK rsi, rcx
    call rax
    ; A slot may decline: this branch taught int_floordiv and int_mod to
    ; answer NULL for a non-int operand, and op_binary_op to fall back on the
    ; other operand's slot.  divmod() is the other direct caller and was not
    ; taught, so the NULL went into the result tuple and `divmod(7, 2.0)`
    ; produced an object with no repr instead of (3.0, 1.0).
    test rax, rax
    jnz .divmod_have_quot
    mov rdi, r12
    mov edx, r14d
    call value_number_methods   ; the RIGHT operand's, as the reflected op
    test rax, rax
    jz .divmod_type_error
    mov rax, [rax + PyNumberMethods.nb_floor_divide]
    test rax, rax
    jz .divmod_type_error
    mov rdi, rbx
    mov edx, r13d
    mov rsi, r12
    mov ecx, r14d
    V_PACK rdi, rdx
    V_PACK rsi, rcx
    call rax
    test rax, rax
    jz .divmod_type_error
.divmod_have_quot:
    V_UNPACK rax, rdx           ; int_floordiv returns a Value
    mov r15, rax                ; r15 = quotient payload
    mov [rbp - DM_QTAG], rdx   ; save quotient tag

    ; Same for the remainder.
    mov rdi, rbx
    mov edx, r13d
    call value_number_methods
    test rax, rax
    jz .divmod_type_error
    mov rax, [rax + PyNumberMethods.nb_remainder]
    test rax, rax
    jz .divmod_type_error

    mov rdi, rbx
    mov edx, r13d
    mov rsi, r12
    mov ecx, r14d
    V_PACK rdi, rdx
    V_PACK rsi, rcx
    call rax
    test rax, rax
    jnz .divmod_have_rem
    mov rdi, r12
    mov edx, r14d
    call value_number_methods
    test rax, rax
    jz .divmod_pop_type_error
    mov rax, [rax + PyNumberMethods.nb_remainder]
    test rax, rax
    jz .divmod_pop_type_error
    mov rdi, rbx
    mov edx, r13d
    mov rsi, r12
    mov ecx, r14d
    V_PACK rdi, rdx
    V_PACK rsi, rcx
    call rax
    test rax, rax
    jz .divmod_pop_type_error
.divmod_have_rem:
    V_UNPACK rax, rdx           ; int_mod returns a Value
    mov r12, rax                ; r12 = remainder payload
    mov r13, rdx                ; r13 = remainder tag

    ; Create 2-tuple (quotient, remainder)
    mov edi, 2
    extern tuple_new
    call tuple_new
    mov rbx, [rax + PyTupleObject.ob_item]
    mov rcx, [rbp - DM_QTAG]                     ; quotient tag
    V_PACK r15, rcx
    mov [rbx], r15
    V_PACK r12, r13
    mov [rbx + 8], r12
    mov edx, TAG_PTR

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.divmod_error:
    CSTRING rdi, "divmod expected 2 arguments, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted

.divmod_pop_type_error:
.divmod_type_error:
    ; Name both operands, as CPython does: with two of them, "unsupported"
    ; alone does not say which.
    mov rdi, rbx
    mov edx, r13d
    V_PACK rdi, rdx
    mov rsi, r12
    mov ecx, r14d
    V_PACK rsi, rcx
    CSTRING rdx, "unsupported operand type(s) for divmod()"
    call raise_binop_type_error
.divmod_float_zero:
    extern exc_ZeroDivisionError_type
    RAISE exc_ZeroDivisionError_type, "float divmod()"
END_FUNC builtin_divmod

;; ============================================================================
;; divmod_is_float(rdi = payload, esi = tag) -> eax = 1 for a float or a
;; float subclass instance
;; divmod_is_zero(rdi = payload, esi = tag)  -> eax = 1 for a zero int or float
;;
;; divmod(1.5, 0) is "float divmod()" in CPython even though the divisor is an
;; int, so the two questions are asked separately: is the divisor zero, and is
;; either operand a float.
;; ============================================================================
DEF_FUNC_LOCAL divmod_is_float
    cmp esi, TAG_FLOAT
    je .dif_yes
    cmp esi, TAG_PTR
    jne .dif_no
    lea rax, [rel float_type]
    cmp [rdi + PyObject.ob_type], rax
    je .dif_yes
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_FLOAT_SUBCLASS
    jz .dif_no
.dif_yes:
    mov eax, 1
    leave
    ret
.dif_no:
    xor eax, eax
    leave
    ret
END_FUNC divmod_is_float

DEF_FUNC_LOCAL divmod_is_zero
    cmp esi, TAG_SMALLINT
    je .diz_int
    cmp esi, TAG_FLOAT
    je .diz_raw
    cmp esi, TAG_PTR
    jne .diz_no
    lea rax, [rel float_type]
    cmp [rdi + PyObject.ob_type], rax
    je .diz_obj
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_FLOAT_SUBCLASS
    jnz .diz_obj
    jmp .diz_no                 ; a heap int is never zero: it would be compact
.diz_obj:
    movsd xmm0, [rdi + PyFloatObject.value]
    jmp .diz_test
.diz_raw:
    movq xmm0, rdi
.diz_test:
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    jp .diz_no
    jne .diz_no
    mov eax, 1
    leave
    ret
.diz_int:
    test rdi, rdi
    jnz .diz_no
    mov eax, 1
    leave
    ret
.diz_no:
    xor eax, eax
    leave
    ret
END_FUNC divmod_is_zero

; tp_call wrappers: shift (type, args, nargs) → (args, nargs)
global int_type_call
ITC_FRAME  equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC int_type_call, ITC_FRAME
    ; rdi=type, rsi=args, rdx=nargs
    mov rdi, rsi
    mov rsi, rdx
    ; Check for keyword args
    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jz .itc_no_kw
    ; Have keyword args — get count
    mov rcx, [rax + PyTupleObject.ob_size]   ; n_kw
    mov r8, rsi
    sub r8, rcx                               ; n_pos = nargs - n_kw
    ; Check each keyword name
    xor r9d, r9d                              ; index
.itc_kw_loop:
    cmp r9, rcx
    jge .itc_kw_checked
    mov r10, [rax + PyTupleObject.ob_item]        ; kw names payloads
    mov r10, [r10 + r9*8]                          ; kw name str
    ; Compare to "base"
    push rdi
    push rsi
    push rcx
    push rax
    push r8
    push r9
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "base"
    call ap_strcmp
    mov r11d, eax               ; save strcmp result
    pop r9
    pop r8
    pop rax
    pop rcx
    pop rsi
    pop rdi
    test r11d, r11d
    jnz .itc_kw_reject          ; not "base" → reject
    inc r9
    jmp .itc_kw_loop
.itc_kw_checked:
    ; All keywords are "base". Validate: need exactly 1 positional + 1 keyword
    cmp rcx, 1
    jne .itc_kw_reject
    cmp r8, 1
    jne .itc_kw_no_pos          ; base= without positional string → TypeError
    ; Good: int('str', base=N) — args are already [str, base], nargs=2
    ; Clear kw_names_pending (we consumed it)
    mov qword [gs:ThreadState.kw_names_pending], 0
    leave
    jmp builtin_int_fn
.itc_kw_no_pos:
    test r8, r8
    jne .itc_kw_reject
    RAISE exc_TypeError_type, "int() missing string argument"
.itc_kw_reject:
    RAISE exc_TypeError_type, "'x' is an invalid keyword argument for int()"
.itc_no_kw:
    leave
    jmp builtin_int_fn
END_FUNC int_type_call

DEF_FUNC_BARE bool_type_call
    ; Check for kwargs — bool() doesn't accept keyword arguments
    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jnz .bool_kwargs_error
    mov rdi, rsi
    mov rsi, rdx
    jmp builtin_bool
.bool_kwargs_error:
    mov qword [gs:ThreadState.kw_names_pending], 0
    extern exc_TypeError_type
    extern raise_exception
    RAISE exc_TypeError_type, "bool() takes no keyword arguments"
END_FUNC bool_type_call

;; float_type_call(rdi = type, rsi = args, rdx = nargs) -> a fat pair
;;
;; The type argument used to be discarded, so `class F(float)` produced a
;; plain float: the subclass name was lost and its __init__ never ran.  int
;; and str were right because their family flag routes type_call elsewhere;
;; float and complex had neither the flag nor a constructor that read rdi.
FTC_TYPE  equ 8
FTC_BITS  equ 16
FTC_FRAME equ 16            ; + 0 pushes = 16
extern builtin_sub_alloc

DEF_FUNC float_type_call, FTC_FRAME
    NO_KEYWORDS "float() takes no keyword arguments"
    mov [rbp - FTC_TYPE], rdi
    mov rdi, rsi
    mov rsi, rdx
    call builtin_float          ; rax = raw double bits, edx = TAG_FLOAT
    lea rcx, [rel float_type]
    cmp [rbp - FTC_TYPE], rcx
    je .ftc_out                 ; float() itself: the immediate is the answer
    test edx, edx
    jz .ftc_out                 ; it raised

    ; A subclass instance carries the double where float_to_f64 reads it,
    ; at the base's own offset.  Returning a pointer here is what lets
    ; type_call's two callers agree: .not_type_self packs the fat pair and
    ; .nnf_check_base_new unpacks it as a Value, and only a pointer means
    ; the same thing to both.
    mov [rbp - FTC_BITS], rax
    mov rdi, [rbp - FTC_TYPE]
    call builtin_sub_alloc
    mov rcx, [rbp - FTC_BITS]
    mov [rax + PyFloatObject.value], rcx
    mov edx, TAG_PTR
.ftc_out:
    leave
    ret
END_FUNC float_type_call

;; ============================================================================
;; 2. int() -- moved to a sibling file by the split
;; ============================================================================

;; ============================================================================
;; 4. builtin_ord(args, nargs) - ord(c)
;; ============================================================================
ORD_ARG   equ 8             ; args[0] as it arrived, for both refusals
ORD_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC builtin_ord, ORD_FRAME

    cmp rsi, 1
    jne .ord_nargs_error

    mov rax, [rdi]
    mov [rbp - ORD_ARG], rax
    V_TEST_PTR rax, r11          ; args[0] a pointer?
    ja .ord_type_error
    test rax, rax
    jz .ord_type_error

    mov rdi, rax                   ; args[0] payload

    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .ord_is_str
    ; bytes and bytearray are one byte each in CPython's ord(), and were a
    ; TypeError here: `ord(b"x")` is 120 there and refused by name here.
    extern bytes_type
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .ord_bytes
    extern bytearray_type
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .ord_bytearray
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jnz .ord_is_str
    jmp .ord_type_error

.ord_bytes:
    mov rcx, [rdi + PyBytesObject.ob_size]
    cmp rcx, 1
    jne .ord_len_error
    movzx eax, byte [rdi + PyBytesObject.data]
    jmp .ord_done

.ord_bytearray:
    mov rcx, [rdi + PyByteArrayObject.ob_size]
    cmp rcx, 1
    jne .ord_len_error
    mov rax, [rdi + PyByteArrayObject.ob_bytes]
    movzx eax, byte [rax]
    jmp .ord_done

.ord_is_str:

    ; A string is stored as UTF-8, so one character can be up to four bytes.
    ; Requiring ob_size == 1 made ord(chr(233)) a TypeError.
    mov rcx, [rdi + PyStrObject.ob_size]
    test rcx, rcx
    jz .ord_len_error
    movzx eax, byte [rdi + PyStrObject.data]
    test al, 0x80
    jz .ord_ascii
    ; Multi-byte: decode and check it is the whole string.
    mov r8d, eax
    and r8d, 0xf8
    cmp r8d, 0xf0
    je .ord_four
    mov r8d, eax
    and r8d, 0xf0
    cmp r8d, 0xe0
    je .ord_three
    mov r8d, eax
    and r8d, 0xe0
    cmp r8d, 0xc0
    jne .ord_len_error
    cmp rcx, 2
    jne .ord_len_error
    and eax, 0x1f
    shl eax, 6
    movzx edx, byte [rdi + PyStrObject.data + 1]
    and edx, 0x3f
    or eax, edx
    jmp .ord_done
.ord_three:
    cmp rcx, 3
    jne .ord_len_error
    and eax, 0x0f
    shl eax, 12
    movzx edx, byte [rdi + PyStrObject.data + 1]
    and edx, 0x3f
    shl edx, 6
    or eax, edx
    movzx edx, byte [rdi + PyStrObject.data + 2]
    and edx, 0x3f
    or eax, edx
    jmp .ord_done
.ord_four:
    cmp rcx, 4
    jne .ord_len_error
    and eax, 0x07
    shl eax, 18
    movzx edx, byte [rdi + PyStrObject.data + 1]
    and edx, 0x3f
    shl edx, 12
    or eax, edx
    movzx edx, byte [rdi + PyStrObject.data + 2]
    and edx, 0x3f
    shl edx, 6
    or eax, edx
    movzx edx, byte [rdi + PyStrObject.data + 3]
    and edx, 0x3f
    or eax, edx
    jmp .ord_done
.ord_ascii:
    cmp rcx, 1
    jne .ord_len_error
.ord_done:
    RET_TAG_SMALLINT
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.ord_type_error:
    mov rsi, [rbp - ORD_ARG]
    CSTRING rdi, `ord() expected string of length 1, but \x01 found`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.ord_len_error:
    ; CPython counts CODE POINTS for a str and bytes for the other two, and
    ; says how many it got: "expected a character, but string of length 2".
    mov rdi, [rbp - ORD_ARG]
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .ord_len_bytes
    mov rsi, [rdi + PyStrObject.ob_length]
    jmp .ord_len_raise
.ord_len_bytes:
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    jne .ord_len_size
    mov rsi, [rdi + PyByteArrayObject.ob_size]
    jmp .ord_len_raise
.ord_len_size:
    mov rsi, [rdi + PyBytesObject.ob_size]
.ord_len_raise:
    CSTRING rdx, " found"
    CSTRING rdi, "ord() expected a character, but string of length "
    extern raise_type_error_counted
    jmp raise_type_error_counted

.ord_nargs_error:
    CSTRING rdx, " given)"
    CSTRING rdi, "ord() takes exactly one argument ("
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_ord

;; ============================================================================
;; 5. builtin_chr(args, nargs) - chr(n)
;; ============================================================================
BC_BUF    equ 16            ; up to four UTF-8 bytes, then a NUL
DEF_FUNC builtin_chr, 16

    cmp rsi, 1
    jne .chr_nargs_error

    mov rdi, [rdi]            ; args[0]

    ; int_to_i64 reads PyIntObject.compact off whatever it is handed, so
    ; chr(1.5) dereferenced a float's raw bits and chr(2**70) truncated
    ; through __gmpz_get_si and answered a character.  obj_as_index is the
    ; funnel: it names the type, it takes anything with an __index__, and it
    ; refuses what will not fit an index.
    ; ...and a width that will not fit is CPython's "C int" here, not the
    ; "C ssize_t" a subscript reports: chr takes an int, not an index.  Only
    ; a heap int can be that wide, and obj_as_index below refuses everything
    ; that is not a number at all.
    V_TEST_PTR rdi, rax
    ja .chr_have_value
    test rdi, rdi
    jz .chr_have_value
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    jne .chr_have_value
    push rdi
    mov edx, TAG_PTR
    extern int_fits_i64
    call int_fits_i64
    pop rdi
    test eax, eax
    jz .chr_too_wide
.chr_have_value:
    V_UNPACK rdi, rdx
    extern obj_as_index
    call obj_as_index

    cmp rax, 0x7fffffff
    jg .chr_too_wide
    cmp rax, -0x80000000
    jl .chr_too_wide
    test rax, rax
    jl .chr_range_error
    cmp rax, 0x10ffff
    ja .chr_range_error

    ; Single byte (ASCII)
    cmp rax, 0x7f
    ja .chr_utf8_encode

    ; str_new, not str_from_cstr: chr(0) is a one-character string holding a
    ; NUL, and measuring it with strlen made it empty.
    mov byte [rbp - BC_BUF], al
    mov byte [rbp - BC_BUF + 1], 0
    lea rdi, [rbp - BC_BUF]
    mov esi, 1
    call str_new
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.chr_utf8_encode:
    cmp rax, 0x7ff
    ja .chr_3byte

    ; 2-byte: 110xxxxx 10xxxxxx
    mov rcx, rax
    shr rcx, 6
    or cl, 0xc0
    mov byte [rbp - BC_BUF], cl
    mov rcx, rax
    and cl, 0x3f
    or cl, 0x80
    mov byte [rbp - BC_BUF + 1], cl
    mov byte [rbp - BC_BUF + 2], 0
    lea rdi, [rbp - BC_BUF]
    mov esi, 2
    call str_new                ; str_new, so U+0080..U+00FF share one object
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.chr_3byte:
    cmp rax, 0xffff
    ja .chr_4byte

    ; 3-byte: 1110xxxx 10xxxxxx 10xxxxxx
    mov rcx, rax
    shr rcx, 12
    or cl, 0xe0
    mov byte [rbp - BC_BUF], cl
    mov rcx, rax
    shr rcx, 6
    and cl, 0x3f
    or cl, 0x80
    mov byte [rbp - BC_BUF + 1], cl
    mov rcx, rax
    and cl, 0x3f
    or cl, 0x80
    mov byte [rbp - BC_BUF + 2], cl
    mov byte [rbp - BC_BUF + 3], 0
    lea rdi, [rbp - BC_BUF]
    call str_from_cstr
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.chr_4byte:
    ; 4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
    mov rcx, rax
    shr rcx, 18
    or cl, 0xf0
    mov byte [rbp - BC_BUF], cl
    mov rcx, rax
    shr rcx, 12
    and cl, 0x3f
    or cl, 0x80
    mov byte [rbp - BC_BUF + 1], cl
    mov rcx, rax
    shr rcx, 6
    and cl, 0x3f
    or cl, 0x80
    mov byte [rbp - BC_BUF + 2], cl
    mov rcx, rax
    and cl, 0x3f
    or cl, 0x80
    mov byte [rbp - BC_BUF + 3], cl
    mov byte [rbp - BC_BUF + 4], 0
    lea rdi, [rbp - BC_BUF]
    call str_from_cstr
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.chr_too_wide:
    extern exc_OverflowError_type
    RAISE exc_OverflowError_type, "Python int too large to convert to C int"
.chr_range_error:
    RAISE exc_ValueError_type, "chr() arg not in range(0x110000)"

.chr_nargs_error:
    CSTRING rdx, " given)"
    CSTRING rdi, "chr() takes exactly one argument ("
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_chr

;; ============================================================================
;; 6. builtin_hex(args, nargs) - hex(n)
;; ============================================================================
HEXB_VAL   equ 8
HEXB_STR   equ 16
HEXB_OUT   equ 24
HEXB_FRAME equ 32           ; + 2 pushes = 48
DEF_FUNC builtin_hex, HEXB_FRAME
    push rbx
    push r12
    cmp rsi, 1
    jne .hex_nargs_error

    ; obj_as_index truncates a value too wide for int64, so builtin_hex(2**70)
    ; came out as "0x0".  It is still what validates the argument and
    ; honours __index__; int_base_str renders any width through GMP.
    mov rdi, [rdi]
    mov [rbp - HEXB_VAL], rdi
    V_UNPACK rdi, rdx
    call int_is_integer
    test eax, eax
    jnz .hex_have_value
    mov rdi, [rbp - HEXB_VAL]
    call obj_as_index
    mov rdx, TAG_SMALLINT
    V_PACK rax, rdx
    mov [rbp - HEXB_VAL], rax
.hex_have_value:
    mov rdi, [rbp - HEXB_VAL]
    mov esi, 16
    xor edx, edx
    call int_base_str
    mov [rbp - HEXB_STR], rax

    mov rbx, rax
    cmp byte [rbx], '-'
    jne .hex_positive
    inc rbx
.hex_positive:
    xor ecx, ecx
.hex_len:
    cmp byte [rbx + rcx], 0
    je .hex_have_len
    inc rcx
    jmp .hex_len
.hex_have_len:
    mov r12, rcx
    lea rdi, [rcx + 8]
    call ap_malloc
    mov [rbp - HEXB_OUT], rax
    xor edx, edx
    mov r8, [rbp - HEXB_STR]
    cmp byte [r8], '-'
    jne .hex_no_sign
    mov byte [rax], '-'
    mov edx, 1
.hex_no_sign:
    mov byte [rax + rdx], '0'
    mov byte [rax + rdx + 1], 'x'
    add rdx, 2
    xor r9d, r9d
.hex_copy:
    cmp r9, r12
    jge .hex_copied
    mov r10b, [rbx + r9]
    mov [rax + rdx], r10b
    inc rdx
    inc r9
    jmp .hex_copy
.hex_copied:
    mov byte [rax + rdx], 0

    mov rdi, [rbp - HEXB_STR]
    call ap_free
    mov rdi, [rbp - HEXB_OUT]
    call str_from_cstr
    mov rbx, rax
    mov r12, rdx
    mov rdi, [rbp - HEXB_OUT]
    call ap_free
    mov rax, rbx
    mov rdx, r12
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.hex_nargs_error:
    CSTRING rdx, " given)"
    CSTRING rdi, "hex() takes exactly one argument ("
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_hex

; builtin_eval_fn used to live here: a stub that parsed a single integer
; literal and raised ValueError for anything else.  It is now a real
; evaluator in compiler/evalexec.asm, backed by the source compiler.

;; ============================================================================
;; builtin_round_fn(args, nargs) - round(number[, ndigits])
;;
;; Every arm of this used to round with cvtsd2si, which answers the integer
;; INDEFINITE value -- 0x8000000000000000 -- for anything outside int64 and
;; reports nothing about it.  round(1e300), round(inf) and round(nan) were
;; all -9223372036854775808.  float_int had already learned this lesson for
;; int(); round() had not, and the two-argument arm had three more of its
;; own: 10**ndigits was an int64 that wrapped at ndigits >= 19 and looped 400
;; times for round(x, 400), x * 10**n overflowed to infinity for a large x,
;; and the cvtsd2si/cvtsi2sd round trip lost the sign of -0.0.
;;
;; The float work is float_round_ndigits (src/pyo/float.asm), which rounds
;; the decimal representation the way CPython's double_round does rather than
;; the scaled binary value.  The int work is GMP's, so round(10**30, -5) is
;; an answer rather than "type cannot be rounded".
;; ============================================================================

extern float_round_ndigits
extern int_fits_i64
extern int_shrink
extern __gmpz_init
extern __gmpz_set_si
extern __gmpz_ui_pow_ui
extern __gmpz_tdiv_qr
extern __gmpz_mul
extern __gmpz_add
extern __gmpz_sub
extern __gmpz_cmp
extern __gmpz_cmpabs
extern __gmpz_mul_2exp
extern __gmpz_cmp_si
extern __gmpz_set
extern __gmpz_powm
extern __gmpz_invert
extern __gmpz_neg
extern __gmpz_clear
extern __gmpz_tdiv_q_ui

global builtin_round_fn
RND_X      equ 8              ; x payload
RND_XTAG   equ 16             ; x tag
RND_ND     equ 24             ; ndigits as int64
RND_SAVE   equ 32             ; scratch across a call
RND_FRAME  equ 56            ; + 1 push = 64, 16-aligned
DEF_FUNC builtin_round_fn, RND_FRAME
    push rbx

    cmp rsi, 1
    je .rnd_one_arg
    cmp rsi, 2
    je .rnd_two_arg
    jmp .rnd_error

.rnd_one_arg:
    ; round(x) -> int.  int_unwrap flattens bool, compact heap ints and int
    ; subclasses to (value, TAG_SMALLINT); a genuinely large int stays a
    ; pointer and is returned as itself.
    extern int_unwrap
    mov rdi, [rdi]              ; args[0]
    V_UNPACK rdi, rdx
    call int_unwrap
    mov [rbp - RND_X], rdi
    mov [rbp - RND_XTAG], rdx

    cmp edx, TAG_SMALLINT
    je .rnd_int_identity

    mov rdi, [rbp - RND_X]
    mov esi, [rbp - RND_XTAG]
    call round_self_double      ; -> xmm0, eax = 1 when it was a float
    test eax, eax
    jz .rnd_one_not_float

    ; Round to nearest, ties to even -- what cvtsd2si was providing -- and
    ; hand the result to float_int, which knows about NaN, the infinities and
    ; the values that need GMP.
    roundsd xmm0, xmm0, 0
    movq rdi, xmm0
    V_FROM_F64 rdi, rax
    extern float_int
    call float_int
    pop rbx
    leave
    ret

.rnd_one_not_float:
    ; A heap int is its own answer.  It used to go through int_to_i64, which
    ; truncates: round(10**30) came back as garbage.
    mov rdi, [rbp - RND_X]
    cmp qword [rbp - RND_XTAG], TAG_PTR
    jne .rnd_one_dunder
    lea rax, [rel int_type]
    cmp [rdi + PyObject.ob_type], rax
    jne .rnd_one_dunder
    INCREF rdi
    mov rax, rdi
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.rnd_int_identity:
    mov rax, [rbp - RND_X]
    mov edx, TAG_SMALLINT
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.rnd_one_dunder:
    ; Anything else is asked for __round__, which is how round() works on a
    ; Decimal, a Fraction or any class that defines it.
    mov rdi, [rbp - RND_X]
    mov edx, [rbp - RND_XTAG]
    V_PACK rdi, rdx
    CSTRING rsi, "__round__"
    extern dunder_call_1
    call dunder_call_1
    test rax, rax               ; dunder_call_1 answers with a Value; 0 is absent-or-raised
    jz .rnd_type_error          ; no __round__, or it raised
    ; Already a Value.  The guard above was converted and this was not, so
    ; `class M(list): __round__ = list.__len__` answered 2^50 out.
    pop rbx
    leave
    ret

.rnd_two_arg:
    extern int_unwrap
    mov rbx, rdi                ; args array
    mov rdi, [rbx]
    V_UNPACK rdi, rdx
    call int_unwrap
    mov [rbp - RND_X], rdi
    mov [rbp - RND_XTAG], rdx

    mov rdi, [rbx + 8]
    V_UNPACK rdi, rdx           ; args[1]
    call int_unwrap
    mov rbx, rdi
    mov r8d, edx

    ; ndigits has to be an int, and one that fits: CPython clamps a huge one
    ; to the same "past every bound" answer the small ones reach.
    cmp r8d, TAG_SMALLINT
    je .rnd_nd_small
    cmp r8d, TAG_PTR
    jne .rnd_type_error
    lea rax, [rel int_type]
    cmp [rbx + PyObject.ob_type], rax
    jne .rnd_type_error
    mov rdi, rbx
    mov edx, TAG_PTR
    call int_fits_i64
    test eax, eax
    jz .rnd_nd_huge
    mov rdi, rbx
    mov edx, TAG_PTR
    call int_to_i64
    mov [rbp - RND_ND], rax
    jmp .rnd_have_nd
.rnd_nd_huge:
    ; Larger than an int64 either way.  Its sign is all that is left of it.
    INT_NEED_MPZ rbx
    lea rdi, [rbx + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    js .rnd_nd_min
    mov qword [rbp - RND_ND], 1000
    jmp .rnd_have_nd
.rnd_nd_min:
    mov qword [rbp - RND_ND], -1000
    jmp .rnd_have_nd
.rnd_nd_small:
    mov [rbp - RND_ND], rbx

.rnd_have_nd:
    cmp qword [rbp - RND_XTAG], TAG_SMALLINT
    je .rnd_two_int

    mov rdi, [rbp - RND_X]
    mov esi, [rbp - RND_XTAG]
    call round_self_double
    test eax, eax
    jz .rnd_two_not_float

    ; float_round_ndigits takes the count in edi, saturated to a range where
    ; it is the sign that decides.
    mov rax, [rbp - RND_ND]
    cmp rax, 2000
    jle .rnd_nd_lo
    mov eax, 2000
.rnd_nd_lo:
    cmp rax, -2000
    jge .rnd_nd_ok
    mov eax, -2000
.rnd_nd_ok:
    mov edi, eax
    call float_round_ndigits
    movq rax, xmm0
    V_FROM_F64 rax, rdx
    pop rbx
    leave
    ret

.rnd_two_not_float:
    mov rdi, [rbp - RND_X]
    cmp qword [rbp - RND_XTAG], TAG_PTR
    jne .rnd_two_dunder
    lea rax, [rel int_type]
    cmp [rdi + PyObject.ob_type], rax
    je .rnd_two_bigint
.rnd_two_dunder:
    ; round(x, n) on anything else is __round__ with two arguments.  It used
    ; to be a flat TypeError, so round(Decimal(1), 2) could not work.
    mov rdi, [rbp - RND_X]
    cmp qword [rbp - RND_XTAG], TAG_PTR
    jne .rnd_type_error         ; an immediate has no __round__ of its own
    mov rsi, [rbp - RND_ND]     ; dunder_call_2 takes the (payload, tag) pair
    CSTRING rdx, "__round__"
    mov ecx, TAG_SMALLINT
    extern dunder_call_2
    call dunder_call_2
    V_UNPACK rax, rdx
    test edx, edx
    jz .rnd_type_error
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.rnd_two_int:
    ; round(int, n).  A non-negative n leaves it alone; a negative one rounds
    ; to the nearest multiple of 10**|n|, ties to even.  It used to do that
    ; through a double, which is wrong the moment the int does not fit one.
    mov rax, [rbp - RND_ND]
    test rax, rax
    jns .rnd_int_identity
    mov rdi, [rbp - RND_X]
    extern smallint_to_pyint
    call smallint_to_pyint
    mov [rbp - RND_SAVE], rax
    mov rdi, rax
    mov rsi, [rbp - RND_ND]
    call int_round_to_power10
    mov rbx, rax
    mov rdi, [rbp - RND_SAVE]
    extern int_dealloc
    call int_dealloc
    mov rax, rbx
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.rnd_two_bigint:
    mov rdi, [rbp - RND_X]
    mov rax, [rbp - RND_ND]
    test rax, rax
    jns .rnd_bigint_identity
    mov rsi, rax
    call int_round_to_power10
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.rnd_bigint_identity:
    INCREF rdi
    mov rax, rdi
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.rnd_error:
    RAISE exc_TypeError_type, "round() takes 1 or 2 arguments"

.rnd_type_error:
    RAISE exc_TypeError_type, "type cannot be rounded"
END_FUNC builtin_round_fn

;; ============================================================================
;; round_self_double(rdi = payload, esi = tag)
;;   -> xmm0 = the double, eax = 1 when it is one; eax = 0 otherwise
;;
;; A float arrives three ways -- as an immediate, as a PyFloatObject, and as a
;; subclass instance with the double inline at the base's offset -- and both
;; arms of round() have to know all three.
;; ============================================================================
DEF_FUNC_LOCAL round_self_double
    mov rax, rdi
    mov edx, esi
    cmp edx, TAG_FLOAT
    je .rsd_raw
    cmp edx, TAG_PTR
    jne .rsd_no
    lea rcx, [rel float_type]
    cmp [rax + PyObject.ob_type], rcx
    je .rsd_obj
    mov rcx, [rax + PyObject.ob_type]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_FLOAT_SUBCLASS
    jz .rsd_no
.rsd_obj:
    movsd xmm0, [rax + PyFloatObject.value]
    mov eax, 1
    leave
    ret
.rsd_raw:
    movq xmm0, rax
    mov eax, 1
    leave
    ret
.rsd_no:
    xor eax, eax
    leave
    ret
END_FUNC round_self_double

;; ============================================================================
;; int_round_to_power10(rdi = a GMP-backed PyIntObject*, rsi = ndigits < 0)
;;   -> rax = a new int, rounded to the nearest multiple of 10**|ndigits|
;;
;; Ties to even, as Python's round() is throughout.  In GMP because the whole
;; point is the ints a double cannot hold: round(10**30, -5) used to be
;; "type cannot be rounded", and round(1234, -2) went through a double.
;; ============================================================================
IRP_SELF  equ 8
IRP_ND    equ 16
IRP_POW   equ 32              ; mpz_t, 16 bytes
IRP_Q     equ 48
IRP_R     equ 64
IRP_T     equ 80
IRP_FRAME equ 96              ; + 1 push + 8 pad = 112, 16-aligned
DEF_FUNC_LOCAL int_round_to_power10, IRP_FRAME
    push rbx
    sub rsp, 8
    mov [rbp - IRP_SELF], rdi
    neg rsi
    mov [rbp - IRP_ND], rsi     ; |ndigits|

    ; 10**|ndigits|.  An exponent past what any reachable int has digits for
    ; still works: the quotient is simply 0 or +-1.
    lea rdi, [rbp - IRP_POW]
    call __gmpz_init wrt ..plt
    lea rdi, [rbp - IRP_Q]
    call __gmpz_init wrt ..plt
    lea rdi, [rbp - IRP_R]
    call __gmpz_init wrt ..plt
    lea rdi, [rbp - IRP_T]
    call __gmpz_init wrt ..plt

    mov rax, [rbp - IRP_ND]
    cmp rax, 100000
    jle .irp_pow_ok
    mov qword [rbp - IRP_ND], 100000    ; far past any int we can hold
.irp_pow_ok:
    lea rdi, [rbp - IRP_POW]
    mov esi, 10
    mov rdx, [rbp - IRP_ND]
    call __gmpz_ui_pow_ui wrt ..plt

    ; q, r = trunc-divide.  GMP's remainder carries the dividend's sign,
    ; which is what makes the half comparison below sign-agnostic.
    mov rdi, [rbp - IRP_SELF]
    INT_NEED_MPZ rdi
    lea rdi, [rbp - IRP_Q]
    lea rsi, [rbp - IRP_R]
    mov rdx, [rbp - IRP_SELF]
    add rdx, PyIntObject.mpz
    lea rcx, [rbp - IRP_POW]
    call __gmpz_tdiv_qr wrt ..plt

    ; 2*|r| against 10**|n|
    lea rdi, [rbp - IRP_T]
    lea rsi, [rbp - IRP_R]
    mov edx, 1
    call __gmpz_mul_2exp wrt ..plt
    lea rdi, [rbp - IRP_T]
    lea rsi, [rbp - IRP_POW]
    call __gmpz_cmpabs wrt ..plt
    test eax, eax
    js .irp_done                ; below half: the quotient stands
    jz .irp_tie

    ; Above half: step the quotient away from zero.
.irp_step:
    lea rdi, [rbp - IRP_R]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    js .irp_step_down
    lea rdi, [rbp - IRP_T]
    mov esi, 1
    call __gmpz_set_si wrt ..plt
    jmp .irp_step_add
.irp_step_down:
    lea rdi, [rbp - IRP_T]
    mov rsi, -1                 ; a 64-bit signed long: `mov esi, -1` would
                                ; zero-extend to 4294967295
    call __gmpz_set_si wrt ..plt
.irp_step_add:
    lea rdi, [rbp - IRP_Q]
    lea rsi, [rbp - IRP_Q]
    lea rdx, [rbp - IRP_T]
    call __gmpz_add wrt ..plt
    jmp .irp_done

.irp_tie:
    ; Exactly half: to the even quotient.  q is even when q - 2*(q/2) is 0.
    lea rdi, [rbp - IRP_T]
    lea rsi, [rbp - IRP_Q]
    mov edx, 2
    call __gmpz_tdiv_q_ui wrt ..plt
    test eax, eax               ; the remainder of q / 2
    jz .irp_done                ; q already even
    jmp .irp_step

.irp_done:
    ; result = q * 10**|n|
    lea rdi, [rbp - IRP_Q]
    lea rsi, [rbp - IRP_Q]
    lea rdx, [rbp - IRP_POW]
    call __gmpz_mul wrt ..plt

    mov edi, PyIntObject_size
    extern ap_malloc
    call ap_malloc
    mov rbx, rax
    mov qword [rbx + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rbx + PyObject.ob_type], rcx
    mov qword [rbx + PyIntObject.compact], 0
    INT_NEED_MPZ rbx
    lea rdi, [rbx + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    lea rdi, [rbx + PyIntObject.mpz]
    lea rsi, [rbp - IRP_Q]
    extern __gmpz_set
    call __gmpz_set wrt ..plt

    lea rdi, [rbp - IRP_POW]
    call __gmpz_clear wrt ..plt
    lea rdi, [rbp - IRP_Q]
    call __gmpz_clear wrt ..plt
    lea rdi, [rbp - IRP_R]
    call __gmpz_clear wrt ..plt
    lea rdi, [rbp - IRP_T]
    call __gmpz_clear wrt ..plt

    mov rdi, rbx
    call int_shrink
    add rsp, 8
    pop rbx
    leave
    ret
END_FUNC int_round_to_power10


;; ============================================================================
;; builtin_bin(args, nargs) - bin(x)
;; Returns binary string representation: '0b...' or '-0b...'
;; ============================================================================
global builtin_bin
BINB_VAL   equ 8
BINB_STR   equ 16
BINB_OUT   equ 24
BINB_FRAME equ 32           ; + 2 pushes = 48
DEF_FUNC builtin_bin, BINB_FRAME
    push rbx
    push r12
    cmp rsi, 1
    jne .bin_nargs_error

    ; obj_as_index truncates a value too wide for int64, so builtin_bin(2**70)
    ; came out as "0b0".  It is still what validates the argument and
    ; honours __index__; int_base_str renders any width through GMP.
    mov rdi, [rdi]
    mov [rbp - BINB_VAL], rdi
    V_UNPACK rdi, rdx
    call int_is_integer
    test eax, eax
    jnz .bin_have_value
    mov rdi, [rbp - BINB_VAL]
    call obj_as_index
    mov rdx, TAG_SMALLINT
    V_PACK rax, rdx
    mov [rbp - BINB_VAL], rax
.bin_have_value:
    mov rdi, [rbp - BINB_VAL]
    mov esi, 2
    xor edx, edx
    call int_base_str
    mov [rbp - BINB_STR], rax

    mov rbx, rax
    cmp byte [rbx], '-'
    jne .bin_positive
    inc rbx
.bin_positive:
    xor ecx, ecx
.bin_len:
    cmp byte [rbx + rcx], 0
    je .bin_have_len
    inc rcx
    jmp .bin_len
.bin_have_len:
    mov r12, rcx
    lea rdi, [rcx + 8]
    call ap_malloc
    mov [rbp - BINB_OUT], rax
    xor edx, edx
    mov r8, [rbp - BINB_STR]
    cmp byte [r8], '-'
    jne .bin_no_sign
    mov byte [rax], '-'
    mov edx, 1
.bin_no_sign:
    mov byte [rax + rdx], '0'
    mov byte [rax + rdx + 1], 'b'
    add rdx, 2
    xor r9d, r9d
.bin_copy:
    cmp r9, r12
    jge .bin_copied
    mov r10b, [rbx + r9]
    mov [rax + rdx], r10b
    inc rdx
    inc r9
    jmp .bin_copy
.bin_copied:
    mov byte [rax + rdx], 0

    mov rdi, [rbp - BINB_STR]
    call ap_free
    mov rdi, [rbp - BINB_OUT]
    call str_from_cstr
    mov rbx, rax
    mov r12, rdx
    mov rdi, [rbp - BINB_OUT]
    call ap_free
    mov rax, rbx
    mov rdx, r12
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.bin_nargs_error:
    CSTRING rdx, " given)"
    CSTRING rdi, "bin() takes exactly one argument ("
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_bin

;; ============================================================================
;; builtin_oct(args, nargs) - oct(x)
;; Returns octal string representation: '0o...' or '-0o...'
;; ============================================================================
global builtin_oct
OCTB_VAL   equ 8
OCTB_STR   equ 16
OCTB_OUT   equ 24
OCTB_FRAME equ 32           ; + 2 pushes = 48
DEF_FUNC builtin_oct, OCTB_FRAME
    push rbx
    push r12
    cmp rsi, 1
    jne .oct_nargs_error

    ; obj_as_index truncates a value too wide for int64, so builtin_oct(2**70)
    ; came out as "0o0".  It is still what validates the argument and
    ; honours __index__; int_base_str renders any width through GMP.
    mov rdi, [rdi]
    mov [rbp - OCTB_VAL], rdi
    V_UNPACK rdi, rdx
    call int_is_integer
    test eax, eax
    jnz .oct_have_value
    mov rdi, [rbp - OCTB_VAL]
    call obj_as_index
    mov rdx, TAG_SMALLINT
    V_PACK rax, rdx
    mov [rbp - OCTB_VAL], rax
.oct_have_value:
    mov rdi, [rbp - OCTB_VAL]
    mov esi, 8
    xor edx, edx
    call int_base_str
    mov [rbp - OCTB_STR], rax

    mov rbx, rax
    cmp byte [rbx], '-'
    jne .oct_positive
    inc rbx
.oct_positive:
    xor ecx, ecx
.oct_len:
    cmp byte [rbx + rcx], 0
    je .oct_have_len
    inc rcx
    jmp .oct_len
.oct_have_len:
    mov r12, rcx
    lea rdi, [rcx + 8]
    call ap_malloc
    mov [rbp - OCTB_OUT], rax
    xor edx, edx
    mov r8, [rbp - OCTB_STR]
    cmp byte [r8], '-'
    jne .oct_no_sign
    mov byte [rax], '-'
    mov edx, 1
.oct_no_sign:
    mov byte [rax + rdx], '0'
    mov byte [rax + rdx + 1], 'o'
    add rdx, 2
    xor r9d, r9d
.oct_copy:
    cmp r9, r12
    jge .oct_copied
    mov r10b, [rbx + r9]
    mov [rax + rdx], r10b
    inc rdx
    inc r9
    jmp .oct_copy
.oct_copied:
    mov byte [rax + rdx], 0

    mov rdi, [rbp - OCTB_STR]
    call ap_free
    mov rdi, [rbp - OCTB_OUT]
    call str_from_cstr
    mov rbx, rax
    mov r12, rdx
    mov rdi, [rbp - OCTB_OUT]
    call ap_free
    mov rax, rbx
    mov rdx, r12
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.oct_nargs_error:
    CSTRING rdx, " given)"
    CSTRING rdi, "oct() takes exactly one argument ("
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_oct

; const_one is read by round() and pow(); it lived in a .rodata block shared
; with format()'s name string, which is now in builtins_obj.asm.
section .rodata

align 8
const_one: dq 0x3ff0000000000000   ; 1.0 in IEEE 754

section .text

;; ============================================================================
;; complex_type_call(rdi = type, rsi = args, rdx = nargs) -> Value
;; The tp_new thunk.  Keywords are not accepted yet -- CPython takes real= and
;; imag= -- so a pending kw_names is rejected rather than ignored, and cleared
;; on the way out the way int_type_call and bool_type_call do.
;; ============================================================================
CTC_TYPE  equ 8
CTC_VAL   equ 16
CTC_FRAME equ 16            ; + 0 pushes = 16

DEF_FUNC complex_type_call, CTC_FRAME
    cmp qword [gs:ThreadState.kw_names_pending], 0
    jne .ctc_kwargs
    mov [rbp - CTC_TYPE], rdi
    mov rdi, rsi
    mov rsi, rdx
    call builtin_complex        ; rax = a complex pointer, edx = TAG_PTR
    lea rcx, [rel complex_type]
    cmp [rbp - CTC_TYPE], rcx
    je .ctc_out                 ; complex() itself
    test edx, edx
    jz .ctc_out                 ; it raised

    ; Re-home the two doubles into an instance of the subclass, then drop the
    ; exact complex builtin_complex built.  Copying is cheaper than teaching
    ; builtin_complex a type argument it would have to thread through six
    ; return paths.
    mov [rbp - CTC_VAL], rax
    mov rdi, [rbp - CTC_TYPE]
    call builtin_sub_alloc
    mov rcx, [rbp - CTC_VAL]
    movsd xmm0, [rcx + PyComplexObject.cval_real]
    movsd xmm1, [rcx + PyComplexObject.cval_imag]
    movsd [rax + PyComplexObject.cval_real], xmm0
    movsd [rax + PyComplexObject.cval_imag], xmm1
    mov [rbp - CTC_TYPE], rax
    mov rdi, [rbp - CTC_VAL]
    call obj_decref
    mov rax, [rbp - CTC_TYPE]
    mov edx, TAG_PTR
.ctc_out:
    leave
    ret
.ctc_kwargs:
    mov qword [gs:ThreadState.kw_names_pending], 0
    RAISE exc_TypeError_type, "complex() takes no keyword arguments"
END_FUNC complex_type_call

;; ============================================================================
;; builtin_complex(rdi = args, rsi = nargs) -> Value
;;
;;   complex()            0j
;;   complex(z)           z itself when it is already an exact complex
;;   complex(x)           (float(x)+0j) for an int, bool or float
;;   complex(a, b)        real = ar - bi, imag = ai + br
;;
;; That last formula is the whole of the two-argument case, and it is not
;; (a, b): complex(1j, 1) is 2j and complex(1, 1j) is 0j.
;; ============================================================================
BCX_A     equ 16              ; first argument's parts
BCX_B     equ 32              ; second argument's parts
BCX_ARGS  equ 40
BCX_NARGS equ 48
BCX_RA    equ 56              ; bcx_coerce's verdict for each argument: the
BCX_RB    equ 64              ; COERCED value's shape decides, not the given one
BCX_FRAME equ 64              ; + 0 pushes = 64
;; ============================================================================
;; bcx_coerce(rdi = Value, rsi = &double[2], edx = may call __complex__)
;;   -> eax = 0 not a number, 1 a real number, 2 a complex one
;;
;; complex_to_parts, then the conversion protocols CPython's constructor
;; consults and its arithmetic does not: __complex__, then __float__, then
;; __index__.  They belong here rather than in complex_to_parts because
;; `1j + obj` must go on returning NotImplemented for an object with only a
;; __float__; only complex() itself coerces.
;;
;; __complex__ is offered for the first argument alone -- CPython calls
;; try_complex_special_method on r and never on i, so complex(1, C()) is a
;; TypeError even though complex(C(), 1) is not.
;;
;; Telling 1 from 2 is what the caller needs to finish the two-argument case:
;; it is the coerced value's shape that decides, not the argument's, so
;; complex(C(), 1) where C.__complex__ gives 3+4j is (3+5j).
;;
;; A __complex__ returning something other than a complex raises here rather
;; than answering 0: that is a different error, and CPython reports it as one.
;; ============================================================================
BCC_OUT   equ 8
BCC_SELF  equ 16
BCC_EXC   equ 24
BCC_DUN   equ 32            ; whether __complex__ may be tried
BCC_FRAME equ 32            ; + 0 pushes = 32

extern dunder_call_1
extern obj_dealloc
extern complex_type
extern raise_type_error_with_name
extern raise_binop_type_error
extern eval_exception_unwind

DEF_FUNC_LOCAL bcx_coerce, BCC_FRAME
    mov [rbp - BCC_OUT], rsi
    mov [rbp - BCC_SELF], rdi
    mov [rbp - BCC_DUN], rdx
    ; Is it complex-valued?  A subclass counts, as PyComplex_Check does.
    xor r8d, r8d
    V_TEST_PTR rdi, rax
    ja .bcc_classified
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel complex_type]
    cmp rax, rcx
    je .bcc_is_complex
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_COMPLEX_SUBCLASS
    jz .bcc_classified
.bcc_is_complex:
    mov r8d, 1
.bcc_classified:
    mov [rbp - BCC_EXC], r8     ; parked; DUNDER_EXC_SAVE comes later
    call complex_to_parts
    test eax, eax
    jz .bcc_protocols
    mov rax, [rbp - BCC_EXC]
    inc eax                         ; 1 for a real number, 2 for a complex one
    jmp .bcc_done

.bcc_protocols:
    ; Only a heaptype can carry these; a builtin that had one would already
    ; have been recognised above.
    mov rdi, [rbp - BCC_SELF]
    V_TEST_PTR rdi, rax
    ja .bcc_no
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .bcc_no

    DUNDER_EXC_SAVE [rbp - BCC_EXC]
    cmp qword [rbp - BCC_DUN], 0
    je .bcc_try_float

    ; --- __complex__ ---
    CSTRING rsi, "__complex__"
    call dunder_call_1
    test rax, rax               ; dunder_call_1 answers with a Value; 0 is absent-or-raised
    jz .bcc_try_float           ; absent, or it raised
    ; The result must be a complex.  Take its parts and release it: an exact
    ; complex or a subclass both answer, as CPython accepts both.
    mov [rbp - BCC_SELF], rax
    V_TEST_PTR rax, rcx
    ja .bcc_bad_complex
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel complex_type]
    cmp rcx, rdx
    je .bcc_complex_ok
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_COMPLEX_SUBCLASS
    jz .bcc_bad_complex
.bcc_complex_ok:
    mov rdi, rax
    mov rsi, [rbp - BCC_OUT]
    call complex_to_parts
    mov rdi, [rbp - BCC_SELF]
    DECREF_V rdi, rdx
    mov eax, 2                  ; complex-valued, whatever the argument was
    jmp .bcc_done

.bcc_bad_complex:
    mov rsi, [rbp - BCC_SELF]
    CSTRING rdi, `__complex__ returned non-complex (type \x01)`
    call raise_type_error_with_name

.bcc_try_float:
    DUNDER_RAISED [rbp - BCC_EXC], .bcc_raised
    ; --- __float__, then __index__: both through their slots, which is where
    ; slots.asm puts a heaptype's, and both give a real part with a +0.0
    ; imaginary one.
    mov rdi, [rbp - BCC_SELF]
    mov rax, [rdi + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_as_number]
    test rcx, rcx
    jz .bcc_no
    mov rax, [rcx + PyNumberMethods.nb_float]
    test rax, rax
    jnz .bcc_call_conv
    mov rax, [rcx + PyNumberMethods.nb_index]
    test rax, rax
    jz .bcc_no
.bcc_call_conv:
    call rax                    ; rdi is still self; returns a Value
    test rax, rax
    jz .bcc_raised
    mov [rbp - BCC_SELF], rax
    mov rdi, rax
    mov rsi, [rbp - BCC_OUT]
    call complex_to_parts       ; a float or an int: 1 on success, 0 otherwise
    mov [rbp - BCC_EXC], rax    ; the verdict, across the release
    mov rdi, [rbp - BCC_SELF]
    DECREF_V rdi, rdx
    mov rax, [rbp - BCC_EXC]
    jmp .bcc_done

.bcc_raised:
    ; A protocol method raised.  Report that, not "not a number".
    leave
    jmp eval_exception_unwind

.bcc_no:
    xor eax, eax
.bcc_done:
    leave
    ret
END_FUNC bcx_coerce

DEF_FUNC builtin_complex, BCX_FRAME
    mov [rbp - BCX_ARGS], rdi
    mov [rbp - BCX_NARGS], rsi
    test rsi, rsi
    je .bcx_zero
    cmp rsi, 2
    ja .bcx_argcount

    ; --- a string argument, which is a parse rather than a conversion ---
    mov rdi, [rbp - BCX_ARGS]
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .bcx_first_not_str
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .bcx_from_string
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jnz .bcx_from_string
.bcx_first_not_str:
    ; The second argument may not be one either, and that is a distinct
    ; message from "must be a number".
    cmp qword [rbp - BCX_NARGS], 2
    jne .bcx_first
    mov rdi, [rbp - BCX_ARGS]
    mov rdi, [rdi + 8]
    V_TEST_PTR rdi, rax
    ja .bcx_first
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .bcx_second_is_str
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jnz .bcx_second_is_str

.bcx_first:
    mov rdi, [rbp - BCX_ARGS]
    mov rdi, [rdi]
    lea rsi, [rbp - BCX_A]
    mov edx, 1                  ; __complex__ is offered to this one only
    call bcx_coerce
    mov [rbp - BCX_RA], rax
    test eax, eax
    jz .bcx_bad_type

    cmp qword [rbp - BCX_NARGS], 1
    jne .bcx_two

    ; complex(z) hands back an exact complex unchanged, as CPython does.
    mov rdi, [rbp - BCX_ARGS]
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .bcx_one_build
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel complex_type]
    cmp rax, rcx
    jne .bcx_one_build
    push rdi
    call obj_incref
    pop rax
    mov edx, TAG_PTR
    leave
    ret
.bcx_one_build:
    movsd xmm0, [rbp - BCX_A]
    movsd xmm1, [rbp - BCX_A + 8]
    call complex_from_doubles
    leave
    ret

.bcx_two:
    mov rdi, [rbp - BCX_ARGS]
    mov rdi, [rdi + 8]
    lea rsi, [rbp - BCX_B]
    xor edx, edx                ; ...and never to the second
    call bcx_coerce
    mov [rbp - BCX_RB], rax
    test eax, eax
    jz .bcx_bad_second

    ; CPython subtracts the second argument's imaginary part only when that
    ; argument really is a complex, and *assigns* the imaginary part rather
    ; than adding to it unless the FIRST argument was one.  The difference is
    ; invisible except on a signed zero, where it is the whole answer:
    ; complex(0, -0.0) is -0j, and 0.0 + -0.0 is +0.0.
    movsd xmm0, [rbp - BCX_A]           ; real = ar
    cmp qword [rbp - BCX_RB], 2
    jne .bcx_two_imag
    movsd xmm1, [rbp - BCX_B + 8]
    subsd xmm0, xmm1                    ; real -= bi
.bcx_two_imag:
    movsd [rbp - BCX_A], xmm0
    movsd xmm1, [rbp - BCX_B]           ; br
    cmp qword [rbp - BCX_RA], 2
    jne .bcx_two_build                  ; imag = br
    addsd xmm1, [rbp - BCX_A + 8]       ; imag = ai + br
.bcx_two_build:
    movsd xmm0, [rbp - BCX_A]
    call complex_from_doubles
    leave
    ret

.bcx_zero:
    xorpd xmm0, xmm0
    xorpd xmm1, xmm1
    call complex_from_doubles
    leave
    ret

.bcx_from_string:
    ; complex("1+2j").  Reached only when there is one argument -- a string
    ; with a second is its own error, below.
    cmp qword [rbp - BCX_NARGS], 2
    je .bcx_str_and_second
    mov rdi, [rbp - BCX_ARGS]
    mov rdi, [rdi]
    lea rsi, [rbp - BCX_A]
    extern complex_parse_string
    call complex_parse_string    ; raises rather than returning on a bad parse
    jmp .bcx_one_build

.bcx_bad_type:
    mov rdi, [rbp - BCX_ARGS]
    mov rsi, [rdi]
    CSTRING rdi, `complex() first argument must be a string or a number, not '\x01'`
    call raise_type_error_with_name

.bcx_bad_second:
    mov rdi, [rbp - BCX_ARGS]
    mov rsi, [rdi + 8]
    CSTRING rdi, `complex() second argument must be a number, not '\x01'`
    call raise_type_error_with_name

.bcx_str_and_second:
    RAISE exc_TypeError_type, "complex() can't take second arg if first is a string"

.bcx_second_is_str:
    RAISE exc_TypeError_type, "complex() second arg can't be a string"

.bcx_argcount:
    mov rsi, [rbp - BCX_NARGS]
    CSTRING rdx, " given)"
    CSTRING rdi, "complex() takes at most 2 arguments ("
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_complex



section .data
align 8
dw_warn_impl: dq 0

section .rodata
dw_mod_name:  db "_warnings", 0
dw_attr_name: db "warn", 0

section .text
;; ============================================================================
;; deprecation_warn(rdi = the message, a C string) -> eax = 1 ok, 0 raised
;;
;; The one place assembly raises a Python warning.  CPython's int() warns when
;; it falls back to __trunc__ -- "The delegation of int() to __trunc__ is
;; deprecated" -- and a test suite that turns warnings into errors reads that
;; as the deprecation firing.  Nothing here warned at all, so `int(x)` for an
;; x with only a __trunc__ was silent.
;;
;; `_warnings` is imported lazily and cached, the way builtin_open_fn reaches
;; `_io`: the module is Python, and importing it at startup would run a module
;; body before there is an interpreter to run it in.  A filter set to "error"
;; makes warn() raise, which is a real answer and is passed on; anything else
;; going wrong is swallowed, because a warning that cannot be shown must not
;; become the caller's problem.
;; ============================================================================

extern import_module
extern dict_get
extern obj_call_n
extern exc_DeprecationWarning_type

DW_ARGS  equ 24             ; two Values: the message and the category
DW_MSG   equ 32
DW_KW    equ 40             ; the parked kw_names_pending
DW_TMP   equ 48             ; whatever is being held across a call
DW_FRAME equ 56             ; + 1 push = 64, 16-aligned
global deprecation_warn
DEF_FUNC deprecation_warn, DW_FRAME
    push rbx
    mov rbx, rdi

    cmp qword [rel dw_warn_impl], 0
    jne .dw_have

    ; The pending keyword names belong to whatever call is in flight, not to
    ; the import that is about to run a module body.  A frame slot, not a
    ; push: everything below makes calls, and a lone push would put every one
    ; of them eight bytes out of alignment.
    mov rax, [gs:ThreadState.kw_names_pending]
    mov [rbp - DW_KW], rax
    mov qword [gs:ThreadState.kw_names_pending], 0

    lea rdi, [rel dw_mod_name]
    call str_from_cstr_heap
    mov [rbp - DW_TMP], rax
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call import_module
    mov [rbp - DW_ARGS], rax        ; the module, across the release
    mov rdi, [rbp - DW_TMP]
    call obj_decref
    cmp qword [rbp - DW_ARGS], 0
    je .dw_no_module

    lea rdi, [rel dw_attr_name]
    call str_from_cstr_heap
    mov [rbp - DW_TMP], rax
    mov rdi, [rbp - DW_ARGS]
    mov rdi, [rdi + PyModuleObject.mod_dict]
    mov rsi, rax
    call dict_get
    mov [rbp - DW_MSG], rax         ; the function, across the release
    mov rdi, [rbp - DW_TMP]
    call obj_decref
    mov rax, [rbp - DW_MSG]
    test rax, rax
    jz .dw_no_module
    mov rdi, rax
    call obj_incref                 ; the cache holds it for the process
    mov rax, [rbp - DW_MSG]
    mov [rel dw_warn_impl], rax

    mov rax, [rbp - DW_KW]
    mov [gs:ThreadState.kw_names_pending], rax

.dw_have:
    mov rdi, rbx
    call str_from_cstr_heap
    mov [rbp - DW_MSG], rax
    mov [rbp - DW_ARGS], rax
    lea rax, [rel exc_DeprecationWarning_type]
    mov [rbp - DW_ARGS + 8], rax

    mov rdi, [rel dw_warn_impl]
    lea rsi, [rbp - DW_ARGS]
    mov edx, 2
    call obj_call_n
    mov [rbp - DW_TMP], rax

    mov rdi, [rbp - DW_MSG]
    call obj_decref
    mov rax, [rbp - DW_TMP]
    test rax, rax
    jz .dw_raised
    XDECREF_V rax, rcx
    mov eax, 1
    pop rbx
    leave
    ret

.dw_raised:
    ; warn() raised -- a filter set to "error" does exactly that -- and the
    ; exception is the caller's to propagate.
    xor eax, eax
    pop rbx
    leave
    ret

.dw_no_module:
    ; No _warnings, or no warn in it: say nothing rather than fail.  An
    ; import that raised has to be cleared, or the next opcode would find it.
    mov rax, [rbp - DW_KW]
    mov [gs:ThreadState.kw_names_pending], rax
    mov rdi, [gs:ThreadState.current_exception]
    test rdi, rdi
    jz .dw_no_module_done
    mov qword [gs:ThreadState.current_exception], 0
    call obj_decref
.dw_no_module_done:
    mov eax, 1
    pop rbx
    leave
    ret
END_FUNC deprecation_warn

;; ============================================================================
;; float_str_clean(rdi = NUL-terminated text, rsi = its length)
;;     (builtin_float's, in builtins.asm, which is at the file-size cap)
;;     -> rax = the text to hand strtod, or 0 when it is not a float at all
;;        rdx = 1 when rax is an ap_malloc'd copy the caller has to free
;;
;; Two things glibc's strtod and CPython's float() disagree about:
;;
;;   - strtod accepts C99 HEX FLOATS, so float("0x1.8p+1") answered 3.0 and
;;     float("0x10") answered 16.0, where CPython raises ValueError -- only
;;     float.fromhex reads that spelling.  No decimal float, and neither
;;     "inf"/"infinity" nor "nan", contains an x, so the letter is the test.
;;
;;   - strtod rejects PEP 515 UNDERSCORES, so float("1_000.5") raised where
;;     CPython answers 1000.5.  The rule is that an underscore stands BETWEEN
;;     TWO DIGITS: "1_.0", "1e_10", "1e1_", "_1" and "1__0" are all errors,
;;     while "1_0e1_0", ".5_5" and "5_5." are fine.  strtod is then handed a
;;     copy with them removed.
;; ============================================================================
DEF_FUNC float_str_clean          ; 4 pushes, so rsp stays 16-aligned
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r12, rsi

    xor r13d, r13d              ; an underscore was seen
    xor ecx, ecx
.fsc_scan:
    cmp rcx, r12
    jae .fsc_scanned
    movzx eax, byte [rbx + rcx]
    cmp al, 'x'
    je .fsc_reject
    cmp al, 'X'
    je .fsc_reject
    cmp al, '_'
    jne .fsc_next
    mov r13d, 1
    test rcx, rcx
    jz .fsc_reject              ; nothing before it
    movzx eax, byte [rbx + rcx - 1]
    sub al, '0'
    cmp al, 9
    ja .fsc_reject              ; what precedes it is not a digit
    lea rax, [rcx + 1]
    cmp rax, r12
    jae .fsc_reject             ; nothing after it
    movzx eax, byte [rbx + rcx + 1]
    sub al, '0'
    cmp al, 9
    ja .fsc_reject              ; what follows it is not a digit
.fsc_next:
    inc rcx
    jmp .fsc_scan

.fsc_scanned:
    test r13d, r13d
    jnz .fsc_copy
    mov rax, rbx                ; nothing to remove
    xor edx, edx
    jmp .fsc_out

.fsc_copy:
    lea rdi, [r12 + 1]
    call ap_malloc
    mov r14, rax
    xor ecx, ecx                ; source index
    xor esi, esi                ; destination index
.fsc_copy_loop:
    cmp rcx, r12
    jae .fsc_copy_done
    movzx eax, byte [rbx + rcx]
    inc rcx
    cmp al, '_'
    je .fsc_copy_loop
    mov [r14 + rsi], al
    inc rsi
    jmp .fsc_copy_loop
.fsc_copy_done:
    mov byte [r14 + rsi], 0
    mov rax, r14
    mov edx, 1
    jmp .fsc_out

.fsc_reject:
    xor eax, eax
    xor edx, edx
.fsc_out:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC float_str_clean
