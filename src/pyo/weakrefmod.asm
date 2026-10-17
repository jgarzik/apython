; weakrefmod.asm - the _weakref module
;
; weakref.py, _weakrefset.py and collections/__init__.py all import from here,
; so nothing downstream of collections could load without it: functools, enum,
; re, inspect, typing, dataclasses, copy.
;
; The references are real.  Rather than give every object a weakref list slot
; -- which would mean a new field in PyTypeObject and an edit to every static
; type table -- the links live in one side table keyed by the referent's
; address, and obj_dealloc consults it.  The table is empty in the common case
; and the check is one compare against a counter, so a program that never
; makes a weak reference pays nothing.
;
; The table owns its reference objects; a reference borrows its referent and
; has that pointer zeroed when the referent dies, before any callback runs.

%include "macros.inc"
%include "object.inc"
%include "value.inc"
%include "opcodes.inc"

extern ap_malloc
extern ap_free
extern gc_alloc
extern obj_incref
extern obj_decref
extern obj_dealloc
extern obj_hash
extern obj_repr
extern obj_richcompare_bool
extern dict_new
extern dict_get
extern dict_set
extern dict_del
extern dict_type
extern list_new
extern list_append
extern list_type
extern str_from_cstr_heap
extern str_new_heap
extern module_new
extern builtin_func_new
extern type_type
extern user_type_metatype
extern exc_metatype
extern func_type
extern builtin_func_type
extern method_type
extern gen_type
extern coro_type
extern async_gen_type
extern module_type
extern memoryview_type
extern code_type
extern file_type
extern io_bytesio_type
extern task_type
extern set_type
extern frozenset_type
extern int_type
extern float_type
extern tuple_type
extern bytes_type
extern raise_exception
extern exc_TypeError_type
extern exc_ReferenceError_type
extern bool_true
extern bool_false
extern none_singleton
extern v_int_bias

section .text

;; ============================================================================
;; weakref_table_get() -> rax = the side table, creating it on first use
;; ============================================================================
DEF_FUNC_LOCAL weakref_table_get
    mov rax, [rel weakref_table]
    test rax, rax
    jnz .have
    call dict_new
    mov [rel weakref_table], rax
.have:
    leave
    ret
END_FUNC weakref_table_get

;; ============================================================================
;; weakref_chain(rdi = referent) -> rax = the list of references, or 0
;; ============================================================================
DEF_FUNC_LOCAL weakref_chain, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rax, [rel weakref_table]
    test rax, rax
    jz .none
    mov rdi, rax
    mov rsi, rbx
    add rsi, [rel v_int_bias]   ; a user address always fits an int immediate
    call dict_get
    pop rbx
    leave
    ret
.none:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC weakref_chain

;; ============================================================================
;; weakref_slot_get(rdi = the referent, rsi = the name, unused) -> rax = Value
;;
;; __weakref__, which CPython answers from *tp_weaklistoffset: the HEAD of the
;; object's weak reference list, or None when there is none.  The links are in
;; the side table here rather than in a slot, so the head has to be picked out
;; of the chain -- and "head" is not simply "entry zero", for two reasons:
;;
;;   - ref_clear ZEROES a dying reference's slot in place rather than removing
;;     it, so the list keeps NULL holes and ob_size never shrinks.  Reading
;;     entry zero answered a hole as a NULL Value, which the getset wrapper
;;     turns into "attribute is not readable" -- so `p.__weakref__` raised
;;     instead of answering None once its only reference had died.
;;   - CPython puts the callback-free reference at the head and appends the
;;     ones with callbacks after it, and this tree appends both.  Measured:
;;     with a basic and a callback reference alive, CPython's __weakref__ is
;;     the basic one whichever order they were made in, and with only a
;;     callback reference it is that.  So: the first live entry with no
;;     callback, else the first live entry, else None.
;;
;; Shaped as a tp_getattr because it is registered as a GS_NAMED getset on every
;; class that adds weak-referenceability; the name is not read.
;; ============================================================================
WSG_ANY   equ 8             ; the first live entry, whatever its callback
WSG_FRAME equ 24            ; + 1 push = 32, 16-aligned
global weakref_slot_get
DEF_FUNC weakref_slot_get, WSG_FRAME
    push rbx
    mov qword [rbp - WSG_ANY], 0
    V_TEST_PTR rdi, rax
    ja .wsg_none                ; an immediate has no weak references
    test rdi, rdi
    jz .wsg_none
    call weakref_chain
    test rax, rax
    jz .wsg_none
    mov rcx, [rax + PyListObject.ob_size]
    mov rdx, [rax + PyListObject.ob_item]
    xor r8d, r8d
.wsg_scan:
    cmp r8, rcx
    jge .wsg_scanned
    mov rbx, [rdx + r8*8]
    test rbx, rbx
    jz .wsg_next                ; a hole ref_clear left behind
    cmp qword [rbp - WSG_ANY], 0
    jne .wsg_have_any
    mov [rbp - WSG_ANY], rbx
.wsg_have_any:
    cmp qword [rbx + PyWeakRefObject.wr_callback], 0
    je .wsg_found               ; callback-free: CPython's head
.wsg_next:
    inc r8
    jmp .wsg_scan
.wsg_scanned:
    mov rbx, [rbp - WSG_ANY]
    test rbx, rbx
    jz .wsg_none
.wsg_found:
    mov rdi, rbx
    call obj_incref
    mov rax, rbx
    pop rbx
    leave
    ret
.wsg_none:
    lea rbx, [rel none_singleton]
    mov rdi, rbx
    call obj_incref
    mov rax, rbx
    pop rbx
    leave
    ret
END_FUNC weakref_slot_get

