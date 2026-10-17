; pyo/strintern.asm - the string intern table
;
; One table, mapping a run of bytes to the single PyStrObject that stands for
; it.  Identifiers coming out of marshal and out of our own compiler go through
; it, so that the same name written in two modules -- or in two functions of
; one module -- is one object.
;
; WHY A TABLE OF ITS OWN AND NOT A dict
;
; Two reasons, both structural rather than stylistic.
;
; The callers have `(const char *, len)` in hand and no object yet.  A dict
; would force `str_new_heap` -> look up -> free the duplicate on every HIT,
; which is an allocate, a copy and a free per token of every file compiled.
; A byte-keyed probe allocates only on a miss.
;
; And `dict`'s comparison path can raise: `dict_keys_equal`'s error arm is
; `jmp eval_exception_unwind`, which calls `fatal_error` when there is no live
; interpreter frame -- and `./apython foo.py` compiles before any frame exists.
; That is the rule in CLAUDE.md that `src/compiler/` must never reach
; `raise_exception`, arrived at from the other direction.  Nothing here calls
; anything but `ap_malloc`, `ap_memcmp`, `str_hash_bytes` and the refcount
; helpers.
;
; WHAT IS INTERNED
;
; The rules are CPython's, and the second one is the guard rail:
;
;   - a NAME, unconditionally.  Identifiers are what benefit; `co_names` is
;     where the attribute cache compares by pointer.
;   - a str CONSTANT only when every byte is [A-Za-z0-9_].  So `"hello"` is
;     shared between modules and `"hello world"` and `"ete"` with an accent are
;     NOT.  Over-interning is invisible in a single module and shows up as two
;     modules' unrelated long strings sharing an object.
;
; THE TABLE NEVER EVICTS, AND THAT IS LOAD-BEARING
;
; `CompUnit.names` holds BORROWED pointers -- the object arena owns them -- and
; an interned name outlives the arena.  Never evicting makes those borrowed
; pointers valid for the life of the process, which is a stronger invariant
; than the one recorded in `src/compiler/compile.asm`.  The cost is that the
; table shows as "still reachable" under valgrind.  That is deliberate; it is
; not a leak to be fixed.

%include "macros.inc"
%include "object.inc"
%include "value.inc"

extern ap_malloc
extern ap_free
extern ap_memcmp
extern ap_memcpy
extern str_hash_bytes
extern ap_strlen
extern str_alloc_bytes
extern str_set_length
extern str_type
extern obj_incref
extern obj_decref

section .text

;; ============================================================================
;; si_grow() -> rax = 1 on success, 0 when the allocation failed
;;
;; Doubles the slot array and re-files every entry.  Re-filing cannot fail and
;; cannot collide with itself: the capacity is a power of two, every key is
;; distinct, and the probe below is the same one.
;; ============================================================================
SG_OLD   equ 8
SG_OLDCAP equ 16
SG_FRAME equ 32             ; + 2 pushes = 48, 16-aligned
DEF_FUNC_LOCAL si_grow, SG_FRAME
    push rbx
    push r12

    mov rax, [rel si_slots]
    mov [rbp - SG_OLD], rax
    mov rax, [rel si_capacity]
    mov [rbp - SG_OLDCAP], rax

    ; Eight slots to begin with, then double.
    test rax, rax
    jnz .sg_double
    mov eax, 8
    jmp .sg_have_cap
.sg_double:
    shl rax, 1
.sg_have_cap:
    mov rbx, rax                    ; the new capacity
    mov rdi, rbx
    shl rdi, 3
    call ap_malloc
    test rax, rax
    jz .sg_fail
    mov r12, rax                    ; the new slot array

    ; Zero it: an empty slot is a NULL pointer, and there are no tombstones
    ; because nothing is ever removed.
    xor ecx, ecx
.sg_zero:
    cmp rcx, rbx
    jge .sg_zeroed
    mov qword [r12 + rcx*8], 0
    inc rcx
    jmp .sg_zero
.sg_zeroed:

    mov [rel si_slots], r12
    mov [rel si_capacity], rbx

    ; Re-file the old entries.
    mov rax, [rbp - SG_OLD]
    test rax, rax
    jz .sg_done
    xor ecx, ecx
.sg_refile:
    cmp rcx, [rbp - SG_OLDCAP]
    jge .sg_freed
    mov rax, [rbp - SG_OLD]
    mov rdi, [rax + rcx*8]
    test rdi, rdi
    jz .sg_refile_next
    push rcx
    push rcx                        ; two slots: rsp stays 16-aligned
    mov rsi, [rdi + PyStrObject.ob_hash]
    call si_place
    pop rcx
    pop rcx
