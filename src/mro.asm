;; ============================================================================
;; mro.asm -- C3 linearization, and walking it
;;
;; A class could only ever have one base: `class C(A, B)` stored A and dropped
;; B, silently, so `C().b()` was an AttributeError and `isinstance(C(), B)` was
;; False.  A heaptype now records every base in tp_bases and the C3
;; linearization of them in tp_mro.
;;
;; Every place that used to follow tp_base to resolve an attribute or answer a
;; subclass question steps with type_mro_next instead: given the type the
;; search started from and where it has got to, it returns the next entry of
;; that type's MRO.  A static type has no tp_mro, and for it the answer is
;; still tp_base -- which is why the single-inheritance paths did not have to
;; change shape.
;; ============================================================================

%include "object.inc"
%include "macros.inc"
%include "value.inc"

extern ap_malloc
extern ap_free
extern tuple_new
extern obj_dealloc
extern obj_incref
extern object_type
extern set_exception
extern exc_TypeError_type

section .text

;; ============================================================================
;; type_mro_next(rdi = origin type, rsi = current type) -> rax = next or NULL
;;
;; The origin's tp_mro is authoritative when it exists; otherwise the answer is
;; the current type's tp_base, which is what single inheritance always gave.
;; ============================================================================
DEF_FUNC_BARE type_mro_next
    test rsi, rsi
    jz .mn_none
    test rdi, rdi
    jz .mn_base
    mov r8, [rdi + PyTypeObject.tp_mro]
    test r8, r8
    jz .mn_base
    mov rcx, [r8 + PyTupleObject.ob_size]
    mov r9, [r8 + PyTupleObject.ob_item]
    xor edx, edx
.mn_scan:
    cmp rdx, rcx
    jge .mn_base                    ; current is not on this MRO after all
    cmp [r9 + rdx*8], rsi
    je .mn_found
    inc rdx
    jmp .mn_scan
.mn_found:
    inc rdx
    cmp rdx, rcx
    jge .mn_none
    mov rax, [r9 + rdx*8]
    ret
.mn_base:
    mov rax, [rsi + PyTypeObject.tp_base]
    test rax, rax
    jnz .mn_out
    ; A static type's chain ends at 0, not at object; every lookup and
    ; subclass test stopped one type short of object.
    lea rax, [rel object_type]
    cmp rsi, rax
    je .mn_none
.mn_out:
    ret
.mn_none:
    xor eax, eax
    ret
END_FUNC type_mro_next

;; ============================================================================
;; type_check_is_class(rdi = Value) -> eax 0/1
;; True when the value is a type object: its metatype is type_type,
;; user_type_metatype or exc_metatype.
;; ============================================================================
DEF_FUNC_BARE type_check_is_class
    V_TEST_PTR rdi, rax
    ja .tc_no
    test rdi, rdi
    jz .tc_no
    mov rax, [rdi + PyObject.ob_type]
    extern type_type
    lea rcx, [rel type_type]
    cmp rax, rcx
    je .tc_yes
    extern user_type_metatype
    lea rcx, [rel user_type_metatype]
    cmp rax, rcx
    je .tc_yes
    extern exc_metatype
    lea rcx, [rel exc_metatype]
    cmp rax, rcx
    je .tc_yes
    ; A user metaclass is a class too: `class C(metaclass=M)` gives C an
    ; ob_type of M, which is none of the three built-in metatypes.
    push rdi
    mov rdi, rax
    lea rsi, [rel type_type]
    call type_is_subtype
    pop rdi
    test eax, eax
    jnz .tc_yes
.tc_no:
    xor eax, eax
    ret
.tc_yes:
    mov eax, 1
    ret
END_FUNC type_check_is_class

