; sync.asm - 32-bit direct futex locks, monotonic thread IDs, and the 64-bucket
; Biased Reference Counting (BRC) thread registry and merge queue.

%include "macros.inc"
%include "object.inc"
%include "threadstate.inc"
%include "gil.inc"
%include "sync.inc"

ASM_INIT

extern eval_breaker
extern gil_threaded
extern gil_finalizing
extern tstate_main_ptr
extern tstate_list_head
extern tstate_list_lock
extern tstate_install
extern tstate_link
extern tstate_unlink
extern malloc
extern realloc
extern aligned_alloc
extern free
extern pthread_self
extern pthread_key_create
extern pthread_getspecific
extern pthread_setspecific
extern pause
extern fatal_error
extern obj_dealloc
extern obj_decref
extern ap_free
extern alloc_thread_flush
extern sre_cpcache_clear_thread

SYS_arch_prctl  equ 158
ARCH_SET_GS     equ 0x1001
ARCH_GET_GS     equ 0x1004
SYS_gettid_sync equ 186
TSTATE_ALLOC_SZ equ (ThreadState_size + 63) & ~63

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
global rt_tstate_key
rt_tstate_key:  dd 0            ; pthread_key_t for ThreadState* (0 on foreign threads)
                times 56 db 0

; Stop-The-World (STW) coordinator state (cache-line isolated).
align 64
stw_mutex:      dd 0            ; serializes concurrent STW requesters
                dd 0
global stw_requested
stw_requested:  dd 0            ; 1 while STW active (futex for parked threads)
stw_remaining:  dd 0            ; attached threads still to park (futex for owner)
stw_owner_ts:   dq 0            ; ThreadState* of active STW owner, or 0
                times 40 db 0

section .bss
alignb 64
; 64 cache-line-padded BRC hash buckets.
; Each 64-byte entry:
;   +0  dword lock  (32-bit futex)
;   +4  dword pad
;   +8  qword head  (ThreadState* linked via ts_brc_hash_next)
;   +16..63 padding
global brc_buckets
brc_buckets:    resb (BRC_NBUCKETS * BRC_BUCKET_STRIDE)
alignb 64
brc_pending_total: resq 1

section .text

;; ============================================================================
;; rt_enable_threading() -> nothing
;;
;; Publish rt_threaded = 1 and gil_threaded = 1 with full memory ordering so
;; every subsequently started thread and leaf lock observes concurrent mode.
;; ============================================================================
global rt_enable_threading
DEF_FUNC_BARE rt_enable_threading
    mov qword [rel gil_threaded], 1
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
    lock inc qword [rel brc_pending_total]
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
    mov rdx, [r13]
    neg rdx
    mov rax, rdx
    lock xadd [rel brc_pending_total], rax
    add rax, rdx
    jnz .btq_ret
    lock and qword [rel eval_breaker], ~EB_BRC_MERGE
    cmp qword [rel brc_pending_total], 0
    je .btq_ret
    lock or qword [rel eval_breaker], EB_BRC_MERGE
.btq_ret:
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
    mov qword [rel brc_pending_total], 0
    mov rax, [rbx + ThreadState.ts_brc_len]
    test rax, rax
    jz .braf_clear_eb
    mov [rel brc_pending_total], rax
    jmp .braf_reg
.braf_clear_eb:
    lock and qword [rel eval_breaker], ~EB_BRC_MERGE
.braf_reg:
    mov byte [rel rt_threaded], 0
    mov rdi, rbx
    call brc_register_thread
    add rsp, 8
    pop rbx
    leave
    ret
END_FUNC brc_reset_after_fork

;; ============================================================================
;; obj_decref_local_zero(rdi = PyObject *obj) -> nothing
;;
;; Owner thread just decremented ob_ref_local to 0.  In single-threaded mode
;; (rt_threaded == 0) with ob_ref_shared == 0, deallocate immediately with no
;; locked instruction.  In concurrent mode, atomically transition ob_ref_shared
;; to REF_MERGED and ob_tid to REF_TID_MERGED so a racing weakref try-incref
;; cannot resurrect the dying object.
;; ============================================================================
global obj_decref_local_zero
DEF_FUNC_BARE obj_decref_local_zero
    cmp byte [rel rt_threaded], 0
    jne .odlz_conc
    cmp dword [rdi + PyObject.ob_ref_shared], 0
    je obj_dealloc
