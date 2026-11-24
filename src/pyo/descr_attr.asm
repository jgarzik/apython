; descr_attr.asm - what the descriptor wrappers answer by NAME
;
; staticmethod, classmethod and property are three small objects whose whole
; job is the descriptor protocol, and descriptors.asm is that protocol: the
; constructors, __get__ / __set__ / __delete__, and the type objects.  This
; file is the other thing Python can do with one -- read an attribute off it:
;
;   property      fget, fset, fdel, __doc__, and getter() / setter() /
;                 deleter(), each of which answers a COPY with one accessor
;                 replaced
;   staticmethod  __func__ and __wrapped__, and __name__ / __qualname__ /
;   classmethod   __doc__ / __module__ forwarded to what is wrapped
;   all three     __isabstractmethod__, which is how abc sees through a
;                 wrapper to the @abstractmethod underneath
;
; Split off when descriptors.asm reached the 100k cap, along the seam between
; "is a descriptor" and "has attributes".  Nothing here raises by jumping.

%include "macros.inc"
%include "object.inc"

extern ap_strcmp
extern obj_decref
extern obj_dealloc
extern method_new
extern builtin_func_new
extern prop_new_of
extern bool_true
extern bool_false

section .data
align 8
; Cached builtin function singletons for property.setter/getter/deleter
_prop_setter_cache: dq 0
_prop_getter_cache: dq 0
_prop_deleter_cache: dq 0

section .rodata
descr_func_name: db "__func__", 0
descr_wrapped_name: db "__wrapped__", 0
descr_fwd_name:     db "__name__", 0
descr_fwd_qualname: db "__qualname__", 0
descr_fwd_doc:      db "__doc__", 0
descr_fwd_module:   db "__module__", 0

section .text

;; ============================================================================
;; property_getattr(PyPropertyObject *self, PyObject *name) -> rax = Value
;; Handles: "setter", "getter", "deleter", "fget", "fset", "fdel"
;; ============================================================================
DEF_FUNC property_getattr
    push rbx
    push r12

    mov rbx, rdi                ; self (property)
    mov r12, rsi                ; name

    ; Compare name against known attributes
    ; name is a PyStrObject — get its data pointer
    lea rdi, [r12 + PyStrObject.data]

    ; Check "setter"
    CSTRING rsi, "setter"
    call ap_strcmp
    test eax, eax
    jz .pga_setter

    ; Check "getter"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "getter"
    call ap_strcmp
    test eax, eax
    jz .pga_getter

    ; Check "deleter"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "deleter"
    call ap_strcmp
    test eax, eax
    jz .pga_deleter

    ; Check "__doc__"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "__doc__"
    call ap_strcmp
    test eax, eax
    jz .pga_doc

    ; Check "fget"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "fget"
    call ap_strcmp
    test eax, eax
    jz .pga_fget

    ; Check "fset"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "fset"
    call ap_strcmp
    test eax, eax
    jz .pga_fset

    ; Check "fdel"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "fdel"
    call ap_strcmp
    test eax, eax
    jz .pga_fdel

    ; Not found
    RET_NULL
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.pga_setter:
    ; Return bound method: method_new(prop_setter_builtin, self)
    call _get_prop_setter_builtin
    mov rdi, rax
    mov rsi, rbx
    call method_new
    jmp .pga_done

.pga_getter:
    call _get_prop_getter_builtin
    mov rdi, rax
    mov rsi, rbx
    call method_new
    jmp .pga_done

.pga_deleter:
    call _get_prop_deleter_builtin
    mov rdi, rax
    mov rsi, rbx
    call method_new
    jmp .pga_done

.pga_fget:
    mov rax, [rbx + PyPropertyObject.prop_get]
    test rax, rax
    jnz .pga_incref_ret
    ; Return None if NULL
    extern none_singleton
    lea rax, [rel none_singleton]
    jmp .pga_incref_ret

.pga_fset:
    mov rax, [rbx + PyPropertyObject.prop_set]
    test rax, rax
    jnz .pga_incref_ret
    lea rax, [rel none_singleton]
    jmp .pga_incref_ret

.pga_fdel:
    mov rax, [rbx + PyPropertyObject.prop_del]
    test rax, rax
    jnz .pga_incref_ret
    lea rax, [rel none_singleton]
    jmp .pga_incref_ret

.pga_doc:
    mov rax, [rbx + PyPropertyObject.prop_doc]
    test rax, rax
    jnz .pga_incref_ret
    lea rax, [rel none_singleton]
    jmp .pga_incref_ret

