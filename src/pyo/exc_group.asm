; exc_group.asm - ExceptionGroup type implementation (PEP 654)
;
; Provides:
;   - exc_BaseExceptionGroup_type, exc_ExceptionGroup_type
;   - eg_new(type, msg_str, exc_tuple) -> PyExceptionGroupObject*
;   - eg_type_call(type, args, nargs) -> PyObject*  (constructor)
;   - eg_dealloc(eg)
;   - eg_str(eg) -> str
;   - eg_getattr(eg, name) -> PyObject* or NULL
;   - eg_split(eg, match_type) -> rax=match, rdx=rest
;   - eg_is_base_exception_group(obj) -> 0/1
;   - prep_reraise_star(orig, excs_list) -> PyObject*

%include "macros.inc"
%include "object.inc"

extern ap_free
extern object_type
extern ap_malloc
extern gc_alloc
extern gc_dealloc
extern gc_track
extern exc_traverse
extern exc_clear_gc
extern ap_strcmp
extern exc_BaseException_type
extern exc_Exception_type
extern exc_getattr
extern exc_isinstance
extern exc_metatype
extern exc_repr
extern exc_setattr
extern exc_AttributeError_type
extern exc_str
extern exc_TypeError_type
extern exc_ValueError_type
extern list_append
extern list_new
extern list_type
extern none_singleton
extern obj_decref
extern obj_dealloc
extern obj_incref
extern raise_exception
extern tuple_new
extern str_type
extern tuple_type
extern type_type
extern dict_new
extern dict_set
extern str_from_cstr_heap
extern builtin_func_new
extern type_stamp_methods
extern obj_getattr_opt
extern obj_call_n
extern raise_type_error_counted
extern raise_type_error_with_name

;; ============================================================================
;; eg_new(PyTypeObject *type, PyObject *msg_str, PyObject *exc_tuple)
;;   -> PyExceptionGroupObject*
;; Allocate and initialize an ExceptionGroup.
;; msg_str and exc_tuple are INCREFed. type is immortal.
;; ============================================================================
EGN_EG    equ 8
EGN_FRAME equ 8             ; + 3 pushes = 32
DEF_FUNC eg_new, EGN_FRAME
    push rbx
    push r12
    push r13

    mov rbx, rdi            ; type
    mov r12, rsi            ; msg_str
    mov r13, rdx            ; exc_tuple

    ; Allocate through the collector.  It has to be gc_alloc rather than
    ; ap_malloc because the TYPE decides how the block is freed, and the type
    ; here is whatever the caller passed: `except*` splits a group by calling
    ; this with the group's own type, and a SUBCLASS of any exception type is
    ; given exc_dealloc, which frees through gc_dealloc at obj - GC_HEAD_SIZE.
    ; A plain ap_malloc block handed back sixteen bytes low corrupts the heap.
    mov edi, PyExceptionGroupObject_size
    mov rsi, rbx
    call gc_alloc
    ; gc_alloc sets ob_refcnt = 1 and stamps ob_type, but does not COUNT the
    ; type -- and a group's type is as often a program's class as it is one of
    ; the two builtins.  See exc_new.
    inc qword [rbx + PyObject.ob_refcnt]
    mov [rax + PyExceptionGroupObject.exc_type], rbx
    mov [rax + PyExceptionGroupObject.exc_value], r12
    mov qword [rax + PyExceptionGroupObject.exc_tb], 0
    mov qword [rax + PyExceptionGroupObject.exc_context], 0
    mov qword [rax + PyExceptionGroupObject.exc_cause], 0
    ; ap_malloc does not zero, and exc_getattr reads exc_dict on every
    ; attribute miss -- so leaving it uninitialised made `eg.anything` branch
    ; on a garbage pointer.  exc_suppress is read the same way by a bare
    ; `raise`.  exc_args is filled in below, once the args tuple exists.
    mov qword [rax + PyExceptionGroupObject.exc_dict], 0
    mov qword [rax + PyExceptionGroupObject.exc_suppress], 0
    mov qword [rax + PyExceptionGroupObject.exc_args], 0
    mov [rax + PyExceptionGroupObject.eg_exceptions], r13

    ; INCREF msg_str
    test r12, r12
    jz .no_msg
    INCREF r12
.no_msg:

    ; INCREF exc_tuple
    test r13, r13
    jz .no_tup
    INCREF r13
.no_tup:

    ; Build args tuple: (msg, excs)
    mov [rbp - EGN_EG], rax
    mov edi, 2
    call tuple_new
    mov rcx, [rbp - EGN_EG]

    mov r8, [rax + PyTupleObject.ob_item]       ; payloads

    ; args[0] = msg_str
    test r12, r12
    jz .args_no_msg
    INCREF r12
    mov [r8], r12
    jmp .args_set_excs
.args_no_msg:
    ; Push None for msg if NULL
    lea rdx, [rel none_singleton]
    INCREF rdx
    mov [r8], rdx
.args_set_excs:
    ; args[1] = exc_tuple (fat slot 1 at offset +16)
    test r13, r13
    jz .args_no_excs
    INCREF r13
    mov [r8 + 8], r13
    jmp .args_done
.args_no_excs:
    lea rdx, [rel none_singleton]
    INCREF rdx
    mov [r8 + 8], rdx
.args_done:
    mov [rcx + PyExceptionGroupObject.exc_args], rax

    ; Track only now: every field the traverse reads is set.
    mov rdi, rcx
    call gc_track

    ; From the frame slot, not from rcx: gc_track is where a collection
    ; actually runs, and rcx is caller-saved.  The 1-in-N allocation that
    ; triggered one came back with a clobbered rcx and returned it as the new
    ; group -- usually harmless rubbish, and NULL often enough that building
    ; ~150 nested ExceptionGroups reliably died on `[NULL + exc_args]`.
    mov rax, [rbp - EGN_EG]

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC eg_new

