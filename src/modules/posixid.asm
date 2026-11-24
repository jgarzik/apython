;; ============================================================================
;; posixid.asm -- who the process is, what it may do, and the numbers it is
;; described by.
;;
;; The credential and process-group calls, the resource questions
;; (sched_getaffinity, cpu_count, sysconf, times), the descriptor calls that
;; posix.asm had no room for (pread, pwrite, sendfile, fchdir, statvfs,
;; get_terminal_size, pipe2, getrandom, mkfifo), and the constant blocks
;; -- O_*, EX_*, ST_*, SCHED_*, PRIO_*, SEEK_*, GRND_*, RTLD_*, RWF_*,
;; POSIX_FADV_*, CLD_*, P_* -- that every one of them is spelled in terms of.
;;
;; A third file rather than a third of posix.asm, which is 200 bytes below the
;; 100k cap that src/compiler/lint.py enforces; posixdir.asm was split off for
;; the same reason and is registered the same way.
;;
;; lib/os.py is CPython's verbatim file, so nearly all of this surfaces under
;; its own name the moment it is here: os.cpu_count, os.get_terminal_size,
;; os.times and the rest are thin wrappers or plain re-exports.
;;
;; The constants are a TABLE rather than a run of MODULE_ADD_INT calls, the
;; way socket.asm's SKCONST table is: one line per constant, the name derived
;; from the symbol, and no chance of a name and a value drifting apart.
;; ============================================================================

%include "src/include/object.inc"
%include "src/include/macros.inc"
%include "src/include/value.inc"

extern posix_int_arg
extern set_oserror
extern posix_set_missing
extern int_from_i64
extern list_new
extern list_append
extern tuple_new
extern str_from_cstr_heap
extern none_singleton
extern obj_decref
extern obj_dealloc
extern dict_set
extern dict_new
extern ap_malloc
extern ap_free
extern exc_TypeError_type
extern exc_ValueError_type
extern set_exception
extern builtin_type_new
extern structseq_new
extern terminal_size_type
extern structseq_init_type
extern structseq_dealloc
extern structseq_repr
extern structseq_getattr
extern type_type
extern sys_ioctl
extern sys_getrandom
extern sys_pipe2
extern str_type

;; The syscalls this file is the only user of.  runtime.asm holds the ones
;; more than one module wants; these are spelled here, beside the functions
;; that make them, rather than at a distance from their only caller.
SYS_getpid          equ 39
SYS_times           equ 100
SYS_getuid          equ 102
SYS_getgid          equ 104
SYS_setuid          equ 105
SYS_setgid          equ 106
SYS_geteuid         equ 107
SYS_getegid         equ 108
SYS_setpgid         equ 109
SYS_getppid         equ 110
SYS_getpgrp         equ 111
SYS_getgroups       equ 115
SYS_getpriority     equ 140
SYS_setpriority     equ 141
SYS_sched_getaffinity equ 204
SYS_pread64         equ 17
SYS_pwrite64        equ 18
SYS_sendfile        equ 40
SYS_fchdir          equ 81
SYS_mknod           equ 133
SYS_statfs          equ 137

section .text

;; ============================================================================
;; POSIXID_NOARG name, syscall_number, clinic_name
;;   -> the int the kernel answers with
;;
;; getuid and its eight siblings: no arguments, and a result that cannot
;; fail.  POSIX says so for every one of them, which is why there is no
;; POSIX_CHECK here -- getuid(2) has no error return at all, and a check
;; against -4095 would turn a uid of 4294963201 into an exception.
;; ============================================================================
%macro POSIXID_NOARG 3          ; %1 = function, %2 = syscall, %3 = its name
DEF_FUNC %1, 8
    mov rax, %2
    syscall
    movsxd rdi, eax
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret
END_FUNC %1
%endmacro

POSIXID_NOARG posixid_getuid,  SYS_getuid,  "getuid"
POSIXID_NOARG posixid_geteuid, SYS_geteuid, "geteuid"
POSIXID_NOARG posixid_getgid,  SYS_getgid,  "getgid"
POSIXID_NOARG posixid_getegid, SYS_getegid, "getegid"
POSIXID_NOARG posixid_getppid, SYS_getppid, "getppid"
POSIXID_NOARG posixid_getpgrp, SYS_getpgrp, "getpgrp"

;; ============================================================================
;; POSIXID_INT1 name, syscall_number, clinic_name
;;   -> None; the one-integer setters, which DO fail
;; Fails: 0
;; ============================================================================
%macro POSIXID_INT1 3
DEF_FUNC %1, 16
    test rsi, rsi
    jz %%argerr
    mov rdi, [rdi]
    call posix_int_arg
    ERR_M1 %%fail
    mov rdi, rax
    mov rax, %2
    syscall
    cmp rax, -4095
    jb %%ok
    mov rdi, rax
    neg rdi
    xor esi, esi
    call set_oserror
