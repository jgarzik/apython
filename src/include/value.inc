; value.inc - NaN-boxed 64-bit value representation ("Value")
;
; ==========================================================================
; ENCODING
; ==========================================================================
;
; A Value is ONE 64-bit word.  Let high16 = v >> 48.
;
;   high16            meaning                       decode
;   ----------------  ----------------------------  ------------------------
;   0x0000            PyObject*, RAW (v==0 => NULL) use as-is
;   0x0001 .. 0xFFF1  float64                       bits = v - V_F64_OFF
;   0xFFF2            async SLEEP sentinel          delay_ns = v & V_MASK48
;   0xFFF3            async IO_WAIT sentinel        fd|dir<<32 = v & V_MASK48
;   0xFFF4 .. 0xFFF7  reserved
;   0xFFF8 .. 0xFFFF  int immediate                 i = v - V_INT_BIAS
;
; Rationale:
;   * Linux x86-64 user virtual addresses are < 2^47, so every heap pointer
;     has high16 == 0.  Pointers are stored RAW: zero-cost dereference, and
;     NULL == 0 so `test reg, reg` still works as an error check.
;   * Non-NaN doubles span raw bits [0, 0xFFF0000000000000].  Adding 2^48
;     maps them to [0x0001000000000000, 0xFFF1000000000000], which collides
;     with neither pointer space nor tag space.
;   * NaN purification: raw double bits >= V_NAN_LIM (0xFFF1000000000000)
;     are negative NaNs whose encoding would land in tag space.  That set
;     includes x86's default QNaN (0xFFF8000000000000, produced by inf-inf,
;     0*inf, inf/inf).  They are canonicalized to V_CANON_NAN before
;     encoding.  CPython renders every NaN as "nan" regardless of sign or
;     payload, so this is unobservable from Python.
;   * Integers use a bias so that encode is one ADD and decode one SUB.
;     Immediate range is [-2^50, 2^50); anything wider becomes a heap
;     PyIntObject (Python ints are arbitrary precision anyway).
;
; None / True / False have NO immediate form: they are the immortal heap
; singletons none_singleton / bool_true / bool_false, stored as raw pointers.
;
; ==========================================================================

%ifndef VALUE_INC
%define VALUE_INC

%include "threadstate.inc"
%include "sync.inc"

; --- Encoding constants (assemble-time; see v_* symbols below for the
; --- runtime rip-relative copies, since x86-64 has no `cmp r64, imm64`.)
V_F64_OFF     equ 0x0001000000000000   ; float bias (2^48)
V_PTR_LIM     equ 0x0001000000000000   ; v < this  => pointer or NULL
V_PTR_MAX_M1  equ 0x0000FFFFFFFFFFFE   ; (v-1) <= this => non-NULL pointer
V_NAN_LIM     equ 0xFFF1000000000000   ; raw double bits >= this need purifying
V_CANON_NAN   equ 0x7FF8000000000000   ; canonical quiet NaN
V_SLEEP_LO    equ 0xFFF2000000000000   ; async sleep sentinel base
V_IOWAIT_LO   equ 0xFFF3000000000000   ; async io-wait sentinel base
V_INT_LO      equ 0xFFF8000000000000   ; v >= this => int immediate
V_INT_BIAS    equ 0xFFFC000000000000   ; i = v - bias, range [-2^50, 2^50)
V_MASK48      equ 0x0000FFFFFFFFFFFF
V_INT_SHIFT   equ 50                   ; log2 of the int immediate magnitude
V_NULL        equ 0

; high16 discriminators, for the `mov scratch, v / shr scratch, 48` form
VH_PTR        equ 0x0000
VH_F64_MAX    equ 0xFFF1
VH_SLEEP      equ 0xFFF2
VH_IOWAIT     equ 0xFFF3
VH_INT_LO     equ 0xFFF8

; Runtime constant pool, defined in src/val.asm.  A file that defines them
; sets VALUE_INC_NO_EXTERN before including this header.
%ifndef VALUE_INC_NO_EXTERN
extern v_f64_off
extern v_ptr_max_m1
extern v_nan_lim
extern v_canon_nan
extern v_int_lo
extern v_int_bias
extern v_mask48
extern v_sleep_lo
extern v_iowait_lo
extern val_from_i64_p
extern val_pack_cold
extern val_unpack_cold
%endif

; ==========================================================================
; CLASSIFICATION
; Each macro takes (value_reg, scratch_reg) and leaves flags set for the
; documented conditional jump.  Neither register may be the other.
; ==========================================================================

