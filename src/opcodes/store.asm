; opcodes/store.asm - the handlers that write a name, and the ones that unbind it
;
; STORE_FAST/NAME/GLOBAL/ATTR/DEREF and DELETE_DEREF/FAST/NAME/GLOBAL/ATTR/
; SUBSCR, plus sa_try_specialize, which decides whether a STORE_ATTR site
; earns opcode 240.
;
; Split out of load.asm along the seam that file still carried from the
; concatenation it was made by, because load.asm had reached lint's 100k cap
; for a hand-written file and no fix to any handler in it could be written at
; all.  The loads, the attribute protocol they share and the stack shuffles
; stay there; nothing here calls one of its file-local helpers except
; unbound_local_raise, which op_delete_fast needs and which is now global.
;
; Register convention (callee-saved, preserved across handlers):
;   rbx = bytecode instruction pointer (current position in co_code[])
;   r12 = current frame pointer (PyFrame*)
;   r13 = value stack payload top pointer
;   r14 = co_consts tuple data pointer (&tuple.ob_item[0])
;   r15 = free
;
; co_names is accessed via the LOAD_CO_NAMES macro (reads a global).
; ecx = opcode argument on entry (set by eval_dispatch)
; rbx has already been advanced past the 2-byte instruction word.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

extern instance_setattr
extern member_descr_type
extern dict_get_index
extern unbound_local_raise
extern obj_dealloc
extern opcode_dispatch_table
extern opcode_table
extern func_type
extern method_type
extern staticmethod_type
extern classmethod_type
extern none_singleton
extern dunder_get
extern int_type
extern float_type
extern none_type
extern type_lookup_cached
extern rbt_append_cstr
extern attr_may_be_data_descr

extern eval_dispatch
extern obj_decref
extern dict_set
extern dict_type
extern raise_exception
extern eval_exception_unwind
extern obj_incref
extern exc_AttributeError_type
extern exc_TypeError_type
extern exc_NameError_type
extern dict_del
extern dict_get
extern property_type
extern property_descr_set
extern dunder_set
extern dunder_call_3
extern dunder_lookup

section .text

;; --- Named frame-layout constants ---

; op_store_attr: rbp-frame (48 bytes)
SA_OBJ    equ 8
SA_VAL    equ 16
SA_NAME   equ 24
SA_DESC   equ 32    ; general descriptor (MRO walk)
SA_OTAG   equ 40
SA_VTAG   equ 48
SA_EXC    equ 56
SA_ORIGIN equ 64   ; the type the descriptor walk started from
SA_FRAME  equ 88            ; + 0 pushes = 80

; op_delete_attr: rbp-frame (16 bytes)
DA_NAME   equ 8
DA_OBJ    equ 16
DA_EXC    equ 24            ; the exception pending before the deleter ran
DA_FRAME  equ 40            ; + 0 pushes = 32

; op_delete_subscr: rbp-frame (32 bytes)
DS_OBJ    equ 8
DS_KEY    equ 16
DS_OTAG   equ 24
DS_KTAG   equ 32
DS_RET    equ 40            ; what mp_ass_subscript answered, across the DECREFs
DS_FRAME  equ 56            ; + 0 pushes = 56, which is 8 mod 16: a handler is
                            ;   entered aligned, so its calls want the odd frame

;; ============================================================================
;; op_store_fast - Store TOS into localsplus[arg]
;;
;; Pops value from stack, stores in fast local slot, XDECREF old value.
;; VPOP does not clobber ecx (it only does sub r13,8 / mov reg,[r13]).
;; ============================================================================
DEF_FUNC_BARE op_store_fast
    ; ecx = arg (slot index)
    VPOP rax                                          ; new value
    mov rdi, [r12 + PyFrame.localsplus + rcx*8]       ; old value
    mov [r12 + PyFrame.localsplus + rcx*8], rax
    XDECREF_V rdi, r9
    DISPATCH
END_FUNC op_store_fast

