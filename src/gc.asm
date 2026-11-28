; gc.asm - Cycle-collecting garbage collector for apython
; CPython 3.12 compatible generational GC with 8-shard tracking and
; 2-phase Stop-The-World (STW) collection.
;
; Three generations: gen0 (young), gen1, gen2 (old).
; Tracking lists are sharded across 8 cache-line-padded shards (selected by
; ts_tid & 7).  Every GC-allocated PyGC_Head is at least 8-byte aligned (note:
; ap_malloc size class 40 is 8-byte aligned, NOT 16-byte aligned), so the low
; 3 bits of PyGC_Head.gc_next store the owning shard index (0..7).
;
; gc_collect_gen uses a 2-phase STW protocol:
;   - STW Phase A: drain all threads' BRC queues, merge gen 0..gen across all
;     8 shards, run reachability (Phases 1-4), promote reachable objects to
;     shard 0's target generation, snapshot unreachable objects (taking a temp
;     +1 ref, unlinking them while preserving GC_PREV_MASK_FINALIZED, and
;     detaching weakrefs via weakref_detach_for), then resume the world.
;   - Unlocked: DECREF deferred BRC dead objects, invoke weakref callbacks,
;     and run PEP 442 finalizers.
;   - STW Phase B (only if any finalizer ran): drain BRC queues, re-check
;     reachability (accounting for our temp +1 ref), promote resurrected
;     objects, resume the world, and drop temp refs on resurrected objects.
;   - Unlocked Phase 5: run tp_clear on remaining unreachable objects, re-track
;     any survivors (refcount > 1) under shard 0's lock, and drop temp +1 refs.

%include "macros.inc"
%include "object.inc"
%include "threadstate.inc"
%include "sync.inc"
%include "gil.inc"

extern ap_malloc
extern ap_free
extern malloc
extern realloc
extern free
extern fatal_error
extern obj_decref
extern obj_dealloc
extern obj_incref
extern obj_get_refcount
extern obj_call_finalizer
extern sys_write
extern list_append
extern exc_fetch
extern async_gen_type
extern gen_type
extern coro_type
extern gen_gc_finalize
extern weakref_live
extern weakref_detach_for
extern weakref_run_callbacks
extern rt_threaded
extern rt_mutex_lock
extern rt_mutex_unlock
extern rt_mutex_lock_p
extern rt_mutex_unlock_p
extern stw_stop_world
extern stw_start_world
extern brc_drain_all_stw

GC_NSHARDS      equ 8
GC_SHARD_MASK   equ 7
GC_SHARD_STRIDE equ 64
GC_NEXT_MASK    equ ~7

; Offsets within each 64-byte cache-line-padded shard in gc_shards[8]
GCS_GEN0        equ 0           ; 16B PyGC_Head sentinel
GCS_GEN1        equ 16          ; 16B PyGC_Head sentinel
GCS_GEN2        equ 32          ; 16B PyGC_Head sentinel
GCS_LOCK        equ 48          ; 4B futex lock (+ 4B pad)
GCS_COUNT       equ 56          ; 8B gen0 allocation count

;; ============================================================================
;; GC data (DATA)
;; ============================================================================
section .data

; 8 cache-line-padded GC tracking shards.  gc_shards is 64-byte aligned, so
; every sentinel address has low 3 bits == 0; adding +s encodes shard tag s
; in the low 3 bits of gc_next identically to bitwise OR.
align 64
gc_shards:
%assign _s 0
%rep GC_NSHARDS
    ; gen0 sentinel
    dq gc_shards + _s * GC_SHARD_STRIDE + GCS_GEN0 + _s
    dq gc_shards + _s * GC_SHARD_STRIDE + GCS_GEN0
    ; gen1 sentinel
    dq gc_shards + _s * GC_SHARD_STRIDE + GCS_GEN1 + _s
    dq gc_shards + _s * GC_SHARD_STRIDE + GCS_GEN1
    ; gen2 sentinel
    dq gc_shards + _s * GC_SHARD_STRIDE + GCS_GEN2 + _s
    dq gc_shards + _s * GC_SHARD_STRIDE + GCS_GEN2
    ; futex lock + pad + gen0_count
    dd 0
    dd 0
    dq 0
%assign _s _s + 1
%endrep

align 8
global gc_gen0_threshold
gc_gen0_threshold: dq 700
global gc_gen1_threshold
gc_gen1_threshold: dq 10
global gc_gen1_collections
gc_gen1_collections: dq 0
global gc_gen2_threshold
gc_gen2_threshold: dq 10
global gc_gen2_collections
gc_gen2_collections: dq 0

; GC state
global gc_enabled
gc_enabled:     dq 1

; The gc.set_debug() flags, and the gc.garbage list the SAVEALL one needs.
global gc_debug
gc_debug:       dq 0
global gc_garbage_list
gc_garbage_list: dq 0
; Three counters per generation -- collections, collected, uncollectable --
; which is what gc.get_stats() answers with.
global gc_stat_counters
gc_stat_counters: times 9 dq 0

global gc_collecting        ; reentrancy + mutual-exclusion guard for collection
gc_collecting:  dq 0
global gc_pending_threads   ; count of threads with ThreadState.ts_gc_pending == 1
gc_pending_threads: dd 0
                dd 0

gc_reachable_sentinel: dq 0 ; set by gc_collect_gen before phase 4 / res4

section .text

;; ============================================================================
;; gc_get_gen0_count() -> rax = total gen0 count across all 8 shards
;; ============================================================================
global gc_get_gen0_count
DEF_FUNC_BARE gc_get_gen0_count
    lea rcx, [rel gc_shards]
    xor eax, eax
    xor edx, edx
.ggc_loop:
    add rax, [rcx + GCS_COUNT]
    add rcx, GC_SHARD_STRIDE
    inc edx
    cmp edx, GC_NSHARDS
    jb .ggc_loop
    ret
END_FUNC gc_get_gen0_count

;; ============================================================================
;; gc_reset_after_fork() -> nothing
;; Zero all 8 shard futex locks and gc_collecting in a forked child.
;; ============================================================================
global gc_reset_after_fork
DEF_FUNC_BARE gc_reset_after_fork
    lea rcx, [rel gc_shards]
    xor edx, edx
.graf_loop:
    mov dword [rcx + GCS_LOCK], 0
    add rcx, GC_SHARD_STRIDE
    inc edx
    cmp edx, GC_NSHARDS
    jb .graf_loop
    mov qword [rel gc_collecting], 0
    mov dword [rel gc_pending_threads], 0
    mov byte [gs:ThreadState.ts_gc_pending], 0
    ret
END_FUNC gc_reset_after_fork

;; ============================================================================
;; gc_list_append_shard(rdi=node, rsi=list_sentinel, rdx=shard_tag) -> nothing
;; Insert node at the tail of list (before sentinel), tagging gc_next with
;; shard_tag (0..7).
;; ============================================================================
DEF_FUNC_BARE gc_list_append_shard
    ; node->gc_next = sentinel | shard_tag
    mov rax, rsi
    or rax, rdx
    mov [rdi + PyGC_Head.gc_next], rax
    ; old_tail = sentinel->gc_prev & GC_PREV_MASK
    mov rax, [rsi + PyGC_Head.gc_prev]
    and rax, GC_PREV_MASK
    mov [rdi + PyGC_Head.gc_prev], rax
    ; old_tail->gc_next = node | shard_tag
    mov rcx, rdi
    or rcx, rdx
    mov [rax + PyGC_Head.gc_next], rcx
    ; sentinel->gc_prev = node
    mov [rsi + PyGC_Head.gc_prev], rdi
    ret
END_FUNC gc_list_append_shard