;; ============================================================================
;; weakref_clear_for(rdi = object about to be freed)
;;
;; Called from obj_dealloc, and only when the table is non-empty.  Every
;; reference to the object is emptied before any callback runs, so a callback
;; that looks at the reference sees a dead one, as CPython guarantees.
;; ============================================================================
WC_OBJ   equ 8
WC_LIST  equ 16
WC_IDX   equ 24
WC_EXC   equ 32
WC_FRAME equ 48             ; + 2 pushes = 64
DEF_FUNC weakref_clear_for, WC_FRAME
    push rbx
    push r12
    mov [rbp - WC_OBJ], rdi

    call weakref_chain
    test rax, rax
    jz .done
    mov [rbp - WC_LIST], rax
    mov rdi, rax
    call obj_incref             ; hold it past the table entry going away

    ; ...and hold every reference IN it, because the chain's entries are
    ; borrowed and a callback may drop the last reference to a later one.
    ; CPython builds a tuple of them for the same reason.
    mov rax, [rbp - WC_LIST]
    mov rbx, [rax + PyListObject.ob_size]
    mov r12, [rax + PyListObject.ob_item]
    xor ecx, ecx
.hold_loop:
    cmp rcx, rbx
    jge .hold_done
    mov rdi, [r12 + rcx*8]
    test rdi, rdi
    jz .hold_next
    inc qword [rdi + PyObject.ob_refcnt]
.hold_next:
    inc rcx
    jmp .hold_loop
.hold_done:

    ; Empty every reference first.
    mov rax, [rbp - WC_LIST]
    mov rbx, [rax + PyListObject.ob_size]
    mov r12, [rax + PyListObject.ob_item]
    xor ecx, ecx
.clear_loop:
    cmp rcx, rbx
    jge .clear_done
    mov rdx, [r12 + rcx*8]
    test rdx, rdx
    jz .clear_next
    mov qword [rdx + PyWeakRefObject.wr_object], 0
.clear_next:
    inc rcx
    jmp .clear_loop
.clear_done:

    ; Drop the table entry.  That releases the table's references, so a
    ; reference nobody else holds is freed here.
    mov rdi, [rel weakref_table]
    test rdi, rdi
    jz .no_entry
    mov rsi, [rbp - WC_OBJ]
    add rsi, [rel v_int_bias]
    call dict_del
    mov rax, [rel weakref_table]
    mov rax, [rax + PyDictObject.ob_size]
    mov [rel weakref_live], rax
.no_entry:

    ; Then the callbacks, on whichever references are still alive.
    mov qword [rbp - WC_IDX], 0
