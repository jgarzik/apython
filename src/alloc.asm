; alloc.asm - Where memory comes from
;
; ap_malloc, ap_free and ap_realloc are the WHOLE funnel.  Nothing else in the
; tree calls libc malloc, free or realloc -- GMP and zlib allocate and free
; their own -- so every byte the interpreter owns passes through these three,
; and they are free to be something other than a libc wrapper.  They are: a
; size-class pool allocator over one contiguous reservation, with libc under
; it for anything over 512 bytes.  The long comment below is the design.
;
; Below the object model, like the rest of runtime.asm was: nothing here can
; allocate a Python object or raise a Python exception, and out of memory is
; fatal_error rather than a return of NULL -- which is why not one of the 183
; call sites in the tree has a failure path.

%include "macros.inc"
%include "object.inc"

extern fatal_error

extern malloc
extern free
extern realloc


;; ============================================================================
;; The pool allocator
;;
;; Every object apython builds is small and dies young.  A million iterations
;; of `[1, 2, 3, 4, 5]` allocate 124,000 blocks averaging 48 bytes with a peak
;; of 353 KB live; glibc malloc and free are 41.9% of that loop's instructions.
;; Nearly every type in the tree is under 144 bytes -- a list header is 40, a
;; dict 80, a bound method 32, a frame 120, and 16 more for anything that
;; carries a GC head.
;;
;; So: CPython's pymalloc, with two deliberate differences.
;;
;; ---- Ownership -------------------------------------------------------------
;;
;; A block carries NO header, so a pointer from the pools and a pointer from
;; libc are indistinguishable by inspection -- and ap_free is handed both,
;; because anything over 512 bytes still goes to libc.  CPython answers this
;; with `address_in_range`, a three-level radix tree over the arena-granular
;; address: three dependent loads on every free.
;;
;; It needs that because it takes address space in one-megabyte pieces
;; wherever mmap puts them.  We take it ONCE, as a single contiguous span, and
;; then the question is two instructions:
;;
;;     mov rax, rdi
;;     sub rax, [rel ap_span_base]
;;     cmp rax, [rel ap_span_len]      ; unsigned: one compare, two-sided
;;
;; against two globals that never leave L1, with no load from the freed page
;; at all.  And the offset that answers it is also the pool number, so the
;; free path gets its size class from the same subtraction.
;;
;; THREE INVARIANTS HOLD THAT UP.  They are not obvious and they are not
;; optional:
;;
;;   1. The span is mapped once and NEVER unmapped, never shrunk, and
;;      ap_span_base / ap_span_len are never rewritten after it exists.  Were
;;      the span ever returned to the kernel, glibc could be handed the same
;;      addresses -- and then ap_free of a libc pointer would push it onto one
;;      of our free lists and hand it out again as a live object.  Silent, and
;;      total.  This is the reason pools are never returned to the OS.
;;
;;   2. Ownership and allocation are INDEPENDENT.  Running out of span must
;;      not clear ap_span_len: blocks handed out before it ran out have to
;;      keep being freed by us forever after.  ap_state gates allocation,
;;      ap_span_len gates ownership, and ap_span_len is write-once.
;;
;;   3. ap_span_len is a variable, not a constant.  The binary is -no-pie at
;;      0x400000 with glibc's brk heap just above the bss, so ordinary libc
;;      pointers ARE numerically below a gigabyte; `cmp rax, SPAN` would claim
;;      them.
;;
;; ---- No pool header --------------------------------------------------------
;;
;; CPython puts a 48-byte header at the start of each pool holding its size
;; class, its own free list and a refcount.  Reaching it means reading the
;; first cache line of the pool that contains the block being freed -- with a
;; thousand live pools, a thousand different pages.
;;
;; Here a pool has no header.  One byte per pool in ap_pool_szidx says which
;; class it was carved for, and the free lists are per class and global.  A
;; thousand pools is a thousand BYTES of side table: sixteen cache lines,
;; permanently hot, and dense because pools are bump-carved in order.  Block
;; zero starts at the pool base, so every block is 16-aligned by construction
;; and `(offset & (POOL_SIZE-1)) % blocksize == 0` is an exact test for "this
;; is really the start of a block", which the checking build uses.
;;
;; The price is that a pool belongs to its class for life: a global free list
;; and pool recycling are mutually exclusive, because reclaiming a pool would
;; mean excising its blocks from a list that does not know where they came
;; from.  CPython's header exists to serve exactly that recycling.  Peak
;; memory becomes the sum over classes of each class's own peak rather than
;; the peak of the total; for a process that runs one script and exits, which
;; is every apython process, that is the right trade.  It also makes
;; ap_pool_szidx write-once, so a block's size is a stable property of its
;; address for the block's whole lifetime.
;; ============================================================================