;; ============================================================================
;; gc_list_append(rdi=node, rsi=list_sentinel)
;; Insert node at the tail of a tag-0 list (STW young/unreach or shard 0).
;; ============================================================================
DEF_FUNC_BARE gc_list_append
    mov [rdi + PyGC_Head.gc_next], rsi
    mov rax, [rsi + PyGC_Head.gc_prev]
    and rax, GC_PREV_MASK
    mov [rdi + PyGC_Head.gc_prev], rax
    mov [rax + PyGC_Head.gc_next], rdi
    mov [rsi + PyGC_Head.gc_prev], rdi
    ret
END_FUNC gc_list_append

;; ============================================================================
;; gc_list_remove(rdi=node)
;; Remove node from its doubly-linked list, preserving any shard tag in the
;; low 3 bits of gc_next and state bits in the low 2 bits of next->gc_prev.
;; ============================================================================
DEF_FUNC_BARE gc_list_remove
    mov rax, [rdi + PyGC_Head.gc_prev]
    and rax, GC_PREV_MASK          ; prev ptr (clear state bits)
    mov rcx, [rdi + PyGC_Head.gc_next]  ; tagged next ptr
    ; prev->gc_next = node->gc_next (preserves shard tag)
    mov [rax + PyGC_Head.gc_next], rcx
    and rcx, GC_NEXT_MASK          ; untagged next ptr
    ; next->gc_prev = prev | (next->gc_prev & ~GC_PREV_MASK)
    mov rdx, [rcx + PyGC_Head.gc_prev]
    and rdx, ~GC_PREV_MASK
    or rax, rdx
    mov [rcx + PyGC_Head.gc_prev], rax
    ret
END_FUNC gc_list_remove

;; ============================================================================
;; gc_list_merge_from_shard(rdi=from_sentinel, rsi=to_sentinel, rdx=from_tag) -> nothing
;; Move all nodes from 'from' list to end of tag-0 'to' list and reset 'from'
;; to empty with its shard tag.  Preserves from_head's GC_PREV_MASK_FINALIZED.
;; NOTE: interior nodes keep their shard tag in gc_next until Phase 1 strips
;; them (or if from_tag == 0, they are already tag-0).
;; ============================================================================
DEF_FUNC_BARE gc_list_merge_from_shard
    mov rax, [rdi + PyGC_Head.gc_next]
    and rax, GC_NEXT_MASK          ; from_head (untagged)
    cmp rax, rdi
    je .empty

    mov r8, [rdi + PyGC_Head.gc_prev]
    and r8, GC_PREV_MASK           ; r8 = from_tail
    mov r9, [rsi + PyGC_Head.gc_prev]
    and r9, GC_PREV_MASK           ; r9 = to_tail

    ; to_tail->gc_next = from_head (tag 0)
    mov [r9 + PyGC_Head.gc_next], rax
    ; from_head->gc_prev = to_tail | (from_head->gc_prev & GC_PREV_MASK_FINALIZED)
    mov r10, [rax + PyGC_Head.gc_prev]
    and r10, GC_PREV_MASK_FINALIZED
    or r9, r10
    mov [rax + PyGC_Head.gc_prev], r9
    ; from_tail->gc_next = to_sentinel (tag 0)
    mov [r8 + PyGC_Head.gc_next], rsi
    ; to_sentinel->gc_prev = from_tail
    mov [rsi + PyGC_Head.gc_prev], r8

    ; Empty 'from' sentinel with its shard tag restored
    mov rax, rdi
    or rax, rdx
    mov [rdi + PyGC_Head.gc_next], rax
    mov [rdi + PyGC_Head.gc_prev], rdi
.empty:
    ret
END_FUNC gc_list_merge_from_shard

;; ============================================================================
;; gc_alloc(rdi=size, rsi=type) -> PyObject*
;; Allocate a GC-tracked object. Prepends PyGC_Head, returns obj pointer.
;; ============================================================================
DEF_FUNC gc_alloc
    push rbx
    push r12

    mov rbx, rdi               ; size
    mov r12, rsi               ; type

    lea rdi, [rbx + GC_HEAD_SIZE]
    call ap_malloc

    mov qword [rax + PyGC_Head.gc_next], 0
    mov qword [rax + PyGC_Head.gc_prev], 0

    lea rbx, [rax + GC_HEAD_SIZE]

    INIT_OBJ_RC rbx
    mov [rbx + PyObject.ob_type], r12

    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret
END_FUNC gc_alloc

;; ============================================================================
;; gc_track(rdi=obj) -> nothing
;; Add object to current thread's shard gen0 tracking list. May trigger GC.
;; Fast bare leaf path when rt_threaded == 0 (no frame, no callee-saved pushes,
;; no nested call; shard 1 is fixed for single-threaded main, except post-fork
;; where ts_tid may differ — still read ts_tid into edx once without frame).
;; ============================================================================
DEF_FUNC_BARE gc_track
    lea rax, [rdi - GC_HEAD_SIZE]
    cmp byte [rel rt_threaded], 0
    jne .gt_threaded

    cmp qword [rax + PyGC_Head.gc_next], 0
    jne .gt_fast_ret

    mov ecx, [gs:ThreadState.ts_tid]
    and ecx, GC_SHARD_MASK
    mov edx, ecx
    shl edx, 6
    lea rsi, [rel gc_shards]
    add rsi, rdx                        ; rsi = &gc_shards[s] (gen0 sentinel)

    ; Inline gc_list_append_shard(node=rax, sentinel=rsi, tag=rcx)
    mov r8, rsi
    or r8, rcx
    mov [rax + PyGC_Head.gc_next], r8   ; node->gc_next = sentinel | s
    mov r9, [rsi + PyGC_Head.gc_prev]
    and r9, GC_PREV_MASK                ; r9 = old_tail
    mov [rax + PyGC_Head.gc_prev], r9   ; node->gc_prev = old_tail
    mov r8, rax
    or r8, rcx
    mov [r9 + PyGC_Head.gc_next], r8    ; old_tail->gc_next = node | s
    mov [rsi + PyGC_Head.gc_prev], rax  ; sentinel->gc_prev = node

    mov rax, [rsi + GCS_COUNT]
    inc rax
    mov [rsi + GCS_COUNT], rax
    cmp rax, [rel gc_gen0_threshold]
    jg .gt_fast_trigger
.gt_fast_ret:
    xor edx, edx                        ; preserve TAG_PTR(0) expectation
    ret

.gt_fast_trigger:
    cmp qword [rel gc_enabled], 0
    je .gt_fast_ret
    cmp qword [rel gc_collecting], 0
    jne .gt_fast_ret
    push rbp
    mov rbp, rsp
    xor edi, edi
    call gc_collect_gen
    xor edx, edx
    leave
    ret

.gt_threaded:
    push rbp
    mov rbp, rsp
    sub rsp, 8                          ; + 3 pushes = 32, 16-aligned
    push rbx
    push r12
    push r13

    mov rbx, rax
    mov r13d, [gs:ThreadState.ts_tid]
    and r13d, GC_SHARD_MASK
    mov eax, r13d
    shl eax, 6
    lea r12, [rel gc_shards]
    add r12, rax

    lea rdi, [r12 + GCS_LOCK]
    call rt_mutex_lock

    cmp qword [rbx + PyGC_Head.gc_next], 0
    jne .gt_unlock_already

    mov rdi, rbx
    lea rsi, [r12 + GCS_GEN0]
    mov rdx, r13
    call gc_list_append_shard

    inc qword [r12 + GCS_COUNT]
    mov rbx, [r12 + GCS_COUNT]

    lea rdi, [r12 + GCS_LOCK]
    call rt_mutex_unlock

    ; Trigger when this shard exceeds threshold, or every 64th alloc check sum.
    mov rax, rbx
    cmp rax, [rel gc_gen0_threshold]
    jg .gt_maybe_collect
    test eax, 63
    jnz .gt_done
    call gc_get_gen0_count
    cmp rax, [rel gc_gen0_threshold]
    jle .gt_done

