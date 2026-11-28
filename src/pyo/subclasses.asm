; subclasses.asm - the direct-subclass side table behind type.__subclasses__
;
; A class does not carry a list of its subclasses.  Giving it one would mean a
; new field in PyTypeObject and an edit to every static type table in the
; tree, so the links live in a side table keyed by the base's address -- the
; shape _weakref already uses, and for the same reason.  The table is empty
; until the first class is built, and obj_dealloc's check against it is one
; compare with a counter.
;
; The entries are BORROWED, which is what CPython's weak-referenced
; tp_subclasses amounts to: a class is recorded when it is created and removed
; when it is freed, so the list only ever holds live classes.
;
; Borrowed is why the entries are NOT in a Python list.  Two things go wrong
; if they are, and both were seen:
;
;   - list_append takes a reference, so every class became immortal;
;   - and giving it back is not enough, because a list is GC-visible.  The
;     collector walks it from the table -- which is a root -- reaches the
;     class and marks it alive.  A borrowed pointer inside a tracked container
;     reachable from a root is not borrowed as far as the collector is
;     concerned.
;   - and a list DEALLOCATES its items, so dropping the list released classes
;     it never owned.
;
; So each base's subclasses live in a SubList: an ap_malloc'd header and a
; plain array of PyTypeObject*, outside the object system entirely.  The dict
; holds its address as an int immediate, which owns nothing and is not
; traversed.

%include "macros.inc"
%include "object.inc"
%include "value.inc"

ASM_INIT

extern dict_get_str
extern dict_set_str
extern dict_new
extern dict_get
extern dict_set
extern dict_del
extern list_new
extern list_append
extern obj_decref
extern obj_try_incref
extern ap_malloc
extern ap_realloc
extern ap_free
extern v_int_bias
extern set_exception
extern exc_TypeError_type
extern type_check_is_class

; SubList lives in object.inc, with every other struct.

SUBLIST_INITIAL equ 4

section .bss
alignb 64
subclass_lock:   resd 1
alignb 8
subclass_table:  resq 1      ; base address (an int Value) -> SubList address
global subclass_live
subclass_live:   resq 1      ; the table's size, so obj_dealloc can skip with
                             ; one compare

section .text

;; ============================================================================
;; subclass_reset_after_fork() -> nothing
;; Reset subclass_lock in a forked child.
;; ============================================================================
global subclass_reset_after_fork
DEF_FUNC_BARE subclass_reset_after_fork
    mov dword [rel subclass_lock], 0
    ret
END_FUNC subclass_reset_after_fork

;; ============================================================================
;; sub_table_refresh() -- keep subclass_live equal to the table's size
;; ============================================================================
DEF_FUNC_LOCAL sub_table_refresh
    mov rax, [rel subclass_table]
    test rax, rax
    jz .empty
    mov rax, [rax + PyDictObject.ob_size]
    mov [rel subclass_live], rax
    leave
    ret
.empty:
    mov qword [rel subclass_live], 0
    leave
    ret
END_FUNC sub_table_refresh

;; ============================================================================
;; sub_list_for_type(rdi = a base type) -> rax = its SubList, or 0
;;
;; _abc_subclasscheck reads it directly for step 6, which is why it is global.
;; ============================================================================
global sub_list_for_type
DEF_FUNC sub_list_for_type, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rax, [rel subclass_table]
    test rax, rax
    jz .none
    mov rdi, rax
    mov rsi, rbx
    add rsi, [rel v_int_bias]   ; a user address always fits an int immediate
    call dict_get_str
    test rax, rax
    jz .none
    sub rax, [rel v_int_bias]   ; the SubList address, stored the same way
    pop rbx
    leave
    ret
.none:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC sub_list_for_type

