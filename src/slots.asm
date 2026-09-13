; slots.asm - Install real type slots on a heaptype from its Python dunders.
;
; __build_class__ leaves every tp_as_*, tp_iter, tp_iternext, tp_hash, tp_call
; and tp_richcompare at zero.  Dispatch to a user class was therefore wired
; ad-hoc, one operation at a time, wherever somebody remembered: of the 163
; slot reads in the tree, 130 have no dunder fallback at all.  The ones nobody
; wired are simply absent -- sorted(MyIterator()) called through a NULL
; tp_iternext, any(MyIterable()) raised TypeError, and -obj dereferenced a
; NULL tp_as_number.
;
; This is CPython's answer: at class creation, install a small wrapper into
; the slot for each dunder the class defines.  Every slot reader then becomes
; correct with no edit -- including the 23 readers of tp_iter across 11 files
; -- and the ad-hoc fallbacks become dead weight rather than load-bearing.
;
; A wrapper cannot signal failure the way CPython's can, because most callers
; here do not check the result: get_iterator does `call rax` and immediately
; dereferences what comes back.  So a wrapper whose dunder raises re-enters
; the interpreter's unwinder directly, exactly as raise_exception does, and
; never returns to its caller.  The one exception is tp_iternext, where NULL
; is the ordinary "exhausted" answer and every caller already handles it.

%include "macros.inc"
%include "object.inc"

; Where a slot lives: directly in PyTypeObject, or in one of the three
; method tables it points at.  A table is allocated for a type only when it
; defines at least one dunder that belongs in it.
SLOT_DIRECT   equ 0
SLOT_NUMBER   equ 1
SLOT_SEQUENCE equ 2
SLOT_MAPPING  equ 3

; One row of the dunder-to-slot table.
struc SlotEntry
    .name:    resq 1        ; dunder name, a C string
    .kind:    resq 1        ; SLOT_DIRECT or which method table
    .offset:  resq 1        ; byte offset within PyTypeObject or that table
    .wrapper: resq 1        ; function to install there
endstruc

extern obj_is_true
extern object_type
extern none_singleton
extern dunder_lookup
extern dunder_lookup_owner
extern dunder_call_1
extern dunder_iter
extern dunder_next
extern current_exception
extern eval_exception_unwind
extern exc_StopIteration_type
extern obj_decref
extern obj_as_index
extern ap_malloc
extern raise_exception
extern exc_TypeError_type

section .text

;; ============================================================================
;; slot_ensure_table(rdi = type, esi = kind) -> rax = the method table
;;
;; Allocate the method table on first use and hang it off the type.  A
;; heaptype starts with all three pointers NULL, which is exactly what
;; "implements no numeric/sequence/mapping protocol" means, so they must stay
;; NULL unless the class actually defines something.
;; ============================================================================
DEF_FUNC_LOCAL slot_ensure_table
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi

    cmp esi, SLOT_NUMBER
    je .set_number
    cmp esi, SLOT_SEQUENCE
    je .set_sequence
    mov r13, PyTypeObject.tp_as_mapping
    mov r14, PyMappingMethods_size
    jmp .go
.set_number:
    mov r13, PyTypeObject.tp_as_number
    mov r14, PyNumberMethods_size
    jmp .go
.set_sequence:
    mov r13, PyTypeObject.tp_as_sequence
    mov r14, PySequenceMethods_size

