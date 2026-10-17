; methods/dict.asm - dict methods
;
; Methods are registered into each type's tp_dict by methods_init, in
; methods_init.asm.  A method is name(PyObject *self, PyObject **args,
; int64_t nargs); args are borrowed, the result is a new reference.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

; External functions
extern ap_memset
extern obj_decref
extern str_from_cstr_heap
extern tuple_new
extern tuple_type
extern dict_copy_shallow
extern dict_new
extern dict_get
extern obj_getattr_opt
extern obj_call_n
extern dict_set
extern dict_del
extern none_singleton
extern raise_exception
extern raise_key_error
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_KeyError_type
extern tuple_type_call
extern dict_type
extern obj_dealloc

; Set entry layout constants (must match set.asm)

; --- moved to a sibling file by the split ---

extern dict_subscript

section .text

;; ############################################################################
;;                         DICT METHODS
;; ############################################################################

;; ============================================================================
;; dict_method_get(args, nargs) -> value or None
;; args[0]=self, args[1]=key, optionally args[2]=default
;; ============================================================================
DEF_FUNC dict_method_get
    push rbx
    push r12

    mov rax, rdi            ; args
    mov rbx, [rax]          ; self (dict)
    mov r12, rsi            ; nargs
    push rax

    ; dict_get(self, key)
    mov rdi, rbx
    mov rsi, [rax + 8]      ; key Value -- dict_get unpacks it itself, so
    call dict_get           ; decoding here would hand it a bare payload
    test rax, rax               ; a Value, and 0 is the only miss
    jnz .dg_found

    ; Not found - return default or None
    pop rcx                 ; args
    cmp r12, 3
    jl .dg_ret_none
    mov rax, [rcx + 16]     ; args[2], the default
    INCREF_V rax, rdx
    pop r12
    pop rbx
    leave
    ret

.dg_ret_none:
    RET_NONE
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.dg_found:
    add rsp, 8              ; discard saved args
    INCREF_V rax, rdx       ; dict_get's answer is borrowed
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_method_get

;; ============================================================================
;; dict_method_keys(args, nargs) -> dict_keys view
;; args[0]=self
;; ============================================================================
extern dict_view_new
DEF_FUNC dict_method_keys
    mov rdi, [rdi]          ; self (dict)
    xor esi, esi            ; kind=0 (keys)
    extern dict_keys_view_type
    lea rdx, [rel dict_keys_view_type]
    call dict_view_new
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC dict_method_keys

;; ============================================================================
;; dict_method_values(args, nargs) -> dict_values view
;; args[0]=self
;; ============================================================================
DEF_FUNC dict_method_values
    mov rdi, [rdi]          ; self (dict)
    mov esi, 1              ; kind=1 (values)
    extern dict_values_view_type
    lea rdx, [rel dict_values_view_type]
    call dict_view_new
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC dict_method_values

;; ============================================================================
;; dict_method_items(args, nargs) -> dict_items view
;; args[0]=self
;; ============================================================================
DEF_FUNC dict_method_items
    mov rdi, [rdi]          ; self (dict)
    mov esi, 2              ; kind=2 (items)
    extern dict_items_view_type
    lea rdx, [rel dict_items_view_type]
    call dict_view_new
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC dict_method_items

;; ============================================================================
;; dict_method_pop(args, nargs) -> value
;; args[0]=self, args[1]=key, optionally args[2]=default
;; ============================================================================
DEF_FUNC dict_method_pop, 8            ; 5 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r14, rdi            ; r14 = args
    mov rbx, [r14]          ; self
    mov r12, rsi            ; nargs
    mov r13, [r14 + 8]      ; args[1], the key Value

    mov rdi, rbx
    mov rsi, r13
    call dict_get
    test rax, rax           ; a Value, and 0 is the only miss
    jz .dpop2_not_found

    INCREF_V rax, rdx       ; dict_get's answer is borrowed
    mov r15, rax            ; held across dict_del, which can run a __del__

    mov rdi, rbx
    mov rsi, r13
    call dict_del

    mov rax, r15
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.dpop2_not_found:
    cmp r12, 3
    jl .dpop2_error
    mov rax, [r14 + 16]     ; args[2], the default
    INCREF_V rax, rdx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.dpop2_error:
    mov rdi, [r14 + 8]         ; the key Value, still in the argument array
    call raise_key_error
