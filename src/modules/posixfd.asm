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
extern sys_ioctl
extern bytes_from_data
extern bytes_type
extern bytearray_type
extern ap_memcpy
extern set_oserror
extern set_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_OverflowError_type
extern none_singleton
extern bool_false
extern bool_true

;; ============================================================================
;; posix.fcntl(fd, cmd, arg=0) -> int, or bytes when arg was bytes-like
;; Fails: 0
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
    ERR_M1 .pfc_fail
    mov [rbp - PFC_FD], rax         ; the fd, across the next conversion
    mov rdi, [rbx + 8]
    call posix_int_arg
    ERR_M1 .pfc_fail
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
    ERR_M1 .pfc_fail
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
    call set_oserror
.pfc_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
.pfc_too_big:
    FAIL exc_ValueError_type, "fcntl string arg too long", .pfc_fail
.pfc_argerr:
    SET_EXC exc_TypeError_type, "fcntl() takes 2 or 3 arguments"
    leave                           ; nothing pushed yet; rax = 0
    ret
END_FUNC posix_fcntl

;; posix_blocking_fd(rdi = descriptor Value) -> signed C int
;; Fails: -1
DEF_FUNC_LOCAL posix_blocking_fd
    V_UNPACK rdi, rdx
    extern obj_as_index_clamped
    call obj_as_index_clamped
    ERR_M1 .fail
    movsxd rcx, eax
    cmp rax, rcx
    jne .overflow
    leave
    ret
.overflow:
    SET_EXC exc_OverflowError_type, "Python int too large to convert to C int"
.fail:
    mov rax, -1
    leave
    ret
END_FUNC posix_blocking_fd

;; posix.set_blocking(fd, blocking) -> None
;; Fails: 0
PSB_ARGS     equ 8
PSB_FD       equ 16
PSB_NONBLOCK equ 24
PSB_FRAME    equ 32
FIONBIO      equ 0x5421
DEF_FUNC posix_set_blocking, PSB_FRAME
    cmp rsi, 2
    jne .args
    mov [rbp - PSB_ARGS], rdi
    mov rdi, [rdi]
    call posix_blocking_fd
    ERR_M1 .fail
    mov [rbp - PSB_FD], rax
    mov rdi, [rbp - PSB_ARGS]
    mov rdi, [rdi + 8]
    extern obj_is_true
    call obj_is_true
    ERR_M1 .fail
    xor eax, 1
    mov [rbp - PSB_NONBLOCK], eax
    mov rdi, [rbp - PSB_FD]
    mov esi, FIONBIO
    lea rdx, [rbp - PSB_NONBLOCK]
    call sys_ioctl
    test rax, rax
    js .oserror
    LOAD_NONE rax
    leave
    ret
.args:
    SET_EXC exc_TypeError_type, "set_blocking() takes exactly 2 arguments"
    jmp .fail
.oserror:
    neg rax
    mov rdi, rax
    xor esi, esi
    call set_oserror
.fail:
    xor eax, eax
    leave
    ret
END_FUNC posix_set_blocking

;; posix.get_blocking(fd) -> bool
;; Fails: 0
F_GETFL equ 3
DEF_FUNC posix_get_blocking
    cmp rsi, 1
    jne .args
    mov rdi, [rdi]
    call posix_blocking_fd
    ERR_M1 .fail
    mov rdi, rax
    mov esi, F_GETFL
    xor edx, edx
    call sys_fcntl
    test rax, rax
    js .oserror
    test eax, O_NONBLOCK
    lea rax, [rel bool_true]
    lea rcx, [rel bool_false]
    cmovne rax, rcx
    leave
    ret
.args:
    SET_EXC exc_TypeError_type, "get_blocking() takes exactly 1 argument"
    jmp .fail
.oserror:
    neg rax
    mov rdi, rax
    xor esi, esi
    call set_oserror
.fail:
    xor eax, eax
    leave
    ret
END_FUNC posix_get_blocking

;; ============================================================================
;; posix.flock(fd, operation) -> None
;; Fails: 0
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
    ERR_M1 .pfl_fail
    pop rdi
    push rax
    mov rdi, [rdi + 8]
    call posix_int_arg
    ERR_M1 .pfl_fail
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
    call set_oserror
    jmp .pfl_fail
.pfl_argerr:
    SET_EXC exc_TypeError_type, "flock() takes exactly 2 arguments"
.pfl_fail:
    xor eax, eax                    ; leave drops whatever was pushed
    leave
    ret
END_FUNC posix_flock
