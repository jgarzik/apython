; pyo/int.asm - Integer type (fat value TAG_SMALLINT + GMP arbitrary precision)
;
; Fat value TAG_SMALLINT: tag=1, payload=raw signed i64, full 64-bit range
; No heap allocation or refcounting needed for inline integers.
;
; PyIntObject layout (GMP-backed, heap-allocated):
;   +0  ob_refcnt (8 bytes)
;   +8  ob_type   (8 bytes)
;   +16 mpz       (16 bytes: _mp_alloc:4, _mp_size:4, _mp_d:8)
;   Total: PyIntObject_size = 32

%include "macros.inc"
%include "object.inc"

extern ap_malloc
extern ap_free
extern str_from_cstr
extern str_from_cstr_heap
extern bool_true
extern bool_false
extern none_singleton
extern type_type

; GMP functions
extern bool_type
extern __gmpz_init
extern int_true_divide
extern __gmpz_set
extern __gmpz_set_si
extern __gmpz_setbit
extern __gmpz_fdiv_r_2exp
extern __gmpz_tstbit
extern __gmpz_add_ui
extern __gmpz_tdiv_qr
extern __gmpz_init_set_si
extern __gmpz_clear
extern __gmpz_get_si
extern __gmpz_fits_slong_p
extern __gmpz_tdiv_ui
extern __gmpz_get_str
extern __gmpz_add
extern __gmpz_sub
extern __gmpz_mul
extern __gmpz_fdiv_q
extern __gmpz_fdiv_r
extern __gmpz_neg
extern __gmpz_cmp
extern __gmpz_cmp_si
extern __gmpz_sizeinbase
extern __gmpz_set_str
extern __gmpz_and
extern __gmpz_ior
extern __gmpz_xor
extern __gmpz_com
extern __gmpz_mul_2exp
extern __gmpz_fdiv_q_2exp
extern __gmpz_pow_ui
extern __gmpz_get_d

extern raise_exception
extern strlen
extern exc_ValueError_type
extern exc_ZeroDivisionError_type
extern float_from_f64
extern int_repr           ; pyo/int_str.asm
extern int_from_cstr_base ; pyo/int_str.asm
extern int_base_str       ; pyo/int_str.asm


;; ============================================================================

;; ============================================================================
;; int_from_i64(int64_t val) -> (rax=payload, edx=TAG_SMALLINT)
;; All i64 values are SmallInt (payload = raw signed 64-bit).
;; ============================================================================
DEF_FUNC_BARE int_from_i64
%ifdef INT_STRESS_BOX
    ; Stress build (make INT_STRESS=1): box anything with |v| >= INT_STRESS_BOX
    ; as a compact heap int, so the ordinary test suite exercises the heap-int
    ; paths that the shrinking immediate range will make common.  Small-int
    ; identity (`x is y`) differs from CPython in this mode by construction.
    mov rax, rdi
    mov rcx, rdi
    sar rcx, 63
    xor rax, rcx
    sub rax, rcx
    cmp rax, INT_STRESS_BOX
    jb .inline
    push rbp
    mov rbp, rsp
    call int_new_compact
    mov edx, TAG_PTR
    leave
    ret
.inline:
%endif
    mov rax, rdi
    RET_TAG_SMALLINT
    ret
END_FUNC int_from_i64

;; ============================================================================
;; int_promote_mpz(rdi: PyIntObject*) -> void
;;
;; Give a compact integer a real mpz_t, in place.  Idempotent in practice
;; because callers reach it through INT_NEED_MPZ, which checks .compact first.
;;
;; PRESERVES EVERY REGISTER, so INT_NEED_MPZ can be dropped in front of any
;; .mpz access without auditing what is live around it.
;; ============================================================================
IPM_RSP equ 8               ; the caller's rsp, while GMP is called on an
                            ;   aligned one
IPM_FRAME equ 16            ; + 10 pushes below, which are mid-body
DEF_FUNC int_promote_mpz, IPM_FRAME
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push rdi                    ; the object again, for after the call
    mov rsi, [rdi + PyIntObject.ival]
    lea rdi, [rdi + PyIntObject.mpz]
    ; ALIGN rather than count.  The tenth push used to be here to make the
    ; pushes even, which is right only if the CALLER got its own parity right
    ; -- and INT_NEED_MPZ, the macro that reaches this, brackets the call with
    ; a single push, so it arrives at whichever parity its own caller had.
    ; Measured: two calls in a bignum workload came in eight out.
    mov [rbp - IPM_RSP], rsp
    and rsp, -16
    call __gmpz_init_set_si wrt ..plt
    mov rsp, [rbp - IPM_RSP]
    pop rdi                     ; the object again
    mov qword [rdi + PyIntObject.compact], 0
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    leave
    ret
END_FUNC int_promote_mpz

;; ============================================================================
;; int_alloc_raw() -> rax = PyIntObject_size bytes, uninitialised
;;
;; Every heap integer in this file comes from here, and int_dealloc hands the
;; block back rather than to free().
;;
;; A heap integer is the shortest-lived object this interpreter makes.  A loop
;; whose accumulator has grown past +-2^50 allocates one per iteration and
;; frees the previous one immediately, so glibc's malloc and free were 29.7% of
;; such a loop -- more than GMP and the interpreter's own arithmetic together.
;; The size is fixed and the type is fixed, so the general allocator is being
;; asked a question with one answer.
;;
;; CPython has no int freelist, but it does not need one: every object below
;; 512 bytes comes from pymalloc, which is a per-size-class free list already.
;; This is that, for the one size class that matters here.
;;
;; The block is handed back RAW.  A caller that wants a compact integer sets
;; .compact itself and a caller that wants a GMP-backed one clears it and
;; calls __gmpz_init, exactly as when this was ap_malloc.  Nothing may assume
;; a recycled block's mpz is live: int_dealloc clears it before recycling.
;;
;; The cap keeps a program that builds a large list of big integers and then
;; drops it from holding the memory: past INT_FREELIST_MAX blocks the rest go
;; back to libc.
;;
;; Building with -DNO_INT_FREELIST turns this into a plain ap_malloc, which is
;; what to do when running under valgrind: a recycled block is not a freed one,
;; so a use-after-free on an integer is invisible while the list is on.
;; ============================================================================
INT_FREELIST_MAX equ 256

DEF_FUNC_BARE int_alloc_raw
%ifndef NO_INT_FREELIST
    mov rax, [rel int_freelist]
    test rax, rax
    jz .ial_malloc
    ; The block is dead, so its refcount word is free to hold the next link.
    mov rcx, [rax + PyObject.ob_refcnt]
    mov [rel int_freelist], rcx
    dec qword [rel int_freelist_count]
    ret
.ial_malloc:
%endif
    push rbp
    mov rbp, rsp
    mov edi, PyIntObject_size
    call ap_malloc
    leave
    ret
END_FUNC int_alloc_raw

;; ============================================================================
;; int_new_compact(int64_t val) -> rax: PyIntObject*
;; Heap integer with no GMP init and no limb allocation.
;; ============================================================================
DEF_FUNC int_new_compact
    push rbx
    push r12
    mov rbx, rdi
    call int_alloc_raw
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyIntObject.ival], rbx
    mov qword [rax + PyIntObject.compact], 1
    pop r12
    pop rbx
    leave
    ret
END_FUNC int_new_compact

;; ============================================================================
;; int_from_i64_gmp(int64_t val) -> (rax=PyIntObject*, edx=TAG_PTR)
;; Heap integer from an int64.  Compact: the mpz is created lazily, only if
;; something actually needs it.  (Name kept for its many call sites.)
;; ============================================================================
DEF_FUNC_BARE int_from_i64_gmp
    push rbp
    mov rbp, rsp
    call int_new_compact
    mov edx, TAG_PTR
    leave
    ret
END_FUNC int_from_i64_gmp

;; ============================================================================
;; smallint_to_pyint(SmallInt val) -> PyIntObject*
;; Decode SmallInt and create GMP-backed int
;; ============================================================================
DEF_FUNC_BARE smallint_to_pyint
    jmp int_from_i64_gmp
END_FUNC smallint_to_pyint

;; ============================================================================
;; int_fits_i64(rdi = payload, edx = tag) -> eax = 1 when the value fits
;;
;; int_to_i64 truncates through __gmpz_get_si, so a count of 2**64 came back
;; as 0 and [0] * (2**64) quietly returned [] instead of raising.
DEF_FUNC int_fits_i64
    cmp edx, TAG_SMALLINT
    je .ifi_yes
    cmp edx, TAG_PTR
    jne .ifi_yes                ; not an int at all; the caller's type check
                                ; deals with that
    call int_unwrap             ; see int_to_i64
    cmp edx, TAG_SMALLINT
    je .ifi_yes
    cmp qword [rdi + PyIntObject.compact], 0
    jne .ifi_yes                ; the compact ival is live, so it fits
    lea rdi, [rdi + PyIntObject.mpz]
    call __gmpz_fits_slong_p wrt ..plt
    test eax, eax
    jz .ifi_no
.ifi_yes:
    mov eax, 1
    leave
    ret
.ifi_no:
    xor eax, eax
    leave
    ret
END_FUNC int_fits_i64

;; ============================================================================
;; int_to_i64(PyObject *obj) -> int64_t
;; Extract integer value as C int64. Handles SmallInt.
;; ============================================================================
DEF_FUNC_BARE int_to_i64
    cmp edx, TAG_SMALLINT
    je .smallint
    ; An int SUBCLASS wraps an int rather than being one -- buildclass gives
    ; it a PyInstanceObject layout, not room on the end of a PyIntObject -- so
    ; reading .compact here would read the wrapper's own header.  Most callers
    ; unwrap first; the ones that only checked the type with REQUIRE_INT_TYPE
    ; did not, and every value they read came out as 0.  int_unwrap is cheap
    ; and idempotent: for an exact int it is one compare.
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .smallint
    cmp qword [rdi + PyIntObject.compact], 0
    jne .compact                ; heap int whose value already fits int64
    push rbp
    mov rbp, rsp
    lea rdi, [rdi + PyIntObject.mpz]
    call __gmpz_get_si wrt ..plt
    pop rbp
    ret
.compact:
    mov rax, [rdi + PyIntObject.ival]
    ret
.smallint:
    mov rax, rdi
    ret
