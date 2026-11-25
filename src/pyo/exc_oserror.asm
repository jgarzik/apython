; exc_oserror.asm - what OSError does that no other exception does.
;
; Split out of exception.asm, which reached the 100k cap that
; src/compiler/lint.py enforces.  The seam is a real one: OSError is the only
; exception with a constructor that rewrites its own class from its first
; argument, the only one with four named attributes beside .args, and the only
; one whose str() assembles a message from them rather than printing what it
; was handed.  Nothing here is reachable for any other exception type, and
; nothing else in exception.asm calls into it except exc_str, for the one line
; that asks whether this is an OSError.
;
; The errno -> subclass table is CPython's ADD_ERRNO list and belongs with the
; constructor that reads it.

%include "macros.inc"
%include "object.inc"

; --- objects ---
extern dict_get_quiet
extern obj_decref
extern obj_repr
extern obj_str
extern int_from_i64
extern int_to_i64
extern int_is_integer
extern str_from_cstr_heap
extern str_new_heap
extern tuple_new
extern dict_get
extern ap_memcpy
extern obj_dealloc

; --- exceptions ---
extern exc_new
extern exc_setattr
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

;; ============================================================================
;; oserror_str(rdi = exc) -> rax = PyStrObject*, 0 to fall through, or -1 when
;; a field's repr()/str() raised.  The third answer is not the second: falling
;; through on a raise rendered the args tuple and left the exception pending.
;;
;; "[Errno N] strerror: 'file' -> 'file2'", with the tail dropped as the parts
;; run out, exactly as CPython's OSError_str does.  Returns 0 when there is not
;; even an errno and a strerror, so exc_str falls back to the generic rendering
;; -- which is what makes str(OSError()) empty and str(OSError("boom")) "boom".
;;
;; The attributes are read out of exc_dict, where oserror_new put them.
;; ============================================================================
OSS_EXC    equ 8
OSS_DICT   equ 16
OSS_TMP    equ 24           ; a borrowed str being copied out
OSS_CUR    equ 32           ; write cursor
OSS_BUF    equ 544          ; 512 bytes of assembly space
OSS_FRAME  equ 544          ; + 2 pushes = 560
DEF_FUNC oserror_str, OSS_FRAME
    push rbx
    push r12
    mov [rbp - OSS_EXC], rdi
    mov rax, [rdi + PyExceptionObject.exc_dict]
    test rax, rax
    jz .oss_none
    mov [rbp - OSS_DICT], rax

    lea rbx, [rbp - OSS_BUF]        ; rbx = cursor

    ; errno and strerror are both required for any of the forms.
    lea rdi, [rel oserror_n_errno]
    call oserror_field
    test rax, rax
    jz .oss_none
    mov r12, rax                    ; r12 = errno Value
    lea rdi, [rel oserror_n_strerror]
    call oserror_field
    test rax, rax
    jz .oss_none

    ; "[Errno " <repr(errno)> "] "
    mov dword [rbx], '[Err'
    mov dword [rbx + 4], 'no  '
    add rbx, 7
    mov rdi, r12
    call obj_repr                   ; an int's repr is its digits
    test rax, rax
    jz .oss_raised                  ; the repr/str raised
    V_UNPACK rax, rdx
    mov rdi, rbx
    call oserror_append
    mov rbx, rax
    mov word [rbx], ' ' * 256 + ']'
    add rbx, 2

    ; str(strerror)
    lea rdi, [rel oserror_n_strerror]
    call oserror_field
    mov rdi, rax
    call obj_str
    test rax, rax
    jz .oss_raised                  ; the repr/str raised
    V_UNPACK rax, rdx
    mov rdi, rbx
    call oserror_append
    mov rbx, rax

    ; ": " repr(filename), then " -> " repr(filename2)
    lea rdi, [rel oserror_n_filename]
    call oserror_field
    test rax, rax
    jz .oss_finish
    mov r12, rax
    mov word [rbx], ' ' * 256 + ':'
    add rbx, 2
    mov rdi, r12
    call obj_repr
    test rax, rax
    jz .oss_raised                  ; the repr/str raised
    V_UNPACK rax, rdx
    mov rdi, rbx
    call oserror_append
    mov rbx, rax

    lea rdi, [rel oserror_n_filename2]
    call oserror_field
    test rax, rax
    jz .oss_finish
    mov r12, rax
    mov dword [rbx], ' -> '
    add rbx, 4
    mov rdi, r12
    call obj_repr
    test rax, rax
    jz .oss_raised                  ; the repr/str raised
    V_UNPACK rax, rdx
    mov rdi, rbx
    call oserror_append
    mov rbx, rax

.oss_finish:
    lea rdi, [rbp - OSS_BUF]
    mov rsi, rbx
    sub rsi, rdi
    extern str_new_heap
    call str_new_heap
    pop r12
    pop rbx
    leave
    ret

