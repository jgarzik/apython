; descriptors.asm - staticmethod, classmethod, property descriptor types
;
; staticmethod(func) -> wrapper that prevents method binding
; classmethod(func) -> wrapper that binds class instead of instance
; property(fget[, fset[, fdel]]) -> data descriptor

%include "macros.inc"
%include "object.inc"
extern dict_get_mro
extern str_type
extern generic_alias_dealloc

extern descr_alloc
extern prop_new_of
extern ap_strcmp
extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern ap_free
extern obj_incref
extern obj_decref
extern obj_dealloc
extern type_type
extern set_exception
extern rbt_typename
extern rbt_append_cstr
extern exc_TypeError_type
extern exc_AttributeError_type
extern ap_strcmp
extern obj_call_n
extern method_new
extern builtin_func_new
extern property_getattr
extern descr_func_attr

;; ============================================================================
;; staticmethod_construct(rdi = the class, rsi = args, rdx = nargs)
;;   -> rax = the wrapper, edx = TAG_PTR; (0, 0) with a TypeError pending
;; Fails: 0
;;
;; tp_new for staticmethod_type.  The class is NOT always staticmethod: see
;; descr_alloc above.
;; ============================================================================
DEF_FUNC staticmethod_construct, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx

    ; A SUBCLASS's arguments belong to its __init__, and CPython's __new__
    ; ignores what it cannot use rather than refusing them: `class Named(staticmethod)`
    ; taking (f, label) reaches this first.  The exact type is strict, because
    ; nothing runs __init__ after it -- type_call's builtin shortcut is tp_new
    ; and nothing else.
    lea rax, [rel staticmethod_type]
    cmp rdi, rax
    je .sm_exact
    xor ebx, ebx
    test rdx, rdx
    jz .sm_have
    mov rbx, [rsi]
    jmp .sm_have
.sm_exact:
    cmp rdx, 1
    jne .sm_error
    mov rbx, [rsi]              ; rbx = func (args[0])
.sm_have:

    ; rdi is still the class this was called on; nothing above touches it.
    lea rsi, [rel staticmethod_type]
    mov edx, PyStaticMethodObject_size
    call descr_alloc
    ; ob_refcnt=1, ob_type set
    mov [rax + PyStaticMethodObject.sm_callable], rbx

    ; A VALUE, as classmethod's is: `staticmethod(0)` is an ordinary call.
    push rax
    mov rax, rbx
    INCREF_V rax, rcx
    mov rdi, [rsp]
    call gc_track
    pop rax

    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.sm_error:
    mov rsi, rdx
    CSTRING rdi, "staticmethod expected 1 argument, got "
    xor edx, edx
    extern set_type_error_counted
    call set_type_error_counted
    RET_NULL
    pop rbx
    leave
    ret
END_FUNC staticmethod_construct

;; ============================================================================
;; staticmethod_dealloc(PyObject *self)
;; ============================================================================
DEF_FUNC_LOCAL staticmethod_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyStaticMethodObject.sm_callable]
    XDECREF_V rdi, rax

    mov rdi, rbx
    call gc_dealloc

    pop rbx
    leave
    ret
END_FUNC staticmethod_dealloc

;; ============================================================================
;; staticmethod_call(rdi = self, rsi = Value *args, rdx = nargs) -> Value
;;
;; tp_call for staticmethod_type.  A staticmethod object has been callable
;; since Python 3.10 -- `staticmethod(f)(x)` is `f(x)` -- and this tree had it
;; at 0, so calling one raised TypeError and callable() answered False.
;;
;; The wrapped value is a Value and need not be a pointer at all:
;; staticmethod(1) is legal to build, and calling it must report the int the
;; way calling the int directly would.  That is what op_call does for the same
;; condition, with the same helper.
;; Fails: 0
;; ============================================================================
DEF_FUNC staticmethod_call, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx

    mov rbx, [rdi + PyStaticMethodObject.sm_callable]
    V_TEST_PTR rbx, rax
    ja .smc_not_callable
    test rbx, rbx
    jz .smc_not_callable
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .smc_not_callable

    mov rdi, rbx
    call rax                    ; the wrapped callable, with our args verbatim

    pop rbx
    leave
    ret

.smc_not_callable:
    mov rsi, rbx
    CSTRING rdi, `'\x01' object is not callable`
    extern set_type_error_with_name
    call set_type_error_with_name       ; rax = 0
    pop rbx
    leave
    ret
END_FUNC staticmethod_call

;; ============================================================================
;; classmethod_construct(rdi = the class, rsi = args, rdx = nargs)
;;   -> rax = the wrapper, edx = TAG_PTR; (0, 0) with a TypeError pending
;; Fails: 0
;;
;; tp_new for classmethod_type.  The class is NOT always classmethod: see
;; descr_alloc above.
;; ============================================================================
global classmethod_construct
DEF_FUNC classmethod_construct, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx

    ; A SUBCLASS's arguments belong to its __init__, and CPython's __new__
    ; ignores what it cannot use rather than refusing them: `class Named(classmethod)`
    ; taking (f, label) reaches this first.  The exact type is strict, because
    ; nothing runs __init__ after it -- type_call's builtin shortcut is tp_new
    ; and nothing else.
    lea rax, [rel classmethod_type]
    cmp rdi, rax
    je .cm_exact
    xor ebx, ebx
    test rdx, rdx
    jz .cm_have
    mov rbx, [rsi]
    jmp .cm_have
.cm_exact:
    cmp rdx, 1
    jne .cm_error
    mov rbx, [rsi]              ; rbx = func (args[0])
.cm_have:

    ; rdi is still the class this was called on; nothing above touches it.
    lea rsi, [rel classmethod_type]
    mov edx, PyClassMethodObject_size
    call descr_alloc
    ; ob_refcnt=1, ob_type set
    mov [rax + PyClassMethodObject.cm_callable], rbx

    ; A VALUE, not a pointer: `classmethod(0)` is an ordinary call and
    ; obj_incref on a small integer's Value writes through the number.
    push rax
    mov rax, rbx
    INCREF_V rax, rcx
    mov rdi, [rsp]
    call gc_track
    pop rax

    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.cm_error:
    mov rsi, rdx
    CSTRING rdi, "classmethod expected 1 argument, got "
    xor edx, edx
    call set_type_error_counted
    RET_NULL
    pop rbx
    leave
    ret
END_FUNC classmethod_construct

;; ============================================================================
;; classmethod_dealloc(PyObject *self)
;; ============================================================================
DEF_FUNC_LOCAL classmethod_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyClassMethodObject.cm_callable]
    XDECREF_V rdi, rax

    mov rdi, rbx
    call gc_dealloc

    pop rbx
    leave
    ret
END_FUNC classmethod_dealloc

;; ============================================================================
;; property_construct(rdi = the class, rsi = args, rdx = nargs)
;;   -> rax = the property, edx = TAG_PTR; (0, 0) with a TypeError pending
;; Fails: 0
;;
;; tp_new for property_type: property(fget), property(fget, fset), or with
;; fdel and doc.  The class is NOT always property -- see descr_alloc above --
;; and unlike the other two this one makes calls before it allocates, so the
;; class goes in a frame slot rather than staying in rdi.
;; ============================================================================
PC_CLS   equ 8
PC_FRAME equ 16                 ; 16 + 4 pushes keeps rsp 16-aligned, and the
                                ; four collected arguments pushed below it
                                ; keep the parity
DEF_FUNC property_construct, PC_FRAME
    mov [rbp - PC_CLS], rdi
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rsi                ; args
    mov r12, rdx                ; nargs

    ; The four are positional-or-keyword in CPython, and property(gx,
    ; doc="D") is the common spelling.  Taken positionally, that string
    ; became FSET -- and a property whose setter is a str calls a str on
    ; assignment.  Collect the keywords into the same four slots first, then
    ; let the positionals fill what is left.
    push qword 0                ; [rsp + 24] = doc
    push qword 0                ; [rsp + 16] = fdel
    push qword 0                ; [rsp +  8] = fset
    push qword 0                ; [rsp     ] = fget

    ; A SUBCLASS's arguments belong to its __init__, exactly as they do for
    ; staticmethod and classmethod above -- and here it is not only leniency
    ; about how many: `class Named(property)` taking (fget, label) hit the
    ; keyword loop and was told property() has no argument called label.  So
    ; the four slots are left empty and the parse happens once, in
    ; property_method_init, which every subclass reaches because property's
    ; own __init__ is on the MRO.
    mov rax, [rbp - PC_CLS]
    lea rcx, [rel property_type]
    cmp rax, rcx
    jne .pc_pos_done

    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jz .pc_positional
    mov r13, [rax + PyTupleObject.ob_size]      ; n_kw
    mov r14, r12
    sub r14, r13                                ; n_pos
    xor ecx, ecx
.pc_kw_loop:
    cmp rcx, r13
    jge .pc_kw_done
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rdx, [rdx + rcx*8]                      ; the keyword's name
    mov rsi, r14
    add rsi, rcx
    mov rsi, [rbx + rsi*8]                      ; the value given for it
    lea rdi, [rdx + PyStrObject.data]

    push rax
    push rcx
    push rsi
    push rdi
    CSTRING rsi, "fget"
    call ap_strcmp
    test eax, eax
    jz .pc_kw_slot0
    mov rdi, [rsp]
    CSTRING rsi, "fset"
    call ap_strcmp
    test eax, eax
    jz .pc_kw_slot1
    mov rdi, [rsp]
    CSTRING rsi, "fdel"
    call ap_strcmp
    test eax, eax
    jz .pc_kw_slot2
    mov rdi, [rsp]
    CSTRING rsi, "doc"
    call ap_strcmp
    test eax, eax
    jnz .pc_kw_bad
    mov edx, 3
    jmp .pc_kw_store
.pc_kw_slot0:
    xor edx, edx
    jmp .pc_kw_store
.pc_kw_slot1:
    mov edx, 1
    jmp .pc_kw_store
.pc_kw_slot2:
    mov edx, 2
.pc_kw_store:
    mov rsi, [rsp + 8]                          ; the value
    mov [rsp + 32 + rdx*8], rsi                 ; past the four pushes
    pop rdi
    pop rsi
    pop rcx
    pop rax
    inc rcx
    jmp .pc_kw_loop
.pc_kw_bad:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    jmp .pc_kw_error
.pc_kw_done:
    mov r12, r14                                ; only the positionals remain
    mov qword [gs:ThreadState.kw_names_pending], 0

.pc_positional:
    cmp r12, 4
    ja .pc_error
    xor ecx, ecx
.pc_pos_loop:
    cmp rcx, r12
    jge .pc_pos_done
    mov rax, [rbx + rcx*8]
    cmp qword [rsp + rcx*8], 0
    jne .pc_dup_error
    mov [rsp + rcx*8], rax
    inc rcx
    jmp .pc_pos_loop
