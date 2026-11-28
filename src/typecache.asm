; typecache.asm - one answer for "what does this class call that name?"
;
; Resolving an attribute through a class means walking its MRO and probing
; each tp_dict, and MRO_NEXT is an out-of-line call to type_mro_next -- so a
; lookup of depth d costs d function calls and d hash-and-probes.  Nothing
; about the answer changes between two lookups unless the class or one of its
; bases is written to, and tp_version already says exactly that: it is stamped
; fresh by type_refresh_attr_flags, which runs at class creation and from
; type_setattr and pushes its answer down every subclass.
;
; So the cache needs no invalidation of its own.  A stale entry fails the
; version compare and is simply overwritten; there is no list to walk when a
; class changes and no way to miss one.  Versions come from a single global
; counter, so an entry can never be matched by a different class that happens
; to reuse a freed address.
;
; A profile of an attribute-heavy object benchmark put 32% of its instructions
; in dict_lookup and 8% in type_mro_next, nearly all of it reached from this
; walk -- and that benchmark's classes carry a property, which sets
; TYPE_FLAG_MRO_HAS_DATA_DESCR and so forces the descriptor-first order on
; every attribute, not just the one that is a descriptor.
;
; Only a type that HAS a version is cached, which means heap types.  A static
; type reads zero there and keeps walking: its dict is filled during startup
; by methods/init.asm, in writes that go nowhere near type_setattr, so a
; version handed out before that finished would be a promise the tree does not
; keep.  Giving the builtins versions is worth doing and wants an explicit
; "startup is over" point to do it at.

%include "macros.inc"
%include "object.inc"

extern dict_get_mro
extern dict_get
extern type_mro_next
extern obj_decref

; 2048 entries, direct mapped.  A collision misses and does the walk, which is
; what the code did unconditionally before, so a bad hash costs nothing that
; was not already being paid.
;; A POWER OF TWO, because the index is taken with `and rcx, TC_MASK`.  1024
;; rather than the old 2048 so the array is 64 KB where it was 96 KB: the
;; entries got wider, and a collision costs the MRO walk this cache replaced,
;; which is what the code did unconditionally before it existed.
TC_SLOTS     equ 1024
TC_MASK      equ TC_SLOTS - 1
TC_VERSION   equ 0              ; 0 marks a slot that has never been filled
TC_TYPE      equ 8
TC_NAME      equ 16             ; OWNED -- see the note in type_lookup_cached
TC_VALUE     equ 24             ; the Value dict_get returned, borrowed
TC_TAG       equ 32             ; 0 means "this class does not define it"
TC_OWNER     equ 40             ; the MRO entry whose dict answered
;; 64, not the 48 the six fields need.  gcd(48, 64) is 16, so entries at a
;; 48-byte stride start at offsets {0, 48, 32, 16} mod 64 and EXACTLY HALF of
;; them spanned two cache lines -- every one of those hits cost two line
;; fetches to read six words that fit in one.  At 64 an entry is a line, the
;; index is a shift instead of a multiply, and TC_SLOTS falls to keep the
;; array no larger than it was.
TC_ENTRY     equ 64
TC_SHIFT     equ 6              ; log2(TC_ENTRY)
TC_LOCK_CNT  equ 64             ; 64 cache-line-padded bucket locks
TC_LOCK_MASK equ TC_LOCK_CNT - 1
TC_LOCK_STRIDE equ 64

; Acquire/release the bucket lock for slot index in %1 (not rax/rdi).
; Preserves all registers; no-op while rt_threaded == 0.
%macro TC_LOCK_SLOT 1
    extern rt_threaded
    cmp byte [rel rt_threaded], 0
    je %%skip
    push rdi
    push rax
    mov rdi, %1
    and rdi, TC_LOCK_MASK
    shl rdi, 6
    lea rax, [rel type_cache_locks]
    add rdi, rax
    extern rt_mutex_lock_p
    call rt_mutex_lock_p
    pop rax
    pop rdi
%%skip:
%endmacro

%macro TC_UNLOCK_SLOT 1
    extern rt_threaded
    cmp byte [rel rt_threaded], 0
    je %%skip
    push rdi
    push rax
    mov rdi, %1
    and rdi, TC_LOCK_MASK
    shl rdi, 6
    lea rax, [rel type_cache_locks]
    add rdi, rax
    extern rt_mutex_unlock_p
    call rt_mutex_unlock_p
    pop rax
    pop rdi
%%skip:
%endmacro

