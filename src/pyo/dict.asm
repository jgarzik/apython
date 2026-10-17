; pyo/dict.asm - Dict type implementation
; Open-addressing hash table with linear probing

%include "opcodes.inc"
%include "macros.inc"
%include "object.inc"

extern ap_memcpy
extern obj_richcompare_bool
extern eval_exception_unwind
extern bool_true
extern bool_false
extern ap_malloc
extern gc_alloc
extern iter_traverse_one
extern iter_clear_one
extern gc_track
extern gc_dealloc
extern ap_free
extern ap_memcmp
extern obj_hash
extern obj_decref
extern obj_dealloc
extern str_type
extern fatal_error
extern raise_exception
extern obj_incref
extern type_type
extern tuple_type

; Initial capacity (must be power of 2)
; DICT_INIT_CAP now lives in object.inc, shared with the subclass path

; Tombstone marker for deleted dict entries.
; When an entry is deleted, key_tag is set to this value so that
; linear probing continues past it (instead of stopping as at empty slots).
; Must never match a valid tag value.

;; ============================================================================
;; dict_new() -> PyDictObject*
;; Allocate a new empty dict with initial capacity 8
;; ============================================================================
DEF_FUNC dict_new, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    ; Header
    mov edi, PyDictObject_size
    lea rsi, [rel dict_type]
    call gc_alloc
    mov rbx, rax
    mov qword [rbx + PyDictObject.ob_size], 0
    mov qword [rbx + PyDictObject.capacity], DICT_INIT_CAP
    mov qword [rbx + PyDictObject.dk_version], 1
    mov qword [rbx + PyDictObject.dk_tombstones], 0
    mov qword [rbx + PyDictObject.dk_nentries], 0
    mov qword [rbx + PyDictObject.dk_kind], 1   ; vacuously all-str

    ; The shared empty table: no allocation, and the first insert resizes
    ; away from it before it can write anything.
    mov qword [rbx + PyDictObject.capacity], 1
    lea rax, [rel dict_empty_entries]
    mov [rbx + PyDictObject.entries], rax
    lea rax, [rel dict_empty_indices]
    mov [rbx + PyDictObject.dk_indices], rax

    ; NOT tracked yet.  A dict whose contents are all untrackable cannot be
    ; part of a cycle, and CPython does not track one: `gc.is_tracked({})` is
    ; False there and was True here.  dict_maybe_track puts it in a
    ; generation the moment something trackable goes in, which is the only
    ; way it can become part of one.
    mov rax, rbx
    pop rbx
    leave
    ret
END_FUNC dict_new

;; ============================================================================
;; dict_copy_shallow(rdi = src dict) -> rax = a new dict, or 0
;;
;; BOTH TABLES ARE CLONED, not re-inserted.  The copy takes the source's
;; capacity, so the sparse index array transfers as it stands and not one key
;; is hashed or probed; the dense array is memcpy'd up to its high-water mark,
;; holes and all, which is what keeps the index array's dummies pointing at
;; the right slots and keeps insertion order.  CPython's clone_combined_dict_keys.
;;
;; It used to walk every slot of the source and call dict_set per entry -- a
;; hash, a probe, a tracking check and a version bump for each -- and read
;; 0.18x of CPython on d_copy and 0.13x on d_from_dict.  Cloning is one
;; ap_memcpy each way and one pass taking a reference per live element.
;;
;; The copy holds exactly what the source holds, so a NON-EMPTY one is
;; collector-tracked exactly when the source is and the bit needs no
;; re-derivation.  An EMPTY source yields an untracked copy however the source
;; itself is marked, which is CPython's answer as well -- PyDict_Copy returns a
;; plain PyDict_New() when ma_used is 0.  The two come apart because clear()
;; does not untrack: `d = {1: []}; d.clear()` leaves a dict that is still in a
;; generation and holds nothing, and a copy of it holds nothing either, so it
;; cannot be part of a cycle and there is nothing for the collector to walk.
;;
;; dict.copy() is this, and so is the namespace copy type_from_parts makes:
;; a class must not keep the caller's dict as its tp_dict, or `ns['x'] = 1`
;; after `type(n, b, ns)` would edit the live class.
;; ============================================================================
DEF_FUNC dict_copy_shallow      ; 4 pushes, so rsp stays 16-aligned
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi                ; src
    call dict_new
    test rax, rax
    jz .dcs_out
    mov r12, rax                ; dst

    ; An empty source needs no table at all: the shared one is already right.
    ; This also skips the tracking below, deliberately -- see the docblock.
    cmp qword [rbx + PyDictObject.ob_size], 0
    je .dcs_done

    mov rdi, r12
    mov rsi, [rbx + PyDictObject.capacity]
    call dict_alloc_tables      ; same capacity, so the indices transfer as-is

    mov rdi, [r12 + PyDictObject.entries]
    mov rsi, [rbx + PyDictObject.entries]
    mov rdx, [rbx + PyDictObject.dk_nentries]
    imul rdx, rdx, DICT_ENTRY_SIZE
    call ap_memcpy

    mov rdi, [r12 + PyDictObject.dk_indices]
    mov rsi, [rbx + PyDictObject.dk_indices]
    mov rdx, [rbx + PyDictObject.capacity]
    shl rdx, 3
    call ap_memcpy

    mov rax, [rbx + PyDictObject.dk_nentries]
    mov [r12 + PyDictObject.dk_nentries], rax
    mov rax, [rbx + PyDictObject.dk_tombstones]
    mov [r12 + PyDictObject.dk_tombstones], rax
    mov rax, [rbx + PyDictObject.ob_size]
    mov [r12 + PyDictObject.ob_size], rax
    mov rax, [rbx + PyDictObject.dk_kind]
    mov [r12 + PyDictObject.dk_kind], rax

    ; One reference for each key and value the copy now holds.  A hole in the
    ; dense array carries a zero key and owns nothing.
    mov r13, [r12 + PyDictObject.entries]
    mov r14, [r12 + PyDictObject.dk_nentries]
    imul r14, r14, DICT_ENTRY_SIZE
    add r14, r13
.dcs_loop:
    cmp r13, r14
    jae .dcs_track
    mov rax, [r13 + DictEntry.key]
    test rax, rax
    jz .dcs_next
    INCREF_V rax, rcx
    mov rax, [r13 + DictEntry.value]
    INCREF_V rax, rcx
.dcs_next:
    add r13, DICT_ENTRY_SIZE
    jmp .dcs_loop

.dcs_track:
    ; Tracked when the source is: the copy holds the same objects.  Only a
    ; non-empty source reaches here.
    cmp qword [rbx - GC_HEAD_SIZE + PyGC_Head.gc_next], 0
    je .dcs_done
    mov rdi, r12
    call gc_track

.dcs_done:
    mov rax, r12
.dcs_out:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_copy_shallow

;; ============================================================================
;; dict_release_tables(rdi = dict) -> void
;;
;; Hand the dict back to the shared empty table, releasing whatever it had.
;; What clear() means, and cheaper than what it used to do: an ap_memset over
;; capacity*24 bytes and a `rep stosq` over capacity*8 more, keeping a table
;; whose contents are all gone.  CPython's dict_clear points ma_keys at
;; Py_EMPTY_KEYS for the same reason.
;; ============================================================================
DEF_FUNC dict_release_tables, 8         ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyDictObject.entries]
    lea rax, [rel dict_empty_entries]
    cmp rdi, rax
    je .drt_done                        ; already shared; nothing to release
    call ap_free
    mov rdi, [rbx + PyDictObject.dk_indices]
    call ap_free
    mov qword [rbx + PyDictObject.capacity], 1
    mov qword [rbx + PyDictObject.dk_kind], 1   ; no keys left to disprove it
    lea rax, [rel dict_empty_entries]
    mov [rbx + PyDictObject.entries], rax
    lea rax, [rel dict_empty_indices]
    mov [rbx + PyDictObject.dk_indices], rax
.drt_done:
    pop rbx
    leave
    ret
END_FUNC dict_release_tables

;; ============================================================================
;; dict_clear_all(rdi = dict) -> void
;; Empty a dict and release everything it held.
;;
;; The tables are DETACHED first, and only then walked.  Releasing a value runs
;; its __del__, which is arbitrary Python and may call clear() on this same
;; dict -- and a second call that still found these entries installed released
;; every one of them a second time, freeing objects the first call was in the
;; middle of.  CPython's PyDict_Clear installs the empty table before it drops
;; a single reference, for exactly this reason.  Nothing hands out a pointer to
;; the detached table, so the walk below needs no re-reading and no clearing.
;; ============================================================================
DCA_BASE    equ 8              ; the detached entry array, to free
DCA_CUR     equ 16             ; the cursor into it
DCA_INDICES equ 24             ; the detached index array, to free
DCA_COUNT   equ 32
DCA_VAL     equ 40
DCA_FRAME   equ 56             ; + 1 push = 64, 16-aligned
DEF_FUNC dict_clear_all, DCA_FRAME
    push rbx
    mov rbx, rdi

    mov rax, [rbx + PyDictObject.entries]
    mov rcx, [rbx + PyDictObject.dk_indices]
    mov rdx, [rbx + PyDictObject.capacity]
    mov [rbp - DCA_BASE], rax
    mov [rbp - DCA_CUR], rax
    mov [rbp - DCA_INDICES], rcx
    mov [rbp - DCA_COUNT], rdx

    lea rcx, [rel dict_empty_entries]
    cmp rax, rcx
    jne .dca_detach
    ; Already sharing the empty table: nothing of ours to release or free.
    mov qword [rbp - DCA_BASE], 0
    mov qword [rbp - DCA_COUNT], 0
    jmp .dca_reset

.dca_detach:
    mov [rbx + PyDictObject.entries], rcx
    lea rcx, [rel dict_empty_indices]
    mov [rbx + PyDictObject.dk_indices], rcx
    mov qword [rbx + PyDictObject.capacity], 1
    mov qword [rbx + PyDictObject.dk_kind], 1   ; no keys left to disprove it

.dca_reset:
    mov qword [rbx + PyDictObject.ob_size], 0
    mov qword [rbx + PyDictObject.dk_nentries], 0
    mov qword [rbx + PyDictObject.dk_tombstones], 0
    inc qword [rbx + PyDictObject.dk_version]

.dca_loop:
    cmp qword [rbp - DCA_COUNT], 0
    je .dca_free
    dec qword [rbp - DCA_COUNT]
    mov rax, [rbp - DCA_CUR]
    mov rdi, [rax + DictEntry.key]
    test rdi, rdi
    jz .dca_next                    ; empty slot or tombstone
    mov rcx, [rax + DictEntry.value]
    mov [rbp - DCA_VAL], rcx
    DECREF_V rdi, rax
    mov rdi, [rbp - DCA_VAL]
    DECREF_V rdi, rax
