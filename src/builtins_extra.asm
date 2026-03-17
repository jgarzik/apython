; builtins_extra.asm - Additional Python builtin functions
; Each builtin: name(PyObject **args, int64_t nargs) -> PyObject*
; args = borrowed refs; return = new ref

%include "macros.inc"
%include "object.inc"
%include "types.inc"
%include "frame.inc"

; External symbols used
extern int_from_i64
extern int_to_i64
extern __gmpz_fits_slong_p
extern int_neg
extern int_add
extern int_from_cstr
extern int_from_cstr_base
extern float_from_f64
extern float_int
extern ap_malloc
extern obj_dealloc
extern ap_free
extern ap_memcpy
extern strlen
extern str_from_cstr
extern str_from_cstr_heap
extern obj_str
extern obj_repr
extern obj_is_true
extern obj_incref
extern obj_decref
extern dict_get
extern raise_exception
extern exc_new
extern current_exception
extern eval_exception_unwind
extern none_singleton
extern eval_saved_r12

extern int_type
extern float_type
extern none_type
extern builtin_bool
extern builtin_float
extern str_type
extern bool_type
extern bool_true
extern bool_false

extern exc_TypeError_type
extern exc_ValueError_type
extern exc_AttributeError_type
extern exc_StopIteration_type
extern gen_type
extern raise_exception_obj
extern list_new
extern list_append
extern list_contains
extern dict_tp_iter
extern type_type
extern user_type_metatype
extern dunder_lookup
extern kw_names_pending
extern ap_strcmp
extern dict_new

; ============================================================================
; 1. builtin_abs(args, nargs) - abs(x)
; ============================================================================
DEF_FUNC builtin_abs
    push rbx
    sub rsp, 8

    cmp rsi, 1
    jne .abs_error

    mov rbx, [rdi]

    cmp qword [rdi + 8], TAG_SMALLINT
    je .abs_smallint

    cmp qword [rdi + 8], TAG_FLOAT
    je .abs_inline_float

    cmp qword [rdi + 8], TAG_BOOL
    je .abs_bool_tag

    cmp qword [rdi + 8], TAG_PTR
    jne .abs_type_error

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
    jne .abs_type_error
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
    ret

.abs_gmp_check:

    ; GMP int: check _mp_size at PyIntObject.mpz + 4
    mov eax, [rbx + PyIntObject.mpz + 4]
    test eax, eax
    jl .abs_gmp_neg

    inc qword [rbx + PyObject.ob_refcnt]
    mov rax, rbx
    mov edx, TAG_PTR
    add rsp, 8
    pop rbx
    leave
    ret

.abs_gmp_neg:
    mov rdi, rbx
    call int_neg
    ; rdx = tag already set by callee
    add rsp, 8
    pop rbx
    leave
    ret

.abs_smallint:
    mov rax, rbx
    test rax, rax
    jns .abs_si_pos
    neg rax
.abs_si_pos:
    RET_TAG_SMALLINT
    add rsp, 8
    pop rbx
    leave
    ret

.abs_bool_tag:
    ; TAG_BOOL: payload is 0 or 1, already non-negative → return as SmallInt
    mov rax, rbx
    RET_TAG_SMALLINT
    add rsp, 8
    pop rbx
    leave
    ret

.abs_inline_float:
    ; TAG_FLOAT: clear sign bit inline
    btr rbx, 63
    mov rax, rbx
    mov edx, TAG_FLOAT
    add rsp, 8
    pop rbx
    leave
    ret

.abs_float:
    movsd xmm0, [rbx + PyFloatObject.value]
    mov rax, 0x7FFFFFFFFFFFFFFF
    movq xmm1, rax
    andpd xmm0, xmm1
    call float_from_f64
    add rsp, 8
    pop rbx
    leave
    ret

.abs_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "bad operand type for abs()"
    call raise_exception

.abs_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "abs() takes exactly one argument"
    call raise_exception
END_FUNC builtin_abs

