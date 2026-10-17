; ssl.asm - the _sslcore module: OpenSSL's libssl, and nothing else.
;
; The same split _zlibcore/lib/zlib.py and _hashlibcore/lib/_hashlib.py use.
; What is genuinely C lives here -- the calls into libssl and libcrypto, the
; handle table that stands between a Python program and their pointers, and
; the four callbacks OpenSSL insists on calling back into -- and everything a
; Python program sees is lib/_ssl.py: _SSLContext, _SSLSocket, MemoryBIO,
; SSLSession, the exception hierarchy, the constants, the certificate decoder
; and every error message.
;
; What is peculiar to this library is its WIDTH.  zlib is five calls; the
; part of libssl CPython's _ssl.c touches is closer to a hundred, nearly all
; of them a pointer and an int or two in and an int, a string or another
; pointer out.  Writing a hundred wrappers by hand would be a hundred chances
; to misalign a stack, so each one here is a single row -- the C symbol, what
; it returns and what it takes, spelled as letters -- and ONE engine,
; ssl_call, converts the arguments the row names, makes the call and converts
; the answer.  The rows are at the bottom of the file; the letters are:
;
;   argument (one Python argument unless noted)
;     H  a handle -> the pointer it stands for
;     P  a context handle -> SSL_CTX_get0_param(ctx)
;     R  a connection handle -> SSL_get0_param(ssl)
;     T  a context handle -> SSL_CTX_get_cert_store(ctx)
;     M  an index into ssl_methods, CALLED: TLS_method(), BIO_s_mem() ...
;     F  an index into ssl_callbacks, passed as a function pointer; -1 is NULL
;     i  an int
;     s  a str or bytes -> its NUL-terminated data
;     z  the same, or None -> NULL
;     b  a bytes or bytearray -> two C arguments, the data and the length
;     o  an int n -> two C arguments, an n-byte output buffer and n
;     r  a bytes -> two C arguments, a pointer to a pointer to its data (the
;        d2i_* convention, which advances it) and the length
;     q  no Python argument -> a pointer to a zeroed pointer-sized out slot
;     n  no Python argument -> a pointer to a zeroed length out slot
;
;   result
;     i  int (C int)          l  int (C long)         v  None
;     s  const char* -> str, or None for NULL
;     n  the output buffer, as bytes of the length the call returned when it
;        returned more than zero, else that return value as an int
;     f  the whole output buffer when the call returned 1, else the int
;     z  the output buffer read as a NUL-terminated str
;     L  bytes of (returned pointer, the n slot), or None for NULL
;     Q  bytes of (the q slot, the n slot), or None when the q slot is NULL
;     N  the n slot, as an int: what the call wrote through its out pointer
;     A  bytes of (the q slot, the returned length), and the q slot is then
;        OPENSSL_free'd -- the i2d_* convention
;     C S B X E  a new handle owning an SSL_CTX, SSL, BIO, X509, SSL_SESSION
;     H  a new handle BORROWING whatever came back; freeing it frees nothing
;
; A handle is an INDEX into ssl_handles, not a pointer.  A pointer would be an
; integer a Python program could forge and this module would dereference; an
; index is bounds-checked and a freed slot reads back as 0.

%include "macros.inc"
%include "object.inc"

ASM_INIT

extern dict_new
extern dict_set
extern module_new
extern str_from_cstr_heap
extern obj_decref
extern int_from_i64
extern builtin_func_new
extern bytes_new
extern bytes_from_data
extern bytes_type
extern bytearray_type
extern str_type
extern none_singleton
extern ap_malloc
extern ap_realloc
extern ap_free
extern ap_memcpy
extern ap_memset
extern ap_strlen
extern obj_as_index
extern raise_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_MemoryError_type

extern __errno_location
extern CRYPTO_free
extern TLS_method
extern TLS_client_method
extern TLS_server_method
extern BIO_s_mem
extern TLSv1_method
extern TLSv1_1_method
extern TLSv1_2_method
extern SSL_CTX_get0_param
extern SSL_get0_param
extern SSL_CTX_get_cert_store
extern SSL_CTX_free
extern SSL_free
extern BIO_free
extern X509_free
extern SSL_SESSION_free
extern SSL_CTX_set_alpn_select_cb
extern SSL_select_next_proto
extern SSL_get_ex_data

; --- the descriptor every row assembles to --------------------------------
struc SslFn
    .fn:    resq 1      ; the C function
    .tramp: resq 1      ; the builtin's entry, which loads this row
    .name:  resq 1      ; NUL-terminated Python name
    .spec:  resb 8      ; result letter, argument letters, NUL padding
endstruc

; --- one slot of the handle table ----------------------------------------
struc SslHandle
    .ptr:   resq 1      ; the OpenSSL object, 0 when the slot is free
    .kind:  resq 1      ; HK_*: which free function owns it
    .extra: resq 1      ; an ap_malloc block owned with it (ALPN), or 0
endstruc

HK_BORROWED equ 0
HK_CTX      equ 1
HK_SSL      equ 2
HK_BIO      equ 3
HK_X509     equ 4
HK_SESSION  equ 5

SSL_MAX_CARGS equ 6

; libssl's own numbers for the two callbacks that answer with them.
OPENSSL_NPN_NEGOTIATED   equ 1
SSL_TLSEXT_ERR_OK        equ 0
SSL_TLSEXT_ERR_NOACK     equ 3
SSL_CLIENT_HELLO_RETRY   equ -1

SSL_PW_MAX  equ 1024    ; PEM_BUFSIZE: OpenSSL never asks for more

section .data
align 8
ssl_handles:     dq 0       ; SslHandle[], grown by doubling
ssl_handle_cap:  dq 0
ssl_handle_n:    dq 0
ssl_last_errno:  dq 0       ; errno as the last engine call left it
ssl_pw_len:      dq -1      ; -1: no password, so the callback refuses
ssl_keylog:      dq 0       ; lines the keylog callback has queued
ssl_keylog_len:  dq 0
ssl_keylog_cap:  dq 0

; ssl_call's 'M' letter: functions CALLED to produce the argument.  The index
; is lib/_ssl.py's to choose, so the order is part of its contract.
ssl_methods:
    dq TLS_method, TLS_client_method, TLS_server_method, BIO_s_mem
    dq TLSv1_method, TLSv1_1_method, TLSv1_2_method
SSL_N_METHODS equ 7

; ssl_call's 'F' letter: functions passed BY ADDRESS, for OpenSSL to call.
ssl_callbacks:
    dq ssl_pw_cb, ssl_alpn_cb, ssl_hello_cb, ssl_keylog_cb
SSL_N_CALLBACKS equ 4

