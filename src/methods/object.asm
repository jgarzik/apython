; methods/object.asm - object's own dunders, and the slot-backed ones
;
; object.__init__/__str__/__repr__/__format__ and friends, plus the three
; DEF_DUNDER_* macros that generate __len__, __iter__, __str__ and __repr__
; for six builtin types at once.  Those stay together: one block generates
; methods for str, bytes, int, float, dict, list, tuple and set, so it cannot
; be distributed by type.
;
; Methods are registered into each type's tp_dict by methods_init, in
; methods_init.asm.  A method is name(PyObject *self, PyObject **args,
; int64_t nargs); args are borrowed, the result is a new reference.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

; External functions
extern frozenset_type
extern current_exception
extern int_is_integer
extern complex_type
extern obj_decref
extern obj_repr
extern obj_str
extern str_type
extern dict_set
extern dict_del
extern none_singleton
extern bool_true
extern bool_false
extern int_from_i64
extern raise_exception
extern exc_TypeError_type
extern int_type
extern obj_is_true
extern notimpl_singleton
extern dict_type
extern list_type
extern obj_dealloc
extern tuple_type

; Set entry layout constants (must match set.asm)

; --- moved to a sibling file by the split ---

extern bytes_type
extern bytearray_type

extern float_type

extern set_type

section .text

;; ============================================================================
;; object.__init__ / __str__ / __repr__
;;
;; object_type.tp_dict held only __new__.  types.py builds its type zoo out of
;; `type(object.__init__)` and `type(object().__str__)`, so these have to be
;; reachable before it can import -- and `super().__init__()` in a class that
;; derives straight from object needs the first one anyway.

;; ============================================================================
;; scalar_dunder_new(args, nargs) -> Value   -- int.__new__ / str.__new__
;;
;; `int.__new__(cls, v)` builds an instance of cls carrying v, WITHOUT going
;; back through cls.__new__.  That distinction is the whole reason it has to
;; exist: enum makes each member with `member_type.__new__(cls, *args)` where
;; cls is the enum class, whose own __new__ is what is calling this.
;;
;; It also has to be findable: enum decides which base is the "data type" by
;; asking whether __new__ or __init__ is in that base's __dict__, and int and
;; str had neither.
;; ============================================================================
extern int_sub_new
extern str_sub_new
DEF_FUNC scalar_dunder_new
    push rbx
    push r12
    test rsi, rsi
    jz .sdn_bad
    mov rbx, [rdi]                      ; cls
    lea r12, [rdi + 8]                  ; the rest of the arguments
    dec rsi
    V_TEST_PTR rbx, rax
    ja .sdn_bad

    mov rax, [rbx + PyTypeObject.tp_flags]
    lea rcx, [rel int_type]
    cmp rbx, rcx
    je .sdn_int
    test rax, TYPE_FLAG_INT_SUBCLASS
    jnz .sdn_int
    lea rcx, [rel str_type]
    cmp rbx, rcx
    je .sdn_str
    test rax, TYPE_FLAG_STR_SUBCLASS
    jnz .sdn_str
    extern float_type
    lea rcx, [rel float_type]
    cmp rbx, rcx
    je .sdn_float
    test rax, TYPE_FLAG_FLOAT_SUBCLASS
    jnz .sdn_float
    extern complex_type
    lea rcx, [rel complex_type]
    cmp rbx, rcx
    je .sdn_complex
    test rax, TYPE_FLAG_COMPLEX_SUBCLASS
    jnz .sdn_complex
    jmp .sdn_bad

.sdn_int:
    mov rdi, rbx
    mov rdx, rsi
    mov rsi, r12
    call int_sub_new
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.sdn_str:
    ; str.__new__(str) is a plain str, not a subclass instance.  str_sub_new
    ; allocates through gc_alloc and appends a tail __dict__ word; handing
    ; that object str_type meant str_dealloc freed it with ap_free, and
    ; `str.__new__(str)` aborted with "double free or corruption".
    lea rcx, [rel str_type]
    cmp rbx, rcx
    jne .sdn_str_sub
    mov rdi, r12
    mov rsi, rsi                ; the argument count, less the class
    extern builtin_str_fn
    call builtin_str_fn
    pop r12
    pop rbx
    leave
    ret
.sdn_str_sub:
    mov rdi, rbx
    mov rdx, rsi
    mov rsi, r12
    call str_sub_new
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

;; float and complex have constructors that already read the type they are
;; handed, so the subclass arm is the same call as the base one.  Both return
;; a fat pair, which the V_PACK below is exactly right for.
.sdn_float:
    extern float_type_call
    mov rdi, rbx
    mov rdx, rsi
    mov rsi, r12
    call float_type_call
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.sdn_complex:
    extern complex_type_call
    mov rdi, rbx
    mov rdx, rsi
    mov rsi, r12
    call complex_type_call
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.sdn_bad:
    RAISE exc_TypeError_type, "__new__() argument 1 must be a subclass of int or str"
END_FUNC scalar_dunder_new

;; ============================================================================
;; ============================================================================
;; builtin_method_format(self, format_spec) -- __format__ for the four types
;; the spec mini-language knows how to render itself.
;;
;; CPython gives int, float, str and complex a __format__ of their own, and a
;; subclass inherits it.  Without one, `class F(float)` inherited OBJECT's,
;; which refuses any non-empty spec: format(F(2.5), ".2f") was "unsupported
;; format string passed to object.__format__".
;; ============================================================================
extern format_apply_spec

DEF_FUNC builtin_method_format
    cmp rsi, 2
    jne .bmf_bad
    mov rax, [rdi + 8]                  ; the format spec
    V_TEST_PTR rax, rcx
    ja .bmf_bad_spec
    test rax, rax
    jz .bmf_bad_spec
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .bmf_bad_spec
    mov rsi, rax
    mov rdi, [rdi]
    call format_apply_spec
    leave
    ret
.bmf_bad:
    RAISE exc_TypeError_type, "__format__() takes exactly one argument"
.bmf_bad_spec:
    RAISE exc_TypeError_type, "__format__() argument must be str"
END_FUNC builtin_method_format

;; object.__format__(self, format_spec)
;;
;; An empty spec is str(self); anything else is an error, because object has no
;; formatting of its own to apply.  enum reaches for this by name when it
;; decides whether a mixin overrode it.
;; ============================================================================
DEF_FUNC object_method_format
    cmp rsi, 2
    jne .omf_bad
    mov rax, [rdi + 8]                  ; the format spec
    V_TEST_PTR rax, rcx
    ja .omf_bad_spec
    test rax, rax
    jz .omf_bad_spec
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .omf_bad_spec
    cmp qword [rax + PyStrObject.ob_size], 0
    jne .omf_unsupported
    mov rdi, [rdi]
    call obj_str
    leave
    ret
.omf_bad:
    RAISE exc_TypeError_type, "__format__() takes exactly one argument"
.omf_bad_spec:
    RAISE exc_TypeError_type, "__format__() argument must be str"
.omf_unsupported:
    RAISE exc_TypeError_type, "unsupported format string passed to object.__format__"
END_FUNC object_method_format

;; ============================================================================
;; object.__sizeof__(self) -> the type's tp_basicsize
;; ============================================================================
DEF_FUNC object_method_sizeof
    mov rax, [rdi]
    V_TEST_PTR rax, rcx
    ja .oso_zero
    test rax, rax
    jz .oso_zero
    mov rax, [rax + PyObject.ob_type]
    mov rdi, [rax + PyTypeObject.tp_basicsize]
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
.oso_zero:
    xor edi, edi
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
END_FUNC object_method_sizeof

;; ============================================================================
;; object.__dir__(self) -> the names its type and instance dict carry
;;
;; The default walk, and only that: dir() is what asks for __dir__ in the
;; first place, so calling it back from here made the pair circular and left
;; neither of them asking the object anything.
;; ============================================================================
DEF_FUNC object_method_dir
    extern dir_default
    mov rdi, [rdi]              ; args[0] = self, a Value
    call dir_default
    leave
    ret
END_FUNC object_method_dir

;; ============================================================================
;; object.__reduce_ex__(self, protocol) / object.__reduce__(self)
;;   -> rax = the reduction tuple, as a Value
;;
;; Delegated to lib/_reduce.py, which is where CPython's Python half of this
;; lives -- and where the protocol-2 half CPython writes in C has been written
;; to join it.  Assembling a
;; five-tuple here would mean calling back into Python for
;; __getnewargs_ex__, __getstate__ and the list/dict iterators anyway, and a
;; reduction assembled wrongly does not fail: it makes a pickle that
;; unpickles into the wrong object.
;;
;; This used to raise.  `copy.copy(x)` for an ordinary instance is
;; `cls.__reduce_ex__(x, 4)` and nothing else, so copy, deepcopy and every
;; pickle of a plain object were a TypeError -- which is what stopped
;; tarfile, whose addfile() copies its TarInfo.
;;
;; object.__reduce__(self) is protocol 0, as CPython's is.
;; ============================================================================
ORX_ARGS  equ 16            ; two Values: args[0] = self, args[1] = protocol
ORX_FN    equ 24
ORX_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC object_method_reduce, ORX_FRAME
    test rsi, rsi
    jz .orx_nargs
    mov rax, [rdi]
    mov [rbp - ORX_ARGS], rax   ; args[0] = self
    xor eax, eax
    cmp rsi, 2
    jb .orx_have_proto
    push rdi
    sub rsp, 8
    mov rdi, [rdi + 8]
    V_UNPACK rdi, rdx
    extern obj_as_index
    call obj_as_index
    add rsp, 8
    pop rdi
.orx_have_proto:
    push rax
    sub rsp, 8
    mov rdi, rax
    extern int_from_i64
    call int_from_i64
    V_PACK rax, rdx
    add rsp, 8
    add rsp, 8                  ; the pushed protocol is not needed again
    mov [rbp - ORX_ARGS + 8], rax   ; args[1] = the protocol

    call object_reduce_impl
    test rax, rax
    jz .orx_failed
    mov rdi, rax
    lea rsi, [rbp - ORX_ARGS]
    mov edx, 2
    extern obj_call_n
    call obj_call_n
    push rax
    sub rsp, 8
    mov rdi, [rbp - ORX_ARGS + 8]
    DECREF_V rdi, rcx           ; the protocol int, which V_PACK may have boxed
    add rsp, 8
    pop rax
    leave
    ret

.orx_failed:
    RAISE exc_TypeError_type, "cannot pickle this object: _reduce is not available"
.orx_nargs:
    RAISE exc_TypeError_type, "__reduce_ex__() missing self"
END_FUNC object_method_reduce

;; ============================================================================
;; object_reduce_impl() -> rax = _reduce.object_reduce_ex, borrowed, or 0
;;
;; Looked up lazily and cached for the life of the process, the way
;; co_ast_builder caches _ast._from_raw and for the same reason: builtins are
;; built long before the import system can run.
;; ============================================================================
section .data
omr_cached: dq 0
section .rodata
omr_mod:  db "_reduce", 0
omr_attr: db "object_reduce_ex", 0
section .text

ORI_KEY   equ 8
ORI_MOD   equ 16
ORI_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC_LOCAL object_reduce_impl, ORI_FRAME
    mov rax, [rel omr_cached]
    test rax, rax
    jnz .ori_out

    lea rdi, [rel omr_mod]
    extern str_from_cstr_heap
    call str_from_cstr_heap
    mov [rbp - ORI_KEY], rax
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    extern import_module
    call import_module
    mov [rbp - ORI_MOD], rax
    mov rdi, [rbp - ORI_KEY]
    extern obj_decref
    call obj_decref
    mov rax, [rbp - ORI_MOD]
    test rax, rax
    jz .ori_fail

    lea rdi, [rel omr_attr]
    call str_from_cstr_heap
    mov [rbp - ORI_KEY], rax
    mov rdi, [rbp - ORI_MOD]
    mov rdi, [rdi + PyModuleObject.mod_dict]
    mov rsi, rax
    extern dict_get
    call dict_get
    push rax
    mov rdi, [rbp - ORI_KEY]
    call obj_decref
    mov rdi, [rbp - ORI_MOD]
    call obj_decref             ; sys.modules keeps the module alive
    pop rax
    test rax, rax
    jz .ori_fail
    V_UNPACK rax, rdx
    cmp edx, TAG_PTR
    jne .ori_fail
    mov [rel omr_cached], rax   ; borrowed: _reduce stays in sys.modules