.oss_none:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.oss_raised:
    ; A field's repr() or str() raised.  Those four returns went unchecked, so
    ; a filename with a raising __repr__ produced a truncated message and left
    ; the exception to fire at some later, unrelated point.
    mov rax, -1
    pop r12
    pop rbx
    leave
    ret
END_FUNC oserror_str

;; ============================================================================
;; oserror_field(rdi = name cstr) -> rax = the Value, or 0 when absent or None
;; Reads [rbp - OSS_DICT] from oserror_str's frame, so it is local to it.
;; ============================================================================
DEF_FUNC_LOCAL oserror_field, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, [rbp]                  ; oserror_str's rbp
    call str_from_cstr_heap
    push rax
    mov rdi, [rbx - OSS_DICT]
    mov rsi, rax
    call dict_get_quiet
    mov rcx, rax
    pop rdi
    push rcx
    call obj_decref                 ; the temporary key
    pop rax
    test rax, rax
    jz .osf_no
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .osf_no
    pop rbx
    leave
    ret
.osf_no:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC oserror_field

;; ============================================================================
;; oserror_append(rdi = cursor, rax = PyStrObject*) -> rax = new cursor
;; Copies the string's bytes and drops the reference.  Bounded: the caller's
;; buffer is 512 bytes and a single field is truncated rather than overrunning.
;; ============================================================================
OSA_CUR   equ 8
OSA_STR   equ 16
OSA_LEN   equ 24
OSA_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC_LOCAL oserror_append, OSA_FRAME
    mov [rbp - OSA_CUR], rdi
    mov [rbp - OSA_STR], rax
    test rax, rax
    jz .osa_nothing
    mov rdx, [rax + PyStrObject.ob_size]
    cmp rdx, 120
    jle .osa_len_ok
    mov edx, 120                    ; one field cannot fill the buffer
    ; Back off to a character boundary: cutting at 120 bytes landed in the
    ; middle of a UTF-8 sequence and left the message ending in a lone
    ; continuation byte, which is not a str at all.
.osa_back_off:
    test rdx, rdx
    jz .osa_len_ok
    movzx ecx, byte [rax + PyStrObject.data + rdx]
    and ecx, 0xc0
    cmp ecx, 0x80                   ; a continuation byte: the cut is inside
    jne .osa_len_ok
    dec rdx
    jmp .osa_back_off
.osa_len_ok:
    mov [rbp - OSA_LEN], rdx
    mov rdi, [rbp - OSA_CUR]
    lea rsi, [rax + PyStrObject.data]
    extern ap_memcpy
    call ap_memcpy
    mov rdi, [rbp - OSA_STR]
    call obj_decref
    mov rax, [rbp - OSA_CUR]
    add rax, [rbp - OSA_LEN]
    leave
    ret
.osa_nothing:
    mov rax, [rbp - OSA_CUR]
    leave
    ret
END_FUNC oserror_append


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
;; The four attributes live in the instance's exc_dict rather than in new
;; struct fields.  exc_getattr already falls through to exc_dict, so `.errno`
;; and friends need no arm of their own; and PyExceptionObject stays the size
;; it was, which matters because exc_new allocates a compile-time constant and
;; every exception in the process would otherwise have paid for these.
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

    ; Everything defaults to None; CPython reports None, not AttributeError,
    ; for an OSError built with no arguments.
    lea rax, [rel none_singleton]
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
    jl .onw_have_fields
    mov rcx, [rax + 16]
    mov [rbp - ONW_FNAME], rcx
    cmp qword [rbp - ONW_NARGS], 5
    jl .onw_have_fields
    mov rcx, [rax + 32]         ; args[4]; args[3] is Windows-only winerror
    mov [rbp - ONW_FNAME2], rcx

.onw_have_fields:
    ; A filename that is present and not None truncates .args to two items.
    mov rax, [rbp - ONW_FNAME]
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .onw_subclass
    mov qword [rbp - ONW_EFFN], 2

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
    lea rbx, [rel oserror_attr_names]
    ; The four Values sit at rbp-40, -48, -56, -64: a larger ONW_ constant is a
    ; LOWER address, so the walk subtracts.
    lea r12, [rbp - ONW_ERRNO]
.onw_attr_loop:
    mov rdi, [rbx]
    test rdi, rdi
    jz .onw_done
    call str_from_cstr_heap
    push rax
    mov rdi, [rbp - ONW_EXC]
    mov rsi, rax
    mov rdx, [r12]
    mov ecx, TAG_PTR
    call exc_setattr            ; err: none of the five is a field name
    pop rdi
    call obj_decref             ; exc_setattr's dict_set took its own ref
    add rbx, 8
    sub r12, 8
    jmp .onw_attr_loop

