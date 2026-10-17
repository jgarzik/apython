; structseq.asm - tuple-with-named-fields, the shape os.stat() returns
;
; A struct sequence is a tuple whose entries also have names, plus a tail of
; fields reachable only by name.  os.stat() returns one; so do os.uname(),
; os.terminal_size(), sys.version_info and its three siblings.
;
; The instance IS a tuple -- the PyTupleObject header sits at offset 0, so
; every piece of tuple code reads it unchanged, `isinstance(st, tuple)` is
; True, unpacking works, and tuple's own methods come through the MRO from
; tuple_type.tp_dict.  bool_type does exactly this one layer down: a static
; type whose tp_basicsize is its base's, with tp_base patched at init.
;
;     +0   ob_refcnt   }
;     +8   ob_type     }  PyTupleObject, read verbatim by tuple's code
;     +16  ob_size     }  = n_in_sequence, NOT the field count
;     +24  ob_hash     }
;     +32  ob_item -> Value[n_in_sequence]
;     +40  the named-only fields, one Value each
;
; ob_item is a separate allocation rather than inline storage, which is what
; makes the tail safe: nothing tuple does can reach past the 40-byte header.
; That is the difference from str and bytes, whose subclasses need
; TP_DICT_AT_TAIL because their data IS inline.
;
; Each type carries a StructSeqDesc pointer in one extra qword just past
; PyTypeObject, so tp_getattr, tp_repr and tp_dealloc can all find their own
; descriptor from the instance's type.  Without it every type would need
; three thunks whose only job was to name a table.
;
; NOT GC-tracked, and deliberately.  A struct sequence holds numbers and
; strings; it cannot be part of a cycle, and CPython's are not tracked
; either.  So: ap_malloc, no tp_traverse, no TYPE_FLAG_HAVE_GC -- and its own
; tp_dealloc, because tuple_dealloc would hand a 40-plus-tail object to the
; tuple free pool, from which it would come back out as a plain tuple.

%include "macros.inc"
%include "object.inc"

ASM_INIT

extern none_singleton
extern ap_malloc
extern ap_free
extern ap_strcmp
extern obj_decref
extern obj_dealloc
extern obj_repr
extern str_from_cstr_heap
extern str_concat
extern tuple_type
extern type_type
extern exc_TypeError_type
extern raise_exception
extern get_iterator_opt

section .text

;; ============================================================================
;; structseq_new(rdi = the type) -> rax = a zeroed instance, or 0
;;
;; ob_size is n_in_sequence, not the field count: the tail is reachable by
;; name only, and every tuple operation must see the shorter length.
;; ============================================================================
SSN_TYPE  equ 8
SSN_DESC  equ 16
SSN_OBJ   equ 24
SSN_FRAME equ 32            ; + 0 pushes = 32

DEF_FUNC structseq_new, SSN_FRAME
    mov [rbp - SSN_TYPE], rdi
    mov rax, [rdi + STRUCTSEQ_DESC]         ; the descriptor, just past the type
    mov [rbp - SSN_DESC], rax

    mov rdi, [rdi + PyTypeObject.tp_basicsize]
    call ap_malloc
    test rax, rax
    jz .ssn_out
    mov [rbp - SSN_OBJ], rax

    mov qword [rax + PyObject.ob_refcnt], 1
    mov rcx, [rbp - SSN_TYPE]
    mov [rax + PyObject.ob_type], rcx
    inc qword [rcx + PyObject.ob_refcnt]
    mov qword [rax + PyTupleObject.ob_hash], -1

    mov rdx, [rbp - SSN_DESC]
    mov rdx, [rdx + StructSeqDesc.n_in_sequence]
    mov [rax + PyTupleObject.ob_size], rdx

    ; Zero the tail before anything can look at it: the fields are filled one
    ; at a time, and a repr or a dealloc in between must see NULLs.
    mov rcx, [rbp - SSN_TYPE]
    mov rcx, [rcx + PyTypeObject.tp_basicsize]
    lea rsi, [rax + PyTupleObject_size]
    sub rcx, PyTupleObject_size
.ssn_zero_tail:
    cmp rcx, 8
    jb .ssn_items
    mov qword [rsi], 0
    add rsi, 8
    sub rcx, 8
    jmp .ssn_zero_tail

.ssn_items:
    ; ap_malloc(0) is not a thing worth relying on, so an empty sequence still
    ; gets one word.
    lea rdi, [rdx*8]
    test rdi, rdi
    jnz .ssn_items_alloc
    mov edi, 8
.ssn_items_alloc:
    push rdx
    push rdx                    ; twice, to keep rsp 16-byte aligned
    call ap_malloc
    pop rdx
    pop rdx
    test rax, rax
    jz .ssn_no_items
    mov rcx, [rbp - SSN_OBJ]
    mov [rcx + PyTupleObject.ob_item], rax
    xor ecx, ecx
.ssn_zero_items:
    cmp rcx, rdx
    jge .ssn_done
    mov qword [rax + rcx*8], 0
    inc rcx
    jmp .ssn_zero_items

.ssn_no_items:
    mov rdi, [rbp - SSN_OBJ]
    call ap_free
    xor eax, eax
    jmp .ssn_out
.ssn_done:
    mov rax, [rbp - SSN_OBJ]
.ssn_out:
    leave
    ret