.odlz_conc:
    mov dword [rdi + PyObject.ob_tid], REF_TID_MERGED
    mov eax, [rdi + PyObject.ob_ref_shared]
.odlz_cas:
    mov edx, eax
    or edx, REF_MERGED_BIT
    lock cmpxchg [rdi + PyObject.ob_ref_shared], edx
    jne .odlz_cas
    cmp edx, REF_MERGED_BIT
    je obj_dealloc
    ret
END_FUNC obj_decref_local_zero

;; ============================================================================
;; obj_decref_shared(rdi = PyObject *obj) -> nothing
;;
;; Non-owner or merged-object decrement on ob_ref_shared.  If a non-merged
;; object's shared count drops below zero, sets REF_QUEUED_BIT and enqueues
;; it onto the owner's BRC merge queue (or merges directly if the owner exited).
;; ============================================================================
global obj_decref_shared
DEF_FUNC obj_decref_shared, 8           ; + 1 push (rbx) = 16, 16-aligned
    push rbx
    mov rbx, rdi
    mov eax, [rbx + PyObject.ob_ref_shared]
.ods_cas:
    test eax, REF_MERGED_BIT
    jnz .ods_merged
    mov edx, eax
    sub edx, REF_SHARED_ONE
    test edx, edx
    jns .ods_store
    test eax, REF_QUEUED_BIT
    jnz .ods_store
    or edx, REF_QUEUED_BIT
    lock cmpxchg [rbx + PyObject.ob_ref_shared], edx
    jne .ods_cas
    mov edi, [rbx + PyObject.ob_tid]
    mov rsi, rbx
    call brc_enqueue
    test eax, eax
    jnz .ods_done
    mov r8d, [rbx + PyObject.ob_ref_local]
    mov dword [rbx + PyObject.ob_ref_local], 0
    mov dword [rbx + PyObject.ob_tid], REF_TID_MERGED
    shl r8d, REF_SHARED_SHIFT
    mov eax, [rbx + PyObject.ob_ref_shared]
.ods_orphan_cas:
    mov edx, eax
    add edx, r8d
    and edx, ~REF_QUEUED_BIT
    or edx, REF_MERGED_BIT
    lock cmpxchg [rbx + PyObject.ob_ref_shared], edx
    jne .ods_orphan_cas
    cmp edx, REF_MERGED_BIT
    jne .ods_done
    mov rdi, rbx
    pop rbx
    leave
    jmp obj_dealloc
.ods_store:
    lock cmpxchg [rbx + PyObject.ob_ref_shared], edx
    jne .ods_cas
.ods_done:
    pop rbx
    leave
    ret
.ods_merged:
    mov edx, eax
    sub edx, REF_SHARED_ONE
    lock cmpxchg [rbx + PyObject.ob_ref_shared], edx
    jne .ods_cas
    cmp edx, REF_MERGED_BIT
    jne .ods_done
    mov rdi, rbx
    pop rbx
    leave
    jmp obj_dealloc
END_FUNC obj_decref_shared

;; ============================================================================
;; obj_decref_shared_p(rdi = PyObject *obj) -> nothing
;;
;; Register-preserving wrapper around obj_decref_shared for DECREF_V's cold
;; non-local path.
;; ============================================================================
global obj_decref_shared_p
DEF_FUNC_BARE obj_decref_shared_p
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    push r11
    sub rsp, 8
    call obj_decref_shared
    add rsp, 8
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
END_FUNC obj_decref_shared_p

;; ============================================================================
;; obj_decref_no_dealloc(rdi = PyObject *obj) -> eax = 1 if still alive (>0),
;;   0 if total refcount reached 0 (does NOT call obj_dealloc)
;; ============================================================================
global obj_decref_no_dealloc
DEF_FUNC obj_decref_no_dealloc, 8       ; + 1 push (rbx) = 16, 16-aligned
    push rbx
    mov rbx, rdi
    mov eax, [rbx + PyObject.ob_tid]
    test eax, eax
    jz .odnd_alive
    cmp eax, [gs:ThreadState.ts_tid]
    jne .odnd_nonlocal
    dec dword [rbx + PyObject.ob_ref_local]
    jnz .odnd_alive
    mov dword [rbx + PyObject.ob_tid], REF_TID_MERGED
    mov eax, [rbx + PyObject.ob_ref_shared]
