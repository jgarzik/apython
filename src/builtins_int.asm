; builtins_int.asm - int(), and the three protocols it consults.
;
; Split off when builtins_num.asm reached the 100k cap that
; src/compiler/lint.py enforces.  The seam is the one the file already had:
; this is one function, it is a third of the file on its own, and it shares
; nothing with the builtins around it but the externs below.
;
; What makes it that big is that int() is four converters wearing one name.
; A str, bytes or bytearray argument is PARSED, in any base from 2 to 36,
; with CPython's underscore rules and its exact error wording.  A float is
; truncated toward zero.  An int subclass has its value extracted unless it
; overrides __int__.  And anything else goes through __int__, then __index__,
; then __trunc__ -- in that order, each one deprecating differently, and each
; of the three having to bind what the MRO answered with before calling it.
;
; deprecation_warn stays in builtins_num.asm: it is the one place assembly
; raises a Python warning, and round() and the rest reach for it too.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

extern obj_incref
extern obj_decref
extern obj_dealloc
extern obj_repr
extern obj_as_index
extern int_to_i64
extern int_base_str
extern int_is_integer
extern int_neg
extern int_from_cstr_base
extern int_promote_mpz
extern float_from_f64
extern float_int
extern ap_malloc
extern ap_free
extern ap_memcpy
extern ap_strcmp
extern str_new
extern str_from_cstr
extern str_from_cstr_heap
extern raise_exception
extern raise_type_error_with_name
extern exc_new
extern eval_exception_unwind
extern type_name_message
extern dunder_lookup
extern dunder_bind
extern deprecation_warn
extern __gmpz_fits_slong_p
extern strlen

extern int_type
extern float_type
extern bool_type
extern bool_true
extern str_type
extern bytes_type
extern bytearray_type
extern array_type
extern memoryview_type
extern exc_TypeError_type
extern exc_ValueError_type

section .rodata
int_base_empty: db 0
int_trunc_deprecated: db "The delegation of int() to __trunc__ is deprecated.", 0
; The \x01 is where type_name_message puts the type's name.
int_dunder_int_msg:   db `__int__ returned non-int (type \x01).  The ability to return an instance of a strict subclass of int is deprecated, and may be removed in a future version of Python.`, 0
int_dunder_index_msg: db `__index__ returned non-int (type \x01).  The ability to return an instance of a strict subclass of int is deprecated, and may be removed in a future version of Python.`, 0
int_dunder_trunc_msg: db `__trunc__ returned non-int (type \x01).  The ability to return an instance of a strict subclass of int is deprecated, and may be removed in a future version of Python.`, 0

section .text

;; ============================================================================
;; int_dunder_invoke(rax = what dunder_bind answered, edx = its verdict,
;;                   rbx = self)
;;   -> rax:edx = the Value the dunder answered with, or edx = 3 when what it
;;      was bound to is not callable at all
;;
;; The three call sites below -- __int__, __trunc__, and __int__ on an int
;; subclass -- were three copies of the same twenty lines, and a copy is how
;; one of them drifts.  dunder_bind's verdict says whether self is an
;; argument: 0 means it is and what came back is borrowed, 1 means __get__
;; already supplied it and the reference is OURS to release.
;; ============================================================================
IDI_VERDICT equ 8
IDI_FRAME   equ 16          ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL int_dunder_invoke, IDI_FRAME
    mov [rbp - IDI_VERDICT], rdx
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .idi_uncallable
    cmp qword [rbp - IDI_VERDICT], 0
    jne .idi_bound
    SPUSH_PTR rbx                           ; args[0] = self (fat arg)
    mov rdi, rax
    mov rsi, rsp
    mov edx, 1
    call rcx
    V_UNPACK rax, rdx                       ; tp_call returns a Value
    add rsp, 16
    leave
    ret
.idi_bound:
    push rax
    push rax                                ; a pair, so rsp stays aligned
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call rcx
    mov rdi, rax
    mov rsi, rdx
    pop rax
    pop rcx
    push rdi
    push rsi
    mov rdi, rax
    call obj_decref                         ; what __get__ answered was ours
    pop rdx
    pop rax
    V_UNPACK rax, rdx
    leave
    ret
