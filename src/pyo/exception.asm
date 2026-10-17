; exception.asm - Exception type objects and exception object creation
;
; Provides:
;   - PyTypeObject singletons for all standard Python exception types
;   - exc_new(type, msg_str) -> PyExceptionObject*
;   - exc_from_cstr(type, msg_cstr) -> PyExceptionObject*
;   - exc_isinstance(exc, type) -> bool (walks tp_base chain)
;   - exception_type_table[] for EXC_* ID -> PyTypeObject* lookup
;
; Exception hierarchy (simplified):
;   BaseException
;     Exception
;       TypeError, ValueError, RuntimeError, NotImplementedError,
;       LookupError (KeyError, IndexError),
;       ArithmeticError (ZeroDivisionError, OverflowError),
;       AttributeError, NameError, StopIteration,
;       AssertionError, OSError, RecursionError, UnicodeError

%include "macros.inc"
%include "object.inc"

extern exc_repr
extern exc_str
extern traceback_type
extern ap_memcpy
extern oserror_str
extern oserror_new
extern raise_oserror
extern raise_oserror_owned
extern raise_oserror_owned2
extern raise_oserror_build
extern type_number_methods

extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern ap_free
extern str_from_cstr
extern str_from_cstr_heap
extern obj_decref
extern obj_dealloc
extern obj_incref
extern str_type
extern type_getattr
extern type_repr
extern type_type
extern raise_exception_obj
extern str_new_heap
extern none_singleton
extern int_from_i64
extern int_is_integer
extern int_to_i64
extern int_type
extern obj_repr
extern obj_str
extern raise_exception
extern tuple_new
extern tuple_type
extern ap_strcmp
extern kw_names_pending
extern dict_get
extern dict_new
extern dict_set
extern eg_dealloc
extern exc_BaseExceptionGroup_type
extern exc_ExceptionGroup_type

;; ============================================================================
;; exc_new(PyTypeObject *type, PyObject *msg_str, int msg_tag) -> PyExceptionObject*
;; Creates a new exception with given type and message string.
;; msg_str and type are both INCREFed.
;; rdx = msg_tag (TAG_PTR for heap objs, TAG_SMALLINT for ints, 0 for NULL).
;; ============================================================================
EN_EXC equ 8
EN_FRAME equ 24            ; + 3 pushes = 48, 16-aligned
DEF_FUNC exc_new, EN_FRAME
    push rbx
    push r12
    push r13

    mov rbx, rdi            ; type
    mov r12, rsi            ; msg Value (0 = no message)

    ; Allocate exception object (GC-tracked), at the TYPE's size rather than
    ; at the base layout's.
    ;
    ; A fixed PyExceptionObject_size is right for the sixty-nine builtins and
    ; wrong for anything wider.  BaseExceptionGroup carries eg_exceptions past
    ; the end of that layout, so a group reaching here -- which is what
    ; `super().__new__(cls, msg, excs)` in an ExceptionGroup subclass does,
    ; through BaseException.__new__ -- was allocated eight bytes short and
    ; eg_split read the field off the end of the block.  A subclass with
    ; __slots__ is the same shape: type_from_parts puts them after
    ; tp_basicsize, which this was not consulting.
    ;
    ; Floored at the base size, because a type whose tp_basicsize is somehow
    ; smaller must still have room for the fields zeroed below.
    mov edi, PyExceptionObject_size
    mov rax, [rbx + PyTypeObject.tp_basicsize]
    cmp rax, rdi
    cmovg rdi, rax
    mov rsi, rbx               ; type
    call gc_alloc
    ; ob_refcnt=1, ob_type set by gc_alloc -- but gc_alloc does not count the
    ; type it stamps, and "exception types are immortal" is true of the
    ; sixty-nine builtin ones and false of every class a program writes.  An
    ; uncounted one is freed by the collector out from under live instances,
    ; because a class's only cycle is with its own MRO tuple.
    inc qword [rbx + PyObject.ob_refcnt]
    mov [rax + PyExceptionObject.exc_type], rbx
    mov [rax + PyExceptionObject.exc_value], r12
    mov qword [rax + PyExceptionObject.exc_tb], 0
    mov qword [rax + PyExceptionObject.exc_context], 0
    mov qword [rax + PyExceptionObject.exc_cause], 0
    mov qword [rax + PyExceptionObject.exc_args], 0
    mov qword [rax + PyExceptionObject.exc_dict], 0
    mov qword [rax + PyExceptionObject.exc_suppress], 0

    ; INCREF the message
    INCREF_V r12, r13

    ; Create args tuple: (msg,) if msg present, else ()
    mov [rbp - EN_EXC], rax   ; save exc
    test r12, r12             ; a NULL Value is 0 and no real Value is
    jz .empty_args
    mov edi, 1
    call tuple_new
    INCREF_V r12, r13
    mov r8, [rax + PyTupleObject.ob_item]
    mov [r8], r12
    jmp .set_args
.empty_args:
    xor edi, edi
    call tuple_new
.set_args:
    mov rcx, [rbp - EN_EXC]
    mov [rcx + PyExceptionObject.exc_args], rax

    ; Track in GC
    mov rdi, rcx
    call gc_track

    mov rax, [rbp - EN_EXC]

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC exc_new

;; ============================================================================
;; exc_is_exception(rdi = object) -> eax 0/1
;; True when the object is an instance of BaseException, i.e. when reading
;; PyExceptionObject.exc_context off it is defined.
;; ============================================================================
DEF_FUNC_BARE exc_is_exception
    V_TEST_PTR rdi, rax
    ja .nope
    test rdi, rdi
    jz .nope
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel exc_BaseException_type]
    extern type_is_subtype
    jmp type_is_subtype
.nope:
    xor eax, eax
    ret
END_FUNC exc_is_exception

;; ============================================================================
;; exc_set_context(rdi = new exception, rsi = exception being handled)
;; Implements CPython's implicit chaining: the exception raised while another
;; is being handled gets that one as its __context__.  The chain is first
;; scanned for `new` so a re-raise cannot make it point at itself.
;; ============================================================================
ESC_NEW equ 8
ESC_OLD equ 16
ESC_FRAME equ 16            ; + 0 pushes = 16
DEF_FUNC exc_set_context, ESC_FRAME
    cmp rdi, rsi
    je .esc_done
    mov [rbp - ESC_NEW], rdi
    mov [rbp - ESC_OLD], rsi
    call exc_is_exception
    test eax, eax
    jz .esc_done
    mov rdi, [rbp - ESC_OLD]
    call exc_is_exception
    test eax, eax
    jz .esc_done

    mov rdi, [rbp - ESC_NEW]
    mov rsi, [rbp - ESC_OLD]
    ; Break an existing link back to `new` so the chain stays acyclic -- and
    ; do not HANG on a cycle that is already there.  `ex.__context__ = ex` is
    ; a legal assignment, and this walked the resulting chain for ever;
    ; CPython's test_exceptions has two tests named for not hanging on exactly
    ; that (issue 25782).  Floyd's tortoise and hare, as _PyErr_SetObject
    ; does it: the tortoise moves every other step, and meeting it means the
    ; whole path has been visited and checked.
    mov rax, rsi                ; the hare
    mov r8, rsi                 ; the tortoise
    xor r9d, r9d                ; ...which moves on every other turn
.esc_scan:
    mov rcx, [rax + PyExceptionObject.exc_context]
    test rcx, rcx
    jz .esc_link
    cmp rcx, rdi
    je .esc_unlink
    mov rax, rcx
    cmp rax, r8
    je .esc_link                ; a cycle that was already there
    test r9d, r9d
    jz .esc_next
    mov r8, [r8 + PyExceptionObject.exc_context]
.esc_next:
    xor r9d, 1
    jmp .esc_scan

.esc_unlink:
    mov qword [rax + PyExceptionObject.exc_context], 0
    push rdi
    push rsi
    mov rdi, rcx
    call obj_decref
    pop rsi
    pop rdi

.esc_link:
    ; Drop whatever context `new` already had, then take a reference to `old`.
    mov rax, [rdi + PyExceptionObject.exc_context]
    test rax, rax
    jz .esc_store
    push rdi
    push rsi
    mov rdi, rax
    call obj_decref
    pop rsi
    pop rdi
.esc_store:
    INCREF rsi
    mov [rdi + PyExceptionObject.exc_context], rsi
.esc_done:
    leave
    ret
END_FUNC exc_set_context

;; ============================================================================
;; raise_key_error(rdi = key Value) -- does not return.
;; CPython reports the missing key itself as the exception's single argument,
;; so that KeyError('k') and str(e) == "'k'" carry which key was absent.
;; ============================================================================
DEF_FUNC raise_key_error
    extern current_exception
    call set_key_error
    mov rdi, [rel current_exception]
    mov qword [rel current_exception], 0
    call raise_exception_obj
    ud2
END_FUNC raise_key_error

;; ============================================================================
;; set_key_error(rdi = key Value) -- the same KeyError, RECORDED rather than
;; raised, for a caller that has a C stack it still has to unwind by hand.
;; ============================================================================
global set_key_error
DEF_FUNC set_key_error
    mov rsi, rdi                ; exc_new takes the message as a Value
    lea rdi, [rel exc_KeyError_type]
    xor edx, edx
    call exc_new
    mov rdi, rax
    extern exc_install
    call exc_install
    leave
    ret
END_FUNC set_key_error

;; ============================================================================
;; exc_from_cstr(PyTypeObject *type, const char *msg) -> PyExceptionObject*
;; Creates exception with a C string message (converted to PyStrObject).
;; ============================================================================
DEF_FUNC exc_from_cstr, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx

    mov rbx, rdi            ; save type

    ; Convert C string to PyStrObject (heap — stored in exception struct)
    mov rdi, rsi
    call str_from_cstr_heap
    ; rax = str obj (refcnt=1)

    ; Now create exception: exc_new(type, str, TAG_PTR)
    mov rdi, rbx
    mov rsi, rax
    mov edx, TAG_PTR
    call exc_new
    ; rax = exception obj
    ; exc_new INCREFs the str, so we need to DECREF our copy
    push rax
    mov rdi, [rax + PyExceptionObject.exc_value]
    DECREF_V rdi, rsi
    pop rax

    pop rbx
    leave
    ret
END_FUNC exc_from_cstr

;; ============================================================================
;; exc_dealloc(PyExceptionObject *exc)
;; Free exception and DECREF its fields.
;; ============================================================================
ED_TYPE  equ 8
ED_FRAME equ 24                    ; + 1 push = 32, so rsp is 16-aligned
DEF_FUNC exc_dealloc, ED_FRAME
    push rbx

    mov rbx, rdi

    ; UNTRACK FIRST, which is the first line of CPython's
    ; BaseException_dealloc and was the last thing here.  Everything below
    ; releases a field, and a release runs arbitrary code -- a __del__, a
    ; container teardown, an allocation that trips a collection -- with this
    ; object at refcount 0 and still on a generation list.  The collector
    ; then sees it as garbage, clears and frees it, and gc_dealloc below
    ; untracks a block that is no longer ours: a SIGSEGV in gc_list_remove
    ; with nothing on the stack to connect it to the exception.  It surfaced
    ; when AttributeError started carrying `.obj`, because that is what first
    ; put an arbitrary object in an exception's dict.
    extern gc_untrack
    call gc_untrack

    ; XDECREF exc_value (tag-aware: may be SmallInt)
    mov rdi, [rbx + PyExceptionObject.exc_value]
    XDECREF_V rdi, rsi
.no_value:

    ; XDECREF exc_tb
    mov rdi, [rbx + PyExceptionObject.exc_tb]
    test rdi, rdi
    jz .no_tb
    call obj_decref
.no_tb:

    ; XDECREF exc_context
    mov rdi, [rbx + PyExceptionObject.exc_context]
    test rdi, rdi
    jz .no_context
    call obj_decref
.no_context:

    ; XDECREF exc_cause
    mov rdi, [rbx + PyExceptionObject.exc_cause]
    test rdi, rdi
    jz .no_cause
    call obj_decref
.no_cause:

    ; XDECREF exc_args
    mov rdi, [rbx + PyExceptionObject.exc_args]
    test rdi, rdi
    jz .no_args
    call obj_decref
.no_args:

    ; XDECREF exc_dict
    mov rdi, [rbx + PyExceptionObject.exc_dict]
    test rdi, rdi
    jz .no_dict
    call obj_decref
.no_dict:

    ; Save ob_type before freeing: gc_dealloc reads it, then frees.  A frame
    ; slot rather than a push, so both calls below stay 16-aligned.
    mov rax, [rbx + PyObject.ob_type]
    mov [rbp - ED_TYPE], rax

    ; Free the object (GC-aware)
    mov rdi, rbx
    call gc_dealloc

    ; Release the class AFTER the instance, the order instance_dealloc uses.
    mov rdi, [rbp - ED_TYPE]
    call obj_decref

    pop rbx
    leave
    ret
