; typeattr.asm - reading and writing a class's attributes: `type_getattr`
; itself, the descriptors `type.__dict__` answers those attributes through,
; `type.mro()`, and `type_setattr`.
;
; type_getattr and type_getattr_meta came over when class.asm reached the 100k
; cap a second time.  This is where they belong: the getset thunks below were
; already written as "load the interned name and hand it to type_getattr", and
; type_setattr special-cases the same names the read does.  What stayed in
; class.asm is the class and the INSTANCE -- construction, the reprs, dealloc
; and the collector's view of both.
;
; type_setattr came over when class.asm reached the 100k cap.  It belongs
; here by subject: every name it special-cases -- __name__, and the refusal a
; static type gives -- is one of the attributes this file already answers
; the read of.
;
; `C.__mro__` has worked for a long time: type_getattr special-cases the name
; before it walks anything.  What did not exist was the entry in
; `type.__dict__` that CPython answers it THROUGH, and the stdlib reaches for
; that entry directly rather than for the attribute --
;
;     _static_getmro = type.__dict__['__mro__'].__get__
;
; is inspect.py's way of reading an MRO without triggering a __getattr__, and
; it is a KeyError without one.  inspect is imported by dataclasses, pdb,
; pydoc, doctest, unittest and asyncio, so the one missing key stopped a
; seventh of the standard library.
;
; Each descriptor is a getset whose getter is a two-instruction thunk: load
; the interned name for its slot, and hand it to type_getattr, which already
; knows how to answer it.  That keeps one implementation of what `__mro__`
; means rather than two that can drift, and it is why a static type with no
; tp_mro answers here too -- the synthesis lives there.

%include "macros.inc"
%include "object.inc"
%include "value.inc"

extern type_type
extern object_type
extern str_from_cstr
extern user_type_metatype
extern obj_dealloc
extern property_type
extern func_type
extern builtin_func_type
extern method_new
extern ap_strcmp
extern str_type
extern dict_new
extern dict_del_opt
extern obj_incref
extern value_type
extern type_refresh_attr_flags
extern getset_descr_new
extern str_from_cstr_heap
extern dict_set
extern obj_decref
extern list_new
extern list_append
extern exc_TypeError_type
extern raise_exception

;; The attributes exposed, in slot order.  Every one of them is a name
;; type_getattr answers from the type itself rather than from its dict.
TYA_COUNT equ 11

section .bss
;; The interned name for each slot, built once by type_dict_add_attrs.  A
;; thunk has no argument but self, so this is how it knows which it is.
tya_names: resq TYA_COUNT

;; Where type_setattr builds its refusal for a static type.  A raise follows
;; immediately, so nothing outlives the call.
TS_IMM_BUFSZ equ 256
ts_imm_buf: resb TS_IMM_BUFSZ

section .rodata
tya_mro:           db "__mro__", 0
tya_bases:         db "__bases__", 0
tya_base:          db "__base__", 0
tya_name:          db "__name__", 0
tya_qualname:      db "__qualname__", 0
tya_module:        db "__module__", 0
tya_dict:          db "__dict__", 0
tya_basicsize:     db "__basicsize__", 0
tya_dictoffset:    db "__dictoffset__", 0
tya_weakrefoffset: db "__weakrefoffset__", 0
tya_flags:         db "__flags__", 0

;; Parallel to tya_names: the C string for each slot, so the registration is
;; one loop rather than ten copies of it.
align 8
tya_cstrs:
    dq tya_mro, tya_bases, tya_base, tya_name, tya_qualname
    dq tya_module, tya_dict, tya_basicsize, tya_dictoffset, tya_weakrefoffset
    dq tya_flags

section .text

;; ============================================================================
;; tya_fetch(rdi = self Value, rsi = name str) -> rax = Value, or 0 raising
;;
;; The body every thunk tail-jumps into.  `self` reaches a getset getter
;; unchecked as far as its own type goes -- getset_check_receiver only proves
;; it is an instance of the owner -- and the owner here is `type`, whose
;; instances are classes.  A class IS a type object, so the test is that its
;; own type is a metatype.
;; ============================================================================
TYF_FRAME equ 16            ; + 0 pushes = 16
DEF_FUNC_LOCAL tya_fetch, TYF_FRAME
    V_TEST_PTR rdi, rax
    ja .tyf_not_a_type
    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .tyf_not_a_type
    test dword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .tyf_not_a_type
    leave
    jmp type_getattr
.tyf_not_a_type:
    RAISE exc_TypeError_type, "descriptor requires a type object"
END_FUNC tya_fetch

;; CPython's Py_TPFLAGS_*, for the bits this tree can answer honestly.
CPY_TPFLAGS_COMPAT            equ 0x00000002
CPY_TPFLAGS_IMMUTABLETYPE     equ 0x00000100
CPY_TPFLAGS_HEAPTYPE          equ 0x00000200
CPY_TPFLAGS_BASETYPE          equ 0x00000400
CPY_TPFLAGS_READY             equ 0x00001000
CPY_TPFLAGS_HAVE_GC           equ 0x00004000
CPY_TPFLAGS_VALID_VERSION_TAG equ 0x00080000
CPY_TPFLAGS_LONG_SUBCLASS     equ 0x01000000
CPY_TPFLAGS_LIST_SUBCLASS     equ 0x02000000
CPY_TPFLAGS_TUPLE_SUBCLASS    equ 0x04000000
CPY_TPFLAGS_BYTES_SUBCLASS    equ 0x08000000
CPY_TPFLAGS_UNICODE_SUBCLASS  equ 0x10000000
CPY_TPFLAGS_DICT_SUBCLASS     equ 0x20000000
CPY_TPFLAGS_BASE_EXC_SUBCLASS equ 0x40000000
CPY_TPFLAGS_TYPE_SUBCLASS     equ 0x80000000

;; TGF_BIT ours, theirs -- copy one flag across, ecx holding this type's.
%macro TGF_BIT 2
    test ecx, %1
    jz %%off
    or eax, %2
%%off:
%endmacro

;; TYA_GET name, slot -- one getter, which is the whole body of a descriptor.
%macro TYA_GET 2
DEF_FUNC_BARE %1
    mov rsi, [rel tya_names + 8 * %2]
    jmp tya_fetch
END_FUNC %1
%endmacro

TYA_GET tya_get_mro,           0
TYA_GET tya_get_bases,         1
TYA_GET tya_get_base,          2
TYA_GET tya_get_name,          3
TYA_GET tya_get_qualname,      4
TYA_GET tya_get_module,        5
TYA_GET tya_get_dict,          6
TYA_GET tya_get_basicsize,     7
TYA_GET tya_get_dictoffset,    8
TYA_GET tya_get_weakrefoffset, 9

