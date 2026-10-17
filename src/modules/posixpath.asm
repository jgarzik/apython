; modules/posixpath.asm - how an argument becomes a path, and how a bad one
; is refused
;
; Split out of posix.asm, which was at the 100k cap that src/compiler/lint.py
; holds hand-written files to.  This is a seam the file already had: the
; syscall wrappers all begin by turning one argument into a NUL-terminated C
; string, and posix_path_arg is the only thing that knows how -- str, str
; subclass, bytes, bytes subclass, or one __fspath__ step, with the embedded
; NUL refused before any of it reaches the kernel.
;
; It is not only posix's.  _io.FileIO opens its path from here too, which is
; what fixed `open(b"...")` and `open(S("..."))` for a str subclass; the
; refusal it wants is worded differently, which is what POSIX_PATH_KIND_IO is.
;
; The message builders it calls -- posix_typename_of, posix_copy_bounded,
; posix_raise_typename -- and the buffer they write into stay in posix.asm,
; where a dozen other refusals share them.

%include "macros.inc"
%include "object.inc"
%include "posixpath.inc"

extern ap_strlen
extern exc_TypeError_type
extern exc_ValueError_type
extern obj_decref
extern raise_exception
extern set_exception
extern str_type
extern bytes_type
extern posix_copy_bounded
extern posix_typename_of
extern posix_raise_typename
extern pm_msgbuf
extern pm_msg_fspath
extern pm_msg_path
extern pm_msg_shouldbe
extern pm_msg_not
extern pm_msg_io
extern pm_msg_expected
extern pm_kind_plain
extern pm_kind_fd
extern pm_kind_fd_none
extern dunder_call_1
extern obj_call_n
extern obj_getattr_opt

section .text


PPA_VAL   equ 8
PPA_OWNED equ 16
PPA_PTR   equ 24
PPA_EXC   equ 32            ; current_exception before __fspath__ ran
PPA_ORIG  equ 40            ; the argument as given, for the message
PPA_WHO   equ 48            ; "<func>: <arg>", for the message, or 0
PPA_KINDS equ 56            ; which kinds this caller accepts
; Whether the path RESOLVED to a bytes -- after __fspath__, which may answer
; either kind.  CPython gives a bytes path bytes results, and this function
; threw the distinction away: .ppa_str and .ppa_bytes converged and every
; caller built str.  os.scandir(b'.'), os.listdir(b'.') and os.readlink on a
; bytes path were all str here.
PPA_ISBYTES equ 64
PPA_FRAME equ 80            ; + 0 pushes = 80, 16-aligned

;; ============================================================================
;; posix_embedded_nul(rdi = a pointer to the characters, rsi = the declared
;;                    length in bytes)
;;   -> eax = 1 when there is a NUL before the end, 0 when the string is
;;      clean
;;
;; A C string ends at the first NUL and a Python str does not, so handing one
;; straight to a syscall acts on a PREFIX of what the caller asked for --
;; silently, which is how a checked path becomes a different path.  CPython
;; refuses rather than truncating, and so does everything here.
;;
;; The test is the declared length against the C length.  It is safe to run
;; ap_strlen past the characters because every PyStrObject and every
;; PyBytesObject is NUL-terminated; src/pyo/bytes.asm's header records that
;; this comparison is the reason.
;;
;; Its callers are posix_path_arg below, the three string vectors in
;; posixproc.asm, and FileIO's own open path in modules/io.asm.  The last
;; four had no check at all: os.execv(p, ["sh", "-c", "x\0y"]) passed "x",
;; and open("a\0b") opened "a".
;; ============================================================================
PNUL_LEN equ 8
PNUL_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC posix_embedded_nul, PNUL_FRAME
    mov [rbp - PNUL_LEN], rsi
    call ap_strlen
    cmp rax, [rbp - PNUL_LEN]
    jne .pnul_yes
    xor eax, eax
    leave
    ret
.pnul_yes:
    mov eax, 1
    leave
    ret
END_FUNC posix_embedded_nul

