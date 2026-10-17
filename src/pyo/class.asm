; pyo/class.asm - Class instances and bound methods for apython
; Phase 10: class instantiation, attribute access, __init__ dispatch

%include "macros.inc"
%include "object.inc"
extern type_number_methods
extern type_refresh_attr_flags

extern gc_alloc
extern gc_track
extern gc_dealloc
extern ap_free
extern obj_decref
extern obj_dealloc
extern raise_exception
extern none_singleton
extern obj_incref
extern dict_new
extern dict_get
extern dict_set
extern str_from_cstr
extern str_from_cstr_heap
extern type_getattr
extern type_getattr_meta
extern type_lookup_cached
extern dunder_name_obj
extern ap_strcmp
extern type_repr
extern attr_error_pending
extern exc_AttributeError_type
extern exc_TypeError_type
extern func_type
extern type_type
extern kw_names_pending
extern eval_exception_unwind
extern sub_list_for_type
extern object_method_getattribute
extern dunder_get
extern dunder_call_3
extern dunder_lookup
extern dunder_call_2
extern builtin_func_type
extern current_exception
extern dict_type
extern tuple_type
extern int_type
extern str_type
extern staticmethod_type
extern method_new
extern instance_new
extern int_sub_new
extern str_sub_new
extern tuple_sub_fill
extern builtin_sub_init_base
extern classmethod_type
extern property_type


;; ============================================================================
;; instance_dealloc(PyObject *self)
;; Deallocate an instance: DECREF inst_dict, DECREF ob_type, free self.
;; rdi = instance
;; ============================================================================

;; ============================================================================
;; obj_call_finalizer(rdi = obj) -> void
;;
;; CPython's PyObject_CallFinalizer: run __del__ once, with the object held
;; alive for the duration and the pending exception put back the way it was.
;;
;; Answers eax = 1 when the object still has references after the call.  A
;; caller that is DEALLOCATING it -- where the refcount was zero on the way in
;; -- reads that as resurrection and must free nothing: __del__ stored `self`
;; somewhere, and that somewhere is a live reference.  That is CPython's
;; PyObject_CallFinalizerFromDealloc, which is the same arithmetic entered at
;; zero.  The collector calls this on an object that is in a cycle and so has
;; references either way; it ignores the answer and lets the resurrection pass
;; decide.
;;
;; It is a function of its own because the COLLECTOR calls it too.  PEP 442
;; says the finalizers of an unreachable cycle all run before any of it is
;; cleared -- otherwise __del__ is handed an object whose attributes have
;; already been dropped, and anything it resurrects has been freed underneath
;; the reference it was just given.  The caller is what decides "once": the
;; FINALIZED bit in the object's GC head.
;; ============================================================================
OCF_EXC   equ 8
OCF_OWNED equ 16          ; whether the reference below is ours to drop
OCF_FRAME equ 24          ; + 1 push = 32
DEF_FUNC obj_call_finalizer, OCF_FRAME
    push rbx
    mov rbx, rdi

    ; Temporarily bump refcount to prevent re-entrant dealloc during __del__
    inc qword [rbx + PyObject.ob_refcnt]

    ; Call __del__(self) — dunder_call_1 handles lookup + call
    extern dunder_del
    extern dunder_call_1
    ; Snapshot what was pending, and hold a reference to it: if __del__ raises,
    ; installing its exception releases the global's reference to this one, and
    ; the saved pointer would be dangling by the time it is put back.
    DUNDER_EXC_SAVE [rbp - OCF_EXC]
    mov qword [rbp - OCF_OWNED], 0
    mov rdi, [rbp - OCF_EXC]
    test rdi, rdi
    jz .del_nothing_pending
    ; ...but only when the global's own reference is real.  The unwinder can
    ; reach here with current_exception pointing at an object whose refcount
    ; is already zero, and taking and dropping a reference on that one frees
    ; an exception that is still being carried.
    ;
    ; No path produces that state today: the case bugs.md used to carry does
    ; not reproduce, valgrind is clean over the async suite, and a watch here
    ; gets no hits across the corpus.  The check stays anyway.  It is two
    ; instructions, and the invariant behind it is genuinely fragile --
    ; raise_exception_obj takes over its caller's reference rather than
    ; adding one, so the global's is often the only reference there is, and
    ; this function runs while the unwinder is releasing the value stack.
    cmp qword [rdi + PyObject.ob_refcnt], 0
    jle .del_nothing_pending
    call obj_incref
    mov qword [rbp - OCF_OWNED], 1
.del_nothing_pending:
    mov rdi, rbx
    lea rsi, [rel dunder_del]
    call dunder_call_1
    V_UNPACK rax, rdx           ; returns a Value
    ; Ignore return value — DECREF if non-NULL
    test edx, edx
    jz .del_no_result
    DECREF_VAL rax, rdx
.del_no_result:

    ; A __del__ that raises must not leave the exception pending: the object is
    ; being freed, there is no caller to hand it to, and leaving it set means
    ; the *next* raise silently discards it -- or, if this dealloc came from
    ; the unwinder dropping the value stack, that the handler receives the
    ; wrong exception object.  CPython reports it and puts back what was there.
    ;
    ; "Did it raise?" is EXC_RAISED_SINCE's three-way question and not a bare
    ; inequality.  current_exception is also the exception being HANDLED, and a
    ; __del__ that raises and catches internally leaves the global at 0: a
    ; change, but not a raise.  DUNDER_RAISED read that as one, and this arm
    ; then zeroed the global -- destroying the exception the interpreter was
    ; carrying, so that a __del__ running during an unwind made the enclosing
    ; except block never run.
    EXC_RAISED_SINCE [rbp - OCF_EXC], rax, .del_report

.del_restore:
    ; Whatever __del__ left behind, the pending exception goes back to what it
    ; was.  The reference taken above is what the global gets; anything else
    ; sitting there is released.
    mov rax, [rbp - OCF_EXC]
    cmp [rel current_exception], rax
    je .del_drop_saved
    mov rdi, [rel current_exception]
    mov [rel current_exception], rax    ; the saved reference moves in here
    test rdi, rdi
    jz .del_cleared
    call obj_decref
    jmp .del_cleared
.del_drop_saved:
    ; Unchanged, so the global still owns its own; drop the extra one.
    cmp qword [rbp - OCF_OWNED], 0
    je .del_cleared
    mov rdi, rax
    test rdi, rdi
    jz .del_cleared
    call obj_decref

.del_cleared:

    ; Undo the bump, without deallocating: whether anything is left is the
    ; answer this function gives.
    dec qword [rbx + PyObject.ob_refcnt]
    xor eax, eax
    cmp qword [rbx + PyObject.ob_refcnt], 0
    setne al

    pop rbx
    leave
    ret

.del_report:
    ; A genuinely new exception: report it in full on stderr -- the object it
    ; came out of, and the traceback of where inside __del__ it happened --
    ; then put back the old one.  This used to be one line that named neither.
    ; CPython names the __del__ FUNCTION, not the object it was called on.
    ; The lookup is borrowed, and cannot raise: it just found this method.
    mov rdi, [rbx + PyObject.ob_type]
    lea rsi, [rel dunder_del]
    call dunder_lookup
    V_UNPACK rax, rdx
    cmp edx, TAG_PTR
    je .del_report_have_fn
    xor eax, eax
.del_report_have_fn:
    mov rsi, rax
    mov rdi, [rel current_exception]
    extern traceback_print_unraisable
    call traceback_print_unraisable
    jmp .del_restore
END_FUNC obj_call_finalizer

ID_EXC   equ 8
ID_OWNED equ 16          ; whether the reference below is ours to drop
ID_FRAME equ 24             ; + 1 push = 32
DEF_FUNC instance_dealloc, ID_FRAME
    push rbx

    mov rbx, rdi                ; rbx = self

    ; __del__ has already run by now: obj_dealloc calls the finalizer before
    ; it clears the weak references and before it reaches this tp_dealloc,
    ; which is the order PEP 442 asks for and the order that lets an object
    ; its own finalizer resurrects keep the weakrefs that pointed at it.  If
    ; it did resurrect, obj_dealloc returned and this never ran at all.

    ; Check if this is an int subclass — XDECREF int_value (tag-aware)
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_INT_SUBCLASS
    jz .no_int_value
    mov rdi, [rbx + PyIntSubclassObject.int_value]
    V_UNPACK rdi, rsi
    DECREF_VAL rdi, rsi
.no_int_value:

    ; DECREF_VAL each __slots__ slot.  Slots start after the whole instance
    ; header, which for a container subclass is the embedded base plus the
    ; dict word -- not PyInstanceObject_size.  Assuming the latter made a
    ; list subclass treat its own `allocated` and `ob_item` fields as slot
    ; values and DECREF them.
    push r12
    mov rax, [rbx + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_dictoffset]
    test rcx, rcx
    jz .id_no_dict_hdr
    cmp rcx, TP_DICT_AT_TAIL
    je .id_no_dict_hdr          ; the dict is past the data, not in the header
    add rcx, 8
    ; A base's slots are BELOW the dict word when the subclass is the one that
    ; added the dict: `class C: __slots__ = ('a',)` puts a at 16 and `class
    ; D(C): pass` puts D's dict at 24, so starting past the dict found no
    ; slots at all and D never released C's.  The floor is the family's, and
    ; the walk skips the dict word wherever it sits.
    push rax
    push rcx
    mov rdi, rax
    call instance_slot_floor
    mov rdx, rax
    pop rcx
    pop rax
    test rdx, rdx
    jz .id_have_hdr
    cmp rdx, rcx
    jae .id_have_hdr
    mov rcx, rdx
    ; ...but the header does not end at the dict word when the layout base
    ; keeps fields of its own PAST it.  _io.FileIO is built by
    ; type_from_parts and then has its tp_basicsize patched up to make room
    ; for the descriptor, the flags, the name, the blksize and the mode --
    ; all above tp_dictoffset + 8.  `class F(_io.FileIO): pass` therefore
    ; walked five of FileIO's own fields as if they were __slots__ Values and
    ; XDECREF'd them: a file descriptor of 3 is `dec qword [3]`, a wild write
    ; on ordinary single inheritance with no __slots__ anywhere.
    ;
    ; tp_base is the layout base -- the type whose fields sit below the
    ; subclass's own slots -- so its basicsize is the real floor.
    jmp .id_have_hdr
.id_no_dict_hdr:
    ; No dict word: a str subclass, whose header is the base's, not
    ; PyInstanceObject's.  Using 24 there found a phantom slot at +24 --
    ; PyStrObject.ob_hash -- and XDECREF'd the hash as if it were a pointer.
    push rax
    mov rdi, rax
    call instance_slot_floor
    mov rcx, rax
    pop rax
    test rcx, rcx
    jnz .id_have_hdr
    mov rcx, OBJ_HEADER_SIZE