.idi_uncallable:
    ; Release what __get__ answered, when that is what this is, and say so.
    cmp qword [rbp - IDI_VERDICT], 0
    je .idi_say
    mov rdi, rax
    call obj_decref
.idi_say:
    mov edx, 3
    leave
    ret
END_FUNC int_dunder_invoke

;; ============================================================================
;; builtin_int_fn(rdi = the argument array, rsi = how many) -> rax:edx = the
;;   Value, or 0 with the exception recorded
;;
;; int(), int(x) and int(x, base).  Four converters wearing one name: a str,
;; bytes or bytearray argument is parsed in the base given; a float is
;; truncated toward zero; an int subclass has its value extracted unless it
;; overrides __int__; and anything else goes through __int__, then __index__,
;; then __trunc__, in that order.
;; ============================================================================
; Frame layout:
BI_ARGS   equ 8
BI_NARGS  equ 16
BI_OBJ    equ 24       ; original string/bytes obj for error messages
BI_BASE   equ 32       ; base value for error messages
BI_ORIGIN equ 40       ; the argument's type, for the bytes-family MRO walk
BI_XLAT   equ 64       ; a Unicode-to-ASCII copy of the argument, or 0
BI_DATA   equ 72       ; the bytes actually parsed: that copy, or the original
BI_XLEN   equ 80       ; and its length, which strlen cannot recover
BI_DUNDER equ 56       ; which of __int__/__index__/__trunc__ was called, so
                       ; the deprecation for a strict-int-subclass result can
                       ; name it the way CPython does
BI_LEN    equ 48       ; the source length: bytes and bytearray keep it in
                       ; different fields, so the shared tail cannot re-read it
BI_ARRLEN equ 88       ; the byte length of a buffer source: an array
                       ; counts ITEMS in ob_size, so it is not ob_size
BI_BOUND  equ 96       ; dunder_bind's verdict: whether self is an argument
BI_FRAME  equ 104           ; + 1 push = 112, 16-byte aligned

global builtin_int_fn
DEF_FUNC builtin_int_fn, BI_FRAME
    push rbx
    mov qword [rbp - BI_ORIGIN], 0

    test rsi, rsi
    jz .int_no_args

    cmp rsi, 1
    je .int_one_arg

    cmp rsi, 2
    je .int_two_args

    jmp .int_error

.int_one_arg:
    mov rbx, [rdi]

    V_TEST_INT_M [rdi], r11      ; args[0] an int immediate?
    jae .int_return_smallint

    V_TEST_F64_M [rdi], r11      ; args[0] a float?
    jbe .int_from_inline_float

    ; Must be TAG_PTR to dereference
    V_TEST_PTR_M [rdi], r11      ; args[0] a pointer?
    ja .int_type_error

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
    ; A float subclass keeps its double inline; .int_from_float reads it
    ; through float_int, which unwraps one.
    test rdx, TYPE_FLAG_FLOAT_SUBCLASS
    jnz .int_from_float

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
    cmp qword [rbp - BI_ORIGIN], 0
    jne .int_chain_have_origin
    mov [rbp - BI_ORIGIN], rcx
.int_chain_have_origin:
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    je .int_from_bytes
    lea rdx, [rel bytearray_type]
    cmp rcx, rdx
    je .int_from_bytearray
    lea rdx, [rel memoryview_type]
    cmp rcx, rdx
    je .int_from_memoryview
    ; array.array is a buffer too, and CPython's int() takes any buffer:
    ; int(array('B', b'100')) is 100.  CPython's own test_int asserts it, and
    ; guards the whole case on `from array import array` succeeding -- so the
    ; assertion only became reachable when the module arrived.
    extern array_type
    lea rdx, [rel array_type]
    cmp rcx, rdx
    je .int_from_array
    MRO_NEXT rcx, [rbp - BI_ORIGIN]
    test rcx, rcx
    jnz .int_check_bytes_chain

    jmp .int_try_dunder

