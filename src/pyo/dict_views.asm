; pyo/dict_views.asm - dict.keys(), dict.values(), dict.items()
;
; Split out of pyo/dict.asm, which reached the 100k cap the tree holds
; hand-written files to.  The seam is the obvious one: this file is the three
; VIEW types and everything only they do -- construction, len, iteration,
; repr, `in`, the four set operators and the set-like comparison -- and
; pyo/dict.asm is the TABLE.  Nothing here knows how a key is probed for; it
; asks dict_get and dict_contains like any other caller.
;
; A view is a two-word object over a borrowed-then-INCREF'd dict and a kind
; (0 keys, 1 values, 2 items).  It holds no snapshot: everything reads the
; dict as it is now, which is what makes a view a view rather than a list.
;
; The three are not interchangeable.  keys and items are SET-LIKE and values
; is not, which is CPython's rule and is why the values type carries no
; tp_richcompare and no sq_contains: two values views compare by identity,
; and `x in d.values()` is a walk.  keys gets sq_contains straight from the
; dict; items gets one that looks the key up and compares the value.

%include "macros.inc"
%include "object.inc"
%include "value.inc"
%include "opcodes.inc"

extern dict_type
extern dict_get
extern dict_contains
extern dict_iter_type
extern dict_value_iter_type
extern dict_item_iter_type
extern dict_iter_next
extern set_type
extern frozenset_type
extern set_type_call
extern obj_binary_op
extern obj_richcompare_bool
extern obj_decref
extern obj_dealloc
extern type_type
extern obj_incref
extern eval_exception_unwind
extern get_iterator
extern call_iternext
extern gc_alloc
extern gc_track
extern gc_dealloc
extern iter_traverse_one
extern iter_clear_one
extern bool_true
extern bool_false
extern tuple_type
extern str_type
extern list_new
extern list_append
extern list_type
extern obj_repr
extern str_from_cstr_heap
extern ap_malloc
extern ap_free
extern ap_memcpy

section .text

;; ============================================================================
;; Dict View Objects
;; dict.keys(), dict.values(), dict.items() return view objects.
;; Views hold a reference to the dict and support iteration + len().
;; ============================================================================

;; ============================================================================
;; dict_view_new(rdi=dict, rsi=kind, rdx=type_ptr) -> PyDictViewObject*
;; Create a new dict view. kind: 0=keys, 1=values, 2=items
;; ============================================================================
DEF_FUNC dict_view_new, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    mov rbx, rdi               ; dict
    mov r12, rsi               ; kind
    mov r13, rdx               ; view type

    mov edi, PyDictViewObject_size
    mov rsi, r13
    call gc_alloc

    mov [rax + PyDictViewObject.dv_dict], rbx
    mov [rax + PyDictViewObject.dv_kind], r12

    ; INCREF dict
    push rax
    mov rdi, rbx
    call obj_incref
    pop rax
    push rax
    mov rdi, rax
    call gc_track
    pop rax

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_view_new

;; ============================================================================
;; dict_view_dealloc(rdi = the view) -> void
;;
;; A view owns exactly one thing: the reference it took to the dict.
;; ============================================================================
DEF_FUNC_LOCAL dict_view_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; DECREF dict
    mov rdi, [rbx + PyDictViewObject.dv_dict]
    call obj_decref

    ; Free self
    mov rdi, rbx
    call gc_dealloc

    pop rbx
    leave
    ret
END_FUNC dict_view_dealloc

;; ============================================================================
;; dict_view_len(rdi=view) -> i64
;; Returns the number of items in the underlying dict.
;; ============================================================================
DEF_FUNC_BARE dict_view_len
    mov rax, [rdi + PyDictViewObject.dv_dict]
    mov rax, [rax + PyDictObject.ob_size]
    ret
END_FUNC dict_view_len