.gt_maybe_collect:
    cmp qword [rel gc_enabled], 0
    je .gt_done
    cmp qword [rel gc_collecting], 0
    jne .gt_done
    cmp byte [gs:ThreadState.ts_gc_pending], 0
    jne .gt_done

    ; Never run stw_stop_world() synchronously from gc_track() while threaded:
    ; the caller may hold a leaf OBJ_LOCK (e.g. list_copy, list_slice), which
    ; would ABBA-deadlock with an attached thread waiting on that same lock.
    ; Defer auto-GC to THIS thread's next VM safepoint (ts_gc_pending) so
    ; peer threads returning from lock.acquire() never steal our GC trigger.
    mov byte [gs:ThreadState.ts_gc_pending], 1
    lock inc dword [rel gc_pending_threads]
    extern eval_breaker
    lock or qword [rel eval_breaker], EB_GC_COLLECT
    jmp .gt_done

.gt_unlock_already:
    lea rdi, [r12 + GCS_LOCK]
    call rt_mutex_unlock

.gt_done:
    xor edx, edx                ; preserve TAG_PTR(0) expectation of callers
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC gc_track

;; ============================================================================
;; gc_untrack(rdi=obj) -> nothing
;; Remove object from its GC tracking shard list.
;; Fast bare leaf path when rt_threaded == 0 (no frame, no pushes, no calls).
;; ============================================================================
DEF_FUNC_BARE gc_untrack
    lea rdi, [rdi - GC_HEAD_SIZE]
    mov rcx, [rdi + PyGC_Head.gc_next]
    test rcx, rcx
    jz .gu_fast_ret

    cmp byte [rel rt_threaded], 0
    jne .gu_threaded

    ; Inline gc_list_remove(rdi)
    mov rax, [rdi + PyGC_Head.gc_prev]
    and rax, GC_PREV_MASK               ; prev ptr
    mov [rax + PyGC_Head.gc_next], rcx  ; prev->gc_next = tagged next
    mov r8, rcx
    and r8, GC_NEXT_MASK                ; untagged next ptr
    mov rdx, [r8 + PyGC_Head.gc_prev]
    and rdx, ~GC_PREV_MASK
    or rax, rdx
    mov [r8 + PyGC_Head.gc_prev], rax
    mov qword [rdi + PyGC_Head.gc_next], 0
    and qword [rdi + PyGC_Head.gc_prev], GC_PREV_MASK_FINALIZED

    and ecx, GC_SHARD_MASK
    shl ecx, 6
    lea rdx, [rel gc_shards]
    add rdx, rcx
    dec qword [rdx + GCS_COUNT]
    jns .gu_fast_ret
    mov qword [rdx + GCS_COUNT], 0
.gu_fast_ret:
    ret

.gu_threaded:
    push rbp
    mov rbp, rsp
    sub rsp, 8                          ; + 3 pushes = 32, 16-aligned
    push rbx
    push r12
    push r13
    mov rbx, rdi

.gu_retry:
    mov rax, [rbx + PyGC_Head.gc_next]
    test rax, rax
    jz .gu_done

    mov r13d, eax
    and r13d, GC_SHARD_MASK
    mov eax, r13d
    shl eax, 6
    lea r12, [rel gc_shards]
    add r12, rax

    lea rdi, [r12 + GCS_LOCK]
    call rt_mutex_lock

    ; Re-verify node is still tracked in this same shard (STW GC may have moved it)
    mov rax, [rbx + PyGC_Head.gc_next]
    test rax, rax
    jz .gu_unlock_done
    mov ecx, eax
    and ecx, GC_SHARD_MASK
    cmp ecx, r13d
    jne .gu_unlock_retry

    mov rdi, rbx
    call gc_list_remove
    mov qword [rbx + PyGC_Head.gc_next], 0
    and qword [rbx + PyGC_Head.gc_prev], GC_PREV_MASK_FINALIZED

    dec qword [r12 + GCS_COUNT]
    jns .gu_unlock_done
    mov qword [r12 + GCS_COUNT], 0

.gu_unlock_done:
    lea rdi, [r12 + GCS_LOCK]
    call rt_mutex_unlock
    jmp .gu_done

.gu_unlock_retry:
    lea rdi, [r12 + GCS_LOCK]
    call rt_mutex_unlock
    jmp .gu_retry

.gu_done:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC gc_untrack

