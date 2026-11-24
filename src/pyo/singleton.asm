; singleton.asm - The five immortal singletons and their types
;
; True, False, None, NotImplemented and Ellipsis.  Each is a pointer-identity
; value with a trivial tp_repr, no allocation and a refcount nothing decrements
; to zero, which is why they share a file rather than a protocol.

%include "value.inc"
%include "macros.inc"
%include "object.inc"

extern str_from_cstr
extern __gmpz_init
extern __gmpz_set_si
extern int_add
extern int_sub
extern int_mul
extern int_mod
extern int_power
extern int_neg
extern int_invert
extern int_lshift
extern int_rshift
extern int_floordiv
extern int_true_divide
extern int_and
extern int_or
extern int_xor
extern int_type
extern int_compare
extern type_type

;; ============================================================================
;; bool_repr(PyObject *self) -> PyObject*
;; Returns "True" or "False" string
;; ============================================================================
DEF_FUNC bool_repr
    ; Check if this is True or False
    lea rax, [rel bool_true]
    cmp rdi, rax
    je .is_true
    lea rdi, [rel bool_false_str]
    call str_from_cstr
    leave
    ret
.is_true:
    lea rdi, [rel bool_true_str]
    call str_from_cstr
    leave
    ret
END_FUNC bool_repr

;; ============================================================================
;; bool_hash(PyObject *self) -> int64
;; True -> 1, False -> 0
;; ============================================================================
DEF_FUNC_BARE bool_hash
    lea rax, [rel bool_true]
    cmp rdi, rax
    je .hash_true
    xor eax, eax           ; False -> hash 0
    ret
.hash_true:
    mov eax, 1              ; True -> hash 1
    ret
END_FUNC bool_hash

;; ============================================================================
;; bool_bool(PyObject *self) -> int
;; True -> 1, False -> 0
;; ============================================================================
DEF_FUNC_BARE bool_bool
    lea rax, [rel bool_true]
    cmp rdi, rax
    je .ret_true
    xor eax, eax
    ret
.ret_true:
    mov eax, 1
    ret
END_FUNC bool_bool

;; ============================================================================
;; bool_from_int(int value) -> PyObject*
;; Returns True if value != 0, else False
;; ============================================================================
DEF_FUNC_BARE bool_from_int
    test edi, edi
    jnz .true
    lea rax, [rel bool_false]
    ret
.true:
    lea rax, [rel bool_true]
    ret
END_FUNC bool_from_int

;; ============================================================================
;; Bool-specific bitwise: return bool when both args bool, else delegate to int
;; Calling convention: rdi=left_payload, edx=left_tag, rsi=right_payload, ecx=right_tag
;; ============================================================================

;; bool_and / bool_or / bool_xor (Value left, Value right) -> Value
;;
;; `True & False` is False, not 0.  The three bitwise operators are the only
;; ones bool narrows: everything else (+, -, *, <<) widens to int, which is why
;; bool's other slots are int's unchanged.
;;
;; int_and and friends unwrap the singletons to SmallInts and hand back a
;; SmallInt, so the narrowing has to happen here, and only when BOTH operands
;; were bools -- `True & 1` is 1, an int.
;;
;; CPython never compiles `True & False` as a runtime operation (its folder
;; settles it), so nothing running from a .pyc had reached this.

; %1 = the int_* implementation to delegate to
%macro BOOL_BITWISE 2
DEF_FUNC %1
    push rbx
    xor ebx, ebx
    lea rax, [rel bool_true]
    lea rcx, [rel bool_false]
    cmp rdi, rax
    je %%left_bool
    cmp rdi, rcx
    jne %%go
%%left_bool:
    cmp rsi, rax
    je %%both
    cmp rsi, rcx
    jne %%go
%%both:
    mov ebx, 1
%%go:
    call %2
    test ebx, ebx
    jz %%done
    V_TO_I64 rax
    mov edi, eax
    call bool_from_int          ; a pointer is its own Value
%%done:
    pop rbx
    leave
    ret
END_FUNC %1
%endmacro

BOOL_BITWISE bool_and, int_and
BOOL_BITWISE bool_or,  int_or
BOOL_BITWISE bool_xor, int_xor

;; ============================================================================
;; Bool unary: +True -> 1 (int), abs(True) -> 1 (int)
;; For TAG_BOOL, payload is already 0 or 1, just change tag to SmallInt
;; Calling convention for unary: rdi=payload, edx=tag (but ignored since we
;; know we're called from bool's number methods, so tag is TAG_BOOL)
;; ============================================================================

