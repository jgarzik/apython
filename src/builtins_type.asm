; builtins_type.asm - isinstance() and issubclass(), and the question they
; both have to ask first.
;
; Split out of builtins.asm, which reached the 100k cap that src/compiler/lint.py
; enforces.  The seam is a real one: these two builtins are the only ones that
; answer a question about the TYPE RELATIONSHIP between two objects, they share
; obj_declared_class -- the "what does this object say it is" step CPython takes
; before it looks at what the object really is -- and each recurses into the
; other's tuple form.  Nothing else in builtins.asm calls any of the three.
;
; The invariant that matters here: obj_declared_class hands back either 0 or an
; OWNED reference, and every exit that can be reached after it has run must
; release it exactly once.  A slot that is released on a path that never wrote
; it decrements a word at whatever address the machine stack was holding.

%include "macros.inc"
%include "object.inc"

; --- objects and refcounting ---
extern obj_decref
extern obj_dealloc
extern obj_getattr_opt
extern dunder_name_obj

; --- types this asks about by identity ---
extern bool_type
extern float_type
extern int_type
extern none_type
extern tuple_type
extern union_type
extern generic_alias_type

; --- the type machinery ---
extern type_check_is_class
extern type_custom_check
extern type_is_subtype

; --- singletons and the exception plumbing ---
extern bool_true
extern bool_false
extern eval_exception_unwind
extern exc_TypeError_type
extern raise_exception
extern raise_type_error_counted

section .text


;; ============================================================================
;; builtin_isinstance(PyObject **args, int64_t nargs) -> rax = Value
;; isinstance(obj, type) -> True/False
;; Walks the full tp_base chain for inheritance.
;; ============================================================================
ISI_OBJ   equ 8         ; the object as a Value, for __instancecheck__
ISI_DECL  equ 16        ; obj.__class__, when it is a class and differs
ISI_FRAME equ 16            ; + 2 pushes = 32

;; ============================================================================
;; obj_declared_class(rdi = the object as a Value) -> rax = its __class__ when
;;   that is a class and is NOT simply type(obj), else 0.  A NEW reference.
;;
;; CPython asks an object what class it says it belongs to, not only what
;; class it is: an object with a __class__ of its own -- a mock, mostly -- is
;; judged by the answer.  isinstance() consults both, and so does
;; _abc_instancecheck.
;;
;; Returns 0 for anything that is not a heap object, has no __class__, or
;; whose __class__ is the type it already has.
;; ============================================================================
extern obj_getattr_opt
extern dunder_name_obj
ODC_OBJ   equ 8
ODC_TYPE  equ 16
ODC_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC obj_declared_class, ODC_FRAME
    mov [rbp - ODC_OBJ], rdi
    V_TEST_PTR rdi, rax
    ja .odc_none
    test rdi, rdi
    jz .odc_none

    mov rax, [rdi + PyObject.ob_type]
    mov [rbp - ODC_TYPE], rax   ; the real type

    lea rdi, [rel isi_class_attr]
    call dunder_name_obj        ; borrowed, interned by literal
    mov rsi, rax
    mov rdi, [rbp - ODC_OBJ]
    call obj_getattr_opt
    test rax, rax
    jz .odc_lookup_failed

    ; __class__ is whatever the property returned, and that need not be an
    ; object at all.  `class B: __class__ = property(lambda s: 42)` handed an
    ; int IMMEDIATE to type_check_is_class and then to obj_decref, which
    ; decremented a word at V_INT_BIAS + 42.  A non-pointer is not a class, and
    ; DECREF_V is the release that knows there is nothing to release.
    V_TEST_PTR rax, rcx
    ja .odc_drop_value

    push rax
    mov rdi, rax
    call type_check_is_class
    pop rdi
    test eax, eax
    jz .odc_drop
    cmp rdi, [rbp - ODC_TYPE]
    je .odc_drop                ; the same answer, so it adds nothing
    mov rax, rdi
    leave
    ret
.odc_drop:
    call obj_decref
.odc_none:
    xor eax, eax
    leave
    ret
.odc_drop_value:
    mov rdi, rax
    DECREF_V rdi, rcx
    xor eax, eax
    leave
    ret

.odc_lookup_failed:
    ; A __class__ that RAISES is not a __class__ that is missing.  CPython
    ; propagates anything but an AttributeError out of isinstance(); this
    ; answered False with the exception still pending, and it surfaced at the
    ; end of the program as an unraisable naming a frame long gone.
    ;
    ; attr_error_pending is the tree's own flag for "the AttributeError below
    ; is the ordinary answer to a lookup", which is exactly the one CPython
    ; swallows here.
    cmp qword [gs:ThreadState.current_exception], 0
    je .odc_none
    cmp qword [gs:ThreadState.attr_error_pending], 0
    jne .odc_none
    extern eval_exception_unwind
    leave
    jmp eval_exception_unwind