;; ============================================================================
;; sub_list_add(rdi = a base type, rsi = the subclass)
;;
;; Records one edge.  The entry is BORROWED -- no INCREF -- which is what
;; makes __subclasses__ report live classes only, and what the SubList exists
;; for: see the header.
;; ============================================================================
SLA_BASE  equ 8
SLA_SUB   equ 16
SLA_LIST  equ 24
SLA_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL sub_list_add, SLA_FRAME
    mov [rbp - SLA_BASE], rdi
    mov [rbp - SLA_SUB], rsi

    call sub_list_for_type
    test rax, rax
    jnz .sla_have

    ; First subclass for this base: a SubList, and a table entry pointing at
    ; it.  The dict value is an int immediate, so the dict owns nothing here
    ; and the collector has nothing to walk.
    mov edi, SubList_size
    call ap_malloc
    mov [rbp - SLA_LIST], rax
    mov qword [rax + SubList.count], 0
    mov qword [rax + SubList.capacity], SUBLIST_INITIAL
    mov edi, SUBLIST_INITIAL * 8
    call ap_malloc
    mov rcx, [rbp - SLA_LIST]
    mov [rcx + SubList.items], rax

    mov rax, [rel subclass_table]
    test rax, rax
    jnz .sla_have_table
    call dict_new
    mov [rel subclass_table], rax
.sla_have_table:
    mov rdi, [rel subclass_table]
    mov rsi, [rbp - SLA_BASE]
    add rsi, [rel v_int_bias]
    mov rdx, [rbp - SLA_LIST]
    add rdx, [rel v_int_bias]
    call dict_set_str
    call sub_table_refresh
    mov rax, [rbp - SLA_LIST]

.sla_have:
    mov [rbp - SLA_LIST], rax
    mov rcx, [rax + SubList.count]
    cmp rcx, [rax + SubList.capacity]
    jl .sla_store
    ; A class with thousands of direct subclasses is not a shape worth tuning
    ; for, so doubling is the whole policy.
    shl qword [rax + SubList.capacity], 1
    mov rsi, [rax + SubList.capacity]
    shl rsi, 3
    mov rdi, [rax + SubList.items]
    call ap_realloc
    mov rcx, [rbp - SLA_LIST]
    mov [rcx + SubList.items], rax
.sla_store:
    mov rax, [rbp - SLA_LIST]
    mov rcx, [rax + SubList.count]
    mov rdx, [rax + SubList.items]
    mov r8, [rbp - SLA_SUB]
    mov [rdx + rcx*8], r8       ; borrowed, by design
    inc qword [rax + SubList.count]
    leave
    ret
END_FUNC sub_list_add

;; ============================================================================
;; subclass_register(rdi = the new type)
;;
;; Records it against each of its bases.  Called from type_from_parts once
;; tp_bases is set, and once at start-up for bool -- the one static subclass
;; in the tree, which CPython lists in int.__subclasses__().
;; ============================================================================
SR_TYPE  equ 8
SR_BASES equ 16
SR_IDX   equ 24
SR_FRAME equ 32             ; + 2 pushes = 48, 16-aligned
global subclass_register
DEF_FUNC subclass_register, SR_FRAME
    push rbx
    push r12
    mov [rbp - SR_TYPE], rdi
    RT_LOCK_GATED subclass_lock

    mov rax, [rdi + PyTypeObject.tp_bases]
    test rax, rax
    jnz .sr_have_bases

    ; A static type has no bases tuple, only tp_base.
    mov rdi, [rdi + PyTypeObject.tp_base]
    test rdi, rdi
    jz .sr_done
    mov rsi, [rbp - SR_TYPE]
    call sub_list_add
    jmp .sr_done

.sr_have_bases:
    mov [rbp - SR_BASES], rax
    mov qword [rbp - SR_IDX], 0
.sr_loop:
    mov rax, [rbp - SR_BASES]
    mov rcx, [rbp - SR_IDX]
    cmp rcx, [rax + PyTupleObject.ob_size]
    jge .sr_done
    mov rax, [rax + PyTupleObject.ob_item]
    mov rbx, [rax + rcx*8]      ; the base, as a Value
    inc qword [rbp - SR_IDX]
    V_TEST_PTR rbx, rax
    ja .sr_loop
    test rbx, rbx
    jz .sr_loop
    mov rdi, rbx
    mov rsi, [rbp - SR_TYPE]
    call sub_list_add
    jmp .sr_loop

