; sync.asm - 32-bit direct futex locks, monotonic thread IDs, and the 64-bucket
; Biased Reference Counting (BRC) thread registry and merge queue.

%include "macros.inc"
%include "threadstate.inc"
%include "gil.inc"
%include "sync.inc"

ASM_INIT

extern eval_breaker
extern malloc
extern realloc
extern free
extern fatal_error

section .data
align 64
; 0 while only the main thread has ever touched Python; flipped to 1 once
; (irreversibly for the process, reset in a forked child) before the first
; worker thread or foreign callback closure is admitted.
global rt_threaded
rt_threaded:    db 0
                times 63 db 0

; Monotonic compact owner thread ID allocator.  Main thread starts at 1;
; 0 is reserved for immortal objects and 0xFFFFFFFF for merged objects.
global rt_next_tid
rt_next_tid:    dd 2
                times 60 db 0

section .bss
align 64
; 64 cache-line-padded BRC hash buckets.
; Each 64-byte entry:
;   +0  dword lock  (32-bit futex)
;   +4  dword pad
;   +8  qword head  (ThreadState* linked via ts_brc_hash_next)
;   +16..63 padding
global brc_buckets
brc_buckets:    resb (BRC_NBUCKETS * BRC_BUCKET_STRIDE)

section .text

;; ============================================================================
;; rt_enable_threading() -> nothing
;;
;; Publish rt_threaded = 1 with full memory ordering so every subsequently
;; started thread and leaf lock observes concurrent mode.
;; ============================================================================
global rt_enable_threading
DEF_FUNC_BARE rt_enable_threading
    mov al, 1
    xchg [rel rt_threaded], al
    ret
END_FUNC rt_enable_threading

;; ============================================================================
;; rt_tid_alloc() -> eax = unique non-zero compact tid (1..0xFFFFFFFE)
;; ============================================================================
global rt_tid_alloc
DEF_FUNC_BARE rt_tid_alloc
.retry:
    mov eax, 1
    lock xadd [rel rt_next_tid], eax
    test eax, eax
    jz .retry
    cmp eax, REF_TID_MERGED
    je .retry
    ret
END_FUNC rt_tid_alloc

;; ============================================================================
;; rt_mutex_lock(rdi = uint32_t *mutex) -> nothing
;;
;; Direct 32-bit futex mutex (0=free, 1=locked, 2=contended), spin=0.
;; Clobbers rax, rcx, rdx, rsi, r8, r9, r10, r11 (SysV caller-saved).
;; ============================================================================
global rt_mutex_lock
DEF_FUNC_BARE rt_mutex_lock
    xor eax, eax
    mov edx, 1
    lock cmpxchg [rdi], edx
    jz .rml_done
.rml_slow:
    mov eax, 2
    xchg [rdi], eax
    test eax, eax
    jz .rml_done
.rml_wait:
    ; futex(rdi, FUTEX_WAIT_PRIVATE, 2, NULL, NULL, 0)
    mov eax, SYS_futex
    mov esi, FUTEX_WAIT_PRIVATE
    mov edx, 2
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    syscall
    mov eax, 2
    xchg [rdi], eax
    test eax, eax
    jnz .rml_wait
.rml_done:
    ret
END_FUNC rt_mutex_lock

;; ============================================================================
;; rt_mutex_unlock(rdi = uint32_t *mutex) -> nothing
;; ============================================================================
global rt_mutex_unlock
DEF_FUNC_BARE rt_mutex_unlock
    xor eax, eax
    xchg [rdi], eax
    cmp eax, 2
    jne .rmu_done
    ; futex(rdi, FUTEX_WAKE_PRIVATE, 1, NULL, NULL, 0)
    mov eax, SYS_futex
    mov esi, FUTEX_WAKE_PRIVATE
    mov edx, 1
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    syscall
.rmu_done:
    ret
END_FUNC rt_mutex_unlock

;; ============================================================================
;; rt_mutex_lock_p(rdi = uint32_t *mutex) -> nothing
;;
;; Register-preserving wrapper around rt_mutex_lock (preserves EVERY GPR,
;; clobbers only flags).  Fast uncontended path saves only rax and rdx.
;; ============================================================================
global rt_mutex_lock_p
DEF_FUNC_BARE rt_mutex_lock_p
    push rax
    push rdx
    xor eax, eax
    mov edx, 1
    lock cmpxchg [rdi], edx
    jnz .rmlp_slow
    pop rdx
    pop rax
    ret
.rmlp_slow:
    push rcx
    push rsi
    push r8
    push r9
    push r10
    push r11
.rmlp_xchg:
    mov eax, 2
    xchg [rdi], eax
    test eax, eax
    jz .rmlp_done
    mov eax, SYS_futex
    mov esi, FUTEX_WAIT_PRIVATE
    mov edx, 2
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    syscall
    jmp .rmlp_xchg
.rmlp_done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rcx
    pop rdx
    pop rax
    ret
END_FUNC rt_mutex_lock_p