.ori_out:
    leave
    ret
.ori_fail:
    xor eax, eax
    leave
    ret
END_FUNC object_reduce_impl

;; ============================================================================
extern str_from_cstr
OMI_SELF  equ 8
OMI_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC object_method_init, OMI_FRAME
    ; object.__init__(self, ...) does nothing -- but it does not accept
    ; anything either.  CPython's object_init refuses excess arguments
    ; unless the other half of the construction is overridden, so a class
    ; that defines neither __new__ nor __init__ cannot be handed any.
    cmp rsi, 1
    jbe .omi_done
    mov rax, [rdi]              ; self, a Value
    V_TEST_PTR rax, rcx
    ja .omi_done
    test rax, rax
    jz .omi_done
    mov rdi, [rax + PyObject.ob_type]
    mov [rbp - OMI_SELF], rdi
    extern init_dunder_cstr
    lea rsi, [rel init_dunder_cstr]
    mov edx, PyTypeObject.tp_init
    extern type_defines_dunder
    call type_defines_dunder
    test eax, eax
    jnz .omi_own_init
    mov rdi, [rbp - OMI_SELF]
    extern new_dunder_cstr
    lea rsi, [rel new_dunder_cstr]
    mov edx, PyTypeObject.tp_new
    call type_defines_dunder
    test eax, eax
    jz .omi_no_args
.omi_done:
    RET_NONE
    leave
    V_PACK rax, rdx
    ret

.omi_own_init:
    RAISE exc_TypeError_type, \
          "object.__init__() takes exactly one argument (the instance to initialize)"
.omi_no_args:
    mov rsi, [rbp - OMI_SELF]
    CSTRING rdi, \
        `\x01.__init__() takes exactly one argument (the instance to initialize)`
    extern raise_type_error_with_typename
    jmp raise_type_error_with_typename
END_FUNC object_method_init

DEF_FUNC object_method_str
    ; object.__str__ defers to __repr__, which is what CPython does.  It must
    ; not call obj_str: that dispatches back to tp_str, which looks up
    ; __str__, which finds this again.
    test rsi, rsi
    jz .oms_bad
    mov rdi, [rdi]
    extern obj_repr
    call obj_repr
    leave
    ret
.oms_bad:
    RAISE exc_TypeError_type, "__str__() takes exactly one argument"
END_FUNC object_method_str

;; object.__repr__ is the *default* implementation, not a re-dispatch: it
;; writes "<Name object>" straight out.  Calling obj_repr here would come
;; back through tp_repr to this same method.
OMR_BUF   equ 136
OMR_FRAME equ 160           ; + 0 pushes = 160
DEF_FUNC object_method_repr, OMR_FRAME
    test rsi, rsi
    jz .omr_bad
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .omr_plain
    test rdi, rdi
    jz .omr_plain
    mov rsi, [rdi + PyObject.ob_type]
    mov rsi, [rsi + PyTypeObject.tp_name]
    test rsi, rsi
    jz .omr_plain

    lea rdi, [rbp - OMR_BUF]
    xor ecx, ecx
    mov byte [rdi], '<'
    inc rcx
.omr_name:
    movzx eax, byte [rsi]
    test al, al
    jz .omr_tail
    inc rsi
    cmp rcx, 100
    jae .omr_tail
    mov [rdi + rcx], al
    inc rcx
    jmp .omr_name
.omr_tail:
    CSTRING rsi, " object>"
.omr_tail_copy:
    movzx eax, byte [rsi]
    test al, al
    jz .omr_emit
    inc rsi
    mov [rdi + rcx], al
    inc rcx
    jmp .omr_tail_copy
.omr_emit:
    mov byte [rdi + rcx], 0
    call str_from_cstr
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.omr_plain:
    CSTRING rdi, "<object>"
    call str_from_cstr
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.omr_bad:
    RAISE exc_TypeError_type, "__repr__() takes exactly one argument"
END_FUNC object_method_repr

;; ============================================================================
;; object.__init_subclass__(cls) -> None
;; A no-op hook every class inherits, so that a real one can end with
;; `super().__init_subclass__()` -- which is how they are written.  Keywords
;; are an error here: whoever declared them should have consumed them.
;; ============================================================================
DEF_FUNC object_method_init_subclass
    cmp rsi, 2
    jge .omis_bad
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.omis_bad:
    RAISE exc_TypeError_type, "__init_subclass__() takes no keyword arguments"
END_FUNC object_method_init_subclass

;; ============================================================================
;; A builtin's own __str__ and __repr__, reachable by name.
;;
;; They were not: `str.__str__` resolved through the MRO to object's, and enum
;; asks precisely that question -- "if member_type.__str__ is object.__str__,
;; use its __repr__ instead" -- so every StrEnum member printed as
;; <Names object>.  The thunk calls the *defining* type's slot, not the
;; argument's, which is what keeps it right on a subclass and out of the
;; recursion a re-dispatch would cause.  An immediate int or float has no
;; ob_type to read a slot from, so it goes through obj_repr, which knows them.
;; ============================================================================
%macro DEF_DUNDER_STRREPR 3     ; %1 = type prefix, %2 = tp_str or tp_repr, %3 = the dunder's own name
DEF_FUNC %1_dunder_%2
    cmp rsi, 1                  ; exactly self; an extra was accepted
    jne %%bad
    mov rdi, [rdi]
    lea rsi, [rel %1_type]
    xor edx, edx
    CSTRING rcx, %3             ; %2 is the slot name, not the dunder's
    extern dunder_require_self
    call dunder_require_self
    mov rdi, rax
    V_TEST_PTR rdi, rax
    ja %%immediate
    test rdi, rdi
    jz %%immediate
    lea rax, [rel %1_type]
    mov rax, [rax + PyTypeObject.tp_%2]
    test rax, rax
    jz %%immediate
    ; int_repr reads edx as the argument's tag, and this one is a pointer.
    mov edx, TAG_PTR
    call rax
    leave
    ret
%%immediate:
    call obj_repr
    leave
    ret
%%bad:
    ; CPython reports both counts, and counts self in neither.
    dec rsi                     ; rsi is still nargs on this path
    xor edi, edi
    xor edx, edx                ; check_num_args' wording, with no gap
    extern raise_wrapper_arity
    call raise_wrapper_arity
END_FUNC %1_dunder_%2
%endmacro

;; A builtin container's __len__ and __iter__, reachable by name.  They were
;; slots and nothing else, so `cache.__len__` -- how functools' lru_cache reads
;; its size without paying for the len() call -- raised AttributeError.  Like
;; the str/repr thunks these read the *defining* type's slot, so a subclass
;; inherits the base's behaviour rather than re-dispatching into itself.
%macro DEF_DUNDER_LEN 1-2 0
DEF_FUNC %1_dunder_len
    cmp rsi, 1                  ; exactly self: an extra argument
    jne %%arity                 ; was silently accepted
    mov rdi, [rdi]
    lea rsi, [rel %1_type]
%ifnum %2
    xor edx, edx
%else
    lea rdx, [rel %2]
%endif
    CSTRING rcx, "__len__"

    extern dunder_require_self
    call dunder_require_self
    mov rdi, rax
    lea rax, [rel %1_type]
    mov rcx, [rax + PyTypeObject.tp_as_mapping]
    test rcx, rcx
    jz %%seq
    mov rcx, [rcx + PyMappingMethods.mp_length]
    test rcx, rcx
    jnz %%have
%%seq:
    mov rcx, [rax + PyTypeObject.tp_as_sequence]
    test rcx, rcx
    jz %%bad
    mov rcx, [rcx + PySequenceMethods.sq_length]
    test rcx, rcx
    jz %%bad
%%have:
    call rcx
    mov edx, TAG_SMALLINT
    leave
    V_PACK rax, rdx
    ret
%%arity:
    dec rsi
    xor edi, edi
    xor edx, edx                ; check_num_args' wording, with no gap
    extern raise_wrapper_arity
    call raise_wrapper_arity
%%bad:
    RAISE exc_TypeError_type, "object has no len()"
END_FUNC %1_dunder_len
%endmacro