.pga_incref_ret:
    mov rdi, rax
    push rax
    INCREF_V rdi, rcx
    pop rax

.pga_done:
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC property_getattr

;; ============================================================================
;; Lazy-init helpers for property setter/getter/deleter builtin singletons
;; Each returns a borrowed ref to a cached PyBuiltinObject.
;; ============================================================================

;; _get_prop_setter_builtin() -> PyBuiltinObject* (borrowed)
DEF_FUNC_LOCAL _get_prop_setter_builtin
    mov rax, [rel _prop_setter_cache]
    test rax, rax
    jnz .ret
    lea rdi, [rel _prop_setter_impl]
    CSTRING rsi, "setter"
    call builtin_func_new
    mov [rel _prop_setter_cache], rax
.ret:
    leave
    ret
END_FUNC _get_prop_setter_builtin

;; _get_prop_getter_builtin() -> PyBuiltinObject* (borrowed)
DEF_FUNC_LOCAL _get_prop_getter_builtin
    mov rax, [rel _prop_getter_cache]
    test rax, rax
    jnz .ret
    lea rdi, [rel _prop_getter_impl]
    CSTRING rsi, "getter"
    call builtin_func_new
    mov [rel _prop_getter_cache], rax
.ret:
    leave
    ret
END_FUNC _get_prop_getter_builtin

;; _get_prop_deleter_builtin() -> PyBuiltinObject* (borrowed)
DEF_FUNC_LOCAL _get_prop_deleter_builtin
    mov rax, [rel _prop_deleter_cache]
    test rax, rax
    jnz .ret
    lea rdi, [rel _prop_deleter_impl]
    CSTRING rsi, "deleter"
    call builtin_func_new
    mov [rel _prop_deleter_cache], rax
.ret:
    leave
    ret
END_FUNC _get_prop_deleter_builtin

;; ============================================================================
;; _prop_setter_impl(args, nargs) — property.setter(func)
;; args[0] = property (self from bound method), args[1] = func
;; -> rax = a new property with the same fget/fdel and the new fset
;; Fails: 0
;; ============================================================================
extern method_one_arg_check
DEF_FUNC _prop_setter_impl, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi                ; args: args[0] = property, args[1] = new fset
    CSTRING rdx, "property.setter() takes no keyword arguments"
    CSTRING rcx, "property.setter() takes exactly one argument ("
    call method_one_arg_check
    ERR_NULL .psi_fail
    mov r8, [rbx]               ; old property
    mov r9, [rbx + 8]          ; new fset

    ; Build args for property_construct: (fget, fset, fdel)
    sub rsp, 32                 ; three Values, rsp stays aligned
    mov rax, [r8 + PyPropertyObject.prop_get]
    mov [rsp], rax              ; args[0] = fget
    mov [rsp + 8], r9           ; args[1] = new fset
    mov rax, [r8 + PyPropertyObject.prop_del]
    mov [rsp + 16], rax         ; args[2] = fdel

    ; The new property is an instance of the OLD one's class, not of property:
    ; `@Cached.setter` on a property subclass must still hand back a Cached.
    ; CPython's property_copy takes Py_TYPE(old) for the same reason.
    mov rdi, [r8 + PyObject.ob_type]
    mov rsi, rsp                ; args
    mov edx, 3                  ; nargs
    ; Check if fdel is NULL — if so, pass 2 args
    cmp qword [rsp + 16], 0
    jne .psi_call
    mov edx, 2
.psi_call:
    call prop_new_of
    add rsp, 32
    mov edx, TAG_PTR

    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.psi_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC _prop_setter_impl

;; ============================================================================
;; _prop_getter_impl(args, nargs) — property.getter(func)
;; -> rax = a new property with the new fget and the same fset/fdel
;; Fails: 0
;; ============================================================================
DEF_FUNC _prop_getter_impl, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    CSTRING rdx, "property.getter() takes no keyword arguments"
    CSTRING rcx, "property.getter() takes exactly one argument ("
    call method_one_arg_check
    ERR_NULL .pgi_fail
    mov r8, [rbx]               ; old property
    mov r9, [rbx + 8]          ; new fget

    sub rsp, 32                 ; three Values, rsp stays aligned
    mov [rsp], r9               ; args[0] = new fget
    mov rax, [r8 + PyPropertyObject.prop_set]
    mov [rsp + 8], rax          ; args[1] = fset
    mov rax, [r8 + PyPropertyObject.prop_del]
    mov [rsp + 16], rax         ; args[2] = fdel

    mov rdi, [r8 + PyObject.ob_type]   ; the old property's class, not property
    mov rsi, rsp
    mov edx, 3
    cmp qword [rsp + 16], 0
    jne .pgi_call
    mov edx, 2
    cmp qword [rsp + 8], 0
    jne .pgi_call
    mov edx, 1