.sr_done:
    RT_UNLOCK_GATED subclass_lock
    pop r12
    pop rbx
    leave
    ret
END_FUNC subclass_register

;; ============================================================================
;; subclass_unregister(rdi = a type about to be freed)
;;
;; Out of every list it appears in, and its own list freed if it had one.
;; Called from user_type_dealloc, which is the only thing keeping a freed
;; class out of __subclasses__().
;;
;; It scans the whole table rather than walking the dying class's tp_bases,
;; which would be the obvious thing and does not work: the bases tuple is
;; itself garbage in the same collection, and its items are cleared before
;; this runs -- so the class saw no bases at all, removed itself from
;; nothing, and left a dangling pointer that the next __subclasses__() call
;; increfed and then freed a second time.
;;
;; The scan is over bases-that-have-subclasses, not over all classes, and it
;; only runs for a class that is being freed while the table is non-empty.
;; ============================================================================
SU_TYPE  equ 8
SU_IDX   equ 16
SU_FRAME equ 32             ; + 2 pushes = 48, 16-aligned
global subclass_unregister
DEF_FUNC subclass_unregister, SU_FRAME
    push rbx
    push r12
    mov [rbp - SU_TYPE], rdi

    cmp qword [rel subclass_live], 0
    je .su_ret
    RT_LOCK_GATED subclass_lock
    cmp qword [rel subclass_live], 0
    je .su_done
    mov rbx, [rel subclass_table]
    test rbx, rbx
    jz .su_done

    mov qword [rbp - SU_IDX], 0
.su_slot:
    mov rcx, [rbp - SU_IDX]
    cmp rcx, [rbx + PyDictObject.capacity]
    jge .su_own
    mov rax, [rbx + PyDictObject.entries]
    imul rdx, rcx, DICT_ENTRY_SIZE
    lea rax, [rax + rdx]
    inc qword [rbp - SU_IDX]
    ENTRY_CLASSIFY rax, .su_slot, .su_slot

    mov r12, [rax + DictEntry.value]
    sub r12, [rel v_int_bias]   ; the SubList address
    mov rcx, [r12 + SubList.count]
.su_scan:
    dec rcx
    js .su_slot
    mov rdx, [r12 + SubList.items]
    mov r8, [rdx + rcx*8]
    cmp r8, [rbp - SU_TYPE]
    jne .su_scan
    ; Shift the tail down over it.  The entries are borrowed, so nothing is
    ; released.  A class appears once per base, so one pass per list is enough.
    mov r9, [r12 + SubList.count]
    dec r9
.su_shift:
    cmp rcx, r9
    jge .su_shrink
    mov rdx, [r12 + SubList.items]
    mov r8, [rdx + rcx*8 + 8]
    mov [rdx + rcx*8], r8
    inc rcx
    jmp .su_shift
.su_shrink:
    mov [r12 + SubList.count], r9
    jmp .su_slot

.su_own:
    ; Its own list, if it had one.  Ask first: dict_del RAISES KeyError on a
    ; missing key, and this runs inside a dealloc, where a raise abandons the
    ; C stack in the middle of a collection.  Most classes never have a
    ; subclass and so never have an entry.
    mov rdi, [rbp - SU_TYPE]
    call sub_list_for_type
    test rax, rax
    jz .su_done
    mov r12, rax
    mov rdi, [rel subclass_table]
    mov rsi, [rbp - SU_TYPE]
    add rsi, [rel v_int_bias]
    call dict_del             ; err: an int key in a table of ints, and sub_list_for_type just found it
    mov rdi, [r12 + SubList.items]
    call ap_free
    mov rdi, r12
    call ap_free
    call sub_table_refresh

