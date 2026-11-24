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
DEF_FUNC type_method_new
    push rbx
    push r12
    ; type.__new__(mcls, name, bases, ns, **kwds): the keywords are for
    ; __init_subclass__ and are not ours to reject.
    cmp rsi, 4
    jl .tmn_error
    mov rbx, rdi                    ; args
    mov r12, [rdi]                  ; mcls

    ; type_from_parts consumes a reference to the namespace, and borrows the
    ; name and the bases.  The name used to be given a reference here as
    ; well, which nothing ever took back: one str per class, for every class
    ; built through type.__new__ under a name made for the occasion.
    mov rdi, [rbx + 24]             ; namespace
    call obj_incref
    mov rdi, [rbx + 8]              ; name
    mov rsi, [rbx + 16]             ; bases
    mov rdx, [rbx + 24]
    ; The metatype is whatever __new__ was handed, not the default, and it has
    ; to be on the class before its descriptors' __set_name__ run -- which is
    ; inside type_from_parts.
    mov [gs:ThreadState.class_metatype_pending], r12
    call type_from_parts
    mov qword [gs:ThreadState.class_metatype_pending], 0
    test rax, rax
    jz .tmn_failed                  ; a __set_name__ raised, and it is pending

    ; Stamped already unless type_from_parts bailed before reaching it.
    mov [rax + PyObject.ob_type], r12
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.tmn_failed:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret

.tmn_error:
    SET_EXC exc_TypeError_type, "type.__new__() takes at least 3 arguments"
    jmp .tmn_failed
END_FUNC type_method_new

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