;; ============================================================================
;; eg_type_call(PyTypeObject *type, PyObject **args, int64_t nargs)
;;   -> PyObject*
;; Constructor: ExceptionGroup(msg, excs)
;; rdi = type, rsi = args array, rdx = nargs
;; ============================================================================
EGC_TYPE  equ 8
EGC_ARGS  equ 16
EGC_NARGS equ 24
EGC_ORIG  equ 32            ; the sequence as it was passed, for .args
EGC_SEQV  equ 40            ; scratch Value, so &it can be an args array
EGC_FRAME equ 56            ; + 3 pushes = 80, 16-aligned
DEF_FUNC eg_type_call, EGC_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - EGC_TYPE], rdi
    mov [rbp - EGC_ARGS], rsi
    mov [rbp - EGC_NARGS], rdx

    ; Require exactly 2 args
    cmp rdx, 2
    jne .bad_nargs

    ; args[0] = msg (must be str), args[1] = excs (list or tuple)
    mov rbx, [rsi]          ; msg
    mov r12, [rsi + 8]     ; excs
    mov [rbp - EGC_ORIG], r12

    ; The message has to BE a str, and CPython says which argument and what
    ; it got.  Nothing checked, so eg_new stored whatever it was handed.
    V_TEST_PTR rbx, rax
    ja .bad_msg
    test rbx, rbx
    jz .bad_msg
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .msg_ok
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .bad_msg
.msg_ok:

    ; ...and the sequence has to be a POINTER before its type can be read.
    ; `BaseExceptionGroup("x", 0)` read a small integer's Value as one.
    V_TEST_PTR r12, rax
    ja .bad_excs
    test r12, r12
    jz .bad_excs

    ; Check if excs is a tuple already
    mov rax, [r12 + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .have_tuple

    ; Check if excs is a list — convert to tuple
    lea rcx, [rel list_type]
    cmp rax, rcx
    jne .other_sequence

    ; Convert list to tuple
    mov rcx, [r12 + PyListObject.ob_size]
    test rcx, rcx
    jz .empty_excs

    push rbx                ; save msg
    mov rdi, rcx
    call tuple_new
    mov r13, rax            ; r13 = new tuple
    pop rbx

    ; Copy list items to tuple
    mov rcx, [r12 + PyListObject.ob_size]
    mov r8, [r12 + PyListObject.ob_item]       ; list payloads
    xor edx, edx
.copy_list:
    mov rcx, [r12 + PyListObject.ob_size]  ; reload loop limit (clobbered below)
    cmp rdx, rcx
    jge .list_done
    mov rdi, [r8 + rdx*8]      ; list item payload
    V_UNPACK rdi, r11
    INCREF_VAL rdi, r11
    mov r10, [r13 + PyTupleObject.ob_item]       ; tuple payloads
    V_PACK rdi, r11
    mov [r10 + rdx * 8], rdi
    inc rdx
    jmp .copy_list
.list_done:
    mov r12, r13            ; r12 = exc_tuple (owned, refcnt=1)
    jmp .check_nonempty

.other_sequence:
    ; CPython builds the tuple with PySequence_Tuple, so a str, a range or a
    ; generator is a sequence of members and is judged one member at a time.
    ; Refusing everything but tuple and list here made
    ; `BaseExceptionGroup("m", "x")` a TypeError about the sequence, where
    ; CPython reports Item 0 instead.
    mov rdi, r12
    extern get_iterator_opt
    mov esi, TAG_PTR
    call get_iterator_opt
    test rax, rax
    jz .bad_excs
    V_UNPACK rax, rdx
    mov rdi, rax
    call obj_decref
    mov [rbp - EGC_SEQV], r12
    lea rsi, [rbp - EGC_SEQV]
    extern tuple_type
    lea rdi, [rel tuple_type]
    mov edx, 1
    extern tuple_type_call
    call tuple_type_call
    V_UNPACK rax, rdx
    test rax, rax
    jz .egc_propagate
    mov r12, rax
    jmp .check_nonempty

.egc_propagate:
    xor eax, eax
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    leave
    ret

.have_tuple:
    ; Tuple — INCREF since eg_new will INCREF again, we need our own ref
    INCREF r12
    jmp .check_nonempty

.check_nonempty:
    ; Validate: len(excs) > 0
    mov rcx, [r12 + PyTupleObject.ob_size]
    test rcx, rcx
    jz .empty_excs_decref

    ; Every member has to be an exception, and CPython says which one is not.
    ; And the CLASS depends on them: BaseExceptionGroup narrows to
    ; ExceptionGroup when they all derive from Exception, and ExceptionGroup
    ; refuses one that does not.
    mov r13, [r12 + PyTupleObject.ob_item]
    mov rcx, [r12 + PyTupleObject.ob_size]
    xor edx, edx
    mov r8d, 1                  ; all of them are Exceptions, so far
.egc_member_loop:
    cmp rdx, rcx
    jge .egc_members_ok
    mov rdi, [r13 + rdx*8]
    V_TEST_PTR rdi, rax
    ja .egc_bad_member
    test rdi, rdi
    jz .egc_bad_member
    mov rax, [rdi + PyObject.ob_type]
    push rcx
    push rdx
    push r8
    push rdi
    mov rdi, rax
    lea rsi, [rel exc_BaseException_type]
    extern type_is_subtype
    call type_is_subtype
    pop rdi
    pop r8
    pop rdx
    pop rcx
    test eax, eax
    jz .egc_bad_member
    mov rax, [rdi + PyObject.ob_type]
    push rcx
    push rdx
    push r8
    push r8
    mov rdi, rax
    lea rsi, [rel exc_Exception_type]
    call type_is_subtype
    pop r8
    pop r8
    pop rdx
    pop rcx
    test eax, eax
    jnz .egc_member_next
    xor r8d, r8d                ; one of them is a bare BaseException
.egc_member_next:
    inc rdx
    jmp .egc_member_loop

.egc_bad_member:
    push rdx                    ; the index; obj_decref keeps nothing
    push rdx
    mov rdi, r12
    call obj_decref
    pop rsi
    pop rsi
    CSTRING rdi, "Item "
    CSTRING rdx, " of second argument (exceptions) is not an exception"
    extern exc_ValueError_type
    extern raise_value_error_counted
    jmp raise_value_error_counted

.egc_members_ok:
    mov rdi, [rbp - EGC_TYPE]
    lea rax, [rel exc_ExceptionGroup_type]
    cmp rdi, rax
    jne .egc_not_eg
    test r8d, r8d
    jnz .egc_have_type
    ; ExceptionGroup will not hold one.
    mov rdi, r12
    call obj_decref
    RAISE exc_TypeError_type, \
          "Cannot nest BaseExceptions in an ExceptionGroup"
.egc_not_eg:
    lea rax, [rel exc_BaseExceptionGroup_type]
    cmp rdi, rax
    jne .egc_have_type
    test r8d, r8d
    jz .egc_have_type
    lea rdi, [rel exc_ExceptionGroup_type]   ; all Exceptions: narrow to it
.egc_have_type:
    mov [rbp - EGC_TYPE], rdi

    ; Call eg_new(type, msg, exc_tuple)
    mov rdi, [rbp - EGC_TYPE]
    mov rsi, rbx            ; msg
    mov rdx, r12            ; exc_tuple
    call eg_new
    ; rax = new EG object

    ; DECREF our ref to exc_tuple (eg_new INCREFed it).  Two pushes, not one:
    ; this frame leaves rsp 16-aligned, so a lone save puts the callee 8 out.
    push rax
    push rax
    mov rdi, r12
    call obj_decref
    pop rax
    pop rax

    ; .args holds the sequence AS PASSED, not the tuple this made of it:
    ; `BaseExceptionGroup("x", [e]).args` is ('x', [e]) in CPython, and
    ; .exceptions is the tuple.
    mov rcx, [rax + PyExceptionGroupObject.exc_args]
    test rcx, rcx
    jz .egc_no_args
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov rdx, [rcx + 8]
    mov r8, [rbp - EGC_ORIG]
    mov [rcx + 8], r8
    push rax
    mov rdi, r8
    call obj_incref
    mov rdi, [rsp]
    mov rdi, rdx
    call obj_decref
    pop rax
.egc_no_args:

    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.bad_nargs:
    ; CPython's wording, with the count it was given.
    mov rsi, [rbp - EGC_NARGS]
    CSTRING rdi, "BaseExceptionGroup.__new__() takes exactly 2 arguments ("
    CSTRING rdx, " given)"
    extern raise_type_error_counted
    jmp raise_type_error_counted

.bad_msg:
    mov rsi, rbx
    CSTRING rdi, \
        `BaseExceptionGroup.__new__() argument 1 must be str, not \x02`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.bad_excs:
    RAISE exc_TypeError_type, "second argument (exceptions) must be a sequence"

.empty_excs:
    RAISE exc_ValueError_type, "second argument (exceptions) must be a non-empty sequence"

.empty_excs_decref:
    ; DECREF exc_tuple before raising
    push r12
    mov rdi, r12
    call obj_decref
    pop r12
    RAISE exc_ValueError_type, "second argument (exceptions) must be a non-empty sequence"

END_FUNC eg_type_call

;; ============================================================================
;; eg_dealloc(PyExceptionGroupObject *eg)
;; Free exception group and DECREF all fields.
;; ============================================================================
EGD_TYPE  equ 8
EGD_FRAME equ 24                  ; + 1 push = 32, so rsp is 16-aligned
DEF_FUNC eg_dealloc, EGD_FRAME
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyExceptionGroupObject.exc_value]
    XDECREF_V rdi, rsi
