; thread.asm - the `_threadcore` module: OS threads and the lock they wait on.
;
; The split src/modules/zlib.asm sets out.  What has to be machine work lives
; here -- pthread_create and the entry point a new thread starts at, a
; ThreadState for it, and a lock that gives the GIL up while it waits -- and
; everything a Python program sees is lib/_thread.py: the lock CLASS, the
; argument checking, the excepthook, the sentinels Thread.join waits on.
; Every function here takes fixed positional arguments.
;
; A thread is a pthread, not a raw clone: glibc's malloc arenas, errno,
; OpenSSL's error queue and libffi all live in the thread descriptor glibc
; keeps on fs.  The interpreter's own per-thread state is the ThreadState on
; gs (src/include/threadstate.inc), allocated here and installed as the first
; thing the new thread does -- a clone inherits its creator's gs base, so
; until then it is looking at someone else's.
;
; The new thread ALWAYS runs a Python function at the bottom of its stack:
; `_thread._bootstrap(function, args, kwargs)`.  That is not for tidiness.
; A raise with no interpreter frame beneath it is fatal_error -- the unwinder
; has nowhere to land -- and a builtin called directly would raise exactly
; there.  With a Python frame underneath, an exception reaches eval_return
; and the call comes back here with NULL, which is the property
; src/modules/pyexpat_cb.asm records and rests on.
;
; A lock is a POSIX semaphore, as CPython's is on Linux, addressed by a
; handle that is its address.  The fast path is sem_trywait under the GIL;
; the slow path gives the GIL up, waits, and takes it back.  A signal
; interrupts the wait only on the main thread -- every other thread is
; created with all signals blocked -- and the handler runs between retries.

%include "macros.inc"
%include "object.inc"
%include "threadstate.inc"
%include "gil.inc"

ASM_INIT

extern none_singleton
extern bool_true
extern bool_false
extern ap_malloc
extern ap_free
extern dict_new
extern dict_set
extern module_new
extern obj_decref
extern obj_dealloc
extern obj_call_n
extern str_from_cstr_heap
extern builtin_func_new
extern int_from_i64
extern obj_as_index
extern set_exception
extern exc_RuntimeError_type
extern exc_ValueError_type
extern tstate_install
extern tstate_link
extern tstate_unlink
extern gil_take
extern gil_drop
extern gil_threaded
extern signal_run_pending
extern signal_mark_pending
extern systrace_install
extern sysprofile_install

extern pthread_create
extern pthread_self
extern pthread_attr_init
extern pthread_attr_destroy
extern pthread_attr_setdetachstate
extern pthread_attr_setstacksize
extern pthread_sigmask
extern sigfillset
extern aligned_alloc
extern free
extern sem_init
extern sem_destroy
extern sem_trywait
extern sem_wait
extern sem_clockwait
extern sem_post
extern sem_getvalue
extern clock_gettime
extern confstr
extern gil_interval_ns
extern __errno_location

SYS_gettid              equ 186
PTHREAD_CREATE_DETACHED equ 1
SIG_SETMASK             equ 2
CLOCK_MONOTONIC         equ 1
EINTR_ERRNO             equ 4
NS_PER_SEC              equ 1000000000
SEM_SIZE                equ 32          ; sizeof(sem_t) on x86-64 glibc
TSTATE_ALLOC            equ (ThreadState_size + 63) & ~63

; What start() hands the new thread.
struc ThreadStart
    .tstate:    resq 1      ; its ThreadState, zeroed
    .bootstrap: resq 1      ; _thread._bootstrap
    .argv:      resq 3      ; function, args, kwargs: the bootstrap's arguments
endstruc

section .data
align 8
tc_running:    dq 0         ; threads started here and not yet finished
tc_stack_size: dq 0         ; bytes, or 0 for the platform's default

section .text

;; ============================================================================
;; tc_int_arg(rdi = args, rsi = index) -> rax = that argument as an int64
;;
;; TypeError for anything that is not an integer.
;; Fails: -1
;; ============================================================================
DEF_FUNC_LOCAL tc_int_arg
    mov rdi, [rdi + rsi*8]
    V_UNPACK rdi, rdx
    call obj_as_index           ; err: its -1 and its exception are ours
    leave
    ret
END_FUNC tc_int_arg