.pc_pos_done:

    mov r13, [rsp]              ; fget
    mov r14, [rsp + 8]          ; fset
    test r13, r13
    jnz .pc_alloc
    lea r13, [rel none_singleton]   ; property() with no getter is legal

.pc_alloc:
    ; doc and fdel, kept on the stack because rbx is about to become the new
    ; property and the argument array would be lost with it.
    mov rax, [rsp + 24]
    push rax                    ; doc
    mov rax, [rsp + 24]         ; fdel, now one slot deeper
    push rax

.pc_do_alloc:
    ; None means "no accessor", and CPython normalises it to NULL right here
    ; (property_init_impl).  Storing the singleton instead made
    ; `property(None, f)` look like it HAD a getter, and reading the attribute
    ; called None: "TypeError: 'NoneType' object is not callable" where
    ; CPython raises AttributeError.  Doing it at the constructor fixes every
    ; reader at once, and .pga_fget already maps NULL back to None.
    lea rax, [rel none_singleton]
    cmp r13, rax
    jne .pc_get_ok
    xor r13d, r13d
.pc_get_ok:
    cmp r14, rax
    jne .pc_set_ok
    xor r14d, r14d
.pc_set_ok:

    mov rdi, [rbp - PC_CLS]
    lea rsi, [rel property_type]
    mov edx, PyPropertyObject_size
    call descr_alloc
    mov rbx, rax                ; rbx = new property (ob_refcnt=1, ob_type set)
    mov [rbx + PyPropertyObject.prop_get], r13
    mov [rbx + PyPropertyObject.prop_set], r14
    pop rax                     ; fdel
    push rcx
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    jne .pc_del_ok
    xor eax, eax
.pc_del_ok:
    pop rcx
    mov [rbx + PyPropertyObject.prop_del], rax
    pop rax                     ; doc
    mov [rbx + PyPropertyObject.prop_doc], rax
    ; Filled in by __set_name__ when the class body is built; a property that
    ; never reaches a class body keeps NULL and falls back to CPython's
    ; unnamed wording.
    mov qword [rbx + PyPropertyObject.prop_name], 0

    ; All four are Values, not pointers.  CPython takes any object for each --
    ; property(f, None, None, 5).__doc__ is 5, and f.__doc__ may be an int --
    ; so an INCREF that dereferences is a segfault on an immediate.
    mov rdi, r13
    INCREF_V rdi, rax

    test r14, r14
    jz .pc_no_fset
    mov rdi, r14
    INCREF_V rdi, rax
.pc_no_fset:

    mov rdi, [rbx + PyPropertyObject.prop_del]
    test rdi, rdi
    jz .pc_no_fdel
    INCREF_V rdi, rax
.pc_no_fdel:

    ; __doc__: the explicit one if given, else fget's own -- which is what
    ; CPython copies, so that help() on a property says something.
    mov rdi, [rbx + PyPropertyObject.prop_doc]
    test rdi, rdi
    jz .pc_doc_from_fget
    INCREF_V rdi, rax
    jmp .pc_doc_done

.pc_doc_from_fget:
    mov rdi, r13
    test rdi, rdi
    jz .pc_doc_done
    V_TEST_PTR rdi, rax
    ja .pc_doc_done
    lea rdi, [rel pc_doc_name]
    extern dunder_name_obj
    call dunder_name_obj
    mov rsi, rax
    mov rdi, r13
    extern obj_getattr_opt
    call obj_getattr_opt
    test rax, rax
    jz .pc_doc_done
    ; obj_getattr_opt hands back a new reference; the property keeps it.
    mov [rbx + PyPropertyObject.prop_doc], rax
.pc_doc_done:

    mov rdi, rbx
    call gc_track

    mov rax, rbx
    mov edx, TAG_PTR

    add rsp, 32                 ; the four collected arguments
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.pc_error:
    mov rsi, r12
    CSTRING rdx, " given)"
    CSTRING rdi, "property() takes at most 4 arguments ("
    call set_type_error_counted
    jmp .pc_fail

.pc_dup_error:
    FAIL exc_TypeError_type, "property() got multiple values for an argument", .pc_fail

.pc_kw_error:
    SET_EXC exc_TypeError_type, "property() got an unexpected keyword argument"
.pc_fail:
    ; Reached with the four collected arguments on the stack, and from the
    ; keyword loop with its own four above them: cut back to the saved
    ; registers rather than count.
    RET_NULL
    lea rsp, [rbp - PC_FRAME - 32]
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC property_construct

;; ============================================================================
;; property_dunder_set_name(args, nargs) -> None, always
;;   args[0] = the property, args[1] = the owner class, args[2] = the name
;;
;; CPython's property.__set_name__.  It exists for one purpose: to let the
;; AttributeError name the attribute.  "property 'r' of 'Plain' object has no
;; setter" needs the name, and a descriptor is not told its own name anywhere
;; else -- the class body assigns it into a dict and nothing hands it down.
;;
;; A property that never reaches a class body -- one built and called by hand
;; -- keeps a NULL name and falls back to CPython's unnamed wording.
;; ============================================================================
PSN_NAME  equ 8          ; the name, held across the release below
PSN_PROP  equ 16         ; and the property, for the same reason
PSN_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC property_dunder_set_name, PSN_FRAME
    cmp rsi, 3
    jb .psn_done
    mov rax, [rdi]              ; the property
    mov rdx, [rdi + 16]         ; the name Value (one Value per slot)
    ; The name goes in the FRAME before anything is released.  It was held in
    ; rdx across the obj_decref below, and rdx is caller-saved: a release that
    ; reached zero ran obj_dealloc, which destroys it, and the garbage left
    ; behind was then classified and dereferenced.
    mov [rbp - PSN_NAME], rdx
    ; Only a str, and only once: a re-assignment under a second name would
    ; otherwise leak the first.
    mov rdi, [rax + PyPropertyObject.prop_name]
    test rdi, rdi
    jz .psn_no_old
    mov [rbp - PSN_PROP], rax
    call obj_decref
    mov rax, [rbp - PSN_PROP]
.psn_no_old:
    mov rdx, [rbp - PSN_NAME]
    mov qword [rax + PyPropertyObject.prop_name], 0
    V_TEST_PTR rdx, rcx         ; ja when NULL or an immediate
    ja .psn_done
    mov rcx, [rdx + PyObject.ob_type]
    lea rdi, [rel str_type]
    cmp rcx, rdi
    jne .psn_done
    mov [rax + PyPropertyObject.prop_name], rdx
    mov rdi, rdx
    call obj_incref
.psn_done:
    xor eax, eax
    RET_NONE
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC property_dunder_set_name

;; ============================================================================
;; property_set_no_accessor(rdi = the property, rsi = the receiver Value,
;;                          rdx = "setter"/"deleter"/"getter")
;;   -> rax = 0, always, with the AttributeError pending
;;
;; "property 'r' of 'Plain' object has no setter", which is 3.12's wording.
;; The old message was 3.10's bare "can't set attribute" and named neither.
;; Falls back to CPython's own unnamed form when __set_name__ never ran.
;; ============================================================================
PRN_RECV equ 8
PRN_WHAT equ 16
PRN_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC property_set_no_accessor, PRN_FRAME
    push rbx
    mov [rbp - PRN_RECV], rsi
    mov [rbp - PRN_WHAT], rdx
    mov rbx, [rdi + PyPropertyObject.prop_name]

    TS_LEA rdi, ts_errbuf
    test rbx, rbx
    jz .prn_unnamed
    lea rsi, [rel prop_msg_open]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rbx + PyStrObject.data]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel prop_msg_of]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - PRN_RECV]
    call rbt_typename
    mov rdi, rax
    lea rsi, [rel prop_msg_has_no]
    call rbt_append_cstr
    jmp .prn_what
.prn_unnamed:
    lea rsi, [rel prop_msg_anon]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - PRN_RECV]
    call rbt_typename
    mov rdi, rax
    lea rsi, [rel prop_msg_has_no]
    call rbt_append_cstr
.prn_what:
    mov rdi, rax
    mov rsi, [rbp - PRN_WHAT]
    call rbt_append_cstr
    lea rdi, [rel exc_AttributeError_type]
    TS_LEA rsi, ts_errbuf
    call set_exception
    pop rbx
    leave
    ret
END_FUNC property_set_no_accessor

section .rodata
prop_msg_open:   db "property '", 0
prop_msg_of:     db "' of '", 0
prop_msg_anon:   db "property of '", 0
prop_msg_has_no: db "' object has no ", 0
prop_msg_setter: db "setter", 0
prop_msg_deleter: db "deleter", 0
prop_msg_getter: db "getter", 0

section .bss
prop_msg_buf: resb 256


section .text

;; ============================================================================
;; property_dealloc(PyObject *self)
;; ============================================================================
DEF_FUNC_LOCAL property_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyPropertyObject.prop_get]
    test rdi, rdi
    jz .pd_no_get
    DECREF_V rdi, rcx
.pd_no_get:
    mov rdi, [rbx + PyPropertyObject.prop_set]
    test rdi, rdi
    jz .pd_no_set
    DECREF_V rdi, rcx
.pd_no_set:
    mov rdi, [rbx + PyPropertyObject.prop_del]
    test rdi, rdi
    jz .pd_no_del
    DECREF_V rdi, rcx
.pd_no_del:
    mov rdi, [rbx + PyPropertyObject.prop_doc]
    test rdi, rdi
    jz .pd_no_doc
    DECREF_V rdi, rcx
.pd_no_doc:
    mov rdi, [rbx + PyPropertyObject.prop_name]
    test rdi, rdi
    jz .pd_no_name
    call obj_decref
.pd_no_name:

    mov rdi, rbx
    call gc_dealloc

    pop rbx
    leave
    ret
END_FUNC property_dealloc

;; ============================================================================
;; property_descr_get(PyPropertyObject *prop, PyObject *obj) -> PyObject*
;; Called by LOAD_ATTR when a property is found in the type dict.
;; Invokes prop.fget(obj). Returns result (owned ref), as the (rax, edx) pair;
;; (0, 0) with the exception pending when the getter raised or there is none.
;; Fails: 0
;; ============================================================================
DEF_FUNC property_descr_get
    push rbx
    push r12

    mov rbx, rdi                ; property
    mov r12, rsi                ; obj

    mov rax, [rbx + PyPropertyObject.prop_get]
    test rax, rax
    jz .pdg_no_getter

    ; fget(obj), through the general call path.  Reaching for tp_call directly
    ; missed a getter that is an instance of a class defining __call__ -- an
    ; operator.itemgetter, say, which is exactly what collections.namedtuple
    ; builds its fields from -- and reported it as an unreadable attribute.
    SPUSH_PTR r12               ; args[0] = obj
    mov rdi, rax
    mov rsi, rsp
    mov edx, 1
    call obj_call_n             ; err: 0 goes to the caller as it stands
    add rsp, 16
    V_UNPACK rax, rdx           ; the pair the callers of this expect

    pop r12
    pop rbx
    leave
    ret