section .bss
align 64
type_cache: resb TC_SLOTS * TC_ENTRY
align 64
type_cache_locks: resb TC_LOCK_CNT * TC_LOCK_STRIDE

section .text

;; ============================================================================
;; type_cache_quiesce() -> nothing
;;
;; Barrier for type_setattr in free-threaded mode: after bumping tp_version,
;; acquire and release each of the 64 bucket locks so every concurrent reader
;; that observed the old version has finished INCREFing its cached value
;; before tp_dict mutation can DECREF/free the displaced entry.
;; ============================================================================
global type_cache_quiesce
DEF_FUNC type_cache_quiesce
    extern rt_threaded
    cmp byte [rel rt_threaded], 0
    je .tcq_done
    push rbx
    push r12
    lea rbx, [rel type_cache_locks]
    xor r12d, r12d
.tcq_loop:
    cmp r12d, TC_LOCK_CNT
    jae .tcq_out
    mov rdi, rbx
    extern rt_mutex_lock_p
    call rt_mutex_lock_p
    mov rdi, rbx
    extern rt_mutex_unlock_p
    call rt_mutex_unlock_p
    add rbx, TC_LOCK_STRIDE
    inc r12d
    jmp .tcq_loop
.tcq_out:
    pop r12
    pop rbx
.tcq_done:
    leave
    ret
END_FUNC type_cache_quiesce

;; ============================================================================
;; type_cache_clear() -> nothing
;;
;; Empty every slot.  The cache is an invisible optimisation, so a test that
;; changes a class and asks whether the change took effect has to be able to
;; empty it -- test_type_cache and test_descr both call sys._clear_type_cache,
;; and there was no way to.
;;
;; TC_NAME is the one OWNED field, so it is released rather than just
;; overwritten; zeroing TC_VERSION is what makes a slot unused, and the rest
;; is never read once it is.
;; ============================================================================
DEF_FUNC type_cache_clear
    push rbx
    push r12
    lea rbx, [rel type_cache]
    xor r12d, r12d
.tcc_loop:
    cmp r12, TC_SLOTS
    jge .tcc_done
    TC_LOCK_SLOT r12
    mov rax, r12
    shl rax, TC_SHIFT
    add rax, rbx
    xor edi, edi
    cmp qword [rax + TC_VERSION], 0
    je .tcc_unlock
    mov qword [rax + TC_VERSION], 0
    mov rdi, [rax + TC_NAME]
    mov qword [rax + TC_NAME], 0
.tcc_unlock:
    TC_UNLOCK_SLOT r12
    test rdi, rdi
    jz .tcc_next
    call obj_decref
.tcc_next:
    inc r12
    jmp .tcc_loop
.tcc_done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_cache_clear

;; ============================================================================
;; type_lookup_cached(rdi = a type, rsi = an interned name)
;;   -> rax = the payload (owned), edx = the tag (0 = not found), rcx = the owner
;;
;; What the MRO walk it replaces returns, and in the same registers: the value
;; found in the first tp_dict along the MRO that has the name, and the type
;; whose dict that was.  The reference is OWNED.
;;
;; A negative answer is cached too.  "This class has no __iter__" is asked as
;; often as any positive lookup and costs a full walk to establish.
;; ============================================================================
TLC_TYPE    equ 8
TLC_NAME    equ 16
TLC_SLOT    equ 24
TLC_VER     equ 32
TLC_OLDNAME equ 40              ; the name this fill displaces, to release
TLC_RESVAL  equ 48              ; the answer, across that release
TLC_RESTAG  equ 56
TLC_RESOWN  equ 64
TLC_IDX     equ 72              ; slot index (0..TC_SLOTS-1) for bucket lock
TLC_FRAME   equ 88              ; 88 + 3 pushes keeps rsp 16-aligned

