; abcmod.asm - the _abc accelerator module
;
; abc.py imports eight names from here and builds ABCMeta on them.  The pure
; Python fallback it reaches for when the import fails, _py_abc, needs
; _weakrefset and so _weakref, which does not exist here -- so this module is
; what makes `import abc` work, and with it collections.abc, os, inspect,
; typing and most of what stands on them.
;
; The algorithm is CPython's, in Modules/_abc.c.  Two deliberate departures,
; both once recorded in the old bug list:
;
;   * The registry and the caches hold strong references.  CPython uses weak
;     ones so a registered class can be collected; here a class that is
;     registered lives as long as the ABC does.
;
; Step 6 -- recursing into cls.__subclasses__() to find a registration made
; on a subclass of the ABC -- was missing for a long time, because types kept
; no subclass list.  They do now, in src/pyo/subclasses.asm, and this reads it
; directly rather than through the Python-level __subclasses__.
;
; State lives in the class's own tp_dict, under the names _py_abc uses, and is
; read straight out of it rather than through type_getattr: an ABC's subclass
; must not inherit its base's registry.

%include "macros.inc"
%include "object.inc"

struc SubList
    .count:    resq 1
    .capacity: resq 1
    .items:    resq 1
endstruc
%include "value.inc"

extern dict_get_mro
extern dict_set
extern dict_new
extern dict_get
extern set_new
extern set_add
extern set_contains
extern str_from_cstr_heap
extern module_new
extern builtin_func_new
extern obj_incref
extern obj_decref
extern obj_dealloc
extern obj_is_true
extern tuple_new
extern type_getattr
extern type_is_subtype
extern sub_list_for_type
extern type_check_is_class
extern value_type
extern ap_strcmp
extern rbt_append_cstr
extern exc_TypeError_type
extern exc_RuntimeError_type
extern bool_true
extern bool_false
extern none_singleton
extern notimpl_singleton
extern type_type

section .text