;; ============================================================================
;; gc_dealloc(rdi=obj)
;; Untrack and free a potentially GC-tracked object.
;; ============================================================================
DEF_FUNC gc_dealloc, 8            ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, rdi

    mov rax, [rbx + PyObject.ob_type]
    test rax, rax
    jz .plain_free
    mov rax, [rax + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_HAVE_GC
    jz .plain_free

    lea rdi, [rbx - GC_HEAD_SIZE]
    cmp qword [rdi + PyGC_Head.gc_next], 0
    je .gc_free

    mov rdi, rbx
    call gc_untrack

.gc_free:
    lea rdi, [rbx - GC_HEAD_SIZE]
    call ap_free
    jmp .done

.plain_free:
    mov rdi, rbx
    call ap_free

.done:
    pop rbx
    leave
    ret
END_FUNC gc_dealloc

;; ============================================================================
;; gc_walk_generation(rdi = generation 0..2, rsi = list)
;; Appends every object tracked in that generation across all 8 shards to list.
;; Snapshots under STW into a temporary libc buffer with INCREF'd pointers,
;; then appends and DECREFs outside STW.
;; ============================================================================
GWG_GEN   equ 8
GWG_LIST  equ 16
GWG_BUF   equ 24
GWG_CNT   equ 32
GWG_FRAME equ 40            ; + 5 pushes = 80, 16-aligned

global gc_walk_generation
DEF_FUNC gc_walk_generation, GWG_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov [rbp - GWG_GEN], rdi
    mov [rbp - GWG_LIST], rsi
    mov qword [rbp - GWG_BUF], 0
    mov qword [rbp - GWG_CNT], 0

    call stw_stop_world

    ; Pass 1: count tracked objects in generation across all 8 shards
    xor r14d, r14d                      ; total count
    mov r15, [rbp - GWG_GEN]
    shl r15, 4                          ; gen * 16
    xor r13d, r13d                      ; shard s = 0..7
.gwg_cnt_shard:
    mov eax, r13d
    shl eax, 6
    lea r12, [rel gc_shards]
    add r12, rax
    add r12, r15                        ; r12 = &gc_shards[s].gen[gen]
    mov rbx, [r12 + PyGC_Head.gc_next]
    and rbx, GC_NEXT_MASK
.gwg_cnt_loop:
    cmp rbx, r12
    je .gwg_cnt_next_shard
    lea rax, [rbx + GC_HEAD_SIZE]
    cmp rax, [rbp - GWG_LIST]
    je .gwg_cnt_step
    inc r14
.gwg_cnt_step:
    mov rbx, [rbx + PyGC_Head.gc_next]
    and rbx, GC_NEXT_MASK
    jmp .gwg_cnt_loop
.gwg_cnt_next_shard:
    inc r13d
    cmp r13d, GC_NSHARDS
    jb .gwg_cnt_shard

    test r14, r14
    jz .gwg_resume_empty

    ; Allocate temporary snapshot array via libc malloc
    mov [rbp - GWG_CNT], r14
    lea rdi, [r14 * 8]
    call malloc wrt ..plt
    test rax, rax
    jz .gwg_oom
    mov [rbp - GWG_BUF], rax

    ; Pass 2: snapshot + INCREF every object in generation across all 8 shards
    xor r14d, r14d                      ; index
    xor r13d, r13d                      ; shard s = 0..7
.gwg_cap_shard:
    mov eax, r13d
    shl eax, 6
    lea r12, [rel gc_shards]
    add r12, rax
    add r12, r15
    mov rbx, [r12 + PyGC_Head.gc_next]
    and rbx, GC_NEXT_MASK
.gwg_cap_loop:
    cmp rbx, r12
    je .gwg_cap_next_shard
    lea rax, [rbx + GC_HEAD_SIZE]
    cmp rax, [rbp - GWG_LIST]
    je .gwg_cap_step
    INCREF rax
    mov rcx, [rbp - GWG_BUF]
    mov [rcx + r14 * 8], rax
    inc r14
.gwg_cap_step:
    mov rbx, [rbx + PyGC_Head.gc_next]
    and rbx, GC_NEXT_MASK
    jmp .gwg_cap_loop
.gwg_cap_next_shard:
    inc r13d
    cmp r13d, GC_NSHARDS
    jb .gwg_cap_shard

    call stw_start_world

    ; Append all snapshotted objects outside STW, then drop our temp ref
    mov r12, [rbp - GWG_BUF]
    mov r13, [rbp - GWG_CNT]
    xor r14d, r14d
.gwg_app_loop:
    cmp r14, r13
    jae .gwg_free
    mov rbx, [r12 + r14 * 8]
    mov rdi, [rbp - GWG_LIST]
    mov rsi, rbx
    call list_append          ; err: gc.get_objects built this list for the walk
    mov rdi, rbx
    call obj_decref
    inc r14
    jmp .gwg_app_loop

.gwg_free:
    mov rdi, r12
    call free wrt ..plt
    jmp .gwg_done

.gwg_resume_empty:
    call stw_start_world

.gwg_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.gwg_oom:
    call stw_start_world
    CSTRING rdi, "out of memory in gc_walk_generation"
    call fatal_error
END_FUNC gc_walk_generation

;; ============================================================================
;; gc_retrack_survivor(rdi = obj, esi = target_gen 0..2) -> nothing
;; Re-insert a surviving unreachable object into shard 0's target generation
;; under shard 0's lock, preserving GC_PREV_MASK_FINALIZED.
;; ============================================================================
DEF_FUNC_LOCAL gc_retrack_survivor      ; + 4 pushes = 32, 16-aligned
    push rbx
    push r12
    push r13
    push r14

    lea rbx, [rdi - GC_HEAD_SIZE]
    mov r13d, esi
    shl r13d, 4
    lea r12, [rel gc_shards]            ; shard 0

    cmp byte [rel rt_threaded], 0
    je .grs_nolock
    lea rdi, [r12 + GCS_LOCK]
    call rt_mutex_lock
.grs_nolock:
    cmp qword [rbx + PyGC_Head.gc_next], 0
    jne .grs_unlock
    mov r14, [rbx + PyGC_Head.gc_prev]
    and r14, GC_PREV_MASK_FINALIZED
    mov rdi, rbx
    lea rsi, [r12 + r13]
    call gc_list_append
    or [rbx + PyGC_Head.gc_prev], r14
.grs_unlock:
    cmp byte [rel rt_threaded], 0
    je .grs_done
    lea rdi, [r12 + GCS_LOCK]
    call rt_mutex_unlock
.grs_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC gc_retrack_survivor

;; ============================================================================
;; gc_drain_obj_buf(rdi = PyObject** buf, rsi = count) -> nothing
;; DECREF every object in a libc-malloc'd array and free the array.
;; ============================================================================
DEF_FUNC_LOCAL gc_drain_obj_buf, 8      ; + 3 pushes = 32, 16-aligned
    push rbx
    push r12
    push r13
    test rdi, rdi
    jz .gdb_done
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
.gdb_loop:
    cmp r13, r12
    jae .gdb_free
    mov rdi, [rbx + r13 * 8]
    call obj_decref
    inc r13
    jmp .gdb_loop
.gdb_free:
    mov rdi, rbx
    call free wrt ..plt
.gdb_done:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC gc_drain_obj_buf

;; ============================================================================
;; The gc.set_debug() reporting.  Goes to stderr via sys_write without
;; allocating or calling into Python.
;; ============================================================================

;; gcd_puts(rdi = NUL-terminated string)
DEF_FUNC_LOCAL gcd_puts, 8                          ; + 1 push = 16
    push rbx
    mov rbx, rdi
    xor ecx, ecx
.gcp_len:
    cmp byte [rbx + rcx], 0
    je .gcp_write
    inc rcx
    jmp .gcp_len
.gcp_write:
    mov edi, 2
    mov rsi, rbx
    mov rdx, rcx
    call sys_write
    pop rbx
    leave
    ret
END_FUNC gcd_puts

;; gcd_putu(rdi = unsigned) -- decimal, right-to-left into the frame
GCU_END   equ 8
GCU_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC_LOCAL gcd_putu, GCU_FRAME
    mov rax, rdi
    lea rcx, [rbp - GCU_END]
    mov r8d, 10
.gcu_loop:
    xor edx, edx
    div r8
    dec rcx
    add dl, '0'
    mov [rcx], dl
    test rax, rax
    jnz .gcu_loop
    lea rdx, [rbp - GCU_END]
    sub rdx, rcx
    mov rsi, rcx
    mov edi, 2
    call sys_write
    leave
    ret
END_FUNC gcd_putu

;; gcd_putp(rdi = pointer) -- "0x" and lowercase hex
GCP_END   equ 8
GCP_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC_LOCAL gcd_putp, GCP_FRAME
    mov rax, rdi
    lea rcx, [rbp - GCP_END]
.gcx_loop:
    mov rdx, rax
    and edx, 15
    cmp dl, 10
    jb .gcx_digit
    add dl, 'a' - 10 - '0'
.gcx_digit:
    add dl, '0'
    dec rcx
    mov [rcx], dl
    shr rax, 4
    jnz .gcx_loop
    push rcx
    sub rsp, 8
    lea rdi, [rel gcd_s_0x]
    call gcd_puts
    add rsp, 8
    pop rcx
    lea rdx, [rbp - GCP_END]
    sub rdx, rcx
    mov rsi, rcx
    mov edi, 2
    call sys_write
    leave
    ret
END_FUNC gcd_putp

;; gcd_report(rdi = obj, rsi = "collectable" or "unreachable" cstr)
DEF_FUNC_LOCAL gcd_report, 16                        ; + 2 pushes = 32
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rel gcd_s_gc]
    call gcd_puts
    mov rdi, r12
    call gcd_puts
    lea rdi, [rel gcd_s_lt]
    call gcd_puts
    mov rdi, [rbx + PyObject.ob_type]
    mov rdi, [rdi + PyTypeObject.tp_name]
    call gcd_puts
    lea rdi, [rel gcd_s_sp]
    call gcd_puts
    mov rdi, rbx
    call gcd_putp
    lea rdi, [rel gcd_s_gtnl]
    call gcd_puts
    pop r12
    pop rbx
    leave
    ret
END_FUNC gcd_report

section .rodata
gcd_s_0x:     db "0x", 0
gcd_s_gc:     db "gc: ", 0
gcd_s_lt:     db " <", 0
gcd_s_sp:     db " ", 0
gcd_s_gtnl:   db ">", 10, 0
gcd_s_coll:   db "collectable", 0
gcd_s_start:  db "gc: collecting generation ", 0
gcd_s_dots:   db "...", 10, 0
gcd_s_done:   db "gc: done, ", 0
gcd_s_unre:   db " unreachable, 0 uncollectable", 10, 0
section .text