;; ============================================================================
;; dict_view_iter(rdi=view) -> PyDictIterObject*
;; Create an iterator for this view, using the view's kind.
;; ============================================================================
DEF_FUNC dict_view_iter
    push rbx
    push r12

    mov rbx, rdi               ; view

    mov edi, PyDictIterObject_size
    lea rsi, [rel dict_iter_type]
    call gc_alloc

    mov rdi, [rbx + PyDictViewObject.dv_dict]
    mov [rax + PyDictIterObject.it_dict], rdi
    mov qword [rax + PyDictIterObject.it_index], 0
    mov rcx, [rbx + PyDictViewObject.dv_kind]
    mov [rax + PyDictIterObject.it_kind], rcx
    ; The three kinds are three types, differing only in the name they report.
    lea rdx, [rel dict_value_iter_type]
    cmp rcx, 1
    je .dvi_named
    lea rdx, [rel dict_item_iter_type]
    cmp rcx, 2
    je .dvi_named
    jmp .dvi_kind_done
.dvi_named:
    mov [rax + PyObject.ob_type], rdx
.dvi_kind_done:
    ; The SIZE, not the version: see dict_tp_iter.
    mov rcx, [rdi + PyDictObject.ob_size]
    mov [rax + PyDictIterObject.it_version], rcx

    ; INCREF dict
    push rax                    ; save iterator
    call obj_incref
    pop rax                     ; restore iterator
    push rax
    mov rdi, rax
    call gc_track
    pop rax

    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_view_iter

;; ============================================================================
;; dict_view_repr(rdi = the view) -> rax = PyStrObject*, edx = TAG_PTR
;;
;; "dict_keys(['a'])", and the same for values and items.  The three view
;; types had tp_repr 0, and obj_repr answers a NULL Value for that with no
;; exception -- so print(d.keys()) printed nothing at all.
;;
;; The text is the type's own name around the repr of a list of the view's
;; contents, which is exactly what CPython writes, and lets list_repr do the
;; work including its recursion guard.
;; ============================================================================
DVR_VIEW  equ 8
DVR_LIST  equ 16
DVR_TEXT  equ 24
DVR_FRAME equ 32            ; + 2 pushes = 48, 16-aligned

extern obj_repr
DEF_FUNC dict_view_repr, DVR_FRAME
    push rbx
    push r12
    mov [rbp - DVR_VIEW], rdi

    ; The same cycle stack list and tuple use.  A view can reach itself --
    ; d['k'] = d.values() -- and without this the repr recursed until the
    ; depth limit where CPython prints dict_values([...]).
    extern repr_check_active
    extern repr_push
    extern repr_pop
    call repr_check_active
    test eax, eax
    jnz .dvr_recursive
    mov rdi, [rbp - DVR_VIEW]
    call repr_push

    xor edi, edi
    extern list_new
    call list_new
    mov [rbp - DVR_LIST], rax
    mov rbx, rax

    mov rdi, [rbp - DVR_VIEW]
    call dict_view_iter
    mov r12, rax
.dvr_loop:
    mov rdi, r12
    call dict_iter_next
    V_UNPACK rax, rdx
    test edx, edx
    jz .dvr_done
    push rax
    push rdx
    mov rdi, rbx
    mov rsi, rax
    V_PACK rsi, rdx
    extern list_append
    call list_append
    pop rdx
    pop rax
    ; dict_iter_next hands back an OWNED reference and list_append takes its
    ; own, so without this every element leaked -- and for an items view the
    ; leaked object is a freshly built tuple, so a loop grew without bound.
    mov rdi, rax
    mov rsi, rdx
    DECREF_VAL rdi, rsi
    jmp .dvr_loop
.dvr_done:
    mov rdi, r12
    call obj_decref

    mov rdi, rbx
    call obj_repr
    V_UNPACK rax, rdx
    mov [rbp - DVR_TEXT], rax
    mov rdi, rbx
    call obj_decref
    ; After the nested reprs, not before them: they are what the guard is
    ; for, and they all happen inside that obj_repr.
    mov rdi, [rbp - DVR_VIEW]
    call repr_pop
    mov rax, [rbp - DVR_TEXT]
    test rax, rax
    jz .dvr_failed

.dvr_wrap:
    ; "<name>(" + that + ")"
    mov rdi, [rbp - DVR_VIEW]
    mov rdi, [rdi + PyObject.ob_type]
    mov rbx, [rdi + PyTypeObject.tp_name]
    xor ecx, ecx
.dvr_namelen:
    cmp byte [rbx + rcx], 0
    je .dvr_have_namelen
    inc rcx
    jmp .dvr_namelen
