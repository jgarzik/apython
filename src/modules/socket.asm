; socketmod.asm - _socketcore, the descriptor half of the socket layer
;
; The split is the one _iocore/lib/_io.py already uses: what only assembly can
; do is here, and everything expressible in Python is in lib/_socket.py, which
; presents itself to the stdlib as `_socket`.
;
; The line between the halves is the sockaddr.  Nothing here knows what an
; address means: bind, connect, accept and the rest take and return the raw
; bytes the kernel wants, and lib/_socket.py packs a (host, port) pair or a
; filesystem path into them.  So AF_INET and AF_UNIX cost this file nothing
; and AF_INET6 would cost it nothing either -- the family is a number that
; travels through.
;
; Every call is the syscall and the errno check, and the errno check is
; raise_oserror, which is what maps ECONNREFUSED to ConnectionRefusedError
; and EAGAIN to BlockingIOError.  Timeouts are not here: a timeout is a poll
; on a non-blocking descriptor, and that is a loop in Python.

%include "macros.inc"
%include "object.inc"
%include "gil.inc"
%include "value.inc"
%include "eventloop.inc"

ASM_INIT

extern dict_new
extern dict_set
extern module_new
extern str_from_cstr_heap
extern str_new_heap
extern builtin_func_new
extern obj_decref
extern int_from_i64
extern int_is_integer
extern int_fits_i64
extern obj_as_index
extern bytes_from_data
extern bytes_like_ptr_len
extern bytearray_type
extern memoryview_type
extern list_new
extern list_append
extern tuple_new
extern set_oserror
extern set_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_OverflowError_type
extern ap_malloc
extern ap_free
extern ap_memcpy
extern ap_strlen
extern none_singleton
extern obj_dealloc
extern list_type
extern bool_true
extern bool_false

extern sys_socket
extern sys_bind
extern sys_listen
extern sys_accept4
extern sys_connect
extern sys_sendto
extern sys_recvfrom
extern sys_setsockopt
extern sys_getsockopt
extern sys_getsockname
extern sys_getpeername
extern sys_shutdown
extern sys_socketpair
extern sys_poll
extern sys_close
extern sys_dup
extern sys_fcntl
extern sys_uname

;; ============================================================================
;; SOCK_CHECK_RET reg, exit -- the kernel returns -errno in [-4095, -1].  The
;; OSError is recorded, with no filename to attach, and control goes to the
;; caller's error exit.
;; ============================================================================
%macro SOCK_CHECK_RET 2         ; %1 = the result, %2 = the error exit
    cmp %1, -4095
    jb %%ok
    mov rdi, %1
    neg rdi
    xor esi, esi
    call set_oserror
    jmp %2
%%ok:
%endmacro

; The largest sockaddr this file ever handles: sockaddr_un is 110 bytes.
SOCKADDR_MAX equ 128

; The largest single recv this will attempt.  ap_malloc is fatal on failure,
; so a size that cannot be met has to be refused rather than tried; list
; repetition draws the same line in the same place.
SOCK_MAX_RECV equ 0x10000000

; O_CLOEXEC for a socket, which is where the accept path needs it.
SOCK_CLOEXEC equ 0o2000000

F_GETFL equ 3
F_SETFL equ 4
O_NONBLOCK equ 0o4000

section .text

;; ============================================================================
;; sk_int_arg(rdi = a Value) -> rax = int64
;; Fails: -1
;;
;; posix_int_arg by another name, and for the same reason: obj_as_index alone
;; reads a float's payload as a pointer, so a descriptor of 0.5 would be
;; whatever those bits point at.
;; ============================================================================
DEF_FUNC_LOCAL sk_int_arg, 8            ; 1 pushes, so rsp is 16-aligned
    push rdi
    V_UNPACK rdi, rdx
    call int_is_integer
    test eax, eax
    jz .sia_bad
    pop rdi
    push rdi
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .sia_fail
    pop rdi
    push rax
    sub rsp, 8
    V_UNPACK rdi, rdx
    call int_fits_i64
    add rsp, 8
    test eax, eax
    jz .sia_range
    pop rax
    leave
    ret
.sia_range:
    FAIL exc_OverflowError_type, "Python int too large to convert to C int", .sia_fail
.sia_bad:
    SET_EXC exc_TypeError_type, "an integer is required"
.sia_fail:
    mov rax, -1                 ; leave drops the parked argument
    leave
    ret
END_FUNC sk_int_arg

;; ============================================================================
;; sk_bytes_arg(rdi = a Value) -> rax = data, r10 = length
;; sk_wbuf_arg(rdi = a Value) -> the same, for something writable
;; An empty buffer's storage may be NULL, so 0 alone is not the refusal.
;; Fails: 0?
;; ============================================================================
DEF_FUNC_LOCAL sk_bytes_arg
    call bytes_like_ptr_len
    test ecx, ecx
    jz .sba_bad
    leave
    ret
.sba_bad:
    SET_EXC exc_TypeError_type, "a bytes-like object is required"
    leave                       ; rax = 0
    ret
END_FUNC sk_bytes_arg

;; Fails: 0?
DEF_FUNC_LOCAL sk_wbuf_arg, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    V_TEST_PTR rdi, rax
    ja .swb_bad
    test rdi, rdi
    jz .swb_bad
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .swb_ok
    lea rcx, [rel memoryview_type]
    cmp rax, rcx
    jne .swb_bad
    cmp qword [rdi + PyMemoryViewObject.mv_readonly], 0
    jne .swb_bad
.swb_ok:
    mov rdi, rbx
    call bytes_like_ptr_len
    test ecx, ecx
    jz .swb_bad
    pop rbx
    leave
    ret
.swb_bad:
    SET_EXC exc_TypeError_type, "a writable bytes-like object is required"
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC sk_wbuf_arg

;; ============================================================================
;; sk_ret_int(rdi = int64) -> rax = that as a Value
;; ============================================================================
DEF_FUNC_LOCAL sk_ret_int
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret
END_FUNC sk_ret_int

;; ============================================================================
;; _socketcore.socket(family, type, proto) -> fd
;; ============================================================================
DEF_FUNC sock_socket_fn, 16
    cmp rsi, 3
    jl .ss_args
    push rbx
    push r12
    mov rbx, rdi
    mov rdi, [rbx]
    call sk_int_arg
    ERR_M1 .ss_fail
    mov r12, rax
    mov rdi, [rbx + 8]
    call sk_int_arg
    ERR_M1 .ss_fail
    push rax
    mov rdi, [rbx + 16]
    call sk_int_arg
    ERR_M1 .ss_fail1
    mov rdx, rax
    pop rsi
    mov rdi, r12
    call sys_socket
    SOCK_CHECK_RET rax, .ss_fail
    mov rdi, rax
    pop r12
    pop rbx
    leave
    jmp sk_ret_int
.ss_args:
    SET_EXC exc_TypeError_type, "socket() takes exactly 3 arguments"
    leave                       ; nothing pushed yet; rax = 0
    ret
.ss_fail1:
    pop rcx                     ; the type, parked across the conversion
.ss_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC sock_socket_fn

;; ============================================================================
;; _socketcore.close(fd) / dup(fd)
;; ============================================================================
DEF_FUNC sock_close_fn, 16
    test rsi, rsi
    jz .sc_args
    mov rdi, [rdi]
    call sk_int_arg
    ERR_M1 .sc_fail
    mov rdi, rax
    call sys_close
    SOCK_CHECK_RET rax, .sc_fail
    LOAD_NONE rax
    leave
    ret
.sc_args:
    SET_EXC exc_TypeError_type, "close() takes exactly 1 argument"
.sc_fail:
    xor eax, eax
    leave
    ret
END_FUNC sock_close_fn

DEF_FUNC sock_dup_fn, 16
    test rsi, rsi
    jz .sd_args
    mov rdi, [rdi]
    call sk_int_arg
    ERR_M1 .sd_fail
    mov rdi, rax
    call sys_dup
    SOCK_CHECK_RET rax, .sd_fail
    mov rdi, rax
    leave
    jmp sk_ret_int
.sd_args:
    SET_EXC exc_TypeError_type, "dup() takes exactly 1 argument"
.sd_fail:
    xor eax, eax
    leave
    ret
END_FUNC sock_dup_fn

;; ============================================================================
;; bind(fd, addr) / connect(fd, addr) / connect_ex(fd, addr)
;;
;; connect_ex answers the errno rather than raising it: that is the whole
;; difference between the two, and non-blocking connect() reports EINPROGRESS
;; through it.
;; ============================================================================
SKA_FD    equ 8
SKA_LEN   equ 16
SKA_BUF   equ 16 + SOCKADDR_MAX
SKA_FRAME equ ((SKA_BUF + 15) / 16) * 16