END_FUNC int_to_i64
;; ============================================================================
;; int_hash_i64(rdi: int64) -> rax: int64
;;
;; CPython's integer hash: sign(v) * (|v| mod PyHASH_MODULUS), with -1 mapped
;; to -2.  PyHASH_MODULUS is 2^61-1, so any |v| < 2^61-1 hashes to itself --
;; that fast path covers every immediate and almost every heap int.
;;
;; Shared by int_hash, obj_hash and builtin_hash so that all three agree; a
;; disagreement silently corrupts dict and set lookups.
;; ============================================================================
DEF_FUNC_BARE int_hash_i64
    mov rcx, rdi
    sar rcx, 63                 ; rcx = sign mask (0 or -1)
    mov rax, rdi
    xor rax, rcx
    sub rax, rcx                ; rax = |v| (INT64_MIN -> 2^63, unsigned)
    mov r8, PYHASH_MODULUS
    cmp rax, r8
    jb .ihi_small               ; |v| < modulus: the value is its own hash

    xor edx, edx
    div r8                      ; rdx = |v| mod modulus
    mov rax, rdx
    xor rax, rcx
    sub rax, rcx                ; reapply the sign
    jmp .ihi_fix

.ihi_small:
    mov rax, rdi
.ihi_fix:
    cmp rax, -1
    jne .ihi_done
    mov rax, -2
.ihi_done:
    ret
END_FUNC int_hash_i64

;; ============================================================================
;; int_hash(rdi: PyObject *self, edx: tag) -> int64
;;
;; NOTE: edx MUST hold the value's tag -- it is forwarded to int_unwrap.
;; ============================================================================
DEF_FUNC_BARE int_hash
    ; Unwrap int subclass instances
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .smallint

    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8              ; rbp and one callee-saved push leave the frame
                            ; eight bytes out of 16-alignment, and the ABI
                            ; wants rsp % 16 == 0 at the call below
    mov rbx, rdi
    INT_NEED_MPZ rbx
    lea rdi, [rbx + PyIntObject.mpz]
    mov rsi, PYHASH_MODULUS
    call __gmpz_tdiv_ui wrt ..plt   ; rax = |n| mod modulus
    INT_NEED_MPZ rbx
    mov ecx, [rbx + PyIntObject.mpz + 4]   ; _mp_size carries the sign
    test ecx, ecx
    jns .done
    neg rax
.done:
    cmp rax, -1
    jne .done2
    mov rax, -2
.done2:
    add rsp, 8
    pop rbx
    pop rbp
    ret

.smallint:
    jmp int_hash_i64
END_FUNC int_hash

;; ============================================================================
;; int_bool(PyObject *self) -> int (0 or 1)
;; SmallInt: decoded != 0. GMP: cmp_si(0) != 0.
;; ============================================================================
DEF_FUNC_BARE int_bool
    ; Unwrap int subclass instances
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .smallint

    push rbp
    mov rbp, rsp
    INT_NEED_MPZ rdi
    lea rdi, [rdi + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    setne al
    movzx eax, al
    pop rbp
    ret

.smallint:
    test rdi, rdi
    setnz al
    movzx eax, al
    ret
END_FUNC int_bool

;; ============================================================================
;; int_add(PyObject *a, PyObject *b) -> rax = Value
;; SmallInt x SmallInt fast path with overflow check.
;; ============================================================================
DEF_FUNC_BARE int_add
    call int_binop_unpack       ; rdi/edx = left, rsi/ecx = right, both ints
    test eax, eax
    jnz .operands_ok
    xor eax, eax                ; not both ints: a NULL Value is NotImplemented,
    ret                         ; so the caller tries the other operand's slot
.operands_ok:
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp_path
    cmp ecx, TAG_SMALLINT
    jne .gmp_path

    ; Both SmallInt: decode and add
    ; The tag has to be saved BEFORE rcx is clobbered.  .gmp_path is reached
    ; two ways -- from the tag checks above, where ecx is the right operand's
    ; TAG, and from the `jo` below, where `mov rcx, rsi` has just made it the
    ; right operand's PAYLOAD.  Entering with a payload made .gmp_path's
    ; `push rcx ; save right_tag` save the wrong thing, so `cmp ecx,
    ; TAG_SMALLINT` failed, smallint_to_pyint was never called, and the raw
    ; integer was dereferenced as a PyIntObject*.
    ;
    ; `s = s + 2**49` in a loop segfaulted the moment the accumulator crossed
    ; 2**63 and took this path.  TAG_SMALLINT is 1, so an addend whose low 32
    ; bits happened to equal 1 passed the broken comparison -- which is why
    ; `s += 1` was fine and every other step was not.  int_mul already does it
    ; this way; add and sub did not.
    mov rax, rdi
    push rcx                ; save right_tag (ecx) before clobber
    mov rcx, rsi
    add rax, rcx
    jo .gmp_path_pop        ; overflow, fall back to GMP
    add rsp, 8              ; discard saved right_tag

    ; Result fits: encode as SmallInt
    RET_TAG_SMALLINT
    V_PACK rax, rdx             ; return one Value
    ret

.gmp_path_pop:
    pop rcx                 ; restore right_tag
.gmp_path:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi

    ; --- big + small, without building an mpz for the small ---------------
    ; int_binop_unpack has already flattened a compact heap int into an
    ; immediate, so an operand still tagged TAG_PTR here is genuinely
    ; GMP-backed and the other one, when it is an immediate, is an int64 GMP
    ; will take directly.  Going through smallint_to_pyint instead cost an
    ; object allocation, an __gmpz_init, an __gmpz_set and an __gmpz_clear
    ; with its free -- per addition, and `s += x + i` over a bignum
    ; accumulator is exactly this shape.  Callgrind put malloc and free
    ; together at 19.7% of that loop.
    ;
    ; Both-immediate reaches here too, from the `jo` above, and wants the
    ; general path: there is no mpz to add to.
    cmp edx, TAG_SMALLINT
    je .add_small_left
    cmp ecx, TAG_SMALLINT
    jne .add_both_big
    mov r13, r12            ; right is the immediate
    mov r12, rbx            ; left is the mpz
    jmp .add_mixed
.add_small_left:
    cmp ecx, TAG_SMALLINT
    je .add_both_big        ; both immediates: the overflow arm
    mov r13, rbx            ; left is the immediate, r12 already the mpz
.add_mixed:
    mov rax, 0x8000000000000000
    cmp r13, rax
    je .add_mixed_general   ; -2**63 has no positive magnitude to hand mpz_ui

    sub rsp, 8              ; the GMP calls want rsp 16-byte aligned
    call int_alloc_raw
    mov rbx, rax
    mov qword [rbx + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rbx + PyObject.ob_type], rcx
    mov qword [rbx + PyIntObject.compact], 0  ; GMP-backed
    lea rdi, [rbx + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    lea rdi, [rbx + PyIntObject.mpz]
    lea rsi, [r12 + PyIntObject.mpz]
    mov rdx, r13
    test rdx, rdx
    js .add_mixed_neg
    extern __gmpz_add_ui
    call __gmpz_add_ui wrt ..plt
    jmp .add_mixed_done
.add_mixed_neg:
    neg rdx
    extern __gmpz_sub_ui
    call __gmpz_sub_ui wrt ..plt
.add_mixed_done:
    add rsp, 8
    mov rax, rbx
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    pop rbp
    V_PACK rax, rdx             ; return one Value
    ret

.add_mixed_general:
    ; -2**63 fell out of the arm above; put the operands back the way the
    ; general path expects to find them and let it build the temporary.
    mov rbx, rdi
    mov r12, rsi

.add_both_big:
    ; Convert SmallInt args to GMP if needed
    push rcx                ; save right_tag across left conversion
    cmp edx, TAG_SMALLINT
    jne .a_ready
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1             ; flag: a was converted
    jmp .check_b
.a_ready:
    xor r13d, r13d
.check_b:
    pop rcx                 ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ready
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2              ; flag: b was converted
.b_ready:
    ; Allocate result
    call int_alloc_raw
    push rax                ; save result ptr
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyIntObject.compact], 0  ; GMP-backed
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]          ; reload result ptr
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    INT_NEED_MPZ rbx
    lea rsi, [rbx + PyIntObject.mpz]
    INT_NEED_MPZ r12
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_add wrt ..plt

    ; Free any temp GMP ints
    test r13b, 1
    jz .no_free_a
    mov rdi, rbx
    call int_dealloc
.no_free_a:
    test r13b, 2
    jz .no_free_b
    mov rdi, r12
    call int_dealloc
.no_free_b:
    pop rax
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    pop rbp
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC int_add

;; ============================================================================
;; int_sub(PyObject *a, PyObject *b) -> rax = Value
;; ============================================================================
DEF_FUNC_BARE int_sub
    call int_binop_unpack       ; rdi/edx = left, rsi/ecx = right, both ints
    test eax, eax
    jnz .operands_ok
    xor eax, eax                ; not both ints: a NULL Value is NotImplemented,
    ret                         ; so the caller tries the other operand's slot
.operands_ok:
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp_path
    cmp ecx, TAG_SMALLINT
    jne .gmp_path

    ; The tag has to be saved BEFORE rcx is clobbered.  .gmp_path is reached
    ; two ways -- from the tag checks above, where ecx is the right operand's
    ; TAG, and from the `jo` below, where `mov rcx, rsi` has just made it the
    ; right operand's PAYLOAD.  Entering with a payload made .gmp_path's
    ; `push rcx ; save right_tag` save the wrong thing, so `cmp ecx,
    ; TAG_SMALLINT` failed, smallint_to_pyint was never called, and the raw
    ; integer was dereferenced as a PyIntObject*.
    ;
    ; `s = s + 2**49` in a loop segfaulted the moment the accumulator crossed
    ; 2**63 and took this path.  TAG_SMALLINT is 1, so an addend whose low 32
    ; bits happened to equal 1 passed the broken comparison -- which is why
    ; `s += 1` was fine and every other step was not.  int_mul already does it
    ; this way; add and sub did not.
    mov rax, rdi
    push rcx                ; save right_tag (ecx) before clobber
    mov rcx, rsi
    sub rax, rcx
    jo .gmp_path_pop
    add rsp, 8              ; discard saved right_tag
    RET_TAG_SMALLINT
    V_PACK rax, rdx             ; return one Value
    ret