; ============================================================================
; builtin_divmod(args, nargs) - divmod(a, b) -> (a // b, a % b)
; ============================================================================
global builtin_divmod
DEF_FUNC builtin_divmod
    push rbx
    push r12
    push r13
    push r14
    push r15

    cmp rsi, 2
    jne .divmod_error

    mov rbx, [rdi]              ; a payload
    mov r13, [rdi + 8]          ; a tag
    mov r12, [rdi + 16]         ; b payload (args[1], 16-byte stride)
    mov r14, [rdi + 24]         ; b tag

    ; Compute a // b: int_floordiv(rdi=left, edx=left_tag, rsi=right, ecx=right_tag)
    mov rdi, rbx
    mov edx, r13d
    mov rsi, r12
    mov ecx, r14d
    extern int_floordiv
    call int_floordiv
    mov r15, rax                ; r15 = quotient payload
    push rdx                   ; save quotient tag (stack slot)

    ; Compute a % b: int_mod(rdi=left, edx=left_tag, rsi=right, ecx=right_tag)
    mov rdi, rbx
    mov edx, r13d
    mov rsi, r12
    mov ecx, r14d
    extern int_mod
    call int_mod
    mov r12, rax                ; r12 = remainder payload
    mov r13, rdx                ; r13 = remainder tag

    ; Create 2-tuple (quotient, remainder)
    mov edi, 2
    extern tuple_new
    call tuple_new
    mov rbx, [rax + PyTupleObject.ob_item]       ; payloads
    mov rsi, [rax + PyTupleObject.ob_item_tags]  ; tags
    mov [rbx], r15                               ; quotient payload
    pop rcx                                      ; quotient tag
    mov byte [rsi], cl
    mov [rbx + 8], r12                           ; remainder payload
    mov byte [rsi + 1], r13b                     ; remainder tag
    mov edx, TAG_PTR

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.divmod_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "divmod expected 2 arguments"
    call raise_exception
END_FUNC builtin_divmod

; tp_call wrappers: shift (type, args, nargs) → (args, nargs)
global int_type_call
ITC_FRAME  equ 8
DEF_FUNC int_type_call, ITC_FRAME
    ; rdi=type, rsi=args, rdx=nargs
    mov rdi, rsi
    mov rsi, rdx
    ; Check for keyword args
    mov rax, [rel kw_names_pending]
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
    mov qword [rel kw_names_pending], 0
    leave
    jmp builtin_int_fn
.itc_kw_no_pos:
    cmp r8, 0
    jne .itc_kw_reject
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "int() missing string argument"
    call raise_exception
.itc_kw_reject:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "'x' is an invalid keyword argument for int()"
    call raise_exception
.itc_no_kw:
    leave
    jmp builtin_int_fn
END_FUNC int_type_call

global str_type_call
DEF_FUNC_BARE str_type_call
    mov rdi, rsi
    mov rsi, rdx
    jmp builtin_str_fn
END_FUNC str_type_call

global bool_type_call
DEF_FUNC_BARE bool_type_call
    ; Check for kwargs — bool() doesn't accept keyword arguments
    mov rax, [rel kw_names_pending]
    test rax, rax
    jnz .bool_kwargs_error
    mov rdi, rsi
    mov rsi, rdx
    jmp builtin_bool
.bool_kwargs_error:
    mov qword [rel kw_names_pending], 0
    extern exc_TypeError_type
    extern raise_exception
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "bool() takes no keyword arguments"
    call raise_exception
END_FUNC bool_type_call

global float_type_call
DEF_FUNC_BARE float_type_call
    mov rdi, rsi
    mov rsi, rdx
    jmp builtin_float
END_FUNC float_type_call

; ============================================================================
; 2. builtin_int_fn(args, nargs) - int(x) or int(x, base)
; ============================================================================
; Frame layout:
BI_ARGS   equ 8
BI_NARGS  equ 16
BI_OBJ    equ 24       ; original string/bytes obj for error messages
BI_BASE   equ 32       ; base value for error messages
BI_FRAME  equ 32

DEF_FUNC builtin_int_fn, BI_FRAME
    push rbx

    test rsi, rsi
    jz .int_no_args

    cmp rsi, 1
    je .int_one_arg

    cmp rsi, 2
    je .int_two_args

    jmp .int_error

.int_one_arg:
    mov rbx, [rdi]

    cmp qword [rdi + 8], TAG_SMALLINT
    je .int_return_smallint

    cmp qword [rdi + 8], TAG_FLOAT
    je .int_from_inline_float

    cmp qword [rdi + 8], TAG_BOOL
    je .int_from_bool_tag

    ; Must be TAG_PTR to dereference
    cmp qword [rdi + 8], TAG_PTR
    jne .int_type_error

    mov rax, [rbx + PyObject.ob_type]

    lea rcx, [rel bool_type]
    cmp rax, rcx
    je .int_from_bool

    lea rcx, [rel int_type]
    cmp rax, rcx
    je .int_from_int

    ; Check int subclass (TYPE_FLAG_INT_SUBCLASS) — e.g. class MyInt(int)
    mov rdx, [rax + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_INT_SUBCLASS
    jnz .int_from_int_subclass

    lea rcx, [rel float_type]
    cmp rax, rcx
    je .int_from_float

    lea rcx, [rel str_type]
    cmp rax, rcx
    je .int_from_str
    ; Check str subclass via flag
    mov rdx, [rax + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_STR_SUBCLASS
    jnz .int_from_str

    extern bytes_type
    extern bytearray_type
    extern memoryview_type
    ; Check bytes, bytearray, or subclasses (walk base chain)
    mov rcx, rax
.int_check_bytes_chain:
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    je .int_from_bytes
    lea rdx, [rel bytearray_type]
    cmp rcx, rdx
    je .int_from_bytearray
    lea rdx, [rel memoryview_type]
    cmp rcx, rdx
    je .int_from_memoryview
    mov rcx, [rcx + PyTypeObject.tp_base]
    test rcx, rcx
    jnz .int_check_bytes_chain

    jmp .int_try_dunder

.int_no_args:
    xor eax, eax
    RET_TAG_SMALLINT
    jmp .int_ret

.int_return_smallint:
    mov rax, rbx
    RET_TAG_SMALLINT
    jmp .int_ret

.int_from_int:
    inc qword [rbx + PyObject.ob_refcnt]
    mov rax, rbx
    mov edx, TAG_PTR
    jmp .int_ret

.int_from_bool_tag:
    ; TAG_BOOL: payload 0 (False) or 1 (True) → SmallInt
    mov rax, rbx
    RET_TAG_SMALLINT
    jmp .int_ret

.int_from_inline_float:
    ; TAG_FLOAT: rbx = raw double bits — delegate to float_int for NaN/inf checks
    mov rdi, rbx
    call float_int
    jmp .int_ret

.int_from_float:
    mov rdi, rbx
    call float_int
    jmp .int_ret

.int_from_str:
    mov [rbp - BI_OBJ], rbx           ; save original obj for error msg
    mov qword [rbp - BI_BASE], 10     ; base 10
    ; Check for embedded NUL bytes
    lea rdi, [rbx + PyStrObject.data]
    call strlen wrt ..plt
    cmp rax, [rbx + PyStrObject.ob_size]
    jne .int_str_parse_error           ; embedded NUL → reject
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, 10
    call int_from_cstr_base
    test edx, edx
    jz .int_str_parse_error
    jmp .int_ret

.int_from_bytes:
    ; int(bytes_obj) — need null-terminated copy for int_from_cstr_base
    mov [rbp - BI_OBJ], rbx           ; save original obj for error msg
    mov qword [rbp - BI_BASE], 10     ; base 10
    mov rcx, [rbx + PyBytesObject.ob_size]
    lea rdi, [rcx + 8]       ; size + 8-byte NUL padding
    push rcx
    call ap_malloc
    pop rcx
    push rax                  ; save buffer ptr
    ; Copy bytes data
    mov rdi, rax
    lea rsi, [rbx + PyBytesObject.data]
    mov rdx, rcx
    extern ap_memcpy
    call ap_memcpy
    ; Null-terminate with 8-byte zero-fill
    pop rdi                   ; rdi = buffer
    push rdi
    mov rcx, [rbx + PyBytesObject.ob_size]
    mov qword [rdi + rcx], 0
    ; Check for embedded NUL bytes
    call strlen wrt ..plt
    cmp rax, [rbx + PyBytesObject.ob_size]
    jne .int_bytes_nul_error  ; embedded NUL → free buf + error
    ; Parse
    mov rdi, [rsp]            ; buffer (still on stack)
    mov rsi, 10
    call int_from_cstr_base
    mov rbx, rax              ; save result payload
    push rdx                  ; save result tag
    mov rdi, [rsp + 8]       ; buffer ptr (under tag on stack)
    call ap_free
    pop rdx                   ; restore result tag
    add rsp, 8               ; pop buffer ptr
    mov rax, rbx
    test edx, edx            ; check tag (not payload — SmallInt 0 is valid)
    jz .int_str_parse_error
    jmp .int_ret

.int_bytes_nul_error:
    pop rdi                   ; free temp buffer
    call ap_free
    jmp .int_str_parse_error

.int_str_parse_error:
    jmp .int_invalid_literal_error

.int_from_bytearray:
    ; Same as int_from_bytes but using PyByteArrayObject layout (identical to PyBytesObject)
    mov [rbp - BI_OBJ], rbx
    mov qword [rbp - BI_BASE], 10
    mov rcx, [rbx + PyByteArrayObject.ob_size]
    lea rdi, [rcx + 8]
    push rcx
    call ap_malloc
    pop rcx
    push rax
    mov rdi, rax
    lea rsi, [rbx + PyByteArrayObject.data]
    mov rdx, rcx
    call ap_memcpy
    pop rdi
    push rdi
    mov rcx, [rbx + PyByteArrayObject.ob_size]
    mov qword [rdi + rcx], 0
    ; Check for embedded NUL
    call strlen wrt ..plt
    cmp rax, [rbx + PyByteArrayObject.ob_size]
    jne .int_bytes_nul_error
    mov rdi, [rsp]
    mov rsi, 10
    call int_from_cstr_base
    mov rbx, rax              ; save result payload
    push rdx                  ; save result tag
    mov rdi, [rsp + 8]       ; buffer ptr (under tag on stack)
    call ap_free
    pop rdx                   ; restore result tag
    add rsp, 8               ; pop buffer ptr
    mov rax, rbx
    test edx, edx            ; check tag (not payload — SmallInt 0 is valid)
    jz .int_str_parse_error
    jmp .int_ret

.int_from_memoryview:
    ; int(memoryview) — copy the viewed bytes and parse
    mov [rbp - BI_OBJ], rbx
    mov qword [rbp - BI_BASE], 10
    mov rcx, [rbx + PyMemoryViewObject.mv_len]
    lea rdi, [rcx + 8]
    push rcx
    call ap_malloc
    pop rcx
    push rax
    mov rdi, rax
    mov rsi, [rbx + PyMemoryViewObject.mv_buf]
    mov rdx, rcx
    call ap_memcpy
    pop rdi
    push rdi
    mov rcx, [rbx + PyMemoryViewObject.mv_len]
    mov qword [rdi + rcx], 0
    ; Check for embedded NUL
    call strlen wrt ..plt
    cmp rax, [rbx + PyMemoryViewObject.mv_len]
    jne .int_bytes_nul_error
    mov rdi, [rsp]
    mov rsi, 10
    call int_from_cstr_base
    mov rbx, rax              ; save result payload
    push rdx                  ; save result tag
    mov rdi, [rsp + 8]       ; buffer ptr (under tag on stack)
    call ap_free
    pop rdx                   ; restore result tag
    add rsp, 8               ; pop buffer ptr
    mov rax, rbx
    test edx, edx            ; check tag (not payload — SmallInt 0 is valid)
    jz .int_str_parse_error
    jmp .int_ret

.int_from_bool:
    lea rax, [rel bool_true]
    cmp rbx, rax
    je .int_bool_true
    xor eax, eax
    RET_TAG_SMALLINT
    jmp .int_ret
.int_bool_true:
    mov rax, 1
    RET_TAG_SMALLINT
    jmp .int_ret

.int_from_int_subclass:
    ; rbx = int subclass instance (PyIntSubclassObject)
    ; Check if it has __int__ method
    mov rdi, [rbx + PyObject.ob_type]
    CSTRING rsi, "__int__"
    call dunder_lookup
    test edx, edx
    jz .int_from_int_sub_extract ; no __int__, extract int_value
    ; Call __int__(self) — rax = func (borrowed ref)
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .int_from_int
    SPUSH_PTR rbx                ; args[0] = self (fat arg)
    mov rdi, rax
    mov rsi, rsp
    mov edx, 1
    call rcx
    add rsp, 16
    ; Check for exception (NULL return)
    test edx, edx
    jz .int_dunder_error
    ; Verify result is int-like
    cmp edx, TAG_SMALLINT
    je .int_ret                  ; SmallInt — OK
    cmp edx, TAG_FLOAT
    je .int_dunder_returned_float
    mov rcx, [rax + PyObject.ob_type]
    lea r8, [rel int_type]
    cmp rcx, r8
    je .int_ret                  ; exact int — OK
    lea r8, [rel bool_type]
    cmp rcx, r8
    je .int_convert_bool_result  ; bool → convert to plain int
    mov r8, [rcx + PyTypeObject.tp_flags]
    test r8, TYPE_FLAG_INT_SUBCLASS
    jnz .int_ret                 ; int subclass — OK for now
    ; __int__ returned non-int
    mov rdi, rax
    call obj_decref
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "__int__ returned non-int (type float)"
    call raise_exception

.int_from_int_sub_extract:
    ; rbx = PyIntSubclassObject with no __int__ method
    ; Extract the int_value and return it
    mov rax, [rbx + PyIntSubclassObject.int_value]
    mov rdx, [rbx + PyIntSubclassObject.int_value_tag]
    cmp edx, TAG_SMALLINT
    je .int_ret                  ; SmallInt — no INCREF needed
    INCREF rax
    jmp .int_ret

.int_try_dunder:
    ; rbx = unknown-type object
    ; Try __int__ protocol
    mov rdi, [rbx + PyObject.ob_type]
    CSTRING rsi, "__int__"
    call dunder_lookup
    test edx, edx
    jnz .int_call_dunder

    ; Try __index__ protocol
    mov rdi, [rbx + PyObject.ob_type]
    CSTRING rsi, "__index__"
    call dunder_lookup
    test edx, edx
    jnz .int_call_dunder

    ; Try __trunc__ protocol
    mov rdi, [rbx + PyObject.ob_type]
    CSTRING rsi, "__trunc__"
    call dunder_lookup
    test edx, edx
    jnz .int_call_dunder_trunc

    jmp .int_type_error

.int_call_dunder:
    ; rax = func (borrowed ref), rbx = self
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .int_type_error
    SPUSH_PTR rbx                ; args[0] = self (fat arg)
    mov rdi, rax
    mov rsi, rsp
    mov edx, 1
    call rcx
    add rsp, 16
    ; Check for exception (NULL return)
    test edx, edx
    jz .int_dunder_error
    ; Verify result is int-like
    cmp edx, TAG_SMALLINT
    je .int_ret                  ; SmallInt — OK
    cmp edx, TAG_FLOAT
    je .int_dunder_returned_float
    mov rcx, [rax + PyObject.ob_type]
    lea r8, [rel int_type]
    cmp rcx, r8
    je .int_ret                  ; exact int — OK
    lea r8, [rel bool_type]
    cmp rcx, r8
    je .int_convert_bool_result  ; bool → convert to plain int
    mov r8, [rcx + PyTypeObject.tp_flags]
    test r8, TYPE_FLAG_INT_SUBCLASS
    jnz .int_ret                 ; int subclass — OK
    ; Not int-like
    mov rdi, rax
    call obj_decref
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "__int__ returned non-int"
    call raise_exception

.int_call_dunder_trunc:
    ; rax = __trunc__ func, rbx = self
    ; Call __trunc__(self); result must be int-like or have __index__
    ; CPython 3.12: tries __index__ on result, but NOT __int__
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .int_type_error
    SPUSH_PTR rbx                ; args[0] = self (fat arg)
    mov rdi, rax
    mov rsi, rsp
    mov edx, 1
    call rcx
    add rsp, 16
    ; rax = result of __trunc__()
    ; Check for exception (NULL return)
    test edx, edx
    jz .int_dunder_error
    ; If it's already an int, return it
    cmp edx, TAG_SMALLINT
    je .int_ret                  ; SmallInt — OK
    cmp edx, TAG_PTR
    jne .int_trunc_nonint_error  ; non-pointer (Float/None/Bool) — not int
    mov rcx, [rax + PyObject.ob_type]
    lea r8, [rel int_type]
    cmp rcx, r8
    je .int_ret
    lea r8, [rel bool_type]
    cmp rcx, r8
    je .int_convert_bool_result
    mov r8, [rcx + PyTypeObject.tp_flags]
    test r8, TYPE_FLAG_INT_SUBCLASS
    jnz .int_ret
    ; __trunc__ returned non-int — try __index__ only (CPython behavior)
    mov rbx, rax                 ; save __trunc__ result
    mov rdi, [rax + PyObject.ob_type]
    CSTRING rsi, "__index__"
    call dunder_lookup
    test edx, edx
    jnz .int_call_trunc_index
    ; No __index__ — raise TypeError with type name
    ; Get type name from __trunc__ result
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_name]  ; C string
    push rax                               ; save type name
    mov rdi, rbx
    call obj_decref
    pop rsi                                ; type name
    jmp .int_trunc_type_error_with_name

.int_call_trunc_index:
    ; rax = __index__ func, rbx = __trunc__ result
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .int_trunc_no_index
    SPUSH_PTR rbx                ; args[0] = __trunc__ result (fat arg)
    mov rdi, rax
    mov rsi, rsp
    mov edx, 1
    call rcx
    add rsp, 16
    ; rax = __index__ result, rbx = __trunc__ result (still needs DECREF)
    ; Save __index__ result and DECREF __trunc__ result first
    push rax
    push rdx
    mov rdi, rbx
    call obj_decref              ; DECREF __trunc__ result
    pop rdx
    pop rax
    ; Now check __index__ result
    test edx, edx
    jz .int_dunder_error
    ; Verify it's an int
    cmp edx, TAG_SMALLINT
    je .int_ret                  ; SmallInt — OK
    cmp edx, TAG_PTR
    jne .int_index_nonint_error  ; non-pointer (Float/None/Bool) — not int
    mov rcx, [rax + PyObject.ob_type]
    lea r8, [rel int_type]
    cmp rcx, r8
    je .int_ret
    lea r8, [rel bool_type]
    cmp rcx, r8
    je .int_convert_bool_result
    mov r8, [rcx + PyTypeObject.tp_flags]
    test r8, TYPE_FLAG_INT_SUBCLASS
    jnz .int_ret
    ; __index__ returned non-int (heap object)
    mov rdi, rax
    call obj_decref
.int_index_nonint_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "__index__ returned non-int"
    call raise_exception

.int_trunc_no_index:
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_name]
    push rax                               ; save type name
    mov rdi, rbx
    call obj_decref
    pop rsi                                ; type name
    jmp .int_trunc_type_error_with_name

.int_trunc_type_error_with_name:
    ; rsi = type name (C string ptr)
    ; Build: "__trunc__ returned non-Integral (type <name>)"
    ; Use str_from_cstr + str_concat approach
    push rsi                               ; save type name
    CSTRING rdi, "__trunc__ returned non-Integral (type "
    call str_from_cstr_heap
    push rax                               ; save prefix str

    ; Create type name str
    mov rdi, [rsp + 8]                     ; type name C string
    call str_from_cstr_heap
    push rax                               ; save name str

    ; Create suffix str
    CSTRING rdi, ")"
    call str_from_cstr_heap
    push rax                               ; save suffix str

    ; Concat: prefix + name
    extern str_concat
    mov rdi, [rsp + 16]                    ; prefix str
    mov rsi, [rsp + 8]                     ; name str
    mov ecx, TAG_PTR                       ; right_tag (heap str)
    call str_concat
    push rax                               ; save partial

    ; Concat: partial + suffix
    mov rdi, rax                           ; partial
    mov rsi, [rsp + 8]                     ; suffix str
    mov ecx, TAG_PTR                       ; right_tag (heap str)
    call str_concat
    mov rbx, rax                           ; rbx = full message str

    ; DECREF intermediate strings (5 items on stack: partial, suffix, name, prefix, type_name_cstr)
    pop rdi                                ; partial
    call obj_decref
    pop rdi                                ; suffix
    call obj_decref
    pop rdi                                ; name
    call obj_decref
    pop rdi                                ; prefix
    call obj_decref
    add rsp, 8                             ; pop type name C string

    ; Raise TypeError with the message
    lea rdi, [rel exc_TypeError_type]
    mov rsi, rbx
    mov edx, TAG_PTR
    call exc_new
    push rax                               ; save exc
    mov rdi, rbx
    call obj_decref                        ; DECREF msg str
    pop rax                                ; exc obj

    ; Store exception and jump to unwind
    mov [rel current_exception], rax
    jmp eval_exception_unwind

.int_trunc_nonint_error:
    ; __trunc__ returned non-pointer non-int (TAG_FLOAT, TAG_NONE, etc)
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "__trunc__ returned non-Integral"
    call raise_exception

.int_dunder_returned_float:
    ; __int__/__trunc__ returned TAG_FLOAT — TypeError (non-int return)
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "__int__ returned non-int (type float)"
    call raise_exception

.int_convert_bool_result:
    ; rax = bool_true or bool_false, convert to SmallInt
    lea rcx, [rel bool_true]
    cmp rax, rcx
    je .int_bool_result_true
    xor eax, eax
    RET_TAG_SMALLINT
    jmp .int_ret
.int_bool_result_true:
    mov rax, 1
    RET_TAG_SMALLINT
    jmp .int_ret

.int_dunder_error:
    ; Dunder method raised an exception — propagate it (return NULL)
    xor eax, eax
    jmp .int_ret

.int_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "int() argument must be a string or a number, not"
    call raise_exception

.int_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "int() takes at most 2 arguments"
    call raise_exception

; ------- int(x, base) -------
.int_two_args:
    mov [rbp - BI_ARGS], rdi       ; save args pointer
    ; Get base from args[1] (contiguous 16-byte fat value from CALL)
    mov rax, [rdi + 16]            ; args[1] payload (16-byte stride)
    cmp qword [rdi + 24], TAG_SMALLINT  ; args[1] tag
    je .int_base_smallint
    ; Reject non-pointer tags (TAG_FLOAT, TAG_NONE, TAG_BOOL)
    cmp qword [rdi + 24], TAG_PTR
    jne .int_base_type_error
    ; base is a heap object — check if it's an int or has __index__
    ; args already saved in [rbp - BI_ARGS]
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel int_type]
    cmp rcx, rdx
    je .int_base_heap_int
    lea rdx, [rel bool_type]
    cmp rcx, rdx
    je .int_base_heap_int
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_INT_SUBCLASS
    jnz .int_base_heap_int
    ; Try __index__ protocol on base
    SPUSH_PTR rax                 ; save base obj as fat arg
    mov rdi, rcx                  ; type
    CSTRING rsi, "__index__"
    call dunder_lookup
    test edx, edx
    jz .int_base_no_index
    ; Call __index__(base_obj)
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .int_base_no_index
    mov rdi, rax
    lea rsi, [rsp]               ; args[0] = base_obj (fat arg on stack)
    mov edx, 1
    call rcx
    add rsp, 16                  ; pop fat arg
    ; rax = __index__ result, should be int
    test edx, edx
    jz .int_dunder_error         ; __index__ raised exception
    cmp edx, TAG_SMALLINT
    je .int_base_si_from_index
    ; heap int — check if it fits in i64 first
    push rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_fits_slong_p wrt ..plt
    test eax, eax
    pop rdi                      ; rdi = __index__ result
    jz .int_base_range_error     ; doesn't fit → definitely out of 2-36 range
    mov edx, TAG_PTR             ; heap int
    call int_to_i64
    jmp .int_have_base