.int_no_args:
    xor eax, eax
    RET_TAG_SMALLINT
    jmp .int_ret

.int_return_smallint:
    mov rax, rbx
    V_TO_I64 rax
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
    ; A float immediate — delegate to float_int for the NaN/inf checks
    mov rdi, rbx
    call float_int
    V_UNPACK rax, rdx           ; .int_ret hands back the pair, not the Value
    jmp .int_ret

.int_from_float:
    ; A float subclass instance.  float_int unboxes one itself now, so the
    ; Value goes straight in; this arm used to read the double out by hand.
    mov rdi, rbx
    call float_int
    V_UNPACK rax, rdx
    jmp .int_ret

.int_from_str:
    mov [rbp - BI_OBJ], rbx           ; save original obj for error msg
    mov qword [rbp - BI_BASE], 10     ; base 10
    ; A Unicode decimal digit is a digit, and a Unicode space is a space:
    ; int("\uff11\uff12\uff13") is 123 in CPython, which runs
    ; _PyUnicode_TransformDecimalAndSpaceToASCII over the argument first.
    mov qword [rbp - BI_XLAT], 0
    mov rdi, rbx
    extern str_decimal_ascii
    call str_decimal_ascii
    test rax, rax
    jz .int_str_ascii
    mov [rbp - BI_XLAT], rax
    mov [rbp - BI_XLEN], rdx
    mov rdi, rax
    jmp .int_str_have_data
.int_str_ascii:
    mov rax, [rbx + PyStrObject.ob_size]
    mov [rbp - BI_XLEN], rax
    lea rdi, [rbx + PyStrObject.data]
.int_str_have_data:
    mov [rbp - BI_DATA], rdi
    ; Check for embedded NUL bytes -- against the length of what is actually
    ; being parsed, which is the translated copy's when there is one.
    call strlen wrt ..plt
    cmp rax, [rbp - BI_XLEN]
    jne .int_str_parse_error_x
    mov rdi, [rbp - BI_DATA]
    mov esi, 10
    call int_from_cstr_base
    test edx, edx
    jz .int_str_parse_error_x
    push rax
    push rdx
    mov rdi, [rbp - BI_XLAT]
    test rdi, rdi
    jz .int_str_kept
    extern ap_free
    call ap_free
.int_str_kept:
    pop rdx
    pop rax
    jmp .int_ret

.int_str_parse_error_x:
    mov rdi, [rbp - BI_XLAT]
    test rdi, rdi
    jz .int_str_parse_error
    call ap_free
    jmp .int_str_parse_error

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
    mov esi, 10
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

.int_from_array:
    ; The same shape as a bytearray, except that ob_size counts ITEMS: the
    ; byte length is items times the item size, and the buffer pointer sits
    ; at the same offset.  int() reads the raw bytes, whatever the typecode
    ; says they mean.
    mov [rbp - BI_OBJ], rbx
    mov qword [rbp - BI_BASE], 10
    mov rcx, [rbx + PyArrayObject.ob_size]
    imul rcx, [rbx + PyArrayObject.ob_isize]
    mov [rbp - BI_ARRLEN], rcx
    mov rsi, [rbx + PyArrayObject.ob_data]
    jmp .int_bytes_common

.int_from_bytearray:
    ; Same as int_from_bytes but using PyByteArrayObject layout (identical to PyBytesObject)
    mov [rbp - BI_OBJ], rbx
    mov qword [rbp - BI_BASE], 10
    mov rcx, [rbx + PyByteArrayObject.ob_size]
    mov [rbp - BI_ARRLEN], rcx
    mov rsi, [rbx + PyByteArrayObject.ob_bytes]
.int_bytes_common:
    lea rdi, [rcx + 8]
    push rsi
    push rcx
    call ap_malloc
    pop rcx
    pop rsi
    push rax
    mov rdi, rax
    mov rdx, rcx
    test rdx, rdx
    jz .int_bytes_copied
    call ap_memcpy