.gmp_path_pop:
    pop rcx                 ; restore right_tag
.gmp_path:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    push rcx                ; save right_tag
    cmp edx, TAG_SMALLINT
    jne .a_ready
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1
    jmp .check_b
.a_ready:
    xor r13d, r13d
.check_b:
    pop rcx                 ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ready
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2
.b_ready:
    call int_alloc_raw
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyIntObject.compact], 0  ; GMP-backed
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    INT_NEED_MPZ rbx
    lea rsi, [rbx + PyIntObject.mpz]
    INT_NEED_MPZ r12
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_sub wrt ..plt
    test r13b, 1
    jz .no_free_a
    mov rdi, rbx
    call int_dealloc
.no_free_a:
    test r13b, 2
    jz .no_free_b
    mov rdi, r12
    call int_dealloc
.no_free_b:
    pop rax
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    pop rbp
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC int_sub

;; ============================================================================
;; int_mul(PyObject *a, PyObject *b) -> rax = Value
;; SmallInt x SmallInt: use imul with overflow detection
;; ============================================================================
DEF_FUNC_BARE int_mul
    call int_binop_unpack       ; rdi/edx = left, rsi/ecx = right, both ints
    test eax, eax
    jnz .operands_ok
    xor eax, eax                ; not both ints: a NULL Value is NotImplemented,
    ret                         ; so the caller tries the other operand's slot
.operands_ok:
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp_path
    cmp ecx, TAG_SMALLINT
    jne .gmp_path

    mov rax, rdi
    push rcx                ; save right_tag (ecx) before clobber
    mov rcx, rsi
    imul rax, rcx
    jo .gmp_path_pop
    add rsp, 8             ; discard saved right_tag
    RET_TAG_SMALLINT
    V_PACK rax, rdx             ; return one Value
    ret

.gmp_path_pop:
    pop rcx                 ; restore right_tag
.gmp_path:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    push rcx                ; save right_tag
    cmp edx, TAG_SMALLINT
    jne .a_ready
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1
    jmp .check_b
.a_ready:
    xor r13d, r13d
.check_b:
    pop rcx                 ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ready
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2
.b_ready:
    call int_alloc_raw
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyIntObject.compact], 0  ; GMP-backed
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    INT_NEED_MPZ rbx
    lea rsi, [rbx + PyIntObject.mpz]
    INT_NEED_MPZ r12
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_mul wrt ..plt
    test r13b, 1
    jz .no_free_a
    mov rdi, rbx
    call int_dealloc
.no_free_a:
    test r13b, 2
    jz .no_free_b
    mov rdi, r12
    call int_dealloc
.no_free_b:
    pop rax
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    pop rbp
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC int_mul

;; ============================================================================
;; int_floordiv(PyObject *a, PyObject *b) -> rax = Value
;; ============================================================================
FD_RTAG   equ 32            ; the right operand's tag, across a conversion call
FD_NEW    equ 40            ; the result object, across the GMP calls
FD_LOCALS equ 24            ; those two and the pad that keeps .gmp_path's
                            ; every call 16-aligned: with rbp and three
                            ; callee-saved pushes the frame is 32 bytes deep,
                            ; and 24 more is the next multiple of 16.  The two
                            ; `push`es these slots replace each flipped the
                            ; parity for a stretch of the body, and GMP is
                            ; called from both stretches -- __gmpz_cmp_si
                            ; below was reached eight bytes out on every
                            ; big-integer floor division.
DEF_FUNC_BARE int_floordiv
    call int_binop_unpack       ; rdi/edx = left, rsi/ecx = right, both ints
    test eax, eax
    jnz .operands_ok
    xor eax, eax                ; not both ints: a NULL Value is NotImplemented,
    ret                         ; so the caller tries the other operand's slot
.operands_ok:
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp_path
    cmp ecx, TAG_SMALLINT
    jne .gmp_path

    ; SmallInt fast path
    test rsi, rsi
    jz .zdiv_error          ; div by zero -> raise ZeroDivisionError
    cmp rsi, -1
    je .fd_neg_one          ; idiv TRAPS on INT64_MIN / -1: the quotient has no
                            ; int64, and the CPU raises #DE for it exactly as
                            ; it does for a zero divisor.  These operands are
                            ; int_binop_unpack's, so they are full int64s and
                            ; not immediates -- a compact heap int holding
                            ; -2**63 reaches here, and `(-2**63) // -1` died
                            ; with SIGFPE inside int_floordiv.
    mov rax, rdi
    mov rcx, rsi
    cqo
    idiv rcx
    ; Python floored division: if remainder != 0 and has different sign from divisor, adjust
    test rdx, rdx
    jz .smallint_done
    mov r8, rdx
    xor r8, rcx
    jns .smallint_done
    dec rax
.smallint_done:
    RET_TAG_SMALLINT
    V_PACK rax, rdx             ; return one Value
    ret

.fd_neg_one:
    ; a // -1 is -a exactly.  -INT64_MIN is the one that does not fit, and it
    ; goes to GMP -- where ecx is still the right operand's tag, because
    ; nothing above has written it.
    mov rax, rdi
    neg rax
    jo .gmp_path
    RET_TAG_SMALLINT
    V_PACK rax, rdx             ; return one Value
    ret

.zdiv_error:
    push rbp
    mov rbp, rsp
    RAISE exc_ZeroDivisionError_type, "integer division or modulo by zero"

.gmp_path:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, FD_LOCALS
    mov rbx, rdi
    mov r12, rsi
    mov [rbp - FD_RTAG], rcx    ; save right_tag
    cmp edx, TAG_SMALLINT
    jne .a_ready
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1
    jmp .check_b
.a_ready:
    xor r13d, r13d
.check_b:
    mov rcx, [rbp - FD_RTAG]    ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ready
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2
.b_ready:
    ; Check for division by zero (GMP path)
    INT_NEED_MPZ r12
    lea rdi, [r12 + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    jz .gmp_zdiv_error

    call int_alloc_raw
    mov [rbp - FD_NEW], rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyIntObject.compact], 0  ; GMP-backed
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rbp - FD_NEW]
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    INT_NEED_MPZ rbx
    lea rsi, [rbx + PyIntObject.mpz]
    INT_NEED_MPZ r12
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_fdiv_q wrt ..plt
    test r13b, 1
    jz .no_free_a
    mov rdi, rbx
    call int_dealloc
.no_free_a:
    test r13b, 2
    jz .no_free_b
    mov rdi, r12
    call int_dealloc
.no_free_b:
    mov rax, [rbp - FD_NEW]
    mov edx, TAG_PTR
    add rsp, FD_LOCALS
    pop r13
    pop r12
    pop rbx
    pop rbp
    V_PACK rax, rdx             ; return one Value
    ret

.gmp_zdiv_error:
    ; Free temp allocs if any
    test r13b, 1
    jz .gmp_zdiv_na
    mov rdi, rbx
    call int_dealloc
.gmp_zdiv_na:
    test r13b, 2
    jz .gmp_zdiv_nb
    mov rdi, r12
    call int_dealloc
.gmp_zdiv_nb:
    RAISE exc_ZeroDivisionError_type, "integer division or modulo by zero"
END_FUNC int_floordiv

;; ============================================================================
;; int_mod(PyObject *a, PyObject *b) -> rax = Value
;; ============================================================================
MD_RTAG   equ 32            ; the right operand's tag, across a conversion call
MD_NEW    equ 40            ; the result object, across the GMP calls
MD_LOCALS equ 24            ; as int_floordiv above, and for the same reason
DEF_FUNC_BARE int_mod
    call int_binop_unpack       ; rdi/edx = left, rsi/ecx = right, both ints
    test eax, eax
    jnz .operands_ok
    xor eax, eax                ; not both ints: a NULL Value is NotImplemented,
    ret                         ; so the caller tries the other operand's slot
.operands_ok:
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp_path
    cmp ecx, TAG_SMALLINT
    jne .gmp_path

    test rsi, rsi
    jz .mod_zdiv_error
    cmp rsi, -1
    je .mod_neg_one         ; idiv traps on INT64_MIN / -1, and it computes the
                            ; quotient even when only the remainder is wanted
    mov rax, rdi
    mov rcx, rsi
    cqo
    idiv rcx
    mov rax, rdx            ; remainder is in rdx
    ; Python floored mod: if remainder != 0 and has different sign from divisor, adjust
    test rax, rax
    jz .smallint_done
    mov r8, rax
    xor r8, rcx
    jns .smallint_done
    add rax, rcx            ; remainder += divisor
.smallint_done:
    RET_TAG_SMALLINT
    V_PACK rax, rdx             ; return one Value
    ret

.mod_neg_one:
    xor eax, eax            ; a % -1 is 0 for every a
    RET_TAG_SMALLINT
    V_PACK rax, rdx             ; return one Value
    ret

.mod_zdiv_error:
    push rbp
    mov rbp, rsp
    RAISE exc_ZeroDivisionError_type, "integer modulo by zero"

.gmp_path:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, MD_LOCALS
    mov rbx, rdi
    mov r12, rsi
    mov [rbp - MD_RTAG], rcx    ; save right_tag
    cmp edx, TAG_SMALLINT
    jne .a_ready
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1
    jmp .check_b
.a_ready:
    xor r13d, r13d
.check_b:
    mov rcx, [rbp - MD_RTAG]    ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ready
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2
.b_ready:
    ; Check for division by zero (GMP path)
    INT_NEED_MPZ r12
    lea rdi, [r12 + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    jz .gmp_mod_zdiv_error

    call int_alloc_raw
    mov [rbp - MD_NEW], rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyIntObject.compact], 0  ; GMP-backed
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rbp - MD_NEW]
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    INT_NEED_MPZ rbx
    lea rsi, [rbx + PyIntObject.mpz]
    INT_NEED_MPZ r12
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_fdiv_r wrt ..plt
    test r13b, 1
    jz .no_free_a
    mov rdi, rbx
    call int_dealloc
.no_free_a:
    test r13b, 2
    jz .no_free_b
    mov rdi, r12
    call int_dealloc
.no_free_b:
    mov rax, [rbp - MD_NEW]
    mov edx, TAG_PTR
    add rsp, MD_LOCALS
    pop r13
    pop r12
    pop rbx
    pop rbp
    V_PACK rax, rdx             ; return one Value
    ret