END_FUNC obj_declared_class

;; ============================================================================
;; builtin_isinstance(rdi = args, rsi = nargs) -> rax = Value, True or False
;;
;; The frame constants are above, beside the header that describes what this
;; answers; only obj_declared_class stands between the two, because this needs
;; it before it can start.
;;
;; ISI_DECL holds an OWNED reference and .isi_release_declared releases it, so
;; it is zeroed in the prologue: the arm that leaves for .isinstance_false on
;; an unknown tag never reaches the store, and released the stack instead.
;; ============================================================================
DEF_FUNC builtin_isinstance, ISI_FRAME
    push rbx
    push r12

    ; Before anything can jump to .isinstance_false, which releases it.
    ; obj_declared_class() writes this slot much further down, but the
    ; "unknown non-pointer tag" arm below leaves for .isinstance_false without
    ; ever reaching that store -- and .isi_release_declared then obj_decref'd
    ; whatever the stack happened to hold.  It was a live code object's
    ; bytecode: one decrement turned a RETURN_VALUE (83) into an 82, and the
    ; eval loop died on an opcode CPython 3.12 does not assign.
    ;
    ; abc_instancecheck_func has always zeroed its equivalent slot here.
    mov qword [rbp - ISI_DECL], 0

    cmp rsi, 2
    jne .isinstance_error

    extern bool_true
    extern bool_false

    mov rax, [rdi]
    mov [rbp - ISI_OBJ], rax   ; the object as a Value, for __instancecheck__
    mov rax, [rdi]             ; rax = args[0] = obj
    V_UNPACK rax, r8
    mov rcx, [rdi + 8]         ; rcx = args[1] = type_to_check
    V_UNPACK rcx, r9

    ; Get obj's type (tag-aware for all inline types)
    cmp r8d, TAG_SMALLINT
    je .isinstance_smallint
    cmp r8d, TAG_FLOAT
    je .isinstance_float
    cmp r8d, TAG_PTR
    jne .isinstance_false      ; unknown non-pointer tag → False
    mov rdx, [rax + PyObject.ob_type]
    jmp .isinstance_got_type

.isinstance_none:
    lea rdx, [rel none_type]
    jmp .isinstance_got_type

.isinstance_smallint:
    lea rdx, [rel int_type]
    jmp .isinstance_got_type

.isinstance_float:
    lea rdx, [rel float_type]
    jmp .isinstance_got_type

.isinstance_bool:
    lea rdx, [rel bool_type]

.isinstance_got_type:
    ; rdx = obj's type, rcx = type_to_check (may be tuple)
    ; Second arg must be TAG_PTR (type or tuple)
    cmp r9d, TAG_PTR
    jne .isinstance_type_error
    mov rax, [rcx + PyObject.ob_type]
    extern tuple_type
    lea r8, [rel tuple_type]
    cmp rax, r8
    je .isinstance_tuple
    ; A parameterized generic has its own refusal in CPython, and saying only
    ; that it is not a type buries which of the two mistakes it was.
    extern generic_alias_type
    lea r8, [rel generic_alias_type]
    cmp rax, r8
    je .isinstance_generic
    ; A union is its members, and isinstance over one is isinstance over
    ; them: CPython treats `int | str` exactly as it treats `(int, str)`.
    ; The message here has always said "or a union"; nothing accepted one.
    extern union_type
    lea r8, [rel union_type]
    cmp rax, r8
    jne .isinstance_not_union
    mov rcx, [rcx + PyGenericAliasObject.ga_args]
    jmp .isinstance_tuple
.isinstance_not_union:
    ; Any class, including one built by a user metaclass.
    push rcx
    push rdx
    mov rdi, rcx
    extern type_check_is_class
    call type_check_is_class
    pop rdx
    pop rcx
    test eax, eax
    jz .isinstance_type_error

    ; A metaclass may define __instancecheck__ -- that is how ABCMeta makes
    ; isinstance() consult a registry rather than the MRO.
    push rcx
    push rdx
    mov rdi, rcx                ; the class
    mov rsi, [rbp - ISI_OBJ]    ; the object
    CSTRING rdx, "__instancecheck__"
    extern type_custom_check
    call type_custom_check
    pop rdx
    pop rcx
    cmp eax, -1
    je .isinstance_check
    test eax, eax
    jz .isinstance_false
    jmp .isinstance_true