;; ============================================================================
;; thread_entry(rdi = ThreadStart*) -> rax = NULL
;;
;; Where a new pthread begins.  Called by glibc, so the SysV ABI holds and
;; nothing about the interpreter's registers can be assumed.  gs is installed
;; before anything else: every later line reads through it.
;; ============================================================================
TE_FRAME equ 8                  ; + 5 pushes = 48, 16-aligned
DEF_FUNC_LOCAL thread_entry, TE_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi

    mov rdi, [rbx + ThreadStart.tstate]
    call tstate_install
    extern rt_tid_alloc
    call rt_tid_alloc
    mov [gs:ThreadState.ts_tid], eax
    mov dword [gs:ThreadState.ts_state], 0
    mov rdi, [gs:ThreadState.ts_self]
    extern brc_register_thread
    call brc_register_thread
    call pthread_self
    mov [gs:ThreadState.ts_ident], rax
    mov eax, SYS_gettid
    syscall
    mov [gs:ThreadState.ts_native_id], rax

    call gil_take
    call tstate_link
    inc qword [rel tc_running]

    mov rdi, [rbx + ThreadStart.bootstrap]
    lea rsi, [rbx + ThreadStart.argv]
    mov edx, 3
    call obj_call_n
    ERR_NULL .te_raised
    DECREF_V rax, rcx
    jmp .te_finished
.te_raised:
    ; The bootstrap lets nothing out.  If something got past it anyway there
    ; is nobody to hand it to; it must not stay set on a dying thread.
    mov rdi, [gs:ThreadState.current_exception]
    test rdi, rdi
    jz .te_finished
    mov qword [gs:ThreadState.current_exception], 0
    call obj_decref

.te_finished:
    ; The references start() took.
    mov rdi, [rbx + ThreadStart.bootstrap]
    DECREF_V rdi, rcx
    mov rdi, [rbx + ThreadStart.argv]
    DECREF_V rdi, rcx
    mov rdi, [rbx + ThreadStart.argv + 8]
    DECREF_V rdi, rcx
    mov rdi, [rbx + ThreadStart.argv + 16]
    DECREF_V rdi, rcx
    mov rdi, rbx
    call ap_free

    ; Release Python state while the thread still owns the GIL.
    extern native_asyncio_clear_running_loop
    call native_asyncio_clear_running_loop
    extern sre_cpcache_clear_thread
    call sre_cpcache_clear_thread
    mov rdi, [gs:ThreadState.ts_import_ns_portions]
    test rdi, rdi
    jz .te_no_ns_portions
    mov qword [gs:ThreadState.ts_import_ns_portions], 0
    call obj_decref
.te_no_ns_portions:
    mov rdi, [gs:ThreadState.ts_dict]
    test rdi, rdi
    jz .te_no_dict
    mov qword [gs:ThreadState.ts_dict], 0
    call obj_decref
.te_no_dict:
    mov rdi, [gs:ThreadState.frame_datastack_base]
    test rdi, rdi
    jz .te_no_stack
    call ap_free
.te_no_stack:
    mov rdi, [gs:ThreadState.repr_stack]
    test rdi, rdi
    jz .te_no_repr
    call ap_free
.te_no_repr:
    ; Its trace and profile functions go back, and with the last tracing
    ; thread the dispatch table goes back to the plain one.
    mov rdi, [gs:ThreadState.ts_self]
    xor esi, esi
    call systrace_install
    mov rdi, [gs:ThreadState.ts_self]
    xor esi, esi
    call sysprofile_install
    call tstate_unlink
    dec qword [rel tc_running]
    mov rdi, [gs:ThreadState.ts_self]
    extern brc_unregister_thread
    call brc_unregister_thread

    ; Past this line the thread holds no GIL and touches no object.  The
    ; ThreadState, ssl_pw_buf and path_scratch came from libc.
    mov r12, [gs:ThreadState.ts_self]
    call gil_drop
    mov rdi, [r12 + ThreadState.ssl_pw_buf]
    test rdi, rdi
    jz .te_no_ssl_pw
    call free
.te_no_ssl_pw:
    mov rdi, [r12 + ThreadState.ts_path_scratch]
    test rdi, rdi
    jz .te_no_path_scratch
    call free
.te_no_path_scratch:
    mov rdi, r12
    call free

    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC thread_entry

