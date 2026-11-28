; methods/list_sort.asm - list.sort()'s engine: timsort over Values
;
; Split out of methods/list.asm, which kept everything AROUND the sort -- the
; arity check, the keyword parsing, the key array, emptying the list so a
; re-entrant mutation is caught, and putting it back.  What is here is the
; sort itself, and it is a different algorithm from what was there.
;
; WHAT WAS THERE, AND WHY IT HAD TO GO
;
; A plain bottom-up merge sort: width = 1, 2, 4, ... merging every adjacent
; pair regardless of the data.  An already-sorted list cost a full n log n
; comparisons where timsort costs n - 1, and tests/run_list_bench.sh put the
; three cases that shows -- sorted, reverse-sorted, and a list of hundred-item
; runs -- at 0.05x, 0.07x and 0.05x of CPython.  Sixty-eight per cent of
; everything lists lost was in this one function.
;
; It also ran on the OLD (payload, tag) representation: it allocated an
; n x 16 buffer, unpacked every element into it, merged sixteen-byte elements,
; V_PACKed BOTH OPERANDS OF EVERY COMPARISON, and packed the result back.  A
; Value is one word.  The array the list already has is the array to sort.
;
; WHAT IS HERE
;
; Timsort, following CPython's Objects/listsort.txt:
;
;   - count_run finds the next ascending or strictly-descending run and
;     reverses a descending one in place.  The strictness is a stability
;     requirement, not an accident: a run of equal elements reversed would
;     put them back in the wrong order.
;   - minrun is the top six bits of n plus one if any lower bit is set, so
;     that n / minrun is just under a power of two and the merge tree is
;     balanced.  A run shorter than that is extended by a binary insertion
;     sort, which is also why a ten-element sort now allocates nothing at all.
;   - the run stack keeps the invariant len[-3] > len[-2] + len[-1] and
;     len[-2] > len[-1], merging as runs are pushed.  Both conditions are
;     checked, which is the 2015 correction -- the original invariant could
;     be violated and overflow the stack.
;   - merge_at trims both ends by galloping before merging: the elements of A
;     below B[0] and of B above A[-1] are already in place and are never
;     touched.  Then merge_lo or merge_hi, whichever copies min(na, nb) to
;     scratch.
;   - galloping proper, with MIN_GALLOP = 7 and an adaptive min_gallop that
;     the whole sort shares, so it learns whether the data is structured.
;
; And a PRE-SORT TYPE SCAN, which is the other half of CPython's speed here.
; One pass over the keys proves they are all int immediates, all float
; immediates, or all exact str; the comparator is then chosen once and every
; comparison is a compare instruction or a memcmp rather than an indirect
; tp_richcompare returning a bool OBJECT that is tested and released.  The
; int case is the strongest: the immediate encoding is monotonic, so the
; comparison is a single unsigned `cmp` of the two Values.
;
; WHAT THIS FILE DOES NOT DO
;
; Nothing here decides what a comparison MEANS.  The fallback comparator is
; obj_richcompare_bool with PY_LT, which is CPython's safe_object_compare and
; is the only thing in the tree that knows about NotImplemented, reflected
; operands and a raising __lt__.  The ladder that used to be inline here --
; str, float, tp_richcompare, dunder, reflected -- was a hand-rolled subset of
; it, and with a comparator chosen up front there is nothing left for it to do.

%include "macros.inc"
%include "object.inc"
%include "value.inc"
%include "listsort.inc"

extern ap_malloc
extern ap_free
extern ap_memcpy
extern ap_memmove
extern ap_memcmp
extern obj_richcompare_bool
extern str_type
extern tuple_type
extern v_f64_off
extern stw_requested
extern stw_safepoint

section .text


;; ============================================================================
;; The comparators.  Each is cmp(rdi = a, rsi = b) -> eax = 1 when a < b, 0
;; when it is not, and -1 with an exception pending.  Only `<` is ever asked,
;; as in CPython: a sort that used more than one operator could not be stable
;; against a type that defines them inconsistently.
;; ============================================================================

;; ============================================================================
;; sort_cmp_int(rdi = a, rsi = b) -> eax = 1 when a < b
;;
;; Both are int immediates, proved by the pre-sort scan.  The encoding is
;; monotonic and needs no decoding: an immediate is i + V_INT_BIAS, and the
;; whole range lands in [0xFFF8.., 0xFFFF..] without wrapping, so an UNSIGNED
;; compare of the two Values IS the integer compare.
;; ============================================================================
DEF_FUNC_BARE sort_cmp_int
    xor eax, eax
    cmp rdi, rsi
    setb al
    ret
END_FUNC sort_cmp_int

;; ============================================================================
;; sort_cmp_float(rdi = a, rsi = b) -> eax = 1 when a < b
;;
;; Both are float immediates.  The compare is reversed and `seta` used rather
;; than `setb`, so that an unordered result -- a NaN on either side -- answers
;; 0, which is what `<` means for one.
;; ============================================================================
DEF_FUNC_BARE sort_cmp_float
    mov rax, [rel v_f64_off]
    sub rdi, rax
    sub rsi, rax
    movq xmm0, rdi
    movq xmm1, rsi
    xor eax, eax
    comisd xmm1, xmm0           ; b ? a
    seta al                     ; b > a, and false when unordered
    ret
END_FUNC sort_cmp_float

;; ============================================================================
;; sort_cmp_str(rdi = a, rsi = b) -> eax = 1 when a < b
;;
;; Both are exact str, proved by the scan.  CPython's unsafe_latin_compare,
;; except that it can do this for EVERY string: ours are UTF-8, and a byte
;; compare of two UTF-8 strings orders them by code point, where CPython has
;; to check that both are one-byte kind first.
;;
;; The comparison is open-coded rather than a call to ap_memcmp, because the
;; strings a sort compares are usually short and the call, the frame and the
;; three saves cost more than the bytes do.  Eight at a time: an x86 load is
;; little-endian and a lexicographic compare is big-endian, so the differing
;; word is byte-swapped before it is compared, which puts the earliest
;; differing byte in the most significant position where it belongs.
;; ============================================================================
DEF_FUNC_BARE sort_cmp_str
    mov r10, [rdi + PyStrObject.ob_size]
    mov r11, [rsi + PyStrObject.ob_size]
    mov rdx, r10
    cmp rdx, r11
    cmova rdx, r11              ; the shorter of the two
    lea rdi, [rdi + PyStrObject.data]
    lea rsi, [rsi + PyStrObject.data]
.scs_qword:
    cmp rdx, 8
    jb .scs_byte
    mov r8, [rdi]
    mov r9, [rsi]
    cmp r8, r9
    jne .scs_qword_differs
    add rdi, 8
    add rsi, 8
    sub rdx, 8
    jmp .scs_qword
.scs_qword_differs:
    bswap r8
    bswap r9
    xor eax, eax
    cmp r8, r9
    setb al
    ret
.scs_byte:
    test rdx, rdx
    jz .scs_prefix
    movzx r8d, byte [rdi]
    movzx r9d, byte [rsi]
    cmp r8d, r9d
    jne .scs_byte_differs
    inc rdi
    inc rsi
    dec rdx
    jmp .scs_byte
.scs_byte_differs:
    xor eax, eax
    cmp r8d, r9d
    setb al
    ret
.scs_prefix:
    ; The common prefix matched: the shorter string is the smaller one.
    xor eax, eax
    cmp r10, r11
    setb al
    ret
END_FUNC sort_cmp_str

;; ============================================================================
;; sort_cmp_general(rdi = a, rsi = b) -> eax = 1 when a < b, -1 on error
;;
;; CPython's safe_object_compare.  obj_richcompare_bool is the only thing in
;; the tree that knows what a comparison means -- the identity shortcut,
;; NotImplemented, the reflected operand, a __lt__ that raises -- so this is a
;; tail call and nothing else.
;; ============================================================================
DEF_FUNC_BARE sort_cmp_general
    mov edx, PY_LT
    jmp obj_richcompare_bool
END_FUNC sort_cmp_general

;; ============================================================================
;; ST_ISLT -- rdi = a, rsi = b; rbx = ms.  eax = 1 when a < b, -1 on error.
;; One indirect call through the comparator the scan chose.
;; ============================================================================
%macro ST_ISLT 0
    call [rbx + MS_CMP]
%endmacro

;; ============================================================================
;; ST_LOAD dst, arrayfield, index -- dst = ms->field[index]
;; ============================================================================
%macro ST_LOAD 3
    mov %1, [rbx + %2]
    mov %1, [%1 + %3*8]
%endmacro

;; ============================================================================
;; sort_cmp_tuple(rdi = a, rsi = b) -> eax = 1 when a < b, -1 on error
;;
;; CPython's unsafe_tuple_compare.  Sorting a list of tuples is common enough
;; -- (key, payload) pairs, and everything decorate-sort-undecorate builds --
;; that it is worth not going through the tuple type's own tp_richcompare,
;; which walks the pair twice: once for == and again for <.
;;
;; Here the walk is once.  Elements are compared for equality until one pair
;; differs, and the FIRST pair gets the element comparator the scan chose,
;; because that is the position it proved homogeneous.  Any later pair falls
;; to obj_richcompare_bool, which knows nothing about them and must not.
;;
;; The equality test itself is the one `x in list` uses: two identical Values
;; are equal, and two int immediates that are not the same Value are not.
;; That settles the common case -- a first element that decides the order --
;; without a call at all, which is a thing CPython's version cannot do.
;; ============================================================================
STU_A     equ 8
STU_B     equ 16
STU_VLEN  equ 24
STU_WLEN  equ 32
STU_FRAME equ 48                ; + 2 pushes = 64, 16-aligned
DEF_FUNC sort_cmp_tuple, STU_FRAME
    push r12
    push r13
    mov [rbp - STU_A], rdi
    mov [rbp - STU_B], rsi
    mov rax, [rdi + PyTupleObject.ob_size]
    mov [rbp - STU_VLEN], rax
    mov rax, [rsi + PyTupleObject.ob_size]
    mov [rbp - STU_WLEN], rax
    xor r12d, r12d              ; i