.odnd_lcas:
    mov edx, eax
    or edx, REF_MERGED_BIT
    lock cmpxchg [rbx + PyObject.ob_ref_shared], edx
    jne .odnd_lcas
    cmp edx, REF_MERGED_BIT
    je .odnd_dead
.odnd_alive:
    mov eax, 1
    pop rbx
    leave
    ret
.odnd_dead:
    xor eax, eax
    pop rbx
    leave
    ret
.odnd_nonlocal:
    mov eax, [rbx + PyObject.ob_ref_shared]
.odnd_scas:
    test eax, REF_MERGED_BIT
    jnz .odnd_smerged
    mov edx, eax
    sub edx, REF_SHARED_ONE
    test edx, edx
    jns .odnd_sstore
    test eax, REF_QUEUED_BIT
    jnz .odnd_sstore
    or edx, REF_QUEUED_BIT
    lock cmpxchg [rbx + PyObject.ob_ref_shared], edx
    jne .odnd_scas
    mov edi, [rbx + PyObject.ob_tid]
    mov rsi, rbx
    call brc_enqueue
    test eax, eax
    jnz .odnd_alive
    mov r8d, [rbx + PyObject.ob_ref_local]
    mov dword [rbx + PyObject.ob_ref_local], 0
    mov dword [rbx + PyObject.ob_tid], REF_TID_MERGED
    shl r8d, REF_SHARED_SHIFT
    mov eax, [rbx + PyObject.ob_ref_shared]
.odnd_ocas:
    mov edx, eax
    add edx, r8d
    and edx, ~REF_QUEUED_BIT
    or edx, REF_MERGED_BIT
    lock cmpxchg [rbx + PyObject.ob_ref_shared], edx
    jne .odnd_ocas
    cmp edx, REF_MERGED_BIT
    je .odnd_dead
    jmp .odnd_alive
.odnd_sstore:
    lock cmpxchg [rbx + PyObject.ob_ref_shared], edx
    jne .odnd_scas
    jmp .odnd_alive
.odnd_smerged:
    mov edx, eax
    sub edx, REF_SHARED_ONE
    lock cmpxchg [rbx + PyObject.ob_ref_shared], edx
    jne .odnd_scas
    cmp edx, REF_MERGED_BIT
    je .odnd_dead
    jmp .odnd_alive
END_FUNC obj_decref_no_dealloc

;; ============================================================================
;; obj_try_incref(rdi = PyObject *obj) -> eax = 1 if incremented, 0 if dying
;; ============================================================================
global obj_try_incref
DEF_FUNC_BARE obj_try_incref
    mov eax, [rdi + PyObject.ob_tid]
    test eax, eax
    jz .oti_ok
    cmp eax, [gs:ThreadState.ts_tid]
    jne .oti_shared
    cmp dword [rdi + PyObject.ob_ref_local], 0
    je .oti_dead
    inc dword [rdi + PyObject.ob_ref_local]
.oti_ok:
    mov eax, 1
    ret
.oti_shared:
    mov eax, [rdi + PyObject.ob_ref_shared]
.oti_cas:
    test eax, REF_MERGED_BIT
    jz .oti_add
    mov edx, eax
    sar edx, REF_SHARED_SHIFT
    test edx, edx
    jle .oti_dead
.oti_add:
    lea edx, [eax + REF_SHARED_ONE]
    lock cmpxchg [rdi + PyObject.ob_ref_shared], edx
    jne .oti_cas
    mov eax, 1
    ret
.oti_dead:
    xor eax, eax
    ret
END_FUNC obj_try_incref

;; ============================================================================
;; obj_get_refcount(rdi = PyObject *obj) -> rax = total refcount
;; ============================================================================
global obj_get_refcount
DEF_FUNC_BARE obj_get_refcount
    mov ecx, [rdi + PyObject.ob_tid]
    test ecx, ecx
    jz .ogr_immortal
    mov eax, [rdi + PyObject.ob_ref_shared]
    sar eax, REF_SHARED_SHIFT
    movsxd rax, eax
    cmp ecx, REF_TID_MERGED
    je .ogr_done
    mov edx, [rdi + PyObject.ob_ref_local]
    add rax, rdx
.ogr_done:
    ret
.ogr_immortal:
    mov eax, 0xFFFFFFFF
    ret
END_FUNC obj_get_refcount

