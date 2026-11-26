; exc_oserror.asm - what OSError does that no other exception does.
;
; OSError remaps errno to a subclass and uses native fields for formatting
; and reduction. The errno table follows CPython's ADD_ERRNO list.

%include "macros.inc"
%include "object.inc"

; --- objects ---
extern obj_decref
extern obj_dealloc
extern int_from_i64
extern int_to_i64
extern int_is_integer
extern str_from_cstr_heap
extern tuple_new

; --- exceptions ---
extern exc_new
extern exc_OSError_type
extern none_singleton

; --- the subclasses the errno table maps to ---
extern exc_BlockingIOError_type
extern exc_BrokenPipeError_type
extern exc_ChildProcessError_type
extern exc_ConnectionAbortedError_type
extern exc_ConnectionRefusedError_type
extern exc_ConnectionResetError_type
extern exc_FileExistsError_type
extern exc_FileNotFoundError_type
extern exc_IsADirectoryError_type
extern exc_NotADirectoryError_type
extern exc_InterruptedError_type
extern exc_PermissionError_type
extern exc_ProcessLookupError_type
extern exc_TimeoutError_type

; --- libc ---
extern strerror

section .text

;; oserror_str(rdi = exception) -> str, 0 to use BaseException's text,
;; or -1 when conversion raised.
OSF_FRAME equ 8
DEF_FUNC oserror_str, OSF_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov edi, 2
    CSTRING r12, "[Errno %s] %s"
    cmp qword [rbx + PyOSErrorObject.filename], 0
    jne .with_file
    cmp qword [rbx + PyOSErrorObject.errno], 0
    je .fallback
    cmp qword [rbx + PyOSErrorObject.strerror], 0
    je .fallback
    jmp .arguments
.with_file:
    mov edi, 3
    CSTRING r12, "[Errno %s] %s: %r"
    cmp qword [rbx + PyOSErrorObject.filename2], 0
    je .arguments
    mov edi, 4
    CSTRING r12, "[Errno %s] %s: %r -> %r"
.arguments:
    ; Hold all fields in a tuple before a user conversion can mutate them.
    call tuple_new
    mov r13, rax
    mov r8, [rax + PyTupleObject.ob_item]
    mov r9, [rax + PyTupleObject.ob_size]
    xor ecx, ecx
.copy:
    mov rax, [rbx + PyOSErrorObject.errno + rcx*8]
    test rax, rax
    jnz .store
    lea rax, [rel none_singleton]
.store:
    INCREF_V rax, rdx
    mov [r8 + rcx*8], rax
    inc rcx
    cmp rcx, r9
    jb .copy

    mov rdi, r12
    call str_from_cstr_heap
    mov r12, rax
    mov rdi, rax
    mov rsi, r13
    mov ecx, 1                      ; return on a failing conversion
    xor edx, edx                    ; str format
    extern str_mod_impl
    call str_mod_impl               ; err: checked after releasing both args
    mov rbx, rax
    mov rdi, r13
    call obj_decref
    mov rdi, r12
    call obj_decref
    mov rax, rbx
    test rax, rax
    jnz .done
    mov rax, -1
    jmp .done
.fallback:
    xor eax, eax
.done:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC oserror_str

;; oserror_zero_fields(rdi = exception) -> void
;; The OSError extension and the heap subclass slots above it hold Values.
DEF_FUNC_BARE oserror_zero_fields
    mov rcx, [rdi + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_basicsize]
    sub rcx, PyExceptionObject_size
    shr rcx, 3
    add rdi, PyExceptionObject_size
    xor eax, eax
    rep stosq
    ret
END_FUNC oserror_zero_fields

;; oserror_traverse(rdi = exception, r14 = visitor) -> void
DEF_FUNC oserror_traverse
    push rbx
    push r12
    mov rax, [rdi + PyObject.ob_type]
    mov r12, [rax + PyTypeObject.tp_basicsize]
    add r12, rdi
    lea rbx, [rdi + PyExceptionObject_size]
.next:
    cmp rbx, r12
    jae .done
    mov rdi, [rbx]
    VISIT_V rdi, rsi
    add rbx, 8
    jmp .next
.done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC oserror_traverse

