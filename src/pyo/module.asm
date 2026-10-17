; module.asm - Dict-backed attribute namespaces
;
; A module and a SimpleNamespace are the same object with different repr:
; a dict, and getattr/setattr that read and write it by name.
; PyModuleObject: name + dict

%include "macros.inc"
%include "object.inc"

extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern ap_free
extern obj_decref
extern obj_dealloc
extern raise_exception
extern exc_TypeError_type
extern obj_incref
extern str_from_cstr
extern str_type
extern dict_new
extern dict_get
extern dict_set
extern type_type
extern none_singleton
extern ap_strcmp
extern str_from_cstr_heap
extern obj_call_n
extern exc_AttributeError_type
extern type_is_subtype
extern eval_exception_unwind
extern dir_default
global module_dunder_dir

;; ============================================================================
;; module_new(PyObject *name_str, PyObject *dict) -> PyModuleObject*
;; Create a new module with given name and dict
;; If dict is NULL, creates a new empty dict
;;
;; module_new_of takes the TYPE as well, for a subclass of ModuleType, and
;; ecx = 0 to leave the dict EMPTY -- which is what module.__new__ hands back
;; before module.__init__ has run.  The constructor used to allocate
;; module_type unconditionally, so `class M(ModuleType)` produced a plain
;; module: type(M("x")) was `module` and isinstance(m, M) was False.
;; ============================================================================
DEF_FUNC module_new
    lea rdx, [rel module_type]
    mov ecx, 1
    leave
    jmp module_new_of
END_FUNC module_new

;; ============================================================================
;; module_new_of(rdi = name_str, rsi = dict or NULL, rdx = the type,
;;               ecx = 1 to write __name__ and __doc__) -> PyModuleObject*
;; ============================================================================
MNO_FILL  equ 8
MNO_FRAME equ 24            ; + 3 pushes = 48, 16-aligned
global module_new_of
DEF_FUNC module_new_of, MNO_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - MNO_FILL], rcx

    mov rbx, rdi                ; name_str
    mov r12, rsi                ; dict (or NULL)
    mov r13, rdx                ; the type

    ; Create dict if NULL
    test r12, r12
    jnz .have_dict
    call dict_new
    mov r12, rax
    jmp .alloc
.have_dict:
    ; INCREF the dict (module holds a reference)
    mov rdi, r12
    call obj_incref

.alloc:
    ; Allocate PyModuleObject (GC-tracked).  A subclass is wider, and gc_alloc
    ; does not zero what it hands back, so the tail past the module's own
    ; fields is cleared here -- instance_traverse walks it as Values.
    mov rdi, [r13 + PyTypeObject.tp_basicsize]
    cmp rdi, PyModuleObject_size
    jae .alloc_size_ok
    mov rdi, PyModuleObject_size
.alloc_size_ok:
    push rdi
    mov rsi, r13
    call gc_alloc
    pop rcx
    ; ob_refcnt=1, ob_type set by gc_alloc
    mov rdx, PyModuleObject_size
.alloc_zero:
    cmp rdx, rcx
    jae .alloc_zeroed
    mov qword [rax + rdx], 0
    add rdx, 8
    jmp .alloc_zero
.alloc_zeroed:

    ; INCREF name
    push rax
    mov rdi, rbx
    call obj_incref
    pop rax

    ; Fill module fields
    mov [rax + PyModuleObject.mod_name], rbx
    mov [rax + PyModuleObject.mod_dict], r12
    cmp qword [rbp - MNO_FILL], 0
    je .mn_tracked

    ; __name__ lives in the dict, not only in mod_name: module_getattr looks
    ; nowhere else, so every builtin module answered AttributeError for it --
    ; and reading a module's own __name__ is ordinary code, not introspection.
    ; CPython's module init writes it into the dict for the same reason.
    push rax
    lea rdi, [rel mod_name_key]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, rbx
    call dict_set
    pop rdi
    call obj_decref
    pop rax

    ; __doc__ = None, which is what a module without a docstring has.  It was
    ; simply absent, so reading __doc__ at module level was a NameError -- and
    ; the module body's own STORE_NAME overwrites this when there is one.
    push rax
    lea rdi, [rel mod_doc_key]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rel none_singleton]
    call dict_set
    pop rdi
    call obj_decref
    pop rax

.mn_tracked:
    push rax
    mov rdi, rax
    call gc_track
    pop rax

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC module_new_of

;; ============================================================================
;; module_dealloc(PyObject *self)
;; ============================================================================
DEF_FUNC_LOCAL module_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; XDECREF name
    mov rdi, [rbx + PyModuleObject.mod_name]
    test rdi, rdi
    jz .no_name
    call obj_decref
.no_name:
    ; XDECREF dict
    mov rdi, [rbx + PyModuleObject.mod_dict]
    test rdi, rdi
    jz .no_dict
    call obj_decref
.no_dict:
    mov rdi, rbx
    call gc_dealloc

    pop rbx
    leave
    ret
END_FUNC module_dealloc

;; ============================================================================
;; mg_getattr_name() -> rax = the str "__getattr__", borrowed, or 0
;;
;; PEP 562's hook is looked up by name on every module attribute that MISSES,
;; so the name is built once and kept rather than allocated per miss.  Borrowed
;; for the life of the interpreter, like the builtins the reduce protocol
;; caches.
;; ============================================================================
DEF_FUNC_LOCAL mg_getattr_name
    mov rax, [rel mg_name_cached]
    test rax, rax
    jnz .mgn_done
    CSTRING rdi, "__getattr__"
    call str_from_cstr_heap
    test rax, rax
    jz .mgn_done                ; 0, and the caller treats it as "no hook"
    mov [rel mg_name_cached], rax
.mgn_done:
    leave
    ret
END_FUNC mg_getattr_name

;; ============================================================================
;; mg_dir_name() -> rax = the str "__dir__", borrowed, or 0
;;
;; Built once and kept, for the same reason mg_getattr_name is.
;; ============================================================================
DEF_FUNC_LOCAL mg_dir_name
    mov rax, [rel mg_dir_cached]
    test rax, rax
    jnz .mdn_done
    CSTRING rdi, "__dir__"
    call str_from_cstr_heap
    test rax, rax
    jz .mdn_done
    mov [rel mg_dir_cached], rax
.mdn_done:
    leave
    ret
END_FUNC mg_dir_name

