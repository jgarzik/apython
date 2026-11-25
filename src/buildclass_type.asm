; buildclass_type.asm - `type`'s own methods
;
; Split off from buildclass.asm before it reached the 100k cap that
; src/compiler/lint.py enforces.  The seam is the one the file already had:
; these five are the entries of `type`'s method table -- __new__, __init__,
; __prepare__, __instancecheck__ and __subclasscheck__ -- each a builtin
; reached through tp_call, and the only thing any of them wants from the
; constructor is type_from_parts itself.  Nothing in buildclass.asm calls
; anything here.

%include "macros.inc"
%include "object.inc"

extern bool_false
extern bool_true
extern dict_new
extern exc_TypeError_type
extern none_singleton
extern obj_declared_class
extern obj_decref
extern obj_incref
extern set_exception
extern str_type
extern tuple_type
extern type_type
extern user_type_metatype
extern exc_metatype
extern type_check_is_class
extern type_from_parts
extern type_is_subtype
extern value_type

section .text

;; ============================================================================
;; type.__new__(mcls, name, bases, ns) -> a new class whose metatype is mcls
;;
;; A metaclass __new__ almost always ends in
;; `super().__new__(mcls, name, bases, ns)`, and without this that resolved to
;; object.__new__ and produced an *instance* of the metaclass rather than a
;; class.  ABCMeta is written exactly that way, so abc.py depends on it.
;; Fails: 0
;; ============================================================================
TMN_ARGS  equ 8
TMN_N     equ 16            ; every argument, the class keywords' values included
TMN_MCLS  equ 24
TMN_I     equ 32
TMN_FRAME equ 32            ; + 2 pushes = 48, 16-aligned
DEF_FUNC type_method_new, TMN_FRAME
    push rbx
    push r12
    mov [rbp - TMN_ARGS], rdi
    mov [rbp - TMN_N], rsi
    mov rbx, rdi                    ; args

    ; type.__new__(mcls, name, bases, ns, **kwds): the keywords are for
    ; __init_subclass__ and are not ours to reject.  Their values arrive
    ; after the positional arguments, so they are not part of the count.
    mov rcx, rsi
    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jz .tmn_counted
    sub rcx, [rax + PyTupleObject.ob_size]