DEF_FUNC_LOCAL sock_addr_setup, SKA_FRAME
    ; rdi = args, returns rax = fd, rsi = &buf, rdx = len -- but the buffer is
    ; the CALLER's frame, so this is spelled out at each call site instead.
    leave
    ret
END_FUNC sock_addr_setup

;; sock_bind_like(rdi = args, rsi = nargs, rdx = the syscall) -> rax = result
;; The result is the kernel's, -errno included; a refused ARGUMENT is -1 with
;; the exception pending.
;; Fails: -1
SBL_FD    equ 8
SBL_FN    equ 16
SBL_LEN   equ 24
SBL_BUF   equ 32 + SOCKADDR_MAX
SBL_FRAME equ ((SBL_BUF + 15) / 16) * 16 + 8      ; + 1 push = 16-aligned
DEF_FUNC_LOCAL sock_bind_like, SBL_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - SBL_FN], rdx
    mov rdi, [rbx]
    call sk_int_arg
    ERR_M1 .sbl_fail
    mov [rbp - SBL_FD], rax
    mov rdi, [rbx + 8]
    call sk_bytes_arg           ; rax = data, r10 = length
    ERR_PENDING .sbl_fail
    cmp r10, SOCKADDR_MAX
    ja .sbl_toobig
    test r10, r10
    jz .sbl_empty
    mov [rbp - SBL_LEN], r10
    mov rdi, rbp
    sub rdi, SBL_BUF
    mov rsi, rax
    mov rdx, r10
    call ap_memcpy
    mov rdi, [rbp - SBL_FD]
    mov rsi, rbp
    sub rsi, SBL_BUF
    mov rdx, [rbp - SBL_LEN]
    ; connect() can block for as long as the peer takes; bind() never does,
    ; and gives the GIL up for a few microseconds it did not need to.  The
    ; address is in this frame.
    mov rax, [rbp - SBL_FN]
    extern gil_blocking_call
    call gil_blocking_call
    pop rbx
    leave
    ret
.sbl_toobig:
    FAIL exc_ValueError_type, "address too long", .sbl_fail
.sbl_empty:
    SET_EXC exc_ValueError_type, "empty address"
.sbl_fail:
    mov rax, -1
    pop rbx
    leave
    ret
END_FUNC sock_bind_like

DEF_FUNC sock_bind_fn, 16
    cmp rsi, 2
    jl .sb_args
    lea rdx, [rel sys_bind]
    call sock_bind_like
    ERR_M1 .sb_fail
    SOCK_CHECK_RET rax, .sb_fail
    LOAD_NONE rax
    leave
    ret
.sb_args:
    SET_EXC exc_TypeError_type, "bind() takes exactly 2 arguments"
.sb_fail:
    xor eax, eax
    leave
    ret
END_FUNC sock_bind_fn

DEF_FUNC sock_connect_fn, 16
    cmp rsi, 2
    jl .sn_args
    lea rdx, [rel sys_connect]
    call sock_bind_like
    ERR_M1 .sn_fail
    SOCK_CHECK_RET rax, .sn_fail
    LOAD_NONE rax
    leave
    ret
.sn_args:
    SET_EXC exc_TypeError_type, "connect() takes exactly 2 arguments"
.sn_fail:
    xor eax, eax
    leave
    ret
END_FUNC sock_connect_fn

DEF_FUNC sock_connect_ex_fn, 16
    cmp rsi, 2
    jl .sx_args
    lea rdx, [rel sys_connect]
    call sock_bind_like
    ERR_M1 .sx_fail
    xor edi, edi
    cmp rax, -4095
    jb .sx_ok
    mov rdi, rax
    neg rdi
.sx_ok:
    leave
    jmp sk_ret_int
.sx_args:
    SET_EXC exc_TypeError_type, "connect_ex() takes exactly 2 arguments"
.sx_fail:
    xor eax, eax
    leave
    ret
END_FUNC sock_connect_ex_fn

;; ============================================================================
;; listen(fd, backlog) / shutdown(fd, how)
;; ============================================================================
DEF_FUNC sock_listen_fn, 8         ; lint: pushes=1 -- the `push rbx` below sits after the
                            ; argument test, and lint counts only the pushes before
                            ; the first non-push instruction.  Unannotated it read
                            ; this frame as pushless and demanded the size that
                            ; MISALIGNS it.
    cmp rsi, 2
    jl .sl_args
    push rbx
    mov rbx, rdi
    mov rdi, [rbx]
    call sk_int_arg
    ERR_M1 .sl_fail
    push rax
    mov rdi, [rbx + 8]
    call sk_int_arg
    ERR_M1 .sl_fail1
    mov rsi, rax
    pop rdi
    call sys_listen
    SOCK_CHECK_RET rax, .sl_fail
    LOAD_NONE rax
    pop rbx
    leave
    ret
.sl_args:
    SET_EXC exc_TypeError_type, "listen() takes exactly 2 arguments"
    leave                       ; nothing pushed yet; rax = 0
    ret
.sl_fail1:
    pop rcx                     ; the descriptor, parked across the conversion
.sl_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC sock_listen_fn

DEF_FUNC sock_shutdown_fn, 8         ; lint: pushes=1 -- the `push rbx` below sits after the
                            ; argument test, and lint counts only the pushes before
                            ; the first non-push instruction.  Unannotated it read
                            ; this frame as pushless and demanded the size that
                            ; MISALIGNS it.
    cmp rsi, 2
    jl .sh_args
    push rbx
    mov rbx, rdi
    mov rdi, [rbx]
    call sk_int_arg
    ERR_M1 .sh_fail
    push rax
    mov rdi, [rbx + 8]
    call sk_int_arg
    ERR_M1 .sh_fail1
    mov rsi, rax
    pop rdi
    call sys_shutdown
    SOCK_CHECK_RET rax, .sh_fail
    LOAD_NONE rax
    pop rbx
    leave
    ret
.sh_args:
    SET_EXC exc_TypeError_type, "shutdown() takes exactly 2 arguments"
    leave                       ; nothing pushed yet; rax = 0
    ret
.sh_fail1:
    pop rcx                     ; the descriptor, parked across the conversion
.sh_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC sock_shutdown_fn

;; ============================================================================
;; accept(fd) -> (fd, addr_bytes)
;; ============================================================================
SAC_LEN   equ 8
SAC_FD    equ 16
SAC_TUP   equ 24
SAC_BUF   equ 32 + SOCKADDR_MAX
SAC_FRAME equ ((SAC_BUF + 15) / 16) * 16 + 8       ; + 1 push = 16-aligned
DEF_FUNC sock_accept_fn, SAC_FRAME
    push rbx
    test rsi, rsi
    jz .sa_args
    mov rdi, [rdi]
    call sk_int_arg
    ERR_M1 .sa_fail
    mov rbx, rax
    mov dword [rbp - SAC_LEN], SOCKADDR_MAX
    ; SOCK_CLOEXEC: every descriptor Python opens is non-inheritable by
    ; default (PEP 446), and an accepted socket that survives an exec is a
    ; listening server's descriptor in somebody else's process.
    mov rdi, rbx
    mov rsi, rbp
    sub rsi, SAC_BUF
    mov rdx, rbp
    sub rdx, SAC_LEN
    mov ecx, SOCK_CLOEXEC
    BLOCKING_CALL sys_accept4
    SOCK_CHECK_RET rax, .sa_fail
    mov [rbp - SAC_FD], rax

    mov edx, [rbp - SAC_LEN]
    cmp rdx, SOCKADDR_MAX
    jbe .sa_have_len
    mov edx, SOCKADDR_MAX
.sa_have_len:
    mov rdi, rbp
    sub rdi, SAC_BUF
    mov rsi, rdx
    call bytes_from_data
    test rax, rax
    jz .sa_fail
    mov rbx, rax                    ; the address bytes

    mov edi, 2
    call tuple_new
    test rax, rax
    jz .sa_fail
    mov [rbp - SAC_TUP], rax
    mov rdi, [rbp - SAC_FD]
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - SAC_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx], rax
    mov [rcx + 8], rbx              ; the tuple takes the reference
    mov rax, [rbp - SAC_TUP]
    pop rbx
    leave
    ret
.sa_fail:
    xor eax, eax
    pop rbx
    leave
    ret
.sa_args:
    FAIL exc_TypeError_type, "accept() takes exactly 1 argument", .sa_fail
END_FUNC sock_accept_fn

