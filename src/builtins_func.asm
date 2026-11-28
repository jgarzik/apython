; builtins_func.asm - what a builtin FUNCTION is, beyond being called.
;
; src/builtins.asm is the builtins themselves -- len, abs, sorted and the rest
; -- and it reached the 100k cap lint.py enforces for a hand-written file.
; What moved here is the other thing that file held: the PyBuiltinObject's own
; machinery, which is about the callable rather than about any one builtin.
; Its attributes (__name__, __qualname__, __module__, __self__, __get__), its
; repr, its dealloc, the stamp that tells a type's method from a module's
; function, and builtin_kind_of, which decides which of the two a name is.
;
; They belong together because they all read the same three fields --
; func_name, func_owner and func_kind -- and because func_kind is what answers
; "is this a descriptor", which is the question every attribute-lookup site
; asks through builtin_should_bind.

%include "macros.inc"
%include "object.inc"

extern ap_free
extern ap_strcmp
extern bfg_get_cached
extern bfr_close
extern bfr_function_open
extern bfr_method_open
extern bfr_objects
extern bfr_of
extern bfr_of_type_object
extern bfr_on_type_open
extern bfr_wrapper_open
extern bko_contains_methods
extern bko_contains_name
extern bko_getitem_methods
extern bko_getitem_name
extern bko_name_in_table
extern bko_name_is
extern bko_type_in_table
extern bko_wrapper_names
extern builtin_func_new
extern builtin_func_repr_unknown_str
extern builtin_func_type
extern exc_TypeError_type
extern none_singleton
extern obj_decref
extern set_exception
extern str_from_cstr
extern str_from_cstr_heap

section .text

