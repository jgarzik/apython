; builtins_attr.asm - getattr, hasattr, setattr, delattr, and object's
; generic forms of the last two
;
; Split out of builtins_obj.asm, which reached lint's 100k cap for a
; hand-written file when __setattr__ gained a slot and object.__setattr__
; needed a second entry point that does not go through it.
;
; The pair that matters is builtin_setattr and object_generic_setattr.  They
; share a body and differ in one flag: the first dispatches through the type's
; tp_setattr, and the second performs the generic store directly.  That is not
; an optimisation -- for a class that defines __setattr__, tp_setattr IS the
; wrapper that called object.__setattr__, and going back through it is
; unbounded recursion.  delattr is the same shape.

%include "macros.inc"
%include "object.inc"

extern str_type
extern obj_getattr_opt
extern exc_AttributeError_type
extern type_is_subtype
extern obj_decref
extern obj_incref
extern none_singleton
extern bool_true
extern bool_false
extern instance_setattr
extern type_setattr
extern obj_dealloc
extern str_from_cstr
extern dict_get

; The frame slots the two attribute builtins use.  They were defined in
; builtins_obj.asm beside the functions and moved with them.
GA_EXC   equ 24

section .text

;; ============================================================================
;; attr_require_name(rdi = the name argument, a Value) -> rax = 0
;; Fails: -1
;;
;; getattr, setattr, delattr and hasattr all read the name as a PyStrObject
;; without asking what it is: `getattr(x, 0)` read a small integer's Value as
;; one.  CPython refuses the type by name, and quotes it.
;; ============================================================================
ARN_ARG   equ 8
ARN_FRAME equ 16            ; + 0 pushes = 16-aligned
DEF_FUNC_LOCAL attr_require_name, ARN_FRAME
    mov [rbp - ARN_ARG], rdi
    V_TEST_PTR rdi, rax
    ja .arn_bad
    test rdi, rdi
    jz .arn_bad
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .arn_ok
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .arn_bad
.arn_ok:
    xor eax, eax
    leave
    ret
.arn_bad:
    mov rsi, [rbp - ARN_ARG]
    CSTRING rdi, `attribute name must be string, not '\x01'`
    extern set_type_error_with_name
    call set_type_error_with_name
    mov rax, -1
    leave
    ret
END_FUNC attr_require_name

;; ============================================================================
;; attr_found_swallow(rax = the attribute a lookup FOUND) -> rax, unchanged
;;
;; obj_getattr_raw leaves a __getattr__ hook's AttributeError pending so that
;; a MISS can be re-raised in the hook's own words.  It is also still there
;; when the walk went on past the hook and found the name -- a module with a
;; PEP 562 hook, asked for __class__ -- and then it is nobody's.  The same
;; release obj_getattr_opt makes, for the two callers that use the raw form.
;; ============================================================================
AFS_VAL   equ 8
AFS_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL attr_found_swallow, AFS_FRAME
    cmp qword [gs:ThreadState.attr_error_pending], 0
    je .afs_done
    mov [rbp - AFS_VAL], rax
    extern attr_miss_swallow
    call attr_miss_swallow
    mov rax, [rbp - AFS_VAL]
.afs_done:
    leave
    ret
END_FUNC attr_found_swallow

;; ============================================================================
;; builtin_getattr(rdi = args, rsi = nargs) -> rax = Value
;; Fails: 0
;; getattr(obj, name[, default]): the default is answered only for an
;; AttributeError, so anything else the lookup raises still propagates.
;; ============================================================================
DEF_FUNC builtin_getattr, 32
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi

    cmp r12, 2
    jb .getattr_too_few
    cmp r12, 3
    ja .getattr_error

    ; One lookup, with the descriptor protocol run over it -- the same answer
    ; `obj.name` gives.  Doing it by hand here is what made getattr() hand back
    ; the property object instead of calling it.
    mov rdi, [rbx + 8]
    call attr_require_name
    ERR_M1 .getattr_propagate
    DUNDER_EXC_SAVE [rbp - GA_EXC]
    mov rdi, [rbx]                 ; args[0], as a Value
    mov rsi, [rbx + 8]             ; args[1], the name
    extern obj_getattr_raw
    call obj_getattr_raw
    test rax, rax
    jz .getattr_missing
    call attr_found_swallow     ; found: a hook's "absent" behind it is stale
    pop r12
    pop rbx
    leave
    ret