;; ============================================================================
;; abc_state_get(rdi = cls, rsi = name cstr) -> rax = Value, or 0 if absent
;; Reads the class's own tp_dict.  Borrowed; the caller does not own it.
;; ============================================================================
AG_CLS   equ 8
AG_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC_LOCAL abc_state_get, AG_FRAME
    push rbx
    mov [rbp - AG_CLS], rdi
    mov rdi, rsi
    call str_from_cstr_heap
    mov rbx, rax
    mov rax, [rbp - AG_CLS]
    mov rdi, [rax + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .absent
    mov rsi, rbx
    call dict_get_mro
    mov rdi, rbx
    mov rbx, rax
    call obj_decref
    mov rax, rbx
    pop rbx
    leave
    ret
.absent:
    mov rdi, rbx
    call obj_decref
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC abc_state_get

;; ============================================================================
;; abc_state_set(rdi = cls, rsi = name cstr, rdx = value Value) -> rax = 0
;; Fails: -1
;; Stores into the class's own tp_dict, creating it if the type has none.
;; ============================================================================
AS_CLS   equ 8
AS_VAL   equ 16
AS_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC_LOCAL abc_state_set, AS_FRAME
    push rbx
    mov [rbp - AS_CLS], rdi
    mov [rbp - AS_VAL], rdx
    mov rdi, rsi
    call str_from_cstr_heap
    mov rbx, rax
    mov rax, [rbp - AS_CLS]
    mov rdi, [rax + PyTypeObject.tp_dict]
    test rdi, rdi
    jnz .have_dict
    call dict_new
    mov rcx, [rbp - AS_CLS]
    mov [rcx + PyTypeObject.tp_dict], rax
    mov rdi, rax
.have_dict:
    mov rsi, rbx
    mov rdx, [rbp - AS_VAL]
    call dict_set       ; err: returned to the caller, once the name is released
    mov rdi, rbx
    mov rbx, rax                ; dict_set's answer, across the release
    call obj_decref
    mov rax, rbx
    pop rbx
    leave
    ret
END_FUNC abc_state_set

;; ============================================================================
;; abc_fresh_set(rdi = cls, rsi = name cstr) -> rax = the new set (borrowed)
;; Fails: 0
;; ============================================================================
AF_CLS   equ 8
AF_NAME  equ 16
AF_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC_LOCAL abc_fresh_set, AF_FRAME
    push rbx
    mov [rbp - AF_CLS], rdi
    mov [rbp - AF_NAME], rsi
    call set_new
    mov rbx, rax
    mov rdi, [rbp - AF_CLS]
    mov rsi, [rbp - AF_NAME]
    mov rdx, rbx
    call abc_state_set          ; err: tested once our reference is released -- the dict takes its own
    mov [rbp - AF_NAME], rax
    mov rdi, rbx
    call obj_decref
    mov rax, rbx
    cmp qword [rbp - AF_NAME], 0
    je .af_done
    xor eax, eax                ; the class's dict refused it, and the set is gone
.af_done:
    pop rbx
    leave
    ret
END_FUNC abc_fresh_set

;; ============================================================================
;; abc_ref(rdi = a class) -> rax = an OWNED reference to what the registry and
;;   the caches hold for it
;;
;; A weak reference, which is what CPython's `_abc` keeps in its WeakSets: a
;; class registered against an ABC, or merely asked about once, used to live
;; as long as the ABC did.  Registries are process-lifetime, so that is a leak
;; with no upper bound on what it holds -- a class, its dict, its methods, and
;; whatever those close over.
;;
;; A ref with no callback is SHARED, so the same class always yields the same
;; object: a set lookup finds what a registration put there without any
;; special comparison, and a weakref hashes as its referent does.  A class
;; that cannot carry one is held strongly, as everything was.
;; ============================================================================
DEF_FUNC abc_ref, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    V_TEST_PTR rdi, rax
    ja .ar_strong
    test rdi, rdi
    jz .ar_strong
    mov rdi, [rbx + PyObject.ob_type]
    extern weakref_referenceable
    call weakref_referenceable
    test eax, eax
    jz .ar_strong
    extern weakref_make_shared
    mov rdi, rbx
    call weakref_make_shared
    test rax, rax
    jz .ar_strong
    pop rbx
    leave
    ret
.ar_strong:
    mov rax, rbx
    V_TEST_PTR rax, rcx
    ja .ar_done
    test rax, rax
    jz .ar_done
    INCREF rax
.ar_done:
    pop rbx
    leave
    ret
END_FUNC abc_ref

;; ============================================================================
;; abc_deref(rdi = what a set holds) -> rax = the class, borrowed, or 0 when
;;   the weak reference has gone dead
;; ============================================================================
DEF_FUNC_BARE abc_deref
    V_TEST_PTR rdi, rax
    ja .ad_none
    test rdi, rdi
    jz .ad_none
    mov rax, [rdi + PyObject.ob_type]
    extern weakref_type
    lea rcx, [rel weakref_type]
    cmp rax, rcx
    jne .ad_itself
    mov rax, [rdi + PyWeakRefObject.wr_object]
    ret
.ad_itself:
    mov rax, rdi
    ret
.ad_none:
    xor eax, eax
    ret
END_FUNC abc_deref

;; ============================================================================
;; abc_require_class(rdi = an argument, as a Value) -> rax = it, when a class
;; Fails: 0
;;
;; Every entry point here reads its state out of the argument's tp_dict, and
;; none of them asked whether the argument HAD one: `_abc._reset_registry(1.5)`
;; read a field of a float's bits and `_abc._get_dump("s")` one of a str's.
;; CPython's _get_impl fetches `_abc_impl` off whatever it is handed, so what
;; it says of a non-class is the AttributeError that fetch raises -- "'float'
;; object has no attribute '_abc_impl'" -- and so does this.
;; ============================================================================
ARC_ARG   equ 8
ARC_NAME  equ 16
ARC_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
extern set_no_attribute
DEF_FUNC_LOCAL abc_require_class, ARC_FRAME
    mov [rbp - ARC_ARG], rdi
    call type_check_is_class
    test eax, eax
    jz .arc_refuse
    mov rax, [rbp - ARC_ARG]
    leave
    ret
.arc_refuse:
    CSTRING rdi, "_abc_impl"
    call str_from_cstr_heap
    mov [rbp - ARC_NAME], rax
    mov rdi, [rbp - ARC_ARG]
    mov rsi, rax
    call set_no_attribute
    mov rdi, [rbp - ARC_NAME]
    call obj_decref
    xor eax, eax
    leave
    ret
END_FUNC abc_require_class

;; ============================================================================
;; abc_class_arg(rdi = args, rsi = nargs, rdx = the no-keywords sentence,
;;               rcx = the arity sentence up to its count)
;;   -> rax = the one argument, a class (borrowed)
;; Fails: 0
;;
;; The whole signature of _get_dump, _reset_registry and _reset_caches, which
;; is CPython's METH_O: no keywords, exactly one argument, and that argument
;; an ABC.  A keyword used to arrive as the class.
;; ============================================================================
ACA_ARGS  equ 8
ACA_N     equ 16
ACA_ARITY equ 24
ACA_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
extern set_exception
extern set_type_error_counted
DEF_FUNC_LOCAL abc_class_arg, ACA_FRAME
    mov [rbp - ACA_ARGS], rdi
    mov [rbp - ACA_N], rsi
    mov [rbp - ACA_ARITY], rcx
    cmp qword [gs:ThreadState.kw_names_pending], 0
    je .aca_no_kw
    mov qword [gs:ThreadState.kw_names_pending], 0
    lea rdi, [rel exc_TypeError_type]
    mov rsi, rdx
    call set_exception
    jmp .aca_fail
.aca_no_kw:
    cmp qword [rbp - ACA_N], 1
    jne .aca_arity
    mov rdi, [rbp - ACA_ARGS]
    mov rdi, [rdi]
    call abc_require_class
    ERR_NULL .aca_fail
    leave
    ret
.aca_arity:
    mov rdi, [rbp - ACA_ARITY]
    mov rsi, [rbp - ACA_N]
    CSTRING rdx, " given)"
    call set_type_error_counted
.aca_fail:
    xor eax, eax
    leave
    ret
END_FUNC abc_class_arg

;; ============================================================================
;; get_cache_token() -> int
;; ============================================================================
DEF_FUNC abc_get_cache_token
    mov rax, [rel abc_invalidation_counter]
    V_PACK_I64 rax, rcx
    leave
    ret
END_FUNC abc_get_cache_token

;; ============================================================================
;; abc_getattr(rdi = object Value, rsi = name str) -> rax = Value, or 0
;;
;; What `getattr(value, "__isabstractmethod__", False)` means, and it has to
;; be the WHOLE attribute protocol: this used to ask the type's tp_getattr and
;; then read the type's tp_dict raw, which hands back a descriptor rather than
;; what the descriptor answers.  Harmless while no wrapper had the name; the
;; moment classmethod and property published theirs, every wrapper looked
;; abstract because a getset object is truthy, and a subclass that overrode an
;; abstract classmethod stayed abstract.
;; ============================================================================
DEF_FUNC_LOCAL abc_getattr
    V_TEST_PTR rdi, rax
    ja .aga_none
    test rdi, rdi
    jz .aga_none
    extern obj_getattr_opt
    call obj_getattr_opt        ; a new reference, or 0 with no exception set
    leave
    ret
.aga_none:
    xor eax, eax
    leave
    ret
END_FUNC abc_getattr

;; ============================================================================
;; abc_is_abstract(rdi = value Value) -> rax 0/1
;; Fails: -1
;;   -- the truth of its __isabstractmethod__ could not be asked.
;; ============================================================================
DEF_FUNC_LOCAL abc_is_abstract, 24
    push rbx
    CSTRING rsi, "__isabstractmethod__"
    push rdi
    mov rdi, rsi
    call str_from_cstr_heap
    mov rbx, rax
    pop rdi
    mov rsi, rbx
    call abc_getattr
    push rax
    mov rdi, rbx
    call obj_decref
    pop rdi
    test rdi, rdi
    jz .aia_no
    mov rbx, rdi
    call obj_is_true            ; err: its -1, with the exception, is this function's too
    push rax
    mov rdi, rbx
    DECREF_V rdi, rcx
    pop rax
    pop rbx
    leave
    ret
.aia_no:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC abc_is_abstract

;; ============================================================================
;; abc_compute_abstracts(rdi = cls)
;;
;; __abstractmethods__ is what makes an abstract class refuse to be
;; instantiated, and CPython computes it here rather than in abc.py: the names
;; in the class body that are marked abstract, plus any the bases left abstract
;; and this class did not override.
;; -> rax = 0
;; Fails: -1
;; for a name whose __hash__ or __eq__ raises as the set is built, or an
;; __isabstractmethod__ whose truth raised, as CPython's does.
;; ============================================================================
CA_CLS   equ 8
CA_SET   equ 16
CA_IDX   equ 24
CA_DICT  equ 32
CA_KEY   equ 48
CA_FRAME equ 64             ; + 2 pushes = 80
DEF_FUNC_LOCAL abc_compute_abstracts, CA_FRAME
    push rbx
    push r12
    mov [rbp - CA_CLS], rdi
    call set_new
    mov [rbp - CA_SET], rax

    ; The class's own namespace.
    mov rax, [rbp - CA_CLS]
    mov rax, [rax + PyTypeObject.tp_dict]
    test rax, rax
    jz .ca_bases
    mov [rbp - CA_DICT], rax
    mov qword [rbp - CA_IDX], 0
.ca_own_loop:
    mov rax, [rbp - CA_DICT]
    mov rcx, [rbp - CA_IDX]
    cmp rcx, [rax + PyDictObject.dk_nentries]
    jge .ca_bases
    mov rdx, [rax + PyDictObject.entries]
    imul rcx, rcx, DICT_ENTRY_SIZE
    mov rbx, [rdx + rcx + DictEntry.key]
    mov r12, [rdx + rcx + DictEntry.value]
    inc qword [rbp - CA_IDX]
    test rbx, rbx
    jz .ca_own_loop
    mov rdi, r12
    call abc_is_abstract
    ERR_M1 .ca_fail
    test eax, eax
    jz .ca_own_loop
    mov rdi, [rbp - CA_SET]
    mov rsi, rbx
    call set_add
    ERR_M1 .ca_fail
    jmp .ca_own_loop

.ca_bases:
    ; Anything a base left abstract and this class did not define concretely.
    ; The MRO rather than __bases__: a static type keeps no tp_bases tuple,
    ; and every entry carries its own __abstractmethods__ anyway.
    mov rbx, [rbp - CA_CLS]
.ca_base_loop:
    MRO_NEXT rbx, [rbp - CA_CLS]
    test rbx, rbx
    jz .ca_store
    mov rdi, rbx
    CSTRING rsi, "__abstractmethods__"
    call abc_state_get
    mov r12, rax
    test r12, r12
    jz .ca_base_loop
    V_TEST_PTR r12, rax
    ja .ca_base_loop
    mov qword [rbp - CA_IDX], 0
.ca_names_loop:
    mov rcx, [rbp - CA_IDX]
    cmp rcx, [r12 + PyDictObject.capacity]
    jge .ca_base_loop
    mov rdx, [r12 + PyDictObject.entries]
    shl rcx, 4                  ; SET_ENTRY_SIZE
    mov rax, [rdx + rcx + 8]    ; the key (the hash sits at +0)
    inc qword [rbp - CA_IDX]
    test rax, rax
    jz .ca_names_loop
    V_TEST_PTR rax, rcx
    ja .ca_names_loop
    mov [rbp - CA_KEY], rax
    mov rdi, [rbp - CA_CLS]
    mov rsi, rax
    call type_getattr
    V_UNPACK rax, rdx
    test edx, edx
    jz .ca_names_loop
    push rax
    push rdx
    mov rdi, rax
    V_PACK rdi, rdx
    call abc_is_abstract        ; err: tested as rcx below, once the attribute is released
    mov rcx, rax
    pop rdx
    pop rdi
    push rcx
    DECREF_VAL rdi, rdx
    pop rcx
    cmp rcx, -1                 ; never an answer
    je .ca_fail
    test ecx, ecx
    jz .ca_names_loop
    mov rdi, [rbp - CA_SET]
    mov rsi, [rbp - CA_KEY]
    call set_add
    ERR_M1 .ca_fail
    jmp .ca_names_loop

.ca_store:
    mov rax, [rbp - CA_SET]
    extern frozenset_type
    lea rcx, [rel frozenset_type]
    mov [rax + PyObject.ob_type], rcx   ; the name set is immutable
    mov rdi, [rbp - CA_CLS]
    CSTRING rsi, "__abstractmethods__"
    mov rdx, rax
    call abc_state_set
    ERR_M1 .ca_fail
    mov rdi, [rbp - CA_SET]
    call obj_decref
    xor eax, eax
.ca_ret:
    pop r12
    pop rbx
    leave
    ret
.ca_fail:
    mov rdi, [rbp - CA_SET]     ; the half-built set
    call obj_decref
    mov rax, -1
    jmp .ca_ret
END_FUNC abc_compute_abstracts

;; ============================================================================
;; _abc_init(cls) -> None
;; Fails: 0
;; ============================================================================
AI_CLS   equ 8
AI_FRAME equ 16             ; + 0 pushes = 16
DEF_FUNC abc_init_func, AI_FRAME
    cmp rsi, 1
    jl .bad
    mov rax, [rdi]
    mov [rbp - AI_CLS], rax
    mov rdi, rax
    call type_check_is_class
    test eax, eax
    jz .bad

    mov rdi, [rbp - AI_CLS]
    CSTRING rsi, "_abc_registry"
    call abc_fresh_set
    ERR_NULL .ai_fail
    mov rdi, [rbp - AI_CLS]
    CSTRING rsi, "_abc_cache"
    call abc_fresh_set
    ERR_NULL .ai_fail
    mov rdi, [rbp - AI_CLS]
    CSTRING rsi, "_abc_negative_cache"
    call abc_fresh_set
    ERR_NULL .ai_fail
    mov rdi, [rbp - AI_CLS]
    CSTRING rsi, "_abc_negative_cache_version"
    mov rdx, [rel abc_invalidation_counter]
    V_PACK_I64 rdx, rcx
    call abc_state_set
    ERR_M1 .ai_fail

    mov rdi, [rbp - AI_CLS]
    call abc_compute_abstracts
    ERR_M1 .ai_fail

    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.bad:
    SET_EXC exc_TypeError_type, "_abc_init() requires a class"
.ai_fail:
    xor eax, eax
    leave
    ret
END_FUNC abc_init_func

;; ============================================================================
;; abc_call_issubclass(rdi = sub, rsi = parent) -> eax 0/1, -1 on error
;; The builtin, so a registered class that is itself an ABC gets its own
;; __subclasscheck__ consulted.
;; ============================================================================
DEF_FUNC_LOCAL abc_call_issubclass, 24
    push rbx
    sub rsp, 16
    mov [rsp], rdi
    mov [rsp + 8], rsi
    extern builtin_issubclass
    mov rdi, rsp
    mov esi, 2
    call builtin_issubclass     ; err: .err, two lines down
    add rsp, 16
    test rax, rax
    jz .err
    mov rbx, rax
    mov rdi, rax
    call obj_is_true            ; err: a bool, straight from the builtin
    mov rdi, rbx
    mov ebx, eax
    call obj_decref
    mov eax, ebx
    pop rbx
    leave
    ret
.err:
    mov eax, -1
    pop rbx
    leave
    ret
END_FUNC abc_call_issubclass

;; ============================================================================
;; abc_subclasscheck(rdi = cls, rsi = subclass) -> eax 1 yes / 0 no / -1 error
;; Modules/_abc.c, _abc__abc_subclasscheck_impl.
;; ============================================================================
SC_CLS    equ 8
SC_SUB    equ 16
SC_CACHE  equ 24
SC_NEG    equ 32
SC_HOOK   equ 40
SC_IDX    equ 48
SC_REG    equ 56
SC_FRAME  equ 64            ; + 2 pushes = 80
DEF_FUNC abc_subclasscheck, SC_FRAME
    push rbx
    push r12
    mov [rbp - SC_CLS], rdi
    mov [rbp - SC_SUB], rsi

    ; 1. the positive cache
    CSTRING rsi, "_abc_cache"
    call abc_state_get
    mov [rbp - SC_CACHE], rax
    test rax, rax
    jz .no_state
    mov rdi, rax
    mov rsi, [rbp - SC_SUB]
    push rdi
    mov rdi, rsi
    call abc_ref                ; what the set holds: a weak reference
    pop rdi
    push rax
    mov rsi, rax
    call set_contains
    ERR_M1 .error_ref
    push rax
    mov rdi, [rsp + 8]
    call obj_decref
    pop rax
    add rsp, 8
    test eax, eax
    jnz .yes

    ; 2. the negative cache, invalidated when the token has moved on
    mov rdi, [rbp - SC_CLS]
    CSTRING rsi, "_abc_negative_cache_version"
    call abc_state_get
    V_TO_I64 rax
    cmp rax, [rel abc_invalidation_counter]
    jge .neg_current
    mov rdi, [rbp - SC_CLS]
    CSTRING rsi, "_abc_negative_cache"
    call abc_fresh_set
    ERR_NULL .error
    mov [rbp - SC_NEG], rax
    mov rdi, [rbp - SC_CLS]
    CSTRING rsi, "_abc_negative_cache_version"
    mov rdx, [rel abc_invalidation_counter]
    V_PACK_I64 rdx, rcx
    call abc_state_set
    ERR_M1 .error
    jmp .hook

.neg_current:
    mov rdi, [rbp - SC_CLS]
    CSTRING rsi, "_abc_negative_cache"
    call abc_state_get
    mov [rbp - SC_NEG], rax
    test rax, rax
    jz .hook
    mov rdi, rax
    mov rsi, [rbp - SC_SUB]
    push rdi
    mov rdi, rsi
    call abc_ref
    pop rdi
    push rax
    mov rsi, rax
    call set_contains
    ERR_M1 .error_ref
    push rax
    mov rdi, [rsp + 8]
    call obj_decref
    pop rax
    add rsp, 8
    test eax, eax
    jnz .no

.hook:
    ; 3. __subclasshook__, which is where the structural ABCs answer
    CSTRING rdi, "__subclasshook__"
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, [rbp - SC_CLS]
    mov rsi, rbx
    call type_getattr
    mov r12, rax
    mov rdi, rbx
    call obj_decref
    mov rax, r12
    test rax, rax
    jz .mro
    mov [rbp - SC_HOOK], rax

    V_TEST_PTR rax, rcx
    ja .mro                     ; not callable; fall through to the MRO check
    ; type_getattr hands back what is in the dict, wrappers included, and
    ; __subclasshook__ is always a classmethod -- unwrap it and pass the
    ; class explicitly, which is what binding would have done.
    mov rcx, [rax + PyObject.ob_type]
    extern classmethod_type
    lea rdx, [rel classmethod_type]
    cmp rcx, rdx
    jne .hook_plain
    mov rdx, [rax + PyClassMethodObject.cm_callable]
    test rdx, rdx
    jz .hook_release
    mov rcx, [rdx + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .hook_release
    sub rsp, 16
    mov rax, [rbp - SC_CLS]
    mov [rsp], rax
    mov rax, [rbp - SC_SUB]
    mov [rsp + 8], rax
    mov rdi, rdx
    mov rsi, rsp
    mov edx, 2
    call rcx
    add rsp, 16
    jmp .hook_have_result
.hook_plain:
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .hook_release
    sub rsp, 16
    mov rax, [rbp - SC_SUB]
    mov [rsp], rax
    mov rdi, [rbp - SC_HOOK]
    mov rsi, rsp
    mov edx, 1
    call rcx
    add rsp, 16
.hook_have_result:
    mov rbx, rax                ; rbx = the hook's result
    mov rdi, [rbp - SC_HOOK]
    call obj_decref
    mov qword [rbp - SC_HOOK], 0
    test rbx, rbx
    jz .error

    lea rax, [rel notimpl_singleton]
    cmp rbx, rax
    je .hook_undecided
    mov rdi, rbx
    call obj_is_true            ; err: tested as r12 below, once the answer is released
    mov r12, rax
    mov rdi, rbx
    call obj_decref
    cmp r12, -1                 ; never an answer: its __bool__ raised
    je .error
    test r12d, r12d
    jz .cache_no
    jmp .cache_yes

.hook_undecided:
    mov rdi, rbx
    call obj_decref
    jmp .mro

.hook_release:
    mov rdi, [rbp - SC_HOOK]
    call obj_decref

.mro:
    ; 4. an ordinary subclass, found by walking the MRO
    mov rdi, [rbp - SC_SUB]
    mov rsi, [rbp - SC_CLS]
    call type_is_subtype
    test eax, eax
    jnz .cache_yes

    ; 5. a subclass of something registered
    mov rdi, [rbp - SC_CLS]
    CSTRING rsi, "_abc_registry"
    call abc_state_get
    test rax, rax
    jz .subclasses
    mov [rbp - SC_REG], rax
    mov qword [rbp - SC_IDX], 0
.reg_loop:
    mov rax, [rbp - SC_REG]
    mov rcx, [rbp - SC_IDX]
    cmp rcx, [rax + PyDictObject.capacity]
    jge .subclasses
    mov rdx, [rax + PyDictObject.entries]
    shl rcx, 4                  ; SET_ENTRY_SIZE
    mov rdi, [rdx + rcx + 8]    ; the entry's key Value (hash sits at +0)
    inc qword [rbp - SC_IDX]
    V_TEST_PTR rdi, rax
    ja .reg_loop
    test rdi, rdi
    jz .reg_loop
    call abc_deref              ; a weak reference, unless it could not be one
    test rax, rax
    jz .reg_loop                ; the registered class has been collected
    mov rsi, rax                ; the registered class
    mov rdi, [rbp - SC_SUB]
    call abc_call_issubclass
    cmp eax, -1
    je .error
    test eax, eax
    jz .reg_loop
    jmp .cache_yes

.subclasses:
    ; 6. a subclass of one of THIS class's subclasses.  A registration made
    ; against a subclass of the ABC counts for the ABC too, and this is the
    ; only step that can find it: without it, `B.register(X)` for a B deriving
    ; from A left issubclass(X, A) answering False.  It was missing because
    ; nothing kept a list of subclasses; type.__subclasses__ does now.
    mov rdi, [rbp - SC_CLS]
    call sub_list_for_type
    test rax, rax
    jz .cache_no
    mov [rbp - SC_REG], rax     ; the SubList, reusing the registry slot
    mov qword [rbp - SC_IDX], 0
.sub_loop:
    mov rax, [rbp - SC_REG]
    mov rcx, [rbp - SC_IDX]
    cmp rcx, [rax + SubList.count]
    jge .cache_no
    mov rdx, [rax + SubList.items]
    mov rsi, [rdx + rcx*8]
    inc qword [rbp - SC_IDX]
    cmp rsi, [rbp - SC_CLS]
    je .sub_loop                ; not itself, or the recursion never ends
    mov rdi, [rbp - SC_SUB]
    call abc_call_issubclass
    cmp eax, -1
    je .error
    test eax, eax
    jz .sub_loop
    jmp .cache_yes

.cache_yes:
    mov rdi, [rbp - SC_CACHE]
    test rdi, rdi
    jz .yes
    push rdi
    mov rdi, [rbp - SC_SUB]
    call abc_ref
    pop rdi
    push rax
    mov rsi, rax
    call set_add
    ERR_M1 .error_ref
    pop rdi
    call obj_decref
.yes:
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret

.cache_no:
    mov rdi, [rbp - SC_NEG]
    test rdi, rdi
    jz .no
    push rdi
    mov rdi, [rbp - SC_SUB]
    call abc_ref
    pop rdi
    push rax
    mov rsi, rax
    call set_add
    ERR_M1 .error_ref
    pop rdi
    call obj_decref
.no:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.no_state:
    ; Not initialised as an ABC: fall back to plain inheritance.
    mov rdi, [rbp - SC_SUB]
    mov rsi, [rbp - SC_CLS]
    call type_is_subtype
    pop r12
    pop rbx
    leave
    ret

.error_ref:
    ; Comparing the weak reference with what a cache already holds ran a
    ; class's __eq__, and it raised.  The reference is on top of the stack.
    pop rdi
    call obj_decref
.error:
    mov eax, -1
    pop r12
    pop rbx
    leave
    ret
END_FUNC abc_subclasscheck

;; ============================================================================
;; _abc_subclasscheck(cls, subclass) -> bool
;; Fails: 0
;;
;; Exactly two arguments, and both classes: the walk below reads tp_dict and
;; the MRO off each.  It took "at least two", so a longer call was accepted,
;; and it asked neither argument what it was.
;; ============================================================================
SCF_FRAME equ 8             ; + 1 push = 16, 16-aligned
DEF_FUNC abc_subclasscheck_func, SCF_FRAME
    push rbx
    cmp rsi, 2
    jne .bad
    mov rbx, rdi                ; args
    mov rdi, [rbx]
    call abc_require_class
    ERR_NULL .propagate
    mov rdi, [rbx + 8]
    call type_check_is_class
    test eax, eax
    jz .not_a_class
    mov rdi, [rbx]
    mov rsi, [rbx + 8]
    call abc_subclasscheck
    cmp eax, -1
    je .propagate
    test eax, eax
    jz .false
    lea rax, [rel bool_true]
    INCREF rax
    pop rbx
    leave
    ret
.false:
    lea rax, [rel bool_false]
    INCREF rax
    pop rbx
    leave
    ret
.propagate:
    xor eax, eax
    pop rbx
    leave
    ret
.not_a_class:
    FAIL exc_TypeError_type, "issubclass() arg 1 must be a class", .propagate
.bad:
    CSTRING rdi, "_abc_subclasscheck expected 2 arguments, got "
    xor edx, edx                ; rsi is still the count
    call set_type_error_counted
    jmp .propagate
END_FUNC abc_subclasscheck_func

;; ============================================================================
;; type_abstract_error(rdi = the type, rsi = its __abstractmethods__ set)
;;   -> rax = 0, always, with the TypeError pending
;;
;; "Can't instantiate abstract class Shape without an implementation for
;;  abstract methods 'area', 'perimeter'" -- CPython's wording, with the
;; names sorted and the noun agreeing with how many there are.  It used to
;; say only "Can't instantiate abstract class with abstract methods", which
;; names neither the class nor what is missing, and those are the two things
;; the reader needs.
;; ============================================================================
TAE_NAMES equ 12 * 8        ; the sorted keys, up to TAE_MAX of them
TAE_COUNT equ TAE_NAMES + 8
TAE_BUF   equ TAE_COUNT + 8 + 1024
TAE_FRAME equ TAE_BUF       ; + 3 pushes = TAE_BUF + 24
TAE_MAX   equ 12

global type_abstract_error
DEF_FUNC type_abstract_error, TAE_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi                ; the type
    mov r12, rsi                ; the set

    ; --- collect the keys, up to TAE_MAX of them ---
    xor r13d, r13d              ; how many collected
    mov rcx, [r12 + PyDictObject.entries]
    xor r8d, r8d                ; the slot index
.tae_scan:
    cmp r8, [r12 + PyDictObject.capacity]
    jge .tae_sort
    cmp r13, TAE_MAX
    jge .tae_sort
    mov rax, r8
    shl rax, 4                  ; SET_ENTRY_SIZE
    mov rdx, [rcx + rax + SET_ENTRY_KEY]
    test rdx, rdx
    jz .tae_scan_next
    mov rax, r13
    shl rax, 3
    lea r9, [rbp - TAE_NAMES]
    mov [r9 + rax], rdx
    inc r13
.tae_scan_next:
    inc r8
    jmp .tae_scan

    ; --- insertion sort, by the bytes of the names ---
.tae_sort:
    mov [rbp - TAE_COUNT], r13
    cmp r13, 2
    jl .tae_build
    mov r8d, 1                      ; i
.tae_sort_outer:
    cmp r8, r13
    jge .tae_build
    mov r9, r8                  ; j
.tae_sort_inner:
    test r9, r9
    jz .tae_sort_next
    lea rcx, [rbp - TAE_NAMES]
    mov rax, r9
    shl rax, 3
    mov rdi, [rcx + rax]
    mov rsi, [rcx + rax - 8]
    add rdi, PyStrObject.data
    add rsi, PyStrObject.data
    push r8
    push r9
    call ap_strcmp
    pop r9
    pop r8
    test eax, eax
    jge .tae_sort_next
    lea rcx, [rbp - TAE_NAMES]
    mov rax, r9
    shl rax, 3
    mov rdi, [rcx + rax]
    mov rsi, [rcx + rax - 8]
    mov [rcx + rax], rsi
    mov [rcx + rax - 8], rdi
    dec r9
    jmp .tae_sort_inner
.tae_sort_next:
    inc r8
    jmp .tae_sort_outer

    ; --- build the message ---
.tae_build:
    lea rdi, [rbp - TAE_BUF]
    lea rsi, [rel tae_prefix]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbx + PyTypeObject.tp_name]
    call rbt_append_cstr
    mov rdi, rax
    mov r13, [rbp - TAE_COUNT]
    test r13, r13
    jz .tae_raise               ; nothing to name: keep the short form
    cmp r13, 1
    je .tae_singular
    lea rsi, [rel tae_plural]
    jmp .tae_middle
.tae_singular:
    lea rsi, [rel tae_singular_s]
.tae_middle:
    call rbt_append_cstr
    mov rdi, rax

    xor r12d, r12d              ; the index
.tae_names_loop:
    cmp r12, r13
    jge .tae_raise
    test r12, r12
    jz .tae_no_comma
    lea rsi, [rel tae_comma]
    call rbt_append_cstr
    mov rdi, rax
.tae_no_comma:
    lea rsi, [rel tae_quote]
    call rbt_append_cstr
    mov rdi, rax
    lea rcx, [rbp - TAE_NAMES]
    mov rax, r12
    shl rax, 3
    mov rsi, [rcx + rax]
    add rsi, PyStrObject.data
    push r12
    push r13
    call rbt_append_cstr
    pop r13
    pop r12
    mov rdi, rax
    lea rsi, [rel tae_quote]
    call rbt_append_cstr
    mov rdi, rax
    inc r12
    jmp .tae_names_loop

.tae_raise:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - TAE_BUF]
    call set_exception
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_abstract_error