;; ============================================================================
;; rt_mutex_unlock_p(rdi = uint32_t *mutex) -> nothing
;;
;; Register-preserving wrapper around rt_mutex_unlock (preserves EVERY GPR,
;; clobbers only flags).
;; ============================================================================
global rt_mutex_unlock_p
DEF_FUNC_BARE rt_mutex_unlock_p
    push rax
    xor eax, eax
    xchg [rdi], eax
    cmp eax, 2
    je .rmup_wake
    pop rax
    ret
.rmup_wake:
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    push r11
    mov eax, SYS_futex
    mov esi, FUTEX_WAKE_PRIVATE
    mov edx, 1
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    syscall
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
END_FUNC rt_mutex_unlock_p

;; ============================================================================
;; rt_mutex_lock2_p(rdi = mutex1, rsi = mutex2) -> nothing
;;
;; Lock two futex words in ascending pointer order, avoiding deadlock and
;; handling mutex1 == mutex2 safely.  Preserves EVERY GPR.
;; ============================================================================
global rt_mutex_lock2_p
DEF_FUNC_BARE rt_mutex_lock2_p
    cmp rdi, rsi
    je .rl2_same
    jb .rl2_order
    ; Swap rdi and rsi (restore before returning)
    push rdi
    push rsi
    xchg rdi, rsi
    call rt_mutex_lock_p
    mov rdi, rsi
    call rt_mutex_lock_p
    pop rsi
    pop rdi
    ret
.rl2_order:
    call rt_mutex_lock_p
    push rdi
    mov rdi, rsi
    call rt_mutex_lock_p
    pop rdi
    ret
.rl2_same:
    jmp rt_mutex_lock_p
END_FUNC rt_mutex_lock2_p

;; ============================================================================
;; rt_mutex_unlock2_p(rdi = mutex1, rsi = mutex2) -> nothing
;;
;; Unlock two futex words (handling mutex1 == mutex2).  Preserves EVERY GPR.
;; ============================================================================
global rt_mutex_unlock2_p
DEF_FUNC_BARE rt_mutex_unlock2_p
    cmp rdi, rsi
    je .ru2_same
    call rt_mutex_unlock_p
    push rdi
    mov rdi, rsi
    call rt_mutex_unlock_p
    pop rdi
    ret
.ru2_same:
    jmp rt_mutex_unlock_p
END_FUNC rt_mutex_unlock2_p

;; ============================================================================
;; brc_register_thread(rdi = ThreadState*) -> nothing
;;
;; Insert a live ThreadState into brc_buckets[ts_tid & 63].
;; ============================================================================
global brc_register_thread
DEF_FUNC brc_register_thread
    push rbx
    push r12
    mov rbx, rdi
    mov eax, [rbx + ThreadState.ts_tid]
    and eax, BRC_BUCKET_MASK
    shl eax, 6                          ; * 64 (BRC_BUCKET_STRIDE)
    lea r12, [rel brc_buckets]
    add r12, rax

    mov rdi, r12
    call rt_mutex_lock
    mov rax, [r12 + 8]
    mov [rbx + ThreadState.ts_brc_hash_next], rax
    mov [r12 + 8], rbx
    mov rdi, r12
    call rt_mutex_unlock

    pop r12
    pop rbx
    leave
    ret
END_FUNC brc_register_thread

;; ============================================================================
;; brc_unregister_thread(rdi = ThreadState*) -> nothing
;;
;; Remove an exiting ThreadState from brc_buckets[ts_tid & 63].  Once the
;; bucket lock is released, any remote thread trying to enqueue onto this tid
;; sees it absent (orphaned) and merges ob_ref_local directly.
;; ============================================================================
global brc_unregister_thread
DEF_FUNC brc_unregister_thread
    push rbx
    push r12
    mov rbx, rdi
    mov eax, [rbx + ThreadState.ts_tid]
    and eax, BRC_BUCKET_MASK
    shl eax, 6
    lea r12, [rel brc_buckets]
    add r12, rax

    mov rdi, r12
    call rt_mutex_lock
    lea rcx, [r12 + 8]                  ; &prev_link
.bu_scan:
    mov rax, [rcx]
    test rax, rax
    jz .bu_done
    cmp rax, rbx
    je .bu_found
    lea rcx, [rax + ThreadState.ts_brc_hash_next]
    jmp .bu_scan
.bu_found:
    mov rdx, [rbx + ThreadState.ts_brc_hash_next]
    mov [rcx], rdx
    mov qword [rbx + ThreadState.ts_brc_hash_next], 0
.bu_done:
    mov rdi, r12
    call rt_mutex_unlock

    pop r12
    pop rbx
    leave
    ret
END_FUNC brc_unregister_thread