.gmp_mod_zdiv_error:
    test r13b, 1
    jz .gmp_mod_zdiv_na
    mov rdi, rbx
    call int_dealloc
.gmp_mod_zdiv_na:
    test r13b, 2
    jz .gmp_mod_zdiv_nb
    mov rdi, r12
    call int_dealloc
.gmp_mod_zdiv_nb:
    RAISE exc_ZeroDivisionError_type, "integer modulo by zero"
END_FUNC int_mod

;; ============================================================================
;; int_pos(rdi = operand Value) -> the operand, unchanged
;; Unary positive: identity for ints.  The slot existed as a zero, which is
;; indistinguishable from "this type has no unary +" -- so +x could not be
;; type-checked without rejecting a heap int too.
;; ============================================================================
DEF_FUNC_BARE int_pos
    mov rax, rdi
    V_TEST_PTR rax, rcx
    ja .ip_immediate
    inc qword [rax + PyObject.ob_refcnt]
.ip_immediate:
    ret
END_FUNC int_pos

;; ============================================================================
;; int_neg(PyObject *a) -> rax = Value
;; ============================================================================
DEF_FUNC_BARE int_neg
    V_UNPACK rdi, rdx           ; operand Value -> (payload, tag)
    cmp edx, TAG_SMALLINT
    je .smallint
    ; Unwrap int subclass
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .smallint

    ; GMP path
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    mov rbx, rdi
    call int_alloc_raw
    mov r12, rax
    mov qword [r12 + PyObject.ob_refcnt], 1
    lea rax, [rel int_type]
    mov [r12 + PyObject.ob_type], rax
    mov qword [r12 + PyIntObject.compact], 0  ; GMP-backed
    INT_NEED_MPZ r12
    lea rdi, [r12 + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    INT_NEED_MPZ r12
    lea rdi, [r12 + PyIntObject.mpz]
    INT_NEED_MPZ rbx
    lea rsi, [rbx + PyIntObject.mpz]
    call __gmpz_neg wrt ..plt
    mov rax, r12
    mov edx, TAG_PTR
    pop r12
    pop rbx
    pop rbp
    V_PACK rax, rdx             ; return one Value
    ret

.smallint:
    mov rax, rdi
    neg rax
    jo .neg_overflow            ; only -(-2^63) overflows
    RET_TAG_SMALLINT
    V_PACK rax, rdx             ; return one Value
    ret
.neg_overflow:
    ; -(-2^63) = 2^63, doesn't fit i64. Create GMP and negate.
    push rbp
    mov rbp, rsp
    push rbx
    call int_from_i64_gmp       ; rdi still has original -2^63
    ; rax = GMP PyIntObject* with value -2^63
    mov rbx, rax
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    mov rsi, rdi
    call __gmpz_neg wrt ..plt   ; negate in place → +2^63
    mov rax, rbx
    mov edx, TAG_PTR
    pop rbx
    pop rbp
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC int_neg

;; ============================================================================
;; int_unwrap(rdi) -> rdi
;; If rdi is a PyIntSubclassObject, extract the int_value.
;; If rdi is a SmallInt or GMP int, leave unchanged.
;; ============================================================================
;; int_is_integer(rdi: payload, edx: tag) -> eax: 1 if this value is an int
;;
;; True for SmallInt, bool, heap PyIntObject (compact or GMP) and int
;; subclasses.  Builtins that used to test `tag == TAG_SMALLINT` need this
;; instead, or they reject every integer that lives on the heap.
;; ============================================================================
DEF_FUNC_BARE int_is_integer
    cmp edx, TAG_SMALLINT
    je .iii_yes
    test edx, TAG_RC_BIT
    jz .iii_no
    test rdi, rdi
    jz .iii_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .iii_yes
    lea rcx, [rel bool_type]
    cmp rax, rcx
    je .iii_yes
    mov rax, [rax + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_INT_SUBCLASS
    jnz .iii_yes
.iii_no:
    xor eax, eax
    ret
.iii_yes:
    mov eax, 1
    ret
END_FUNC int_is_integer

DEF_FUNC_BARE int_unwrap
    ; rdi = payload, edx = tag -> rdi = unwrapped payload, edx = unwrapped tag
    ;
    ; Also flattens a COMPACT heap int to (ival, TAG_SMALLINT).  Nearly every
    ; int operation starts by calling this, so that one line is what lets them
    ; all take their existing int64 fast path for compact operands instead of
    ; forcing a GMP promotion.
.iuw_retry:
    cmp edx, TAG_SMALLINT
    je .iuw_done
    ; Only dereference if TAG_PTR (heap pointer); other tags return unchanged
    test edx, TAG_RC_BIT
    jz .iuw_done                 ; TAG_FLOAT, TAG_NONE, TAG_NULL → not an int
    ; True and False are GMP-backed singletons, so nothing downstream could
    ; take an int64 fast path on them; round(True) reported that bool cannot
    ; be rounded.  Flatten them here, where every int operation passes.
    lea rcx, [rel bool_true]
    cmp rdi, rcx
    je .iuw_true
    lea rcx, [rel bool_false]
    cmp rdi, rcx
    je .iuw_false
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .iuw_exact                ; exact int_type: compact or GMP?
    mov rax, [rax + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_INT_SUBCLASS
    jz .iuw_done                 ; not int subclass
    mov rdi, [rdi + PyIntSubclassObject.int_value]       ; wrapped Value
    V_UNPACK rdi, rdx
    jmp .iuw_retry               ; the wrapped value may itself be a compact int
.iuw_exact:
    cmp qword [rdi + PyIntObject.compact], 0
    je .iuw_done                 ; GMP-backed, edx already TAG_PTR
    mov rdi, [rdi + PyIntObject.ival]
    mov edx, TAG_SMALLINT
.iuw_done:
    ret
.iuw_true:
    mov edi, 1
    mov edx, TAG_SMALLINT
    ret
.iuw_false:
    xor edi, edi
    mov edx, TAG_SMALLINT
    ret
END_FUNC int_unwrap

;; ============================================================================
;; int_binop_unpack(rdi = left Value, rsi = right Value)
;;   -> eax = 1, and rdi/edx = left payload+tag, rsi/ecx = right payload+tag
;;      eax = 0 when either operand is not an integer, in which case the caller
;;              returns a NULL Value -- this tree's NotImplemented.
;;
;; This is CPython's CHECK_BINOP, and it is the only place that decides what
;; int arithmetic accepts.  Every int nb_* binary slot enters through it, so
;; `1 + "a"` can no longer reach INT_NEED_MPZ and write an mpz_t over a foreign
;; object's header.  Both operands come back flattened -- an int subclass is
;; unwrapped and a compact heap int becomes (ival, TAG_SMALLINT) -- so the
;; slots below still take their int64 fast path.
;;
;; Callee-saved only; calls nothing outside this file, so the frame alignment
;; the SysV ABI wants at a libc call does not arise.
;; ============================================================================
DEF_FUNC_BARE int_binop_unpack
    push rbx
    push r12
    push r13
    push r14
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    mov rbx, rdi                ; rbx  = left payload
    mov r12d, edx               ; r12d = left tag
    mov r13, rsi                ; r13  = right payload
    mov r14d, ecx               ; r14d = right tag

    call int_is_integer         ; rdi/edx already hold the left operand
    test eax, eax
    jz .ibu_decline
    mov rdi, r13
    mov edx, r14d
    call int_is_integer
    test eax, eax
    jz .ibu_decline

    mov rdi, rbx                ; flatten subclasses and compact heap ints
    mov edx, r12d
    call int_unwrap
    mov rbx, rdi
    mov r12d, edx
    mov rdi, r13
    mov edx, r14d
    call int_unwrap
    mov rsi, rdi                ; rsi/ecx = unwrapped right
    mov ecx, edx
    mov rdi, rbx                ; rdi/edx = unwrapped left
    mov edx, r12d
    mov eax, 1
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.ibu_decline:
    xor eax, eax
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
END_FUNC int_binop_unpack

;; int_compare(PyObject *a, PyObject *b, int op) -> PyObject*
;; op: PY_LT=0 PY_LE=1 PY_EQ=2 PY_NE=3 PY_GT=4 PY_GE=5
;; ============================================================================
DEF_FUNC int_compare
    V_UNPACK rdi, rcx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, r8            ; right Value -> (payload, tag)
    push rbx
    push r12
    push r13
    push r14

    mov ebx, edx            ; save op
    mov r12, rdi             ; a
    mov r13, rsi             ; b
    mov r14d, r8d            ; r14d = b_tag (right operand tag from caller)

    ; Unwrap int subclass instances
    ; int_unwrap(rdi=payload, edx=tag) -> rdi=unwrapped, edx=tag
    ; For tp_richcompare callers: rcx=right_tag, r8d or edx has left_tag
    ; Since tp_richcompare passes edx=op, we need to determine tags ourselves
    ; The caller (op_compare_op) passes tags in stack/regs before calling tp_richcompare
    ; but tp_richcompare only gets (left, right, op). We detect SmallInt by checking
    ; if value could be a heap pointer (presence of valid ob_type).
    ; Simpler: since nb_ callers pass rdx=left_tag, rcx=right_tag, but tp_richcompare
    ; passes edx=op, we check if edx looks like a tag or a comparison op.
    ; Tags: 0,1,2,3,4,0x105. Ops: 0-5. Overlap at 0-4!
    ; So we can't distinguish. Instead, just check ob_type validity for heap pointers.

    ; Strategy: try to detect SmallInt by checking if pointer dereference would be valid.
    ; Since caller already handles both-SmallInt, at least one is a real pointer.
    ; We use a different approach: check if the value is in a plausible heap range.
    ; Actually, the simplest: the caller's compare_op fast path catches both-SmallInt.
    ; For int_compare, we can just assume at least one is a heap int. We need to handle
    ; int subclass unwrapping and SmallInt-to-GMP conversion.

    ; Check a: is it a heap pointer? (ob_type at +8 would be a valid pointer)
    ; For SmallInt raw values (arbitrary int64), accessing [rdi+8] would segfault
    ; on most values. We need a reliable way to detect.
    ; Use: the caller passes rdx=left_tag for nb_ calls, but edx=op for tp_richcompare.
    ; Since we saved ebx=edx, we lost the distinction.
    ;
    ; NEW APPROACH: Check if ob_type points to int_type or its subclass
    ; This only works for heap pointers. For SmallInt payloads, we'd crash.
    ; Since the caller already eliminated both-SmallInt, at least one is heap.
    ; We can't know WHICH one is SmallInt without tags.
    ;
    ; SAFE APPROACH: Make tp_richcompare callers pass tags.
    ; For now: assume the compare_op caller already handles both-SmallInt,
    ; so both args are heap pointers (TAG_PTR). Skip int_unwrap tag check.
    ; int_unwrap with edx=TAG_PTR will do type checking and unwrap subclasses.

    ; Unwrap a
    mov rdi, r12
    mov edx, ecx                 ; left_tag from caller
    call int_unwrap
    mov r12, rdi                 ; unwrapped a
    mov eax, edx                 ; a_tag after unwrap

    ; Unwrap b
    push rax                     ; save a_tag
    mov rdi, r13
    mov edx, r14d                ; right_tag from caller
    call int_unwrap
    mov r13, rdi                 ; unwrapped b
    ; edx = b_tag after unwrap
    pop rax                      ; rax = a_tag

    ; Validate both operands are actually ints (TAG_SMALLINT or TAG_PTR with int_type/bool_type)
    ; If either is not an int, return NULL (NotImplemented)
    extern bool_type
    cmp eax, TAG_SMALLINT
    je .a_valid
    cmp eax, TAG_PTR
    jne .ret_notimpl             ; a is not int (e.g., str, float obj, etc.)
    mov rcx, [r12 + PyObject.ob_type]
    lea r8, [rel int_type]
    cmp rcx, r8
    je .a_valid
    lea r8, [rel bool_type]
    cmp rcx, r8
    jne .ret_notimpl             ; a is TAG_PTR but not int_type or bool_type
.a_valid:
    cmp edx, TAG_SMALLINT
    je .b_valid
    cmp edx, TAG_PTR
    jne .ret_notimpl             ; b is not int
    mov rcx, [r13 + PyObject.ob_type]
    lea r8, [rel int_type]
    cmp rcx, r8
    je .b_valid
    lea r8, [rel bool_type]
    cmp rcx, r8
    jne .ret_notimpl             ; b is TAG_PTR but not int_type or bool_type
.b_valid:

    ; Check if both SmallInt (could happen after unwrapping int subclasses)
    cmp eax, TAG_SMALLINT
    jne .a_not_smallint
    cmp edx, TAG_SMALLINT
    je .both_smallint
.a_not_smallint:

    ; At least one is GMP - use __gmpz_cmp_si to avoid heap allocation
    cmp eax, TAG_SMALLINT
    jne .a_is_gmp
    ; a is SmallInt, b is GMP: cmp_si(b->mpz, a) then negate
    INT_NEED_MPZ r13
    lea rdi, [r13 + PyIntObject.mpz]
    mov rsi, r12               ; SmallInt raw value
    call __gmpz_cmp_si wrt ..plt
    neg eax                    ; negate: cmp_si(b,a) → want cmp(a,b)
    mov r12d, eax
    jmp .dispatch_op
.a_is_gmp:
    cmp edx, TAG_SMALLINT
    jne .both_gmp
    ; a is GMP, b is SmallInt: cmp_si(a->mpz, b)
    INT_NEED_MPZ r12
    lea rdi, [r12 + PyIntObject.mpz]
    mov rsi, r13               ; SmallInt raw value
    call __gmpz_cmp_si wrt ..plt
    mov r12d, eax
    jmp .dispatch_op
.both_gmp:
    INT_NEED_MPZ r12
    lea rdi, [r12 + PyIntObject.mpz]
    INT_NEED_MPZ r13
    lea rsi, [r13 + PyIntObject.mpz]
    call __gmpz_cmp wrt ..plt
    mov r12d, eax
    jmp .dispatch_op

.both_smallint:
    ; Compare SmallInt payloads directly
    mov rax, r12
    mov rcx, r13
    cmp rax, rcx
    ; Set r12d to cmp-style result: -1, 0, or 1
    mov r12d, 0                         ; lint: flags -- xor would clobber the compare
    jz .dispatch_op
    mov r12d, -1
    jl .dispatch_op
    mov r12d, 1

.dispatch_op:
    cmp ebx, PY_LT
    je .do_lt
    cmp ebx, PY_LE
    je .do_le
    cmp ebx, PY_EQ
    je .do_eq
    cmp ebx, PY_NE
    je .do_ne
    cmp ebx, PY_GT
    je .do_gt
    jmp .do_ge

.do_lt:
    test r12d, r12d
    js .ret_true
    jmp .ret_false
.do_le:
    test r12d, r12d
    jle .ret_true
    jmp .ret_false
.do_eq:
    test r12d, r12d
    jz .ret_true
    jmp .ret_false
.do_ne:
    test r12d, r12d
    jnz .ret_true
    jmp .ret_false
.do_gt:
    test r12d, r12d
    jg .ret_true
    jmp .ret_false
.do_ge:
    test r12d, r12d
    jge .ret_true
    jmp .ret_false

.ret_notimpl:
    ; Operand is not an int — return NULL (NotImplemented)
    RET_NULL
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ret_true:
    RET_TRUE
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.ret_false:
    RET_FALSE
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC int_compare

;; ============================================================================
;; int_dealloc(PyObject *self)
;; Free GMP data + object. SmallInt guard.
;; ============================================================================
DEF_FUNC_BARE int_dealloc
    ; tp_dealloc(rdi=obj) — edx is NOT passed, so no tag check.
    ; SmallInts never reach here (no TAG_RC_BIT, so DECREF_VAL skips them).
    push rbp
    mov rbp, rsp
    push rbx
    mov rbx, rdi
    cmp qword [rbx + PyIntObject.compact], 0
    jne .compact                ; no mpz was ever initialized
    lea rdi, [rbx + PyIntObject.mpz]
    ; `push rbp` and `push rbx` above leave rsp eight out, and this is a call
    ; into libc.  DEF_FUNC_BARE is exempt from lint's alignment check -- it
    ; has no frame for lint to reason about -- so a hand-rolled prologue like
    ; this one has to get its own parity right.  Measured: 290 of 290 calls
    ; here were misaligned on a bignum workload.
    sub rsp, 8
    call __gmpz_clear wrt ..plt
    add rsp, 8
.compact:
%ifndef NO_INT_FREELIST
    ; Back to the free list rather than to libc.  The mpz has been cleared
    ; above when there was one, so the block is as raw as a fresh malloc.
    mov rax, [rel int_freelist_count]
    cmp rax, INT_FREELIST_MAX
    jae .really_free
    mov rcx, [rel int_freelist]
    mov [rbx + PyObject.ob_refcnt], rcx     ; the dead refcount is the link
    mov [rel int_freelist], rbx
    inc qword [rel int_freelist_count]
    pop rbx
    pop rbp
    ret
.really_free:
%endif
    mov rdi, rbx
    call ap_free
    pop rbx
    pop rbp
    ret
END_FUNC int_dealloc

;; ============================================================================
;; Bitwise AND: int_and(PyObject *a, PyObject *b) -> rax = Value
;; ============================================================================
DEF_FUNC_BARE int_and
    call int_binop_unpack       ; rdi/edx = left, rsi/ecx = right, both ints
    test eax, eax
    jnz .operands_ok
    xor eax, eax                ; not both ints: a NULL Value is NotImplemented,
    ret                         ; so the caller tries the other operand's slot
.operands_ok:
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp
    cmp ecx, TAG_SMALLINT
    jne .gmp

    ; Both SmallInt
    mov rax, rdi
    and rax, rsi           ; AND preserves tag bit, result is valid SmallInt
    RET_TAG_SMALLINT
    V_PACK rax, rdx             ; return one Value
    ret

.gmp:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    push rcx                ; save right_tag
    cmp edx, TAG_SMALLINT
    jne .a_ok
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1
    jmp .chk_b
.a_ok:
    xor r13d, r13d
.chk_b:
    pop rcx                 ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ok
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2
.b_ok:
    call int_alloc_raw
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyIntObject.compact], 0  ; GMP-backed
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    INT_NEED_MPZ rbx
    lea rsi, [rbx + PyIntObject.mpz]
    INT_NEED_MPZ r12
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_and wrt ..plt
    test r13b, 1
    jz .na
    mov rdi, rbx
    call int_dealloc
.na:
    test r13b, 2
    jz .nb
    mov rdi, r12
    call int_dealloc
.nb:
    pop rax
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    pop rbp
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC int_and

;; ============================================================================
;; Bitwise OR: int_or(PyObject *a, PyObject *b) -> rax = Value
;; ============================================================================
DEF_FUNC_BARE int_or
    call int_binop_unpack       ; rdi/edx = left, rsi/ecx = right, both ints
    test eax, eax
    jnz .operands_ok
    xor eax, eax                ; not both ints: a NULL Value is NotImplemented,
    ret                         ; so the caller tries the other operand's slot
.operands_ok:
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp
    cmp ecx, TAG_SMALLINT
    jne .gmp

    ; Both SmallInt
    mov rax, rdi
    or rax, rsi            ; OR preserves tag bit
    RET_TAG_SMALLINT
    V_PACK rax, rdx             ; return one Value
    ret

.gmp:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    push rcx                ; save right_tag
    cmp edx, TAG_SMALLINT
    jne .a_ok
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1
    jmp .chk_b
.a_ok:
    xor r13d, r13d
.chk_b:
    pop rcx                 ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ok
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2
.b_ok:
    call int_alloc_raw
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyIntObject.compact], 0  ; GMP-backed
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    INT_NEED_MPZ rbx
    lea rsi, [rbx + PyIntObject.mpz]
    INT_NEED_MPZ r12
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_ior wrt ..plt
    test r13b, 1
    jz .na
    mov rdi, rbx
    call int_dealloc
.na:
    test r13b, 2
    jz .nb
    mov rdi, r12
    call int_dealloc
.nb:
    pop rax
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    pop rbp
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC int_or

;; ============================================================================
;; Bitwise XOR: int_xor(PyObject *a, PyObject *b) -> rax = Value
;; ============================================================================
DEF_FUNC_BARE int_xor
    call int_binop_unpack       ; rdi/edx = left, rsi/ecx = right, both ints
    test eax, eax
    jnz .operands_ok
    xor eax, eax                ; not both ints: a NULL Value is NotImplemented,
    ret                         ; so the caller tries the other operand's slot
.operands_ok:
    ; Check both SmallInt
    cmp edx, TAG_SMALLINT
    jne .gmp
    cmp ecx, TAG_SMALLINT
    jne .gmp

    ; Both SmallInt: XOR values, must re-set tag bit
    mov rax, rdi
    mov rcx, rsi
    xor rax, rcx
    RET_TAG_SMALLINT
    V_PACK rax, rdx             ; return one Value
    ret

.gmp:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    push rcx                ; save right_tag
    cmp edx, TAG_SMALLINT
    jne .a_ok
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov r13b, 1
    jmp .chk_b
.a_ok:
    xor r13d, r13d
.chk_b:
    pop rcx                 ; restore right_tag
    cmp ecx, TAG_SMALLINT
    jne .b_ok
    mov rdi, r12
    call smallint_to_pyint
    mov r12, rax
    or r13b, 2
.b_ok:
    call int_alloc_raw
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyIntObject.compact], 0  ; GMP-backed
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    INT_NEED_MPZ rbx
    lea rsi, [rbx + PyIntObject.mpz]
    INT_NEED_MPZ r12
    lea rdx, [r12 + PyIntObject.mpz]
    call __gmpz_xor wrt ..plt
    test r13b, 1
    jz .na
    mov rdi, rbx
    call int_dealloc