.dca_next:
    add qword [rbp - DCA_CUR], DICT_ENTRY_SIZE
    jmp .dca_loop

.dca_free:
    cmp qword [rbp - DCA_BASE], 0
    je .dca_done
    mov rdi, [rbp - DCA_BASE]
    call ap_free
    mov rdi, [rbp - DCA_INDICES]
    call ap_free
.dca_done:
    pop rbx
    leave
    ret
END_FUNC dict_clear_all

;; ============================================================================
;; dict_alloc_tables(rdi = dict, rsi = capacity)
;; Allocates the dense entry array (zeroed, so the unused tail reads as empty)
;; and the sparse index array (all DICT_IX_EMPTY).  Sets .capacity.
;; ============================================================================
DEF_FUNC dict_alloc_tables, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov [rbx + PyDictObject.capacity], r12

    ; dense entries, zero-filled
    mov rdi, r12
    imul rdi, rdi, DICT_ENTRY_SIZE
    call ap_malloc
    mov [rbx + PyDictObject.entries], rax
    mov rdi, rax
    mov rcx, r12
    imul rcx, rcx, DICT_ENTRY_SIZE / 8
    xor eax, eax
    rep stosq

    ; sparse indices, all empty
    lea rdi, [r12 * 8]
    call ap_malloc
    mov [rbx + PyDictObject.dk_indices], rax
    mov rdi, rax
    mov rcx, r12
    mov rax, DICT_IX_EMPTY
    rep stosq

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_alloc_tables

;; ============================================================================
;; dict_type_call(PyTypeObject *type, PyObject **args, int64_t nargs) -> PyDictObject*
;; Constructor: dict() or dict(mapping)
;; ============================================================================
extern dict_method_update

DEF_FUNC dict_type_call, 8            ; 5 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rsi               ; args
    mov r12, rdx               ; nargs

    ; Check for keyword arguments
    mov r14, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0  ; clear immediately

    ; Determine positional arg count
    xor r13d, r13d             ; r13 = n_pos = nargs
    mov r13, r12
    test r14, r14
    jz .dtc_no_kw
    mov rax, [r14 + PyTupleObject.ob_size]
    sub r13, rax               ; r13 = n_pos = nargs - n_kw

.dtc_no_kw:
    ; dict() with no pos args (may have kwargs)
    test r13, r13
    jz .dtc_no_pos

    ; dict(arg) - one positional arg (may also have kwargs)
    cmp r13, 1
    jne .dtc_nargs_error

    ; Check if arg is a dict
    mov rdi, [rbx]             ; args[0]
    V_TEST_PTR rdi, rax
    ja .dtc_try_iterable
    mov rax, [rdi + PyObject.ob_type]
    REQUIRE_DICT_TYPE rax, rcx, .dtc_try_iterable

    ; dict(other_dict) is a copy, and dict_copy_shallow is what a copy is:
    ; both tables cloned, nothing re-hashed.  The loop that was here walked
    ; every slot and called dict_set per entry, with a three-register push
    ; bracket around each call.
    call dict_copy_shallow
    mov r15, rax
    test rax, rax
    jz .dtc_error
    ; Fall through to add kwargs if present
    jmp .dtc_add_kwargs

.dtc_try_iterable:
    ; Not a dict.  "A mapping, or an iterable of pairs" is exactly what
    ; dict.update means, so it is decided in one place: build an empty dict and
    ; update it.  Doing it again here is how the constructor came to accept
    ; pairs and reject a mappingproxy while update accepted both.
    call dict_new
    mov r15, rax
    sub rsp, 24
    mov [rsp], r15
    mov rax, [rbx]                      ; args[0]
    mov [rsp + 8], rax
    mov rdi, rsp
    mov esi, 2
    call dict_method_update             ; kw_names_pending is already cleared
    add rsp, 24
    test rax, rax
    jz .dtc_error                       ; update left its exception pending
    mov rdi, rax
    DECREF_V rdi, rsi                   ; the None it returns
    jmp .dtc_add_kwargs

.dtc_iter_type_error:
    ; DECREF iterator and raise TypeError
    mov rdi, r13
    call obj_decref
    jmp .dtc_error

.dtc_error_pop:
    add rsp, 8
    jmp .dtc_error

.dtc_no_pos:
    ; No positional args — create empty dict (kwargs will be added below)
    call dict_new
    mov r15, rax

.dtc_add_kwargs:
    ; Add keyword arguments if present
    test r14, r14
    jz .dtc_return_dict

    ; r14 = kw_names tuple, rbx = args, r13 was n_pos (now reuse)
    ; kwargs start at args[n_pos] — reload n_pos
    mov rax, r12               ; total nargs
    mov rcx, [r14 + PyTupleObject.ob_size]
    sub rax, rcx               ; rax = n_pos
    mov r13, rcx               ; r13 = n_kw
    mov rcx, rax               ; rcx = n_pos (index into args)

    ; kw_names.ob_item has the key strings, args[n_pos + i] has values
    mov rax, [r14 + PyTupleObject.ob_item]      ; keys payload array
    xor r8d, r8d              ; kw index
.dtc_kw_loop:
    cmp r8, r13
    jge .dtc_return_dict

    ; Calculate arg position: args[(n_pos + r8)]
    push r8
    push rcx
    push rax
    push rdx

    ; Get key from kw_names
    mov rsi, [rax + r8*8]         ; key payload (string)
    V_UNPACK rsi, r8

    ; Get value from args
    lea r9, [rcx + r8]            ; wait, need original r8 (kw index)
    ; Recalculate: value is at args[n_pos + kw_index]
    pop rdx
    pop rax
    pop rcx
    pop r8

    push r8
    push rcx
    push rax
    push rdx

    ; key from kw_names tuple items
    mov r9, [r14 + PyTupleObject.ob_item]
    mov rsi, [r9 + r8*8]         ; key Value

    ; value from args: index = n_pos + kw_index
    add rcx, r8                   ; rcx = n_pos + kw_index
    shl rcx, 3                    ; one Value per arg slot
    mov rdx, [rbx + rcx]         ; value Value

    ; dict_set(dict, key Value, value Value)
    mov rdi, r15
    call dict_set

    pop rdx
    pop rax
    pop rcx
    pop r8
    inc r8
    jmp .dtc_kw_loop

.dtc_return_dict:
    mov rax, r15
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.dtc_nargs_error:
    mov rsi, r13
    CSTRING rdi, "dict expected at most 1 argument, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted

.dtc_error:
    ; Reached both when the argument is the wrong TYPE and when reading it
    ; RAISED -- dict_method_update answers 0 for either, as the comment at
    ; .dtc_try_iterable says.  Substituting a type error over a pending
    ; exception threw the real one away: dict(map(f, xs)) for an f that raises
    ; reported "dict() argument must be a mapping or iterable".
    cmp qword [gs:ThreadState.current_exception], 0
    jne .dtc_propagate
    extern exc_TypeError_type
    RAISE exc_TypeError_type, "dict() argument must be a mapping or iterable"

.dtc_propagate:
    extern eval_exception_unwind
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    jmp eval_exception_unwind
END_FUNC dict_type_call


;; ============================================================================
;; dict_get(rdi=dict, rsi=key Value) -> rax = value Value, or 0 when absent
;; Linear probing lookup
;; ============================================================================
DEF_FUNC dict_get, 8            ; + 1 push = 16, 16-aligned
    ; One push, not two: r12 was saved and never touched, and this is on the
    ; path of every global load and every attribute lookup.  The frame carries
    ; the alignment instead, which is where STYLE.md says padding belongs.
    push rbx
    mov rbx, rdi                ; the dict; rdi does not survive the call
    call dict_lookup            ; rax = entries index or -1
    test rax, rax
    js .dg_miss
    mov rcx, [rbx + PyDictObject.entries]
    imul rax, rax, DICT_ENTRY_SIZE
    mov rax, [rcx + rax + DictEntry.value]
    pop rbx
    leave
    ret
.dg_miss:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC dict_get

;; ============================================================================
;; dict_lookup(rdi = dict, rsi = key Value) -> rax = entries index, or -1
;;   rdx = the indices slot the key hashes to (where an insert would go, or
;;         the first dummy on the probe path), r8 = hash
;; The one probe loop; every read path goes through it.
;;
;; TWO probe loops, chosen once on entry, as CPython 3.12 does.  Everything
;; invariant for the call is in a REGISTER -- the index array, the entry
;; array, the key, the slot and the mask -- because the loop used to reload
;; all five from the dict header and the frame on every single iteration.
;; Eight loads to answer a question that, for an interned name hitting on the
;; first probe, is one indexed load and one pointer compare.
;;
;; The str loop is entered only when the probe key is an exact str AND the
;; dict's dk_kind says every key in it is one, so it can compare bytes
;; without first asking what the STORED key is.  Everything else -- an int, a
;; tuple, an object, or a str probe into a dict that has seen a non-str key --
;; takes the generic loop, which asks obj_richcompare_bool.  A str probing a
;; mixed dict gets a correct but slower answer, which is the trade CPython
;; makes with its third loop and this does not.
;;
;; Both loops try IDENTITY first.  Interning makes that the answer for every
;; attribute name, every global and every keyword; it used to sit behind a
;; frame-slot load and a memory compare.
;;
;; There is no probe counter.  Every slot that is not EMPTY was claimed by an
;; insert, so the non-empty count is dk_nentries, which dict_set holds at
;; three quarters of capacity -- a quarter of the table is always EMPTY and
;; the walk always ends.
;; ============================================================================
DL_HASH  equ 8
DL_FREE  equ 16
DL_IX    equ 24            ; the candidate index, across a comparison call
DL_DICT  equ 32            ; ... and the dict, to see whether it moved
DL_CMPKEY equ 40           ; ... and the key that was compared
DL_PERT  equ 48            ; the probe recurrence's remaining hash bits
DL_FRAME equ 56            ; + 5 pushes = 96, 16-aligned

; rbx = dk_indices, r12 = entries, r13 = the key, r14 = slot, r15 = mask
%macro DL_SETUP 0
    mov rbx, [rdi + PyDictObject.dk_indices]
    mov r12, [rdi + PyDictObject.entries]
    mov r15, [rdi + PyDictObject.capacity]
    dec r15                     ; the mask
    mov r14, [rbp - DL_HASH]
    mov [rbp - DL_PERT], r14     ; the whole hash, folded in a step at a time
    and r14, r15                 ; the first slot
    mov qword [rbp - DL_FREE], -1
%endmacro

