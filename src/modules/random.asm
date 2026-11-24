; random.asm - the `_randomcore` module: MT19937 itself.
;
; The same split src/modules/zlib.asm sets out: what is genuinely machine work
; lives here and everything a Python program sees lives in lib/_random.py.
; The generator's state is 624 words and a cursor, a handle is an INDEX into a
; table rather than a pointer, and every function here takes fixed positional
; arguments and answers an int, a float or a bytes.
;
; This was Python, and it was the Python that cost: `random()` was 47 times
; CPython's, `getrandbits` 26, and `randbytes` 1.8 seconds per megabyte --
; which is the whole reason test_zlib timed out, since CPython's
; check_big_compress_buffer opens with randbytes(10 * 1024 * 1024) whether or
; not -M was given.  The twist is a 624-iteration loop of shifts and xors, and
; an interpreter running it one bytecode at a time cannot be made fast.
;
; The SEQUENCE is the contract.  MT19937 is fully specified, and CPython's
; random.py, its tests and every recorded seed depend on the exact stream, so
; the acceptance test is a byte comparison against CPython for a given seed
; rather than a statistical one.  That includes the two details a rewrite gets
; wrong quietly: random() takes 27 bits from the first word and 26 from the
; second, in that order, and getrandbits above 32 composes little-endian words
; with the LAST one narrowed.

%include "macros.inc"
%include "object.inc"

extern none_singleton
extern ap_malloc
extern ap_free
extern ap_realloc
extern dict_new
extern dict_set
extern module_new
extern obj_decref
extern str_from_cstr_heap
extern builtin_func_new
extern bytes_new
extern bytes_type
extern float_from_f64
extern int_from_i64
extern obj_as_index
extern exc_TypeError_type
extern exc_ValueError_type
extern set_exception
extern list_type
extern tuple_type

MT_N        equ 624
MT_M        equ 397
MT_MATRIX_A equ 0x9908b0df
MT_UPPER    equ 0x80000000
MT_LOWER    equ 0x7fffffff
RC_MAGIC    equ 0x4D54524E          ; "MTRN"

struc MTState
    .mt:    resd MT_N       ; the state words
    .mti:   resq 1          ; the cursor; MT_N + 1 means "never seeded"
    .magic: resq 1
endstruc

section .bss
rc_handles:   resq 1        ; MTState*[], grown by doubling
rc_handle_n:  resq 1
rc_handle_cap: resq 1

section .text

;; ============================================================================
;; rc_handle_at(rdi = handle index) -> rax = MTState*, or 0
;;
;; Bounds-checked and magic-checked, because the index came from Python.
;; ============================================================================
DEF_FUNC_BARE rc_handle_at
    xor eax, eax
    test rdi, rdi
    js .rha_no
    cmp rdi, [rel rc_handle_n]
    jae .rha_no
    mov rax, [rel rc_handles]
    test rax, rax
    jz .rha_no
    mov rax, [rax + rdi*8]
    test rax, rax
    jz .rha_no
    cmp qword [rax + MTState.magic], RC_MAGIC
    je .rha_no_check
    xor eax, eax
.rha_no_check:
.rha_no:
    ret
END_FUNC rc_handle_at

;; ============================================================================
;; rc_state_arg(rdi = args, rsi = the index of the handle argument)
;;   -> rax = MTState*; ValueError when the handle is not live
;; Fails: 0
;; ============================================================================
RSA_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL rc_state_arg, RSA_FRAME
    mov rdi, [rdi + rsi*8]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .rsa_fail
    mov rdi, rax
    call rc_handle_at
    test rax, rax
    jz .rsa_bad
    leave
    ret
.rsa_bad:
    SET_EXC exc_ValueError_type, "invalid _randomcore handle"
.rsa_fail:
    xor eax, eax
    leave
    ret
END_FUNC rc_state_arg