; What frees each handle kind, indexed by HK_*.  A borrowed handle has none.
ssl_free_fns:
    dq 0, SSL_CTX_free, SSL_free, BIO_free, X509_free, SSL_SESSION_free

section .bss
ssl_pw_buf:      resb SSL_PW_MAX

section .rodata
ssl_modname:     db "_sslcore", 0
sn_errno:        db "errno", 0
sn_free:         db "free", 0
sn_set_password: db "set_password", 0
sn_set_alpn:     db "set_alpn_server", 0
sn_keylog_drain: db "keylog_drain", 0

section .text

;; ============================================================================
;; ssl_handle_at(rdi = handle index) -> rax = SslHandle*, or 0
;;
;; Bounds-checked, because the index came from Python.  A freed slot has a
;; zero pointer and reads as no handle at all.
;; ============================================================================
DEF_FUNC_BARE ssl_handle_at
    xor eax, eax
    test rdi, rdi
    js .sh_no
    cmp rdi, [rel ssl_handle_n]
    jae .sh_no
    imul rax, rdi, SslHandle_size
    add rax, [rel ssl_handles]
    cmp qword [rax + SslHandle.ptr], 0
    jne .sh_ok
    xor eax, eax
.sh_ok:
.sh_no:
    ret
END_FUNC ssl_handle_at

;; ============================================================================
;; ssl_handle_alloc(rdi = pointer, rsi = HK_* kind) -> rax = its index, or -1
;;
;; Reuses the first free slot, so a program that opens and closes a thousand
;; connections keeps a table the size of the most it ever had open at once.
;; ============================================================================
SA_PTR   equ 8
SA_KIND  equ 16
SA_CAP   equ 24
SA_FRAME equ 40             ; + 1 push = 48, 16-aligned
DEF_FUNC_LOCAL ssl_handle_alloc, SA_FRAME
    push rbx
    mov [rbp - SA_PTR], rdi
    mov [rbp - SA_KIND], rsi
    xor ebx, ebx
.sa_scan:
    cmp rbx, [rel ssl_handle_n]
    jae .sa_append
    imul rax, rbx, SslHandle_size
    add rax, [rel ssl_handles]
    cmp qword [rax + SslHandle.ptr], 0
    je .sa_take
    inc rbx
    jmp .sa_scan

.sa_append:
    mov rax, [rel ssl_handle_n]
    cmp rax, [rel ssl_handle_cap]
    jb .sa_have_room
    mov rax, [rel ssl_handle_cap]
    test rax, rax
    jnz .sa_double
    mov eax, 16
    jmp .sa_grow
.sa_double:
    add rax, rax
.sa_grow:
    mov [rbp - SA_CAP], rax
    mov rdi, [rel ssl_handles]
    imul rsi, rax, SslHandle_size
    call ap_realloc
    test rax, rax
    jz .sa_fail
    mov [rel ssl_handles], rax
    mov rcx, [rbp - SA_CAP]
    mov [rel ssl_handle_cap], rcx
.sa_have_room:
    mov rbx, [rel ssl_handle_n]
    inc qword [rel ssl_handle_n]
    imul rax, rbx, SslHandle_size
    add rax, [rel ssl_handles]
.sa_take:
    mov rcx, [rbp - SA_PTR]
    mov [rax + SslHandle.ptr], rcx
    mov rcx, [rbp - SA_KIND]
    mov [rax + SslHandle.kind], rcx
    mov qword [rax + SslHandle.extra], 0
    mov rax, rbx
    pop rbx
    leave
    ret
.sa_fail:
    mov rax, -1
    pop rbx
    leave
    ret
END_FUNC ssl_handle_alloc

;; ============================================================================
;; ssl_val_int(rdi = a Value) -> rax = int64; raises TypeError for a non-index
;; ============================================================================
DEF_FUNC_BARE ssl_val_int
    V_UNPACK rdi, rdx
    jmp obj_as_index
END_FUNC ssl_val_int

;; ============================================================================
;; ssl_val_handle(rdi = a Value) -> rax = SslHandle*; raises ValueError for an
;;   index that is not a live handle
;; ============================================================================
VH_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL ssl_val_handle, VH_FRAME
    call ssl_val_int
    mov rdi, rax
    call ssl_handle_at
    test rax, rax
    jz .vh_bad
    leave
    ret
.vh_bad:
    RAISE exc_ValueError_type, "_sslcore: invalid handle"
END_FUNC ssl_val_handle

;; ============================================================================
;; ssl_val_data(rdi = a Value) -> rax = data pointer, rdx = length; rax = 0 if
;;   it is none of str, bytes or bytearray
;;
;; A str gives its UTF-8, which is NUL-terminated; so is a bytes.  A
;; bytearray's buffer is not promised a terminator, which is why lib/_ssl.py
;; hands only bytes and str to a letter that wants a C string.
;; ============================================================================
DEF_FUNC_BARE ssl_val_data
    V_TEST_PTR rdi, rax
    ja .vd_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .vd_bytes
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .vd_str
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    jne .vd_no
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    mov rax, [rdi + PyByteArrayObject.ob_bytes]
    test rax, rax
    jnz .vd_ret
    lea rax, [rel ssl_pw_buf]       ; an empty bytearray: any valid pointer
.vd_ret:
    ret
.vd_bytes:
    mov rdx, [rdi + PyBytesObject.ob_size]
    lea rax, [rdi + PyBytesObject.data]
    ret
.vd_str:
    mov rdx, [rdi + PyStrObject.ob_size]
    lea rax, [rdi + PyStrObject.data]
    ret
.vd_no:
    xor eax, eax
    xor edx, edx
    ret
END_FUNC ssl_val_data

;; ============================================================================
;; ssl_call(rdi = args, rsi = nargs, rax = the SslFn row) -> rax = a Value
;;
;; The engine every row's builtin jumps to.  Converts each argument the row's
;; letters name, calls the C function with errno cleared, records errno, and
;; converts the result.  Every conversion that can raise runs BEFORE anything
;; is allocated, so a TypeError leaves nothing behind; the one allocation, the
;; 'o' buffer, is freed on the way out.
;; ============================================================================
SC_DESC  equ 8
SC_NARGS equ 16
SC_OBUF  equ 24             ; the 'o' output buffer, or 0
SC_OLEN  equ 32
SC_OIDX  equ 40             ; which C argument the buffer pointer goes in
SC_SQ    equ 48             ; the 'q' out slot
SC_SN    equ 56             ; the 'n' out slot
SC_SR    equ 64             ; the 'r' in/out slot
SC_RET   equ 72             ; what the C function returned
SC_VAL   equ 80             ; the result Value, while the buffer is freed
SC_CARG  equ 128            ; C arguments 0..5 at rbp-128 .. rbp-88
SC_FRAME equ 128            ; + 4 pushes = 160, 16-aligned
DEF_FUNC_LOCAL ssl_call, SC_FRAME
    push rbx
    push r12
    push r13
    push r14
    mov [rbp - SC_DESC], rax
    mov [rbp - SC_NARGS], rsi
    mov rbx, rdi
    xor eax, eax
    mov [rbp - SC_OBUF], rax
    mov [rbp - SC_OLEN], rax
    mov [rbp - SC_SQ], rax
    mov [rbp - SC_SN], rax
    mov [rbp - SC_SR], rax
    mov qword [rbp - SC_OIDX], -1