;; ============================================================================
;; getsockname(fd) / getpeername(fd) -> addr_bytes
;; ============================================================================
SGN_LEN   equ 8
SGN_BUF   equ 16 + SOCKADDR_MAX
SGN_FRAME equ ((SGN_BUF + 15) / 16) * 16 + 8       ; + 1 push = 16-aligned
;; sock_name_like(rdi = args, rsi = nargs, rdx = the syscall) -> rax = bytes
;; Fails: 0
DEF_FUNC_LOCAL sock_name_like, SGN_FRAME
    push rbx
    mov rbx, rdx                    ; the syscall
    mov rdi, [rdi]
    call sk_int_arg
    ERR_M1 .snl_fail
    mov dword [rbp - SGN_LEN], SOCKADDR_MAX
    mov rdi, rax
    mov rsi, rbp
    sub rsi, SGN_BUF
    mov rdx, rbp
    sub rdx, SGN_LEN
    call rbx
    SOCK_CHECK_RET rax, .snl_fail
    mov edx, [rbp - SGN_LEN]
    cmp rdx, SOCKADDR_MAX
    jbe .snl_len
    mov edx, SOCKADDR_MAX
.snl_len:
    mov rdi, rbp
    sub rdi, SGN_BUF
    mov rsi, rdx
    call bytes_from_data
    pop rbx
    leave
    ret
.snl_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC sock_name_like

DEF_FUNC sock_getsockname_fn, 16
    test rsi, rsi
    jz .sgn_args
    lea rdx, [rel sys_getsockname]
    call sock_name_like         ; err: its 0 and its exception are ours
    leave
    ret
.sgn_args:
    SET_EXC exc_TypeError_type, "getsockname() takes exactly 1 argument"
    leave
    ret
END_FUNC sock_getsockname_fn

DEF_FUNC sock_getpeername_fn, 16
    test rsi, rsi
    jz .sgp_args
    lea rdx, [rel sys_getpeername]
    call sock_name_like         ; err: its 0 and its exception are ours
    leave
    ret
.sgp_args:
    SET_EXC exc_TypeError_type, "getpeername() takes exactly 1 argument"
    leave
    ret
END_FUNC sock_getpeername_fn

;; ============================================================================
;; send(fd, data, flags) -> n     -- sendto(fd, data, flags, addr) when given
;; ============================================================================
SSD_FD    equ 8
SSD_FLAGS equ 16
SSD_DATA  equ 24
SSD_LEN   equ 32
SSD_ALEN  equ 40
SSD_BUF   equ 48 + SOCKADDR_MAX
SSD_FRAME equ ((SSD_BUF + 15) / 16) * 16 + 8       ; + 1 push = 16-aligned
DEF_FUNC sock_send_fn, SSD_FRAME
    push rbx
    cmp rsi, 3
    jl .ssd_args
    mov rbx, rdi
    mov r10, rsi                    ; nargs
    push r10
    mov rdi, [rbx]
    call sk_int_arg
    ERR_M1 .ssd_fail1
    mov [rbp - SSD_FD], rax
    mov rdi, [rbx + 8]
    call sk_bytes_arg
    ERR_PENDING .ssd_fail1
    mov [rbp - SSD_DATA], rax
    mov [rbp - SSD_LEN], r10
    mov rdi, [rbx + 16]
    call sk_int_arg
    ERR_M1 .ssd_fail1
    mov [rbp - SSD_FLAGS], rax
    pop r10
    xor r8d, r8d                    ; no destination
    xor r9d, r9d
    cmp r10, 4
    jl .ssd_go
    mov rdi, [rbx + 24]
    call sk_bytes_arg               ; rax = data, r10 = length
    ERR_PENDING .ssd_fail
    cmp r10, SOCKADDR_MAX
    ja .ssd_toobig
    mov [rbp - SSD_ALEN], r10
    mov rdi, rbp
    sub rdi, SSD_BUF
    mov rsi, rax
    mov rdx, r10
    call ap_memcpy
    mov r8, rbp
    sub r8, SSD_BUF
    mov r9, [rbp - SSD_ALEN]
.ssd_go:
    mov rdi, [rbp - SSD_FD]
    mov rsi, [rbp - SSD_DATA]
    mov rdx, [rbp - SSD_LEN]
    mov rcx, [rbp - SSD_FLAGS]
    BLOCKING_CALL sys_sendto
    SOCK_CHECK_RET rax, .ssd_fail
    mov rdi, rax
    pop rbx
    leave
    jmp sk_ret_int
.ssd_toobig:
    FAIL exc_ValueError_type, "address too long", .ssd_fail
.ssd_args:
    FAIL exc_TypeError_type, "send() takes at least 3 arguments", .ssd_fail
.ssd_fail1:
    pop rcx                     ; the argument count, parked across the conversions
.ssd_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC sock_send_fn

;; ============================================================================
;; recv(fd, n, flags) -> bytes
;; recvfrom(fd, n, flags) -> (bytes, addr_bytes)
;; ============================================================================
SRC_FD    equ 8
SRC_N     equ 16
SRC_FLAGS equ 24
SRC_BUF   equ 32
SRC_ALEN  equ 40
SRC_DATA  equ 48
SRC_FROM  equ 56 + SOCKADDR_MAX
SRC_FRAME equ ((SRC_FROM + 15) / 16) * 16 + 8      ; + 1 push = 16-aligned
;; sock_recv_common(rdi = args, rsi = nargs, edx = 1 when the sender is wanted)
;;   -> rax = the bytes received
;; Fails: 0
DEF_FUNC_LOCAL sock_recv_common, SRC_FRAME
    ; rdi = args, rsi = nargs, edx = 1 when the sender is wanted
    push rbx
    mov rbx, rdi
    mov [rbp - SRC_ALEN], rdx
    mov rdi, [rbx]
    call sk_int_arg
    ERR_M1 .src_fail
    mov [rbp - SRC_FD], rax
    mov rdi, [rbx + 8]
    call sk_int_arg
    ERR_M1 .src_fail
    test rax, rax
    js .src_negative
    cmp rax, SOCK_MAX_RECV
    ja .src_toobig
    mov [rbp - SRC_N], rax
    mov rdi, [rbx + 16]
    call sk_int_arg
    ERR_M1 .src_fail
    mov [rbp - SRC_FLAGS], rax

    mov rdi, [rbp - SRC_N]
    test rdi, rdi
    jnz .src_alloc
    mov edi, 1
.src_alloc:
    call ap_malloc
    test rax, rax
    jz .src_fail
    mov [rbp - SRC_BUF], rax

    xor r8d, r8d
    xor r9d, r9d
    cmp qword [rbp - SRC_ALEN], 0
    je .src_call
    mov dword [rbp - SRC_ALEN], SOCKADDR_MAX
    mov r8, rbp
    sub r8, SRC_FROM
    mov r9, rbp
    sub r9, SRC_ALEN
.src_call:
    mov rdi, [rbp - SRC_FD]
    mov rsi, [rbp - SRC_BUF]
    mov rdx, [rbp - SRC_N]
    mov rcx, [rbp - SRC_FLAGS]
    BLOCKING_CALL sys_recvfrom
    cmp rax, -4095
    jb .src_ok
    push rax
    push rax
    mov rdi, [rbp - SRC_BUF]
    call ap_free
    pop rax
    pop rax
    SOCK_CHECK_RET rax, .src_fail
.src_ok:
    mov rdi, [rbp - SRC_BUF]
    mov rsi, rax
    call bytes_from_data
    mov [rbp - SRC_DATA], rax
    push rax
    push rax
    mov rdi, [rbp - SRC_BUF]
    call ap_free
    pop rax
    pop rax
    mov rax, [rbp - SRC_DATA]
    pop rbx
    leave
    ret
.src_negative:
    FAIL exc_ValueError_type, "negative buffersize in recv", .src_fail
.src_toobig:
    ; ap_malloc is fatal on failure by design, so an absurd size has to be
    ; refused before it is asked for: `sock.recv(1 << 62)` killed the process
    ; with "Fatal: out of memory" where CPython raises MemoryError.
    extern exc_MemoryError_type
    FAIL exc_MemoryError_type, "", .src_fail
.src_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC sock_recv_common

DEF_FUNC sock_recv_fn, 16
    cmp rsi, 3
    jl .sr_args
    xor edx, edx
    call sock_recv_common       ; err: its 0 and its exception are ours
    leave
    ret
.sr_args:
    SET_EXC exc_TypeError_type, "recv() takes exactly 3 arguments"
    leave
    ret
END_FUNC sock_recv_fn