.na:
    test r13b, 2
    jz .nb
    mov rdi, r12
    call int_dealloc
.nb:
    pop rax
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    pop rbp
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC int_xor

;; ============================================================================
;; Bitwise NOT: int_invert(PyObject *a, PyObject *b_unused) -> rax = Value
;; ~x = -(x+1)
;; ============================================================================
DEF_FUNC_BARE int_invert
    V_UNPACK rdi, rdx           ; operand Value -> (payload, tag)
    ; Unwrap int subclass instances
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .smallint

    ; GMP path
    push rbp
    mov rbp, rsp
    push rbx
    mov rbx, rdi
    call int_alloc_raw
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyIntObject.compact], 0  ; GMP-backed
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    INT_NEED_MPZ rbx
    lea rsi, [rbx + PyIntObject.mpz]
    call __gmpz_com wrt ..plt
    pop rax
    mov edx, TAG_PTR
    pop rbx
    pop rbp
    V_PACK rax, rdx             ; return one Value
    ret

.smallint:
    mov rax, rdi
    not rax                ; ~x = -(x+1), always fits i64
    RET_TAG_SMALLINT
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC int_invert


;; ============================================================================
;; int_shrink(PyIntObject *v) -> rax = Value
;;
;; A heap integer whose value fits the immediate range must not stay on the
;; heap.  There is no small-int cache here: an integer in +-2^50 IS its Value,
;; so `x is 1` compares words, and a boxed 1 is not the 1 every other operation
;; produces.  The operators that always compute through GMP -- shift and power
;; -- hand their result through this on the way out.
;;
;; A value too wide for an immediate but inside an int64 becomes COMPACT here,
;; and that is the second half of the job.  int_binop_unpack flattens a compact
;; heap int into an immediate and can do nothing with an mpz-backed one, so a
;; value that stayed mpz-backed dragged every later operation on it back into
;; GMP: marshal built 1 << 60 as a bignum, and `s += x + i` then paid an
;; __gmpz_init, an __gmpz_add and an __gmpz_clear per iteration for a number
;; that fits in a register.  The __gmpz_clear is not a new cost -- the object's
;; dealloc would have paid it either way.
;; ============================================================================
IS_VAL   equ 8                    ; the int64 across int_dealloc
IS_FRAME equ 8
DEF_FUNC int_shrink, IS_FRAME     ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    cmp qword [rbx + PyIntObject.compact], 0
    jne .from_compact
    lea rdi, [rbx + PyIntObject.mpz]
    call __gmpz_fits_slong_p wrt ..plt
    test eax, eax
    jz .keep
    lea rdi, [rbx + PyIntObject.mpz]
    call __gmpz_get_si wrt ..plt
    jmp .have