%assign i 0
%rep SSL_MAX_CARGS
    mov [rbp - SC_CARG + i*8], rax
%assign i i+1
%endrep

    ; How many Python arguments the letters consume: all but 'q' and 'n'.
    mov rcx, [rbp - SC_DESC]
    lea r12, [rcx + SslFn.spec + 1]
    xor edx, edx
    mov rcx, r12
.sc_count:
    movzx eax, byte [rcx]
    test al, al
    jz .sc_counted
    inc rcx
    cmp al, 'q'
    je .sc_count
    cmp al, 'n'
    je .sc_count
    inc rdx
    jmp .sc_count
.sc_counted:
    cmp rdx, [rbp - SC_NARGS]
    jne .sc_nargs

    xor r13d, r13d              ; Python argument index
    xor r14d, r14d              ; C argument index
.sc_arg:
    movzx eax, byte [r12]
    test al, al
    jz .sc_args_done
    inc r12
    cmp al, 'q'
    je .sc_q
    cmp al, 'n'
    je .sc_n
    mov rdi, [rbx + r13*8]
    inc r13
    cmp al, 'i'
    je .sc_i
    cmp al, 'H'
    je .sc_h
    cmp al, 'P'
    je .sc_p
    cmp al, 'R'
    je .sc_r_param
    cmp al, 'T'
    je .sc_t
    cmp al, 's'
    je .sc_s
    cmp al, 'z'
    je .sc_z
    cmp al, 'b'
    je .sc_b
    cmp al, 'o'
    je .sc_o
    cmp al, 'r'
    je .sc_r
    cmp al, 'M'
    je .sc_m
    cmp al, 'F'
    je .sc_f
    RAISE exc_TypeError_type, "_sslcore: bad argument letter"

.sc_q:
    lea rax, [rbp - SC_SQ]
    jmp .sc_put
.sc_n:
    lea rax, [rbp - SC_SN]
    jmp .sc_put
.sc_i:
    call ssl_val_int
    jmp .sc_put
.sc_h:
    call ssl_val_handle
    mov rax, [rax + SslHandle.ptr]
    jmp .sc_put
.sc_p:
    call ssl_val_handle
    mov rdi, [rax + SslHandle.ptr]
    call SSL_CTX_get0_param wrt ..plt
    jmp .sc_put
.sc_r_param:
    call ssl_val_handle
    mov rdi, [rax + SslHandle.ptr]
    call SSL_get0_param wrt ..plt
    jmp .sc_put
.sc_t:
    call ssl_val_handle
    mov rdi, [rax + SslHandle.ptr]
    call SSL_CTX_get_cert_store wrt ..plt
    jmp .sc_put
.sc_z:
    lea rax, [rel none_singleton]
    cmp rdi, rax
    je .sc_put_zero
.sc_s:
    call ssl_val_data
    test rax, rax
    jz .sc_type
    jmp .sc_put
.sc_put_zero:
    xor eax, eax
    jmp .sc_put
.sc_b:
    call ssl_val_data
    test rax, rax
    jz .sc_type
    mov [rbp - SC_CARG + r14*8], rax
    inc r14
    mov rax, rdx
    jmp .sc_put
.sc_r:
    call ssl_val_data
    test rax, rax
    jz .sc_type
    mov [rbp - SC_SR], rax
    lea rax, [rbp - SC_SR]
    mov [rbp - SC_CARG + r14*8], rax
    inc r14
    mov rax, rdx
    jmp .sc_put
.sc_o:
    call ssl_val_int
    test rax, rax
    js .sc_neg
    mov [rbp - SC_OLEN], rax
    mov [rbp - SC_OIDX], r14
    inc r14                     ; the pointer is filled in once allocated
    jmp .sc_put
.sc_m:
    call ssl_val_int
    cmp rax, SSL_N_METHODS
    jae .sc_bad_index
    lea rcx, [rel ssl_methods]
    call [rcx + rax*8]
    jmp .sc_put
.sc_f:
    call ssl_val_int
    cmp rax, -1
    je .sc_put_zero
    cmp rax, SSL_N_CALLBACKS
    jae .sc_bad_index
    lea rcx, [rel ssl_callbacks]
    mov rax, [rcx + rax*8]
.sc_put:
    mov [rbp - SC_CARG + r14*8], rax
    inc r14
    jmp .sc_arg

.sc_args_done:
    ; The output buffer, one byte longer than asked for and that byte a NUL,
    ; so a result read as a C string ends inside it whatever was written.
    mov rcx, [rbp - SC_OIDX]
    test rcx, rcx
    js .sc_call
    mov rdi, [rbp - SC_OLEN]
    inc rdi
    call ap_malloc
    test rax, rax
    jz .sc_nomem
    mov [rbp - SC_OBUF], rax
    mov byte [rax], 0
    mov rcx, [rbp - SC_OLEN]
    mov byte [rax + rcx], 0
    mov rcx, [rbp - SC_OIDX]
    mov [rbp - SC_CARG + rcx*8], rax

.sc_call:
    call __errno_location wrt ..plt
    mov dword [rax], 0
    mov rdi, [rbp - SC_CARG]
    mov rsi, [rbp - SC_CARG + 8]
    mov rdx, [rbp - SC_CARG + 16]
    mov rcx, [rbp - SC_CARG + 24]
    mov r8,  [rbp - SC_CARG + 32]
    mov r9,  [rbp - SC_CARG + 40]
    mov r10, [rbp - SC_DESC]
    mov r10, [r10 + SslFn.fn]
    xor eax, eax                ; no vector arguments, should it be variadic
    call r10
    mov [rbp - SC_RET], rax
    call __errno_location wrt ..plt
    movsxd rax, dword [rax]
    mov [rel ssl_last_errno], rax

    mov rcx, [rbp - SC_DESC]
    movzx eax, byte [rcx + SslFn.spec]
    cmp al, 'i'
    je .sc_ret_i
    cmp al, 'l'
    je .sc_ret_l
    cmp al, 'v'
    je .sc_ret_none
    cmp al, 's'
    je .sc_ret_s
    cmp al, 'n'
    je .sc_ret_n
    cmp al, 'f'
    je .sc_ret_f
    cmp al, 'z'
    je .sc_ret_z
    cmp al, 'L'
    je .sc_ret_L
    cmp al, 'Q'
    je .sc_ret_Q
    cmp al, 'A'
    je .sc_ret_A
    cmp al, 'N'
    je .sc_ret_N
    mov esi, HK_CTX
    cmp al, 'C'
    je .sc_ret_handle
    mov esi, HK_SSL
    cmp al, 'S'
    je .sc_ret_handle
    mov esi, HK_BIO
    cmp al, 'B'
    je .sc_ret_handle
    mov esi, HK_X509
    cmp al, 'X'
    je .sc_ret_handle
    mov esi, HK_SESSION
    cmp al, 'E'
    je .sc_ret_handle
    mov esi, HK_BORROWED
    jmp .sc_ret_handle