END_FUNC structseq_new

;; ============================================================================
;; structseq_set(rdi = obj, esi = field index, rdx = Value)
;;
;; Takes over the caller's reference, so a builder reads as one line per
;; field.  Field indices below n_in_sequence land in the tuple, the rest in
;; the tail -- one numbering across both, as the descriptor lists them.
;; ============================================================================
DEF_FUNC_BARE structseq_set
    movsxd rsi, esi
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + STRUCTSEQ_DESC]
    mov rcx, [rax + StructSeqDesc.n_in_sequence]
    cmp rsi, rcx
    jge .sss_tail
    mov rax, [rdi + PyTupleObject.ob_item]
    mov [rax + rsi*8], rdx
    ret
.sss_tail:
    sub rsi, rcx
    lea rax, [rdi + PyTupleObject_size]
    mov [rax + rsi*8], rdx
    ret
END_FUNC structseq_set

;; ============================================================================
;; structseq_getattr(rdi = self, rsi = name str) -> rax = Value, or NULL
;;
;; NULL for an unknown name rather than a raise, so op_load_attr falls through
;; to the MRO's tp_dicts and tuple's index(), count() and __len__ still work.
;; That is the contract slice_getattr states and every other tp_getattr keeps.
;; ============================================================================
SSG_SELF  equ 8
SSG_NAME  equ 16
SSG_DESC  equ 24
SSG_FRAME equ 40            ; + 1 push = 48, 16-byte aligned

DEF_FUNC structseq_getattr, SSG_FRAME
    push rbx
    mov [rbp - SSG_SELF], rdi
    mov [rbp - SSG_NAME], rsi
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + STRUCTSEQ_DESC]
    mov [rbp - SSG_DESC], rax
    xor ebx, ebx

.ssg_loop:
    mov rax, [rbp - SSG_DESC]
    cmp rbx, [rax + StructSeqDesc.n_fields]
    jge .ssg_missing
    mov rax, [rax + StructSeqDesc.fields]
    mov rcx, rbx
    shl rcx, 4                              ; StructSeqField_size
    mov rdi, [rax + rcx + StructSeqField.name]
    mov rsi, [rbp - SSG_NAME]
    lea rsi, [rsi + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .ssg_found
    inc rbx
    jmp .ssg_loop

.ssg_found:
    ; The field's own index, which is not the loop index: a descriptor may
    ; list its fields in any order.
    mov rax, [rbp - SSG_DESC]
    mov rcx, [rax + StructSeqDesc.fields]
    mov rdx, rbx
    shl rdx, 4
    mov rdx, [rcx + rdx + StructSeqField.index]
    mov rcx, [rax + StructSeqDesc.n_in_sequence]
    mov rdi, [rbp - SSG_SELF]
    cmp rdx, rcx
    jge .ssg_tail
    mov rax, [rdi + PyTupleObject.ob_item]
    mov rax, [rax + rdx*8]
    jmp .ssg_out
.ssg_tail:
    sub rdx, rcx
    lea rax, [rdi + PyTupleObject_size]
    mov rax, [rax + rdx*8]
    ; A named-only field the constructor never filled holds a zero Value, and
    ; zero is also what .ssg_missing answers for "no such attribute" -- so the
    ; field read as absent rather than unset.  The name IS on the descriptor;
    ; CPython answers None for one that was not supplied.
    test rax, rax
    jnz .ssg_out
    LOAD_NONE rax
.ssg_out:
    INCREF_V rax, rcx
    pop rbx
    leave
    ret

.ssg_missing:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC structseq_getattr

;; ============================================================================
;; structseq_repr(rdi = self, edx = tag) -> rax = str, edx = TAG_PTR
;;
;; "os.stat_result(st_mode=33188, st_ino=..., ...)" -- the type's full dotted
;; tp_name, then the SEQUENCE fields only.  CPython's shows no more than
;; those, however many named-only ones follow.
;;
;; Built by repeated concatenation, which is quadratic in the field count and
;; entirely fine at twenty of them.
;; ============================================================================
SSR_SELF  equ 8
SSR_DESC  equ 16
SSR_ACC   equ 24
SSR_TMP   equ 32
SSR_FRAME equ 40            ; + 1 push = 48

DEF_FUNC structseq_repr, SSR_FRAME
    push rbx
    mov [rbp - SSR_SELF], rdi
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + STRUCTSEQ_DESC]
    mov [rbp - SSR_DESC], rax

    mov rdi, [rbp - SSR_SELF]
    mov rdi, [rdi + PyObject.ob_type]
    mov rdi, [rdi + PyTypeObject.tp_name]
    call str_from_cstr_heap
    mov [rbp - SSR_ACC], rax
    mov rdi, rax
    CSTRING rsi, "("
    call ssr_append_cstr
    mov [rbp - SSR_ACC], rax

    xor ebx, ebx
.ssr_loop:
    mov rax, [rbp - SSR_DESC]
    cmp rbx, [rax + StructSeqDesc.n_in_sequence]
    jge .ssr_close
    test rbx, rbx
    jz .ssr_name
    mov rdi, [rbp - SSR_ACC]
    CSTRING rsi, ", "
    call ssr_append_cstr
    mov [rbp - SSR_ACC], rax