;; ============================================================================
;; _randomcore.new() -> a handle
;;
;; The state is left UNSEEDED -- mti = N + 1 -- which is what makes the first
;; generate fall back to init_genrand(5489), as the reference implementation
;; does.
;; ============================================================================
RN_ST    equ 8
RN_FRAME equ 24             ; + 1 push = 32, 16-aligned
DEF_FUNC rc_new, RN_FRAME
    push rbx
    mov edi, MTState_size
    call ap_malloc
    test rax, rax
    jz .rn_oom
    mov rbx, rax
    mov qword [rbx + MTState.mti], MT_N + 1
    mov qword [rbx + MTState.magic], RC_MAGIC

    ; Find a free slot, or grow.
    xor ecx, ecx
    mov rdx, [rel rc_handles]
    test rdx, rdx
    jz .rn_grow
.rn_scan:
    cmp rcx, [rel rc_handle_n]
    jae .rn_grow
    cmp qword [rdx + rcx*8], 0
    je .rn_have_slot
    inc rcx
    jmp .rn_scan

.rn_grow:
    mov rax, [rel rc_handle_n]
    cmp rax, [rel rc_handle_cap]
    jb .rn_no_grow
    mov rsi, [rel rc_handle_cap]
    test rsi, rsi
    jnz .rn_double
    mov esi, 8
    jmp .rn_realloc
.rn_double:
    add rsi, rsi
.rn_realloc:
    mov [rbp - RN_ST], rsi
    shl rsi, 3
    mov rdi, [rel rc_handles]
    call ap_realloc
    test rax, rax
    jz .rn_oom_free
    mov [rel rc_handles], rax
    mov rcx, [rbp - RN_ST]
    mov [rel rc_handle_cap], rcx
.rn_no_grow:
    mov rcx, [rel rc_handle_n]
    inc qword [rel rc_handle_n]
    mov rdx, [rel rc_handles]

.rn_have_slot:
    mov [rdx + rcx*8], rbx
    mov rdi, rcx
    call int_from_i64
    V_PACK rax, rdx
    pop rbx
    leave
    ret

.rn_oom_free:
    mov rdi, rbx
    call ap_free
.rn_oom:
    SET_EXC exc_ValueError_type, "out of memory"
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC rc_new

;; ============================================================================
;; _randomcore.free(handle) -> None
;; ============================================================================
RF_IDX   equ 8
RF_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC rc_free, RF_FRAME
    cmp rsi, 1
    jne .rf_arity
    mov rdi, [rdi]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .idx_fail
    mov [rbp - RF_IDX], rax
    mov rdi, rax
    call rc_handle_at
    mov rcx, [rbp - RF_IDX]
    test rax, rax
    jz .rf_done
    mov qword [rax + MTState.magic], 0
    mov rdx, [rel rc_handles]
    mov qword [rdx + rcx*8], 0
    mov rdi, rax
    call ap_free
.rf_done:
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
.rf_arity:
    SET_EXC exc_TypeError_type, "free() takes exactly one argument"
.idx_fail:                      ; not an index: the exception is pending
    xor eax, eax
    leave
    ret
END_FUNC rc_free

;; ============================================================================
;; rc_init_genrand(rdi = MTState*, esi = the seed) -> nothing
;;
;; Knuth's initialiser, exactly as the reference implementation writes it:
;; mt[i] = 1812433253 * (mt[i-1] ^ (mt[i-1] >> 30)) + i, truncated to 32 bits.
;; ============================================================================
DEF_FUNC_BARE rc_init_genrand
    mov [rdi + MTState.mt], esi
    mov ecx, 1
.rig_loop:
    cmp rcx, MT_N
    jae .rig_done
    mov eax, [rdi + MTState.mt + rcx*4 - 4]
    mov edx, eax
    shr edx, 30
    xor eax, edx
    imul eax, eax, 1812433253
    add eax, ecx
    mov [rdi + MTState.mt + rcx*4], eax
    inc rcx
    jmp .rig_loop
.rig_done:
    mov qword [rdi + MTState.mti], MT_N
    ret
END_FUNC rc_init_genrand

;; ============================================================================
;; rc_twist(rdi = MTState*) -> nothing
;;
;; One pass of the recurrence over the whole state.  Written as the reference
;; does, in three parts, because the second half indexes backwards by N - M
;; and the last word wraps to mt[0].
;; ============================================================================
DEF_FUNC_BARE rc_twist
    xor ecx, ecx