;; ============================================================================
;; op_store_name - Store TOS under co_names[arg] in locals or globals dict
;;
;; If frame->locals is not NULL, store there; otherwise store in globals.
;; Uses dict_set(dict, key, value) extern.
;; dict_set signature: dict_set(PyDictObject *dict, PyObject *key, PyObject *value)
;; ============================================================================
DEF_FUNC_BARE op_store_name
    ; ecx = arg (index into co_names)
    ; Get name string before popping (payload array: 8-byte stride)
    shl ecx, 3
    LOAD_CO_NAMES r8
    mov r8, [r8 + rcx]        ; r8 = name (key) - caller-saved, safe temp
    VPOP_VAL r9, r10           ; r9 = value payload, r10 = value tag

    ; Determine target dict: locals if present, else globals
    mov rdi, [r12 + PyFrame.locals]
    test rdi, rdi
    jnz .have_dict
    mov rdi, [r12 + PyFrame.globals]
.have_dict:
    ; A class body prepared by a metaclass executes in whatever mapping
    ; __prepare__ returned, and that mapping's __setitem__ is the whole point
    ; of preparing one -- enum's _EnumDict records every member there.  Writing
    ; straight into dict storage skips it, so anything but an exact dict goes
    ; through mp_ass_subscript.
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel dict_type]
    cmp rax, rcx
    jne .mapping_set

    ; dict_set(dict, key, value, value_tag, key_tag)
    ; rdi = dict (already set)
    mov rsi, r8                ; rsi = name (key)
    mov rdx, r9                ; rdx = value payload
    mov rcx, r10               ; rcx = value tag
    V_PACK rdx, rcx
    push r9
    push r10
    call dict_set
    pop r10
    pop r9
    ; DECREF value to release the stack's reference (dict_set INCREFed it)
    DECREF_VAL r9, r10
    DISPATCH

.mapping_set:
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .have_dict_plain
    mov rax, [rax + PyMappingMethods.mp_ass_subscript]
    test rax, rax
    jz .have_dict_plain
    mov rsi, r8                ; key
    mov rdx, r9
    mov rcx, r10
    V_PACK rdx, rcx            ; value Value
    push r9
    push r10
    call rax
    pop r10
    pop r9
    DECREF_VAL r9, r10
    DISPATCH

.have_dict_plain:
    ; No mapping protocol at all: fall back to writing the dict directly, which
    ; is what it was before and is right for anything dict-shaped.
    mov rsi, r8
    mov rdx, r9
    mov rcx, r10
    V_PACK rdx, rcx
    push r9
    push r10
    call dict_set
    pop r10
    pop r9
    DECREF_VAL r9, r10
    DISPATCH
END_FUNC op_store_name

;; ============================================================================
;; op_store_global - Store TOS under co_names[arg] in globals dict
;;
;; Same as store_name but always uses globals.
;; ============================================================================
DEF_FUNC_BARE op_store_global
    ; ecx = arg (index into co_names, payload array: 8-byte stride)
    shl ecx, 3
    LOAD_CO_NAMES r8
    mov r8, [r8 + rcx]        ; r8 = name (key)
    VPOP_VAL r9, r10           ; r9 = value payload, r10 = value tag

    ; Always store in globals
    mov rdi, [r12 + PyFrame.globals]
    mov rsi, r8                ; rsi = name (key)
    mov rdx, r9                ; rdx = value payload
    mov rcx, r10               ; rcx = value tag
    V_PACK rdx, rcx
    push r9
    push r10
    call dict_set
    pop r10
    pop r9
    ; DECREF value to release the stack's reference (dict_set INCREFed it)
    DECREF_VAL r9, r10
    DISPATCH
END_FUNC op_store_global