.sct_loop:
    cmp r12, [rbp - STU_VLEN]
    jae .sct_ran_out
    cmp r12, [rbp - STU_WLEN]
    jae .sct_ran_out
    mov rax, [rbp - STU_A]
    mov rdi, [rax + PyTupleObject.ob_item]
    mov rdi, [rdi + r12*8]
    mov rax, [rbp - STU_B]
    mov rsi, [rax + PyTupleObject.ob_item]
    mov rsi, [rsi + r12*8]
    VALUE_EQ_FAST rdi, rsi, rdx, .sct_equal, .sct_differ_here
    mov edx, PY_EQ
    call obj_richcompare_bool
    cmp eax, -1
    je .sct_error
    test eax, eax
    jz .sct_differ
.sct_equal:
    inc r12
    jmp .sct_loop

.sct_ran_out:
    ; One tuple is a prefix of the other, so the shorter one is the smaller.
    xor eax, eax
    mov rcx, [rbp - STU_VLEN]
    cmp rcx, [rbp - STU_WLEN]
    setb al
    jmp .sct_out

.sct_differ_here:
    ; rdi and rsi still hold the pair; the fast arms did not call anything.
    test r12, r12
    jnz .sct_general
    call [rbx + MS_ELEMCMP]
    jmp .sct_out

.sct_differ:
    mov rax, [rbp - STU_A]
    mov rdi, [rax + PyTupleObject.ob_item]
    mov rdi, [rdi + r12*8]
    mov rax, [rbp - STU_B]
    mov rsi, [rax + PyTupleObject.ob_item]
    mov rsi, [rsi + r12*8]
    test r12, r12
    jz .sct_elem
.sct_general:
    mov edx, PY_LT
    call obj_richcompare_bool
    jmp .sct_out
.sct_elem:
    call [rbx + MS_ELEMCMP]
    jmp .sct_out

.sct_error:
    mov eax, -1
.sct_out:
    pop r13
    pop r12
    leave
    ret
END_FUNC sort_cmp_tuple

;; ============================================================================
;; sort_scan_types(rbx = ms, rdi = keys, rsi = n) -> void; sets MS_CMP and,
;; for a list of tuples, MS_ELEMCMP
;;
;; One pass, proving what a comparator would otherwise have to re-establish on
;; every one of n log n comparisons.  CPython's pre-sort check, and the same
;; order of questions:
;;
;; ARE THE KEYS TUPLES?  That is asked first, because for a list of tuples the
;; thing that has to be homogeneous is the FIRST ELEMENTS, not the keys.  A
;; list of tuples whose first elements disagree still gets the tuple
;; comparator; it just gets the general one for the element.
;;
;; A heap integer is NOT an int immediate and does not qualify -- the compare
;; would have to go through GMP -- so a list holding one falls to the general
;; comparator, as it must.
;;
;; Nothing here calls anything, so there is no frame and nothing is spilled:
;; a ten-element sort pays for this pass before it does any work at all, and
;; it has to be cheaper than what it saves.
;; ============================================================================
DEF_FUNC_BARE sort_scan_types
    lea rax, [rel sort_cmp_general]
    mov [rbx + MS_CMP], rax
    mov [rbx + MS_ELEMCMP], rax
    cmp rsi, 2
    jb .sst_ret
    lea rsi, [rdi + rsi*8]      ; one past the last key
    xor r9d, r9d                ; r9 = the keys are tuples, so far

    ; The first key decides which question the loop is asking.
    mov r8, [rdi]
    V_TEST_PTR r8, rax
    ja .sst_scan
    lea rax, [rel tuple_type]
    cmp [r8 + PyObject.ob_type], rax
    jne .sst_scan
    cmp qword [r8 + PyTupleObject.ob_size], 0
    jle .sst_scan
    mov r9d, 1

.sst_scan:
    mov r10, -1                 ; r10 = the kind: -1 undecided, -2 mixed
.sst_loop:
    cmp rdi, rsi
    jae .sst_done
    mov r8, [rdi]
    add rdi, 8
    test r9, r9
    jz .sst_have_probe

    ; Every key has to be an exact tuple with something in it, or there is no
    ; first element to compare and the whole idea is off.
    V_TEST_PTR r8, rax
    ja .sst_not_tuples
    lea rax, [rel tuple_type]
    cmp [r8 + PyObject.ob_type], rax
    jne .sst_not_tuples
    cmp qword [r8 + PyTupleObject.ob_size], 0
    jle .sst_not_tuples
    mov rax, [r8 + PyTupleObject.ob_item]
    mov r8, [rax]               ; the first element is what is classified

.sst_have_probe:
    ; 1 = int immediate, 2 = float immediate, 3 = exact str, 0 = anything else
    xor eax, eax
    V_IS_INT r8, rcx
    jb .sst_not_int
    mov eax, 1
    jmp .sst_have_kind
.sst_not_int:
    V_IS_FLOAT r8, rcx
    jae .sst_not_float
    mov eax, 2
    jmp .sst_have_kind
.sst_not_float:
    V_TEST_PTR r8, rcx
    ja .sst_have_kind
    lea rcx, [rel str_type]
    cmp [r8 + PyObject.ob_type], rcx
    jne .sst_have_kind
    mov eax, 3
.sst_have_kind:
    cmp r10, -1
    jne .sst_compare_kind
    mov r10, rax                ; the first one is the claim
    jmp .sst_loop
.sst_compare_kind:
    cmp rax, r10
    je .sst_loop
    ; Mixed.  With plain keys there is nothing left to learn; with tuples the
    ; loop still has to prove that every key IS one.
    mov r10, -2
    test r9, r9
    jnz .sst_loop
    jmp .sst_done

.sst_not_tuples:
    ; One key is not a tuple, so neither the tuple comparator nor anything
    ; learned about first elements applies.
    ret

.sst_done:
    ; r10 names the comparator the probed values earned.
    lea rax, [rel sort_cmp_general]
    cmp r10, 1
    jne .sst_try_float
    lea rax, [rel sort_cmp_int]
    jmp .sst_have_cmp
.sst_try_float:
    cmp r10, 2
    jne .sst_try_str
    lea rax, [rel sort_cmp_float]
    jmp .sst_have_cmp
.sst_try_str:
    cmp r10, 3
    jne .sst_have_cmp
    lea rax, [rel sort_cmp_str]
.sst_have_cmp:
    test r9, r9
    jnz .sst_tuples
    mov [rbx + MS_CMP], rax
    ret
.sst_tuples:
    mov [rbx + MS_ELEMCMP], rax
    lea rax, [rel sort_cmp_tuple]
    mov [rbx + MS_CMP], rax
.sst_ret:
    ret
END_FUNC sort_scan_types

;; ============================================================================
;; sort_minrun(rdi = n) -> rax
;;
;; The top six bits of n, plus one if any bit below them was set.  Below 64 it
;; is n itself, and the whole list is then a single binary insertion sort.
;; ============================================================================
DEF_FUNC_BARE sort_minrun
    xor eax, eax                ; the sticky bit
.smr_loop:
    cmp rdi, ST_MAX_MINRUN
    jb .smr_done
    mov rcx, rdi
    and ecx, 1
    or eax, ecx
    shr rdi, 1
    jmp .smr_loop
.smr_done:
    add rax, rdi
    ret
END_FUNC sort_minrun

;; ============================================================================
;; sort_getmem(rbx = ms, rdi = elements needed) -> eax = 0
;;
;; The merge scratch.  Not realloc'd: what is in the old block does not matter,
;; so a fresh allocation avoids copying it, which is the note CPython's
;; merge_getmem makes as well.
;; ============================================================================
DEF_FUNC sort_getmem, 16        ; + 2 pushes = 32, 16-aligned
    push r12
    push r13
    mov r12, rdi
    cmp r12, [rbx + MS_ALLOCED]
    jbe .sgm_ok

    mov rdi, [rbx + MS_TKEYS]
    test rdi, rdi
    jz .sgm_no_old
    call ap_free
    mov rdi, [rbx + MS_TVALS]
    test rdi, rdi
    jz .sgm_no_old
    call ap_free
.sgm_no_old:
    mov qword [rbx + MS_TKEYS], 0
    mov qword [rbx + MS_TVALS], 0
    mov qword [rbx + MS_ALLOCED], 0

    mov rdi, r12
    shl rdi, 3
    call ap_malloc
    mov [rbx + MS_TKEYS], rax
    cmp qword [rbx + MS_VALUES], 0
    je .sgm_no_vals
    mov rdi, r12
    shl rdi, 3
    call ap_malloc
    mov [rbx + MS_TVALS], rax