.int_bytes_copied:
    pop rdi
    push rdi
    mov rcx, [rbp - BI_ARRLEN]
    mov qword [rdi + rcx], 0
    ; Check for embedded NUL
    call strlen wrt ..plt
    cmp rax, [rbp - BI_ARRLEN]
    jne .int_bytes_nul_error
    mov rdi, [rsp]
    mov esi, 10
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
    ; int(memoryview) — copy the viewed bytes and parse.  A strided view has
    ; no contiguous run, and a number is not what one is for; CPython's own
    ; int() over a non-contiguous view raises through the buffer protocol.
    cmp qword [rbx + PyMemoryViewObject.mv_stride], 1
    jne .int_type_error
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
    mov esi, 10
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
    mov eax, 1
    RET_TAG_SMALLINT
    jmp .int_ret

.int_from_int_subclass:
    ; rbx = int subclass instance (PyIntSubclassObject)
    ; Check if it has __int__ method
    mov rdi, [rbx + PyObject.ob_type]
    CSTRING rsi, "__int__"
    call dunder_lookup
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    jz .int_from_int_sub_extract ; no __int__, extract int_value
    lea rcx, [rel int_dunder_int_msg]
    mov [rbp - BI_DUNDER], rcx  ; which dunder the deprecation names
    ; Call __int__(self), BOUND first -- see .int_call_dunder below.
    mov rdi, rax
    mov rsi, rbx
    call dunder_bind
    cmp edx, 2
    je .int_bind_raised
    call int_dunder_invoke
    cmp edx, 3
    je .int_from_int
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
    je .int_subclass_result      ; bool is a strict subclass of int
    mov r8, [rcx + PyTypeObject.tp_flags]
    test r8, TYPE_FLAG_INT_SUBCLASS
    jnz .int_subclass_result     ; deprecated, and converted to an exact int
    ; __int__ returned non-int
    mov rdi, rax
    call obj_decref
    RAISE exc_TypeError_type, "__int__ returned non-int (type float)"

.int_from_int_sub_extract:
    ; rbx = PyIntSubclassObject with no __int__ method
    ; Extract the int_value and return it
    mov rax, [rbx + PyIntSubclassObject.int_value]
    V_UNPACK rax, rdx
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
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jz .int_try_index
    lea rcx, [rel int_dunder_int_msg]
    mov [rbp - BI_DUNDER], rcx
    jmp .int_call_dunder

.int_try_index:
    ; Try __index__ protocol
    mov rdi, [rbx + PyObject.ob_type]
    CSTRING rsi, "__index__"
    call dunder_lookup
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jz .int_try_trunc
    lea rcx, [rel int_dunder_index_msg]
    mov [rbp - BI_DUNDER], rcx
    jmp .int_call_dunder

.int_try_trunc:
    ; Try __trunc__ protocol
    mov rdi, [rbx + PyObject.ob_type]
    CSTRING rsi, "__trunc__"
    call dunder_lookup
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jnz .int_call_dunder_trunc

    jmp .int_type_error

.int_bind_raised:
    ; __get__ raised; the exception is already recorded.
    jmp eval_exception_unwind

.int_trunc_warn_raised:
    ; warn() raised, which is what a filter set to "error" does.  The
    ; exception is already recorded; unwind with it.
    extern eval_exception_unwind
    jmp eval_exception_unwind

.int_call_dunder:
    ; rax = what the MRO answered with, rbx = self.
    ;
    ; It has to be BOUND before it is called.  This was the one dunder call
    ; site in the tree that never went through dunder_bind: it took whatever
    ; dunder_lookup found and jumped straight to its tp_call with self
    ; prepended, so a __int__ that is a DESCRIPTOR had the descriptor called
    ; rather than what its __get__ answers.  unittest.mock installs exactly
    ; that -- a MagicProxy per magic method -- so int(MagicMock()) raised
    ; while float(), len(), hash() and every other conversion on the same
    ; object worked.
    mov rdi, rax
    mov rsi, rbx
    call dunder_bind
    cmp edx, 2
    je .int_bind_raised
    call int_dunder_invoke
    cmp edx, 3
    je .int_type_error
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
    je .int_subclass_result      ; bool is a strict subclass of int
    mov r8, [rcx + PyTypeObject.tp_flags]
    test r8, TYPE_FLAG_INT_SUBCLASS
    jnz .int_subclass_result
    ; Not int-like, and CPython names what it got.
    mov rsi, rax
    V_PACK rsi, rdx
    CSTRING rdi, `__int__ returned non-int (type \x01)`
    call raise_type_error_with_name