;; ============================================================================
;; op_store_attr - Store TOS-1 as attribute of TOS
;;
;; Python 3.12 STORE_ATTR (opcode 95):
;;   ecx = name index in co_names
;;
;; Stack: ... | value | obj |  (obj=TOS, value=TOS-1)
;; Pops obj, pops value, sets obj.name = value via tp_setattr.
;; DECREF obj and value after the store.
;; Followed by 4 CACHE entries (8 bytes) that must be skipped.
;; ============================================================================
DEF_FUNC op_store_attr, SA_FRAME
    mov qword [rbp - SA_ORIGIN], 0
    DUNDER_EXC_SAVE [rbp - SA_EXC]

    ; Get name (payload array: 8-byte stride)
    shl ecx, 3
    LOAD_CO_NAMES rax
    mov rax, [rax + rcx]
    mov [rbp - SA_NAME], rax

    ; Pop obj (TOS)
    VPOP_VAL rdi, rax
    mov [rbp - SA_OBJ], rdi
    mov [rbp - SA_OTAG], rax

    ; Pop value
    VPOP_VAL rdi, rax
    mov [rbp - SA_VAL], rdi
    mov [rbp - SA_VTAG], rax

    ; Non-pointer obj can't have attrs set (SmallInt, Float, None, Bool)
    cmp qword [rbp - SA_OTAG], TAG_PTR
    jne .sa_no_setattr

    ; Check for property/descriptor in type dict (walk MRO) before regular setattr
    mov rdi, [rbp - SA_OBJ]       ; obj
    mov rcx, [rdi + PyObject.ob_type]  ; rcx = type (walks chain)

    ; ...but only when there is one to find.  This walk cost a dict_get per
    ; MRO entry on EVERY store, and instance_setattr walks the same MRO again
    ; straight afterwards -- five dict operations to put a key in an instance
    ; dict.  The flag is the same one the load side uses, maintained by
    ; type_refresh_attr_flags, and a class with no data descriptor in its MRO
    ; cannot have a property or a __set__ to find here.
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_MRO_HAS_DATA_DESCR
    jz .sa_no_property

.sa_walk_mro:
    ; The same question the load side asks, through the same cache: what does
    ; this class define for this name?  Only reached when the flag above says
    ; there is a data descriptor somewhere in the MRO -- but that flag is
    ; per-CLASS, so one property makes every attribute of the class take this
    ; path, and the walk it replaces ran on every store.
    test rcx, rcx
    jz .sa_no_property
    mov rdi, rcx
    mov rsi, [rbp - SA_NAME]
    call type_lookup_cached     ; rax = payload, edx = tag
    test edx, edx
    jnz .sa_found_in_type
    jmp .sa_no_property

.sa_found_in_type:

    ; Check if it's a descriptor (only TAG_PTR can be a descriptor)
    cmp edx, TAG_PTR
    jne .sa_no_property           ; non-pointer — not a descriptor
    mov rcx, [rax + PyObject.ob_type]

    ; Check property first (fast path)
    lea rdx, [rel property_type]
    cmp rcx, rdx
    jne .sa_check_general_set

    ; Found property descriptor — call fset(obj, value, ecx=value_tag)
    mov rdi, rax                  ; property
    mov rsi, [rbp - SA_OBJ]      ; obj
    mov rdx, [rbp - SA_VAL]      ; value
    mov ecx, [rbp - SA_VTAG]     ; value tag
    V_PACK rdx, rcx              ; property_descr_set takes a value Value
    call property_descr_set
    jmp .sa_descr_cleanup

.sa_check_general_set:
    ; Check for general __set__ on heaptype descriptor
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .sa_no_property

    ; Save the descriptor for potential __set__ call
    mov [rbp - SA_DESC], rax      ; save descriptor (borrowed ref, still in dict)

    ; Check if descriptor's type has __set__
    mov rdi, rcx                  ; descriptor's type
    lea rsi, [rel dunder_set]
    call dunder_lookup
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    jz .sa_no_property

    ; Has __set__! Call descriptor.__set__(obj, value)
    mov rdi, [rbp - SA_DESC]     ; descriptor
    mov rsi, [rbp - SA_OBJ]     ; obj
    mov rdx, [rbp - SA_VAL]     ; value
    lea rcx, [rel dunder_set]
    mov r8d, [rbp - SA_VTAG]    ; value tag
    call dunder_call_3
    V_UNPACK rax, rdx           ; returns a Value
    ; DECREF result if non-NULL
    test edx, edx
    jz .sa_descr_cleanup
    DECREF_VAL rax, rdx

.sa_descr_cleanup:

    ; DECREF value (tag-aware)
    mov rdi, [rbp - SA_VAL]
    mov rsi, [rbp - SA_VTAG]
    DECREF_VAL rdi, rsi
    ; DECREF obj (tag-aware)
    mov rdi, [rbp - SA_OBJ]
    mov rsi, [rbp - SA_OTAG]
    DECREF_VAL rdi, rsi

    ; A descriptor __set__ that raised returns normally, leaving the
    ; exception pending; without this it surfaced later at an unrelated
    ; instruction.  Compared against entry, because current_exception is
    ; already set whenever this runs inside an except block.
    DUNDER_RAISED [rbp - SA_EXC], .sa_propagate
    add rbx, 8
    leave
    DISPATCH