;; ============================================================================
;; _threadcore.start(bootstrap, function, args, kwargs) -> the thread's ident
;; Fails: 0
;;
;; Start a pthread that calls bootstrap(function, args, kwargs).  The thread
;; is detached -- nothing joins it at the pthread level; Thread.join waits on
;; a lock the bootstrap releases -- and is created with every signal blocked,
;; so the kernel delivers signals to the main thread, where handlers run.
;; ============================================================================
TS_TID    equ 8                 ; pthread_t
TS_ATTR   equ 72                ; pthread_attr_t, 56 bytes, in 64
TS_NEWSET equ 200               ; sigset_t, 128 bytes: everything
TS_OLDSET equ 328               ; sigset_t: the mask to put back
TS_RC     equ 336               ; what pthread_create answered
TS_FRAME  equ 336               ; + 2 pushes = 352, 16-aligned
DEF_FUNC tc_start, TS_FRAME
    push rbx
    push r12
    mov r12, rdi                ; args

    mov edi, ThreadStart_size
    call ap_malloc
    mov rbx, rax
    mov rax, [r12]
    INCREF_V rax, rcx
    mov [rbx + ThreadStart.bootstrap], rax
    mov rax, [r12 + 8]
    INCREF_V rax, rcx
    mov [rbx + ThreadStart.argv], rax
    mov rax, [r12 + 16]
    INCREF_V rax, rcx
    mov [rbx + ThreadStart.argv + 8], rax
    mov rax, [r12 + 24]
    INCREF_V rax, rcx
    mov [rbx + ThreadStart.argv + 16], rax

    ; The ThreadState: zeroed, and line-aligned as main_tstate is.
    mov edi, 64
    mov esi, TSTATE_ALLOC
    call aligned_alloc
    mov [rbx + ThreadStart.tstate], rax
    test rax, rax
    jz .ts_failed
    mov rdi, rax
    mov ecx, TSTATE_ALLOC / 8
    xor eax, eax
    rep stosq

    ; From here the GIL is real: blocking calls give it up.
    mov qword [rel gil_threaded], 1

    lea rdi, [rbp - TS_ATTR]
    call pthread_attr_init
    lea rdi, [rbp - TS_ATTR]
    mov esi, PTHREAD_CREATE_DETACHED
    call pthread_attr_setdetachstate
    mov rsi, [rel tc_stack_size]
    test rsi, rsi
    jz .ts_default_stack
    lea rdi, [rbp - TS_ATTR]
    call pthread_attr_setstacksize
.ts_default_stack:

    lea rdi, [rbp - TS_NEWSET]
    call sigfillset
    mov edi, SIG_SETMASK
    lea rsi, [rbp - TS_NEWSET]
    lea rdx, [rbp - TS_OLDSET]
    call pthread_sigmask

    lea rdi, [rbp - TS_TID]
    lea rsi, [rbp - TS_ATTR]
    lea rdx, [rel thread_entry]
    mov rcx, rbx
    call pthread_create
    mov [rbp - TS_RC], rax

    mov edi, SIG_SETMASK
    lea rsi, [rbp - TS_OLDSET]
    xor edx, edx
    call pthread_sigmask
    lea rdi, [rbp - TS_ATTR]
    call pthread_attr_destroy

    cmp dword [rbp - TS_RC], 0
    jne .ts_failed

    mov rdi, [rbp - TS_TID]
    call int_from_i64
    V_PACK rax, rdx
    pop r12
    pop rbx
    leave
    ret

.ts_failed:
    ; Nothing started: give back what the thread would have released.
    mov rdi, [rbx + ThreadStart.tstate]
    call free                   ; free(NULL) is defined
    mov rdi, [rbx + ThreadStart.bootstrap]
    DECREF_V rdi, rcx
    mov rdi, [rbx + ThreadStart.argv]
    DECREF_V rdi, rcx
    mov rdi, [rbx + ThreadStart.argv + 8]
    DECREF_V rdi, rcx
    mov rdi, [rbx + ThreadStart.argv + 16]
    DECREF_V rdi, rcx
    mov rdi, rbx
    call ap_free
    SET_EXC exc_RuntimeError_type, "can't start new thread"
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC tc_start

;; ============================================================================
;; thread_running_reset() -> nothing
;;
;; The child of a fork has no threads but the one that forked.
;; ============================================================================
global thread_running_reset
DEF_FUNC_BARE thread_running_reset
    mov qword [rel tc_running], 0
    ret
END_FUNC thread_running_reset

;; ============================================================================
;; _threadcore.get_ident() -> pthread_self() as an int
;; ============================================================================
DEF_FUNC tc_get_ident
    call pthread_self
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret
END_FUNC tc_get_ident