.no_val:

    ; XDECREF exc_tb
    mov rdi, [rbx + PyExceptionGroupObject.exc_tb]
    test rdi, rdi
    jz .no_tb
    call obj_decref
.no_tb:

    ; XDECREF exc_context
    mov rdi, [rbx + PyExceptionGroupObject.exc_context]
    test rdi, rdi
    jz .no_ctx
    call obj_decref
.no_ctx:

    ; XDECREF exc_cause
    mov rdi, [rbx + PyExceptionGroupObject.exc_cause]
    test rdi, rdi
    jz .no_cause
    call obj_decref
.no_cause:

    ; XDECREF exc_args
    mov rdi, [rbx + PyExceptionGroupObject.exc_args]
    test rdi, rdi
    jz .no_args
    call obj_decref
.no_args:

    ; XDECREF eg_exceptions
    mov rdi, [rbx + PyExceptionGroupObject.eg_exceptions]
    test rdi, rdi
    jz .no_excs
    call obj_decref
.no_excs:

    ; Save ob_type before freeing: gc_dealloc reads it, then frees.  A frame
    ; slot rather than a push, so both calls below stay 16-aligned.
    mov rax, [rbx + PyObject.ob_type]
    mov [rbp - EGD_TYPE], rax

    ; Free the object (GC-aware), matching eg_new's gc_alloc
    mov rdi, rbx
    call gc_dealloc

    ; Release the class AFTER the instance, matching eg_new's count.
    mov rdi, [rbp - EGD_TYPE]
    call obj_decref

    pop rbx
    leave
    ret
END_FUNC eg_dealloc

;; ============================================================================
;; eg_traverse(PyExceptionGroupObject *eg) -> visits every reference it owns
;;
;; A group is an exception plus one more reference -- the tuple of the
;; exceptions it holds -- so it visits that and hands the rest to
;; exc_traverse.  Without it a group's instances are tracked and report no
;; outgoing references, and no cycle through one is ever collectable.
;; ============================================================================
DEF_FUNC eg_traverse, 8         ; + 1 push = 16, so `call r14` is aligned
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyExceptionGroupObject.eg_exceptions]
    VISIT_PTR rdi

    mov rdi, rbx
    call exc_traverse

    pop rbx
    leave
    ret
END_FUNC eg_traverse

;; ============================================================================
;; eg_clear(PyExceptionGroupObject *eg) -> drops every reference it owns
;; The collector's half of eg_traverse.
;; ============================================================================
DEF_FUNC eg_clear, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyExceptionGroupObject.eg_exceptions]
    mov qword [rbx + PyExceptionGroupObject.eg_exceptions], 0
    test rdi, rdi
    jz .egc_no_excs
    call obj_decref
.egc_no_excs:

    mov rdi, rbx
    call exc_clear_gc

    pop rbx
    leave
    ret
END_FUNC eg_clear

;; ============================================================================
;; eg_str(PyExceptionGroupObject *eg) -> (rax = str, edx = TAG_PTR), or (0, 0)
;;
;; CPython's BaseExceptionGroup_str: "%S (%zd sub-exception%s)".  This was
;; `jmp exc_str`, which printed the args tuple -- "('m', [ValueError(1)])"
;; where CPython says "m (1 sub-exception)".
;; ============================================================================
EST_MSG   equ 8
EST_BUF   equ 16
EST_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC eg_str, EST_FRAME
    push rbx
    mov rbx, rdi

    ; The message, as a string.  The constructor requires a str, but str() of
    ; it costs nothing and is what CPython's %S does.
    mov rdi, [rbx + PyExceptionGroupObject.exc_value]
    extern obj_str
    call obj_str
    V_UNPACK rax, rdx
    test edx, edx
    jz .est_failed
    mov [rbp - EST_MSG], rax

    ; The message, then at most " (18446744073709551615 sub-exceptions)".
    mov rdi, [rax + PyVarObject.ob_size]
    add rdi, 64
    extern ap_malloc
    call ap_malloc
    mov [rbp - EST_BUF], rax

    mov rdi, rax
    mov rsi, [rbp - EST_MSG]
    mov rdx, [rsi + PyVarObject.ob_size]
    lea rsi, [rsi + PyStrObject.data]
    extern ap_memcpy
    call ap_memcpy
    mov rax, [rbp - EST_BUF]
    mov rcx, [rbp - EST_MSG]
    add rax, [rcx + PyVarObject.ob_size]

    mov rdi, rax
    CSTRING rsi, " ("
    extern rbt_append_cstr
    call rbt_append_cstr

    mov rdi, rax
    mov rsi, [rbx + PyExceptionGroupObject.eg_exceptions]
    mov rsi, [rsi + PyVarObject.ob_size]
    extern msg_append_i64
    call msg_append_i64

    mov rdi, rax
    CSTRING rsi, " sub-exception"
    call rbt_append_cstr

    mov rcx, [rbx + PyExceptionGroupObject.eg_exceptions]
    cmp qword [rcx + PyVarObject.ob_size], 1
    jle .est_singular
    mov rdi, rax
    CSTRING rsi, "s"
    call rbt_append_cstr
.est_singular:
    mov rdi, rax
    CSTRING rsi, ")"
    call rbt_append_cstr

    mov rdi, [rbp - EST_BUF]
    extern str_from_cstr_heap
    call str_from_cstr_heap
    push rax
    push rax                    ; and a pad, for the alignment
    mov rdi, [rbp - EST_BUF]
    extern ap_free
    call ap_free
    mov rdi, [rbp - EST_MSG]
    extern obj_decref
    call obj_decref
    pop rax
    pop rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.est_failed:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
END_FUNC eg_str

