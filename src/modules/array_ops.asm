; array_ops.asm - sequence operators and full slicing for array.array
;
; Split from src/modules/array.asm to keep every hand-written assembly file
; well under the 100 KB cap.  Owns sq_concat, sq_inplace_concat, sq_repeat,
; sq_inplace_repeat, sq_contains, slice get/set/del, and their tp_dict dunder
; wrappers.

%include "macros.inc"
%include "object.inc"
%include "value.inc"

extern array_type
extern array_find_code
extern array_new_empty
extern array_reserve
extern array_item_value
extern array_no_exports
extern array_extend_iterable
extern array_append_value
extern array_sq_item
extern array_ass_subscript_int
extern array_tp_iter

extern ap_malloc
extern ap_free
extern ap_memcpy
extern ap_memmove
extern obj_decref
extern obj_incref
extern obj_as_index
extern obj_as_slice_index
extern int_from_i64
extern obj_richcompare_bool
extern binop_is_count
extern seq_repeat_count
extern slice_type
extern slice_indices_live
extern none_singleton
extern bool_true
extern bool_false
extern set_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_IndexError_type
extern exc_MemoryError_type

; Cap repeated array byte allocations at 1 GiB so pathological `a * (maxsize//N + 1)`
; raises MemoryError cleanly rather than exhausting host RAM.
ARRAY_MAX_BYTES equ 0x40000000

section .text

;; ============================================================================
;; ao_slice_length(rdi = start, rsi = stop, rcx = step) -> rax = element count
;; ============================================================================
DEF_FUNC_BARE ao_slice_length
    test rcx, rcx
    js .asl_neg
    mov rax, rsi
    sub rax, rdi
    jle .asl_zero
    ; Handle huge positive steps (e.g. 1<<62) without signed overflow on add:
    ; count = (stop - start - 1) / step + 1
    dec rax
    xor edx, edx
    div rcx
    inc rax
    ret
.asl_neg:
    mov rax, rdi
    sub rax, rsi
    jle .asl_zero
    mov r8, rcx
    neg r8
    dec rax
    xor edx, edx
    div r8
    inc rax
    ret
.asl_zero:
    xor eax, eax
    ret
END_FUNC ao_slice_length

;; ============================================================================
;; ao_copy_scalar(rdi = dst, rsi = src, rcx = isize) -> clobbers rax only
;; Copies 1, 2, 4 or 8 B; preserves rdi, rsi, rcx, rdx, r8-r11.
;; ============================================================================
DEF_FUNC_BARE ao_copy_scalar
    cmp rcx, 4
    je .acs_4
    cmp rcx, 8
    je .acs_8
    cmp rcx, 2
    je .acs_2
    mov al, [rsi]
    mov [rdi], al
    ret
.acs_2:
    mov ax, [rsi]
    mov [rdi], ax
    ret
.acs_4:
    mov eax, [rsi]
    mov [rdi], eax
    ret
.acs_8:
    mov rax, [rsi]
    mov [rdi], rax
    ret
END_FUNC ao_copy_scalar