;; ============================================================================
;; gc_collect_gen(edi=generation) -> rax = unreachable objects cleared
;; Core 2-phase STW cycle collection algorithm.
;; ============================================================================
GCG_GEN     equ 8
GCG_TGEN    equ 16
GCG_YOUNG   equ 32    ; 16-byte PyGC_Head sentinel on stack
GCG_UNREACH equ 48    ; 16-byte PyGC_Head sentinel on stack
GCG_RANFIN  equ 56    ; did any finalizer actually run this pass?
GCG_FOUND   equ 64    ; unreachable object count
GCG_UNR_BUF equ 72    ; PyObject** of unreachable objects (temp +1 ref each)
GCG_UNR_LEN equ 80    ; count of unreachable objects
GCG_WR_BUF  equ 88    ; WC_LIST* array of detached weakref callbacks
GCG_WR_LEN  equ 96
GCG_WR_CAP  equ 104
GCG_BRC_BUF equ 112   ; PyObject** deferred BRC dead objects from STW
GCG_BRC_LEN equ 120
GCG_RES_BUF equ 128   ; PyObject** resurrected objects from Phase B
GCG_RES_LEN equ 136
GCG_FRAME   equ 152   ; + 5 pushes (40) = 192, 16-aligned

global gc_collect_gen
DEF_FUNC gc_collect_gen, GCG_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; Atomically claim gc_collecting (0 -> 1).  Reentrant calls from finalizers
    ; or concurrent callers return 0 immediately, matching CPython.
    xor eax, eax
    mov ecx, 1
    lock cmpxchg [rel gc_collecting], rcx
    jne .already_collecting

    mov [rbp - GCG_GEN], edi
    mov eax, edi
    cmp eax, 2
    jge .tgen_2
    inc eax
    jmp .tgen_set
.tgen_2:
    mov eax, 2
.tgen_set:
    mov [rbp - GCG_TGEN], eax

    mov qword [rbp - GCG_FOUND], 0
    mov qword [rbp - GCG_RANFIN], 0
    mov qword [rbp - GCG_UNR_BUF], 0
    mov qword [rbp - GCG_UNR_LEN], 0
    mov qword [rbp - GCG_WR_BUF], 0
    mov qword [rbp - GCG_WR_LEN], 0
    mov qword [rbp - GCG_WR_CAP], 0
    mov qword [rbp - GCG_BRC_BUF], 0
    mov qword [rbp - GCG_BRC_LEN], 0
    mov qword [rbp - GCG_RES_BUF], 0
    mov qword [rbp - GCG_RES_LEN], 0

    mov [gs:ThreadState.gc_collect_rsp], rsp

    test qword [rel gc_debug], GC_DEBUG_STATS
    jz .no_stats_start
    lea rdi, [rel gcd_s_start]
    call gcd_puts
    mov edi, [rbp - GCG_GEN]
    call gcd_putu
    lea rdi, [rel gcd_s_dots]
    call gcd_puts
.no_stats_start:

    ;; ========================================================================
    ;; STW PHASE A: exact reachability, promote survivors, snapshot unreachable
    ;; ========================================================================
    call stw_stop_world

    call brc_drain_all_stw
    mov [rbp - GCG_BRC_BUF], rax
    mov [rbp - GCG_BRC_LEN], rdx

    ; Initialize young and unreachable sentinels on stack (tag 0)
    lea r12, [rbp - GCG_YOUNG]
    mov [r12 + PyGC_Head.gc_next], r12
    mov [r12 + PyGC_Head.gc_prev], r12
    lea r15, [rbp - GCG_UNREACH]
    mov [r15 + PyGC_Head.gc_next], r15
    mov [r15 + PyGC_Head.gc_prev], r15

    ; Merge gen 0..gen across all 8 shards into GCG_YOUNG, and zero gen0 counts
    xor r13d, r13d                      ; g = 0..gen
.merge_gen_loop:
    cmp r13d, [rbp - GCG_GEN]
    jg .merge_done
    mov r14d, r13d
    shl r14d, 4                         ; g * 16
    xor ebx, ebx                        ; shard s = 0..7
.merge_shard_loop:
    mov eax, ebx
    shl eax, 6
    lea rdi, [rel gc_shards]
    add rdi, rax
    test r13d, r13d
    jnz .merge_no_zero_cnt
    mov qword [rdi + GCS_COUNT], 0
.merge_no_zero_cnt:
    add rdi, r14                        ; &gc_shards[s].gen[g]
    mov rsi, r12                        ; &GCG_YOUNG
    mov rdx, rbx                        ; shard tag s
    call gc_list_merge_from_shard
    inc ebx
    cmp ebx, GC_NSHARDS
    jb .merge_shard_loop
    inc r13d
    jmp .merge_gen_loop
.merge_done:

    ; ---- Phase 1: Strip shard tags & set gc_refs = ob_refcnt in GCG_YOUNG ----
    mov rbx, [r12 + PyGC_Head.gc_next]
.phase1_loop:
    cmp rbx, r12
    je .phase1_done

    ; Strip low 3 shard-tag bits from gc_next so all STW lists are tag-0
    mov rax, [rbx + PyGC_Head.gc_next]
    and rax, GC_NEXT_MASK
    mov [rbx + PyGC_Head.gc_next], rax
    mov r13, rax                        ; save next

    lea rdi, [rbx + GC_HEAD_SIZE]
    call obj_get_refcount
    mov rcx, rax

    shl rcx, GC_PREV_SHIFT
    or rcx, GC_PREV_MASK_COLLECTING
    mov rdx, [rbx + PyGC_Head.gc_prev]
    and rdx, GC_PREV_MASK_FINALIZED
    or rcx, rdx
    mov [rbx + PyGC_Head.gc_prev], rcx

    mov rbx, r13
    jmp .phase1_loop
.phase1_done:

    ; ---- Phase 2: Traverse all objects, decrement gc_refs of targets ----
    mov rbx, [r12 + PyGC_Head.gc_next]
.phase2_loop:
    cmp rbx, r12
    je .phase2_done

    lea r13, [rbx + GC_HEAD_SIZE]
    mov rax, [r13 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_traverse]
    test rax, rax
    jz .phase2_next

    push rbx
    push rbx                            ; keep rsp 16-aligned
    mov rdi, r13
    lea r14, [rel gc_visit_decref]
    call rax
    pop rbx
    pop rbx

.phase2_next:
    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .phase2_loop
.phase2_done:

    ; ---- Phase 3: Partition into reachable (GCG_YOUNG) vs unreachable ----
    mov r14, r12                        ; prev (starts at young sentinel)
    mov rbx, [r12 + PyGC_Head.gc_next]
.phase3_loop:
    cmp rbx, r12
    je .phase3_done

    mov r13, [rbx + PyGC_Head.gc_next]

    mov rax, [rbx + PyGC_Head.gc_prev]
    mov rdx, rax
    and rdx, GC_PREV_MASK_FINALIZED
    shr rax, GC_PREV_SHIFT
    test rax, rax
    jnz .phase3_keep

    mov [r14 + PyGC_Head.gc_next], r13

    mov rdi, rbx
    mov rsi, r15
    call gc_list_append

    mov rax, [rbx + PyGC_Head.gc_prev]
    or rax, GC_PREV_MASK_COLLECTING
    or rax, rdx
    mov [rbx + PyGC_Head.gc_prev], rax
    jmp .phase3_next

.phase3_keep:
    mov rax, r14
    or rax, rdx
    mov [rbx + PyGC_Head.gc_prev], rax
    mov r14, rbx

.phase3_next:
    mov rbx, r13
    jmp .phase3_loop
.phase3_done:
    mov [r12 + PyGC_Head.gc_prev], r14

    ; ---- Phase 4: Traverse reachable roots, rescue transitively reachable ----
    mov [rel gc_reachable_sentinel], r12
    mov rbx, [r12 + PyGC_Head.gc_next]
.phase4_loop:
    cmp rbx, r12
    je .phase4_done

    lea r13, [rbx + GC_HEAD_SIZE]
    mov rax, [r13 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_traverse]
    test rax, rax
    jz .phase4_next

    push rbx
    push rbx
    mov rdi, r13
    lea r14, [rel gc_visit_reachable]
    call rax
    pop rbx
    pop rbx

.phase4_next:
    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .phase4_loop