; CF=0 (jae) if v is an int immediate.
%macro V_IS_INT 2               ; %1 = value, %2 = scratch (clobbered)
    mov %2, %1
    shr %2, 48
    cmp %2, VH_INT_LO
%endmacro

; CF=1 (jb) if v is a float immediate.
; (high16 - 1) < 0xFFF1 holds exactly for high16 in [0x0001, 0xFFF1];
; pointers wrap to 0xFFFFFFFFFFFFFFFF and correctly fail the test.
%macro V_IS_FLOAT 2             ; %1 = value, %2 = scratch (clobbered)
    mov %2, %1
    shr %2, 48
    dec %2
    cmp %2, VH_F64_MAX
%endmacro

; Test whether a Value is a real (non-NULL) pointer.  Use `ja` to branch away
; when it is NULL or an immediate, `jbe` when it is a pointer.
%macro V_TEST_PTR 2             ; %1 = value, %2 = scratch (clobbered)
    lea %2, [%1 - 1]
    cmp %2, [rel v_ptr_max_m1]
%endmacro

; Derive the legacy tag of a Value.  %2 may be a register or a memory
; operand and is left untouched; only %1 is written.
%macro V_TAG_OF 2               ; %1 = tag out, %2 = Value (preserved)
    mov %1, %2
    test %1, %1
    jz %%null                   ; 0 is the empty slot
    shr %1, 48
    jz %%ptr
    cmp %1, VH_INT_LO
    jae %%int
    cmp %1, VH_F64_MAX
    jbe %%f64
    cmp %1, VH_SLEEP
    je %%slp
    cmp %1, VH_IOWAIT
    je %%iow
%%null:
    xor %1, %1
    jmp %%done
%%ptr:
    mov %1, TAG_PTR
    jmp %%done
%%int:
    mov %1, TAG_SMALLINT
    jmp %%done
%%f64:
    mov %1, TAG_FLOAT
    jmp %%done
%%slp:
    mov %1, TAG_SLEEP
    jmp %%done
%%iow:
    mov %1, TAG_IO_WAIT
%%done:
%endmacro

; ==========================================================================
; CONVERSION
; ==========================================================================

; Raw IEEE-754 double bits -> Value.  Purifies tag-space NaNs.
%macro V_FROM_F64 2             ; %1 = bits in/value out, %2 = scratch
    mov %2, [rel v_canon_nan]
    cmp %1, [rel v_nan_lim]
    cmovae %1, %2
    add %1, [rel v_f64_off]
%endmacro

; Value (known float) -> raw IEEE-754 double bits.
%macro V_TO_F64 1               ; %1 = value in / bits out
    sub %1, [rel v_f64_off]
%endmacro

; int64 -> Value, branching to %3 when the value does not fit the immediate
; range (the caller must then box it, e.g. via val_from_i64).
%macro V_FROM_I64 3             ; %1 = i64 in/value out, %2 = scratch, %3 = overflow label
    mov %2, %1
    sar %2, V_INT_SHIFT
    inc %2
    cmp %2, 2
    jae %3
    add %1, [rel v_int_bias]
%endmacro

; Value (known int immediate) -> int64.
%macro V_TO_I64 1               ; %1 = value in / int64 out
    sub %1, [rel v_int_bias]
%endmacro

; V_INT(n) -- the Value of a COMPILE-TIME integer constant, folded by NASM.
;
; An int immediate is just n + V_INT_BIAS, so a literal needs no runtime work
; at all: `mov rdx, V_INT(0)` is one instruction where `mov rdx, 0` followed by
; `V_PACK_I64 rdx, rcx` was about sixteen.  Only for constants known to the
; assembler and inside the immediate range: NASM would fold a wider one into a
; FLOAT Value without a word, so `check_const_value` in src/compiler/lint.py is
; what refuses it -- a %define cannot check its own argument.
%define V_INT(n) ((n) + V_INT_BIAS)

; ==========================================================================
; MIGRATION SHIMS
;
; Bridge between converted code, which passes a single Value, and code that
; still passes an old (payload, tag) pair.  Both are inline: the classify is
; a couple of compares, and only an out-of-range integer needs a call.
; These disappear along with the tags in P6.
; ==========================================================================

; int64 -> Value, boxing on overflow.  %2 must not be rax.
%macro V_PACK_I64 2             ; %1 = i64 in / Value out, %2 = scratch
    mov %2, %1
    sar %2, V_INT_SHIFT
    inc %2
    cmp %2, 2
    jb %%fits
    ; Outside the immediate range: box it.  val_from_i64_p preserves every
    ; register except rax, so this cold path cannot disturb the caller.
    push rax
    push rdi