.pgi_call:
    call prop_new_of
    add rsp, 32
    mov edx, TAG_PTR

    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.pgi_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC _prop_getter_impl

;; ============================================================================
;; _prop_deleter_impl(args, nargs) — property.deleter(func)
;; -> rax = a new property with the same fget/fset and the new fdel
;; Fails: 0
;; ============================================================================
DEF_FUNC _prop_deleter_impl, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    CSTRING rdx, "property.deleter() takes no keyword arguments"
    CSTRING rcx, "property.deleter() takes exactly one argument ("
    call method_one_arg_check
    ERR_NULL .pdi_fail
    mov r8, [rbx]               ; old property
    mov r9, [rbx + 8]          ; new fdel

    sub rsp, 32                 ; three Values, rsp stays aligned
    mov rax, [r8 + PyPropertyObject.prop_get]
    mov [rsp], rax              ; args[0] = fget
    mov rax, [r8 + PyPropertyObject.prop_set]
    mov [rsp + 8], rax          ; args[1] = fset
    mov [rsp + 16], r9          ; args[2] = new fdel

    mov rdi, [r8 + PyObject.ob_type]   ; the old property's class, not property
    mov rsi, rsp
    mov edx, 3
    call prop_new_of
    add rsp, 32
    mov edx, TAG_PTR

    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.pdi_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC _prop_deleter_impl

;; ============================================================================
;; descr_func_attr(wrapper, PyStrObject *name) -> Value
;;
;; __func__, the wrapped function.  It is the only way to reach the function
;; through the wrapper, and collections.namedtuple needs it: after building
;; _make as a classmethod it does `_make.__func__.__doc__ = ...`.
;;
;; __name__, __qualname__, __doc__ and __module__ are FORWARDED to it, which
;; is what CPython 3.10 made these two wrappers do (bpo-43682) -- a
;; staticmethod is "callable as a regular function" and reads like one.  A
;; module-level callable that must not bind when a class body stores it can
;; only be spelled as a staticmethod here, and lib/select.py does; without the
;; forwarding, `select.select.__name__` was an AttributeError.
;;
;; One function serves both wrappers -- sm_callable and cm_callable are the
;; same slot -- so both type tables point straight at it.
;; ============================================================================
DF_NAME  equ 8              ; the attribute name, across ap_strcmp
DF_FRAME equ 8              ; + 1 push = 16, 16-byte aligned
DEF_FUNC descr_func_attr, DF_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - DF_NAME], rsi    ; a push here would unalign rsp for ap_strcmp
    lea rdi, [rsi + PyStrObject.data]
    lea rsi, [rel descr_func_name]
    call ap_strcmp
    test eax, eax
    je .have
    ; __wrapped__ is the same slot under CPython 3.10's second name, and
    ; functools.wraps and inspect.unwrap both look for it.
    mov rsi, [rbp - DF_NAME]
    lea rdi, [rsi + PyStrObject.data]
    lea rsi, [rel descr_wrapped_name]
    call ap_strcmp
    test eax, eax
    je .have

    ; Anything else the wrapped callable answers for itself.  Only the four
    ; CPython forwards, so a name the function happens to carry does not leak
    ; through the wrapper.
    mov rsi, [rbp - DF_NAME]
    lea rdi, [rsi + PyStrObject.data]
    lea rsi, [rel descr_fwd_name]
    call ap_strcmp
    test eax, eax
    je .forward
    mov rsi, [rbp - DF_NAME]
    lea rdi, [rsi + PyStrObject.data]
    lea rsi, [rel descr_fwd_qualname]
    call ap_strcmp
    test eax, eax
    je .forward
    mov rsi, [rbp - DF_NAME]
    lea rdi, [rsi + PyStrObject.data]
    lea rsi, [rel descr_fwd_doc]
    call ap_strcmp
    test eax, eax
    je .forward
    mov rsi, [rbp - DF_NAME]
    lea rdi, [rsi + PyStrObject.data]
    lea rsi, [rel descr_fwd_module]
    call ap_strcmp
    test eax, eax
    jne .none