;; ============================================================================
;; tya_get_flags(rdi = the class) -> rax = its Py_TPFLAGS_* word, as an int
;;
;; tp_flags cannot be reported raw: the low 32 bits are this tree's own layout
;; and the high 32 are the type version.  This translates the bits that mean
;; the same thing in both.
;;
;; It is deliberately NOT the whole of CPython's word, and cannot be.  The
;; bits left out are the ones this tree does not model -- MANAGED_DICT and
;; MANAGED_WEAKREF above all, whose absence is a recorded divergence, and
;; MATCH_SELF, SEQUENCE, MAPPING, HAVE_VECTORCALL and ITEMS_AT_END, which no
;; flag here stands for.  Reporting them would be a lie; reporting a subset
;; means code masking one of them reads a confident zero.  Both are wrong and
;; the subset is the less wrong: BASETYPE, HAVE_GC and the subclass bits are
;; what anything in Python actually tests, and they are exact.
;; DIVERGENCES.md carries the list.
;; ============================================================================
TGF_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL tya_get_flags, TGF_FRAME
    V_TEST_PTR rdi, rax
    ja .tgf_bad
    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .tgf_bad
    test dword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .tgf_bad
    call type_cpython_flags
    V_PACK_I64 rax, rcx
    leave
    ret
.tgf_bad:
    RAISE exc_TypeError_type, "descriptor requires a type object"
END_FUNC tya_get_flags

;; ============================================================================
;; type_cpython_flags(rdi = a type) -> rax = its Py_TPFLAGS_* word
;;
;; Shared with type_getattr, which answers __flags__ ahead of the tp_dict walk
;; because CPython's is a data descriptor on the metatype.
;; ============================================================================
global type_cpython_flags
DEF_FUNC type_cpython_flags, 8      ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, rdi
    mov rcx, [rdi + PyTypeObject.tp_flags]
    ; READY, and the compatibility bit every CPython type carries.  A type
    ; that can be asked for its flags at all is ready by construction here.
    mov eax, CPY_TPFLAGS_READY | CPY_TPFLAGS_COMPAT

    test ecx, TYPE_FLAG_HEAPTYPE
    jz .tcf_static
    or eax, CPY_TPFLAGS_HEAPTYPE
    jmp .tcf_after_heap
.tcf_static:
    ; A static type is immutable, and CPython stamps VALID_VERSION_TAG on the
    ; ones it has readied.
    or eax, CPY_TPFLAGS_IMMUTABLETYPE | CPY_TPFLAGS_VALID_VERSION_TAG
.tcf_after_heap:

    ; BASETYPE is "can be subclassed", and this tree keeps the NEGATIVE of it:
    ; TYPE_FLAG_BASETYPE is set on three types by hand, while TYPE_FLAG_FINAL
    ; is the flag buildclass actually consults to refuse a base.  Translating
    ; the positive one reported `object` as un-subclassable.
    test ecx, TYPE_FLAG_FINAL
    jnz .tcf_no_base
    or eax, CPY_TPFLAGS_BASETYPE
.tcf_no_base:
    test ecx, TYPE_FLAG_HAVE_GC
    jz .tcf_no_gc
    or eax, CPY_TPFLAGS_HAVE_GC
.tcf_no_gc:

    ; The subclass bits, seven of them one flag each.
    ; Not TYPE_FLAG_INT_SUBCLASS for bool: setting that flag on bool_type
    ; makes `WIFEXITED(s)` answer 1 rather than True, because the flag is how
    ; several places ask "is this an int" and a bool then takes the int path
    ; and loses its boolness.  The MRO answers the same question without
    ; touching what anything else reads.
    TGF_BIT TYPE_FLAG_INT_SUBCLASS,       CPY_TPFLAGS_LONG_SUBCLASS
    TGF_BIT TYPE_FLAG_LIST_SUBCLASS,      CPY_TPFLAGS_LIST_SUBCLASS
    TGF_BIT TYPE_FLAG_TUPLE_SUBCLASS,     CPY_TPFLAGS_TUPLE_SUBCLASS
    TGF_BIT TYPE_FLAG_BYTES_SUBCLASS,     CPY_TPFLAGS_BYTES_SUBCLASS
    TGF_BIT TYPE_FLAG_STR_SUBCLASS,       CPY_TPFLAGS_UNICODE_SUBCLASS
    TGF_BIT TYPE_FLAG_DICT_SUBCLASS,      CPY_TPFLAGS_DICT_SUBCLASS
    TGF_BIT TYPE_FLAG_METATYPE,           CPY_TPFLAGS_TYPE_SUBCLASS

    ; Two that want the MRO instead of a flag: BASE_EXC has none at all, and
    ; bool's LONG deliberately is not set (see above).
    push rax
    mov rdi, rbx
    lea rsi, [rel exc_BaseException_type]
    extern type_is_subtype
    extern exc_BaseException_type
    call type_is_subtype
    mov edx, eax
    pop rax
    test edx, edx
    jz .tcf_no_exc
    or eax, CPY_TPFLAGS_BASE_EXC_SUBCLASS
.tcf_no_exc:
    test eax, CPY_TPFLAGS_LONG_SUBCLASS
    jnz .tcf_no_long
    push rax
    mov rdi, rbx
    lea rsi, [rel int_type]
    extern int_type
    call type_is_subtype
    mov edx, eax
    pop rax
    test edx, edx
    jz .tcf_no_long
    or eax, CPY_TPFLAGS_LONG_SUBCLASS
.tcf_no_long:
    pop rbx
    leave
    ret
END_FUNC type_cpython_flags

section .rodata
align 8
tya_getters:
    dq tya_get_mro, tya_get_bases, tya_get_base, tya_get_name
    dq tya_get_qualname, tya_get_module, tya_get_dict, tya_get_basicsize
    dq tya_get_dictoffset, tya_get_weakrefoffset, tya_get_flags
section .text