%%fail:
    xor eax, eax
    leave
    ret
%%ok:
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    ret
%%argerr:
    PM_MISSING %3, "id", 1, %%fail
END_FUNC %1
%endmacro

%macro PM_MISSING 4             ; %4 = the caller's error exit
    CSTRING rdi, %1
    CSTRING rsi, %2
    mov edx, %3
    call posix_set_missing      ; err: it always fails; %4 is where that goes
    jmp %4
%endmacro

POSIXID_INT1 posixid_setuid, SYS_setuid, "setuid"
POSIXID_INT1 posixid_setgid, SYS_setgid, "setgid"

;; ============================================================================
;; posixid_setpgid(pid, pgrp) -> None
;; Fails: 0
;; ============================================================================
DEF_FUNC posixid_setpgid, 24
    push rbx
    cmp rsi, 2
    jne .spg_args
    mov rbx, rdi
    mov rdi, [rbx + 8]
    call posix_int_arg
    ERR_M1 .spg_fail
    push rax
    mov rdi, [rbx]
    call posix_int_arg
    ERR_M1 .spg_fail_pop
    pop rsi
    mov rdi, rax
    mov rax, SYS_setpgid
    syscall
    cmp rax, -4095
    jb .spg_ok
    mov rdi, rax
    neg rdi
    xor esi, esi
    call set_oserror
    jmp .spg_fail
.spg_ok:
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.spg_args:
    FAIL exc_TypeError_type, "setpgid expected 2 arguments", .spg_fail
.spg_fail_pop:
    pop rcx                         ; the pgrp parked across the conversion
.spg_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC posixid_setpgid

;; ============================================================================
;; posixid_getgroups() -> the supplementary group list
;;
;; getgroups(2) twice: once with a zero size to learn the count, once to
;; fetch them.  NGROUPS_MAX is 65536 on Linux, so the buffer is allocated
;; rather than put on the stack.
;; Fails: 0
;; ============================================================================
GG_N    equ 8
GG_BUF  equ 16
GG_OUT  equ 24
GG_I    equ 32
GG_FRAME equ 40             ; + 1 push = 48, 16-aligned
DEF_FUNC posixid_getgroups, GG_FRAME
    push rbx
    xor edi, edi
    xor esi, esi
    mov rax, SYS_getgroups
    syscall
    cmp rax, -4095
    jb .gg_have_n
    mov rdi, rax
    neg rdi
    xor esi, esi
    call set_oserror
    jmp .gg_fail
.gg_have_n:
    mov [rbp - GG_N], rax
    lea rdi, [rax*4 + 8]
    call ap_malloc
    test rax, rax
    jz .gg_fail
    mov [rbp - GG_BUF], rax
    mov rdi, [rbp - GG_N]
    mov rsi, rax
    mov rax, SYS_getgroups
    syscall
    cmp rax, -4095
    jb .gg_got
    push rax
    push rax
    mov rdi, [rbp - GG_BUF]
    call ap_free
    pop rdi
    pop rdi
    neg rdi
    xor esi, esi
    call set_oserror
    jmp .gg_fail
.gg_got:
    mov [rbp - GG_N], rax
    mov rdi, rax
    call list_new
    test rax, rax
    jz .gg_freefail
    mov [rbp - GG_OUT], rax
    mov qword [rbp - GG_I], 0
.gg_loop:
    mov rcx, [rbp - GG_I]
    cmp rcx, [rbp - GG_N]
    jae .gg_done
    mov rdx, [rbp - GG_BUF]
    mov edi, [rdx + rcx*4]
    call int_from_i64
    V_PACK rax, rdx
    mov rdi, [rbp - GG_OUT]
    mov rsi, rax
    call list_append
    inc qword [rbp - GG_I]
    jmp .gg_loop
.gg_done:
    mov rdi, [rbp - GG_BUF]
    call ap_free
    mov rax, [rbp - GG_OUT]
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.gg_freefail:
    mov rdi, [rbp - GG_BUF]
    call ap_free
.gg_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
END_FUNC posixid_getgroups