END_FUNC exc_dealloc

;; ============================================================================
;; exc_getattr(PyExceptionObject *exc, PyStrObject *name) -> PyObject* or NULL
;; Handle attribute access on exception objects: args, __context__, __cause__, etc.
;; ============================================================================
DEF_FUNC exc_getattr
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi            ; exc
    mov r12, rsi            ; name str

    ; Compare attribute name
    lea rdi, [r12 + PyStrObject.data]

    ; Check "args"
    CSTRING rsi, "args"
    call ap_strcmp
    test eax, eax
    jz .get_args

    ; Check "__context__"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "__context__"
    call ap_strcmp
    test eax, eax
    jz .get_context

    ; Check "__cause__"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "__cause__"
    call ap_strcmp
    test eax, eax
    jz .get_cause

    ; Check "__suppress_context__"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "__suppress_context__"
    call ap_strcmp
    test eax, eax
    jz .get_suppress

    ; Check "__traceback__"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "__traceback__"
    call ap_strcmp
    test eax, eax
    jz .get_tb

    ; Check "code" (for SystemExit.code).  Only SystemExit has it; on any
    ; other exception `code` is an ordinary instance attribute.
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "code"
    call ap_strcmp
    test eax, eax
    jnz .not_code
    mov rdi, rbx
    lea rsi, [rel exc_SystemExit_type]
    call exc_isinstance
    test eax, eax
    jnz .get_code
.not_code:

    ; Check "value" (for StopIteration.value)
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "value"
    call ap_strcmp
    test eax, eax
    jz .get_value

    ; UnicodeEncodeError's and UnicodeDecodeError's five, which are their
    ; whole point: an error handler is given the exception and reads the span
    ; it has to replace out of it.  They are not fields either -- args is
    ; (encoding, object, start, end, reason), which is the shape both the
    ; message builder and lib/_codecs already assume -- so reading them back
    ; out keeps one source of truth and needs no five-argument constructor.
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "encoding"
    xor r14d, r14d
    call ap_strcmp
    test eax, eax
    jz .uni_attr
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "object"
    mov r14d, 1
    call ap_strcmp
    test eax, eax
    jz .uni_attr
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "start"
    mov r14d, 2
    call ap_strcmp
    test eax, eax
    jz .uni_attr
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "end"
    mov r14d, 3
    call ap_strcmp
    test eax, eax
    jz .uni_attr
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "reason"
    mov r14d, 4
    call ap_strcmp
    test eax, eax
    jz .uni_attr
    jmp .not_unicode_attr

.uni_attr:
    mov rdi, rbx

    lea rsi, [rel exc_UnicodeError_type]
    call exc_isinstance
    test eax, eax
    jz .not_unicode_attr
    ; An explicit assignment wins, as it does for SyntaxError's.
    mov rdi, [rbx + PyExceptionObject.exc_dict]
    test rdi, rdi
    jz .uni_from_args
    mov rsi, r12
    call dict_get
    V_UNPACK rax, rdx
    test edx, edx
    jnz .found_in_dict
.uni_from_args:
    ; A TRANSLATE error has four arguments, not five: there is no codec, so
    ; args is (object, start, end, reason).  Reading it at the five-argument
    ; offsets made UnicodeTranslateError("ab", 0, 1, "r").object answer 0 and
    ; .end answer "r" -- which is what every error handler reads to find the
    ; span it must replace, so a translate error's handler got nonsense.
    mov rdi, rbx
    lea rsi, [rel exc_UnicodeTranslateError_type]
    call exc_isinstance
    test eax, eax
    jz .uni_have_index
    test r14d, r14d
    jz .return_none             ; no `encoding` on a translate error
    dec r14d
.uni_have_index:
    mov rax, [rbx + PyExceptionObject.exc_args]
    test rax, rax
    jz .return_none
    movsxd rcx, r14d
    cmp [rax + PyTupleObject.ob_size], rcx
    jle .return_none
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rax, [rdx + rcx*8]
    INCREF_V rax, rdx
    V_UNPACK rax, rdx
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.not_unicode_attr:

    ; SyntaxError's seven attributes.  They are not fields: they live in the
    ; args tuple CPython puts them in -- args = (msg, (filename, lineno,
    ; offset, text, end_lineno, end_offset)) -- so reading them back out of it
    ; keeps one source of truth, and an exception built by hand with the same
    ; args answers the same way.  r14d carries which one: 0 is the message and
    ; 1..6 index the location tuple.
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "msg"
    xor r14d, r14d
    call ap_strcmp
    test eax, eax
    jz .syn_attr
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "filename"
    mov r14d, 1
    call ap_strcmp
    test eax, eax
    jz .syn_attr
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "lineno"
    mov r14d, 2
    call ap_strcmp
    test eax, eax
    jz .syn_attr
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "offset"
    mov r14d, 3
    call ap_strcmp
    test eax, eax
    jz .syn_attr
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "text"
    mov r14d, 4
    call ap_strcmp
    test eax, eax
    jz .syn_attr
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "end_lineno"
    mov r14d, 5
    call ap_strcmp
    test eax, eax
    jz .syn_attr
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "end_offset"
    mov r14d, 6
    call ap_strcmp
    test eax, eax
    jz .syn_attr
    jmp .not_syntax_attr

.syn_attr:
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    call exc_isinstance
    test eax, eax
    jz .not_syntax_attr
    ; An explicit `e.lineno = 3` wins, the way .get_code lets one win.
    mov rdi, [rbx + PyExceptionObject.exc_dict]
    test rdi, rdi
    jz .syn_from_args
    mov rsi, r12
    call dict_get
    V_UNPACK rax, rdx
    test edx, edx
    jnz .found_in_dict
.syn_from_args:
    mov rax, [rbx + PyExceptionObject.exc_args]
    test rax, rax
    jz .return_none
    test r14d, r14d
    jnz .syn_loc
    cmp qword [rax + PyTupleObject.ob_size], 1
    jl .return_none
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rax, [rcx]
    jmp .syn_have
.syn_loc:
    ; Anything short of a real tuple in args[1] means the attribute is absent,
    ; which is None -- `SyntaxError('boom')` has a msg and no location.
    cmp qword [rax + PyTupleObject.ob_size], 2
    jl .return_none
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rax, [rcx + 8]
    V_TEST_PTR rax, rcx
    ja .return_none
    test rax, rax
    jz .return_none
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    jne .return_none
    movsxd rcx, r14d
    cmp [rax + PyTupleObject.ob_size], rcx
    jl .return_none
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rax, [rdx + rcx*8 - 8]
.syn_have:
    INCREF_V rax, rdx
    V_UNPACK rax, rdx
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
.not_syntax_attr:

    ; The instance dict comes first: a class attribute used to shadow the
    ; instance attribute of the same name, so `e.x = 2` then `e.x` read the
    ; class default.
    mov rdi, [rbx + PyExceptionObject.exc_dict]
    test rdi, rdi
    jz .eg_type_start
    mov rsi, r12
    call dict_get
    V_UNPACK rax, rdx
    test edx, edx
    jnz .found_in_dict
.eg_type_start:

    ; Then the type's MRO (for user-defined subclass attrs).  Only the exact
    ; type's dict used to be consulted, so a method defined on an exception's
    ; *base* was invisible.
    mov r13, [rbx + PyObject.ob_type]   ; origin
    mov r14, r13                        ; walker