.int_subclass_result:
    ; CPython accepts a strict subclass of int here and DEPRECATES it, naming
    ; the dunder and the type: "__index__ returned non-int (type bool).  The
    ; ability to return an instance of a strict subclass of int is
    ; deprecated...".  Nothing warned, so a test that turns the deprecation
    ; into an error saw nothing to turn.
    mov [rbp - BI_ARGS], rax        ; the result, across the warning
    mov [rbp - BI_BASE], rdx
    mov rdi, [rbp - BI_DUNDER]
    mov rsi, rcx                    ; the result's type
    extern type_name_message
    call type_name_message
    mov rdi, rax
    call deprecation_warn
    test eax, eax
    jz .int_trunc_warn_raised
    mov rax, [rbp - BI_ARGS]
    mov rdx, [rbp - BI_BASE]
    lea rcx, [rel bool_type]
    cmp [rax + PyObject.ob_type], rcx
    je .int_convert_bool_result

    ; ...and the value comes back as an EXACT int.  CPython converts it;
    ; handing the subclass instance straight back made int(x) answer
    ; something whose type is not int.
    mov rdi, rax
    mov rax, [rdi + PyIntSubclassObject.int_value]
    V_UNPACK rax, rdx
    cmp edx, TAG_SMALLINT
    je .int_sub_have
    INCREF rax
.int_sub_have:
    mov [rbp - BI_XLAT], rax        ; the extracted value, across the release
    mov [rbp - BI_XLEN], rdx
    mov rdi, [rbp - BI_ARGS]        ; the subclass instance
    call obj_decref
    mov rax, [rbp - BI_XLAT]
    mov rdx, [rbp - BI_XLEN]
    jmp .int_ret

.int_call_dunder_trunc:
    ; rax = __trunc__ func, rbx = self
    ; CPython 3.12 warns before it does this, and a suite that turns warnings
    ; into errors reads that as the deprecation firing.  The warning has to
    ; come first: the filter may make it raise, and then __trunc__ must not
    ; have run.
    push rax
    lea rdi, [rel int_trunc_deprecated]
    call deprecation_warn
    test eax, eax
    pop rax
    jz .int_trunc_warn_raised

    ; Call __trunc__(self); result must be int-like or have __index__
    ; CPython 3.12: tries __index__ on result, but NOT __int__
    mov rdi, rax
    mov rsi, rbx
    call dunder_bind
    cmp edx, 2
    je .int_bind_raised
    call int_dunder_invoke
    cmp edx, 3
    je .int_type_error
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
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
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
    V_UNPACK rax, rdx           ; tp_call returns a Value
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
    RAISE exc_TypeError_type, "__index__ returned non-int"

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
    mov [gs:ThreadState.current_exception], rax
    jmp eval_exception_unwind

.int_trunc_nonint_error:
    ; __trunc__ returned non-pointer non-int (TAG_FLOAT, TAG_NONE, etc)
    RAISE exc_TypeError_type, "__trunc__ returned non-Integral"

.int_dunder_returned_float:
    ; __int__/__trunc__ returned TAG_FLOAT — TypeError (non-int return)
    RAISE exc_TypeError_type, "__int__ returned non-int (type float)"

.int_convert_bool_result:
    ; rax = bool_true or bool_false, convert to SmallInt
    lea rcx, [rel bool_true]
    cmp rax, rcx
    je .int_bool_result_true
    xor eax, eax
    RET_TAG_SMALLINT
    jmp .int_ret
