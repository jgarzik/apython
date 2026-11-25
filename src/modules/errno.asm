; errnomod.asm - the errno module
;
; Name-to-number for every errno the platform defines, plus errno.errorcode,
; the inverse mapping.  These are frozen Linux x86-64 kernel ABI constants, so
; the table is written out rather than generated at build time -- and
; tests/test_errno.py prints every pair, which run_tests.sh diffs against the
; system CPython, so a typo here cannot survive a test run.

%include "macros.inc"
%include "object.inc"

extern dict_set_str
extern dict_new
extern dict_set
extern module_new
extern str_from_cstr_heap
extern obj_decref
extern obj_dealloc
extern int_from_i64

section .text

;; ============================================================================
;; errno_module_create() -> PyObject*
;;
;; Builds the module dict: one int per name, plus errorcode mapping each
;; number back to its canonical name.  Where two names share a number
;; (EWOULDBLOCK and EAGAIN, EDEADLOCK and EDEADLK) errorcode keeps the one
;; CPython keeps, which is whichever its own errorcode dict ended up with.
;; ============================================================================
EM_DICT  equ 8
EM_CODES equ 16
EM_ENT   equ 24
EM_FRAME equ 32             ; + 2 pushes = 48
DEF_FUNC errno_module_create, EM_FRAME
    push rbx
    push r12

    call dict_new
    mov [rbp - EM_DICT], rax
    call dict_new
    mov [rbp - EM_CODES], rax

    ; --- every name -> its number ---
    lea rbx, [rel errno_names]
.em_loop:
    mov rdi, [rbx]
    test rdi, rdi
    jz .em_codes
    call str_from_cstr_heap
    mov r12, rax                    ; the name str
    mov rdi, [rbx + 8]
    call int_from_i64               ; a fat pair, not a Value
    V_PACK rax, rdx
    mov [rbp - EM_ENT], rax         ; the call below clobbers rdx and rcx
    mov rdi, [rbp - EM_DICT]
    mov rsi, r12
    mov rdx, rax
    call dict_set_str
    ; DECREF_V, not obj_decref: V_PACK boxes an int outside the immediate
    ; range -- every one of these under INT_STRESS=1 -- and hands back an owned
    ; reference, while an immediate owns nothing.  DECREF_V tells them apart.
    mov rax, [rbp - EM_ENT]
    DECREF_V rax, rcx
    mov rdi, r12
    call obj_decref
    add rbx, 16
    jmp .em_loop

    ; --- errorcode: number -> canonical name ---
.em_codes:
    lea rbx, [rel errno_codes]
.em_codes_loop:
    mov rdi, [rbx]
    test rdi, rdi
    jz .em_finish
    call str_from_cstr_heap
    mov r12, rax
    mov rdi, [rbx + 8]
    call int_from_i64
    V_PACK rax, rdx
    mov [rbp - EM_ENT], rax
    mov rdi, [rbp - EM_CODES]
    mov rsi, rax                    ; the number is the key here
    mov rdx, r12
    call dict_set_str
    mov rax, [rbp - EM_ENT]
    DECREF_V rax, rcx               ; see the note in the loop above
    mov rdi, r12
    call obj_decref
    add rbx, 16
    jmp .em_codes_loop

.em_finish:
    lea rdi, [rel errno_s_errorcode]
    call str_from_cstr_heap
    mov r12, rax
    mov rdi, [rbp - EM_DICT]
    mov rsi, r12
    mov rdx, [rbp - EM_CODES]
    call dict_set_str
    mov rdi, r12
    call obj_decref
    mov rdi, [rbp - EM_CODES]
    call obj_decref

    lea rdi, [rel errno_s_name]
    call str_from_cstr_heap
    mov r12, rax
    mov rdi, r12
    mov rsi, [rbp - EM_DICT]
    call module_new
    push rax
    mov rdi, r12
    call obj_decref
    pop rax
    pop r12
    pop rbx
    leave
    ret
END_FUNC errno_module_create

section .rodata
errno_s_errorcode: db "errorcode", 0
errno_s_name:      db "errno", 0