END_FUNC dict_method_pop

;; ============================================================================
;; dict_method_clear(args, nargs) -> None
;; args[0]=self
;; ============================================================================
DEF_FUNC dict_method_clear
    ; dict_clear_all detaches the tables before it releases anything, which is
    ; what makes clear() safe against a value's __del__ calling clear() again.
    extern dict_clear_all
    mov rdi, [rdi]              ; self (dict)
    call dict_clear_all

    RET_NONE
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC dict_method_clear

; CPython's PySequence_Fast hands a list or a tuple straight back rather than
; copying it, and dict.update's two materialisation points are exactly where
; it uses it.  A list and a tuple carry ob_size and ob_item at the same two
; offsets, which is the only reason one accessor serves both; NASM checks it
; here rather than leaving it to a reader.
%if PyTupleObject.ob_size != PyListObject.ob_size
    %error "list and tuple must agree on ob_size for du_as_sequence"
%endif
%if PyTupleObject.ob_item != PyListObject.ob_item
    %error "list and tuple must agree on ob_item for du_as_sequence"
%endif

;; ============================================================================
;; du_as_sequence(rdi = a Value) -> rax = an owned exact list or tuple, or 0
;;   with an exception pending
;;
;; A list or a tuple is already what the caller wants to index, so it comes
;; back with one more reference and nothing is built.  `dict(pairs)` was
;; copying the whole sequence AND allocating a fresh two-element tuple for
;; every pair in it, which is one allocation per element to read two words
;; that were already contiguous.
;; ============================================================================
DAS_ARG   equ 8                         ; also the one-Value argument array
DAS_FRAME equ 16                        ; + 0 pushes = 16, 16-aligned
DEF_FUNC du_as_sequence, DAS_FRAME
    mov [rbp - DAS_ARG], rdi
    V_TEST_PTR rdi, rax
    ja .das_build
    test rdi, rdi
    jz .das_build
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .das_keep
    extern list_type
    lea rcx, [rel list_type]
    cmp rax, rcx
    jne .das_build
.das_keep:
    INCREF_V rdi, rax
    mov rax, rdi
    leave
    ret
.das_build:
    lea rsi, [rbp - DAS_ARG]
    lea rdi, [rel tuple_type]
    mov edx, 1
    call tuple_type_call
    leave
    ret
END_FUNC du_as_sequence

;; ============================================================================
;; dict_method_update(args, nargs) -> None
;; args[0]=self; then either a mapping, or an iterable of key/value pairs,
;; and/or keyword arguments.  All three forms are ordinary Python; the old
;; code read args[1] as a PyDictObject unconditionally, so d.update(5)
;; dereferenced the payload, d.update([("a",1)]) read a list's fields as a
;; dict's, and d.update(a=1) treated the keyword's value as the mapping.
;; ============================================================================
DU_ARGS   equ 8
DU_SELF   equ 16
DU_NKW    equ 24
DU_NPOS   equ 32
DU_TMP    equ 40        ; materialised sequence, owned, or 0
DU_PAIRV  equ 48        ; scratch Value, so &it can be passed as an args array
DU_PAIR   equ 56        ; materialised pair, owned, or 0
DU_KWNAMES equ 64       ; the consumed kw_names_pending tuple, borrowed
DU_OTHER  equ 72        ; the positional argument, borrowed
DU_KEYV   equ 80        ; key and value, held across dict_set: both are
DU_VALV   equ 88        ;   borrowed from a table user code can empty
DU_ORIGN  equ 96        ; the source's dk_nentries when the walk started
DU_FRAME  equ 112           ; + 4 pushes = 144