;; --- size classes -----------------------------------------------------------
;; szidx = (n - 1) >> 4 for n in 1..512, and blocksize = (szidx + 1) << 4.
;; 16-byte alignment because that is what glibc gives today and what gc_alloc's
;; 16-byte head has to preserve.
AP_ALIGN         equ 16
AP_ALIGN_SHIFT   equ 4
AP_SMALL_MAX     equ 512                    ; inclusive; above this, libc
AP_NCLASSES      equ AP_SMALL_MAX / AP_ALIGN    ; 32

;; --- pools ------------------------------------------------------------------
AP_POOL_SHIFT    equ 14
AP_POOL_SIZE     equ 1 << AP_POOL_SHIFT     ; 16 KiB, CPython's POOL_SIZE
AP_LOCAL_MAX     equ 256                    ; per-thread free-list high-water mark
AP_BATCH         equ 128                    ; batch size for global spill/refill

;; --- the span ---------------------------------------------------------------
;; A ladder, biggest first.  MAP_NORESERVE is ignored under
;; vm.overcommit_memory=2, and RLIMIT_AS charges the whole reservation whatever
;; the flags say -- so a fixed gigabyte would turn a working build into "out of
;; memory" inside a container with `ulimit -v` set.  Any rung will do; none of
;; them means anything is wrong.
%ifdef AP_SPAN_TINY
AP_SPAN_TRY_0    equ 1 * 1024 * 1024        ; POOL_TINY=1: exhaust it on purpose
AP_SPAN_TRY_1    equ 1 * 1024 * 1024
AP_SPAN_TRY_2    equ 1 * 1024 * 1024
%else
AP_SPAN_TRY_0    equ 1024 * 1024 * 1024
AP_SPAN_TRY_1    equ  128 * 1024 * 1024
AP_SPAN_TRY_2    equ   16 * 1024 * 1024
%endif
AP_SPAN_MAX      equ 1024 * 1024 * 1024
AP_NPOOLS_MAX    equ AP_SPAN_MAX >> AP_POOL_SHIFT   ; 65536 bytes of side table

; ap_pool_szidx is sized from AP_SPAN_MAX and indexed by the pool number,
; which comes from whichever rung of the ladder was mapped.  Raising the first
; rung -- the obvious knob, three lines up -- without raising AP_SPAN_MAX
; would make ap_new_pool write past the end of that table and into whatever
; .bss follows it, with nothing wrong at the write and everything wrong later.
%if AP_SPAN_TRY_0 > AP_SPAN_MAX
%error "AP_SPAN_TRY_0 exceeds AP_SPAN_MAX: ap_pool_szidx would be indexed past its end"
%endif

;; Two pools of slop: one absorbs the alignment of the mmap base up to a pool
;; boundary, and one sits above the carve limit so that a word-at-a-time string
;; scanner reading past the last block of the last pool cannot walk off the
;; mapping.
AP_SPAN_SLOP     equ 2 * AP_POOL_SIZE

;; --- state ------------------------------------------------------------------
AP_UNINIT        equ 0
AP_ON            equ 1
AP_OFF           equ 2                      ; mmap failed, or switched off

;; --- mmap / madvise ---------------------------------------------------------
AP_PROT_READ     equ 1
AP_PROT_WRITE    equ 2
AP_MAP_PRIVATE   equ 0x02
AP_MAP_ANONYMOUS equ 0x20
AP_MAP_NORESERVE equ 0x4000
AP_MMAP_ERR_LIM  equ -4095                  ; a raw syscall answers -errno
AP_MADV_NOHUGEPAGE equ 15

section .text

