; methods/list.asm - list and tuple methods
;
; Methods are registered into each type's tp_dict by methods_init, in
; methods_init.asm.  A method is name(PyObject *self, PyObject **args,
; int64_t nargs); args are borrowed, the result is a new reference.

%include "macros.inc"
%include "object.inc"
%include "listsort.inc"
extern str_type
extern ap_memcmp
extern obj_as_index
extern obj_as_slice_index
%include "opcodes.inc"

; External functions
extern get_iterator_opt
extern ap_malloc
extern ap_free
extern ap_realloc
extern ap_memcpy
extern ap_memmove
extern ap_strcmp
extern obj_decref
extern list_new
extern list_append
extern list_type
extern tuple_type
extern none_singleton
extern bool_true
extern bool_false
extern int_from_i64
extern eval_exception_unwind
extern obj_richcompare_bool
extern int_to_i64
extern raise_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_IndexError_type
extern int_type
extern list_sorting_error
extern list_reverse_values
extern obj_dealloc

; Set entry layout constants (must match set.asm)

; --- moved to a sibling file by the split ---

section .text

;; ############################################################################
;;                         LIST METHODS
;; ############################################################################

;; ============================================================================
;; list_method_append(args, nargs) -> None
;; args[0]=self, args[1]=item
;; ============================================================================
DEF_FUNC list_method_append

    mov rax, [rdi]          ; self (list)
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rax + PyListObject.ob_item], 0
    je list_sorting_error
    mov rsi, [rdi + 8]     ; item payload
    V_UNPACK rsi, rdx       ; args[1]
    mov rdi, rax
    V_PACK rsi, rdx         ; list_append takes a Value
    call list_append

    RET_NONE
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC list_method_append

;; ============================================================================
;; list_method_pop(args, nargs) -> removed item
;; args[0]=self, optionally args[1]=index (default: last)
;; ============================================================================
DEF_FUNC list_method_pop, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    mov rax, rdi            ; rax = args ptr
    mov rbx, [rax]          ; self (list)
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, rsi            ; nargs

    ; Get index
    cmp r12, 2
    jge .pop_idx
    ; Default: pop last element
    mov r13, [rbx + PyListObject.ob_size]
    dec r13                 ; index = size - 1
    jmp .pop_do

.pop_idx:
    mov rdi, [rax + 8]    ; args[1]
    V_UNPACK rdi, rdx       ; args[1]
    call obj_as_index       ; an index, so __index__ counts and a str does not
    mov r13, rax

    ; Handle negative index
    test r13, r13
    jns .pop_do
    add r13, [rbx + PyListObject.ob_size]

.pop_do:
    ; Bounds check
    test r13, r13
    jl .pop_error
    cmp r13, [rbx + PyListObject.ob_size]
    jge .pop_error

    ; Get the item (it already has refs from being in the list)
    mov rax, [rbx + PyListObject.ob_item]
    mov r12, [rax + r13 * 8]        ; payload to return
    V_UNPACK r12, rdx
    push rdx                        ; save tag on stack
    ; Don't DECREF since we're transferring ownership to caller

    ; Shift payloads down: memmove(&payloads[idx], &payloads[idx+1], (size-1-idx)*8)
    mov rax, [rbx + PyListObject.ob_item]
    lea rdi, [rax + r13 * 8]        ; dst = &payloads[idx]
    lea rsi, [rdi + 8]              ; src = &payloads[idx+1]
    mov rdx, [rbx + PyListObject.ob_size]
    sub rdx, r13
    dec rdx                         ; count = size - idx - 1
    shl rdx, 3                      ; bytes = count * 8
    jz .pop_shrink                  ; nothing to shift if popping last
    call ap_memmove

.pop_shrink:
    dec qword [rbx + PyListObject.ob_size]

    ; Return item (ownership transferred, no extra INCREF needed)
    mov rax, r12
    pop rdx                  ; item tag
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.pop_error:
    RAISE exc_IndexError_type, "pop index out of range"
END_FUNC list_method_pop

;; ============================================================================
;; list_method_insert(args, nargs) -> None
;; args[0]=self, args[1]=index, args[2]=item
;; ============================================================================
DEF_FUNC list_method_insert
    push rbx
    push r12
    push r13
    push r14

    mov rax, rdi            ; args (16-byte stride)
    mov rbx, [rax]          ; self = args[0]
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    push rax

    ; Get index
    mov rdi, [rax + 8]     ; args[1] payload (16B stride)
    V_UNPACK rdi, rdx       ; args[1]
    call obj_as_index       ; an index, so __index__ counts and a str does not
    mov r12, rax            ; index

    pop rax
    mov r13, [rax + 16]     ; item = args[2] payload (16B stride)
    V_UNPACK r13, r14       ; args[2]

    ; Clamp index to [0, size]
    test r12, r12
    jns .ins_pos
    add r12, [rbx + PyListObject.ob_size]
    test r12, r12
    jns .ins_pos
    xor r12d, r12d
.ins_pos:
    cmp r12, [rbx + PyListObject.ob_size]
    jle .ins_ok
    mov r12, [rbx + PyListObject.ob_size]
.ins_ok:

    ; First append a dummy to grow the list if needed
    ; (reuse list_append logic for growth, then shift)
    ; Actually, let's just handle growth manually:
    ; Check if size == allocated
    mov rax, [rbx + PyListObject.ob_size]
    cmp rax, [rbx + PyListObject.allocated]
    jl .ins_no_grow
    ; Double capacity
    mov rdi, [rbx + PyListObject.allocated]
    shl rdi, 1
    mov [rbx + PyListObject.allocated], rdi
    mov rdi, [rbx + PyListObject.ob_item]
    mov rsi, [rbx + PyListObject.allocated]
    shl rsi, 3              ; new_cap * 8
    call ap_realloc
    mov [rbx + PyListObject.ob_item], rax