;; recvfrom needs the address the datagram came from, so it repeats the body
;; with the two extra syscall arguments filled in.
SRF_FD    equ 8
SRF_N     equ 16
SRF_FLAGS equ 24
SRF_BUF   equ 32
SRF_ALEN  equ 40
SRF_TUP   equ 48
SRF_DATA  equ 56
SRF_FROM  equ 64 + SOCKADDR_MAX
SRF_FRAME equ ((SRF_FROM + 15) / 16) * 16 + 8      ; + 1 push = 16-aligned
DEF_FUNC sock_recvfrom_fn, SRF_FRAME
    push rbx
    cmp rsi, 3
    jl .srf_args
    mov rbx, rdi
    mov rdi, [rbx]
    call sk_int_arg
    ERR_M1 .srf_fail
    mov [rbp - SRF_FD], rax
    mov rdi, [rbx + 8]
    call sk_int_arg
    ERR_M1 .srf_fail
    test rax, rax
    js .srf_negative
    cmp rax, SOCK_MAX_RECV
    ja .srf_toobig
    mov [rbp - SRF_N], rax
    mov rdi, [rbx + 16]
    call sk_int_arg
    ERR_M1 .srf_fail
    mov [rbp - SRF_FLAGS], rax

    mov rdi, [rbp - SRF_N]
    test rdi, rdi
    jnz .srf_alloc
    mov edi, 1
.srf_alloc:
    call ap_malloc
    test rax, rax
    jz .srf_fail
    mov [rbp - SRF_BUF], rax

    mov dword [rbp - SRF_ALEN], SOCKADDR_MAX
    mov rdi, [rbp - SRF_FD]
    mov rsi, [rbp - SRF_BUF]
    mov rdx, [rbp - SRF_N]
    mov rcx, [rbp - SRF_FLAGS]
    mov r8, rbp
    sub r8, SRF_FROM
    mov r9, rbp
    sub r9, SRF_ALEN
    BLOCKING_CALL sys_recvfrom
    cmp rax, -4095
    jb .srf_ok
    push rax
    push rax
    mov rdi, [rbp - SRF_BUF]
    call ap_free
    pop rax
    pop rax
    SOCK_CHECK_RET rax, .srf_fail
.srf_ok:
    mov rdi, [rbp - SRF_BUF]
    mov rsi, rax
    call bytes_from_data
    mov [rbp - SRF_DATA], rax
    push rax
    push rax
    mov rdi, [rbp - SRF_BUF]
    call ap_free
    pop rax
    pop rax
    cmp qword [rbp - SRF_DATA], 0
    je .srf_fail

    mov edx, [rbp - SRF_ALEN]
    cmp rdx, SOCKADDR_MAX
    jbe .srf_alen
    mov edx, SOCKADDR_MAX
.srf_alen:
    mov rdi, rbp
    sub rdi, SRF_FROM
    mov rsi, rdx
    call bytes_from_data
    test rax, rax
    jz .srf_fail
    mov rbx, rax

    mov edi, 2
    call tuple_new
    test rax, rax
    jz .srf_fail
    mov [rbp - SRF_TUP], rax
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbp - SRF_DATA]
    mov [rcx], rdx
    mov [rcx + 8], rbx
    mov rax, [rbp - SRF_TUP]
    pop rbx
    leave
    ret
.srf_negative:
    FAIL exc_ValueError_type, "negative buffersize in recvfrom", .srf_fail
.srf_toobig:
    FAIL exc_MemoryError_type, "", .srf_fail
.srf_fail:
    xor eax, eax
    pop rbx
    leave
    ret
.srf_args:
    FAIL exc_TypeError_type, "recvfrom() takes exactly 3 arguments", .srf_fail
END_FUNC sock_recvfrom_fn

;; ============================================================================
;; recv_into(fd, buffer, nbytes, flags) -> n
;; ============================================================================
SRI_FD    equ 8
SRI_PTR   equ 16
SRI_CAP   equ 24
SRI_N     equ 32
SRI_FRAME equ 48            ; + 1 push = 56... padded below
DEF_FUNC sock_recv_into_fn, 40
    push rbx
    cmp rsi, 4
    jl .sri_args
    mov rbx, rdi
    mov rdi, [rbx]
    call sk_int_arg
    ERR_M1 .sri_fail
    mov [rbp - SRI_FD], rax
    mov rdi, [rbx + 8]
    call sk_wbuf_arg            ; rax = data, r10 = length
    ERR_PENDING .sri_fail
    mov [rbp - SRI_PTR], rax
    mov [rbp - SRI_CAP], r10
    mov rdi, [rbx + 16]
    call sk_int_arg
    ERR_M1 .sri_fail
    mov [rbp - SRI_N], rax
    test rax, rax
    js .sri_negative
    jnz .sri_have_n
    mov rax, [rbp - SRI_CAP]
    mov [rbp - SRI_N], rax
.sri_have_n:
    mov rax, [rbp - SRI_N]
    cmp rax, [rbp - SRI_CAP]
    ja .sri_toobig
    mov rdi, [rbx + 24]
    call sk_int_arg
    ERR_M1 .sri_fail
    mov rcx, rax
    mov rdi, [rbp - SRI_FD]
    mov rsi, [rbp - SRI_PTR]
    mov rdx, [rbp - SRI_N]
    xor r8d, r8d
    xor r9d, r9d
    BLOCKING_CALL sys_recvfrom
    SOCK_CHECK_RET rax, .sri_fail
    mov rdi, rax
    pop rbx
    leave
    jmp sk_ret_int
.sri_negative:
    FAIL exc_ValueError_type, "negative buffersize in recv_into", .sri_fail
.sri_toobig:
    FAIL exc_ValueError_type, "nbytes is greater than the length of the buffer", .sri_fail
.sri_args:
    FAIL exc_TypeError_type, "recv_into() takes exactly 4 arguments", .sri_fail
.sri_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC sock_recv_into_fn

;; ============================================================================
;; setsockopt(fd, level, optname, value_bytes) -- the value is always bytes;
;; lib/_socket.py is what turns an int into four of them.
;; getsockopt(fd, level, optname, buflen) -> bytes
;; ============================================================================
SSO_FD    equ 8
SSO_LEVEL equ 16
SSO_NAME  equ 24
SSO_LEN   equ 32
SSO_BUF   equ 40 + 256
SSO_FRAME equ ((SSO_BUF + 15) / 16) * 16 + 8       ; + 1 push = 16-aligned
DEF_FUNC sock_setsockopt_fn, SSO_FRAME
    push rbx
    cmp rsi, 4
    jl .sso_args
    mov rbx, rdi
    mov rdi, [rbx]
    call sk_int_arg
    ERR_M1 .sso_fail
    mov [rbp - SSO_FD], rax
    mov rdi, [rbx + 8]
    call sk_int_arg
    ERR_M1 .sso_fail
    mov [rbp - SSO_LEVEL], rax
    mov rdi, [rbx + 16]
    call sk_int_arg
    ERR_M1 .sso_fail
    mov [rbp - SSO_NAME], rax
    mov rdi, [rbx + 24]
    call sk_bytes_arg
    ERR_PENDING .sso_fail
    cmp r10, 256
    ja .sso_toobig
    mov [rbp - SSO_LEN], r10
    mov rdi, rbp
    sub rdi, SSO_BUF
    mov rsi, rax
    mov rdx, r10
    call ap_memcpy
    mov rdi, [rbp - SSO_FD]
    mov rsi, [rbp - SSO_LEVEL]
    mov rdx, [rbp - SSO_NAME]
    mov rcx, rbp
    sub rcx, SSO_BUF
    mov r8, [rbp - SSO_LEN]
    call sys_setsockopt
    SOCK_CHECK_RET rax, .sso_fail
    LOAD_NONE rax
    pop rbx
    leave
    ret
.sso_toobig:
    FAIL exc_ValueError_type, "option value too long", .sso_fail
.sso_args:
    FAIL exc_TypeError_type, "setsockopt() takes exactly 4 arguments", .sso_fail
.sso_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC sock_setsockopt_fn

SGO_FD    equ 8
SGO_LEVEL equ 16
SGO_NAME  equ 24
SGO_LEN   equ 32
SGO_BUF   equ 40 + 256
SGO_FRAME equ ((SGO_BUF + 15) / 16) * 16 + 8       ; + 1 push = 16-aligned
DEF_FUNC sock_getsockopt_fn, SGO_FRAME
    push rbx
    cmp rsi, 4
    jl .sgo_args
    mov rbx, rdi
    mov rdi, [rbx]
    call sk_int_arg
    ERR_M1 .sgo_fail
    mov [rbp - SGO_FD], rax
    mov rdi, [rbx + 8]
    call sk_int_arg
    ERR_M1 .sgo_fail
    mov [rbp - SGO_LEVEL], rax
    mov rdi, [rbx + 16]
    call sk_int_arg
    ERR_M1 .sgo_fail
    mov [rbp - SGO_NAME], rax
    mov rdi, [rbx + 24]
    call sk_int_arg
    ERR_M1 .sgo_fail
    test rax, rax
    js .sgo_badlen
    cmp rax, 256
    ja .sgo_badlen
    mov [rbp - SGO_LEN], rax
    mov rdi, [rbp - SGO_FD]
    mov rsi, [rbp - SGO_LEVEL]
    mov rdx, [rbp - SGO_NAME]
    mov rcx, rbp
    sub rcx, SGO_BUF
    mov r8, rbp
    sub r8, SGO_LEN
    call sys_getsockopt
    SOCK_CHECK_RET rax, .sgo_fail
    mov rdi, rbp
    sub rdi, SGO_BUF
    mov rsi, [rbp - SGO_LEN]
    call bytes_from_data
    pop rbx
    leave
    ret