;; ============================================================================
;; array_concat(rdi = self Value, rsi = other Value) -> rax = new array or 0
;; Fails: 0?
;; ============================================================================
AC_SELF  equ 8
AC_OTHER equ 16
AC_RES   equ 24
AC_N1    equ 32
AC_N2    equ 40
AC_FRAME equ 56                 ; + 1 push (rbx) = 64, 16-aligned
global array_concat
DEF_FUNC array_concat, AC_FRAME
    push rbx
    mov [rbp - AC_SELF], rdi
    mov [rbp - AC_OTHER], rsi

    V_TEST_PTR rsi, rax
    ja .ac_not_array
    mov rax, [rsi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_ARRAY_SUBCLASS
    jz .ac_not_array

    mov rcx, [rdi + PyArrayObject.ob_code]
    cmp rcx, [rsi + PyArrayObject.ob_code]
    jne .ac_bad_kind

    mov rdi, rcx
    call array_find_code
    test rax, rax
    jz .ac_bad_kind
    mov rdi, rax
    call array_new_empty
    test rax, rax
    jz .ac_fail
    mov [rbp - AC_RES], rax

    mov rdi, [rbp - AC_SELF]
    mov rsi, [rbp - AC_OTHER]
    OBJ_LOCK2 rdi, rsi

    mov rax, [rdi + PyArrayObject.ob_size]
    mov [rbp - AC_N1], rax
    mov rdx, [rsi + PyArrayObject.ob_size]
    mov [rbp - AC_N2], rdx
    add rax, rdx
    jo .ac_unlock_nomem
    mov rbx, rax                ; total items
    test rbx, rbx
    jz .ac_unlock_done

    mov rcx, [rdi + PyArrayObject.ob_isize]
    mov rax, rbx
    imul rax, rcx
    jo .ac_unlock_nomem
    cmp rax, ARRAY_MAX_BYTES
    ja .ac_unlock_nomem

    mov rdi, [rbp - AC_RES]
    mov rsi, rbx
    call array_reserve
    ERR_NULL .ac_unlock_drop

    ; Copy self's bytes
    mov r8, [rbp - AC_RES]
    mov r9, [rbp - AC_SELF]
    mov rdx, [rbp - AC_N1]
    imul rdx, [r8 + PyArrayObject.ob_isize]
    test rdx, rdx
    jz .ac_copy_second
    mov rdi, [r8 + PyArrayObject.ob_data]
    mov rsi, [r9 + PyArrayObject.ob_data]
    call ap_memcpy

.ac_copy_second:
    mov r8, [rbp - AC_RES]
    mov r9, [rbp - AC_OTHER]
    mov rdx, [rbp - AC_N2]
    imul rdx, [r8 + PyArrayObject.ob_isize]
    test rdx, rdx
    jz .ac_set_size
    mov rax, [rbp - AC_N1]
    imul rax, [r8 + PyArrayObject.ob_isize]
    mov rdi, [r8 + PyArrayObject.ob_data]
    add rdi, rax
    mov rsi, [r9 + PyArrayObject.ob_data]
    call ap_memcpy

.ac_set_size:
    mov r8, [rbp - AC_RES]
    mov [r8 + PyArrayObject.ob_size], rbx

.ac_unlock_done:
    mov rdi, [rbp - AC_SELF]
    mov rsi, [rbp - AC_OTHER]
    OBJ_UNLOCK2 rdi, rsi
    mov rax, [rbp - AC_RES]
    pop rbx
    leave
    ret

.ac_unlock_nomem:
    mov rdi, [rbp - AC_SELF]
    mov rsi, [rbp - AC_OTHER]
    OBJ_UNLOCK2 rdi, rsi
    SET_EXC exc_MemoryError_type, "out of memory"
    jmp .ac_drop
.ac_unlock_drop:
    mov rdi, [rbp - AC_SELF]
    mov rsi, [rbp - AC_OTHER]
    OBJ_UNLOCK2 rdi, rsi
.ac_drop:
    mov rdi, [rbp - AC_RES]
    call obj_decref
.ac_fail:
    xor eax, eax
    pop rbx
    leave
    ret
.ac_not_array:
    FAIL exc_TypeError_type, "can only append array to array", .ac_fail
.ac_bad_kind:
    FAIL exc_TypeError_type, "bad argument type for built-in operation", .ac_fail
END_FUNC array_concat

;; ============================================================================
;; array_inplace_concat(rdi = self Value, rsi = other Value) -> rax = self or 0
;; Fails: 0?
;; ============================================================================
AIC_SELF  equ 8
AIC_OTHER equ 16
AIC_FRAME equ 16                ; 0 pushes, 16-aligned
global array_inplace_concat
DEF_FUNC array_inplace_concat, AIC_FRAME
    mov [rbp - AIC_SELF], rdi
    mov [rbp - AIC_OTHER], rsi

    V_TEST_PTR rsi, rax
    ja .aic_not_array
    mov rax, [rsi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_ARRAY_SUBCLASS
    jz .aic_not_array

    mov rcx, [rdi + PyArrayObject.ob_code]
    cmp rcx, [rsi + PyArrayObject.ob_code]
    jne .aic_bad_kind

    call array_extend_iterable
    ERR_NULL .aic_fail
    mov rax, [rbp - AIC_SELF]
    INCREF rax
    leave
    ret
.aic_not_array:
    FAIL exc_TypeError_type, "can only extend array with array", .aic_fail
.aic_bad_kind:
    FAIL exc_TypeError_type, "bad argument type for built-in operation", .aic_fail
.aic_fail:
    xor eax, eax
    leave
    ret
END_FUNC array_inplace_concat

;; ============================================================================
;; array_repeat(rdi = self Value, rsi = count Value) -> rax = new array or 0
;; Fails: 0? (0 without exception pending means declined for non-int)
;; ============================================================================
ARP2_SELF  equ 8
ARP2_ARG   equ 16
ARP2_CNT   equ 24
ARP2_RES   equ 32
ARP2_BYTES equ 40
ARP2_FRAME equ 56               ; + 1 push (rbx) = 64, 16-aligned
global array_repeat
DEF_FUNC array_repeat, ARP2_FRAME
    push rbx
    mov [rbp - ARP2_SELF], rdi
    mov [rbp - ARP2_ARG], rsi

    mov rdi, rsi
    call binop_is_count
    test eax, eax
    jz .ar_decline

    mov rsi, [rbp - ARP2_ARG]
    call seq_repeat_count
    ERR_M1 .ar_fail
    test rax, rax
    jns .ar_cnt_ok
    xor eax, eax
.ar_cnt_ok:
    mov [rbp - ARP2_CNT], rax

    mov rdi, [rbp - ARP2_SELF]
    mov rdi, [rdi + PyArrayObject.ob_code]
    call array_find_code
    mov rdi, rax
    call array_new_empty
    test rax, rax
    jz .ar_fail
    mov [rbp - ARP2_RES], rax

    cmp qword [rbp - ARP2_CNT], 0
    je .ar_done

    mov rdi, [rbp - ARP2_SELF]
    OBJ_LOCK rdi
    mov rbx, [rdi + PyArrayObject.ob_size]
    test rbx, rbx
    jz .ar_unlock_done

    mov rax, [rbp - ARP2_CNT]
    imul rax, rbx               ; total items
    jo .ar_unlock_nomem
    mov rcx, [rdi + PyArrayObject.ob_isize]
    mov rdx, rax
    imul rdx, rcx               ; total bytes
    jo .ar_unlock_nomem
    cmp rdx, ARRAY_MAX_BYTES
    ja .ar_unlock_nomem

    mov rdx, rbx
    imul rdx, rcx
    mov [rbp - ARP2_BYTES], rdx ; bytes per copy
    mov rbx, rax                ; total items

    mov rdi, [rbp - ARP2_RES]
    mov rsi, rbx
    call array_reserve
    ERR_NULL .ar_unlock_drop

    ; Copy chunk once, then repeat
    mov r8, [rbp - ARP2_RES]
    mov r9, [rbp - ARP2_SELF]
    mov rdi, [r8 + PyArrayObject.ob_data]
    mov rsi, [r9 + PyArrayObject.ob_data]
    mov rdx, [rbp - ARP2_BYTES]
    call ap_memcpy

    ; Doubling copy inside res->ob_data
    mov rax, [rbp - ARP2_BYTES] ; filled bytes
    mov rcx, [rbp - ARP2_CNT]
    imul rcx, rax               ; total bytes
.ar_dup_loop:
    cmp rax, rcx
    jge .ar_set_size
    mov rdx, rcx
    sub rdx, rax                ; remaining bytes
    cmp rdx, rax
    jbe .ar_dup_copy
    mov rdx, rax                ; copy at most filled bytes
.ar_dup_copy:
    mov r8, [rbp - ARP2_RES]
    mov rsi, [r8 + PyArrayObject.ob_data]
    lea rdi, [rsi + rax]
    push rax
    push rcx
    push rdx
    sub rsp, 8
    call ap_memcpy
    add rsp, 8
    pop rdx
    pop rcx
    pop rax
    add rax, rdx
    jmp .ar_dup_loop

.ar_set_size:
    mov r8, [rbp - ARP2_RES]
    mov [r8 + PyArrayObject.ob_size], rbx
.ar_unlock_done:
    mov rdi, [rbp - ARP2_SELF]
    OBJ_UNLOCK rdi
.ar_done:
    mov rax, [rbp - ARP2_RES]
    pop rbx
    leave
    ret
.ar_unlock_nomem:
    mov rdi, [rbp - ARP2_SELF]
    OBJ_UNLOCK rdi
    SET_EXC exc_MemoryError_type, "out of memory"
    jmp .ar_drop
.ar_unlock_drop:
    mov rdi, [rbp - ARP2_SELF]
    OBJ_UNLOCK rdi
.ar_drop:
    mov rdi, [rbp - ARP2_RES]
    call obj_decref
.ar_decline:
.ar_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC array_repeat

;; ============================================================================
;; array_inplace_repeat(rdi = self Value, rsi = count Value) -> rax = self or 0
;; Fails: 0?
;; ============================================================================
AIR_SELF  equ 8
AIR_ARG   equ 16
AIR_CNT   equ 24
AIR_BYTES equ 32
AIR_FRAME equ 40                ; + 1 push (rbx) = 48, 16-aligned
global array_inplace_repeat
DEF_FUNC array_inplace_repeat, AIR_FRAME
    push rbx
    mov [rbp - AIR_SELF], rdi
    mov [rbp - AIR_ARG], rsi

    mov rdi, rsi
    call binop_is_count
    test eax, eax
    jz .air_decline

    mov rsi, [rbp - AIR_ARG]
    call seq_repeat_count
    ERR_M1 .air_fail
    mov [rbp - AIR_CNT], rax

    mov rdi, [rbp - AIR_SELF]
    OBJ_LOCK rdi
    mov rbx, [rdi + PyArrayObject.ob_size]
    test rbx, rbx
    jz .air_unlock_ok

    mov rax, [rbp - AIR_CNT]
    cmp rax, 1
    je .air_unlock_ok

    call array_no_exports
    ERR_NULL .air_unlock_fail

    mov rdi, [rbp - AIR_SELF]
    mov rax, [rbp - AIR_CNT]
    test rax, rax
    jg .air_pos
    mov qword [rdi + PyArrayObject.ob_size], 0
    jmp .air_unlock_ok

.air_pos:
    mov rbx, [rdi + PyArrayObject.ob_size]

    imul rax, rbx               ; total items
    jo .air_unlock_nomem
    mov rcx, [rdi + PyArrayObject.ob_isize]
    mov rdx, rax
    imul rdx, rcx               ; total bytes
    jo .air_unlock_nomem
    cmp rdx, ARRAY_MAX_BYTES
    ja .air_unlock_nomem

    mov rdx, rbx
    imul rdx, rcx
    mov [rbp - AIR_BYTES], rdx
    mov rbx, rax                ; total items

    mov rsi, rbx
    call array_reserve
    ERR_NULL .air_unlock_fail

    ; Doubling copy in place
    mov rax, [rbp - AIR_BYTES]
    mov rcx, [rbp - AIR_CNT]
    imul rcx, rax
.air_dup_loop:
    cmp rax, rcx
    jge .air_set_size
    mov rdx, rcx
    sub rdx, rax
    cmp rdx, rax
    jbe .air_dup_copy
    mov rdx, rax
.air_dup_copy:
    mov r8, [rbp - AIR_SELF]
    mov rsi, [r8 + PyArrayObject.ob_data]
    lea rdi, [rsi + rax]
    push rax
    push rcx
    push rdx
    sub rsp, 8
    call ap_memcpy
    add rsp, 8
    pop rdx
    pop rcx
    pop rax
    add rax, rdx
    jmp .air_dup_loop

.air_set_size:
    mov rdi, [rbp - AIR_SELF]
    mov [rdi + PyArrayObject.ob_size], rbx
.air_unlock_ok:
    mov rdi, [rbp - AIR_SELF]
    OBJ_UNLOCK rdi
    mov rax, [rbp - AIR_SELF]
    INCREF rax
    pop rbx
    leave
    ret
.air_unlock_nomem:
    mov rdi, [rbp - AIR_SELF]
    OBJ_UNLOCK rdi
    SET_EXC exc_MemoryError_type, "out of memory"
    jmp .air_fail
.air_unlock_fail:
    mov rdi, [rbp - AIR_SELF]
    OBJ_UNLOCK rdi
.air_decline:
.air_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC array_inplace_repeat

;; ============================================================================
;; array_contains(rdi = self, rsi = item Value) -> eax = 1, 0, or -1
;; Fails: -1
;; ============================================================================
ACT_SELF  equ 8
ACT_ITEM  equ 16
ACT_IDX   equ 24
ACT_ELEM  equ 32
ACT_FRAME equ 48                ; 0 pushes, 48 -> align: +0 = 48, 16-aligned
global array_contains
DEF_FUNC array_contains, ACT_FRAME
    mov [rbp - ACT_SELF], rdi
    mov [rbp - ACT_ITEM], rsi
    mov qword [rbp - ACT_IDX], 0
.act_loop:
    mov rdi, [rbp - ACT_SELF]
    OBJ_LOCK rdi
    mov rsi, [rbp - ACT_IDX]
    cmp rsi, [rdi + PyArrayObject.ob_size]
    jge .act_unlock_false
    call array_item_value
    mov rdi, [rbp - ACT_SELF]
    OBJ_UNLOCK rdi
    test rax, rax
    jz .act_error
    mov [rbp - ACT_ELEM], rax
    mov rdi, rax
    mov rsi, [rbp - ACT_ITEM]
    mov edx, PY_EQ
    call obj_richcompare_bool
    push rax
    sub rsp, 8
    mov rdi, [rbp - ACT_ELEM]
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    test eax, eax
    js .act_error
    jnz .act_true
    inc qword [rbp - ACT_IDX]
    jmp .act_loop
.act_unlock_false:
    OBJ_UNLOCK rdi
    xor eax, eax
    leave
    ret
.act_true:
    mov eax, 1
    leave
    ret
.act_error:
    mov eax, -1
    leave
    ret
END_FUNC array_contains

;; ============================================================================
;; array_subscript_full(rdi = self, rsi = key Value) -> rax = Value or 0
;; Handles integer index and PySliceObject (contiguous and extended).
;; ============================================================================
ASF_SELF  equ 8
ASF_KEY   equ 16
ASF_START equ 24
ASF_STOP  equ 32
ASF_STEP  equ 40
ASF_LEN   equ 48
ASF_OUT   equ 56
ASF_FRAME equ 72                ; + 1 push (rbx) = 80, 16-aligned
global array_subscript_full
DEF_FUNC array_subscript_full, ASF_FRAME
    push rbx
    mov [rbp - ASF_SELF], rdi
    mov [rbp - ASF_KEY], rsi

    V_TEST_PTR rsi, rax
    ja .asf_int
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel slice_type]
    cmp rax, rcx
    je .asf_slice

.asf_int:
    mov rdi, rsi
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .asf_fail
    mov rdi, [rbp - ASF_SELF]
    mov rsi, rax
    pop rbx
    leave
    jmp array_sq_item

.asf_slice:
    mov rdi, rsi
    mov rcx, [rbp - ASF_SELF]
    lea rsi, [rcx + PyArrayObject.ob_size]
    call slice_indices_live     ; rax = start, rdx = stop, rcx = step
    ERR_M1 .asf_fail
    mov [rbp - ASF_START], rax
    mov [rbp - ASF_STOP], rdx
    mov [rbp - ASF_STEP], rcx

    mov rdi, [rbp - ASF_SELF]
    mov rdi, [rdi + PyArrayObject.ob_code]
    call array_find_code
    mov rdi, rax
    call array_new_empty
    test rax, rax
    jz .asf_fail
    mov [rbp - ASF_OUT], rax

    mov r8, [rbp - ASF_SELF]
    OBJ_LOCK r8
    ; Re-clamp start/stop against live ob_size under OBJ_LOCK
    mov r9, [r8 + PyArrayObject.ob_size]
    mov rax, [rbp - ASF_START]
    mov rdx, [rbp - ASF_STOP]
    mov rcx, [rbp - ASF_STEP]
    test rcx, rcx
    js .asf_clamp_neg
    cmp rax, r9
    cmovg rax, r9
    cmp rdx, r9
    cmovg rdx, r9
    jmp .asf_clamped
.asf_clamp_neg:
    cmp rax, r9
    jl .asf_clamped
    lea rax, [r9 - 1]
.asf_clamped:
    mov [rbp - ASF_START], rax
    mov rdi, rax
    mov rsi, rdx
    call ao_slice_length
    mov [rbp - ASF_LEN], rax
    test rax, rax
    jz .asf_unlock_done

    mov rdi, [rbp - ASF_OUT]
    mov rsi, rax
    call array_reserve
    ERR_NULL .asf_unlock_drop

    mov r8, [rbp - ASF_SELF]
    mov r9, [rbp - ASF_OUT]
    mov rcx, [r8 + PyArrayObject.ob_isize]
    cmp qword [rbp - ASF_STEP], 1
    jne .asf_ext_copy

    ; Contiguous slice (step == 1): single memcpy
    mov rax, [rbp - ASF_START]
    imul rax, rcx
    mov rsi, [r8 + PyArrayObject.ob_data]
    add rsi, rax
    mov rdi, [r9 + PyArrayObject.ob_data]
    mov rdx, [rbp - ASF_LEN]
    imul rdx, rcx
    call ap_memcpy
    jmp .asf_set_len

.asf_ext_copy:
    mov rdi, [r9 + PyArrayObject.ob_data]
    mov r10, [r8 + PyArrayObject.ob_data]
    mov rbx, [rbp - ASF_START]
    mov r11, [rbp - ASF_LEN]
    mov r8, [rbp - ASF_STEP]
.asf_ext_loop:
    test r11, r11
    jz .asf_set_len
    mov rax, rbx
    imul rax, rcx
    lea rsi, [r10 + rax]
    call ao_copy_scalar
    add rdi, rcx
    add rbx, r8
    dec r11
    jmp .asf_ext_loop

.asf_set_len:
    mov r9, [rbp - ASF_OUT]
    mov rax, [rbp - ASF_LEN]
    mov [r9 + PyArrayObject.ob_size], rax

.asf_unlock_done:
    mov r8, [rbp - ASF_SELF]
    OBJ_UNLOCK r8
    mov rax, [rbp - ASF_OUT]
    pop rbx
    leave
    ret

.asf_unlock_drop:
    mov r8, [rbp - ASF_SELF]
    OBJ_UNLOCK r8
    mov rdi, [rbp - ASF_OUT]
    call obj_decref
.asf_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC array_subscript_full

;; ============================================================================
;; array_ass_subscript_full(rdi = self, rsi = key Value, rdx = val Value)
;;   -> eax = 0 on success, -1 raising.  val == 0 is slice/item deletion.
;; ============================================================================
AASF_SELF  equ 8
AASF_KEY   equ 16
AASF_VAL   equ 24
AASF_START equ 32
AASF_STOP  equ 40
AASF_STEP  equ 48
AASF_SLEN  equ 56
AASF_VBUF  equ 64
AASF_VN    equ 72
AASF_ISIZE equ 80
AASF_FRAME equ 88               ; + 3 pushes (rbx,r12,r13) = 112, 16-aligned
global array_ass_subscript_full
DEF_FUNC array_ass_subscript_full, AASF_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - AASF_SELF], rdi
    mov [rbp - AASF_KEY], rsi
    mov [rbp - AASF_VAL], rdx
    mov qword [rbp - AASF_VBUF], 0
    mov qword [rbp - AASF_VN], 0
    mov rax, [rdi + PyArrayObject.ob_isize]
    mov [rbp - AASF_ISIZE], rax

    V_TEST_PTR rsi, rax
    ja .aasf_int
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel slice_type]
    cmp rax, rcx
    je .aasf_slice