;; ============================================================================
;; _abc_instancecheck(cls, instance) -> bool
;; Fails: 0
;;
;; CPython consults instance.__class__ as well as type(instance), so that an
;; object which lies about its class is believed -- which is most of what a
;; mock is for.  This used to check only the type, on the grounds that
;; nothing here could lie; a property named __class__ has been able to for a
;; while, and isinstance() of such an object answered by what it really was.
;;
;; The declared class is asked first, as CPython asks it, and the real type
;; only if the two differ and the first said no.
;; ============================================================================
IC_CLS   equ 8
IC_SUB   equ 16
IC_INST  equ 24
IC_DECL  equ 32             ; instance.__class__, when it is a class and differs
IC_FRAME equ 32             ; + 0 pushes = 32, 16-aligned
DEF_FUNC abc_instancecheck_func, IC_FRAME
    cmp rsi, 2
    jne .bad
    mov rax, [rdi]
    mov [rbp - IC_CLS], rax
    mov rax, [rdi + 8]
    mov [rbp - IC_INST], rax
    mov qword [rbp - IC_DECL], 0
    mov rdi, [rbp - IC_CLS]
    call abc_require_class      ; the cache below is read off its tp_dict
    ERR_NULL .propagate
    mov rdi, [rbp - IC_INST]
    call value_type
    mov [rbp - IC_SUB], rax
    mov qword [rbp - IC_DECL], 0

    ; instance.__class__, if it is a class and is not simply the type again.
    lea rdi, [rel ic_class_attr]
    extern dunder_name_obj
    call dunder_name_obj        ; borrowed, interned by literal
    mov rsi, rax
    mov rdi, [rbp - IC_INST]
    extern obj_getattr_opt
    call obj_getattr_opt
    test rax, rax
    jz .ic_no_declared
    push rax
    mov rdi, rax
    call type_check_is_class
    pop rdi
    test eax, eax
    jz .ic_drop_declared
    cmp rdi, [rbp - IC_SUB]
    je .ic_drop_declared        ; the same answer, so one check does
    mov [rbp - IC_DECL], rdi
    jmp .ic_have_declared
