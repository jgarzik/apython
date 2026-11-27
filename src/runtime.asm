; runtime.asm - The freestanding layer: syscalls, memory, strings, and dying
;
; Everything here is below the object model and cannot allocate a Python object
; or raise a Python exception.  It is the bottom of the call graph: ap_malloc
; calls fatal_error when it is out of memory, and fatal_error can only reach
; sys_write and sys_exit.  That chain used to span three directories and two
; source trees; it is one file now, and the externs between them are gone.
;
; These are PLT-free by design -- the memory and string operations are open
; coded rather than calling into libc, so a Python-level operation does not
; pay a PLT indirection per byte.

%include "macros.inc"
%include "object.inc"


;; ============================================================================
;; Linux x86-64 syscall wrappers
;; (was src/lib/syscall.asm)
;; ============================================================================

section .text

; Eliminates libc stdio dependency for all I/O paths

; Syscall numbers (x86-64)
SYS_read            equ 0
SYS_write           equ 1
SYS_open            equ 2
SYS_close           equ 3
SYS_fstat           equ 5
SYS_mmap            equ 9
SYS_munmap          equ 11
SYS_madvise         equ 28
SYS_msync           equ 26
SYS_mremap          equ 25
SYS_socket          equ 41
SYS_connect         equ 42
SYS_accept4         equ 288
SYS_sendto          equ 44
SYS_recvfrom        equ 45
SYS_sendmsg         equ 46
SYS_poll            equ 7
SYS_bind            equ 49
SYS_listen          equ 50
SYS_getsockname     equ 51
SYS_getpeername     equ 52
SYS_socketpair      equ 53
SYS_setsockopt      equ 54
SYS_getsockopt      equ 55
SYS_shutdown        equ 48
SYS_fcntl           equ 72
SYS_ioctl           equ 16
SYS_flock           equ 73
SYS_getrusage       equ 98
SYS_prlimit64       equ 302
SYS_io_uring_setup  equ 425
SYS_io_uring_enter  equ 426
SYS_lseek           equ 8
SYS_stat            equ 4
SYS_lstat           equ 6
SYS_dup             equ 32
SYS_getpid          equ 39
SYS_wait4           equ 61
SYS_rename          equ 82
SYS_symlink equ 88
SYS_mkdir           equ 83
SYS_rmdir           equ 84
SYS_unlink          equ 87
SYS_readlink        equ 89
SYS_chmod           equ 90
SYS_getcwd          equ 79
SYS_getdents64      equ 217
SYS_pipe2           equ 293
SYS_epoll_create1   equ 291
SYS_epoll_ctl       equ 233
SYS_epoll_wait      equ 232
SYS_getrandom       equ 318
SYS_ftruncate       equ 77
SYS_uname           equ 63
SYS_access          equ 21
SYS_umask           equ 95
SYS_exit_group      equ 231
SYS_chdir           equ 80
SYS_truncate        equ 76
SYS_link            equ 86
SYS_chown           equ 92
SYS_fchmod          equ 91
SYS_fsync           equ 74
SYS_dup2            equ 33
SYS_utimensat       equ 280
SYS_fork            equ 57
SYS_execve          equ 59
SYS_exit            equ 60
SYS_kill            equ 62
SYS_setsid          equ 112
SYS_close_range     equ 436
SYS_pidfd_open      equ 434
SYS_rt_sigaction    equ 13
SYS_rt_sigprocmask  equ 14
SYS_alarm           equ 37
SYS_pause           equ 34

;; ============================================================================
;; EINTR, and why these funnels retry it themselves.
;;
;; Signal handlers used to be installed with SA_RESTART, so an interrupted
;; slow syscall was restarted by the KERNEL and no caller ever saw EINTR.  But
;; that also meant a Python handler could not run while a read was blocked:
;; the handler that `signal.alarm(1)` fires during `f.read(6)` never ran, and
;; a program waiting for it to write the rest of the data waited for ever.
;; CPython installs with sa_flags = 0 exactly so that the read RETURNS, and
;; does the retry itself around a PyErr_CheckSignals.
;;
;; So SA_RESTART is gone (see signal_install), and what it used to do is done
;; here instead: these two retry EINTR with nothing in between, which is what
;; every one of their fifty-odd low-level callers -- a write to stderr, the
;; compiler reading a file -- already assumed.  sys_read_intr and
;; sys_write_intr are the same syscalls WITHOUT the retry, for the one caller
;; that has a Python frame to run a handler on: the _iocore file object.
;; ============================================================================
EINTR equ 4

;; ============================================================================
;; sys_write(int fd, const void *buf, size_t len) -> ssize_t
;; ============================================================================
DEF_FUNC_BARE sys_write
.retry:
    mov rax, SYS_write
    ; rdi=fd, rsi=buf, rdx=len already in place
    syscall
    cmp rax, -EINTR
    je .retry
    ret
END_FUNC sys_write

;; ============================================================================
;; sys_write_intr(int fd, const void *buf, size_t len) -> ssize_t, -EINTR and
;; all
;; ============================================================================
global sys_write_intr
DEF_FUNC_BARE sys_write_intr
    mov rax, SYS_write
    syscall
    ret
END_FUNC sys_write_intr

;; ============================================================================
;; sys_read(int fd, void *buf, size_t len) -> ssize_t
;; ============================================================================
DEF_FUNC_BARE sys_read
.retry:
    mov rax, SYS_read
    ; rdi=fd, rsi=buf, rdx=len already in place
    syscall
    cmp rax, -EINTR
    je .retry
    ret
END_FUNC sys_read

;; ============================================================================
;; sys_read_intr(int fd, void *buf, size_t len) -> ssize_t, -EINTR and all
;; ============================================================================
global sys_read_intr
DEF_FUNC_BARE sys_read_intr
    mov rax, SYS_read
    syscall
    ret
END_FUNC sys_read_intr

;; ============================================================================
;; sys_open(const char *path, int flags, int mode) -> int fd
;; ============================================================================
DEF_FUNC_BARE sys_open
    mov rax, SYS_open
    ; rdi=path, rsi=flags, rdx=mode already in place
    syscall
    ret
END_FUNC sys_open

;; ============================================================================
;; sys_close(int fd) -> int
;; ============================================================================
DEF_FUNC_BARE sys_close
    mov rax, SYS_close
    ; rdi=fd already in place
    syscall
    ret
END_FUNC sys_close

;; ============================================================================
;; sys_fstat(int fd, struct stat *buf) -> int
;; ============================================================================
DEF_FUNC_BARE sys_fstat
    mov rax, SYS_fstat
    ; rdi=fd, rsi=buf already in place
    syscall
    ret
END_FUNC sys_fstat



;; ---------------------------------------------------------------------------
;; The syscalls the posix module needs.  Each returns the kernel's own value:
;; the result, or -errno.  Nothing normalises to -1 -- posix_check reads the
;; negative directly to build the OSError.
;;
;; The fourth argument goes in r10, not rcx, and `syscall` itself clobbers rcx
;; and r11 -- so `mov r10, rcx` has to come before it, never after.
;; ---------------------------------------------------------------------------

;; ============================================================================
;; sys_stat(const char *path, struct stat *buf) -> int
;; ============================================================================
DEF_FUNC_BARE sys_stat
    mov rax, SYS_stat
    syscall
    ret
END_FUNC sys_stat

;; ============================================================================
;; sys_lstat(const char *path, struct stat *buf) -> int
;; ============================================================================
DEF_FUNC_BARE sys_lstat
    mov rax, SYS_lstat
    syscall
    ret
END_FUNC sys_lstat

;; ============================================================================
;; sys_lseek(int fd, off_t off, int whence) -> off_t
;; ============================================================================
DEF_FUNC_BARE sys_lseek
    mov rax, SYS_lseek
    syscall
    ret
END_FUNC sys_lseek

;; ============================================================================
;; sys_dup(int fd) -> int
;; ============================================================================
DEF_FUNC_BARE sys_dup
    mov rax, SYS_dup
    syscall
    ret
END_FUNC sys_dup

;; ============================================================================
;; sys_getpid(void) -> pid_t
;; ============================================================================
DEF_FUNC_BARE sys_getpid
    mov rax, SYS_getpid
    syscall
    ret
END_FUNC sys_getpid

;; ============================================================================
;; sys_getcwd(char *buf, size_t size) -> long (the length including the NUL)
;; ============================================================================
DEF_FUNC_BARE sys_getcwd
    mov rax, SYS_getcwd
    syscall
    ret
END_FUNC sys_getcwd

;; ============================================================================
;; sys_mkdir(const char *path, mode_t mode) -> int
;; ============================================================================
DEF_FUNC_BARE sys_mkdir
    mov rax, SYS_mkdir
    syscall
    ret
END_FUNC sys_mkdir

;; ============================================================================
;; sys_rmdir(const char *path) -> int
;; ============================================================================
DEF_FUNC_BARE sys_rmdir
    mov rax, SYS_rmdir
    syscall
    ret
END_FUNC sys_rmdir