;; oserror_clear(rdi = exception) -> void
DEF_FUNC oserror_clear
    push rbx
    push r12
    mov rax, [rdi + PyObject.ob_type]
    mov r12, [rax + PyTypeObject.tp_basicsize]
    add r12, rdi
    lea rbx, [rdi + PyExceptionObject_size]
.next:
    cmp rbx, r12
    jae .done
    mov rdi, [rbx]
    mov qword [rbx], 0
    XDECREF_V rdi, rcx
    add rbx, 8
    jmp .next
.done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC oserror_clear

;; oserror_install_members(rdi = OSError type dict) -> void
OIM_NAME equ 8
OIM_FRAME equ 8
DEF_FUNC oserror_install_members, OIM_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    lea r12, [rel oserror_attr_names]
    mov r13d, PyOSErrorObject.errno
.next:
    mov rdi, [r12]
    test rdi, rdi
    jz .written
    call str_from_cstr_heap
    mov [rbp - OIM_NAME], rax
    mov rdi, r13
    mov rsi, rax
    lea rdx, [rel exc_OSError_type]
    extern member_descr_new
    call member_descr_new
    mov qword [rax + PyMemberDescrObject.md_nullable], 1
    mov rdx, rax
    mov rsi, [rbp - OIM_NAME]
    mov rdi, rbx
    push rax
    push rax
    extern dict_set_str
    call dict_set_str
    pop rdi
    pop rax
    call obj_decref
    add r12, 8
    add r13, 8
    jmp .next
.written:
    lea rdi, [rel oserror_n_written]
    call str_from_cstr_heap
    mov r12, rax
    lea rdi, [rel oserror_written_get]
    lea rsi, [rel oserror_written_set]
    mov rdx, r12
    extern getset_descr_new
    call getset_descr_new
    mov r13, rax
    lea rcx, [rel exc_OSError_type]
    mov [r13 + PyGetSetDescrObject.gs_owner], rcx
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call dict_set_str
    mov rdi, r13
    call obj_decref
    mov rdi, r12
    call obj_decref
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC oserror_install_members

