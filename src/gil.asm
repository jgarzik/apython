; gil.asm - the global interpreter lock, and the eval breaker it shares with
; signals.
;
; The design is CPython's Python/ceval_gil.c, on a pthread mutex and two
; condition variables:
;
;   * A thread that wants the GIL waits on gil_cond with a timeout, the
;     switch interval.  If the interval passes and the same thread has held
;     the lock the whole time, the waiter sets EB_GIL_DROP in eval_breaker.
;   * The holder sees that bit at its next checkpoint (CHECK_EVAL_SIGNALS,
;     macros.inc) and calls gil_yield, which releases the lock and then WAITS
;     until another thread has actually taken it.  Without that handshake the
;     thread that just let go is the one most likely to win the mutex back,
;     and a waiter starves.
;   * A blocking call gives the lock up outright (gil_release) and takes it
;     back afterwards (gil_acquire); see src/include/gil.inc for what code
;     between the two may not do.
;
; pthread primitives rather than a raw futex: glibc's malloc, errno, OpenSSL
; and libffi all need a real thread descriptor on fs, so threads are made with
; pthread_create and these come with it; and helgrind understands them.
;
; Until a second thread has been started (gil_threaded), gil_release and
; gil_acquire return at once and nobody waits, so a single-threaded program
; never touches the mutex after startup.
;
; Shutdown: the main thread sets gil_finalizing while holding the lock and
; never gives it up again.  Any other thread that asks for the lock after
; that parks for ever -- it would otherwise run Python against an interpreter
; that is being taken apart -- and exit_group ends it with the process.
; CPython 3.12 does the same with pthread_exit.

%include "macros.inc"
%include "object.inc"
%include "threadstate.inc"
%include "gil.inc"

ASM_INIT

extern pthread_mutex_lock
extern pthread_mutex_unlock
extern pthread_cond_signal
extern pthread_cond_wait
extern pthread_cond_timedwait
extern clock_gettime
extern pause
extern mallopt
extern pthread_self
extern fork
extern __errno_location
extern sigemptyset
extern pthread_sigmask
extern thread_running_reset
extern signal_run_pending

ETIMEDOUT_ERRNO equ 110
NS_PER_SEC      equ 1000000000

section .data
align 8
; The dispatch loop's checkpoints test this one word against zero.  Bits are
; EB_* (gil.inc); they are set and cleared with `lock`, because a signal
; handler and another thread's gil_take both write it.
global eval_breaker
eval_breaker:       dq 0

; The switch interval, in nanoseconds.  sys.setswitchinterval writes it.
global gil_interval_ns
gil_interval_ns:    dq 5000000

global gil_threaded
gil_threaded:       dq 0        ; a second thread has been started, ever
global gil_finalizing
gil_finalizing:     dq 0        ; the main thread is shutting down

; The thread whose tstate handles signals and owns shutdown.  A variable and
; not `main_tstate`, because after a fork from another thread that thread is
; the only one left and becomes it.
global tstate_main_ptr
tstate_main_ptr:    dq 0

; Every live ThreadState, newest first, linked through ts_next / ts_prev.
; Read and written only with the GIL held.
global tstate_list_head
tstate_list_head:   dq 0

section .bss
align 64
gil_mutex:          resb 64     ; pthread_mutex_t (40 bytes), zero = unlocked
gil_cond:           resb 64     ; pthread_cond_t (48 bytes): the GIL is free
gil_switch_cond:    resb 64     ; pthread_cond_t: the GIL has a new holder
gil_locked:         resq 1      ; 1 while some thread holds it
gil_last_holder:    resq 1      ; the ThreadState that took it last
gil_switch_number:  resq 1      ; bumped each time a DIFFERENT thread takes it
gil_waiters:        resq 1      ; threads inside gil_take's wait

section .text