;; ============================================================================
;; eg_setattr(rdi = the group, rsi = the name, rdx = the value Value,
;;            rcx = its tag) -> rax = 0, or does not return
;;
;; The two names eg_getattr answers out of the object's FIELDS are read-only,
;; as CPython's member table has them.  exc_setattr would have put them in the
;; instance dict, where nothing ever reads them again: `g.message = "x"` was
;; accepted and then invisible.  Everything else is an ordinary exception
;; attribute and goes to exc_setattr.
;; ============================================================================
EST2_NAME  equ 8
EST2_SELF  equ 16
EST2_VAL   equ 24
EST2_TAG   equ 32
EST2_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC eg_setattr, EST2_FRAME
    mov [rbp - EST2_SELF], rdi
    mov [rbp - EST2_NAME], rsi
    mov [rbp - EST2_VAL], rdx
    mov [rbp - EST2_TAG], rcx

    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "message"
    call ap_strcmp
    test eax, eax
    jz .egs_readonly

    mov rdi, [rbp - EST2_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "exceptions"
    call ap_strcmp
    test eax, eax
    jz .egs_readonly

    mov rdi, [rbp - EST2_SELF]
    mov rsi, [rbp - EST2_NAME]
    mov rdx, [rbp - EST2_VAL]
    mov rcx, [rbp - EST2_TAG]
    leave
    jmp exc_setattr

.egs_readonly:
    leave
    RAISE exc_AttributeError_type, "readonly attribute"
END_FUNC eg_setattr

;; ============================================================================
;; eg_getattr(PyExceptionGroupObject *eg, PyStrObject *name) -> rax = Value or NULL
;; Handle: message, exceptions, args, __context__, __cause__, __traceback__
;; ============================================================================
DEF_FUNC eg_getattr
    push rbx
    push r12

    mov rbx, rdi            ; eg
    mov r12, rsi            ; name

    ; Check "message"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "message"
    call ap_strcmp
    test eax, eax
    jz .get_message

    ; Check "exceptions"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "exceptions"
    call ap_strcmp
    test eax, eax
    jz .get_exceptions

    ; Fall through to exc_getattr for args, __context__, __cause__, __traceback__
    mov rdi, rbx
    mov rsi, r12
    pop r12
    pop rbx
    leave
    jmp exc_getattr

.get_message:
    ; Return exc_value (message string)
    mov rax, [rbx + PyExceptionGroupObject.exc_value]
    test rax, rax
    jz .return_none
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.get_exceptions:
    ; Return eg_exceptions tuple
    mov rax, [rbx + PyExceptionGroupObject.eg_exceptions]
    test rax, rax
    jz .return_none
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.return_none:
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC eg_getattr

;; ============================================================================
;; eg_split(PyExceptionGroupObject *eg, PyTypeObject *match_type)
;;   -> rax = match_eg (or NULL if none matched)
;;   -> rdx = rest_eg  (or NULL if all matched)
;;
;; CPython's BaseExceptionGroup.split, which RECURSES: a sub-exception that is
;; itself a group is split in turn and each half kept in the matching side, so
;; the nesting survives in both.  This walked one level, so
;; `except* KeyError` over
;; ExceptionGroup("outer", [ExceptionGroup("inner", [KeyError()]), OSError()])
;; matched only the OSError and left the outer group unhandled -- the nested
;; group went whole into `rest` because nothing asked whether it was a group.
;;
;; A sub-group that contributes to neither side appears in neither, which falls
;; out of the empty-list test: eg_half answers NULL for an empty half.
;; ============================================================================
EGS_EG       equ 8
EGS_MTYPE    equ 16
EGS_MLIST    equ 24
EGS_RLIST    equ 32
EGS_IDX      equ 40
EGS_COUNT    equ 48
EGS_SUBM     equ 56            ; a recursive call's two halves, held across the
EGS_SUBR     equ 64            ; appends that take them
; 72 and not 80: with three pushes the frame has to be 8 mod 16, as the 56 it
; replaced was.  An even multiple puts every call in here 8 out, and the first
; thing that notices is the allocator.
EGS_FRAME    equ 72            ; + 3 pushes = 96, 16-aligned
DEF_FUNC eg_split, EGS_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - EGS_EG], rdi
    mov [rbp - EGS_MTYPE], rsi

    ; Get exceptions tuple
    mov rax, [rdi + PyExceptionGroupObject.eg_exceptions]
    test rax, rax
    jz .split_no_excs
    mov rax, [rax + PyTupleObject.ob_size]
    mov [rbp - EGS_COUNT], rax
    jmp .split_lists
.split_no_excs:
    mov qword [rbp - EGS_COUNT], 0
.split_lists:
    ; list_new takes a CAPACITY, so rdi has to be cleared: left holding the
    ; group pointer it asked the allocator for a list of 2^46 slots.
    xor edi, edi
    call list_new
    mov [rbp - EGS_MLIST], rax
    test rax, rax
    jz .split_nomem
    xor edi, edi
    call list_new
    mov [rbp - EGS_RLIST], rax
    test rax, rax
    jz .split_nomem

    ; Iterate sub-exceptions
    mov qword [rbp - EGS_IDX], 0
.split_loop:
    mov rcx, [rbp - EGS_IDX]
    cmp rcx, [rbp - EGS_COUNT]
    jge .split_done

    ; Get exc = eg.eg_exceptions[i]
    mov rax, [rbp - EGS_EG]
    mov rax, [rax + PyExceptionGroupObject.eg_exceptions]
    mov r8, [rax + PyTupleObject.ob_item]
    mov rdi, [r8 + rcx*8]

    ; A sub-exception that is itself a GROUP is split in turn, whether or not
    ; the group as a whole isinstance-matches: CPython asks the leaves.
    call eg_is_base_exception_group
    test eax, eax
    jnz .split_nested

    mov rcx, [rbp - EGS_IDX]
    mov rax, [rbp - EGS_EG]
    mov rax, [rax + PyExceptionGroupObject.eg_exceptions]
    mov r8, [rax + PyTupleObject.ob_item]
    mov rdi, [r8 + rcx*8]

    ; exc_isinstance(exc, match_type)
    mov rsi, [rbp - EGS_MTYPE]
    call exc_isinstance
    test eax, eax
    jz .split_rest

    ; Match: append to match_list
    mov rcx, [rbp - EGS_IDX]
    mov rax, [rbp - EGS_EG]
    mov rax, [rax + PyExceptionGroupObject.eg_exceptions]
    mov r8, [rax + PyTupleObject.ob_item]
    mov rsi, [r8 + rcx*8]
    mov rdi, [rbp - EGS_MLIST]
    call list_append
    jmp .split_next

.split_rest:
    ; No match: append to rest_list
    mov rcx, [rbp - EGS_IDX]
    mov rax, [rbp - EGS_EG]
    mov rax, [rax + PyExceptionGroupObject.eg_exceptions]
    mov r8, [rax + PyTupleObject.ob_item]
    mov rsi, [r8 + rcx*8]
    mov rdi, [rbp - EGS_RLIST]
    call list_append
    jmp .split_next

.split_nested:
    ; Recurse.  Each half that came back is a NEW group this frame owns, where
    ; the flat path above appends a borrowed element -- so each append is
    ; followed by a release of our own reference.
    ;
    ; rdi is re-read: eg_is_base_exception_group walks an MRO and uses rdi as
    ; the scratch for type_mro_next, so the sub-exception is not still in it.
    ; Recursing on whatever was left ran until the allocator gave up.
    mov rcx, [rbp - EGS_IDX]
    mov rax, [rbp - EGS_EG]
    mov rax, [rax + PyExceptionGroupObject.eg_exceptions]
    mov r8, [rax + PyTupleObject.ob_item]
    mov rdi, [r8 + rcx*8]
    mov rsi, [rbp - EGS_MTYPE]
    call eg_split
    mov [rbp - EGS_SUBM], rax
    mov [rbp - EGS_SUBR], rdx

    cmp qword [rbp - EGS_SUBM], 0
    je .split_nested_rest
    mov rdi, [rbp - EGS_MLIST]
    mov rsi, [rbp - EGS_SUBM]
    call list_append
    mov rdi, [rbp - EGS_SUBM]
    call obj_decref
.split_nested_rest:
    cmp qword [rbp - EGS_SUBR], 0
    je .split_next
    mov rdi, [rbp - EGS_RLIST]
    mov rsi, [rbp - EGS_SUBR]
    call list_append
    mov rdi, [rbp - EGS_SUBR]
    call obj_decref

.split_next:
    inc qword [rbp - EGS_IDX]
    jmp .split_loop

.split_done:
    mov rdi, [rbp - EGS_EG]
    mov rsi, [rbp - EGS_MLIST]
    call eg_half
    mov r12, rax                    ; r12 = match_eg, or 0

    mov rdi, [rbp - EGS_EG]
    mov rsi, [rbp - EGS_RLIST]
    call eg_half
    mov r13, rax                    ; r13 = rest_eg, or 0

    ; DECREF the two temp lists.  eg_half gave each new group a reference of
    ; its own, through args[1].
    push r12
    push r13
    mov rdi, [rbp - EGS_MLIST]
    call obj_decref
    mov rdi, [rbp - EGS_RLIST]
    call obj_decref
    pop r13
    pop r12

    ; Return: rax = match_eg, rdx = rest_eg
    mov rax, r12
    mov rdx, r13

    pop r13
    pop r12
    pop rbx
    leave
    ret