.int_base_si_from_index:
    jmp .int_have_base
.int_base_no_index:
    add rsp, 16                  ; pop fat arg
    jmp .int_base_type_error
.int_base_heap_int:
    ; rax = heap int object (GMP). Check if it fits in i64.
    push rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_fits_slong_p wrt ..plt
    test eax, eax
    pop rdi                      ; rdi = heap int obj
    jz .int_base_range_error     ; doesn't fit → out of 2-36 range
    mov edx, TAG_PTR             ; heap int
    call int_to_i64
    jmp .int_have_base
.int_base_smallint:
.int_have_base:
    ; rax = base value
    mov [rbp - BI_NARGS], rax      ; save base
    ; Validate base: must be 0 or 2..36
    test rax, rax
    jz .int_base_ok
    cmp rax, 2
    jl .int_base_range_error
    cmp rax, 36
    jg .int_base_range_error
.int_base_ok:
    ; Save base for error reporting
    mov rax, [rbp - BI_NARGS]
    mov [rbp - BI_BASE], rax
    ; Get x from args[0] — must be string or bytes
    mov rdi, [rbp - BI_ARGS]
    mov rbx, [rdi]                 ; args[0] payload
    mov [rbp - BI_OBJ], rbx       ; save original obj for error msg
    cmp qword [rdi + 8], TAG_PTR  ; args[0] tag
    jne .int_base_type_error_str  ; non-pointer: can't have base with non-str
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .int_base_from_str
    mov rdx, [rax + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_STR_SUBCLASS
    jnz .int_base_from_str
    ; Check bytes, bytearray, or subclasses (walk base chain)
    mov rcx, rax
.int_base_check_bytes_chain:
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    je .int_base_from_bytes
    lea rdx, [rel bytearray_type]
    cmp rcx, rdx
    je .int_base_from_bytes            ; same layout as bytes
    mov rcx, [rcx + PyTypeObject.tp_base]
    test rcx, rcx
    jnz .int_base_check_bytes_chain
    jmp .int_base_type_error_str

.int_base_from_str:
    ; Check for embedded NUL bytes
    lea rdi, [rbx + PyStrObject.data]
    call strlen wrt ..plt
    cmp rax, [rbx + PyStrObject.ob_size]
    jne .int_base_parse_error      ; embedded NUL → reject
    ; Parse string with given base
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, [rbp - BI_NARGS]      ; base
    call int_from_cstr_base
    test edx, edx            ; check tag (not payload — SmallInt 0 is valid)
    jz .int_base_parse_error
    jmp .int_ret

.int_base_from_bytes:
    ; Parse bytes with given base — make null-terminated copy
    mov rcx, [rbx + PyBytesObject.ob_size]
    lea rdi, [rcx + 8]
    push rcx
    call ap_malloc
    pop rcx
    push rax
    mov rdi, rax
    lea rsi, [rbx + PyBytesObject.data]
    mov rdx, rcx
    call ap_memcpy
    pop rdi
    push rdi
    mov rcx, [rbx + PyBytesObject.ob_size]
    mov qword [rdi + rcx], 0
    ; Check for embedded NUL
    call strlen wrt ..plt
    cmp rax, [rbx + PyBytesObject.ob_size]
    jne .int_base_bytes_nul_error
    mov rdi, [rsp]                 ; buffer
    mov rsi, [rbp - BI_NARGS]      ; base
    call int_from_cstr_base
    mov rbx, rax                   ; save result payload
    push rdx                       ; save result tag
    mov rdi, [rsp + 8]            ; buffer ptr (under tag on stack)
    call ap_free
    pop rdx                        ; restore result tag
    add rsp, 8                    ; pop buffer ptr
    mov rax, rbx
    test edx, edx                 ; check tag (not payload — SmallInt 0 is valid)
    jz .int_base_parse_error
    jmp .int_ret

.int_base_bytes_nul_error:
    pop rdi                   ; free temp buffer
    call ap_free
    jmp .int_base_parse_error

.int_base_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "int() second arg must be an integer"
    call raise_exception

.int_base_type_error_str:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "int() can't convert non-string with explicit base"
    call raise_exception

.int_base_range_error:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "int() base must be >= 2 and <= 36, or 0"
    call raise_exception

.int_base_parse_error:
    ; Restore rbx from BI_OBJ (may have been clobbered in bytes path)
    mov rbx, [rbp - BI_OBJ]
    jmp .int_invalid_literal_error

.int_invalid_literal_error:
    ; Build "invalid literal for int() with base N: <repr>"
    ; [rbp - BI_OBJ] = original obj, [rbp - BI_BASE] = base
    ;
    ; Strategy: build "...base N: " as C string in stack buffer, then
    ; create ONE PyStr, concat with repr, minimal DECREF.
    ;
    ; Stack layout (sub rsp, 72, aligned to 16):
    ;   [rsp+0..47]  = C string buffer (48 bytes)
    ;   [rsp+48]     = saved prefix_str
    ;   [rsp+56]     = saved repr_str
    ;   [rsp+64]     = saved full_msg / exc
    sub rsp, 72                         ; rsp ≡ 0 (mod 16) — aligned

    ; --- Build "invalid literal for int() with base N: " as C string ---
    mov rdi, rsp
    CSTRING rsi, "invalid literal for int() with base "
    mov edx, 36
    call ap_memcpy
    ; rdi = rsp + 36 (past prefix, ap_memcpy advances rdi via rep movsb)

    ; Append base as decimal (0-36)
    mov rax, [rbp - BI_BASE]
    cmp rax, 10
    jb .ile_one_digit
    ; Two digits
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    mov [rdi], al
    inc rdi
    add dl, '0'
    mov [rdi], dl
    inc rdi
    jmp .ile_base_done
.ile_one_digit:
    add al, '0'
    mov [rdi], al
    inc rdi
.ile_base_done:
    mov byte [rdi], ':'
    mov byte [rdi+1], ' '
    mov byte [rdi+2], 0

    ; Create PyStr from buffer (heap — passed to str_concat, DECREFed)
    mov rdi, rsp
    call str_from_cstr_heap
    mov [rsp + 48], rax

    ; Get repr of original object (always a heap ptr)
    mov rdi, [rbp - BI_OBJ]
    mov esi, TAG_PTR
    call obj_repr
    test rax, rax
    jnz .ile_have_repr
    CSTRING rdi, "???"
    call str_from_cstr_heap
    jmp .ile_repr_ready
.ile_have_repr:
    ; rax = repr string (heap ptr)
.ile_repr_ready:
    mov [rsp + 56], rax

    ; Concat prefix_str + repr_str → full message
    mov rdi, [rsp + 48]
    mov rsi, [rsp + 56]
    mov ecx, TAG_PTR            ; right_tag (heap str)
    call str_concat
    mov [rsp + 64], rax

    ; DECREF prefix_str and repr_str
    mov rdi, [rsp + 48]
    call obj_decref
    mov rdi, [rsp + 56]
    call obj_decref

    ; Create ValueError
    lea rdi, [rel exc_ValueError_type]
    mov rsi, [rsp + 64]
    mov edx, TAG_PTR
    call exc_new
    mov rbx, rax                        ; rbx = exc (callee-saved)

    ; DECREF full message
    mov rdi, [rsp + 64]
    call obj_decref

    ; DECREF previous exception if any
    mov rax, [rel current_exception]
    test rax, rax
    jz .int_ile_no_prev
    mov rdi, rax
    call obj_decref
.int_ile_no_prev:
    mov [rel current_exception], rbx
    add rsp, 72
    jmp eval_exception_unwind

.int_ret:
    ; Common epilogue: rax = payload, edx = tag (set by callee)
    ; rbx was pushed after sub rsp, BI_FRAME, so it's at rbp - BI_FRAME - 8
    lea rsp, [rbp - BI_FRAME - 8]
    pop rbx
    leave
    ret

END_FUNC builtin_int_fn

; ============================================================================
; 3. builtin_str_fn(args, nargs) - str(x)
; ============================================================================
DEF_FUNC builtin_str_fn

    test rsi, rsi
    jz .str_no_args

    cmp rsi, 1
    jne .str_error

    mov rsi, [rdi + 8]         ; arg[0] tag
    mov rdi, [rdi]             ; arg[0] payload
    call obj_str
    leave
    ret

.str_no_args:
    CSTRING rdi, ""
    call str_from_cstr
    leave
    ret

.str_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "str() takes at most 1 argument"
    call raise_exception
END_FUNC builtin_str_fn

; ============================================================================
; 4. builtin_ord(args, nargs) - ord(c)
; ============================================================================
DEF_FUNC builtin_ord

    cmp rsi, 1
    jne .ord_nargs_error

    cmp qword [rdi + 8], TAG_PTR
    jne .ord_type_error            ; non-string tag

    mov rdi, [rdi]                 ; args[0] payload

    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .ord_type_error

    cmp qword [rdi + PyStrObject.ob_size], 1
    jne .ord_len_error

    movzx eax, byte [rdi + PyStrObject.data]
    RET_TAG_SMALLINT
    leave
    ret

.ord_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "ord() expected string of length 1"
    call raise_exception

.ord_len_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "ord() expected a character"
    call raise_exception

.ord_nargs_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "ord() takes exactly one argument"
    call raise_exception
END_FUNC builtin_ord

; ============================================================================
; 5. builtin_chr(args, nargs) - chr(n)
; ============================================================================
DEF_FUNC builtin_chr, 16

    cmp rsi, 1
    jne .chr_nargs_error

    mov edx, [rdi + 8]
    mov rdi, [rdi]
    call int_to_i64

    cmp rax, 0
    jl .chr_range_error
    cmp rax, 0x10FFFF
    ja .chr_range_error

    ; Single byte (ASCII)
    cmp rax, 0x7F
    ja .chr_utf8_encode

    mov byte [rbp - 16], al
    mov byte [rbp - 15], 0
    lea rdi, [rbp - 16]
    call str_from_cstr
    leave
    ret

.chr_utf8_encode:
    cmp rax, 0x7FF
    ja .chr_3byte

    ; 2-byte: 110xxxxx 10xxxxxx
    mov rcx, rax
    shr rcx, 6
    or cl, 0xC0
    mov byte [rbp - 16], cl
    mov rcx, rax
    and cl, 0x3F
    or cl, 0x80
    mov byte [rbp - 15], cl
    mov byte [rbp - 14], 0
    lea rdi, [rbp - 16]
    call str_from_cstr
    leave
    ret

.chr_3byte:
    cmp rax, 0xFFFF
    ja .chr_4byte

    ; 3-byte: 1110xxxx 10xxxxxx 10xxxxxx
    mov rcx, rax
    shr rcx, 12
    or cl, 0xE0
    mov byte [rbp - 16], cl
    mov rcx, rax
    shr rcx, 6
    and cl, 0x3F
    or cl, 0x80
    mov byte [rbp - 15], cl
    mov rcx, rax
    and cl, 0x3F
    or cl, 0x80
    mov byte [rbp - 14], cl
    mov byte [rbp - 13], 0
    lea rdi, [rbp - 16]
    call str_from_cstr
    leave
    ret

.chr_4byte:
    ; 4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
    mov rcx, rax
    shr rcx, 18
    or cl, 0xF0
    mov byte [rbp - 16], cl
    mov rcx, rax
    shr rcx, 12
    and cl, 0x3F
    or cl, 0x80
    mov byte [rbp - 15], cl
    mov rcx, rax
    shr rcx, 6
    and cl, 0x3F
    or cl, 0x80
    mov byte [rbp - 14], cl
    mov rcx, rax
    and cl, 0x3F
    or cl, 0x80
    mov byte [rbp - 13], cl
    mov byte [rbp - 12], 0
    lea rdi, [rbp - 16]
    call str_from_cstr
    leave
    ret

.chr_range_error:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "chr() arg not in range(0x110000)"
    call raise_exception

.chr_nargs_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "chr() takes exactly one argument"
    call raise_exception
END_FUNC builtin_chr

; ============================================================================
; 6. builtin_hex(args, nargs) - hex(n)
; ============================================================================
DEF_FUNC builtin_hex, 80

    cmp rsi, 1
    jne .hex_nargs_error

    mov edx, [rdi + 8]
    mov rdi, [rdi]
    call int_to_i64

    test rax, rax
    jz .hex_zero

    test rax, rax
    jns .hex_positive

    ; Negative
    neg rax
    mov byte [rbp - 80], '-'
    mov byte [rbp - 79], '0'
    mov byte [rbp - 78], 'x'
    lea rdi, [rbp - 77]
    mov r8d, 3
    jmp .hex_digits

.hex_positive:
    mov byte [rbp - 80], '0'
    mov byte [rbp - 79], 'x'
    lea rdi, [rbp - 78]
    mov r8d, 2

.hex_digits:
    ; Write hex digits in reverse into temp area, then copy in correct order
    lea rsi, [rbp - 16]
    xor ecx, ecx

.hex_digit_loop:
    test rax, rax
    jz .hex_reverse

    mov rdx, rax
    and edx, 0xF
    cmp edx, 10
    jb .hex_dec_digit
    add edx, ('a' - 10)
    jmp .hex_store_digit
.hex_dec_digit:
    add edx, '0'
.hex_store_digit:
    mov byte [rsi], dl
    dec rsi
    inc ecx
    shr rax, 4
    jmp .hex_digit_loop

.hex_reverse:
    ; Digits at [rsi+1 .. rsi+ecx], LSB first (reversed)
    ; Copy them MSB-first into rdi
    inc rsi
    mov edx, ecx
.hex_copy_loop:
    test ecx, ecx
    jz .hex_done_copy
    mov al, byte [rsi]
    mov byte [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jmp .hex_copy_loop

.hex_done_copy:
    mov byte [rdi], 0
    lea rdi, [rbp - 80]
    call str_from_cstr
    leave
    ret

.hex_zero:
    CSTRING rdi, "0x0"
    call str_from_cstr
    leave
    ret

.hex_nargs_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "hex() takes exactly one argument"
    call raise_exception
END_FUNC builtin_hex

; ============================================================================
; 7. builtin_id(args, nargs) - id(x)
; ============================================================================
DEF_FUNC builtin_id

    cmp rsi, 1
    jne .id_error

    cmp qword [rdi + 8], TAG_SMALLINT  ; check args[0] tag
    mov rdi, [rdi]                     ; args[0] payload
    je .id_smallint

    call int_from_i64
    leave
    ret

.id_smallint:
    call int_from_i64
    leave
    ret

.id_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "id() takes exactly one argument"
    call raise_exception
END_FUNC builtin_id

; ============================================================================
; 8. builtin_hash_fn(args, nargs) - hash(x)
; ============================================================================
DEF_FUNC builtin_hash_fn
    push rbx
    sub rsp, 8

    cmp rsi, 1
    jne .hash_nargs_error

    mov rbx, [rdi]

    cmp qword [rdi + 8], TAG_SMALLINT  ; check args[0] tag
    je .hash_smallint

    cmp qword [rdi + 8], TAG_FLOAT
    je .hash_float

    ; Check non-pointer tags before dereference
    cmp qword [rdi + 8], TAG_BOOL
    je .hash_bool
    cmp qword [rdi + 8], TAG_NONE
    je .hash_none

    mov rax, [rbx + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_hash]
    test rcx, rcx
    jz .hash_type_error

    mov rdi, rbx
    call rcx
    mov rdi, rax
    call int_from_i64
    add rsp, 8
    pop rbx
    leave
    ret

.hash_float:
    ; TAG_FLOAT: call float_hash for PEP-correct integer-float matching
    extern float_hash
    mov rdi, rbx
    call float_hash
    mov rdi, rax
    call int_from_i64
    add rsp, 8
    pop rbx
    leave
    ret

.hash_smallint:
    mov rax, rbx
    ; Apply -1 → -2 convention (hash must never return -1)
    cmp rax, -1
    jne .hash_si_ok
    mov rax, -2
.hash_si_ok:
    mov rdi, rax
    call int_from_i64
    add rsp, 8
    pop rbx
    leave
    ret

.hash_bool:
    ; hash(True) = 1, hash(False) = 0 — payload is already 0 or 1
    mov rax, rbx
    jmp .hash_si_ok

.hash_none:
    ; hash(None) — CPython convention
    mov eax, 0x48ae2ce5
    jmp .hash_si_ok

.hash_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "unhashable type"
    call raise_exception

.hash_nargs_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "hash() takes exactly one argument"
    call raise_exception
END_FUNC builtin_hash_fn

; ============================================================================
; 9. builtin_callable(args, nargs) - callable(x)
; ============================================================================
DEF_FUNC builtin_callable

    cmp rsi, 1
    jne .callable_error

    cmp qword [rdi + 8], TAG_SMALLINT  ; check args[0] tag
    je .callable_false
    cmp qword [rdi + 8], TAG_PTR
    jne .callable_false             ; non-pointer tag (TAG_FLOAT etc.)
    mov rdi, [rdi]                     ; args[0] payload

    mov rax, [rdi + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_call]
    test rcx, rcx
    jz .callable_false

    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret

.callable_false:
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret

.callable_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "callable() takes exactly one argument"
    call raise_exception
END_FUNC builtin_callable

; ============================================================================
; 10. builtin_iter_fn(args, nargs) - iter(x)
; ============================================================================
DEF_FUNC builtin_iter_fn

    cmp rsi, 1
    jne .iter_error

    mov esi, [rdi + 8]                 ; args[0] tag
    mov rdi, [rdi]                     ; args[0] payload

    ; Use get_iterator which handles tp_iter, __iter__, __getitem__, validation
    extern get_iterator
    call get_iterator
    mov edx, TAG_PTR
    leave
    ret

.iter_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "iter() takes exactly one argument"
    call raise_exception
END_FUNC builtin_iter_fn

; ============================================================================
; 11. builtin_next_fn(args, nargs) - next(x)
; ============================================================================
DEF_FUNC builtin_next_fn
    push rbx

    cmp rsi, 1
    jne .next_error

    cmp qword [rdi + 8], TAG_SMALLINT  ; check args[0] tag
    je .next_type_error
    cmp qword [rdi + 8], TAG_PTR
    jne .next_type_error            ; non-pointer tag (TAG_FLOAT etc.)
    mov rdi, [rdi]                     ; args[0] payload

    mov rax, [rdi + PyObject.ob_type]
    mov rcx, rax                       ; save type
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jnz .next_have_iternext

    ; tp_iternext NULL — try __next__ on heaptype
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .next_type_error
    mov rbx, rdi                       ; save iterator
    extern dunder_next
    lea rsi, [rel dunder_next]
    extern dunder_call_1
    call dunder_call_1
    test edx, edx
    jnz .next_got_val                  ; got a value
    ; NULL from __next__ — check for StopIteration in current_exception
    extern current_exception
    mov rax, [rel current_exception]
    test rax, rax
    jz .next_stop                      ; no exception, clean exhaustion
    mov rcx, [rax + PyObject.ob_type]
    extern exc_StopIteration_type
    lea rdx, [rel exc_StopIteration_type]
    cmp rcx, rdx
    jne .next_got_val_null             ; other exception: leave it, propagate
    ; It's StopIteration — leave it as current_exception for raise
    jmp .next_stop
.next_got_val_null:
    ; Non-StopIteration exception set — return NULL to propagate
    RET_NULL
    pop rbx
    leave
    ret

.next_have_iternext:
    mov rbx, rdi                       ; save iterator for StopIteration.value
    call rax
    test edx, edx
    jz .next_stop

.next_got_val:
    ; tp_iternext / __next__ returns fat (rax=payload, rdx=tag)
    pop rbx
    leave
    ret

.next_stop:
    ; Check if iterator is a generator (has gi_return_value)
    lea rax, [rel gen_type]
    cmp [rbx + PyObject.ob_type], rax
    jne .next_stop_no_val
    ; Get generator's return value for StopIteration
    mov rsi, [rbx + PyGenObject.gi_return_value]
    mov rdx, [rbx + PyGenObject.gi_return_tag]
    test edx, edx
    jnz .next_stop_with_val
.next_stop_no_val:
    lea rsi, [rel none_singleton]
    mov edx, TAG_PTR
.next_stop_with_val:
    lea rdi, [rel exc_StopIteration_type]
    call exc_new
    mov rdi, rax
    call raise_exception_obj

.next_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "object is not an iterator"
    call raise_exception

.next_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "next() takes exactly one argument"
    call raise_exception
END_FUNC builtin_next_fn

; ============================================================================
; 12. builtin_any(args, nargs) - any(iterable)
; ============================================================================
DEF_FUNC builtin_any
    push rbx
    push r12
    push r13
    push r14

    cmp rsi, 1
    jne .any_error

    cmp qword [rdi + 8], TAG_PTR
    jne .any_type_error
    mov rdi, [rdi]
    mov rax, [rdi + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_iter]
    test rcx, rcx
    jz .any_type_error
    call rcx
    mov rbx, rax

    mov rax, [rbx + PyObject.ob_type]
    mov r12, [rax + PyTypeObject.tp_iternext]

.any_loop:
    mov rdi, rbx
    call r12
    test edx, edx             ; TAG_NULL = exhausted
    jz .any_false

    mov r13, rax               ; item payload
    mov r14, rdx               ; item tag

    mov rdi, r13
    mov rsi, r14
    call obj_is_true
    test eax, eax
    jnz .any_found_true

    ; Falsy: DECREF item and continue
    DECREF_VAL r13, r14
    jmp .any_loop

.any_found_true:
    DECREF_VAL r13, r14

.any_true:
    mov rdi, rbx
    call obj_decref
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.any_false:
    mov rdi, rbx
    call obj_decref
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.any_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "argument is not iterable"
    call raise_exception

.any_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "any() takes exactly one argument"
    call raise_exception
END_FUNC builtin_any

; ============================================================================
; 13. builtin_all(args, nargs) - all(iterable)
; ============================================================================
DEF_FUNC builtin_all
    push rbx
    push r12
    push r13
    push r14

    cmp rsi, 1
    jne .all_error

    cmp qword [rdi + 8], TAG_PTR
    jne .all_type_error
    mov rdi, [rdi]
    mov rax, [rdi + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_iter]
    test rcx, rcx
    jz .all_type_error
    call rcx
    mov rbx, rax

    mov rax, [rbx + PyObject.ob_type]
    mov r12, [rax + PyTypeObject.tp_iternext]

.all_loop:
    mov rdi, rbx
    call r12
    test edx, edx             ; TAG_NULL = exhausted
    jz .all_true

    mov r13, rax               ; item payload
    mov r14, rdx               ; item tag

    mov rdi, r13
    mov rsi, r14
    call obj_is_true
    test eax, eax
    jz .all_found_false

    ; Truthy: DECREF item and continue
    DECREF_VAL r13, r14
    jmp .all_loop

.all_found_false:
    DECREF_VAL r13, r14

.all_false:
    mov rdi, rbx
    call obj_decref
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.all_true:
    mov rdi, rbx
    call obj_decref
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.all_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "argument is not iterable"
    call raise_exception

.all_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "all() takes exactly one argument"
    call raise_exception
END_FUNC builtin_all

; ============================================================================
; 14. builtin_sum(args, nargs) - sum(iterable[, start])
; ============================================================================
DEF_FUNC builtin_sum
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    mov rbx, rdi
    mov r14, rsi

    cmp r14, 1
    jb .sum_error
    cmp r14, 2
    ja .sum_error

    cmp r14, 2
    je .sum_has_start
    xor eax, eax
    mov r13, rax
    mov qword [rsp], TAG_SMALLINT      ; accum_tag = SmallInt (0)
    jmp .sum_get_iter

.sum_has_start:
    mov r13, [rbx + 16]            ; args[1] payload (start value, 16-byte stride)
    mov eax, [rbx + 24]            ; args[1] tag
    mov [rsp], eax                 ; accum_tag
    cmp eax, TAG_PTR
    jne .sum_get_iter
    inc qword [r13 + PyObject.ob_refcnt]

.sum_get_iter:
    cmp qword [rbx + 8], TAG_PTR       ; args[0] tag
    jne .sum_type_error
    mov rdi, [rbx]                     ; args[0] payload (iterable)
    mov rax, [rdi + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_iter]
    test rcx, rcx
    jz .sum_type_error
    call rcx
    mov rbx, rax

    mov rax, [rbx + PyObject.ob_type]
    mov r12, [rax + PyTypeObject.tp_iternext]

.sum_loop:
    mov rdi, rbx
    call r12
    test edx, edx
    jz .sum_done

    mov r14, rax                   ; item payload
    mov r15d, edx                  ; item tag

    mov rdi, r13                   ; accum payload
    mov rsi, r14                   ; item payload
    mov edx, [rsp]                 ; accum tag (left_tag)
    mov ecx, r15d                  ; item tag (right_tag)
    ; Use float_add if either operand is float, else int_add
    cmp edx, TAG_FLOAT
    je .sum_float_add
    cmp ecx, TAG_FLOAT
    je .sum_float_add
    call int_add
    jmp .sum_have_result
.sum_float_add:
    extern float_add
    call float_add
.sum_have_result:
    ; rax = new accum payload, edx = new accum tag

    ; Save new accum before DECREFs
    push rax
    push rdx

    ; DECREF old accumulator (tag at [rsp+16] = original [rsp])
    mov rdi, r13
    mov esi, [rsp + 16]
    DECREF_VAL rdi, rsi

    ; DECREF item
    mov rdi, r14
    mov esi, r15d
    DECREF_VAL rdi, rsi

    ; Restore new accum
    pop rdx                        ; new accum tag
    pop r13                        ; new accum payload
    mov [rsp], edx                 ; update accum_tag slot

    jmp .sum_loop

.sum_done:
    mov rdi, rbx
    call obj_decref
    mov rax, r13
    mov edx, [rsp]                 ; accum_tag
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sum_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "argument is not iterable"
    call raise_exception

.sum_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "sum expected 1-2 arguments"
    call raise_exception
END_FUNC builtin_sum

; ============================================================================
; 15-16. builtin_min / builtin_max
; ============================================================================
; Shared implementation: minmax_impl(args, nargs, cmp_op)
;   rdi = args, rsi = nargs, edx = cmp_op (PY_LT=0 for min, PY_GT=4 for max)
; Returns (rax=payload, rdx=tag)
;
; Stack layout:
;   [rsp + MM_TAG]     = current best tag (64-bit)
;   [rsp + MM_CMP_RES] = richcompare result ptr
;   [rsp + MM_ITER]    = iterator ptr (iter path only)
;   [rsp + MM_ITERNX]  = tp_iternext fn ptr (iter path only)
;   [rsp + MM_CMP_OP]  = comparison op (PY_LT or PY_GT)
MM_TAG     equ 8
MM_CMP_RES equ 16
MM_ITER    equ 24
MM_ITERNX  equ 32
MM_CMP_OP  equ 40
MM_FRAME   equ 48

DEF_FUNC_BARE builtin_min
    xor edx, edx                   ; PY_LT = 0
    jmp minmax_impl
END_FUNC builtin_min

DEF_FUNC_BARE builtin_max
    mov edx, PY_GT                 ; PY_GT = 4
    jmp minmax_impl
END_FUNC builtin_max

DEF_FUNC_LOCAL minmax_impl, MM_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov [rbp - MM_CMP_OP], edx    ; save comparison op

    cmp rsi, 1
    jb .mm_error

    ; nargs == 1 → iterate the single argument
    cmp rsi, 1
    je .mm_iter_path

    ; --- Multi-arg path: min/max(a, b, ...) ---
    mov rbx, rdi                   ; args array
    mov r12, rsi                   ; nargs
    mov r13, 1                     ; index = 1

    mov r14, [rbx]                 ; args[0] payload = current best
    mov rax, [rbx + 8]            ; args[0] tag (64-bit)
    mov [rbp - MM_TAG], rax
    INCREF_VAL r14, rax

.mm_loop:
    cmp r13, r12
    jge .mm_done

    mov rax, r13
    shl rax, 4
    mov r15, [rbx + rax]          ; candidate payload
    mov rcx, [rbx + rax + 8]     ; candidate tag

    ; SmallInt fast path: both SmallInt?
    cmp qword [rbp - MM_TAG], TAG_SMALLINT
    jne .mm_slow
    cmp rcx, TAG_SMALLINT
    jne .mm_slow
    ; For min (PY_LT=0): update if candidate < best
    ; For max (PY_GT=4): update if candidate > best
    cmp dword [rbp - MM_CMP_OP], 0
    jne .mm_si_max
    cmp r15, r14
    jge .mm_no_update
    mov r14, r15
    jmp .mm_no_update
.mm_si_max:
    cmp r15, r14
    jle .mm_no_update
    mov r14, r15
    jmp .mm_no_update

.mm_slow:
    ; Resolve candidate type for richcompare
    mov r8, rcx                    ; save candidate tag
    test rcx, rcx
    js .mm_cand_ss
    cmp rcx, TAG_PTR
    jne .mm_try_float
    mov rdi, r15
    mov rax, [rdi + PyObject.ob_type]
    jmp .mm_have_type
.mm_cand_ss:
    lea rax, [rel str_type]
    jmp .mm_have_type
.mm_try_float:
    cmp rcx, TAG_FLOAT
    jne .mm_no_update
    lea rax, [rel float_type]
.mm_have_type:
    mov rcx, [rax + PyTypeObject.tp_richcompare]
    test rcx, rcx
    jz .mm_no_update

    ; tp_richcompare(candidate, best, cmp_op, cand_tag, best_tag)
    mov rdi, r15
    mov rsi, r14
    mov edx, [rbp - MM_CMP_OP]
    mov rax, rcx                   ; fn ptr
    mov rcx, r8                    ; left_tag = candidate tag
    mov r8, [rbp - MM_TAG]         ; right_tag = best tag
    call rax

    lea rcx, [rel bool_true]
    cmp rax, rcx
    mov [rbp - MM_CMP_RES], rax
    jne .mm_slow_no_upd

    ; Update best: DECREF old, set new = candidate
    mov rdi, r14
    mov rsi, [rbp - MM_TAG]
    DECREF_VAL rdi, rsi
    mov r14, r15
    mov rax, r13
    shl rax, 4
    mov rax, [rbx + rax + 8]
    mov [rbp - MM_TAG], rax
    INCREF_VAL r14, rax

    mov rdi, [rbp - MM_CMP_RES]
    call obj_decref
    jmp .mm_no_update

.mm_slow_no_upd:
    mov rdi, [rbp - MM_CMP_RES]
    call obj_decref

.mm_no_update:
    inc r13
    jmp .mm_loop

.mm_done:
    mov rax, r14
    mov rdx, [rbp - MM_TAG]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

    ; --- Iterator path: min/max(iterable) ---
.mm_iter_path:
    ; Get iterator from args[0]
    cmp qword [rdi + 8], TAG_PTR
    jne .mm_iter_type_error
    mov rdi, [rdi]                     ; iterable
    mov rax, [rdi + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_iter]
    test rcx, rcx
    jz .mm_iter_type_error
    call rcx
    test rax, rax
    jz .mm_iter_type_error
    mov [rbp - MM_ITER], rax
    mov rbx, [rax + PyObject.ob_type]
    mov rbx, [rbx + PyTypeObject.tp_iternext]
    mov [rbp - MM_ITERNX], rbx

    ; Get first element → initial best
    mov rdi, [rbp - MM_ITER]
    call rbx
    test edx, edx
    jz .mm_iter_empty

    mov r14, rax                       ; best payload
    mov [rbp - MM_TAG], rdx            ; best tag
    INCREF_VAL r14, rdx
    DECREF_VAL rax, rdx                ; DECREF iternext result

.mm_iter_loop:
    mov rdi, [rbp - MM_ITER]
    call qword [rbp - MM_ITERNX]
    test edx, edx
    jz .mm_iter_done

    mov r15, rax                       ; candidate payload
    mov r12, rdx                       ; candidate tag

    ; SmallInt fast path
    cmp qword [rbp - MM_TAG], TAG_SMALLINT
    jne .mm_iter_slow
    cmp r12, TAG_SMALLINT
    jne .mm_iter_slow
    cmp dword [rbp - MM_CMP_OP], 0
    jne .mm_iter_si_max
    cmp r15, r14
    jge .mm_iter_no_update
    mov r14, r15
    jmp .mm_iter_no_update
.mm_iter_si_max:
    cmp r15, r14
    jle .mm_iter_no_update
    mov r14, r15
    jmp .mm_iter_no_update

.mm_iter_slow:
    ; Resolve candidate type for richcompare
    mov rcx, r12
    test rcx, rcx
    js .mm_iter_cand_ss
    cmp rcx, TAG_PTR
    jne .mm_iter_try_float
    mov rdi, r15
    mov rax, [rdi + PyObject.ob_type]
    jmp .mm_iter_have_type
.mm_iter_cand_ss:
    lea rax, [rel str_type]
    jmp .mm_iter_have_type
.mm_iter_try_float:
    cmp rcx, TAG_FLOAT
    jne .mm_iter_no_update
    lea rax, [rel float_type]
.mm_iter_have_type:
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jz .mm_iter_no_update

    ; tp_richcompare(candidate, best, cmp_op, cand_tag, best_tag)
    mov rdi, r15
    mov rsi, r14
    mov edx, [rbp - MM_CMP_OP]
    mov rcx, r12
    mov r8, [rbp - MM_TAG]
    call rax

    lea rcx, [rel bool_true]
    cmp rax, rcx
    mov [rbp - MM_CMP_RES], rax
    jne .mm_iter_slow_no_upd

    ; Update best
    mov rdi, r14
    mov rsi, [rbp - MM_TAG]
    DECREF_VAL rdi, rsi
    mov r14, r15
    mov [rbp - MM_TAG], r12
    INCREF_VAL r14, r12

    mov rdi, [rbp - MM_CMP_RES]
    call obj_decref
    jmp .mm_iter_no_update

.mm_iter_slow_no_upd:
    mov rdi, [rbp - MM_CMP_RES]
    call obj_decref

.mm_iter_no_update:
    ; DECREF candidate
    DECREF_VAL r15, r12
    jmp .mm_iter_loop

.mm_iter_done:
    mov rdi, [rbp - MM_ITER]
    call obj_decref
    mov rax, r14
    mov rdx, [rbp - MM_TAG]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.mm_iter_empty:
    mov rdi, [rbp - MM_ITER]
    call obj_decref
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "min()/max() arg is an empty sequence"
    call raise_exception

.mm_iter_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "argument is not iterable"
    call raise_exception

.mm_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "min()/max() expected at least 1 argument"
    call raise_exception
END_FUNC minmax_impl

; ============================================================================
; 17. builtin_getattr(args, nargs) - getattr(obj, name[, default])
; ============================================================================
DEF_FUNC builtin_getattr
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi
    mov r12, rsi

    cmp r12, 2
    jb .getattr_error
    cmp r12, 3
    ja .getattr_error

    mov r13, [rbx]                 ; args[0] payload (obj)
    mov r14, [rbx + 16]            ; args[1] payload (name, 16-byte stride)

    cmp qword [rbx + 8], TAG_PTR       ; args[0] tag
    jne .getattr_try_type_dict

    mov rax, [r13 + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_getattr]
    test rcx, rcx
    jz .getattr_try_type_dict

    mov rdi, r13
    mov rsi, r14
    call rcx
    test edx, edx              ; check tag, not payload (SmallInt(0) has payload=0)
    jnz .getattr_found

    jmp .getattr_try_type_dict

.getattr_try_type_dict:
    cmp qword [rbx + 8], TAG_SMALLINT
    je .getattr_smallint_type
    cmp qword [rbx + 8], TAG_FLOAT
    je .getattr_float_type
    cmp qword [rbx + 8], TAG_BOOL
    je .getattr_bool_type
    cmp qword [rbx + 8], TAG_NONE
    je .getattr_none_type
    cmp qword [rbx + 8], TAG_PTR
    jne .getattr_not_found         ; unknown tag
    mov rax, [r13 + PyObject.ob_type]
    jmp .getattr_check_dict

.getattr_smallint_type:
    lea rax, [rel int_type]
    jmp .getattr_check_dict
.getattr_float_type:
    lea rax, [rel float_type]
    jmp .getattr_check_dict
.getattr_bool_type:
    lea rax, [rel bool_type]
    jmp .getattr_check_dict
.getattr_none_type:
    lea rax, [rel none_type]

.getattr_check_dict:
    mov rcx, [rax + PyTypeObject.tp_dict]
    test rcx, rcx
    jz .getattr_not_found

    mov rdi, rcx
    mov rsi, r14
    mov edx, TAG_PTR
    call dict_get
    test edx, edx
    jz .getattr_not_found

    INCREF_VAL rax, rdx
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.getattr_found:
    ; Result from tp_getattr could be any type
    ; rdx = tag already set by callee
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.getattr_not_found:
    cmp r12, 3
    jne .getattr_raise

    mov rax, [rbx + 32]           ; args[2] payload (default, 16-byte stride)
    mov rdx, [rbx + 40]           ; args[2] tag
    INCREF_VAL rax, rdx
.getattr_ret_default_si:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.getattr_raise:
    lea rdi, [rel exc_AttributeError_type]
    CSTRING rsi, "object has no attribute"
    call raise_exception

.getattr_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "getattr expected 2 or 3 arguments"
    call raise_exception
END_FUNC builtin_getattr

; ============================================================================
; 18. builtin_hasattr(args, nargs) - hasattr(obj, name)
; ============================================================================
DEF_FUNC builtin_hasattr
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    cmp rsi, 2
    jne .hasattr_error

    mov rbx, rdi                   ; save args ptr

    mov r12, [rbx]                 ; args[0] payload (obj)
    mov r13, [rbx + 16]            ; args[1] payload (name, 16-byte stride)

    cmp qword [rbx + 8], TAG_PTR       ; args[0] tag
    jne .hasattr_try_type_dict

    mov rax, [r12 + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_getattr]
    test rcx, rcx
    jz .hasattr_try_type_dict

    mov rdi, r12
    mov rsi, r13
    call rcx
    test edx, edx              ; check tag, not payload (SmallInt(0) has payload=0)
    jz .hasattr_try_type_dict

    ; Found via tp_getattr - DECREF result, return True
    mov rdi, rax
    DECREF_VAL rdi, rdx            ; use tag from tp_getattr return
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    leave
    ret

.hasattr_try_type_dict:
    cmp qword [rbx + 8], TAG_SMALLINT
    je .hasattr_smallint_type
    cmp qword [rbx + 8], TAG_FLOAT
    je .hasattr_float_type
    cmp qword [rbx + 8], TAG_BOOL
    je .hasattr_bool_type
    cmp qword [rbx + 8], TAG_NONE
    je .hasattr_none_type
    cmp qword [rbx + 8], TAG_PTR
    jne .hasattr_not_found         ; unknown tag
    mov rax, [r12 + PyObject.ob_type]
    jmp .hasattr_check_dict

.hasattr_smallint_type:
    lea rax, [rel int_type]
    jmp .hasattr_check_dict
.hasattr_float_type:
    lea rax, [rel float_type]
    jmp .hasattr_check_dict
.hasattr_bool_type:
    lea rax, [rel bool_type]
    jmp .hasattr_check_dict
.hasattr_none_type:
    lea rax, [rel none_type]

.hasattr_check_dict:
    mov rcx, [rax + PyTypeObject.tp_dict]
    test rcx, rcx
    jz .hasattr_not_found

    mov rdi, rcx
    mov rsi, r13
    mov edx, TAG_PTR
    call dict_get
    test edx, edx
    jz .hasattr_not_found

    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    leave
    ret

.hasattr_not_found:
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    leave
    ret

.hasattr_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "hasattr() takes exactly 2 arguments"
    call raise_exception
END_FUNC builtin_hasattr

; ============================================================================
; 19. builtin_setattr(args, nargs) - setattr(obj, name, value)
; ============================================================================
DEF_FUNC builtin_setattr
    mov rbp, rsp
    push rbx
    sub rsp, 8

    cmp rsi, 3
    jne .setattr_error

    mov rbx, rdi

    cmp qword [rbx + 8], TAG_PTR       ; args[0] tag
    jne .setattr_type_error
    mov rdi, [rbx]                     ; args[0] payload (obj)

    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_setattr]
    test rax, rax
    jz .setattr_type_error

    push rax                           ; save tp_setattr
    mov rdi, [rbx]                     ; args[0] payload (obj)
    mov rsi, [rbx + 16]               ; args[1] payload (name, 16-byte stride)
    mov rdx, [rbx + 32]               ; args[2] payload (value, 16-byte stride)
    mov rcx, [rbx + 40]               ; args[2] tag (value tag, 16-byte stride)
    pop rax                            ; restore tp_setattr
    call rax

    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    add rsp, 8
    pop rbx
    leave
    ret

.setattr_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "object does not support attribute assignment"
    call raise_exception

.setattr_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "setattr() takes exactly 3 arguments"
    call raise_exception
END_FUNC builtin_setattr

; ============================================================================
; builtin_globals(args, nargs) - globals()
; Returns the globals dict of the current frame.
; ============================================================================
DEF_FUNC builtin_globals
    cmp rsi, 0
    jne .globals_error

    ; Get current eval frame from saved r12
    mov rax, [rel eval_saved_r12]
    mov rax, [rax + PyFrame.globals]
    INCREF rax
    mov edx, TAG_PTR
    leave
    ret

.globals_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "globals() takes no arguments"
    call raise_exception
END_FUNC builtin_globals

; ============================================================================
; builtin_locals(args, nargs) - locals()
; Returns the locals dict if available, otherwise globals.
; In module scope, locals() == globals().
; In class body, returns the class dict.
; In function scope, returns globals as approximation.
; ============================================================================
DEF_FUNC builtin_locals
    cmp rsi, 0
    jne .locals_error

    ; Get current eval frame
    mov rax, [rel eval_saved_r12]
    ; Check if frame has a locals dict
    mov rcx, [rax + PyFrame.locals]
    test rcx, rcx
    jz .locals_use_globals
    ; Has locals dict - return it
    mov rax, rcx
    INCREF rax
    mov edx, TAG_PTR
    leave
    ret

.locals_use_globals:
    ; No locals dict - return globals (module scope)
    mov rax, [rax + PyFrame.globals]
    INCREF rax
    mov edx, TAG_PTR
    leave
    ret

.locals_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "locals() takes no arguments"
    call raise_exception
END_FUNC builtin_locals

; ============================================================================
; builtin_dir(args, nargs) - dir(obj)
; Returns list of attribute names from obj's type (and base chain) dicts.
; ============================================================================
DIR_LIST    equ 8       ; result list
DIR_OBJ     equ 16      ; the object
DIR_FRAME   equ 24

global builtin_dir
DEF_FUNC builtin_dir, DIR_FRAME
    push rbx
    push r12
    push r13

    cmp rsi, 1
    jne .dir_error

    mov rax, [rdi + 8]      ; args[0] tag
    mov r12, rax             ; save obj_tag in r12 temporarily
    mov rax, [rdi]           ; obj payload
    mov [rbp - DIR_OBJ], rax

    ; Create result list
    xor edi, edi
    call list_new
    mov [rbp - DIR_LIST], rax
    mov rbx, rax            ; rbx = result list

    ; Determine which dict to iterate:
    ; If obj is a type (ob_type == type_type or user_type_metatype), iterate tp_dict
    ; Otherwise, iterate instance __dict__ (if any), then class dict
    mov rax, [rbp - DIR_OBJ]
    cmp r12d, TAG_SMALLINT
    je .dir_done            ; SmallInt: no attributes
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel type_type]
    cmp rcx, rdx
    je .dir_from_type
    lea rdx, [rel user_type_metatype]
    cmp rcx, rdx
    je .dir_from_type

    ; Instance: get its type, iterate the type's dict chain
    mov r12, [rax + PyObject.ob_type]   ; r12 = type
    jmp .dir_walk_chain