.sg_refile_next:
    inc rcx
    jmp .sg_refile
.sg_freed:
    mov rdi, [rbp - SG_OLD]
    call ap_free
.sg_done:
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret
.sg_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC si_grow

;; ============================================================================
;; si_lookup(const char *data, int64_t len, int64_t hash) -> rax = the resident
;;   PyStrObject*, or 0 when these bytes are not in the table
;;
;; A BORROWED reference; the table's own is what keeps it alive.  One probe,
;; shared by both entry points, so they cannot disagree about where a string
;; lives.  Hash, then length, then bytes -- the same order dict_lookup uses.
;; ============================================================================
SL_DATA equ 8
SL_LEN  equ 16
SL_HASH equ 24
SL_FRAME equ 40                 ; + 3 pushes = 64, 16-aligned
DEF_FUNC si_lookup, SL_FRAME
    push rbx
    push r12
    push r13
    mov rbx, [rel si_capacity]
    test rbx, rbx
    jz .sl_miss
    mov [rbp - SL_DATA], rdi          ; data
    mov [rbp - SL_LEN], rsi         ; len
    mov [rbp - SL_HASH], rdx         ; hash
    dec rbx                     ; the mask; the capacity is a power of two
    mov r12, rdx
    and r12, rbx                ; the slot being probed
.sl_probe:
    mov rax, [rel si_slots]
    mov r13, [rax + r12*8]
    test r13, r13
    jz .sl_miss
    mov rax, [rbp - SL_HASH]
    cmp rax, [r13 + PyStrObject.ob_hash]
    jne .sl_next
    mov rax, [rbp - SL_LEN]
    cmp rax, [r13 + PyStrObject.ob_size]
    jne .sl_next
    lea rdi, [r13 + PyStrObject.data]
    mov rsi, [rbp - SL_DATA]
    mov rdx, [rbp - SL_LEN]
    call ap_memcmp
    test eax, eax
    jnz .sl_next
    mov rax, r13
    pop r13
    pop r12
    pop rbx
    leave
    ret
.sl_next:
    inc r12
    and r12, rbx
    jmp .sl_probe
.sl_miss:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC si_lookup

;; ============================================================================
;; si_place(rdi = an interned PyStrObject*, rsi = its hash) -> nothing
;;
;; Drop a string into the first empty slot on its probe path.  Only used when
;; the key is known to be absent -- on a fresh insert, and while re-filing.
;; ============================================================================
DEF_FUNC_BARE si_place
    mov rcx, [rel si_capacity]
    dec rcx                         ; the mask; the capacity is a power of two
    mov rax, rsi
    and rax, rcx
    mov r8, [rel si_slots]
.sp_probe:
    cmp qword [r8 + rax*8], 0
    je .sp_found
    inc rax
    and rax, rcx
    jmp .sp_probe
.sp_found:
    mov [r8 + rax*8], rdi
    ret
END_FUNC si_place

;; ============================================================================
;; str_intern_bytes(const char *data, int64_t len) -> rax = PyStrObject*, edx
;;
;; The interned string for these bytes, creating it if this is the first time.
;; The returned reference is OWNED, which is deliberately the same contract
;; `str_new_heap` has -- so a call site swaps one for the other and its
;; ownership does not change.
;;
;; The table holds a reference of its own to every string in it, which is what
;; keeps the object alive after every other holder is gone.
;; ============================================================================
SIB_DATA equ 8
SIB_LEN  equ 16
SIB_HASH equ 24
SIB_FRAME equ 32            ; + 2 pushes = 48, 16-aligned
DEF_FUNC str_intern_bytes, SIB_FRAME
    push rbx
    push r12
    mov [rbp - SIB_DATA], rdi
    mov [rbp - SIB_LEN], rsi

    mov rsi, [rbp - SIB_LEN]
    mov rdi, [rbp - SIB_DATA]
    call str_hash_bytes
    mov [rbp - SIB_HASH], rax

    ; Grow when the table is more than half full, so the probe path stays
    ; short.  There are no tombstones, so this is the only thing that grows it.
    mov rax, [rel si_used]
    inc rax
    shl rax, 1
    cmp rax, [rel si_capacity]
    jbe .sib_search
    call si_grow
    test eax, eax
    jz .sib_plain               ; out of memory: hand back an ordinary string

.sib_search:
    mov rdi, [rbp - SIB_DATA]
    mov rsi, [rbp - SIB_LEN]
    mov rdx, [rbp - SIB_HASH]
    call si_lookup
    test rax, rax
    jz .sib_insert
    ; A hit.  The caller gets an owned reference, as it would from str_new_heap.
    mov rbx, rax
    mov rdi, rax
    call obj_incref
    mov rax, rbx
    jmp .sib_return