.id_have_hdr:
    push r13
    mov r13, [rax + PyTypeObject.tp_dictoffset]
    cmp r13, TP_DICT_AT_TAIL
    jne .id_dict_off_ok
    xor r13d, r13d              ; nothing in the header to skip
.id_dict_off_ok:
    mov rax, [rax + PyTypeObject.tp_basicsize]
    cmp rax, rcx
    jbe .id_slots_done          ; no slots
    ; Downwards, from the most derived class's slots to the base's, which is
    ; the order CPython releases them in and therefore the order two __del__s
    ; run in.
    mov r12, rax
.slot_decref_loop:
    sub r12, 8
    cmp r12, rcx
    jb .id_slots_done
    cmp r12, r13
    je .slot_decref_loop        ; the instance dict, released above
    push rcx
    lea rdi, [rbx + r12]
    mov rdi, [rdi]              ; slot Value
    XDECREF_V rdi, rsi
    pop rcx
    jmp .slot_decref_loop
.id_slots_done:
    pop r13

    ; And the slots that live at the TAIL, which a str subclass's do: past
    ; the characters and past the word the tail __dict__ occupies.  They are
    ; not in the header at all, so the walk above cannot reach them.
    mov rax, [rbx + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_tailslots]
    test rcx, rcx
    jz .id_tail_done
    INST_DICT_TAIL r12, rbx
    lea r12, [r12 + rcx*8]      ; the last one; downwards, as above
.id_tail_loop:
    push rcx
    mov rdi, [r12]
    XDECREF_V rdi, rsi
    pop rcx
    sub r12, 8
    dec rcx
    jnz .id_tail_loop
.id_tail_done:

.no_slots:
    pop r12

    ; XDECREF the instance dict; a type may have no dict slot at all.  AFTER
    ; the slots, which is the order CPython's subtype_dealloc uses and so the
    ; order two __del__s run in.  The slot walk skips this word.
    LOAD_INST_DICT rdi, rbx, .no_dict
    test rdi, rdi
    jz .no_dict
    call obj_decref