;; ============================================================================
;; _threadcore.get_native_id() -> gettid() as an int
;; ============================================================================
DEF_FUNC tc_get_native_id
    mov eax, SYS_gettid
    syscall
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret
END_FUNC tc_get_native_id

;; ============================================================================
;; _threadcore.count() -> how many threads started here are still running
;; ============================================================================
DEF_FUNC tc_count
    mov rdi, [rel tc_running]
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret
END_FUNC tc_count

;; ============================================================================
;; _threadcore.set_stack_size(bytes) -> the previous setting
;;
;; 0 means the platform's default.  Validation is lib/_thread.py's.
;; ============================================================================
SSS_FRAME equ 16                ; + 0 pushes = 16, 16-aligned
DEF_FUNC tc_set_stack_size, SSS_FRAME
    xor esi, esi
    call tc_int_arg
    ERR_M1 .fail
    mov rdi, [rel tc_stack_size]
    mov [rel tc_stack_size], rax
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret
.fail:
    xor eax, eax
    leave
    ret
END_FUNC tc_set_stack_size

;; ============================================================================
;; _threadcore.thread_dict() -> this thread's own dict, made on first use
;;
;; What _thread._local keeps its per-thread namespaces in.  Released when the
;; thread ends.
;; ============================================================================
DEF_FUNC tc_thread_dict
    mov rax, [gs:ThreadState.ts_dict]
    test rax, rax
    jnz .ttd_have
    call dict_new
    mov [gs:ThreadState.ts_dict], rax
.ttd_have:
    INCREF rax
    leave
    ret
END_FUNC tc_thread_dict

;; ============================================================================
;; _threadcore.interrupt_main(signum) -> None
;;
;; Mark a signal as arrived for the main thread, without sending one.
;; ============================================================================
DEF_FUNC tc_interrupt_main
    xor esi, esi
    call tc_int_arg
    ERR_M1 .fail
    mov rdi, rax
    call signal_mark_pending
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
.fail:
    xor eax, eax
    leave
    ret
END_FUNC tc_interrupt_main

;; ============================================================================
;; _threadcore.lock_new() -> a handle: the address of an unlocked semaphore
;; ============================================================================
LN_FRAME equ 8                  ; + 1 push = 16, 16-aligned
DEF_FUNC tc_lock_new, LN_FRAME
    push rbx
    mov edi, SEM_SIZE
    call ap_malloc
    mov rbx, rax
    mov rdi, rax
    xor esi, esi                ; not shared between processes
    mov edx, 1                  ; one holder at a time
    call sem_init
    mov rdi, rbx
    call int_from_i64
    V_PACK rax, rdx
    pop rbx
    leave
    ret
END_FUNC tc_lock_new

;; ============================================================================
;; _threadcore.lock_free(handle) -> None
;; ============================================================================
LF_FRAME equ 8                  ; + 1 push = 16, 16-aligned
DEF_FUNC tc_lock_free, LF_FRAME
    push rbx
    xor esi, esi
    call tc_int_arg
    ERR_M1 .fail
    mov rbx, rax
    mov rdi, rax
    call sem_destroy
    mov rdi, rbx
    call ap_free
    RET_NONE
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC tc_lock_free

;; ============================================================================
;; _threadcore.lock_reinit(handle) -> None
;;
;; Back to unlocked, whatever it was: _at_fork_reinit, for the child of a
;; fork that inherited a lock some vanished thread held.
;; ============================================================================
DEF_FUNC tc_lock_reinit
    xor esi, esi
    call tc_int_arg
    ERR_M1 .fail
    mov rdi, rax
    xor esi, esi
    mov edx, 1
    call sem_init
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
.fail:
    xor eax, eax
    leave
    ret
END_FUNC tc_lock_reinit