.sgm_no_vals:
    mov [rbx + MS_ALLOCED], r12
.sgm_ok:
    xor eax, eax
    pop r13
    pop r12
    leave
    ret
END_FUNC sort_getmem

;; ============================================================================
;; sort_reverse(rbx = ms, rdi = lo, rsi = hi) -> void
;;
;; Reverse ms->keys[lo, hi), and ms->values with it.  Values, so no refcount
;; traffic: the array owns exactly what it owned before.
;; ============================================================================
DEF_FUNC_BARE sort_reverse
    mov r8, [rbx + MS_KEYS]
    mov r9, [rbx + MS_VALUES]
    dec rsi
.srv_loop:
    cmp rdi, rsi
    jge .srv_done
    mov rax, [r8 + rdi*8]
    mov rcx, [r8 + rsi*8]
    mov [r8 + rdi*8], rcx
    mov [r8 + rsi*8], rax
    test r9, r9
    jz .srv_no_vals
    mov rax, [r9 + rdi*8]
    mov rcx, [r9 + rsi*8]
    mov [r9 + rdi*8], rcx
    mov [r9 + rsi*8], rax
.srv_no_vals:
    inc rdi
    dec rsi
    jmp .srv_loop
.srv_done:
    ret
END_FUNC sort_reverse

;; ============================================================================
;; sort_count_run(rbx = ms, rdi = lo, rsi = hi) -> rax = the run's length,
;;                                                 or -1 with an exception
;;
;; The longest ascending or STRICTLY descending run starting at lo, with a
;; descending one reversed in place.  Strictly: a descending run that admitted
;; equal neighbours could not be reversed without moving equal elements past
;; one another, which is exactly what stability forbids.
;; ============================================================================
SCR_LO   equ 8
SCR_HI   equ 16
SCR_N    equ 24
SCR_FRAME equ 32                ; + 2 pushes = 48, 16-aligned
DEF_FUNC sort_count_run, SCR_FRAME
    push r12
    push r13
    mov [rbp - SCR_LO], rdi
    mov [rbp - SCR_HI], rsi

    lea rax, [rdi + 1]
    cmp rax, rsi
    jb .scr_have_two
    mov eax, 1                  ; one element left: a run of one
    jmp .scr_out
.scr_have_two:
    mov qword [rbp - SCR_N], 2

    ; keys[lo+1] < keys[lo] ?  Then the run is descending.
    ST_LOAD rdi, MS_KEYS, rax
    mov r12, [rbp - SCR_LO]
    ST_LOAD rsi, MS_KEYS, r12
    ST_ISLT
    cmp eax, -1
    je .scr_error
    test eax, eax
    jnz .scr_descending

    ; Ascending: extend while keys[i] >= keys[i-1], i.e. NOT keys[i] < keys[i-1]
.scr_asc_loop:
    mov r12, [rbp - SCR_LO]
    add r12, [rbp - SCR_N]      ; r12 = the next index
    cmp r12, [rbp - SCR_HI]
    jae .scr_done
    test r12d, 4095
    jnz .scr_asc_no_stw
    cmp dword [rel stw_requested], 0
    je .scr_asc_no_stw
    call stw_safepoint
.scr_asc_no_stw:
    ST_LOAD rdi, MS_KEYS, r12
    dec r12
    ST_LOAD rsi, MS_KEYS, r12
    ST_ISLT
    cmp eax, -1
    je .scr_error
    test eax, eax
    jnz .scr_done
    inc qword [rbp - SCR_N]
    jmp .scr_asc_loop

.scr_descending:
.scr_desc_loop:
    mov r12, [rbp - SCR_LO]
    add r12, [rbp - SCR_N]
    cmp r12, [rbp - SCR_HI]
    jae .scr_desc_done
    test r12d, 4095
    jnz .scr_desc_no_stw
    cmp dword [rel stw_requested], 0
    je .scr_desc_no_stw
    call stw_safepoint
.scr_desc_no_stw:
    ST_LOAD rdi, MS_KEYS, r12
    dec r12
    ST_LOAD rsi, MS_KEYS, r12
    ST_ISLT
    cmp eax, -1
    je .scr_error
    test eax, eax
    jz .scr_desc_done
    inc qword [rbp - SCR_N]
    jmp .scr_desc_loop
.scr_desc_done:
    mov rdi, [rbp - SCR_LO]
    mov rsi, rdi
    add rsi, [rbp - SCR_N]
    call sort_reverse

.scr_done:
    mov rax, [rbp - SCR_N]
.scr_out:
    pop r13
    pop r12
    leave
    ret
.scr_error:
    mov rax, -1
    pop r13
    pop r12
    leave
    ret
END_FUNC sort_count_run

;; ============================================================================
;; sort_binarysort(rbx = ms, rdi = lo, rsi = hi, rdx = start) -> eax = 0/-1
;;
;; keys[lo, start) is already sorted; extend that to keys[lo, hi).  A binary
;; search for each element's place and then a slide, which is CPython's
;; binarysort: it costs log(k) comparisons and k moves, and the moves are
;; Values, so there is no refcount traffic at all.
;;
;; This is what makes a short list free of the merge machinery entirely -- a
;; list below minrun is one call to this and nothing else, and never touches
;; the scratch allocation.
;; ============================================================================
SBS_LO    equ 8
SBS_HI    equ 16
SBS_PIVV  equ 24                ; the value that rides along with the pivot
SBS_M     equ 32                ; the probe, across the comparator call
SBS_FRAME equ 32                ; + 4 pushes = 64, 16-aligned
DEF_FUNC sort_binarysort, SBS_FRAME
    push r12
    push r13
    push r14
    push r15
    mov [rbp - SBS_LO], rdi
    mov [rbp - SBS_HI], rsi
    mov r12, rdx                ; start

    cmp r12, rdi
    jne .sbs_outer
    inc r12                     ; a single element is a sorted prefix

.sbs_outer:
    cmp r12, [rbp - SBS_HI]
    jae .sbs_ok

    mov rax, [rbx + MS_KEYS]
    mov r15, [rax + r12*8]      ; the pivot
    cmp qword [rbx + MS_VALUES], 0
    je .sbs_no_pivv
    mov rax, [rbx + MS_VALUES]
    mov rax, [rax + r12*8]
    mov [rbp - SBS_PIVV], rax
.sbs_no_pivv:

    ; l = lo, r = start;  invariant: keys[lo, l) <= pivot < keys[r, start)
    mov r13, [rbp - SBS_LO]
    mov r14, r12

.sbs_bsearch:
    cmp r13, r14
    jae .sbs_place
    mov rax, r14
    sub rax, r13
    shr rax, 1
    add rax, r13                ; m = l + (r - l) / 2
    mov [rbp - SBS_M], rax      ; a frame slot, not a register: the comparator
    mov rcx, [rbx + MS_KEYS]    ; answers in eax and would clobber a restore
    mov rsi, [rcx + rax*8]
    mov rdi, r15
    ST_ISLT                     ; pivot < keys[m] ?
    cmp eax, -1
    je .sbs_error
    test eax, eax
    jz .sbs_go_right
    mov r14, [rbp - SBS_M]      ; r = m
    jmp .sbs_bsearch
.sbs_go_right:
    mov r13, [rbp - SBS_M]      ; l = m + 1
    inc r13
    jmp .sbs_bsearch

.sbs_place:
    ; Slide keys[l, start) up one and drop the pivot at l.  A backward walk
    ; rather than a memmove: the run is short -- that is what minrun is for --
    ; and the call costs more than the words do.
    mov rax, [rbx + MS_KEYS]
    mov rcx, r12
.sbs_slide:
    cmp rcx, r13
    jbe .sbs_slide_done
    mov rdx, [rax + rcx*8 - 8]
    mov [rax + rcx*8], rdx
    dec rcx
    jmp .sbs_slide
.sbs_slide_done:
    mov [rax + r13*8], r15
    cmp qword [rbx + MS_VALUES], 0
    je .sbs_next
    mov rax, [rbx + MS_VALUES]
    mov rcx, r12
.sbs_vslide:
    cmp rcx, r13
    jbe .sbs_vslide_done
    mov rdx, [rax + rcx*8 - 8]
    mov [rax + rcx*8], rdx
    dec rcx
    jmp .sbs_vslide
.sbs_vslide_done:
    mov rdx, [rbp - SBS_PIVV]
    mov [rax + r13*8], rdx

.sbs_next:
    inc r12
    jmp .sbs_outer

.sbs_ok:
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    leave
    ret
.sbs_error:
    mov eax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    leave
    ret
END_FUNC sort_binarysort