.ins_no_grow:

    ; Shift items up: memmove(&items[idx+1], &items[idx], (size-idx)*8)
    mov rax, [rbx + PyListObject.ob_item]
    mov rcx, r12
    shl rcx, 3              ; idx * 8
    lea rsi, [rax + rcx]    ; src = &items[idx]
    lea rdi, [rsi + 8]      ; dst = &items[idx+1]
    mov rdx, [rbx + PyListObject.ob_size]
    sub rdx, r12            ; count = size - idx
    shl rdx, 3              ; bytes = count * 8
    jz .ins_place           ; nothing to shift if inserting at end
    call ap_memmove

.ins_place:
    ; Place item at index
    mov rax, [rbx + PyListObject.ob_item]
    INCREF_VAL r13, r14
    V_PACK r13, r14
    mov [rax + r12 * 8], r13
    inc qword [rbx + PyListObject.ob_size]

    RET_NONE
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC list_method_insert

;; ============================================================================
;; list_method_reverse(args, nargs) -> None
;; args[0]=self, reverse in place
;; ============================================================================
DEF_FUNC list_method_reverse
    ; No push: the body uses rax, rcx, rdi, rsi, r8 and r10, and the one exit
    ; that is not the `ret` below is a tail jump into list_sorting_error,
    ; which never returns.  rbx was saved and never read.
    mov rax, [rdi]          ; self
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rax + PyListObject.ob_item], 0
    je list_sorting_error
    mov rsi, [rax + PyListObject.ob_size]
    mov rdi, [rax + PyListObject.ob_item]
    call list_reverse_values
.rev_done:
    RET_NONE
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC list_method_reverse

;; ============================================================================
;; list_method_sort(args, nargs) -> None
;;
;; Everything AROUND the sort: the arity check, the two keywords, the key
;; array, emptying the list so that a re-entrant mutation is caught, and
;; putting it back.  The sort itself is timsort, in methods/list_sort.asm.
;;
;; What is sorted is the list's OWN ob_item array, in place, one Value per
;; element.  There is no conversion pass and no fat buffer: the previous
;; version allocated n x 16 bytes, V_UNPACKed every element into it, merged
;; sixteen-byte elements and packed the result back, which is the largest
;; single piece of (payload, tag) scaffolding that was left in the tree.
;;
;; With key=, the keys are a second array of the same length and the items
;; ride along as `values` -- CPython's sortslice, and the same reason for it:
;; the comparator only ever looks at a key, so a decorate-sort-undecorate
;; costs nothing at compare time.
;;
;; reverse= is TWO reversals, before and after, not a flag the inner loop
;; tests.  That is CPython's choice as well, and it is what keeps a stable
;; sort stable: reversing the input and the output leaves equal elements in
;; their original relative order, while flipping the comparison would not.
;; It also takes a compare out of every one of n log n comparisons.
;;
;; args[0] = self.
;; ============================================================================
LS_LIST    equ 8      ; the list
LS_N       equ 16     ; ob_size, taken before the list is emptied
LS_ITEMS   equ 24     ; the ob_item array, taken with it
LS_ALLOC   equ 32     ; and its capacity
LS_KEYS    equ 40     ; what is compared: LS_ITEMS, or the key array
LS_VALUES  equ 48     ; what rides along: 0, or LS_ITEMS
LS_KEY     equ 56     ; the key callable, or 0
LS_REV     equ 64     ; reverse=
LS_EXC     equ 72     ; current_exception on entry
LS_NK      equ 80     ; keys computed so far; the error path DECREFs them
;; The MergeState sits at the top of the frame, so that adding a scalar slot
;; above cannot silently overlap it.
LS_MS      equ 88 + MS_SIZE
LS_FRAME   equ LS_MS  ; + 5 pushes = 16-aligned
extern list_timsort
extern obj_call_n
extern obj_is_true
DEF_FUNC list_method_sort, LS_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; Both "did the sort raise" tests below used to read current_exception and
    ; compare it against zero.  That global is also the exception *being
    ; handled*, so inside any `except` block an ordinary L.sort() reported
    ; failure -- invisible until sorted() stopped discarding this function's
    ; return value.
    DUNDER_EXC_SAVE [rbp - LS_EXC]

    ; sort() takes no positional argument beyond self; only the keywords key
    ; and reverse.  nargs was never compared against anything, so
    ; l.sort(42, 42) was accepted.  The check has to be here rather than in
    ; add_method_to_dict_checked, which counts keyword values in nargs and
    ; would therefore reject l.sort(key=f).
    mov rax, rsi                ; nargs, self included
    mov rcx, [gs:ThreadState.kw_names_pending]
    test rcx, rcx
    jz .ls_have_npos
    sub rax, [rcx + PyTupleObject.ob_size]
.ls_have_npos:
    cmp rax, 1
    jg .ls_too_many

    mov rbx, [rdi]              ; self (list)
    mov r12, [rbx + PyListObject.ob_size]
    mov [rbp - LS_LIST], rbx
    mov [rbp - LS_N], r12
    mov qword [rbp - LS_REV], 0
    mov qword [rbp - LS_KEY], 0
    mov qword [rbp - LS_KEYS], 0
    mov qword [rbp - LS_VALUES], 0
    mov qword [rbp - LS_NK], 0

    ; --- Parse keyword arguments ---
    extern ap_strcmp
    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jz .ls_no_kw

    push rdi                       ; save args ptr
    push rsi                       ; save nargs

    mov rcx, [rax + PyTupleObject.ob_size]  ; n_kw
    mov r8, rsi
    sub r8, rcx                    ; r8 = n_pos
    xor r9d, r9d                   ; kw index

