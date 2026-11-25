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

section .bss
align 64
type_cache: resb TC_SLOTS * TC_ENTRY

section .text

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
    mov rax, r12
    shl rax, TC_SHIFT
    add rax, rbx
    cmp qword [rax + TC_VERSION], 0
    je .tcc_next
    mov qword [rax + TC_VERSION], 0
    mov rdi, [rax + TC_NAME]
    test rdi, rdi
    jz .tcc_next
    mov qword [rax + TC_NAME], 0
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
;;   -> rax = the payload, edx = the tag (0 = not found), rcx = the owner
;;
;; What the MRO walk it replaces returns, and in the same registers: the value
;; found in the first tp_dict along the MRO that has the name, and the type
;; whose dict that was.  The reference is BORROWED, exactly as dict_get's is.
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
TLC_FRAME   equ 88              ; 88 + 3 pushes keeps rsp 16-aligned

DEF_FUNC type_lookup_cached, TLC_FRAME
    push rbx
    push r12
    push r13

    mov rbx, rdi                        ; the type
    mov r12, rsi                        ; the name
    mov [rbp - TLC_TYPE], rdi
    mov [rbp - TLC_NAME], rsi

    ; A type with no version cannot be cached; walk and answer.
    mov rax, [rdi + PyTypeObject.tp_flags]
    shr rax, TYPE_VERSION_SHIFT
    test eax, eax
    jz .tlc_walk_only
    mov [rbp - TLC_VER], rax

    ; slot = (type >> 4) ^ (name >> 4), folded
    mov rcx, rdi
    shr rcx, 4
    mov rdx, rsi
    shr rdx, 4
    imul rcx, rcx, 31
    xor rcx, rdx
    and rcx, TC_MASK
    shl rcx, TC_SHIFT
    lea r13, [rel type_cache]
    add r13, rcx
    mov [rbp - TLC_SLOT], r13

    ; A hit is all three of the version, the type and the name.
    mov rcx, [rbp - TLC_VER]
    cmp [r13 + TC_VERSION], rcx
    jne .tlc_miss
    cmp [r13 + TC_TYPE], rbx
    jne .tlc_miss
    cmp [r13 + TC_NAME], r12
    jne .tlc_miss
    mov rax, [r13 + TC_VALUE]
    mov edx, [r13 + TC_TAG]
    mov rcx, [r13 + TC_OWNER]
    jmp .tlc_out

.tlc_miss:
    call tc_walk                        ; rax/edx = value, rcx = owner
    mov r13, [rbp - TLC_SLOT]
    mov [rbp - TLC_RESVAL], rax
    mov [rbp - TLC_RESTAG], edx
    mov [rbp - TLC_RESOWN], rcx
    mov [r13 + TC_VALUE], rax
    mov [r13 + TC_TAG], edx
    mov [r13 + TC_OWNER], rcx
    mov [r13 + TC_TYPE], rbx

    ; The entry OWNS its name, and that is not tidiness.  The name is compared
    ; by pointer, and a name that is not interned -- `getattr(o, "visit_" + k)`
    ; builds one per call -- is freed as soon as the caller drops it, after
    ; which the allocator can hand the same address to a DIFFERENT name.  The
    ; entry would then match a lookup it has no answer for.  Holding a
    ; reference makes the address unreusable for as long as the comparison can
    ; see it.  (ast.NodeVisitor found this: visit_BinOp matched the entry left
    ; by visit_Name and dispatched to it.)
    mov r8, [r13 + TC_NAME]
    mov [rbp - TLC_OLDNAME], r8
    INCREF r12
    mov [r13 + TC_NAME], r12

    ; The version goes in LAST, because it is the field the hit test reads
    ; first and the one that makes the entry live.
    mov r8, [rbp - TLC_VER]
    mov [r13 + TC_VERSION], r8

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