%ifnidni %1, rdi
    mov rdi, %1
%endif
    call val_from_i64_p
    mov %2, rax
    pop rdi
    pop rax
    mov %1, %2
    jmp %%done
%%fits:
    add %1, [rel v_int_bias]
%%done:
%endmacro

; ---------------------------------------------------------------------------
; Classify a Value that lives in memory, without first loading it into the
; register the caller is going to use.  Each writes only the scratch %2.
; ---------------------------------------------------------------------------

; Pointer test: follow with `ja` to branch away when NULL or an immediate.
%macro V_TEST_PTR_M 2           ; %1 = m64 holding a Value, %2 = scratch
    mov %2, %1
    dec %2
    cmp %2, [rel v_ptr_max_m1]
%endmacro

; Int-immediate test: follow with `jae` when it is one, `jb` when it is not.
%macro V_TEST_INT_M 2           ; %1 = m64 holding a Value, %2 = scratch
    mov %2, %1
    cmp %2, [rel v_int_lo]
%endmacro

; Float test: follow with `jbe` when it is one, `ja` when it is not.
%macro V_TEST_F64_M 2           ; %1 = m64 holding a Value, %2 = scratch
    mov %2, %1
    shr %2, 48
    dec %2
    cmp %2, VH_F64_MAX - 1
%endmacro

; (payload, tag) -> Value.  %2 must not be rax.
%macro V_PACK_INLINE 2          ; %1 = payload in / Value out, %2 = tag (clobbered)
    cmp %2, TAG_SMALLINT
    je %%si
    cmp %2, TAG_FLOAT
    je %%f64
    cmp %2, TAG_SLEEP
    je %%slp
    cmp %2, TAG_IO_WAIT
    je %%iow
    jmp %%done                  ; TAG_PTR and TAG_NULL: the payload is the Value
%%si:
    V_PACK_I64 %1, %2
    jmp %%done
%%f64:
    V_FROM_F64 %1, %2
    jmp %%done
%%slp:
    or %1, [rel v_sleep_lo]
    jmp %%done
%%iow:
    or %1, [rel v_iowait_lo]
%%done:
%endmacro

; Value -> (payload, tag).
%macro V_UNPACK_INLINE 2        ; %1 = Value in / payload out, %2 = tag out
    mov %2, %1
    shr %2, 48
    jz %%ptr
    cmp %2, VH_INT_LO
    jae %%int
    cmp %2, VH_F64_MAX
    jbe %%f64
    cmp %2, VH_SLEEP
    je %%slp
    cmp %2, VH_IOWAIT
    je %%iow
    xor %1, %1                  ; reserved encoding: treat as empty
    xor %2, %2
    jmp %%done
%%ptr:
    test %1, %1
    jz %%null
    mov %2, TAG_PTR
    jmp %%done
%%null:
    xor %2, %2
    jmp %%done
%%int:
    sub %1, [rel v_int_bias]
    mov %2, TAG_SMALLINT
    jmp %%done
%%f64:
    sub %1, [rel v_f64_off]
    mov %2, TAG_FLOAT
    jmp %%done
%%slp:
    and %1, [rel v_mask48]
    mov %2, TAG_SLEEP
    jmp %%done
%%iow:
    and %1, [rel v_mask48]
    mov %2, TAG_IO_WAIT
%%done:
%endmacro

; ==========================================================================
; V_PACK / V_UNPACK -- the out-of-line form
;
; These two are the most-used macros in the tree, and until this was written
; each expanded in full: 114 bytes for a V_PACK and about 124 for a V_UNPACK,
; at 1280 and 950 sites, which came to a ninth of the whole .text segment.
; Most of that was arms for tags that the site in question never sees.
;
; So the arm the site DOES see stays inline -- for V_PACK, a payload that is
; already the Value (TAG_PTR and TAG_NULL); for V_UNPACK, a real non-NULL
; pointer -- and everything else is one call to a helper in src/val.asm.  The
; two hot arms get FASTER as a side effect: a TAG_PTR pack was a
; four-compare ladder and is now one compare and one predicted branch.
;
; The helpers clobber rax and rdx and nothing else, which is what lets the
; 496 + 1062 sites whose operands are already (rax, rdx) call them with no
; register saves at all.  Every other operand pair is shuffled into place by
; V_PACK_CALL / V_UNPACK_CALL below, which preserve the same contract: the
; macro clobbers %1 and %2 and NOTHING ELSE.
;
; V_PACK_INLINE / V_UNPACK_INLINE keep the old fully-expanded bodies.  Using
; one is a claim that the site was profiled; say what you measured in the
; commit that adds it.
; ==========================================================================