.cb_loop:
    mov rax, [rbp - WC_LIST]
    mov rcx, [rbp - WC_IDX]
    cmp rcx, [rax + PyListObject.ob_size]
    jge .cb_done
    mov rdx, [rax + PyListObject.ob_item]
    mov rbx, [rdx + rcx*8]
    inc qword [rbp - WC_IDX]
    test rbx, rbx
    jz .cb_loop
    mov r12, [rbx + PyWeakRefObject.wr_callback]
    test r12, r12
    jz .cb_loop
    mov rax, [r12 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .cb_loop

    ; A callback that raises has no caller to hand the exception to; report
    ; nothing and put back whatever was being handled, as __del__ does.
    DUNDER_EXC_SAVE [rbp - WC_EXC]
    inc qword [rbx + PyObject.ob_refcnt]
    sub rsp, 16
    mov [rsp], rbx
    mov rdi, r12
    mov rsi, rsp
    mov edx, 1
    call rax
    add rsp, 16
    V_UNPACK rax, rdx
    test edx, edx
    jz .cb_no_result
    DECREF_VAL rax, rdx
.cb_no_result:
    dec qword [rbx + PyObject.ob_refcnt]
    DUNDER_RAISED [rbp - WC_EXC], .cb_raised
.cb_resume:
    jmp .cb_loop

.cb_raised:
    mov rdi, [gs:ThreadState.current_exception]
    mov qword [gs:ThreadState.current_exception], 0
    call obj_decref
    mov rax, [rbp - WC_EXC]
    mov [gs:ThreadState.current_exception], rax
    jmp .cb_resume

.cb_done:
    ; Give back what the hold loop took.  wr_object is zero on all of them by
    ; now, so a ref that dies here does not go looking for a chain that the
    ; table no longer has.
    mov rax, [rbp - WC_LIST]
    mov rbx, [rax + PyListObject.ob_size]
    xor r12d, r12d
.rel_loop:
    cmp r12, rbx
    jge .rel_done
    mov rax, [rbp - WC_LIST]
    mov rax, [rax + PyListObject.ob_item]
    mov rdi, [rax + r12*8]
    test rdi, rdi
    jz .rel_next
    ; Zeroed BEFORE the release: the list's own dealloc releases every item it
    ; still holds, and these are borrowed -- the chain gave its reference back
    ; when it took them.  Emptying the slot is what keeps the two from
    ; disagreeing.
    mov qword [rax + r12*8], 0
    call obj_decref
.rel_next:
    inc r12
    jmp .rel_loop
.rel_done:
    mov rdi, [rbp - WC_LIST]
    call obj_decref
.done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC weakref_clear_for

;; ============================================================================
;; weakref_make(rdi = type, rsi = referent, rdx = callback or 0) -> rax = ref
;; ============================================================================
WM_TYPE  equ 8
WM_OBJ   equ 16
WM_CB    equ 24
WM_REF   equ 32
WM_FRAME equ 56            ; + 1 push = 64, 16-aligned
;; weakref_make_shared(rdi = the referent) -> rax = the shared weakref, or 0.
;; The no-callback form, which is the one that is shared, reached by name for
;; a caller that wants what a set can hold on a class's behalf.
global weakref_make_shared
DEF_FUNC weakref_make_shared
    mov rsi, rdi
    lea rdi, [rel weakref_type]
    xor edx, edx
    call weakref_make
    leave
    ret
END_FUNC weakref_make_shared

DEF_FUNC_LOCAL weakref_make, WM_FRAME
    push rbx
    mov [rbp - WM_TYPE], rdi
    mov [rbp - WM_OBJ], rsi
    mov [rbp - WM_CB], rdx

    ; Without a callback the reference is shared, so `ref(x) is ref(x)`, as
    ; CPython does.  With one it must be distinct: each callback fires once.
    test rdx, rdx
    jnz .fresh
    mov rdi, rsi
    call weakref_chain
    test rax, rax
    jz .fresh
    mov rcx, [rax + PyListObject.ob_size]
    mov rdx, [rax + PyListObject.ob_item]
    xor r8d, r8d
.reuse_scan:
    cmp r8, rcx
    jge .fresh
    mov rbx, [rdx + r8*8]
    test rbx, rbx
    jz .reuse_next
    cmp qword [rbx + PyWeakRefObject.wr_callback], 0
    jne .reuse_next
    mov rax, [rbx + PyObject.ob_type]
    cmp rax, [rbp - WM_TYPE]
    jne .reuse_next
    mov rdi, rbx
    call obj_incref
    mov rax, rbx
    pop rbx
    leave
    ret
.reuse_next:
    inc r8
    jmp .reuse_scan

.fresh:
    ; A SUBCLASS is a heaptype: it carries TYPE_FLAG_HAVE_GC, so its instance
    ; has to come from gc_alloc and be tracked, and its body -- the instance
    ; dict and any __slots__ past our fields -- has to be zeroed before the
    ; collector can see it.  builtin_sub_alloc is what every other builtin
    ; subclass is built by and does all three.  ap_malloc here handed
    ; gc_dealloc a pointer sixteen bytes short of the block, and the first
    ; weakref.KeyedRef ever built corrupted the heap.
    mov rdi, [rbp - WM_TYPE]
    lea rcx, [rel weakref_type]
    cmp rdi, rcx
    je .fresh_exact
    lea rcx, [rel proxy_type]
    cmp rdi, rcx
    je .fresh_exact
    lea rcx, [rel callableproxy_type]
    cmp rdi, rcx
    je .fresh_exact
    extern builtin_sub_alloc
    call builtin_sub_alloc      ; refcnt, ob_type, the type's reference, zeroed
    mov rbx, rax
    jmp .fields

.fresh_exact:
    mov rdi, [rdi + PyTypeObject.tp_basicsize]
    cmp rdi, PyWeakRefObject_size
    jae .size_ok
    mov edi, PyWeakRefObject_size
.size_ok:
    call ap_malloc
    mov rbx, rax
    mov qword [rbx + PyObject.ob_refcnt], 1
    mov rax, [rbp - WM_TYPE]
    mov [rbx + PyObject.ob_type], rax
    inc qword [rax + PyObject.ob_refcnt]

.fields:
    mov rax, [rbp - WM_OBJ]
    mov [rbx + PyWeakRefObject.wr_object], rax
    mov rax, [rbp - WM_CB]
    mov [rbx + PyWeakRefObject.wr_callback], rax
    test rax, rax
    jz .no_cb
    mov rdi, rax
    call obj_incref
.no_cb:
    mov qword [rbx + PyWeakRefObject.wr_hash], -1

    ; A subclass may have an instance dict beyond our fields; zero it.
    mov rax, [rbp - WM_TYPE]
    mov rcx, [rax + PyTypeObject.tp_dictoffset]
    test rcx, rcx
    jz .no_dict
    mov qword [rbx + rcx], 0
.no_dict:

    ; Register in the side table.
    call weakref_table_get
    mov [rbp - WM_REF], rax
    mov rdi, rax
    mov rsi, [rbp - WM_OBJ]
    add rsi, [rel v_int_bias]
    call dict_get
    test rax, rax
    jnz .have_chain
    xor edi, edi
    call list_new
    ; The chain is NOT collector-tracked.  Its entries are borrowed, and
    ; gc_visit_decref walks a tracked list's items and counts a reference for
    ; each -- so every weak reference in it looked one reference short of
    ; reachable, and an explicit gc.collect() freed objects a live frame was
    ; still holding.  Nothing here can be part of a cycle: the list holds no
    ; references at all, and the table that holds the list is tracked.
    push rax
    mov rdi, rax
    extern gc_untrack
    call gc_untrack
    pop rax
    push rax
    mov rdi, [rbp - WM_REF]
    mov rsi, [rbp - WM_OBJ]
    add rsi, [rel v_int_bias]
    mov rdx, [rsp]
    call dict_set
    pop rax
    push rax
    mov rdi, rax
    call obj_decref             ; the table holds it now
    pop rax
.have_chain:
    mov rdi, rax
    mov rsi, rbx
    call list_append
    ; The chain holds a BORROWED reference.  list_append took one, and it is
    ; given straight back: an owned one meant a ref nobody else held stayed
    ; alive for as long as its referent did, so `r = ref(c, cb); del r; del c`
    ; still ran the callback -- which CPython does not, because dropping the
    ; last reference to a ref takes its callback with it.  ref_clear is what
    ; keeps the slot from dangling.
    mov rdi, rbx
    call obj_decref
    mov rax, [rel weakref_table]
    mov rax, [rax + PyDictObject.ob_size]
    mov [rel weakref_live], rax

    mov rax, rbx
    pop rbx
    leave
    ret
END_FUNC weakref_make

;; ============================================================================
;; ref_dealloc / ref_call / ref_repr / ref_hash / ref_richcompare
;; ============================================================================
DEF_FUNC_LOCAL ref_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    call ref_clear              ; the chain slot and the callback
    mov rdi, [rbx + PyObject.ob_type]
    test rdi, rdi
    jz .free
    call obj_decref
.free:
    mov rdi, rbx
    call ap_free
    pop rbx
    leave
    ret
END_FUNC ref_dealloc

; Calling a reference yields the referent, or None once it is gone.
DEF_FUNC ref_deref
    mov rax, [rdi + PyWeakRefObject.wr_object]
    test rax, rax
    jz .dead
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.dead:
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
END_FUNC ref_deref

RR_SELF  equ 8
RR_BUF   equ 1040
RR_FRAME equ 1056           ; + 2 pushes = 1072
DEF_FUNC_LOCAL ref_repr, RR_FRAME
    push rbx
    push r12
    mov [rbp - RR_SELF], rdi
    lea rbx, [rbp - RR_BUF]
    xor r12d, r12d
    mov rax, [rdi + PyWeakRefObject.wr_object]
    test rax, rax
    jz .dead
    CSTRING rsi, "<weakref at 0x0; to '"
    jmp .copy_prefix
.dead:
    CSTRING rsi, "<weakref at 0x0; dead>"
.copy_prefix:
    movzx eax, byte [rsi]
    test al, al
    jz .prefix_done
    inc rsi
    mov [rbx + r12], al
    inc r12
    jmp .copy_prefix
.prefix_done:
    mov rax, [rbp - RR_SELF]
    mov rax, [rax + PyWeakRefObject.wr_object]
    test rax, rax
    jz .finish
    mov rsi, [rax + PyObject.ob_type]
    mov rsi, [rsi + PyTypeObject.tp_name]
.copy_name:
    movzx eax, byte [rsi]
    test al, al
    jz .name_done
    cmp r12, RR_BUF - 8
    jae .name_done
    inc rsi
    mov [rbx + r12], al
    inc r12
    jmp .copy_name
.name_done:
    mov byte [rbx + r12], 0x27      ; a closing quote
    mov byte [rbx + r12 + 1], '>'
    add r12, 2
.finish:
    mov rdi, rbx
    mov rsi, r12
    call str_new_heap
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC ref_repr

; A live reference hashes as its referent and caches the result, so it keeps
; the same hash after the referent dies -- which is what lets a WeakSet find
; and discard a dead entry.
DEF_FUNC_LOCAL ref_hash, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rax, [rbx + PyWeakRefObject.wr_hash]
    cmp rax, -1
    jne .cached
    mov rdi, [rbx + PyWeakRefObject.wr_object]
    test rdi, rdi
    jz .dead
    call obj_hash
    mov [rbx + PyWeakRefObject.wr_hash], rax
.cached:
    pop rbx
    leave
    ret
.dead:
    RAISE exc_TypeError_type, "weak object has gone away"
END_FUNC ref_hash

; Two live references compare as their referents do; a dead one only ever
; equals itself.
RC_SELF  equ 8
RC_OTHER equ 16
RC_OP    equ 24
RC_FRAME equ 32             ; + 0 pushes = 32
DEF_FUNC_LOCAL ref_richcompare, RC_FRAME
    mov [rbp - RC_SELF], rdi
    mov [rbp - RC_OTHER], rsi
    mov [rbp - RC_OP], rdx
    cmp edx, CMP_EQ
    je .eq_or_ne
    cmp edx, CMP_NE
    je .eq_or_ne
    lea rax, [rel notimpl_ref]
    mov rax, [rax]
    jmp .out_ptr

.eq_or_ne:
    V_TEST_PTR rsi, rax
    ja .not_equal
    test rsi, rsi
    jz .not_equal
    mov rax, [rsi + PyObject.ob_type]
    cmp rax, [rdi + PyObject.ob_type]
    jne .not_equal
    mov rdi, [rdi + PyWeakRefObject.wr_object]
    mov rsi, [rsi + PyWeakRefObject.wr_object]
    test rdi, rdi
    jz .by_identity
    test rsi, rsi
    jz .by_identity
    call obj_richcompare_bool
    test eax, eax
    jz .not_equal
    jmp .equal
.by_identity:
    mov rax, [rbp - RC_SELF]
    cmp rax, [rbp - RC_OTHER]
    jne .not_equal
.equal:
    cmp qword [rbp - RC_OP], CMP_EQ
    je .true
    jmp .false
.not_equal:
    cmp qword [rbp - RC_OP], CMP_EQ
    je .false
.true:
    lea rax, [rel bool_true]
    jmp .out_ptr
.false:
    lea rax, [rel bool_false]
.out_ptr:
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
END_FUNC ref_richcompare

;; ============================================================================
;; ref(object[, callback]) -- tp_new for ReferenceType and its subclasses
;; ============================================================================

;; ============================================================================
;; weakref_check_referent(rdi = the referent Value) -> rax = the object, or 0
;;                                                     with a TypeError pending
;;
;; CPython refuses a weak reference to most builtin types: `weakref.ref([])`
;; is a TypeError, not a reference.  That is what a zero tp_weaklistoffset
;; means, and it is load-bearing -- WeakValueDictionary relies on the refusal
;; to reject a value it could never observe dying.  Every one of them was
;; accepted here, so the failure surfaced much later, as a dictionary that
;; quietly never dropped anything.
;;
;; The links live in a side table rather than in a per-object slot (see the
;; file header), so there is no offset to test.  This answers the same
;; question from the type instead.
;; ============================================================================
DEF_FUNC weakref_check_referent, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    ; An immediate is an int or a float, and CPython refuses both -- but it
    ; names the type, so resolve it rather than falling into a generic
    ; message.
    V_IS_INT rdi, rax
    jae .wcr_refuse_int
    V_IS_FLOAT rdi, rax
    jb .wcr_refuse_float
    test rdi, rdi
    jz .wcr_refuse_null
    mov rbx, rdi
    mov rdi, [rdi + PyObject.ob_type]
    call weakref_referenceable
    test eax, eax
    jz .wcr_refuse
    mov rax, rbx
    pop rbx
    leave
    ret
.wcr_refuse:
    mov rsi, [rbx + PyObject.ob_type]
    jmp .wcr_raise
.wcr_refuse_int:
    lea rsi, [rel int_type]
    jmp .wcr_raise
.wcr_refuse_float:
    lea rsi, [rel float_type]
    jmp .wcr_raise
.wcr_refuse_null:
    xor esi, esi
.wcr_raise:
    lea rdi, [rel wcr_message]
    extern raise_type_error_with_typename
    call raise_type_error_with_typename
END_FUNC weakref_check_referent

section .rodata
wcr_message: db "cannot create weak reference to '", 1, "' object", 0

;; The static types CPython gives a weaklist slot.  Everything else static --
;; int, str, list, dict, tuple, the iterators, the descriptors, the exception
;; types -- refuses, and so does `object` itself.
align 8
weakref_allowed_types:
    dq set_type
    dq frozenset_type
    dq type_type
    dq user_type_metatype
    dq exc_metatype
    dq func_type
    dq builtin_func_type
    dq method_type
    dq gen_type
    dq coro_type
    dq async_gen_type
    dq module_type
    dq memoryview_type
    dq code_type
    dq file_type
    dq io_bytesio_type
    dq task_type
    dq 0

;; The three whose instances keep their value inline and variable-sized.  A
;; heaptype over one of them cannot be given a weaklist word at a fixed
;; offset, so CPython does not, and `class I(int): pass` is not
;; weak-referenceable even though `class L(list): pass` is.
align 8
weakref_varsize_types:
    dq int_type
    dq tuple_type
    dq bytes_type
    dq 0
section .text

;; ============================================================================
;; weakref_referenceable(rdi = a type) -> eax = 1 when its instances can be
;;                                        weakly referenced
;;
;; CPython's rule, which lives in type_new_set_attrs: a heaptype is given a
;; __weakref__ word unless it declares __slots__ without naming it, or its
;; layout base keeps its value inline and variable-sized.  Once any level in
;; the chain has the word, every type below it inherits one.
;; ============================================================================
WRR_ADDS  equ 8
WRR_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC weakref_referenceable, WRR_FRAME
    push rbx
    mov rbx, rdi

    ; A __weakref__ named in __slots__ settles it, at any level.
    lea rsi, [rel wrr_weakref_name]
    extern dunder_lookup
    call dunder_lookup
    test rax, rax
    jnz .wrr_yes

    ; Walk down to the first static ancestor, noting whether any heaptype on
    ; the way would have been given the word.
    mov qword [rbp - WRR_ADDS], 0
.wrr_walk:
    test rbx, rbx
    jz .wrr_from_adds
    test qword [rbx + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .wrr_static
    ; DECLARED __slots__, not HAS_SLOTS.  The latter means "this class has no
    ; instance dict", which a __slots__ naming '__dict__' leaves clear -- so
    ; such a class read as slot-free here and its instances were
    ; weak-referenceable, where CPython refuses them: naming '__dict__' does not
    ; excuse a __slots__ from suppressing the weakref word.
    test qword [rbx + PyTypeObject.tp_flags], TYPE_FLAG_DECLARED_SLOTS
    jnz .wrr_next
    mov qword [rbp - WRR_ADDS], 1
.wrr_next:
    mov rbx, [rbx + PyTypeObject.tp_base]
    jmp .wrr_walk

.wrr_static:
    lea rcx, [rel weakref_allowed_types]
.wrr_allow_loop:
    mov rax, [rcx]
    test rax, rax
    jz .wrr_check_varsize
    cmp rax, rbx
    je .wrr_yes
    add rcx, 8
    jmp .wrr_allow_loop

.wrr_check_varsize:
    lea rcx, [rel weakref_varsize_types]
.wrr_var_loop:
    mov rax, [rcx]
    test rax, rax
    jz .wrr_from_adds
    cmp rax, rbx
    je .wrr_no
    add rcx, 8
    jmp .wrr_var_loop

.wrr_from_adds:
    mov rax, [rbp - WRR_ADDS]
    pop rbx
    leave
    ret
.wrr_yes:
    mov eax, 1
    pop rbx
    leave
    ret
.wrr_no:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC weakref_referenceable

section .rodata
wrr_weakref_name: db "__weakref__", 0
rc_too_many: db "__new__ expected at most 2 arguments, got ", 0
section .text

WRC_NARGS equ 8
WRC_FRAME equ 40            ; + 1 push = 48, and the two pushes below keep it
DEF_FUNC ref_construct, WRC_FRAME
    ; rdi = type, rsi = args, rdx = nargs
    push rbx
    mov rbx, rdi

    ; Only the POSITIONAL arguments count.  A keyword's value sits in the same
    ; array with its name parked in kw_names_pending, so a subclass written
    ; `MyRef(ob, callback=None, value=42)` -- which is how CPython's own
    ; test_weakref writes one -- handed `value`'s 24 to weakref_make as the
    ; callback and INCREF'd an int immediate as a pointer.  CPython's
    ; weakref___new__ unpacks the positional tuple and ignores the keywords
    ; entirely; ref.__init__ is what refuses them, and a subclass overriding
    ; __init__ is therefore free to have keywords of its own.  __new__ is
    ; expected to consume the global, and type_call hands __init__ its own copy.
    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jz .rc_no_kw
    mov qword [gs:ThreadState.kw_names_pending], 0
    sub rdx, [rax + PyTupleObject.ob_size]
    ; ref ITSELF takes none.  CPython raises that from ref.__init__, which
    ; this tree's type_call does not reach for a static type -- the builtin
    ; constructor in tp_new is the whole of the call there -- so the refusal
    ; is made here, and only for ref itself.  A subclass still gets CPython's
    ; answer either way: its own __init__ if it has one, and ref.__init__,
    ; which refuses, if it does not.
    lea rcx, [rel weakref_type]
    cmp rbx, rcx
    je .bad_kw
.rc_no_kw:
    mov [rbp - WRC_NARGS], rdx
    cmp rdx, 1
    jl .bad_few
    cmp rdx, 2
    jg .bad_many

    push rdx                    ; nargs, across the check
    push rsi
    mov rdi, [rsi]
    call weakref_check_referent ; raises, naming the type, when it refuses
    pop rsi
    pop rdx
    mov rdi, rax
    xor ecx, ecx
    cmp rdx, 2
    jl .no_cb
    mov rcx, [rsi + 8]
    lea rax, [rel none_singleton]
    cmp rcx, rax
    jne .have_cb
    xor ecx, ecx
.have_cb:
.no_cb:
    mov rsi, rdi
    mov rdx, rcx
    mov rdi, rbx
    call weakref_make
    mov edx, TAG_PTR
    pop rbx
    V_PACK rax, rdx
    leave
    ret
.bad_few:
    RAISE exc_TypeError_type, "__new__ expected at least 1 argument, got 0"
.bad_kw:
    RAISE exc_TypeError_type, "ref() takes no keyword arguments"
.bad_many:
    ; CPython counts them in the message, and a caller that passed three has
    ; to be told it passed three.
    extern raise_type_error_counted
    lea rdi, [rel rc_too_many]
    mov rsi, [rbp - WRC_NARGS]
    xor edx, edx
    call raise_type_error_counted   ; does not return
END_FUNC ref_construct

;; ============================================================================
;; ref_dunder_new(args, nargs) -> Value    -- weakref.ref.__new__
;;
;; ref keeps its constructor in tp_new, so ref.__dict__ had no __new__ and
;; `super().__new__(cls, ob, cb)` in a subclass reached object.__new__, which
;; refuses the extra arguments.  weakref.KeyedRef is written exactly that way,
;; and WeakValueDictionary is built on it.
;; ============================================================================
extern new_from_slot
DEF_FUNC ref_dunder_new
    mov rdx, rsi                ; nargs
    mov rsi, rdi                ; args
    lea rdi, [rel weakref_type]
    call new_from_slot
    leave
    ret
END_FUNC ref_dunder_new

;; ============================================================================
;; ref_dunder_call(rdi = args, rsi = nargs) -> rax = Value, the referent or None
;;
;; ref keeps its dereference in tp_call, so ref.__dict__ had no __call__ and a
;; subclass's `super().__call__()` found nothing -- which is how CPython's own
;; test_weakref writes a subclass that logs each deref.  It calls REF's slot
;; and not the argument's type's, so a subclass that overrides __call__ does
;; not re-enter itself.
;; ============================================================================
DEF_FUNC ref_dunder_call
    mov rdi, [rdi]
    call ref_deref
    leave
    ret
END_FUNC ref_dunder_call

;; ============================================================================
;; ref_dunder_init(args, nargs) -> None    -- weakref.ref.__init__
;;
;; A no-op that ACCEPTS the constructor's arguments.  ref builds itself in
;; __new__, so there is nothing left to initialise -- but weakref.KeyedRef's
;; __init__ ends in `super().__init__(ob, callback)`, and without an entry
;; here that reaches object.__init__, which refuses the two extra arguments.
;; CPython's ref has the same do-nothing tp_init for the same reason.
;; ============================================================================
DEF_FUNC ref_dunder_init
    ; ref itself takes no keywords -- `ref(o, callback=cb)` is a TypeError in
    ; CPython, raised HERE rather than in __new__, which is why a subclass
    ; that overrides __init__ never sees this refusal.
    cmp qword [gs:ThreadState.kw_names_pending], 0
    jne .rdi_kwerror
    cmp rsi, 1
    jl .rdi_error
    cmp rsi, 3
    jg .rdi_error
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
.rdi_error:
    RAISE exc_TypeError_type, "ref.__init__() takes 1 or 2 arguments"
.rdi_kwerror:
    mov qword [gs:ThreadState.kw_names_pending], 0
    RAISE exc_TypeError_type, "ref() takes no keyword arguments"
END_FUNC ref_dunder_init

;; ============================================================================
;; ref_traverse(rdi = a ref) -> nothing; the collector's visit of what it owns
;;
;; A ref owns exactly one thing: its callback.  wr_object is BORROWED -- the
;; whole point of a weak reference -- so it is not visited and not released.
;;
;; This and ref_clear exist for the SUBCLASS.  type_from_parts reads a builtin
;; base's tp_clear to decide what a subclass's dealloc must do: with one it
;; gets descr_sub_dealloc, which runs the clear and then instance_dealloc for
;; the instance dict, the __slots__ and the class reference; without one it
;; gets builtin_sub_dealloc, which frees the block and leaks everything else
;; -- and weakref.KeyedRef, which is what WeakValueDictionary stores, carries
;; a key in an instance dict.
;; ============================================================================
DEF_FUNC ref_traverse, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rax, [rbx + PyWeakRefObject.wr_callback]
    VISIT_V rax, rcx
    pop rbx
    leave
    ret
END_FUNC ref_traverse

;; ============================================================================
;; ref_clear(rdi = a ref) -> nothing; the callback released and the field zeroed
;;
;; The other half of the pair above.  Zeroing as it goes is what keeps
;; descr_sub_dealloc from releasing the callback a second time.
;; ============================================================================
DEF_FUNC ref_clear, 8               ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; Leave the referent's chain, whose entries are borrowed.  A NULL
    ; wr_object means the referent has already gone and taken the whole entry
    ; with it, so there is nothing to leave.
    mov rdi, [rbx + PyWeakRefObject.wr_object]
    test rdi, rdi
    jz .rc_unlinked
    call weakref_chain
    test rax, rax
    jz .rc_unlinked
    mov rcx, [rax + PyListObject.ob_size]
    mov rdx, [rax + PyListObject.ob_item]
    xor r8d, r8d
.rc_scan:
    cmp r8, rcx
    jge .rc_unlinked
    cmp [rdx + r8*8], rbx
    je .rc_hit
    inc r8
    jmp .rc_scan
.rc_hit:
    mov qword [rdx + r8*8], 0
.rc_unlinked:

    mov rdi, [rbx + PyWeakRefObject.wr_callback]
    mov qword [rbx + PyWeakRefObject.wr_callback], 0
    test rdi, rdi
    jz .rc_done
    call obj_decref
.rc_done:
    pop rbx
    leave
    ret
END_FUNC ref_clear

;; ============================================================================
;; proxy objects: the same structure, forwarding attribute access
;; ============================================================================
DEF_FUNC_LOCAL proxy_referent
    mov rax, [rdi + PyWeakRefObject.wr_object]
    test rax, rax
    jz .dead
    leave
    ret
.dead:
    RAISE exc_ReferenceError_type, "weakly-referenced object no longer exists"
END_FUNC proxy_referent

DEF_FUNC proxy_getattr, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rsi
    call proxy_referent
    mov rdi, rax
    mov rsi, rbx
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_getattr]
    test rax, rax
    jz .via_dict
    call rax
    pop rbx
    leave
    ret
.via_dict:
    mov rax, [rdi + PyObject.ob_type]
    mov rdi, [rax + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .none
    mov rsi, rbx
    call dict_get
    test rax, rax
    jz .none
    INCREF_V rax, rcx
    pop rbx
    leave
    ret
.none:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    V_PACK rax, rdx
    ret
END_FUNC proxy_getattr

DEF_FUNC proxy_setattr
    push rbx
    push r12
    mov rbx, rsi
    mov r12, rdx
    call proxy_referent
    mov rdi, rax
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_setattr]
    test rax, rax
    jz .no_setattr
    mov rsi, rbx
    mov rdx, r12
    call rax
    pop r12
    pop rbx
    leave
    ret
.no_setattr:
    RAISE exc_TypeError_type, "proxy object does not support attribute assignment"
END_FUNC proxy_setattr

DEF_FUNC proxy_repr
    call proxy_referent
    mov rdi, rax
    call obj_repr
    leave
    ret
END_FUNC proxy_repr

DEF_FUNC proxy_call
    push rbx
    push r12
    mov rbx, rsi
    mov r12, rdx
    call proxy_referent
    mov rdi, rax
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .not_callable
    mov rsi, rbx
    mov rdx, r12
    call rax
    pop r12
    pop rbx
    leave
    ret
.not_callable:
    RAISE exc_TypeError_type, "proxy object is not callable"
END_FUNC proxy_call

;; ============================================================================
;; Module functions
;; ============================================================================
DEF_FUNC wr_proxy_func
    ; proxy(object[, callback])
    cmp rsi, 1
    jl .bad
    push rbx
    mov rbx, rdi
    push rsi                    ; nargs, across the check
    mov rdi, [rbx]
    call weakref_check_referent ; raises, naming the type, when it refuses
    pop rsi
    mov rdi, rax
    ; A callable referent gets CallableProxyType, as CPython does.
    mov rax, [rdi + PyObject.ob_type]
    cmp qword [rax + PyTypeObject.tp_call], 0
    je .plain
    lea rax, [rel callableproxy_type]
    jmp .have_type
.plain:
    lea rax, [rel proxy_type]
.have_type:
    mov r8, rax
    xor ecx, ecx
    cmp rsi, 2
    jl .no_cb
    mov rcx, [rbx + 8]
    lea rax, [rel none_singleton]
    cmp rcx, rax
    jne .no_cb
    xor ecx, ecx
.no_cb:
    mov rsi, rdi
    mov rdx, rcx
    mov rdi, r8
    call weakref_make
    mov edx, TAG_PTR
    pop rbx
    V_PACK rax, rdx
    leave
    ret
.bad:
    RAISE exc_TypeError_type, "cannot create weak proxy to this object"
END_FUNC wr_proxy_func

DEF_FUNC wr_getweakrefcount_func
    cmp rsi, 1
    jl .zero
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .zero
    test rdi, rdi
    jz .zero
    call weakref_chain
    test rax, rax
    jz .zero
    ; Count the LIVE ones: a reference that died before its referent left its
    ; slot empty rather than shortening the chain.
    mov rcx, [rax + PyListObject.ob_size]
    mov rdx, [rax + PyListObject.ob_item]
    xor eax, eax
    xor r8d, r8d
.count_loop:
    cmp r8, rcx
    jge .counted
    cmp qword [rdx + r8*8], 0
    je .count_next
    inc rax
.count_next:
    inc r8
    jmp .count_loop
.counted:
    add rax, [rel v_int_bias]
    leave
    ret
.zero:
    mov rax, [rel v_int_bias]
    leave
    ret
END_FUNC wr_getweakrefcount_func

DEF_FUNC wr_getweakrefs_func
    cmp rsi, 1
    jl .empty
    push rbx
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .empty_pop
    test rdi, rdi
    jz .empty_pop
    call weakref_chain
    test rax, rax
    jz .empty_pop
    mov rbx, rax
    xor edi, edi
    call list_new
    push rax
    mov rcx, [rbx + PyListObject.ob_size]
    mov rdx, [rbx + PyListObject.ob_item]
    xor r8d, r8d
.copy:
    cmp r8, rcx
    jge .copied
    mov rsi, [rdx + r8*8]
    test rsi, rsi
    jz .copy_next               ; a slot a dead reference left behind
    push rcx
    push rdx
    push r8
    mov rdi, [rsp + 24]
    call list_append
    pop r8
    pop rdx
    pop rcx
.copy_next:
    inc r8
    jmp .copy
.copied:
    pop rax
    mov edx, TAG_PTR
    pop rbx
    V_PACK rax, rdx
    leave
    ret
.empty_pop:
    pop rbx
.empty:
    xor edi, edi
    call list_new
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
END_FUNC wr_getweakrefs_func

; _remove_dead_weakref(dict, key): drop dict[key] if it is a reference whose
; referent has gone.  WeakValueDictionary calls this from its callback.
DEF_FUNC wr_remove_dead_func
    cmp rsi, 2
    jl .none
    push rbx
    mov rbx, rdi
    mov rdi, [rbx]
    V_TEST_PTR rdi, rax
    ja .none_pop
    mov rsi, [rbx + 8]
    push rdi
    push rsi
    call dict_get
    pop rsi
    pop rdi
    test rax, rax
    jz .none_pop
    V_TEST_PTR rax, rcx
    ja .none_pop
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel weakref_type]
    cmp rcx, rdx
    jne .none_pop
    cmp qword [rax + PyWeakRefObject.wr_object], 0
    jne .none_pop
    call dict_del