.phase4_done:

    ; Promote reachable GCG_YOUNG immediately into shard 0's target generation
    mov eax, [rbp - GCG_TGEN]
    shl eax, 4
    lea rsi, [rel gc_shards]
    add rsi, rax                        ; &gc_shards[0].gen[target_gen]
    mov rdi, r12                        ; &GCG_YOUNG
    xor edx, edx                        ; tag 0
    call gc_list_merge_from_shard

    ; Snapshot GCG_UNREACH into unreach_arr, taking temp +1 ref, unlinking
    ; (preserving GC_PREV_MASK_FINALIZED), and detaching weakrefs inside STW.
    xor r13d, r13d                      ; count
    mov rbx, [r15 + PyGC_Head.gc_next]
.snap_cnt:
    cmp rbx, r15
    je .snap_cnt_done
    inc r13
    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .snap_cnt
.snap_cnt_done:
    test r13, r13
    jz .stw_a_done

    mov [rbp - GCG_UNR_LEN], r13
    lea rdi, [r13 * 8]
    call malloc wrt ..plt
    test rax, rax
    jz .stw_a_oom
    mov [rbp - GCG_UNR_BUF], rax

    xor r14d, r14d                      ; index
    mov rbx, [r15 + PyGC_Head.gc_next]
.snap_loop:
    cmp rbx, r15
    je .snap_done
    mov r13, [rbx + PyGC_Head.gc_next]

    ; Unlink node while preserving GC_PREV_MASK_FINALIZED for obj_dealloc
    mov qword [rbx + PyGC_Head.gc_next], 0
    and qword [rbx + PyGC_Head.gc_prev], GC_PREV_MASK_FINALIZED

    lea rdi, [rbx + GC_HEAD_SIZE]       ; obj
    INCREF rdi
    mov rax, [rbp - GCG_UNR_BUF]
    mov [rax + r14 * 8], rdi
    inc r14

    cmp qword [rel weakref_live], 0
    je .snap_next
    call weakref_detach_for
    test rax, rax
    jz .snap_next

    ; Append non-NULL WC_LIST to GCG_WR_BUF
    mov rcx, [rbp - GCG_WR_LEN]
    cmp rcx, [rbp - GCG_WR_CAP]
    jb .wr_push
    mov rdx, [rbp - GCG_WR_CAP]
    test rdx, rdx
    jnz .wr_double
    mov edx, 16
    jmp .wr_grow
.wr_double:
    shl rdx, 1
.wr_grow:
    push rax
    push rdx
    mov rdi, [rbp - GCG_WR_BUF]
    lea rsi, [rdx * 8]
    call realloc wrt ..plt
    pop rdx
    pop rcx                             ; saved WC_LIST
    test rax, rax
    jz .stw_a_oom
    mov [rbp - GCG_WR_BUF], rax
    mov [rbp - GCG_WR_CAP], rdx
    mov rax, rcx
    mov rcx, [rbp - GCG_WR_LEN]
.wr_push:
    mov rdx, [rbp - GCG_WR_BUF]
    mov [rdx + rcx * 8], rax
    inc qword [rbp - GCG_WR_LEN]

.snap_next:
    mov rbx, r13
    jmp .snap_loop
.snap_done:
    mov [r15 + PyGC_Head.gc_next], r15
    mov [r15 + PyGC_Head.gc_prev], r15

.stw_a_done:
    call stw_start_world

    ;; ========================================================================
    ;; UNLOCKED PHASE: BRC deferred frees, weakref callbacks, PEP 442 finalizers
    ;; ========================================================================
    mov rdi, [rbp - GCG_BRC_BUF]
    mov rsi, [rbp - GCG_BRC_LEN]
    call gc_drain_obj_buf
    mov qword [rbp - GCG_BRC_BUF], 0
    mov qword [rbp - GCG_BRC_LEN], 0

    ; Invoke detached weakref callbacks outside STW
    mov r12, [rbp - GCG_WR_BUF]
    test r12, r12
    jz .wr_cb_done
    mov r13, [rbp - GCG_WR_LEN]
    xor r14d, r14d
.wr_cb_loop:
    cmp r14, r13
    jae .wr_cb_free
    mov rdi, [r12 + r14 * 8]
    call weakref_run_callbacks
    inc r14
    jmp .wr_cb_loop
.wr_cb_free:
    mov rdi, r12
    call free wrt ..plt
    mov qword [rbp - GCG_WR_BUF], 0
    mov qword [rbp - GCG_WR_LEN], 0
.wr_cb_done:

    ; Nothing unreachable? Skip finalizers and Phase 5.
    mov r13, [rbp - GCG_UNR_LEN]
    test r13, r13
    jz .phase5_done

    ; ---- Phase 4.5a: Run PEP 442 __del__ and asyncgen finalizers (FIFO) ----
    mov r12, [rbp - GCG_UNR_BUF]
    xor r14d, r14d
.fin_loop:
    cmp r14, r13
    jae .fin_gen_init
    mov rbx, [r12 + r14 * 8]            ; obj
    inc r14

    ; Already finalized in an earlier collection?
    test qword [rbx - GC_HEAD_SIZE + PyGC_Head.gc_prev], GC_PREV_MASK_FINALIZED
    jnz .fin_loop

    mov rax, [rbx + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HAS_DEL
    jnz .fin_call

    ; Check active async generator finalizer
    lea rcx, [rel async_gen_type]
    cmp rax, rcx
    jne .fin_loop
    cmp qword [rbx + PyGenObject.ag_finalizer], 0
    je .fin_loop
    mov rax, [rbx + PyGenObject.gi_frame]
    test rax, rax
    jz .fin_loop
    cmp qword [rax + PyFrame.instr_ptr], 0
    je .fin_loop

.fin_call:
    or qword [rbx - GC_HEAD_SIZE + PyGC_Head.gc_prev], GC_PREV_MASK_FINALIZED
    mov qword [rbp - GCG_RANFIN], 1
    mov rdi, rbx
    call obj_call_finalizer
    jmp .fin_loop

    ; ---- Phase 4.5b: Finalize suspended generators/coroutines (LIFO) ----
    ; Inner generators created inside an outer generator's frame live at higher
    ; indices; closing them in reverse order preserves Python's LIFO unwinding
    ; order even while unreach_arr holds temp +1 refs on all cycle members.
.fin_gen_init:
    mov r14, r13
.fin_gen_loop:
    test r14, r14
    jz .fin_done
    dec r14
    mov rbx, [r12 + r14 * 8]

    test qword [rbx - GC_HEAD_SIZE + PyGC_Head.gc_prev], GC_PREV_MASK_FINALIZED
    jnz .fin_gen_loop

    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel gen_type]
    cmp rax, rcx
    je .fin_is_gen
    lea rcx, [rel coro_type]
    cmp rax, rcx
    jne .fin_gen_loop
.fin_is_gen:
    mov rdx, [rbx + PyGenObject.gi_frame]
    test rdx, rdx
    jz .fin_gen_loop
    cmp qword [rbx + PyGenObject.gi_started], 0
    jne .fin_gen_susp
    lea rcx, [rel coro_type]
    cmp rax, rcx
    jne .fin_gen_loop
    jmp .fin_call_gen
.fin_gen_susp:
    cmp qword [rdx + PyFrame.instr_ptr], 0
    je .fin_gen_loop
.fin_call_gen:
    or qword [rbx - GC_HEAD_SIZE + PyGC_Head.gc_prev], GC_PREV_MASK_FINALIZED
    mov qword [rbp - GCG_RANFIN], 1
    mov rdi, rbx
    call gen_gc_finalize
    jmp .fin_gen_loop
