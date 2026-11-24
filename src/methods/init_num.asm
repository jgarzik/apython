; init_num.asm - the numeric types' method dicts.
;
; int, complex and float, registered into their tp_dicts exactly as
; src/methods/init.asm registers everything else -- this is the same code,
; moved.  src/methods/init.asm reached the 100k cap lint.py enforces for a
; hand-written file, and the seam src/methods/num.asm already draws is the
; obvious one: the numeric method BODIES live in that file, so their
; registration belongs beside it.
;
; The macros are src/include/methodinit.inc now, for the same reason.

%include "macros.inc"
%include "object.inc"
%include "methodinit.inc"

extern dict_set_str
extern add_method_to_dict_checked
extern add_new_staticmethod
extern builtin_func_new
extern builtin_func_new_checked
extern builtin_method_format
extern classmethod_type
extern complex_dunder_new
extern complex_dunder_repr
extern complex_method_complex
extern complex_method_conjugate
extern complex_method_getnewargs
extern complex_type
extern dict_add_builtin_func
extern dict_add_getset
extern dict_new
extern dict_set
extern float_classmethod_fromhex
extern float_classmethod_getformat
extern float_dunder_new
extern float_dunder_repr
extern float_method_as_integer_ratio
extern float_method_conjugate
extern float_method_hex
extern float_method_is_integer
extern float_type
extern gc_alloc
extern gc_track
extern gs_denominator
extern gs_imag
extern gs_numerator
extern gs_real
extern int_classmethod_from_bytes
extern int_dunder_new
extern int_dunder_repr
extern int_method_bit_count
extern int_method_bit_length
extern int_method_conjugate
extern int_method_to_bytes
extern int_type
extern obj_decref
extern str_intern_cstr
extern type_stamp_methods
extern mn___abs__
extern mn___add__
extern mn___and__
extern mn___bool__
extern mn___ceil__
extern mn___complex__
extern mn___divmod__
extern mn___eq__
extern mn___float__
extern mn___floor__
extern mn___floordiv__
extern mn___format__
extern mn___ge__
extern mn___getformat__
extern mn___getnewargs__
extern mn___gt__
extern mn___hash__
extern mn___index__
extern mn___int__
extern mn___invert__
extern mn___le__
extern mn___lshift__
extern mn___lt__
extern mn___mod__
extern mn___mul__
extern mn___ne__
extern mn___neg__
extern mn___or__
extern mn___pos__
extern mn___pow__
extern mn___radd__
extern mn___rand__
extern mn___rdivmod__
extern mn___repr__
extern mn___rfloordiv__
extern mn___rlshift__
extern mn___rmod__
extern mn___rmul__
extern mn___ror__
extern mn___round__
extern mn___rpow__
extern mn___rrshift__
extern mn___rshift__
extern mn___rsub__
extern mn___rtruediv__
extern mn___rxor__
extern mn___sub__
extern mn___truediv__
extern mn___trunc__
extern mn___xor__
extern mn_as_integer_ratio
extern mn_bit_count
extern mn_bit_length
extern mn_conjugate
extern mn_from_bytes
extern mn_fromhex
extern mn_hex
extern mn_is_integer
extern mn_to_bytes

extern gs_real
extern gs_imag
extern gs_numerator
extern gs_denominator

section .text