;; ============================================================================
;; sys_unlink(const char *path) -> int
;; ============================================================================
DEF_FUNC_BARE sys_unlink
    mov rax, SYS_unlink
    syscall
    ret
END_FUNC sys_unlink

;; ============================================================================
;; sys_rename(const char *old, const char *new) -> int
;; ============================================================================
DEF_FUNC_BARE sys_rename
    mov rax, SYS_rename
    syscall
    ret
END_FUNC sys_rename

;; ============================================================================
;; sys_symlink(const char *target, const char *linkpath) -> int
;; ============================================================================
global sys_symlink
DEF_FUNC_BARE sys_symlink
    mov rax, SYS_symlink
    syscall
    ret
END_FUNC sys_symlink

;; ============================================================================
;; sys_readlink(const char *path, char *buf, size_t size) -> ssize_t
;; ============================================================================
DEF_FUNC_BARE sys_readlink
    mov rax, SYS_readlink
    syscall
    ret
END_FUNC sys_readlink

;; ============================================================================
;; sys_chmod(const char *path, mode_t mode) -> int
;; ============================================================================
DEF_FUNC_BARE sys_chmod
    mov rax, SYS_chmod
    syscall
    ret
END_FUNC sys_chmod

;; ============================================================================
;; sys_access(const char *path, int mode) -> int
;; ============================================================================
DEF_FUNC_BARE sys_access
    mov rax, SYS_access
    syscall
    ret
END_FUNC sys_access

;; ============================================================================
;; sys_umask(mode_t mask) -> mode_t (the previous one)
;; ============================================================================
DEF_FUNC_BARE sys_umask
    mov rax, SYS_umask
    syscall
    ret
END_FUNC sys_umask

;; ============================================================================
;; sys_pipe2(int fds[2], int flags) -> int
;; ============================================================================
DEF_FUNC_BARE sys_pipe2
    mov rax, SYS_pipe2
    syscall
    ret
END_FUNC sys_pipe2

;; ============================================================================
;; sys_epoll_create1(int flags) -> int fd, or -errno
;; ============================================================================
DEF_FUNC_BARE sys_epoll_create1
    mov rax, SYS_epoll_create1
    syscall
    ret
END_FUNC sys_epoll_create1

;; ============================================================================
;; sys_epoll_ctl(int epfd, int op, int fd, struct epoll_event *ev) -> 0/-errno
;; ============================================================================
DEF_FUNC_BARE sys_epoll_ctl
    mov r10, rcx
    mov rax, SYS_epoll_ctl
    syscall
    ret
END_FUNC sys_epoll_ctl

;; ============================================================================
;; sys_epoll_wait(int epfd, struct epoll_event *evs, int max, int timeout_ms)
;;   -> int ready, or -errno
;; ============================================================================
DEF_FUNC_BARE sys_epoll_wait
    mov r10, rcx
    mov rax, SYS_epoll_wait
    syscall
    ret
END_FUNC sys_epoll_wait

;; ============================================================================
;; sys_getdents64(int fd, void *dirp, unsigned count) -> int bytes read
;; ============================================================================
DEF_FUNC_BARE sys_getdents64
    mov rax, SYS_getdents64
    syscall
    ret
END_FUNC sys_getdents64

;; ============================================================================
;; sys_getrandom(void *buf, size_t len, unsigned flags) -> ssize_t
;; ============================================================================
DEF_FUNC_BARE sys_getrandom
    mov rax, SYS_getrandom
    syscall
    ret
END_FUNC sys_getrandom

;; ============================================================================
;; sys_ftruncate(int fd, off_t length) -> int
;; ============================================================================
DEF_FUNC_BARE sys_ftruncate
    mov rax, SYS_ftruncate
    syscall
    ret
END_FUNC sys_ftruncate

;; ============================================================================
;; The eight the posix module was short of.  Each is the bare syscall; the
;; argument checking and the OSError live in src/modules/posix.asm.
;; sys_chdir(const char *path) -> int
;; ============================================================================
global sys_chdir
DEF_FUNC_BARE sys_chdir
    mov rax, SYS_chdir
    syscall
    ret
END_FUNC sys_chdir

;; ============================================================================
;; sys_truncate(const char *path, off_t length) -> int
;; ============================================================================
global sys_truncate
DEF_FUNC_BARE sys_truncate
    mov rax, SYS_truncate
    syscall
    ret
END_FUNC sys_truncate

;; ============================================================================
;; sys_link(const char *old, const char *new) -> int
;; ============================================================================
global sys_link
DEF_FUNC_BARE sys_link
    mov rax, SYS_link
    syscall
    ret
END_FUNC sys_link

;; ============================================================================
;; sys_chown(const char *path, uid_t uid, gid_t gid) -> int
;; ============================================================================
global sys_chown
DEF_FUNC_BARE sys_chown
    mov rax, SYS_chown
    syscall
    ret
END_FUNC sys_chown

;; ============================================================================
;; sys_fchmod(int fd, mode_t mode) -> int
;; ============================================================================
global sys_fchmod
DEF_FUNC_BARE sys_fchmod
    mov rax, SYS_fchmod
    syscall
    ret
END_FUNC sys_fchmod

;; ============================================================================
;; sys_fsync(int fd) -> int
;; ============================================================================
global sys_fsync
DEF_FUNC_BARE sys_fsync
    mov rax, SYS_fsync
    syscall
    ret
END_FUNC sys_fsync

;; ============================================================================
;; sys_dup2(int oldfd, int newfd) -> int
;; ============================================================================
global sys_dup2
DEF_FUNC_BARE sys_dup2
    mov rax, SYS_dup2
    syscall
    ret
END_FUNC sys_dup2

;; ============================================================================
;; sys_utimensat(int dirfd, const char *path, const struct timespec times[2],
;; int flags) -> int
;; utime(path, times) goes through this: utimensat is the only one of the
;; family Linux still keeps, and AT_FDCWD with a NULL times means "now".
;; ============================================================================
global sys_utimensat
DEF_FUNC_BARE sys_utimensat
    mov r10, rcx                ; the fourth syscall argument is r10, not rcx
    mov rax, SYS_utimensat
    syscall
    ret
END_FUNC sys_utimensat

;; ============================================================================
;; sys_uname(struct utsname *buf) -> int
;; ============================================================================
DEF_FUNC_BARE sys_uname
    mov rax, SYS_uname
    syscall
    ret
END_FUNC sys_uname

;; ============================================================================
;; sys_wait4(pid_t pid, int *status, int options, struct rusage *ru) -> pid_t
;; ============================================================================
DEF_FUNC_BARE sys_wait4
    ; EINTR is retried here, because SA_RESTART used to do it: see the note
    ; above sys_write.
    mov r10, rcx               ; 4th arg -- and syscall clobbers rcx, so first
.retry:
    mov rax, SYS_wait4
    syscall
    cmp rax, -EINTR
    je .retry
    ret
END_FUNC sys_wait4

;; ============================================================================
;; sys_exit(int code) -> noreturn
;; ============================================================================
DEF_FUNC_BARE sys_exit
    mov rax, SYS_exit_group
    ; rdi=code already in place
    syscall
    ; should never reach here
    hlt
END_FUNC sys_exit

;; ============================================================================
;; sys_mmap(addr, len, prot, flags, fd, offset) -> void*
;; ============================================================================
DEF_FUNC_BARE sys_mmap
    mov rax, SYS_mmap
    mov r10, rcx               ; Linux syscall: 4th arg in r10, not rcx
    syscall
    ret
END_FUNC sys_mmap

;; ============================================================================
;; sys_munmap(addr, len) -> int
;; ============================================================================
DEF_FUNC_BARE sys_munmap
    mov rax, SYS_munmap
    syscall
    ret
END_FUNC sys_munmap

;; ============================================================================
;; sys_msync(addr, len, flags) -> int
;;
;; What mmap.flush() is.  The mapping is already coherent with the file
;; through the page cache, so this is about DURABILITY -- MS_SYNC is what a
;; caller asking for a flush means.
;; ============================================================================
DEF_FUNC_BARE sys_msync
    mov rax, SYS_msync
    syscall
    ret
END_FUNC sys_msync

;; ============================================================================
;; sys_mremap(old_addr, old_len, new_len, flags, new_addr) -> void*
;;
;; What mmap.resize() is.  MREMAP_MAYMOVE is the only flag worth passing:
;; without it a grow fails whenever anything is mapped directly above, which
;; on a heap this allocator has already carved is most of the time.
;; ============================================================================
DEF_FUNC_BARE sys_mremap
    mov rax, SYS_mremap
    mov r10, rcx               ; Linux syscall: 4th arg in r10, not rcx
    syscall
    ret
END_FUNC sys_mremap