;; ============================================================================
;; posixid_sched_getaffinity(pid) -> the set of CPUs the process may run on
;;
;; A set, as CPython's is.  The mask is a bit per CPU in a fixed-size buffer;
;; 128 bytes covers 1024 processors, which is what CPython's own default
;; cpu_set_t does before it starts doubling.
;; Fails: 0
;; ============================================================================
SGA_MASK  equ 128
SGA_SET   equ SGA_MASK + 8
SGA_I     equ SGA_MASK + 16
SGA_BITS  equ SGA_MASK + 24     ; how many bits the kernel actually wrote
SGA_FRAME equ SGA_MASK + 32     ; + 1 push = 168... 160 + 8 = 168, 8 mod 16
extern set_new
extern set_add
DEF_FUNC posixid_sched_getaffinity, SGA_FRAME
    push rbx
    xor ebx, ebx
    test rsi, rsi
    jz .sga_have_pid
    mov rdi, [rdi]
    call posix_int_arg
    ERR_M1 .sga_fail
    mov rbx, rax
.sga_have_pid:
    mov rdi, rbx
    mov esi, SGA_MASK
    lea rdx, [rbp - SGA_MASK]
    mov rax, SYS_sched_getaffinity
    syscall
    cmp rax, -4095
    jb .sga_got
    mov rdi, rax
    neg rdi
    xor esi, esi
    call set_oserror
    jmp .sga_fail
.sga_got:
    ; The kernel answers how many BYTES it wrote, and leaves the rest of the
    ; buffer alone -- so scanning the whole 128 counted whatever was on the
    ; stack.  This machine reported 267 processors.
    shl rax, 3
    mov [rbp - SGA_BITS], rax
    xor edi, edi
    call set_new
    test rax, rax
    jz .sga_fail
    mov [rbp - SGA_SET], rax
    mov qword [rbp - SGA_I], 0
.sga_loop:
    mov rcx, [rbp - SGA_I]
    cmp rcx, [rbp - SGA_BITS]
    jae .sga_done
    mov rdx, rcx
    shr rdx, 6                      ; which 64-bit word
    mov rax, rcx
    and rax, 63                     ; which bit in it
    lea rsi, [rbp - SGA_MASK]
    mov rsi, [rsi + rdx*8]
    bt rsi, rax
    jnc .sga_next
    mov rdi, rcx
    call int_from_i64
    V_PACK rax, rdx
    mov rdi, [rbp - SGA_SET]
    mov rsi, rax
    push rsi
    push rsi
    call set_add
    pop rdi
    pop rdi
    DECREF_V rdi, rdx
.sga_next:
    inc qword [rbp - SGA_I]
    jmp .sga_loop
.sga_done:
    mov rax, [rbp - SGA_SET]
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.sga_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
END_FUNC posixid_sched_getaffinity

;; ============================================================================
;; posixid_cpu_count() -> how many processors there are, or None
;;
;; CPython counts what sched_getaffinity answers -- the processors this
;; process may actually run on, not the ones the machine has -- and answers
;; None when it cannot tell.  A container with a cpuset sees the cpuset.
;; ============================================================================
CC_MASK  equ 128
CC_WORDS equ CC_MASK + 8        ; how many 64-bit words the kernel wrote
CC_FRAME equ CC_MASK + 16       ; + 1 push = 152, 8 mod 16
DEF_FUNC posixid_cpu_count, CC_FRAME
    push rbx
    xor edi, edi
    mov esi, CC_MASK
    lea rdx, [rbp - CC_MASK]
    mov rax, SYS_sched_getaffinity
    syscall
    cmp rax, -4095
    jae .cc_unknown
    ; Only the bytes the kernel reports are ours to read; see
    ; posixid_sched_getaffinity.
    shr rax, 3
    mov [rbp - CC_WORDS], rax
    xor ebx, ebx
    xor ecx, ecx
.cc_loop:
    cmp rcx, [rbp - CC_WORDS]
    jae .cc_counted
    lea rdx, [rbp - CC_MASK]
    mov rax, [rdx + rcx*8]
    popcnt rax, rax
    add rbx, rax
    inc rcx
    jmp .cc_loop
.cc_counted:
    test rbx, rbx
    jz .cc_unknown
    mov rdi, rbx
    call int_from_i64
    V_PACK rax, rdx
    pop rbx
    leave
    ret
.cc_unknown:
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
END_FUNC posixid_cpu_count

;; ============================================================================
;; posixid_times() -> os.times_result: user, system, children_user,
;;   children_system, elapsed
;;
;; times(2) counts in clock ticks; CPython divides by sysconf(_SC_CLK_TCK),
;; which is 100 on every Linux this runs on and is a constant of the ABI
;; rather than of the kernel build.
;;
;; A structseq rather than a tuple, because os.py does NOT wrap this one --
;; `os.times` IS `posix.times`, and `os.times().elapsed` is how every caller
;; reads it.
;; Fails: 0
;; ============================================================================
TMS_BUF   equ 32            ; struct tms: four longs
TMS_TUPLE equ 40
TMS_FRAME equ 56            ; + 1 push = 64, 16-aligned
CLK_TCK   equ 100
DEF_FUNC posixid_times, TMS_FRAME
    push rbx
    lea rdi, [rbp - TMS_BUF]
    mov rax, SYS_times
    syscall
    cmp rax, -4095
    jb .tms_ok
    mov rdi, rax
    neg rdi
    xor esi, esi
    call set_oserror
    jmp .tms_fail