; i = (i*5 + perturb + 1) & mask, with perturb shifted down each step.  The
; first slot uses the hash's LOW bits only; this is what brings the high ones
; into play.  Linear probing does not, and with an identity hash for integers
; the fixed probe order is the same order consecutive keys arrive in, which
; is the case CPython's own comment calls deadly.
%macro DL_ADVANCE 0
    mov rax, [rbp - DL_PERT]
    shr rax, PERTURB_SHIFT
    mov [rbp - DL_PERT], rax
    lea r14, [r14 + r14*4]
    add r14, rax
    inc r14
    and r14, r15
%endmacro

; The entry at index %2, without the 3-cycle `imul reg, reg, 24`.
%macro DL_ENTRY 2               ; %1 = dst, %2 = index
    lea %1, [%2 + %2*2]
    lea %1, [r12 + %1*8]
%endmacro

DEF_FUNC dict_lookup, DL_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r13, rsi                ; the key, held for the whole call
    mov [rbp - DL_DICT], rdi

    ; --- the hash, and which loop -----------------------------------------
    V_IS_INT rsi, rax
    jae .dl_int_key
    V_TEST_PTR rsi, rax
    ja .dl_hash_generic         ; a float immediate has no cached hash
    test rsi, rsi
    jz .dl_hash_generic
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .dl_hash_generic
    ; The hash is cached in the string itself, so the indirect obj_hash call
    ; is pure overhead once it has been taken.  -1 is the "not yet" sentinel;
    ; fall through to obj_hash to compute and cache it the first time.
    mov rax, [rsi + PyStrObject.ob_hash]
    cmp rax, -1
    je .dl_hash_generic
    mov [rbp - DL_HASH], rax
    cmp qword [rdi + PyDictObject.dk_kind], 0
    je .dl_generic_setup        ; a key of some other type is in the table
    DL_SETUP
    jmp .dls_probe

.dl_int_key:
    ; An int immediate IS its own hash: int_hash_i64 answers v whenever
    ; |v| is below PYHASH_MODULUS, and +-2^50 is well inside that.  The only
    ; exception is CPython's, that hash(-1) is -2.  This used to be a call to
    ; obj_hash, which unpacked the Value, walked a tag ladder and tail-jumped
    ; to int_hash_i64 to compute v from v.
    mov rax, rsi
    V_TO_I64 rax
    cmp rax, -1
    jne .dl_have_hash
    mov rax, -2
    jmp .dl_have_hash

.dl_hash_generic:
    push rdi
    push rdi                    ; twice: rsp keeps its alignment
    mov rdi, rsi
    call obj_hash
    pop rdi
    pop rdi
.dl_have_hash:
    mov [rbp - DL_HASH], rax
.dl_generic_setup:
    DL_SETUP
    jmp .dlg_probe

;; --- str against str, in a table of nothing but strs ----------------------
.dls_probe:
    mov rax, [rbx + r14*8]      ; the index stored at this slot
    test rax, rax
    js .dls_no_entry            ; EMPTY (-1) or DUMMY (-2)
    DL_ENTRY rcx, rax
    mov rdx, [rbp - DL_HASH]
    cmp rdx, [rcx + DictEntry.hash]
    jne .dls_next
    mov rdi, [rcx + DictEntry.key]
    cmp rdi, r13
    je .dl_out_found            ; the same object, which interning makes the
                                ; common case for a name
    ; Length, then bytes -- CPython's unicode_eq, in Objects/stringlib/eq.h.
    ; Nothing here can run Python, so the table cannot move underneath it.
    mov rdx, [rdi + PyStrObject.ob_size]
    cmp rdx, [r13 + PyStrObject.ob_size]
    jne .dls_next
    mov [rbp - DL_IX], rax
    lea rdi, [rdi + PyStrObject.data]
    lea rsi, [r13 + PyStrObject.data]
    call ap_memcmp
    test eax, eax
    jnz .dls_next
    mov rax, [rbp - DL_IX]
    jmp .dl_out_found
.dls_no_entry:
    cmp rax, DICT_IX_EMPTY
    je .dl_miss
    cmp qword [rbp - DL_FREE], -1   ; the first dummy is where an insert goes
    jne .dls_next
    mov [rbp - DL_FREE], r14
.dls_next:
    DL_ADVANCE
    jmp .dls_probe

;; --- everything else ------------------------------------------------------
.dlg_probe:
    mov rax, [rbx + r14*8]
    test rax, rax
    js .dlg_no_entry
    DL_ENTRY rcx, rax
    mov rdx, [rbp - DL_HASH]
    cmp rdx, [rcx + DictEntry.hash]
    jne .dlg_next
    mov rdi, [rcx + DictEntry.key]
    cmp rdi, r13
    je .dl_out_found            ; identical Values are equal, whatever they are
    ; obj_richcompare_bool, reached directly.  dict_keys_equal was a whole
    ; extra frame whose entire body was to set edx and test the answer for -1.
    mov [rbp - DL_IX], rax
    mov [rbp - DL_CMPKEY], rdi
    mov rsi, r13
    mov edx, PY_EQ
    call obj_richcompare_bool
    cmp eax, -1
    je .dl_error

    ; THE TABLE MAY HAVE MOVED.  __eq__ is arbitrary Python and may insert
    ; into the very dict being probed; a resize frees both arrays and
    ; rehashes into new ones, which leaves the two pointers and the mask in
    ; registers stale.  This is the only comparison in either loop that can
    ; run Python -- the str loop compares bytes -- and it is why the old code
    ; reloaded the arrays from the header on EVERY probe.  Ask once, here,
    ; and start again if the answer changed: CPython returns DKIX_KEY_CHANGED
    ; and its caller does the same.
    mov rcx, [rbp - DL_DICT]
    cmp rbx, [rcx + PyDictObject.dk_indices]
    jne .dl_restart
    mov rcx, [rbp - DL_IX]
    DL_ENTRY rcx, rcx
    mov rcx, [rcx + DictEntry.key]
    cmp rcx, [rbp - DL_CMPKEY]
    jne .dl_restart             ; the entry itself was deleted or rebound

    test eax, eax
    jz .dlg_next
    mov rax, [rbp - DL_IX]
    jmp .dl_out_found

.dl_restart:
    mov rdi, [rbp - DL_DICT]
    DL_SETUP
    jmp .dlg_probe
.dlg_no_entry:
    cmp rax, DICT_IX_EMPTY
    je .dl_miss
    cmp qword [rbp - DL_FREE], -1
    jne .dlg_next
    mov [rbp - DL_FREE], r14
.dlg_next:
    DL_ADVANCE
    jmp .dlg_probe

.dl_miss:
    ; An insert goes into the first dummy seen, else this empty slot.
    mov rcx, [rbp - DL_FREE]
    cmp rcx, -1
    je .dl_out_miss
    mov r14, rcx
.dl_out_miss:
    mov rax, -1
.dl_out_found:
    mov rdx, r14
    mov r8, [rbp - DL_HASH]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.dl_error:
    ; The probe loop has no error channel; the exception is already pending.
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    jmp eval_exception_unwind
END_FUNC dict_lookup

;; ============================================================================
;; dict_get_index(rdi=dict, rsi=key, edx=key_tag) -> int64
;; Like dict_get but returns the slot index (for IC caching), -1 if not found.
;; ============================================================================
DEF_FUNC dict_get_index, 16     ; + 0 pushes = 16, 16-aligned
    ; The index into the *dense* array, which the LOAD_GLOBAL inline cache
    ; caches.  A dense index never moves except on a resize, and the cache is
    ; already guarded by dk_version, so it is strictly more stable than the
    ; hash slot this used to return.
    ;
    ; rbx was pushed and popped purely to align rsp for the call; the frame
    ; does that now, without the two instructions.
    call dict_lookup
    leave
    ret
END_FUNC dict_get_index

;; ============================================================================
;; dict_find_slot(rdi=dict, rsi=key, rdx=hash, rcx=key_tag)
;;   -> rax = entry ptr, rdx = 1 if existing key found, 0 if empty/tombstone slot
;; Internal helper used by dict_set.
;; Tombstone reuse: if no match found but a tombstone was seen, returns it
;; instead of the empty slot, so inserts reclaim deleted entries.
;; ============================================================================

;; ============================================================================
;; dict_resize(PyDictObject *dict)
;; Double capacity and rehash all entries
;; ============================================================================
DR_DICT  equ 8
DR_OLDE  equ 16
DR_OLDN  equ 24
DR_FRAME equ 40            ; + 3 pushes = 64, 16-aligned
DEF_FUNC dict_resize_to, DR_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi                ; the capacity asked for
    mov [rbp - DR_DICT], rbx
    mov rax, [rbx + PyDictObject.entries]
    mov [rbp - DR_OLDE], rax
    mov rax, [rbx + PyDictObject.dk_nentries]
    mov [rbp - DR_OLDN], rax
    ; r12, not rcx: ap_free below is a call and rcx is caller-saved.
    mov rdi, [rbx + PyDictObject.dk_indices]
    lea rax, [rel dict_empty_indices]
    cmp rdi, rax
    je .dr_alloc
    call ap_free
.dr_alloc:
    mov rdi, rbx
    mov rsi, r12
    call dict_alloc_tables

    ; Re-append the live entries in their existing order, dropping holes.
    mov qword [rbx + PyDictObject.dk_nentries], 0
    mov qword [rbx + PyDictObject.dk_tombstones], 0
    xor r12d, r12d              ; index into the old dense array
.dr_loop:
    cmp r12, [rbp - DR_OLDN]
    jge .dr_done
    mov rax, [rbp - DR_OLDE]
    imul rcx, r12, DICT_ENTRY_SIZE
    add rax, rcx
    cmp qword [rax + DictEntry.key], 0
    je .dr_next

    ; place it: hash is already known, so probe the fresh index array
    mov r13, [rax + DictEntry.hash]
    mov rcx, [rbx + PyDictObject.capacity]
    dec rcx
    mov rdx, r13
    and rdx, rcx                ; slot
    mov r8, r13                 ; perturb
.dr_probe:
    mov rsi, [rbx + PyDictObject.dk_indices]
    cmp qword [rsi + rdx*8], DICT_IX_EMPTY
    je .dr_place
    shr r8, PERTURB_SHIFT       ; the same recurrence dict_lookup walks
    lea rdx, [rdx + rdx*4]
    add rdx, r8
    inc rdx
    and rdx, rcx
    jmp .dr_probe
.dr_place:
    mov rdi, [rbx + PyDictObject.dk_nentries]
    mov [rsi + rdx*8], rdi
    mov rsi, [rbx + PyDictObject.entries]
    imul rcx, rdi, DICT_ENTRY_SIZE
    add rsi, rcx
    mov rcx, [rax + DictEntry.hash]
    mov [rsi + DictEntry.hash], rcx
    mov rcx, [rax + DictEntry.key]
    mov [rsi + DictEntry.key], rcx
    mov rcx, [rax + DictEntry.value]
    mov [rsi + DictEntry.value], rcx
    inc qword [rbx + PyDictObject.dk_nentries]

