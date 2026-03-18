; none_obj.asm - None singleton and NoneType

%include "macros.inc"
%include "object.inc"
%include "types.inc"

extern str_from_cstr
extern type_type

; none_repr(PyObject *self) -> PyObject*
; Returns a new string "None"
DEF_FUNC_BARE none_repr
    lea rdi, [rel none_str]
    jmp str_from_cstr
END_FUNC none_repr

; none_hash(PyObject *self) -> int64
; Returns a fixed hash value for None
DEF_FUNC_BARE none_hash
    mov rax, 0x48FA9B36     ; arbitrary fixed hash
    ret
END_FUNC none_hash

; none_bool(PyObject *self) -> int
; None is always falsy
DEF_FUNC_BARE none_bool
    xor eax, eax
    ret
END_FUNC none_bool

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
    dq 0                    ; tp_new
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

; None singleton - immortal object, never freed
align 8
global none_singleton
none_singleton:
    dq 0x7FFFFFFFFFFFFFFF   ; ob_refcnt (max value, never reaches zero)
    dq none_type            ; ob_type

; ============================================================================
; NotImplementedType and NotImplemented singleton
; ============================================================================

section .text
; notimpl_repr(PyObject *self) -> PyObject*
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
    dq 0                    ; tp_new
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

; NotImplemented singleton - immortal object, never freed
align 8
global notimpl_singleton
notimpl_singleton:
    dq 0x7FFFFFFFFFFFFFFF   ; ob_refcnt (max value, never reaches zero)
    dq notimpl_type         ; ob_type

; ============================================================================
; EllipsisType and Ellipsis singleton
; ============================================================================

section .text
; ellipsis_repr(PyObject *self) -> PyObject*
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
    dq 0                    ; tp_new
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

; Ellipsis singleton - immortal object, never freed
align 8
global ellipsis_singleton
ellipsis_singleton:
    dq 0x7FFFFFFFFFFFFFFF   ; ob_refcnt (max value, never reaches zero)
    dq ellipsis_type        ; ob_type