.ssr_name:
    ; The field whose index is rbx, which the loop finds rather than assumes.
    mov rax, [rbp - SSR_DESC]
    mov rcx, [rax + StructSeqDesc.fields]
    xor edx, edx
.ssr_find:
    cmp rdx, [rax + StructSeqDesc.n_fields]
    jge .ssr_close              ; a descriptor missing a sequence index
    mov rsi, rdx
    shl rsi, 4
    cmp qword [rcx + rsi + StructSeqField.index], rbx
    je .ssr_have_field
    inc rdx
    jmp .ssr_find
.ssr_have_field:
    mov rsi, [rcx + rsi + StructSeqField.name]
    mov rdi, [rbp - SSR_ACC]
    call ssr_append_cstr
    mov [rbp - SSR_ACC], rax
    mov rdi, rax
    CSTRING rsi, "="
    call ssr_append_cstr
    mov [rbp - SSR_ACC], rax

    mov rdi, [rbp - SSR_SELF]
    mov rdi, [rdi + PyTupleObject.ob_item]
    mov rdi, [rdi + rbx*8]
    call obj_repr
    test rax, rax
    jz .ssr_fail
    mov rsi, rax
    mov rdi, [rbp - SSR_ACC]
    call ssr_append_obj         ; takes over the reference obj_repr returned
    mov [rbp - SSR_ACC], rax
    inc rbx
    jmp .ssr_loop

.ssr_close:
    mov rdi, [rbp - SSR_ACC]
    CSTRING rsi, ")"
    call ssr_append_cstr
    mov [rbp - SSR_ACC], rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.ssr_fail:
    mov rdi, [rbp - SSR_ACC]
    call obj_decref
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
END_FUNC structseq_repr

;; ssr_append_cstr(rdi = accumulator str, rsi = C string) -> rax = the new one
;; ssr_append_obj (rdi = accumulator str, rsi = a str) -> rax = the new one
;;
;; Both release the accumulator they were given and the piece appended, so a
;; caller keeps exactly one reference and the loop is one line per piece.
;; The accumulator is an argument rather than a frame slot the helper reaches
;; into: DEF_FUNC_LOCAL builds a frame of its own, so `[rbp - SSR_ACC]` inside
;; one of these read the helper's frame, not structseq_repr's.
DEF_FUNC_LOCAL ssr_append_cstr
    push rbx
    push r12
    mov rbx, rdi
    mov rdi, rsi
    call str_from_cstr_heap
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    mov ecx, TAG_PTR
    call str_concat
    push rax
    push rax
    mov rdi, rbx
    call obj_decref             ; the old accumulator
    mov rdi, r12
    call obj_decref             ; the piece
    pop rax
    pop rax
    pop r12
    pop rbx
    leave
    ret
END_FUNC ssr_append_cstr

DEF_FUNC_LOCAL ssr_append_obj
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov ecx, TAG_PTR
    call str_concat             ; rdi is the accumulator already
    push rax
    push rax
    mov rdi, rbx
    call obj_decref             ; the old accumulator
    mov rdi, r12
    call obj_decref             ; the piece
    pop rax
    pop rax
    pop r12
    pop rbx
    leave
    ret
END_FUNC ssr_append_obj

;; ============================================================================
;; structseq_dealloc(rdi = self)
;;
;; Its own, not tuple's: tuple_dealloc returns a small tuple to the free pool
;; by ob_size, and a struct sequence with three visible fields would come back
;; out of it as a plain three-tuple -- with a tail nothing knew was there.
;; ============================================================================
SSD_SELF  equ 8
SSD_N     equ 16
SSD_FRAME equ 16            ; + 2 pushes = 32

DEF_FUNC structseq_dealloc, SSD_FRAME
    push rbx
    push r12
    mov [rbp - SSD_SELF], rdi

    ; The visible entries, then their array.
    mov r12, [rdi + PyTupleObject.ob_size]
    mov rbx, [rdi + PyTupleObject.ob_item]
    test rbx, rbx
    jz .ssd_tail
    xor ecx, ecx
.ssd_items:
    cmp rcx, r12
    jge .ssd_free_items
    push rcx
    push rcx
    mov rdi, [rbx + rcx*8]
    DECREF_V rdi, rsi
    pop rcx
    pop rcx
    inc rcx
    jmp .ssd_items
.ssd_free_items:
    mov rdi, rbx
    call ap_free

.ssd_tail:
    ; The named-only fields, which the tuple length says nothing about.
    mov rdi, [rbp - SSD_SELF]
    mov rax, [rdi + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_basicsize]
    sub rcx, PyTupleObject_size
    shr rcx, 3                  ; how many tail slots
    lea rbx, [rdi + PyTupleObject_size]
    xor r12d, r12d
.ssd_tail_loop:
    cmp r12, rcx
    jge .ssd_type
    push rcx
    push rcx
    mov rdi, [rbx + r12*8]
    DECREF_V rdi, rsi
    pop rcx
    pop rcx
    inc r12
    jmp .ssd_tail_loop

.ssd_type:
    mov rdi, [rbp - SSD_SELF]
    mov rdi, [rdi + PyObject.ob_type]
    call obj_decref             ; the instance held one, as every instance does
    mov rdi, [rbp - SSD_SELF]
    call ap_free
    pop r12
    pop rbx
    leave
    ret
END_FUNC structseq_dealloc