.dr_next:
    inc r12
    jmp .dr_loop

.dr_done:
    mov rdi, [rbp - DR_OLDE]
    lea rax, [rel dict_empty_entries]
    cmp rdi, rax
    je .dr_out
    call ap_free
.dr_out:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_resize_to

;; ============================================================================
;; dict_resize(rdi = dict) -> void
;;
;; Rebuild at whatever capacity the live count warrants: double it when the
;; dict is at least half full, and otherwise keep it, which compacts a table
;; that is mostly holes.  The floor matters because a dict growing away from
;; the shared empty table has capacity one, and doubling that is two.
;; ============================================================================
DEF_FUNC_BARE dict_resize
    mov rsi, [rdi + PyDictObject.capacity]
    mov rax, rsi
    shr rax, 1
    cmp [rdi + PyDictObject.ob_size], rax
    jl .drz_same
    shl rsi, 1
.drz_same:
    cmp rsi, DICT_INIT_CAP
    jae dict_resize_to
    mov esi, DICT_INIT_CAP
    jmp dict_resize_to
END_FUNC dict_resize

;; ============================================================================
;; dict_reserve(rdi = dict, rsi = how many more entries are coming) -> void
;;
;; Grow ONCE, so that a bulk insert of a known size does not rebuild the
;; table on the way.  Building a hundred-key dict from an empty one resized
;; five times, rehashing everything each time; CPython presizes in exactly
;; the same places -- dict_merge, BUILD_MAP, dict.fromkeys -- and for exactly
;; this reason.
;;
;; The table holds dk_nentries at three quarters of capacity, so the room
;; needed is that many slots rounded up to a power of two.  A dict that
;; already has the room is left alone, which is what makes it safe to call on
;; the shared empty table with nothing coming.
;; ============================================================================
DEF_FUNC_BARE dict_reserve
    mov rax, [rdi + PyDictObject.dk_nentries]
    add rax, rsi
    mov rcx, [rdi + PyDictObject.capacity]
    mov rdx, rcx
    shr rdx, 2
    lea rdx, [rdx + rdx*2]      ; capacity * 3/4
    cmp rax, rdx
    jbe .drv_done               ; the room is already there
    cmp rcx, DICT_INIT_CAP
    jae .drv_grow
    mov ecx, DICT_INIT_CAP
.drv_grow:
    mov rdx, rcx
    shr rdx, 2
    lea rdx, [rdx + rdx*2]
    cmp rax, rdx
    jbe .drv_resize
    shl rcx, 1
    jmp .drv_grow
.drv_resize:
    mov rsi, rcx
    jmp dict_resize_to
.drv_done:
    ret
END_FUNC dict_reserve

;; ============================================================================
;; dict_set(rdi=dict, rsi=key Value, rdx=value Value)
;; Insert or update a key-value pair.
;; ============================================================================
DS_DICT  equ 8
DS_KEY   equ 16
DS_VAL   equ 24
DS_FRAME equ 40            ; + 3 pushes = 64, 16-aligned
;; ============================================================================
;; dict_maybe_track(rdi = the dict, rsi = a key Value, rdx = a value Value)
;;
;; CPython's _PyDict_MaybeUntrack, from the other end: it untracks during a
;; collection, and this never tracks in the first place until there is a
;; reason to.  Either is what makes `gc.is_tracked({})` and
;; `gc.is_tracked({1: 2})` False -- a dict of numbers and strings cannot be
;; part of a cycle, so walking it during every collection buys nothing.
;;
;; "Trackable" is CPython's _PyObject_GC_MAY_BE_TRACKED: an immediate is not,
;; a str or bytes is not, and a tuple counts only while it is tracked itself.
;; gc_track is idempotent, so this is safe to call on every insertion.
;; ============================================================================
DEF_FUNC dict_maybe_track, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    cmp qword [rbx - GC_HEAD_SIZE + PyGC_Head.gc_next], 0
    jne .dmt_done               ; already in a generation
    push rdx                    ; the value, across the key's test
    mov rdi, rsi
    call dict_value_trackable
    pop rdi                     ; the value
    test eax, eax
    jnz .dmt_track
    call dict_value_trackable
    test eax, eax
    jz .dmt_done
.dmt_track:
    mov rdi, rbx
    extern gc_track
    call gc_track
.dmt_done:
    pop rbx
    leave
    ret
END_FUNC dict_maybe_track

;; dict_value_trackable(rdi = a Value) -> eax = 1 when the collector could
;; ever have to walk into it
DEF_FUNC_BARE dict_value_trackable
    xor eax, eax
    V_TEST_PTR rdi, rcx
    ja .dvt_no                  ; an immediate is not an object
    test rdi, rdi
    jz .dvt_no
    mov rcx, [rdi + PyObject.ob_type]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .dvt_no                  ; a str, a bytes, None, a bool
    ; A tuple is trackable only while it is tracked: an untracked one holds
    ; nothing the collector could reach, and CPython says the same.
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    jne .dvt_yes
    cmp qword [rdi - GC_HEAD_SIZE + PyGC_Head.gc_next], 0
    je .dvt_no
.dvt_yes:
    mov eax, 1
.dvt_no:
    ret
END_FUNC dict_value_trackable

DEF_FUNC dict_set, DS_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - DS_DICT], rdi
    mov [rbp - DS_KEY], rsi
    mov [rbp - DS_VAL], rdx

    ; Anything trackable going in is what makes the dict itself trackable.
    call dict_maybe_track
    mov rdi, [rbp - DS_DICT]
    mov rsi, [rbp - DS_KEY]
    mov rdx, [rbp - DS_VAL]

    call dict_lookup            ; rax = index or -1, rdx = slot, r8 = hash
    mov rbx, [rbp - DS_DICT]
    test rax, rax
    js .ds_insert

    ; Update in place: the key keeps its position, as in CPython.
    mov rcx, [rbx + PyDictObject.entries]
    imul rax, rax, DICT_ENTRY_SIZE
    add rcx, rax
    mov rdi, [rcx + DictEntry.value]
    mov rsi, [rbp - DS_VAL]
    mov [rcx + DictEntry.value], rsi
    INCREF_V rsi, rax
    DECREF_V rdi, rax
    jmp .ds_bump

.ds_insert:
    mov r12, rdx                ; the indices slot to claim
    mov r13, r8                 ; hash

    ; A key that is not an exact str ends the str probe loop's licence, for
    ; good.  Only an INSERT can do it: a lookup that misses changes nothing,
    ; and a delete leaves the remaining keys as they were.  CPython rebuilds
    ; the whole table here; one word is enough for the one bit we use.
    cmp qword [rbx + PyDictObject.dk_kind], 0
    je .ds_kind_known
    mov rax, [rbp - DS_KEY]
    V_TEST_PTR rax, rcx
    ja .ds_not_str
    mov rcx, [rax + PyObject.ob_type]
    lea rax, [rel str_type]
    cmp rcx, rax
    je .ds_kind_known
.ds_not_str:
    mov qword [rbx + PyDictObject.dk_kind], 0
.ds_kind_known:
    ; Room for one more dense entry?
    mov rax, [rbx + PyDictObject.dk_nentries]
    inc rax
    mov rcx, [rbx + PyDictObject.capacity]
    mov rdx, rcx
    shr rdx, 2
    lea rdx, [rdx + rdx*2]      ; capacity * 3/4
    cmp rax, rdx
    jle .ds_have_room

    mov rdi, rbx
    call dict_resize

    ; The slot is stale after a rebuild, and the replacement is found by
    ; PROBING FOR AN EMPTY ONE rather than by looking the key up again.
    ;
    ; A second dict_lookup is what this used to do, and dict_lookup is
    ; arbitrary Python: obj_hash on the way in, obj_richcompare_bool on a
    ; collision.  Either can clear this dict, and clear() points entries at
    ; the read-only dict_empty_entries and sets the capacity to one -- so the
    ; store below landed in .rodata, at an index the new capacity does not
    ; have.  Re-testing for room afterwards does not fix it either: __hash__
    ; runs on EVERY lookup, so a __hash__ that clears makes the resize and
    ; the re-lookup chase each other forever.
    ;
    ; Nothing needs looking up.  The key is known absent -- the lookup at the
    ; top of this function missed -- and dict_resize runs no user code, so it
    ; is absent still.  What is wanted is a free slot for a hash already in
    ; hand, and that is a comparison-free walk of the same recurrence
    ; dict_lookup and dict_resize_to use.  CPython's insertdict does exactly
    ; this: find_empty_slot, not a second lookup.  A rebuilt table has no
    ; dummies in it, so EMPTY is the only thing to look for.
    mov rcx, [rbx + PyDictObject.capacity]
    dec rcx                     ; mask
    mov r12, r13
    and r12, rcx                ; slot
    mov r8, r13                 ; perturb
.ds_empty_probe:
    mov rsi, [rbx + PyDictObject.dk_indices]
    cmp qword [rsi + r12*8], DICT_IX_EMPTY
    je .ds_have_room
    shr r8, PERTURB_SHIFT
    lea r12, [r12 + r12*4]
    add r12, r8
    inc r12
    and r12, rcx
    jmp .ds_empty_probe

.ds_have_room:
    mov rax, [rbx + PyDictObject.dk_nentries]
    mov rcx, [rbx + PyDictObject.entries]
    imul rdx, rax, DICT_ENTRY_SIZE
    add rcx, rdx
    mov [rcx + DictEntry.hash], r13
    mov rdx, [rbp - DS_KEY]
    mov [rcx + DictEntry.key], rdx
    INCREF_V rdx, rsi
    mov rdx, [rbp - DS_VAL]
    mov [rcx + DictEntry.value], rdx
    INCREF_V rdx, rsi

    ; point the sparse slot at it
    mov rcx, [rbx + PyDictObject.dk_indices]
    mov [rcx + r12*8], rax
    inc qword [rbx + PyDictObject.dk_nentries]
    inc qword [rbx + PyDictObject.ob_size]

.ds_bump:
    inc qword [rbx + PyDictObject.dk_version]
    jnz .ds_done
    mov qword [rbx + PyDictObject.dk_version], 1
.ds_done:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_set

;; ============================================================================
;; dict_dealloc(PyObject *self)
;; Free all entries, then free dict
;; ============================================================================
DEF_FUNC dict_dealloc, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r13, [rbx + PyDictObject.dk_nentries]
    xor r12d, r12d
