; pyo/uniontype.asm - types.UnionType: `int | None` as an object
;
; Split out of pyo/descriptors.asm, which was over the 100k cap that
; src/compiler/lint.py holds hand-written files to.  This is a seam the file
; already had: the union is a type of its own, reached only through nb_or, and
; it shares nothing with the descriptors around it but the tables that name
; its slots.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

extern ap_strcmp
extern ga_emit_name
extern generic_alias_new
extern generic_alias_type
extern obj_decref
extern obj_incref
extern str_new_heap
extern union_type
section .text


;; ============================================================================
;; union_type_or(rdi = the left Value, rsi = the right Value)
;;   -> (rax = a UnionType, rdx = TAG_PTR), or a NULL Value when the pair is
;;      not unionable
;;
;; types.UnionType -- what `int | str` evaluates to (PEP 604).
;; types.py takes UnionType from `type(int | str)`.  Represented as a
;; GenericAlias-shaped record whose args are the operand tuple; the repr is
;; the pipe form rather than the bracket form.
;; ============================================================================
UTO_LIST  equ 8         ; the member list being accumulated
UTO_LEFT  equ 16
UTO_RIGHT equ 24
UTO_FRAME equ 32            ; + 4 pushes = 64, 16-aligned

DEF_FUNC union_type_or, UTO_FRAME
    ; nb_or(left, right) -> UnionType, for type | type
    push rbx
    push r12
    push r13
    push r14
    mov [rbp - UTO_LEFT], rdi
    mov [rbp - UTO_RIGHT], rsi

    ; both sides must be types (or an existing union, or None)
    call union_operand_ok       ; rdi = left
    test eax, eax
    jz .uto_notimpl
    mov rdi, [rbp - UTO_RIGHT]
    call union_operand_ok
    test eax, eax
    jz .uto_notimpl

    ; Collect the members.  This used to be a bare tuple_new(2) holding the two
    ; operands, so int | str | float nested as ((int|str), float): __args__ was
    ; not flat, and union_richcompare -- which compares the two arg tuples as
    ; sets -- read the inner union as one opaque member and answered False for
    ; (int|str|float) == (float|str|int).  The repr hid it, because a member
    ; that is not a type is printed with obj_repr, which re-enters union_repr.
    extern list_new
    xor edi, edi
    call list_new
    mov rbx, rax
    mov [rbp - UTO_LIST], rax

    mov rdi, [rbp - UTO_LEFT]
    call .uto_add_operand
    mov rdi, [rbp - UTO_RIGHT]
    call .uto_add_operand

    ; int | int is int: a union of one member is that member.
    cmp qword [rbx + PyListObject.ob_size], 1
    jne .uto_build
    mov rax, [rbx + PyListObject.ob_item]
    mov r12, [rax]
    INCREF_V r12, rcx
    mov rdi, rbx
    call obj_decref
    mov rax, r12
    mov edx, TAG_PTR
    jmp .uto_return

.uto_build:
    mov rdi, [rbx + PyListObject.ob_size]
    extern tuple_new
    call tuple_new
    mov r12, rax                ; the member tuple
    mov r13, [rbx + PyListObject.ob_item]
    mov r14, [r12 + PyTupleObject.ob_item]
    xor ecx, ecx
.uto_copy:
    cmp rcx, [rbx + PyListObject.ob_size]
    jge .uto_copied
    mov rax, [r13 + rcx * 8]
    mov [r14 + rcx * 8], rax
    push rcx
    INCREF_V rax, rcx
    pop rcx
    inc rcx
    jmp .uto_copy

.uto_copied:
    mov rdi, rbx
    call obj_decref             ; the accumulator; the tuple owns the members

    xor edi, edi                ; no origin
    mov rsi, r12
    call generic_alias_new
    lea rcx, [rel union_type]
    mov [rax + PyObject.ob_type], rcx
    push rax
    mov rdi, r12
    call obj_decref             ; generic_alias_new took its own ref
    pop rax
    mov edx, TAG_PTR

.uto_return:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.uto_notimpl:
    xor eax, eax
    xor edx, edx
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