.sib_insert:
    mov rdi, [rbp - SIB_LEN]
    xor esi, esi                ; counted below: an identifier may be non-ASCII
    call str_alloc_bytes
    test rax, rax
    jz .sib_plain
    mov rbx, rax
    push rbx
    push rbx                    ; two slots: rsp stays 16-aligned
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, [rbp - SIB_DATA]
    mov rdx, [rbp - SIB_LEN]
    call ap_memcpy
    pop rbx
    pop rbx
    push rbx
    push rbx
    mov rdi, rbx
    call str_set_length
    pop rbx
    pop rbx
    ; The hash is already known; storing it now means the string arrives
    ; pre-hashed, which is what dict_lookup's fast path wants.
    mov rax, [rbp - SIB_HASH]
    mov [rbx + PyStrObject.ob_hash], rax
    ; One reference for the table and one for the caller.
    inc qword [rbx + PyObject.ob_refcnt]
    mov rdi, rbx
    mov rsi, [rbp - SIB_HASH]
    call si_place
    inc qword [rel si_used]
    mov rax, rbx

.sib_return:
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.sib_plain:
    ; The table could not take it.  An ordinary string is still a correct
    ; answer; it is only not a shared one.
    mov rdi, [rbp - SIB_LEN]
    xor esi, esi
    call str_alloc_bytes
    test rax, rax
    jz .sib_return              ; nothing left to do; the caller sees NULL
    mov rbx, rax
    push rbx
    push rbx
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, [rbp - SIB_DATA]
    mov rdx, [rbp - SIB_LEN]
    call ap_memcpy
    pop rbx
    pop rbx
    push rbx
    push rbx
    mov rdi, rbx
    call str_set_length
    pop rbx
    pop rbx
    mov rax, [rbp - SIB_HASH]
    mov [rbx + PyStrObject.ob_hash], rax
    mov rax, rbx
    jmp .sib_return
END_FUNC str_intern_bytes

;; ============================================================================
;; str_intern(rdi = PyStrObject*) -> rax = PyStrObject*, edx = TAG_PTR
;;
;; The interned string equal to this one.  The argument is BORROWED and the
;; result is owned, so `x = str_intern(y)` leaves y's reference alone.
;;
;; On a MISS the argument itself is filed, not a copy of it.  That is what
;; CPython does -- its sys.intern marks the object it was given -- and it is
;; what makes `sys.intern(s) is s` true for a string nothing has interned yet.
;; Copying instead would answer False, and enum and functools compare interned
;; names with `is`.
;;
;; Only an exact str is interned; a subclass is handed straight back, since
;; sharing it would hand out an object of the wrong type.
;; ============================================================================
SINT_SELF equ 8
SINT_HASH equ 16
SINT_FRAME equ 32           ; + 2 pushes = 48, 16-aligned
DEF_FUNC str_intern, SINT_FRAME
    push rbx
    push r12
    mov rbx, rdi
    test rbx, rbx
    jz .sint_asis
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .sint_asis

    mov [rbp - SINT_SELF], rbx
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, [rbx + PyStrObject.ob_size]
    call str_hash_bytes
    mov [rbp - SINT_HASH], rax
    mov [rbx + PyStrObject.ob_hash], rax

    ; Same growth rule as str_intern_bytes: never past half full.
    mov rax, [rel si_used]
    inc rax
    shl rax, 1
    cmp rax, [rel si_capacity]
    jbe .sint_search
    call si_grow
    test eax, eax
    jz .sint_asis               ; out of memory: the string is still correct

.sint_search:
    mov rdi, [rbp - SINT_SELF]
    lea rdi, [rdi + PyStrObject.data]
    mov rsi, [rbp - SINT_SELF]
    mov rsi, [rsi + PyStrObject.ob_size]
    mov rdx, [rbp - SINT_HASH]
    call si_lookup
    test rax, rax
    jz .sint_adopt
    mov rbx, rax

.sint_asis:
    mov rdi, rbx
    call obj_incref
    mov rax, rbx
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.sint_adopt:
    ; Not present: this object becomes the interned one.  Two references now
    ; exist -- the table's and the caller's.
    mov rdi, [rbp - SINT_SELF]
    inc qword [rdi + PyObject.ob_refcnt]
    mov rsi, [rbp - SINT_HASH]
    call si_place
    inc qword [rel si_used]
    mov rbx, [rbp - SINT_SELF]
    jmp .sint_asis
END_FUNC str_intern

