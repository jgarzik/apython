; opcodes/load.asm - Opcode handlers that move operands around
;
; LOAD_*, STORE_*/DELETE_*, and the pure stack shuffles POP_TOP, PUSH_NULL,
; COPY and SWAP.  Nothing here computes anything: every handler moves a Value
; between localsplus, a dict, and the value stack.
;
; Register convention (callee-saved, preserved across handlers):
;   rbx = bytecode instruction pointer (current position in co_code[])
;   r12 = current frame pointer (PyFrame*)
;   r13 = value stack payload top pointer
;
; ecx = opcode argument on entry (set by eval_dispatch)
; rbx has already been advanced past the 2-byte instruction word.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

extern exc_TypeError_type

section .text

extern eval_dispatch
extern eval_saved_rbx
extern eval_saved_r13
extern eval_co_consts
extern dict_get
extern dict_get_index
extern instance_setattr
extern raise_exception
extern obj_incref
extern obj_decref
extern func_type
extern exc_NameError_type
extern exc_AttributeError_type
extern method_new
extern method_type
extern staticmethod_type
extern classmethod_type
extern property_type
extern property_descr_get
extern none_singleton
extern dunder_get
extern dunder_call_3
extern dunder_lookup
extern int_type
extern float_type
extern none_type
extern eval_co_names
extern obj_dealloc
extern opcode_table
extern opcode_dispatch_table

; --- Named frame-layout constants ---

; op_load_attr frame layout (DEF_FUNC op_load_attr, LA_FRAME)
LA_FLAG      equ 8
LA_OBJ       equ 16
LA_NAME      equ 24
LA_ATTR      equ 32
LA_FROM_TYPE equ 40
LA_CLASS     equ 48   ; used by classmethod path
LA_ATTR_TAG  equ 56
LA_OBJ_TAG   equ 64
LA_OBJVAL    equ 72   ; the object as a Value, for the generic tail
LA_WALK      equ 80   ; the MRO cursor while searching the type dicts
LA_TAGTYPE   equ 88   ; the type an immediate resolved to, the walk's origin
LA_OWNMRO    equ 96   ; the attribute came from the CLASS's own MRO
LA_FROMMETA  equ 104  ; type_getattr_meta's out-parameter
LA_FROMINST  equ 112  ; instance_getattr_where's: the INSTANCE dict answered
LA_FRAME     equ 136        ; + 0 pushes = 128

; op_load_super_attr frame layout (DEF_FUNC op_load_super_attr, LSA_FRAME)
LSA_SELF     equ 8
LSA_CLASS    equ 16
LSA_NAME     equ 24
LSA_FLAG     equ 32
LSA_ATTR_TAG equ 40
LSA_ATTR     equ 48
LSA_BIND     equ 56
LSA_ORIGIN   equ 64      ; the MRO super() searches: the instance's, not the class's
LSA_SELFTAG  equ 72      ; unused: LSA_SELF holds the Value itself
LSA_CLASSTAG equ 80      ; and so is the class
LSA_SAVEDEXC equ 88      ; current_exception before the proxy path's lookup
LSA_ARGS     equ 104     ; the two-element array super_construct reads
LSA_FRAME    equ 120        ; + 0 pushes; a handler is entered by jmp, so
                         ; this is 8 mod 16 and not 0

;; ============================================================================
;; op_load_const - Load constant from co_consts[arg]
;; ============================================================================
DEF_FUNC_BARE op_load_const
    ; ecx = arg (index into co_consts)
    mov rax, [rel eval_co_consts]
    mov rax, [rax + rcx * 8]
    INCREF_V rax, rdx
    VPUSH rax
    DISPATCH
END_FUNC op_load_const

;; ============================================================================
;; op_load_fast - Load local variable from frame localsplus[arg]
;; ============================================================================
DEF_FUNC_BARE op_load_fast
    ; ecx = arg (slot index in localsplus)
    mov rax, [r12 + PyFrame.localsplus + rcx*8]
    INCREF_V rax, rdx
    VPUSH rax
    DISPATCH
END_FUNC op_load_fast

;; ============================================================================
;; op_load_global - Load global (or builtin) variable by name
;;
;; Python 3.12 encoding:
;;   bit 0 of arg = push-null-before flag
;;   actual name index = arg >> 1
;;
;; Search order: globals dict -> builtins dict
;; Followed by 4 CACHE entries (8 bytes) that must be skipped.
;; ============================================================================
DEF_FUNC_BARE op_load_global
    ; ecx = arg
    ; Check bit 0: if set, push NULL first
    test ecx, 1
    jz .no_push_null
    VPUSH_NULL
.no_push_null:
    ; Name index = arg >> 1
    shr ecx, 1
    ; Get name string from co_names (payload array)
    shl ecx, 3
    LOAD_CO_NAMES rdi
    mov rdi, [rdi + rcx]       ; rdi = name (PyStrObject*)

    ; Save name on the regular stack for retry.  Twice: this handler carves no
    ; frame, so a lone push leaves every call below it 8 out.
    push rdi
    push rdi

    ; Try globals first: dict_get_index(globals, name) -> slot or -1
    mov rdi, [r12 + PyFrame.globals]
    mov rsi, [rsp]             ; rsi = name
    mov edx, TAG_PTR
    call dict_get_index
    cmp rax, -1
    je .try_builtins

    ; Found in globals — try to specialize to LOAD_GLOBAL_MODULE
    ; rax = slot index, rbx points at CACHE[0]
    mov word [rbx + 2], ax     ; CACHE[1] = index (low 16 bits)
    mov rdi, [r12 + PyFrame.globals]
    mov rdi, [rdi + PyDictObject.dk_version]
    mov word [rbx + 4], di     ; CACHE[2] = module_keys_version
    mov byte [rbx - 2], 200    ; rewrite opcode to LOAD_GLOBAL_MODULE

    ; Load the value now (via entry slot)
    mov rdi, [r12 + PyFrame.globals]
    mov rdi, [rdi + PyDictObject.entries]
    movzx eax, word [rbx + 2]  ; index
    imul rax, rax, DICT_ENTRY_SIZE
    add rdi, rax               ; rdi = entry ptr
    mov rax, [rdi + DictEntry.value]
    add rsp, 16                ; discard the saved name and its pad
    jmp .lg_push_result

.try_builtins:
    ; Try builtins: dict_get_index(builtins, name) -> slot or -1
    mov rdi, [r12 + PyFrame.builtins]
    pop rsi                    ; rsi = name
    push rsi                   ; save name for error message
    mov edx, TAG_PTR
    call dict_get_index
    cmp rax, -1
    je .not_found

    ; Found in builtins — specialize to LOAD_GLOBAL_BUILTIN
    add rsp, 16                ; discard the saved name and its pad
    mov word [rbx + 2], ax     ; CACHE[1] = index
    mov rdi, [r12 + PyFrame.globals]
    mov rdi, [rdi + PyDictObject.dk_version]
    mov word [rbx + 4], di     ; CACHE[2] = module_keys_version (guard globals hasn't added it)
    mov rdi, [r12 + PyFrame.builtins]
    mov rdi, [rdi + PyDictObject.dk_version]
    mov word [rbx + 6], di     ; CACHE[3] = builtin_keys_version

    mov byte [rbx - 2], 201    ; rewrite opcode to LOAD_GLOBAL_BUILTIN

    ; Load the value now
    mov rdi, [r12 + PyFrame.builtins]
    mov rdi, [rdi + PyDictObject.entries]
    movzx eax, word [rbx + 2]
    imul rax, rax, DICT_ENTRY_SIZE
    add rdi, rax               ; rdi = entry ptr
    mov rax, [rdi + DictEntry.value]
    jmp .lg_push_result

.not_found:
    pop rdi                    ; name (PyStrObject*)
    add rsp, 8                 ; and its pad
    call raise_name_not_defined
    ; (does not return)

.lg_push_result:
    ; rax is the Value straight out of the dict entry.  It used to be
    ; V_UNPACKed into a (payload, tag) pair above and re-encoded here, around
    ; a refcount bump that never needed either.
    INCREF_V rax, rdx
    VPUSH rax
    ; Skip 4 CACHE entries = 8 bytes
    add rbx, 8
    DISPATCH
END_FUNC op_load_global


;; ============================================================================
;; op_load_name - Load name from locals -> globals -> builtins
;;
;; Similar to LOAD_GLOBAL but checks locals dict first.
;; ============================================================================
DEF_FUNC_BARE op_load_name
    ; ecx = arg (index into co_names)
    shl ecx, 3                ; payload array: 8-byte stride
    LOAD_CO_NAMES rsi
    mov rsi, [rsi + rcx]       ; rsi = name (PyStrObject*)
    sub rsp, 8                 ; pad: rsp is 16-aligned on entry to a
                               ; handler, so a call needs an even push list
    push rsi                   ; save name

    ; Check if frame has a locals dict
    mov rdi, [r12 + PyFrame.locals]
    test rdi, rdi
    jz .try_globals

    ; ...and it need not BE a dict: exec() takes any mapping, and a class body
    ; runs in whatever __prepare__ returned.  Handing one of those to dict_get
    ; probed the object's header as a hash table.
    ;
    ; A dict SUBCLASS keeps the direct read, where CPython's PyDict_CheckExact
    ; sends it through PyObject_GetItem.  It cannot go the other way here: a
    ; builtin __getitem__ reports a miss by RAISING, which in this tree is a
    ; non-local jump into the unwinder, so the KeyError could not be absorbed
    ; -- `class Enum(metaclass=EnumType)` died on `__name__`.  The cost is
    ; that a dict subclass overriding __getitem__ is not consulted; bugs.md
    ; carries it.
    extern dict_type
    mov rax, [rdi + PyObject.ob_type]
    REQUIRE_DICT_TYPE rax, rdx, .locals_mapping

    ; Try locals first: dict_get(locals, name)
    mov rsi, [rsp]             ; rsi = name
    call dict_get
    test rax, rax               ; dict_get returns a Value, and 0 on a miss
    jnz .found
    jmp .try_globals

.locals_mapping:
    mov rsi, [rsp]             ; rsi = name
    extern mapping_getitem_opt
    call mapping_getitem_opt
    test rax, rax
    jnz .found_owned
    ; A miss RAISES for a mapping of its own, where a dict answers NULL.
    ; CPython clears a KeyError and lets anything else through; clearing
    ; whatever it was keeps the mapping's exception out of a name lookup that
    ; then succeeds in globals or in builtins.
    extern current_exception
    extern attr_error_pending
    mov rdi, [rel current_exception]
    test rdi, rdi
    jz .try_globals
    mov qword [rel current_exception], 0
    call obj_decref

.try_globals:
    ; Try globals: dict_get(globals, name)
    mov rdi, [r12 + PyFrame.globals]
    mov rsi, [rsp]             ; rsi = name
    call dict_get
    test rax, rax               ; dict_get returns a Value, and 0 on a miss
    jnz .found

    ; Try builtins: dict_get(builtins, name)
    mov rdi, [r12 + PyFrame.builtins]
    pop rsi                    ; rsi = name
    push rsi                   ; save for error message
    call dict_get
    test rax, rax               ; dict_get returns a Value, and 0 on a miss
    jnz .found

    ; Not found in any dict - raise NameError with name
    pop rdi                    ; name (PyStrObject*)
    add rsp, 8                 ; the pad; this does not return
    call raise_name_not_defined
    ; (does not return)

.found_owned:
    ; mapping_getitem_opt already handed over a reference of its own.
    add rsp, 16                ; discard saved name and the pad
    VPUSH rax
    DISPATCH

.found:
    add rsp, 16                ; discard saved name and the pad
.found_no_pop:
    ; Each of the three probes above used to V_UNPACK dict_get's answer just
    ; to `test edx, edx` for a miss.  dict_get already returns a bare Value
    ; and 0 on a miss, and 0 is the only NULL encoding -- integer 0 encodes as
    ; V_INT_BIAS -- so the raw test is exact.
    INCREF_V rax, rdx
    VPUSH rax
    DISPATCH
END_FUNC op_load_name

;; ============================================================================
;; op_load_build_class - Push __build_class__ builtin onto the stack
;;
;; Opcode 71: LOAD_BUILD_CLASS
;; Pushes the __build_class__ function from the global build_class_obj.
;; ============================================================================
extern build_class_obj

DEF_FUNC_BARE op_load_build_class
    mov rax, [rel build_class_obj]
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
END_FUNC op_load_build_class

;; ============================================================================
;; op_load_attr - Load attribute from object
;;
;; Python 3.12 LOAD_ATTR (opcode 106):
;;   ecx = arg
;;   name_index = ecx >> 1
;;   flag = ecx & 1
;;
;; Pop obj from value stack, look up attr by name on obj.
;; flag=0: push attr, DECREF obj
;; flag=1: method-style load:
;;   If attr is a function: push obj as self, push attr
;;   Else: push NULL, push attr, DECREF obj
;;
;; Followed by 9 CACHE entries (18 bytes) that must be skipped.
;; ============================================================================
extern module_type
extern classmethod_type
extern staticmethod_type
DEF_FUNC op_load_attr, LA_FRAME

    ; Extract flag and name_index
    mov eax, ecx
    and eax, 1
    mov [rbp - LA_FLAG], rax
    mov qword [rbp - LA_FROM_TYPE], 0
    mov qword [rbp - LA_FROMINST], 0
    ; Only the tp_getattr path below has an opinion about which MRO answered.
    ; Every other road to .la_property_run would read this slot as whatever the
    ; last call left on the stack.
    mov qword [rbp - LA_OWNMRO], 0

    shr ecx, 1              ; name_index
    mov eax, ecx
    shl eax, 3              ; payload array: 8-byte stride
    LOAD_CO_NAMES rsi
    mov rsi, [rsi + rax]    ; name string
    mov [rbp - LA_NAME], rsi

    ; Pop obj.  Keep the Value as well as the (payload, tag) pair: the
    ; generic tail classifies a Value, and an immediate's payload is not one.
    VPEEK rcx
    mov [rbp - LA_OBJVAL], rcx
    VPOP_VAL rdi, rax
    mov [rbp - LA_OBJ], rdi
    mov [rbp - LA_OBJ_TAG], rax
    ; Only the type_getattr path writes this, and every other path reads it
    ; as "the class's own mro answered", which is what 0 means.
    mov qword [rbp - LA_FROMMETA], 0

    ; Dispatch on obj tag — resolve non-pointer tags to their type
    cmp qword [rbp - LA_OBJ_TAG], TAG_PTR
    je .la_is_ptr
    cmp qword [rbp - LA_OBJ_TAG], TAG_SMALLINT
    je .la_resolve_int
    cmp qword [rbp - LA_OBJ_TAG], TAG_FLOAT
    je .la_resolve_float
    jmp .la_attr_error

    ; --- Non-pointer tag resolution: look up attr in type's tp_getattr or tp_dict ---
.la_resolve_bool:
    extern bool_type
    lea r8, [rel bool_type]
    jmp .la_resolve_tag_type

.la_resolve_int:
    lea r8, [rel int_type]
    jmp .la_resolve_tag_type

.la_resolve_float:
    lea r8, [rel float_type]
    jmp .la_resolve_tag_type

.la_resolve_none:
    lea r8, [rel none_type]
    ; fall through

.la_resolve_tag_type:
    ; r8 = type object for the non-pointer value.  Record it before anything
    ; else: an immediate has no ob_type, so this is the only thing the
    ; descriptor branches below can use as "the type of the object".
    mov [rbp - LA_TAGTYPE], r8
    ; First try tp_getattr
    mov rax, [r8 + PyTypeObject.tp_getattr]
    test rax, rax
    jz .la_resolve_tag_dict
    ; Call tp_getattr(self Value, name).  The VALUE, not the payload: a
    ; pointer is its own Value, so this is the same argument .la_is_ptr
    ; passes, and one tp_getattr can then serve both -- int's has to, since
    ; an int arrives as an immediate, as a heap int and as a subclass
    ; instance.  Nothing depended on the old convention: no type with a
    ; tp_getattr had a non-pointer form until int and float got one.
    mov rdi, [rbp - LA_OBJVAL]
    mov rsi, [rbp - LA_NAME]
    call rax
    V_UNPACK rax, rdx           ; tp_getattr returns a Value
    test edx, edx
    jz .la_resolve_tag_dict     ; found nothing: the tp_dicts still might
    mov [rbp - LA_ATTR], rax
    mov [rbp - LA_ATTR_TAG], rdx
    jmp .la_got_attr

.la_resolve_tag_dict:
    ; No tp_getattr: walk the MRO's tp_dicts, so an immediate reaches what
    ; object supplies too -- `(1).__eq__` lives there and nowhere else.
    ;
    ; The type comes back out of the frame rather than out of r8.  One of the
    ; two ways in is the `jz` after `call rax` above, and that call is an
    ; ordinary one: r8 is caller-saved, so by here it holds whatever the
    ; tp_getattr left behind -- ap_strcmp leaves 0x8080808080808080 -- and the
    ; walk below dereferenced it.  `.la_resolve_tag_type` stored the type at
    ; LA_TAGTYPE on the way in, before either path diverged.
    mov r8, [rbp - LA_TAGTYPE]
    mov [rbp - LA_WALK], r8
.la_tag_loop:
    mov rax, [rbp - LA_WALK]
    test rax, rax
    jz .la_attr_error
    mov rax, [rax + PyTypeObject.tp_dict]
    test rax, rax
    jz .la_tag_next
    mov rdi, rax
    mov rsi, [rbp - LA_NAME]
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value
    test edx, edx
    jnz .la_tag_found
.la_tag_next:
    mov rax, [rbp - LA_WALK]
    MRO_NEXT rax, [rbp - LA_TAGTYPE]
    mov [rbp - LA_WALK], rax
    jmp .la_tag_loop
.la_tag_found:
    mov [rbp - LA_ATTR], rax
    mov [rbp - LA_ATTR_TAG], rdx
    INCREF_VAL rax, rdx
    mov qword [rbp - LA_FROM_TYPE], 1
    jmp .la_got_attr

.la_is_ptr:
    ; Look up attribute
    ; Check if obj's type has tp_getattr
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_getattr]
    test rax, rax
    jz .la_try_dict

    ; Call tp_getattr(obj, name)
    ; tp_getattr handles all descriptor/binding logic (staticmethod, classmethod,
    ; property, method binding). Result is fully resolved.
    mov qword [rbp - LA_OWNMRO], 0
    mov rdi, [rbp - LA_OBJ]
    mov rsi, [rbp - LA_NAME]
    ; type_getattr can say WHICH MRO answered -- the class's own or its
    ; metatype's -- and the property arm below needs to know.
    extern type_getattr
    extern type_getattr_meta
    lea rdx, [rel type_getattr]
    cmp rax, rdx
    je .la_call_type_getattr
    ; A heaptype instance answers through instance_getattr, and it can say
    ; whether the answer came out of the INSTANCE dict.  That decides whether
    ; the descriptor protocol below runs at all: a property stored in an
    ; instance dict is a property object, not a call to its getter, and this
    ; used to invoke it.
    extern instance_getattr
    extern instance_getattr_where
    lea rdx, [rel instance_getattr]
    cmp rax, rdx
    jne .la_call_getattr
    lea rdx, [rbp - LA_FROMINST]
    ; Ask for a method UNBOUND.  .la_unwrap_bound_method below takes a bound
    ; method apart into [func, self] two instructions later, so building one
    ; here is a gc_alloc, a gc_track, two increfs and an immediate dealloc for
    ; nothing.  obj_getattr_opt shares this entry and asks for 0, because
    ; getattr(c, 'm') must still answer a bound method.
    mov ecx, 1
    call instance_getattr_where
    jmp .la_getattr_done_v