;; ============================================================================
;; sys_madvise(addr, len, advice) -> int
;;
;; Only MADV_NOHUGEPAGE is wanted so far, and only by the pool allocator: on a
;; host whose transparent_hugepage is `always`, a reservation of a gigabyte is
;; hugepage-eligible, and touching one 16 KiB pool would fault in two megabytes
;; of resident memory to back it.  Advice a kernel is free to ignore, so the
;; result is ignored too.
;; ============================================================================
DEF_FUNC_BARE sys_madvise
    mov rax, SYS_madvise
    syscall
    ret
END_FUNC sys_madvise

;; ============================================================================
;; sys_io_uring_setup(entries, params*) -> int fd
;; ============================================================================
DEF_FUNC_BARE sys_io_uring_setup
    mov rax, SYS_io_uring_setup
    syscall
    ret
END_FUNC sys_io_uring_setup

;; ============================================================================
;; sys_io_uring_enter(fd, to_submit, min_complete, flags, sig, sigsz) -> int
;; ============================================================================
DEF_FUNC_BARE sys_io_uring_enter
    ; NOT retried: like poll, it is a WAIT with a deadline of its own and the
    ; kernel does not restart it.  The event loop sees the EINTR, as it did
    ; when SA_RESTART was set.
    mov r10, rcx               ; 4th arg
    mov rax, SYS_io_uring_enter
    syscall
    ret
END_FUNC sys_io_uring_enter

;; ============================================================================
;; sys_socket(domain, type, protocol) -> int fd
;; ============================================================================
DEF_FUNC_BARE sys_socket
    mov rax, SYS_socket
    syscall
    ret
END_FUNC sys_socket

;; ============================================================================
;; sys_bind(fd, addr*, addrlen) -> int
;; ============================================================================
DEF_FUNC_BARE sys_bind
    mov rax, SYS_bind
    syscall
    ret
END_FUNC sys_bind

;; ============================================================================
;; sys_listen(fd, backlog) -> int
;; ============================================================================
DEF_FUNC_BARE sys_listen
    mov rax, SYS_listen
    syscall
    ret
END_FUNC sys_listen

;; ============================================================================
;; sys_accept4(fd, addr*, addrlen*, flags) -> int
;; ============================================================================
DEF_FUNC_BARE sys_accept4
    ; EINTR is retried here, because SA_RESTART used to do it: see the note
    ; above sys_write.
    mov r10, rcx               ; 4th arg
.retry:
    mov rax, SYS_accept4
    syscall
    cmp rax, -EINTR
    je .retry
    ret
END_FUNC sys_accept4

;; ============================================================================
;; sys_connect(fd, addr*, addrlen) -> int
;; ============================================================================
DEF_FUNC_BARE sys_connect
    ; NOT retried, and not restartable either: after EINTR the kernel
    ; continues the connection asynchronously, so a second connect() on the
    ; same descriptor answers EALREADY or EISCONN rather than finishing the
    ; first.  CPython waits with poll instead of calling again.
    mov rax, SYS_connect
    syscall
    ret
END_FUNC sys_connect

;; ============================================================================
;; sys_sendto(fd, buf, len, flags, dest_addr*, addrlen) -> ssize_t
;; ============================================================================
DEF_FUNC_BARE sys_sendto
    ; EINTR is retried here, because SA_RESTART used to do it: see the note
    ; above sys_write.
    mov r10, rcx               ; 4th arg
.retry:
    mov rax, SYS_sendto
    syscall
    cmp rax, -EINTR
    je .retry
    ret
END_FUNC sys_sendto

;; ============================================================================
;; sys_recvfrom(fd, buf, len, flags, src_addr*, addrlen*) -> ssize_t
;; ============================================================================
DEF_FUNC_BARE sys_recvfrom
    ; EINTR is retried here, because SA_RESTART used to do it: see the note
    ; above sys_write.
    mov r10, rcx               ; 4th arg
.retry:
    mov rax, SYS_recvfrom
    syscall
    cmp rax, -EINTR
    je .retry
    ret
END_FUNC sys_recvfrom

;; ============================================================================
;; sys_setsockopt(fd, level, optname, optval*, optlen) -> int
;; ============================================================================
DEF_FUNC_BARE sys_setsockopt
    mov rax, SYS_setsockopt
    mov r10, rcx               ; 4th arg
    syscall
    ret
END_FUNC sys_setsockopt

;; ============================================================================
;; sys_getsockopt(fd, level, optname, optval*, optlen*) -> int
;; ============================================================================
DEF_FUNC_BARE sys_getsockopt
    mov rax, SYS_getsockopt
    mov r10, rcx               ; 4th arg
    syscall
    ret
END_FUNC sys_getsockopt

;; ============================================================================
;; sys_getsockname(fd, addr*, addrlen*) -> int
;; ============================================================================
DEF_FUNC_BARE sys_getsockname
    mov rax, SYS_getsockname
    syscall
    ret
END_FUNC sys_getsockname

;; ============================================================================
;; sys_getpeername(fd, addr*, addrlen*) -> int
;; ============================================================================
DEF_FUNC_BARE sys_getpeername
    mov rax, SYS_getpeername
    syscall
    ret
END_FUNC sys_getpeername

;; ============================================================================
;; sys_poll(struct pollfd *fds, nfds_t n, int timeout_ms) -> int
;; The syscall rather than glibc's wrapper: this returns -errno, where the
;; wrapper returns -1 in a 32-bit register and leaves the reason in errno.
;; ============================================================================
DEF_FUNC_BARE sys_poll
    ; NOT retried here.  Linux never restarts poll() whatever SA_RESTART says
    ; -- the timeout is absolute to the call -- so a retry is not what the
    ; flag used to do: it re-issued the wait with the WHOLE timeout again and
    ; ran no handler, which is an unkillable poll.  The caller with a Python
    ; frame does it, with the remaining time: see socket_poll.
    mov rax, SYS_poll
    syscall
    ret
END_FUNC sys_poll

;; ============================================================================
;; sys_shutdown(fd, how) -> int
;; ============================================================================
DEF_FUNC_BARE sys_shutdown
    mov rax, SYS_shutdown
    syscall
    ret
END_FUNC sys_shutdown

;; ============================================================================
;; sys_socketpair(domain, type, protocol, int sv[2]) -> int
;; ============================================================================
DEF_FUNC_BARE sys_socketpair
    mov rax, SYS_socketpair
    mov r10, rcx               ; 4th arg
    syscall
    ret
END_FUNC sys_socketpair


;; ============================================================================
;; sys_fcntl(fd, cmd, arg) -> int
;; ============================================================================
DEF_FUNC_BARE sys_fcntl
    mov rax, SYS_fcntl
    syscall
    ret
END_FUNC sys_fcntl

;; ============================================================================
;; sys_prlimit64(pid, resource, const struct rlimit64 *new, struct rlimit64 *old)
;;   -> int
;;
;; The modern form of getrlimit and setrlimit both: a NULL `new` reads and a
;; NULL `old` writes, and pid 0 means this process.  The legacy pair carry a
;; 32-bit rlim_t on some ABIs and this one never does.
;; ============================================================================
global sys_prlimit64
DEF_FUNC_BARE sys_prlimit64
    mov r10, rcx                ; the 4th argument; syscall clobbers rcx
    mov rax, SYS_prlimit64
    syscall
    ret
END_FUNC sys_prlimit64

;; ============================================================================
;; sys_getrusage(who, struct rusage *out) -> int
;; ============================================================================
global sys_getrusage
DEF_FUNC_BARE sys_getrusage
    mov rax, SYS_getrusage
    syscall
    ret
END_FUNC sys_getrusage

;; ============================================================================
;; sys_flock(fd, operation) -> int
;;
;; BSD advisory locking.  Not an fcntl command: the two families are separate
;; locks on the same file and do not see each other.
;; ============================================================================
global sys_flock
DEF_FUNC_BARE sys_flock
    mov rax, SYS_flock
    syscall
    ret
END_FUNC sys_flock

;; ============================================================================
;; sys_ioctl(fd, request, arg) -> int
;; ============================================================================
DEF_FUNC_BARE sys_ioctl
    mov rax, SYS_ioctl
    syscall
    ret
END_FUNC sys_ioctl

;; ============================================================================
;; Memory operations, PLT-free
;; (was src/lib/memops.asm)
;; ============================================================================

section .text

; Replaces libc memcpy and memset
; Uses rep movsb / rep stosb (optimal on ERMS-capable CPUs, Ivy Bridge+)

;; ============================================================================
;; ap_memcpy(void *dst, const void *src, size_t n) -> void *dst
;; ============================================================================
DEF_FUNC_BARE ap_memcpy
    mov rax, rdi            ; save dst for return
    ; `rep movsb` is ERMS-accelerated for long copies and carries roughly
    ; thirty cycles of startup, which is the entire cost of a short one.
    ; Short is the common case here: a one-character string from iteration
    ; copies ONE byte, and join and split copy a piece at a time.  Up to 32
    ; bytes go through overlapping loads and stores instead, and the overlap
    ; is safe because this is memcpy, not memmove.
    ;
    ; CLOBBERS ONLY rax AND rcx on these paths -- strictly less than the
    ; `rep movsb` they replace, which also advanced rdi and rsi.  Widening
    ; that set is not free: sre.asm reads r8 across a call to this.
    cmp rdx, 32
    ja .amcp_rep
    cmp rdx, 16
    ja .amcp_17_32
    cmp rdx, 8
    jb .amcp_under8
    mov rcx, [rsi]                  ; 8..16, two qwords overlapping
    mov [rdi], rcx
    mov rcx, [rsi + rdx - 8]
    mov [rdi + rdx - 8], rcx
    ret