.dvr_have_namelen:
    mov r12, rcx                        ; the name's length
    mov rax, [rbp - DVR_TEXT]
    mov rdx, [rax + PyStrObject.ob_size]
    lea rdi, [r12 + rdx]
    add rdi, PyStrObject.data + 10      ; two brackets, a NUL and slack
    extern ap_malloc
    call ap_malloc
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel str_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyStrObject.ob_hash], -1
    push rax

    lea rdi, [rax + PyStrObject.data]
    mov rsi, rbx
    mov rdx, r12
    extern ap_memcpy
    call ap_memcpy
    mov rax, [rsp]
    mov byte [rax + PyStrObject.data + r12], '('
    lea rdi, [rax + PyStrObject.data + r12 + 1]
    mov rcx, [rbp - DVR_TEXT]
    lea rsi, [rcx + PyStrObject.data]
    mov rdx, [rcx + PyStrObject.ob_size]
    call ap_memcpy
    mov rax, [rsp]
    mov rcx, [rbp - DVR_TEXT]
    mov rdx, [rcx + PyStrObject.ob_size]
    lea rcx, [r12 + rdx]
    mov byte [rax + PyStrObject.data + rcx + 1], ')'
    mov byte [rax + PyStrObject.data + rcx + 2], 0
    add rcx, 2
    mov [rax + PyStrObject.ob_size], rcx
    mov rdi, rax
    extern str_set_length
    call str_set_length

    mov rdi, [rbp - DVR_TEXT]
    call obj_decref
    pop rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.dvr_failed:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret

.dvr_recursive:
    ; A bare ellipsis, NOT the name wrapper: CPython's dictview_repr returns
    ; "..." on its own here, and the enclosing level supplies the name.  It
    ; is what makes d['k'] = d.values() print
    ; dict_values([dict_values([...])]) rather than one level deeper.
    CSTRING rdi, "..."
    extern str_from_cstr_heap
    call str_from_cstr_heap
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_view_repr

;; ============================================================================
;; dict_keys_view_contains(rdi = view, rsi = key Value) -> eax = 0 or 1
;;
;; `k in d.keys()` is `k in d`, so this is a tail jump and nothing else.
;; ============================================================================
DEF_FUNC_BARE dict_keys_view_contains
    mov rdi, [rdi + PyDictViewObject.dv_dict]
    jmp dict_contains           ; (rdi=dict, rsi=key Value)
END_FUNC dict_keys_view_contains

;; ============================================================================
;; dict_items_view_contains(rdi = view, rsi = probe Value) -> eax = 0 or 1
;;
;; `(k, v) in d.items()` is one lookup and one comparison, not a walk.  The
;; items view had no sq_contains at all, so the question fell to the generic
;; protocol, which iterates the whole view and compares every pair -- O(n)
;; where CPython's dictitems_contains is O(1), and measured at a hundred
;; times CPython on tests/run_dict_bench.sh.
;;
;; A probe that is not a two-element tuple is simply not in the view; CPython
;; answers False rather than raising, and it accepts a tuple SUBCLASS, whose
;; __eq__ the comparison below still gets to run.
;;
;; The dict's value is compared on the LEFT, as in CPython: the pair's own
;; second element is the right operand, so a probe carrying a type with an
;; __eq__ is offered the reflected operand by the ordinary rule rather than
;; being asked first.
;; ============================================================================
DEF_FUNC dict_items_view_contains, 8    ; + 1 push = 16, 16-aligned
    push rbx

    V_TEST_PTR rsi, rax
    ja .divc_no
    mov rax, [rsi + PyObject.ob_type]
    REQUIRE_TUPLE_TYPE rax, rcx, .divc_no
    cmp qword [rsi + PyTupleObject.ob_size], 2
    jne .divc_no

    mov rbx, rsi                        ; the pair, held across the lookup
    mov rdi, [rdi + PyDictViewObject.dv_dict]
    mov rax, [rbx + PyTupleObject.ob_item]
    mov rsi, [rax]                      ; the key
    call dict_get                       ; a borrowed Value, or 0
    test rax, rax
    jz .divc_no

    ; The borrow is safe across the comparison: obj_richcompare_bool takes a
    ; reference to both operands before it can run any Python.
    mov rdi, rax
    mov rax, [rbx + PyTupleObject.ob_item]
    mov rsi, [rax + 8]                  ; the value the pair carries
    mov edx, PY_EQ
    call obj_richcompare_bool
    cmp eax, -1
    je .divc_error
    pop rbx
    leave
    ret