;; ============================================================================
;; brc_enqueue(edi = owner_tid, rsi = PyObject *obj) -> eax = 1 if queued to
;;   live owner, 0 if owner has exited (orphaned)
;;
;; Called by a remote thread when ob_ref_shared drops below 0 on a non-merged
;; object.  Uses libc malloc/realloc for the queue array so it never recurses
;; into ap_malloc.
;; ============================================================================
BE_TID   equ 8
BE_OBJ   equ 16
BE_FRAME equ 16                 ; + 2 pushes = 32, 16-aligned
global brc_enqueue
DEF_FUNC brc_enqueue, BE_FRAME
    push rbx
    push r12
    mov [rbp - BE_TID], edi
    mov [rbp - BE_OBJ], rsi

    mov eax, edi
    and eax, BRC_BUCKET_MASK
    shl eax, 6
    lea r12, [rel brc_buckets]
    add r12, rax

    mov rdi, r12
    call rt_mutex_lock

    mov ebx, [rbp - BE_TID]
    mov rax, [r12 + 8]
.be_scan:
    test rax, rax
    jz .be_orphan
    cmp [rax + ThreadState.ts_tid], ebx
    je .be_found
    mov rax, [rax + ThreadState.ts_brc_hash_next]
    jmp .be_scan

.be_found:
    mov rbx, rax                        ; rbx = owner ThreadState*
    mov rcx, [rbx + ThreadState.ts_brc_len]
    cmp rcx, [rbx + ThreadState.ts_brc_cap]
    jb .be_push
    ; Grow owner's queue via libc realloc (starts at 64 entries).
    mov rax, [rbx + ThreadState.ts_brc_cap]
    test rax, rax
    jnz .be_double
    mov eax, 64
    jmp .be_grow
.be_double:
    shl rax, 1
.be_grow:
    push rax
    sub rsp, 8
    mov rdi, [rbx + ThreadState.ts_brc_buf]
    lea rsi, [rax * 8]
    call realloc wrt ..plt
    add rsp, 8
    pop rcx                             ; new cap
    test rax, rax
    jnz .be_grown
    CSTRING rdi, "out of memory growing BRC merge queue"
    call fatal_error
.be_grown:
    mov [rbx + ThreadState.ts_brc_buf], rax
    mov [rbx + ThreadState.ts_brc_cap], rcx
    mov rcx, [rbx + ThreadState.ts_brc_len]
.be_push:
    mov rax, [rbx + ThreadState.ts_brc_buf]
    mov rdx, [rbp - BE_OBJ]
    mov [rax + rcx*8], rdx
    inc qword [rbx + ThreadState.ts_brc_len]
    lock or qword [rel eval_breaker], EB_BRC_MERGE

    mov rdi, r12
    call rt_mutex_unlock
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret

.be_orphan:
    mov rdi, r12
    call rt_mutex_unlock
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC brc_enqueue

;; ============================================================================
;; brc_take_queue(rdi = ThreadState*, rsi = &out_len) -> rax = PyObject** or 0
;;
;; Atomically detach a thread's BRC queue under its bucket lock so the owner
;; (or STW GC) can merge & deallocate entries without holding the bucket lock.
;; Caller must free() the returned buffer when non-NULL.
;; ============================================================================
global brc_take_queue
DEF_FUNC brc_take_queue
    push rbx
    push r12
    push r13
    sub rsp, 8
    mov rbx, rdi                        ; tstate
    mov r13, rsi                        ; &out_len
    mov eax, [rbx + ThreadState.ts_tid]
    and eax, BRC_BUCKET_MASK
    shl eax, 6
    lea r12, [rel brc_buckets]
    add r12, rax

    mov rdi, r12
    call rt_mutex_lock
    mov rax, [rbx + ThreadState.ts_brc_buf]
    mov rcx, [rbx + ThreadState.ts_brc_len]
    mov [r13], rcx
    test rcx, rcx
    jz .btq_empty
    mov qword [rbx + ThreadState.ts_brc_buf], 0
    mov qword [rbx + ThreadState.ts_brc_len], 0
    mov qword [rbx + ThreadState.ts_brc_cap], 0
    mov rbx, rax
    mov rdi, r12
    call rt_mutex_unlock
    mov rax, rbx
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    leave
    ret
.btq_empty:
    mov rdi, r12
    call rt_mutex_unlock
    xor eax, eax
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC brc_take_queue

;; ============================================================================
;; brc_reset_after_fork(rdi = surviving ThreadState*) -> nothing
;;
;; Zero all 64 BRC bucket locks/lists in a forked child and re-register only
;; the surviving thread.
;; ============================================================================
global brc_reset_after_fork
DEF_FUNC brc_reset_after_fork
    push rbx
    sub rsp, 8
    mov rbx, rdi
    lea rdi, [rel brc_buckets]
    xor eax, eax
    mov ecx, (BRC_NBUCKETS * BRC_BUCKET_STRIDE) / 8
    rep stosq
    mov qword [rbx + ThreadState.ts_brc_hash_next], 0
    mov byte [rel rt_threaded], 0
    mov rdi, rbx
    call brc_register_thread
    add rsp, 8
    pop rbx
    leave
    ret
END_FUNC brc_reset_after_fork
