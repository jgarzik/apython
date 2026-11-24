; iter_reduce.asm - what the builtin iterators answer to pickle.
;
; CPython gives every one of its iterators a __reduce__, and pickle, copy and
; deepcopy all go through it: an object with none of its own falls back to
; copyreg's, which refuses anything it cannot rebuild from a class and a state
; dict.  So `pickle.dumps(iter([1,2,3]))` was "cannot pickle 'list_iterator'
; object" here, and so was every range, slice, Ellipsis and NotImplemented --
; 2,106 error lines over 28 of CPython's test modules, the largest single
; cluster in the sweep, and test_range was 192 of it against 28 tests.
;
; The shapes are CPython's, taken from the running interpreter rather than
; transcribed:
;
;   a sequence iterator   (iter, (seq,), index)   -- and (iter, (empty,)) once
;                                                     it_seq has been dropped
;   a range iterator      (iter, (range(current, stop, step),), None)
;   range                 (range, (start, stop, step))
;   slice                 (slice, (start, stop, step))
;   Ellipsis              'Ellipsis'
;   NotImplemented        'NotImplemented'
;
; The empty is the sequence's OWN empty -- '' for a str iterator, [] for a
; list's -- because CPython has a reduce per iterator type and each builds its
; own.  A str iterator's index is a CODE POINT index there and a byte index
; here, so that one is converted; for ASCII, which is the common case, the two
; are equal and the conversion is a compare.
;
; __setstate__ is the other half: pickle applies it after rebuilding, and a
; program can call it directly.  CPython clamps rather than refusing -- a
; negative index means the start and one past the end means exhausted -- and
; so does this.

%include "macros.inc"
%include "object.inc"
%include "value.inc"

extern eval_exception_unwind
extern int_from_i64
extern tuple_new
extern list_new
extern str_new_heap
extern bytes_new
extern bytearray_new
extern obj_incref
extern obj_decref
extern obj_as_index
extern dict_get
extern str_from_cstr_heap
extern builtins_dict_global
extern str_byte_to_cp
extern str_cp_offset
extern str_iter_type
extern str_type
extern none_singleton
extern exc_TypeError_type
extern raise_exception
extern range_new
extern range_new_v
extern range_obj_type
extern slice_type
extern range_iter_type
extern longrange_iter_type

section .text

;; ============================================================================
;; ir_iter_builtin() -> rax = the `iter` builtin object, borrowed, or 0
;;
;; Every sequence and mapping iterator names `iter` as the callable half of its
;; reduce, so it is looked up once and kept.  Borrowed: builtins holds it for
;; the life of the interpreter.
;; ============================================================================
IIB_DICT  equ 8
IIB_NAME  equ 16
IIB_FRAME equ 16            ; 0 pushes, 16-aligned
DEF_FUNC ir_iter_builtin, IIB_FRAME
    mov rax, [rel ir_iter_cached]
    test rax, rax
    jnz .iib_done
    mov rdi, [rel builtins_dict_global]
    test rdi, rdi
    jz .iib_none
    ; Frame slots rather than pushes: a lone push before each of these three
    ; calls left every one of them eight bytes out, and a misaligned call
    ; propagates into everything beneath it -- obj_decref reaches obj_dealloc
    ; and ap_free.
    mov [rbp - IIB_DICT], rdi
    CSTRING rdi, "iter"
    call str_from_cstr_heap
    mov [rbp - IIB_NAME], rax
    mov rdi, [rbp - IIB_DICT]
    mov rsi, rax
    call dict_get
    mov [rbp - IIB_DICT], rax   ; the answer, borrowed from builtins
    mov rdi, [rbp - IIB_NAME]
    call obj_decref             ; the name
    mov rax, [rbp - IIB_DICT]
    test rax, rax
    jz .iib_none
    mov [rel ir_iter_cached], rax
.iib_done:
    leave
    ret
.iib_none:
    xor eax, eax
    leave
    ret
END_FUNC ir_iter_builtin

;; ============================================================================
;; ir_reduce_tuple(rdi = callable, rsi = args tuple (reference taken),
;;                 rdx = state Value, rcx = 1 when there IS a state)
;;   -> rax = the reduce tuple as a Value, or 0
;;
;; A two-tuple when there is no state and a three-tuple when there is, which is
;; exactly the difference pickle reads: a state is passed to __setstate__ and
;; an absent one is not.  None is a real state for a range iterator, so the
;; presence flag is separate from the value.
;; ============================================================================
IRT_CALL  equ 8
IRT_ARGS  equ 16
IRT_STATE equ 24
IRT_HAVE  equ 32
IRT_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC ir_reduce_tuple, IRT_FRAME
    push rbx
    mov [rbp - IRT_CALL], rdi
    mov [rbp - IRT_ARGS], rsi
    mov [rbp - IRT_STATE], rdx
    mov [rbp - IRT_HAVE], rcx

    mov edi, 2
    cmp qword [rbp - IRT_HAVE], 0
    je .irt_have_size
    mov edi, 3