.sa_no_property:
    ; Check tp_setattr
    mov rdi, [rbp - SA_OBJ]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_setattr]
    test rax, rax
    jz .sa_no_setattr

    ; Call tp_setattr(obj, name, value, ecx=value_tag)
    mov rdi, [rbp - SA_OBJ]
    mov rsi, [rbp - SA_NAME]
    mov rdx, [rbp - SA_VAL]
    mov ecx, [rbp - SA_VTAG]
    V_PACK rdx, rcx             ; tp_setattr takes a value Value
    call rax

    ; Specialize, now that the store has happened.
    ;
    ; It has to be AFTER rather than before: the first store to an attribute is
    ; the one that creates it, so there is no dense index to cache until this
    ; call has run.  A site whose attribute is created here specializes on its
    ; second execution, which is what `self.x = ...` in __init__ followed by a
    ; loop of `p.x = ...` actually does.
    ;
    ; Nothing here can fail loudly -- every branch out just leaves the site
    ; generic -- so it is written as a straight run of guards.
    mov rdi, [rbp - SA_OBJ]
    mov rsi, [rbp - SA_NAME]
    mov rdx, rbx
    call sa_try_specialize

    ; DECREF value (tag-aware)
    mov rdi, [rbp - SA_VAL]
    mov rsi, [rbp - SA_VTAG]
    DECREF_VAL rdi, rsi
    ; DECREF obj (tag-aware)
    mov rdi, [rbp - SA_OBJ]
    mov rsi, [rbp - SA_OTAG]
    DECREF_VAL rdi, rsi

    DUNDER_RAISED [rbp - SA_EXC], .sa_propagate
    add rbx, 8                ; skip 4 CACHE entries
    leave
    DISPATCH

.sa_propagate:
    ; Same shape as op_call's .propagate_exc: the unwinder reads the current
    ; IP from PyFrame.disp_ip, which DISPATCH set, so rbx is not advanced.
    leave
    PUBLISH_SP
    jmp eval_exception_unwind

.sa_no_setattr:
    RAISE exc_AttributeError_type, "cannot set attribute"
END_FUNC op_store_attr

;; ============================================================================
;; op_store_deref - Store TOS into cell at localsplus[arg]
;;
;; Gets cell from localsplus[arg], sets cell.ob_ref = TOS.
;; Ownership transfers from stack to cell (no INCREF needed).
;; DECREFs old cell value.
;; ============================================================================
DEF_FUNC_BARE op_store_deref
    VPOP rax                       ; new Value
    mov rdx, [r12 + PyFrame.localsplus + rcx*8]  ; cell object

    ; Ownership transfers from stack to cell - no INCREF needed
    mov rdi, [rdx + PyCellObject.ob_ref]        ; old Value
    mov [rdx + PyCellObject.ob_ref], rax
    DECREF_V rdi, rsi
    DISPATCH
END_FUNC op_store_deref

;; ============================================================================
;; op_delete_deref - Set cell at localsplus[arg] to empty (NULL)
;;
;; DECREFs old value if present.
;; ============================================================================
DEF_FUNC_BARE op_delete_deref
    mov rax, [r12 + PyFrame.localsplus + rcx*8]  ; rax = cell object (payload)
    mov rdi, [rax + PyCellObject.ob_ref]
    mov qword [rax + PyCellObject.ob_ref], 0
    DECREF_V rdi, rsi
    DISPATCH
END_FUNC op_delete_deref

;; ============================================================================
;; op_delete_fast - Delete local variable (set localsplus[arg] = NULL)
;;
;; DECREF old value if present.
;; ============================================================================
DEF_FUNC_BARE op_delete_fast
    mov rdi, [r12 + PyFrame.localsplus + rcx*8]       ; old value
    ; Deleting a local that was never bound is an UnboundLocalError, not a
    ; no-op: `def f(): del y; y = 1` used to succeed silently.
    test rdi, rdi
    jz .dfa_unbound
    mov qword [r12 + PyFrame.localsplus + rcx*8], 0
    XDECREF_V rdi, rsi
    DISPATCH