;; ============================================================================
;; structseq_init_type(rdi = the type)
;;
;; The two slots a static type cannot spell out for itself: tp_base, and the
;; tp_iter that init_iter_types patches into tuple_type at startup.  Slot
;; reads do not walk the MRO, so `for x in st` needs the pointer copied here
;; rather than inherited.  bool_init does the first of these for the same
;; reason.  Must run after init_iter_types.
;; ============================================================================
;; ============================================================================
;; structseq_type_new(rdi = the type, rsi = args, rdx = nargs) -> the instance
;;
;; `os.terminal_size((80, 24))` and every other struct sequence's constructor.
;; Without one, type_call walked to the base and used TUPLE's, which gc_allocs
;; -- and structseq_dealloc ap_frees, sixteen bytes off the block it was given
;; and never untracked.  A built-and-dropped terminal_size aborted the process
;; with "double free or corruption"; shutil.get_terminal_size() makes exactly
;; that call.
;; ============================================================================
SSC_TYPE  equ 8
SSC_OBJ   equ 16
SSC_ITER  equ 24
SSC_I     equ 32
SSC_N     equ 40
SSC_EXC   equ 48            ; current_exception on entry, to tell a raising
                            ; __next__ from a clean exhaustion
SSC_MAX   equ 56            ; n_fields: the tail is constructible too
SSC_FRAME equ 64            ; + 0 pushes = 64

DEF_FUNC structseq_type_new, SSC_FRAME
    mov [rbp - SSC_TYPE], rdi
    test rdx, rdx
    jz .ssc_argerr
    cmp rdx, 2
    jg .ssc_argerr
    ; TWO limits, not one.  n_in_sequence is the tuple's length and the
    ; MINIMUM; n_fields counts the named-only tail as well and is the
    ; maximum.  CPython accepts anything between them and leaves the rest
    ; None -- `time.struct_time(tt[:time._STRUCT_TM_ITEMS])` is the last line
    ; of _strptime.py and hands over all eleven -- and demanding exactly nine
    ; was every strptime call in the stdlib.
    mov rax, [rdi + STRUCTSEQ_DESC]
    mov rcx, [rax + StructSeqDesc.n_fields]
    mov rax, [rax + StructSeqDesc.n_in_sequence]
    mov [rbp - SSC_N], rax
    mov [rbp - SSC_MAX], rcx

    ; The sequence is walked with the ordinary iterator protocol, so a list, a
    ; tuple and a generator all work -- as they do in CPython.
    mov rdi, [rsi]
    V_UNPACK rdi, rsi           ; get_iterator still takes (payload, tag), not
    call get_iterator_opt       ; a Value; passing only the payload left the
                                ; tag register holding whatever was in it
    test rax, rax
    jz .ssc_not_sequence
    mov [rbp - SSC_ITER], rax

    mov rdi, [rbp - SSC_TYPE]
    call structseq_new
    test rax, rax
    jz .ssc_fail_iter
    mov [rbp - SSC_OBJ], rax

    mov qword [rbp - SSC_I], 0
    DUNDER_EXC_SAVE [rbp - SSC_EXC]
.ssc_loop:
    mov rdi, [rbp - SSC_ITER]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .ssc_bad_len
    call rax
    V_UNPACK rax, rdx
    test edx, edx
    jz .ssc_iter_end            ; NULL: the sequence ended, or __next__ raised

    mov rcx, [rbp - SSC_I]
    cmp rcx, [rbp - SSC_MAX]
    jge .ssc_too_long_item
    V_PACK rax, rdx
    mov rdx, rax
    mov rdi, [rbp - SSC_OBJ]
    mov esi, ecx
    call structseq_set          ; takes over the reference tp_iternext gave
    inc qword [rbp - SSC_I]
    jmp .ssc_loop

.ssc_iter_end:
    ; tp_iternext answers NULL for a clean exhaustion AND for a __next__ that
    ; raised.  Treating both as exhaustion built the object anyway and left
    ; the exception pending for whatever ran next -- or, when the count was
    ; short, replaced it with a length error.
    EXC_RAISED_SINCE [rbp - SSC_EXC], rax, .ssc_propagate

.ssc_exhausted:
    ; Short of the minimum is an error; short of the maximum is not.  A tail
    ; field nobody supplied stays the zero structseq_new left there, and
    ; structseq_getattr already answers None for one.
    mov rcx, [rbp - SSC_I]
    cmp rcx, [rbp - SSC_N]
    jl .ssc_too_short
    mov rdi, [rbp - SSC_ITER]
    call obj_decref
    mov rax, [rbp - SSC_OBJ]
    mov edx, TAG_PTR
    leave
    ret

.ssc_too_long_item:
    ; The item that tripped the limit is owned and goes no further.
    V_PACK rax, rdx
    mov rdi, rax
    DECREF_V rdi, rcx
.ssc_too_long:
    ; Keep counting, so the message can say how many were actually there --
    ; which is the half of it that tells the caller what to change.  A bound
    ; keeps an endless iterator from spinning here for ever.
    inc qword [rbp - SSC_I]
    mov rax, [rbp - SSC_I]
    cmp rax, [rbp - SSC_MAX]
    ja .ssc_bad_len             ; one over is enough to report