;; ============================================================================
;; sort_gallop_left(rbx = ms, rdi = key, rsi = base index, rdx = n,
;;                  rcx = hint) -> rax = k, or -1 with an exception
;;
;; The LEFTMOST place in keys[base, base+n) where key could be inserted and
;; stay sorted: keys[base+k-1] < key <= keys[base+k].  An exponential search
;; from the hint, doubling the offset, then a binary search over what is left.
;;
;; Left and right differ only in where they put an element equal to the key,
;; and that difference is the whole of stability in a galloping merge: the
;; run that comes first in the list uses one and the run that comes second
;; uses the other.
;; ============================================================================
SGL_KEY   equ 8
SGL_BASE  equ 16
SGL_N     equ 24
SGL_LAST  equ 32
SGL_OFS   equ 40
SGL_MAX   equ 48                ; maxofs, in a slot and not a register: it has
SGL_HINT  equ 56                ; to survive the comparator, and the comparator
SGL_FRAME equ 64                ; answers in eax.  + 2 pushes = 80, 16-aligned
DEF_FUNC sort_gallop_left, SGL_FRAME
    push r12
    push r13
    mov [rbp - SGL_KEY], rdi
    mov [rbp - SGL_BASE], rsi
    mov [rbp - SGL_N], rdx
    mov [rbp - SGL_HINT], rcx
    mov qword [rbp - SGL_LAST], 0
    mov qword [rbp - SGL_OFS], 1

    ; keys[base + hint] < key ?  Then gallop right, else gallop left.
    lea r12, [rsi + rcx]
    ST_LOAD rdi, MS_KEYS, r12
    mov rsi, [rbp - SGL_KEY]
    ST_ISLT                     ; keys[base+hint] < key
    cmp eax, -1
    je .sgl_error
    test eax, eax
    jz .sgl_gallop_down

    ; Rightwards: find the largest ofs with keys[base+hint+ofs] < key.
    ; maxofs is n - hint, not one less: &keys[base+n-1] is the highest slot,
    ; so hint + ofs is allowed to reach n itself.
    mov rax, [rbp - SGL_N]
    sub rax, [rbp - SGL_HINT]
    mov [rbp - SGL_MAX], rax
.sgl_up_loop:
    mov rax, [rbp - SGL_OFS]
    cmp rax, [rbp - SGL_MAX]
    jge .sgl_up_done
    mov r13, [rbp - SGL_BASE]
    add r13, [rbp - SGL_HINT]
    add r13, rax
    ST_LOAD rdi, MS_KEYS, r13
    mov rsi, [rbp - SGL_KEY]
    ST_ISLT
    cmp eax, -1
    je .sgl_error
    test eax, eax
    jz .sgl_up_done
    mov rcx, [rbp - SGL_OFS]
    mov [rbp - SGL_LAST], rcx
    lea rcx, [rcx + rcx + 1]
    mov [rbp - SGL_OFS], rcx
    jmp .sgl_up_loop
.sgl_up_done:
    mov rax, [rbp - SGL_MAX]
    cmp [rbp - SGL_OFS], rax
    jle .sgl_up_clamped
    mov [rbp - SGL_OFS], rax
.sgl_up_clamped:
    ; Translate back to offsets from base.
    mov rax, [rbp - SGL_HINT]
    add [rbp - SGL_LAST], rax
    add [rbp - SGL_OFS], rax
    jmp .sgl_binary

.sgl_gallop_down:
    ; Leftwards: find the smallest ofs with key <= keys[base+hint-ofs].
    mov rax, [rbp - SGL_HINT]
    inc rax                     ; maxofs = hint + 1: &keys[base] is the lowest
    mov [rbp - SGL_MAX], rax
.sgl_dn_loop:
    mov rax, [rbp - SGL_OFS]
    cmp rax, [rbp - SGL_MAX]
    jge .sgl_dn_done
    mov r13, [rbp - SGL_BASE]
    add r13, [rbp - SGL_HINT]
    sub r13, rax
    ST_LOAD rdi, MS_KEYS, r13
    mov rsi, [rbp - SGL_KEY]
    ST_ISLT
    cmp eax, -1
    je .sgl_error
    test eax, eax
    jnz .sgl_dn_done
    mov rcx, [rbp - SGL_OFS]
    mov [rbp - SGL_LAST], rcx
    lea rcx, [rcx + rcx + 1]
    mov [rbp - SGL_OFS], rcx
    jmp .sgl_dn_loop
.sgl_dn_done:
    mov rax, [rbp - SGL_MAX]
    cmp [rbp - SGL_OFS], rax
    jle .sgl_dn_clamped
    mov [rbp - SGL_OFS], rax
.sgl_dn_clamped:
    ; Mirror: [hint - ofs, hint - lastofs)
    mov rcx, [rbp - SGL_HINT]
    sub rcx, [rbp - SGL_OFS]
    mov rax, [rbp - SGL_HINT]
    sub rax, [rbp - SGL_LAST]
    mov [rbp - SGL_LAST], rcx
    mov [rbp - SGL_OFS], rax

.sgl_binary:
    ; keys[base+lastofs-1] < key <= keys[base+ofs]; narrow to one place.
    inc qword [rbp - SGL_LAST]
.sgl_bin_loop:
    mov rax, [rbp - SGL_LAST]
    cmp rax, [rbp - SGL_OFS]
    jae .sgl_bin_done
    mov rcx, [rbp - SGL_OFS]
    sub rcx, rax
    shr rcx, 1
    add rcx, rax                ; m = lastofs + (ofs - lastofs) / 2
    mov r13, rcx
    mov rcx, [rbp - SGL_BASE]
    add rcx, r13
    ST_LOAD rdi, MS_KEYS, rcx
    mov rsi, [rbp - SGL_KEY]
    ST_ISLT                     ; keys[base+m] < key
    cmp eax, -1
    je .sgl_error
    test eax, eax
    jz .sgl_bin_hi
    lea rax, [r13 + 1]
    mov [rbp - SGL_LAST], rax
    jmp .sgl_bin_loop
.sgl_bin_hi:
    mov [rbp - SGL_OFS], r13
    jmp .sgl_bin_loop
.sgl_bin_done:
    mov rax, [rbp - SGL_OFS]
    pop r13
    pop r12
    leave
    ret
.sgl_error:
    mov rax, -1
    pop r13
    pop r12
    leave
    ret
END_FUNC sort_gallop_left

;; ============================================================================
;; sort_gallop_right(rbx = ms, rdi = key, rsi = base index, rdx = n,
;;                   rcx = hint) -> rax = k, or -1 with an exception
;;
;; The RIGHTMOST such place: keys[base+k-1] <= key < keys[base+k].  The same
;; search as gallop_left with the comparison the other way round -- there it
;; asks "keys[i] < key", here "key < keys[i]".
;; ============================================================================
DEF_FUNC sort_gallop_right, SGL_FRAME
    push r12
    push r13
    mov [rbp - SGL_KEY], rdi
    mov [rbp - SGL_BASE], rsi
    mov [rbp - SGL_N], rdx
    mov [rbp - SGL_HINT], rcx
    mov qword [rbp - SGL_LAST], 0
    mov qword [rbp - SGL_OFS], 1

    ; key < keys[base + hint] ?  Then gallop left, else gallop right.
    lea r12, [rsi + rcx]
    mov rdi, [rbp - SGL_KEY]
    ST_LOAD rsi, MS_KEYS, r12
    ST_ISLT                     ; key < keys[base+hint]
    cmp eax, -1
    je .sgr_error
    test eax, eax
    jnz .sgr_gallop_down

    ; Rightwards: largest ofs with NOT key < keys[base+hint+ofs].
    mov rax, [rbp - SGL_N]
    sub rax, [rbp - SGL_HINT]   ; maxofs = n - hint, as in gallop_left
    mov [rbp - SGL_MAX], rax
.sgr_up_loop:
    mov rax, [rbp - SGL_OFS]
    cmp rax, [rbp - SGL_MAX]
    jge .sgr_up_done
    mov r13, [rbp - SGL_BASE]
    add r13, [rbp - SGL_HINT]
    add r13, rax
    mov rdi, [rbp - SGL_KEY]
    ST_LOAD rsi, MS_KEYS, r13
    ST_ISLT
    cmp eax, -1
    je .sgr_error
    test eax, eax
    jnz .sgr_up_done
    mov rcx, [rbp - SGL_OFS]
    mov [rbp - SGL_LAST], rcx
    lea rcx, [rcx + rcx + 1]
    mov [rbp - SGL_OFS], rcx
    jmp .sgr_up_loop
.sgr_up_done:
    mov rax, [rbp - SGL_MAX]
    cmp [rbp - SGL_OFS], rax
    jle .sgr_up_clamped
    mov [rbp - SGL_OFS], rax
.sgr_up_clamped:
    mov rax, [rbp - SGL_HINT]
    add [rbp - SGL_LAST], rax
    add [rbp - SGL_OFS], rax
    jmp .sgr_binary

.sgr_gallop_down:
    mov rax, [rbp - SGL_HINT]
    inc rax
    mov [rbp - SGL_MAX], rax
.sgr_dn_loop:
    mov rax, [rbp - SGL_OFS]
    cmp rax, [rbp - SGL_MAX]
    jge .sgr_dn_done
    mov r13, [rbp - SGL_BASE]
    add r13, [rbp - SGL_HINT]
    sub r13, rax
    mov rdi, [rbp - SGL_KEY]
    ST_LOAD rsi, MS_KEYS, r13
    ST_ISLT
    cmp eax, -1
    je .sgr_error
    test eax, eax
    jz .sgr_dn_done
    mov rcx, [rbp - SGL_OFS]
    mov [rbp - SGL_LAST], rcx
    lea rcx, [rcx + rcx + 1]
    mov [rbp - SGL_OFS], rcx
    jmp .sgr_dn_loop
.sgr_dn_done:
    mov rax, [rbp - SGL_MAX]
    cmp [rbp - SGL_OFS], rax
    jle .sgr_dn_clamped
    mov [rbp - SGL_OFS], rax