.dfa_unbound:
    mov edi, ecx
    call unbound_local_raise    ; does not return
END_FUNC op_delete_fast

;; ============================================================================
;; op_delete_name - Delete name from locals or globals dict
;; ============================================================================
DEF_FUNC_BARE op_delete_name
    shl ecx, 3                ; payload array: 8-byte stride
    LOAD_CO_NAMES rsi
    mov rsi, [rsi + rcx]      ; name
    ; The frame's locals, and ONLY those when it has some: CPython's
    ; DELETE_NAME is a delete from f_locals and a NameError when it misses.
    ; Falling through to globals meant `class C: del g` deleting a module
    ; global -- silently, and leaving nothing behind to say so.  A frame with
    ; no locals dict of its own is the module case, where the two are the
    ; same mapping anyway.
    mov rdi, [r12 + PyFrame.locals]
    test rdi, rdi
    jz .dn_globals
    ; ...and they need not be a DICT: exec() takes any mapping, and a class
    ; body runs in whatever __prepare__ returned.  dict_del_opt read the
    ; object's header as a hash table.  Anything but an exact dict goes
    ; through mp_ass_subscript with a NULL value, which is how CPython's
    ; PyObject_DelItem spells a delete -- and it is also what makes a custom
    ; mapping's __delitem__ run at all.
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel dict_type]
    cmp rax, rcx
    jne .dn_mapping
    sub rsp, 8                 ; pad: rsp is 16-aligned on entry to a
                               ; handler, so a call needs an even push list
    push rsi
    extern dict_del_opt
    call dict_del_opt
    pop rsi
    add rsp, 8
    test eax, eax
    jz .dn_ok                  ; found and deleted
    jmp .dn_error

.dn_mapping:
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .dn_error
    mov rax, [rax + PyMappingMethods.mp_ass_subscript]
    test rax, rax
    jz .dn_error
    sub rsp, 8
    push rsi
    xor edx, edx               ; a NULL value is a delete
    call rax
    pop rsi
    add rsp, 8
    ; A mapping that refuses has already raised, and slot_mp_ass_subscript
    ; does not even return in that case; there is nothing to report here.
    jmp .dn_ok
.dn_globals:
    mov rdi, [r12 + PyFrame.globals]
    sub rsp, 8                 ; pad: rsp is 16-aligned on entry to a
                               ; handler, so a call needs an even push list
    push rsi
    call dict_del_opt
    pop rsi
    add rsp, 8
    test eax, eax
    jnz .dn_error
.dn_ok:
    DISPATCH
.dn_error:
    call name_error_raise      ; does not return
END_FUNC op_delete_name

;; ============================================================================
;; op_delete_global - Delete name from globals dict
;; ============================================================================
DEF_FUNC_BARE op_delete_global
    shl ecx, 3                ; payload array: 8-byte stride
    LOAD_CO_NAMES rsi
    mov rsi, [rsi + rcx]      ; name
    mov rdi, [r12 + PyFrame.globals]
    sub rsp, 8                 ; pad: rsp is 16-aligned on entry to a
                               ; handler, so a call needs an even push list
    push rsi
    extern dict_del_opt
    call dict_del_opt
    pop rsi
    add rsp, 8
    test eax, eax
    jnz .dg_error
    DISPATCH
.dg_error:
    call name_error_raise      ; does not return
END_FUNC op_delete_global

;; ============================================================================
;; name_error_raise(rsi = the name string) -- does not return
;; "name 'g' is not defined", which is CPython's wording and names the name.
;; ============================================================================
NER_BUF   equ 264
NER_FRAME equ 272           ; + 0 pushes = 272
DEF_FUNC_LOCAL name_error_raise, NER_FRAME
    mov r8, rsi
    lea rdi, [rel ner_buf_open]
    mov rsi, r8
    lea rdi, [rbp - NER_BUF]
    lea rsi, [rel ner_buf_open]
    call rbt_append_cstr
    mov rdi, rax
    test r8, r8
    jz .ner_no_name
    lea rsi, [r8 + PyStrObject.data]
    jmp .ner_have_name
