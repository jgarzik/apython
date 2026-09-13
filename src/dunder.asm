; dunder.asm - Dunder method dispatch helpers for user-defined classes
;
; Provides lookup and call helpers for __eq__, __add__, __iter__, etc.
; Used as fallback when tp_richcompare / tp_as_number / tp_iter etc. are NULL
; on heaptype (user-defined class) objects.

%include "macros.inc"
%include "object.inc"

extern kw_names_pending

; A dunder is invoked on behalf of an operation, not as the call the user
; wrote, so it must not inherit that call's keyword names.  Without this,
; sorted(MyIterable(), reverse=True) reached __iter__ with reverse=True still
; pending and raised "unexpected keyword argument".  The leak only became
; reachable once heaptypes had real slots to dispatch through.
%macro DUNDER_KW_SAVE 1
    mov %1, [rel kw_names_pending]
    mov qword [rel kw_names_pending], 0
%endmacro

%macro DUNDER_KW_RESTORE 1
    mov [rel kw_names_pending], %1
%endmacro

extern none_singleton
extern str_intern_cstr
extern dict_get
extern obj_decref
extern obj_incref
extern exc_TypeError_type
extern raise_exception

;; ============================================================================
;; dunder_name_obj(rdi = const char *literal) -> rax = PyStrObject*, borrowed
;;
;; dunder_lookup used to build a fresh PyStrObject from its C string on every
;; call and free it again: ap_strlen, ap_malloc, ap_memcpy, a code-point scan to
;; set ob_length, a full string hash (the object being new, ob_hash was always
;; cold), and ap_free.  That sat behind 27 direct call sites and 131 DUNDER_*
;; macro uses -- every __add__, __iter__, __next__, __len__, __getitem__ and
;; __enter__ fallback in the interpreter.
;;
;; The names are compile-time literals in .rodata, so the pointer is stable per
;; call site and comparing pointers is enough to recognise one.  A miss interns
;; the string once and keeps it forever; the interned object then caches its own
;; ob_hash, so the dict probes stop rehashing too.  Two call sites that spell
;; the same name in different literals simply get two entries, and -- because
;; the miss goes through the intern table -- both entries hold the SAME object,
;; which is what lets dict_lookup answer by pointer.  It said "interns" here
;; long before it did: the miss arm called str_from_cstr_heap, so the name a
;; __init__ lookup probed with was a different object from the one
;; src/methods/init.asm had put in object's tp_dict, and every such probe ran
;; a length compare and an ap_memcmp.
;;
;; The table never evicts.  Distinct dunder literals number a few dozen against
;; 256 slots, so the probe terminates.
;;
;; The hash has to be multiplicative and not a shift.  The sixty dunder_* names
;; are one contiguous 565-byte run of .rodata, so (addr >> 4) put all of them
;; into thirty-six CONSECUTIVE slots: seventy-odd keys, one primary cluster, and
;; linear probing walking most of it.  Simulated over the sixty-one names nm can
;; put a symbol on, that averaged 13.6 probes per lookup with a worst case of
;; 55, and callgrind measured the function at 33.6% of a `class C: pass; C()`
;; loop -- 227 instructions for a body whose hit path is ten.  Multiplying by
;; the 64-bit golden-ratio constant and taking the TOP byte mixes the low
;; address bits into the slot number, which is what a shift cannot do; the same
;; simulation gives 1.1 probes and a worst case of 3.
;; ============================================================================
DUNDER_CACHE_SLOTS equ 256
DUNDER_HASH_MUL    equ 0x9E3779B97F4A7C15   ; 2^64 / phi, odd, all bits set-ish

DEF_FUNC dunder_name_obj
    push rbx
    push r12                    ; 2 pushes + frame 0 = 16
    mov rbx, rdi
    mov rax, DUNDER_HASH_MUL
    imul rax, rdi
    shr rax, 56                 ; the top byte: 256 slots, so eight bits
    mov r12, rax

.probe:
    lea rcx, [rel dunder_cache_keys]
    mov rdx, [rcx + r12*8]
    test rdx, rdx
    jz .miss
    cmp rdx, rbx
    je .hit
    inc r12
    and r12, DUNDER_CACHE_SLOTS - 1
    jmp .probe

.hit:
    lea rcx, [rel dunder_cache_vals]
    mov rax, [rcx + r12*8]
    pop r12
    pop rbx
    leave
    ret

.miss:
    mov rdi, rbx
    call str_intern_cstr        ; kept for the life of the process
    lea rcx, [rel dunder_cache_keys]
    mov [rcx + r12*8], rbx
    lea rcx, [rel dunder_cache_vals]
    mov [rcx + r12*8], rax
    pop r12
    pop rbx
    leave
    ret
END_FUNC dunder_name_obj

section .bss
align 8
dunder_cache_keys: resq DUNDER_CACHE_SLOTS
dunder_cache_vals: resq DUNDER_CACHE_SLOTS

section .text

;; ============================================================================
;; dunder_lookup(PyTypeObject *type, const char *name) -> rax = Value
;;
;; Walk type->tp_base chain, looking up name in each type's tp_dict.
;; rdi = type object, rsi = C string name
;; Returns: borrowed reference to function, or NULL if not found.
;; ============================================================================
DLO_OWNER equ 8
DLO_FRAME equ 16            ; + 4 pushes = 48, 16-aligned
global dunder_lookup_owner
DEF_FUNC_BARE dunder_lookup
    xor edx, edx                ; no owner wanted
    jmp dunder_lookup_owner