;; .uto_add_operand(rdi = one operand Value) -- add what it contributes to the
;; list in rbx.  A union contributes its members; anything else contributes
;; itself.  Uses r13 and r14.
.uto_add_operand:
    ; None stands for NoneType inside a union, which is what makes
    ; (None | int) == (int | type(None)) true, as it is in CPython.
    lea rcx, [rel none_singleton]
    cmp rdi, rcx
    jne .uto_ao_typed
    extern none_type
    lea rdi, [rel none_type]
.uto_ao_typed:
    V_TEST_PTR rdi, rax
    ja .uto_ao_one
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel union_type]
    cmp rax, rcx
    jne .uto_ao_one

    mov r13, [rdi + PyGenericAliasObject.ga_args]
    xor r14d, r14d
.uto_ao_loop:
    cmp r14, [r13 + PyTupleObject.ob_size]
    jge .uto_ao_spliced
    mov rax, [r13 + PyTupleObject.ob_item]
    mov rdi, [rax + r14 * 8]
    call .uto_ao_one            ; already flat and already normalised
    inc r14
    jmp .uto_ao_loop
.uto_ao_spliced:
    ret

;; .uto_ao_one(rdi = one member) -- append it unless an equal one is there.
.uto_ao_one:
    push rdi
    mov rsi, rdi
    mov rdi, rbx
    extern list_contains
    call list_contains
    pop rdi
    test eax, eax
    jnz .uto_ao_one_done        ; int | int, and (int|str) | str
    mov rsi, rdi
    mov rdi, rbx
    extern list_append
    call list_append
.uto_ao_one_done:
    ret
END_FUNC union_type_or

;; ============================================================================
;; union_getattr(rdi = self, rsi = name) -> (rax = payload, rdx = tag)
;;
;; A union is a GenericAlias-shaped record, but it is not one: it has no
;; origin, so it cannot simply borrow generic_alias_getattr.  __args__ is the
;; half that matters -- typing and every annotation reader ask for it by name,
;; and union_type carried neither a tp_getattr nor a tp_dict, so it answered
;; AttributeError while the tuple sat in ga_args.
;; ============================================================================
DEF_FUNC union_getattr, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "__args__"
    call ap_strcmp
    test eax, eax
    jnz .ug_missing

    mov rax, [rbx + PyGenericAliasObject.ga_args]
    mov rdi, rax
    call obj_incref
    mov rax, [rbx + PyGenericAliasObject.ga_args]
    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.ug_missing:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
END_FUNC union_getattr

;; ============================================================================
;; union_operand_ok(rdi = a Value) -> eax = 1 when `|` may build a union of it
;;
;; CPython's is_unionable: a class, an existing union, a generic alias, or
;; None.  Two of the four were missing.  A class built by a metaclass of its
;; own is still a class, and asking whether its ob_type is one of the two
;; metatypes this tree ships answers no for it -- TYPE_FLAG_METATYPE is the
;; question that does not depend on which metatype made it.  And a generic
;; alias is what every modern annotation is written with: `list[int] | None`
;; is the shape, and `type Tree = int | list[Tree]` is the reason PEP 695's
;; lazy evaluation exists.
;; ============================================================================
DEF_FUNC_BARE union_operand_ok
    V_TEST_PTR rdi, rax
    ja .uok_no
    test rdi, rdi
    jz .uok_no
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jnz .uok_yes
    lea rcx, [rel union_type]
    cmp rax, rcx
    je .uok_yes
    ; A generic alias or any subclass of one -- collections.abc's
    ; _CallableGenericAlias is that -- as CPython's PyObject_TypeCheck asks.
    lea rcx, [rel generic_alias_type]
.uok_ga:
    cmp rax, rcx
    je .uok_yes
    mov rax, [rax + PyTypeObject.tp_base]
    test rax, rax
    jnz .uok_ga
    extern none_singleton
    lea rcx, [rel none_singleton]
    cmp rdi, rcx
    je .uok_yes
.uok_no:
    xor eax, eax
    ret
.uok_yes:
    mov eax, 1
    ret
END_FUNC union_operand_ok

