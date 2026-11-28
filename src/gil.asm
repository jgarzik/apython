; gil.asm - Free-threaded thread-state lifecycle, eval_breaker dispatch,
; STW-coordinated blocking-call detach/reattach, and fork safety.
;
; There is NO global interpreter lock (sys._is_gil_enabled() == False):
; multiple threads execute Python bytecode in parallel on separate CPU cores.
; All shared runtime state is protected by per-object/subsystem leaf futex
; locks (src/sync.asm) and biased reference counting (BRC).
;
; ALLOW_THREADS_BEGIN/END (gil_release/gil_acquire) and BLOCKING_CALL
; (gil_blocking_call) mark threads as TS_STATE_DETACHED around blocking
; syscalls and long native C calls so Stop-The-World (STW) GC, fork(), and
; interpreter shutdown never wait on a blocked thread.
;
; Until a second thread or foreign callback closure is admitted (rt_threaded ==
; 0), detach/reattach are immediate single-branch no-ops.

%include "macros.inc"
%include "object.inc"
%include "threadstate.inc"
%include "gil.inc"
%include "sync.inc"

ASM_INIT

extern pause
extern mallopt
extern pthread_self
extern pthread_key_create
extern pthread_setspecific
extern rt_tstate_key
extern fork
extern __errno_location
extern sigemptyset
extern pthread_sigmask
extern thread_running_reset
extern signal_run_pending
extern fatal_error
extern rt_threaded
extern rt_mutex_lock
extern rt_mutex_unlock
extern rt_detach
extern rt_reattach
extern stw_safepoint
extern stw_stop_world
extern stw_start_world
extern stw_notify_unlink
extern stw_reset_after_fork
extern brc_register_thread
extern brc_drain_thread
extern brc_reset_after_fork
extern alloc_reset_after_fork
extern systrace_after_fork_child
extern weakref_reset_after_fork
extern gc_reset_after_fork
extern subclass_reset_after_fork
extern type_lock
extern ap_exited_live

section .data
align 8
; The dispatch loop's checkpoints test this one word against zero.  Bits are
; EB_* (gil.inc): EB_SIGNAL, EB_STOP_WORLD, EB_BRC_MERGE.
global eval_breaker
eval_breaker:       dq 0

; Kept for sys.getswitchinterval / sys.setswitchinterval API compatibility.
global gil_interval_ns
gil_interval_ns:    dq 5000000

global gil_threaded
gil_threaded:       dq 0        ; set alongside rt_threaded when threading starts
global gil_finalizing
gil_finalizing:     dq 0        ; the main thread is shutting down

; The thread whose tstate handles signals and owns shutdown.  Updated on fork.
global tstate_main_ptr
tstate_main_ptr:    dq 0

; Every live ThreadState, newest first, linked through ts_next / ts_prev.
; Protected by tstate_list_lock (32-bit futex).
global tstate_list_head
tstate_list_head:   dq 0
global tstate_list_lock
tstate_list_lock:   dd 0
                    dd 0

section .text

;; ============================================================================
;; gil_init() -> nothing
;;
;; Called once by main after tstate_install: registers the main thread with
;; ts_tid = 1, ts_state = TS_STATE_ATTACHED, and bounds glibc malloc arenas
;; to 8 so high thread counts stay within virtual-memory limits while still
;; allowing parallel libc allocations.
;; ============================================================================
M_ARENA_MAX equ -8
DEF_FUNC gil_init
    mov edi, M_ARENA_MAX
    mov esi, 8
    call mallopt
    call pthread_self
    mov [gs:ThreadState.ts_ident], rax
    mov rax, [gs:ThreadState.ts_self]
    mov dword [rax + ThreadState.ts_tid], 1
    mov dword [rax + ThreadState.ts_state], TS_STATE_ATTACHED
    mov ecx, 1
    shl rcx, 40
    mov [rax + ThreadState.ts_dict_ver], rcx
    mov [rel tstate_main_ptr], rax
    mov [rel tstate_list_head], rax
    mov rdi, rax
    call brc_register_thread
    lea rdi, [rel rt_tstate_key]
    xor esi, esi
    call pthread_key_create
    mov edi, [rel rt_tstate_key]
    mov rsi, [gs:ThreadState.ts_self]
    call pthread_setspecific
    leave
    ret
END_FUNC gil_init

;; ============================================================================
;; tstate_link() -> nothing
;;
;; Put the calling thread's ThreadState at the head of tstate_list_head.
;; ============================================================================
DEF_FUNC tstate_link
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_lock
    mov rax, [gs:ThreadState.ts_self]
    mov rcx, [rel tstate_list_head]
    mov [rax + ThreadState.ts_next], rcx
    mov qword [rax + ThreadState.ts_prev], 0
    test rcx, rcx
    jz .tl_head
    mov [rcx + ThreadState.ts_prev], rax
.tl_head:
    mov [rel tstate_list_head], rax
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_unlock
    leave
    ret