;; ============================================================================
;; str_intern_cstr(rdi = const char *) -> rax = PyStrObject*, edx = TAG_PTR
;;
;; The interned string for a NUL-terminated literal.  Owned, like every other
;; entry point here, so it drops straight in where a `str_from_cstr_heap` built
;; a type-dict key.
;;
;; It exists because those keys were NOT interned.  `src/methods/init.asm`
;; registers every builtin method with `str_from_cstr_heap`, so the key sitting
;; in `list`'s tp_dict under "append" was a different object from the interned
;; `co_names` entry a `l.append(x)` site probes with -- and `dict_lookup`'s
;; pointer-identity arm, the one interning exists to make hit, could never fire
;; for a builtin's methods.  Every such probe fell through to a length compare
;; and an `ap_memcmp`.
;; ============================================================================
DEF_FUNC str_intern_cstr, 8     ; + 1 push, so rsp is 16-aligned at the calls
    push rbx
    mov rbx, rdi
    call ap_strlen
    mov rdi, rbx
    mov rsi, rax
    call str_intern_bytes
    pop rbx
    leave
    ret
END_FUNC str_intern_cstr

;; ============================================================================
;; str_intern_steal(rdi = an OWNED PyStrObject*) -> rax = PyStrObject*, edx
;;
;; The same, but it consumes the caller's reference.  This is the form that
;; drops in immediately after a `str_new_heap`: the string just built is
;; released when an equal one already exists.
;; ============================================================================
DEF_FUNC str_intern_steal, 8    ; + 1 push, so rsp is 16-aligned at the calls
    push rbx
    mov rbx, rdi
    call str_intern
    push rax
    push rax                    ; two slots: rsp stays 16-aligned
    mov rdi, rbx
    call obj_decref
    pop rax
    pop rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
END_FUNC str_intern_steal

;; ============================================================================
;; str_all_name_chars(const char *data, int64_t len) -> rax = 1 or 0
;;
;; Whether every byte is [A-Za-z0-9_], which is CPython's test for whether a
;; string CONSTANT is worth interning.  An empty string answers 1, as CPython's
;; all_name_chars does -- it loops over the bytes and there are none.
;; ============================================================================
DEF_FUNC_BARE str_all_name_chars
    lea rdx, [rel si_name_chars]
    xor ecx, ecx
.sanc_loop:
    cmp rcx, rsi
    jge .sanc_yes
    movzx eax, byte [rdi + rcx]
    cmp byte [rdx + rax], 0
    je .sanc_no
    inc rcx
    jmp .sanc_loop
.sanc_yes:
    mov eax, 1
    ret
.sanc_no:
    xor eax, eax
    ret
END_FUNC str_all_name_chars

;; ============================================================================
;; str_is_interned(rdi = PyStrObject*) -> eax = 1 when this very object is the
;;   one the table holds for its bytes, else 0
;;
;; There is no flag on the object: membership IS being the table's resident.
;; An equal string that is not the resident answers 0, which is CPython's
;; PyUnicode_CHECK_INTERNED.  marshal's writer asks, so that what it wrote
;; interned comes back interned.  Never raises, never allocates.
;; ============================================================================
SII_SELF  equ 8
SII_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC str_is_interned, SII_FRAME
    mov [rbp - SII_SELF], rdi
    mov rdx, [rdi + PyStrObject.ob_hash]
    cmp rdx, -1
    jne .sii_lookup
    lea rdi, [rdi + PyStrObject.data]
    mov rsi, [rbp - SII_SELF]
    mov rsi, [rsi + PyStrObject.ob_size]
    call str_hash_bytes
    mov rdx, rax
.sii_lookup:
    mov rdi, [rbp - SII_SELF]
    mov rsi, [rdi + PyStrObject.ob_size]
    lea rdi, [rdi + PyStrObject.data]
    call si_lookup
    xor ecx, ecx
    cmp rax, [rbp - SII_SELF]
    sete cl
    mov eax, ecx
    leave
    ret
END_FUNC str_is_interned

section .rodata
;; 1 for the bytes an identifier may be made of.  A byte table is enough
;; BECAUSE the answer is no for everything above 0x7f: a name written in a
;; non-ASCII script is still interned, but as a NAME rather than as a constant,
;; and it is only constants this decides.
si_name_chars:
%assign snc 0
%rep 256
    %if (snc >= 'a' && snc <= 'z') || (snc >= 'A' && snc <= 'Z') || (snc >= '0' && snc <= '9') || snc == '_'
    db 1
    %else
    db 0
    %endif
%assign snc snc+1
%endrep

section .bss
si_slots:    resq 1         ; PyStrObject*[capacity]; NULL is empty
si_capacity: resq 1         ; a power of two, or 0 before the first insert
si_used:     resq 1