.tms_ok:
    mov rbx, rax                    ; the elapsed real time, in ticks
    lea rdi, [rel times_result_type]
    call structseq_new
    test rax, rax
    jz .tms_fail
    mov [rbp - TMS_TUPLE], rax
    xor ecx, ecx
.tms_loop:
    cmp rcx, 4
    jae .tms_elapsed
    push rcx
    push rcx
    lea rdx, [rbp - TMS_BUF]
    mov rdi, [rdx + rcx*8]
    call posixid_ticks_to_seconds
    pop rcx
    pop rcx
    mov rdx, [rbp - TMS_TUPLE]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov [rdx + rcx*8], rax
    inc rcx
    jmp .tms_loop
.tms_elapsed:
    mov rdi, rbx
    call posixid_ticks_to_seconds
    mov rdx, [rbp - TMS_TUPLE]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov [rdx + 32], rax
    mov rax, [rbp - TMS_TUPLE]
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.tms_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
END_FUNC posixid_times

;; ============================================================================
;; posixid_ticks_to_seconds(rdi = clock ticks) -> rax = a float Value
;; ============================================================================
DEF_FUNC_LOCAL posixid_ticks_to_seconds
    cvtsi2sd xmm0, rdi
    mov eax, CLK_TCK
    cvtsi2sd xmm1, eax
    divsd xmm0, xmm1
    movq rax, xmm0
    V_FROM_F64 rax, rcx
    leave
    ret
END_FUNC posixid_ticks_to_seconds

;; ============================================================================
;; posixid_pread(fd, length, offset) -> bytes
;;
;; A read or a write at an explicit offset, leaving the descriptor's own
;; position where it was.  That is the whole point of them, and it is what
;; makes a file readable from two places without a seek between.
;; Fails: 0
;; ============================================================================
extern bytes_new
extern bytes_type
extern bytearray_type
PR_BUF    equ 8
PR_LEN    equ 16
PR_FRAME  equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC posixid_pread, PR_FRAME
    push rbx
    cmp rsi, 3
    jne .pr_args
    mov rbx, rdi
    mov rdi, [rbx + 8]
    call posix_int_arg
    ERR_M1 .pr_fail
    test rax, rax
    js .pr_negative
    mov [rbp - PR_LEN], rax
    mov rdi, rax
    call bytes_new
    test rax, rax
    jz .pr_fail
    mov [rbp - PR_BUF], rax
    mov rdi, [rbx + 16]
    call posix_int_arg
    ERR_M1 .pr_fail_buf
    push rax
    mov rdi, [rbx]
    call posix_int_arg
    ERR_M1 .pr_fail_pop
    pop rcx                         ; the offset
    mov rdi, rax
    mov rsi, [rbp - PR_BUF]
    add rsi, PyBytesObject.data
    mov rdx, [rbp - PR_LEN]
    mov r10, rcx
    mov rax, SYS_pread64
    syscall
    cmp rax, -4095
    jb .pr_read
    push rax
    push rax
    mov rdi, [rbp - PR_BUF]
    call obj_decref
    pop rdi
    pop rdi
    neg rdi
    xor esi, esi
    call set_oserror
    jmp .pr_fail
.pr_read:
    ; Shorter than asked for is ordinary; the object is truncated in place,
    ; which is safe because nothing else has seen it yet.
    mov rdi, [rbp - PR_BUF]
    mov [rdi + PyBytesObject.ob_size], rax
    mov byte [rdi + PyBytesObject.data + rax], 0
    mov rax, rdi
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.pr_negative:
    ; CPython answers OSError(EINVAL) here, not ValueError: its clinic takes
    ; the length as a Py_ssize_t and the refusal comes from the call.
    mov edi, 22                     ; EINVAL
    xor esi, esi
    call set_oserror
.pr_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.pr_args:
    FAIL exc_TypeError_type, "pread expected 3 arguments", .pr_fail
.pr_fail_pop:
    pop rcx                         ; the offset parked across the conversion
.pr_fail_buf:
    mov rdi, [rbp - PR_BUF]
    call obj_decref
    jmp .pr_fail
END_FUNC posixid_pread