;; ============================================================================
;; module_dunder_dir(rdi = args Value*, rsi = nargs) -> rax = a list, as a Value
;;   args[0] = the module
;;
;; PEP 562's other half.  A module may define its own __dir__ as a plain
;; module-level function, and it lives in mod_dict -- which is the module's
;; INSTANCE namespace, not its type's -- so builtin_dir's dunder_call_1, which
;; searches the type, would never find it.  This method is what the type
;; answers with, and it does the instance-dict probe on the module's behalf.
;;
;; It has to be a real entry in module_type.tp_dict rather than an arm inside
;; dir_default: the stdlib asks `hasattr(m, "__dir__")` and CPython says True
;; for every module.  That is the "a builtin's behaviour that lives only in a
;; slot" rule, pointing the other way.
;;
;; builtin_dir sorts whatever comes back and accepts any iterable, so a
;; module's own __dir__ may answer a tuple or a generator, as CPython's may.
;; ============================================================================
MDD_HOOK  equ 8              ; the module's own __dir__, owned across the call
MDD_RES   equ 16             ; its result, parked across the release
MDD_FRAME equ 24             ; + 1 push = 40; DEF_FUNC's push rbp makes it 16-aligned
DEF_FUNC_LOCAL module_dunder_dir, MDD_FRAME
    push rbx
    mov rbx, [rdi]              ; args[0] = self

    ; Not a module -- a SimpleNamespace shares this file but not this dict --
    ; so fall through to the ordinary answer rather than reading mod_dict off
    ; whatever it is.
    V_TEST_PTR rbx, rax
    ja .mdd_default
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel module_type]
    cmp rax, rcx
    jne .mdd_default

    mov rdi, [rbx + PyModuleObject.mod_dict]
    test rdi, rdi
    jz .mdd_default
    call mg_dir_name
    test rax, rax
    jz .mdd_default
    mov rdi, [rbx + PyModuleObject.mod_dict]
    mov rsi, rax
    call dict_get               ; a Value; 0 is the miss, and it never raises
    test rax, rax
    jz .mdd_default

    ; The module's own __dir__, called with no arguments.  obj_call_n refuses a
    ; non-callable with a TypeError, which is what CPython answers too.
    ;
    ; dict_get handed back a BORROWED reference and the call runs arbitrary
    ; Python, so own it for the duration: a hook whose body is
    ; `del globals()["__dir__"]` otherwise drops the last reference to the
    ; function that is executing, and this frame goes on using freed memory.
    INCREF_V rax, rcx
    mov [rbp - MDD_HOOK], rax
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call obj_call_n
    ; Release it before returning.  The result -- or the 0 that says the hook
    ; raised -- goes to a frame slot across the DECREF, because obj_dealloc
    ; clobbers every caller-saved register, rax included.
    mov [rbp - MDD_RES], rax
    mov rdi, [rbp - MDD_HOOK]
    DECREF_V rdi, rcx
    mov rax, [rbp - MDD_RES]
    pop rbx
    leave
    ret

.mdd_default:
    mov rdi, rbx
    call dir_default
    pop rbx
    leave
    ret
END_FUNC module_dunder_dir

;; ============================================================================
;; module_getattr(PyObject *self, PyObject *name_str) -> rax = Value
;; Look up attribute in module's dict, then PEP 562's __getattr__.
;;
;; The hook runs only on a MISS, which is why it is here rather than at the
;; three call sites -- op_load_attr, obj_getattr_opt and op_import_from each
;; turn this function's 0 into an error of their own, and each would have
;; needed its own copy.
;;
;; An AttributeError out of the hook is the protocol saying "absent", and
;; getattr(m, n, default) and hasattr() have to be able to see that; anything
;; else is a genuine failure in the middle of a lookup and keeps unwinding.
;; That is the same handshake instance_getattr's .getattr_raised uses, down to
;; the attr_error_pending flag raise_no_attribute reads.
;; ============================================================================
MG_HOOK   equ 8              ; the module's own __getattr__, owned across the call
MG_NAME   equ 16             ; the attribute name, as the hook's one argument
MG_FRAME  equ 32             ; + 2 pushes = 48, 16-aligned
DEF_FUNC module_getattr, MG_FRAME
    push rbx
    push r12
    mov rbx, rdi                ; self
    mov r12, rsi                ; save name_str

    ; Check for __dict__ special attribute
    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel ma_dunder_dict]
    call ap_strcmp
    test eax, eax
    jnz .normal_lookup

    ; Return the module's dict directly (always a heap object)
    mov rax, [rbx + PyModuleObject.mod_dict]
    test rax, rax
    jz .not_found
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.normal_lookup:
    ; dict_get(mod_dict, name_str)
    mov rdi, [rbx + PyModuleObject.mod_dict]
    test rdi, rdi
    jz .not_found
    mov rsi, r12
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value

    ; INCREF if found (dict_get returns borrowed ref)
    test edx, edx
    jz .not_found
    INCREF_VAL rax, rdx         ; tag-aware: skip for SmallInt
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.not_found:
    ; PEP 562.  The module's own __getattr__, if it has one, answers the miss.
    mov rdi, [rbx + PyModuleObject.mod_dict]
    test rdi, rdi
    jz .mg_really_not_found

    ; Never on the hook's own name: looking __getattr__ up in the dict and
    ; missing must not ask the hook for itself.
    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel mg_dunder_getattr]
    call ap_strcmp
    test eax, eax
    jz .mg_really_not_found

    call mg_getattr_name
    test rax, rax
    jz .mg_really_not_found
    mov rdi, [rbx + PyModuleObject.mod_dict]
    mov rsi, rax
    call dict_get               ; a Value; 0 is the miss, and it never raises
    test rax, rax
    jz .mg_really_not_found

    ; The hook, called with the attribute name.  obj_call_n returns rather
    ; than unwinding, and refuses a non-callable with a TypeError of its own --
    ; which is CPython's answer for `m.__getattr__ = 5` too, so it is left to
    ; do that.
    ;
    ; dict_get handed back a BORROWED reference, and the call runs arbitrary
    ; Python -- which may unbind the hook.  A body of
    ; `del globals()["__getattr__"]` then drops the last reference to the
    ; function that is currently executing, and every instruction after the
    ; call reads freed memory.  So own it for the duration.  CPython's own
    ; Lib/test/test_module/bad_getattr3.py is exactly this, and its comment is
    ; "these lookups should not crash".
    INCREF_V rax, rcx
    mov [rbp - MG_HOOK], rax
    mov [rbp - MG_NAME], r12    ; the one-Value argument array
    mov rdi, rax
    lea rsi, [rbp - MG_NAME]
    mov edx, 1
    call obj_call_n
    ; Release it here, before anything branches: the hook is finished with,
    ; and one release point on the straight line is worth four on the exits --
    ; the unwind tail below abandons this frame into eval_exception_unwind and
    ; would be the easy one to forget.  The result, or the 0 that says the
    ; hook raised, goes to a frame slot across the DECREF, because obj_dealloc
    ; clobbers every caller-saved register, rax included.
    mov [rbp - MG_NAME], rax
    mov rdi, [rbp - MG_HOOK]
    DECREF_V rdi, rcx
    mov rax, [rbp - MG_NAME]
    test rax, rax
    jz .mg_hook_raised
    pop r12
    pop rbx
    leave
    ret                         ; already a Value, and owned