.irt_have_size:
    call tuple_new
    test rax, rax
    jz .irt_fail
    mov rbx, rax

    mov rax, [rbp - IRT_CALL]
    mov rdi, rax
    call obj_incref
    mov rcx, [rbx + PyTupleObject.ob_item]
    mov rax, [rbp - IRT_CALL]
    mov [rcx], rax
    mov rax, [rbp - IRT_ARGS]   ; the args tuple's reference is taken
    mov [rcx + 8], rax

    cmp qword [rbp - IRT_HAVE], 0
    je .irt_done
    mov rdi, [rbp - IRT_STATE]
    INCREF_V rdi, rdx
    mov rcx, [rbx + PyTupleObject.ob_item]
    mov rax, [rbp - IRT_STATE]
    mov [rcx + 16], rax
.irt_done:
    mov rax, rbx
    pop rbx
    leave
    ret
.irt_fail:
    ; The args tuple's reference was taken on the way in, so failing to build
    ; the outer tuple has to release it -- a caller that reads 0 as "it raised"
    ; has already handed ownership over and will not free it.
    mov rdi, [rbp - IRT_ARGS]
    call obj_decref             ; NULL-safe, and always a real tuple
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ir_reduce_tuple

;; ============================================================================
;; ir_one_tuple(rdi = a Value; the reference is TAKEN) -> rax = (value,), or 0
;; ============================================================================
IO1_VAL   equ 8
IO1_FRAME equ 16            ; 0 pushes, 16-aligned
DEF_FUNC ir_one_tuple, IO1_FRAME
    mov [rbp - IO1_VAL], rdi
    mov edi, 1
    call tuple_new
    test rax, rax
    jz .io1_done
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbp - IO1_VAL]
    mov [rcx], rdx
.io1_done:
    leave
    ret
END_FUNC ir_one_tuple

;; ============================================================================
;; seqiter_reduce_core(rdi = the iterator, rsi = a maker for this sequence's
;;                     own empty, edx = 1 when it_index counts BYTES)
;;   -> rax = the reduce tuple Value, or 0
;;
;; The shared body of every sequence iterator's __reduce__.  Once it_seq has
;; been dropped -- which next() does at exhaustion, as CPython's does -- there
;; is no sequence left to name, and CPython answers with the type's own empty
;; and no state at all.
;; ============================================================================
SRC_SELF  equ 8
SRC_EMPTY equ 16
SRC_BYTES equ 24
SRC_ARGS  equ 32
SRC_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC seqiter_reduce_core, SRC_FRAME
    push rbx
    mov [rbp - SRC_SELF], rdi
    mov [rbp - SRC_EMPTY], rsi
    mov [rbp - SRC_BYTES], rdx

    call ir_iter_builtin
    test rax, rax
    jz .src_fail
    mov rbx, rax                ; rbx = the `iter` builtin, borrowed

    mov rdi, [rbp - SRC_SELF]
    mov rdi, [rdi + PyListIterObject.it_seq]
    test rdi, rdi
    jz .src_exhausted

    ; (iter, (seq,), index)
    call obj_incref
    mov rdi, [rbp - SRC_SELF]
    mov rdi, [rdi + PyListIterObject.it_seq]
    call ir_one_tuple
    test rax, rax
    jz .src_fail
    mov [rbp - SRC_ARGS], rax

    mov rdi, [rbp - SRC_SELF]
    mov rdx, [rdi + PyListIterObject.it_index]
    cmp qword [rbp - SRC_BYTES], 0
    je .src_have_index
    ; A str iterator counts bytes and CPython counts code points.  They are
    ; equal for an ASCII string, which str_byte_to_cp settles with a compare.
    mov rdi, [rdi + PyListIterObject.it_seq]
    mov rsi, rdx
    call str_byte_to_cp
    mov rdx, rax
.src_have_index:
    V_PACK_I64 rdx, rcx
    mov rdi, rbx
    mov rsi, [rbp - SRC_ARGS]
    mov ecx, 1
    call ir_reduce_tuple
    pop rbx
    leave
    ret