.pdg_no_getter:
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rel prop_msg_getter]
    call property_set_no_accessor
    RET_NULL
    pop r12
    pop rbx
    leave
    ret
END_FUNC property_descr_get

;; ============================================================================
;; property_descr_set(PyPropertyObject *prop, PyObject *obj, PyObject *value)
;;   -> rax = 0, or -1 with the exception pending
;; Called by STORE_ATTR when a property is found in the type dict.
;; Invokes prop.fset(obj, value), or fdel(obj) for a NULL value.
;; Fails: -1
;; ============================================================================
DEF_FUNC property_descr_set
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi                ; property
    mov r12, rsi                ; obj
    mov r13, rdx                ; value Value

    ; A NULL value is `del obj.attr`, and that is the DELETER's business.
    ; Without this arm it reached fset with a NULL Value, so `del d.v` ran the
    ; setter with nothing and the deleter never ran at all.
    test r13, r13
    jz .pds_delete

    mov rax, [rbx + PyPropertyObject.prop_set]
    test rax, rax
    jz .pds_no_setter

    ; Call fset(obj, value): fset.tp_call(fset, args, 2)
    mov rdi, rax
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .pds_no_setter

    ; Build the args array on the stack: [obj, value]
    sub rsp, 16
    mov [rsp], r12              ; args[0] = obj
    mov [rsp + 8], r13          ; args[1] = value (already a Value)
    mov rsi, rsp                ; args ptr
    mov edx, 2                  ; nargs = 2
    call rax
    add rsp, 16                 ; pop args
    ERR_NULL .pds_failed
    DECREF_V rax, rdx           ; fset's None
    xor eax, eax

.pds_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.pds_delete:
    mov rax, [rbx + PyPropertyObject.prop_del]
    test rax, rax
    jz .pds_no_deleter
    mov rdi, rax
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .pds_no_deleter
    sub rsp, 16
    mov [rsp], r12              ; args[0] = obj
    mov rsi, rsp
    mov edx, 1
    call rax
    add rsp, 16
    ERR_NULL .pds_failed
    DECREF_V rax, rdx
    xor eax, eax
    jmp .pds_done
.pds_failed:
    mov rax, -1                 ; the setter raised
    jmp .pds_done

.pds_no_deleter:
    lea rdx, [rel prop_msg_deleter]
    jmp .pds_refuse
.pds_no_setter:
    lea rdx, [rel prop_msg_setter]
.pds_refuse:
    mov rdi, rbx
    mov rsi, r12
    call property_set_no_accessor
    jmp .pds_failed
END_FUNC property_descr_set

;; ============================================================================
;; member_descr_new(i64 offset, PyStrObject *name) -> PyMemberDescrObject*
;; Create a member descriptor for a __slots__ slot.
;; rdi = byte offset in instance, rsi = slot name (INCREF'd, ownership taken),
;; rdx = the class it belongs to, borrowed -- the type owns the dict that owns
;; this, and only the repr reads it.
;; ============================================================================
DEF_FUNC member_descr_new, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    mov rbx, rdi            ; offset
    mov r12, rsi            ; name str
    mov r13, rdx            ; the owning class

    mov edi, PyMemberDescrObject_size
    call ap_malloc

    INIT_OBJ_RC rax
    lea rcx, [rel member_descr_type]
    mov [rax + PyMemberDescrObject.ob_type], rcx
    mov [rax + PyMemberDescrObject.md_offset], rbx
    mov [rax + PyMemberDescrObject.md_name], r12
    mov [rax + PyMemberDescrObject.md_owner], r13
    mov qword [rax + PyMemberDescrObject.md_nullable], 0

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC member_descr_new

;; ============================================================================
;; member_descr_repr(rdi = the descriptor) -> "<member 'x' of 'S' objects>"
;;
;; CPython's wording, and the same shape a method descriptor's repr has.  It
;; used to fall through to object's, which prints the type and an address and
;; says neither which slot nor whose.
;; ============================================================================
MDR_BUF   equ 272
MDR_FRAME equ 296            ; + 1 push = 304, 16-aligned
DEF_FUNC_LOCAL member_descr_repr, MDR_FRAME
    push rbx
    mov rbx, rdi
    lea rdi, [rbp - MDR_BUF]
    CSTRING rsi, "<member '"
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbx + PyMemberDescrObject.md_name]
    test rsi, rsi
    jz .mdr_no_name
    add rsi, PyStrObject.data
    call rbt_append_cstr
.mdr_no_name:
    mov rdi, rax
    CSTRING rsi, "' of '"
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbx + PyMemberDescrObject.md_owner]
    test rsi, rsi
    jz .mdr_no_owner
    mov rsi, [rsi + PyTypeObject.tp_name]
    call rbt_append_cstr
.mdr_no_owner:
    mov rdi, rax
    CSTRING rsi, "' objects>"
    call rbt_append_cstr
    lea rdi, [rbp - MDR_BUF]
    extern str_from_cstr
    call str_from_cstr
    pop rbx
    leave
    ret
END_FUNC member_descr_repr

;; member_descr_dealloc(PyMemberDescrObject *self)
DEF_FUNC member_descr_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; DECREF name string
    mov rdi, [rbx + PyMemberDescrObject.md_name]
    test rdi, rdi
    jz .md_no_name
    call obj_decref
.md_no_name:

    ; Free self
    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC member_descr_dealloc

;; ============================================================================
;; Data section
;; ============================================================================
;; ============================================================================
;; mappingproxy -- a read-only window onto a dict.
;;
;; type.__dict__ is one in CPython, and types.py does
;; `MappingProxyType = type(type.__dict__)`, so the type has to exist and be
;; distinct from dict before anything downstream of types.py can import.
;; Reads delegate to the wrapped dict; there is no write path.
;; ============================================================================
extern dict_get
extern str_new_heap
extern obj_repr
extern obj_incref
;; ============================================================================
;; mappingproxy_construct(PyObject *type, PyObject **args, int64_t nargs)
;; tp_new for mappingproxy_type: MappingProxyType(mapping).
;;
;; The type existed only to be *named* by types.py, so it had no constructor at
;; all -- and calling it fell through to the ordinary class-construction path,
;; which allocated a proxy-sized block and left mp_mapping holding whatever was
;; there.  enum's `__members__` is a MappingProxyType(...) call.  It goes in
;; tp_new, not tp_call: tp_call on a type is what makes that type's *instances*
;; callable.
;;   -> (rax = the proxy, edx = TAG_PTR), or (0, 0) with a TypeError pending
;; Fails: 0
;; ============================================================================
extern type_is_subtype
MPC_ARG   equ 8             ; the argument, kept across type_is_subtype
MPC_FRAME equ 16            ; + 0 pushes = 16, and a call needs 8 more
DEF_FUNC mappingproxy_construct, MPC_FRAME
    cmp rdx, 1
    jne .mpc_arity
    mov rdi, [rsi]                  ; the mapping
    mov [rbp - MPC_ARG], rdi
    V_TEST_PTR rdi, rax
    ja .mpc_error
    test rdi, rdi
    jz .mpc_error
    mov rax, [rdi + PyObject.ob_type]
    ; A proxy of a proxy wraps the same dict, as CPython's does.
    lea rcx, [rel mappingproxy_type]
    cmp rax, rcx
    je .mpc_unwrap
    ; A dict SUBCLASS is a dict: `ob_type is dict_type` refused OrderedDict,
    ; which is what stopped inspect.signature.  A subtype test and not a
    ; protocol probe, because the slots below reach real dict internals.
    mov rdi, rax
    lea rsi, [rel dict_type]
    call type_is_subtype
    test eax, eax
    jz .mpc_error
    mov rdi, [rbp - MPC_ARG]
    jmp .mpc_wrap
.mpc_unwrap:
    mov rdi, [rdi + PyMappingProxyObject.mp_mapping]
.mpc_wrap:
    call mappingproxy_new
    mov edx, TAG_PTR            ; a constructor returns the (payload, tag) pair
    leave
    ret
.mpc_error:
    mov rsi, [rbp - MPC_ARG]
    CSTRING rdi, `mappingproxy() argument must be a mapping, not \x01`
    call set_type_error_with_name
    jmp .mpc_fail
.mpc_arity:
    SET_EXC exc_TypeError_type, "mappingproxy() argument must be a mapping, not a sequence"
.mpc_fail:
    RET_NULL
    leave
    ret
END_FUNC mappingproxy_construct

DEF_FUNC mappingproxy_new, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi                    ; the dict
    mov edi, PyMappingProxyObject_size
    call ap_malloc
    INIT_OBJ_RC rax
    lea rcx, [rel mappingproxy_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyMappingProxyObject.mp_mapping], rbx
    push rax
    mov rdi, rbx
    call obj_incref
    pop rax
    pop rbx
    leave
    ret
END_FUNC mappingproxy_new

DEF_FUNC_LOCAL mappingproxy_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyMappingProxyObject.mp_mapping]
    test rdi, rdi
    jz .mpd_free
    call obj_decref
.mpd_free:
    mov rdi, rbx
    call ap_free
    pop rbx
    leave
    ret
END_FUNC mappingproxy_dealloc

; Everything below just forwards to the wrapped dict.
DEF_FUNC_BARE mappingproxy_subscript
    mov rdi, [rdi + PyMappingProxyObject.mp_mapping]
    extern dict_subscript
    jmp dict_subscript
END_FUNC mappingproxy_subscript

DEF_FUNC_BARE mappingproxy_len
    mov rdi, [rdi + PyMappingProxyObject.mp_mapping]
    extern dict_len
    jmp dict_len
END_FUNC mappingproxy_len

DEF_FUNC_BARE mappingproxy_contains
    mov rdi, [rdi + PyMappingProxyObject.mp_mapping]
    extern dict_contains
    jmp dict_contains
END_FUNC mappingproxy_contains

DEF_FUNC_BARE mappingproxy_iter
    mov rdi, [rdi + PyMappingProxyObject.mp_mapping]
    extern dict_tp_iter
    jmp dict_tp_iter
END_FUNC mappingproxy_iter

DEF_FUNC_BARE mappingproxy_repr
    mov rdi, [rdi + PyMappingProxyObject.mp_mapping]
    extern dict_repr
    jmp dict_repr
END_FUNC mappingproxy_repr

MPG_MAP   equ 8
MPG_NAME  equ 16
MPG_PTR   equ 24
MPG_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC mappingproxy_getattr, MPG_FRAME
    ; A proxy is read-only, so the methods that would write through it are
    ; refused before the wrapped dict is consulted.  Without this, giving dict
    ; a __setitem__ method made `C.__dict__.__setitem__(k, v)` quietly mutate
    ; the class.
    mov [rbp - MPG_MAP], rdi
    mov [rbp - MPG_NAME], rsi
    lea rax, [rel mpg_readonly_names]
    mov [rbp - MPG_PTR], rax
