; valtest.asm - Self-test for the NaN-boxed Value encoding
;
; Reachable via `./apython --selftest-value`.  Encoding bugs in a NaN box are
; near-impossible to diagnose from Python-level symptoms (a mis-tagged value
; simply segfaults somewhere unrelated), so the boundary cases are checked
; directly against the encoder here.
;
; value_selftest() -> rax = 0 on success, else a nonzero case id of the form
;                     (group_number * 1000 + case_index + 1).

%include "macros.inc"
%include "object.inc"

extern sys_write
extern int_to_i64
extern obj_dealloc
extern val_from_i64
extern val_from_i64_p
extern val_unpack

section .rodata

; --- Group 1: integers.  (value, 1 = expect immediate / 0 = expect boxed)
align 16
int_cases:
    dq 0,                    1
    dq 1,                    1
    dq -1,                   1
    dq 0x0003ffffffffffff,   1      ; 2^50 - 1  (largest immediate)
    dq 0xfffc000000000000,   1      ; -2^50     (smallest immediate)
    dq 0x0004000000000000,   0      ; 2^50      (first boxed)
    dq 0xfffbffffffffffff,   0      ; -2^50 - 1 (first boxed)
    dq 4611686018427387904,  0      ; 2^62
    dq -4611686018427387904, 0      ; -2^62
    dq 0x7fffffffffffffff,   0      ; INT64_MAX
    dq 0x8000000000000000,   0      ; INT64_MIN
int_cases_end:
INT_CASE_COUNT equ (int_cases_end - int_cases) / 16

; --- Group 2: floats.  (raw double bits, expected decoded bits)
align 16
float_cases:
    dq 0x0000000000000000, 0x0000000000000000   ; +0.0
    dq 0x8000000000000000, 0x8000000000000000   ; -0.0
    dq 0x3ff0000000000000, 0x3ff0000000000000   ; 1.0
    dq 0xbff0000000000000, 0xbff0000000000000   ; -1.0
    dq 0x0000000000000001, 0x0000000000000001   ; smallest subnormal
    dq 0x800fffffffffffff, 0x800fffffffffffff   ; largest negative subnormal
    dq 0x7fefffffffffffff, 0x7fefffffffffffff   ; DBL_MAX
    dq 0xffefffffffffffff, 0xffefffffffffffff   ; -DBL_MAX
    dq 0x7ff0000000000000, 0x7ff0000000000000   ; +inf
    dq 0xfff0000000000000, 0xfff0000000000000   ; -inf
    dq 0x7ff8000000000000, 0x7ff8000000000000   ; canonical quiet NaN
    dq 0x7fffffffffffffff, 0x7fffffffffffffff   ; positive NaN, max payload
    dq 0xfff0000000000001, 0xfff0000000000001   ; negative NaN below V_NAN_LIM
    dq 0xfff0ffffffffffff, 0xfff0ffffffffffff   ; negative NaN, last safe one
    dq 0xfff1000000000000, 0x7ff8000000000000   ; first purified NaN
    dq 0xfff8000000000000, 0x7ff8000000000000   ; x86 default QNaN (inf - inf)
    dq 0xffffffffffffffff, 0x7ff8000000000000   ; all-ones NaN
float_cases_end:
FLOAT_CASE_COUNT equ (float_cases_end - float_cases) / 16