.ic_drop_declared:
    call obj_decref
.ic_no_declared:
.ic_have_declared:

    mov rdi, [rbp - IC_CLS]
    CSTRING rsi, "_abc_cache"
    call abc_state_get
    test rax, rax
    jz .full
    mov rdi, rax
    mov rsi, [rbp - IC_SUB]
    push rdi
    mov rdi, rsi
    call abc_ref
    pop rdi
    push rax
    mov rsi, rax
    call set_contains
    ERR_M1 .propagate_ref
    push rax
    mov rdi, [rsp + 8]
    call obj_decref
    pop rax
    add rsp, 8
    test eax, eax
    jnz .true

.full:
    ; The declared class first, when there is one to ask.
    cmp qword [rbp - IC_DECL], 0
    je .ic_check_type
    mov rdi, [rbp - IC_CLS]
    mov rsi, [rbp - IC_DECL]
    call abc_subclasscheck
    cmp eax, -1
    je .propagate
    test eax, eax
    jnz .true

.ic_check_type:
    mov rdi, [rbp - IC_CLS]
    mov rsi, [rbp - IC_SUB]
    call abc_subclasscheck
    cmp eax, -1
    je .propagate
    test eax, eax
    jz .false
.true:
    call .ic_release_declared
    lea rax, [rel bool_true]
    INCREF rax
    leave
    ret
