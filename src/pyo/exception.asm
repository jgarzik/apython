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
%include "types.inc"
%include "errcodes.inc"

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
extern exc_traverse
extern exc_clear_gc
extern tuple_new
extern tuple_type
extern ap_strcmp
extern dict_get
extern dict_new
extern dict_set
extern eg_dealloc
extern exc_BaseExceptionGroup_type
extern exc_ExceptionGroup_type

; exc_new(PyTypeObject *type, PyObject *msg_str, int msg_tag) -> PyExceptionObject*
; Creates a new exception with given type and message string.
; msg_str is INCREFed. type is stored but not INCREFed (types are immortal).
; rdx = msg_tag (TAG_PTR for heap objs, TAG_SMALLINT for ints, 0 for NULL).
EN_EXC equ 8
EN_MSG equ 16
EN_FRAME equ 16
DEF_FUNC exc_new, EN_FRAME
    push rbx
    push r12
    push r13

    mov rbx, rdi            ; type
    mov r12, rsi            ; msg_str
    mov r13, rdx            ; msg_tag

    ; Allocate exception object (GC-tracked)
    mov edi, PyExceptionObject_size
    mov rsi, rbx               ; type
    call gc_alloc
    ; ob_refcnt=1, ob_type set by gc_alloc
    mov [rax + PyExceptionObject.exc_type], rbx
    mov [rax + PyExceptionObject.exc_value], r12
    mov [rax + PyExceptionObject.exc_value_tag], r13
    mov qword [rax + PyExceptionObject.exc_tb], 0
    mov qword [rax + PyExceptionObject.exc_context], 0
    mov qword [rax + PyExceptionObject.exc_cause], 0
    mov qword [rax + PyExceptionObject.exc_args], 0

    ; INCREF the message (tag-aware)
    INCREF_VAL r12, r13

    ; Create args tuple: (msg_str,) if msg present, else ()
    mov [rbp - EN_EXC], rax   ; save exc
    test r13, r13             ; check tag for TAG_NULL, not payload (SmallInt(0) has payload=0)
    jz .empty_args
    mov edi, 1
    call tuple_new
    INCREF_VAL r12, r13
    mov r8, [rax + PyTupleObject.ob_item]       ; payloads
    mov r9, [rax + PyTupleObject.ob_item_tags]  ; tags
    mov [r8], r12
    mov byte [r9], r13b                         ; msg tag
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

; exc_from_cstr(PyTypeObject *type, const char *msg) -> PyExceptionObject*
; Creates exception with a C string message (converted to PyStrObject).
DEF_FUNC exc_from_cstr
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
    mov rsi, [rax + PyExceptionObject.exc_value_tag]
    DECREF_VAL rdi, rsi
    pop rax

    pop rbx
    leave
    ret
END_FUNC exc_from_cstr

; exc_dealloc(PyExceptionObject *exc)
; Free exception and DECREF its fields.
DEF_FUNC exc_dealloc
    push rbx

    mov rbx, rdi

    ; XDECREF exc_value (tag-aware: may be SmallInt)
    mov rdi, [rbx + PyExceptionObject.exc_value]
    mov rsi, [rbx + PyExceptionObject.exc_value_tag]
    XDECREF_VAL rdi, rsi
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

    ; Free the object (GC-aware)
    mov rdi, rbx
    call gc_dealloc

    pop rbx
    leave
    ret
END_FUNC exc_dealloc

; exc_repr(PyExceptionObject *exc) -> PyObject* (string)
; Returns "TypeName(msg)" or just "TypeName()" if no message.
DEF_FUNC exc_repr
    push rbx
    push r12
    sub rsp, 256            ; buffer for formatting

    mov rbx, rdi            ; exc

    ; Get type name
    mov rax, [rbx + PyExceptionObject.ob_type]
    mov r12, [rax + PyTypeObject.tp_name]  ; C string ptr

    ; Build string: "TypeName(msg)" into stack buffer
    lea rdi, [rbp - 256 - 16]   ; buffer start (well within stack)
    ; Copy type name
    mov rsi, r12
.copy_name:
    lodsb
    test al, al
    jz .name_done
    stosb
    jmp .copy_name
.name_done:
    mov byte [rdi], '('
    inc rdi

    ; Copy message if present (must be a heap string)
    cmp qword [rbx + PyExceptionObject.exc_value_tag], TAG_PTR
    jne .no_msg
    mov rax, [rbx + PyExceptionObject.exc_value]
    test rax, rax
    jz .no_msg

    ; Check if message is a string
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .no_msg

    ; Copy string data
    mov rsi, rax
    add rsi, PyStrObject.data
    mov rcx, [rax + PyStrObject.ob_size]
.copy_msg:
    test rcx, rcx
    jz .msg_done
    lodsb
    stosb
    dec rcx
    jmp .copy_msg

.no_msg:
.msg_done:
    mov byte [rdi], ')'
    inc rdi
    mov byte [rdi], 0

    ; Create string from buffer
    lea rdi, [rbp - 256 - 16]
    call str_from_cstr

    add rsp, 256
    pop r12
    pop rbx
    leave
    ret
END_FUNC exc_repr