.src_exhausted:
    ; (iter, (empty,)) -- no state, and the sequence's own empty.
    mov rax, [rbp - SRC_EMPTY]
    call rax
    test rax, rax
    jz .src_fail
    mov rdi, rax
    call ir_one_tuple
    test rax, rax
    jz .src_fail
    mov rdi, rbx
    mov rsi, rax
    xor edx, edx
    xor ecx, ecx
    call ir_reduce_tuple
    pop rbx
    leave
    ret

.src_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC seqiter_reduce_core

;; ============================================================================
;; The per-type empties.  Each answers a NEW object where the type is mutable
;; and may answer a shared one where it is not; tuple_new(0), list_new(0),
;; str_new_heap("", 0), bytes_new(0) and bytearray_new(0, 0) all do the right
;; thing for their own type.
;;
;; ir_empty_list() -> rax = []
;; ============================================================================
DEF_FUNC_LOCAL ir_empty_list
    xor edi, edi
    call list_new
    leave
    ret
END_FUNC ir_empty_list

;; ir_empty_tuple() -> rax = ()
DEF_FUNC_LOCAL ir_empty_tuple
    xor edi, edi
    call tuple_new
    leave
    ret
END_FUNC ir_empty_tuple

;; ir_empty_str() -> rax = ''
DEF_FUNC_LOCAL ir_empty_str
    CSTRING rdi, ""
    xor esi, esi
    call str_new_heap
    leave
    ret
END_FUNC ir_empty_str

;; ir_empty_bytes() -> rax = b''
DEF_FUNC_LOCAL ir_empty_bytes
    xor edi, edi
    call bytes_new
    leave
    ret
END_FUNC ir_empty_bytes

;; ir_empty_bytearray() -> rax = bytearray(b'')
DEF_FUNC_LOCAL ir_empty_bytearray
    xor edi, edi
    xor esi, esi
    call bytearray_new
    leave
    ret
END_FUNC ir_empty_bytearray

;; ============================================================================
;; The five sequence iterators' __reduce__, as builtin methods: each takes
;; (args Value[], nargs) and answers one Value.
;; ============================================================================
%macro DEF_SEQITER_REDUCE 3     ; %1 = name prefix, %2 = empty maker, %3 = bytes?
global %1_reduce
DEF_FUNC %1_reduce
    test rsi, rsi
    jz %%noarg
    mov rdi, [rdi]
    lea rsi, [rel %2]
    mov edx, %3
    call seqiter_reduce_core
    leave
    ret
%%noarg:
    RAISE exc_TypeError_type, "__reduce__() takes exactly one argument"
END_FUNC %1_reduce
%endmacro

DEF_SEQITER_REDUCE list_iter,      ir_empty_list,      0
DEF_SEQITER_REDUCE tuple_iter,     ir_empty_tuple,     0
DEF_SEQITER_REDUCE str_iter,       ir_empty_str,       1
DEF_SEQITER_REDUCE bytes_iter,     ir_empty_bytes,     0
DEF_SEQITER_REDUCE bytearray_iter, ir_empty_bytearray, 0

;; ============================================================================
;; seqiter_setstate(rdi = args Value[], rsi = nargs) -> rax = None
;;
;; Shared by all five.  CPython clamps rather than refusing: below zero is the
;; start, past the end is exhausted.  The index is left in the iterator's own
;; units, which for a str iterator means converting a code-point index back to
;; a byte one -- and since the state a __reduce__ hands out is a code-point
;; index, the two have to agree.
;; ============================================================================
SSS_SELF  equ 8
SSS_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC seqiter_setstate, SSS_FRAME
    push rbx
    cmp rsi, 2
    jl .sss_args
    mov rbx, [rdi]              ; the iterator
    mov rdi, [rdi + 8]          ; the state
    V_UNPACK rdi, rdx           ; obj_as_index still takes (payload, tag)
    call obj_as_index
    ERR_M1_JUMP
    ; obj_as_index raises for anything that is not an index, so rax is one.
    test rax, rax
    jns .sss_clamp_low
    xor eax, eax
.sss_clamp_low:
    mov rdi, [rbx + PyListIterObject.it_seq]
    test rdi, rdi
    jz .sss_done                ; already exhausted: nothing to point into
    mov rdx, [rbx + PyObject.ob_type]
    lea rcx, [rel str_iter_type]
    cmp rdx, rcx
    jne .sss_store
    ; A str iterator: the state counts code points and it_index counts bytes.
    mov rsi, rax
    call str_cp_offset
