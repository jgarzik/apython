; set.asm - Set type implementation
; Hash table with open-addressing and linear probing (no values, keys only)

%include "macros.inc"
%include "object.inc"

extern get_iterator_opt
extern list_type
extern tuple_type
extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern ap_free
extern obj_hash
extern obj_decref
extern obj_dealloc
extern obj_incref
extern str_type
extern eval_exception_unwind
extern obj_richcompare_bool
extern ap_memcpy
extern ap_memset
extern fatal_error
extern type_type

; Set entry layout constants
SET_ENTRY_HASH    equ 0
SET_ENTRY_KEY     equ 8

; Initial capacity (must be power of 2)
SET_INIT_CAP equ 8

;; The capacity of the shared empty table below.  One slot, so the mask is
;; zero and a probe lands on that slot, finds it EMPTY and stops -- which is
;; the right answer for every lookup in an empty set.
SET_EMPTY_CAP equ 1

; SET_HASH_VALUE key, out -- the hash of a key Value, with the int case inline.
;
; Every one of the three sites that needed a hash used to V_UNPACK the Value,
; V_PACK the identical word straight back and call obj_hash, whose first
; instruction is another V_UNPACK -- and whose whole answer for an int
; immediate is the value itself, because |n| < 2^50 is below PYHASH_MODULUS
; and int_hash_i64's `.ihi_small` arm returns it unchanged.  Only -1 is
; special, and only because hash(-1) is reserved for "error".  Nothing in set
; can observe that fixup today -- every insert and every probe hashes through
; here, and set_resize reuses the stored hash -- but it is what keeps this and
; obj_hash from ever disagreeing about the same key, which is the invariant
; the entries rely on.
;
; This is set's parallel of dict_lookup's cached string hash: n-queens hashes
; nothing but ints, and the call was most of what `c in cols` cost.
%macro SET_HASH_VALUE 2         ; %1 = key Value (preserved), %2 = the hash out
    V_IS_INT %1, %2
    jb %%slow
    mov %2, %1
    V_TO_I64 %2
    cmp %2, -1
    jne %%done
    mov %2, -2
    jmp %%done
%%slow:
    mov rdi, %1
    call obj_hash
    mov %2, rax
%%done:
%endmacro

; Tombstone marker for deleted entries (must not collide with any tag)

;; ============================================================================
;; set_new() -> PySetObject* (uses PyDictObject layout)
;; Allocate a new empty set with initial capacity 8
;; ============================================================================
DEF_FUNC_BARE set_new
    lea rdi, [rel set_type]
    jmp set_new_of_type
END_FUNC set_new

;; ============================================================================
;; set_new_of_type(rdi = set_type or frozenset_type) -> PySetObject*
;;
;; The two share every field of the layout and differ only in ob_type, so the
;; operators can hand the result the type the left operand had.  They used to
;; call set_new unconditionally, which is why frozenset({1}) | frozenset({2})
;; was a set.
;; ============================================================================
DEF_FUNC set_new_of_type
    push rbx
    push r12
    mov r12, rdi                ; the type to build

    ; Allocate set header (GC-tracked, reuses PyDictObject layout)
    mov edi, PyDictObject_size
    mov rsi, r12
    call gc_alloc
    mov rbx, rax                ; rbx = set (ob_refcnt=1, ob_type set)

    mov qword [rbx + PyDictObject.ob_size], 0
    mov qword [rbx + PyDictObject.dk_version], 0
    mov qword [rbx + PyDictObject.dk_tombstones], 0
    mov qword [rbx + SET_FINGER], 0
    mov qword [rbx + SET_HASH], -1      ; no hash has been asked for yet

    ; The shared empty table: no allocation at all.  A set that is never
    ; added to -- and a great many are not, starting with the temporary every
    ; binary operator builds -- costs one gc_alloc and nothing else, and the
    ; set literal that used to malloc eight slots and then immediately
    ; malloc sixteen now mallocs once.  dict_new hands out
    ; dict_empty_entries for the same reason.
    mov qword [rbx + PyDictObject.capacity], SET_EMPTY_CAP
    lea rax, [rel set_empty_entries]
    mov [rbx + PyDictObject.entries], rax

    mov rdi, rbx
    call gc_track

    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_new_of_type

section .rodata
;; ============================================================================
;; The table every empty set points at.
;;
;; A set used to allocate its own in set_new_of_type: an ap_malloc and an
;; ap_memset of eight entries for every set ever made, including the
;; temporary each binary operator builds and then swaps storage with, and
;; including the one a set literal builds and set_reserve immediately
;; replaces -- two mallocs and two memsets for `{1, 2, 3, 4, 5}`.
;;
;; The capacity is ONE, and that is what makes it safe rather than a special
;; case.  A read needs no arm: set_find_slot masks the hash to the single
;; slot, finds a NULL key with a zero hash -- an EMPTY, not a tombstone --
;; and answers miss, which is the right answer for every lookup in an empty
;; set.  A write cannot reach it either, because set_add's room test is
;; `(fill + 1) * 5 >= capacity * 3` and 3 is not more than 5, so the very
;; first insert resizes to a real table before it stores anything.
;;
;; It lives in .rodata, so "no write path can reach it" is enforced by the
;; page tables rather than by argument.  dict_empty_entries is the same
;; trick and the same reasoning.
;; ============================================================================
align 16
global set_empty_entries
set_empty_entries:
    times SET_ENTRY_SIZE / 8 dq 0

section .text

;; ============================================================================
;; set_release_table(rdi = set) -> void
;;
;; Give the table back and point the set at the shared empty one.  What
;; clear() means: the alternative is to keep a table whose every slot is now
;; dead, which leaves a set that held a million elements holding a million
;; slots.  CPython's set_clear does the same -- it calls set_table_resize
;; down to PySet_MINSIZE -- and dict_release_tables is this function for
;; dicts.
;;
;; The keys are the CALLER's to release; this only touches storage.
;; ============================================================================
global set_release_table
DEF_FUNC set_release_table, 8           ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyDictObject.entries]
    lea rax, [rel set_empty_entries]
    cmp rdi, rax
    je .srt_done                        ; already shared; nothing to release
    call ap_free
    lea rax, [rel set_empty_entries]
    mov [rbx + PyDictObject.entries], rax
    mov qword [rbx + PyDictObject.capacity], SET_EMPTY_CAP
    mov qword [rbx + PyDictObject.dk_tombstones], 0
    mov qword [rbx + SET_FINGER], 0
    mov qword [rbx + SET_HASH], -1
.srt_done:
    pop rbx
    leave
    ret
END_FUNC set_release_table

;; ============================================================================
;; set_result_type(rdi = a set or frozenset) -> rax = the type a derived set
;; should be built with: set_type or frozenset_type.
;;
;; CPython's rule for the operators and for copy(): the result takes the LEFT
;; operand's kind, and a subclass of either yields the plain base rather than
;; the subclass -- frozenset({1}).copy() is a frozenset, and F({1}).copy() for
;; a frozenset subclass F is a frozenset too.
;; ============================================================================
DEF_FUNC_BARE set_result_type
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel frozenset_type]
    cmp rax, rcx
    je .srt_frozen
    lea rcx, [rel set_type]
    cmp rax, rcx
    je .srt_plain
    ; A subclass: which base does it descend from?  frozenset_type carries
    ; TYPE_FLAG_SET_SUBCLASS itself, so the flag cannot answer this; the MRO
    ; can.
    push rdi
    mov rdi, rax
    lea rsi, [rel frozenset_type]
    extern type_is_subtype
    call type_is_subtype
    pop rdi
    test eax, eax
    jnz .srt_frozen
.srt_plain:
    lea rax, [rel set_type]
    ret
.srt_frozen:
    lea rax, [rel frozenset_type]
    ret
END_FUNC set_result_type

;; ============================================================================
;; set_coerce_operand(rdi = the other operand, a Value)
;;   -> rax = an OWNED set-like pointer, or 0 with the exception pending
;;
;; set.union, .intersection, .difference and .symmetric_difference take any
;; iterable, where the operators take only a set.  All four read the argument
;; as a PyDictObject regardless, so `{1,2}.difference([1])` walked a list's
;; header as a hash table, found nothing occupied, and answered {1,2} -- a
;; silently wrong answer rather than a crash.  A set argument is handed back
;; INCREF'd so the caller can release its operand unconditionally.
;; ============================================================================
SCO_ARG   equ 8         ; a one-Value args array for set_type_call
SCO_FRAME equ 16            ; + 0 pushes = 16, 16-aligned

DEF_FUNC set_coerce_operand, SCO_FRAME
    V_TEST_PTR rdi, rax
    ja .sco_build
    test rdi, rdi
    jz .sco_build
    mov rax, [rdi + PyObject.ob_type]
    REQUIRE_SET_TYPE rax, rcx, .sco_build
    mov rax, rdi
    INCREF rax
    leave
    ret

.sco_build:
    mov [rbp - SCO_ARG], rdi
    lea rsi, [rbp - SCO_ARG]
    lea rdi, [rel set_type]
    mov edx, 1
    call set_type_call          ; raises for a non-iterable, NULL if it threw
    leave
    ret
END_FUNC set_coerce_operand

;; ============================================================================
;; frozenset_hash(rdi = self, edx = tag) -> rax = the hash
;;
;; frozenset_type.tp_hash was 0, so a frozenset could not be a dict key or a
;; set member -- the very things it exists for.  This is CPython's own
;; frozenset_hash, over the per-entry hashes the table already stores: XOR
;; makes it order-insensitive, which is what set equality requires of it.
;; ============================================================================
global frozenset_hash
DEF_FUNC frozenset_hash
    push rbx
    push r12
    push r13

    mov rbx, rdi

    ; Cached?  A frozenset's elements cannot change once it exists, so the
    ; fold below has exactly one answer and it is worth keeping: this used
    ; to walk the whole table on EVERY call, and the table is four to six
    ; times the element count, so `hash(f)` in a loop over a hundred-element
    ; frozenset read five hundred slots each time round.  Every use of a
    ; frozenset as a dict key or a set member goes through here.
    mov rax, [rbx + SET_HASH]
    cmp rax, -1
    jne .fsh_ret

    mov r12, [rbx + PyDictObject.entries]
    mov r13, [rbx + PyDictObject.capacity]
    xor r8d, r8d                ; the accumulator; nothing here calls out
    xor ecx, ecx

