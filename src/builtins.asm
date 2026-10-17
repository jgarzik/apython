; builtins.asm - The builtin function object, the core builtins, and the registry
;
; PyBuiltinObject and its type; print, len, range, type, isinstance,
; issubclass, repr, bool and float; and builtins_init, which is the single
; place every name in the builtins dict is registered.  The numeric and object
; builtins live in builtins_num.asm and builtins_obj.asm.

%include "macros.inc"
%include "object.inc"

extern dict_new
extern dict_set
extern str_from_cstr
extern str_from_cstr_heap
extern obj_str
extern obj_decref
extern obj_dealloc
extern builtin_isinstance
extern builtin_issubclass
extern bool_true
extern bool_false
extern none_singleton
extern int_from_i64
extern str_type
extern bool_type
extern float_type
extern ap_malloc
extern ap_free
extern raise_exception
extern sys_write
extern fileobj_write_fd
extern range_new
extern range_new_v
extern int_to_i64
extern obj_as_index
extern obj_as_index_clamped
extern init_iter_types
extern obj_repr
extern ap_memcpy
extern user_type_metatype
extern super_type
extern staticmethod_type
extern classmethod_type
extern property_type
extern type_type
extern list_type
extern dict_type
extern tuple_type
extern set_type
extern bytes_type

; New builtin function implementations (in builtins_extra.asm)
extern builtin_abs
extern builtin_divmod
extern int_type_call
extern str_type_call
extern bool_type_call
extern float_type_call
extern bytearray_type_call
extern memoryview_type_call
extern bytearray_type
extern memoryview_type
extern builtin_ord
extern builtin_chr
extern builtin_hex
extern builtin_id
extern builtin_hash_fn
extern builtin_callable
extern builtin_iter_fn
extern builtin_next_fn
extern builtin_any
extern builtin_all
extern builtin_sum
extern builtin_min
extern builtin_max
extern builtin_getattr
extern builtin_hasattr
extern builtin_setattr

; Iterator builtins (in itertools.asm)
extern builtin_sorted
extern builtin_globals
extern builtin_locals
extern builtin_dir
extern builtin_breakpoint

; Exception types
extern exc_BaseException_type
extern exc_Exception_type
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_KeyError_type
extern exc_IndexError_type
extern exc_AttributeError_type
extern exc_NameError_type
extern exc_UnboundLocalError_type
extern exc_RuntimeError_type
extern exc_StopIteration_type
extern exc_ZeroDivisionError_type
extern exc_ImportError_type
extern exc_NotImplementedError_type
extern exc_OverflowError_type
extern exc_AssertionError_type
extern exc_OSError_type
extern exc_LookupError_type
extern exc_ArithmeticError_type
extern exc_RecursionError_type
extern exc_MemoryError_type
extern exc_KeyboardInterrupt_type
extern exc_SystemExit_type
extern exc_UnicodeError_type
extern exc_Warning_type
extern exc_DeprecationWarning_type
extern exc_UserWarning_type
extern exc_BaseExceptionGroup_type
extern exc_ExceptionGroup_type
extern exc_CancelledError_type
extern exc_StopAsyncIteration_type
extern exc_TimeoutError_type

; --- moved to a sibling file by the split ---
extern builtin___build_class__

extern none_type

extern int_type

extern dict_add_builtin_func

extern bfg_get_builtin
extern builtin_func_dealloc
extern builtin_func_dunder_get
extern builtin_func_getattr
extern builtin_func_repr
extern builtin_kind_of
extern type_stamp_methods

section .text

;; ============================================================================
;; builtin_func_new(void *func_ptr, const char *name_cstr) -> PyBuiltinObject*
;; Create a new builtin function wrapper object
;; ============================================================================
DEF_FUNC builtin_func_new, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    mov rbx, rdi                ; func_ptr
    mov r12, rsi                ; name_cstr

    ; Create a string object for the name (heap — stored in struct field)
    mov rdi, r12
    call str_from_cstr_heap
    mov r13, rax                ; r13 = name string object

    ; Allocate PyBuiltinObject
    mov edi, PyBuiltinObject_size
    call ap_malloc
    ; rax = new object

    ; Fill header
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel builtin_func_type]
    mov [rax + PyObject.ob_type], rcx

    ; Fill builtin-specific fields
    mov qword [rax + PyBuiltinObject.func_id], 0   ; not used for func_ptr dispatch
    mov [rax + PyBuiltinObject.func_name], r13
    mov [rax + PyBuiltinObject.func_ptr], rbx
    mov qword [rax + PyBuiltinObject.min_args], 0  ; 0 = no check
    mov qword [rax + PyBuiltinObject.max_args], -1 ; -1 = no max check
    mov qword [rax + PyBuiltinObject.func_owner], 0
    mov qword [rax + PyBuiltinObject.func_kind], BUILTIN_KIND_FUNCTION

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC builtin_func_new

;; ============================================================================
;; builtin_func_new_checked(void *func_ptr, const char *name_cstr,
;;                          int64_t min_args, int64_t max_args)
;; Like builtin_func_new but sets arg count bounds for validation.
;; rdx = min_args (including self), rcx = max_args (-1 = no max)
;; ============================================================================
DEF_FUNC builtin_func_new_checked
    push r14
    push r15
    mov r14, rdx                ; min_args
    mov r15, rcx                ; max_args
    call builtin_func_new
    mov [rax + PyBuiltinObject.min_args], r14
    mov [rax + PyBuiltinObject.max_args], r15
    pop r15
    pop r14
    leave
    ret
END_FUNC builtin_func_new_checked

;; ============================================================================
;; builtin_func_call(PyObject *self, PyObject **args, int64_t nargs) -> PyObject*
;; Dispatch to the underlying C function: func_ptr(args, nargs)
;; Validates nargs against min_args/max_args if set.
;; ============================================================================
DEF_FUNC_BARE builtin_func_call
    ; self = rdi, args = rsi, nargs = rdx
    ; A method descriptor reached UNBOUND has to be handed one of its own
    ; type's instances.  Nothing checked, so `list.append((1, 2), 9)` read a
    ; tuple's header as a list's and tried to grow it -- "Fatal: out of
    ; memory", from a two-element tuple.  Every builtin method funnels
    ; through here, so one check covers all of them.
    ;
    ; func_owner is 0 for a plain module function, and for the static and
    ; class methods, which are wrapped in their own descriptor objects and so
    ; are never stamped -- exactly the ones whose first argument is a class
    ; rather than an instance.
    mov rcx, [rdi + PyBuiltinObject.func_owner]
    test rcx, rcx
    jz .bfc_receiver_ok
    cmp qword [rdi + PyBuiltinObject.func_kind], BUILTIN_KIND_ON_TYPE
    je .bfc_receiver_ok         ; its receiver is a class, not an instance
    test rdx, rdx
    jz .bfc_no_receiver         ; no arguments at all, so no receiver either
    push rdi
    push rsi
    push rdx
    sub rsp, 8
    mov rdi, [rsi]              ; args[0], the receiver
    extern value_type
    call value_type
    test rax, rax
    jz .bfc_wrong_receiver
    mov rdi, rax
    mov rsi, [rsp + 24]
    mov rsi, [rsi + PyBuiltinObject.func_owner]
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jz .bfc_wrong_receiver
    add rsp, 8
    pop rdx
    pop rsi
    pop rdi

.bfc_receiver_ok:
    ; The bounds are positional counts, and a keyword argument arrives in the
    ; same array with its name in kw_names_pending -- so `(-2).to_bytes(2,
    ; "big", signed=True)` is three by nargs and two by the signature.  Only
    ; the positional ones are counted; a method that takes no keywords at all
    ; still says so itself, as it did before any of this.
    mov r8, rdx
    mov rcx, [gs:ThreadState.kw_names_pending]
    test rcx, rcx
    jz .bfc_have_npos
    sub r8, [rcx + PyTupleObject.ob_size]
.bfc_have_npos:
    ; Check min_args (0 = no check)
    mov rcx, [rdi + PyBuiltinObject.min_args]
    test rcx, rcx
    jz .bfc_no_min_check
    cmp r8, rcx
    jl .bfc_too_few
.bfc_no_min_check:
    ; Check max_args (-1 = no check)
    mov rcx, [rdi + PyBuiltinObject.max_args]
    cmp rcx, -1
    je .bfc_no_max_check
    cmp r8, rcx
    jg .bfc_too_many
.bfc_no_max_check:
    ; Extract func_ptr from self
    mov rax, [rdi + PyBuiltinObject.func_ptr]
    ; Call func_ptr(args, nargs) — builtins return a Value, so this stays a
    ; tail call.
    mov rdi, rsi                ; args
    mov rsi, rdx                ; nargs
    jmp rax

.bfc_no_receiver:
    ; A method descriptor reached unbound with NO arguments at all.  This used
    ; to fall through to the arity check with the comment "the arity check
    ; ruled" -- and that was the bug, because min_args is 0 for everything
    ; registered with ADD_FN rather than ADD_FN_N, and 0 means "no check".  So
    ; the body was entered with a NULL args array and dereferenced args[0].
    ;
    ;     def g(): yield 1
    ;     type(g()).close(*())
    ;
    ; is five lines and a SIGSEGV, and seven more methods had the same hole:
    ; coroutine.close, BaseException/OSError/StopIteration.__reduce__, and
    ; __get__ on property, classmethod and staticmethod.  Checking it here
    ; rather than in each of them is what makes the next one impossible --
    ; every builtin method funnels through this function, which is why the
    ; receiver TYPE check above lives here too.
    extern raise_missing_receiver
    jmp raise_missing_receiver      ; rdi = the descriptor; does not return

.bfc_wrong_receiver:
    add rsp, 8
    pop rdx
    pop rsi
    pop rdi
    mov rsi, [rsi]              ; the receiver
    extern raise_descriptor_receiver
    jmp raise_descriptor_receiver   ; rdi = the descriptor; does not return

.bfc_too_few:
    ; "list.append() takes exactly one argument (0 given)".  Both of these
    ; said "function takes at most N arguments" -- with a literal N, and
    ; naming neither the method nor what it was actually given.
    mov rcx, [rdi + PyBuiltinObject.min_args]
    xor r9d, r9d                ; too few
    jmp .bfc_arity
.bfc_too_many:
    mov rcx, [rdi + PyBuiltinObject.max_args]
    mov r9d, 1
.bfc_arity:
    mov rdx, r8                 ; the positional count, which is what is wrong
    dec rcx                     ; self counts in neither number
    dec rdx
    mov rsi, rdx
    mov rdx, rcx
    mov rcx, r9                 ; which way it was wrong
    extern raise_builtin_arity
    jmp raise_builtin_arity     ; rdi = the descriptor; does not return
END_FUNC builtin_func_call


;; bko_name_in_table(rdi = a NULL-terminated table of C strings) -> eax
;; rbx holds the name being looked for; the caller keeps it there.
global bko_name_in_table
DEF_FUNC bko_name_in_table
    mov r8, rdi
.bnt_loop:
    mov rsi, [r8]
    test rsi, rsi
    jz .bnt_no
    mov rdi, rbx
    xor ecx, ecx
.bnt_cmp:
    mov al, [rdi + rcx]
    mov dl, [rsi + rcx]
    cmp al, dl
    jne .bnt_next
    test al, al
    jz .bnt_yes
    inc rcx
    jmp .bnt_cmp
.bnt_next:
    add r8, 8
    jmp .bnt_loop
.bnt_yes:
    mov eax, 1
    leave
    ret
.bnt_no:
    xor eax, eax
    leave
    ret
END_FUNC bko_name_in_table

;; bko_name_is(rdi = a C string) -> eax = 1 when it is the name in rbx
global bko_name_is
DEF_FUNC bko_name_is
    mov rsi, rdi
    xor ecx, ecx
.bni_cmp:
    mov al, [rbx + rcx]
    mov dl, [rsi + rcx]
    cmp al, dl
    jne .bni_no
    test al, al
    jz .bni_yes
    inc rcx
    jmp .bni_cmp
.bni_yes:
    mov eax, 1
    leave
    ret
