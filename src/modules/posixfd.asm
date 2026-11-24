; modules/posixfd.asm - the two descriptor calls that are neither a read nor a
; write: fcntl and flock
;
; A new file rather than more of posix.asm, which is within a few kilobytes of
; the 100k cap that src/compiler/lint.py holds hand-written files to.  The
; seam is the one posix.ioctl's docblock already names: the raw call belongs
; in assembly and the CONSTANTS -- F_GETFL, LOCK_EX and the hundred-odd names
; CPython's fcntl module publishes -- belong in Python, so lib/fcntl.py is
; written against these two the way lib/select.py is written against
; _socketcore.
;
; Both take the same shape as posix.ioctl, and for the same reason: a bytes
; argument is a STRUCT the kernel writes through, so it is copied into a
; buffer, handed over, and given back as bytes.  `struct flock` is 32 bytes
; and F_GETLK is the call that needs it; CPython's buffer is 1024, and so is
; this one, because that is the size its ValueError names.

%include "macros.inc"
%include "object.inc"
%include "gil.inc"
%include "value.inc"

section .text

extern posix_int_arg
extern sys_fcntl
extern sys_flock
extern bytes_from_data
extern bytes_type
extern bytearray_type
extern ap_memcpy
extern raise_oserror
extern raise_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern none_singleton

;; ============================================================================
;; posix.fcntl(fd, cmd, arg=0) -> int, or bytes when arg was bytes-like
;;
;; CPython's fcntl.fcntl, minus the constants.  An integer argument is passed
;; by value and the call's own result comes back; a bytes-like one is a struct
;; the kernel reads and writes through -- F_GETLK fills in a `struct flock` --
;; so it is copied into a buffer of this frame, passed by address, and the
;; buffer is handed back as a new bytes of the same length.
;;
;; The buffer is 1024 bytes because that is the size CPython's message names,
;; and a longer argument is refused rather than truncated: truncating one
;; would hand the kernel a struct with a missing tail.
;; ============================================================================
PFC_BUF   equ 1032          ; the 1024-byte buffer, ending here
PFC_FD    equ 1040          ; below it, so neither can grow into the other
PFC_LEN   equ 1048
PFC_FRAME equ 1056          ; + 2 pushes = 1072, 16-aligned
PFC_MAX   equ 1024

global posix_fcntl
DEF_FUNC posix_fcntl, PFC_FRAME
    cmp rsi, 2
    jb .pfc_argerr
    cmp rsi, 3
    ja .pfc_argerr
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi

    mov rdi, [rbx]
    call posix_int_arg
    mov [rbp - PFC_FD], rax         ; the fd, across the next conversion
    mov rdi, [rbx + 8]
    call posix_int_arg
    mov r11, rax                    ; the command

    cmp r12, 3
    jb .pfc_int_arg
    mov rdi, [rbx + 16]
    V_TEST_PTR rdi, rax
    ja .pfc_int_arg                 ; an immediate: an integer argument
    test rdi, rdi
    jz .pfc_int_arg
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .pfc_bytes
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    jne .pfc_int_arg
    mov rsi, [rdi + PyByteArrayObject.ob_bytes]
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    jmp .pfc_have_buf
.pfc_bytes:
    lea rsi, [rdi + PyBytesObject.data]
    mov rdx, [rdi + PyBytesObject.ob_size]
.pfc_have_buf:
    cmp rdx, PFC_MAX
    ja .pfc_too_big
    mov [rbp - PFC_LEN], rdx
    push r11
    push r11                        ; two pushes: rsp keeps its alignment
    lea rdi, [rbp - PFC_BUF]
    call ap_memcpy
    pop r11
    pop r11

    mov rdi, [rbp - PFC_FD]
    mov rsi, r11
    lea rdx, [rbp - PFC_BUF]
    call sys_fcntl
    test rax, rax
    js .pfc_failed
    lea rdi, [rbp - PFC_BUF]
    mov rsi, [rbp - PFC_LEN]
    call bytes_from_data
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.pfc_int_arg:
    xor edx, edx
    cmp r12, 3
    jb .pfc_call
    mov rdi, [rbx + 16]
    call posix_int_arg
    mov rdx, rax
.pfc_call:
    mov rdi, [rbp - PFC_FD]
    mov rsi, r11
    call sys_fcntl
    test rax, rax
    js .pfc_failed
    mov edx, TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.pfc_failed:
    neg eax
    mov edi, eax
    xor esi, esi
    call raise_oserror
.pfc_too_big:
    pop r12
    pop rbx
    RAISE exc_ValueError_type, "fcntl string arg too long"
.pfc_argerr:
    RAISE exc_TypeError_type, "fcntl() takes 2 or 3 arguments"
END_FUNC posix_fcntl

;; ============================================================================
;; posix.flock(fd, operation) -> None
;;
;; BSD advisory locking, which is a syscall of its own rather than an fcntl
;; command: the two lock families do not see each other, and a program that
;; uses one has to keep using it.  lockf() is the fcntl family and is built on
;; posix.fcntl in lib/fcntl.py, where `struct flock` can be packed.
;; ============================================================================
PFL_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
global posix_flock
DEF_FUNC posix_flock, PFL_FRAME
    cmp rsi, 2
    jne .pfl_argerr
    push rdi
    mov rdi, [rdi]
    call posix_int_arg
    pop rdi
    push rax
    mov rdi, [rdi + 8]
    call posix_int_arg
    mov rsi, rax
    pop rdi
    BLOCKING_CALL sys_flock
    test rax, rax
    js .pfl_failed
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    ret
.pfl_failed:
    neg eax
    mov edi, eax
    xor esi, esi
    call raise_oserror
.pfl_argerr:
    RAISE exc_TypeError_type, "flock() takes exactly 2 arguments"
END_FUNC posix_flock