.ssc_drain:
    mov rdi, [rbp - SSC_ITER]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .ssc_bad_len
    call rax
    V_UNPACK rax, rdx
    test edx, edx
    jz .ssc_bad_len
    V_PACK rax, rdx
    mov rdi, rax
    DECREF_V rdi, rcx
    inc qword [rbp - SSC_I]
    jmp .ssc_drain

.ssc_bad_len:
    ; Too many.  The bound to name is n_fields, and the wording is "at most"
    ; -- unless the two counts are equal, in which case there is no range to
    ; describe and CPython says "a": os.terminal_size takes a 2-sequence and
    ; nothing else.  Pick the word BEFORE overwriting the count with it.
    mov rax, [rbp - SSC_MAX]
    lea rcx, [rel ssq_takes_atmost]
    cmp rax, [rbp - SSC_N]
    jne .ssc_bad_len_word
    lea rcx, [rel ssq_takes]
.ssc_bad_len_word:
    mov [rbp - SSC_N], rax
    jmp .ssc_len_error
.ssc_too_short:
    ; Too few, and the minimum is already in SSC_N.
    mov rax, [rbp - SSC_MAX]
    lea rcx, [rel ssq_takes_atleast]
    cmp rax, [rbp - SSC_N]
    jne .ssc_len_error
    lea rcx, [rel ssq_takes]
.ssc_len_error:
    push rcx                    ; across the two decrefs below
    push rcx                    ; twice, to keep rsp 16-byte aligned
    mov rdi, [rbp - SSC_OBJ]
    call obj_decref
    mov rdi, [rbp - SSC_ITER]
    call obj_decref
    pop rcx
    pop rcx
    mov rdi, [rbp - SSC_TYPE]
    mov rsi, [rbp - SSC_N]
    mov rdx, [rbp - SSC_I]
    call structseq_raise_length
    ud2
.ssc_propagate:
    mov rdi, [rbp - SSC_OBJ]
    call obj_decref
    mov rdi, [rbp - SSC_ITER]
    call obj_decref
    xor eax, eax
    xor edx, edx
    leave
    ret

.ssc_fail_iter:
    mov rdi, [rbp - SSC_ITER]
    call obj_decref
.ssc_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
.ssc_not_sequence:
    RAISE exc_TypeError_type, "constructor requires a sequence"
.ssc_argerr:
    RAISE exc_TypeError_type, "structseq() missing required argument 'sequence' (pos 1)"
END_FUNC structseq_type_new

;; structseq_raise_length(rdi = type, rsi = wanted, rdx = given,
;;                        rcx = the connective, one of the three ssq_takes_*)
;; "os.terminal_size() takes a 2-sequence (3-sequence given)", or the "at
;; least" / "at most" wording where the field count and the sequence length
;; differ.
DEF_FUNC structseq_raise_length
    push rbx
    push r12
    push r13
    push r13                    ; twice, to keep rsp 16-byte aligned
    mov rbx, rsi
    mov r12, rdx
    mov r13, rcx
    mov rsi, [rdi + PyTypeObject.tp_name]
    lea rdi, [rel ssq_msgbuf]
    mov edx, 60
    call ssq_copy
    mov rdi, rax
    mov rsi, r13
    mov edx, 32
    call ssq_copy
    mov rdi, rax
    mov rsi, rbx
    call ssq_append_i64
    mov rdi, rax
    lea rsi, [rel ssq_seq_open]
    mov edx, 20
    call ssq_copy
    mov rdi, rax
    mov rsi, r12
    call ssq_append_i64
    mov rdi, rax
    lea rsi, [rel ssq_seq_close]
    mov edx, 20
    call ssq_copy
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel ssq_msgbuf]
    call raise_exception
    ud2
END_FUNC structseq_raise_length

DEF_FUNC_LOCAL ssq_copy         ; (rdi = dest, rsi = src, rdx = max) -> the NUL
    xor ecx, ecx
.sqc_loop:
    cmp rcx, rdx
    jge .sqc_done
    mov al, [rsi + rcx]
    test al, al
    jz .sqc_done
    mov [rdi + rcx], al
    inc rcx
    jmp .sqc_loop
.sqc_done:
    lea rax, [rdi + rcx]
    mov byte [rax], 0
    leave
    ret
END_FUNC ssq_copy

DEF_FUNC_LOCAL ssq_append_i64   ; (rdi = dest, rsi = value) -> the NUL
    mov rax, rsi
    lea r8, [rel ssq_numbuf + 24]
    mov byte [r8], 0
    mov r9d, 10
.sqa_loop:
    xor edx, edx
    div r9
    dec r8
    add dl, '0'
    mov [r8], dl
    test rax, rax
    jnz .sqa_loop
.sqa_copy:
    mov al, [r8]
    mov [rdi], al
    test al, al
    jz .sqa_done
    inc r8
    inc rdi
    jmp .sqa_copy
.sqa_done:
    mov rax, rdi
    leave
    ret
END_FUNC ssq_append_i64