;; ============================================================================
;; builtin_func_getattr(rdi = the builtin, rsi = a name str) -> rax = a Value,
;; or 0 when there is no such attribute
;;
;; __name__, __qualname__ and __module__.  The stdlib asks for the first two
;; by name -- statistics decorates with functools and reads f.__name__, and
;; anything that builds a wrapper does the same -- and a builtin had no
;; tp_getattr at all, so the lookup fell through to a type-dict search that
;; answered nothing.
;;
;; __qualname__ is "str.upper" for a method and just the name for a plain
;; function, which is the distinction func_owner already records.  __module__
;; is "builtins" for a plain builtin and None for a method, as CPython's is.
;; ============================================================================
BFG_SELF  equ 8
BFG_NAME  equ 16
BFG_BUF   equ 208
BFG_FRAME equ 208           ; + 1 push = 216... one word more to land right
global builtin_func_getattr
DEF_FUNC builtin_func_getattr, 216      ; + 1 push = 224, 16-aligned
    push rbx
    mov rbx, rdi
    mov [rbp - BFG_SELF], rdi
    mov [rbp - BFG_NAME], rsi

    ; __get__ is answered here rather than from the type's dict, because it is
    ; a per-OBJECT question: CPython's method_descriptor and wrapper_descriptor
    ; have one and its builtin_function_or_method does not, and this tree has
    ; a single type for all three.  The stdlib asks hasattr(f, '__get__') to
    ; decide whether something is a descriptor -- inspect, enum and dataclasses
    ; all do -- so a shared tp_dict entry answered True for `len`.
    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "__get__"
    call ap_strcmp
    test eax, eax
    jz .bfg_get

    mov rdi, [rbp - BFG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "__name__"
    call ap_strcmp
    test eax, eax
    jz .bfg_name

    mov rdi, [rbp - BFG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "__qualname__"
    call ap_strcmp
    test eax, eax
    jz .bfg_qualname

    mov rdi, [rbp - BFG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "__module__"
    call ap_strcmp
    test eax, eax
    jz .bfg_module

    mov rdi, [rbp - BFG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "__self__"
    call ap_strcmp
    test eax, eax
    jz .bfg_self

    mov rdi, [rbp - BFG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "__objclass__"
    call ap_strcmp
    test eax, eax
    jz .bfg_objclass

    xor eax, eax
    pop rbx
    leave
    ret

.bfg_objclass:
    ; The class a DESCRIPTOR was found on.  CPython's method_descriptor and
    ; wrapper_descriptor carry it and its builtin_function_or_method does
    ; not; inspect reads it to classify, and descr_reduce reads it to pickle.
    ; There was no arm at all, so str.count.__objclass__ was an
    ; AttributeError.
    mov rcx, [rbx + PyBuiltinObject.func_kind]
    cmp rcx, BUILTIN_KIND_METHOD
    je .bfg_owner
    cmp rcx, BUILTIN_KIND_WRAPPER
    jne .bfg_no_attr
.bfg_owner:
    mov rax, [rbx + PyBuiltinObject.func_owner]
    test rax, rax
    jz .bfg_no_attr
    INCREF rax
    pop rbx
    leave
    ret
.bfg_no_attr:
    xor eax, eax
    pop rbx
    leave
    ret

.bfg_self:
    ; The type this method was found on.  `int.__new__.__self__ is int` is
    ; not decoration: copyreg._reduce_ex walks the MRO comparing
    ; `base.__new__.__self__ is base` to find the last non-heap base, and
    ; without it every protocol-0 and protocol-1 reduction was an
    ; AttributeError -- which is `copy.copy` and every old pickle.
    ;
    ; CPython's method_descriptor and wrapper_descriptor have no __self__ at
    ; all -- only a bound method does, and it is the receiver -- and that
    ; difference cannot be expressed here: __self__ is published as a getset
    ; on the ONE type that stands for CPython's three kinds, so "absent"
    ; would have to be a per-object answer from a per-type descriptor.
    ; DIVERGENCES.md records it, beside the entry for a bound builtin being a
    ; `method`.  What depended on it is fixed elsewhere: builtin_func_reduce
    ; reads func_kind directly rather than inferring the kind from __self__.
    mov rax, [rbx + PyBuiltinObject.func_owner]
    test rax, rax
    jz .bfg_missing
    INCREF rax
    pop rbx
    leave
    ret
.bfg_missing:
    ; A module-level builtin is bound to its MODULE, which for everything here
    ; is builtins: CPython's `len.__self__` is <module 'builtins'>, and its
    ; meth_reduce reads it to decide between a bare name and a getattr pair.
    ; The comment that used to sit here said CPython had no __self__ for one,
    ; and it does.
    extern builtins_module_obj
    mov rax, [rel builtins_module_obj]
    test rax, rax
    jz .bfg_no_module
    INCREF rax
    pop rbx
    leave
    ret
.bfg_no_module:
    ; Before the module exists -- during start-up -- there is nothing to name.
    xor eax, eax
    pop rbx
    leave
    ret

.bfg_get:
    ; Only a descriptor has one.  A module-level builtin and the payload of a
    ; class or static method answer absent, which is what makes
    ; hasattr(len, '__get__') False, as it is in CPython.
    mov rcx, [rbx + PyBuiltinObject.func_kind]
    cmp rcx, BUILTIN_KIND_FUNCTION
    je .bfg_absent
    cmp rcx, BUILTIN_KIND_ON_TYPE
    je .bfg_absent
    call bfg_get_builtin
    test rax, rax
    jz .bfg_absent
    mov rdi, rax
    mov rsi, rbx
    extern method_new
    call method_new
    pop rbx
    leave
    ret

.bfg_absent:
    xor eax, eax
    pop rbx
    leave
    ret


.bfg_name:
    mov rax, [rbx + PyBuiltinObject.func_name]
    test rax, rax
    jz .bfg_none
    INCREF rax
    pop rbx
    leave
    ret

.bfg_qualname:
    ; A method is qualified by the type that owns it.
    cmp qword [rbx + PyBuiltinObject.func_owner], 0
    je .bfg_name
    lea rdi, [rbp - BFG_BUF]
    mov rsi, [rbx + PyBuiltinObject.func_owner]
    mov rsi, [rsi + PyTypeObject.tp_name]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "."
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbx + PyBuiltinObject.func_name]
    test rsi, rsi
    jz .bfg_qual_done
    add rsi, PyStrObject.data
    call rbt_append_cstr
.bfg_qual_done:
    lea rdi, [rbp - BFG_BUF]
    call str_from_cstr_heap
    pop rbx
    leave
    ret

.bfg_module:
    ; CPython gives a plain builtin "builtins" and a method None.
    cmp qword [rbx + PyBuiltinObject.func_owner], 0
    jne .bfg_none
    CSTRING rdi, "builtins"
    call str_from_cstr_heap
    pop rbx
    leave
    ret

.bfg_none:
    lea rax, [rel none_singleton]
    INCREF rax
    pop rbx
    leave
    ret
END_FUNC builtin_func_getattr
;; ============================================================================
;; bfg_get_builtin() -> rax = the shared `__get__` builtin, borrowed, or 0
;;
;; One object for the process, bound to each descriptor on demand.  It used to
;; live in builtin_func_type's tp_dict, which is exactly why it could not tell
;; a descriptor from a plain function: a type dict is shared by every instance.
;; ============================================================================
DEF_FUNC_LOCAL bfg_get_builtin
    mov rax, [rel bfg_get_cached]
    test rax, rax
    jnz .bgb_done
    lea rdi, [rel builtin_func_dunder_get]
    CSTRING rsi, "__get__"
    call builtin_func_new
    test rax, rax
    jz .bgb_done
    mov [rel bfg_get_cached], rax
.bgb_done:
    leave
    ret
END_FUNC bfg_get_builtin


;; ============================================================================
;; builtin_func_dealloc(PyObject *self)
;;   -> void; releases func_name and frees the object
;;
;; Free the builtin function wrapper
;; ============================================================================
global builtin_func_dealloc
DEF_FUNC builtin_func_dealloc, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; DECREF the name string
    mov rdi, [rbx + PyBuiltinObject.func_name]
    test rdi, rdi
    jz .no_name
    call obj_decref
.no_name:

    ; Free the object
    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC builtin_func_dealloc

;; ============================================================================
;; builtin_func_repr(PyObject *self) -> PyObject*
;; Returns "<built-in function len>", "<method 'bit_length' of 'int'
;; objects>" or "<slot wrapper '__add__' of 'int' objects>", depending on
;; func_kind.
;;
;; It used to INCREF func_name and hand it back verbatim, so repr(len) was
;; 'len' and repr(int.bit_length) was 'bit_length'.  That is not cosmetic:
;; the stdlib classifies a callable by reading its repr, and the three forms
;; are three different CPython types.
;; ============================================================================
BFR_BUF   equ 264           ; the composed repr; two 80-char names plus text
BFR_FRAME equ 280            ; + 1 push = 288, 16-aligned
extern rbt_append_cstr
;; ============================================================================
;; builtin_func_repr(rdi = the PyBuiltinObject)
;;   -> rax = a str, owned, or 0 with an exception pending
;;
;; Four wordings, chosen by func_kind, because that is what says which of
;; CPython's four callable types this one object is standing in for:
;;   <built-in function len>
;;   <method 'append' of 'list' objects>
;;   <slot wrapper '__add__' of 'int' objects>
;;   <built-in method upper of str object at 0x...>
;; ============================================================================
global builtin_func_repr
DEF_FUNC builtin_func_repr, BFR_FRAME
    push rbx
    mov rbx, rdi

    mov rax, [rbx + PyBuiltinObject.func_name]
    test rax, rax
    jz .fallback

    mov rcx, [rbx + PyBuiltinObject.func_owner]
    test rcx, rcx
    jz .plain

    ; A classmethod's or staticmethod's callable, reached without binding:
    ; "<built-in method maketrans of type object at 0x...>", naming the type
    ; it was found on.  method_repr has the same form for the bound case.
    cmp qword [rbx + PyBuiltinObject.func_kind], BUILTIN_KIND_ON_TYPE
    je .on_type

    ; "<method '" or "<slot wrapper '"
    lea rdi, [rbp - BFR_BUF]
    lea rsi, [rel bfr_method_open]
    cmp qword [rbx + PyBuiltinObject.func_kind], BUILTIN_KIND_WRAPPER
    jne .have_open
    lea rsi, [rel bfr_wrapper_open]
.have_open:
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbx + PyBuiltinObject.func_name]
    add rsi, PyStrObject.data
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel bfr_of]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbx + PyBuiltinObject.func_owner]
    mov rsi, [rsi + PyTypeObject.tp_name]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel bfr_objects]
    call rbt_append_cstr
    lea rdi, [rbp - BFR_BUF]
    call str_from_cstr
    pop rbx
    leave
    ret