.false:
    call .ic_release_declared
    lea rax, [rel bool_false]
    INCREF rax
    leave
    ret
.propagate_ref:
    pop rdi                     ; the weak reference being looked up
    call obj_decref
.propagate:
    call .ic_release_declared
    xor eax, eax
    leave
    ret
.ic_release_declared:
    mov rdi, [rbp - IC_DECL]
    test rdi, rdi
    jz .ic_nothing
    mov qword [rbp - IC_DECL], 0
    jmp obj_decref
.ic_nothing:
    ret
.bad:
    CSTRING rdi, "_abc_instancecheck expected 2 arguments, got "
    xor edx, edx                ; rsi is still the count
    call set_type_error_counted
    leave
    ret
END_FUNC abc_instancecheck_func

;; ============================================================================
;; _abc_register(cls, subclass) -> subclass
;; Fails: 0
;; ============================================================================
RG_CLS   equ 8
RG_SUB   equ 16
RG_FRAME equ 16             ; + 0 pushes = 16
DEF_FUNC abc_register_func, RG_FRAME
    cmp rsi, 2
    jne .bad
    mov rax, [rdi]
    mov [rbp - RG_CLS], rax
    mov rax, [rdi + 8]
    mov [rbp - RG_SUB], rax
    ; The ABC has to be a class too: it is the second argument of the
    ; issubclass() below, and CPython's refusal is that call's.
    mov rdi, [rbp - RG_CLS]
    call type_check_is_class
    test eax, eax
    jz .abc_not_a_class
    mov rdi, [rbp - RG_SUB]
    call type_check_is_class
    test eax, eax
    jz .not_a_class

    ; Already a subclass?  Registering is then a no-op.
    mov rdi, [rbp - RG_SUB]
    mov rsi, [rbp - RG_CLS]
    call type_is_subtype
    test eax, eax
    jnz .done

    ; The other way round would make an inheritance cycle.
    mov rdi, [rbp - RG_CLS]
    mov rsi, [rbp - RG_SUB]
    call type_is_subtype
    test eax, eax
    jnz .cycle

    mov rdi, [rbp - RG_CLS]
    CSTRING rsi, "_abc_registry"
    call abc_state_get
    test rax, rax
    jz .done
    mov rdi, rax
    push rdi
    mov rdi, [rbp - RG_SUB]
    call abc_ref
    pop rdi
    push rax
    mov rsi, rax
    call set_add
    ERR_M1 .raised_ref
    pop rdi
    call obj_decref
    inc qword [rel abc_invalidation_counter]