.aasf_int:
    pop r13
    pop r12
    pop rbx
    leave
    jmp array_ass_subscript_int

.aasf_slice:
    ; Validate and snapshot replacement array if val != NULL
    mov rbx, [rbp - AASF_VAL]
    test rbx, rbx
    jz .aasf_indices

    V_TEST_PTR rbx, rax
    ja .aasf_not_array
    mov rax, [rbx + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_ARRAY_SUBCLASS
    jz .aasf_not_array

    mov rdi, [rbp - AASF_SELF]
    mov rcx, [rdi + PyArrayObject.ob_code]
    cmp rcx, [rbx + PyArrayObject.ob_code]
    jne .aasf_bad_kind

    OBJ_LOCK rbx
    mov rax, [rbx + PyArrayObject.ob_size]
    mov [rbp - AASF_VN], rax
    test rax, rax
    jz .aasf_val_unlock
    imul rax, [rbp - AASF_ISIZE]
    mov r12, rax                ; byte count
    mov rdi, rax
    call ap_malloc
    test rax, rax
    jz .aasf_val_unlock_nomem
    mov [rbp - AASF_VBUF], rax
    mov rdi, rax
    mov rsi, [rbx + PyArrayObject.ob_data]
    mov rdx, r12
    call ap_memcpy
.aasf_val_unlock:
    OBJ_UNLOCK rbx

.aasf_indices:
    mov rdi, [rbp - AASF_KEY]
    mov rcx, [rbp - AASF_SELF]
    lea rsi, [rcx + PyArrayObject.ob_size]
    call slice_indices_live     ; rax = start, rdx = stop, rcx = step
    ERR_M1 .aasf_fail
    mov [rbp - AASF_START], rax
    mov [rbp - AASF_STOP], rdx
    mov [rbp - AASF_STEP], rcx

    mov rbx, [rbp - AASF_SELF]
    OBJ_LOCK rbx
    mov r9, [rbx + PyArrayObject.ob_size]
    mov rax, [rbp - AASF_START]
    mov rdx, [rbp - AASF_STOP]
    mov rcx, [rbp - AASF_STEP]
    test rcx, rcx
    js .aasf_clamp_neg
    cmp rax, r9
    cmovg rax, r9
    cmp rdx, r9
    cmovg rdx, r9
    jmp .aasf_clamped
.aasf_clamp_neg:
    cmp rax, r9
    jl .aasf_clamped
    lea rax, [r9 - 1]
.aasf_clamped:
    mov [rbp - AASF_START], rax
    mov [rbp - AASF_STOP], rdx
    mov rdi, rax
    mov rsi, rdx
    call ao_slice_length
    mov [rbp - AASF_SLEN], rax

    cmp qword [rbp - AASF_VAL], 0
    je .aasf_delete

    ; --- Slice assignment ---
    cmp qword [rbp - AASF_STEP], 1
    jne .aasf_assign_ext

    ; Contiguous slice assignment (step == 1): may grow or shrink
    mov r12, [rbp - AASF_SLEN]
    mov r13, [rbp - AASF_VN]
    mov rax, [rbx + PyArrayObject.ob_size]
    sub rax, r12
    add rax, r13                ; new_size
    mov r12, rax                ; r12 = new_size
    cmp r12, [rbx + PyArrayObject.ob_size]
    je .aasf_c_have_cap
    mov rdi, rbx
    call array_no_exports
    ERR_NULL .aasf_unlock_fail
    ; Reserve if growing
    cmp r12, [rbx + PyArrayObject.ob_size]
    jbe .aasf_c_have_cap
    mov rdi, rbx
    mov rsi, r12
    call array_reserve
    ERR_NULL .aasf_unlock_fail
.aasf_c_have_cap:
    ; Shift tail if needed
    mov rax, [rbp - AASF_START]
    add rax, [rbp - AASF_SLEN]  ; old tail start index
    mov rdx, [rbx + PyArrayObject.ob_size]
    sub rdx, rax                ; tail item count
    jle .aasf_c_copy_val
    mov rcx, [rbp - AASF_VN]
    cmp rcx, [rbp - AASF_SLEN]
    je .aasf_c_copy_val
    mov r8, [rbp - AASF_ISIZE]
    imul rdx, r8                ; tail bytes
    mov rsi, rax
    imul rsi, r8
    add rsi, [rbx + PyArrayObject.ob_data]
    mov rdi, [rbp - AASF_START]
    add rdi, rcx
    imul rdi, r8
    add rdi, [rbx + PyArrayObject.ob_data]
    call ap_memmove
.aasf_c_copy_val:
    mov rdx, [rbp - AASF_VN]
    test rdx, rdx
    jz .aasf_c_set_size
    mov r8, [rbp - AASF_ISIZE]
    imul rdx, r8
    mov rdi, [rbp - AASF_START]
    imul rdi, r8
    add rdi, [rbx + PyArrayObject.ob_data]
    mov rsi, [rbp - AASF_VBUF]
    call ap_memcpy
.aasf_c_set_size:
    mov [rbx + PyArrayObject.ob_size], r12
    jmp .aasf_unlock_ok

.aasf_assign_ext:
    ; Extended slice assignment (step != 1): lengths must match exactly
    mov rax, [rbp - AASF_VN]
    cmp rax, [rbp - AASF_SLEN]
    jne .aasf_unlock_ext_mismatch
    test rax, rax
    jz .aasf_unlock_ok
    mov rcx, [rbp - AASF_ISIZE]
    mov rsi, [rbp - AASF_VBUF]
    mov r10, [rbx + PyArrayObject.ob_data]
    mov r12, [rbp - AASF_START]
    mov r13, [rbp - AASF_STEP]
    mov r8, rax
.aasf_ext_set_loop:
    mov rax, r12
    imul rax, rcx
    lea rdi, [r10 + rax]
    call ao_copy_scalar
    add rsi, rcx
    add r12, r13
    dec r8
    jnz .aasf_ext_set_loop
    jmp .aasf_unlock_ok

    ; --- Slice deletion ---
.aasf_delete:
    mov r12, [rbp - AASF_SLEN]
    test r12, r12
    jz .aasf_unlock_ok
    mov rdi, rbx
    call array_no_exports
    ERR_NULL .aasf_unlock_fail

    cmp qword [rbp - AASF_STEP], 1
    jne .aasf_del_ext

    ; Contiguous delete (step == 1)
    mov r8, [rbp - AASF_ISIZE]
    mov rax, [rbp - AASF_START]
    add rax, r12
    mov rdx, [rbx + PyArrayObject.ob_size]
    sub rdx, rax                ; tail items
    jle .aasf_del_shrink
    imul rdx, r8
    mov rsi, rax
    imul rsi, r8
    add rsi, [rbx + PyArrayObject.ob_data]
    mov rdi, [rbp - AASF_START]
    imul rdi, r8
    add rdi, [rbx + PyArrayObject.ob_data]
    call ap_memmove
.aasf_del_shrink:
    sub [rbx + PyArrayObject.ob_size], r12
    jmp .aasf_unlock_ok

.aasf_del_ext:
    ; Normalize negative step to positive ascending indices:
    ; if step < 0: start = start + (slicelen - 1) * step; step = -step
    mov r13, [rbp - AASF_STEP]
    mov rax, [rbp - AASF_START]
    test r13, r13
    jns .aasf_del_pos
    lea rdx, [r12 - 1]
    imul rdx, r13
    add rax, rdx
    neg r13
.aasf_del_pos:
    ; Linear compaction: r8 = read idx, r9 = write idx, rax = next_del,
    ; r12 = remaining deletions, r13 = positive step, r10 = ob_data, rcx = isize
    mov r10, [rbx + PyArrayObject.ob_data]
    mov rcx, [rbp - AASF_ISIZE]
    mov r11, [rbx + PyArrayObject.ob_size]
    mov r8, rax                 ; start scanning at first deleted index
    mov r9, rax                 ; write cursor starts there too
    mov rdx, rax                ; rdx = next_del
.aasf_del_loop:
    cmp r8, r11
    jge .aasf_del_ext_done
    cmp r8, rdx
    jne .aasf_del_keep
    dec r12
    jz .aasf_del_no_more
    add rdx, r13
    jmp .aasf_del_next
.aasf_del_no_more:
    mov rdx, -1                 ; sentinel: never matches r8 >= 0
    jmp .aasf_del_next
.aasf_del_keep:
    ; copy item r8 -> item r9
    mov rax, r8
    imul rax, rcx
    lea rsi, [r10 + rax]
    mov rax, r9
    imul rax, rcx
    lea rdi, [r10 + rax]
    call ao_copy_scalar
    inc r9
.aasf_del_next:
    inc r8
    jmp .aasf_del_loop

.aasf_del_ext_done:
    mov [rbx + PyArrayObject.ob_size], r9

.aasf_unlock_ok:
    OBJ_UNLOCK rbx
    mov rdi, [rbp - AASF_VBUF]
    test rdi, rdi
    jz .aasf_ok_ret
    call ap_free
.aasf_ok_ret:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret

.aasf_unlock_ext_mismatch:
    OBJ_UNLOCK rbx
    SET_EXC exc_ValueError_type, \
            "attempt to assign array to extended slice of different size"
    jmp .aasf_fail
.aasf_val_unlock_nomem:
    OBJ_UNLOCK rbx
    SET_EXC exc_MemoryError_type, "out of memory"
    jmp .aasf_fail
.aasf_unlock_fail:
    OBJ_UNLOCK rbx
.aasf_fail:
    mov rdi, [rbp - AASF_VBUF]
    test rdi, rdi
    jz .aasf_ret_m1
    call ap_free
.aasf_ret_m1:
    mov eax, -1
    pop r13
    pop r12
    pop rbx
    leave
    ret
.aasf_not_array:
    FAIL exc_TypeError_type, "can only assign array to array slice", .aasf_fail
.aasf_bad_kind:
    FAIL exc_TypeError_type, "bad argument type for built-in operation", .aasf_fail
END_FUNC array_ass_subscript_full

;; ============================================================================
;; Dunder method wrappers registered in array_type.tp_dict
;; ============================================================================

;; array_m_add(rdi = args, rsi = nargs) -> rax = new array or 0
global array_m_add
DEF_FUNC array_m_add
    cmp rsi, 2
    jne .amadd_arity
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call array_concat           ; err: 0 is this method's own
    leave
    ret
.amadd_arity:
    SET_EXC exc_TypeError_type, "__add__() takes exactly one argument"
    xor eax, eax
    leave
    ret
END_FUNC array_m_add

;; array_m_iadd(rdi = args, rsi = nargs) -> rax = self or 0
global array_m_iadd
DEF_FUNC array_m_iadd
    cmp rsi, 2
    jne .amiadd_arity
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call array_inplace_concat   ; err: 0 is this method's own
    leave
    ret
.amiadd_arity:
    SET_EXC exc_TypeError_type, "__iadd__() takes exactly one argument"
    xor eax, eax
    leave
    ret
END_FUNC array_m_iadd

;; array_m_mul(rdi = args, rsi = nargs) -> rax = new array or 0 (also __rmul__)
global array_m_mul
DEF_FUNC array_m_mul
    cmp rsi, 2
    jne .ammul_arity
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call array_repeat           ; err: checked just below
    test rax, rax
    jnz .ammul_done
    cmp qword [gs:ThreadState.current_exception], 0
    jne .ammul_done
    SET_EXC exc_TypeError_type, "can't multiply sequence by non-int"
    xor eax, eax
.ammul_done:
    leave
    ret
.ammul_arity:
    SET_EXC exc_TypeError_type, "__mul__() takes exactly one argument"
    xor eax, eax
    leave
    ret
END_FUNC array_m_mul

;; array_m_imul(rdi = args, rsi = nargs) -> rax = self or 0
global array_m_imul
DEF_FUNC array_m_imul
    cmp rsi, 2
    jne .amimul_arity
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call array_inplace_repeat   ; err: checked just below
    test rax, rax
    jnz .amimul_done
    cmp qword [gs:ThreadState.current_exception], 0
    jne .amimul_done
    SET_EXC exc_TypeError_type, "can't multiply sequence by non-int"
    xor eax, eax
.amimul_done:
    leave
    ret
.amimul_arity:
    SET_EXC exc_TypeError_type, "__imul__() takes exactly one argument"
    xor eax, eax
    leave
    ret
END_FUNC array_m_imul

;; array_m_contains(rdi = args, rsi = nargs) -> rax = bool Value or 0
global array_m_contains
DEF_FUNC array_m_contains
    cmp rsi, 2
    jne .amc_arity
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call array_contains
    ERR_M1 .amc_fail
    test eax, eax
    jz .amc_false
    lea rax, [rel bool_true]
    INCREF rax
    leave
    ret
.amc_false:
    lea rax, [rel bool_false]
    INCREF rax
    leave
    ret
.amc_arity:
    SET_EXC exc_TypeError_type, "__contains__() takes exactly one argument"
.amc_fail:
    xor eax, eax
    leave
    ret
END_FUNC array_m_contains

;; array_m_delitem(rdi = args, rsi = nargs) -> rax = None or 0
global array_m_delitem
DEF_FUNC array_m_delitem
    cmp rsi, 2
    jne .amd_arity
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    xor edx, edx
    call array_ass_subscript_full
    test eax, eax
    js .amd_fail
    LOAD_NONE rax
    INCREF rax
    leave
    ret
.amd_arity:
    SET_EXC exc_TypeError_type, "__delitem__() takes exactly one argument"
.amd_fail:
    xor eax, eax
    leave
    ret
END_FUNC array_m_delitem

;; array_m_iter(rdi = args, rsi = nargs) -> rax = iterator or 0
global array_m_iter
DEF_FUNC array_m_iter
    cmp rsi, 1
    jne .amit_arity
    mov rdi, [rdi]
    call array_tp_iter
    leave
    ret
.amit_arity:
    SET_EXC exc_TypeError_type, "__iter__() takes no arguments"
    xor eax, eax
    leave
    ret
END_FUNC array_m_iter

;; ============================================================================
;; array_m_insert(rdi = args, rsi = nargs) -> rax = None or 0
;; a.insert(i, x): inserts x before index i (clamped like list.insert).
;; Appends via array_append_value first (enforcing export lock & type/range
;; validation before shifting), then rotates the appended item into slot i.
;; ============================================================================
AMIN_SELF equ 8
AMIN_IDX  equ 16
AMIN_TMP  equ 24
AMIN_FRAME equ 40               ; + 1 push (rbx) = 48, 16-aligned
global array_m_insert
DEF_FUNC array_m_insert, AMIN_FRAME
    push rbx
    cmp rsi, 3
    jne .amins_arity
    mov rbx, [rdi]
    mov [rbp - AMIN_SELF], rbx
    mov rdx, [rdi + 16]         ; x
    push rdx
    sub rsp, 8
    mov rdi, [rdi + 8]          ; i
    V_UNPACK rdi, rdx
    call obj_as_index
    add rsp, 8
    pop rdx
    ERR_M1 .amins_fail
    mov [rbp - AMIN_IDX], rax

    mov rdi, rbx
    mov rsi, rdx
    call array_append_value
    ERR_NULL .amins_fail

    OBJ_LOCK rbx
    mov r8, [rbx + PyArrayObject.ob_size]
    dec r8                      ; old_size = new_size - 1
    mov rax, [rbp - AMIN_IDX]
    test rax, rax
    jns .amins_pos
    add rax, r8
    test rax, rax
    jns .amins_pos
    xor eax, eax
.amins_pos:
    cmp rax, r8
    jge .amins_unlock_ok        ; already appended at end

    ; Save the newly appended scalar (at old_size), shift [idx..old_size-1]
    ; up by one slot, then write the saved scalar into slot idx.
    mov [rbp - AMIN_IDX], rax   ; save clamped idx BEFORE ao_copy_scalar clobbers rax
    mov rcx, [rbx + PyArrayObject.ob_isize]
    mov r9, [rbx + PyArrayObject.ob_data]
    mov rsi, r8
    imul rsi, rcx
    add rsi, r9
    lea rdi, [rbp - AMIN_TMP]
    call ao_copy_scalar

    mov rax, [rbp - AMIN_IDX]   ; reload clamped idx
    mov rdx, r8
    sub rdx, rax                ; count of items to shift
    imul rdx, rcx               ; bytes to shift
    mov rsi, rax
    imul rsi, rcx
    add rsi, r9                 ; src = &data[idx]
    lea rdi, [rsi + rcx]        ; dst = &data[idx + 1]
    call ap_memmove

    mov rcx, [rbx + PyArrayObject.ob_isize]
    mov rax, [rbp - AMIN_IDX]
    imul rax, rcx
    mov rdi, [rbx + PyArrayObject.ob_data]
    add rdi, rax
    lea rsi, [rbp - AMIN_TMP]
    call ao_copy_scalar

.amins_unlock_ok:
    OBJ_UNLOCK rbx
    LOAD_NONE rax
    INCREF rax
    pop rbx
    leave
    ret
.amins_arity:
    SET_EXC exc_TypeError_type, "insert() takes exactly two arguments"
.amins_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC array_m_insert

;; ============================================================================
;; array_m_pop(rdi = args, rsi = nargs) -> rax = popped Value or 0
;; a.pop([i=-1]): removes and returns element at i.
;; ============================================================================
AMP_SELF  equ 8
AMP_IDX   equ 16
AMP_VAL   equ 24
AMP_FRAME equ 40                ; + 1 push (rbx) = 48, 16-aligned
global array_m_pop
DEF_FUNC array_m_pop, AMP_FRAME
    push rbx
    cmp rsi, 1
    jb .ampop_arity
    cmp rsi, 2
    ja .ampop_arity
    mov rbx, [rdi]
    mov [rbp - AMP_SELF], rbx
    mov qword [rbp - AMP_IDX], -1
    cmp rsi, 2
    jne .ampop_lock
    mov rdi, [rdi + 8]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .ampop_fail
    mov [rbp - AMP_IDX], rax

.ampop_lock:
    OBJ_LOCK rbx
    mov r8, [rbx + PyArrayObject.ob_size]
    test r8, r8
    jz .ampop_unlock_empty
    mov rax, [rbp - AMP_IDX]
    test rax, rax
    jns .ampop_pos
    add rax, r8
.ampop_pos:
    test rax, rax
    js .ampop_unlock_range
    cmp rax, r8
    jge .ampop_unlock_range
    mov [rbp - AMP_IDX], rax

    mov rdi, rbx
    call array_no_exports
    ERR_NULL .ampop_unlock_fail

    mov rdi, rbx
    mov rsi, [rbp - AMP_IDX]
    call array_item_value
    test rax, rax
    jz .ampop_unlock_fail
    mov [rbp - AMP_VAL], rax

    mov r8, [rbx + PyArrayObject.ob_size]
    mov rax, [rbp - AMP_IDX]
    mov rdx, r8
    sub rdx, rax
    dec rdx                     ; tail item count
    jle .ampop_shrink
    mov rcx, [rbx + PyArrayObject.ob_isize]
    imul rdx, rcx
    imul rax, rcx
    mov rdi, [rbx + PyArrayObject.ob_data]
    add rdi, rax                ; dst = &data[idx]
    lea rsi, [rdi + rcx]        ; src = &data[idx + 1]
    call ap_memmove
.ampop_shrink:
    dec qword [rbx + PyArrayObject.ob_size]
    OBJ_UNLOCK rbx
    mov rax, [rbp - AMP_VAL]
    pop rbx
    leave
    ret
.ampop_unlock_empty:
    OBJ_UNLOCK rbx
    SET_EXC exc_IndexError_type, "pop from empty array"
    jmp .ampop_fail
.ampop_unlock_range:
    OBJ_UNLOCK rbx
    SET_EXC exc_IndexError_type, "pop index out of range"
    jmp .ampop_fail
.ampop_unlock_fail:
    OBJ_UNLOCK rbx
    jmp .ampop_fail
.ampop_arity:
    SET_EXC exc_TypeError_type, "pop() takes at most 1 argument"
.ampop_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC array_m_pop

;; ============================================================================
;; array_m_remove(rdi = args, rsi = nargs) -> rax = None or 0
;; a.remove(x): removes the first occurrence of x, or raises ValueError.
;; ============================================================================
AMR_SELF  equ 8
AMR_ITEM  equ 16
AMR_IDX   equ 24
AMR_ELEM  equ 32
AMR_FRAME equ 40                ; + 1 push (rbx) = 48, 16-aligned
global array_m_remove
DEF_FUNC array_m_remove, AMR_FRAME
    push rbx
    cmp rsi, 2
    jne .amrem_arity
    mov rbx, [rdi]
    mov [rbp - AMR_SELF], rbx
    mov rax, [rdi + 8]
    mov [rbp - AMR_ITEM], rax
    mov qword [rbp - AMR_IDX], 0

.amrem_loop:
    OBJ_LOCK rbx
    mov rsi, [rbp - AMR_IDX]
    cmp rsi, [rbx + PyArrayObject.ob_size]
    jge .amrem_unlock_notfound
    mov rdi, rbx
    call array_item_value
    OBJ_UNLOCK rbx
    test rax, rax
    jz .amrem_fail
    mov [rbp - AMR_ELEM], rax
    mov rdi, rax
    mov rsi, [rbp - AMR_ITEM]
    mov edx, PY_EQ
    call obj_richcompare_bool
    push rax
    sub rsp, 8
    mov rdi, [rbp - AMR_ELEM]
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    test eax, eax
    js .amrem_fail
    jnz .amrem_found
    inc qword [rbp - AMR_IDX]
    jmp .amrem_loop

.amrem_found:
    OBJ_LOCK rbx
    mov rax, [rbp - AMR_IDX]
    cmp rax, [rbx + PyArrayObject.ob_size]
    jge .amrem_unlock_notfound
    mov rdi, rbx
    call array_no_exports
    ERR_NULL .amrem_unlock_fail
    mov r8, [rbx + PyArrayObject.ob_size]
    mov rax, [rbp - AMR_IDX]
    mov rdx, r8
    sub rdx, rax
    dec rdx
    jle .amrem_shrink
    mov rcx, [rbx + PyArrayObject.ob_isize]
    imul rdx, rcx
    imul rax, rcx
    mov rdi, [rbx + PyArrayObject.ob_data]
    add rdi, rax
    lea rsi, [rdi + rcx]
    call ap_memmove
.amrem_shrink:
    dec qword [rbx + PyArrayObject.ob_size]
    OBJ_UNLOCK rbx
    LOAD_NONE rax
    INCREF rax
    pop rbx
    leave
    ret
.amrem_unlock_notfound:
    OBJ_UNLOCK rbx
    SET_EXC exc_ValueError_type, "array.remove(x): x not in array"
    jmp .amrem_fail
.amrem_unlock_fail:
    OBJ_UNLOCK rbx
    jmp .amrem_fail
.amrem_arity:
    SET_EXC exc_TypeError_type, "remove() takes exactly one argument"
.amrem_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC array_m_remove

;; ============================================================================
;; array_m_index(rdi = args, rsi = nargs) -> rax = index int Value or 0
;; a.index(x[, start[, stop]]): first index of x in [start, stop).
;; ============================================================================
AMX_SELF  equ 8
AMX_ITEM  equ 16
AMX_IDX   equ 24
AMX_STOP  equ 32
AMX_ELEM  equ 40
AMX_ARGS  equ 48
AMX_NARGS equ 56
AMX_FRAME equ 72                ; + 1 push (rbx) = 80, 16-aligned
global array_m_index
DEF_FUNC array_m_index, AMX_FRAME
    push rbx
    cmp rsi, 2
    jb .amidx_arity
    cmp rsi, 4
    ja .amidx_arity
    mov [rbp - AMX_ARGS], rdi
    mov [rbp - AMX_NARGS], rsi
    mov rbx, [rdi]
    mov [rbp - AMX_SELF], rbx
    mov rax, [rdi + 8]
    mov [rbp - AMX_ITEM], rax
    mov qword [rbp - AMX_IDX], 0
    mov rax, [rbx + PyArrayObject.ob_size]
    mov [rbp - AMX_STOP], rax

    cmp qword [rbp - AMX_NARGS], 3
    jb .amidx_loop
    mov rax, [rbp - AMX_ARGS]
    mov rdi, [rax + 16]
    V_UNPACK rdi, rdx
    call obj_as_slice_index
    ERR_M1 .amidx_fail
    test rax, rax
    jns .amidx_start_ok
    add rax, [rbx + PyArrayObject.ob_size]
    test rax, rax
    jns .amidx_start_ok
    xor eax, eax
.amidx_start_ok:
    mov [rbp - AMX_IDX], rax

    cmp qword [rbp - AMX_NARGS], 4
    jb .amidx_loop
    mov rax, [rbp - AMX_ARGS]
    mov rdi, [rax + 24]
    V_UNPACK rdi, rdx
    call obj_as_slice_index
    ERR_M1 .amidx_fail
    test rax, rax
    jns .amidx_stop_ok
    add rax, [rbx + PyArrayObject.ob_size]
    test rax, rax
    jns .amidx_stop_ok
    xor eax, eax
.amidx_stop_ok:
    mov [rbp - AMX_STOP], rax

.amidx_loop:
    mov rsi, [rbp - AMX_IDX]
    cmp rsi, [rbp - AMX_STOP]
    jge .amidx_notfound
    OBJ_LOCK rbx
    cmp rsi, [rbx + PyArrayObject.ob_size]
    jge .amidx_unlock_notfound
    mov rdi, rbx
    call array_item_value
    OBJ_UNLOCK rbx
    test rax, rax
    jz .amidx_fail
    mov [rbp - AMX_ELEM], rax
    mov rdi, rax
    mov rsi, [rbp - AMX_ITEM]
    mov edx, PY_EQ
    call obj_richcompare_bool
    push rax
    sub rsp, 8
    mov rdi, [rbp - AMX_ELEM]
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    test eax, eax
    js .amidx_fail
    jnz .amidx_found
    inc qword [rbp - AMX_IDX]
    jmp .amidx_loop

.amidx_found:
    mov rdi, [rbp - AMX_IDX]
    call int_from_i64
    V_PACK rax, rdx
    pop rbx
    leave
    ret
.amidx_unlock_notfound:
    OBJ_UNLOCK rbx
.amidx_notfound:
    SET_EXC exc_ValueError_type, "array.index(x): x not in array"
    jmp .amidx_fail
.amidx_arity:
    SET_EXC exc_TypeError_type, "index() takes 1 to 3 arguments"
.amidx_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC array_m_index

;; ============================================================================
;; array_m_count(rdi = args, rsi = nargs) -> rax = count int Value or 0
;; a.count(x): number of occurrences of x in the array.
;; ============================================================================
AMCN_SELF  equ 8
AMCN_ITEM  equ 16
AMCN_IDX   equ 24
AMCN_CNT   equ 32
AMCN_ELEM  equ 40
AMCN_FRAME equ 56               ; + 1 push (rbx) = 64, 16-aligned
global array_m_count
DEF_FUNC array_m_count, AMCN_FRAME
    push rbx
    cmp rsi, 2
    jne .amcnt_arity
    mov rbx, [rdi]
    mov [rbp - AMCN_SELF], rbx
    mov rax, [rdi + 8]
    mov [rbp - AMCN_ITEM], rax
    mov qword [rbp - AMCN_IDX], 0
    mov qword [rbp - AMCN_CNT], 0

.amcnt_loop:
    OBJ_LOCK rbx
    mov rsi, [rbp - AMCN_IDX]
    cmp rsi, [rbx + PyArrayObject.ob_size]
    jge .amcnt_unlock_done
    mov rdi, rbx
    call array_item_value
    OBJ_UNLOCK rbx
    test rax, rax
    jz .amcnt_fail
    mov [rbp - AMCN_ELEM], rax
    mov rdi, rax
    mov rsi, [rbp - AMCN_ITEM]
    mov edx, PY_EQ
    call obj_richcompare_bool
    push rax
    sub rsp, 8
    mov rdi, [rbp - AMCN_ELEM]
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    test eax, eax
    js .amcnt_fail
    jz .amcnt_next
    inc qword [rbp - AMCN_CNT]
.amcnt_next:
    inc qword [rbp - AMCN_IDX]
    jmp .amcnt_loop

.amcnt_unlock_done:
    OBJ_UNLOCK rbx
    mov rdi, [rbp - AMCN_CNT]
    call int_from_i64
    V_PACK rax, rdx
    pop rbx
    leave
    ret
.amcnt_arity:
    SET_EXC exc_TypeError_type, "count() takes exactly one argument"
.amcnt_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC array_m_count

;; ============================================================================
;; array_m_reverse(rdi = args, rsi = nargs) -> rax = None or 0
;; a.reverse(): reverses the order of items in the array in place.
;; ============================================================================
global array_m_reverse
DEF_FUNC array_m_reverse, 8     ; + 1 push (rbx) = 16, 16-aligned
    push rbx
    cmp rsi, 1
    jne .amrev_arity
    mov rbx, [rdi]
    OBJ_LOCK rbx
    mov rax, [rbx + PyArrayObject.ob_size]
    cmp rax, 1
    jle .amrev_unlock_ok
    mov rcx, [rbx + PyArrayObject.ob_isize]
    mov rdi, [rbx + PyArrayObject.ob_data]  ; lo
    dec rax
    imul rax, rcx
    lea rsi, [rdi + rax]                    ; hi
    cmp rcx, 4
    je .amrev_4
    cmp rcx, 8
    je .amrev_8
    cmp rcx, 2
    je .amrev_2
.amrev_1:
    cmp rdi, rsi
    jae .amrev_unlock_ok
    mov al, [rdi]
    mov dl, [rsi]
    mov [rdi], dl
    mov [rsi], al
    inc rdi
    dec rsi
    jmp .amrev_1
.amrev_2:
    cmp rdi, rsi
    jae .amrev_unlock_ok
    mov ax, [rdi]
    mov dx, [rsi]
    mov [rdi], dx
    mov [rsi], ax
    add rdi, 2
    sub rsi, 2
    jmp .amrev_2
.amrev_4:
    cmp rdi, rsi
    jae .amrev_unlock_ok
    mov eax, [rdi]
    mov edx, [rsi]
    mov [rdi], edx
    mov [rsi], eax
    add rdi, 4
    sub rsi, 4
    jmp .amrev_4
.amrev_8:
    cmp rdi, rsi
    jae .amrev_unlock_ok
    mov rax, [rdi]
    mov rdx, [rsi]
    mov [rdi], rdx
    mov [rsi], rax
    add rdi, 8
    sub rsi, 8
    jmp .amrev_8
.amrev_unlock_ok:
    OBJ_UNLOCK rbx
    LOAD_NONE rax
    INCREF rax
    pop rbx
    leave
    ret
.amrev_arity:
    SET_EXC exc_TypeError_type, "reverse() takes no arguments"
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC array_m_reverse

;; ============================================================================
;; array_m_copy(rdi = args, rsi = nargs) -> rax = shallow copy array or 0
;; Also invoked by array_m_deepcopy.
;; ============================================================================
AMCP_SELF  equ 8
AMCP_OUT   equ 16
AMCP_FRAME equ 24               ; + 1 push (rbx) = 32, 16-aligned
global array_m_copy
DEF_FUNC array_m_copy, AMCP_FRAME
    push rbx
    cmp rsi, 1
    jne .amcpy_arity
    mov rbx, [rdi]
    mov [rbp - AMCP_SELF], rbx
    mov rdi, [rbx + PyArrayObject.ob_code]
    call array_find_code
    mov rdi, rax
    call array_new_empty
    test rax, rax
    jz .amcpy_fail
    mov [rbp - AMCP_OUT], rax

    OBJ_LOCK rbx
    mov rsi, [rbx + PyArrayObject.ob_size]
    test rsi, rsi
    jz .amcpy_unlock_done
    mov rdi, rax
    call array_reserve
    ERR_NULL .amcpy_unlock_drop
    mov r8, [rbp - AMCP_OUT]
    mov rdx, [rbx + PyArrayObject.ob_size]
    mov [r8 + PyArrayObject.ob_size], rdx
    imul rdx, [rbx + PyArrayObject.ob_isize]
    mov rdi, [r8 + PyArrayObject.ob_data]
    mov rsi, [rbx + PyArrayObject.ob_data]
    call ap_memcpy
.amcpy_unlock_done:
    OBJ_UNLOCK rbx
    mov rax, [rbp - AMCP_OUT]
    pop rbx
    leave
    ret
.amcpy_unlock_drop:
    OBJ_UNLOCK rbx
    mov rdi, [rbp - AMCP_OUT]
    call obj_decref
    jmp .amcpy_fail
.amcpy_arity:
    SET_EXC exc_TypeError_type, "__copy__() takes no arguments"
.amcpy_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC array_m_copy

;; ============================================================================
;; array_m_deepcopy(rdi = args, rsi = nargs) -> rax = shallow copy array or 0
;; ============================================================================
global array_m_deepcopy
DEF_FUNC array_m_deepcopy
    cmp rsi, 2
    jne .amdcpy_arity
    mov esi, 1
    leave
    jmp array_m_copy
.amdcpy_arity:
    SET_EXC exc_TypeError_type, "__deepcopy__() takes exactly one argument"
    xor eax, eax
    leave
    ret
END_FUNC array_m_deepcopy

;; ============================================================================
;; array_float_arg(rdi = Value) -> xmm0 = double, eax = 1 on success or 0 raising
;; Fails: 0
;; Accepts float/int/bool/subclasses, __float__, or __index__; rejects None,
;; str, etc. with TypeError (unlike raw float_to_f64 which returns 0.0).
;; ============================================================================
AFA_VAL   equ 8
AFA_EXC   equ 16
AFA_TMP   equ 24
AFA_FRAME equ 32                ; 0 pushes, 16-aligned
extern float_binop_accepts
extern float_to_f64
extern float_type
extern dunder_call_1
extern obj_as_index_object
global array_float_arg
DEF_FUNC array_float_arg, AFA_FRAME
    mov [rbp - AFA_VAL], rdi
    V_UNPACK rdi, rsi
    call float_binop_accepts
    test eax, eax
    jz .afa_try_dunder
    mov rdi, [rbp - AFA_VAL]
    V_UNPACK rdi, rsi
    call float_to_f64
    cmp qword [gs:ThreadState.current_exception], 0
    jne .afa_fail
    mov eax, 1
    leave
    ret

.afa_try_dunder:
    mov rdi, [rbp - AFA_VAL]
    V_TEST_PTR rdi, rax
    ja .afa_bad_type

    ; Try __float__ on heap object
    DUNDER_EXC_SAVE [rbp - AFA_EXC]
    CSTRING rsi, "__float__"
    call dunder_call_1          ; err: checked via DUNDER_RAISED below
    test rax, rax
    jnz .afa_got_float
    DUNDER_RAISED [rbp - AFA_EXC], .afa_fail

    ; No __float__: try nb_index (e.g. Intable)
    mov rdi, [rbp - AFA_VAL]
    mov rcx, [rdi + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_as_number]
    test rcx, rcx
    jz .afa_bad_type
    cmp qword [rcx + PyNumberMethods.nb_index], 0
    je .afa_bad_type
    V_UNPACK rdi, rdx
    call obj_as_index_object
    ERR_NULL .afa_fail
    mov [rbp - AFA_TMP], rax
    mov rdi, rax
    V_UNPACK rdi, rsi
    call float_to_f64
    sub rsp, 16
    movsd [rsp], xmm0
    mov rdi, [rbp - AFA_TMP]
    DECREF_V rdi, rcx
    movsd xmm0, [rsp]
    add rsp, 16
    cmp qword [gs:ThreadState.current_exception], 0
    jne .afa_fail
    mov eax, 1
    leave
    ret

.afa_got_float:
    ; __float__ returned owned Value in rax; must be float (or float subclass)
    mov [rbp - AFA_TMP], rax
    V_IS_FLOAT rax, rcx
    jb .afa_conv_float
    V_TEST_PTR rax, rcx
    ja .afa_bad_dunder_ret
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel float_type]
    cmp rcx, rdx
    je .afa_conv_float
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_FLOAT_SUBCLASS
    jz .afa_bad_dunder_ret