.rt_first:
    cmp rcx, MT_N - MT_M
    jae .rt_second
    mov eax, [rdi + MTState.mt + rcx*4]
    and eax, MT_UPPER
    mov edx, [rdi + MTState.mt + rcx*4 + 4]
    and edx, MT_LOWER
    or eax, edx                     ; y
    mov edx, eax
    shr edx, 1
    mov r8d, [rdi + MTState.mt + rcx*4 + (MT_M * 4)]
    xor edx, r8d
    test eax, 1
    jz .rt_first_even
    xor edx, MT_MATRIX_A
.rt_first_even:
    mov [rdi + MTState.mt + rcx*4], edx
    inc rcx
    jmp .rt_first

.rt_second:
    cmp rcx, MT_N - 1
    jae .rt_last
    mov eax, [rdi + MTState.mt + rcx*4]
    and eax, MT_UPPER
    mov edx, [rdi + MTState.mt + rcx*4 + 4]
    and edx, MT_LOWER
    or eax, edx
    mov edx, eax
    shr edx, 1
    mov r8d, [rdi + MTState.mt + rcx*4 - ((MT_N - MT_M) * 4)]
    xor edx, r8d
    test eax, 1
    jz .rt_second_even
    xor edx, MT_MATRIX_A
.rt_second_even:
    mov [rdi + MTState.mt + rcx*4], edx
    inc rcx
    jmp .rt_second

.rt_last:
    mov eax, [rdi + MTState.mt + (MT_N - 1) * 4]
    and eax, MT_UPPER
    mov edx, [rdi + MTState.mt]
    and edx, MT_LOWER
    or eax, edx
    mov edx, eax
    shr edx, 1
    mov r8d, [rdi + MTState.mt + (MT_M - 1) * 4]
    xor edx, r8d
    test eax, 1
    jz .rt_last_even
    xor edx, MT_MATRIX_A
.rt_last_even:
    mov [rdi + MTState.mt + (MT_N - 1) * 4], edx
    mov qword [rdi + MTState.mti], 0
    ret
END_FUNC rc_twist

;; ============================================================================
;; rc_genrand(rdi = MTState*) -> eax = the next 32-bit word
;;
;; The tempering is four steps and they are not interchangeable; a transposed
;; pair still produces plausible noise and a different sequence.
;; ============================================================================
DEF_FUNC_BARE rc_genrand
    mov rcx, [rdi + MTState.mti]
    cmp rcx, MT_N
    jb .rg_have
    cmp rcx, MT_N + 1
    jne .rg_twist
    push rdi
    mov esi, 5489                   ; the reference's default seed
    call rc_init_genrand
    pop rdi
.rg_twist:
    push rdi
    call rc_twist
    pop rdi
    xor ecx, ecx
.rg_have:
    mov eax, [rdi + MTState.mt + rcx*4]
    inc rcx
    mov [rdi + MTState.mti], rcx

    mov edx, eax
    shr edx, 11
    xor eax, edx
    mov edx, eax
    shl edx, 7
    and edx, 0x9d2c5680
    xor eax, edx
    mov edx, eax
    shl edx, 15
    and edx, 0xefc60000
    xor eax, edx
    mov edx, eax
    shr edx, 18
    xor eax, edx
    ret
END_FUNC rc_genrand

;; ============================================================================
;; _randomcore.genrand(handle) -> the next 32-bit word, as an int
;; ============================================================================
DEF_FUNC rc_genrand_fn
    cmp rsi, 1
    jne .rgf_arity
    xor esi, esi
    call rc_state_arg
    ERR_NULL .rgf_fail
    mov rdi, rax
    call rc_genrand
    mov edi, eax
    call int_from_i64
    V_PACK rax, rdx
.rgf_fail:
    leave
    ret
.rgf_arity:
    ; With no argument at all args[0] is whatever the caller's stack held.
    SET_EXC exc_TypeError_type, "genrand() takes exactly one argument"
    leave
    ret
END_FUNC rc_genrand_fn