.from_compact:
    mov rax, [rbx + PyIntObject.ival]
.have:
    ; Still mpz-backed but inside an int64: collapse it.
    cmp qword [rbx + PyIntObject.compact], 0
    jne .have_compact
    push rax
    push rax                    ; two pushes: rsp keeps its alignment
    lea rdi, [rbx + PyIntObject.mpz]
    call __gmpz_clear wrt ..plt
    pop rax
    pop rax
    mov [rbx + PyIntObject.ival], rax
    mov qword [rbx + PyIntObject.compact], 1
.have_compact:

    ; |v| < the immediate limit.  The stress build lowers that limit to force
    ; the heap paths, and this has to move with it or the two disagree about
    ; which integers are immediates.
%ifdef INT_STRESS_BOX
    mov rdx, INT_STRESS_BOX
%else
    mov rdx, 1 << V_INT_SHIFT
%endif
    mov rcx, rax
    mov r8, rax
    sar r8, 63
    xor rcx, r8
    sub rcx, r8
    cmp rcx, rdx
    jae .keep
    ; Kept in the frame, not pushed: a lone push here entered int_dealloc
    ; with rsp misaligned.
    mov [rbp - IS_VAL], rax
    mov rdi, rbx
    call int_dealloc
    mov rax, [rbp - IS_VAL]
    V_PACK_I64 rax, rcx
    pop rbx
    leave
    ret
.keep:
    mov rax, rbx
    pop rbx
    leave
    ret
END_FUNC int_shrink

;; ============================================================================
;; Left shift: int_lshift(PyObject *a, PyObject *b) -> rax = Value
;; ============================================================================
DEF_FUNC int_lshift
    ; The check runs before the callee-saved pushes, so the decline path is a
    ; bare leave/ret with no push mirror to unwind.
    call int_binop_unpack       ; rdi/edx = left, rsi/ecx = right, both ints
    test eax, eax
    jnz .operands_ok
    xor eax, eax                ; NULL Value = NotImplemented
    leave
    ret
.operands_ok:
    push rbx
    push r12
    push r13
    push r14

    mov r14d, edx           ; r14d = left_tag; ecx is already right_tag

    mov rbx, rdi           ; left operand
    mov r12, rsi           ; right operand (shift amount)

    ; Get shift amount as int64
    cmp ecx, TAG_SMALLINT
    je .shift_smallint
    ; GMP right operand: get as int64.  __gmpz_get_si TRUNCATES, so a shift
    ; count that does not fit answered the left operand unchanged; CPython
    ; refuses it.
    INT_NEED_MPZ r12
    ; Four pushes leave rsp aligned; a push/pop of rdi around this call would
    ; flip it, so the argument is recomputed from r12 instead.
    lea rdi, [r12 + PyIntObject.mpz]
    extern __gmpz_fits_slong_p
    call __gmpz_fits_slong_p wrt ..plt
    test eax, eax
    jz .shift_too_wide
    lea rdi, [r12 + PyIntObject.mpz]
    call __gmpz_get_si wrt ..plt
    mov r13, rax
    jmp .have_shift
.shift_smallint:
    mov r13, r12

.have_shift:
    ; r13 = shift amount
    test r13, r13
    js .neg_shift

    ; An int64 shift, when the result provably still fits one.  Without this
    ; `1 << 3` cost two ap_mallocs (a temporary for the left operand and the
    ; result), two __gmpz_inits, a __gmpz_mul_2exp and an int_shrink that then
    ; asked GMP whether the answer fit a long after all.  int_rshift has had
    ; its `sar` arm all along; this is the other half.
    ;
    ; The overflow test is the standard one: shift left, shift arithmetically
    ; back, and compare.  Bits that fell off the top do not come back, so a
    ; mismatch is exactly "this needed more than 64 bits".  It is correct for a
    ; negative left operand too, which is why the shift back is `sar` and not
    ; `shr`.  A count of 64 or more cannot be reasoned about this way -- `shl`
    ; masks it to 6 bits -- so it goes to GMP.
    cmp r14d, TAG_SMALLINT
    jne .lshift_wide
    cmp r13, 63
    jae .lshift_wide
    mov rax, rbx
    mov rcx, r13
    mov rdx, rax
    shl rdx, cl
    mov rsi, rdx
    sar rsi, cl
    cmp rsi, rax
    jne .lshift_wide       ; bits were lost: GMP has to do it
    mov rax, rdx
    RET_TAG_SMALLINT
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.lshift_wide:
    ; Convert left to GMP if needed
    xor ecx, ecx           ; flag: converted
    cmp r14d, TAG_SMALLINT
    jne .a_gmp
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov cl, 1
.a_gmp:
    push rcx
    call int_alloc_raw
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyIntObject.compact], 0  ; GMP-backed
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    INT_NEED_MPZ rbx
    lea rsi, [rbx + PyIntObject.mpz]
    mov rdx, r13           ; shift count
    call __gmpz_mul_2exp wrt ..plt
    pop rax
    pop rcx
    test cl, cl
    jz .lsh_done
    ; The result rides in r12 (the shift operand, dead by now), not on the
    ; stack: a lone push here entered int_dealloc misaligned, and its
    ; __gmpz_clear inherited the bad parity.
    mov r12, rax
    mov rdi, rbx
    call int_dealloc
    mov rax, r12
.lsh_done:
    mov rdi, rax
    call int_shrink
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.neg_shift:
    RAISE exc_ValueError_type, "negative shift count"
.shift_too_wide:
    extern exc_OverflowError_type
    RAISE exc_OverflowError_type, "too many digits in integer"

END_FUNC int_lshift

;; ============================================================================
;; Right shift: int_rshift(PyObject *a, PyObject *b) -> rax = Value
;; ============================================================================
RS_NEW   equ 8              ; the result object, across the two GMP calls
RS_MPZ   equ 16             ; the shift count's mpz, across __gmpz_fits_slong_p
RS_FRAME equ 16             ; + 4 pushes = 48, 16-aligned.  Both slots were
                            ; a `push` before, and each left the GMP call it
                            ; spanned eight bytes out.