; --- Group 4: V_PACK / V_UNPACK round trips.
; (payload, tag, expected payload, expected tag).  An expected tag of -1 means
; "expect a heap-boxed integer whose value is the input payload".
align 16
pack_cases:
    dq 0,                    TAG_NULL,     0,                    TAG_NULL
    dq 5,                    TAG_SMALLINT, 5,                    TAG_SMALLINT
    dq -5,                   TAG_SMALLINT, -5,                   TAG_SMALLINT
    dq 0x0003ffffffffffff,   TAG_SMALLINT, 0x0003ffffffffffff,   TAG_SMALLINT
    dq 0xfffc000000000000,   TAG_SMALLINT, 0xfffc000000000000,   TAG_SMALLINT
    dq 0x0004000000000000,   TAG_SMALLINT, 0x0004000000000000,   -1
    dq 0x8000000000000000,   TAG_SMALLINT, 0x8000000000000000,   -1
    dq 0x3ff0000000000000,   TAG_FLOAT,    0x3ff0000000000000,   TAG_FLOAT
    dq 0x8000000000000000,   TAG_FLOAT,    0x8000000000000000,   TAG_FLOAT
    dq 0xfff0000000000000,   TAG_FLOAT,    0xfff0000000000000,   TAG_FLOAT
    dq 0xfff8000000000000,   TAG_FLOAT,    0x7ff8000000000000,   TAG_FLOAT
    dq 0x0000000000000001,   TAG_FLOAT,    0x0000000000000001,   TAG_FLOAT
    dq 12345678901,          TAG_SLEEP,    12345678901,          TAG_SLEEP
    dq 0x0000000300000007,   TAG_IO_WAIT,  0x0000000300000007,   TAG_IO_WAIT
pack_cases_end:
PACK_CASE_COUNT equ (pack_cases_end - pack_cases) / 32

msg_ok:     db "value selftest: OK", 10
msg_ok_len  equ $ - msg_ok
msg_fail:   db "value selftest: FAILED case "
msg_fail_len equ $ - msg_fail

section .bss
fail_buf:   resb 32

section .text

;; ============================================================================
;; value_selftest() -> rax: 0 on success, else the failing case id
;; ============================================================================
DEF_FUNC value_selftest, 8            ; 5 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; ---------------------------------------------------------------- group 1
    xor r12, r12                    ; case index
.int_loop:
    cmp r12, INT_CASE_COUNT
    jae .int_done

    mov rdx, r12
    shl rdx, 4                      ; 16 bytes per case
    lea rax, [rel int_cases]
    mov r13, [rax + rdx]            ; the int64 under test
    mov r14, [rax + rdx + 8]        ; 1 = expect immediate

    mov rdi, r13
    call val_from_i64
    mov rbx, rax                    ; rbx = encoded Value

    test r14, r14
    jz .int_expect_boxed

    ; Expect an immediate: must land in int space and decode exactly.
    cmp rbx, [rel v_int_lo]
    jb .int_fail
    mov rax, rbx
    V_TO_I64 rax
    cmp rax, r13
    jne .int_fail
    ; ...and val_unpack must agree.
    mov rdi, rbx
    call val_unpack
    cmp edx, TAG_SMALLINT
    jne .int_fail
    cmp rax, r13
    jne .int_fail
    jmp .int_next

.int_expect_boxed:
    ; Expect a heap PyIntObject: raw pointer space, non-NULL, exact value.
    test rbx, rbx
    jz .int_fail
    cmp rbx, [rel v_int_lo]
    jae .int_fail
    mov rax, rbx
    shr rax, 48
    jnz .int_fail                   ; must be a raw pointer (high16 == 0)
    mov rdi, rbx
    mov edx, TAG_PTR
    call int_to_i64
    cmp rax, r13
    jne .int_fail
    mov rdi, rbx
    call obj_dealloc

.int_next:
    inc r12
    jmp .int_loop
.int_done:

    ; ---------------------------------------------------------------- group 2
    xor r12, r12
.flt_loop:
    cmp r12, FLOAT_CASE_COUNT
    jae .flt_done

    mov rdx, r12
    shl rdx, 4                      ; 16 bytes per case
    lea rax, [rel float_cases]
    mov r13, [rax + rdx]            ; raw double bits
    mov r14, [rax + rdx + 8]        ; expected decoded bits

    mov rbx, r13
    V_FROM_F64 rbx, rcx             ; rbx = encoded Value

    ; Must classify as a float: strictly between pointer space and tag space.
    mov rax, rbx
    shr rax, 48
    jz .flt_fail                    ; would look like a pointer
    cmp rax, VH_F64_MAX
    ja .flt_fail                    ; would look like a sentinel or an int

    ; Must decode to the expected (possibly purified) bit pattern.
    mov rax, rbx
    V_TO_F64 rax
    cmp rax, r14
    jne .flt_fail

    ; val_unpack must agree.
    mov rdi, rbx
    call val_unpack
    cmp edx, TAG_FLOAT
    jne .flt_fail
    cmp rax, r14
    jne .flt_fail

    inc r12
    jmp .flt_loop