.amcp_17_32:
    mov rcx, [rsi]
    mov [rdi], rcx
    mov rcx, [rsi + 8]
    mov [rdi + 8], rcx
    mov rcx, [rsi + rdx - 16]
    mov [rdi + rdx - 16], rcx
    mov rcx, [rsi + rdx - 8]
    mov [rdi + rdx - 8], rcx
    ret
.amcp_under8:
    cmp rdx, 4
    jb .amcp_under4
    mov ecx, [rsi]                  ; 4..7, two dwords overlapping
    mov [rdi], ecx
    mov ecx, [rsi + rdx - 4]
    mov [rdi + rdx - 4], ecx
    ret
.amcp_under4:
    cmp rdx, 2
    jb .amcp_under2
    movzx ecx, word [rsi]           ; 2..3, two words overlapping
    mov [rdi], cx
    movzx ecx, word [rsi + rdx - 2]
    mov [rdi + rdx - 2], cx
    ret
.amcp_under2:
    test rdx, rdx
    jz .amcp_done
    mov cl, [rsi]                   ; exactly one byte
    mov [rdi], cl
.amcp_done:
    ret
.amcp_rep:
    mov rcx, rdx            ; rcx = count
    rep movsb               ; rdi=dst, rsi=src already in place
    ret
END_FUNC ap_memcpy

;; ============================================================================
;; ap_memset(void *dst, int val, size_t n) -> void *dst
;; ============================================================================
DEF_FUNC_BARE ap_memset
    mov r8, rdi             ; save dst for return
    ; `rep stosb` carries the same thirty-odd cycles of startup that ap_memcpy
    ; documents for `rep movsb`, and it had no size ladder at all -- so
    ; clearing eight bytes cost what clearing four hundred does.  The callers
    ; are dict and set table clears, code-object field zeroing and the numeric
    ; scratch buffers, and most of them are short.  Same shape as ap_memcpy
    ; above: overlapping stores up to 32 bytes, `rep stosb` beyond.
    movzx eax, sil
    mov rcx, 0x0101010101010101
    imul rax, rcx           ; the byte, in all eight lanes.  rcx, not a fresh
                            ; register: `rep stosb` already clobbers it, so
                            ; the clobber set is unchanged from before.
    cmp rdx, 32
    ja .ams_rep
    cmp rdx, 16
    ja .ams_17_32
    cmp rdx, 8
    jb .ams_under8
    mov [rdi], rax                  ; 8..16, two qwords overlapping
    mov [rdi + rdx - 8], rax
    jmp .ams_done
.ams_17_32:
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + rdx - 16], rax
    mov [rdi + rdx - 8], rax
    jmp .ams_done
.ams_under8:
    cmp rdx, 4
    jb .ams_under4
    mov [rdi], eax                  ; 4..7, two dwords overlapping
    mov [rdi + rdx - 4], eax
    jmp .ams_done
.ams_under4:
    cmp rdx, 2
    jb .ams_under2
    mov [rdi], ax                   ; 2..3, two words overlapping
    mov [rdi + rdx - 2], ax
    jmp .ams_done
.ams_under2:
    test rdx, rdx
    jz .ams_done
    mov [rdi], al                   ; exactly one byte
.ams_done:
    mov rax, r8             ; return original dst
    ret
.ams_rep:
    mov rcx, rdx            ; rcx = count
    rep stosb               ; rdi=dst already in place, al = the byte
    mov rax, r8             ; return original dst
    ret
END_FUNC ap_memset

;; ============================================================================
;; ap_memmove(void *dst, const void *src, size_t n) -> void *dst
;; Handles overlapping regions.  Any n; byte-granular at both ends.
;;
;; Three arms.  Forward covers dst < src and, after the disjointness test
;; below, most of dst > src as well; only a real overlap upward needs the
;; descending loop.
;;
;; Clobbers rax, rcx, rdx, rsi and rdi.  rbx is pushed and restored.
;; ============================================================================
DEF_FUNC_BARE ap_memmove
    mov rax, rdi            ; save dst for return
    mov rcx, rdx            ; rcx = byte count
    test rcx, rcx
    jz .memmove_done
    cmp rdi, rsi
    je .memmove_done        ; dst == src, nop
    jb .memmove_fwd         ; dst < src: forward is safe

    ; dst > src.  Forward is still correct when the two regions do not
    ; actually touch, and forward is where the fast copy lives, so ask before
    ; committing to the slow direction.
    lea rdx, [rsi + rcx]
    cmp rdi, rdx
    jae .memmove_fwd        ; dst >= src + n: disjoint after all

.memmove_bk:
    ; A genuine upward overlap: copy from the top down.
    ;
    ; This was `std` + `rep movsb` + `cld`, which is the obvious spelling and
    ; the wrong one.  Backward `rep movsb` has never been ERMSB-accelerated on
    ; any x86-64 -- it degrades to about a byte a cycle -- and each flip of the
    ; direction flag costs ten to twenty cycles on top.  The header claimed a
    ; "manual qword loop (avoids std penalty)" that was not there; this is it.
    ;
    ; list.insert(0, x) and list.pop(0) reach here on every call, as do
    ; bytearray's splices.
    push rbx
    lea rsi, [rsi + rcx]
    lea rdi, [rdi + rcx]
    mov rdx, rcx
    and edx, 7              ; the byte remainder is at the LOW end going down
    shr rcx, 3
    jz .mmb_tail
.mmb_qword:
    sub rsi, 8
    sub rdi, 8
    mov rbx, [rsi]
    mov [rdi], rbx
    dec rcx
    jnz .mmb_qword
.mmb_tail:
    test edx, edx
    jz .mmb_done
.mmb_byte:
    dec rsi
    dec rdi
    mov bl, [rsi]
    mov [rdi], bl
    dec edx
    jnz .mmb_byte
.mmb_done:
    pop rbx
    ret

.memmove_fwd:
    ; qwords then a byte remainder.  rcx rather than rdx is saved across the
    ; `rep movsq` because the disjointness test above spends rdx.
    push rcx
    shr rcx, 3
    rep movsq
    pop rcx
    and ecx, 7
    rep movsb
.memmove_done:
    ret
END_FUNC ap_memmove

;; ============================================================================
;; ap_memcmp(const void *s1, const void *s2, size_t n) -> int
;; Returns 0 if equal, <0 if s1<s2, >0 if s1>s2
;; ============================================================================
DEF_FUNC_BARE ap_memcmp
    ; This was `repe cmpsb`.  Unlike `rep movsb`, `rep cmpsb` is microcoded on
    ; every x86-64 and has never been ERMS-accelerated -- it runs at roughly a
    ; byte every few cycles with a large fixed startup, and str.split called it
    ; once per byte of the haystack.  Eight bytes at a time, with the byte loop
    ; kept only for the tail.
    ;
    ; Never reads past the end: the word loop runs only while eight whole bytes
    ; remain, which is what `sub`/`jae` below is counting.
    ;
    ; rbx carries the count so that rdx survives, because `repe cmpsb` left it
    ; alone and eighteen call sites were written against that.
    push rbx
    mov rbx, rdx
    sub rbx, 8
    jb .amc_tail
.amc_word:
    mov rax, [rdi]
    mov rcx, [rsi]
    cmp rax, rcx
    jne .amc_word_differs
    add rdi, 8
    add rsi, 8
    sub rbx, 8
    jae .amc_word
.amc_tail:
    add rbx, 8              ; 0..7 bytes left
    jz .amc_equal
.amc_byte:
    movzx eax, byte [rdi]
    movzx ecx, byte [rsi]
    sub eax, ecx
    jnz .amc_done
    inc rdi
    inc rsi
    dec rbx
    jnz .amc_byte
.amc_equal:
    xor eax, eax
.amc_done:
    pop rbx
    ret
.amc_word_differs:
    ; The two words differ somewhere.  Byte-swapping puts memory order into
    ; numeric order, so one unsigned compare gives the lexicographic answer
    ; without finding which byte it was.
    bswap rax
    bswap rcx
    cmp rax, rcx
    sbb eax, eax            ; -1 when below, 0 when above
    or eax, 1               ; -1 or 1; they cannot be equal here
    pop rbx
    ret
END_FUNC ap_memcmp