.int_bool_result_true:
    mov eax, 1
    RET_TAG_SMALLINT
    jmp .int_ret

.int_dunder_error:
    ; Dunder method raised an exception — propagate it (return NULL)
    xor eax, eax
    jmp .int_ret

.int_type_error:
    ; CPython's wording names the type, and this one ended on "not " with
    ; nothing after it -- the one word a reader needs.
    mov rsi, rbx                ; the argument, as a Value
    CSTRING rdi, `int() argument must be a string, a bytes-like object or a real number, not '\x01'`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.int_error:
    RAISE exc_TypeError_type, "int() takes at most 2 arguments"

; ------- int(x, base) -------
.int_two_args:
    mov [rbp - BI_ARGS], rdi       ; save args pointer
    ; Get base from args[1]
    mov rax, [rdi + 8]            ; args[1]
    V_UNPACK rax, rdx
    cmp edx, TAG_SMALLINT
    je .int_base_smallint
    ; Reject the non-pointer immediates (float, and NULL)
    cmp edx, TAG_PTR
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
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
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
    V_UNPACK rax, rdx           ; tp_call returns a Value
    add rsp, 16                  ; pop fat arg
    ; rax = __index__ result, should be int
    test edx, edx
    jz .int_dunder_error         ; __index__ raised exception
    cmp edx, TAG_SMALLINT
    je .int_base_si_from_index
    ; heap int — check if it fits in i64 first
    push rax
    sub rsp, 8                   ; the lone push flips the parity, and the
                                 ; next call is into GMP.  tests/
                                 ; gmp_align_probe.sh found this one; only an
                                 ; INT_STRESS=1 build reaches it, because an
                                 ; ordinary base is a small int.
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_fits_slong_p wrt ..plt
    add rsp, 8                   ; before the test: `add` writes ZF, and the
                                 ; branch below reads the one `test` sets
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
    sub rsp, 8                   ; the lone push flips the parity, and the
                                 ; next call is into GMP.  tests/
                                 ; gmp_align_probe.sh found this one; only an
                                 ; INT_STRESS=1 build reaches it, because an
                                 ; ordinary base is a small int.
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_fits_slong_p wrt ..plt
    add rsp, 8                   ; before the test: `add` writes ZF, and the
                                 ; branch below reads the one `test` sets
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
    V_TEST_PTR_M [rdi], r11      ; args[0] a pointer?
    ja .int_base_type_error_str
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
    cmp qword [rbp - BI_ORIGIN], 0
    jne .int_base_chain_have_origin
    mov [rbp - BI_ORIGIN], rcx
.int_base_chain_have_origin:
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    je .int_base_from_bytes
    lea rdx, [rel bytearray_type]
    cmp rcx, rdx
    je .int_base_from_bytearray
    MRO_NEXT rcx, [rbp - BI_ORIGIN]
    test rcx, rcx
    jnz .int_base_check_bytes_chain
    jmp .int_base_type_error_str

.int_base_from_str:
    ; A Unicode decimal digit is a digit and a Unicode space is a space, as
    ; CPython's _PyUnicode_TransformDecimalAndSpaceToASCII has it.  The
    ; ONE-argument path did this and this one did not, so int("\uff11\uff12")
    ; was 12 and int("\uff11\uff12", 10) was a ValueError -- and the base-0
    ; leading-zero rule could not see a Unicode zero either.
    mov qword [rbp - BI_XLAT], 0
    mov rdi, rbx
    extern str_decimal_ascii
    call str_decimal_ascii
    test rax, rax
    jz .int_base_str_ascii
    mov [rbp - BI_XLAT], rax
    mov [rbp - BI_XLEN], rdx
    mov rdi, rax
    jmp .int_base_str_have_data
.int_base_str_ascii:
    mov rax, [rbx + PyStrObject.ob_size]
    mov [rbp - BI_XLEN], rax
    lea rdi, [rbx + PyStrObject.data]