.sgo_badlen:
    FAIL exc_ValueError_type, "getsockopt buflen out of range", .sgo_fail
.sgo_args:
    FAIL exc_TypeError_type, "getsockopt() takes exactly 4 arguments", .sgo_fail
.sgo_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC sock_getsockopt_fn

;; ============================================================================
;; socketpair(family, type, proto) -> (fd, fd)
;; ============================================================================
SSP_FDS   equ 8
SSP_TUP   equ 16
SSP_FRAME equ 32            ; + 1 push = 40... padded to 24 below
DEF_FUNC sock_socketpair_fn, 24
    push rbx
    cmp rsi, 3
    jl .ssp_args
    mov rbx, rdi
    mov rdi, [rbx]
    call sk_int_arg
    ERR_M1 .ssp_fail
    push rax
    mov rdi, [rbx + 8]
    call sk_int_arg
    ERR_M1 .ssp_fail1
    push rax
    mov rdi, [rbx + 16]
    call sk_int_arg
    ERR_M1 .ssp_fail2
    mov rdx, rax
    pop rsi
    pop rdi
    mov rcx, rbp
    sub rcx, SSP_FDS
    call sys_socketpair
    SOCK_CHECK_RET rax, .ssp_fail

    mov edi, 2
    call tuple_new
    test rax, rax
    jz .ssp_fail
    mov [rbp - SSP_TUP], rax
    mov edi, [rbp - SSP_FDS]
    movsxd rdi, edi
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - SSP_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx], rax
    mov edi, [rbp - SSP_FDS + 4]
    movsxd rdi, edi
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - SSP_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + 8], rax
    mov rax, [rbp - SSP_TUP]
    pop rbx
    leave
    ret
.ssp_fail:
    xor eax, eax
    pop rbx
    leave
    ret
.ssp_args:
    FAIL exc_TypeError_type, "socketpair() takes exactly 3 arguments", .ssp_fail
.ssp_fail2:
    pop rcx                     ; the type
.ssp_fail1:
    pop rcx                     ; the family
    jmp .ssp_fail
END_FUNC sock_socketpair_fn

;; ============================================================================
;; set_blocking(fd, flag) / get_blocking(fd) -- O_NONBLOCK through fcntl,
;; which is where a socket's blocking mode actually lives.
;; ============================================================================
DEF_FUNC sock_set_blocking_fn, 32
    cmp rsi, 2
    jl .sbk_args
    push rbx
    push r12
    mov rbx, rdi
    mov rdi, [rbx]
    call sk_int_arg
    ERR_M1 .sbk_fail
    mov r12, rax
    mov rdi, [rbx + 8]
    call sk_int_arg
    ERR_M1 .sbk_fail
    push rax
    mov rdi, r12
    mov esi, F_GETFL
    xor edx, edx
    call sys_fcntl
    SOCK_CHECK_RET rax, .sbk_fail1
    pop rcx                         ; the requested blocking flag
    test rcx, rcx
    jz .sbk_nonblock
    and rax, ~O_NONBLOCK
    jmp .sbk_set
.sbk_nonblock:
    or rax, O_NONBLOCK
.sbk_set:
    mov rdx, rax
    mov rdi, r12
    mov esi, F_SETFL
    call sys_fcntl
    SOCK_CHECK_RET rax, .sbk_fail
    LOAD_NONE rax
    pop r12
    pop rbx
    leave
    ret
.sbk_args:
    SET_EXC exc_TypeError_type, "set_blocking() takes exactly 2 arguments"
    leave                       ; nothing pushed yet; rax = 0
    ret
.sbk_fail1:
    pop rcx                     ; the requested flag
.sbk_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC sock_set_blocking_fn

DEF_FUNC sock_get_blocking_fn, 16
    test rsi, rsi
    jz .gbk_args
    mov rdi, [rdi]
    call sk_int_arg
    ERR_M1 .gbk_fail
    mov rdi, rax
    mov esi, F_GETFL
    xor edx, edx
    call sys_fcntl
    SOCK_CHECK_RET rax, .gbk_fail
    test rax, O_NONBLOCK
    jnz .gbk_false
    lea rax, [rel bool_true]
    leave
    ret
.gbk_false:
    lea rax, [rel bool_false]
    leave
    ret
.gbk_args:
    SET_EXC exc_TypeError_type, "get_blocking() takes exactly 1 argument"
.gbk_fail:
    xor eax, eax
    leave
    ret
END_FUNC sock_get_blocking_fn

;; ============================================================================
;; gethostname() -> str, out of uname()'s nodename
;; ============================================================================
SGH_BUF   equ 400
SGH_FRAME equ 400
DEF_FUNC sock_gethostname_fn, SGH_FRAME
    mov rdi, rbp
    sub rdi, SGH_BUF
    call sys_uname
    SOCK_CHECK_RET rax, .sgh_fail
    ; struct utsname is five 65-byte fields; nodename is the second.
    mov rdi, rbp
    sub rdi, SGH_BUF
    add rdi, 65
    call str_from_cstr_heap
    leave
    ret
.sgh_fail:
    xor eax, eax
    leave
    ret
END_FUNC sock_gethostname_fn

;; ============================================================================
;; poll(fds, timeout_ms) -> [revents]
;;
;; `fds` is a flat list of alternating descriptor and event mask, which is
;; what a Python caller can build with no packing at all, and the answer is
;; one revents per descriptor in the same order.  select.select() and
;; selectors are both written against this.
;; ============================================================================
SPL_LIST  equ 8
SPL_N     equ 16
SPL_FDS   equ 24
SPL_TMO   equ 32
SPL_OUT   equ 40
SPL_I     equ 48
SPL_DEADLINE equ 56         ; monotonic ns at which the wait expires, or -1
SPL_FRAME equ 64            ; + 1 push = 72... see the pad below
DEF_FUNC sock_poll_fn, 56
    push rbx
    cmp rsi, 2
    jl .spl_args
    mov rbx, rdi
    mov rdi, [rbx]
    V_TEST_PTR rdi, rax
    ja .spl_badlist
    test rdi, rdi
    jz .spl_badlist
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    jne .spl_badlist
    mov [rbp - SPL_LIST], rdi
    mov rax, [rdi + PyListObject.ob_size]
    test rax, 1
    jnz .spl_badlist
    shr rax, 1
    mov [rbp - SPL_N], rax

    mov rdi, [rbx + 8]
    call sk_int_arg
    ERR_M1 .spl_fail
    mov [rbp - SPL_TMO], rax

    ; One pollfd per pair, and never a zero-byte allocation.
    mov rdi, [rbp - SPL_N]
    shl rdi, 3
    test rdi, rdi
    jnz .spl_alloc
    mov edi, 8
.spl_alloc:
    call ap_malloc
    test rax, rax
    jz .spl_fail
    mov [rbp - SPL_FDS], rax

    xor ecx, ecx
    mov [rbp - SPL_I], rcx
.spl_fill:
    mov rcx, [rbp - SPL_I]
    cmp rcx, [rbp - SPL_N]
    jae .spl_ready
    shl rcx, 4                      ; two Values per descriptor
    mov rdx, [rbp - SPL_LIST]
    mov rdx, [rdx + PyListObject.ob_item]
    mov rdi, [rdx + rcx]            ; item 2i, the descriptor
    call sk_int_arg
    ERR_M1 .spl_freefail
    mov rcx, [rbp - SPL_I]
    mov rdx, [rbp - SPL_FDS]
    mov [rdx + rcx*8 + PollFd.fd], eax
    mov rcx, [rbp - SPL_I]
    shl rcx, 4
    mov rdx, [rbp - SPL_LIST]
    mov rdx, [rdx + PyListObject.ob_item]
    mov rdi, [rdx + rcx + 8]        ; item 2i+1, the mask
    call sk_int_arg
    ERR_M1 .spl_freefail
    mov rcx, [rbp - SPL_I]
    mov rdx, [rbp - SPL_FDS]
    mov [rdx + rcx*8 + PollFd.events], ax
    mov word [rdx + rcx*8 + PollFd.revents], 0
    inc qword [rbp - SPL_I]
    jmp .spl_fill

