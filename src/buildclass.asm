; buildclass.asm - Building a class object
;
; type.__new__, type_from_parts, __build_class__, and the keyword handling
; between them.  This is what `class C(B, metaclass=M): ...` compiles down to:
; resolve the metaclass, run __prepare__, execute the body into the namespace
; it returns, build the type, then apply __set_name__ to every descriptor in it.

%include "macros.inc"
%include "object.inc"
extern bool_true
extern type_check_is_class
extern bool_false

extern type_is_subtype
extern dict_copy_shallow
extern dict_type
extern dict_new
extern dunder_call_3
extern dunder_lookup
extern dict_get
extern dict_set
extern str_from_cstr_heap
extern obj_getattr_opt
extern obj_call_n
extern tuple_new
extern obj_incref
extern obj_decref
extern bool_type
extern gc_alloc
extern gc_track
extern raise_exception
extern eval_frame
extern frame_new
extern ap_malloc
extern ap_free
extern ap_memcpy
extern str_new_heap
extern str_type
extern frame_free
extern instance_dealloc
extern instance_repr
extern instance_getattr
extern instance_setattr
extern type_call
extern user_type_metatype
extern staticmethod_type
extern classmethod_type
extern func_type
extern type_type
extern list_type
extern tuple_type
extern bytes_type
extern ap_strcmp
extern object_type
extern obj_dealloc

; New builtin function implementations (in builtins_extra.asm)
extern bytearray_type
extern memoryview_type

; Iterator builtins (in itertools.asm)

; Exception types
extern exc_TypeError_type

; --- moved to a sibling file by the split ---
extern builtins_dict_global

section .text

;; ============================================================================
;; type.__new__(mcls, name, bases, ns) -> a new class whose metatype is mcls
;;
;; A metaclass __new__ almost always ends in
;; `super().__new__(mcls, name, bases, ns)`, and without this that resolved to
;; object.__new__ and produced an *instance* of the metaclass rather than a
;; class.  ABCMeta is written exactly that way, so abc.py depends on it.
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

    mov rdi, [rbx + 8]              ; name
    mov rsi, [rbx + 16]             ; bases
    mov rdx, [rbx + 24]             ; namespace
    ; type_from_parts adopts a reference to each
    push rdi
    call obj_incref
    pop rdi
    push rdi
    mov rdi, rdx
    call obj_incref
    pop rdi
    mov rsi, [rbx + 16]
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
    RAISE exc_TypeError_type, "type.__new__() takes at least 3 arguments"
END_FUNC type_method_new

;; ============================================================================
;; type.__init__(cls, ...) -> None
;;
;; A no-op, as CPython's type_init is -- but a REGISTERED one.  `type` had no
;; __init__ in its dict, so a metaclass ending in `super().__init__(name,
;; bases, ns)` walked past it to object's, which now refuses arguments it
;; has nowhere to put.  CPython takes one or three besides the class.
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
    RAISE exc_TypeError_type, "type.__init__() takes 1 or 3 arguments"
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
    RAISE exc_TypeError_type, "__instancecheck__() takes exactly one argument"
END_FUNC type_method_instancecheck

;; type_method_subclasscheck(args, nargs) -> Value, documented with its twin
;; above: the same plain check, over two classes rather than a class and an
;; instance.
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
    RAISE exc_TypeError_type, "issubclass() arg 1 must be a class"
.tsc_error:
    RAISE exc_TypeError_type, "__subclasscheck__() takes exactly one argument"
END_FUNC type_method_subclasscheck


;; ============================================================================
;; type_apply_set_name(PyTypeObject *cls, PyDictObject *ns)
;;
;; Call __set_name__(owner, name) on every value in the class body that defines
;; one, once the class exists.  It is the hook a descriptor uses to learn what
;; it was assigned to, and enum is built on it: each member starts as a
;; _proto_member and __set_name__ is what replaces it with the real member.
;;
;; The names are snapshotted first, because a __set_name__ is entitled to
;; setattr on the owner -- which is this very dict, and rehashing it under the
;; walk would lose entries.
;;
;; Returns 0 when one of them raised.  Returning the class anyway would leave
;; the exception pending with nothing to attach it to, and the next opcode to
;; look at a NULL would be the one that crashed.
;; ============================================================================
TSN_CLS   equ 8
TSN_NS    equ 16
TSN_KEYS  equ 24
TSN_I     equ 32
TSN_N     equ 40
TSN_NAME  equ 48
TSN_FRAME equ 56          ; + 3 pushes = 80
DEF_FUNC type_apply_set_name, TSN_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - TSN_CLS], rdi
    mov [rbp - TSN_NS], rsi
    test rsi, rsi
    jz .done

    ; --- snapshot the keys ---
    mov r12, [rsi + PyDictObject.capacity]
    mov r13, [rsi + PyDictObject.entries]
    xor ebx, ebx
    xor ecx, ecx
.count:
    cmp rcx, r12
    jae .counted
    imul rax, rcx, DICT_ENTRY_SIZE
    cmp qword [r13 + rax + DictEntry.key], 0
    je .count_next
    inc rbx
.count_next:
    inc rcx
    jmp .count
.counted:
    test rbx, rbx
    jz .done
    mov [rbp - TSN_N], rbx
    mov rdi, rbx
    call tuple_new
    test rax, rax
    jz .done
    mov [rbp - TSN_KEYS], rax
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rsi, [rbp - TSN_NS]
    mov r12, [rsi + PyDictObject.capacity]
    mov r13, [rsi + PyDictObject.entries]
    xor ebx, ebx
    xor ecx, ecx
.fill:
    cmp rcx, r12
    jae .filled
    imul rax, rcx, DICT_ENTRY_SIZE
    mov rdi, [r13 + rax + DictEntry.key]
    test rdi, rdi
    jz .fill_next
    INCREF_V rdi, r8
    mov [rdx + rbx*8], rdi
    inc rbx
.fill_next:
    inc rcx
    jmp .fill
.filled:

    ; --- call each value's __set_name__, if its TYPE defines one ---
    mov qword [rbp - TSN_I], 0
.loop:
    mov rax, [rbp - TSN_I]
    cmp rax, [rbp - TSN_N]
    jae .release
    mov rcx, [rbp - TSN_KEYS]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov rcx, [rcx + rax*8]
    mov [rbp - TSN_NAME], rcx

    mov rdi, [rbp - TSN_NS]
    mov rsi, rcx
    call dict_get
    V_UNPACK rax, rdx
    test edx, edx
    jz .next                            ; deleted while we walked
    ; The classification is the TAG's to make: after V_UNPACK rax holds a
    ; payload, and testing a payload as if it were a Value calls a small int a
    ; pointer.
    cmp edx, TAG_PTR
    jne .next
    test rax, rax
    jz .next
    mov rbx, rax

    ; Looked up on the type, not the instance: an instance attribute called
    ; __set_name__ is not the hook.
    mov rdi, [rbx + PyObject.ob_type]
    lea rsi, [rel tsn_name]
    call dunder_lookup
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    jz .next

    mov rdi, rbx                        ; self = the value
    mov rsi, [rbp - TSN_CLS]            ; owner
    mov rdx, [rbp - TSN_NAME]           ; name
    lea rcx, [rel tsn_name]
    mov r8d, TAG_PTR
    call dunder_call_3
    test rax, rax               ; dunder_call_3 answers with a Value; 0 is the miss
    jz .raised
    mov rdi, rax
    DECREF_V rdi, rsi
.next:
    inc qword [rbp - TSN_I]
    jmp .loop

.release:
    mov rdi, [rbp - TSN_KEYS]
    call obj_decref
.done:
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    leave
    ret
.raised:
    mov rdi, [rbp - TSN_KEYS]
    call obj_decref
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_apply_set_name

;; ============================================================================
;; type_mangle_name(rdi = the name, rsi = the class name) -> rax = an OWNED
;;                  reference: a new string when it mangles, the argument with
;;                  one more reference when it does not
;;
;; CPython's rule, and the same one comp_intern_name applies at compile time:
;; two leading underscores, not two trailing ones, and the class name with its
;; own leading underscores stripped -- an all-underscore class name mangles
;; nothing.  Both have to agree, or a slot and the code that uses it name
;; different things.
;; ============================================================================
TMN_NAME  equ 8
TMN_CLS   equ 16
TMN_BUF   equ 24
TMN_LEN   equ 32
TMN_FRAME equ 48                ; 32 used + 16 pad = 48, 16-aligned
global type_mangle_name
DEF_FUNC type_mangle_name, TMN_FRAME
    push rbx
    push r12
    mov [rbp - TMN_NAME], rdi
    mov [rbp - TMN_CLS], rsi

    test rsi, rsi
    jz .tmn_plain
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .tmn_plain
    mov rax, [rdi + PyObject.ob_type]
    cmp rax, rcx
    jne .tmn_plain

    mov rdx, [rdi + PyStrObject.ob_size]
    cmp rdx, 2
    jl .tmn_plain
    cmp byte [rdi + PyStrObject.data], '_'
    jne .tmn_plain
    cmp byte [rdi + PyStrObject.data + 1], '_'
    jne .tmn_plain
    ; ...but not one that also ends in two underscores.
    cmp rdx, 4
    jl .tmn_mangle
    cmp byte [rdi + PyStrObject.data + rdx - 1], '_'
    jne .tmn_mangle
    cmp byte [rdi + PyStrObject.data + rdx - 2], '_'
    je .tmn_plain

.tmn_mangle:
    ; Strip the class name's own leading underscores.
    mov rsi, [rbp - TMN_CLS]
    lea rbx, [rsi + PyStrObject.data]
    mov r12, [rsi + PyStrObject.ob_size]
.tmn_strip:
    test r12, r12
    jz .tmn_plain               ; nothing but underscores: no mangling
    cmp byte [rbx], '_'
    jne .tmn_stripped
    inc rbx
    dec r12
    jmp .tmn_strip
.tmn_stripped:

    ; "_" + the stripped class name + the name
    mov rdi, [rbp - TMN_NAME]
    mov rax, [rdi + PyStrObject.ob_size]
    lea rdi, [rax + r12 + 2]
    mov [rbp - TMN_LEN], rdi
    call ap_malloc
    test rax, rax
    jz .tmn_plain
    mov [rbp - TMN_BUF], rax
    mov byte [rax], '_'
    lea rdi, [rax + 1]
    mov rsi, rbx
    mov rdx, r12
    call ap_memcpy
    mov rdi, [rbp - TMN_BUF]
    lea rdi, [rdi + r12 + 1]
    mov rsi, [rbp - TMN_NAME]
    mov rdx, [rsi + PyStrObject.ob_size]
    lea rsi, [rsi + PyStrObject.data]
    call ap_memcpy
    mov rdi, [rbp - TMN_BUF]
    mov rsi, [rbp - TMN_NAME]
    mov rsi, [rsi + PyStrObject.ob_size]
    lea rsi, [rsi + r12 + 1]
    call str_new_heap           ; -> rax = PyStrObject*, refcount 1
    push rax
    mov rdi, [rbp - TMN_BUF]
    call ap_free
    pop rax
    pop r12
    pop rbx
    leave
    ret

.tmn_plain:
    mov rax, [rbp - TMN_NAME]
    INCREF rax
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_mangle_name

;; ============================================================================
;; bc_fill_cell(rdi = the class namespace, rsi = a cstring name, rdx = a Value,
;;              rcx = the refusal to raise when the name is not a cell)
;;   -> nothing, or does not return
;;
;; Fill the cell the compiler left under that name, then take the name back
;; out: both cells a class body can leave are plumbing rather than attributes,
;; and CPython's type_new deletes each after using it.  A missing name is the
;; ordinary case and does nothing.
;;
;; What is under the name need not be a cell: a metaclass can put anything
;; there, and CPython's own test_super puts None, 0, "" and object() there on
;; purpose.  This wrote the class straight into PyCellObject.ob_ref of
;; whatever it found -- into the None singleton, or through an int immediate
;; as if it were an address.
;; ============================================================================
BFC_DICT equ 8
BFC_NAME equ 16
BFC_VAL  equ 24
BFC_KEY  equ 32
BFC_MSG  equ 40
BFC_FOUND equ 48                ; what was under the name, across the release
BFC_FRAME equ 64                ; + 0 pushes, 16-aligned
DEF_FUNC_LOCAL bc_fill_cell, BFC_FRAME
    mov [rbp - BFC_DICT], rdi
    mov [rbp - BFC_NAME], rsi
    mov [rbp - BFC_VAL], rdx
    mov [rbp - BFC_MSG], rcx

    mov rdi, rsi
    call str_from_cstr_heap
    test rax, rax
    jz .bfc_out
    mov [rbp - BFC_KEY], rax
    mov rdi, [rbp - BFC_DICT]
    mov rsi, rax
    call dict_get                       ; a Value; 0 is the miss
    test rax, rax
    jz .bfc_drop_key

    ; It has to BE a cell.  CPython's type_new asks the same question and
    ; words the refusal the same way, naming the type it found instead.
    mov [rbp - BFC_FOUND], rax
    V_TEST_PTR rax, rcx
    ja .bfc_not_a_cell
    mov rcx, [rax + PyObject.ob_type]
    extern cell_type
    lea rdx, [rel cell_type]
    cmp rcx, rdx
    jne .bfc_not_a_cell

    mov rcx, [rbp - BFC_VAL]
    mov [rax + PyCellObject.ob_ref], rcx  ; a pointer is its own Value
    mov rdi, rcx
    call obj_incref
    mov rdi, [rbp - BFC_DICT]
    mov rsi, [rbp - BFC_KEY]
    extern dict_del_opt
    call dict_del_opt