errno_s_E2BIG: db "E2BIG", 0
errno_s_EACCES: db "EACCES", 0
errno_s_EADDRINUSE: db "EADDRINUSE", 0
errno_s_EADDRNOTAVAIL: db "EADDRNOTAVAIL", 0
errno_s_EADV: db "EADV", 0
errno_s_EAFNOSUPPORT: db "EAFNOSUPPORT", 0
errno_s_EAGAIN: db "EAGAIN", 0
errno_s_EALREADY: db "EALREADY", 0
errno_s_EBADE: db "EBADE", 0
errno_s_EBADF: db "EBADF", 0
errno_s_EBADFD: db "EBADFD", 0
errno_s_EBADMSG: db "EBADMSG", 0
errno_s_EBADR: db "EBADR", 0
errno_s_EBADRQC: db "EBADRQC", 0
errno_s_EBADSLT: db "EBADSLT", 0
errno_s_EBFONT: db "EBFONT", 0
errno_s_EBUSY: db "EBUSY", 0
errno_s_ECANCELED: db "ECANCELED", 0
errno_s_ECHILD: db "ECHILD", 0
errno_s_ECHRNG: db "ECHRNG", 0
errno_s_ECOMM: db "ECOMM", 0
errno_s_ECONNABORTED: db "ECONNABORTED", 0
errno_s_ECONNREFUSED: db "ECONNREFUSED", 0
errno_s_ECONNRESET: db "ECONNRESET", 0
errno_s_EDEADLK: db "EDEADLK", 0
errno_s_EDEADLOCK: db "EDEADLOCK", 0
errno_s_EDESTADDRREQ: db "EDESTADDRREQ", 0
errno_s_EDOM: db "EDOM", 0
errno_s_EDOTDOT: db "EDOTDOT", 0
errno_s_EDQUOT: db "EDQUOT", 0
errno_s_EEXIST: db "EEXIST", 0
errno_s_EFAULT: db "EFAULT", 0
errno_s_EFBIG: db "EFBIG", 0
errno_s_EHOSTDOWN: db "EHOSTDOWN", 0
errno_s_EHOSTUNREACH: db "EHOSTUNREACH", 0
errno_s_EIDRM: db "EIDRM", 0
errno_s_EILSEQ: db "EILSEQ", 0
errno_s_EINPROGRESS: db "EINPROGRESS", 0
errno_s_EINTR: db "EINTR", 0
errno_s_EINVAL: db "EINVAL", 0
errno_s_EIO: db "EIO", 0
errno_s_EISCONN: db "EISCONN", 0
errno_s_EISDIR: db "EISDIR", 0
errno_s_EISNAM: db "EISNAM", 0
errno_s_EKEYEXPIRED: db "EKEYEXPIRED", 0
errno_s_EKEYREJECTED: db "EKEYREJECTED", 0
errno_s_EKEYREVOKED: db "EKEYREVOKED", 0
errno_s_EL2HLT: db "EL2HLT", 0
errno_s_EL2NSYNC: db "EL2NSYNC", 0
errno_s_EL3HLT: db "EL3HLT", 0
errno_s_EL3RST: db "EL3RST", 0
errno_s_ELIBACC: db "ELIBACC", 0
errno_s_ELIBBAD: db "ELIBBAD", 0
errno_s_ELIBEXEC: db "ELIBEXEC", 0
errno_s_ELIBMAX: db "ELIBMAX", 0
errno_s_ELIBSCN: db "ELIBSCN", 0
errno_s_ELNRNG: db "ELNRNG", 0
errno_s_ELOOP: db "ELOOP", 0
errno_s_EMEDIUMTYPE: db "EMEDIUMTYPE", 0
errno_s_EMFILE: db "EMFILE", 0
errno_s_EMLINK: db "EMLINK", 0
errno_s_EMSGSIZE: db "EMSGSIZE", 0
errno_s_EMULTIHOP: db "EMULTIHOP", 0
errno_s_ENAMETOOLONG: db "ENAMETOOLONG", 0
errno_s_ENAVAIL: db "ENAVAIL", 0
errno_s_ENETDOWN: db "ENETDOWN", 0
errno_s_ENETRESET: db "ENETRESET", 0
errno_s_ENETUNREACH: db "ENETUNREACH", 0
errno_s_ENFILE: db "ENFILE", 0
errno_s_ENOANO: db "ENOANO", 0
errno_s_ENOBUFS: db "ENOBUFS", 0
errno_s_ENOCSI: db "ENOCSI", 0
errno_s_ENODATA: db "ENODATA", 0
errno_s_ENODEV: db "ENODEV", 0
errno_s_ENOENT: db "ENOENT", 0
errno_s_ENOEXEC: db "ENOEXEC", 0
errno_s_ENOKEY: db "ENOKEY", 0
errno_s_ENOLCK: db "ENOLCK", 0
errno_s_ENOLINK: db "ENOLINK", 0
errno_s_ENOMEDIUM: db "ENOMEDIUM", 0
errno_s_ENOMEM: db "ENOMEM", 0
errno_s_ENOMSG: db "ENOMSG", 0
errno_s_ENONET: db "ENONET", 0
errno_s_ENOPKG: db "ENOPKG", 0
errno_s_ENOPROTOOPT: db "ENOPROTOOPT", 0
errno_s_ENOSPC: db "ENOSPC", 0
errno_s_ENOSR: db "ENOSR", 0
errno_s_ENOSTR: db "ENOSTR", 0
errno_s_ENOSYS: db "ENOSYS", 0
errno_s_ENOTBLK: db "ENOTBLK", 0
errno_s_ENOTCONN: db "ENOTCONN", 0
errno_s_ENOTDIR: db "ENOTDIR", 0
errno_s_ENOTEMPTY: db "ENOTEMPTY", 0
errno_s_ENOTNAM: db "ENOTNAM", 0
errno_s_ENOTRECOVERABLE: db "ENOTRECOVERABLE", 0
errno_s_ENOTSOCK: db "ENOTSOCK", 0
errno_s_ENOTSUP: db "ENOTSUP", 0
errno_s_ENOTTY: db "ENOTTY", 0
errno_s_ENOTUNIQ: db "ENOTUNIQ", 0
errno_s_ENXIO: db "ENXIO", 0
errno_s_EOPNOTSUPP: db "EOPNOTSUPP", 0
errno_s_EOVERFLOW: db "EOVERFLOW", 0
errno_s_EOWNERDEAD: db "EOWNERDEAD", 0
errno_s_EPERM: db "EPERM", 0
errno_s_EPFNOSUPPORT: db "EPFNOSUPPORT", 0
errno_s_EPIPE: db "EPIPE", 0
errno_s_EPROTO: db "EPROTO", 0
errno_s_EPROTONOSUPPORT: db "EPROTONOSUPPORT", 0
errno_s_EPROTOTYPE: db "EPROTOTYPE", 0
errno_s_ERANGE: db "ERANGE", 0
errno_s_EREMCHG: db "EREMCHG", 0
errno_s_EREMOTE: db "EREMOTE", 0
errno_s_EREMOTEIO: db "EREMOTEIO", 0
errno_s_ERESTART: db "ERESTART", 0
errno_s_ERFKILL: db "ERFKILL", 0
errno_s_EROFS: db "EROFS", 0
errno_s_ESHUTDOWN: db "ESHUTDOWN", 0
errno_s_ESOCKTNOSUPPORT: db "ESOCKTNOSUPPORT", 0
errno_s_ESPIPE: db "ESPIPE", 0
errno_s_ESRCH: db "ESRCH", 0
errno_s_ESRMNT: db "ESRMNT", 0
errno_s_ESTALE: db "ESTALE", 0
errno_s_ESTRPIPE: db "ESTRPIPE", 0
errno_s_ETIME: db "ETIME", 0
errno_s_ETIMEDOUT: db "ETIMEDOUT", 0
errno_s_ETOOMANYREFS: db "ETOOMANYREFS", 0
errno_s_ETXTBSY: db "ETXTBSY", 0
errno_s_EUCLEAN: db "EUCLEAN", 0
errno_s_EUNATCH: db "EUNATCH", 0
errno_s_EUSERS: db "EUSERS", 0
errno_s_EWOULDBLOCK: db "EWOULDBLOCK", 0
errno_s_EXDEV: db "EXDEV", 0
errno_s_EXFULL: db "EXFULL", 0