.sgr_dn_clamped:
    mov rcx, [rbp - SGL_HINT]
    sub rcx, [rbp - SGL_OFS]
    mov rax, [rbp - SGL_HINT]
    sub rax, [rbp - SGL_LAST]
    mov [rbp - SGL_LAST], rcx
    mov [rbp - SGL_OFS], rax

.sgr_binary:
    inc qword [rbp - SGL_LAST]
.sgr_bin_loop:
    mov rax, [rbp - SGL_LAST]
    cmp rax, [rbp - SGL_OFS]
    jae .sgr_bin_done
    mov rcx, [rbp - SGL_OFS]
    sub rcx, rax
    shr rcx, 1
    add rcx, rax
    mov r13, rcx
    mov rcx, [rbp - SGL_BASE]
    add rcx, r13
    mov rdi, [rbp - SGL_KEY]
    ST_LOAD rsi, MS_KEYS, rcx
    ST_ISLT                     ; key < keys[base+m]
    cmp eax, -1
    je .sgr_error
    test eax, eax
    jnz .sgr_bin_hi
    lea rax, [r13 + 1]
    mov [rbp - SGL_LAST], rax
    jmp .sgr_bin_loop
.sgr_bin_hi:
    mov [rbp - SGL_OFS], r13
    jmp .sgr_bin_loop
.sgr_bin_done:
    mov rax, [rbp - SGL_OFS]
    pop r13
    pop r12
    leave
    ret
.sgr_error:
    mov rax, -1
    pop r13
    pop r12
    leave
    ret
END_FUNC sort_gallop_right

;; ============================================================================
;; The element moves.
;;
;; keys and values move in lockstep, and values is 0 unless key= was given.
;; That is one compare per move, and it goes the same way for the whole sort,
;; so the branch predictor pays for it once.  CPython's sortslice carries the
;; same pair for the same reason: the comparator only ever looks at keys, so
;; a decorate-sort-undecorate costs no extra indirection at compare time.
;; ============================================================================

;; ST_GET1 dstreg, keyfield, valfield, idxreg -- read one element into
;; dstreg (key) and r11 (value, or undefined when there are none).
%macro ST_GET1 4
    mov %1, [rbx + %2]
    mov %1, [%1 + %4*8]
    cmp qword [rbx + MS_VALUES], 0
    je %%nov
    mov r11, [rbx + %3]
    mov r11, [r11 + %4*8]
%%nov:
%endmacro

;; ST_PUT1 keyfield, valfield, idxreg, srcreg -- write srcreg (key) and r11
;; (value) at idxreg.
%macro ST_PUT1 4
    mov r10, [rbx + %1]
    mov [r10 + %3*8], %4
    cmp qword [rbx + MS_VALUES], 0
    je %%nov
    mov r10, [rbx + %2]
    mov [r10 + %3*8], r11
%%nov:
%endmacro

;; ============================================================================
;; sort_bulk_move(rbx = ms, rdi = dst index, rsi = src index, rdx = count,
;;                rcx = 0 for keys<-keys, 1 for keys<-temp, 2 for temp<-keys)
;;   -> void
;;
;; A run of elements at once, keys and values together.  ap_memmove and not
;; ap_memcpy for the keys<-keys direction, which is the one a gallop through
;; the second run uses and where source and destination overlap.
;; ============================================================================
SBM_DST   equ 8
SBM_SRC   equ 16
SBM_CNT   equ 24
SBM_DIR   equ 32
SBM_FRAME equ 32                ; + 0 pushes = 40... padded below
DEF_FUNC sort_bulk_move, 48
    mov [rbp - SBM_DST], rdi
    mov [rbp - SBM_SRC], rsi
    mov [rbp - SBM_CNT], rdx
    mov [rbp - SBM_DIR], rcx
    test rdx, rdx
    jz .sbm_done

    ; keys
    mov rax, [rbx + MS_KEYS]
    mov r8, [rbx + MS_KEYS]
    cmp rcx, 1
    jne .sbm_k_src
    mov r8, [rbx + MS_TKEYS]
.sbm_k_src:
    cmp rcx, 2
    jne .sbm_k_dst
    mov rax, [rbx + MS_TKEYS]
.sbm_k_dst:
    lea rdi, [rax + rdi*8]
    lea rsi, [r8 + rsi*8]
    mov rdx, [rbp - SBM_CNT]
    shl rdx, 3
    call ap_memmove

    cmp qword [rbx + MS_VALUES], 0
    je .sbm_done
    mov rcx, [rbp - SBM_DIR]
    mov rax, [rbx + MS_VALUES]
    mov r8, [rbx + MS_VALUES]
    cmp rcx, 1
    jne .sbm_v_src
    mov r8, [rbx + MS_TVALS]
.sbm_v_src:
    cmp rcx, 2
    jne .sbm_v_dst
    mov rax, [rbx + MS_TVALS]
.sbm_v_dst:
    mov rdi, [rbp - SBM_DST]
    lea rdi, [rax + rdi*8]
    mov rsi, [rbp - SBM_SRC]
    lea rsi, [r8 + rsi*8]
    mov rdx, [rbp - SBM_CNT]
    shl rdx, 3
    call ap_memmove
.sbm_done:
    leave
    ret
END_FUNC sort_bulk_move

;; ============================================================================
;; sort_merge_lo(rbx = ms, rdi = ia, rsi = na, rdx = ib, rcx = nb) -> eax
;;
;; Merge the two adjacent runs, na <= nb, by copying A to scratch and filling
;; forwards.  Straight one-at-a-time merging until one run wins min_gallop
;; times in a row, then galloping until it stops paying, and min_gallop is
;; nudged down while it pays and up when it stops -- so the whole sort learns
;; whether the data is structured, which is what carrying it in the
;; MergeState rather than a local is for.
;; ============================================================================
SML_DEST  equ 8
SML_I     equ 16
SML_J     equ 24
SML_NA    equ 32
SML_NB    equ 40
SML_MG    equ 48
SML_AC    equ 56
SML_BC    equ 64
SML_FRAME equ 80                ; + 2 pushes = 96, 16-aligned
DEF_FUNC sort_merge_lo, SML_FRAME
    push r12
    push r13

    mov [rbp - SML_DEST], rdi
    mov [rbp - SML_NA], rsi
    mov [rbp - SML_J], rdx
    mov [rbp - SML_NB], rcx
    mov qword [rbp - SML_I], 0

    ; A goes to the scratch.
    push rdi
    push rdi                    ; twice: rsp keeps its alignment
    mov rdi, rsi
    call sort_getmem
    pop rdi
    pop rdi
    mov rsi, rdi                ; src = ia
    xor edi, edi                ; dst = 0 in the scratch
    mov rdx, [rbp - SML_NA]
    mov ecx, 2                  ; temp <- keys
    call sort_bulk_move

    ; b[0] is known to precede every element of A: merge_at galloped it into
    ; place before calling here.
    mov r12, [rbp - SML_J]
    ST_GET1 rax, MS_KEYS, MS_VALUES, r12
    mov r13, [rbp - SML_DEST]
    ST_PUT1 MS_KEYS, MS_VALUES, r13, rax
    inc qword [rbp - SML_DEST]
    inc qword [rbp - SML_J]
    dec qword [rbp - SML_NB]
    jz .sml_succeed
    cmp qword [rbp - SML_NA], 1
    je .sml_copyb

    mov rax, [rbx + MS_MINGALLOP]
    mov [rbp - SML_MG], rax

.sml_outer:
    mov qword [rbp - SML_AC], 0
    mov qword [rbp - SML_BC], 0

.sml_one:
    mov r12, [rbp - SML_J]
    ST_LOAD rdi, MS_KEYS, r12
    mov r12, [rbp - SML_I]
    mov rsi, [rbx + MS_TKEYS]
    mov rsi, [rsi + r12*8]
    ST_ISLT                     ; B[j] < A[i] ?
    cmp eax, -1
    je .sml_fail
    test eax, eax
    jz .sml_take_a

    ; take from B
    mov r12, [rbp - SML_J]
    ST_GET1 rax, MS_KEYS, MS_VALUES, r12
    mov r13, [rbp - SML_DEST]
    ST_PUT1 MS_KEYS, MS_VALUES, r13, rax
    inc qword [rbp - SML_DEST]
    inc qword [rbp - SML_J]
    inc qword [rbp - SML_BC]
    mov qword [rbp - SML_AC], 0
    dec qword [rbp - SML_NB]
    jz .sml_succeed
    mov rax, [rbp - SML_BC]
    cmp rax, [rbp - SML_MG]
    jb .sml_one
    jmp .sml_gallop

.sml_take_a:
    mov r12, [rbp - SML_I]
    ST_GET1 rax, MS_TKEYS, MS_TVALS, r12
    mov r13, [rbp - SML_DEST]
    ST_PUT1 MS_KEYS, MS_VALUES, r13, rax
    inc qword [rbp - SML_DEST]
    inc qword [rbp - SML_I]
    inc qword [rbp - SML_AC]
    mov qword [rbp - SML_BC], 0
    dec qword [rbp - SML_NA]
    cmp qword [rbp - SML_NA], 1
    je .sml_copyb
    mov rax, [rbp - SML_AC]
    cmp rax, [rbp - SML_MG]
    jb .sml_one

.sml_gallop:
    inc qword [rbp - SML_MG]
.sml_gallop_loop:
    mov rax, [rbp - SML_MG]
    cmp rax, 1
    jbe .sml_mg_floor
    dec rax
    mov [rbp - SML_MG], rax