.ner_no_name:
    lea rsi, [rel ner_unknown]
.ner_have_name:
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel ner_close]
    call rbt_append_cstr
    lea rdi, [rel exc_NameError_type]
    lea rsi, [rbp - NER_BUF]
    call raise_exception
    ud2
END_FUNC name_error_raise

section .rodata
ner_buf_open: db "name '", 0
ner_close:    db "' is not defined", 0
ner_unknown:  db "?", 0
section .text

;; ============================================================================
;; op_delete_attr - Delete attribute from object
;;
;; Calls tp_setattr(obj, name, NULL) to delete.
;; Followed by 4 CACHE entries (8 bytes) - WAIT, DELETE_ATTR has no CACHE in 3.12.
;; ============================================================================
DEF_FUNC op_delete_attr, DA_FRAME

    shl ecx, 3                ; payload array: 8-byte stride
    LOAD_CO_NAMES rax
    mov rax, [rax + rcx]      ; name
    mov [rbp - DA_NAME], rax

    VPOP_VAL rdi, rax
    mov [rbp - DA_OBJ], rdi

    ; Non-pointer obj can't have attrs deleted
    cmp rax, TAG_PTR
    jne .da_error

    ; Call tp_setattr(obj, name, NULL) to delete attr
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_setattr]
    test rax, rax
    jz .da_error

    mov rdi, [rbp - DA_OBJ]
    mov rsi, [rbp - DA_NAME]
    xor edx, edx               ; value = NULL means delete
    xor ecx, ecx               ; value tag = TAG_NULL
    DUNDER_EXC_SAVE [rbp - DA_EXC]
    call rax

    ; DECREF obj
    mov rdi, [rbp - DA_OBJ]
    call obj_decref

    ; A deleter that raised returns normally, leaving the exception pending;
    ; without this `del c.v` swallowed it and it surfaced somewhere else.
    ; Compared against entry, because current_exception is already set
    ; whenever this runs inside an except block.
    DUNDER_RAISED [rbp - DA_EXC], .da_propagate
    leave
    DISPATCH

.da_propagate:
    ; Same shape as .sa_propagate: the unwinder reads the current IP from
    ; PyFrame.disp_ip, which DISPATCH set, so rbx is not advanced.
    leave
    PUBLISH_SP
    jmp eval_exception_unwind

.da_error:
    ; The object is NOT released here, and this is the whole shape of the bug
    ; that used to live at this label.  VPOP_VAL only moved r13; the slot
    ; still holds the pointer, and eval_exception_unwind restores r13 from
    ; PyFrame.disp_sp -- what DISPATCH published BEFORE the pop -- and releases
    ; everything above the handler's depth.  Decref'ing here as well freed it
    ; while the unwinder was still holding it, and `del range(i).start` in a
    ; loop corrupted the heap.  op_store_attr's .sa_no_setattr, which is the
    ; same branch of the same question, has always got this right.
    RAISE exc_AttributeError_type, "cannot delete attribute"
END_FUNC op_delete_attr

;; ============================================================================
;; op_delete_subscr - Delete obj[key]
;;
;; Pops key (TOS), pops obj (TOS1).
;; Calls mp_ass_subscript(obj, key, NULL) to delete.
;; ============================================================================
DEF_FUNC op_delete_subscr, DS_FRAME

    VPOP_VAL rsi, rax            ; key + tag
    VPOP_VAL rdi, rcx            ; obj + tag
    mov [rbp - DS_OBJ], rdi     ; save obj
    mov [rbp - DS_KEY], rsi     ; save key
    mov [rbp - DS_OTAG], rcx    ; save obj tag
    mov [rbp - DS_KTAG], rax    ; save key tag

    ; Non-pointer obj can't have items deleted
    cmp qword [rbp - DS_OTAG], TAG_PTR
    jne .ds_error

    ; Call mp_ass_subscript(obj, key Value, NULL) -- a NULL value means delete
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .ds_error
    mov rax, [rax + PyMappingMethods.mp_ass_subscript]
    test rax, rax
    jz .ds_error

    mov rcx, [rbp - DS_KTAG]
    V_PACK rsi, rcx            ; key Value
    xor edx, edx               ; value = 0 (delete)
    call rax
    movsxd rax, eax
    mov [rbp - DS_RET], rax    ; DECREF_VAL below clobbers it

    ; DECREF key and obj (tag-aware)
    mov rdi, [rbp - DS_KEY]
    mov rsi, [rbp - DS_KTAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rbp - DS_OBJ]
    mov rsi, [rbp - DS_OTAG]
    DECREF_VAL rdi, rsi

    ; Most of the tree's mp_ass_subscript implementations raise and never come
    ; back, which is why this used to discard the answer.  array's reports
    ; failure the other way -- SET_EXC and -1 -- and discarding that meant a
    ; refused delete simply did not happen, with the exception left pending to
    ; surface at whatever opcode ran next: `del a[99]` printed nothing at all
    ; and an IndexError arrived from somewhere else later.
    cmp qword [rbp - DS_RET], 0
    jl .ds_raised

    leave
    DISPATCH