;; posix_path_arg(rdi = the argument Value, rsi = a "<func>: <arg>" prefix or
;;                0, edx = the accepted kinds)
;;   -> rax = a NUL-terminated C string, rdx = an object to release or 0,
;;      rcx = 1 when the path resolved to a BYTES, 0 when it was a str
;;
;; rcx is a real return value, not leftover scratch: a caller that builds a
;; name or a path out of what it finds has to build it of the argument's own
;; kind.  Callers that only pass the string to a syscall ignore it.
;;
;; CPython names the function and the argument in its refusal -- "stat: path
;; should be string, bytes, os.PathLike or integer, not float" -- and lists
;; the kinds THAT function takes.  This said only "path should be string,
;; bytes, or os.PathLike, not float" for all thirteen callers.
global posix_path_arg
DEF_FUNC posix_path_arg, PPA_FRAME
    mov [rbp - PPA_WHO], rsi
    mov [rbp - PPA_KINDS], rdx
    mov [rbp - PPA_VAL], rdi
    mov [rbp - PPA_ORIG], rdi   ; kept: the message names the class whose
                                ; __fspath__ answered wrongly, not the answer
    mov qword [rbp - PPA_OWNED], 0
    mov qword [rbp - PPA_EXC], 0

.ppa_classify:
    mov rdi, [rbp - PPA_VAL]
    V_TEST_PTR rdi, rax
    ja .ppa_bad                 ; an immediate is never a path
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .ppa_str
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jnz .ppa_str
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .ppa_bytes

    ; os.PathLike: one __fspath__ call, whose result must itself be a str or
    ; bytes.  Looping would let a __fspath__ returning another PathLike go
    ; round for ever; CPython allows exactly one step too.
    cmp qword [rbp - PPA_OWNED], 0
    jne .ppa_bad                ; already followed one
    CSTRING rsi, "__fspath__"
    DUNDER_EXC_SAVE [rbp - PPA_EXC]
    call dunder_call_1
    test rax, rax               ; dunder_call_1 answers with a Value; 0 is absent-or-raised
    jnz .ppa_got_fspath
    ; NULL means either "no __fspath__" or "__fspath__ raised", and reporting
    ; the second as a bad path type buries the real exception.
    DUNDER_RAISED [rbp - PPA_EXC], .ppa_propagate
    jmp .ppa_bad
.ppa_got_fspath:
    mov [rbp - PPA_VAL], rax
    ; Only a POINTER is recorded as owned.  __fspath__ can return anything --
    ; `def __fspath__(self): return 5` is a TypeError, but the release runs
    ; before the message is built, and obj_decref on an int immediate writes
    ; through the number.
    V_TEST_PTR rax, rcx
    ja .ppa_classify
    test rax, rax
    jz .ppa_classify
    mov [rbp - PPA_OWNED], rax  ; the object itself, so the raise paths and
                                ; the caller release the same thing
    jmp .ppa_classify

.ppa_str:
    mov qword [rbp - PPA_ISBYTES], 0
    mov rcx, [rdi + PyStrObject.ob_size]
    lea rax, [rdi + PyStrObject.data]
    jmp .ppa_checked
.ppa_bytes:
    mov qword [rbp - PPA_ISBYTES], 1
    mov rcx, [rdi + PyBytesObject.ob_size]
    lea rax, [rdi + PyBytesObject.data]

.ppa_checked:
    ; The declared length and the C length must agree, or there is a NUL in
    ; the middle and the syscall would act on a prefix.
    mov [rbp - PPA_PTR], rax
    mov rdi, rax
    mov rsi, rcx                        ; the declared length
    call posix_embedded_nul
    test eax, eax
    jnz .ppa_embedded_nul
    mov rax, [rbp - PPA_PTR]
    mov rdx, [rbp - PPA_OWNED]  ; the __fspath__ result, now the caller's
    mov rcx, [rbp - PPA_ISBYTES]
    leave
    ret