;; ============================================================================
;; DEF_DUNDER_CALL type_prefix -- `__call__` in a callable builtin's tp_dict.
;
;; The stdlib asks by NAME.  collections.abc.Callable's __subclasshook__ is
;; _check_methods(C, "__call__"), which walks C.__mro__ looking in each
;; __dict__ -- so a type whose callability lives only in tp_call answered False
;; to isinstance(x, Callable), and every builtin, function and lambda did.
;
;; The thunk calls the DEFINING type's tp_call, captured here, and not the
;; argument's: reading it from the argument would send a subclass that
;; installed slot_tp_call straight back into itself.
;
;; Unlike __iter__ and __len__ this one is variadic.  args[0] is self and the
;; rest are already contiguous behind it, so they forward without a copy, and
;; `len.__call__([1,2,3])` is the same call as `len([1,2,3])`.
;; ============================================================================
DDC_ARGS  equ 8
DDC_N     equ 16
DDC_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
%macro DEF_DUNDER_CALL 1
DEF_FUNC %1_dunder_call, DDC_FRAME
    test rsi, rsi
    jz %%noself
    mov [rbp - DDC_ARGS], rdi
    mov [rbp - DDC_N], rsi

    mov rdi, [rdi]              ; self
    lea rsi, [rel %1_type]
    xor edx, edx
    CSTRING rcx, "__call__"
    extern dunder_require_self
    call dunder_require_self
    mov rdi, rax                ; the receiver, checked

    lea rax, [rel %1_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz %%bad
    mov rsi, [rbp - DDC_ARGS]
    add rsi, 8                  ; the arguments after self
    mov rdx, [rbp - DDC_N]
    dec rdx
    call rax                    ; tp_call already answers one Value
    leave
    ret
%%bad:
    RAISE exc_TypeError_type, "object is not callable"
%%noself:
    xor edi, edi
    xor edx, edx
    mov esi, 1
    extern raise_wrapper_arity
    call raise_wrapper_arity
END_FUNC %1_dunder_call
%endmacro

; The callable builtins.  Every type with a tp_call needs one, or the ABC
; answers False for its instances.
extern method_type
extern func_type
extern builtin_func_type
extern staticmethod_type
extern type_type
DEF_DUNDER_CALL method
DEF_DUNDER_CALL func
DEF_DUNDER_CALL builtin_func
DEF_DUNDER_CALL staticmethod
DEF_DUNDER_CALL type

%macro DEF_DUNDER_ITER 1-2 0
DEF_FUNC %1_dunder_iter
    cmp rsi, 1                  ; exactly self: an extra argument
    jne %%arity                 ; was silently accepted
    mov rdi, [rdi]
    lea rsi, [rel %1_type]
%ifnum %2
    xor edx, edx
%else
    lea rdx, [rel %2]
%endif
    CSTRING rcx, "__iter__"

    extern dunder_require_self
    call dunder_require_self
    mov rdi, rax
    lea rax, [rel %1_type]
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz %%bad
    call rax
    test rax, rax
    jz %%failed
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
%%failed:
    xor eax, eax
    xor edx, edx
    leave
    V_PACK rax, rdx
    ret
%%arity:
    dec rsi
    xor edi, edi
    xor edx, edx                ; check_num_args' wording, with no gap
    extern raise_wrapper_arity
    call raise_wrapper_arity
%%bad:
    RAISE exc_TypeError_type, "object is not iterable"
END_FUNC %1_dunder_iter
%endmacro

; range's type symbol is range_obj_type, so the generators that build
; `%1_type` need the alias.  It is a preprocessor name, not a second symbol.
%define range_type range_obj_type
extern range_obj_type

; list and tuple already have hand-written ones.
DEF_DUNDER_LEN dict
DEF_DUNDER_LEN str
;; ============================================================================
;; DEF_DUNDER_NEXT %1 -- generates %1_dunder_next, the tp_dict entry for
;; %1_type's __next__.  (rdi = args, rsi = nargs) -> rax = a Value
;;
;; The stdlib asks for __next__ by NAME -- heapq.py does `next = it.__next__`
;; at module level -- and a slot with no matching tp_dict entry answers that
;; wrong.  This reads the DEFINING type's tp_iternext, never the argument's,
;; so a subclass that defines __next__ does not re-dispatch into itself.
;;
;; The exhaustion arm is builtin_next_fn's: a NULL from tp_iternext is a clean
;; stop OR a raise, and manufacturing a StopIteration without asking which
;; would report a dict mutated during iteration as the end of the dict.
;;
;; It SETS that StopIteration and answers NULL; it does not RAISE.  This said
;; the opposite, on the reasoning that the thunk is only ever called from a
;; live Python frame -- and that stopped being true the moment dunder_bind
;; learned not to prepend self to a bound method, because
;; `type("C", (), {"__next__": iter([1]).__next__})` then reaches this thunk
;; from slot_tp_iternext with no Python frame in between.  A RAISE there
;; unwinds to the nearest enclosing Python frame and straight past the wrapper
;; whose whole job is to turn a StopIteration back into exhaustion, so a `for`
;; over such an object never terminated.  Every caller of a builtin already
;; propagates a NULL with an exception pending, so the ordinary
;; `it.__next__()` is unchanged.
;; ============================================================================
DN_EXC   equ 8
DN_FRAME equ 32             ; + 0 pushes = 32, 16-aligned.  It was 24, so
                            ; every one of the twenty-two functions this macro
                            ; generates called dunder_require_self -- and then
                            ; tp_iternext, which for map and filter reaches
                            ; arbitrary Python -- eight bytes out.  lint's
                            ; check_alignment skips a DEF_FUNC inside a %macro,
                            ; so nothing saw it.

%macro DEF_DUNDER_NEXT 1
DEF_FUNC %1_dunder_next, DN_FRAME
    cmp rsi, 1                  ; exactly self
    jne %%arity
    mov rdi, [rdi]
    lea rsi, [rel %1_type]
    xor edx, edx
    CSTRING rcx, "__next__"
    extern dunder_require_self
    call dunder_require_self
    mov rdi, rax

    DUNDER_EXC_SAVE [rbp - DN_EXC]
    lea rax, [rel %1_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz %%bad
    call rax
    V_UNPACK rax, rdx           ; tp_iternext answers a Value
    test edx, edx
    jz %%stop
    leave
    V_PACK rax, rdx
    ret

%%stop:
    EXC_RAISED_SINCE [rbp - DN_EXC], rcx, %%failed
    xor esi, esi                ; a bare StopIteration: str(e) is ""
    extern exc_StopIteration_type
    lea rdi, [rel exc_StopIteration_type]
    extern exc_new
    call exc_new
    mov rdi, rax
    extern exc_install
    call exc_install            ; takes ownership; falls through to %%failed

%%failed:
    xor eax, eax
    xor edx, edx
    leave
    V_PACK rax, rdx
    ret

%%arity:
    dec rsi
    xor edi, edi
    xor edx, edx                ; check_num_args' wording, with no gap
    extern raise_wrapper_arity
    call raise_wrapper_arity
%%bad:
    RAISE exc_TypeError_type, "object is not an iterator"
END_FUNC %1_dunder_next
%endmacro

DEF_DUNDER_LEN set
DEF_DUNDER_LEN frozenset
DEF_DUNDER_LEN bytes
DEF_DUNDER_ITER dict
DEF_DUNDER_ITER list
DEF_DUNDER_ITER tuple
DEF_DUNDER_ITER str
DEF_DUNDER_ITER set
DEF_DUNDER_ITER frozenset
DEF_DUNDER_ITER bytes
DEF_DUNDER_LEN range
DEF_DUNDER_ITER range

;; The builtin iterators, which had a tp_iternext and a tp_iter and no way
;; to reach either by name.  heapq.py's `next = it.__next__` and
;; inspect.py's `iter(lines).__next__` are what noticed.

extern list_iter_type
extern tuple_iter_type
extern range_iter_type
extern longrange_iter_type
extern str_iter_type
extern bytes_iter_type
extern bytearray_iter_type
extern memoryview_iter_type
extern set_iter_type
extern dict_iter_type
extern dict_value_iter_type
extern dict_item_iter_type
extern dict_rev_iter_type
extern enumerate_iter_type
extern zip_iter_type
extern map_iter_type
extern filter_iter_type
extern callable_iter_type
extern seq_iter_type
extern reversed_iter_type
extern sre_scanner_type
extern scandir_iter_type

DEF_DUNDER_ITER list_iter
DEF_DUNDER_NEXT list_iter
DEF_DUNDER_ITER tuple_iter
DEF_DUNDER_NEXT tuple_iter
DEF_DUNDER_ITER range_iter
DEF_DUNDER_NEXT range_iter
DEF_DUNDER_ITER longrange_iter
DEF_DUNDER_NEXT longrange_iter
DEF_DUNDER_ITER str_iter
DEF_DUNDER_NEXT str_iter
DEF_DUNDER_ITER bytes_iter
DEF_DUNDER_NEXT bytes_iter
DEF_DUNDER_ITER bytearray_iter
DEF_DUNDER_NEXT bytearray_iter
DEF_DUNDER_ITER memoryview_iter
DEF_DUNDER_NEXT memoryview_iter
DEF_DUNDER_ITER set_iter
DEF_DUNDER_NEXT set_iter
DEF_DUNDER_ITER dict_iter
DEF_DUNDER_NEXT dict_iter
DEF_DUNDER_ITER dict_value_iter
DEF_DUNDER_NEXT dict_value_iter
DEF_DUNDER_ITER dict_item_iter
DEF_DUNDER_NEXT dict_item_iter
DEF_DUNDER_ITER dict_rev_iter
DEF_DUNDER_NEXT dict_rev_iter
DEF_DUNDER_ITER enumerate_iter
DEF_DUNDER_NEXT enumerate_iter
DEF_DUNDER_ITER zip_iter
DEF_DUNDER_NEXT zip_iter
DEF_DUNDER_ITER map_iter
DEF_DUNDER_NEXT map_iter
DEF_DUNDER_ITER filter_iter
DEF_DUNDER_NEXT filter_iter
DEF_DUNDER_ITER callable_iter
DEF_DUNDER_NEXT callable_iter
DEF_DUNDER_ITER seq_iter
DEF_DUNDER_NEXT seq_iter
DEF_DUNDER_ITER reversed_iter
DEF_DUNDER_NEXT reversed_iter
DEF_DUNDER_ITER sre_scanner
DEF_DUNDER_NEXT sre_scanner
DEF_DUNDER_ITER scandir_iter
DEF_DUNDER_NEXT scandir_iter

; A generator is its own iterator, and CPython's type says so by name.
extern gen_type
extern coro_type
extern async_gen_asend_type
DEF_DUNDER_ITER async_gen_asend
extern async_gen_athrow_type
DEF_DUNDER_ITER async_gen_athrow
DEF_DUNDER_ITER gen
; A coroutine's __await__ is the same thing under the name `await` uses.
DEF_DUNDER_ITER coro


;; A builtin number's unary dunders, reachable by name.  int and float had
;; none at all: `(-5).__abs__()` was an AttributeError, and -- worse -- an MRO
;; name lookup could not prefer int's operator over a later base's, because
;; int had nothing in its dict to find.  `class I(int, M)` with an M defining
;; __invert__ therefore installed M's, where CPython answers int's.
;;
;; Like the str/repr thunks these call the *defining* type's slot rather than
;; the argument's, which is what keeps a subclass out of its own recursion.
%macro DEF_DUNDER_UNARY 3       ; %1 = type prefix, %2 = suffix, %3 = nb_ field
DEF_FUNC %1_dunder_%2
    cmp rsi, 1
    jne %%bad
    mov rdi, [rdi]              ; args[0] = self, a Value
    lea rsi, [rel %1_type]
    xor edx, edx
    CSTRING_DUNDER rcx, %2
    extern dunder_require_self
    call dunder_require_self
    mov rdi, rax
    lea rax, [rel %1_type]
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jz %%bad
    mov rax, [rax + PyNumberMethods.%3]
    test rax, rax
    jz %%bad
    call rax
    leave
    ret
%%bad:
    ; CPython reports both counts, and counts self in neither.
    dec rsi                     ; rsi is still nargs on this path
    xor edi, edi
    xor edx, edx                ; check_num_args' wording, with no gap
    extern raise_wrapper_arity
    call raise_wrapper_arity
END_FUNC %1_dunder_%2
%endmacro

;; ============================================================================
;; DEF_SEQ_DUNDER prefix, suffix, implementation
;;
;; The sequence operators, by name.  Two things separate these from
;; DEF_DUNDER_BINARY.
;;
;; CPython RAISES for an operand a sequence slot refuses -- [1].__add__(5) is
;; a TypeError where {}.__or__(5) is NotImplemented -- so the implementation's
;; own error is the answer, and is left to propagate.
;;
;; And every one of these implementations declines a SELF of the wrong type
;; through BINOP_REQUIRE_LEFT, which answers a NULL Value with nothing
;; pending.  A builtin's caller reads that as "it raised", finds no exception,
;; and falls over -- so list.__add__(5, []) has to be turned into the
;; TypeError CPython gives.  tuple's three hand-written thunks had that hole
;; and are regenerated from this.
;;
;; Arity is not checked here.  It is in the registration, and
;; builtin_func_call rejects the wrong count before this is entered.
;; ============================================================================
%macro DEF_SEQ_DUNDER 3-4       ; %1 prefix, %2 suffix, %3 implementation,
                                ; %4 present = decline as NotImplemented
DEF_FUNC %1_dunder_%2, DB_FRAME
    cmp rsi, 2
    jne %%bad
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    mov [rbp - DB_RHS], rsi
    lea rsi, [rel %1_type]
    xor edx, edx
    CSTRING_DUNDER rcx, %2
    extern dunder_require_self
    call dunder_require_self
    mov rdi, rax
    mov rsi, [rbp - DB_RHS]
    DUNDER_EXC_SAVE [rbp - DB_EXC]
    extern %3
    call %3
    test rax, rax
    jnz %%out
    EXC_RAISED_SINCE [rbp - DB_EXC], rcx, %%out
%if %0 >= 4
%ifidn %4,count
    ; A repetition whose count is not an index.  The OPERATOR words this as
    ; "can't multiply sequence by non-int of type 'str'"; the dunder called by
    ; name says what the count itself had to be, and CPython draws the same
    ; line.  The slots decline rather than raise so that `[1] * R()` can still
    ; reach R.__rmul__, and without this the decline came out of the dunder as
    ; a bare "unsupported operand type" -- or, where the dunder tail-jumps
    ; into the slot, as a NULL that bound nothing at all.
    mov rsi, [rbp - DB_RHS]
    extern seq_repeat_not_index
    jmp seq_repeat_not_index
%else
    ; The implementation declined the pair without raising.  Called by name,
    ; that has to read as NotImplemented so the caller can try the reflected
    ; form; only the operator machinery turns a decline into a TypeError.
    extern notimpl_singleton
    lea rax, [rel notimpl_singleton]
    INCREF rax
    leave
    ret
%endif
%endif
%%bad:
    RAISE exc_TypeError_type, "unsupported operand type"
%%out:
    leave
    ret
END_FUNC %1_dunder_%2
%endmacro

;; The reflected sequence form: self is the RIGHT operand, and the slot is
;; called with the operands the way it expects them.  `2 * L` reaches
;; list.__rmul__(L, 2), and sq_repeat wants (L, 2).
%macro DEF_SEQ_RDUNDER 3-4      ; %1 prefix, %2 suffix, %3 implementation,
                                ; %4 = count: a decline is a bad count
DEF_FUNC %1_dunder_%2, DB_FRAME
    cmp rsi, 2
    jne %%bad
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    mov [rbp - DB_RHS], rsi
    lea rsi, [rel %1_type]
    xor edx, edx
    CSTRING_DUNDER rcx, %2
    extern dunder_require_self
    call dunder_require_self
    mov rdi, rax
    mov rsi, [rbp - DB_RHS]
    DUNDER_EXC_SAVE [rbp - DB_EXC]
    extern %3
    call %3
    test rax, rax
    jnz %%out
    EXC_RAISED_SINCE [rbp - DB_EXC], rcx, %%out
%if %0 >= 4
    mov rsi, [rbp - DB_RHS]
    extern seq_repeat_not_index
    jmp seq_repeat_not_index
%endif
%%bad:
    RAISE exc_TypeError_type, "unsupported operand type"
%%out:
    leave
    ret
END_FUNC %1_dunder_%2
%endmacro

;; What str and bytes accept on the other side of their reflected `%`.
global dunder_operand_is_str
DEF_FUNC_BARE dunder_operand_is_str
    V_TEST_PTR rdi, rax
    ja .dois_no
    test rdi, rdi
    jz .dois_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .dois_yes
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .dois_no
.dois_yes:
    mov eax, 1
    ret
.dois_no:
    xor eax, eax
    ret
END_FUNC dunder_operand_is_str

global dunder_operand_is_bytes
DEF_FUNC_BARE dunder_operand_is_bytes
    V_TEST_PTR rdi, rax
    ja .doib_no
    test rdi, rdi
    jz .doib_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .doib_yes
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .doib_yes
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_BYTES_SUBCLASS
    jz .doib_no
.doib_yes:
    mov eax, 1
    ret
.doib_no:
    xor eax, eax
    ret
END_FUNC dunder_operand_is_bytes

;; Anything at all: the dict and set slots validate both operands themselves
;; and decline a pair they do not want with a NULL Value, which
;; DEF_DUNDER_BINARY already turns into NotImplemented.
global dunder_operand_any
DEF_FUNC_BARE dunder_operand_any
    mov eax, 1
    ret
END_FUNC dunder_operand_any

;; ============================================================================
;; DEF_DUNDER_BINARY prefix, suffix, nb_field, reflected
;;
;; The binary operator dunders, by name.  int.__add__ did not exist at all --
;; dir(int) was short by about forty names -- so a class delegating to it found
;; nothing, and the stdlib's habit of asking `hasattr(x, "__add__")` answered
;; no for the type it is truest of.
;;
;; The slot is the *defining* type's, as in DEF_DUNDER_UNARY: reading it off
;; the argument would send a subclass back into its own wrapper.  A reflected
;; form swaps the operands and calls the same slot, which is what nb_ slots
;; expect -- they take both operands and answer NotImplemented when the pair
;; is not theirs, so `int.__radd__(1, "x")` comes out right without a second
;; table.
;; ============================================================================
;; dunder_operand_is_int / _is_real -- what each type's binary dunders accept.
;; The SLOTS here coerce: int_add adds an int to a float quite happily, which
;; is what makes 1 + 2.5 work without a reflected step.  A dunder called by
;; name must not: CPython's int.__add__(1, 2.5) is NotImplemented, and code
;; that dispatches on that answer -- the numeric tower in fractions and
;; decimal does -- reads a computed 3.5 as "int handled it".
global dunder_operand_is_int
DEF_FUNC_BARE dunder_operand_is_int
    V_UNPACK rdi, rdx
    jmp int_is_integer
END_FUNC dunder_operand_is_int

global dunder_operand_is_real
DEF_FUNC dunder_operand_is_real, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    V_IS_FLOAT rdi, rax
    jb .doir_yes
    V_TEST_PTR rdi, rax
    ja .doir_int
    test rdi, rdi
    jz .doir_int
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel float_type]
    cmp rax, rcx
    je .doir_yes
    mov rdi, rax
    lea rsi, [rel float_type]
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jnz .doir_yes
.doir_int:
    mov rdi, rbx
    V_UNPACK rdi, rdx
    call int_is_integer
    pop rbx
    leave
    ret
.doir_yes:
    mov eax, 1
    pop rbx
    leave
    ret
END_FUNC dunder_operand_is_real

;; ============================================================================
;; dunder_operand_is_complex(rdi = the other operand, a Value) -> eax = 1 when
;;   complex's binary dunders will take it
;;
;; A complex, or anything real.  The whole family was absent from complex's
;; tp_dict -- the operators worked through the slots, but
;; `hasattr(complex(1,2), "__add__")` was False, and the numeric tower asks by
;; name.
;; ============================================================================
global dunder_operand_is_complex
DEF_FUNC dunder_operand_is_complex, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    V_TEST_PTR rdi, rax
    ja .doic_real
    test rdi, rdi
    jz .doic_real
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel complex_type]
    cmp rax, rcx
    je .doic_yes
    mov rdi, rax
    lea rsi, [rel complex_type]
    call type_is_subtype
    test eax, eax
    jnz .doic_yes