.tmn_counted:
    cmp rcx, 4
    jl .tmn_error

    ; Nothing below was checked, and all four are dereferenced: this is a
    ; method anyone can call by hand.  `type.__new__(type, 1, (), {})` read a
    ; str's characters off an int, a base that was not a class had
    ; tp_basicsize read off it, and `type.__new__(int, ...)` handed back a
    ; class whose type was int.  Each refusal is CPython's, in its order.
    lea rdi, [rel type_type]
    mov rsi, rbx
    mov rdx, [rbp - TMN_N]
    extern new_check_class
    call new_check_class            ; a class, and a subtype of type
    ERR_NULL .tmn_failed
    mov [rbp - TMN_MCLS], rax

    mov rsi, [rbx + 8]              ; the name
    V_TEST_PTR rsi, rax
    ja .tmn_bad_name
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .tmn_name_ok
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .tmn_bad_name
.tmn_name_ok:
    mov rsi, [rbx + 16]             ; the bases
    V_TEST_PTR rsi, rax
    ja .tmn_bad_bases
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    jne .tmn_bad_bases
    mov rsi, [rbx + 24]             ; the namespace
    V_TEST_PTR rsi, rax
    ja .tmn_bad_ns
    mov rax, [rsi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_DICT_SUBCLASS
    jz .tmn_bad_ns

    ; Every base is a class, and its metatype is on one line of descent with
    ; the one asked for; the most derived of them all is the class's.
    ; CPython's _PyType_CalculateMetaclass, less the hand-over to a more
    ; derived winner's own __new__.
    mov rdi, [rbp - TMN_MCLS]
    call tmn_plain_metatype
    mov [rbp - TMN_MCLS], rax
    mov qword [rbp - TMN_I], 0
.tmn_base_loop:
    mov rax, [rbx + 16]
    mov rcx, [rbp - TMN_I]
    cmp rcx, [rax + PyTupleObject.ob_size]
    jae .tmn_checked
    mov rax, [rax + PyTupleObject.ob_item]
    mov rax, [rax + rcx*8]
    V_TEST_PTR rax, rdx
    ja .tmn_conflict
    mov rdi, [rax + PyObject.ob_type]
    test qword [rdi + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .tmn_conflict                ; not a class at all
    call tmn_plain_metatype
    mov r12, rax                    ; the base's metatype
    mov rdi, [rbp - TMN_MCLS]
    mov rsi, r12
    call type_is_subtype
    test eax, eax
    jnz .tmn_base_next
    mov rdi, r12
    mov rsi, [rbp - TMN_MCLS]
    call type_is_subtype
    test eax, eax
    jz .tmn_conflict
    mov [rbp - TMN_MCLS], r12       ; the base's is the more derived
.tmn_base_next:
    inc qword [rbp - TMN_I]
    jmp .tmn_base_loop
.tmn_checked:

    ; The metatype is the one __new__ was handed or a base's more derived
    ; one, not the default, and it has to be on the class before its
    ; descriptors' __set_name__ run -- which is inside type_from_parts.
    lea rdi, [rbx + 8]
    mov rsi, [rbp - TMN_N]
    dec rsi
    mov rdx, [rbp - TMN_MCLS]
    call type_new_impl              ; err: its 0 is this function's answer too
    pop r12
    pop rbx
    leave
    ret

.tmn_bad_name:
    CSTRING rdi, `type.__new__() argument 1 must be str, not \x01`
    jmp .tmn_named
.tmn_bad_bases:
    CSTRING rdi, `type.__new__() argument 2 must be tuple, not \x01`
    jmp .tmn_named
.tmn_bad_ns:
    CSTRING rdi, `type.__new__() argument 3 must be dict, not \x01`
.tmn_named:
    extern set_type_error_with_name
    call set_type_error_with_name   ; rsi is the argument, still
    jmp .tmn_failed
.tmn_conflict:
    SET_EXC exc_TypeError_type, "metaclass conflict: the metaclass of a derived class must be a (non-strict) subclass of the metaclasses of all its bases"
    jmp .tmn_failed
.tmn_error:
    SET_EXC exc_TypeError_type, "type.__new__() takes at least 3 arguments"
.tmn_failed:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_method_new

;; ============================================================================
;; tmn_plain_metatype(rdi = a metatype) -> rax = it, or `type` for the two
;;   metatypes that stand in for `type` here
;;
;; user_type_metatype and exc_metatype exist so an ordinary class and a
;; builtin exception class can carry different slots; no metaclass a program
;; writes derives from either, so for "is one a subclass of the other" they
;; are `type`.  bc_normalize_metatype in buildclass_stmt.asm is the same
;; mapping for the class statement.
;; ============================================================================
DEF_FUNC_LOCAL tmn_plain_metatype
    mov rax, rdi
    lea rcx, [rel user_type_metatype]
    cmp rdi, rcx
    je .tpm_type
    lea rcx, [rel exc_metatype]
    cmp rdi, rcx
    jne .tpm_done
.tpm_type:
    lea rax, [rel type_type]
.tpm_done:
    leave
    ret
END_FUNC tmn_plain_metatype

;; ============================================================================
;; type_new_impl(rdi = Value *args: the name, the bases, the namespace, and
;;               after them the values of the class keywords;
;;               rsi = how many that is; rdx = the metatype, or 0)
;;   -> rax = the new class, one strong reference
;; Fails: 0
;;
;; What type.__new__ and the three-argument type() both come to, once each has
;; checked its arguments in its own words: name a str, bases a tuple of
;; classes, namespace a dict.  All three stay the caller's.
;;
;; The class keywords are the reason this is a function.  `type(n, b, d,
;; tag=1)` and `super().__new__(mcls, n, b, d, **kw)` are calls with keywords,
;; so the names are in kw_names_pending and the values follow the positional
;; arguments -- and neither path did anything with them.  The names stayed
;; pending, so the next call type_from_parts made was the one that consumed
;; them: __init_subclass__(cls) took `cls` for the value of `tag` and failed
;; for want of a positional argument, and where the base had no
;; __init_subclass__ of its own a keyword nothing accepts was silently
;; dropped.  Only the class statement with no metaclass worked, because
;; __build_class__ hands them over itself.  They are handed over here the
;; same way, through class_kwnames_pending and class_kwvalues_pending.
;;
;; __new__ CONSUMES kw_names_pending, as every builtin __new__ does:
;; type_call gives __init__ the names again from its own copy.
;;
;; A metatype of `type` is the default, which here is user_type_metatype.
;; Stamping type_type itself on the class gave it a type whose tp_dealloc is
;; not a class's, and a class built by `type.__new__(type, ...)` was never
;; freed.
;; ============================================================================
TNI_ARGS  equ 8
TNI_N     equ 16
TNI_META  equ 24
TNI_KWN   equ 32            ; the keyword names, borrowed, or 0
TNI_KWV   equ 40            ; their values as a tuple, owned, or 0
TNI_OLDN  equ 48            ; the pending pair as it stood, put back on the way out
TNI_OLDV  equ 56
TNI_FRAME equ 64            ; + 2 pushes = 80, 16-aligned
global type_new_impl
DEF_FUNC type_new_impl, TNI_FRAME
    push rbx
    push r12
    mov [rbp - TNI_ARGS], rdi
    mov [rbp - TNI_N], rsi
    mov [rbp - TNI_META], rdx
    mov qword [rbp - TNI_KWV], 0

    mov rax, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov [rbp - TNI_KWN], rax
    test rax, rax
    jz .tni_kw_ready
    mov rbx, [rax + PyTupleObject.ob_size]
    test rbx, rbx
    jnz .tni_have_kw
    mov qword [rbp - TNI_KWN], 0
    jmp .tni_kw_ready
.tni_have_kw:
    mov rdi, rbx
    extern tuple_new
    call tuple_new
    mov [rbp - TNI_KWV], rax
    mov rdi, [rax + PyTupleObject.ob_item]
    mov rcx, [rbp - TNI_N]
    sub rcx, rbx                    ; where the keyword values start
    mov rsi, [rbp - TNI_ARGS]
    lea rsi, [rsi + rcx*8]
    xor ecx, ecx
.tni_copy:
    cmp rcx, rbx
    jae .tni_kw_ready
    mov rdx, [rsi + rcx*8]
    mov [rdi + rcx*8], rdx
    INCREF_V rdx, rax
    inc rcx
    jmp .tni_copy
.tni_kw_ready:

    ; The pending pair is a registration type_from_parts reads when it calls
    ; __init_subclass__, and a class may be built while another is: scoped,
    ; so that the inner one neither inherits the outer's keywords nor leaves
    ; its own behind.
    mov rax, [gs:ThreadState.class_kwnames_pending]
    mov [rbp - TNI_OLDN], rax
    mov rax, [gs:ThreadState.class_kwvalues_pending]
    mov [rbp - TNI_OLDV], rax
    mov rax, [rbp - TNI_KWN]
    mov [gs:ThreadState.class_kwnames_pending], rax
    mov rax, [rbp - TNI_KWV]
    mov [gs:ThreadState.class_kwvalues_pending], rax

    mov rax, [rbp - TNI_META]
    lea rcx, [rel type_type]
    cmp rax, rcx
    jne .tni_have_meta
    xor eax, eax
.tni_have_meta:
    mov [gs:ThreadState.class_metatype_pending], rax

    ; type_from_parts consumes a reference to the namespace, and borrows the
    ; name and the bases.
    mov rbx, [rbp - TNI_ARGS]
    mov rdi, [rbx + 16]
    call obj_incref
    mov rdi, [rbx]
    mov rsi, [rbx + 8]
    mov rdx, [rbx + 16]
    call type_from_parts            ; err: its 0 is this function's answer too
    mov rbx, rax

    mov qword [gs:ThreadState.class_metatype_pending], 0
    mov rax, [rbp - TNI_OLDN]
    mov [gs:ThreadState.class_kwnames_pending], rax
    mov rax, [rbp - TNI_OLDV]
    mov [gs:ThreadState.class_kwvalues_pending], rax
    mov rdi, [rbp - TNI_KWV]
    test rdi, rdi
    jz .tni_out
    call obj_decref
.tni_out:
    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_new_impl

;; ============================================================================
;; type.__init__(cls, ...) -> None
;;
;; A no-op, as CPython's type_init is -- but a REGISTERED one.  `type` had no
;; __init__ in its dict, so a metaclass ending in `super().__init__(name,
;; bases, ns)` walked past it to object's, which now refuses arguments it
;; has nowhere to put.  CPython takes one or three besides the class.
;; Fails: 0
;; ============================================================================
DEF_FUNC type_method_init
    ; One or three besides the class.  A builtin here is handed its keyword
    ; values as further positional arguments, and a metaclass ending in
    ; `super().__init__(name, bases, ns, **kwds)` is the shape that matters,
    ; so four or more is taken as the three-argument form with keywords.
    cmp rsi, 2
    je .tmi_ok
    cmp rsi, 4
    jae .tmi_ok
    jmp .tmi_error
.tmi_ok:
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
.tmi_error:
    SET_EXC exc_TypeError_type, "type.__init__() takes 1 or 3 arguments"
    leave                       ; set_exception answered 0
    ret
END_FUNC type_method_init

;; ============================================================================
;; type_method_prepare(args, nargs) -> Value: a fresh empty dict
;;
;; `type.__prepare__(name, bases, **kwds)`, a classmethod.  A metaclass that
;; wants an ordered or otherwise special namespace overrides it; type's own
;; answers the plain dict __build_class__ would have made anyway.  Absent, it
;; was `types.prepare_class` and every cooperative `super().__prepare__(...)`
;; that could not find it.
;; ============================================================================
DEF_FUNC type_method_prepare
    extern dict_new
    call dict_new
    test rax, rax
    jz .tmp_fail
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.tmp_fail:
    xor eax, eax
    leave
    ret
END_FUNC type_method_prepare

;; ============================================================================
;; type_method_instancecheck(args, nargs) -> Value: True or False
;; type_method_subclasscheck(args, nargs) -> Value: True or False
;;
;; `type.__instancecheck__(cls, obj)` and `type.__subclasscheck__(cls, sub)`.
;;
;; These are the PLAIN checks, and that is the whole point of them: CPython's
;; go straight to recursive_isinstance rather than back through
;; PyObject_IsInstance.  One that consulted the dunder would recurse forever
;; through a metaclass whose __instancecheck__ ends in
;; `super().__instancecheck__(obj)` -- which is how ABCMeta's is written.
;; Fails: 0
;; ============================================================================
TIC_CLS   equ 8
TIC_OBJ   equ 16
TIC_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC type_method_instancecheck, TIC_FRAME
    push rbx
    cmp rsi, 2
    jne .tic_error
    mov rax, [rdi]
    mov [rbp - TIC_CLS], rax
    mov rax, [rdi + 8]
    mov [rbp - TIC_OBJ], rax

    mov rdi, [rbp - TIC_CLS]
        call type_check_is_class
    test eax, eax
    jz .tic_error

    ; What the object IS.
    mov rdi, [rbp - TIC_OBJ]
    extern value_type
    call value_type
    test rax, rax
    jz .tic_declared
    mov rdi, rax
    mov rsi, [rbp - TIC_CLS]
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jnz .tic_true

.tic_declared:
    ; ...and what it SAYS it is, which is a separate question a mock answers
    ; differently.  obj_declared_class hands back a new reference.
    mov rdi, [rbp - TIC_OBJ]
    extern obj_declared_class
    call obj_declared_class
    ERR_PENDING .tic_fail
    test rax, rax
    jz .tic_false
    mov rbx, rax
    mov rdi, rax
    mov rsi, [rbp - TIC_CLS]
    call type_is_subtype
    push rax
    push rax                        ; pad
    mov rdi, rbx
    extern obj_decref
    call obj_decref
    pop rax
    pop rax
    test eax, eax
    jnz .tic_true

.tic_false:
    RET_FALSE
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.tic_true:
    RET_TRUE
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.tic_error:
    SET_EXC exc_TypeError_type, "__instancecheck__() takes exactly one argument"
.tic_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC type_method_instancecheck

;; type_method_subclasscheck(args, nargs) -> Value, documented with its twin
;; above: the same plain check, over two classes rather than a class and an
;; instance.
;; Fails: 0
DEF_FUNC type_method_subclasscheck, TIC_FRAME
    push rbx
    cmp rsi, 2
    jne .tsc_error
    mov rax, [rdi]
    mov [rbp - TIC_CLS], rax
    mov rax, [rdi + 8]
    mov [rbp - TIC_OBJ], rax
    mov rdi, rax
    call type_check_is_class
    test eax, eax
    jz .tsc_not_a_class
    mov rdi, [rbp - TIC_CLS]
    call type_check_is_class
    test eax, eax
    jz .tsc_error
    mov rdi, [rbp - TIC_OBJ]
    mov rsi, [rbp - TIC_CLS]
    call type_is_subtype
    test eax, eax
    jnz .tsc_true
    RET_FALSE
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.tsc_true:
    RET_TRUE
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.tsc_not_a_class:
    SET_EXC exc_TypeError_type, "issubclass() arg 1 must be a class"
    jmp .tsc_fail
.tsc_error:
    SET_EXC exc_TypeError_type, "__subclasscheck__() takes exactly one argument"
.tsc_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC type_method_subclasscheck