DEF_FUNC dict_method_update, DU_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov rbx, [rdi]                  ; self
    mov [rbp - DU_ARGS], rdi
    mov [rbp - DU_SELF], rbx
    mov qword [rbp - DU_TMP], 0
    mov qword [rbp - DU_PAIR], 0

    ; Keyword arguments occupy the last n_kw slots and are named by
    ; kw_names_pending.  Consume it here so nothing downstream sees it.
    xor eax, eax
    mov [rbp - DU_KWNAMES], rax
    mov rcx, [gs:ThreadState.kw_names_pending]
    test rcx, rcx
    jz .du_have_nkw
    mov [rbp - DU_KWNAMES], rcx
    mov rax, [rcx + PyTupleObject.ob_size]
    mov qword [gs:ThreadState.kw_names_pending], 0
.du_have_nkw:
    mov [rbp - DU_NKW], rax
    sub rsi, rax
    mov [rbp - DU_NPOS], rsi        ; positional count, self included

    cmp rsi, 2
    jg .du_too_many
    jl .du_kwargs                   ; self only: nothing positional to merge

    ; ---- positional argument: a mapping, or an iterable of pairs ----------
    mov rdi, [rbp - DU_ARGS]
    mov r12, [rdi + 8]
    V_TEST_PTR r12, rax
    ja .du_from_pairs               ; an immediate is not a mapping; let the
                                    ; iterator protocol produce the TypeError
    mov rax, [r12 + PyObject.ob_type]
    REQUIRE_DICT_TYPE rax, rcx, .du_from_pairs

    ; ---- other is a dict: walk its DENSE array ----------------------------
    ; Room for the whole of it first, so a hundred-key update does not
    ; rebuild the table five times on the way; then dk_nentries, which is the
    ; exact high-water mark, rather than capacity, which at the 3/4 load
    ; factor is a third more slots and after deletions is unbounded.
    extern dict_reserve
    mov rdi, rbx
    mov rsi, [r12 + PyDictObject.ob_size]
    call dict_reserve
    mov rax, [r12 + PyDictObject.dk_nentries]
    mov [rbp - DU_ORIGN], rax
    xor r14d, r14d
.du_loop:
    ; The bound is re-read every turn rather than cached.  dict_set runs user
    ; code -- __hash__ and __eq__ on the DESTINATION's keys -- and that code
    ; can clear the SOURCE, which points its entries at the one-slot
    ; read-only dict_empty_entries.  A cached dk_nentries kept walking to the
    ; old bound, off the end of a 24-byte .rodata table, and inserted what it
    ; found there as a key and a value.
    cmp r14, [r12 + PyDictObject.dk_nentries]
    jge .du_kwargs

    mov rax, [r12 + PyDictObject.entries]
    imul rcx, r14, DICT_ENTRY_SIZE
    add rax, rcx

    mov rdi, [rax + DictEntry.key]
    test rdi, rdi
    jz .du_next

    mov rdx, [rax + DictEntry.value]
    ; Both Values are BORROWED from that table, so both are held for the
    ; duration: the same user code can drop the source's last reference to
    ; either, and dict_set would then store what it had already read.
    ; CPython's dict_merge takes the same pair of references.
    mov [rbp - DU_KEYV], rdi
    mov [rbp - DU_VALV], rdx
    INCREF_V rdi, rcx
    INCREF_V rdx, rcx
    mov rsi, rdi                    ; key Value
    mov rdi, rbx                    ; self
    call dict_set
    mov rdi, [rbp - DU_KEYV]
    DECREF_V rdi, rcx
    mov rdi, [rbp - DU_VALV]
    DECREF_V rdi, rcx

    ; And say so, rather than carrying on over whatever is left.  CPython's
    ; dict_merge compares the source's dk_nentries against what it was after
    ; every insert, for the same reason and with this wording.
    mov rax, [r12 + PyDictObject.dk_nentries]
    cmp rax, [rbp - DU_ORIGN]
    jne .du_mutated

.du_next:
    inc r14
    jmp .du_loop

    ; ---- other is an iterable of (key, value) pairs -----------------------