.split_nomem:
    ; list_new failed.  Unreachable while ap_malloc's contract holds -- out of
    ; memory is fatal_error there, not a NULL -- but the arm exists, so it has
    ; to be right: on the SECOND failure the first list is already owned.
    ;
    ; Only MLIST.  EGS_RLIST is not merely NULL on the first failure, it is
    ; uninitialised frame memory, so releasing it unguarded would decref
    ; whatever was there; and on the second failure it holds the 0 just stored.
    mov rdi, [rbp - EGS_MLIST]
    test rdi, rdi
    jz .split_nomem_out
    call obj_decref
.split_nomem_out:
    xor eax, eax
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC eg_split

;; ============================================================================
;; eg_half(rdi = the group being split, rsi = a LIST of exceptions)
;;   -> rax = a new group carrying them, or 0 when the list is empty
;;
;; One of the two halves.  eg_exceptions is a TUPLE, so the list is copied into
;; one -- but `.args` holds the sequence as PASSED, which for CPython's split is
;; the list `derive` was handed: `eg.split(T)[0].args` is ('msg', [...]) there
;; and was ('msg', (...)) here, because eg_new stores what it is given in both
;; places and only the constructor corrected it.
;;
;; The new group comes from the source's own derive(), as CPython's split does,
;; so a subclass decides what its halves are: the default derive builds a plain
;; BaseExceptionGroup -- whose constructor picks ExceptionGroup when every
;; member is an Exception -- and an override builds whatever it likes.  Building
;; from the group's own ob_type instead, which is what this did, made a subclass
;; of ExceptionGroup split into more of itself.
;; ============================================================================
EGH_EG    equ 8
EGH_LIST  equ 16
EGH_TUPLE equ 24
EGH_NEW   equ 32
EGH_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC_LOCAL eg_half, EGH_FRAME
    push rbx
    mov [rbp - EGH_EG], rdi
    mov [rbp - EGH_LIST], rsi

    mov rcx, [rsi + PyListObject.ob_size]
    test rcx, rcx
    jz .egh_empty

    mov rdi, rcx
    call tuple_new
    test rax, rax
    jz .egh_empty
    mov [rbp - EGH_TUPLE], rax

    mov rbx, rax                    ; rbx = the tuple
    mov rax, [rbp - EGH_LIST]
    mov rcx, [rax + PyListObject.ob_size]
    mov r8, [rax + PyListObject.ob_item]
    xor edx, edx
.egh_copy:
    cmp rdx, rcx
    jge .egh_copied
    push rcx
    push r8
    mov rdi, [r8 + rdx*8]
    V_UNPACK rdi, r11
    INCREF_VAL rdi, r11
    mov r10, [rbx + PyTupleObject.ob_item]
    V_PACK rdi, r11
    mov [r10 + rdx*8], rdi
    pop r8
    pop rcx
    inc rdx
    jmp .egh_copy
.egh_copied:
    ; The tuple is not what the new group is built FROM any more -- derive is
    ; handed the list, as CPython hands it -- but it is what eg_exceptions has
    ; to end up holding, and the derived group's constructor makes its own.  So
    ; the tuple is only the thing this frame must not leak.
    mov rdi, [rbp - EGH_TUPLE]
    call obj_decref
    mov qword [rbp - EGH_TUPLE], 0

    mov rdi, [rbp - EGH_EG]
    mov rsi, [rbp - EGH_LIST]
    call eg_derive
    pop rbx
    leave
    ret

.egh_drop_tuple:
    mov rdi, [rbp - EGH_TUPLE]
    call obj_decref
    xor eax, eax
    pop rbx
    leave
    ret

.egh_empty:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC eg_half

;; ============================================================================
;; eg_derive(rdi = the source group, rsi = a LIST of exceptions)
;;   -> rax = a new group, or 0 with an exception pending
;;
;; CPython's split and subgroup both build their halves through the group's own
;; derive(), and then copy the metadata the original carried.  Looking the name
;; up rather than calling the default directly is the whole point: a subclass
;; that defines derive decides what its halves are.
;; ============================================================================
EGDV_EG    equ 8
EGDV_LIST  equ 16
EGDV_NEW   equ 24
EGDV_NOTES equ 32            ; __notes__ as obj_getattr_opt answered it: a Value
EGDV_COPY  equ 40            ; list(__notes__), the copy that is stored
EGDV_FRAME equ 56            ; + 1 push = 64, 16-aligned
DEF_FUNC_LOCAL eg_derive, EGDV_FRAME
    push rbx
    mov [rbp - EGDV_EG], rdi
    mov [rbp - EGDV_LIST], rsi

    CSTRING rdi, "derive"
    call str_from_cstr_heap
    test rax, rax
    jz .egd_fail
    mov rbx, rax
    mov rdi, [rbp - EGDV_EG]
    mov rsi, rbx
    call obj_getattr_opt            ; bound, through the MRO
    push rax
    push rax
    mov rdi, rbx
    call obj_decref                 ; the name
    pop rax
    pop rax
    test rax, rax
    jz .egd_fail                    ; no derive at all: cannot happen once
                                    ; eg_install_methods has run, and a pending
                                    ; exception is the honest answer if it does
    mov rbx, rax                    ; rbx = the bound derive
    sub rsp, 16
    mov rax, [rbp - EGDV_LIST]
    mov [rsp], rax
    mov rdi, rbx
    mov rsi, rsp
    mov edx, 1
    call obj_call_n
    add rsp, 16
    mov [rbp - EGDV_NEW], rax
    push rax
    push rax
    mov rdi, rbx
    call obj_decref                 ; the bound method
    pop rax
    pop rax
    test rax, rax
    jz .egd_fail

    ; derive() may answer anything; CPython requires a BaseExceptionGroup.
    V_TEST_PTR rax, rcx
    ja .egd_bad
    mov rdi, rax
    call eg_is_base_exception_group
    test eax, eax
    jz .egd_bad_ref

    ; The metadata CPython copies onto each half: the traceback, the cause, the
    ; context, the suppress flag and __notes__.  Without them a split loses the
    ; traceback of the group it came from.
    mov rbx, [rbp - EGDV_NEW]
    mov rax, [rbp - EGDV_EG]
    mov rcx, [rax + PyExceptionGroupObject.exc_tb]
    test rcx, rcx
    jz .egd_no_tb
    mov rdi, rcx
    call obj_incref
    mov rbx, [rbp - EGDV_NEW]
    mov rax, [rbp - EGDV_EG]
    mov rcx, [rax + PyExceptionGroupObject.exc_tb]
    mov rdx, [rbx + PyExceptionGroupObject.exc_tb]
    mov [rbx + PyExceptionGroupObject.exc_tb], rcx
    test rdx, rdx
    jz .egd_no_tb
    mov rdi, rdx
    call obj_decref
.egd_no_tb:
    mov rbx, [rbp - EGDV_NEW]
    mov rax, [rbp - EGDV_EG]
    mov rcx, [rax + PyExceptionGroupObject.exc_cause]
    test rcx, rcx
    jz .egd_no_cause
    mov rdi, rcx
    call obj_incref
    mov rbx, [rbp - EGDV_NEW]
    mov rax, [rbp - EGDV_EG]
    mov rcx, [rax + PyExceptionGroupObject.exc_cause]
    mov [rbx + PyExceptionGroupObject.exc_cause], rcx