;; Every refusal ends here: the exception is already pending and this answers
;; 0, which is what the docblock above promises and what all twenty-four call
;; sites are written for.  It used to RAISE instead, and a raise abandons the C
;; stack -- so the cleanup each caller had ready for this never ran.  For the
;; one-path callers that cost nothing; for rename, symlink, link and putenv,
;; which resolve two paths and hold the first while converting the second, it
;; leaked the first one's resolved path on every refusal of the second.
.ppa_fail_out:
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
    leave
    ret

.ppa_propagate:
    ; __fspath__ raised: the exception is already the right one.
    POSIX_PATH_DONE [rbp - PPA_OWNED]
    jmp .ppa_fail_out

.ppa_embedded_nul:
    ; The __fspath__ result is still held here, and set_exception does not
    ; abandon the frame -- but releasing before setting keeps the order the
    ; other arms use.
    POSIX_PATH_DONE [rbp - PPA_OWNED]
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "embedded null byte"
    call set_exception
    jmp .ppa_fail_out

.ppa_bad:
    ; Two different failures share this label: the argument was never a path,
    ; or its __fspath__ handed back something that is not one.  CPython words
    ; them differently, and the second names the class.
    mov rax, [rbp - PPA_ORIG]
    cmp rax, [rbp - PPA_VAL]
    je .ppa_bad_plain

    lea rdi, [rel pm_msgbuf]
    lea rsi, [rel pm_msg_expected]
    mov edx, 40
    call posix_copy_bounded
    mov rdi, rax
    mov rsi, [rbp - PPA_ORIG]
    call posix_typename_of
    mov rdi, rax
    lea rsi, [rel pm_msg_fspath]
    mov edx, 60
    call posix_copy_bounded
    mov rdi, rax
    mov rsi, [rbp - PPA_VAL]
    call posix_typename_of
    POSIX_PATH_DONE [rbp - PPA_OWNED]
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel pm_msgbuf]
    call set_exception
    jmp .ppa_fail_out

.ppa_bad_plain:
    POSIX_PATH_DONE [rbp - PPA_OWNED]
    cmp qword [rbp - PPA_KINDS], POSIX_PATH_KIND_IO
    je .ppa_bad_io
    lea rdi, [rel pm_msgbuf]
    mov rsi, [rbp - PPA_WHO]
    test rsi, rsi
    jz .ppa_no_who
    mov edx, 40                     ; the prefix already reads "<func>: <arg>"
    call posix_copy_bounded
    mov rdi, rax
    jmp .ppa_kinds
.ppa_bad_io:
    lea rdi, [rel pm_msgbuf]
    lea rsi, [rel pm_msg_io]
    mov edx, 56
    call posix_copy_bounded
    mov rdi, rax
    mov rsi, [rbp - PPA_VAL]
    call posix_typename_of
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel pm_msgbuf]
    call set_exception
    jmp .ppa_fail_out
.ppa_no_who:
    lea rsi, [rel pm_msg_path]
    mov edx, 8
    call posix_copy_bounded
    mov rdi, rax
.ppa_kinds:
    lea rsi, [rel pm_msg_shouldbe]
    mov edx, 32
    call posix_copy_bounded
    mov rdi, rax
    mov rcx, [rbp - PPA_KINDS]
    lea rsi, [rel pm_kind_plain]
    cmp rcx, POSIX_PATH_KIND_FD
    je .ppa_kind_fd
    cmp rcx, POSIX_PATH_KIND_FD_NONE
    je .ppa_kind_fd_none
    jmp .ppa_kind_copy
.ppa_kind_fd:
    lea rsi, [rel pm_kind_fd]
    jmp .ppa_kind_copy
.ppa_kind_fd_none:
    lea rsi, [rel pm_kind_fd_none]
.ppa_kind_copy:
    mov edx, 48
    call posix_copy_bounded
    mov rdi, rax
    lea rsi, [rel pm_msg_not]
    mov edx, 8
    call posix_copy_bounded
    mov rdi, rax
    mov rsi, [rbp - PPA_VAL]
    call posix_typename_of
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel pm_msgbuf]
    call set_exception
    jmp .ppa_fail_out
END_FUNC posix_path_arg