.mpg_deny_loop:
    mov rax, [rbp - MPG_PTR]
    mov rsi, [rax]
    test rsi, rsi
    jz .mpg_allowed
    add qword [rbp - MPG_PTR], 8
    mov rdi, [rbp - MPG_NAME]
    add rdi, PyStrObject.data
    extern ap_strcmp
    call ap_strcmp
    test eax, eax
    jnz .mpg_deny_loop
    xor eax, eax
    xor edx, edx
    leave
    ret

.mpg_allowed:
    mov rdi, [rbp - MPG_MAP]
    mov rsi, [rbp - MPG_NAME]
    ; keys/values/items/get and the rest live on the wrapped dict
    mov rdi, [rdi + PyMappingProxyObject.mp_mapping]
    extern dict_type
    mov rax, [rel dict_type + PyTypeObject.tp_dict]
    test rax, rax
    jz .mpg_none
    push rdi
    mov rdi, rax
    call dict_get_mro
    V_UNPACK rax, rdx
    pop rdi
    test edx, edx
    jz .mpg_none
    ; bind it to the wrapped dict, so proxy.keys() reads the dict
    extern method_new
    push rax                    ; save owned func from dict_get_mro
    mov rsi, rdi
    mov rdi, rax
    call method_new
    pop rdi
    push rax
    call obj_decref
    pop rax
    mov edx, TAG_PTR
    leave
    ret
.mpg_none:
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC mappingproxy_getattr


;; ============================================================================
;; getset_descr_new(rdi = getter, rsi = setter, rdx = name str) -> descriptor
;; A named pair of C accessors, stored in a type's dict.  This is how CPython
;; exposes func.__code__ and the co_* fields, and types.py takes
;; GetSetDescriptorType straight off one of them.
;; ============================================================================
DEF_FUNC getset_descr_new, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov edi, PyGetSetDescrObject_size
    call ap_malloc
    INIT_OBJ_RC rax
    lea rcx, [rel getset_descr_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyGetSetDescrObject.gs_get], rbx
    mov [rax + PyGetSetDescrObject.gs_set], r12
    mov [rax + PyGetSetDescrObject.gs_name], r13
    mov qword [rax + PyGetSetDescrObject.gs_owner], 0
    mov qword [rax + PyGetSetDescrObject.gs_flags], 0
    ; gs_name is owned -- getset_descr_dealloc decrefs it -- and was stored
    ; without a reference of its own.  Harmless while the one instance ever
    ; built was immortal; not once every numeric type registers several.
    push rax
    mov rdi, r13
    call obj_incref
    pop rax
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC getset_descr_new

;; ============================================================================
;; getset_descr_getattr(rdi = the descriptor, rsi = name str) -> Value, or 0
;;
;; __name__, __qualname__ and __objclass__, which is what a descriptor is
;; asked for once it has been fished out of a type's dict by name.  inspect's
;; _shadowed_dict reads `class_dict.__name__ == "__dict__"` off exactly this
;; object, and an AttributeError there stopped pydoc, pstats and everything
;; through them.
;; ============================================================================
GDA_SELF  equ 8
GDA_FRAME equ 16            ; + 0 pushes = 16
DEF_FUNC_LOCAL getset_descr_getattr, GDA_FRAME
    mov [rbp - GDA_SELF], rdi
    test rsi, rsi
    jz .gda_miss
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .gda_miss

    lea rdi, [rsi + PyStrObject.data]
    push rsi
    CSTRING rsi, "__name__"
    call ap_strcmp
    pop rsi
    test eax, eax
    jz .gda_name

    lea rdi, [rsi + PyStrObject.data]
    push rsi
    CSTRING rsi, "__qualname__"
    call ap_strcmp
    pop rsi
    test eax, eax
    jz .gda_qualname

    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "__objclass__"
    call ap_strcmp
    test eax, eax
    jz .gda_objclass
.gda_miss:
    xor eax, eax
    xor edx, edx
    leave
    ret

.gda_name:
    mov rax, [rbp - GDA_SELF]
    mov rax, [rax + PyGetSetDescrObject.gs_name]
    test rax, rax
    jz .gda_miss
    mov rdi, rax
    push rax
    call obj_incref
    pop rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.gda_qualname:
    ; "type.__mro__": the owning type's name, then the attribute's.
    mov rax, [rbp - GDA_SELF]
    mov rcx, [rax + PyGetSetDescrObject.gs_owner]
    test rcx, rcx
    jz .gda_name
    mov rax, [rax + PyGetSetDescrObject.gs_name]
    test rax, rax
    jz .gda_miss
    TS_LEA rdi, ts_errbuf
    mov rsi, [rcx + PyTypeObject.tp_name]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "."
    call rbt_append_cstr
    mov rdi, rax
    mov rcx, [rbp - GDA_SELF]
    mov rsi, [rcx + PyGetSetDescrObject.gs_name]
    lea rsi, [rsi + PyStrObject.data]
    call rbt_append_cstr
    TS_LEA rdi, ts_errbuf
    call str_from_cstr
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.gda_objclass:
    mov rax, [rbp - GDA_SELF]
    mov rax, [rax + PyGetSetDescrObject.gs_owner]
    test rax, rax
    jz .gda_miss
    mov rdi, rax
    push rax
    call obj_incref
    pop rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
END_FUNC getset_descr_getattr

section .bss
gda_buf: resb 320
extern bool_false
extern bool_true
extern none_type
extern obj_hash
extern union_getattr
extern union_hash
extern union_repr
extern union_richcompare
extern union_type_or
section .text

;; ============================================================================
;; getset_descr_repr(rdi = the descriptor) -> PyStrObject*
;;
;; "<attribute 'real' of 'int' objects>", as CPython words it.  tp_repr was 0,
;; so obj_repr fell to its no-repr arm and repr(int.real) was the empty
;; string -- and the stdlib reads a descriptor's repr to classify it.
;; ============================================================================
global getset_descr_repr
extern rbt_append_cstr
extern str_from_cstr
DEF_FUNC getset_descr_repr
    mov rsi, rdi
    lea rdi, [rel gdr_open]
    xor edx, edx
    call getset_descr_compose
    mov rdi, rax                ; the NUL the composer left
    lea rsi, [rel gdr_close]
    call rbt_append_cstr
    TS_LEA rdi, ts_errbuf
    call str_from_cstr
    leave
    ret
END_FUNC getset_descr_repr

;; ============================================================================
;; getset_descr_dunder_get(args, nargs) -- descriptor.__get__(obj[, type])
;; getset_descr_dunder_set(args, nargs) -- descriptor.__set__(obj, value)
;;
;; The stdlib decides what a descriptor IS by asking for these by name:
;; inspect.isdatadescriptor, and the enum and dataclasses classifiers, walk a
;; __dict__ and test hasattr(v, '__get__').  With no tp_dict on the type, the
;; answer was False for every getset in the tree.
;;   -> rax = a Value, or 0 with the exception pending
;; Fails: 0
;; ============================================================================
global getset_descr_dunder_get
DEF_FUNC getset_descr_dunder_get
    cmp rsi, 2
    jl .gdg_bad
    cmp rsi, 3
    jg .gdg_bad
    mov rax, [rdi]              ; args[0] = the descriptor
    mov rsi, [rdi + 8]          ; args[1] = the instance
    ; descr.__get__(None, cls) answers the descriptor itself, as CPython's does
    IS_NONE rsi, rcx
    je .gdg_self
    mov rdi, rax
    call getset_descr_get       ; err: its 0 is this __get__'s own
    leave
    ret
.gdg_self:
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.gdg_bad:
    SET_EXC exc_TypeError_type, "expected 1 or 2 arguments"
    leave
    ret
END_FUNC getset_descr_dunder_get

global getset_descr_dunder_set
DEF_FUNC getset_descr_dunder_set
    cmp rsi, 3
    jne .gds_bad
    mov rax, [rdi]
    mov rsi, [rdi + 8]
    mov rdx, [rdi + 16]
    mov rdi, rax
    call getset_descr_set
    ERR_M1 .gds_fail
    extern none_singleton
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.gds_bad:
    SET_EXC exc_TypeError_type, "expected 2 arguments"
.gds_fail:
    xor eax, eax
    leave
    ret
END_FUNC getset_descr_dunder_set

;; getset_descr_dunder_delete(args, nargs) -- descriptor.__delete__(obj)
;; A getset is a DATA descriptor whether or not it has a setter, so all three
;; names exist; a read-only one refuses when either is called.
;;   -> rax = None, or 0 with the exception pending
;; Fails: 0
global getset_descr_dunder_delete
DEF_FUNC getset_descr_dunder_delete
    cmp rsi, 2
    jne .gdd_bad
    mov rax, [rdi]
    mov rsi, [rdi + 8]
    xor edx, edx                ; a NULL Value: delete rather than assign
    mov rdi, rax
    call getset_descr_set
    ERR_M1 .gdd_fail
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.gdd_bad:
    SET_EXC exc_TypeError_type, "expected 1 argument"
.gdd_fail:
    xor eax, eax
    leave
    ret
END_FUNC getset_descr_dunder_delete

;; ============================================================================
;; getset_descr_compose(rdi = a leading C string, rsi = the descriptor)
;;   -> rax = the address of the NUL in gdr_buf, which holds
;;      "<lead>'name' of 'T' objects" -- a caller appends its own ending
;;
;; The middle the repr and the not-writable message share.
;; ============================================================================
DEF_FUNC_LOCAL getset_descr_compose, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    mov rbx, rsi
    mov r12, rdi
    mov r13, rdx                ; 1 = say "for" where the others say "of"
    TS_LEA rdi, ts_errbuf
    mov rsi, r12
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbx + PyGetSetDescrObject.gs_name]
    test rsi, rsi
    jz .gdc_no_name
    add rsi, PyStrObject.data
    jmp .gdc_have_name
.gdc_no_name:
    lea rsi, [rel gdr_unknown]
.gdc_have_name:
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel gdr_of]
    test r13, r13
    jz .gdc_joiner
    lea rsi, [rel gdr_for]
.gdc_joiner:
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbx + PyGetSetDescrObject.gs_owner]
    test rsi, rsi
    jz .gdc_no_owner
    mov rsi, [rsi + PyTypeObject.tp_name]
    jmp .gdc_have_owner
.gdc_no_owner:
    lea rsi, [rel gdr_unknown]
.gdc_have_owner:
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel gdr_tail]
    call rbt_append_cstr        ; rax = the NUL, where a caller appends more
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC getset_descr_compose

section .rodata
gds_ro_open: db "attribute '", 0
gds_ro_tail: db " is not writable", 0
gdr_tail:    db "' objects", 0
section .bss
gdr_buf: resb 320
section .text

section .rodata
gdr_open:    db "<attribute '", 0
gdr_of:      db "' of '", 0
gdr_for:     db "' for '", 0
gdr_close:   db ">", 0
gdr_unknown: db "?", 0
section .text