.fsh_loop:
    cmp rcx, r13
    jge .fsh_length
    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r12
    cmp qword [rax + SET_ENTRY_KEY], 0      ; occupied?
    je .fsh_next

    ; h ^= ((h ^ 89869747) ^ (h << 16)) * 3644798167
    mov rdx, [rax + SET_ENTRY_HASH]
    mov rsi, rdx
    mov edi, 89869747
    xor rsi, rdi
    mov rdi, rdx
    shl rdi, 16
    xor rsi, rdi
    mov rdi, 3644798167
    imul rsi, rdi
    xor r8, rsi

.fsh_next:
    inc rcx
    jmp .fsh_loop

.fsh_length:
    ; Fold the size in, so frozensets of different sizes do not collide as
    ; readily, then scramble once more.
    mov rax, [rbx + PyDictObject.ob_size]
    inc rax
    mov edi, 1927868237
    imul rax, rdi
    xor r8, rax

    mov rax, r8
    mov edi, 69069
    imul rax, rdi
    mov edi, 907133923
    add rax, rdi

    cmp rax, -1                 ; -1 is the error sentinel everywhere else,
    jne .fsh_store              ; and the not-yet-computed one here
    mov eax, 590923713

.fsh_store:
    mov [rbx + SET_HASH], rax

.fsh_ret:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC frozenset_hash

;; ============================================================================
;; set_keys_equal(rdi = a Value, rsi = b Value) -> eax = 1 if equal, 0 if not
;;
;; Was an identity check plus a string compare, and nothing else: no
;; cross-type numeric equality, so 1.0 in {1} was False where the same
;; lookup in a dict succeeded, and no __eq__, so a user class could never
;; find its own key.  Set membership is PyObject_RichCompareBool, the same
;; as everywhere else.
;;
;; It took a (payload, tag) pair and packed both back, which was the only
;; reason set_find_slot unpacked them -- the entries hold Values and so does
;; the probe key.  Now it is only reached when the two Values DIFFER, which
;; rules out every int and every identity hit before the call is made.
;; ============================================================================
DEF_FUNC_LOCAL set_keys_equal
    mov edx, PY_EQ
    call obj_richcompare_bool
    cmp eax, -1
    je .ske_error
    leave
    ret

.ske_error:
    ; The caller has no error channel; the exception is already pending.
    leave
    jmp eval_exception_unwind
END_FUNC set_keys_equal

