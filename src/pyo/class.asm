; class_obj.asm - Class instances and bound methods for apython
; Phase 10: class instantiation, attribute access, __init__ dispatch

%include "macros.inc"
%include "object.inc"
%include "types.inc"
%include "frame.inc"

extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern ap_free
extern obj_decref
extern obj_incref
extern obj_dealloc
extern dict_new
extern dict_get
extern dict_set
extern str_from_cstr
extern str_from_cstr_heap
extern ap_strcmp
extern type_repr
extern fatal_error
extern raise_exception
extern exc_AttributeError_type
extern exc_TypeError_type
extern func_type
extern type_type
extern method_traverse
extern method_clear
extern instance_traverse
extern instance_clear
extern int_type
extern str_type
extern staticmethod_type
extern classmethod_type
extern property_type
extern property_descr_get
extern eval_frame
extern frame_new
extern frame_free

;; ============================================================================
;; instance_new(PyTypeObject *type) -> PyInstanceObject*
;; Allocate a new instance of the given class type.
;; rdi = type (the class)
;; Returns: new instance with refcnt=1, ob_type=type, inst_dict=new dict
;; ============================================================================
DEF_FUNC instance_new
    push rbx
    push r12

    mov rbx, rdi                ; rbx = type

    ; Allocate using tp_basicsize (GC-tracked, supports __slots__)
    mov rdi, [rbx + PyTypeObject.tp_basicsize]
    push rdi                    ; save size for zero-fill
    mov rsi, rbx                ; type
    call gc_alloc
    mov r12, rax                ; r12 = instance (ob_refcnt=1, ob_type set)

    ; Zero-fill body past header (handles slot init to TAG_NULL)
    pop rcx                     ; size in bytes
    sub rcx, OBJ_HEADER_SIZE
    jle .skip_zero
    lea rdi, [r12 + OBJ_HEADER_SIZE]
    shr rcx, 3
    xor eax, eax
    rep stosq