.getattr_missing:
    ; A getter that raised is not a missing attribute: returning the default,
    ; or an AttributeError, would bury the real exception.  current_exception
    ; is also whatever is being HANDLED, so it has to be compared against the
    ; snapshot rather than tested for emptiness.
    DUNDER_RAISED [rbp - GA_EXC], .getattr_check_type
.getattr_absent:
    cmp r12, 3
    jne .getattr_raise
    mov rax, [rbx + 16]            ; args[2], the default
    INCREF_V rax, rdx
    pop r12
    pop rbx
    leave
    ret

.getattr_check_type:
    ; Something was raised.  Only an AttributeError means "absent" -- that is
    ; the exception the __getattr__ and descriptor protocols use to say so, and
    ; the only one CPython swallows here.  Anything else is a real failure and
    ; returning the default would bury it.
    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jz .getattr_absent
    mov rdi, [rax + PyObject.ob_type]
    lea rsi, [rel exc_AttributeError_type]
    call type_is_subtype           ; a subclass of AttributeError counts too
    test eax, eax
    jz .getattr_propagate
    ; With no default to fall back on, CPython re-raises what was raised --
    ; __getattr__'s own message, not a manufactured one -- so leave it pending.
    cmp r12, 3
    jne .getattr_propagate
    ; Clear it before releasing, so a dealloc that re-enters cannot see a
    ; pointer that is about to go away.
    mov rdi, [gs:ThreadState.current_exception]
    mov qword [gs:ThreadState.current_exception], 0
    call obj_decref
    jmp .getattr_absent

.getattr_propagate:
    xor eax, eax                   ; NULL with the exception pending: op_call unwinds
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret

.getattr_raise:
    ; Name the object's type and the attribute, as every other path does.
    ; getattr(o, "zzz") said only "object has no attribute", which is the
    ; sentence with both nouns taken out of it.
    mov rdi, [rbx]
    mov rsi, [rbx + 8]
    xor edx, edx                ; a get, so .name and .obj are filled in
    extern set_no_attribute
    call set_no_attribute
    jmp .getattr_propagate

.getattr_too_few:
    mov rsi, r12
    CSTRING rdi, "getattr expected at least 2 arguments, got "
    xor edx, edx
    extern set_type_error_counted
    call set_type_error_counted
    jmp .getattr_propagate

.getattr_error:
    mov rsi, r12
    CSTRING rdi, "getattr expected at most 3 arguments, got "
    xor edx, edx
    call set_type_error_counted
    jmp .getattr_propagate
END_FUNC builtin_getattr

;; ============================================================================
;; 18. builtin_hasattr(rdi = args, rsi = nargs) - hasattr(obj, name)
;;   -> rax = Value
;; Fails: 0
;; ============================================================================
HA_EXC    equ 8              ; current_exception before the lookup
DEF_FUNC builtin_hasattr, 24
    push rbx
    mov rbx, rdi
    cmp rsi, 2
    jne .hasattr_error

    ; The same lookup getattr() does, so the two cannot disagree about what
    ; exists.  A getter that raises propagates rather than reading as absent,
    ; which is what CPython does for anything but an AttributeError.
    mov rdi, [rbx + 8]
    call attr_require_name
    ERR_M1 .hasattr_propagate
    DUNDER_EXC_SAVE [rbp - HA_EXC]
    mov rdi, [rbx]
    mov rsi, [rbx + 8]
    extern obj_getattr_raw
    call obj_getattr_raw
    test rax, rax
    jz .hasattr_missing
    call attr_found_swallow
    mov rdi, rax
    DECREF_V rdi, rsi
    lea rax, [rel bool_true]
    INCREF rax
    pop rbx
    leave
    ret
.hasattr_missing:
    ; hasattr swallows a missing attribute, not a getter that blew up.
    DUNDER_RAISED [rbp - HA_EXC], .hasattr_check_type
.hasattr_false:
    lea rax, [rel bool_false]
    INCREF rax
    pop rbx
    leave
    ret
.hasattr_check_type:
    ; As getattr: only an AttributeError reads as absent.
    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jz .hasattr_false
    mov rdi, [rax + PyObject.ob_type]
    lea rsi, [rel exc_AttributeError_type]
    call type_is_subtype
    test eax, eax
    jz .hasattr_propagate
    mov rdi, [gs:ThreadState.current_exception]
    mov qword [gs:ThreadState.current_exception], 0
    call obj_decref
    jmp .hasattr_false