DEF_FUNC structseq_init_type
    ; Not an acceptable base.  CPython's PyStructSequence_InitType2 asks for no
    ; Py_TPFLAGS_BASETYPE, so none of these twelve can be subclassed there, and
    ; all twelve could be here.  What came out was not merely something CPython
    ; would not have let you make: the subclass has no STRUCTSEQ_DESC word of
    ; its own and type_from_parts zero-fills it, so structseq_getattr and
    ; structseq_dealloc read a NULL desc off the instance.
    ;
    ; Set here rather than in the twelve tables because every one of them
    ; passes through this function at start-up -- and TYPE_FLAG_FINAL is the
    ; INVERSE of CPython's flag, so this is one line rather than an audit.
    ; type_cpython_flags already reports CPY_TPFLAGS_BASETYPE from the absence
    ; of FINAL, so __flags__ comes right with it.
    or qword [rdi + PyTypeObject.tp_flags], TYPE_FLAG_FINAL
    lea rax, [rel tuple_type]
    mov [rdi + PyTypeObject.tp_base], rax
    ; tp_new, so that type_call does not fall through to tuple's -- which
    ; allocates with a GC header this family's dealloc does not expect.
    lea rcx, [rel structseq_type_new]
    mov [rdi + PyTypeObject.tp_new], rcx
    mov rcx, [rax + PyTypeObject.tp_iter]
    mov [rdi + PyTypeObject.tp_iter], rcx
    mov rcx, [rax + PyTypeObject.tp_hash]
    mov [rdi + PyTypeObject.tp_hash], rcx
    mov rcx, [rax + PyTypeObject.tp_richcompare]
    mov [rdi + PyTypeObject.tp_richcompare], rcx
    mov rcx, [rax + PyTypeObject.tp_as_sequence]
    mov [rdi + PyTypeObject.tp_as_sequence], rcx
    mov rcx, [rax + PyTypeObject.tp_as_mapping]
    mov [rdi + PyTypeObject.tp_as_mapping], rcx
    leave
    ret
END_FUNC structseq_init_type

;; ============================================================================
;; sys.version_info -- the first struct sequence, and the one that proves the
;; mechanism.  It was a bare 5-tuple, so .major was an AttributeError and
;; type(sys.version_info).__name__ was 'tuple'.
;; ============================================================================
section .rodata

ssq_takes:         db "() takes a ", 0
ssq_takes_atleast: db "() takes an at least ", 0
ssq_takes_atmost:  db "() takes an at most ", 0
ssq_seq_open:  db "-sequence (", 0
ssq_seq_close: db "-sequence given)", 0

section .bss
ssq_msgbuf: resb 192
ssq_numbuf: resb 32

section .rodata

vi_name:        db "sys.version_info", 0
vi_f_major:     db "major", 0
vi_f_minor:     db "minor", 0
vi_f_micro:     db "micro", 0
vi_f_release:   db "releaselevel", 0
vi_f_serial:    db "serial", 0

align 8
vi_fields:
    dq vi_f_major,   0
    dq vi_f_minor,   1
    dq vi_f_micro,   2
    dq vi_f_release, 3
    dq vi_f_serial,  4

align 8
vi_desc:
    dq 5                        ; n_in_sequence
    dq 5                        ; n_fields
    dq vi_fields

section .data
align 8
global version_info_type
version_info_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq vi_name                  ; tp_name -- the full dotted name, as CPython's
    dq PyTupleObject_size       ; tp_basicsize: no named-only tail
    dq structseq_dealloc        ; tp_dealloc (NOT tuple's: it pools by size)
    dq structseq_repr           ; tp_repr
    dq structseq_repr           ; tp_str
    dq 0                        ; tp_hash          } all four copied from
    dq 0                        ; tp_call          } tuple_type by
    dq structseq_getattr        ; tp_getattr       } structseq_init_type,
    dq 0                        ; tp_setattr       } which must run first
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_TUPLE_SUBCLASS ; tp_flags -- no HAVE_GC: it owns no cycles
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
    dq vi_desc                  ; STRUCTSEQ_DESC, one qword past the type

;; ============================================================================
;; sys.asyncgen_hooks -- what sys.get_asyncgen_hooks() answers with
;;
;; PEP 525's pair.  It has to be a struct sequence rather than a namespace
;; because CPython's own event loop restores it by splatting --
;; `sys.set_asyncgen_hooks(*old_agen_hooks)` -- while reading the halves by
;; name elsewhere, so it must be BOTH a two-tuple and named.
;; ============================================================================
section .rodata

agh_name:       db "asyncgen_hooks", 0
agh_f_first:    db "firstiter", 0
agh_f_final:    db "finalizer", 0

align 8
agh_fields:
    dq agh_f_first, 0
    dq agh_f_final, 1

align 8
agh_desc:
    dq 2                        ; n_in_sequence
    dq 2                        ; n_fields
    dq agh_fields

section .data
align 8
global asyncgen_hooks_type
asyncgen_hooks_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq agh_name                 ; tp_name
    dq PyTupleObject_size       ; tp_basicsize: no named-only tail
    dq structseq_dealloc        ; tp_dealloc
    dq structseq_repr           ; tp_repr
    dq structseq_repr           ; tp_str
    dq 0                        ; tp_hash          } copied from tuple_type
    dq 0                        ; tp_call          } by structseq_init_type,
    dq structseq_getattr        ; tp_getattr       } which must run first
    dq 0                        ; tp_setattr       }
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_TUPLE_SUBCLASS ; tp_flags -- no HAVE_GC: it owns no cycles
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
    dq agh_desc                 ; STRUCTSEQ_DESC, one qword past the type