.on_type:
    lea rdi, [rbp - BFR_BUF]
    lea rsi, [rel bfr_on_type_open]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbx + PyBuiltinObject.func_name]
    add rsi, PyStrObject.data
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel bfr_of_type_object]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbx + PyBuiltinObject.func_owner]
    extern obj_repr_address
    call obj_repr_address       ; writes " at 0xADDR>"
    lea rdi, [rbp - BFR_BUF]
    call str_from_cstr
    pop rbx
    leave
    ret

.plain:
    lea rdi, [rbp - BFR_BUF]
    lea rsi, [rel bfr_function_open]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbx + PyBuiltinObject.func_name]
    add rsi, PyStrObject.data
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel bfr_close]
    call rbt_append_cstr
    lea rdi, [rbp - BFR_BUF]
    call str_from_cstr
    pop rbx
    leave
    ret

.fallback:
    lea rdi, [rel builtin_func_repr_unknown_str]
    call str_from_cstr
    pop rbx
    leave
    ret
END_FUNC builtin_func_repr

;; ============================================================================
;; type_stamp_methods(rdi = a type whose tp_dict is complete)
;;
;; Walks the type's dict and tells every PyBuiltinObject in it which type it
;; belongs to and which of CPython's three descriptor kinds it is.  Called
;; once per type from methods_init, after the dict is stored.
;;
;; A stamp rather than an argument on each of the three hundred registration
;; sites, and it also catches the methods a shared helper registered -- the
;; set/frozenset table, the DEF_DUNDER_* generators -- which no per-site
;; argument would have reached without touching every one of them.
;;
;; Only a bare PyBuiltinObject is stamped.  A staticmethod or classmethod
;; wrapper is skipped, which is right: CPython reprs those differently again,
;; and with an address this tree does not print.
;; ============================================================================
TSM_TYPE  equ 8
TSM_FRAME equ 32            ; + 2 pushes = 8 + 32 + 16 = 56, not 16-aligned
;;   -> void; writes func_owner and func_kind onto everything the dict holds
;;
global type_stamp_methods
DEF_FUNC type_stamp_methods, TSM_FRAME
    push rbx
    push r12
    mov [rbp - TSM_TYPE], rdi
    mov rbx, [rdi + PyTypeObject.tp_dict]
    test rbx, rbx
    jz .tsm_done
    OBJ_LOCK rbx

    mov r12, [rbx + PyDictObject.entries]
    test r12, r12
    jz .tsm_unlock_done
    mov rcx, [rbx + PyDictObject.capacity]
    xor r8d, r8d