.du_from_pairs:
    ; A mapping is anything with a keys() method -- that one test is how
    ; CPython tells the two shapes apart -- and it is read through keys() and
    ; indexing rather than as a sequence of pairs.  Without this, updating from
    ; a type's __dict__, which is a mappingproxy, reported that its elements
    ; were not two long.  enum builds its classes that way.
    mov [rbp - DU_OTHER], r12
    V_TEST_PTR r12, rax
    ja .du_as_pairs
    test r12, r12
    jz .du_as_pairs
    lea rdi, [rel du_keys_name]
    call str_from_cstr_heap
    test rax, rax
    jz .du_as_pairs
    mov r13, rax
    mov rdi, [rbp - DU_OTHER]
    mov rsi, r13
    call obj_getattr_opt
    mov [rbp - DU_PAIR], rax            ; the bound keys(), owned, or 0
    mov rdi, r13
    call obj_decref
    cmp qword [rbp - DU_PAIR], 0
    je .du_as_pairs

    xor esi, esi
    mov rdi, [rbp - DU_PAIR]
    xor edx, edx
    call obj_call_n
    mov r14, rax
    mov rdi, [rbp - DU_PAIR]
    mov qword [rbp - DU_PAIR], 0
    call obj_decref
    test r14, r14
    jz .du_propagate                    ; keys() raised; it is already pending

    ; Materialise the key sequence, so any iterable of keys is accepted.
    mov [rbp - DU_PAIRV], r14
    lea rsi, [rbp - DU_PAIRV]
    lea rdi, [rel tuple_type]
    mov edx, 1
    call tuple_type_call
    mov [rbp - DU_TMP], rax
    mov rdi, r14
    call obj_decref
    mov r12, [rbp - DU_TMP]
    test r12, r12
    jz .du_propagate                    ; keys() was not iterable
    mov r13, [r12 + PyTupleObject.ob_size]
    xor r14d, r14d
.du_key_loop:
    cmp r14, r13
    jge .du_keys_done
    mov rax, [r12 + PyTupleObject.ob_item]
    mov rsi, [rax + r14 * 8]            ; the key Value
    mov rdi, [rbp - DU_OTHER]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .du_not_mapping
    mov rax, [rax + PyMappingMethods.mp_subscript]
    test rax, rax
    jz .du_not_mapping
    call rax                            ; other[key] -> Value
    test rax, rax
    jz .du_propagate                    ; the lookup raised
    mov [rbp - DU_PAIRV], rax
    mov rdx, rax
    mov rax, [r12 + PyTupleObject.ob_item]
    mov rsi, [rax + r14 * 8]            ; the key again
    mov rdi, [rbp - DU_SELF]
    call dict_set
    mov rdi, [rbp - DU_PAIRV]
    DECREF_V rdi, rsi
    inc r14
    jmp .du_key_loop
.du_not_mapping:
    ; raise_exception does not return -- it jumps into the unwinder -- so
    ; anything this frame owns has to go first.
    call .du_release
    RAISE exc_TypeError_type, "object is not subscriptable"

.du_mutated:
    extern exc_RuntimeError_type
    extern set_exception
    SET_EXC exc_RuntimeError_type, "dict mutated during update"
    ; fall through: the exception is pending, which is what .du_propagate is for

.du_propagate:
    ; Something we called raised, and the exception is already pending.
    ; Falling through to the success tail returned None and left it to surface
    ; at whatever ran next, with the dict half updated.
    call .du_release
    RET_NULL
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

; Local: drop the owned temporaries, whichever of them are live.
.du_release:
    mov rdi, [rbp - DU_TMP]
    test rdi, rdi
    jz .du_rel_pair
    mov qword [rbp - DU_TMP], 0
    call obj_decref
.du_rel_pair:
    mov rdi, [rbp - DU_PAIR]
    test rdi, rdi
    jz .du_rel_done
    mov qword [rbp - DU_PAIR], 0
    call obj_decref
.du_rel_done:
    ret

.du_keys_done:
    mov rdi, [rbp - DU_TMP]
    mov qword [rbp - DU_TMP], 0
    call obj_decref
    mov rbx, [rbp - DU_SELF]
    jmp .du_kwargs

.du_as_pairs:
    mov rdi, [rbp - DU_OTHER]
    call du_as_sequence             ; raises for a non-iterable
    mov [rbp - DU_TMP], rax
    mov r12, rax
    ; ...but an iterable whose __next__ raises returns NULL rather than
    ; raising from here, and reading ob_size off that dereferences 0.
    test rax, rax
    jz .du_propagate
    mov r13, [r12 + PyTupleObject.ob_size]
    mov rdi, rbx
    mov rsi, r13
    call dict_reserve               ; the pair count is known; take it once
    xor r14d, r14d