.sc_ret_i:
    movsxd rdi, dword [rbp - SC_RET]
    jmp .sc_ret_int
.sc_ret_N:
    movsxd rdi, dword [rbp - SC_SN]
    jmp .sc_ret_int
.sc_ret_l:
    mov rdi, [rbp - SC_RET]
.sc_ret_int:
    call int_from_i64
    V_PACK rax, rdx
    jmp .sc_finish
.sc_ret_none:
    LOAD_NONE rax
    jmp .sc_finish
.sc_ret_s:
    mov rdi, [rbp - SC_RET]
    test rdi, rdi
    jz .sc_ret_none
    call str_from_cstr_heap
    jmp .sc_finish
.sc_ret_n:
    movsxd rsi, dword [rbp - SC_RET]
    test rsi, rsi
    jle .sc_ret_i
    cmp rsi, [rbp - SC_OLEN]
    jbe .sc_ret_n_len
    mov rsi, [rbp - SC_OLEN]
.sc_ret_n_len:
    mov rdi, [rbp - SC_OBUF]
    call bytes_from_data
    jmp .sc_finish
.sc_ret_f:
    cmp dword [rbp - SC_RET], 1
    jne .sc_ret_i
    mov rdi, [rbp - SC_OBUF]
    mov rsi, [rbp - SC_OLEN]
    call bytes_from_data
    jmp .sc_finish
.sc_ret_z:
    mov rdi, [rbp - SC_OBUF]
    call str_from_cstr_heap
    jmp .sc_finish
.sc_ret_L:
    mov rdi, [rbp - SC_RET]
    test rdi, rdi
    jz .sc_ret_none
    mov rsi, [rbp - SC_SN]
    call bytes_from_data
    jmp .sc_finish
.sc_ret_Q:
    mov rdi, [rbp - SC_SQ]
    test rdi, rdi
    jz .sc_ret_none
    mov rsi, [rbp - SC_SN]
    call bytes_from_data
    jmp .sc_finish
.sc_ret_A:
    movsxd rsi, dword [rbp - SC_RET]
    test rsi, rsi
    jle .sc_ret_none
    mov rdi, [rbp - SC_SQ]
    test rdi, rdi
    jz .sc_ret_none
    call bytes_from_data
    mov [rbp - SC_VAL], rax
    mov rdi, [rbp - SC_SQ]
    xor esi, esi
    xor edx, edx
    call CRYPTO_free wrt ..plt
    mov rax, [rbp - SC_VAL]
    jmp .sc_finish
.sc_ret_handle:
    mov rdi, [rbp - SC_RET]
    test rdi, rdi
    jz .sc_ret_none
    call ssl_handle_alloc
    test rax, rax
    js .sc_nomem_after
    mov rdi, rax
    jmp .sc_ret_int

.sc_finish:
    mov [rbp - SC_VAL], rax
    mov rdi, [rbp - SC_OBUF]
    test rdi, rdi
    jz .sc_done
    call ap_free
.sc_done:
    mov rax, [rbp - SC_VAL]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sc_nomem_after:
    ; The object is OpenSSL's and owned by no handle: drop it rather than
    ; leak it, then fail the way an allocation failure fails.
    mov rcx, [rbp - SC_DESC]
    movzx eax, byte [rcx + SslFn.spec]
    mov rdi, [rbp - SC_RET]
    cmp al, 'H'
    je .sc_nomem_free_buf
    ; Every owning letter maps onto ssl_free_fns through the same order.
    lea rcx, [rel ssl_free_fns]
    mov edx, HK_CTX
    cmp al, 'C'
    je .sc_nomem_drop
    mov edx, HK_SSL
    cmp al, 'S'
    je .sc_nomem_drop
    mov edx, HK_BIO
    cmp al, 'B'
    je .sc_nomem_drop
    mov edx, HK_X509
    cmp al, 'X'
    je .sc_nomem_drop
    mov edx, HK_SESSION
.sc_nomem_drop:
    call [rcx + rdx*8]
.sc_nomem_free_buf:
    mov rdi, [rbp - SC_OBUF]
    test rdi, rdi
    jz .sc_nomem
    call ap_free
.sc_nomem:
    RAISE exc_MemoryError_type, "_sslcore: out of memory"
.sc_nargs:
    RAISE exc_TypeError_type, "_sslcore: wrong number of arguments"
.sc_type:
    RAISE exc_TypeError_type, "_sslcore: a str or bytes-like object is required"
.sc_neg:
    RAISE exc_ValueError_type, "_sslcore: negative buffer size"
.sc_bad_index:
    RAISE exc_ValueError_type, "_sslcore: index out of range"
END_FUNC ssl_call

;; ============================================================================
;; _sslcore.errno() -> int
;;
;; errno as the last engine call left it.  An SSL_ERROR_SYSCALL is only
;; meaningful with the errno beside it, and anything Python runs in between
;; -- an allocation, a dict lookup -- may change the live one.
;; ============================================================================
DEF_FUNC ssl_errno
    mov rdi, [rel ssl_last_errno]
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret
END_FUNC ssl_errno

;; ============================================================================
;; _sslcore.free(handle) -> None
;;
;; Frees what the handle owns -- the OpenSSL object through its own free
;; function, and any block kept beside it -- and gives the slot back.  Freeing
;; a borrowed handle frees nothing; freeing twice is not an error, because
;; lib/_ssl.py frees from __del__ and a close() may have got there first.
;; ============================================================================
SF_H     equ 8
SF_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC ssl_free, SF_FRAME
    cmp rsi, 1
    jne .sf_nargs
    mov rdi, [rdi]
    call ssl_val_int
    mov rdi, rax
    call ssl_handle_at
    test rax, rax
    jz .sf_none
    mov [rbp - SF_H], rax
    mov rcx, [rax + SslHandle.kind]
    lea rdx, [rel ssl_free_fns]
    mov rcx, [rdx + rcx*8]
    test rcx, rcx
    jz .sf_extra
    mov rdi, [rax + SslHandle.ptr]
    call rcx