.spl_ready:
    ; A finite timeout becomes a DEADLINE, because the retry below must not
    ; start it again.
    mov qword [rbp - SPL_DEADLINE], -1
    mov eax, [rbp - SPL_TMO]
    test eax, eax
    js .spl_wait                    ; negative: wait for ever
    movsxd rax, eax
    mov ecx, 1000000
    imul rax, rcx
    push rax
    sub rsp, 8
    call spl_monotonic_ns
    add rsp, 8
    pop rcx
    add rax, rcx
    mov [rbp - SPL_DEADLINE], rax

.spl_wait:
    ; sys_poll, not glibc's poll: the wrapper answers -1 in eax and leaves the
    ; reason in errno, so the -4095 test below could never fire and an error
    ; came back as an array of zero revents -- "nothing is ready", forever.
    mov rdi, [rbp - SPL_FDS]
    mov rsi, [rbp - SPL_N]
    mov edx, [rbp - SPL_TMO]
    BLOCKING_CALL sys_poll
    cmp rax, -4095
    jb .spl_polled

    ; EINTR: run the Python handler and wait out what is LEFT.  Linux never
    ; restarts poll(), so SA_RESTART never did this and a retry in the syscall
    ; funnel would start the whole timeout again and run no handler at all --
    ; an unkillable wait.  CPython's select_poll_poll keeps a deadline for
    ; exactly this.
    cmp rax, -4
    jne .spl_failed
    test qword [rel eval_breaker], EB_SIGNAL
    jz .spl_remaining
    extern eval_breaker
    extern signal_run_pending
    call signal_run_pending
    test eax, eax
    jnz .spl_handler_raised

.spl_remaining:
    cmp qword [rbp - SPL_DEADLINE], -1
    je .spl_wait                    ; no timeout to shorten
    call spl_monotonic_ns
    mov rcx, [rbp - SPL_DEADLINE]
    sub rcx, rax                    ; nanoseconds left
    jle .spl_expired
    mov rax, rcx
    xor edx, edx
    mov ecx, 1000000
    div rcx                         ; to milliseconds, rounding down
    mov [rbp - SPL_TMO], eax
    jmp .spl_wait
.spl_expired:
    mov dword [rbp - SPL_TMO], 0
    jmp .spl_wait

.spl_handler_raised:
    jmp .spl_freefail               ; its exception is pending

.spl_failed:
    push rax
    push rax
    mov rdi, [rbp - SPL_FDS]
    call ap_free
    pop rax
    pop rax
    SOCK_CHECK_RET rax, .spl_fail
.spl_polled:
    mov rdi, [rbp - SPL_N]
    call list_new
    test rax, rax
    jz .spl_freefail
    mov [rbp - SPL_OUT], rax
    xor ecx, ecx
    mov [rbp - SPL_I], rcx
.spl_out:
    mov rcx, [rbp - SPL_I]
    cmp rcx, [rbp - SPL_N]
    jae .spl_done
    mov rdx, [rbp - SPL_FDS]
    movzx edi, word [rdx + rcx*8 + PollFd.revents]
    call int_from_i64
    V_PACK rax, rdx
    mov rdi, [rbp - SPL_OUT]
    mov rsi, rax
    call list_append          ; err: a list built here is not being sorted
    inc qword [rbp - SPL_I]
    jmp .spl_out
.spl_done:
    mov rdi, [rbp - SPL_FDS]
    call ap_free
    mov rax, [rbp - SPL_OUT]
    pop rbx
    leave
    ret
.spl_freefail:
    mov rdi, [rbp - SPL_FDS]
    call ap_free
.spl_fail:
    xor eax, eax
    pop rbx
    leave
    ret
.spl_badlist:
    FAIL exc_TypeError_type, "poll() takes a flat list of fd, events pairs", .spl_fail
.spl_args:
    FAIL exc_TypeError_type, "poll() takes exactly 2 arguments", .spl_fail
END_FUNC sock_poll_fn

;; ============================================================================
;; sock_epoll_create_fn(flags) -> the epoll descriptor
;;
;; epoll_create1(2).  The Python half is lib/select.py's epoll object, the
;; same split poll() already uses: the syscalls are here and the registry,
;; the timeout arithmetic and the context manager are Python.
;; ============================================================================
extern sys_epoll_create1
extern sys_epoll_ctl
extern sys_epoll_wait
DEF_FUNC sock_epoll_create_fn, 16       ; + 0 pushes = 16, 16-aligned
    test rsi, rsi
    jz .sec_noflags
    mov rdi, [rdi]
    call sk_int_arg
    ERR_M1 .sec_fail
    mov rdi, rax
    jmp .sec_go
.sec_noflags:
    xor edi, edi
.sec_go:
    call sys_epoll_create1
    SOCK_CHECK_RET rax, .sec_fail
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret
.sec_fail:
    xor eax, eax
    leave
    ret
END_FUNC sock_epoll_create_fn

;; ============================================================================
;; sock_epoll_ctl_fn(epfd, op, fd, events) -> None
;;
;; epoll_ctl(2).  The event's `data` is set to the descriptor itself, which is
;; what lets epoll_wait below answer (fd, events) pairs without a side table.
;;
;; struct epoll_event is PACKED on x86-64: a u32 of events followed by the
;; 8-byte union, twelve bytes in all and not sixteen.  Writing it as two
;; aligned words puts the descriptor four bytes past where the kernel reads
;; it, and every event comes back for descriptor zero.
;; ============================================================================
SEC_EV    equ 16            ; the twelve-byte event, padded to the slot
SEC_FRAME equ 24            ; + 0 pushes = 24... padded to 16 below
DEF_FUNC sock_epoll_ctl_fn, 32
    cmp rsi, 4
    jne .sctl_args
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + 24]                 ; events
    call sk_int_arg
    ERR_M1 .sctl_fail
    mov [rbp - SEC_EV], eax
    mov rdi, [rbx + 16]                 ; fd
    call sk_int_arg
    ERR_M1 .sctl_fail
    mov [rbp - SEC_EV + 4], rax         ; data.u64 = the descriptor
    mov rdi, [rbx + 8]                  ; op
    call sk_int_arg
    ERR_M1 .sctl_fail
    push rax
    mov rdi, [rbx]                      ; epfd
    call sk_int_arg
    ERR_M1 .sctl_fail1
    pop rsi
    mov rdi, rax
    mov rdx, [rbp - SEC_EV + 4]         ; fd, again
    lea rcx, [rbp - SEC_EV]
    call sys_epoll_ctl
    SOCK_CHECK_RET rax, .sctl_fail
    pop rbx
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    ret
.sctl_args:
    SET_EXC exc_TypeError_type, "epoll_ctl() takes exactly 4 arguments"
    leave                       ; nothing pushed yet; rax = 0
    ret
.sctl_fail1:
    pop rcx                     ; the op, parked across the conversion
.sctl_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC sock_epoll_ctl_fn

;; ============================================================================
;; sock_epoll_wait_fn(epfd, maxevents, timeout_ms) -> [fd, events, fd, ...]
;;
;; epoll_wait(2), answering the flat list poll() answers in: one descriptor
;; and one mask per ready file, which the Python half pairs up.
;;
;; EINTR is handled the way poll()'s is, and for the same reason: Linux never
;; restarts epoll_wait, so the Python handler has to run here and the wait
;; resume against a DEADLINE rather than starting its timeout again.
;; ============================================================================
SEW_EVS   equ 8
SEW_MAX   equ 16
SEW_TMO   equ 24
SEW_OUT   equ 32
SEW_I     equ 40
SEW_N     equ 48
SEW_DEADLINE equ 56
SEW_EPFD  equ 64
SEW_FRAME equ 72            ; + 1 push = 80, 16-aligned
DEF_FUNC sock_epoll_wait_fn, SEW_FRAME
    push rbx
    cmp rsi, 3
    jne .sew_args
    mov rbx, rdi
    mov rdi, [rbx]
    call sk_int_arg
    ERR_M1 .sew_fail
    mov [rbp - SEW_EPFD], rax
    mov rdi, [rbx + 8]
    call sk_int_arg
    ERR_M1 .sew_fail
    test rax, rax
    jle .sew_badmax
    mov [rbp - SEW_MAX], rax
    mov rdi, [rbx + 16]
    call sk_int_arg
    ERR_M1 .sew_fail
    mov [rbp - SEW_TMO], rax

    ; Twelve bytes each; the allocation is rounded up so a partial trailing
    ; event can never be written past the end.
    mov rdi, [rbp - SEW_MAX]
    imul rdi, rdi, 12
    add rdi, 16
    call ap_malloc
    test rax, rax
    jz .sew_fail
    mov [rbp - SEW_EVS], rax

    mov qword [rbp - SEW_DEADLINE], -1
    mov rax, [rbp - SEW_TMO]
    test rax, rax
    js .sew_wait
    mov ecx, 1000000
    imul rax, rcx
    push rax
    sub rsp, 8
    call spl_monotonic_ns
    add rsp, 8
    pop rcx
    add rax, rcx
    mov [rbp - SEW_DEADLINE], rax