;; ============================================================================
;; posixid_pwrite(fd, data, offset) -> how many bytes went
;; Fails: 0
;; ============================================================================
PW_DATA  equ 8              ; the bytes to write
PW_LEN   equ 16             ; and how many
PW_FRAME equ 24             ; + 1 push = 32, 16-aligned
DEF_FUNC posixid_pwrite, PW_FRAME
    push rbx
    cmp rsi, 3
    jne .pw_args
    mov rbx, rdi
    mov rdi, [rbx + 8]
    call posixid_buffer_arg
    ERR_PENDING .pw_fail
    mov [rbp - PW_DATA], rax
    mov [rbp - PW_LEN], rdx
    mov rdi, [rbx + 16]
    call posix_int_arg
    ERR_M1 .pw_fail
    push rax
    mov rdi, [rbx]
    call posix_int_arg
    ERR_M1 .pw_fail_pop
    pop rcx
    mov rdi, rax
    mov rsi, [rbp - PW_DATA]
    mov rdx, [rbp - PW_LEN]
    mov r10, rcx
    mov rax, SYS_pwrite64
    syscall
    cmp rax, -4095
    jb .pw_ok
    mov rdi, rax
    neg rdi
    xor esi, esi
    call set_oserror
    jmp .pw_fail
.pw_ok:
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    pop rbx
    leave
    ret
.pw_args:
    FAIL exc_TypeError_type, "pwrite expected 3 arguments", .pw_fail
.pw_fail_pop:
    pop rcx                         ; the offset parked across the conversion
.pw_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC posixid_pwrite

;; ============================================================================
;; posixid_buffer_arg(rdi = a Value) -> rax = the bytes, rdx = how many
;; bytes and bytearray only, which is what pwrite and sendfile take here.
;; An empty bytearray's storage may be NULL, so 0 alone is not the refusal.
;; Fails: 0?
;; ============================================================================
DEF_FUNC_LOCAL posixid_buffer_arg, 16
    V_TEST_PTR rdi, rcx
    ja .pba_bad
    test rdi, rdi
    jz .pba_bad
    mov rcx, [rdi + PyObject.ob_type]
    lea rax, [rel bytes_type]
    cmp rcx, rax
    je .pba_bytes
    lea rax, [rel bytearray_type]
    cmp rcx, rax
    jne .pba_bad
    mov rax, [rdi + PyByteArrayObject.ob_bytes]
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    leave
    ret
.pba_bytes:
    lea rax, [rdi + PyBytesObject.data]
    mov rdx, [rdi + PyBytesObject.ob_size]
    leave
    ret
.pba_bad:
    SET_EXC exc_TypeError_type, "a bytes-like object is required"
    leave                           ; rax = 0
    ret
END_FUNC posixid_buffer_arg

;; posixid_fchdir(fd) -> None -- chdir to an open directory descriptor.
POSIXID_INT1 posixid_fchdir, SYS_fchdir, "fchdir"

;; ============================================================================
;; posixid_sendfile(out_fd, in_fd, offset, count) -> how many bytes moved
;;
;; The four-argument form only, which is Linux's and the one shutil uses.
;; An offset of None means "from the descriptor's own position", which is
;; what a NULL third argument says to the kernel.
;; Fails: 0
;; ============================================================================
SF_COUNT equ 8
SF_OFFV  equ 16             ; the offset itself, which the kernel updates
SF_OFFP  equ 24             ; a pointer to it, or 0 for "the file position"
SF_FRAME equ 40             ; + 1 push = 48, 16-aligned
DEF_FUNC posixid_sendfile, SF_FRAME
    push rbx
    cmp rsi, 4
    jne .sf_args
    mov rbx, rdi
    mov rdi, [rbx + 24]
    call posix_int_arg
    ERR_M1 .sf_fail
    mov [rbp - SF_COUNT], rax
    mov rdi, [rbx + 16]
    lea rcx, [rel none_singleton]
    cmp rdi, rcx
    je .sf_no_offset
    call posix_int_arg
    ERR_M1 .sf_fail
    mov [rbp - SF_OFFV], rax
    lea rax, [rbp - SF_OFFV]
    mov [rbp - SF_OFFP], rax
    jmp .sf_have_offset
.sf_no_offset:
    mov qword [rbp - SF_OFFP], 0
.sf_have_offset:
    mov rdi, [rbx + 8]
    call posix_int_arg
    ERR_M1 .sf_fail
    push rax
    mov rdi, [rbx]
    call posix_int_arg
    ERR_M1 .sf_fail_pop
    pop rsi                         ; in_fd
    mov rdi, rax                    ; out_fd
    mov rdx, [rbp - SF_OFFP]
    mov r10, [rbp - SF_COUNT]
    mov rax, SYS_sendfile
    syscall
    cmp rax, -4095
    jb .sf_ok
    mov rdi, rax
    neg rdi
    xor esi, esi
    call set_oserror
    jmp .sf_fail