;; ============================================================================
;; ap_span_create() -> rax = 1 if the pools are live, 0 if they never will be
;;
;; Runs at most once.  Everything about "is the allocator on" is decided here
;; and nowhere else, so the fast paths carry no test of their own -- an
;; all-zeroes table sends them down the cold path on its own.
;; ============================================================================
AS_WANT  equ 8              ; the span this rung is asking the kernel for
AS_FRAME equ 16             ; + 2 pushes = 32, 16-aligned
DEF_FUNC_LOCAL ap_span_create, AS_FRAME
    push rbx
    push r12

    mov eax, [rel ap_state]
    cmp eax, AP_UNINIT
    jne .asc_settled

%ifdef NO_POOL
    jmp .asc_off
%else
    ; APYTHON_MALLOC=libc switches the pools off without a rebuild, which is
    ; what a valgrind run wants: a block recycled through a free list is not a
    ; freed block, so every use-after-free in the interpreter would go
    ; invisible.  The Makefile's NO_INT_FREELIST paragraph says this about one
    ; type; this says it about all of them.
    CSTRING rdi, "APYTHON_MALLOC"
    extern getenv
    call getenv
    test rax, rax
    jz .asc_ladder
    mov rdi, rax
    CSTRING rsi, "libc"
    extern ap_strcmp
    call ap_strcmp
    test eax, eax
    jz .asc_off

.asc_ladder:
    ; Biggest first.  MAP_NORESERVE is ignored under vm.overcommit_memory=2,
    ; and RLIMIT_AS charges the whole reservation whatever the flags say, so a
    ; single fixed size would turn a working build into "out of memory" inside
    ; a container with `ulimit -v` set.  Any rung will do.
    xor r12d, r12d                          ; rung index
.asc_rung:
    cmp r12d, 3
    jae .asc_off
    lea rax, [rel ap_span_ladder]
    mov rbx, [rax + r12*8]
    inc r12d
    mov [rbp - AS_WANT], rbx

    lea rsi, [rbx + AP_SPAN_SLOP]           ; ask for the slop as well
    xor edi, edi                            ; let the kernel choose the address
    mov edx, AP_PROT_READ | AP_PROT_WRITE
    mov ecx, AP_MAP_PRIVATE | AP_MAP_ANONYMOUS | AP_MAP_NORESERVE
    mov r8, -1                              ; fd, ignored for anonymous
    xor r9d, r9d                            ; offset
    extern sys_mmap
    call sys_mmap
    cmp rax, AP_MMAP_ERR_LIM
    jae .asc_rung                           ; -errno, never -1; try the next

    ; A gigabyte of anonymous memory is transparent-hugepage eligible where
    ; THP is `always`, and then touching one 16 KiB pool would fault in two
    ; megabytes to back it.  Advice; a refusal changes nothing.
    mov rbx, rax                            ; the raw mapping
    mov rdi, rax
    mov rsi, [rbp - AS_WANT]
    add rsi, AP_SPAN_SLOP
    mov edx, AP_MADV_NOHUGEPAGE
    extern sys_madvise
    call sys_madvise

    ; Round the base up to a pool boundary -- that is what lets a block find
    ; its pool with a shift.  The slop above is what pays for it, and what
    ; keeps a word-at-a-time reader off the end of the mapping.
    lea rax, [rbx + AP_POOL_SIZE - 1]
    and rax, ~(AP_POOL_SIZE - 1)
    mov [rel ap_span_base], rax
    mov [rel ap_pool_next], rax
    mov rcx, [rbp - AS_WANT]
    add rax, rcx
    mov [rel ap_pool_end], rax
    ; LAST, and once.  Nothing may see a length before the base is right, and
    ; nothing may ever see it change again: see invariant 2 in the header.
    mov [rel ap_span_len], rcx

    mov dword [rel ap_state], AP_ON
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret
%endif

.asc_off:
    mov dword [rel ap_state], AP_OFF
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.asc_settled:
    xor eax, eax
    cmp dword [rel ap_state], AP_ON
    sete al
    pop r12
    pop rbx
    leave
    ret
END_FUNC ap_span_create