.divc_no:
    xor eax, eax
    pop rbx
    leave
    ret

.divc_error:
    ; sq_contains has no error channel; the exception is already pending.
    pop rbx
    leave
    jmp eval_exception_unwind
END_FUNC dict_items_view_contains

;; ============================================================================
;; dict_view_to_set(rdi = a Value) -> rax = a set Value, owned, or 0
;;
;; Both operands of a view's set operations become sets first.  A set or a
;; frozenset is kept as it is; anything else is built into one, which is
;; what makes `d.keys() - ["a"]` work where `{"a"} - ["a"]` does not: a
;; view's operators take any iterable, as CPython's do.
;; ============================================================================
DVS_ARG   equ 8
DVS_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL dict_view_to_set, DVS_FRAME
    mov [rbp - DVS_ARG], rdi
    V_TEST_PTR rdi, rax
    ja .dvs_build
    test rdi, rdi
    jz .dvs_build
    mov rax, [rdi + PyObject.ob_type]
    extern set_type
    lea rcx, [rel set_type]
    cmp rax, rcx
    je .dvs_keep
    extern frozenset_type
    lea rcx, [rel frozenset_type]
    cmp rax, rcx
    jne .dvs_build
.dvs_keep:
    mov rax, [rbp - DVS_ARG]
    INCREF_V rax, rcx
    leave
    ret
.dvs_build:
    lea rsi, [rbp - DVS_ARG]
    lea rdi, [rel set_type]
    mov edx, 1
    extern set_type_call
    call set_type_call
    V_UNPACK rax, rdx
    leave
    ret
END_FUNC dict_view_to_set

;; ============================================================================
;; dict_view_binop(rdi = left Value, rsi = right Value, edx = op index)
;;   -> rax = Value, or 0 with an exception pending
;;
;; A view is set-like, and CPython gives it the four set operators.  Both
;; sides become sets and the set's own slot does the work.
;; ============================================================================
DVB_OP    equ 8
DVB_LEFT  equ 16
DVB_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL dict_view_binop, DVB_FRAME
    mov [rbp - DVB_OP], rdx
    push rsi
    push rsi
    call dict_view_to_set
    pop rsi
    pop rsi
    test rax, rax
    jz .dvb_fail
    mov [rbp - DVB_LEFT], rax
    mov rdi, rsi
    call dict_view_to_set
    test rax, rax
    jz .dvb_fail_left
    mov rsi, rax
    mov rdi, [rbp - DVB_LEFT]
    mov edx, [rbp - DVB_OP]
    extern obj_binary_op
    call obj_binary_op          ; consumes both
    leave
    ret
.dvb_fail_left:
    mov rdi, [rbp - DVB_LEFT]
    DECREF_V rdi, rcx
.dvb_fail:
    xor eax, eax
    leave
    ret
END_FUNC dict_view_binop

%macro DEF_VIEW_BINOP 2
;; ============================================================================
;; dict_view_<op>(rdi = left Value, rsi = right Value) -> rax = Value, or 0
;; One of the four set operators, named for the slot it fills.
;; ============================================================================
DEF_FUNC_LOCAL dict_view_%1, 8      ; + 0 pushes = 16, 16-aligned
    mov edx, %2
    call dict_view_binop
    leave
    ret
END_FUNC dict_view_%1
%endmacro

;; The four, each naming the set slot it ends up in.
DEF_VIEW_BINOP nb_sub, NB_SUBTRACT
DEF_VIEW_BINOP nb_and, NB_AND
DEF_VIEW_BINOP nb_or,  NB_OR
DEF_VIEW_BINOP nb_xor, NB_XOR

;; ============================================================================
;; dvr_len(rdi = a set, a frozenset or a keys/items view) -> rax = its length
;; ============================================================================
DEF_FUNC_BARE dvr_len
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    mov rax, [rax + PySequenceMethods.sq_length]
    jmp rax
END_FUNC dvr_len