.ds_raised:
    ; Same shape as .da_propagate: DISPATCH saved the stack top from BEFORE
    ; the two operands came off it, and the unwinder cleans up from there --
    ; so jumping without republishing r13 released both a second time.  A
    ; refused `del a[99]` on an array freed the array's own header and printed
    ; `array('[', [1675724320, 32139, 3])`.
    leave
    PUBLISH_SP
    jmp eval_exception_unwind

.ds_error:
    RAISE exc_TypeError_type, "object does not support item deletion"
END_FUNC op_delete_subscr

;; ============================================================================
;; sa_try_specialize(rdi = the object, rsi = the name, rdx = the bytecode IP)
;;   -> nothing
;;
;; Install STORE_ATTR_INSTANCE at the site rdx points into, if the store that
;; just happened was an ordinary write into an instance dict.  Every check that
;; fails simply returns and leaves the site generic.
;;
;; It runs AFTER the store rather than before, because the first store to an
;; attribute is the one that creates it: there is no dense index to cache until
;; tp_setattr has run.  A site specializes on its second execution, which is
;; what `self.x = ...` in __init__ followed by a loop of `p.x = ...` does.
;;
;; The key comparison is the one that matters most.  dict_set keeps the FIRST
;; writer's key object, so an attribute created under a name that is not the
;; interned constant -- setattr(o, "".join(...), 1) -- can never satisfy the
;; handler's pointer guard.  Refusing to install here is what stops such a site
;; specializing and deopting on every execution for ever, which is the shape
;; bugs.md records on the load side.
;;
;; A type whose version is zero is never cached.  That is a static type, and
;; its instances have no instance dict to write into.
;; ============================================================================
STS_IP  equ 8
STS_VER equ 16
STS_FRAME equ 24                    ; 24 + 3 pushes keeps rsp 16-aligned

; The fourth CACHE word is a backoff counter, and it is what stops a site
; that can never hit from rewriting its own instruction stream forever.  A
; STORE_ATTR inside an __init__ is exactly that site: the handler's second
; guard wants the cached dense index to be inside dk_nentries, and the object
; being constructed has an empty instance dict or none at all, so the cache
; misses on the very store that installed it.  Before this, every constructed
; object cost two writes into the bytecode buffer -- specialize, deopt,
; specialize -- for a cache that was never once going to answer.  CPython
; spells the same idea ADAPTIVE_BACKOFF_*.
STS_BACKOFF equ 6                   ; CACHE[+6], a word; +0 and +4 are in use
STS_BACKOFF_N equ 63                ; executions to skip after a deopt

DEF_FUNC_LOCAL sa_try_specialize, STS_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - STS_IP], rdx
    ; Still backing off from a deopt?  Count down and leave the site alone.
    movzx eax, word [rdx + STS_BACKOFF]
    test eax, eax
    jz .sts_no_backoff
    dec eax
    mov [rdx + STS_BACKOFF], ax
    jmp .sts_out