;; ============================================================================
;; bool_positive: +False -> 0, +True -> 1
;; True and False are ordinary heap singletons, so rdi is a pointer -- not the
;; 0/1 payload this used to be handed before the value representation changed.
;; Nothing called it until __pos__ started reaching real slots, which is why
;; the stale convention went unnoticed.
;; ============================================================================
DEF_FUNC_BARE bool_positive
    lea rcx, [rel bool_true]
    xor eax, eax
    cmp rdi, rcx
    sete al
    V_PACK_I64 rax, rcx
    ret
END_FUNC bool_positive

;; ============================================================================
;; bool_absolute: abs(False) -> 0, abs(True) -> 1
;; ============================================================================
DEF_FUNC_BARE bool_absolute
    lea rcx, [rel bool_true]
    xor eax, eax
    cmp rdi, rcx
    sete al
    V_PACK_I64 rax, rcx
    ret
END_FUNC bool_absolute

;; ============================================================================
;; bool_getattr(self, name_str) -> (rax=payload, edx=tag)
;; Handles .real and .imag for bool; returns SmallInt
;; rdi = self (either TAG_BOOL payload 0/1, or TAG_PTR bool singleton ptr)
;; rsi = name string
;; ============================================================================
DEF_FUNC bool_getattr
    push rbx
    push r12
    mov rbx, rdi           ; self (payload or ptr)
    mov r12, rsi           ; name string

    ; Compare name against "real"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "real"
    extern ap_strcmp
    call ap_strcmp
    test eax, eax
    jz .real

    ; Compare name against "imag"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "imag"
    call ap_strcmp
    test eax, eax
    jz .imag

    ; numerator and denominator, which int carries too: numbers.py and
    ; fractions.py ask a bool for all four, and bool does not reach
    ; int_getattr -- op_load_attr walks tp_dicts once this returns NULL, and
    ; neither name lives in one.
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "numerator"
    call ap_strcmp
    test eax, eax
    jz .real                    ; True.numerator is 1, as True.real is

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "denominator"
    call ap_strcmp
    test eax, eax
    jz .denominator

    ; None of the four — return NULL (attr not found)
    RET_NULL
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.real:
    ; True.real -> 1, False.real -> 0 (as SmallInt)
    ; rbx is either 0/1 (TAG_BOOL) or ptr to bool_true/bool_false (TAG_PTR)
    ; Detect: if rbx <= 1, it's TAG_BOOL payload; else it's a pointer
    cmp rbx, 1
    jbe .real_tag_bool
    ; TAG_PTR: compare with bool_true singleton
    lea rax, [rel bool_true]
    cmp rbx, rax
    je .real_one
    xor eax, eax              ; False.real = 0
    RET_TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
.real_one:
    mov eax, 1
    RET_TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
.real_tag_bool:
    mov rax, rbx               ; 0 or 1
    RET_TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.imag:
    ; True.imag -> 0, False.imag -> 0 (as SmallInt)
    xor eax, eax
    RET_TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.denominator:
    mov eax, 1
    RET_TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC bool_getattr

section .data

bool_true_str:  db "True", 0
bool_false_str: db "False", 0
bool_name_str:  db "bool", 0

; Bool number methods
align 8
bool_number_methods:
    dq int_add              ; nb_add (inherited from int)
    dq int_sub              ; nb_subtract
    dq int_mul              ; nb_multiply
    dq int_mod              ; nb_remainder
    dq 0                    ; nb_divmod
    dq int_power            ; nb_power
    dq int_neg              ; nb_negative
    dq bool_positive        ; nb_positive
    dq bool_absolute        ; nb_absolute
    dq bool_bool            ; nb_bool
    dq int_invert           ; nb_invert
    dq int_lshift           ; nb_lshift
    dq int_rshift           ; nb_rshift
    dq bool_and             ; nb_and
    dq bool_xor             ; nb_xor
    dq bool_or              ; nb_or
    dq 0                    ; nb_int
    dq 0                    ; nb_float
    dq int_floordiv         ; nb_floor_divide
    dq int_true_divide      ; nb_true_divide
    dq 0                    ; nb_index
    dq 0                        ; nb_iadd         +168
    dq 0                        ; nb_isub         +176
    dq 0                        ; nb_imul         +184
    dq 0                        ; nb_irem         +192
    dq 0                        ; nb_ipow         +200
    dq 0                        ; nb_ilshift      +208
    dq 0                        ; nb_irshift      +216
    dq 0                        ; nb_iand         +224
    dq 0                        ; nb_ixor         +232
    dq 0                        ; nb_ior          +240
    dq 0                        ; nb_ifloor_divide +248
    dq 0                        ; nb_itrue_divide +256
    dq 0 ; nb_matmul
    dq 0 ; nb_imatmul