.la_call_type_getattr:
    mov qword [rbp - LA_FROMMETA], 0
    lea rdx, [rbp - LA_FROMMETA]
    call type_getattr_meta
    V_UNPACK rax, rdx
    test edx, edx
    jz .la_try_dict
    cmp qword [rbp - LA_FROMMETA], 0
    jne .la_getattr_done
    mov qword [rbp - LA_OWNMRO], 1
    jmp .la_getattr_done
.la_call_getattr:
    ; A MODULE's tp_getattr reads the module's own dict, which is INSTANCE
    ; storage: CPython's module_getattro hands the value back as it stands, so
    ; a staticmethod in a module dict is a staticmethod object and not the
    ; function inside it.  The descriptor block below ran over it and unwrapped
    ; it -- and lib/select.py keeps one there on purpose, because CPython's
    ; select.select is a C function that does NOT bind when a class body stores
    ; it, which is exactly what Lib/selectors.py does with it.
    extern module_getattr
    lea rdx, [rel module_getattr]
    cmp rax, rdx
    je .la_getattr_as_is
    ; So does a SUPER's: super_lookup has already run the whole descriptor
    ; protocol against __self__, and what it answers is final.  Running the
    ; block below again bound `super(C, C).prop` -- the property itself, as
    ; CPython answers it -- to the super object and called the getter on it.
    extern super_getattr_value
    lea rdx, [rel super_getattr_value]
    cmp rax, rdx
    jne .la_getattr_go
.la_getattr_as_is:
    mov qword [rbp - LA_FROMINST], 1
.la_getattr_go:
    call rax
    V_UNPACK rax, rdx           ; tp_getattr returns a Value
    test edx, edx
    jz .la_try_dict             ; tp_getattr returned NULL — fallback to tp_dict
    jmp .la_getattr_done        ; load-bearing: the arm below unpacks again

.la_getattr_done_v:
    ; instance_getattr_where hands back a Value, and a NULL one means it found
    ; nothing -- 0 is the only NULL encoding.  Unless attr_error_pending says
    ; it installed an AttributeError on the way: an unassigned __slots__ slot,
    ; or a __getattr__ that said "absent".  The class dict was already asked,
    ; and asking again finds the slot's member descriptor and hands THAT back.
    test rax, rax
    jnz .la_gdv_found
    cmp qword [rel attr_error_pending], 0
    je .la_try_dict
    cmp qword [rel current_exception], 0
    je .la_try_dict
    jmp .la_no_such_attr
.la_gdv_found:
    V_UNPACK rax, rdx
    cmp qword [rbp - LA_FROMINST], 2
    je .la_getattr_unbound

.la_getattr_done:
    mov [rbp - LA_ATTR], rax
    mov [rbp - LA_ATTR_TAG], rdx   ; save tag from tp_getattr
    ; LA_FROM_TYPE stays 0 — tp_getattr already handled binding
    jmp .la_got_attr

.la_getattr_unbound:
    ; A function from the type, handed over unbound at our own request.  That
    ; is exactly what .la_try_dict's own answer looks like, so it joins the
    ; same path: LA_FROM_TYPE says the descriptor and binding rules apply, and
    ; the descriptor block is skipped because a function is none of
    ; staticmethod, classmethod, property or getset and its type is not a
    ; heaptype.
    mov qword [rbp - LA_FROMINST], 0
    mov qword [rbp - LA_FROM_TYPE], 1
    mov [rbp - LA_ATTR], rax
    mov [rbp - LA_ATTR_TAG], rdx
    jmp .la_check_flag

.la_try_dict:
    ; No tp_getattr, or it found nothing: ask the class what it defines for
    ; this name.  Reading only the exact type's dict hid everything object
    ; supplies -- `[].__len__` and `None.__new__` among them -- so this is an
    ; MRO walk, and type_lookup_cached is that walk with the answer kept
    ; against the class's version.
    mov rdi, [rbp - LA_OBJ]
    mov rdi, [rdi + PyObject.ob_type]
    mov rsi, [rbp - LA_NAME]
    extern type_lookup_cached
    call type_lookup_cached     ; rax = payload, edx = tag, rcx = owner
    test edx, edx
    jz .la_attr_error
.la_dict_found:

    ; INCREF the result (dict_get returns borrowed ref — may be SmallInt)
    mov [rbp - LA_ATTR], rax
    mov [rbp - LA_ATTR_TAG], rdx   ; save tag from dict_get
    INCREF_VAL rax, rdx
    mov qword [rbp - LA_FROM_TYPE], 1
    jmp .la_got_attr

.la_attr_error:
    ; Last: the attributes every object has -- __class__, __dict__ -- which
    ; no individual tp_getattr provides.  A type that defines one itself has
    ; already been consulted above and wins.
    mov rdi, [rbp - LA_OBJVAL]
    mov rsi, [rbp - LA_NAME]
    extern obj_generic_attr
    call obj_generic_attr
    test rax, rax
    jz .la_no_such_attr
    mov [rbp - LA_ATTR], rax
    mov qword [rbp - LA_ATTR_TAG], TAG_PTR
    mov qword [rbp - LA_FROM_TYPE], 0
    jmp .la_got_attr

.la_no_such_attr:
    mov rdi, [rbp - LA_OBJVAL]
    mov rsi, [rbp - LA_NAME]
    extern raise_no_attribute
    xor edx, edx
    call raise_no_attribute

