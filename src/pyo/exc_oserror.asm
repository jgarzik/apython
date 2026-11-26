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
    jz .done
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
.done:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC oserror_install_members

;; ============================================================================
;; oserror_new(rdi = type, rsi = args, rdx = nargs) -> fat pair (rax, rdx)
;;
;; OSError's constructor, installed as tp_new on exc_OSError_type only.
;; exc_type_call consults tp_new before its own default path, and DEF_EXC_TYPE
;; leaves the slot 0 on the subclasses -- which is what CPython wants too: the
;; errno-to-subclass remapping applies only when the type is exactly OSError.
;;
;; From CPython's oserror_parse_args/oserror_init: for 2 <= nargs <= 5 the
;; arguments are (errno, strerror, filename, winerror, filename2); when a
;; filename is given and is not None it is stored and `.args` is truncated to
;; its first two items, which is why `OSError(2, "x", "/f").args` is a 2-tuple.
;;
;; ============================================================================
ONW_TYPE   equ 8
ONW_ARGS   equ 16
ONW_NARGS  equ 24
ONW_EXC    equ 32
ONW_ERRNO  equ 40           ; the four attributes, as Values
ONW_STRERR equ 48
ONW_FNAME  equ 56
ONW_FNAME2 equ 64
ONW_EFFN   equ 72           ; the effective argument count for .args
ONW_FRAME  equ 80           ; + 2 pushes = 96
DEF_FUNC oserror_new, ONW_FRAME
    push rbx
    push r12
    mov [rbp - ONW_TYPE], rdi
    mov [rbp - ONW_ARGS], rsi
    mov [rbp - ONW_NARGS], rdx
    mov [rbp - ONW_EFFN], rdx

    ; An absent field remains NULL so reduction can distinguish an explicit None.
    xor eax, eax
    mov [rbp - ONW_ERRNO], rax
    mov [rbp - ONW_STRERR], rax
    mov [rbp - ONW_FNAME], rax
    mov [rbp - ONW_FNAME2], rax

    cmp rdx, 2
    jl .onw_build
    cmp rdx, 5
    jg .onw_build

    mov rax, [rbp - ONW_ARGS]
    mov rcx, [rax]
    mov [rbp - ONW_ERRNO], rcx
    mov rcx, [rax + 8]
    mov [rbp - ONW_STRERR], rcx
    cmp qword [rbp - ONW_NARGS], 3
    jl .onw_subclass
    mov rcx, [rax + 16]
    lea rsi, [rel none_singleton]
    cmp rcx, rsi
    je .onw_subclass
    mov [rbp - ONW_FNAME], rcx
    mov qword [rbp - ONW_EFFN], 2
    cmp qword [rbp - ONW_NARGS], 5
    jl .onw_subclass
    mov rcx, [rax + 32]         ; args[4]; args[3] is Windows-only winerror
    cmp rcx, rsi
    je .onw_subclass
    mov [rbp - ONW_FNAME2], rcx

.onw_subclass:
    ; Remap to a subclass by errno, but only for OSError itself.
    mov rax, [rbp - ONW_TYPE]
    lea rcx, [rel exc_OSError_type]
    cmp rax, rcx
    jne .onw_build
    ; int_is_integer, not V_IS_INT: under INT_STRESS=1 -- and for any errno
    ; past the immediate range -- the number arrives as a heap PyIntObject, and
    ; testing only for an immediate silently skipped the remapping.
    mov rdi, [rbp - ONW_ERRNO]
    V_UNPACK rdi, rdx
    push rdi
    push rdx
    call int_is_integer
    pop rdx
    pop rdi
    test eax, eax
    jz .onw_build
    call int_to_i64             ; rdi = payload, edx = tag
    mov rdi, rax
    lea rsi, [rel oserror_errnomap]
.onw_scan:
    mov rax, [rsi]
    test rax, rax
    jz .onw_build               ; end of table
    cmp rax, rdi
    je .onw_mapped
    add rsi, 16
    jmp .onw_scan
.onw_mapped:
    mov rax, [rsi + 8]
    mov [rbp - ONW_TYPE], rax

.onw_build:
    ; exc_new(type, args[0] or NULL) gives the instance and a 0-or-1 tuple.
    mov rdi, [rbp - ONW_TYPE]
    xor esi, esi
    xor edx, edx
    cmp qword [rbp - ONW_NARGS], 0
    je .onw_created
    mov rax, [rbp - ONW_ARGS]
    mov rsi, [rax]
    mov edx, TAG_PTR
.onw_created:
    call exc_new
    mov [rbp - ONW_EXC], rax

    ; Replace .args when the effective count is not the 0-or-1 exc_new made.
    mov rcx, [rbp - ONW_EFFN]
    cmp rcx, 2
    jl .onw_attrs
    mov rdi, rcx
    call tuple_new
    mov r12, rax
    xor edx, edx
.onw_copy:
    cmp rdx, [rbp - ONW_EFFN]
    jge .onw_replace
    mov rsi, [rbp - ONW_ARGS]
    mov rdi, [rsi + rdx*8]
    INCREF_V rdi, r8
    mov r9, [r12 + PyTupleObject.ob_item]
    mov [r9 + rdx*8], rdi
    inc rdx
    jmp .onw_copy
.onw_replace:
    mov rdi, [rbp - ONW_EXC]
    mov rax, [rdi + PyExceptionObject.exc_args]
    test rax, rax
    jz .onw_set_args
    mov rdi, rax
    call obj_decref
.onw_set_args:
    mov rdi, [rbp - ONW_EXC]
    mov [rdi + PyExceptionObject.exc_args], r12

.onw_attrs:
    mov rax, [rbp - ONW_EXC]
    mov rdx, [rbp - ONW_ERRNO]
    INCREF_V rdx, rcx
    mov [rax + PyOSErrorObject.errno], rdx
    mov rdx, [rbp - ONW_STRERR]
    INCREF_V rdx, rcx
    mov [rax + PyOSErrorObject.strerror], rdx
    mov rdx, [rbp - ONW_FNAME]
    INCREF_V rdx, rcx
    mov [rax + PyOSErrorObject.filename], rdx
    mov rdx, [rbp - ONW_FNAME2]
    INCREF_V rdx, rcx
    mov [rax + PyOSErrorObject.filename2], rdx

.onw_done:
    mov rax, [rbp - ONW_EXC]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC oserror_new

;; oserror_is_field(rdi = attribute name, NUL-terminated) -> eax = boolean
DEF_FUNC oserror_is_field, 16
    push rbx
    push r12
    mov r12, rdi
    lea rbx, [rel oserror_attr_names]
.next:
    mov rsi, [rbx]
    test rsi, rsi
    jz .missing
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
.missing:
    xor eax, eax
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


section .text

;; ============================================================================
;; oserror_reduce(rdi = the argument array, rsi = the count) -> rax = a Value
;;   -- OSError.__reduce__(self)
;;
;; CPython's OSError_reduce, and the only method OSError keeps of its own.
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