;; oserror_use_init(rdi = type) -> eax = 1 when parsing belongs in __init__
;; A Python __init__ can take unrelated arguments. If __new__ is overridden
;; too, its call to OSError.__new__ supplies the arguments for native parsing.
DEF_FUNC_LOCAL oserror_use_init, 8
    push rbx
    test qword [rdi + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .native_new
    mov rbx, rdi
    extern exc_user_init
    call exc_user_init
    test rax, rax
    jz .native_new
    mov rdi, rbx
    extern exc_user_new
    call exc_user_new
    test rax, rax
    jnz .native_new
    mov eax, 1
    pop rbx
    leave
    ret
.native_new:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC oserror_use_init

;; oserror_new(rdi = type, rsi = args, rdx = nargs) -> fat pair (rax, rdx)
DEF_FUNC oserror_new
    push rdi
    push rsi
    push rdx
    sub rsp, 8
    call oserror_use_init
    add rsp, 8
    pop rdx
    pop rsi
    pop rdi
    test eax, eax
    jz .parse
    xor esi, esi
    xor edx, edx
    call exc_new
    mov edx, TAG_PTR
    leave
    ret
.parse:
    xor ecx, ecx
    call oserror_parse
    leave
    ret
END_FUNC oserror_new

;; oserror_parse(rdi = type, rsi = args, rdx = nargs, rcx = instance or 0)
;;   -> fat pair (instance, TAG_PTR), or (0, 0) with an exception pending
;; A supplied instance is initialized in place and returned borrowed.
ONW_TYPE   equ 8
ONW_ARGS   equ 16
ONW_EFFN   equ 24
ONW_WRITTEN equ 40
ONW_FNAME2 equ 48
ONW_FNAME  equ 56
ONW_STRERR equ 64
ONW_ERRNO  equ 72
ONW_FRAME  equ 80
DEF_FUNC_LOCAL oserror_parse, ONW_FRAME
    push rbx
    push r12
    mov rbx, rcx
    mov [rbp - ONW_TYPE], rdi
    mov [rbp - ONW_ARGS], rsi
    mov [rbp - ONW_EFFN], rdx

    xor eax, eax
    mov [rbp - ONW_WRITTEN], rax
    mov [rbp - ONW_ERRNO], rax
    mov [rbp - ONW_STRERR], rax
    mov [rbp - ONW_FNAME], rax
    mov [rbp - ONW_FNAME2], rax
    cmp rdx, 2
    jl .allocate
    cmp rdx, 5
    jg .allocate

    mov rax, [rsi]
    mov [rbp - ONW_ERRNO], rax
    mov rax, [rsi + 8]
    mov [rbp - ONW_STRERR], rax

    ; Remap before interpreting the third argument. Only exact OSError may
    ; turn into BlockingIOError and treat that argument as a write count.
    lea rcx, [rel exc_OSError_type]
    cmp rdi, rcx
    jne .third
    mov r12, [rbp - ONW_ERRNO]
    mov rdi, r12
    V_UNPACK rdi, rdx
    call int_is_integer
    test eax, eax
    jz .third
    mov rdi, r12
    V_UNPACK rdi, rdx
    extern int_fits_i64
    call int_fits_i64
    test eax, eax
    jz .third
    mov rdi, r12
    V_UNPACK rdi, rdx
    call int_to_i64
    lea rsi, [rel oserror_errnomap]
.find_errno:
    cmp qword [rsi], 0
    je .third
    cmp [rsi], rax
    je .mapped
    add rsi, 16
    jmp .find_errno
.mapped:
    mov rax, [rsi + 8]
    mov [rbp - ONW_TYPE], rax

.third:
    cmp qword [rbp - ONW_EFFN], 3
    jl .allocate
    mov rax, [rbp - ONW_ARGS]
    mov r12, [rax + 16]
    lea rsi, [rel none_singleton]
    cmp r12, rsi
    je .allocate
    lea rcx, [rel exc_BlockingIOError_type]
    cmp [rbp - ONW_TYPE], rcx
    jne .filename
    mov rdi, r12
    call oserror_is_number
    test eax, eax
    jz .filename
    mov rdi, r12
    call oserror_as_written
    test rax, rax
    jz .fail
    mov [rbp - ONW_WRITTEN], rax
    jmp .allocate

.filename:
    mov [rbp - ONW_FNAME], r12
    cmp qword [rbp - ONW_EFFN], 5
    jne .trim
    mov rax, [rbp - ONW_ARGS]
    mov rcx, [rax + 32]         ; args[3] is the Windows-only winerror
    lea rsi, [rel none_singleton]
    cmp rcx, rsi
    je .trim
    mov [rbp - ONW_FNAME2], rcx
.trim:
    mov qword [rbp - ONW_EFFN], 2

.allocate:
    test rbx, rbx
    jnz .args
    mov rdi, [rbp - ONW_TYPE]
    xor esi, esi
    cmp qword [rbp - ONW_EFFN], 0
    je .allocate_new
    mov rax, [rbp - ONW_ARGS]
    mov rsi, [rax]
.allocate_new:
    xor edx, edx
    call exc_new
    mov rbx, rax
    cmp qword [rbp - ONW_EFFN], 1
    jbe .fields                 ; exc_new already supplied the args tuple
.args:
    mov rdi, [rbp - ONW_EFFN]
    call tuple_new
    mov r8, [rax + PyTupleObject.ob_item]
    mov rsi, [rbp - ONW_ARGS]
    xor edx, edx
.copy_args:
    cmp rdx, [rbp - ONW_EFFN]
    jge .install_args
    mov rdi, [rsi + rdx*8]
    INCREF_V rdi, rcx
    mov [r8 + rdx*8], rdi
    inc rdx
    jmp .copy_args
.install_args:
    mov rdi, [rbx + PyExceptionObject.exc_args]
    mov [rbx + PyExceptionObject.exc_args], rax
    XDECREF_V rdi, rcx

.fields:
    xor r12d, r12d
.store_field:
    mov rax, [rbp - ONW_ERRNO + r12]
    test rax, rax
    jnz .install_field
    cmp r12, 16
    jae .next_field            ; absent filenames leave the old fields alone
.install_field:
    INCREF_V rax, rcx
    mov rdi, [rbx + PyOSErrorObject.errno + r12]
    mov [rbx + PyOSErrorObject.errno + r12], rax
    XDECREF_V rdi, rcx
.next_field:
    add r12, 8
    cmp r12, 32
    jb .store_field
    mov rax, [rbp - ONW_WRITTEN]
    test rax, rax
    jz .done
    mov rdi, rbx
    call oserror_install_written
.done:
    mov rax, rbx
    mov edx, TAG_PTR
    jmp .return
.fail:
    xor eax, eax
    xor edx, edx
.return:
    pop r12
    pop rbx
    leave
    ret
END_FUNC oserror_parse

;; oserror_method_new(rdi = args, rsi = total count) -> Value or 0 on error
DEF_FUNC oserror_method_new, 8
    push rbx
    mov rbx, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0
    test rbx, rbx
    jz .positional
    mov rbx, [rbx + PyTupleObject.ob_size]
    sub rsi, rbx
.positional:
    test rsi, rsi
    jz .no_type
    mov rax, [rdi]
    V_TEST_PTR rax, rcx
    ja .not_type
    mov rcx, [rax + PyObject.ob_type]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .not_type
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_OSERROR_SUBCLASS
    jz .not_oserror
    lea rdx, [rsi - 1]
    lea rsi, [rdi + 8]
    mov rdi, rax
    test rbx, rbx
    jz .construct
    push rdi
    sub rsp, 8
    call oserror_use_init
    add rsp, 8
    pop rdi
    test eax, eax
    jnz .deferred
    jmp .no_keywords
.deferred:
    xor esi, esi
    xor edx, edx
    call exc_new
    mov edx, TAG_PTR
    jmp .pack
.construct:
    call oserror_new
.pack:
    V_PACK rax, rdx
    jmp .return
.no_keywords:
    mov rsi, [rdi + PyTypeObject.tp_name]
    xor edi, edi
    extern exc_set_bad_keyword
    call exc_set_bad_keyword
    jmp .failed
.no_type:
    extern exc_TypeError_type
    FAIL exc_TypeError_type, "OSError.__new__(): not enough arguments", .failed
.not_type:
    mov rsi, rax
    CSTRING rdi, `OSError.__new__(X): X is not a type object (\x01)`
    extern set_type_error_with_name
    call set_type_error_with_name
    jmp .failed
.not_oserror:
    mov rsi, rax
    CSTRING rdi, `OSError.__new__(\x01): \x01 is not a subtype of OSError`
    extern set_type_error_with_typename
    call set_type_error_with_typename
.failed:
    xor eax, eax
.return:
    pop rbx
    leave
    ret
END_FUNC oserror_method_new

;; oserror_method_init(rdi = args, rsi = total count) -> None or 0 on error
OMI_ARGS equ 8
OMI_NARGS equ 16
OMI_KW equ 24
OMI_FRAME equ 40
DEF_FUNC oserror_method_init, OMI_FRAME
    push rbx
    mov [rbp - OMI_ARGS], rdi
    mov [rbp - OMI_NARGS], rsi
    mov rax, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov [rbp - OMI_KW], rax
    mov rax, [rdi]
    mov rbx, [rax + PyObject.ob_type]
    mov rdi, rbx
    call oserror_use_init
    test eax, eax
    jz .done
    mov rax, [rbp - OMI_KW]
    test rax, rax
    jz .parse
    cmp qword [rax + PyTupleObject.ob_size], 0
    jnz .no_keywords
.parse:
    mov rdi, rbx
    mov rsi, [rbp - OMI_ARGS]
    mov rcx, [rsi]
    add rsi, 8
    mov rdx, [rbp - OMI_NARGS]
    dec rdx
    call oserror_parse
    test rax, rax
    jz .return
.done:
    LOAD_NONE rax
    jmp .return
.no_keywords:
    mov rsi, [rbx + PyTypeObject.tp_name]
    xor edi, edi
    call exc_set_bad_keyword
    xor eax, eax
.return:
    pop rbx
    leave
    ret
END_FUNC oserror_method_init

;; oserror_is_number(rdi = Value) -> eax = boolean, as in PyNumber_Check
DEF_FUNC_LOCAL oserror_is_number
    extern value_type
    call value_type
    test qword [rax + PyTypeObject.tp_flags], \
        TYPE_FLAG_INT_SUBCLASS | TYPE_FLAG_FLOAT_SUBCLASS | TYPE_FLAG_COMPLEX_SUBCLASS
    jnz .yes
    mov rcx, [rax + PyTypeObject.tp_as_number]
    test rcx, rcx
    jz .no
    mov rax, [rcx + PyNumberMethods.nb_index]
    or rax, [rcx + PyNumberMethods.nb_int]
    or rax, [rcx + PyNumberMethods.nb_float]
    setnz al
    movzx eax, al
    leave
    ret
.yes:
    mov eax, 1
    leave
    ret
.no:
    xor eax, eax
    leave
    ret
END_FUNC oserror_is_number

;; oserror_as_written(rdi = Value) -> owned int Value, or 0 with error pending
OAW_ARG equ 8
OAW_INT equ 16
OAW_RESULT equ 24
OAW_FRAME equ 32
DEF_FUNC_LOCAL oserror_as_written, OAW_FRAME
    mov [rbp - OAW_ARG], rdi
    V_UNPACK rdi, rdx
    extern obj_as_index_object
    call obj_as_index_object
    ERR_NULL .return
    mov [rbp - OAW_INT], rax
    mov rdi, rax
    V_UNPACK rdi, rdx
    call int_is_integer
    test eax, eax
    jz .bad_index
    mov rdi, [rbp - OAW_INT]
    V_UNPACK rdi, rdx
    call int_fits_i64
    test eax, eax
    jz .overflow
    mov rdi, [rbp - OAW_INT]
    V_UNPACK rdi, rdx
    call int_to_i64
    V_PACK_I64 rax, rcx
    mov [rbp - OAW_RESULT], rax
    mov rdi, [rbp - OAW_INT]
    DECREF_V rdi, rcx
    mov rax, [rbp - OAW_RESULT]
.return:
    leave
    ret
.bad_index:
    mov rsi, [rbp - OAW_INT]
    CSTRING rdi, `__index__ returned non-int (type \x01)`
    call set_type_error_with_name
    mov rdi, [rbp - OAW_INT]
    DECREF_V rdi, rcx
    xor eax, eax
    leave
    ret
.overflow:
    mov rdi, [rbp - OAW_INT]
    DECREF_V rdi, rcx
    mov rdi, [rbp - OAW_ARG]
    call value_type
    mov rsi, rax
    CSTRING rdi, `cannot fit '\x01' into an index-sized integer`
    extern type_name_message
    call type_name_message
    mov rsi, rax
    extern exc_ValueError_type, set_exception
    lea rdi, [rel exc_ValueError_type]
    call set_exception
    xor eax, eax
    leave
    ret
END_FUNC oserror_as_written

;; oserror_install_written(rdi = exception, rax = owned count or 0) -> void
DEF_FUNC_LOCAL oserror_install_written
    mov rcx, V_INT(-1)
    cmp rax, rcx
    jne .store
    xor eax, eax
.store:
    mov rcx, [rdi + PyOSErrorObject.written]
    mov [rdi + PyOSErrorObject.written], rax
    XDECREF_V rcx, rdx
    leave
    ret
END_FUNC oserror_install_written

;; oserror_written_get(rdi = exception) -> owned int Value or 0 on error
DEF_FUNC_LOCAL oserror_written_get
    mov rax, [rdi + PyOSErrorObject.written]
    test rax, rax
    jz .unset
    INCREF_V rax, rcx
    leave
    ret
.unset:
    call oserror_written_missing
    mov qword [gs:ThreadState.attr_error_pending], 1
    xor eax, eax
    leave
    ret
END_FUNC oserror_written_get

;; oserror_written_set(rdi = exception, rsi = Value or 0) -> 0 or -1 on error
DEF_FUNC_LOCAL oserror_written_set, 8
    push rbx
    mov rbx, rdi
    test rsi, rsi
    jz .delete
    mov rdi, rsi
    call oserror_as_written
    test rax, rax
    jz .failed
    jmp .install
.delete:
    cmp qword [rbx + PyOSErrorObject.written], 0
    je .unset
    xor eax, eax
.install:
    mov rdi, rbx
    call oserror_install_written
    xor eax, eax
    jmp .return
.unset:
    call oserror_written_missing
.failed:
    mov rax, -1
.return:
    pop rbx
    leave
    ret
END_FUNC oserror_written_set

;; oserror_written_missing() -> 0 with AttributeError pending
DEF_FUNC_BARE oserror_written_missing
    extern exc_AttributeError_type
    lea rdi, [rel exc_AttributeError_type]
    lea rsi, [rel oserror_n_written]
    jmp set_exception
END_FUNC oserror_written_missing

;; oserror_is_field(rdi = attribute name, NUL-terminated) -> eax = boolean
DEF_FUNC oserror_is_field, 16
    push rbx
    push r12
    mov r12, rdi
    lea rbx, [rel oserror_attr_names]
.next:
    mov rsi, [rbx]
    test rsi, rsi
    jz .written
    mov rdi, r12
    extern ap_strcmp
    call ap_strcmp
    test eax, eax
    jz .found
    add rbx, 8
    jmp .next
.found:
    mov eax, 1
    jmp .out
.written:
    mov rdi, r12
    lea rsi, [rel oserror_n_written]
    call ap_strcmp
    test eax, eax
    setz al
    movzx eax, al
.out:
    pop r12
    pop rbx
    leave
    ret
END_FUNC oserror_is_field

;; ============================================================================
;; set_oserror(rdi = errno (positive), rsi = filename PyStrObject* or NULL)
;;   -> rax = 0, with the OSError pending; its body is further down
;;
;; Builds OSError(errno, strerror(errno), filename) and makes it pending, so the
;; subclass remapping and the "[Errno N] ...: 'file'" rendering both apply.
;; strerror comes from libc, whose text is byte-identical to CPython's -- it is
;; the same call CPython makes.
;;
;; The sibling of set_key_error: an exception that needs richer args than
;; the two-argument SET_EXC macro can build.
;; ============================================================================
RO_ARGS  equ 40             ; five Values: errno, strerror, filename,
                            ; winerror, filename2 -- CPython's full form
RO_FRAME equ 48             ; + 0 pushes = 48
;; set_oserror_owned(rdi = errno, rsi = the caller's path Value,
;;                   rdx = a resolved path the caller owns, or 0)
;;   -> rax = 0, always, with the OSError pending
;;
;; The same error, naming the resolved path when there is one and releasing
;; it afterwards.  posix resolves os.PathLike arguments into a new string, and
;; the message has to name that rather than the object that produced it --
;; which means it cannot be released before the exception is built.
ROO_OWNED equ 8
ROO_OWNED2 equ 16           ; the second resolved path, for rename
ROO_FRAME equ 32            ; + 0 pushes = 32

global set_oserror_owned
DEF_FUNC_BARE set_oserror_owned
    xor ecx, ecx                ; no second path
    xor r8d, r8d
    jmp set_oserror_owned2
END_FUNC set_oserror_owned

;; set_oserror_owned2(rdi = errno, rsi = the first path Value,
;;                    rdx = the owned resolved first path or 0,
;;                    rcx = the second path Value,
;;                    r8 = the owned resolved second path or 0)
;;   -> rax = 0, always, with the OSError pending
;;
;; The two-path form, for rename and symlink: CPython reports
;; "'src' -> 'dst'".  Each path is named by its RESOLVED form when
;; posix_path_arg had to build one -- a PathLike argument -- and by the
;; argument itself otherwise.  Both resolved paths are released after the
;; exception is built and before the raise, which is the whole reason this
;; and its sibling exist.
global set_oserror_owned2
DEF_FUNC set_oserror_owned2, ROO_FRAME
    mov [rbp - ROO_OWNED], rdx
    mov [rbp - ROO_OWNED2], r8
    test rdx, rdx
    jz .roo_have_second
    mov rsi, rdx                ; name the resolved path, not the PathLike
.roo_have_second:
    mov rdx, rcx
    test r8, r8
    jz .roo_second_plain
    mov rdx, r8
.roo_second_plain:
    ; The release has to come after the build, which names the paths.
    call oserror_build    ; rax = the exception, and it took its own
                                ; reference to both filenames
    push rax
    sub rsp, 8
    mov rdi, [rbp - ROO_OWNED]
    test rdi, rdi
    jz .roo_no_owned
    call obj_decref
.roo_no_owned:
    mov rdi, [rbp - ROO_OWNED2]
    test rdi, rdi
    jz .roo_no_owned2
    call obj_decref
.roo_no_owned2:
    add rsp, 8
    pop rdi
    test rdi, rdi
    jz .roo_out
    extern exc_install
    call exc_install            ; adopts the reference
.roo_out:
    xor eax, eax
    leave
    ret
END_FUNC set_oserror_owned2

;; ============================================================================
;; set_oserror(rdi = errno, rsi = filename PyStrObject* or 0)
;;   -> rax = 0, always, with the OSError pending
;;
;; exc_install, and a return: nothing here jumps into the unwinder, so the
;; caller releases what it holds on its own way out.  set_exception in
;; eval.asm is the same thing for a type-and-message pair.
;; ============================================================================
global set_oserror
DEF_FUNC set_oserror
    xor edx, edx                ; no second path
    call oserror_build    ; rax = the exception, owned
    test rax, rax
    jz .so_out
    mov rdi, rax
    extern exc_install
    call exc_install            ; adopts the reference
.so_out:
    xor eax, eax
    leave
    ret
END_FUNC set_oserror

;; oserror_build(rdi = errno, rsi = filename or 0, rdx = a second
;;                     filename or 0) -> rax = the exception
;;
;; The half of set_oserror that only builds, so a caller with cleanup of its
;; own can do it between building and installing: posix has a resolved path
;; to release that the message names.
;;
;; The second filename is CPython's five-argument form, (errno, strerror,
;; filename, winerror, filename2); OSError.__str__ already renders it as
;; "... : 'src' -> 'dst'".  rename reported only its source without it.
DEF_FUNC oserror_build, RO_FRAME
    mov [rbp - RO_ARGS + 16], rsi   ; args[2] = filename, or NULL for now
    mov [rbp - RO_ARGS + 24], rdx   ; args[3] = winerror; overwritten below
    mov [rbp - RO_ARGS + 32], rdx   ; args[4] = filename2, or NULL
    push rdi
    call int_from_i64
    V_PACK rax, rdx
    mov [rbp - RO_ARGS], rax        ; args[0] = errno
    pop rdi
    extern strerror
    call strerror wrt ..plt
    mov rdi, rax
    call str_from_cstr_heap
    mov [rbp - RO_ARGS + 8], rax    ; args[1] = strerror text

    mov edx, 2                      ; two args when there is no filename
    cmp qword [rbp - RO_ARGS + 16], 0
    je .ro_call
    mov edx, 3
    cmp qword [rbp - RO_ARGS + 32], 0
    je .ro_call
    ; The five-argument form.  args[3] is Windows-only and is None here.
    lea rax, [rel none_singleton]
    mov [rbp - RO_ARGS + 24], rax
    mov edx, 5