DEF_FUNC int_rshift, RS_FRAME
    call int_binop_unpack       ; rdi/edx = left, rsi/ecx = right, both ints
    test eax, eax
    jnz .operands_ok
    xor eax, eax                ; NULL Value = NotImplemented
    leave
    ret
.operands_ok:
    push rbx
    push r12
    push r13
    push r14

    mov r14d, edx           ; r14d = left_tag; ecx is already right_tag

    mov rbx, rdi
    mov r12, rsi

    ; Get shift amount
    cmp ecx, TAG_SMALLINT
    je .shift_smallint
    ; __gmpz_get_si TRUNCATES, so a shift count that does not fit answered
    ; the left operand unchanged.  For a RIGHT shift CPython does not
    ; refuse it: everything has been shifted out, so the answer is 0 or -1
    ; by the sign.
    INT_NEED_MPZ r12
    lea rdi, [r12 + PyIntObject.mpz]
    mov [rbp - RS_MPZ], rdi
    extern __gmpz_fits_slong_p
    call __gmpz_fits_slong_p wrt ..plt
    mov rdi, [rbp - RS_MPZ]
    test eax, eax
    jz .rshift_all_out
    call __gmpz_get_si wrt ..plt
    mov r13, rax
    jmp .have_shift
.shift_smallint:
    mov r13, r12

.have_shift:
    test r13, r13
    js .neg_shift

    ; SmallInt fast path
    cmp r14d, TAG_SMALLINT
    jne .gmp_path
    mov rax, rbx
    ; Arithmetic right shift
    mov rcx, r13
    cmp rcx, 63
    jge .max_shift
    sar rax, cl
    RET_TAG_SMALLINT
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
.max_shift:
    ; Shift >= 63: result is 0 or -1 depending on sign
    sar rax, 63
    RET_TAG_SMALLINT
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.gmp_path:
    call int_alloc_raw
    mov [rbp - RS_NEW], rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyIntObject.compact], 0  ; GMP-backed
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rbp - RS_NEW]
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    INT_NEED_MPZ rbx
    lea rsi, [rbx + PyIntObject.mpz]
    mov rdx, r13
    call __gmpz_fdiv_q_2exp wrt ..plt
    mov rdi, [rbp - RS_NEW]
    call int_shrink
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.neg_shift:
    RAISE exc_ValueError_type, "negative shift count"
.rshift_all_out:
    ; A shift wider than any integer: the sign is all that survives.  The
    ; count itself may be negative, and that is still a ValueError.
    lea rdi, [r12 + PyIntObject.mpz]
    xor esi, esi
    extern __gmpz_cmp_si
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    js .neg_shift
    mov r13, 0x7FFFFFFFFFFFFFFF
    jmp .have_shift

END_FUNC int_rshift

;; ============================================================================
;; Power: int_power(PyObject *a, PyObject *b) -> rax = Value
;; For small positive exponents, use GMP mpz_pow_ui
;; ============================================================================
IPW_ETAG  equ 8             ; the exponent's tag, across the GMP calls
IPW_BASED equ 16            ; the base as a double, likewise
IPW_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
; The widest result int_power will build: 2^34 bits is two gigabytes of digits,
; far past anything a program means to compute and far short of the size GMP
; aborts on.
IPW_MAX_BITS equ 1 << 34
DEF_FUNC int_power, IPW_FRAME
    call int_binop_unpack       ; rdi/edx = base, rsi/ecx = exponent, both ints
    test eax, eax
    jnz .operands_ok
    xor eax, eax                ; NULL Value = NotImplemented
    leave
    ret
.operands_ok:
    push rbx
    push r12
    push r13
    push r14

    mov r14d, edx           ; r14d = base_tag
    mov [rbp - IPW_ETAG], ecx   ; the exponent's tag, which the GMP calls
                                ; below clobber and .neg_exp still needs

    mov rbx, rdi           ; rbx = base
    mov r12, rsi           ; r12 = exponent

    ; The exponent's SIGN first, and from the value rather than from a
    ; truncated copy of it: mpz_get_si is undefined past int64, so the sign
    ; of 10**20 read back through it is whatever the low bits say.
    cmp ecx, TAG_SMALLINT
    je .exp_smallint
    INT_NEED_MPZ r12
    lea rdi, [r12 + PyIntObject.mpz]
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    js .neg_exp
    lea rdi, [r12 + PyIntObject.mpz]
    call __gmpz_get_si wrt ..plt
    mov r13, rax
    jmp .have_exp
.exp_smallint:
    mov r13, r12

.have_exp:
    ; Negative exponent: return float (int ** -n = 1/int**n)
    test r13, r13
    js .neg_exp

    ; Repeated squaring in int64, while it fits.  Without this `i ** 2` cost
    ; two ap_mallocs, two __gmpz_inits, a __gmpz_pow_ui and an int_shrink --
    ; malloc and free were 32% of an `i ** 2` loop.
    ;
    ; Every imul is checked, and a bail lands in the GMP path below with the
    ; base and exponent untouched in rbx/r13, so nothing has to be undone.
    ; The base is squared only when another bit remains, so an overflow in the
    ; final squaring -- whose value would never have been used -- cannot send a
    ; result that fitted to GMP.
    cmp r14d, TAG_SMALLINT
    jne .pow_wide
    cmp r13, 64
    jae .pow_wide          ; any base but 0 and +-1 overflows well before this,
                           ; and GMP settles those three quickly
    mov eax, 1                      ; result
    mov rsi, rbx           ; b, the running square
    mov rdi, r13           ; e, the remaining exponent
.pow_loop:
    test rdi, rdi
    jz .pow_fits
    test dil, 1
    jz .pow_square
    imul rax, rsi
    jo .pow_wide
.pow_square:
    shr rdi, 1
    jz .pow_fits
    imul rsi, rsi
    jo .pow_wide
    jmp .pow_loop
.pow_fits:
    RET_TAG_SMALLINT
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.pow_wide:
    ; Convert base to GMP if needed
    ; r14d = base_tag from int_unwrap
    xor ecx, ecx
    cmp r14d, TAG_SMALLINT
    jne .base_gmp
    mov rdi, rbx
    call smallint_to_pyint
    mov rbx, rax
    mov cl, 1
.base_gmp:
    ; Refuse a result too wide to build, BEFORE asking GMP to build it.
    ; __gmpz_pow_ui reaches __gmp_overflow_in_mpz on a size it cannot
    ; represent, and that raises SIGFPE and kills the process -- there is no
    ; error return to check afterwards.  `Decimal(10**19).sqrt()` at
    ; decimal's MAX_PREC asks for one, which is how test_decimal took the
    ; whole sweep down with it.
    ;
    ; CPython reaches MemoryError by failing the allocation; this reaches the
    ; same answer without trying, since the width is known from the base's
    ; and the exponent's.
    push rcx
    push rcx                            ; twice: one push flips the parity
    INT_NEED_MPZ rbx
    lea rdi, [rbx + PyIntObject.mpz]
    mov esi, 2
    call __gmpz_sizeinbase wrt ..plt    ; the base's width in bits
    pop rcx
    pop rcx
    ; 0, 1 and -1 answer in one bit however large the exponent is, and every
    ; other base needs at least two -- so this one compare is the whole
    ; special case, and `1 ** 10**19` stays 1 rather than becoming a refusal.
    cmp rax, 1
    jbe .pow_size_ok
    mul r13                             ; rdx:rax = bits * exponent
    test rdx, rdx
    jnz .pow_too_big
    ; Through a register: a 64-bit immediate does not fit in a cmp, and NASM
    ; truncates rather than refusing, so `cmp rax, 1 << 34` compared against
    ; zero and refused 2 ** 64.
    mov rdx, IPW_MAX_BITS
    cmp rax, rdx
    ja .pow_too_big
.pow_size_ok:

    push rcx
    call int_alloc_raw
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel int_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyIntObject.compact], 0  ; GMP-backed
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    call __gmpz_init wrt ..plt
    mov rax, [rsp]
    INT_NEED_MPZ rax
    lea rdi, [rax + PyIntObject.mpz]
    INT_NEED_MPZ rbx
    lea rsi, [rbx + PyIntObject.mpz]
    mov rdx, r13           ; exponent (unsigned)
    call __gmpz_pow_ui wrt ..plt
    pop rax
    pop rcx
    test cl, cl
    jz .pow_done
    push rax
    sub rsp, 8              ; the lone push above flips the parity, and
                            ;   int_dealloc reaches __gmpz_clear
    mov rdi, rbx
    call int_dealloc
    add rsp, 8
    pop rax
.pow_done:
    mov rdi, rax
    call int_shrink
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.pow_too_big:
    test cl, cl
    jz .ptb_raise
    mov rdi, rbx                        ; the base this path converted
    call int_dealloc
.ptb_raise:
    pop r14
    pop r13
    pop r12
    pop rbx
    extern exc_MemoryError_type
    RAISE exc_MemoryError_type, "integer result too large to represent"

.neg_exp:
    ; int ** negative -> float.  This used to compute 1.0 / base**|exp| with
    ; a LINEAR loop -- one multiply per unit of the exponent -- so
    ; 0 ** -10**20 ran 10**20 iterations and never came back, and it divided
    ; by the 0.0 it had just built rather than raising ZeroDivisionError.
    ; It also overflowed on the way: 2 ** -1074 is 5e-324, and base**1074 is
    ; an infinity, so the reciprocal came out 0.0.
    ;
    ; float_pow answers all of it, and is the only place the IEEE corners are
    ; written down.
    ;
    ; Both operands become doubles through float_to_f64, which is where the
    ; CORRECT conversion lives: it renders the integer to a decimal string and
    ; lets strtod round it to nearest even, as CPython's PyLong_AsDouble does.
    ; This path used GMP's mpz_get_d, which TRUNCATES toward zero, so an
    ; integer sitting between two doubles picked the lower neighbour and the
    ; reciprocal of the wrong neighbour is a different float: (10**30) ** -1
    ; answered 1e-30 where CPython says 9.999999999999999e-31.  float_to_f64
    ; also handles an exponent past int64 without the magnitude and sign
    ; damage mpz_get_si would do.
    mov rdi, rbx
    mov esi, r14d
    extern float_to_f64
    call float_to_f64
    movsd [rbp - IPW_BASED], xmm0
    ; The exponent, as the object rather than the int64 r13 holds when it fit.
    mov rdi, r12
    mov esi, dword [rbp - IPW_ETAG]
    call float_to_f64
    movq rsi, xmm0
    V_FROM_F64 rsi, rax
    mov rdi, [rbp - IPW_BASED]
    V_FROM_F64 rdi, rax
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    extern float_pow
    jmp float_pow