.flt_done:

    ; ---------------------------------------------------------------- group 3
    ; Pointer and NULL handling.
    xor r12, r12

    ; NULL: unpacks to TAG_NULL, and DECREF_V must not touch memory.
    xor rdi, rdi
    call val_unpack
    test edx, edx
    jnz .ptr_fail
    test rax, rax
    jnz .ptr_fail
    inc r12

    xor rax, rax
    DECREF_V rax, rcx               ; must be a no-op, not a NULL dereference
    inc r12

    ; A real object: INCREF_V / DECREF_V must move its refcount by one.
    lea rbx, [rel probe_obj]
    mov dword [rbx + PyObject.ob_ref_local], 7
    mov dword [rbx + PyObject.ob_ref_shared], 0
    mov eax, [gs:ThreadState.ts_tid]
    mov [rbx + PyObject.ob_tid], eax
    INCREF_V rbx, rcx
    cmp dword [rbx + PyObject.ob_ref_local], 8
    jne .ptr_fail
    inc r12
    DECREF_V rbx, rcx
    cmp dword [rbx + PyObject.ob_ref_local], 7
    jne .ptr_fail
    inc r12

    ; Immediates must never be refcounted.
    mov edi, 12345
    call val_from_i64
    mov rbx, rax
    cmp rbx, [rel v_int_lo]
    jb .ptr_fail
    INCREF_V rbx, rcx               ; must be a no-op
    DECREF_V rbx, rcx               ; must be a no-op
    mov rax, rbx
    V_TO_I64 rax
    cmp rax, 12345
    jne .ptr_fail
    inc r12

    ; ---------------------------------------------------------------- group 4
    ; V_PACK / V_UNPACK must round trip every (payload, tag) pair the VM can
    ; hold.  These two macros carry the whole migration: a mistake here
    ; corrupts values silently rather than crashing.
    xor r12, r12
.pk_loop:
    cmp r12, PACK_CASE_COUNT
    jae .pk_done

    mov rdx, r12
    shl rdx, 5                      ; 32 bytes per case
    lea rax, [rel pack_cases]
    add rax, rdx
    mov r13, [rax]                  ; payload
    mov r14, [rax + 8]              ; tag
    mov r15, [rax + 16]             ; expected payload
    mov rbx, [rax + 24]             ; expected tag (-1 = expect boxed int)

    push rbx
    push r15
    mov rdi, r13
    mov rsi, r14
    V_PACK rdi, rsi                 ; rdi = Value
    V_UNPACK rdi, rsi               ; rdi = payload, rsi = tag
    pop r15
    pop rbx

    cmp rbx, -1
    je .pk_boxed

    cmp rsi, rbx
    jne .pk_fail
    cmp rdi, r15
    jne .pk_fail
    jmp .pk_next

.pk_boxed:
    ; Expect a heap PyIntObject holding the original value.
    cmp rsi, TAG_PTR
    jne .pk_fail
    mov edx, TAG_PTR
    push rdi
    call int_to_i64
    cmp rax, r15
    pop rdi
    jne .pk_fail
    call obj_dealloc

.pk_next:
    inc r12
    jmp .pk_loop
.pk_done:


    ; ---------------------------------------------------------------- group 5
    ; The V_PACK / V_UNPACK operand SHAPES.
    ;
    ; Both macros now reach a helper that speaks (rax, rdx), so an operand
    ; pair that is anything else gets shuffled around the call.  The shuffle
    ; is chosen at assembly time by %ifidni, and its whole job is to leave
    ; every register that is not an operand exactly as it found it.  Group 4
    ; exercises one shape thoroughly; this exercises all of them, and checks
    ; the thing that would otherwise fail silently -- that rax survives a
    ; macro whose operands are not rax, and rdx one whose operands are not
    ; rdx.  A shape used at a single site in the tree is covered here and
    ; nowhere else.
    ;
    ; rbx carries the case number; SH_WITNESS is a value no arm produces.