.ls_kw_loop:
    cmp r9, rcx
    jge .ls_kw_done

    ; Get kwarg name string ptr from kw_names tuple
    mov r10, r9
    mov rbx, [rax + PyTupleObject.ob_item]
    mov r10, [rbx + r10 * 8]

    ; Kwarg value offset: (n_pos + kw_idx) * 8
    mov r11, r8
    add r11, r9
    shl r11, 3

    ; --- Check "reverse" ---
    push rax
    push rcx
    push r8
    push r9
    push r11
    push rdi
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "reverse"
    call ap_strcmp
    mov r10d, eax
    pop rdi
    pop r11
    pop r9
    pop r8
    pop rcx
    pop rax
    test r10d, r10d
    jnz .ls_kw_not_reverse

    ; reverse= is any object, and its truth is obj_is_true's answer.  The test
    ; that used to be here compared the Value against bool_true, so
    ; `reverse=[1]` sorted forwards and `reverse=1.5` did too.
    push rax
    push rcx
    push r8
    push r9
    push r11
    push rdi
    mov rdi, [rdi + r11]
    call obj_is_true
    mov r10d, eax
    pop rdi
    pop r11
    pop r9
    pop r8
    pop rcx
    pop rax
    mov [rbp - LS_REV], r10
    jmp .ls_kw_next

.ls_kw_not_reverse:
    ; --- Check "key" ---
    ; r10 was clobbered by strcmp result above, reload kwarg name
    mov r10, r9
    mov rbx, [rax + PyTupleObject.ob_item]
    mov r10, [rbx + r10 * 8]
    push rax
    push rcx
    push r8
    push r9
    push r11
    push rdi
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "key"
    call ap_strcmp
    mov r10d, eax
    pop rdi
    pop r11
    pop r9
    pop r8
    pop rcx
    pop rax
    test r10d, r10d
    jnz .ls_kw_next                ; not "key" either, skip

    ; Extract key function value
    mov r10, [rdi + r11]           ; the key Value (a callable, so a pointer)
    ; key=None means no key function
    lea r14, [rel none_singleton]
    cmp r10, r14
    je .ls_kw_next
    mov [rbp - LS_KEY], r10

.ls_kw_next:
    inc r9
    jmp .ls_kw_loop

.ls_kw_done:
    pop rsi
    pop rdi
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov rbx, [rbp - LS_LIST]       ; reload list (clobbered by kw parsing)

.ls_no_kw:
    cmp r12, 2
    jb .ls_trivial

    ; --- Take the array away from the list ------------------------------
    ; ob_item == NULL is what every other list method tests to decide that a
    ; sort is in progress, so from here to the restore below any re-entrant
    ; append, pop, insert, clear, extend, remove or reverse raises.
    mov rax, [rbx + PyListObject.ob_item]
    mov [rbp - LS_ITEMS], rax
    mov [rbp - LS_KEYS], rax       ; with no key=, the items ARE the keys
    mov rax, [rbx + PyListObject.allocated]
    mov [rbp - LS_ALLOC], rax
    mov qword [rbx + PyListObject.ob_item], 0
    mov qword [rbx + PyListObject.ob_size], 0

    cmp qword [rbp - LS_KEY], 0
    jz .ls_keys_ready

    ; --- key=: a parallel array, computed before anything is compared ----
    mov rdi, r12
    shl rdi, 3
    call ap_malloc
    mov [rbp - LS_KEYS], rax
    mov rax, [rbp - LS_ITEMS]
    mov [rbp - LS_VALUES], rax     ; the items now ride along with their keys
    xor r15d, r15d
.ls_keys_loop:
    cmp r15, [rbp - LS_N]
    jae .ls_keys_ready
    mov rax, [rbp - LS_ITEMS]
    mov rdi, [rax + r15*8]
    sub rsp, 16                    ; one Value; 16 keeps rsp aligned
    mov [rsp], rdi                 ; args[0] = item
    ; The key, through obj_call_n: it takes a function, a builtin, a type or
    ; an instance with a __call__, and refuses anything else BY NAME.  The
    ; three-way tp_call dance that used to be here read a non-pointer key's
    ; Value as a type pointer -- `sorted([1, 2], key=0)` -- and called
    ; through a NULL tp_call for a type that has none.
    mov rdi, [rbp - LS_KEY]
    mov rsi, rsp                   ; args ptr -> &[item]
    mov edx, 1                     ; nargs = 1
    call obj_call_n
    add rsp, 16
    test rax, rax
    jz .ls_failed
    mov rcx, [rbp - LS_KEYS]
    mov [rcx + r15*8], rax
    inc r15
    mov [rbp - LS_NK], r15
    jmp .ls_keys_loop

.ls_keys_ready:
    ; --- reverse=, half of it -------------------------------------------
    cmp qword [rbp - LS_REV], 0
    jz .ls_run
    mov rdi, [rbp - LS_KEYS]
    mov rsi, [rbp - LS_N]
    call ls_reverse_array
    cmp qword [rbp - LS_VALUES], 0
    jz .ls_run
    mov rdi, [rbp - LS_VALUES]
    mov rsi, [rbp - LS_N]
    call ls_reverse_array

.ls_run:
    lea rdi, [rbp - LS_MS]
    mov rsi, [rbp - LS_KEYS]
    mov rdx, [rbp - LS_VALUES]
    mov rcx, [rbp - LS_N]
    call list_timsort
    cmp eax, -1
    je .ls_failed

    mov r13d, 1                    ; the sort itself succeeded
    jmp .ls_unwind
.ls_failed:
    xor r13d, r13d