.sf_ok:
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    pop rbx
    leave
    ret
.sf_args:
    FAIL exc_TypeError_type, "sendfile expected 4 arguments", .sf_fail
.sf_fail_pop:
    pop rcx                         ; in_fd parked across the conversion
.sf_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC posixid_sendfile

;; ============================================================================
;; posixid_get_terminal_size(fd=1) -> (columns, lines)
;;
;; TIOCGWINSZ, which answers a struct of four u16 -- rows first, then
;; columns.  CPython's os.terminal_size is (columns, lines), the other way
;; round, and getting that backwards is the whole bug this could have.
;;
;; The structseq type is posix.asm's, already built and registered; only the
;; function was missing.
;; Fails: 0
;; ============================================================================
TIOCGWINSZ equ 0x5413
GTS_WS    equ 8             ; struct winsize: four u16
GTS_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC posixid_get_terminal_size, GTS_FRAME
    push rbx
    mov ebx, 1                      ; stdout, as CPython's default is
    test rsi, rsi
    jz .gts_have_fd
    mov rdi, [rdi]
    call posix_int_arg
    ERR_M1 .gts_fail
    mov rbx, rax
.gts_have_fd:
    mov rdi, rbx
    mov esi, TIOCGWINSZ
    lea rdx, [rbp - GTS_WS]
    call sys_ioctl
    cmp rax, -4095
    jb .gts_ok
    mov rdi, rax
    neg rdi
    xor esi, esi
    call set_oserror
    jmp .gts_fail
.gts_ok:
    lea rdi, [rel terminal_size_type]
    call structseq_new
    test rax, rax
    jz .gts_fail
    mov rbx, rax
    lea rcx, [rbp - GTS_WS]
    movzx edi, word [rcx + 2]       ; ws_col
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbx + PyTupleObject.ob_item]
    mov [rcx], rax
    lea rcx, [rbp - GTS_WS]
    movzx edi, word [rcx]           ; ws_row
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbx + PyTupleObject.ob_item]
    mov [rcx + 8], rax
    mov rax, rbx
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.gts_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
END_FUNC posixid_get_terminal_size

;; ============================================================================
;; PIDCONST value_symbol, value -- one row of the constants table.
;;
;; The name is derived from the symbol, the way socket.asm's SKCONST derives
;; it, so a name and a value cannot drift apart.  The name string goes in a
;; section of its own: emitted here it would land in the middle of the table,
;; where a pointer belongs.
;; ============================================================================
%macro PIDCONST 2
    %defstr %%s %1
    [section .rodata.pidnames]
    %%name: db %%s, 0
    __?SECT?__
    dq %%name, %2
%endmacro

section .rodata
; --- os.times_result ---
tmr_name: db "os.times_result", 0
tmr_f0:   db "user", 0
tmr_f1:   db "system", 0
tmr_f2:   db "children_user", 0
tmr_f3:   db "children_system", 0
tmr_f4:   db "elapsed", 0

align 8
tmr_fields:
    dq tmr_f0, 0
    dq tmr_f1, 1
    dq tmr_f2, 2
    dq tmr_f3, 3
    dq tmr_f4, 4

align 8
tmr_desc:
    dq 5
    dq 5
    dq tmr_fields

section .data
align 8
global times_result_type
times_result_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type
    dq tmr_name
    dq PyTupleObject_size
    dq structseq_dealloc
    dq structseq_repr
    dq structseq_repr
    dq 0
    dq 0
    dq structseq_getattr
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq TYPE_FLAG_TUPLE_SUBCLASS
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
    dq tmr_desc                 ; STRUCTSEQ_DESC, one qword past the type

section .rodata