END_FUNC tstate_link

;; ============================================================================
;; tstate_unlink() -> nothing
;;
;; Remove calling thread's ThreadState, fold residual ts_alloc_live delta into
;; ap_exited_live, and notify any waiting STW coordinator under tstate_list_lock.
;; ============================================================================
DEF_FUNC tstate_unlink
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_lock
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
    mov qword [rax + ThreadState.ts_next], 0
    mov qword [rax + ThreadState.ts_prev], 0
    mov rdx, [rax + ThreadState.ts_alloc_live]
    mov qword [rax + ThreadState.ts_alloc_live], 0
    add [rel ap_exited_live], rdx
    cmp byte [rax + ThreadState.ts_gc_pending], 0
    je .tu_no_gc_pend
    mov byte [rax + ThreadState.ts_gc_pending], 0
    extern gc_pending_threads
    lock dec dword [rel gc_pending_threads]
    jnz .tu_no_gc_pend
    lock and qword [rel eval_breaker], ~EB_GC_COLLECT
    cmp dword [rel gc_pending_threads], 0
    je .tu_no_gc_pend
    lock or qword [rel eval_breaker], EB_GC_COLLECT
.tu_no_gc_pend:
    mov rdi, rax
    call stw_notify_unlink
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_unlock
    leave
    ret
END_FUNC tstate_unlink

;; ============================================================================
;; gil_take() -> nothing
;;
;; Attach the calling thread to the free-threaded runtime (blocking if a STW
;; pause is active, or parking permanently if shutdown is in progress).
;; ============================================================================
DEF_FUNC_BARE gil_take
    cmp qword [rel gil_finalizing], 0
    je rt_reattach
    mov rax, [gs:ThreadState.ts_self]
    cmp rax, [rel tstate_main_ptr]
    je rt_reattach
.gt_park:
    call pause
    jmp .gt_park
END_FUNC gil_take

;; ============================================================================
;; gil_drop() -> nothing
;;
;; Detach the calling thread from the free-threaded runtime.
;; ============================================================================
DEF_FUNC_BARE gil_drop
    jmp rt_detach
END_FUNC gil_drop

;; ============================================================================
;; gil_release() -> nothing
;;
;; ALLOW_THREADS_BEGIN: detach before a blocking call so STW pauses do not
;; wait for this thread.  No-op while rt_threaded == 0 or main is shutting down.
;; ============================================================================
DEF_FUNC_BARE gil_release
    cmp byte [rel rt_threaded], 0
    je .gr_out
    cmp qword [rel gil_finalizing], 0
    je rt_detach
    mov rax, [gs:ThreadState.ts_self]
    cmp rax, [rel tstate_main_ptr]
    jne rt_detach
.gr_out:
    ret
END_FUNC gil_release

;; ============================================================================
;; gil_acquire() -> nothing; rax and rdx are preserved
;;
;; ALLOW_THREADS_END: reattach after a blocking call (waiting out any active
;; STW pause, or parking permanently if shutdown began while detached).
;; ============================================================================
GA_RAX   equ 8
GA_RDX   equ 16
GA_FRAME equ 16                 ; + 0 pushes = 16, 16-aligned
DEF_FUNC gil_acquire, GA_FRAME
    cmp qword [rel gil_finalizing], 0
    je .ga_not_fin
    mov rcx, [gs:ThreadState.ts_self]
    cmp rcx, [rel tstate_main_ptr]
    je .ga_out
.ga_park:
    call pause
    jmp .ga_park
.ga_not_fin:
    cmp byte [rel rt_threaded], 0
    je .ga_out
.ga_attach:
    mov [rbp - GA_RAX], rax
    mov [rbp - GA_RDX], rdx
    call rt_reattach
    mov rax, [rbp - GA_RAX]
    mov rdx, [rbp - GA_RDX]
.ga_out:
    leave
    ret
END_FUNC gil_acquire

;; ============================================================================
;; eval_breaker_slow() -> eax = 1 when a signal handler raised, else 0
;;
;; Where CHECK_EVAL_SIGNALS lands when eval_breaker is non-zero:
;;   1. EB_STOP_WORLD: park at STW safepoint (GC / fork / shutdown).
;;   2. EB_SIGNAL: run pending signal handlers on the main thread only
;;      (worker threads never yield or block for signals).
;;   3. EB_BRC_MERGE: drain this thread's remote BRC merge queue.
;;   4. EB_GC_COLLECT: run deferred gen0 auto-GC with zero leaf locks held.
;; ============================================================================
DEF_FUNC eval_breaker_slow
    test qword [rel eval_breaker], EB_STOP_WORLD
    jz .ebs_signals
    call stw_safepoint
.ebs_signals:
    test qword [rel eval_breaker], EB_SIGNAL
    jz .ebs_brc
    mov rax, [gs:ThreadState.ts_self]
    cmp rax, [rel tstate_main_ptr]
    jne .ebs_brc
    leave
    jmp signal_run_pending