section .data
align 8
errno_names:
    dq errno_s_E2BIG, 7
    dq errno_s_EACCES, 13
    dq errno_s_EADDRINUSE, 98
    dq errno_s_EADDRNOTAVAIL, 99
    dq errno_s_EADV, 68
    dq errno_s_EAFNOSUPPORT, 97
    dq errno_s_EAGAIN, 11
    dq errno_s_EALREADY, 114
    dq errno_s_EBADE, 52
    dq errno_s_EBADF, 9
    dq errno_s_EBADFD, 77
    dq errno_s_EBADMSG, 74
    dq errno_s_EBADR, 53
    dq errno_s_EBADRQC, 56
    dq errno_s_EBADSLT, 57
    dq errno_s_EBFONT, 59
    dq errno_s_EBUSY, 16
    dq errno_s_ECANCELED, 125
    dq errno_s_ECHILD, 10
    dq errno_s_ECHRNG, 44
    dq errno_s_ECOMM, 70
    dq errno_s_ECONNABORTED, 103
    dq errno_s_ECONNREFUSED, 111
    dq errno_s_ECONNRESET, 104
    dq errno_s_EDEADLK, 35
    dq errno_s_EDEADLOCK, 35
    dq errno_s_EDESTADDRREQ, 89
    dq errno_s_EDOM, 33
    dq errno_s_EDOTDOT, 73
    dq errno_s_EDQUOT, 122
    dq errno_s_EEXIST, 17
    dq errno_s_EFAULT, 14
    dq errno_s_EFBIG, 27
    dq errno_s_EHOSTDOWN, 112
    dq errno_s_EHOSTUNREACH, 113
    dq errno_s_EIDRM, 43
    dq errno_s_EILSEQ, 84
    dq errno_s_EINPROGRESS, 115
    dq errno_s_EINTR, 4
    dq errno_s_EINVAL, 22
    dq errno_s_EIO, 5
    dq errno_s_EISCONN, 106
    dq errno_s_EISDIR, 21
    dq errno_s_EISNAM, 120
    dq errno_s_EKEYEXPIRED, 127
    dq errno_s_EKEYREJECTED, 129
    dq errno_s_EKEYREVOKED, 128
    dq errno_s_EL2HLT, 51
    dq errno_s_EL2NSYNC, 45
    dq errno_s_EL3HLT, 46
    dq errno_s_EL3RST, 47
    dq errno_s_ELIBACC, 79
    dq errno_s_ELIBBAD, 80
    dq errno_s_ELIBEXEC, 83
    dq errno_s_ELIBMAX, 82
    dq errno_s_ELIBSCN, 81
    dq errno_s_ELNRNG, 48
    dq errno_s_ELOOP, 40
    dq errno_s_EMEDIUMTYPE, 124
    dq errno_s_EMFILE, 24
    dq errno_s_EMLINK, 31
    dq errno_s_EMSGSIZE, 90
    dq errno_s_EMULTIHOP, 72
    dq errno_s_ENAMETOOLONG, 36
    dq errno_s_ENAVAIL, 119
    dq errno_s_ENETDOWN, 100
    dq errno_s_ENETRESET, 102
    dq errno_s_ENETUNREACH, 101
    dq errno_s_ENFILE, 23
    dq errno_s_ENOANO, 55
    dq errno_s_ENOBUFS, 105
    dq errno_s_ENOCSI, 50
    dq errno_s_ENODATA, 61
    dq errno_s_ENODEV, 19
    dq errno_s_ENOENT, 2
    dq errno_s_ENOEXEC, 8
    dq errno_s_ENOKEY, 126
    dq errno_s_ENOLCK, 37
    dq errno_s_ENOLINK, 67
    dq errno_s_ENOMEDIUM, 123
    dq errno_s_ENOMEM, 12
    dq errno_s_ENOMSG, 42
    dq errno_s_ENONET, 64
    dq errno_s_ENOPKG, 65
    dq errno_s_ENOPROTOOPT, 92
    dq errno_s_ENOSPC, 28
    dq errno_s_ENOSR, 63
    dq errno_s_ENOSTR, 60
    dq errno_s_ENOSYS, 38
    dq errno_s_ENOTBLK, 15
    dq errno_s_ENOTCONN, 107
    dq errno_s_ENOTDIR, 20
    dq errno_s_ENOTEMPTY, 39
    dq errno_s_ENOTNAM, 118
    dq errno_s_ENOTRECOVERABLE, 131
    dq errno_s_ENOTSOCK, 88
    dq errno_s_ENOTSUP, 95
    dq errno_s_ENOTTY, 25
    dq errno_s_ENOTUNIQ, 76
    dq errno_s_ENXIO, 6
    dq errno_s_EOPNOTSUPP, 95
    dq errno_s_EOVERFLOW, 75
    dq errno_s_EOWNERDEAD, 130
    dq errno_s_EPERM, 1
    dq errno_s_EPFNOSUPPORT, 96
    dq errno_s_EPIPE, 32
    dq errno_s_EPROTO, 71
    dq errno_s_EPROTONOSUPPORT, 93
    dq errno_s_EPROTOTYPE, 91
    dq errno_s_ERANGE, 34
    dq errno_s_EREMCHG, 78
    dq errno_s_EREMOTE, 66
    dq errno_s_EREMOTEIO, 121
    dq errno_s_ERESTART, 85
    dq errno_s_ERFKILL, 132
    dq errno_s_EROFS, 30
    dq errno_s_ESHUTDOWN, 108
    dq errno_s_ESOCKTNOSUPPORT, 94
    dq errno_s_ESPIPE, 29
    dq errno_s_ESRCH, 3
    dq errno_s_ESRMNT, 69
    dq errno_s_ESTALE, 116
    dq errno_s_ESTRPIPE, 86
    dq errno_s_ETIME, 62
    dq errno_s_ETIMEDOUT, 110
    dq errno_s_ETOOMANYREFS, 109
    dq errno_s_ETXTBSY, 26
    dq errno_s_EUCLEAN, 117
    dq errno_s_EUNATCH, 49
    dq errno_s_EUSERS, 87
    dq errno_s_EWOULDBLOCK, 11
    dq errno_s_EXDEV, 18
    dq errno_s_EXFULL, 54
    dq 0, 0