.egd_no_cause:
    mov rbx, [rbp - EGDV_NEW]
    mov rax, [rbp - EGDV_EG]
    mov rcx, [rax + PyExceptionGroupObject.exc_context]
    test rcx, rcx
    jz .egd_no_context
    mov rdi, rcx
    call obj_incref
    mov rbx, [rbp - EGDV_NEW]
    mov rax, [rbp - EGDV_EG]
    mov rcx, [rax + PyExceptionGroupObject.exc_context]
    mov [rbx + PyExceptionGroupObject.exc_context], rcx
.egd_no_context:
    mov rbx, [rbp - EGDV_NEW]
    mov rax, [rbp - EGDV_EG]
    mov rcx, [rax + PyExceptionGroupObject.exc_suppress]
    mov [rbx + PyExceptionGroupObject.exc_suppress], rcx

    ; __notes__, which lives in the instance dict.  CPython copies it onto the
    ; derived group only when it is a SEQUENCE, and copies it as a LIST --
    ; PySequence_List -- so a str arrives as a list of its characters and a
    ; tuple as a list.  Anything else is left alone rather than reported:
    ; split() is not a good place to tell a program it put a number there.
    ;
    ; obj_getattr_opt answers a VALUE.  This released it with obj_decref, which
    ; dereferences whatever it is handed, so `eg.__notes__ = 5` decremented a
    ; refcount at address 5 -- which is exactly what CPython's own
    ; test_split_does_not_copy_non_sequence_notes does.  DECREF_V is the
    ; release that admits an immediate.  The block above copies exc_tb,
    ; exc_cause and exc_context with a plain obj_incref/obj_decref and is right
    ; to: those are genuine PyObject* fields on the group.  This one borrowed
    ; that idiom across the boundary where it stops being true.
    CSTRING rdi, "__notes__"
    call str_from_cstr_heap
    test rax, rax
    jz .egd_done
    mov rbx, rax                    ; rbx = the name, for the rest of the block
    mov rdi, [rbp - EGDV_EG]
    mov rsi, rbx
    call obj_getattr_opt
    mov [rbp - EGDV_NOTES], rax
    test rax, rax
    jz .egd_notes_absent

    ; PySequence_Check: not a dict, and the type answers sq_item.  An immediate
    ; is not a pointer, so it is never a sequence and never gets this far.
    V_TEST_PTR rax, rcx
    ja .egd_notes_release
    mov rcx, [rax + PyObject.ob_type]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_DICT_SUBCLASS
    jnz .egd_notes_release
    mov rcx, [rcx + PyTypeObject.tp_as_sequence]
    test rcx, rcx
    jz .egd_notes_release
    cmp qword [rcx + PySequenceMethods.sq_item], 0
    je .egd_notes_release

    ; list(notes): the shallow copy, so each half carries a notes list of its
    ; own and appending to one does not reach the other.
    lea rdi, [rel list_type]
    lea rsi, [rbp - EGDV_NOTES]     ; the one-Value argument array
    mov edx, 1
    call obj_call_n
    mov [rbp - EGDV_COPY], rax
    test rax, rax
    jz .egd_notes_raised
    mov rdi, [rbp - EGDV_NEW]
    mov rsi, rbx
    mov rdx, rax
    mov ecx, TAG_PTR
    call exc_setattr
    mov rdi, [rbp - EGDV_COPY]
    call obj_decref                 ; exc_setattr took a reference of its own

.egd_notes_release:
    mov rdi, [rbp - EGDV_NOTES]
    DECREF_V rdi, rcx               ; obj_getattr_opt's reference, a Value
.egd_notes_absent:
    ; A missing __notes__ leaves an AttributeError pending, which is the
    ; ordinary answer to a lookup and not this function's failure.
    extern current_exception
    extern attr_error_pending
    cmp qword [rel current_exception], 0
    je .egd_notes_clean
    cmp qword [rel attr_error_pending], 0
    je .egd_notes_clean
    mov qword [rel current_exception], 0
.egd_notes_clean:
    mov rdi, rbx
    call obj_decref                 ; the name

.egd_done:
    mov rax, [rbp - EGDV_NEW]
    pop rbx
    leave
    ret

.egd_notes_raised:
    ; list(__notes__) raised.  The notes Value and the name are still ours, and
    ; the half that was built has to go: eg_derive answers 0 only with an
    ; exception pending, so returning the group here would hand the caller both
    ; a result and a pending raise.
    mov rdi, [rbp - EGDV_NOTES]
    DECREF_V rdi, rcx
    mov rdi, rbx
    call obj_decref                 ; the name
    mov rdi, [rbp - EGDV_NEW]
    call obj_decref
    xor eax, eax
    pop rbx
    leave
    ret

.egd_bad_ref:
    mov rdi, [rbp - EGDV_NEW]
    call obj_decref
.egd_bad:
    mov rsi, [rbp - EGDV_NEW]
    CSTRING rdi, `derive must return an instance of BaseExceptionGroup, not '\x01'`
    call raise_type_error_with_name
.egd_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC eg_derive

;; ============================================================================
;; eg_method_derive(rdi = args Value*, rsi = nargs)
;;   -> rax = BaseExceptionGroup(self.message, excs), or 0
;;
;; BaseExceptionGroup.derive(self, excs).  The default, which is why a subclass
;; of ExceptionGroup splits into ExceptionGroup and not into more of itself: the
;; constructor picks the class from the contents, as BaseExceptionGroup.__new__
;; does.
;; ============================================================================
; The two constructor arguments, adjacent and in order, because eg_type_call
; reads them as an args array.
EMD_EXCS  equ 8
EMD_MSG   equ 16
EMD_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL eg_method_derive, EMD_FRAME
    cmp rsi, 2
    jne .emd_arity
    mov rax, [rdi]                  ; self
    mov rcx, [rdi + 8]              ; excs
    mov [rbp - EMD_EXCS], rcx
    mov rax, [rax + PyExceptionGroupObject.exc_value]
    mov [rbp - EMD_MSG], rax
    lea rdi, [rel exc_BaseExceptionGroup_type]
    lea rsi, [rbp - EMD_MSG]
    mov edx, 2
    call eg_type_call
    leave
    ret
.emd_arity:
    dec rsi
    CSTRING rdi, "BaseExceptionGroup.derive() takes exactly one argument ("
    CSTRING rdx, " given)"
    jmp raise_type_error_counted
END_FUNC eg_method_derive

;; ============================================================================
;; eg_method_split(rdi = args Value*, rsi = nargs)
;;   -> rax = a (match, rest) tuple, each half a group or None, or 0
;;
;; BaseExceptionGroup.split(self, condition).  The splitting existed only as the
;; thing `except*` calls, so a program could not do it itself.  The condition is
;; a type or a tuple of them -- the callable form CPython also takes is not
;; here, and `except*` does not need it.
;; ============================================================================
EMS_SELF  equ 8
EMS_MATCH equ 16
EMS_REST  equ 24
EMS_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC_LOCAL eg_method_split, EMS_FRAME
    cmp rsi, 2
    jne .ems_arity
    mov rax, [rdi]
    mov [rbp - EMS_SELF], rax
    mov rsi, [rdi + 8]              ; the condition
    mov rdi, rax
    call eg_split
    mov [rbp - EMS_MATCH], rax
    mov [rbp - EMS_REST], rdx

    mov edi, 2
    call tuple_new
    test rax, rax
    jz .ems_fail
    mov r8, [rax + PyTupleObject.ob_item]
    mov rcx, [rbp - EMS_MATCH]
    test rcx, rcx
    jnz .ems_have_match
    lea rcx, [rel none_singleton]
    inc qword [rcx + PyObject.ob_refcnt]
.ems_have_match:
    mov [r8], rcx
    mov rcx, [rbp - EMS_REST]
    test rcx, rcx
    jnz .ems_have_rest
    lea rcx, [rel none_singleton]
    inc qword [rcx + PyObject.ob_refcnt]