.du_pair_loop:
    ; The bound is re-read, not the r13 the reserve was sized from.  A tuple
    ; source cannot change, but 8010506 made an exact LIST source be read
    ; where it lies rather than snapshotted -- and dict_set below runs
    ; __hash__ and __eq__, which can shorten that list.  Indexing ob_item to
    ; a stale length reads freed slots.
    cmp r14, [r12 + PyTupleObject.ob_size]
    jge .du_pairs_done
    mov rax, [r12 + PyTupleObject.ob_item]
    mov rax, [rax + r14 * 8]
    mov [rbp - DU_PAIRV], rax
    ; An element that is not iterable at all has CPython's own message,
    ; naming which element it was.  Left to tuple() below it came back as
    ; "'int' object is not iterable", which says nothing about the dict.
    mov rdi, rax
    V_TEST_PTR rdi, rcx
    ja .du_not_a_sequence
    test rdi, rdi
    jz .du_not_a_sequence
    ; A pair that is already a list or a tuple is read where it lies.  A pair
    ; of any other shape still has to be materialised, and still has to be
    ; refused BY NAME when it is not iterable at all -- CPython's message
    ; says which element it was, and tuple() below would say only
    ; "'int' object is not iterable".
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .du_pair_direct
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .du_pair_direct
    mov esi, TAG_PTR
    extern get_iterator_opt
    call get_iterator_opt
    test rax, rax
    jz .du_not_a_sequence
    mov rdi, rax
    call obj_decref
    ; Materialise the pair, so any two-element iterable is accepted.
    lea rsi, [rbp - DU_PAIRV]
    lea rdi, [rel tuple_type]
    mov edx, 1
    call tuple_type_call
    jmp .du_pair_have
.du_pair_direct:
    INCREF_V rdi, rax
    mov rax, rdi
.du_pair_have:
    mov [rbp - DU_PAIR], rax
    test rax, rax
    jz .du_propagate
    cmp qword [rax + PyTupleObject.ob_size], 2
    jne .du_bad_pair
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rsi, [rcx]                  ; key Value
    mov rdx, [rcx + 8]              ; value Value
    ; DU_PAIR holds the pair itself, but a pair that is a LIST keeps its
    ; elements somewhere the same user code can empty -- and these two are
    ; borrowed out of it.  Held for the call, as in the dict branch above.
    mov [rbp - DU_KEYV], rsi
    mov [rbp - DU_VALV], rdx
    INCREF_V rsi, rcx
    INCREF_V rdx, rcx
    mov rdi, [rbp - DU_SELF]
    call dict_set
    mov rdi, [rbp - DU_KEYV]
    DECREF_V rdi, rcx
    mov rdi, [rbp - DU_VALV]
    DECREF_V rdi, rcx
    mov rdi, [rbp - DU_PAIR]
    mov qword [rbp - DU_PAIR], 0
    call obj_decref
    inc r14
    jmp .du_pair_loop
.du_pairs_done:
    mov rdi, [rbp - DU_TMP]
    mov qword [rbp - DU_TMP], 0
    call obj_decref
    mov rbx, [rbp - DU_SELF]

    ; ---- keyword arguments -------------------------------------------------
.du_kwargs:
    mov r13, [rbp - DU_NKW]
    test r13, r13
    jz .du_done
    mov r12, [rbp - DU_KWNAMES]
    xor r14d, r14d
.du_kw_loop:
    cmp r14, r13
    jge .du_done
    mov rax, [r12 + PyTupleObject.ob_item]
    mov rsi, [rax + r14 * 8]        ; keyword name str, already a Value
    mov rax, [rbp - DU_NPOS]
    add rax, r14                    ; value slot = n_pos + kw index
    mov rcx, [rbp - DU_ARGS]
    mov rdx, [rcx + rax * 8]        ; value Value
    mov rdi, [rbp - DU_SELF]
    call dict_set
    inc r14
    jmp .du_kw_loop