.sss_store:
    mov [rbx + PyListIterObject.it_index], rax
.sss_done:
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    pop rbx
    leave
    ret
.sss_args:
    RAISE exc_TypeError_type, "__setstate__() takes exactly one argument"
END_FUNC seqiter_setstate

;; ============================================================================
;; seqiter_length_hint(rdi = args Value[], rsi = nargs) -> rax = an int Value
;;
;; How many are left, which is what operator.length_hint asks for and what
;; list() uses to size itself.  Never negative: an index past the end is an
;; exhausted iterator, and CPython answers 0 for one.
;; ============================================================================
SLH_SELF  equ 8
SLH_FRAME equ 16            ; 0 pushes, 16-aligned
DEF_FUNC seqiter_length_hint, SLH_FRAME
    test rsi, rsi
    jz .slh_args
    mov rdi, [rdi]
    mov [rbp - SLH_SELF], rdi
    mov rcx, [rdi + PyListIterObject.it_seq]
    test rcx, rcx
    jz .slh_zero

    ; A str counts CODE POINTS and its iterator counts bytes, so both halves
    ; of the subtraction have to be in the same units.  Every other sequence
    ; here keeps its length in ob_size and indexes it directly.
    mov rdx, [rdi + PyObject.ob_type]
    lea rax, [rel str_iter_type]
    cmp rdx, rax
    je .slh_str
    mov rax, [rcx + PyListObject.ob_size]
    sub rax, [rdi + PyListIterObject.it_index]
    jmp .slh_check

.slh_str:
    mov rsi, [rdi + PyListIterObject.it_index]
    mov rdi, rcx
    push rcx
    push rcx
    call str_byte_to_cp
    pop rcx
    pop rcx
    mov rdx, [rcx + PyStrObject.ob_length]
    sub rdx, rax
    mov rax, rdx

.slh_check:
    test rax, rax
    jns .slh_have
.slh_zero:
    xor eax, eax
.slh_have:
    V_PACK_I64 rax, rcx
    leave
    ret
.slh_args:
    RAISE exc_TypeError_type, "__length_hint__() takes exactly one argument"
END_FUNC seqiter_length_hint


;; ============================================================================
;; ir_getattr_builtin() -> rax = the `getattr` builtin, borrowed, or 0
;;
;; A BOUND callable reduces to (getattr, (receiver, name)) -- that is how
;; CPython pickles both a bound method and a bound builtin, and it is the only
;; reduction that can name something reachable only through an object.
;; ============================================================================
IGB_DICT  equ 8
IGB_NAME  equ 16
IGB_FRAME equ 16            ; 0 pushes, 16-aligned
DEF_FUNC ir_getattr_builtin, IGB_FRAME
    mov rax, [rel ir_getattr_cached]
    test rax, rax
    jnz .igb_done
    mov rdi, [rel builtins_dict_global]
    test rdi, rdi
    jz .igb_none
    mov [rbp - IGB_DICT], rdi   ; slots, not pushes: see ir_iter_builtin
    CSTRING rdi, "getattr"
    call str_from_cstr_heap
    mov [rbp - IGB_NAME], rax
    mov rdi, [rbp - IGB_DICT]
    mov rsi, rax
    call dict_get
    mov [rbp - IGB_DICT], rax
    mov rdi, [rbp - IGB_NAME]
    call obj_decref
    mov rax, [rbp - IGB_DICT]
    test rax, rax
    jz .igb_none
    mov [rel ir_getattr_cached], rax
.igb_done:
    leave
    ret
.igb_none:
    xor eax, eax
    leave
    ret
END_FUNC ir_getattr_builtin

;; ============================================================================
;; ir_bound_reduce(rdi = the receiver Value, rsi = the name str (borrowed))
;;   -> rax = (getattr, (receiver, name)), or 0
;; ============================================================================
IBR_SELF  equ 8
IBR_NAME  equ 16
IBR_ARGS  equ 24
IBR_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC ir_bound_reduce, IBR_FRAME
    push rbx
    mov [rbp - IBR_SELF], rdi
    mov [rbp - IBR_NAME], rsi

    call ir_getattr_builtin
    test rax, rax
    jz .ibr_fail
    mov rbx, rax

    mov edi, 2
    call tuple_new
    test rax, rax
    jz .ibr_fail
    mov [rbp - IBR_ARGS], rax
    mov rdi, [rbp - IBR_SELF]
    INCREF_V rdi, rdx
    mov rdi, [rbp - IBR_NAME]
    call obj_incref
    mov rax, [rbp - IBR_ARGS]
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbp - IBR_SELF]
    mov [rcx], rdx
    mov rdx, [rbp - IBR_NAME]
    mov [rcx + 8], rdx

    mov rdi, rbx
    mov rsi, [rbp - IBR_ARGS]
    xor edx, edx
    xor ecx, ecx
    call ir_reduce_tuple
    pop rbx
    leave
    ret