.eg_type_walk:
    test r14, r14
    jz .check_exc_dict
    mov rdi, [r14 + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .eg_type_next
    mov rsi, r12
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value
    test edx, edx
    jnz .found_in_type
.eg_type_next:
    MRO_NEXT r14, r13
    jmp .eg_type_walk

.check_exc_dict:
    ; Check exc_dict for custom instance attributes
    mov rdi, [rbx + PyExceptionObject.exc_dict]
    test rdi, rdi
    jz .not_found
    mov rsi, r12
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value
    test edx, edx
    jnz .found_in_dict

.not_found:
    ; AttributeError's .name and .obj, and ImportError's .name and .path, are
    ; C members in CPython: unset they read as None, not as a miss.  Only the
    ; DEFAULT is answered here -- a raise site that fills one puts it in
    ; exc_dict, which the walk above has already consulted.
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "name"
    call ap_strcmp
    test eax, eax
    jz .eg_name_default
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "obj"
    call ap_strcmp
    test eax, eax
    jz .eg_attr_default
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "path"
    call ap_strcmp
    test eax, eax
    jz .eg_import_default
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "msg"
    call ap_strcmp
    test eax, eax
    jz .eg_import_msg
    jmp .eg_really_not_found

.eg_import_msg:
    ; ImportError.msg, a C member in CPython: args[0] when there is exactly
    ; one argument, else None.  An assigned msg is in exc_dict, found above.
    ; numpy's import-time fallback reads it off the ImportError it catches.
    mov rdi, rbx
    lea rsi, [rel exc_ImportError_type]
    call exc_isinstance
    test eax, eax
    jz .eg_really_not_found
    mov rax, [rbx + PyExceptionObject.exc_args]
    test rax, rax
    jz .return_none
    cmp qword [rax + PyTupleObject.ob_size], 1
    jne .return_none
    mov rax, [rax + PyTupleObject.ob_item]
    mov rax, [rax]
    INCREF_V rax, rcx
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.eg_name_default:
    ; `name` belongs to both, so ask about AttributeError and fall through to
    ; the ImportError question.
    mov rdi, rbx
    lea rsi, [rel exc_AttributeError_type]
    call exc_isinstance
    test eax, eax
    jnz .return_none
.eg_import_default:
    mov rdi, rbx
    lea rsi, [rel exc_ImportError_type]
    call exc_isinstance
    test eax, eax
    jnz .return_none
    jmp .eg_really_not_found

.eg_attr_default:
    mov rdi, rbx
    lea rsi, [rel exc_AttributeError_type]
    call exc_isinstance
    test eax, eax
    jnz .return_none

.eg_really_not_found:
    RET_NULL
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.found_in_dict:
    INCREF_VAL rax, rdx
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.found_in_type:
    ; A plain function found on the class is a method and has to be bound;
    ; returning it raw made exc.method() call it with no self.  Descriptors
    ; are returned as they are, for LOAD_ATTR to unwrap.
    cmp edx, TAG_PTR
    jne .fit_raw
    mov rcx, [rax + PyObject.ob_type]
    extern func_type
    lea rdx, [rel func_type]
    cmp rcx, rdx
    je .fit_bind
    extern builtin_func_type
    lea rdx, [rel builtin_func_type]
    cmp rcx, rdx
    je .fit_bind
    mov edx, TAG_PTR
.fit_raw:
    INCREF_VAL rax, rdx     ; tag-aware INCREF (rdx = tag from dict_get)
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.fit_bind:
    mov rdi, rax
    mov rsi, rbx
    extern method_new
    call method_new
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.get_args:
    mov rax, [rbx + PyExceptionObject.exc_args]
    test rax, rax
    jz .return_empty_tuple
    INCREF rax
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.return_empty_tuple:
    xor edi, edi
    call tuple_new
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.get_code:
    ; An explicit `e.code = x` wins; otherwise code is args[0] when there is
    ; exactly one argument, the whole args tuple when there are more, and
    ; None when there are none.
    mov rdi, [rbx + PyExceptionObject.exc_dict]
    test rdi, rdi
    jz .code_from_args
    mov rsi, r12
    call dict_get
    V_UNPACK rax, rdx
    test edx, edx
    jnz .found_in_dict
.code_from_args:
    mov rax, [rbx + PyExceptionObject.exc_args]
    test rax, rax
    jz .return_none
    mov rcx, [rax + PyTupleObject.ob_size]
    test rcx, rcx
    jz .return_none
    cmp rcx, 1
    jne .code_tuple
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rax, [rcx]
    INCREF_V rax, rdx
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.code_tuple:
    INCREF rax
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.get_context:
    mov rax, [rbx + PyExceptionObject.exc_context]
    test rax, rax
    jz .return_none
    INCREF rax
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.get_suppress:
    mov rax, [rbx + PyExceptionObject.exc_suppress]
    test rax, rax
    jz .suppress_false
    extern bool_true
    lea rax, [rel bool_true]
    jmp .suppress_ret
.suppress_false:
    extern bool_false
    lea rax, [rel bool_false]
.suppress_ret:
    INCREF rax
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.get_cause:
    mov rax, [rbx + PyExceptionObject.exc_cause]
    test rax, rax
    jz .return_none
    INCREF rax
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.get_tb:
    mov rax, [rbx + PyExceptionObject.exc_tb]
    test rax, rax
    jz .return_none
    INCREF rax
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.get_value:
    ; Return exc_args[0] if args is non-empty, else None
    mov rax, [rbx + PyExceptionObject.exc_args]
    test rax, rax
    jz .return_none
    ; Check if tuple has at least 1 element
    cmp qword [rax + PyTupleObject.ob_size], 0
    je .return_none
    ; Return args[0]
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rax, [rcx]
    INCREF_V rax, rdx
    V_UNPACK rax, rdx
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.return_none:
    extern none_singleton
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC exc_getattr

;; ============================================================================
;; exc_setattr(PyExceptionObject *exc, PyStrObject *name, PyObject *value, int value_tag)
;; Store a custom attribute on an exception object using exc_dict.
;; rdi = exc, rsi = name, rdx = value, ecx = value_tag
;; ============================================================================
ESA_VAL   equ 8
ESA_TAG   equ 16
ESA_ISTB  equ 24            ; the field takes a traceback, not an exception
ESA_FRAME equ 32            ; + 2 pushes = 48
DEF_FUNC exc_setattr, ESA_FRAME
    push rbx
    push r12
    mov rbx, rdi            ; exc
    mov r12, rsi            ; the name
    mov [rbp - ESA_VAL], rdx
    mov [rbp - ESA_TAG], rcx

    ; A NULL value is a DELETE: op_delete_attr calls tp_setattr(obj, name,
    ; NULL).  Writing that straight into the dict left an entry whose key was
    ; set and whose value was 0, which every later read of that dict trips
    ; over -- `del e.attr` then `e.__dict__` reported "object has no repr".
    cmp qword [rbp - ESA_VAL], 0
    je .esa_delete

    ; Four names are fields of the object, not entries in its dict, and
    ; exc_getattr reads them from the fields.  Writing them to the dict left
    ; the assignment invisible: `e.__cause__ = other` read back as None, and
    ; the report the traceback printer produced had no cause chain in it.
    ; `raise x from y` goes through the fields directly, which is why only the
    ; hand-written form was affected.
    ; args is the first name exc_getattr compares, and it answers out of the
    ; exc_args FIELD without ever reading the dict -- so an assignment that
    ; fell through to the generic dict_set below was silently dropped, and
    ; e.args went on reading the old tuple.  That is the whole of CPython's
    ; test_configparser, whose exception classes end __init__ with
    ; `self.args = (section, source, lineno)`; func_setattr's comment records
    ; the identical failure for f.__name__.
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "args"
    call ap_strcmp
    test eax, eax
    jz .esa_args
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "__cause__"
    call ap_strcmp
    test eax, eax
    jz .esa_cause
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "__context__"
    call ap_strcmp
    test eax, eax
    jz .esa_context
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "__traceback__"
    call ap_strcmp
    test eax, eax
    jz .esa_tb
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "__suppress_context__"
    call ap_strcmp
    test eax, eax
    jz .esa_suppress
    ; And `e.__dict__ = {...}` REPLACES the dict rather than putting an entry
    ; called "__dict__" inside it, which is what exc_getattr answers with and
    ; what every other object does.
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "__dict__"
    call ap_strcmp
    test eax, eax
    jz .esa_dict
    ; ap_strcmp clobbers the argument registers, so the value and its tag come
    ; back from the frame.
    mov rsi, r12
    mov rdx, [rbp - ESA_VAL]
    mov rcx, [rbp - ESA_TAG]

    ; Create exc_dict if needed
    mov rax, [rbx + PyExceptionObject.exc_dict]
    test rax, rax
    jnz .esa_have_dict
    push rsi
    push rdx
    push rcx
    call dict_new
    mov [rbx + PyExceptionObject.exc_dict], rax
    pop rcx
    pop rdx
    pop rsi
.esa_have_dict:
    mov rdi, [rbx + PyExceptionObject.exc_dict]
    ; rsi = name and rdx = value are both already Values
    call dict_set

    xor eax, eax            ; return 0 (success)
    xor edx, edx

    pop r12
    pop rbx
    leave
    ret

.esa_dict:
    extern dict_type
    ; Only a dict, as CPython's __dict__ setter insists.
    mov rdx, [rbp - ESA_VAL]
    V_TEST_PTR rdx, rax
    ja .esa_dict_bad
    test rdx, rdx
    jz .esa_dict_bad
    mov rax, [rdx + PyObject.ob_type]
    REQUIRE_DICT_TYPE rax, rcx, .esa_dict_bad
    INCREF rdx
    mov rdi, [rbx + PyExceptionObject.exc_dict]
    mov [rbx + PyExceptionObject.exc_dict], rdx
    test rdi, rdi
    jz .esa_dict_done
    call obj_decref
.esa_dict_done:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret
.esa_dict_bad:
    pop r12
    pop rbx
    RAISE exc_TypeError_type, "__dict__ must be set to a dictionary"

.esa_delete:
    ; `del e.args` is refused rather than reported as a missing attribute:
    ; the field always exists, and CPython names it.
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "args"
    call ap_strcmp
    test eax, eax
    jnz .esa_delete_dict
    RAISE exc_TypeError_type, "args may not be deleted"
.esa_delete_dict:
    mov rax, [rbx + PyExceptionObject.exc_dict]
    test rax, rax
    jz .esa_del_missing
    mov rdi, rax
    mov rsi, r12
    extern dict_del_opt
    call dict_del_opt
    test eax, eax
    jnz .esa_del_missing
    xor eax, eax            ; return 0 (success)
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret
.esa_del_missing:
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    extern raise_no_attribute
    pop r12
    pop rbx
    leave
    jmp raise_no_attribute      ; does not return

.esa_args:
    ; CPython's BaseException_set_args is PySequence_Tuple(val) then
    ; Py_XSETREF, and tuple_type_call IS PySequence_Tuple: an exact tuple is
    ; handed straight back (so `e.args = t; e.args is t` holds, as it does
    ; there), anything else iterable is drained into a new one, and a
    ; non-iterable raises "'int' object is not iterable" from get_iterator --
    ; which is the wording CPython's own arrives at by the same route.
    extern tuple_type_call
    lea rdi, [rel tuple_type]
    lea rsi, [rbp - ESA_VAL]        ; a one-Value argument array
    mov edx, 1
    call tuple_type_call
    test rax, rax
    jz .esa_args_out                ; an iterable that raised part way; the
                                    ; exception stands and op_store_attr's
                                    ; DUNDER_RAISED finds it
    mov rdi, [rbx + PyExceptionObject.exc_args]
    mov [rbx + PyExceptionObject.exc_args], rax     ; the new tuple is owned
    test rdi, rdi
    jz .esa_args_out
    call obj_decref
.esa_args_out:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret

    ; Each field holds a strong reference, and None means "none of it": the
    ; report walks a NULL field, not a None one.
.esa_cause:
    mov esi, PyExceptionObject.exc_cause
    ; `raise x from y` also sets __suppress_context__, and so does assigning
    ; to __cause__ -- CPython's cause setter does both.
    mov qword [rbx + PyExceptionObject.exc_suppress], 1
    jmp .esa_field
.esa_context:
    mov esi, PyExceptionObject.exc_context
    jmp .esa_field
.esa_tb:
    mov esi, PyExceptionObject.exc_tb
    mov qword [rbp - ESA_ISTB], 1
    jmp .esa_field_typed
.esa_field:
    mov qword [rbp - ESA_ISTB], 0
.esa_field_typed:
    mov rdx, [rbp - ESA_VAL]
    lea rcx, [rel none_singleton]
    cmp rdx, rcx
    jne .esa_field_check
    xor edx, edx            ; None clears it
    jmp .esa_field_store
.esa_field_check:
    ; All three take None or one particular kind of object, and nothing else.
    ; Only None was being tested for, so the INCREF below dereferenced an
    ; int -- `e.__cause__ = 5` was a segfault where CPython raises TypeError.
    mov rdi, rdx
    V_TEST_PTR rdi, rax
    ja .esa_field_bad
    test rdi, rdi
    jz .esa_field_bad
    mov rax, [rdi + PyObject.ob_type]
    cmp qword [rbp - ESA_ISTB], 0
    jne .esa_field_tb_check
    push rsi
    push rdx
    mov rdi, rax
    lea rsi, [rel exc_BaseException_type]
    extern type_is_subtype
    call type_is_subtype
    pop rdx
    pop rsi
    test eax, eax
    jz .esa_field_bad
    jmp .esa_field_store
.esa_field_tb_check:
    lea rcx, [rel traceback_type]
    cmp rax, rcx
    jne .esa_field_bad
.esa_field_store:
    mov r12, rdx
    test r12, r12
    jz .esa_field_swap
    mov rdi, r12
    push rsi
    call obj_incref
    pop rsi
.esa_field_swap:
    mov rdi, [rbx + rsi]
    mov [rbx + rsi], r12
    test rdi, rdi
    jz .esa_field_done
    call obj_decref
.esa_field_done:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret

.esa_field_bad:
    cmp qword [rbp - ESA_ISTB], 0
    jne .esa_field_bad_tb
    cmp esi, PyExceptionObject.exc_cause
    jne .esa_field_bad_context
    RAISE exc_TypeError_type, \
        "exception cause must be None or derive from BaseException"
.esa_field_bad_context:
    RAISE exc_TypeError_type, \
        "exception context must be None or derive from BaseException"
.esa_field_bad_tb:
    RAISE exc_TypeError_type, "__traceback__ must be a traceback or None"

.esa_suppress:
    ; CPython's setter takes a bool and nothing else, down to the wording.
    mov rdi, [rbp - ESA_VAL]
    lea rcx, [rel bool_true]
    cmp rdi, rcx
    je .esa_suppress_true
    lea rcx, [rel bool_false]
    cmp rdi, rcx
    jne .esa_suppress_bad
    xor eax, eax
    jmp .esa_suppress_store
.esa_suppress_true:
    mov eax, 1
.esa_suppress_store:
    mov [rbx + PyExceptionObject.exc_suppress], rax
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret
.esa_suppress_bad:
    RAISE exc_TypeError_type, "attribute value type must be bool"
END_FUNC exc_setattr

;; ============================================================================
;; exc_isinstance(PyExceptionObject *exc, PyTypeObject *type) -> int (0/1)
;; Check if exception is an instance of type, walking tp_base chain.
;; If type is a tuple, checks each element.
;; ============================================================================
extern tuple_type
DEF_FUNC_BARE exc_isinstance
    ; rdi = exc, rsi = target type (or tuple of types)
    ; The target is an arbitrary expression -- `except 5:` is legal syntax --
    ; so classify it before dereferencing.  An immediate's payload is not an
    ; address; this walked ob_type off it.  Putting the check here covers all
    ; five callers and the recursion through nested tuples below.
    V_TEST_PTR rsi, rax
    ja .not_a_class
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .tuple_match

    ; A class is anything whose type is one of the three metatypes: the
    ; builtin exception types carry exc_metatype, a `class E(Exception)`
    ; heaptype carries user_type_metatype, and everything else type_type.
    lea rcx, [rel exc_metatype]
    cmp rax, rcx
    je .is_class
    lea rcx, [rel type_type]
    cmp rax, rcx
    je .is_class
    extern user_type_metatype
    lea rcx, [rel user_type_metatype]
    cmp rax, rcx
    jne .not_a_class

.is_class:
    ; Single type: the exception's MRO, so a class with several bases is
    ; caught by an `except` naming any of them.
    mov rdi, [rdi + PyExceptionObject.ob_type]
    jmp type_is_subtype
.not_a_class:
    RAISE exc_TypeError_type, "catching classes that do not inherit from BaseException is not allowed"
.not_match:
    xor eax, eax
    ret

.tuple_match:
    ; rsi = tuple of types. Check each element.
    push rbx
    push r12
    push r13
    mov rbx, rdi               ; save exc
    mov r12, [rsi + PyTupleObject.ob_item]       ; type payloads
    mov r13, [rsi + PyTupleObject.ob_size]        ; count
    xor ecx, ecx
.tuple_loop:
    cmp rcx, r13
    jge .tuple_no_match
    push rcx
    mov rdi, rbx               ; exc
    mov rsi, [r12 + rcx*8]    ; type element
    ; Recursive call for nested tuples
    call exc_isinstance
    pop rcx
    test eax, eax
    jnz .tuple_found
    inc rcx
    jmp .tuple_loop
.tuple_found:
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    ret
.tuple_no_match:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret
END_FUNC exc_isinstance

;; ============================================================================
;; type_is_exc_subclass(PyTypeObject *type) -> int (0/1)
;; Walk tp_base chain checking for a type with tp_dealloc == exc_dealloc.
;; Detects user-defined exception classes (e.g., class MyError(Exception): pass)
;; ============================================================================
DEF_FUNC_BARE type_is_exc_subclass
    lea rdx, [rel exc_dealloc]
    lea rcx, [rel eg_dealloc]
    mov r10, rdi                    ; origin of the walk
.tie_walk:
    test rdi, rdi
    jz .tie_no
    mov rax, [rdi + PyTypeObject.tp_dealloc]
    cmp rax, rdx
    je .tie_yes
    cmp rax, rcx
    je .tie_yes
    push r10
    mov rsi, rdi
    mov rdi, r10
    extern type_mro_next
    call type_mro_next
    pop r10
    mov rdi, rax
    jmp .tie_walk
.tie_yes:
    mov eax, 1
    ret
.tie_no:
    xor eax, eax
    ret
END_FUNC type_is_exc_subclass


; exc_type_call(PyTypeObject *type, PyObject **args, int64_t nargs) -> rax = Value
; tp_call for exception metatype. Creates an exception instance.
; rdi = exception type (the class being called, e.g. ValueError)
; rsi = args array
; rdx = nargs
ETC_EXC   equ 8
ETC_ARGS  equ 16
ETC_NARGS equ 24
ETC_KWFAM equ 32            ; 0 none, 1 AttributeError, 2 ImportError
ETC_KW1   equ 40            ; the 'name' keyword's value, or 0
ETC_KW2   equ 48            ; 'obj' for AttributeError, 'path' for ImportError
ETC_FRAME equ 48            ; + 2 pushes = 64, 16-byte aligned
;; ============================================================================
;; exc_method_init(args, nargs) -> None -- BaseException.__init__
;;
;; `class E(Exception)` whose __init__ calls super().__init__(msg) has to end
;; up with args == (msg,), which is what str(e) and repr(e) are built from.
;; BaseException had no __init__ of its own, so the super() call walked past
;; every exception type in the MRO and reached object.__init__, which takes
;; its arguments and ignores them: re.error's message came out as the whole
;; three-item constructor tuple, and so did every other exception that
;; composes its own message.
;; ============================================================================
EMI_SELF  equ 8
EMI_TUP   equ 16
EMI_FRAME equ 40            ; + 1 push = 48, 16-aligned

DEF_FUNC exc_method_init, EMI_FRAME
    push rbx
    test rsi, rsi
    jz .emi_none
    mov rax, [rdi]
    V_TEST_PTR rax, rcx
    ja .emi_none
    test rax, rax
    jz .emi_none
    mov [rbp - EMI_SELF], rax

    ; args = the tuple of everything after self
    lea rbx, [rdi + 8]
    dec rsi
    mov [rbp - EMI_TUP], rsi
    mov rdi, rsi
    call tuple_new
    test rax, rax
    jz .emi_none
    mov rcx, rax
    mov r8, [rax + PyTupleObject.ob_item]
    xor edx, edx
.emi_copy:
    cmp rdx, [rbp - EMI_TUP]
    jge .emi_copied
    mov r9, [rbx + rdx*8]
    INCREF_V r9, r10
    mov [r8 + rdx*8], r9
    inc rdx
    jmp .emi_copy
.emi_copied:
    mov rdi, [rbp - EMI_SELF]
    mov rsi, [rdi + PyExceptionObject.exc_args]
    mov [rdi + PyExceptionObject.exc_args], rcx
    test rsi, rsi
    jz .emi_none
    mov rdi, rsi
    call obj_decref

.emi_none:
    LOAD_NONE rax
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
END_FUNC exc_method_init

;; ============================================================================
;; exc_method_with_traceback(rdi = args, rsi = nargs) -> rax = Value, self
;;
;; `exc.with_traceback(tb)` sets __traceback__ and hands the exception back, so
;; that `raise e.with_traceback(tb)` is one expression.  unittest's
;; assertRaises does `self.exception = exc_value.with_traceback(None)` in its
;; __exit__, so without this every assertRaises raised AttributeError from
;; inside a __exit__ that was already handling an exception.
;;
;; args[0] is the exception: builtin_func_call has already checked the receiver
;; against the owner type_stamp_methods stamped on this dict.
;; ============================================================================
EWT_SELF  equ 8
EWT_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC exc_method_with_traceback, EWT_FRAME
    cmp rsi, 2
    jne .ewt_arity
    mov rax, [rdi]
    mov [rbp - EWT_SELF], rax
    mov rdx, [rdi + 8]              ; the traceback, as a Value

    lea rcx, [rel none_singleton]
    cmp rdx, rcx
    je .ewt_clear
    ; Only a traceback or None.  An immediate is neither, and reading ob_type
    ; off one is a dereference of the number.
    V_TEST_PTR rdx, rcx
    ja .ewt_bad
    mov rcx, [rdx + PyObject.ob_type]
    lea r8, [rel traceback_type]
    cmp rcx, r8
    jne .ewt_bad
    INCREF rdx
    jmp .ewt_store
.ewt_clear:
    xor edx, edx                    ; None clears it, as the setter does
.ewt_store:
    mov rax, [rbp - EWT_SELF]
    mov rcx, [rax + PyExceptionObject.exc_tb]
    mov [rax + PyExceptionObject.exc_tb], rdx
    test rcx, rcx
    jz .ewt_ret
    push rax
    push rax                        ; pad: the call below needs an even list
    mov rdi, rcx
    call obj_decref
    pop rax
    pop rax
.ewt_ret:
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx                 ; builtins return one Value
    ret
.ewt_bad:
    RAISE exc_TypeError_type, "__traceback__ must be a traceback or None"
.ewt_arity:
    dec rsi                         ; the count CPython reports excludes self
    CSTRING rdi, "BaseException.with_traceback() takes exactly one argument ("
    CSTRING rdx, " given)"
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC exc_method_with_traceback

;; ============================================================================
;; exc_method_new(args, nargs) -> a bare exception of args[0]'s type
;;
;; BaseException.__new__.  CPython has one and this tree did not, so
;; `ValueError.__new__(ValueError)` resolved up the MRO to object.__new__ --
;; which is a different function with a different rule.  It happened to work
;; while object.__new__ accepted anything; once it started refusing types
;; whose allocation it does not own, every `cls.__new__(cls)` on an exception
;; became a TypeError.  copyreg and unittest both write that idiom.
;;
;; The remaining arguments become `.args`, as CPython's does -- `__init__` is
;; what interprets them, and `__new__` only has to record them.
;; ============================================================================
EMN_TYPE  equ 8
EMN_EXC   equ 16
EMN_ARGS  equ 24
EMN_NARGS equ 32
EMN_TUP   equ 40
EMN_I     equ 48
EMN_FRAME equ 72            ; + 1 push = 80, 16-aligned
DEF_FUNC exc_method_new, EMN_FRAME
    push rbx
    test rsi, rsi
    jz .emn_no_type
    mov [rbp - EMN_NARGS], rsi
    mov [rbp - EMN_ARGS], rdi
    mov rbx, [rdi]              ; args[0] = the class
    ; ...if it IS a class.  Nothing checked, so `ValueError("x").__new__(V)`
    ; -- which reaches here with the INSTANCE in args[0], because the wrapper
    ; below binds -- built an exception whose exc_type was an instance and
    ; aborted with "double free or corruption" when it was freed.
    V_TEST_PTR rbx, rax
    ja .emn_not_a_type
    mov rax, [rbx + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .emn_not_a_type
    mov rdi, rbx
    lea rsi, [rel exc_BaseException_type]
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jz .emn_not_an_exc

    ; A group is BaseExceptionGroup's to build, not this one's: eg_new fills
    ; eg_exceptions and nothing here would.  `super().__new__(cls, msg, excs)`
    ; inside an ExceptionGroup subclass lands here -- BaseExceptionGroup
    ; publishes no __new__ of its own, so the MRO walk runs past it to this
    ; one -- and used to get back a plain exception whose eg_exceptions was
    ; never written, which eg_split then read as a tuple.
    mov rdi, rbx
    extern exc_BaseExceptionGroup_type
    lea rsi, [rel exc_BaseExceptionGroup_type]
    call type_is_subtype
    test eax, eax
    jnz .emn_group

    mov [rbp - EMN_TYPE], rbx

    ; A bare instance: no message, so exc_new builds an empty args tuple.
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    call exc_new
    test rax, rax
    jz .emn_fail
    mov [rbp - EMN_EXC], rax

    ; Anything after the class becomes .args.
    mov rcx, [rbp - EMN_NARGS]
    dec rcx
    jz .emn_done
    mov rdi, rcx
    call tuple_new
    test rax, rax
    jz .emn_fail
    mov [rbp - EMN_TUP], rax
    mov qword [rbp - EMN_I], 0
.emn_copy:
    mov rdx, [rbp - EMN_I]
    mov rcx, [rbp - EMN_NARGS]
    dec rcx
    cmp rdx, rcx
    jge .emn_install
    mov rsi, [rbp - EMN_ARGS]
    lea rcx, [rdx + 1]          ; skip the class
    mov rdi, [rsi + rcx * 8]
    INCREF_V rdi, r8
    mov rax, [rbp - EMN_TUP]
    mov r9, [rax + PyTupleObject.ob_item]
    mov [r9 + rdx * 8], rdi
    inc qword [rbp - EMN_I]
    jmp .emn_copy
.emn_install:
    mov rdi, [rbp - EMN_EXC]
    mov rax, [rdi + PyExceptionObject.exc_args]
    test rax, rax
    jz .emn_set
    mov rdi, rax
    call obj_decref
.emn_set:
    mov rdi, [rbp - EMN_EXC]
    mov rax, [rbp - EMN_TUP]
    mov [rdi + PyExceptionObject.exc_args], rax
.emn_done:
    mov rax, [rbp - EMN_EXC]
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.emn_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.emn_no_type:
    pop rbx
    RAISE exc_TypeError_type, \
          "BaseException.__new__(): not enough arguments"
.emn_not_a_type:
    mov rsi, rbx
    pop rbx
    CSTRING rdi, `BaseException.__new__(X): X is not a type object (\x01)`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
.emn_group:
    ; Hand the whole call on, minus the class, which eg_type_call takes as its
    ; first argument in the tp_new shape rather than in the args array.
    mov rdi, rbx
    mov rsi, [rbp - EMN_ARGS]
    add rsi, 8
    mov rdx, [rbp - EMN_NARGS]
    dec rdx
    pop rbx
    leave
    extern eg_type_call
    jmp eg_type_call

.emn_not_an_exc:
    ; raise_type_error_with_TYPENAME: the argument here IS a class, so the
    ; name wanted is its own and not its type's, which is always "type".
    mov rsi, rbx
    pop rbx
    CSTRING rdi, \
        `BaseException.__new__(\x01): \x01 is not a subtype of BaseException`
    extern raise_type_error_with_typename
    jmp raise_type_error_with_typename
END_FUNC exc_method_new

;; ============================================================================
;; exc_method_add_note(args, nargs) -> Value: None
;;
;; PEP 678.  It needs no field on the exception and CPython's does not have
;; one either: __notes__ is an ordinary instance attribute, created on the
;; first call and appended to afterwards.  That is why a program can replace
;; it, delete it, and see it in vars(e) -- all of which CPython's does too,
;; and all of which a field would have taken away.
;;
;; The lookup goes straight to the instance dict rather than through
;; exc_getattr.  A __notes__ that a CLASS happens to define is not this
;; exception's, and a getattr walk could run Python on the way -- neither of
;; which belongs on the path a traceback printer also takes.
;; ============================================================================
EAN_SELF  equ 8
EAN_NOTE  equ 16
EAN_LIST  equ 24
EAN_NAME  equ 32
EAN_FRAME equ 48            ; + 0 pushes = 48, 16-aligned

extern list_new
extern list_append
extern list_type
extern type_is_subtype

DEF_FUNC exc_method_add_note, EAN_FRAME
    cmp rsi, 2
    jne .ean_arity
    mov rax, [rdi]
    mov [rbp - EAN_SELF], rax
    mov rax, [rdi + 8]
    mov [rbp - EAN_NOTE], rax
    mov qword [rbp - EAN_NAME], 0

    ; A str or a subclass of one, which is what PyUnicode_Check takes.
    V_TEST_PTR rax, rcx
    ja .ean_not_str
    test rax, rax
    jz .ean_not_str
    mov rdi, [rax + PyObject.ob_type]
    lea rsi, [rel str_type]
    call type_is_subtype
    test eax, eax
    jz .ean_not_str

    CSTRING rdi, "__notes__"
    call str_from_cstr_heap
    test rax, rax
    jz .ean_out
    mov [rbp - EAN_NAME], rax

    mov rdi, [rbp - EAN_SELF]
    mov rdi, [rdi + PyExceptionObject.exc_dict]
    test rdi, rdi
    jz .ean_make
    mov rsi, [rbp - EAN_NAME]
    call dict_get
    test rax, rax
    jz .ean_make

    ; Present, so it has to be a list -- CPython refuses anything else rather
    ; than replacing it, because a program that put something there meant it.
    ; A SUBCLASS of list is one: the check is PyList_Check, and PyList_Append
    ; goes to the underlying list rather than to an overridden append, which
    ; is what list_append does too.
    V_TEST_PTR rax, rcx
    ja .ean_not_list
    mov [rbp - EAN_LIST], rax           ; borrowed: the dict owns it
    mov rdi, [rax + PyObject.ob_type]
    lea rsi, [rel list_type]
    call type_is_subtype
    test eax, eax
    jz .ean_not_list
    jmp .ean_append

.ean_make:
    xor edi, edi
    call list_new
    test rax, rax
    jz .ean_out
    mov [rbp - EAN_LIST], rax
    mov rdi, [rbp - EAN_SELF]
    mov rsi, [rbp - EAN_NAME]
    mov rdx, rax
    xor ecx, ecx
    call exc_setattr                    ; creates exc_dict when there is none
    ; The dict holds it now.  Dropping the constructor's reference leaves one
    ; owner, so the list a program reads back is the one appended to here.
    mov rdi, [rbp - EAN_LIST]
    call obj_decref

.ean_append:
    mov rdi, [rbp - EAN_LIST]
    mov rsi, [rbp - EAN_NOTE]
    call list_append

.ean_out:
    mov rdi, [rbp - EAN_NAME]
    test rdi, rdi
    jz .ean_none
    call obj_decref
.ean_none:
    RET_NONE
    leave
    ret

.ean_not_list:
    mov rdi, [rbp - EAN_NAME]
    call obj_decref
    RAISE exc_TypeError_type, "Cannot add note: __notes__ is not a list"

.ean_not_str:
    mov rsi, [rbp - EAN_NOTE]
    CSTRING rdi, `note must be a str, not '\x01'`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.ean_arity:
    dec rsi                             ; the count CPython reports excludes self
    CSTRING rdi, "BaseException.add_note() takes exactly one argument ("
    CSTRING rdx, " given)"
    jmp raise_type_error_counted
END_FUNC exc_method_add_note

;; ============================================================================
;; exc_install_methods() -- give BaseException a tp_dict with __init__ in it
;;
;; One dict on the root of the exception hierarchy is enough: every other
;; exception type reaches it through the MRO, which is what a super() call
;; walks.
;; ============================================================================
EIM_KEY   equ 8
EIM_FN    equ 16
EIM_FRAME equ 40            ; + 1 push = 48, 16-aligned

;; EXC_ADD_METHOD impl, "name" -- one entry in BaseException's tp_dict.
;; rbx holds the dict.  This was open-coded for the single method that used to
;; be here; a second one is what turned fifteen lines into a macro.
;; EXC_ADD_STATIC impl, "name" -- the same, wrapped in a staticmethod so that
;; reading it off an INSTANCE does not bind the instance as its first argument.
%macro EXC_ADD_STATIC 2
    CSTRING rdi, %2
    call str_from_cstr_heap
    mov [rbp - EIM_KEY], rax
    lea rdi, [rel %1]
    CSTRING rsi, %2
    call builtin_func_new
    mov [rbp - EIM_FN], rax
    sub rsp, 16
    mov [rsp], rax
    ; The class to build, which staticmethod_construct no longer ignores.
    extern staticmethod_type
    lea rdi, [rel staticmethod_type]
    mov rsi, rsp
    mov edx, 1
    extern staticmethod_construct
    call staticmethod_construct
    add rsp, 16
    push rax
    mov rdi, [rbp - EIM_FN]
    call obj_decref             ; the staticmethod holds it now
    pop rax
    mov [rbp - EIM_FN], rax
    mov rdi, rbx
    mov rsi, [rbp - EIM_KEY]
    mov rdx, rax
    call dict_set
    mov rdi, [rbp - EIM_KEY]
    call obj_decref
    mov rdi, [rbp - EIM_FN]
    call obj_decref
%endmacro

%macro EXC_ADD_METHOD 2
    CSTRING rdi, %2
    call str_from_cstr_heap
    mov [rbp - EIM_KEY], rax
    lea rdi, [rel %1]
    CSTRING rsi, %2
    call builtin_func_new
    mov [rbp - EIM_FN], rax
    mov rdi, rbx
    mov rsi, [rbp - EIM_KEY]
    mov rdx, rax
    call dict_set
    mov rdi, [rbp - EIM_KEY]
    call obj_decref
    mov rdi, [rbp - EIM_FN]
    call obj_decref
%endmacro

;; ============================================================================
;; BaseException.__reduce__(self) -> (type(self), self.args)
;;   or (type(self), self.args, self.__dict__) when the dict is not empty
;;
;; One body serves every exception type: only exc_BaseException_type carries a
;; tp_dict and all ~100 others inherit along tp_base, which is how CPython
;; arranges it too.
;;
;; Without it, copy.deepcopy(ValueError('x')) was ValueError() and a pickle
;; round trip lost .args -- lib/_reduce.py falls through to _reduce_newobj,
;; which names the class and stops.  The args tuple is exactly what the
;; constructor takes back, so this is the whole reduction.
;;
;; OSError does NOT get its own here, and the difference is recorded in
;; bugs.md beside its cause: its errno, strerror, filename and filename2 live
;; in the instance dict rather than in fields, so they come back as a STATE
;; where CPython, which keeps them as C members, answers a two-tuple and
;; re-packs the filename into the args instead.  Every value survives the
;; round trip either way; the tuple's shape differs.
;; ============================================================================
ERD_SELF  equ 8
ERD_ARGS  equ 16
ERD_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL exc_method_reduce, ERD_FRAME
    mov rdi, [rdi]                      ; args[0] = self, always a pointer
    mov [rbp - ERD_SELF], rdi

    ; .args, which is always a real tuple once the constructor has run -- but
    ; a subclass that never calls it can leave the field NULL, and an empty
    ; tuple is the honest answer there rather than a NULL in a reduction.
    mov rax, [rdi + PyExceptionObject.exc_args]
    test rax, rax
    jnz .erd_have_args
    xor edi, edi
    extern tuple_new
    call tuple_new
    test rax, rax
    jz .erd_failed
    jmp .erd_args_ready
.erd_have_args:
    mov rdi, rax
    call obj_incref
    mov rax, [rbp - ERD_SELF]
    mov rax, [rax + PyExceptionObject.exc_args]
.erd_args_ready:
    mov [rbp - ERD_ARGS], rax           ; owned; ir_reduce_tuple takes it

    ; A non-empty instance dict becomes the third element, which is what
    ; carries an attribute a program set on the exception itself.
    mov rcx, [rbp - ERD_SELF]
    mov rcx, [rcx + PyExceptionObject.exc_dict]
    test rcx, rcx
    jz .erd_no_state
    cmp qword [rcx + PyDictObject.ob_size], 0
    je .erd_no_state
    mov rdx, rcx
    mov ecx, 1
    jmp .erd_build
.erd_no_state:
    xor edx, edx
    xor ecx, ecx
.erd_build:
    mov rsi, [rbp - ERD_ARGS]
    mov rdi, [rbp - ERD_SELF]
    mov rdi, [rdi + PyObject.ob_type]   ; type(self), borrowed
    extern ir_reduce_tuple
    call ir_reduce_tuple
    test rax, rax
    jz .erd_failed
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx                     ; builtins return one Value
    ret

.erd_failed:
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC exc_method_reduce

global exc_install_methods
DEF_FUNC exc_install_methods, EIM_FRAME
    push rbx
    call dict_new
    test rax, rax
    jz .eim_out
    mov rbx, rax
    mov [rel exc_BaseException_type + PyTypeObject.tp_dict], rbx

    extern builtin_func_new
    EXC_ADD_METHOD exc_method_init, "__init__"
    EXC_ADD_METHOD exc_method_with_traceback, "with_traceback"
    EXC_ADD_METHOD exc_method_add_note, "add_note"
    EXC_ADD_METHOD exc_method_reduce, "__reduce__"
    ; Stamp the owner on it, which is what makes builtin_func_call check the
    ; receiver.  Without it `BaseException.__init__([], 'a')` wrote a tuple
    ; into a list's 57th byte -- exc_args' offset -- and released whatever
    ; word was there.
    lea rdi, [rel exc_BaseException_type]
    extern type_stamp_methods
    call type_stamp_methods

    ; __new__ goes in after the stamp AND inside a staticmethod.  Its first
    ; argument is the class being built, not a BaseException, so the receiver
    ; check the stamp installs would refuse every correct call -- and a bare
    ; builtin function BINDS on instance access, which put the instance in
    ; args[0] for `ValueError("x").__new__(ValueError)`.  A staticmethod is
    ; what CPython makes __new__, and it is what stops both.
    EXC_ADD_STATIC exc_method_new, "__new__"

    ; OSError keeps one method of its own, because its reduction is not the
    ; general one: the filename goes back into the ARGUMENTS and the four
    ; named attributes must not go out as a state.  A dict of one entry on
    ; exc_OSError_type is all it takes -- everything else still resolves along
    ; the MRO to BaseException's.
    call dict_new
    test rax, rax
    jz .eim_out
    mov rbx, rax
    mov [rel exc_OSError_type + PyTypeObject.tp_dict], rbx
    extern oserror_reduce
    EXC_ADD_METHOD oserror_reduce, "__reduce__"
    lea rdi, [rel exc_OSError_type]
    call type_stamp_methods
.eim_out:
    pop rbx
    leave
    ret
END_FUNC exc_install_methods

;; ============================================================================
;; exc_user_init(rdi = an exception type) -> rax = its own __init__, or 0
;;
;; The Python `__init__` a class in the exception hierarchy defines, found
;; along the MRO because it is inherited: `class F(E): pass` runs E's.  A
;; builtin's is the default and does not count -- BaseException's is what
;; stores .args, and it is what refuses keywords.
;; ============================================================================
global exc_user_init

;; ============================================================================
;; exc_user_new(rdi = the class) -> rax = its Python __new__, borrowed, or 0
;;
;; The same question exc_user_init asks about __init__, about __new__: is
;; there one defined in PYTHON anywhere along this class's MRO?  A builtin
;; answer is the default -- object's or BaseException's -- and means "no", so
;; that a class with no constructor of its own keeps the fast path.
;;
;; type_call's exception arm went straight to exc_type_call, which finds a
;; BUILTIN tp_new along tp_base, and never asked this: a __new__ written in
;; Python was skipped for `E()` as much as for `raise E`.
;;
;; A __new__ in a class body is implicitly a staticmethod, so what comes back
;; is usually a staticmethod object.  It is callable as it stands, and the
;; class has to be passed explicitly either way, so it is handed back as it
;; is rather than unwrapped.
;; ============================================================================
global exc_user_new
DEF_FUNC exc_user_new, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    test rdi, rdi
    jz .eun_none
    lea rsi, [rel exc_new_name]
    call dunder_lookup
    V_UNPACK rax, rdx
    test edx, edx
    jz .eun_none
    cmp edx, TAG_PTR
    jne .eun_none
    test rax, rax
    jz .eun_none
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel builtin_func_type]
    cmp rcx, rdx
    je .eun_none                ; a builtin: the default, not a definition
    ; A staticmethod wrapping a builtin is the same default: BaseException's
    ; own __new__ is registered that way, and unwrapping is how to see it.
    extern staticmethod_type
    lea rdx, [rel staticmethod_type]
    cmp rcx, rdx
    jne .eun_out
    mov rcx, [rax + PyStaticMethodObject.sm_callable]
    test rcx, rcx
    jz .eun_none
    V_TEST_PTR rcx, rdx
    ja .eun_out
    mov rcx, [rcx + PyObject.ob_type]
    lea rdx, [rel builtin_func_type]
    cmp rcx, rdx
    je .eun_none
.eun_out:
    pop rbx
    leave
    ret
.eun_none:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC exc_user_new

;; ============================================================================
;; exc_user_init(rdi = the class) -> rax = its Python __init__, borrowed, or 0
;;
;; The __init__ to run, found along the MRO rather than in the class's own
;; slot: it is inherited, and `class F(E): pass` runs E's.  A builtin answer is
;; BaseException's default and means "no", which is what keeps a class with no
;; constructor of its own on the fast path.
;; ============================================================================
DEF_FUNC exc_user_init, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    test rdi, rdi
    jz .eui_none
    lea rsi, [rel exc_init_name]
    extern dunder_lookup
    call dunder_lookup
    V_UNPACK rax, rdx
    test edx, edx
    jz .eui_none
    cmp edx, TAG_PTR
    jne .eui_none
    test rax, rax
    jz .eui_none
    mov rcx, [rax + PyObject.ob_type]
    extern builtin_func_type
    lea rdx, [rel builtin_func_type]
    cmp rcx, rdx
    je .eui_none                ; a builtin: the default, not a definition
    pop rbx
    leave
    ret
.eui_none:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC exc_user_init

DEF_FUNC exc_type_call, ETC_FRAME
    push rbx
    push r12

    mov rbx, rdi            ; rbx = type
    mov [rbp - ETC_ARGS], rsi
    mov [rbp - ETC_NARGS], rdx
    mov qword [rbp - ETC_KW1], 0
    mov qword [rbp - ETC_KW2], 0
    ; The family is read again at .done, and the user-__init__ path below
    ; reaches it without going through exc_kw_family.
    mov qword [rbp - ETC_KWFAM], 0

    ; ------------------------------------------------------------------
    ; Keyword arguments.  AttributeError and ImportError each carry two
    ; named attributes -- `AttributeError("x", name=n, obj=o)` and
    ; `ImportError("x", name=n, path=p)` -- and the stdlib reads both back:
    ; importlib sets ModuleNotFoundError.name, and the "did you mean"
    ; machinery reads AttributeError.name and .obj.  Neither existed here.
    ; The keywords were folded into .args, so `.args` came out one item too
    ; long and `.name` was an AttributeError of its own.
    ;
    ; They are the only builtin exceptions that take keywords; every other
    ; one answers "takes no keyword arguments", as CPython's does.
    ; ------------------------------------------------------------------
    ; A class that defines its own __init__ takes whatever keywords that
    ; __init__ takes, and type_call runs it after this returns.  Consuming
    ; kw_names_pending here, and refusing the keywords before that runs, made
    ; every user exception with a keyword parameter unconstructible.  Only
    ; the count comes off, so .args holds the positionals; the names stay
    ; pending for the __init__ call.
    mov rdi, rbx
    call exc_user_init
    test rax, rax
    jz .etc_no_user_init
    mov r12, [rel kw_names_pending]
    test r12, r12
    jz .etc_kw_done
    mov rcx, [r12 + PyTupleObject.ob_size]
    sub [rbp - ETC_NARGS], rcx
    jmp .etc_kw_done
.etc_no_user_init:

    mov rdi, rbx
    call exc_kw_family
    mov [rbp - ETC_KWFAM], rax

    mov r12, [rel kw_names_pending]
    test r12, r12
    jz .etc_kw_done
    mov qword [rel kw_names_pending], 0     ; consumed, however this ends
    mov rcx, [r12 + PyTupleObject.ob_size]
    sub [rbp - ETC_NARGS], rcx              ; .args gets the positionals only
    cmp qword [rbp - ETC_KWFAM], 0
    je .etc_no_keywords

    xor edx, edx                            ; the keyword index
.etc_kw_loop:
    cmp rdx, [r12 + PyTupleObject.ob_size]
    jge .etc_kw_done
    mov rax, [r12 + PyTupleObject.ob_item]
    mov r8, [rax + rdx*8]                   ; the keyword's name
    mov rax, [rbp - ETC_NARGS]
    add rax, rdx
    mov rcx, [rbp - ETC_ARGS]
    mov r9, [rcx + rax*8]                   ; the value that goes with it

    push rdx
    push r8
    push r9
    sub rsp, 8
    lea rdi, [r8 + PyStrObject.data]
    CSTRING rsi, "name"
    call ap_strcmp
    test eax, eax
    jz .etc_kw_name
    mov r8, [rsp + 16]
    lea rdi, [r8 + PyStrObject.data]
    cmp qword [rbp - ETC_KWFAM], 1
    je .etc_kw_cmp_obj
    CSTRING rsi, "path"
    jmp .etc_kw_cmp2
.etc_kw_cmp_obj:
    CSTRING rsi, "obj"
.etc_kw_cmp2:
    call ap_strcmp
    test eax, eax
    jz .etc_kw_second
    add rsp, 8
    pop r9
    pop r8
    pop rdx
    lea rdi, [r8 + PyStrObject.data]
    mov rsi, [rbx + PyTypeObject.tp_name]
    call exc_raise_bad_keyword
.etc_kw_name:
    add rsp, 8
    pop r9
    pop r8
    pop rdx
    mov [rbp - ETC_KW1], r9
    jmp .etc_kw_next
.etc_kw_second:
    add rsp, 8
    pop r9
    pop r8
    pop rdx
    mov [rbp - ETC_KW2], r9
.etc_kw_next:
    inc rdx
    jmp .etc_kw_loop
.etc_no_keywords:
    xor edi, edi                ; no keyword name: the whole class is refused
    mov rsi, [rbx + PyTypeObject.tp_name]
    call exc_raise_bad_keyword
.etc_kw_done:
    mov rdx, [rbp - ETC_NARGS]
    mov rsi, [rbp - ETC_ARGS]

    ; Check for a constructor (ExceptionGroup's, or OSError's).  It lives in
    ; tp_new; tp_call would make instances callable.
    ;
    ; The search follows the base chain, because a constructor is inherited:
    ; CPython's FileNotFoundError(2, "x", "/f") runs OSError.__new__ and comes
    ; out with .errno and .filename set.  DEF_EXC_TYPE leaves tp_new 0 on every
    ; subclass, so looking only at the exact type found nothing for them.  The
    ; remapping OSError's constructor does is separately gated on the type
    ; being exactly OSError, which is what CPython gates it on too.
    ; The walk stops at object: BaseException's tp_base IS object_type, and
    ; add_builtin_type puts object_type_call in object's tp_new -- so running
    ; past it made every exception build a bare object instead, and `raise
    ; ValueError("x")` became "exceptions must derive from BaseException".
    mov rax, rbx
.etc_find_new:
    lea rcx, [rel object_type]
    cmp rax, rcx
    je .default_exc_create
    mov rcx, [rax + PyTypeObject.tp_new]
    test rcx, rcx
    jnz .etc_have_new
    mov rax, [rax + PyTypeObject.tp_base]
    test rax, rax
    jnz .etc_find_new
    jmp .default_exc_create
.etc_have_new:
    mov rax, rcx
    ; Delegate to the type's own constructor, which still returns a fat pair
    mov rdi, rbx
    mov rsi, [rbp - ETC_ARGS]
    mov rdx, [rbp - ETC_NARGS]
    pop r12
    pop rbx
    leave
    sub rsp, 8                  ; keep the callee's rsp 16-byte aligned
    call rax
    add rsp, 8
    V_PACK rax, rdx
    ret

.default_exc_create:
    ; Get message from args[0] if nargs >= 1
    test edx, edx
    jz .no_args
    mov rsi, [rsi]           ; args[0] is already the message Value
    jmp .create
.no_args:
    xor esi, esi             ; msg = NULL (no message)
    xor edx, edx             ; no tag
.create:
    ; Create exception: exc_new(type, msg, msg_tag)
    mov rdi, rbx
    call exc_new
    mov [rbp - ETC_EXC], rax

    ; Build args tuple from all arguments (not just the first one)
    ; exc_new already created a 0-or-1 element args tuple, replace if nargs > 1
    mov rcx, [rbp - ETC_NARGS]
    cmp rcx, 2
    jl .done

    ; Need to build a proper args tuple with all nargs items
    mov rdi, rcx
    call tuple_new
    mov r12, rax             ; r12 = new args tuple
    mov rcx, [rbp - ETC_NARGS]
    mov rsi, [rbp - ETC_ARGS]
    xor edx, edx
.copy_args:
    mov rcx, [rbp - ETC_NARGS]   ; reload loop limit (clobbered below)
    cmp rdx, rcx
    jge .replace_args
    mov rcx, rdx
    shl rcx, 3                    ; one Value per arg slot
    mov rdi, [rsi + rcx]          ; the argument Value
    INCREF_V rdi, r8
    mov r9, [r12 + PyTupleObject.ob_item]
    mov [r9 + rdx * 8], rdi
    inc rdx
    jmp .copy_args
.replace_args:
    ; DECREF old args tuple
    mov rdi, [rbp - ETC_EXC]
    mov rax, [rdi + PyExceptionObject.exc_args]
    test rax, rax
    jz .set_new_args
    push r12
    mov rdi, rax
    call obj_decref
    pop r12
.set_new_args:
    mov rdi, [rbp - ETC_EXC]
    mov [rdi + PyExceptionObject.exc_args], r12

.done:
    ; The two named attributes, defaulting to None -- CPython reports None
    ; there, not AttributeError, when they were not given.
    cmp qword [rbp - ETC_KWFAM], 0
    je .etc_finish
    mov rdi, [rbp - ETC_EXC]
    mov rsi, [rbp - ETC_KWFAM]
    mov rdx, [rbp - ETC_KW1]
    mov rcx, [rbp - ETC_KW2]
    call exc_store_named
.etc_finish:
    mov rax, [rbp - ETC_EXC]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; tp_call returns one Value
    ret
END_FUNC exc_type_call

;; exc_kw_family(rdi = the type) -> rax = 0 none, 1 AttributeError,
;;                                       2 ImportError
DEF_FUNC_LOCAL exc_kw_family, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    lea rsi, [rel exc_AttributeError_type]
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jnz .ekf_attr
    mov rdi, rbx
    lea rsi, [rel exc_ImportError_type]
    call type_is_subtype
    test eax, eax
    jnz .ekf_import
    xor eax, eax
    pop rbx
    leave
    ret
.ekf_attr:
    mov eax, 1
    pop rbx
    leave
    ret
.ekf_import:
    mov eax, 2
    pop rbx
    leave
    ret
END_FUNC exc_kw_family

;; exc_raise_bad_keyword(rdi = the keyword's name as a C string, or 0 when the
;;                        type takes none at all; rsi = the type's name)
;; CPython's two wordings:
;;   'foo' is an invalid keyword argument for AttributeError()
;;   ValueError() takes no keyword arguments
ERB_NAME  equ 8
ERB_TYPE  equ 16
ERB_BUF   equ 192
ERB_FRAME equ 192           ; + 0 pushes = 192, 16-aligned
DEF_FUNC_LOCAL exc_raise_bad_keyword, ERB_FRAME
    mov [rbp - ERB_NAME], rdi
    mov [rbp - ERB_TYPE], rsi
    lea rdi, [rbp - ERB_BUF]
    cmp qword [rbp - ERB_NAME], 0
    je .erb_none_taken
    CSTRING rsi, "'"
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - ERB_NAME]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "' is an invalid keyword argument for "
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - ERB_TYPE]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "()"
    call rbt_append_cstr
    jmp .erb_raise