;; ============================================================================
;; ap_memchr(rdi = buf, rsi = len, rdx = byte) -> rax = first match, or 0
;;
;; The highest-leverage scanner in the tree: str.find, .count, .replace,
;; .split, .partition and `in` all reach it, most of them through ap_memfind,
;; which tail-jumps here for a one-byte needle.
;;
;; Sixteen bytes at a time with SSE2, which is architecturally guaranteed on
;; every x86-64 -- no cpuid, no ifunc, nothing to detect.  `pcmpeqb` marks
;; every matching lane and `pmovmskb` collapses the answer to a 16-bit mask,
;; so the loop is four instructions per sixteen bytes where the SWAR form it
;; replaced was twelve per eight.
;;
;; The vector arm runs only while sixteen or more bytes remain, so it never
;; reads past the end -- the guarantee the SWAR version documented is kept
;; exactly, without widening any allocation's padding.  Below sixteen the byte
;; loop is entered directly: the old code had a sixteen-byte byte-at-a-time
;; PROLOGUE for the same reason, to keep a short scan away from a three-cycle
;; `imul` broadcast on the critical path (measured at the time: the word loop
;; alone was 40% slower on `s.count("a")`).  SSE2 has no such setup -- the
;; broadcast is four cheap shuffles -- but a scan shorter than one vector
;; still cannot pay for even that, so the test stays.
;;
;; Clobbers rax, rcx, rdi, rsi and xmm0/xmm1 -- narrower than the version it
;; replaces, which also pushed rbx.  No SysV xmm register is callee-saved, and
;; no caller of this function touches one.
;; ============================================================================
DEF_FUNC_BARE ap_memchr
    ; A bounded byte prologue before any setup, kept from the SWAR version and
    ; for the same reason -- which a first pass at this removed, and the
    ; benchmark caught within one run.  `A = "abcdefghij" * 100; s.count("a")`
    ; calls this once per match with the next match ten bytes away, so what it
    ; measures is the fixed cost per CALL.  A vector setup is four shuffles
    ; plus two GPR/XMM domain crossings; ten byte compares pipeline better
    ; than that, and dropping the prologue cost 57% on s_count while making
    ; every long scan faster.  Sixteen bytes is noise against a scan long
    ; enough to want the loop.
    mov rcx, rsi
    cmp rcx, 16
    jbe .amk_prologue
    mov ecx, 16
.amk_prologue:
    sub rsi, rcx                    ; what is left for the vector loop
    test rcx, rcx
    jz .amk_vec_setup
.amk_pro_byte:
    cmp dl, [rdi]
    je .amk_hit
    inc rdi
    dec rcx
    jnz .amk_pro_byte

.amk_vec_setup:
    cmp rsi, 16
    jb .amk_bytes

    ; Broadcast the low byte of edx to all sixteen lanes.  Each step doubles
    ; the width, so only byte 0 survives and the caller need not have zeroed
    ; the rest of the register.
    movd xmm1, edx
    punpcklbw xmm1, xmm1
    punpcklwd xmm1, xmm1
    pshufd xmm1, xmm1, 0

.amk_vec:
    movdqu xmm0, [rdi]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0
    test eax, eax
    jnz .amk_vec_hit
    add rdi, 16
    sub rsi, 16
    cmp rsi, 16
    jae .amk_vec

.amk_bytes:
    test rsi, rsi
    jz .amk_none
.amk_byte_loop:
    cmp dl, [rdi]
    je .amk_hit
    inc rdi
    dec rsi
    jnz .amk_byte_loop
.amk_none:
    xor eax, eax
    ret

.amk_vec_hit:
    ; One mask bit per byte, lowest bit = lowest address.
    bsf eax, eax
    add rax, rdi
    ret
.amk_hit:
    mov rax, rdi
    ret
END_FUNC ap_memchr

;; ============================================================================
;; String operations, PLT-free
;; (was src/lib/string.asm)
;; ============================================================================

section .text

; Replaces libc strlen, strcmp, strstr

;; ============================================================================
;; ap_strlen(const char *s) -> size_t
;;
;; Eight bytes at a time, by the same Mycroft test ap_strcmp uses below: for a
;; word x, (x - 0x01..01) & ~x & 0x80..80 is nonzero exactly when some byte of
;; x is zero.
;;
;; This was `repne scasb`, under a comment claiming it was "fast on modern
;; x86-64 with FAST_SHORT_REP".  FSRM covers `rep movsb` and nothing else;
;; `repne scasb` has never been accelerated on any Intel or AMD part, and runs
;; at roughly a byte every two to four cycles after a large fixed startup.
;;
;; A byte prologue walks to the next 8-byte boundary before the word loop
;; starts, so no 8-byte load can reach into a page the string does not already
;; touch.  It also costs no register, which is the point: the clobber set here
;; is exactly what `repne scasb` clobbered -- rax, rcx and rdi -- because the
;; thirteen callers were written against that and one of them holds a live
;; rsi across the call.  The two constants live in .rodata for the same
;; reason; in a register they would have widened it.
;; ============================================================================
DEF_FUNC_BARE ap_strlen
    push rsi
    mov rsi, rdi                    ; the original pointer, for the length
.asl_align:
    test dil, 7
    jz .asl_aligned
    cmp byte [rdi], 0
    je .asl_hit
    inc rdi
    jmp .asl_align

.asl_aligned:
    mov rax, [rdi]
    mov rcx, rax
    not rcx
    sub rax, [rel swar_ones]
    and rax, rcx
    and rax, [rel swar_himask]
    jnz .asl_found
.asl_loop:
    add rdi, 8
    mov rax, [rdi]
    mov rcx, rax
    not rcx
    sub rax, [rel swar_ones]
    and rax, rcx
    and rax, [rel swar_himask]
    jz .asl_loop
.asl_found:
    ; The lowest set 0x80 marks the first NUL, x86 being little-endian.
    bsf rax, rax
    shr rax, 3                      ; bit index -> byte index within the word
    add rdi, rax
.asl_hit:
    mov rax, rdi
    sub rax, rsi
    pop rsi
    ret
END_FUNC ap_strlen

section .rodata
align 8
; The two Mycroft constants, shared by ap_strlen and ap_strcmp.  In .rodata
; rather than in registers because both functions were written to a clobber
; set their callers depend on, and rematerialising them inside a loop -- which
; ap_strcmp did, twice per eight bytes, at ten bytes of encoding each -- is
; twenty bytes of instruction fetch per iteration to save a load that is
; always L1-resident.
swar_ones:    dq 0x0101010101010101
swar_himask:  dq 0x8080808080808080

section .text

;; ============================================================================
;; ap_strcmp(const char *a, const char *b) -> int
;; 8-byte fast path with byte-at-a-time fallback, returns <0 / 0 / >0
;;
;; Safety: reading 8 bytes at a time is safe because all callers compare
;; PyStrObject.data which is inline after the header. Object allocation
;; always provides >=8 bytes past .data even for 1-char strings, due to
;; minimum object size and alignment.
;; ============================================================================
DEF_FUNC_BARE ap_strcmp
    ; rdi = a, rsi = b