;; ============================================================================
;; init_num_types() -> void
;;
;; Build and install tp_dict for int, complex and float.  Called from
;; methods_init, in the place the blocks used to sit, so the order every other
;; type is registered in is unchanged.
;; ============================================================================
global init_num_types
DEF_FUNC init_num_types, 8       ; + 1 push = 16, 16-aligned
    push rbx

    ;; --- int_type methods ---
    call dict_new
    mov rbx, rax

    ADD_FN_N mn___repr__, int_dunder_repr, 1, 1

    ; int.__new__ / str.__new__: enum builds each member with
    ; `member_type.__new__(cls, *args)`, and decides which base is the data
    ; type by asking whether __new__ is in its __dict__.
    mov rdi, rbx
    lea rsi, [rel int_dunder_new]
    call add_new_staticmethod

    ADD_FN_N mn_bit_length, int_method_bit_length, 1, 1

    ; The names dir(int) was short of.  __round__ IS builtin_round_fn: a
    ; method's (args, nargs) is the shape round()'s own arguments arrive in.
    extern int_method_is_integer
    ADD_FN_N mn_is_integer, int_method_is_integer, 1, 1

    extern int_method_as_integer_ratio
    ADD_FN_N mn_as_integer_ratio, int_method_as_integer_ratio, 1, 1

    extern int_method_round
    ADD_FN_N mn___round__, int_method_round, 1, 2

    extern int_method_identity
    ADD_FN_N mn___floor__, int_method_identity, 1, 1

    ADD_FN_N mn___ceil__, int_method_identity, 1, 1

    extern int_method_getnewargs
    ADD_FN_N mn___getnewargs__, int_method_getnewargs, 1, 1

    ADD_FN_N mn_bit_count, int_method_bit_count, 1, 1

    ADD_FN_N mn_conjugate, int_method_conjugate, 1, 1

    ADD_FN_N mn_to_bytes, int_method_to_bytes, 1, 3


    ; Add from_bytes as classmethod
    lea rdi, [rel int_classmethod_from_bytes]
    lea rsi, [rel mn_from_bytes]
    call builtin_func_new
    push rax                    ; save builtin_func

    ; Wrap in PyClassMethodObject (GC-tracked)
    mov edi, PyClassMethodObject_size
    lea rsi, [rel classmethod_type]
    call gc_alloc
    pop rcx                     ; builtin_func
    mov [rax + PyClassMethodObject.cm_callable], rcx
    push rax                    ; save classmethod wrapper
    mov rdi, rax
    call gc_track
    pop rax
    push rax                    ; re-save

    ; Create key string
    lea rdi, [rel mn_from_bytes]
    call str_intern_cstr
    push rax                    ; save key

    ; dict_set(dict, key, classmethod_wrapper, TAG_PTR, TAG_PTR)
    mov rdi, rbx
    mov rsi, rax                ; key
    mov rdx, [rsp + 8]         ; classmethod wrapper
    call dict_set_str

    ; DECREF key
    pop rdi
    call obj_decref
    ; DECREF classmethod wrapper (dict_set did INCREF)
    pop rdi
    call obj_decref

    ;; The unary operators, by name.  Without these an MRO lookup for
    ;; __invert__ on `class I(int, M)` could not find int's before M's, since
    ;; int had nothing in its dict to find, and type_install_slots wrote M's
    ;; wrapper over the nb_invert the class had already inherited.
    extern int_dunder_neg
    ADD_FN_N mn___neg__, int_dunder_neg, 1, 1
    extern int_dunder_pos
    ADD_FN_N mn___pos__, int_dunder_pos, 1, 1
    extern int_dunder_abs
    ADD_FN_N mn___abs__, int_dunder_abs, 1, 1
    extern int_dunder_invert
    ADD_FN_N mn___invert__, int_dunder_invert, 1, 1
    extern int_dunder_int
    ADD_FN_N mn___int__, int_dunder_int, 1, 1
    extern int_dunder_float
    ADD_FN_N mn___float__, int_dunder_float, 1, 1
    extern int_dunder_index
    ADD_FN_N mn___index__, int_dunder_index, 1, 1
    extern int_dunder_trunc
    ADD_FN_N mn___trunc__, int_dunder_trunc, 1, 1
    extern int_dunder_bool
    ADD_FN_N mn___bool__, int_dunder_bool, 1, 1

    ;; and the binary family, forward and reflected.
    extern int_dunder_add
    ADD_FN_N mn___add__, int_dunder_add, 2, 2
    extern int_dunder_sub
    ADD_FN_N mn___sub__, int_dunder_sub, 2, 2
    extern int_dunder_mul
    ADD_FN_N mn___mul__, int_dunder_mul, 2, 2
    extern int_dunder_mod
    ADD_FN_N mn___mod__, int_dunder_mod, 2, 2
    extern int_dunder_divmod
    ADD_FN_N mn___divmod__, int_dunder_divmod, 2, 2
    extern int_dunder_pow
    ADD_FN_N mn___pow__, int_dunder_pow, 2, 3
    extern int_dunder_lshift
    ADD_FN_N mn___lshift__, int_dunder_lshift, 2, 2
    extern int_dunder_rshift
    ADD_FN_N mn___rshift__, int_dunder_rshift, 2, 2
    extern int_dunder_and
    ADD_FN_N mn___and__, int_dunder_and, 2, 2
    extern int_dunder_xor
    ADD_FN_N mn___xor__, int_dunder_xor, 2, 2
    extern int_dunder_or
    ADD_FN_N mn___or__, int_dunder_or, 2, 2
    extern int_dunder_floordiv
    ADD_FN_N mn___floordiv__, int_dunder_floordiv, 2, 2
    extern int_dunder_truediv
    ADD_FN_N mn___truediv__, int_dunder_truediv, 2, 2
    extern int_dunder_radd
    ADD_FN_N mn___radd__, int_dunder_radd, 2, 2
    extern int_dunder_rsub
    ADD_FN_N mn___rsub__, int_dunder_rsub, 2, 2
    extern int_dunder_rmul
    ADD_FN_N mn___rmul__, int_dunder_rmul, 2, 2
    extern int_dunder_rmod
    ADD_FN_N mn___rmod__, int_dunder_rmod, 2, 2
    extern int_dunder_rdivmod
    ADD_FN_N mn___rdivmod__, int_dunder_rdivmod, 2, 2
    extern int_dunder_rpow
    ADD_FN_N mn___rpow__, int_dunder_rpow, 2, 3
    extern int_dunder_rlshift
    ADD_FN_N mn___rlshift__, int_dunder_rlshift, 2, 2
    extern int_dunder_rrshift
    ADD_FN_N mn___rrshift__, int_dunder_rrshift, 2, 2
    extern int_dunder_rand
    ADD_FN_N mn___rand__, int_dunder_rand, 2, 2
    extern int_dunder_rxor
    ADD_FN_N mn___rxor__, int_dunder_rxor, 2, 2
    extern int_dunder_ror
    ADD_FN_N mn___ror__, int_dunder_ror, 2, 2
    extern int_dunder_rfloordiv
    ADD_FN_N mn___rfloordiv__, int_dunder_rfloordiv, 2, 2
    extern int_dunder_rtruediv
    ADD_FN_N mn___rtruediv__, int_dunder_rtruediv, 2, 2

    ;; real, imag, numerator and denominator, as getset descriptors.  int's
    ;; tp_getattr answers an instance read before this dict is consulted;
    ;; these are what make `int.real` an attribute of the type, and what put
    ;; the four names in dir().
    mov rdi, rbx
    lea rsi, [rel gs_real]
    extern int_get_real
    lea rdx, [rel int_get_real]
    xor ecx, ecx
    call dict_add_getset
    mov rdi, rbx
    lea rsi, [rel gs_numerator]
    lea rdx, [rel int_get_real]
    xor ecx, ecx
    call dict_add_getset
    mov rdi, rbx
    lea rsi, [rel gs_imag]
    extern int_get_imag
    lea rdx, [rel int_get_imag]
    xor ecx, ecx
    call dict_add_getset
    mov rdi, rbx
    lea rsi, [rel gs_denominator]
    extern int_get_denominator
    lea rdx, [rel int_get_denominator]
    xor ecx, ecx
    call dict_add_getset

    ; Store in int_type.tp_dict
    ADD_FN_N mn___format__, builtin_method_format, 2, 2

    extern int_dunder_hash
    ADD_FN_N mn___hash__, int_dunder_hash, 1, 1

    extern int_dunder_lt
    ADD_FN_N mn___lt__, int_dunder_lt, 2, 2
    extern int_dunder_le
    ADD_FN_N mn___le__, int_dunder_le, 2, 2
    extern int_dunder_gt
    ADD_FN_N mn___gt__, int_dunder_gt, 2, 2
    extern int_dunder_ge
    ADD_FN_N mn___ge__, int_dunder_ge, 2, 2
    extern int_dunder_eq
    ADD_FN_N mn___eq__, int_dunder_eq, 2, 2
    extern int_dunder_ne
    ADD_FN_N mn___ne__, int_dunder_ne, 2, 2

    lea rax, [rel int_type]
    mov [rax + PyTypeObject.tp_dict], rbx
    mov rdi, rax
    call type_stamp_methods

    ;; --- complex_type methods ---
    ;
    ; __repr__ goes through DEF_DUNDER_STRREPR, which calls the DEFINING
    ; type's slot rather than the argument's; the naive form recurses on a
    ; subclass (bugs.md).  There is deliberately no __str__: CPython's complex
    ; has no tp_str of its own, so `complex.__str__ is object.__str__` is True
    ; there, and leaving it out reproduces that while tp_str = complex_repr
    ; still keeps print(2j) fast.
    call dict_new
    mov rbx, rax

    ADD_FN_N mn___repr__, complex_dunder_repr, 1, 1

    mov rdi, rbx
    lea rsi, [rel complex_dunder_new]
    call add_new_staticmethod

    ADD_FN_N mn_conjugate, complex_method_conjugate, 1, 1

    ADD_FN_N mn___complex__, complex_method_complex, 1, 1

    ADD_FN_N mn___getnewargs__, complex_method_getnewargs, 1, 1

    ADD_FN_N mn___format__, builtin_method_format, 2, 2

    mov rdi, rbx
    lea rsi, [rel gs_real]
    extern complex_get_real
    lea rdx, [rel complex_get_real]
    xor ecx, ecx
    call dict_add_getset
    mov rdi, rbx
    lea rsi, [rel gs_imag]
    extern complex_get_imag
    lea rdx, [rel complex_get_imag]
    xor ecx, ecx
    call dict_add_getset

    extern complex_dunder_hash
    ADD_FN_N mn___hash__, complex_dunder_hash, 1, 1

    extern complex_dunder_bool
    ADD_FN_N mn___bool__, complex_dunder_bool, 1, 1

    ;; The binary family, forward and reflected, and the unary three.  They
    ;; went through the slots and nothing else, so `complex(1,2).__add__` did
    ;; not exist -- and a class that dispatches on NotImplemented, as the
    ;; numeric tower does, cannot ask a type that has no __add__ to try.
    extern complex_dunder_add
    ADD_FN_N mn___add__, complex_dunder_add, 2, 2
    extern complex_dunder_sub
    ADD_FN_N mn___sub__, complex_dunder_sub, 2, 2
    extern complex_dunder_mul
    ADD_FN_N mn___mul__, complex_dunder_mul, 2, 2
    extern complex_dunder_truediv
    ADD_FN_N mn___truediv__, complex_dunder_truediv, 2, 2
    extern complex_dunder_pow
    ADD_FN_N mn___pow__, complex_dunder_pow, 2, 3
    extern complex_dunder_radd
    ADD_FN_N mn___radd__, complex_dunder_radd, 2, 2
    extern complex_dunder_rsub
    ADD_FN_N mn___rsub__, complex_dunder_rsub, 2, 2
    extern complex_dunder_rmul
    ADD_FN_N mn___rmul__, complex_dunder_rmul, 2, 2
    extern complex_dunder_rtruediv
    ADD_FN_N mn___rtruediv__, complex_dunder_rtruediv, 2, 2
    extern complex_dunder_rpow
    ADD_FN_N mn___rpow__, complex_dunder_rpow, 2, 3
    extern complex_dunder_neg
    ADD_FN_N mn___neg__, complex_dunder_neg, 1, 1
    extern complex_dunder_pos
    ADD_FN_N mn___pos__, complex_dunder_pos, 1, 1
    extern complex_dunder_abs
    ADD_FN_N mn___abs__, complex_dunder_abs, 1, 1

    lea rax, [rel complex_type]
    mov [rax + PyTypeObject.tp_dict], rbx
    mov rdi, rax
    call type_stamp_methods

    ;; --- float_type methods ---
    call dict_new
    mov rbx, rax

    ADD_FN_N mn___repr__, float_dunder_repr, 1, 1

    ; float.__new__, for the same reason int and str carry one: a subclass
    ; that overrides __new__ reaches the base's through super(), and enum
    ; looks the name up in __dict__ to pick its data type.
    mov rdi, rbx
    lea rsi, [rel float_dunder_new]
    call add_new_staticmethod

    ADD_FN_N mn_is_integer, float_method_is_integer, 1, 1

    ; float's four.  __floor__ and __ceil__ do exactly what MATH_ROUNDER's
    ; native arm does, because adding them newly routes a float SUBCLASS
    ; instance through the dunder: that arm reaches only an immediate.
    ADD_FN_N mn___round__, int_method_round, 1, 2

    extern float_method_floor
    ADD_FN_N mn___floor__, float_method_floor, 1, 1

    extern float_method_ceil
    ADD_FN_N mn___ceil__, float_method_ceil, 1, 1

    extern float_method_getnewargs
    ADD_FN_N mn___getnewargs__, float_method_getnewargs, 1, 1

    ADD_FN_N mn_conjugate, float_method_conjugate, 1, 1

    ADD_FN_N mn_as_integer_ratio, float_method_as_integer_ratio, 1, 1

    ADD_FN_N mn_hex, float_method_hex, 1, 1


    ; Add fromhex as classmethod
    ADD_CLASSMETHOD_N mn_fromhex, float_classmethod_fromhex, 2, 2
    ADD_CLASSMETHOD_N mn___getformat__, float_classmethod_getformat, 2, 2

    ADD_FN_N mn___format__, builtin_method_format, 2, 2

    extern float_dunder_neg
    ADD_FN_N mn___neg__, float_dunder_neg, 1, 1
    extern float_dunder_pos
    ADD_FN_N mn___pos__, float_dunder_pos, 1, 1
    extern float_dunder_abs
    ADD_FN_N mn___abs__, float_dunder_abs, 1, 1
    extern float_dunder_int
    ADD_FN_N mn___int__, float_dunder_int, 1, 1
    extern float_dunder_float
    ADD_FN_N mn___float__, float_dunder_float, 1, 1

    ;; the binary family, forward and reflected.
    extern float_dunder_add
    ADD_FN_N mn___add__, float_dunder_add, 2, 2
    extern float_dunder_sub
    ADD_FN_N mn___sub__, float_dunder_sub, 2, 2
    extern float_dunder_mul
    ADD_FN_N mn___mul__, float_dunder_mul, 2, 2
    extern float_dunder_mod
    ADD_FN_N mn___mod__, float_dunder_mod, 2, 2
    extern float_dunder_divmod
    ADD_FN_N mn___divmod__, float_dunder_divmod, 2, 2
    extern float_dunder_pow
    ADD_FN_N mn___pow__, float_dunder_pow, 2, 3
    extern float_dunder_floordiv
    ADD_FN_N mn___floordiv__, float_dunder_floordiv, 2, 2
    extern float_dunder_truediv
    ADD_FN_N mn___truediv__, float_dunder_truediv, 2, 2
    extern float_dunder_radd
    ADD_FN_N mn___radd__, float_dunder_radd, 2, 2
    extern float_dunder_rsub
    ADD_FN_N mn___rsub__, float_dunder_rsub, 2, 2
    extern float_dunder_rmul
    ADD_FN_N mn___rmul__, float_dunder_rmul, 2, 2
    extern float_dunder_rmod
    ADD_FN_N mn___rmod__, float_dunder_rmod, 2, 2
    extern float_dunder_rdivmod
    ADD_FN_N mn___rdivmod__, float_dunder_rdivmod, 2, 2
    extern float_dunder_rpow
    ADD_FN_N mn___rpow__, float_dunder_rpow, 2, 3
    extern float_dunder_rfloordiv
    ADD_FN_N mn___rfloordiv__, float_dunder_rfloordiv, 2, 2
    extern float_dunder_rtruediv
    ADD_FN_N mn___rtruediv__, float_dunder_rtruediv, 2, 2
    extern float_dunder_trunc
    ADD_FN_N mn___trunc__, float_dunder_trunc, 1, 1
    extern float_dunder_bool
    ADD_FN_N mn___bool__, float_dunder_bool, 1, 1

    ; real and imag; float has no numerator or denominator, as CPython has not
    mov rdi, rbx
    lea rsi, [rel gs_real]
    extern float_get_real
    lea rdx, [rel float_get_real]
    xor ecx, ecx
    call dict_add_getset
    mov rdi, rbx
    lea rsi, [rel gs_imag]
    extern float_get_imag
    lea rdx, [rel float_get_imag]
    xor ecx, ecx
    call dict_add_getset

    ; Store in float_type.tp_dict
    extern float_dunder_hash
    ADD_FN_N mn___hash__, float_dunder_hash, 1, 1

    extern float_dunder_lt
    ADD_FN_N mn___lt__, float_dunder_lt, 2, 2
    extern float_dunder_le
    ADD_FN_N mn___le__, float_dunder_le, 2, 2
    extern float_dunder_gt
    ADD_FN_N mn___gt__, float_dunder_gt, 2, 2
    extern float_dunder_ge
    ADD_FN_N mn___ge__, float_dunder_ge, 2, 2
    extern float_dunder_eq
    ADD_FN_N mn___eq__, float_dunder_eq, 2, 2
    extern float_dunder_ne
    ADD_FN_N mn___ne__, float_dunder_ne, 2, 2

    lea rax, [rel float_type]
    mov [rax + PyTypeObject.tp_dict], rbx
    mov rdi, rax
    call type_stamp_methods

    pop rbx
    leave
    ret
END_FUNC init_num_types