.du_done:
    RET_NONE
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.du_not_a_sequence:
    call .du_release
    mov rsi, r14
    CSTRING rdx, " to a sequence"
    CSTRING rdi, "cannot convert dictionary update sequence element #"
    extern raise_type_error_counted
    jmp raise_type_error_counted

.du_bad_pair:
    ; "element #0 has length 3; 2 is required": two numbers, so the first
    ; goes into a buffer here and raise_value_error_counted appends the
    ; second.
    mov r13, [rax + PyTupleObject.ob_size]
    call .du_release
    sub rsp, 128
    mov rdi, rsp
    CSTRING rsi, "dictionary update sequence element #"
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, r14
    extern msg_append_i64
    call msg_append_i64
    mov rdi, rax
    CSTRING rsi, " has length "
    call rbt_append_cstr
    mov rdi, rsp
    mov rsi, r13
    CSTRING rdx, "; 2 is required"
    extern raise_value_error_counted
    jmp raise_value_error_counted

.du_too_many:
    RAISE exc_TypeError_type, "update expected at most 1 argument"
END_FUNC dict_method_update

;; ============================================================================
;; dict_method_setdefault(args, nargs) -> value
;; args[0]=self, args[1]=key, args[2]=default (optional, default=None)
;; ============================================================================
DEF_FUNC dict_method_setdefault, 8            ; 5 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, [rdi]          ; self (dict)
    mov r12, [rdi + 8]      ; args[1], the key Value
    mov r13, rsi            ; nargs

    ; Save args ptr for default value access
    push rdi

    mov rdi, rbx
    mov rsi, r12
    call dict_get
    test rax, rax           ; a Value, and 0 is the only miss
    jnz .sd_found

    ; Not found - determine default value
    pop rdi                 ; restore args ptr
    cmp r13, 3
    jl .sd_use_none
    mov r13, [rdi + 16]     ; args[2], the default
    jmp .sd_set_default

.sd_use_none:
    lea r13, [rel none_singleton]

.sd_set_default:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call dict_set

    mov rax, r13
    INCREF_V rax, rdx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sd_found:
    add rsp, 8              ; discard saved args ptr
    INCREF_V rax, rdx       ; dict_get's answer is borrowed
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_method_setdefault

;; ============================================================================
;; dict_method_copy(args, nargs) -> new dict (shallow copy)
;; args[0]=self
;; ============================================================================
DEF_FUNC dict_method_copy
    mov rdi, [rdi]          ; self (dict)
    call dict_copy_shallow
    mov edx, TAG_PTR        ; dict is heap ptr
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC dict_method_copy

;; ============================================================================
;; dict_classmethod_fromkeys(args, nargs) -> new dict
;; args[0]=cls (type), args[1]=iterable, optional args[2]=value (default None)
;; Creates dict from iterable keys with given value.
;; ============================================================================
DFK_ITER  equ 8
DFK_DICT  equ 16
DFK_VAL   equ 24
DFK_VTAG  equ 32
DFK_EXC   equ 40            ; current_exception before the iteration started
DFK_CLS   equ 48            ; args[0]: the class the result must be
DFK_FRAME equ 56            ; + 3 pushes = 80, 16-aligned

DEF_FUNC dict_classmethod_fromkeys, DFK_FRAME
    push rbx
    push r12
    push r13
    mov rax, [rdi]                 ; args[0] = cls
    mov [rbp - DFK_CLS], rax

    ; Default value = None
    extern none_singleton
    lea rax, [rel none_singleton]
    mov [rbp - DFK_VAL], rax
    mov qword [rbp - DFK_VTAG], TAG_PTR

    ; If nargs >= 3, use args[2] as value
    cmp rsi, 3
    jl .dfk_get_iter
    mov rax, [rdi + 16]            ; value payload
    V_UNPACK rax, rcx       ; args[2]
    mov [rbp - DFK_VAL], rax
    mov [rbp - DFK_VTAG], rcx