;; ============================================================================
;; type_dict_add_attrs(rdi = type's tp_dict) -> void
;;
;; Called while type_type's dict is being built.  Interns each name, keeps it
;; in tya_names for the thunk that will need it, and stores a read-only getset
;; under it.  gs_owner is type_type, which is what makes the repr read
;; "<attribute '__mro__' of 'type' objects>".
;; ============================================================================
TDA_DICT  equ 8
TDA_I     equ 16
TDA_NAME  equ 24
TDA_FRAME equ 32            ; + 2 pushes = 48
DEF_FUNC type_dict_add_attrs, TDA_FRAME
    push rbx
    push r12
    mov [rbp - TDA_DICT], rdi
    xor ebx, ebx
.tda_loop:
    cmp rbx, TYA_COUNT
    jge .tda_done
    lea rax, [rel tya_cstrs]
    mov rdi, [rax + rbx*8]
    call str_from_cstr_heap
    test rax, rax
    jz .tda_done
    mov [rbp - TDA_NAME], rax
    ; The slot keeps the reference the dict key would otherwise be the only
    ; owner of: a thunk reads it for the life of the process.
    lea rcx, [rel tya_names]
    mov [rcx + rbx*8], rax
    lea rcx, [rel tya_getters]
    mov rdi, [rcx + rbx*8]
    xor esi, esi                ; read-only, as CPython's are
    mov rdx, rax
    call getset_descr_new
    test rax, rax
    jz .tda_done
    mov r12, rax
    lea rcx, [rel type_type]
    mov [r12 + PyGetSetDescrObject.gs_owner], rcx
    mov rdi, [rbp - TDA_DICT]
    mov rsi, [rbp - TDA_NAME]
    mov rdx, r12
    call dict_set
    mov rdi, r12
    call obj_decref
    inc rbx
    jmp .tda_loop
.tda_done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_dict_add_attrs

;; ============================================================================
;; type_method_mro(rdi = args Value*, rsi = nargs) -> rax = Value
;;
;; `type.mro(C)`, and `C.mro()` through the same entry -- a builtin in
;; type's dict binds to the class the way any other method binds to its
;; receiver, so both arrive here with the class as args[0].
;;
;; CPython's recomputes the linearization; this reads the one the class
;; already carries, which is the same list for every class that has one and
;; is the only answer available for a static type that has none.
;; ============================================================================
TMM_LIST  equ 8
TMM_TUPLE equ 16
TMM_FRAME equ 32            ; + 2 pushes = 48
DEF_FUNC type_method_mro, TMM_FRAME
    push rbx
    push r12
    cmp rsi, 1
    jne .tmm_arity
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .tmm_not_a_type
    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .tmm_not_a_type
    test dword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .tmm_not_a_type

    lea rax, [rel tya_names]
    mov rsi, [rax]              ; slot 0 is "__mro__"
    test rsi, rsi
    jz .tmm_not_a_type
    call type_getattr
    test rax, rax
    jz .tmm_failed
    mov [rbp - TMM_TUPLE], rax

    mov rdi, [rax + PyTupleObject.ob_size]
    call list_new
    test rax, rax
    jz .tmm_drop_tuple
    mov [rbp - TMM_LIST], rax

    mov r12, [rbp - TMM_TUPLE]
    xor ebx, ebx
.tmm_copy:
    cmp rbx, [r12 + PyTupleObject.ob_size]
    jge .tmm_copied
    mov rdi, [rbp - TMM_LIST]
    mov rax, [r12 + PyTupleObject.ob_item]
    mov rsi, [rax + rbx*8]
    call list_append
    inc rbx
    jmp .tmm_copy
.tmm_copied:
    mov rdi, r12
    call obj_decref
    mov rax, [rbp - TMM_LIST]
    pop r12
    pop rbx
    leave
    ret

.tmm_drop_tuple:
    mov rdi, [rbp - TMM_TUPLE]
    call obj_decref
.tmm_failed:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
.tmm_arity:
    RAISE exc_TypeError_type, "mro() takes no arguments"
.tmm_not_a_type:
    RAISE exc_TypeError_type, "mro() requires a type"
END_FUNC type_method_mro

;; ============================================================================
;; type_setattr(rdi = the type, rsi = the name str, rdx = the value Value or 0
;;              to delete, ecx = the value's tag) -> eax = 0, or never returns
;;
;; Writes into the type's tp_dict, except for the names that are not dict
;; entries at all: __name__ is tp_name, and a static type refuses every write.
;; ============================================================================
DEF_FUNC type_setattr
    push rbx
    push rcx                    ; keep the stack aligned

    ; --- a static type is immutable ---
    ; `str.foo = 1` used to succeed and put a key in str's own tp_dict, for
    ; every process-wide str from then on.  CPython refuses: only a heaptype
    ; is writable, everything else is Py_TPFLAGS_IMMUTABLETYPE.  The check has
    ; to be ahead of the __name__ rename below, which has its own narrower
    ; version of it, and ahead of the tp_dict allocation, which would
    ; otherwise hand a static type a dict just to reject the write into it.
    mov rax, [rdi + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_HEAPTYPE
    jz .ts_immutable

    ; --- a data descriptor on the metatype takes the write ---
    ; CPython stores into a class through the GENERIC setattr, so a metaclass
    ; property with a setter runs it and the class dict is never touched.
    ; op_store_attr already asked; setattr(), delattr() and `del C.x` come
    ; straight here.  The gate is the one type_getattr_meta uses.
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAP_DATA_DESCR
    jnz .ts_meta_data
.ts_no_meta_data:

    ; --- __name__ renames the class ---
    ; A class's name is tp_name, not a dict entry, so `C.__name__ = "x"` set a
    ; key nothing ever read and the class kept its old name.  typing.py
    ; renames two classes and then registers them in sys.modules UNDER THE
    ; NEW NAME -- so `sys.modules["re"]` became typing's deprecated `re`
    ; class, and the next `import re` handed a class to everything that
    ; wanted the module.
    mov rbx, rdi
    test rsi, rsi
    jz .ts_not_name
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .ts_not_name
    lea rdi, [rsi + PyStrObject.data]
    push rsi
    push rdx
    CSTRING rsi, "__name__"
    call ap_strcmp
    pop rdx
    pop rsi
    test eax, eax
    jz .ts_rename

    ; --- __qualname__ is ht_qualname, not a dict entry ---
    ; It comes out of the class body's namespace at build time, so a later
    ; `C.__qualname__ = "x"` has to go to the same place or the class keeps
    ; the one it was born with.
    lea rdi, [rsi + PyStrObject.data]
    push rsi
    push rdx
    CSTRING rsi, "__qualname__"
    call ap_strcmp
    pop rdx
    pop rsi
    test eax, eax
    jz .ts_requalify
.ts_not_name:
    mov rdi, rbx
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
    ; A NULL value means DELETE, not "store a NULL".  dict_set was called
    ; either way, so `del C.attr` left the key in the type's dict bound to a
    ; NULL Value.  Lookup answered correctly -- `k in C.__dict__` was False and
    ; `C.__dict__[k]` raised KeyError -- but the entry was still occupied, so
    ; keys() and items() went on yielding it, and items() handed out the NULL
    ; Value itself.
    ;
    ; That is how a NULL reached ordinary builtins: enum.py deletes five names
    ; from Enum, doctest walks Enum.__dict__.items(), and inspect called
    ; type() and isinstance() on the hole.  isinstance() then released an
    ; uninitialised frame slot, and the decrement landed inside a live code
    ; object's bytecode -- one byte of a RETURN_VALUE, which the eval loop
    ; then refused as opcode 82.
    ;
    ; instance_setattr already had this fix; type_setattr was missed.
    test rdx, rdx
    jz .ts_dict_del
    ; dict_set(dict, name Value, value Value)
    pop rcx
    call dict_set
    jmp .ts_wrote

.ts_meta_data:
    push rdi
    push rsi
    push rdx
    push rdx                    ; the pad: four pushes keep the call aligned
    call ts_meta_descr_set
    pop rdx
    pop rdx
    pop rsi
    pop rdi
    test eax, eax
    jz .ts_no_meta_data
    xor eax, eax                ; a raise inside it is left pending
    pop rcx
    pop rbx
    leave
    ret

.ts_dict_del:
    ; The alignment push is still on the stack here, so this call is aligned
    ; where the dict_set above is not; borrow that word to carry the name
    ; across, since rsi does not survive a call and there is no frame.
    mov [rsp], rsi
    extern dict_del_opt
    call dict_del_opt           ; -1 when it was never there
    mov rsi, [rsp]
    pop rcx
    test eax, eax
    jnz .ts_del_missing

.ts_wrote:
    ; Assigning a dunder after the class exists has to take effect, the way
    ; `C.__eq__ = f` does in CPython: the slot is installed at class creation
    ; from what the body defined, and nothing re-ran this.  Only a heaptype
    ; has slots to install; a static type's are in its table.
    mov rax, [rbx + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_HEAPTYPE
    jz .ts_done
    mov rdi, rbx
    extern type_install_slots_tree
    call type_install_slots_tree

    ; And the __getattribute__ bit, which unlike a slot is inherited -- so
    ; this pushes the new answer down every subclass, not just this type.
    ; Without it `Base.__getattribute__ = f` would leave an already-built D
    ; saying "no override" and the hook would silently never run.
    mov rdi, rbx
    call type_refresh_attr_flags
.ts_done:

    pop rbx
    leave
    ret

.ts_del_missing:
    ; `del C.nosuch` succeeded silently while dict_set was storing a NULL over
    ; a key that was never there.  CPython raises, and so does the instance
    ; path next door.  rsi is the name, restored above.
    mov rdi, rbx                ; the type -- a pointer is its own Value
    mov edx, 1                  ; a delete is a set, as far as the wording goes
    extern raise_no_attribute
    call raise_no_attribute     ; does not return

.ts_rename:
    ; tp_name points into a PyStrObject's data, and the type owns a reference
    ; to that string -- user_type_dealloc recovers it the same way.  So a
    ; rename is: take the new one, point at its data, drop the old.
    mov rax, rdx
    test rax, rax
    jz .ts_rename_bad
    V_TEST_PTR rax, rcx
    ja .ts_rename_bad
    mov rcx, [rax + PyObject.ob_type]
    lea rdi, [rel str_type]
    cmp rcx, rdi
    jne .ts_rename_bad
    mov rcx, [rbx + PyTypeObject.tp_flags]
    test rcx, TYPE_FLAG_HEAPTYPE
    jz .ts_rename_static
    mov rdi, rax
    push rax
    call obj_incref
    pop rax
    mov rcx, [rbx + PyTypeObject.tp_name]
    lea rdx, [rax + PyStrObject.data]
    mov [rbx + PyTypeObject.tp_name], rdx
    test rcx, rcx
    jz .ts_rename_done
    sub rcx, PyStrObject.data
    mov rdi, rcx
    call obj_decref
.ts_rename_done:
    xor eax, eax
    pop rcx
    pop rbx
    leave
    ret
.ts_requalify:
    ; CPython refuses a non-str and refuses a delete.  A heaptype is the only
    ; kind that reaches here at all; the static-type refusal is above.
    mov rax, rdx
    test rax, rax
    jz .ts_requalify_del
    V_TEST_PTR rax, rcx
    ja .ts_requalify_bad
    mov rcx, [rax + PyObject.ob_type]
    lea rdi, [rel str_type]
    cmp rcx, rdi
    jne .ts_requalify_bad
    mov rdi, rax
    push rax
    call obj_incref
    pop rax
    mov rcx, [rbx + HT_QUALNAME]
    mov [rbx + HT_QUALNAME], rax
    test rcx, rcx
    jz .ts_rename_done
    mov rdi, rcx
    call obj_decref
    jmp .ts_rename_done

.ts_requalify_bad:
    ; "can only assign string to C.__qualname__, not 'int'" -- both halves are
    ; the caller's, so it is built the way the immutable-type refusal below is.
    ;
    ; The value goes on the machine stack, not into a callee-saved register:
    ; r13 is the eval loop's value-stack top, and this path leaves through the
    ; unwinder rather than returning.
    push rdx
    push rdx                            ; and a pad, to keep rsp even
    lea r8, [rel ts_imm_buf]
    xor ecx, ecx
    CSTRING r9, "can only assign string to "
    call ts_imm_append
    mov r9, [rbx + PyTypeObject.tp_name]
    call ts_imm_append
    CSTRING r9, ".__qualname__, not '"
    call ts_imm_append
    mov rdi, [rsp]
    push r8
    push rcx
    call value_type
    pop rcx
    pop r8
    xor r9d, r9d
    test rax, rax
    jz .ts_requalify_nameless
    mov r9, [rax + PyTypeObject.tp_name]
.ts_requalify_nameless:
    call ts_imm_append
    CSTRING r9, "'"
    call ts_imm_append
    mov byte [r8 + rcx], 0
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel ts_imm_buf]
    call raise_exception

.ts_requalify_del:
    ; CPython says "immutable type" here even for a class that is not one:
    ; type_setattro reaches its shared refusal before the two part company.
    lea r8, [rel ts_imm_buf]
    xor ecx, ecx
    CSTRING r9, "cannot delete '__qualname__' attribute of immutable type '"
    call ts_imm_append
    mov r9, [rbx + PyTypeObject.tp_name]
    call ts_imm_append
    CSTRING r9, "'"
    call ts_imm_append
    mov byte [r8 + rcx], 0
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel ts_imm_buf]
    call raise_exception

.ts_immutable:
    ; "cannot set 'foo' attribute of immutable type 'str'".  Both halves are
    ; the caller's, so the message is built rather than named.  CPython says
    ; "set" for a delete too -- its check is ahead of the point where the two
    ; part company -- so this does not look at the value.
    mov rbx, rdi                        ; the type
    lea r8, [rel ts_imm_buf]
    xor ecx, ecx
    CSTRING r9, "cannot set '"
    call ts_imm_append
    ; the attribute name
    xor r9d, r9d
    test rsi, rsi
    jz .ts_imm_after_name
    mov rax, [rsi + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rax, rdx
    jne .ts_imm_after_name
    lea r9, [rsi + PyStrObject.data]
.ts_imm_after_name:
    call ts_imm_append
    CSTRING r9, "' attribute of immutable type '"
    call ts_imm_append
    mov r9, [rbx + PyTypeObject.tp_name]
    call ts_imm_append
    CSTRING r9, "'"
    call ts_imm_append
    mov byte [r8 + rcx], 0
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel ts_imm_buf]
    call raise_exception

.ts_rename_static:
    RAISE exc_TypeError_type, "cannot set __name__ of a built-in type"
.ts_rename_bad:
    RAISE exc_TypeError_type, "can only assign string to __name__"
END_FUNC type_setattr

;; ============================================================================
;; ts_imm_append(r8 = buffer, rcx = length, r9 = NUL-terminated source or 0)
;;   -> rcx advanced past what was copied
;;
;; The one piece of string building type_setattr's refusal needs.  Everything
;; else it touches is caller-saved and it is on a path that ends in a raise,
;; so it keeps to r8/rcx/r9 and clobbers only rax.
;; ============================================================================
DEF_FUNC_LOCAL ts_imm_append
    test r9, r9
    jz .tia_done
.tia_loop:
    movzx eax, byte [r9]
    test al, al
    jz .tia_done
    cmp rcx, TS_IMM_BUFSZ - 2
    jae .tia_done
    mov [r8 + rcx], al
    inc rcx
    inc r9
    jmp .tia_loop
.tia_done:
    leave
    ret
END_FUNC ts_imm_append

;; ============================================================================
;; type_getattr(PyTypeObject *self, PyObject *name) -> PyObject*
;; Look up an attribute on a type object itself (class variables).
;; Also handles __name__ (from tp_name) and __bases__.
;; rdi = type object, rsi = name (PyStrObject*)
;; Returns: owned reference to attribute value, or NULL
;; ============================================================================
extern tuple_new
TGA_ORIGIN equ 8            ; the type the MRO walk started from
TGA_META   equ 16           ; its metatype, for the second walk
TGA_FROMMETA equ 24         ; where to report which walk answered, or 0
TGA_FALLBACK equ 32         ; what a total miss means: 0 = no attribute,
                            ; 1 = an empty __annotations__ to create and keep,
                            ; 2 = an empty __type_params__ tuple
TGA_FRAME  equ 48           ; + 2 pushes = 64
DEF_FUNC_BARE type_getattr
    xor edx, edx                ; no caller wants to know where it came from
    jmp type_getattr_meta
END_FUNC type_getattr

;; ============================================================================
;; type_getattr_meta(rdi = type, rsi = name, rdx = &from_metatype) -> Value
;;
;; The same lookup, reporting WHICH of the two MROs answered: the class's own,
;; or its metatype's.  It writes 1 through rdx for the metatype and 0 for the
;; class, and rdx may be 0.
;;
;; The caller that needs this is the descriptor protocol.  CPython does not
;; run a property's getter when the property was found in the class's own MRO
;; -- `C.prop` IS the property object, which is how `C.prop.__doc__ = ...` can
;; be written at all -- but it does run one found on the METATYPE, which is
;; what makes Enum.__members__ work.  Deciding that from "is the object a
;; class" gets the second case wrong, and until now this function had no way
;; to say which it was.
;; ============================================================================
DEF_FUNC type_getattr_meta, TGA_FRAME
    push rbx
    push r12

    mov [rbp - TGA_FROMMETA], rdx
    test rdx, rdx
    jz .tga_no_out
    mov qword [rdx], 0
.tga_no_out:
    mov rbx, rsi                ; rbx = name
    mov r12, rdi                ; r12 = type (walks)
    mov [rbp - TGA_ORIGIN], rdi
    mov qword [rbp - TGA_FALLBACK], 0

    ; A DATA descriptor on the metatype outranks everything below -- the
    ; ladder and the class's own MRO both -- because that is the first thing
    ; CPython's type_getattro asks.  The class dict used to win, so a
    ; metaclass property named __module__ (zope.interface's) answered with the
    ; descriptor the class body stored under the same name.  Only a metaclass
    ; of the user's own can hold one this ladder does not already answer:
    ; type's getsets ARE the ladder, and the builtin metatypes are not
    ; heaptypes, so TYPE_FLAG_HEAP_DATA_DESCR is the gate and an ordinary
    ; class -- or one made by ABCMeta -- pays one load and one test here.
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAP_DATA_DESCR
    jnz .tga_meta_data
.tga_ladder:

    ; Every name the ladder below can match begins with "__", and there are
    ; twelve of them, each an ap_strcmp CALL made before any dict is touched.
    ; An ordinary attribute -- which is what `C.attr` almost always is --
    ; matched none of them and paid for all twelve: ap_strcmp was 17% of the
    ; case and type_getattr_meta another 12%.  Two byte compares now stand in
    ; front of the lot.  The second byte is read only when the first is an
    ; underscore, so an empty name reads its NUL terminator and stops.
    cmp byte [rbx + PyStrObject.data], '_'
    jne .tga_walk
    cmp byte [rbx + PyStrObject.data + 1], '_'
    jne .tga_walk

    ; Check for __name__: compare name string data with "__name__"
    lea rdi, [rbx + PyStrObject.data]
    lea rsi, [rel tga_name_str]
    call ap_strcmp
    test eax, eax
    jz .tga_return_name

    ; A builtin type's __qualname__ is its __name__, and its __module__ is
    ; "builtins".  Neither existed, so `ValueError.__qualname__` was an
    ; AttributeError -- and CPython's traceback and warnings machinery reads
    ; both off an exception's type.  A heaptype sets them in its own dict,
    ; which the walk below finds first.
    lea rdi, [rbx + PyStrObject.data]
    CSTRING rsi, "__qualname__"
    call ap_strcmp
    test eax, eax
    jz .tga_return_qualname

    lea rdi, [rbx + PyStrObject.data]
    CSTRING rsi, "__module__"
    call ap_strcmp
    test eax, eax
    jz .tga_return_module

    lea rdi, [rbx + PyStrObject.data]
    CSTRING rsi, "__dict__"
    call ap_strcmp
    test eax, eax
    jz .tga_return_dict

    lea rdi, [rbx + PyStrObject.data]
    CSTRING rsi, "__mro__"
    call ap_strcmp
    test eax, eax
    jz .tga_return_mro

    lea rdi, [rbx + PyStrObject.data]
    CSTRING rsi, "__bases__"
    call ap_strcmp
    test eax, eax
    jz .tga_return_bases

    lea rdi, [rbx + PyStrObject.data]
    CSTRING rsi, "__base__"
    call ap_strcmp
    test eax, eax
    jz .tga_return_base

    ; The instance layout, as CPython reports it.  These are getsets on the
    ; metatype in CPython, so they are data descriptors and win over anything
    ; a class body puts under the same name -- hence the check here, ahead of
    ; the tp_dict walk, rather than after it.
    lea rdi, [rbx + PyStrObject.data]
    CSTRING rsi, "__basicsize__"
    call ap_strcmp
    test eax, eax
    jz .tga_return_basicsize

    lea rdi, [rbx + PyStrObject.data]
    CSTRING rsi, "__dictoffset__"
    call ap_strcmp
    test eax, eax
    jz .tga_return_dictoffset

    lea rdi, [rbx + PyStrObject.data]
    CSTRING rsi, "__weakrefoffset__"
    call ap_strcmp
    test eax, eax
    jz .tga_return_weakrefoffset

    ; __flags__ is computed rather than read, but it is a data descriptor on
    ; the metatype in CPython for the same reason as the three above, so it
    ; has to be answered here too -- otherwise `type.__flags__` finds the
    ; getset in type's own dict and hands back the descriptor.
    lea rdi, [rbx + PyStrObject.data]
    CSTRING rsi, "__flags__"
    call ap_strcmp
    test eax, eax
    jz .tga_return_flags

    ; These two are answered from the class's OWN dict and nothing else, so
    ; they belong in front of the walk -- CPython answers both from a getset on
    ; `type`, and a data descriptor on the metatype wins over whatever the
    ; class inherits through its own MRO.  Asked at the END of the walk, as
    ; they were, `class Sub(Base): pass` reported BASE's annotations, and
    ; because the dict is handed out by reference
    ; `Sub.__annotations__['y'] = str` then wrote into Base's.
    lea rdi, [rbx + PyStrObject.data]
    CSTRING rsi, "__annotations__"
    call ap_strcmp
    test eax, eax
    jz .tga_annotations

    lea rdi, [rbx + PyStrObject.data]
    CSTRING rsi, "__type_params__"
    call ap_strcmp
    test eax, eax
    jz .tga_type_params

    ; Check type->tp_dict, then walk tp_base chain
.tga_walk:
    mov rdi, [r12 + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .tga_next_base

    mov rsi, rbx
    call dict_get               ; a Value; 0 is the only miss
    test rax, rax
    jnz .tga_found

.tga_next_base:
    MRO_NEXT r12, [rbp - TGA_ORIGIN]
    test r12, r12
    jnz .tga_walk
    jmp .tga_not_found

.tga_return_dict:
    ; A class dict is exposed read-only, as CPython does: types.py takes
    ; MappingProxyType straight out of `type(type.__dict__)`, so the wrapper
    ; has to exist and be its own type.  A static type may have no tp_dict
    ; at all; give it an empty one rather than reporting no __dict__.
    mov r12, [rbp - TGA_ORIGIN]
    mov rdi, [r12 + PyTypeObject.tp_dict]
    test rdi, rdi
    jnz .tga_have_tp_dict
    extern dict_new
    call dict_new
    mov [r12 + PyTypeObject.tp_dict], rax
    mov rdi, rax
.tga_have_tp_dict:
    extern mappingproxy_new
    call mappingproxy_new
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.tga_return_mro:
    mov rax, [rbp - TGA_ORIGIN]
    mov rax, [rax + PyTypeObject.tp_mro]
    test rax, rax
    jz .tga_synth_mro
    jmp .tga_return_tuple
.tga_return_bases:
    mov rax, [rbp - TGA_ORIGIN]
    mov rax, [rax + PyTypeObject.tp_bases]
    test rax, rax
    jnz .tga_return_tuple
    ; A static type keeps no tuple; build one from tp_base.  Its chain ends at
    ; 0 rather than at object -- type_mro_next, type_mro_len and type_mro_fill
    ; each substitute the object that anchors the end, and this did not, so
    ; every builtin reported no bases at all while reporting a two-entry
    ; __mro__.  Nothing in the language notices until something walks
    ; __bases__ itself: functools._c3_mro(str) answered [str], _find_impl
    ; answered None, and singledispatch raised "'NoneType' object is not
    ; callable" on its first call, before anything had been registered.
    mov rcx, [rbp - TGA_ORIGIN]
    mov rcx, [rcx + PyTypeObject.tp_base]
    test rcx, rcx
    jnz .tga_bases_one
    ; object is the one type that really has no bases; everything else has it.
    lea rcx, [rel object_type]
    cmp rcx, [rbp - TGA_ORIGIN]
    je .tga_empty_tuple
.tga_bases_one:
    push rcx
    mov edi, 1
    call tuple_new
    pop rcx
    mov rdx, [rax + PyTupleObject.ob_item]
    mov [rdx], rcx
    push rax
    mov rdi, rcx
    call obj_incref
    pop rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.tga_synth_mro:
    ; Likewise for __mro__: walk the base chain into a fresh tuple.
    mov rdi, [rbp - TGA_ORIGIN]
    extern type_mro_len
    call type_mro_len
    push rax
    mov rdi, rax
    call tuple_new
    pop rcx
    mov r12, rax
    mov rdi, [rbp - TGA_ORIGIN]
    mov rsi, [rax + PyTupleObject.ob_item]
    extern type_mro_fill
    call type_mro_fill
    ; The tuple owns a reference to each entry.
    mov rcx, [r12 + PyTupleObject.ob_item]
    xor edx, edx
.tga_mro_incref:
    cmp rdx, rax
    jge .tga_mro_done
    push rax
    push rdx
    push rcx
    mov rdi, [rcx + rdx*8]
    call obj_incref
    pop rcx
    pop rdx
    pop rax
    inc rdx
    jmp .tga_mro_incref
.tga_mro_done:
    mov rax, r12
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.tga_return_base:
    ; The one base a class's layout comes from.  `object.__base__` is None,
    ; and only object's is: a static type's tp_base is 0 and its base is
    ; object, the same substitution __bases__ makes above.
    mov rax, [rbp - TGA_ORIGIN]
    mov rax, [rax + PyTypeObject.tp_base]
    test rax, rax
    jnz .tga_return_object
    lea rax, [rel object_type]
    cmp rax, [rbp - TGA_ORIGIN]
    jne .tga_return_object
    extern none_singleton
    lea rax, [rel none_singleton]
.tga_return_object:
    mov rdi, rax
    push rax
    call obj_incref
    pop rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.tga_empty_tuple:
    xor edi, edi
    call tuple_new
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.tga_return_tuple:
    mov rdi, rax
    push rax
    call obj_incref
    pop rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.tga_found:
    ; dict_get's answer is a borrowed Value.
    INCREF_V rax, rdx
    pop r12
    pop rbx
    leave
    ret

.tga_return_flags:
    mov rdi, r12
    extern type_cpython_flags
    call type_cpython_flags
    mov rdi, rax
    jmp .tga_return_layout_int

.tga_return_basicsize:
    mov rdi, [r12 + PyTypeObject.tp_basicsize]
    jmp .tga_return_layout_int

.tga_return_dictoffset:
    mov rdi, [r12 + PyTypeObject.tp_dictoffset]
    jmp .tga_return_layout_int

.tga_return_weakrefoffset:
    ; No weakref word in the instance layout yet: the links live in a side
    ; table, so every type reports 0, which is also what CPython reports for
    ; a type whose instances cannot be weak-referenced.
    xor edi, edi

.tga_return_layout_int:
    extern int_from_i64
    call int_from_i64
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.tga_return_qualname:
    ; A class defined in Python records its own, which carries the enclosing
    ; scope -- "outer.<locals>.Local".  It lives in ht_qualname, past the type
    ; and only on a heaptype, because it is a getset on `type` in CPython and
    ; must not be visible in tp_dict or from an instance.  Only a builtin type
    ; falls through to __name__.
    test qword [r12 + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .tga_return_name
    mov rax, [r12 + HT_QUALNAME]
    test rax, rax
    jz .tga_return_name
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.tga_return_module:
    ; A class defined in Python records its own __module__ in its dict; only
    ; a builtin type falls through to the default below.
    mov rdi, [r12 + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .tga_module_builtin
    mov rsi, rbx
    extern dict_get
    call dict_get
    test rax, rax
    jz .tga_module_builtin
    V_UNPACK rax, rdx
    INCREF_VAL rax, rdx
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.tga_module_builtin:
    ; The dotted prefix of tp_name when there is one -- "_io.FileIO" is in
    ; module "_io" -- and "builtins" otherwise, as CPython has it.
    mov rsi, [r12 + PyTypeObject.tp_name]
    xor ecx, ecx
    xor r8d, r8d                ; the index just past the last dot, or 0
.tga_mod_scan:
    movzx eax, byte [rsi + rcx]
    test al, al
    jz .tga_mod_done
    cmp al, '.'
    jne .tga_mod_next
    mov r8, rcx
.tga_mod_next:
    inc rcx
    jmp .tga_mod_scan
.tga_mod_done:
    test r8, r8
    jz .tga_mod_plain
    mov rdi, rsi
    mov rsi, r8
    extern str_new_heap
    call str_new_heap
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.tga_annotations:
    ; The class's OWN dict -- never the MRO's, which is what made
    ; `class Sub(Base): pass` report Base's -- then the METATYPE's, and only
    ; then the create-and-keep below.  Skipping the metatype walk was the
    ; other half of the same commit's mistake: a metaclass with annotations of
    ; its own supplies them to its instances, and
    ; `class Meta(type): registry: dict = {}` gave `C.__annotations__` as {}.
    mov rdi, [r12 + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .tga_ann_try_meta
    mov rsi, rbx
    call dict_get               ; a Value; 0 is the only miss
    test rax, rax
    jnz .tga_found
.tga_ann_try_meta:
    mov qword [rbp - TGA_FALLBACK], 1
    jmp .tga_meta_start

.tga_type_params:
    mov rdi, [r12 + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .tga_tp_try_meta
    mov rsi, rbx
    call dict_get
    test rax, rax
    jnz .tga_found
.tga_tp_try_meta:
    mov qword [rbp - TGA_FALLBACK], 2
    jmp .tga_meta_start

.tga_empty_type_params:
    ; A class with no type parameters has an EMPTY tuple, not no attribute --
    ; typing and dataclasses both read it unguarded, and so does int's.
    xor edi, edi
    extern tuple_new
    call tuple_new
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.tga_make_annotations:
    ; CPython creates the dict on first read and KEEPS it, so that
    ; `C.__annotations__['x'] = int` persists -- but only for a class that has
    ; a dict of its own to keep it in.  A static type answers AttributeError
    ; there and here.
    mov r12, [rbp - TGA_ORIGIN]
    test qword [r12 + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .tga_really_really_not_found
    mov rdi, [r12 + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .tga_really_really_not_found
    push rdi
    push rdi
    call dict_new
    pop rdi
    pop rdi
    test rax, rax
    jz .tga_really_really_not_found
    push rax
    push rax
    mov rdx, rax
    mov rsi, rbx                ; the name, "__annotations__"
    call dict_set
    pop rax
    pop rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret
    ret
.tga_mod_plain:
    CSTRING rdi, "builtins"
    extern str_from_cstr_heap
    call str_from_cstr_heap
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.tga_return_name:
    ; __name__ is the last dotted component of tp_name: CPython stores
    ; "types.GenericAlias" but reports "GenericAlias", keeping the qualified
    ; form for the repr.  That rule is the STATIC one; a heaptype answers its
    ; whole name, which is how a class renamed to "typing.re" reports the
    ; dotted form CPython's does.
    mov rdi, [r12 + PyTypeObject.tp_name]
    mov rcx, [r12 + PyTypeObject.tp_flags]
    test rcx, TYPE_FLAG_HEAPTYPE
    jnz .tga_name_done
    mov rsi, rdi
    xor ecx, ecx
.tga_name_scan:
    movzx eax, byte [rsi + rcx]
    test al, al
    jz .tga_name_done
    cmp al, '.'
    jne .tga_name_next
    lea rdi, [rsi + rcx + 1]
.tga_name_next:
    inc rcx
    jmp .tga_name_scan
.tga_name_done:
    call str_from_cstr
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.tga_not_found:
    ; Then the metatype's own MRO.  Anything found from here on came from the
    ; metatype, which the caller may need to know.
    mov rax, [rbp - TGA_FROMMETA]
    test rax, rax
    jz .tga_meta_no_out
    mov qword [rax], 1
.tga_meta_no_out:
    ; A metaclass's methods are attributes of the classes it makes, bound to
    ; the class the way an ordinary class's methods bind to its instances --
    ; `ByteString.register` is ABCMeta's, two links up the metatype chain.
    ; Only a user metaclass is walked: the three builtin metatypes hold
    ; entries meant for `type` itself, and offering those on every class would
    ; shadow what a class inherits from object.
.tga_meta_start:
    mov r12, [rbp - TGA_ORIGIN]
    mov r12, [r12 + PyObject.ob_type]
    test r12, r12
    jz .tga_really_not_found
    lea rax, [rel type_type]
    cmp r12, rax
    je .tga_really_not_found
    lea rax, [rel user_type_metatype]
    cmp r12, rax
    je .tga_really_not_found
    extern exc_metatype
    lea rax, [rel exc_metatype]
    cmp r12, rax
    je .tga_really_not_found
    mov [rbp - TGA_META], r12

.tga_meta_walk:
    mov rdi, [r12 + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .tga_meta_next
    mov rsi, rbx
    call dict_get
    V_UNPACK rax, rdx
    test edx, edx
    jnz .tga_meta_found
.tga_meta_next:
    MRO_NEXT r12, [rbp - TGA_META]
    test r12, r12
    jnz .tga_meta_walk
    jmp .tga_really_not_found

.tga_meta_data:
    mov rdi, rax
    mov rsi, rbx
    call type_meta_data_descr   ; a borrowed descriptor, or 0
    test rax, rax
    jz .tga_ladder
    mov rcx, [rbp - TGA_FROMMETA]
    test rcx, rcx
    jz .tga_meta_data_found
    mov qword [rcx], 1          ; the caller runs its __get__
.tga_meta_data_found:
    mov [rbp - TGA_META], rax   ; just a place to keep it; nothing walks on
    mov edx, TAG_PTR
    ; fall into the metatype answer: bound or handed over, as any other
.tga_meta_found:
    cmp edx, TAG_PTR
    jne .tga_meta_plain
    mov rcx, [rax + PyObject.ob_type]
    ; rdx is the TAG, and .tga_meta_plain increfs with it.  Borrowing it as
    ; scratch for these compares left it holding a type's ADDRESS, which is
    ; not TAG_PTR, so INCREF_VAL did nothing and the metatype's tp_dict was
    ; left holding a property its caller then released -- a use-after-free
    ; that reproduces as `class Meta(type)` with a property, read twice.
    ; A builtin binds too when it is a descriptor, as it does everywhere else
    ; a method is fetched.  type.__subclasses__ is one, and this walk is the
    ; ONLY road to it for a class whose metatype is a metaclass of its own --
    ; every ABC and every Enum -- so A.__subclasses__() came back unbound and
    ; answered "takes no arguments".  A module-level builtin stored on a
    ; metaclass is not a descriptor and is handed over as it stands.
    push rax
    push rdx
    mov rdi, rax
    xor esi, esi                   ; the receiver here is a CLASS, by design
    extern builtin_should_bind
    call builtin_should_bind
    mov ecx, eax
    pop rdx
    pop rax
    test ecx, ecx
    jz .tga_meta_plain
.tga_meta_bind:
    mov rdi, rax
    mov rsi, [rbp - TGA_ORIGIN]
    call method_new
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.tga_meta_plain:
    mov r12, rdx
    INCREF_VAL rax, rdx
    mov rdx, r12
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.tga_really_not_found:
    ; __annotations__ and __type_params__ used to be asked here, after the
    ; walk, which is what made a subclass answer its base's.  They are in the
    ; ladder now -- and they come back HERE when both walks miss, because
    ; each has an empty value to invent rather than an attribute to refuse.
    cmp qword [rbp - TGA_FALLBACK], 1
    je .tga_make_annotations
    cmp qword [rbp - TGA_FALLBACK], 2
    je .tga_empty_type_params
.tga_really_really_not_found:
    RET_NULL
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC type_getattr_meta

;; ============================================================================
;; ts_meta_descr_set(rdi = a class, rsi = the name, rdx = the value Value, or
;;   0 to delete) -> eax = 1 when a data descriptor on the metatype took it
;;
;; A property's setter or deleter, or a descriptor's __set__ / __delete__,
;; called with the CLASS as the instance.  What either raises is left pending
;; for the caller's own check, as op_store_attr's property arm leaves it.
;; ============================================================================
TSM_CLS   equ 8
TSM_VAL   equ 16
TSM_DESC  equ 24
TSM_FRAME equ 32
DEF_FUNC_LOCAL ts_meta_descr_set, TSM_FRAME
    mov [rbp - TSM_CLS], rdi
    mov [rbp - TSM_VAL], rdx
    mov rdi, [rdi + PyObject.ob_type]
    call type_meta_data_descr
    test rax, rax
    jz .tsm_no
    mov [rbp - TSM_DESC], rax
    mov rcx, [rax + PyObject.ob_type]
    lea r8, [rel property_type]
    cmp rcx, r8
    jne .tsm_general
    mov rdi, rax
    mov rsi, [rbp - TSM_CLS]
    mov rdx, [rbp - TSM_VAL]    ; 0 is the deleter's
    extern property_descr_set
    call property_descr_set
    jmp .tsm_yes
.tsm_general:
    cmp qword [rbp - TSM_VAL], 0
    je .tsm_delete
    mov rax, [rbp - TSM_VAL]
    V_UNPACK rax, rdx           ; dunder_call_3 takes a (payload, tag) arg2
    mov r8d, edx
    mov rdx, rax
    mov rdi, [rbp - TSM_DESC]
    mov rsi, [rbp - TSM_CLS]
    extern dunder_set
    lea rcx, [rel dunder_set]
    extern dunder_call_3
    call dunder_call_3
    jmp .tsm_result
.tsm_delete:
    mov rdi, [rbp - TSM_DESC]
    mov rsi, [rbp - TSM_CLS]
    CSTRING rdx, "__delete__"
    mov ecx, TAG_PTR
    extern dunder_call_2
    call dunder_call_2
.tsm_result:
    DECREF_V rax, rcx           ; the answer is None, or 0 when it raised
.tsm_yes:
    mov eax, 1
    leave
    ret
.tsm_no:
    xor eax, eax
    leave
    ret
END_FUNC ts_meta_descr_set

;; ============================================================================
;; type_meta_data_descr(rdi = a metatype, rsi = a name) -> rax = a BORROWED
;;   data descriptor the metatype's MRO defines under that name, or 0
;;
;; Step one of CPython's type_getattro and of its generic setattr on a type.
;; Only an entry a HEAPTYPE in the metatype's MRO owns counts: `type`'s own
;; getsets (__name__, __module__, __dict__ ...) are answered by
;; type_getattr_meta's ladder and by type_setattr's renames, and reporting
;; them here would hand out the getset instead.  Of what a heaptype holds,
;; a property and an instance of a class with __set__ or __delete__ qualify --
;; the GS_LAYOUT getsets a class body grows are not the class's to offer.
;;
;; Answered through the type cache, so a class whose metaclass defines nothing
;; under the name pays one hashed compare per lookup.
;; ============================================================================
TMD_DESCR equ 8
TMD_FRAME equ 16
DEF_FUNC type_meta_data_descr, TMD_FRAME
    extern type_lookup_cached
    call type_lookup_cached     ; rax = payload, edx = tag, rcx = the owner
    cmp edx, TAG_PTR
    jne .tmd_no
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .tmd_no
    mov rdx, [rax + PyObject.ob_type]
    lea r8, [rel property_type]
    cmp rdx, r8
    je .tmd_yes
    test qword [rdx + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .tmd_no
    mov [rbp - TMD_DESCR], rax
    mov rdi, rax
    extern attr_is_data_descr
    call attr_is_data_descr
    test eax, eax
    jz .tmd_no
    mov rax, [rbp - TMD_DESCR]
.tmd_yes:
    leave
    ret
.tmd_no:
    xor eax, eax
    leave
    ret
END_FUNC type_meta_data_descr

section .rodata
tga_name_str:       db "__name__", 0

section .text