align 8
pid_consts:
    ; The open flags posix.asm has no room for.  O_RDONLY and its neighbours
    ; are already there; these are the ones a program asks for by name and
    ; got AttributeError from.
    PIDCONST O_DIRECT, 0o40000
    PIDCONST O_DIRECTORY, 0o200000
    PIDCONST O_NOFOLLOW, 0o400000
    PIDCONST O_NOATIME, 0o1000000
    PIDCONST O_PATH, 0o10000000
    PIDCONST O_TMPFILE, 0o20200000
    PIDCONST O_SYNC, 0o4010000
    PIDCONST O_DSYNC, 0o10000
    PIDCONST O_RSYNC, 0o4010000
    PIDCONST O_ASYNC, 0o20000
    PIDCONST O_NDELAY, 0o4000
    ; 0 on x86-64: off_t is already 64-bit there, so glibc defines it away
    ; and CPython exposes glibc's value rather than the kernel's 0o100000.
    PIDCONST O_LARGEFILE, 0

    ; sysexits.h, which os.py re-exports and which a program uses to exit
    ; with something a shell can read.
    PIDCONST EX_OK, 0
    PIDCONST EX_USAGE, 64
    PIDCONST EX_DATAERR, 65
    PIDCONST EX_NOINPUT, 66
    PIDCONST EX_NOUSER, 67
    PIDCONST EX_NOHOST, 68
    PIDCONST EX_UNAVAILABLE, 69
    PIDCONST EX_SOFTWARE, 70
    PIDCONST EX_OSERR, 71
    PIDCONST EX_OSFILE, 72
    PIDCONST EX_CANTCREAT, 73
    PIDCONST EX_IOERR, 74
    PIDCONST EX_TEMPFAIL, 75
    PIDCONST EX_PROTOCOL, 76
    PIDCONST EX_NOPERM, 77
    PIDCONST EX_CONFIG, 78

    ; statvfs's flag word.  ST_IMMUTABLE is deliberately not here: CPython
    ; does not export it either, and a name this module has and CPython's
    ; does not is as much a divergence as one it lacks.
    PIDCONST ST_RDONLY, 1
    PIDCONST ST_NOSUID, 2
    PIDCONST ST_NODEV, 4
    PIDCONST ST_NOEXEC, 8
    PIDCONST ST_SYNCHRONOUS, 16
    PIDCONST ST_MANDLOCK, 64
    PIDCONST ST_WRITE, 128
    PIDCONST ST_APPEND, 256
    PIDCONST ST_NOATIME, 1024
    PIDCONST ST_NODIRATIME, 2048
    PIDCONST ST_RELATIME, 4096

    PIDCONST SCHED_OTHER, 0
    PIDCONST SCHED_FIFO, 1
    PIDCONST SCHED_RR, 2
    PIDCONST SCHED_BATCH, 3
    PIDCONST SCHED_IDLE, 5
    PIDCONST SCHED_RESET_ON_FORK, 0x40000000

    PIDCONST PRIO_PROCESS, 0
    PIDCONST PRIO_PGRP, 1
    PIDCONST PRIO_USER, 2

    ; The two lseek whences that are not SEEK_SET/CUR/END; a filesystem that
    ; does not support them answers ENXIO, which is the answer and not an
    ; excuse to leave the names out.
    PIDCONST SEEK_DATA, 3
    PIDCONST SEEK_HOLE, 4

    PIDCONST GRND_RANDOM, 2
    PIDCONST GRND_NONBLOCK, 1

    PIDCONST RTLD_LAZY, 1
    PIDCONST RTLD_NOW, 2
    PIDCONST RTLD_GLOBAL, 0x100
    PIDCONST RTLD_LOCAL, 0
    PIDCONST RTLD_NODELETE, 0x1000
    PIDCONST RTLD_NOLOAD, 4
    PIDCONST RTLD_DEEPBIND, 8

    PIDCONST POSIX_FADV_NORMAL, 0
    PIDCONST POSIX_FADV_RANDOM, 1
    PIDCONST POSIX_FADV_SEQUENTIAL, 2
    PIDCONST POSIX_FADV_WILLNEED, 3
    PIDCONST POSIX_FADV_DONTNEED, 4
    PIDCONST POSIX_FADV_NOREUSE, 5

    PIDCONST RWF_DSYNC, 2
    PIDCONST RWF_HIPRI, 1
    PIDCONST RWF_SYNC, 4
    PIDCONST RWF_NOWAIT, 8
    PIDCONST RWF_APPEND, 16

    ; waitid's, and the si_code values it answers with.
    PIDCONST P_ALL, 0
    PIDCONST P_PID, 1
    PIDCONST P_PGID, 2
    PIDCONST P_PIDFD, 3
    PIDCONST WEXITED, 4
    PIDCONST WSTOPPED, 2
    PIDCONST WCONTINUED, 8
    PIDCONST WNOWAIT, 0x01000000
    PIDCONST CLD_EXITED, 1
    PIDCONST CLD_KILLED, 2
    PIDCONST CLD_DUMPED, 3
    PIDCONST CLD_TRAPPED, 4
    PIDCONST CLD_STOPPED, 5
    PIDCONST CLD_CONTINUED, 6

    PIDCONST NGROUPS_MAX, 65536
    PIDCONST TMP_MAX, 238328
    dq 0, 0

section .text

;; ============================================================================
;; posixid_register(rdi = the module dict) -> nothing
;;
;; Everything this file adds to `posix`, called from posix_module_init the
;; way posixdir_register is.  r12 is the dict throughout, because
;; MODULE_ADD_FUNC wants it there.
;; ============================================================================
PIR_ENT   equ 8
PIR_KEY   equ 16
PIR_ROW   equ 24
PIR_FRAME equ 32            ; + 2 pushes = 48, 16-aligned
global posixid_register
extern builtin_func_new
DEF_FUNC posixid_register, PIR_FRAME
    push r12
    push rbx
    mov r12, rdi

    MODULE_ADD_FUNC posixid_getuid,    pid_n_getuid
    MODULE_ADD_FUNC posixid_geteuid,   pid_n_geteuid
    MODULE_ADD_FUNC posixid_getgid,    pid_n_getgid
    MODULE_ADD_FUNC posixid_getegid,   pid_n_getegid
    MODULE_ADD_FUNC posixid_getppid,   pid_n_getppid
    MODULE_ADD_FUNC posixid_getpgrp,   pid_n_getpgrp
    MODULE_ADD_FUNC posixid_setuid,    pid_n_setuid
    MODULE_ADD_FUNC posixid_setgid,    pid_n_setgid
    MODULE_ADD_FUNC posixid_setpgid,   pid_n_setpgid
    MODULE_ADD_FUNC posixid_getgroups, pid_n_getgroups
    MODULE_ADD_FUNC posixid_sched_getaffinity, pid_n_sched_getaffinity
    MODULE_ADD_FUNC posixid_cpu_count, pid_n_cpu_count
    MODULE_ADD_FUNC posixid_times,     pid_n_times
    MODULE_ADD_FUNC posixid_pread,     pid_n_pread
    MODULE_ADD_FUNC posixid_pwrite,    pid_n_pwrite
    MODULE_ADD_FUNC posixid_fchdir,    pid_n_fchdir
    MODULE_ADD_FUNC posixid_sendfile,  pid_n_sendfile
    MODULE_ADD_FUNC posixid_get_terminal_size, pid_n_get_terminal_size

    ; os.times returns os.times_result, and `os.times` IS `posix.times` --
    ; nothing in os.py wraps it, so the named fields have to come from here.
    lea rdi, [rel times_result_type]
    call structseq_init_type
    lea rax, [rel times_result_type]
    inc qword [rax + PyObject.ob_refcnt]
    mov [rbp - PIR_ENT], rax
    lea rdi, [rel pid_n_times_result]
    call str_from_cstr_heap
    mov [rbp - PIR_KEY], rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rbp - PIR_ENT]
    call dict_set
    mov rdi, [rbp - PIR_ENT]
    call obj_decref
    mov rdi, [rbp - PIR_KEY]
    call obj_decref

    ; The constants, one table row at a time.
    lea rbx, [rel pid_consts]
.pir_loop:
    mov rax, [rbx]
    test rax, rax
    jz .pir_done
    mov rdi, [rbx + 8]
    V_PACK_I64 rdi, rcx
    mov [rbp - PIR_ENT], rdi
    mov rdi, [rbx]
    call str_from_cstr_heap
    test rax, rax
    jz .pir_next
    mov [rbp - PIR_KEY], rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rbp - PIR_ENT]
    call dict_set
    mov rax, [rbp - PIR_ENT]
    DECREF_V rax, rcx
    mov rdi, [rbp - PIR_KEY]
    call obj_decref
.pir_next:
    add rbx, 16
    jmp .pir_loop
.pir_done:
    pop rbx
    pop r12
    leave
    ret
END_FUNC posixid_register

section .rodata
pid_n_getuid:    db "getuid", 0
pid_n_geteuid:   db "geteuid", 0
pid_n_getgid:    db "getgid", 0
pid_n_getegid:   db "getegid", 0
pid_n_getppid:   db "getppid", 0
pid_n_getpgrp:   db "getpgrp", 0
pid_n_setuid:    db "setuid", 0
pid_n_setgid:    db "setgid", 0
pid_n_setpgid:   db "setpgid", 0
pid_n_getgroups: db "getgroups", 0
pid_n_sched_getaffinity: db "sched_getaffinity", 0
pid_n_cpu_count: db "cpu_count", 0
pid_n_times:     db "times", 0
pid_n_pread:     db "pread", 0
pid_n_pwrite:    db "pwrite", 0
pid_n_fchdir:    db "fchdir", 0
pid_n_sendfile:  db "sendfile", 0
pid_n_get_terminal_size: db "get_terminal_size", 0
pid_n_times_result: db "times_result", 0
section .text