.none_pop:
    pop rbx
.none:
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
END_FUNC wr_remove_dead_func

;; ============================================================================
;; Module construction
;; ============================================================================

%macro WR_ADD_TYPE 2
    lea rdi, [rel %2]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rel %1]
    call dict_set
    pop rdi
    call obj_decref
%endmacro

WRM_FRAME equ 16            ; + 2 pushes = 32, 16-aligned
DEF_FUNC weakref_module_create, WRM_FRAME
    push rbx
    push r12

    call dict_new
    mov r12, rax

    MODULE_ADD_FUNC wr_proxy_func,           wrm_proxy
    MODULE_ADD_FUNC wr_getweakrefcount_func, wrm_getweakrefcount
    MODULE_ADD_FUNC wr_getweakrefs_func,     wrm_getweakrefs
    MODULE_ADD_FUNC wr_remove_dead_func,     wrm_remove_dead

    WR_ADD_TYPE weakref_type,       wrm_ref
    WR_ADD_TYPE weakref_type,       wrm_ReferenceType
    WR_ADD_TYPE proxy_type,         wrm_ProxyType
    WR_ADD_TYPE callableproxy_type, wrm_CallableProxyType

    lea rdi, [rel wrm_name]
    call str_from_cstr_heap
    push rax
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov rbx, rax
    pop rdi
    call obj_decref
    mov rdi, r12
    call obj_decref
    mov rax, rbx

    pop r12
    pop rbx
    leave
    ret