.bni_no:
    xor eax, eax
    leave
    ret
END_FUNC bko_name_is

;; bko_type_in_table(rdi = a NULL-terminated table of type pointers,
;;                   rsi = a type) -> eax = 1 when it is in the table
global bko_type_in_table
DEF_FUNC bko_type_in_table
.bti_loop:
    mov rax, [rdi]
    test rax, rax
    jz .bti_no
    cmp rax, rsi
    je .bti_yes
    add rdi, 8
    jmp .bti_loop
.bti_yes:
    mov eax, 1
    leave
    ret
.bti_no:
    xor eax, eax
    leave
    ret
END_FUNC bko_type_in_table

section .rodata
%macro BKO_NAME 1
    %%s: db %1, 0
    section .data
    dq %%s
    section .rodata
%endmacro

section .data
align 8
global bko_wrapper_names
bko_wrapper_names:
section .rodata
BKO_NAME "__abs__"
BKO_NAME "__add__"
BKO_NAME "__and__"
BKO_NAME "__bool__"
BKO_NAME "__call__"
BKO_NAME "__delattr__"
BKO_NAME "__delitem__"
BKO_NAME "__divmod__"
BKO_NAME "__eq__"
BKO_NAME "__float__"
BKO_NAME "__floordiv__"
BKO_NAME "__ge__"
BKO_NAME "__get__"
BKO_NAME "__getattribute__"
BKO_NAME "__gt__"
BKO_NAME "__hash__"
BKO_NAME "__iadd__"
BKO_NAME "__iand__"
BKO_NAME "__imul__"
BKO_NAME "__index__"
BKO_NAME "__init__"
BKO_NAME "__int__"
BKO_NAME "__invert__"
BKO_NAME "__ior__"
BKO_NAME "__isub__"
BKO_NAME "__iter__"
BKO_NAME "__ixor__"
BKO_NAME "__le__"
BKO_NAME "__len__"
BKO_NAME "__lshift__"
BKO_NAME "__lt__"
BKO_NAME "__mod__"
BKO_NAME "__mul__"
BKO_NAME "__ne__"
BKO_NAME "__neg__"
BKO_NAME "__next__"
BKO_NAME "__or__"
BKO_NAME "__pos__"
BKO_NAME "__pow__"
BKO_NAME "__radd__"
BKO_NAME "__rand__"
BKO_NAME "__rdivmod__"
BKO_NAME "__repr__"
BKO_NAME "__rfloordiv__"
BKO_NAME "__rlshift__"
BKO_NAME "__rmod__"
BKO_NAME "__rmul__"
BKO_NAME "__ror__"
BKO_NAME "__rpow__"
BKO_NAME "__rrshift__"
BKO_NAME "__rshift__"
BKO_NAME "__rsub__"
BKO_NAME "__rtruediv__"
BKO_NAME "__rxor__"
BKO_NAME "__setattr__"
BKO_NAME "__setitem__"
BKO_NAME "__str__"
BKO_NAME "__sub__"
BKO_NAME "__truediv__"
BKO_NAME "__xor__"
section .data
    dq 0

section .rodata
global bko_contains_name
bko_contains_name: db "__contains__", 0
global bko_getitem_name
bko_getitem_name:  db "__getitem__", 0

; The types whose __contains__ and __getitem__ CPython builds from a real
; method rather than from a slot.  Everything else answers both from a slot.
section .data
align 8
global bko_contains_methods
bko_contains_methods:
    dq dict_type
    dq set_type
    dq frozenset_type
    dq 0
global bko_getitem_methods
bko_getitem_methods:
    dq dict_type
    dq list_type
    dq 0
section .text
extern dict_type
extern set_type
extern frozenset_type
extern list_type

section .rodata
global builtin_func_repr_unknown_str
builtin_func_repr_unknown_str: db "<built-in function>", 0
global bfr_function_open
bfr_function_open: db "<built-in function ", 0
global bfr_on_type_open
bfr_on_type_open:  db "<built-in method ", 0
global bfr_of_type_object
bfr_of_type_object: db " of type object", 0
global bfr_method_open
bfr_method_open:   db "<method '", 0
global bfr_wrapper_open
bfr_wrapper_open:  db "<slot wrapper '", 0
global bfr_of
bfr_of:            db "' of '", 0
global bfr_objects
bfr_objects:       db "' objects>", 0
global bfr_close
bfr_close:         db ">", 0
section .text

;; ============================================================================
;; print_sink_resolve() -> rax = the object sys.stdout names, OWNED, or 0
;;
;; Read per call, not cached: `sys.stdout = buf` is how doctest, pdb,
;; unittest -b and contextlib.redirect_stdout all capture output, and the
;; startup snapshot in sys_stdout_obj does not follow an assignment.  0 when
;; sys is not up yet (during startup) or when sys.stdout is None, both of
;; which mean "produce nothing", as CPython's print does.
;; ============================================================================
PSR_SINK  equ 8
PSR_NAME  equ 16
PSR_FRAME equ 16            ; 0 pushes, 16-aligned
DEF_FUNC_LOCAL print_sink_resolve, PSR_FRAME
    extern sys_module_obj
    mov rax, [rel sys_module_obj]
    test rax, rax
    jz .psr_none
    mov [rbp - PSR_SINK], rax
    CSTRING rdi, "stdout"
    extern str_from_cstr_heap
    call str_from_cstr_heap
    mov [rbp - PSR_NAME], rax
    mov rdi, [rbp - PSR_SINK]
    mov rsi, rax
    extern obj_getattr_opt
    call obj_getattr_opt
    mov [rbp - PSR_SINK], rax   ; the sink, owned
    mov rdi, [rbp - PSR_NAME]
    call obj_decref             ; the name
    mov rax, [rbp - PSR_SINK]
    test rax, rax
    jz .psr_none
    ; obj_getattr_opt hands back a VALUE, and a reference, and the caller KEEPS
    ; it.  Giving it back and holding a borrowed one was wrong: "sys.stdout is
    ; reachable from sys the whole time" stops being true the moment user code
    ; reassigns it, and print resolves the sink BEFORE converting its
    ; arguments -- so a __str__ that does `sys.stdout = other` dropped the last
    ; reference to the sink and print then wrote through freed memory.
    ; CPython is safe here because PyFile_WriteObject fetches the bound
    ; `write` before it calls PyObject_Str.
    ;
    ; Only None means "no stream".  Anything ELSE, immediate or not, goes
    ; through to the write attempt, which is what names the type: CPython
    ; answers `sys.stdout = 5; print(x)` with "'int' object has no attribute
    ; 'write'", where producing nothing silently loses the output.
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .psr_is_none
    leave
    ret
.psr_is_none:
    ; None is not a stream, and the reference is ours to drop.
    mov rdi, rax
    DECREF_V rdi, rcx
.psr_none:
    xor eax, eax
    leave
    ret
END_FUNC print_sink_resolve

;; ============================================================================
;; print_sink_write(rdi = sink, rsi = buf, rdx = len) -> rax = 0 ok, 1 raised
;;
;; The three startup streams are the assembly file_type and keep their own
;; buffer, so they are written through fileobj_emit and the ordering against
;; everything else that writes them is preserved.  Anything else is an
;; ordinary object and is asked for its `write` -- which is all print()
;; requires of a file, and all it has ever required in CPython.
;; ============================================================================
PSW_SINK  equ 8
PSW_BUF   equ 16
PSW_LEN   equ 24
PSW_STR   equ 32
PSW_NAME  equ 40            ; the attribute name, in a slot rather than pushed:
                            ; a lone push around a call misaligns it, and lint
                            ; counts only the pushes in a prologue
PSW_FRAME equ 56            ; + 1 push = 64, 16-aligned
DEF_FUNC_LOCAL print_sink_write, PSW_FRAME
    push rbx
    test rdi, rdi
    jz .psw_ok                  ; nothing to write to: produce nothing
    test rdx, rdx
    jz .psw_ok                  ; nothing to write
    mov [rbp - PSW_SINK], rdi
    mov [rbp - PSW_BUF], rsi
    mov [rbp - PSW_LEN], rdx

    ; file= takes any Value, so an int or a float gets here too; asking it for
    ; ob_type would read the number.  It has no `write` either way, and
    ; raise_no_attribute names a Value's type correctly.
    V_TEST_PTR rdi, rax
    ja .psw_not_object

    extern file_type
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel file_type]
    cmp rax, rcx
    jne .psw_object

    ; A closed stream is refused HERE and not inside fileobj_emit: that helper
    ; is also the route write_fd takes when it recognises sys.stdout, which is
    ; how a traceback reaches the terminal, and an error report must not raise.
    ; Without this, `sys.stdout.close(); print(...)` appended to the closed
    ; object's buffer and the failure surfaced at exit as "Exception ignored in
    ; <stdout>: OSError: [Errno 9] Bad file descriptor" -- or, if the fd had
    ; been reused by then, as text written into an unrelated file.
    extern fileobj_check_open
    call fileobj_check_open     ; raises ValueError and does not return
    mov rdi, [rbp - PSW_SINK]
    mov rsi, [rbp - PSW_BUF]
    mov rdx, [rbp - PSW_LEN]
    extern fileobj_emit
    call fileobj_emit
    test rax, rax
    jns .psw_ok
    ; The one hole print had.  A start-up stream IS a file_type, so the DEFAULT
    ; case took this arm -- and it threw the write's result away, which is why
    ; `apython x.py | head` exited 0 with the tail of its output silently gone.
    ; The .psw_object arm below has propagated all along.
    ;
    ; Set rather than raise: print holds a str() of the current argument and the
    ; sink across this, and .print_sink_failed is what releases them.
    neg eax
    mov edi, eax
    xor esi, esi
    extern set_oserror
    call set_oserror
    jmp .psw_raised

.psw_object:
    ; The text becomes a str, because that is what write() takes.
    mov rdi, [rbp - PSW_BUF]
    mov rsi, [rbp - PSW_LEN]
    extern str_new_heap
    call str_new_heap
    test rax, rax
    jz .psw_raised
    mov [rbp - PSW_STR], rax

    CSTRING rdi, "write"
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, [rbp - PSW_SINK]
    mov rsi, rbx
    call obj_getattr_opt
    mov [rbp - PSW_NAME], rax
    mov rdi, rbx
    call obj_decref             ; the name
    mov rbx, [rbp - PSW_NAME]   ; rbx = the bound write, a Value, or 0
    test rbx, rbx
    jz .psw_no_write

    sub rsp, 16
    mov rax, [rbp - PSW_STR]
    mov [rsp], rax
    mov rdi, rbx
    mov rsi, rsp
    mov edx, 1
    extern obj_call_n
    call obj_call_n
    add rsp, 16
    push rax
    push rax
    mov rdi, rbx
    DECREF_V rdi, rcx           ; the bound write, which is a Value
    mov rdi, [rbp - PSW_STR]
    call obj_decref             ; the text, which is always a str
    pop rax
    pop rax
    test rax, rax
    jz .psw_raised
    ; The result is discarded, as CPython discards write()'s return.
    DECREF_V rax, rcx
    jmp .psw_ok

.psw_no_write:
    ; CPython's message, and it is the one a caller catches: a file= that is
    ; not a file says so by name rather than by silently writing nowhere.
    ; Unless the LOOKUP raised -- obj_getattr_opt answers 0 for that too, and
    ; reporting a `write` property that raised as a missing `write` loses the
    ; exception the program actually has to see.
    mov rdi, [rbp - PSW_STR]
    call obj_decref
    cmp qword [gs:ThreadState.current_exception], 0
    jne .psw_raised
.psw_not_object:
    CSTRING rdi, "write"
    call str_from_cstr_heap
    mov rsi, rax
    mov rdi, [rbp - PSW_SINK]
    xor edx, edx                ; a get, not a set
    extern raise_no_attribute
    call raise_no_attribute
    ; does not return

.psw_raised:
    mov eax, 1
    pop rbx
    leave
    ret
.psw_ok:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC print_sink_write