;; ============================================================================
;; gil_init() -> nothing
;;
;; Called once by main, after tstate_install: the calling thread becomes the
;; main thread and holds the GIL.  No locking -- nothing else exists yet, and
;; the mutex and condition variables are valid as zeroes.
;;
;; It also holds glibc's malloc to ONE arena.  Left alone, glibc gives each
;; new thread an arena of its own and reserves 64 MiB of address space for
;; it; sixty threads then need 4 GiB of address space to hold a few kilobytes
;; each, and under a `ulimit -v` the next allocation fails.  Nearly every
;; allocation here is made with the GIL held, so a second arena would buy no
;; concurrency anyway.
;; ============================================================================
M_ARENA_MAX equ -8
DEF_FUNC gil_init
    mov edi, M_ARENA_MAX
    mov esi, 1
    call mallopt
    call pthread_self
    mov [gs:ThreadState.ts_ident], rax
    mov rax, [gs:ThreadState.ts_self]
    mov [rel tstate_main_ptr], rax
    mov [rel gil_last_holder], rax
    mov [rel tstate_list_head], rax
    mov qword [rel gil_locked], 1
    leave
    ret
END_FUNC gil_init

;; ============================================================================
;; tstate_link() -> nothing
;;
;; Put the calling thread's ThreadState at the head of the list.  GIL held.
;; ============================================================================
DEF_FUNC_BARE tstate_link
    mov rax, [gs:ThreadState.ts_self]
    mov rcx, [rel tstate_list_head]
    mov [rax + ThreadState.ts_next], rcx
    mov qword [rax + ThreadState.ts_prev], 0
    test rcx, rcx
    jz .tl_head
    mov [rcx + ThreadState.ts_prev], rax
.tl_head:
    mov [rel tstate_list_head], rax
    ret
END_FUNC tstate_link

;; ============================================================================
;; tstate_unlink() -> nothing
;;
;; Take the calling thread's ThreadState off the list.  GIL held.
;; ============================================================================
DEF_FUNC_BARE tstate_unlink
    mov rax, [gs:ThreadState.ts_self]
    mov rcx, [rax + ThreadState.ts_next]
    mov rdx, [rax + ThreadState.ts_prev]
    test rdx, rdx
    jz .tu_was_head
    mov [rdx + ThreadState.ts_next], rcx
    jmp .tu_next
.tu_was_head:
    mov [rel tstate_list_head], rcx
.tu_next:
    test rcx, rcx
    jz .tu_done
    mov [rcx + ThreadState.ts_prev], rdx
.tu_done:
    ret
END_FUNC tstate_unlink

;; ============================================================================
;; gil_take() -> nothing; returns holding the GIL
;;
;; Wait for the lock, asking the holder to drop it once a switch interval has
;; gone by with no change of hands.  The calling thread's gs must already
;; point at its ThreadState.  Preserves nothing caller-saved.
;; ============================================================================
GT_TS    equ 16                 ; struct timespec: tv_sec, then tv_nsec above it
GT_SAVED equ 24                 ; the switch number when this wait began
GT_FRAME equ 24                 ; + 1 push = 32, 16-aligned
DEF_FUNC gil_take, GT_FRAME
    push rbx
    lea rdi, [rel gil_mutex]
    call pthread_mutex_lock
    inc qword [rel gil_waiters]

.gt_loop:
    ; Shutting down, and this is not the thread doing it: never run again.
    cmp qword [rel gil_finalizing], 0
    je .gt_live
    mov rax, [gs:ThreadState.ts_self]
    cmp rax, [rel tstate_main_ptr]
    jne .gt_park
.gt_live:
    cmp qword [rel gil_locked], 0
    je .gt_free

    mov rax, [rel gil_switch_number]
    mov [rbp - GT_SAVED], rax
    xor edi, edi                ; CLOCK_REALTIME, which the timed wait measures
    lea rsi, [rbp - GT_TS]
    call clock_gettime
    mov rax, [rbp - GT_TS + 8]
    add rax, [rel gil_interval_ns]