.ls_unwind:
    ; --- the key array, whose contents are owned references --------------
    cmp qword [rbp - LS_KEY], 0
    jz .ls_no_keyarr
    mov r14, [rbp - LS_KEYS]
    xor r15d, r15d
.ls_free_keys:
    cmp r15, [rbp - LS_NK]
    jae .ls_free_keyarr
    mov rdi, [r14 + r15*8]
    push r14
    push r15
    DECREF_V rdi, rcx
    pop r15
    pop r14
    inc r15
    jmp .ls_free_keys
.ls_free_keyarr:
    mov rdi, r14
    call ap_free
.ls_no_keyarr:

    ; --- the other half of reverse=, on the items alone ------------------
    ; The keys are gone; only the array that goes back into the list is left
    ; to un-reverse.
    cmp qword [rbp - LS_REV], 0
    jz .ls_restore
    mov rdi, [rbp - LS_ITEMS]
    mov rsi, [rbp - LS_N]
    call ls_reverse_array

.ls_restore:
    ; --- did anything reach the list while it was empty? -----------------
    mov rbx, [rbp - LS_LIST]
    mov r14, [rbx + PyListObject.ob_item]   ; what the mutation left, if any
    mov r15, [rbx + PyListObject.ob_size]
    mov rax, [rbp - LS_ITEMS]
    mov [rbx + PyListObject.ob_item], rax
    mov rax, [rbp - LS_ALLOC]
    mov [rbx + PyListObject.allocated], rax
    mov rax, [rbp - LS_N]
    mov [rbx + PyListObject.ob_size], rax
    test r14, r14
    jnz .ls_mutated

    test r13d, r13d
    jz .ls_error_return
    RET_NONE
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.ls_mutated:
    ; Somebody put items into the list while the sort held its array.  Ours
    ; is back in place; theirs has to be released, element by element,
    ; because nothing else owns those references.
    xor ebx, ebx
.ls_mut_loop:
    cmp rbx, r15
    jae .ls_mut_done
    mov rdi, [r14 + rbx*8]
    DECREF_V rdi, rcx
    inc rbx
    jmp .ls_mut_loop
.ls_mut_done:
    mov rdi, r14
    call ap_free
    test r13d, r13d
    jz .ls_error_return          ; there is already an exception to report
    RAISE exc_ValueError_type, "list modified during sort"
    ; raise_exception does not return

.ls_trivial:
    ; n < 2 and nothing to sort -- but the KEY still runs, once per element.
    ; CPython computes them before it looks at the length, so `sorted([1],
    ; key=0)` is a TypeError there and was [1] here, and a key that raises
    ; was not called at all.
    cmp qword [rbp - LS_KEY], 0
    jz .ls_trivial_done
    cmp r12, 1
    jne .ls_trivial_done
    mov rax, [rbx + PyListObject.ob_item]
    test rax, rax
    jz .ls_trivial_done
    mov rdi, [rax]                 ; items[0], a Value
    sub rsp, 16
    mov [rsp], rdi
    mov rdi, [rbp - LS_KEY]
    mov rsi, rsp
    mov edx, 1
    call obj_call_n
    add rsp, 16
    test rax, rax
    jz .ls_error_return
    XDECREF_V rax, rcx             ; only whether it could be computed
.ls_trivial_done:
    RET_NONE
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.ls_error_return:
    ; Something raised -- a key, a comparison, or a __lt__ that mutated the
    ; list.  The array is already back where it belongs.
    EXC_RAISED_SINCE [rbp - LS_EXC], rax, .ls_error_have
    RAISE exc_ValueError_type, "sort failed"
.ls_error_have:
    RET_NULL
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.ls_too_many:
    RAISE exc_TypeError_type, "sort() takes no positional arguments"
END_FUNC list_method_sort

;; ============================================================================
;; ls_reverse_array(rdi = Value[], rsi = n) -> void
;;
;; reverse= is done by reversing the input and reversing the result, which is
;; what keeps the sort stable; this is both halves of it.  Values, so there is
;; no refcount traffic: the array owns exactly what it owned before.
;; ============================================================================
DEF_FUNC_LOCAL ls_reverse_array
    call list_reverse_values
    leave
    ret
END_FUNC ls_reverse_array

;; ============================================================================
;; list_method_index(args, nargs) -> SmallInt index
;; args[0]=self, args[1]=value, optional args[2]=start, args[3]=stop
;; Linear scan with identity check then __eq__ protocol
;; ============================================================================
LI_LIST   equ 8
LI_VPAY   equ 16   ; value payload
LI_IDX    equ 32
LI_SIZE   equ 40
LI_ARGS   equ 48   ; save args pointer
LI_NARGS  equ 56   ; save nargs
LI_FRAME  equ 64            ; + 2 pushes = 80, 16-aligned
DEF_FUNC list_method_index, LI_FRAME
    push rbx
    push r12

    mov [rbp - LI_ARGS], rdi  ; save args
    mov [rbp - LI_NARGS], rsi ; save nargs
    mov rax, [rdi]           ; self
    mov [rbp - LI_LIST], rax
    mov rax, [rdi + 8]      ; args[1], the value to find
    mov [rbp - LI_VPAY], rax    ; kept whole: obj_richcompare_bool takes a Value
    mov rcx, [rbp - LI_LIST]
    mov rcx, [rcx + PyListObject.ob_size]

    ; Default stop = list size
    mov [rbp - LI_SIZE], rcx

    ; Default start = 0
    mov qword [rbp - LI_IDX], 0

    ; Check for optional start arg (nargs >= 3)
    cmp qword [rbp - LI_NARGS], 3
    jl .li_have_bounds
    ; Get start from args[2]
    mov rax, [rbp - LI_ARGS]
    mov rdi, [rax + 16]      ; args[2] payload
    V_UNPACK rdi, rdx       ; args[2]
    call obj_as_slice_index
    ; Handle negative start
    test rax, rax
    jns .li_start_pos
    add rax, [rbp - LI_SIZE]  ; start += len
    test rax, rax
    jns .li_start_pos
    xor eax, eax              ; clamp to 0
.li_start_pos:
    mov [rbp - LI_IDX], rax

    ; Check for optional stop arg (nargs >= 4)
    cmp qword [rbp - LI_NARGS], 4
    jl .li_have_bounds
    ; Get stop from args[3]
    mov rax, [rbp - LI_ARGS]
    mov rdi, [rax + 24]      ; args[3] payload
    V_UNPACK rdi, rdx       ; args[3]
    call obj_as_slice_index
    ; Handle negative stop
    test rax, rax
    jns .li_stop_pos
    add rax, [rbp - LI_SIZE]  ; stop += len
    test rax, rax
    jns .li_stop_pos
    xor eax, eax              ; clamp to 0
.li_stop_pos:
    ; Clamp stop to list size
    mov rcx, [rbp - LI_LIST]
    mov rcx, [rcx + PyListObject.ob_size]
    cmp rax, rcx
    jle .li_stop_ok
    mov rax, rcx
.li_stop_ok:
    mov [rbp - LI_SIZE], rax

.li_have_bounds:

.index_loop:
    mov rax, [rbp - LI_IDX]
    cmp rax, [rbp - LI_SIZE]
    jge .index_not_found
    ; Re-read the size: an element's __eq__ can shorten the list.
    mov rbx, [rbp - LI_LIST]
    cmp rax, [rbx + PyListObject.ob_size]
    jge .index_not_found

    mov rbx, [rbx + PyListObject.ob_item]
    mov rdi, [rbx + rax * 8]    ; the element Value

    ; Was a hand-rolled type switch feeding tp_richcompare, with a NULL
    ; result meaning "no match" -- so NotImplemented never tried the
    ; reflected operand and a raising __eq__ was reported as absence.
    mov rsi, [rbp - LI_VPAY]
    VALUE_EQ_FAST rdi, rsi, rdx, .index_found, .index_next
    mov edx, PY_EQ
    call obj_richcompare_bool
    cmp eax, -1
    je .index_error
    test eax, eax
    jnz .index_found

.index_next:
    inc qword [rbp - LI_IDX]
    jmp .index_loop

.index_found:
    mov rdi, [rbp - LI_IDX]
    call int_from_i64
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.index_error:
    leave
    jmp eval_exception_unwind

.index_not_found:
    ; CPython names the value it could not find, through its repr.
    mov rsi, [rbp - LI_VPAY]
    CSTRING rdx, " is not in list"
    CSTRING rdi, ""
    extern raise_value_error_with_repr2
    jmp raise_value_error_with_repr2
END_FUNC list_method_index

;; ============================================================================
;; list_method_count(args, nargs) -> SmallInt
;; args[0]=self, args[1]=value
;; ============================================================================
LC_IDX    equ 8
LC_FRAME  equ 16            ; + 4 pushes = 48, 16-aligned

DEF_FUNC list_method_count, LC_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov rbx, [rdi]          ; self
    mov r12, [rdi + 8]      ; the value Value
    xor r14d, r14d          ; count = 0
    mov qword [rbp - LC_IDX], 0

.count_loop:
    mov rcx, [rbp - LC_IDX]
    ; The size is re-read every pass: an element's __eq__ can shorten the
    ; list under us.
    mov r13, [rbx + PyListObject.ob_size]
    cmp rcx, r13
    jge .count_done

    mov rax, [rbx + PyListObject.ob_item]
    mov rdi, [rax + rcx * 8]    ; the element Value
    mov rsi, r12
    VALUE_EQ_FAST rdi, rsi, rdx, .count_hit, .count_next
    mov edx, PY_EQ
    call obj_richcompare_bool
    cmp eax, -1
    je .count_error
    test eax, eax
    jz .count_next
.count_hit:
    inc r14

.count_next:
    inc qword [rbp - LC_IDX]
    jmp .count_loop

.count_done:
    mov rdi, r14
    call int_from_i64
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.count_error:
    leave
    jmp eval_exception_unwind
END_FUNC list_method_count

;; ============================================================================
;; list_method_copy(args, nargs) -> new list (shallow copy)
;; args[0]=self
;; ============================================================================
DEF_FUNC list_method_copy, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    ; list_copy, in src/pyo/list.asm, is one ap_memcpy and one INCREF loop.
    ; This used to be list_new plus a `call list_append` per element, with a
    ; push and a pop around each call -- two implementations of a shallow
    ; copy, and the method used the slow one.  list_append was 34.7% of a
    ; .copy() loop.
    mov rdi, [rdi]          ; self
    extern list_copy
    call list_copy
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC list_method_copy

;; ============================================================================
;; list.__getitem__(self, key) → calls list_subscript
;; ============================================================================
extern list_subscript
;; ============================================================================
;; tuple dunders.  tuple_type.tp_dict held only index and count, so
;; hasattr((1,), '__getitem__') was False and the operators worked solely
;; through the type slots -- which is what CPython's seq_tests probes.
;; ============================================================================
extern tuple_subscript

extern tuple_contains


extern tuple_concat

extern tuple_repeat


DEF_FUNC_BARE list_dunder_getitem
    REQUIRE_SELF_BARE list_type, "__getitem__"
    mov rax, [rdi]          ; self
    mov rsi, [rdi + 8]     ; key payload
    mov rdi, rax
    jmp list_subscript
END_FUNC list_dunder_getitem

;; ============================================================================
;; list.__setitem__(self, key, value) → calls list_ass_subscript
;; ============================================================================
extern list_ass_subscript
DEF_FUNC list_dunder_setitem
    REQUIRE_SELF list_type, "__setitem__"
    mov rax, [rdi]          ; self
    mov rsi, [rdi + 8]      ; args[1] = key   (already a Value)
    mov rdx, [rdi + 16]     ; args[2] = value (already a Value)
    mov rdi, rax
    call list_ass_subscript
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    leave
    ret
END_FUNC list_dunder_setitem

;; ============================================================================
;; list.__delitem__(self, key) → calls list_ass_subscript with NULL value
;; ============================================================================
DEF_FUNC list_dunder_delitem
    REQUIRE_SELF list_type, "__delitem__"
    mov rax, [rdi]          ; self
    mov rsi, [rdi + 8]     ; key payload
    xor edx, edx            ; a NULL value Value means "delete"
    mov rdi, rax
    call list_ass_subscript
    extern none_singleton
    RET_NONE
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC list_dunder_delitem

;; ============================================================================
;; list.__contains__(self, item) → calls list_contains
;; ============================================================================
extern list_contains
DEF_FUNC list_dunder_contains
    REQUIRE_SELF list_type, "__contains__"
    mov rax, [rdi]          ; self
    mov rsi, [rdi + 8]     ; item payload
    mov rdi, rax
    call list_contains
    ; eax = 0 or 1 → return bool
    test eax, eax
    jz .ldc_false
    extern bool_true
    lea rax, [rel bool_true]
    jmp .ldc_done
.ldc_false:
    extern bool_false
    lea rax, [rel bool_false]
.ldc_done:
    mov edx, TAG_PTR
    INCREF rax
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC list_dunder_contains

;; ============================================================================
;; list.__len__(self) → returns SmallInt length
;; ============================================================================
DEF_FUNC list_dunder_len
    REQUIRE_SELF list_type, "__len__"
    mov rax, [rdi]          ; self
    mov rax, [rax + PyListObject.ob_size]
    mov rdi, rax
    call int_from_i64
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC list_dunder_len

;; ============================================================================
;; list.__iadd__(self, other) → calls list_inplace_concat
;; ============================================================================
extern list_inplace_concat
DEF_FUNC_BARE list_dunder_iadd
    REQUIRE_SELF_BARE list_type, "__iadd__"
    ; Both operands go through as VALUES: list_inplace_concat unpacks them
    ; itself, and unpacking here first left an immediate's payload where a
    ; Value belonged -- `[1].__iadd__(0)` named no type at all, because the
    ; payload of 0 is 0 and nothing has that type.
    mov rax, [rdi]          ; self
    mov rsi, [rdi + 8]      ; other
    mov rdi, rax
    jmp list_inplace_concat
END_FUNC list_dunder_iadd

;; ============================================================================
;; list.__init__(self, [iterable]) → re-initialize list
;; Uses list_extend to populate from iterable after clearing.
;; ============================================================================
;; ============================================================================
;; container_dunder_new(args, nargs) -> a new empty instance of args[0]
;;
;; list, tuple, dict and set had no __new__ in their type dicts, so
;; super().__new__(cls, seq) inside a subclass's own __new__ found nothing.
;; It is registered as a staticmethod, as CPython does: __new__ takes the
;; class explicitly and must not be bound to anything.
;; ============================================================================
extern instance_new
extern builtin_sub_init_base
extern tuple_sub_fill
extern set_sub_fill
extern frozenset_type
extern type_is_subtype
DEF_FUNC container_dunder_new, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    test rsi, rsi
    jz .cdn_error
    mov rbx, [rdi]              ; cls
    mov r12, rdi                ; args
    mov r13, rsi                ; nargs

    V_TEST_PTR rbx, rax
    ja .cdn_error

    mov rdi, rbx
    call instance_new
    push rax
    mov rdi, rax
    call builtin_sub_init_base
    pop rax

    ; tuple is immutable, so its contents arrive here rather than through
    ; __init__.
    mov rcx, [rbx + PyTypeObject.tp_flags]
    test rcx, TYPE_FLAG_TUPLE_SUBCLASS
    jz .cdn_check_frozen
    push rax
    mov rdi, rax
    lea rsi, [r12 + 8]          ; the arguments after cls
    lea rdx, [r13 - 1]
    call tuple_sub_fill
    pop rax
    jmp .cdn_done

.cdn_check_frozen:
    ; frozenset is immutable for the same reason and has to arrive the same
    ; way: it has no __init__, as CPython's has none.  A SET subclass does,
    ; and fills there, so only the frozen side is served here -- the subclass
    ; flag is on both types and the MRO is what tells them apart.
    mov rcx, [rbx + PyTypeObject.tp_flags]
    test rcx, TYPE_FLAG_SET_SUBCLASS
    jz .cdn_done
    push rax
    mov rdi, rbx
    lea rsi, [rel frozenset_type]
    call type_is_subtype
    test eax, eax
    jz .cdn_not_frozen
    mov rdi, [rsp]
    lea rsi, [r12 + 8]          ; the arguments after cls
    lea rdx, [r13 - 1]
    call set_sub_fill
.cdn_not_frozen:
    pop rax

.cdn_done:
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.cdn_error:
    RAISE exc_TypeError_type, "__new__() takes a class argument"
END_FUNC container_dunder_new

;; ============================================================================
;; list_dunder_init(args, nargs) -> None    -- list.__init__
;;
;; `list()` takes no keyword arguments, and CPython refuses them here with one
;; carve-out that its generated code spells out: the refusal applies only when
;; the receiver IS a list, or when its type has not overridden __new__.  A
;; subclass with its own __new__ has already absorbed the keywords, and list's
;; init is then entitled to ignore whatever is left -- `WithNew([1, 2],
;; newarg=3)` works in CPython and has to work here.
;;
;; The keyword VALUES sit in the argument array after the positional ones, so
;; where they are ignored the count comes down by as many; otherwise the first
;; of them would be read as the iterable.
;; ============================================================================
LDI_ARGS  equ 8
LDI_NARGS equ 16
LDI_OWNER equ 24
LDI_FRAME equ 32            ; + 2 pushes = 48, 16-aligned
DEF_FUNC list_dunder_init, LDI_FRAME
    push rbx
    push r12

    mov rbx, rdi            ; save args ptr
    mov r12, rsi            ; save nargs

    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jz .ldi_kw_done
    mov qword [gs:ThreadState.kw_names_pending], 0     ; consumed, whichever way this goes
    mov rcx, [rax + PyTupleObject.ob_size]
    sub r12, rcx                            ; the positional count alone

    mov rax, [rbx]                          ; self
    mov rax, [rax + PyObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .ldi_no_keywords                     ; the receiver IS a list

    mov [rbp - LDI_ARGS], rbx
    mov [rbp - LDI_NARGS], r12
    mov qword [rbp - LDI_OWNER], 0
    mov rdi, rax
    CSTRING rsi, "__new__"
    lea rdx, [rbp - LDI_OWNER]
    extern dunder_lookup_owner
    call dunder_lookup_owner
    mov rax, [rbp - LDI_OWNER]              ; the type whose dict answered
    mov rbx, [rbp - LDI_ARGS]
    mov r12, [rbp - LDI_NARGS]
    test rax, rax
    jz .ldi_no_keywords
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .ldi_no_keywords                     ; still list's own __new__
.ldi_kw_done:

    ; self = args[0]
    mov rax, [rbx]          ; self (list)

    ; Clear: DECREF all items, set size to 0
    push rax
    mov rcx, [rax + PyListObject.ob_size]
    test rcx, rcx
    jz .ldi_cleared
    ; Simple clear: just set size to 0 (items leak but safe for now)
    mov qword [rax + PyListObject.ob_size], 0
.ldi_cleared:
    pop rax

    ; If nargs >= 2, use list_extend to add items from args[1]
    cmp r12, 2
    jl .ldi_done

    ; Build args for list_extend: args[0]=self, args[1]=iterable
    ; Our args are already in the right format: [self, iterable, ...]
    mov rdi, rbx            ; args ptr (already has self + iterable)
    mov esi, 2                      ; nargs = 2
    call list_method_extend

.ldi_done:
    RET_NONE
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.ldi_no_keywords:
    RAISE exc_TypeError_type, "list() takes no keyword arguments"
END_FUNC list_dunder_init

;; ============================================================================
;; list_method_clear(args, nargs) -> None
;; args[0]=self
;; ============================================================================
DEF_FUNC list_method_clear, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    push r12
    push r13

    mov rbx, [rdi]          ; self
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, [rbx + PyListObject.ob_size]

    ; DECREF all items (fat 16-byte slots)
    xor r13d, r13d
.clear_loop:
    cmp r13, r12
    jge .clear_done
    mov rax, [rbx + PyListObject.ob_item]
    mov rdi, [rax + r13 * 8]    ; payload
    V_UNPACK rdi, rsi
    push r13
    DECREF_VAL rdi, rsi
    pop r13
    inc r13
    jmp .clear_loop

.clear_done:
    mov qword [rbx + PyListObject.ob_size], 0

    RET_NONE
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC list_method_clear

;; ============================================================================
;; list_method_extend(args, nargs) -> None
;; args[0]=self, args[1]=iterable (list, tuple, or generic iterable)
;; ============================================================================
LE_SELF   equ 8
LE_ITER   equ 16
LE_EXC    equ 24            ; current_exception before the iteration started
LE_FRAME  equ 24            ; + 3 pushes = 48, 16-aligned
DEF_FUNC list_method_extend, LE_FRAME
    push rbx
    push r12
    push r13

    mov rbx, [rdi]           ; self
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, [rdi + 8]      ; iterable payload
    V_UNPACK r12, r13       ; args[1]
    mov [rbp - LE_SELF], rbx

    ; Check iterable type for fast paths
    test r13d, TAG_RC_BIT
    jz .extend_generic         ; non-pointer → must use generic iter

    mov rax, [r12 + PyObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .extend_list
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .extend_tuple

    ; Generic iterable path
    jmp .extend_generic

    ; A list and a tuple are the same shape here -- a contiguous Value array
    ; and a size -- so both go to list_extend_from_array, which grows once
    ; and copies once.  Each used to call list_append per element, and
    ; l.extend(l) is why that helper handles a source that is the
    ; destination's own array.
.extend_list:
    mov rdx, [r12 + PyListObject.ob_size]
    mov rsi, [r12 + PyListObject.ob_item]
    jmp .extend_from_array

.extend_tuple:
    mov rdx, [r12 + PyTupleObject.ob_size]
    mov rsi, [r12 + PyTupleObject.ob_item]

.extend_from_array:
    mov rdi, [rbp - LE_SELF]
    extern list_extend_from_array
    call list_extend_from_array
    jmp .extend_done

.extend_generic:
    ; get_iterator_opt, not a tp_iter read: an object with __getitem__
    ; and no __iter__ is iterable, and the slot read rejected it.
    test r13d, TAG_RC_BIT
    jz .extend_type_error       ; a non-pointer is never iterable
    mov rdi, r12
    mov esi, TAG_PTR
    call get_iterator_opt
    test rax, rax
    jz .extend_type_error
    mov [rbp - LE_ITER], rax

    DUNDER_EXC_SAVE [rbp - LE_EXC]
.extend_iter_loop:
    mov rdi, [rbp - LE_ITER]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .extend_iter_done
    mov rdi, [rbp - LE_ITER]
    call rax                    ; tp_iternext(iter) → (payload, tag)
    V_UNPACK rax, rdx           ; tp_iternext returns a Value
    test edx, edx
    jz .extend_iter_done        ; StopIteration

    ; Append item to list
    push rax
    push rdx
    mov rdi, [rbp - LE_SELF]
    mov rsi, rax
    ; edx = tag (already set)
    V_PACK rsi, rdx         ; list_append takes a Value
    call list_append
    ; DECREF item (list_append INCREFs internally)
    pop rsi                     ; tag
    pop rdi                     ; payload
    DECREF_VAL rdi, rsi
    jmp .extend_iter_loop

.extend_iter_done:
    ; DECREF iterator
    mov rdi, [rbp - LE_ITER]
    call obj_decref

    ; NULL means exhausted or raised, and only the pending exception says
    ; which: L.extend(G()) for a raising __getitem__ appended a short run and
    ; answered None.
    EXC_RAISED_SINCE [rbp - LE_EXC], rcx, .extend_iter_raised
    jmp .extend_done            ; nothing pending: an ordinary exhaustion

.extend_iter_raised:
    xor eax, eax                ; a NULL Value, with the exception pending
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    leave
    ret

.extend_done:
    RET_NONE
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.extend_type_error:
    ; The METHOD's wording, which is not the opcode's: CPython says
    ; "'int' object is not iterable" here and "Value after * must be an
    ; iterable, not int" for the `*x` that LIST_EXTEND compiles from.  The
    ; type comes from the TAG, because an int or a float has no ob_type.
    extern int_type
    extern float_type
    lea rsi, [rel int_type]
    cmp r13d, TAG_PTR
    je .lme_ptr_type
    cmp r13d, TAG_FLOAT
    jne .lme_have_type
    lea rsi, [rel float_type]
    jmp .lme_have_type
.lme_ptr_type:
    mov rsi, [r12 + PyObject.ob_type]
.lme_have_type:
    CSTRING rdi, `'\x01' object is not iterable`
    extern raise_type_error_with_typename
    jmp raise_type_error_with_typename
END_FUNC list_method_extend

;; ============================================================================
;; list_method_remove(args, nargs) -> None
;; args[0]=self, args[1]=value
;; Removes first occurrence of value. Raises ValueError if not found.
;; ============================================================================
DEF_FUNC list_method_remove, 8            ; 5 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, [rdi]          ; self (list)
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, [rdi + 8]      ; the value Value
    xor r14d, r14d          ; index = 0

.lremove_loop:
    ; Re-read the size each pass: an element's __eq__ can shorten the list.
    mov r13, [rbx + PyListObject.ob_size]
    cmp r14, r13
    jge .lremove_not_found

    mov rax, [rbx + PyListObject.ob_item]
    mov rdi, [rax + r14 * 8]    ; the element Value

    ; Was a hand-rolled type switch feeding tp_richcompare, treating a NULL
    ; result as "no match" -- so NotImplemented never reached the reflected
    ; operand and a raising __eq__ became a ValueError about absence.
    mov rsi, r12
    VALUE_EQ_FAST rdi, rsi, rdx, .lremove_found, .lremove_next
    mov edx, PY_EQ
    call obj_richcompare_bool
    cmp eax, -1
    je .lremove_error
    test eax, eax
    jnz .lremove_found

.lremove_next:
    inc r14
    jmp .lremove_loop

.lremove_error:
    leave
    jmp eval_exception_unwind

.lremove_found:
    ; r14 = index of found item
    ; Get the item for DECREF
    mov rax, [rbx + PyListObject.ob_item]
    mov r12, [rax + r14 * 8]        ; the item Value

    ; Shift payloads left: memmove(&payloads[idx], &payloads[idx+1], (size-1-idx)*8)
    mov rax, [rbx + PyListObject.ob_item]
    lea rdi, [rax + r14 * 8]
    lea rsi, [rdi + 8]
    mov rdx, [rbx + PyListObject.ob_size]
    sub rdx, r14
    dec rdx                 ; count = size - idx - 1
    shl rdx, 3              ; bytes = count * 8
    jz .lremove_shrink      ; nothing to shift if removing last
    call ap_memmove

.lremove_shrink:
    dec qword [rbx + PyListObject.ob_size]

    ; DECREF the removed item
    mov rdi, r12
    DECREF_V rdi, rsi

    ; Return None
    RET_NONE
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.lremove_not_found:
    RAISE exc_ValueError_type, "list.remove(x): x not in list"
END_FUNC list_method_remove

;; ============================================================================
;; list_method_reversed(args, nargs) -> reversed iterator
;; args[0]=self
;; ============================================================================
extern reversed_iter_type
DEF_FUNC list_method_reversed, 8            ; 1 push, so rsp is 16-aligned
    push rbx

    mov rbx, [rdi]            ; self (list)

    ; Allocate ReversedIterObject (32 bytes: refcnt, type, it_seq, it_index).
    ; gc_alloc, and tracked: this is the same type builtin_reversed makes, it
    ; holds the sequence it walks, and a list can hold the iterator back.
    ; Allocating it with ap_malloc while its tp_dealloc frees it with
    ; gc_dealloc handed free() a pointer sixteen bytes past the block.
    mov edi, 32
    lea rsi, [rel reversed_iter_type]
    extern gc_alloc
    call gc_alloc

    mov [rax + 16], rbx       ; it_seq = self
    INCREF rbx
    mov rcx, [rbx + PyListObject.ob_size]
    dec rcx                   ; it_index = ob_size - 1
    mov [rax + 24], rcx

    push rax
    mov rdi, rax
    extern gc_track
    call gc_track
    pop rax

    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC list_method_reversed