;; ============================================================================
;; print_sink_flush(rdi = sink) -> rax = 0 ok, 1 raised
;;
;; What flush=True asks of the sink.  A startup stream is drained directly;
;; anything else is asked for its `flush` -- and, once asked, a sink without
;; one is an error.  CPython requires only `write` of a file, but flush=True
;; is `PyObject_CallMethodNoArgs(file, &_Py_ID(flush))` with its result tested,
;; so `print(x, file=write_only, flush=True)` raises AttributeError there.
;; Treating a missing flush as a flush that had already happened made this the
;; one place a print could fail silently.
;; ============================================================================
PSF_SINK  equ 8
PSF_NAME  equ 16            ; a slot, not a push: see PSW_NAME above
PSF_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC_LOCAL print_sink_flush, PSF_FRAME
    push rbx
    test rdi, rdi
    jz .psf_ok
    V_TEST_PTR rdi, rax
    ja .psf_ok                  ; not an object: print_sink_write said so
    mov [rbp - PSF_SINK], rdi

    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel file_type]
    cmp rax, rcx
    jne .psf_object
    extern fileobj_drain
    call fileobj_drain
    test rax, rax
    jns .psf_ok
    neg eax
    mov edi, eax
    xor esi, esi
    extern set_oserror
    call set_oserror
    jmp .psf_failed

.psf_object:
    CSTRING rdi, "flush"
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, [rbp - PSF_SINK]
    mov rsi, rbx
    call obj_getattr_opt
    mov [rbp - PSF_NAME], rax
    mov rdi, rbx
    call obj_decref             ; the name
    mov rbx, [rbp - PSF_NAME]
    test rbx, rbx
    jz .psf_no_flush

    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    call obj_call_n
    push rax
    push rax
    mov rdi, rbx
    DECREF_V rdi, rcx           ; a Value, as obj_getattr_opt answers
    pop rax
    pop rax
    test rax, rax
    jz .psf_failed
    DECREF_V rax, rcx
.psf_ok:
    xor eax, eax
    pop rbx
    leave
    ret

.psf_no_flush:
    ; Missing, or the lookup raised -- the same 0 for both, so ask.
    cmp qword [gs:ThreadState.current_exception], 0
    jne .psf_failed
    CSTRING rdi, "flush"
    call str_from_cstr_heap
    mov rsi, rax
    mov rdi, [rbp - PSF_SINK]
    xor edx, edx                ; a get, not a set
    extern raise_no_attribute
    call raise_no_attribute
    ; does not return

.psf_failed:
    mov eax, 1
    pop rbx
    leave
    ret
END_FUNC print_sink_flush

; PRINT_DROP_SINK -- release the sink when print resolved it itself.  Used at
; each of builtin_print's three exits; clobbers rdi and rcx, which none of
; them has anything live in.
%macro PRINT_DROP_SINK 0
    cmp qword [rbp - PR_OWNSINK], 0
    je %%done
    mov qword [rbp - PR_OWNSINK], 0
    mov rdi, [rbp - PR_SINK]
    DECREF_V rdi, rcx
%%done:
%endmacro

;; ============================================================================
;; builtin_print(PyObject **args, int64_t nargs) -> PyObject*
;; Print each arg separated by spaces, followed by newline
;; Buffered: builds output in stack buffer, single fwrite() at end
;; ============================================================================
; Print frame layout
PR_SEP       equ 8     ; sep: a str, or 0 for the default " "
PR_END       equ 24    ; end: a str, or 0 for the default "\n"
PR_SINK      equ 40    ; where the text goes: an object, or 0 for "sys.stdout"
PR_FLUSH     equ 48    ; the flush= keyword, once it means something
PR_OWNSINK   equ 56    ; 1 when PR_SINK is a reference of ours to release:
                       ; print_sink_resolve hands one over, and `file=` does
                       ; not -- that one is borrowed from the argument array
; math_bind_kw_named's out slots, one per name in pr_kwnames and in that
; order, so at ascending addresses
PR_KW_SEP    equ 96
PR_KW_END    equ 88
PR_KW_FILE   equ 80
PR_KW_FLUSH  equ 72
PR_FRAME     equ 4200            ; + 5 pushes = 4240, 16-aligned; the 4096-byte
                                 ; buffer sits below PR_KW_SEP

extern ap_strcmp
extern math_bind_kw_named
extern obj_is_true
extern rbt_append_cstr
extern rbt_typename


DEF_FUNC builtin_print, PR_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi                ; args array
    mov r12, rsi                ; nargs
    xor r13d, r13d              ; r13 = current arg index
    xor r15d, r15d              ; r15 = buffer write offset

    ; Initialize defaults
    mov qword [rbp - PR_SEP], 0       ; NULL = default " "
    mov qword [rbp - PR_END], 0       ; NULL = default "\n"
    mov qword [rbp - PR_SINK], 0      ; 0 = "whatever sys.stdout names"
    mov qword [rbp - PR_OWNSINK], 0
    mov qword [rbp - PR_FLUSH], 0

    ; Check for keyword arguments; none is the fast path
    cmp qword [gs:ThreadState.kw_names_pending], 0
    je .print_no_kw

    ; sep, end, file and flush, and nothing else: an unknown keyword is
    ; CPython's "'x' is an invalid keyword argument for print()", where it
    ; used to be skipped without a word.
    xor eax, eax
    mov [rbp - PR_KW_SEP], rax
    mov [rbp - PR_KW_END], rax
    mov [rbp - PR_KW_FILE], rax
    mov [rbp - PR_KW_FLUSH], rax
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rel pr_kwnames]
    lea rcx, [rbp - PR_KW_SEP]
    lea r8, [rel pr_kw_fn]
    call math_bind_kw_named
    mov r12, rax                ; r12 = n_pos

    ; sep and end: None or a str (a subclass too), checked before anything
    ; is written, as CPython does.  None is the default, which is the 0 the
    ; slot already holds.
    mov rdi, [rbp - PR_KW_SEP]
    CSTRING rsi, "sep"
    call print_str_or_none
    mov [rbp - PR_SEP], rax
    mov rdi, [rbp - PR_KW_END]
    CSTRING rsi, "end"
    call print_str_or_none
    mov [rbp - PR_END], rax

    ; It was accepted and ignored, which cost nothing while stdout was
    ; unbuffered and costs the whole point of the keyword now that it is not.
    mov rdi, [rbp - PR_KW_FLUSH]
    test rdi, rdi
    jz .print_kw_file
    call obj_is_true
    mov [rbp - PR_FLUSH], rax

.print_kw_file:
    ; file kwarg: the OBJECT, kept as it is.  Reading PyFileObject.file_fd off
    ; whatever pointer arrived meant a StringIO wrote to whatever its second
    ; word happened to hold, and a non-pointer was dropped without a word.
    ; None means sys.stdout, which is the 0 the slot already holds.
    mov rax, [rbp - PR_KW_FILE]
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .print_no_kw
    mov [rbp - PR_SINK], rax

.print_no_kw:
    ; No file=, or file=None: whatever sys.stdout names RIGHT NOW.  Resolved
    ; here rather than at start-up, because reassigning sys.stdout is how
    ; every capture in the standard library works.
    cmp qword [rbp - PR_SINK], 0
    jne .print_have_sink
    call print_sink_resolve
    mov [rbp - PR_SINK], rax
    mov qword [rbp - PR_OWNSINK], 1
.print_have_sink:

align 16
.print_loop:
    cmp r13, r12
    jge .print_flush

    ; Get string representation: obj_str(args[i]) with tag
    mov rax, r13
    shl rax, 3                  ; one Value per slot
    mov rdi, [rbx + rax]       ; arg Value
    call obj_str
    ; obj_str returns (rax=payload, edx=tag)
    mov r14, rax                ; r14 = result payload
    mov r9, rdx                 ; r9 = result tag

    test r9d, r9d
    jz .print_str_failed        ; obj_str raised; see below

    ; Heap string: get length from ob_size
    mov rcx, [r14 + PyStrObject.ob_size]

    ; Check if it fits in buffer (need room for data + possible space)
    lea rax, [r15 + rcx + 2]   ; +2 for space and newline
    cmp rax, 4096
    jae .flush_and_write_direct

    ; Copy string data into buffer
    lea rdi, [rbp - PR_FRAME + r15] ; dest = buf + offset
    lea rsi, [r14 + PyStrObject.data]  ; src = str data
    mov rdx, rcx                ; len
    ; Inline small copy (most strings are short)
    test rcx, rcx
    jz .copy_done
    call ap_memcpy
.copy_done:
    add r15, [r14 + PyStrObject.ob_size]

    ; DECREF the string representation (known TAG_PTR heap string;
    ; r9 tag may have been clobbered by ap_memcpy call above)
    mov rdi, r14
    call obj_decref

.skip_arg:
    ; Append separator if not the last arg
    inc r13
    cmp r13, r12
    jge .print_flush

    ; Check if custom sep was provided
    cmp qword [rbp - PR_SEP], 0
    jne .print_custom_sep

    ; Default: single space
    mov byte [rbp - PR_FRAME + r15], ' '
    inc r15
    jmp .print_loop

.print_custom_sep:
    ; Custom sep: a str, validated when the keyword was bound
    mov rax, [rbp - PR_SEP]
    mov rcx, [rax + PyStrObject.ob_size]
    ; The per-argument copy checks the 4096-byte buffer; this one did not, so
    ; print(..., sep="X"*5000) wrote past the frame over the return address.
    lea rdx, [r15 + rcx + 2]
    cmp rdx, 4096
    jae .print_sep_direct
    ; Copy sep bytes into buffer
    lea rdi, [rbp - PR_FRAME + r15]
    lea rsi, [rax + PyStrObject.data]
    mov rdx, rcx
    test rcx, rcx
    jz .print_sep_done
    push rcx
    call ap_memcpy
    pop rcx
.print_sep_done:
    add r15, rcx
    jmp .print_loop

.print_sep_direct:
    ; Flush what is buffered, then write the separator straight out.
    test r15, r15
    jz .print_sep_write
    mov rdi, [rbp - PR_SINK]
    lea rsi, [rbp - PR_FRAME]
    mov rdx, r15
    call print_sink_write
    test eax, eax
    jnz .print_sink_failed
    xor r15d, r15d
.print_sep_write:
    mov rax, [rbp - PR_SEP]
    mov rdi, [rbp - PR_SINK]
    lea rsi, [rax + PyStrObject.data]
    mov rdx, [rax + PyStrObject.ob_size]
    call print_sink_write
    test eax, eax
    jnz .print_sink_failed
    jmp .print_loop

.flush_and_write_direct:
    ; Buffer full - flush what we have, then write this string directly
    ; First flush buffer
    test r15, r15
    jz .write_direct
    mov rdi, [rbp - PR_SINK]
    lea rsi, [rbp - PR_FRAME]      ; buf
    mov rdx, r15                ; len
    call print_sink_write
    test eax, eax
    jnz .print_sink_failed_held
    xor r15d, r15d              ; reset offset

.write_direct:
    ; Write this string directly
    mov rdi, [rbp - PR_SINK]
    lea rsi, [r14 + PyStrObject.data]
    mov rdx, [r14 + PyStrObject.ob_size]  ; len
    call print_sink_write
    test eax, eax
    jnz .print_sink_failed_held

    ; DECREF the string representation (known TAG_PTR heap string;
    ; r9 tag was clobbered by sys_write calls above)
    mov rdi, r14
    call obj_decref
    jmp .skip_arg

.print_sink_failed_held:
    ; As .print_sink_failed, but with the str() of the current argument still
    ; held in r14.
    mov rdi, r14
    call obj_decref
.print_sink_failed:
    ; write() raised, or the sink has none.  Whatever was already handed over
    ; stays handed over, as CPython's per-argument writes do, and the
    ; exception is the result.
    PRINT_DROP_SINK
    xor eax, eax
    xor edx, edx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.print_str_failed:
    ; str() on an argument raised.  Skipping the argument left the exception
    ; pending and printed the rest of the line anyway, so it surfaced at some
    ; later instruction rather than at the print() -- or, with nothing else to
    ; carry it, at the end of the program.
    ;
    ; CPython writes each argument as it reaches it, so whatever came before
    ; this one is already out; flush that much and propagate.
    test r15, r15
    jz .psf_return
    mov rdi, [rbp - PR_SINK]
    lea rsi, [rbp - PR_FRAME]
    mov rdx, r15
    call print_sink_write