; exc_str(PyExceptionObject *exc) -> PyObject* (string)
; Returns the message string, or type name if no message.
DEF_FUNC exc_str

    ; Return exc_value if it's a heap string
    cmp qword [rdi + PyExceptionObject.exc_value_tag], TAG_PTR
    jne .use_type_name
    mov rax, [rdi + PyExceptionObject.exc_value]
    test rax, rax
    jz .use_type_name

    ; Check if it's a string
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .use_type_name

    ; INCREF and return the message
    INCREF rax
    leave
    ret

.use_type_name:
    ; Return type name as string
    mov rax, [rdi + PyExceptionObject.ob_type]
    mov rdi, [rax + PyTypeObject.tp_name]
    call str_from_cstr
    leave
    ret
END_FUNC exc_str

; exc_getattr(PyExceptionObject *exc, PyStrObject *name) -> PyObject* or NULL
; Handle attribute access on exception objects: args, __context__, __cause__, etc.
global exc_getattr
DEF_FUNC exc_getattr
    push rbx
    push r12

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

    ; Check "__traceback__"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "__traceback__"
    call ap_strcmp
    test eax, eax
    jz .get_tb

    ; Check "value" (for StopIteration.value)
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "value"
    call ap_strcmp
    test eax, eax
    jz .get_value

    ; Not found — try type dict (for user-defined exception subclass attrs)
    mov rdi, [rbx + PyObject.ob_type]
    mov rdi, [rdi + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .not_found
    mov rsi, r12
    mov edx, TAG_PTR
    call dict_get
    test edx, edx
    jnz .found_in_type

.not_found:
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.found_in_type:
    INCREF_VAL rax, rdx     ; tag-aware INCREF (rdx = tag from dict_get)
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
    pop r12
    pop rbx
    leave
    ret

.return_empty_tuple:
    xor edi, edi
    call tuple_new
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.get_context:
    mov rax, [rbx + PyExceptionObject.exc_context]
    test rax, rax
    jz .return_none
    INCREF rax
    mov edx, TAG_PTR
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
    pop r12
    pop rbx
    leave
    ret

.get_tb:
    mov rax, [rbx + PyExceptionObject.exc_tb]
    test rax, rax
    jz .return_none
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
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
    mov rcx, [rax + PyTupleObject.ob_item]       ; payloads
    mov r8, [rax + PyTupleObject.ob_item_tags]   ; tags
    mov rax, [rcx]                               ; payload
    movzx edx, byte [r8]                         ; tag
    INCREF_VAL rax, rdx
    pop r12
    pop rbx
    leave
    ret

.return_none:
    extern none_singleton
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC exc_getattr

; exc_isinstance(PyExceptionObject *exc, PyTypeObject *type) -> int (0/1)
; Check if exception is an instance of type, walking tp_base chain.
; If type is a tuple, checks each element.
extern tuple_type
DEF_FUNC_BARE exc_isinstance
    ; rdi = exc, rsi = target type (or tuple of types)
    ; Check if rsi is a tuple
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .tuple_match

    ; Single type: walk tp_base chain
    mov rax, [rdi + PyExceptionObject.ob_type]
.walk:
    test rax, rax
    jz .not_match
    cmp rax, rsi
    je .match
    mov rax, [rax + PyTypeObject.tp_base]
    jmp .walk
.match:
    mov eax, 1
    ret
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

; type_is_exc_subclass(PyTypeObject *type) -> int (0/1)
; Walk tp_base chain checking for a type with tp_dealloc == exc_dealloc.
; Detects user-defined exception classes (e.g., class MyError(Exception): pass)
global type_is_exc_subclass
DEF_FUNC_BARE type_is_exc_subclass
    lea rdx, [rel exc_dealloc]
    lea rcx, [rel eg_dealloc]
.tie_walk:
    test rdi, rdi
    jz .tie_no
    mov rax, [rdi + PyTypeObject.tp_dealloc]
    cmp rax, rdx
    je .tie_yes
    cmp rax, rcx
    je .tie_yes
    mov rdi, [rdi + PyTypeObject.tp_base]
    jmp .tie_walk
.tie_yes:
    mov eax, 1
    ret
.tie_no:
    xor eax, eax
    ret
END_FUNC type_is_exc_subclass

; exc_type_from_id(int exc_id) -> PyTypeObject*
; Look up exception type from EXC_* constant.
DEF_FUNC_BARE exc_type_from_id
    lea rax, [rel exception_type_table]
    mov rax, [rax + rdi*8]
    ret
END_FUNC exc_type_from_id

; exc_type_call(PyTypeObject *type, PyObject **args, int64_t nargs) -> PyObject*
; tp_call for exception metatype. Creates an exception instance.
; rdi = exception type (the class being called, e.g. ValueError)
; rsi = args array
; rdx = nargs
ETC_EXC   equ 8
ETC_ARGS  equ 16
ETC_NARGS equ 24
ETC_FRAME equ 24
DEF_FUNC exc_type_call, ETC_FRAME
    push rbx
    push r12

    mov rbx, rdi            ; rbx = type
    mov [rbp - ETC_ARGS], rsi
    mov [rbp - ETC_NARGS], rdx

    ; Check if the type has its own tp_call (e.g., ExceptionGroup)
    mov rax, [rbx + PyTypeObject.tp_call]
    test rax, rax
    jz .default_exc_create
    ; Delegate to type's own tp_call
    mov rdi, rbx
    mov rsi, [rbp - ETC_ARGS]
    mov rdx, [rbp - ETC_NARGS]
    pop r12
    pop rbx
    leave
    jmp rax

.default_exc_create:
    ; Get message from args[0] if nargs >= 1
    test edx, edx
    jz .no_args
    mov rdx, [rsi + 8]      ; rdx = args[0] tag
    mov rsi, [rsi]           ; rsi = args[0] (message payload)
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
    shl rcx, 4                    ; source index * 16 (args at 16B stride)
    mov rdi, [rsi + rcx]          ; payload
    mov r8, [rsi + rcx + 8]       ; tag
    INCREF_VAL rdi, r8
    mov r9, [r12 + PyTupleObject.ob_item]       ; payloads
    mov r10, [r12 + PyTupleObject.ob_item_tags] ; tags
    mov [r9 + rdx*8], rdi
    mov byte [r10 + rdx], r8b
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
    mov rax, [rbp - ETC_EXC]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC exc_type_call

; ============================================================================
; Traceback support
; ============================================================================

; traceback_new() -> PyTracebackObject*
; Allocates a new traceback with tb_next=NULL, tb_lineno=0.
global traceback_new
DEF_FUNC traceback_new
    mov edi, PyTracebackObject_size
    call ap_malloc
    mov qword [rax + PyTracebackObject.ob_refcnt], 1
    lea rcx, [rel traceback_type]
    mov [rax + PyTracebackObject.ob_type], rcx
    mov qword [rax + PyTracebackObject.tb_next], 0
    mov qword [rax + PyTracebackObject.tb_lineno], 0
    leave
    ret
END_FUNC traceback_new

; traceback_dealloc(PyTracebackObject *tb)
; XDECREF tb_next, free self.
global traceback_dealloc
DEF_FUNC traceback_dealloc
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyTracebackObject.tb_next]
    test rdi, rdi
    jz .no_next
    call obj_decref