.dir_from_type:
    ; obj IS a type: iterate its tp_dict chain
    mov r12, [rbp - DIR_OBJ]

.dir_walk_chain:
    ; r12 = current type to get keys from
    test r12, r12
    jz .dir_done

    mov rdi, [r12 + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .dir_next_base

    ; Iterate this dict's keys
    call dict_tp_iter
    mov r13, rax            ; r13 = iterator

.dir_iter_loop:
    mov rdi, r13
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .dir_iter_done
    mov rdi, r13
    call rax                ; tp_iternext(iter) -> key or NULL
    test edx, edx
    jz .dir_iter_done

    ; Check if key already in result list (avoid duplicates from base classes)
    push rax                ; save key
    mov rdi, rbx            ; list
    mov rsi, rax            ; key
    call list_contains
    test eax, eax
    pop rax                 ; restore key
    jnz .dir_iter_loop      ; already present, skip

    ; Append key to result
    push rax
    mov rdi, rbx
    mov rsi, rax
    mov edx, TAG_PTR
    call list_append
    pop rdi
    call obj_decref
    jmp .dir_iter_loop

.dir_iter_done:
    ; DECREF iterator
    mov rdi, r13
    call obj_decref

.dir_next_base:
    mov r12, [r12 + PyTypeObject.tp_base]
    jmp .dir_walk_chain

.dir_done:
    mov rax, rbx            ; return result list
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.dir_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "dir() takes exactly 1 argument"
    call raise_exception
END_FUNC builtin_dir

; ============================================================================
; builtin_eval_fn(args, nargs) - restricted literal evaluator
; Only evaluates integer literals (for test_int.py compatibility)
; ============================================================================
global builtin_eval_fn
DEF_FUNC builtin_eval_fn
    cmp rsi, 1
    jne .evl_error

    ; Get the string argument
    cmp qword [rdi + 8], TAG_SMALLINT  ; args[0] tag
    je .evl_type_error                 ; SmallInt: not a string
    mov rdi, [rdi]                     ; args[0] payload
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .evl_type_error

    ; Try parsing as integer literal with base 0 (auto-detect)
    lea rdi, [rdi + PyStrObject.data]
    xor esi, esi                ; base 0 = auto-detect
    call int_from_cstr_base
    test edx, edx            ; check tag (not payload — SmallInt 0 is valid)
    jnz .evl_done

    ; Parse failed — raise SyntaxError
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "invalid syntax"
    call raise_exception

.evl_done:
    ; Classify: SmallInt (bit63) or heap ptr
    ; rdx = tag already set by callee
    leave
    ret

.evl_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "eval() takes exactly 1 argument"
    call raise_exception

.evl_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "eval() arg 1 must be a string"
    call raise_exception
END_FUNC builtin_eval_fn

; ============================================================================
; builtin_round_fn(args, nargs) - round(number[, ndigits])
; 1 arg: round to nearest int (banker's rounding)
; 2 args: round to ndigits decimal places
; ============================================================================
extern exc_RuntimeError_type

global builtin_round_fn
RND_FRAME equ 16
DEF_FUNC builtin_round_fn, RND_FRAME
    push rbx

    cmp rsi, 1
    je .rnd_one_arg
    cmp rsi, 2
    je .rnd_two_arg
    jmp .rnd_error

.rnd_one_arg:
    ; round(x) — return int
    mov rax, [rdi]          ; payload
    mov ecx, [rdi + 8]     ; tag

    cmp ecx, TAG_SMALLINT
    je .rnd_int_ret          ; int → return as-is

    ; Extract double from TAG_FLOAT or TAG_PTR (PyFloatObject)
    cmp ecx, TAG_FLOAT
    je .rnd_one_raw_float
    cmp ecx, TAG_PTR
    jne .rnd_type_error
    ; Check if it's a PyFloatObject
    lea rcx, [rel float_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .rnd_one_check_int_obj
    movsd xmm0, [rax + PyFloatObject.value]
    jmp .rnd_one_do_round
.rnd_one_check_int_obj:
    ; Check if it's a PyIntObject (heap int)
    lea rcx, [rel int_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .rnd_type_error
    ; It's a heap int — convert to i64 and return as SmallInt
    mov rdi, rax
    call int_to_i64
    RET_TAG_SMALLINT
    pop rbx
    leave
    ret
.rnd_one_raw_float:
    movq xmm0, rax

.rnd_one_do_round:
    ; Float: banker's rounding (x86 default rounding mode = round-to-nearest-even)
    cvtsd2si rax, xmm0     ; round-to-nearest-even
    RET_TAG_SMALLINT
    pop rbx
    leave
    ret

.rnd_int_ret:
    RET_TAG_SMALLINT
    pop rbx
    leave
    ret

.rnd_two_arg:
    ; round(x, ndigits)
    mov rax, [rdi]          ; x payload
    mov ecx, [rdi + 8]     ; x tag
    mov rbx, [rdi + 16]    ; ndigits payload
    mov r8d, [rdi + 24]    ; ndigits tag

    ; ndigits must be int
    cmp r8d, TAG_SMALLINT
    jne .rnd_type_error

    ; Check x type — extract double
    cmp ecx, TAG_SMALLINT
    je .rnd_two_int
    cmp ecx, TAG_FLOAT
    je .rnd_two_raw_float
    cmp ecx, TAG_PTR
    jne .rnd_type_error
    ; Check if PyFloatObject
    lea rcx, [rel float_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .rnd_type_error
    movsd xmm0, [rax + PyFloatObject.value]
    jmp .rnd_two_got_float
.rnd_two_raw_float:
    movq xmm0, rax          ; xmm0 = x (double)
.rnd_two_got_float:

    ; round(float, ndigits): multiply by 10^ndigits, round, divide
    mov [rbp - RND_FRAME], rbx  ; save ndigits

    ; Compute 10^ndigits (ndigits in rbx as int64)
    mov rax, 1               ; multiplier = 1
    test rbx, rbx
    jz .rnd_two_no_scale
    js .rnd_two_neg_scale
    mov rcx, rbx
.rnd_pow10_loop:
    imul rax, 10
    dec rcx
    jnz .rnd_pow10_loop

.rnd_two_no_scale:
    ; xmm0 = x, rax = 10^ndigits
    cvtsi2sd xmm1, rax      ; xmm1 = 10^ndigits
    mulsd xmm0, xmm1        ; x * 10^n
    cvtsd2si rax, xmm0      ; banker's round
    cvtsi2sd xmm0, rax      ; back to double
    divsd xmm0, xmm1        ; / 10^n
    movq rax, xmm0
    mov edx, TAG_FLOAT
    pop rbx
    leave
    ret

.rnd_two_neg_scale:
    ; Negative ndigits for float: e.g., round(1234.5, -2) = 1200.0
    neg rbx
    mov rax, 1
    mov rcx, rbx
.rnd_pow10n_loop:
    imul rax, 10
    dec rcx
    jnz .rnd_pow10n_loop

    cvtsi2sd xmm1, rax      ; xmm1 = 10^|ndigits|
    divsd xmm0, xmm1        ; x / 10^n
    cvtsd2si rax, xmm0      ; banker's round
    cvtsi2sd xmm0, rax
    mulsd xmm0, xmm1        ; * 10^n
    movq rax, xmm0
    mov edx, TAG_FLOAT
    pop rbx
    leave
    ret

.rnd_two_int:
    ; round(int, ndigits) — ndigits >= 0: return int as-is
    ; ndigits < 0: round to nearest 10^|ndigits|
    test rbx, rbx
    jns .rnd_int_ret         ; ndigits >= 0, int stays the same

    ; Negative ndigits: round(1234, -2) = 1200
    neg rbx
    ; Compute 10^|ndigits|
    mov rcx, 1
.rnd_int_pow10:
    imul rcx, 10
    dec rbx
    jnz .rnd_int_pow10

    ; rax = x, rcx = divisor
    ; rounded = (x + divisor/2) / divisor * divisor (away from zero simple)
    ; Python uses banker's: convert to float, round, convert back
    cvtsi2sd xmm0, rax
    cvtsi2sd xmm1, rcx
    divsd xmm0, xmm1
    cvtsd2si rax, xmm0      ; banker's round
    imul rax, rcx
    RET_TAG_SMALLINT
    pop rbx
    leave
    ret

.rnd_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "round() takes 1 or 2 arguments"
    call raise_exception

.rnd_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "type cannot be rounded"
    call raise_exception
END_FUNC builtin_round_fn

; ============================================================================
; builtin_pow_fn(args, nargs) - pow(base, exp[, mod])
; 2 args: base ** exp
; 3 args: pow(base, exp, mod) — modular exponentiation
; ============================================================================
global builtin_pow_fn
POW_FRAME equ 24
DEF_FUNC builtin_pow_fn, POW_FRAME
    push rbx
    push r12
    push r13

    cmp rsi, 2
    je .pow_two
    cmp rsi, 3
    je .pow_three
    jmp .pow_error

.pow_two:
    ; pow(base, exp) — extract operands and delegate to int_power/float path
    mov rax, [rdi]          ; base payload
    mov ecx, [rdi + 8]     ; base tag
    mov rbx, [rdi + 16]    ; exp payload
    mov r8d, [rdi + 24]    ; exp tag

    ; Both SmallInt? Delegate to int_power (handles GMP overflow)
    cmp ecx, TAG_SMALLINT
    jne .pow_two_float
    cmp r8d, TAG_SMALLINT
    jne .pow_two_float

    ; int ** int — call int_power(base, exp, base_tag, exp_tag)
    extern int_power
    mov rdi, rax            ; base payload
    mov rsi, rbx            ; exp payload
    mov edx, ecx            ; base tag (TAG_SMALLINT)
    mov ecx, r8d            ; exp tag (TAG_SMALLINT)
    call int_power
    ; rax = result payload, edx = result tag
    pop r13
    pop r12
    pop rbx
    leave
    ret

.pow_two_float:
    ; At least one is float: convert both to double
    cmp ecx, TAG_SMALLINT
    jne .pow_f_base_float
    cvtsi2sd xmm0, rax
    jmp .pow_f_got_base
.pow_f_base_float:
    cmp ecx, TAG_FLOAT
    je .pow_f_base_raw
    ; TAG_PTR: extract from PyFloatObject
    cmp ecx, TAG_PTR
    jne .pow_type_error
    lea rcx, [rel float_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .pow_type_error
    movsd xmm0, [rax + PyFloatObject.value]
    jmp .pow_f_got_base
.pow_f_base_raw:
    movq xmm0, rax
.pow_f_got_base:
    cmp r8d, TAG_SMALLINT
    jne .pow_f_exp_float
    cvtsi2sd xmm1, rbx
    jmp .pow_f_got_exp
.pow_f_exp_float:
    cmp r8d, TAG_FLOAT
    je .pow_f_exp_raw
    ; TAG_PTR: extract from PyFloatObject
    cmp r8d, TAG_PTR
    jne .pow_type_error
    lea rcx, [rel float_type]
    cmp [rbx + PyObject.ob_type], rcx
    jne .pow_type_error
    movsd xmm1, [rbx + PyFloatObject.value]
    jmp .pow_f_got_exp
.pow_f_exp_raw:
    movq xmm1, rbx
.pow_f_got_exp:
    ; xmm0 = base, xmm1 = exp
    ; Use repeated squaring for integer exponents, or fall back to exp*ln
    ; Simple: convert to C pow() equivalent using exp/ln
    ; x^y = exp2(y * log2(x)) — but we don't have those instructions easily
    ; Use a simpler approach: if exp is a small integer, use repeated mult
    cvtsd2si rcx, xmm1
    cvtsi2sd xmm2, rcx
    ucomisd xmm1, xmm2
    jne .pow_f_general       ; exp is not an integer
    jp .pow_f_general        ; NaN

    ; Integer exponent: repeated squaring
    mov r13, rcx
    test r13, r13
    js .pow_f_neg

    movq xmm2, [rel const_one] ; result = 1.0
.pow_f_sq:
    test r13, r13
    jz .pow_f_sq_done
    test r13, 1
    jz .pow_f_sq_even
    mulsd xmm2, xmm0
.pow_f_sq_even:
    mulsd xmm0, xmm0
    shr r13, 1
    jmp .pow_f_sq
.pow_f_sq_done:
    movq rax, xmm2
    mov edx, TAG_FLOAT
    pop r13
    pop r12
    pop rbx
    leave
    ret

.pow_f_neg:
    neg r13
    movq xmm2, [rel const_one]
.pow_f_neg_sq:
    test r13, r13
    jz .pow_f_neg_done
    test r13, 1
    jz .pow_f_neg_even
    mulsd xmm2, xmm0
.pow_f_neg_even:
    mulsd xmm0, xmm0
    shr r13, 1
    jmp .pow_f_neg_sq
.pow_f_neg_done:
    movq xmm0, [rel const_one]
    divsd xmm0, xmm2
    movq rax, xmm0
    mov edx, TAG_FLOAT
    pop r13
    pop r12
    pop rbx
    leave
    ret

.pow_f_general:
    ; Non-integer float exponent: x^y = 2^(y * log2(x))
    ; xmm0 = base, xmm1 = exp
    ; fyl2x computes st(1) * log2(st(0)), so load exp first, then base
    sub rsp, 16
    movsd [rsp], xmm1          ; exp on stack
    fld qword [rsp]             ; st(0) = exp
    movsd [rsp], xmm0          ; base on stack
    fld qword [rsp]             ; st(0) = base, st(1) = exp
    fyl2x                       ; st(0) = exp * log2(base)
    ; Compute 2^st(0): split into int + frac
    fld st0                     ; dup
    frndint                     ; st(0) = int part
    fsub st1, st0               ; st(1) = frac part
    fxch st1                    ; st(0) = frac, st(1) = int
    f2xm1                       ; st(0) = 2^frac - 1
    fld1
    faddp st1, st0              ; st(0) = 2^frac
    fscale                      ; st(0) = 2^frac * 2^int = result
    fstp st1                    ; pop int part
    fstp qword [rsp]            ; store result
    movsd xmm0, [rsp]
    add rsp, 16
    movq rax, xmm0
    mov edx, TAG_FLOAT
    pop r13
    pop r12
    pop rbx
    leave
    ret

.pow_three:
    ; pow(base, exp, mod) — modular exponentiation
    mov rax, [rdi]          ; base
    mov ecx, [rdi + 8]     ; base tag
    mov rbx, [rdi + 16]    ; exp
    mov r8d, [rdi + 24]    ; exp tag
    mov r12, [rdi + 32]    ; mod
    mov r9d, [rdi + 40]    ; mod tag

    ; All must be SmallInt
    cmp ecx, TAG_SMALLINT
    jne .pow_type_error
    cmp r8d, TAG_SMALLINT
    jne .pow_type_error
    cmp r9d, TAG_SMALLINT
    jne .pow_type_error

    ; exp must be >= 0
    test rbx, rbx
    js .pow_neg_mod_exp
    ; mod must be != 0
    test r12, r12
    jz .pow_zero_mod

    ; Modular exponentiation: result = base^exp mod mod
    mov r13, rbx            ; exp
    ; rax = base, r12 = mod
    ; Reduce base mod first
    cqo
    idiv r12                ; rax=quot, rdx=rem
    mov rax, rdx            ; base = base % mod
    ; Adjust remainder to match Python semantics (sign of mod)
    test rax, rax
    jz .pow_mod_pos
    mov rdx, rax
    xor rdx, r12
    jns .pow_mod_pos         ; same sign → OK
    add rax, r12             ; different signs → adjust
.pow_mod_pos:
    mov rcx, 1              ; result = 1
.pow_mod_loop:
    test r13, r13
    jz .pow_mod_done
    test r13, 1
    jz .pow_mod_even
    imul rcx, rax           ; result *= base
    ; result %= mod
    push rax
    mov rax, rcx
    cqo
    idiv r12
    mov rcx, rdx
    test rcx, rcx
    jz .pow_mod_pos2
    mov rdx, rcx
    xor rdx, r12
    jns .pow_mod_pos2
    add rcx, r12
.pow_mod_pos2:
    pop rax
.pow_mod_even:
    imul rax, rax           ; base *= base
    ; base %= mod
    push rcx
    cqo
    idiv r12
    mov rax, rdx
    test rax, rax
    jz .pow_mod_pos3
    mov rdx, rax
    xor rdx, r12
    jns .pow_mod_pos3
    add rax, r12
.pow_mod_pos3:
    pop rcx
    shr r13, 1
    jmp .pow_mod_loop
.pow_mod_done:
    ; Apply final result % mod (needed for exp=0 case: pow(x,0,mod) = 1 % mod)
    mov rax, rcx
    cqo
    idiv r12
    mov rax, rdx
    test rax, rax
    jz .pow_mod_final
    mov rdx, rax
    xor rdx, r12
    jns .pow_mod_final
    add rax, r12
.pow_mod_final:
    RET_TAG_SMALLINT
    pop r13
    pop r12
    pop rbx
    leave
    ret

.pow_neg_mod_exp:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "pow() 2nd argument cannot be negative when 3rd argument specified"
    call raise_exception

.pow_zero_mod:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "pow() 3rd argument cannot be 0"
    call raise_exception

.pow_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "pow() takes 2 or 3 arguments"
    call raise_exception

.pow_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "pow() arguments must be numeric"
    call raise_exception
END_FUNC builtin_pow_fn

section .rodata
align 8
const_one: dq 0x3FF0000000000000   ; 1.0 in IEEE 754

section .text

; ============================================================================
; builtin_input_fn(args, nargs) - input([prompt])
; 0 args: read line from stdin
; 1 arg: print prompt, then read line
; ============================================================================
extern sys_write
extern sys_read

global builtin_input_fn
INP_BUF_SIZE equ 4096
INP_FRAME equ INP_BUF_SIZE + 16  ; buffer + saved values
DEF_FUNC builtin_input_fn, INP_FRAME
    cmp rsi, 0
    je .inp_no_prompt
    cmp rsi, 1
    jne .inp_error

    ; Print prompt to stdout
    mov rax, [rdi]          ; prompt payload
    mov rcx, [rdi + 8]     ; prompt tag (64-bit)

    cmp rcx, TAG_PTR
    jne .inp_type_error
    ; Write prompt string data
    mov rsi, rax
    add rsi, PyStrObject.data  ; buf ptr
    mov rdx, [rax + PyStrObject.ob_size]  ; len
    mov edi, 1              ; stdout
    call sys_write

.inp_no_prompt:
    ; Read line from stdin into stack buffer
    lea rsi, [rbp - INP_FRAME]  ; buffer
    mov edx, INP_BUF_SIZE - 1
    xor edi, edi            ; stdin (fd=0)
    call sys_read
    ; rax = bytes read (or negative on error)
    test rax, rax
    jle .inp_empty

    ; Strip trailing newline
    lea rdi, [rbp - INP_FRAME]
    mov rcx, rax
    dec rcx
    cmp byte [rdi + rcx], 10  ; '\n'
    jne .inp_no_strip
    dec rax                  ; exclude newline
.inp_no_strip:
    ; Null-terminate
    mov byte [rdi + rax], 0

    ; Create string from buffer
    ; rdi already points to buffer
    call str_from_cstr
    leave
    ret

.inp_empty:
    ; EOF or error: return empty string
    CSTRING rdi, ""
    call str_from_cstr
    leave
    ret

.inp_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "input() takes at most 1 argument"
    call raise_exception

.inp_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "input() prompt must be a string"
    call raise_exception
END_FUNC builtin_input_fn

; ============================================================================
; builtin_open_fn(args, nargs) - open(filename[, mode])
; 1 arg: open for reading ('r')
; 2 args: open with specified mode
; ============================================================================
extern sys_open
extern sys_close
extern file_type

global builtin_open_fn
OPN_FRAME equ 32
DEF_FUNC builtin_open_fn, OPN_FRAME
    push rbx
    push r12
    push r13

    cmp rsi, 1
    je .opn_default_mode
    cmp rsi, 2
    je .opn_with_mode
    jmp .opn_error

.opn_default_mode:
    ; filename only — default mode 'r'
    mov rax, [rdi]          ; filename str
    mov rcx, [rdi + 8]     ; filename tag (64-bit)
    cmp rcx, TAG_PTR
    jne .opn_type_error
    mov rbx, rax            ; save filename str

    ; Open read-only: O_RDONLY=0
    lea rdi, [rax + PyStrObject.data]
    xor esi, esi            ; flags = O_RDONLY
    xor edx, edx            ; mode = 0
    call sys_open
    mov r12, rax            ; fd
    test rax, rax
    js .opn_file_error

    ; Create default mode string "r" (heap — stored in PyFileObject struct field)
    CSTRING rdi, "r"
    call str_from_cstr_heap
    mov r13, rax            ; mode str
    jmp .opn_create_fileobj

.opn_with_mode:
    mov rax, [rdi]          ; filename str
    mov rcx, [rdi + 8]     ; filename tag (64-bit)
    push rdi                ; save args ptr
    cmp rcx, TAG_PTR
    jne .opn_type_error_pop
    mov rbx, rax            ; save filename str
    pop rdi                 ; restore args ptr

    mov rax, [rdi + 16]    ; mode str
    mov rcx, [rdi + 24]    ; mode tag (64-bit)
    cmp rcx, TAG_PTR
    jne .opn_type_error
    mov r13, rax            ; save mode str

    ; Parse mode string
    lea rdi, [rax + PyStrObject.data]
    movzx eax, byte [rdi]

    cmp al, 'r'
    je .opn_mode_r
    cmp al, 'w'
    je .opn_mode_w
    cmp al, 'a'
    je .opn_mode_a
    cmp al, 'x'
    je .opn_mode_x
    jmp .opn_bad_mode

.opn_mode_r:
    ; Check for 'r+' or 'rb' or just 'r'
    movzx ecx, byte [rdi + 1]
    cmp cl, '+'
    je .opn_rw
    xor esi, esi            ; O_RDONLY
    jmp .opn_do_open

.opn_rw:
    mov esi, 2              ; O_RDWR
    jmp .opn_do_open

.opn_mode_w:
    mov esi, 0x241          ; O_WRONLY|O_CREAT|O_TRUNC (1|0x40|0x200)
    jmp .opn_do_open

.opn_mode_a:
    mov esi, 0x441          ; O_WRONLY|O_CREAT|O_APPEND (1|0x40|0x400)
    jmp .opn_do_open

.opn_mode_x:
    mov esi, 0xC1           ; O_WRONLY|O_CREAT|O_EXCL (1|0x40|0x80)
    jmp .opn_do_open

.opn_do_open:
    push rsi                ; save flags
    lea rdi, [rbx + PyStrObject.data]  ; filename cstr
    pop rsi                 ; restore flags
    mov edx, 0644o          ; default file permissions
    call sys_open
    mov r12, rax
    test rax, rax
    js .opn_file_error

    ; INCREF mode str (we're storing a ref)
    mov rdi, r13
    call obj_incref

.opn_create_fileobj:
    ; Allocate PyFileObject
    mov edi, PyFileObject_size
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel file_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyFileObject.file_fd], r12
    mov [rax + PyFileObject.file_name], rbx
    mov [rax + PyFileObject.file_mode], r13

    ; INCREF filename (storing ref)
    push rax
    mov rdi, rbx
    call obj_incref
    pop rax

    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.opn_file_error:
    extern exc_FileNotFoundError_type
    lea rdi, [rel exc_FileNotFoundError_type]
    CSTRING rsi, "No such file or directory"
    call raise_exception

.opn_bad_mode:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "invalid mode string"
    call raise_exception

.opn_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "open() takes 1 or 2 arguments"
    call raise_exception

.opn_type_error_pop:
    add rsp, 8                 ; discard saved args ptr
.opn_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "open() arguments must be strings"
    call raise_exception
END_FUNC builtin_open_fn

; ============================================================================
; builtin_bin(args, nargs) - bin(x)
; Returns binary string representation: '0b...' or '-0b...'
; ============================================================================
global builtin_bin
DEF_FUNC builtin_bin, 80

    cmp rsi, 1
    jne .bin_nargs_error

    mov edx, [rdi + 8]
    mov rdi, [rdi]
    call int_to_i64

    test rax, rax
    jz .bin_zero

    test rax, rax
    jns .bin_positive

    ; Negative
    neg rax
    mov byte [rbp - 80], '-'
    mov byte [rbp - 79], '0'
    mov byte [rbp - 78], 'b'
    lea rdi, [rbp - 77]
    mov r8d, 3
    jmp .bin_digits

.bin_positive:
    mov byte [rbp - 80], '0'
    mov byte [rbp - 79], 'b'
    lea rdi, [rbp - 78]
    mov r8d, 2

.bin_digits:
    lea rsi, [rbp - 16]
    xor ecx, ecx

.bin_digit_loop:
    test rax, rax
    jz .bin_reverse

    mov rdx, rax
    and edx, 1
    add edx, '0'
    mov byte [rsi], dl
    dec rsi
    inc ecx
    shr rax, 1
    jmp .bin_digit_loop

.bin_reverse:
    inc rsi
    mov edx, ecx
.bin_copy_loop:
    test ecx, ecx
    jz .bin_done_copy
    mov al, byte [rsi]
    mov byte [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jmp .bin_copy_loop

.bin_done_copy:
    mov byte [rdi], 0
    lea rdi, [rbp - 80]
    call str_from_cstr
    leave
    ret

.bin_zero:
    CSTRING rdi, "0b0"
    call str_from_cstr
    leave
    ret

.bin_nargs_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "bin() takes exactly one argument"
    call raise_exception
END_FUNC builtin_bin

; ============================================================================
; builtin_oct(args, nargs) - oct(x)
; Returns octal string representation: '0o...' or '-0o...'
; ============================================================================
global builtin_oct
DEF_FUNC builtin_oct, 80

    cmp rsi, 1
    jne .oct_nargs_error

    mov edx, [rdi + 8]
    mov rdi, [rdi]
    call int_to_i64

    test rax, rax
    jz .oct_zero

    test rax, rax
    jns .oct_positive

    ; Negative
    neg rax
    mov byte [rbp - 80], '-'
    mov byte [rbp - 79], '0'
    mov byte [rbp - 78], 'o'
    lea rdi, [rbp - 77]
    mov r8d, 3
    jmp .oct_digits

.oct_positive:
    mov byte [rbp - 80], '0'
    mov byte [rbp - 79], 'o'
    lea rdi, [rbp - 78]
    mov r8d, 2

.oct_digits:
    lea rsi, [rbp - 16]
    xor ecx, ecx

.oct_digit_loop:
    test rax, rax
    jz .oct_reverse

    mov rdx, rax
    and edx, 7
    add edx, '0'
    mov byte [rsi], dl
    dec rsi
    inc ecx
    shr rax, 3
    jmp .oct_digit_loop

.oct_reverse:
    inc rsi
    mov edx, ecx
.oct_copy_loop:
    test ecx, ecx
    jz .oct_done_copy
    mov al, byte [rsi]
    mov byte [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jmp .oct_copy_loop

.oct_done_copy:
    mov byte [rdi], 0
    lea rdi, [rbp - 80]
    call str_from_cstr
    leave
    ret

.oct_zero:
    CSTRING rdi, "0o0"
    call str_from_cstr
    leave
    ret

.oct_nargs_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "oct() takes exactly one argument"
    call raise_exception
END_FUNC builtin_oct

; ============================================================================
; builtin_ascii_fn(args, nargs) - ascii(obj)
; Like repr() but escapes non-ASCII characters to \xNN / \uNNNN / \UNNNNNNNN
; ============================================================================
extern ap_realloc
global builtin_ascii_fn
AA_REPR   equ 8
AA_FRAME  equ 16
DEF_FUNC builtin_ascii_fn, AA_FRAME

    cmp rsi, 1
    jne .aa_nargs_error

    ; Get repr(obj)
    mov esi, [rdi + 8]       ; tag
    mov rdi, [rdi]            ; payload
    call obj_repr
    test edx, edx
    jz .aa_nargs_error

    ; Check if all chars are ASCII (fast path)
    mov [rbp - AA_REPR], rax
    lea rsi, [rax + PyStrObject.data]
    mov rcx, [rax + PyStrObject.ob_size]
    xor edx, edx              ; edx = index
.aa_check_loop:
    cmp edx, ecx
    jge .aa_all_ascii
    movzx eax, byte [rsi + rdx]
    cmp eax, 128
    jae .aa_need_escape
    inc edx
    jmp .aa_check_loop

.aa_all_ascii:
    ; Repr is all ASCII — just return it
    mov rax, [rbp - AA_REPR]
    mov edx, TAG_PTR
    leave
    ret

.aa_need_escape:
    ; We need to build a new string with non-ASCII chars escaped
    ; For simplicity, allocate a buffer big enough (4x original + 1)
    push rbx
    push r12
    push r13

    mov rbx, [rbp - AA_REPR]  ; rbx = repr str
    mov r12, [rbx + PyStrObject.ob_size]  ; r12 = original length
    lea rdi, [r12*4 + 8]      ; worst case: every char becomes \xNN (4 chars) + 8 NUL pad
    call ap_malloc
    mov r13, rax               ; r13 = output buffer

    lea rsi, [rbx + PyStrObject.data]  ; rsi = input
    mov rdi, r13               ; rdi = output
    xor ecx, ecx              ; ecx = input index
.aa_escape_loop:
    cmp ecx, r12d
    jge .aa_escape_done
    movzx eax, byte [rsi + rcx]
    cmp eax, 128
    jae .aa_do_escape
    mov byte [rdi], al
    inc rdi
    inc ecx
    jmp .aa_escape_loop

.aa_do_escape:
    ; Emit \xHH
    mov byte [rdi], '\'
    mov byte [rdi + 1], 'x'
    add rdi, 2
    ; High nibble
    mov edx, eax
    shr edx, 4
    cmp edx, 10
    jb .aa_hi_dec
    add edx, ('a' - 10)
    jmp .aa_hi_store
.aa_hi_dec:
    add edx, '0'
.aa_hi_store:
    mov byte [rdi], dl
    inc rdi
    ; Low nibble
    mov edx, eax
    and edx, 0xF
    cmp edx, 10
    jb .aa_lo_dec
    add edx, ('a' - 10)
    jmp .aa_lo_store
.aa_lo_dec:
    add edx, '0'
.aa_lo_store:
    mov byte [rdi], dl
    inc rdi
    inc ecx
    jmp .aa_escape_loop

.aa_escape_done:
    mov qword [rdi], 0         ; 8-byte zero-fill for ap_strcmp
    sub rdi, r13               ; rdi = output length

    ; Create string from buffer
    mov rdi, r13
    call str_from_cstr
    push rax
    push rdx

    ; Free buffer
    mov rdi, r13
    call ap_free

    ; DECREF original repr
    mov rdi, rbx
    call obj_decref

    pop rdx
    pop rax
    pop r13
    pop r12
    pop rbx
    leave
    ret

.aa_nargs_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "ascii() takes exactly one argument"
    call raise_exception
END_FUNC builtin_ascii_fn

; ============================================================================
; builtin_format_fn(args, nargs) - format(value[, format_spec])
; Calls value.__format__(format_spec) or str(value) if no __format__
; ============================================================================
global builtin_format_fn
FMT_OBJ     equ 8
FMT_OBJ_TAG equ 16
FMT_SPEC    equ 24
FMT_FRAME   equ 32
DEF_FUNC builtin_format_fn, FMT_FRAME

    cmp rsi, 1
    jb .fmt_nargs_error
    cmp rsi, 2
    ja .fmt_nargs_error

    push rbx
    mov rbx, rsi               ; rbx = nargs

    ; Save obj
    mov rax, [rdi]
    mov [rbp - FMT_OBJ], rax
    mov rax, [rdi + 8]
    mov [rbp - FMT_OBJ_TAG], rax

    ; Get format spec (empty string if not provided)
    cmp rbx, 2
    jb .fmt_empty_spec
    mov rax, [rdi + 16]
    mov [rbp - FMT_SPEC], rax
    jmp .fmt_have_spec

.fmt_empty_spec:
    CSTRING rdi, ""
    call str_from_cstr
    mov [rbp - FMT_SPEC], rax

.fmt_have_spec:
    ; For now, always use str(value) as fallback.
    ; TODO: implement __format__ protocol for non-empty format specs.
    jmp .fmt_use_str

.fmt_use_str:
    ; Just call str(value) — simple fallback
    mov rdi, [rbp - FMT_OBJ]
    mov rsi, [rbp - FMT_OBJ_TAG]
    call obj_str
    ; If we allocated an empty spec, DECREF it
    cmp rbx, 2
    jge .fmt_done
    push rax
    push rdx
    mov rdi, [rbp - FMT_SPEC]
    call obj_decref
    pop rdx
    pop rax
.fmt_done:
    pop rbx
    leave
    ret

.fmt_nargs_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "format() takes 1 or 2 arguments"
    call raise_exception
END_FUNC builtin_format_fn

; ============================================================================
; builtin_vars_fn(args, nargs) - vars([obj])
; 0 args: returns frame locals dict (same as locals())
; 1 arg: returns obj.__dict__
; ============================================================================
extern eval_saved_r12
global builtin_vars_fn
VR_FRAME equ 8
DEF_FUNC builtin_vars_fn, VR_FRAME

    test rsi, rsi
    jz .vars_no_arg
    cmp rsi, 1
    jne .vars_nargs_error

    ; vars(obj): return obj.__dict__
    mov rax, [rdi + 8]        ; tag
    cmp eax, TAG_PTR
    jne .vars_no_dict

    mov rdi, [rdi]            ; obj pointer
    ; Try inst_dict (user-defined class instances)
    mov rax, [rdi + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_flags]
    test ecx, TYPE_FLAG_HEAPTYPE
    jz .vars_no_dict

    ; User instance: get inst_dict
    mov rax, [rdi + PyInstanceObject.inst_dict]
    test rax, rax
    jz .vars_empty_dict
    INCREF rax
    mov edx, TAG_PTR
    leave
    ret

.vars_empty_dict:
    ; Instance has no dict yet — create empty dict
    call dict_new
    mov edx, TAG_PTR
    leave
    ret

.vars_no_arg:
    ; Same as locals()
    extern builtin_locals
    xor edi, edi
    xor esi, esi
    call builtin_locals
    leave
    ret

.vars_no_dict:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "vars() argument must have __dict__ attribute"
    call raise_exception

.vars_nargs_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "vars() takes at most 1 argument"
    call raise_exception
END_FUNC builtin_vars_fn

; ============================================================================
; builtin_delattr_fn(args, nargs) - delattr(obj, name)
; Calls tp_setattr(obj, name, NULL) to delete
; ============================================================================
extern dict_del
global builtin_delattr_fn
DA2_OBJ   equ 8
DA2_NAME  equ 16
DA2_FRAME equ 24
DEF_FUNC builtin_delattr_fn, DA2_FRAME

    cmp rsi, 2
    jne .da2_nargs_error

    ; Get obj and name
    mov rax, [rdi]             ; obj payload
    mov [rbp - DA2_OBJ], rax
    mov rax, [rdi + 16]       ; name payload
    mov [rbp - DA2_NAME], rax

    ; obj must be a heap pointer
    cmp dword [rdi + 8], TAG_PTR
    jne .da2_type_error

    ; Get type and tp_setattr
    mov rdi, [rbp - DA2_OBJ]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_setattr]
    test rax, rax
    jz .da2_attr_error

    ; Call tp_setattr(obj, name, NULL=delete)
    mov rdi, [rbp - DA2_OBJ]
    mov rsi, [rbp - DA2_NAME]
    xor edx, edx              ; value = NULL means delete
    xor ecx, ecx              ; value tag = TAG_NULL
    call rax

    ; Return None
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    ret

.da2_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "delattr: first argument must be an object"
    call raise_exception

.da2_attr_error:
    lea rdi, [rel exc_AttributeError_type]
    CSTRING rsi, "object does not support attribute deletion"
    call raise_exception

.da2_nargs_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "delattr() takes exactly 2 arguments"
    call raise_exception
END_FUNC builtin_delattr_fn

; ============================================================================
; builtin_aiter_fn(args, nargs) - aiter(async_iterable)
; Calls tp_iter on the async iterable
; ============================================================================
global builtin_aiter_fn
DEF_FUNC builtin_aiter_fn

    cmp rsi, 1
    jne .aiter_nargs_error

    ; Get the object
    mov esi, [rdi + 8]        ; tag
    mov rdi, [rdi]            ; payload

    ; Must be a heap pointer
    cmp esi, TAG_PTR
    jne .aiter_type_error

    ; Call tp_iter
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz .aiter_type_error

    call rax                   ; tp_iter returns rax=ptr only
    mov edx, TAG_PTR
    leave
    ret

.aiter_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "object is not an async iterable"
    call raise_exception

.aiter_nargs_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "aiter() takes exactly 1 argument"
    call raise_exception
END_FUNC builtin_aiter_fn

; ============================================================================
; builtin_anext_fn(args, nargs) - anext(async_iterator[, default])
; Calls tp_iternext; on StopAsyncIteration returns default
; ============================================================================
extern exc_StopAsyncIteration_type
extern current_exception
global builtin_anext_fn
AN_ITER    equ 8
AN_DEFAULT equ 16
AN_DEFTAG  equ 24
AN_NARGS   equ 32
AN_FRAME   equ 40
DEF_FUNC builtin_anext_fn, AN_FRAME

    cmp rsi, 1
    jb .an_nargs_error
    cmp rsi, 2
    ja .an_nargs_error

    mov [rbp - AN_NARGS], rsi

    ; Save iterator
    mov rax, [rdi]
    mov [rbp - AN_ITER], rax

    ; Save default if present
    cmp rsi, 2
    jb .an_no_default
    mov rax, [rdi + 16]
    mov [rbp - AN_DEFAULT], rax
    mov eax, [rdi + 24]
    mov [rbp - AN_DEFTAG], rax
    jmp .an_call

.an_no_default:
    mov qword [rbp - AN_DEFAULT], 0
    mov qword [rbp - AN_DEFTAG], 0

.an_call:
    ; Call tp_iternext
    mov rdi, [rbp - AN_ITER]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .an_type_error

    mov rdi, [rbp - AN_ITER]
    call rax                   ; returns (rax, edx)
    test edx, edx
    jnz .an_got_value

    ; Got NULL — check if we have a default
    cmp qword [rbp - AN_NARGS], 2
    jb .an_reraise

    ; Clear the exception and return default
    mov qword [rel current_exception], 0
    mov rax, [rbp - AN_DEFAULT]
    mov edx, [rbp - AN_DEFTAG]
    INCREF_VAL rax, rdx
    leave
    ret

.an_got_value:
    leave
    ret

.an_reraise:
    ; No default — let the exception propagate
    leave
    ret

.an_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "object is not an async iterator"
    call raise_exception

.an_nargs_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "anext() takes 1 or 2 arguments"
    call raise_exception
END_FUNC builtin_anext_fn

; ============================================================================
; builtin_import_fn(args, nargs) - __import__(name, ...)
; Wraps import_module(name_str, fromlist=NULL, level=0)
; Only uses first arg (name), ignores globals/locals/fromlist/level for now
; ============================================================================
extern import_module
global builtin_import_fn
DEF_FUNC builtin_import_fn

    cmp rsi, 1
    jb .imp_nargs_error

    ; Get name string
    mov rdi, [rdi]             ; name payload (must be str)
    xor esi, esi               ; fromlist = NULL
    xor edx, edx              ; level = 0
    call import_module
    ; Returns (rax=module, edx=TAG_PTR)
    leave
    ret

.imp_nargs_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "__import__() requires at least 1 argument"
    call raise_exception
END_FUNC builtin_import_fn