;; ============================================================================
;; _randomcore.random(handle) -> a double in [0, 1)
;;
;; 27 bits from the first word and 26 from the second, in that order: that
;; split is what makes the sequence CPython's, and reversing it produces
;; numbers that are just as uniform and completely different.
;; ============================================================================
RR_A     equ 8
RR_FRAME equ 24             ; + 1 push = 32, 16-aligned
DEF_FUNC rc_random, RR_FRAME
    push rbx
    cmp rsi, 1
    jne .rr_arity
    xor esi, esi
    call rc_state_arg
    ERR_NULL .rr_fail
    mov rbx, rax
    mov rdi, rbx
    call rc_genrand
    shr eax, 5
    mov [rbp - RR_A], rax
    mov rdi, rbx
    call rc_genrand
    shr eax, 6
    cvtsi2sd xmm1, eax
    cvtsi2sd xmm0, qword [rbp - RR_A]
    mulsd xmm0, [rel rc_67108864]
    addsd xmm0, xmm1
    mulsd xmm0, [rel rc_inv_2_53]
    call float_from_f64
    V_PACK rax, rdx
.rr_fail:
    pop rbx
    leave
    ret
.rr_arity:
    SET_EXC exc_TypeError_type, "random() takes exactly one argument"
    jmp .rr_fail
END_FUNC rc_random

;; ============================================================================
;; _randomcore.bits(handle, k) -> an int of exactly k random bits, k <= 32
;;
;; CPython's fast path: one word, shifted RIGHT by 32 - k, so the bits kept
;; are the most significant ones.  Anything wider goes through words() below,
;; because the result is a bignum and this cannot build one.
;; ============================================================================
RI_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC rc_bits, RI_FRAME
    cmp rsi, 2
    jne .ri_arity
    push rdi
    sub rsp, 8
    xor esi, esi
    call rc_state_arg
    ERR_NULL .ri_fail           ; leave drops what was pushed
    add rsp, 8
    pop rdi
    mov rdi, [rdi + 8]
    push rax
    sub rsp, 8
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .ri_fail
    add rsp, 8
    pop rdi                     ; the MTState*
    mov rcx, rax
    test rcx, rcx
    js .ri_negative
    cmp rcx, 32
    ja .ri_wide
    test rcx, rcx
    jz .ri_zero
    push rcx
    sub rsp, 8
    call rc_genrand
    add rsp, 8
    pop rcx
    neg ecx
    add ecx, 32
    shr eax, cl
    mov edi, eax
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
.ri_zero:
    xor edi, edi
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
.ri_negative:
    FAIL exc_ValueError_type, "number of bits must be non-negative", .ri_fail
.ri_wide:
    FAIL exc_ValueError_type, "bits() is limited to 32 bits", .ri_fail
.ri_arity:
    SET_EXC exc_TypeError_type, "bits() takes exactly two arguments"
.ri_fail:
    xor eax, eax
    leave
    ret
END_FUNC rc_bits

;; ============================================================================
;; _randomcore.words(handle, k) -> ceil(k / 32) * 4 bytes, little-endian
;;
;; The buffer CPython's getrandbits assembles before handing it to
;; _PyLong_FromByteArray: one word per 32 bits, least significant first, with
;; the LAST word shifted right by 32 - (k mod 32) when k is not a multiple of
;; 32.  The caller turns it into an int with int.from_bytes(b, "little"), and
;; randbytes takes its first n bytes -- which is what makes the two agree, and
;; what makes ten megabytes of random bytes one GMP import rather than two and
;; a half million interpreted shifts.
;;
;; The shift drops the LOW bits, so a one-byte tail is the word's TOP byte.
;; Emitting the low byte instead is uniform, plausible and a different
;; sequence from CPython's.
;; ============================================================================
RW_ST    equ 8
RW_OUT   equ 16
RW_W     equ 24              ; the word count
RW_I     equ 32
RW_LAST  equ 40              ; the last word's width in bits, 1..32
RW_FRAME equ 56              ; + 1 push = 64, 16-aligned
DEF_FUNC rc_words, RW_FRAME
    push rbx
    cmp rsi, 2
    jne .rw_arity
    mov rbx, rdi
    xor esi, esi
    call rc_state_arg
    ERR_NULL .rw_fail
    mov [rbp - RW_ST], rax
    mov rdi, [rbx + 8]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .rw_fail
    test rax, rax
    js .rw_negative
    test rax, rax
    jz .rw_empty

    ; words = (k - 1) / 32 + 1, and the last word's width is what is left.
    mov rcx, rax
    dec rcx
    shr rcx, 5
    inc rcx
    mov [rbp - RW_W], rcx
    dec rcx
    shl rcx, 5
    sub rax, rcx                ; k - 32 * (words - 1), in 1..32
    mov [rbp - RW_LAST], rax

    mov rdi, [rbp - RW_W]
    shl rdi, 2
    call bytes_new
    test rax, rax
    jz .rw_oom
    mov [rbp - RW_OUT], rax

    mov qword [rbp - RW_I], 0