;; ============================================================================
;; getset_descr_get(rdi = the descriptor, rsi = self Value) -> rax = Value
;;
;; Calls the C getter.  Until now nothing anywhere read gs_get: the type was a
;; stub built once so types.py could name GetSetDescriptorType, and .real and
;; .imag were four separate tp_getattr strcmp chains instead -- which answered
;; an instance and left `int.real` an AttributeError, because a chain is not a
;; thing a type's dict can hold.
;;
;; A NULL getter is a set-only attribute, which CPython reports as an
;; AttributeError naming it.  That, a receiver of the wrong type and a getter
;; that fails all answer 0 with the exception pending.
;; Fails: 0
;; ============================================================================
GDG_DESC  equ 8
GDG_SELF  equ 16
GDG_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC getset_descr_get, GDG_FRAME
    mov [rbp - GDG_DESC], rdi
    mov [rbp - GDG_SELF], rsi
    call getset_check_receiver  ; clobbers both argument registers
    ERR_NULL .gdg_out
    mov rdi, [rbp - GDG_DESC]
    mov rsi, [rbp - GDG_SELF]
    mov rax, [rdi + PyGetSetDescrObject.gs_get]
    test rax, rax
    jz .gdg_unreadable
    test qword [rdi + PyGetSetDescrObject.gs_flags], GS_NAMED
    jnz .gdg_named
    mov rdi, rsi
    call rax
    leave
    ret
.gdg_named:
    ; A whole tp_getattr, called the way the slot calls it.  It answers NULL
    ; for a name that is not its own, which cannot happen here -- the
    ; descriptor was registered under a name that function answers -- but a
    ; released memoryview answers NULL for every one of them, so the NULL is
    ; turned into the AttributeError the caller expects rather than passed on
    ; as a value.
    mov rdi, rsi
    mov rsi, [rbp - GDG_DESC]
    mov rsi, [rsi + PyGetSetDescrObject.gs_name]
    call rax
    test rax, rax
    jnz .gdg_out
    cmp qword [gs:ThreadState.current_exception], 0
    je .gdg_unreadable
.gdg_out:
    leave
    ret
.gdg_unreadable:
    SET_EXC exc_AttributeError_type, "attribute is not readable"
    leave
    ret
END_FUNC getset_descr_get

;; ============================================================================
;; getset_check_receiver(rdi = the descriptor, rsi = self Value)
;;   -> rax = 1, or 0 with a TypeError naming both types pending
;; Fails: 0
;;
;; The getters are C functions that dereference their argument as an instance
;; of the type the descriptor belongs to, so reaching one UNBOUND --
;; `slice.__dict__['start'].__get__(5)` -- handed an int immediate to
;; `mov rax, [rdi + PySliceObject.start]`.  builtin_func_call has had this
;; check for its own descriptors since they started carrying an owner; a
;; getset carries one too.
;; ============================================================================
GCR_DESC  equ 8
GCR_SELF  equ 16
GCR_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC_LOCAL getset_check_receiver, GCR_FRAME
    mov [rbp - GCR_DESC], rdi
    mov [rbp - GCR_SELF], rsi
    mov rax, [rdi + PyGetSetDescrObject.gs_owner]
    test rax, rax
    jz .gcr_ok                  ; no owner recorded: nothing to check against
    mov rdi, rsi
    extern value_type
    call value_type
    test rax, rax
    jz .gcr_bad
    mov rdi, rax
    mov rcx, [rbp - GCR_DESC]
    mov rsi, [rcx + PyGetSetDescrObject.gs_owner]
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jz .gcr_bad
.gcr_ok:
    mov eax, 1
    leave
    ret
.gcr_bad:
    ; CPython's wording for this one is "for 'T' objects", where the readonly
    ; and repr messages say "of".  getset_descr_compose ends with the shared
    ; tail, so the joining word is passed in.
    lea rdi, [rel gcr_open]
    mov rsi, [rbp - GCR_DESC]
    mov edx, 1                      ; "for", not "of"
    call getset_descr_compose
    mov rdi, rax
    lea rsi, [rel gcr_mid]
    call rbt_append_cstr
    ; The receiver's type name, worked out BEFORE the append point goes into
    ; rdi -- value_type takes rdi as well.
    push rax                    ; the append point
    sub rsp, 8
    mov rdi, [rbp - GCR_SELF]
    call value_type
    add rsp, 8
    pop rdi                     ; the append point
    test rax, rax
    jz .gcr_unknown
    mov rsi, [rax + PyTypeObject.tp_name]
    jmp .gcr_have
.gcr_unknown:
    lea rsi, [rel gdr_unknown]
.gcr_have:
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel gcr_tail]
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    TS_LEA rsi, ts_errbuf
    call set_exception          ; rax = 0
    leave
    ret
END_FUNC getset_check_receiver

;; ============================================================================
;; member_check_receiver(rdi = the descriptor, rsi = self Value)
;;   -> rax = 1, or 0 with a TypeError pending
;; Fails: 0
;;
;; A __slots__ descriptor is an OFFSET into an instance of the class it was
;; made for.  Nothing stops a program from putting one in another class's body
;; -- `class Sneaky: borrowed = Class.slot`, which CPython's own test_opcache
;; does on purpose -- and `o.borrowed = 42` then wrote at Class's offset into
;; a Sneaky, which has a different layout: a wild store rather than an error.
;; CPython's member_get and member_set both ask this first, and word the
;; refusal the way getset's does.
;; ============================================================================
MCR_DESC  equ 8
MCR_SELF  equ 16
MCR_FRAME equ 32            ; + 0 pushes = 32
global member_check_receiver
DEF_FUNC member_check_receiver, MCR_FRAME
    mov [rbp - MCR_DESC], rdi
    mov [rbp - MCR_SELF], rsi
    mov rcx, [rdi + PyMemberDescrObject.md_owner]
    test rcx, rcx
    jz .mcr_ok                  ; no owner recorded: nothing to check against
    mov rdi, rsi
    call value_type
    test rax, rax
    jz .mcr_bad
    mov rdi, rax
    mov rcx, [rbp - MCR_DESC]
    mov rsi, [rcx + PyMemberDescrObject.md_owner]
    call type_is_subtype
    test eax, eax
    jz .mcr_bad
.mcr_ok:
    mov eax, 1
    leave
    ret

.mcr_bad:
    TS_LEA rdi, ts_errbuf
    lea rsi, [rel gcr_open]
    call rbt_append_cstr
    mov rdi, rax
    mov rcx, [rbp - MCR_DESC]
    mov rsi, [rcx + PyMemberDescrObject.md_name]
    lea rsi, [rsi + PyStrObject.data]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel mcr_for]
    call rbt_append_cstr
    mov rdi, rax
    mov rcx, [rbp - MCR_DESC]
    mov rcx, [rcx + PyMemberDescrObject.md_owner]
    mov rsi, [rcx + PyTypeObject.tp_name]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel mcr_quote]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel gcr_mid]
    call rbt_append_cstr
    ; The receiver's type name, worked out BEFORE the append point goes into
    ; rdi -- value_type takes rdi as well.
    push rax
    sub rsp, 8
    mov rdi, [rbp - MCR_SELF]
    call value_type
    add rsp, 8
    pop rdi
    test rax, rax
    jz .mcr_unknown
    mov rsi, [rax + PyTypeObject.tp_name]
    jmp .mcr_have
.mcr_unknown:
    lea rsi, [rel gdr_unknown]
.mcr_have:
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel gcr_tail]
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    TS_LEA rsi, ts_errbuf
    call set_exception          ; rax = 0
    leave
    ret
END_FUNC member_check_receiver

;; ============================================================================
;; member_descr_get(rdi = the descriptor, rsi = the instance Value)
;;   -> rax = the slot's Value, owned; 0 with the exception pending when the
;;      slot has never been assigned or the receiver is of the wrong layout
;; Fails: 0
;;
;; The read half of a __slots__ descriptor, as a function rather than as five
;; lines inlined at each attribute-access site -- __get__ needs one to call.
;; ============================================================================
MDG_SELF  equ 8
MDG_RECV  equ 16
MDG_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
global member_descr_get
DEF_FUNC member_descr_get, MDG_FRAME
    mov [rbp - MDG_SELF], rdi
    mov [rbp - MDG_RECV], rsi
    call member_check_receiver  ; refuses when the layouts do not match
    ERR_NULL .mdg_fail

    mov rdi, [rbp - MDG_SELF]
    mov rsi, [rbp - MDG_RECV]
    mov rcx, [rdi + PyMemberDescrObject.md_offset]
    SLOT_ADDR rdx, rsi, rcx
    mov rax, [rdx]
    test rax, rax
    jz .mdg_unset
    INCREF_V rax, rdx
    leave
    ret

.mdg_unset:
    mov rcx, [rbp - MDG_SELF]
    cmp qword [rcx + PyMemberDescrObject.md_nullable], 0
    je .mdg_missing
    LOAD_NONE rax
    leave
    ret
.mdg_missing:
    ; CPython names the type and the attribute, exactly as an ordinary missing
    ; attribute does -- this is the same absence.
    mov rdi, [rbp - MDG_RECV]
    mov rcx, [rbp - MDG_SELF]
    mov rsi, [rcx + PyMemberDescrObject.md_name]
    extern set_no_attribute_store
    call set_no_attribute_store ; rax = 0
.mdg_fail:
    leave
    ret
END_FUNC member_descr_get

;; ============================================================================
;; member_descr_set(rdi = the descriptor, rsi = the instance Value,
;;                  rdx = the new Value, or 0 to DELETE)
;;   -> rax = 0, or -1 with the exception pending
;; Fails: -1
;;
;; The write half.  A delete of a slot that was never assigned is an
;; AttributeError naming the slot -- CPython's PyMember_SetOne for T_OBJECT_EX
;; -- where this used to store 0 over 0 and report success, so `del o.x`
;; twice worked and absence could not be told from presence.
;; ============================================================================
MDS_SELF  equ 8
MDS_RECV  equ 16
MDS_VAL   equ 24
MDS_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
global member_descr_set
DEF_FUNC member_descr_set, MDS_FRAME
    mov [rbp - MDS_SELF], rdi
    mov [rbp - MDS_RECV], rsi
    mov [rbp - MDS_VAL], rdx
    call member_check_receiver
    ERR_NULL .mds_fail

    mov rdi, [rbp - MDS_SELF]
    mov rsi, [rbp - MDS_RECV]
    mov rcx, [rdi + PyMemberDescrObject.md_offset]
    SLOT_ADDR rdx, rsi, rcx
    mov rax, [rdx]              ; the old Value
    mov rcx, [rbp - MDS_VAL]
    test rcx, rcx
    jnz .mds_store
    test rax, rax
    jnz .mds_store
    mov rdi, [rbp - MDS_SELF]
    cmp qword [rdi + PyMemberDescrObject.md_nullable], 0
    je .mds_unset               ; deleting an unset T_OBJECT_EX