.sml_mg_floor:
    mov rax, [rbp - SML_MG]
    mov [rbx + MS_MINGALLOP], rax

    ; How many of A precede B[j]?  A is in the scratch, so this galloping
    ; search runs over the scratch: MS_TKEYS is swapped in for the call and
    ; back out after it, which is what the pointer swap below is.
    mov r12, [rbp - SML_J]
    ST_LOAD rdi, MS_KEYS, r12
    mov rax, [rbx + MS_KEYS]
    mov rcx, [rbx + MS_TKEYS]
    mov [rbx + MS_KEYS], rcx
    push rax
    push rax
    mov rsi, [rbp - SML_I]
    mov rdx, [rbp - SML_NA]
    xor ecx, ecx
    call sort_gallop_right
    pop rcx
    pop rcx
    mov [rbx + MS_KEYS], rcx
    cmp rax, -1
    je .sml_fail
    mov [rbp - SML_AC], rax
    test rax, rax
    jz .sml_no_a_run
    mov rdi, [rbp - SML_DEST]
    mov rsi, [rbp - SML_I]
    mov rdx, rax
    mov ecx, 1                  ; keys <- temp
    push rax
    push rax
    call sort_bulk_move
    pop rax
    pop rax
    add [rbp - SML_DEST], rax
    add [rbp - SML_I], rax
    sub [rbp - SML_NA], rax
    cmp qword [rbp - SML_NA], 1
    jbe .sml_na_small
.sml_no_a_run:
    ; one from B
    mov r12, [rbp - SML_J]
    ST_GET1 rax, MS_KEYS, MS_VALUES, r12
    mov r13, [rbp - SML_DEST]
    ST_PUT1 MS_KEYS, MS_VALUES, r13, rax
    inc qword [rbp - SML_DEST]
    inc qword [rbp - SML_J]
    dec qword [rbp - SML_NB]
    jz .sml_succeed

    ; How many of B precede A[i]?
    mov r12, [rbp - SML_I]
    mov rdi, [rbx + MS_TKEYS]
    mov rdi, [rdi + r12*8]
    mov rsi, [rbp - SML_J]
    mov rdx, [rbp - SML_NB]
    xor ecx, ecx
    call sort_gallop_left
    cmp rax, -1
    je .sml_fail
    mov [rbp - SML_BC], rax
    test rax, rax
    jz .sml_no_b_run
    mov rdi, [rbp - SML_DEST]
    mov rsi, [rbp - SML_J]
    mov rdx, rax
    xor ecx, ecx                ; keys <- keys, overlapping
    push rax
    push rax
    call sort_bulk_move
    pop rax
    pop rax
    add [rbp - SML_DEST], rax
    add [rbp - SML_J], rax
    sub [rbp - SML_NB], rax
    cmp qword [rbp - SML_NB], 0
    je .sml_succeed
.sml_no_b_run:
    ; one from A
    mov r12, [rbp - SML_I]
    ST_GET1 rax, MS_TKEYS, MS_TVALS, r12
    mov r13, [rbp - SML_DEST]
    ST_PUT1 MS_KEYS, MS_VALUES, r13, rax
    inc qword [rbp - SML_DEST]
    inc qword [rbp - SML_I]
    dec qword [rbp - SML_NA]
    cmp qword [rbp - SML_NA], 1
    je .sml_copyb

    mov rax, [rbp - SML_AC]
    cmp rax, ST_MIN_GALLOP
    jae .sml_gallop_loop
    mov rax, [rbp - SML_BC]
    cmp rax, ST_MIN_GALLOP
    jae .sml_gallop_loop

    inc qword [rbp - SML_MG]    ; leaving galloping costs it one
    mov rax, [rbp - SML_MG]
    mov [rbx + MS_MINGALLOP], rax
    jmp .sml_outer

.sml_na_small:
    cmp qword [rbp - SML_NA], 1
    je .sml_copyb
    ; na == 0: everything left is B, and it is already where it belongs
    jmp .sml_ok

.sml_succeed:
    ; Whatever is left of A goes at the end.
    mov rdx, [rbp - SML_NA]
    test rdx, rdx
    jz .sml_ok
    mov rdi, [rbp - SML_DEST]
    mov rsi, [rbp - SML_I]
    mov ecx, 1                  ; keys <- temp
    call sort_bulk_move
    jmp .sml_ok

.sml_copyb:
    ; na == 1: the rest of B slides down, and A's last element follows it.
    mov rdx, [rbp - SML_NB]
    test rdx, rdx
    jz .sml_copyb_tail
    mov rdi, [rbp - SML_DEST]
    mov rsi, [rbp - SML_J]
    xor ecx, ecx
    call sort_bulk_move
.sml_copyb_tail:
    mov r12, [rbp - SML_I]
    ST_GET1 rax, MS_TKEYS, MS_TVALS, r12
    mov r13, [rbp - SML_DEST]
    add r13, [rbp - SML_NB]
    ST_PUT1 MS_KEYS, MS_VALUES, r13, rax

.sml_ok:
    xor eax, eax
    pop r13
    pop r12
    leave
    ret
.sml_fail:
    mov eax, -1
    pop r13
    pop r12
    leave
    ret
END_FUNC sort_merge_lo

;; ============================================================================
;; sort_merge_hi(rbx = ms, rdi = ia, rsi = na, rdx = ib, rcx = nb) -> eax
;;
;; The mirror of merge_lo, for nb < na: B goes to the scratch and the result
;; is filled backwards from the top.  The pair exists so that the scratch is
;; always min(na, nb) elements, which is what bounds a sort's extra memory.
;;
;; The comparison is the same one -- "is B's element less than A's?" -- and it
;; is the ANSWER that is used the other way round: filling downwards, the
;; larger element goes first, so a true answer takes from A.  A tie takes from
;; B, which puts B's element at the higher index and leaves A's below it,
;; which is stability.
;; ============================================================================
SMH_DEST  equ 8
SMH_I     equ 16
SMH_J     equ 24
SMH_NA    equ 32
SMH_NB    equ 40
SMH_MG    equ 48
SMH_AC    equ 56
SMH_BC    equ 64
SMH_IA    equ 72
SMH_FRAME equ 80                ; + 2 pushes = 96, 16-aligned
DEF_FUNC sort_merge_hi, SMH_FRAME
    push r12
    push r13

    mov [rbp - SMH_IA], rdi
    mov [rbp - SMH_NA], rsi
    mov [rbp - SMH_NB], rcx
    lea rax, [rdi + rsi - 1]
    mov [rbp - SMH_I], rax      ; the top of A, in keys
    lea rax, [rdx + rcx - 1]
    mov [rbp - SMH_DEST], rax   ; fills downwards
    lea rax, [rcx - 1]
    mov [rbp - SMH_J], rax      ; the top of B, in the scratch

    ; B goes to the scratch.
    push rdx
    push rdx                    ; twice: rsp keeps its alignment
    mov rdi, rcx
    call sort_getmem
    pop rdx
    pop rdx
    mov rsi, rdx                ; src = ib
    xor edi, edi
    mov rdx, [rbp - SMH_NB]
    mov ecx, 2                  ; temp <- keys
    call sort_bulk_move

    ; a[na-1] follows every element of B: merge_at galloped it into place.
    mov r12, [rbp - SMH_I]
    ST_GET1 rax, MS_KEYS, MS_VALUES, r12
    mov r13, [rbp - SMH_DEST]
    ST_PUT1 MS_KEYS, MS_VALUES, r13, rax
    dec qword [rbp - SMH_DEST]
    dec qword [rbp - SMH_I]
    dec qword [rbp - SMH_NA]
    jz .smh_succeed
    cmp qword [rbp - SMH_NB], 1
    je .smh_copya

    mov rax, [rbx + MS_MINGALLOP]
    mov [rbp - SMH_MG], rax

.smh_outer:
    mov qword [rbp - SMH_AC], 0
    mov qword [rbp - SMH_BC], 0

.smh_one:
    mov r12, [rbp - SMH_J]
    mov rdi, [rbx + MS_TKEYS]
    mov rdi, [rdi + r12*8]
    mov r12, [rbp - SMH_I]
    ST_LOAD rsi, MS_KEYS, r12
    ST_ISLT                     ; B[j] < A[i] ?
    cmp eax, -1
    je .smh_fail
    test eax, eax
    jz .smh_take_b

    ; A's element is the larger: it goes at the top.
    mov r12, [rbp - SMH_I]
    ST_GET1 rax, MS_KEYS, MS_VALUES, r12
    mov r13, [rbp - SMH_DEST]
    ST_PUT1 MS_KEYS, MS_VALUES, r13, rax
    dec qword [rbp - SMH_DEST]
    dec qword [rbp - SMH_I]
    inc qword [rbp - SMH_AC]
    mov qword [rbp - SMH_BC], 0
    dec qword [rbp - SMH_NA]
    jz .smh_succeed
    mov rax, [rbp - SMH_AC]
    cmp rax, [rbp - SMH_MG]
    jb .smh_one
    jmp .smh_gallop