;; ============================================================================
;; union_repr(rdi = a UnionType) -> rax = "int | str", a str
;; ============================================================================
UR_BUF   equ 264
UR_SELF  equ 272
UR_FRAME equ 296            ; + 5 pushes = 336, 16-aligned
DEF_FUNC union_repr, UR_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov [rbp - UR_SELF], rdi
    lea rbx, [rbp - UR_BUF]
    xor r13d, r13d
    mov rdi, [rdi + PyGenericAliasObject.ga_args]
    test rdi, rdi
    jz .ur_done
    mov r14, [rdi + PyTupleObject.ob_size]
    mov r15, [rdi + PyTupleObject.ob_item]
    xor r12d, r12d
.ur_loop:
    cmp r12, r14
    jge .ur_done
    test r12, r12
    jz .ur_no_sep
    cmp r13, UR_BUF - 16
    jae .ur_done
    mov byte [rbx + r13], ' '
    mov byte [rbx + r13 + 1], '|'
    mov byte [rbx + r13 + 2], ' '
    add r13, 3
.ur_no_sep:
    mov rdi, [r15 + r12*8]
    mov rsi, rbx
    mov rdx, r13
    call ga_emit_name
    mov r13, rax
    inc r12
    jmp .ur_loop
.ur_done:
    mov rdi, rbx
    mov rsi, r13
    call str_new_heap
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC union_repr


;; ============================================================================
;; union_hash(rdi = PyGenericAliasObject*) -> rax = hash
;; union_richcompare(rdi = left, rsi = right, edx = op) -> Value
;;
;; `hash(int | str)` used to raise: builtin_hash_fn raises when tp_hash is 0,
;; and copyreg.py hashes `type(int | str)` two lines after the complex one, so
;; the whole module -- and everything that imports it -- stopped there.
;;
;; CPython hashes a union as `hash(frozenset(args))` and compares them as
;; frozensets.  frozenset_type.tp_hash is 0 here, so instead the args are
;; combined with XOR, which induces exactly the same equivalence: order does
;; not matter and a repeat is absorbed, so `int | str` and `str | int` hash
;; alike.  The values differ from CPython's; nothing observes them, and the
;; language only requires that equal objects hash equal.
;; ============================================================================
UH_FRAME equ 16             ; + 2 pushes = 32
DEF_FUNC union_hash, UH_FRAME
    push rbx
    push r12
    mov rax, [rdi + PyGenericAliasObject.ga_args]
    test rax, rax
    jz .uh_empty
    mov r12, [rax + PyTupleObject.ob_size]
    mov rbx, [rax + PyTupleObject.ob_item]
    xor eax, eax
    test r12, r12
    jz .uh_done
    push rax
    xor ecx, ecx
.uh_loop:
    push rcx
    mov rdi, [rbx + rcx*8]
    extern obj_hash
    call obj_hash
    pop rcx
    pop rdx
    xor rdx, rax
    push rdx
    inc rcx
    cmp rcx, r12
    jb .uh_loop
    pop rax
.uh_done:
    ; A light avalanche, so that two unions differing only in one member do
    ; not collide merely because XOR preserves low bits.
    mov rdx, rax
    shr rdx, 32
    imul rdx, rdx, 1000003
    xor rax, rdx
    cmp rax, -1
    jne .uh_ret
    mov rax, -2
.uh_ret:
    pop r12
    pop rbx
    leave
    ret
.uh_empty:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC union_hash

;; ============================================================================
;; union_richcompare(rdi = left, rsi = right, edx = the operator,
;;                   rcx/r8 = their tags) -> (rax, edx) = True, False, or a
;;   NULL Value for an operator a union does not answer
;;
;; Two unions are equal when they hold the same members, whatever the order:
;; `int | str == str | int`.
;; ============================================================================
URC_LEFT  equ 8
URC_RIGHT equ 16
URC_OP    equ 24
URC_FRAME equ 32             ; + 2 pushes = 48
DEF_FUNC union_richcompare, URC_FRAME
    push rbx
    push r12
    cmp edx, PY_EQ
    je .ur_ok
    cmp edx, PY_NE
    jne .ur_decline