.ebs_brc:
    test qword [rel eval_breaker], EB_BRC_MERGE
    jz .ebs_gc
    mov rdi, [gs:ThreadState.ts_self]
    cmp qword [rdi + ThreadState.ts_brc_len], 0
    je .ebs_gc
    call brc_drain_thread
.ebs_gc:
    test qword [rel eval_breaker], EB_GC_COLLECT
    jz .ebs_none
    cmp byte [gs:ThreadState.ts_gc_pending], 0
    je .ebs_none
    mov byte [gs:ThreadState.ts_gc_pending], 0
    lock dec dword [rel gc_pending_threads]
    jnz .ebs_gc_run
    lock and qword [rel eval_breaker], ~EB_GC_COLLECT
    cmp dword [rel gc_pending_threads], 0
    je .ebs_gc_run
    lock or qword [rel eval_breaker], EB_GC_COLLECT
.ebs_gc_run:
    extern gc_enabled
    extern gc_collecting
    extern gc_collect_gen
    cmp qword [rel gc_enabled], 0
    je .ebs_none
    cmp qword [rel gc_collecting], 0
    jne .ebs_none
    xor edi, edi
    call gc_collect_gen
.ebs_none:
    xor eax, eax
    leave
    ret
END_FUNC eval_breaker_slow

;; ============================================================================
;; gil_fork() -> rax = the child's pid, 0 in the child, or -errno
;;
;; When threaded, pauses all other Python threads via stw_stop_world() before
;; calling glibc fork() so no runtime leaf futex is held across fork().
;; Resumes the world in the parent; resets single-threaded runtime state in
;; the child.
;; ============================================================================
GF_SET   equ 128                ; a sigset_t
GF_PID   equ 136
GF_STW   equ 144                ; 1 if we called stw_stop_world before fork
GF_ERR   equ 152                ; saved -errno on fork failure
GF_FRAME equ 160                ; + 0 pushes = 160, 16-aligned
SYS_gettid_nr   equ 186
SIG_SETMASK_HOW equ 2
DEF_FUNC gil_fork, GF_FRAME
    mov qword [rbp - GF_STW], 0
    cmp byte [rel rt_threaded], 0
    je .gf_do_fork
    call stw_stop_world
    mov qword [rbp - GF_STW], 1
.gf_do_fork:
    call fork
    mov [rbp - GF_PID], rax
    test eax, eax
    jz .gf_child
    jns .gf_parent_ok
    call __errno_location
    mov eax, [rax]
    neg rax
    mov [rbp - GF_ERR], rax
    cmp qword [rbp - GF_STW], 0
    je .gf_err_ret
    call stw_start_world
.gf_err_ret:
    mov rax, [rbp - GF_ERR]
    leave
    ret

.gf_parent_ok:
    cmp qword [rbp - GF_STW], 0
    je .gf_out
    call stw_start_world
.gf_out:
    mov rax, [rbp - GF_PID]
    leave
    ret

.gf_child:
    mov qword [rel gil_threaded], 0
    mov rax, [gs:ThreadState.ts_self]
    mov dword [rax + ThreadState.ts_state], TS_STATE_ATTACHED
    mov [rel tstate_list_head], rax
    mov dword [rel tstate_list_lock], 0
    mov qword [rax + ThreadState.ts_next], 0
    mov qword [rax + ThreadState.ts_prev], 0
    call alloc_reset_after_fork
    call thread_running_reset
    call systrace_after_fork_child
    mov rdi, [gs:ThreadState.ts_self]
    call brc_reset_after_fork
    call weakref_reset_after_fork
    call stw_reset_after_fork
    call gc_reset_after_fork
    call subclass_reset_after_fork
    mov dword [rel type_lock], 0
    mov eax, SYS_gettid_nr
    syscall
    mov [gs:ThreadState.ts_native_id], rax

    ; A non-main thread was created with all signals blocked; as the child's
    ; sole thread it becomes the main thread and unblocks signals.
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
END_FUNC gil_fork

;; ============================================================================
;; gil_blocking_call(rax = function, rdi..r9 = args) -> rax, rdx
;;
;; BLOCKING_CALL (gil.inc): detach around a blocking native syscall wrapper
;; when rt_threaded != 0.  Single-threaded: one branch + tail jump.
;; ============================================================================
GBC_FN    equ 8
GBC_ARGS  equ 56                ; six words, rdi lowest
GBC_FRAME equ 64                ; + 0 pushes = 64, 16-aligned
global gil_blocking_call
gil_blocking_call:
    cmp byte [rel rt_threaded], 0
    je .gbc_direct
    cmp qword [rel gil_finalizing], 0
    je .gbc_detach
    mov r10, [gs:ThreadState.ts_self]
    cmp r10, [rel tstate_main_ptr]
    je .gbc_direct
.gbc_detach:
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
    call rt_detach
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