.mg_hook_raised:
    ; An AttributeError is "absent" and has to reach getattr()'s default and
    ; hasattr(); raise_no_attribute reads attr_error_pending and propagates
    ; this one rather than replacing it, so `m.missing` still reports what the
    ; hook said.  Anything else keeps unwinding.
    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jz .mg_really_not_found
    mov rdi, [rax + PyObject.ob_type]
    lea rsi, [rel exc_AttributeError_type]
    call type_is_subtype
    test eax, eax
    jz .mg_hook_unwind
    mov qword [gs:ThreadState.attr_error_pending], 1
    RET_NULL
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.mg_hook_unwind:
    pop r12
    pop rbx
    leave
    jmp eval_exception_unwind

.mg_really_not_found:
    RET_NULL
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC module_getattr

;; ============================================================================
;; module_setattr(PyObject *self, PyObject *name_str, PyObject *value) -> int
;; Set attribute in module's dict
;; ============================================================================
DEF_FUNC module_setattr
    ; A NULL value is tp_setattr's DELETE convention -- the same one
    ; dict_ass_subscript honours by routing to dict_del.  This handed it to
    ; dict_set, which stored the NULL and kept the key, so `del mod.x` left
    ; the entry findable with a NULL value.  Two things followed: dk_version
    ; did not move, because a dict's keys version tracks the KEY SET and
    ; overwriting a value is not a change to it, so every LOAD_GLOBAL_BUILTIN
    ; inline cache guarding on it stayed valid; and when a cache did notice
    ; the NULL and deopt, op_load_global looked the name up again, FOUND it,
    ; re-specialized, and pushed the NULL.  A NULL Value on the value stack is
    ; not an error anything notices -- it propagates until something
    ; dereferences it.
    mov rax, rdi                ; self
    test rdx, rdx
    jz .ms_delete
    mov rdi, [rax + PyModuleObject.mod_dict]
    ; rsi = name_str and rdx = value are both already Values
    call dict_set
    xor eax, eax               ; return 0 (success)
    leave
    ret

.ms_delete:
    push rax                    ; the module, for the error message
    push rsi                    ; the name, likewise
    mov rdi, [rax + PyModuleObject.mod_dict]
    extern dict_del_opt
    call dict_del_opt           ; -1 when the name was never there
    pop rsi
    pop rdi
    test eax, eax
    js .ms_missing
    xor eax, eax               ; return 0 (success)
    leave
    ret

.ms_missing:
    ; CPython raises AttributeError naming the module, exactly as a failed
    ; READ of the same name does.  Storing a NULL under a fresh key, which is
    ; what this used to do, invented an entry instead.
    xor edx, edx
    extern raise_no_attribute
    call raise_no_attribute     ; does not return
END_FUNC module_setattr

;; ============================================================================
;; module_repr(PyObject *self) -> PyObject*
;;
;; "<module 'sys' (built-in)>" for a module with no __file__, and
;; "<module 'x' from '/path'>" for one that has it.  This used to answer the
;; bare name, which reads as a string rather than a module and is the one
;; repr in the tree that did not even have angle brackets.
;;
;; Note that __file__ here is the .pyc a module was loaded from, where
;; CPython's is the .py -- a difference in that attribute, not in this.
;; ============================================================================
MR_FILE  equ 8
MR_BUILTIN equ 16       ; is this name in builtin_module_table?
MR_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC module_repr, MR_FRAME
    push rbx
    mov rbx, rdi
    mov qword [rbp - MR_FILE], 0

    extern obj_repr_buf
    extern obj_repr_buf_str
    extern rbt_append_cstr

    ; __file__ out of the module dict, when it is a str.
    mov rax, [rbx + PyModuleObject.mod_dict]
    test rax, rax
    jz .mr_no_file
    mov rdi, rax
    lea rdi, [rel mod_file_key]
    call str_from_cstr
    push rax
    mov rdi, [rbx + PyModuleObject.mod_dict]
    mov rsi, rax
    extern dict_get
    call dict_get
    pop rdi
    push rax
    call obj_decref
    pop rax
    test rax, rax
    jz .mr_no_file
    V_UNPACK rax, rdx
    cmp edx, TAG_PTR
    jne .mr_no_file
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .mr_no_file
    mov [rbp - MR_FILE], rax
.mr_no_file:

    ; "(built-in)" is for a module that really is one.  The decision used to
    ; be __file__ alone, so anything without one -- types.ModuleType('x'), and
    ; every module a test builds by hand -- claimed to be built-in.  CPython
    ; asks __spec__ first and says plain `<module 'x'>` for a module that is
    ; neither built-in nor loaded from a file.
    ;
    ; __spec__ cannot answer here: it is None or absent on every module in
    ; this tree.  builtin_module_table can, exactly -- it is the list
    ; sys.builtin_module_names is built from, so "is this name in it" IS the
    ; question "is this module built-in".
    mov qword [rbp - MR_BUILTIN], 0
    mov rsi, [rbx + PyModuleObject.mod_name]
    test rsi, rsi
    jz .mr_not_builtin
    lea rsi, [rsi + PyStrObject.data]
    extern builtin_module_table
    extern builtin_module_count
    lea r8, [rel builtin_module_table]
    mov r9, [rel builtin_module_count]
.mr_bm_loop:
    test r9, r9
    jz .mr_not_builtin
    mov rdi, [r8]                   ; the row's name, a C string
    push r8
    push r9
    push rsi
    call ap_strcmp
    pop rsi
    pop r9
    pop r8
    test eax, eax
    jz .mr_is_builtin
    add r8, BuiltinModule_size
    dec r9
    jmp .mr_bm_loop
.mr_is_builtin:
    mov qword [rbp - MR_BUILTIN], 1
.mr_not_builtin:

    lea rdi, [rel mod_repr_open]
    call obj_repr_buf
    mov rdi, rax
    mov rsi, [rbx + PyModuleObject.mod_name]
    test rsi, rsi
    jz .mr_unnamed
    lea rsi, [rsi + PyStrObject.data]
    jmp .mr_have_name
.mr_unnamed:
    lea rsi, [rel mod_repr_unknown]
.mr_have_name:
    call rbt_append_cstr
    mov rdi, rax
    cmp qword [rbp - MR_FILE], 0
    jne .mr_from
    cmp qword [rbp - MR_BUILTIN], 0
    je .mr_plain
    lea rsi, [rel mod_repr_builtin]
    call rbt_append_cstr
    jmp .mr_done