%define SH_WITNESS 0x5AFE0F1CE5AFE001

    ; --- V_PACK rax, rdx -- the 1062-site shape, no shuffle at all
    mov ebx, 1
    mov eax, 42
    mov edx, TAG_SMALLINT
    V_PACK rax, rdx
    mov r12, V_INT(42)
    cmp rax, r12
    jne .sh_fail

    ; --- V_PACK rdi, rdx -- %2 is rdx, so rax is parked in rdi by an xchg
    mov ebx, 2
    mov r13, SH_WITNESS
    mov rax, r13
    mov edi, 42
    mov edx, TAG_SMALLINT
    V_PACK rdi, rdx
    cmp rdi, r12
    jne .sh_fail
    cmp rax, r13                    ; the parked rax must have come back
    jne .sh_fail

    ; --- V_PACK rdi, rsi -- neither operand is rax or rdx: xchg AND push
    mov ebx, 3
    mov rax, r13
    mov rdx, r13
    mov edi, 42
    mov esi, TAG_SMALLINT
    V_PACK rdi, rsi
    cmp rdi, r12
    jne .sh_fail
    cmp rax, r13
    jne .sh_fail
    cmp rdx, r13
    jne .sh_fail

    ; --- V_PACK rax, rsi -- %1 is rax, %2 is not rdx
    mov ebx, 4
    mov rdx, r13
    mov eax, 42
    mov esi, TAG_SMALLINT
    V_PACK rax, rsi
    cmp rax, r12
    jne .sh_fail
    cmp rdx, r13
    jne .sh_fail

    ; --- V_PACK rdx, rsi -- %1 is rdx
    mov ebx, 5
    mov rax, r13
    mov edx, 42
    mov esi, TAG_SMALLINT
    V_PACK rdx, rsi
    cmp rdx, r12
    jne .sh_fail
    cmp rax, r13
    jne .sh_fail

    ; --- V_PACK rdx, rax -- the reversed pair: both are the helper's own
    mov ebx, 6
    mov edx, 42
    mov eax, TAG_SMALLINT
    V_PACK rdx, rax
    cmp rdx, r12
    jne .sh_fail

    ; --- V_PACK rdi, rax -- %2 is rax, the single-site shape
    mov ebx, 7
    mov rdx, r13
    mov edi, 42
    mov eax, TAG_SMALLINT
    V_PACK rdi, rax
    cmp rdi, r12
    jne .sh_fail
    cmp rdx, r13
    jne .sh_fail

    ; --- and the same seven for V_UNPACK, from the Value back to the pair ---

    mov ebx, 11
    mov rax, r12
    V_UNPACK rax, rdx
    cmp rax, 42
    jne .sh_fail
    cmp rdx, TAG_SMALLINT
    jne .sh_fail

    mov ebx, 12
    mov r13, SH_WITNESS
    mov rax, r13
    mov rdi, r12
    V_UNPACK rdi, rdx
    cmp rdi, 42
    jne .sh_fail
    cmp rdx, TAG_SMALLINT
    jne .sh_fail
    cmp rax, r13
    jne .sh_fail

    mov ebx, 13
    mov rax, r13
    mov rdx, r13
    mov rdi, r12
    V_UNPACK rdi, rsi
    cmp rdi, 42
    jne .sh_fail
    cmp rsi, TAG_SMALLINT
    jne .sh_fail
    cmp rax, r13
    jne .sh_fail
    cmp rdx, r13
    jne .sh_fail

    mov ebx, 14
    mov rdx, r13
    mov rax, r12
    V_UNPACK rax, rsi
    cmp rax, 42
    jne .sh_fail
    cmp rsi, TAG_SMALLINT
    jne .sh_fail
    cmp rdx, r13
    jne .sh_fail

    mov ebx, 15
    mov rax, r13
    mov rdx, r12
    V_UNPACK rdx, rsi
    cmp rdx, 42
    jne .sh_fail
    cmp rsi, TAG_SMALLINT
    jne .sh_fail
    cmp rax, r13
    jne .sh_fail

    mov ebx, 16
    mov rdx, r12
    V_UNPACK rdx, rax
    cmp rdx, 42
    jne .sh_fail
    cmp rax, TAG_SMALLINT
    jne .sh_fail

    mov ebx, 17
    mov rdx, r13
    mov rdi, r12
    V_UNPACK rdi, rax
    cmp rdi, 42
    jne .sh_fail
    cmp rax, TAG_SMALLINT
    jne .sh_fail
    cmp rdx, r13
    jne .sh_fail

    ; --- the two arms the shapes above never reach: a pointer and an empty
    ; --- slot.  A pointer is answered inline and must not reach the helper;
    ; --- an empty slot must come back as (0, 0) rather than as a pointer.
    mov ebx, 21
    lea rdi, [rel probe_obj]
    mov r13, rdi
    V_UNPACK rdi, rsi
    cmp rdi, r13
    jne .sh_fail
    cmp rsi, TAG_PTR
    jne .sh_fail

    mov ebx, 22
    xor edi, edi
    V_UNPACK rdi, rsi
    test rdi, rdi
    jnz .sh_fail
    test rsi, rsi
    jnz .sh_fail

    ; --- a TAG_SMALLINT payload OUTSIDE the immediate range, so V_PACK's
    ; --- boxing arm runs.  It reaches ap_malloc and GMP through
    ; --- val_from_i64_p; the point is that it still preserves rdi's caller.
    mov ebx, 23
    mov r13, SH_WITNESS
    mov rdi, r13
    mov r14, 1 << 55
    mov rsi, TAG_SMALLINT
    V_PACK r14, rsi                 ; r14 = an owned heap PyIntObject
    cmp rdi, r13                    ; the boxing arm parks rdi in its scratch
    jne .sh_fail
    mov rdi, r14
    mov edx, TAG_PTR
    call int_to_i64
    mov r15, 1 << 55
    cmp rax, r15
    jne .sh_fail
    mov rdi, r14
    call obj_dealloc

    ; ---------------------------------------------------------------- success
    xor eax, eax
    jmp .done

