; gil.inc - the global interpreter lock's interface (src/gil.asm)
;
; One thread runs the interpreter at a time.  Everything shared -- the
; allocator, freelists, the collector, caches, interned strings, refcounts --
; is an ordinary global with no lock of its own, and is safe for exactly that
; reason: whoever touches it holds the GIL.
;
; The lock changes hands in two places and nowhere else:
;
;   * at an eval-breaker checkpoint (CHECK_EVAL_SIGNALS, macros.inc), when a
;     waiting thread has asked for it.  Those are the points that already ran
;     signal handlers -- arbitrary Python -- so everything around them is
;     already written to survive anything happening there;
;
;   * around a call that blocks, bracketed by ALLOW_THREADS_BEGIN and
;     ALLOW_THREADS_END below.
;
; Between the two macros the thread does not hold the GIL, and so MUST NOT
; touch an object, allocate, free, read or write a refcount, or raise.  Copy
; what the call needs into registers or frame slots first; capture errno into
; a frame slot before ALLOW_THREADS_END, not after.  The call's result is safe
; in rax and rdx: ALLOW_THREADS_END preserves both.
;
; Until a second thread has ever been started both macros cost one load and
; one branch, so a single-threaded program pays nothing for them.

%ifndef GIL_INC
%define GIL_INC

; Bits of eval_breaker, the one word the dispatch loop's checkpoints test.
EB_SIGNAL   equ 1               ; a signal arrived; the main thread runs handlers
EB_GIL_DROP equ 2               ; a waiting thread wants the GIL

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