.mds_store:
    ; The new value is counted BEFORE the old one is released: they may be the
    ; same object, and `o.x = o.x` would otherwise free it between the two.
    mov rdi, [rbp - MDS_VAL]
    INCREF_V rdi, rcx
    mov [rdx], rdi
    XDECREF_V rax, rcx
    xor eax, eax
    leave
    ret

.mds_unset:
    mov rcx, [rbp - MDS_SELF]
    mov rsi, [rcx + PyMemberDescrObject.md_name]
    lea rdi, [rel exc_AttributeError_type]
    lea rsi, [rsi + PyStrObject.data]
    extern exc_AttributeError_type
    call set_exception
.mds_fail:
    mov rax, -1
    leave
    ret
END_FUNC member_descr_set

;; ============================================================================
;; member_descr_getattr(rdi = the descriptor, rsi = the name str)
;;   -> rax = a Value, or 0 for a miss
;;
;; __name__, __qualname__ and __objclass__, the three a descriptor fished out
;; of a type's dict is asked for.  getset_descr_getattr is the same function
;; over the sibling type; the fields differ, so the two cannot be shared.
;; ============================================================================
MDA_SELF  equ 8
MDA_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL member_descr_getattr, MDA_FRAME
    mov [rbp - MDA_SELF], rdi
    test rsi, rsi
    jz .mda_miss
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .mda_miss

    lea rdi, [rsi + PyStrObject.data]
    push rsi
    CSTRING rsi, "__name__"
    call ap_strcmp
    pop rsi
    test eax, eax
    jz .mda_name

    lea rdi, [rsi + PyStrObject.data]
    push rsi
    CSTRING rsi, "__qualname__"
    call ap_strcmp
    pop rsi
    test eax, eax
    jz .mda_qualname

    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "__objclass__"
    call ap_strcmp
    test eax, eax
    jz .mda_objclass
.mda_miss:
    xor eax, eax
    xor edx, edx
    leave
    ret

.mda_name:
    mov rax, [rbp - MDA_SELF]
    mov rax, [rax + PyMemberDescrObject.md_name]
    test rax, rax
    jz .mda_miss
    mov rdi, rax
    push rax
    call obj_incref
    pop rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.mda_qualname:
    ; "C.x": the owning type's name, then the slot's.
    mov rax, [rbp - MDA_SELF]
    mov rcx, [rax + PyMemberDescrObject.md_owner]
    test rcx, rcx
    jz .mda_name
    mov rax, [rax + PyMemberDescrObject.md_name]
    test rax, rax
    jz .mda_miss
    TS_LEA rdi, ts_errbuf
    mov rsi, [rcx + PyTypeObject.tp_name]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "."
    call rbt_append_cstr
    mov rdi, rax
    mov rcx, [rbp - MDA_SELF]
    mov rsi, [rcx + PyMemberDescrObject.md_name]
    lea rsi, [rsi + PyStrObject.data]
    call rbt_append_cstr
    TS_LEA rdi, ts_errbuf
    call str_from_cstr
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.mda_objclass:
    mov rax, [rbp - MDA_SELF]
    mov rax, [rax + PyMemberDescrObject.md_owner]
    test rax, rax
    jz .mda_miss
    mov rdi, rax
    push rax
    call obj_incref
    pop rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
END_FUNC member_descr_getattr

;; ============================================================================
;; member_descr_dunder_get(rdi = args, rsi = nargs) -> rax = Value
;;
;; descr.__get__(obj[, type]), the first of the three by NAME.  A __slots__ descriptor worked through attribute access
;; and answered "'member_descriptor' object has no attribute '__get__'" to
;; every program that reached for the protocol itself -- which
;; inspect.getattr_static, inspect.isdatadescriptor and anything walking
;; type.__dict__ do.
;; Fails: 0
;; ============================================================================
global member_descr_dunder_get
DEF_FUNC member_descr_dunder_get
    cmp rsi, 2
    jl .mdg_bad
    cmp rsi, 3
    jg .mdg_bad
    mov rax, [rdi]              ; the descriptor
    mov rcx, rsi                ; the COUNT, read before rsi becomes the arg
    mov rsi, [rdi + 8]          ; the instance
    ; descr.__get__(None, cls) answers the descriptor itself; with no cls it
    ; is CPython's "__get__(None, None) is invalid".
    IS_NONE rsi, rdx
    jne .mdg_go
    cmp rcx, 3
    jl .mdg_none_none
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.mdg_go:
    mov rdi, rax
    call member_descr_get       ; err: its 0 is this __get__'s own
    leave
    ret
.mdg_none_none:
    SET_EXC exc_TypeError_type, "__get__(None, None) is invalid"
    leave
    ret
.mdg_bad:
    SET_EXC exc_TypeError_type, "expected 1 or 2 arguments"
    leave
    ret
END_FUNC member_descr_dunder_get

;; ============================================================================
;; member_descr_dunder_set(rdi = args, rsi = nargs) -> rax = None
;;
;; descr.__set__(obj, value).
;; Fails: 0
;; ============================================================================
global member_descr_dunder_set
DEF_FUNC member_descr_dunder_set
    cmp rsi, 3
    jne .mds_bad
    mov rax, [rdi]
    mov rsi, [rdi + 8]
    mov rdx, [rdi + 16]
    mov rdi, rax
    call member_descr_set
    ERR_M1 .mds_fail
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
.mds_bad:
    SET_EXC exc_TypeError_type, "expected 2 arguments"
.mds_fail:
    xor eax, eax
    leave
    ret
END_FUNC member_descr_dunder_set

;; ============================================================================
;; member_descr_dunder_delete(rdi = args, rsi = nargs) -> rax = None
;;
;; descr.__delete__(obj).  A __slots__ descriptor is a DATA descriptor
;; whether or not the slot has ever been assigned, so all three names exist.
;; Fails: 0
;; ============================================================================
global member_descr_dunder_delete
DEF_FUNC member_descr_dunder_delete
    cmp rsi, 2
    jne .mdd_bad
    mov rax, [rdi]
    mov rsi, [rdi + 8]
    xor edx, edx                ; a NULL Value: delete rather than assign
    mov rdi, rax
    call member_descr_set
    ERR_M1 .mdd_fail
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
.mdd_bad:
    SET_EXC exc_TypeError_type, "expected 1 argument"
.mdd_fail:
    xor eax, eax
    leave
    ret
END_FUNC member_descr_dunder_delete

section .rodata
mcr_for:   db "' for '", 0
mcr_quote: db "' objects", 0
gcr_open: db "descriptor '", 0
gcr_mid:  db " doesn't apply to a '", 0
gcr_tail: db "' object", 0
section .text

;; ============================================================================
;; getset_descr_set(rdi = the descriptor, rsi = self Value, rdx = value Value)
;;   -> rax = 0, or -1 with the exception pending
;; Fails: -1
;;
;; A NULL setter is a read-only attribute.  Every getset the tree registers
;; today has one, which is what makes `(5).real = 1` an AttributeError rather
;; than a silent instance attribute on a subclass.
;; ============================================================================
GDS_SELF  equ 8             ; the descriptor
GDS_RECV  equ 16
GDS_VALUE equ 24
GDS_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC getset_descr_set, GDS_FRAME
    mov [rbp - GDS_SELF], rdi
    mov [rbp - GDS_RECV], rsi
    mov [rbp - GDS_VALUE], rdx
    call getset_check_receiver  ; the setter dereferences it too
    ERR_NULL .gds_fail
    mov rdi, [rbp - GDS_SELF]
    mov rsi, [rbp - GDS_RECV]
    mov rdx, [rbp - GDS_VALUE]
    mov rax, [rdi + PyGetSetDescrObject.gs_set]
    test rax, rax
    jz .gds_readonly
    mov rdi, rsi
    mov rsi, rdx
    call rax
    leave
    ret
.gds_readonly:
    ; Now that the descriptor carries its name and its owner, it can say
    ; which attribute -- which is what CPython's message does.
    lea rdi, [rel gds_ro_open]
    mov rsi, [rbp - GDS_SELF]
    xor edx, edx
    call getset_descr_compose
    mov rdi, rax
    lea rsi, [rel gds_ro_tail]
    call rbt_append_cstr
    lea rdi, [rel exc_AttributeError_type]
    TS_LEA rsi, ts_errbuf
    call set_exception
.gds_fail:
    mov rax, -1
    leave
    ret
END_FUNC getset_descr_set

DEF_FUNC_LOCAL getset_descr_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyGetSetDescrObject.gs_name]
    test rdi, rdi
    jz .gsd_free
    call obj_decref
.gsd_free:
    mov rdi, rbx
    call ap_free
    pop rbx
    leave
    ret
END_FUNC getset_descr_dealloc

;; ============================================================================
;; The __new__ thunks for the four types in this file whose constructor lives
;; in tp_new and nowhere else.
;;
;; A builtin's constructor being a SLOT is not something Python can see: the
;; stdlib asks by name.  `super().__new__(cls, ...)` in a subclass resolves
;; along the MRO, finds no __new__ on the builtin, reaches object.__new__ and
;; is refused -- which is how `collections.abc.Callable[[int], int]` came to
;; be a TypeError, since _CallableGenericAlias is exactly that shape.  It is
;; also every copy.copy, copy.deepcopy and pickle of a subclass of one of
;; these, because the reduce protocol reconstructs through __new__.
;;
;; Each is `new_from_slot` with the owner named: the slot called is the
;; owner's, never the argument's, so a Python subclass that defines __new__
;; does not re-enter itself.
;; ============================================================================
extern new_from_slot

;; ============================================================================
;; staticmethod_dunder_new(args, nargs) -> Value    -- staticmethod.__new__
;; ============================================================================
DEF_FUNC staticmethod_dunder_new
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rel staticmethod_type]
    call new_from_slot          ; err: its 0 is this __new__'s own
    leave
    ret
END_FUNC staticmethod_dunder_new

;; ============================================================================
;; classmethod_dunder_new(args, nargs) -> Value    -- classmethod.__new__
;; ============================================================================
DEF_FUNC classmethod_dunder_new
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rel classmethod_type]
    call new_from_slot          ; err: its 0 is this __new__'s own
    leave
    ret
END_FUNC classmethod_dunder_new

;; ============================================================================
;; property_dunder_new(args, nargs) -> Value    -- property.__new__
;; ============================================================================
DEF_FUNC property_dunder_new
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rel property_type]
    call new_from_slot          ; err: its 0 is this __new__'s own
    leave
    ret
END_FUNC property_dunder_new

;; ============================================================================
;; mappingproxy_dunder_new(args, nargs) -> Value    -- mappingproxy.__new__
;; ============================================================================
DEF_FUNC mappingproxy_dunder_new
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rel mappingproxy_type]
    call new_from_slot          ; err: its 0 is this __new__'s own
    leave
    ret
END_FUNC mappingproxy_dunder_new



section .data

sm_name_str: db "staticmethod", 0
align 8
cm_name_str: db "classmethod", 0
prop_name_str: db "property", 0