.done:
    mov rax, [rbp - RG_SUB]
    mov rdi, rax
    call obj_incref
    mov rax, [rbp - RG_SUB]
    leave
    ret
.raised_ref:
    pop rdi                     ; the weak reference being added
    call obj_decref
    xor eax, eax
    leave
    ret
.not_a_class:
    SET_EXC exc_TypeError_type, "Can only register classes"
    leave
    ret
.cycle:
    SET_EXC exc_RuntimeError_type, "Refusing to create an inheritance cycle"
    leave
    ret
.abc_not_a_class:
    SET_EXC exc_TypeError_type, \
        "issubclass() arg 2 must be a class, a tuple of classes, or a union"
    leave
    ret
.bad:
    CSTRING rdi, "_abc_register expected 2 arguments, got "
    xor edx, edx                ; rsi is still the count
    call set_type_error_counted
    leave
    ret
END_FUNC abc_register_func

;; ============================================================================
;; _get_dump(cls) -> (registry, cache, negative_cache, negative_cache_version)
;; Fails: 0
;; ============================================================================
GD_CLS   equ 8
GD_TUP   equ 16
GD_FRAME equ 16             ; + 0 pushes = 16
DEF_FUNC abc_get_dump_func, GD_FRAME
    CSTRING rdx, "_abc._get_dump() takes no keyword arguments"
    CSTRING rcx, "_abc._get_dump() takes exactly one argument ("
    call abc_class_arg
    ERR_NULL .fail
    mov [rbp - GD_CLS], rax
    mov edi, 4
    call tuple_new
    mov [rbp - GD_TUP], rax

    %macro GD_SLOT 2
    mov rdi, [rbp - GD_CLS]
    CSTRING rsi, %2
    call abc_state_get
    test rax, rax
    jnz %%have
    lea rax, [rel none_singleton]
    %%have:
    INCREF_V rax, rcx
    mov rcx, [rbp - GD_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + %1 * 8], rax
    %endmacro

    GD_SLOT 0, "_abc_registry"
    GD_SLOT 1, "_abc_cache"
    GD_SLOT 2, "_abc_negative_cache"
    GD_SLOT 3, "_abc_negative_cache_version"

    mov rax, [rbp - GD_TUP]
    leave
    ret