;; ============================================================================
;; obj_addref_bulk(rdi = PyObject *obj, rsi = uint64_t count) -> nothing
;; ============================================================================
global obj_addref_bulk
DEF_FUNC_BARE obj_addref_bulk
    mov eax, [rdi + PyObject.ob_tid]
    cmp eax, [gs:ThreadState.ts_tid]
    jne .oab_nonlocal
    add dword [rdi + PyObject.ob_ref_local], esi
    ret
.oab_nonlocal:
    test eax, eax
    jz .oab_done
    mov ecx, esi
    shl ecx, REF_SHARED_SHIFT
    lock add dword [rdi + PyObject.ob_ref_shared], ecx
.oab_done:
    ret
END_FUNC obj_addref_bulk

;; ============================================================================
;; brc_drain_thread(rdi = ThreadState *ts) -> nothing
;; ============================================================================
BDT_LEN   equ 8
BDT_FRAME equ 24                        ; + 3 pushes = 48, 16-aligned
global brc_drain_thread
DEF_FUNC brc_drain_thread, BDT_FRAME
    push rbx
    push r12
    push r13
    lea rsi, [rbp - BDT_LEN]
    call brc_take_queue
    test rax, rax
    jz .bdt_done
    mov rbx, rax
    mov r12, [rbp - BDT_LEN]
    xor r13d, r13d
.bdt_loop:
    cmp r13, r12
    jae .bdt_free
    mov rdi, [rbx + r13*8]
    inc r13
    mov r8d, [rdi + PyObject.ob_ref_local]
    mov dword [rdi + PyObject.ob_ref_local], 0
    mov dword [rdi + PyObject.ob_tid], REF_TID_MERGED
    shl r8d, REF_SHARED_SHIFT
    mov eax, [rdi + PyObject.ob_ref_shared]
.bdt_cas:
    mov edx, eax
    add edx, r8d
    and edx, ~REF_QUEUED_BIT
    or edx, REF_MERGED_BIT
    lock cmpxchg [rdi + PyObject.ob_ref_shared], edx
    jne .bdt_cas
    cmp edx, REF_MERGED_BIT
    jne .bdt_loop
    call obj_dealloc
    jmp .bdt_loop
.bdt_free:
    mov rdi, rbx
    call free wrt ..plt
.bdt_done:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC brc_drain_thread

;; ============================================================================
;; brc_drain_all_stw() -> rax = libc-malloc'd PyObject** of deferred dead
;;   objects (each pinned with refcount=1), rdx = count (0 if none)
;;
;; Must ONLY be called inside STW (or single-threaded).  Drains every live
;; ThreadState's BRC queue so every object's refcount is exact before GC
;; reachability analysis.  Never calls obj_dealloc inside STW: objects whose
;; refcount reaches 0 are bumped back to 1 and returned for unlocked DECREF
;; after stw_start_world().
;; ============================================================================
BDA_BUF   equ 8
BDA_LEN   equ 16
BDA_CAP   equ 24
BDA_QLEN  equ 32
BDA_FRAME equ 40                        ; + 5 pushes = 80, 16-aligned
global brc_drain_all_stw
DEF_FUNC brc_drain_all_stw, BDA_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov qword [rbp - BDA_BUF], 0
    mov qword [rbp - BDA_LEN], 0
    mov qword [rbp - BDA_CAP], 0

    mov r15, [rel tstate_list_head]
.bda_ts_loop:
    test r15, r15
    jz .bda_done
    cmp qword [r15 + ThreadState.ts_brc_len], 0
    je .bda_ts_next
    mov rdi, r15
    lea rsi, [rbp - BDA_QLEN]
    call brc_take_queue
    test rax, rax
    jz .bda_ts_next
    mov rbx, rax
    mov r12, [rbp - BDA_QLEN]
    xor r13d, r13d
.bda_obj_loop:
    cmp r13, r12
    jae .bda_free_q
    mov r14, [rbx + r13*8]
    inc r13
    mov r8d, [r14 + PyObject.ob_ref_local]
    mov dword [r14 + PyObject.ob_ref_local], 0
    shl r8d, REF_SHARED_SHIFT
    mov eax, [r14 + PyObject.ob_ref_shared]