.hasattr_propagate:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.hasattr_error:
    CSTRING rdi, "hasattr expected 2 arguments, got "
    xor edx, edx
    call set_type_error_counted
    jmp .hasattr_propagate
END_FUNC builtin_hasattr

;; ============================================================================
;; 19. builtin_setattr(rdi = args, rsi = nargs) - setattr(obj, name, value)
;;   -> rax = Value
;; Fails: 0
;; ============================================================================
SETA_EXC equ 16     ; the exception pending before tp_setattr ran
SETA_GENERIC equ 24 ; non-zero when this is object.__setattr__

DEF_FUNC_BARE builtin_setattr
    xor edx, edx                       ; go through the type's tp_setattr
    jmp setattr_impl
END_FUNC builtin_setattr

;; ============================================================================
;; object_generic_setattr(rdi = args, rsi = nargs) -> the None Value
;; Fails: 0
;;
;; object.__setattr__ and object.__delattr__: the GENERIC store, which must not
;; go through the type's tp_setattr.  For a class that defines __setattr__ that
;; slot is slot_tp_setattr -- the wrapper that called this -- and the
;; `object.__setattr__(self, k, v)` such a method almost always ends with would
;; recurse until the stack ran out.  CPython separates the two the same way,
;; and for the same reason.
;; ============================================================================
global object_generic_setattr
DEF_FUNC_BARE object_generic_setattr
    mov edx, 1                         ; the generic store, whatever the type
    jmp setattr_impl
END_FUNC object_generic_setattr

;; ============================================================================
;; setattr_impl(rdi = args, rsi = nargs, edx = generic?) -> the None Value
;; Fails: 0
;;
;; The body both of the above share.  edx picks the store; everything else is
;; identical, including the wording of both errors.
;; ============================================================================
DEF_FUNC_LOCAL setattr_impl
    push rbx
    sub rsp, 24
    mov [rbp - SETA_GENERIC], rdx

    cmp rsi, 3
    jne .setattr_error

    mov rbx, rdi

    mov rdi, [rbx + 8]           ; the name, before anything reads it as one
    call attr_require_name
    ERR_M1 .setattr_raised

    V_TEST_PTR_M [rbx], r11      ; args[0] a pointer?
    ja .setattr_no_attr
    mov rdi, [rbx]                     ; args[0] payload (obj)

    cmp qword [rbp - SETA_GENERIC], 0
    jne .setattr_generic
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_setattr]
    test rax, rax
    jz .setattr_no_attr
    jmp .setattr_have_store
.setattr_generic:
    ; The generic store for the object at hand.  A class is not an ordinary
    ; instance: writing to one goes through type_setattr, which renames the
    ; type on __name__, reinstalls its slots and refreshes its version.
    ;
    ; This stands in for a `type.__setattr__` entry, which this tree does not
    ; have -- so `super().__delattr__(name)` from a metaclass resolves past
    ; type to object's, and object's has to be the one that knows.  enum.py's
    ; EnumType.__delattr__ does exactly that, and reached instance_setattr on a
    ; class, which deleted nothing and raised.
    extern instance_setattr
    extern type_setattr
    mov rcx, [rdi + PyObject.ob_type]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .setattr_generic_instance
    lea rax, [rel type_setattr]
    jmp .setattr_have_store
.setattr_generic_instance:
    lea rax, [rel instance_setattr]
.setattr_have_store:

    push rax                           ; save the store to call
    mov rdi, [rbx]                     ; args[0] payload (obj)
    mov rsi, [rbx + 8]               ; args[1] payload (name, 16-byte stride)
    mov rdx, [rbx + 16]               ; args[2] payload (value, 16-byte stride)
    pop rax                            ; restore tp_setattr
    DUNDER_EXC_SAVE [rbp - SETA_EXC]
    call rax

    ; tp_setattr reports failure by leaving an exception pending, not in a
    ; register, so a property setter that raised came back here as a success
    ; and setattr() answered None.  Compared against entry, because
    ; current_exception is already set inside an except block.
    EXC_RAISED_SINCE [rbp - SETA_EXC], rcx, .setattr_raised

    RET_NONE
    add rsp, 24
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.setattr_raised:
    xor eax, eax
    xor edx, edx
    add rsp, 24                 ; the prologue's carve, which grew with
                                ; SETA_GENERIC; popping 8 restored rbx from
                                ; the flag slot instead
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.setattr_no_attr:
    ; CPython reports the missing attribute, not a generic "unsupported":
    ; setattr(5, "x", 1) is AttributeError: 'int' object has no attribute 'x'.
    mov rdi, [rbx]
    mov rsi, [rbx + 8]
    extern set_no_attribute_store
    call set_no_attribute_store
    jmp .setattr_raised

