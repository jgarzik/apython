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
;; ap_new_pool(rdi = szidx) -> rax = 1 if that class now has room, else 0
;;
;; Cold.  Carves one pool off the span and gives it to a single size class for
;; the life of the process; the file header says why it is never taken back.
;; ============================================================================
DEF_FUNC_LOCAL ap_new_pool, 8               ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, rdi                            ; szidx

    cmp dword [rel ap_state], AP_ON
    je .anp_have_span
    call ap_span_create
    test eax, eax
    jz .anp_none

.anp_have_span:
    mov rax, [rel ap_pool_next]
    lea rcx, [rax + AP_POOL_SIZE]
    cmp rcx, [rel ap_pool_end]
    ja .anp_none                            ; span used up; libc from here on
    mov [rel ap_pool_next], rcx

    ; poolno = (pool - span_base) >> POOL_SHIFT.  Written once, never rewritten,
    ; which is what makes a block's size a property of its address.
    mov rdx, rax
    sub rdx, [rel ap_span_base]
    shr rdx, AP_POOL_SHIFT
    lea rsi, [rel ap_pool_szidx]
    mov [rsi + rdx], bl

    ; The class bumps through the pool from its base.  The carve test is
    ; `bump + blocksize > end`, so the remainder that does not divide evenly is
    ; simply never handed out and there is no modulo anywhere.
    lea rsi, [rel ap_sc_bump]
    mov [rsi + rbx*8], rax
    lea rsi, [rel ap_sc_bump_end]
    mov [rsi + rbx*8], rcx

    mov eax, 1
    pop rbx
    leave
    ret

.anp_none:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ap_new_pool

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
;; Never returns NULL: out of memory is fatal_error, which is why no call site
;; in the tree has a failure path.  16-byte aligned, as glibc's is.
;;
;; The fast path is twelve instructions, two loads, one store, no call and no
;; frame.  glibc's tcache path is about forty-five, plus a PLT thunk, a TLS
;; access and a call/ret pair.
;; ============================================================================
DEF_FUNC_BARE ap_malloc
%ifndef NO_POOL
    ; size - 1 does double duty: it is the class index once shifted, and its
    ; wraparound at size 0 sends a zero request to the same place a huge one
    ; goes, so neither needs a test of its own.
    lea rax, [rdi - 1]
    cmp rax, AP_SMALL_MAX - 1
    ja .aml_big
    shr rax, AP_ALIGN_SHIFT                 ; szidx
    lea rcx, [rel ap_sc_free]
    lea rcx, [rcx + rax*8]                  ; RIP-relative addressing has no
                                            ; SIB byte, so [rel sym + reg*8]
                                            ; does not exist; two lea do
    mov rdx, [rcx]
    test rdx, rdx
    jz .aml_carve
    ; The link lives in the dead block's own first eight bytes, so there is no
    ; per-block header and the pointer handed back IS the block.
    mov rax, [rdx]
    mov [rcx], rax
    mov rax, rdx
    ret

.aml_carve:
    ; Nothing on the free list, so take a virgin block off this class's pool.
    ; An all-zeroes table -- which is what "the allocator has not started yet"
    ; looks like -- fails the test below and falls through to the cold path,
    ; so the fast path needs no is-it-initialised check anywhere.
    lea rdx, [rax + 1]
    shl rdx, AP_ALIGN_SHIFT                 ; blocksize
    lea rcx, [rel ap_sc_bump]
    lea rcx, [rcx + rax*8]
    mov r8, [rcx]
    lea r9, [r8 + rdx]
    lea rdx, [rel ap_sc_bump_end]
    cmp r9, [rdx + rax*8]
    ja .aml_newpool                         ; also the uninitialised case
    mov [rcx], r9
    inc qword [rel ap_carved]               ; once per block, ever: see
    mov rax, r8                             ; ap_live_blocks
    ret