.bda_cas:
    mov edx, eax
    add edx, r8d
    and edx, ~REF_QUEUED_BIT
    or edx, REF_MERGED_BIT
    lock cmpxchg [r14 + PyObject.ob_ref_shared], edx
    jne .bda_cas
    mov dword [r14 + PyObject.ob_tid], REF_TID_MERGED
    cmp edx, REF_MERGED_BIT
    jne .bda_obj_loop
    ; Refcount reached 0 inside STW: pin to 1 and defer dealloc until after STW.
    mov dword [r14 + PyObject.ob_ref_shared], REF_MERGED_BIT | REF_SHARED_ONE
    mov rax, [rbp - BDA_LEN]
    cmp rax, [rbp - BDA_CAP]
    jb .bda_append
    mov rcx, [rbp - BDA_CAP]
    test rcx, rcx
    jnz .bda_grow
    mov ecx, 16
    jmp .bda_realloc
.bda_grow:
    shl rcx, 1
.bda_realloc:
    mov [rbp - BDA_CAP], rcx
    mov rdi, [rbp - BDA_BUF]
    lea rsi, [rcx * 8]
    call realloc wrt ..plt
    test rax, rax
    jz .bda_oom
    mov [rbp - BDA_BUF], rax
.bda_append:
    mov rax, [rbp - BDA_BUF]
    mov rcx, [rbp - BDA_LEN]
    mov [rax + rcx * 8], r14
    inc qword [rbp - BDA_LEN]
    jmp .bda_obj_loop
.bda_free_q:
    mov rdi, rbx
    call free wrt ..plt
.bda_ts_next:
    mov r15, [r15 + ThreadState.ts_next]
    jmp .bda_ts_loop
.bda_done:
    lock and qword [rel eval_breaker], ~EB_BRC_MERGE
    mov rax, [rbp - BDA_BUF]
    mov rdx, [rbp - BDA_LEN]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.bda_oom:
    CSTRING rdi, "out of memory draining BRC queues during STW"
    call fatal_error
END_FUNC brc_drain_all_stw

;; ============================================================================
;; rt_detach() -> nothing
;;
;; Transition the calling thread from TS_STATE_ATTACHED to TS_STATE_DETACHED.
;; If a Stop-The-World pause is currently waiting for attached threads to park,
;; decrement stw_remaining and wake the STW coordinator when it reaches 0.
;; ============================================================================
global rt_detach
DEF_FUNC rt_detach
    cmp byte [rel rt_threaded], 0
    je .rtd_done
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_lock
    mov rax, [gs:ThreadState.ts_self]
    cmp dword [rax + ThreadState.ts_state], TS_STATE_ATTACHED
    jne .rtd_unlock
    mov dword [rax + ThreadState.ts_state], TS_STATE_DETACHED
    cmp dword [rel stw_requested], 0
    je .rtd_unlock
    cmp rax, [rel stw_owner_ts]
    je .rtd_unlock
    dec dword [rel stw_remaining]
    jnz .rtd_unlock
    ; Wake the STW coordinator waiting on stw_remaining
    mov eax, SYS_futex
    lea rdi, [rel stw_remaining]
    mov esi, FUTEX_WAKE_PRIVATE
    mov edx, 1
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    syscall
.rtd_unlock:
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_unlock
.rtd_done:
    leave
    ret
END_FUNC rt_detach

;; ============================================================================
;; rt_reattach() -> nothing
;;
;; Transition the calling thread back to TS_STATE_ATTACHED.  If a STW pause
;; is active, block on the stw_requested futex until the world resumes.
;; ============================================================================
global rt_reattach
DEF_FUNC rt_reattach
    cmp qword [rel gil_finalizing], 0
    je .rtr_not_fin
    mov rax, [gs:ThreadState.ts_self]
    cmp rax, [rel tstate_main_ptr]
    jne .rtr_park_forever
.rtr_not_fin:
    cmp byte [rel rt_threaded], 0
    je .rtr_done
.rtr_retry:
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_lock
    cmp qword [rel gil_finalizing], 0
    je .rtr_check_stw
    mov rax, [gs:ThreadState.ts_self]
    cmp rax, [rel tstate_main_ptr]
    jne .rtr_shutdown_park
.rtr_check_stw:
    cmp dword [rel stw_requested], 0
    jne .rtr_wait
    mov rax, [gs:ThreadState.ts_self]
    mov dword [rax + ThreadState.ts_state], TS_STATE_ATTACHED
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_unlock
.rtr_done:
    leave
    ret