DEF_FUNC type_lookup_cached, TLC_FRAME
    push rbx
    push r12
    push r13

    mov rbx, rdi                        ; the type
    mov r12, rsi                        ; the name
    mov [rbp - TLC_TYPE], rdi
    mov [rbp - TLC_NAME], rsi

    ; Quick unversioned check (static types have version 0).
    mov rax, [rdi + PyTypeObject.tp_flags]
    shr rax, TYPE_VERSION_SHIFT
    test eax, eax
    jz .tlc_walk_only

    ; slot = (type >> 4) ^ (name >> 4), folded
    mov rcx, rdi
    shr rcx, 4
    mov rdx, rsi
    shr rdx, 4
    imul rcx, rcx, 31
    xor rcx, rdx
    and rcx, TC_MASK
    mov [rbp - TLC_IDX], rcx
    mov r8, rcx                         ; r8 = slot index
    shl rcx, TC_SHIFT
    lea r13, [rel type_cache]
    add r13, rcx
    mov [rbp - TLC_SLOT], r13

    ; Lock bucket, read live tp_version under lock, and test hit.
    ; Holding the bucket lock across version read + INCREF pairs with
    ; type_cache_quiesce() in type_setattr so TC_VALUE cannot be freed
    ; while a reader with a matching version is INCREFing it.
    TC_LOCK_SLOT r8
    mov rax, [rbx + PyTypeObject.tp_flags]
    shr rax, TYPE_VERSION_SHIFT
    test eax, eax
    jz .tlc_unlock_walk_only
    mov [rbp - TLC_VER], rax

    cmp [r13 + TC_VERSION], rax
    jne .tlc_miss_unlock
    cmp [r13 + TC_TYPE], rbx
    jne .tlc_miss_unlock
    cmp [r13 + TC_NAME], r12
    jne .tlc_miss_unlock
    mov rax, [r13 + TC_VALUE]
    mov edx, [r13 + TC_TAG]
    INCREF_VAL rax, edx
    mov rcx, [r13 + TC_OWNER]
    TC_UNLOCK_SLOT r8
    jmp .tlc_out

.tlc_unlock_walk_only:
    TC_UNLOCK_SLOT r8
    jmp .tlc_walk_only

.tlc_miss_unlock:
    TC_UNLOCK_SLOT r8
    call tc_walk                        ; rax/edx = owned value, rcx = owner
    mov [rbp - TLC_RESVAL], rax
    mov [rbp - TLC_RESTAG], edx
    mov [rbp - TLC_RESOWN], rcx
    mov r13, [rbp - TLC_SLOT]
    mov r8, [rbp - TLC_IDX]
    mov qword [rbp - TLC_OLDNAME], 0

    ; Re-lock bucket and verify tp_version did not change during tc_walk.
    TC_LOCK_SLOT r8
    mov r9, [rbx + PyTypeObject.tp_flags]
    shr r9, TYPE_VERSION_SHIFT
    cmp r9, [rbp - TLC_VER]
    jne .tlc_skip_fill

    mov rax, [rbp - TLC_RESVAL]
    mov edx, [rbp - TLC_RESTAG]
    mov rcx, [rbp - TLC_RESOWN]
    mov [r13 + TC_VALUE], rax
    mov [r13 + TC_TAG], edx
    mov [r13 + TC_OWNER], rcx
    mov [r13 + TC_TYPE], rbx

    mov r10, [r13 + TC_NAME]
    mov [rbp - TLC_OLDNAME], r10
    INCREF r12
    mov [r13 + TC_NAME], r12
    mov [r13 + TC_VERSION], r9

.tlc_skip_fill:
    TC_UNLOCK_SLOT r8
    mov rdi, [rbp - TLC_OLDNAME]
    test rdi, rdi
    jz .tlc_filled
    call obj_decref
.tlc_filled:
    mov rax, [rbp - TLC_RESVAL]
    mov edx, [rbp - TLC_RESTAG]
    mov rcx, [rbp - TLC_RESOWN]
    jmp .tlc_out

.tlc_walk_only:
    call tc_walk

.tlc_out:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_lookup_cached

;; ============================================================================
;; tc_walk() -> rax = the payload, edx = the tag, rcx = the owner
;;
;; The MRO walk itself, over the type and name type_lookup_cached parked in
;; its frame.  Only callable from there.
;; ============================================================================
DEF_FUNC_BARE tc_walk
    push rbx
    push r12
    push r14                            ; three, so rsp is 16-aligned at the
                                        ; calls below
    mov rbx, [rbp - TLC_TYPE]           ; the walker
    mov r14, rbx                        ; the origin the MRO is read from
    mov r12, [rbp - TLC_NAME]

.tcw_loop:
    test rbx, rbx
    jz .tcw_not_found
    mov rdi, [rbx + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .tcw_next
    mov rsi, r12
    call dict_get_mro
    V_UNPACK rax, rdx
    test edx, edx
    jnz .tcw_found
.tcw_next:
    mov rdi, r14
    mov rsi, rbx
    call type_mro_next
    mov rbx, rax
    jmp .tcw_loop

.tcw_found:
    mov rcx, rbx                        ; the dict that answered
    pop r14
    pop r12
    pop rbx
    ret

.tcw_not_found:
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
    pop r14
    pop r12
    pop rbx
    ret
END_FUNC tc_walk