.erb_none_taken:
    mov rsi, [rbp - ERB_TYPE]
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "() takes no keyword arguments"
    call rbt_append_cstr
.erb_raise:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - ERB_BUF]
    call raise_exception
END_FUNC exc_raise_bad_keyword

;; exc_store_named(rdi = the exception, rsi = the family,
;;                 rdx = the 'name' Value or 0, rcx = the second one or 0)
ESN_EXC   equ 8
ESN_FAM   equ 16
ESN_V1    equ 24
ESN_V2    equ 32
ESN_FRAME equ 48            ; + 0 pushes = 48
DEF_FUNC_LOCAL exc_store_named, ESN_FRAME
    mov [rbp - ESN_EXC], rdi
    mov [rbp - ESN_FAM], rsi
    mov [rbp - ESN_V1], rdx
    mov [rbp - ESN_V2], rcx

    CSTRING rdi, "name"
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    mov rdi, [rbp - ESN_EXC]
    mov rsi, [rsp + 8]
    mov rdx, [rbp - ESN_V1]
    test rdx, rdx
    jnz .esn_have1
    lea rdx, [rel none_singleton]
.esn_have1:
    ; No INCREF here.  exc_setattr's generic path is dict_set, which takes its
    ; own reference -- so an INCREF on top of it left the value with one
    ; reference too many, and every ImportError(name=n, path=p) and
    ; AttributeError(name=n, obj=o) leaked both values.  Invisible for years
    ; because almost every call passes string CONSTANTS out of co_consts,
    ; which outlive the exception anyway, and because the defaults are the
    ; None singleton.
    xor ecx, ecx
    call exc_setattr
    add rsp, 8
    pop rdi
    call obj_decref

    cmp qword [rbp - ESN_FAM], 1
    je .esn_second_obj
    CSTRING rdi, "path"
    jmp .esn_second