.sf_extra:
    mov rax, [rbp - SF_H]
    mov rdi, [rax + SslHandle.extra]
    test rdi, rdi
    jz .sf_clear
    call ap_free
.sf_clear:
    mov rax, [rbp - SF_H]
    xor ecx, ecx
    mov [rax + SslHandle.ptr], rcx
    mov [rax + SslHandle.kind], rcx
    mov [rax + SslHandle.extra], rcx
.sf_none:
    RET_NONE
    leave
    ret
.sf_nargs:
    RAISE exc_TypeError_type, "_sslcore: wrong number of arguments"
END_FUNC ssl_free

;; ============================================================================
;; _sslcore.set_password(bytes or None) -> None
;;
;; What ssl_pw_cb hands OpenSSL the next time a PEM key asks for one.  The
;; callback cannot call Python, so lib/_ssl.py evaluates a password callable
;; first and parks the answer here for the length of one load.  None means no
;; password, and the callback then refuses rather than letting OpenSSL fall
;; back to prompting on the terminal.
;; ============================================================================
SP_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC ssl_set_password, SP_FRAME
    cmp rsi, 1
    jne .sp_nargs
    mov rdi, [rdi]
    lea rax, [rel none_singleton]
    cmp rdi, rax
    je .sp_clear
    call ssl_val_data
    test rax, rax
    jz .sp_type
    cmp rdx, SSL_PW_MAX
    jae .sp_long
    mov [rel ssl_pw_len], rdx
    lea rdi, [rel ssl_pw_buf]
    mov rsi, rax
    call ap_memcpy
    jmp .sp_done
.sp_clear:
    ; Wipe what was there: a key's password should not outlive its load.
    lea rdi, [rel ssl_pw_buf]
    xor esi, esi
    mov edx, SSL_PW_MAX
    call ap_memset
    mov qword [rel ssl_pw_len], -1
.sp_done:
    RET_NONE
    leave
    ret
.sp_nargs:
    RAISE exc_TypeError_type, "_sslcore: wrong number of arguments"
.sp_type:
    RAISE exc_TypeError_type, "password should be a string or bytes"
.sp_long:
    RAISE exc_ValueError_type, "password cannot be longer than 1023 bytes"
END_FUNC ssl_set_password

;; ============================================================================
;; ssl_pw_cb(rdi = buf, esi = size, edx = rwflag, rcx = userdata) -> eax = the
;;   password's length, or -1 when there is none
;;
;; OpenSSL's pem_password_cb.  Called from inside a PEM read, with whatever
;; set_password parked.
;; ============================================================================
DEF_FUNC ssl_pw_cb
    mov rax, [rel ssl_pw_len]
    test rax, rax
    js .pw_none
    movsxd rdx, esi
    cmp rax, rdx
    jbe .pw_fits
    mov rax, rdx
.pw_fits:
    push rax
    sub rsp, 8
    mov rdx, rax
    lea rsi, [rel ssl_pw_buf]
    call ap_memcpy
    add rsp, 8
    pop rax
    leave
    ret
.pw_none:
    mov eax, -1
    leave
    ret
END_FUNC ssl_pw_cb

;; ============================================================================
;; _sslcore.set_alpn_server(ctx handle, wire-format protocols) -> None
;;
;; The server half of ALPN: OpenSSL asks a callback to choose, and the
;; callback chooses from this list.  The list is copied into a block the
;; context's handle owns -- [length, bytes] -- because the protocol the
;; callback picks is returned as a pointer INTO it and must outlive the
;; handshake.
;; ============================================================================
SL_H     equ 8
SL_DATA  equ 16
SL_LEN   equ 24
SL_BLK   equ 32
SL_FRAME equ 48             ; + 0 pushes = 48, 16-aligned
DEF_FUNC ssl_set_alpn_server, SL_FRAME
    cmp rsi, 2
    jne .sl_nargs
    push rdi
    sub rsp, 8
    mov rdi, [rdi + 8]
    call ssl_val_data
    add rsp, 8
    pop rdi
    test rax, rax
    jz .sl_type
    mov [rbp - SL_DATA], rax
    mov [rbp - SL_LEN], rdx
    mov rdi, [rdi]
    call ssl_val_handle
    mov [rbp - SL_H], rax

    mov rdi, [rbp - SL_LEN]
    add rdi, 8
    call ap_malloc
    test rax, rax
    jz .sl_nomem
    mov [rbp - SL_BLK], rax
    mov rcx, [rbp - SL_LEN]
    mov [rax], rcx
    lea rdi, [rax + 8]
    mov rsi, [rbp - SL_DATA]
    mov rdx, rcx
    call ap_memcpy

    mov rax, [rbp - SL_H]
    mov rdi, [rax + SslHandle.extra]
    test rdi, rdi
    jz .sl_install
    call ap_free
.sl_install:
    mov rax, [rbp - SL_H]
    mov rdx, [rbp - SL_BLK]
    mov [rax + SslHandle.extra], rdx
    mov rdi, [rax + SslHandle.ptr]
    lea rsi, [rel ssl_alpn_cb]
    call SSL_CTX_set_alpn_select_cb wrt ..plt
    RET_NONE
    leave
    ret
.sl_nargs:
    RAISE exc_TypeError_type, "_sslcore: wrong number of arguments"
.sl_type:
    RAISE exc_TypeError_type, "_sslcore: a bytes-like object is required"
.sl_nomem:
    RAISE exc_MemoryError_type, "_sslcore: out of memory"
END_FUNC ssl_set_alpn_server

;; ============================================================================
;; ssl_alpn_cb(rdi = ssl, rsi = out**, rdx = outlen*, rcx = client list,
;;   r8d = its length, r9 = the [length, bytes] block) -> eax = TLSEXT code
;;
;; SSL_select_next_proto does the choosing, in the server's order of
;; preference, as CPython's _selectALPN_cb does.  No overlap is NOACK: the
;; handshake goes on without a protocol rather than failing.
;; ============================================================================
DEF_FUNC ssl_alpn_cb
    mov rax, rsi                ; out
    mov r10, rdx                ; outlen
    mov rdi, rax
    mov rsi, r10
    ; client list and its length move up two places; the server list comes
    ; from the block.
    mov r10, rcx
    mov r11d, r8d
    lea rdx, [r9 + 8]
    mov ecx, [r9]
    mov r8, r10
    mov r9d, r11d
    call SSL_select_next_proto wrt ..plt
    cmp eax, OPENSSL_NPN_NEGOTIATED
    jne .ac_noack
    mov eax, SSL_TLSEXT_ERR_OK
    leave
    ret