.tsm_loop:
    cmp r8, rcx
    jge .tsm_unlock_done
    mov rax, r8
    imul rax, DICT_ENTRY_SIZE
    add rax, r12
    mov rdx, [rax + DictEntry.key]
    test rdx, rdx
    jz .tsm_next
    mov rax, [rax + DictEntry.value]
    V_TEST_PTR rax, r9
    ja .tsm_next                ; an immediate is not a method
    test rax, rax
    jz .tsm_next
    extern getset_descr_type
    lea r9, [rel getset_descr_type]
    cmp [rax + PyObject.ob_type], r9
    je .tsm_getset
    extern classmethod_type
    lea r9, [rel classmethod_type]
    cmp [rax + PyObject.ob_type], r9
    je .tsm_on_type
    extern staticmethod_type
    lea r9, [rel staticmethod_type]
    cmp [rax + PyObject.ob_type], r9
    je .tsm_on_type
    lea r9, [rel builtin_func_type]
    cmp [rax + PyObject.ob_type], r9
    jne .tsm_next
    cmp qword [rax + PyBuiltinObject.func_owner], 0
    jne .tsm_next               ; a shared body keeps its first owner

    push rcx
    push r8
    push rax
    sub rsp, 8
    mov rdi, [rbp - TSM_TYPE]
    mov rsi, [rax + PyBuiltinObject.func_name]
    call builtin_kind_of
    add rsp, 8
    pop rdx                     ; the builtin
    mov rcx, [rbp - TSM_TYPE]
    mov [rdx + PyBuiltinObject.func_owner], rcx
    mov [rdx + PyBuiltinObject.func_kind], rax
    pop r8
    pop rcx
    mov r12, [rbx + PyDictObject.entries]
    jmp .tsm_next
.tsm_on_type:
    ; int.from_bytes, float.fromhex, dict.fromkeys and str.maketrans are
    ; builtins wrapped in a classmethod or a staticmethod, and skipping the
    ; wrapper left the builtin inside unstamped -- so a bound one reprd as
    ; "<bound method from_bytes of <class 'int'>>" and an unbound one as
    ; "<built-in function maketrans>", where CPython says "<built-in method
    ; from_bytes of type object at 0x...>" for both.  Reach through and stamp
    ; the callable.  The two wrappers keep cm_callable and sm_callable at the
    ; same offset, which is why one arm serves both.
    mov rdx, [rax + PyClassMethodObject.cm_callable]
    test rdx, rdx
    jz .tsm_next
    lea r9, [rel builtin_func_type]
    cmp [rdx + PyObject.ob_type], r9
    jne .tsm_next
    cmp qword [rdx + PyBuiltinObject.func_owner], 0
    jne .tsm_next
    mov r9, [rbp - TSM_TYPE]
    mov [rdx + PyBuiltinObject.func_owner], r9
    mov qword [rdx + PyBuiltinObject.func_kind], BUILTIN_KIND_ON_TYPE
    jmp .tsm_next