.smh_take_b:
    mov r12, [rbp - SMH_J]
    ST_GET1 rax, MS_TKEYS, MS_TVALS, r12
    mov r13, [rbp - SMH_DEST]
    ST_PUT1 MS_KEYS, MS_VALUES, r13, rax
    dec qword [rbp - SMH_DEST]
    dec qword [rbp - SMH_J]
    inc qword [rbp - SMH_BC]
    mov qword [rbp - SMH_AC], 0
    dec qword [rbp - SMH_NB]
    cmp qword [rbp - SMH_NB], 1
    je .smh_copya
    mov rax, [rbp - SMH_BC]
    cmp rax, [rbp - SMH_MG]
    jb .smh_one

.smh_gallop:
    inc qword [rbp - SMH_MG]
.smh_gallop_loop:
    mov rax, [rbp - SMH_MG]
    cmp rax, 1
    jbe .smh_mg_floor
    dec rax
    mov [rbp - SMH_MG], rax
.smh_mg_floor:
    mov rax, [rbp - SMH_MG]
    mov [rbx + MS_MINGALLOP], rax

    ; How many of A stand above B[j]?  A's live run is keys[i-na+1, i].
    mov r12, [rbp - SMH_J]
    mov rdi, [rbx + MS_TKEYS]
    mov rdi, [rdi + r12*8]
    mov rsi, [rbp - SMH_I]
    sub rsi, [rbp - SMH_NA]
    inc rsi                     ; base
    mov rdx, [rbp - SMH_NA]
    lea rcx, [rdx - 1]          ; hint: the top
    call sort_gallop_right
    cmp rax, -1
    je .smh_fail
    mov rcx, [rbp - SMH_NA]
    sub rcx, rax                ; the count above
    mov [rbp - SMH_AC], rcx
    test rcx, rcx
    jz .smh_no_a_run
    sub [rbp - SMH_DEST], rcx
    sub [rbp - SMH_I], rcx
    mov rdi, [rbp - SMH_DEST]
    inc rdi
    mov rsi, [rbp - SMH_I]
    inc rsi
    mov rdx, rcx
    push rcx
    push rcx
    xor ecx, ecx                ; keys <- keys
    call sort_bulk_move
    pop rcx
    pop rcx
    sub [rbp - SMH_NA], rcx
    jz .smh_succeed
.smh_no_a_run:
    ; one from B
    mov r12, [rbp - SMH_J]
    ST_GET1 rax, MS_TKEYS, MS_TVALS, r12
    mov r13, [rbp - SMH_DEST]
    ST_PUT1 MS_KEYS, MS_VALUES, r13, rax
    dec qword [rbp - SMH_DEST]
    dec qword [rbp - SMH_J]
    dec qword [rbp - SMH_NB]
    cmp qword [rbp - SMH_NB], 1
    je .smh_copya

    ; How many of B stand above A[i]?  B's live run is temp[0, j].
    mov r12, [rbp - SMH_I]
    ST_LOAD rdi, MS_KEYS, r12
    mov rax, [rbx + MS_KEYS]
    mov rcx, [rbx + MS_TKEYS]
    mov [rbx + MS_KEYS], rcx
    push rax
    push rax
    xor esi, esi                ; base 0 in the scratch
    mov rdx, [rbp - SMH_NB]
    lea rcx, [rdx - 1]
    call sort_gallop_left
    pop rcx
    pop rcx
    mov [rbx + MS_KEYS], rcx
    cmp rax, -1
    je .smh_fail
    mov rcx, [rbp - SMH_NB]
    sub rcx, rax
    mov [rbp - SMH_BC], rcx
    test rcx, rcx
    jz .smh_no_b_run
    sub [rbp - SMH_DEST], rcx
    sub [rbp - SMH_J], rcx
    mov rdi, [rbp - SMH_DEST]
    inc rdi
    mov rsi, [rbp - SMH_J]
    inc rsi
    mov rdx, rcx
    push rcx
    push rcx
    mov ecx, 1                  ; keys <- temp
    call sort_bulk_move
    pop rcx
    pop rcx
    sub [rbp - SMH_NB], rcx
    cmp qword [rbp - SMH_NB], 1
    je .smh_copya
    cmp qword [rbp - SMH_NB], 0
    je .smh_succeed
.smh_no_b_run:
    ; one from A
    mov r12, [rbp - SMH_I]
    ST_GET1 rax, MS_KEYS, MS_VALUES, r12
    mov r13, [rbp - SMH_DEST]
    ST_PUT1 MS_KEYS, MS_VALUES, r13, rax
    dec qword [rbp - SMH_DEST]
    dec qword [rbp - SMH_I]
    dec qword [rbp - SMH_NA]
    jz .smh_succeed

    mov rax, [rbp - SMH_AC]
    cmp rax, ST_MIN_GALLOP
    jae .smh_gallop_loop
    mov rax, [rbp - SMH_BC]
    cmp rax, ST_MIN_GALLOP
    jae .smh_gallop_loop

    inc qword [rbp - SMH_MG]
    mov rax, [rbp - SMH_MG]
    mov [rbx + MS_MINGALLOP], rax
    jmp .smh_outer

.smh_succeed:
    ; Whatever is left of B goes at the bottom.
    mov rdx, [rbp - SMH_NB]
    test rdx, rdx
    jz .smh_ok
    mov rdi, [rbp - SMH_DEST]
    sub rdi, rdx
    inc rdi
    mov rsi, [rbp - SMH_J]
    sub rsi, rdx
    inc rsi
    mov ecx, 1                  ; keys <- temp
    call sort_bulk_move
    jmp .smh_ok

.smh_copya:
    ; nb == 1: the rest of A slides up, and B's last element goes below it.
    mov rdx, [rbp - SMH_NA]
    test rdx, rdx
    jz .smh_copya_tail
    mov rdi, [rbp - SMH_DEST]
    sub rdi, rdx
    inc rdi
    mov rsi, [rbp - SMH_I]
    sub rsi, rdx
    inc rsi
    xor ecx, ecx
    call sort_bulk_move
.smh_copya_tail:
    mov r12, [rbp - SMH_J]
    ST_GET1 rax, MS_TKEYS, MS_TVALS, r12
    mov r13, [rbp - SMH_DEST]
    sub r13, [rbp - SMH_NA]
    ST_PUT1 MS_KEYS, MS_VALUES, r13, rax

.smh_ok:
    xor eax, eax
    pop r13
    pop r12
    leave
    ret
.smh_fail:
    mov eax, -1
    pop r13
    pop r12
    leave
    ret
END_FUNC sort_merge_hi

;; ============================================================================
;; sort_merge_at(rbx = ms, rdi = i) -> eax = 0, or -1 with an exception
;;
;; Merge the runs at pending[i] and pending[i+1], which must be adjacent, and
;; leave the result as pending[i].  i is always the top or the one below it.
;;
;; Both ends are trimmed by galloping first: everything in A below B's first
;; element is already where it belongs, and so is everything in B above A's
;; last.  On data that is already largely ordered that trim IS the merge --
;; it is why an already-sorted list, which count_run has handed over as one
;; run, and a list of sorted runs cost so little.
;; ============================================================================
SMA_I     equ 8
SMA_IA    equ 16
SMA_NA    equ 24
SMA_IB    equ 32
SMA_NB    equ 40
SMA_FRAME equ 48                ; + 2 pushes = 64, 16-aligned
DEF_FUNC sort_merge_at, SMA_FRAME
    push r12
    push r13
    mov [rbp - SMA_I], rdi

    cmp dword [rel stw_requested], 0
    je .sma_no_stw
    call stw_safepoint
    mov rdi, [rbp - SMA_I]
.sma_no_stw:

    lea r12, [rbx + MS_PENDING]
    mov rax, rdi
    shl rax, 4
    add r12, rax                ; &pending[i]
    mov rax, [r12]
    mov [rbp - SMA_IA], rax
    mov rax, [r12 + 8]
    mov [rbp - SMA_NA], rax
    mov rax, [r12 + 16]
    mov [rbp - SMA_IB], rax
    mov rax, [r12 + 24]
    mov [rbp - SMA_NB], rax

    ; The merged run takes A's place, and anything above it slides down one.
    mov rax, [rbp - SMA_NA]
    add rax, [rbp - SMA_NB]
    mov [r12 + 8], rax
    mov rax, [rbx + MS_NRUNS]
    dec rax
    mov [rbx + MS_NRUNS], rax
    mov rcx, [rbp - SMA_I]
    lea rcx, [rcx + 2]
    cmp rcx, rax
    jne .sma_no_slide
    mov rax, [r12 + 32]
    mov [r12 + 16], rax
    mov rax, [r12 + 40]
    mov [r12 + 24], rax
.sma_no_slide:

    ; Where does B[0] belong in A?  Everything below that is already placed.
    mov r13, [rbp - SMA_IB]
    ST_LOAD rdi, MS_KEYS, r13
    mov rsi, [rbp - SMA_IA]
    mov rdx, [rbp - SMA_NA]
    xor ecx, ecx
    call sort_gallop_right
    cmp rax, -1
    je .sma_fail
    add [rbp - SMA_IA], rax
    sub [rbp - SMA_NA], rax
    jz .sma_ok

    ; Where does A[-1] belong in B?  Everything above that is already placed.
    mov r13, [rbp - SMA_IA]
    add r13, [rbp - SMA_NA]
    dec r13
    ST_LOAD rdi, MS_KEYS, r13
    mov rsi, [rbp - SMA_IB]
    mov rdx, [rbp - SMA_NB]
    lea rcx, [rdx - 1]
    call sort_gallop_left
    cmp rax, -1
    je .sma_fail
    mov [rbp - SMA_NB], rax
    test rax, rax
    jz .sma_ok

    mov rdi, [rbp - SMA_IA]
    mov rsi, [rbp - SMA_NA]
    mov rdx, [rbp - SMA_IB]
    mov rcx, [rbp - SMA_NB]
    cmp rsi, rcx
    jbe .sma_lo
    call sort_merge_hi
    jmp .sma_out