align 8
errno_codes:
    dq errno_s_EPERM, 1
    dq errno_s_ENOENT, 2
    dq errno_s_ESRCH, 3
    dq errno_s_EINTR, 4
    dq errno_s_EIO, 5
    dq errno_s_ENXIO, 6
    dq errno_s_E2BIG, 7
    dq errno_s_ENOEXEC, 8
    dq errno_s_EBADF, 9
    dq errno_s_ECHILD, 10
    dq errno_s_EAGAIN, 11
    dq errno_s_ENOMEM, 12
    dq errno_s_EACCES, 13
    dq errno_s_EFAULT, 14
    dq errno_s_ENOTBLK, 15
    dq errno_s_EBUSY, 16
    dq errno_s_EEXIST, 17
    dq errno_s_EXDEV, 18
    dq errno_s_ENODEV, 19
    dq errno_s_ENOTDIR, 20
    dq errno_s_EISDIR, 21
    dq errno_s_EINVAL, 22
    dq errno_s_ENFILE, 23
    dq errno_s_EMFILE, 24
    dq errno_s_ENOTTY, 25
    dq errno_s_ETXTBSY, 26
    dq errno_s_EFBIG, 27
    dq errno_s_ENOSPC, 28
    dq errno_s_ESPIPE, 29
    dq errno_s_EROFS, 30
    dq errno_s_EMLINK, 31
    dq errno_s_EPIPE, 32
    dq errno_s_EDOM, 33
    dq errno_s_ERANGE, 34
    dq errno_s_EDEADLOCK, 35
    dq errno_s_ENAMETOOLONG, 36
    dq errno_s_ENOLCK, 37
    dq errno_s_ENOSYS, 38
    dq errno_s_ENOTEMPTY, 39
    dq errno_s_ELOOP, 40
    dq errno_s_ENOMSG, 42
    dq errno_s_EIDRM, 43
    dq errno_s_ECHRNG, 44
    dq errno_s_EL2NSYNC, 45
    dq errno_s_EL3HLT, 46
    dq errno_s_EL3RST, 47
    dq errno_s_ELNRNG, 48
    dq errno_s_EUNATCH, 49
    dq errno_s_ENOCSI, 50
    dq errno_s_EL2HLT, 51
    dq errno_s_EBADE, 52
    dq errno_s_EBADR, 53
    dq errno_s_EXFULL, 54
    dq errno_s_ENOANO, 55
    dq errno_s_EBADRQC, 56
    dq errno_s_EBADSLT, 57
    dq errno_s_EBFONT, 59
    dq errno_s_ENOSTR, 60
    dq errno_s_ENODATA, 61
    dq errno_s_ETIME, 62
    dq errno_s_ENOSR, 63
    dq errno_s_ENONET, 64
    dq errno_s_ENOPKG, 65
    dq errno_s_EREMOTE, 66
    dq errno_s_ENOLINK, 67
    dq errno_s_EADV, 68
    dq errno_s_ESRMNT, 69
    dq errno_s_ECOMM, 70
    dq errno_s_EPROTO, 71
    dq errno_s_EMULTIHOP, 72
    dq errno_s_EDOTDOT, 73
    dq errno_s_EBADMSG, 74
    dq errno_s_EOVERFLOW, 75
    dq errno_s_ENOTUNIQ, 76
    dq errno_s_EBADFD, 77
    dq errno_s_EREMCHG, 78
    dq errno_s_ELIBACC, 79
    dq errno_s_ELIBBAD, 80
    dq errno_s_ELIBSCN, 81
    dq errno_s_ELIBMAX, 82
    dq errno_s_ELIBEXEC, 83
    dq errno_s_EILSEQ, 84
    dq errno_s_ERESTART, 85
    dq errno_s_ESTRPIPE, 86
    dq errno_s_EUSERS, 87
    dq errno_s_ENOTSOCK, 88
    dq errno_s_EDESTADDRREQ, 89
    dq errno_s_EMSGSIZE, 90
    dq errno_s_EPROTOTYPE, 91
    dq errno_s_ENOPROTOOPT, 92
    dq errno_s_EPROTONOSUPPORT, 93
    dq errno_s_ESOCKTNOSUPPORT, 94
    dq errno_s_ENOTSUP, 95
    dq errno_s_EPFNOSUPPORT, 96
    dq errno_s_EAFNOSUPPORT, 97
    dq errno_s_EADDRINUSE, 98
    dq errno_s_EADDRNOTAVAIL, 99
    dq errno_s_ENETDOWN, 100
    dq errno_s_ENETUNREACH, 101
    dq errno_s_ENETRESET, 102
    dq errno_s_ECONNABORTED, 103
    dq errno_s_ECONNRESET, 104
    dq errno_s_ENOBUFS, 105
    dq errno_s_EISCONN, 106
    dq errno_s_ENOTCONN, 107
    dq errno_s_ESHUTDOWN, 108
    dq errno_s_ETOOMANYREFS, 109
    dq errno_s_ETIMEDOUT, 110
    dq errno_s_ECONNREFUSED, 111
    dq errno_s_EHOSTDOWN, 112
    dq errno_s_EHOSTUNREACH, 113
    dq errno_s_EALREADY, 114
    dq errno_s_EINPROGRESS, 115
    dq errno_s_ESTALE, 116
    dq errno_s_EUCLEAN, 117
    dq errno_s_ENOTNAM, 118
    dq errno_s_ENAVAIL, 119
    dq errno_s_EISNAM, 120
    dq errno_s_EREMOTEIO, 121
    dq errno_s_EDQUOT, 122
    dq errno_s_ENOMEDIUM, 123
    dq errno_s_EMEDIUMTYPE, 124
    dq errno_s_ECANCELED, 125
    dq errno_s_ENOKEY, 126
    dq errno_s_EKEYEXPIRED, 127
    dq errno_s_EKEYREVOKED, 128
    dq errno_s_EKEYREJECTED, 129
    dq errno_s_EOWNERDEAD, 130
    dq errno_s_ENOTRECOVERABLE, 131
    dq errno_s_ERFKILL, 132
    dq 0, 0