.ro_call:
    lea rdi, [rel exc_OSError_type]
    lea rsi, [rbp - RO_ARGS]
    call oserror_new                ; rax = the instance
    ; oserror_new takes references of its own, so the two built here are
    ; ours to release: without this every OSError raised from posix leaked
    ; its strerror text and, outside +-2^50, its errno as well.  A loop that
    ; probes the filesystem with try/except leaked once per attempt.
    push rax
    sub rsp, 8
    mov rdi, [rbp - RO_ARGS + 8]
    call obj_decref
    mov rax, [rbp - RO_ARGS]
    DECREF_V rax, rcx
    add rsp, 8
    pop rax
    leave
    ret
END_FUNC oserror_build

section .data
align 8
; errno -> OSError subclass, exactly CPython's ADD_ERRNO table (19 entries,
; Objects/exceptions.c).  Terminated by a zero errno; errno 0 never maps.
align 8
oserror_errnomap:
    dq 11,  exc_BlockingIOError_type        ; EAGAIN (and EWOULDBLOCK)
    dq 114, exc_BlockingIOError_type        ; EALREADY
    dq 115, exc_BlockingIOError_type        ; EINPROGRESS
    dq 32,  exc_BrokenPipeError_type        ; EPIPE
    dq 108, exc_BrokenPipeError_type        ; ESHUTDOWN
    dq 10,  exc_ChildProcessError_type      ; ECHILD
    dq 103, exc_ConnectionAbortedError_type ; ECONNABORTED
    dq 111, exc_ConnectionRefusedError_type ; ECONNREFUSED
    dq 104, exc_ConnectionResetError_type   ; ECONNRESET
    dq 17,  exc_FileExistsError_type        ; EEXIST
    dq 2,   exc_FileNotFoundError_type      ; ENOENT
    dq 21,  exc_IsADirectoryError_type      ; EISDIR
    dq 20,  exc_NotADirectoryError_type     ; ENOTDIR
    dq 4,   exc_InterruptedError_type       ; EINTR
    dq 13,  exc_PermissionError_type        ; EACCES
    dq 1,   exc_PermissionError_type        ; EPERM
    dq 3,   exc_ProcessLookupError_type     ; ESRCH
    dq 110, exc_TimeoutError_type           ; ETIMEDOUT
    dq 0,   0

