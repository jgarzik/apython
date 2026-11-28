; gil.inc - Free-threaded attachment & eval-breaker interface (src/gil.asm)
;
; Multiple threads execute Python bytecode concurrently (no GIL).  All shared
; runtime state is protected by per-object/subsystem leaf futex locks and
; biased reference counting (src/sync.asm).
;
; ALLOW_THREADS_BEGIN / ALLOW_THREADS_END and BLOCKING_CALL mark the calling
; thread as TS_STATE_DETACHED around blocking syscalls and long native C calls
; so Stop-The-World (STW) GC, fork(), and shutdown pauses never wait on a
; blocked thread.  Between BEGIN and END the thread MUST NOT touch Python
; objects, allocate, free, read or write refcounts, or raise.
;
; Until a second thread or foreign callback closure is admitted (rt_threaded ==
; 0), both macros cost one load and one branch.

%ifndef GIL_INC
%define GIL_INC

; Bits of eval_breaker, the one word the dispatch loop's checkpoints test.
EB_SIGNAL     equ 1             ; a signal arrived; the main thread runs handlers
EB_GIL_DROP   equ 2             ; a waiting thread wants the GIL (retired in FT)
EB_STOP_WORLD equ 4             ; STW safepoint requested (GC / fork / shutdown)
EB_BRC_MERGE  equ 8             ; at least one thread has queued BRC merges

; ALLOW_THREADS_BEGIN -- give the GIL up before a call that may block.
; Clobbers every caller-saved register.
%macro ALLOW_THREADS_BEGIN 0
    extern gil_release
    call gil_release
%endmacro

; ALLOW_THREADS_END -- take the GIL back.  Preserves rax and rdx (the blocked
; call's result); clobbers the other caller-saved registers.
%macro ALLOW_THREADS_END 0
    extern gil_acquire
    call gil_acquire
%endmacro

; BLOCKING_CALL fn -- `call fn` with the GIL given up while it runs.  For a
; function that may block and touches no interpreter state: the syscall
; wrappers in runtime.asm.  rdi, rsi, rdx, rcx, r8 and r9 arrive as set; rax
; and rdx come back as the function left them.  Anything the call reads or
; writes through a pointer must be memory no other thread can move or free
; meanwhile -- a frame slot, a buffer this call owns.
%macro BLOCKING_CALL 1
    extern gil_blocking_call
    lea rax, [rel %1]
    call gil_blocking_call
%endmacro

%endif ; GIL_INC