END_FUNC int_power


;; ============================================================================
;; int_getattr(rdi = self Value, rsi = name str) -> rax = Value, or NULL
;;
;; real, imag, numerator and denominator.  numbers.py and fractions.py reach
;; for all four on a plain int, and every one of them was an AttributeError:
;; only bool and complex had this chain, so `(5).real` raised while
;; `True.real` did not.
;;
;; Not a getset descriptor -- getset_descr_new is a stub whose accessors are
;; NULL and which nothing in the tree invokes.  bool_getattr and
;; complex_getattr do exactly this, for exactly these names.  Returning NULL
;; rather than raising is what lets bit_length() and __eq__ coexist with it:
;; op_load_attr falls through to the MRO's tp_dicts.
;;
;; The argument is a Value, so all three shapes of int arrive here -- an
;; immediate, a heap int and a subclass instance -- and .real has to hand
;; back a plain int for the last of them, as CPython does.
;; ============================================================================
IG_SELF   equ 8
IG_NAME   equ 16
IG_FRAME  equ 16            ; + 0 pushes = 16

extern ap_strcmp
DEF_FUNC int_getattr, IG_FRAME
    mov [rbp - IG_SELF], rdi
    mov [rbp - IG_NAME], rsi

    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "real"
    call ap_strcmp
    test eax, eax
    jz .ig_self_value

    mov rdi, [rbp - IG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "numerator"
    call ap_strcmp
    test eax, eax
    jz .ig_self_value

    mov rdi, [rbp - IG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "imag"
    call ap_strcmp
    test eax, eax
    jz .ig_zero

    mov rdi, [rbp - IG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "denominator"
    call ap_strcmp
    test eax, eax
    jz .ig_one

    RET_NULL
    leave
    V_PACK rax, rdx
    ret

.ig_self_value:
    mov rdi, [rbp - IG_SELF]
    call int_get_real
    leave
    ret

.ig_zero:
    mov rdi, [rbp - IG_SELF]
    call int_get_imag
    leave
    ret

.ig_one:
    mov rdi, [rbp - IG_SELF]
    call int_get_denominator
    leave
    ret
END_FUNC int_getattr

;; ============================================================================
;; int_get_real(rdi = self Value) -> rax = Value
;;
;; The getter behind int.real and int.numerator, reached both from the
;; tp_getattr chain above and from the getset descriptor in int_type.tp_dict.
;; An exact int answers with itself; a subclass answers with its value, so
;; that type(I(5).real) is int.
;; ============================================================================
DEF_FUNC int_get_real
    V_TEST_PTR rdi, rax
    ja .ig_self_out             ; an immediate is already a plain int
    ; Compare the TYPE, not the family flag: int_type carries
    ; TYPE_FLAG_INT_SUBCLASS itself, so that a subclass inherits it, and an
    ; exact heap int took the unwrapping path below.  int_unwrap reduced it
    ; to a SmallInt payload and V_PACK boxed it again -- a fresh object, so
    ; `v.real is v` was False for any v outside +-2^50, and the extra
    ; reference on top of that leaked one int per read.
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .ig_self_out
    ; Anything else -- a bool, an int subclass instance -- unwraps to the
    ; plain int it holds.  True.__abs__() and True.__index__() are 1 in
    ; CPython, not True; True.real goes through bool_getattr and never gets
    ; here.  int_unwrap leaves a non-int alone, so the fallthrough is safe.
    mov edx, TAG_PTR
    call int_unwrap             ; rdi/edx = the plain int it wraps
    cmp edx, TAG_PTR
    jne .ig_wrapped_immediate
    ; A pointer here is BORROWED from the wrapper, and V_PACK does nothing to
    ; it: handing it back without a reference of its own underflows the
    ; refcount, which shows up as a crash at teardown rather than at the read.
    mov rax, rdi
    INCREF_V rax, rcx
    leave
    ret
.ig_wrapped_immediate:
    V_PACK rdi, rdx             ; an immediate, or a box V_PACK now owns
    mov rax, rdi
    leave
    ret
.ig_self_out:
    mov rax, rdi
    INCREF_V rax, rcx
    leave
    ret
END_FUNC int_get_real

;; ============================================================================
;; int_get_imag(rdi = self Value) -> rax = Value.  Always 0.
;; ============================================================================
DEF_FUNC int_get_imag
    xor eax, eax
    V_PACK_I64 rax, rcx
    leave
    ret
END_FUNC int_get_imag

;; ============================================================================
;; int_get_denominator(rdi = self Value) -> rax = Value.  Always 1.
;; ============================================================================
DEF_FUNC int_get_denominator
    mov rax, V_INT(1)
    leave
    ret
END_FUNC int_get_denominator

;; ============================================================================
;; int_abs(rdi = operand Value) -> rax = Value
;;
;; nb_absolute, which int did not have: abs() reached int through
;; builtin_abs's own inline path, so the slot -- and `(-5).__abs__()` with it
;; -- was simply absent.
;; ============================================================================
DEF_FUNC int_abs, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi                ; the operand, as it arrived
    V_UNPACK rdi, rdx
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .iabs_small
    cmp qword [rdi + PyIntObject.compact], 0
    jne .iabs_compact
    lea rdi, [rdi + PyIntObject.mpz]
    xor esi, esi
    extern __gmpz_cmp_si
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    js .iabs_negate
    jmp .iabs_same
.iabs_compact:
    mov rax, [rdi + PyIntObject.ival]
    test rax, rax
    js .iabs_negate
    jmp .iabs_same
.iabs_small:
    test rdi, rdi
    js .iabs_negate
.iabs_same:
    ; The unwrapped value, not the operand: abs() of a bool or of an int
    ; subclass instance is a plain int, as CPython has it.
    mov rdi, rbx
    call int_get_real
    pop rbx
    leave
    ret
.iabs_negate:
    mov rdi, rbx
    call int_neg
    pop rbx
    leave
    ret
END_FUNC int_abs

;; ============================================================================
;; int_float(rdi = operand Value) -> rax = a float Value
;; nb_float: what float(n) and n.__float__() both want.
;; ============================================================================
DEF_FUNC int_float
    V_UNPACK rdi, rsi
    extern float_to_f64
    call float_to_f64
    movq rax, xmm0
    ; An integer too wide for a double is an OverflowError here, and only
    ; here: float_to_f64 is also what a COMPARISON goes through, and
    ; `10**400 > 1.0` has an answer.  CPython draws the line in the same
    ; place -- long_as_double raises, long_richcompare does not.
    mov rcx, rax
    mov rdx, 0x7FFFFFFFFFFFFFFF
    and rcx, rdx
    mov rdx, 0x7FF0000000000000
    cmp rcx, rdx
    jae .if_overflow
    V_FROM_F64 rax, rdx
    mov edx, TAG_FLOAT
    leave
    ret
.if_overflow:
    RAISE exc_OverflowError_type, "int too large to convert to float"
END_FUNC int_float


;; ============================================================================
;; Data
;; ============================================================================
section .data

align 8
one_double: dq 0x3ff0000000000000  ; 1.0

int_name_str: db "int", 0

section .data

align 8
global int_number_methods
int_number_methods:
    dq int_add              ; nb_add          +0
    dq int_sub              ; nb_subtract     +8
    dq int_mul              ; nb_multiply     +16
    dq int_mod              ; nb_remainder    +24
    dq 0                    ; nb_divmod       +32
    dq int_power            ; nb_power        +40
    dq int_neg              ; nb_negative     +48
    dq int_pos              ; nb_positive     +56
    dq int_abs              ; nb_absolute     +64
    dq int_bool             ; nb_bool         +72
    dq int_invert           ; nb_invert       +80
    dq int_lshift           ; nb_lshift       +88
    dq int_rshift           ; nb_rshift       +96
    dq int_and              ; nb_and          +104
    dq int_xor              ; nb_xor          +112
    dq int_or               ; nb_or           +120
    dq int_get_real         ; nb_int          +128 (an int is its own int)
    dq int_float            ; nb_float        +136
    dq int_floordiv         ; nb_floor_divide +144
    dq int_true_divide      ; nb_true_divide  +152
    dq int_get_real         ; nb_index        +160 (an int is its own index)
    dq 0                        ; nb_iadd         +168
    dq 0                        ; nb_isub         +176
    dq 0                        ; nb_imul         +184
    dq 0                        ; nb_irem         +192
    dq 0                        ; nb_ipow         +200
    dq 0                        ; nb_ilshift      +208
    dq 0                        ; nb_irshift      +216
    dq 0                        ; nb_iand         +224
    dq 0                        ; nb_ixor         +232
    dq 0                        ; nb_ior          +240
    dq 0                        ; nb_ifloor_divide +248
    dq 0                        ; nb_itrue_divide +256
    dq 0 ; nb_matmul
    dq 0 ; nb_imatmul

align 8
global int_type
int_type:
    dq 1                    ; ob_refcnt (immortal)
    dq type_type            ; ob_type
    dq int_name_str         ; tp_name
    dq PyIntObject_size     ; tp_basicsize
    dq int_dealloc          ; tp_dealloc
    dq int_repr             ; tp_repr
    dq int_repr             ; tp_str
    dq int_hash             ; tp_hash
    dq 0                    ; tp_call
    dq int_getattr          ; tp_getattr (.real/.imag/.numerator/.denominator)
    dq 0                    ; tp_setattr
    dq int_compare          ; tp_richcompare
    dq 0                    ; tp_iter
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq 0                    ; tp_new
    dq int_number_methods   ; tp_as_number
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq TYPE_FLAG_INT_SUBCLASS ; tp_flags
    dq 0                    ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

section .bss
;; The free list int_alloc_raw pops from and int_dealloc pushes onto.  A block
;; on it is dead: its refcount word holds the link to the next one.
;;
;; align 8 because a `resd 1` earlier in this file's .bss (type_version_counter)
;; had left both of these at `addr % 8 == 4`, so every push and pop of the free
;; list was an unaligned qword access four bytes from a line split.
align 8
int_freelist:       resq 1
int_freelist_count: resq 1