.ibr_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ir_bound_reduce

;; ============================================================================
;; builtin_func_reduce(rdi = args Value[], rsi = nargs) -> rax = a Value
;;
;; CPython's meth_reduce: an UNBOUND builtin reduces to its own name, which
;; pickle then saves as a global lookup, and a bound one to
;; (getattr, (receiver, name)).  Without it, pickling anything that reached a
;; builtin -- including the `iter` every iterator's own reduce names -- was
;; "Can't pickle <class 'builtin_function_or_method'>".
;; ============================================================================
DEF_FUNC builtin_func_reduce
    test rsi, rsi
    jz .bfr_args
    mov rdi, [rdi]
    ; A DESCRIPTOR reduces through the class it was found on.  CPython has a
    ; separate descr_reduce for method_descriptor and wrapper_descriptor --
    ; (getattr, (__objclass__, __name__)) -- and meth_reduce, the bare name,
    ; is for a MODULE-level builtin.  One function answered the bare name for
    ; every kind here, so pickle went looking for str.count under __main__
    ; and said "it's not found as __main__.count"; test_pickle, test_descr
    ; and test_functools carried about a hundred and eighty of those.
    mov rcx, [rdi + PyBuiltinObject.func_kind]
    cmp rcx, BUILTIN_KIND_METHOD
    je .bfr_descr
    cmp rcx, BUILTIN_KIND_WRAPPER
    je .bfr_descr
    cmp rcx, BUILTIN_KIND_ON_TYPE
    je .bfr_descr               ; int.__new__: its owner is its __self__ too
    mov rax, [rdi + PyBuiltinObject.func_name]
    mov rdi, rax
    call obj_incref
    leave
    ret
.bfr_descr:
    mov rax, [rdi + PyBuiltinObject.func_owner]
    test rax, rax
    jz .bfr_plain               ; unstamped: nothing to name it by
    mov rsi, [rdi + PyBuiltinObject.func_name]
    mov rdi, rax
    call ir_bound_reduce
    test rax, rax
    jz .bfr_failed
    leave
    ret
.bfr_plain:
    mov rax, [rdi + PyBuiltinObject.func_name]
    mov rdi, rax
    call obj_incref
    leave
    ret
.bfr_failed:
    xor eax, eax
    xor edx, edx
    leave
    ret
.bfr_args:
    RAISE exc_TypeError_type, "__reduce__() takes exactly one argument"
END_FUNC builtin_func_reduce

;; ============================================================================
;; method_reduce(rdi = args Value[], rsi = nargs) -> rax = a Value
;;
;; A bound method -- which in this tree is also what a bound BUILTIN is, the
;; divergence DIVERGENCES.md records -- reduces to (getattr, (self, name)),
;; exactly as CPython's method_reduce does.  It is the second largest cluster
;; in the pickle sweep after the iterators: anything holding a bound method,
;; which is most callbacks, could not be pickled at all.
;; ============================================================================
MTR_SELF  equ 8
MTR_FRAME equ 16            ; 0 pushes, 16-aligned
DEF_FUNC method_reduce, MTR_FRAME
    test rsi, rsi
    jz .mtr_args
    mov rdi, [rdi]
    mov [rbp - MTR_SELF], rdi
    mov rax, [rdi + PyMethodObject.im_func]
    V_TEST_PTR rax, rcx
    ja .mtr_unnamed
    ; The name is the function's own __name__: a PyFuncObject keeps it in
    ; func_name and a builtin in func_name too, at different offsets, so the
    ; type decides which.
    extern func_type
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel func_type]
    cmp rcx, rdx
    jne .mtr_builtin
    mov rsi, [rax + PyFuncObject.func_name]
    jmp .mtr_have_name
.mtr_builtin:
    extern builtin_func_type
    lea rdx, [rel builtin_func_type]
    cmp rcx, rdx
    jne .mtr_unnamed
    mov rsi, [rax + PyBuiltinObject.func_name]
.mtr_have_name:
    test rsi, rsi
    jz .mtr_unnamed
    mov rdi, [rbp - MTR_SELF]
    mov rdi, [rdi + PyMethodObject.im_self]
    call ir_bound_reduce
    leave
    ret