;; ============================================================================
;; _threadcore.lock_acquire(handle, timeout_ns) -> True if taken, else False
;;
;; timeout_ns < 0 waits for ever, 0 does not wait, anything else is how long.
;; The GIL is given up for the wait.  A signal that interrupts it runs its
;; Python handler here, on the main thread, and the wait resumes with the
;; ORIGINAL deadline; a handler that raises ends it, and the answer is NULL
;; with that exception pending.
;; ============================================================================
LA_TMO   equ 8
LA_TS    equ 24                 ; struct timespec: tv_sec, tv_nsec above it
LA_ERR   equ 32                 ; errno from the wait, read before the GIL
LA_FRAME equ 40                 ; + 1 push = 48, 16-aligned
DEF_FUNC tc_lock_acquire, LA_FRAME
    push rbx
    mov rbx, rdi                ; args, for the moment
    mov esi, 1
    call tc_int_arg
    ERR_M1 .la_fail
    mov [rbp - LA_TMO], rax
    mov rdi, rbx
    xor esi, esi
    call tc_int_arg
    ERR_M1 .la_fail
    mov rbx, rax                ; the semaphore

    mov rdi, rbx
    call sem_trywait
    test eax, eax
    jz .la_taken
    cmp qword [rbp - LA_TMO], 0
    je .la_not_taken
    jl .la_wait                 ; for ever: no deadline to work out

    ; deadline = now + timeout, on the clock sem_clockwait is told to use
    mov edi, CLOCK_MONOTONIC
    lea rsi, [rbp - LA_TS]
    call clock_gettime
    mov rax, [rbp - LA_TMO]
    xor edx, edx
    mov ecx, NS_PER_SEC
    div rcx                     ; rax = seconds, rdx = nanoseconds
    add [rbp - LA_TS], rax
    add rdx, [rbp - LA_TS + 8]
    cmp rdx, NS_PER_SEC
    jb .la_deadline
    sub rdx, NS_PER_SEC
    inc qword [rbp - LA_TS]
.la_deadline:
    mov [rbp - LA_TS + 8], rdx

.la_wait:
    ALLOW_THREADS_BEGIN
    cmp qword [rbp - LA_TMO], 0
    jl .la_forever
    mov rdi, rbx
    mov esi, CLOCK_MONOTONIC
    lea rdx, [rbp - LA_TS]
    call sem_clockwait
    jmp .la_waited
.la_forever:
    mov rdi, rbx
    call sem_wait
.la_waited:
    mov dword [rbp - LA_ERR], 0
    test eax, eax
    jz .la_back
    call __errno_location       ; this thread's errno, before anything else runs
    mov eax, [rax]
    mov [rbp - LA_ERR], eax
    mov eax, -1
.la_back:
    ALLOW_THREADS_END           ; rax survives
    test eax, eax
    jz .la_taken
    cmp dword [rbp - LA_ERR], EINTR_ERRNO
    jne .la_not_taken           ; ETIMEDOUT
    call signal_run_pending
    test eax, eax
    jz .la_wait
    xor eax, eax                ; the handler raised: NULL, exception pending
    pop rbx
    leave
    ret

.la_taken:
    lea rax, [rel bool_true]
    INCREF rax
    pop rbx
    leave
    ret
.la_not_taken:
    lea rax, [rel bool_false]
    INCREF rax
    pop rbx
    leave
    ret
.la_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC tc_lock_acquire

;; ============================================================================
;; _threadcore.lock_release(handle) -> None
;;
;; Raises RuntimeError for a lock nobody holds.  Any thread may release it;
;; that is what makes it usable as a signal between threads.
;; ============================================================================
LR_VAL   equ 8                  ; sem_getvalue's int
LR_FRAME equ 8                  ; + 1 push = 16, 16-aligned
DEF_FUNC tc_lock_release, LR_FRAME
    push rbx
    xor esi, esi
    call tc_int_arg
    ERR_M1 .fail
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rbp - LR_VAL]
    call sem_getvalue
    cmp dword [rbp - LR_VAL], 0
    jg .lr_unlocked
    mov rdi, rbx
    call sem_post
    RET_NONE
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.lr_unlocked:
    SET_EXC exc_RuntimeError_type, "release unlocked lock"
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC tc_lock_release

;; ============================================================================
;; _threadcore.lock_locked(handle) -> True while some thread holds it
;; ============================================================================
LL_VAL   equ 8
LL_FRAME equ 16                 ; + 0 pushes = 16, 16-aligned
DEF_FUNC tc_lock_locked, LL_FRAME
    xor esi, esi
    call tc_int_arg
    ERR_M1 .fail
    mov rdi, rax
    lea rsi, [rbp - LL_VAL]
    call sem_getvalue
    lea rax, [rel bool_true]
    cmp dword [rbp - LL_VAL], 0
    jle .ll_have
    lea rax, [rel bool_false]
.ll_have:
    INCREF rax
    leave
    ret
.fail:
    xor eax, eax
    leave
    ret
END_FUNC tc_lock_locked