.gt_carry:
    cmp rax, NS_PER_SEC
    jb .gt_deadline
    sub rax, NS_PER_SEC
    inc qword [rbp - GT_TS]
    jmp .gt_carry
.gt_deadline:
    mov [rbp - GT_TS + 8], rax
    lea rdi, [rel gil_cond]
    lea rsi, [rel gil_mutex]
    lea rdx, [rbp - GT_TS]
    call pthread_cond_timedwait
    cmp eax, ETIMEDOUT_ERRNO
    jne .gt_loop
    ; A whole interval, the lock still held, and by the same thread as when
    ; the wait began: ask it to let go.
    cmp qword [rel gil_locked], 0
    je .gt_loop
    mov rax, [rel gil_switch_number]
    cmp rax, [rbp - GT_SAVED]
    jne .gt_loop
    lock or qword [rel eval_breaker], EB_GIL_DROP
    jmp .gt_loop

.gt_free:
    dec qword [rel gil_waiters]
    mov qword [rel gil_locked], 1
    lock and qword [rel eval_breaker], ~EB_GIL_DROP
    mov rax, [gs:ThreadState.ts_self]
    cmp rax, [rel gil_last_holder]
    je .gt_same
    mov [rel gil_last_holder], rax
    inc qword [rel gil_switch_number]
.gt_same:
    lea rdi, [rel gil_switch_cond]
    call pthread_cond_signal
    lea rdi, [rel gil_mutex]
    call pthread_mutex_unlock
    pop rbx
    leave
    ret

.gt_park:
    dec qword [rel gil_waiters]
    lea rdi, [rel gil_mutex]
    call pthread_mutex_unlock
.gt_park_loop:
    call pause
    jmp .gt_park_loop
END_FUNC gil_take

;; ============================================================================
;; gil_drop() -> nothing; returns NOT holding the GIL
;;
;; Let go and wake one waiter.  The caller must not touch interpreter state
;; until it has called gil_take again.
;; ============================================================================
DEF_FUNC gil_drop
    lea rdi, [rel gil_mutex]
    call pthread_mutex_lock
    mov qword [rel gil_locked], 0
    lea rdi, [rel gil_cond]
    call pthread_cond_signal
    lea rdi, [rel gil_mutex]
    call pthread_mutex_unlock
    leave
    ret
END_FUNC gil_drop

;; ============================================================================
;; gil_yield() -> nothing; returns holding the GIL
;;
;; Hand the lock to a waiting thread and take it back afterwards.  The wait on
;; gil_switch_cond is the forced switch: this thread does not ask for the
;; lock again until some other thread has had it.  With nobody waiting it
;; returns at once.
;; ============================================================================
GY_FRAME equ 8                  ; + 1 push = 16, 16-aligned
DEF_FUNC gil_yield, GY_FRAME
    push rbx
    lock and qword [rel eval_breaker], ~EB_GIL_DROP
    cmp qword [rel gil_finalizing], 0
    jne .gy_out                 ; shutting down: the main thread keeps it
    cmp qword [rel gil_waiters], 0
    je .gy_out
    lea rdi, [rel gil_mutex]
    call pthread_mutex_lock
    mov qword [rel gil_locked], 0
    mov rbx, [rel gil_switch_number]
    lea rdi, [rel gil_cond]
    call pthread_cond_signal
.gy_wait:
    cmp qword [rel gil_waiters], 0
    je .gy_retake               ; the waiter left without taking it
    cmp rbx, [rel gil_switch_number]
    jne .gy_retake              ; another thread has it now, or has had it
    lea rdi, [rel gil_switch_cond]
    lea rsi, [rel gil_mutex]
    call pthread_cond_wait
    jmp .gy_wait
.gy_retake:
    lea rdi, [rel gil_mutex]
    call pthread_mutex_unlock
    call gil_take
.gy_out:
    pop rbx
    leave
    ret
END_FUNC gil_yield