.doic_real:
    mov rdi, rbx
    call dunder_operand_is_real
    pop rbx
    leave
    ret
.doic_yes:
    mov eax, 1
    pop rbx
    leave
    ret
END_FUNC dunder_operand_is_complex

; The one frame slot these need: the exception pending before the slot ran.
DB_EXC   equ 8
DB_RHS   equ 16     ; the right operand, parked across the receiver check
; The three-argument form (pow with a modulus) rebuilds its argument array
; here, so a reflected dunder can swap the base and the exponent.  An
; argument array runs upward, so the three slots descend: DB_A0 is the lowest
; address and therefore args[0].
DB_A0    equ 40
DB_A1    equ 32
DB_A2    equ 24
DB_FRAME equ 48             ; + 0 pushes = 48, 16-aligned

;; %7, when given, is a three-argument form: pow() takes a modulus, and
;; `int.__pow__(5, 3)` is `pow(2, 5, 3)`.  It takes (args, nargs) as a builtin
;; does, so the reflected case has only to swap the first two before the call.
%macro DEF_DUNDER_BINARY 5-8 0, 0, 0 ; %1 prefix, %2 suffix, %3 nb_ field, %4 reflected, %5 operand check, %6 self check, %7 3-arg form, %8 check the operand in it
DEF_FUNC %1_dunder_%2, DB_FRAME
%ifnum %7
    cmp rsi, 2
    jne %%bad
%else
    cmp rsi, 3
    je %%three
    cmp rsi, 2
    jne %%bad
%endif
%if %4
    mov rsi, [rdi]              ; self is the right operand
    mov rdi, [rdi + 8]
%else
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
%endif

    ; Self has to be one of this type's, whichever side it arrived on:
    ; int.__radd__("x", 1) reaches the same slot as int.__add__.
%if %4
    mov [rbp - DB_RHS], rdi     ; the other operand; self is on the right
    mov rdi, rsi
    lea rsi, [rel %1_type]
%ifnum %6
    xor edx, edx
%else
    lea rdx, [rel %6]
%endif
    CSTRING_DUNDER rcx, %2
    extern dunder_require_self
    call dunder_require_self
    mov rsi, rax
    mov rdi, [rbp - DB_RHS]
%else
    mov [rbp - DB_RHS], rsi
    lea rsi, [rel %1_type]
%ifnum %6
    xor edx, edx
%else
    lea rdx, [rel %6]
%endif
    CSTRING_DUNDER rcx, %2
    extern dunder_require_self
    call dunder_require_self
    mov rdi, rax
    mov rsi, [rbp - DB_RHS]
%endif

    ; The operand that is not self has to be one this type's dunder accepts.
    push rdi
    push rsi                    ; [rsp] = right, [rsp + 8] = left
%if %4
    mov rdi, [rsp + 8]
%else
    mov rdi, [rsp]
%endif
    extern %5
    call %5
    pop rsi
    pop rdi
    test eax, eax
    jz %%notimpl

    lea rax, [rel %1_type]
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jz %%bad
    mov rax, [rax + PyNumberMethods.%3]
    test rax, rax
    jz %%bad
    DUNDER_EXC_SAVE [rbp - DB_EXC]
    call rax
    test rax, rax
    jnz %%out

    ; A slot declines a pair it does not want by answering NULL, and the
    ; operator machinery turns that into its TypeError.  A dunder called by
    ; name has to answer NotImplemented instead, so its caller can try the
    ; reflected form -- int.__add__(1, "x") is NotImplemented, not an error.
    EXC_RAISED_SINCE [rbp - DB_EXC], rcx, %%out
%%notimpl:
    extern notimpl_singleton
    lea rax, [rel notimpl_singleton]
    INCREF rax
%%out:
    leave
    ret
%ifnnum %7
%%three:
%if %8
    ; int's slot declines a non-int operand before it ever looks at the
    ; modulus, so the dunder answers NotImplemented -- but float's checks the
    ; modulus first and raises, which is why only one of them tests here.
    ; The other operand is args[1] on both sides; self is args[0] either way.
    push rdi
    mov rdi, [rdi + 8]
    call %5
    pop rdi
    test eax, eax
    jz %%notimpl
%endif
%if %4
    ; Reflected: self is the BASE's right operand, so the pair swaps.
    mov rax, [rdi]              ; self
    mov rcx, [rdi + 8]          ; the base
    mov [rbp - DB_A0], rcx
    mov [rbp - DB_A1], rax
    mov rax, [rdi + 16]         ; the modulus
    mov [rbp - DB_A2], rax
    lea rdi, [rbp - DB_A0]
%endif
    mov esi, 3
    extern %7
    call %7
    leave
    ret
