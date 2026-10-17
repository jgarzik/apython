; gc.asm - Cycle-collecting garbage collector for apython
; CPython 3.12 compatible generational GC
;
; Three generations: gen0 (young), gen1, gen2 (old)
; Each generation is a doubly-linked list of PyGC_Head nodes.
; gc_refs stored in gc_prev high bits during collection.

%include "macros.inc"
%include "object.inc"

extern ap_malloc
extern ap_free
extern obj_decref
extern obj_dealloc
extern obj_incref
extern frame_free
extern sys_write
extern list_append

;; ============================================================================
;; GC data (BSS + DATA)
;; ============================================================================
section .data

; Generation 0 sentinel (young objects)
align 8
gc_gen0:
    dq gc_gen0          ; gc_next -> self (empty list)
    dq gc_gen0          ; gc_prev -> self
global gc_gen0_count
gc_gen0_count:  dq 0
global gc_gen0_threshold
gc_gen0_threshold: dq 700

; Generation 1 sentinel
align 8
gc_gen1:
    dq gc_gen1
    dq gc_gen1
global gc_gen1_threshold
gc_gen1_threshold: dq 10
global gc_gen1_collections
gc_gen1_collections: dq 0

; Generation 2 sentinel
align 8
gc_gen2:
    dq gc_gen2
    dq gc_gen2
global gc_gen2_threshold
gc_gen2_threshold: dq 10
global gc_gen2_collections
gc_gen2_collections: dq 0

; GC state
global gc_enabled
gc_enabled:     dq 1

; The gc.set_debug() flags, and the gc.garbage list the SAVEALL one needs.
; The list is registered by gc_module_create; it is 0 until `import gc`, and
; SAVEALL with no list simply collects as usual rather than losing objects.
global gc_debug
gc_debug:       dq 0
global gc_garbage_list
gc_garbage_list: dq 0
; Three counters per generation -- collections, collected, uncollectable --
; which is what gc.get_stats() answers with.
global gc_stat_counters
gc_stat_counters: times 9 dq 0

global gc_collecting        ; reentrancy guard: gc_track and gc_collect_gen
                            ; both refuse to start a pass while it is set
gc_collecting:  dq 0

; Where gc_collect_gen's frame is, while it is running; 0 when it is not.
;
; eval_exception_unwind has to clear gc_collecting for a raise that escapes
; the collector -- one with no Python frame beneath it lands in an OUTER
; frame, which discards this one, and nothing would ever clear the flag
; again.  It must NOT clear it for a raise inside a finalizer, which lands in
; the finalizer's own frame and comes back here with the collection still
; running; clearing it there let the finalizer's next allocation, or its next
; gc.collect(), start a second pass over the lists this frame holds.
;
; The two are told apart by where the unwind LANDS.  The machine stack grows
; down, so a landing point below this is a frame nested inside the collection
; and the collector survives; a landing point above it discards the
; collector's frame.  One comparison, and it is exact.  gc_collect_rsp is the
; COLLECTING thread's, so it lives in ThreadState (src/include/threadstate.inc).
; gc_collecting stays global: the collector is.

; Generation table (for indexed access).  Only the sentinel is ever read
; through it: the count and threshold columns it used to carry were named
; directly by everything that wanted them, and two of the three counts did
; not exist -- gen1 and gen2 were declared, exported and never once written.
align 8
gc_generations:
    dq gc_gen0                  ; gen 0
    dq gc_gen1                  ; gen 1
    dq gc_gen2                  ; gen 2

GEN_ENTRY_SIZE equ 8    ; one qword per generation entry

section .text


;; ============================================================================
;; gc_list_append(rdi=node, rsi=list_sentinel)
;; Insert node at the tail of list (before sentinel)
;; ============================================================================
DEF_FUNC_BARE gc_list_append
    ; node->gc_next = sentinel
    mov [rdi + PyGC_Head.gc_next], rsi
    ; node->gc_prev = sentinel->gc_prev (preserve low bits = 0 for tracked)
    mov rax, [rsi + PyGC_Head.gc_prev]
    and rax, GC_PREV_MASK          ; clear state bits from prev pointer
    mov [rdi + PyGC_Head.gc_prev], rax
    ; old_tail->gc_next = node
    mov [rax + PyGC_Head.gc_next], rdi
    ; sentinel->gc_prev = node (keep state bits = 0)
    mov [rsi + PyGC_Head.gc_prev], rdi
    ret
END_FUNC gc_list_append