.ur_ok:
    mov [rbp - URC_OP], edx
    ; Both sides must be unions; anything else declines so the protocol can
    ; try the other operand.
    V_TEST_PTR rdi, rax
    ja .ur_decline
    V_TEST_PTR rsi, rax
    ja .ur_decline
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel union_type]
    cmp rax, rcx
    jne .ur_decline
    mov rax, [rsi + PyObject.ob_type]
    cmp rax, rcx
    jne .ur_decline
    mov [rbp - URC_LEFT], rdi
    mov [rbp - URC_RIGHT], rsi

    ; Set equality: every member of each side is present in the other.
    mov rdi, [rbp - URC_LEFT]
    mov rsi, [rbp - URC_RIGHT]
    call union_args_subset
    test eax, eax
    jz .ur_false
    mov rdi, [rbp - URC_RIGHT]
    mov rsi, [rbp - URC_LEFT]
    call union_args_subset
    test eax, eax
    jz .ur_false
.ur_true:
    cmp dword [rbp - URC_OP], PY_EQ
    je .ur_ret_true
    jmp .ur_ret_false
.ur_false:
    cmp dword [rbp - URC_OP], PY_EQ
    je .ur_ret_false
.ur_ret_true:
    extern bool_true
    lea rax, [rel bool_true]
    pop r12
    pop rbx
    leave
    ret
.ur_ret_false:
    extern bool_false
    lea rax, [rel bool_false]
    pop r12
    pop rbx
    leave
    ret
.ur_decline:
    xor eax, eax                    ; NULL Value = NotImplemented
    pop r12
    pop rbx
    leave
    ret
END_FUNC union_richcompare

;; ============================================================================
;; union_args_subset(rdi = a, rsi = b) -> eax = 1 when every member of a's
;; args tuple is also in b's.  Members are compared with
;; obj_richcompare_bool, not by pointer: union_operand_ok admits None and
;; nested unions as well as types.
;; ============================================================================
UAS_BITEMS equ 8
UAS_BSIZE  equ 16
UAS_AITEMS equ 24
UAS_ASIZE  equ 32
UAS_I      equ 40
UAS_FRAME  equ 48           ; + 0 pushes = 48
DEF_FUNC_LOCAL union_args_subset, UAS_FRAME
    mov rax, [rdi + PyGenericAliasObject.ga_args]
    test rax, rax
    jz .uas_yes
    mov rcx, [rax + PyTupleObject.ob_size]
    mov [rbp - UAS_ASIZE], rcx
    mov rcx, [rax + PyTupleObject.ob_item]
    mov [rbp - UAS_AITEMS], rcx
    mov rax, [rsi + PyGenericAliasObject.ga_args]
    test rax, rax
    jz .uas_no
    mov rcx, [rax + PyTupleObject.ob_size]
    mov [rbp - UAS_BSIZE], rcx
    mov rcx, [rax + PyTupleObject.ob_item]
    mov [rbp - UAS_BITEMS], rcx
    mov qword [rbp - UAS_I], 0
.uas_outer:
    mov rax, [rbp - UAS_I]
    cmp rax, [rbp - UAS_ASIZE]
    jae .uas_yes
    xor ecx, ecx
.uas_inner:
    cmp rcx, [rbp - UAS_BSIZE]
    jae .uas_no
    push rcx
    mov rax, [rbp - UAS_AITEMS]
    mov r8, [rbp - UAS_I]
    mov rdi, [rax + r8*8]
    mov rax, [rbp - UAS_BITEMS]
    mov rsi, [rax + rcx*8]
    mov edx, PY_EQ
    extern obj_richcompare_bool
    call obj_richcompare_bool
    pop rcx
    ; -1 is "the comparison raised".  There is no way to report that through
    ; tp_richcompare here -- a NULL Value means NotImplemented, not failure --
    ; but the scan must at least stop, or the next comparison runs more Python
    ; over the top of the pending exception.
    test eax, eax
    jl .uas_no
    cmp eax, 1
    je .uas_found
    inc rcx
    jmp .uas_inner
.uas_found:
    inc qword [rbp - UAS_I]
    jmp .uas_outer
.uas_yes:
    mov eax, 1
    leave
    ret
.uas_no:
    xor eax, eax
    leave
    ret
END_FUNC union_args_subset