.no_next:
    mov rdi, rbx
    call ap_free
    pop rbx
    leave
    ret
END_FUNC traceback_dealloc

; traceback_getattr(PyTracebackObject *tb, PyStrObject *name) -> (rax, edx)
; Handles tb_lineno, tb_next, tb_frame attributes.
global traceback_getattr
DEF_FUNC traceback_getattr
    push rbx
    push r12

    mov rbx, rdi            ; tb
    mov r12, rsi            ; name str

    ; Check "tb_lineno"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "tb_lineno"
    call ap_strcmp
    test eax, eax
    jz .tb_get_lineno

    ; Check "tb_next"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "tb_next"
    call ap_strcmp
    test eax, eax
    jz .tb_get_next

    ; Check "tb_frame"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "tb_frame"
    call ap_strcmp
    test eax, eax
    jz .tb_return_none

    ; Not found
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.tb_get_lineno:
    mov rax, [rbx + PyTracebackObject.tb_lineno]
    mov edx, TAG_SMALLINT
    pop r12
    pop rbx
    leave
    ret

.tb_get_next:
    mov rax, [rbx + PyTracebackObject.tb_next]
    test rax, rax
    jz .tb_return_none
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.tb_return_none:
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC traceback_getattr

; ============================================================================
; Data section - Exception type objects and name strings
; ============================================================================
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
    dq 0                    ; tp_setattr
    dq 0                    ; tp_richcompare
    dq 0                    ; tp_iter
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq 0                    ; tp_new
    dq 0                    ; tp_as_number
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq 0                    ; tp_flags (no HAVE_GC — exc types are static, not gc_alloc'd)
    dq 0                    ; tp_bases
    dq 0                    ; tp_traverse
    dq 0                    ; tp_clear

exc_meta_name: db "exception_metatype", 0

; Traceback type object (immortal)
align 8
global traceback_type
traceback_type:
    dq 1                    ; ob_refcnt (immortal)
    dq type_type            ; ob_type
    dq tb_type_name         ; tp_name
    dq PyTracebackObject_size ; tp_basicsize
    dq traceback_dealloc    ; tp_dealloc
    dq 0                    ; tp_repr
    dq 0                    ; tp_str
    dq 0                    ; tp_hash
    dq 0                    ; tp_call
    dq traceback_getattr    ; tp_getattr
    dq 0                    ; tp_setattr
    dq 0                    ; tp_richcompare
    dq 0                    ; tp_iter
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq 0                    ; tp_new
    dq 0                    ; tp_as_number
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq 0                    ; tp_flags
    dq 0                    ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
tb_type_name: db "traceback", 0

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
    dq 0                    ; tp_setattr
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
%endmacro

; Define all exception types
DEF_EXC_TYPE exc_BaseException_type, exc_name_BaseException, 0
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
DEF_EXC_TYPE exc_TimeoutError_type, exc_name_TimeoutError, exc_Exception_type

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