.rtr_wait:
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_unlock
    mov eax, SYS_futex
    lea rdi, [rel stw_requested]
    mov esi, FUTEX_WAIT_PRIVATE
    mov edx, 1
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    syscall
    jmp .rtr_retry
.rtr_shutdown_park:
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_unlock
.rtr_park_forever:
    call pause wrt ..plt
    jmp .rtr_park_forever
END_FUNC rt_reattach

;; ============================================================================
;; stw_safepoint() -> nothing
;;
;; Called from eval_breaker_slow (EB_STOP_WORLD) and long native loops (sre,
;; timsort).  Parks the calling thread until stw_start_world() clears
;; stw_requested and wakes all parked threads (or permanently if shutting down).
;; ============================================================================
global stw_safepoint
DEF_FUNC stw_safepoint
    cmp dword [rel stw_requested], 0
    je .sp_done
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_lock
    cmp dword [rel stw_requested], 0
    je .sp_unlock_done
    mov rax, [gs:ThreadState.ts_self]
    cmp rax, [rel stw_owner_ts]
    je .sp_unlock_done
    cmp dword [rax + ThreadState.ts_state], TS_STATE_ATTACHED
    jne .sp_unlock_wait
    mov dword [rax + ThreadState.ts_state], TS_STATE_PARKED
    dec dword [rel stw_remaining]
    jnz .sp_unlock_wait
    mov eax, SYS_futex
    lea rdi, [rel stw_remaining]
    mov esi, FUTEX_WAKE_PRIVATE
    mov edx, 1
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    syscall
.sp_unlock_wait:
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_unlock
    cmp qword [rel gil_finalizing], 0
    je .sp_wait_loop
    mov rax, [gs:ThreadState.ts_self]
    cmp rax, [rel tstate_main_ptr]
    jne .sp_park_forever
.sp_wait_loop:
    mov eax, SYS_futex
    lea rdi, [rel stw_requested]
    mov esi, FUTEX_WAIT_PRIVATE
    mov edx, 1
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    syscall
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_lock
    cmp qword [rel gil_finalizing], 0
    je .sp_recheck_stw
    mov rax, [gs:ThreadState.ts_self]
    cmp rax, [rel tstate_main_ptr]
    jne .sp_shutdown_unlock
.sp_recheck_stw:
    cmp dword [rel stw_requested], 0
    jne .sp_unlock_wait
    mov rax, [gs:ThreadState.ts_self]
    mov dword [rax + ThreadState.ts_state], TS_STATE_ATTACHED
.sp_unlock_done:
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_unlock
.sp_done:
    leave
    ret
.sp_shutdown_unlock:
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_unlock
.sp_park_forever:
    call pause wrt ..plt
    jmp .sp_park_forever
END_FUNC stw_safepoint

;; ============================================================================
;; stw_stop_world() -> nothing
;;
;; Stop all other attached Python threads at safepoints.  No-op while
;; rt_threaded == 0.  Detaches self while acquiring stw_mutex so two concurrent
;; STW requesters never deadlock against each other.
;; ============================================================================
global stw_stop_world
DEF_FUNC stw_stop_world
    cmp byte [rel rt_threaded], 0
    je .ssw_done
    ; Detach while waiting on stw_mutex so another active STW does not wait on us.
    call rt_detach
    lea rdi, [rel stw_mutex]
    call rt_mutex_lock

    lea rdi, [rel tstate_list_lock]
    call rt_mutex_lock
    mov rcx, [gs:ThreadState.ts_self]
    mov dword [rcx + ThreadState.ts_state], TS_STATE_ATTACHED
    mov [rel stw_owner_ts], rcx
    mov dword [rel stw_requested], 1
    lock or qword [rel eval_breaker], EB_STOP_WORLD

    ; Count every other thread currently in TS_STATE_ATTACHED.
    xor edx, edx
    mov rax, [rel tstate_list_head]
.ssw_count:
    test rax, rax
    jz .ssw_counted
    cmp rax, rcx
    je .ssw_next
    cmp dword [rax + ThreadState.ts_state], TS_STATE_ATTACHED
    jne .ssw_next
    inc edx
.ssw_next:
    mov rax, [rax + ThreadState.ts_next]
    jmp .ssw_count
.ssw_counted:
    mov [rel stw_remaining], edx
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_unlock

    ; Wait until every attached thread has parked or detached.