.rw_loop:
    mov rcx, [rbp - RW_I]
    cmp rcx, [rbp - RW_W]
    jae .rw_done
    mov rdi, [rbp - RW_ST]
    call rc_genrand
    mov rcx, [rbp - RW_I]
    mov rdx, [rbp - RW_W]
    dec rdx
    cmp rcx, rdx
    jne .rw_store               ; only the last word is narrowed
    mov rcx, [rbp - RW_LAST]
    cmp rcx, 32
    je .rw_store_last
    neg ecx
    add ecx, 32
    shr eax, cl
.rw_store_last:
    mov rcx, [rbp - RW_I]
.rw_store:
    mov rsi, [rbp - RW_OUT]
    mov [rsi + PyBytesObject.data + rcx*4], eax
    inc qword [rbp - RW_I]
    jmp .rw_loop
.rw_done:
    mov rax, [rbp - RW_OUT]
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.rw_empty:
    xor edi, edi
    call bytes_new
    test rax, rax
    jz .rw_oom
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.rw_negative:
    FAIL exc_ValueError_type, "number of bits must be non-negative", .rw_fail
.rw_oom:
    FAIL exc_ValueError_type, "out of memory", .rw_fail
.rw_arity:
    SET_EXC exc_TypeError_type, "words() takes exactly two arguments"
.rw_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC rc_words

;; ============================================================================
;; _randomcore.seed_words(handle, words) -> None
;;
;; init_by_array over a list or tuple of 32-bit ints, which is the seeding
;; CPython uses for every seed that is not None -- so a recorded seed produces
;; a recorded sequence.  Knuth's two loops, written as the reference writes
;; them.
;; ============================================================================
RS_ST    equ 8
RS_KEY   equ 16
RS_KLEN  equ 24
RS_I     equ 32
RS_J     equ 40
RS_K     equ 48
RS_FRAME equ 72             ; + 1 push = 80, 16-aligned
DEF_FUNC rc_seed_words, RS_FRAME
    push rbx
    cmp rsi, 2
    jne .rs_arity
    mov rbx, rdi
    xor esi, esi
    call rc_state_arg
    ERR_NULL .rs_fail
    mov [rbp - RS_ST], rax

    mov rax, [rbx + 8]
    V_TEST_PTR rax, rcx
    ja .rs_type
    test rax, rax
    jz .rs_type
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel list_type]
    cmp rcx, rdx
    je .rs_have_seq
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    jne .rs_type
.rs_have_seq:
    mov [rbp - RS_KEY], rax
    mov rcx, [rax + PyListObject.ob_size]
    mov [rbp - RS_KLEN], rcx
    ; init_by_array reads key[j] before it asks whether j has wrapped, so an
    ; empty key is a read past an empty array.
    test rcx, rcx
    jz .rs_empty

    mov rdi, [rbp - RS_ST]
    mov esi, 19650218
    call rc_init_genrand

    mov qword [rbp - RS_I], 1
    mov qword [rbp - RS_J], 0
    mov rax, [rbp - RS_KLEN]
    cmp rax, MT_N
    jae .rs_k_is_len
    mov eax, MT_N
.rs_k_is_len:
    mov [rbp - RS_K], rax