;; ============================================================================
;; ap_refill_or_new_pool(rdi = szidx) -> rax = 1 if that class now has room, else 0
;;
;; Cold, serialized by ap_global_lock.  First tries to pull up to AP_BATCH
;; blocks from ap_global_free[szidx] into the calling thread's local freelist;
;; otherwise carves a fresh 16 KiB pool off the span for this thread's bump ptr.
;; ============================================================================
DEF_FUNC_LOCAL ap_refill_or_new_pool
    push rbx
    push r12
    mov rbx, rdi                            ; szidx

    lea rdi, [rel ap_global_lock]
    extern rt_mutex_lock
    call rt_mutex_lock

    ; 1. Try refilling up to AP_BATCH blocks from ap_global_free[szidx].
    lea r12, [rel ap_global_free]
    mov rax, [r12 + rbx*8]
    test rax, rax
    jz .arnp_carve_pool

    ; Walk up to AP_BATCH nodes starting at head = rax.
    mov rdx, rax                            ; head
    mov rsi, rax                            ; tail
    mov ecx, 1
.arnp_take:
    cmp ecx, AP_BATCH
    jae .arnp_take_done
    mov r8, [rsi]
    test r8, r8
    jz .arnp_take_done
    mov rsi, r8
    inc ecx
    jmp .arnp_take
.arnp_take_done:
    mov r8, [rsi]                           ; remainder for ap_global_free
    mov [r12 + rbx*8], r8
    mov r10, [gs:ThreadState.ts_self]
    mov r9, [r10 + ThreadState.ts_sc_free + rbx*8]
    mov [rsi], r9
    mov [r10 + ThreadState.ts_sc_free + rbx*8], rdx
    add [r10 + ThreadState.ts_sc_free_count + rbx*4], ecx

    lea rdi, [rel ap_global_lock]
    extern rt_mutex_unlock
    call rt_mutex_unlock
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret

.arnp_carve_pool:
    cmp dword [rel ap_state], AP_ON
    je .arnp_have_span
    call ap_span_create
    test eax, eax
    jz .arnp_none

.arnp_have_span:
    mov rax, [rel ap_pool_next]
    lea rcx, [rax + AP_POOL_SIZE]
    cmp rcx, [rel ap_pool_end]
    ja .arnp_none                           ; span used up; libc from here on
    mov [rel ap_pool_next], rcx

    ; poolno = (pool - span_base) >> POOL_SHIFT.  Written once, never rewritten,
    ; which is what makes a block's size a property of its address.
    mov rdx, rax
    sub rdx, [rel ap_span_base]
    shr rdx, AP_POOL_SHIFT
    lea rsi, [rel ap_pool_szidx]
    mov [rsi + rdx], bl

    ; Hand the fresh pool to the calling thread's private bump pointer.
    mov r10, [gs:ThreadState.ts_self]
    mov [r10 + ThreadState.ts_sc_bump + rbx*8], rax
    mov [r10 + ThreadState.ts_sc_bump_end + rbx*8], rcx

    lea rdi, [rel ap_global_lock]
    call rt_mutex_unlock
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret

.arnp_none:
    lea rdi, [rel ap_global_lock]
    call rt_mutex_unlock
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC ap_refill_or_new_pool

;; ============================================================================
;; ap_spill_batch(rdi = szidx) -> nothing
;;
;; Cold.  Detaches AP_BATCH blocks from this thread's local freelist for szidx
;; and prepends them to ap_global_free[szidx] under ap_global_lock.
;; ============================================================================
DEF_FUNC_LOCAL ap_spill_batch
    push rbx
    push r12
    push r13
    sub rsp, 8
    mov rbx, rdi                            ; szidx
    mov r10, [gs:ThreadState.ts_self]
    mov r12, [r10 + ThreadState.ts_sc_free + rbx*8] ; head of batch
    test r12, r12
    jz .asb_done

    mov r13, r12                            ; tail of batch
    mov ecx, 1
.asb_walk:
    cmp ecx, AP_BATCH
    jae .asb_cut
    mov rax, [r13]
    test rax, rax
    jz .asb_cut
    mov r13, rax
    inc ecx
    jmp .asb_walk
.asb_cut:
    mov rax, [r13]                          ; remainder stays local
    mov [r10 + ThreadState.ts_sc_free + rbx*8], rax
    sub [r10 + ThreadState.ts_sc_free_count + rbx*4], ecx

    lea rdi, [rel ap_global_lock]
    call rt_mutex_lock
    lea rax, [rel ap_global_free]
    mov rdx, [rax + rbx*8]
    mov [r13], rdx
    mov [rax + rbx*8], r12
    lea rdi, [rel ap_global_lock]
    call rt_mutex_unlock

.asb_done:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC ap_spill_batch