; ---------------------------------------------------------------------------
; V_PACK_CALL payload, tag -- reach val_pack_cold with (rax = payload,
; rdx = tag), leave the Value in `payload`, and disturb nothing else.
;
; Six shapes, because rax and rdx are both the helper's ABI and, at most
; sites, somebody else's live registers.  Where an operand IS rax or rdx it is
; already the macro's to clobber, so the save collapses to an xchg -- which is
; why the overwhelmingly common (rax, rdx) shape costs one call and nothing.
; ---------------------------------------------------------------------------
%macro V_PACK_CALL 2
  %ifidni %1,%2
    %error "V_PACK: payload and tag must be different registers"
  %endif
  %ifidni %1,rax
    %ifidni %2,rdx
    call val_pack_cold
    %else
    push rdx
    mov rdx, %2
    call val_pack_cold
    pop rdx
    %endif
  %elifidni %1,rdx
    %ifidni %2,rax
    xchg rax, rdx
    call val_pack_cold
    xchg rax, rdx
    %else
    push rax
    mov rax, rdx
    mov rdx, %2
    call val_pack_cold
    mov rdx, rax
    pop rax
    %endif
  %elifidni %2,rdx
    xchg rax, %1                ; park the caller's rax in %1, which is ours
    call val_pack_cold
    xchg rax, %1
  %elifidni %2,rax
    push rdx
    mov rdx, rax                ; the tag, before rax is overwritten
    mov rax, %1
    call val_pack_cold
    mov %1, rax
    pop rdx
  %else
    xchg rax, %1
    push rdx
    mov rdx, %2
    call val_pack_cold
    pop rdx
    xchg rax, %1
  %endif
%endmacro

; ---------------------------------------------------------------------------
; V_UNPACK_CALL value, tag -- the mirror.  Both operands are outputs here, so
; where %2 is already rdx the tag needs no move at all.
; ---------------------------------------------------------------------------
%macro V_UNPACK_CALL 2
  %ifidni %1,%2
    %error "V_UNPACK: value and tag must be different registers"
  %endif
  %ifidni %1,rax
    %ifidni %2,rdx
    call val_unpack_cold
    %else
    push rdx
    call val_unpack_cold
    mov %2, rdx
    pop rdx
    %endif
  %elifidni %1,rdx
    %ifidni %2,rax
    xchg rax, rdx
    call val_unpack_cold
    xchg rax, rdx
    %else
    push rax
    mov rax, rdx
    call val_unpack_cold
    mov %2, rdx                 ; read the tag out before rdx is retired
    mov rdx, rax
    pop rax
    %endif
  %elifidni %2,rdx
    xchg rax, %1
    call val_unpack_cold
    xchg rax, %1
  %elifidni %2,rax
    push rdx
    mov rax, %1
    call val_unpack_cold
    mov %1, rax                 ; the payload, before rax takes the tag
    mov rax, rdx
    pop rdx
  %else
    xchg rax, %1
    push rdx
    call val_unpack_cold
    mov %2, rdx
    pop rdx
    xchg rax, %1
  %endif
%endmacro

; (payload, tag) -> Value.  Clobbers %1 and %2 only.
;
; The tag set is {0, 1, 2, 7, 8, 0x85}, so `> TAG_IO_WAIT` is exactly TAG_PTR
; and zero is exactly TAG_NULL -- both are the Value already.  A reserved tag
; in 3..6 falls through to the helper, which passes it through, which is what
; the fully-inline form did too.
%macro V_PACK 2                 ; %1 = payload in / Value out, %2 = tag (clobbered)
    cmp %2, TAG_IO_WAIT
    ja %%done                   ; TAG_PTR: a pointer is its own Value
    cmp %2, TAG_SMALLINT
    jne %%not_int
    ; An in-range int is one add, and the range check is the add's own result:
    ; i + bias lands in [V_INT_LO, 2^64) for exactly i in [-2^50, 2^50), and
    ; for nothing else -- the interval is 2^51 wide, so the wrap is unique.
    ; Testing it this way rather than with V_FROM_I64 is not a flourish:
    ; V_FROM_I64 needs a scratch, the only scratch here is the tag, and the
    ; helper on the overflow path still needs the tag.
    add %1, [rel v_int_bias]
    cmp %1, [rel v_int_lo]
    jae %%done
    sub %1, [rel v_int_bias]    ; too wide for an immediate: the helper boxes it
    jmp %%call