.mtr_unnamed:
    ; Nothing to name it by; let the generic reduction refuse it, as CPython's
    ; does for a method whose function has no __name__.
    RAISE exc_TypeError_type, "cannot pickle this method"
.mtr_args:
    RAISE exc_TypeError_type, "__reduce__() takes exactly one argument"
END_FUNC method_reduce


;; ============================================================================
;; ir_three_tuple(rdi = a, rsi = b, rdx = c -- three Values, references taken)
;;   -> rax = (a, b, c), or 0
;; ============================================================================
IT3_A     equ 8
IT3_B     equ 16
IT3_C     equ 24
IT3_FRAME equ 32            ; 0 pushes, 16-aligned
DEF_FUNC ir_three_tuple, IT3_FRAME
    mov [rbp - IT3_A], rdi
    mov [rbp - IT3_B], rsi
    mov [rbp - IT3_C], rdx
    mov edi, 3
    call tuple_new
    test rax, rax
    jz .it3_done
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbp - IT3_A]
    mov [rcx], rdx
    mov rdx, [rbp - IT3_B]
    mov [rcx + 8], rdx
    mov rdx, [rbp - IT3_C]
    mov [rcx + 16], rdx
.it3_done:
    leave
    ret
END_FUNC ir_three_tuple

;; ============================================================================
;; range_reduce(rdi = args Value[], rsi = nargs) -> rax = (range, (a, b, c))
;;
;; CPython's range_reduce.  The three bounds are the Values a range already
;; keeps beside its int64s, so a wide range reduces as exactly as a narrow one.
;; ============================================================================
RGR_ARGS  equ 8
RGR_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC range_reduce, RGR_FRAME
    push rbx
    test rsi, rsi
    jz .rgr_args
    mov rbx, [rdi]              ; the range

    mov rdi, [rbx + PyRangeObject.vstart]
    INCREF_V rdi, rdx
    mov rsi, [rbx + PyRangeObject.vstop]
    INCREF_V rsi, rdx
    mov rdx, [rbx + PyRangeObject.vstep]
    INCREF_V rdx, rcx
    mov rdi, [rbx + PyRangeObject.vstart]
    mov rsi, [rbx + PyRangeObject.vstop]
    mov rdx, [rbx + PyRangeObject.vstep]
    call ir_three_tuple
    test rax, rax
    jz .rgr_fail
    mov rsi, rax
    lea rdi, [rel range_obj_type]
    xor edx, edx
    xor ecx, ecx
    call ir_reduce_tuple
    pop rbx
    leave
    ret
.rgr_fail:
    xor eax, eax
    pop rbx
    leave
    ret
.rgr_args:
    RAISE exc_TypeError_type, "__reduce__() takes exactly one argument"
END_FUNC range_reduce

;; ============================================================================
;; slice_reduce(rdi = args Value[], rsi = nargs) -> rax = (slice, (a, b, c))
;; ============================================================================
SLR_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC slice_reduce, SLR_FRAME
    push rbx
    test rsi, rsi
    jz .slr_args
    mov rbx, [rdi]

    mov rdi, [rbx + PySliceObject.start]
    INCREF_V rdi, rdx
    mov rsi, [rbx + PySliceObject.stop]
    INCREF_V rsi, rdx
    mov rdx, [rbx + PySliceObject.step]
    INCREF_V rdx, rcx
    mov rdi, [rbx + PySliceObject.start]
    mov rsi, [rbx + PySliceObject.stop]
    mov rdx, [rbx + PySliceObject.step]
    call ir_three_tuple
    test rax, rax
    jz .slr_fail
    mov rsi, rax
    lea rdi, [rel slice_type]
    xor edx, edx
    xor ecx, ecx
    call ir_reduce_tuple
    pop rbx
    leave
    ret
.slr_fail:
    xor eax, eax
    pop rbx
    leave
    ret
.slr_args:
    RAISE exc_TypeError_type, "__reduce__() takes exactly one argument"
END_FUNC slice_reduce

;; ============================================================================
;; ir_name_reduce(rdi = a C string) -> rax = that string as a str Value
;;
;; What a singleton reduces to: pickle reads a bare string as "look this name
;; up in the module the object came from", which for Ellipsis and
;; NotImplemented is builtins.
;; ============================================================================
DEF_FUNC ir_name_reduce
    call str_from_cstr_heap
    leave
    ret
END_FUNC ir_name_reduce