;; ============================================================================
;; ap_block_size(rdi = ptr) -> rax = the block's size, or 0 if it is not ours
;;
;; For the self-test and the checking build.  This is a property of the
;; ADDRESS: because a pool never changes class, the answer is the same for as
;; long as the block exists, and the same again if the address is handed out
;; anew.
;; ============================================================================
global ap_block_size
DEF_FUNC_BARE ap_block_size
    mov rax, rdi
    sub rax, [rel ap_span_base]
    cmp rax, [rel ap_span_len]
    jae .abs_not_ours
    shr rax, AP_POOL_SHIFT
    lea rcx, [rel ap_pool_szidx]
    movzx eax, byte [rcx + rax]
    inc eax
    shl eax, AP_ALIGN_SHIFT
    ret
.abs_not_ours:
    xor eax, eax
    ret
END_FUNC ap_block_size

;; ============================================================================
;; ap_malloc(rdi = size) -> rax = a block of at least that many bytes
;;
;; Never returns NULL: out of memory is fatal_error.  16-byte aligned.
;; Lock-free per-thread fast path (zero gs: stores via ts_self base reg).
;; ============================================================================
DEF_FUNC_BARE ap_malloc
%ifndef NO_POOL
    lea rax, [rdi - 1]
    cmp rax, AP_SMALL_MAX - 1
    ja .aml_big
    shr rax, AP_ALIGN_SHIFT                 ; szidx
    mov r10, [gs:ThreadState.ts_self]
    lea rcx, [r10 + ThreadState.ts_sc_free + rax*8]
    mov rdx, [rcx]
    test rdx, rdx
    jz .aml_carve
    mov r8, [rdx]
    mov [rcx], r8
    dec dword [r10 + ThreadState.ts_sc_free_count + rax*4]
    inc qword [r10 + ThreadState.ts_alloc_live]
    mov rax, rdx
    ret

.aml_carve:
    lea rdx, [rax + 1]
    shl rdx, AP_ALIGN_SHIFT                 ; blocksize
    lea rcx, [r10 + ThreadState.ts_sc_bump + rax*8]
    mov r8, [rcx]
    lea r9, [r8 + rdx]
    cmp r9, [r10 + ThreadState.ts_sc_bump_end + rax*8]
    ja .aml_newpool                         ; also the uninitialised case
    mov [rcx], r9
    inc qword [r10 + ThreadState.ts_alloc_live]
    mov rax, r8
    ret

.aml_newpool:
    push rbp
    mov rbp, rsp
    push rdi
    push rdi                                ; 16-byte aligned
    mov rdi, rax                            ; szidx
    call ap_refill_or_new_pool
    pop rdi
    pop rdi
    pop rbp
    test eax, eax
    jz .aml_libc
    jmp ap_malloc

.aml_big:
    test rdi, rdi
    jnz .aml_libc
    mov edi, AP_ALIGN
    jmp ap_malloc
%endif

.aml_libc:
    push rbp
    mov rbp, rsp
    call malloc wrt ..plt
    test rax, rax
    jz .aml_oom
    mov r10, [gs:ThreadState.ts_self]
    inc qword [r10 + ThreadState.ts_alloc_live]
    pop rbp
    ret
.aml_oom:
    lea rdi, [rel ap_oom_msg]
    call fatal_error        ; never returns
END_FUNC ap_malloc

;; ============================================================================
;; ap_free(rdi = ptr) -> void
;;
;; NULL-safe.  Lock-free push onto this thread's size-class freelist (valid
;; for any pool block allocated by any thread because pools are class-for-life).
;; Spills AP_BATCH blocks to ap_global_free once local count hits AP_LOCAL_MAX.
;; ============================================================================
DEF_FUNC_BARE ap_free
    test rdi, rdi
    jz .afr_done
    mov r10, [gs:ThreadState.ts_self]
    dec qword [r10 + ThreadState.ts_alloc_live]
%ifndef NO_POOL
    mov rax, rdi
    sub rax, [rel ap_span_base]
    cmp rax, [rel ap_span_len]
    jae .afr_libc
    shr rax, AP_POOL_SHIFT
    lea rcx, [rel ap_pool_szidx]
    movzx eax, byte [rcx + rax]             ; szidx
    lea rcx, [r10 + ThreadState.ts_sc_free + rax*8]
    mov rdx, [rcx]
    mov [rdi], rdx
    mov [rcx], rdi
    mov edx, [r10 + ThreadState.ts_sc_free_count + rax*4]
    inc edx
    mov [r10 + ThreadState.ts_sc_free_count + rax*4], edx
    cmp edx, AP_LOCAL_MAX
    jae .afr_spill
    ret