.dde_loop:
    cmp r12, r13
    jge .dde_done
    mov rax, [rbx + PyDictObject.entries]
    imul rcx, r12, DICT_ENTRY_SIZE
    add rax, rcx
    mov rdi, [rax + DictEntry.key]
    test rdi, rdi
    jz .dde_next
    push rax
    DECREF_V rdi, rsi
    pop rax
    mov rdi, [rax + DictEntry.value]
    DECREF_V rdi, rsi
.dde_next:
    inc r12
    jmp .dde_loop
.dde_done:
    mov rdi, [rbx + PyDictObject.entries]
    lea rax, [rel dict_empty_entries]
    cmp rdi, rax
    je .dde_no_idx              ; the shared table; both halves are static
    test rdi, rdi
    jz .dde_no_entries
    call ap_free
.dde_no_entries:
    mov rdi, [rbx + PyDictObject.dk_indices]
    test rdi, rdi
    jz .dde_no_idx
    call ap_free
.dde_no_idx:
    mov rdi, rbx
    call gc_dealloc
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_dealloc

;; ============================================================================
;; dict_len(PyObject *self) -> int64_t
;; Returns ob_size (number of items)
;; ============================================================================
global dict_len
dict_len:
    mov rax, [rdi + PyDictObject.ob_size]
    ret

;; ============================================================================
;; dict_subscript(rdi = dict, rsi = key Value) -> rax = the value, as a Value
;; mp_subscript: look up the key; a dict SUBCLASS with a __missing__ answers
;; its own misses, and anything else raises KeyError naming the key.
;; ============================================================================
DSUB_DICT  equ 8
DSUB_FRAME equ 24           ; + 1 push = 32, 16-aligned
DEF_FUNC dict_subscript, DSUB_FRAME
    push rbx

    mov [rbp - DSUB_DICT], rdi ; the mapping, for __missing__ below
    mov rbx, rsi               ; save the key Value for the error message
    call dict_get              ; both take a key Value
    test rax, rax              ; a Value, and 0 is the only miss
    jz .key_error
    INCREF_V rax, rdx          ; dict_get's answer is borrowed
    pop rbx
    leave
    ret

.key_error:
    ; A dict SUBCLASS gets to answer for itself first.  CPython's
    ; dict_subscript asks __missing__ on any mapping that is not exactly a
    ; dict, and collections.defaultdict is only the best-known user of it:
    ; urllib.parse.quote builds a memoising dict subclass exactly this way, so
    ; quoting any character that was not already cached raised KeyError.
    mov rax, [rbp - DSUB_DICT]
    mov rax, [rax + PyObject.ob_type]
    lea rcx, [rel dict_type]
    cmp rax, rcx
    je .plain_key_error

    mov rdi, [rbp - DSUB_DICT]
    mov rsi, rbx
    V_UNPACK rsi, rcx           ; dunder_call_2 wants (payload, tag)
    CSTRING rdx, "__missing__"
    extern dunder_call_2
    call dunder_call_2
    test rax, rax
    jnz .ds_missing_answered
    ; 0 is "no __missing__" or "it raised"; only the first falls through to
    ; the KeyError this lookup was always going to give.
    cmp qword [gs:ThreadState.current_exception], 0
    jne .ds_missing_raised

.plain_key_error:
    ; The key itself is the argument, as in CPython: d["k"] reports
    ; KeyError('k'), not a fixed "key not found".  rbx already holds it.
    mov rdi, rbx               ; the key Value, saved on entry
    extern raise_key_error
    call raise_key_error

.ds_missing_answered:
    ; dunder_call_2 hands back a Value and this function ANSWERS with a Value
    ; -- the docblock above still described the old (payload, tag) pair, and
    ; unpacking here turned a returned int immediate into a pointer to the
    ; number.  `__missing__` returning 42 dereferenced address 42.
    pop rbx
    leave
    ret

.ds_missing_raised:
    pop rbx
    leave
    extern eval_exception_unwind
    jmp eval_exception_unwind
END_FUNC dict_subscript

;; ============================================================================
;; dict_ass_subscript(rdi=dict, rsi=key Value, rdx=value Value)
;; A value Value of 0 (NULL) means "delete this key".
;; mp_ass_subscript: set key=value or delete key from dict
;; ============================================================================
DEF_FUNC_BARE dict_ass_subscript
    ; A NULL Value is 0 and no real Value is, so this test needs no tag
    test rdx, rdx
    jz .das_delete
    jmp dict_set
.das_delete:
    jmp dict_del
END_FUNC dict_ass_subscript

;; ============================================================================
;; dict_del(rdi=dict, rsi=key Value) -> 0 on success; RAISES KeyError on a miss
;; dict_del_opt(rdi=dict, rsi=key Value) -> 0 on success, -1 on a miss
;;
;; Delete key from dict.  DECREFs both key and value.
;;
;; The two differ only in what a miss does.  dict_del's header used to
;; promise "-1 = not found" and then raise instead, so DELETE_NAME's
;; locals-then-globals fallback never ran and its NameError arm was
;; unreachable: `del undefined_global` reported the dict's KeyError, where
;; CPython says "name 'g' is not defined".
;; ============================================================================
DD_DICT  equ 8
DD_KEYV  equ 16
DD_QUIET equ 24             ; answer -1 instead of raising
DD_VAL   equ 32             ; the value, held while the key is released
DD_FRAME equ 48             ; + 2 pushes = 64
global dict_del_opt
DEF_FUNC dict_del_opt, DD_FRAME
    push rbx
    push r12
    mov [rbp - DD_DICT], rdi
    mov [rbp - DD_KEYV], rsi
    mov qword [rbp - DD_QUIET], 1
    jmp dict_del.dd_body
END_FUNC dict_del_opt

DEF_FUNC dict_del, DD_FRAME
    push rbx
    push r12
    mov [rbp - DD_DICT], rdi
    mov [rbp - DD_KEYV], rsi
    mov qword [rbp - DD_QUIET], 0
.dd_body:

    call dict_lookup            ; rax = index or -1, rdx = slot
    mov rbx, [rbp - DD_DICT]
    test rax, rax
    js .dd_missing
    mov r12, rdx                ; the slot to mark dummy

    ; Hole the dense entry.  It keeps its position so the surrounding order
    ; is preserved; the index array forgets it.
    mov rcx, [rbx + PyDictObject.entries]
    imul rax, rax, DICT_ENTRY_SIZE
    add rcx, rax
    mov rdi, [rcx + DictEntry.key]
    mov rsi, [rcx + DictEntry.value]
    mov [rbp - DD_VAL], rsi
    mov qword [rcx + DictEntry.key], 0
    mov qword [rcx + DictEntry.value], 0
    mov qword [rcx + DictEntry.hash], ENTRY_TOMBSTONE_HASH

    ; EVERY change to the table is made before either reference is released.
    ;
    ; A DECREF here can reach a __del__, and a __del__ is arbitrary Python:
    ; it can call clear() on this very dict, and clear() hands the tables
    ; back and points dk_indices at the one-slot read-only
    ; dict_empty_indices.  The store below used to come after, through a
    ; pointer read before -- so it landed in .rodata, at an index the new
    ; capacity does not have.  A twenty-key dict and a __del__ that clears it
    ; was a SIGSEGV.
    mov rcx, [rbx + PyDictObject.dk_indices]
    mov qword [rcx + r12*8], DICT_IX_DUMMY
    dec qword [rbx + PyDictObject.ob_size]
    inc qword [rbx + PyDictObject.dk_tombstones]
    inc qword [rbx + PyDictObject.dk_version]
    jnz .dd_release
    mov qword [rbx + PyDictObject.dk_version], 1

.dd_release:
    ; The table no longer refers to either of these, so whatever a __del__
    ; does with the dict from here finds it consistent.
    DECREF_V rdi, rax
    mov rdi, [rbp - DD_VAL]
    DECREF_V rdi, rax
.dd_done:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.dd_missing:
    cmp qword [rbp - DD_QUIET], 0
    je .dd_raise
    mov rax, -1
    pop r12
    pop rbx
    leave
    ret
.dd_raise:
    mov rdi, [rbp - DD_KEYV]
    call raise_key_error
END_FUNC dict_del

; dict_repr is in src/repr.asm
extern dict_repr

;; ============================================================================
;; dict_tp_iter(PyDictObject *dict) -> PyDictIterObject*
;; Create a new dict key iterator.
;; rdi = dict
;; ============================================================================
DEF_FUNC dict_tp_iter, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx

    mov rbx, rdi               ; save dict

    ; gc_alloc, not ap_malloc: the iterator holds the dict, and a dict holding
    ; its own iterator or its own view is a cycle only the collector can break.
    mov edi, PyDictIterObject_size
    lea rsi, [rel dict_iter_type]
    call gc_alloc

    mov [rax + PyDictIterObject.it_dict], rbx
    mov qword [rax + PyDictIterObject.it_index], 0
    mov qword [rax + PyDictIterObject.it_kind], 0  ; 0 = keys
    ; Snapshot the SIZE for mutation detection, as CPython's dictiter does.
    ; dk_version was the wrong field: dict_set bumps it on every write, the
    ; update-in-place branch included, so `for k in d: d[k] = f(d[k])` raised
    ; RuntimeError.  ob_size is sufficient on its own -- a resize only ever
    ; happens on an insert, and an insert always changes ob_size, so a
    ; rebuilt entry array cannot slip past a size comparison.
    mov rcx, [rbx + PyDictObject.ob_size]
    mov [rax + PyDictIterObject.it_version], rcx

    ; INCREF the dict
    push rax
    mov rdi, rbx
    call obj_incref
    pop rax
    push rax
    mov rdi, rax
    extern gc_track
    call gc_track
    pop rax

    pop rbx
    leave
    ret
END_FUNC dict_tp_iter

;; ============================================================================
;; dict_iter_next(PyDictIterObject *self) -> (rax=key, edx=key_tag) or (0, TAG_NULL)
;; Return next key, or (0, TAG_NULL) if exhausted.
;; Scans entries for next non-empty slot.
;; rdi = iterator
;; ============================================================================
extern exc_RuntimeError_type

DEF_FUNC_BARE dict_iter_next
    ; Mutation detection: compare saved version with current
    mov rax, [rdi + PyDictIterObject.it_dict]         ; dict
    test rax, rax
    jz .di_done                 ; already dropped, or cleared by the collector
    mov rcx, [rax + PyDictObject.ob_size]
    cmp rcx, [rdi + PyDictIterObject.it_version]
    jne .di_mutation_error

    mov r10, [rdi + PyDictIterObject.it_kind]         ; 0=keys, 1=values, 2=items
    mov rcx, [rdi + PyDictIterObject.it_index]        ; current index
    mov rdx, [rax + PyDictObject.capacity]            ; capacity
    mov rsi, [rax + PyDictObject.entries]              ; entries ptr