.ems_have_rest:
    mov [r8 + 8], rcx
    mov edx, TAG_PTR
    leave
    ret
.ems_fail:
    ; tuple_new failed, which ap_malloc's contract says cannot happen -- but
    ; both halves eg_split handed over are OURS, and dropping them here would
    ; leak two fresh groups.
    mov rdi, [rbp - EMS_MATCH]
    test rdi, rdi
    jz .ems_drop_rest
    call obj_decref
.ems_drop_rest:
    mov rdi, [rbp - EMS_REST]
    test rdi, rdi
    jz .ems_out
    call obj_decref
.ems_out:
    xor eax, eax
    xor edx, edx
    leave
    ret
.ems_arity:
    dec rsi
    CSTRING rdi, "BaseExceptionGroup.split() takes exactly one argument ("
    CSTRING rdx, " given)"
    jmp raise_type_error_counted
END_FUNC eg_method_split

;; ============================================================================
;; eg_method_subgroup(rdi = args Value*, rsi = nargs)
;;   -> rax = the match half, or None, or 0
;;
;; BaseExceptionGroup.subgroup(self, condition): split's first half, with the
;; second released.
;; ============================================================================
ESG_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL eg_method_subgroup, ESG_FRAME
    cmp rsi, 2
    jne .esg_arity
    mov rax, [rdi]
    mov rsi, [rdi + 8]
    mov rdi, rax
    call eg_split
    ; The rest half is not this caller's; only the match is.
    test rdx, rdx
    jz .esg_have
    push rax
    push rax
    mov rdi, rdx
    call obj_decref
    pop rax
    pop rax
.esg_have:
    test rax, rax
    jnz .esg_out
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
.esg_out:
    mov edx, TAG_PTR
    leave
    ret
.esg_arity:
    dec rsi
    CSTRING rdi, "BaseExceptionGroup.subgroup() takes exactly one argument ("
    CSTRING rdx, " given)"
    jmp raise_type_error_counted
END_FUNC eg_method_subgroup

; EGI_ADD impl, "name" -- one method into BaseExceptionGroup's tp_dict.
; rbx holds the dict.  Above the docblock rather than below it, because
; lint walks back from the DEF_FUNC over the layout constants and stops
; at a %endmacro -- a docblock behind one reads as absent.
%macro EGI_ADD 2
    CSTRING rdi, %2
    call str_from_cstr_heap
    mov [rbp - EGI_KEY], rax
    lea rdi, [rel %1]
    CSTRING rsi, %2
    call builtin_func_new
    mov [rbp - EGI_FN], rax
    mov rdi, rbx
    mov rsi, [rbp - EGI_KEY]
    mov rdx, rax
    call dict_set
    mov rdi, [rbp - EGI_KEY]
    call obj_decref
    mov rdi, [rbp - EGI_FN]
    call obj_decref
%endmacro

;; ============================================================================
;; eg_install_methods() -> nothing; BaseExceptionGroup.tp_dict is left holding
;;   split, subgroup and derive, or left at 0 if the dict could not be made.
;;
;; One dict on BaseExceptionGroup serves ExceptionGroup too: eg_getattr walks
;; the type MRO's tp_dicts, so both builtins and every user subclass reach it.
;; Modelled on exc_install_methods, stamp included -- that is what makes
;; `g.split(T)` check its receiver.
;; ============================================================================
EGI_KEY   equ 8
EGI_FN    equ 16
EGI_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC eg_install_methods, EGI_FRAME
    push rbx
    call dict_new
    test rax, rax
    jz .egi_out
    mov rbx, rax
    mov [rel exc_BaseExceptionGroup_type + PyTypeObject.tp_dict], rbx

    EGI_ADD eg_method_split, "split"
    EGI_ADD eg_method_subgroup, "subgroup"
    EGI_ADD eg_method_derive, "derive"
    ; PEP 585, as CPython's: BaseExceptionGroup[E] is a GenericAlias, and
    ; pytest subclasses `AbstractRaises[BaseExceptionGroup[...]]` at import.
    mov rdi, rbx
    extern add_class_getitem
    call add_class_getitem

    lea rdi, [rel exc_BaseExceptionGroup_type]
    call type_stamp_methods
.egi_out:
    pop rbx
    leave
    ret
END_FUNC eg_install_methods

;; ============================================================================
;; eg_is_base_exception_group(PyObject *obj) -> int (0/1)
;; Check if obj's type (or base chain) has tp_dealloc == eg_dealloc.
;; ============================================================================
DEF_FUNC_BARE eg_is_base_exception_group
    mov rax, [rdi + PyObject.ob_type]
    mov r10, rax                    ; origin of the walk
    lea rdx, [rel eg_dealloc]
.walk:
    test rax, rax
    jz .no
    cmp [rax + PyTypeObject.tp_dealloc], rdx
    je .yes
    push r10
    push rdx
    mov rdi, r10
    mov rsi, rax
    extern type_mro_next
    call type_mro_next
    pop rdx
    pop r10
    jmp .walk
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret
END_FUNC eg_is_base_exception_group

;; ============================================================================
;; prep_reraise_star(orig, excs_list) -> PyObject*
;; Filter Nones from excs_list, merge remaining into new EG if needed.
;; rdi = orig exception (owned ref), rsi = list of rest values (owned ref)
;; Returns: None (all handled) or exception to re-raise (new ref).
;; Consumes references to both orig and excs_list.
;; ============================================================================
PRS_ORIG  equ 8
PRS_LIST  equ 16
PRS_FIRST equ 24
PRS_FLAT  equ 32
PRS_FRAME equ 32            ; + 2 pushes = 48
DEF_FUNC prep_reraise_star, PRS_FRAME
    push rbx
    push r12

    mov [rbp - PRS_ORIG], rdi
    mov [rbp - PRS_LIST], rsi

    ; Phase 1: Count non-None entries, find first non-None
    mov rcx, [rsi + PyListObject.ob_size]
    mov rsi, [rsi + PyListObject.ob_item]
    xor ebx, ebx                ; non-None count
    xor r12d, r12d              ; first non-None ptr
    xor edx, edx
    lea r8, [rel none_singleton]
.scan:
    cmp rdx, rcx
    jge .scan_done
    mov rdi, [rsi + rdx*8]     ; list item
    cmp rdi, r8                 ; skip None
    je .scan_next
    inc ebx
    test r12, r12
    jnz .scan_next
    mov r12, rdi                ; save first non-None
.scan_next:
    inc rdx
    jmp .scan
.scan_done:
    mov [rbp - PRS_FIRST], r12

    test ebx, ebx
    jz .all_none
    cmp ebx, 1
    je .single

    ; Multiple non-None: check if orig is an ExceptionGroup
    mov rdi, [rbp - PRS_ORIG]
    call eg_is_base_exception_group
    test eax, eax
    jz .not_eg

    ; orig IS an EG: flatten sub-exceptions from all non-None rest items
    xor edi, edi
    call list_new
    mov [rbp - PRS_FLAT], rax

    ; Iterate excs_list, collect sub-exceptions from non-None items
    mov rax, [rbp - PRS_LIST]
    mov rcx, [rax + PyListObject.ob_size]
    xor edx, edx