.bfc_drop_key:
    mov rdi, [rbp - BFC_KEY]
    call obj_decref
.bfc_out:
    leave
    ret

.bfc_not_a_cell:
    ; Release the interned key first: the raise abandons this frame.
    mov rdi, [rbp - BFC_KEY]
    call obj_decref
    mov rdi, [rbp - BFC_MSG]
    mov rsi, [rbp - BFC_FOUND]
    extern raise_type_error_with_name
    leave
    jmp raise_type_error_with_name      ; does not return
END_FUNC bc_fill_cell

;; ============================================================================
;; type_from_parts(rdi = name str, rsi = bases tuple or NULL, rdx = namespace dict)
;;   -> rax = the new type object, one strong reference
;;
;; The heaptype construction shared by __build_class__ and the three-argument
;; type().  Extracted rather than duplicated: type() used to fall through to
;; type_call's .normal_type_call, which treats type_type as an ordinary class
;; -- it allocated an instance-sized block and let type fields be written into
;; it, printing <class ''> and then aborting with a double free.
;;
;; The frame is built by hand, not by DEF_FUNC's size argument, so that the
;; body's [rbp - TFP_BASE] slot keeps meaning what it meant inside __build_class__.
;; ============================================================================
; The class keywords `class C(B, tag="t")` carries.  __init_subclass__ is
; called from inside type_from_parts, which never saw them -- so a base that
; declares `def __init_subclass__(cls, **kw)` was handed an empty kw.  Set
; around the call and cleared by it, the same convention kw_names_pending uses.
; class_kwnames_pending / class_kwvalues_pending, which lives in ThreadState (src/include/threadstate.inc).
;
; The metatype `type.__new__(mcls, ...)` was handed.  It used to be stamped on
; the finished class by type_method_new, AFTER type_from_parts had already run
; every descriptor's __set_name__ -- so a __set_name__ saw an owner whose type
; was the default metatype, and `cls.__members__` inside one was an
; AttributeError.  enum.py is written exactly that way, so fourteen stdlib
; modules stopped there.  Set around the call and cleared by it, the same
; convention class_kwnames_pending uses.  class_metatype_pending, also in
; ThreadState.