.dfk_get_iter:
    ; Get iterator from args[1] (iterable)
    ; One Value per argument slot, so args[1] is at +8 and args[2] at +16.
    mov rax, rdi                   ; save args ptr
    mov rdi, [rax + 8]            ; args[1], the iterable
    V_UNPACK rdi, rsi             ; get_iterator takes a (payload, tag) pair
    extern get_iterator
    call get_iterator
    test rax, rax
    jz .dfk_no_iter
    mov [rbp - DFK_ITER], rax

    ; The result must be of the class this was called ON: D.fromkeys() answers
    ; a D, not a dict, and every dict subclass in the stdlib -- defaultdict,
    ; OrderedDict, Counter -- is reached that way.  An exact dict takes the
    ; direct constructor; anything else is built by calling the class with no
    ; arguments, which is what CPython does, and is why a subclass whose
    ; __init__ demands one cannot be fromkeys'd there either.
    mov rax, [rbp - DFK_CLS]
    lea rcx, [rel dict_type]
    cmp rax, rcx
    je .dfk_exact
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    extern obj_call_n
    call obj_call_n
    test rax, rax
    jz .dfk_ctor_failed
    ; The keys go in with dict_set, which wants the dict layout.  A class that
    ; is not a dict subclass has no such layout, and would be written through
    ; as though it had.  (CPython reaches PyObject_SetItem here, so it also
    ; honours an overridden __setitem__, which this does not.)
    mov rcx, [rax + PyObject.ob_type]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_DICT_SUBCLASS
    jz .dfk_not_a_dict
    jmp .dfk_have_dict
.dfk_exact:
    call dict_new
.dfk_have_dict:
    mov [rbp - DFK_DICT], rax
    test rax, rax
    jz .dfk_ctor_failed

    DUNDER_EXC_SAVE [rbp - DFK_EXC]
.dfk_loop:
    ; Get next key from iterator
    mov rdi, [rbp - DFK_ITER]
    extern call_iternext
    call call_iternext
    V_UNPACK rax, rdx           ; call_iternext returns a Value
    test edx, edx
    jz .dfk_done                   ; iterator exhausted

    ; rax=key payload, rdx=key tag
    ; Save key before loading value (which overwrites rdx)
    mov rsi, rax                   ; key payload
    mov r8, rdx                    ; key tag
    V_PACK rsi, r8

    ; dict_set(dict, key Value, value Value)
    mov rdi, [rbp - DFK_DICT]
    mov rdx, [rbp - DFK_VAL]       ; value payload
    mov rcx, [rbp - DFK_VTAG]      ; value tag
    V_PACK rdx, rcx
    call dict_set

    jmp .dfk_loop

.dfk_done:
    ; DECREF iterator
    mov rdi, [rbp - DFK_ITER]
    call obj_decref

    ; call_iternext answers NULL for a clean exhaustion and for a __next__
    ; that raised anything but StopIteration, which it leaves pending.
    ; Without the distinction dict.fromkeys(G()) for a raising __getitem__
    ; answered a short dict and stranded the exception.
    EXC_RAISED_SINCE [rbp - DFK_EXC], rcx, .dfk_raised

    mov rax, [rbp - DFK_DICT]
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.dfk_raised:
    mov rdi, [rbp - DFK_DICT]
    call obj_decref
.dfk_no_iter:
    xor eax, eax                ; a NULL Value, with the exception pending
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    leave
    ret

.dfk_not_a_dict:
    mov rdi, rax
    call obj_decref
    mov rdi, [rbp - DFK_ITER]
    call obj_decref
    RAISE exc_TypeError_type, \
        "fromkeys() requires a dict subclass"

.dfk_ctor_failed:
    ; The class refused to build, and said why.
    mov rdi, [rbp - DFK_ITER]
    call obj_decref
    xor eax, eax
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_classmethod_fromkeys

;; ============================================================================
;; dict_method_popitem(args, nargs) -> (key, value) tuple
;; args[0]=self. Removes and returns last inserted item.
;; ============================================================================
DEF_FUNC dict_method_popitem
    push rbx
    push r12
    push r13
    push r14

    mov rbx, [rdi]          ; self (dict)

    ; Check if dict is empty
    cmp qword [rbx + PyDictObject.ob_size], 0
    je .dpopitem_empty

    ; The LAST entry, found from the high-water mark.  The scan used to start
    ; at capacity-1, so on a hundred-entry dict in a 256-slot table it walked
    ; a hundred and fifty-six empty slots before reaching anything.
    ; dk_nentries is where the dense array stops.
    mov r12, [rbx + PyDictObject.dk_nentries]