.fast8:
    mov rax, [rdi]          ; load 8 bytes from a
    mov rdx, [rsi]          ; load 8 bytes from b
    cmp rax, rdx
    jne .byte_loop          ; mismatch -> fall back

    ; Check if NUL within these 8 bytes (Mycroft's trick).  Both constants
    ; used to be movabs'd inside this loop -- twenty bytes of encoding per
    ; eight bytes compared -- and r8 is no longer touched at all.
    mov rcx, rax
    sub rcx, [rel swar_ones]
    not rax
    and rcx, rax
    and rcx, [rel swar_himask]
    jnz .equal              ; NUL found -> strings equal

    add rdi, 8
    add rsi, 8
    jmp .fast8

.equal:
    xor eax, eax
    ret

.byte_loop:
    movzx eax, byte [rdi]
    movzx ecx, byte [rsi]
    sub eax, ecx
    jnz .done               ; bytes differ
    test cl, cl
    jz .done                 ; both NUL
    inc rdi
    inc rsi
    jmp .byte_loop
.done:
    ret
END_FUNC ap_strcmp


;; ============================================================================
;; ap_memfind(rdi = hay, rsi = hlen, rdx = needle, rcx = nlen)
;;   -> rax = pointer to the first match, or 0
;;
;; ap_strstr's length-aware sibling.  A Python str is counted, not
;; NUL-terminated: "a\x00b" is three characters, and every search over it that
;; went through ap_strstr stopped at the NUL and reported the tail missing.
;;
;; An empty needle matches at hay, as it does in CPython.  A needle longer than
;; what is left cannot match, which is also the loop's termination condition.
;; The first byte is checked before the inner loop is entered, so a mismatching
;; position costs one compare rather than a call frame -- ap_strstr re-entered
;; its inner loop at every offset, which is what made str.replace quadratic.
;; ============================================================================
AMF_HAY    equ 8
AMF_NEEDLE equ 16
AMF_NLEN   equ 24
AMF_LAST   equ 32           ; the last offset a match could start at
AMF_HLEN   equ 40
AMF_LIMIT  equ 48           ; rejected candidates before two-way takes over
AMF_FRAME  equ 48           ; + 2 pushes = 64, 16-byte aligned

DEF_FUNC_BARE ap_memfind
    ; No stack frame on this path.  str.count calls this once per occurrence,
    ; so a prologue here is paid per match, not per search -- building one
    ; before the one-byte test cost 40% on `s.count("a")` even though the
    ; scan itself got faster.  The frame lives in ap_memfind_multi.
    test rcx, rcx
    jz .amf_empty               ; the empty needle matches immediately
    mov rax, rsi
    sub rax, rcx
    js .amf_none                ; needle longer than haystack

    ; A one-byte needle IS ap_memchr -- CPython's search makes the same first
    ; split (`m <= 1` in Objects/stringlib/fastsearch.h).  str.replace and
    ; str.count over a single character are the common shape.
    cmp rcx, 1
    jne ap_memfind_multi
    movzx edx, byte [rdx]
    jmp ap_memchr               ; rdi = hay, rsi = hlen already
.amf_empty:
    mov rax, rdi
    ret
.amf_none:
    xor eax, eax
    ret
END_FUNC ap_memfind

;; ============================================================================
;; ap_memfind_multi(rdi = hay, rsi = hlen, rdx = needle, rcx = nlen)
;;   -> rax = the first match, or 0
;;
;; ap_memfind's needle-of-two-or-more arm, split out so that the one-byte case
;; reaches ap_memchr without a prologue.  Entered by tail jump, never called
;; directly; hlen >= nlen >= 2 is already established.
;; ============================================================================
DEF_FUNC_LOCAL ap_memfind_multi, AMF_FRAME
    push rbx
    push r12
    mov [rbp - AMF_HAY], rdi
    mov [rbp - AMF_HLEN], rsi
    mov [rbp - AMF_NEEDLE], rdx
    mov [rbp - AMF_NLEN], rcx
    mov rax, rsi
    sub rax, rcx
    mov [rbp - AMF_LAST], rax
    mov rbx, rdi                ; rbx = where the next scan starts
    ; How many candidates the memchr scan is allowed to reject before the
    ; two-way search takes over.  CPython's adaptive_find keeps the same kind
    ; of tally and for the same reason: this loop is O(n*m) on a needle whose
    ; prefix repeats, and the two-way search is O(n+m) but pays a
    ; factorization up front, so the switch has to be earned.
    ;
    ; A rejected candidate costs at most nlen bytes, so hlen/nlen + 1 of them
    ; cost at most hlen + nlen -- which makes the whole search linear whether
    ; it switches or not.  For an ordinary short needle in a long text the
    ; limit is in the hundreds of thousands and is never reached; for the
    ; `("a"*N + "b"*N)` shapes CPython's own test_adaptive_find builds it is
    ; two or three.
    mov rax, rsi
    xor edx, edx
    div rcx
    inc rax
    mov [rbp - AMF_LIMIT], rax
    xor r12d, r12d

.amf_loop:
    ; The first byte is found by ap_memchr rather than compared one at a time,
    ; so a position that cannot match costs an eighth of a compare instead of
    ; a whole one.  Only the region that could still START a match is scanned.
    mov rsi, [rbp - AMF_HAY]
    add rsi, [rbp - AMF_LAST]
    sub rsi, rbx                ; distance from here to the last valid start
    js .amf_no_match
    inc rsi                     ; ...as a count
    mov rdi, rbx
    mov rdx, [rbp - AMF_NEEDLE]
    movzx edx, byte [rdx]
    call ap_memchr
    test rax, rax
    jz .amf_no_match

    ; The first byte is in place; ap_memcmp settles the rest.
    mov rbx, rax
    lea rdi, [rax + 1]
    mov rsi, [rbp - AMF_NEEDLE]
    inc rsi
    mov rdx, [rbp - AMF_NLEN]
    dec rdx
    call ap_memcmp
    test eax, eax
    jz .amf_hit
    inc rbx

    ; A candidate that got as far as ap_memcmp and failed cost the whole
    ; needle.  Once that has happened more times than the needle is long, and
    ; there is enough haystack left to pay the factorization back, hand the
    ; rest to the two-way search.
    inc r12
    cmp r12, [rbp - AMF_LIMIT]
    jbe .amf_loop
    mov rax, [rbp - AMF_HAY]
    add rax, [rbp - AMF_HLEN]
    sub rax, rbx                ; bytes of haystack left from here
    cmp rax, 2000
    jl .amf_loop
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rbp - AMF_NEEDLE]
    mov rcx, [rbp - AMF_NLEN]
    call ap_memfind_twoway
    jmp .amf_out

.amf_hit:
    mov rax, rbx
    jmp .amf_out
.amf_no_match:
    xor eax, eax
.amf_out:
    pop r12
    pop rbx
    leave
    ret
END_FUNC ap_memfind_multi


;; ============================================================================
;; tw_lex_search(rdi = needle, rsi = nlen, edx = invert) -> rax = max_suffix,
;;                                                          rdx = period
;;
;; The maximal suffix of the needle under the ordinary alphabet order, or
;; under the inverted one when `invert` is set, and the period of the right
;; half that falls out of the same walk.  Crochemore and Perrin's critical
;; factorization is the later of the two cuts.
;;
;; Each iteration increases candidate + k + max_suffix, so the loop is linear
;; in the needle.
;; ============================================================================
DEF_FUNC_LOCAL tw_lex_search
    xor eax, eax                ; max_suffix
    mov r8d, 1                  ; candidate
    xor r9d, r9d                ; k
    mov r10d, 1                 ; period
.tls_loop:
    lea r11, [r8 + r9]
    cmp r11, rsi
    jge .tls_done
    movzx ecx, byte [rdi + r11] ; a = needle[candidate + k]
    lea r11, [rax + r9]
    movzx r11d, byte [rdi + r11] ; b = needle[max_suffix + k]
    test edx, edx
    jz .tls_plain
    xchg ecx, r11d              ; inverted alphabet: compare b < a instead
.tls_plain:
    cmp ecx, r11d
    jb .tls_short
    ja .tls_better
    ; a == b
    lea r11, [r9 + 1]
    cmp r11, r10
    je .tls_whole_period
    mov r9, r11
    jmp .tls_loop
.tls_whole_period:
    add r8, r10
    xor r9d, r9d
    jmp .tls_loop
.tls_short:
    lea r8, [r8 + r9 + 1]
    xor r9d, r9d
    mov r10, r8
    sub r10, rax                ; period = candidate - max_suffix
    jmp .tls_loop
.tls_better:
    mov rax, r8
    inc r8
    xor r9d, r9d
    mov r10d, 1
    jmp .tls_loop
.tls_done:
    mov rdx, r10
    leave
    ret
END_FUNC tw_lex_search

;; ============================================================================
;; ap_memfind_twoway(rdi = hay, rsi = hlen, rdx = needle, rcx = nlen)
;;   -> rax = pointer to the first match, or 0
;;
;; Crochemore and Perrin's (1991) two-way algorithm, as CPython's
;; Objects/stringlib/fastsearch.h implements it: O(n + m) whatever the input,
;; where the memchr-driven scan beside it is O(n * m) on a needle whose
;; prefix repeats.  CPython's own string_tests.test_adaptive_find builds
;; exactly that -- `("a"*N + "b"*N)` shapes at N = 1,000,000 -- and it is why
;; test_bytes, test_unicode and test_userstring used to be reported as HANG
;; rather than as failures.
;;
;; Three parts: the critical factorization (tw_lex_search, twice), a
;; compressed Boyer-Moore bad-character table over the low six bits of each
;; byte, and a window walk with two arms -- one for a periodic needle, which
;; needs a memory of how much of the last window already matched, and one for
;; an aperiodic needle, which does not.
;;
;; hlen >= nlen >= 2 is the caller's to establish.
;; ============================================================================
TW_HAY    equ 8
TW_HLEN   equ 16
TW_NEEDLE equ 24
TW_NLEN   equ 32
TW_CUT    equ 40
TW_PERIOD equ 48
TW_GAP    equ 56
TW_GJE    equ 64            ; gap_jump_end, the aperiodic arm's split
TW_MEMORY equ 72
TW_TABLE  equ 144           ; 64 one-byte shifts
TW_FRAME  equ 144           ; + 4 pushes = 176, 16-aligned

global ap_memfind_twoway
DEF_FUNC ap_memfind_twoway, TW_FRAME
    push rbx
    push r12
    push r13
    push r14
    mov [rbp - TW_HAY], rdi
    mov [rbp - TW_HLEN], rsi
    mov [rbp - TW_NEEDLE], rdx
    mov [rbp - TW_NLEN], rcx
    mov rbx, rdi
    mov r12, rdx

    ; --- the critical factorization: the later of the two maximal suffixes --
    mov rdi, r12
    mov rsi, rcx
    xor edx, edx
    call tw_lex_search
    ; The first pair goes straight into the frame: tw_lex_search itself uses
    ; r8 through r11, so holding cut1 and period1 in registers across the
    ; second call handed the periodicity test a cut of whatever the second
    ; search had left there -- and `"aba".find("aa")` answered 1.
    mov [rbp - TW_CUT], rax
    mov [rbp - TW_PERIOD], rdx
    mov rdi, r12
    mov rsi, [rbp - TW_NLEN]
    mov edx, 1
    call tw_lex_search
    ; Take the LATER cut, with the period that came with it.
    cmp [rbp - TW_CUT], rax
    jg .tw_take_first
    mov [rbp - TW_CUT], rax
    mov [rbp - TW_PERIOD], rdx