.no_dict:

    ; A bytearray subclass owns a second allocation -- its bytes -- that the
    ; slot walk above knows nothing about, and the base's own dealloc never
    ; runs for a subclass.  Every instance leaked its buffer.
    mov rax, [rbx + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_BYTEARRAY_SUBCLASS
    jz .id_no_bytes
    mov rdi, [rbx + PyByteArrayObject.ob_bytes]
    test rdi, rdi
    jz .id_no_bytes
    mov qword [rbx + PyByteArrayObject.ob_bytes], 0
    mov qword [rbx + PyByteArrayObject.ob_cap], 0
    mov qword [rbx + PyByteArrayObject.ob_size], 0
    extern ap_free
    call ap_free
.id_no_bytes:

    ; The same shape for the three containers that keep their storage out of
    ; line.  A dict, list or set subclass instance owns tables the slot walk
    ; above knows nothing about, and the base's own dealloc never runs for a
    ; subclass -- so every instance leaked both its contents and its tables:
    ; `class D(dict): pass` leaked 256 bytes per D(), and a list or set
    ; subclass the same in its own currency.  The contents go through the
    ; type's existing tp_clear, which is exactly "release everything held and
    ; leave the tables empty"; the tables are freed here afterwards.
    mov rax, [rbx + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_flags]
    test rcx, TYPE_FLAG_DICT_SUBCLASS
    jnz .id_dict_storage
    test rcx, TYPE_FLAG_LIST_SUBCLASS
    jnz .id_list_storage
    test rcx, TYPE_FLAG_SET_SUBCLASS
    jnz .id_set_storage
    test rcx, TYPE_FLAG_TUPLE_SUBCLASS
    jnz .id_tuple_storage
    jmp .id_no_storage

.id_tuple_storage:
    ; tuple_sub_fill gives a subclass instance its own ob_item array and
    ; INCREFs every element into it.  tuple has no tp_clear to borrow, so the
    ; walk is written out.  Only when ob_size is positive: tuple_sub_fill
    ; allocates nothing for an empty one and leaves ob_item unwritten, so
    ; there is nothing there to read, let alone free.
    ;
    ; r12 and r13 belong to the caller here -- instance_dealloc saves only
    ; rbx -- so they are pushed around the loop rather than simply used.
    mov rax, [rbx + PyTupleObject.ob_size]
    test rax, rax
    jle .id_no_storage
    push r12
    push r13
    mov r12, rax
    xor r13d, r13d
.id_tuple_loop:
    cmp r13, r12
    jge .id_tuple_free
    mov rax, [rbx + PyTupleObject.ob_item]
    mov rdi, [rax + r13*8]
    XDECREF_V rdi, rsi
    inc r13
    jmp .id_tuple_loop
.id_tuple_free:
    mov qword [rbx + PyTupleObject.ob_size], 0
    mov rdi, [rbx + PyTupleObject.ob_item]
    mov qword [rbx + PyTupleObject.ob_item], 0
    pop r13
    pop r12
    test rdi, rdi
    jz .id_no_storage
    call ap_free
    jmp .id_no_storage

.id_dict_storage:
    ; dict_clear_gc releases the table as well as the contents -- an emptied
    ; dict is handed back to the shared empty one -- so there is nothing left
    ; here to free.  Freeing it anyway handed free() a static address.
    extern dict_clear_gc
    mov rdi, rbx
    call dict_clear_gc
    jmp .id_no_storage

.id_list_storage:
    extern list_clear
    mov rdi, rbx
    call list_clear
    mov rdi, [rbx + PyListObject.ob_item]
    test rdi, rdi
    jz .id_no_storage
    mov qword [rbx + PyListObject.ob_item], 0
    mov qword [rbx + PyListObject.ob_size], 0
    call ap_free
    jmp .id_no_storage

.id_set_storage:
    extern set_clear_gc
    mov rdi, rbx
    call set_clear_gc
    mov rdi, [rbx + PyDictObject.entries]
    test rdi, rdi
    jz .id_no_storage
    ; Not the shared empty table, which lives in .rodata and belongs to no
    ; set: `S().clear()` installs it, and freeing it handed free() a static
    ; address -- "free(): invalid pointer", and the process aborted.
    ; set_dealloc has this check; instance_dealloc, which is what runs for a
    ; SUBCLASS of set, did not.  The dict arm above says the same thing.
    extern set_empty_entries
    lea rax, [rel set_empty_entries]
    cmp rdi, rax
    je .id_set_shared
    mov qword [rbx + PyDictObject.entries], 0
    mov qword [rbx + PyDictObject.capacity], 0
    call ap_free
    jmp .id_no_storage
.id_set_shared:
    mov qword [rbx + PyDictObject.entries], 0
    mov qword [rbx + PyDictObject.capacity], 0

.id_no_storage:

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
;; instance_repr(PyObject *self) -> PyStrObject*
;; Try __repr__ dunder, fall back to "<instance>".
;; rdi = instance
;; ============================================================================
;; ============================================================================
;; base_slot(rdi = type, rsi = slot byte offset) -> rax = the slot, or 0
;;
;; Walk past the heaptypes in the tp_base chain to the concrete builtin
;; underneath and read one of its slots.  A subclass of list embeds a list,
;; so printing it should print the list -- "<instance>" is only right for a
;; class that derives from object.
;; ============================================================================
DEF_FUNC base_slot
.bs_walk:
    mov rdi, [rdi + PyTypeObject.tp_base]
    test rdi, rdi
    jz .bs_none
    mov rax, [rdi + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_HEAPTYPE
    jnz .bs_walk
    mov rax, [rdi + rsi]
    leave
    ret
.bs_none:
    xor eax, eax
    leave
    ret
END_FUNC base_slot

IR_EXC   equ 8
IR_ASSTR equ 16            ; 1 when str() sent us here, so a non-str answer is
                           ; reported as __str__ and not as __repr__
IR_FRAME equ 24            ; + 1 push = 32, 16-aligned

;; ============================================================================
;; instance_repr(rdi = an instance) -> (rax = a str, edx = TAG_PTR), or (0, 0)
;;
;; `Foo.__repr__ = Foo.__str__` makes the two chase each other: instance_repr
;; finds __repr__, which is object.__str__, which asks for __repr__ again.  No
;; Python frame is entered anywhere in that loop, so recursion_depth never
;; moved and the machine stack ran out -- CPython raises RecursionError, and
;; its test_descr.test_repr_as_str (issue 11603) is the test for it.
;;
;; The body is wrapped so its several exits need not each be touched, as
;; list_richcompare is.  A NULL rather than a raise, so the container reprs
;; still get to free their buffers on the way out.
;; ============================================================================
extern c_recursion_depth
extern recursion_limit
extern exc_RecursionError_type
extern set_exception
DEF_FUNC instance_repr
    xor esi, esi                ; repr() asked, so report __repr__
    C_RECURSION_ENTER .ir_too_deep
    call instance_repr_inner
    C_RECURSION_LEAVE
    leave
    ret
.ir_too_deep:
    C_RECURSION_LEAVE
    SET_EXC exc_RecursionError_type, \
            "maximum recursion depth exceeded while getting the repr of an object"
    RET_NULL
    leave
    ret
END_FUNC instance_repr

;; ============================================================================
;; instance_repr_as_str(rdi = an instance) -> the same as instance_repr
;;
;; What str() falls back to when the class has no __str__ of its own.  It is
;; instance_repr with one difference, and the difference is only in the
;; message a non-str answer gets: CPython checks that result at the str()
;; level, so it says "__str__ returned non-string".
;; ============================================================================
DEF_FUNC_LOCAL instance_repr_as_str
    mov esi, 1
    C_RECURSION_ENTER .iras_too_deep
    call instance_repr_inner
    C_RECURSION_LEAVE
    leave
    ret
.iras_too_deep:
    C_RECURSION_LEAVE
    SET_EXC exc_RecursionError_type, \
            "maximum recursion depth exceeded while getting the repr of an object"
    RET_NULL
    leave
    ret
END_FUNC instance_repr_as_str

;; instance_repr_inner(rdi = an instance) -> the same; the wrapper above only
;; bounds the recursion.
DEF_FUNC_LOCAL instance_repr_inner, IR_FRAME
    push rbx
    ; AFTER the push, so lint's counter -- which stops at the first non-push
    ; instruction -- can still see it and check the frame's parity.
    mov [rbp - IR_ASSTR], rsi   ; a frame slot, not a global: a __repr__ that
                                ; calls str() on something else nests, and a
                                ; global would be cleared by the inner call --
                                ; or left set by an inner RAISE, which no
                                ; save-and-restore around the call can undo
    mov rbx, rdi
    DUNDER_EXC_SAVE [rbp - IR_EXC]

    ; Try __repr__ dunder.  object.__repr__ lives in object_type's dict now,
    ; so the MRO search finds it for *every* class -- but it is the default,
    ; not an override, and taking it would print "<L object>" for a list
    ; subclass instead of the list.  Skip it and let the base slot answer.
    extern dunder_repr
    extern dunder_call_1
    extern dunder_lookup
    mov rdi, [rbx + PyObject.ob_type]
    lea rsi, [rel dunder_repr]
    call dunder_lookup
    V_UNPACK rax, rdx
    test edx, edx
    jz .ir_no_dunder
    extern object_method_repr
    extern builtin_func_type
    cmp edx, TAG_PTR
    jne .ir_call_dunder
    mov rcx, [rax + PyObject.ob_type]
    lea r8, [rel builtin_func_type]
    cmp rcx, r8
    jne .ir_call_dunder
    mov rcx, [rax + PyBuiltinObject.func_ptr]
    lea r8, [rel object_method_repr]
    cmp rcx, r8
    je .ir_no_dunder            ; the inherited default: not an override

.ir_call_dunder:
    mov rdi, rbx
    lea rsi, [rel dunder_repr]
    call dunder_call_1
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jz .ir_dunder_none
    ; ...and it has to BE a str; see instance_str.
    ; V_UNPACK has already run, so rax is a PAYLOAD: an int payload of 5
    ; passes a pointer test and dereferences address 5.  The TAG is what says
    ; whether there is an ob_type to read.
    cmp edx, TAG_PTR
    jne .ir_not_a_string
    mov rcx, [rax + PyObject.ob_type]
    lea r8, [rel str_type]
    cmp rcx, r8
    je .done
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jnz .done
.ir_not_a_string:
    mov rsi, rax
    VALUE_FOR_TYPE rsi, rdx     ; the payload, back to something that names a type
    ; str() with no __str__ of its own is object.__str__, which is repr -- and
    ; CPython checks the result at the str() level, so it says __str__ there.
    cmp qword [rbp - IR_ASSTR], 0
    jne .ir_not_a_string_from_str
    CSTRING rdi, `__repr__ returned non-string (type \x01)`
    jmp raise_type_error_with_name
.ir_not_a_string_from_str:
    CSTRING rdi, `__str__ returned non-string (type \x01)`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name      ; does not return

.ir_dunder_none:
    DUNDER_RAISED [rbp - IR_EXC], .failed   ; __repr__ ran and raised

.ir_no_dunder:

    ; No __repr__.  If a builtin lies under this class, use its repr: a
    ; list subclass should print as a list.
    mov rdi, [rbx + PyObject.ob_type]
    mov rsi, PyTypeObject.tp_repr
    call base_slot
    test rax, rax
    jz .ir_generic
    ; object_type.tp_repr is instance_repr itself, so a plain class would
    ; call straight back into here.
    lea rcx, [rel instance_repr]
    cmp rax, rcx
    je .ir_generic
    mov rdi, rbx
    call rax
    ; The base slot returns a str pointer.  Some of them (str_str) set only
    ; rax, and callers still read rdx as the tag -- builtin_print treats a
    ; zero tag as "skip this argument", which is why printing a str subclass
    ; produced nothing.
    mov edx, TAG_PTR
    jmp .done

.ir_generic:
    ; object.__repr__: "<module.qualname object at 0x...>", with the module
    ; left out when it is "builtins".  This used to be the fixed string
    ; "<instance>", which said neither which class nor which object.
    mov rdi, rbx
    call instance_repr_default

.done:
    pop rbx
    leave
    ret

.failed:
    RET_NULL
    pop rbx
    leave
    ret
END_FUNC instance_repr_inner

;; ============================================================================
;; instance_repr_default(rdi = the instance) -> rax = PyStrObject*
;;
;; The shape object.__repr__ has: the defining module and the qualified name,
;; then the address.  The module is dropped when it is "builtins", which is
;; the rule that keeps a builtin's own default repr free of a "builtins."
;; prefix.  Both names come through type_getattr, so a class that sets
;; __qualname__ or __module__ itself is answered with what it set.
;; ============================================================================
IRD_OBJ   equ 8
IRD_MOD   equ 16
IRD_NAME  equ 24
IRD_FRAME equ 40            ; + 1 push = 48, 16-aligned

DEF_FUNC_LOCAL instance_repr_default, IRD_FRAME
    push rbx
    mov [rbp - IRD_OBJ], rdi
    mov qword [rbp - IRD_MOD], 0
    mov qword [rbp - IRD_NAME], 0
    mov rbx, [rdi + PyObject.ob_type]

    CSTRING rdi, "__qualname__"
    extern str_from_cstr_heap
    call str_from_cstr_heap
    push rax
    mov rdi, rbx
    mov rsi, rax
    call type_getattr
    V_UNPACK rax, rdx
    cmp edx, TAG_PTR
    je .ird_have_name
    xor eax, eax
.ird_have_name:
    mov [rbp - IRD_NAME], rax
    pop rdi
    call obj_decref

    CSTRING rdi, "__module__"
    call str_from_cstr_heap
    push rax
    mov rdi, rbx
    mov rsi, rax
    call type_getattr
    V_UNPACK rax, rdx
    cmp edx, TAG_PTR
    je .ird_have_mod
    xor eax, eax
.ird_have_mod:
    mov [rbp - IRD_MOD], rax
    pop rdi
    call obj_decref

    ; "builtins" is not printed, exactly as CPython's object_repr has it.
    mov rax, [rbp - IRD_MOD]
    test rax, rax
    jz .ird_build
    lea rdi, [rax + PyStrObject.data]
    CSTRING rsi, "builtins"
    extern ap_strcmp
    call ap_strcmp
    test eax, eax
    jne .ird_build
    mov rdi, [rbp - IRD_MOD]
    call obj_decref
    mov qword [rbp - IRD_MOD], 0

.ird_build:
    mov rdi, [rbp - IRD_OBJ]
    xor esi, esi
    mov rax, [rbp - IRD_MOD]
    test rax, rax
    jz .ird_no_mod
    lea rsi, [rax + PyStrObject.data]
.ird_no_mod:
    mov rdx, [rbx + PyTypeObject.tp_name]
    mov rax, [rbp - IRD_NAME]
    test rax, rax
    jz .ird_no_name
    lea rdx, [rax + PyStrObject.data]
.ird_no_name:
    extern obj_default_repr_named
    call obj_default_repr_named
    push rax
    mov rdi, [rbp - IRD_NAME]
    test rdi, rdi
    jz .ird_no_name_ref
    call obj_decref
.ird_no_name_ref:
    mov rdi, [rbp - IRD_MOD]
    test rdi, rdi
    jz .ird_no_mod_ref
    call obj_decref
.ird_no_mod_ref:
    pop rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
END_FUNC instance_repr_default

;; ============================================================================
;; instance_str(PyObject *self) -> PyStrObject*
;; Try __str__ dunder, fall back to instance_repr.
;; rdi = instance
;; ============================================================================
IS_EXC   equ 8
IS_FRAME equ 24            ; + 1 push = 32, 16-aligned

;; The same guard instance_repr carries, and for the same loop: the two reach
;; each other, so bounding only one of them would report the depth at whichever
;; happened to be asked first.
DEF_FUNC instance_str
    C_RECURSION_ENTER .is_too_deep
    call instance_str_inner
    C_RECURSION_LEAVE
    leave
    ret
.is_too_deep:
    C_RECURSION_LEAVE
    SET_EXC exc_RecursionError_type, \
            "maximum recursion depth exceeded while getting the str of an object"
    RET_NULL
    leave
    ret
END_FUNC instance_str

;; instance_str_inner(rdi = an instance) -> the same; the wrapper above only
;; bounds the recursion.
DEF_FUNC_LOCAL instance_str_inner, IS_FRAME
    push rbx
    mov rbx, rdi
    DUNDER_EXC_SAVE [rbp - IS_EXC]

    ; Try __str__ dunder, skipping the inherited object.__str__ default for
    ; the same reason instance_repr does: taking it would print a str
    ; subclass as its repr instead of its text.
    extern dunder_str
    extern object_method_str
    mov rdi, [rbx + PyObject.ob_type]
    lea rsi, [rel dunder_str]
    call dunder_lookup
    V_UNPACK rax, rdx
    test edx, edx
    jz .is_no_dunder
    cmp edx, TAG_PTR
    jne .is_call_dunder
    mov rcx, [rax + PyObject.ob_type]
    lea r8, [rel builtin_func_type]
    cmp rcx, r8
    jne .is_call_dunder
    mov rcx, [rax + PyBuiltinObject.func_ptr]
    lea r8, [rel object_method_str]
    cmp rcx, r8
    je .is_no_dunder

.is_call_dunder:
    mov rdi, rbx
    lea rsi, [rel dunder_str]
    call dunder_call_1
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jz .is_dunder_none
    ; It has to BE a str.  Nothing checked, so `def __str__(self): return 5`
    ; handed an int to every caller of str() -- and an f-string, a %-format
    ; and str.join all read PyStrObject.data off it, which is a segfault from
    ; four lines of ordinary Python.
    ; V_UNPACK has already run, so rax is a PAYLOAD: an int payload of 5
    ; passes a pointer test and dereferences address 5.  The TAG is what says
    ; whether there is an ob_type to read.
    cmp edx, TAG_PTR
    jne .is_not_a_string
    mov rcx, [rax + PyObject.ob_type]
    lea r8, [rel str_type]
    cmp rcx, r8
    je .done
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jnz .done
.is_not_a_string:
    mov rsi, rax
    VALUE_FOR_TYPE rsi, rdx     ; the payload, back to something that names a type
    CSTRING rdi, `__str__ returned non-string (type \x01)`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name      ; does not return

.is_dunder_none:
    DUNDER_RAISED [rbp - IS_EXC], .failed   ; __str__ ran and raised

.is_no_dunder:

    ; No __str__.  Prefer the underlying builtin's tp_str -- but only when it
    ; is really its own, which means different from its tp_repr.  Most builtins
    ; do what object does and let str() fall through to repr(): CPython says
    ; `int.__str__ is object.__str__`, and so does list's.  Taking the base's
    ; tp_str unconditionally meant an int subclass that defined __repr__ still
    ; printed as the number.
    push r12
    mov rdi, [rbx + PyObject.ob_type]
    mov rsi, PyTypeObject.tp_str
    call base_slot
    mov r12, rax
    mov rdi, [rbx + PyObject.ob_type]
    mov rsi, PyTypeObject.tp_repr
    call base_slot
    cmp rax, r12
    mov rax, r12
    pop r12
    je .is_generic              ; the base defers to its own repr; so do we
    test rax, rax
    jz .is_generic
    lea rcx, [rel instance_str]
    cmp rax, rcx
    je .is_generic
    mov rdi, rbx
    call rax
    ; The base slot returns a str pointer.  Some of them (str_str) set only
    ; rax, and callers still read rdx as the tag -- builtin_print treats a
    ; zero tag as "skip this argument", which is why printing a str subclass
    ; produced nothing.
    mov edx, TAG_PTR
    jmp .done

.is_generic:
    mov rdi, rbx
    call instance_repr_as_str

.done:
    pop rbx
    leave
    ret

.failed:
    RET_NULL
    pop rbx
    leave
    ret
END_FUNC instance_str_inner

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
TC_NEW_FUNC equ 48              ; saved __new__ func pointer
TC_NEW_TAG  equ 56              ; saved __new__ result tag
; The keywords this call was made with.  __new__ consumes kw_names_pending, so
; __init__ has to be handed it again -- otherwise `M(name, bases, ns, **kwds)`
; reaches __init__ with the keyword values as extra positional arguments, and
; that is how a metaclass with class keywords fails.
TC_KWNAMES  equ 64
; The __init__ an exception subclass runs, found along its MRO.
TC_EXCINIT  equ 72
; Whether the instance came from object's own __new__.  CPython's object_new
; refuses excess arguments when neither __new__ nor __init__ is overridden --
; `class A: pass` then `A(1)` -- and answering that needs to know which of the
; two halves was the default.
TC_PLAIN    equ 80
; __init__ went through __get__, so the reference here is owned.
TC_INIT_BOUND equ 88
; ...and the receiver is already inside it, so self is not prepended.  Also
; set for a callable that is not a descriptor at all, which CPython does not
; bind and does not hand a self to either.
TC_NO_SELF  equ 96

; Refuse arguments this construction has nowhere to put: object's own
; __new__ on one side and object's own __init__ on the other means CPython's
; object_new raises rather than dropping them, so `class A: pass` makes
; `A(1)` a TypeError.  rbx is the type, r13 the positional count, and the
; keyword names saved at the top -- __new__ consumes the global -- stand for
; the rest.  Written out at both sites rather than called, so that neither
; has to reason about what a return address does to rsp.
; A __init__ this code bound through __get__ is owned and has to go back.
; A plain function -- the fast path -- was never bound and must not be touched.
%macro TC_RELEASE_BOUND_INIT 0
    cmp qword [rbp - TC_INIT_BOUND], 0
    je %%none
    mov qword [rbp - TC_INIT_BOUND], 0
    push rax
    push rdx
    mov rdi, rbx
    call obj_decref
    pop rdx
    pop rax
%%none:
%endmacro

;; ============================================================================
;; TC_NAME dest, cache, literal
;;
;; The interned str for a literal type_call asks for on EVERY construction,
;; memoised in one qword.  dunder_name_obj is a hash probe and a call; three of
;; them per object made were 6.7% of a `class C: pass` construction loop once
;; the probe itself was fixed.  The name it answers with is immortal -- the
;; intern table never evicts -- so a qword is a complete cache and needs no
;; invalidation.
;; ============================================================================
%macro TC_NAME 3
    mov %1, [rel %2]
    test %1, %1
    jnz %%have
    lea rdi, [rel %3]
    call dunder_name_obj
    mov [rel %2], rax
    mov %1, rax
%%have:
%endmacro

%macro TC_REFUSE_EXTRA_ARGS 1
    cmp qword [rbp - TC_PLAIN], 0
    je %%ok
    test r13, r13
    jnz %%refuse
    mov rax, [rbp - TC_KWNAMES]
    test rax, rax
    jz %%ok
    cmp qword [rax + PyTupleObject.ob_size], 0
    je %%ok
%%refuse:
    mov rsi, rbx
    CSTRING rdi, `\x01() takes no arguments`
    extern raise_type_error_with_typename
    call raise_type_error_with_typename     ; does not return
%%ok:
%endmacro

;; ============================================================================
;; tc_winner_metatype(rdi = args) -> rax = the metatype to delegate to, or 0
;;
;; args[1] is the bases tuple.  A base whose metatype is `type` -- or the
;; user_type_metatype that stands in for it here -- contributes nothing; of the
;; rest the most derived wins, which is CPython's rule minus the conflict
;; diagnosis.  0 means an ordinary type() call.
;; ============================================================================
TWM_ARGS  equ 8
TWM_WIN   equ 16
TWM_I     equ 24
TWM_N     equ 32
TWM_ITEM  equ 40
TWM_FRAME equ 40          ; + 1 push = 64
DEF_FUNC_LOCAL tc_winner_metatype, TWM_FRAME
    push rbx
    mov [rbp - TWM_ARGS], rdi
    mov qword [rbp - TWM_WIN], 0

    mov rbx, [rdi + 8]                  ; the bases tuple
    V_TEST_PTR rbx, rax
    ja .twm_done
    test rbx, rbx
    jz .twm_done
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    jne .twm_done

    mov rax, [rbx + PyTupleObject.ob_size]
    mov [rbp - TWM_N], rax
    mov qword [rbp - TWM_I], 0
.twm_scan:
    mov rax, [rbp - TWM_I]
    cmp rax, [rbp - TWM_N]
    jae .twm_done
    mov rcx, [rbx + PyTupleObject.ob_item]
    mov rcx, [rcx + rax*8]
    V_TEST_PTR rcx, rdx
    ja .twm_next
    test rcx, rcx
    jz .twm_next
    mov rcx, [rcx + PyObject.ob_type]
    lea rdx, [rel type_type]
    cmp rcx, rdx
    je .twm_next
    lea rdx, [rel user_type_metatype]
    cmp rcx, rdx
    je .twm_next
    ; exc_metatype is the same stand-in for an exception base: it exists to
    ; give a builtin exception class its own tp_call, and it has no tp_setattr
    ; because those classes are immutable.  Electing it here made
    ; `type("T", (Exception,), {})` a class OF exc_metatype, so every store on
    ; it -- `T.__module__ = ...` -- was "cannot set attribute".
    extern exc_metatype
    lea rdx, [rel exc_metatype]
    cmp rcx, rdx
    je .twm_next
    mov [rbp - TWM_ITEM], rcx
    mov rdx, [rbp - TWM_WIN]
    test rdx, rdx
    jz .twm_take
    cmp rdx, rcx
    je .twm_next
    ; Keep whichever is the subclass of the other; a genuine conflict just
    ; leaves the one already found.
    mov rdi, rcx
    mov rsi, rdx
    extern type_is_subtype
    call type_is_subtype
    mov rcx, [rbp - TWM_ITEM]
    test eax, eax
    jz .twm_next
.twm_take:
    mov [rbp - TWM_WIN], rcx
.twm_next:
    inc qword [rbp - TWM_I]
    jmp .twm_scan
.twm_done:
    mov rax, [rbp - TWM_WIN]
    pop rbx
    leave
    ret
END_FUNC tc_winner_metatype


DEF_FUNC type_call
    ; Special case: type(x) with 1 arg when calling type itself
    ; Returns x.__class__ (the type of x)
    lea rax, [rel type_type]
    cmp rdi, rax
    jne .not_type_self
    cmp edx, 3
    jge .type_three_arg         ; the extra arguments are class keywords
    cmp edx, 1
    je .type_one_arg
    ; type() and type(a, b) are neither form.  Falling through to tp_new
    ; reported it as `type.__new__() takes at least 3 arguments`, which
    ; names a method the caller did not write.
    RAISE exc_TypeError_type, "type() takes 1 or 3 arguments"
.type_one_arg:
    ; type(x) → return type of x
    mov rax, [rsi]          ; args[0] payload
    V_TEST_INT_M [rsi], r11      ; args[0] an int immediate?
    jae .type_smallint
    V_TEST_F64_M [rsi], r11      ; args[0] a float?
    jbe .type_float
    mov rax, [rax + PyObject.ob_type]
    ; The heaptype metatype is an implementation split, not a language type:
    ; CPython has one `type`, and `type(C) is type` for an ordinary class.
    ; exc_metatype is the same split for the builtin exception classes, and
    ; answering it here sent types.new_class("E", (KeyError,)) -- which asks
    ; type(base) for the metaclass -- to build E with exc_metatype.
    lea rcx, [rel user_type_metatype]
    cmp rax, rcx
    je .type_of_is_type
    lea rcx, [rel exc_metatype]
    cmp rax, rcx
    jne .type_of_have_type
.type_of_is_type:
    lea rax, [rel type_type]
.type_of_have_type:
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; tp_call returns one Value
    ret
.type_smallint:
    lea rax, [rel int_type]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; tp_call returns one Value
    ret
.type_float:
    extern float_type
    lea rax, [rel float_type]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; tp_call returns one Value
    ret
.type_three_arg:
    ; The class a three-argument type() builds belongs to the most derived of
    ; its bases' metatypes, not to `type`.  Going straight to type_from_parts
    ; ignored that and the class keywords with it, so
    ; `type(name, (SomeEnum,), ns, boundary=KEEP)` -- which is how enum's
    ; _simple_enum decorator builds a class -- never ran EnumType at all.
    push rsi
    push rdx
    mov rdi, rsi
    call tc_winner_metatype
    pop rdx
    pop rsi
    test rax, rax
    jz .tta_plain
    mov rdi, rax
    call type_call              ; the metatype's own tp_call, keywords and all
    leave
    ret

.tta_plain:
    ; type(name, bases, namespace) builds a class, exactly as a class
    ; statement does.  Falling through to .normal_type_call instead treated
    ; type_type as an ordinary class: it allocated a PyInstanceObject-sized
    ; block and wrote type fields into it, so the result printed as
    ; <class ''> and the process aborted with a double free.
    push rbx
    mov rbx, rsi                        ; args

    mov rdi, [rbx]                      ; name
    V_TEST_PTR rdi, rax
    ja .type_three_bad_name
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .type_three_bad_name

    ; bases: the tuple goes through as it is; an empty one means object.
    mov rsi, [rbx + 8]
    V_TEST_PTR rsi, rax
    ja .type_three_bad_bases
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    jne .type_three_bad_bases
    mov rcx, [rsi + PyTupleObject.ob_size]
    test rcx, rcx
    jnz .type_three_have_base
    xor esi, esi
.type_three_have_base:

    mov rdx, [rbx + 16]                 ; namespace dict
    V_TEST_PTR rdx, rax
    ja .type_three_bad_ns
    mov rax, [rdx + PyObject.ob_type]
    lea rcx, [rel dict_type]
    cmp rax, rcx
    jne .type_three_bad_ns

    ; type_from_parts takes ownership of a reference to the namespace, which
    ; becomes tp_dict, and keeps the name alive through tp_name.
    inc qword [rdx + PyObject.ob_refcnt]
    mov rdi, [rbx]
    inc qword [rdi + PyObject.ob_refcnt]
    extern type_from_parts
    call type_from_parts
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.type_three_bad_name:
    RAISE exc_TypeError_type, "type() argument 1 must be str"
.type_three_bad_bases:
    RAISE exc_TypeError_type, "type() argument 2 must be a tuple of at most one base"
.type_three_bad_ns:
    RAISE exc_TypeError_type, "type() argument 3 must be dict"

.type_bool:
    extern bool_type
    lea rax, [rel bool_type]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; tp_call returns one Value
    ret
.type_none:
    extern none_type
    lea rax, [rel none_type]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; tp_call returns one Value
    ret

.not_type_self:
    ; Check for a built-in constructor (int(), str(), staticmethod(), ...).
    ; It lives in tp_new, NOT tp_call: tp_call on a type is what makes that
    ; type's INSTANCES callable, so parking a constructor there made every
    ; string, list and heap int callable ("abc"() returned '').
    ; A HEAPTYPE never takes this shortcut, however it came by its tp_new.
    ; buildclass copies a builtin base's constructor into the subclass, and
    ; calling it here skipped the __new__ and __init__ the class defined in
    ; Python: `class M(ModuleType)` with both of them had neither run.
    ; .normal_type_call reaches the base's constructor anyway, at
    ; .nnf_check_base_new, and runs __init__ on what it built.
    test qword [rdi + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jnz .normal_type_call
    mov rax, [rdi + PyTypeObject.tp_new]
    test rax, rax
    jz .tc_no_constructor
    ; Avoid infinite recursion if a constructor is ever type_call itself
    lea rcx, [rel type_call]
    cmp rax, rcx
    je .normal_type_call
    ; Call the constructor: ctor(type, args, nargs).  It still returns a fat
    ; pair, so tp_call has to pack it rather than tail-jump.
    leave
    sub rsp, 8                  ; keep the callee's rsp 16-byte aligned
    call rax
    add rsp, 8
    V_PACK rax, rdx
    ret

.tc_no_constructor:
    ; A STATIC type with no tp_new and no base to inherit one from is a type
    ; only the interpreter may build: a generator, a coroutine, any of the
    ; iterators, a dict view, os.scandir's iterator.  CPython gives each of
    ; them a NULL tp_new and answers "cannot create 'generator' instances";
    ; this fell through to .normal_type_call, which allocated one and left
    ; every field holding whatever the allocator last put there.
    ;
    ; The consequence is not a curiosity.  `type(os.scandir(p))()` produced an
    ; object with an uninitialised GC head, and the collector walked its
    ; doubly-linked list through it -- a SIGSEGV in gc_list_remove several
    ; hundred tests after the line that caused it.  CPython's
    ; test_os.TestScandir.test_uninstantiable is three lines and does exactly
    ; that.  It is the shape CLAUDE.md records for mappingproxy, one type
    ; over.
    ;
    ; tp_base is checked as well as tp_new, so this cannot catch a static type
    ; that inherits its constructor: every type it does catch has both at
    ; zero.  A heaptype never arrives here at all -- type_new always gives one
    ; a tp_new.
    cmp qword [rdi + PyTypeObject.tp_base], 0
    jne .normal_type_call
    mov rsi, rdi                        ; the type, whose name fills the \x01
    CSTRING rdi, `cannot create '\x01' instances`
    extern raise_type_error_with_typename
    jmp raise_type_error_with_typename  ; does not return

.normal_type_call:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56                 ; locals + align (5 pushes + rbp = 48, +56 = 104)
    mov rax, [rel kw_names_pending]
    mov [rbp - TC_KWNAMES], rax
    mov qword [rbp - TC_NEW_TAG], TAG_PTR  ; default return tag
    mov qword [rbp - TC_PLAIN], 0

    mov rbx, rdi                ; rbx = type
    mov r12, rsi                ; r12 = args
    mov r13d, edx               ; r13d = nargs
    movsxd r13, r13d            ; sign-extend to 64 bits

    ; An abstract class refuses to be instantiated.  __abstractmethods__ is
    ; the set ABCMeta leaves on the class; a non-empty one is the whole test,
    ; and it lives in the class's own dict, never inherited -- a concrete
    ; subclass gets an empty set of its own.
    mov rax, [rbx + PyTypeObject.tp_dict]
    test rax, rax
    jz .tc_not_abstract
    ; dunder_name_obj hands back a BORROWED interned name, cached by the
    ; literal's address; str_from_cstr_heap allocated, copied, scanned for code
    ; points and hashed one afresh on every instantiation, and released it two
    ; lines later.  Three of those per object made is most of what a heaptype
    ; instance cost over object()'s.
    push rax
    TC_NAME rcx, tc_abstract_name_obj, tc_abstract_name
    pop rdi
    mov rsi, rcx
    call dict_get
    test rax, rax
    jz .tc_not_abstract
    V_TEST_PTR rax, rcx
    ja .tc_not_abstract
    cmp qword [rax + PyDictObject.ob_size], 0
    je .tc_not_abstract
    mov rdi, rbx
    mov rsi, rax
    extern type_abstract_error
    call type_abstract_error    ; does not return
.tc_not_abstract:

    ; Check if this type inherits from an exception type
    extern type_is_exc_subclass
    mov rdi, rbx
    call type_is_exc_subclass
    test eax, eax
    jnz .exc_subclass_call

    ; An int subclass used to short-circuit here, before anything looked for a
    ; __new__ of its own -- so a class that defines one never had it called,
    ; and its extra arguments reached int()'s two-argument form instead:
    ; `NIC(7, "SEVEN")` came back as "int() second arg must be an integer".
    ; The shortcut now waits at .new_not_found, beside the str one.

    ; === Look up __new__ in MRO (stop at object_type) ===
    ; Borrowed and interned, so nothing below releases it -- see the note at
    ; the __abstractmethods__ lookup above.
    TC_NAME r15, tc_new_name_obj, new_name_cstr   ; BORROWED

    ; type_lookup_cached answers exactly what the MRO walk this replaced did --
    ; the value in the first tp_dict along the MRO that has the name, and the
    ; type whose dict that was -- from a table keyed on the type's version,
    ; which type_refresh_attr_flags already bumps down every subclass whenever
    ; a class dict is written.  Invalidation is therefore free and passive.
    ;
    ; It could not have been used before the names became interned: its hit
    ; test is a POINTER compare on the name, and a freshly built string missed
    ; every time and churned the entry's owned reference on the way past.
    mov rdi, rbx
    mov rsi, r15
    call type_lookup_cached     ; rax/edx = the value, rcx = the owner
    test edx, edx
    jz .new_not_found
    ; The hand walk stopped AT object_type and the cache walks past it.
    ; object's own __new__ is instance_new's business, not a definition.
    lea rdi, [rel object_type]
    cmp rcx, rdi
    je .new_not_found
    jmp .new_found

.new_not_found:
    ; An int subclass carries its value inline, so it cannot come from
    ; instance_new either.
    mov rax, [rbx + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_INT_SUBCLASS
    jz .nnf_check_str
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call int_sub_new
    test edx, edx
    jz .int_sub_error
    mov r14, rax
    jmp .lookup_init
.nnf_check_str:
    ; A str subclass is variable-size, so it cannot come from instance_new.
    mov rax, [rbx + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_STR_SUBCLASS
    jz .nnf_check_base_new
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call str_sub_new
    mov r14, rax
    jmp .lookup_init

.nnf_check_base_new:
    ; A builtin base with a constructor of its own -- bytes, bytearray,
    ; memoryview -- builds the instance, and __init__ still runs on it
    ; afterwards.  Inheriting the base's tp_new outright skipped __init__.
    mov rdi, rbx
    mov rsi, PyTypeObject.tp_new
    call base_slot
    test rax, rax
    jz .tc_plain_new
    lea rcx, [rel type_call]
    cmp rax, rcx
    je .tc_plain_new
    extern object_type_call
    lea rcx, [rel object_type_call]
    cmp rax, rcx
    je .tc_plain_new
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call rax
    V_UNPACK rax, rdx
    test edx, edx
    jz .int_sub_error
    mov r14, rax
    jmp .lookup_init

.tc_plain_new:
    ; Default: instance_new(type)
    mov qword [rbp - TC_PLAIN], 1
    mov rdi, rbx
    call instance_new
    mov r14, rax                ; r14 = instance

    ; A subclass of a builtin container embeds that container's layout, so
    ; the embedded part needs the empty state its own constructor would have
    ; given it before __init__ fills it.
    mov rax, [rbx + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_LIST_SUBCLASS | TYPE_FLAG_TUPLE_SUBCLASS | \
              TYPE_FLAG_DICT_SUBCLASS | TYPE_FLAG_SET_SUBCLASS
    jz .lookup_init
    mov rdi, r14
    call builtin_sub_init_base

    ; tuple has no __init__ to fill it later, so do it now.
    mov rax, [rbx + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_TUPLE_SUBCLASS
    jz .lookup_init
    mov rdi, r14
    mov rsi, r12
    mov rdx, r13
    call tuple_sub_fill
    jmp .lookup_init

.new_found:
    ; rax = __new__ func ptr, edx = tag
    ; __new__ is conventionally a staticmethod -- it is registered that way
    ; for the container types, and a user class writing @staticmethod gets
    ; the same wrapper -- so unwrap before calling.  The wrapper itself has
    ; no tp_call.
    cmp edx, TAG_PTR
    jne .tc_new_unwrapped
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel staticmethod_type]
    cmp rcx, rdx
    jne .tc_new_unwrapped
    mov rax, [rax + PyStaticMethodObject.sm_callable]
.tc_new_unwrapped:
    mov [rbp - TC_NEW_FUNC], rax

    ; Build args for __new__(cls, *original_args)
    lea rax, [r13 + 2]          ; nargs + 1 slots...
    and rax, -2                 ; ...rounded up to a pair, so rsp stays
    shl rax, 3                  ; 16-aligned for the tp_call below
    sub rsp, rax
    mov r15, rsp                ; r15 = new args array

    ; args[0] = cls (a type pointer is its own Value)
    mov [r15], rbx

    ; Copy original args
    xor ecx, ecx
.copy_new_args:
    cmp rcx, r13
    jge .new_args_copied
    mov rax, rcx
    shl rax, 3                  ; one Value per slot
    mov rdx, [r12 + rax]
    lea r9, [rcx + 1]
    shl r9, 3                   ; dest slot (offset by one for self)
    mov [r15 + r9], rdx
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
    V_UNPACK rax, rdx           ; tp_call returns a Value

    mov r14, rax                ; r14 = instance from __new__
    mov [rbp - TC_NEW_TAG], rdx ; save result tag

    ; Restore stack from args allocation
    lea rax, [r13 + 2]          ; nargs + 1 slots...
    and rax, -2                 ; ...rounded up to a pair, so rsp stays
    shl rax, 3                  ; 16-aligned for the tp_call below
    add rsp, rax

    ; Only call __init__ if __new__ returned an INSTANCE OF cls -- CPython's
    ; type_call asks PyObject_TypeCheck, which is isinstance and not identity.
    ; The pointer compare that was here skipped __init__ for the standard
    ; factory shape, where __new__ picks a subclass and returns object.__new__
    ; of it:
    ;
    ;   class Base:
    ;       def __new__(cls, *a): return object.__new__(Sub if cls is Base else cls)
    ;       def __init__(self, *a): self.args = a
    ;   class Sub(Base): pass
    ;   Base(1, 2).args         # AttributeError; __init__ never ran
    ;
    ; pathlib is the ordinary victim: Path.__new__ returns a PosixPath, so
    ; PurePath.__init__ never ran and every method died on _raw_paths.
    ;
    ; type_is_subtype is DEF_FUNC_BARE and clobbers rdi/rsi/r10/r11/rax; rbx,
    ; r12, r13 and r14 all survive it, and rcx is dead here.  rsp is back to
    ; the prologue's shape, the add rsp above having undone the argument carve.
    cmp qword [rbp - TC_NEW_TAG], TAG_PTR
    jne .no_init
    mov rdi, [r14 + PyObject.ob_type]
    mov rsi, rbx
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jz .no_init

.lookup_init:
    ; Look up __init__ walking the MRO (type + tp_base chain)
    ; Borrowed and interned, as for __new__ above.
    TC_NAME r15, tc_init_name_obj, init_name_cstr ; BORROWED

    ; The same cache as for __new__ above; .init_found already reads the owner
    ; out of rcx, which is where this leaves it.
    ;
    ; The search starts at the INSTANCE's type, not at the class that was
    ; called: CPython's type_call runs Py_TYPE(obj)->tp_init.  Starting at
    ; the called class ran the wrong __init__ whenever __new__ returned a
    ; subclass instance -- the standard factory shape, and the one the
    ; isinstance test above exists to allow.
    mov rdi, [r14 + PyObject.ob_type]
    mov rsi, r15
    call type_lookup_cached
    test edx, edx
    jnz .init_found

    ; __init__ not found anywhere
    TC_REFUSE_EXTRA_ARGS 0
    jmp .no_init

.init_found:
    ; Found where?  object's own __init__ is not a definition, and with
    ; object's __new__ on the other side CPython refuses the arguments
    ; outright rather than dropping them: `class A: pass` makes `A(1)` a
    ; TypeError there and made a silent A here.
    ;
    ; Having refused them, there is nothing left to run.  object.__init__ does
    ; exactly this check and then returns None -- and reaching it cost a
    ; dunder_lookup of __get__ on builtin_func_type, a dunder_call_3 to run it,
    ; a method_new (a gc_alloc and a gc_track) for the bound method it builds,
    ; the call, and the dealloc of the method again.  Callgrind put that chain
    ; at 15.0% of a `class C: pass` construction and two of its five dict
    ; lookups, all of it to reach a function whose body is `return None`.
    ;
    ; Only the arm that lands on object's own __init__ takes this exit.  A
    ; class that writes `__init__ = object.__init__` has it in its OWN dict, so
    ; the owner is that class and the call still happens.
    lea rdx, [rel object_type]
    cmp rcx, rdx
    jne .init_is_defined
    TC_REFUSE_EXTRA_ARGS 0
    jmp .no_init
.init_is_defined:
    mov rbx, rax                ; rbx = __init__ func

    ; __init__ reaches its instance through the DESCRIPTOR PROTOCOL, not by
    ; having self prepended to whatever the class dict holds.
    ;
    ; A plain function is the fast path and keeps the manual prepend, which is
    ; what CPython's lookup_maybe_method does when it reports `unbound`: a
    ; function's __get__ would only build a bound method for this to take
    ; apart again.  That equivalence is also why the bug hid -- the one case
    ; anybody writes is the one case where the two agree.
    ;
    ; Everything else is bound first and called with the arguments AS
    ; WRITTEN.  `__init__ = staticmethod(g)` calls g with no arguments in
    ; CPython and called it with self here; functools.partial and a callable
    ; instance are not descriptors at all, and CPython does not bind them.
    mov qword [rbp - TC_INIT_BOUND], 0
    mov qword [rbp - TC_NO_SELF], 0
    mov rax, [rbx + PyObject.ob_type]
    lea rdx, [rel func_type]
    cmp rax, rdx
    je .init_have_callable

    ; A builtin is asked directly rather than through its type.  __get__ used
    ; to sit in builtin_func_type's tp_dict, where every instance of the type
    ; shared it, so asking the TYPE said "descriptor" for `len` as loudly as
    ; for `type.__init__`.  It is answered per object now, and func_kind is
    ; what answers it: a method or a wrapper binds, a module-level function
    ; does not -- which is CPython's rule, where the first two have a
    ; tp_descr_get and builtin_function_or_method has none.
    extern builtin_func_type
    lea rdx, [rel builtin_func_type]
    cmp rax, rdx
    jne .init_ask_type_get
    mov qword [rbp - TC_NO_SELF], 1     ; either way, no manual prepend
    mov rdi, rbx
    xor esi, esi                        ; the receiver check is type_call's own
    extern builtin_should_bind
    call builtin_should_bind
    test eax, eax
    jz .init_have_callable              ; not a descriptor: call it as written
    mov rdi, rbx
    mov rsi, r14
    call method_new
    test rax, rax
    jz .init_bind_raised
    mov rbx, rax
    mov qword [rbp - TC_INIT_BOUND], 1  ; owned; released after the call
    jmp .init_have_callable

.init_ask_type_get:
    ; Does its type define __get__?
    mov rdi, rax
    lea rsi, [rel dunder_get]
    call dunder_lookup
    V_UNPACK rax, rdx
    mov qword [rbp - TC_NO_SELF], 1     ; either way, no manual prepend
    test edx, edx
    jz .init_have_callable              ; not a descriptor: call it as it is

    ; __get__(init, instance, type_of_instance), which is the receiver
    ; CPython's lookup_maybe_method passes.
    mov rdi, rbx                        ; self = the __init__ object
    mov rsi, r14                        ; arg1 = the instance
    mov rdx, [r14 + PyObject.ob_type]   ; arg2 = its type
    lea rcx, [rel dunder_get]           ; the dunder's name
    mov r8d, TAG_PTR                    ; arg2 is always a heap pointer
    call dunder_call_3
    V_UNPACK rax, rdx
    test edx, edx
    jz .init_bind_raised
    mov rbx, rax
    mov qword [rbp - TC_INIT_BOUND], 1  ; owned; released after the call
    jmp .init_have_callable

.init_bind_raised:
    ; __get__ raised.  Nothing has been allocated on the stack yet, so this
    ; only has to drop the half-built instance the way .init_raised does.
    mov rax, r14
    mov rsi, [rbp - TC_NEW_TAG]
    DECREF_VAL rax, rsi
    xor r14d, r14d
    mov qword [rbp - TC_NEW_TAG], 0
    jmp .no_init

.init_have_callable:

    ; === Call __init__(instance, *args) ===
    ; Build args array on machine stack: [instance, arg0, arg1, ...]
    ; Total args = nargs + 1 (for instance)
    ; One Value per slot.  This carved (nargs+1)*16 and filled at stride 8 --
    ; twice the stack it needs, left over from the 128-bit representation the
    ; NaN-box migration ended, and the comment still said "fat values".
    lea rax, [r13 + 2]          ; nargs + 1 slots...
    and rax, -2                 ; ...rounded up to a pair, so rsp stays
    shl rax, 3                  ; 16-aligned for the tp_call below
    sub rsp, rax                ; allocate on stack
    mov r15, rsp                ; r15 = new args array

    ; args[0] = instance (a pointer is its own Value).  A bound callable
    ; already carries its receiver, so the copy starts at slot 0 for it and
    ; slot 1 for the unbound fast path.
    xor r8d, r8d                ; the destination offset, in slots
    cmp qword [rbp - TC_NO_SELF], 0
    jne .copy_args
    mov [r15], r14
    mov r8d, 1

.copy_args:
    xor ecx, ecx
.copy_args_loop:
    cmp rcx, r13
    jge .args_copied
    mov rax, rcx
    shl rax, 3                  ; one Value per slot
    mov rdx, [r12 + rax]
    lea r9, [rcx + r8]
    shl r9, 3                   ; dest slot
    mov [r15 + r9], rdx
    inc rcx
    jmp .copy_args_loop
.args_copied:

    ; Get __init__'s tp_call
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .init_not_callable
    mov r11, rax                        ; tp_call, kept across the check below

    ; Call tp_call(__init_func, args_with_instance, nargs+1), with the same
    ; keywords the class was called with: __new__ has consumed them by now.
    ;
    ; The keywords the class was called with: __new__ has consumed
    ; kw_names_pending by now, and without handing them back a metaclass's
    ; __init__ sees the keyword VALUES as extra positional arguments.
    ;
    ; A BUILTIN __init__ used to be left with whatever was in the global
    ; rather than being given these, on the reasoning that what was there was
    ; still the original call's.  It is not, as soon as __new__ is a Python
    ; function that forwards: `super().__new__(cls, **kw)` is itself a call
    ; with keywords, and container_dunder_new does not consume them, so dict's
    ; __init__ read the leftover names against the wrong argument array and
    ; `class D(dict)` with a forwarding __new__ failed on `D(a=1)` with
    ; "'int' object is not iterable".  Handing both kinds the SAME saved names
    ; is what the slot is for, and it keeps `L(sequence=())` a TypeError --
    ; list's constructor is still the one that refuses it.
    mov rcx, [rbp - TC_KWNAMES]
    mov [rel kw_names_pending], rcx     ; func_call clears it again
    mov rdi, rbx                ; callable = __init__ func
    mov rsi, r15                ; args ptr
    lea rdx, [r13 + 1]          ; nargs + 1, self included
    cmp qword [rbp - TC_NO_SELF], 0
    je .init_do_call
    mov rdx, r13                ; bound, or not a descriptor: as written
.init_do_call:
    call r11
    V_UNPACK rax, rdx           ; tp_call returns a Value
    test edx, edx
    jz .init_raised             ; NULL, with the exception still pending

    ; __init__ must return None, and CPython says so rather than dropping
    ; whatever it got: a __init__ with a stray `return self` is a common
    ; mistake and answering silently hides it.
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    jne .init_bad_return

    mov rsi, rdx
    DECREF_VAL rax, rsi
    TC_RELEASE_BOUND_INIT

    ; Restore stack (undo the sub rsp from args allocation)
    lea rax, [r13 + 2]          ; nargs + 1 slots...
    and rax, -2                 ; ...rounded up to a pair, so rsp stays
    shl rax, 3                  ; 16-aligned for the tp_call below
    add rsp, rax
    jmp .no_init

.init_bad_return:
    ; rax/rdx still hold what __init__ answered.
    mov rsi, rdx
    V_PACK rax, rsi
    mov r15, rax                ; r15 is free: the args array is done with
    TC_RELEASE_BOUND_INIT
    CSTRING rdi, `__init__() should return None, not '\x01'`
    mov rsi, r15
    extern raise_type_error_with_name
    ; The argument carve is still on the stack.  The raise does not return and
    ; eval_exception_unwind reloads rsp from eval_base_rsp, so there is nothing
    ; to unwind here.
    ;
    ; And eval_saved_r13 is NOT republished: r13 is the argument count in this
    ; function, not the value stack, and handing the unwinder that made it
    ; zero words from an arbitrary address.  The caller published the right
    ; one before it got here, which is why the other raises in this function
    ; do not touch it either.
    jmp raise_type_error_with_name

.init_raised:
    ; What __init__ returned was never looked at, so a raise inside it
    ; produced a "successful" construction: the caller got an object whose
    ; __init__ had not finished, and the exception surfaced at whatever ran
    ; next, as a "During handling of the above exception" chain attached to
    ; code that had nothing to do with it.  io.StringIO(5) is where it turned
    ; up -- it raises TypeError from __init__ and got back a StringIO.
    lea rax, [r13 + 2]          ; nargs + 1 slots...
    and rax, -2                 ; ...rounded up to a pair, so rsp stays
    shl rax, 3                  ; 16-aligned for the tp_call below
    add rsp, rax
    TC_RELEASE_BOUND_INIT
    mov rax, r14
    mov rsi, [rbp - TC_NEW_TAG]
    DECREF_VAL rax, rsi         ; the half-built instance goes no further
    xor r14d, r14d
    mov qword [rbp - TC_NEW_TAG], 0

.no_init:
    ; Return the instance (tag from TC_NEW_TAG; default TAG_PTR, or __new__ result tag)
    mov rax, r14
    mov rdx, [rbp - TC_NEW_TAG]

    add rsp, 56                 ; undo the locals; must match the sub above
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; tp_call returns one Value
    ret

.exc_subclass_call:
    ; User-defined exception subclass — create PyExceptionObject via exc_type_call
    ; rbx = type, r12 = args, r13 = nargs

    ; ...unless the class defines __new__ in Python.  exc_type_call finds a
    ; BUILTIN tp_new along tp_base and nothing here used to ask whether there
    ; was a Python one, so `class E(Exception): def __new__(...)` had its
    ; constructor silently skipped -- for `E()` as much as for `raise E`.
    extern exc_user_new
    extern obj_call_n
    mov rdi, rbx
    call exc_user_new
    test rax, rax
    jnz .exc_sub_user_new

    extern exc_type_call
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call exc_type_call
    ; rax = exception object (PyExceptionObject)
    mov r14, rax                ; r14 = instance
    jmp .exc_sub_have_instance

.exc_sub_user_new:
    ; Call it as (cls, *args).  __new__ is a staticmethod, so the class is
    ; passed explicitly; the array is built on the stack the same way the
    ; __init__ call below builds its own.
    mov [rbp - TC_NEW_FUNC], rax
    lea rax, [r13 + 2]          ; nargs + 1 slots...
    and rax, -2                 ; ...rounded up to a pair, so rsp stays
    shl rax, 3                  ; 16-aligned for the call below
    sub rsp, rax
    mov r15, rsp
    mov [r15], rbx              ; args[0] = the class
    xor ecx, ecx
.exc_sub_new_copy:
    cmp rcx, r13
    jge .exc_sub_new_call
    mov rdx, [r12 + rcx*8]
    mov [r15 + rcx*8 + 8], rdx
    inc rcx
    jmp .exc_sub_new_copy
.exc_sub_new_call:
    mov rdi, [rbp - TC_NEW_FUNC]
    mov rsi, r15
    lea rdx, [r13 + 1]
    call obj_call_n
    mov r14, rax
    ; The stack goes back before anything branches, so every exit below is the
    ; ordinary one.
    lea rax, [r13 + 2]
    and rax, -2
    shl rax, 3
    add rsp, rax
    test r14, r14
    jz .exc_sub_new_failed

    ; CPython runs __init__ only when what came back is an instance of the
    ; class that was asked for -- a __new__ that answers something else has
    ; taken over the construction entirely.
    V_TEST_PTR r14, rax
    ja .exc_sub_new_other
    mov rdi, [r14 + PyObject.ob_type]
    mov rsi, rbx
    call type_is_subtype
    test eax, eax
    jz .exc_sub_new_other

.exc_sub_have_instance:

    ; The __init__ to run, found along the MRO rather than in this type's own
    ; slot: it is inherited, and `class F(E): pass` runs E's.  tp_init is set
    ; only from the class's OWN body, so a subclass of a subclass ran none.
    extern exc_user_init
    mov rdi, rbx
    call exc_user_init
    mov [rbp - TC_EXCINIT], rax
    test rax, rax
    jz .exc_sub_no_init

    ; Build args: (instance, *original_args), one Value per slot
    lea rax, [r13 + 2]          ; nargs + 1 slots...
    and rax, -2                 ; ...rounded up to a pair, so rsp stays
    shl rax, 3                  ; 16-aligned for the tp_call below
    sub rsp, rax
    mov r15, rsp                ; r15 = new args array
    mov [r15], r14
    ; Copy original args
    xor ecx, ecx
.exc_sub_copy_args:
    cmp rcx, r13
    jge .exc_sub_args_copied
    mov rax, rcx
    shl rax, 3                  ; one Value per slot
    mov rdx, [r12 + rax]
    lea r9, [rcx + 1]
    shl r9, 3                   ; dest slot (offset by one for self)
    mov [r15 + r9], rdx
    inc rcx
    jmp .exc_sub_copy_args
.exc_sub_args_copied:
    ; Get __init__'s tp_call
    mov rdi, [rbp - TC_EXCINIT]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .exc_sub_init_cleanup
    mov rdi, [rbp - TC_EXCINIT]
    mov rsi, r15
    lea rdx, [r13 + 1]
    call rax
    V_UNPACK rax, rdx           ; tp_call returns a Value
    ; DECREF return value (should be None)
    mov rsi, rdx
    DECREF_VAL rax, rsi
.exc_sub_init_cleanup:
    lea rax, [r13 + 2]          ; nargs + 1 slots...
    and rax, -2                 ; ...rounded up to a pair, so rsp stays
    shl rax, 3                  ; 16-aligned for the tp_call below
    add rsp, rax

.exc_sub_new_other:
    ; __new__ answered something that is not an instance of the class asked
    ; for, so it has taken the construction over and __init__ does not run --
    ; type_call's rule, applied here.
.exc_sub_no_init:
    mov rax, r14
    mov edx, TAG_PTR
    add rsp, 56                 ; undo the locals; must match the sub above
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; tp_call returns one Value
    ret

.exc_sub_new_failed:
    ; __new__ raised; the exception is pending and there is nothing to return.
    add rsp, 56                 ; undo the locals; must match the sub above
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    RET_NULL
    ret

.int_subclass_call:
    ; rbx = type, r12 = args, r13 = nargs
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call int_sub_new
    test edx, edx
    jz .int_sub_error
.int_sub_epilogue:
    add rsp, 56                 ; undo the locals; must match the sub above
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; tp_call returns one Value
    ret
.int_sub_error:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; tp_call returns one Value
    ret

.init_not_callable:
    RAISE exc_TypeError_type, "__init__ is not callable"
    ; does not return

.new_not_callable:
    ; Restore stack from args allocation, then error
    lea rax, [r13 + 2]          ; nargs + 1 slots...
    and rax, -2                 ; ...rounded up to a pair, so rsp stays
    shl rax, 3                  ; 16-aligned for the tp_call below
    add rsp, rax
    RAISE exc_TypeError_type, "__new__ is not callable"
    ; does not return
END_FUNC type_call


;; ============================================================================
;; user_type_dealloc(PyTypeObject *type)
;; Deallocator for user-defined heap types (created by __build_class__).
;; Frees tp_dict, tp_name string, and the type object itself.
;; ============================================================================

;; ============================================================================
;; type_traverse / type_clear -- a heap type is a GC object like any other
;;
;; user_type_metatype carried TYPE_FLAG_HAVE_GC and a NULL tp_traverse, so
;; every class was tracked and none was reachable THROUGH: the collector could
;; see a class but not what it held.  A class always sits in a cycle -- its
;; own tp_mro tuple contains it -- so with no traverse none of them was ever
;; collected.  `def f(): class Temp: pass` leaked a class per call, and so did
;; every decorator, factory and closure that builds one.
;;
;; type_clear follows CPython's: the dict's contents and tp_mro, and not
;; tp_base or tp_bases.  Breaking the MRO is enough to break the cycle, and
;; the bases are what the type needs to stay coherent while the rest of the
;; collection runs.
;; ============================================================================
global type_traverse
DEF_FUNC type_traverse, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyTypeObject.tp_dict]
    VISIT_PTR rdi
    ; The metatype, which type_from_parts counts.  Without this edge a class
    ; and its Python-level metaclass -- which refer to each other, the class
    ; through ob_type and the metaclass through the class's MRO -- would be a
    ; cycle the collector could not see all of.
    mov rdi, [rbx + PyObject.ob_type]
    VISIT_PTR rdi
    mov rdi, [rbx + PyTypeObject.tp_base]
    VISIT_PTR rdi
    mov rdi, [rbx + PyTypeObject.tp_bases]
    VISIT_PTR rdi
    mov rdi, [rbx + PyTypeObject.tp_mro]
    VISIT_PTR rdi
    pop rbx
    leave
    ret
END_FUNC type_traverse

global type_clear
DEF_FUNC type_clear, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .tcl_mro
    extern dict_clear_gc
    call dict_clear_gc          ; the contents, not the dict itself
.tcl_mro:
    mov rdi, [rbx + PyTypeObject.tp_mro]
    test rdi, rdi
    jz .tcl_done
    mov qword [rbx + PyTypeObject.tp_mro], 0
    call obj_decref
.tcl_done:
    pop rbx
    leave
    ret
END_FUNC type_clear

DEF_FUNC user_type_dealloc, 16           ; 2 pushes, so rsp is 16-aligned
    push rbx
    push r12
    mov rbx, rdi                ; rbx = type object
    ; The metatype has to be read out before the object is freed and released
    ; after, because gc_dealloc reads ob_type on its way through.
    mov r12, [rbx + PyObject.ob_type]

    ; Out of every base's subclass list first, while tp_bases is still there
    ; to say which they are.  The entries are borrowed, so this is the only
    ; thing that keeps a freed class out of __subclasses__().
    extern subclass_live
    cmp qword [rel subclass_live], 0
    je .utd_no_subclasses
    extern subclass_unregister
    mov rdi, rbx
    call subclass_unregister
.utd_no_subclasses:

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

    ; ...and ht_qualname, which the dict no longer holds for us.
    mov rdi, [rbx + HT_QUALNAME]
    test rdi, rdi
    jz .utd_no_qualname
    mov qword [rbx + HT_QUALNAME], 0
    call obj_decref
.utd_no_qualname:

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

    ; And release the metatype, now that nothing reads ob_type any more.
    ; type_from_parts counts it into ob_type for every class, so this is the
    ; other half of that rather than a special case for a Python-level
    ; metaclass -- a static metatype simply sees a balanced pair, exactly as
    ; object_type does through tp_base above.
    test r12, r12
    jz .utd_no_metatype
    mov rdi, r12
    call obj_decref
.utd_no_metatype:

    pop r12
    pop rbx
    leave
    ret
END_FUNC user_type_dealloc

;; ============================================================================
;; Data section
;; ============================================================================
section .rodata

section .data
align 8
;; The object object.__getattribute__ is currently resolving for, or 0.  Set
;; around its call and consumed by the first instance_getattr that sees it.
global instance_getattr_skip
instance_getattr_skip: dq 0
section .rodata
id_del_ignored_msg: db "Exception ignored in __del__", 10
id_del_ignored_len equ $ - id_del_ignored_msg
section .bss
align 8
;; The three names type_call resolves on every construction, memoised by
;; TC_NAME.  Immortal once set: the intern table never evicts.
tc_abstract_name_obj: resq 1
tc_new_name_obj:      resq 1
tc_init_name_obj:     resq 1

section .data

instance_repr_cstr: db "<instance>", 0
global init_dunder_cstr
init_dunder_cstr:
init_name_cstr:     db "__init__", 0
tc_abstract_name: db "__abstractmethods__", 0
global new_dunder_cstr
new_dunder_cstr:
new_name_cstr:      db "__new__", 0
object_name_str:    db "object", 0
user_type_name_str: db "type", 0

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
    extern type_setattr
    dq type_setattr             ; tp_setattr — setting class vars in tp_dict
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq type_number_methods      ; tp_as_number -- `C | None` builds a
                                ; union, and a class's `|` is its
                                ; METATYPE's slot, not its own
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq type_type                ; tp_base — metatype inherits from type
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC | TYPE_FLAG_METATYPE  ; tp_flags (heaptypes are gc_alloc'd)
    dq 0                        ; tp_bases
    dq type_traverse            ; tp_traverse
    dq type_clear               ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; object_type - base type for all Python objects
; Used as explicit base class: class Foo(object): pass
; Also callable: object() returns a bare instance
align 8
extern object_hash

global object_type
object_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq object_name_str          ; tp_name
    ; object() has no __dict__, so its instances are the bare header.  This
    ; used to be PyInstanceObject_size -- the header PLUS a dict word that
    ; object's own tp_dictoffset of 0 says is not there.  Every object() paid
    ; for it, and `class B(object): pass` put its dict one word further out
    ; than `class B: pass` did, for two different layouts of the same class.
    dq OBJ_HEADER_SIZE          ; tp_basicsize
    dq instance_dealloc         ; tp_dealloc
    dq instance_repr            ; tp_repr
    dq 0                        ; tp_str
    dq object_hash              ; tp_hash
    dq 0                        ; tp_call  (instances are not callable)
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
    dq 0           ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer


section .text

;; ============================================================================
;; GC traverse and clear.  These lived in gc.asm, which left the collector
;; holding the reference graph of every type in the system; a type's own
;; file is the only place that knows which of its fields are owned.
;; ============================================================================

; ---- instance_traverse / instance_clear ----
;; ============================================================================
;; instance_slot_floor(rdi = the instance's type) -> rax = where its __slots__
;; begin
;;
;; Every heaptype whose instances this function deallocs lays out its own
;; slots directly above its base's, so a subclass's slot region includes the
;; ones its ancestors declared: `class C: __slots__ = ('a',)` and `class
;; D(C): pass` give D exactly C's layout, and taking the floor from D's own
;; base -- C -- found no slots at all and released none.  D's `a` was never
;; freed, and a cycle through it was uncollectable.
;;
;; The walk stops at the first ancestor that manages its own storage: a
;; static type, or a heaptype with a tp_dealloc of its own.  _io.FileIO is
;; the second kind -- a heaptype with a patched basicsize and five C fields
;; -- and walking past it would hand a file descriptor to DECREF_VAL.
;; ============================================================================
DEF_FUNC_LOCAL instance_slot_floor
    push rbx
    mov rbx, rdi                ; the type whose base chain is walked
    xor eax, eax                ; the floor, 0 until an ancestor sets it
.isf_loop:
    mov rcx, [rbx + PyTypeObject.tp_base]
    test rcx, rcx
    jz .isf_done
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .isf_builtin
    lea rdx, [rel instance_dealloc]
    cmp [rcx + PyTypeObject.tp_dealloc], rdx
    jne .isf_builtin            ; it keeps fields of its own
    mov rbx, rcx
    jmp .isf_loop
.isf_builtin:
    mov rax, [rcx + PyTypeObject.tp_basicsize]
.isf_done:
    pop rbx
    leave
    ret
END_FUNC instance_slot_floor

DEF_FUNC instance_traverse
    push rbx
    push r12
    push r13
    push r15                    ; r14 is the visit callback, VISIT_V's own

    mov rbx, rdi

    ; Visit the instance dict, wherever this family keeps it
    ; No NULL test, and that is VISIT_PTR's doing rather than an omission: it
    ; is NULL-safe.  An instance carries no dict until something puts one
    ; there, so this is the ordinary case and not a rare one.  Swapping this
    ; for VISIT_V would break it silently.
    LOAD_INST_DICT rdi, rbx, .no_inst_dict
    VISIT_PTR rdi
.no_inst_dict:

    ; Visit the CLASS.  CPython's subtype_traverse says why in as many words:
    ; "For a heaptype, the instances count as references to the type.  Traverse
    ; the type so the collector can find cycles involving this link."
    ;
    ; Without it, an instance freed by the COLLECTOR rather than by
    ; refcounting never accounted for the reference it held to its class, and
    ; the class survived -- about 900 bytes of class, dict and methods every
    ; time.  It needs both a class whose lifetime is shorter than the program's
    ; (defined in a function, or built by type()) AND an instance only the
    ; collector can free, which is why a module-level class never showed it.
    ; `self.callback = self.method` is the everyday way to make such an
    ; instance, so every callback-registering object had this.
    ;
    ; ONLY for a heaptype.  A static type has no GC head, and handing one to
    ; the collector is the shape that made an earlier crash
    ; layout-dependent -- the flag test is the whole guard.
    mov rax, [rbx + PyObject.ob_type]
    test dword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .no_type_visit
    VISIT_PTR rax
.no_type_visit:

    ; Visit __slots__ values (one Value each, after the instance header).
    ; The header ends at tp_dictoffset plus the dict word, or at
    ; PyInstanceObject_size when the family keeps no dict.
    mov rax, [rbx + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_dictoffset]
    test rcx, rcx
    jz .it_no_dict_hdr
    cmp rcx, TP_DICT_AT_TAIL
    je .it_no_dict_hdr          ; the dict is past the data, not in the header
    add rcx, 8
    ; The same floor and the same skip as instance_dealloc: a base's slots sit
    ; BELOW the dict word the subclass added, and starting past the dict left
    ; them unvisited -- so a cycle through an inherited slot was never
    ; collectable.  The layout base's own fields can sit past the dict word
    ; too, which is why the floor stops at the first ancestor that manages its
    ; own storage: here the consequence of walking those would be the
    ; collector visiting a file descriptor as an object pointer.
    push rax
    push rcx
    mov rdi, rax
    call instance_slot_floor
    mov rdx, rax
    pop rcx
    pop rax
    test rdx, rdx
    jz .it_have_hdr
    cmp rdx, rcx
    jae .it_have_hdr
    mov rcx, rdx
    jmp .it_have_hdr
.it_no_dict_hdr:
    ; No dict word: a str subclass, whose header is the base's, not
    ; PyInstanceObject's.  Using 24 there found a phantom slot at +24 --
    ; PyStrObject.ob_hash -- and XDECREF'd the hash as if it were a pointer.
    push rax
    mov rdi, rax
    call instance_slot_floor
    mov rcx, rax
    pop rax
    test rcx, rcx
    jnz .it_have_hdr
    mov rcx, OBJ_HEADER_SIZE
.it_have_hdr:
    mov r15, [rax + PyTypeObject.tp_dictoffset]
    cmp r15, TP_DICT_AT_TAIL
    jne .it_dict_off_ok
    xor r15d, r15d
.it_dict_off_ok:
    add r15, rbx                ; the dict word's address, or rbx
    mov rax, [rax + PyTypeObject.tp_basicsize]
    sub rax, rcx
    jle .done
    shr rax, 3                  ; nslots
    mov r13, rax
    lea r12, [rbx + rcx]

.slot_loop:
    cmp r12, r15
    je .it_slot_skip            ; the instance dict, visited above
    mov rdi, [r12]
    VISIT_V rdi, rsi
.it_slot_skip:
    add r12, 8
    dec r13
    jnz .slot_loop

.done:
    ; And the slots at the TAIL, which a str subclass's are: past the
    ; characters and past the word the tail __dict__ occupies.  Nothing in
    ; the header walk above can reach them, so a cycle through one was never
    ; collectable.
    mov rax, [rbx + PyObject.ob_type]
    mov r13, [rax + PyTypeObject.tp_tailslots]
    test r13, r13
    jz .it_tail_done
    INST_DICT_TAIL r12, rbx
    add r12, 8                  ; past the dict word
.it_tail_loop:
    mov rdi, [r12]
    VISIT_V rdi, rsi
    add r12, 8
    dec r13
    jnz .it_tail_loop
.it_tail_done:
    pop r15
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC instance_traverse

DEF_FUNC instance_clear, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; XDECREF + NULL the instance dict, wherever this family keeps it
    LOAD_INST_DICT rdi, rbx, .done
    test rdi, rdi
    jz .done
    xor eax, eax
    STORE_INST_DICT rbx, rax, rcx, .ic_decref
.ic_decref:
    call obj_decref

.done:
    pop rbx
    leave
    ret
END_FUNC instance_clear