.dpopitem_scan:
    dec r12
    js .dpopitem_empty          ; unreachable while ob_size is non-zero
    mov rax, [rbx + PyDictObject.entries]
    imul rcx, r12, DICT_ENTRY_SIZE
    add rax, rcx
    mov r13, [rax + DictEntry.key]      ; a Value; 0 is a hole
    test r13, r13
    jz .dpopitem_scan
    mov r14, [rax + DictEntry.value]

    ; The (key, value) pair.  Values throughout: this used to take the key
    ; apart with V_TAG_OF and V_UNPACK and put it back together with V_PACK
    ; three times over, to move two words.
    mov edi, 2
    call tuple_new
    mov r12, rax
    mov r9, [r12 + PyTupleObject.ob_item]
    INCREF_V r13, rcx
    INCREF_V r14, rcx
    mov [r9], r13
    mov [r9 + 8], r14

    ; Delete key from dict
    mov rdi, rbx
    mov rsi, r13
    call dict_del

    mov rax, r12
    mov edx, TAG_PTR         ; tuple is heap ptr
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.dpopitem_empty:
    RAISE exc_KeyError_type, "popitem(): dictionary is empty"
END_FUNC dict_method_popitem

section .rodata
du_keys_name:   db "keys", 0

section .text

;; ============================================================================
;; dict's subscript dunders, which lived in methods/object.asm
;; ============================================================================

DEF_FUNC_BARE dict_dunder_getitem
    REQUIRE_SELF_BARE dict_type, "__getitem__"
    ; The same guards its two siblings carry.  builtin_func_call validates
    ; neither the count nor the type for these -- add_method_to_dict registers
    ; them with no min or max -- so dict.__getitem__(5, "a") handed the
    ; immediate 5 to dict_get as a pointer and dereferenced it, and
    ; d.__getitem__() read args[1] off the end of the argument array.
    cmp rsi, 2
    jne .ddg_error
    mov rax, [rdi]              ; self
    V_TEST_PTR rax, rcx
    ja .ddg_error
    test rax, rax
    jz .ddg_error
    mov rcx, [rax + PyObject.ob_type]
    REQUIRE_DICT_TYPE rcx, rdx, .ddg_error
    mov rsi, [rdi + 8]          ; the key Value
    mov rdi, rax
    jmp dict_subscript
.ddg_error:
    RAISE exc_TypeError_type, "descriptor '__getitem__' requires a 'dict' object"
END_FUNC dict_dunder_getitem

DEF_FUNC dict_dunder_setitem
    REQUIRE_SELF dict_type, "__setitem__"
    cmp rsi, 3
    jne .dds_error
    mov rax, [rdi]
    V_TEST_PTR rax, rcx
    ja .dds_error
    test rax, rax
    jz .dds_error
    mov rcx, [rax + PyObject.ob_type]
    REQUIRE_DICT_TYPE rcx, rdx, .dds_error
    mov rsi, [rdi + 8]
    mov rdx, [rdi + 16]
    mov rdi, rax
    call dict_set
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.dds_error:
    RAISE exc_TypeError_type, "object does not support item assignment"
END_FUNC dict_dunder_setitem

DEF_FUNC dict_dunder_delitem
    REQUIRE_SELF dict_type, "__delitem__"
    cmp rsi, 2
    jne .ddd_error
    mov rax, [rdi]
    V_TEST_PTR rax, rcx
    ja .ddd_error
    test rax, rax
    jz .ddd_error
    mov rcx, [rax + PyObject.ob_type]
    REQUIRE_DICT_TYPE rcx, rdx, .ddd_error
    mov rsi, [rdi + 8]
    mov rdi, rax
    call dict_del
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.ddd_error:
    RAISE exc_TypeError_type, "object does not support item deletion"
END_FUNC dict_dunder_delitem