.psf_return:
    PRINT_DROP_SINK
    xor eax, eax
    xor edx, edx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.print_flush:
    ; Append end string (default: "\n")
    cmp qword [rbp - PR_END], 0
    jne .print_custom_end

    ; Default: newline
    mov byte [rbp - PR_FRAME + r15], 10
    inc r15
    jmp .print_do_flush

.print_custom_end:
    ; A str, validated when the keyword was bound
    mov rax, [rbp - PR_END]

    ; Custom end string, bounded the same way
    mov rcx, [rax + PyStrObject.ob_size]
    lea rdx, [r15 + rcx + 2]
    cmp rdx, 4096
    jae .print_end_direct
    lea rdi, [rbp - PR_FRAME + r15]
    lea rsi, [rax + PyStrObject.data]
    mov rdx, rcx
    test rcx, rcx
    jz .print_end_copy_done
    push rcx
    call ap_memcpy
    pop rcx
.print_end_copy_done:
    add r15, rcx
    jmp .print_do_flush

.print_end_direct:
    test r15, r15
    jz .print_end_write
    mov rdi, [rbp - PR_SINK]
    lea rsi, [rbp - PR_FRAME]
    mov rdx, r15
    call print_sink_write
    test eax, eax
    jnz .print_sink_failed
    xor r15d, r15d
.print_end_write:
    mov rax, [rbp - PR_END]
    mov rdi, [rbp - PR_SINK]
    lea rsi, [rax + PyStrObject.data]
    mov rdx, [rax + PyStrObject.ob_size]
    call print_sink_write
    test eax, eax
    jnz .print_sink_failed
    jmp .print_do_flush

.print_do_flush:
    ; Single write for the whole line
    mov rdi, [rbp - PR_SINK]
    lea rsi, [rbp - PR_FRAME]      ; buf
    mov rdx, r15                ; len
    call print_sink_write
    test eax, eax
    jnz .print_sink_failed

    cmp qword [rbp - PR_FLUSH], 0
    je .print_no_flush
    mov rdi, [rbp - PR_SINK]
    call print_sink_flush
    test eax, eax
    jnz .print_sink_failed
.print_no_flush:
    PRINT_DROP_SINK

    ; Return None (with INCREF)
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC builtin_print

;; ============================================================================
;; print_str_or_none(rdi = the keyword's Value or 0, rsi = its name, a C
;;                   string) -> rax = the str, or 0 for "not given or None"
;; Anything else raises CPython's "sep must be None or a string, not int".
;; ============================================================================
PSN_ARG   equ 8
PSN_NAME  equ 16
PSN_BUF   equ 256           ; three appends of at most 80 bytes
PSN_FRAME equ 256           ; + 0 pushes = 256, 16-aligned
DEF_FUNC_LOCAL print_str_or_none, PSN_FRAME
    xor eax, eax
    test rdi, rdi
    jz .psn_ret                 ; not given
    lea rcx, [rel none_singleton]
    cmp rdi, rcx
    je .psn_ret                 ; None: the default
    V_TEST_PTR rdi, rcx
    ja .psn_bad
    mov rcx, [rdi + PyObject.ob_type]
    REQUIRE_STR_TYPE rcx, rdx, .psn_bad
    mov rax, rdi
.psn_ret:
    leave
    ret
.psn_bad:
    mov [rbp - PSN_ARG], rdi
    mov [rbp - PSN_NAME], rsi
    lea rdi, [rbp - PSN_BUF]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, " must be None or a string, not "
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - PSN_ARG]
    call rbt_typename
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - PSN_BUF]
    call raise_exception
END_FUNC print_str_or_none

; The keywords print() takes, for math_bind_kw_named
section .rodata
pr_kw_sep:   db "sep", 0
pr_kw_end:   db "end", 0
pr_kw_file:  db "file", 0
pr_kw_flush: db "flush", 0
pr_kw_fn:    db "print", 0
section .data
align 8
pr_kwnames:  dq pr_kw_sep, pr_kw_end, pr_kw_file, pr_kw_flush, 0
section .text

;; ============================================================================
;; builtin_len(PyObject **args, int64_t nargs) -> rax = Value
;; Returns len() of the first argument.  Reads ob_size for a variable-size
;; builtin, and falls back to the sequence and mapping length slots.
;; ============================================================================
LEN_EXC   equ 8
LEN_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC builtin_len, LEN_FRAME
    push rbx

    ; Check nargs == 1
    cmp rsi, 1
    jne .len_error

    mov rbx, [rdi]              ; rbx = args[0]
    V_TEST_PTR rbx, rax
    ja .len_type_error

    ; Check if the object has a mapping mp_length
    mov rax, [rbx + PyObject.ob_type]
    test rax, rax
    jz .len_error

    ; Try tp_as_mapping->mp_length first
    mov rcx, [rax + PyTypeObject.tp_as_mapping]
    test rcx, rcx
    jz .try_sequence
    mov rcx, [rcx + PyMappingMethods.mp_length]
    test rcx, rcx
    jz .try_sequence
    mov rdi, rbx
    call rcx
    jmp .make_int

.try_sequence:
    ; Try tp_as_sequence->sq_length
    mov rax, [rbx + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_as_sequence]
    test rcx, rcx
    jz .try_dunder_len
    mov rcx, [rcx + PySequenceMethods.sq_length]
    test rcx, rcx
    jz .try_dunder_len
    mov rdi, rbx
    call rcx
    jmp .make_int

.try_dunder_len:
    ; Try __len__ dunder on heaptype
    mov rax, [rbx + PyObject.ob_type]
    mov rdx, [rax + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .len_type_error

    extern dunder_len
    extern dunder_call_1
    mov rdi, rbx
    DUNDER_EXC_SAVE [rbp - LEN_EXC]
    lea rsi, [rel dunder_len]
    call dunder_call_1
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx
    jz .no_dunder_len

    ; __len__ returned a result — extract integer value
    push rdx                ; save tag for SmallInt check
    push rax                ; save result for DECREF
    ; Check if SmallInt (tag == TAG_SMALLINT)
    cmp qword [rsp + 8], TAG_SMALLINT
    je .len_smallint
    ; Heap int — read value (assume fits in 64 bits)
    extern int_to_i64
    mov rdi, rax
    call int_to_i64
    pop rdi                 ; DECREF the int result
    add rsp, 8              ; discard saved tag
    push rax                ; save extracted value
    call obj_decref
    pop rax
    jmp .make_int

.len_smallint:
    ; SmallInt: payload IS the int64 value, no DECREF needed
    pop rax                 ; restore payload
    add rsp, 8              ; discard saved tag
    jmp .make_int

.no_dunder_len:
    ; A NULL from dunder_call_1 means either "no __len__ on this type" or
    ; "__len__ raised"; only the first is a fallback.
    DUNDER_RAISED [rbp - LEN_EXC], .len_failed

    ; There is no last-resort ob_size read here any more.  Every real
    ; container reaches len() through sq_length, mp_length or __len__; the
    ; fallback only caught things that have no length at all, and read +16 --
    ; which for an iterator is it_seq, so len(reversed([1,2,3])) returned a
    ; heap address.
    jmp .len_type_error

.make_int:
    ; rax = length; create an int object
    mov rdi, rax
    call int_from_i64
    ; int_from_i64 returns (rax=payload, edx=tag) — preserve edx

    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.len_failed:
    RET_NULL
    pop rbx
    leave
    ret

.len_error:
    CSTRING rdx, " given)"
    CSTRING rdi, "len() takes exactly one argument ("
    extern raise_type_error_counted
    jmp raise_type_error_counted

.len_type_error:
    mov rsi, rbx                ; args[0], live throughout
    CSTRING rdi, `object of type '\x01' has no len()`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
END_FUNC builtin_len

;; ============================================================================
;; range_arg_value(rdi = an argument Value) -> rax = an int Value, owned
;;
;; What a range bound is: an int, or anything with __index__, kept AS an
;; object.  The bounds used to go through obj_as_index_clamped, which is an
;; int64 and saturates -- so `range(1 << 1000)` was range(0, 2**63 - 1),
;; where CPython's is an ordinary range over an ordinary int.  Clamping was
;; not a choice either: _collections_abc builds one at import to name the
;; type its iterator has, so refusing it takes the standard library with it.
;;
;; A plain int is handed back as it stands, with a reference taken.  Anything
;; else goes through __index__, whose result is already owned.
;; ============================================================================
RAV_ARG   equ 8
RAV_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL range_arg_value, RAV_FRAME
    mov [rbp - RAV_ARG], rdi
    V_IS_INT rdi, rax
    jae .rav_keep
    V_TEST_PTR rdi, rax
    ja .rav_index               ; a float: __index__ will refuse it by name
    test rdi, rdi
    jz .rav_index
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    jne .rav_index
.rav_keep:
    mov rdi, [rbp - RAV_ARG]
    INCREF_V rdi, rax
    mov rax, rdi
    leave
    ret
.rav_index:
    ; obj_as_index refuses everything that is not an index, by name, and
    ; unwraps an int subclass; its int64 is discarded and the OBJECT taken.
    ; A bound wider than an int64 has no int64 to check, so the refusal has
    ; to come from the type rather than from the width -- which is what
    ; nb_index answers.
    mov rdi, [rbp - RAV_ARG]
    V_UNPACK rdi, rdx
    extern obj_as_index_object
    call obj_as_index_object
    leave
    ret
END_FUNC range_arg_value

;; ============================================================================
;; builtin_range(PyObject **args, int64_t nargs) -> rax = Value
;; range(stop) or range(start, stop) or range(start, stop, step)
;; ============================================================================
DEF_FUNC builtin_range, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    mov rbx, rdi               ; args
    mov r12, rsi               ; nargs

    cmp r12, 1
    je .range_1
    cmp r12, 2
    je .range_2
    cmp r12, 3
    je .range_3

    RAISE exc_TypeError_type, "range expected 1 to 3 arguments"

.range_1:
    ; range(stop): start=0, stop=args[0], step=1
    mov rdi, [rbx]             ; args[0]
    call range_arg_value       ; an int Value, owned; raises otherwise
    mov rsi, rax
    xor edi, edi
    V_PACK_I64 rdi, rdx        ; start = 0
    mov rdx, V_INT(1)           ; step = 1
    call range_new_v
    jmp .range_done

.range_2:
    ; range(start, stop): step=1
    mov rdi, [rbx]             ; args[0]
    call range_arg_value
    mov r13, rax               ; start
    mov rdi, [rbx + 8]         ; args[1]
    call range_arg_value
    mov rsi, rax               ; stop
    mov rdi, r13               ; start
    mov rdx, V_INT(1)           ; step = 1
    call range_new_v
    jmp .range_done

.range_3:
    ; range(start, stop, step)
    mov rdi, [rbx]             ; args[0]
    call range_arg_value
    push rax                   ; start
    mov rdi, [rbx + 8]         ; args[1]
    call range_arg_value
    push rax                   ; stop
    mov rdi, [rbx + 16]        ; args[2]
    call range_arg_value
    mov rdx, rax               ; step
    ; A zero step makes range_obj_sq_length divide by zero and makes
    ; range_iter_next advance by nothing, so len(range(0,5,0)) was SIGFPE
    ; and `for i in range(0,5,0)` hung.
    xor ecx, ecx
    V_PACK_I64 rcx, r8
    cmp rdx, rcx
    je .range_zero_step
    pop rsi                    ; stop
    pop rdi                    ; start
    call range_new_v
    jmp .range_done

.range_zero_step:
    RAISE exc_ValueError_type, "range() arg 3 must not be zero"

.range_done:
    pop r13
    pop r12
    pop rbx
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC builtin_range

;; ============================================================================
;; builtin_repr(PyObject **args, int64_t nargs) -> rax = Value
;; repr(obj)
;; ============================================================================
DEF_FUNC builtin_repr

    cmp rsi, 1
    jne .repr_error

    mov rdi, [rdi]             ; args[0]
    call obj_repr
    ; rdx = tag from obj_repr
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.repr_error:
    CSTRING rdx, " given)"
    CSTRING rdi, "repr() takes exactly one argument ("
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_repr

;; ============================================================================
;; builtin_bool(PyObject **args, int64_t nargs) -> PyObject*
;; bool()    -> False
;; bool(x)   -> True if x is truthy, False otherwise
;; ============================================================================
DEF_FUNC builtin_bool

    test rsi, rsi
    je .bool_no_args
    cmp rsi, 1
    jne .bool_error

    ; bool(x) - test truthiness
    mov rdi, [rdi]             ; args[0]
    extern obj_is_true
    call obj_is_true           ; eax = 0 or 1
    test eax, eax
    jz .bool_ret_false
    RET_TRUE
    leave
    ret
.bool_ret_false:
    RET_FALSE
    leave
    ret

.bool_no_args:
    ; bool() -> False
    RET_FALSE
    leave
    ret

.bool_error:
    CSTRING rdi, "bool expected at most 1 argument, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_bool

;; ============================================================================
;; builtin_float(PyObject **args, int64_t nargs) -> PyObject*
;; float()    -> 0.0
;; float(x)   -> convert x to float (int, float, or string)
;; ============================================================================
global builtin_float


extern float_str_clean
BF_START  equ 8              ; the string strtod was handed
BF_ENDPTR equ 16            ; where strtod stopped
BF_OBJ    equ 24            ; the str object itself, for the error message
BF_XLAT   equ 32            ; a Unicode-to-ASCII copy of it, or 0
BF_XLEN   equ 40            ; and the length of what is being parsed
BF_ARG    equ 48            ; the object being converted, across the nb_float call
BF_RET    equ 56            ; and what its __float__ answered with
; CPython names BOTH classes in "Wrong.__float__ returned non-float (type
; int)" and the raiser takes one, so the receiver's name is baked into the
; template here and the raiser fills in the other.  Derived rather than
; hand-picked, so growing the scalars above cannot walk into it.
BF_TMPLLEN equ 320
BF_TMPL   equ 64 + BF_TMPLLEN
BF_FRAME  equ BF_TMPL       ; + 0 pushes = 384, 16-aligned
DEF_FUNC builtin_float, BF_FRAME

    test rsi, rsi
    je .float_no_args
    cmp rsi, 1
    jne .float_error

    ; float(x) - convert x
    mov rdi, [rdi]             ; args[0]
    V_UNPACK rdi, rsi

    ; TAG_FLOAT fast-path: already a float, return as-is
    cmp esi, TAG_FLOAT
    je .float_passthrough

    ; TAG_PTR: check for string
    cmp esi, TAG_PTR
    jne .float_numeric          ; non-pointer tag → numeric conversion

    ; Check if it's a string
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .float_from_str
    ; bytes and bytearray parse as numeric strings in CPython, and were
    ; refused outright here: float(b"1.5") was a TypeError.
    extern bytes_type
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .float_from_bytes
    extern bytearray_type
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .float_from_bytearray

    ; A class defining __float__ now carries nb_float; float_to_f64 below
    ; knows nothing about it and returned 0.0 for such an object.
    mov rcx, [rax + PyTypeObject.tp_as_number]
    test rcx, rcx
    jz .float_numeric
    mov rcx, [rcx + PyNumberMethods.nb_float]
    test rcx, rcx
    jz .float_numeric
    mov [rbp - BF_ARG], rdi     ; the call clobbers rdi, and both exits want it
    call rcx                    ; nb_float returns a Value, or 0 if it raised
    test rax, rax
    jz .float_dunder_raised
    mov rdi, rax
    V_UNPACK rdi, rdx
    cmp edx, TAG_FLOAT
    jne .float_dunder_wrong     ; it answered, but not with a float
    mov rax, rdi
    mov edx, TAG_FLOAT
    leave
    ret