%%not_int:
    test %2, %2
    jz %%done                   ; TAG_NULL: an empty slot is the Value too
%%call:
    V_PACK_CALL %1, %2
%%done:
%endmacro

; Value -> (payload, tag).  Clobbers %1 and %2 only.
;
; `lea %2,[%1-1]` + one unsigned compare tests "non-NULL" and "below 2^48" at
; once; the `mov` in between sets the answer for the taken arm without
; touching the flags.
%macro V_UNPACK 2               ; %1 = Value in / payload out, %2 = tag out
    lea %2, [%1 - 1]
    cmp %2, [rel v_ptr_max_m1]
    mov %2, TAG_PTR
    jbe %%done
    cmp %1, [rel v_int_lo]      ; everything at or above it is an int immediate
    jb %%slow
    sub %1, [rel v_int_bias]
    mov %2, TAG_SMALLINT
    jmp %%done
%%slow:
    V_UNPACK_CALL %1, %2
%%done:
%endmacro

; ==========================================================================
; REFERENCE COUNTING
; A Value participates in refcounting iff it is a non-NULL pointer, i.e.
; 1 <= v < 2^48.  `lea scratch,[v-1]` + one unsigned compare tests both
; halves of that at once.
; ==========================================================================

%macro INCREF_V 2               ; %1 = value, %2 = scratch (clobbered)
    lea %2, [%1 - 1]
    cmp %2, [rel v_ptr_max_m1]
    ja %%skip
    mov _R32_%+%2, [%1 + PyObject.ob_tid]
    cmp _R32_%+%2, [gs:ThreadState.ts_tid]
    jne %%nonlocal
    inc dword [%1 + PyObject.ob_ref_local]
    jmp %%skip
%%nonlocal:
    test _R32_%+%2, _R32_%+%2
    jz %%skip
    lock add dword [%1 + PyObject.ob_ref_shared], REF_SHARED_ONE
%%skip:
%endmacro

; Clobbers rdi and all caller-saved registers when the object is freed.
;
; The %ifnidni is not cosmetic: DECREF_V's operand is already rdi at a great
; many sites, and without the guard the macro emits `mov rdi, rdi` there --
; 593 of them in the linked binary before this was added.
; VALUE_EQ_FAST elem, needle, scratch, equal_label, unequal_label
;
; The two questions about `==` that a Value can answer without calling
; anything, for the loops that scan a container comparing every element
; against one needle.  Falls THROUGH when neither applies, so the caller's
; general comparison follows immediately.
;
;   - identical Values are equal.  obj_richcompare_bool answers this in its
;     own first compare, but only after two INCREF_Vs, a frame and a call --
;     and over a container of small integers, where every element IS its
;     Value, that compare is the only thing it does.
;   - two int immediates that are not the same Value are NOT equal, the
;     encoding being one-to-one.  That is the other half: the misses, which
;     the identity arm cannot settle and which are every element of the
;     container when the answer is "not found".
;
; Anything else -- a bool, which is a heap singleton; a heap integer, which
; is outside the immediate range; a float; a class with its own __eq__ --
; falls through and is compared properly.
%macro VALUE_EQ_FAST 5          ; %1 elem, %2 needle, %3 scratch, %4 eq, %5 ne
    cmp %1, %2
    je %4
    V_IS_INT %1, %3
    jb %%general
    V_IS_INT %2, %3
    jb %%general
    jmp %5
%%general:
%endmacro

%macro DECREF_V 2               ; %1 = value, %2 = scratch (clobbered)
    lea %2, [%1 - 1]
    cmp %2, [rel v_ptr_max_m1]
    ja %%skip
    mov _R32_%+%2, [%1 + PyObject.ob_tid]
    cmp _R32_%+%2, [gs:ThreadState.ts_tid]
    jne %%nonlocal
    dec dword [%1 + PyObject.ob_ref_local]
    jnz %%skip
%ifnidni %1, rdi
    mov rdi, %1
%endif
    extern obj_decref_local_zero
    call obj_decref_local_zero
    jmp %%skip
%%nonlocal:
    test _R32_%+%2, _R32_%+%2
    jz %%skip
    push rdi
    push rdi
%ifnidni %1, rdi
    mov rdi, %1
%endif
    extern obj_decref_shared_p
    call obj_decref_shared_p
    pop rdi
    pop rdi
%%skip:
%endmacro

; DECREF_V is already NULL-safe; XDECREF_V exists for call-site clarity.
%macro XDECREF_V 2              ; %1 = value, %2 = scratch (clobbered)
    DECREF_V %1, %2
%endmacro

%endif ; VALUE_INC