.isinstance_check:
    ; The MRO, not the tp_base chain: a class with several bases is an
    ; instance of all of them.
    extern type_is_subtype
    push rcx                    ; the target class: type_is_subtype clobbers it
    push rcx
    mov rdi, rdx
    mov rsi, rcx
    call type_is_subtype
    pop rcx
    pop rcx
    test eax, eax
    jnz .isinstance_true

    ; ...and only then what the object SAYS it is.  This used to be asked up
    ; front, before the real type had been consulted at all, which is not
    ; CPython's order: object_isinstance takes PyObject_TypeCheck first and
    ; looks up __class__ only when that says no.  The difference is visible as
    ; soon as the lookup can fail -- `isinstance(x, type(x))` must not run a
    ; __class__ property, and must answer True rather than propagate when one
    ; would raise.
    push rcx                    ; the target class: the call clobbers it
    push rcx
    mov rdi, [rbp - ISI_OBJ]
    call obj_declared_class
    pop rcx
    pop rcx
    mov [rbp - ISI_DECL], rax
    test rax, rax
    jz .isinstance_false
    mov rdi, rax
    mov rsi, rcx
    call type_is_subtype
    test eax, eax
    jnz .isinstance_true
    jmp .isinstance_false

.isinstance_tuple:
    ; rcx = tuple of types. Check obj against each.
    mov rbx, rcx               ; rbx = tuple
    mov r12, rdx               ; r12 = obj's type (saved)
    mov rsi, [rbx + PyTupleObject.ob_item]  ; payloads
    mov rcx, [rbx + PyTupleObject.ob_size]
    xor r8d, r8d               ; index
.isinstance_tuple_loop:
    cmp r8, rcx
    jge .isinstance_false
    push rcx
    push r8
    push rsi
    push rsi                   ; keep the stack 16-byte aligned
    ; Ask again with the element as the second argument, rather than
    ; testing it here.  CPython recurses over a tuple's elements, so a
    ; nested tuple, a union, a parameterized generic and a non-class all
    ; get the answer -- or the refusal -- they get at the top level.  The
    ; flat loop that used to be here read a non-class element's Value as a
    ; type pointer: `isinstance(1, (1,))` was a segfault.
    mov rdi, [rsi + r8*8]      ; the element, a Value
    sub rsp, 16
    mov rax, [rbp - ISI_OBJ]
    mov [rsp], rax
    mov [rsp + 8], rdi
    mov rdi, rsp
    mov esi, 2
    call builtin_isinstance
    add rsp, 16
    V_UNPACK rax, rdx
    lea rcx, [rel bool_true]
    cmp rax, rcx
    pop rsi
    pop rsi
    pop r8
    pop rcx
    je .isinstance_true
    inc r8
    jmp .isinstance_tuple_loop

.isinstance_false:
    call .isi_release_declared
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    pop r12
    pop rbx
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.isinstance_true:
    call .isi_release_declared
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    pop r12
    pop rbx
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.isi_release_declared:
    mov rdi, [rbp - ISI_DECL]
    test rdi, rdi
    jz .isi_nothing
    mov qword [rbp - ISI_DECL], 0
    jmp obj_decref
.isi_nothing:
    ret

.isinstance_generic:
    RAISE exc_TypeError_type, \
          "isinstance() argument 2 cannot be a parameterized generic"

.isinstance_type_error:
    RAISE exc_TypeError_type, "isinstance() arg 2 must be a type, a tuple of types, or a union"

.isinstance_error:
    CSTRING rdi, "isinstance expected 2 arguments, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_isinstance

;; ============================================================================
;; builtin_issubclass(PyObject **args, int64_t nargs) -> rax = Value
;; issubclass(cls, parent) -> True/False
;; Walks the full tp_base chain for inheritance.
;; Supports tuple second arg: issubclass(cls, (type1, type2, ...))
;; ============================================================================
ISC_CLS   equ 8         ; args[0] as a Value, for the recursion over a tuple
ISC_FRAME equ 24            ; + 3 pushes = 48, 16-aligned
DEF_FUNC builtin_issubclass, ISC_FRAME
    push rbx
    push r12
    push r13

    cmp rsi, 2
    jne .issubclass_error

    mov rdx, [rdi]             ; rdx = args[0] = cls
    mov [rbp - ISC_CLS], rdx   ; the Value, which the payload below is not
    V_UNPACK rdx, r8
    mov rcx, [rdi + 8]         ; rcx = args[1] = parent
    V_UNPACK rcx, r9

    ; The SECOND argument decides first.  CPython's PyObject_IsSubclass
    ; takes the tuple branch before it looks at the first argument at all,
    ; so `issubclass((), ())` is False there -- the empty tuple runs out of
    ; members before anything is checked -- and was an error here.  Each
    ; member's recursion validates the first argument in its own right.
    cmp r9d, TAG_PTR
    jne .issubclass_check_arg1
    mov rax, [rcx + PyObject.ob_type]
    lea r10, [rel tuple_type]
    cmp rax, r10
    je .issubclass_tuple