;; ============================================================================
;; sys.UnraisableHookArgs -- what sys.unraisablehook is handed
;;
;; Five fields, in CPython's order.  err_msg is always None here: it is the
;; string CPython puts in front of "Exception ignored", and the two callers --
;; a __del__ and a generator being finalised -- both use the plain form.
;; ============================================================================
section .rodata
uh_name:        db "UnraisableHookArgs", 0
uh_f_type:      db "exc_type", 0
uh_f_value:     db "exc_value", 0
uh_f_tb:        db "exc_traceback", 0
uh_f_errmsg:    db "err_msg", 0
uh_f_object:    db "object", 0

align 8
uh_fields:
    dq uh_f_type,   0
    dq uh_f_value,  1
    dq uh_f_tb,     2
    dq uh_f_errmsg, 3
    dq uh_f_object, 4

align 8
uh_desc:
    dq 5                        ; n_in_sequence
    dq 5                        ; n_fields
    dq uh_fields

section .data
align 8
global unraisable_args_type
unraisable_args_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq uh_name                  ; tp_name
    dq PyTupleObject_size       ; tp_basicsize: no named-only tail
    dq structseq_dealloc        ; tp_dealloc
    dq structseq_repr           ; tp_repr
    dq structseq_repr           ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq structseq_getattr        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_TUPLE_SUBCLASS ; tp_flags
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
    dq uh_desc                  ; STRUCTSEQ_DESC, one qword past the type

section .text

;; ============================================================================
;; sys.float_info, sys.int_info and sys.hash_info.  All three were absent --
;; sysmod.asm carried "Skip for now" where each should have been -- and the
;; numeric stdlib reads them.  Their values are filled in by sys_module_init.
;; ============================================================================

;; sys.float_info
section .rodata

float_info_name: db "sys.float_info", 0
float_info_f0: db "max", 0
float_info_f1: db "max_exp", 0
float_info_f2: db "max_10_exp", 0
float_info_f3: db "min", 0
float_info_f4: db "min_exp", 0
float_info_f5: db "min_10_exp", 0
float_info_f6: db "dig", 0
float_info_f7: db "mant_dig", 0
float_info_f8: db "epsilon", 0
float_info_f9: db "radix", 0
float_info_f10: db "rounds", 0

align 8
float_info_fields:
    dq float_info_f0, 0
    dq float_info_f1, 1
    dq float_info_f2, 2
    dq float_info_f3, 3
    dq float_info_f4, 4
    dq float_info_f5, 5
    dq float_info_f6, 6
    dq float_info_f7, 7
    dq float_info_f8, 8
    dq float_info_f9, 9
    dq float_info_f10, 10

align 8
float_info_desc:
    dq 11
    dq 11
    dq float_info_fields

section .data
align 8
global float_info_type
float_info_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq float_info_name          ; tp_name
    dq PyTupleObject_size       ; tp_basicsize: no named-only tail
    dq structseq_dealloc        ; tp_dealloc
    dq structseq_repr           ; tp_repr
    dq structseq_repr           ; tp_str
    dq 0                        ; tp_hash          } copied from tuple_type by
    dq 0                        ; tp_call          } structseq_init_type, which
    dq structseq_getattr        ; tp_getattr       } must run first
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_TUPLE_SUBCLASS ; tp_flags -- no HAVE_GC
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
    dq float_info_desc          ; STRUCTSEQ_DESC, one qword past the type

;; sys.int_info
section .rodata

int_info_name: db "sys.int_info", 0
int_info_f0: db "bits_per_digit", 0
int_info_f1: db "sizeof_digit", 0
int_info_f2: db "default_max_str_digits", 0
int_info_f3: db "str_digits_check_threshold", 0

align 8
int_info_fields:
    dq int_info_f0, 0
    dq int_info_f1, 1
    dq int_info_f2, 2
    dq int_info_f3, 3

align 8
int_info_desc:
    dq 4
    dq 4
    dq int_info_fields

section .data
align 8
global int_info_type
int_info_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq int_info_name            ; tp_name
    dq PyTupleObject_size       ; tp_basicsize: no named-only tail
    dq structseq_dealloc        ; tp_dealloc
    dq structseq_repr           ; tp_repr
    dq structseq_repr           ; tp_str
    dq 0                        ; tp_hash          } copied from tuple_type by
    dq 0                        ; tp_call          } structseq_init_type, which
    dq structseq_getattr        ; tp_getattr       } must run first
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_TUPLE_SUBCLASS ; tp_flags -- no HAVE_GC
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
    dq int_info_desc            ; STRUCTSEQ_DESC, one qword past the type

;; sys.hash_info
section .rodata

hash_info_name: db "sys.hash_info", 0
hash_info_f0: db "width", 0
hash_info_f1: db "modulus", 0
hash_info_f2: db "inf", 0
hash_info_f3: db "nan", 0
hash_info_f4: db "imag", 0
hash_info_f5: db "algorithm", 0
hash_info_f6: db "hash_bits", 0
hash_info_f7: db "seed_bits", 0
hash_info_f8: db "cutoff", 0

align 8
hash_info_fields:
    dq hash_info_f0, 0
    dq hash_info_f1, 1
    dq hash_info_f2, 2
    dq hash_info_f3, 3
    dq hash_info_f4, 4
    dq hash_info_f5, 5
    dq hash_info_f6, 6
    dq hash_info_f7, 7
    dq hash_info_f8, 8