.di_scan:
    cmp rcx, rdx
    jge .di_exhausted

    ; Check if entry at index has a key (key_tag != TAG_NULL)
    imul rax, rcx, DictEntry_size
    add rax, rsi
    ENTRY_CLASSIFY rax, .di_skip, .di_skip

    ; Found a valid entry — advance index
    inc rcx
    mov [rdi + PyDictIterObject.it_index], rcx

    ; Branch on kind
    cmp r10, 1
    je .di_return_value
    ja .di_return_item

    ; kind=0: return key
    mov rax, [rax + DictEntry.key]
    INCREF_V rax, rdx
    ret

.di_return_value:
    ; kind=1: return value
    mov rax, [rax + DictEntry.value]
    INCREF_V rax, rdx
    ret

.di_return_item:
    ; kind=2: return (key, value) 2-tuple
    ; rax = entry ptr — need to allocate tuple, so must save entry
    push rbx
    push r12
    mov rbx, rax                ; save entry ptr

    ; Allocate 2-tuple
    mov edi, 2
    extern tuple_new
    call tuple_new
    mov r12, rax                ; r12 = new tuple

    mov r9, [r12 + PyTupleObject.ob_item]

    ; tuple[0] = key
    mov rax, [rbx + DictEntry.key]
    INCREF_V rax, rdx
    mov [r9], rax

    ; tuple[1] = value
    mov rax, [rbx + DictEntry.value]
    INCREF_V rax, rdx
    mov [r9 + 8], rax

    mov rax, r12

    pop r12
    pop rbx
    ret

.di_skip:
    inc rcx
    jmp .di_scan

.di_exhausted:
    ; Drop the dict at exhaustion, as CPython's dictiter does: it is what
    ; lets a __del__ holding the last reference run while the iterator can
    ; still answer "exhausted".  Clear before releasing -- list_iter_next
    ; carries the reason in full.
    mov [rdi + PyDictIterObject.it_index], rcx
    mov rax, [rdi + PyDictIterObject.it_dict]
    test rax, rax
    jz .di_done
    mov qword [rdi + PyDictIterObject.it_dict], 0
    push rdi
    mov rdi, rax
    call obj_decref
    pop rdi
.di_done:
    RET_NULL
    ret

.di_mutation_error:
    RAISE exc_RuntimeError_type, "dictionary changed size during iteration"
END_FUNC dict_iter_next

;; ============================================================================
;; dict_iter_dealloc(PyObject *self)
;; ============================================================================
DEF_FUNC_LOCAL dict_iter_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; DECREF the dict
    mov rdi, [rbx + PyDictIterObject.it_dict]
    call obj_decref

    ; Free self
    mov rdi, rbx
    extern gc_dealloc
    call gc_dealloc

    pop rbx
    leave
    ret
END_FUNC dict_iter_dealloc

;; ============================================================================
;; dict_iter_self(PyObject *self) -> self with INCREF
;; ============================================================================
dict_iter_self:
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret

;; ============================================================================
;; dict_contains(rdi=dict, rsi=key, edx=key_tag) -> int (0 or 1)
;; For the 'in' operator: checks if key exists in dict.
;; ============================================================================
DEF_FUNC_BARE dict_contains
    call dict_get
    test rax, rax               ; a Value, and 0 is the only miss
    setnz al
    movzx eax, al
    ret
END_FUNC dict_contains


;; ============================================================================
;; dict_nb_or(left, right, ltag, rtag) -> new dict (merge)
;; Implements dict | dict -> new dict containing all items from both.
;; Right dict values override left on key collision.
;; ============================================================================
DNO_LEFT  equ 8
DNO_RIGHT equ 16
DNO_NEW   equ 24
DNO_FRAME equ 32            ; + 0 pushes = 32

DEF_FUNC dict_nb_or, DNO_FRAME
    ; Both operands of `|` must be dicts.  These slots used to read whatever
    ; they were handed as a PyDictObject: `{1:2} | 5` dereferenced address
    ; 5 + capacity_offset.  A NULL Value declines, so the protocol can still
    ; reach a user class's __ror__.
    V_TEST_PTR rdi, rax         ; ja == not a pointer, so not a dict either
    ja .nb_or_decline
    V_TEST_PTR rsi, rax
    ja .nb_or_decline
    mov rax, [rdi + PyObject.ob_type]
    REQUIRE_DICT_TYPE rax, rcx, .nb_or_decline
    mov rax, [rsi + PyObject.ob_type]
    REQUIRE_DICT_TYPE rax, rcx, .nb_or_decline
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    mov [rbp - DNO_LEFT], rdi       ; left dict
    mov [rbp - DNO_RIGHT], rsi      ; right dict

    ; Create new dict
    ; The left half of `a | b` IS a copy of a, so it is a clone: no key is
    ; hashed and no slot is probed.  The loop that was here re-inserted every
    ; entry through dict_set.
    mov rdi, [rbp - DNO_LEFT]
    call dict_copy_shallow
    mov [rbp - DNO_NEW], rax

    ; Then room for the right half in one go, so the merge cannot rebuild
    ; the table underneath itself.
    mov rdi, rax
    mov rsi, [rbp - DNO_RIGHT]
    mov rsi, [rsi + PyDictObject.ob_size]
    call dict_reserve

.dno_copy_right_start:
    ; Copy all entries from right dict (overrides left), over the DENSE array
    mov rdi, [rbp - DNO_RIGHT]
    mov r8, [rdi + PyDictObject.dk_nentries]
    xor ecx, ecx
.dno_copy_right:
    cmp rcx, r8
    jge .dno_done

    imul rax, rcx, DICT_ENTRY_SIZE
    add rax, [rdi + PyDictObject.entries]
    cmp qword [rax + DictEntry.key], 0   ; occupied?
    je .dno_right_next

    push rcx
    push r8
    push rdi
    mov rdi, [rbp - DNO_NEW]
    mov rsi, [rax + DictEntry.key]
    mov rdx, [rax + DictEntry.value]
    call dict_set
    pop rdi
    pop r8
    pop rcx

.dno_right_next:
    inc rcx
    jmp .dno_copy_right

.dno_done:
    mov rax, [rbp - DNO_NEW]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; return one Value
    ret
.nb_or_decline:
    xor eax, eax                ; NULL Value = NotImplemented
    leave
    ret
END_FUNC dict_nb_or

;; ============================================================================
;; dict_nb_ior(left, right, ltag, rtag) -> left dict (inplace merge |=)
;; Iterates right dict entries and dict_set each into left.
;; Returns (left, TAG_PTR) with INCREF on left.
;; ============================================================================
DIO_LEFT  equ 8
DIO_RIGHT equ 16
DIO_ARGS  equ 32       ; args[0] at rbp-32, args[1] at rbp-24: an args array
                       ; grows upward, so its first slot is the deeper one
DIO_FRAME equ 32            ; + 0 pushes = 32, 16-aligned

DEF_FUNC dict_nb_ior, DIO_FRAME
    ; The LEFT operand must be a dict; the right can be anything dict.update
    ; takes -- a mapping, something with keys(), or an iterable of pairs --
    ; which is CPython's rule for `|=` and not for `|`.  This slot read
    ; whatever it was given as a PyDictObject, so `d |= 5` was an arbitrary
    ; dereference, and declining was the safe half of the answer.
    V_TEST_PTR rdi, rax         ; ja == not a pointer, so not a dict either
    ja .nb_ior_decline
    V_TEST_PTR rsi, rax
    ja .nb_ior_other
    mov rax, [rdi + PyObject.ob_type]
    REQUIRE_DICT_TYPE rax, rcx, .nb_ior_decline
    mov rax, [rsi + PyObject.ob_type]
    REQUIRE_DICT_TYPE rax, rcx, .nb_ior_other
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    mov [rbp - DIO_LEFT], rdi       ; left dict
    mov [rbp - DIO_RIGHT], rsi      ; right dict

    ; Room for the whole right half first, then walk its DENSE array.
    mov rdi, [rbp - DIO_LEFT]
    mov rsi, [rbp - DIO_RIGHT]
    mov rsi, [rsi + PyDictObject.ob_size]
    call dict_reserve
    mov rdi, [rbp - DIO_RIGHT]
    mov r8, [rdi + PyDictObject.dk_nentries]
    xor ecx, ecx
.dio_loop:
    cmp rcx, r8
    jge .dio_done

    imul rax, rcx, DICT_ENTRY_SIZE
    add rax, [rdi + PyDictObject.entries]
    cmp qword [rax + DictEntry.key], 0   ; occupied?
    je .dio_next

    push rcx
    push r8
    push rdi
    mov rdi, [rbp - DIO_LEFT]
    mov rsi, [rax + DictEntry.key]
    mov rdx, [rax + DictEntry.value]
    call dict_set
    pop rdi
    pop r8
    pop rcx

.dio_next:
    inc rcx
    jmp .dio_loop

.dio_done:
    ; Return left dict with INCREF (caller will DECREF both operands)
    mov rax, [rbp - DIO_LEFT]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; return one Value
    ret
.nb_ior_other:
    ; Anything else goes through dict.update, which already accepts a mapping,
    ; the keys() protocol, or an iterable of key/value pairs -- and raises the
    ; right thing for what is none of those.  The left operand still has to be
    ; a dict.
    mov rax, [rdi + PyObject.ob_type]
    REQUIRE_DICT_TYPE rax, rcx, .nb_ior_decline
    mov [rbp - DIO_LEFT], rdi
    mov [rbp - DIO_ARGS], rdi
    mov [rbp - DIO_ARGS + 8], rsi
    lea rdi, [rbp - DIO_ARGS]
    mov esi, 2
    extern dict_method_update
    call dict_method_update
    test rax, rax
    jz .nb_ior_failed           ; update raised; hand the failure on
    DECREF_V rax, rcx           ; update answers None
    mov rax, [rbp - DIO_LEFT]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.nb_ior_failed:
    xor eax, eax
    xor edx, edx
    leave
    ret

.nb_ior_decline:
    xor eax, eax                ; NULL Value = NotImplemented
    leave
    ret
END_FUNC dict_nb_ior

;; ============================================================================
;; dict_richcompare(rdi = left, rsi = right, edx = op, rcx = left tag,
;;                  r8 = right tag) -> (rax = payload, edx = tag)
;;
;; Only supports Py_EQ (2) and Py_NE (3).
;; Two dicts are equal if they have the same size and all key-value pairs match.
;; ============================================================================

DRC_LEFT  equ 8
DRC_RIGHT equ 16
DRC_OP    equ 24
DRC_LVAL  equ 32            ; the left value, held for the turn
DRC_RVAL  equ 40            ; the right value, held for the turn
DRC_KEY   equ 48            ; the key, held for the turn
DRC_IDX   equ 56
DRC_RES   equ 64            ; the comparison's verdict, across the releases
DRC_FRAME equ 80            ; + 0 pushes = 80