.ssw_wait:
    mov edx, [rel stw_remaining]
    test edx, edx
    jz .ssw_done
    mov eax, SYS_futex
    lea rdi, [rel stw_remaining]
    mov esi, FUTEX_WAIT_PRIVATE
    ; edx = observed stw_remaining
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    syscall
    jmp .ssw_wait
.ssw_done:
    leave
    ret
END_FUNC stw_stop_world

;; ============================================================================
;; stw_start_world() -> nothing
;;
;; Resume all threads parked by stw_stop_world().  No-op while rt_threaded == 0.
;; ============================================================================
global stw_start_world
DEF_FUNC stw_start_world
    cmp byte [rel rt_threaded], 0
    je .srw_done
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_lock
    lock and qword [rel eval_breaker], ~EB_STOP_WORLD
    mov qword [rel stw_owner_ts], 0
    mov dword [rel stw_requested], 0
    mov eax, SYS_futex
    lea rdi, [rel stw_requested]
    mov esi, FUTEX_WAKE_PRIVATE
    mov edx, 0x7FFFFFFF
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    syscall
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_unlock
    lea rdi, [rel stw_mutex]
    call rt_mutex_unlock
.srw_done:
    leave
    ret
END_FUNC stw_start_world

;; ============================================================================
;; stw_reset_after_fork() -> nothing
;; Reset STW coordinator state in a forked child (single thread survives).
;; ============================================================================
global stw_reset_after_fork
DEF_FUNC_BARE stw_reset_after_fork
    mov dword [rel stw_mutex], 0
    mov dword [rel stw_requested], 0
    mov dword [rel stw_remaining], 0
    mov qword [rel stw_owner_ts], 0
    lock and qword [rel eval_breaker], ~(EB_STOP_WORLD | EB_GC_COLLECT)
    ret
END_FUNC stw_reset_after_fork

;; ============================================================================
;; stw_notify_unlink(rdi = ThreadState *self) -> nothing
;;
;; Called by tstate_unlink while holding tstate_list_lock.  If a STW is waiting
;; on this exiting attached thread, decrement stw_remaining and wake owner.
;; ============================================================================
global stw_notify_unlink
DEF_FUNC_BARE stw_notify_unlink
    cmp dword [rdi + ThreadState.ts_state], TS_STATE_ATTACHED
    jne .snu_done
    mov dword [rdi + ThreadState.ts_state], TS_STATE_DETACHED
    cmp dword [rel stw_requested], 0
    je .snu_done
    cmp rdi, [rel stw_owner_ts]
    je .snu_done
    dec dword [rel stw_remaining]
    jnz .snu_done
    mov eax, SYS_futex
    lea rdi, [rel stw_remaining]
    mov esi, FUTEX_WAKE_PRIVATE
    mov edx, 1
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    syscall
.snu_done:
    ret
END_FUNC stw_notify_unlink

;; ============================================================================
;; rt_foreign_enter() -> eax = 0 (already attached), 1 (reattached Python
;;   thread), or 2 (newly created foreign ThreadState)
;;
;; Entry guard for C-to-Python callbacks (ctypes cx_tramp).  Uses POSIX
;; pthread_getspecific(rt_tstate_key) rather than ARCH_GET_GS because Linux
;; clone() inherits the creator's gs_base onto foreign pthreads whereas
;; pthread TLS keys are guaranteed NULL on every newly spawned foreign thread.
;; ============================================================================
global rt_foreign_enter
DEF_FUNC rt_foreign_enter
    push rbx
    push r12
    mov edi, [rel rt_tstate_key]
    call pthread_getspecific wrt ..plt
    test rax, rax
    jz .rfe_foreign

    ; Known Python thread: check shutdown before rt_threaded early-out, then
    ; reattach if detached (e.g. inside ALLOW_THREADS ffi_call).
    cmp qword [rel gil_finalizing], 0
    je .rfe_not_fin
    cmp rax, [rel tstate_main_ptr]
    jne .rfe_park_forever
.rfe_not_fin:
    cmp byte [rel rt_threaded], 0
    je .rfe_already
    cmp dword [rax + ThreadState.ts_state], TS_STATE_ATTACHED
    je .rfe_already
    call rt_reattach
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret

.rfe_already:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.rfe_park_forever:
    call pause wrt ..plt
    jmp .rfe_park_forever