END_FUNC dunder_lookup

;; ============================================================================
;; dunder_lookup_owner(PyTypeObject *type, const char *name,
;;                     PyTypeObject **owner_out) -> rax = Value
;;
;; The same walk, reporting WHERE it stopped.  The caller that needs this is
;; type_install_slots: a dunder a builtin base supplies is not a definition
;; the subclass made, and installing a generic wrapper over it is wrong --
;; type_from_parts has already handed the subclass the base's real slot by
;; pointer.  Which type's tp_dict answered is the only way to tell the two
;; apart, and the value alone cannot say.
;;
;; rdx may be 0, which is what dunder_lookup passes.
;; ============================================================================
DEF_FUNC dunder_lookup_owner, DLO_FRAME
    push rbx
    push r12
    push r13
    push r14                ; holds the origin type

    mov [rbp - DLO_OWNER], rdx
    mov rbx, rdi            ; rbx = type (walks the MRO)
    mov r14, rdi            ; r14 = origin of the walk
    mov r12, rsi            ; r12 = name C string

    ; The interned name for this literal; borrowed, so no DECREF on the way out.
    mov rdi, r12
    call dunder_name_obj
    mov r13, rax            ; r13 = name string object

.walk:
    test rbx, rbx
    jz .not_found

    ; Check tp_dict
    mov rdi, [rbx + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .try_base

    mov rsi, r13
    call dict_get           ; dict_get(tp_dict, name_str) -> borrowed ref
    test rax, rax               ; a Value already, and 0 is the miss
    jnz .found

.try_base:
    MRO_NEXT rbx, r14
    jmp .walk

.found:
    mov rcx, [rbp - DLO_OWNER]
    test rcx, rcx
    jz .found_no_owner
    mov [rcx], rbx          ; the MRO entry whose tp_dict answered
.found_no_owner:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret                     ; rax is the Value dict_get answered with

.not_found:
    xor eax, eax            ; a NULL Value

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dunder_lookup_owner

;; ============================================================================
;; dunder_lookup_after(rdi = the class itself, rsi = name cstr) -> rax = Value
;;
;; What CPython writes as `super(cls, cls).name`: the same walk as
;; dunder_lookup, started one entry further along the class's OWN MRO, so the
;; class's own definition is skipped and everything behind it is not.
;;
;; __init_subclass__ is what needs this.  It used to be looked up on the
;; LAYOUT base -- the widest of the bases -- which is not where Python says to
;; look: `class D(Mixin, Base)` picked whichever of the two was wider, so a
;; hook on the other one never ran.  unittest.TestCase is written that way,
;; and 44 of CPython 3.12's own test modules ended on the AttributeError that
;; followed.  Skipping the first entry is also what keeps the class from
;; calling its own hook on itself: type_wrap_implicit_classmethods has
;; already put one in its dict by the time this runs.
;; ============================================================================
DLA_FRAME equ 16            ; + 4 pushes = 48, 16-aligned
global dunder_lookup_after
DEF_FUNC dunder_lookup_after, DLA_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov r14, rdi            ; r14 = the origin whose MRO is authoritative
    mov rbx, rdi            ; rbx walks it
    mov r12, rsi            ; r12 = name C string

    mov rdi, r12
    call dunder_name_obj
    mov r13, rax            ; borrowed, so no DECREF on the way out

    MRO_NEXT rbx, r14       ; start AFTER the class itself

.dla_walk:
    test rbx, rbx
    jz .dla_not_found

    mov rdi, [rbx + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .dla_next

    mov rsi, r13
    call dict_get           ; a Value already, and 0 is the miss
    test rax, rax
    jnz .dla_done

.dla_next:
    MRO_NEXT rbx, r14
    jmp .dla_walk

.dla_not_found:
    xor eax, eax

.dla_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dunder_lookup_after

;; ============================================================================
;; dunder_bind(rdi = what dunder_lookup found, rsi = self)
;;   -> rax = the callable to use; edx = 0 when self is prepended to its
;;      arguments and rax is borrowed, 1 when self is NOT an argument and rax
;;      is OWNED, 2 when __get__ raised and rax is 0
;;
;; CPython's lookup_maybe_method.  It asks one question of what the type's
;; MRO answered with: is it a DESCRIPTOR?
;;
;;   - a plain function is a METHOD_DESCRIPTOR, and is called unbound with
;;     self as its first argument.  This is the fast path, kept exactly so a
;;     bound method need not be built per call
;;   - a descriptor of any other kind goes through its own __get__ first, and
;;     what that answers is called WITHOUT self
;;   - anything that is NOT a descriptor at all is called exactly as it
;;     stands, also WITHOUT self
;;
;; The three dunder_call_* used to prepend self unconditionally, so a dunder
;; that is a DESCRIPTOR was never bound at all -- its __get__ never ran and
;; the descriptor OBJECT was called instead.  For one with no __call__ that is
;; a jump to a NULL tp_call: unittest.mock installs exactly this shape
;; (MagicProxy, one per magic method), and every MagicMock test segfaulted.
;;
;; The third arm is the other half of the same mistake, and it stood for
;; longer.  A dunder that is ALREADY BOUND -- `type("C", (), {"__len__":
;; L.__len__})` -- is not a descriptor, so self was prepended to a callable
;; that had one, and every slot reached through the protocol raised TypeError
;; about arity while the SAME attribute read off the instance worked.  The
;; worst of them did not raise: a generator's __next__ swallowed the extra
;; argument and answered the ITERATOR at exhaustion instead of raising
;; StopIteration, so a `for` over such an object never terminated.  That is
;; how xml.etree.ElementTree.iterparse builds its iterator.
;;
;; The question is asked of the TYPE, not of the name: staticmethod(...) and
;; a plain callable instance come out right for the same reason a bound
;; method does.
;; ============================================================================
DB_FOUND equ 8
DB_SELF  equ 16
DB_FRAME equ 32             ; + 0 pushes = 32, 16-aligned
extern classmethod_type
extern obj_dealloc
global dunder_bind
DEF_FUNC dunder_bind, DB_FRAME
    mov [rbp - DB_FOUND], rdi
    mov [rbp - DB_SELF], rsi
    mov rax, [rdi + PyObject.ob_type]
    extern func_type
    lea rcx, [rel func_type]
    cmp rax, rcx
    je .db_unbound
    extern builtin_func_type
    lea rcx, [rel builtin_func_type]
    cmp rax, rcx
    je .db_unbound              ; its own convention is args[0] = self

    ; Anything else: bind it if its type says how, and otherwise take it
    ; exactly as it stands.
    mov rdi, rax
    lea rsi, [rel dunder_get]
    call dunder_lookup
    V_TEST_PTR rax, rcx
    ja .db_as_is                ; no __get__: not a descriptor

    mov rdi, [rbp - DB_FOUND]
    mov rsi, [rbp - DB_SELF]
    mov rdx, [rsi + PyObject.ob_type]
    lea rcx, [rel dunder_get]
    mov r8d, TAG_PTR            ; both are heap pointers
    call dunder_call_3
    test rax, rax
    jz .db_raised
    mov edx, 1
    leave
    ret

.db_unbound:
    mov rax, [rbp - DB_FOUND]
    xor edx, edx
    leave
    ret

.db_as_is:
    ; Not a descriptor, so there is nothing to bind and nothing to prepend.
    ; edx = 1 promises the caller an OWNED reference -- it releases what it
    ; was handed -- and what dunder_lookup found is borrowed from a tp_dict.
    mov rax, [rbp - DB_FOUND]
    INCREF rax
    mov edx, 1
    leave
    ret

.db_raised:
    xor eax, eax
    mov edx, 2
    leave
    ret
END_FUNC dunder_bind

;; ============================================================================
;; dunder_lookup_special(rdi = the object, rsi = the dunder name C string)
;;   -> rax = an OWNED callable that takes no self, or 0 (with an exception
;;      pending only when __get__ raised)
;;
;; CPython's _PyObject_LookupSpecial: the type's own MRO, then the descriptor
;; protocol, and a plain function becomes a bound method.  BEFORE_WITH needs
;; the RESULT rather than the call, because __exit__ is pushed and invoked
;; later; everything else goes through dunder_call_*.
;; ============================================================================
DLS_OBJ   equ 8
DLS_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
global dunder_lookup_special
DEF_FUNC dunder_lookup_special, DLS_FRAME
    mov [rbp - DLS_OBJ], rdi
    mov rdi, [rdi + PyObject.ob_type]
    call dunder_lookup
    V_TEST_PTR rax, rcx
    ja .dls_miss

    mov rdi, rax
    mov rsi, [rbp - DLS_OBJ]
    call dunder_bind
    cmp edx, 2
    je .dls_raised
    test edx, edx
    jnz .dls_owned

    ; A plain function: bind it the way an attribute access would.
    mov rdi, rax
    mov rsi, [rbp - DLS_OBJ]
    extern method_new
    call method_new
.dls_owned:
    leave
    ret

.dls_miss:
.dls_raised:
    xor eax, eax
    leave
    ret
END_FUNC dunder_lookup_special

;; ============================================================================
;; dunder_call_1(PyObject *self, const char *name) -> (rax=payload, rdx=tag)
;;
;; dunder_call_1(rdi = self, rsi = dunder name C string) -> rax = the result
;;   Value, or 0 when the dunder is absent, is not callable, or raised.
;;
;; This said "(rax=payload, rdx=tag)" and had not for some time; the code
;; already ended `V_PACK rax, rdx`.  A stale signature here is not cosmetic --
;; V_PACK happened to leave the tag in rdx as well, so SIX callers grew a
;; `test edx, edx` against a second return value nobody had promised, and they
;; all broke the moment the pack went away.  dunder_call_2's docblock records
;; the same trap costing a real str.translate bug.  0 in rax is the answer.
;; ============================================================================
DEF_FUNC dunder_call_1
    push rbx
    push r12
    push r13
    push r14                ; alignment

    mov rbx, rdi            ; rbx = self

    ; Lookup dunder on self's type
    mov rdi, [rbx + PyObject.ob_type]
    ; rsi = name already set
    call dunder_lookup
    ; Absent, or present but not a pointer, is not callable -- and for a Value
    ; those are the same test: `ja` covers NULL and every immediate at once.
    ; This was V_UNPACK plus two tag tests; dunder_lookup already returns the
    ; Value, so the tag it synthesised was thrown away either way.
    V_TEST_PTR rax, r9
    ja .not_found
    IS_NONE rax, r9
    je .dunder_is_none

    ; Bind it, if it is a descriptor rather than a plain function.
    mov rdi, rax
    mov rsi, rbx
    call dunder_bind
    cmp edx, 2
    je .bind_raised
    mov r12, rax            ; r12 = the callable
    mov r13, rdx            ; 1 = already bound, so self is not an argument

    ; __get__ can answer anything at all, an immediate included, and an
    ; immediate has no ob_type to read.
    V_TEST_PTR r12, r9
    ja .bind_uncallable

    ; Call: tp_call(func, &[self], 1) -- or with no arguments at all
    mov rax, [r12 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .bind_uncallable

    sub rsp, 16             ; one Value; 16 keeps rsp aligned
    mov [rsp], rbx          ; args[0] = self
    mov rdi, r12            ; callable
    mov rsi, rsp            ; args ptr
    mov edx, 1              ; nargs
    test r13, r13
    jz .dc1_have_args
    xor edx, edx            ; bound: self is already in the callable
.dc1_have_args:
    push r15
    push r15                ; pushed twice: rsp must stay 16-byte aligned
    DUNDER_KW_SAVE r15      ; at the call, and the args pointer was taken
    call rax                ; before these, so it is unaffected
    DUNDER_KW_RESTORE r15
    pop r15
    pop r15
    add rsp, 16             ; pop args
    ; rax = result payload, rdx = result tag

    test r13, r13
    jz .dc1_done
    push rax
    sub rsp, 8
    mov rdi, r12            ; the bound callable was ours
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
.dc1_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret                     ; rax is already the Value

.bind_uncallable:
    ; A bound result that is not callable, or a descriptor object with no
    ; __call__.  The caller reads a NULL as "absent", and a slot wrapper turns
    ; that into "failed without an exception", so say what is wrong.
    ; COMPOSE FIRST, then release: the message names the bound object's TYPE
    ; and this is usually its last reference, so naming it afterwards read a
    ; freed object.
    mov rdi, r12
    extern value_type
    call value_type
    test rax, rax
    jz .dc1_name_it
    mov rsi, rax
    CSTRING rdi, `'\x01' object is not callable`
    extern type_name_message
    call type_name_message      ; rax = the composed C string
    mov r14, rax
    test r13, r13
    jz .dc1_raise_composed
    mov rdi, r12
    DECREF_V rdi, rcx
.dc1_raise_composed:
    lea rdi, [rel exc_TypeError_type]
    mov rsi, r14
    call raise_exception        ; does not return
.dc1_name_it:
    mov rsi, r12
    CSTRING rdi, `'\x01' object is not callable`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.bind_raised:
    ; __get__ raised.  A pending exception with a NULL answer is this
    ; function's documented shape, so it is the caller's to propagate.
    RET_NULL
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.dunder_is_none:
    ; A dunder explicitly set to None is not "absent": CPython installs the
    ; generic wrapper anyway and the call fails as "'NoneType' object is not
    ; callable".  Returning NULL with nothing pending instead made
    ; `__setattr__ = None` store silently and `__call__ = None` report the
    ; receiver as the thing that was not callable.
    ;
    ; The two slots whose WRAPPER interprets None -- tp_iter and tp_hash, the
    ; only ones update_one_slot special-cases -- test for it before they get
    ; here, so "not iterable" and "unhashable type" still win.
    extern exc_TypeError_type
    RAISE exc_TypeError_type, "'NoneType' object is not callable"

.not_found:
    RET_NULL
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret                     ; rax is already the Value
END_FUNC dunder_call_1

;; ============================================================================
;; dunder_call_2(PyObject *self, PyObject *other, const char *name, int other_tag)
;;   -> rax = the result Value, or a NULL one when there is no such dunder
;;
;; Look up dunder on self's type, call with (self, other).
;; rdi = self (heap ptr), rsi = other payload, rdx = dunder name, ecx = other_tag
;;
;; One Value out, packed -- not the (payload, tag) pair this said for a long
;; time after it stopped being true.  str.translate believed the comment and
;; packed the answer a second time, which is a no-op for a pointer and shifts
;; an int by V_INT_BIAS: a mapping that answered an ordinal reported
;; "character mapping must be in range(0x110000)".
;; ============================================================================
DEF_FUNC dunder_call_2
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi            ; rbx = self
    mov r12, rsi            ; r12 = other payload
    mov r14, rcx            ; r14 = other tag

    ; Lookup dunder on self's type
    mov rdi, [rbx + PyObject.ob_type]
    mov rsi, rdx            ; name
    call dunder_lookup
    ; Absent, or present but not a pointer, is not callable -- and for a Value
    ; those are the same test: `ja` covers NULL and every immediate at once.
    ; This was V_UNPACK plus two tag tests; dunder_lookup already returns the
    ; Value, so the tag it synthesised was thrown away either way.
    V_TEST_PTR rax, r9
    ja .not_found
    IS_NONE rax, r9
    je .dunder_is_none

    ; Bind it, if it is a descriptor rather than a plain function.
    mov rdi, rax
    mov rsi, rbx
    call dunder_bind
    cmp edx, 2
    je .bind_raised
    mov r13, rax            ; r13 = the callable
    push rdx                ; the bound flag; r15 is the caller's
    push rdx

    ; __get__ can answer anything at all, an immediate included.
    V_TEST_PTR r13, r9
    ja .bind_uncallable

    ; Call: tp_call(func, &[self, other], 2) -- or &[other], 1 when bound
    mov rax, [r13 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .bind_uncallable

    sub rsp, 16             ; 2 Values
    mov [rsp], rbx          ; args[0] = self
    V_PACK r12, r14         ; args[1] = other
    mov [rsp+8], r12
    mov rdi, r13            ; callable
    mov rsi, rsp            ; args ptr
    mov edx, 2              ; nargs
    cmp qword [rsp + 16], 0
    je .dc2_have_args
    lea rsi, [rsp + 8]      ; bound: self is already in the callable
    mov edx, 1
.dc2_have_args:
    push r15
    push r15                ; pushed twice: rsp must stay 16-byte aligned
    DUNDER_KW_SAVE r15      ; at the call, and the args pointer was taken
    call rax                ; before these, so it is unaffected
    DUNDER_KW_RESTORE r15
    pop r15
    pop r15
    add rsp, 16             ; pop args
    ; rax = result payload, rdx = result tag

    pop rcx
    pop rcx                 ; the bound flag
    test rcx, rcx
    jz .dc2_done
    push rax
    sub rsp, 8
    mov rdi, r13            ; the bound callable was ours
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
.dc2_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret                     ; rax is already the Value

.bind_uncallable:
    pop rcx
    pop rcx
    ; COMPOSE FIRST, then release: the message names the bound object's TYPE
    ; and this is usually its last reference, so naming it afterwards read a
    ; freed object.
    push rcx
    push rcx
    mov rdi, r13
    call value_type
    pop rcx
    pop rcx
    test rax, rax
    jz .dc2_name_it
    push rcx
    push rcx
    mov rsi, rax
    CSTRING rdi, `'\x01' object is not callable`
    call type_name_message      ; rax = the composed C string
    pop rcx
    pop rcx
    mov r14, rax
    test rcx, rcx
    jz .dc2_raise_composed
    mov rdi, r13
    DECREF_V rdi, rcx
.dc2_raise_composed:
    lea rdi, [rel exc_TypeError_type]
    mov rsi, r14
    call raise_exception        ; does not return
.dc2_name_it:
    mov rsi, r13
    CSTRING rdi, `'\x01' object is not callable`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.bind_raised:
    ; __get__ raised; a pending exception with a NULL answer is this
    ; function's documented shape.
    RET_NULL
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.dunder_is_none:
    ; A dunder explicitly set to None is not "absent": CPython installs the
    ; generic wrapper anyway and the call fails as "'NoneType' object is not
    ; callable".  Returning NULL with nothing pending instead made
    ; `__setattr__ = None` store silently and `__call__ = None` report the
    ; receiver as the thing that was not callable.
    ;
    ; The two slots whose WRAPPER interprets None -- tp_iter and tp_hash, the
    ; only ones update_one_slot special-cases -- test for it before they get
    ; here, so "not iterable" and "unhashable type" still win.
    extern exc_TypeError_type
    RAISE exc_TypeError_type, "'NoneType' object is not callable"

.not_found:
    RET_NULL
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret                     ; rax is already the Value
END_FUNC dunder_call_2

;; ============================================================================
;; mapping_getitem_opt(rdi = the mapping, rsi = the key, a pointer)
;;   -> rax = an OWNED Value, or 0
;;
;; `m[key]` for a mapping that is not a dict, asked in a way the CALLER can
;; recover from.
;;
;; A heaptype's mp_subscript is slot_mp_subscript, which does NOT return when
;; __getitem__ raises: it tail-jumps into the unwinder.  So the opcodes that
;; have to absorb a miss -- LOAD_NAME's probe of a custom locals, and
;; SETUP_ANNOTATIONS -- cannot go through the slot at all.  The dunder itself
;; answers a NULL Value and leaves the exception pending, which is what
;; CPython's PyObject_GetItem does for them.
;;
;; A NULL answer with NOTHING pending means there is no __getitem__ at all.
;; ============================================================================
global mapping_getitem_opt
DEF_FUNC mapping_getitem_opt
    lea rdx, [rel dunder_getitem]
    mov ecx, TAG_PTR            ; the key is a pointer; its Value is itself
    call dunder_call_2
    leave
    ret
END_FUNC mapping_getitem_opt

;; ============================================================================
;; dunder_call_3(PyObject *self, PyObject *arg1, PyObject *arg2, const char *name,
;;               int arg2_tag)
;;   -> rax = the result Value, or 0 when the dunder is absent, is not
;;      callable, or raised.  As in dunder_call_1: this said "(rax=payload,
;;      rdx=tag)" and did not mean it.
;;
;; Look up dunder on self's type, call with (self, arg1, arg2).
;; rdi = self (heap), rsi = arg1 (heap), rdx = arg2, rcx = dunder name,
;; r8d = arg2 tag (use TAG_PTR if arg2 is always a heap ptr).
;; Returns: result fat value (rax=payload, rdx=tag), or (0, TAG_NULL) if not found.
;; ============================================================================
DC3_BOUND equ 8             ; 1 when __get__ bound it and self is not an argument
DC3_ARG2  equ 16            ; arg2 as a Value, packed before r15 is needed again
DC3_FRAME equ 24            ; + 5 pushes = 64, 16-aligned
DEF_FUNC dunder_call_3, DC3_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi            ; rbx = self
    mov r12, rsi            ; r12 = arg1
    mov r13, rdx            ; r13 = arg2
    mov r15d, r8d           ; r15d = arg2 tag

    ; Lookup dunder on self's type
    mov rdi, [rbx + PyObject.ob_type]
    mov rsi, rcx            ; name
    call dunder_lookup
    ; Absent, or present but not a pointer, is not callable -- and for a Value
    ; those are the same test: `ja` covers NULL and every immediate at once.
    ; This was V_UNPACK plus two tag tests; dunder_lookup already returns the
    ; Value, so the tag it synthesised was thrown away either way.
    V_TEST_PTR rax, r9
    ja .not_found
    IS_NONE rax, r9
    je .dunder_is_none

    ; Bind it, if it is a descriptor rather than a plain function.  This is
    ; also the call dunder_bind itself makes, for __get__: that one is an
    ; ordinary function on every class that defines it, so the recursion stops
    ; at the func_type arm.
    V_PACK r13, r15         ; arg2 as a Value, before r15 is needed again
    mov [rbp - DC3_ARG2], r13
    mov rdi, rax
    mov rsi, rbx
    call dunder_bind
    cmp edx, 2
    je .bind_raised
    mov r14, rax            ; r14 = the callable
    mov [rbp - DC3_BOUND], rdx

    ; __get__ can answer anything at all, an immediate included.
    V_TEST_PTR r14, r9
    ja .bind_uncallable

    ; Call: tp_call(func, &[self, arg1, arg2], 3) -- or &[arg1, arg2], 2
    mov rax, [r14 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .bind_uncallable

    sub rsp, 32             ; 3 Values, rounded up to keep rsp aligned
    mov [rsp], rbx          ; args[0] = self
    mov [rsp+8], r12        ; args[1] = arg1
    mov r13, [rbp - DC3_ARG2]
    mov [rsp+16], r13       ; args[2] = arg2
    mov rdi, r14            ; callable
    mov rsi, rsp            ; args ptr
    mov edx, 3              ; nargs
    cmp qword [rbp - DC3_BOUND], 0
    je .dc3_have_args
    lea rsi, [rsp + 8]      ; bound: self is already in the callable
    mov edx, 2
.dc3_have_args:
    push r15
    push r15                ; pushed twice: rsp must stay 16-byte aligned
    DUNDER_KW_SAVE r15      ; at the call, and the args pointer was taken
    call rax                ; before these, so it is unaffected
    DUNDER_KW_RESTORE r15
    pop r15
    pop r15
    add rsp, 32             ; pop args
    ; rax = result payload, rdx = result tag

    cmp qword [rbp - DC3_BOUND], 0
    je .dc3_done
    push rax
    sub rsp, 8
    mov rdi, r14            ; the bound callable was ours
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
.dc3_done:

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret                     ; rax is already the Value

.bind_uncallable:
    ; COMPOSE FIRST, then release: the message names the bound object's TYPE
    ; and this is usually its last reference, so naming it afterwards read a
    ; freed object.
    mov rdi, r14
    call value_type
    test rax, rax
    jz .dc3_name_it
    mov rsi, rax
    CSTRING rdi, `'\x01' object is not callable`
    call type_name_message      ; rax = the composed C string
    mov r15, rax
    cmp qword [rbp - DC3_BOUND], 0
    je .dc3_raise_composed
    mov rdi, r14
    DECREF_V rdi, rcx
.dc3_raise_composed:
    lea rdi, [rel exc_TypeError_type]
    mov rsi, r15
    call raise_exception        ; does not return
.dc3_name_it:
    mov rsi, r14
    CSTRING rdi, `'\x01' object is not callable`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.bind_raised:
    ; __get__ raised; a pending exception with a NULL answer is this
    ; function's documented shape.
    RET_NULL
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.dunder_is_none:
    ; A dunder explicitly set to None is not "absent": CPython installs the
    ; generic wrapper anyway and the call fails as "'NoneType' object is not
    ; callable".  Returning NULL with nothing pending instead made
    ; `__setattr__ = None` store silently and `__call__ = None` report the
    ; receiver as the thing that was not callable.
    ;
    ; The two slots whose WRAPPER interprets None -- tp_iter and tp_hash, the
    ; only ones update_one_slot special-cases -- test for it before they get
    ; here, so "not iterable" and "unhashable type" still win.
    extern exc_TypeError_type
    RAISE exc_TypeError_type, "'NoneType' object is not callable"

.not_found:
    RET_NULL
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret                     ; rax is already the Value
END_FUNC dunder_call_3

;; ============================================================================
;; obj_call_n(Value callable, Value *args, uint64_t nargs) -> Value, or 0
;;
;; Call anything callable: a function, a builtin, a type, or an instance of a
;; class that defines __call__.  Going through tp_call alone misses the last of
;; those -- a user class carries __call__ in its dict, and only op_call knew to
;; look there -- so a property whose getter was an operator.itemgetter reported
;; "unreadable attribute" rather than calling it.
;;
;; Returns 0 with a TypeError pending when the object is not callable.  nargs
;; is bounded because the self-prepended copy lives in this frame; every
;; descriptor use passes one or two.
;; ============================================================================
OCN_MAX equ 8

OCN_FN    equ 8
OCN_BUF   equ 32 + (OCN_MAX + 1) * 8
OCN_FRAME equ ((OCN_BUF + 15) / 16) * 16 + 8    ; + 3 pushes = 16-aligned
DEF_FUNC obj_call_n, OCN_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    V_TEST_PTR rbx, rax
    ja .not_callable
    test rbx, rbx
    jz .not_callable

    mov rax, [rbx + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_call]
    test rcx, rcx
    jz .try_dunder

    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call rcx
    jmp .ret

.try_dunder:
    ; A heaptype instance whose class defines __call__: dispatch to that with
    ; the object itself as the first argument.
    test dword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .not_callable
    mov rdi, rax
    lea rsi, [rel dunder_call]
    call dunder_lookup
    ; As in dunder_call_1: absent and "present but not a pointer" are one
    ; test on the Value dunder_lookup already returns.
    V_TEST_PTR rax, r9
    ja .not_callable
    mov [rbp - OCN_FN], rax

    cmp r13, OCN_MAX
    ja .not_callable

    ; args' = [self, args...]
    lea rdi, [rbp - OCN_BUF]
    mov [rdi], rbx
    xor ecx, ecx
.copy:
    cmp rcx, r13
    jae .copied
    mov rax, [r12 + rcx*8]
    mov [rdi + rcx*8 + 8], rax
    inc rcx
    jmp .copy
.copied:
    mov rax, [rbp - OCN_FN]
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .not_callable
    mov rdi, rax
    lea rsi, [rbp - OCN_BUF]
    lea rdx, [r13 + 1]
    call rcx
    jmp .ret

.not_callable:
    ; CPython names the type: "'int' object is not callable" is what tells a
    ; caller WHICH of its values was not a function.
    mov rsi, rbx
    CSTRING rdi, `'\x01' object is not callable`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
.ret:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC obj_call_n

section .data
; Pre-defined dunder name strings (C strings for convenience)
global dunder_eq
global dunder_ne
global dunder_lt
global dunder_le
global dunder_gt
global dunder_ge
global dunder_add
global dunder_radd
global dunder_sub
global dunder_rsub
global dunder_mul
global dunder_rmul
global dunder_truediv
global dunder_rtruediv
global dunder_floordiv
global dunder_rfloordiv
global dunder_mod
global dunder_rmod
global dunder_pow
global dunder_rpow
global dunder_and
global dunder_or
global dunder_xor
global dunder_lshift
global dunder_rshift
global dunder_iter
global dunder_aiter
global dunder_anext
global dunder_next
global dunder_getitem
global dunder_setitem
global dunder_contains
global dunder_len
global dunder_bool
global dunder_call
global obj_call_n
global dunder_iadd
global dunder_isub
global dunder_imul
global dunder_iand
global dunder_ifloordiv
global dunder_ilshift
global dunder_imatmul
global dunder_imod
global dunder_ior
global dunder_ipow
global dunder_irshift
global dunder_itruediv
global dunder_ixor
global dunder_rmatmul
global dunder_rand
global dunder_ror
global dunder_rxor
global dunder_rlshift
global dunder_rrshift
global dunder_repr
global dunder_str
global dunder_matmul
global dunder_get
global dunder_enter
global dunder_set
global dunder_del

dunder_eq:       db "__eq__", 0
dunder_ne:       db "__ne__", 0
dunder_lt:       db "__lt__", 0
dunder_le:       db "__le__", 0
dunder_gt:       db "__gt__", 0
dunder_ge:       db "__ge__", 0
dunder_add:      db "__add__", 0
dunder_radd:     db "__radd__", 0
dunder_sub:      db "__sub__", 0
dunder_rsub:     db "__rsub__", 0
dunder_mul:      db "__mul__", 0
dunder_rmul:     db "__rmul__", 0
dunder_truediv:  db "__truediv__", 0
dunder_rtruediv: db "__rtruediv__", 0
dunder_floordiv: db "__floordiv__", 0
dunder_rfloordiv: db "__rfloordiv__", 0
dunder_mod:      db "__mod__", 0
dunder_rmod:     db "__rmod__", 0
dunder_pow:      db "__pow__", 0
dunder_rpow:     db "__rpow__", 0
dunder_and:      db "__and__", 0
dunder_or:       db "__or__", 0
dunder_xor:      db "__xor__", 0
dunder_lshift:   db "__lshift__", 0
dunder_rshift:   db "__rshift__", 0
dunder_iter:     db "__iter__", 0
dunder_next:     db "__next__", 0
dunder_aiter:    db "__aiter__", 0
dunder_anext:    db "__anext__", 0
dunder_getitem:  db "__getitem__", 0
dunder_setitem:  db "__setitem__", 0
dunder_contains: db "__contains__", 0
dunder_len:      db "__len__", 0
dunder_bool:     db "__bool__", 0
dunder_call:     db "__call__", 0
dunder_iadd:     db "__iadd__", 0
dunder_isub:     db "__isub__", 0
dunder_imul:     db "__imul__", 0
dunder_iand:     db "__iand__", 0
dunder_ifloordiv: db "__ifloordiv__", 0
dunder_ilshift:  db "__ilshift__", 0
dunder_imatmul:  db "__imatmul__", 0
dunder_imod:     db "__imod__", 0
dunder_ior:      db "__ior__", 0
dunder_ipow:     db "__ipow__", 0
dunder_irshift:  db "__irshift__", 0
dunder_itruediv: db "__itruediv__", 0
dunder_ixor:     db "__ixor__", 0
dunder_rmatmul:  db "__rmatmul__", 0
dunder_rand:     db "__rand__", 0
dunder_ror:      db "__ror__", 0
dunder_rxor:     db "__rxor__", 0
dunder_rlshift:  db "__rlshift__", 0
dunder_rrshift:  db "__rrshift__", 0
dunder_repr:     db "__repr__", 0
dunder_str:      db "__str__", 0
dunder_matmul:   db "__matmul__", 0
dunder_get:      db "__get__", 0
dunder_enter:    db "__enter__", 0
dunder_set:      db "__set__", 0
dunder_del:      db "__del__", 0

; Compare op -> dunder name lookup table
global cmp_dunder_table
align 8
cmp_dunder_table:
    dq dunder_lt            ; 0 = PY_LT
    dq dunder_le            ; 1 = PY_LE
    dq dunder_eq            ; 2 = PY_EQ
    dq dunder_ne            ; 3 = PY_NE
    dq dunder_gt            ; 4 = PY_GT
    dq dunder_ge            ; 5 = PY_GE

; Binary op -> dunder name lookup table (indexed by NB_* code)
; Covers NB_ADD(0) through NB_XOR(12)
global binop_dunder_table
align 8
binop_dunder_table:
    dq dunder_add           ; 0  = NB_ADD
    dq dunder_and           ; 1  = NB_AND
    dq dunder_floordiv      ; 2  = NB_FLOOR_DIVIDE
    dq dunder_lshift        ; 3  = NB_LSHIFT
    dq dunder_matmul        ; 4  = NB_MATRIX_MULTIPLY
    dq dunder_mul           ; 5  = NB_MULTIPLY
    dq dunder_mod           ; 6  = NB_REMAINDER
    dq dunder_or            ; 7  = NB_OR
    dq dunder_pow           ; 8  = NB_POWER
    dq dunder_rshift        ; 9  = NB_RSHIFT
    dq dunder_sub           ; 10 = NB_SUBTRACT
    dq dunder_truediv       ; 11 = NB_TRUE_DIVIDE
    dq dunder_xor           ; 12 = NB_XOR

; Reflected binary op -> dunder name lookup table
global binop_rdunder_table
align 8
binop_rdunder_table:
    dq dunder_radd          ; 0  = NB_ADD -> __radd__
    dq dunder_rand          ; 1  = NB_AND -> __rand__
    dq dunder_rfloordiv     ; 2  = NB_FLOOR_DIVIDE -> __rfloordiv__
    dq dunder_rlshift       ; 3  = NB_LSHIFT -> __rlshift__
    dq dunder_rmatmul       ; 4  = NB_MATRIX_MULTIPLY -> __rmatmul__
    dq dunder_rmul          ; 5  = NB_MULTIPLY -> __rmul__
    dq dunder_rmod          ; 6  = NB_REMAINDER -> __rmod__
    dq dunder_ror           ; 7  = NB_OR -> __ror__
    dq dunder_rpow          ; 8  = NB_POWER -> __rpow__
    dq dunder_rrshift       ; 9  = NB_RSHIFT -> __rrshift__
    dq dunder_rsub          ; 10 = NB_SUBTRACT -> __rsub__
    dq dunder_rtruediv      ; 11 = NB_TRUE_DIVIDE -> __rtruediv__
    dq dunder_rxor          ; 12 = NB_XOR -> __rxor__

; Inplace binary op -> dunder name lookup table
; Indexed by (NB_INPLACE_* - 13), same 0-12 order as binop_dunder_table
global binop_inplace_dunder_table
align 8
binop_inplace_dunder_table:
    dq dunder_iadd           ; 0  = NB_ADD -> __iadd__
    dq dunder_iand           ; 1  = NB_AND -> __iand__
    dq dunder_ifloordiv      ; 2  = NB_FLOOR_DIVIDE -> __ifloordiv__
    dq dunder_ilshift        ; 3  = NB_LSHIFT -> __ilshift__
    dq dunder_imatmul        ; 4  = NB_MATRIX_MULTIPLY -> __imatmul__
    dq dunder_imul           ; 5  = NB_MULTIPLY -> __imul__
    dq dunder_imod           ; 6  = NB_REMAINDER -> __imod__
    dq dunder_ior            ; 7  = NB_OR -> __ior__
    dq dunder_ipow           ; 8  = NB_POWER -> __ipow__
    dq dunder_irshift        ; 9  = NB_RSHIFT -> __irshift__
    dq dunder_isub           ; 10 = NB_SUBTRACT -> __isub__
    dq dunder_itruediv       ; 11 = NB_TRUE_DIVIDE -> __itruediv__
    dq dunder_ixor           ; 12 = NB_XOR -> __ixor__