; Comparing two dicts that reach each other -- x = {}; x['foo'] = x, twice --
; recursed until the machine stack ran out; the identity fast path inside only
; catches x == x.  The body is wrapped so its several exits need not each be
; touched, exactly as list_richcompare and tuple_richcompare are.  CPython's
; test_copy.test_deepcopy_reflexive_dict is the test for it.
extern recursion_limit
extern exc_RecursionError_type
DEF_FUNC dict_richcompare
    C_RECURSION_ENTER .drc_too_deep
    call dict_richcompare_inner
    C_RECURSION_LEAVE
    leave
    ret
.drc_too_deep:
    C_RECURSION_LEAVE
    RAISE exc_RecursionError_type, "maximum recursion depth exceeded in comparison"
END_FUNC dict_richcompare

;; dict_richcompare_inner(the same arguments) -> (rax = payload, edx = tag)
;; The comparison itself; the wrapper above only bounds the recursion.
DEF_FUNC_LOCAL dict_richcompare_inner, DRC_FRAME
    V_UNPACK rdi, rcx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, r8            ; right Value -> (payload, tag)
    ; edx = op (PY_EQ=2, PY_NE=3)
    mov [rbp - DRC_LEFT], rdi
    mov [rbp - DRC_RIGHT], rsi
    mov [rbp - DRC_OP], edx

    ; The right operand is dereferenced as a dict below, so it has to be
    ; one: an immediate's payload is not an address, and any other object's
    ; fields are not ob_size/capacity/entries.
    ;
    ; A *subclass* is one too, and the test used to be for the exact type --
    ; so `D(x) == D(x)` for any dict subclass answered NotImplemented on the
    ; right, fell through to identity, and came out False.  CPython's
    ; dict_richcompare asks PyDict_Check, which admits a subclass; the same
    ; question here is the flag, which type_from_parts propagates.
    cmp r8d, TAG_PTR
    jne .drc_not_impl
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel dict_type]
    cmp rax, rcx
    je .drc_right_ok
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_DICT_SUBCLASS
    jz .drc_not_impl
.drc_right_ok:

    ; Only handle EQ (2) and NE (3)
    cmp edx, 2
    je .drc_do_eq
    cmp edx, 3
    je .drc_do_eq

.drc_not_impl:
    ; Unsupported op — return NotImplemented (NULL)
    RET_NULL
    leave
    ret

.drc_do_eq:
    ; Compare sizes
    mov rdi, [rbp - DRC_LEFT]
    mov rsi, [rbp - DRC_RIGHT]
    mov rax, [rdi + PyDictObject.ob_size]
    mov rcx, [rsi + PyDictObject.ob_size]
    cmp rax, rcx
    jne .drc_not_equal

    ; Same size — check all key-value pairs from left exist in right with same
    ; value.  Neither the capacity nor the entries pointer may be cached
    ; across the loop and nothing in an entry may be used borrowed: the
    ; comparison below is the values' own __eq__, and releasing a value runs
    ; its __del__.  Either can empty or resize either dict -- CPython's own
    ; test_dict does exactly that, twice, because CPython segfaulted on it
    ; too.  So each turn re-reads the table and takes a reference to the key
    ; and to both values for as long as it needs them.
    mov qword [rbp - DRC_IDX], 0

.drc_loop:
    mov rdi, [rbp - DRC_LEFT]
    mov rax, [rbp - DRC_IDX]
    cmp rax, [rdi + PyDictObject.capacity]
    jge .drc_equal
    mov rcx, [rdi + PyDictObject.entries]
    test rcx, rcx
    jz .drc_equal                   ; emptied under us: nothing left to walk
    imul rax, rax, DICT_ENTRY_SIZE
    add rax, rcx

    ; Occupied?  An empty slot and a tombstone both have a NULL key.
    mov rsi, [rax + DictEntry.key]
    test rsi, rsi
    jz .drc_next

    ; Hold the key and the left value for the turn.  A key is a Value like any
    ; other -- an int key is an immediate -- so it is INCREF_V, not INCREF.
    mov [rbp - DRC_KEY], rsi
    INCREF_V rsi, rcx
    mov r11, [rax + DictEntry.value]
    mov [rbp - DRC_LVAL], r11
    INCREF_V r11, rax

    ; Look the key up in the right dict.  dict_get hands back a borrowed
    ; Value, or 0 when the key is not there.
    mov rdi, [rbp - DRC_RIGHT]
    mov rsi, [rbp - DRC_KEY]
    call dict_get
    mov [rbp - DRC_RVAL], rax
    test rax, rax
    jz .drc_not_equal_rel           ; key not in right
    INCREF_V rax, rcx

    ; Compare them the way Python does.  This used to be a hand-rolled
    ; payload-and-tag comparison that answered "not equal" whenever the two
    ; Values were not the same KIND -- so `{1: 1} == {1: 1.0}` was False, and
    ; so was `{1: True} == {1: 1}`.  obj_richcompare_bool is what every other
    ; container search uses: identity first, then __eq__, then the reflected
    ; operand, and -1 when the comparison raised.
    extern obj_richcompare_bool
    mov rdi, [rbp - DRC_LVAL]
    mov rsi, [rbp - DRC_RVAL]
    mov edx, 2                      ; PY_EQ
    call obj_richcompare_bool

    ; Release the turn's references before acting on the answer.  The verdict
    ; goes in a frame slot and not a register: DECREF_V reaches obj_dealloc,
    ; which clobbers every caller-saved register there is, and a __del__ under
    ; it runs arbitrary Python.
    mov [rbp - DRC_RES], eax
    mov rdi, [rbp - DRC_KEY]
    DECREF_V rdi, rax
    mov rdi, [rbp - DRC_LVAL]
    DECREF_V rdi, rax
    mov rdi, [rbp - DRC_RVAL]
    DECREF_V rdi, rax

    mov eax, [rbp - DRC_RES]
    test eax, eax
    js .drc_raised                  ; -1: the comparison raised
    jz .drc_not_equal

.drc_next:
    inc qword [rbp - DRC_IDX]
    jmp .drc_loop

.drc_not_equal_rel:
    ; The key was absent from the right dict: drop what this turn is holding.
    mov rdi, [rbp - DRC_KEY]
    DECREF_V rdi, rax
    mov rdi, [rbp - DRC_LVAL]
    DECREF_V rdi, rax
    jmp .drc_not_equal

.drc_raised:
    ; The comparison raised.  Returning NULL would be read as NotImplemented,
    ; and the caller would fall back to identity and answer False with the
    ; exception still pending -- so hand it to the unwinder, which is what
    ; list_richcompare_inner does with the same -1.
    extern eval_exception_unwind
    leave
    jmp eval_exception_unwind

.drc_not_equal:
    ; Return based on op: EQ→False, NE→True
    cmp dword [rbp - DRC_OP], 3     ; NE?
    je .drc_ret_true
    xor eax, eax                    ; False
    RET_BOOL_RAX
    leave
    ret

.drc_equal:
    ; Return based on op: EQ→True, NE→False
    cmp dword [rbp - DRC_OP], 3     ; NE?
    je .drc_ret_false
.drc_ret_true:
    mov eax, 1                      ; True
    RET_BOOL_RAX
    leave
    ret

.drc_ret_false:
    xor eax, eax                    ; False
    RET_BOOL_RAX
    leave
    ret
END_FUNC dict_richcompare_inner

;; ============================================================================
;; dict_reversed(args, nargs) -> PyDictIterObject* (reverse key iterator)
;; Called as dict.__reversed__(self).
;; args[0] = dict (self), nargs = 1
;; ============================================================================
DEF_FUNC dict_reversed
    ; args[0] = self (dict)
    mov rax, [rdi]             ; dict payload
    push rbx

    mov rbx, rax               ; rbx = dict

    mov edi, PyDictIterObject_size
    lea rsi, [rel dict_rev_iter_type]
    call gc_alloc

    mov [rax + PyDictIterObject.it_dict], rbx
    ; Set it_index to capacity - 1 (start from end)
    mov rcx, [rbx + PyDictObject.capacity]
    dec rcx
    mov [rax + PyDictIterObject.it_index], rcx
    mov qword [rax + PyDictIterObject.it_kind], 0  ; 0 = keys
    ; Snapshot the SIZE for mutation detection, as CPython's dictiter does.
    ; dk_version was the wrong field: dict_set bumps it on every write, the
    ; update-in-place branch included, so `for k in d: d[k] = f(d[k])` raised
    ; RuntimeError.  ob_size is sufficient on its own -- a resize only ever
    ; happens on an insert, and an insert always changes ob_size, so a
    ; rebuilt entry array cannot slip past a size comparison.
    mov rcx, [rbx + PyDictObject.ob_size]
    mov [rax + PyDictIterObject.it_version], rcx

    ; INCREF the dict
    push rax
    mov rdi, rbx
    call obj_incref
    pop rax
    push rax
    mov rdi, rax
    call gc_track
    pop rax

    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC dict_reversed

;; ============================================================================
;; dict_rev_iter_next(PyDictIterObject *self) -> (rax=key, edx=key_tag) or NULL
;; Like dict_iter_next but scans backwards (decrements index).
;; ============================================================================
DEF_FUNC_BARE dict_rev_iter_next
    ; Mutation detection
    mov rax, [rdi + PyDictIterObject.it_dict]
    test rax, rax
    jz .dri_done                ; already dropped, or cleared by the collector
    mov rcx, [rax + PyDictObject.ob_size]
    cmp rcx, [rdi + PyDictIterObject.it_version]
    jne .dri_mutation_error

    mov rcx, [rdi + PyDictIterObject.it_index]        ; current index
    mov rsi, [rax + PyDictObject.entries]              ; entries ptr

.dri_scan:
    test rcx, rcx
    js .dri_exhausted           ; index < 0 → done

    ; Check if entry at index has a valid key
    imul rax, rcx, DictEntry_size
    add rax, rsi
    ENTRY_CLASSIFY rax, .dri_skip, .dri_skip

    ; Found a valid entry — save decremented index
    dec rcx
    mov [rdi + PyDictIterObject.it_index], rcx

    ; Which half, or both: the same it_kind the forward iterator reads.  This
    ; walked keys unconditionally, because reversed(d) was its only caller --
    ; and then reversed(d.values()) and reversed(d.items()), once the views
    ; grew a __reversed__, quietly answered with keys.
    mov r10, [rdi + PyDictIterObject.it_kind]
    cmp r10, 1
    je .dri_return_value
    ja .dri_return_item

    ; Return key
    mov rax, [rax + DictEntry.key]
    INCREF_V rax, rdx
    ret