.float_dunder_raised:
    ; A NULL is "it raised" and nothing else.  Untested, it fell through to
    ; the generic path -- which reads ob_type off rdi, and rdi was the NULL's
    ; own payload, so the exception became a SIGSEGV.
    xor eax, eax
    xor edx, edx
    leave
    ret

.float_dunder_wrong:
    ; Falling through to the generic path was worse than wrong: rdi held the
    ; unpacked PAYLOAD of whatever __float__ returned rather than the object,
    ; so `def __float__(self): return 1` had binop_is_number read ob_type off
    ; address 1.
    ;
    ; CPython names BOTH classes here -- "Wrong.__float__ returned non-float
    ; (type int)" -- so the receiver's name goes into a template and the
    ; raiser fills in the other.
    mov [rbp - BF_RET], rax
    call .float_recv_prefix     ; rax = where to keep writing in BF_TMPL

    ; A strict subclass of float is ACCEPTED, and deprecated: CPython returns
    ; the exact float and warns.  __int__ already does this for a subclass of
    ; int; this is the same rule one type over.
    mov rdi, [rbp - BF_RET]
    V_TEST_PTR rdi, rcx
    ja .float_wrong_msg
    test rdi, rdi
    jz .float_wrong_msg
    mov rcx, [rdi + PyObject.ob_type]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_FLOAT_SUBCLASS
    jz .float_wrong_msg

    mov rdi, rax
    CSTRING rsi, `__float__ returned non-float (type \x01).  The ability to return an instance of a strict subclass of float is deprecated, and may be removed in a future version of Python.`
    call .float_append
    lea rdi, [rbp - BF_TMPL]
    mov rsi, [rbp - BF_RET]
    mov rsi, [rsi + PyObject.ob_type]
    extern type_name_message
    call type_name_message
    mov rdi, rax
    extern deprecation_warn
    call deprecation_warn
    test eax, eax
    jz .float_dunder_warn_raised
    ; ...and the value comes back as an EXACT float, as CPython's does.
    mov rdi, [rbp - BF_RET]
    mov rax, [rdi + PyFloatObject.value]
    push rax
    push rax                    ; a pair, so the call stays 16-byte aligned
    mov rsi, TAG_PTR
    DECREF_VAL rdi, rsi
    pop rax
    pop rax
    mov edx, TAG_FLOAT
    leave
    ret

.float_dunder_warn_raised:
    mov rdi, [rbp - BF_RET]
    mov rsi, TAG_PTR
    DECREF_VAL rdi, rsi
    xor eax, eax
    xor edx, edx
    leave
    ret

.float_wrong_msg:
    mov rdi, rax
    CSTRING rsi, `__float__ returned non-float (type \x01)`
    call .float_append
    lea rdi, [rbp - BF_TMPL]
    mov rsi, [rbp - BF_RET]
    extern raise_type_error_with_name
    call raise_type_error_with_name

;; Writes "<the receiver's type name>." into BF_TMPL and answers the NUL it
;; left behind, so the caller appends the rest of the message there.  A type
;; with no name, or a name too long for the buffer, leaves the prefix out --
;; which is the wording int() and index() use anyway.
.float_recv_prefix:
    lea rax, [rbp - BF_TMPL]
    mov byte [rax], 0
    push rax
    push rax                    ; a pair, so the calls stay 16-byte aligned
    mov rdi, [rbp - BF_ARG]
    extern value_type
    call value_type
    test rax, rax
    jz .frp_done
    mov rsi, [rax + PyTypeObject.tp_name]
    test rsi, rsi
    jz .frp_done
    mov rdi, rsi
    extern ap_strlen
    call ap_strlen
    cmp rax, 64
    jae .frp_done
    mov rdi, [rbp - BF_ARG]
    call value_type
    mov rsi, [rax + PyTypeObject.tp_name]
    lea rdi, [rbp - BF_TMPL]
    call .float_append
    mov rdi, rax
    CSTRING rsi, "."
    call .float_append
    add rsp, 16
    ret
.frp_done:
    pop rax
    pop rax
    ret

;; .float_append(rdi = where to write, rsi = a C string) -> rax = the NUL
;;
;; rbt_append_cstr caps at eighty characters, which is right for the type
;; names it was written for and silently cuts the deprecation text in half --
;; that is where "...return an instance of a " ended.  This one is bounded by
;; the end of BF_TMPL instead.
.float_append:
    lea rcx, [rbp - BF_TMPL]
    add rcx, BF_TMPLLEN - 1     ; the last byte the NUL may occupy
    mov rax, rdi
.fa_loop:
    cmp rax, rcx
    jae .fa_done
    mov dl, [rsi]
    test dl, dl
    jz .fa_done
    mov [rax], dl
    inc rax
    inc rsi
    jmp .fa_loop
.fa_done:
    mov byte [rax], 0
    ret

.float_numeric:
    ; float_to_f64 answers 0.0 for anything it does not recognise, so
    ; float(None) and float([1]) quietly produced 0.0.
    push rdi
    push rsi
    extern binop_is_number
    call binop_is_number
    pop rsi
    pop rdi
    test eax, eax
    jz .float_bad_type

    extern float_to_f64
    call float_to_f64          ; xmm0 = double
    extern float_from_f64
    call float_from_f64        ; rax = double bits, edx = TAG_FLOAT

    leave
    ret

.float_bad_type:
    V_PACK rdi, rsi
    mov rsi, rdi
    CSTRING rdi, `float() argument must be a string or a real number, not '\x01'`
    extern raise_type_error_with_name
    call raise_type_error_with_name

.float_passthrough:
    mov rax, rdi
    mov edx, TAG_FLOAT
    leave
    ret

.float_from_bytes:
    mov [rbp - BF_OBJ], rdi
    mov qword [rbp - BF_XLAT], 0
    mov rax, [rdi + PyBytesObject.ob_size]
    mov [rbp - BF_XLEN], rax
    lea rdi, [rdi + PyBytesObject.data]
    jmp .float_str_have_data

.float_from_bytearray:
    mov [rbp - BF_OBJ], rdi
    mov qword [rbp - BF_XLAT], 0
    mov rax, [rdi + PyByteArrayObject.ob_size]
    mov [rbp - BF_XLEN], rax
    mov rdi, [rdi + PyByteArrayObject.ob_bytes]
    jmp .float_str_have_data

.float_from_str:
    ; rdi = PyStrObject*. Parse string → double via strtod.
    mov [rbp - BF_OBJ], rdi
    ; A Unicode decimal digit is a digit and a Unicode space is a space, as
    ; CPython's _PyUnicode_TransformDecimalAndSpaceToASCII has it.
    mov qword [rbp - BF_XLAT], 0
    extern str_decimal_ascii
    call str_decimal_ascii
    test rax, rax
    jz .float_str_ascii
    mov [rbp - BF_XLAT], rax
    mov [rbp - BF_XLEN], rdx
    mov rdi, rax
    jmp .float_str_have_data
.float_str_ascii:
    mov rdi, [rbp - BF_OBJ]
    mov rax, [rdi + PyStrObject.ob_size]
    mov [rbp - BF_XLEN], rax
    lea rdi, [rdi + PyStrObject.data]   ; rdi = null-terminated string data
.float_str_have_data:
    mov [rbp - BF_START], rdi                  ; save start ptr

    ; An embedded NUL is not the end of the string, and strtod thinks it is:
    ; float("1\x002") answered 1.0 where CPython raises.
    extern strlen
    call strlen wrt ..plt
    cmp rax, [rbp - BF_XLEN]
    jne .float_str_error

    ; Reject a hex float and strip PEP 515 underscores before strtod sees
    ; either.  A cleaned copy takes over BF_XLAT's ownership, so both exits
    ; free exactly one buffer.
    mov rdi, [rbp - BF_START]
    mov rsi, [rbp - BF_XLEN]
    call float_str_clean
    test rax, rax
    jz .float_str_error
    mov [rbp - BF_START], rax
    test edx, edx
    jz .float_str_cleaned
    mov rdi, [rbp - BF_XLAT]
    mov [rbp - BF_XLAT], rax
    test rdi, rdi
    jz .float_str_cleaned
    call ap_free