.mr_plain:
    lea rsi, [rel mod_repr_plain]
    call rbt_append_cstr
    jmp .mr_done
.mr_from:
    ; A path has no length limit, and the shared buffer's pieces stop at
    ; eighty characters -- a project a few directories deep printed its
    ; module as "...src/pk'>".  So this form is assembled from strings:
    ; CPython's "<module %R from %R>", the repr of the name and of the path.
    mov rdi, rbx
    mov rsi, [rbp - MR_FILE]
    call module_repr_from
    pop rbx
    leave
    ret
.mr_done:
    call obj_repr_buf_str
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
END_FUNC module_repr

;; ============================================================================
;; module_repr_from(rdi = a module, rsi = its __file__ str)
;;   -> rax = "<module 'name' from '/path'>", edx = TAG_PTR
;; ============================================================================
MRF_MOD   equ 8
MRF_FILE  equ 16
MRF_ACC   equ 24                ; the string so far
MRF_FRAME equ 32
DEF_FUNC_LOCAL module_repr_from, MRF_FRAME
    mov [rbp - MRF_MOD], rdi
    mov [rbp - MRF_FILE], rsi
    lea rdi, [rel mod_repr_open_r]
    call str_from_cstr_heap
    mov [rbp - MRF_ACC], rax
    mov rax, [rbp - MRF_MOD]
    mov rdi, [rax + PyModuleObject.mod_name]
    test rdi, rdi
    jnz .mrf_named
    lea rdi, [rel mod_repr_unknown]
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    mov rdi, rax
    call obj_repr
    add rsp, 8
    pop rdi
    push rax
    sub rsp, 8
    call obj_decref
    add rsp, 8
    pop rax
    jmp .mrf_add_name
.mrf_named:
    call obj_repr
.mrf_add_name:
    mov rdi, [rbp - MRF_ACC]
    mov rsi, rax
    call mrf_append
    mov [rbp - MRF_ACC], rax
    lea rdi, [rel mod_repr_from_r]
    call str_from_cstr_heap
    mov rdi, [rbp - MRF_ACC]
    mov rsi, rax
    call mrf_append
    mov [rbp - MRF_ACC], rax
    mov rdi, [rbp - MRF_FILE]
    call obj_repr
    mov rdi, [rbp - MRF_ACC]
    mov rsi, rax
    call mrf_append
    mov [rbp - MRF_ACC], rax
    lea rdi, [rel mod_repr_close_r]
    call str_from_cstr_heap
    mov rdi, [rbp - MRF_ACC]
    mov rsi, rax
    call mrf_append
    mov edx, TAG_PTR
    leave
    ret
END_FUNC module_repr_from

;; ============================================================================
;; mrf_append(rdi = a str, owned, rsi = a str, owned) -> rax = the two
;;   concatenated; both references released
;; ============================================================================
MRA_A     equ 8
MRA_B     equ 16
MRA_FRAME equ 16
DEF_FUNC_LOCAL mrf_append, MRA_FRAME
    mov [rbp - MRA_A], rdi
    mov [rbp - MRA_B], rsi
    mov ecx, TAG_PTR
    extern str_concat
    call str_concat
    push rax
    sub rsp, 8
    mov rdi, [rbp - MRA_A]
    call obj_decref
    mov rdi, [rbp - MRA_B]
    call obj_decref
    add rsp, 8
    pop rax
    leave
    ret
END_FUNC mrf_append

;; ============================================================================
;; Data
;; ============================================================================
section .rodata

mod_name_key: db "__name__", 0
mod_doc_key: db "__doc__", 0
mod_file_key: db "__file__", 0
mod_repr_open:    db "<module '", 0
mod_repr_unknown: db "?", 0
mod_repr_builtin: db "' (built-in)>", 0
mod_repr_plain:   db "'>", 0
mod_repr_from:    db "' from '", 0
mod_repr_open_r:  db "<module ", 0
mod_repr_from_r:  db " from ", 0
mod_repr_close_r: db ">", 0
mod_repr_close:   db "'>", 0
module_type_name: db "module", 0
ma_dunder_dict: db "__dict__", 0
mg_dunder_getattr: db "__getattr__", 0

section .data
align 8
global module_type


module_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq module_type_name         ; tp_name
    dq PyModuleObject_size      ; tp_basicsize
    dq module_dealloc           ; tp_dealloc
    dq module_repr              ; tp_repr
    dq module_repr              ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq module_getattr           ; tp_getattr
    dq module_setattr           ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq module_type_new          ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC | TYPE_FLAG_BASETYPE   ; tp_flags
    dq 0                        ; tp_bases
    dq module_traverse                        ; tp_traverse
    dq module_clear_gc                        ; tp_clear
    ; A module's own dict IS its __dict__, which is what makes `self.x = 1`
    ; work on a ModuleType subclass -- CPython's PyModule_Type says the same
    ; thing with offsetof(PyModuleObject, md_dict).
    dq PyModuleObject.mod_dict  ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

;; ============================================================================
;; (was src/pyo/namespace.asm)
;; ============================================================================

section .text

extern ap_malloc
extern ap_free
extern obj_incref
extern obj_decref
extern dict_new
extern dict_get
extern dict_set
extern dict_type
extern str_type
extern str_from_cstr
extern str_from_cstr_heap
extern str_new_heap
extern obj_repr
extern type_type
extern raise_exception
extern exc_TypeError_type

section .text

;; ============================================================================
;; namespace_alloc(rdi = the type to build) -> rax = the object, or 0
;;
;; builtin_sub_alloc rather than a bare ap_malloc, because the type is not
;; always THIS one: `class Sub(SimpleNamespace)` is a heaptype, its
;; tp_basicsize is larger and it is collector-tracked, so its instances come
;; from gc_alloc with a header sixteen bytes below the object.  It also counts
;; the type, which namespace_dealloc gives back.
;; ============================================================================
extern builtin_sub_alloc
DEF_FUNC_LOCAL namespace_alloc, 8            ; 1 push = 16, 16-aligned
    push rbx
    call builtin_sub_alloc
    test rax, rax
    jz .nsa_out
    mov rbx, rax
    call dict_new
    test rax, rax
    jz .nsa_no_dict
    mov [rbx + PySimpleNamespaceObject.ns_dict], rax
    mov rax, rbx
.nsa_out:
    pop rbx
    leave
    ret
.nsa_no_dict:
    mov rdi, rbx
    call obj_decref
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC namespace_alloc