%endif
%%bad:
    ; CPython reports both counts, and counts self in neither.  Its wording
    ; for a wrapper that takes a RANGE is different again (" expected at most
    ; 2 arguments, got 3", the leading space its own); ours reports the count
    ; it wanted, which bugs.md records among the wordings that differ.
    dec rsi                     ; rsi is still nargs on this path
    mov edi, 1
    xor edx, edx                ; check_num_args' wording, with no gap
    extern raise_wrapper_arity
    call raise_wrapper_arity
END_FUNC %1_dunder_%2
%endmacro

;; ============================================================================
;; DEF_DUNDER_DIVMOD prefix, suffix, reflected
;;
;; divmod has no nb_ slot filled on either numeric type -- the builtin drives
;; nb_floor_divide and nb_remainder itself -- so its dunder goes through the
;; builtin rather than through a slot.  The one thing that has to be kept is
;; the dunder's own answer for an operand it does not want: NotImplemented,
;; not a TypeError, so the caller can try the reflected form.
;; ============================================================================
%macro DEF_DUNDER_DIVMOD 4      ; %1 prefix, %2 suffix, %3 reflected, %4 operand check
DEF_FUNC %1_dunder_%2, 16
    cmp rsi, 2
    jne %%bad
    sub rsp, 16
%if %3
    mov rax, [rdi + 8]
    mov [rsp], rax
    mov rax, [rdi]
    mov [rsp + 8], rax
%else
    mov rax, [rdi]
    mov [rsp], rax
    mov rax, [rdi + 8]
    mov [rsp + 8], rax
%endif
    ; Self has to be one of this type's, whichever slot it landed in.
%if %3
    mov rdi, [rsp + 8]
%else
    mov rdi, [rsp]
%endif
    lea rsi, [rel %1_type]
    xor edx, edx
    CSTRING_DUNDER rcx, %2
    extern dunder_require_self
    call dunder_require_self

    ; The operand that is not self has to be one this type accepts, as for
    ; the other binary dunders.  The reflected form already put self SECOND.
%if %3
    mov rdi, [rsp]
%else
    mov rdi, [rsp + 8]
%endif
    extern %4
    call %4
    test eax, eax
    jz %%notimpl
    mov rdi, rsp
    mov esi, 2
    extern builtin_divmod
    call builtin_divmod
    add rsp, 16
    leave
    ret
%%notimpl:
    add rsp, 16
    extern notimpl_singleton
    lea rax, [rel notimpl_singleton]
    INCREF rax
    leave
    ret
%%bad:
    ; CPython reports both counts, and counts self in neither.
    dec rsi                     ; rsi is still nargs on this path
    mov edi, 1
    xor edx, edx                ; check_num_args' wording, with no gap
    extern raise_wrapper_arity
    call raise_wrapper_arity
END_FUNC %1_dunder_%2
%endmacro

;; __bool__ is the odd one: nb_bool answers 0 or 1 in eax, not a Value.
%macro DEF_DUNDER_BOOL 1
DEF_FUNC %1_dunder_bool
    cmp rsi, 1
    jne %%bad
    mov rdi, [rdi]
    lea rsi, [rel %1_type]
    xor edx, edx
    CSTRING rcx, "__bool__"
    extern dunder_require_self
    call dunder_require_self
    mov rdi, rax
    lea rax, [rel %1_type]
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jz %%bad
    mov rax, [rax + PyNumberMethods.nb_bool]
    test rax, rax
    jz %%bad
    call rax
    test eax, eax
    jz %%false
    extern bool_true
    lea rax, [rel bool_true]
    INCREF rax
    leave
    ret
%%false:
    extern bool_false
    lea rax, [rel bool_false]
    INCREF rax
    leave
    ret
%%bad:
    ; CPython reports both counts, and counts self in neither.
    dec rsi                     ; rsi is still nargs on this path
    xor edi, edi
    xor edx, edx                ; check_num_args' wording, with no gap
    extern raise_wrapper_arity
    call raise_wrapper_arity
END_FUNC %1_dunder_bool
%endmacro

DEF_DUNDER_UNARY int, neg, nb_negative
DEF_DUNDER_UNARY int, pos, nb_positive
DEF_DUNDER_UNARY int, abs, nb_absolute
DEF_DUNDER_UNARY int, invert, nb_invert
DEF_DUNDER_UNARY int, int, nb_int
DEF_DUNDER_UNARY int, float, nb_float
DEF_DUNDER_UNARY int, index, nb_index
DEF_DUNDER_UNARY int, trunc, nb_int

DEF_DUNDER_UNARY float, neg, nb_negative
DEF_DUNDER_UNARY float, pos, nb_positive
DEF_DUNDER_UNARY float, abs, nb_absolute
DEF_DUNDER_UNARY float, int, nb_int
DEF_DUNDER_UNARY float, float, nb_float
DEF_DUNDER_UNARY float, trunc, nb_int
DEF_DUNDER_BOOL float
; complex has an nb_bool of its own; only the by-name half was missing.
DEF_DUNDER_BOOL complex

;; int's binary family, forward and reflected.
DEF_DUNDER_BINARY int, add, nb_add, 0, dunder_operand_is_int
DEF_DUNDER_BINARY int, sub, nb_subtract, 0, dunder_operand_is_int
DEF_DUNDER_BINARY int, mul, nb_multiply, 0, dunder_operand_is_int
DEF_DUNDER_BINARY int, mod, nb_remainder, 0, dunder_operand_is_int
DEF_DUNDER_DIVMOD int, divmod, 0, dunder_operand_is_int
DEF_DUNDER_BINARY int, pow, nb_power, 0, dunder_operand_is_int, 0, builtin_pow_fn, 1
DEF_DUNDER_BINARY int, lshift, nb_lshift, 0, dunder_operand_is_int
DEF_DUNDER_BINARY int, rshift, nb_rshift, 0, dunder_operand_is_int
DEF_DUNDER_BINARY int, and, nb_and, 0, dunder_operand_is_int
DEF_DUNDER_BINARY int, xor, nb_xor, 0, dunder_operand_is_int
DEF_DUNDER_BINARY int, or, nb_or, 0, dunder_operand_is_int
DEF_DUNDER_BINARY int, floordiv, nb_floor_divide, 0, dunder_operand_is_int
DEF_DUNDER_BINARY int, truediv, nb_true_divide, 0, dunder_operand_is_int
DEF_DUNDER_BINARY int, radd, nb_add, 1, dunder_operand_is_int
DEF_DUNDER_BINARY int, rsub, nb_subtract, 1, dunder_operand_is_int
DEF_DUNDER_BINARY int, rmul, nb_multiply, 1, dunder_operand_is_int
DEF_DUNDER_BINARY int, rmod, nb_remainder, 1, dunder_operand_is_int
DEF_DUNDER_DIVMOD int, rdivmod, 1, dunder_operand_is_int
DEF_DUNDER_BINARY int, rpow, nb_power, 1, dunder_operand_is_int, 0, builtin_pow_fn, 1
DEF_DUNDER_BINARY int, rlshift, nb_lshift, 1, dunder_operand_is_int
DEF_DUNDER_BINARY int, rrshift, nb_rshift, 1, dunder_operand_is_int
DEF_DUNDER_BINARY int, rand, nb_and, 1, dunder_operand_is_int
DEF_DUNDER_BINARY int, rxor, nb_xor, 1, dunder_operand_is_int
DEF_DUNDER_BINARY int, ror, nb_or, 1, dunder_operand_is_int
DEF_DUNDER_BINARY int, rfloordiv, nb_floor_divide, 1, dunder_operand_is_int
DEF_DUNDER_BINARY int, rtruediv, nb_true_divide, 1, dunder_operand_is_int

;; float's, which is the same list without the bitwise operators.
DEF_DUNDER_BINARY float, add, nb_add, 0, dunder_operand_is_real
DEF_DUNDER_BINARY float, sub, nb_subtract, 0, dunder_operand_is_real
DEF_DUNDER_BINARY float, mul, nb_multiply, 0, dunder_operand_is_real
DEF_DUNDER_BINARY float, mod, nb_remainder, 0, dunder_operand_is_real
DEF_DUNDER_DIVMOD float, divmod, 0, dunder_operand_is_real
DEF_DUNDER_BINARY float, pow, nb_power, 0, dunder_operand_is_real, 0, builtin_pow_fn
DEF_DUNDER_BINARY float, floordiv, nb_floor_divide, 0, dunder_operand_is_real
DEF_DUNDER_BINARY float, truediv, nb_true_divide, 0, dunder_operand_is_real
DEF_DUNDER_BINARY float, radd, nb_add, 1, dunder_operand_is_real
DEF_DUNDER_BINARY float, rsub, nb_subtract, 1, dunder_operand_is_real
DEF_DUNDER_BINARY float, rmul, nb_multiply, 1, dunder_operand_is_real
DEF_DUNDER_BINARY float, rmod, nb_remainder, 1, dunder_operand_is_real
DEF_DUNDER_DIVMOD float, rdivmod, 1, dunder_operand_is_real
DEF_DUNDER_BINARY float, rpow, nb_power, 1, dunder_operand_is_real, 0, builtin_pow_fn
DEF_DUNDER_BINARY float, rfloordiv, nb_floor_divide, 1, dunder_operand_is_real
DEF_DUNDER_BINARY float, rtruediv, nb_true_divide, 1, dunder_operand_is_real

;; complex.  Its operators went through the slots and nothing else, so
;; `complex(1,2).__add__` did not exist -- and a class that dispatches on
;; NotImplemented, as the numeric tower does, cannot ask a type that has no
;; __add__ to try.  There is no floordiv or mod: complex has neither.
DEF_DUNDER_BINARY complex, add, nb_add, 0, dunder_operand_is_complex
DEF_DUNDER_BINARY complex, sub, nb_subtract, 0, dunder_operand_is_complex
DEF_DUNDER_BINARY complex, mul, nb_multiply, 0, dunder_operand_is_complex
DEF_DUNDER_BINARY complex, truediv, nb_true_divide, 0, dunder_operand_is_complex
; The operand is checked before the modulus, as int's is: complex's slot
; declines a non-complex operand outright, so `z.__pow__("x", 0)` is
; NotImplemented rather than a complaint about the modulus.
DEF_DUNDER_BINARY complex, pow, nb_power, 0, dunder_operand_is_complex, 0, builtin_pow_fn, 1
DEF_DUNDER_BINARY complex, radd, nb_add, 1, dunder_operand_is_complex
DEF_DUNDER_BINARY complex, rsub, nb_subtract, 1, dunder_operand_is_complex
DEF_DUNDER_BINARY complex, rmul, nb_multiply, 1, dunder_operand_is_complex
DEF_DUNDER_BINARY complex, rtruediv, nb_true_divide, 1, dunder_operand_is_complex
DEF_DUNDER_BINARY complex, rpow, nb_power, 1, dunder_operand_is_complex, 0, builtin_pow_fn, 1
DEF_DUNDER_UNARY complex, neg, nb_negative
DEF_DUNDER_UNARY complex, pos, nb_positive
DEF_DUNDER_UNARY complex, abs, nb_absolute

;; ============================================================================
;; object's generic attribute dunders, and the two hooks
;;
;; All five were absent from the tree.  They are not protocol hooks here --
;; slot_table has no row for any of them and nothing looks one up -- so these
;; are the generic implementations by name and nothing more.  They are named
;; rather than registered as builtin_setattr directly so that the day
;; __setattr__ becomes a slot, the owner test in type_install_slots has a
;; function to recognise.
;; ============================================================================
global object_method_setattr
DEF_FUNC_BARE object_method_setattr
    ; The GENERIC store, not builtin_setattr's dispatch through tp_setattr.
    ; Now that __setattr__ has a slot, that slot is the wrapper which called
    ; this, and re-entering it is unbounded recursion -- which is exactly what
    ; `object.__setattr__(self, k, v)` inside a __setattr__ does.
    extern object_generic_setattr
    jmp object_generic_setattr
END_FUNC object_method_setattr

global object_method_delattr
DEF_FUNC_BARE object_method_delattr
    ; The generic delete, for the same reason as __setattr__ above.  A NULL
    ; value through the store is what a deletion is.
    extern object_generic_delattr
    jmp object_generic_delattr
END_FUNC object_method_delattr


;; ============================================================================
;; object_method_getattribute(args, nargs) -- object.__getattribute__(o, name)
;;
;; The ordinary resolution, with the object's own __getattribute__ NOT run: a
;; user's almost always ends in `return object.__getattribute__(self, attr)`,
;; and letting that re-enter the hook is an infinite regress.  CPython gets
;; this from slot dispatch, where calling object's slot cannot reach the
;; subclass's; here the object is named in a global that the first
;; instance_getattr for it consumes.
;; ============================================================================
OGA2_FRAME equ 16           ; + 0 pushes = 16
global object_method_getattribute
DEF_FUNC object_method_getattribute, OGA2_FRAME
    extern builtin_getattr
    extern instance_getattr_skip
    cmp rsi, 2
    jne .omg_plain
    mov rax, [rdi]
    V_TEST_PTR rax, rcx
    ja .omg_plain
    test rax, rax
    jz .omg_plain
    mov [rel instance_getattr_skip], rax
.omg_plain:
    call builtin_getattr        ; with the wrong count it raises, as it should
    mov qword [rel instance_getattr_skip], 0
    leave
    ret
END_FUNC object_method_getattribute

;; object.__getstate__(self) -> self.__dict__, the pair (dict, slots), or None
;;
;; CPython 3.11+ answers a two-tuple for a class with __slots__: (None,
;; {name: value}), or (the instance dict, {slots}) when it has both.  Only
;; the plain dict form was here, so every __slots__ class answered None and
;; pickling one through __getstate__ lost every slot it had.
;;
;; There is no name-carrying slot walk anywhere else -- instance_traverse and
;; instance_dealloc walk the same words by OFFSET, which is all they need --
;; so the names come from where they are actually recorded: the member
;; descriptors in each type's dict along the MRO.
OGS_SELF  equ 8
OGS_DICT  equ 16
OGS_SLOTS equ 24
OGS_TUP   equ 32
OGS_FRAME equ 48            ; + 0 pushes = 48
global object_method_getstate
DEF_FUNC object_method_getstate, OGS_FRAME
    cmp rsi, 1
    jne .ogs_bad
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .ogs_none
    test rdi, rdi
    jz .ogs_none
    mov [rbp - OGS_SELF], rdi

    ; The instance dict, if this class has one.  An empty one is None, as
    ; CPython has it.
    mov qword [rbp - OGS_DICT], 0
    LOAD_INST_DICT rax, rdi, .ogs_no_dict
    test rax, rax
    jz .ogs_no_dict
    cmp qword [rax + PyDictObject.ob_size], 0
    je .ogs_no_dict
    mov [rbp - OGS_DICT], rax
.ogs_no_dict:

    ; The slots, if this class has any set.
    mov rdi, [rbp - OGS_SELF]
    call object_collect_slots   ; -> rax = a dict, or 0 when there are none
    mov [rbp - OGS_SLOTS], rax
    test rax, rax
    jnz .ogs_pair

    ; No slots: the plain dict form.
    mov rax, [rbp - OGS_DICT]
    test rax, rax
    jz .ogs_none
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.ogs_pair:
    ; (dict_or_None, {slots}).  The tuple takes over the slots dict this
    ; built, and a reference to the instance dict.
    mov edi, 2
    extern tuple_new
    call tuple_new
    mov [rbp - OGS_TUP], rax
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rcx, [rbp - OGS_DICT]
    test rcx, rcx
    jnz .ogs_pair_dict
    lea rcx, [rel none_singleton]
.ogs_pair_dict:
    INCREF rcx
    mov [rdx], rcx
    mov rcx, [rbp - OGS_SLOTS]
    mov [rdx + 8], rcx          ; the reference object_collect_slots returned
    mov rax, [rbp - OGS_TUP]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.ogs_none:
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.ogs_bad:
    RAISE exc_TypeError_type, "__getstate__() takes no arguments"
END_FUNC object_method_getstate

;; ============================================================================
;; object_collect_slots(rdi = an instance) -> rax = a new dict of the slots
;; that are set, or 0 when there are none
;;
;; Walks the MRO, and each type's dict, for member descriptors -- which are
;; where a __slots__ name is recorded, one per slot, built by type_from_parts.
;; The value is read the way instance_getattr's .found_slot reads it,
;; including its convention that a 0 word means the slot was never assigned.
;;
;; CPython's order is the MRO's: the most derived class's slots first.
;; ============================================================================
OCS_SELF  equ 8
OCS_DICT  equ 16
OCS_TYPE  equ 24
OCS_WALK  equ 32
OCS_ENT   equ 40
OCS_CAP   equ 48
OCS_IDX   equ 56
OCS_FRAME equ 64            ; + 0 pushes = 64
DEF_FUNC_LOCAL object_collect_slots, OCS_FRAME
    mov [rbp - OCS_SELF], rdi
    mov rax, [rdi + PyObject.ob_type]
    mov [rbp - OCS_TYPE], rax
    mov [rbp - OCS_WALK], rax
    mov qword [rbp - OCS_DICT], 0

.ocs_type_loop:
    mov rax, [rbp - OCS_WALK]
    test rax, rax
    jz .ocs_done
    ; Only a CLASS has __slots__.  A builtin's tp_dict holds member
    ; descriptors of its own -- func_type has one for __globals__ -- and
    ; taking those for slots made `f.__getstate__()` on a function answer a
    ; dict holding the whole module namespace.
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .ocs_next_type
    ; Not rbx: that is the eval loop's bytecode IP, and this function does
    ; not save it.
    mov rdx, [rax + PyTypeObject.tp_dict]
    test rdx, rdx
    jz .ocs_next_type
    mov rcx, [rdx + PyDictObject.entries]
    test rcx, rcx
    jz .ocs_next_type
    mov [rbp - OCS_ENT], rcx
    mov rcx, [rdx + PyDictObject.capacity]
    mov [rbp - OCS_CAP], rcx
    mov qword [rbp - OCS_IDX], 0

.ocs_entry_loop:
    mov rax, [rbp - OCS_IDX]
    cmp rax, [rbp - OCS_CAP]
    jge .ocs_next_type
    imul rax, DICT_ENTRY_SIZE
    add rax, [rbp - OCS_ENT]
    mov rdx, [rax + DictEntry.key]
    test rdx, rdx
    jz .ocs_next_entry
    mov rax, [rax + DictEntry.value]
    V_TEST_PTR rax, rcx
    ja .ocs_next_entry
    test rax, rax
    jz .ocs_next_entry
    extern member_descr_type
    lea rcx, [rel member_descr_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .ocs_next_entry

    ; A member descriptor: read the word it names.  0 means never assigned.
    mov rcx, [rax + PyMemberDescrObject.md_offset]
    mov rdi, [rbp - OCS_SELF]
    SLOT_ADDR rsi, rdi, rcx
    mov rdx, [rsi]
    test rdx, rdx
    jz .ocs_next_entry

    ; Make the dict on the first slot that is actually set, so a class with
    ; __slots__ and nothing assigned answers None the way CPython's does.
    push rax
    sub rsp, 8
    cmp qword [rbp - OCS_DICT], 0
    jne .ocs_have_dict
    extern dict_new
    call dict_new
    mov [rbp - OCS_DICT], rax
.ocs_have_dict:
    add rsp, 8
    pop rax

    mov rcx, [rax + PyMemberDescrObject.md_offset]
    mov rdx, [rbp - OCS_SELF]
    SLOT_ADDR rdi, rdx, rcx
    mov rdx, [rdi]
    mov rsi, [rax + PyMemberDescrObject.md_name]
    mov rdi, [rbp - OCS_DICT]
    extern dict_set
    call dict_set

.ocs_next_entry:
    inc qword [rbp - OCS_IDX]
    jmp .ocs_entry_loop

.ocs_next_type:
    mov rax, [rbp - OCS_WALK]
    MRO_NEXT rax, [rbp - OCS_TYPE]
    mov [rbp - OCS_WALK], rax
    jmp .ocs_type_loop

.ocs_done:
    mov rax, [rbp - OCS_DICT]
    leave
    ret
END_FUNC object_collect_slots

;; object.__subclasshook__(cls, subclass) -> NotImplemented
;;
;; "I have no opinion", which is what the structural ABCs override and what
;; abc_subclasscheck reads as "fall through to the MRO".  It has been looking
;; for this name since it was written and silently finding nothing.
global object_method_subclasshook
DEF_FUNC object_method_subclasshook
    lea rax, [rel notimpl_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
END_FUNC object_method_subclasshook

;; --- the container operators, by name ------------------------------------
;; hasattr(list, "__add__") was False, and so was every other one of these:
;; the slot was there and the name was not, so `operator`-style code and
;; anything that duck-types on a dunder could not see them.
;;
;; The split is CPython's own.  A sequence slot RAISES for an operand it
;; refuses, so those get the thunk; an nb_ slot declines with NULL and has to
;; answer NotImplemented, so those get the DEF_DUNDER_BINARY shape.
DEF_SEQ_DUNDER  list, add,   list_concat
DEF_SEQ_DUNDER  list, mul,   list_repeat, count
DEF_SEQ_RDUNDER list, rmul,  list_repeat, count
DEF_SEQ_DUNDER  list, imul,  list_inplace_repeat, count

DEF_SEQ_DUNDER  str, add,      str_concat
DEF_SEQ_DUNDER  str, mul,      str_repeat, count
DEF_SEQ_RDUNDER str, rmul,     str_repeat, count
DEF_SEQ_DUNDER  str, mod,      str_mod
DEF_SEQ_DUNDER  str, getitem,  str_subscript

DEF_SEQ_DUNDER  bytes, add,     bytes_concat
DEF_SEQ_DUNDER  bytes, mul,     bytes_repeat, count
DEF_SEQ_RDUNDER bytes, rmul,    bytes_repeat, count
DEF_SEQ_DUNDER  bytes, mod,     bytes_mod
DEF_SEQ_DUNDER  bytes, getitem, bytes_subscript

DEF_SEQ_DUNDER  bytearray, add,   bytearray_concat
DEF_SEQ_DUNDER  bytearray, mul,   bytearray_repeat, count
DEF_SEQ_RDUNDER bytearray, rmul,  bytearray_repeat, count
DEF_SEQ_DUNDER  bytearray, iadd,  bytearray_inplace_concat
DEF_SEQ_DUNDER  bytearray, imul,  bytearray_inplace_repeat, count
DEF_SEQ_DUNDER  bytearray, mod,   bytearray_mod

;; The reflected `%` forms answer NotImplemented for anything that is not a
;; str (or bytes), rather than reading it as one.
DEF_DUNDER_BINARY str,       rmod, nb_remainder, 1, dunder_operand_is_str
DEF_DUNDER_BINARY bytes,     rmod, nb_remainder, 1, dunder_operand_is_bytes
DEF_DUNDER_BINARY bytearray, rmod, nb_remainder, 1, dunder_operand_is_bytes

;; dict and set decline through their slots, so the operand check has nothing
;; left to do.
DEF_DUNDER_BINARY dict, or,  nb_or, 0, dunder_operand_any
DEF_DUNDER_BINARY dict, ror, nb_or, 1, dunder_operand_any
DEF_SEQ_DUNDER    dict, ior, dict_nb_ior

;; The set operators.  These used to be registered from one shared table into
;; both types' dicts, so each had to name frozenset_type as a second
;; acceptable receiver -- and set.__and__(frozenset(...), ...) was accepted
;; where CPython raises.  CPython gives frozenset its own eight descriptors;
;; so do we, and each side now names only itself.  The bodies are identical
;; apart from the receiver check: frozenset_type carries set_number_methods,
;; so both reach the same slots.
DEF_DUNDER_BINARY set, sub,  nb_subtract, 0, dunder_operand_any
DEF_DUNDER_BINARY set, rsub, nb_subtract, 1, dunder_operand_any
DEF_DUNDER_BINARY set, and,  nb_and,      0, dunder_operand_any
DEF_DUNDER_BINARY set, rand, nb_and,      1, dunder_operand_any
DEF_DUNDER_BINARY set, xor,  nb_xor,      0, dunder_operand_any
DEF_DUNDER_BINARY set, rxor, nb_xor,      1, dunder_operand_any
DEF_DUNDER_BINARY set, or,   nb_or,       0, dunder_operand_any
DEF_DUNDER_BINARY set, ror,  nb_or,       1, dunder_operand_any

;; The in-place four, which set really does have and frozenset really does
;; not.  These take the mutating nb_inplace_* slots directly rather than
;; going through DEF_DUNDER_BINARY's nb_ lookup, because a subclass reaching
;; the slot off its own type would re-enter this wrapper.
DEF_SEQ_DUNDER    set, iand, set_nb_iand, 1
DEF_SEQ_DUNDER    set, ior,  set_nb_ior, 1
DEF_SEQ_DUNDER    set, isub, set_nb_isub, 1
DEF_SEQ_DUNDER    set, ixor, set_nb_ixor, 1

DEF_DUNDER_BINARY frozenset, sub,  nb_subtract, 0, dunder_operand_any
DEF_DUNDER_BINARY frozenset, rsub, nb_subtract, 1, dunder_operand_any
DEF_DUNDER_BINARY frozenset, and,  nb_and,      0, dunder_operand_any
DEF_DUNDER_BINARY frozenset, rand, nb_and,      1, dunder_operand_any
DEF_DUNDER_BINARY frozenset, xor,  nb_xor,      0, dunder_operand_any
DEF_DUNDER_BINARY frozenset, rxor, nb_xor,      1, dunder_operand_any
DEF_DUNDER_BINARY frozenset, or,   nb_or,       0, dunder_operand_any
DEF_DUNDER_BINARY frozenset, ror,  nb_or,       1, dunder_operand_any

;; int's nb_bool takes the (payload, tag) pair rather than a Value -- it hands
;; the pair straight to int_unwrap -- so it cannot go through the macro.
DEF_FUNC int_dunder_bool
    REQUIRE_SELF int_type, "__bool__"
    cmp rsi, 1
    jne .idb_bad
    mov rdi, [rdi]
    V_UNPACK rdi, rdx
    extern int_bool
    call int_bool
    test eax, eax
    jz .idb_false
    lea rax, [rel bool_true]
    INCREF rax
    leave
    ret
.idb_false:
    lea rax, [rel bool_false]
    INCREF rax
    leave
    ret
.idb_bad:
    ; CPython reports both counts, and counts self in neither.
    dec rsi
    xor edi, edi
    xor edx, edx                ; check_num_args' wording, with no gap
    extern raise_wrapper_arity
    call raise_wrapper_arity
END_FUNC int_dunder_bool

DEF_DUNDER_STRREPR str, str, "__str__"
DEF_DUNDER_STRREPR str, repr, "__repr__"
DEF_DUNDER_STRREPR bytes, str, "__str__"
DEF_DUNDER_STRREPR bytes, repr, "__repr__"
DEF_DUNDER_STRREPR int, repr, "__repr__"
DEF_DUNDER_STRREPR float, repr, "__repr__"
DEF_DUNDER_STRREPR complex, repr, "__repr__"

; The containers, for the same reason and one more: pprint keys its dispatch
; table on the UNBOUND repr -- `_dispatch[list.__repr__] = _pprint_list`, and
; nine lines like it -- so while every one of these resolved through the MRO to
; object's, they all collapsed onto a single key holding whichever line ran
; last.  pprint then handed a list to the SimpleNamespace printer, which is
; where every `'list' object has no attribute '__dict__'` came from.
;
; __repr__ only: CPython gives none of these a __str__ of its own, and
; `list.__str__ is object.__str__` is a question enum asks.
extern namespace_type
extern mappingproxy_type
extern memoryview_type
extern dict_keys_view_type
extern dict_values_view_type
extern dict_items_view_type

DEF_DUNDER_STRREPR list, repr, "__repr__"
DEF_DUNDER_STRREPR tuple, repr, "__repr__"
DEF_DUNDER_STRREPR dict, repr, "__repr__"
DEF_DUNDER_STRREPR set, repr, "__repr__"
DEF_DUNDER_STRREPR frozenset, repr, "__repr__"
DEF_DUNDER_STRREPR bytearray, repr, "__repr__"
DEF_DUNDER_STRREPR bool, repr, "__repr__"
DEF_DUNDER_STRREPR range_obj, repr, "__repr__"
DEF_DUNDER_STRREPR slice, repr, "__repr__"
DEF_DUNDER_STRREPR type, repr, "__repr__"
DEF_DUNDER_STRREPR namespace, repr, "__repr__"
DEF_DUNDER_STRREPR mappingproxy, repr, "__repr__"
DEF_DUNDER_STRREPR memoryview, repr, "__repr__"
DEF_DUNDER_STRREPR dict_keys_view, repr, "__repr__"
DEF_DUNDER_STRREPR dict_values_view, repr, "__repr__"
DEF_DUNDER_STRREPR dict_items_view, repr, "__repr__"

;; ############################################################################
;;                         SET METHODS
;; ############################################################################

;; ============================================================================
;; Slot-backed dunder methods
;;
;; The operators reach the type slots directly, but the methods themselves
;; were absent from most builtin type dicts, so `dict.__setitem__` and
;; `ref.__hash__` -- both of which collections and weakref bind at class
;; definition time -- raised AttributeError.  One implementation per slot,
;; dispatching through whatever the receiver's type provides.
;; ============================================================================

;; object.__eq__ / __ne__ / __hash__ and the ordering four.
;;
;; These must not go back through the comparison protocol: a heaptype's
;; tp_richcompare looks __eq__ up in the MRO, finds object's, and if that
;; re-entered the protocol the two would call each other forever.  CPython's
;; are self-contained for the same reason -- identity for __eq__, the type's
;; own EQ slot for __ne__, the address for __hash__.

;; Like __ne__, this defers to the type's own comparison before falling back to
;; identity.  It is reached only when nothing in the MRO defines __eq__ by name,
;; which for a builtin means its answer lives in tp_richcompare -- so comparing
;; addresses here made `a.__eq__(b)` return NotImplemented for two equal tuples.
;; CPython's constant folding shares one empty tuple, which hid it from every
;; test that spelled the operands out.

;; ============================================================================
;; object.__lt__ / __le__ / __gt__ / __ge__ -> NotImplemented, always
;;
;; CPython has all four, and they exist so that a class can call up to them
;; and so that dir(object) is complete.  They were left out here because a
;; builtin subclass looks __lt__ up in its MRO and would find object's
;; NotImplemented before reaching the base type's own comparison -- which is
;; exactly the problem type_install_slots' owner test solves: the dunder was
;; supplied by a type that is not a heaptype, so no wrapper is installed over
;; it and the subclass keeps its base's real slot.  That is what makes these
;; four safe -- `sorted([L([2]), L([1])])` on a list subclass still sorts by
;; contents.
;; ============================================================================
%macro DEF_OBJECT_ORDERING 1
DEF_FUNC object_method_%1
    cmp rsi, 2
    jne %%bad
    extern notimpl_singleton
    lea rax, [rel notimpl_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
%%bad:
    ; CPython reports both counts, and counts self in neither.
    dec rsi                     ; rsi is still nargs on this path
    xor edi, edi
    xor edx, edx                ; check_num_args' wording, with no gap
    extern raise_wrapper_arity
    call raise_wrapper_arity
END_FUNC object_method_%1
%endmacro

DEF_OBJECT_ORDERING lt
DEF_OBJECT_ORDERING le
DEF_OBJECT_ORDERING gt
DEF_OBJECT_ORDERING ge

DEF_FUNC object_method_eq
    cmp rsi, 2
    jne .ome_error
    push rbx
    mov rbx, [rdi + 8]          ; other
    mov rdi, [rdi]              ; self
    V_TEST_PTR rdi, rax
    ja .ome_identity
    test rdi, rdi
    jz .ome_identity
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jz .ome_identity
    ; ...but not when that slot is the generic dispatcher.  It looks __eq__ up
    ; by name, walks to object's, and arrives back here -- unbounded recursion
    ; for any class defining a comparison other than __eq__ (a class that
    ; defines __eq__ never reaches this method at all).  __ne__ takes the same
    ; route through here, so both == and != segfaulted.
    extern slot_tp_richcompare
    lea rcx, [rel slot_tp_richcompare]
    cmp rax, rcx
    je .ome_identity
    mov rsi, rbx
    mov edx, CMP_EQ
    call rax
    V_UNPACK rax, rdx
    test edx, edx
    jz .ome_notimpl
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.ome_notimpl:
    lea rax, [rel notimpl_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.ome_identity:
    cmp rdi, rbx
    je .ome_true_pop
    lea rax, [rel notimpl_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.ome_true_pop:
    pop rbx
.ome_true:
    RET_TRUE
    leave
    V_PACK rax, rdx
    ret
.ome_error:
    RAISE exc_TypeError_type, "__eq__() takes exactly one argument"
END_FUNC object_method_eq

;; __ne__ delegates to the type's own EQ comparison and inverts it, so a class
;; that defines only __eq__ still gets a correct !=.
DEF_FUNC object_method_ne
    cmp rsi, 2
    jne .omn_error
    push rbx
    mov rbx, [rdi + 8]          ; other
    mov rdi, [rdi]              ; self
    V_TEST_PTR rdi, rax
    ja .omn_identity
    test rdi, rdi
    jz .omn_identity
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jz .omn_identity
    mov rsi, rbx
    mov edx, CMP_EQ
    call rax
    V_UNPACK rax, rdx
    test edx, edx
    jz .omn_notimpl
    lea rcx, [rel notimpl_singleton]
    cmp rax, rcx
    je .omn_release_notimpl
    push rax
    push rdx
    mov rdi, rax
    V_PACK rdi, rdx
    extern obj_is_true
    call obj_is_true
    mov ebx, eax
    pop rdx
    pop rdi
    DECREF_VAL rdi, rdx
    test ebx, ebx
    jz .omn_true
    lea rax, [rel bool_false]
    jmp .omn_out
.omn_true:
    lea rax, [rel bool_true]
    jmp .omn_out
.omn_release_notimpl:
    mov rdi, rax
    call obj_decref
.omn_notimpl:
    lea rax, [rel notimpl_singleton]
    jmp .omn_out
.omn_identity:
    ; No tp_richcompare to delegate to, so this stands in for object's own
    ; __eq__ and inverts it: identity is the only thing it answers True to,
    ; and everything else is NotImplemented -- a DECLINE, which is what lets
    ; the other operand's __ne__ be asked.  Answering True here made
    ; `R() != Ord()` True where CPython calls Ord.__ne__, for every plain
    ; class with no comparison of its own.
    cmp rdi, rbx
    jne .omn_notimpl
.omn_same:
    lea rax, [rel bool_false]
.omn_out:
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.omn_error:
    RAISE exc_TypeError_type, "__ne__() takes exactly one argument"
END_FUNC object_method_ne

;; object.__hash__(self) -- the address, which is what obj_hash falls back to
;; when a type has no tp_hash, reached directly so a heaptype's slot cannot
;; bounce back into itself.
;;
;; It used to hand back `args[0] + V_INT_BIAS` without unpacking.  For a
;; pointer the Value IS the address and biasing turns it into an int
;; immediate, which is the intended answer -- but an int immediate is already
;; biased, so it was biased twice and int.__hash__(5) was
;; -1125899906842619.  object_hash takes the decoded pointer; the bias
;; belongs only on the way out.
DEF_FUNC object_method_hash
    cmp rsi, 1
    jl .omh_error
    mov rdi, [rdi]
    V_UNPACK rdi, rdx
    extern object_hash
    call object_hash
    mov rdi, rax                ; boxed, not biased: see DEF_DUNDER_HASH
    extern int_from_i64
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
.omh_error:
    RAISE exc_TypeError_type, "__hash__() takes no arguments"
END_FUNC object_method_hash


;; ============================================================================
;; dict.__getitem__ / __setitem__ / __delitem__
;;
;; These call dict's own implementation rather than dispatching through the
;; instance's mp_ass_subscript.  A dict subclass that overrides __setitem__ has
;; a wrapper in that slot, so a virtual dispatch here turns
;; `super().__setitem__(k, v)` -- the ordinary way to write such an override --
;; into unbounded recursion.  `dict.__setitem__` means dict's, exactly as it
;; does in CPython, where it is a slot wrapper bound to dict.
;; ============================================================================
extern dict_subscript





;; generic_method_hash(args, nargs): args[0]=self
DEF_FUNC generic_method_hash
    cmp rsi, 1
    jne .gmh_error
    mov rdi, [rdi]
    extern obj_hash
    call obj_hash
    mov rdi, rax                ; boxed, not biased: see DEF_DUNDER_HASH
    extern int_from_i64
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
.gmh_error:
    RAISE exc_TypeError_type, "__hash__() takes no arguments"
END_FUNC generic_method_hash

;; ============================================================================
;; DEF_DUNDER_HASH prefix
;;
;; T.__hash__(x) calling the DEFINING type's tp_hash, the same rule
;; DEF_DUNDER_STRREPR and DEF_DUNDER_UNARY follow -- so a subclass reaches
;; the base's hash rather than re-entering its own.
;;
;; Nothing but object registered __hash__, so every builtin resolved the name
;; through the MRO to object's, which answers the ADDRESS:
;; str.__hash__('a') was 403506976 and float.__hash__(1.25) was 1.25.  The
;; stdlib binds these by name -- `__hash__ = tuple.__hash__` in a mixin is
;; ordinary -- and got object's every time.
;; ============================================================================
%macro DEF_DUNDER_HASH 1
DEF_FUNC %1_dunder_hash
    test rsi, rsi
    jz %%bad
    cmp rsi, 1
    jne %%bad
    mov rdi, [rdi]
    lea rsi, [rel %1_type]
    xor edx, edx
    CSTRING rcx, "__hash__"
    extern dunder_require_self
    call dunder_require_self
    mov rdi, rax
    V_UNPACK rdi, rdx
    lea rax, [rel %1_type]
    mov rax, [rax + PyTypeObject.tp_hash]
    test rax, rax
    jz %%bad
    call rax
    ; A hash is a full int64 and most of them fall outside the +-2^50 an
    ; immediate holds, so it has to be boxed rather than biased: adding
    ; V_INT_BIAS to a large one lands in the float range, and
    ; str.__hash__('a') came out as -1.6e-80.
    mov rdi, rax
    extern int_from_i64
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
%%bad:
    dec rsi
    xor edi, edi
    xor edx, edx                ; check_num_args' wording, with no gap
    extern raise_wrapper_arity
    call raise_wrapper_arity
END_FUNC %1_dunder_hash
%endmacro

;; ============================================================================
;; DEF_DUNDER_RICHCMP prefix, suffix, PY_op
;;
;; T.__eq__(a, b) calling the DEFINING type's tp_richcompare -- the same rule
;; DEF_DUNDER_HASH above and DEF_DUNDER_STRREPR follow, so a subclass reaches
;; the base's comparison rather than re-entering its own.
;;
;; No builtin registered __eq__ or __ne__ at all, so every one resolved the
;; name through the MRO to object's, which compares identities:
;; `int.__eq__ is object.__eq__` was True where CPython says False, and
;; dict.__eq__(d, e) answered NotImplemented where CPython compares the
;; contents.  == itself was always right -- it goes through tp_richcompare --
;; so this is the by-name half, and the stdlib asks by name:
;; `__eq__ = dict.__eq__` in a mixin is ordinary.
;; ============================================================================
%macro DEF_DUNDER_RICHCMP 3     ; %1 prefix, %2 suffix, %3 the PY_ op
DEF_FUNC %1_dunder_%2, DB_FRAME
    cmp rsi, 2
    jne %%bad
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    mov [rbp - DB_RHS], rsi
    lea rsi, [rel %1_type]
    xor edx, edx
    CSTRING_DUNDER rcx, %2
    extern dunder_require_self
    call dunder_require_self
    mov rdi, rax
    mov rsi, [rbp - DB_RHS]

    lea rax, [rel %1_type]
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jz %%notimpl
    mov edx, %3
    DUNDER_EXC_SAVE [rbp - DB_EXC]
    call rax
    V_UNPACK rax, rdx
    test edx, edx
    jnz %%out

    ; A slot declines with a NULL Value; by name that has to be
    ; NotImplemented, so the caller can try the reflected form.
    EXC_RAISED_SINCE [rbp - DB_EXC], rcx, %%out
%%notimpl:
    extern notimpl_singleton
    lea rax, [rel notimpl_singleton]
    INCREF rax
    mov edx, TAG_PTR
%%out:
    leave
    V_PACK rax, rdx
    ret
%%bad:
    ; CPython reports both counts, and counts self in neither.
    dec rsi                     ; rsi is still nargs on this path
    mov edi, 1
    xor edx, edx                ; check_num_args' wording, with no gap
    extern raise_wrapper_arity
    call raise_wrapper_arity
END_FUNC %1_dunder_%2
%endmacro

;; All six, because every one of them is the same call with a different op
;; and CPython gives all six to each of these types.  A type whose slot has
;; no ordering -- dict -- answers NotImplemented for the four, which is what
;; its slot already does.
%macro DEF_RICHCMP_PAIR 1
DEF_DUNDER_RICHCMP %1, eq, PY_EQ
DEF_DUNDER_RICHCMP %1, ne, PY_NE
DEF_DUNDER_RICHCMP %1, lt, PY_LT
DEF_DUNDER_RICHCMP %1, le, PY_LE
DEF_DUNDER_RICHCMP %1, gt, PY_GT
DEF_DUNDER_RICHCMP %1, ge, PY_GE
%endmacro

DEF_RICHCMP_PAIR int
DEF_RICHCMP_PAIR str
DEF_RICHCMP_PAIR float
DEF_RICHCMP_PAIR bytes
DEF_RICHCMP_PAIR tuple
DEF_RICHCMP_PAIR dict
DEF_RICHCMP_PAIR list
DEF_RICHCMP_PAIR set
DEF_RICHCMP_PAIR frozenset

; range defines only == and != of its own; the ordering dunders stay
; object's, as they are in CPython.
DEF_DUNDER_RICHCMP range, eq, PY_EQ
DEF_DUNDER_RICHCMP range, ne, PY_NE
DEF_DUNDER_HASH range

DEF_DUNDER_HASH int
DEF_DUNDER_HASH str
DEF_DUNDER_HASH float
DEF_DUNDER_HASH bytes
DEF_DUNDER_HASH tuple
DEF_DUNDER_HASH complex
extern bool_type
extern slice_type
DEF_DUNDER_HASH bool
DEF_DUNDER_HASH slice

;; ============================================================================
;; generic_method_contains(args, nargs) -> bool
;; args[0]=self, args[1]=item
;;
;; `x in c` reaches sq_contains directly, but the method itself was never in
;; any type's dict, so `frozenset(names).__contains__` -- keyword.py's
;; iskeyword, among others -- raised AttributeError.  One implementation
;; serves every type that has the slot.
;; ============================================================================
DEF_FUNC generic_method_contains
    cmp rsi, 2
    jne .gmc_error
    mov rax, [rdi]              ; self
    V_TEST_PTR rax, rcx
    ja .gmc_error
    test rax, rax
    jz .gmc_error
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_as_sequence]
    test rcx, rcx
    jz .gmc_error
    mov rcx, [rcx + PySequenceMethods.sq_contains]
    test rcx, rcx
    jz .gmc_error
    mov rsi, [rdi + 8]          ; the item, as a Value
    mov rdi, rax
    call rcx
    test eax, eax
    jz .gmc_false
    RET_TRUE
    leave
    V_PACK rax, rdx
    ret
.gmc_false:
    RET_FALSE
    leave
    V_PACK rax, rdx
    ret
.gmc_error:
    RAISE exc_TypeError_type, "__contains__() takes exactly one argument"
END_FUNC generic_method_contains

;; ============================================================================
;; new_from_slot(rdi = the type this __new__ belongs to, rsi = args,
;;               rdx = nargs) -> Value
;;
;; The __new__ for a builtin that keeps its constructor in tp_new and has no
;; entry of its own in tp_dict.  `weakref.ref` was the costly one: KeyedRef
;; does `super().__new__(type, ob, callback)`, that found object.__new__
;; instead, and object refuses extra arguments for a type whose real
;; constructor is elsewhere -- so WeakValueDictionary, and everything in the
;; standard library above it, could not be built.
;;
;; The slot called is the OWNER's, taken from rdi, never the argument's.  A
;; subclass that defines __new__ in Python has its own entry ahead of this one
;; in the MRO; reaching for cls->tp_new here would re-enter that and recurse.
;; The owner's constructor already takes the class to build as its first
;; argument, which is how a subclass instance still comes out.
;; ============================================================================
;; ============================================================================
;; new_check_class(rdi = the type this __new__ belongs to, rsi = args,
;;                 rdx = nargs) -> rax = args[0], the class to build; or the
;;                 TypeError is raised and this does not return
;;
;; The three things CPython's tp_new_wrapper checks before any __new__ runs,
;; in its order and with its wording: there is a first argument, it is a type,
;; and it is a subtype of the type whose __new__ was reached.  Skipping the
;; last one is not a message-quality question -- `list.__new__(dict)` built a
;; DICT and handed it back as the result of list's constructor, and every
;; container and scalar __new__ in this tree did that.
;; ============================================================================
extern kw_names_pending
extern type_check_is_class
extern type_is_subtype
extern raise_new_bad_class
NCC_OWNER equ 8
NCC_ARGS  equ 16
NCC_FRAME equ 24                        ; + 1 push = 32, 16-aligned
DEF_FUNC new_check_class, NCC_FRAME
    push rbx
    mov [rbp - NCC_OWNER], rdi
    mov [rbp - NCC_ARGS], rsi
    mov rbx, rdi

    test rdx, rdx
    jz .ncc_no_arg

    mov rdi, [rsi]                      ; cls
    call type_check_is_class
    test eax, eax
    jz .ncc_not_type

    mov rsi, [rbp - NCC_ARGS]
    mov rdi, [rsi]
    mov rsi, rbx
    call type_is_subtype
    test eax, eax
    jz .ncc_not_subtype

    ; ...and the constructor that would actually run for it has to be the one
    ; being asked for.  `int.__new__(bool)` is a subtype call and still wrong:
    ; bool builds itself, so int's constructor would make an int wearing
    ; bool's name.  CPython compares the two tp_new slots and so does this.
    mov rax, [rbp - NCC_ARGS]
    mov rdi, [rax]
    test qword [rdi + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .ncc_static                      ; cls is static: its own slot answers
    extern base_slot
    mov rsi, PyTypeObject.tp_new
    call base_slot                      ; the first STATIC base's constructor
    test rax, rax
    jz .ncc_ok                          ; no static base with one at all
    cmp rax, [rbx + PyTypeObject.tp_new]
    jne .ncc_not_safe
    jmp .ncc_ok
.ncc_static:
    mov rax, [rdi + PyTypeObject.tp_new]
    cmp rax, [rbx + PyTypeObject.tp_new]
    jne .ncc_not_safe
.ncc_ok:
    mov rax, [rbp - NCC_ARGS]
    mov rax, [rax]
    pop rbx
    leave
    ret

.ncc_not_safe:
    mov rdi, rbx
    mov rsi, [rbp - NCC_ARGS]
    mov rsi, [rsi]
    mov edx, 3
    call raise_new_bad_class
.ncc_no_arg:
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    call raise_new_bad_class
.ncc_not_type:
    mov rdi, rbx
    mov rsi, [rbp - NCC_ARGS]
    mov rsi, [rsi]
    mov edx, 1
    call raise_new_bad_class
.ncc_not_subtype:
    mov rdi, rbx
    mov rsi, [rbp - NCC_ARGS]
    mov rsi, [rsi]
    mov edx, 2
    call raise_new_bad_class
END_FUNC new_check_class

;; ============================================================================
;; new_from_slot(rdi = the type this __new__ belongs to, rsi = args,
;;               rdx = nargs) -> Value
;;
;; The __new__ for a builtin that keeps its constructor in tp_new and has no
;; entry of its own in tp_dict.  `weakref.ref` was the costly one: KeyedRef
;; does `super().__new__(type, ob, callback)`, that found object.__new__
;; instead, and object refuses extra arguments for a type whose real
;; constructor is elsewhere -- so WeakValueDictionary, and everything in the
;; standard library above it, could not be built.
;;
;; The slot called is the OWNER's, taken from rdi, never the argument's.  A
;; subclass that defines __new__ in Python has its own entry ahead of this one
;; in the MRO; reaching for cls->tp_new here would re-enter that and recurse.
;; The owner's constructor already takes the class to build as its first
;; argument, which is how a subclass instance still comes out.
;; ============================================================================
DEF_FUNC new_from_slot, 8               ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    mov rbx, rdi                        ; the owning type
    mov r12, rsi                        ; args
    mov r13, rdx                        ; nargs

    call new_check_class                ; raises for all three refusals

    mov rax, [rbx + PyTypeObject.tp_new]
    test rax, rax
    jz .nfs_no_ctor                     ; an owner with no constructor at all

    mov rdi, [r12]                      ; cls
    lea rsi, [r12 + 8]                  ; the arguments after cls
    lea rdx, [r13 - 1]
    pop r13
    pop r12
    pop rbx
    leave
    jmp rax                             ; the slot returns a Value already

.nfs_no_ctor:
    mov rdi, rbx
    mov rsi, [r12]
    mov edx, 2
    call raise_new_bad_class
END_FUNC new_from_slot

;; ============================================================================
;; The per-type __new__ entry points.
;;
;; container_dunder_new serves list, tuple, dict, set and frozenset, and
;; scalar_dunder_new serves int, str, float and complex: one body each,
;; because what they do is decided by the class argument's own flags.  That is
;; also why neither could check the argument -- a shared body does not know
;; which type's dict it was reached through, and "is dict a subtype of list"
;; is a question about the OWNER.  So each type gets four lines that name it,
;; and `list.__new__(dict)` stops answering `{}`.
;; ============================================================================
%macro NEW_THUNK 3-4            ; %1 = symbol, %2 = owner type, %3 = the body,
                                ; %4 = the message when the type takes NO
                                ; keywords at all
DEF_FUNC %1                     ; 2 pushes + frame 0 = 16, 16-aligned
    push rbx
    push r12
    mov rbx, rdi                ; args
    mov r12, rsi                ; nargs
    lea rdi, [rel %2]
    mov rsi, rbx
    mov rdx, r12
    call new_check_class        ; raises for a bad class argument; rax = cls
%if %0 >= 4
    NO_KEYWORDS_TP_INIT %2, %4
%endif
    ; __new__ CONSUMES the keywords, which is the contract type_call states --
    ; it hands them back to __init__ from its own saved copy.  Leaving them set
    ; gave them to whatever the body calls next: a frozenset subclass's
    ; __new__ fills itself through set.update, which refuses keywords, so
    ; `class FS(frozenset)` with its own __init__ was refused under update's
    ; name before its __init__ ever ran.
    mov qword [rel kw_names_pending], 0
    mov rdi, rbx
    mov rsi, r12
    call %3
    pop r12
    pop rbx
    leave
    ret
END_FUNC %1
%endmacro

extern container_dunder_new
extern set_type
extern module_type
extern module_method_new
NEW_THUNK list_dunder_new,      list_type,      container_dunder_new
NEW_THUNK tuple_dunder_new,     tuple_type,     container_dunder_new, "tuple() takes no keyword arguments"
NEW_THUNK dict_dunder_new,      dict_type,      container_dunder_new
NEW_THUNK set_dunder_new,       set_type,       container_dunder_new
NEW_THUNK frozenset_dunder_new, frozenset_type, container_dunder_new, "frozenset() takes no keyword arguments"
NEW_THUNK int_dunder_new,       int_type,       scalar_dunder_new
NEW_THUNK str_dunder_new,       str_type,       scalar_dunder_new
NEW_THUNK float_dunder_new,     float_type,     scalar_dunder_new, "float() takes no keyword arguments"
NEW_THUNK complex_dunder_new,   complex_type,   scalar_dunder_new
NEW_THUNK module_dunder_new,    module_type,    module_method_new