;; ============================================================================
;; dvr_all_contained_in(rdi = a, rsi = b) -> eax = 1 when every element of a
;;   is in b, 0 when one is not, -1 with an exception pending
;;
;; CPython's all_contained_in: walk a with the ordinary iterator protocol and
;; ask b's sq_contains about each element.  Nothing is hashed that b does not
;; hash itself, which is the whole point -- an items view's VALUES need not be
;; hashable, and building a set of them is what used to raise on them.
;; ============================================================================
DAC_B     equ 8
DAC_EXC   equ 16
DAC_FRAME equ 40                ; + 3 pushes = 64, 16-aligned
DEF_FUNC_LOCAL dvr_all_contained_in, DAC_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - DAC_B], rsi
    DUNDER_EXC_SAVE [rbp - DAC_EXC]

    mov esi, TAG_PTR            ; a is always a set or a view, so a pointer
    extern get_iterator
    call get_iterator
    test rax, rax
    jz .dac_error
    mov r12, rax

.dac_loop:
    mov rdi, r12
    extern call_iternext
    call call_iternext
    test rax, rax
    jz .dac_exhausted
    mov rbx, rax                ; the element, owned

    mov rdi, [rbp - DAC_B]
    mov rsi, rbx
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    mov rax, [rax + PySequenceMethods.sq_contains]
    call rax                    ; sq_contains unwinds rather than reporting
    mov r13d, eax
    mov rdi, rbx
    DECREF_V rdi, rcx
    test r13d, r13d
    jnz .dac_loop

    mov rdi, r12
    call obj_decref
    xor eax, eax
    jmp .dac_out

.dac_exhausted:
    ; call_iternext answers NULL for a clean exhaustion and for a __next__
    ; that raised anything but StopIteration, which it leaves pending.
    mov rdi, r12
    call obj_decref
    EXC_RAISED_SINCE [rbp - DAC_EXC], rcx, .dac_error
    mov eax, 1
    jmp .dac_out
.dac_error:
    mov eax, -1
.dac_out:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dvr_all_contained_in

;; ============================================================================
;; dict_view_richcompare(rdi = self, rsi = other, edx = op) -> rax = Value
;;
;; A view compares as the set of what it holds, which is how `d.keys() ==
;; {"a"}` is True.  Only against something set-like: a view compared with a
;; list is unequal rather than an error.
;;
;; The comparison is CPython's dictview_richcompare -- lengths first, then
;; containment one element at a time.  It used to build a SET out of each
;; side and compare those, which is wrong twice over:
;;
;;   - an items view's values need not be hashable, and hashing them is not
;;     part of the question.  `{"k": [1]}.items() == {"k": [1]}.items()` is
;;     True in CPython and raised TypeError here, and so did every ordering
;;     operator, and so did a comparison whose LENGTHS already settled it.
;;   - a VALUES view is not set-like at all.  CPython gives it no
;;     tp_richcompare, so two of them compare by identity and
;;     `{1: 2}.values() == {1: 2}.values()` is False; here it was True, and
;;     `{1: 2}.values() == {2}` was True as well.  The values view's slot is
;;     now 0 and this function refuses one as the right operand.
;;
;; Lengths first is not only an optimisation: for the ordering operators a
;; size mismatch settles the answer with no containment check at all, which
;; is why an unhashable value cannot get in the way of `a.items() == {}`.
;; ============================================================================
DVC_OP     equ 8
DVC_SELF   equ 16
DVC_OTHER  equ 24
DVC_LSELF  equ 32
DVC_LOTHER equ 40
DVC_FRAME  equ 48           ; + 0 pushes = 48, 16-aligned
DEF_FUNC_LOCAL dict_view_richcompare, DVC_FRAME
    mov [rbp - DVC_OP], rdx
    mov [rbp - DVC_SELF], rdi
    mov [rbp - DVC_OTHER], rsi

    ; The other side has to be set-like: a set, a frozenset, or a KEYS or
    ; ITEMS view.  Anything else -- a values view included -- is
    ; NotImplemented, which for == falls back to identity.
    V_TEST_PTR rsi, rax
    ja .dvc_notimpl
    test rsi, rsi
    jz .dvc_notimpl
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel set_type]
    cmp rax, rcx
    je .dvc_ok
    lea rcx, [rel frozenset_type]
    cmp rax, rcx
    je .dvc_ok
    lea rcx, [rel dict_keys_view_type]
    cmp rax, rcx
    je .dvc_ok
    lea rcx, [rel dict_items_view_type]
    cmp rax, rcx
    jne .dvc_notimpl