;; ============================================================================
;; thread_info_version() -> rax = a new str such as "NPTL 2.39", or None
;;
;; sys.thread_info.version: the thread library's own name for itself.
;; ============================================================================
CS_GNU_LIBPTHREAD_VERSION equ 3
TIV_BUF   equ 64
TIV_FRAME equ 64                ; + 0 pushes = 64, 16-aligned
global thread_info_version
DEF_FUNC thread_info_version, TIV_FRAME
    mov edi, CS_GNU_LIBPTHREAD_VERSION
    lea rsi, [rbp - TIV_BUF]
    mov edx, TIV_BUF
    call confstr
    test rax, rax
    jz .tiv_none
    cmp rax, TIV_BUF
    ja .tiv_none                ; longer than anything it has ever been
    lea rdi, [rbp - TIV_BUF]
    call str_from_cstr_heap
    leave
    ret
.tiv_none:
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
END_FUNC thread_info_version

;; ============================================================================
;; _threadcore.get_interval() -> the GIL switch interval, in nanoseconds
;; ============================================================================
DEF_FUNC tc_get_interval
    mov rdi, [rel gil_interval_ns]
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret
END_FUNC tc_get_interval

;; ============================================================================
;; _threadcore.set_interval(nanoseconds) -> None
;;
;; How long a thread waits for the GIL before asking its holder to let go.
;; Validation is lib/_thread.py's; this only refuses to store less than one.
;; ============================================================================
DEF_FUNC tc_set_interval
    xor esi, esi
    call tc_int_arg
    ERR_M1 .fail
    mov ecx, 1
    cmp rax, 1
    cmovl rax, rcx
    mov [rel gil_interval_ns], rax
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
.fail:
    xor eax, eax
    leave
    ret
END_FUNC tc_set_interval

;; ============================================================================
;; thread_module_create() -> rax = the `_threadcore` module
;; ============================================================================
TMC_FRAME equ 16                ; + 2 pushes = 32, 16-aligned
global thread_module_create
DEF_FUNC thread_module_create, TMC_FRAME
    push rbx
    push r12
    call dict_new
    mov r12, rax                ; MODULE_ADD_FUNC reads the dict from r12

    MODULE_ADD_FUNC tc_start,          tc_n_start
    MODULE_ADD_FUNC tc_get_ident,      tc_n_get_ident
    MODULE_ADD_FUNC tc_get_native_id,  tc_n_get_native_id
    MODULE_ADD_FUNC tc_count,          tc_n_count
    MODULE_ADD_FUNC tc_set_stack_size, tc_n_set_stack_size
    MODULE_ADD_FUNC tc_thread_dict,    tc_n_thread_dict
    MODULE_ADD_FUNC tc_interrupt_main, tc_n_interrupt_main
    MODULE_ADD_FUNC tc_lock_new,       tc_n_lock_new
    MODULE_ADD_FUNC tc_lock_free,      tc_n_lock_free
    MODULE_ADD_FUNC tc_lock_reinit,    tc_n_lock_reinit
    MODULE_ADD_FUNC tc_lock_acquire,   tc_n_lock_acquire
    MODULE_ADD_FUNC tc_lock_release,   tc_n_lock_release
    MODULE_ADD_FUNC tc_lock_locked,    tc_n_lock_locked
    MODULE_ADD_FUNC tc_get_interval,   tc_n_get_interval
    MODULE_ADD_FUNC tc_set_interval,   tc_n_set_interval

    lea rdi, [rel tc_name]
    call str_from_cstr_heap
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov rbx, rax
    mov rdi, r12
    call obj_decref
    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret
END_FUNC thread_module_create

section .rodata
tc_name:              db "_threadcore", 0
tc_n_start:           db "start", 0
tc_n_get_ident:       db "get_ident", 0
tc_n_get_native_id:   db "get_native_id", 0
tc_n_count:           db "count", 0
tc_n_set_stack_size:  db "set_stack_size", 0
tc_n_thread_dict:     db "thread_dict", 0
tc_n_interrupt_main:  db "interrupt_main", 0
tc_n_lock_new:        db "lock_new", 0
tc_n_lock_free:       db "lock_free", 0
tc_n_lock_reinit:     db "lock_reinit", 0
tc_n_lock_acquire:    db "lock_acquire", 0
tc_n_lock_release:    db "lock_release", 0
tc_n_lock_locked:     db "lock_locked", 0
tc_n_get_interval:    db "get_interval", 0
tc_n_set_interval:    db "set_interval", 0