; Bool type object
align 8
global bool_type
bool_type:
    dq 1                    ; ob_refcnt
    dq type_type            ; ob_type
    dq bool_name_str        ; tp_name
    dq PyIntObject_size     ; tp_basicsize (bool is subtype of int)
    dq 0                    ; tp_dealloc
    dq bool_repr            ; tp_repr
    dq bool_repr            ; tp_str
    dq bool_hash            ; tp_hash
    dq 0                    ; tp_call
    dq bool_getattr         ; tp_getattr
    dq 0                    ; tp_setattr
    dq int_compare          ; tp_richcompare (inherit from int)
    dq 0                    ; tp_iter
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq 0                    ; tp_new
    dq bool_number_methods  ; tp_as_number
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    dq 0                    ; tp_base (set to int_type in bool_init)
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq TYPE_FLAG_FINAL          ; tp_flags -- CPython gives this type no
                                ; Py_TPFLAGS_BASETYPE
    dq 0                    ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; True singleton - has embedded mpz_t value of 1
align 8
global bool_true
bool_true:
    dq 0x7fffffffffffffff   ; ob_refcnt (immortal)
    dq bool_type            ; ob_type
    ; mpz_t inline: _mp_alloc(4 bytes), _mp_size(4 bytes), _mp_d(8 bytes)
    dd 0                    ; _mp_alloc (set by gmpz_init)
    dd 0                    ; _mp_size  (set by gmpz_set_si)
    dq 0                    ; _mp_d     (set by gmpz_init)
    dq 0                    ; ival      (unused: singletons are GMP-backed)
    dq 0                    ; compact   (0 = GMP-backed)

; False singleton - has embedded mpz_t value of 0
align 8
global bool_false
bool_false:
    dq 0x7fffffffffffffff   ; ob_refcnt (immortal)
    dq bool_type            ; ob_type
    dd 0                    ; _mp_alloc
    dd 0                    ; _mp_size
    dq 0                    ; _mp_d
    dq 0                    ; ival      (unused: singletons are GMP-backed)
    dq 0                    ; compact   (0 = GMP-backed)