.la_got_attr:
    ; The descriptor protocol applies to what a TYPE supplies.  A value the
    ; INSTANCE dict was holding is itself, whatever its type: CPython's
    ; object.__getattribute__ returns it without looking, and this used to run
    ; a property's getter and an object's __get__ out of an instance dict.
    cmp qword [rbp - LA_FROMINST], 0
    jne .la_check_flag

    ; === Descriptor protocol: check for staticmethod/classmethod ===
    mov rax, [rbp - LA_ATTR]   ; attr
    cmp qword [rbp - LA_ATTR_TAG], TAG_PTR
    jne .la_check_flag         ; not a heap pointer — skip descriptor check
    mov rcx, [rax + PyObject.ob_type]

    lea rdx, [rel staticmethod_type]
    cmp rcx, rdx
    je .la_handle_staticmethod

    lea rdx, [rel classmethod_type]
    cmp rcx, rdx
    je .la_handle_classmethod

    lea rdx, [rel property_type]
    cmp rcx, rdx
    je .la_handle_property

    extern getset_descr_type
    lea rdx, [rel getset_descr_type]
    cmp rcx, rdx
    je .la_handle_getset

    ; General descriptor protocol: check for __get__ on attr's type
    ; Only check if attr's type is a heaptype (user-defined descriptor), or a
    ; static one that says it is a descriptor -- `super` is the only such.
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE | TYPE_FLAG_DESCRIPTOR
    jz .la_check_flag

    ; Check if attr's type has __get__
    mov rdi, rcx               ; attr's type
    lea rsi, [rel dunder_get]
    call dunder_lookup
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jz .la_check_flag          ; no __get__, treat normally

    ; Has __get__!  Which two arguments it gets depends on where the lookup
    ; started.  `obj.x` is __get__(obj, type(obj)); `C.x` is __get__(None, C),
    ; and CPython's type.__getattribute__ is what draws that line.  Passing
    ; the class as the instance and the METAclass as the owner made every
    ; descriptor that distinguishes the two answer the wrong case -- enum's
    ; property looks the name up in the instance's value rather than handing
    ; back the member, which is what stopped `import enum`'s users working.
    ;
    ; The test is TYPE_FLAG_METATYPE on the object's own type, not a compare
    ; against type_type: a class built by a metaclass of its own is still a
    ; class.  And the descriptor has to have come from the class's OWN mro --
    ; one found on the metatype is an ordinary instance access, where the
    ; class IS the instance.
    mov rsi, [rbp - LA_OBJ]    ; obj (instance)
    mov rdx, [rsi + PyObject.ob_type] ; type(obj)
    mov rax, [rbp - LA_OBJVAL]
    V_TEST_PTR rax, rcx         ; the Value, not the tag: VPOP_VAL writes only
    ja .la_descr_have_args      ; the low half of the tag slot
    cmp qword [rbp - LA_FROMMETA], 0
    jne .la_descr_have_args
    test qword [rdx + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .la_descr_have_args
    mov rdx, rsi               ; owner = the class
    LOAD_NONE rsi              ; instance = None
.la_descr_have_args:
    mov rdi, [rbp - LA_ATTR]   ; descriptor (attr)
    lea rcx, [rel dunder_get]
    mov r8d, TAG_PTR             ; both are always heap pointers
    call dunder_call_3
    V_UNPACK rax, rdx           ; returns a Value

    ; rax = result from __get__, rdx = result tag
    SAVE_FAT_RESULT            ; save (rax,rdx) across DECREF calls

    ; DECREF descriptor wrapper
    mov rdi, [rbp - LA_ATTR]
    call obj_decref
    ; DECREF obj
    mov rdi, [rbp - LA_OBJ]
    mov rsi, [rbp - LA_OBJ_TAG]
    DECREF_VAL rdi, rsi         ; a payload, not necessarily a pointer

    RESTORE_FAT_RESULT
    ; As above: a user __get__ that raised returns NULL, and pushing it lost
    ; the exception.
    test edx, edx
    jz .la_propagate
    cmp qword [rbp - LA_FLAG], 0
    jne .la_descr_get_flag1
    VPUSH_VAL rax, rdx
    jmp .la_done

.la_descr_get_flag1:
    ; flag=1: push NULL + result
    xor ecx, ecx
    VPUSH_NULL
    VPUSH_VAL rax, rdx
    jmp .la_done

.la_handle_getset:
    ; A getset descriptor found on the object's TYPE reads through its getter.
    ; Reached any other way it is itself the answer -- `int.real` comes back
    ; out of int's own dict through type_getattr, which is exactly what
    ; CPython's __get__(None, type) hands back.
    cmp qword [rbp - LA_FROM_TYPE], 0
    je .la_check_flag
    mov rdi, [rbp - LA_ATTR]
    mov rsi, [rbp - LA_OBJVAL]
    extern getset_descr_get
    call getset_descr_get       ; -> a Value
    push rax
    push rax                    ; twice: rsp stays 16-byte aligned
    mov rdi, [rbp - LA_ATTR]
    call obj_decref             ; the descriptor, INCREF'd by the dict walk
    mov rdi, [rbp - LA_OBJ]
    mov rsi, [rbp - LA_OBJ_TAG]
    DECREF_VAL rdi, rsi
    pop rax
    pop rax
    cmp qword [rbp - LA_FLAG], 0
    jne .la_getset_flag1
    VPUSH rax
    jmp .la_done
.la_getset_flag1:
    push rax
    push rax
    VPUSH_NULL
    pop rax
    pop rax
    VPUSH rax
    jmp .la_done

.la_check_flag:
    ; Check flag
    cmp qword [rbp - LA_FLAG], 0
    jne .la_method_load

    ; flag=0: simple attribute load
    ; If attr came from type dict and is callable, create bound method
    cmp qword [rbp - LA_FROM_TYPE], 0
    je .la_try_ic_instance
    mov rax, [rbp - LA_ATTR]
    cmp qword [rbp - LA_ATTR_TAG], TAG_PTR
    jne .la_simple_push         ; not a heap pointer
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .la_simple_push

    ; Create bound method(func=attr, self=obj).  im_self is a Value, so an
    ; immediate binds like anything else: `(7).bit_length` used to be the
    ; unbound descriptor, which answered `<method 'bit_length' of 'int'
    ; objects>` where CPython has a bound method, had no __self__, and --
    ; once the arity bounds were registered -- refused its own zero-argument
    ; call because the receiver it was never given did not count.
    mov rdi, [rbp - LA_ATTR]   ; func
    mov rsi, [rbp - LA_OBJ]    ; self
    mov rdx, [rbp - LA_OBJ_TAG]
    V_PACK rsi, rdx
    call method_new
    VPUSH_PTR rax

    ; DECREF the raw func (method_new INCREFed it)
    mov rdi, [rbp - LA_ATTR]
    call obj_decref
    ; DECREF obj (method_new INCREFed it)
    mov rdi, [rbp - LA_OBJ]
    mov rsi, [rbp - LA_OBJ_TAG]
    DECREF_VAL rdi, rsi         ; a payload, not necessarily a pointer
    jmp .la_done

.la_try_ic_instance:
    ; The attribute came out of the instance dict, and this site asked for a
    ; plain load.  That is what opcode 204 caches: the class, the name, and
    ; the dense index the name sits at.
    cmp qword [rbp - LA_FROMINST], 0
    je .la_simple_push
    cmp qword [rbp - LA_OBJ_TAG], TAG_PTR
    jne .la_simple_push
    mov rdi, [rbp - LA_OBJ]
    mov rax, [rdi + PyObject.ob_type]
    ; A __getattribute__ of the class's own runs instead of all of this.
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_GETATTRIBUTE_OVERRIDDEN
    jnz .la_simple_push
    ; The version is what the handler guards on, so a type without one -- a
    ; static type, whose instances have no instance dict anyway -- cannot be
    ; cached.
    mov rcx, [rax + PyTypeObject.tp_flags]
    shr rcx, TYPE_VERSION_SHIFT
    test ecx, ecx
    jz .la_simple_push
    mov [rbp - LA_TAGTYPE], rax    ; the type, held across the calls below

    ; Does THIS NAME resolve to something that could outrank the instance
    ; dict?  That used to be asked as TYPE_FLAG_MRO_HAS_DATA_DESCR, which is
    ; per-CLASS: one @property anywhere in the MRO refused the cache for every
    ; other attribute of the class, and an ordinary object with one computed
    ; field paid a full instance_getattr for all of its plain ones.
    ;
    ; The per-name answer is only affordable because it is asked once, at
    ; install, and the version the handler guards on is what keeps it true --
    ; adding a property to the class, or to a base, stamps a new one.
    ;
    ; attr_may_be_data_descr, not attr_is_data_descr: a descriptor's own type
    ; can gain __set__ long afterwards, and that write refreshes the
    ; DESCRIPTOR's type, not the class holding it.  The over-approximation
    ; refuses anything whose type is a heaptype, and a static type cannot gain
    ; __set__ at all -- so what it lets through can never become one.
    mov rdi, rax
    mov rsi, [rbp - LA_NAME]
    call type_lookup_cached        ; rax = payload, edx = tag
    test edx, edx
    jz .la_ic_name_free            ; the MRO does not define it at all
    cmp edx, TAG_PTR
    jne .la_ic_name_free           ; and an immediate is never a descriptor
    mov rdi, rax
    extern attr_may_be_data_descr
    call attr_may_be_data_descr
    test eax, eax
    jnz .la_simple_push
.la_ic_name_free:

    mov rdi, [rbp - LA_OBJ]
    LOAD_INST_DICT rsi, rdi, .la_simple_push
    test rsi, rsi
    jz .la_simple_push
    mov rdi, rsi
    mov rsi, [rbp - LA_NAME]
    mov edx, TAG_PTR
    extern dict_get_index
    call dict_get_index
    cmp rax, -1
    je .la_simple_push             ; gone already: do not cache a miss
    cmp rax, 0xFFFF
    ja .la_simple_push             ; the index does not fit the cache

    ; The handler validates the slot by comparing its KEY against co_names by
    ; pointer, and dict_set keeps the FIRST writer's key object.  An attribute
    ; created under a name that is not the interned constant --
    ; setattr(o, "".join([...]), 1) -- can therefore never satisfy that guard,
    ; and installing anyway made the site specialize and deopt on every single
    ; execution: two instruction-stream writes and a dict_get_index per access,
    ; measured at 41ms against 18ms for the same loop over a constant name.
    ; Refusing once here is what stops it.
    mov rdi, [rbp - LA_OBJ]
    LOAD_INST_DICT rsi, rdi, .la_simple_push   ; rsi did not survive the call
    mov rcx, [rsi + PyDictObject.entries]
    imul rdx, rax, DICT_ENTRY_SIZE
    add rcx, rdx
    mov rdx, [rbp - LA_NAME]
    cmp rdx, [rcx + DictEntry.key]
    jne .la_simple_push

    mov word [rbx + 4], ax         ; CACHE[+4] = dense index
    mov rcx, [rbp - LA_TAGTYPE]
    mov rcx, [rcx + PyTypeObject.tp_flags]
    shr rcx, TYPE_VERSION_SHIFT
    mov dword [rbx], ecx           ; CACHE[+0] = the type's version
    mov byte [rbx - 2], 204        ; rewrite to LOAD_ATTR_INSTANCE
    ; fall through

.la_simple_push:
    mov rax, [rbp - LA_ATTR]
    mov rdx, [rbp - LA_ATTR_TAG]
    VPUSH_VAL rax, rdx

    ; DECREF obj -- tag-aware.  An immediate's payload is not an address,
    ; and this path is reachable with one now that the generic tail
    ; (__class__, __dict__) answers for every kind of value.
    mov rdi, [rbp - LA_OBJ]
    mov rsi, [rbp - LA_OBJ_TAG]
    DECREF_VAL rdi, rsi

    jmp .la_done

.la_method_load:
    ; flag=1: method-style load
    mov rax, [rbp - LA_ATTR]
    cmp qword [rbp - LA_ATTR_TAG], TAG_PTR
    jne .la_not_method             ; non-pointer can't be a method
    mov rcx, [rax + PyObject.ob_type]

    ; If attr is a bound method (returned by instance_getattr with binding),
    ; unwrap into [im_func, im_self] push pattern
    lea rdx, [rel method_type]
    cmp rcx, rdx
    je .la_unwrap_bound_method

    ; Whether it binds is the object's question: a Python function always
    ; does, a builtin only when it is a method or wrapper descriptor rather
    ; than a module-level function.  Types and other callables never do.
    ;
    ; Only for an attribute that came from a TYPE DICT.  What a tp_getattr
    ; answers is built on the spot and never stamped -- a generator's `send`,
    ; a coroutine's, a file's -- so its func_kind says FUNCTION and this would
    ; decline it; the arms below already decide that case, by asking what kind
    ; of object the RECEIVER is.
    cmp qword [rbp - LA_FROM_TYPE], 0
    je .la_is_method_func
    mov rdi, rax
    xor esi, esi                   ; the receiver is decided further down
    extern builtin_should_bind
    call builtin_should_bind
    test eax, eax
    mov rax, [rbp - LA_ATTR]
    jnz .la_is_method_func
    jmp .la_not_method

.la_is_method_func:

    ; === IC: try to specialize as LOAD_ATTR_METHOD (203) ===
    ; Only when attr came from type dict (no tp_getattr path)
    cmp qword [rbp - LA_FROM_TYPE], 0
    jne .la_ic_check               ; from type dict → IC + method_push
    ; from_type=0: came from tp_getattr.  Most builtin types' tp_getattr hands
    ; back an unbound method that still needs self; the exceptions are the ones
    ; whose tp_getattr reads out of a namespace rather than off a type, where
    ; the answer is already a plain function.
    cmp qword [rbp - LA_OBJ_TAG], TAG_PTR
    jne .la_method_push            ; non-ptr obj can't be heaptype
    mov rdi, [rbp - LA_OBJ]
    mov rax, [rdi + PyObject.ob_type]
    ; If obj IS a type, the attribute is unbound → [NULL, func]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jnz .la_not_method             ; class attribute → [NULL, func]
    test dword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jnz .la_not_method             ; heaptype instance attr → [NULL, func]
    ; A module's tp_getattr answers out of the module's own namespace, not out
    ; of a type -- `m.f` is the global f, never a method bound to m.  It is not
    ; a heaptype, so without this it fell into the built-in case below and was
    ; called with the module as its first argument.
    lea rcx, [rel module_type]
    cmp rax, rcx
    je .la_not_method
    ; A function's tp_getattr is the same shape: it reads out of the
    ; function's own __dict__, so `f.g` is whatever was stored there and
    ; calling it must not pass f.  functools.lru_cache hangs cache_info off
    ; the wrapper exactly like that, and `slow.cache_info()` was called with
    ; the wrapper as its first argument.
    lea rcx, [rel func_type]
    cmp rax, rcx
    je .la_not_method
    ; The same for a classmethod or staticmethod wrapper: its __func__ is the
    ; function it wraps, not a method of the wrapper.
    lea rcx, [rel classmethod_type]
    cmp rax, rcx
    je .la_not_method
    lea rcx, [rel staticmethod_type]
    cmp rax, rcx
    je .la_not_method
    ; And a super, whose tp_getattr has already done the whole descriptor
    ; protocol against __self__ -- `super().s` on a staticmethod comes back
    ; as the plain function, and binding the SUPER OBJECT to it as self made
    ; `super().s()` a TypeError about an argument nobody wrote.  This is the
    ; shape CPython avoids wholesale: _PyObject_GetMethod reports "not a
    ; method" for any type with a tp_getattro of its own.
    extern super_type
    lea rcx, [rel super_type]
    cmp rax, rcx
    je .la_not_method
    ; And a BOUND METHOD, whose method_getattr answers `__func__` with the
    ; plain function under it and delegates everything else to that function's
    ; own __dict__.  Neither is a method OF the bound method, so binding it as
    ; self passed three arguments where two were written:
    ; `bm.__func__(a, 1)` was "A.im() takes 2 positional arguments but 3 were
    ; given".  It matters most for what a decorator hangs off its wrapper --
    ; `obj.method.cache_clear()` on an lru_cache'd method is this shape.
    ; The value was never wrong; only the fused call site was, so a two-step
    ; `m = bm.__func__` worked and hid it.
    lea rcx, [rel method_type]
    cmp rax, rcx
    je .la_not_method
    jmp .la_method_push            ; built-in tp_getattr → [func, self]

.la_ic_check:

    ; Verify type has tp_dict with valid dk_version
    mov rdi, [rbp - LA_OBJ]       ; obj
    cmp qword [rbp - LA_OBJ_TAG], TAG_PTR
    jne .la_method_push            ; non-pointer obj, skip IC
    mov rcx, [rdi + PyObject.ob_type]
    mov rdx, [rcx + PyTypeObject.tp_dict]
    test rdx, rdx
    jz .la_method_push             ; no tp_dict, skip

    ; Write CACHE: [+0]=type version(32b), [+4]=dk_version(16b), [+6]=descr(64b)
    ;
    ; The VERSION, not the type POINTER, is what says "the same class in the
    ; same state".  Versions come from one global counter and are never
    ; reused; an address is, and a class freed and another allocated in its
    ; place passed the pointer compare -- with the dk_version guard only
    ; sixteen bits wide behind it, and a cached DESCRIPTOR belonging to the
    ; dead class's dict.  The site then called the wrong class's method, or a
    ; freed one.  Every other cache in load_ic.asm already guards this way,
    ; and typecache.asm's header says why.
    mov rax, [rcx + PyTypeObject.tp_flags]
    shr rax, TYPE_VERSION_SHIFT
    test eax, eax
    jz .la_method_push             ; no version: not cacheable
    mov [rbx], eax                 ; CACHE[+0] = type version
    mov rdx, [rdx + PyDictObject.dk_version]
    mov word [rbx + 4], dx         ; CACHE[+4] = dk_version (low 16 bits)
    mov rax, [rbp - LA_ATTR]
    mov [rbx + 6], rax             ; CACHE[+6] = descr (8 bytes unaligned)
    mov byte [rbx - 2], 203       ; rewrite opcode to LOAD_ATTR_METHOD

.la_method_push:
    ; It's a function -> method call pattern
    ; CPython order: push func (deeper), then self (TOS)
    ; Don't DECREF obj since it stays on stack as self
    mov rax, [rbp - LA_ATTR]
    VPUSH_PTR rax              ; push func (deeper slot = callable)
    mov rax, [rbp - LA_OBJ]
    mov rdx, [rbp - LA_OBJ_TAG]
    VPUSH_VAL rax, rdx         ; push self with correct tag (SmallInt/Float/etc.)
    jmp .la_done

.la_unwrap_bound_method:
    ; Attr is a bound method from instance_getattr.
    ; Unwrap: push im_func (deeper), im_self (TOS).
    ; DECREF obj (not used — method has its own self ref).
    mov rdi, [rbp - LA_OBJ]
    mov rsi, [rbp - LA_OBJ_TAG]
    DECREF_VAL rdi, rsi         ; a payload, not necessarily a pointer

    mov rax, [rbp - LA_ATTR]    ; bound method
    ; INCREF im_func and im_self (we're creating new refs on the value stack)
    mov rdi, [rax + PyMethodObject.im_func]
    push rax
    push rax                    ; twice: rsp stays 16-byte aligned
    call obj_incref
    pop rax
    pop rax
    mov rdi, [rax + PyMethodObject.im_self]
    push rax
    push rax
    call obj_incref
    pop rax
    pop rax

    ; Push [im_func, im_self] then DECREF the method wrapper
    mov rcx, [rax + PyMethodObject.im_func]
    VPUSH_PTR rcx                    ; func (deeper)
    mov rcx, [rax + PyMethodObject.im_self]
    VPUSH_PTR rcx                    ; self (TOS)

    ; DECREF the method wrapper
    mov rdi, rax
    call obj_decref
    jmp .la_done

.la_not_method:
    ; Non-function attr with flag=1: push NULL then attr
    mov rdi, [rbp - LA_OBJ]
    mov rsi, [rbp - LA_OBJ_TAG]
    DECREF_VAL rdi, rsi         ; a payload, not necessarily a pointer
    xor eax, eax
    VPUSH_NULL              ; push NULL
    mov rax, [rbp - LA_ATTR]
    mov rdx, [rbp - LA_ATTR_TAG]
    VPUSH_VAL rax, rdx         ; push attr
    jmp .la_done

.la_handle_staticmethod:
    ; Unwrap: extract sm_callable from wrapper
    mov rdi, [rax + PyStaticMethodObject.sm_callable]
    push rdi                   ; save unwrapped func
    push rdi                   ; twice: rsp stays 16-byte aligned
    call obj_incref            ; INCREF unwrapped func

    ; DECREF wrapper
    mov rdi, [rbp - LA_ATTR]
    call obj_decref

    ; Update attr to unwrapped func
    pop rax
    pop rax
    mov [rbp - LA_ATTR], rax

    ; DECREF obj (not binding it as self)
    mov rdi, [rbp - LA_OBJ]
    mov rsi, [rbp - LA_OBJ_TAG]
    DECREF_VAL rdi, rsi         ; a payload, not necessarily a pointer

    cmp qword [rbp - LA_FLAG], 0
    jne .la_sm_flag1

    ; flag=0: push just the unwrapped func
    mov rax, [rbp - LA_ATTR]
    VPUSH_PTR rax
    jmp .la_done

.la_sm_flag1:
    ; flag=1: push NULL + func (no self binding)
    xor eax, eax
    VPUSH_NULL
    mov rax, [rbp - LA_ATTR]
    VPUSH_PTR rax
    jmp .la_done

.la_handle_property:
    ; A property found in the CLASS's own MRO is the property itself --
    ; `C.prop` is what `C.prop.__doc__ = ...` is written on, and dis.py opens
    ; with exactly that -- while one found on the METATYPE runs, which is what
    ; makes Enum.__members__ work.  type_getattr_meta reports which; deciding
    ; it here from "is the object a class" gets the second case wrong, which
    ; is why it went undone for so long.
    cmp qword [rbp - LA_OWNMRO], 0
    je .la_property_run
    mov rdi, [rbp - LA_OBJ]
    mov rsi, [rbp - LA_OBJ_TAG]
    DECREF_VAL rdi, rsi
    mov rax, [rbp - LA_ATTR]
    mov edx, TAG_PTR
    cmp qword [rbp - LA_FLAG], 0
    jne .la_prop_self_flag1
    VPUSH_VAL rax, rdx
    jmp .la_done
.la_prop_self_flag1:
    VPUSH_NULL
    VPUSH_VAL rax, rdx
    jmp .la_done

.la_property_run:
    ; === IC: try to specialize as LOAD_ATTR_PROPERTY (242) ===
    ;
    ; This is where a @property is actually run, and until now it was the only
    ; place: every read of one took op_load_attr's whole prologue, the MRO
    ; lookup, the descriptor protocol, property_descr_get and then the generic
    ; call path for the getter.  Decomposing m_oo put the entire remaining gap
    ; there -- a method body reading one property cost 45.8ms against CPython's
    ; 34.8, where the same body reading a plain attribute cost 19.4 against
    ; 28.1.  Opcode 242 caches the getter and pushes its frame directly.
    ;
    ; Only flag=0 installs: a method-style load would have to push [NULL,
    ; value], and `obj.prop()` is not a shape worth a second cache layout.
    cmp qword [rbp - LA_FLAG], 0
    jne .la_prop_call
    cmp qword [rbp - LA_OBJ_TAG], TAG_PTR
    jne .la_prop_call
    mov rdi, [rbp - LA_OBJ]
    mov rax, [rdi + PyObject.ob_type]
    ; A __getattribute__ of the class's own runs instead of all of this.
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_GETATTRIBUTE_OVERRIDDEN
    jnz .la_prop_call
    ; The version is what the handler guards on, and it is what pins the
    ; property the getter is read out of: rebinding the class attribute goes
    ; through type_setattr, which stamps a new one down every subclass.
    mov rcx, [rax + PyTypeObject.tp_flags]
    shr rcx, TYPE_VERSION_SHIFT
    test ecx, ecx
    jz .la_prop_call
    mov [rbp - LA_TAGTYPE], rax

    ; Ask the type by NAME rather than trusting LA_ATTR: what the handler will
    ; do on every later execution is resolve this name against this type, and
    ; this is the one place to check that the two agree.
    mov rdi, rax
    mov rsi, [rbp - LA_NAME]
    call type_lookup_cached        ; rax = payload, edx = tag
    cmp edx, TAG_PTR
    jne .la_prop_call
    cmp rax, [rbp - LA_ATTR]
    jne .la_prop_call              ; a different answer: do not cache this one
    ; Exactly property, not a subclass of it: a subclass may define __get__.
    lea rcx, [rel property_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .la_prop_call
    mov rax, [rax + PyPropertyObject.prop_get]
    test rax, rax
    jz .la_prop_call               ; no getter: the generic path raises
    ; The getter has to be a shape the handler can run inline.  Checking it
    ; here as well as at every hit is what keeps a lambda with a default, a
    ; builtin or a generator from installing and deopting for ever.
    lea rcx, [rel func_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .la_prop_call
    mov rcx, [rax + PyFuncObject.func_code]
    cmp dword [rcx + PyCodeObject.co_argcount], 1
    jne .la_prop_call
    cmp dword [rcx + PyCodeObject.co_kwonlyargcount], 0
    jne .la_prop_call
    test dword [rcx + PyCodeObject.co_flags], \
         CO_VARARGS | CO_VARKEYWORDS | CO_GENERATOR | CO_COROUTINE | \
         CO_ASYNC_GENERATOR
    jnz .la_prop_call

    ; Install BEFORE the getter runs: the getter is arbitrary Python and may
    ; rewrite the very class this cached, and a version stamped after it would
    ; be the new one against a getter read before it.
    mov [rbx + 4], rax             ; CACHE[+4] = the getter
    mov rcx, [rbp - LA_TAGTYPE]
    mov rcx, [rcx + PyTypeObject.tp_flags]
    shr rcx, TYPE_VERSION_SHIFT
    mov dword [rbx], ecx           ; CACHE[+0] = the type's version
    mov byte [rbx - 2], OP_LOAD_ATTR_PROPERTY

.la_prop_call:
    ; Call property_descr_get(property, obj)
    mov rdi, [rbp - LA_ATTR]   ; property descriptor
    mov rsi, [rbp - LA_OBJ]    ; obj
    call property_descr_get
    ; A getter that raised an AttributeError has not failed -- it has said the
    ; attribute is absent, which is what __getattr__ is the hook for.  Asked
    ; here, before the object below is released, and before the tag says NULL.
    test edx, edx
    jnz .la_prop_got
    mov rdi, [rbp - LA_OBJ]
    mov rsi, [rbp - LA_NAME]
    extern attr_getattr_hook
    call attr_getattr_hook     ; -> (rax, edx); edx = 0 leaves it pending
.la_prop_got:
    SAVE_FAT_RESULT            ; save (rax,rdx) across DECREF calls

    ; DECREF property wrapper
    mov rdi, [rbp - LA_ATTR]
    call obj_decref
    ; DECREF obj
    mov rdi, [rbp - LA_OBJ]
    mov rsi, [rbp - LA_OBJ_TAG]
    DECREF_VAL rdi, rsi         ; a payload, not necessarily a pointer

    RESTORE_FAT_RESULT
    ; A getter that raised hands back NULL.  Pushing that and dispatching on
    ; left a (0,0) pair on the value stack where the frame expected a value:
    ; the exception escaped its own try block, and a getter that touched self
    ; segfaulted.
    test edx, edx
    jz .la_propagate
    ; Push result (property_descr_get already returns owned ref)
    cmp qword [rbp - LA_FLAG], 0
    jne .la_prop_flag1
    VPUSH_VAL rax, rdx
    jmp .la_done

.la_prop_flag1:
    ; flag=1: push NULL + result (it's a value, not a method)
    xor ecx, ecx
    VPUSH_NULL
    VPUSH_VAL rax, rdx
    jmp .la_done

.la_handle_classmethod:
    ; Unwrap: extract cm_callable from wrapper
    mov rdi, [rax + PyClassMethodObject.cm_callable]
    push rdi                   ; save unwrapped func
    push rdi                   ; twice: rsp stays 16-byte aligned
    call obj_incref            ; INCREF unwrapped func

    ; DECREF wrapper
    mov rdi, [rbp - LA_ATTR]
    call obj_decref

    ; Update attr to unwrapped func
    pop rax
    pop rax
    mov [rbp - LA_ATTR], rax

    ; Determine class: if obj is a type, class=obj. Else class=type(obj).
    ; "obj is a type" is a flag on its metatype, not a comparison against the
    ; two we ship: a class built by a metaclass of its own is still a class,
    ; and asking the narrow question bound the metaclass instead.
    ; An immediate int or float has no ob_type to read: `(5).from_bytes`
    ; reaches a classmethod through one.
    mov rdi, [rbp - LA_OBJ]    ; obj, as a payload -- the tag is separate
    cmp qword [rbp - LA_OBJ_TAG], TAG_PTR
    jne .la_cm_of_type
    test rdi, rdi
    jz .la_cm_of_type
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jnz .la_cm_obj_is_type
    jmp .la_cm_have_ob_type
.la_cm_of_type:
    mov rax, [rbp - LA_TAGTYPE]
.la_cm_have_ob_type:

    ; obj is an instance -> class = ob_type
    mov [rbp - LA_CLASS], rax  ; save class
    mov rdi, rax
    call obj_incref
    jmp .la_cm_have_class

.la_cm_obj_is_type:
    ; obj is a type -> class = obj itself
    mov [rbp - LA_CLASS], rdi  ; save class (= obj)
    call obj_incref

.la_cm_have_class:
    ; DECREF obj
    mov rdi, [rbp - LA_OBJ]
    mov rsi, [rbp - LA_OBJ_TAG]
    DECREF_VAL rdi, rsi         ; a payload, not necessarily a pointer

    cmp qword [rbp - LA_FLAG], 0
    jne .la_cm_flag1

    ; flag=0: create bound method(func, class) and push
    mov rdi, [rbp - LA_ATTR]   ; func
    mov rsi, [rbp - LA_CLASS]  ; class (as self)
    call method_new            ; INCREFs both func and class
    ; DECREF our refs to func and class
    push rax                   ; save method
    mov rdi, [rbp - LA_ATTR]
    call obj_decref
    mov rdi, [rbp - LA_CLASS]
    call obj_decref
    pop rax
    VPUSH_PTR rax
    jmp .la_done

.la_cm_flag1:
    ; flag=1: CPython order: push func (deeper), then class (TOS as self)
    mov rax, [rbp - LA_ATTR]   ; func
    VPUSH_PTR rax
    mov rax, [rbp - LA_CLASS]  ; class
    VPUSH_PTR rax
    jmp .la_done

.la_propagate:
    ; The exception is already pending; hand it to the frame's own handler.
    extern eval_exception_unwind
    leave
    mov [rel eval_saved_r13], r13
    jmp eval_exception_unwind

.la_done:
    add rbx, 18            ; skip 9 CACHE entries
    leave
    DISPATCH
END_FUNC op_load_attr


;; ============================================================================
;; op_load_closure - Load cell from localsplus[arg]
;;
;; Same as LOAD_FAST -- loads the cell object itself (not its contents).
;; In Python 3.12, LOAD_CLOSURE is same opcode behavior as LOAD_FAST.
;; ============================================================================
DEF_FUNC_BARE op_load_closure
    mov rax, [r12 + PyFrame.localsplus + rcx*8]
    INCREF_V rax, rdx
    VPUSH rax
    DISPATCH
END_FUNC op_load_closure

;; ============================================================================
;; op_load_deref - Load value through cell in localsplus[arg]
;;
;; Gets cell from localsplus[arg], then loads cell.ob_ref.
;; Raises NameError if cell is empty (ob_ref == NULL).
;; ============================================================================
DEF_FUNC_BARE op_load_deref
    mov rax, [r12 + PyFrame.localsplus + rcx*8]  ; rax = cell object (payload)
    test rax, rax
    jz .deref_error
    mov rax, [rax + PyCellObject.ob_ref]       ; rax = contained Value
    test rax, rax                              ; 0 means an empty cell
    jz .deref_error
    INCREF_V rax, rdx
    VPUSH rax
    DISPATCH

.deref_error:
    ; An empty cell is one of CPython's two different exceptions, and which
    ; one depends on whose cell it is: this function's own (a local that a
    ; nested scope closes over) is an UnboundLocalError, and a FREE variable
    ; from an enclosing scope is a NameError with its own wording.
    ; co_localspluskinds says which -- and now says it truthfully, the
    ; compiler having written CO_FAST_LOCAL for every slot until now.
    mov edi, ecx
    call unbound_local_raise    ; does not return
END_FUNC op_load_deref

;; ============================================================================
;; op_load_fast_check - Load local with NULL check
;;
;; Same as LOAD_FAST but raises UnboundLocalError if slot is NULL.
;; Used after DELETE_FAST and in exception handlers.
;; ============================================================================
DEF_FUNC_BARE op_load_fast_check
    mov rax, [r12 + PyFrame.localsplus + rcx*8]
    test rax, rax           ; an empty slot is 0
    jz .lfc_error
    INCREF_V rax, rdx
    VPUSH rax
    DISPATCH

.lfc_error:
    mov edi, ecx
    call unbound_local_raise    ; does not return
END_FUNC op_load_fast_check

;; ============================================================================
;; unbound_local_raise(edi = the localsplus slot) -- does not return
;;
;; "cannot access local variable 'x' where it is not associated with a value",
;; which is CPython's wording and names the variable.  The name is in the
;; frame's code object, at the same index the slot has.
;; ============================================================================
ULR_BUF   equ 264
ULR_FREE  equ 272           ; is this slot a free variable?
ULR_SLOT  equ 280
ULR_FRAME equ 288           ; + 0 pushes = 288
DEF_FUNC unbound_local_raise, ULR_FRAME
    mov [rbp - ULR_SLOT], rdi
    mov qword [rbp - ULR_FREE], 0

    ; CO_FAST_FREE in co_localspluskinds is what separates the two forms.
    mov rax, [r12 + PyFrame.code]
    test rax, rax
    jz .ulr_kind_done
    mov rax, [rax + PyCodeObject.co_localspluskinds]
    test rax, rax
    jz .ulr_kind_done
    mov rcx, [rbp - ULR_SLOT]
    cmp rcx, [rax + PyBytesObject.ob_size]
    jae .ulr_kind_done
    movzx edx, byte [rax + PyBytesObject.data + rcx]
    test edx, CO_FAST_FREE
    jz .ulr_kind_done
    mov qword [rbp - ULR_FREE], 1
.ulr_kind_done:

    mov r8, [rbp - ULR_SLOT]    ; the slot, across the appends
    lea rdi, [rbp - ULR_BUF]
    lea rsi, [rel ulr_open]
    cmp qword [rbp - ULR_FREE], 0
    je .ulr_have_open
    lea rsi, [rel ulr_free_open]
.ulr_have_open:
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax

    ; co_localsplusnames[slot], when the code object has one.
    mov rax, [r12 + PyFrame.code]
    test rax, rax
    jz .ulr_no_name
    mov rax, [rax + PyCodeObject.co_localsplusnames]
    test rax, rax
    jz .ulr_no_name
    movsxd rcx, r8d
    cmp rcx, [rax + PyTupleObject.ob_size]
    jae .ulr_no_name
    mov rax, [rax + PyTupleObject.ob_item]
    mov rax, [rax + rcx*8]
    V_TEST_PTR rax, rdx
    ja .ulr_no_name
    test rax, rax
    jz .ulr_no_name
    lea rsi, [rax + PyStrObject.data]
    jmp .ulr_have_name
.ulr_no_name:
    lea rsi, [rel ulr_unknown]
.ulr_have_name:
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel ulr_close]
    cmp qword [rbp - ULR_FREE], 0
    je .ulr_have_close
    lea rsi, [rel ulr_free_close]
.ulr_have_close:
    call rbt_append_cstr

    extern exc_UnboundLocalError_type
    extern exc_NameError_type
    lea rdi, [rel exc_UnboundLocalError_type]
    cmp qword [rbp - ULR_FREE], 0
    je .ulr_raise
    lea rdi, [rel exc_NameError_type]
.ulr_raise:
    lea rsi, [rbp - ULR_BUF]
    extern raise_exception
    call raise_exception
    ud2
END_FUNC unbound_local_raise

section .rodata
lsa_bad_class_msg: db `super() argument 1 must be a type, not \x01`, 0
ulr_open:      db "cannot access local variable '", 0
ulr_close:     db "' where it is not associated with a value", 0
ulr_free_open: db "cannot access free variable '", 0
ulr_free_close: db "' where it is not associated with a value in enclosing scope", 0
ulr_unknown:   db "?", 0
section .text

;; ============================================================================
;; op_load_fast_and_clear - Load local and set slot to NULL
;;
;; Used by comprehensions to save/restore iteration variable.
;; If slot is NULL, pushes NULL (no error).
;; ============================================================================
DEF_FUNC_BARE op_load_fast_and_clear
    mov rax, [r12 + PyFrame.localsplus + rcx*8]       ; may be empty (0)
    mov qword [r12 + PyFrame.localsplus + rcx*8], 0
    ; Ownership transfers to the stack, so no INCREF
    VPUSH rax
    DISPATCH
END_FUNC op_load_fast_and_clear

;; ============================================================================
;; op_load_super_attr - Load attribute via super()
;;
;; Opcode 141: LOAD_SUPER_ATTR
;; Stack: TOS=self, TOS1=class, TOS2=global_super
;; arg encoding: name_index = arg >> 2, method = arg & 1
;; Followed by 1 CACHE entry (2 bytes).
;;
;; Pops all three stack values, looks up attribute in class->tp_base->tp_dict
;; (walking the MRO chain), and pushes result.
;;
;; The low bit decides how MANY values come back, not just which: with it set
;; this is a method load and pushes two -- the callable and the receiver, or
;; NULL and a value that is not one -- and with it clear it pushes exactly
;; ONE, the attribute.  dis.stack_effect agrees: -1 with the bit, -2 without.
;; Pushing two either way is invisible in `return super().x`, where the extra
;; word dies with the frame, and becomes an extra argument the moment the
;; result is used in the middle of an expression.
;; ============================================================================
DEF_FUNC op_load_super_attr, LSA_FRAME

    ; Save method flag
    mov eax, ecx
    and eax, 1
    mov [rbp - LSA_FLAG], rax

    ; Get name from co_names
    shr ecx, 2
    mov eax, ecx
    shl eax, 3                    ; payload array: 8-byte stride
    LOAD_CO_NAMES rsi
    mov rax, [rsi + rax]          ; name string
    mov [rbp - LSA_NAME], rax

    ; Pop self, class, global_super.  self stays a VALUE -- it is handed to
    ; super_lookup and to method_new, both of which take one, and it is
    ; released with DECREF_V; unpacking it would turn the immediate int of
    ; `super(int, 1).bit_length` into a pointer to address 1.
    VPOP rax                       ; self
    mov [rbp - LSA_SELF], rax
    VPOP_VAL rax, rdx              ; class
    mov [rbp - LSA_CLASS], rax
    mov [rbp - LSA_CLASSTAG], rdx
    VPOP rdi              ; global_super -- DECREF and discard
    DECREF_V rdi, rsi

    ; Argument 1 has to be a type: every walk below is over its MRO, and
    ; `super(1, self)` read a tp_mro off the number.  CPython checks this one
    ; FIRST, so `super(1, 5)` complains about the 1.  Whether it is a class is
    ; the metatype flag rather than a pointer compare, because a class built
    ; by a metaclass of its own has a metatype of its own.
    cmp qword [rbp - LSA_CLASSTAG], TAG_PTR
    jne .lsa_bad_class
    mov rdi, [rbp - LSA_CLASS]
    test rdi, rdi
    jz .lsa_bad_class
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .lsa_bad_class

    ; super() searches the *instance's* MRO starting just past the class the
    ; method was defined in -- that is the whole point of it in a diamond,
    ; and following the defining class's own tp_base chain skipped the
    ; sibling branch entirely.
    ; The second argument is a VALUE and need not be a pointer at all, and
    ; type_is_subtype walks a tp_mro -- so asking it about the object read a
    ; field of an ordinary instance as an MRO tuple, and dereferenced an int
    ; or a float outright.  `super(C, 5).f` was a segfault, and so was
    ; CPython's own test_descr.test_proxy_super, which reaches here with a
    ; proxy object.
    extern type_is_subtype
    extern value_type
    mov rdi, [rbp - LSA_SELF]
    call value_type
    test rax, rax
    jz .lsa_origin_try_self
    mov [rbp - LSA_ORIGIN], rax     ; the instance's type, if it turns out to fit
    mov rdi, rax
    mov rsi, [rbp - LSA_CLASS]
    call type_is_subtype
    test eax, eax
    jz .lsa_origin_try_self
    mov rax, [rbp - LSA_ORIGIN]
    jmp .lsa_have_origin
.lsa_origin_try_self:
    ; A classmethod gets the class itself as the second argument.  Whether it
    ; IS a class is a flag on its type -- TYPE_FLAG_METATYPE is set on type,
    ; on both metatypes here and on any class deriving from type -- and not a
    ; pointer compare, because a class built by a metaclass of its own has a
    ; metatype of its own.
    mov rdi, [rbp - LSA_SELF]
    V_TEST_PTR rdi, rax
    ja .lsa_origin_class
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .lsa_origin_class
    mov rsi, [rbp - LSA_CLASS]
    call type_is_subtype
    test eax, eax
    jz .lsa_origin_class
    mov rax, [rbp - LSA_SELF]
    jmp .lsa_have_origin
.lsa_origin_class:
    ; Neither the object's type nor the object itself is a subtype of the
    ; class.  CPython's supercheck asks one more question before refusing --
    ; what the object says its class is -- and that is what makes super() work
    ; through a proxy that forwards attribute access, which is what
    ; test_descr.test_proxy_super is for.  The declared class is what CPython
    ; then searches and reports as __self_class__, and it arrives OWNED; every
    ; exit below would have to release it, so this shape is handed to the
    ; unspecialised path instead -- .lsa_via_object builds the real super
    ; object, whose constructor owns the declared class for as long as it
    ; lives.  Only a proxy ever reaches there.
    mov rdi, [rbp - LSA_SELF]
    IS_NONE rdi, rax
    je .lsa_unbound                 ; super(C, None) is CPython's UNBOUND super
    extern obj_declared_class
    call obj_declared_class
    test rax, rax
    jz .lsa_bad_self
    push rax
    push rax                        ; and a pad: the calls below stay aligned
    mov rdi, rax
    mov rsi, [rbp - LSA_CLASS]
    call type_is_subtype
    mov [rbp - LSA_ORIGIN], rax     ; the verdict, across the release
    pop rdi
    pop rdi
    call obj_decref                 ; obj_declared_class hands over a reference
    cmp qword [rbp - LSA_ORIGIN], 0
    je .lsa_bad_self
    jmp .lsa_via_object
.lsa_have_origin:
    mov [rbp - LSA_ORIGIN], rax

    ; The four names super answers for ITSELF.  This opcode has the three
    ; operands and no super object, so it searched the MRO for them and came
    ; back empty -- `super(list, [1]).__self__` was an AttributeError where
    ; CPython, whose unspecialised path builds a real super and getattrs it,
    ; answers the list.
    mov rdi, [rbp - LSA_NAME]
    mov rsi, [rbp - LSA_CLASS]
    mov rdx, [rbp - LSA_SELF]
    mov rcx, [rbp - LSA_ORIGIN]
    extern super_own_attr
    call super_own_attr
    test rax, rax
    jnz .lsa_own_attr

    ; The attribute form is super_lookup, which is also what a super OBJECT's
    ; tp_getattr calls -- the descriptor rules live in one place, and the two
    ; cannot answer differently.  The method form below keeps arms of its own,
    ; because it pushes two values and leaves a function unbound on purpose.
    cmp qword [rbp - LSA_FLAG], 0
    jne .lsa_method_walk
    mov rdi, [rbp - LSA_CLASS]
    mov rsi, [rbp - LSA_SELF]
    mov rdx, [rbp - LSA_ORIGIN]
    mov rcx, [rbp - LSA_NAME]
    lea r8, [rbp - LSA_BIND]        ; LSA_BIND is unused on this path
    extern super_lookup
    call super_lookup
    SAVE_FAT_RESULT
    mov rdi, [rbp - LSA_CLASS]
    call obj_decref
    mov rdi, [rbp - LSA_SELF]
    DECREF_V rdi, rax
    RESTORE_FAT_RESULT
    test edx, edx
    jz .lsa_attr_failed
    VPUSH_VAL rax, rdx
    jmp .lsa_done
.lsa_attr_failed:
    cmp qword [rbp - LSA_BIND], 0
    jne .lsa_absent                 ; nothing on the MRO has the name
    jmp .lsa_propagate              ; a property getter raised

.lsa_method_walk:
    mov rdi, [rbp - LSA_ORIGIN]
    mov rsi, [rbp - LSA_CLASS]
    extern type_mro_next
    call type_mro_next
    test rax, rax
    jz .lsa_not_found

.lsa_walk:
    ; rcx tracks the current type for the .lsa_next_base step, including the
    ; no-tp_dict path that used to fall through with rcx undefined.
    mov rcx, rax
    mov rdi, [rax + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .lsa_next_base

    push rax                       ; save current type
    push rax                       ; twice: rsp stays 16-byte aligned
    mov rsi, [rbp - LSA_NAME]      ; name
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value
    pop rcx
    pop rcx                        ; restore current type
    test edx, edx               ; the tag, not the payload: a hit may be int 0
    jnz .lsa_found

.lsa_next_base:
    MRO_NEXT rcx, [rbp - LSA_ORIGIN]
    mov rax, rcx
    test rax, rax
    jnz .lsa_walk
    ; The MRO is exhausted: nothing after __thisclass__ defines the name.
    ; This used to FALL THROUGH into .lsa_bad_class, so
    ; `super(list, [1]).__len__()` reported "super() argument 1 must be a
    ; type, not type" instead of an AttributeError naming the attribute.
    jmp .lsa_not_found

.lsa_unbound:
    ; CPython's unbound super: there is no instance, so nothing to search --
    ; but its own four names still answer, with __self__ and __self_class__
    ; both None.
    mov qword [rbp - LSA_ORIGIN], 0
    mov rdi, [rbp - LSA_NAME]
    mov rsi, [rbp - LSA_CLASS]
    mov rdx, [rbp - LSA_SELF]
    xor ecx, ecx
    call super_own_attr
    test rax, rax
    jnz .lsa_own_attr
    jmp .lsa_not_found

.lsa_via_object:
    ; A proxy: read the attribute off a real super object, which is the
    ; unspecialised path and is already right about the declared class.  The
    ; two operands stay held until the answer is in hand, so nothing here is
    ; owed if super_construct or a getter raises -- .lsa_propagate republishes
    ; the pre-pop stack top and lets the unwinder release them.
    mov rax, [rbp - LSA_CLASS]
    mov [rbp - LSA_ARGS], rax
    mov rax, [rbp - LSA_SELF]
    mov [rbp - LSA_ARGS + 8], rax
    extern super_construct
    extern super_type
    lea rdi, [rel super_type]
    lea rsi, [rbp - LSA_ARGS]
    mov edx, 2
    call super_construct
    test rax, rax
    jz .lsa_propagate
    mov [rbp - LSA_BIND], rax       ; the super object, owned

    DUNDER_EXC_SAVE [rbp - LSA_SAVEDEXC]
    mov rdi, rax
    mov rsi, [rbp - LSA_NAME]
    extern super_getattr_value
    call super_getattr_value
    mov [rbp - LSA_ATTR], rax
    mov rdi, [rbp - LSA_BIND]
    call obj_decref
    cmp qword [rbp - LSA_ATTR], 0
    jne .lsa_via_have
    ; A zero is either "nothing on the MRO has the name", which this words,
    ; or a property getter that raised, which is already pending.
    EXC_RAISED_SINCE [rbp - LSA_SAVEDEXC], rax, .lsa_propagate
    jmp .lsa_not_found

.lsa_via_have:
    mov rdi, [rbp - LSA_CLASS]
    call obj_decref
    mov rdi, [rbp - LSA_SELF]
    DECREF_V rdi, rax
    cmp qword [rbp - LSA_FLAG], 0
    je .lsa_via_one
    VPUSH_NULL                      ; a value, not a method: NULL beneath it
.lsa_via_one:
    mov rax, [rbp - LSA_ATTR]
    VPUSH rax
    jmp .lsa_done

.lsa_own_attr:
    ; One of super's own.  Release the operands, then push -- in method mode
    ; with a NULL beneath it, the way .lsa_prop_one does, because this is a
    ; value and not a method.
    mov [rbp - LSA_ATTR], rax
    mov rdi, [rbp - LSA_CLASS]
    call obj_decref
    mov rdi, [rbp - LSA_SELF]
    DECREF_V rdi, rax
    cmp qword [rbp - LSA_FLAG], 0
    je .lsa_own_one
    VPUSH_NULL
.lsa_own_one:
    mov rax, [rbp - LSA_ATTR]
    VPUSH rax
    jmp .lsa_done

.lsa_bad_class:
    ; Compose the message while the operands are still held, then release them
    ; and raise: the raise abandons this frame, so nothing may be owed by then.
    ; The type to name, from the TAG: LSA_CLASS is a payload and an int one is
    ; the number itself, which value_type would read as a Value.
    mov rax, [rbp - LSA_CLASSTAG]
    cmp eax, TAG_PTR
    jne .lsa_bad_class_imm
    mov rdi, [rbp - LSA_CLASS]
    mov rsi, [rdi + PyObject.ob_type]
    jmp .lsa_bad_class_name
.lsa_bad_class_imm:
    extern int_type
    extern float_type
    lea rsi, [rel int_type]
    cmp eax, TAG_SMALLINT
    je .lsa_bad_class_name
    lea rsi, [rel float_type]
.lsa_bad_class_name:
    lea rdi, [rel lsa_bad_class_msg]
    extern type_name_message
    call type_name_message
    mov [rbp - LSA_ORIGIN], rax     ; the composed text, across the releases
    mov rdi, [rbp - LSA_SELF]
    DECREF_V rdi, rsi
    mov rdi, [rbp - LSA_CLASS]
    mov rsi, [rbp - LSA_CLASSTAG]
    DECREF_VAL rdi, rsi
    ; DISPATCH saved the stack top from before the three operands were popped.
    mov [rel eval_saved_r13], r13
    lea rdi, [rel exc_TypeError_type]
    mov rsi, [rbp - LSA_ORIGIN]
    extern raise_exception
    leave
    jmp raise_exception

.lsa_bad_self:
    ; Release what was popped and say what CPython says.
    mov rdi, [rbp - LSA_SELF]
    DECREF_V rdi, rsi
    mov rdi, [rbp - LSA_CLASS]
    call obj_decref
    ; DISPATCH saved the stack top from before the three operands were popped.
    mov [rel eval_saved_r13], r13
    RAISE exc_TypeError_type, "super(type, obj): obj must be an instance or subtype of type"

.lsa_not_found:
    ; DECREF class and self
    mov rdi, [rbp - LSA_CLASS]
    call obj_decref
    mov rdi, [rbp - LSA_SELF]
    DECREF_V rdi, rax
.lsa_absent:
    ; CPython's wording names the attribute; ours said only "super: attribute
    ; not found", which is the same information minus the one part a reader
    ; needs.  The super OBJECT reaches the same sentence through the generic
    ; getattr path, which has a type to name.
    mov rdi, [rbp - LSA_NAME]
    extern super_no_attribute
    call super_no_attribute
    ; DISPATCH saved the stack top as it was BEFORE this handler popped its
    ; three operands, and the unwinder cleans up from there -- so raising
    ; without republishing r13 releases those three a second time.
    mov [rel eval_saved_r13], r13
    leave
    jmp eval_exception_unwind

.lsa_found:
    ; rax = attribute value, rdx = tag (from dict_get)
    mov [rbp - LSA_ATTR_TAG], rdx  ; save tag before INCREF/DECREF
    INCREF_VAL rax, rdx
    push rax                       ; save attr

    ; DECREF class
    mov rdi, [rbp - LSA_CLASS]
    call obj_decref

    pop rax                        ; restore attr

    ; A staticmethod reached through super() must be unwrapped and pushed
    ; unbound.  super().__new__(cls) supplies cls itself, so binding self here
    ; would call __new__(cls, cls, ...) — and a staticmethod wrapper has no
    ; tp_call, so it would raise "object is not callable" first.  LOAD_ATTR
    ; does the same thing at .la_handle_staticmethod.
    ; rax is the decoded payload here, not a Value, so the tag is what says
    ; whether it is safe to dereference.
    cmp qword [rbp - LSA_ATTR_TAG], TAG_PTR
    jne .lsa_check_flag
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel staticmethod_type]
    cmp rcx, rdx
    je .lsa_staticmethod
    lea rdx, [rel classmethod_type]
    cmp rcx, rdx
    je .lsa_classmethod

.lsa_check_flag:
    ; Check method flag
    cmp qword [rbp - LSA_FLAG], 0
    je .lsa_attr_mode

    ; Method mode: CPython order: push func (deeper), then self (TOS) -- but
    ; only for something that BINDS.  A module-level builtin parked in a class
    ; body does not, and pushing self under it prepends the receiver to its
    ; arguments: `super().f([1,2])` for `f = len` became len(self, [1,2]).
    cmp qword [rbp - LSA_ATTR_TAG], TAG_PTR
    jne .lsa_method_unbound
    mov [rbp - LSA_ATTR], rax
    mov rdi, rax
    xor esi, esi                   ; super() has already chosen the receiver
    call builtin_should_bind
    mov ecx, eax
    mov rax, [rbp - LSA_ATTR]
    test ecx, ecx
    jz .lsa_method_unbound
    mov rdx, [rbp - LSA_ATTR_TAG]
    VPUSH_VAL rax, rdx             ; push func (deeper = callable)
    mov rax, [rbp - LSA_SELF]     ; self (already has ref from stack)
    VPUSH rax                      ; push self (TOS) -- a Value
    jmp .lsa_done

.lsa_method_unbound:
    ; NULL then the attribute, which is what a call with no receiver expects.
    mov rdi, [rbp - LSA_SELF]
    DECREF_V rdi, rcx              ; self is not going on the stack
    VPUSH_NULL
    mov rax, [rbp - LSA_ATTR]
    mov rdx, [rbp - LSA_ATTR_TAG]
    VPUSH_VAL rax, rdx
    jmp .lsa_done

.lsa_attr_mode:
    ; Attr mode: super().meth is a *bound* method, exactly as it is in
    ; CPython -- the lookup goes through the descriptor protocol.  Pushing
    ; the raw function meant super().__init__(*args) called it with no self,
    ; so the first argument stood in for self and the real instance was
    ; never touched: a list subclass whose __init__ did super().__init__(*a)
    ; came out empty.  The non-star form works because the compiler emits
    ; method mode for it, which is why this went unnoticed.
    cmp qword [rbp - LSA_ATTR_TAG], TAG_PTR
    jne .lsa_attr_plain
    ; A builtin method is equally a descriptor -- super().__init__ on a list
    ; subclass resolves to list.__init__, which is one of these -- but a
    ; module-level builtin parked in a class body is not, and super().f must
    ; hand that one over as it stands.
    mov [rbp - LSA_ATTR], rax
    mov rdi, rax
    xor esi, esi                   ; super() has already chosen the receiver
    extern builtin_should_bind
    call builtin_should_bind
    mov rax, [rbp - LSA_ATTR]
    test eax, eax
    jz .lsa_attr_plain

.lsa_attr_bind:
    mov [rbp - LSA_ATTR], rax
    mov rdi, rax
    mov rsi, [rbp - LSA_SELF]
    call method_new                ; INCREFs both
    push rax                       ; the bound method, ours
    mov rdi, [rbp - LSA_ATTR]
    call obj_decref                ; release our ref on the function
    mov rdi, [rbp - LSA_SELF]
    DECREF_V rdi, rax              ; and on self
    pop rax
    VPUSH_PTR rax
    jmp .lsa_done

.lsa_attr_plain:
    ; Not a function.  A property still has to be RUN -- `super().value` is
    ; the getter's answer, not the descriptor -- and anything else is the
    ; class attribute itself.
    cmp qword [rbp - LSA_ATTR_TAG], TAG_PTR
    jne .lsa_attr_value
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel property_type]
    cmp rcx, rdx
    je .lsa_attr_property
.lsa_attr_value:
    push rax                      ; save attr
    mov rdi, [rbp - LSA_SELF]
    DECREF_V rdi, rax
    pop rax
    mov rdx, [rbp - LSA_ATTR_TAG]
    VPUSH_VAL rax, rdx             ; push attr
    jmp .lsa_done

.lsa_attr_property:
    mov [rbp - LSA_ATTR], rax
    mov rdi, rax
    mov rsi, [rbp - LSA_SELF]
    call property_descr_get        ; -> (rax, rdx), owned
    SAVE_FAT_RESULT
    mov rdi, [rbp - LSA_ATTR]
    call obj_decref
    mov rdi, [rbp - LSA_SELF]
    DECREF_V rdi, rax
    RESTORE_FAT_RESULT
    test edx, edx
    jz .lsa_propagate              ; the getter raised
    cmp qword [rbp - LSA_FLAG], 0
    je .lsa_prop_one
    VPUSH_NULL                     ; a value, not a method: NULL beneath it
.lsa_prop_one:
    VPUSH_VAL rax, rdx
    jmp .lsa_done

.lsa_propagate:
    ; As at .lsa_not_found: the unwinder starts from eval_saved_r13, which is
    ; where the stack was before the three operands came off it.
    mov [rel eval_saved_r13], r13
    leave
    extern eval_exception_unwind
    jmp eval_exception_unwind

.lsa_staticmethod:
    ; Unwrap sm_callable, release the wrapper and self, push (NULL, callable)
    ; in both flag modes — a staticmethod never binds self.
    mov rcx, [rax + PyStaticMethodObject.sm_callable]
    mov [rbp - LSA_ATTR], rcx
    push rax                       ; save the wrapper
    mov rdi, rcx
    call obj_incref                ; we now own the callable
    pop rdi                        ; the wrapper
    call obj_decref
    mov rdi, [rbp - LSA_SELF]
    DECREF_V rdi, rax              ; not binding self
    cmp qword [rbp - LSA_FLAG], 0
    je .lsa_sm_one
    VPUSH_NULL
.lsa_sm_one:
    mov rax, [rbp - LSA_ATTR]
    VPUSH_PTR rax
    jmp .lsa_done

.lsa_classmethod:
    ; Unwrap cm_callable and bind it to the derived class, not to self:
    ; super().cm() must pass type(self), matching .la_handle_classmethod.
    mov rcx, [rax + PyClassMethodObject.cm_callable]
    mov [rbp - LSA_ATTR], rcx
    push rax                       ; save the wrapper
    mov rdi, rcx
    call obj_incref                ; we now own the callable
    pop rdi                        ; the wrapper
    call obj_decref

    ; class = self when self is already a type, else type(self).  self is a
    ; Value, so its type comes from value_type: `super(int, 1).from_bytes`
    ; read the immediate's low bits as an object header.
    mov rdi, [rbp - LSA_SELF]
    call value_type
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jnz .lsa_cm_self_is_type
    mov [rbp - LSA_BIND], rax
    mov rdi, rax
    call obj_incref
    jmp .lsa_cm_have_class
.lsa_cm_self_is_type:
    mov rdi, [rbp - LSA_SELF]
    mov [rbp - LSA_BIND], rdi
    call obj_incref
.lsa_cm_have_class:
    mov rdi, [rbp - LSA_SELF]
    DECREF_V rdi, rax              ; the class stands in for self

    cmp qword [rbp - LSA_FLAG], 0
    jne .lsa_cm_flag1

    ; Attr mode: one value, a method bound to the class
    mov rdi, [rbp - LSA_ATTR]
    mov rsi, [rbp - LSA_BIND]
    call method_new                ; INCREFs both
    push rax                       ; save the bound method
    mov rdi, [rbp - LSA_ATTR]
    call obj_decref
    mov rdi, [rbp - LSA_BIND]
    call obj_decref
    pop rax
    VPUSH_PTR rax
    jmp .lsa_done

.lsa_cm_flag1:
    ; Method mode: func deeper, the class as self on top
    mov rax, [rbp - LSA_ATTR]
    VPUSH_PTR rax
    mov rax, [rbp - LSA_BIND]
    VPUSH_PTR rax
    jmp .lsa_done

.lsa_done:
    ; Skip 1 CACHE entry = 2 bytes
    add rbx, 2
    leave
    DISPATCH
END_FUNC op_load_super_attr

;; ============================================================================
;; raise_name_not_defined(PyStrObject *name)
;; Raise NameError with message "name 'X' is not defined"
;; rdi = name string object
;; Does not return.
;; ============================================================================
; The copy below is BOUNDED, and was not: a name long enough to fill the
; buffer wrote straight past the frame.  `if True: ` + `a` * 256 is a valid
; statement and its NameError carries a 256-character name, which overflowed a
; 256-byte buffer by the prefix, the suffix and the NUL -- and the crash landed
; in eval_return's DECREF of a frame field holding the bytes "efined".
; test_traceback's test_traceback_very_long_line is where it showed.
; 200 is CPython's own bound, not a buffer size: NAME_ERROR_MSG is
; "name '%.200s' is not defined", so a longer name is truncated there too and
; the messages match exactly.
RNND_BUF     equ 512
RNND_MAXNAME equ 200
RNND_FRAME   equ RNND_BUF
DEF_FUNC raise_name_not_defined, RNND_FRAME
    ; Build "name 'X' is not defined" in stack buffer
    lea rcx, [rbp - RNND_BUF]
    lea rsi, [rdi + PyStrObject.data]   ; name C-string

    ; "name '"
    mov dword [rcx], "name"
    mov word [rcx+4], " '"
    add rcx, 6

    ; Copy name
    mov edx, RNND_MAXNAME
.rnnd_copy:
    test edx, edx
    jz .rnnd_name_done
    mov al, [rsi]
    test al, al
    jz .rnnd_name_done
    mov [rcx], al
    inc rcx
    inc rsi
    dec edx
    jmp .rnnd_copy
.rnnd_name_done:

    ; "' is not defined"
    mov dword [rcx], "' is"
    mov dword [rcx+4], " not"
    mov dword [rcx+8], " def"
    mov dword [rcx+12], "ined"
    mov byte [rcx+16], 0
    ; Total appended: 16 chars

    extern exc_NameError_type
    lea rdi, [rel exc_NameError_type]
    lea rsi, [rbp - RNND_BUF]
    call raise_exception
END_FUNC raise_name_not_defined

;; ============================================================================
;; obj_getattr_opt(Value obj, PyStrObject *name) -> rax = Value, or 0
;;
;; One attribute lookup, with the descriptor protocol run over the result --
;; the same answer `obj.name` gives.  Returns 0 when there is no such
;; attribute; a getter that raises unwinds out of here the way it unwinds out
;; of any other call, so 0 never means "raised".
;;
;; getattr() and hasattr() each used to do their own partial version of this,
;; stopping at the raw type-dict entry.  That returned the property object
;; itself rather than calling it, so `p.v` and `getattr(p, "v")` disagreed --
;; and collections.namedtuple, which reaches its fields through descriptors
;; built at runtime, was on the wrong side of the difference.
;;
;; op_load_attr still has its own copy: it needs the unbound attribute and the
;; from-type flag to decide the two-slot push its method form uses, which a
;; function returning one value cannot give it.  tests/test_getattr_descriptors.py
;; pins the two to agree.
;; ============================================================================
GA_OBJ      equ 8
GA_NAME     equ 16
GA_ATTR     equ 24
GA_ATTRTAG  equ 32
GA_FROMTYPE equ 40
GA_CLASS    equ 48
GA_TYPE     equ 56
GA_SAVE     equ 64
GA_SAVETAG  equ 72
GA_WALK     equ 80          ; the MRO cursor
GA_OWNMRO   equ 88          ; the attribute came from the CLASS's own MRO
GA_FROMMETA equ 96          ; type_getattr_meta's out-parameter
GA_FROMINST equ 104         ; instance_getattr_where's: instance storage
GA_FRAME    equ 120         ; + 1 push = 128
DEF_FUNC obj_getattr_opt, GA_FRAME
    push rbx
    mov [rbp - GA_OBJ], rdi
    mov [rbp - GA_NAME], rsi
    mov qword [rbp - GA_FROMTYPE], 0
    mov qword [rbp - GA_OWNMRO], 0
    mov qword [rbp - GA_FROMINST], 0

    ; The type to look in, and whether the object is a real pointer.
    V_TEST_PTR rdi, rax
    ja .ga_immediate
    test rdi, rdi
    jz .ga_none
    mov rax, [rdi + PyObject.ob_type]
    mov [rbp - GA_TYPE], rax
    jmp .ga_try_getattr

.ga_immediate:
    ; An int or a float immediate: its type is fixed by the tag.
    lea rax, [rel float_type]
    V_IS_INT rdi, rcx
    jb .ga_have_type
    lea rax, [rel int_type]
.ga_have_type:
    mov [rbp - GA_TYPE], rax
    ; fall through

.ga_try_getattr:
    ; tp_getattr resolves the whole thing when a type has one.  The immediate
    ; path reaches this too, which it did not before: int and float have a
    ; chain now, for .real and its three neighbours, and skipping it here made
    ; hasattr(5, "real") answer False while (5).real worked.  op_load_attr and
    ; this function are pinned to agree by tests/test_getattr_descriptors.py.
    mov rax, [rbp - GA_TYPE]
    mov rcx, [rax + PyTypeObject.tp_getattr]
    test rcx, rcx
    jz .ga_type_dict
    mov qword [rbp - GA_OWNMRO], 0
    mov rdi, [rbp - GA_OBJ]
    mov rsi, [rbp - GA_NAME]
    ; type_getattr can say WHICH MRO answered -- the class's own or its
    ; metatype's -- and the descriptor protocol below needs to know: a
    ; property found on the class is the property, one found on the metatype
    ; runs.  Nothing else has anything to report.
    extern type_getattr
    extern type_getattr_meta
    lea rdx, [rel type_getattr]
    cmp rcx, rdx
    je .ga_call_type_getattr
    ; The same question op_load_attr asks, and it has to get the same answer:
    ; tests/test_getattr_descriptors.py pins the two together.
    lea rdx, [rel instance_getattr]
    cmp rcx, rdx
    jne .ga_call_getattr
    mov rdi, [rbp - GA_OBJ]
    mov rsi, [rbp - GA_NAME]
    lea rdx, [rbp - GA_FROMINST]
    xor ecx, ecx                ; getattr() wants the bound method itself
    call instance_getattr_where
    test rax, rax
    jnz .ga_where_found
    ; As op_load_attr: an AttributeError installed on the way is the answer.
    ; getattr() and hasattr() see it pending and decide what it means.
    cmp qword [rel attr_error_pending], 0
    je .ga_type_dict
    cmp qword [rel current_exception], 0
    je .ga_type_dict
    xor eax, eax
    pop rbx
    leave
    ret
.ga_where_found:
    V_UNPACK rax, rdx
    jmp .ga_getattr_done
.ga_call_type_getattr:
    mov qword [rbp - GA_FROMMETA], 0
    lea rdx, [rbp - GA_FROMMETA]
    call type_getattr_meta
    V_UNPACK rax, rdx
    test edx, edx
    jz .ga_type_dict
    cmp qword [rbp - GA_FROMMETA], 0
    jne .ga_getattr_done
    mov qword [rbp - GA_OWNMRO], 1
    jmp .ga_getattr_done
.ga_call_getattr:
    ; A MODULE's tp_getattr reads the module's own dict, which is INSTANCE
    ; storage: CPython's module_getattro hands the value back as it stands, so
    ; a staticmethod in a module dict is a staticmethod object and not the
    ; function inside it.  The descriptor block below ran over it and unwrapped
    ; it -- and lib/select.py keeps one there on purpose, because CPython's
    ; select.select is a C function that does NOT bind when a class body stores
    ; it, which is exactly what Lib/selectors.py does with it.
    lea rdx, [rel module_getattr]
    cmp rcx, rdx
    je .ga_getattr_as_is
    ; And a super's, as in op_load_attr: its answer is already final.
    lea rdx, [rel super_getattr_value]
    cmp rcx, rdx
    jne .ga_getattr_go
.ga_getattr_as_is:
    mov qword [rbp - GA_FROMINST], 1
.ga_getattr_go:
    call rcx
    V_UNPACK rax, rdx
    test edx, edx
    jz .ga_type_dict
.ga_getattr_done:
    mov [rbp - GA_ATTR], rax
    mov [rbp - GA_ATTRTAG], rdx
    jmp .ga_have_attr

.ga_none:
    xor eax, eax
    pop rbx
    leave
    ret

.ga_type_dict:
    ; Walk the MRO, not just the exact type.  Stopping at the first tp_dict
    ; made everything object supplies invisible from an instance: `None.__new__`
    ; raised while `object.__new__` was fine, because only lookups on a TYPE
    ; walked.
    mov rax, [rbp - GA_TYPE]
    mov [rbp - GA_WALK], rax
.ga_mro_loop:
    mov rax, [rbp - GA_WALK]
    test rax, rax
    jz .ga_generic
    mov rax, [rax + PyTypeObject.tp_dict]
    test rax, rax
    jz .ga_mro_next
    mov rdi, rax
    mov rsi, [rbp - GA_NAME]
    call dict_get
    V_UNPACK rax, rdx
    test edx, edx
    jnz .ga_from_type
.ga_mro_next:
    mov rax, [rbp - GA_WALK]
    MRO_NEXT rax, [rbp - GA_TYPE]
    mov [rbp - GA_WALK], rax
    jmp .ga_mro_loop
.ga_from_type:
    mov [rbp - GA_ATTR], rax
    mov [rbp - GA_ATTRTAG], rdx
    INCREF_VAL rax, rdx
    mov qword [rbp - GA_FROMTYPE], 1
    jmp .ga_have_attr

.ga_generic:
    ; The attributes every object has -- __class__, __dict__ -- which no
    ; individual tp_getattr provides.
    mov rdi, [rbp - GA_OBJ]
    mov rsi, [rbp - GA_NAME]
    call obj_generic_attr
    test rax, rax
    jz .ga_missing
    mov [rbp - GA_ATTR], rax
    mov qword [rbp - GA_ATTRTAG], TAG_PTR

.ga_have_attr:
    ; --- the descriptor protocol, over whatever the lookup produced ---
    ; Except over INSTANCE STORAGE.  A property in an instance dict or a
    ; __slots__ slot is a property object, not a call to its getter.
    cmp qword [rbp - GA_FROMINST], 0
    jne .ga_plain
    cmp qword [rbp - GA_ATTRTAG], TAG_PTR
    jne .ga_plain
    mov rax, [rbp - GA_ATTR]
    mov rcx, [rax + PyObject.ob_type]

    lea rdx, [rel staticmethod_type]
    cmp rcx, rdx
    je .ga_static

    lea rdx, [rel classmethod_type]
    cmp rcx, rdx
    je .ga_class

    lea rdx, [rel property_type]
    cmp rcx, rdx
    je .ga_property

    lea rdx, [rel getset_descr_type]
    cmp rcx, rdx
    je .ga_getset

    ; A user-defined descriptor: a heaptype whose own type defines __get__,
    ; or a static type that declares itself one (`super`).
    test dword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE | TYPE_FLAG_DESCRIPTOR
    jz .ga_plain
    mov rdi, rcx
    lea rsi, [rel dunder_get]
    call dunder_lookup
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    jz .ga_plain
    mov rdi, [rbp - GA_ATTR]
    ; Found in a CLASS's own MRO, it is read through the class: __get__(None,
    ; cls), as `cls.name` does.  Passing the class as the instance and its
    ; metatype as the owner made getattr(cls, name) disagree with cls.name for
    ; every Python-written data descriptor -- ctypes' Structure fields among
    ; them, whose __get__ then refused the class as "not a ctype instance".
    cmp qword [rbp - GA_OWNMRO], 0
    jne .ga_user_own
    mov rsi, [rbp - GA_OBJ]
    mov rdx, [rbp - GA_TYPE]
    jmp .ga_user_call
.ga_user_own:
    lea rsi, [rel none_singleton]
    mov rdx, [rbp - GA_OBJ]
.ga_user_call:
    lea rcx, [rel dunder_get]
    mov r8d, TAG_PTR
    call dunder_call_3
    mov [rbp - GA_SAVE], rax
    mov rdi, [rbp - GA_ATTR]
    call obj_decref
    mov rax, [rbp - GA_SAVE]
    pop rbx
    leave
    ret

.ga_getset:
    ; As in op_load_attr: through the type it is a read, out of the type's own
    ; dict it is the descriptor itself.
    cmp qword [rbp - GA_FROMTYPE], 0
    je .ga_plain
    mov rdi, [rbp - GA_ATTR]
    mov rsi, [rbp - GA_OBJ]
    call getset_descr_get
    mov [rbp - GA_SAVE], rax
    mov rdi, [rbp - GA_ATTR]
    call obj_decref
    mov rax, [rbp - GA_SAVE]
    pop rbx
    leave
    ret

.ga_static:
    mov rax, [rbp - GA_ATTR]
    mov rbx, [rax + PyStaticMethodObject.sm_callable]
    INCREF rbx
    mov rdi, rax
    call obj_decref
    mov rax, rbx
    pop rbx
    leave
    ret

.ga_class:
    ; Bound to the class: to the object itself when that is already a type,
    ; and to its type otherwise.  An immediate int or float has no ob_type to
    ; read, and reaching for one dereferenced the number -- getattr(5,
    ; "from_bytes") is an ordinary thing to write.
    mov rax, [rbp - GA_ATTR]
    mov rbx, [rax + PyClassMethodObject.cm_callable]
    mov rdi, [rbp - GA_OBJ]
    V_TEST_PTR rdi, rcx
    ja .ga_class_of_type
    test rdi, rdi
    jz .ga_class_of_type
    mov rcx, [rdi + PyObject.ob_type]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jnz .ga_class_self
.ga_class_of_type:
    mov rdi, [rbp - GA_TYPE]
.ga_class_self:
    mov [rbp - GA_CLASS], rdi
    mov rdi, rbx
    mov rsi, [rbp - GA_CLASS]
    call method_new
    mov [rbp - GA_SAVE], rax
    mov rdi, [rbp - GA_ATTR]
    call obj_decref
    mov rax, [rbp - GA_SAVE]
    pop rbx
    leave
    ret

.ga_property:
    ; A property found in the CLASS's own MRO is the property itself --
    ; `C.prop` is what you write `C.prop.__doc__ = ...` on -- while one found
    ; on the METATYPE runs, which is what makes Enum.__members__ work.  Which
    ; it was is type_getattr_meta's answer; deciding it from "is the object a
    ; class" gets the second case wrong.
    cmp qword [rbp - GA_OWNMRO], 0
    je .ga_property_run
    mov rax, [rbp - GA_ATTR]
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.ga_property_run:
    mov rdi, [rbp - GA_ATTR]
    mov rsi, [rbp - GA_OBJ]
    call property_descr_get
    ; As in op_load_attr: an AttributeError out of the getter is the attribute
    ; saying it is absent, and a class with __getattr__ gets its chance at the
    ; name.  getattr(o, n, default) reaches the property through here.
    test edx, edx
    jnz .ga_prop_got
    mov rdi, [rbp - GA_OBJ]
    mov rsi, [rbp - GA_NAME]
    call attr_getattr_hook
.ga_prop_got:
    ; property_descr_get hands back the (payload, tag) pair, already unpacked.
    ; Unpacking it again read the payload as a Value: a small int came back as
    ; a pointer to its own numeric value, and the first thing to touch it died.
    mov [rbp - GA_SAVE], rax
    mov [rbp - GA_SAVETAG], rdx
    mov rdi, [rbp - GA_ATTR]
    call obj_decref
    mov rax, [rbp - GA_SAVE]
    mov rdx, [rbp - GA_SAVETAG]
    V_PACK rax, rdx
    pop rbx
    leave
    ret

.ga_plain:
    ; A function found on the type binds to the instance; one found on the
    ; instance does not.
    cmp qword [rbp - GA_FROMTYPE], 0
    je .ga_done
    cmp qword [rbp - GA_ATTRTAG], TAG_PTR
    jne .ga_done
    mov rax, [rbp - GA_ATTR]
    mov rcx, [rax + PyObject.ob_type]
    cmp qword [rcx + PyTypeObject.tp_call], 0
    je .ga_done
    ; A type is callable but is not a method of its instance.
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jnz .ga_done
    mov rdi, rax
    mov rsi, [rbp - GA_OBJ]
    call method_new
    mov [rbp - GA_SAVE], rax
    mov rdi, [rbp - GA_ATTR]
    call obj_decref
    mov rax, [rbp - GA_SAVE]
    pop rbx
    leave
    ret

.ga_done:
    mov rax, [rbp - GA_ATTR]
    mov rdx, [rbp - GA_ATTRTAG]
    V_PACK rax, rdx
    pop rbx
    leave
    ret

.ga_missing:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC obj_getattr_opt

;; ============================================================================
;; The pure stack shuffles.  Nothing below reads a name or touches a dict.
;; ============================================================================

section .text

;; ============================================================================
;; op_pop_top - Pop and discard top of stack, DECREF it
;; ============================================================================
DEF_FUNC_BARE op_pop_top
    VPOP rax
    DECREF_V rax, rdx
    DISPATCH
END_FUNC op_pop_top

;; ============================================================================
;; op_push_null - Push NULL (0) sentinel onto the value stack
;;
;; Used before LOAD_GLOBAL/LOAD_ATTR to mark callable slots.
;; ============================================================================
DEF_FUNC_BARE op_push_null
    VPUSH_NULL
    DISPATCH
END_FUNC op_push_null

;; ============================================================================
;; op_copy - Copy the i-th item (1-based from top) to top of stack
;;
;; ecx = arg = position (1 = top of stack)
;; Stack layout: ... [r13 - N*8] ... [r13 - 8] [r13]
;;                                                ^ TOS (position 1)
;; ============================================================================
DEF_FUNC_BARE op_copy
    ; ecx = position (1-indexed from top)
    ; Compute address: r13 - ecx*8 (8 bytes/slot)
    mov rax, rcx
    mov rdx, r13
    shl rax, 3
    sub rdx, rax               ; slot i
    mov rax, [rdx]             ; peek the Value at position i
    INCREF_V rax, rsi
    mov [r13], rax
    add r13, 8
    DISPATCH
END_FUNC op_copy

;; ============================================================================
;; op_swap - Swap TOS with the i-th item (1-indexed from top)
;;
;; ecx = arg = position (1 = top, so swap(1) is a no-op, swap(2) swaps
;;   top two items, etc.)
;; TOS is at [r13-8], i-th item is at [r13 - i*8]
;; No reference count changes needed (just moving pointers).
;; ============================================================================
DEF_FUNC_BARE op_swap
    ; ecx = position (1-indexed from top)
    ; Swap TOS with the i-th item -- one word each now
    mov rax, rcx
    mov rdx, r13
    shl rax, 3
    sub rdx, rax               ; slot i
    mov r9, [rdx]
    mov r10, [r13 - 8]
    mov [rdx], r10
    mov [r13 - 8], r9
    DISPATCH
END_FUNC op_swap