.forward:
    mov rax, [rbx + PyClassMethodObject.cm_callable]
    V_TEST_PTR rax, rcx
    ja .none
    test rax, rax
    jz .none
    mov rdi, rax
    mov rsi, [rbp - DF_NAME]
    extern obj_getattr_opt
    call obj_getattr_opt
    test rax, rax
    jz .none
    V_UNPACK rax, rdx
    pop rbx
    leave
    ret

.have:
    mov rax, [rbx + PyClassMethodObject.cm_callable]
    test rax, rax
    jz .none
    ; A VALUE, as the constructor's own comment says.  INCREF wrote through
    ; the number for `staticmethod(1).__func__`, and the V_PACK that followed
    ; was a no-op the wrong way round -- an immediate is already its Value.
    INCREF_V rax, rcx
    xor edx, edx
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.none:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
END_FUNC descr_func_attr

;; ============================================================================
;; descr_is_abstract(rdi = a callable Value, or 0) -> eax = 1 when it carries a
;;   truthy __isabstractmethod__
;;
;; What abc marks a function with.  A wrapper is abstract when what it wraps
;; is, which is how `@property` over `@abstractmethod` reaches
;; ABCMeta.__new__: it collects the names whose values answer True here, and
;; a wrapper that could not answer at all left __abstractmethods__ empty and
;; the class instantiable.
;; ============================================================================
DIA_FRAME equ 8             ; + 1 push = 16, 16-aligned
DEF_FUNC descr_is_abstract, DIA_FRAME
    push rbx
    test rdi, rdi
    jz .dia_no
    V_TEST_PTR rdi, rax
    ja .dia_no
    mov rbx, rdi
    lea rdi, [rel dia_name]
    extern str_from_cstr_heap
    call str_from_cstr_heap
    push rax
    push rax                            ; pad
    mov rdi, rbx
    mov rsi, rax
    extern obj_getattr_opt
    call obj_getattr_opt
    mov rbx, rax
    pop rdi
    pop rdi
    call obj_decref                     ; the name
    test rbx, rbx
    jz .dia_no
    mov rdi, rbx
    extern obj_is_true
    call obj_is_true
    push rax
    push rax                            ; pad
    mov rdi, rbx
    extern obj_decref
    DECREF_V rdi, rcx
    pop rax
    pop rcx
    test eax, eax
    jle .dia_no
    mov eax, 1
    pop rbx
    leave
    ret
.dia_no:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC descr_is_abstract

section .rodata
dia_name: db "__isabstractmethod__", 0
section .text

;; ============================================================================
;; descr_wrapper_isabstract(rdi = a staticmethod or classmethod, rsi = unused)
;;   -> rax = Value: True or False
;;
;; Both keep what they wrap in the same slot, which is why one body serves the
;; pair everywhere else in this file too.
;; ============================================================================
DEF_FUNC descr_wrapper_isabstract
    mov rdi, [rdi + PyStaticMethodObject.sm_callable]
    call descr_is_abstract
    test eax, eax
    jnz .dwa_true
    lea rax, [rel bool_false]
    jmp .dwa_done
.dwa_true:
    lea rax, [rel bool_true]
.dwa_done:
    inc qword [rax + PyObject.ob_refcnt]
    leave
    ret
END_FUNC descr_wrapper_isabstract

;; ============================================================================
;; property_isabstract(rdi = a property, rsi = unused) -> rax = Value
;;
;; A property is abstract when ANY of its three accessors is, which is what
;; lets `@property` sit over `@abstractmethod` and also over a concrete
;; setter.
;; ============================================================================
PIA_SELF  equ 8
PIA_FRAME equ 16            ; + 0 pushes = 16, and a call needs 8 more
DEF_FUNC property_isabstract, PIA_FRAME
    mov [rbp - PIA_SELF], rdi
    mov rdi, [rdi + PyPropertyObject.prop_get]
    call descr_is_abstract
    test eax, eax
    jnz .pia_true
    mov rdi, [rbp - PIA_SELF]
    mov rdi, [rdi + PyPropertyObject.prop_set]
    call descr_is_abstract
    test eax, eax
    jnz .pia_true
    mov rdi, [rbp - PIA_SELF]
    mov rdi, [rdi + PyPropertyObject.prop_del]
    call descr_is_abstract
    test eax, eax
    jnz .pia_true
    lea rax, [rel bool_false]
    jmp .pia_done
.pia_true:
    lea rax, [rel bool_true]
.pia_done:
    inc qword [rax + PyObject.ob_refcnt]
    leave
    ret
END_FUNC property_isabstract