.sew_wait:
    mov rdi, [rbp - SEW_EPFD]
    mov rsi, [rbp - SEW_EVS]
    mov rdx, [rbp - SEW_MAX]
    mov rcx, [rbp - SEW_TMO]
    BLOCKING_CALL sys_epoll_wait
    cmp rax, -4095
    jb .sew_waited
    cmp rax, -4
    jne .sew_failed
    test qword [rel eval_breaker], EB_SIGNAL
    jz .sew_remaining
    call signal_run_pending
    test eax, eax
    jnz .sew_handler_raised
.sew_remaining:
    cmp qword [rbp - SEW_DEADLINE], -1
    je .sew_wait
    call spl_monotonic_ns
    mov rcx, [rbp - SEW_DEADLINE]
    sub rcx, rax
    jle .sew_expired
    mov rax, rcx
    xor edx, edx
    mov ecx, 1000000
    div rcx
    mov [rbp - SEW_TMO], rax
    jmp .sew_wait
.sew_expired:
    mov qword [rbp - SEW_TMO], 0
    jmp .sew_wait

.sew_handler_raised:
    jmp .sew_freefail               ; its exception is pending

.sew_failed:
    push rax
    push rax
    mov rdi, [rbp - SEW_EVS]
    call ap_free
    pop rax
    pop rax
    SOCK_CHECK_RET rax, .sew_fail

.sew_waited:
    mov [rbp - SEW_N], rax
    mov rdi, rax
    add rdi, rdi
    call list_new
    test rax, rax
    jz .sew_freefail
    mov [rbp - SEW_OUT], rax
    xor ecx, ecx
    mov [rbp - SEW_I], rcx
.sew_out:
    mov rcx, [rbp - SEW_I]
    cmp rcx, [rbp - SEW_N]
    jae .sew_done
    imul rcx, rcx, 12
    mov rdx, [rbp - SEW_EVS]
    mov rdi, [rdx + rcx + 4]            ; data.u64 -- the descriptor
    call int_from_i64
    V_PACK rax, rdx
    mov rdi, [rbp - SEW_OUT]
    mov rsi, rax
    call list_append          ; err: a list built here is not being sorted
    mov rcx, [rbp - SEW_I]
    imul rcx, rcx, 12
    mov rdx, [rbp - SEW_EVS]
    mov edi, [rdx + rcx]                ; the mask
    call int_from_i64
    V_PACK rax, rdx
    mov rdi, [rbp - SEW_OUT]
    mov rsi, rax
    call list_append          ; err: a list built here is not being sorted
    inc qword [rbp - SEW_I]
    jmp .sew_out
.sew_done:
    mov rdi, [rbp - SEW_EVS]
    call ap_free
    mov rax, [rbp - SEW_OUT]
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.sew_freefail:
    mov rdi, [rbp - SEW_EVS]
    call ap_free
.sew_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.sew_badmax:
    FAIL exc_ValueError_type, "maxevents must be positive", .sew_fail
.sew_args:
    FAIL exc_TypeError_type, "epoll_wait() takes exactly 3 arguments", .sew_fail
END_FUNC sock_epoll_wait_fn

;; ============================================================================
;; spl_monotonic_ns() -> rax = CLOCK_MONOTONIC in nanoseconds
;;
;; What poll()'s retry measures its remaining timeout against.  The event
;; loop has one of these too, in eventloop_poll.asm, but that file is one of
;; two interchangeable backends and this is not.
;; ============================================================================
SMN_TS    equ 16            ; struct timespec: two 8-byte fields
SMN_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
extern clock_gettime
DEF_FUNC_LOCAL spl_monotonic_ns, SMN_FRAME
    mov edi, 1                      ; CLOCK_MONOTONIC
    lea rsi, [rbp - SMN_TS]
    call clock_gettime
    mov rax, [rbp - SMN_TS]         ; tv_sec
    mov ecx, 1000000000
    imul rax, rcx
    add rax, [rbp - SMN_TS + 8]     ; tv_nsec
    leave
    ret
END_FUNC spl_monotonic_ns

;; ============================================================================
;; socket_module_create() -> PyObject*
;;
;; The constants are a table rather than a hundred registration blocks, the
;; way errnomod does its 130 errnos.  Their values are Linux's, which is the
;; only platform this interpreter targets; lib/_socket.py re-exports them
;; under the names the stdlib expects.
;; ============================================================================
SMC_DICT  equ 8
SMC_ENT   equ 16
SMC_NAME  equ 24
SMC_FRAME equ 32            ; + 2 pushes = 48
DEF_FUNC socket_module_create, SMC_FRAME
    push rbx
    push r12

    call dict_new
    test rax, rax
    jz .smc_fail
    mov [rbp - SMC_DICT], rax
    mov r12, rax                ; MODULE_ADD_FUNC writes through r12

    MODULE_ADD_FUNC sock_socket_fn,       sk_n_socket
    MODULE_ADD_FUNC sock_close_fn,        sk_n_close
    MODULE_ADD_FUNC sock_dup_fn,          sk_n_dup
    MODULE_ADD_FUNC sock_bind_fn,         sk_n_bind
    MODULE_ADD_FUNC sock_connect_fn,      sk_n_connect
    MODULE_ADD_FUNC sock_connect_ex_fn,   sk_n_connect_ex
    MODULE_ADD_FUNC sock_listen_fn,       sk_n_listen
    MODULE_ADD_FUNC sock_accept_fn,       sk_n_accept
    MODULE_ADD_FUNC sock_shutdown_fn,     sk_n_shutdown
    MODULE_ADD_FUNC sock_send_fn,         sk_n_send
    MODULE_ADD_FUNC sock_recv_fn,         sk_n_recv
    MODULE_ADD_FUNC sock_recvfrom_fn,     sk_n_recvfrom
    MODULE_ADD_FUNC sock_recv_into_fn,    sk_n_recv_into
    MODULE_ADD_FUNC sock_setsockopt_fn,   sk_n_setsockopt
    MODULE_ADD_FUNC sock_getsockopt_fn,   sk_n_getsockopt
    MODULE_ADD_FUNC sock_getsockname_fn,  sk_n_getsockname
    MODULE_ADD_FUNC sock_getpeername_fn,  sk_n_getpeername
    MODULE_ADD_FUNC sock_socketpair_fn,   sk_n_socketpair
    MODULE_ADD_FUNC sock_set_blocking_fn, sk_n_set_blocking
    MODULE_ADD_FUNC sock_get_blocking_fn, sk_n_get_blocking
    MODULE_ADD_FUNC sock_gethostname_fn,  sk_n_gethostname
    MODULE_ADD_FUNC sock_poll_fn,         sk_n_poll
    MODULE_ADD_FUNC sock_epoll_create_fn, sk_n_epoll_create
    MODULE_ADD_FUNC sock_epoll_ctl_fn,    sk_n_epoll_ctl
    MODULE_ADD_FUNC sock_epoll_wait_fn,   sk_n_epoll_wait

    lea rbx, [rel sk_consts]
.smc_loop:
    mov rdi, [rbx]
    test rdi, rdi
    jz .smc_finish
    call str_from_cstr_heap
    test rax, rax
    jz .smc_fail
    mov [rbp - SMC_NAME], rax
    mov rdi, [rbx + 8]
    call int_from_i64
    V_PACK rax, rdx
    mov [rbp - SMC_ENT], rax
    mov rdi, [rbp - SMC_DICT]
    mov rsi, [rbp - SMC_NAME]
    mov rdx, rax
    call dict_set
    ; DECREF_V, not obj_decref: under INT_STRESS=1 every one of these is a
    ; heap int and V_PACK handed back an owned reference.
    mov rax, [rbp - SMC_ENT]
    DECREF_V rax, rcx
    mov rdi, [rbp - SMC_NAME]
    call obj_decref
    add rbx, 16
    jmp .smc_loop

.smc_finish:
    lea rdi, [rel sk_n_module]
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, rax
    mov rsi, [rbp - SMC_DICT]
    call module_new             ; takes a reference of its own
    push rax
    mov rdi, rbx
    call obj_decref
    mov rdi, [rbp - SMC_DICT]
    call obj_decref             ; ours, now that the module holds one
    pop rax
    pop r12
    pop rbx
    leave
    ret