.tw_take_first:
    mov r8, [rbp - TW_CUT]
    mov r9, [rbp - TW_PERIOD]

    ; --- periodic?  needle[:cut] == needle[period:period+cut] --------------
    mov rdi, r12
    mov rsi, r12
    add rsi, r9
    mov rdx, r8
    test rdx, rdx
    jz .tw_periodic             ; an empty left half compares equal
    call ap_memcmp
    test eax, eax
    jnz .tw_aperiodic
.tw_periodic:
    mov qword [rbp - TW_GAP], 0
    mov r10d, 1                 ; is_periodic
    jmp .tw_table

.tw_aperiodic:
    ; period = max(cut, nlen - cut) + 1
    mov rax, [rbp - TW_NLEN]
    sub rax, [rbp - TW_CUT]
    cmp rax, [rbp - TW_CUT]
    jge .tw_ap_have
    mov rax, [rbp - TW_CUT]
.tw_ap_have:
    inc rax
    mov [rbp - TW_PERIOD], rax
    ; gap = the distance back to the previous byte equivalent (mod 64) to the
    ; last one, or nlen when there is none.
    mov rax, [rbp - TW_NLEN]
    mov [rbp - TW_GAP], rax
    mov rcx, rax
    dec rcx
    movzx r11d, byte [r12 + rcx]
    and r11d, 63
    dec rcx
.tw_gap_loop:
    test rcx, rcx
    js .tw_gap_done
    movzx eax, byte [r12 + rcx]
    and eax, 63
    cmp eax, r11d
    je .tw_gap_found
    dec rcx
    jmp .tw_gap_loop
.tw_gap_found:
    mov rax, [rbp - TW_NLEN]
    dec rax
    sub rax, rcx
    mov [rbp - TW_GAP], rax
.tw_gap_done:
    xor r10d, r10d              ; not periodic

.tw_table:
    ; --- the compressed bad-character table --------------------------------
    ; not_found_shift = min(nlen, 255), then the last `not_found_shift` bytes
    ; of the needle each write their own distance from the end.
    mov rax, [rbp - TW_NLEN]
    cmp rax, 255
    jle .tw_nfs_ok
    mov eax, 255
.tw_nfs_ok:
    mov r11, rax                ; not_found_shift
    lea rdi, [rbp - TW_TABLE]
    xor ecx, ecx
.tw_fill:
    cmp rcx, 64
    jge .tw_filled
    mov [rdi + rcx], al
    inc rcx
    jmp .tw_fill
.tw_filled:
    mov rcx, [rbp - TW_NLEN]
    sub rcx, r11                ; i = nlen - not_found_shift
.tw_shift_loop:
    cmp rcx, [rbp - TW_NLEN]
    jge .tw_shifted
    movzx eax, byte [r12 + rcx]
    and eax, 63
    mov rdx, [rbp - TW_NLEN]
    dec rdx
    sub rdx, rcx                ; nlen - 1 - i
    mov [rdi + rax], dl
    inc rcx
    jmp .tw_shift_loop
.tw_shifted:

    mov r13, [rbp - TW_NLEN]
    dec r13                     ; window_last = nlen - 1
    test r10d, r10d
    jnz .tw_periodic_search

    ; =====================================================================
    ; The aperiodic arm.
    ; =====================================================================
    ; period = max(gap, period); gap_jump_end = min(nlen, cut + gap)
    mov rax, [rbp - TW_GAP]
    cmp rax, [rbp - TW_PERIOD]
    jle .tw_ap_period_ok
    mov [rbp - TW_PERIOD], rax
.tw_ap_period_ok:
    mov rax, [rbp - TW_CUT]
    add rax, [rbp - TW_GAP]
    cmp rax, [rbp - TW_NLEN]
    jle .tw_gje_ok
    mov rax, [rbp - TW_NLEN]
.tw_gje_ok:
    mov [rbp - TW_GJE], rax

.tw_window_loop:
    cmp r13, [rbp - TW_HLEN]
    jge .tw_none
.tw_horspool:
    movzx eax, byte [rbx + r13]
    and eax, 63
    lea rdi, [rbp - TW_TABLE]
    movzx eax, byte [rdi + rax]
    add r13, rax
    test eax, eax
    jz .tw_aligned
    cmp r13, [rbp - TW_HLEN]
    jge .tw_none
    jmp .tw_horspool
.tw_aligned:
    ; window = window_last - nlen + 1
    mov r8, r13
    sub r8, [rbp - TW_NLEN]
    inc r8                      ; r8 = window index into hay

    ; the early right half: a mismatch here is worth exactly `gap`
    mov r14, [rbp - TW_CUT]
.tw_early:
    cmp r14, [rbp - TW_GJE]
    jge .tw_late_start
    mov rax, r8
    add rax, r14
    movzx ecx, byte [rbx + rax]
    cmp cl, [r12 + r14]
    jne .tw_early_bad
    inc r14
    jmp .tw_early
.tw_early_bad:
    add r13, [rbp - TW_GAP]
    jmp .tw_window_loop

.tw_late_start:
    mov r14, [rbp - TW_GJE]
.tw_late:
    cmp r14, [rbp - TW_NLEN]
    jge .tw_left_start
    mov rax, r8
    add rax, r14
    movzx ecx, byte [rbx + rax]
    cmp cl, [r12 + r14]
    jne .tw_late_bad
    inc r14
    jmp .tw_late
.tw_late_bad:
    add r13, r14
    sub r13, [rbp - TW_CUT]
    inc r13
    jmp .tw_window_loop

.tw_left_start:
    xor r14d, r14d
.tw_left:
    cmp r14, [rbp - TW_CUT]
    jge .tw_found
    mov rax, r8
    add rax, r14
    movzx ecx, byte [rbx + rax]
    cmp cl, [r12 + r14]
    jne .tw_left_bad
    inc r14
    jmp .tw_left
.tw_left_bad:
    add r13, [rbp - TW_PERIOD]
    jmp .tw_window_loop

.tw_found:
    lea rax, [rbx + r8]
    jmp .tw_out
.tw_none:
    xor eax, eax
.tw_out:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

    ; =====================================================================
    ; The periodic arm.  `memory` records how much of the window the last
    ; comparison already proved, so a needle that is its own repetition does
    ; not re-compare the overlap -- which is what keeps this linear.
    ; =====================================================================
.tw_periodic_search:
    mov qword [rbp - TW_MEMORY], 0
.tw_pwindow_loop:
    cmp r13, [rbp - TW_HLEN]
    jge .tw_none
.tw_phorspool:
    movzx eax, byte [rbx + r13]
    and eax, 63
    lea rdi, [rbp - TW_TABLE]
    movzx eax, byte [rdi + rax]
    add r13, rax
    test eax, eax
    jz .tw_pno_shift
    cmp r13, [rbp - TW_HLEN]
    jge .tw_none
    jmp .tw_phorspool

.tw_pno_shift:
    mov r8, r13
    sub r8, [rbp - TW_NLEN]
    inc r8                      ; window index

    ; the right half, from max(cut, memory)
    mov r14, [rbp - TW_CUT]
    cmp r14, [rbp - TW_MEMORY]
    jge .tw_pright
    mov r14, [rbp - TW_MEMORY]
.tw_pright:
    cmp r14, [rbp - TW_NLEN]
    jge .tw_pleft_start
    mov rax, r8
    add rax, r14
    movzx ecx, byte [rbx + rax]
    cmp cl, [r12 + r14]
    jne .tw_pright_bad
    inc r14
    jmp .tw_pright
.tw_pright_bad:
    add r13, r14
    sub r13, [rbp - TW_CUT]
    inc r13
    mov qword [rbp - TW_MEMORY], 0
    jmp .tw_pwindow_loop

.tw_pleft_start:
    mov r14, [rbp - TW_MEMORY]
.tw_pleft:
    cmp r14, [rbp - TW_CUT]
    jge .tw_pfound
    mov rax, r8
    add rax, r14
    movzx ecx, byte [rbx + rax]
    cmp cl, [r12 + r14]
    jne .tw_pleft_bad
    inc r14
    jmp .tw_pleft