;; ============================================================================
;; bc_solid_base(rdi = type) -> rax = the type its instance layout belongs to
;;
;; CPython's solid_base: walk down tp_base for as long as the type adds
;; nothing to its base's layout except the instance dict word.  What comes
;; back is the type that actually owns the shape of the instance -- `list` for
;; any number of plain subclasses of list, `object` for a plain class.
;;
;; The dict word is excluded deliberately, exactly as extra_ivars() excludes
;; it: every heaptype over a builtin adds one, and if that counted as a layout
;; of its own then no two of them could ever be combined.
;; ============================================================================
DEF_FUNC_LOCAL bc_solid_base
.sb_loop:
    mov rsi, [rdi + PyTypeObject.tp_base]
    test rsi, rsi
    jz .sb_done                     ; object itself, or a base-less builtin
    mov rax, [rdi + PyTypeObject.tp_basicsize]
    mov rcx, [rsi + PyTypeObject.tp_basicsize]

    mov rdx, [rdi + PyTypeObject.tp_dictoffset]
    test rdx, rdx
    jz .sb_compare                  ; no dict word to discount
    cmp qword [rsi + PyTypeObject.tp_dictoffset], 0
    jne .sb_compare                 ; the base already had one
    test qword [rdi + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .sb_compare
    cmp rdx, rcx
    jb .sb_compare                  ; inside the base's own layout, not added
    lea r8, [rdx + 8]
    cmp r8, rax
    jne .sb_compare                 ; TP_DICT_AT_TAIL, or not the last word
    sub rax, 8

.sb_compare:
    cmp rax, rcx
    jne .sb_done                    ; it adds a layout of its own
    mov rdi, rsi
    jmp .sb_loop

.sb_done:
    mov rax, rdi
    leave
    ret
END_FUNC bc_solid_base

;; ============================================================================
;; bc_take_qualname(r12 = the new heaptype) -> nothing
;;
;; Moves __qualname__ out of tp_dict and into ht_qualname.  CPython's type_new
;; does the same.  Whether it IS a str was settled by bc_check_qualname before
;; the type existed, so nothing here raises.
;; ============================================================================
BTQ_KEY   equ 8
BTQ_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL bc_take_qualname, BTQ_FRAME
    mov rdi, [r12 + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .btq_done
    lea rdi, [rel bc_qualname_name]
    call str_from_cstr_heap
    test rax, rax
    jz .btq_done
    mov [rbp - BTQ_KEY], rax
    mov rdi, [r12 + PyTypeObject.tp_dict]
    mov rsi, rax
    call dict_get
    test rax, rax
    jz .btq_release_key

    ; A str, and bc_check_qualname has already said so.
    V_TEST_PTR rax, rcx
    ja .btq_release_key
    mov rcx, [rax + PyObject.ob_type]
    extern str_type
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .btq_release_key

    INCREF rax                  ; ht_qualname owns it
    mov [r12 + HT_QUALNAME], rax
    mov rdi, [r12 + PyTypeObject.tp_dict]
    mov rsi, [rbp - BTQ_KEY]
    extern dict_del_opt
    call dict_del_opt

.btq_release_key:
    mov rdi, [rbp - BTQ_KEY]
    call obj_decref
.btq_done:
    leave
    ret

END_FUNC bc_take_qualname

;; ============================================================================
;; bc_check_qualname(rdi = the class body namespace, or 0) -> nothing; may
;;   raise and then does not return
;;
;; "type __qualname__ must be a str, not int", which CPython's type_new says
;; before it builds anything.  Separate from the move above because it has to
;; run BEFORE the type object exists: a raise from after the half-built class
;; is registered in build_class_pending goes through a teardown this early
;; stage is not ready for.
;; ============================================================================
BCQ_KEY   equ 8
BCQ_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL bc_check_qualname, BCQ_FRAME
    test rdi, rdi
    jz .bcq_done
    mov rax, [rdi + PyObject.ob_type]
    extern dict_type
    lea rcx, [rel dict_type]
    cmp rax, rcx
    jne .bcq_done               ; a __prepare__ mapping: type_new does not look
    push rdi
    sub rsp, 8
    lea rdi, [rel bc_qualname_name]
    call str_from_cstr_heap
    add rsp, 8
    pop rdi
    test rax, rax
    jz .bcq_done
    mov [rbp - BCQ_KEY], rax
    mov rsi, rax
    call dict_get
    push rax
    sub rsp, 8
    mov rdi, [rbp - BCQ_KEY]
    call obj_decref
    add rsp, 8
    pop rax
    test rax, rax
    jz .bcq_done
    V_TEST_PTR rax, rcx
    ja .bcq_not_str
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    je .bcq_done
.bcq_not_str:
    mov rsi, rax
    lea rdi, [rel bc_qualname_not_str]
    extern raise_type_error_with_name
    jmp raise_type_error_with_name      ; does not return
.bcq_done:
    leave
    ret
END_FUNC bc_check_qualname

section .rodata
bc_qualname_name:    db "__qualname__", 0
bc_qualname_not_str: db "type __qualname__ must be a str, not ", 1, 0
section .text


;; ============================================================================
;; bc_slot_is_dict_name(rdi = a slot-name str) -> eax = 1 when it is __dict__
;;
;; A str, and its callers are what guarantee that: this reads PyStrObject.data
;; off what it is handed, so a bytes or an int item would be compared as a
;; string.  bc_slots_validate refuses every non-str before anything below gets
;; to look at one.
;; ============================================================================
DEF_FUNC_LOCAL bc_slot_is_dict_name
    lea rsi, [rdi + PyStrObject.data]
    CSTRING rdi, "__dict__"
    xchg rdi, rsi
    extern ap_strcmp
    call ap_strcmp
    test eax, eax
    jnz .bsidn_no
    mov eax, 1
    leave
    ret
.bsidn_no:
    xor eax, eax
    leave
    ret
END_FUNC bc_slot_is_dict_name

;; ============================================================================
;; bc_slots_validate(rdi = slots sequence, rsi = nslots, edx = 1 when a base
;;                   already supplies an instance dict)
;;   -> eax = 1 when one of the names is '__dict__'; raises and does not return
;;      when an item is not a usable slot name
;;
;; CPython's valid_identifier, plus type_new_slots_impl's two special cases.
;; Every item must be a str and every str must be an identifier: a non-str was
;; SKIPPED here, which is worse than refusing it -- `__slots__ = (42,)` built a
;; class whose declared slot did not exist -- and '__dict__' was only ever
;; looked for, never counted, so naming it twice was accepted where CPython
;; says "we already got one".  The same message covers a base that has a dict
;; already, and the order of the two checks is CPython's, so a __slots__ that
;; is wrong in more than one way names the same complaint it does.
;; ============================================================================
BSV_N      equ 8
BSV_ITEMS  equ 16
BSV_I      equ 24
BSV_MAYNOT equ 32           ; a base has a dict, so '__dict__' is an error
BSV_SEEN   equ 40           ; '__dict__' has already been named
BSV_FRAME  equ 48           ; 0 pushes, 16-aligned
DEF_FUNC_LOCAL bc_slots_validate, BSV_FRAME
    mov [rbp - BSV_N], rsi
    mov [rbp - BSV_MAYNOT], rdx
    mov qword [rbp - BSV_SEEN], 0
    mov rax, [rdi + PyTupleObject.ob_item]
    mov [rbp - BSV_ITEMS], rax
    mov qword [rbp - BSV_I], 0
.bsv_loop:
    mov rcx, [rbp - BSV_I]
    cmp rcx, [rbp - BSV_N]
    jge .bsv_done
    mov rax, [rbp - BSV_ITEMS]
    mov rdi, [rax + rcx*8]

    ; A str, or the whole __slots__ is refused.  An int or a float gets here
    ; as an immediate, so the pointer test comes first -- asking one for its
    ; ob_type would read the number.
    V_TEST_PTR rdi, rdx
    ja .bsv_not_str
    mov rax, [rdi + PyObject.ob_type]
    REQUIRE_STR_TYPE rax, rdx, .bsv_not_str

    ; And an identifier, which is the same test str.isidentifier makes.
    extern str_pred_impl
    push rdi
    mov esi, 10                 ; the isidentifier predicate
    call str_pred_impl
    pop rdi
    test eax, eax
    jz .bsv_not_identifier

    call bc_slot_is_dict_name
    test eax, eax
    jz .bsv_next
    cmp qword [rbp - BSV_MAYNOT], 0
    jne .bsv_double_dict
    cmp qword [rbp - BSV_SEEN], 0
    jne .bsv_double_dict
    mov qword [rbp - BSV_SEEN], 1
.bsv_next:
    inc qword [rbp - BSV_I]
    jmp .bsv_loop
.bsv_done:
    mov rax, [rbp - BSV_SEEN]
    leave
    ret

.bsv_not_str:
    ; rdi is still the item, and raise_type_error_with_name names a Value's
    ; type whether it is a pointer or not.
    mov rsi, rdi
    CSTRING rdi, `__slots__ items must be strings, not '\x01'`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.bsv_not_identifier:
    extern exc_TypeError_type
    RAISE exc_TypeError_type, "__slots__ must be identifiers"

.bsv_double_dict:
    RAISE exc_TypeError_type, "__dict__ slot disallowed: we already got one"
END_FUNC bc_slots_validate

DEF_FUNC type_from_parts
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 88             ; the epilogue's `add rsp` must match this

TFP_BASE  equ 48            ; the layout base: the widest of the bases
TFP_BASES equ 56            ; the bases tuple, or NULL
TFP_EXC   equ 64            ; current_exception, to tell a raise from a miss
TFP_SLOTV equ 72            ; the tag of whatever __slots__ holds
TFP_SLOT1 equ 80            ; a one-tuple built for `__slots__ = 'name'`, owned
TFP_TAIL  equ 88            ; 1 when the slots go at the instance's TAIL
TFP_WANTDICT equ 96         ; 1 when __slots__ names '__dict__' itself
; Whether THIS class contributes the instance dict, and whether it contributes
; weak-referenceability -- the two questions that decide the __dict__ and
; __weakref__ entries.  Both are answered where TFP_BASE is in scope, because
; bc_base_has_dict reads it through the saved rbp.
TFP_ADDDICT equ 104
TFP_ADDWEAK equ 112
    mov r14, rdi                ; class name str
    mov r15, rdx                ; namespace dict, becomes tp_dict
    mov [rbp - TFP_BASES], rsi
    DUNDER_EXC_SAVE [rbp - TFP_EXC]

    ; tp_dict is a COPY of the namespace, never the namespace itself.  The
    ; caller's reference is transferred to us either way, so the original is
    ; released here.
    ;
    ; Adopting it made `ns` and the live class the same object: `ns['y'] = 2`
    ; after `type('C', (), ns)` added an attribute to C, where CPython's
    ; type_new copied and answers False to hasattr(C, 'y').  It is also what
    ; would make a version-tag cache unsound -- lib/enum.py writes into the
    ; class body namespace after the class exists (`classdict['__str__'] =`),
    ; and none of those writes go through type_setattr.
    ;
    ; Only an exact dict is copied.  A __prepare__ that returns something else
    ; is adopted as before; the rest of this function already assumes a dict
    ; and would be no worse off.
    test r15, r15
    jz .tfp_ns_ready
    mov rax, [r15 + PyObject.ob_type]
    lea rcx, [rel dict_type]
    cmp rax, rcx
    jne .tfp_ns_ready
    mov rdi, r15
    call dict_copy_shallow
    test rax, rax
    jz .tfp_ns_ready            ; copy failed; keep the original
    mov rdi, r15                ; the caller's namespace, ours to release
    mov r15, rax
    call obj_decref
.tfp_ns_ready:
    mov rsi, [rbp - TFP_BASES]  ; the scan below still reads it, and the calls
                                ; above are free to clobber a caller-saved reg

    ; The layout base is the widest base, not simply the first: `class
    ; C(Mixin, list)` has to be laid out as a list.  Ties go to the earlier
    ; base, which is what CPython's solid-base rule gives for the ordinary
    ; single-inheritance case -- except that a plain heaptype is only as wide
    ; as it is because it carries a __dict__, which is not a layout the way a
    ; builtin's inline value is.  float is 24 bytes and so is an ordinary
    ; heaptype, so `class MF(Mixin, float)` picked Mixin and the double had
    ; nowhere to live.  On a tie the static base wins.
    xor eax, eax                ; best base
    test rsi, rsi
    jz .tfp_base_done
    mov rcx, [rsi + PyTupleObject.ob_size]
    mov r8, [rsi + PyTupleObject.ob_item]
    xor r9, r9
    xor r10, r10                ; best basicsize
.tfp_base_scan:
    cmp r9, rcx
    jge .tfp_base_done
    mov r11, [r8 + r9*8]
    test r11, r11
    jz .tfp_base_next
    mov rdx, [r11 + PyTypeObject.tp_basicsize]
    cmp rdx, r10
    ja .tfp_base_take
    jb .tfp_base_next
    ; Equal widths: take this one only if the incumbent is a heaptype and
    ; this is not.
    test rax, rax
    jz .tfp_base_next
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .tfp_base_next           ; the incumbent is already a builtin
    test qword [r11 + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jnz .tfp_base_next
    ; ...and only when the heaptype's own layout is object's.  One that
    ; descends from a builtin of the same width already IS that layout:
    ; `class G(F, ValueError)` with F an OSError subclass has to stay an
    ; OSError -- picking ValueError lost OSError's constructor, and with it
    ; .errno and .strerror (ssl.SSLCertVerificationError is that shape).
    mov rdx, rax
.tfp_base_static_of:
    mov rdx, [rdx + PyTypeObject.tp_base]
    test rdx, rdx
    jz .tfp_base_tie_take
    test qword [rdx + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jnz .tfp_base_static_of
    lea rdi, [rel object_type]
    cmp rdx, rdi
    jne .tfp_base_next          ; a real layout of its own: keep it
.tfp_base_tie_take:
    mov rdx, r10                ; the widths are equal
.tfp_base_take:
    mov r10, rdx
    mov rax, r11
.tfp_base_next:
    inc r9
    jmp .tfp_base_scan
.tfp_base_done:
    mov [rbp - TFP_BASE], rax   ; layout base, or NULL

    ; A base CPython refuses.  The check goes here rather than in
    ; __build_class__, where the one for `bool` used to live on its own:
    ; type(name, bases, ns) reaches this and not that, so `type("B", (bool,),
    ; {})` was accepted while `class B(bool)` was not.
    cmp qword [rbp - TFP_BASES], 0
    je .tfp_final_ok
    xor r9, r9
.tfp_final_scan:
    mov rcx, [rbp - TFP_BASES]
    cmp r9, [rcx + PyTupleObject.ob_size]
    jge .tfp_final_ok
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov rcx, [rcx + r9*8]
    test rcx, rcx
    jz .tfp_final_next
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_FINAL
    jnz .tfp_final_base
.tfp_final_next:
    inc r9
    jmp .tfp_final_scan
.tfp_final_base:
    mov rdi, [rcx + PyTypeObject.tp_name]
    extern raise_final_base
    call raise_final_base
.tfp_final_ok:

    ; Two bases whose layouts are unrelated cannot both be laid out in one
    ; instance.  `class C(MyList, MyDict)` was accepted here and laid out as
    ; whichever base was wider, after which the family flags were OR'd from
    ; both and instance_dealloc ran whichever storage arm it tested first.
    ; CPython answers "multiple bases have instance lay-out conflict", and the
    ; question it asks is about the solid bases: unless one is a subtype of
    ; the other, the two shapes cannot be nested.
    ;
    ; rbx, r12 and r13 are free here -- r12 does not become the new type until
    ; the allocation below, and nothing has claimed the other two.
    test rax, rax
    jz .tfp_layout_ok
    mov rdi, rax
    call bc_solid_base
    mov r13, rax                ; the layout base's solid base
    cmp qword [rbp - TFP_BASES], 0
    je .tfp_layout_ok
    xor ebx, ebx
.tfp_layout_scan:
    mov rcx, [rbp - TFP_BASES]
    cmp rbx, [rcx + PyTupleObject.ob_size]
    jge .tfp_layout_ok
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov rdi, [rcx + rbx*8]
    test rdi, rdi
    jz .tfp_layout_next
    call bc_solid_base
    mov r12, rax
    mov rdi, r13
    mov rsi, r12
    call type_is_subtype
    test eax, eax
    jnz .tfp_layout_next
    mov rdi, r12
    mov rsi, r13
    call type_is_subtype
    test eax, eax
    jz .tfp_layout_conflict
.tfp_layout_next:
    inc rbx
    jmp .tfp_layout_scan
.tfp_layout_conflict:
    RAISE exc_TypeError_type, "multiple bases have instance lay-out conflict"
.tfp_layout_ok:
    ; A subtype of int, bytes or tuple cannot carry slots.  int wraps its
    ; value rather than embedding it and the other two keep their data
    ; inline, so a slot laid out at the base's basicsize lands inside that
    ; data or past the allocation entirely -- `class N(int): __slots__ =
    ; ('tag',)` put the member at offset 48 of a 32-byte object, and a bytes
    ; subclass would write its slot over its own bytes.  Both are a SIGSEGV,
    ; and CPython refuses all three with this wording.
    ;
    ; str is the one CPython accepts, and it is accepted here now: its slots
    ; go at the TAIL of the instance, past the characters and past the dict
    ; word, which is the same place its __dict__ already lives.  See
    ; tp_tailslots.
    mov rdi, [rbp - TFP_BASE]
    test rdi, rdi
    jz .tfp_slots_ok
    call bc_solid_base
    mov r13, rax
    lea rcx, [rel int_type]
    cmp r13, rcx
    je .tfp_slots_check
    extern bytes_type
    lea rcx, [rel bytes_type]
    cmp r13, rcx
    je .tfp_slots_check
    extern str_type
    lea rcx, [rel tuple_type]
    cmp r13, rcx
    jne .tfp_slots_ok
.tfp_slots_check:
    lea rdi, [rel bc_slots_name]
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, r15
    mov rsi, rax
    call dict_get
    V_UNPACK rax, rdx
    mov r12, rax
    mov [rbp - TFP_SLOTV], rdx
    mov rdi, rbx
    call obj_decref
    cmp qword [rbp - TFP_SLOTV], TAG_PTR
    jne .tfp_slots_ok
    test r12, r12
    jz .tfp_slots_ok
    mov rcx, [r12 + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    je .tfp_slots_size
    lea rdx, [rel list_type]
    cmp rcx, rdx
    jne .tfp_slots_ok
.tfp_slots_size:
    cmp qword [r12 + PyTupleObject.ob_size], 0
    je .tfp_slots_ok
    lea rdi, [rel bc_slots_unsupported]
    mov rsi, r13
    extern raise_type_error_with_typename
    call raise_type_error_with_typename
.tfp_slots_ok:
    ; __qualname__ is checked HERE, before the type object exists.  Refusing
    ; it once the half-built class is registered in build_class_pending
    ; unwinds through a teardown that is not prepared for a raise from this
    ; early -- and the symptom was an interned name released one time too
    ; many, surfacing at shutdown in an unrelated code object's co_names.
    mov rdi, r15
    call bc_check_qualname
    mov rax, [rbp - TFP_BASE]
    mov rdx, r15                ; restore namespace (scan clobbered rdx)

    ; Allocate the type object (GC-tracked).  A heaptype gets two words past
    ; the table: the struct-sequence descriptor slot a derived class inherits
    ; the meaning of, and ht_qualname -- see object.inc.
    mov edi, HEAPTYPE_ALLOC_SIZE
    lea rsi, [rel user_type_metatype]
    call gc_alloc
    mov r12, rax            ; r12 = new type object (ob_refcnt=1, ob_type set)
    mov [gs:ThreadState.build_class_pending], rax  ; register for exception cleanup

    ; The class holds a REFERENCE to its metatype, not a borrowed pointer.
    ;
    ; For the two metatypes this tree ships that is only bookkeeping -- they
    ; are static and outlive everything.  A metaclass written in Python is an
    ; ordinary heap type that can be collected, and ob_type pointing at one
    ; without counting is a dangling pointer the moment the metaclass dies
    ; first.  user_type_dealloc gives it back and type_traverse reports the
    ; edge, so a metaclass cycle stays collectable.
    ;
    ; Counted HERE, at the allocation, and not once the metatype is finally
    ; decided: the line above registers the half-built class in
    ; build_class_pending, and from that point any raise -- mro_compute
    ; rejects an inconsistent MRO -- unwinds through user_type_dealloc, which
    ; releases ob_type.  Taking the reference later made every failed class
    ; creation a release of one that was never taken, and fifteen of them
    ; drove user_type_metatype's count to zero.
    mov rdi, [rax + PyObject.ob_type]
    call obj_incref

    ; Zero-fill the type object (skip ob_refcnt and ob_type, already set by gc_alloc)
    lea rdi, [r12 + 16]
    xor eax, eax
    mov ecx, (HEAPTYPE_ALLOC_SIZE - 16) / 8
    rep stosq

    ; tp_name: point to class_name string's data area
    lea rax, [r14 + PyStrObject.data]
    mov [r12 + PyTypeObject.tp_name], rax

    ; Instance layout.  A heaptype embeds its base's layout and puts its own
    ; __dict__ immediately after it, so both numbers come from the base:
    ; tp_dictoffset is the base's basicsize, and tp_basicsize is that plus
    ; the dict word.  With no base that yields 16 and 24 -- exactly
    ; PyInstanceObject, which is where those constants came from.
    ;
    ; A variable-size base such as str keeps its data inline, so there is no
    ; fixed offset past the header for a dict.  It gets one at the tail
    ; instead, which is what TP_DICT_AT_TAIL means; bytes and __slots__ classes
    ; still get none.
    mov qword [r12 + PyTypeObject.tp_basicsize], PyInstanceObject_size
    mov qword [r12 + PyTypeObject.tp_dictoffset], PyInstanceObject.inst_dict
    mov rax, [rbp - TFP_BASE]               ; base class
    test rax, rax
    jz .bc_layout_done
    ; Tail slots are inherited whether or not this class declares any of its
    ; own: they are part of the instance's size, and a subclass that reserved
    ; none of them would allocate short and let its base's slots write past
    ; the end.  The __slots__ code below adds to this.
    mov rcx, [rax + PyTypeObject.tp_tailslots]
    mov [r12 + PyTypeObject.tp_tailslots], rcx
    ; If the base already has a dict slot -- another heaptype, an int
    ; subclass, or an EXCEPTION, whose exc_dict is one -- share it rather than
    ; adding a second one, which would collide with whatever the base put
    ; there.
    mov rcx, [rax + PyTypeObject.tp_dictoffset]
    test rcx, rcx
    jnz .bc_layout_inherit

    mov rcx, [rax + PyTypeObject.tp_flags]
    test rcx, TYPE_FLAG_STR_SUBCLASS
    jnz .bc_layout_no_dict
    test rcx, TYPE_FLAG_INT_SUBCLASS
    jnz .bc_layout_done             ; int subclasses wrap rather than embed

    ; bytes keeps its data inline exactly as str does, so its subclasses get
    ; the same tail dict.  Putting one at the base's basicsize instead landed
    ; it *inside* the data: `B(bytes)` with an attribute corrupted itself.
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .bc_layout_no_dict
    ; memoryview borrows its storage, so a tail dict would not be its to
    ; write; it gets none rather than a corrupting one.  bytearray used to be
    ; in the same sentence, back when its data was inline and could move --
    ; it is a fixed-size header with an out-of-line buffer now, so the dict
    ; goes past the header like any other builtin's.
    extern bytearray_type
    extern memoryview_type
    lea rcx, [rel memoryview_type]
    cmp rax, rcx
    je .bc_layout_none

    ; A builtin base with a fixed-size header: the dict goes just past it.
    mov rcx, [rax + PyTypeObject.tp_basicsize]
    test rcx, rcx
    jz .bc_layout_done
    mov [r12 + PyTypeObject.tp_dictoffset], rcx
    add rcx, 8
    mov [r12 + PyTypeObject.tp_basicsize], rcx
    jmp .bc_layout_done

.bc_layout_inherit:
    mov [r12 + PyTypeObject.tp_dictoffset], rcx
    mov rcx, [rax + PyTypeObject.tp_basicsize]
    mov [r12 + PyTypeObject.tp_basicsize], rcx
    jmp .bc_layout_done

.bc_layout_none:
    ; The base's own header, and no dict at all: tp_basicsize still has to be
    ; the base's, or the dealloc slot walk reads a negative count.
    mov qword [r12 + PyTypeObject.tp_dictoffset], 0
    mov rcx, [rax + PyTypeObject.tp_basicsize]
    mov [r12 + PyTypeObject.tp_basicsize], rcx
    jmp .bc_layout_done

.bc_layout_no_dict:
    mov qword [r12 + PyTypeObject.tp_dictoffset], TP_DICT_AT_TAIL
    mov rcx, [rax + PyTypeObject.tp_basicsize]
    mov [r12 + PyTypeObject.tp_basicsize], rcx

.bc_layout_done:

    ; Wire instance methods
    lea rax, [rel instance_dealloc]
    mov [r12 + PyTypeObject.tp_dealloc], rax

    lea rax, [rel instance_repr]
    mov [r12 + PyTypeObject.tp_repr], rax

    extern instance_str
    lea rax, [rel instance_str]
    mov [r12 + PyTypeObject.tp_str], rax

    ; tp_call left NULL: calling the type goes through metatype.tp_call (type_call).
    ; Calling instances falls through to __call__ dunder dispatch.

    lea rax, [rel instance_getattr]
    mov [r12 + PyTypeObject.tp_getattr], rax

    lea rax, [rel instance_setattr]
    mov [r12 + PyTypeObject.tp_setattr], rax

    ; tp_flags = HEAPTYPE | HAVE_GC (enables dunder dispatch fallbacks + GC tracking)
    mov qword [r12 + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE | TYPE_FLAG_HAVE_GC

    ; Set tp_traverse and tp_clear for GC cycle detection
    extern instance_traverse
    extern instance_clear
    lea rax, [rel instance_traverse]
    mov [r12 + PyTypeObject.tp_traverse], rax
    lea rax, [rel instance_clear]
    mov [r12 + PyTypeObject.tp_clear], rax

    ; A layout base with a dealloc, traverse or clear of its OWN keeps it.
    ;
    ; The three above are the generic ones, right for an ordinary class.  A
    ; base that keeps raw fields past the instance header has to clean them
    ; up itself, and _io.FileIO does: fileio_dealloc closes the descriptor,
    ; releases the name and the mode, zeroes the raw words and only then
    ; chains to the generic dealloc.  Overwriting it meant a subclass never
    ; ran any of that -- `class F(_io.FileIO): pass` leaked a file descriptor
    ; per instance, and the collector walked the descriptor as a pointer.
    ;
    ; Inheriting is CPython's rule too: a subtype that adds no storage gets
    ; its base's tp_dealloc.  Nothing changes for an ordinary base, whose
    ; three slots are the generic ones already.
    call bc_inherit_lifecycle

    ; tp_dict = class_dict (ownership transferred from r15, no INCREF needed)
    mov [r12 + PyTypeObject.tp_dict], r15

    ; __qualname__ comes OUT of the dict and into ht_qualname, as CPython's
    ; type_new takes it out.  It is a getset on `type` there, so
    ; `'__qualname__' in C.__dict__` is False and an instance of C cannot see
    ; it; here it sat in tp_dict, so every instance of every class answered
    ; its class's -- and vars(C) had an entry CPython's does not.
    call bc_take_qualname

    ; __new__ is an implicit staticmethod.  Without the wrapper, looking it up
    ; through the class or through super() binds it like an ordinary method
    ; and prepends the instance, so `super().__new__(cls, *args)` arrived one
    ; argument too long -- which is exactly how every metaclass in the stdlib
    ; calls it.
    lea rdi, [rel bc_new_name]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    call dict_get
    mov rbx, rax                ; the current __new__, as a Value
    V_TEST_PTR rbx, rax
    ja .tfp_new_done
    test rbx, rbx
    jz .tfp_new_done
    mov rax, [rbx + PyObject.ob_type]
    extern func_type
    lea rcx, [rel func_type]
    cmp rax, rcx
    jne .tfp_new_done
    sub rsp, 16
    mov [rsp], rbx
    extern staticmethod_type
    extern staticmethod_construct
    lea rdi, [rel staticmethod_type]
    mov rsi, rsp
    mov edx, 1
    call staticmethod_construct
    V_UNPACK rax, rdx
    add rsp, 16
    test rax, rax
    jz .tfp_new_done
    mov rbx, rax
    mov rdi, r15
    mov rsi, [rsp]              ; the "__new__" key
    mov rdx, rbx
    call dict_set
    mov rdi, rbx
    call obj_decref             ; the dict holds it now
.tfp_new_done:
    pop rdi
    call obj_decref             ; the key

    ; A class statement's body sets __module__ itself; three-argument type()
    ; hands over a bare namespace, and without __module__ the repr comes out
    ; unqualified.  Fill it from the running frame's __name__, as CPython does.
    lea rdi, [rel bc_module_name]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    call dict_get
    test rax, rax               ; dict_get answers with a Value; 0 is the miss
    jnz .bc_have_module
    mov rcx, [gs:ThreadState.eval_saved_r12]
    test rcx, rcx
    jz .bc_have_module
    mov rcx, [rcx + PyFrame.globals]
    test rcx, rcx
    jz .bc_have_module
    lea rdi, [rel bc_dunder_name_name]
    call str_from_cstr_heap
    push rax
    mov rdi, [gs:ThreadState.eval_saved_r12]
    mov rdi, [rdi + PyFrame.globals]
    mov rsi, rax
    call dict_get
    V_UNPACK rax, rdx
    pop rdi
    push rax
    push rdx
    call obj_decref                 ; the "__name__" key
    pop rdx
    pop rax
    test edx, edx
    jz .bc_have_module
    mov rdi, r15
    mov rsi, [rsp]                  ; the "__module__" key
    mov rdx, rax
    call dict_set
.bc_have_module:
    pop rdi
    call obj_decref

    ; __doc__ is in EVERY class's own dict, None when the body wrote no
    ; docstring -- type_dict_set_doc puts it there during PyType_Ready.  Without
    ; it the name was simply absent and the MRO walk answered with a BASE's
    ; docstring: `class D(W): pass` over a documented W had D.__doc__ == 'base
    ; doc' where CPython says None, and inspect.getdoc's own inheritance walk
    ; was therefore looking at an answer it had not chosen.
    ;
    ; Last of the fill-ins, which is where CPython puts it: type_dict_set_doc
    ; runs after add_getsets, so `class D: pass` lists __doc__ after the rest
    ; while a class with a docstring has it where the body put it.
    lea rdi, [rel bc_doc_name]
    call str_from_cstr_heap
    test rax, rax
    jz .bc_have_doc_key
    push rax
    mov rdi, r15
    mov rsi, rax
    call dict_get
    test rax, rax               ; a Value; 0 is the miss
    jnz .bc_have_doc
    mov rdi, r15
    mov rsi, [rsp]
    lea rdx, [rel none_singleton]
    call dict_set
.bc_have_doc:
    pop rdi
    call obj_decref
.bc_have_doc_key:

    ; INCREF class_name (type object refers to it via tp_name)
    mov rdi, r14
    call obj_incref

    ; === Parse __slots__ from class_dict ===
    ; r12=type, r15=class_dict, [rbp - TFP_BASE]=base_class
    mov qword [rbp - TFP_SLOT1], 0
    lea rdi, [rel bc_slots_name]
    call str_from_cstr_heap
    push rax                        ; save __slots__ str
    mov rdi, r15                    ; class_dict
    mov rsi, rax
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value
    pop rdi                         ; __slots__ str
    push rdx                        ; save dict_get tag
    push rax                        ; save dict_get value
    call obj_decref                 ; DECREF __slots__ str
    pop rax                         ; value
    pop rdx                         ; tag
    test edx, edx
    jz .bc_no_slots

    ; Must be TAG_PTR and a tuple, a list, or a single string
    cmp edx, TAG_PTR
    jne .bc_no_slots
    extern tuple_type
    extern list_type
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    je .bc_slots_tuple
    lea rdx, [rel list_type]
    cmp rcx, rdx
    je .bc_slots_tuple
    ; `__slots__ = 'name'` declares exactly one, and is the form a class with
    ; a single slot is usually written with.  Wrap it, so the loop below sees
    ; one shape; the wrapper is released at .bc_no_slots, which every exit
    ; from the slot code passes through.
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .bc_no_slots
    push rax
    mov edi, 1
    call tuple_new
    pop rcx
    test rax, rax
    jz .bc_no_slots
    mov [rbp - TFP_SLOT1], rax
    mov rdx, [rax + PyTupleObject.ob_item]
    mov [rdx], rcx
    push rax
    mov rdi, rcx
    call obj_incref
    pop rax

    ; rax = slots list — get size and item pointers (same layout as tuple for ob_size/ob_item)
.bc_slots_tuple:
    ; rax = slots sequence (tuple or list, both have ob_size at same offset)
    ;
    ; The class DECLARED __slots__, whatever is in them and whether or not the
    ; instance dict survives it.  TYPE_FLAG_HAS_SLOTS below answers the other
    ; question -- "has no instance dict" -- and the two part company for a
    ; __slots__ naming '__dict__'.  weakref_referenceable needs this one.
    or qword [r12 + PyTypeObject.tp_flags], TYPE_FLAG_DECLARED_SLOTS
    mov rbx, rax                    ; rbx = slots sequence
    mov r13, [rbx + PyTupleObject.ob_size]  ; r13 = nslots (works for both)
    test r13, r13
    jnz .bc_have_slots
    ; __slots__ = () is still __slots__.  Skipping it here left the flag
    ; unset, so a class that declares it took arbitrary attributes -- which is
    ; the one thing the empty form exists to prevent.
    call bc_base_has_dict
    test eax, eax
    jnz .bc_no_slots
    or qword [r12 + PyTypeObject.tp_flags], TYPE_FLAG_HAS_SLOTS
    call bc_drop_dict_word
    jmp .bc_no_slots
.bc_have_slots:
    mov qword [rbp - TFP_TAIL], 0

    ; A __slots__ that NAMES '__dict__' is asking for the instance dict back:
    ; the other names become fast slots and everything else still goes in the
    ; dict.  CPython's type_new reads it the same way, and refuses it when a
    ; base already supplies one.  Treated as an ordinary slot name it got a
    ; descriptor over a word of its own and the instances still had no dict,
    ; so every attribute that was not a slot raised -- which is the whole of
    ; why pure-Python functools.partial, whose __slots__ names both
    ; '__dict__' and '__weakref__', could not carry an attribute.
    ; Every item is checked here, before any of it is believed: a str, an
    ; identifier, and '__dict__' at most once and only when no base already
    ; supplies one.  bc_slots_validate raises and does not return when it is
    ; not, so everything below reads names it has vouched for.
    call bc_base_has_dict
    mov edx, eax
    mov rdi, rbx
    mov rsi, r13
    call bc_slots_validate
    mov [rbp - TFP_WANTDICT], rax

    ; A str subclass keeps its characters inline, so there is no fixed offset
    ; past the header to lay a slot at: one put there writes over the string's
    ; own bytes, which is why this used to be refused outright.  Its slots go
    ; at the TAIL instead, past the data and past the word the tail __dict__
    ; occupies, and a member descriptor addresses one with a negative offset.
    ; tp_tailslots counts them cumulatively, so a subclass's own start where
    ; its base's stop.
    mov rax, [rbp - TFP_BASE]
    test rax, rax
    jz .bc_slots_not_tail
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .bc_slots_not_tail
    mov qword [rbp - TFP_TAIL], 1
    ; __slots__ suppresses the dict only when no base already provides one,
    ; exactly as for an ordinary class: `class V(U)` where U is a plain str
    ; subclass keeps U's tail dict and must still take arbitrary attributes.
    ; The tail word is reserved either way, so the slot indices past it do
    ; not depend on which case this is.
    ;
    ; And a __slots__ that NAMES '__dict__' keeps it, the same as an inherited
    ; one -- this branch is reached instead of .bc_slots_not_tail, and only
    ; that one read the answer, so `class S(str): __slots__ = ('__dict__',)`
    ; had no dict and every attribute on it raised.
    push rax
    cmp qword [rbp - TFP_WANTDICT], 0
    jne .bc_tail_keep_dict_pop
    call bc_base_has_dict
    pop rcx
    test eax, eax
    jnz .bc_tail_keep_dict
    jmp .bc_tail_no_dict
.bc_tail_keep_dict_pop:
    pop rcx
    jmp .bc_tail_keep_dict
.bc_tail_no_dict:
    or qword [r12 + PyTypeObject.tp_flags], TYPE_FLAG_HAS_SLOTS
    mov qword [r12 + PyTypeObject.tp_dictoffset], 0
.bc_tail_keep_dict:
    mov rax, rcx
    mov rdi, [rax + PyTypeObject.tp_tailslots]
    mov rcx, rdi
    add rcx, r13
    mov [r12 + PyTypeObject.tp_tailslots], rcx
    ; The loop below wants a base to count from; here it is -(1 + inherited),
    ; and each slot is one LOWER, because the offsets run negative.
    neg rdi
    dec rdi
    jmp .bc_have_basic

.bc_slots_not_tail:
    ; Where the slots start.  A class that declares __slots__ and inherits no
    ; dict has none of its own, so the dict word comes out of the layout and
    ; the slots take its place -- which is the layout CPython has, and eight
    ; bytes per instance that used to be a word that could never be written.
    ;
    ; When a base does provide a dict, the class shares it and the slots go
    ; after the whole header, dict word included: putting them at the base's
    ; basicsize instead lands the first slot on top of the dict pointer.
    ; A __slots__ naming '__dict__' keeps the dict word, exactly as an
    ; inherited dict does, and the slots go after the whole header.
    cmp qword [rbp - TFP_WANTDICT], 0
    jne .bc_slots_share_dict
    call bc_base_has_dict
    test eax, eax
    jnz .bc_slots_share_dict
    or qword [r12 + PyTypeObject.tp_flags], TYPE_FLAG_HAS_SLOTS
    call bc_drop_dict_word
    mov rdi, [r12 + PyTypeObject.tp_basicsize]
    jmp .bc_slots_bump
.bc_slots_share_dict:
    mov rdi, [r12 + PyTypeObject.tp_basicsize]
.bc_slots_bump:
    ; rdi = base_basicsize
    ; Set tp_basicsize = base_basicsize + nslots * 8 (one Value per slot)
    mov rax, r13
    shl rax, 3                      ; nslots * 8
    add rax, rdi                    ; + base_basicsize
    mov [r12 + PyTypeObject.tp_basicsize], rax
.bc_have_basic:

    ; TYPE_FLAG_HAS_SLOTS says "this class has NO instance dict", and it is
    ; set above, before the layout is decided, because it is what decides it.
    ; __slots__ suppresses the dict only when NO BASE already provides one --
    ; `class C(A)` with a plain A inherits A's __dict__ and must still accept
    ; `c.z = 1`, which was an AttributeError here.

    ; Create member descriptors for each slot
    ; rbx = slots tuple, r13 = nslots, rdi = base_basicsize
    push rdi                        ; save base_basicsize
    xor edx, edx                    ; i = 0

.bc_slot_loop:
    cmp rdx, r13                    ; i < nslots?
    jge .bc_slots_done

    push rdx                        ; save i

    ; Get slot name: slots_tuple[i]
    mov rax, [rbx + PyTupleObject.ob_item]       ; payloads
    mov rcx, [rax + rdx*8]                        ; name payload
    V_UNPACK rcx, r8
    cmp r8d, TAG_PTR
    jne .bc_slot_skip               ; skip non-string slots

    ; '__dict__' is consumed by the layout above, not by a descriptor: the
    ; instance dict answers it.  Its word stays reserved and unused, which is
    ; what '__weakref__' has always done here.
    push rcx
    push rdx
    mov rdi, rcx
    call bc_slot_is_dict_name
    pop rdx
    pop rcx
    test eax, eax
    jnz .bc_slot_skip

    ; Compute the descriptor's offset: base_basicsize + i*8 for an ordinary
    ; class, and -(1 + inherited) - i for a str subclass, whose slots are at
    ; the tail and are addressed by a negative offset.
    cmp qword [rbp - TFP_TAIL], 0
    jne .bc_slot_tail_off
    mov rdi, [rsp + 8]             ; base_basicsize
    mov rax, [rsp]                 ; i
    lea rdi, [rdi + rax*8]              ; offset
    jmp .bc_slot_have_off
.bc_slot_tail_off:
    mov rdi, [rsp + 8]             ; -(1 + inherited tail slots)
    sub rdi, [rsp]                 ; ... one lower per slot
.bc_slot_have_off:

    ; A private slot name is mangled, exactly as a private name written in the
    ; class body is.  CPython's type_new does it here, leaving __slots__
    ; itself as the tuple the class wrote; skipping it meant the descriptor
    ; was `__x` where every use of it compiles to `_C__x`, so
    ; `__slots__ = ('__x',)` and `self.__x = 5` never met.  The dict key is
    ; the load-bearing half -- attribute lookup finds a descriptor by key --
    ; and md_name is mangled with it so __set_name__ and the repr agree.
    push rdi                       ; the offset, across the call
    mov rdi, rcx                   ; the name as written
    mov rsi, r14                   ; the class name
    call type_mangle_name          ; -> rax, owned
    mov rcx, rax
    pop rdi                        ; the offset

    ; Create descriptor: member_descr_new(offset, name_str, owner)
    mov rsi, rcx                   ; name string
    push rcx                       ; the name: the dict key, then ours to drop
    INCREF rsi                     ; descriptor takes ownership
    mov rdx, r12                   ; the class, for the repr
    extern member_descr_new
    call member_descr_new          ; rax = new descriptor

    ; Add to class_dict: dict_set(dict, name, descriptor, TAG_PTR, TAG_PTR)
    mov rdi, r15                   ; class_dict
    mov rsi, [rsp]                 ; name (key)
    mov rdx, rax                   ; descriptor (value)
    push rax                       ; save descriptor for DECREF
    call dict_set

    ; DECREF our ref on descriptor (dict now owns one via INCREF in dict_set)
    pop rdi
    call obj_decref
    pop rdi                        ; and on the name, which dict_set copied
    call obj_decref

.bc_slot_skip:
    pop rdx                        ; restore i
    inc rdx
    jmp .bc_slot_loop

.bc_slots_done:
    pop rdi                        ; clean base_basicsize

.bc_no_slots:
    ; The wrapper built for a single-string __slots__, if there was one.  The
    ; descriptors hold their own references to the name.
    mov rdi, [rbp - TFP_SLOT1]
    test rdi, rdi
    jz .bc_slot1_done
    mov qword [rbp - TFP_SLOT1], 0
    call obj_decref
.bc_slot1_done:

    ; Look up "__init__" in class_dict for tp_init
    lea rdi, [rel bc_init_name]
    call str_from_cstr_heap
    push rax                ; save __init__ str obj

    mov rdi, r15            ; class_dict
    mov rsi, rax            ; "__init__" str
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value
    mov rbx, rax            ; rbx = __init__ func or NULL

    ; DECREF the "__init__" string
    pop rdi
    call obj_decref

    ; Store tp_init (func ptr or 0)
    mov [r12 + PyTypeObject.tp_init], rbx

    ; Set tp_base: use explicit base class, or default to object_type
    mov rax, [rbp - TFP_BASE]
    test rax, rax
    jnz .bc_have_base
    lea rax, [rel object_type]
    mov [rbp - TFP_BASE], rax           ; update saved base for later use
.bc_have_base:
    mov [r12 + PyTypeObject.tp_base], rax
    mov rdi, rax
    call obj_incref

    ; tp_bases and tp_mro.  With these in place a lookup or a subclass test
    ; can see every base, not just the first.
    mov rax, [rbp - TFP_BASES]
    test rax, rax
    jz .bc_no_bases
    cmp qword [rax + PyTupleObject.ob_size], 0
    jne .bc_have_bases_tuple
.bc_no_bases:
    ; No explicit bases: the linearization is (C, object).  An *empty* tuple
    ; means the same thing as none at all and reaches here through
    ; `class C(metaclass=M)` and `type.__new__(M, n, (), d)`, which the NULL
    ; test alone missed -- those classes got an MRO of just [C], so they were
    ; not even instances of object.  It stays invisible until a merge needs
    ; the object at the end: enum's `StrEnum(str, ReprEnum)` linearised to
    ; [StrEnum, str, object, ReprEnum, Enum].
    mov edi, 1
    extern tuple_new
    call tuple_new
    mov rcx, [rax + PyTupleObject.ob_item]
    lea rdx, [rel object_type]
    mov [rcx], rdx
    mov rdi, rdx
    mov [rbp - TFP_BASES], rax
    call obj_incref
    jmp .bc_bases_ready
.bc_have_bases_tuple:
    mov rdi, rax
    call obj_incref
.bc_bases_ready:
    mov rax, [rbp - TFP_BASES]
    mov [r12 + PyTypeObject.tp_bases], rax
    mov rdi, r12
    mov rsi, rax
    extern mro_compute
    call mro_compute
    mov [r12 + PyTypeObject.tp_mro], rax

    ; Inherit the family bits from every base, not only the layout one: a
    ; `class C(Mixin, list)` is still a list subclass.  The container bits
    ; were defined and set on the base types but never inherited at all, so
    ; nothing downstream could tell a list subclass from any other class.
    mov rax, [rbp - TFP_BASES]
    mov rcx, [rax + PyTupleObject.ob_size]
    mov r8, [rax + PyTupleObject.ob_item]
    xor r9, r9
    xor r10, r10
.bc_flag_scan:
    cmp r9, rcx
    jge .bc_flags_done
    mov r11, [r8 + r9*8]
    test r11, r11
    jz .bc_flag_next
    or r10, [r11 + PyTypeObject.tp_flags]
.bc_flag_next:
    inc r9
    jmp .bc_flag_scan
.bc_flags_done:
    and r10, TYPE_FLAG_INT_SUBCLASS | TYPE_FLAG_STR_SUBCLASS | \
             TYPE_FLAG_LIST_SUBCLASS | TYPE_FLAG_TUPLE_SUBCLASS | \
             TYPE_FLAG_DICT_SUBCLASS | TYPE_FLAG_SET_SUBCLASS | \
             TYPE_FLAG_FLOAT_SUBCLASS | TYPE_FLAG_COMPLEX_SUBCLASS | \
             TYPE_FLAG_BYTEARRAY_SUBCLASS | TYPE_FLAG_BYTES_SUBCLASS
    or [r12 + PyTypeObject.tp_flags], r10

    ; A class deriving from `type` is a metatype: its instances are classes,
    ; so it uses type's attribute slots.  Leaving instance_getattr/setattr
    ; wired made `cls.x = 1` inside a metaclass __new__ walk tp_dictoffset on
    ; a PyTypeObject and write through a bogus offset.
    mov rdi, [rbp - TFP_BASE]
    test rdi, rdi
    jz .bc_not_metatype
    lea rsi, [rel type_type]
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jz .bc_not_metatype
    extern type_getattr
    extern type_setattr
    lea rax, [rel type_getattr]
    mov [r12 + PyTypeObject.tp_getattr], rax
    lea rax, [rel type_setattr]
    mov [r12 + PyTypeObject.tp_setattr], rax
    mov qword [r12 + PyTypeObject.tp_dictoffset], 0
    mov qword [r12 + PyTypeObject.tp_basicsize], TYPE_OBJECT_SIZE
    ; Calling a metatype builds a class, so it needs type's tp_call, not the
    ; instance-constructing one a heaptype gets by default.
    extern type_call
    lea rax, [rel type_call]
    mov [r12 + PyTypeObject.tp_call], rax
    ; And say so in a bit, so that "is this object a class?" is one test
    ; rather than a comparison against the two metatypes we happen to ship.
    or qword [r12 + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    ; `C | None` for a class C is the METATYPE's nb_or, so a metaclass of a
    ; user's own has to carry type's numeric slots -- without them, only
    ; classes made by the two metatypes this tree ships could form a union.
    extern type_number_methods
    lea rax, [rel type_number_methods]
    mov [r12 + PyTypeObject.tp_as_number], rax
    ; A metatype's INSTANCES are classes, so releasing one has to unregister
    ; it from its bases and free a type's fields -- not walk it as an ordinary
    ; instance.  The dealloc used is the object's TYPE's, and a class built by
    ; a metaclass of the user's own has that metaclass as its type, so the
    ; generic heaptype dealloc freed a class the wrong way: the block went
    ; back to the allocator with the GC's list and the base's subclass list
    ; still pointing into it.
    ;
    ; And walked and cleared as one too, or the collector cannot break the
    ; cycle a class makes with its own MRO tuple -- which is the only thing
    ; that ever frees one, since the tuple's first element is the class.  The
    ; generic heaptype traverse reports none of a type's four references, so
    ; such a class simply accumulated, in memory and in its bases'
    ; __subclasses__().
    extern user_type_dealloc
    extern type_traverse
    extern type_clear
    lea rax, [rel user_type_dealloc]
    mov [r12 + PyTypeObject.tp_dealloc], rax
    lea rax, [rel type_traverse]
    mov [r12 + PyTypeObject.tp_traverse], rax
    lea rax, [rel type_clear]
    mov [r12 + PyTypeObject.tp_clear], rax
.bc_not_metatype:

    ; If base is an exception type, inherit exception-compatible methods
    extern type_is_exc_subclass
    mov rdi, [rbp - TFP_BASE]
    call type_is_exc_subclass
    test eax, eax
    jz .bc_check_int_sub

    ; Exception subclass: override instance_* with exc_* methods.
    ;
    ; tp_repr and tp_str stay instance_repr / instance_str, for the reason
    ; the int arm below spells out: they look for the class's own __repr__ /
    ; __str__ first and fall back to the base's slot -- exc_repr / exc_str --
    ; when there is none.  Overwriting them meant an exception subclass that
    ; defined __str__ never had it called, which is every argparse error
    ; message: ArgumentError.__str__ builds the text, so they all came out as
    ; the args tuple.
    extern exc_dealloc
    lea rax, [rel exc_dealloc]
    mov [r12 + PyTypeObject.tp_dealloc], rax
    ; Exception getattr/setattr for custom attributes via exc_dict
    extern exc_getattr
    extern exc_setattr
    lea rax, [rel exc_getattr]
    mov [r12 + PyTypeObject.tp_getattr], rax
    lea rax, [rel exc_setattr]
    mov [r12 + PyTypeObject.tp_setattr], rax
    ; Wire exc traverse/clear for exception subclasses
    extern exc_traverse
    extern exc_clear_gc
    lea rax, [rel exc_traverse]
    mov [r12 + PyTypeObject.tp_traverse], rax
    lea rax, [rel exc_clear_gc]
    mov [r12 + PyTypeObject.tp_clear], rax

    ; A subclass of an exception GROUP is still a group, and the four slots
    ; above are the exception's, not the group's: they neither answer
    ; `.exceptions` nor release the tuple behind it.  `except*` splits a group
    ; by constructing one of the group's OWN type, so a subclass reaches all
    ; of them.
    extern exc_BaseExceptionGroup_type
    extern type_is_subtype
    mov rdi, [rbp - TFP_BASE]
    lea rsi, [rel exc_BaseExceptionGroup_type]
    call type_is_subtype
    test eax, eax
    jz .bc_no_set_base
    extern eg_dealloc
    extern eg_getattr
    extern eg_traverse
    extern eg_clear
    lea rax, [rel eg_dealloc]
    mov [r12 + PyTypeObject.tp_dealloc], rax
    lea rax, [rel eg_getattr]
    mov [r12 + PyTypeObject.tp_getattr], rax
    lea rax, [rel eg_traverse]
    mov [r12 + PyTypeObject.tp_traverse], rax
    lea rax, [rel eg_clear]
    mov [r12 + PyTypeObject.tp_clear], rax
    jmp .bc_no_set_base

.bc_check_int_sub:
    ; Int subclass: inherit int-compatible repr/str and number methods
    mov rax, [r12 + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_INT_SUBCLASS
    jz .bc_check_builtin_sub
    ; tp_repr and tp_str stay instance_repr/instance_str.  They already find
    ; the class's own __repr__ first and fall back to the builtin base's slot
    ; when there is none -- which is how a list subclass prints as a list.
    ; Overwriting them with int's here meant an int subclass that defined
    ; __repr__ never had it called.
    extern int_type
    mov rdi, [rel int_type + PyTypeObject.tp_as_number]
    mov [r12 + PyTypeObject.tp_as_number], rdi
    mov rdi, [rel int_type + PyTypeObject.tp_richcompare]
    mov [r12 + PyTypeObject.tp_richcompare], rdi
    mov rdi, [rel int_type + PyTypeObject.tp_hash]
    mov [r12 + PyTypeObject.tp_hash], rdi
    jmp .bc_no_set_base

.bc_check_builtin_sub:
    ; Inherit the base's constructor (tp_new) where that is the whole story.
    mov rax, [rbp - TFP_BASE]              ; base class
    test rax, rax
    jz .bc_no_set_base

    ; ...but not for bytes, bytearray or memoryview: inheriting tp_new sends
    ; type_call straight to the base constructor and returns, so a subclass
    ; __init__ never ran.  They go through .normal_type_call, which asks the
    ; base to build the instance and then runs __init__ on it.
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .bc_container_sub
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .bc_container_sub
    lea rcx, [rel memoryview_type]
    cmp rax, rcx
    je .bc_container_sub
    ; ...nor for float and complex, for the same reason.  Inheriting the
    ; thunk sent type_call straight to it, and it built and returned a plain
    ; float or complex: the subclass name was lost and its __init__ never
    ; ran.  Both constructors now read the type they are handed, so the
    ; base_slot route in type_call gives them the subclass.
    extern float_type
    lea rcx, [rel float_type]
    cmp rax, rcx
    je .bc_container_sub
    extern complex_type
    lea rcx, [rel complex_type]
    cmp rax, rcx
    je .bc_container_sub

    ; Not for the container families.  Inheriting tp_new sends type_call
    ; straight to the base constructor, which returns a plain list (or
    ; tuple, dict, set) and never reaches __init__ -- so the subclass name
    ; was lost and its __init__ never ran.  Leaving tp_new NULL routes them
    ; through .normal_type_call, the same path an ordinary class takes.
    mov rcx, [r12 + PyTypeObject.tp_flags]
    test rcx, TYPE_FLAG_LIST_SUBCLASS | TYPE_FLAG_TUPLE_SUBCLASS | \
              TYPE_FLAG_DICT_SUBCLASS | TYPE_FLAG_SET_SUBCLASS | \
              TYPE_FLAG_STR_SUBCLASS
    jnz .bc_container_sub
    mov rdi, [rax + PyTypeObject.tp_new]
    test rdi, rdi
    jz .bc_no_set_base
    ; Don't inherit object_type_call or type_call
    extern object_type_call
    lea rcx, [rel object_type_call]
    cmp rdi, rcx
    je .bc_no_set_base
    lea rcx, [rel type_call]
    cmp rdi, rcx
    je .bc_no_set_base
    ; Inherit the constructor from the base (for bytearray, etc.)
    mov [r12 + PyTypeObject.tp_new], rdi

    ; A base that OWNS references -- property, staticmethod, classmethod, the
    ; three static bases with a tp_clear -- needs its fields released and
    ; traced, and its subclass is instance-shaped besides: it has a __dict__
    ; and may have __slots__.  bytes, bytearray and memoryview have neither a
    ; tp_traverse nor a tp_clear, keep their data inline, and are what
    ; builtin_sub_dealloc was written for.
    mov rcx, [rax + PyTypeObject.tp_clear]
    test rcx, rcx
    jz .bc_sub_plain
    mov [r12 + PyTypeObject.tp_clear], rcx
    mov rcx, [rax + PyTypeObject.tp_traverse]
    mov [r12 + PyTypeObject.tp_traverse], rcx
    extern descr_sub_dealloc
    lea rcx, [rel descr_sub_dealloc]
    mov [r12 + PyTypeObject.tp_dealloc], rcx
    jmp .bc_container_sub

.bc_sub_plain:
    ; Use builtin_sub_dealloc instead of instance_dealloc
    ; (builtin subclasses don't have inst_dict at +16)
    extern builtin_sub_dealloc
    lea rax, [rel builtin_sub_dealloc]
    mov [r12 + PyTypeObject.tp_dealloc], rax

.bc_container_sub:
    ; Inherit the base's protocol slots.  These have no Python-level dunder
    ; that instance_getattr could route to, so a subclass with none of them
    ; is not a container at all: d["k"] = 1 raised, because a heaptype's
    ; tp_as_mapping is NULL.  type_install_slots runs after this and
    ; overrides whichever ones the class defines for itself.
    mov rax, [rbp - TFP_BASE]              ; base class
    mov rcx, [rax + PyTypeObject.tp_as_number]
    mov [r12 + PyTypeObject.tp_as_number], rcx
    mov rcx, [rax + PyTypeObject.tp_as_sequence]
    mov [r12 + PyTypeObject.tp_as_sequence], rcx
    mov rcx, [rax + PyTypeObject.tp_as_mapping]
    mov [r12 + PyTypeObject.tp_as_mapping], rcx
    mov rcx, [rax + PyTypeObject.tp_hash]
    mov [r12 + PyTypeObject.tp_hash], rcx
    mov rcx, [rax + PyTypeObject.tp_richcompare]
    mov [r12 + PyTypeObject.tp_richcompare], rcx
    mov rcx, [rax + PyTypeObject.tp_iter]
    mov [r12 + PyTypeObject.tp_iter], rcx
    mov rcx, [rax + PyTypeObject.tp_iternext]
    mov [r12 + PyTypeObject.tp_iternext], rcx

    ; tp_call is what makes the base's INSTANCES callable, and a subclass of
    ; weakref.ref that did not inherit it could not be dereferenced -- which
    ; is weakref.KeyedRef, and WeakValueDictionary above it.  The two
    ; metatype constructors are excluded for the same reason tp_new excludes
    ; them: calling an instance of an ordinary class must not build a class.
    mov rcx, [rax + PyTypeObject.tp_call]
    test rcx, rcx
    jz .bc_no_set_base
    lea rdx, [rel object_type_call]
    cmp rcx, rdx
    je .bc_no_set_base
    lea rdx, [rel type_call]
    cmp rcx, rdx
    je .bc_no_set_base
    mov [r12 + PyTypeObject.tp_call], rcx

.bc_no_set_base:

    ; Fill the type's slots from the dunders it defines.  Until now a
    ; heaptype's tp_iter, tp_iternext, tp_hash, tp_call, tp_richcompare and
    ; tp_as_* were all left at zero, and every operation that wanted one had
    ; to grow its own dunder fallback -- or, more often, not.
    extern type_install_slots
    mov rdi, r12
    call type_install_slots

    ; __hash__ is the one slot whose ABSENCE is meaningful.  Python's rule:
    ; a class that defines __eq__ and not __hash__ is unhashable, and
    ; `__hash__ = None` says so explicitly.  type_install_slots leaves the
    ; inherited slot in place for both -- it treats a None dunder as "no
    ; definition" -- so `{Eq(): 1}` succeeded and Eq.__hash__ is None was
    ; False.  CPython does this in type_new for exactly the same reason: it
    ; cannot be expressed as a slot wrapper.
    mov rdi, r12
    mov rsi, r15
    call type_apply_hash_rule

    ; Two names are implicitly classmethods, whatever the class body wrote.
    ; CPython wraps them in type_new; without it `Template.__init_subclass__()`
    ; -- which CPython's own string.py does at import -- called a plain
    ; function with no arguments, and `C[int]` never reached
    ; __class_getitem__ with the class.
    mov rdi, r12
    mov rsi, r15
    call type_wrap_implicit_classmethods

    ; The metatype, if type.__new__ was handed one, and BEFORE any user code
    ; runs -- __init_subclass__ below and __set_name__ further down alike.  A
    ; descriptor is entitled to read an attribute the metaclass supplies off
    ; the owner it is given; and the global is a REGISTRATION, so it has to be
    ; put down before anything that might build a class of its own picks it
    ; up.  It used to be stamped after __init_subclass__, and a class defined
    ; inside one came out with the outer class's metaclass.
    mov rax, [gs:ThreadState.class_metatype_pending]
    test rax, rax
    jz .tfp_default_metatype
    ; Swap the reference the allocation took: the explicit metatype gains one
    ; and user_type_metatype, which gc_alloc installed and which is what
    ; ob_type still holds here, gives its up.
    mov [r12 + PyObject.ob_type], rax
    mov qword [gs:ThreadState.class_metatype_pending], 0
    mov rdi, rax
    call obj_incref
    lea rdi, [rel user_type_metatype]
    call obj_decref
.tfp_default_metatype:

    ; Record it against each of its bases, so type.__subclasses__ can answer.
    ; Borrowed, and dropped again by user_type_dealloc, so the list only ever
    ; holds live classes -- which is what CPython's weak-referenced
    ; tp_subclasses amounts to.
    ;
    ; BEFORE any user code runs, for the same reason the metatype above is:
    ; __init_subclass__ can read Base.__subclasses__() and CPython's already
    ; lists the class being created.  It also has to be before anything that
    ; can cache against a base, or the class would sit outside the walk that
    ; invalidates such a cache with no way back in.  Only tp_bases is needed,
    ; and that has been set since the layout was decided.
    extern subclass_register
    mov rdi, r12
    call subclass_register

    ; __dict__ and __weakref__, the two entries type_new adds that this did not.
    ;
    ; CPython's rule is not "this class's instances have them", it is "THIS
    ; CLASS contributes them": type_new_descriptors sets tp_dictoffset and
    ; tp_weaklistoffset only for what the class itself adds, and
    ; type_new_set_slots picks the getset table off those two fields before
    ; PyType_Ready inherits anything.  So `class D(C): pass` over a plain C gets
    ; neither, `class S(Slotted): pass` gets both, an int subclass gets the
    ; dict and not the weakref -- int keeps its value inline and variable-sized
    ; -- and a metaclass gets neither.
    ;
    ; Asked HERE because the metatype branch above has had its say about
    ; tp_dictoffset, mro_compute has run (weakref_referenceable does a dunder
    ; lookup), and type_refresh_attr_flags below has not -- so the flag it sets
    ; is computed once, over the final dict.
    mov qword [rbp - TFP_ADDDICT], 0
    mov qword [rbp - TFP_ADDWEAK], 0

    ; Does this class contribute the instance dict?  Its instances have one
    ; (tp_dictoffset non-zero, and no __slots__ suppressing it) and the layout
    ; base did not already supply one.  bc_base_has_dict is called from here
    ; and nowhere else: it reads TFP_BASE out of this frame.
    cmp qword [r12 + PyTypeObject.tp_dictoffset], 0
    je .bc_layout_weak
    test qword [r12 + PyTypeObject.tp_flags], TYPE_FLAG_HAS_SLOTS
    jnz .bc_layout_weak
    call bc_base_has_dict
    test eax, eax
    jnz .bc_layout_weak
    mov qword [rbp - TFP_ADDDICT], 1

.bc_layout_weak:
    ; ...and weak-referenceability.  weakref_referenceable already answers
    ; CPython's question -- it walks down to the first static ancestor and
    ; knows which three keep their value inline -- so "this class adds it" is
    ; "its instances can be referenced and its base's could not".  Asked before
    ; anything is written, because the getset installed below is itself what a
    ; later call would find.
    mov rdi, r12
    extern weakref_referenceable
    call weakref_referenceable
    test eax, eax
    jz .bc_layout_install
    mov rdi, [rbp - TFP_BASE]
    test rdi, rdi
    jz .bc_layout_adds_weak     ; no base yet: object, which is not referenceable
    call weakref_referenceable
    test eax, eax
    jnz .bc_layout_install      ; the base already had it
.bc_layout_adds_weak:
    mov qword [rbp - TFP_ADDWEAK], 1

.bc_layout_install:
    mov rdi, r12
    mov rsi, [rbp - TFP_ADDDICT]
    mov rdx, [rbp - TFP_ADDWEAK]
    call bc_layout_entries

    ; Does anything in this MRO define a __getattribute__ of its own?  Asked
    ; once, here, instead of on every attribute access.  tp_mro, tp_dict and
    ; tp_bases are all set by now, which is all it reads.
    extern type_refresh_attr_flags
    mov rdi, r12
    call type_refresh_attr_flags

    ; Call __init_subclass__, resolved the way Python resolves it:
    ; `super(cls, cls).__init_subclass__`, over the NEW CLASS's own MRO with
    ; its own entry skipped.  It used to be looked up on TFP_BASE -- the
    ; layout base, the widest of the bases -- which answers a different
    ; question: `class D(Mixin, Base)` picked whichever of the two was wider,
    ; so a hook on the other never ran.  Skipping the first entry is also what
    ; keeps a class from calling its own hook on itself.
    extern dunder_lookup_after
    mov rdi, r12               ; the class being built
    CSTRING rsi, "__init_subclass__"
    call dunder_lookup_after
    test rax, rax               ; a Value; 0 is the miss
    jz .bc_no_init_subclass

    ; object's own is a classmethod wrapper; unwrap it, since the class it
    ; would bind is already going in as args[0].
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel classmethod_type]
    cmp rcx, rdx
    jne .bc_is_have_callable
    mov rax, [rax + PyClassMethodObject.cm_callable]
    test rax, rax
    jz .bc_no_init_subclass
.bc_is_have_callable:

    ; Call __init_subclass__(new_class, **class_keywords).  The keywords are
    ; the whole point of the hook -- `class C(B, tag="t")` -- and they arrive
    ; through the pending pair, because the class statement knows them and
    ; this function does not.
    SPUSH_PTR r12              ; args[0] = new class
    mov rdi, rax               ; callable
    mov rsi, rsp               ; args
    mov edx, 1                 ; nargs
    mov rcx, [gs:ThreadState.class_kwnames_pending]
    mov r8, [gs:ThreadState.class_kwvalues_pending]
    call bc_call_kw
    add rsp, 16                ; pop fat args
    test rax, rax
    jz .bc_init_subclass_failed
    mov rdi, rax
    call obj_decref
    jmp .bc_no_init_subclass

.bc_init_subclass_failed:
    ; It ran and raised; the exception is pending and the class is not built.
    DUNDER_RAISED [rbp - TFP_EXC], .tfp_set_name_failed

.bc_no_init_subclass:

    ; The two cells a class body may have left for this moment.
    ; __classcell__ takes the finished class, which is what a method's
    ; `__class__` reads.  __classdictcell__ is PEP 695's parallel and takes
    ; the tp_dict -- class_dict IS it, set above -- so a type alias's
    ; __value__, evaluated long after the body returned, sees the class as it
    ; is rather than a snapshot of the mapping it was built in.
    mov rdi, r15
    lea rsi, [rel bc_classcell_name]
    mov rdx, r12
    lea rcx, [rel bc_classcell_bad]
    call bc_fill_cell
    mov rdi, r15
    lea rsi, [rel bc_classdictcell_name]
    mov rdx, r15
    lea rcx, [rel bc_classdictcell_bad]
    call bc_fill_cell

    ; Track the type object in GC
    extern gc_track
    mov rdi, r12
    call gc_track

    ; Now that the class exists, tell every descriptor in it what it is called.
    mov rdi, r12
    mov rsi, r15
    call type_apply_set_name
    test eax, eax
    jz .tfp_set_name_failed

    ; Return the new type object - clear pending flag first
    mov qword [gs:ThreadState.build_class_pending], 0
    mov rax, r12

    add rsp, 88                 ; must match the sub in the prologue
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.tfp_set_name_failed:
    ; A __set_name__ raised.  The class is discarded and the exception carried
    ; out as a NULL return, which is what every builtin does.
    mov qword [gs:ThreadState.build_class_pending], 0
    mov rdi, r12
    call obj_decref
    xor eax, eax
    add rsp, 88                 ; must match the sub in the prologue
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_from_parts

;; ============================================================================
;; bc_inherit_lifecycle() -- keep the layout base's tp_dealloc / tp_traverse /
;; tp_clear when they are not the generic ones
;;
;; Reads type_from_parts' r12 (the new type) and [rbp - TFP_BASE] through the
;; saved rbp, as bc_base_has_dict does.
;; ============================================================================
DEF_FUNC_LOCAL bc_inherit_lifecycle
    mov r9, [rbp]                   ; type_from_parts' frame
    mov r9, [r9 - TFP_BASE]
    test r9, r9
    jz .bil_done

    ; Only a HEAPTYPE base.  A static builtin -- int, str, list, dict -- has
    ; a tp_dealloc written for its own storage layout, and a subclass of one
    ; is instance-shaped, not int-shaped; type_from_parts has dedicated arms
    ; further down for those.  The bases this is for are the heaptypes that
    ; were built here and then had their tp_basicsize patched to make room
    ; for raw fields: _io.FileIO and _io.BytesIO.
    test qword [r9 + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .bil_done

    extern instance_dealloc
    mov rax, [r9 + PyTypeObject.tp_dealloc]
    test rax, rax
    jz .bil_traverse
    lea rcx, [rel instance_dealloc]
    cmp rax, rcx
    je .bil_traverse
    mov [r12 + PyTypeObject.tp_dealloc], rax
.bil_traverse:
    extern instance_traverse
    mov rax, [r9 + PyTypeObject.tp_traverse]
    test rax, rax
    jz .bil_clear
    lea rcx, [rel instance_traverse]
    cmp rax, rcx
    je .bil_clear
    mov [r12 + PyTypeObject.tp_traverse], rax
.bil_clear:
    extern instance_clear
    mov rax, [r9 + PyTypeObject.tp_clear]
    test rax, rax
    jz .bil_done
    lea rcx, [rel instance_clear]
    cmp rax, rcx
    je .bil_done
    mov [r12 + PyTypeObject.tp_clear], rax
.bil_done:
    leave
    ret
END_FUNC bc_inherit_lifecycle

;; ============================================================================
;; bc_base_has_dict() -> eax = 1 when the layout base already gives instances
;; a __dict__
;;
;; Reads type_from_parts' [rbp - TFP_BASE] through the saved rbp, which is
;; why it is file-local and named for its one caller.
;;
;; A base with __slots__ of its own does NOT count: it has a dict word
;; reserved in its layout that it can never use (bugs.md carries that), so
;; the offset being non-zero says nothing about whether instances have one.
;; ============================================================================
;; ============================================================================
;; bc_drop_dict_word() -- the class being built has no instance dict
;;
;; Zero tp_dictoffset and pull tp_basicsize back to where the header really
;; ends: the layout base's basicsize, or the bare object header when there is
;; no base yet (tp_base is filled in with object further down, and object is
;; exactly that size).  Both slot walks read the header end back out of these
;; two fields, so this is the only place that has to know.
;;
;; The type being built is r12, as it is throughout type_from_parts; the
;; layout base is reached through the saved rbp, as bc_base_has_dict does.
;; ============================================================================
DEF_FUNC_LOCAL bc_drop_dict_word
    push rbx
    mov rax, r12                        ; the type being built
    mov qword [rax + PyTypeObject.tp_dictoffset], 0
    mov rbx, [rbp]                      ; type_from_parts' frame
    mov rcx, [rbx - TFP_BASE]
    test rcx, rcx
    jz .bddw_no_base
    mov rcx, [rcx + PyTypeObject.tp_basicsize]
    test rcx, rcx
    jnz .bddw_store
.bddw_no_base:
    mov ecx, OBJ_HEADER_SIZE
.bddw_store:
    mov [rax + PyTypeObject.tp_basicsize], rcx
    pop rbx
    leave
    ret
END_FUNC bc_drop_dict_word

DEF_FUNC_LOCAL bc_base_has_dict
    mov rax, [rbp]              ; type_from_parts' frame
    mov rax, [rax - TFP_BASE]
    test rax, rax
    jz .bbhd_no
    cmp qword [rax + PyTypeObject.tp_dictoffset], 0
    je .bbhd_no
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HAS_SLOTS
    jnz .bbhd_no
    mov eax, 1
    leave
    ret
.bbhd_no:
    xor eax, eax
    leave
    ret
END_FUNC bc_base_has_dict

;; ============================================================================
;; bc_layout_entries(rdi = the new heaptype, rsi = 1 to add __dict__,
;;                   rdx = 1 to add __weakref__) -> nothing
;;
;; One read-only GS_NAMED getset per name, owned by the type, and skipped when
;; the name is already taken -- which is what keeps a `__slots__` naming either
;; of them from losing the member descriptor the slot loop just made.
;;
;; The descriptors are per-class and carry gs_owner, because
;; inspect._shadowed_dict tests `class_dict.__objclass__ is entry` and treats
;; anything else as a dict that SHADOWS the real one: a shared singleton would
;; stop getattr_static reading instance attributes for every class in the
;; process.  gs_owner is borrowed, as everywhere else -- the type owns the dict
;; that owns the descriptor, so it cannot outlive it.
;;
;; Read-only on purpose.  CPython's __weakref__ getset has no setter at all,
;; and __dict__'s cannot be reached from here anyway: the store side gates on
;; TYPE_FLAG_MRO_HAS_DATA_DESCR, which GS_LAYOUT deliberately keeps clear.
;; bugs.md carries what that leaves open.
;; ============================================================================
BLE_TYPE  equ 8
BLE_DICT  equ 16
BLE_ADDD  equ 24
BLE_ADDW  equ 32
BLE_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC_LOCAL bc_layout_entries, BLE_FRAME
    push rbx
    mov [rbp - BLE_TYPE], rdi
    mov [rbp - BLE_ADDD], rsi
    mov [rbp - BLE_ADDW], rdx
    mov rbx, [rdi + PyTypeObject.tp_dict]
    mov [rbp - BLE_DICT], rbx
    test rbx, rbx
    jz .ble_done

    cmp qword [rbp - BLE_ADDD], 0
    je .ble_weak
    lea rdi, [rel ble_dict_name]
    mov rsi, [rbp - BLE_TYPE]
    extern obj_generic_attr
    lea rdx, [rel obj_generic_attr]
    call bc_add_layout_getset

.ble_weak:
    cmp qword [rbp - BLE_ADDW], 0
    je .ble_done
    lea rdi, [rel ble_weakref_name]
    mov rsi, [rbp - BLE_TYPE]
    extern weakref_slot_get
    lea rdx, [rel weakref_slot_get]
    call bc_add_layout_getset

.ble_done:
    pop rbx
    leave
    ret
END_FUNC bc_layout_entries

;; ============================================================================
;; bc_add_layout_getset(rdi = name cstr, rsi = the owning type,
;;                      rdx = a tp_getattr-shaped getter) -> nothing
;;
;; GS_NAMED means the getter is called (self, gs_name) and answers from the
;; name, which is what obj_generic_attr and weakref_slot_get both are; see
;; dict_add_getattr in methods/init.asm, which this mirrors for a dict that is
;; not a static type's.
;; ============================================================================
BAL_NAME  equ 8
BAL_DESC  equ 16
BAL_OWNER equ 24
BAL_GET   equ 32
BAL_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC_LOCAL bc_add_layout_getset, BAL_FRAME
    push rbx
    mov [rbp - BAL_OWNER], rsi
    mov [rbp - BAL_GET], rdx
    extern str_intern_cstr
    call str_intern_cstr
    test rax, rax
    jz .bal_done
    mov [rbp - BAL_NAME], rax
    mov rbx, [rbp - BAL_OWNER]
    mov rbx, [rbx + PyTypeObject.tp_dict]
    mov rdi, rbx
    mov rsi, rax
    call dict_get
    test rax, rax               ; a Value; 0 is the miss
    jnz .bal_drop_name          ; the class already has the name

    mov rdi, [rbp - BAL_GET]
    xor esi, esi                ; read-only
    mov rdx, [rbp - BAL_NAME]
    extern getset_descr_new
    call getset_descr_new
    test rax, rax
    jz .bal_drop_name
    mov [rbp - BAL_DESC], rax
    mov qword [rax + PyGetSetDescrObject.gs_flags], GS_NAMED | GS_LAYOUT
    mov rcx, [rbp - BAL_OWNER]
    mov [rax + PyGetSetDescrObject.gs_owner], rcx   ; borrowed
    mov rdi, rbx
    mov rsi, [rbp - BAL_NAME]
    mov rdx, rax
    call dict_set
    mov rdi, [rbp - BAL_DESC]
    call obj_decref             ; dict_set took its own
.bal_drop_name:
    mov rdi, [rbp - BAL_NAME]
    call obj_decref             ; str_intern_cstr's, and getset_descr_new took
                                ; one of its own for gs_name
.bal_done:
    pop rbx
    leave
    ret
END_FUNC bc_add_layout_getset

;; ============================================================================
;; type_apply_hash_rule(rdi = the type, rsi = the class dict)
;;
;; Python's inherited-hash rule, which is about a name being ABSENT and so
;; cannot be a slot wrapper:
;;
;;   __hash__ = None in the body   -> unhashable
;;   __eq__ defined, __hash__ not  -> unhashable
;;   otherwise                     -> whatever was inherited or installed
;;
;; __ne__ does not count: only __eq__ suppresses it.
;; ============================================================================
TAH_TYPE  equ 8
TAH_DICT  equ 16
TAH_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC_LOCAL type_apply_hash_rule, TAH_FRAME
    mov [rbp - TAH_TYPE], rdi
    mov [rbp - TAH_DICT], rsi
    test rsi, rsi
    jz .tah_done

    CSTRING rdi, "__hash__"
    mov rsi, [rbp - TAH_DICT]
    call tah_dict_get
    test rax, rax
    jz .tah_no_hash

    ; Present in the body: only None means unhashable.
    extern none_singleton
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .tah_unhashable_slot
    jmp .tah_done

.tah_no_hash:
    ; Absent from the body: __eq__ here suppresses it...
    CSTRING rdi, "__eq__"
    mov rsi, [rbp - TAH_DICT]
    call tah_dict_get
    test rax, rax
    jnz .tah_unhashable

    ; ...and so does an INHERITED __hash__ of None, which is how a subclass
    ; of an unhashable class stays unhashable without a rule of its own.
    ; The name resolves through the MRO; the slot does not follow it, so the
    ; two have to be reconciled here.
    mov rdi, [rbp - TAH_TYPE]
    CSTRING rsi, "__hash__"
    extern dunder_lookup
    call dunder_lookup
    V_UNPACK rax, rdx
    test edx, edx
    jz .tah_done
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    jne .tah_done
    jmp .tah_unhashable_slot

.tah_unhashable_slot:
    ; The slot only: the name already says None, here or up the MRO.
    extern hash_not_implemented
    mov rax, [rbp - TAH_TYPE]
    lea rcx, [rel hash_not_implemented]
    mov [rax + PyTypeObject.tp_hash], rcx
    jmp .tah_done

.tah_unhashable:
    mov rax, [rbp - TAH_TYPE]
    lea rcx, [rel hash_not_implemented]
    mov [rax + PyTypeObject.tp_hash], rcx

    ; The NAME has to say so too: `Eq.__hash__ is None` is how the stdlib
    ; asks, and a subclass that defines neither inherits the None through the
    ; MRO -- which is why SubEq(Eq) is unhashable in CPython without any
    ; rule of its own.
    CSTRING rdi, "__hash__"
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    mov rdi, [rbp - TAH_DICT]
    mov rsi, rax
    lea rdx, [rel none_singleton]
    extern dict_set
    call dict_set
    add rsp, 8
    pop rdi
    call obj_decref
.tah_done:
    leave
    ret
END_FUNC type_apply_hash_rule

;; ============================================================================
;; type_wrap_implicit_classmethods(rdi = the type, rsi = the class dict)
;;
;; __init_subclass__ and __class_getitem__ are classmethods even when the
;; class body defines them as plain functions -- CPython does this in
;; type_new, and it cannot be expressed as a slot.  Anything already wrapped,
;; or not a plain function at all, is left alone.
;; ============================================================================
TWI_TYPE  equ 8
TWI_DICT  equ 16
TWI_KEY   equ 24
TWI_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC_LOCAL type_wrap_implicit_classmethods, TWI_FRAME
    push rbx
    mov [rbp - TWI_TYPE], rdi
    mov [rbp - TWI_DICT], rsi
    test rsi, rsi
    jz .twi_done

    CSTRING rbx, "__init_subclass__"
    call .twi_one
    CSTRING rbx, "__class_getitem__"
    call .twi_one
.twi_done:
    pop rbx
    leave
    ret

;; rbx = the name, as a C string
.twi_one:
    push rbx
    sub rsp, 8
    mov rdi, rbx
    extern str_from_cstr_heap
    call str_from_cstr_heap
    add rsp, 8
    pop rbx
    mov [rbp - TWI_KEY], rax

    mov rdi, [rbp - TWI_DICT]
    mov rsi, rax
    extern dict_get
    call dict_get
    test rax, rax
    jz .twi_release

    ; Only a plain function is wrapped; a classmethod or staticmethod the
    ; body wrote is already what the author asked for.
    V_TEST_PTR rax, rcx
    ja .twi_release
    mov rcx, [rax + PyObject.ob_type]
    extern func_type
    lea rdx, [rel func_type]
    cmp rcx, rdx
    jne .twi_release

    push rax                    ; [rsp] is the one-element argument array
    sub rsp, 8
    extern classmethod_type
    extern classmethod_construct
    lea rdi, [rel classmethod_type]
    lea rsi, [rsp + 8]
    mov edx, 1
    call classmethod_construct
    add rsp, 8
    pop rcx
    test rax, rax
    jz .twi_release

    push rax
    sub rsp, 8
    mov rdi, [rbp - TWI_DICT]
    mov rsi, [rbp - TWI_KEY]
    mov rdx, rax
    extern dict_set
    call dict_set
    add rsp, 8
    pop rdi
    extern obj_decref
    call obj_decref             ; dict_set took its own reference

.twi_release:
    mov rdi, [rbp - TWI_KEY]
    call obj_decref
    ret
END_FUNC type_wrap_implicit_classmethods

;; tah_dict_get(rdi = a name C string, rsi = the dict)
;;   -> rax = the Value, or 0 when absent
DEF_FUNC_LOCAL tah_dict_get, 16
    push rbx
    sub rsp, 8
    mov rbx, rsi
    extern str_from_cstr_heap
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    mov rdi, rbx
    mov rsi, rax
    extern dict_get
    call dict_get
    add rsp, 8
    pop rdi
    push rax
    sub rsp, 8
    call obj_decref             ; the key this built
    add rsp, 8
    pop rax
    add rsp, 8
    pop rbx
    leave
    ret
END_FUNC tah_dict_get




;; ============================================================================
;; bc_call_kw(callable, Value *pos, uint64_t npos, names, values) -> Value
;;
;; One call with the class keywords attached.  The convention the interpreter
;; already uses is kw_names_pending plus the values sitting after the
;; positional ones, so both __prepare__ and the metaclass are reached exactly
;; the way an ordinary keyword call is.
;; ============================================================================
BCK_MAX   equ 20

BCK_FN    equ 8
BCK_NPOS  equ 16
BCK_NAMES equ 24
BCK_VALS  equ 32
BCK_NKW   equ 40
BCK_ARGS  equ 48 + BCK_MAX * 8
BCK_FRAME equ ((BCK_ARGS + 15) / 16) * 16 + 8    ; + 3 pushes = 16-aligned
global bc_call_kw
DEF_FUNC bc_call_kw, BCK_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - BCK_FN], rdi
    mov rbx, rsi
    mov [rbp - BCK_NPOS], rdx
    mov [rbp - BCK_NAMES], rcx
    mov [rbp - BCK_VALS], r8

    xor eax, eax
    test r8, r8
    jz .have_nkw
    mov rax, [r8 + PyTupleObject.ob_size]
.have_nkw:
    mov [rbp - BCK_NKW], rax
    add rax, rdx
    cmp rax, BCK_MAX
    ja .too_many

    ; the positional arguments, then the keyword values
    xor r12d, r12d                      ; the write index
.copy_pos:
    cmp r12, [rbp - BCK_NPOS]
    jae .copy_kw
    mov rax, [rbx + r12*8]
    lea rcx, [rbp - BCK_ARGS]
    mov [rcx + r12*8], rax
    inc r12
    jmp .copy_pos
.copy_kw:
    cmp qword [rbp - BCK_NKW], 0
    je .no_kw
    mov rsi, [rbp - BCK_VALS]
    mov rsi, [rsi + PyTupleObject.ob_item]
    xor r13d, r13d
.copy_kw_loop:
    cmp r13, [rbp - BCK_NKW]
    jae .kw_copied
    mov rax, [rsi + r13*8]
    lea rcx, [rbp - BCK_ARGS]
    mov [rcx + r12*8], rax
    inc r12
    inc r13
    jmp .copy_kw_loop
.kw_copied:
    mov rax, [rbp - BCK_NAMES]
    mov [gs:ThreadState.kw_names_pending], rax
.no_kw:
    mov rdi, [rbp - BCK_FN]
    lea rsi, [rbp - BCK_ARGS]
    mov rdx, r12
    call obj_call_n
    mov qword [gs:ThreadState.kw_names_pending], 0
    pop r13
    pop r12
    pop rbx
    leave
    ret
.too_many:
    RAISE exc_TypeError_type, "too many class keyword arguments"
END_FUNC bc_call_kw
section .rodata
global bc_prepare_name
bc_prepare_name: db "__prepare__", 0
tsn_name: db "__set_name__", 0
bc_init_name: db "__init__", 0
ble_dict_name:    db "__dict__", 0
ble_weakref_name: db "__weakref__", 0
bc_doc_name:   db "__doc__", 0
bc_module_name: db "__module__", 0
bc_dunder_name_name: db "__name__", 0
bc_classcell_name: db "__classcell__", 0
bc_classcell_bad: db `__classcell__ must be a nonlocal cell, not <class '\x01'>`, 0
bc_classdictcell_bad: db `__classdictcell__ must be a nonlocal cell, not <class '\x01'>`, 0
bc_classdictcell_name: db "__classdictcell__", 0
bc_slots_name: db "__slots__", 0
bc_slots_unsupported:
    db "nonempty __slots__ not supported for subtype of '", 1, "'", 0
bc_new_name:          db "__new__", 0
section .text