.smc_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC socket_module_create

section .rodata

sk_n_module:       db "_socketcore", 0
sk_n_socket:       db "socket", 0
sk_n_close:        db "close", 0
sk_n_dup:          db "dup", 0
sk_n_bind:         db "bind", 0
sk_n_connect:      db "connect", 0
sk_n_connect_ex:   db "connect_ex", 0
sk_n_listen:       db "listen", 0
sk_n_accept:       db "accept", 0
sk_n_shutdown:     db "shutdown", 0
sk_n_send:         db "send", 0
sk_n_recv:         db "recv", 0
sk_n_recvfrom:     db "recvfrom", 0
sk_n_recv_into:    db "recv_into", 0
sk_n_setsockopt:   db "setsockopt", 0
sk_n_getsockopt:   db "getsockopt", 0
sk_n_getsockname:  db "getsockname", 0
sk_n_getpeername:  db "getpeername", 0
sk_n_socketpair:   db "socketpair", 0
sk_n_set_blocking: db "set_blocking", 0
sk_n_get_blocking: db "get_blocking", 0
sk_n_gethostname:  db "gethostname", 0
sk_n_poll:         db "poll", 0
sk_n_epoll_create: db "epoll_create1", 0
sk_n_epoll_ctl:    db "epoll_ctl", 0
sk_n_epoll_wait:   db "epoll_wait", 0

; One row of the constants table, and the name it is spelled with.  The name
; goes in a section of its own: emitted here it would land in the middle of
; the table, where a pointer belongs.
%macro SKCONST 2
    %defstr %%s %1
    [section .rodata.sknames]
    %%name: db %%s, 0
    __?SECT?__
    dq %%name, %2
%endmacro

align 8
sk_consts:
    ; epoll's, which lib/select.py re-exports.  EPOLLIN and its neighbours
    ; share their values with POLLIN and its, which is Linux's doing and not
    ; a coincidence worth relying on -- they are written out.
    SKCONST EPOLLIN, 0x001
    SKCONST EPOLLPRI, 0x002
    SKCONST EPOLLOUT, 0x004
    SKCONST EPOLLERR, 0x008
    SKCONST EPOLLHUP, 0x010
    SKCONST EPOLLRDNORM, 0x040
    SKCONST EPOLLRDBAND, 0x080
    SKCONST EPOLLWRNORM, 0x100
    SKCONST EPOLLWRBAND, 0x200
    SKCONST EPOLLMSG, 0x400
    SKCONST EPOLLRDHUP, 0x2000
    SKCONST EPOLLEXCLUSIVE, 0x10000000
    SKCONST EPOLLWAKEUP, 0x20000000
    SKCONST EPOLLONESHOT, 0x40000000
    SKCONST EPOLLET, 0x80000000
    SKCONST EPOLL_CLOEXEC, 0o2000000
    SKCONST EPOLL_CTL_ADD, 1
    SKCONST EPOLL_CTL_DEL, 2
    SKCONST EPOLL_CTL_MOD, 3
    SKCONST AF_UNSPEC, 0
    SKCONST AF_UNIX, 1
    SKCONST AF_LOCAL, 1
    SKCONST AF_INET, 2
    SKCONST AF_INET6, 10
    SKCONST AF_NETLINK, 16
    SKCONST AF_PACKET, 17

    SKCONST SOCK_STREAM, 1
    SKCONST SOCK_DGRAM, 2
    SKCONST SOCK_RAW, 3
    SKCONST SOCK_RDM, 4
    SKCONST SOCK_SEQPACKET, 5
    SKCONST SOCK_CLOEXEC, 0o2000000
    SKCONST SOCK_NONBLOCK, 0o4000

    SKCONST SOL_SOCKET, 1
    SKCONST SOL_IP, 0
    SKCONST SOL_TCP, 6
    SKCONST SOL_UDP, 17

    SKCONST SO_DEBUG, 1
    SKCONST SO_REUSEADDR, 2
    SKCONST SO_TYPE, 3
    SKCONST SO_ERROR, 4
    SKCONST SO_DONTROUTE, 5
    SKCONST SO_BROADCAST, 6
    SKCONST SO_SNDBUF, 7
    SKCONST SO_RCVBUF, 8
    SKCONST SO_KEEPALIVE, 9
    SKCONST SO_OOBINLINE, 10
    SKCONST SO_LINGER, 13
    SKCONST SO_REUSEPORT, 15
    SKCONST SO_PASSCRED, 16
    SKCONST SO_PEERCRED, 17
    SKCONST SO_RCVLOWAT, 18
    SKCONST SO_SNDLOWAT, 19
    SKCONST SO_RCVTIMEO, 20
    SKCONST SO_SNDTIMEO, 21
    SKCONST SO_BINDTODEVICE, 25
    SKCONST SO_ACCEPTCONN, 30
    SKCONST SO_PROTOCOL, 38
    SKCONST SO_DOMAIN, 39

    SKCONST IPPROTO_IP, 0
    SKCONST IPPROTO_ICMP, 1
    SKCONST IPPROTO_IGMP, 2
    SKCONST IPPROTO_TCP, 6
    SKCONST IPPROTO_UDP, 17
    SKCONST IPPROTO_IPV6, 41
    SKCONST IPPROTO_RAW, 255

    SKCONST TCP_NODELAY, 1
    SKCONST TCP_MAXSEG, 2
    SKCONST TCP_CORK, 3
    SKCONST TCP_KEEPIDLE, 4
    SKCONST TCP_KEEPINTVL, 5
    SKCONST TCP_KEEPCNT, 6
    SKCONST TCP_QUICKACK, 12
    SKCONST TCP_USER_TIMEOUT, 18

    SKCONST IP_TOS, 1
    SKCONST IP_TTL, 2
    SKCONST IP_HDRINCL, 3
    SKCONST IP_OPTIONS, 4
    SKCONST IP_MULTICAST_IF, 32
    SKCONST IP_MULTICAST_TTL, 33
    SKCONST IP_MULTICAST_LOOP, 34
    SKCONST IP_ADD_MEMBERSHIP, 35
    SKCONST IP_DROP_MEMBERSHIP, 36

    SKCONST IPV6_V6ONLY, 26

    SKCONST MSG_OOB, 1
    SKCONST MSG_PEEK, 2
    SKCONST MSG_DONTROUTE, 4
    SKCONST MSG_CTRUNC, 8
    SKCONST MSG_TRUNC, 32
    SKCONST MSG_DONTWAIT, 64
    SKCONST MSG_EOR, 128
    SKCONST MSG_WAITALL, 256
    SKCONST MSG_NOSIGNAL, 16384

    SKCONST SHUT_RD, 0
    SKCONST SHUT_WR, 1
    SKCONST SHUT_RDWR, 2

    SKCONST SOMAXCONN, 4096

    SKCONST INADDR_ANY, 0
    SKCONST INADDR_LOOPBACK, 0x7f000001
    SKCONST INADDR_BROADCAST, 0xffffffff
    SKCONST INADDR_NONE, 0xffffffff

    SKCONST AI_PASSIVE, 1
    SKCONST AI_CANONNAME, 2
    SKCONST AI_NUMERICHOST, 4
    SKCONST AI_V4MAPPED, 8
    SKCONST AI_ALL, 16
    SKCONST AI_ADDRCONFIG, 32
    SKCONST AI_NUMERICSERV, 1024

    SKCONST NI_NUMERICHOST, 1
    SKCONST NI_NUMERICSERV, 2
    SKCONST NI_NOFQDN, 4
    SKCONST NI_NAMEREQD, 8
    SKCONST NI_DGRAM, 16
    SKCONST NI_MAXHOST, 1025
    SKCONST NI_MAXSERV, 32

    SKCONST EAI_BADFLAGS, -1
    SKCONST EAI_NONAME, -2
    SKCONST EAI_AGAIN, -3
    SKCONST EAI_FAIL, -4
    SKCONST EAI_NODATA, -5
    SKCONST EAI_FAMILY, -6
    SKCONST EAI_SOCKTYPE, -7
    SKCONST EAI_SERVICE, -8
    SKCONST EAI_ADDRFAMILY, -9
    SKCONST EAI_MEMORY, -10
    SKCONST EAI_SYSTEM, -11

    SKCONST POLLIN, 1
    SKCONST POLLPRI, 2
    SKCONST POLLOUT, 4
    SKCONST POLLERR, 8
    SKCONST POLLHUP, 16
    SKCONST POLLNVAL, 32

    dq 0, 0