.esn_second_obj:
    CSTRING rdi, "obj"
.esn_second:
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    mov rdi, [rbp - ESN_EXC]
    mov rsi, [rsp + 8]
    mov rdx, [rbp - ESN_V2]
    test rdx, rdx
    jnz .esn_have2
    lea rdx, [rel none_singleton]
.esn_have2:
    xor ecx, ecx                ; borrowed, as above
    call exc_setattr
    add rsp, 8
    pop rdi
    call obj_decref
    leave
    ret
END_FUNC exc_store_named

;; ============================================================================
;; exc_raise_import(rdi = the type, rsi = message C string,
;;                  rdx = the `name` Value or 0, rcx = the `path` Value or 0,
;;                  r8 = 1 to release rdx and rcx afterwards, 0 to borrow them)
;;     -- does not return
;;
;; The import machinery's own ImportErrors, with the two named attributes
;; CPython's carry.  exc_from_cstr cannot do this for the family in general:
;; it is on the path of every internally raised exception, StopIteration from
;; call_iternext included, and a type_is_subtype plus two dict_sets there
;; would be paid by every `for` loop that ends.  So the import sites ask for
;; it and nothing else does.
;;
;; exc_store_named substitutes None for a 0 and hands the value to
;; exc_setattr, whose generic path is dict_set -- and dict_set takes its own
;; reference.  So the two values arrive here BORROWED: storing one does not
;; consume the caller's reference.
;;
;; r8 = 1 releases them after they have been stored, which is what a caller
;; that built the name string only for this needs -- it cannot release it
;; itself, because this does not return.
;; ============================================================================
ERI_NAME  equ 8
ERI_PATH  equ 16
ERI_OWN   equ 24
ERI_FRAME equ 32                ; + 0 pushes = 32, 16-aligned
DEF_FUNC exc_raise_import, ERI_FRAME
    mov [rbp - ERI_NAME], rdx
    mov [rbp - ERI_PATH], rcx
    mov [rbp - ERI_OWN], r8
    call exc_from_cstr
    test rax, rax
    jz .eri_oom
    mov rdi, rax
    push rax
    sub rsp, 8
    mov esi, 2                  ; the ImportError family: name and path
    mov rdx, [rbp - ERI_NAME]
    mov rcx, [rbp - ERI_PATH]
    call exc_store_named
    add rsp, 8
    pop rdi
    cmp qword [rbp - ERI_OWN], 0
    je .eri_raise
    push rdi
    sub rsp, 8
    mov rdi, [rbp - ERI_NAME]
    test rdi, rdi
    jz .eri_drop_path
    call obj_decref