.onw_done:
    mov rax, [rbp - ONW_EXC]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC oserror_new

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
;; oserror_named(rdi = the exception, rsi = the attribute name as a C string)
;;   -> rax = the value as a Value, borrowed, or 0
;;
;; 0 both when the dict has no such key and when the value is None: CPython
;; keeps these as C fields, its test is `self->filename`, and a NULL field and
;; a None are the same absence to it.
;; ============================================================================
ONM_DICT  equ 8
ONM_KEY   equ 16
ONM_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
extern str_intern_cstr
DEF_FUNC_LOCAL oserror_named, ONM_FRAME
    mov rdi, [rdi + PyExceptionObject.exc_dict]
    test rdi, rdi
    jz .onm_none
    mov [rbp - ONM_DICT], rdi
    mov rdi, rsi
    call str_intern_cstr
    test rax, rax
    jz .onm_none
    mov [rbp - ONM_KEY], rax
    mov rdi, [rbp - ONM_DICT]
    mov rsi, rax
    call dict_get_quiet                       ; a borrowed Value, or 0 for a miss
    mov [rbp - ONM_DICT], rax           ; ONM_DICT is spent; hold the answer
    mov rdi, [rbp - ONM_KEY]
    call obj_decref                     ; str_intern_cstr's own reference
    mov rax, [rbp - ONM_DICT]
    test rax, rax
    jz .onm_none
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .onm_none
    leave
    ret
.onm_none:
    xor eax, eax
    leave
    ret
END_FUNC oserror_named

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
;;   * the state is the instance dict WITHOUT the four named attributes.  They
;;     are C fields in CPython, so its dict never has them; here they live in
;;     exc_dict (bugs.md carries why), and handing them on as a state would
;;     make the reduction a three-tuple where CPython's is a two-tuple.  The
;;     filter is what keeps the two answers identical.
;; ============================================================================
ORD_SELF   equ 8
ORD_ARGS   equ 16           ; the args tuple to hand over, owned
ORD_STATE  equ 24           ; the filtered dict, owned, or 0
ORD_FNAME  equ 32
ORD_FNAME2 equ 40
ORD_ORIG   equ 48           ; the original args tuple, borrowed
ORD_FRAME  equ 64           ; + 2 pushes = 80, 16-aligned
extern obj_incref
extern dict_copy_shallow
extern dict_del_opt
extern ir_reduce_tuple
global oserror_reduce
DEF_FUNC oserror_reduce, ORD_FRAME
    push rbx
    push r12
    mov rax, [rdi]                      ; self, always a pointer
    mov [rbp - ORD_SELF], rax
    mov qword [rbp - ORD_STATE], 0

    mov rdi, rax
    lea rsi, [rel oserror_n_filename]
    call oserror_named
    mov [rbp - ORD_FNAME], rax
    mov rdi, [rbp - ORD_SELF]
    lea rsi, [rel oserror_n_filename2]
    call oserror_named
    mov [rbp - ORD_FNAME2], rax

    mov rax, [rbp - ORD_SELF]
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
    mov rdi, [rdi + PyExceptionObject.exc_dict]
    test rdi, rdi
    jz .ord_build
    call dict_copy_shallow
    test rax, rax
    jz .ord_build
    mov rbx, rax
    lea r12, [rel oserror_attr_names]
.ord_strip:
    mov rdi, [r12]
    test rdi, rdi
    jz .ord_stripped
    call str_intern_cstr
    test rax, rax
    jz .ord_stripped
    mov [rbp - ORD_ORIG], rax           ; ORD_ORIG is spent; hold the key
    mov rdi, rbx
    mov rsi, rax
    call dict_del_opt                   ; -1 when it was never there -- err: the key is an interned attribute name
    mov rdi, [rbp - ORD_ORIG]
    call obj_decref
    add r12, 8
    jmp .ord_strip
.ord_stripped:
    cmp qword [rbx + PyDictObject.ob_size], 0
    jne .ord_keep_state
    mov rdi, rbx
    call obj_decref
    jmp .ord_build
.ord_keep_state:
    mov [rbp - ORD_STATE], rbx

.ord_build:
    mov rdi, [rbp - ORD_SELF]
    mov rdi, [rdi + PyObject.ob_type]   ; type(self), borrowed
    mov rsi, [rbp - ORD_ARGS]           ; the reference goes with it
    mov rdx, [rbp - ORD_STATE]
    xor ecx, ecx
    test rdx, rdx
    jz .ord_call
    mov ecx, 1
.ord_call:
    call ir_reduce_tuple
    mov [rbp - ORD_ARGS], rax           ; spent; hold the answer
    mov rdi, [rbp - ORD_STATE]
    test rdi, rdi
    jz .ord_done
    call obj_decref                     ; ir_reduce_tuple took its own
.ord_done:
    mov rax, [rbp - ORD_ARGS]
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