;; ============================================================================
;; namespace_new() -> PySimpleNamespaceObject* with a fresh dict
;; ============================================================================
DEF_FUNC namespace_new, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    lea rdi, [rel namespace_type]
    call namespace_alloc
    pop rbx
    leave
    ret
END_FUNC namespace_new

;; ============================================================================
;; namespace_type_call(rdi = type, rsi = args, rdx = nargs) -> rax = Value
;;
;; types.SimpleNamespace(**kwargs).  There was no tp_new at all, so calling the
;; type fell through to the ordinary class-construction path: the object came
;; from instance_new with no ns_dict -- "namespace has no attribute storage" on
;; the first assignment -- and was then freed at the object pointer by
;; namespace_dealloc, sixteen bytes above the block gc_alloc had handed out.
;;
;; CPython takes keywords only, and says so.
;; ============================================================================
NTC_TYPE  equ 8
NTC_NS    equ 16
NTC_ARGS  equ 24
NTC_NARGS equ 32
NTC_KW    equ 40
NTC_I     equ 48
NTC_FRAME equ 64            ; + 0 pushes = 64, 16-aligned
DEF_FUNC namespace_type_call, NTC_FRAME
    mov [rbp - NTC_TYPE], rdi
    mov [rbp - NTC_ARGS], rsi
    mov [rbp - NTC_NARGS], rdx

    ; The keywords, taken now: a tp_new is expected to consume them, and
    ; type_call hands __init__ its own saved copy.
    mov rax, [gs:ThreadState.kw_names_pending]
    mov [rbp - NTC_KW], rax
    mov qword [gs:ThreadState.kw_names_pending], 0
    xor ecx, ecx
    test rax, rax
    jz .ntc_no_kw
    mov rcx, [rax + PyTupleObject.ob_size]
.ntc_no_kw:
    ; nargs counts the keyword VALUES too; whatever is left is positional.
    mov rdx, [rbp - NTC_NARGS]
    sub rdx, rcx
    test rdx, rdx
    jnz .ntc_positional

    mov rdi, [rbp - NTC_TYPE]
    call namespace_alloc
    test rax, rax
    jz .ntc_fail
    mov [rbp - NTC_NS], rax

    ; Every keyword becomes an attribute.  With no positionals the values
    ; start at args[0], in the order the names are in.
    mov qword [rbp - NTC_I], 0
.ntc_kw_loop:
    mov rax, [rbp - NTC_KW]
    test rax, rax
    jz .ntc_done
    mov rcx, [rbp - NTC_I]
    cmp rcx, [rax + PyTupleObject.ob_size]
    jge .ntc_done
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rsi, [rdx + rcx*8]                  ; the name
    mov rdx, [rbp - NTC_ARGS]
    mov rdx, [rdx + rcx*8]                  ; the value
    mov rdi, [rbp - NTC_NS]
    mov rdi, [rdi + PySimpleNamespaceObject.ns_dict]
    call dict_set
    inc qword [rbp - NTC_I]
    jmp .ntc_kw_loop

.ntc_done:
    mov rax, [rbp - NTC_NS]
    mov edx, TAG_PTR
    leave
    ret

.ntc_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret

.ntc_positional:
    RAISE exc_TypeError_type, "no positional arguments expected"
END_FUNC namespace_type_call

;; namespace_set(rdi = ns, rsi = name cstr, rdx = value Value)
;; Helper for building one from assembly; steals nothing, INCREFs via dict_set.
DEF_FUNC namespace_set
    push rbx
    push r12
    mov rbx, [rdi + PySimpleNamespaceObject.ns_dict]
    mov r12, rdx
    mov rdi, rsi
    call str_from_cstr_heap
    push rax
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r12
    call dict_set
    pop rdi
    call obj_decref
    pop r12
    pop rbx
    leave
    ret
END_FUNC namespace_set

NSD_TYPE  equ 8
NSD_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC_LOCAL namespace_dealloc, NSD_FRAME
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PySimpleNamespaceObject.ns_dict]
    test rdi, rdi
    jz .nsd_free
    call obj_decref
.nsd_free:
    ; gc_dealloc, not ap_free: a SUBCLASS of this type is a heaptype and is
    ; collector-tracked, so its block starts sixteen bytes below the object.
    ; And the reference namespace_alloc took on the type goes back, after the
    ; object is gone -- gc_dealloc reads ob_type on its way past.
    mov rax, [rbx + PyObject.ob_type]
    mov [rbp - NSD_TYPE], rax
    mov rdi, rbx
    call gc_dealloc
    mov rdi, [rbp - NSD_TYPE]
    call obj_decref
    pop rbx
    leave
    ret
END_FUNC namespace_dealloc

;; namespace_getattr(rdi = self, rsi = name) -> Value or NULL
NSG_NAME  equ 8
NSG_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC namespace_getattr, NSG_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - NSG_NAME], rsi
    cmp qword [rdi + PySimpleNamespaceObject.ns_dict], 0
    je .nsg_none

    ; __dict__ IS the storage, and writing through it is how CPython lets a
    ; caller add attributes in bulk.  vars(ns) asks the same question.
    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "__dict__"
    call ap_strcmp
    test eax, eax
    jnz .nsg_lookup
    mov rax, [rbx + PySimpleNamespaceObject.ns_dict]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.nsg_lookup:
    mov rdi, [rbx + PySimpleNamespaceObject.ns_dict]
    mov rsi, [rbp - NSG_NAME]
    call dict_get
    V_UNPACK rax, rdx
    test edx, edx
    jz .nsg_none
    INCREF_VAL rax, rdx
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.nsg_none:
    ; Not here: LOAD_ATTR's shared tail still gets a chance at __class__,
    ; so returning NULL is the right answer.
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    V_PACK rax, rdx
    ret
END_FUNC namespace_getattr

;; namespace_setattr(rdi = self, rsi = name, rdx = value Value) -> 0
NSS_SELF  equ 8
NSS_NAME  equ 16
NSS_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC namespace_setattr, NSS_FRAME
    mov [rbp - NSS_SELF], rdi
    mov [rbp - NSS_NAME], rsi
    mov rdi, [rdi + PySimpleNamespaceObject.ns_dict]
    test rdi, rdi
    jz .nss_no_dict
    ; A NULL value is a DELETE -- that is tp_setattr's convention, and this
    ; stored the NULL instead, leaving an entry whose value was nothing.
    ; `del ns.a` then showed as `a=` in the repr and read back as garbage.
    test rdx, rdx
    jz .nss_delete
    call dict_set
    xor eax, eax
    leave
    ret

.nss_delete:
    extern dict_del_opt
    call dict_del_opt
    test eax, eax
    js .nss_missing
    xor eax, eax
    leave
    ret