.eri_drop_path:
    mov rdi, [rbp - ERI_PATH]
    test rdi, rdi
    jz .eri_dropped
    call obj_decref
.eri_dropped:
    add rsp, 8
    pop rdi
.eri_raise:
    call raise_exception_obj
    ud2
.eri_oom:
    ; No memory for the exception itself; the unwinder still has to run, and
    ; exc_install handles a 0 by leaving whatever is pending in place.
    xor edi, edi
    call raise_exception_obj
    ud2
END_FUNC exc_raise_import





;; ============================================================================
;; Data section - Exception type objects and name strings
;; ============================================================================
section .data

; Exception type name strings
exc_name_BaseException:     db "BaseException", 0
exc_name_Exception:         db "Exception", 0
exc_name_TypeError:         db "TypeError", 0
exc_name_ValueError:        db "ValueError", 0

exc_name_KeyError:          db "KeyError", 0
exc_name_IndexError:        db "IndexError", 0
exc_name_AttributeError:    db "AttributeError", 0
exc_name_NameError:         db "NameError", 0
exc_name_UnboundLocalError: db "UnboundLocalError", 0
exc_name_RuntimeError:      db "RuntimeError", 0
exc_name_StopIteration:     db "StopIteration", 0
exc_name_ZeroDivisionError: db "ZeroDivisionError", 0
exc_name_ImportError:       db "ImportError", 0
exc_name_NotImplementedError: db "NotImplementedError", 0
exc_name_FileNotFoundError: db "FileNotFoundError", 0
exc_name_FileExistsError:   db "FileExistsError", 0
exc_name_UnicodeTranslateError: db "UnicodeTranslateError", 0
exc_name_OverflowError:     db "OverflowError", 0
exc_name_AssertionError:    db "AssertionError", 0
exc_name_KeyboardInterrupt: db "KeyboardInterrupt", 0
exc_name_MemoryError:       db "MemoryError", 0
exc_name_RecursionError:    db "RecursionError", 0
exc_name_SystemExit:        db "SystemExit", 0
exc_name_OSError:           db "OSError", 0
exc_name_LookupError:       db "LookupError", 0
exc_name_ArithmeticError:   db "ArithmeticError", 0
exc_name_UnicodeError:      db "UnicodeError", 0
exc_name_Warning:           db "Warning", 0
exc_name_DeprecationWarning: db "DeprecationWarning", 0
exc_name_UserWarning:       db "UserWarning", 0
exc_name_CancelledError:    db "CancelledError", 0
exc_name_StopAsyncIteration: db "StopAsyncIteration", 0
exc_name_TimeoutError:      db "TimeoutError", 0
exc_name_GeneratorExit:     db "GeneratorExit", 0
exc_name_ModuleNotFoundError: db "ModuleNotFoundError", 0
exc_name_SyntaxError:       db "SyntaxError", 0
exc_name_IndentationError:  db "IndentationError", 0
exc_name_TabError:          db "TabError", 0
exc_name_EOFError:          db "EOFError", 0
exc_name_UnicodeDecodeError: db "UnicodeDecodeError", 0
exc_name_UnicodeEncodeError: db "UnicodeEncodeError", 0
exc_name_ConnectionError:   db "ConnectionError", 0
exc_name_ConnectionResetError: db "ConnectionResetError", 0
exc_name_ConnectionRefusedError: db "ConnectionRefusedError", 0
exc_name_ConnectionAbortedError: db "ConnectionAbortedError", 0
exc_name_BrokenPipeError:   db "BrokenPipeError", 0
exc_name_PermissionError:   db "PermissionError", 0
exc_name_IsADirectoryError: db "IsADirectoryError", 0
exc_name_NotADirectoryError: db "NotADirectoryError", 0
exc_name_ProcessLookupError: db "ProcessLookupError", 0
exc_name_ChildProcessError: db "ChildProcessError", 0
exc_name_BlockingIOError:   db "BlockingIOError", 0
exc_name_InterruptedError:  db "InterruptedError", 0
exc_name_FloatingPointError: db "FloatingPointError", 0
exc_name_BufferError:       db "BufferError", 0
exc_name_ReferenceError:    db "ReferenceError", 0
exc_name_SystemError:       db "SystemError", 0
exc_name_RuntimeWarning:    db "RuntimeWarning", 0
exc_name_FutureWarning:     db "FutureWarning", 0
exc_name_ImportWarning:     db "ImportWarning", 0
exc_name_UnicodeWarning:    db "UnicodeWarning", 0
exc_name_ResourceWarning:   db "ResourceWarning", 0
exc_name_BytesWarning:      db "BytesWarning", 0
exc_name_PendingDeprecationWarning: db "PendingDeprecationWarning", 0
exc_name_SyntaxWarning:     db "SyntaxWarning", 0
exc_name_EncodingWarning:   db "EncodingWarning", 0