;; ============================================================================
;; type_custom_check(rdi = class, rsi = object Value, rdx = dunder name cstr)
;;   -> rax: 1 = yes, 0 = no, -1 = no override, decide the normal way
;; Fails: -1
;;   -- the hook raised, or the truth of what it answered could not be asked.
;;   -1 with nothing pending is still "no override".
;;
;; A metaclass may define __instancecheck__ / __subclasscheck__; ABCMeta does,
;; and that is how isinstance() consults a virtual-subclass registry instead of
;; the MRO.  Only a *user* metatype is consulted -- the three builtin metatypes
;; have no such method, and looking one up on every isinstance() would cost a
;; dict probe per call.
;; ============================================================================
TCI_CLS   equ 8
TCI_OBJ   equ 16
TCI_NAME  equ 24
TCI_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC type_custom_check, TCI_FRAME
    push rbx
    mov [rbp - TCI_CLS], rdi
    mov [rbp - TCI_OBJ], rsi
    mov [rbp - TCI_NAME], rdx

    mov rdi, [rdi + PyObject.ob_type]       ; the metatype
    lea rax, [rel type_type]
    cmp rdi, rax
    je .tcc_none
    extern user_type_metatype
    lea rax, [rel user_type_metatype]
    cmp rdi, rax
    je .tcc_none
    extern exc_metatype
    lea rax, [rel exc_metatype]
    cmp rdi, rax
    je .tcc_none

    mov rsi, [rbp - TCI_NAME]
    extern dunder_lookup
    call dunder_lookup
    V_UNPACK rax, rdx
    test edx, edx
    jz .tcc_none

    ; call it as method(cls, obj)
    mov rdi, rax
    mov rcx, [rdi + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .tcc_none
    sub rsp, 16
    mov rax, [rbp - TCI_CLS]
    mov [rsp], rax
    mov rax, [rbp - TCI_OBJ]
    mov [rsp + 8], rax
    mov rsi, rsp
    mov edx, 2
    call rcx
    ERR_PENDING .tcc_raised
    V_UNPACK rax, rdx
    add rsp, 16
    test edx, edx
    jz .tcc_none

    push rax
    push rdx
    mov rdi, rax
    V_PACK rdi, rdx
    extern obj_is_true
    call obj_is_true            ; err: its -1, with the exception, is this function's too
    mov rbx, rax
    pop rdx
    pop rdi
    DECREF_VAL rdi, rdx
    mov rax, rbx
    pop rbx
    leave
    ret

.tcc_raised:                    ; the hook raised: -1 again, but with it pending
    add rsp, 16
.tcc_none:
    mov rax, -1
    pop rbx
    leave
    ret
END_FUNC type_custom_check

;; ============================================================================
;; type_is_subtype(rdi = candidate subtype, rsi = type) -> eax 0/1
;; ============================================================================
DEF_FUNC_BARE type_is_subtype
    test rdi, rdi
    jz .st_no
    mov r10, rdi                    ; origin
    mov r11, rsi                    ; target
    mov rsi, rdi                    ; walker
.st_loop:
    test rsi, rsi
    jz .st_no
    cmp rsi, r11
    je .st_yes
    mov rdi, r10
    call type_mro_next
    mov rsi, rax
    jmp .st_loop
.st_yes:
    mov eax, 1
    ret
.st_no:
    xor eax, eax
    ret
END_FUNC type_is_subtype

;; ============================================================================
;; type_mro_len(rdi = type) -> rax = number of entries in its linearization
;; ============================================================================
DEF_FUNC_BARE type_mro_len
    test rdi, rdi
    jz .ml_zero
    mov rax, [rdi + PyTypeObject.tp_mro]
    test rax, rax
    jz .ml_chain
    mov rax, [rax + PyTupleObject.ob_size]
    ret
.ml_chain:
    xor eax, eax
    lea rcx, [rel object_type]
.ml_walk:
    test rdi, rdi
    jz .ml_done
    inc rax
    cmp rdi, rcx
    je .ml_done                     ; object terminates the chain
    mov rdi, [rdi + PyTypeObject.tp_base]
    test rdi, rdi
    jnz .ml_walk
    inc rax                         ; the implicit object at the end
.ml_done:
    ret
.ml_zero:
    xor eax, eax
    ret
END_FUNC type_mro_len

;; ============================================================================
;; type_mro_fill(rdi = type, rsi = dest array) -> rax = count written
;; ============================================================================
DEF_FUNC_BARE type_mro_fill
    xor eax, eax
    test rdi, rdi
    jz .mf_done
    mov r8, [rdi + PyTypeObject.tp_mro]
    test r8, r8
    jz .mf_chain
    mov rcx, [r8 + PyTupleObject.ob_size]
    mov r9, [r8 + PyTupleObject.ob_item]
.mf_copy:
    cmp rax, rcx
    jge .mf_done
    mov rdx, [r9 + rax*8]
    mov [rsi + rax*8], rdx
    inc rax
    jmp .mf_copy
.mf_chain:
    test rdi, rdi
    jz .mf_object
    mov [rsi + rax*8], rdi
    inc rax
    mov rdi, [rdi + PyTypeObject.tp_base]
    jmp .mf_chain
.mf_object:
    ; Most static types leave tp_base at 0 rather than pointing at object, so
    ; a chain walk ends one short and object never entered the linearization:
    ; isinstance(D(), object) was False for `class D(dict)`.
    test rax, rax
    jz .mf_done
    lea rcx, [rel object_type]
    cmp [rsi + rax*8 - 8], rcx
    je .mf_done
    mov [rsi + rax*8], rcx
    inc rax
.mf_done:
    ret
END_FUNC type_mro_fill

;; ============================================================================
;; mro_compute(rdi = the new type, rsi = bases tuple or NULL)
;;   -> rax = new tuple holding the C3 linearization, one strong reference
;; Fails: 0
;;
;; L[C] = C + merge(L[B1], ..., L[Bn], [B1, ..., Bn]), taking as the next entry
;; the first sequence head that appears in no sequence's tail.
;; ============================================================================
MC_TYPE  equ 8
MC_BASES equ 16
MC_NSEQ  equ 24         ; number of sequences = nbases + 1
MC_SEQS  equ 32         ; {start, len, pos} x nseq
MC_POOL  equ 40         ; concatenated sequence contents
MC_OUT   equ 48         ; result array
MC_OUTN  equ 56
MC_TOTAL equ 64
MC_FRAME equ 88            ; + 5 pushes = 128, 16-aligned
SEQ_START equ 0
SEQ_LEN   equ 8
SEQ_POS   equ 16
SEQ_SIZE  equ 24
DEF_FUNC mro_compute, MC_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov [rbp - MC_TYPE], rdi
    mov [rbp - MC_BASES], rsi
    mov qword [rbp - MC_SEQS], 0
    mov qword [rbp - MC_POOL], 0
    mov qword [rbp - MC_OUT], 0

    xor r14d, r14d                  ; nbases
    test rsi, rsi
    jz .mc_have_n
    mov r14, [rsi + PyTupleObject.ob_size]
.mc_have_n:

    ; Upper bound on the pool: every base's linearization, plus the bases
    ; sequence itself.
    mov r15, r14                    ; running total
    xor ebx, ebx
.mc_count:
    cmp rbx, r14
    jge .mc_counted
    mov rax, [rbp - MC_BASES]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdi, [rax + rbx*8]
    call type_mro_len
    add r15, rax
    inc rbx
    jmp .mc_count
.mc_counted:
    mov [rbp - MC_TOTAL], r15

    ; Sequence table
    lea rax, [r14 + 1]
    mov [rbp - MC_NSEQ], rax
    imul rdi, rax, SEQ_SIZE
    call ap_malloc
    mov [rbp - MC_SEQS], rax
    mov r13, rax                    ; r13 = seqs

    lea rdi, [r15 * 8]
    add rdi, 8
    call ap_malloc
    mov [rbp - MC_POOL], rax
    mov r12, rax                    ; r12 = pool cursor

    ; One sequence per base: its own linearization.
    xor ebx, ebx
.mc_fill:
    cmp rbx, r14
    jge .mc_filled
    mov rax, [rbp - MC_BASES]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdi, [rax + rbx*8]
    mov rsi, r12
    call type_mro_fill
    imul rcx, rbx, SEQ_SIZE
    mov [r13 + rcx + SEQ_START], r12
    mov [r13 + rcx + SEQ_LEN], rax
    mov qword [r13 + rcx + SEQ_POS], 0
    lea r12, [r12 + rax*8]
    inc rbx
    jmp .mc_fill
.mc_filled:

    ; And a final sequence holding the bases in order.
    imul rcx, r14, SEQ_SIZE
    mov [r13 + rcx + SEQ_START], r12
    mov [r13 + rcx + SEQ_LEN], r14
    mov qword [r13 + rcx + SEQ_POS], 0
    xor ebx, ebx
.mc_bases:
    cmp rbx, r14
    jge .mc_based
    mov rax, [rbp - MC_BASES]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rax, [rax + rbx*8]
    mov [r12 + rbx*8], rax
    inc rbx
    jmp .mc_bases
.mc_based:

    ; Output: the class itself, then the merge.
    mov rdi, [rbp - MC_TOTAL]
    add rdi, 2
    shl rdi, 3
    call ap_malloc
    mov [rbp - MC_OUT], rax
    mov rcx, [rbp - MC_TYPE]
    mov [rax], rcx
    mov qword [rbp - MC_OUTN], 1

.mc_merge:
    ; Find the first head that is in no tail.
    xor r15d, r15d                  ; candidate = NULL
    xor rbx, rbx                    ; sequence index
.mc_pick:
    cmp rbx, [rbp - MC_NSEQ]
    jge .mc_picked
    imul rcx, rbx, SEQ_SIZE
    mov rdx, [r13 + rcx + SEQ_POS]
    cmp rdx, [r13 + rcx + SEQ_LEN]
    jge .mc_pick_next
    mov r12, [r13 + rcx + SEQ_START]
    mov r12, [r12 + rdx*8]          ; candidate under test

    ; Reject it if it appears in any sequence's tail.
    xor r8, r8
.mc_tail:
    cmp r8, [rbp - MC_NSEQ]
    jge .mc_accept
    imul r9, r8, SEQ_SIZE
    mov r10, [r13 + r9 + SEQ_POS]
    inc r10
    mov r11, [r13 + r9 + SEQ_LEN]
.mc_tail_scan:
    cmp r10, r11
    jge .mc_tail_next
    mov rax, [r13 + r9 + SEQ_START]
    cmp [rax + r10*8], r12
    je .mc_pick_next
    inc r10
    jmp .mc_tail_scan
.mc_tail_next:
    inc r8
    jmp .mc_tail
.mc_accept:
    mov r15, r12
    jmp .mc_picked
.mc_pick_next:
    inc rbx
    jmp .mc_pick

.mc_picked:
    test r15, r15
    jnz .mc_take

    ; Nothing selectable: either everything is consumed, or the hierarchy is
    ; inconsistent.
    xor rbx, rbx
.mc_drain_check:
    cmp rbx, [rbp - MC_NSEQ]
    jge .mc_done
    imul rcx, rbx, SEQ_SIZE
    mov rdx, [r13 + rcx + SEQ_POS]
    cmp rdx, [r13 + rcx + SEQ_LEN]
    jl .mc_inconsistent
    inc rbx
    jmp .mc_drain_check

.mc_take:
    mov rax, [rbp - MC_OUT]
    mov rcx, [rbp - MC_OUTN]
    mov [rax + rcx*8], r15
    inc rcx
    mov [rbp - MC_OUTN], rcx

    ; Advance every sequence whose head is the entry just taken.
    xor rbx, rbx
.mc_advance:
    cmp rbx, [rbp - MC_NSEQ]
    jge .mc_merge
    imul rcx, rbx, SEQ_SIZE
    mov rdx, [r13 + rcx + SEQ_POS]
    cmp rdx, [r13 + rcx + SEQ_LEN]
    jge .mc_advance_next
    mov rax, [r13 + rcx + SEQ_START]
    cmp [rax + rdx*8], r15
    jne .mc_advance_next
    inc rdx
    mov [r13 + rcx + SEQ_POS], rdx
.mc_advance_next:
    inc rbx
    jmp .mc_advance

.mc_done:
    ; Materialise the result.
    mov rdi, [rbp - MC_OUTN]
    call tuple_new
    mov r12, rax
    mov r13, [rax + PyTupleObject.ob_item]
    xor rbx, rbx
.mc_store:
    cmp rbx, [rbp - MC_OUTN]
    jge .mc_stored
    mov rax, [rbp - MC_OUT]
    mov rax, [rax + rbx*8]
    mov [r13 + rbx*8], rax
    mov rdi, rax
    call obj_incref
    inc rbx
    jmp .mc_store
.mc_stored:
    mov rdi, [rbp - MC_SEQS]
    call ap_free
    mov rdi, [rbp - MC_POOL]
    call ap_free
    mov rdi, [rbp - MC_OUT]
    call ap_free
    mov rax, r12
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.mc_inconsistent:
    mov rdi, [rbp - MC_SEQS]
    call ap_free
    mov rdi, [rbp - MC_POOL]
    call ap_free
    mov rdi, [rbp - MC_OUT]
    call ap_free
    SET_EXC exc_TypeError_type, "Cannot create a consistent method resolution order (MRO) for bases"
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC mro_compute