.su_done:
    RT_UNLOCK_GATED subclass_lock
.su_ret:
    pop r12
    pop rbx
    leave
    ret
END_FUNC subclass_unregister

;; ============================================================================
;; sub_list_snapshot(rdi = a base type) -> rax = owned PyListObject* of live
;;   direct subclasses, or 0 when there are none
;;
;; Atomically snapshots the base's SubList under subclass_lock, pinning each
;; still-live subclass via obj_try_incref so dying types waiting in
;; subclass_unregister are skipped rather than resurrected.
;; ============================================================================
SLS_LIST  equ 8
SLS_SUBS  equ 16
SLS_IDX   equ 24
SLS_FRAME equ 32            ; + 2 pushes = 48, 16-aligned
global sub_list_snapshot
DEF_FUNC sub_list_snapshot, SLS_FRAME
    push rbx
    push r12
    cmp qword [rel subclass_live], 0
    je .sls_none
    RT_LOCK_GATED subclass_lock
    call sub_list_for_type
    test rax, rax
    jz .sls_unlock_none
    mov rcx, [rax + SubList.count]
    test rcx, rcx
    jz .sls_unlock_none
    mov [rbp - SLS_SUBS], rax
    mov rdi, rcx
    extern list_new_untracked
    call list_new_untracked
    mov [rbp - SLS_LIST], rax
    mov qword [rbp - SLS_IDX], 0
    xor ebx, ebx                ; output count
.sls_copy:
    mov rax, [rbp - SLS_SUBS]
    mov rcx, [rbp - SLS_IDX]
    cmp rcx, [rax + SubList.count]
    jge .sls_copy_done
    inc qword [rbp - SLS_IDX]
    mov rdx, [rax + SubList.items]
    mov r12, [rdx + rcx*8]
    test r12, r12
    jz .sls_copy
    mov rdi, r12
    call obj_try_incref
    test eax, eax
    jz .sls_copy
    mov rax, [rbp - SLS_LIST]
    mov rdx, [rax + PyListObject.ob_item]
    mov [rdx + rbx*8], r12
    inc rbx
    jmp .sls_copy
.sls_copy_done:
    mov rax, [rbp - SLS_LIST]
    mov [rax + PyListObject.ob_size], rbx
    RT_UNLOCK_GATED subclass_lock
    mov rdi, [rbp - SLS_LIST]
    extern gc_track
    call gc_track
    mov rax, [rbp - SLS_LIST]
    pop r12
    pop rbx
    leave
    ret
.sls_unlock_none:
    RT_UNLOCK_GATED subclass_lock
.sls_none:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC sub_list_snapshot

;; ============================================================================
;; type_method_subclasses(args, nargs) -> a new list of the direct subclasses
;;
;; type.__subclasses__().  _abc_subclasscheck's step 6 -- "was this registered
;; against a subclass of the ABC rather than against the ABC itself?" -- has no
;; way to ask without it, so issubclass(X, A) answered False for an X
;; registered against a subclass of A.
;; Fails: 0
;; ============================================================================
TMS_LIST  equ 8
TMS_SUBS  equ 16
TMS_IDX   equ 24
TMS_FRAME equ 32            ; + 2 pushes = 48, 16-aligned
global type_method_subclasses
DEF_FUNC type_method_subclasses, TMS_FRAME
    push rbx
    push r12
    cmp rsi, 1
    jne .tms_args
    mov rbx, [rdi]              ; the class
    mov rdi, rbx
    call type_check_is_class
    test eax, eax
    jz .tms_type

    mov rdi, rbx
    call sub_list_snapshot
    test rax, rax
    jnz .tms_done
    xor edi, edi
    call list_new

.tms_done:
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.tms_args:
    SET_EXC exc_TypeError_type, "__subclasses__() takes no arguments"
    jmp .tms_fail
.tms_type:
    SET_EXC exc_TypeError_type, "__subclasses__() requires a type"
.tms_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_method_subclasses