.ac_noack:
    mov eax, SSL_TLSEXT_ERR_NOACK
    leave
    ret
END_FUNC ssl_alpn_cb

;; ============================================================================
;; ssl_hello_cb(rdi = ssl, rsi = alert*, rdx = arg) -> eax = 1, 0 or -1
;;
;; The client-hello callback, and the way an SNI callback written in Python
;; runs without OpenSSL ever calling Python.  The connection's ex_data slot 0
;; is lib/_ssl.py's verdict: 0 means not yet asked, so the handshake is PAUSED
;; (SSL_CLIENT_HELLO_RETRY, which SSL_do_handshake reports as
;; SSL_ERROR_WANT_CLIENT_HELLO_CB); Python then reads the name, runs the
;; callback, records 1 to go on or (alert << 8) | 2 to fail with that alert,
;; and calls SSL_do_handshake again.
;; ============================================================================
HC_ALERT equ 8
HC_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC ssl_hello_cb, HC_FRAME
    mov [rbp - HC_ALERT], rsi
    xor esi, esi
    call SSL_get_ex_data wrt ..plt
    test rax, rax
    jz .hc_retry
    cmp rax, 1
    je .hc_go
    shr rax, 8
    mov rcx, [rbp - HC_ALERT]
    mov [rcx], eax
    xor eax, eax
    leave
    ret
.hc_go:
    mov eax, 1
    leave
    ret
.hc_retry:
    mov eax, SSL_CLIENT_HELLO_RETRY
    leave
    ret
END_FUNC ssl_hello_cb

;; ============================================================================
;; ssl_keylog_cb(rdi = ssl, rsi = line) -> void
;;
;; The keylog callback.  It cannot write the file itself -- the file is a
;; Python object's business -- so it queues the line and its newline, and
;; lib/_ssl.py drains the queue into keylog_filename after each operation.
;; ============================================================================
KL_LINE  equ 8
KL_LEN   equ 16
KL_FRAME equ 32             ; + 0 pushes = 32, 16-aligned
DEF_FUNC ssl_keylog_cb, KL_FRAME
    mov [rbp - KL_LINE], rsi
    mov rdi, rsi
    call ap_strlen
    mov [rbp - KL_LEN], rax
    ; Room for the line and its newline.
    mov rcx, [rel ssl_keylog_len]
    lea rcx, [rcx + rax + 1]
    cmp rcx, [rel ssl_keylog_cap]
    jbe .kl_room
    add rcx, rcx
    mov [rel ssl_keylog_cap], rcx
    mov rdi, [rel ssl_keylog]
    mov rsi, rcx
    call ap_realloc
    test rax, rax
    jz .kl_lost
    mov [rel ssl_keylog], rax
.kl_room:
    mov rdi, [rel ssl_keylog]
    add rdi, [rel ssl_keylog_len]
    mov rsi, [rbp - KL_LINE]
    mov rdx, [rbp - KL_LEN]
    call ap_memcpy
    mov rcx, [rbp - KL_LEN]
    mov rdx, [rel ssl_keylog]
    add rdx, [rel ssl_keylog_len]
    mov byte [rdx + rcx], 10
    inc rcx
    add [rel ssl_keylog_len], rcx
    leave
    ret
.kl_lost:
    ; Out of memory: the old block is still ours; keep its capacity honest.
    mov qword [rel ssl_keylog], 0
    mov qword [rel ssl_keylog_len], 0
    mov qword [rel ssl_keylog_cap], 0
    leave
    ret
END_FUNC ssl_keylog_cb

;; ============================================================================
;; _sslcore.keylog_drain() -> bytes
;;
;; Every line the keylog callback queued since the last drain, and the queue
;; emptied.
;; ============================================================================
KD_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC ssl_keylog_drain, KD_FRAME
    mov rdi, [rel ssl_keylog]
    mov rsi, [rel ssl_keylog_len]
    test rsi, rsi
    jz .kd_empty
    call bytes_from_data
    mov qword [rel ssl_keylog_len], 0
    mov edx, TAG_PTR
    leave
    ret
.kd_empty:
    xor edi, edi
    call bytes_new
    mov edx, TAG_PTR
    leave
    ret
END_FUNC ssl_keylog_drain

;; ============================================================================
;; SSLFN pyname, csym, "result", "arguments" -- one row of the engine's table
;;
;; Assembles the SslFn descriptor into .data (contiguous, so the module
;; builder walks them as an array), its name into .rodata, and a two-line
;; trampoline into .text that loads the row and jumps to ssl_call.  The spec
;; is padded to eight bytes; a row with more than seven letters fails to
;; assemble, by the negative `times`.
;; ============================================================================
%macro SSLFN 4
    extern %2
    %defstr SSLFN_NAME %1
section .rodata
%%name: db SSLFN_NAME, 0
section .data
%%desc: dq %2, %%tramp, %%name
%%spec: db %3, %4
    times 8 - ($ - %%spec) db 0
section .text
%%tramp:
    lea rax, [rel %%desc]
    jmp ssl_call
%endmacro

section .data
align 8
ssl_fn_table:
section .text

; --- the library, its errors, its object names ----------------------------
SSLFN OpenSSL_version,          OpenSSL_version,          "s", "i"
SSLFN OpenSSL_version_num,      OpenSSL_version_num,      "l", ""
SSLFN RAND_bytes,               RAND_bytes,               "f", "o"
SSLFN RAND_status,              RAND_status,              "i", ""
SSLFN RAND_seed,                RAND_seed,                "v", "b"
SSLFN ERR_get_error,            ERR_get_error,            "l", ""
SSLFN ERR_peek_last_error,      ERR_peek_last_error,      "l", ""
SSLFN ERR_clear_error,          ERR_clear_error,          "v", ""
SSLFN ERR_reason_error_string,  ERR_reason_error_string,  "s", "i"
SSLFN ERR_lib_error_string,     ERR_lib_error_string,     "s", "i"
SSLFN X509_verify_cert_error_string, X509_verify_cert_error_string, "s", "i"
SSLFN OBJ_txt2nid,              OBJ_txt2nid,              "i", "s"
SSLFN OBJ_sn2nid,               OBJ_sn2nid,               "i", "s"
SSLFN OBJ_nid2sn,               OBJ_nid2sn,               "s", "i"
SSLFN OBJ_nid2ln,               OBJ_nid2ln,               "s", "i"
SSLFN OBJ_nid2obj,              OBJ_nid2obj,              "H", "i"
SSLFN OBJ_obj2txt,              OBJ_obj2txt,              "n", "oHi"
SSLFN OBJ_txt2obj,              OBJ_txt2obj,              "H", "si"
SSLFN OBJ_obj2nid,              OBJ_obj2nid,              "i", "H"
SSLFN ASN1_OBJECT_free,         ASN1_OBJECT_free,         "v", "H"
SSLFN X509_get_default_cert_file_env, X509_get_default_cert_file_env, "s", ""
SSLFN X509_get_default_cert_file, X509_get_default_cert_file, "s", ""
SSLFN X509_get_default_cert_dir_env, X509_get_default_cert_dir_env, "s", ""
SSLFN X509_get_default_cert_dir, X509_get_default_cert_dir, "s", ""