.nss_missing:
    mov rdi, [rbp - NSS_SELF]
    mov rsi, [rbp - NSS_NAME]
    xor edx, edx
    extern raise_no_attribute
    call raise_no_attribute     ; does not return

.nss_no_dict:
    RAISE exc_TypeError_type, "namespace has no attribute storage"
END_FUNC namespace_setattr

;; namespace_repr(rdi = self) -> str   "namespace(a=1, b=2)"
NR_SELF  equ 8
NR_DICT  equ 16
NR_IDX   equ 24
NR_COUNT equ 32
NR_CAP   equ 40
NR_BUF   equ 1080        ; 1024 bytes, [rbp-1080, rbp-56)
NR_FRAME equ 1088           ; + 2 pushes = 1104
DEF_FUNC namespace_repr, NR_FRAME
    push rbx
    push r13
    mov [rbp - NR_SELF], rdi
    mov qword [rbp - NR_IDX], 0
    mov qword [rbp - NR_COUNT], 0

    ; A namespace can hold itself, and this walked into it for ever.  The
    ; recursion stack the container reprs share is what stops it, and CPython
    ; prints the same marker whatever the type is called.
    extern repr_check_active
    extern repr_push
    extern repr_pop
    call repr_check_active
    test eax, eax
    jnz .nr_recursive
    mov rdi, [rbp - NR_SELF]
    call repr_push

    lea rbx, [rbp - NR_BUF]
    xor r13d, r13d
    ; A SUBCLASS reprs under its own name -- `Sub(q=9)` -- while this type
    ; itself is spelled "namespace" and not by its tp_name, which is
    ; "types.SimpleNamespace".
    mov rax, [rbp - NR_SELF]
    mov rax, [rax + PyObject.ob_type]
    lea rcx, [rel namespace_type]
    cmp rax, rcx
    je .nr_own_name
    mov rsi, [rax + PyTypeObject.tp_name]
    jmp .nr_prefix
.nr_own_name:
    CSTRING rsi, "namespace"
.nr_prefix:
    movzx eax, byte [rsi]
    test al, al
    jz .nr_open_paren
    inc rsi
    mov [rbx + r13], al
    inc r13
    jmp .nr_prefix
.nr_open_paren:
    mov byte [rbx + r13], '('
    inc r13
    jmp .nr_setup

.nr_recursive:
    lea rdi, [rel nr_recursive_str]
    extern str_from_cstr_heap
    call str_from_cstr_heap
    mov edx, TAG_PTR
    pop r13
    pop rbx
    leave
    ret

.nr_setup:
    mov rax, [rbp - NR_SELF]
    mov rax, [rax + PySimpleNamespaceObject.ns_dict]
    test rax, rax
    jz .nr_close
    mov [rbp - NR_DICT], rax
    mov rcx, [rax + PyDictObject.capacity]
    mov [rbp - NR_CAP], rcx

.nr_scan:
    mov rcx, [rbp - NR_IDX]
    cmp rcx, [rbp - NR_CAP]
    jge .nr_close
    mov rax, [rbp - NR_DICT]
    mov rax, [rax + PyDictObject.entries]
    imul rdx, rcx, DICT_ENTRY_SIZE
    mov rsi, [rax + rdx + DictEntry.key]
    test rsi, rsi
    jz .nr_next
    cmp r13, NR_BUF - 64
    jae .nr_close

    ; ", " between items
    cmp qword [rbp - NR_COUNT], 0
    je .nr_no_sep
    mov byte [rbx + r13], ','
    mov byte [rbx + r13 + 1], ' '
    add r13, 2
.nr_no_sep:
    inc qword [rbp - NR_COUNT]

    ; key -- always a str here
    mov r8, [rsi + PyStrObject.ob_size]
    lea rsi, [rsi + PyStrObject.data]
    xor ecx, ecx
.nr_key:
    cmp rcx, r8
    jge .nr_key_done
    cmp r13, NR_BUF - 40
    jae .nr_key_done
    movzx eax, byte [rsi + rcx]
    mov [rbx + r13], al
    inc r13
    inc rcx
    jmp .nr_key
.nr_key_done:
    mov byte [rbx + r13], '='
    inc r13

    ; = repr(value)
    mov rax, [rbp - NR_DICT]
    mov rax, [rax + PyDictObject.entries]
    mov rcx, [rbp - NR_IDX]
    imul rdx, rcx, DICT_ENTRY_SIZE
    mov rdi, [rax + rdx + DictEntry.value]
    call obj_repr
    V_UNPACK rax, rdx
    test rax, rax
    jz .nr_next
    mov r8, [rax + PyStrObject.ob_size]
    lea rsi, [rax + PyStrObject.data]
    xor ecx, ecx
.nr_val:
    cmp rcx, r8
    jge .nr_val_done
    cmp r13, NR_BUF - 8
    jae .nr_val_done
    movzx edx, byte [rsi + rcx]
    mov [rbx + r13], dl
    inc r13
    inc rcx
    jmp .nr_val
.nr_val_done:
    mov rdi, rax
    call obj_decref

.nr_next:
    inc qword [rbp - NR_IDX]
    jmp .nr_scan

.nr_close:
    mov byte [rbx + r13], ')'
    inc r13
    call repr_pop
    mov rdi, rbx
    mov rsi, r13
    call str_new_heap
    mov edx, TAG_PTR
    pop r13
    pop rbx
    leave
    ret
END_FUNC namespace_repr

section .rodata
nr_recursive_str: db "namespace(...)", 0
section .text

;; ============================================================================
;; namespace_richcompare(rdi = left Value, rsi = right Value, edx = op,
;;                       rcx = left tag, r8 = right tag)
;;   -> rax = Value (True/False), or NULL for NotImplemented
;;
;; Two namespaces are equal when their contents are, which is what makes
;; SimpleNamespace usable as a record.  There was no tp_richcompare at all, so
;; `SN(x=1) == SN(x=1)` fell through to identity and answered False.  CPython
;; requires BOTH to be namespaces -- a subclass counts -- and then asks the
;; two dicts.
;; ============================================================================
extern type_is_subtype
extern dict_richcompare
NRC_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC namespace_richcompare, NRC_FRAME
    V_UNPACK rdi, rcx
    V_UNPACK rsi, r8
    cmp edx, 2                  ; PY_EQ
    je .nrc_op_ok
    cmp edx, 3                  ; PY_NE
    jne .nrc_notimpl