.rs_first:
    cmp qword [rbp - RS_K], 0
    je .rs_second_init
    mov rdi, [rbp - RS_ST]
    mov rcx, [rbp - RS_I]
    mov eax, [rdi + MTState.mt + rcx*4 - 4]
    mov edx, eax
    shr edx, 30
    xor eax, edx
    imul eax, eax, 1664525
    xor eax, [rdi + MTState.mt + rcx*4]
    ; + key[j] + j
    mov rdx, [rbp - RS_KEY]
    mov rdx, [rdx + PyListObject.ob_item]
    mov rsi, [rbp - RS_J]
    mov rsi, [rdx + rsi*8]
    push rax
    mov rdi, rsi
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .rs_fail_pushed
    mov edx, eax
    pop rax
    add eax, edx
    add rax, [rbp - RS_J]
    mov rdi, [rbp - RS_ST]
    mov rcx, [rbp - RS_I]
    mov [rdi + MTState.mt + rcx*4], eax

    inc qword [rbp - RS_I]
    inc qword [rbp - RS_J]
    mov rcx, [rbp - RS_I]
    cmp rcx, MT_N
    jb .rs_first_no_wrap
    mov eax, [rdi + MTState.mt + (MT_N - 1) * 4]
    mov [rdi + MTState.mt], eax
    mov qword [rbp - RS_I], 1
.rs_first_no_wrap:
    mov rcx, [rbp - RS_J]
    cmp rcx, [rbp - RS_KLEN]
    jb .rs_first_no_jwrap
    mov qword [rbp - RS_J], 0
.rs_first_no_jwrap:
    dec qword [rbp - RS_K]
    jmp .rs_first

.rs_second_init:
    mov qword [rbp - RS_K], MT_N - 1
.rs_second:
    cmp qword [rbp - RS_K], 0
    je .rs_final
    mov rdi, [rbp - RS_ST]
    mov rcx, [rbp - RS_I]
    mov eax, [rdi + MTState.mt + rcx*4 - 4]
    mov edx, eax
    shr edx, 30
    xor eax, edx
    imul eax, eax, 1566083941
    mov edx, [rdi + MTState.mt + rcx*4]
    xor edx, eax
    mov eax, edx
    sub eax, ecx                    ; - i
    mov [rdi + MTState.mt + rcx*4], eax

    inc qword [rbp - RS_I]
    mov rcx, [rbp - RS_I]
    cmp rcx, MT_N
    jb .rs_second_no_wrap
    mov eax, [rdi + MTState.mt + (MT_N - 1) * 4]
    mov [rdi + MTState.mt], eax
    mov qword [rbp - RS_I], 1
.rs_second_no_wrap:
    dec qword [rbp - RS_K]
    jmp .rs_second

.rs_final:
    mov rdi, [rbp - RS_ST]
    mov dword [rdi + MTState.mt], MT_UPPER
    mov qword [rdi + MTState.mti], MT_N
    RET_NONE
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.rs_type:
    FAIL exc_TypeError_type, "seed_words() wants a list or tuple of ints", .rs_fail
.rs_arity:
    FAIL exc_TypeError_type, "seed_words() takes exactly two arguments", .rs_fail
.rs_empty:
    FAIL exc_ValueError_type, "seed_words() wants at least one word", .rs_fail
.rs_fail_pushed:
    pop rax                     ; the running word, parked across the call
.rs_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC rc_seed_words

;; ============================================================================
;; _randomcore.getstate(handle) -> 2500 bytes: 624 state words then mti
;;
;; Bytes rather than a tuple of 625 ints, because the conversion belongs on
;; the Python side where getstate() is asked for once and not in a loop.
;; ============================================================================
RG_FRAME equ 24             ; + 1 push = 32, 16-aligned
DEF_FUNC rc_getstate, RG_FRAME
    push rbx
    cmp rsi, 1
    jne .rgs_arity
    xor esi, esi
    call rc_state_arg
    ERR_NULL .rgs_fail
    mov rbx, rax
    mov edi, (MT_N + 1) * 4
    call bytes_new
    test rax, rax
    jz .rgs_oom
    lea rdi, [rax + PyBytesObject.data]
    mov rsi, rbx
    mov ecx, MT_N