.issubclass_check_arg1:
    ; Validate first arg is a type.  A user metaclass makes its instances
    ; classes too, so this is a subtype test, not three pointer compares.
    cmp r8d, TAG_PTR
    jne .issubclass_arg1_error
    push rcx
    push rdx
    push r9
    mov rdi, rdx
    call type_check_is_class
    pop r9
    pop rdx
    pop rcx
    test eax, eax
    jz .issubclass_arg1_error

    ; Only now is a non-class second argument an error of its own, and
    ; type_check_is_class clobbered the type read above.
    cmp r9d, TAG_PTR
    jne .issubclass_arg2_error
    mov rax, [rcx + PyObject.ob_type]
    lea r10, [rel generic_alias_type]
    cmp rax, r10
    je .issubclass_generic
    ; A union is its members, exactly as a tuple of them would be.  The
    ; message here has always said "or a union"; nothing accepted one.
    lea r10, [rel union_type]
    cmp rax, r10
    jne .issubclass_not_union
    mov rcx, [rcx + PyGenericAliasObject.ga_args]
    jmp .issubclass_tuple
.issubclass_not_union:
    ; Validate second arg is a type
    push rcx
    push rdx
    mov rdi, rcx
    call type_check_is_class
    pop rdx
    pop rcx
    test eax, eax
    jz .issubclass_arg2_error

    ; Single type check.  A metaclass __subclasscheck__ -- ABCMeta's, above
    ; all -- decides before the MRO is walked, since a virtual subclass is
    ; not in anyone's MRO.
.issubclass_walk:
    push rcx
    push rdx
    mov rdi, rcx                ; the parent class
    mov rsi, rdx                ; the candidate subclass
    CSTRING rdx, "__subclasscheck__"
    call type_custom_check
    pop rdx
    pop rcx
    cmp eax, -1
    jne .issubclass_from_hook
    mov rdi, rdx
    mov rsi, rcx
    call type_is_subtype
    test eax, eax
    jnz .issubclass_true
    jmp .issubclass_false
.issubclass_from_hook:
    test eax, eax
    jnz .issubclass_true
    jmp .issubclass_false

.issubclass_tuple:
    ; rcx = tuple of types. Check cls against each.
    mov rbx, rcx               ; rbx = tuple
    mov r12, rdx               ; r12 = cls (saved)
    mov rsi, [rbx + PyTupleObject.ob_item]  ; payloads array
    mov r13, [rbx + PyTupleObject.ob_size]  ; count
    xor r8d, r8d               ; index
.issubclass_tuple_loop:
    cmp r8, r13
    jge .issubclass_false
    push rsi
    push r8
    ; The same recursion as isinstance's, and for the same reason: an
    ; element that is not a class was read as one.
    mov rdi, [rsi + r8*8]      ; the element, a Value
    sub rsp, 16
    mov rax, [rbp - ISC_CLS]
    mov [rsp], rax             ; cls, as the Value it arrived as
    mov [rsp + 8], rdi
    mov rdi, rsp
    mov esi, 2
    call builtin_issubclass
    add rsp, 16
    V_UNPACK rax, rdx
    lea rcx, [rel bool_true]
    cmp rax, rcx
    pop r8
    pop rsi
    je .issubclass_true
    inc r8
    jmp .issubclass_tuple_loop

.issubclass_false:
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    pop r13
    pop r12
    pop rbx
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.issubclass_true:
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    pop r13
    pop r12
    pop rbx
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.issubclass_arg1_error:
    RAISE exc_TypeError_type, "issubclass() arg 1 must be a class"

.issubclass_arg2_error:
    RAISE exc_TypeError_type, "issubclass() arg 2 must be a class, a tuple of classes, or a union"
.issubclass_generic:
    RAISE exc_TypeError_type, \
          "issubclass() argument 2 cannot be a parameterized generic"

.issubclass_error:
    CSTRING rdi, "issubclass expected 2 arguments, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_issubclass


section .rodata
isi_class_attr:  db "__class__", 0