.nrc_op_ok:
    cmp r8d, TAG_PTR
    jne .nrc_notimpl
    test rsi, rsi
    jz .nrc_notimpl

    push rdi
    push rsi
    push rdx
    push rdx                    ; and a pad: the call below stays aligned
    mov rdi, [rsi + PyObject.ob_type]
    lea rsi, [rel namespace_type]
    call type_is_subtype
    pop rdx
    pop rdx
    pop rsi
    pop rdi
    test eax, eax
    jz .nrc_notimpl

    mov rdi, [rdi + PySimpleNamespaceObject.ns_dict]
    mov rsi, [rsi + PySimpleNamespaceObject.ns_dict]
    mov ecx, TAG_PTR
    mov r8d, TAG_PTR
    leave
    jmp dict_richcompare        ; a pointer is its own Value

.nrc_notimpl:
    RET_NULL
    leave
    ret
END_FUNC namespace_richcompare

section .data

align 8
ns_name_str: db "types.SimpleNamespace", 0

align 8
global namespace_type
namespace_type:
    dq 1                            ; ob_refcnt (immortal)
    dq type_type                    ; ob_type
    dq ns_name_str                  ; tp_name
    dq PySimpleNamespaceObject_size ; tp_basicsize
    dq namespace_dealloc            ; tp_dealloc
    dq namespace_repr               ; tp_repr
    dq namespace_repr               ; tp_str
    dq 0                            ; tp_hash
    dq 0                            ; tp_call
    dq namespace_getattr            ; tp_getattr
    dq namespace_setattr            ; tp_setattr
    dq namespace_richcompare        ; tp_richcompare
    dq 0                            ; tp_iter
    dq 0                            ; tp_iternext
    dq 0                            ; tp_init
    dq namespace_type_call          ; tp_new  (constructor)
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
    ; ns_dict IS the instance dict, and saying so is what lets the generic
    ; machinery find it: object.__getstate__ reads tp_dictoffset, so with a
    ; zero here `copy.copy(SimpleNamespace(a=1))` answered `namespace()` --
    ; a namespace with every attribute silently dropped.  CPython reports 16
    ; for the same field.
    dq PySimpleNamespaceObject.ns_dict  ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

section .text

;; ============================================================================
;; GC traverse and clear.  These lived in gc.asm, which left the collector
;; holding the reference graph of every type in the system; a type's own
;; file is the only place that knows which of its fields are owned.
;; ============================================================================

;; ============================================================================
;; ---- module_traverse / module_clear ----
;; ============================================================================
DEF_FUNC module_traverse, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyModuleObject.mod_dict]
    VISIT_PTR rdi
    mov rdi, [rbx + PyModuleObject.mod_name]
    VISIT_PTR rdi

    pop rbx
    leave
    ret
END_FUNC module_traverse

DEF_FUNC module_clear_gc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyModuleObject.mod_dict]
    mov qword [rbx + PyModuleObject.mod_dict], 0
    test rdi, rdi
    jz .done
    call obj_decref
.done:
    pop rbx
    leave
    ret
END_FUNC module_clear_gc

section .text


;; MTN_SET_NONE key -- one dict entry bound to None, on the module in MTN_MOD.
%macro MTN_SET_NONE 1
    lea rdi, [rel %1]
    call str_from_cstr_heap
    push rax
    push rax                    ; pad
    mov rcx, [rbp - MTN_MOD]
    mov rdi, [rcx + PyModuleObject.mod_dict]
    mov rsi, rax
    lea rdx, [rel none_singleton]
    call dict_set
    pop rdi
    pop rdi
    call obj_decref
%endmacro

;; ============================================================================
;; module_type_new(rdi = type, rsi = args, rdx = nargs)
;;   -> fat (rax = the new module, rdx = TAG_PTR); raises and does not return
;;      on a bad argument
;;
;; `types.ModuleType(name[, doc])`.  module_type had no tp_new and no tp_init,
;; so type_call fell through to instance_new, which allocated
;; PyModuleObject_size bytes and handed back a module whose mod_name and
;; mod_dict were whatever the allocator left -- before the arity check refused
;; the arguments and reported "module() takes no arguments".  A constructor
;; belongs in tp_new, which is what type_call consults; tp_call on a type is
;; what makes that type's INSTANCES callable.  mappingproxy hit the same
;; pattern.
;;
;; module_new already writes __name__ and __doc__ = None into the dict, so the
;; only extra work is the optional doc.
;; ============================================================================
MTN_MOD   equ 8
MTN_TYPE  equ 16
MTN_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC module_type_new, MTN_FRAME
    mov [rbp - MTN_TYPE], rdi
    cmp rdx, 1
    jl .mtn_arity
    cmp rdx, 2
    jg .mtn_arity
    push rdx                    ; nargs
    push rsi                    ; args

    mov rdi, [rsi]              ; args[0], the name, as a Value
    V_TEST_PTR rdi, rax
    ja .mtn_bad_name
    test rdi, rdi
    jz .mtn_bad_name
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .mtn_bad_name

    mov rdx, [rbp - MTN_TYPE]   ; the class that was called, not module_type
    xor esi, esi                ; a dict of its own
    mov ecx, 1
    extern module_new_of
    call module_new_of
    mov [rbp - MTN_MOD], rax

    pop rsi
    pop rdx
    cmp rdx, 2
    jne .mtn_done

    ; The docstring, over the None module_new left there.
    mov rcx, [rsi + 8]          ; args[1]
    mov rax, [rbp - MTN_MOD]
    mov rdi, [rax + PyModuleObject.mod_dict]
    push rcx
    push rcx                    ; pad
    lea rdi, [rel mod_doc_key]
    call str_from_cstr_heap
    pop rcx
    pop rcx
    mov rsi, rax
    push rax
    push rax                    ; pad
    mov rax, [rbp - MTN_MOD]
    mov rdi, [rax + PyModuleObject.mod_dict]
    mov rdx, rcx
    call dict_set
    pop rdi
    pop rdi
    call obj_decref

.mtn_done:
    ; CPython's module.__init__ leaves these three in the dict as None, and
    ; sorted(m.__dict__) is how a test notices they are missing.  A module the
    ; import system builds gets real ones written over these.
    MTN_SET_NONE mtn_loader_key
    MTN_SET_NONE mtn_package_key
    MTN_SET_NONE mtn_spec_key
    mov rax, [rbp - MTN_MOD]
    mov edx, TAG_PTR
    leave
    ret

.mtn_bad_name:
    add rsp, 16
    RAISE exc_TypeError_type, "module.__init__() argument 1 must be str, not None"
.mtn_arity:
    CSTRING rdi, "module() takes at most 2 arguments ("
    mov rsi, rdx
    CSTRING rdx, " given)"
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC module_type_new