;; ============================================================================
section .text

;; ============================================================================
;; func_dunder_get(args, nargs) -> Value
;; staticmethod_dunder_get(args, nargs) -> Value
;; classmethod_dunder_get(args, nargs) -> Value
;;
;; The binding LOAD_ATTR performs natively, exposed as `__get__` so that a
;; function answers hasattr(f, '__get__') the way CPython's does.  enum tells a
;; member from a method in a class body by exactly that question, so without
;; these every helper defined inside an Enum body became an enum member --
;; `Flag._member_names_` came out as ['_get_value'].
;;
;; args[0] is the descriptor, args[1] the instance (None through the class),
;; args[2] the owner type when given.
;; ============================================================================
extern none_singleton
DEF_FUNC func_dunder_get
    mov rax, [rdi]                      ; the function itself
    cmp rsi, 2
    jl .fdg_plain
    mov rdx, [rdi + 8]                  ; the instance
    lea rcx, [rel none_singleton]
    cmp rdx, rcx
    je .fdg_plain                       ; unbound access through the class
    test rdx, rdx
    jz .fdg_plain
    mov rdi, rax
    mov rsi, rdx
    call method_new
    leave
    ret
.fdg_plain:
    INCREF rax
    leave
    ret
END_FUNC func_dunder_get

DEF_FUNC staticmethod_dunder_get
    mov rax, [rdi]
    mov rax, [rax + PyStaticMethodObject.sm_callable]
    test rax, rax
    jz .smg_none
    INCREF rax
    leave
    ret
.smg_none:
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
END_FUNC staticmethod_dunder_get

DEF_FUNC classmethod_dunder_get, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, [rdi]
    mov rbx, [rbx + PyClassMethodObject.cm_callable]
    test rbx, rbx
    jz .cmg_none
    ; classmethod() takes anything, callable or not -- CPython's own test_descr
    ; builds classmethod(1) on purpose -- and a non-pointer cannot be bound:
    ; method_new would INCREF an immediate.  Hand it back as it is; calling
    ; what comes out is the same TypeError either way.
    V_TEST_PTR rbx, rax
    ja .cmg_plain

    ; With neither an instance nor an owner there is nothing to bind to, and
    ; the __get__ wrapper says so before the descriptor's own code runs --
    ; CPython's wrap_descr_get maps both Nones to NULL and refuses the pair.
    cmp rsi, 2
    jl .cmg_pair_ok             ; no instance argument at all
    mov rax, [rdi + 8]
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    jne .cmg_pair_ok
    cmp rsi, 3
    jl .cmg_bad_pair
    mov rax, [rdi + 16]
    cmp rax, rcx
    je .cmg_bad_pair
.cmg_pair_ok:

    ; The owner type, or the instance's type when only an instance is given.
    xor edx, edx
    cmp rsi, 3
    jl .cmg_from_inst
    mov rdx, [rdi + 16]
    lea rcx, [rel none_singleton]
    cmp rdx, rcx
    jne .cmg_have_owner
    xor edx, edx
.cmg_from_inst:
    cmp rsi, 2
    jl .cmg_plain
    mov rdx, [rdi + 8]
    lea rcx, [rel none_singleton]
    cmp rdx, rcx
    je .cmg_plain
    test rdx, rdx
    jz .cmg_plain
    ; The instance is a Value, not a pointer: `classmethod(f).__get__(0)`
    ; binds to int, and reading ob_type off the immediate dereferenced the
    ; NUMBER.  value_type is the one place that knows all three encodings.
    ; args is not needed past here -- rbx holds the callable -- so rdi is
    ; free to carry the argument.
    extern value_type
    mov rdi, rdx
    call value_type
    mov rdx, rax
.cmg_have_owner:
    test rdx, rdx
    jz .cmg_plain
    ; And the owner has to be a pointer for the same reason: `__get__(0, 5)`
    ; would otherwise hand method_new an immediate to hold.
    V_TEST_PTR rdx, rax
    ja .cmg_plain
    mov rdi, rbx
    mov rsi, rdx
    call method_new
    pop rbx
    leave
    ret
.cmg_plain:
    mov rax, rbx
    INCREF_V rax, rcx
    pop rbx
    leave
    ret
.cmg_bad_pair:
    SET_EXC exc_TypeError_type, "__get__(None, None) is invalid"
    pop rbx
    leave
    ret
.cmg_none:
    lea rax, [rel none_singleton]
    INCREF rax
    pop rbx
    leave
    ret
END_FUNC classmethod_dunder_get

;; ============================================================================
;; property_dunder_get / _set / _delete(args, nargs) -> Value
;;
;; The descriptor protocol LOAD_ATTR and STORE_ATTR run natively, exposed by
;; name for the same reason the function ones are: `hasattr(p, '__get__')`.
;; ============================================================================
DEF_FUNC property_dunder_get
    mov rax, [rdi]
    cmp rsi, 2
    jl .pdg2_self
    mov rdx, [rdi + 8]
    lea rcx, [rel none_singleton]
    cmp rdx, rcx
    je .pdg2_self                       ; reached through the class
    test rdx, rdx
    jz .pdg2_self
    mov rdi, rax
    mov rsi, rdx
    call property_descr_get     ; err: (0, 0) packs to the 0 this __get__ answers
    V_PACK rax, rdx
    leave
    ret
.pdg2_self:
    INCREF rax
    leave
    ret
END_FUNC property_dunder_get

PDS2_FRAME equ 16

DEF_FUNC property_dunder_set, PDS2_FRAME
    cmp rsi, 3
    jl .pds2_bad
    mov rax, [rdi]
    mov rdx, [rdi + 16]                 ; the value, already a Value
    mov rsi, [rdi + 8]                  ; the instance
    mov rdi, rax
    call property_descr_set
    ERR_M1 .pds2_raised
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.pds2_raised:
    xor eax, eax
    leave
    ret
.pds2_bad:
    SET_EXC exc_TypeError_type, "__set__() takes exactly 2 arguments"
    leave
    ret
END_FUNC property_dunder_set

DEF_FUNC property_dunder_delete, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    cmp rsi, 2
    jl .pdd_no_deleter
    mov rbx, [rdi]
    mov rax, [rbx + PyPropertyObject.prop_del]
    test rax, rax
    jz .pdd_no_deleter
    mov rdx, [rdi + 8]
    SPUSH_PTR rdx                       ; args[0] = the instance
    mov rdi, rax
    mov rsi, rsp
    mov edx, 1
    call obj_call_n
    add rsp, 16
    ERR_NULL .pdd_failed
    V_UNPACK rax, rdx
    DECREF_VAL rax, edx
    lea rax, [rel none_singleton]
    INCREF rax
    pop rbx
    leave
    ret
.pdd_failed:
    xor eax, eax
    pop rbx
    leave
    ret
.pdd_no_deleter:
    FAIL exc_AttributeError_type, "can't delete attribute", .pdd_failed
END_FUNC property_dunder_delete

section .text

;; ============================================================================
;; property_setattr(rdi = self, rsi = name, rdx = value Value)
;;   -> rax = 0, or -1 with the AttributeError pending
;; Fails: -1
;;
;; Only __doc__ is writable, which is the one CPython allows -- fget, fset and
;; fdel are read-only there too.  dis.py opens with
;; `_Instruction.opname.__doc__ = "Human readable name for operation"`, and
;; with no tp_setattr at all that was "AttributeError: cannot set attribute",
;; which took dis, modulefinder, pathlib, zipapp and mimetypes with it.
;; ============================================================================
PSA_SELF  equ 8
PSA_VAL   equ 16
PSA_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC_LOCAL property_setattr, PSA_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - PSA_VAL], rdx

    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "__doc__"
    call ap_strcmp
    test eax, eax
    jnz .psa_readonly

    mov rdi, [rbp - PSA_VAL]
    test rdi, rdi
    jz .psa_delete
    INCREF_V rdi, rax
    mov rax, [rbx + PyPropertyObject.prop_doc]
    mov rcx, [rbp - PSA_VAL]
    mov [rbx + PyPropertyObject.prop_doc], rcx
    test rax, rax
    jz .psa_ok
    mov rdi, rax
    DECREF_V rdi, rcx
.psa_ok:
    xor eax, eax
    pop rbx
    leave
    ret

.psa_delete:
    mov rdi, [rbx + PyPropertyObject.prop_doc]
    mov qword [rbx + PyPropertyObject.prop_doc], 0
    test rdi, rdi
    jz .psa_ok
    DECREF_V rdi, rcx
    jmp .psa_ok

.psa_readonly:
    SET_EXC exc_AttributeError_type, "readonly attribute"
    mov rax, -1
    pop rbx
    leave
    ret
END_FUNC property_setattr

section .data

; staticmethod_type - type descriptor for staticmethod wrapper
align 8
global staticmethod_type
staticmethod_type:
    dq 0x00000000FFFFFFFF       ; ob_ref_local=IMMORTAL, ob_ref_shared=0
    dq 0                        ; ob_tid=0 (immortal), ob_mutex=0
    dq type_type                ; ob_type
    dq sm_name_str              ; tp_name
    dq PyStaticMethodObject_size ; tp_basicsize
    dq staticmethod_dealloc     ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq staticmethod_call        ; tp_call (callable since 3.10)
    dq descr_func_attr          ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq staticmethod_construct ; tp_new  (constructor)
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC                        ; tp_flags
    dq 0                        ; tp_bases
    dq staticmethod_traverse                        ; tp_traverse
    dq staticmethod_clear                        ; tp_clear
    dq 0               ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; classmethod_type - type descriptor for classmethod wrapper
align 8
global classmethod_type
classmethod_type:
    dq 0x00000000FFFFFFFF       ; ob_ref_local=IMMORTAL, ob_ref_shared=0
    dq 0                        ; ob_tid=0 (immortal), ob_mutex=0
    dq type_type                ; ob_type
    dq cm_name_str              ; tp_name
    dq PyClassMethodObject_size ; tp_basicsize
    dq classmethod_dealloc      ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                ; tp_call  (instances are not callable)
    dq descr_func_attr          ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq classmethod_construct ; tp_new  (constructor)
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC                        ; tp_flags
    dq 0                        ; tp_bases
    dq classmethod_traverse                        ; tp_traverse
    dq classmethod_clear                        ; tp_clear
    dq 0              ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; property_type - type descriptor for property descriptor
align 8
global property_type
property_type:
    dq 0x00000000FFFFFFFF       ; ob_ref_local=IMMORTAL, ob_ref_shared=0
    dq 0                        ; ob_tid=0 (immortal), ob_mutex=0
    dq type_type                ; ob_type
    dq prop_name_str            ; tp_name
    dq PyPropertyObject_size    ; tp_basicsize
    dq property_dealloc         ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                ; tp_call  (instances are not callable)
    dq property_getattr         ; tp_getattr (.setter/.getter/.deleter)
    dq property_setattr         ; tp_setattr (__doc__, and nothing else)
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq property_construct   ; tp_new  (constructor)
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC                        ; tp_flags
    dq 0                        ; tp_bases
    dq property_traverse                        ; tp_traverse
    dq property_clear                        ; tp_clear
    dq 0           ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; member_descr_type - type descriptor for __slots__ member descriptors