.sts_no_backoff:
    mov r12, rdi                    ; the object
    mov r13, rsi                    ; the name
    V_TEST_PTR r12, rax
    ja .sts_out

    ; An ordinary instance store: no __setattr__ of the class's own.
    mov rax, [r12 + PyObject.ob_type]
    lea rcx, [rel instance_setattr]
    cmp [rax + PyTypeObject.tp_setattr], rcx
    jne .sts_out

    ; The version the handler will guard on.
    mov rcx, [rax + PyTypeObject.tp_flags]
    shr rcx, TYPE_VERSION_SHIFT
    test ecx, ecx
    jz .sts_out
    mov [rbp - STS_VER], ecx

    ; And nothing in the MRO able to outrank the instance dict FOR THIS NAME.
    ; That used to be asked as TYPE_FLAG_MRO_HAS_DATA_DESCR, which is
    ; per-CLASS: one @property anywhere in the MRO refused STORE_ATTR_INSTANCE
    ; for every other attribute of the class and of every subclass, so an
    ; ordinary object with one computed field ran the generic handler for all
    ; of its plain writes.  The load side asks per name a few hundred lines
    ; above; the store side is the same question with the same answer.
    ;
    ; A __slots__ member descriptor is a data descriptor too, and refusing it
    ; here is what keeps the handler -- which writes into the instance dict --
    ; away from a name that lives in a slot.
    ;
    ; attr_may_be_data_descr, not attr_is_data_descr: a descriptor's own type
    ; can gain __set__ long after the class holding it was stamped.  Asked
    ; once, at install; the version guard is what keeps the answer true.
    mov rdi, rax
    mov rsi, r13
    call type_lookup_cached         ; rax = payload, edx = tag
    test edx, edx
    jz .sts_name_free               ; the MRO does not define it at all
    cmp edx, TAG_PTR
    jne .sts_name_free              ; and an immediate is never a descriptor
    mov rdi, rax

    ; A __slots__ member is a data descriptor too, and refusing it above is
    ; what keeps STORE_ATTR_INSTANCE -- which writes into the instance dict --
    ; away from a name that lives in a slot.  But a slot has a cache of its
    ; own, and a simpler one: the offset is fixed by the CLASS, so there is no
    ; index to distrust and no key to compare, and the same version guard
    ; covers it.  Without this a class with __slots__ specialized nothing at
    ; all, and every `self.x = v` in its __init__ ran the generic handler.
    mov rcx, [rdi + PyObject.ob_type]
    lea rdx, [rel member_descr_type]
    cmp rcx, rdx
    je .sts_member

    call attr_may_be_data_descr
    test eax, eax
    jnz .sts_out
    jmp .sts_name_free

.sts_member:
    ; The offset has to fit the 16-bit cache field, and it is SIGNED: a str
    ; subclass addresses its slots from the tail with a negative one.  An
    ; instance is never big enough for it not to fit, but an offset that did
    ; not would be silently truncated, so it is checked rather than assumed.
    mov rax, [rdi + PyMemberDescrObject.md_offset]
    movsx rdx, ax
    cmp rdx, rax
    jne .sts_out
    mov rcx, [rbp - STS_IP]
    mov edx, [rbp - STS_VER]
    mov dword [rcx], edx
    mov word [rcx + 4], ax
    mov byte [rcx - 2], OP_STORE_ATTR_SLOT
    jmp .sts_out

.sts_name_free:

    LOAD_INST_DICT rbx, r12, .sts_out
    test rbx, rbx
    jz .sts_out

    ; Where the name sits in the dense array.
    mov rdi, rbx
    mov rsi, r13
    xor edx, edx
    call dict_get_index
    test rax, rax
    js .sts_out
    cmp rax, 0xFFFF                 ; the cache field is 16 bits wide
    jae .sts_out
    mov r12, rax                    ; the index

    ; And whether that entry is keyed by the very object co_names holds.
    mov rdx, [rbx + PyDictObject.entries]
    imul rax, rax, DICT_ENTRY_SIZE
    add rdx, rax
    cmp r13, [rdx + DictEntry.key]
    jne .sts_out
    cmp qword [rdx + DictEntry.value], 0
    je .sts_out

    ; Install: version, index, then the opcode byte last.
    mov rcx, [rbp - STS_IP]
    mov eax, [rbp - STS_VER]
    mov dword [rcx], eax
    mov word [rcx + 4], r12w
    mov byte [rcx - 2], OP_STORE_ATTR_INSTANCE

.sts_out:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sa_try_specialize