.flat_loop:
    cmp rdx, rcx
    jge .flat_done
    mov rax, [rbp - PRS_LIST]
    mov rsi, [rax + PyListObject.ob_item]      ; payload array
    mov rdi, [rsi + rdx*8]                    ; list item
    lea r8, [rel none_singleton]
    cmp rdi, r8
    je .flat_next

    ; non-None item — check if it's an EG
    push rdx
    push rcx
    call eg_is_base_exception_group
    pop rcx
    pop rdx
    test eax, eax
    jz .flat_append_single

    ; It's an EG: append each sub-exception from eg_exceptions tuple
    mov rax, [rbp - PRS_LIST]
    mov rsi, [rax + PyListObject.ob_item]       ; payloads
    mov rdi, [rsi + rdx*8]                      ; the EG payload
    mov rax, [rdi + PyExceptionGroupObject.eg_exceptions]
    mov r8, [rax + PyTupleObject.ob_size]
    push rdx
    push rcx
    xor ecx, ecx
.sub_loop:
    cmp rcx, r8
    jge .sub_done
    push rcx
    push r8
    push rax
    mov r9, [rax + PyTupleObject.ob_item]       ; payloads
    mov rsi, [r9 + rcx*8]
    mov rdi, [rbp - PRS_FLAT]
    call list_append
    pop rax
    pop r8
    pop rcx
    inc rcx
    jmp .sub_loop
.sub_done:
    pop rcx
    pop rdx
    jmp .flat_next

.flat_append_single:
    ; Non-EG exception: append directly
    push rdx
    push rcx
    mov rax, [rbp - PRS_LIST]
    mov rsi, [rax + PyListObject.ob_item]       ; payloads
    mov rsi, [rsi + rdx*8]                       ; list item payload
    mov rdi, [rbp - PRS_FLAT]
    call list_append
    pop rcx
    pop rdx

.flat_next:
    inc rdx
    jmp .flat_loop

.flat_done:
    ; Convert flat list to tuple
    mov rax, [rbp - PRS_FLAT]
    mov rcx, [rax + PyListObject.ob_size]
    push rcx
    mov edi, ecx
    call tuple_new
    mov rbx, rax                   ; rbx = new tuple
    pop rcx
    mov rax, [rbp - PRS_FLAT]
    mov r8, [rax + PyListObject.ob_item]       ; list payloads
    xor edx, edx
.copy_flat:
    cmp rdx, rcx
    jge .copy_flat_done
    push rcx
    mov rdi, [r8 + rdx*8]      ; list item payload
    V_UNPACK rdi, r11
    INCREF_VAL rdi, r11
    mov r10, [rbx + PyTupleObject.ob_item]       ; tuple payloads
    V_PACK rdi, r11
    mov [r10 + rdx * 8], rdi
    pop rcx
    inc rdx
    jmp .copy_flat
.copy_flat_done:

    ; Create new EG(orig.ob_type, orig.exc_value, flat_tuple)
    mov rax, [rbp - PRS_ORIG]
    mov rdi, [rax + PyExceptionGroupObject.ob_type]
    mov rsi, [rax + PyExceptionGroupObject.exc_value]
    mov rdx, rbx
    call eg_new
    mov r12, rax                   ; r12 = result

    ; DECREF the tuple (eg_new INCREFed it)
    mov rdi, rbx
    call obj_decref
    ; DECREF flat list
    mov rdi, [rbp - PRS_FLAT]
    call obj_decref

    mov rax, r12
    jmp .cleanup

.not_eg:
    ; orig is not EG — return first non-None
    mov rax, [rbp - PRS_FIRST]
    INCREF rax
    jmp .cleanup

.single:
    ; Single non-None: return it
    mov rax, r12
    INCREF rax
    jmp .cleanup

.all_none:
    ; All handled: return None
    lea rax, [rel none_singleton]
    INCREF rax

.cleanup:
    ; DECREF orig and excs_list
    push rax
    mov rdi, [rbp - PRS_LIST]
    call obj_decref
    mov rdi, [rbp - PRS_ORIG]
    call obj_decref
    pop rax

    pop r12
    pop rbx
    leave
    ret
END_FUNC prep_reraise_star

;; ============================================================================
;; Data section - ExceptionGroup type objects
;; ============================================================================
section .data

exc_name_BaseExceptionGroup: db "BaseExceptionGroup", 0
exc_name_ExceptionGroup:     db "ExceptionGroup", 0

; BaseExceptionGroup type — base = BaseException
align 8
global eg_install_methods
global exc_BaseExceptionGroup_type
exc_BaseExceptionGroup_type:
    dq 1                        ; ob_refcnt (immortal)
    dq exc_metatype             ; ob_type
    dq exc_name_BaseExceptionGroup ; tp_name
    dq PyExceptionGroupObject_size ; tp_basicsize
    dq eg_dealloc               ; tp_dealloc
    dq exc_repr                 ; tp_repr
    dq eg_str                   ; tp_str
    dq 0                        ; tp_hash
    dq 0                ; tp_call  (instances are not callable)
    dq eg_getattr               ; tp_getattr
    ; A setter at all.  There was none, so `e.__traceback__ = tb` on a group
    ; was "AttributeError: cannot set attribute" -- which is what unittest's
    ; _clean_tracebacks does to every error it reports, so CPython's
    ; test_exception_group could not even print its first failure.
    dq eg_setattr               ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq eg_type_call         ; tp_new  (constructor)
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq exc_BaseException_type   ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC        ; tp_flags
    dq 0                        ; tp_bases
    dq eg_traverse              ; tp_traverse
    dq eg_clear                 ; tp_clear
    dq PyExceptionObject.exc_dict ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; ExceptionGroup type — base = BaseExceptionGroup (also inherits from Exception)
align 8
global exc_ExceptionGroup_type
exc_ExceptionGroup_type:
    dq 1                        ; ob_refcnt (immortal)
    dq exc_metatype             ; ob_type
    dq exc_name_ExceptionGroup  ; tp_name
    dq PyExceptionGroupObject_size ; tp_basicsize
    dq eg_dealloc               ; tp_dealloc
    dq exc_repr                 ; tp_repr
    dq eg_str                   ; tp_str
    dq 0                        ; tp_hash
    dq 0                ; tp_call  (instances are not callable)
    dq eg_getattr               ; tp_getattr
    ; A setter at all.  There was none, so `e.__traceback__ = tb` on a group
    ; was "AttributeError: cannot set attribute" -- which is what unittest's
    ; _clean_tracebacks does to every error it reports, so CPython's
    ; test_exception_group could not even print its first failure.
    dq eg_setattr               ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq eg_type_call         ; tp_new  (constructor)
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq exc_BaseExceptionGroup_type ; tp_base
    dq 0                        ; tp_dict
    dq eg_mro_tuple             ; tp_mro
    dq TYPE_FLAG_HAVE_GC        ; tp_flags
    dq eg_bases_tuple           ; tp_bases
    dq eg_traverse              ; tp_traverse
    dq eg_clear                 ; tp_clear
    dq PyExceptionObject.exc_dict ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

;; ExceptionGroup is the one builtin with two bases: BaseExceptionGroup for
;; the group machinery and Exception so that `except Exception` catches it.
;; A tp_base chain cannot say that, so it carries a real MRO.
align 8
eg_mro_items:
    dq exc_ExceptionGroup_type
    dq exc_BaseExceptionGroup_type
    dq exc_Exception_type
    dq exc_BaseException_type
    dq object_type
align 8
eg_mro_tuple:
    dq 1                        ; ob_refcnt (immortal)
    dq tuple_type               ; ob_type
    dq 5                        ; ob_size
    dq -1                       ; ob_hash
    dq eg_mro_items             ; ob_item

align 8
eg_bases_items:
    dq exc_BaseExceptionGroup_type
    dq exc_Exception_type
align 8
eg_bases_tuple:
    dq 1                        ; ob_refcnt (immortal)
    dq tuple_type               ; ob_type
    dq 2                        ; ob_size
    dq -1                       ; ob_hash
    dq eg_bases_items           ; ob_item