.afa_conv_float:
    mov rdi, rax
    V_UNPACK rdi, rsi
    call float_to_f64
    sub rsp, 16
    movsd [rsp], xmm0
    mov rdi, [rbp - AFA_TMP]
    DECREF_V rdi, rcx
    movsd xmm0, [rsp]
    add rsp, 16
    mov eax, 1
    leave
    ret

.afa_bad_dunder_ret:
    mov rdi, [rbp - AFA_TMP]
    DECREF_V rdi, rcx
    SET_EXC exc_TypeError_type, "__float__ returned non-float"
    xor eax, eax
    leave
    ret
.afa_bad_type:
    SET_EXC exc_TypeError_type, "must be real number"
.afa_fail:
    xor eax, eax
    leave
    ret
END_FUNC array_float_arg

;; ============================================================================
;; array_richcompare_direct(rdi = left, rsi = right, edx = op)
;;   -> (rax = bool_true/bool_false, edx = TAG_PTR), or (0, 0) on NotImpl/err
;;
;; Element-wise comparison without list_richcompare's identity shortcut, so
;; array('f', [nan]) != array('f', [nan]) is True and ==, <, <=, >, >= are
;; all False (matching CPython's array_richcompare).
;; ============================================================================
ARD_LEFT  equ 8
ARD_RIGHT equ 16
ARD_OP    equ 24
ARD_N1    equ 32
ARD_N2    equ 40
ARD_MIN   equ 48
ARD_IDX   equ 56
ARD_V1    equ 64
ARD_V2    equ 72
ARD_FRAME equ 88                ; + 1 push (rbx) = 96, 16-aligned
global array_richcompare_direct
DEF_FUNC array_richcompare_direct, ARD_FRAME
    push rbx
    V_TEST_PTR rsi, rax
    ja .ard_not_impl
    mov rax, [rsi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_ARRAY_SUBCLASS
    jz .ard_not_impl

    mov [rbp - ARD_LEFT], rdi
    mov [rbp - ARD_RIGHT], rsi
    mov [rbp - ARD_OP], rdx

    mov r8, [rdi + PyArrayObject.ob_size]
    mov r9, [rsi + PyArrayObject.ob_size]
    mov [rbp - ARD_N1], r8
    mov [rbp - ARD_N2], r9

    ; Short-circuit EQ/NE when lengths differ
    cmp rdx, PY_EQ
    je .ard_chk_len_eq
    cmp rdx, PY_NE
    je .ard_chk_len_ne
    jmp .ard_min_len
.ard_chk_len_eq:
    cmp r8, r9
    jne .ard_ret_false
    jmp .ard_min_len
.ard_chk_len_ne:
    cmp r8, r9
    jne .ard_ret_true

.ard_min_len:
    mov rax, r8
    cmp r9, rax
    cmovl rax, r9
    mov [rbp - ARD_MIN], rax
    mov qword [rbp - ARD_IDX], 0

.ard_loop:
    mov rbx, [rbp - ARD_IDX]
    cmp rbx, [rbp - ARD_MIN]
    jge .ard_prefix_eq

    ; Fetch v1 under lock
    mov rdi, [rbp - ARD_LEFT]
    OBJ_LOCK rdi
    cmp rbx, [rdi + PyArrayObject.ob_size]
    jge .ard_unlock1_prefix
    mov rsi, rbx
    call array_item_value
    mov rcx, [rbp - ARD_LEFT]
    OBJ_UNLOCK rcx
    test rax, rax
    jz .ard_error
    mov [rbp - ARD_V1], rax

    ; Fetch v2 under lock
    mov rdi, [rbp - ARD_RIGHT]
    OBJ_LOCK rdi
    cmp rbx, [rdi + PyArrayObject.ob_size]
    jge .ard_unlock2_drop1_prefix
    mov rsi, rbx
    call array_item_value
    mov rcx, [rbp - ARD_RIGHT]
    OBJ_UNLOCK rcx
    test rax, rax
    jz .ard_drop1_error
    mov [rbp - ARD_V2], rax

    ; Compare v1 == v2 (no identity shortcut for NaN -> nan == nan is False)
    mov rdi, [rbp - ARD_V1]
    mov rsi, rax
    V_IS_FLOAT rdi, rcx
    jae .ard_cmp_eq
    mov rax, rdi
    sub rax, [rel v_f64_off]
    movq xmm0, rax
    ucomisd xmm0, xmm0
    jp .ard_diff
.ard_cmp_eq:
    mov edx, PY_EQ
    call obj_richcompare_bool
    test eax, eax
    js .ard_drop12_error
    jz .ard_diff

    ; Equal: release both and continue
    mov rdi, [rbp - ARD_V1]
    DECREF_V rdi, rcx
    mov rdi, [rbp - ARD_V2]
    DECREF_V rdi, rcx
    inc qword [rbp - ARD_IDX]
    jmp .ard_loop

.ard_diff:
    mov rdx, [rbp - ARD_OP]
    cmp rdx, PY_EQ
    je .ard_drop12_false
    cmp rdx, PY_NE
    je .ard_drop12_true
    ; Ordering op on first differing pair
    mov rdi, [rbp - ARD_V1]
    mov rsi, [rbp - ARD_V2]
    call obj_richcompare_bool
    push rax
    sub rsp, 8
    mov rdi, [rbp - ARD_V1]
    DECREF_V rdi, rcx
    mov rdi, [rbp - ARD_V2]
    DECREF_V rdi, rcx
    add rsp, 8
    pop rax
    test eax, eax
    js .ard_error
    jz .ard_ret_false
    jmp .ard_ret_true

.ard_unlock1_prefix:
    OBJ_UNLOCK rdi
    jmp .ard_prefix_eq
.ard_unlock2_drop1_prefix:
    OBJ_UNLOCK rdi
    mov rdi, [rbp - ARD_V1]
    DECREF_V rdi, rcx

.ard_prefix_eq:
    mov rdi, [rbp - ARD_LEFT]
    mov r8, [rdi + PyArrayObject.ob_size]
    mov rsi, [rbp - ARD_RIGHT]
    mov r9, [rsi + PyArrayObject.ob_size]
    mov rdx, [rbp - ARD_OP]
    cmp rdx, PY_EQ
    je .ard_fin_eq
    cmp rdx, PY_NE
    je .ard_fin_ne
    cmp rdx, PY_LT
    je .ard_fin_lt
    cmp rdx, PY_LE
    je .ard_fin_le
    cmp rdx, PY_GT
    je .ard_fin_gt
    ; PY_GE
    cmp r8, r9
    jge .ard_ret_true
    jmp .ard_ret_false
.ard_fin_eq:
    cmp r8, r9
    je .ard_ret_true
    jmp .ard_ret_false
.ard_fin_ne:
    cmp r8, r9
    jne .ard_ret_true
    jmp .ard_ret_false
.ard_fin_lt:
    cmp r8, r9
    jl .ard_ret_true
    jmp .ard_ret_false
.ard_fin_le:
    cmp r8, r9
    jle .ard_ret_true
    jmp .ard_ret_false
.ard_fin_gt:
    cmp r8, r9
    jg .ard_ret_true
    jmp .ard_ret_false

.ard_drop12_true:
    mov rdi, [rbp - ARD_V1]
    DECREF_V rdi, rcx
    mov rdi, [rbp - ARD_V2]
    DECREF_V rdi, rcx
.ard_ret_true:
    lea rax, [rel bool_true]
    INCREF rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.ard_drop12_false:
    mov rdi, [rbp - ARD_V1]
    DECREF_V rdi, rcx
    mov rdi, [rbp - ARD_V2]
    DECREF_V rdi, rcx
.ard_ret_false:
    lea rax, [rel bool_false]
    INCREF rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.ard_drop12_error:
    mov rdi, [rbp - ARD_V2]
    DECREF_V rdi, rcx
.ard_drop1_error:
    mov rdi, [rbp - ARD_V1]
    DECREF_V rdi, rcx
.ard_error:
.ard_not_impl:
    RET_NULL
    pop rbx
    leave
    ret
END_FUNC array_richcompare_direct