;; ============================================================================
;; gc_list_remove(rdi=node)
;; Remove node from its doubly-linked list
;; ============================================================================
DEF_FUNC_BARE gc_list_remove
    mov rax, [rdi + PyGC_Head.gc_prev]
    and rax, GC_PREV_MASK          ; clear state bits
    mov rcx, [rdi + PyGC_Head.gc_next]
    ; prev->gc_next = node->gc_next
    mov [rax + PyGC_Head.gc_next], rcx
    ; next->gc_prev = prev (copy prev, preserve next's state bits)
    mov rdx, [rcx + PyGC_Head.gc_prev]
    and rdx, ~GC_PREV_MASK         ; keep state bits
    or rax, rdx                    ; combine prev ptr with state bits
    mov [rcx + PyGC_Head.gc_prev], rax
    ret
END_FUNC gc_list_remove


;; ============================================================================
;; gc_list_merge(rdi=from_sentinel, rsi=to_sentinel)
;; Move all nodes from 'from' list to end of 'to' list. Empties 'from'.
;; ============================================================================
DEF_FUNC gc_list_merge
    push rbx

    ; Check if from is empty
    mov rax, [rdi + PyGC_Head.gc_next]
    cmp rax, rdi
    je .empty

    ; from_head = from->gc_next, from_tail = from->gc_prev
    mov rbx, rax                   ; rbx = from_head
    mov rcx, [rdi + PyGC_Head.gc_prev]
    and rcx, GC_PREV_MASK          ; rcx = from_tail (clear bits)

    ; to_tail = to->gc_prev
    mov rdx, [rsi + PyGC_Head.gc_prev]
    and rdx, GC_PREV_MASK          ; rdx = to_tail

    ; to_tail->gc_next = from_head
    mov [rdx + PyGC_Head.gc_next], rbx
    ; from_head->gc_prev = to_tail
    mov [rbx + PyGC_Head.gc_prev], rdx
    ; from_tail->gc_next = to_sentinel
    mov [rcx + PyGC_Head.gc_next], rsi
    ; to_sentinel->gc_prev = from_tail
    mov [rsi + PyGC_Head.gc_prev], rcx

    ; Empty the from list
    mov [rdi + PyGC_Head.gc_next], rdi
    mov [rdi + PyGC_Head.gc_prev], rdi

.empty:
    pop rbx
    leave
    ret
END_FUNC gc_list_merge

;; ============================================================================
;; gc_alloc(rdi=size, rsi=type) -> PyObject*
;; Allocate a GC-tracked object. Prepends PyGC_Head, returns obj pointer.
;; ============================================================================
DEF_FUNC gc_alloc
    push rbx
    push r12

    mov rbx, rdi               ; size
    mov r12, rsi               ; type

    ; Allocate size + GC_HEAD_SIZE
    lea rdi, [rbx + GC_HEAD_SIZE]
    call ap_malloc
    ; rax = raw alloc ptr (PyGC_Head)

    ; Zero the GC head
    mov qword [rax + PyGC_Head.gc_next], 0
    mov qword [rax + PyGC_Head.gc_prev], 0

    ; Object starts after GC head
    lea rbx, [rax + GC_HEAD_SIZE]

    ; Init ob_refcnt=1, ob_type=type
    mov qword [rbx + PyObject.ob_refcnt], 1
    mov [rbx + PyObject.ob_type], r12

    mov rax, rbx               ; return obj ptr
    pop r12
    pop rbx
    leave
    ret
END_FUNC gc_alloc

;; ============================================================================
;; gc_track(rdi=obj)
;; Add object to gen0 tracking list. May trigger collection.
;; ============================================================================
DEF_FUNC gc_track, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi               ; save obj

    ; gc = obj - GC_HEAD_SIZE
    lea rdi, [rbx - GC_HEAD_SIZE]
    ; Already in a list?  Appending a second time makes the node's own links
    ; point into two places at once, and the next removal writes through the
    ; stale pair -- an arbitrary 8-byte store into freed memory.
    cmp qword [rdi + PyGC_Head.gc_next], 0
    jne .already_tracked
    ; Append to gen0 list
    lea rsi, [rel gc_gen0]
    call gc_list_append

    ; Increment gen0 count
    inc qword [rel gc_gen0_count]

    ; Check threshold
    mov rax, [rel gc_gen0_count]
    cmp rax, [rel gc_gen0_threshold]
    jle .done

    ; Check if GC is enabled and not already collecting
    cmp qword [rel gc_enabled], 0
    je .done
    cmp qword [rel gc_collecting], 0
    jne .done

    ; Trigger gen0 collection
    xor edi, edi               ; gen = 0
    call gc_collect_gen

.done:
    pop rbx
    leave
    ret

.already_tracked:
    pop rbx
    leave
    ret
END_FUNC gc_track

;; ============================================================================
;; gc_untrack(rdi=obj)
;; Remove object from GC tracking list.
;; ============================================================================
DEF_FUNC gc_untrack
    ; gc = obj - GC_HEAD_SIZE
    lea rdi, [rdi - GC_HEAD_SIZE]

    ; Check if actually tracked (gc_next != 0)
    cmp qword [rdi + PyGC_Head.gc_next], 0
    je .not_tracked

    call gc_list_remove

    ; Mark the node untracked.  gc_list_remove only fixes up the neighbours;
    ; it leaves this node's own links pointing into the list.  Every "is it
    ; tracked?" test in the collector and in gc_dealloc reads gc_next, so a
    ; stale one made a second untrack unlink a node that was no longer in any
    ; list -- writing through pointers into freed memory.
    mov qword [rdi + PyGC_Head.gc_next], 0
    mov qword [rdi + PyGC_Head.gc_prev], 0

    ; We don't track which gen it's in, so decrement gen0 count
    ; (approximate — during collection, counts are managed differently)
    dec qword [rel gc_gen0_count]
    jns .done
    mov qword [rel gc_gen0_count], 0

.not_tracked:
.done:
    leave
    ret
END_FUNC gc_untrack

;; ============================================================================
;; gc_dealloc(rdi=obj)
;; Untrack and free a potentially GC-tracked object.
;; If TYPE_FLAG_HAVE_GC is set: untrack + free at obj - GC_HEAD_SIZE
;; Otherwise: plain ap_free(obj) (for objects allocated without GC head)
;; ============================================================================
DEF_FUNC gc_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; Check if this type uses GC allocation
    mov rax, [rbx + PyObject.ob_type]
    test rax, rax
    jz .plain_free                 ; safety: no type -> plain free
    mov rax, [rax + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_HAVE_GC
    jz .plain_free

    ; GC-allocated object: untrack if tracked
    lea rdi, [rbx - GC_HEAD_SIZE]
    cmp qword [rdi + PyGC_Head.gc_next], 0
    je .gc_free

    mov rdi, rbx
    call gc_untrack

.gc_free:
    ; Free at the GC head address
    lea rdi, [rbx - GC_HEAD_SIZE]
    call ap_free
    jmp .done

.plain_free:
    ; Non-GC object: standard free
    mov rdi, rbx
    call ap_free

.done:
    pop rbx
    leave
    ret
END_FUNC gc_dealloc

;; ============================================================================
;; gc_walk_generation(rdi = generation 0..2, rsi = list)
;; Appends every object tracked in that generation to the list.
;;
;; The list is itself a tracked object and is skipped by identity: appending
;; it to itself would still terminate, but it would report a list that
;; contains itself.  list_append can reallocate, and a reallocation is the
;; kind of thing that could otherwise trigger a collection and unlink nodes
;; out from under the walk -- gc_collecting is the flag gc_track already
;; tests before triggering one, so the walk raises it for its duration.
;; ============================================================================
GWG_LIST  equ 8
GWG_SAVED equ 16
GWG_FRAME equ 32            ; + 2 pushes = 48

global gc_walk_generation
DEF_FUNC gc_walk_generation, GWG_FRAME
    push rbx
    push r12
    mov [rbp - GWG_LIST], rsi
    lea rax, [rel gc_generations]
    mov r12, [rax + rdi*8]              ; the generation's sentinel

    mov rax, [rel gc_collecting]
    mov [rbp - GWG_SAVED], rax
    mov qword [rel gc_collecting], 1

    mov rbx, [r12 + PyGC_Head.gc_next]
.gwg_loop:
    cmp rbx, r12
    je .gwg_done
    lea rsi, [rbx + GC_HEAD_SIZE]
    cmp rsi, [rbp - GWG_LIST]
    je .gwg_next
    mov rdi, [rbp - GWG_LIST]
    call list_append
.gwg_next:
    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .gwg_loop
.gwg_done:
    mov rax, [rbp - GWG_SAVED]
    mov [rel gc_collecting], rax
    pop r12
    pop rbx
    leave
    ret
END_FUNC gc_walk_generation

;; ============================================================================
;; The gc.set_debug() reporting.  It goes to stderr, unbuffered, through the
;; write syscall: a collection can be running under any interpreter state at
;; all -- including inside a tp_clear -- so it must not allocate, must not
;; call into Python, and must not touch sys.stderr.
;;
;; DEBUG_COLLECTABLE names the type and the address rather than calling repr,
;; which is what CPython does too, and for the same reason: repr on a
;; half-cleared object runs arbitrary Python inside the collector.
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
GCU_END   equ 8             ; one past the last digit
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
    sub rdx, rcx                ; length
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
    lea rdi, [rel gcd_s_0x]
    call gcd_puts
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
;;   gc: <msg> <typename 0xADDR>
DEF_FUNC_LOCAL gcd_report, 16                        ; + 2 pushes = 24
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
;; gc_collect_gen(edi=generation) -> rax = the unreachable objects it cleared
;; Core cycle collection algorithm.
;; ============================================================================
; Local frame layout
GCG_GEN     equ 8
GCG_YOUNG   equ 24    ; 16-byte PyGC_Head sentinel on stack (next+prev)
GCG_UNREACH equ 40    ; 16-byte PyGC_Head sentinel on stack
GCG_RANFIN  equ 48    ; did any finalizer actually run this pass?
GCG_FOUND   equ 56    ; how many unreachable objects this pass cleared
GCG_SEEN    equ 72    ; 16-byte PyGC_Head sentinel, the finalize phase's
GCG_FRAME   equ 88            ; + 5 pushes = 128, 16-aligned

global gc_collect_gen
DEF_FUNC gc_collect_gen, GCG_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; A collection already running is a collection this one must not join.
    ;
    ; Phase 3 and phase 4.5 keep their unreachable and finalize sentinels in
    ; THIS frame, and phase 4.5 runs ordinary Python -- every __del__ on an
    ; unreachable object with one.  A finalizer that called gc.collect()
    ; started a second pass over the same generation lists and rebuilt them
    ; around this frame's stack addresses, leaving the outer pass walking
    ; links into a frame that had moved on.
    ;
    ; The flag was already set here and already tested by gc_track, which is
    ; why an allocation inside a finalizer was safe and an explicit collect
    ; was not -- and CPython's test suite calls support.gc_collect() from
    ; tearDown constantly, with event-loop and stream finalizers underneath.
    ; CPython answers 0 to the same question, in gcmodule.c's
    ; "if (gcstate->collecting) return 0"; so does this.
    cmp qword [rel gc_collecting], 0
    jne .already_collecting

    mov [rbp - GCG_GEN], edi    ; save generation
    mov qword [rbp - GCG_FOUND], 0
    mov qword [rbp - GCG_RANFIN], 0

    ; Set collecting flag, and say where this frame is, so that a raise from
    ; inside a finalizer can be told from one that discards this frame.
    mov qword [rel gc_collecting], 1
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

    ; Initialize young list sentinel on stack
    lea rax, [rbp - GCG_YOUNG]
    mov [rax + PyGC_Head.gc_next], rax
    mov [rax + PyGC_Head.gc_prev], rax

    ; Initialize unreachable list sentinel on stack
    lea rax, [rbp - GCG_UNREACH]
    mov [rax + PyGC_Head.gc_next], rax
    mov [rax + PyGC_Head.gc_prev], rax

    ; Merge gen 0..gen into young list
    xor r12d, r12d             ; i = 0
.merge_loop:
    cmp r12d, [rbp - GCG_GEN]
    jg .merge_done

    ; Get gen[i] sentinel address
    lea rdi, [rel gc_generations]
    imul eax, r12d, GEN_ENTRY_SIZE
    mov rdi, [rdi + rax]      ; gen[i].sentinel

    lea rsi, [rbp - GCG_YOUNG]
    call gc_list_merge

    inc r12d
    jmp .merge_loop
.merge_done:

    ; ---- Phase 1: Set gc_refs = ob_refcnt for all objects in young ----
    lea r12, [rbp - GCG_YOUNG]  ; r12 = young sentinel
    mov rbx, [r12 + PyGC_Head.gc_next]  ; rbx = first gc node

.phase1_loop:
    cmp rbx, r12
    je .phase1_done

    ; obj = gc + GC_HEAD_SIZE
    lea rax, [rbx + GC_HEAD_SIZE]
    mov rcx, [rax + PyObject.ob_refcnt]

    ; Store gc_refs in gc_prev, with the COLLECTING bit set.  That bit is
    ; what marks a node as belonging to *this* collection: phase 2 traverses
    ; young objects but reaches referents in older generations too, and those
    ; still hold a real prev pointer in the same field.  Without the mark,
    ; gc_visit_decref subtracted 4 from an older node's prev pointer and the
    ; list was silently corrupt until something tried to unlink through it.
    shl rcx, GC_PREV_SHIFT
    or rcx, GC_PREV_MASK_COLLECTING
    ; FINALIZED is not this collection's business and must outlive it: it says
    ; __del__ has already run, ever.  Overwriting the whole word here dropped
    ; it, so an object resurrected by its own finalizer and collected again
    ; later had __del__ run a second time.  CPython's gc_reset_refs keeps the
    ; same bit for the same reason.
    mov rdx, [rbx + PyGC_Head.gc_prev]
    and rdx, GC_PREV_MASK_FINALIZED
    or rcx, rdx
    mov [rbx + PyGC_Head.gc_prev], rcx

    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .phase1_loop
.phase1_done:

    ; ---- Phase 2: Traverse all objects, decrement gc_refs of visited targets ----
    mov rbx, [r12 + PyGC_Head.gc_next]

.phase2_loop:
    cmp rbx, r12
    je .phase2_done

    lea r13, [rbx + GC_HEAD_SIZE]  ; r13 = obj
    mov rax, [r13 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_traverse]
    test rax, rax
    jz .phase2_next

    ; Call tp_traverse(obj, visit_decref, NULL)
    ; Use r14 for the visit callback used by the VISIT_* macros
    push rbx
    mov rdi, r13               ; obj
    lea r14, [rel gc_visit_decref]  ; visit callback
    call rax                   ; tp_traverse
    pop rbx

.phase2_next:
    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .phase2_loop
.phase2_done:

    ; ---- Phase 3: Partition into reachable (gc_refs > 0) vs unreachable ----
    ; NOTE: gc_prev was overwritten with gc_refs in phase 1, so we cannot use
    ; gc_list_remove (which needs gc_prev). Instead, track prev pointer (r14)
    ; and rebuild gc_prev as we walk gc_next.
    lea r15, [rbp - GCG_UNREACH]  ; r15 = unreachable sentinel
    mov r14, r12                   ; r14 = prev (starts at young sentinel)

    mov rbx, [r12 + PyGC_Head.gc_next]

.phase3_loop:
    cmp rbx, r12
    je .phase3_done

    mov r13, [rbx + PyGC_Head.gc_next]  ; save next

    ; Check gc_refs (stored in gc_prev high bits from phase 1)
    mov rax, [rbx + PyGC_Head.gc_prev]
    mov rdx, rax
    and rdx, GC_PREV_MASK_FINALIZED  ; carried across both rewrites below
    shr rax, GC_PREV_SHIFT     ; gc_refs
    test rax, rax
    jnz .phase3_keep           ; gc_refs > 0 — tentatively reachable

    ; Unreachable: unlink from young by setting prev->gc_next = next
    mov [r14 + PyGC_Head.gc_next], r13
    ; (don't update r14 — prev stays the same)

    ; Append to unreachable list (gc_list_append maintains gc_prev properly)
    mov rdi, rbx
    mov rsi, r15
    call gc_list_append

    ; Mark as collecting (set bit in gc_prev)
    mov rax, [rbx + PyGC_Head.gc_prev]
    or rax, GC_PREV_MASK_COLLECTING
    or rax, rdx                ; and whatever FINALIZED said
    mov [rbx + PyGC_Head.gc_prev], rax

    jmp .phase3_next

.phase3_keep:
    ; Reachable: restore gc_prev to point to prev node.  Every reader of a
    ; prev pointer masks the low two bits off, so FINALIZED rides along in it.
    mov rax, r14
    or rax, rdx
    mov [rbx + PyGC_Head.gc_prev], rax
    mov r14, rbx               ; update prev

.phase3_next:
    mov rbx, r13
    jmp .phase3_loop

.phase3_done:
    ; Fix young sentinel's gc_prev to point to last reachable node
    mov [r12 + PyGC_Head.gc_prev], r14

    ; ---- Phase 4: Traverse reachable roots, rescue transitively reachable ----
    ; Set the global so gc_visit_reachable knows where to move rescued objects
    mov [rel gc_reachable_sentinel], r12

    mov rbx, [r12 + PyGC_Head.gc_next]

.phase4_loop:
    cmp rbx, r12
    je .phase4_done

    lea r13, [rbx + GC_HEAD_SIZE]  ; obj
    mov rax, [r13 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_traverse]
    test rax, rax
    jz .phase4_next

    push rbx
    mov rdi, r13
    lea r14, [rel gc_visit_reachable]
    call rax
    pop rbx

.phase4_next:
    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .phase4_loop
.phase4_done:

    ; ---- Phase 4.5: run the finalizers, before anything is cleared --------
    ; PEP 442.  Every unreachable object with a __del__ gets it called, once,
    ; while the cycle it is part of is still intact.  Letting phase 5's
    ; tp_clear drop the last reference and reach __del__ that way, which is
    ; what happened before, hands the finalizer an object whose attributes
    ; have already been dropped -- and then frees whatever it resurrected,
    ; underneath the reference it was just given.
    ;
    ; Each object moves to `seen` BEFORE its finalizer runs and the head is
    ; re-read every turn, because a __del__ can break a cycle and free other
    ; members of this very list.  The state bits are carried across the move
    ; by hand: gc_list_append writes a clean prev pointer.
    lea r13, [rbp - GCG_SEEN]
    mov [r13 + PyGC_Head.gc_next], r13
    mov [r13 + PyGC_Head.gc_prev], r13

.finalize_loop:
    mov rbx, [r15 + PyGC_Head.gc_next]
    cmp rbx, r15
    je .finalize_done

    mov r14, [rbx + PyGC_Head.gc_prev]
    and r14, ~GC_PREV_MASK          ; the state bits, kept across the move
    mov rdi, rbx
    call gc_list_remove
    mov rdi, rbx
    mov rsi, r13
    call gc_list_append
    or [rbx + PyGC_Head.gc_prev], r14

    test r14, GC_PREV_MASK_FINALIZED
    jnz .finalize_loop              ; an earlier collection already ran it

    lea rdi, [rbx + GC_HEAD_SIZE]
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HAS_DEL
    jz .finalize_loop

    or qword [rbx + PyGC_Head.gc_prev], GC_PREV_MASK_FINALIZED
    mov qword [rbp - GCG_RANFIN], 1
    extern obj_call_finalizer
    call obj_call_finalizer
    jmp .finalize_loop

.finalize_done:
    ; Put the chain back.  gc_list_merge would rewrite the head node's gc_prev
    ; and lose its state bits, and nothing can have been added to the
    ; unreachable sentinel meanwhile, so the two just exchange chains.
    mov rax, [r13 + PyGC_Head.gc_next]
    cmp rax, r13
    je .finalize_empty
    mov rcx, [r13 + PyGC_Head.gc_prev]
    and rcx, GC_PREV_MASK           ; tail
    mov [r15 + PyGC_Head.gc_next], rax
    mov [r15 + PyGC_Head.gc_prev], rcx
    mov rdx, [rax + PyGC_Head.gc_prev]
    and rdx, ~GC_PREV_MASK
    or rdx, r15
    mov [rax + PyGC_Head.gc_prev], rdx
    mov [rcx + PyGC_Head.gc_next], r15
    jmp .finalize_back
.finalize_empty:
    mov [r15 + PyGC_Head.gc_next], r15
    mov [r15 + PyGC_Head.gc_prev], r15
.finalize_back:

    ; Nothing ran, so nothing can have been resurrected: skip the recount.
    ; This is the ordinary case -- most programs have no __del__ anywhere --
    ; and it keeps the collection at exactly the cost it had before.
    cmp qword [rbp - GCG_RANFIN], 0
    je .resurrect_done

    ; ---- Phase 4.6: what the finalizers brought back ----------------------
    ; A finalizer that stored `self` somewhere outside the cycle has given the
    ; object a reference this set does not account for.  Recompute reachability
    ; over the unreachable set alone, exactly as phases 1-4 did over the young
    ; list: whatever still has no reference from outside stays unreachable, and
    ; everything else -- and everything it holds -- goes back to be looked at
    ; next time.
    mov rbx, [r15 + PyGC_Head.gc_next]
.res1_loop:
    cmp rbx, r15
    je .res1_done
    lea rax, [rbx + GC_HEAD_SIZE]
    mov rcx, [rax + PyObject.ob_refcnt]
    shl rcx, GC_PREV_SHIFT
    or rcx, GC_PREV_MASK_COLLECTING
    mov rdx, [rbx + PyGC_Head.gc_prev]
    and rdx, GC_PREV_MASK_FINALIZED ; a finalizer still runs at most once
    or rcx, rdx
    mov [rbx + PyGC_Head.gc_prev], rcx
    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .res1_loop
.res1_done:

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
    push rbx                        ; and a pad, so the call is 16-aligned
    mov rdi, r13
    lea r14, [rel gc_visit_decref]
    call rax
    pop rbx
    pop rbx
.res2_next:
    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .res2_loop
.res2_done:

    ; Sort the set: still unreachable back into the unreachable list, anything
    ; with a reference from outside it into the young list.  Draining by
    ; gc_next and re-appending is what rebuilds the prev pointers that the
    ; recount above overwrote with gc_refs.
    mov rbx, [r15 + PyGC_Head.gc_next]
    mov [r15 + PyGC_Head.gc_next], r15
    mov [r15 + PyGC_Head.gc_prev], r15
.res3_loop:
    cmp rbx, r15
    je .res3_done
    mov r13, [rbx + PyGC_Head.gc_next]      ; the original next
    mov r14, [rbx + PyGC_Head.gc_prev]
    mov rax, r14
    shr rax, GC_PREV_SHIFT                  ; gc_refs
    and r14, GC_PREV_MASK_FINALIZED         ; the bit to carry over
    test rax, rax
    jnz .res3_alive

    mov rdi, rbx
    mov rsi, r15
    call gc_list_append
    or r14, GC_PREV_MASK_COLLECTING
    or [rbx + PyGC_Head.gc_prev], r14
    jmp .res3_next

.res3_alive:
    ; Resurrected.  It joins the reachable set with the collecting bit clear,
    ; and is promoted with the rest at the end of this collection.
    mov rdi, rbx
    mov rsi, r12
    call gc_list_append
    or [rbx + PyGC_Head.gc_prev], r14

.res3_next:
    mov rbx, r13
    jmp .res3_loop
.res3_done:

    ; And whatever a resurrected object holds comes back with it.
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
    push rbx                        ; and a pad, so the call is 16-aligned
    mov rdi, r13
    lea r14, [rel gc_visit_reachable]
    call rax
    pop rbx
    pop rbx
.res4_next:
    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .res4_loop
.res4_done:

.resurrect_done:

    ; ---- Count the unreachable set, before phase 5 starts freeing it ----
    ; This is the number gc.collect() answers with.  Counting inside phase 5
    ; undercounts, and by a lot: clearing one member of a cycle drops the
    ; others by refcount, and obj_dealloc -> gc_untrack unlinks them before
    ; the loop ever reaches them.  A three-object cycle answered 1.
    mov rbx, [r15 + PyGC_Head.gc_next]
.count_loop:
    cmp rbx, r15
    je .count_done
    inc qword [rbp - GCG_FOUND]
    test qword [rel gc_debug], GC_DEBUG_COLLECTABLE
    jz .count_next
    lea rdi, [rbx + GC_HEAD_SIZE]
    lea rsi, [rel gcd_s_coll]
    call gcd_report
.count_next:
    mov rbx, [rbx + PyGC_Head.gc_next]
    jmp .count_loop
.count_done:

    ; ---- DEBUG_SAVEALL: hand the unreachable set to gc.garbage ----
    ; CPython appends every unreachable object to gc.garbage and does not
    ; clear any of them, so the whole cycle stays alive to be looked at.  The
    ; nodes go back into the young list one at a time rather than by a list
    ; merge: gc_list_append rewrites gc_prev, which is what clears the
    ; COLLECTING bit phase 3 set.  Leaving it set would make the next
    ; collection's gc_visit_decref treat these as part of *its* generation.
    test qword [rel gc_debug], GC_DEBUG_SAVEALL
    jz .no_saveall
    mov rax, [rel gc_garbage_list]
    test rax, rax
    jz .no_saveall
.saveall_loop:
    mov rbx, [r15 + PyGC_Head.gc_next]
    cmp rbx, r15
    je .saveall_done
    lea rsi, [rbx + GC_HEAD_SIZE]
    mov rdi, [rel gc_garbage_list]
    call list_append
    mov r14, [rbx + PyGC_Head.gc_prev]
    and r14, GC_PREV_MASK_FINALIZED  ; kept; only COLLECTING is being cleared
    mov rdi, rbx
    call gc_list_remove
    mov rdi, rbx
    mov rsi, r12
    call gc_list_append
    or [rbx + PyGC_Head.gc_prev], r14
    jmp .saveall_loop
.saveall_done:
    jmp .phase5_done
.no_saveall:

    ; ---- Phase 5: Clear the unreachable set, letting DECREF free it ----
    ; One pass, and the head is re-read from the sentinel every time round.
    ; Caching a next pointer across tp_clear is what broke here: clearing one
    ; object drops references to others in the same list, so the node that
    ; had been saved as "next" was often freed before the walk reached it.
    ; Holding a reference across tp_clear is the other half -- it keeps the
    ; object under our own feet alive, exactly as delete_garbage does.
.phase5_loop:
    mov rbx, [r15 + PyGC_Head.gc_next]
    cmp rbx, r15
    je .phase5_done

    lea r13, [rbx + GC_HEAD_SIZE]          ; r13 = obj
    inc qword [r13 + PyObject.ob_refcnt]

    mov rax, [r13 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_clear]
    test rax, rax
    jz .phase5_no_clear
    mov rdi, r13
    call rax                               ; tp_clear(obj)
.phase5_no_clear:

    ; Still at the head?  Then clearing it did not take it out of the list,
    ; and the loop has to, or it never advances.  Survivors join the young
    ; list and are promoted with it; CPython moves them to `old` the same way.
    ;
    ; gc_list_append writes a clean prev pointer, which is what takes the
    ; collecting bit off -- and it would take FINALIZED off with it, so a
    ; survivor whose __del__ the finalize phase already ran would have it run
    ; a second time on the way out.  That bit is carried over by hand.
    cmp qword [r15 + PyGC_Head.gc_next], rbx
    jne .phase5_drop
    mov r14, [rbx + PyGC_Head.gc_prev]
    and r14, GC_PREV_MASK_FINALIZED
    mov rdi, rbx
    call gc_list_remove
    mov rdi, rbx
    mov rsi, r12
    call gc_list_append
    or [rbx + PyGC_Head.gc_prev], r14

.phase5_drop:
    mov rdi, r13
    dec qword [rdi + PyObject.ob_refcnt]
    jnz .phase5_loop
    call obj_dealloc
    jmp .phase5_loop

.phase5_done:

    test qword [rel gc_debug], GC_DEBUG_STATS
    jz .no_stats_done
    lea rdi, [rel gcd_s_done]
    call gcd_puts
    mov rdi, [rbp - GCG_FOUND]
    call gcd_putu
    lea rdi, [rel gcd_s_unre]
    call gcd_puts
.no_stats_done:

    ; ---- Move surviving reachable objects to next generation ----
    mov eax, [rbp - GCG_GEN]
    cmp eax, 2
    jge .promote_to_gen2
    inc eax
    jmp .do_promote
.promote_to_gen2:
    mov eax, 2
.do_promote:
    ; Get target generation sentinel
    lea rdi, [rel gc_generations]
    imul ecx, eax, GEN_ENTRY_SIZE
    mov rsi, [rdi + rcx]      ; target gen sentinel

    lea rdi, [rbp - GCG_YOUNG]
    call gc_list_merge

    ; Reset gen0 count (approximate)
    mov qword [rel gc_gen0_count], 0

    ; Update collection counters for triggering higher-gen collections
    mov eax, [rbp - GCG_GEN]
    test eax, eax
    jz .check_gen1

    cmp eax, 1
    je .inc_gen2_colls
    jmp .collect_done

.check_gen1:
    ; Gen0 collection done — increment gen1 collection counter
    inc qword [rel gc_gen1_collections]
    mov rax, [rel gc_gen1_collections]
    cmp rax, [rel gc_gen1_threshold]
    jl .collect_done
    mov qword [rel gc_gen1_collections], 0
    ; Trigger gen1 collection
    mov edi, 1
    call gc_collect_gen
    jmp .collect_done

.inc_gen2_colls:
    ; Gen1 collection done — increment gen2 collection counter
    inc qword [rel gc_gen2_collections]
    mov rax, [rel gc_gen2_collections]
    cmp rax, [rel gc_gen2_threshold]
    jl .collect_done
    mov qword [rel gc_gen2_collections], 0
    ; Trigger gen2 collection
    mov edi, 2
    call gc_collect_gen

.collect_done:
    ; Clear collecting flag
    mov qword [rel gc_collecting], 0
    mov qword [gs:ThreadState.gc_collect_rsp], 0
    mov rax, [rbp - GCG_FOUND]

    ; What gc.get_stats() reports: how many collections have run in this
    ; generation and how many objects they freed.  Nothing counted before,
    ; and there was nothing to read them.  "uncollectable" stays zero: an
    ; object this collector cannot free is one with a __del__ in a cycle,
    ; which CPython has not treated as uncollectable since 3.4 either.
    mov ecx, [rbp - GCG_GEN]
    imul rcx, rcx, 24
    lea rdx, [rel gc_stat_counters]
    inc qword [rdx + rcx]
    add [rdx + rcx + 8], rax

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.already_collecting:
    ; No stats row either: nothing was walked, so nothing is counted.  The
    ; flag stays set -- the collection that owns it will clear it.
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC gc_collect_gen


;; ============================================================================
;; gc_visit_decref(rdi=obj)
;; Visit callback for Phase 2: decrement gc_refs of visited object
;; ============================================================================
DEF_FUNC_BARE gc_visit_decref
    ; Check if this object's type has HAVE_GC flag (non-GC objects have no GC head)
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .skip
    GC_SKIP_STATIC_TYPE rdi, rax, .skip
    ; gc = obj - GC_HEAD_SIZE
    lea rax, [rdi - GC_HEAD_SIZE]
    ; Check if object is tracked (gc_next != 0)
    cmp qword [rax + PyGC_Head.gc_next], 0
    je .skip
    ; Only nodes in the generation being collected carry gc_refs here; every
    ; other tracked object still has a live prev pointer in this field.
    mov rcx, [rax + PyGC_Head.gc_prev]
    test rcx, GC_PREV_MASK_COLLECTING
    jz .skip
    mov rdx, rcx
    and rdx, ~GC_PREV_MASK    ; extract state bits (low 2)
    shr rcx, GC_PREV_SHIFT    ; gc_refs
    dec rcx                    ; gc_refs--
    jns .store
    xor ecx, ecx              ; clamp to 0
.store:
    shl rcx, GC_PREV_SHIFT
    or rcx, rdx               ; combine with state bits
    mov [rax + PyGC_Head.gc_prev], rcx
.skip:
    ret
END_FUNC gc_visit_decref

;; ============================================================================
;; gc_visit_reachable(rdi=obj)
;; Visit callback for Phase 4: if obj is in unreachable set, move to reachable
;; ============================================================================
GVR_FIN   equ 8            ; the FINALIZED bit, across the two list calls
GVR_FRAME equ 24           ; + 1 push = 32, so rsp is 16-aligned
DEF_FUNC gc_visit_reachable, GVR_FRAME
    push rbx

    ; Check if this object's type has HAVE_GC flag (non-GC objects have no GC head)
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .done
    GC_SKIP_STATIC_TYPE rdi, rax, .done
    ; gc = obj - GC_HEAD_SIZE
    lea rbx, [rdi - GC_HEAD_SIZE]
    ; Check if tracked
    cmp qword [rbx + PyGC_Head.gc_next], 0
    je .done

    ; Check if in unreachable set (collecting bit set)
    mov rax, [rbx + PyGC_Head.gc_prev]
    test rax, GC_PREV_MASK_COLLECTING
    jz .done                   ; not in unreachable — nothing to do

    ; FINALIZED says __del__ has already run and outlives any one collection;
    ; gc_list_append below writes a clean prev pointer, which is what takes
    ; the collecting bit off and would take that one with it.
    and rax, GC_PREV_MASK_FINALIZED
    mov [rbp - GVR_FIN], rax

    ; Remove from unreachable list
    mov rdi, rbx
    call gc_list_remove

    ; Append to young/reachable list (r12 = young sentinel, set in gc_collect_gen)
    ; We use a global to pass the reachable list sentinel
    mov rdi, rbx
    lea rsi, [rel gc_reachable_sentinel]
    mov rsi, [rsi]
    call gc_list_append
    mov rax, [rbp - GVR_FIN]
    or [rbx + PyGC_Head.gc_prev], rax

.done:
    pop rbx
    leave
    ret
END_FUNC gc_visit_reachable

section .data
gc_reachable_sentinel: dq 0    ; set by gc_collect_gen before phase 4

section .text



