align 8
oserror_attr_names:
    dq oserror_n_errno
    dq oserror_n_strerror
    dq oserror_n_filename
    dq oserror_n_filename2
    dq 0
oserror_n_errno:     db "errno", 0
oserror_n_strerror:  db "strerror", 0
oserror_n_filename:  db "filename", 0
oserror_n_filename2: db "filename2", 0
oserror_n_written:   db "characters_written", 0


section .text

;; ============================================================================
;; oserror_reduce(rdi = the argument array, rsi = the count) -> rax = a Value
;;   -- OSError.__reduce__(self)
;;
;; CPython's OSError_reduce.
;; Two things make it differ from BaseException's:
;;
;;   * a filename is re-packed INTO the arguments, because the constructor
;;     takes it back there and `args` does not carry it -- a filename
;;     truncates args to two items.  Three when there is one filename, five
;;     when there are two: the fourth is the Windows-only winerror, which has
;;     to be present as None for the fifth to land where the constructor reads
;;     it.
;;   * the state is the real instance dict, if one has been allocated.
;; ============================================================================
ORD_SELF   equ 8
ORD_ARGS   equ 16           ; the args tuple to hand over, owned
ORD_FNAME  equ 32
ORD_FNAME2 equ 40
ORD_ORIG   equ 48           ; the original args tuple, borrowed
ORD_FRAME  equ 64           ; + 2 pushes = 80, 16-aligned
extern obj_incref
extern ir_reduce_tuple
global oserror_reduce
DEF_FUNC oserror_reduce, ORD_FRAME
    push rbx
    push r12
    mov rax, [rdi]                      ; self, always a pointer
    mov [rbp - ORD_SELF], rax
    mov rcx, [rax + PyOSErrorObject.filename]
    mov [rbp - ORD_FNAME], rcx
    mov rcx, [rax + PyOSErrorObject.filename2]
    mov [rbp - ORD_FNAME2], rcx
    mov rax, [rax + PyExceptionObject.exc_args]
    mov [rbp - ORD_ORIG], rax
    test rax, rax
    jz .ord_args_empty
    cmp qword [rax + PyTupleObject.ob_size], 2
    jne .ord_args_as_is
    cmp qword [rbp - ORD_FNAME], 0
    je .ord_args_as_is

    mov edi, 3
    cmp qword [rbp - ORD_FNAME2], 0
    je .ord_alloc
    mov edi, 5