align 8
hash_info_desc:
    dq 9
    dq 9
    dq hash_info_fields

section .data
align 8
global hash_info_type
hash_info_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq hash_info_name           ; tp_name
    dq PyTupleObject_size       ; tp_basicsize: no named-only tail
    dq structseq_dealloc        ; tp_dealloc
    dq structseq_repr           ; tp_repr
    dq structseq_repr           ; tp_str
    dq 0                        ; tp_hash          } copied from tuple_type by
    dq 0                        ; tp_call          } structseq_init_type, which
    dq structseq_getattr        ; tp_getattr       } must run first
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_TUPLE_SUBCLASS ; tp_flags -- no HAVE_GC
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
    dq hash_info_desc           ; STRUCTSEQ_DESC, one qword past the type

section .rodata
align 8
global float_info_v0
float_info_v0: dq 0x7FEFFFFFFFFFFFFF    ; 1.7976931348623157e+308
global float_info_v3
float_info_v3: dq 0x0010000000000000    ; 2.2250738585072014e-308
global float_info_v8
float_info_v8: dq 0x3CB0000000000000    ; 2.220446049250313e-16
global hash_info_v5
hash_info_v5: db "fnv", 0

;; ============================================================================
;; sys.thread_info.  Three fields, as CPython's is, and the name is the honest
;; one: `pthread-stubs` is what CPython itself reports for a build whose
;; threads do not start, which is exactly what lib/_thread.py is.  `lock` and
;; `version` are None, which is also CPython's answer when there is nothing to
;; name -- and what makes test_os's and test_threadsignals' `if
;; sys.thread_info.version` guards fall the right way.
;; ============================================================================
section .rodata

thread_info_name: db "sys.thread_info", 0
thread_info_f0: db "name", 0
thread_info_f1: db "lock", 0
thread_info_f2: db "version", 0
global thread_info_v0
thread_info_v0: db "pthread-stubs", 0

align 8
thread_info_fields:
    dq thread_info_f0, 0
    dq thread_info_f1, 1
    dq thread_info_f2, 2

align 8
thread_info_desc:
    dq 3
    dq 3
    dq thread_info_fields

section .data
align 8
global thread_info_type
thread_info_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq thread_info_name         ; tp_name
    dq PyTupleObject_size       ; tp_basicsize: no named-only tail
    dq structseq_dealloc        ; tp_dealloc
    dq structseq_repr           ; tp_repr
    dq structseq_repr           ; tp_str
    dq 0                        ; tp_hash          } copied from tuple_type by
    dq 0                        ; tp_call          } structseq_init_type, which
    dq structseq_getattr        ; tp_getattr       } must run first
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_TUPLE_SUBCLASS ; tp_flags -- no HAVE_GC
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
    dq thread_info_desc         ; STRUCTSEQ_DESC, one qword past the type

section .rodata

;; ============================================================================
;; sys.flags.  _pyio reads sys.flags.utf8_mode and .dev_mode at module level,
;; so without it the module could not be imported at all.  The values are the
;; ones that describe this interpreter, not CPython's defaults copied over:
;; hash_randomization is 0 because str_hash is an unseeded FNV-1a, and
;; int_max_str_digits matches what sys.get_int_max_str_digits() reports.
;; ============================================================================

;; sys.flags
section .rodata

flags_name: db "sys.flags", 0
flags_f0: db "debug", 0
flags_f1: db "inspect", 0
flags_f2: db "interactive", 0
flags_f3: db "optimize", 0
flags_f4: db "dont_write_bytecode", 0
flags_f5: db "no_user_site", 0
flags_f6: db "no_site", 0
flags_f7: db "ignore_environment", 0
flags_f8: db "verbose", 0
flags_f9: db "bytes_warning", 0
flags_f10: db "quiet", 0
flags_f11: db "hash_randomization", 0
flags_f12: db "isolated", 0
flags_f13: db "dev_mode", 0
flags_f14: db "utf8_mode", 0
flags_f15: db "warn_default_encoding", 0
flags_f16: db "safe_path", 0
flags_f17: db "int_max_str_digits", 0

align 8
flags_fields:
    dq flags_f0, 0
    dq flags_f1, 1
    dq flags_f2, 2
    dq flags_f3, 3
    dq flags_f4, 4
    dq flags_f5, 5
    dq flags_f6, 6
    dq flags_f7, 7
    dq flags_f8, 8
    dq flags_f9, 9
    dq flags_f10, 10
    dq flags_f11, 11
    dq flags_f12, 12
    dq flags_f13, 13
    dq flags_f14, 14
    dq flags_f15, 15
    dq flags_f16, 16
    dq flags_f17, 17

align 8
flags_desc:
    dq 18
    dq 18
    dq flags_fields

section .data
align 8
global flags_type
flags_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq flags_name               ; tp_name
    dq PyTupleObject_size       ; tp_basicsize
    dq structseq_dealloc        ; tp_dealloc
    dq structseq_repr           ; tp_repr
    dq structseq_repr           ; tp_str
    dq 0                        ; tp_hash          } copied from tuple_type by
    dq 0                        ; tp_call          } structseq_init_type
    dq structseq_getattr        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_TUPLE_SUBCLASS ; tp_flags
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
    dq flags_desc               ; STRUCTSEQ_DESC