.float_str_cleaned:
    mov rdi, [rbp - BF_START]

    ; Call strtod(str, &endptr)
    extern strtod
    lea rsi, [rbp - BF_ENDPTR]                ; &endptr at [rbp - BF_ENDPTR]
    call strtod wrt ..plt
    ; xmm0 = parsed value, [rbp - BF_ENDPTR] = endptr

    ; Check endptr > start (parsed something)
    mov rax, [rbp - BF_ENDPTR]                ; endptr
    cmp rax, [rbp - BF_START]                 ; compare with start
    je .float_str_error                ; nothing parsed → error

    ; Skip trailing whitespace after parsed portion
.float_skip_ws:
    movzx ecx, byte [rax]
    cmp cl, ' '
    je .float_ws_next
    cmp cl, 9                          ; tab
    je .float_ws_next
    cmp cl, 10                         ; newline
    je .float_ws_next
    cmp cl, 13                         ; carriage return
    je .float_ws_next
    jmp .float_ws_done
.float_ws_next:
    inc rax
    jmp .float_skip_ws
.float_ws_done:
    cmp byte [rax], 0
    jne .float_str_error               ; trailing garbage → ValueError

    ; xmm0 still holds the strtod result
    mov rdi, [rbp - BF_XLAT]
    test rdi, rdi
    jz .float_str_kept
    movq rax, xmm0
    push rax
    extern ap_free
    call ap_free
    pop rax
    movq xmm0, rax
.float_str_kept:
    call float_from_f64                ; rax = double bits, edx = TAG_FLOAT
    leave
    ret

.float_str_error:
    mov rdi, [rbp - BF_XLAT]
    test rdi, rdi
    jz .float_str_error_msg
    mov qword [rbp - BF_XLAT], 0
    call ap_free
.float_str_error_msg:
    ; CPython names the string it could not convert, and int() here already
    ; does; float's message had lost it.
    mov rsi, [rbp - BF_OBJ]
    CSTRING rdi, "could not convert string to float: "
    extern raise_value_error_with_repr
    call raise_value_error_with_repr

.float_no_args:
    ; float() -> 0.0
    xorpd xmm0, xmm0
    call float_from_f64
    leave
    ret

.float_error:
    CSTRING rdi, "float expected at most 1 argument, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_float


;; Helper: add_builtin_type(dict, name_cstr, type_obj, tp_call_fn)
;; Registers a type object directly in builtins (for isinstance to work).
;; Sets type_obj.tp_call = tp_call_fn so the type is callable.
;; rdi=dict, rsi=name_cstr, rdx=type_obj, rcx=tp_call_fn
;; ============================================================================
;; add_builtin_str(dict, const char *key, const char *value)
;; Bind a plain string constant in the builtins dict.
;; ============================================================================
ABS_DICT equ 8
ABS_KEY  equ 16
ABS_FRAME equ 32            ; + 2 pushes = 48, 16-aligned
DEF_FUNC_LOCAL add_builtin_str, ABS_FRAME
    push rbx
    push r12
    mov [rbp - ABS_DICT], rdi
    mov [rbp - ABS_KEY], rsi
    mov rdi, rdx
    call str_from_cstr_heap
    mov r12, rax
    mov rdi, [rbp - ABS_KEY]
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, [rbp - ABS_DICT]
    mov rsi, rbx
    mov rdx, r12
    call dict_set
    mov rdi, rbx
    call obj_decref
    mov rdi, r12
    call obj_decref
    pop r12
    pop rbx
    leave
    ret
END_FUNC add_builtin_str

DEF_FUNC_LOCAL add_builtin_type
    push rbx
    push r12

    mov rbx, rdi               ; dict
    mov r12, rdx               ; type_obj

    ; Install the constructor in tp_new.  It must NOT go in tp_call: tp_call
    ; on a type governs whether that type's INSTANCES are callable.
    mov [r12 + PyTypeObject.tp_new], rcx

    ; Create key string (heap — used as dict key, then DECREFed)
    push r12
    mov rdi, rsi
    call str_from_cstr_heap
    mov rcx, rax               ; key str
    V_PACK rdx, rcx

    ; dict_set(dict, key, type_obj)
    mov rdi, rbx
    mov rsi, rcx
    pop rdx                    ; type_obj
    push rcx                   ; save key for DECREF
    call dict_set

    ; DECREF key
    pop rdi
    call obj_decref

    pop r12
    pop rbx
    leave
    ret
END_FUNC add_builtin_type