.aml_newpool:
    push rbp
    mov rbp, rsp
    push rdi
    push rdi                                ; the pair keeps rsp 16-aligned
    mov rdi, rax                            ; szidx
    call ap_new_pool
    pop rdi
    pop rdi
    pop rbp
    test eax, eax
    jz .aml_libc
    jmp ap_malloc                           ; the carve above now succeeds, and
                                            ; cannot fail twice: a pool holds
                                            ; at least one block of any class

.aml_big:
    ; A zero request still has to answer with something unique and freeable,
    ; because that is what malloc(0) does and what list_new_from leans on.
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
    inc qword [rel ap_libc_live]
    pop rbp
    ret
.aml_oom:
    lea rdi, [rel ap_oom_msg]
    call fatal_error        ; never returns
END_FUNC ap_malloc

;; ============================================================================
;; ap_free(rdi = ptr) -> void
;;
;; NULL-safe.  Fifteen instructions, no call and no frame, and -- unlike every
;; other scheme that has to decide whether a pointer is its own -- no load from
;; the page being freed.
;; ============================================================================
DEF_FUNC_BARE ap_free
    test rdi, rdi
    jz .afr_done
%ifndef NO_POOL
    ; One subtraction answers two questions: whether the block is ours, and
    ; which pool it is in.
    mov rax, rdi
    sub rax, [rel ap_span_base]
    cmp rax, [rel ap_span_len]
    jae .afr_libc
    shr rax, AP_POOL_SHIFT
    lea rcx, [rel ap_pool_szidx]
    movzx eax, byte [rcx + rax]
    lea rcx, [rel ap_sc_free]
    lea rcx, [rcx + rax*8]
    mov rdx, [rcx]
    mov [rdi], rdx
    mov [rcx], rdi
    ret
.afr_libc:
%endif
    dec qword [rel ap_libc_live]
    jmp free wrt ..plt
.afr_done:
    ret
END_FUNC ap_free

;; ============================================================================
;; ap_live_blocks() -> rax = blocks handed out and not yet freed
;;
;; sys.getallocatedblocks().  What a leak test reads: run an operation in a
;; loop and the number must not climb.  It costs the allocator's fast paths
;; nothing -- the count is DERIVED: every pool block ever carved, less the
;; ones sitting on a free list (walked here, which is the whole cost), plus
;; the blocks libc is holding for us.  A block parked on a freelist above
;; the allocator -- the int freelist, a frame region -- counts as live, which
;; is why a test warms up before it takes its first reading.
;; ============================================================================
DEF_FUNC_BARE ap_live_blocks
    mov rax, [rel ap_carved]
    add rax, [rel ap_libc_live]
    lea rcx, [rel ap_sc_free]
    xor edx, edx
.alb_class:
    mov rsi, [rcx + rdx*8]
.alb_walk:
    test rsi, rsi
    jz .alb_next
    dec rax
    mov rsi, [rsi]
    jmp .alb_walk
.alb_next:
    inc edx
    cmp edx, AP_NCLASSES
    jb .alb_class
    ret
END_FUNC ap_live_blocks

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
%ifndef NO_POOL
    test rdi, rdi
    jz .arl_as_malloc
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

.arl_as_malloc:
    mov rdi, rsi
    jmp ap_malloc
.arl_libc:
%endif
    push rbp
    mov rbp, rsp
    call realloc wrt ..plt
    test rax, rax
    jz .arl_oom
    pop rbp
    ret
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
align 64
;; Per size class: the free list, and the virgin high-water mark inside the
;; class's current pool.  Three flat arrays rather than one array of records,
;; so the class index IS the offset and no multiply is needed.
ap_sc_free:      resq AP_NCLASSES
align 64
ap_sc_bump:      resq AP_NCLASSES
ap_sc_bump_end:  resq AP_NCLASSES

;; One byte per pool saying which size class it was carved for.  Demand-zero,
;; and only the pages for pools that actually exist are ever touched -- they
;; are dense, because pools are carved in address order.
align 64
ap_pool_szidx:   resb AP_NPOOLS_MAX
ap_carved:       resq 1                     ; pool blocks carved, ever
ap_libc_live:    resq 1                     ; libc blocks out now