.int_base_str_have_data:
    mov [rbp - BI_DATA], rdi
    ; Check for embedded NUL bytes, against the length of what is actually
    ; being parsed -- the translated copy's, when there is one.
    call strlen wrt ..plt
    cmp rax, [rbp - BI_XLEN]
    jne .int_base_str_parse_error_x
    mov rdi, [rbp - BI_DATA]
    mov rsi, [rbp - BI_NARGS]      ; base
    call int_from_cstr_base
    test edx, edx            ; check tag (not payload — SmallInt 0 is valid)
    jz .int_base_str_parse_error_x
    push rax
    push rdx
    mov rdi, [rbp - BI_XLAT]
    test rdi, rdi
    jz .int_base_str_kept
    call ap_free
.int_base_str_kept:
    pop rdx
    pop rax
    jmp .int_ret

.int_base_str_parse_error_x:
    mov rdi, [rbp - BI_XLAT]
    test rdi, rdi
    jz .int_base_parse_error
    call ap_free
    jmp .int_base_parse_error

.int_base_from_bytearray:
    ; A bytearray keeps its data OUT OF LINE, so it cannot be read through
    ; the bytes offsets -- which is what this did while the two layouts
    ; happened to match.  rsi and rcx are set here, then the shared body
    ; below copies from them.
    mov rcx, [rbx + PyByteArrayObject.ob_size]
    mov rsi, [rbx + PyByteArrayObject.ob_bytes]
    test rsi, rsi
    jnz .int_base_bytes_have
    lea rsi, [rel int_base_empty]
    jmp .int_base_bytes_have

.int_base_from_bytes:
    ; Parse bytes with given base — make null-terminated copy
    mov rcx, [rbx + PyBytesObject.ob_size]
    lea rsi, [rbx + PyBytesObject.data]

.int_base_bytes_have:
    mov [rbp - BI_LEN], rcx
    push rsi
    lea rdi, [rcx + 8]
    push rcx
    call ap_malloc
    pop rcx
    pop rsi
    push rax
    mov rdi, rax
    mov rdx, rcx
    call ap_memcpy
    pop rdi
    push rdi
    mov rcx, [rbp - BI_LEN]
    mov qword [rdi + rcx], 0
    ; Check for embedded NUL
    call strlen wrt ..plt
    cmp rax, [rbp - BI_LEN]
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
    mov rsi, [rbp - BI_ARGS]
    mov rsi, [rsi + 8]
    CSTRING rdi, `'\x01' object cannot be interpreted as an integer`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.int_base_type_error_str:
    RAISE exc_TypeError_type, "int() can't convert non-string with explicit base"

.int_base_range_error:
    RAISE exc_ValueError_type, "int() base must be >= 2 and <= 36, or 0"

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

    ; Get repr of original object (always a heap ptr).  CPython renders a
    ; bytearray argument as the BYTES it holds -- int(bytearray(b"x"))
    ; reports b'x' -- so a temporary stands in for it.
    mov rdi, [rbp - BI_OBJ]
    mov rax, [rdi + PyObject.ob_type]
    extern bytearray_type
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    jne .ile_repr_src
    mov rsi, [rdi + PyByteArrayObject.ob_size]
    mov rdi, [rdi + PyByteArrayObject.ob_bytes]
    extern bytes_from_data
    call bytes_from_data
    test rax, rax
    jz .ile_no_repr
    mov [rsp + 56], rax
    mov rdi, rax
    call obj_repr
    push rax
    mov rdi, [rsp + 64]         ; the temporary bytes, under the pushed repr
    call obj_decref
    pop rax
    test rax, rax
    jnz .ile_have_repr
    jmp .ile_no_repr
.ile_repr_src:
    mov rdi, [rbp - BI_OBJ]
    call obj_repr
    test rax, rax
    jnz .ile_have_repr
.ile_no_repr:
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
    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jz .int_ile_no_prev
    mov rdi, rax
    call obj_decref
.int_ile_no_prev:
    mov [gs:ThreadState.current_exception], rbx
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