;; ============================================================================
;; builtins_init() -> PyDictObject*
;; Create and populate the builtins dictionary
;; ============================================================================
DEF_FUNC builtins_init, 8            ; 1 push, so rsp is 16-aligned
    push rbx

    ; Initialize iterator types (patches list/tuple tp_iter)
    call init_iter_types

    ; BaseException gets a tp_dict, so that super().__init__ from a user
    ; exception subclass reaches something that sets .args.
    extern exc_install_methods
    call exc_install_methods
    ; split, subgroup and derive, on BaseExceptionGroup -- which ExceptionGroup
    ; and every user subclass reach through the MRO walk in eg_getattr.
    extern eg_install_methods
    call eg_install_methods

    ; Create the builtins dict
    call dict_new
    mov rbx, rax                ; rbx = builtins dict

    ; Store globally for __build_class__ to access
    mov [rel builtins_dict_global], rbx

    ; builtins.__name__ is "builtins", as it is in CPython.  A class body's
    ; prologue does LOAD_NAME __name__ to fill in __module__, and with a bare
    ; dict for globals -- which is what exec(src, {}) gives it -- the lookup
    ; falls all the way through to here.
    mov rdi, rbx
    lea rsi, [rel bi_dunder_name]
    lea rdx, [rel bi_builtins_name]
    call add_builtin_str

    ; Create __build_class__ wrapper and store globally
    lea rdi, [rel builtin___build_class__]
    lea rsi, [rel bi_name_build_class]
    call builtin_func_new
    mov [rel build_class_obj], rax

    ; Register __build_class__ in builtins dict
    mov rdi, rbx
    lea rsi, [rel bi_name_build_class]
    lea rdx, [rel builtin___build_class__]
    call dict_add_builtin_func

    ; Add builtins using helper
    mov rdi, rbx
    lea rsi, [rel bi_name_print]
    lea rdx, [rel builtin_print]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_len]
    lea rdx, [rel builtin_len]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_range]
    extern range_obj_type
    extern range_type_call
    lea rdx, [rel range_obj_type]
    lea rcx, [rel range_type_call]
    call add_builtin_type

    mov rdi, rbx
    lea rsi, [rel bi_name_type]
    lea rdx, [rel type_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_isinstance]
    lea rdx, [rel builtin_isinstance]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_issubclass]
    lea rdx, [rel builtin_issubclass]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_repr]
    lea rdx, [rel builtin_repr]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_float]
    lea rdx, [rel float_type]
    lea rcx, [rel float_type_call]
    call add_builtin_type

    mov rdi, rbx
    lea rsi, [rel bi_name_complex]
    extern complex_type
    extern complex_type_call
    lea rdx, [rel complex_type]
    lea rcx, [rel complex_type_call]
    call add_builtin_type

    mov rdi, rbx
    lea rsi, [rel bi_name_bool]
    lea rdx, [rel bool_type]
    lea rcx, [rel bool_type_call]
    call add_builtin_type

    extern object_type
    extern object_type_call
    mov rdi, rbx
    lea rsi, [rel bi_name_object]
    lea rdx, [rel object_type]
    lea rcx, [rel object_type_call]
    call add_builtin_type

    ; Register new builtins (from builtins_extra.asm)
    mov rdi, rbx
    lea rsi, [rel bi_name_abs]
    lea rdx, [rel builtin_abs]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_divmod]
    lea rdx, [rel builtin_divmod]
    call dict_add_builtin_func

    ; Register int as the int_type object (not a function wrapper)
    ; so isinstance(42, int) works correctly
    mov rdi, rbx
    lea rsi, [rel bi_name_int]
    lea rdx, [rel int_type]
    lea rcx, [rel int_type_call]
    call add_builtin_type

    mov rdi, rbx
    lea rsi, [rel bi_name_str]
    lea rdx, [rel str_type]
    lea rcx, [rel str_type_call]
    call add_builtin_type

    mov rdi, rbx
    lea rsi, [rel bi_name_ord]
    lea rdx, [rel builtin_ord]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_chr]
    lea rdx, [rel builtin_chr]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_hex]
    lea rdx, [rel builtin_hex]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_id]
    lea rdx, [rel builtin_id]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_hash]
    lea rdx, [rel builtin_hash_fn]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_callable]
    lea rdx, [rel builtin_callable]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_iter]
    lea rdx, [rel builtin_iter_fn]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_next]
    lea rdx, [rel builtin_next_fn]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_any]
    lea rdx, [rel builtin_any]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_all]
    lea rdx, [rel builtin_all]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_sum]
    lea rdx, [rel builtin_sum]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_min]
    lea rdx, [rel builtin_min]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_max]
    lea rdx, [rel builtin_max]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_getattr]
    lea rdx, [rel builtin_getattr]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_hasattr]
    lea rdx, [rel builtin_hasattr]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_setattr]
    lea rdx, [rel builtin_setattr]
    call dict_add_builtin_func

    ; Register iterator builtins (from itertools.asm)
    extern enumerate_iter_type
    extern enumerate_type_call
    mov rdi, rbx
    lea rsi, [rel bi_name_enumerate]
    lea rdx, [rel enumerate_iter_type]
    lea rcx, [rel enumerate_type_call]
    call add_builtin_type

    mov rdi, rbx
    lea rsi, [rel bi_name_zip]
    extern zip_iter_type
    extern zip_type_call
    lea rdx, [rel zip_iter_type]
    lea rcx, [rel zip_type_call]
    call add_builtin_type

    mov rdi, rbx
    lea rsi, [rel bi_name_map]
    extern map_iter_type
    extern map_type_call
    lea rdx, [rel map_iter_type]
    lea rcx, [rel map_type_call]
    call add_builtin_type

    mov rdi, rbx
    lea rsi, [rel bi_name_filter]
    extern filter_iter_type
    extern filter_type_call
    lea rdx, [rel filter_iter_type]
    lea rcx, [rel filter_type_call]
    call add_builtin_type

    mov rdi, rbx
    lea rsi, [rel bi_name_reversed]
    extern reversed_iter_type
    extern reversed_type_call
    lea rdx, [rel reversed_iter_type]
    lea rcx, [rel reversed_type_call]
    call add_builtin_type

    mov rdi, rbx
    lea rsi, [rel bi_name_sorted]
    lea rdx, [rel builtin_sorted]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_globals]
    lea rdx, [rel builtin_globals]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_locals]
    lea rdx, [rel builtin_locals]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_dir]
    lea rdx, [rel builtin_dir]
    call dict_add_builtin_func

    mov rdi, rbx
    lea rsi, [rel bi_name_breakpoint]
    lea rdx, [rel builtin_breakpoint]
    call dict_add_builtin_func

    ; Register super type as builtin (LOAD_SUPER_ATTR needs it loadable)
    mov rdi, rbx
    lea rsi, [rel bi_name_super]
    lea rdx, [rel super_type]
    call add_exc_type_builtin

    ; Register descriptor types as builtins
    mov rdi, rbx
    lea rsi, [rel bi_name_staticmethod]
    lea rdx, [rel staticmethod_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_classmethod]
    lea rdx, [rel classmethod_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_property]
    lea rdx, [rel property_type]
    call add_exc_type_builtin

    ; Register NotImplemented singleton as builtin constant
    extern notimpl_singleton
    mov rdi, rbx
    lea rsi, [rel bi_name_NotImplemented]
    lea rdx, [rel notimpl_singleton]
    call add_exc_type_builtin

    ; Register Ellipsis singleton as builtin constant
    extern ellipsis_singleton
    mov rdi, rbx
    lea rsi, [rel bi_name_Ellipsis]
    lea rdx, [rel ellipsis_singleton]
    call add_exc_type_builtin

    ; __debug__ is True: there is no -O here, and nothing strips an assert.
    ; CPython makes it a compile-time constant; a builtin answers every read
    ; the same way, and the stdlib does read it -- test_exceptions decorates a
    ; whole class with @unittest.skipUnless(__debug__, ...), which is a
    ; NameError without this.
    mov rdi, rbx
    lea rsi, [rel bi_name_debug]
    lea rdx, [rel bool_true]
    call add_exc_type_builtin

    ; Register exception types as builtins
    mov rdi, rbx
    lea rsi, [rel bi_name_BaseException]
    lea rdx, [rel exc_BaseException_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_Exception]
    lea rdx, [rel exc_Exception_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_TypeError]
    lea rdx, [rel exc_TypeError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_ValueError]
    lea rdx, [rel exc_ValueError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_KeyError]
    lea rdx, [rel exc_KeyError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_IndexError]
    lea rdx, [rel exc_IndexError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_AttributeError]
    lea rdx, [rel exc_AttributeError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_NameError]
    lea rdx, [rel exc_NameError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_UnboundLocalError]
    lea rdx, [rel exc_UnboundLocalError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_RuntimeError]
    lea rdx, [rel exc_RuntimeError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_StopIteration]
    lea rdx, [rel exc_StopIteration_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_ZeroDivisionError]
    lea rdx, [rel exc_ZeroDivisionError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_NotImplementedError]
    lea rdx, [rel exc_NotImplementedError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_OverflowError]
    lea rdx, [rel exc_OverflowError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_AssertionError]
    lea rdx, [rel exc_AssertionError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_OSError]
    lea rdx, [rel exc_OSError_type]
    call add_exc_type_builtin

    ; OSError's own constructor: it parses (errno, strerror, filename, ...),
    ; truncates .args, and remaps to a subclass by errno.  It goes in tp_new,
    ; which exc_type_call consults, and only on OSError itself -- DEF_EXC_TYPE
    ; leaves the slot 0 on the subclasses, which is what CPython wants: the
    ; remapping applies when the type is exactly OSError.
    extern oserror_new
    lea rax, [rel exc_OSError_type]
    lea rcx, [rel oserror_new]
    mov [rax + PyTypeObject.tp_new], rcx

    mov rdi, rbx
    lea rsi, [rel bi_name_FileNotFoundError]
    extern exc_FileNotFoundError_type
    lea rdx, [rel exc_FileNotFoundError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_FileExistsError]
    extern exc_FileExistsError_type
    lea rdx, [rel exc_FileExistsError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_UnicodeTranslateError]
    extern exc_UnicodeTranslateError_type
    lea rdx, [rel exc_UnicodeTranslateError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_IOError]
    extern exc_OSError_type
    lea rdx, [rel exc_OSError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_EnvironmentError]
    extern exc_OSError_type
    lea rdx, [rel exc_OSError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_LookupError]
    lea rdx, [rel exc_LookupError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_ArithmeticError]
    lea rdx, [rel exc_ArithmeticError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_RecursionError]
    lea rdx, [rel exc_RecursionError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_ImportError]
    lea rdx, [rel exc_ImportError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_MemoryError]
    lea rdx, [rel exc_MemoryError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_KeyboardInterrupt]
    lea rdx, [rel exc_KeyboardInterrupt_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_SystemExit]
    lea rdx, [rel exc_SystemExit_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_UnicodeError]
    lea rdx, [rel exc_UnicodeError_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_Warning]
    lea rdx, [rel exc_Warning_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_DeprecationWarning]
    lea rdx, [rel exc_DeprecationWarning_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_UserWarning]
    lea rdx, [rel exc_UserWarning_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_BaseExceptionGroup]
    lea rdx, [rel exc_BaseExceptionGroup_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_ExceptionGroup]
    lea rdx, [rel exc_ExceptionGroup_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_StopAsyncIteration]
    lea rdx, [rel exc_StopAsyncIteration_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_TimeoutError]
    lea rdx, [rel exc_TimeoutError_type]
    call add_exc_type_builtin

    extern exc_GeneratorExit_type
    mov rdi, rbx
    lea rsi, [rel bi_name_GeneratorExit]
    lea rdx, [rel exc_GeneratorExit_type]
    call add_exc_type_builtin

    extern exc_ModuleNotFoundError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_ModuleNotFoundError]
    lea rdx, [rel exc_ModuleNotFoundError_type]
    call add_exc_type_builtin

    extern exc_SyntaxError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_SyntaxError]
    lea rdx, [rel exc_SyntaxError_type]
    call add_exc_type_builtin

    extern exc_IndentationError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_IndentationError]
    lea rdx, [rel exc_IndentationError_type]
    call add_exc_type_builtin

    extern exc_TabError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_TabError]
    lea rdx, [rel exc_TabError_type]
    call add_exc_type_builtin

    extern exc_EOFError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_EOFError]
    lea rdx, [rel exc_EOFError_type]
    call add_exc_type_builtin

    extern exc_UnicodeDecodeError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_UnicodeDecodeError]
    lea rdx, [rel exc_UnicodeDecodeError_type]
    call add_exc_type_builtin

    extern exc_UnicodeEncodeError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_UnicodeEncodeError]
    lea rdx, [rel exc_UnicodeEncodeError_type]
    call add_exc_type_builtin

    extern exc_ConnectionError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_ConnectionError]
    lea rdx, [rel exc_ConnectionError_type]
    call add_exc_type_builtin

    extern exc_ConnectionResetError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_ConnectionResetError]
    lea rdx, [rel exc_ConnectionResetError_type]
    call add_exc_type_builtin

    extern exc_ConnectionRefusedError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_ConnectionRefusedError]
    lea rdx, [rel exc_ConnectionRefusedError_type]
    call add_exc_type_builtin

    extern exc_ConnectionAbortedError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_ConnectionAbortedError]
    lea rdx, [rel exc_ConnectionAbortedError_type]
    call add_exc_type_builtin

    extern exc_BrokenPipeError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_BrokenPipeError]
    lea rdx, [rel exc_BrokenPipeError_type]
    call add_exc_type_builtin

    extern exc_PermissionError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_PermissionError]
    lea rdx, [rel exc_PermissionError_type]
    call add_exc_type_builtin

    extern exc_IsADirectoryError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_IsADirectoryError]
    lea rdx, [rel exc_IsADirectoryError_type]
    call add_exc_type_builtin

    extern exc_NotADirectoryError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_NotADirectoryError]
    lea rdx, [rel exc_NotADirectoryError_type]
    call add_exc_type_builtin

    extern exc_ProcessLookupError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_ProcessLookupError]
    lea rdx, [rel exc_ProcessLookupError_type]
    call add_exc_type_builtin

    extern exc_ChildProcessError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_ChildProcessError]
    lea rdx, [rel exc_ChildProcessError_type]
    call add_exc_type_builtin

    extern exc_BlockingIOError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_BlockingIOError]
    lea rdx, [rel exc_BlockingIOError_type]
    call add_exc_type_builtin

    extern exc_InterruptedError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_InterruptedError]
    lea rdx, [rel exc_InterruptedError_type]
    call add_exc_type_builtin

    extern exc_FloatingPointError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_FloatingPointError]
    lea rdx, [rel exc_FloatingPointError_type]
    call add_exc_type_builtin

    extern exc_BufferError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_BufferError]
    lea rdx, [rel exc_BufferError_type]
    call add_exc_type_builtin

    extern exc_ReferenceError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_ReferenceError]
    lea rdx, [rel exc_ReferenceError_type]
    call add_exc_type_builtin

    extern exc_SystemError_type
    mov rdi, rbx
    lea rsi, [rel bi_name_SystemError]
    lea rdx, [rel exc_SystemError_type]
    call add_exc_type_builtin

    extern exc_RuntimeWarning_type
    mov rdi, rbx
    lea rsi, [rel bi_name_RuntimeWarning]
    lea rdx, [rel exc_RuntimeWarning_type]
    call add_exc_type_builtin

    extern exc_FutureWarning_type
    mov rdi, rbx
    lea rsi, [rel bi_name_FutureWarning]
    lea rdx, [rel exc_FutureWarning_type]
    call add_exc_type_builtin

    extern exc_ImportWarning_type
    mov rdi, rbx
    lea rsi, [rel bi_name_ImportWarning]
    lea rdx, [rel exc_ImportWarning_type]
    call add_exc_type_builtin

    extern exc_UnicodeWarning_type
    mov rdi, rbx
    lea rsi, [rel bi_name_UnicodeWarning]
    lea rdx, [rel exc_UnicodeWarning_type]
    call add_exc_type_builtin

    extern exc_ResourceWarning_type
    mov rdi, rbx
    lea rsi, [rel bi_name_ResourceWarning]
    lea rdx, [rel exc_ResourceWarning_type]
    call add_exc_type_builtin

    extern exc_BytesWarning_type
    mov rdi, rbx
    lea rsi, [rel bi_name_BytesWarning]
    lea rdx, [rel exc_BytesWarning_type]
    call add_exc_type_builtin

    extern exc_PendingDeprecationWarning_type
    mov rdi, rbx
    lea rsi, [rel bi_name_PendingDeprecationWarning]
    lea rdx, [rel exc_PendingDeprecationWarning_type]
    call add_exc_type_builtin

    extern exc_SyntaxWarning_type
    mov rdi, rbx
    lea rsi, [rel bi_name_SyntaxWarning]
    lea rdx, [rel exc_SyntaxWarning_type]
    call add_exc_type_builtin

    extern exc_EncodingWarning_type
    mov rdi, rbx
    lea rsi, [rel bi_name_EncodingWarning]
    lea rdx, [rel exc_EncodingWarning_type]
    call add_exc_type_builtin

    ; Register data types as builtins
    mov rdi, rbx
    lea rsi, [rel bi_name_list]
    lea rdx, [rel list_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_dict]
    lea rdx, [rel dict_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_tuple]
    lea rdx, [rel tuple_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_set]
    lea rdx, [rel set_type]
    call add_exc_type_builtin

    mov rdi, rbx
    lea rsi, [rel bi_name_bytes]
    lea rdx, [rel bytes_type]
    extern bytes_type_call
    lea rcx, [rel bytes_type_call]
    call add_builtin_type

    mov rdi, rbx
    lea rsi, [rel bi_name_bytearray]
    lea rdx, [rel bytearray_type]
    lea rcx, [rel bytearray_type_call]
    call add_builtin_type

    mov rdi, rbx
    lea rsi, [rel bi_name_memoryview]
    lea rdx, [rel memoryview_type]
    lea rcx, [rel memoryview_type_call]
    call add_builtin_type

    ; eval
    mov rdi, rbx
    lea rsi, [rel bi_name_eval]
    extern builtin_eval_fn
    lea rdx, [rel builtin_eval_fn]
    call dict_add_builtin_func

    ; compile
    mov rdi, rbx
    lea rsi, [rel bi_name_compile]
    extern builtin_compile_fn
    lea rdx, [rel builtin_compile_fn]
    call dict_add_builtin_func

    ; exec
    mov rdi, rbx
    lea rsi, [rel bi_name_exec]
    extern builtin_exec_fn
    lea rdx, [rel builtin_exec_fn]
    call dict_add_builtin_func

    ; round
    mov rdi, rbx
    lea rsi, [rel bi_name_round]
    extern builtin_round_fn
    lea rdx, [rel builtin_round_fn]
    call dict_add_builtin_func

    ; pow
    mov rdi, rbx
    lea rsi, [rel bi_name_pow]
    extern builtin_pow_fn
    lea rdx, [rel builtin_pow_fn]
    call dict_add_builtin_func

    ; input
    mov rdi, rbx
    lea rsi, [rel bi_name_input]
    extern builtin_input_fn
    lea rdx, [rel builtin_input_fn]
    call dict_add_builtin_func

    ; open
    mov rdi, rbx
    lea rsi, [rel bi_name_open]
    extern builtin_open_fn
    lea rdx, [rel builtin_open_fn]
    call dict_add_builtin_func

    ; bin
    mov rdi, rbx
    lea rsi, [rel bi_name_bin]
    extern builtin_bin
    lea rdx, [rel builtin_bin]
    call dict_add_builtin_func

    ; oct
    mov rdi, rbx
    lea rsi, [rel bi_name_oct]
    extern builtin_oct
    lea rdx, [rel builtin_oct]
    call dict_add_builtin_func

    ; ascii
    mov rdi, rbx
    lea rsi, [rel bi_name_ascii]
    extern builtin_ascii_fn
    lea rdx, [rel builtin_ascii_fn]
    call dict_add_builtin_func

    ; format
    mov rdi, rbx
    lea rsi, [rel bi_name_format]
    extern builtin_format_fn
    lea rdx, [rel builtin_format_fn]
    call dict_add_builtin_func

    ; vars
    mov rdi, rbx
    lea rsi, [rel bi_name_vars]
    extern builtin_vars_fn
    lea rdx, [rel builtin_vars_fn]
    call dict_add_builtin_func

    ; delattr
    mov rdi, rbx
    lea rsi, [rel bi_name_delattr]
    extern builtin_delattr_fn
    lea rdx, [rel builtin_delattr_fn]
    call dict_add_builtin_func

    ; aiter
    mov rdi, rbx
    lea rsi, [rel bi_name_aiter]
    extern builtin_aiter_fn
    lea rdx, [rel builtin_aiter_fn]
    call dict_add_builtin_func

    ; anext
    mov rdi, rbx
    lea rsi, [rel bi_name_anext]
    extern builtin_anext_fn
    lea rdx, [rel builtin_anext_fn]
    call dict_add_builtin_func

    ; __import__
    mov rdi, rbx
    lea rsi, [rel bi_name___import__]
    extern builtin_import_fn
    lea rdx, [rel builtin_import_fn]
    call dict_add_builtin_func

    ; slice
    mov rdi, rbx
    lea rsi, [rel bi_name_slice]
    extern slice_type
    extern slice_type_call
    lea rdx, [rel slice_type]
    lea rcx, [rel slice_type_call]
    call add_builtin_type

    ; frozenset
    mov rdi, rbx
    lea rsi, [rel bi_name_frozenset]
    extern frozenset_type
    extern frozenset_type_call
    lea rdx, [rel frozenset_type]
    lea rcx, [rel frozenset_type_call]
    call add_builtin_type

    ; Return builtins dict
    mov rax, rbx

    pop rbx
    leave
    ret