;; ============================================================================
;; gil_release() -> nothing
;;
;; ALLOW_THREADS_BEGIN: give the GIL up before a call that may block.  A
;; no-op until a second thread exists, and during shutdown.
;; ============================================================================
DEF_FUNC_BARE gil_release
    cmp qword [rel gil_threaded], 0
    je .gr_out
    cmp qword [rel gil_finalizing], 0
    jne .gr_out
    jmp gil_drop
.gr_out:
    ret
END_FUNC gil_release

;; ============================================================================
;; gil_acquire() -> nothing; rax and rdx are preserved
;;
;; ALLOW_THREADS_END: take the GIL back after the blocking call, whose result
;; is usually still in rax.  A no-op exactly when gil_release was one for
;; this thread, so the two agree about whether the lock changed hands.
;; ============================================================================
GA_RAX   equ 8
GA_RDX   equ 16
GA_FRAME equ 16                 ; + 0 pushes = 16, 16-aligned
DEF_FUNC gil_acquire, GA_FRAME
    cmp qword [rel gil_threaded], 0
    je .ga_out
    cmp qword [rel gil_finalizing], 0
    je .ga_take
    ; Shutting down.  The main thread never let go (gil_release was a no-op
    ; for it), so it has nothing to take back.  Any OTHER thread gave the
    ; lock up before shutdown began and is now coming back from its blocking
    ; call: it must not simply carry on -- that would be Python running with
    ; no lock at all, beside the main thread -- so it goes to gil_take, which
    ; parks it.
    mov rcx, [gs:ThreadState.ts_self]
    cmp rcx, [rel tstate_main_ptr]
    je .ga_out
.ga_take:
    mov [rbp - GA_RAX], rax
    mov [rbp - GA_RDX], rdx
    call gil_take
    mov rax, [rbp - GA_RAX]
    mov rdx, [rbp - GA_RDX]
.ga_out:
    leave
    ret
END_FUNC gil_acquire

;; ============================================================================
;; eval_breaker_slow() -> eax = 1 when a signal handler raised, else 0
;;
;; Where CHECK_EVAL_SIGNALS lands when eval_breaker is non-zero.  Hands the
;; GIL over if a thread asked for it, then runs pending signal handlers --
;; on the main thread only, which is where Python promises they run.  Another
;; thread that sees a signal pending yields, so the main thread gets to it.
;; ============================================================================
DEF_FUNC eval_breaker_slow
    test qword [rel eval_breaker], EB_GIL_DROP
    jz .ebs_signals
    call gil_yield
.ebs_signals:
    test qword [rel eval_breaker], EB_SIGNAL
    jz .ebs_none
    mov rax, [gs:ThreadState.ts_self]
    cmp rax, [rel tstate_main_ptr]
    jne .ebs_not_main
    leave
    jmp signal_run_pending
.ebs_not_main:
    call gil_yield
.ebs_none:
    xor eax, eax
    leave
    ret
END_FUNC eval_breaker_slow

;; ============================================================================
;; gil_fork() -> rax = the child's pid, 0 in the child, or -errno
;;
;; fork(2) through glibc, not the raw syscall: with threads, some OTHER
;; thread may hold one of glibc's own locks -- malloc's, stdio's -- at the
;; instant of the fork, and the child would inherit it locked with nobody
;; left to release it.  glibc's fork takes and resets those.
;;
;; The child has exactly one thread, the one that forked, whatever it was in
;; the parent.  It becomes the main thread there, and everything about the
;; GIL is put back to "one thread, holding it": the mutex and the condition
;; variables may have been caught mid-operation by a thread that no longer
;; exists.
;; ============================================================================
GF_SET   equ 128                ; a sigset_t
GF_PID   equ 136
GF_FRAME equ 144                ; + 0 pushes = 144, 16-aligned
SYS_gettid_nr equ 186
SIG_SETMASK_HOW equ 2
DEF_FUNC gil_fork, GF_FRAME
    call fork
    mov [rbp - GF_PID], rax
    test eax, eax
    jz .gf_child
    jns .gf_out
    call __errno_location
    mov eax, [rax]
    neg rax
    leave
    ret