.tw_pleft_bad:
    ; The left half failed: shift by a whole period and remember that the
    ; overlap is already known to match.
    add r13, [rbp - TW_PERIOD]
    mov rax, [rbp - TW_NLEN]
    sub rax, [rbp - TW_PERIOD]
    mov [rbp - TW_MEMORY], rax
    cmp r13, [rbp - TW_HLEN]
    jge .tw_none
    movzx eax, byte [rbx + r13]
    and eax, 63
    lea rdi, [rbp - TW_TABLE]
    movzx eax, byte [rdi + rax]
    test eax, eax
    jz .tw_pno_shift            ; still aligned: compare again from memory
    ; A mismatch was identified to the right of where the next comparison
    ; would start, so at least the first-comparison jump is safe.
    mov rcx, [rbp - TW_CUT]
    cmp rcx, [rbp - TW_MEMORY]
    jge .tw_pmem_have
    mov rcx, [rbp - TW_MEMORY]
.tw_pmem_have:
    sub rcx, [rbp - TW_CUT]
    inc rcx                     ; mem_jump
    cmp rax, rcx
    jge .tw_pjump
    mov rax, rcx
.tw_pjump:
    mov qword [rbp - TW_MEMORY], 0
    add r13, rax
    jmp .tw_pwindow_loop

.tw_pfound:
    lea rax, [rbx + r8]
    jmp .tw_out
END_FUNC ap_memfind_twoway

;; ============================================================================
;; ap_memrfind(rdi = hay, rsi = hlen, rdx = needle, rcx = nlen)
;;   -> rax = pointer to the *last* match, or 0
;;
;; ap_memfind walking down instead of up, for rfind and rindex.  An empty
;; needle matches at the end of the range, which is what "the last place it
;; occurs" means and what CPython returns.
;; ============================================================================
DEF_FUNC_BARE ap_memrfind
    mov r8, rsi
    sub r8, rcx                 ; r8 = last offset a match could start at
    js .amr_none                ; needle longer than haystack
    test rcx, rcx
    jz .amr_empty               ; empty needle: matches at the far end
    movzx r9d, byte [rdx]
    mov r10, r8                 ; r10 = current offset, counting down

.amr_outer:
    test r10, r10
    jl .amr_none
    cmp r9b, [rdi + r10]
    jne .amr_next
    lea r11, [rdi + r10]
    mov eax, 1
.amr_inner:
    cmp rax, rcx
    jge .amr_hit
    mov sil, [rdx + rax]
    cmp sil, [r11 + rax]
    jne .amr_next
    inc rax
    jmp .amr_inner
.amr_next:
    dec r10
    jmp .amr_outer

.amr_hit:
    mov rax, r11
    ret
.amr_empty:
    lea rax, [rdi + r8]
    ret
.amr_none:
    xor eax, eax
    ret
END_FUNC ap_memrfind


;; ============================================================================
;; Dying without an interpreter
;; (was src/error.asm)
;; ============================================================================

section .text

; Uses raw Linux syscalls instead of libc stdio

;; ============================================================================
;; fatal_error(const char *msg)
;; Prints "Error: <msg>\n" to stderr and exits with code 1. Never returns.
;; ============================================================================
DEF_FUNC fatal_error, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi            ; save msg

    ; sys_write(2, "Error: ", 7)
    mov edi, 2
    lea rsi, [rel err_prefix]
    mov edx, 7
    call sys_write

    ; strlen(msg) inline
    mov rdi, rbx
    xor ecx, ecx
.strlen_loop:
    cmp byte [rdi + rcx], 0
    je .strlen_done
    inc rcx
    jmp .strlen_loop
.strlen_done:

    ; sys_write(2, msg, len)
    mov edi, 2
    mov rsi, rbx
    mov rdx, rcx
    call sys_write

    ; sys_write(2, "\n", 1)
    mov edi, 2
    lea rsi, [rel err_newline]
    mov edx, 1
    call sys_write

    ; sys_exit(1)
    mov edi, 1
    call sys_exit
END_FUNC fatal_error


;; ============================================================================
;; error_unimplemented_opcode(int opcode)
;; Reports unimplemented bytecode opcode and exits
;; ============================================================================
EUO_END   equ 1              ; one past the digits: holds the newline
DEF_FUNC error_unimplemented_opcode, 32             ; space for decimal digits

    mov eax, edi            ; opcode value

    ; Convert opcode int to decimal string on stack
    lea rdi, [rbp - EUO_END]     ; write digits right-to-left
    mov byte [rdi], 10      ; trailing newline
    lea rcx, [rbp - EUO_END]     ; rcx = end (points at newline)
    mov r8d, 10

.digit_loop:
    xor edx, edx
    div r8d                 ; eax = quot, edx = rem
    dec rdi
    add dl, '0'
    mov [rdi], dl
    test eax, eax
    jnz .digit_loop

    ; rdi = start of digits, rcx = newline position
    ; length = rcx - rdi + 1 (include newline)
    mov r8, rcx
    sub r8, rdi
    inc r8                  ; r8 = length of digits + newline

    ; Save digit start and length
    mov rbx, rdi
    mov r9, r8

    ; sys_write(2, prefix, prefix_len)
    mov edi, 2
    lea rsi, [rel err_op_prefix]
    mov edx, err_op_prefix_len
    call sys_write

    ; sys_write(2, digits_and_newline, len)
    mov edi, 2
    mov rsi, rbx
    mov rdx, r9
    call sys_write

    ; sys_exit(1)
    mov edi, 1
    call sys_exit
END_FUNC error_unimplemented_opcode

;; ============================================================================
;; set_list_sorting_error() -> rax = 0, always, with the ValueError pending
;;
;; What a list method says when ob_item == NULL: the list is being sorted,
;; and the sort holds its array.
;; ============================================================================
DEF_FUNC set_list_sorting_error
    extern exc_ValueError_type
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel list_modified_msg]
    extern set_exception
    call set_exception
    xor eax, eax
    leave
    ret
END_FUNC set_list_sorting_error

section .rodata
err_prefix: db "Error: "
err_newline: db 10
err_op_prefix: db "Error: unimplemented opcode "
err_op_prefix_len equ $ - err_op_prefix
list_modified_msg: db "list modified during sort", 0

section .text

;; ============================================================================
;; sys_fork(void) -> pid_t
;; ============================================================================
DEF_FUNC_BARE sys_fork
    mov rax, SYS_fork
    syscall
    ret
END_FUNC sys_fork

;; ============================================================================
;; sys_execve(const char *path, char *const argv[], char *const envp[]) -> int
;; Only ever returns on failure.
;; ============================================================================
DEF_FUNC_BARE sys_execve
    mov rax, SYS_execve
    syscall
    ret
END_FUNC sys_execve

;; ============================================================================
;; sys_exit_now(int code) -> noreturn
;; The bare _exit: no flush, no atexit, which is what a forked child that
;; failed to exec must call rather than unwinding through the parent's state.
;;
;; exit_group, not exit.  The exit syscall ends the calling THREAD; it ended
;; the process only while there was one thread to end.  os._exit() from a
;; second thread left the process running without it -- and that thread held
;; the GIL, so every other thread waited on it for ever.
;; ============================================================================
DEF_FUNC_BARE sys_exit_now
    mov rax, SYS_exit_group
    syscall
    ud2
END_FUNC sys_exit_now

;; ============================================================================
;; sys_close_range(unsigned first, unsigned last, int flags) -> int
;; Linux 5.9.  The only way to shut every inherited descriptor without
;; enumerating /proc, which is what a forked child cannot safely read.
;; ============================================================================
DEF_FUNC_BARE sys_close_range
    mov rax, SYS_close_range
    syscall
    ret
END_FUNC sys_close_range

;; ============================================================================
;; sys_kill(pid_t pid, int sig) -> int
;; ============================================================================
DEF_FUNC_BARE sys_kill
    mov rax, SYS_kill
    syscall
    ret
END_FUNC sys_kill

;; ============================================================================
;; sys_alarm(unsigned int seconds) -> unsigned int
;; The seconds left on the previous alarm, or 0 when there was none.
;; ============================================================================
global sys_alarm
DEF_FUNC_BARE sys_alarm
    mov rax, SYS_alarm
    syscall
    ret
END_FUNC sys_alarm

;; ============================================================================
;; sys_pause(void) -> int
;; Blocks until a signal is delivered; always -EINTR when it returns.
;; ============================================================================
global sys_pause
DEF_FUNC_BARE sys_pause
    mov rax, SYS_pause
    syscall
    ret
END_FUNC sys_pause

;; ============================================================================
;; sys_setsid(void) -> pid_t
;; ============================================================================
DEF_FUNC_BARE sys_setsid
    mov rax, SYS_setsid
    syscall
    ret
END_FUNC sys_setsid

;; ============================================================================
;; sys_pidfd_open(pid_t pid, unsigned int flags) -> int fd
;; ============================================================================
global sys_pidfd_open
DEF_FUNC_BARE sys_pidfd_open
    mov rax, SYS_pidfd_open
    syscall
    ret
END_FUNC sys_pidfd_open

;; ============================================================================
;; sys_sendmsg(int fd, const struct msghdr *msg, int flags) -> ssize_t
;; ============================================================================
global sys_sendmsg
DEF_FUNC_BARE sys_sendmsg
    mov rax, SYS_sendmsg
    syscall
    ret
END_FUNC sys_sendmsg