md_name_str: db "member_descriptor", 0
align 8
global member_descr_type
member_descr_type:
    dq 0x00000000FFFFFFFF       ; ob_ref_local=IMMORTAL, ob_ref_shared=0
    dq 0                        ; ob_tid=0 (immortal), ob_mutex=0
    dq type_type                    ; ob_type
    dq md_name_str                  ; tp_name
    dq PyMemberDescrObject_size     ; tp_basicsize
    dq member_descr_dealloc         ; tp_dealloc
    dq member_descr_repr            ; tp_repr
    dq 0                            ; tp_str
    dq 0                            ; tp_hash
    dq 0                            ; tp_call
    dq member_descr_getattr         ; tp_getattr
    dq 0                            ; tp_setattr
    dq 0                            ; tp_richcompare
    dq 0                            ; tp_iter
    dq 0                            ; tp_iternext
    dq 0                            ; tp_init
    dq 0                            ; tp_new
    dq 0                            ; tp_as_number
    dq 0                            ; tp_as_sequence
    dq 0                            ; tp_as_mapping
    dq 0                            ; tp_base
    dq 0                            ; tp_dict
    dq 0                            ; tp_mro
    dq 0                            ; tp_flags
    dq 0                            ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

align 8
u_name_str: db "types.UnionType", 0

align 8
global union_type
union_type:
    dq 0x00000000FFFFFFFF       ; ob_ref_local=IMMORTAL, ob_ref_shared=0
    dq 0                        ; ob_tid=0 (immortal), ob_mutex=0
    dq type_type                    ; ob_type
    dq u_name_str                   ; tp_name
    dq PyGenericAliasObject_size    ; tp_basicsize
    dq generic_alias_dealloc        ; tp_dealloc
    dq union_repr                   ; tp_repr
    dq union_repr                   ; tp_str
    dq union_hash                   ; tp_hash
    dq 0                            ; tp_call
    dq union_getattr                ; tp_getattr
    dq 0                            ; tp_setattr
    dq union_richcompare            ; tp_richcompare
    dq 0                            ; tp_iter
    dq 0                            ; tp_iternext
    dq 0                            ; tp_init
    dq 0                            ; tp_new
    dq union_number_methods         ; tp_as_number
    dq 0                            ; tp_as_sequence
    dq 0                            ; tp_as_mapping
    dq 0                            ; tp_base
    dq 0                            ; tp_dict
    dq 0                            ; tp_mro
    dq 0                            ; tp_flags
    dq 0                            ; tp_bases
    dq 0                            ; tp_traverse
    dq 0                            ; tp_clear
    dq 0                            ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer


section .text

section .data
align 8
union_number_methods:
    times 15 dq 0
    dq union_type_or                ; nb_or (+120)
    times 20 dq 0

; A generic alias is unionable too, so `list[int] | None` needs the slot on
; the LEFT operand's type as well as on the right's.
align 8
global generic_alias_as_number
generic_alias_as_number:
    times 15 dq 0
    dq union_type_or                ; nb_or (+120)
    times 20 dq 0

align 8
global ga_name_str
global ga_name_str
ga_name_str: db "types.GenericAlias", 0

align 8
section .text


section .data


align 8
gsd_name_str: db "getset_descriptor", 0

align 8
global getset_descr_type
getset_descr_type:
    dq 0x00000000FFFFFFFF       ; ob_ref_local=IMMORTAL, ob_ref_shared=0
    dq 0                        ; ob_tid=0 (immortal), ob_mutex=0
    dq type_type                    ; ob_type
    dq gsd_name_str                 ; tp_name
    dq PyGetSetDescrObject_size     ; tp_basicsize
    dq getset_descr_dealloc         ; tp_dealloc
    dq getset_descr_repr            ; tp_repr
    dq getset_descr_repr            ; tp_str
    dq 0                            ; tp_hash
    dq 0                            ; tp_call
    dq getset_descr_getattr         ; tp_getattr
    dq 0                            ; tp_setattr
    dq 0                            ; tp_richcompare
    dq 0                            ; tp_iter
    dq 0                            ; tp_iternext
    dq 0                            ; tp_init
    dq 0                            ; tp_new
    dq 0                            ; tp_as_number
    dq 0                            ; tp_as_sequence
    dq 0                            ; tp_as_mapping
    dq 0                            ; tp_base
    dq 0                            ; tp_dict
    dq 0                            ; tp_mro
    dq 0                            ; tp_flags
    dq 0                            ; tp_bases
    dq 0                            ; tp_traverse
    dq 0                            ; tp_clear
    dq 0                            ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

align 8
mp_name_str: db "mappingproxy", 0

align 8
global mappingproxy_type
mappingproxy_type:
    dq 0x00000000FFFFFFFF       ; ob_ref_local=IMMORTAL, ob_ref_shared=0
    dq 0                        ; ob_tid=0 (immortal), ob_mutex=0
    dq type_type                    ; ob_type
    dq mp_name_str                  ; tp_name
    dq PyMappingProxyObject_size    ; tp_basicsize
    dq mappingproxy_dealloc         ; tp_dealloc
    dq mappingproxy_repr            ; tp_repr
    dq mappingproxy_repr            ; tp_str
    dq 0                            ; tp_hash
    dq 0                            ; tp_call
    dq mappingproxy_getattr         ; tp_getattr
    dq 0                            ; tp_setattr
    dq 0                            ; tp_richcompare
    dq mappingproxy_iter            ; tp_iter
    dq 0                            ; tp_iternext
    dq 0                            ; tp_init
    dq mappingproxy_construct       ; tp_new
    dq 0                            ; tp_as_number
    dq mappingproxy_seq_methods     ; tp_as_sequence
    dq mappingproxy_map_methods     ; tp_as_mapping
    dq 0                            ; tp_base
    dq 0                            ; tp_dict
    dq 0                            ; tp_mro
    dq 0                            ; tp_flags
    dq 0                            ; tp_bases
    dq 0                            ; tp_traverse
    dq 0                            ; tp_clear
    dq 0                            ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

align 8
mappingproxy_seq_methods:
    dq mappingproxy_len             ; sq_length
    dq 0, 0, 0, 0                   ; concat, repeat, item, ass_item
    dq mappingproxy_contains        ; sq_contains
    dq 0, 0                         ; inplace concat, repeat

align 8
mappingproxy_map_methods:
    dq mappingproxy_len             ; mp_length
    dq mappingproxy_subscript       ; mp_subscript
    dq 0                            ; mp_ass_subscript


section .rodata
mpg_n_setitem: db "__setitem__", 0
mpg_n_delitem: db "__delitem__", 0
mpg_n_clear:   db "clear", 0
mpg_n_pop:     db "pop", 0
mpg_n_popitem: db "popitem", 0
mpg_n_setdefault: db "setdefault", 0
mpg_n_update:  db "update", 0
align 8
mpg_readonly_names:
    dq mpg_n_setitem, mpg_n_delitem, mpg_n_clear, mpg_n_pop
    dq mpg_n_popitem, mpg_n_setdefault, mpg_n_update, 0

section .text

;; ============================================================================
;; GC traverse and clear.  These lived in gc.asm, which left the collector
;; holding the reference graph of every type in the system; a type's own
;; file is the only place that knows which of its fields are owned.
;; ============================================================================

;; ============================================================================
;; ---- staticmethod_traverse / classmethod_traverse / property_traverse ----
;; ============================================================================
DEF_FUNC staticmethod_traverse
    mov rdi, [rdi + PyStaticMethodObject.sm_callable]
    V_TEST_PTR rdi, rax         ; a Value: only a pointer is the collector's
    ja .smt_done
    VISIT_PTR rdi
.smt_done:
    leave
    ret
END_FUNC staticmethod_traverse

DEF_FUNC staticmethod_clear, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyStaticMethodObject.sm_callable]
    mov qword [rbx + PyStaticMethodObject.sm_callable], 0
    ; DECREF_V: the slot is a Value, and the dealloc beside this one already
    ; knows it.  An immediate here released a number as a pointer.
    DECREF_V rdi, rax
.done:
    pop rbx
    leave
    ret
END_FUNC staticmethod_clear

DEF_FUNC classmethod_traverse
    mov rdi, [rdi + PyClassMethodObject.cm_callable]
    V_TEST_PTR rdi, rax         ; a Value: only a pointer is the collector's
    ja .cmt_done
    VISIT_PTR rdi
.cmt_done:
    leave
    ret
END_FUNC classmethod_traverse

DEF_FUNC classmethod_clear, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyClassMethodObject.cm_callable]
    mov qword [rbx + PyClassMethodObject.cm_callable], 0
    ; DECREF_V: the slot is a Value, and the dealloc beside this one already
    ; knows it.  An immediate here released a number as a pointer.
    DECREF_V rdi, rax
.done:
    pop rbx
    leave
    ret
END_FUNC classmethod_clear

DEF_FUNC property_traverse, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    mov rbx, rdi
    mov rax, [rbx + PyPropertyObject.prop_get]
    VISIT_V rax, rcx
    mov rax, [rbx + PyPropertyObject.prop_set]
    VISIT_V rax, rcx
    mov rax, [rbx + PyPropertyObject.prop_del]
    VISIT_V rax, rcx
    mov rax, [rbx + PyPropertyObject.prop_doc]
    VISIT_V rax, rcx
    pop rbx
    leave
    ret
END_FUNC property_traverse

DEF_FUNC property_clear, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyPropertyObject.prop_name]
    mov qword [rbx + PyPropertyObject.prop_name], 0
    test rdi, rdi
    jz .no_name
    call obj_decref
.no_name:
    mov rdi, [rbx + PyPropertyObject.prop_get]
    mov qword [rbx + PyPropertyObject.prop_get], 0
    test rdi, rdi
    jz .no_get
    DECREF_V rdi, rcx
.no_get:
    mov rdi, [rbx + PyPropertyObject.prop_set]
    mov qword [rbx + PyPropertyObject.prop_set], 0
    test rdi, rdi
    jz .no_set
    DECREF_V rdi, rcx
.no_set:
    mov rdi, [rbx + PyPropertyObject.prop_del]
    mov qword [rbx + PyPropertyObject.prop_del], 0
    test rdi, rdi
    jz .no_del
    DECREF_V rdi, rcx
.no_del:
    mov rdi, [rbx + PyPropertyObject.prop_doc]
    mov qword [rbx + PyPropertyObject.prop_doc], 0
    test rdi, rdi
    jz .no_doc
    DECREF_V rdi, rcx
.no_doc:
    pop rbx
    leave
    ret
END_FUNC property_clear

section .rodata
pc_doc_name: db "__doc__", 0