;; MMI_SET key_cstr, value -- write one entry into the module being
;; initialised.  rdi (args) and rsi (nargs) are preserved across it.
%macro MMI_SET 2
    mov rax, %2
    push rsi
    push rdi
    push rax
    push rax                    ; pad
    lea rdi, [rel %1]
    call str_from_cstr_heap
    pop rdx
    pop rdx                     ; the value again
    push rax
    push rax                    ; pad
    mov rcx, [rbp - MMI_SELF]
    mov rdi, [rcx + PyModuleObject.mod_dict]
    mov rsi, rax
    call dict_set
    pop rdi
    pop rdi
    call obj_decref
    pop rdi
    pop rsi
%endmacro

%macro MMI_SET_NONE 1
    push rsi
    push rdi
    lea rdi, [rel %1]
    call str_from_cstr_heap
    push rax
    push rax                    ; pad
    mov rcx, [rbp - MMI_SELF]
    mov rdi, [rcx + PyModuleObject.mod_dict]
    mov rsi, rax
    lea rdx, [rel none_singleton]
    call dict_set
    pop rdi
    pop rdi
    call obj_decref
    pop rdi
    pop rsi
%endmacro


;; ============================================================================
;; module_method_new(rdi = args, rsi = nargs) -> a Value
;;
;; `module.__new__(cls, *args)`.  CPython's is PyType_GenericNew: it allocates
;; and nothing more, and module.__init__ is what writes the name.  The split
;; matters because a ModuleType subclass is written that way --
;;
;;     class M(ModuleType):
;;         def __init__(self, name):
;;             super().__init__(name)
;;
;; -- and with neither name in module's tp_dict, `super().__init__` resolved
;; to object's and raised, while `super().__new__` hit the object.__new__
;; gate.  module_type had no tp_dict at all.
;; ============================================================================
MMN_TYPE  equ 8
MMN_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC module_method_new, MMN_FRAME
    test rsi, rsi
    jle .mmn_no_args
    mov rdi, [rdi]              ; args[0], the class
    V_TEST_PTR rdi, rax
    ja .mmn_not_a_type
    test rdi, rdi
    jz .mmn_not_a_type
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .mmn_not_a_type
    mov [rbp - MMN_TYPE], rdi
    lea rsi, [rel module_type]
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jz .mmn_not_a_module

    ; An empty name rather than a NULL one: module_repr and module_dealloc
    ; both read the field, and __init__ overwrites it a moment later.
    lea rdi, [rel mod_empty_name]
    call str_from_cstr_heap
    push rax
    mov rdi, rax
    xor esi, esi                ; a dict of its own
    mov rdx, [rbp - MMN_TYPE]
    xor ecx, ecx                ; and an EMPTY one, as CPython's is
    call module_new_of
    pop rdi
    push rax
    call obj_decref             ; the module holds the name now
    pop rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.mmn_no_args:
    RAISE exc_TypeError_type, "module.__new__(): not enough arguments"
.mmn_not_a_type:
    RAISE exc_TypeError_type, "module.__new__(X): X is not a type object"
.mmn_not_a_module:
    RAISE exc_TypeError_type, "module.__new__(X): X is not a subtype of module"
END_FUNC module_method_new

;; ============================================================================
;; module_method_init(rdi = args, rsi = nargs) -> a Value (None)
;;
;; `module.__init__(self, name[, doc])` -- the half that writes the name, the
;; docstring and the three attributes CPython leaves as None.
;; ============================================================================
MMI_SELF  equ 8
MMI_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC module_method_init, MMI_FRAME
    cmp rsi, 2
    jl .mmi_arity
    cmp rsi, 3
    jg .mmi_arity
    push rsi
    push rdi
    mov rdi, [rdi]              ; args[0], self
    V_TEST_PTR rdi, rax
    ja .mmi_bad_self
    test rdi, rdi
    jz .mmi_bad_self
    mov rax, [rdi + PyObject.ob_type]
    push rdi
    push rdi
    mov rdi, rax
    lea rsi, [rel module_type]
    call type_is_subtype
    pop rdi
    pop rdi
    test eax, eax
    jz .mmi_bad_self
    mov [rbp - MMI_SELF], rdi

    pop rdi                     ; args
    pop rsi                     ; nargs
    mov rdx, [rdi + 8]          ; args[1], the name
    V_TEST_PTR rdx, rax
    ja .mmi_bad_name
    test rdx, rdx
    jz .mmi_bad_name
    mov rax, [rdx + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .mmi_bad_name

    ; The name, in the field and in the dict both.
    push rsi
    push rdi
    mov rdi, rdx
    call obj_incref
    pop rdi
    pop rsi
    mov rdx, [rdi + 8]
    mov rcx, [rbp - MMI_SELF]
    mov rax, [rcx + PyModuleObject.mod_name]
    mov [rcx + PyModuleObject.mod_name], rdx
    push rsi
    push rdi
    mov rdi, rax
    call obj_decref             ; whatever __new__ left there
    pop rdi
    pop rsi

    MMI_SET mod_name_key, [rdi + 8]
    cmp rsi, 3
    jl .mmi_no_doc
    MMI_SET mod_doc_key, [rdi + 16]
    jmp .mmi_rest
.mmi_no_doc:
    MMI_SET_NONE mod_doc_key
.mmi_rest:
    MMI_SET_NONE mtn_loader_key
    MMI_SET_NONE mtn_package_key
    MMI_SET_NONE mtn_spec_key

    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.mmi_bad_self:
    add rsp, 16
    RAISE exc_TypeError_type, \
        "module.__init__() argument 1 must be a module"
.mmi_bad_name:
    RAISE exc_TypeError_type, \
        "module.__init__() argument 1 must be str, not None"
.mmi_arity:
    RAISE exc_TypeError_type, "module.__init__() takes at most 2 arguments"
END_FUNC module_method_init

extern new_from_slot

;; ============================================================================
;; namespace_dunder_new(args, nargs) -> Value    -- types.SimpleNamespace.__new__
;;
;; types.SimpleNamespace keeps its constructor in tp_new and had no entry of its own in
;; tp_dict, so `types.SimpleNamespace.__new__` resolved along the MRO to object.__new__ and
;; was refused.  That is every `super().__new__(cls, ...)` in a subclass, and
;; every copy, deepcopy and pickle of one, since the reduce protocol
;; reconstructs through __new__.  The slot called is the OWNER's, so a Python
;; subclass defining __new__ does not re-enter itself.
;; ============================================================================
DEF_FUNC namespace_dunder_new
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rel namespace_type]
    call new_from_slot
    leave
    ret
END_FUNC namespace_dunder_new



section .rodata
mtn_loader_key:  db "__loader__", 0
mtn_package_key: db "__package__", 0
mtn_spec_key:    db "__spec__", 0
mod_empty_name:  db "", 0

section .bss
mg_name_cached: resq 1        ; the str "__getattr__", built once
mg_dir_cached:  resq 1        ; the str "__dir__", built once