.fin_done:

    ; If no finalizer ran, nothing could have been resurrected.
    cmp qword [rbp - GCG_RANFIN], 0
    je .resurrect_done

    ;; ========================================================================
    ;; STW PHASE B: resurrection recount over unreach_arr (subtract temp +1)
    ;; ========================================================================
    call stw_stop_world

    call brc_drain_all_stw
    mov [rbp - GCG_BRC_BUF], rax
    mov [rbp - GCG_BRC_LEN], rdx

    lea r12, [rbp - GCG_YOUNG]
    mov [r12 + PyGC_Head.gc_next], r12
    mov [r12 + PyGC_Head.gc_prev], r12
    lea r15, [rbp - GCG_UNREACH]
    mov [r15 + PyGC_Head.gc_next], r15
    mov [r15 + PyGC_Head.gc_prev], r15

    ; Re-link unreach_arr into GCG_UNREACH with gc_refs = refcount - 1
    mov r13, [rbp - GCG_UNR_BUF]
    mov r14, [rbp - GCG_UNR_LEN]
    xor ebx, ebx
.res_link_loop:
    cmp rbx, r14
    jae .res_link_done
    mov rdi, [r13 + rbx * 8]            ; obj
    inc rbx
    lea rcx, [rdi - GC_HEAD_SIZE]
    ; Safety: if already re-tracked somehow, unlink first
    cmp qword [rcx + PyGC_Head.gc_next], 0
    je .res_not_tracked
    push rdi
    push rcx
    mov rdi, rcx
    call gc_list_remove
    pop rcx
    pop rdi
.res_not_tracked:
    mov rdx, [rcx + PyGC_Head.gc_prev]
    and rdx, GC_PREV_MASK_FINALIZED
    push rdi
    push rcx
    push rdx
    push rdx                            ; 16-align
    mov rdi, rcx
    mov rsi, r15
    call gc_list_append
    pop rdx
    pop rdx
    pop rcx
    pop rdi
    or [rcx + PyGC_Head.gc_prev], rdx
    jmp .res_link_loop
.res_link_done:

    ; res1: gc_refs = obj_get_refcount(obj) - 1 (account for our temp +1 ref)
    mov rbx, [r15 + PyGC_Head.gc_next]
.res1_loop:
    cmp rbx, r15
    je .res1_done
    lea rdi, [rbx + GC_HEAD_SIZE]
    call obj_get_refcount
    dec rax
    jns .res1_nonneg
    xor eax, eax
.res1_nonneg:
    shl rax, GC_PREV_SHIFT
    or rax, GC_PREV_MASK_COLLECTING
    mov rdx, [rbx + PyGC_Head.gc_prev]
    and rdx, GC_PREV_MASK_FINALIZED
    or rax, rdx
    mov [rbx + PyGC_Head.gc_prev], rax
    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .res1_loop
.res1_done:

    ; res2: traverse unreachable set, decrementing internal references
    mov rbx, [r15 + PyGC_Head.gc_next]
.res2_loop:
    cmp rbx, r15
    je .res2_done
    lea r13, [rbx + GC_HEAD_SIZE]
    mov rax, [r13 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_traverse]
    test rax, rax
    jz .res2_next
    push rbx
    push rbx
    mov rdi, r13
    lea r14, [rel gc_visit_decref]
    call rax
    pop rbx
    pop rbx
.res2_next:
    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .res2_loop
.res2_done:

    ; res3: partition into still-unreachable (r15) vs resurrected (r12)
    mov rbx, [r15 + PyGC_Head.gc_next]
    mov [r15 + PyGC_Head.gc_next], r15
    mov [r15 + PyGC_Head.gc_prev], r15
.res3_loop:
    cmp rbx, r15
    je .res3_done
    mov r13, [rbx + PyGC_Head.gc_next]
    mov r14, [rbx + PyGC_Head.gc_prev]
    mov rax, r14
    shr rax, GC_PREV_SHIFT
    and r14, GC_PREV_MASK_FINALIZED
    test rax, rax
    jnz .res3_alive

    mov rdi, rbx
    mov rsi, r15
    call gc_list_append
    or r14, GC_PREV_MASK_COLLECTING
    or [rbx + PyGC_Head.gc_prev], r14
    jmp .res3_next

.res3_alive:
    mov rdi, rbx
    mov rsi, r12
    call gc_list_append
    or [rbx + PyGC_Head.gc_prev], r14

.res3_next:
    mov rbx, r13
    jmp .res3_loop
.res3_done:

    ; res4: transitive rescue from resurrected roots
    mov [rel gc_reachable_sentinel], r12
    mov rbx, [r12 + PyGC_Head.gc_next]
.res4_loop:
    cmp rbx, r12
    je .res4_done
    lea r13, [rbx + GC_HEAD_SIZE]
    mov rax, [r13 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_traverse]
    test rax, rax
    jz .res4_next
    push rbx
    push rbx
    mov rdi, r13
    lea r14, [rel gc_visit_reachable]
    call rax
    pop rbx
    pop rbx
.res4_next:
    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .res4_loop
.res4_done:

    ; Collect resurrected objects into GCG_RES_BUF so we drop temp +1 after STW
    xor r13d, r13d
    mov rbx, [r12 + PyGC_Head.gc_next]
.res_cnt_loop:
    cmp rbx, r12
    je .res_cnt_done
    inc r13
    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .res_cnt_loop
.res_cnt_done:
    test r13, r13
    jz .res_no_rescued

    mov [rbp - GCG_RES_LEN], r13
    lea rdi, [r13 * 8]
    call malloc wrt ..plt
    test rax, rax
    jz .stw_b_oom
    mov [rbp - GCG_RES_BUF], rax

    xor r14d, r14d
    mov rbx, [r12 + PyGC_Head.gc_next]
.res_cap_loop:
    cmp rbx, r12
    je .res_cap_done
    lea rax, [rbx + GC_HEAD_SIZE]
    mov rcx, [rbp - GCG_RES_BUF]
    mov [rcx + r14 * 8], rax
    inc r14
    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .res_cap_loop
.res_cap_done:

    ; Promote resurrected GCG_YOUNG into shard 0's target generation
    mov eax, [rbp - GCG_TGEN]
    shl eax, 4
    lea rsi, [rel gc_shards]
    add rsi, rax
    mov rdi, r12
    xor edx, edx
    call gc_list_merge_from_shard

.res_no_rescued:
    ; Rebuild unreach_arr in-place from remaining GCG_UNREACH (K <= N)
    xor r14d, r14d
    mov rbx, [r15 + PyGC_Head.gc_next]
.res_unr_loop:
    cmp rbx, r15
    je .res_unr_done
    mov r13, [rbx + PyGC_Head.gc_next]
    mov qword [rbx + PyGC_Head.gc_next], 0
    and qword [rbx + PyGC_Head.gc_prev], GC_PREV_MASK_FINALIZED
    lea rax, [rbx + GC_HEAD_SIZE]
    mov rcx, [rbp - GCG_UNR_BUF]
    mov [rcx + r14 * 8], rax
    inc r14
    mov rbx, r13
    jmp .res_unr_loop
.res_unr_done:
    mov [rbp - GCG_UNR_LEN], r14
    mov [r15 + PyGC_Head.gc_next], r15
    mov [r15 + PyGC_Head.gc_prev], r15

    call stw_start_world

    ; Drop deferred BRC objects and temp +1 refs on resurrected objects unlocked
    mov rdi, [rbp - GCG_BRC_BUF]
    mov rsi, [rbp - GCG_BRC_LEN]
    call gc_drain_obj_buf
    mov qword [rbp - GCG_BRC_BUF], 0
    mov qword [rbp - GCG_BRC_LEN], 0

    mov rdi, [rbp - GCG_RES_BUF]
    mov rsi, [rbp - GCG_RES_LEN]
    call gc_drain_obj_buf
    mov qword [rbp - GCG_RES_BUF], 0
    mov qword [rbp - GCG_RES_LEN], 0