END_FUNC weakref_module_create

section .data
align 8
weakref_table: dq 0
global weakref_live
weakref_live:  dq 0
notimpl_ref:   dq notimpl_singleton
extern notimpl_singleton

align 8
wrm_ref_name:   db "weakref", 0
wrm_proxy_name: db "weakproxy", 0
wrm_cproxy_name: db "weakcallableproxy", 0

align 8
global weakref_type
weakref_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq wrm_ref_name             ; tp_name
    dq PyWeakRefObject_size     ; tp_basicsize
    dq ref_dealloc              ; tp_dealloc
    dq ref_repr                 ; tp_repr
    dq ref_repr                 ; tp_str
    dq ref_hash                 ; tp_hash
    dq ref_deref                ; tp_call — calling a reference derefs it
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq ref_richcompare          ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq ref_construct            ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_BASETYPE       ; tp_flags
    dq 0                        ; tp_bases
    dq ref_traverse             ; tp_traverse
    dq ref_clear                ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

align 8
global proxy_type
proxy_type:
    dq 1
    dq type_type
    dq wrm_proxy_name
    dq PyWeakRefObject_size
    dq ref_dealloc
    dq proxy_repr
    dq proxy_repr
    dq 0                        ; tp_hash — a proxy is unhashable
    dq 0                        ; tp_call
    dq proxy_getattr
    dq proxy_setattr
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

align 8
global callableproxy_type
callableproxy_type:
    dq 1
    dq type_type
    dq wrm_cproxy_name
    dq PyWeakRefObject_size
    dq ref_dealloc
    dq proxy_repr
    dq proxy_repr
    dq 0
    dq proxy_call
    dq proxy_getattr
    dq proxy_setattr
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

section .rodata
wrm_name:              db "_weakref", 0
wrm_proxy:             db "proxy", 0
wrm_getweakrefcount:   db "getweakrefcount", 0
wrm_getweakrefs:       db "getweakrefs", 0
wrm_remove_dead:       db "_remove_dead_weakref", 0
wrm_ref:               db "ref", 0
wrm_ReferenceType:     db "ReferenceType", 0
wrm_ProxyType:         db "ProxyType", 0
wrm_CallableProxyType: db "CallableProxyType", 0