; --- the context ----------------------------------------------------------
SSLFN SSL_CTX_new,              SSL_CTX_new,              "C", "M"
SSLFN SSL_CTX_get_options,      SSL_CTX_get_options,      "l", "H"
SSLFN SSL_CTX_set_options,      SSL_CTX_set_options,      "l", "Hi"
SSLFN SSL_CTX_clear_options,    SSL_CTX_clear_options,    "l", "Hi"
SSLFN SSL_CTX_ctrl,             SSL_CTX_ctrl,             "l", "Hiiz"
SSLFN SSL_CTX_ctrl_ptr,         SSL_CTX_ctrl,             "l", "HiiH"
SSLFN SSL_CTX_set_verify,       SSL_CTX_set_verify,       "v", "HiF"
SSLFN SSL_CTX_get_verify_mode,  SSL_CTX_get_verify_mode,  "i", "H"
SSLFN SSL_CTX_set_cipher_list,  SSL_CTX_set_cipher_list,  "i", "Hs"
SSLFN SSL_CTX_set_ciphersuites, SSL_CTX_set_ciphersuites, "i", "Hs"
SSLFN SSL_CTX_get_ciphers,      SSL_CTX_get_ciphers,      "H", "H"
SSLFN SSL_CTX_load_verify_locations, SSL_CTX_load_verify_locations, "i", "Hzz"
SSLFN SSL_CTX_set_default_verify_paths, SSL_CTX_set_default_verify_paths, "i", "H"
SSLFN SSL_CTX_use_certificate_chain_file, SSL_CTX_use_certificate_chain_file, "i", "Hs"
SSLFN SSL_CTX_use_PrivateKey_file, SSL_CTX_use_PrivateKey_file, "i", "Hsi"
SSLFN SSL_CTX_check_private_key, SSL_CTX_check_private_key, "i", "H"
SSLFN SSL_CTX_set_default_passwd_cb, SSL_CTX_set_default_passwd_cb, "v", "HF"
SSLFN SSL_CTX_set_alpn_protos,  SSL_CTX_set_alpn_protos,  "i", "Hb"
SSLFN SSL_CTX_set_client_hello_cb, SSL_CTX_set_client_hello_cb, "v", "HFz"
SSLFN SSL_CTX_set_keylog_callback, SSL_CTX_set_keylog_callback, "v", "HF"
SSLFN SSL_CTX_set_num_tickets,  SSL_CTX_set_num_tickets,  "i", "Hi"
SSLFN SSL_CTX_get_num_tickets,  SSL_CTX_get_num_tickets,  "l", "H"
SSLFN SSL_CTX_get_security_level, SSL_CTX_get_security_level, "i", "H"
SSLFN SSL_CTX_set_post_handshake_auth, SSL_CTX_set_post_handshake_auth, "v", "Hi"
SSLFN SSL_CTX_set_session_id_context, SSL_CTX_set_session_id_context, "i", "Hb"
SSLFN X509_VERIFY_PARAM_get_flags, X509_VERIFY_PARAM_get_flags, "l", "P"
SSLFN X509_VERIFY_PARAM_set_flags, X509_VERIFY_PARAM_set_flags, "i", "Pi"
SSLFN X509_VERIFY_PARAM_clear_flags, X509_VERIFY_PARAM_clear_flags, "i", "Pi"
SSLFN X509_VERIFY_PARAM_set_hostflags, X509_VERIFY_PARAM_set_hostflags, "v", "Pi"
SSLFN X509_STORE_add_cert,      X509_STORE_add_cert,      "i", "TH"
SSLFN X509_STORE_get0_objects,  X509_STORE_get0_objects,  "H", "T"
SSLFN X509_OBJECT_get_type,     X509_OBJECT_get_type,     "i", "H"
SSLFN X509_OBJECT_get0_X509,    X509_OBJECT_get0_X509,    "H", "H"
SSLFN OPENSSL_sk_num,           OPENSSL_sk_num,           "i", "H"
SSLFN OPENSSL_sk_value,         OPENSSL_sk_value,         "H", "Hi"
SSLFN d2i_X509,                 d2i_X509,                 "X", "zr"
SSLFN BIO_new_mem_buf,          BIO_new_mem_buf,          "B", "b"
SSLFN PEM_read_bio_X509,        PEM_read_bio_X509,        "X", "HzFz"
SSLFN d2i_X509_bio,             d2i_X509_bio,             "X", "Hz"
SSLFN X509_check_ca,            X509_check_ca,            "i", "H"
SSLFN i2d_X509,                 i2d_X509,                 "A", "Hq"
SSLFN BIO_new_file,             BIO_new_file,             "B", "ss"
SSLFN PEM_read_bio_DHparams,    PEM_read_bio_DHparams,    "H", "Hzzz"
SSLFN DH_free,                  DH_free,                  "v", "H"