;; ellipsis_reduce(rdi = args Value[], rsi = nargs) -> rax = 'Ellipsis'
DEF_FUNC ellipsis_reduce
    test rsi, rsi
    jz .elr_args
    CSTRING rdi, "Ellipsis"
    call ir_name_reduce
    leave
    ret
.elr_args:
    RAISE exc_TypeError_type, "__reduce__() takes exactly one argument"
END_FUNC ellipsis_reduce

;; notimpl_reduce(rdi = args Value[], rsi = nargs) -> rax = 'NotImplemented'
DEF_FUNC notimpl_reduce
    test rsi, rsi
    jz .nir_args
    CSTRING rdi, "NotImplemented"
    call ir_name_reduce
    leave
    ret
.nir_args:
    RAISE exc_TypeError_type, "__reduce__() takes exactly one argument"
END_FUNC notimpl_reduce

;; ============================================================================
;; range_iter_reduce(rdi = args Value[], rsi = nargs)
;;   -> rax = (iter, (range(current, stop, step),), None)
;;
;; CPython hands back the REMAINING range rather than the original plus an
;; index, so an iterator half way through pickles as a fresh iterator over
;; what is left.  The state is None, which pickle skips -- __setstate__ is
;; there for a program that calls it, not for the round trip.
;; ============================================================================
RIR_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC range_iter_reduce, RIR_FRAME
    push rbx
    test rsi, rsi
    jz .rir_args
    mov rbx, [rdi]

    call ir_iter_builtin
    test rax, rax
    jz .rir_fail
    mov rdx, rax                ; the `iter` builtin

    push rdx
    push rdx
    mov rdi, [rbx + PyRangeIterObject.it_current]
    mov rsi, [rbx + PyRangeIterObject.it_stop]
    mov rdx, [rbx + PyRangeIterObject.it_step]
    call range_new
    pop rdx
    pop rdx
    test rax, rax
    jz .rir_fail
    push rdx
    push rdx
    mov rdi, rax
    call ir_one_tuple
    pop rdx
    pop rdx
    test rax, rax
    jz .rir_fail

    mov rdi, rdx                ; the `iter` builtin
    mov rsi, rax                ; (range,)
    lea rdx, [rel none_singleton]
    mov ecx, 1                  ; there IS a state, and it is None
    call ir_reduce_tuple
    pop rbx
    leave
    ret
.rir_fail:
    xor eax, eax
    pop rbx
    leave
    ret
.rir_args:
    RAISE exc_TypeError_type, "__reduce__() takes exactly one argument"
END_FUNC range_iter_reduce

;; ============================================================================
;; range_iter_length_hint(rdi = args Value[], rsi = nargs) -> rax = an int
;;
;; How many are left: (stop - current + step -+ 1) / step, floored at zero.
;; ============================================================================
DEF_FUNC range_iter_length_hint
    test rsi, rsi
    jz .rlh_args
    mov rdi, [rdi]
    mov rax, [rdi + PyRangeIterObject.it_stop]
    sub rax, [rdi + PyRangeIterObject.it_current]
    mov rcx, [rdi + PyRangeIterObject.it_step]
    test rcx, rcx
    js .rlh_negative
    ; ceil((stop - current) / step) for a positive step
    add rax, rcx
    dec rax
    cqo
    idiv rcx
    jmp .rlh_check
.rlh_negative:
    ; and for a negative one, with both signs flipped
    add rax, rcx
    inc rax
    cqo
    idiv rcx
.rlh_check:
    test rax, rax
    jns .rlh_have
    xor eax, eax
.rlh_have:
    V_PACK_I64 rax, rcx
    leave
    ret
.rlh_args:
    RAISE exc_TypeError_type, "__length_hint__() takes exactly one argument"
END_FUNC range_iter_length_hint

section .bss
ir_iter_cached: resq 1
ir_getattr_cached: resq 1

section .text

;; ============================================================================
;; dictiter_length_hint(rdi = args Value[], rsi = nargs) -> rax = an int Value
;; setiter_length_hint -- the same, over a set's narrower entries
;; dictrev_length_hint -- the same, counting DOWN
;;
;; How many entries the iterator has left.  CPython keeps a counter it
;; decrements per next(); these index a SPARSE entry table, so the answer is
;; the occupied slots between the index and the end -- O(n) where CPython's
;; is O(1), and called once, by a caller about to walk all n anyway.
;;
;; Three entry points rather than one, because the walk differs in two ways
;; that cannot be read off the object.  A set shares PyDictObject's HEADER
;; and not its entries: SET_ENTRY_SIZE is sixteen bytes where DictEntry_size
;; is twenty-four, and using the wrong stride reports a plausible wrong
;; number -- a ten-element set read as a dict answered 47.  And the
;; reversed-dict iterator starts at the end and counts DOWN, so its remaining
;; entries are the ones BELOW its index.
;; ============================================================================
DLH_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC dictiter_length_hint, DLH_FRAME
    test rsi, rsi
    jz .dlh_args
    mov rdi, [rdi]
    mov r8d, DictEntry_size
    xor r9d, r9d                        ; forward
    call dlh_count
    V_PACK rax, rdx
    leave
    ret