.afr_spill:
    mov rdi, rax
    jmp ap_spill_batch
.afr_libc:
%endif
    jmp free wrt ..plt
.afr_done:
    ret
END_FUNC ap_free

;; ============================================================================
;; ap_live_blocks() -> rax = blocks handed out and not yet freed
;;
;; O(num_threads): sums ap_exited_live + ts_alloc_live across all live
;; ThreadStates under tstate_list_lock.
;; ============================================================================
DEF_FUNC ap_live_blocks
    push rbx
    sub rsp, 8
    extern tstate_list_lock
    extern tstate_list_head
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_lock
    mov rbx, [rel ap_exited_live]
    mov rax, [rel tstate_list_head]
.alb_loop:
    test rax, rax
    jz .alb_done
    add rbx, [rax + ThreadState.ts_alloc_live]
    mov rax, [rax + ThreadState.ts_next]
    jmp .alb_loop
.alb_done:
    lea rdi, [rel tstate_list_lock]
    call rt_mutex_unlock
    mov rax, rbx
    add rsp, 8
    pop rbx
    leave
    ret
END_FUNC ap_live_blocks

;; ============================================================================
;; alloc_thread_flush() -> nothing
;;
;; Called by a worker thread during exit before tstate_unlink: drains all five
;; per-thread object freelists, then returns all cached local pool blocks and
;; unused bump-pointer tail blocks to ap_global_free under ap_global_lock.
;; ============================================================================
global alloc_thread_flush
DEF_FUNC alloc_thread_flush
    push rbx
    push r12
    push r13
    sub rsp, 8

    extern frame_pool_drain
    extern int_freelist_drain
    extern list_pool_drain
    extern slice_pool_drain
    extern tuple_pool_drain
    call frame_pool_drain
    call int_freelist_drain
    call list_pool_drain
    call slice_pool_drain
    call tuple_pool_drain

    lea rdi, [rel ap_global_lock]
    call rt_mutex_lock

    mov r12, [gs:ThreadState.ts_self]
    lea r13, [rel ap_global_free]
    xor ebx, ebx                            ; szidx = 0..AP_NCLASSES-1
.atf_class:
    cmp ebx, AP_NCLASSES
    jae .atf_done

    ; Move ts_sc_free[szidx] list to ap_global_free[szidx].
    mov rax, [r12 + ThreadState.ts_sc_free + rbx*8]
    test rax, rax
    jz .atf_bump
    mov rcx, rax
.atf_tail:
    mov rdx, [rcx]
    test rdx, rdx
    jz .atf_link
    mov rcx, rdx
    jmp .atf_tail
.atf_link:
    mov rdx, [r13 + rbx*8]
    mov [rcx], rdx
    mov [r13 + rbx*8], rax
    mov qword [r12 + ThreadState.ts_sc_free + rbx*8], 0
    mov dword [r12 + ThreadState.ts_sc_free_count + rbx*4], 0

.atf_bump:
    ; Carve remaining virgin blocks from [ts_sc_bump, ts_sc_bump_end) into
    ; ap_global_free[szidx] so short-lived threads never strand pool space.
    mov rax, [r12 + ThreadState.ts_sc_bump + rbx*8]
    mov rcx, [r12 + ThreadState.ts_sc_bump_end + rbx*8]
    lea rdx, [rbx + 1]
    shl rdx, AP_ALIGN_SHIFT                 ; blocksize
.atf_carve:
    lea rsi, [rax + rdx]
    cmp rsi, rcx
    ja .atf_bump_done
    mov r8, [r13 + rbx*8]
    mov [rax], r8
    mov [r13 + rbx*8], rax
    mov rax, rsi
    jmp .atf_carve
.atf_bump_done:
    mov qword [r12 + ThreadState.ts_sc_bump + rbx*8], 0
    mov qword [r12 + ThreadState.ts_sc_bump_end + rbx*8], 0

    inc ebx
    jmp .atf_class

.atf_done:
    lea rdi, [rel ap_global_lock]
    call rt_mutex_unlock
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC alloc_thread_flush