.go:
    mov rax, [rbx + r13]
    test rax, rax
    jz .fresh

    ; The table may be an *ancestor's*: __build_class__ inherits the protocol
    ; slots of a builtin base by copying the pointer.  Writing a wrapper
    ; through it patched the builtin's own static table, so one `class
    ; MyInt(int)` with a __neg__ gave every int in the process that __neg__.
    ;
    ; The question has to be asked of the whole MRO, not just tp_base.  With
    ; multiple inheritance the table comes from whichever base supplied the
    ; layout, which need not be tp_base: `class IntFlag(int, ReprEnum, Flag)`
    ; inherits int's PyNumberMethods while its tp_base is elsewhere, so a
    ; tp_base-only test found no sharing and installed Flag's __invert__ into
    ; int's own static table.  Every plain `~n` in the process then went to
    ; slot_nb_invert, which dereferences its operand -- and an int immediate
    ; is not a pointer.  Importing enum and defining any IntFlag was enough.
    mov r12, rax                    ; the candidate table
    mov rcx, rbx                    ; MRO walker, starting at this type
.share_scan:
    MRO_NEXT rcx, rbx               ; clobbers rax; r12 holds the table
    test rcx, rcx
    jz .not_shared                  ; nothing above shares it: already ours
    cmp r12, [rcx + r13]
    jne .share_scan
    jmp .copy_shared

.not_shared:
    mov rax, r12                    ; type_mro_next returned 0 into rax
    jmp .have

.copy_shared:                       ; shared with an ancestor: copy first
    mov rdi, r14
    call .alloc_zeroed
    push rax
    mov rdi, rax
    mov rsi, r12
    mov rdx, r14
    extern ap_memcpy
    call ap_memcpy
    pop rax
    mov [rbx + r13], rax
    jmp .have

.fresh:
    mov rdi, r14
    call .alloc_zeroed
    mov [rbx + r13], rax

.have:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.alloc_zeroed:
    push rdi
    call ap_malloc
    pop rcx
    push rax
    mov rdi, rax
    shr rcx, 3
    xor eax, eax
    rep stosq
    pop rax
    ret
END_FUNC slot_ensure_table

;; ============================================================================
;; slot_table_offset(rsi = a SlotEntry kind) -> rax = the byte offset of the
;;   method-table pointer that kind lives in, within PyTypeObject
;;
;; The mapping slot_ensure_table already makes, needed on its own by the two
;; callers that want to READ a table rather than materialise one: the arm that
;; installs a builtin base's slot, and the one that declines to clear a slot
;; in a table this type does not have.
;; ============================================================================
DEF_FUNC_BARE slot_table_offset
    cmp esi, SLOT_NUMBER
    je .sto_number
    cmp esi, SLOT_SEQUENCE
    je .sto_sequence
    mov rax, PyTypeObject.tp_as_mapping
    ret
.sto_number:
    mov rax, PyTypeObject.tp_as_number
    ret
.sto_sequence:
    mov rax, PyTypeObject.tp_as_sequence
    ret
END_FUNC slot_table_offset

;; ============================================================================
;; slot_current(rbx = the SlotEntry, rbp = type_install_slots' frame)
;;   -> rax = what TIS_TYPE's slot for that entry holds right now, or 0
;;
;; Only type_install_slots calls this, and only to ask whether the slot still
;; holds the wrapper it installed -- which is what makes clearing safe.  It
;; reads the caller's frame directly rather than taking the type as an
;; argument, because the entry is already in rbx there.
;; ============================================================================
DEF_FUNC_BARE slot_current
    mov rsi, [rbx + SlotEntry.kind]
    mov rcx, [rbp - TIS_TYPE]
    test rsi, rsi
    jnz .sc_indirect
    mov rax, [rbx + SlotEntry.offset]
    mov rax, [rcx + rax]
    ret
.sc_indirect:
    push rbx
    call slot_table_offset
    pop rbx
    mov rcx, [rbp - TIS_TYPE]
    mov rcx, [rcx + rax]
    xor eax, eax
    test rcx, rcx
    jz .sc_done
    mov rax, [rbx + SlotEntry.offset]
    mov rax, [rcx + rax]
.sc_done:
    ret
END_FUNC slot_current

;; ============================================================================
;; slot_tp_hash(rdi = self, edx = tag) -> rax = i64 hash
;; ============================================================================
DEF_FUNC slot_tp_hash, 8    ; + 1 push = 16, 16-aligned
    ; `__hash__ = None` makes the type unhashable -- the one None case
    ; update_one_slot special-cases, where it installs
    ; PyObject_HashNotImplemented.  Asked here for the same reason
    ; slot_tp_iter asks: dunder_call_1 would otherwise report a NoneType.
    push rdi
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel sl_hash_name]
    call dunder_lookup
    V_UNPACK rax, rdx
    pop rdi
    test edx, edx
    jz .sth_go
    IS_NONE rax, rcx
    je .sth_unhashable

.sth_go:
    lea rsi, [rel sl_hash_name]
    call dunder_call_1
    V_UNPACK rax, rdx
    test edx, edx
    jz .failed
    ; __hash__ must return an int; obj_as_index raises otherwise.
    push rax
    push rdx
    mov rdi, rax
    call obj_as_index
    add rsp, 16
    leave
    ret
.failed:
    call slot_reraise
.sth_unhashable:
    mov rsi, rdi
    CSTRING rdi, `unhashable type: '\x01'`
    jmp raise_type_error_with_name
END_FUNC slot_tp_hash

;; ============================================================================
;; Unary numeric slots.  Each is called as nb_xxx(rdi = operand Value) and
;; returns a Value.  Before this, -obj and ~obj on a user class dereferenced
;; a NULL tp_as_number, and +obj and abs(obj) were simply ignored.
;; ============================================================================
%macro DEF_UNARY_SLOT 2         ; %1 = function name, %2 = dunder name symbol
DEF_FUNC %1
    lea rsi, [rel %2]
    call dunder_call_1
    V_UNPACK rax, rdx
    test edx, edx
    jz %%failed
    V_PACK rax, rdx
    leave
    ret
%%failed:
    call slot_reraise
END_FUNC %1
%endmacro

;; ============================================================================
;; slot_nb_bool(rdi = self) -> eax = 0 or 1
;;
;; obj_is_true consults nb_bool, then sq_length, then mp_length, and only then
;; the __bool__ dunder -- so once __len__ reached a length slot it shadowed
;; __bool__, which is the wrong priority.  Installing nb_bool puts it back.
;; ============================================================================
DEF_FUNC slot_nb_bool
    lea rsi, [rel sl_bool_name]
    call dunder_call_1
    V_UNPACK rax, rdx
    test edx, edx
    jz .failed

    extern bool_true
    extern bool_false
    push rax
    push rdx
    cmp edx, TAG_PTR
    jne .not_bool
    lea rcx, [rel bool_true]
    cmp rax, rcx
    je .is_true
    lea rcx, [rel bool_false]
    cmp rax, rcx
    jne .not_bool
    pop rdx
    pop rdi
    call obj_decref
    xor eax, eax
    leave
    ret
.is_true:
    pop rdx
    pop rdi
    call obj_decref
    mov eax, 1
    leave
    ret
.not_bool:
    ; CPython names what came back -- "returned int" is what tells the author
    ; which of their returns was the wrong one.  The Value is rebuilt from the
    ; pair because value_type classifies a Value, and an immediate has no
    ; ob_type to read; the reference it still holds dies with the unwind.
    pop rdx
    pop rsi
    V_PACK rsi, rdx
    CSTRING rdi, `__bool__ should return bool, returned \x01`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
.failed:
    call slot_reraise
END_FUNC slot_nb_bool

;; ============================================================================
;; slot_nb_index / slot_nb_int / slot_nb_float -- conversion protocols.
;; ============================================================================
DEF_UNARY_SLOT slot_nb_index, sl_index_name
DEF_UNARY_SLOT slot_nb_int,   sl_int_name
DEF_UNARY_SLOT slot_nb_float, sl_float_name

;; ============================================================================
;; slot_tp_richcompare(rdi = left Value, rsi = right Value, edx = op) -> Value
;;
;; NULL means NotImplemented, which is what every caller of tp_richcompare
;; already expects.  Installed when the class defines any of the six
;; comparison dunders, so dict and set key lookup -- which consult
;; tp_richcompare -- start seeing a user class's __eq__.
;; ============================================================================
DEF_FUNC slot_tp_richcompare
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi

    ; op -> dunder name
    extern cmp_dunder_table
    lea rax, [rel cmp_dunder_table]
    movsxd rcx, edx
    mov rdx, [rax + rcx*8]      ; the dunder name

    ; dunder_call_2 takes `other` as a payload plus its tag, not a Value.
    mov rdi, rbx
    mov rsi, r12
    V_UNPACK rsi, rcx
    extern dunder_call_3
    extern obj_dealloc
    extern dunder_call_2
    call dunder_call_2
    V_UNPACK rax, rdx
    test edx, edx
    jz .rc_notimplemented

    ; A dunder answering NotImplemented is reported the same way a missing
    ; one is: NULL, so the caller tries the reflected operand.
    extern notimpl_singleton
    lea rcx, [rel notimpl_singleton]
    cmp rax, rcx
    je .rc_drop_notimpl

    V_PACK rax, rdx
    pop r12
    pop rbx
    leave
    ret

.rc_drop_notimpl:
    mov rdi, rax
    call obj_decref
.rc_notimplemented:
    RET_NULL
    pop r12
    pop rbx
    leave
    ret
END_FUNC slot_tp_richcompare


;; ============================================================================
;; slot_sq_contains(rdi = self, rsi = the value Value) -> eax = 0 or 1
;;
;; `x in obj` for a class that defines __contains__.  The one SEQUENCE slot
;; with a real dispatcher: unlike sq_concat and sq_repeat, CPython fills this
;; one in on a subclass, and so must we -- `class L(list)` with a
;; __contains__ answered list's membership test and never called the method.
;;
;; sq_contains has no error channel, only 0 or 1, so a raising __contains__
;; cannot be reported through the return value: it goes to slot_reraise like
;; every other wrapper here, and the exception reaches the `in` that asked.
;; ============================================================================
SC_EXC   equ 8
SC_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC slot_sq_contains, SC_FRAME
    DUNDER_EXC_SAVE [rbp - SC_EXC]
    V_UNPACK rsi, rcx           ; dunder_call_2 wants (payload, tag)
    lea rdx, [rel sl_contains_name]
    call dunder_call_2
    V_UNPACK rax, rdx
    test edx, edx
    jz .sc_failed

    ; Any truthy answer means yes, as CPython has it -- __contains__ may
    ; return a list, and `1 in NB()` is then False rather than a TypeError.
    push rax
    push rdx
    V_PACK rax, rdx
    mov rdi, rax
    call obj_is_true
    mov ecx, eax
    pop rdx
    pop rax
    push rcx
    V_PACK rax, rdx
    mov rdi, rax
    DECREF_V rdi, rsi
    pop rcx
    mov eax, ecx
    leave
    ret

.sc_failed:
    ; Missing, or it raised.  Missing cannot happen -- the wrapper is only
    ; installed when the class defines the name -- so slot_reraise's no-exception
    ; arm is the honest answer for it rather than a silent False.
    call slot_reraise           ; does not return
END_FUNC slot_sq_contains

;; ============================================================================
;; DEF_BINARY_SLOT wrapper, dunder_name_symbol, nb_field
;;
;; The generic dispatcher for a binary operator slot:
;;   (rdi = left Value, rsi = right Value) -> rax = result Value, or NULL
;;
;; A NULL Value means NotImplemented.  That is already what a declining nb_
;; slot means to op_binary_op and obj_binary_op, so the protocol carries on
;; to the right operand and then to the reflected dunder.  A dunder that
;; RAISES cannot be reported that way -- a NULL would read as a decline and
;; the exception would surface later at an unrelated instruction -- so it goes
;; to slot_reraise, like every other wrapper here.
;;
;; The wrapper speaks for BOTH operands, as CPython's SLOT1BINFULL does, and
;; the identity tests are what tell it which one it is speaking for.
;;
;; op_binary_op offers the pair to the RIGHT type's slot as well, with the
;; operands still in their original order.  If the wrapper answered there with
;; the LEFT object's __op__ it would be calling the wrong object entirely; so
;; it asks "am I the slot the LEFT operand's type actually holds?", and when
;; the answer is no it asks the mirror question about the right and calls
;; __rop__ instead.  That second arm is what a subclass of a BUILTIN needs:
;; MyFloat(float) defining only __radd__ inherits float's nb_add, which
;; answers before any reflected dunder can be reached, so `1 + MyFloat(2)`
;; came back 3.0.  CPython installs slot_nb_add on such a type precisely
;; because __radd__ was defined, and notices there that self is on the right.
;; ============================================================================
SB_LEFT  equ 8
SB_RIGHT equ 16
SB_EXC   equ 24
SB_OTHER equ 32             ; do_other: the right type holds this wrapper too
SB_FRAME equ 48             ; + 0 pushes = 48, 16-aligned

%macro DEF_BINARY_SLOT 3-4 0    ; %1 = wrapper, %2 = name symbol, %3 = nb field,
                                ; %4 = the reflected name symbol, or 0
DEF_FUNC %1, SB_FRAME
    mov [rbp - SB_LEFT], rdi
    mov [rbp - SB_RIGHT], rsi
    mov qword [rbp - SB_OTHER], 0

%ifnum %4
%else
    ; do_other, CPython's: the two types differ and the RIGHT one holds this
    ; same wrapper in this same slot.  Computed first because the forward arm
    ; below consults it before giving up.
    V_TEST_PTR rsi, rax
    ja %%have_other
    mov rax, [rsi + PyObject.ob_type]
    mov rcx, rdi
    push rax
    sub rsp, 8
    mov rdi, rcx
    extern value_type
    call value_type
    add rsp, 8
    mov rcx, rax
    pop rax                     ; the right type
    cmp rax, rcx
    je %%have_other             ; same type: there is no other side
    mov rdx, [rax + PyTypeObject.tp_as_number]
    test rdx, rdx
    jz %%have_other
    mov rdx, [rdx + PyNumberMethods.%3]
    lea rcx, [rel %1]
    cmp rdx, rcx
    jne %%have_other
    mov qword [rbp - SB_OTHER], 1
%%have_other:
    mov rdi, [rbp - SB_LEFT]
    mov rsi, [rbp - SB_RIGHT]
%endif

    V_TEST_PTR rdi, rax
    ja %%try_other              ; an immediate holds no slot of its own
    test rdi, rdi
    jz %%try_other
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jz %%try_other
    mov rax, [rax + PyNumberMethods.%3]
    lea rcx, [rel %1]
    cmp rax, rcx
    jne %%try_other             ; we are the RIGHT type's slot here

%ifnum %4
%else
    ; CPython's subclass-priority rule, which lives in SLOT1BINFULL and not
    ; in binary_op1: when the right operand's type is a PROPER SUBCLASS of
    ; the left's and overrides the reflected name, its __rop__ runs first.
    ; P() + Q() for a Q deriving from P called P.__add__ here and calls
    ; Q.__radd__ in CPython.
    ;
    ; It cannot be binary_op1's `slotv != slotw`: every heaptype that
    ; overrides an operator holds this same wrapper, so that compare is
    ; always equal and the rule would never fire.  CPython's own answer for
    ; a Python class is method_is_overloaded, which asks the two TYPES for
    ; the reflected name and compares what they hand back.
    mov rdi, [rbp - SB_LEFT]
    mov rsi, [rbp - SB_RIGHT]
    lea rdx, [rel %4]
    call slot_binop_reflect_first
    test ecx, ecx
    jz %%no_reflect
    cmp ecx, 2
    je %%raised
    leave
    ret                         ; rax is already a Value
%%no_reflect:
%endif

    DUNDER_EXC_SAVE [rbp - SB_EXC]
    mov rdi, [rbp - SB_LEFT]
    mov rsi, [rbp - SB_RIGHT]
    V_UNPACK rsi, rcx           ; dunder_call_2 wants (payload, tag)
    lea rdx, [rel %2]
    call dunder_call_2
    V_UNPACK rax, rdx
    test edx, edx
    jz %%none_or_raised

    lea rcx, [rel notimpl_singleton]
    cmp rax, rcx
    je %%drop_notimpl
    V_PACK rax, rdx
    leave
    ret

%%drop_notimpl:
    mov rdi, rax                ; dunder_call_2 hands back an owned reference
    call obj_decref

%%try_other:
%ifnum %4
%else
    ; The forward direction had nothing to say, or this wrapper is the right
    ; type's rather than the left's.  Either way, __rop__(right, left) is the
    ; remaining question, and only when the right type really does hold this
    ; slot -- otherwise op_binary_op's own reflected arm will ask it.
    cmp qword [rbp - SB_OTHER], 0
    je %%decline
    mov qword [rbp - SB_OTHER], 0   ; once
    DUNDER_EXC_SAVE [rbp - SB_EXC]
    mov rdi, [rbp - SB_RIGHT]
    mov rsi, [rbp - SB_LEFT]
    V_UNPACK rsi, rcx
    lea rdx, [rel %4]
    call dunder_call_2
    V_UNPACK rax, rdx
    test edx, edx
    jz %%none_or_raised
    lea rcx, [rel notimpl_singleton]
    cmp rax, rcx
    je %%drop_other_notimpl
    V_PACK rax, rdx
    leave
    ret
%%drop_other_notimpl:
    mov rdi, rax
    call obj_decref
%endif

%%decline:
    xor eax, eax                ; the NULL Value
    leave
    ret

%%none_or_raised:
    EXC_RAISED_SINCE [rbp - SB_EXC], rcx, %%raised
    xor eax, eax
    leave
    ret
%%raised:
    call slot_reraise           ; does not return
END_FUNC %1
%endmacro

;; ============================================================================
;; slot_binop_reflect_first(rdi = left Value, rsi = right Value,
;;                          rdx = the reflected name's C string)
;;   -> rax = a result VALUE with ecx = 1, or ecx = 0 to carry on,
;;      or ecx = 2 when the reflected call raised
;;
;; The status is in ecx and not edx because the answer is already a Value:
;; edx would be read as its tag, and TAG_SMALLINT is 1.
;;
;; Global, because obj_binary_op asks the same question: `sum([1, 2, MyInt(3)])`
;; has to answer MyInt.__radd__ for the same reason `1 + MyInt(3)` does, and
;; the two go through different functions.
;;
;; CPython's SLOT1BINFULL prologue.  The reflected form runs FIRST when the
;; right operand's type is a proper subclass of the left's and overrides the
;; reflected name -- so `P() + Q()` for a Q(P) defining __radd__ answers
;; Q.__radd__ rather than P.__add__.
;;
;; "Overrides" is method_is_overloaded: ask both TYPES for the reflected name
;; and compare what they hand back.  A raw slot compare cannot serve, because
;; every heaptype that overrides an operator holds the same wrapper.
;; ============================================================================
SBR_LEFT  equ 8
SBR_RIGHT equ 16
SBR_NAME  equ 24
SBR_EXC   equ 32
SBR_LMETH equ 40
SBR_LTYPE equ 48            ; the left type, which value_type may synthesise
SBR_FRAME equ 64            ; + 0 pushes = 64
global slot_binop_reflect_first
DEF_FUNC slot_binop_reflect_first, SBR_FRAME
    mov [rbp - SBR_LEFT], rdi
    mov [rbp - SBR_RIGHT], rsi
    mov [rbp - SBR_NAME], rdx

    ; The RIGHT operand has to be a heap object: an immediate's type is int or
    ; float exactly, and neither can be a proper subclass of anything.  The
    ; LEFT may well be an immediate -- `1 + MyInt(3)` and `sum([1, 2, MyInt(3)])`
    ; both put one there -- so its type comes from value_type, which knows the
    ; encoding, rather than from a dereference.
    V_TEST_PTR rsi, rax
    ja .sbr_no
    extern value_type
    call value_type              ; rdi is still the left Value
    test rax, rax
    jz .sbr_no
    mov [rbp - SBR_LTYPE], rax
    mov rcx, [rbp - SBR_RIGHT]
    mov rcx, [rcx + PyObject.ob_type]
    cmp rax, rcx
    je .sbr_no                  ; same type: nothing to prefer

    ; PyType_IsSubtype(type(right), type(left)), and a PROPER one -- the
    ; equality above has already excluded the other case.
    mov rdi, rcx
    mov rsi, rax
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jz .sbr_no

    ; method_is_overloaded: the right type must HAVE the reflected name, and
    ; it must not be the same object the left type hands back.
    mov rdi, [rbp - SBR_RIGHT]
    mov rdi, [rdi + PyObject.ob_type]
    mov rsi, [rbp - SBR_NAME]
    extern dunder_lookup
    call dunder_lookup
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    jz .sbr_no                  ; the right type does not define it
    mov [rbp - SBR_LMETH], rax  ; the right type's, for the compare below

    mov rdi, [rbp - SBR_LTYPE]
    mov rsi, [rbp - SBR_NAME]
    call dunder_lookup
    V_UNPACK rax, rdx
    test edx, edx
    jz .sbr_call                ; the left type has none: overridden
    cmp rax, [rbp - SBR_LMETH]
    je .sbr_no                  ; the same object: inherited, not overridden

.sbr_call:
    ; __rop__(right, left).
    DUNDER_EXC_SAVE [rbp - SBR_EXC]
    mov rdi, [rbp - SBR_RIGHT]
    mov rsi, [rbp - SBR_LEFT]
    V_UNPACK rsi, rcx
    mov rdx, [rbp - SBR_NAME]
    extern dunder_call_2
    call dunder_call_2
    V_UNPACK rax, rdx
    test edx, edx
    jz .sbr_none_or_raised

    extern notimpl_singleton
    lea rcx, [rel notimpl_singleton]
    cmp rax, rcx
    je .sbr_drop_notimpl
    V_PACK rax, rdx
    mov ecx, 1
    leave
    ret

.sbr_drop_notimpl:
    mov rdi, rax                ; dunder_call_2 hands back an owned reference
    extern obj_decref
    call obj_decref
.sbr_no:
    xor eax, eax
    xor ecx, ecx
    leave
    ret

.sbr_none_or_raised:
    EXC_RAISED_SINCE [rbp - SBR_EXC], rcx, .sbr_raised
    xor eax, eax
    xor ecx, ecx
    leave
    ret
.sbr_raised:
    xor eax, eax
    mov ecx, 2
    leave
    ret
END_FUNC slot_binop_reflect_first

DEF_UNARY_SLOT slot_nb_negative, sl_neg_name
DEF_UNARY_SLOT slot_nb_positive, sl_pos_name
DEF_UNARY_SLOT slot_nb_invert,   sl_invert_name
DEF_UNARY_SLOT slot_nb_absolute, sl_abs_name

; The binary operators, forward and in-place.  Reflected names get no
; wrapper: this one is one-directional, unlike CPython's SLOT1BIN, and
; op_binary_op's reflected-dunder arm already serves that direction.

DEF_BINARY_SLOT slot_nb_add, sl_add_name, nb_add, sl_radd_name
DEF_BINARY_SLOT slot_nb_sub, sl_sub_name, nb_subtract, sl_rsub_name
DEF_BINARY_SLOT slot_nb_mul, sl_mul_name, nb_multiply, sl_rmul_name
DEF_BINARY_SLOT slot_nb_mod, sl_mod_name, nb_remainder, sl_rmod_name
DEF_BINARY_SLOT slot_nb_divmod, sl_divmod_name, nb_divmod, sl_rdivmod_name
DEF_BINARY_SLOT slot_nb_pow, sl_pow_name, nb_power, sl_rpow_name
DEF_BINARY_SLOT slot_nb_lshift, sl_lshift_name, nb_lshift, sl_rlshift_name
DEF_BINARY_SLOT slot_nb_rshift, sl_rshift_name, nb_rshift, sl_rrshift_name
DEF_BINARY_SLOT slot_nb_and, sl_and_name, nb_and, sl_rand_name
DEF_BINARY_SLOT slot_nb_xor, sl_xor_name, nb_xor, sl_rxor_name
DEF_BINARY_SLOT slot_nb_or, sl_or_name, nb_or, sl_ror_name
DEF_BINARY_SLOT slot_nb_floordiv, sl_floordiv_name, nb_floor_divide, sl_rfloordiv_name
DEF_BINARY_SLOT slot_nb_truediv, sl_truediv_name, nb_true_divide, sl_rtruediv_name
DEF_BINARY_SLOT slot_nb_matmul, sl_matmul_name, nb_matmul, sl_rmatmul_name
DEF_BINARY_SLOT slot_nb_iadd, sl_iadd_name, nb_iadd
DEF_BINARY_SLOT slot_nb_isub, sl_isub_name, nb_isub
DEF_BINARY_SLOT slot_nb_imul, sl_imul_name, nb_imul
DEF_BINARY_SLOT slot_nb_imod, sl_imod_name, nb_irem
DEF_BINARY_SLOT slot_nb_ipow, sl_ipow_name, nb_ipow
DEF_BINARY_SLOT slot_nb_ilshift, sl_ilshift_name, nb_ilshift
DEF_BINARY_SLOT slot_nb_irshift, sl_irshift_name, nb_irshift
DEF_BINARY_SLOT slot_nb_iand, sl_iand_name, nb_iand
DEF_BINARY_SLOT slot_nb_ixor, sl_ixor_name, nb_ixor
DEF_BINARY_SLOT slot_nb_ior, sl_ior_name, nb_ior
DEF_BINARY_SLOT slot_nb_ifloordiv, sl_ifloordiv_name, nb_ifloor_divide
DEF_BINARY_SLOT slot_nb_itruediv, sl_itruediv_name, nb_itrue_divide
DEF_BINARY_SLOT slot_nb_imatmul, sl_imatmul_name, nb_imatmul

;; ============================================================================
;; slot_length(rdi = self) -> rax = i64
;;
;; Serves both mp_length and sq_length; builtin_len tries mapping first, and
;; GET_LEN in a match statement tries sequence first.
;; ============================================================================
DEF_FUNC slot_length
    lea rsi, [rel sl_len_name]
    call dunder_call_1
    V_UNPACK rax, rdx
    test edx, edx
    jz .failed
    push rax
    push rdx
    mov rdi, rax
    call obj_as_index
    add rsp, 16
    test rax, rax
    js .negative
    leave
    ret
.negative:
    extern exc_ValueError_type
    RAISE exc_ValueError_type, "__len__() should return >= 0"
.failed:
    call slot_reraise
END_FUNC slot_length

;; ============================================================================
;; slot_tp_setattr(rdi = self, rsi = name, rdx = the value Value, or 0)
;;   -> eax = 0, or does not return
;;
;; tp_setattr for a class that defines __setattr__ or __delattr__.  A NULL
;; value is a deletion, the same convention instance_setattr and
;; mp_ass_subscript use, so one wrapper serves both dunders.
;;
;; There was no row for either name in slot_table, so a class defining
;; __setattr__ kept the instance_setattr that type_from_parts installs: the
;; dunder sat in the class dict, answered `'__setattr__' in C.__dict__`, and
;; was never called.  Both `o.x = v` and `setattr(o, "x", v)` wrote straight
;; into the instance dict, and `del o.x` deleted without running __delattr__.
;;
;; object supplies both names, so type_install_slots' slot_is_object_default
;; check is what keeps an ordinary class -- which merely inherits them -- from
;; getting this wrapper and recursing into itself.
;; ============================================================================
STA_SELF  equ 8
STA_NAME  equ 16
STA_FRAME equ 24                    ; 24 + 1 push keeps rsp 16-aligned

DEF_FUNC slot_tp_setattr, STA_FRAME
    push rbx
    mov [rbp - STA_SELF], rdi
    mov [rbp - STA_NAME], rsi
    mov rbx, rdx
    test rbx, rbx
    jz .sta_delete

    ; __setattr__(self, name, value)
    mov rsi, [rbp - STA_NAME]
    mov rdx, rbx
    lea rcx, [rel sl_setattr_name]
    mov r8d, TAG_PTR
    V_UNPACK rdx, r8
    call dunder_call_3
    test rax, rax               ; dunder_call_3 answers with a Value; 0 is the miss
    jz .sta_failed
    mov rdi, rax
    DECREF_V rdi, rsi                   ; __setattr__ returns None
    xor eax, eax
    pop rbx
    leave
    ret

.sta_delete:
    ; __delattr__(self, name)
    mov rdi, [rbp - STA_SELF]
    mov rsi, [rbp - STA_NAME]
    lea rdx, [rel sl_delattr_name]
    mov ecx, TAG_PTR
    call dunder_call_2
    test rax, rax               ; dunder_call_2 answers with a Value; 0 is the miss
    jz .sta_failed
    mov rdi, rax
    DECREF_V rdi, rsi
    xor eax, eax
    pop rbx
    leave
    ret

.sta_failed:
    call slot_reraise                   ; does not return
END_FUNC slot_tp_setattr

;; ============================================================================
;; slot_mp_subscript(rdi = self, rsi = key Value) -> Value
;; slot_mp_ass_subscript(rdi = self, rsi = key Value, rdx = value Value)
;;
;; type_from_parts hands a builtin subclass its base's method table by pointer,
;; so a dict subclass that defines __setitem__ inherits dict's slot and the
;; Python method is never reached: `d["a"] = 1` went straight into dict's
;; storage.  Installing these wrappers is what makes the override take effect
;; -- collections.OrderedDict and enum's _EnumDict are both built on it.
;;
;; A NULL value Value means deletion, which is __delitem__, the same convention
;; dict_ass_subscript uses.
;; ============================================================================
DEF_FUNC slot_mp_subscript
    mov rdx, rsi
    V_UNPACK rdx, rcx
    mov rsi, rdx
    lea rdx, [rel sl_getitem_name]
    call dunder_call_2
    V_UNPACK rax, rdx
    test edx, edx
    jz .failed
    leave
    V_PACK rax, rdx
    ret
.failed:
    call slot_reraise           ; does not return
END_FUNC slot_mp_subscript

SAS_SELF  equ 8
SAS_KEY   equ 16
SAS_FRAME equ 24            ; + 1 push = 32
DEF_FUNC slot_mp_ass_subscript, SAS_FRAME
    push rbx
    mov [rbp - SAS_SELF], rdi
    mov [rbp - SAS_KEY], rsi
    mov rbx, rdx
    test rbx, rbx
    jz .delete

    ; __setitem__(self, key, value)
    mov rsi, [rbp - SAS_KEY]
    mov rdx, rbx
    lea rcx, [rel sl_setitem_name]
    mov r8d, TAG_PTR                    ; dunder_call_3 packs arg2 with this
    V_UNPACK rdx, r8
    call dunder_call_3
    test rax, rax               ; dunder_call_3 answers with a Value; 0 is the miss
    jz .failed
    mov rdi, rax
    DECREF_V rdi, rsi                   ; __setitem__ returns None
    xor eax, eax
    pop rbx
    leave
    ret

.delete:
    mov rdi, [rbp - SAS_SELF]
    mov rsi, [rbp - SAS_KEY]
    V_UNPACK rsi, rcx
    lea rdx, [rel sl_delitem_name]
    call dunder_call_2
    test rax, rax               ; dunder_call_2 answers with a Value; 0 is the miss
    jz .failed
    mov rdi, rax
    DECREF_V rdi, rsi
    xor eax, eax
    pop rbx
    leave
    ret
.failed:
    call slot_reraise           ; does not return
END_FUNC slot_mp_ass_subscript

;; ============================================================================
;; slot_reraise - resume unwinding with the exception the dunder left pending.
;;
;; Does not return.  If somehow nothing is pending, there is no coherent value
;; to hand back either, so report it rather than continue with a NULL.
;; ============================================================================
DEF_FUNC_LOCAL slot_reraise
    cmp qword [rel current_exception], 0
    je .no_exc
    leave
    jmp eval_exception_unwind
.no_exc:
    extern raise_exception
    extern exc_RuntimeError_type
    RAISE exc_RuntimeError_type, "slot wrapper failed without an exception"
END_FUNC slot_reraise

;; ============================================================================
;; slot_tp_iter(rdi = self) -> rax = iterator, a raw pointer
;;
;; get_iterator does `call rax` and then reads ob_type off the result without
;; a NULL check, so this must either return an object or not return.
;; ============================================================================
DEF_FUNC slot_tp_iter, 8    ; + 1 push = 16, 16-aligned
    ; `__iter__ = None` disables iteration, and says so in the type's own
    ; name.  This is one of exactly two slots whose wrapper interprets None
    ; -- the other is tp_hash -- and it has to be asked here, before
    ; dunder_call_1 turns a None dunder into "'NoneType' object is not
    ; callable".
    push rdi
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel dunder_iter]
    call dunder_lookup
    V_UNPACK rax, rdx
    pop rdi
    test edx, edx
    jz .sti_go                  ; absent: the ordinary path reports it
    IS_NONE rax, rcx
    je .sti_disabled

.sti_go:
    lea rsi, [rel dunder_iter]
    call dunder_call_1
    V_UNPACK rax, rdx
    test edx, edx
    jz .failed
    leave
    ret
.failed:
    call slot_reraise           ; does not return
.sti_disabled:
    mov rsi, rdi
    CSTRING rdi, `'\x01' object is not iterable`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
END_FUNC slot_tp_iter

;; ============================================================================
;; slot_tp_iternext(rdi = self) -> Value, or NULL when exhausted
;;
;; NULL is the ordinary answer here, so this mirrors call_iternext: a
;; StopIteration is swallowed and reported as exhaustion, and any other
;; exception is left pending for the caller to notice.
;; ============================================================================
DEF_FUNC slot_tp_iternext
    lea rsi, [rel dunder_next]
    call dunder_call_1
    test rax, rax               ; dunder_call_1 answers with a Value; 0 is the miss
    jnz .got_value

    mov rax, [rel current_exception]
    test rax, rax
    jz .exhausted
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel exc_StopIteration_type]
    cmp rcx, rdx
    jne .exhausted              ; a different exception: leave it pending
    mov rdi, rax
    mov qword [rel current_exception], 0
    call obj_decref

.exhausted:
    RET_NULL
    leave
    ret

.got_value:
    ; dunder_call_1 already answered with a Value; packing it again read rdx
    ; as a tag, and `class A(list): __next__ = list.pop` came back 2^50 out.
    leave
    ret
END_FUNC slot_tp_iternext



;; ============================================================================
;; slot_tp_call(rdi = self, rsi = Value *args, rdx = nargs) -> Value, or NULL
;;
;; tp_call for a class that defines __call__ in Python.  Until this existed,
;; tp_call stayed 0 on every heaptype and `x()` worked only because op_call
;; and obj_call_n each hand-rolled the __call__ lookup themselves.  Everything
;; that consults tp_call directly did not: `f(*args)` raised TypeError,
;; callable() answered False, and iter(o, sentinel), min/max's key= and the
;; weakref and signal callback checks all refused a working callable.
;;
;; The dunder is looked up on the TYPE, along the MRO, exactly as
;; obj_call_n's does -- not with getattr on the instance, which would find an
;; instance attribute CPython ignores here.
;;
;; Keyword arguments ride in the tail of the same flat array, named by the
;; kw_names_pending global.  Prepending self at the FRONT leaves that tail
;; where the callee expects it, so this must not touch the global.
;;
;; obj_call_n is the model, but its OCN_MAX of 8 cannot be inherited: this is
;; the general call path, and `c(*range(100))` is ordinary.  Small arities use
;; the frame buffer, anything larger takes a heap one.
;; ============================================================================
STC_MAX   equ 16              ; args held in the frame; above this, ap_malloc
STC_SELF  equ 8
STC_FUNC  equ 16
STC_HEAP  equ 24              ; the malloc'd buffer, or 0
STC_BOUND equ 32              ; 1 when __call__ was a descriptor and __get__
                              ; has already bound self into the callable
STC_BUF   equ 48 + (STC_MAX + 1) * 8
STC_FRAME equ ((STC_BUF + 15) / 16) * 16 + 8    ; + 3 pushes = 16-aligned

extern ap_malloc
extern ap_free
extern dunder_lookup
extern dunder_call
extern exc_MemoryError_type
extern set_exception
extern sub_list_for_type
extern c_recursion_depth
extern recursion_limit

global slot_tp_call
DEF_FUNC slot_tp_call, STC_FRAME
    push rbx
    push r12
    push r13

    ; `A.__call__ = A()` makes calling an A reach this again through the
    ; instance's own __call__, and again, with no Python frame anywhere in the
    ; chain -- so recursion_depth never moved and the machine stack simply ran
    ; out.  CPython raises RecursionError here (Py_EnterRecursiveCall in
    ; slot_tp_call), and its test_class has a test for exactly this.  The
    ; counter is the C one, reset wholesale by eval_exception_unwind.
    C_RECURSION_ENTER .stc_overflow

    mov [rbp - STC_SELF], rdi
    mov rbx, rsi                ; args
    mov r12, rdx                ; nargs
    mov qword [rbp - STC_HEAP], 0
    mov qword [rbp - STC_FUNC], 0   ; the first .stc_not_callable jump is
                                    ; before the lookup that fills it
    mov qword [rbp - STC_BOUND], 0

    ; __call__ on the type, along the MRO.
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel dunder_call]
    call dunder_lookup
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    jz .stc_not_callable

    ; A __call__ that is a DESCRIPTOR is bound first, and then takes the
    ; arguments unchanged: the self it would have been handed is already in
    ; the callable __get__ answered.  Calling the descriptor object itself is
    ; what every dunder call used to do, and for one with no __call__ of its
    ; own that is a jump to a NULL tp_call.
    mov rdi, rax
    mov rsi, [rbp - STC_SELF]
    extern dunder_bind
    call dunder_bind
    cmp edx, 2
    je .stc_get_raised
    mov [rbp - STC_FUNC], rax
    mov [rbp - STC_BOUND], rdx
    test rdx, rdx
    jnz .stc_bound_call

    ; Where the self-prepended copy goes.
    lea r13, [rbp - STC_BUF]
    cmp r12, STC_MAX
    jbe .stc_have_buf
    lea rdi, [r12 + 1]
    shl rdi, 3
    call ap_malloc
    test rax, rax
    jz .stc_no_memory
    mov [rbp - STC_HEAP], rax
    mov r13, rax

.stc_have_buf:
    mov rax, [rbp - STC_SELF]
    mov [r13], rax
    xor ecx, ecx
.stc_copy:
    cmp rcx, r12
    jge .stc_copied
    mov rax, [rbx + rcx*8]
    mov [r13 + rcx*8 + 8], rax
    inc rcx
    jmp .stc_copy

.stc_copied:
    ; Dispatch through __call__'s own tp_call, with self as argument zero.
    mov rax, [rbp - STC_FUNC]
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .stc_not_callable
    mov rdi, rax
    mov rsi, r13
    lea rdx, [r12 + 1]
    call rcx
    mov rbx, rax                ; the result, kept across ap_free

    mov rdi, [rbp - STC_HEAP]
    test rdi, rdi
    jz .stc_released
    call ap_free
.stc_released:
    cmp qword [rbp - STC_BOUND], 0
    je .stc_return
    push rbx
    sub rsp, 8
    mov rdi, [rbp - STC_FUNC]   ; the bound callable was ours
    DECREF_V rdi, rcx
    add rsp, 8
    pop rbx

.stc_return:
    C_RECURSION_LEAVE
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    leave
    ret

.stc_overflow:
    extern exc_RecursionError_type
    SET_EXC exc_RecursionError_type, "maximum recursion depth exceeded"
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret

.stc_bound_call:
    ; Bound: the arguments go through as they came, and this frame owes the
    ; callable a release -- on the failing road too, which is why that one
    ; does not jump straight to .stc_not_callable.
    mov rax, [rbp - STC_FUNC]
    V_TEST_PTR rax, rcx
    ja .stc_bound_uncallable
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .stc_bound_uncallable
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    call rcx
    mov rbx, rax                ; the result, kept across the release below
    jmp .stc_released

.stc_bound_uncallable:
    ; The message names what __get__ answered, and this is usually its last
    ; reference -- so COMPOSE FIRST and release after.  The order used to be
    ; the other way round, whatever the comment said, and .stc_not_callable
    ; read the freed object's ob_type.
    mov rdi, rax
    extern value_type
    call value_type
    test rax, rax
    jz .stc_bound_anon
    mov rsi, rax
    CSTRING rdi, `'\x01' object is not callable`
    call type_name_message      ; rax = the composed C string
    mov rbx, rax                ; rbx is this frame's, and pops below restore it
    mov rdi, [rbp - STC_FUNC]
    DECREF_V rdi, rcx
    mov qword [rbp - STC_BOUND], 0
    lea rdi, [rel exc_TypeError_type]
    mov rsi, rbx
    call set_exception
    jmp .stc_fail

.stc_bound_anon:
    mov rdi, [rbp - STC_FUNC]
    DECREF_V rdi, rcx
    mov qword [rbp - STC_BOUND], 0
    mov qword [rbp - STC_FUNC], 0
    jmp .stc_not_callable

.stc_get_raised:
    ; __get__ raised; its exception is pending and is the caller's.
    jmp .stc_fail

.stc_no_memory:
    SET_EXC exc_MemoryError_type, "out of memory"
    jmp .stc_fail

.stc_not_callable:
    ; The slot is installed, so __call__ was there at class creation and has
    ; since been removed or replaced with something uncallable.  Name what was
    ; found: `__call__ = None` is the common way to get here, and CPython says
    ; "'NoneType' object is not callable" for it -- the message used to name
    ; nothing at all.
    mov rax, [rbp - STC_FUNC]
    test rax, rax
    jz .stc_nc_anon
    V_TEST_PTR rax, rcx
    ja .stc_nc_value
    mov rsi, [rax + PyObject.ob_type]
    CSTRING rdi, `'\x01' object is not callable`
    extern type_name_message
    call type_name_message      ; rax = the composed C string
    mov rsi, rax
    lea rdi, [rel exc_TypeError_type]
    extern set_exception
    call set_exception
    jmp .stc_fail
.stc_nc_value:
    ; __get__ answered an immediate -- an int, a float -- which has no ob_type
    ; to read.  value_type is the one that takes a Value.
    mov rdi, rax
    extern value_type
    call value_type
    test rax, rax
    jz .stc_nc_anon
    mov rsi, rax
    CSTRING rdi, `'\x01' object is not callable`
    call type_name_message
    mov rsi, rax
    lea rdi, [rel exc_TypeError_type]
    call set_exception
    jmp .stc_fail

.stc_nc_anon:
    SET_EXC exc_TypeError_type, "object is not callable"

.stc_fail:
    mov rdi, [rbp - STC_HEAP]
    test rdi, rdi
    jz .stc_fail_ret
    call ap_free
.stc_fail_ret:
    C_RECURSION_LEAVE
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC slot_tp_call

;; ============================================================================
;; type_install_slots(rdi = heaptype)
;;
;; Fill the type's slots from the dunders it defines.  Called once at class
;; creation, and again by type_setattr when a dunder is assigned afterwards,
;; so `C.__iter__ = f` takes effect the way it does in CPython.
;; ============================================================================
TIS_TYPE  equ 8
TIS_ENTRY equ 16
TIS_FOUND equ 24
TIS_OWNER equ 32            ; the MRO entry whose tp_dict answered
TIS_BEST  equ 40            ; the strongest answer so far for this slot's group
TIS_RANK  equ 48            ; and how strong it is: 2 wrapper, 1 inherited, 0 none
TIS_SRC   equ 56            ; which type an inherited slot is read from
TIS_FRAME equ 64            ; + 2 pushes = 80, 16-aligned

DEF_FUNC type_install_slots, TIS_FRAME
    push rbx
    push r12

    mov [rbp - TIS_TYPE], rdi
    mov qword [rbp - TIS_BEST], 0
    mov dword [rbp - TIS_RANK], 0
    lea rbx, [rel slot_table]

.next_entry:
    mov rax, [rbx + SlotEntry.name]
    test rax, rax
    jz .done

    mov [rbp - TIS_ENTRY], rbx
    mov rdi, [rbp - TIS_TYPE]
    mov rsi, rax
    lea rdx, [rbp - TIS_OWNER]
    call dunder_lookup_owner    ; walks the MRO; returns a Value
    V_UNPACK rax, rdx
    mov rbx, [rbp - TIS_ENTRY]
    test edx, edx
    jz .not_found               ; nothing in the MRO defines this dunder
    mov [rbp - TIS_FOUND], rax

    ; A dunder a BUILTIN base supplies is not a definition this class made,
    ; and a generic wrapper must not be installed over it.  type_from_parts
    ; has already given the subclass that base's real slot by pointer, so
    ; leaving the slot alone is not merely safe -- it is the same thing
    ; CPython does when update_one_slot recognises an inherited wrapper
    ; descriptor and installs the base's own C function, one indirection
    ; earlier.
    ;
    ; Without this, `class E(int): pass` finds int's own __add__ in the MRO
    ; and would get a wrapper over it -- and int.__add__ refuses a float, so
    ; E(1) + 2.5 would answer NotImplemented both ways round and raise, where
    ; int's nb_add coerces and CPython answers 3.5.
    ;
    ; TYPE_FLAG_HEAPTYPE is set on every class type_from_parts builds and on
    ; nothing static, so the test is one flag on the type that answered.
    mov rcx, [rbp - TIS_OWNER]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .from_builtin

    ; A builtin method assigned by NAME into a class body is that builtin's
    ; own slot wearing a name, not a definition this class made.  The owner
    ; that answered is a heaptype -- the value is in ITS dict -- so the test
    ; above says nothing; what tells them apart is what the value IS.
    ;
    ; `__hash__ = ref.__hash__`, which is how weakref.WeakMethod is written,
    ; got the generic wrapper installed over it.  The wrapper looks the name
    ; up, finds the builtin, and the builtin dispatches on the ARGUMENT's type
    ; -- straight back into the wrapper.  hash() on one of those recursed
    ; until the C stack ran out, which is what CPython's test_weakref has been
    ; dying on.  update_one_slot recognises the same shape and installs the
    ; defining type's own function.
    ;
    ; Only when this type actually DERIVES from the one the method was stamped
    ; onto.  `class C: __hash__ = int.__hash__` is not that, and CPython
    ; leaves it to fail on the receiver check, which it does here too.
    ; edx still carries the tag dunder_lookup_owner answered with.
    cmp edx, TAG_PTR
    jne .own_definition
    mov rax, [rbp - TIS_FOUND]
    mov rcx, [rax + PyObject.ob_type]
    extern builtin_func_type
    lea rdx, [rel builtin_func_type]
    cmp rcx, rdx
    jne .own_definition
    mov rcx, [rax + PyBuiltinObject.func_owner]
    test rcx, rcx
    jz .own_definition
    mov [rbp - TIS_OWNER], rcx      ; whose slot .from_builtin will install
    mov rdi, [rbp - TIS_TYPE]
    mov rsi, rcx
    extern type_is_subtype
    call type_is_subtype
    mov rbx, [rbp - TIS_ENTRY]      ; the walk's cursor, across the call
    test eax, eax
    jnz .from_builtin

.own_definition:
    ; A dunder explicitly set to None is NOT skipped.  update_one_slot
    ; special-cases None for tp_hash alone; everywhere else the generic
    ; wrapper is installed and the call fails as "'NoneType' object is not
    ; callable", which is what CPython answers for __setattr__ = None,
    ; __getattr__ = None and __call__ = None.  The disabling that does happen
    ; lives in the wrappers: slot_tp_iter and slot_tp_hash test for None
    ; themselves, so `__iter__ = None` says "not iterable" while
    ; `callable(C())` stays True for `__call__ = None`.
    ;
    ; Skipping here left the previous slot in place, so `__setattr__ = None`
    ; silently stored and `__iter__ = None` after the class was built did
    ; nothing at all.
    ; object's own defaults are not a definition.  They live in
    ; object_type.tp_dict so that `MutableMapping.__ne__` and friends can be
    ; bound by name, but a builtin subclass that inherits one must keep the
    ; base type's C-level slot: installing a wrapper here would make
    ; `T((1,)) == (1,)` on a tuple subclass go through object's identity test
    ; instead of tuple's comparison.
    mov rax, [rbp - TIS_FOUND]

    mov rdx, [rbx + SlotEntry.wrapper]
    mov r8d, 2
    jmp .store

.not_found:
    ; Nothing in the MRO answers this name any more -- `del C.__iter__`.  The
    ; slot has to be EMPTIED, or it keeps pointing at a wrapper that finds no
    ; dunder and raises "slot wrapper failed without an exception" where
    ; CPython says "'A' object is not iterable".
    ;
    ; Writing 0 is the whole of it, and not "re-derive from the base":
    ; update_one_slot begins with NULL and ends `*ptr = specific ? specific :
    ; generic`, and inheritance is not re-derived because the lookup walks the
    ; WHOLE MRO -- a base that supplies the dunder is simply found, and that
    ; is the arm below.
    xor edx, edx
    xor r8d, r8d
    jmp .store

.from_builtin:
    ; A dunder a BUILTIN base supplies is not a definition this class made,
    ; and a generic wrapper must not be installed over it.  Install the
    ; OWNER's slot: CPython takes `specific = d->d_wrapped`, the base's own C
    ; function.  Leaving whatever is already there is right only at class
    ; creation, when type_from_parts has just copied that value in; after a
    ; delete the slot holds a stale wrapper and leaving it is the bug.
    ;
    ; Without this, `class E(int): pass` finds int's own __add__ in the MRO
    ; and would get a wrapper over it -- and int.__add__ refuses a float, so
    ; E(1) + 2.5 would answer NotImplemented both ways round and raise, where
    ; int's nb_add coerces and CPython answers 3.5.
    ; WHOSE slot to install.  For a real builtin base -- list, int, tuple --
    ; it is that base's, which is what type_from_parts copied in at creation
    ; and what a delete has to put back.
    ;
    ; object is the exception, and it has to be read from THIS type instead.
    ; object's dunders live in its tp_dict so that `MutableMapping.__ne__`
    ; and friends can be bound by name, but a heaptype's generic slot is not
    ; object's -- it is instance_setattr, instance_getattr and the rest, which
    ; type_from_parts already installed.  Writing object's over them made
    ; every plain `self.x = 1` answer "cannot set attribute".
    mov rcx, [rbp - TIS_OWNER]
    lea rax, [rel object_type]
    cmp rcx, rax
    jne .from_builtin_have_src
    mov rcx, [rbp - TIS_TYPE]   ; leave this type's own slot as it stands
.from_builtin_have_src:
    mov [rbp - TIS_SRC], rcx
    mov rsi, [rbx + SlotEntry.kind]
    test rsi, rsi
    jnz .from_builtin_indirect
    mov rax, [rbx + SlotEntry.offset]
    mov rdx, [rcx + rax]
    mov r8d, 1
    jmp .store
.from_builtin_indirect:
    ; The source's method table, if it has one; a missing table means it
    ; supplies nothing here and the slot is empty.
    call slot_table_offset      ; rax = the byte offset of that table
    mov rcx, [rbp - TIS_SRC]
    mov rcx, [rcx + rax]
    xor edx, edx
    mov r8d, 1
    test rcx, rcx
    jz .store
    mov rax, [rbx + SlotEntry.offset]
    mov rdx, [rcx + rax]
    jmp .store

    ;; .store -- rdx is this ENTRY's answer for the slot.  Several entries can
    ;; name the same slot -- __setattr__ and __delattr__ both drive
    ;; tp_setattr, __delitem__ joins __setitem__ on mp_ass_subscript, and all
    ;; six comparisons drive tp_richcompare -- and they are adjacent in the
    ;; table, exactly as update_one_slot's `do { ... } while (++p)->offset ==
    ;; offset` requires.  Resolving them one at a time let a later row undo an
    ;; earlier one: `__setattr__ = None` installed the wrapper and the
    ;; __delattr__ row, finding object's, immediately wrote object's slot back
    ;; over it, so the assignment stored silently.
    ;;
    ;; A group's answer is the strongest of its rows, and the rows share a
    ;; wrapper, so "strongest" is just: a wrapper beats an inherited slot,
    ;; which beats empty.
.store:
    ; rdx = this row's value, r8d = its RANK: 2 a wrapper this class earns, 1
    ; a slot inherited from a builtin base, 0 nothing.  The group keeps the
    ; highest, which is what "a wrapper anywhere in the group wins" means.
    cmp r8d, [rbp - TIS_RANK]
    jbe .store_keep_best
    mov [rbp - TIS_RANK], r8d
    mov [rbp - TIS_BEST], rdx
.store_keep_best:
    ; Is the NEXT row the same slot?  If so, let it have its say first.
    mov rcx, [rbx + SlotEntry_size + SlotEntry.name]
    test rcx, rcx
    jz .store_flush
    mov rax, [rbx + SlotEntry_size + SlotEntry.kind]
    cmp rax, [rbx + SlotEntry.kind]
    jne .store_flush
    mov rax, [rbx + SlotEntry_size + SlotEntry.offset]
    cmp rax, [rbx + SlotEntry.offset]
    jne .store_flush
    jmp .skip

.store_flush:
    mov rdx, [rbp - TIS_BEST]
    mov r9d, [rbp - TIS_RANK]
    mov qword [rbp - TIS_BEST], 0
    mov dword [rbp - TIS_RANK], 0
    test r9d, r9d
    jnz .store_write

    ; Rank 0 means "nothing in the MRO answers this name", and the slot is
    ; about to be emptied.  Only take out a wrapper THIS code installed.
    ;
    ; A builtin's slot is inherited by POINTER and often has no tp_dict entry
    ; to be found -- type.__call__ is not in type's dict here -- so "not
    ; found" does not mean "not there".  Clearing unconditionally emptied
    ; tp_call on every metaclass, and `Circle()` for a class with an ABCMeta
    ; metaclass became "'ABCMeta' object is not callable".
    push rdx
    call slot_current           ; rax = what the slot holds now
    pop rdx
    cmp rax, [rbx + SlotEntry.wrapper]
    jne .skip

.store_write:
    mov rcx, [rbp - TIS_TYPE]
    mov rsi, [rbx + SlotEntry.kind]
    test rsi, rsi
    jnz .store_indirect
    mov rax, [rbx + SlotEntry.offset]
    mov [rcx + rax], rdx
    jmp .skip

.store_indirect:
    ; Clearing a slot in a table this type does not have is nothing to do:
    ; there is no wrapper there to take out, and materialising a copy of the
    ; base's table to write a 0 into would break the inheritance it stands for.
    test rdx, rdx
    jnz .store_indirect_write
    push rdx
    call slot_table_offset
    mov rcx, [rbp - TIS_TYPE]
    mov rcx, [rcx + rax]
    pop rdx
    test rcx, rcx
    jz .skip
.store_indirect_write:
    push rdx
    mov rdi, [rbp - TIS_TYPE]
    mov rsi, [rbx + SlotEntry.kind]
    call slot_ensure_table      ; rax = the method table
    pop rdx
    mov rbx, [rbp - TIS_ENTRY]
    mov rcx, [rbx + SlotEntry.offset]
    mov [rax + rcx], rdx
    jmp .skip

.skip:
    add rbx, SlotEntry_size
    jmp .next_entry

.done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_install_slots

;; ============================================================================
;; type_install_slots_tree(rdi = a type) -> void
;;
;; type_install_slots for a class and for everything that derives from it.
;;
;; A slot is not inherited by pointer at run time: `type_from_parts` copies a
;; base's slot in when the subclass is BUILT, and nothing re-reads it after
;; that.  So `del A.__iter__` cleared A's tp_iter and left B(A) holding the
;; wrapper it was born with, which then found no dunder anywhere and raised
;; `RuntimeError: slot wrapper failed without an exception` where CPython says
;; `'B' object is not iterable`.  Assigning one had the mirror bug: `A.__len__
;; = f` after B exists never reached B.
;;
;; CPython's update_one_slot ends in update_subclasses for exactly this, and
;; type_refresh_attr_flags next door already walks the same side table for the
;; __getattribute__ bit.  A reinstall recomputes from the MRO, so it is
;; idempotent and the order within the tree does not matter.
;; ============================================================================
DEF_FUNC type_install_slots_tree
    push rbx
    push r12
    push r13
    push r14
    test rdi, rdi
    jz .tist_out
    mov rbx, rdi
    ; A static type has no slots to install -- its table is the definition --
    ; but it can still be walked past on the way to nothing.
    mov rax, [rbx + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_HEAPTYPE
    jz .tist_children
    mov rdi, rbx
    call type_install_slots
.tist_children:
    mov rdi, rbx
    call sub_list_for_type
    test rax, rax
    jz .tist_out
    mov r12, [rax + SubList.items]
    mov r13, [rax + SubList.count]
    test r12, r12
    jz .tist_out
    xor r14d, r14d
.tist_loop:
    cmp r14, r13
    jge .tist_out
    mov rdi, [r12 + r14*8]
    test rdi, rdi
    jz .tist_next
    call type_install_slots_tree
.tist_next:
    inc r14
    jmp .tist_loop
.tist_out:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_install_slots_tree

section .rodata

sl_iter_name:   db "__iter__", 0
sl_next_name:   db "__next__", 0
sl_hash_name:   db "__hash__", 0
sl_neg_name:    db "__neg__", 0
sl_contains_name: db "__contains__", 0
sl_add_name: db "__add__", 0
sl_radd_name: db "__radd__", 0
sl_rsub_name: db "__rsub__", 0
sl_rmul_name: db "__rmul__", 0
sl_rmod_name: db "__rmod__", 0
sl_rdivmod_name: db "__rdivmod__", 0
sl_rpow_name: db "__rpow__", 0
sl_rlshift_name: db "__rlshift__", 0
sl_rrshift_name: db "__rrshift__", 0
sl_rand_name: db "__rand__", 0
sl_rxor_name: db "__rxor__", 0
sl_ror_name: db "__ror__", 0
sl_rfloordiv_name: db "__rfloordiv__", 0
sl_rtruediv_name: db "__rtruediv__", 0
sl_rmatmul_name: db "__rmatmul__", 0
sl_sub_name: db "__sub__", 0
sl_mul_name: db "__mul__", 0
sl_mod_name: db "__mod__", 0
sl_divmod_name: db "__divmod__", 0
sl_pow_name: db "__pow__", 0
sl_lshift_name: db "__lshift__", 0
sl_rshift_name: db "__rshift__", 0
sl_and_name: db "__and__", 0
sl_xor_name: db "__xor__", 0
sl_or_name: db "__or__", 0
sl_floordiv_name: db "__floordiv__", 0
sl_truediv_name: db "__truediv__", 0
sl_matmul_name: db "__matmul__", 0
sl_iadd_name: db "__iadd__", 0
sl_isub_name: db "__isub__", 0
sl_imul_name: db "__imul__", 0
sl_imod_name: db "__imod__", 0
sl_ipow_name: db "__ipow__", 0
sl_ilshift_name: db "__ilshift__", 0
sl_irshift_name: db "__irshift__", 0
sl_iand_name: db "__iand__", 0
sl_ixor_name: db "__ixor__", 0
sl_ior_name: db "__ior__", 0
sl_ifloordiv_name: db "__ifloordiv__", 0
sl_itruediv_name: db "__itruediv__", 0
sl_imatmul_name: db "__imatmul__", 0
sl_pos_name:    db "__pos__", 0
sl_invert_name: db "__invert__", 0
sl_abs_name:    db "__abs__", 0
sl_len_name:    db "__len__", 0
sl_bool_name:   db "__bool__", 0
sl_index_name:  db "__index__", 0
sl_int_name:    db "__int__", 0
sl_float_name:  db "__float__", 0
sl_eq_name:     db "__eq__", 0
sl_ne_name:     db "__ne__", 0
sl_lt_name:     db "__lt__", 0
sl_le_name:     db "__le__", 0
sl_gt_name:     db "__gt__", 0
sl_ge_name:     db "__ge__", 0
sl_call_name:   db "__call__", 0
sl_getitem_name: db "__getitem__", 0
sl_setitem_name: db "__setitem__", 0
sl_delitem_name: db "__delitem__", 0
sl_setattr_name: db "__setattr__", 0
sl_delattr_name: db "__delattr__", 0

align 8
;; ============================================================================
;; slot_binop_wrappers -- the wrapper installed for each NB_* op, indexed
;; exactly as arith.asm's binary_op_offsets is: 0..12 forward, 13..25
;; in-place.  op_binary_op reads it to answer one question it cannot get from
;; the slot alone, now that every heaptype overriding an operator holds the
;; same function there: is this type's own __op__ what the slot would call?
;; ============================================================================
global slot_binop_wrappers
slot_binop_wrappers:
    dq slot_nb_add
    dq slot_nb_and
    dq slot_nb_floordiv
    dq slot_nb_lshift
    dq slot_nb_matmul
    dq slot_nb_mul
    dq slot_nb_mod
    dq slot_nb_or
    dq slot_nb_pow
    dq slot_nb_rshift
    dq slot_nb_sub
    dq slot_nb_truediv
    dq slot_nb_xor
    dq slot_nb_iadd
    dq slot_nb_iand
    dq slot_nb_ifloordiv
    dq slot_nb_ilshift
    dq slot_nb_imatmul
    dq slot_nb_imul
    dq slot_nb_imod
    dq slot_nb_ior
    dq slot_nb_ipow
    dq slot_nb_irshift
    dq slot_nb_isub
    dq slot_nb_itruediv
    dq slot_nb_ixor

slot_table:
    dq sl_call_name,   SLOT_DIRECT,   PyTypeObject.tp_call,     slot_tp_call
    dq sl_iter_name,   SLOT_DIRECT,   PyTypeObject.tp_iter,     slot_tp_iter
    dq sl_next_name,   SLOT_DIRECT,   PyTypeObject.tp_iternext, slot_tp_iternext
    dq sl_hash_name,   SLOT_DIRECT,   PyTypeObject.tp_hash,     slot_tp_hash
    dq sl_neg_name,    SLOT_NUMBER,   PyNumberMethods.nb_negative, slot_nb_negative
    dq sl_pos_name,    SLOT_NUMBER,   PyNumberMethods.nb_positive, slot_nb_positive
    dq sl_invert_name, SLOT_NUMBER,   PyNumberMethods.nb_invert,   slot_nb_invert
    dq sl_abs_name,    SLOT_NUMBER,   PyNumberMethods.nb_absolute, slot_nb_absolute
    dq sl_bool_name,   SLOT_NUMBER,   PyNumberMethods.nb_bool,     slot_nb_bool
    dq sl_index_name,  SLOT_NUMBER,   PyNumberMethods.nb_index,    slot_nb_index
    dq sl_int_name,    SLOT_NUMBER,   PyNumberMethods.nb_int,      slot_nb_int
    dq sl_float_name,  SLOT_NUMBER,   PyNumberMethods.nb_float,    slot_nb_float
    dq sl_len_name,    SLOT_MAPPING,  PyMappingMethods.mp_length,  slot_length
    dq sl_getitem_name, SLOT_MAPPING, PyMappingMethods.mp_subscript, slot_mp_subscript
    dq sl_setitem_name, SLOT_MAPPING, PyMappingMethods.mp_ass_subscript, slot_mp_ass_subscript
    dq sl_delitem_name, SLOT_MAPPING, PyMappingMethods.mp_ass_subscript, slot_mp_ass_subscript
    dq sl_setattr_name, SLOT_DIRECT, PyTypeObject.tp_setattr, slot_tp_setattr
    dq sl_delattr_name, SLOT_DIRECT, PyTypeObject.tp_setattr, slot_tp_setattr
    dq sl_len_name,    SLOT_SEQUENCE, PySequenceMethods.sq_length, slot_length
    dq sl_eq_name,     SLOT_DIRECT,   PyTypeObject.tp_richcompare, slot_tp_richcompare
    dq sl_ne_name,     SLOT_DIRECT,   PyTypeObject.tp_richcompare, slot_tp_richcompare
    dq sl_lt_name,     SLOT_DIRECT,   PyTypeObject.tp_richcompare, slot_tp_richcompare
    dq sl_le_name,     SLOT_DIRECT,   PyTypeObject.tp_richcompare, slot_tp_richcompare
    dq sl_gt_name,     SLOT_DIRECT,   PyTypeObject.tp_richcompare, slot_tp_richcompare
    dq sl_ge_name,     SLOT_DIRECT,   PyTypeObject.tp_richcompare, slot_tp_richcompare
    dq sl_contains_name, SLOT_SEQUENCE, PySequenceMethods.sq_contains, slot_sq_contains
    dq sl_add_name, SLOT_NUMBER, PyNumberMethods.nb_add, slot_nb_add
    dq sl_radd_name, SLOT_NUMBER, PyNumberMethods.nb_add, slot_nb_add
    dq sl_sub_name, SLOT_NUMBER, PyNumberMethods.nb_subtract, slot_nb_sub
    dq sl_rsub_name, SLOT_NUMBER, PyNumberMethods.nb_subtract, slot_nb_sub
    dq sl_mul_name, SLOT_NUMBER, PyNumberMethods.nb_multiply, slot_nb_mul
    dq sl_rmul_name, SLOT_NUMBER, PyNumberMethods.nb_multiply, slot_nb_mul
    dq sl_mod_name, SLOT_NUMBER, PyNumberMethods.nb_remainder, slot_nb_mod
    dq sl_rmod_name, SLOT_NUMBER, PyNumberMethods.nb_remainder, slot_nb_mod
    dq sl_divmod_name, SLOT_NUMBER, PyNumberMethods.nb_divmod, slot_nb_divmod
    dq sl_rdivmod_name, SLOT_NUMBER, PyNumberMethods.nb_divmod, slot_nb_divmod
    dq sl_pow_name, SLOT_NUMBER, PyNumberMethods.nb_power, slot_nb_pow
    dq sl_rpow_name, SLOT_NUMBER, PyNumberMethods.nb_power, slot_nb_pow
    dq sl_lshift_name, SLOT_NUMBER, PyNumberMethods.nb_lshift, slot_nb_lshift
    dq sl_rlshift_name, SLOT_NUMBER, PyNumberMethods.nb_lshift, slot_nb_lshift
    dq sl_rshift_name, SLOT_NUMBER, PyNumberMethods.nb_rshift, slot_nb_rshift
    dq sl_rrshift_name, SLOT_NUMBER, PyNumberMethods.nb_rshift, slot_nb_rshift
    dq sl_and_name, SLOT_NUMBER, PyNumberMethods.nb_and, slot_nb_and
    dq sl_rand_name, SLOT_NUMBER, PyNumberMethods.nb_and, slot_nb_and
    dq sl_xor_name, SLOT_NUMBER, PyNumberMethods.nb_xor, slot_nb_xor
    dq sl_rxor_name, SLOT_NUMBER, PyNumberMethods.nb_xor, slot_nb_xor
    dq sl_or_name, SLOT_NUMBER, PyNumberMethods.nb_or, slot_nb_or
    dq sl_ror_name, SLOT_NUMBER, PyNumberMethods.nb_or, slot_nb_or
    dq sl_floordiv_name, SLOT_NUMBER, PyNumberMethods.nb_floor_divide, slot_nb_floordiv
    dq sl_rfloordiv_name, SLOT_NUMBER, PyNumberMethods.nb_floor_divide, slot_nb_floordiv
    dq sl_truediv_name, SLOT_NUMBER, PyNumberMethods.nb_true_divide, slot_nb_truediv
    dq sl_rtruediv_name, SLOT_NUMBER, PyNumberMethods.nb_true_divide, slot_nb_truediv
    dq sl_matmul_name, SLOT_NUMBER, PyNumberMethods.nb_matmul, slot_nb_matmul
    dq sl_rmatmul_name, SLOT_NUMBER, PyNumberMethods.nb_matmul, slot_nb_matmul
    dq sl_iadd_name, SLOT_NUMBER, PyNumberMethods.nb_iadd, slot_nb_iadd
    dq sl_isub_name, SLOT_NUMBER, PyNumberMethods.nb_isub, slot_nb_isub
    dq sl_imul_name, SLOT_NUMBER, PyNumberMethods.nb_imul, slot_nb_imul
    dq sl_imod_name, SLOT_NUMBER, PyNumberMethods.nb_irem, slot_nb_imod
    dq sl_ipow_name, SLOT_NUMBER, PyNumberMethods.nb_ipow, slot_nb_ipow
    dq sl_ilshift_name, SLOT_NUMBER, PyNumberMethods.nb_ilshift, slot_nb_ilshift
    dq sl_irshift_name, SLOT_NUMBER, PyNumberMethods.nb_irshift, slot_nb_irshift
    dq sl_iand_name, SLOT_NUMBER, PyNumberMethods.nb_iand, slot_nb_iand
    dq sl_ixor_name, SLOT_NUMBER, PyNumberMethods.nb_ixor, slot_nb_ixor
    dq sl_ior_name, SLOT_NUMBER, PyNumberMethods.nb_ior, slot_nb_ior
    dq sl_ifloordiv_name, SLOT_NUMBER, PyNumberMethods.nb_ifloor_divide, slot_nb_ifloordiv
    dq sl_itruediv_name, SLOT_NUMBER, PyNumberMethods.nb_itrue_divide, slot_nb_itruediv
    dq sl_imatmul_name, SLOT_NUMBER, PyNumberMethods.nb_imatmul, slot_nb_imatmul

    dq 0, 0, 0, 0