.rgs_copy:
    mov edx, [rsi]
    mov [rdi], edx
    add rsi, 4
    add rdi, 4
    dec ecx
    jnz .rgs_copy
    mov rdx, [rbx + MTState.mti]
    mov [rdi], edx
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.rgs_arity:
    FAIL exc_TypeError_type, "getstate() takes exactly one argument", .rgs_fail
.rgs_oom:
    SET_EXC exc_ValueError_type, "out of memory"
.rgs_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC rc_getstate

;; ============================================================================
;; _randomcore.setstate(handle, data) -> None
;;
;; The inverse of getstate(): exactly the same 2500 bytes, with mti checked
;; against N because a cursor past the end would read off the state.
;; ============================================================================
RT_ST    equ 8
RT_FRAME equ 24             ; + 1 push = 32, 16-aligned
DEF_FUNC rc_setstate, RT_FRAME
    push rbx
    cmp rsi, 2
    jne .rss_arity
    mov rbx, rdi
    xor esi, esi
    call rc_state_arg
    ERR_NULL .rss_fail
    mov [rbp - RT_ST], rax

    mov rax, [rbx + 8]
    V_TEST_PTR rax, rcx
    ja .rss_type
    test rax, rax
    jz .rss_type
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    jne .rss_type
    cmp qword [rax + PyBytesObject.ob_size], (MT_N + 1) * 4
    jne .rss_size

    lea rsi, [rax + PyBytesObject.data]
    mov rdi, [rbp - RT_ST]
    mov ecx, MT_N
.rss_copy:
    mov edx, [rsi]
    mov [rdi], edx
    add rsi, 4
    add rdi, 4
    dec ecx
    jnz .rss_copy
    mov edx, [rsi]
    cmp edx, MT_N
    ja .rss_value
    mov rax, [rbp - RT_ST]
    mov [rax + MTState.mti], rdx
    RET_NONE
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.rss_value:
    FAIL exc_ValueError_type, "invalid state", .rss_fail
.rss_size:
    FAIL exc_ValueError_type, "state is the wrong size", .rss_fail
.rss_type:
    FAIL exc_TypeError_type, "setstate() wants bytes", .rss_fail
.rss_arity:
    SET_EXC exc_TypeError_type, "setstate() takes exactly two arguments"
.rss_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC rc_setstate

;; ============================================================================
;; random_module_create() -> rax = the module object
;; ============================================================================
RMC_FRAME equ 32            ; + 2 pushes = 48, 16-aligned
DEF_FUNC random_module_create, RMC_FRAME
    push rbx
    push r12
    call dict_new
    mov r12, rax                ; MODULE_ADD_FUNC reads the dict from r12

    MODULE_ADD_FUNC rc_new,        rc_n_new
    MODULE_ADD_FUNC rc_free,       rc_n_free
    MODULE_ADD_FUNC rc_genrand_fn, rc_n_genrand
    MODULE_ADD_FUNC rc_random,     rc_n_random
    MODULE_ADD_FUNC rc_bits,       rc_n_bits
    MODULE_ADD_FUNC rc_words,      rc_n_words
    MODULE_ADD_FUNC rc_seed_words, rc_n_seed_words
    MODULE_ADD_FUNC rc_getstate,   rc_n_getstate
    MODULE_ADD_FUNC rc_setstate,   rc_n_setstate

    lea rdi, [rel rc_name]
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov rbx, rax
    mov rdi, r12
    call obj_decref
    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret
END_FUNC random_module_create

section .rodata
align 8
rc_67108864: dq 0x4190000000000000      ; 67108864.0
rc_inv_2_53: dq 0x3CA0000000000000      ; 1.0 / 9007199254740992.0
rc_name:         db "_randomcore", 0
rc_n_new:        db "new", 0
rc_n_free:       db "free", 0
rc_n_genrand:    db "genrand", 0
rc_n_random:     db "random", 0
rc_n_bits:       db "bits", 0
rc_n_words:      db "words", 0
rc_n_seed_words: db "seed_words", 0
rc_n_getstate:   db "getstate", 0
rc_n_setstate:   db "setstate", 0

ASM_INIT