.dlh_args:
    RAISE exc_TypeError_type, "__length_hint__() takes exactly one argument"
END_FUNC dictiter_length_hint

;; ============================================================================
;; setiter_length_hint(rdi = args Value[], rsi = nargs) -> rax = an int Value
;; ============================================================================
DEF_FUNC setiter_length_hint, DLH_FRAME
    test rsi, rsi
    jz .slhx_args
    mov rdi, [rdi]
    mov r8d, SET_ENTRY_SIZE
    xor r9d, r9d
    call dlh_count
    V_PACK rax, rdx
    leave
    ret
.slhx_args:
    RAISE exc_TypeError_type, "__length_hint__() takes exactly one argument"
END_FUNC setiter_length_hint

;; ============================================================================
;; dictrev_length_hint(rdi = args Value[], rsi = nargs) -> rax = an int Value
;; ============================================================================
DEF_FUNC dictrev_length_hint, DLH_FRAME
    test rsi, rsi
    jz .drlh_args
    mov rdi, [rdi]
    mov r8d, DictEntry_size
    mov r9d, 1                          ; backward
    call dlh_count
    V_PACK rax, rdx
    leave
    ret
.drlh_args:
    RAISE exc_TypeError_type, "__length_hint__() takes exactly one argument"
END_FUNC dictrev_length_hint

;; ============================================================================
;; dlh_count(rdi = the iterator, r8 = the entry stride, r9 = 1 to count
;;           downward) -> rax = an int Value's payload, edx = its tag
;;
;; An entry is occupied when its key is non-zero; a tombstone leaves the hash
;; set and the key clear, so one test covers both kinds of hole.
;; ============================================================================
DEF_FUNC_LOCAL dlh_count, 16
    mov rax, [rdi + PyDictIterObject.it_dict]
    test rax, rax
    jz .dlc_zero                    ; dropped, or cleared by the collector
    mov rcx, [rdi + PyDictIterObject.it_index]
    mov rsi, [rax + PyDictObject.entries]
    test r9, r9
    jnz .dlc_back
    mov rdx, [rax + PyDictObject.capacity]
    xor r10d, r10d
.dlc_fwd:
    cmp rcx, rdx
    jge .dlc_done
    mov rax, rcx
    imul rax, r8
    add rax, rsi
    cmp qword [rax + SET_ENTRY_KEY], 0
    je .dlc_fwd_next
    inc r10
.dlc_fwd_next:
    inc rcx
    jmp .dlc_fwd

.dlc_back:
    ; The index is the next slot to VISIT, so it counts itself; an index
    ; below zero is exhaustion.
    xor r10d, r10d
.dlc_bck:
    test rcx, rcx
    js .dlc_done
    mov rax, rcx
    imul rax, r8
    add rax, rsi
    cmp qword [rax + SET_ENTRY_KEY], 0
    je .dlc_bck_next
    inc r10
.dlc_bck_next:
    dec rcx
    jmp .dlc_bck

.dlc_done:
    mov rdi, r10
    call int_from_i64
    leave
    ret
.dlc_zero:
    xor edi, edi
    call int_from_i64
    leave
    ret
END_FUNC dlh_count

;; ============================================================================
;; reversed_length_hint(rdi = args Value[], rsi = nargs) -> rax = an int Value
;;
;; A reversed iterator counts DOWN, so what is left is the index plus one --
;; and an index of -1 is exhaustion, which answers 0 rather than a negative.
;; ============================================================================
RLH_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC reversed_length_hint, RLH_FRAME
    test rsi, rsi
    jz .rlh_args
    mov rdi, [rdi]
    mov rax, [rdi + PyDictIterObject.it_index]
    inc rax
    jns .rlh_have
    xor eax, eax
.rlh_have:
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret
.rlh_args:
    RAISE exc_TypeError_type, "__length_hint__() takes exactly one argument"
END_FUNC reversed_length_hint