.int_fail:
    lea rax, [r12 + 1]
    add rax, 1000
    jmp .done
.flt_fail:
    lea rax, [r12 + 1]
    add rax, 2000
    jmp .done
.ptr_fail:
    lea rax, [r12 + 1]
    add rax, 3000
    jmp .done
.pk_fail:
    lea rax, [r12 + 1]
    add rax, 4000
    jmp .done
.sh_fail:
    mov rax, rbx
    add rax, 5000

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC value_selftest

;; ============================================================================
;; value_selftest_main() -> rax: process exit status
;;
;; Runs value_selftest and reports the outcome on stdout.
;; ============================================================================
DEF_FUNC value_selftest_main, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    call value_selftest
    mov rbx, rax
    test rbx, rbx
    jnz .fail

    mov edi, 1
    lea rsi, [rel msg_ok]
    mov edx, msg_ok_len
    call sys_write
    xor eax, eax
    pop rbx
    leave
    ret

.fail:
    mov edi, 1
    lea rsi, [rel msg_fail]
    mov edx, msg_fail_len
    call sys_write

    ; Render the case id as decimal into fail_buf, backwards from the end.
    lea rsi, [rel fail_buf + 31]
    mov byte [rsi], 10              ; trailing newline
    mov rax, rbx
    mov ecx, 10
.digits:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .digits

    lea rdx, [rel fail_buf + 32]
    sub rdx, rsi                    ; length
    mov edi, 1
    call sys_write

    mov eax, 1
    pop rbx
    leave
    ret
END_FUNC value_selftest_main

section .data
align 16
probe_obj:
    dd 1, 0, 1, 0   ; ob_ref_local=1, ob_ref_shared=0, ob_tid=1, ob_mutex=0
    dq 0            ; ob_type