;; ============================================================================
;; alloc_reset_after_fork() -> nothing
;;
;; Reset allocator mutex in a forked child.
;; ============================================================================
global alloc_reset_after_fork
DEF_FUNC_BARE alloc_reset_after_fork
    mov dword [rel ap_global_lock], 0
    ret
END_FUNC alloc_reset_after_fork

;; ============================================================================
;; ap_realloc(rdi = ptr, rsi = size) -> rax = the resized block
;;
;; ap_realloc(NULL, n) is malloc(n), which src/compiler/ast.asm's Buf grower
;; relies on.  Never returns NULL, as ap_malloc does not.
;;
;; The old size is not passed and does not need to be: a pool never changes
;; class, so the block's size is a property of its address.  When the new size
;; still fits the block it already has -- every shrink, and every growth inside
;; one class -- this hands back the same pointer and copies nothing.
;; ============================================================================
DEF_FUNC_BARE ap_realloc
    test rdi, rdi
    jz .arl_as_malloc
%ifndef NO_POOL
    test rsi, rsi
    jnz .arl_sized
    mov esi, 1                              ; realloc(p, 0) must not answer NULL
.arl_sized:
    mov rax, rdi
    sub rax, [rel ap_span_base]
    cmp rax, [rel ap_span_len]
    jae .arl_libc                           ; a libc block stays a libc block:
                                            ; we cannot know how much to copy
    shr rax, AP_POOL_SHIFT
    lea rcx, [rel ap_pool_szidx]
    movzx ecx, byte [rcx + rax]
    inc ecx
    shl ecx, AP_ALIGN_SHIFT                 ; the block it already has
    cmp rsi, rcx
    jbe .arl_same

    push rbp
    mov rbp, rsp
    push rbx
    push r12                                ; 2 pushes, so the calls are aligned
    mov rbx, rdi                            ; the old block
    mov r12, rcx                            ; ...and its size
    mov rdi, rsi
    call ap_malloc                          ; small -> a pool, large -> libc
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12                            ; the whole old BLOCK, so no min()
    extern ap_memcpy
    call ap_memcpy
    mov r12, rax
    mov rdi, rbx
    call ap_free
    mov rax, r12
    pop r12
    pop rbx
    pop rbp
    ret

.arl_same:
    mov rax, rdi
    ret

.arl_libc:
%endif
    push rbp
    mov rbp, rsp
    call realloc wrt ..plt
    test rax, rax
    jz .arl_oom
    pop rbp
    ret
.arl_as_malloc:
    mov rdi, rsi
    jmp ap_malloc
.arl_oom:
    lea rdi, [rel ap_oom_msg]
    call fatal_error        ; never returns
END_FUNC ap_realloc

section .rodata
ap_oom_msg: db "Fatal: out of memory", 0


;; ============================================================================
;; The span, and the three words the fast paths read.
;;
;; Adjacent and first, because ap_free loads two of them on every call and one
;; cache line is one miss rather than two.
;; ============================================================================
section .data
align 64
ap_span_base:  dq 0         ; base of the pool-aligned span; 0 while there is none
ap_span_len:   dq 0         ; usable bytes.  WRITE-ONCE.  NEVER CLEARED.
ap_pool_next:  dq 0         ; the next pool to carve
ap_pool_end:   dq 0         ; span_base + span_len
ap_state:      dd AP_UNINIT

align 8
ap_span_ladder:
    dq AP_SPAN_TRY_0
    dq AP_SPAN_TRY_1
    dq AP_SPAN_TRY_2

section .bss
alignb 64
; Global allocator lock (32-bit futex) guarding span creation, pool carving,
; and ap_global_free batch spill/refill.
ap_global_lock:  resd 1
                 resb 60
; Global overflow free lists per size class (filled by AP_BATCH spills and
; exiting thread flushes).
ap_global_free:  resq AP_NCLASSES
alignb 64
; Residual live-block delta folded in by exited threads under tstate_list_lock.
global ap_exited_live
ap_exited_live:  resq 1

;; One byte per pool saying which size class it was carved for.  Demand-zero,
;; and only the pages for pools that actually exist are ever touched -- they
;; are dense, because pools are carved in address order.
alignb 64
ap_pool_szidx:   resb AP_NPOOLS_MAX