; --- the connection -------------------------------------------------------
SSLFN SSL_new,                  SSL_new,                  "S", "H"
SSLFN SSL_set_fd,               SSL_set_fd,               "i", "Hi"
SSLFN SSL_set_bio,              SSL_set_bio,              "v", "HHH"
SSLFN BIO_up_ref,               BIO_up_ref,               "i", "H"
SSLFN SSL_set_connect_state,    SSL_set_connect_state,    "v", "H"
SSLFN SSL_set_accept_state,     SSL_set_accept_state,     "v", "H"
SSLFN SSL_ctrl,                 SSL_ctrl,                 "l", "Hiiz"
SSLFN X509_VERIFY_PARAM_set1_host, X509_VERIFY_PARAM_set1_host, "i", "Rb"
SSLFN X509_VERIFY_PARAM_set1_ip, X509_VERIFY_PARAM_set1_ip, "i", "Rb"
SSLFN SSL_do_handshake,         SSL_do_handshake,         "i", "H"
SSLFN SSL_read,                 SSL_read,                 "n", "Ho"
SSLFN SSL_write,                SSL_write,                "i", "Hb"
SSLFN SSL_pending,              SSL_pending,              "i", "H"
SSLFN SSL_shutdown,             SSL_shutdown,             "i", "H"
SSLFN SSL_get_shutdown,         SSL_get_shutdown,         "i", "H"
SSLFN SSL_set_shutdown,         SSL_set_shutdown,         "v", "Hi"
SSLFN SSL_get_error,            SSL_get_error,            "i", "Hi"
SSLFN SSL_get_verify_result,    SSL_get_verify_result,    "l", "H"
SSLFN SSL_get_version,          SSL_get_version,          "s", "H"
SSLFN SSL_get_current_cipher,   SSL_get_current_cipher,   "H", "H"
SSLFN SSL_get_ciphers,          SSL_get_ciphers,          "H", "H"
SSLFN SSL_get_client_ciphers,   SSL_get_client_ciphers,   "H", "H"
SSLFN SSL_get0_alpn_selected,   SSL_get0_alpn_selected,   "Q", "Hqn"
SSLFN SSL_get_finished,         SSL_get_finished,         "n", "Ho"
SSLFN SSL_get_peer_finished,    SSL_get_peer_finished,    "n", "Ho"
SSLFN SSL_session_reused,       SSL_session_reused,       "i", "H"
SSLFN SSL_get1_session,         SSL_get1_session,         "E", "H"
SSLFN SSL_set_session,          SSL_set_session,          "i", "HH"
SSLFN SSL_get1_peer_certificate, SSL_get1_peer_certificate, "X", "H"
SSLFN SSL_get_peer_cert_chain,  SSL_get_peer_cert_chain,  "H", "H"
SSLFN SSL_get0_verified_chain,  SSL_get0_verified_chain,  "H", "H"
SSLFN SSL_verify_client_post_handshake, SSL_verify_client_post_handshake, "i", "H"
SSLFN SSL_get_verify_mode,      SSL_get_verify_mode,      "i", "H"
SSLFN SSL_set_verify,           SSL_set_verify,           "v", "HiF"
SSLFN SSL_set_post_handshake_auth, SSL_set_post_handshake_auth, "v", "Hi"
SSLFN SSL_set_SSL_CTX,          SSL_set_SSL_CTX,          "H", "HH"
SSLFN SSL_set_ex_data,          SSL_set_ex_data,          "i", "Hii"
SSLFN SSL_client_hello_get0_ext, SSL_client_hello_get0_ext, "Q", "Hiqn"
SSLFN SSL_get_servername,       SSL_get_servername,       "s", "Hi"
SSLFN SSL_is_init_finished,     SSL_is_init_finished,     "i", "H"
SSLFN SSL_get_current_compression, SSL_get_current_compression, "H", "H"
SSLFN SSL_COMP_get_name,        SSL_COMP_get_name,        "s", "H"

; --- ciphers and sessions -------------------------------------------------
SSLFN SSL_CIPHER_get_name,      SSL_CIPHER_get_name,      "s", "H"
SSLFN SSL_CIPHER_get_version,   SSL_CIPHER_get_version,   "s", "H"
SSLFN SSL_CIPHER_get_bits,      SSL_CIPHER_get_bits,      "i", "Hz"
SSLFN SSL_CIPHER_get_alg_bits,  SSL_CIPHER_get_bits,      "N", "Hn"
SSLFN SSL_CIPHER_get_id,        SSL_CIPHER_get_id,        "l", "H"
SSLFN SSL_CIPHER_is_aead,       SSL_CIPHER_is_aead,       "i", "H"
SSLFN SSL_CIPHER_get_cipher_nid, SSL_CIPHER_get_cipher_nid, "i", "H"
SSLFN SSL_CIPHER_get_digest_nid, SSL_CIPHER_get_digest_nid, "i", "H"
SSLFN SSL_CIPHER_get_kx_nid,    SSL_CIPHER_get_kx_nid,    "i", "H"
SSLFN SSL_CIPHER_get_auth_nid,  SSL_CIPHER_get_auth_nid,  "i", "H"
SSLFN SSL_CIPHER_description,   SSL_CIPHER_description,   "z", "Ho"
SSLFN SSL_SESSION_get_id,       SSL_SESSION_get_id,       "L", "Hn"
SSLFN SSL_SESSION_get_time,     SSL_SESSION_get_time,     "l", "H"
SSLFN SSL_SESSION_get_timeout,  SSL_SESSION_get_timeout,  "l", "H"
SSLFN SSL_SESSION_get_ticket_lifetime_hint, SSL_SESSION_get_ticket_lifetime_hint, "l", "H"
SSLFN SSL_SESSION_has_ticket,   SSL_SESSION_has_ticket,   "i", "H"

; --- memory BIOs ----------------------------------------------------------
SSLFN BIO_new,                  BIO_new,                  "B", "M"
SSLFN BIO_write,                BIO_write,                "i", "Hb"
SSLFN BIO_read,                 BIO_read,                 "n", "Ho"
SSLFN BIO_ctrl_pending,         BIO_ctrl_pending,         "l", "H"
SSLFN BIO_ctrl,                 BIO_ctrl,                 "l", "Hiiz"
SSLFN BIO_clear_flags,          BIO_clear_flags,          "v", "Hi"

section .data
ssl_fn_table_end:
section .text

;; ============================================================================
;; ssl_module_create() -> PyObject*
;;
;; Every row of the table, then the five functions that are not rows.
;; ============================================================================
SM_FRAME equ 8              ; + 3 pushes = 32, 16-aligned
DEF_FUNC ssl_module_create, SM_FRAME
    push rbx
    push r12
    push r13

    call dict_new
    mov r12, rax                ; MODULE_ADD_FUNC reads the dict from r12

    lea rbx, [rel ssl_fn_table]
.sm_row:
    lea rax, [rel ssl_fn_table_end]
    cmp rbx, rax
    jae .sm_rows_done
    mov rdi, [rbx + SslFn.tramp]
    mov rsi, [rbx + SslFn.name]
    call builtin_func_new
    mov r13, rax
    mov rdi, [rbx + SslFn.name]
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    mov rdi, r12
    mov rsi, rax
    mov rdx, r13
    call dict_set
    add rsp, 8
    pop rdi
    call obj_decref
    mov rdi, r13
    call obj_decref
    add rbx, SslFn_size
    jmp .sm_row
.sm_rows_done:

    MODULE_ADD_FUNC ssl_errno,           sn_errno
    MODULE_ADD_FUNC ssl_free,            sn_free
    MODULE_ADD_FUNC ssl_set_password,    sn_set_password
    MODULE_ADD_FUNC ssl_set_alpn_server, sn_set_alpn
    MODULE_ADD_FUNC ssl_keylog_drain,    sn_keylog_drain

    lea rdi, [rel ssl_modname]
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r12
    call module_new
    mov r13, rax
    mov rdi, rbx
    call obj_decref             ; module_new took its own
    mov rdi, r12
    call obj_decref
    mov rax, r13

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC ssl_module_create