.ord_alloc:
    call tuple_new
    test rax, rax
    jz .ord_failed
    mov rbx, rax
    mov r12, [rax + PyTupleObject.ob_item]
    mov rax, [rbp - ORD_ORIG]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rcx, [rax]
    INCREF_V rcx, rdx
    mov [r12], rcx
    mov rcx, [rax + 8]
    INCREF_V rcx, rdx
    mov [r12 + 8], rcx
    mov rcx, [rbp - ORD_FNAME]
    INCREF_V rcx, rdx
    mov [r12 + 16], rcx
    cmp qword [rbp - ORD_FNAME2], 0
    je .ord_args_built
    lea rcx, [rel none_singleton]       ; winerror, so filename2 lands at 4
    INCREF rcx
    mov [r12 + 24], rcx
    mov rcx, [rbp - ORD_FNAME2]
    INCREF_V rcx, rdx
    mov [r12 + 32], rcx
.ord_args_built:
    mov [rbp - ORD_ARGS], rbx
    jmp .ord_state

.ord_args_empty:
    xor edi, edi
    call tuple_new
    test rax, rax
    jz .ord_failed
    mov [rbp - ORD_ARGS], rax
    jmp .ord_state

.ord_args_as_is:
    mov rdi, [rbp - ORD_ORIG]
    call obj_incref
    mov rax, [rbp - ORD_ORIG]
    mov [rbp - ORD_ARGS], rax

.ord_state:
    mov rdi, [rbp - ORD_SELF]
    mov rdx, [rdi + PyExceptionObject.exc_dict]
    mov rdi, [rdi + PyObject.ob_type]
    mov rsi, [rbp - ORD_ARGS]
    xor ecx, ecx
    test rdx, rdx
    setnz cl
    call ir_reduce_tuple
    pop r12
    pop rbx
    leave
    ret

.ord_failed:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC oserror_reduce