.fail:
    xor eax, eax
    leave
    ret
END_FUNC abc_get_dump_func

;; ============================================================================
;; _reset_registry(cls) -> None
;; Fails: 0
;; ============================================================================
DEF_FUNC abc_reset_registry_func
    CSTRING rdx, "_abc._reset_registry() takes no keyword arguments"
    CSTRING rcx, "_abc._reset_registry() takes exactly one argument ("
    call abc_class_arg
    ERR_NULL .fail
    mov rdi, rax
    CSTRING rsi, "_abc_registry"
    call abc_fresh_set
    ERR_NULL .fail
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.fail:
    xor eax, eax
    leave
    ret
END_FUNC abc_reset_registry_func

;; ============================================================================
;; _reset_caches(cls) -> None
;; Fails: 0
;; ============================================================================
RC_CLS   equ 8
RC_FRAME equ 16             ; + 0 pushes = 16
DEF_FUNC abc_reset_caches_func, RC_FRAME
    CSTRING rdx, "_abc._reset_caches() takes no keyword arguments"
    CSTRING rcx, "_abc._reset_caches() takes exactly one argument ("
    call abc_class_arg
    ERR_NULL .fail
    mov [rbp - RC_CLS], rax
    mov rdi, rax
    CSTRING rsi, "_abc_cache"
    call abc_fresh_set
    ERR_NULL .fail
    mov rdi, [rbp - RC_CLS]
    CSTRING rsi, "_abc_negative_cache"
    call abc_fresh_set
    ERR_NULL .fail
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.fail:
    xor eax, eax
    leave
    ret