; bool_init() - Initialize True/False singletons' mpz values and set tp_base
; Must be called once at startup
section .text
DEF_FUNC bool_init

    ; Set bool_type.tp_base = int_type
    lea rax, [rel int_type]
    mov [rel bool_type + PyTypeObject.tp_base], rax

    ; Init True's mpz to 1
    lea rdi, [rel bool_true + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    lea rdi, [rel bool_true + PyIntObject.mpz]
    mov esi, 1
    call __gmpz_set_si wrt ..plt

    ; Init False's mpz to 0
    lea rdi, [rel bool_false + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    lea rdi, [rel bool_false + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_set_si wrt ..plt

    leave
    ret
END_FUNC bool_init

;; ============================================================================
;; (was src/pyo/none.asm)
;; ============================================================================

section .text

extern str_from_cstr
extern type_type

;; ============================================================================
;; none_repr(PyObject *self) -> PyObject*
;; Returns a new string "None"
;; ============================================================================
DEF_FUNC_BARE none_repr
    lea rdi, [rel none_str]
    jmp str_from_cstr
END_FUNC none_repr

;; ============================================================================
;; none_hash(PyObject *self) -> int64
;; Returns a fixed hash value for None
;; ============================================================================
DEF_FUNC_BARE none_hash
    mov eax, 0x48fa9b36             ; arbitrary fixed hash
    ret
END_FUNC none_hash

;; ============================================================================
;; none_bool(PyObject *self) -> int
;; None is always falsy
;; ============================================================================
DEF_FUNC_BARE none_bool
    xor eax, eax
    ret
END_FUNC none_bool


;; ============================================================================
;; singleton_type_call(rdi = the type, rsi = args, rdx = nargs)
;;   -> (rax = the singleton, rdx = TAG_PTR), or (0, 0) with a TypeError
;;      pending for any argument at all
;; Fails: 0
;;
;; `NoneType()`, `EllipsisType()` and `NotImplementedType()` answer their own
;; singleton -- `type(None)() is None` -- and take no arguments at all.
;;
;; With no tp_new all three fell through to the ordinary class-construction
;; path, which ALLOCATED a fresh two-word object of that type.  It was not the
;; singleton, so `type(None)() is None` was False; it had no tp_dealloc, so
;; nothing ever freed it; and its type carries no tp_flags, no tp_dict and no
;; tp_basicsize beyond the header, so the heap fell over at shutdown.
;; ============================================================================
DEF_FUNC singleton_type_call
    ; The message is spelled out per type rather than taken from tp_name,
    ; because CPython's is: ellipsis_new says "EllipsisType" where the type
    ; itself is called "ellipsis".
    lea rax, [rel none_singleton]
    lea r8, [rel stc_none_msg]
    lea rcx, [rel none_type]
    cmp rdi, rcx
    je .stc_have
    lea rax, [rel notimpl_singleton]
    lea r8, [rel stc_notimpl_msg]
    lea rcx, [rel notimpl_type]
    cmp rdi, rcx
    je .stc_have
    lea rax, [rel ellipsis_singleton]
    lea r8, [rel stc_ellipsis_msg]
.stc_have:
    ; A keyword argument arrives in the same array with its name parked in
    ; kw_names_pending, so the count covers both forms.
    test rdx, rdx
    jnz .stc_takes_none
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
.stc_takes_none:
    mov rsi, r8
    extern exc_TypeError_type
    lea rdi, [rel exc_TypeError_type]
    extern set_exception
    call set_exception
    RET_NULL
    leave
    ret
section .rodata
stc_none_msg:     db "NoneType takes no arguments", 0
stc_notimpl_msg:  db "NotImplementedType takes no arguments", 0
stc_ellipsis_msg: db "EllipsisType takes no arguments", 0
section .text
END_FUNC singleton_type_call

section .data

; NoneType name and repr string
none_name_str: db "NoneType", 0
none_str:      db "None", 0

; NoneType number methods (only nb_bool is set)
align 8
none_number_methods:
    dq 0                    ; nb_add
    dq 0                    ; nb_subtract
    dq 0                    ; nb_multiply
    dq 0                    ; nb_remainder
    dq 0                    ; nb_divmod
    dq 0                    ; nb_power
    dq 0                    ; nb_negative
    dq 0                    ; nb_positive
    dq 0                    ; nb_absolute
    dq none_bool            ; nb_bool
    dq 0                    ; nb_invert
    dq 0                    ; nb_lshift
    dq 0                    ; nb_rshift
    dq 0                    ; nb_and
    dq 0                    ; nb_xor
    dq 0                    ; nb_or
    dq 0                    ; nb_int
    dq 0                    ; nb_float
    dq 0                    ; nb_floor_divide
    dq 0                    ; nb_true_divide
    dq 0                    ; nb_index
    dq 0                        ; nb_iadd         +168
    dq 0                        ; nb_isub         +176
    dq 0                        ; nb_imul         +184
    dq 0                        ; nb_irem         +192
    dq 0                        ; nb_ipow         +200
    dq 0                        ; nb_ilshift      +208
    dq 0                        ; nb_irshift      +216
    dq 0                        ; nb_iand         +224
    dq 0                        ; nb_ixor         +232
    dq 0                        ; nb_ior          +240
    dq 0                        ; nb_ifloor_divide +248
    dq 0                        ; nb_itrue_divide +256
    dq 0 ; nb_matmul
    dq 0 ; nb_imatmul

; NoneType type object
align 8
global none_type
none_type:
    dq 1                    ; ob_refcnt (immortal)
    dq type_type            ; ob_type
    dq none_name_str        ; tp_name
    dq PyObject_size        ; tp_basicsize
    dq 0                    ; tp_dealloc (never deallocated)
    dq none_repr            ; tp_repr
    dq none_repr            ; tp_str
    dq none_hash            ; tp_hash
    dq 0                    ; tp_call
    dq 0                    ; tp_getattr
    dq 0                    ; tp_setattr
    dq 0                    ; tp_richcompare
    dq 0                    ; tp_iter
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq singleton_type_call                     ; tp_new
    dq none_number_methods  ; tp_as_number
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq 0                    ; tp_flags
    dq 0                    ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; None singleton - immortal object, never freed
align 8
global none_singleton
none_singleton:
    dq 0x7fffffffffffffff   ; ob_refcnt (max value, never reaches zero)
    dq none_type            ; ob_type

;; ============================================================================
;; NotImplementedType and NotImplemented singleton
;; ============================================================================

section .text
;; ============================================================================
;; notimpl_repr(PyObject *self) -> PyObject*
;; ============================================================================
DEF_FUNC_BARE notimpl_repr
    lea rdi, [rel notimpl_repr_str]
    jmp str_from_cstr
END_FUNC notimpl_repr

section .data
notimpl_name_str: db "NotImplementedType", 0
notimpl_repr_str: db "NotImplemented", 0

; NotImplementedType type object
align 8
global notimpl_type
notimpl_type:
    dq 1                    ; ob_refcnt (immortal)
    dq type_type            ; ob_type
    dq notimpl_name_str     ; tp_name
    dq PyObject_size        ; tp_basicsize
    dq 0                    ; tp_dealloc (never deallocated)
    dq notimpl_repr         ; tp_repr
    dq notimpl_repr         ; tp_str
    dq 0                    ; tp_hash
    dq 0                    ; tp_call
    dq 0                    ; tp_getattr
    dq 0                    ; tp_setattr
    dq 0                    ; tp_richcompare
    dq 0                    ; tp_iter
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq singleton_type_call                     ; tp_new
    dq 0                    ; tp_as_number
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq 0                    ; tp_flags
    dq 0                    ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; NotImplemented singleton - immortal object, never freed
align 8
global notimpl_singleton
notimpl_singleton:
    dq 0x7fffffffffffffff   ; ob_refcnt (max value, never reaches zero)
    dq notimpl_type         ; ob_type

;; ============================================================================
;; EllipsisType and Ellipsis singleton
;; ============================================================================

section .text
;; ============================================================================
;; ellipsis_repr(PyObject *self) -> PyObject*
;; ============================================================================
DEF_FUNC_BARE ellipsis_repr
    lea rdi, [rel ellipsis_repr_str]
    jmp str_from_cstr
END_FUNC ellipsis_repr

section .data
ellipsis_name_str: db "ellipsis", 0
ellipsis_repr_str: db "Ellipsis", 0

; EllipsisType type object
align 8
global ellipsis_type
ellipsis_type:
    dq 1                    ; ob_refcnt (immortal)
    dq type_type            ; ob_type
    dq ellipsis_name_str    ; tp_name
    dq PyObject_size        ; tp_basicsize
    dq 0                    ; tp_dealloc (never deallocated)
    dq ellipsis_repr        ; tp_repr
    dq ellipsis_repr        ; tp_str
    dq 0                    ; tp_hash
    dq 0                    ; tp_call
    dq 0                    ; tp_getattr
    dq 0                    ; tp_setattr
    dq 0                    ; tp_richcompare
    dq 0                    ; tp_iter
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq singleton_type_call                     ; tp_new
    dq 0                    ; tp_as_number
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq 0                    ; tp_flags
    dq 0                    ; tp_bases
    dq 0                    ; tp_traverse
    dq 0                    ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; Ellipsis singleton - immortal object, never freed
align 8
global ellipsis_singleton
ellipsis_singleton:
    dq 0x7fffffffffffffff   ; ob_refcnt (max value, never reaches zero)
    dq ellipsis_type        ; ob_type

;; ============================================================================
;; The __new__ thunks for the three singleton types.
;;
;; `NoneType()`, `NotImplementedType()` and `EllipsisType()` all work, because
;; the constructor is in tp_new -- but `NoneType.__new__` resolved along the
;; MRO to object.__new__ and was refused, which is what `copy.copy` and every
;; pickle of one reach for.  One thunk apiece rather than one shared: the
;; slot called has to be the OWNER's, and there are three owners.
;; ============================================================================
section .text

extern new_from_slot

;; ============================================================================
;; none_dunder_new(args, nargs) -> Value    -- NoneType.__new__
;; ============================================================================
DEF_FUNC none_dunder_new
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rel none_type]
    call new_from_slot          ; err: its 0 is this __new__'s own
    leave
    ret
END_FUNC none_dunder_new

;; ============================================================================
;; notimpl_dunder_new(args, nargs) -> Value  -- NotImplementedType.__new__
;; ============================================================================
DEF_FUNC notimpl_dunder_new
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rel notimpl_type]
    call new_from_slot          ; err: its 0 is this __new__'s own
    leave
    ret
END_FUNC notimpl_dunder_new

;; ============================================================================
;; ellipsis_dunder_new(args, nargs) -> Value  -- EllipsisType.__new__
;; ============================================================================
DEF_FUNC ellipsis_dunder_new
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rel ellipsis_type]
    call new_from_slot          ; err: its 0 is this __new__'s own
    leave
    ret
END_FUNC ellipsis_dunder_new