.gf_child:
    lea rdi, [rel gil_mutex]
    mov ecx, (64 * 3) / 8       ; the mutex and both condition variables
    xor eax, eax
    rep stosq
    mov qword [rel gil_waiters], 0
    mov qword [rel gil_locked], 1
    mov qword [rel gil_threaded], 0
    lock and qword [rel eval_breaker], ~EB_GIL_DROP
    mov rax, [gs:ThreadState.ts_self]
    mov [rel gil_last_holder], rax
    mov [rel tstate_list_head], rax
    mov qword [rax + ThreadState.ts_next], 0
    mov qword [rax + ThreadState.ts_prev], 0
    call thread_running_reset
    mov eax, SYS_gettid_nr
    syscall
    mov [gs:ThreadState.ts_native_id], rax

    ; A thread other than the main one was created with every signal
    ; blocked.  As the child's only thread it has to take them.
    mov rax, [gs:ThreadState.ts_self]
    cmp rax, [rel tstate_main_ptr]
    je .gf_child_done
    mov [rel tstate_main_ptr], rax
    lea rdi, [rbp - GF_SET]
    call sigemptyset
    mov edi, SIG_SETMASK_HOW
    lea rsi, [rbp - GF_SET]
    xor edx, edx
    call pthread_sigmask
.gf_child_done:
    xor eax, eax
    leave
    ret
.gf_out:
    mov rax, [rbp - GF_PID]
    leave
    ret
END_FUNC gil_fork

;; ============================================================================
;; gil_blocking_call(rax = function, rdi, rsi, rdx, rcx, r8, r9 = its
;;   arguments) -> rax, rdx = whatever the function returned
;;
;; BLOCKING_CALL (gil.inc): call a function that may block, with the GIL
;; given up for the duration.  The six argument registers reach the function
;; as they were.  Meant for the raw syscall wrappers in runtime.asm, which
;; touch no interpreter state and report failure as -errno in rax -- so there
;; is no errno to lose while the GIL is being taken back.
;;
;; Until a second thread exists this is a tail jump to the function.
;; ============================================================================
GBC_FN    equ 8
GBC_ARGS  equ 56                ; six words, rdi lowest
GBC_FRAME equ 64                ; + 0 pushes = 64, 16-aligned
global gil_blocking_call
gil_blocking_call:
    cmp qword [rel gil_threaded], 0
    je .gbc_direct
    cmp qword [rel gil_finalizing], 0
    jne .gbc_direct
    push rbp
    mov rbp, rsp
    sub rsp, GBC_FRAME
    mov [rbp - GBC_FN], rax
    mov [rbp - GBC_ARGS], rdi
    mov [rbp - GBC_ARGS + 8], rsi
    mov [rbp - GBC_ARGS + 16], rdx
    mov [rbp - GBC_ARGS + 24], rcx
    mov [rbp - GBC_ARGS + 32], r8
    mov [rbp - GBC_ARGS + 40], r9
    call gil_drop
    mov rdi, [rbp - GBC_ARGS]
    mov rsi, [rbp - GBC_ARGS + 8]
    mov rdx, [rbp - GBC_ARGS + 16]
    mov rcx, [rbp - GBC_ARGS + 24]
    mov r8, [rbp - GBC_ARGS + 32]
    mov r9, [rbp - GBC_ARGS + 40]
    call [rbp - GBC_FN]
    mov [rbp - GBC_ARGS], rax
    mov [rbp - GBC_ARGS + 8], rdx
    call gil_take
    mov rax, [rbp - GBC_ARGS]
    mov rdx, [rbp - GBC_ARGS + 8]
    leave
    ret
.gbc_direct:
    jmp rax
.end:
