; opcodes/unpack.asm - UNPACK_SEQUENCE and UNPACK_EX
;
; The two opcodes behind `a, b = x` and `a, *b, c = x`, and the ValueError
; they share.  Split out of opcodes/build.asm, which had reached the 100k cap
; for a hand-written file; the seam is the one it already had -- these two
; are the only handlers in it that take a sequence APART, and the only ones
; that answer for a length.
;
; Register convention (callee-saved, preserved across handlers):
;   rbx = bytecode instruction pointer (current position in co_code[])
;   r12 = current frame pointer (PyFrame*)
;   r13 = value stack payload top pointer
;
; ecx = opcode argument on entry (set by eval_dispatch)
; rbx has already been advanced past the 2-byte instruction word.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

section .text

extern obj_dealloc
extern opcode_dispatch_table
extern dict_type
extern eval_dispatch
extern eval_exception_unwind
extern exc_TypeError_type
extern exc_ValueError_type
extern get_iterator_opt
extern list_append
extern list_new
extern list_type
extern obj_decref
extern raise_exception
extern set_type
extern str_new
extern str_type
extern tuple_type
extern raise_type_error_with_typename
extern int_type
extern float_type

;; ============================================================================
;; op_unpack_sequence(ecx = count) -> DISPATCH, or unwinds
;;
;; ecx = count
;; Pop TOS (tuple/list/str), push items[count-1], ..., items[0] (reverse order)
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
extern str_new
extern str_type
DEF_FUNC_BARE op_unpack_sequence
    ; Specialize, then run generically this time.  A tuple or a list is the
    ; shape the compiler emits this opcode for almost every time -- every
    ; `a, b = ...` over a literal, a return of several values, a dict item.
    ; The length is not checked here: the specialized handler checks it on
    ; every execution anyway, and a site that unpacks a different length each
    ; time would otherwise never specialize at all.
    mov r8, [r13 - 8]
    V_TEST_PTR r8, r9
    ja .us_no_spec
    mov r8, [r8 + PyObject.ob_type]
    lea r9, [rel tuple_type]
    cmp r8, r9
    je .us_spec_tuple
    lea r9, [rel list_type]
    cmp r8, r9
    jne .us_no_spec
    mov byte [rbx - 2], OP_UNPACK_SEQUENCE_LIST
    jmp .us_no_spec
.us_spec_tuple:
    mov byte [rbx - 2], OP_UNPACK_SEQUENCE_TUPLE
.us_no_spec:

    VPOP_VAL rdi, r8           ; rdi = sequence (tuple or list), r8 = tag
    cmp r8d, TAG_PTR
    jne .unpack_type_error

    ; Determine if tuple or list and get item array + size.
    ;
    ; Three saved words, and the third is the one that matters: the
    ; materialising path below builds a tuple out of an arbitrary iterable,
    ; and that tuple is ours to release, while the original is not -- the
    ; unwinder releases the original for us if this instruction raises.  The
    ; slot holds the tuple, or 0 when there is none.
    push r8                    ; [rsp+16] save tag
    push rdi                   ; [rsp+8]  save payload
    push 0                     ; [rsp]    the materialised tuple, or 0

    mov rax, [rdi + PyObject.ob_type]

    extern tuple_type
    lea rdx, [rel tuple_type]
    cmp rax, rdx
    je .unpack_tuple

    extern list_type
    lea rdx, [rel list_type]
    cmp rax, rdx
    je .unpack_list

    lea rdx, [rel str_type]
    cmp rax, rdx
    je .unpack_str

    ; CPython's guard, and its wording with it: an object with neither a
    ; tp_iter nor an sq_item cannot be iterated at all, and the refusal names
    ; the type -- "cannot unpack non-iterable NoneType object" -- rather than
    ; letting the constructor below speak for it.  op_unpack_ex's generic arm
    ; already answered this way; this one said "'NoneType' object is not
    ; iterable", which is tuple()'s message and not this statement's.
    cmp qword [rax + PyTypeObject.tp_iter], 0
    jne .unpack_generic
    mov rdx, [rax + PyTypeObject.tp_as_sequence]
    test rdx, rdx
    jz .unpack_check_mapping
    cmp qword [rdx + PySequenceMethods.sq_item], 0
    jne .unpack_generic
.unpack_check_mapping:
    ; A class that defines __getitem__ and no __iter__ is iterable through the
    ; legacy protocol, and get_iterator_opt honours it.  Here that shows as
    ; mp_subscript rather than sq_item, so asking only about sq_item -- which
    ; is what CPython's PySequence_Check asks -- refused a class whose
    ; __getitem__ was the whole point.
    mov rdx, [rax + PyTypeObject.tp_as_mapping]
    test rdx, rdx
    jz .unpack_not_iterable
    cmp qword [rdx + PyMappingMethods.mp_subscript], 0
    jne .unpack_generic
.unpack_not_iterable:
    mov esi, TAG_PTR
    jmp unpack_bad_type

.unpack_generic:
    ; Anything iterable unpacks in Python -- a set, a range, a generator, a
    ; dict, a str subclass.  Only exact tuple, list and str were accepted, so
    ; `a, b = {1, 2}` and `a, b = range(2)` raised.
    ; Stack here: [rsp] = the materialised tuple slot, [rsp+8] = payload,
    ; [rsp+16] = tag.
    push rcx                        ; expected count
    sub rsp, 32                     ; scratch Value slot, and the pad that
                                    ; makes rsp aligned here: three prologue
                                    ; pushes plus this one is an ODD number of
                                    ; slots, and the old comment said 24 kept
                                    ; it aligned when it left it 8 out
    mov [rsp], rdi
    lea rsi, [rsp]
    extern tuple_type_call
    lea rdi, [rel tuple_type]
    mov edx, 1
    call tuple_type_call            ; raises for a non-iterable
    add rsp, 32
    pop rcx                         ; expected count
    test rax, rax
    jz .unpack_iter_raised
    ; The original stays in its saved slot: it is what the unwinder releases
    ; if the count then turns out to be wrong.  The tuple goes in the third
    ; slot, and is released on both ways out.
    mov [rsp], rax
    mov rdi, rax
    jmp .unpack_tuple


.unpack_iter_raised:
    ; tuple_type_call answers NULL when the iteration itself raised -- a
    ; __getitem__ or __next__ that threw partway through.  Reading ob_type off
    ; that NULL is how `a, b, c = G()` became a segfault instead of the
    ; exception G raised.
    ;
    ; The sequence is NOT released here.  The unwinder restores r13 from
    ; PyFrame.disp_sp, which is the value stack as it stood before this
    ; instruction ran -- so the sequence VPOP_VAL took off the top is back on
    ; it, and the unwind releases it.  Decref'ing it here as well frees it
    ; while the unwinder is still holding it, which valgrind reports as an
    ; invalid read inside eval_exception_unwind.
    add rsp, 24                     ; the three words the prologue pushed
    extern eval_exception_unwind
    jmp eval_exception_unwind

.unpack_type_error:
    ; rdi = payload, r8 = tag; unpack_bad_type names the type CPython names.
    mov rsi, r8
    jmp unpack_bad_type

.unpack_tuple:
    ; Validate count matches size
    mov r8, [rdi + PyTupleObject.ob_size]
    cmp rcx, r8
    jne .unpack_count_error
    ; Items are in payload/tag arrays
    mov rsi, [rdi + PyTupleObject.ob_item]
    jmp .unpack_fill

.unpack_list:
    ; Validate count matches size
    mov r8, [rdi + PyListObject.ob_size]
    cmp rcx, r8
    jne .unpack_count_error
    ; Items in payload/tag arrays
    mov rsi, [rdi + PyListObject.ob_item]

.unpack_fill:
    ; Pre-advance stack by count (ecx)
    mov edx, ecx
    shl edx, 3
    add r13, rdx              ; stack += count * 8
    ; r10 = negative offset from the pre-advanced pointer, starts at -count
    mov r10, rcx
    neg r10
    mov edx, ecx
    dec edx                    ; edx = source index (count-1 down to 0)
.unpack_fill_loop:
    test edx, edx
    js .unpack_done
    mov eax, edx
    mov rax, [rsi + rax * 8]  ; items[edx] is already a Value
    INCREF_V rax, r9
    mov [r13 + r10*8], rax
    inc r10
    dec edx
    jmp .unpack_fill_loop

.unpack_done:
    ; Release the materialised tuple, if the iterable path built one, and then
    ; the sequence itself (payload + tag).
    pop rdi
    test rdi, rdi
    jz .unpack_done_seq
    call obj_decref
.unpack_done_seq:
    pop rdi                    ; sequence payload
    pop rsi                    ; sequence tag
    DECREF_VAL rdi, rsi

    ; Skip 1 CACHE entry = 2 bytes
    add rbx, 2
    DISPATCH

.unpack_count_error:
    ; Count mismatch: rcx expected, r8 actually there.  The two directions get
    ; different messages, and both carry the counts.
    ;
    ; The sequence is NOT released here, for the reason .unpack_iter_raised
    ; gives above: the unwinder restores r13 from PyFrame.disp_sp, the value
    ; the stack pointer had before this instruction, so the slot VPOP_VAL took
    ; the sequence out of is inside the range the unwind releases.  Releasing
    ; it here as well drove a live sequence's refcount to zero -- `print(xs)`
    ; after `except ValueError` read freed memory and segfaulted.
    ;
    ; The materialised tuple is a different matter: nothing else has ever seen
    ; it, so it has to go here or it leaks.
    pop rdi
    test rdi, rdi
    jz .unpack_count_raise
    push rcx
    push r8
    call obj_decref
    pop r8
    pop rcx
.unpack_count_raise:
    add rsp, 16                ; the payload and tag the prologue pushed
    mov rdi, rcx               ; expected
    mov rsi, r8                ; got
    xor edx, edx               ; no star in the target list
    call raise_unpack_count

.unpack_str:
    ; String unpacking: a, b, c = "xyz"
    ; Validate length matches count
    mov r8, [rdi + PyStrObject.ob_size]
    cmp rcx, r8
    jne .unpack_count_error

    ; Use rbp-frame for the string unpacking loop
    ; Save callee-saved regs
    push rbx                   ; save bytecode IP
    push r12                   ; save frame
    push r14                   ; spare

    mov r12, rcx               ; r12 = count
    mov r14, rdi               ; r14 = string object

    ; Pre-advance stack by count
    mov edx, ecx
    shl edx, 3
    add r13, rdx              ; stack += count * 8

    ; Create single-char strings in reverse order (count-1 down to 0)
    mov ebx, ecx
    dec ebx                    ; ebx = source index (count-1)
    mov rcx, r12
    neg rcx                    ; rcx = -count (negative offset)

.unpack_str_loop:
    test ebx, ebx
    js .unpack_str_done

    ; Create single-char string: str_new(&data[ebx], 1)
    lea rdi, [r14 + PyStrObject.data]
    movsxd rax, ebx
    add rdi, rax               ; rdi = &str.data[ebx]
    mov esi, 1                      ; length = 1
    push rcx                   ; save negative offset
    push rbx                   ; save source index
    call str_new
    pop rbx
    pop rcx
    ; rax = new string (TAG_PTR, refcount=1, ownership transferred to stack)
    mov [r13 + rcx*8], rax    ; a string pointer is its own Value
    inc rcx
    dec ebx
    jmp .unpack_str_loop

.unpack_str_done:
    pop r14
    pop r12
    pop rbx                    ; restore bytecode IP
    jmp .unpack_done           ; the three saved words, and the dispatch
END_FUNC op_unpack_sequence

;; ============================================================================
;; raise_unpack_count(rdi = expected, rsi = got, edx = 1 for a starred
;;   target) -> does not return
;; The two ValueErrors an unpack can raise, in CPython's wording:
;;   "not enough values to unpack (expected 2, got 1)"
;;   "not enough values to unpack (expected at least 2, got 1)"
;;   "too many values to unpack (expected 2)"
;; One shared message said "not enough" for both, so unpacking three values
;; into two reported the opposite of what happened.  UNPACK_EX raised a
;; sentence with no numbers in it at all; its target list has a `*` in it, so
;; the count it names is a minimum.
;; ============================================================================
RUC_BUF   equ 128
RUC_STAR  equ 136
RUC_FRAME equ RUC_BUF + 32
DEF_FUNC raise_unpack_count, RUC_FRAME
    push rbx
    push r12
    mov [rbp - RUC_STAR], rdx
    mov rbx, rdi                        ; expected
    mov r12, rsi                        ; got
    lea rdi, [rbp - RUC_BUF]
    cmp r12, rbx
    jle .ruc_not_enough

    CSTRING rsi, "too many values to unpack (expected "
    call .ruc_cat
    mov rax, rbx
    call .ruc_itoa
    CSTRING rsi, ")"
    call .ruc_cat
    jmp .ruc_raise

.ruc_not_enough:
    cmp qword [rbp - RUC_STAR], 0
    jne .ruc_at_least
    CSTRING rsi, "not enough values to unpack (expected "
    call .ruc_cat
    jmp .ruc_expected_done
.ruc_at_least:
    CSTRING rsi, "not enough values to unpack (expected at least "
    call .ruc_cat
.ruc_expected_done:
    mov rax, rbx
    call .ruc_itoa
    CSTRING rsi, ", got "
    call .ruc_cat
    mov rax, r12
    call .ruc_itoa
    CSTRING rsi, ")"
    call .ruc_cat

.ruc_raise:
    mov byte [rdi], 0
    lea rsi, [rbp - RUC_BUF]
    lea rdi, [rel exc_ValueError_type]
    call raise_exception

; Local: append the NUL-terminated rsi at rdi, leaving rdi past it.
.ruc_cat:
    mov al, [rsi]
    test al, al
    jz .ruc_cat_done
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .ruc_cat
.ruc_cat_done:
    ret

; Local: append rax in decimal at rdi, leaving rdi past it.
.ruc_itoa:
    push rbx
    push r12
    mov r12, rdi
    mov rbx, rsp
    sub rsp, 32
    and rsp, -16
    lea rcx, [rsp + 24]
    mov byte [rcx], 0
    mov r8d, 10
    test rax, rax
    jnz .ruc_digits
    dec rcx
    mov byte [rcx], '0'
    jmp .ruc_emit
.ruc_digits:
    xor edx, edx
    div r8
    add dl, '0'
    dec rcx
    mov [rcx], dl
    test rax, rax
    jnz .ruc_digits
.ruc_emit:
    mov rdi, r12
.ruc_emit_loop:
    mov al, [rcx]
    test al, al
    jz .ruc_emit_done
    mov [rdi], al
    inc rdi
    inc rcx
    jmp .ruc_emit_loop
.ruc_emit_done:
    mov rsp, rbx
    pop r12
    pop rbx
    ret
END_FUNC raise_unpack_count

;; ============================================================================
;; op_unpack_ex(ecx = count_before | count_after << 8) -> DISPATCH,
;;   or unwinds
;;
;; UNPACK_EX (94): arg encodes (count_before | count_after << 8)
;; Pop iterable from TOS, push count_after items, then a list of remaining,
;; then count_before items (in reverse order on stack).
;; ============================================================================
extern list_type

; IPAY/ITAG are the iterable as a (payload, tag) pair
UEX_TOTAL   equ 32
UEX_REST    equ 40
UEX_ITAG    equ 48
UEX_IPAY    equ 56
UEX_EXC     equ 64        ; current_exception before the iteration started
; The three values the loops below used to push and pop one at a time.  A
; lone push leaves the call it spans 8 out, and a misaligned call propagates
; into every Python frame the interpreter runs beneath it.
UEX_RESTL   equ 72        ; the rest list, while it is being filled
UEX_I       equ 80        ; the index being read
UEX_N       equ 88        ; how many are left
UEX_ITER    equ 96        ; the iterator the generic path walks
UEX_TMPL    equ 104       ; and the list it builds from it
DEF_FUNC op_unpack_ex
    push rbx
    push r14
    ; NOTE: do NOT push/pop r13 — the VPUSH macros advance it
    ; (tag stack top) and restoring it would desync from r13 (payload stack top)
    sub rsp, 120               ; room for the slots the loops use, and
                               ; FRAME + 8*pushes == 8 (mod 16), which is
                               ; what a handler wants: it is reached by jmp
                               ; and so entered ALIGNED.  The 48 that used
                               ; to be here was 0 (mod 16) and every call at
                               ; an even push depth was 8 out.
                               ; locals: [rbp - UEX_TOTAL]=total_len, [rbp - UEX_REST]=rest_count,
                               ;         [rbp - UEX_ITAG]=iter_tag, [rbp - UEX_IPAY]=iterable payload

    ; Decode arg: count_before = ecx & 0xff, count_after = ecx >> 8
    mov eax, ecx
    and eax, 0xff
    mov ebx, eax               ; ebx = count_before
    mov eax, ecx
    shr eax, 8
    mov r14d, eax              ; r14 = count_after

    ; Pop iterable
    VPOP_VAL rdi, rax
    mov [rbp - UEX_ITAG], rax          ; iterable tag
    mov [rbp - UEX_IPAY], rdi          ; iterable payload

    ; An int or a float has no type pointer to walk: its payload is a value,
    ; not an address.  op_unpack_sequence has always checked this and this did
    ; not, so `a, *b = 5` read ob_type off the number itself and segfaulted.
    cmp eax, TAG_PTR
    jne .ue_type_error

    ; Get length
    mov rdi, [rbp - UEX_IPAY]
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .ue_list

    extern tuple_type
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .ue_tuple

    ; Generic iterable: iterate into a temp list, then unpack from it
    jmp .ue_generic

.ue_list:
    mov rax, [rdi + PyListObject.ob_size]
    jmp .ue_have_len
.ue_tuple:
    mov rax, [rdi + PyTupleObject.ob_size]

.ue_have_len:
    ; rax = total length
    ; We need: count_before + count_after <= total_length
    lea rcx, [rbx + r14]      ; count_before + count_after
    cmp rax, rcx
    jl .ue_not_enough

    mov [rbp - UEX_TOTAL], rax          ; save total_len

    ; Compute rest_count = total_len - count_before - count_after
    sub rax, rbx
    sub rax, r14
    mov [rbp - UEX_REST], rax          ; rest_count

    ; Push in reverse order (top of stack = last pushed = first in sequence)
    ; Stack order (bottom to top):
    ;   last after_item, ..., first after_item, rest_list, last before_item, ..., first before_item
    ; Wait, Python actually pushes in this order:
    ;   Push count_after items in reverse (items from end)
    ;   Push rest list
    ;   Push count_before items in reverse (items from start)
    ; So TOS = first_before, TOS1 = second_before, ..., then rest, then after items

    ; 1. Push count_after items (from end, in reverse)
    mov rcx, r14
    test rcx, rcx
    jz .ue_no_after

    ; after items are at indices [total_len - count_after .. total_len - 1]
    ; Push them in reverse: index total_len-1, total_len-2, ..., total_len-count_after
    mov rax, [rbp - UEX_TOTAL]          ; total_len
    dec rax                    ; start from total_len - 1
    mov [rbp - UEX_I], rax
    mov [rbp - UEX_N], rcx
.ue_after_loop:
    mov rcx, [rbp - UEX_N]
    test rcx, rcx
    jz .ue_no_after

    ; Get item at index UEX_I from iterable
    mov rdi, [rbp - UEX_IPAY]
    mov rsi, [rbp - UEX_I]
    call .ue_getitem           ; rax = payload, rdx = tag (borrowed)
    INCREF_VAL rax, rdx
    VPUSH_VAL rax, rdx

    dec qword [rbp - UEX_I]
    dec qword [rbp - UEX_N]
    jmp .ue_after_loop

.ue_no_after:
    ; 2. Build rest list
    mov rdi, [rbp - UEX_REST]          ; rest_count as initial capacity
    call list_new
    mov [rbp - UEX_RESTL], rax ; the rest list, while it is being filled

    ; Add items at indices [count_before .. count_before + rest_count - 1]
    mov rcx, [rbp - UEX_REST]          ; rest_count
    mov [rbp - UEX_N], rcx
    mov [rbp - UEX_I], rbx     ; start index = count_before
.ue_rest_loop:
    cmp qword [rbp - UEX_N], 0
    je .ue_rest_done

    mov rdi, [rbp - UEX_IPAY]
    mov rsi, [rbp - UEX_I]
    call .ue_getitem           ; rax = payload, rdx = tag (borrowed)
    mov rsi, rax
    mov rdi, [rbp - UEX_RESTL]
    ; edx = item tag from .ue_getitem (already set)
    V_PACK rsi, rdx         ; list_append takes a Value
    call list_append           ; list_append does INCREF
    inc qword [rbp - UEX_I]
    dec qword [rbp - UEX_N]
    jmp .ue_rest_loop

.ue_rest_done:
    mov rax, [rbp - UEX_RESTL]
    VPUSH_PTR rax              ; push rest list

    ; 3. Push count_before items in reverse (from index count_before-1 down to 0)
    mov rcx, rbx
    test rcx, rcx
    jz .ue_no_before
    dec rcx                    ; start from count_before - 1
    mov [rbp - UEX_I], rcx
.ue_before_loop:
    mov rdi, [rbp - UEX_IPAY]
    mov rsi, [rbp - UEX_I]
    call .ue_getitem           ; rax = payload, rdx = tag (borrowed)
    INCREF_VAL rax, rdx
    VPUSH_VAL rax, rdx

    cmp qword [rbp - UEX_I], 0
    je .ue_no_before
    dec qword [rbp - UEX_I]
    jmp .ue_before_loop

.ue_no_before:
    ; DECREF iterable (tag-aware)
    mov rdi, [rbp - UEX_IPAY]
    mov rsi, [rbp - UEX_ITAG]         ; iterable tag
    DECREF_VAL rdi, rsi

    add rsp, 120
    pop r14
    pop rbx
    leave
    DISPATCH

.ue_generic:
    ; Generic iterable: iterate into a temp list, then unpack from it
    ; [rbp - UEX_IPAY] = iterable payload, [rbp - UEX_ITAG] = iterable tag
    ; ebx = count_before, r14 = count_after (must preserve)
    mov rdi, [rbp - UEX_IPAY]
    mov esi, TAG_PTR
    call get_iterator_opt       ; see the note in .extend_generic
    test rax, rax
    jz .ue_type_error
    mov [rbp - UEX_ITER], rax

    ; Create temp list
    xor edi, edi
    extern list_new
    call list_new
    mov [rbp - UEX_TMPL], rax

    DUNDER_EXC_SAVE [rbp - UEX_EXC]
.ue_gen_loop:
    mov rdi, [rbp - UEX_ITER]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .ue_gen_done
    mov rdi, [rbp - UEX_ITER]
    call rax                   ; tp_iternext(iter) → (payload, tag)
    V_UNPACK rax, rdx           ; tp_iternext returns a Value
    test edx, edx
    jz .ue_gen_done

    ; Append to temp list
    mov [rbp - UEX_I], rax     ; the item, held across list_append
    mov [rbp - UEX_N], rdx     ; and its tag
    mov rdi, [rbp - UEX_TMPL]
    mov rsi, rax
    V_PACK rsi, rdx         ; list_append takes a Value
    call list_append
    mov rdi, [rbp - UEX_I]
    mov rsi, [rbp - UEX_N]
    DECREF_VAL rdi, rsi
    jmp .ue_gen_loop

.ue_gen_done:
    mov rdi, [rbp - UEX_ITER]
    call obj_decref            ; DECREF iterator
    mov rax, [rbp - UEX_TMPL]

    ; NULL is exhaustion or a raise alike.  Read as exhaustion, `a, *b = G()`
    ; for a G whose __getitem__ throws bound a and b to a short answer and
    ; left the exception to surface somewhere unrelated.
    EXC_RAISED_SINCE [rbp - UEX_EXC], rcx, .ue_gen_raised

    ; DECREF original iterable
    mov rdi, [rbp - UEX_IPAY]
    mov rsi, [rbp - UEX_ITAG]
    DECREF_VAL rdi, rsi

    ; Replace iterable with temp list, update tag
    mov rax, [rbp - UEX_TMPL]
    mov [rbp - UEX_IPAY], rax
    mov qword [rbp - UEX_ITAG], TAG_PTR

    ; Now fall through to .ue_list path (reload rdi — clobbered by DECREF_VAL above)
    mov rdi, rax
    jmp .ue_list

.ue_gen_raised:
    mov rdi, [rbp - UEX_TMPL]  ; the partly built temp list
    call obj_decref
    ; The iterable is left alone: the unwinder restores r13 to the stack as
    ; it stood before this instruction, where the pop had not happened.
    extern eval_exception_unwind
    add rsp, 120
    pop r14
    pop rbx
    leave
    jmp eval_exception_unwind

.ue_not_enough:
    ; rax is the length the sequence turned out to have and rcx the number of
    ; named targets around the star.  Both were in hand; the message named
    ; neither.
    mov rdi, rcx
    mov rsi, rax
    mov edx, 1                  ; the target list has a star in it
    PUBLISH_SP
    extern raise_unpack_count
    call raise_unpack_count
    ud2

.ue_type_error:
    mov rdi, [rbp - UEX_IPAY]
    mov rsi, [rbp - UEX_ITAG]
    jmp unpack_bad_type

; Helper: get item at index rsi from iterable rdi (returns borrowed ref: rax=payload, rdx=tag)
.ue_getitem:
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .ue_gi_list
    ; tuple: payload + tag arrays
    mov rax, [rdi + PyTupleObject.ob_item]
    mov rax, [rax + rsi * 8]       ; payload
    V_UNPACK rax, rdx
    ret
.ue_gi_list:
    mov rax, [rdi + PyListObject.ob_item]
    mov rax, [rax + rsi * 8]      ; payload
    V_UNPACK rax, rdx
    ret
END_FUNC op_unpack_ex

;; ============================================================================
;; unpack_bad_type(rdi = the payload, rsi = its tag) -> does not return; the
;;   composed TypeError is raised
;;
;; "cannot unpack non-iterable int object", which is how CPython words both
;; refusals.  The type is resolved from the TAG rather than by packing the
;; pair back into a Value and asking value_type: packing a smallint outside
;; the immediate range allocates, and this path never comes back to free it.
;;
;; Nothing is released here.  The value is still in the stack slot VPOP_VAL
;; took it from, and eval_exception_unwind is what gives that reference back.
;; ============================================================================
DEF_FUNC_BARE unpack_bad_type
    cmp rsi, TAG_FLOAT
    je .ubt_float
    cmp rsi, TAG_PTR
    jne .ubt_int                ; TAG_SMALLINT, and any tag with no object
    test rdi, rdi
    jz .ubt_int
    mov rsi, [rdi + PyObject.ob_type]
    jmp .ubt_raise
.ubt_int:
    lea rsi, [rel int_type]
    jmp .ubt_raise
.ubt_float:
    lea rsi, [rel float_type]
.ubt_raise:
    CSTRING rdi, `cannot unpack non-iterable \x01 object`
    jmp raise_type_error_with_typename
END_FUNC unpack_bad_type