.dri_return_value:
    mov rax, [rax + DictEntry.value]
    INCREF_V rax, rdx
    ret

.dri_return_item:
    ; A (key, value) pair, as the forward iterator builds it.
    push rbx
    push r12
    mov rbx, rax                ; save the entry
    mov edi, 2
    call tuple_new
    mov r12, rax
    mov r9, [r12 + PyTupleObject.ob_item]
    mov rax, [rbx + DictEntry.key]
    INCREF_V rax, rdx
    mov [r9], rax
    mov rax, [rbx + DictEntry.value]
    INCREF_V rax, rdx
    mov [r9 + 8], rax
    mov rax, r12
    mov edx, TAG_PTR
    pop r12
    pop rbx
    ret

.dri_skip:
    dec rcx
    jmp .dri_scan

.dri_exhausted:
    ; Drop the dict at exhaustion, as dict_iter_next does.
    mov [rdi + PyDictIterObject.it_index], rcx
    mov rax, [rdi + PyDictIterObject.it_dict]
    test rax, rax
    jz .dri_done
    mov qword [rdi + PyDictIterObject.it_dict], 0
    push rdi
    mov rdi, rax
    call obj_decref
    pop rdi
.dri_done:
    RET_NULL
    ret

.dri_mutation_error:
    RAISE exc_RuntimeError_type, "dictionary changed size during iteration"
END_FUNC dict_rev_iter_next

;; ============================================================================
;; Data section
;; ============================================================================
section .data

; dict_repr_str removed - repr now in src/repr.asm
dict_iter_name: db "dict_keyiterator", 0
dict_value_iter_name: db "dict_valueiterator", 0
dict_item_iter_name: db "dict_itemiterator", 0
dict_rev_iter_name: db "dict_reversekeyiterator", 0

dict_name_str: db "dict", 0

; Dict mapping methods
align 8
global dict_mapping_methods
dict_mapping_methods:
    dq dict_len                 ; mp_length
    dq dict_subscript           ; mp_subscript
    dq dict_ass_subscript       ; mp_ass_subscript

; Dict number methods (for | operator)
align 8
dict_number_methods:
    dq 0                        ; nb_add          +0
    dq 0                        ; nb_subtract     +8
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
    dq 0                        ; nb_and          +104
    dq 0                        ; nb_xor          +112
    dq dict_nb_or               ; nb_or           +120 (dict merge |)
    dq 0                        ; nb_int          +128
    dq 0                        ; nb_float        +136
    dq 0                        ; nb_floor_divide +144
    dq 0                        ; nb_true_divide  +152
    dq 0                        ; nb_index        +160
    ; Inplace slots
    dq 0                        ; nb_iadd         +168
    dq 0                        ; nb_isub         +176
    dq 0                        ; nb_imul         +184
    dq 0                        ; nb_irem         +192
    dq 0                        ; nb_ipow         +200
    dq 0                        ; nb_ilshift      +208
    dq 0                        ; nb_irshift      +216
    dq 0                        ; nb_iand         +224
    dq 0                        ; nb_ixor         +232
    dq dict_nb_ior              ; nb_ior          +240 (dict inplace merge |=)
    dq 0                        ; nb_ifloor_divide +248
    dq 0                        ; nb_itrue_divide +256
    dq 0 ; nb_matmul
    dq 0 ; nb_imatmul

; Dict sequence methods (for 'in' operator)
align 8
dict_sequence_methods:
    dq dict_len                 ; sq_length
    dq 0                        ; sq_concat
    dq 0                        ; sq_repeat
    dq 0                        ; sq_item
    dq 0                        ; sq_ass_item
    dq dict_contains            ; sq_contains
    dq 0                        ; sq_inplace_concat
    dq 0                        ; sq_inplace_repeat

; Dict type object
align 8
global dict_type
dict_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq dict_name_str            ; tp_name
    dq PyDictObject_size        ; tp_basicsize
    dq dict_dealloc             ; tp_dealloc
    dq dict_repr                ; tp_repr
    dq dict_repr                ; tp_str
    extern hash_not_implemented
    dq hash_not_implemented     ; tp_hash (raises TypeError)
    dq 0                ; tp_call  (instances are not callable)
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq dict_richcompare         ; tp_richcompare
    dq dict_tp_iter             ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq dict_type_call       ; tp_new  (constructor)
    dq dict_number_methods      ; tp_as_number
    dq dict_sequence_methods    ; tp_as_sequence (for 'in' operator)
    dq dict_mapping_methods     ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC | TYPE_FLAG_DICT_SUBCLASS  ; tp_flags
    dq 0                        ; tp_bases
    dq dict_traverse                        ; tp_traverse
    dq dict_clear_gc                        ; tp_clear
    dq 0          ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; Dict key iterator type
align 8
global dict_iter_type
dict_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq dict_iter_name           ; tp_name
    dq PyDictIterObject_size    ; tp_basicsize
    dq dict_iter_dealloc        ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq dict_iter_self           ; tp_iter (return self)
    dq dict_iter_next           ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC                        ; tp_flags
    dq 0                        ; tp_bases
    dq iter_traverse_one                        ; tp_traverse
    dq iter_clear_one                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; The values and items iterators differ from the keys iterator in nothing
; but their name, which is what `type(iter(d.items())).__name__` answers
; and what a default repr prints.  One shared type called them all
; dict_keyiterator.
align 8
global dict_value_iter_type
dict_value_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq dict_value_iter_name           ; tp_name
    dq PyDictIterObject_size    ; tp_basicsize
    dq dict_iter_dealloc        ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq dict_iter_self           ; tp_iter (return self)
    dq dict_iter_next           ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC                        ; tp_flags
    dq 0                        ; tp_bases
    dq iter_traverse_one                        ; tp_traverse
    dq iter_clear_one                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

align 8
global dict_item_iter_type
dict_item_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq dict_item_iter_name           ; tp_name
    dq PyDictIterObject_size    ; tp_basicsize
    dq dict_iter_dealloc        ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq dict_iter_self           ; tp_iter (return self)
    dq dict_iter_next           ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC                        ; tp_flags
    dq 0                        ; tp_bases
    dq iter_traverse_one                        ; tp_traverse
    dq iter_clear_one                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; Dict reverse key iterator type
align 8
global dict_rev_iter_type
dict_rev_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq dict_rev_iter_name       ; tp_name
    dq PyDictIterObject_size    ; tp_basicsize
    dq dict_iter_dealloc        ; tp_dealloc (reuse forward iter dealloc)
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq dict_iter_self           ; tp_iter (return self)
    dq dict_rev_iter_next       ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC                        ; tp_flags
    dq 0                        ; tp_bases
    dq iter_traverse_one                        ; tp_traverse
    dq iter_clear_one                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer


section .rodata

;; ============================================================================
;; The table every empty dict points at.
;;
;; A dict used to allocate its tables in dict_new: two ap_mallocs and two
;; `rep stosq` -- 192 bytes of entries and 64 of indices -- for every dict
;; ever made, including `{}`, every **kwargs frame dict whether or not a
;; keyword arrives, and every instance __dict__.  malloc and free were 37% of
;; `{}` in a loop.  CPython allocates nothing: PyDict_New points at one
;; immortal empty keys object and the table is built on the first insert.
;;
;; The capacity is ONE, and that is what makes it safe rather than a special
;; case.  Reads need no arm at all: dict_lookup masks the hash to the single
;; slot, finds DICT_IX_EMPTY and answers miss.  Writes cannot reach it
;; either, because dict_set's room test is `dk_nentries + 1 > capacity*3/4`
;; and 3/4 of one is zero, so the very first insert resizes to a real table
;; before it stores anything.
;;
;; It lives in .rodata, so "no write path can reach it" is enforced by the
;; page tables rather than by argument.
;; ============================================================================
align 8
dict_empty_indices:
    dq DICT_IX_EMPTY
dict_empty_entries:
    times DICT_ENTRY_SIZE / 8 dq 0

section .text



;; ============================================================================
;; GC traverse and clear.  These lived in gc.asm, which left the collector
;; holding the reference graph of every type in the system; a type's own
;; file is the only place that knows which of its fields are owned.
;; ============================================================================

;; ============================================================================
;; ---- dict_traverse / dict_clear ----
;; ============================================================================

DEF_FUNC dict_traverse, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    push r12
    push r13

    mov rbx, rdi
    mov r12, [rbx + PyDictObject.entries]
    mov r13, [rbx + PyDictObject.capacity]
    test r13, r13
    jz .done
.loop:
    dec r13
    ; Check for empty/tombstone
    ENTRY_CLASSIFY r12, .next, .next

    ; Visit key
    mov rdi, [r12 + DictEntry.key]

    VISIT_V rdi, rsi
    ; Visit value
    mov rdi, [r12 + DictEntry.value]

    VISIT_V rdi, rsi

.next:
    add r12, DICT_ENTRY_SIZE
    test r13, r13
    jnz .loop
.done:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_traverse

DEF_FUNC dict_clear_gc, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    push r12
    push r13

    mov rbx, rdi
    mov r12, [rbx + PyDictObject.entries]
    mov r13, [rbx + PyDictObject.capacity]

    test r13, r13
    jz .done
.loop:
    dec r13
    ENTRY_CLASSIFY r12, .next, .next

    ; DECREF key
    push r12
    push r13
    mov rdi, [r12 + DictEntry.key]
    V_UNPACK rdi, rsi
    DECREF_VAL rdi, rsi
    pop r13
    pop r12

    ; DECREF value
    push r12
    push r13
    mov rdi, [r12 + DictEntry.value]
    V_UNPACK rdi, rsi
    DECREF_VAL rdi, rsi
    pop r13
    pop r12

    ; Clear entry.  It has to become a *tombstone*, not just a zeroed key:
    ; ENTRY_CLASSIFY reads key==0 with any hash other than -1 as "empty",
    ; which ends a probe early, so a surviving key further along the chain
    ; becomes unreachable.
    mov qword [r12 + DictEntry.key], 0
    mov qword [r12 + DictEntry.value], 0
    mov qword [r12 + DictEntry.hash], ENTRY_TOMBSTONE_HASH

.next:
    add r12, DICT_ENTRY_SIZE
    test r13, r13
    jnz .loop
.done:
    ; The table is empty now, so give it back rather than rewriting it.  The
    ; tombstones above still had to be written: a DECREF can run Python that
    ; looks this dict up while the walk is only half done.
    mov rdi, rbx
    call dict_release_tables
    mov qword [rbx + PyDictObject.ob_size], 0
    mov qword [rbx + PyDictObject.dk_nentries], 0
    mov qword [rbx + PyDictObject.dk_tombstones], 0
    inc qword [rbx + PyDictObject.dk_version]

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_clear_gc