; Exception metatype - provides tp_call so exception types can be called
; e.g., ValueError("msg") works via CALL opcode
align 8
global exc_metatype
exc_metatype:
    dq 1                    ; ob_refcnt (immortal)
    dq type_type            ; ob_type
    dq exc_meta_name        ; tp_name
    dq TYPE_OBJECT_SIZE     ; tp_basicsize (PyTypeObject size)
    dq 0                    ; tp_dealloc (types are immortal)
    dq type_repr            ; tp_repr — <class 'ExcName'>
    dq type_repr            ; tp_str — same as repr
    dq 0                    ; tp_hash
    dq exc_type_call        ; tp_call  <-- enables CALL on exception types
    dq type_getattr         ; tp_getattr — enables __name__ etc.
    ; type_setattr, as on every other metatype: it refuses a static type with
    ; CPython's TypeError ("cannot set 'x' attribute of immutable type
    ; 'ValueError'") and would store into a heaptype.  With 0 here the
    ; refusal was op_store_attr's generic AttributeError instead.
    extern type_setattr
    dq type_setattr         ; tp_setattr
    dq 0                    ; tp_richcompare
    dq 0                    ; tp_iter
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq 0                    ; tp_new
    dq type_number_methods      ; tp_as_number -- `C | None` builds a
                                ; union, and a class's `|` is its
                                ; METATYPE's slot, not its own
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    ; tp_base — `type`, because this IS a metatype and a metatype is a kind of
    ; type.  With 0 here, type_is_subtype's walk (which for a static type is
    ; the tp_base chain) stopped at exc_metatype itself, so every builtin
    ; exception class answered False to isinstance(cls, type) -- and CPython's
    ; warnings.py opens by asserting exactly that, which is why importing it,
    ; and pathlib, tempfile, shutil, random, argparse and tarfile behind it,
    ; failed.  user_type_metatype has said type_type here all along.
    dq type_type            ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq TYPE_FLAG_METATYPE   ; tp_flags (no HAVE_GC — exc types are static, not gc_alloc'd)
    dq 0                    ; tp_bases
    dq 0                    ; tp_traverse
    dq 0                    ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; The metatype is implementation detail -- it exists so an exception class can
; carry a tp_call of its own -- and it says `type`, as user_type_metatype
; already did.  Naming itself made `type(ValueError)` print
; <class 'exception_metatype'> where CPython prints <class 'type'>.
exc_meta_name: db "type", 0
exc_init_name: db "__init__", 0
exc_new_name:  db "__new__", 0


; Macro to define an exception type singleton
; %1 = label, %2 = name string, %3 = tp_base (or 0)
%macro DEF_EXC_TYPE 3
align 8
global %1
%1:
    dq 1                    ; ob_refcnt (immortal)
    dq exc_metatype         ; ob_type (metatype with tp_call)
    dq %2                   ; tp_name
    dq PyExceptionObject_size ; tp_basicsize
    dq exc_dealloc          ; tp_dealloc
    dq exc_repr             ; tp_repr
    dq exc_str              ; tp_str
    dq 0                    ; tp_hash
    dq 0                    ; tp_call
    dq exc_getattr          ; tp_getattr
    dq exc_setattr          ; tp_setattr
    dq 0                    ; tp_richcompare
    dq 0                    ; tp_iter
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq 0                    ; tp_new
    dq 0                    ; tp_as_number
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    dq %3                   ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq TYPE_FLAG_HAVE_GC    ; tp_flags
    dq 0                    ; tp_bases
    dq exc_traverse         ; tp_traverse
    dq exc_clear_gc         ; tp_clear
    ; An exception's instance dict is exc_dict, and saying so is what lets
    ; the GENERIC machinery find it: obj_generic_attr and
    ; object.__getstate__ both go through tp_dictoffset, and with a zero
    ; there `Exception('x').__getstate__()` was None however many attributes
    ; had been set.  It is also what type_from_parts inherits, so a subclass
    ; stops putting a SECOND dict one word past the end of an object whose
    ; constructor allocates exactly PyExceptionObject_size.
    dq PyExceptionObject.exc_dict ; tp_dictoffset
    dq 0                        ; tp_tailslots
    ; An exception exports no buffer.  This row was MISSING: the commit that
    ; added tp_as_buffer appended it to all 96 literal static tables and not
    ; to this macro, so every one of the hundred-odd exception types read the
    ; NEXT table's ob_refcnt -- 1 or 2 -- as a function pointer.  The tables
    ; are laid out back to back, so `b"x" == ValueError("y")` called address
    ; 2 by way of bytes_like_ptr_len.  lint's table check counts only literal
    ; tables and cannot see a macro, which is why the tree linted clean.
    dq 0                        ; tp_as_buffer
%endmacro

; Define all exception types
extern object_type
DEF_EXC_TYPE exc_BaseException_type, exc_name_BaseException, object_type
DEF_EXC_TYPE exc_Exception_type, exc_name_Exception, exc_BaseException_type
DEF_EXC_TYPE exc_TypeError_type, exc_name_TypeError, exc_Exception_type
DEF_EXC_TYPE exc_ValueError_type, exc_name_ValueError, exc_Exception_type
DEF_EXC_TYPE exc_KeyError_type, exc_name_KeyError, exc_LookupError_type
DEF_EXC_TYPE exc_IndexError_type, exc_name_IndexError, exc_LookupError_type
DEF_EXC_TYPE exc_AttributeError_type, exc_name_AttributeError, exc_Exception_type
DEF_EXC_TYPE exc_NameError_type, exc_name_NameError, exc_Exception_type
DEF_EXC_TYPE exc_UnboundLocalError_type, exc_name_UnboundLocalError, exc_NameError_type
DEF_EXC_TYPE exc_RuntimeError_type, exc_name_RuntimeError, exc_Exception_type
DEF_EXC_TYPE exc_StopIteration_type, exc_name_StopIteration, exc_Exception_type
DEF_EXC_TYPE exc_ZeroDivisionError_type, exc_name_ZeroDivisionError, exc_ArithmeticError_type
DEF_EXC_TYPE exc_ImportError_type, exc_name_ImportError, exc_Exception_type
DEF_EXC_TYPE exc_NotImplementedError_type, exc_name_NotImplementedError, exc_RuntimeError_type
DEF_EXC_TYPE exc_FileNotFoundError_type, exc_name_FileNotFoundError, exc_OSError_type
DEF_EXC_TYPE exc_FileExistsError_type, exc_name_FileExistsError, exc_OSError_type
DEF_EXC_TYPE exc_UnicodeTranslateError_type, exc_name_UnicodeTranslateError, exc_UnicodeError_type
DEF_EXC_TYPE exc_OverflowError_type, exc_name_OverflowError, exc_ArithmeticError_type
DEF_EXC_TYPE exc_AssertionError_type, exc_name_AssertionError, exc_Exception_type
DEF_EXC_TYPE exc_KeyboardInterrupt_type, exc_name_KeyboardInterrupt, exc_BaseException_type
DEF_EXC_TYPE exc_MemoryError_type, exc_name_MemoryError, exc_Exception_type
DEF_EXC_TYPE exc_RecursionError_type, exc_name_RecursionError, exc_RuntimeError_type
DEF_EXC_TYPE exc_SystemExit_type, exc_name_SystemExit, exc_BaseException_type
DEF_EXC_TYPE exc_OSError_type, exc_name_OSError, exc_Exception_type
DEF_EXC_TYPE exc_LookupError_type, exc_name_LookupError, exc_Exception_type
DEF_EXC_TYPE exc_ArithmeticError_type, exc_name_ArithmeticError, exc_Exception_type
DEF_EXC_TYPE exc_UnicodeError_type, exc_name_UnicodeError, exc_ValueError_type
DEF_EXC_TYPE exc_Warning_type, exc_name_Warning, exc_Exception_type
DEF_EXC_TYPE exc_DeprecationWarning_type, exc_name_DeprecationWarning, exc_Warning_type
DEF_EXC_TYPE exc_UserWarning_type, exc_name_UserWarning, exc_Warning_type
DEF_EXC_TYPE exc_CancelledError_type, exc_name_CancelledError, exc_BaseException_type
DEF_EXC_TYPE exc_StopAsyncIteration_type, exc_name_StopAsyncIteration, exc_Exception_type
; CPython 3.12: TimeoutError is an OSError, and the errno map sends ETIMEDOUT
; here.  It was parented on Exception, so `except OSError` missed it.
DEF_EXC_TYPE exc_TimeoutError_type, exc_name_TimeoutError, exc_OSError_type
DEF_EXC_TYPE exc_GeneratorExit_type, exc_name_GeneratorExit, exc_BaseException_type
DEF_EXC_TYPE exc_ModuleNotFoundError_type, exc_name_ModuleNotFoundError, exc_ImportError_type
DEF_EXC_TYPE exc_SyntaxError_type, exc_name_SyntaxError, exc_Exception_type
DEF_EXC_TYPE exc_IndentationError_type, exc_name_IndentationError, exc_SyntaxError_type
DEF_EXC_TYPE exc_TabError_type, exc_name_TabError, exc_IndentationError_type
DEF_EXC_TYPE exc_EOFError_type, exc_name_EOFError, exc_Exception_type
DEF_EXC_TYPE exc_UnicodeDecodeError_type, exc_name_UnicodeDecodeError, exc_UnicodeError_type
DEF_EXC_TYPE exc_UnicodeEncodeError_type, exc_name_UnicodeEncodeError, exc_UnicodeError_type
DEF_EXC_TYPE exc_ConnectionError_type, exc_name_ConnectionError, exc_OSError_type
DEF_EXC_TYPE exc_ConnectionResetError_type, exc_name_ConnectionResetError, exc_ConnectionError_type
DEF_EXC_TYPE exc_ConnectionRefusedError_type, exc_name_ConnectionRefusedError, exc_ConnectionError_type
DEF_EXC_TYPE exc_ConnectionAbortedError_type, exc_name_ConnectionAbortedError, exc_ConnectionError_type
DEF_EXC_TYPE exc_BrokenPipeError_type, exc_name_BrokenPipeError, exc_ConnectionError_type
DEF_EXC_TYPE exc_PermissionError_type, exc_name_PermissionError, exc_OSError_type
DEF_EXC_TYPE exc_IsADirectoryError_type, exc_name_IsADirectoryError, exc_OSError_type
DEF_EXC_TYPE exc_NotADirectoryError_type, exc_name_NotADirectoryError, exc_OSError_type
DEF_EXC_TYPE exc_ProcessLookupError_type, exc_name_ProcessLookupError, exc_OSError_type
DEF_EXC_TYPE exc_ChildProcessError_type, exc_name_ChildProcessError, exc_OSError_type
DEF_EXC_TYPE exc_BlockingIOError_type, exc_name_BlockingIOError, exc_OSError_type
DEF_EXC_TYPE exc_InterruptedError_type, exc_name_InterruptedError, exc_OSError_type
DEF_EXC_TYPE exc_FloatingPointError_type, exc_name_FloatingPointError, exc_ArithmeticError_type
DEF_EXC_TYPE exc_BufferError_type, exc_name_BufferError, exc_Exception_type
DEF_EXC_TYPE exc_ReferenceError_type, exc_name_ReferenceError, exc_Exception_type
DEF_EXC_TYPE exc_SystemError_type, exc_name_SystemError, exc_Exception_type
DEF_EXC_TYPE exc_RuntimeWarning_type, exc_name_RuntimeWarning, exc_Warning_type
DEF_EXC_TYPE exc_FutureWarning_type, exc_name_FutureWarning, exc_Warning_type
DEF_EXC_TYPE exc_ImportWarning_type, exc_name_ImportWarning, exc_Warning_type
DEF_EXC_TYPE exc_UnicodeWarning_type, exc_name_UnicodeWarning, exc_Warning_type
DEF_EXC_TYPE exc_ResourceWarning_type, exc_name_ResourceWarning, exc_Warning_type
DEF_EXC_TYPE exc_BytesWarning_type, exc_name_BytesWarning, exc_Warning_type
DEF_EXC_TYPE exc_PendingDeprecationWarning_type, exc_name_PendingDeprecationWarning, exc_Warning_type
DEF_EXC_TYPE exc_SyntaxWarning_type, exc_name_SyntaxWarning, exc_Warning_type
DEF_EXC_TYPE exc_EncodingWarning_type, exc_name_EncodingWarning, exc_Warning_type

; Exception type lookup table indexed by EXC_* constants
align 8
global exception_type_table
exception_type_table:
    dq exc_BaseException_type        ; EXC_BASE_EXCEPTION = 0
    dq exc_Exception_type            ; EXC_EXCEPTION = 1
    dq exc_TypeError_type            ; EXC_TYPE_ERROR = 2
    dq exc_ValueError_type           ; EXC_VALUE_ERROR = 3
    dq exc_KeyError_type             ; EXC_KEY_ERROR = 4
    dq exc_IndexError_type           ; EXC_INDEX_ERROR = 5
    dq exc_AttributeError_type       ; EXC_ATTRIBUTE_ERROR = 6
    dq exc_NameError_type            ; EXC_NAME_ERROR = 7
    dq exc_RuntimeError_type         ; EXC_RUNTIME_ERROR = 8
    dq exc_StopIteration_type        ; EXC_STOP_ITERATION = 9
    dq exc_ZeroDivisionError_type    ; EXC_ZERO_DIVISION = 10
    dq exc_ImportError_type          ; EXC_IMPORT_ERROR = 11
    dq exc_NotImplementedError_type  ; EXC_NOT_IMPLEMENTED = 12
    dq exc_FileNotFoundError_type    ; EXC_FILE_NOT_FOUND = 13
    dq exc_OverflowError_type       ; EXC_OVERFLOW_ERROR = 14
    dq exc_AssertionError_type       ; EXC_ASSERTION_ERROR = 15
    dq exc_KeyboardInterrupt_type    ; EXC_KEYBOARD_INTERRUPT = 16
    dq exc_MemoryError_type          ; EXC_MEMORY_ERROR = 17
    dq exc_RecursionError_type       ; EXC_RECURSION_ERROR = 18
    dq exc_SystemExit_type           ; EXC_SYSTEM_EXIT = 19
    dq exc_OSError_type              ; EXC_OS_ERROR = 20
    dq exc_LookupError_type          ; EXC_LOOKUP_ERROR = 21
    dq exc_ArithmeticError_type      ; EXC_ARITHMETIC_ERROR = 22
    dq exc_UnicodeError_type         ; EXC_UNICODE_ERROR = 23
    dq exc_BaseExceptionGroup_type   ; EXC_BASE_EXCEPTION_GROUP = 24
    dq exc_ExceptionGroup_type       ; EXC_EXCEPTION_GROUP = 25
    dq exc_CancelledError_type       ; EXC_CANCELLED_ERROR = 26
    dq exc_StopAsyncIteration_type   ; EXC_STOP_ASYNC_ITERATION = 27
    dq exc_TimeoutError_type         ; EXC_TIMEOUT_ERROR = 28

section .text

;; ============================================================================
;; GC traverse and clear.  These lived in gc.asm, which left the collector
;; holding the reference graph of every type in the system; a type's own
;; file is the only place that knows which of its fields are owned.
;; ============================================================================

;; ============================================================================
;; ---- exc_traverse / exc_clear ----
;; ============================================================================
DEF_FUNC exc_traverse, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    mov rbx, rdi

    ; Visit exc_value (fat)
    mov rdi, [rbx + PyExceptionObject.exc_value]
    VISIT_V rdi, rsi

    ; Visit heap ptrs
    mov rdi, [rbx + PyExceptionObject.exc_tb]
    VISIT_PTR rdi
    mov rdi, [rbx + PyExceptionObject.exc_context]
    VISIT_PTR rdi
    mov rdi, [rbx + PyExceptionObject.exc_cause]
    VISIT_PTR rdi
    mov rdi, [rbx + PyExceptionObject.exc_args]
    VISIT_PTR rdi
    ; The instance dict, which CPython's BaseException_traverse visits first
    ; and this did not.  Leaving an edge out does not merely leak: the
    ; collector counts the references it is SHOWN, so an exception whose only
    ; referrer is reached through its own dict looked unreferenced and was
    ; collected while that referrer still held it.  Nothing put an arbitrary
    ; object in an exception's dict until AttributeError started carrying
    ; `.obj`, and then it was a SIGSEGV in gc_list_remove at an unrelated
    ; POP_EXCEPT.
    mov rdi, [rbx + PyExceptionObject.exc_dict]
    VISIT_PTR rdi

    pop rbx
    leave
    ret
END_FUNC exc_traverse

DEF_FUNC exc_clear_gc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; DECREF_VAL exc_value
    mov rdi, [rbx + PyExceptionObject.exc_value]
    mov qword [rbx + PyExceptionObject.exc_value], 0
    DECREF_V rdi, rsi

    ; XDECREF + NULL heap ptrs
    mov rdi, [rbx + PyExceptionObject.exc_tb]
    mov qword [rbx + PyExceptionObject.exc_tb], 0
    test rdi, rdi
    jz .no_tb
    call obj_decref
.no_tb:
    mov rdi, [rbx + PyExceptionObject.exc_context]
    mov qword [rbx + PyExceptionObject.exc_context], 0
    test rdi, rdi
    jz .no_ctx
    call obj_decref
.no_ctx:
    mov rdi, [rbx + PyExceptionObject.exc_cause]
    mov qword [rbx + PyExceptionObject.exc_cause], 0
    test rdi, rdi
    jz .no_cause
    call obj_decref
.no_cause:
    mov rdi, [rbx + PyExceptionObject.exc_args]
    mov qword [rbx + PyExceptionObject.exc_args], 0
    test rdi, rdi
    jz .no_args
    call obj_decref
.no_args:
    ; The dict, for the reason exc_traverse gives: an edge the collector is
    ; shown has to be an edge it can also break, or the cycle survives the
    ; sweep that found it.
    mov rdi, [rbx + PyExceptionObject.exc_dict]
    mov qword [rbx + PyExceptionObject.exc_dict], 0
    test rdi, rdi
    jz .no_dict_gc
    call obj_decref
.no_dict_gc:

    pop rbx
    leave
    ret
END_FUNC exc_clear_gc