END_FUNC abc_reset_caches_func

;; ============================================================================
;; Module construction
;; ============================================================================

ABC_FRAME equ 16            ; + 2 pushes = 32, 16-aligned
DEF_FUNC abc_module_create, ABC_FRAME
    push rbx
    push r12

    call dict_new
    mov r12, rax

    MODULE_ADD_FUNC abc_get_cache_token,      abcm_get_cache_token
    MODULE_ADD_FUNC abc_init_func,            abcm_abc_init
    MODULE_ADD_FUNC abc_register_func,        abcm_abc_register
    MODULE_ADD_FUNC abc_instancecheck_func,   abcm_abc_instancecheck
    MODULE_ADD_FUNC abc_subclasscheck_func,   abcm_abc_subclasscheck
    MODULE_ADD_FUNC abc_get_dump_func,        abcm_get_dump
    MODULE_ADD_FUNC abc_reset_registry_func,  abcm_reset_registry
    MODULE_ADD_FUNC abc_reset_caches_func,    abcm_reset_caches

    lea rdi, [rel abcm_name]
    call str_from_cstr_heap
    push rax
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov rbx, rax
    pop rdi
    call obj_decref
    mov rdi, r12
    call obj_decref
    mov rax, rbx

    pop r12
    pop rbx
    leave
    ret
END_FUNC abc_module_create

section .data
align 8
abc_invalidation_counter: dq 0

section .rodata
abcm_name:                 db "_abc", 0
abcm_get_cache_token:      db "get_cache_token", 0
abcm_abc_init:             db "_abc_init", 0
abcm_abc_register:         db "_abc_register", 0
abcm_abc_instancecheck:    db "_abc_instancecheck", 0
ic_class_attr:             db "__class__", 0
abcm_abc_subclasscheck:    db "_abc_subclasscheck", 0
abcm_get_dump:             db "_get_dump", 0
abcm_reset_registry:       db "_reset_registry", 0
abcm_reset_caches:         db "_reset_caches", 0

tae_prefix:     db "Can't instantiate abstract class ", 0
tae_singular_s: db " without an implementation for abstract method ", 0
tae_plural:     db " without an implementation for abstract methods ", 0
tae_comma:      db ", ", 0
tae_quote:      db "'", 0