END_FUNC builtins_init

;; ============================================================================
;; add_exc_type_builtin(dict, name_cstr, type_ptr)
;; Register an exception type object in the builtins dict.
;; Types are immortal, so no DECREF needed on the value.
;; rdi=dict, rsi=name_cstr, rdx=type_ptr
;; ============================================================================
DEF_FUNC_LOCAL add_exc_type_builtin
    push rbx
    push r12

    mov rbx, rdi               ; dict
    mov r12, rdx               ; type_ptr

    ; Create key string (heap — used as dict key, then DECREFed)
    mov rdi, rsi
    call str_from_cstr_heap
    push rax                   ; save key

    ; dict_set(dict, key, type_ptr)
    ; INCREF the type (dict_set will INCREF it, types are immortal anyway)
    mov rdi, rbx
    mov rsi, rax               ; key
    mov rdx, r12               ; type object
    call dict_set

    ; DECREF key
    pop rdi
    call obj_decref

    pop r12
    pop rbx
    leave
    ret
END_FUNC add_exc_type_builtin

;; ============================================================================
;; Data section
;; ============================================================================
section .rodata

bi_name_breakpoint:   db "breakpoint", 0
bi_name_print:        db "print", 0
bi_name_len:          db "len", 0
bi_name_range:        db "range", 0
bi_name_type:         db "type", 0
bi_name_isinstance:   db "isinstance", 0
bi_name_issubclass:   db "issubclass", 0
bi_name_repr:         db "repr", 0
bi_name_float:        db "float", 0
bi_name_complex:      db "complex", 0
bi_name_bool:         db "bool", 0
bi_name_object:       db "object", 0
bi_name_build_class:  db "__build_class__", 0

; New builtin names
bi_name_abs:          db "abs", 0
bi_name_int:          db "int", 0
bi_name_str:          db "str", 0
bi_name_ord:          db "ord", 0
bi_name_chr:          db "chr", 0
bi_name_hex:          db "hex", 0
bi_name_id:           db "id", 0
bi_name_hash:         db "hash", 0
bi_name_callable:     db "callable", 0
bi_name_iter:         db "iter", 0
bi_name_next:         db "next", 0
bi_name_any:          db "any", 0
bi_name_all:          db "all", 0
bi_name_sum:          db "sum", 0
bi_name_min:          db "min", 0
bi_name_max:          db "max", 0
bi_name_getattr:      db "getattr", 0
bi_name_hasattr:      db "hasattr", 0
bi_name_setattr:      db "setattr", 0

; Iterator builtin names
bi_name_enumerate:    db "enumerate", 0
bi_name_zip:          db "zip", 0
bi_name_map:          db "map", 0
bi_name_filter:       db "filter", 0
bi_name_reversed:     db "reversed", 0
bi_name_sorted:       db "sorted", 0
bi_name_divmod:       db "divmod", 0
bi_name_globals:      db "globals", 0
bi_name_locals:       db "locals", 0
bi_name_dir:          db "dir", 0
bi_name_eval:         db "eval", 0
bi_dunder_name:       db "__name__", 0
bi_builtins_name:     db "builtins", 0
bi_name_compile:      db "compile", 0
bi_name_exec:         db "exec", 0
bi_name_super:        db "super", 0
bi_name_staticmethod: db "staticmethod", 0
bi_name_classmethod:  db "classmethod", 0
bi_name_property:     db "property", 0
bi_name_NotImplemented: db "NotImplemented", 0
bi_name_Ellipsis:      db "Ellipsis", 0
bi_name_debug:         db "__debug__", 0

; Exception type names
bi_name_BaseException:     db "BaseException", 0
bi_name_Exception:         db "Exception", 0
bi_name_TypeError:         db "TypeError", 0
bi_name_ValueError:        db "ValueError", 0
bi_name_KeyError:          db "KeyError", 0
bi_name_IndexError:        db "IndexError", 0
bi_name_AttributeError:    db "AttributeError", 0
bi_name_NameError:         db "NameError", 0
bi_name_UnboundLocalError: db "UnboundLocalError", 0
bi_name_RuntimeError:      db "RuntimeError", 0
bi_name_StopIteration:     db "StopIteration", 0
bi_name_ZeroDivisionError: db "ZeroDivisionError", 0
bi_name_NotImplementedError: db "NotImplementedError", 0
bi_name_OverflowError:     db "OverflowError", 0
bi_name_AssertionError:    db "AssertionError", 0
bi_name_OSError:           db "OSError", 0
bi_name_FileNotFoundError: db "FileNotFoundError", 0
bi_name_FileExistsError: db "FileExistsError", 0
bi_name_UnicodeTranslateError: db "UnicodeTranslateError", 0
bi_name_IOError: db "IOError", 0
bi_name_EnvironmentError: db "EnvironmentError", 0
bi_name_LookupError:       db "LookupError", 0
bi_name_ArithmeticError:   db "ArithmeticError", 0
bi_name_RecursionError:    db "RecursionError", 0
bi_name_ImportError:       db "ImportError", 0
bi_name_MemoryError:       db "MemoryError", 0
bi_name_KeyboardInterrupt: db "KeyboardInterrupt", 0
bi_name_SystemExit:        db "SystemExit", 0
bi_name_UnicodeError:      db "UnicodeError", 0
bi_name_Warning:           db "Warning", 0
bi_name_DeprecationWarning: db "DeprecationWarning", 0
bi_name_UserWarning:       db "UserWarning", 0
bi_name_BaseExceptionGroup: db "BaseExceptionGroup", 0
bi_name_ExceptionGroup:    db "ExceptionGroup", 0
bi_name_StopAsyncIteration: db "StopAsyncIteration", 0
bi_name_TimeoutError:      db "TimeoutError", 0
bi_name_GeneratorExit:     db "GeneratorExit", 0
bi_name_ModuleNotFoundError: db "ModuleNotFoundError", 0
bi_name_SyntaxError:       db "SyntaxError", 0
bi_name_IndentationError:  db "IndentationError", 0
bi_name_TabError:          db "TabError", 0
bi_name_EOFError:          db "EOFError", 0
bi_name_UnicodeDecodeError: db "UnicodeDecodeError", 0
bi_name_UnicodeEncodeError: db "UnicodeEncodeError", 0
bi_name_ConnectionError:   db "ConnectionError", 0
bi_name_ConnectionResetError: db "ConnectionResetError", 0
bi_name_ConnectionRefusedError: db "ConnectionRefusedError", 0
bi_name_ConnectionAbortedError: db "ConnectionAbortedError", 0
bi_name_BrokenPipeError:   db "BrokenPipeError", 0
bi_name_PermissionError:   db "PermissionError", 0
bi_name_IsADirectoryError: db "IsADirectoryError", 0
bi_name_NotADirectoryError: db "NotADirectoryError", 0
bi_name_ProcessLookupError: db "ProcessLookupError", 0
bi_name_ChildProcessError: db "ChildProcessError", 0
bi_name_BlockingIOError:   db "BlockingIOError", 0
bi_name_InterruptedError:  db "InterruptedError", 0
bi_name_FloatingPointError: db "FloatingPointError", 0
bi_name_BufferError:       db "BufferError", 0
bi_name_ReferenceError:    db "ReferenceError", 0
bi_name_SystemError:       db "SystemError", 0
bi_name_RuntimeWarning:    db "RuntimeWarning", 0
bi_name_FutureWarning:     db "FutureWarning", 0
bi_name_ImportWarning:     db "ImportWarning", 0
bi_name_UnicodeWarning:    db "UnicodeWarning", 0
bi_name_ResourceWarning:   db "ResourceWarning", 0
bi_name_BytesWarning:      db "BytesWarning", 0
bi_name_PendingDeprecationWarning: db "PendingDeprecationWarning", 0
bi_name_SyntaxWarning:     db "SyntaxWarning", 0
bi_name_EncodingWarning:   db "EncodingWarning", 0
bi_name_list:              db "list", 0
bi_name_dict:              db "dict", 0
bi_name_tuple:             db "tuple", 0
bi_name_set:               db "set", 0
bi_name_bytes:             db "bytes", 0
bi_name_bytearray:         db "bytearray", 0
bi_name_memoryview:        db "memoryview", 0
bi_name_round:             db "round", 0
bi_name_pow:               db "pow", 0
bi_name_input:             db "input", 0
bi_name_open:              db "open", 0
bi_name_bin:               db "bin", 0
bi_name_oct:               db "oct", 0
bi_name_ascii:             db "ascii", 0
bi_name_format:            db "format", 0
bi_name_vars:              db "vars", 0
bi_name_delattr:           db "delattr", 0
bi_name_aiter:             db "aiter", 0
bi_name_anext:             db "anext", 0
bi_name___import__:        db "__import__", 0
bi_name_slice:             db "slice", 0
bi_name_frozenset:         db "frozenset", 0

section .data

global builtins_dict_global
builtins_dict_global: dq 0

global build_class_obj
build_class_obj: dq 0

builtin_func_name_str: db "builtin_function_or_method", 0

; Builtin function type object
align 8
global builtin_func_type
builtin_func_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq builtin_func_name_str    ; tp_name
    dq PyBuiltinObject_size     ; tp_basicsize
    dq builtin_func_dealloc     ; tp_dealloc
    dq builtin_func_repr        ; tp_repr
    dq builtin_func_repr        ; tp_str
    dq 0                        ; tp_hash
    dq builtin_func_call        ; tp_call
    dq builtin_func_getattr     ; tp_getattr
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
    dq 0                        ; tp_flags
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

section .bss
global bfg_get_cached
bfg_get_cached: resq 1      ; the shared `__get__` builtin, built once