;; ============================================================================
;; set_find_slot(rdi = the set, rsi = the key Value, rdx = its hash)
;;   -> rax = entry ptr, rdx = 1 if the key is there, 0 if the slot is free
;;
;; Internal helper used by set_add and set_contains.
;;
;; A slot freed by set_remove holds a TOMBSTONE: key 0, hash -1.  The probe
;; cannot stop there -- the key it is looking for may sit further along the
;; run that the tombstone is part of -- but the slot is reusable, and this
;; remembers the first one and hands it back if the probe reaches a slot that
;; was never used at all.
;;
;; Skipping tombstones without remembering them meant every insert consumed a
;; fresh EMPTY slot, so a set that is added to and removed from in equal
;; measure only ever filled up.  With few distinct keys -- which all land in
;; one narrow band of slots -- the dead entries piled into a single
;; linear-probe run and every later add walked the whole of it: n-queens with
;; three such sets ran 500x slower than CPython and grew the tables without
;; bound.  dict never had this; its probe has always remembered the first
;; reusable slot (dl_probe's DL_FREE).
;; ============================================================================
SFS_FREE    equ 8               ; first tombstone seen on this probe, or 0
SFS_FRAME   equ 24              ; 24 + 5 pushes keeps rsp 16-aligned
DEF_FUNC_LOCAL set_find_slot
    sub rsp, SFS_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi                ; set
    mov r12, rsi                ; the key, a Value
    mov r13, rdx                ; hash

.sfs_restart:
    mov qword [rbp - SFS_FREE], 0   ; no reusable slot seen yet

    ; EVERYTHING THE LOOP NEEDS IS IN A REGISTER: the entry array, the mask,
    ; the key and the hash.  The array used to be reloaded from the set
    ; header on every probe, and the key was loaded twice from the same
    ; address -- once inside SET_ENTRY_CLASSIFY and again to compare it --
    ; so four loads answered what two do.
    mov r14, [rbx + PyDictObject.entries]
    mov r15, [rbx + PyDictObject.capacity]
    dec r15                     ; mask

    ; i = (i * 5 + 1 + perturb) & mask, perturb >>= 5 -- dict's recurrence,
    ; and dict's for a reason that had to be measured rather than assumed.
    ;
    ; The probe used to be purely LINEAR, which is fine until keys collide --
    ; and an int hashes to itself, so `i * 4096` sends every key to slot
    ; zero.  Two hundred of those formed one run of two hundred and a lookup
    ; walked half of it.
    ;
    ; CPython's set does not use its dict's recurrence either.  It walks
    ; LINEAR_PROBES (9) consecutive entries before each jump, on the argument
    ; in setobject.c's header: a set entry is a contiguous sixteen bytes, so
    ; ten of them are two and a half cache lines and one predictable stride,
    ; where a dict's compact layout would chase ten scattered entries.  That
    ; argument assumes the keys are SCATTERED to begin with.  Ours are not:
    ; an int hash is the identity, so a set of small ints -- which is most
    ; sets, and is exactly what n-queens' three diagonal sets hold -- packs
    ; into one dense band at the bottom of the table.  A linear run walks
    ; that band; a jump leaves it at once.
    ;
    ; The run length was swept over the whole set harness and the macro
    ; suite.  m_nqueens, which is 23% set code and was the largest single
    ; loss in the suite, reads 351ms at a run of 0, 380 at 1, 417 at 2, 443
    ; at 3, 486 at 5 and 532 at CPython's 9 -- monotone, with no interior
    ; optimum to look for.  The set harness agrees or is indifferent on every
    ; case and prefers 0 sharply where collisions are the measurement:
    ; st_in_collide 1.57x at 9 against 4.33x at 0.
    ;
    ; r8 = perturb.  It is the only extra state, and the recurrence is
    ; full-period without it -- 5i+1 over a power of two reaches every slot --
    ; which is what makes a miss terminate once the load factor guarantees an
    ; empty one.
    mov r8, r13                 ; perturb = hash
    mov rcx, r13
    and rcx, r15                ; i = hash & mask

.find_loop:
    ; entry = entries + slot * SET_ENTRY_SIZE.  SET_ENTRY_SIZE is 16, which no
    ; index scale reaches, but two lea do -- and without imul's latency in the
    ; middle of the recurrence.
    lea rdx, [rcx + rcx]
    lea rax, [r14 + rdx*8]

    mov rdi, [rax + SET_ENTRY_KEY]
    test rdi, rdi
    jz .find_vacant

    ; Hash match?
    cmp r13, [rax + SET_ENTRY_HASH]
    jne .find_next

    ; The stored key is a Value and so is the probe key, and the encoding is a
    ; bijection: equal Values are the same object, and two equal small ints
    ; have bit-identical Values.  So `cmp` answers for every int, every
    ; interned str and every identity hit -- where this used to V_UNPACK the
    ; entry, call set_keys_equal, V_PACK both operands back and call
    ; obj_richcompare_bool, two call/ret pairs and about seventy instructions
    ; to conclude what one compare does.
    cmp rdi, r12
    je .found_existing

    ; Different Values still need the real question asked: 1.0 == 1, and a
    ; user class decides for itself.
    ; The perturb is caller-saved, so it goes on the stack -- but only here,
    ; on the path where a hash matched and the two keys are not the same
    ; object, which is rare.
    push rcx                    ; save slot
    push rax                    ; save entry ptr
    push r8                     ; perturb; caller-saved, and the walk needs it
    push r8                     ; pad, so the call stays 16-aligned
    mov rsi, r12                ; b = the lookup key
    call set_keys_equal
    mov edi, eax                ; save equality result (survives pops)
    pop r8                      ; pad
    pop r8
    pop rax                     ; entry ptr
    pop rcx                     ; slot

    ; __eq__ is arbitrary Python and may have added to THIS set: a resize
    ; frees the entry array and rehashes into a new one, which leaves the
    ; entry pointer just restored dangling and the mask, the slot and the
    ; remembered free slot all describing a table that no longer exists.
    ; The probe starts again rather than trusting any of it -- a set whose
    ; keys collide and whose __eq__ grows it used to walk the freed array and
    ; end at fatal_error("set: hash table full").  r14 IS the array the walk
    ; began on, so the check needs no frame slot of its own.
    cmp r14, [rbx + PyDictObject.entries]
    jne .sfs_restart
    test edi, edi
    jnz .found_existing
    ; An occupied slot holding a DIFFERENT key.  Keep probing -- and jump,
    ; rather than falling through: the arm below records a reusable slot, and
    ; a live entry recorded there is handed back as free by .found_empty and
    ; then overwritten.  That reads as a set whose len() counts a key its
    ; iteration no longer contains.
    jmp .find_next

.find_vacant:
    ; A zero key is a tombstone when the hash says so, and a never-used slot
    ; otherwise.  Remember the FIRST tombstone and keep probing: stopping
    ; here would insert a duplicate of a key that is still live further along
    ; the run.
    cmp qword [rax + SET_ENTRY_HASH], ENTRY_TOMBSTONE_HASH
    jne .found_empty
    cmp qword [rbp - SFS_FREE], 0
    jne .find_next
    mov [rbp - SFS_FREE], rax

.find_next:
    shr r8, PERTURB_SHIFT
    lea rcx, [rcx + rcx*4]      ; i * 5
    add rcx, r8
    inc rcx
    and rcx, r15
    jmp .find_loop

.found_empty:
    ; A never-used slot ends the probe: the key is not in the table.  If a
    ; tombstone was passed on the way, hand that one back instead, so the
    ; insert reuses a dead slot rather than consuming a live one.
    mov rdx, [rbp - SFS_FREE]
    test rdx, rdx
    cmovnz rax, rdx
    xor edx, edx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.found_existing:
    ; rax = entry ptr, rdx = 1 (existing)
    mov edx, 1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_find_slot

;; ============================================================================
;; set_resize_to(rdi = set, rsi = the new capacity) -> void
;; Rebuild the table at the capacity asked for, rehashing nothing: every
;; entry carries the hash it was stored with.
;; ============================================================================
SRT_LIVE  equ 8             ; live entries the rehash has still to move
SRT_FRAME equ 8             ; + 5 pushes = 48, 16-aligned
DEF_FUNC_LOCAL set_resize_to, SRT_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi                ; set
    mov r14, rsi                ; the capacity asked for

    ; Save old entries and capacity
    mov r12, [rbx + PyDictObject.entries]    ; old entries
    mov r13, [rbx + PyDictObject.capacity]   ; old capacity

    mov [rbx + PyDictObject.capacity], r14
    mov qword [rbx + PyDictObject.dk_tombstones], 0  ; rehash clears tombstones
    mov qword [rbx + SET_FINGER], 0     ; and the table it indexed is gone

    ; Allocate new entries array
    imul rdi, r14, SET_ENTRY_SIZE
    call ap_malloc
    mov r15, rax                ; r15 = new entries

    ; Zero new entries
    mov rdi, r15
    xor esi, esi
    imul rdx, r14, SET_ENTRY_SIZE
    call ap_memset

    ; Store new entries pointer
    mov [rbx + PyDictObject.entries], r15

    ; Rehash: iterate old entries, re-insert non-empty ones.  ob_size is the
    ; count of them and nothing here calls out, so the walk stops on the last
    ; one rather than at the end of an array that is three quarters empty.
    mov rax, [rbx + PyDictObject.ob_size]
    mov [rbp - SRT_LIVE], rax
    xor ecx, ecx               ; ecx = index into old entries

.rehash_loop:
    cmp qword [rbp - SRT_LIVE], 0
    je .rehash_done
    cmp rcx, r13                ; compared against old capacity
    jge .rehash_done

    ; old_entry = old_entries + i * SET_ENTRY_SIZE
    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r12                ; rax = old entry ptr

    ; Skip slots that are not occupied
    SET_ENTRY_CLASSIFY rax, .rehash_next, .rehash_next
    dec qword [rbp - SRT_LIVE]

    push rcx                    ; save outer index
    mov rcx, [rax + SET_ENTRY_HASH]
    mov r8, rcx                 ; perturb = hash
    mov rdx, r14
    dec rdx                     ; new mask
    and rcx, rdx                ; i = hash & new mask

    ; Save entry data
    push qword [rax + SET_ENTRY_HASH]
    push qword [rax + SET_ENTRY_KEY]

    ; Find the first empty slot on set_find_slot's sequence.  It has to be
    ; that sequence and not a linear scan: a key is findable only if the walk
    ; that placed it is the walk that goes looking, and a rehash that packed
    ; a collision run linearly would leave everything past the first slot
    ; invisible to a lookup that jumps.  There are no tombstones and no
    ; duplicates in a freshly built table, so nothing is compared -- this is
    ; CPython's set_insert_clean.
.rehash_probe:
    lea rax, [rcx + rcx]
    lea rax, [r15 + rax*8]      ; new entry ptr
    cmp qword [rax + SET_ENTRY_KEY], 0   ; occupied?
    je .rehash_insert

    shr r8, PERTURB_SHIFT
    lea rcx, [rcx + rcx*4]
    add rcx, r8
    inc rcx
    and rcx, rdx
    jmp .rehash_probe

.rehash_insert:
    ; rax = target entry ptr in new table
    pop qword [rax + SET_ENTRY_KEY]
    pop qword [rax + SET_ENTRY_HASH]

    pop rcx                     ; restore outer index

.rehash_next:
    inc ecx
    jmp .rehash_loop

.rehash_done:
    ; Free the old entries array -- unless it is the shared empty table, which
    ; lives in .rodata and belongs to no set.
    lea rax, [rel set_empty_entries]
    cmp r12, rax
    je .rehash_freed
    mov rdi, r12
    call ap_free
.rehash_freed:

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_resize_to

;; ============================================================================
;; set_resize(rdi = set) -> void
;;
;; Rebuild at the size the LIVE count asks for: CPython's
;; `used > 50000 ? used*2 : used*4`, rounded up to the next power of two.
;;
;; This used to double the CURRENT capacity, which answers a different
;; question.  A set added to and discarded from in equal measure fills with
;; tombstones; the tombstones trip the load factor while ob_size stays flat;
;; the table doubles; and the next round of churn does it again.  n-queens
;; holds three sets of exactly that shape.  Sizing from the live count makes
;; one expression do both jobs -- a genuinely full table grows, a
;; tombstone-heavy one shrinks -- because the rehash drops tombstones on the
;; way and the new size never sees them.
;; ============================================================================
DEF_FUNC_BARE set_resize
    mov rsi, [rdi + PyDictObject.ob_size]
    mov rax, rsi
    add rsi, rsi                ; used * 2
    cmp rax, 50000
    ja .srz_round
    add rsi, rsi                ; used * 4, below CPython's cutover
.srz_round:
    ; The smallest power of two STRICTLY greater than that, so a set is at
    ; most a quarter full the moment it has been rebuilt.
    mov eax, SET_INIT_CAP
.srz_grow:
    cmp rax, rsi
    ja .srz_go
    add rax, rax
    jmp .srz_grow
.srz_go:
    mov rsi, rax
    jmp set_resize_to
END_FUNC set_resize

;; ============================================================================
;; set_reserve(rdi = set, rsi = how many more elements are coming) -> void
;;
;; Grow ONCE, so that a bulk build of a known size does not rebuild the table
;; on the way.  Every bulk path started at eight slots and rehashed at 7, 14,
;; 28, 56...: BUILD_SET (which is handed the element count), both
;; constructors, update, copy and all four binary operators.  dict_reserve
;; does the same job for dicts and for the same reason.
;;
;; The table holds ob_size + tombstones below three fifths of capacity, so
;; the room needed is that many slots rounded up to a power of two -- the
;; same test set_add applies, negated.  A set that already has the room is
;; left alone.
;; ============================================================================
global set_reserve
DEF_FUNC_BARE set_reserve
    mov rax, [rdi + PyDictObject.ob_size]
    add rax, [rdi + PyDictObject.dk_tombstones]
    add rax, rsi
    lea rax, [rax + rax*4]      ; what the table will hold, times five
    mov rcx, [rdi + PyDictObject.capacity]
    mov rdx, rcx
    lea rdx, [rdx + rdx*2]      ; capacity * 3
    cmp rax, rdx
    jl .srv_done                ; the room is already there
    cmp rcx, SET_INIT_CAP
    jae .srv_grow
    mov ecx, SET_INIT_CAP
.srv_grow:
    mov rdx, rcx
    lea rdx, [rdx + rdx*2]
    cmp rax, rdx
    jl .srv_resize
    add rcx, rcx
    jmp .srv_grow
.srv_resize:
    mov rsi, rcx
    jmp set_resize_to
.srv_done:
    ret
END_FUNC set_reserve

;; ============================================================================
;; set_clone_into(rdi = a fresh empty set, rsi = the source set) -> void
;;
;; Copy the source's table wholesale instead of re-inserting its elements.
;; The destination takes the source's CAPACITY, so the entry array transfers
;; verbatim -- tombstones included, because in a flat table an entry's slot IS
;; its probe position and a tombstone is what keeps a chain alive.  Not one
;; key is hashed and not one slot is probed.
;;
;; copy() and the self-half of `a | b` used to walk every slot and call
;; set_add per element, which is a hash, a probe, a load-factor test and a
;; possible resize each.  dict_copy_shallow was changed the same way and for
;; the same reason.
;;
;; The caller owns the destination's type; this touches only the table.
;; ============================================================================
global set_clone_into
DEF_FUNC set_clone_into, 16             ; + 4 pushes = 48, 16-aligned
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi                ; dst
    mov r12, rsi                ; src

    cmp qword [r12 + PyDictObject.ob_size], 0
    je .sci_done                ; nothing to carry; the default table is right

    ; The destination's own table goes back first.  This used to go through
    ; set_resize_to, which zeroes the new array and then re-probes every
    ; entry into it -- both wasted, because the memcpy below overwrites
    ; every byte of it.
    lea rax, [rel set_empty_entries]
    mov rdi, [rbx + PyDictObject.entries]
    cmp rdi, rax
    je .sci_alloc               ; the shared table is not ours to free
    call ap_free
.sci_alloc:
    mov r13, [r12 + PyDictObject.capacity]
    mov rdi, r13
    shl rdi, 4                  ; * SET_ENTRY_SIZE
    call ap_malloc
    mov [rbx + PyDictObject.entries], rax
    mov [rbx + PyDictObject.capacity], r13
    mov qword [rbx + SET_FINGER], 0
    mov qword [rbx + SET_HASH], -1

    mov rdi, rax
    mov rsi, [r12 + PyDictObject.entries]
    mov rdx, r13
    shl rdx, 4
    call ap_memcpy

    mov rax, [r12 + PyDictObject.ob_size]
    mov [rbx + PyDictObject.ob_size], rax
    mov rax, [r12 + PyDictObject.dk_tombstones]
    mov [rbx + PyDictObject.dk_tombstones], rax

    ; One reference for each key the copy now holds.  A tombstone carries a
    ; zero key and owns nothing.  ob_size is exactly how many live keys are
    ; in there and nothing here can call out, so the count is the bound: the
    ; empty tail of the table is never touched.
    mov r13, [rbx + PyDictObject.entries]
    mov r14, [rbx + PyDictObject.ob_size]
.sci_loop:
    test r14, r14
    jz .sci_done
    mov rax, [r13 + SET_ENTRY_KEY]
    add r13, SET_ENTRY_SIZE
    test rax, rax
    jz .sci_loop
    dec r14
    INCREF_V rax, rcx
    jmp .sci_loop

.sci_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_clone_into

;; ============================================================================
;; set_add(set, key, key_tag) -> void
;; set_add(rdi=set, rsi=key Value) -> int
;; ============================================================================
SAD_TABLE equ 8             ; the entries array the probe started on
SAD_FRAME equ 16            ; + 4 pushes = 48, 16-aligned
DEF_FUNC set_add, SAD_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi                ; set
    mov r12, rsi                ; the key, a Value

    SET_HASH_VALUE r12, r13     ; r13 = hash

.sad_retry:
    ; Make the room BEFORE probing rather than after inserting.
    ;
    ; A fresh set points at the shared read-only empty table, so the free
    ; slot a probe would hand back is in .rodata.  Resizing first is what
    ; gives the set a table it may write to, and it means no write path
    ; anywhere has to test for the shared one: by the time a slot has been
    ; handed out, the table under it is this set's own.
    ;
    ; (ob_size + tombstones + 1) * 5 >= capacity * 3, which is the same
    ; three-fifths rule one insert earlier.
    mov rax, [rbx + PyDictObject.ob_size]
    add rax, [rbx + PyDictObject.dk_tombstones]
    inc rax
    lea rax, [rax + rax*4]      ; (fill + 1) * 5
    mov rcx, [rbx + PyDictObject.capacity]
    lea rcx, [rcx + rcx*2]      ; capacity * 3
    cmp rax, rcx
    jl .have_room
    mov rdi, rbx
    call set_resize
.have_room:
    mov rcx, [rbx + PyDictObject.entries]
    mov [rbp - SAD_TABLE], rcx

    ; Find slot
    mov rdi, rbx                ; set
    mov rsi, r12                ; the key
    mov rdx, r13                ; hash
    call set_find_slot
    ; rax = entry ptr, edx = 1 if existing, 0 if empty

    ; set_find_slot runs the keys' __eq__, and that is arbitrary Python: it
    ; can `.clear()` this very set, which frees the entries array and installs
    ; the shared read-only empty table.  set_find_slot restarts its own probe
    ; when the table moves, but it then answers about the NEW table -- and if
    ; that is the shared one, the free slot it hands back is in .rodata and
    ; the store below is a fault at a mapped-read-only address.  Making the
    ; room again is what gives the set a table of its own, so start over.
    mov rcx, [rbx + PyDictObject.entries]
    cmp rcx, [rbp - SAD_TABLE]
    jne .sad_retry

    test edx, edx
    jnz .done                   ; key already exists, do nothing

    ; --- Insert new entry ---
    ; The slot may be a reused tombstone rather than a never-used one; both
    ; arrive here with key 0, and only the tombstone carries hash -1.  Taking
    ; one back has to be counted, because dk_tombstones feeds the load factor
    ; below -- left standing it would resize a table with room to spare, and
    ; the capacity would climb on every add.
    cmp qword [rax + SET_ENTRY_HASH], ENTRY_TOMBSTONE_HASH
    jne .fresh_slot
    dec qword [rbx + PyDictObject.dk_tombstones]
.fresh_slot:
    ; Store the hash and the key; the entries hold Values, which is what the
    ; key already is.
    mov [rax + SET_ENTRY_HASH], r13
    INCREF_V r12, rcx
    mov [rax + SET_ENTRY_KEY], r12

    ; Increment ob_size.  The load factor was settled on the way in.
    inc qword [rbx + PyDictObject.ob_size]

.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_add

;; ============================================================================
;; set_contains(rdi = the set, rsi = the key Value) -> eax = 0 or 1
;;
;; A SET is unhashable, but `set() in {1, 2}` is False in CPython rather
;; than a TypeError: its set_contains retries with a frozenset built from
;; the key, because that is the only thing the set could be holding.  A
;; frozenset built here is the same test done up front.
;; ============================================================================
SCT_TMP   equ 8             ; the frozenset standing in for a set key, or 0
SCT_KEY   equ 16            ; the key Value being looked up
SCT_FRAME equ 32            ; + 4 pushes = 64, 16-aligned
DEF_FUNC set_contains, SCT_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov qword [rbp - SCT_TMP], 0
    V_TEST_PTR rsi, rax
    ja .sct_not_set
    test rsi, rsi
    jz .sct_not_set
    ; The retry belongs to an UNHASHABLE set-like, which is what CPython's
    ; TypeError-and-retry amounts to: set and its subclasses have tp_hash 0,
    ; a frozenset has one of its own, and a subclass that DEFINES __hash__ is
    ; hashable and has to be looked up as itself.  The exact-type compare
    ; this replaces raised "unhashable type" for every set subclass.
    mov rax, [rsi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_SET_SUBCLASS
    jz .sct_not_set
    mov rcx, [rax + PyTypeObject.tp_hash]
    test rcx, rcx
    jz .sct_unhashable
    lea rdx, [rel hash_not_implemented]
    cmp rcx, rdx
    jne .sct_not_set
.sct_unhashable:
    mov [rbp - SCT_KEY], rsi
    push rdi
    lea rsi, [rbp - SCT_KEY]
    lea rdi, [rel frozenset_type]
    mov edx, 1
    call frozenset_type_call
    pop rdi
    V_UNPACK rax, rdx
    test rax, rax
    jz .sct_failed
    mov [rbp - SCT_TMP], rax
    mov rsi, rax
.sct_not_set:

    mov rbx, rdi                ; set
    mov r12, rsi                ; the key, a Value

    SET_HASH_VALUE r12, r13     ; r13 = hash

    ; Find slot.  A lookup never resizes: set_add's room-making belongs to
    ; the insert, and a membership test that rehashed the table would move
    ; every element out from under any iterator walking it.
    mov rdi, rbx                ; set
    mov rsi, r12                ; the key
    mov rdx, r13                ; hash
    call set_find_slot
    ; rax = entry ptr, edx = 1 if found, 0 if empty slot

    mov eax, edx                ; return 1 if found, 0 if not

    ; The frozenset built for a set key, if there was one.
    mov rdi, [rbp - SCT_TMP]
    test rdi, rdi
    jz .sct_out
    push rax
    call obj_decref
    pop rax
.sct_out:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.sct_failed:
    xor eax, eax
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

END_FUNC set_contains

;; ============================================================================
;; set_richcompare(self, other, op, self_tag, other_tag) -> (rax, edx) fat value
;; Compares two sets. Only PY_EQ and PY_NE implemented.
;; ============================================================================
SRC_SELF  equ 8
SRC_OTHER equ 16
SRC_OP    equ 24
; The key each of the three subset walks below probes with is BORROWED from
; the table it is walking, and set_contains runs __eq__ -- arbitrary Python,
; which may clear that set and take the key's last reference with it.  Held
; here for the turn, the way CPython holds it.
SRC_KEY   equ 32
SRC_IDX   equ 40
SRC_FRAME equ 48            ; + 3 pushes = 72... see the pad below
DEF_FUNC set_richcompare, SRC_FRAME
    V_UNPACK rdi, rcx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, r8            ; right Value -> (payload, tag)
    push rbx
    push r12
    push r13

    mov [rbp - SRC_SELF], rdi
    mov [rbp - SRC_OTHER], rsi
    mov [rbp - SRC_OP], rdx

    ; Check other is a set or frozenset -- or a SUBCLASS of either, which the
    ; exact-pointer compare this used to be refused: `S() <= S()` for
    ; `class S(set)` came out NotImplemented and then TypeError.  Both static
    ; types carry TYPE_FLAG_SET_SUBCLASS and every subclass inherits it, so
    ; the flag is exactly the question being asked.
    test r8d, TAG_RC_BIT
    jz .src_not_impl
    mov rax, [rsi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_SET_SUBCLASS
    jz .src_not_impl

.src_is_set:
    cmp edx, PY_EQ
    je .src_eq
    cmp edx, PY_NE
    je .src_ne
    cmp edx, PY_LE
    je .src_le
    cmp edx, PY_GE
    je .src_ge
    cmp edx, PY_LT
    je .src_lt
    cmp edx, PY_GT
    je .src_gt
    jmp .src_not_impl

.src_eq:
    ; Check lengths
    mov rax, [rdi + PyDictObject.ob_size]
    cmp rax, [rsi + PyDictObject.ob_size]
    jne .src_false

    ; Two operands that have both been hashed and whose hashes differ cannot
    ; be equal, and that is one compare where the walk below is a lookup per
    ; element.  Only a frozenset ever caches a hash, so the two -1 tests are
    ; the type test as well: a mutable set leaves the field at -1 for life
    ; and simply falls through.  CPython's set_richcompare does exactly this
    ; and for the same reason -- a dict keyed by frozensets asks this
    ; question on every collision.
    mov rax, [rdi + SET_HASH]
    cmp rax, -1
    je .src_eq_walk
    mov rcx, [rsi + SET_HASH]
    cmp rcx, -1
    je .src_eq_walk
    cmp rax, rcx
    jne .src_false
.src_eq_walk:

    ; Every element of self must be in other
    mov rbx, rdi               ; self (set)
    mov r12, rsi               ; other (set)
    mov r13, [rbx + PyDictObject.ob_size]   ; live elements still to visit
    xor ecx, ecx               ; index
.src_eq_loop:
    ; The walk ends when every live element has been seen rather than at the
    ; end of the table.  set_resize sizes from the live count and overshoots
    ; by four, so a set is a quarter full at most; r13 counts the live ones
    ; down.  The capacity and the entry array are still read INSIDE the loop
    ; because set_contains runs __eq__, which can resize the set being
    ; walked -- the counter is only a bound, never a pointer.
    test r13, r13
    jz .src_true
    cmp rcx, [rbx + PyDictObject.capacity]
    jge .src_true
    mov [rbp - SRC_IDX], rcx

    ; Get entry at index
    imul rax, rcx, SET_ENTRY_SIZE
    add rax, [rbx + PyDictObject.entries]
    ; Occupied entries have a non-zero key Value
    mov rsi, [rax + SET_ENTRY_KEY]
    test rsi, rsi                        ; occupied?
    jz .src_eq_next
    dec r13

    ; Entry is occupied — check if key is in other set
    INCREF_V rsi, rax                    ; ours across __eq__
    mov [rbp - SRC_KEY], rsi
    mov rdi, r12               ; other set
    call set_contains
    mov rdi, [rbp - SRC_KEY]
    push rax
    push rax                             ; pad
    DECREF_V rdi, rcx
    pop rax
    pop rcx
    test eax, eax
    jz .src_false              ; not found → not equal

.src_eq_next:
    mov rcx, [rbp - SRC_IDX]
    inc rcx
    jmp .src_eq_loop

.src_le:
    ; self <= other: self is subset of other (every elem of self in other)
    ; A set with more elements than the other cannot be a subset of it, and
    ; that is two loads where the walk below is a lookup per element.
    ; CPython's set_issubset opens with the same test.
    mov rax, [rdi + PyDictObject.ob_size]
    cmp rax, [rsi + PyDictObject.ob_size]
    ja .src_false
    mov rbx, rdi               ; self
    mov r12, rsi               ; other
    mov r13, [rbx + PyDictObject.ob_size]   ; live elements still to visit
    xor ecx, ecx               ; index
.src_le_loop:
    test r13, r13
    jz .src_true
    cmp rcx, [rbx + PyDictObject.capacity]
    jge .src_true
    mov [rbp - SRC_IDX], rcx
    imul rax, rcx, SET_ENTRY_SIZE
    add rax, [rbx + PyDictObject.entries]
    mov rsi, [rax + SET_ENTRY_KEY]
    test rsi, rsi                        ; occupied?
    jz .src_le_next
    dec r13
    INCREF_V rsi, rax                    ; ours across __eq__
    mov [rbp - SRC_KEY], rsi
    mov rdi, r12
    call set_contains
    mov rdi, [rbp - SRC_KEY]
    push rax
    push rax                             ; pad
    DECREF_V rdi, rcx
    pop rax
    pop rcx
    test eax, eax
    jz .src_false
.src_le_next:
    mov rcx, [rbp - SRC_IDX]
    inc rcx
    jmp .src_le_loop

.src_ge:
    ; self >= other: other is subset of self → swap and do <=
    mov rax, [rsi + PyDictObject.ob_size]
    cmp rax, [rdi + PyDictObject.ob_size]
    ja .src_false              ; other is the bigger one; see .src_le
    mov rbx, rsi               ; other (check all of other in self)
    mov r12, rdi               ; self
    mov r13, [rbx + PyDictObject.ob_size]   ; live elements still to visit
    xor ecx, ecx               ; index
.src_ge_loop:
    test r13, r13
    jz .src_true
    cmp rcx, [rbx + PyDictObject.capacity]
    jge .src_true
    mov [rbp - SRC_IDX], rcx
    imul rax, rcx, SET_ENTRY_SIZE
    add rax, [rbx + PyDictObject.entries]
    mov rsi, [rax + SET_ENTRY_KEY]
    test rsi, rsi                        ; occupied?
    jz .src_ge_next
    dec r13
    INCREF_V rsi, rax                    ; ours across __eq__
    mov [rbp - SRC_KEY], rsi
    mov rdi, r12
    call set_contains
    mov rdi, [rbp - SRC_KEY]
    push rax
    push rax                             ; pad
    DECREF_V rdi, rcx
    pop rax
    pop rcx
    test eax, eax
    jz .src_false
.src_ge_next:
    mov rcx, [rbp - SRC_IDX]
    inc rcx
    jmp .src_ge_loop

.src_lt:
    ; self < other: proper subset (self <= other AND len(self) < len(other))
    mov rax, [rdi + PyDictObject.ob_size]
    cmp rax, [rsi + PyDictObject.ob_size]
    jge .src_false             ; not strictly smaller → false
    jmp .src_le                ; then check subset

.src_gt:
    ; self > other: proper superset (self >= other AND len(self) > len(other))
    mov rax, [rdi + PyDictObject.ob_size]
    cmp rax, [rsi + PyDictObject.ob_size]
    jle .src_false             ; not strictly larger → false
    jmp .src_ge                ; then check superset

.src_ne:
    ; PY_NE = not PY_EQ
    push rdi
    push rsi
    mov edx, PY_EQ
    call set_richcompare
    pop rsi
    pop rdi
    ; Negate: if bool_true → return bool_false, vice versa
    test edx, edx
    jz .src_not_impl           ; NULL result → propagate
    lea rcx, [rel bool_true]
    cmp rax, rcx
    je .src_false              ; EQ was True → NE is False
    jmp .src_true              ; EQ was False → NE is True

.src_true:
    extern bool_true
    lea rax, [rel bool_true]
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.src_false:
    extern bool_false
    lea rax, [rel bool_false]
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.src_not_impl:
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_richcompare

;; ============================================================================
;; set_contains_sq(self, key) -> int (0/1)
;; sq_contains wrapper for the sequence methods (for "in" operator)
;; ============================================================================
DEF_FUNC_BARE set_contains_sq
    jmp set_contains
END_FUNC set_contains_sq

;; ============================================================================
;; set_remove(set, key) -> int (0=ok, -1=not found)
;; Remove a key from the set
;;
;; The probe is set_find_slot's, and now it is ONLY set_find_slot's.  This
;; used to carry an independent second copy of the whole loop -- its own
;; restart-after-__eq__ guard, its own tombstone handling, its own advance --
;; three hundred lines from the original.  Two copies of a probe SEQUENCE is
;; a bug waiting for its occasion, because a key is findable only if the
;; sequence that placed it is the sequence that goes looking; the moment
;; set_find_slot started walking ten slots and jumping, the linear copy here
;; would have stopped finding anything past the tenth.
;; ============================================================================
DEF_FUNC set_remove
    push rbx
    push r12
    push r13
    push r14                    ; unused; the pair keeps rsp 16-aligned

    mov rbx, rdi                ; set
    mov r12, rsi                ; the key, a Value

    SET_HASH_VALUE r12, r13     ; r13 = hash

    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call set_find_slot          ; rax = entry, edx = 1 if the key is there
    test edx, edx
    jz .sr_not_found

    ; Tombstone the entry, release the key, and count both sides of it.  An
    ; EMPTY here rather than a tombstone would end any probe run passing
    ; through this slot, and every key beyond it would stop being findable.
    mov rdi, [rax + SET_ENTRY_KEY]
    mov qword [rax + SET_ENTRY_KEY], 0
    mov qword [rax + SET_ENTRY_HASH], ENTRY_TOMBSTONE_HASH
    DECREF_V rdi, rsi
    dec qword [rbx + PyDictObject.ob_size]
    inc qword [rbx + PyDictObject.dk_tombstones]
    xor eax, eax                ; 0 = removed
    jmp .sr_done

.sr_not_found:
    mov eax, -1

.sr_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_remove

;; ============================================================================
;; set_dealloc(PyObject *self)
;; Free all entries, then free set
;; ============================================================================
DEF_FUNC set_dealloc, 8         ; + 5 pushes = 48, 16-aligned
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi                ; self (set)
    mov r12, [rbx + PyDictObject.entries]    ; the base, for the free below
    mov r13, [rbx + PyDictObject.ob_size]    ; live keys still to release
    mov r15, r12                             ; the walking pointer
    mov r14, [rbx + PyDictObject.capacity]
    shl r14, 4
    add r14, r12                             ; one past the end

.dealloc_loop:
    ; Stop when the last live key has been released rather than at the end
    ; of the table: a set is a quarter full at most.  The capacity is the
    ; backstop, because a __del__ reached from DECREF_V can resurrect and
    ; mutate, and then ob_size is no longer what the table holds.
    test r13, r13
    jz .dealloc_entries_done
    cmp r15, r14
    jae .dealloc_entries_done

    mov rdi, [r15 + SET_ENTRY_KEY]
    add r15, SET_ENTRY_SIZE
    test rdi, rdi                            ; empty or tombstone?
    jz .dealloc_loop
    dec r13
    DECREF_V rdi, rsi
    jmp .dealloc_loop

.dealloc_entries_done:
    ; Free entries array, unless it is the shared one
    lea rax, [rel set_empty_entries]
    cmp r12, rax
    je .dealloc_freed
    mov rdi, r12
    call ap_free
.dealloc_freed:

    ; Free set object itself (GC-aware)
    mov rdi, rbx
    call gc_dealloc

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_dealloc

;; ============================================================================
;; set_type_call(self, args, nargs) -> new set
;; Constructor: set() or set(iterable)
;; self = set_type, args = arg array, nargs = count
;; ============================================================================
extern raise_exception
extern exc_TypeError_type

STC_EXC   equ 16            ; current_exception before the iteration started
STC_FRAME equ 16            ; + 2 pushes = 32, 16-aligned
DEF_FUNC set_type_call, STC_FRAME
    NO_KEYWORDS "set() takes no keyword arguments"
    push rbx
    push r12

    ; nargs can be 0 or 1
    test rdx, rdx
    je .stc_empty
    cmp rdx, 1
    jne .stc_error

    ; set(iterable): create set, iterate and add
    mov r12, [rsi]          ; args[0]

    ; Only a heap pointer can be iterable
    V_TEST_PTR r12, rcx
    ja .stc_not_iterable

    call set_new
    mov rbx, rax            ; rbx = new set

    ; A set source is CLONED -- its table copies wholesale, so no key is
    ; hashed and no slot probed.  A list or a tuple knows how many elements
    ; are coming, so the room is taken once instead of rehashing at 7, 14,
    ; 28, 56 on the way.
    mov rax, [r12 + PyObject.ob_type]
    ; A set or a frozenset -- or a SUBCLASS of either.  Both static types
    ; carry TYPE_FLAG_SET_SUBCLASS and every subclass inherits it, so one
    ; test asks the whole question; the two exact-pointer compares this
    ; replaces sent a subclass down the generic iterator path, where its own
    ; __iter__ was asked.  CPython never asks: PyAnySet_Check sends every one
    ; of them to the table.
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_SET_SUBCLASS
    jnz .stc_clone
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .stc_reserve
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    jne .stc_sized_done
.stc_reserve:
    mov rdi, rbx
    mov rsi, [r12 + PyListObject.ob_size]
    call set_reserve
    jmp .stc_sized_done
.stc_clone:
    ; Straight to the return, NOT to the exception check below.  That check
    ; reads a snapshot DUNDER_EXC_SAVE takes further down, on the iterator
    ; path; jumping into it from here read whatever was in the frame slot, so
    ; `set(s)` compared current_exception against stack garbage and, whenever
    ; an exception happened to be in flight -- a __del__ running while a
    ; frame unwinds -- decided the construction had raised, dropped the
    ; finished set and returned NULL.  Nothing in set_clone_into can raise:
    ; it is a memcpy and a run of INCREFs.
    mov rdi, rbx
    mov rsi, r12
    call set_clone_into
    jmp .stc_done
.stc_sized_done:

    ; Get iterator: tp_iter(iterable)
    ; get_iterator_opt, not tp_iter: an object with __getitem__ and no
    ; __iter__ is iterable, and reading the slot rejects it.
    mov rdi, r12
    mov esi, TAG_PTR
    call get_iterator_opt
    test rax, rax
    jz .stc_not_iterable_decref_set
    mov r12, rax            ; r12 = iterator

    DUNDER_EXC_SAVE [rbp - STC_EXC]
.stc_iter_loop:
    ; Get next: tp_iternext(iterator)
    mov rdi, r12
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    V_UNPACK rax, rdx           ; tp_iternext returns a Value
    test edx, edx           ; check tag (NULL = exhausted)
    jz .stc_iter_done

    ; Add to set (set_add INCREFs, so DECREF the iternext ref after)
    mov rdi, rbx            ; set
    mov rsi, rax            ; key payload
    ; edx = key tag (from tp_iternext)
    push rax                ; save key payload
    push rdx                ; save key tag
    push rdx                ; alignment padding (3 pushes = odd, matches ABI)
    V_PACK rsi, rdx         ; set_add takes a key Value
    call set_add
    add rsp, 8              ; drop alignment padding
    pop rsi                 ; key tag
    pop rdi                 ; key payload
    DECREF_VAL rdi, rsi     ; release iternext's reference
    jmp .stc_iter_loop

.stc_iter_done:
    ; DECREF iterator
    mov rdi, r12
    call obj_decref
    ; NULL is exhaustion and a raise alike.  Read as exhaustion, a raising
    ; __getitem__ or __next__ produced a short set and a stranded exception.
    EXC_RAISED_SINCE [rbp - STC_EXC], rcx, .stc_iter_raised

.stc_done:
    mov rax, rbx            ; return new set
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.stc_empty:
    call set_new
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.stc_iter_raised:
    mov rdi, rbx                ; the partly built set
    call obj_decref
    xor eax, eax                ; a NULL Value, with the exception pending
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret

.stc_not_iterable_decref_set:
    ; set was already allocated but iterable has no tp_iter — free set
    mov rdi, rbx
    call obj_decref

.stc_not_iterable:
    mov rsi, r12                ; args[0]: the iterator never replaced it
    CSTRING rdi, `'\x01' object is not iterable`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.stc_error:
    mov rsi, rdx
    CSTRING rdi, "set expected at most 1 argument, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC set_type_call

; set_repr is in src/repr.asm
extern set_repr

;; ============================================================================
;; set_len(PyObject *self) -> int64_t
;; Returns ob_size (number of items)
;; ============================================================================
DEF_FUNC_BARE set_len
    mov rax, [rdi + PyDictObject.ob_size]
    ret
END_FUNC set_len

;; ============================================================================
;; set_tp_iter(set) -> SetIterObject*
;; Create a new set iterator.
;; rdi = set
;; ============================================================================
DEF_FUNC set_tp_iter, 8            ; 1 push, so rsp is 16-aligned
    push rbx

    mov rbx, rdi               ; save set

    ; Reuse PyDictIterObject layout (same structure: refcnt, type, source, index)
    mov edi, PyDictIterObject_size
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel set_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyDictIterObject.it_dict], rbx     ; store set ptr
    mov qword [rax + PyDictIterObject.it_index], 0
    mov qword [rax + PyDictIterObject.it_kind], 0
    ; The size when iteration began.  A set that grows or shrinks under a
    ; `for` walks a rebuilt entry array with a stale index; nothing checked,
    ; so `for x in s: s.add(2)` quietly finished with whatever it happened to
    ; visit where CPython raises.
    mov rcx, [rbx + PyDictObject.ob_size]
    mov [rax + PyDictIterObject.it_version], rcx

    ; INCREF the set
    push rax
    mov rdi, rbx
    call obj_incref
    pop rax

    pop rbx
    leave
    ret
END_FUNC set_tp_iter

;; ============================================================================
;; set_iter_next(iter) -> PyObject* or NULL
;; Return next key, or NULL if exhausted.
;; Scans entries for next non-empty slot.
;; rdi = iterator
;; ============================================================================
DEF_FUNC_BARE set_iter_next
    mov rax, [rdi + PyDictIterObject.it_dict]      ; set
    test rax, rax
    jz .si_done                 ; already dropped, or cleared by the collector
    mov rcx, [rax + PyDictObject.ob_size]
    cmp rcx, [rdi + PyDictIterObject.it_version]
    jne .si_mutation_error
    mov rcx, [rdi + PyDictIterObject.it_index]      ; current index
    mov rdx, [rax + PyDictObject.capacity]          ; capacity
    mov rsi, [rax + PyDictObject.entries]            ; entries ptr

.si_scan:
    cmp rcx, rdx
    jge .si_exhausted

    ; Check if entry at index has a key
    imul rax, rcx, SET_ENTRY_SIZE
    add rax, rsi
    mov r8, [rax + SET_ENTRY_KEY]
    SET_ENTRY_CLASSIFY rax, .si_skip, .si_skip

    ; Found a valid entry -- return the key Value
    inc rcx
    mov [rdi + PyDictIterObject.it_index], rcx
    mov rax, r8
    INCREF_V rax, rdx
    ret

.si_skip:
    inc rcx
    jmp .si_scan

.si_exhausted:
    ; Drop the set at exhaustion, as CPython's setiter does, so a __del__ on
    ; the last reference runs while the iterator can still say "exhausted".
    mov [rdi + PyDictIterObject.it_index], rcx
    mov rax, [rdi + PyDictIterObject.it_dict]
    test rax, rax
    jz .si_done
    mov qword [rdi + PyDictIterObject.it_dict], 0
    push rdi
    mov rdi, rax
    call obj_decref
    pop rdi
.si_done:
    RET_NULL
    ret

.si_mutation_error:
    extern exc_RuntimeError_type
    RAISE exc_RuntimeError_type, "Set changed size during iteration"
END_FUNC set_iter_next

;; ============================================================================
;; set_iter_dealloc(PyObject *self)
;; ============================================================================
DEF_FUNC_LOCAL set_iter_dealloc, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; DECREF the set
    mov rdi, [rbx + PyDictIterObject.it_dict]
    call obj_decref

    ; Free self
    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC set_iter_dealloc

;; ============================================================================
;; set_iter_self(PyObject *self) -> self with INCREF
;; ============================================================================
DEF_FUNC_BARE set_iter_self
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret
END_FUNC set_iter_self

;; ============================================================================
;; frozenset_type_call(self, args, nargs) -> frozenset
;; Same as set_type_call but creates frozenset (reuses set_new, sets ob_type)
;; rdi = self (frozenset_type), rsi = args (16-byte fat slots), rdx = nargs
;; ============================================================================
global frozenset_type_call
FTC_EXC   equ 16            ; current_exception before the iteration started
FTC_FRAME equ 16            ; + 2 pushes = 32, 16-aligned
DEF_FUNC frozenset_type_call, FTC_FRAME
    NO_KEYWORDS "frozenset() takes no keyword arguments"
    push rbx
    push r12

    ; nargs can be 0 or 1
    test rdx, rdx
    je .ftc_empty
    cmp rdx, 1
    jne .ftc_error

    ; frozenset(iterable): create set, iterate and add, then set type
    mov r12, [rsi]          ; args[0]
    V_TEST_PTR r12, rcx
    ja .ftc_not_iterable

    ; frozenset(f) IS f.  A frozenset cannot change, so there is nothing a
    ; copy of one could be for -- CPython's make_new_set says "frozenset(f)
    ; is idempotent" and hands the argument straight back.  This built a
    ; whole second table and answered an object that compared equal but was
    ; not the same one.  Exact type only: a subclass may carry state that a
    ; plain frozenset does not.
    mov rax, [r12 + PyObject.ob_type]
    lea rcx, [rel frozenset_type]
    cmp rax, rcx
    jne .ftc_build
    INCREF r12
    mov rax, r12
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.ftc_build:
    call set_new
    mov rbx, rax

    ; A set source is cloned and a sized one is presized, exactly as in
    ; set_type_call above.
    mov rax, [r12 + PyObject.ob_type]
    ; A set or a frozenset -- or a SUBCLASS of either.  Both static types
    ; carry TYPE_FLAG_SET_SUBCLASS and every subclass inherits it, so one
    ; test asks the whole question; the two exact-pointer compares this
    ; replaces sent a subclass down the generic iterator path, where its own
    ; __iter__ was asked.  CPython never asks: PyAnySet_Check sends every one
    ; of them to the table.
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_SET_SUBCLASS
    jnz .ftc_clone
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .ftc_reserve
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    jne .ftc_sized_done
.ftc_reserve:
    mov rdi, rbx
    mov rsi, [r12 + PyListObject.ob_size]
    call set_reserve
    jmp .ftc_sized_done
.ftc_clone:
    mov rdi, rbx
    mov rsi, r12
    call set_clone_into
    jmp .ftc_done               ; past the exception check; see .stc_clone
.ftc_sized_done:

    ; Get iterator
    ; get_iterator_opt, not tp_iter: an object with __getitem__ and no
    ; __iter__ is iterable, and reading the slot rejects it.
    mov rdi, r12
    mov esi, TAG_PTR
    call get_iterator_opt
    test rax, rax
    jz .ftc_not_iterable_decref
    mov r12, rax

    DUNDER_EXC_SAVE [rbp - FTC_EXC]
.ftc_iter_loop:
    mov rdi, r12
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    V_UNPACK rax, rdx           ; tp_iternext returns a Value
    test edx, edx
    jz .ftc_iter_done

    mov rdi, rbx
    mov rsi, rax
    push rax
    push rdx
    push rdx
    V_PACK rsi, rdx         ; set_add takes a key Value
    call set_add
    add rsp, 8
    pop rsi
    pop rdi
    DECREF_VAL rdi, rsi
    jmp .ftc_iter_loop

.ftc_iter_done:
    mov rdi, r12
    call obj_decref
    ; NULL is exhaustion and a raise alike.  Read as exhaustion, a raising
    ; __getitem__ or __next__ produced a short set and a stranded exception.
    EXC_RAISED_SINCE [rbp - FTC_EXC], rcx, .ftc_iter_raised

.ftc_done:
    ; Set type to frozenset_type
    lea rax, [rel frozenset_type]
    mov [rbx + PyObject.ob_type], rax
    mov rax, rbx
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.ftc_empty:
    call set_new
    lea rcx, [rel frozenset_type]
    mov [rax + PyObject.ob_type], rcx
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.ftc_iter_raised:
    mov rdi, rbx                ; the partly built set
    call obj_decref
    xor eax, eax                ; a NULL Value, with the exception pending
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret

.ftc_not_iterable_decref:
    mov rdi, rbx
    call obj_decref
.ftc_not_iterable:
    mov rsi, r12                ; args[0]: the iterator never replaced it
    CSTRING rdi, `'\x01' object is not iterable`
    jmp raise_type_error_with_name
.ftc_error:
    mov rsi, rdx
    CSTRING rdi, "frozenset expected at most 1 argument, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC frozenset_type_call


;; ============================================================================
;; Set number method wrappers (nb_* convention -> set_method_* convention)
;; nb_* calling convention: rdi=left, rsi=right, rdx=ltag, rcx=rtag
;; set_method calling convention: rdi=args_array, rsi=nargs
;; ============================================================================

extern set_method_union
extern set_method_intersection
extern set_method_difference
extern set_method_symmetric_difference

SNB_FRAME equ 32            ; + 0 pushes = 32

;; set_nb_or(left, right, ltag, rtag) -> new set (union)
; The two operands, laid out as the args array the method form expects.
SNB_LEFT  equ 32
SNB_RIGHT equ 24

; Both operands of a set operator must be sets.  The method forms are laxer on
; purpose -- set.union(iterable) takes any iterable -- but the OPERATORS are
; not: CPython raises TypeError for `{1,2} | [1]`, and these slots used to hand
; the right operand to set_method_union, which reads it as a PyDictObject.
; `{1,2} | 5` was an arbitrary read through address 5.
;
; Declining with a NULL Value rather than raising is what lets the protocol try
; the other operand and then a user class's __ror__.
%macro SET_NB_REQUIRE_BOTH 0
    V_TEST_PTR rdi, rax         ; ja == not a pointer, so not a set either
    ja %%bad
    V_TEST_PTR rsi, rax
    ja %%bad
    mov rax, [rdi + PyObject.ob_type]
    REQUIRE_SET_TYPE rax, rcx, %%bad
    mov rax, [rsi + PyObject.ob_type]
    REQUIRE_SET_TYPE rax, rcx, %%bad
    jmp %%ok
%%bad:
    xor eax, eax                ; NULL Value = NotImplemented
    leave
    ret
%%ok:
%endmacro
DEF_FUNC set_nb_or, SNB_FRAME
    SET_NB_REQUIRE_BOTH
    mov [rbp - SNB_LEFT], rdi         ; args[0] = left
    mov [rbp - SNB_RIGHT], rsi         ; args[1] = right
    lea rdi, [rbp - SNB_LEFT]
    mov esi, 2
    call set_method_union
    leave
    ret
END_FUNC set_nb_or

;; set_nb_and(left, right, ltag, rtag) -> new set (intersection)
DEF_FUNC set_nb_and, SNB_FRAME
    SET_NB_REQUIRE_BOTH
    mov [rbp - SNB_LEFT], rdi         ; args[0] = left
    mov [rbp - SNB_RIGHT], rsi         ; args[1] = right
    lea rdi, [rbp - SNB_LEFT]
    mov esi, 2
    call set_method_intersection
    leave
    ret
END_FUNC set_nb_and

;; ============================================================================
;; The in-place set operators.
;;
;; `s &= t` used to fall through to the binary form and REBIND, so every other
;; name for the same set went on seeing the old value.  bugs.md filed that as a
;; deliberate omission, on the grounds that a by-name `__iand__` that did not
;; really mutate would be worse than none at all.  It would be; the answer is
;; to mutate.
;;
;; Each computes the binary result into a fresh set and then swaps the two
;; sets' storage, so the object the caller is holding is the one that changes.
;; The temporary leaves holding the old table and releases it on the way out.
;; Doing it that way means the four share every line of the actual set algebra
;; with the binary forms, rather than growing a second implementation of it.
;;
;; frozenset does NOT get these -- it shares set_number_methods, so each one
;; asks set_result_type what kind the receiver is and declines for a frozen
;; one.  CPython's frozenset has no `__iand__` either, and `fs &= t` rebinds
;; there too.
;; ============================================================================
%macro DEF_SET_INPLACE 2        ; %1 = name suffix, %2 = the binary form
DEF_FUNC set_nb_i%1, SNB_FRAME
    SET_NB_REQUIRE_BOTH         ; both are sets, or NotImplemented
    mov [rbp - SNB_LEFT], rdi
    mov [rbp - SNB_RIGHT], rsi

    ; An immutable receiver has nothing to mutate: hand back NotImplemented
    ; and let the protocol fall back to the binary form and rebind.
    call set_result_type
    lea rcx, [rel frozenset_type]
    cmp rax, rcx
    je %%decline

    mov rdi, [rbp - SNB_LEFT]
    mov rsi, [rbp - SNB_RIGHT]
    call %2                     ; the binary form: an owned set, as a Value
    test rax, rax
    jz %%decline                ; NULL: it raised, or it declined

    mov rdi, [rbp - SNB_LEFT]
    mov rsi, rax                ; takes over the temporary's reference
    call set_swap_storage       ; -> rax = the receiver, one new reference
    leave
    ret
%%decline:
    xor eax, eax                ; a NULL Value is NotImplemented here
    leave
    ret
END_FUNC set_nb_i%1
%endmacro

DEF_SET_INPLACE and, set_nb_and
DEF_SET_INPLACE or,  set_nb_or
DEF_SET_INPLACE sub, set_nb_sub
DEF_SET_INPLACE xor, set_nb_xor

;; ============================================================================
;; set_swap_storage(rdi = the set to mutate,
;;                  rsi = a fresh set holding the answer, whose reference this
;;                        takes over)
;;   -> rax = the mutated set, with a reference of its own
;;
;; set and frozenset reuse the dict header, of which a set uses four words.
;; Swapping them moves the answer into the caller's object and the old table
;; into the temporary, which then releases it -- so the old keys are dropped
;; by the ordinary set dealloc rather than by a second copy of it here.
;; ============================================================================
DEF_FUNC set_swap_storage, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    push r12
    sub rsp, 8                  ; 8 + 16 = 24; + the pushed rbp = aligned
    mov rbx, rdi
    mov r12, rsi

    mov rax, [rbx + PyDictObject.ob_size]
    mov rcx, [r12 + PyDictObject.ob_size]
    mov [rbx + PyDictObject.ob_size], rcx
    mov [r12 + PyDictObject.ob_size], rax

    mov rax, [rbx + PyDictObject.capacity]
    mov rcx, [r12 + PyDictObject.capacity]
    mov [rbx + PyDictObject.capacity], rcx
    mov [r12 + PyDictObject.capacity], rax

    mov rax, [rbx + PyDictObject.entries]
    mov rcx, [r12 + PyDictObject.entries]
    mov [rbx + PyDictObject.entries], rcx
    mov [r12 + PyDictObject.entries], rax

    mov rax, [rbx + PyDictObject.dk_tombstones]
    mov rcx, [r12 + PyDictObject.dk_tombstones]
    mov [rbx + PyDictObject.dk_tombstones], rcx
    mov [r12 + PyDictObject.dk_tombstones], rax

    ; The pop cursor indexes the table, so it travels with it.
    mov rax, [rbx + SET_FINGER]
    mov rcx, [r12 + SET_FINGER]
    mov [rbx + SET_FINGER], rcx
    mov [r12 + SET_FINGER], rax

    ; A cached hash describes the ELEMENTS, and both objects just got a
    ; different set of them.  Neither is a frozenset today -- only `|=` and
    ; its siblings come through here, and those are mutable-set operators --
    ; but a stale hash is the kind of thing that is discovered years later
    ; by a dict lookup that cannot find a key it is holding.
    mov qword [rbx + SET_HASH], -1
    mov qword [r12 + SET_HASH], -1

    ; The version counter belongs to the object, not to the table, so it does
    ; not travel -- but it does have to move, or an iterator that is mid-walk
    ; will not notice that the set changed under it.
    inc qword [rbx + PyDictObject.dk_version]

    DECREF_REG r12              ; releases the old table and its keys
    mov rax, rbx
    INCREF rax
    add rsp, 8
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_swap_storage

;; set_nb_sub(left, right, ltag, rtag) -> new set (difference)
DEF_FUNC set_nb_sub, SNB_FRAME
    SET_NB_REQUIRE_BOTH
    mov [rbp - SNB_LEFT], rdi         ; args[0] = left
    mov [rbp - SNB_RIGHT], rsi         ; args[1] = right
    lea rdi, [rbp - SNB_LEFT]
    mov esi, 2
    call set_method_difference
    leave
    ret
END_FUNC set_nb_sub

;; set_nb_xor(left, right, ltag, rtag) -> new set (symmetric_difference)
DEF_FUNC set_nb_xor, SNB_FRAME
    SET_NB_REQUIRE_BOTH
    mov [rbp - SNB_LEFT], rdi         ; args[0] = left
    mov [rbp - SNB_RIGHT], rsi         ; args[1] = right
    lea rdi, [rbp - SNB_LEFT]
    mov esi, 2
    call set_method_symmetric_difference
    leave
    ret
END_FUNC set_nb_xor


;; ============================================================================
;; Data section
;; ============================================================================
section .data

; set_repr_str removed - repr now in src/repr.asm
set_iter_name: db "set_iterator", 0

set_name_str: db "set", 0
frozenset_name_str: db "frozenset", 0

; Set number methods (for |, &, -, ^ operators)
align 8
set_number_methods:
    dq 0                        ; nb_add          +0
    dq set_nb_sub               ; nb_subtract     +8  (set difference -)
    dq 0                        ; nb_multiply     +16
    dq 0                        ; nb_remainder    +24
    dq 0                        ; nb_divmod       +32
    dq 0                        ; nb_power        +40
    dq 0                        ; nb_negative     +48
    dq 0                        ; nb_positive     +56
    dq 0                        ; nb_absolute     +64
    dq 0                        ; nb_bool         +72
    dq 0                        ; nb_invert       +80
    dq 0                        ; nb_lshift       +88
    dq 0                        ; nb_rshift       +96
    dq set_nb_and               ; nb_and          +104 (set intersection &)
    dq set_nb_xor               ; nb_xor          +112 (set symmetric_difference ^)
    dq set_nb_or                ; nb_or           +120 (set union |)
    dq 0                        ; nb_int          +128
    dq 0                        ; nb_float        +136
    dq 0                        ; nb_floor_divide +144
    dq 0                        ; nb_true_divide  +152
    dq 0                        ; nb_index        +160
    dq 0                        ; nb_iadd         +168
    dq set_nb_isub            ; nb_isub         +176
    dq 0                        ; nb_imul         +184
    dq 0                        ; nb_irem         +192
    dq 0                        ; nb_ipow         +200
    dq 0                        ; nb_ilshift      +208
    dq 0                        ; nb_irshift      +216
    dq set_nb_iand            ; nb_iand         +224
    dq set_nb_ixor            ; nb_ixor         +232
    dq set_nb_ior            ; nb_ior          +240
    dq 0                        ; nb_ifloor_divide +248
    dq 0                        ; nb_itrue_divide +256
    dq 0 ; nb_matmul
    dq 0 ; nb_imatmul

; Set sequence methods (for sq_contains -> "in" operator, and sq_length -> len())
align 8
global set_seq_methods
set_seq_methods:
    dq set_len                  ; sq_length       +0
    dq 0                        ; sq_concat       +8
    dq 0                        ; sq_repeat       +16
    dq 0                        ; sq_item          +24
    dq 0                        ; sq_ass_item      +32
    dq set_contains_sq          ; sq_contains      +40
    dq 0                        ; sq_inplace_concat +48
    dq 0                        ; sq_inplace_repeat +56

; Set type object
align 8
global set_type
set_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq set_name_str             ; tp_name
    dq PyDictObject_size        ; tp_basicsize (reuse dict layout)
    dq set_dealloc              ; tp_dealloc
    dq set_repr                 ; tp_repr
    dq set_repr                 ; tp_str
    extern hash_not_implemented
    dq hash_not_implemented     ; tp_hash (raises TypeError)
    dq 0                ; tp_call  (instances are not callable)
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq set_richcompare          ; tp_richcompare
    dq set_tp_iter              ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq set_type_call        ; tp_new  (constructor)
    dq set_number_methods       ; tp_as_number
    dq set_seq_methods          ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC | TYPE_FLAG_SET_SUBCLASS ; tp_flags
    dq 0                        ; tp_bases
    dq set_traverse                        ; tp_traverse
    dq set_clear_gc                        ; tp_clear
    dq 0         ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; Frozenset type object
align 8
global frozenset_type
frozenset_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq frozenset_name_str       ; tp_name
    dq PyDictObject_size        ; tp_basicsize (reuse dict layout)
    dq set_dealloc              ; tp_dealloc (same as set)
    dq set_repr                 ; tp_repr (TODO: frozenset({...}) format)
    dq set_repr                 ; tp_str
    dq frozenset_hash           ; tp_hash
    dq 0                ; tp_call  (instances are not callable)
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq set_richcompare          ; tp_richcompare
    dq set_tp_iter              ; tp_iter (reuse set iter)
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq frozenset_type_call  ; tp_new  (constructor)
    dq set_number_methods       ; tp_as_number
    dq set_seq_methods          ; tp_as_sequence (reuse set methods)
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC | TYPE_FLAG_SET_SUBCLASS ; tp_flags
    dq 0                        ; tp_bases
    dq set_traverse                        ; tp_traverse
    dq set_clear_gc                        ; tp_clear
    dq 0         ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; Set iterator type
align 8
global set_iter_type
set_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq set_iter_name            ; tp_name
    dq PyDictIterObject_size    ; tp_basicsize
    dq set_iter_dealloc         ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq set_iter_self            ; tp_iter (return self)
    dq set_iter_next            ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq 0                        ; tp_flags
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

section .text

;; ============================================================================
;; GC traverse and clear.  These lived in gc.asm, which left the collector
;; holding the reference graph of every type in the system; a type's own
;; file is the only place that knows which of its fields are owned.
;; ============================================================================

;; ============================================================================
;; ---- set_traverse / set_clear ----
;; Set entries are 24 bytes (hash+key+key_tag_qword), distinct from DictEntry (32 bytes).
;; ============================================================================
SET_ENTRY_SIZE_GC    equ 16
SET_ENTRY_KEY_GC     equ 8

DEF_FUNC set_traverse, 16       ; + 4 pushes = 48, 16-aligned
    push rbx
    push r12
    push r13
    push r15

    mov rbx, rdi
    mov r12, [rbx + PyDictObject.entries]   ; set reuses PyDictObject layout for header
    mov r13, [rbx + PyDictObject.capacity]
    ; r15, not r14: r14 is where the collector left the visit callback, and
    ; VISIT_V calls through it.
    mov r15, [rbx + PyDictObject.ob_size]   ; live keys still to visit
.st_loop:
    ; The capacity is the backstop; the live count is what usually ends this.
    test r15, r15
    jz .st_done
    test r13, r13
    jz .st_done
    dec r13
    mov rdi, [r12 + SET_ENTRY_KEY_GC]
    add r12, SET_ENTRY_SIZE_GC
    test rdi, rdi                           ; empty or tombstone?
    jz .st_loop
    dec r15
    VISIT_V rdi, rsi
    jmp .st_loop
.st_done:
    pop r15
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_traverse

DEF_FUNC set_clear_gc, 16       ; + 4 pushes = 48, 16-aligned
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi
    mov r12, [rbx + PyDictObject.entries]
    mov r13, [rbx + PyDictObject.capacity]
    mov r14, [rbx + PyDictObject.ob_size]   ; live keys still to release
.sc_loop:
    test r14, r14
    jz .sc_done
    test r13, r13
    jz .sc_done
    dec r13
    mov rdi, [r12 + SET_ENTRY_KEY_GC]
    test rdi, rdi                           ; empty or tombstone?
    jz .sc_next
    dec r14
    mov qword [r12 + SET_ENTRY_KEY_GC], 0   ; before the DECREF, which calls out
    push r12
    push r13
    DECREF_V rdi, rsi
    pop r13
    pop r12
.sc_next:
    add r12, SET_ENTRY_SIZE_GC
    jmp .sc_loop
.sc_done:
    mov qword [rbx + PyDictObject.ob_size], 0

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_clear_gc