.tsm_getset:
    ; A getset carries its owner for the same reason, and for the same repr.
    cmp qword [rax + PyGetSetDescrObject.gs_owner], 0
    jne .tsm_next
    mov rdx, [rbp - TSM_TYPE]
    mov [rax + PyGetSetDescrObject.gs_owner], rdx
.tsm_next:
    inc r8
    jmp .tsm_loop
.tsm_unlock_done:
    OBJ_UNLOCK rbx
.tsm_done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_stamp_methods

;; ============================================================================
;; builtin_func_dunder_get(args, nargs) -- method.__get__(obj[, type])
;;
;; A method descriptor is a NON-data descriptor: hasattr(int.bit_length,
;; '__get__') is True and __set__ is absent, and that pair is exactly how
;; inspect and the enum and dataclasses classifiers tell a method from a
;; getset.  builtin_func_type had no tp_dict, so it answered False to both.
;;
;; The binding itself already happens in op_load_attr; this is the same thing
;; reachable by name.
;; ============================================================================
;;   -> rax = the bound method as a Value, or the descriptor itself when
;;      the instance is None; 0 with an exception pending on a bad arity
;; Fails: 0
;;
global builtin_func_dunder_get
DEF_FUNC builtin_func_dunder_get
    cmp rsi, 2
    jl .bfg_bad
    cmp rsi, 3
    jg .bfg_bad
    mov rax, [rdi]              ; args[0] = the method
    mov rsi, [rdi + 8]          ; args[1] = the instance
    IS_NONE rsi, rcx
    je .bfg_self
    V_TEST_PTR rsi, rcx
    ja .bfg_self                ; an immediate binds nothing, as loads do
    mov rdi, rax
    extern method_new
    call method_new
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.bfg_self:
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.bfg_bad:
    SET_EXC exc_TypeError_type, "expected 1 or 2 arguments"
    leave
    ret
END_FUNC builtin_func_dunder_get

;; ============================================================================
;; builtin_kind_of(rdi = the owning type, rsi = the name string)
;;   -> rax = BUILTIN_KIND_METHOD or BUILTIN_KIND_WRAPPER
;;
;; CPython builds a wrapper_descriptor for every name in its slotdefs table
;; and a method_descriptor for everything else, so the answer is a name
;; lookup -- with two names that go both ways.  dict and set answer
;; __contains__ from a real method and list answers __getitem__ from one,
;; where str, bytes, tuple and range answer both from a slot.
;; ============================================================================
BKO_TYPE  equ 8
BKO_FRAME equ 24            ; + 1 push = 32, 16-aligned
global builtin_kind_of
DEF_FUNC builtin_kind_of, BKO_FRAME
    push rbx
    mov [rbp - BKO_TYPE], rdi
    lea rbx, [rsi + PyStrObject.data]

    ; Only a dunder can be a slot wrapper.
    cmp byte [rbx], '_'
    jne .bko_method
    cmp byte [rbx + 1], '_'
    jne .bko_method

    ; The two names that go both ways, each with its own short list of types
    ; that answer it from a real method rather than from a slot.
    lea rdi, [rel bko_contains_name]
    call bko_name_is
    test eax, eax
    jz .bko_try_getitem
    lea rdi, [rel bko_contains_methods]
    mov rsi, [rbp - BKO_TYPE]
    call bko_type_in_table
    test eax, eax
    jnz .bko_method
    jmp .bko_wrapper
.bko_try_getitem:
    lea rdi, [rel bko_getitem_name]
    call bko_name_is
    test eax, eax
    jz .bko_check_wrapper
    lea rdi, [rel bko_getitem_methods]
    mov rsi, [rbp - BKO_TYPE]
    call bko_type_in_table
    test eax, eax
    jnz .bko_method
    jmp .bko_wrapper

.bko_check_wrapper:
    lea rdi, [rel bko_wrapper_names]
    call bko_name_in_table
    test eax, eax
    jz .bko_method
.bko_wrapper:
    mov eax, BUILTIN_KIND_WRAPPER
    pop rbx
    leave
    ret
.bko_method:
    mov eax, BUILTIN_KIND_METHOD
    pop rbx
    leave
    ret
END_FUNC builtin_kind_of