.resurrect_done:

    ; ---- Count remaining unreachable objects & report DEBUG_COLLECTABLE ----
    mov r13, [rbp - GCG_UNR_LEN]
    mov [rbp - GCG_FOUND], r13
    test r13, r13
    jz .phase5_done

    test qword [rel gc_debug], GC_DEBUG_COLLECTABLE
    jz .count_done
    mov r12, [rbp - GCG_UNR_BUF]
    xor r14d, r14d
.report_loop:
    cmp r14, r13
    jae .count_done
    mov rdi, [r12 + r14 * 8]
    lea rsi, [rel gcd_s_coll]
    call gcd_report
    inc r14
    jmp .report_loop
.count_done:

    ; ---- DEBUG_SAVEALL: append unreachable set to gc.garbage and re-track ----
    test qword [rel gc_debug], GC_DEBUG_SAVEALL
    jz .no_saveall
    cmp qword [rel gc_garbage_list], 0
    je .no_saveall

    mov r12, [rbp - GCG_UNR_BUF]
    mov r13, [rbp - GCG_UNR_LEN]
    xor r14d, r14d
.saveall_loop:
    cmp r14, r13
    jae .phase5_done
    mov rbx, [r12 + r14 * 8]
    inc r14

    mov rdi, [rel gc_garbage_list]
    mov rsi, rbx
    call list_append          ; err: cleared just below -- collector cannot fail
    cmp rax, -1
    jne .saveall_kept
    call exc_fetch
    mov rdi, rax
    XDECREF_V rdi, rax
.saveall_kept:
    mov rdi, rbx
    mov esi, [rbp - GCG_TGEN]
    call gc_retrack_survivor
    mov rdi, rbx
    call obj_decref
    jmp .saveall_loop

.no_saveall:

    ; ---- Phase 5: Clear unreachable objects unlocked, then drop temp refs ----
    ; Pass 5a: invoke tp_clear on every unreachable object while temp +1 refs
    ; keep all cycle members alive across peer tp_clear calls.
    mov r12, [rbp - GCG_UNR_BUF]
    mov r13, [rbp - GCG_UNR_LEN]
    xor r14d, r14d
.p5_clear_loop:
    cmp r14, r13
    jae .p5_drop_init
    mov rbx, [r12 + r14 * 8]
    inc r14
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_clear]
    test rax, rax
    jz .p5_clear_loop
    mov rdi, rbx
    call rax
    jmp .p5_clear_loop

    ; Pass 5b: re-track any object that still has refs beyond our temp +1,
    ; then drop our temp +1 ref (freeing normal cleared objects).
.p5_drop_init:
    xor r14d, r14d
.p5_drop_loop:
    cmp r14, r13
    jae .phase5_done
    mov rbx, [r12 + r14 * 8]
    inc r14
    mov rdi, rbx
    call obj_get_refcount
    cmp rax, 1
    jle .p5_do_decref
    mov rdi, rbx
    mov esi, [rbp - GCG_TGEN]
    call gc_retrack_survivor
.p5_do_decref:
    mov rdi, rbx
    call obj_decref
    jmp .p5_drop_loop

.phase5_done:
    mov rdi, [rbp - GCG_UNR_BUF]
    test rdi, rdi
    jz .no_free_unr
    call free wrt ..plt
    mov qword [rbp - GCG_UNR_BUF], 0
.no_free_unr:

    test qword [rel gc_debug], GC_DEBUG_STATS
    jz .no_stats_done
    lea rdi, [rel gcd_s_done]
    call gcd_puts
    mov rdi, [rbp - GCG_FOUND]
    call gcd_putu
    lea rdi, [rel gcd_s_unre]
    call gcd_puts
.no_stats_done:

    ; Record stats, reset gen0 allocation counters, and release gc_collecting
    ; BEFORE cascading to gen1/gen2.  Resetting GCS_COUNT here (at the end of
    ; collection, right before clearing gc_collecting) prevents allocations made
    ; while gc_collecting == 1 (e.g. during finalizers or by peer threads) from
    ; leaving a shard above threshold on the very next gc_track().
    mov rax, [rbp - GCG_FOUND]
    mov ecx, [rbp - GCG_GEN]
    imul rcx, rcx, 24
    lea rdx, [rel gc_stat_counters]
    inc qword [rdx + rcx]
    add [rdx + rcx + 8], rax

    lea rcx, [rel gc_shards]
    xor edx, edx
.gc_zero_cnts:
    mov qword [rcx + GCS_COUNT], 0
    add rcx, GC_SHARD_STRIDE
    inc edx
    cmp edx, GC_NSHARDS
    jb .gc_zero_cnts

    mov qword [gs:ThreadState.gc_collect_rsp], 0
    mov qword [rel gc_collecting], 0

    mov eax, [rbp - GCG_GEN]
    test eax, eax
    jz .check_gen1
    cmp eax, 1
    je .inc_gen2_colls
    jmp .collect_done

.check_gen1:
    inc qword [rel gc_gen1_collections]
    mov rax, [rel gc_gen1_collections]
    cmp rax, [rel gc_gen1_threshold]
    jl .collect_done
    mov qword [rel gc_gen1_collections], 0
    mov edi, 1
    call gc_collect_gen
    jmp .collect_done

.inc_gen2_colls:
    inc qword [rel gc_gen2_collections]
    mov rax, [rel gc_gen2_collections]
    cmp rax, [rel gc_gen2_threshold]
    jl .collect_done
    mov qword [rel gc_gen2_collections], 0
    mov edi, 2
    call gc_collect_gen

.collect_done:
    mov rax, [rbp - GCG_FOUND]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.already_collecting:
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.stw_a_oom:
.stw_b_oom:
    call stw_start_world
    CSTRING rdi, "out of memory in gc_collect_gen"
    call fatal_error
END_FUNC gc_collect_gen

;; ============================================================================
;; gc_visit_decref(rdi=obj)
;; Visit callback for Phase 2 / res2: decrement gc_refs of visited object.
;; ============================================================================
DEF_FUNC_BARE gc_visit_decref
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .skip
    GC_SKIP_STATIC_TYPE rdi, rax, .skip
    lea rax, [rdi - GC_HEAD_SIZE]
    cmp qword [rax + PyGC_Head.gc_next], 0
    je .skip
    mov rcx, [rax + PyGC_Head.gc_prev]
    test rcx, GC_PREV_MASK_COLLECTING
    jz .skip
    mov rdx, rcx
    and rdx, ~GC_PREV_MASK
    shr rcx, GC_PREV_SHIFT
    dec rcx
    jns .store
    xor ecx, ecx
.store:
    shl rcx, GC_PREV_SHIFT
    or rcx, rdx
    mov [rax + PyGC_Head.gc_prev], rcx
.skip:
    ret
END_FUNC gc_visit_decref

;; ============================================================================
;; gc_visit_reachable(rdi=obj)
;; Visit callback for Phase 4 / res4: move node from unreachable to reachable.
;; ============================================================================
GVR_FIN   equ 8
GVR_FRAME equ 24           ; + 1 push = 32, 16-aligned
DEF_FUNC gc_visit_reachable, GVR_FRAME
    push rbx

    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .done
    GC_SKIP_STATIC_TYPE rdi, rax, .done
    lea rbx, [rdi - GC_HEAD_SIZE]
    cmp qword [rbx + PyGC_Head.gc_next], 0
    je .done

    mov rax, [rbx + PyGC_Head.gc_prev]
    test rax, GC_PREV_MASK_COLLECTING
    jz .done

    and rax, GC_PREV_MASK_FINALIZED
    mov [rbp - GVR_FIN], rax

    mov rdi, rbx
    call gc_list_remove

    mov rdi, rbx
    mov rsi, [rel gc_reachable_sentinel]
    call gc_list_append
    mov rax, [rbp - GVR_FIN]
    or [rbx + PyGC_Head.gc_prev], rax

.done:
    pop rbx
    leave
    ret
END_FUNC gc_visit_reachable