.rfe_foreign:
    ; Foreign C pthread with no ThreadState: park if interpreter is shutting down.
    cmp qword [rel gil_finalizing], 0
    jne .rfe_park_forever
    call rt_enable_threading
    mov edi, 64
    mov esi, TSTATE_ALLOC_SZ
    call aligned_alloc wrt ..plt
    test rax, rax
    jz .rfe_oom
    mov rbx, rax
    mov rdi, rax
    mov ecx, TSTATE_ALLOC_SZ / 8
    xor eax, eax
    rep stosq

    mov rdi, rbx
    call tstate_install
    mov edi, [rel rt_tstate_key]
    mov rsi, rbx
    call pthread_setspecific wrt ..plt
    call rt_tid_alloc
    mov [rbx + ThreadState.ts_tid], eax
    mov ecx, eax
    shl rcx, 40
    mov [rbx + ThreadState.ts_dict_ver], rcx
    mov dword [rbx + ThreadState.ts_state], TS_STATE_DETACHED
    mov rdi, rbx
    call brc_register_thread
    call pthread_self wrt ..plt
    mov [rbx + ThreadState.ts_ident], rax
    mov eax, SYS_gettid_sync
    syscall
    mov [rbx + ThreadState.ts_native_id], rax
    call tstate_link
    call rt_reattach
    mov eax, 2
    pop r12
    pop rbx
    leave
    ret
.rfe_oom:
    CSTRING rdi, "out of memory creating foreign ThreadState"
    call fatal_error
END_FUNC rt_foreign_enter

;; ============================================================================
;; rt_foreign_leave(edi = flag from rt_foreign_enter) -> nothing
;; ============================================================================
global rt_foreign_leave
DEF_FUNC rt_foreign_leave, 8            ; + 1 push = 16, 16-aligned
    push rbx
    test edi, edi
    jz .rfl_done
    cmp edi, 1
    jne .rfl_foreign
    call rt_detach
    jmp .rfl_done

.rfl_foreign:
    mov rdi, [gs:ThreadState.current_exception]
    test rdi, rdi
    jz .rfl_no_exc
    mov qword [gs:ThreadState.current_exception], 0
    call obj_decref
.rfl_no_exc:
    call sre_cpcache_clear_thread
    mov rdi, [gs:ThreadState.ts_import_ns_portions]
    test rdi, rdi
    jz .rfl_no_ns
    mov qword [gs:ThreadState.ts_import_ns_portions], 0
    call obj_decref
.rfl_no_ns:
    mov rdi, [gs:ThreadState.ts_dict]
    test rdi, rdi
    jz .rfl_no_dict
    mov qword [gs:ThreadState.ts_dict], 0
    call obj_decref
.rfl_no_dict:
    mov rdi, [gs:ThreadState.frame_datastack_base]
    test rdi, rdi
    jz .rfl_no_stack
    mov qword [gs:ThreadState.frame_datastack_base], 0
    mov qword [gs:ThreadState.frame_datastack_top], 0
    mov qword [gs:ThreadState.frame_datastack_end], 0
    call ap_free
.rfl_no_stack:
    mov rdi, [gs:ThreadState.repr_stack]
    test rdi, rdi
    jz .rfl_no_repr
    call ap_free
.rfl_no_repr:
    mov rbx, [gs:ThreadState.ts_self]
    mov rdi, rbx
    call brc_drain_thread
    mov rdi, rbx
    call brc_unregister_thread
    mov rdi, rbx
    call brc_drain_thread
    call alloc_thread_flush
    call tstate_unlink

    ; Clear pthread TLS key and gs_base before freeing ThreadState
    mov edi, [rel rt_tstate_key]
    xor esi, esi
    call pthread_setspecific wrt ..plt
    mov eax, SYS_arch_prctl
    mov edi, ARCH_SET_GS
    xor esi, esi
    syscall

    mov rdi, [rbx + ThreadState.trash_buf]
    test rdi, rdi
    jz .rfl_no_trash
    call free wrt ..plt
.rfl_no_trash:
    mov rdi, [rbx + ThreadState.ssl_pw_buf]
    test rdi, rdi
    jz .rfl_no_ssl
    call free wrt ..plt
.rfl_no_ssl:
    mov rdi, [rbx + ThreadState.ts_path_scratch]
    test rdi, rdi
    jz .rfl_no_path
    call free wrt ..plt
.rfl_no_path:
    mov rdi, rbx
    call free wrt ..plt

.rfl_done:
    pop rbx
    leave
    ret
END_FUNC rt_foreign_leave
