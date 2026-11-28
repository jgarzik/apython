; sync.inc - Free-threaded synchronization primitives, biased RC constants,
; and leaf per-object locking macros (src/sync.asm).
;
; Every lock here is a 32-bit direct Linux futex word:
;   0 = unlocked
;   1 = locked (uncontended)
;   2 = locked (waiters parked in kernel)
;
; Empirical hardware probe on Intel Core Ultra 9 285K (24 cores) showed:
;   - spin=0 32-bit futex beats pthread_mutex_t by 21-40% at 2/4/8 threads
;     and beats spin=40 PAUSE by 1.9x at 8 threads.
;   - rt_threaded-gated OBJ_LOCK costs 0.19 ns/pair when single-threaded.
;
; CRITICAL INVARIANT for OBJ_LOCK / OBJ_UNLOCK:
;   Object locks are STRICTLY LEAF critical sections.  Never hold an object
;   lock across Python callbacks (__eq__, __hash__, __repr__, __del__, weakref
;   callbacks), blocking syscalls, or a DECREF that may reach zero.  Because
;   leaf sections never invoke Python or spawn threads, rt_threaded cannot
;   transition 0 -> 1 between OBJ_LOCK and OBJ_UNLOCK.

%ifndef SYNC_INC
%define SYNC_INC

; Linux futex ABI
SYS_futex          equ 202
FUTEX_WAIT_PRIVATE equ 128
FUTEX_WAKE_PRIVATE equ 129

; ThreadState.ts_state values
TS_STATE_ATTACHED  equ 0
TS_STATE_DETACHED  equ 1
TS_STATE_PARKED    equ 2

; Biased Reference Counting (BRC) constants
REF_IMMORTAL_LOCAL equ 0xFFFFFFFF
REF_TID_IMMORTAL   equ 0
REF_TID_MERGED     equ 0xFFFFFFFF
REF_SHARED_SHIFT   equ 2
REF_SHARED_ONE     equ 4        ; 1 << REF_SHARED_SHIFT
REF_MERGED_BIT     equ 1        ; ob_ref_local has been folded into ob_ref_shared
REF_QUEUED_BIT     equ 2        ; object is queued on owner's BRC merge queue
REF_FLAGS_MASK     equ 3

; BRC thread-registry hash table size (power of 2)
BRC_NBUCKETS       equ 64
BRC_BUCKET_MASK    equ (BRC_NBUCKETS - 1)
BRC_BUCKET_STRIDE  equ 64       ; cache-line padded per bucket

; ---------------------------------------------------------------------------
; Leaf per-object locking macros.  Preserve ALL registers (only flags change).
; ---------------------------------------------------------------------------
%macro OBJ_LOCK 1               ; %1 = register holding PyObject*
    extern rt_threaded
    cmp byte [rel rt_threaded], 0
    je %%skip
    push rdi
    lea rdi, [%1 + PyObject.ob_mutex]
    extern rt_mutex_lock_p
    call rt_mutex_lock_p
    pop rdi
%%skip:
%endmacro

%macro OBJ_UNLOCK 1             ; %1 = register holding PyObject*
    extern rt_threaded
    cmp byte [rel rt_threaded], 0
    je %%skip
    push rdi
    lea rdi, [%1 + PyObject.ob_mutex]
    extern rt_mutex_unlock_p
    call rt_mutex_unlock_p
    pop rdi
%%skip:
%endmacro

; Ordered two-object leaf lock (ascending address order, handles %1 == %2).
%macro OBJ_LOCK2 2              ; %1, %2 = distinct registers holding PyObject*
    extern rt_threaded
    cmp byte [rel rt_threaded], 0
    je %%skip
    push rdi
    push rsi
    lea rdi, [%1 + PyObject.ob_mutex]
    lea rsi, [%2 + PyObject.ob_mutex]
    extern rt_mutex_lock2_p
    call rt_mutex_lock2_p
    pop rsi
    pop rdi
%%skip:
%endmacro

%macro OBJ_UNLOCK2 2            ; %1, %2 = distinct registers holding PyObject*
    extern rt_threaded
    cmp byte [rel rt_threaded], 0
    je %%skip
    push rdi
    push rsi
    lea rdi, [%1 + PyObject.ob_mutex]
    lea rsi, [%2 + PyObject.ob_mutex]
    extern rt_mutex_unlock2_p
    call rt_mutex_unlock2_p
    pop rsi
    pop rdi
%%skip:
%endmacro

; Global futex lock gated by rt_threaded (preserves ALL registers).
%macro RT_LOCK_GATED 1          ; %1 = symbol of aligned dword futex
    extern rt_threaded
    cmp byte [rel rt_threaded], 0
    je %%skip
    push rdi
    lea rdi, [rel %1]
    extern rt_mutex_lock_p
    call rt_mutex_lock_p
    pop rdi
%%skip:
%endmacro

%macro RT_UNLOCK_GATED 1        ; %1 = symbol of aligned dword futex
    extern rt_threaded
    cmp byte [rel rt_threaded], 0
    je %%skip
    push rdi
    lea rdi, [rel %1]
    extern rt_mutex_unlock_p
    call rt_mutex_unlock_p
    pop rdi
%%skip:
%endmacro

; Always-active global futex lock (preserves ALL registers).
%macro RT_LOCK 1                ; %1 = symbol of aligned dword futex
    push rdi
    lea rdi, [rel %1]
    extern rt_mutex_lock_p
    call rt_mutex_lock_p
    pop rdi
%endmacro

%macro RT_UNLOCK 1              ; %1 = symbol of aligned dword futex
    push rdi
    lea rdi, [rel %1]
    extern rt_mutex_unlock_p
    call rt_mutex_unlock_p
    pop rdi
%endmacro

%endif ; SYNC_INC