.skip_zero:

    ; INCREF type (stored in ob_type)
    mov rdi, rbx
    call obj_incref

    ; Create inst_dict only if class doesn't have __slots__ (or has __dict__ in __slots__)
    mov rax, [rbx + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_HAS_SLOTS
    jnz .in_no_dict              ; __slots__ suppresses inst_dict

    call dict_new
    mov [r12 + PyInstanceObject.inst_dict], rax

.in_no_dict:
    mov rdi, r12
    call gc_track

    mov rax, r12                ; return instance
    pop r12
    pop rbx
    leave
    ret
END_FUNC instance_new

;; ============================================================================
;; instance_getattr(PyInstanceObject *self, PyObject *name) -> PyObject*
;; Look up an attribute on an instance.
;; 1. Check self->inst_dict — return raw value
;; 2. If not found, check type->tp_dict (walk tp_base chain)
;; 3. If found in type dict and callable, create bound method
;; 4. If found, INCREF and return
;; 5. If not found, return NULL
;;
;; rdi = instance, rsi = name (PyStrObject*)
;; Returns: owned reference to attribute value, or NULL
;; ============================================================================
DEF_FUNC instance_getattr
    push rbx
    push r12
    push r13

    mov rbx, rdi                ; rbx = self (instance)
    mov r12, rsi                ; r12 = name

    ; Check self->inst_dict first (may be NULL for int subclass instances)
    mov rdi, [rbx + PyInstanceObject.inst_dict]
    test rdi, rdi
    jz .check_type_dict
    mov rsi, r12
    mov edx, TAG_PTR
    call dict_get
    test edx, edx
    jnz .found_inst

.check_type_dict:

    ; Not in inst_dict -- walk type MRO: check type->tp_dict, then tp_base chain
    mov rcx, [rbx + PyObject.ob_type]   ; rcx = type (the class)
.walk_mro:
    mov rdi, [rcx + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .try_base

    push rcx                            ; save current type
    mov rsi, r12
    mov edx, TAG_PTR
    call dict_get
    pop rcx                             ; restore current type
    test edx, edx
    jnz .found_type                     ; found in type's dict

.try_base:
    mov rcx, [rcx + PyTypeObject.tp_base]
    test rcx, rcx
    jnz .walk_mro

    jmp .not_found

.found_inst:
    ; Found in instance dict — INCREF and return raw value
    mov r13, rax                ; save payload
    mov r12, rdx                ; save tag (name no longer needed)
    INCREF_VAL rax, edx         ; tag-aware INCREF (skips SmallInt/NULL)
    mov rax, r13
    mov rdx, r12                ; restore tag from dict_get
    pop r13
    pop r12
    pop rbx
    leave
    ret

.found_type:
    ; Found in type dict — handle method binding.
    ; Descriptors (staticmethod, classmethod, property) are returned as-is
    ; for LOAD_ATTR to unwrap, since LOAD_ATTR knows the push convention.
    ; Member descriptors (slots) read from fixed instance offset.
    ; Regular callables are bound to the instance.
    mov r13, rax                ; r13 = attr (borrowed ref from dict_get)
    mov r12, rdx                ; r12 = attr tag (name no longer needed)
    cmp r12, TAG_PTR
    jne .found_type_raw         ; non-pointer — return as-is

    mov rcx, [rax + PyObject.ob_type]

    ; Check for member descriptor (slot) → read from instance offset
    extern member_descr_type
    lea rdx, [rel member_descr_type]
    cmp rcx, rdx
    je .found_slot

    ; Check for staticmethod/classmethod/property → return raw descriptor
    ; LOAD_ATTR handles unwrapping with the correct push convention
    lea rdx, [rel staticmethod_type]
    cmp rcx, rdx
    je .found_type_raw

    lea rdx, [rel classmethod_type]
    cmp rcx, rdx
    je .found_type_raw

    lea rdx, [rel property_type]
    cmp rcx, rdx
    je .found_type_raw

    ; Only bind func_type and builtin_func_type as methods
    ; Types, classes, and other callables are returned as-is
    lea rdx, [rel func_type]
    cmp rcx, rdx
    je .bind_method

    extern builtin_func_type
    lea rdx, [rel builtin_func_type]
    cmp rcx, rdx
    je .bind_method

    jmp .found_type_raw         ; not a function — return raw

.bind_method:
    ; Function found in type dict — create bound method
    mov rdi, r13                ; func
    mov rsi, rbx                ; self (instance)
    call method_new
    ; rax = bound method (method_new INCREFs func and self)
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.found_slot:
    ; Member descriptor found — read value from instance at fixed offset
    ; r13 = member descriptor, rbx = instance
    mov rcx, [r13 + PyMemberDescrObject.md_offset]
    mov rax, [rbx + rcx]       ; slot payload
    mov rdx, [rbx + rcx + 8]  ; slot tag
    test edx, edx
    jz .slot_not_set            ; TAG_NULL = slot not set → AttributeError
    INCREF_VAL rax, rdx
    pop r13
    pop r12
    pop rbx
    leave
    ret

.found_type_raw:
    ; Not callable, SmallInt, or descriptor — INCREF and return
    INCREF_VAL r13, r12         ; tag-aware INCREF
    mov rax, r13
    mov rdx, r12                ; restore tag from dict_get
    pop r13
    pop r12
    pop rbx
    leave
    ret

.slot_not_set:
    ; Slot exists but not initialized — raise AttributeError directly
    ; (must not return NULL or LOAD_ATTR fallback finds descriptor in tp_dict)
    lea rdi, [rel exc_AttributeError_type]
    CSTRING rsi, "slot attribute not set"
    call raise_exception

.not_found:
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC instance_getattr

;; ============================================================================
;; instance_setattr(PyInstanceObject *self, PyObject *name, PyObject *value)
;; Set an attribute on an instance's __dict__.
;; rdi = instance, rsi = name, rdx = value
;; ============================================================================
DEF_FUNC instance_setattr
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi                ; instance
    mov r12, rsi                ; name
    mov r13, rdx                ; value
    mov r14, rcx                ; value_tag

    ; Walk type dict chain looking for member descriptor (slot)
    mov rax, [rbx + PyObject.ob_type]
.sa_walk:
    mov rdi, [rax + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .sa_try_base
    push rax                    ; save current type
    mov rsi, r12                ; name
    mov edx, TAG_PTR
    call dict_get
    mov r9, rax                 ; save dict_get value
    pop rax                     ; restore current type
    test edx, edx
    jnz .sa_found_type

.sa_try_base:
    mov rax, [rax + PyTypeObject.tp_base]
    test rax, rax
    jnz .sa_walk
    jmp .sa_no_slot

.sa_found_type:
    ; Check if it's a member descriptor (r9 = dict value, rax = type)
    cmp edx, TAG_PTR
    jne .sa_no_slot
    extern member_descr_type
    lea rcx, [rel member_descr_type]
    cmp [r9 + PyObject.ob_type], rcx
    jne .sa_no_slot

    ; Member descriptor! Write value to slot offset
    mov rcx, [r9 + PyMemberDescrObject.md_offset]

    ; XDECREF old value at slot
    push rcx
    mov rdi, [rbx + rcx]       ; old payload
    mov rsi, [rbx + rcx + 8]  ; old tag
    XDECREF_VAL rdi, rsi
    pop rcx

    ; INCREF new value
    INCREF_VAL r13, r14

    ; Store new value at slot offset
    mov [rbx + rcx], r13
    mov [rbx + rcx + 8], r14

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sa_no_slot:
    ; No slot found. Fall back to inst_dict.
    mov rdi, [rbx + PyInstanceObject.inst_dict]
    test rdi, rdi
    jnz .sa_have_dict

    ; inst_dict is NULL — check if __slots__ class (can't set arbitrary attrs)
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_HAS_SLOTS
    jnz .sa_no_dict_error

    ; Regular class without __slots__ — create dict on the fly
    push r12
    push r13
    push r14
    call dict_new
    mov [rbx + PyInstanceObject.inst_dict], rax
    mov rdi, rax
    pop r14
    pop r13
    pop r12
    jmp .sa_dict_set

.sa_have_dict:
.sa_dict_set:
    ; dict_set(inst_dict, name, value, value_tag, key_tag)
    mov rsi, r12                ; name
    mov rdx, r13                ; value
    mov rcx, r14                ; value_tag
    mov r8d, TAG_PTR            ; key_tag (name is always heap string)
    call dict_set

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sa_no_dict_error:
    lea rdi, [rel exc_AttributeError_type]
    CSTRING rsi, "object has no attribute"
    call raise_exception
END_FUNC instance_setattr

;; ============================================================================
;; type_setattr(PyTypeObject *type, PyObject *name, PyObject *value, ecx=value_tag)
;; Set an attribute on a type's tp_dict.
;; rdi = type, rsi = name, rdx = value, ecx = value_tag
;; ============================================================================
DEF_FUNC type_setattr
    push rbx
    push rcx                    ; save value_tag

    ; Ensure tp_dict exists
    mov rbx, rdi
    mov rdi, [rbx + PyTypeObject.tp_dict]
    test rdi, rdi
    jnz .ts_have_dict

    ; Allocate a new dict for this type
    push rsi
    push rdx
    call dict_new
    mov [rbx + PyTypeObject.tp_dict], rax
    mov rdi, rax
    pop rdx
    pop rsi

.ts_have_dict:
    ; dict_set(dict, name, value, ecx=value_tag, r8=key_tag)
    pop rcx                     ; restore value_tag
    mov r8d, TAG_PTR            ; key_tag (name is always heap string)
    call dict_set

    pop rbx
    leave
    ret
END_FUNC type_setattr

;; ============================================================================
;; instance_dealloc(PyObject *self)
;; Deallocate an instance: DECREF inst_dict, DECREF ob_type, free self.
;; rdi = instance
;; ============================================================================
DEF_FUNC instance_dealloc
    push rbx

    mov rbx, rdi                ; rbx = self

    ; Check for __del__ dunder on heaptype
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_HEAPTYPE
    jz .no_del

    ; Temporarily bump refcount to prevent re-entrant dealloc during __del__
    inc qword [rbx + PyObject.ob_refcnt]

    ; Call __del__(self) — dunder_call_1 handles lookup + call
    extern dunder_del
    extern dunder_call_1
    mov rdi, rbx
    lea rsi, [rel dunder_del]
    call dunder_call_1
    ; Ignore return value — DECREF if non-NULL
    test edx, edx
    jz .del_no_result
    DECREF_VAL rax, rdx
.del_no_result:

    ; Restore refcount (undo the bump)
    dec qword [rbx + PyObject.ob_refcnt]

.no_del:
    ; XDECREF inst_dict (may be NULL for int subclass instances)
    mov rdi, [rbx + PyInstanceObject.inst_dict]
    test rdi, rdi
    jz .no_dict
    call obj_decref
.no_dict:

    ; Check if this is an int subclass — XDECREF int_value (tag-aware)
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_INT_SUBCLASS
    jz .no_int_value
    mov rdi, [rbx + PyIntSubclassObject.int_value]
    mov rsi, [rbx + PyIntSubclassObject.int_value_tag]
    DECREF_VAL rdi, rsi
.no_int_value:

    ; DECREF_VAL each __slots__ slot
    ; nslots = (tp_basicsize - PyInstanceObject_size) / 16
    push r12
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_basicsize]
    sub rax, PyInstanceObject_size
    jle .no_slots                ; no slots (basicsize <= PyInstanceObject_size)
    shr rax, 4                  ; nslots = (basicsize - 24) / 16
    mov r12, rax                ; r12 = remaining count
    lea rcx, [rbx + PyInstanceObject_size]  ; rcx = first slot address

.slot_decref_loop:
    push rcx
    mov rdi, [rcx]              ; slot payload
    mov rsi, [rcx + 8]         ; slot tag
    XDECREF_VAL rdi, rsi
    pop rcx
    add rcx, 16                 ; next slot
    dec r12
    jnz .slot_decref_loop

.no_slots:
    pop r12

    ; Save ob_type before freeing (gc_dealloc reads ob_type, then frees)
    push qword [rbx + PyObject.ob_type]

    ; Free the instance (GC-aware) — must happen before type DECREF
    mov rdi, rbx
    call gc_dealloc

    ; DECREF ob_type (the class) AFTER freeing the instance
    pop rdi
    call obj_decref

    pop rbx
    leave
    ret
END_FUNC instance_dealloc

;; ============================================================================
;; builtin_sub_dealloc(PyObject *self)
;; Dealloc for heap-type subclasses of builtin types (bytes, bytearray, etc.)
;; These don't have inst_dict — just DECREF the type and free.
;; ============================================================================
global builtin_sub_dealloc
DEF_FUNC builtin_sub_dealloc
    push rbx
    mov rbx, rdi

    ; Save ob_type before freeing (gc_dealloc reads ob_type)
    push qword [rbx + PyObject.ob_type]

    ; Free the object (may be GC-tracked) — must happen before type DECREF
    mov rdi, rbx
    call gc_dealloc

    ; DECREF ob_type (the class) AFTER freeing the object
    pop rdi
    call obj_decref

    pop rbx
    leave
    ret
END_FUNC builtin_sub_dealloc

;; ============================================================================
;; instance_repr(PyObject *self) -> PyStrObject*
;; Try __repr__ dunder, fall back to "<instance>".
;; rdi = instance
;; ============================================================================
DEF_FUNC instance_repr
    push rbx
    mov rbx, rdi

    ; Try __repr__ dunder
    extern dunder_repr
    extern dunder_call_1
    lea rsi, [rel dunder_repr]
    ; r12 is callee-saved and still holds eval frame from caller chain
    call dunder_call_1
    test edx, edx
    jnz .done

    ; Fall back to "<instance>"
    lea rdi, [rel instance_repr_cstr]
    call str_from_cstr

.done:
    pop rbx
    leave
    ret
END_FUNC instance_repr

;; ============================================================================
;; instance_str(PyObject *self) -> PyStrObject*
;; Try __str__ dunder, fall back to instance_repr.
;; rdi = instance
;; ============================================================================
DEF_FUNC instance_str
    push rbx
    mov rbx, rdi

    ; Try __str__ dunder
    extern dunder_str
    lea rsi, [rel dunder_str]
    call dunder_call_1
    test edx, edx
    jnz .done

    ; Fall back to instance_repr
    mov rdi, rbx
    call instance_repr

.done:
    pop rbx
    leave
    ret
END_FUNC instance_str

;; ============================================================================
;; type_call(PyTypeObject *type, PyObject **args, int64_t nargs) -> PyObject*
;; tp_call for user-defined class type objects.
;; Calling a class creates an instance, then calls __init__ if present.
;;
;; rdi = type (the class being called)
;; rsi = args array
;; edx = nargs
;; Returns: new instance
;; ============================================================================
; Local frame offsets for .normal_type_call (rbp-relative, after 5 pushes + sub rsp, 24)
TC_NEW_FUNC equ 48              ; [rbp - 48]: saved __new__ func pointer
TC_NEW_TAG  equ 56              ; [rbp - 56]: saved __new__ result tag

DEF_FUNC type_call
    ; Special case: type(x) with 1 arg when calling type itself
    ; Returns x.__class__ (the type of x)
    lea rax, [rel type_type]
    cmp rdi, rax
    jne .not_type_self
    cmp edx, 1
    jne .not_type_self
    ; type(x) → return type of x
    mov rax, [rsi]          ; args[0] payload
    cmp qword [rsi + 8], TAG_SMALLINT
    je .type_smallint       ; SmallInt → int type
    cmp qword [rsi + 8], TAG_FLOAT
    je .type_float          ; TAG_FLOAT → float type
    cmp qword [rsi + 8], TAG_BOOL
    je .type_bool           ; TAG_BOOL → bool type
    cmp qword [rsi + 8], TAG_NONE
    je .type_none           ; TAG_NONE → none type
    mov rax, [rax + PyObject.ob_type]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
.type_smallint:
    lea rax, [rel int_type]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
.type_float:
    extern float_type
    lea rax, [rel float_type]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
.type_bool:
    extern bool_type
    lea rax, [rel bool_type]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
.type_none:
    extern none_type
    lea rax, [rel none_type]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret

.not_type_self:
    ; Check if type has its own tp_call (built-in constructor, e.g. staticmethod)
    mov rax, [rdi + PyTypeObject.tp_call]
    test rax, rax
    jz .normal_type_call
    ; Avoid infinite recursion: don't tail-call if tp_call is type_call itself
    lea rcx, [rel type_call]
    cmp rax, rcx
    je .normal_type_call
    ; Tail-call the constructor: tp_call(type, args, nargs)
    leave
    jmp rax

.normal_type_call:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24                 ; 16 bytes local + 8 align (5 pushes + rbp = 48, +24 = 72 -> rsp 16-aligned)
    mov qword [rbp - TC_NEW_TAG], TAG_PTR  ; default return tag

    mov rbx, rdi                ; rbx = type
    mov r12, rsi                ; r12 = args
    mov r13d, edx               ; r13d = nargs
    movsxd r13, r13d            ; sign-extend to 64 bits

    ; Check if this type inherits from an exception type
    extern type_is_exc_subclass
    mov rdi, rbx
    call type_is_exc_subclass
    test eax, eax
    jnz .exc_subclass_call

    ; Check if this type is an int subclass
    mov rax, [rbx + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_INT_SUBCLASS
    jnz .int_subclass_call

    ; === Look up __new__ in MRO (stop at object_type) ===
    lea rdi, [rel new_name_cstr]
    call str_from_cstr_heap
    mov r15, rax                ; r15 = "__new__" str

    mov rcx, rbx                ; rcx = current type
.new_mro_walk:
    ; Stop at object_type (default __new__ = instance_new)
    lea rdi, [rel object_type]
    cmp rcx, rdi
    je .new_not_found

    mov rdi, [rcx + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .new_try_base

    push rcx
    mov rsi, r15
    mov edx, TAG_PTR
    call dict_get
    pop rcx
    test edx, edx
    jnz .new_found

.new_try_base:
    mov rcx, [rcx + PyTypeObject.tp_base]
    test rcx, rcx
    jnz .new_mro_walk

.new_not_found:
    ; DECREF name string
    mov rdi, r15
    call obj_decref
    ; Default: instance_new(type)
    mov rdi, rbx
    call instance_new
    mov r14, rax                ; r14 = instance
    jmp .lookup_init

.new_found:
    ; rax = __new__ func ptr, edx = tag
    mov [rbp - TC_NEW_FUNC], rax
    ; DECREF name string
    mov rdi, r15
    call obj_decref

    ; Build args for __new__(cls, *original_args)
    lea rax, [r13 + 1]
    shl rax, 4                  ; (nargs+1) * 16
    sub rsp, rax
    mov r15, rsp                ; r15 = new args array

    ; args[0] = cls (the type)
    mov [r15], rbx
    mov qword [r15 + 8], TAG_PTR

    ; Copy original args
    xor ecx, ecx
.copy_new_args:
    cmp rcx, r13
    jge .new_args_copied
    mov rax, rcx
    shl rax, 4
    mov rdx, [r12 + rax]
    mov r8, [r12 + rax + 8]
    lea r9, [rcx + 1]
    shl r9, 4
    mov [r15 + r9], rdx
    mov [r15 + r9 + 8], r8
    inc rcx
    jmp .copy_new_args
.new_args_copied:

    ; Call __new__'s tp_call
    mov rdi, [rbp - TC_NEW_FUNC]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .new_not_callable

    mov rsi, r15                ; args
    lea rdx, [r13 + 1]          ; nargs + 1
    call rax

    mov r14, rax                ; r14 = instance from __new__
    mov [rbp - TC_NEW_TAG], rdx ; save result tag

    ; Restore stack from args allocation
    lea rax, [r13 + 1]
    shl rax, 4
    add rsp, rax

    ; Check: only call __init__ if __new__ returned instance of cls
    cmp qword [rbp - TC_NEW_TAG], TAG_PTR
    jne .no_init
    mov rax, [r14 + PyObject.ob_type]
    cmp rax, rbx
    jne .no_init

.lookup_init:
    ; Look up __init__ walking the MRO (type + tp_base chain)
    ; Create "__init__" string for lookup (heap — dict key, DECREFed)
    lea rdi, [rel init_name_cstr]
    call str_from_cstr_heap
    mov r15, rax                ; r15 = "__init__" str object

    ; Walk MRO: check type->tp_dict, then tp_base chain
    mov rcx, rbx                ; rcx = current type to check
.init_mro_walk:
    mov rdi, [rcx + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .init_try_base

    push rcx                    ; save current type
    mov rsi, r15
    mov edx, TAG_PTR
    call dict_get
    pop rcx                     ; restore current type
    test edx, edx
    jnz .init_found

.init_try_base:
    mov rcx, [rcx + PyTypeObject.tp_base]
    test rcx, rcx
    jnz .init_mro_walk

    ; __init__ not found anywhere — DECREF name string, skip
    mov rdi, r15
    call obj_decref
    jmp .no_init

.init_found:
    mov rbx, rax                ; rbx = __init__ func

    ; DECREF the "__init__" string (no longer needed)
    mov rdi, r15
    call obj_decref

    ; === Call __init__(instance, *args) ===
    ; Build args array on machine stack: [instance, arg0, arg1, ...]
    ; Total args = nargs + 1 (for instance)
    ; Allocate (nargs+1)*16 bytes on the stack (fat values)
    lea rax, [r13 + 1]
    shl rax, 4                  ; (nargs+1) * 16
    sub rsp, rax                ; allocate on stack
    mov r15, rsp                ; r15 = new args array

    ; args[0] = instance (payload + tag)
    mov [r15], r14
    mov qword [r15 + 8], TAG_PTR

    ; Copy original args: args[1..nargs] (16-byte stride)
    xor ecx, ecx
.copy_args:
    cmp rcx, r13
    jge .args_copied
    mov rax, rcx
    shl rax, 4                  ; source index * 16
    mov rdx, [r12 + rax]       ; source payload
    mov r8, [r12 + rax + 8]    ; source tag
    lea r9, [rcx + 1]
    shl r9, 4                   ; dest index * 16 (offset by 1 for instance)
    mov [r15 + r9], rdx        ; dest payload
    mov [r15 + r9 + 8], r8    ; dest tag
    inc rcx
    jmp .copy_args
.args_copied:

    ; Get __init__'s tp_call
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .init_not_callable

    ; Call tp_call(__init_func, args_with_instance, nargs+1)
    mov rdi, rbx                ; callable = __init__ func
    mov rsi, r15                ; args ptr
    lea rdx, [r13 + 1]          ; nargs + 1
    call rax

    ; DECREF __init__'s return value (should be None — TAG_NONE, not a pointer)
    mov rsi, rdx
    DECREF_VAL rax, rsi

    ; Restore stack (undo the sub rsp from args allocation)
    lea rax, [r13 + 1]
    shl rax, 4
    add rsp, rax

.no_init:
    ; Return the instance (tag from TC_NEW_TAG; default TAG_PTR, or __new__ result tag)
    mov rax, r14
    mov rdx, [rbp - TC_NEW_TAG]

    add rsp, 24                 ; undo alignment
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.exc_subclass_call:
    ; User-defined exception subclass — create PyExceptionObject via exc_type_call
    ; rbx = type, r12 = args, r13 = nargs
    extern exc_type_call
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call exc_type_call
    ; rax = exception object (PyExceptionObject)
    mov r14, rax                ; r14 = instance

    ; Check if type has __init__ in its dict (for custom exception __init__)
    mov rdi, [rbx + PyTypeObject.tp_init]
    test rdi, rdi
    jz .exc_sub_no_init

    ; Build args: (instance, *original_args) using 16-byte fat value stride
    lea rax, [r13 + 1]
    shl rax, 4                  ; (nargs+1) * 16
    sub rsp, rax
    mov r15, rsp                ; r15 = new args array
    mov [r15], r14
    mov qword [r15 + 8], TAG_PTR
    ; Copy original args
    xor ecx, ecx
.exc_sub_copy_args:
    cmp rcx, r13
    jge .exc_sub_args_copied
    mov rax, rcx
    shl rax, 4
    mov rdx, [r12 + rax]
    mov r8, [r12 + rax + 8]
    lea r9, [rcx + 1]
    shl r9, 4
    mov [r15 + r9], rdx
    mov [r15 + r9 + 8], r8
    inc rcx
    jmp .exc_sub_copy_args
.exc_sub_args_copied:
    ; Get __init__'s tp_call
    mov rdi, [rbx + PyTypeObject.tp_init]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .exc_sub_init_cleanup
    mov rdi, [rbx + PyTypeObject.tp_init]
    mov rsi, r15
    lea rdx, [r13 + 1]
    call rax
    ; DECREF return value (should be None)
    mov rsi, rdx
    DECREF_VAL rax, rsi
.exc_sub_init_cleanup:
    lea rax, [r13 + 1]
    shl rax, 4
    add rsp, rax

.exc_sub_no_init:
    mov rax, r14
    mov edx, TAG_PTR
    add rsp, 24                 ; undo alignment
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.int_subclass_call:
    ; Int subclass: get int value via builtin_int_fn, then wrap in subclass instance
    ; rbx = type, r12 = args, r13 = nargs
    extern builtin_int_fn
    mov rdi, r12                ; args
    mov rsi, r13                ; nargs
    call builtin_int_fn
    ; rax = int result (SmallInt or GMP pointer), edx = tag
    test edx, edx
    jz .int_sub_error           ; exception from builtin_int_fn
    mov r14, rax                ; r14 = int value
    mov r15d, edx               ; r15d = int value tag

    ; If type is exactly int_type, return bare int (not a subclass)
    lea rcx, [rel int_type]
    cmp rbx, rcx
    je .int_sub_return_bare

    ; Allocate PyIntSubclassObject (gc_alloc since heaptypes have HAVE_GC)
    push r14                     ; save int_value across malloc
    push r15                     ; save int_value_tag across malloc
    mov edi, PyIntSubclassObject_size
    mov rsi, rbx                 ; type = heaptype
    call gc_alloc
    pop r15
    pop r14
    mov qword [rax + PyIntSubclassObject.inst_dict], 0
    mov [rax + PyIntSubclassObject.int_value], r14
    mov [rax + PyIntSubclassObject.int_value_tag], r15
    ; INCREF the type (subclass object holds a reference)
    push rax
    mov rdi, rbx
    INCREF rdi
    pop rax
    ; int_value ownership: builtin_int_fn returns a new reference,
    ; we transfer it directly into the subclass object (no INCREF needed).
    ; Track in GC
    push rax
    mov rdi, rax
    call gc_track
    pop rax
    jmp .int_sub_done

.int_sub_return_bare:
    mov rax, r14
    mov edx, r15d               ; restore saved tag from builtin_int_fn
    jmp .int_sub_epilogue
.int_sub_done:
    mov edx, TAG_PTR            ; subclass instance is always a heap ptr
.int_sub_epilogue:
    add rsp, 24                 ; undo alignment
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.int_sub_error:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.init_not_callable:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "__init__ is not callable"
    call raise_exception
    ; does not return

.new_not_callable:
    ; Restore stack from args allocation, then error
    lea rax, [r13 + 1]
    shl rax, 4
    add rsp, rax
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "__new__ is not callable"
    call raise_exception
    ; does not return
END_FUNC type_call

;; ============================================================================
;; type_getattr(PyTypeObject *self, PyObject *name) -> PyObject*
;; Look up an attribute on a type object itself (class variables).
;; Also handles __name__ (from tp_name) and __bases__.
;; rdi = type object, rsi = name (PyStrObject*)
;; Returns: owned reference to attribute value, or NULL
;; ============================================================================
DEF_FUNC type_getattr
    push rbx
    push r12

    mov rbx, rsi                ; rbx = name
    mov r12, rdi                ; r12 = type

    ; Check for __name__: compare name string data with "__name__"
    lea rdi, [rbx + PyStrObject.data]
    lea rsi, [rel tga_name_str]
    call ap_strcmp
    test eax, eax
    jz .tga_return_name

    ; Check type->tp_dict, then walk tp_base chain
.tga_walk:
    mov rdi, [r12 + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .tga_next_base

    mov rsi, rbx
    mov edx, TAG_PTR
    call dict_get
    test edx, edx
    jnz .tga_found

.tga_next_base:
    mov r12, [r12 + PyTypeObject.tp_base]
    test r12, r12
    jnz .tga_walk
    jmp .tga_not_found

.tga_found:
    ; Found — INCREF and return
    mov rbx, rax                ; save payload (name no longer needed)
    mov r12, rdx                ; save tag (type walk done)
    INCREF_VAL rax, edx         ; tag-aware INCREF (skips SmallInt/NULL)
    mov rax, rbx
    mov rdx, r12                ; restore tag from dict_get

    pop r12
    pop rbx
    leave
    ret

.tga_return_name:
    ; Return str from tp_name (C string)
    mov rdi, [r12 + PyTypeObject.tp_name]
    call str_from_cstr
    pop r12
    pop rbx
    leave
    ret

.tga_not_found:
    RET_NULL
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_getattr

;; ============================================================================
;; method_new(func, self) -> PyMethodObject*
;; Create a bound method wrapping func+self.
;; rdi = func (callable), rsi = self (instance)
;; ============================================================================
DEF_FUNC method_new
    push rbx
    push r12

    mov rbx, rdi                ; func
    mov r12, rsi                ; self

    mov edi, PyMethodObject_size
    lea rsi, [rel method_type]
    call gc_alloc
    ; ob_refcnt=1, ob_type set by gc_alloc
    mov [rax + PyMethodObject.im_func], rbx
    mov [rax + PyMethodObject.im_self], r12

    ; INCREF func and self
    push rax
    mov rdi, rbx
    call obj_incref
    mov rdi, r12
    call obj_incref

    ; Track in GC
    mov rdi, [rsp]
    call gc_track
    pop rax

    pop r12
    pop rbx
    leave
    ret
END_FUNC method_new

;; ============================================================================
;; method_call(self_method, args, nargs) -> PyObject*
;; Call a bound method: prepend im_self to args, dispatch to im_func's tp_call.
;; rdi = PyMethodObject*, rsi = args, rdx = nargs
;; ============================================================================
DEF_FUNC_LOCAL method_call
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi                ; method obj
    mov r12, rsi                ; original args
    mov r13, rdx                ; original nargs

    ; Allocate new args array: (nargs+1) * 16 (fat values)
    lea rdi, [rdx + 1]
    shl rdi, 4
    call ap_malloc
    mov r14, rax                ; new args array

    ; new_args[0] = im_self (payload + tag)
    mov rcx, [rbx + PyMethodObject.im_self]
    mov [r14], rcx
    mov qword [r14 + 8], TAG_PTR

    ; Copy original args to new_args[1..] (16-byte stride)
    xor ecx, ecx
.mc_copy:
    cmp rcx, r13
    jge .mc_copy_done
    mov rax, rcx
    shl rax, 4                  ; source index * 16
    mov rdx, [r12 + rax]       ; source payload
    mov r8, [r12 + rax + 8]    ; source tag
    lea r9, [rcx + 1]
    shl r9, 4                   ; dest index * 16 (offset by 1 for self)
    mov [r14 + r9], rdx        ; dest payload
    mov [r14 + r9 + 8], r8    ; dest tag
    inc rcx
    jmp .mc_copy
.mc_copy_done:

    ; Call im_func's tp_call(im_func, new_args, nargs+1)
    mov rdi, [rbx + PyMethodObject.im_func]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    mov rsi, r14
    lea rdx, [r13 + 1]
    call rax
    push rax                    ; save result payload
    push rdx                    ; save result tag

    ; Free temp args array
    mov rdi, r14
    call ap_free

    pop rdx                     ; restore result tag
    pop rax                     ; restore result payload
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC method_call

;; ============================================================================
;; method_dealloc(PyObject *self)
;; Free a bound method, DECREF func and self.
;; ============================================================================
DEF_FUNC_LOCAL method_dealloc
    push rbx

    mov rbx, rdi

    mov rdi, [rbx + PyMethodObject.im_func]
    call obj_decref
    mov rdi, [rbx + PyMethodObject.im_self]
    call obj_decref
    mov rdi, rbx
    call gc_dealloc

    pop rbx
    leave
    ret
END_FUNC method_dealloc

;; ============================================================================
;; method_getattr(PyMethodObject *self, PyObject *name) -> PyObject* or NULL
;; Delegate attribute lookup to the underlying im_func.
;; rdi = bound method, rsi = name
;; ============================================================================
DEF_FUNC method_getattr
    ; Delegate to the underlying function's getattr
    mov rdi, [rdi + PyMethodObject.im_func]
    extern func_getattr
    call func_getattr
    leave
    ret
END_FUNC method_getattr

;; ============================================================================
;; object_type_call(args, nargs) -> PyObject*
;; object() returns a bare instance of object_type
;; ============================================================================
global object_type_call
DEF_FUNC_BARE object_type_call
    ; Create a bare instance with object_type (gc_alloc since HAVE_GC)
    push rbp
    mov rbp, rsp
    mov edi, PyInstanceObject_size
    lea rsi, [rel object_type]
    call gc_alloc
    mov qword [rax + PyInstanceObject.inst_dict], 0
    ; Track in GC
    push rax
    mov rdi, rax
    call gc_track
    pop rax
    mov edx, TAG_PTR
    pop rbp
    ret
END_FUNC object_type_call

;; ============================================================================
;; object_new_fn(args, nargs) -> instance
;; Implements object.__new__(cls) — creates a bare instance of cls.
;; args[0] = cls (the type to instantiate)
;; ============================================================================
global object_new_fn
DEF_FUNC object_new_fn
    ; args[0] = cls
    mov rdi, [rdi]              ; cls payload (PyTypeObject*)
    call instance_new
    mov edx, TAG_PTR
    leave
    ret
END_FUNC object_new_fn

;; ============================================================================
;; user_type_dealloc(PyTypeObject *type)
;; Deallocator for user-defined heap types (created by __build_class__).
;; Frees tp_dict, tp_name string, and the type object itself.
;; ============================================================================
global user_type_dealloc
DEF_FUNC user_type_dealloc
    push rbx
    mov rbx, rdi                ; rbx = type object

    ; DECREF tp_dict if present
    mov rdi, [rbx + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .utd_no_dict
    call obj_decref
.utd_no_dict:

    ; DECREF tp_name string (recover from data pointer - PyStrObject.data = 32)
    mov rdi, [rbx + PyTypeObject.tp_name]
    test rdi, rdi
    jz .utd_no_name
    sub rdi, PyStrObject.data   ; point back to PyStrObject base
    call obj_decref
.utd_no_name:

    ; DECREF tp_base if present
    mov rdi, [rbx + PyTypeObject.tp_base]
    test rdi, rdi
    jz .utd_no_base
    call obj_decref
.utd_no_base:

    ; DECREF tp_bases tuple if present
    mov rdi, [rbx + PyTypeObject.tp_bases]
    test rdi, rdi
    jz .utd_no_bases
    call obj_decref
.utd_no_bases:

    ; DECREF tp_mro tuple if present
    mov rdi, [rbx + PyTypeObject.tp_mro]
    test rdi, rdi
    jz .utd_no_mro
    call obj_decref
.utd_no_mro:

    ; Free the type object itself (gc_alloc'd)
    mov rdi, rbx
    call gc_dealloc

    pop rbx
    leave
    ret
END_FUNC user_type_dealloc

;; ============================================================================
;; Data section
;; ============================================================================
section .data

instance_repr_cstr: db "<instance>", 0
init_name_cstr:     db "__init__", 0
new_name_cstr:      db "__new__", 0
tga_name_str:       db "__name__", 0
method_name_str:    db "method", 0
object_name_str:    db "object", 0
user_type_name_str: db "type", 0
super_name_str:     db "super", 0

; user_type_metatype - metatype for user-defined classes
; When accessing Foo.x, we go through Foo->ob_type->tp_getattr = type_getattr
; which looks in Foo->tp_dict. When calling Foo(), we go through
; Foo->ob_type->tp_call = type_call which creates instances.
align 8
global user_type_metatype
user_type_metatype:
    dq 1                        ; ob_refcnt (immortal)
    dq user_type_metatype       ; ob_type (self-referential)
    dq user_type_name_str       ; tp_name
    dq TYPE_OBJECT_SIZE         ; tp_basicsize
    dq user_type_dealloc        ; tp_dealloc — free heap types
    dq type_repr                ; tp_repr — <class 'Name'>
    dq type_repr                ; tp_str — same as repr
    dq 0                        ; tp_hash
    dq type_call                ; tp_call — calling a class creates instances
    dq type_getattr             ; tp_getattr — accessing class vars via tp_dict
    dq type_setattr             ; tp_setattr — setting class vars in tp_dict
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq type_type                ; tp_base — metatype inherits from type
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC         ; tp_flags (heaptypes are gc_alloc'd)
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear

; object_type - base type for all Python objects
; Used as explicit base class: class Foo(object): pass
; Also callable: object() returns a bare instance
align 8
global object_type
object_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq object_name_str          ; tp_name
    dq PyInstanceObject_size    ; tp_basicsize
    dq instance_dealloc         ; tp_dealloc
    dq instance_repr            ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call  (set by add_builtin_type)
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC                        ; tp_flags
    dq 0                        ; tp_bases
    dq instance_traverse                        ; tp_traverse
    dq instance_clear                        ; tp_clear

; super_type - placeholder for the 'super' builtin
; LOAD_SUPER_ATTR pops and discards this; it just needs to be loadable.
align 8
global super_type
super_type:
    dq 1                        ; ob_refcnt (immortal)
    dq super_type               ; ob_type (self-referential)
    dq super_name_str           ; tp_name
    dq TYPE_OBJECT_SIZE         ; tp_basicsize
    times 20 dq 0               ; remaining tp_* fields

; method_type - type descriptor for bound methods
align 8
global method_type
method_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq method_name_str          ; tp_name
    dq PyMethodObject_size      ; tp_basicsize
    dq method_dealloc           ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq method_call              ; tp_call
    dq method_getattr           ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC                        ; tp_flags
    dq 0                        ; tp_bases
    dq method_traverse                        ; tp_traverse
    dq method_clear                        ; tp_clear