.dvc_ok:
    mov rdi, [rbp - DVC_SELF]
    call dvr_len
    mov [rbp - DVC_LSELF], rax
    mov rdi, [rbp - DVC_OTHER]
    call dvr_len
    mov [rbp - DVC_LOTHER], rax

    mov rax, [rbp - DVC_LSELF]
    mov rcx, [rbp - DVC_LOTHER]
    mov edx, [rbp - DVC_OP]
    cmp edx, PY_EQ
    je .dvc_eq
    cmp edx, PY_NE
    je .dvc_eq
    cmp edx, PY_LT
    je .dvc_lt
    cmp edx, PY_LE
    je .dvc_le
    cmp edx, PY_GT
    je .dvc_gt

    cmp rax, rcx                ; PY_GE: self >= other
    jb .dvc_false
    jmp .dvc_swapped
.dvc_gt:
    cmp rax, rcx
    jbe .dvc_false
.dvc_swapped:
    ; A superset question is the subset question with the operands the other
    ; way round.
    mov rdi, [rbp - DVC_OTHER]
    mov rsi, [rbp - DVC_SELF]
    jmp .dvc_contained
.dvc_lt:
    cmp rax, rcx
    jae .dvc_false
    jmp .dvc_forward
.dvc_le:
    cmp rax, rcx
    ja .dvc_false
    jmp .dvc_forward
.dvc_eq:
    cmp rax, rcx
    jne .dvc_len_differs
.dvc_forward:
    mov rdi, [rbp - DVC_SELF]
    mov rsi, [rbp - DVC_OTHER]
.dvc_contained:
    call dvr_all_contained_in
    cmp eax, -1
    je .dvc_fail
    jmp .dvc_have
.dvc_len_differs:
    xor eax, eax                ; == over different sizes, without looking
.dvc_have:
    cmp dword [rbp - DVC_OP], PY_NE
    jne .dvc_bool
    xor eax, 1
.dvc_bool:
    test eax, eax
    jz .dvc_false
    lea rax, [rel bool_true]
    jmp .dvc_answer
.dvc_false:
    lea rax, [rel bool_false]
.dvc_answer:
    inc qword [rax + PyObject.ob_refcnt]
    leave
    ret
.dvc_fail:
    xor eax, eax
    leave
    ret
.dvc_notimpl:
    xor eax, eax
    leave
    ret
END_FUNC dict_view_richcompare

section .data

dict_keys_view_name: db "dict_keys", 0
dict_values_view_name: db "dict_values", 0
dict_items_view_name: db "dict_items", 0

; Dict keys view sequence methods (len + contains)
align 8
dict_keys_view_seq_methods:
    dq dict_view_len            ; sq_length
    dq 0                        ; sq_concat
    dq 0                        ; sq_repeat
    dq 0                        ; sq_item
    dq 0                        ; sq_ass_item
    dq dict_keys_view_contains  ; sq_contains
    dq 0                        ; sq_inplace_concat
    dq 0                        ; sq_inplace_repeat

; The number methods every view shares: the four set operators.
align 8
dict_view_num_methods:
    dq 0                    ; nb_add
    dq dict_view_nb_sub     ; nb_subtract
    dq 0                    ; nb_multiply
    dq 0                    ; nb_remainder
    dq 0                    ; nb_divmod
    dq 0                    ; nb_power
    dq 0                    ; nb_negative
    dq 0                    ; nb_positive
    dq 0                    ; nb_absolute
    dq 0                    ; nb_bool
    dq 0                    ; nb_invert
    dq 0                    ; nb_lshift
    dq 0                    ; nb_rshift
    dq dict_view_nb_and     ; nb_and
    dq dict_view_nb_xor     ; nb_xor
    dq dict_view_nb_or      ; nb_or
    times PyNumberMethods_size / 8 - 16 dq 0

; Dict values view sequence methods.  No sq_contains, as in CPython:
; `x in d.values()` is a walk there too, and a direct scan here would answer
; without noticing a mutation that the iteration protocol raises on.
align 8
dict_view_sequence_methods:
    dq dict_view_len            ; sq_length
    dq 0                        ; sq_concat
    dq 0                        ; sq_repeat
    dq 0                        ; sq_item
    dq 0                        ; sq_ass_item
    dq 0                        ; sq_contains
    dq 0                        ; sq_inplace_concat
    dq 0                        ; sq_inplace_repeat