.setattr_error:
    CSTRING rdi, "setattr expected 3 arguments, got "
    xor edx, edx
    call set_type_error_counted
    jmp .setattr_raised
END_FUNC setattr_impl


;; ============================================================================
;; builtin_delattr_fn(rdi = args, rsi = nargs) - delattr(obj, name)
;;   -> rax = Value
;; Fails: 0
;; Calls tp_setattr(obj, name, NULL) to delete
;; ============================================================================
global builtin_delattr_fn
DA2_OBJ   equ 8
DA2_NAME  equ 16
DA2_EXC   equ 24            ; the exception pending before the deleter ran
DA2_GENERIC equ 32          ; non-zero when this is object.__delattr__
DA2_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC_BARE builtin_delattr_fn
    xor edx, edx                       ; go through the type's tp_setattr
    jmp delattr_impl
END_FUNC builtin_delattr_fn

;; ============================================================================
;; object_generic_delattr(rdi = args, rsi = nargs) -> the None Value
;; Fails: 0
;;
;; object.__delattr__: the generic delete, which must not go through the
;; type's tp_setattr.  The same recursion object_generic_setattr avoids.
;; ============================================================================
global object_generic_delattr
DEF_FUNC_BARE object_generic_delattr
    mov edx, 1
    jmp delattr_impl
END_FUNC object_generic_delattr

;; ============================================================================
;; delattr_impl(rdi = args, rsi = nargs, edx = generic?) -> the None Value
;; Fails: 0
;; ============================================================================
DEF_FUNC_LOCAL delattr_impl, DA2_FRAME
    mov [rbp - DA2_GENERIC], rdx

    cmp rsi, 2
    jne .da2_nargs_error

    ; Get obj and name
    mov rax, [rdi]             ; obj payload
    mov [rbp - DA2_OBJ], rax
    mov rax, [rdi + 8]       ; name payload
    mov [rbp - DA2_NAME], rax
    push rdi
    sub rsp, 8
    mov rdi, rax
    call attr_require_name
    ERR_M1 .da2_raised
    add rsp, 8
    pop rdi

    ; An immediate has no attributes at all, and neither does a type with no
    ; tp_setattr -- but that is an AttributeError naming the type and the
    ; name, exactly as `del x.y` gives, not a complaint about delattr's own
    ; first argument.
    V_TEST_PTR_M [rdi], r11      ; args[0] a pointer?
    ja .da2_no_attr

    ; Get the store: the type's, or the generic one.
    mov rdi, [rbp - DA2_OBJ]
    cmp qword [rbp - DA2_GENERIC], 0
    jne .da2_generic
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_setattr]
    test rax, rax
    jz .da2_no_attr
    jmp .da2_have_store
.da2_generic:
    ; As object_generic_setattr above: a class deletes through type_setattr.
    mov rcx, [rdi + PyObject.ob_type]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .da2_generic_instance
    lea rax, [rel type_setattr]
    jmp .da2_have_store
.da2_generic_instance:
    lea rax, [rel instance_setattr]
.da2_have_store:

    ; Call tp_setattr(obj, name, NULL=delete)
    mov rdi, [rbp - DA2_OBJ]
    mov rsi, [rbp - DA2_NAME]
    xor edx, edx              ; value = NULL means delete
    xor ecx, ecx              ; value tag = TAG_NULL
    DUNDER_EXC_SAVE [rbp - DA2_EXC]
    call rax

    ; A deleter that raised leaves the exception pending and returns
    ; normally, so delattr() answered None and it surfaced somewhere else.
    EXC_RAISED_SINCE [rbp - DA2_EXC], rcx, .da2_raised

    ; Return None
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.da2_raised:
    xor eax, eax
    xor edx, edx
    leave
    V_PACK rax, rdx
    ret

.da2_no_attr:
    mov rdi, [rbp - DA2_OBJ]
    mov rsi, [rbp - DA2_NAME]
    call set_no_attribute_store
    jmp .da2_raised

.da2_nargs_error:
    CSTRING rdi, "delattr expected 2 arguments, got "
    xor edx, edx
    call set_type_error_counted
    jmp .da2_raised
END_FUNC delattr_impl