.sma_lo:
    call sort_merge_lo
.sma_out:
    pop r13
    pop r12
    leave
    ret
.sma_ok:
    xor eax, eax
    pop r13
    pop r12
    leave
    ret
.sma_fail:
    mov eax, -1
    pop r13
    pop r12
    leave
    ret
END_FUNC sort_merge_at

;; ============================================================================
;; sort_merge_collapse(rbx = ms) -> eax = 0, or -1 with an exception
;;
;; Restore the run-stack invariant after a push:
;;
;;     len[-3] > len[-2] + len[-1]   and   len[-2] > len[-1]
;;
;; BOTH conditions, and the four-deep one below with them.  Checking only the
;; first two is the version that was proved wrong in 2015: it admits stacks
;; the depth bound does not cover.
;; ============================================================================
DEF_FUNC sort_merge_collapse, 16 ; + 2 pushes = 32, 16-aligned
    push r12
    push r13
.smc_loop:
    mov rax, [rbx + MS_NRUNS]
    cmp rax, 1
    jbe .smc_ok
    lea r12, [rbx + MS_PENDING]
    mov r13, rax
    sub r13, 2                  ; n = nruns - 2, the index of the pair's left

    ; len[n-1] <= len[n] + len[n+1] ?
    test r13, r13
    jz .smc_check_three
    mov rax, r13
    dec rax
    shl rax, 4
    mov rcx, [r12 + rax + 8]        ; len[n-1]
    mov rax, r13
    shl rax, 4
    mov rdx, [r12 + rax + 8]        ; len[n]
    add rdx, [r12 + rax + 24]       ; + len[n+1]
    cmp rcx, rdx
    jbe .smc_pick

    ; len[n-2] <= len[n-1] + len[n] ?
    cmp r13, 2
    jb .smc_check_three
    mov rax, r13
    sub rax, 2
    shl rax, 4
    mov rcx, [r12 + rax + 8]        ; len[n-2]
    mov rax, r13
    dec rax
    shl rax, 4
    mov rdx, [r12 + rax + 8]        ; len[n-1]
    add rdx, [r12 + rax + 24]       ; + len[n]
    cmp rcx, rdx
    ja .smc_check_three

.smc_pick:
    ; Merge the smaller of the two neighbours into the middle run.
    mov rax, r13
    dec rax
    shl rax, 4
    mov rcx, [r12 + rax + 8]        ; len[n-1]
    mov rax, r13
    add rax, 1
    shl rax, 4
    cmp rcx, [r12 + rax + 8]        ; len[n+1]
    jae .smc_merge
    dec r13
.smc_merge:
    mov rdi, r13
    call sort_merge_at
    cmp eax, -1
    je .smc_fail
    jmp .smc_loop

.smc_check_three:
    ; len[n] <= len[n+1] ?
    mov rax, r13
    shl rax, 4
    mov rcx, [r12 + rax + 8]
    cmp rcx, [r12 + rax + 24]
    ja .smc_ok
    mov rdi, r13
    call sort_merge_at
    cmp eax, -1
    je .smc_fail
    jmp .smc_loop

.smc_ok:
    xor eax, eax
    pop r13
    pop r12
    leave
    ret
.smc_fail:
    mov eax, -1
    pop r13
    pop r12
    leave
    ret
END_FUNC sort_merge_collapse

;; ============================================================================
;; sort_force_collapse(rbx = ms) -> eax = 0, or -1 with an exception
;;
;; Merge everything that is left, smaller neighbour first.
;; ============================================================================
DEF_FUNC sort_force_collapse, 16 ; + 2 pushes = 32, 16-aligned
    push r12
    push r13
.sfc_loop:
    mov rax, [rbx + MS_NRUNS]
    cmp rax, 1
    jbe .sfc_ok
    lea r12, [rbx + MS_PENDING]
    mov r13, rax
    sub r13, 2
    test r13, r13
    jz .sfc_merge
    mov rax, r13
    dec rax
    shl rax, 4
    mov rcx, [r12 + rax + 8]        ; len[n-1]
    mov rax, r13
    add rax, 1
    shl rax, 4
    cmp rcx, [r12 + rax + 8]        ; len[n+1]
    jae .sfc_merge
    dec r13
.sfc_merge:
    mov rdi, r13
    call sort_merge_at
    cmp eax, -1
    je .sfc_fail
    jmp .sfc_loop
.sfc_ok:
    xor eax, eax
    pop r13
    pop r12
    leave
    ret
.sfc_fail:
    mov eax, -1
    pop r13
    pop r12
    leave
    ret
END_FUNC sort_force_collapse

;; ============================================================================
;; list_timsort(rdi = ms, rsi = keys, rdx = values or 0, rcx = n) -> eax = 0,
;;                                                or -1 with an exception
;;
;; The driver.  The caller supplies the MergeState -- it is nearly a kilobyte
;; and belongs in the caller's frame, because a comparator can run Python that
;; sorts another list and each sort needs its own.
;;
;; The caller owns keys and values; nothing here allocates or releases a
;; reference.  Everything moves as a Value, so a sort does no refcount work at
;; all, which is a thing CPython cannot say.
;; ============================================================================
LTS_N     equ 8
LTS_LO    equ 16
LTS_MINRUN equ 24
LTS_FRAME equ 32                ; + 2 pushes = 48, 16-aligned
global list_timsort
DEF_FUNC list_timsort, LTS_FRAME
    push rbx
    push r12

    mov rbx, rdi
    mov qword [rbx + MS_MINGALLOP], ST_MIN_GALLOP
    mov [rbx + MS_KEYS], rsi
    mov [rbx + MS_VALUES], rdx
    mov qword [rbx + MS_TKEYS], 0
    mov qword [rbx + MS_TVALS], 0
    mov qword [rbx + MS_ALLOCED], 0
    mov qword [rbx + MS_NRUNS], 0
    lea rax, [rel sort_cmp_general]
    mov [rbx + MS_CMP], rax
    mov [rbx + MS_ELEMCMP], rax
    mov [rbp - LTS_N], rcx

    cmp rcx, 2
    jb .lts_ok_nofree

    mov rdi, rsi
    mov rsi, rcx
    call sort_scan_types

    mov rdi, [rbp - LTS_N]
    call sort_minrun
    mov [rbp - LTS_MINRUN], rax

    mov qword [rbp - LTS_LO], 0

.lts_loop:
    mov r12, [rbp - LTS_N]
    sub r12, [rbp - LTS_LO]     ; how many remain
    jz .lts_final

    mov rdi, [rbp - LTS_LO]
    mov rsi, [rbp - LTS_N]
    call sort_count_run
    cmp rax, -1
    je .lts_fail
    mov r12, rax                ; the natural run's length

    ; Short of minrun?  Extend it with a binary insertion sort, up to
    ; whatever is left.
    cmp r12, [rbp - LTS_MINRUN]
    jae .lts_have_run
    mov rax, [rbp - LTS_N]
    sub rax, [rbp - LTS_LO]     ; what remains
    cmp rax, [rbp - LTS_MINRUN]
    jbe .lts_force_all
    mov rax, [rbp - LTS_MINRUN]
.lts_force_all:
    mov rdi, [rbp - LTS_LO]
    mov rsi, rdi
    add rsi, rax
    mov rdx, rdi
    add rdx, r12
    push rax
    push rax
    call sort_binarysort
    pop r12
    pop r12                     ; r12 = the forced length
    cmp eax, -1
    je .lts_fail

.lts_have_run:
    ; Push it, then restore the stack invariant.
    mov rax, [rbx + MS_NRUNS]
    lea rcx, [rbx + MS_PENDING]
    mov rdx, rax
    shl rdx, 4
    add rcx, rdx
    mov rdx, [rbp - LTS_LO]
    mov [rcx], rdx
    mov [rcx + 8], r12
    inc rax
    mov [rbx + MS_NRUNS], rax
    add [rbp - LTS_LO], r12

    call sort_merge_collapse
    cmp eax, -1
    je .lts_fail
    jmp .lts_loop

.lts_final:
    call sort_force_collapse
    cmp eax, -1
    je .lts_fail

.lts_ok:
    mov rdi, [rbx + MS_TKEYS]
    test rdi, rdi
    jz .lts_no_temp
    call ap_free
    mov rdi, [rbx + MS_TVALS]
    test rdi, rdi
    jz .lts_no_temp
    call ap_free
.lts_no_temp:
    mov qword [rbx + MS_TKEYS], 0
    mov qword [rbx + MS_TVALS], 0
.lts_ok_nofree:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.lts_fail:
    mov rdi, [rbx + MS_TKEYS]
    test rdi, rdi
    jz .lts_fail_no_temp
    call ap_free
    mov rdi, [rbx + MS_TVALS]
    test rdi, rdi
    jz .lts_fail_no_temp
    call ap_free
.lts_fail_no_temp:
    mov qword [rbx + MS_TKEYS], 0
    mov qword [rbx + MS_TVALS], 0
    mov eax, -1
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_timsort