; Dict items view sequence methods (len + contains)
align 8
dict_items_view_seq_methods:
    dq dict_view_len            ; sq_length
    dq 0                        ; sq_concat
    dq 0                        ; sq_repeat
    dq 0                        ; sq_item
    dq 0                        ; sq_ass_item
    dq dict_items_view_contains ; sq_contains
    dq 0                        ; sq_inplace_concat
    dq 0                        ; sq_inplace_repeat

; Dict keys view type
section .text

;; ============================================================================
;; dict_view_reversed(rdi = args Value[], rsi = nargs) -> rax = a reverse
;; iterator over this view, as a Value
;;
;; `reversed(d.keys())` was "'dict_keys' object is not reversible": the dict
;; itself had a __reversed__ and its three views had none, though the iterator
;; type already carries the kind that tells keys from values from items.  So
;; this is dict_reversed with the view's own dv_kind rather than a hardcoded
;; zero, which is exactly what CPython's dictview_reversed does.
;; ============================================================================
DVREV_FRAME equ 24          ; + 1 push = 32, 16-aligned
DEF_FUNC dict_view_reversed, DVREV_FRAME
    push rbx
    test rsi, rsi
    jz .dvr_args
    mov rbx, [rdi]                  ; the view

    mov rdi, [rbx + PyDictViewObject.dv_dict]
    test rdi, rdi
    jz .dvr_args
    push rdi
    push rdi
    mov edi, PyDictIterObject_size
    extern dict_rev_iter_type
    lea rsi, [rel dict_rev_iter_type]
    extern gc_alloc
    call gc_alloc
    pop rdi
    pop rdi                         ; rdi = the dict again

    mov [rax + PyDictIterObject.it_dict], rdi
    ; From the end, as dict_reversed does: the scan walks the entry array down.
    mov rcx, [rdi + PyDictObject.capacity]
    dec rcx
    mov [rax + PyDictIterObject.it_index], rcx
    mov rcx, [rbx + PyDictViewObject.dv_kind]
    mov [rax + PyDictIterObject.it_kind], rcx
    ; The SIZE, for mutation detection -- see dict_reversed on why not
    ; dk_version.
    mov rcx, [rdi + PyDictObject.ob_size]
    mov [rax + PyDictIterObject.it_version], rcx

    push rax
    push rax
    extern obj_incref
    call obj_incref                 ; the iterator holds the dict
    pop rax
    pop rax
    push rax
    push rax
    mov rdi, rax
    extern gc_track
    call gc_track
    pop rax
    pop rax

    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.dvr_args:
    extern exc_TypeError_type
    extern raise_exception
    RAISE exc_TypeError_type, "__reversed__() takes exactly one argument"
END_FUNC dict_view_reversed

section .text

;; ============================================================================
;; dict_view_get_mapping(rdi = the view as a Value) -> rax = Value
;;
;; `d.keys().mapping`: a read-only proxy onto the dict the view came from.
;; CPython added it in 3.10 so that a view can be used where a mapping is
;; wanted without handing out the mutable original, and `collections.abc`'s
;; own registration tests read it.
;; ============================================================================
DEF_FUNC dict_view_get_mapping
    mov rdi, [rdi + PyDictViewObject.dv_dict]
    test rdi, rdi
    jz .dvgm_none
    extern mappingproxy_new
    call mappingproxy_new
    mov edx, TAG_PTR
    leave
    ret
.dvgm_none:
    extern none_singleton
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    ret
END_FUNC dict_view_get_mapping

;; ============================================================================
;; dict_view_isdisjoint(rdi = args Value[], rsi = nargs) -> rax = a bool Value
;;
;; `d.keys().isdisjoint(other)`, for the two views that are set-like.  CPython
;; takes any iterable, not just a set, and walks it asking the view whether it
;; holds each item -- which is a dict lookup for a keys view and a key-and-value
;; comparison for an items view.  Both are already written as sq_contains, so
;; this is the walk and nothing else.
;; ============================================================================
DVJ_SELF  equ 8
DVJ_ITER  equ 16
DVJ_FRAME equ 24            ; + 1 push = 32, 16-aligned
global dict_view_isdisjoint
DEF_FUNC dict_view_isdisjoint, DVJ_FRAME
    push rbx
    cmp rsi, 2
    jne .dvj_args
    mov rax, [rdi]
    mov [rbp - DVJ_SELF], rax
    mov rdi, [rdi + 8]

    ; get_iterator and call_iternext still speak the old (payload, tag) pair.
    V_UNPACK rdi, rsi
    extern get_iterator
    call get_iterator
    test rax, rax
    jz .dvj_raised
    mov [rbp - DVJ_ITER], rax

.dvj_loop:
    mov rdi, [rbp - DVJ_ITER]
    extern call_iternext
    call call_iternext
    test rax, rax
    jz .dvj_exhausted
    V_PACK rax, rdx
    mov rbx, rax                        ; the item, ours

    ; sq_contains on the view's own type, which is what `x in view` calls.
    mov rdi, [rbp - DVJ_SELF]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .dvj_item_done
    mov rax, [rax + PySequenceMethods.sq_contains]
    test rax, rax
    jz .dvj_item_done
    mov rdi, [rbp - DVJ_SELF]
    mov rsi, rbx
    call rax
    push rax
    push rax
    mov rdi, rbx
    DECREF_V rdi, rcx
    pop rax
    pop rcx
    test eax, eax
    jnz .dvj_false
    ; sq_contains has no error channel -- an unhashable probe answers 0 with
    ; the exception already pending -- so the pending one is what says whether
    ; the 0 meant "no" or "it raised".
    cmp qword [gs:ThreadState.current_exception], 0
    jne .dvj_raised_iter
    jmp .dvj_loop

.dvj_item_done:
    mov rdi, rbx
    DECREF_V rdi, rcx
    jmp .dvj_loop

.dvj_exhausted:
    ; call_iternext answers 0 both for exhaustion and for a raise; the
    ; pending exception is what tells them apart.
    cmp qword [gs:ThreadState.current_exception], 0
    jne .dvj_raised_iter
    mov rdi, [rbp - DVJ_ITER]
    DECREF_V rdi, rcx
    extern bool_true
    lea rax, [rel bool_true]
    INCREF rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.dvj_false:
    mov rdi, [rbp - DVJ_ITER]
    DECREF_V rdi, rcx
    extern bool_false
    lea rax, [rel bool_false]
    INCREF rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.dvj_raised_iter:
    mov rdi, [rbp - DVJ_ITER]
    DECREF_V rdi, rcx
.dvj_raised:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.dvj_args:
    extern exc_TypeError_type
    extern raise_exception
    RAISE exc_TypeError_type, "isdisjoint() takes exactly one argument"
END_FUNC dict_view_isdisjoint

section .data


align 8
global dict_keys_view_type
dict_keys_view_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq dict_keys_view_name      ; tp_name
    dq PyDictViewObject_size    ; tp_basicsize
    dq dict_view_dealloc        ; tp_dealloc
    dq dict_view_repr           ; tp_repr
    dq dict_view_repr           ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq dict_view_richcompare    ; tp_richcompare
    dq dict_view_iter           ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq dict_view_num_methods    ; tp_as_number
    dq dict_keys_view_seq_methods ; tp_as_sequence (with sq_contains)
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

; Dict values view type
align 8
global dict_values_view_type
dict_values_view_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq dict_values_view_name    ; tp_name
    dq PyDictViewObject_size    ; tp_basicsize
    dq dict_view_dealloc        ; tp_dealloc
    dq dict_view_repr           ; tp_repr
    dq dict_view_repr           ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare (a values view is not set-like)
    dq dict_view_iter           ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq dict_view_num_methods    ; tp_as_number
    dq dict_view_sequence_methods ; tp_as_sequence
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

; Dict items view type
align 8
global dict_items_view_type
dict_items_view_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq dict_items_view_name     ; tp_name
    dq PyDictViewObject_size    ; tp_basicsize
    dq dict_view_dealloc        ; tp_dealloc
    dq dict_view_repr           ; tp_repr
    dq dict_view_repr           ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq dict_view_richcompare    ; tp_richcompare
    dq dict_view_iter           ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq dict_view_num_methods    ; tp_as_number
    dq dict_items_view_seq_methods ; tp_as_sequence
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
