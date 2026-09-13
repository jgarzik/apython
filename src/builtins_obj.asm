; builtins_obj.asm - The object, iteration and I/O builtins
;
; str(), id, hash, callable, iter/next, any/all/sum/min/max, the getattr
; family, globals/locals/vars/dir, input, open, ascii, format, aiter/anext,
; __import__ and breakpoint.  Same convention: name(args, nargs) -> PyObject*,
; args borrowed, return a new reference.

%include "macros.inc"
%include "object.inc"

; External symbols used
extern get_iterator_opt
extern int_from_i64
extern int_add
extern ap_malloc
extern ap_free
extern str_from_cstr
extern str_from_cstr_heap
extern obj_str
extern obj_repr
extern obj_is_true
extern obj_incref
extern obj_decref
extern type_is_subtype
extern raise_exception
extern dunder_name_obj
extern obj_getattr_opt
extern exc_new
extern current_exception
extern eval_exception_unwind
extern none_singleton
extern eval_saved_r12
extern obj_dealloc

extern float_type
extern str_type
extern bytes_type
extern bytearray_type
extern memoryview_type
extern bytes_type_call
extern rbt_append_cstr
extern msg_append_i64
extern value_type
extern raise_type_error_counted
extern _bytes_decode_impl
extern ba_shared_decode
extern kw_names_pending
extern ap_strcmp
extern raise_type_error_with_name
extern bool_true
extern bool_false

extern exc_TypeError_type
extern exc_ValueError_type
extern exc_AttributeError_type
extern exc_StopIteration_type
extern gen_type
extern raise_exception_obj
extern list_new
extern list_append
extern list_contains
extern dict_tp_iter
extern type_type
extern user_type_metatype
extern dict_new

; --- builtin_abs and the str() constructor moved to sibling files by the
; --- two splits this file has had.

section .text

;; ============================================================================
;; 7. builtin_id(rdi = args, rsi = nargs) - id(x)
;;   -> rax = Value
;; ============================================================================
DEF_FUNC builtin_id

    cmp rsi, 1
    jne .id_error

    V_TEST_INT_M [rdi], rax            ; args[0] an int immediate?
    mov rdi, [rdi]                     ; args[0]
    jae .id_smallint

    call int_from_i64
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.id_smallint:
    V_TO_I64 rdi
    call int_from_i64
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.id_error:
    RAISE exc_TypeError_type, "id() takes exactly one argument"
END_FUNC builtin_id

;; ============================================================================
;; 8. builtin_hash_fn(rdi = args, rsi = nargs) - hash(x)
;;   -> rax = Value
;;
;; obj_hash and nothing else.  This used to reimplement the dispatch -- int
;; immediate, float immediate, else tp_hash -- and raise when tp_hash was 0.
;; object_type's was 0 and tp_hash is inherited, so every instance, plain
;; class, function, module, iterator and object() answered TypeError, while
;; `d[obj] = 1` worked: dict goes through obj_hash, which falls back to the
;; address.  Two dispatchers, one of them wrong.
;;
;; They must agree in any case, or a key hashes one way going in and another
;; coming out, so there is no version of this that should have its own copy.
;; ============================================================================
DEF_FUNC builtin_hash_fn
    cmp rsi, 1
    jne .hash_nargs_error
    mov rdi, [rdi]
    extern obj_hash
    call obj_hash               ; raises for an unhashable type
    mov rdi, rax
    call int_from_i64
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.hash_nargs_error:
    RAISE exc_TypeError_type, "hash() takes exactly one argument"
END_FUNC builtin_hash_fn

;; ============================================================================
;; 9. builtin_callable(rdi = args, rsi = nargs) - callable(x)
;;   -> rax = Value
;; ============================================================================
DEF_FUNC builtin_callable

    cmp rsi, 1
    jne .callable_error

    V_TEST_INT_M [rdi], r11      ; args[0] an int immediate?
    jae .callable_false
    V_TEST_PTR_M [rdi], r11      ; args[0] a pointer?
    ja .callable_false
    mov rdi, [rdi]                     ; args[0] payload

    ; CPython's answer is one line -- type(x)->tp_call != NULL -- and this can
    ; finally give the same one.  It used to name three static types it knew
    ; had callable instances (func, builtin_func, method) and test tp_call
    ; only for heaptypes, because until slot_tp_call existed a heaptype's
    ; tp_call was always 0 and the allowlist was the only thing that could
    ; work.  An allowlist answers every type nobody thought of wrong:
    ; callable(weakref.ref(x)) was False despite weakrefmod setting tp_call.
    mov rax, [rdi + PyObject.ob_type]
    cmp qword [rax + PyTypeObject.tp_call], 0
    je .callable_false

.callable_true:
    RET_TRUE
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.callable_false:
    RET_FALSE
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.callable_error:
    CSTRING rdx, " given)"
    CSTRING rdi, "callable() takes exactly one argument ("
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_callable

;; ============================================================================
;; 10. builtin_iter_fn(rdi = args, rsi = nargs) - iter(x)
;;   -> rax = Value
;; ============================================================================
DEF_FUNC builtin_iter_fn

    cmp rsi, 2
    je .iter_sentinel
    cmp rsi, 1
    jne .iter_error

    mov rdi, [rdi]                     ; args[0]
    V_UNPACK rdi, rsi

    ; Use get_iterator which handles tp_iter, __iter__, __getitem__, validation
    extern get_iterator
    call get_iterator
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.iter_sentinel:
    ; iter(callable, sentinel): call it until it answers the sentinel.  This
    ; form did not exist, and it is the ordinary way to read a stream until a
    ; marker turns up -- `iter(lambda: f.read(4096), b"")`.
    mov rsi, [rdi + 8]                 ; the sentinel, as a Value
    mov rdi, [rdi]                     ; the callable
    V_TEST_PTR rdi, rax
    ja .iter_not_callable
    test rdi, rdi
    jz .iter_not_callable
    mov rax, [rdi + PyObject.ob_type]
    cmp qword [rax + PyTypeObject.tp_call], 0
    je .iter_not_callable
    extern callable_iter_new
    call callable_iter_new
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.iter_not_callable:
    RAISE exc_TypeError_type, "iter(object, sentinel): object must be callable"
.iter_error:
    ; CPython has two wordings, and they differ by which bound was broken.
    test rsi, rsi
    jnz .iter_too_many
    lea rdi, [rel iter_few_msg]
    jmp .iter_count
.iter_too_many:
    lea rdi, [rel iter_arity_msg]
.iter_count:
    xor edx, edx
    call raise_type_error_counted
END_FUNC builtin_iter_fn

section .rodata
iter_arity_msg: db "iter expected at most 2 arguments, got ", 0
iter_few_msg:   db "iter expected at least 1 argument, got ", 0
section .text

;; ============================================================================
;; 11. builtin_next_fn(rdi = args, rsi = nargs) - next(x)
;;   -> rax = Value
;; ============================================================================
NX_EXC   equ 8              ; current_exception before __next__ ran
; args[0] as it arrived, for the refusal: CPython names the type, and this
; said only "object is not an iterator".
NX_ARG   equ 16
NX_FRAME equ 24            ; + 1 push = 32, 16-aligned

DEF_FUNC builtin_next_fn, NX_FRAME
    push rbx
    DUNDER_EXC_SAVE [rbp - NX_EXC]

    cmp rsi, 1
    je .next_one_arg
    cmp rsi, 2
    je .next_two_args
    test rsi, rsi
    jz .next_too_few
    jmp .next_error

.next_two_args:
    ; next(iterator, default) — return default on StopIteration
    mov rax, [rdi]
    mov [rbp - NX_ARG], rax        ; the refusal below names its type
    push qword [rdi + 8]           ; save the default Value
    push qword [rdi + 8]           ; keep rsp 16-byte aligned
    ; Fall through to same iterator logic, but with default on stack
    V_TEST_PTR_M [rdi], r11      ; args[0] a pointer?
    ja .next_two_type_error
    mov rdi, [rdi]                 ; args[0] = iterator
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .next_two_type_error
    call rax
    V_UNPACK rax, rdx           ; tp_iternext returns a Value
    test edx, edx
    jz .next_two_default           ; exhausted → return default
    ; Got value — discard saved default
    add rsp, 16
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.next_two_default:
    ; Only a StopIteration means "use the default".  This cleared whatever was
    ; pending, so next(it, d) answered d for a __next__ that failed outright
    ; and the real exception surfaced somewhere unrelated.
    extern current_exception
    mov rax, [rel current_exception]
    test rax, rax
    jz .next_two_ret_default
    cmp rax, [rbp - NX_EXC]
    je .next_two_ret_default           ; the one already being handled
    mov rcx, [rax + PyObject.ob_type]
    extern exc_StopIteration_type
    lea rdx, [rel exc_StopIteration_type]
    cmp rcx, rdx
    jne .next_two_raised
    push rdi
    mov rdi, rax
    mov qword [rel current_exception], 0
    call obj_decref
    pop rdi
.next_two_ret_default:
    pop rax                        ; the default Value
    add rsp, 8                     ; drop the alignment copy
    INCREF_V rax, rdx
    V_UNPACK rax, rdx              ; next() still returns a fat pair
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.next_two_raised:
    add rsp, 16                    ; discard saved default
    jmp .next_got_val_null

.next_two_type_error:
    add rsp, 16                    ; discard saved default
    jmp .next_type_error

.next_one_arg:
    mov rax, [rdi]
    mov [rbp - NX_ARG], rax

    V_TEST_INT_M [rdi], r11      ; args[0] an int immediate?
    jae .next_type_error
    V_TEST_PTR_M [rdi], r11      ; args[0] a pointer?
    ja .next_type_error
    mov rdi, [rdi]                     ; args[0] payload

    mov rax, [rdi + PyObject.ob_type]
    mov rcx, rax                       ; save type
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jnz .next_have_iternext

    ; tp_iternext NULL — try __next__ on heaptype
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .next_type_error
    mov rbx, rdi                       ; save iterator
    extern dunder_next
    lea rsi, [rel dunder_next]
    extern dunder_call_1
    call dunder_call_1
    test rax, rax               ; dunder_call_1 answers with a Value; 0 is the miss
    jnz .next_got_value                ; got a Value -- NOT .next_got_val,
                                       ; which packs a (payload, tag) pair and
                                       ; would read rdx as a tag it never set
    ; NULL from __next__ — check for StopIteration in current_exception
    extern current_exception
    mov rax, [rel current_exception]
    test rax, rax
    jz .next_stop                      ; no exception, clean exhaustion
    mov rcx, [rax + PyObject.ob_type]
    extern exc_StopIteration_type
    lea rdx, [rel exc_StopIteration_type]
    cmp rcx, rdx
    jne .next_got_val_null             ; other exception: leave it, propagate
    ; It's StopIteration — leave it as current_exception for raise
    jmp .next_stop
.next_got_val_null:
    ; Non-StopIteration exception set — return NULL to propagate
    RET_NULL
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.next_have_iternext:
    mov rbx, rdi                       ; save iterator for StopIteration.value
    call rax
    V_UNPACK rax, rdx                  ; tp_iternext returns a Value
    test edx, edx
    jz .next_stop

.next_got_val:
    ; tp_iternext returns the pair (rax = payload, rdx = tag)
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.next_got_value:
    ; __next__ through dunder_call_1 already answered with a Value
    pop rbx
    leave
    ret

.next_stop:
    ; A NULL from tp_iternext is a clean exhaustion or a raise, and
    ; manufacturing a StopIteration here discarded the second: next(it) for a
    ; __next__ raising ValueError reported StopIteration instead.
    EXC_RAISED_SINCE [rbp - NX_EXC], rcx, .next_got_val_null

    ; Check if iterator is a generator (has gi_return_value)
    lea rax, [rel gen_type]
    cmp [rbx + PyObject.ob_type], rax
    jne .next_stop_no_val
    ; Get generator's return value for StopIteration (already a Value)
    mov rsi, [rbx + PyGenObject.gi_return_value]
    test rsi, rsi
    jz .next_stop_no_val
    ; A generator that returns None raises a BARE StopIteration in CPython --
    ; args is (), so str(e) is "" and the traceback says "StopIteration" and
    ; not "StopIteration: None".  gi_return_value holds the None singleton
    ; for such a generator, which is not the same as holding nothing.
    lea rax, [rel none_singleton]
    cmp rsi, rax
    jne .next_stop_with_val
    xor esi, esi
.next_stop_no_val:
    ; No argument, not None: CPython's next() over an exhausted iterator
    ; raises a bare StopIteration, whose str() is '' -- passing the None
    ; singleton made it 'None'.  exc_new documents 0 as "no message", and
    ; StopIteration.value still reads None off the empty args tuple.
    xor esi, esi
.next_stop_with_val:
    lea rdi, [rel exc_StopIteration_type]
    call exc_new
    ; SET the exception and answer NULL rather than RAISE.  A raise tail-jumps
    ; into eval_exception_unwind, which lands in the nearest PYTHON frame --
    ; and this is registered as the generator's own __next__, so
    ; slot_tp_iternext reaches it with no Python frame of its own in between.
    ; The StopIteration then unwound straight past the wrapper that exists to
    ; turn it back into exhaustion, and out of the `for` that was calling it:
    ; `type("C", (), {"__next__": gen().__next__})` never terminated a loop.
    ; op_call propagates a NULL with an exception pending, so the Python-level
    ; `next(it)` is unchanged.
    mov rdi, rax
    extern exc_install
    call exc_install            ; takes ownership of the reference
    jmp .next_got_val_null

.next_type_error:
    mov rsi, [rbp - NX_ARG]
    CSTRING rdi, `'\x01' object is not an iterator`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.next_too_few:
    CSTRING rdi, "next expected at least 1 argument, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted

.next_error:
    CSTRING rdi, "next expected at most 2 arguments, got "
    xor edx, edx
    jmp raise_type_error_counted
END_FUNC builtin_next_fn

;; ============================================================================
;; 12. builtin_any(rdi = args, rsi = nargs) - any(iterable)
;;   -> rax = Value
;; ============================================================================
ANY_EXC   equ 8             ; current_exception before the iteration started
; args[0] as it arrived: the refusal said "argument is not iterable" and
; CPython names the type.
ANY_ARG   equ 16
ANY_FRAME equ 32            ; + 4 pushes = 64, 16-aligned

DEF_FUNC builtin_any, ANY_FRAME
    push rbx
    push r12
    push r13
    push r14

    cmp rsi, 1
    jne .any_error

    mov rax, [rdi]
    mov [rbp - ANY_ARG], rax
    V_TEST_PTR_M [rdi], r11      ; args[0] a pointer?
    ja .any_type_error
    mov rdi, [rdi]
    mov esi, TAG_PTR
    call get_iterator_opt       ; not tp_iter: the legacy __getitem__ protocol
    test rax, rax               ; counts as iterable too
    jz .any_type_error
    V_UNPACK rax, rdx           ; tp_call returns a Value
    mov rbx, rax

    mov rax, [rbx + PyObject.ob_type]
    mov r12, [rax + PyTypeObject.tp_iternext]

    DUNDER_EXC_SAVE [rbp - ANY_EXC]
.any_loop:
    mov rdi, rbx
    call r12
    V_UNPACK rax, rdx           ; tp_iternext returns a Value
    test edx, edx             ; TAG_NULL = exhausted
    jz .any_false

    mov r13, rax               ; item payload
    mov r14, rdx               ; item tag

    mov rdi, r13
    mov rsi, r14
    V_PACK rdi, rsi
    call obj_is_true
    test eax, eax
    jnz .any_found_true

    ; Falsy: DECREF item and continue
    DECREF_VAL r13, r14
    jmp .any_loop

.any_found_true:
    DECREF_VAL r13, r14

.any_true:
    mov rdi, rbx
    call obj_decref
    RET_TRUE
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.any_false:
    mov rdi, rbx
    call obj_decref
    ; The loop ends on a NULL from tp_iternext, which is a clean exhaustion
    ; and a raise alike.  Answering from it without asking swallowed the
    ; exception outright: any() over a generator that threw after a run of
    ; falsy items reported a plain result and stranded it.
    EXC_RAISED_SINCE [rbp - ANY_EXC], rcx, .any_raised
    RET_FALSE
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.any_raised:
    xor eax, eax                ; a NULL Value, with the exception pending
    xor edx, edx
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.any_type_error:
    mov rsi, [rbp - ANY_ARG]
    CSTRING rdi, `'\x01' object is not iterable`
    jmp raise_type_error_with_name

.any_error:
    CSTRING rdx, " given)"
    CSTRING rdi, "any() takes exactly one argument ("
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_any

;; ============================================================================
;; 13. builtin_all(rdi = args, rsi = nargs) - all(iterable)
;;   -> rax = Value
;; ============================================================================
ALL_EXC   equ 8             ; current_exception before the iteration started
; args[0] as it arrived: the refusal said "argument is not iterable" and
; CPython names the type.
ALL_ARG   equ 16
ALL_FRAME equ 32            ; + 4 pushes = 64, 16-aligned

DEF_FUNC builtin_all, ALL_FRAME
    push rbx
    push r12
    push r13
    push r14

    cmp rsi, 1
    jne .all_error

    mov rax, [rdi]
    mov [rbp - ALL_ARG], rax
    V_TEST_PTR_M [rdi], r11      ; args[0] a pointer?
    ja .all_type_error
    mov rdi, [rdi]
    mov esi, TAG_PTR
    call get_iterator_opt       ; not tp_iter: the legacy __getitem__ protocol
    test rax, rax               ; counts as iterable too
    jz .all_type_error
    mov rbx, rax

    mov rax, [rbx + PyObject.ob_type]
    mov r12, [rax + PyTypeObject.tp_iternext]

    DUNDER_EXC_SAVE [rbp - ALL_EXC]
.all_loop:
    mov rdi, rbx
    call r12
    V_UNPACK rax, rdx           ; tp_iternext returns a Value
    test edx, edx             ; TAG_NULL = exhausted
    jz .all_true

    mov r13, rax               ; item payload
    mov r14, rdx               ; item tag

    mov rdi, r13
    mov rsi, r14
    V_PACK rdi, rsi
    call obj_is_true
    test eax, eax
    jz .all_found_false

    ; Truthy: DECREF item and continue
    DECREF_VAL r13, r14
    jmp .all_loop

.all_found_false:
    DECREF_VAL r13, r14

.all_false:
    mov rdi, rbx
    call obj_decref
    RET_FALSE
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.all_true:
    mov rdi, rbx
    call obj_decref
    ; The loop ends on a NULL from tp_iternext, which is a clean exhaustion
    ; and a raise alike.  Answering from it without asking swallowed the
    ; exception outright: all() over a generator that threw after a run of
    ; falsy items reported a plain result and stranded it.
    EXC_RAISED_SINCE [rbp - ALL_EXC], rcx, .all_raised
    RET_TRUE
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.all_raised:
    xor eax, eax                ; a NULL Value, with the exception pending
    xor edx, edx
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.all_type_error:
    mov rsi, [rbp - ALL_ARG]
    CSTRING rdi, `'\x01' object is not iterable`
    jmp raise_type_error_with_name

.all_error:
    CSTRING rdx, " given)"
    CSTRING rdi, "all() takes exactly one argument ("
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_all

;; ============================================================================
;; ============================================================================
;; sum_settle(xmm0 = the running total, xmm1 = the compensation) -> rax = Value
;;
;; Folds the compensation term into the running total and hands back a Value.
;; The two doubles are ARGUMENTS and not read out of the caller's frame: this
;; has a prologue of its own, so rbp here is its own.
;; The term is only added when it is NON-ZERO AND FINITE, which is CPython's
;; test: an infinite or overflowed total must not be turned into a NaN by
;; adding an infinity of the other sign to it, and a zero term must not turn
;; -0.0 into +0.0.
;; ============================================================================
DEF_FUNC_LOCAL sum_settle, 8            ; 1 push, so rsp stays 16-aligned
    push rbx
    xorpd xmm2, xmm2
    ucomisd xmm1, xmm2
    jp .ss_skip                         ; a NaN term is not finite
    je .ss_skip                         ; and a zero term changes nothing
    movapd xmm3, xmm1
    andpd xmm3, [rel sum_absmask]
    ucomisd xmm3, [rel sum_inf]
    jae .ss_skip                        ; an infinite term is refused
    addsd xmm0, xmm1
.ss_skip:
    movq rax, xmm0
    V_FROM_F64 rax, rbx
    pop rbx
    leave
    ret
END_FUNC sum_settle

section .rodata
align 16
;; The sign bit cleared, for |x|.  andpd wants its memory operand aligned.
sum_absmask: dq 0x7FFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF
sum_inf:     dq 0x7FF0000000000000, 0x7FF0000000000000
section .text

;; 14. builtin_sum(rdi = args, rsi = nargs) - sum(iterable[, start])
;;   -> rax = Value
;; ============================================================================
;; Every addition goes through obj_binary_op, the whole numeric protocol.
;; This used to pick between int_add and float_add on the two operands' tags
;; and never test the result, so anything neither of those slots accepted --
;; complex, Decimal, any class with __add__ -- left a NULL Value as the
;; accumulator.  NULL is not an error the loop noticed; it was added to,
;; DECREFed, and finally returned, and the failure surfaced wherever the
;; caller next touched it.

SM_ACC   equ 8              ; the accumulator Value, owned
SM_ITEM  equ 16             ; the item just pulled from the iterator, owned
SM_NEW   equ 24             ; the sum, held across the two DECREFs below
SM_EXC   equ 32
SM_OBJ   equ 40             ; args[0], for the error message: rbx is reused
SM_FSUM  equ 48             ; the running float total, while SM_PHASE is 1
SM_COMP  equ 56             ; and the compensation term beside it
SM_PHASE equ 64             ; 0 = not yet a float sum, 1 = in it, 2 = left it
SM_FRAME equ 80             ; + 2 pushes = 96, 16-byte aligned

extern value_type
extern raise_type_error_with_name
extern obj_binary_op
extern bytes_type
extern bytearray_type

DEF_FUNC builtin_sum, SM_FRAME
    push rbx
    push r12

    cmp rsi, 1
    jb .sum_too_few
    cmp rsi, 2
    ja .sum_error

    mov rbx, rdi                ; args
    mov qword [rbp - SM_PHASE], 0
    cmp rsi, 2
    je .sum_start

    xor eax, eax
    V_PACK_I64 rax, rcx         ; the default start is the int 0
    mov [rbp - SM_ACC], rax
    jmp .sum_iter

.sum_start:
    mov rax, [rbx + 8]          ; args[1]
    mov [rbp - SM_ACC], rax
    INCREF_V rax, rcx
    ; CPython refuses a str, bytes or bytearray start and names the better
    ; tool.  Summing them works, but builds one temporary per element.
    V_TEST_PTR rax, rcx
    ja .sum_iter                ; an immediate is fine
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    je .sum_no_str
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    je .sum_no_bytes
    lea rdx, [rel bytearray_type]
    cmp rcx, rdx
    je .sum_no_bytearray

.sum_iter:
    ; get_iterator_opt, not a tp_iter read: an object with __getitem__ and no
    ; __iter__ is iterable everywhere else here, and this rejected it.
    mov rdi, [rbx]              ; args[0], the iterable
    mov [rbp - SM_OBJ], rdi     ; parked: rbx becomes the iterator below, and
                                ; the error message still has to name this
    V_TEST_PTR rdi, rax
    ja .sum_not_iterable        ; an immediate is never iterable
    mov esi, TAG_PTR
    call get_iterator_opt
    test rax, rax
    jz .sum_not_iterable
    mov rbx, rax                ; rbx = the iterator, owned
    mov rax, [rbx + PyObject.ob_type]
    mov r12, [rax + PyTypeObject.tp_iternext]
    test r12, r12
    jz .sum_not_iterable_have

    DUNDER_EXC_SAVE [rbp - SM_EXC]

    ; A float `start` means the very FIRST addition is already one the
    ; compensation has to cover.  Entering the compensated loop only from an
    ; add's RESULT left that first add naked, and it is the one that loses the
    ; digits: sum([1.0, -1e100], 1e100) dropped the 1.0 inside the
    ; 1e100 + 1.0 that produced the seed, and answered 0.0 where CPython says
    ; 1.0.  CPython seeds f_result from `result` before its loop for the same
    ; reason.
    ;
    ; A float is an immediate here, so SM_ACC owns nothing and there is no
    ; reference to hand over; a float SUBCLASS is a pointer, fails this test,
    ; and correctly keeps the generic protocol.
    V_TEST_F64_M [rbp - SM_ACC], rcx
    ja .sum_loop
    mov rax, [rbp - SM_ACC]
    V_TO_F64 rax
    mov [rbp - SM_FSUM], rax
    mov qword [rbp - SM_COMP], 0        ; c = +0.0
    mov qword [rbp - SM_PHASE], 1

.sum_loop:
    mov rdi, rbx
    call r12
    test rax, rax
    jz .sum_stop                ; exhausted -- or it raised
    mov [rbp - SM_ITEM], rax

    cmp qword [rbp - SM_PHASE], 1
    je .sum_compensated

    ; Both the total and the item an integer immediate?  Then the addition is
    ; three instructions on the Values themselves.  Everything below is the
    ; general numeric protocol -- obj_binary_op, int_binop_unpack twice,
    ; int_add -- and over a list of ordinary integers that was 45% of sum().
    ; CPython has the same fast path, keeping a Py_ssize_t running total that
    ; bails on overflow (bltinmodule.c); this bails into the protocol instead,
    ; so there is only one place that knows how to add.
    ;
    ; Safe whether the phase is 0 or 2.  An immediate is never a heaptype
    ; instance, so no __add__ or __radd__ is bypassed, and it owns nothing, so
    ; neither side needs a DECREF.  A float total fails the first test, which
    ; is why the phase does not have to be consulted again.
    mov rax, [rbp - SM_ACC]
    cmp rax, [rel v_int_lo]
    jb .sum_generic_pair
    mov rdx, [rbp - SM_ITEM]
    cmp rdx, [rel v_int_lo]
    jb .sum_generic_pair
    add rax, rdx
    sub rax, [rel v_int_bias]
    cmp rax, [rel v_int_lo]
    jb .sum_generic_pair        ; past +-2^50: the protocol boxes it properly
    mov [rbp - SM_ACC], rax
    jmp .sum_loop

.sum_generic_pair:
    mov rdi, [rbp - SM_ACC]
.sum_generic_add:
    mov rsi, [rbp - SM_ITEM]
    xor edx, edx                ; NB_ADD
    call obj_binary_op
    ; Park the result before either DECREF: obj_dealloc clobbers every
    ; caller-saved register, this one included.
    mov [rbp - SM_NEW], rax
    mov rdi, [rbp - SM_ITEM]
    DECREF_V rdi, rdx
    mov rdi, [rbp - SM_ACC]
    DECREF_V rdi, rdx
    mov rax, [rbp - SM_NEW]
    mov [rbp - SM_ACC], rax     ; NULL if it raised; DECREF_V below is NULL-safe
    test rax, rax
    jz .sum_check_done
    ; The total has just become a float: from here the additions are
    ; compensated.  CPython enters this at the same point -- its integer fast
    ; path ends on the first non-integer item, and whatever that add produced
    ; is what its float loop starts from.  Phase 2 is "already left it", which
    ; is never re-entered, because CPython's float loop is not either.
    cmp qword [rbp - SM_PHASE], 0
    jne .sum_check_done
    V_TEST_F64_M [rbp - SM_ACC], rcx
    ja .sum_check_done
    mov rax, [rbp - SM_ACC]
    V_TO_F64 rax
    mov [rbp - SM_FSUM], rax
    mov qword [rbp - SM_COMP], 0        ; c = +0.0
    mov qword [rbp - SM_PHASE], 1
    mov rax, [rbp - SM_ACC]
.sum_check_done:
    test rax, rax
    jz .sum_fail
    jmp .sum_loop

.sum_compensated:
    ; Improved Kahan-Babuska, after Neumaier -- the algorithm CPython 3.12
    ; adopted in gh-100425, and the reason sum([1e100, 1.0, -1e100]) is 1.0
    ; there and was 0.0 here.  The compensation term IS the answer in that
    ; example: the naive running total loses the 1.0 entirely when 1e100 is
    ; added and again when it is taken away.
    V_TEST_F64_M [rbp - SM_ITEM], rcx
    jbe .sum_c_float
    V_TEST_INT_M [rbp - SM_ITEM], rcx
    jae .sum_c_int
    jmp .sum_c_leave

.sum_c_float:
    mov rax, [rbp - SM_ITEM]
    V_TO_F64 rax
    movq xmm2, rax                      ; x
    movsd xmm0, [rbp - SM_FSUM]         ; s
    movapd xmm1, xmm0
    addsd xmm1, xmm2                    ; t = s + x
    ; Which of the two is larger decides which way round the lost low bits
    ; are recovered.  ucomisd leaves CF set for unordered, so a NaN takes the
    ; second form -- which is what `fabs(s) >= fabs(x)` being false does.
    movapd xmm3, xmm0
    andpd xmm3, [rel sum_absmask]
    movapd xmm4, xmm2
    andpd xmm4, [rel sum_absmask]
    ucomisd xmm3, xmm4
    jb .sum_c_x_bigger
    subsd xmm0, xmm1                    ; s - t
    addsd xmm0, xmm2                    ; (s - t) + x
    jmp .sum_c_accum
.sum_c_x_bigger:
    subsd xmm2, xmm1                    ; x - t
    addsd xmm2, xmm0                    ; (x - t) + s
    movapd xmm0, xmm2
.sum_c_accum:
    movsd xmm3, [rbp - SM_COMP]
    addsd xmm3, xmm0
    movsd [rbp - SM_COMP], xmm3
    movsd [rbp - SM_FSUM], xmm1
    jmp .sum_loop                       ; an immediate owns nothing

.sum_c_int:
    ; CPython adds an integer straight into the total with no compensation,
    ; so this does too.
    mov rax, [rbp - SM_ITEM]
    V_TO_I64 rax
    cvtsi2sd xmm0, rax
    movsd xmm1, [rbp - SM_FSUM]
    addsd xmm1, xmm0
    movsd [rbp - SM_FSUM], xmm1
    jmp .sum_loop

.sum_c_leave:
    ; Something that is neither: settle the total, hand the item to the
    ; general protocol, and do not come back.
    movsd xmm0, [rbp - SM_FSUM]
    movsd xmm1, [rbp - SM_COMP]
    call sum_settle
    mov [rbp - SM_ACC], rax
    mov qword [rbp - SM_PHASE], 2
    mov rdi, [rbp - SM_ACC]
    jmp .sum_generic_add

.sum_stop:
    ; tp_iternext answers NULL both for "exhausted" and for a raise, so the
    ; two are told apart by the pending exception, not by the return.
    EXC_RAISED_SINCE [rbp - SM_EXC], rcx, .sum_fail
    cmp qword [rbp - SM_PHASE], 1
    jne .sum_stop_have_acc
    movsd xmm0, [rbp - SM_FSUM]
    movsd xmm1, [rbp - SM_COMP]
    call sum_settle
    mov [rbp - SM_ACC], rax
    mov qword [rbp - SM_PHASE], 2
.sum_stop_have_acc:
    mov rdi, rbx
    call obj_decref
    mov rax, [rbp - SM_ACC]
    pop r12
    pop rbx
    leave
    ret

.sum_fail:
    mov rdi, rbx
    call obj_decref
.sum_fail_no_iter:
    mov rdi, [rbp - SM_ACC]
    DECREF_V rdi, rdx
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.sum_not_iterable_have:
    ; The iterator exists but has no tp_iternext.  Releasing it and falling
    ; through read the freed object as if it were the argument array.
    mov rdi, rbx
    call obj_decref
.sum_not_iterable:
    mov rdi, [rbp - SM_ACC]
    DECREF_V rdi, rdx
    mov rsi, [rbp - SM_OBJ]
    CSTRING rdi, `'\x01' object is not iterable`
    call raise_type_error_with_name

.sum_no_str:
    mov rdi, [rbp - SM_ACC]
    DECREF_V rdi, rdx
    RAISE exc_TypeError_type, "sum() can't sum strings [use ''.join(seq) instead]"

.sum_no_bytes:
    mov rdi, [rbp - SM_ACC]
    DECREF_V rdi, rdx
    RAISE exc_TypeError_type, "sum() can't sum bytes [use b''.join(seq) instead]"

.sum_no_bytearray:
    mov rdi, [rbp - SM_ACC]
    DECREF_V rdi, rdx
    RAISE exc_TypeError_type, "sum() can't sum bytearray [use b''.join(seq) instead]"

.sum_too_few:
    CSTRING rdx, " given)"
    CSTRING rdi, "sum() takes at least 1 positional argument ("
    extern raise_type_error_counted
    jmp raise_type_error_counted

.sum_error:
    CSTRING rdx, " given)"
    CSTRING rdi, "sum() takes at most 2 arguments ("
    jmp raise_type_error_counted
END_FUNC builtin_sum

;; ============================================================================
;; 15-16. builtin_min / builtin_max(rdi = args, rsi = nargs)
;;   -> rax = Value
;; ============================================================================
; Shared implementation: minmax_impl(args, nargs, cmp_op)
;   rdi = args (Value[]), rsi = nargs, edx = cmp_op (PY_LT for min, PY_GT for max)
;   -> rax = the winning Value, or 0 with an exception pending
;
; Every comparison goes through obj_richcompare_bool.  This used to call
; tp_richcompare off a hand-rolled type ladder and then test the result
; against bool_true, which conflated three different answers with "the
; incumbent keeps": a type the ladder did not recognise, a slot that declined,
; and a comparison that raised.  max([1j, 2j]) answered 1j where CPython
; raises TypeError, and a raising __lt__ was swallowed outright -- while
; sorted() over the same values was correct, because list.sort had already
; been taught the difference.  It also handed obj_decref the NULL a declining
; slot returns.
MM_BEST   equ 8             ; the incumbent Value, owned
MM_CAND   equ 16            ; the candidate Value; owned on the iterator path
MM_ITER   equ 24
MM_ITERNX equ 32
MM_OP     equ 40
MM_N      equ 48
MM_EXC    equ 56
MM_KEY    equ 64            ; the key= callable, or 0
MM_HASDEF equ 72            ; 1 when default= was given
MM_DEFAULT equ 80           ; its Value, borrowed from the argument array
MM_BESTKEY equ 88           ; key(best), owned; == MM_BEST when there is no key
MM_CANDKEY equ 96           ; key(candidate), owned
MM_NPOS   equ 104           ; positional count, once the keywords are split off
MM_FRAME  equ 112           ; + 2 pushes = 128, 16-byte aligned

extern obj_richcompare_bool

DEF_FUNC_BARE builtin_min
    xor edx, edx                   ; PY_LT = 0
    jmp minmax_impl
END_FUNC builtin_min

;; ============================================================================
;; builtin_max(rdi = args, rsi = nargs) -> rax = Value
;; The other half of the pair above, selecting PY_GT instead.
;; ============================================================================
DEF_FUNC_BARE builtin_max
    mov edx, PY_GT                 ; PY_GT = 4
    jmp minmax_impl
END_FUNC builtin_max

;; mm_key_of(rdi = a Value) -> rax = key(it), owned, or 0 with an exception
;; pending.  With no key= it is the value itself, INCREF'd, so both loops hold
;; an owned key either way and release it the same.  Reads minmax_impl's frame
;; through rbp, so it lives only inside it.
DEF_FUNC_LOCAL mm_key_of, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, [rbp]                  ; minmax_impl's rbp
    mov rax, [rbx - MM_KEY]
    test rax, rax
    jnz .mko_call
    mov rax, rdi
    INCREF_V rax, rcx
    pop rbx
    leave
    ret
.mko_call:
    ; minmax_impl checked that this is a pointer with a tp_call before it
    ; allocated anything, so the slot is here.
    sub rsp, 16                     ; one Value; 16 keeps rsp aligned
    mov [rsp], rdi
    mov rdi, rax
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    mov rsi, rsp
    mov edx, 1
    call rax
    add rsp, 16
    pop rbx
    leave
    ret
END_FUNC mm_key_of

;; ============================================================================
;; minmax_impl(rdi = args, rsi = nargs, edx = the comparison op)
;;   -> rax = Value
;; Both builtins, in one body: the op is the only thing that differs, and
;; key= and default= are keyword-only for either of them.
;; ============================================================================
DEF_FUNC_LOCAL minmax_impl, MM_FRAME
    push rbx
    push r12
    mov [rbp - MM_OP], edx
    ; The failure paths release both of these, so they must be readable from
    ; the first instruction that can jump to one.
    mov qword [rbp - MM_BEST], 0
    mov qword [rbp - MM_CAND], 0
    mov qword [rbp - MM_BESTKEY], 0
    mov qword [rbp - MM_CANDKEY], 0
    mov qword [rbp - MM_KEY], 0
    mov qword [rbp - MM_HASDEF], 0
    mov qword [rbp - MM_DEFAULT], 0
    mov [rbp - MM_NPOS], rsi

    ; key= and default=.  Nothing here read kw_names_pending, so both arrived
    ; as extra POSITIONAL operands and were compared as values:
    ; min([1,-3,2], key=abs) compared the function object against the list.
    mov rax, [rel kw_names_pending]
    test rax, rax
    jz .mm_no_kw
    mov qword [rel kw_names_pending], 0
    mov rcx, [rax + PyTupleObject.ob_size]
    mov rdx, [rbp - MM_NPOS]
    sub rdx, rcx
    mov [rbp - MM_NPOS], rdx
    mov r9, [rax + PyTupleObject.ob_item]
    xor r8d, r8d
.mm_kw_loop:
    cmp r8, rcx
    jge .mm_no_kw
    push rcx
    push r8
    push r9
    push rdi
    mov r10, [r9 + r8*8]
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "key"
    call ap_strcmp
    mov r11d, eax
    pop rdi
    pop r9
    pop r8
    pop rcx
    mov r10, [rbp - MM_NPOS]
    add r10, r8
    mov r10, [rdi + r10*8]      ; the keyword's value
    test r11d, r11d
    jnz .mm_kw_try_default
    LOAD_NONE rax               ; key=None means no key, as CPython has it
    cmp r10, rax
    je .mm_kw_next
    mov [rbp - MM_KEY], r10
    jmp .mm_kw_next
.mm_kw_try_default:
    push rcx
    push r8
    push r9
    push rdi
    mov r10, [r9 + r8*8]
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "default"
    call ap_strcmp
    mov r11d, eax
    pop rdi
    pop r9
    pop r8
    pop rcx
    test r11d, r11d
    jnz .mm_kw_next
    mov r10, [rbp - MM_NPOS]
    add r10, r8
    mov r10, [rdi + r10*8]
    mov [rbp - MM_DEFAULT], r10
    mov qword [rbp - MM_HASDEF], 1
.mm_kw_next:
    inc r8
    jmp .mm_kw_loop
.mm_no_kw:

    ; The key is checked here, before anything is allocated: mm_key_of raises
    ; through raise_type_error_with_name, which abandons the C stack, and by
    ; the time it is first called the iterator is already live -- min([1,2],
    ; key=5) leaked it.
    mov rax, [rbp - MM_KEY]
    test rax, rax
    jz .mm_key_ok
    V_TEST_PTR rax, rcx
    ja .mm_key_bad
    mov rcx, [rax + PyObject.ob_type]
    cmp qword [rcx + PyTypeObject.tp_call], 0
    je .mm_key_bad
.mm_key_ok:

    mov rsi, [rbp - MM_NPOS]
    cmp rsi, 1
    jb .mm_error
    je .mm_iter_path
    ; default= is only meaningful for the single-iterable form.
    cmp qword [rbp - MM_HASDEF], 0
    jne .mm_default_with_args

    ; --- min/max(a, b, ...) ---
    mov rbx, rdi                ; args
    mov [rbp - MM_N], rsi
    mov rax, [rbx]              ; args[0] starts as the incumbent
    mov [rbp - MM_BEST], rax
    INCREF_V rax, rcx
    mov rdi, rax
    call mm_key_of
    test rax, rax
    jz .mm_fail
    mov [rbp - MM_BESTKEY], rax
    mov r12d, 1

.mm_loop:
    cmp r12, [rbp - MM_N]
    jge .mm_done
    mov rdi, [rbx + r12*8]      ; the candidate
    call mm_key_of
    test rax, rax
    jz .mm_fail
    mov [rbp - MM_CANDKEY], rax
    mov rdi, rax
    mov rsi, [rbp - MM_BESTKEY]
    mov edx, [rbp - MM_OP]
    call obj_richcompare_bool
    test eax, eax
    jl .mm_fail                 ; the comparison raised
    je .mm_next                 ; the incumbent keeps
    mov rax, [rbx + r12*8]
    INCREF_V rax, rcx           ; before the release, in case they are one object
    mov rdi, [rbp - MM_BEST]
    mov [rbp - MM_BEST], rax
    DECREF_V rdi, rdx
    mov rdi, [rbp - MM_BESTKEY]
    mov rax, [rbp - MM_CANDKEY]
    mov [rbp - MM_BESTKEY], rax
    mov qword [rbp - MM_CANDKEY], 0
    DECREF_V rdi, rdx
.mm_next:
    mov rdi, [rbp - MM_CANDKEY]
    DECREF_V rdi, rdx
    mov qword [rbp - MM_CANDKEY], 0
    inc r12
    jmp .mm_loop

.mm_done:
    mov rdi, [rbp - MM_BESTKEY]
    DECREF_V rdi, rdx
    mov rax, [rbp - MM_BEST]
    pop r12
    pop rbx
    leave
    ret

.mm_fail:
    mov rdi, [rbp - MM_BEST]
    DECREF_V rdi, rdx
    mov rdi, [rbp - MM_BESTKEY]
    DECREF_V rdi, rdx
    mov rdi, [rbp - MM_CANDKEY]
    DECREF_V rdi, rdx
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.mm_key_bad:
    mov rsi, [rbp - MM_KEY]
    CSTRING rdi, `'\x01' object is not callable`
    extern raise_type_error_with_name
    call raise_type_error_with_name

.mm_default_with_args:
    cmp dword [rbp - MM_OP], PY_GT
    je .mm_default_max
    RAISE exc_TypeError_type, "Cannot specify a default for min() with multiple positional arguments"
.mm_default_max:
    RAISE exc_TypeError_type, "Cannot specify a default for max() with multiple positional arguments"

    ; --- min/max(iterable) ---
.mm_iter_path:
    mov rbx, rdi                ; args, kept for the error message
    mov rdi, [rdi]              ; args[0], the iterable
    V_TEST_PTR rdi, rax
    ja .mm_not_iterable         ; an immediate is never iterable
    mov esi, TAG_PTR
    call get_iterator_opt       ; see the note in builtin_sum
    test rax, rax
    jz .mm_not_iterable
    mov [rbp - MM_ITER], rax
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_iternext]
    test rcx, rcx
    jz .mm_iter_no_next
    mov [rbp - MM_ITERNX], rcx

    DUNDER_EXC_SAVE [rbp - MM_EXC]

    mov rdi, [rbp - MM_ITER]
    call qword [rbp - MM_ITERNX]
    test rax, rax
    jz .mm_iter_empty
    mov [rbp - MM_BEST], rax    ; owned, as tp_iternext hands it over
    mov rdi, rax
    call mm_key_of
    test rax, rax
    jz .mm_iter_fail
    mov [rbp - MM_BESTKEY], rax

.mm_iter_loop:
    mov rdi, [rbp - MM_ITER]
    call qword [rbp - MM_ITERNX]
    test rax, rax
    jz .mm_iter_stop
    mov [rbp - MM_CAND], rax
    mov rdi, rax
    call mm_key_of
    test rax, rax
    jz .mm_iter_fail
    mov [rbp - MM_CANDKEY], rax
    mov rdi, rax
    mov rsi, [rbp - MM_BESTKEY]
    mov edx, [rbp - MM_OP]
    call obj_richcompare_bool
    test eax, eax
    jl .mm_iter_fail
    je .mm_iter_next
    ; The candidate wins: hand its reference to BEST rather than adjusting
    ; two counts, and blank CAND so the release below is a no-op.
    mov rdi, [rbp - MM_BEST]
    mov rax, [rbp - MM_CAND]
    mov [rbp - MM_BEST], rax
    mov qword [rbp - MM_CAND], 0
    DECREF_V rdi, rdx
    mov rdi, [rbp - MM_BESTKEY]
    mov rax, [rbp - MM_CANDKEY]
    mov [rbp - MM_BESTKEY], rax
    mov qword [rbp - MM_CANDKEY], 0
    DECREF_V rdi, rdx
.mm_iter_next:
    mov rdi, [rbp - MM_CAND]
    DECREF_V rdi, rdx
    mov qword [rbp - MM_CAND], 0
    mov rdi, [rbp - MM_CANDKEY]
    DECREF_V rdi, rdx
    mov qword [rbp - MM_CANDKEY], 0
    jmp .mm_iter_loop

.mm_iter_stop:
    ; tp_iternext answers NULL for "exhausted" and for a raise alike.
    EXC_RAISED_SINCE [rbp - MM_EXC], rcx, .mm_iter_fail
    mov rdi, [rbp - MM_ITER]
    call obj_decref
    mov rdi, [rbp - MM_BESTKEY]
    DECREF_V rdi, rdx
    mov rax, [rbp - MM_BEST]
    pop r12
    pop rbx
    leave
    ret

.mm_iter_fail:
    mov rdi, [rbp - MM_ITER]
    call obj_decref
    mov rdi, [rbp - MM_BESTKEY]
    DECREF_V rdi, rdx
    mov qword [rbp - MM_BESTKEY], 0
    mov rdi, [rbp - MM_CANDKEY]
    DECREF_V rdi, rdx
    mov qword [rbp - MM_CANDKEY], 0
    mov rdi, [rbp - MM_CAND]
    DECREF_V rdi, rdx
    jmp .mm_fail

.mm_iter_empty:
    EXC_RAISED_SINCE [rbp - MM_EXC], rcx, .mm_iter_fail
    mov rdi, [rbp - MM_ITER]
    call obj_decref
    ; default= is what an empty iterable answers with, when it was given.
    cmp qword [rbp - MM_HASDEF], 0
    je .mm_iter_really_empty
    mov rax, [rbp - MM_DEFAULT]
    INCREF_V rax, rcx
    pop r12
    pop rbx
    leave
    ret
.mm_iter_really_empty:
    ; CPython names the builtin, and MM_OP is what tells them apart.
    cmp dword [rbp - MM_OP], PY_GT
    je .mm_iter_empty_max
    RAISE exc_ValueError_type, "min() iterable argument is empty"
.mm_iter_empty_max:
    RAISE exc_ValueError_type, "max() iterable argument is empty"

.mm_iter_no_next:
    mov rdi, [rbp - MM_ITER]
    call obj_decref
.mm_not_iterable:
    mov rsi, [rbx]
    CSTRING rdi, `'\x01' object is not iterable`
    call raise_type_error_with_name

.mm_error:
    ; CPython names the one that was called, and says how many it got.
    mov rsi, [rbp - MM_NPOS]
    cmp dword [rbp - MM_OP], PY_GT
    je .mm_error_max
    CSTRING rdi, "min expected at least 1 argument, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted
.mm_error_max:
    CSTRING rdi, "max expected at least 1 argument, got "
    xor edx, edx
    jmp raise_type_error_counted
END_FUNC minmax_impl

;; ============================================================================
;; 17. builtin_getattr(args, nargs) - getattr(obj, name[, default])
;; ============================================================================
GA_EXC    equ 8              ; current_exception before the lookup

;; ============================================================================
;; builtin_globals(rdi = args, rsi = nargs) - globals()
;;   -> rax = Value
;; Returns the globals dict of the current frame.
;; ============================================================================
DEF_FUNC builtin_globals
    test rsi, rsi
    jne .globals_error

    ; Get current eval frame from saved r12
    mov rax, [rel eval_saved_r12]
    mov rax, [rax + PyFrame.globals]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.globals_error:
    CSTRING rdx, " given)"
    CSTRING rdi, "globals() takes no arguments ("
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_globals

;; ============================================================================
;; builtin_locals(rdi = args, rsi = nargs) - locals()
;;   -> rax = Value
;; Returns the locals dict if available, otherwise globals.
;; In module scope, locals() == globals().
;; In class body, returns the class dict.
;; In function scope, returns globals as approximation.
;; ============================================================================
DEF_FUNC builtin_locals
    test rsi, rsi
    jne .locals_error

    ; Get current eval frame
    mov rax, [rel eval_saved_r12]
    ; Check if frame has a locals dict
    mov rcx, [rax + PyFrame.locals]
    test rcx, rcx
    jz .locals_use_globals
    ; Has locals dict - return it
    mov rax, rcx
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.locals_use_globals:
    ; No locals mapping means a function frame, whose locals live in the
    ; localsplus array.  Returning globals there was simply the wrong answer:
    ; locals() inside a function listed the module's names, not its own.
    mov rdi, rax
    extern frame_fast_to_locals
    call frame_fast_to_locals
    test rax, rax
    jz .locals_no_frame
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.locals_no_frame:
    mov rax, [rel eval_saved_r12]
    mov rax, [rax + PyFrame.globals]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.locals_error:
    CSTRING rdx, " given)"
    CSTRING rdi, "locals() takes no arguments ("
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_locals

;; ============================================================================
;; dir_default(rdi = obj Value) -> rax = a list Value of the names obj carries
;;
;; What object.__dir__ answers: the tp_dicts along the MRO, plus the instance
;; __dict__ when the object has one.  A module is the exception CPython also
;; makes -- its names live in mod_dict and nowhere else, and module.__dir__
;; answers with those alone rather than adding object's dunders to them.
;;
;; The list comes back unsorted; builtin_dir sorts whatever it is handed,
;; whether that came from here or from a __dir__ of the object's own.
;; ============================================================================
DD_LIST   equ 8       ; result list
DD_OBJ    equ 16      ; the object, as a Value
DD_ORIGIN equ 24      ; the type whose MRO is being listed
DD_FRAME  equ 40          ; + 3 pushes = 64, 16-aligned

DEF_FUNC dir_default, DD_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - DD_OBJ], rdi

    xor edi, edi
    call list_new
    mov rbx, rax                ; rbx = the result list, live throughout
    mov [rbp - DD_LIST], rax

    mov rax, [rbp - DD_OBJ]
    V_UNPACK rax, r12           ; r12 = obj tag
    ; An immediate has no ob_type to read, but it does have a type: naming it
    ; here is what makes dir(5) int's names rather than the empty list.
    cmp r12d, TAG_SMALLINT
    je .dd_int_type
    cmp r12d, TAG_FLOAT
    je .dd_float_type
    test r12d, TAG_RC_BIT
    jz .dd_done
    test rax, rax
    jz .dd_done

    mov rcx, [rax + PyObject.ob_type]

    extern module_type
    lea rdx, [rel module_type]
    cmp rcx, rdx
    je .dd_module

    ; Is the object itself a class?  Ask the flag rather than compare against
    ; the metatypes we ship: a class built by a metaclass of its own is still
    ; a class, and TYPE_FLAG_METATYPE is set on every one of them.
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_METATYPE
    jnz .dd_from_type

    ; An ordinary instance: its own __dict__ first, then its type's MRO.  The
    ; comment here used to claim the instance dict was walked; only the type
    ; chain ever was, so a class attribute showed up and `self.x = 1` did not.
    mov r12, rcx                ; the type, for the walk below
    LOAD_INST_DICT rdx, rax, .dd_have_type
    test rdx, rdx
    jz .dd_have_type
    mov rdi, rdx
    call .dd_add_keys
.dd_have_type:
    mov [rbp - DD_ORIGIN], r12
    jmp .dd_walk_chain

.dd_int_type:
    extern int_type
    lea r12, [rel int_type]
    jmp .dd_type_origin
.dd_float_type:
    lea r12, [rel float_type]
.dd_type_origin:
    mov [rbp - DD_ORIGIN], r12
    jmp .dd_walk_chain

.dd_module:
    ; A module's names are its dict's and nothing else -- not even __class__,
    ; which CPython's module___dir___impl does not add and which the shared
    ; exit below does.  `dir(sys)` carried one name CPython's did not.
    mov rdi, [rax + PyModuleObject.mod_dict]
    test rdi, rdi
    jz .dd_finish
    call .dd_add_keys
    jmp .dd_finish

.dd_from_type:
    ; obj IS a type: list its own MRO
    mov r12, rax
    mov [rbp - DD_ORIGIN], r12

.dd_walk_chain:
    test r12, r12
    jz .dd_done
    mov rdi, [r12 + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .dd_next_base
    call .dd_add_keys
.dd_next_base:
    MRO_NEXT r12, [rbp - DD_ORIGIN]
    jmp .dd_walk_chain

.dd_done:
    ; __class__ is an attribute of every object and lives in no tp_dict here:
    ; obj_generic_attr answers it, after the walk above has missed.  CPython
    ; keeps it as a getset in object's dict, which is where its dir() finds
    ; it -- doing the same needs the metatype data-descriptor precedence that
    ; type_getattr does not have, so the name is added here instead.
    lea rdi, [rel dd_class_name]
    call str_from_cstr
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    call list_contains
    test eax, eax
    jnz .dd_class_present
    mov rdi, rbx
    mov rsi, r12
    call list_append
.dd_class_present:
    mov rdi, r12
    call obj_decref

.dd_finish:
    mov rax, rbx
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; one Value out
    ret

;; .dd_add_keys(rdi = a dict) -- append each of its keys to rbx, skipping the
;; ones already there.  Bases repeat names the derived class already gave.
.dd_add_keys:
    call dict_tp_iter
    mov r13, rax                ; r13 = the key iterator
.dd_key_loop:
    mov rdi, r13
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .dd_keys_done
    mov rdi, r13
    call rax                    ; tp_iternext(iter) -> key or NULL
    V_UNPACK rax, rdx
    test edx, edx
    jz .dd_keys_done

    push rax
    mov rdi, rbx
    mov rsi, rax
    V_PACK rsi, rdx             ; list_contains takes a Value
    call list_contains
    test eax, eax
    pop rax
    jnz .dd_key_loop            ; already present

    push rax
    mov rdi, rbx
    mov rsi, rax
    call list_append
    pop rdi
    call obj_decref
    jmp .dd_key_loop

.dd_keys_done:
    mov rdi, r13
    call obj_decref
    ret
END_FUNC dir_default

;; ============================================================================
;; builtin_dir(rdi = args, rsi = nargs) - dir(obj)
;;   -> rax = Value
;;
;; CPython's PyObject_Dir: ask the object's own __dir__, then sort what comes
;; back.  object.__dir__ is registered and calls dir_default, so an object
;; that defines none still gets the default walk -- and one that does define
;; a __dir__ is finally asked.  Before this, dir() consulted only the MRO's
;; tp_dicts and object.__dir__ called dir() straight back, so the pair asked
;; the object nothing and answered a module with object's own dunders.
;; ============================================================================
BD_OBJ    equ 8       ; the object, as a Value
BD_SORT   equ 24      ; END of the two-Value args buffer for extend and sort
BD_EXC    equ 32      ; current_exception before __dir__ was called
BD_FRAME  equ 48            ; + 0 pushes = 48, 16-aligned

DEF_FUNC builtin_dir, BD_FRAME
    DUNDER_EXC_SAVE [rbp - BD_EXC]
    push rbx

    ; dir() with no argument is the names in the current scope, which is
    ; sorted(locals()) -- CPython's own rule.  It was a TypeError here, and
    ; pickle calls it at import.
    test rsi, rsi
    jz .bd_no_args
    cmp rsi, 1
    jne .bd_error

    mov rax, [rdi]              ; args[0]
    mov [rbp - BD_OBJ], rax

    ; A non-pointer has no object to ask; it goes straight to the default.
    V_TEST_PTR rax, rcx
    ja .bd_default
    test rax, rax
    jz .bd_default

    mov rdi, rax
    lea rsi, [rel dunder_dir_name]
    extern dunder_call_1
    call dunder_call_1          ; -> the Value __dir__ answered, or a NULL one
    test rax, rax
    jnz .bd_have_dunder
    ; NULL means either "no __dir__ on the MRO" or "__dir__ raised".  A Python
    ; __dir__ that raises returns through the C stack with the exception
    ; pending rather than entering the unwinder, so without this test dir()
    ; answered the default walk and left the exception to surface somewhere
    ; else entirely.
    EXC_RAISED_SINCE [rbp - BD_EXC], rcx, .bd_propagate
    jmp .bd_default
.bd_have_dunder:
    mov rbx, rax

    ; __dir__ may answer any iterable; CPython turns it into a list before
    ; sorting.  An exact list already is one, so it is used as it stands.
    V_TEST_PTR rbx, rcx
    ja .bd_from_iterable
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .bd_have_list

.bd_from_iterable:
    xor edi, edi
    call list_new
    mov [rbp - BD_SORT], rax    ; args[0] = the new list, for extend and sort
    mov [rbp - BD_SORT + 8], rbx    ; args[1] = what __dir__ answered
    lea rdi, [rbp - BD_SORT]
    mov esi, 2
    extern list_method_extend
    call list_method_extend
    push rax
    DECREF_V rbx, rcx           ; the iterable __dir__ handed us
    pop rax
    mov rbx, [rbp - BD_SORT]
    test rax, rax
    jz .bd_list_failed          ; iterating what __dir__ answered raised
    jmp .bd_sort

.bd_have_list:
    mov [rbp - BD_SORT], rbx
    jmp .bd_sort

.bd_default:
    mov rdi, [rbp - BD_OBJ]
    call dir_default            ; -> a list Value; a pointer is its own Value
    mov rbx, rax
    mov [rbp - BD_SORT], rax

.bd_sort:
    ; sorted(), which is the other half of CPython's contract here.  dir() used
    ; to answer in MRO order, which no CPython output ever matches.
    lea rdi, [rbp - BD_SORT]
    mov esi, 1
    extern list_method_sort
    call list_method_sort
    test rax, rax
    jz .bd_sort_raised
    DECREF_V rax, rdx

    mov rax, rbx
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.bd_sort_raised:
    ; A comparison raised: the names were not all strings.  Hand the failure
    ; on rather than a half-sorted list.
.bd_list_failed:
    mov rdi, rbx
    call obj_decref
.bd_propagate:
    RET_NULL
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.bd_no_args:
    ; locals() answers the mapping; dir() is its keys, sorted, which is the
    ; same list-and-sort tail the __dir__ path takes.
    xor edi, edi
    xor esi, esi
    extern builtin_locals
    call builtin_locals
    V_UNPACK rax, rdx
    test edx, edx
    jz .bd_failed
    mov rbx, rax
    xor edi, edi
    call list_new
    mov [rbp - BD_SORT], rax
    mov [rbp - BD_SORT + 8], rbx
    lea rdi, [rbp - BD_SORT]
    mov esi, 2
    call list_method_extend
    push rax
    DECREF_V rbx, rcx           ; the mapping locals() handed us
    pop rax
    mov rbx, [rbp - BD_SORT]
    test rax, rax
    jz .bd_list_failed
    jmp .bd_sort
.bd_failed:
    xor eax, eax
    pop rbx
    leave
    ret

.bd_error:
    CSTRING rdi, "dir expected at most 1 argument, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_dir

section .rodata
dunder_dir_name: db "__dir__", 0
dd_class_name: db "__class__", 0

section .text

section .rodata
fmt_dunder_name: db "__format__", 0

section .text

;; ============================================================================
;; builtin_input_fn(rdi = args, rsi = nargs) - input([prompt])
;;   -> rax = Value
;; 0 args: read line from stdin
;; 1 arg: print prompt, then read line
;; ============================================================================
extern sys_write
extern sys_read

global builtin_input_fn
INP_BUF_SIZE equ 4096
INP_FRAME equ INP_BUF_SIZE + 16  ; buffer + saved values
DEF_FUNC builtin_input_fn, INP_FRAME
    test rsi, rsi
    je .inp_no_prompt
    cmp rsi, 1
    jne .inp_error

    mov rax, [rdi]          ; args[0] = prompt
    V_TEST_PTR rax, rcx
    ja .inp_type_error
    ; The prompt has to appear where a print() around it would.  Writing it
    ; straight to fd 1 put it AHEAD of everything still in stdout's buffer,
    ; so a pdb session's prompts all arrived before the output they were
    ; prompting for.  CPython writes it through sys.stdout and flushes; this
    ; flushes first and then writes, which comes to the same order.
    push rax
    sub rsp, 8
    extern fileobj_flush_std
    call fileobj_flush_std
    add rsp, 8
    pop rax
    mov rsi, rax
    add rsi, PyStrObject.data  ; buf ptr
    mov rdx, [rax + PyStrObject.ob_size]  ; len
    mov edi, 1              ; stdout
    call sys_write

.inp_no_prompt:
    ; ONE LINE, not one bufferful.  A single read of 4095 bytes swallowed the
    ; whole pipe: `input()` twice over "A\nB\n" answered "A\nB" and then "",
    ; because the second call found EOF.  A byte at a time is a syscall per
    ; character, which is the price of not owning a stdin buffer; input() is
    ; not on any hot path.
    xor r8d, r8d                ; bytes so far
.inp_getc:
    cmp r8, INP_BUF_SIZE - 1
    jae .inp_have_line
    push r8
    sub rsp, 8
    lea rsi, [rbp - INP_FRAME]
    add rsi, r8
    mov edx, 1
    xor edi, edi                ; stdin
    call sys_read
    add rsp, 8
    pop r8
    test rax, rax
    jle .inp_eof_or_line        ; 0 = EOF, negative = error
    lea rcx, [rbp - INP_FRAME]
    cmp byte [rcx + r8], 10     ; '\n' ends the line and is not kept
    je .inp_have_line
    inc r8
    jmp .inp_getc

.inp_eof_or_line:
    ; EOF with nothing read at all is CPython's EOFError; EOF after some
    ; characters is a final line with no newline, which is not an error.
    test r8, r8
    jz .inp_eof

.inp_have_line:
    lea rdi, [rbp - INP_FRAME]
    mov byte [rdi + r8], 0
    call str_from_cstr
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.inp_eof:
    extern exc_EOFError_type
    RAISE exc_EOFError_type, "EOF when reading a line"

.inp_error:
    RAISE exc_TypeError_type, "input() takes at most 1 argument"

.inp_type_error:
    RAISE exc_TypeError_type, "input() prompt must be a string"
END_FUNC builtin_input_fn

;; ============================================================================
;; builtin_open_fn(args, nargs) - open(filename[, mode])
;; 1 arg: open for reading ('r')
;; 2 args: open with specified mode
;; ============================================================================
extern sys_open
extern sys_close
extern file_type

global builtin_open_fn
OPN_FRAME equ 32            ; + 3 pushes = 56, not 16-aligned

;; ============================================================================
;; open_reject_dir(rdi = fd, rsi = filename str)
;;   -> returns, or raises IsADirectoryError
;;
;; Linux lets open(2) succeed on a directory; it is read(2) that fails with
;; EISDIR, so open("/tmp") used to hand back a file object that failed later
;; and elsewhere.  CPython fstats the descriptor and raises IsADirectoryError,
;; and the mode bits say the same thing here.
;; ============================================================================
ORD_FD    equ 8
ORD_NAME  equ 16
ORD_STAT  equ 16 + 144      ; struct stat; only st_mode, at byte 24, is read
ORD_FRAME equ ORD_STAT      ; + 0 pushes = 160
DEF_FUNC_LOCAL open_reject_dir, ORD_FRAME
    mov [rbp - ORD_FD], rdi
    mov [rbp - ORD_NAME], rsi
    lea rsi, [rbp - ORD_STAT]
    extern sys_fstat
    call sys_fstat
    test rax, rax
    js .ord_ok                          ; fstat failed: let the read report it
    mov eax, [rbp - ORD_STAT + 24]      ; st_mode is a 4-byte field
    and eax, 0o170000                   ; S_IFMT
    cmp eax, 0o40000                    ; S_IFDIR
    jne .ord_ok
    mov rdi, [rbp - ORD_FD]
    call sys_close
    mov edi, 21                         ; EISDIR
    mov rsi, [rbp - ORD_NAME]
    extern raise_oserror
    call raise_oserror                  ; does not return
.ord_ok:
    leave
    ret
END_FUNC open_reject_dir

section .data
align 8
builtin_open_impl: dq 0

section .rodata
bo_mod_name:  db "_io", 0
bo_attr_name: db "open", 0

section .text

;; ============================================================================
;; builtin_open_fn(rdi = args, rsi = nargs) -> rax = Value, the stream
;;   _io.open builds
;;
;; open() is _io.open in CPython, and the same thing here: the whole stack --
;; buffering, text decoding, universal newlines -- lives above FileIO and
;; there is no reason for the builtin to be a second, worse implementation of
;; it.  What stood here opened a descriptor and returned an object with no
;; buffering, no encoding and no seek.
;;
;; The lookup is lazy and cached.  It cannot happen at startup: builtins is
;; built before the import system can run, and _pyio imports abc, posix and
;; _codecs.
;;
;; Keyword arguments pass straight through.  A builtin is handed its keyword
;; values in the same array, with the names in kw_names_pending, and that is
;; exactly what the callee expects -- so this must NOT consume the global.
;; ============================================================================
DEF_FUNC builtin_open_fn
    push rbx
    push r12
    push r13
    sub rsp, 8                  ; 3 pushes + 8, so rsp is 16-aligned at calls
    mov rbx, rdi
    mov r12, rsi

    mov r13, [rel builtin_open_impl]
    test r13, r13
    jnz .bo_have

    ; The pending keyword names belong to the open() call, not to the import
    ; that is about to run a module body; park them across it.
    mov rax, [rel kw_names_pending]
    push rax
    mov qword [rel kw_names_pending], 0

    lea rdi, [rel bo_mod_name]
    call str_from_cstr_heap
    push rax
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call import_module
    mov r13, rax
    pop rdi
    call obj_decref
    test r13, r13
    jz .bo_import_failed

    lea rdi, [rel bo_attr_name]
    call str_from_cstr_heap
    push rax
    mov rdi, [r13 + PyModuleObject.mod_dict]
    mov rsi, rax
    call dict_get
    mov r13, rax
    pop rdi
    call obj_decref
    test r13, r13
    jz .bo_missing
    mov rdi, r13
    call obj_incref             ; the cache holds it for the process's life
    mov [rel builtin_open_impl], r13

    pop rax
    mov [rel kw_names_pending], rax

.bo_have:
    mov rax, [r13 + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_call]
    test rcx, rcx
    jz .bo_missing
    mov rdi, r13
    mov rsi, rbx
    mov rdx, r12
    call rcx
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    leave
    ret

.bo_import_failed:
    add rsp, 8                  ; the parked keyword names
    cmp qword [rel current_exception], 0
    jne .bo_propagate
    RAISE exc_ImportError_type, "open() requires the _io module"
.bo_propagate:
    leave
    jmp eval_exception_unwind
.bo_missing:
    RAISE exc_ImportError_type, "_io.open is missing"
END_FUNC builtin_open_fn

;; ============================================================================
;; builtin_ascii_fn(rdi = args, rsi = nargs) - ascii(obj)
;;   -> rax = Value
;; Like repr() but escapes non-ASCII characters to \xNN / \uNNNN / \UNNNNNNNN
;; ============================================================================
global builtin_ascii_fn
AA_REPR   equ 8
AA_FRAME  equ 16            ; + 0 pushes = 16
DEF_FUNC builtin_ascii_fn, AA_FRAME

    cmp rsi, 1
    jne .aa_nargs_error

    ; Get repr(obj)
    mov rdi, [rdi]            ; args[0]
    call obj_repr
    test edx, edx
    jz .aa_repr_failed        ; a raising __repr__, not a wrong arity

    ; Check if all chars are ASCII (fast path)
    mov [rbp - AA_REPR], rax
    lea rsi, [rax + PyStrObject.data]
    mov rcx, [rax + PyStrObject.ob_size]
    xor edx, edx              ; edx = index
.aa_check_loop:
    cmp edx, ecx
    jge .aa_all_ascii
    movzx eax, byte [rsi + rdx]
    cmp eax, 128
    jae .aa_need_escape
    inc edx
    jmp .aa_check_loop

.aa_all_ascii:
    ; Repr is all ASCII — just return it
    mov rax, [rbp - AA_REPR]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.aa_need_escape:
    ; We need to build a new string with non-ASCII chars escaped
    ; For simplicity, allocate a buffer big enough (4x original + 1)
    push rbx
    push r12
    push r13

    mov rbx, [rbp - AA_REPR]  ; rbx = repr str
    mov r12, [rbx + PyStrObject.ob_size]  ; r12 = original length
    ; Worst case is \uXXXX -- six characters from a two-byte source, so three
    ; per input byte; \UXXXXXXXX is ten from four, which is less.
    lea rdi, [r12*4 + 16]
    call ap_malloc
    mov r13, rax               ; r13 = output buffer

    lea rsi, [rbx + PyStrObject.data]  ; rsi = input
    mov rdi, r13               ; rdi = output
    xor ecx, ecx              ; ecx = input index
.aa_escape_loop:
    cmp ecx, r12d
    jge .aa_escape_done
    movzx eax, byte [rsi + rcx]
    cmp eax, 128
    jae .aa_do_escape
    mov byte [rdi], al
    inc rdi
    inc ecx
    jmp .aa_escape_loop

.aa_do_escape:
    ; A CODEPOINT, not a byte.  This escaped each UTF-8 byte on its own, so
    ; ascii("\u4e2d") answered '\xe4\xb8\xad' rather than '\u4e2d' -- three
    ; escapes for one character, and not something eval() reads back.
    push rcx
    push rsi
    push rdi
    push r12
    mov rdi, rsi
    mov rsi, rcx
    extern ucase_utf8_get
    call ucase_utf8_get         ; eax = codepoint, ecx = its width
    mov r8d, eax
    mov r9d, ecx
    pop r12
    pop rdi
    pop rsi
    pop rcx

    lea r11, [rel aa_hexdigits]
    mov byte [rdi], '\'
    cmp r8d, 0x100
    jae .aa_esc_u
    mov byte [rdi + 1], 'x'
    mov r10d, 2
    jmp .aa_esc_digits
.aa_esc_u:
    cmp r8d, 0x10000
    jae .aa_esc_bigu
    mov byte [rdi + 1], 'u'
    mov r10d, 4
    jmp .aa_esc_digits
.aa_esc_bigu:
    mov byte [rdi + 1], 'U'
    mov r10d, 8
.aa_esc_digits:
    add rdi, 2
    mov eax, r10d
.aa_esc_digit:
    test eax, eax
    jz .aa_esc_done
    dec eax
    push rcx
    mov ecx, eax
    shl ecx, 2
    mov edx, r8d
    shr edx, cl
    pop rcx
    and edx, 0x0f
    movzx edx, byte [r11 + rdx]
    mov [rdi], dl
    inc rdi
    jmp .aa_esc_digit
.aa_esc_done:
    add ecx, r9d
    jmp .aa_escape_loop

.aa_escape_done:
    mov qword [rdi], 0         ; 8-byte zero-fill for ap_strcmp
    sub rdi, r13               ; rdi = output length

    ; Create string from buffer
    mov rdi, r13
    call str_from_cstr
    push rax
    push rdx

    ; Free buffer
    mov rdi, r13
    call ap_free

    ; DECREF original repr
    mov rdi, rbx
    call obj_decref

    pop rdx
    pop rax
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.aa_repr_failed:
    ; obj_repr raised and its exception is pending.  This shared the arity
    ; label, which both buried that exception and read rsi -- long since
    ; something else -- as the argument count: "ascii() takes exactly one
    ; argument (184 given)".
    xor eax, eax
    xor edx, edx
    leave
    ret

.aa_nargs_error:
    CSTRING rdx, " given)"
    CSTRING rdi, "ascii() takes exactly one argument ("
    extern raise_type_error_counted
    jmp raise_type_error_counted
section .rodata
aa_hexdigits: db "0123456789abcdef"
section .text
END_FUNC builtin_ascii_fn

;; ============================================================================
;; builtin_format_fn(rdi = args, rsi = nargs) - format(value[, format_spec])
;;   -> rax = Value
;; Calls value.__format__(format_spec) or str(value) if no __format__
;; ============================================================================
global builtin_format_fn
FMT_OBJ     equ 8
FMT_SPEC    equ 24
FMT_FRAME   equ 24          ; + 1 push = 32, 16-aligned
;
; 24 and a push, not 32 and an unseen one: the `push rbx` used to come after
; the arity branch, where lint's counter -- which stops at the first non-push
; instruction -- could not see it.  The declared frame was then the one that
; balanced ZERO pushes, and the body ran eight bytes out with dunder_call_2
; into arbitrary Python inside it.
DEF_FUNC builtin_format_fn, FMT_FRAME
    push rbx

    cmp rsi, 1
    jb .fmt_too_few
    cmp rsi, 2
    ja .fmt_nargs_error

    mov rbx, rsi               ; rbx = nargs

    ; Save obj.  args[0] is a Value; the slot below used to be filled from
    ; args[1] as though it were a separate tag, which is what the fat-value
    ; representation looked like -- so it held the format spec instead.
    mov rax, [rdi]
    mov [rbp - FMT_OBJ], rax

    ; Get format spec (empty string if not provided)
    cmp rbx, 2
    jb .fmt_empty_spec
    mov rax, [rdi + 8]
    mov [rbp - FMT_SPEC], rax
    ; The spec is read as a PyStrObject below, so it has to BE one: `format
    ; (0, 0)` read a small integer's Value as one.  CPython names the
    ; argument and the type it got.
    V_TEST_PTR rax, rcx
    ja .fmt_spec_error
    test rax, rax
    jz .fmt_spec_error
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    je .fmt_have_spec
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .fmt_spec_error
    jmp .fmt_have_spec

.fmt_empty_spec:
    CSTRING rdi, ""
    call str_from_cstr
    mov [rbp - FMT_SPEC], rax

.fmt_have_spec:
    ; A class defining __format__ formats itself.  This used to fall straight
    ; through to str(), so f"{obj:>5}" ignored both the spec and the method.
    V_TEST_PTR_M [rbp - FMT_OBJ], rcx
    ja .fmt_apply_spec
    mov rdi, [rbp - FMT_OBJ]
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .fmt_apply_spec
    mov rsi, [rbp - FMT_SPEC]
    extern dunder_call_2
    lea rdx, [rel fmt_dunder_name]
    mov ecx, TAG_PTR
    call dunder_call_2
    V_UNPACK rax, rdx
    test edx, edx
    jnz .fmt_dunder_ok
    ; NULL means either "no __format__" or "__format__ raised"; falling
    ; through in the second case replaced the real exception.
    cmp qword [rel current_exception], 0
    jne .fmt_propagate
    jmp .fmt_apply_spec
.fmt_dunder_ok:
    ; It has to BE a str.  Nothing checked, so `def __format__(self, spec):
    ; return 5` handed an int to f-strings and to str.format, both of which
    ; then read a string out of it.
    push rax
    push rdx
    mov rdi, rax
    mov rsi, rdx
    extern format_require_str
    call format_require_str     ; a str, or it does not return
    pop rdx
    pop rax
    ; If an empty spec was allocated here, release it.
    cmp rbx, 2
    jge .fmt_done
    push rax
    push rdx
    mov rdi, [rbp - FMT_SPEC]
    call obj_decref
    pop rdx
    pop rax
    jmp .fmt_done

.fmt_propagate:
    extern eval_exception_unwind
    leave
    jmp eval_exception_unwind

.fmt_apply_spec:
    ; Not a class with its own __format__: apply the spec directly.
    extern format_apply_spec
    mov rdi, [rbp - FMT_OBJ]
    mov rsi, [rbp - FMT_SPEC]
    call format_apply_spec
    V_UNPACK rax, rdx
    cmp rbx, 2
    jge .fmt_done
    push rax
    push rdx
    mov rdi, [rbp - FMT_SPEC]
    call obj_decref
    pop rdx
    pop rax
    jmp .fmt_done

.fmt_use_str:
    ; Just call str(value) — simple fallback
    mov rdi, [rbp - FMT_OBJ]    ; already a Value
    call obj_str
    ; If we allocated an empty spec, DECREF it
    cmp rbx, 2
    jge .fmt_done
    push rax
    push rdx
    mov rdi, [rbp - FMT_SPEC]
    call obj_decref
    pop rdx
    pop rax
.fmt_done:
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.fmt_too_few:
    ; rsi is still nargs at both of these.
    CSTRING rdi, "format expected at least 1 argument, got "
    xor edx, edx
    jmp raise_type_error_counted

.fmt_nargs_error:
    CSTRING rdi, "format expected at most 2 arguments, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted

.fmt_spec_error:
    pop rbx
    mov rsi, [rbp - FMT_SPEC]
    CSTRING rdi, `format() argument 2 must be str, not \x02`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
END_FUNC builtin_format_fn

;; ============================================================================
;; builtin_vars_fn(rdi = args, rsi = nargs) - vars([obj])
;;   -> rax = Value
;; 0 args: returns frame locals dict (same as locals())
;; 1 arg: returns obj.__dict__
;; ============================================================================
extern eval_saved_r12
global builtin_vars_fn
VR_OBJ   equ 8
VR_EXC   equ 16
VR_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC builtin_vars_fn, VR_FRAME

    test rsi, rsi
    jz .vars_no_arg
    cmp rsi, 1
    jne .vars_nargs_error

    ; vars(obj): return obj.__dict__
    mov rax, [rdi]
    mov [rbp - VR_OBJ], rax     ; kept for the general path below
    V_TEST_PTR_M [rdi], rax   ; args[0] a pointer?
    ja .vars_ask

    mov rdi, [rdi]            ; obj pointer
    ; Try inst_dict (user-defined class instances)
    mov rax, [rdi + PyObject.ob_type]
    mov rcx, [rax + PyTypeObject.tp_flags]
    test ecx, TYPE_FLAG_HEAPTYPE
    jz .vars_ask

    ; A __slots__ class has no __dict__, so vars() has nothing to answer with:
    ; CPython's TypeError, rather than the empty dict the arm below invents.
    test rcx, TYPE_FLAG_HAS_SLOTS
    jnz .vars_ask

    ; User instance: get the instance dict.  The offset is the type's, not a
    ; constant -- a dict, list or str subclass puts its __dict__ past its own
    ; storage, and reading PyInstanceObject.inst_dict on one of those lands
    ; inside the base object's header.  For a populated dict subclass that
    ; word is a live pointer, which this then increfs and returned as a dict:
    ; vars(D()) after a single d['a'] = 1 was a segfault.
    LOAD_INST_DICT rax, rdi, .vars_ask
    test rax, rax
    jz .vars_ask                ; see below
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

    ; A NULL instance dict used to answer with a fresh, DETACHED one here, so
    ; `vars(o)['x'] = 1` silently did not stick and `vars(o) is o.__dict__` was
    ; False.  It only mattered for int and bytes subclasses then; now that
    ; instance_new leaves the slot NULL until something needs it, every fresh
    ; instance reaches this.  .vars_ask goes through obj_getattr_opt to
    ; __dict__, whose .oga_dict arm creates one AND attaches it -- two paths
    ; that happened to agree become one path.

.vars_no_arg:
    ; Same as locals()
    extern builtin_locals
    xor edi, edi
    xor esi, esi
    call builtin_locals         ; already returns a Value
    leave
    ret

.vars_ask:
    ; Everything the fast path above does not recognise -- a module, a class,
    ; a function, an instance of a builtin type -- still has a __dict__ if it
    ; has one at all, and CPython's vars() is nothing but PyObject_GetAttr for
    ; that name.  Reading it the ordinary way is also what makes a
    ; __getattr__ that supplies one work, and it is what `vars(some_module)`
    ; needs: sre_constants builds its module namespace out of one.
    DUNDER_EXC_SAVE [rbp - VR_EXC]
    lea rdi, [rel vars_dict_name]
    call dunder_name_obj
    test rax, rax
    jz .vars_no_dict
    mov rsi, rax
    mov rdi, [rbp - VR_OBJ]
    call obj_getattr_opt
    test rax, rax
    jz .vars_ask_failed
    leave
    ret

.vars_ask_failed:
    ; An AttributeError here means "no __dict__", which is the TypeError
    ; below; anything else is a real failure and must not be reworded.
    DUNDER_RAISED [rbp - VR_EXC], .vars_ask_raised
    jmp .vars_no_dict
.vars_ask_raised:
    mov rax, [rel current_exception]
    test rax, rax
    jz .vars_no_dict
    mov rdi, [rax + PyObject.ob_type]
    lea rsi, [rel exc_AttributeError_type]
    call type_is_subtype
    test eax, eax
    jz .vars_propagate
    mov rdi, [rel current_exception]
    mov qword [rel current_exception], 0
    call obj_decref
    jmp .vars_no_dict
.vars_propagate:
    xor eax, eax
    leave
    ret

.vars_no_dict:
    RAISE exc_TypeError_type, "vars() argument must have __dict__ attribute"

.vars_nargs_error:
    CSTRING rdi, "vars expected at most 1 argument, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_vars_fn

section .rodata
vars_dict_name: db "__dict__", 0
section .text

;; ============================================================================
;; builtin_aiter_fn(rdi = args, rsi = nargs) - aiter(async_iterable)
;;   -> rax = Value
;; Calls tp_iter on the async iterable
;; ============================================================================
AIT_ARG   equ 8             ; the argument, for the message
AIT_NARGS equ 16
AIT_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC builtin_aiter_fn, AIT_FRAME
    mov [rbp - AIT_NARGS], rsi

    cmp rsi, 1
    jne .aiter_nargs_error

    ; Get the object
    mov rdi, [rdi]            ; args[0]
    mov [rbp - AIT_ARG], rdi

    ; Must be a heap pointer
    V_TEST_PTR rdi, rsi
    ja .aiter_type_error
    test rdi, rdi
    jz .aiter_type_error

    ; __aiter__, not __iter__: a list has a tp_iter and is not an async
    ; iterable at all, so `aiter([])` answered its ordinary list_iterator.
    push rdi
    extern dunder_lookup
    mov rdi, [rdi + PyObject.ob_type]
    CSTRING rsi, "__aiter__"
    call dunder_lookup
    pop rdi
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    jz .aiter_type_error
    ; Call tp_iter
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz .aiter_type_error

    call rax                   ; tp_iter returns rax=ptr only
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.aiter_type_error:
    mov rsi, [rbp - AIT_ARG]
    CSTRING rdi, `'\x01' object is not an async iterable`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.aiter_nargs_error:
    mov rsi, [rbp - AIT_NARGS]
    CSTRING rdi, "aiter() takes exactly one argument ("
    CSTRING rdx, " given)"
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC builtin_aiter_fn

;; ============================================================================
;; builtin_anext_fn(rdi = args, rsi = nargs) - anext(async_iterator[, default])
;;   -> rax = Value
;; Calls tp_iternext; on StopAsyncIteration returns default
;; ============================================================================
extern current_exception
global builtin_anext_fn
AN_ITER    equ 8
AN_DEFAULT equ 16
AN_DEFTAG  equ 24
AN_NARGS   equ 32
AN_FRAME   equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC builtin_anext_fn, AN_FRAME

    mov [rbp - AN_NARGS], rsi
    cmp rsi, 1
    jb .an_nargs_error
    cmp rsi, 2
    ja .an_nargs_error


    ; Save iterator.  Its ob_type is read below without asking whether it is
    ; a pointer at all, so `anext(0)` read a small integer's Value as one.
    mov rax, [rdi]
    mov [rbp - AN_ITER], rax
    V_TEST_PTR rax, rcx
    ja .an_type_error
    test rax, rax
    jz .an_type_error

    ; Save default if present
    cmp rsi, 2
    jb .an_no_default
    mov rax, [rdi + 8]
    V_UNPACK rax, rdx
    mov [rbp - AN_DEFAULT], rax
    mov [rbp - AN_DEFTAG], rdx
    jmp .an_call

.an_no_default:
    mov qword [rbp - AN_DEFAULT], 0
    mov qword [rbp - AN_DEFTAG], 0

.an_call:
    ; Call tp_iternext
    mov rdi, [rbp - AN_ITER]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .an_type_error

    mov rdi, [rbp - AN_ITER]
    call rax                   ; returns (rax, edx)
    V_UNPACK rax, rdx           ; tp_iternext returns a Value
    test edx, edx
    jnz .an_got_value

    ; Got NULL — check if we have a default
    cmp qword [rbp - AN_NARGS], 2
    jb .an_reraise

    ; Clear the exception and return default
    mov qword [rel current_exception], 0
    mov rax, [rbp - AN_DEFAULT]
    mov edx, [rbp - AN_DEFTAG]
    INCREF_VAL rax, rdx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.an_got_value:
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.an_reraise:
    ; No default — let the exception propagate
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.an_type_error:
    mov rsi, [rbp - AN_ITER]
    CSTRING rdi, `'\x01' object is not an async iterator`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.an_nargs_error:
    ; CPython's two, with the count: it words the low bound and the high one
    ; differently, and a program greps the text.
    mov rsi, [rbp - AN_NARGS]
    cmp rsi, 1
    jge .an_too_many
    CSTRING rdi, "anext expected at least 1 argument, got "
    xor edx, edx
    extern raise_type_error_counted
    jmp raise_type_error_counted
.an_too_many:
    CSTRING rdi, "anext expected at most 2 arguments, got "
    xor edx, edx
    jmp raise_type_error_counted
END_FUNC builtin_anext_fn

;; ============================================================================
;; builtin_import_fn(rdi = args, rsi = nargs) - __import__(name, globals,
;;                                     locals, fromlist, level)
;;   -> rax = Value
;;
;; fromlist decides WHICH module comes back: empty or None gives the top-level
;; package, non-empty gives the module actually named.  Ignoring it returned
;; `encodings` where `encodings.utf_8` was asked for, which is why
;; encodings.search_function found no getregentry and codecs.lookup("utf-8")
;; reported an unknown encoding.
;;
;; globals and locals are still ignored: they only matter for a relative
;; import, and level > 0 is rejected below rather than silently mishandled.
;; ============================================================================
extern kw_names_pending
extern sys_modules_dict
extern dict_get
extern obj_as_index
extern exc_NotImplementedError_type
extern ap_strcmp
extern tuple_type
extern tuple_new
extern list_type
extern import_module

BIM_ARGS     equ 8
BIM_FROMLIST equ 16
BIM_LEVEL    equ 24
BIM_NAME     equ 32
BIM_NPOS     equ 40
BIM_TEMP     equ 48         ; a wrapped fromlist, released before returning
BIM_FRAME    equ 64         ; + 0 pushes = 64

DEF_FUNC builtin_import_fn, BIM_FRAME
    mov [rbp - BIM_ARGS], rdi
    mov [rbp - BIM_NPOS], rsi
    mov qword [rbp - BIM_FROMLIST], 0
    mov qword [rbp - BIM_LEVEL], 0
    mov qword [rbp - BIM_TEMP], 0
    ; BIM_NAME belongs in this block too: .imp_check_name reads 0 as "no name
    ; was given", and with neither a positional argument nor name= nothing
    ; ever wrote the slot -- so `__import__()` tested uninitialised stack and
    ; then used it as a PyStrObject*.
    mov qword [rbp - BIM_NAME], 0

    ; Keyword arguments sit after the positional ones, named in order by
    ; kw_names_pending.  Consume it: a builtin that leaves it set hands its
    ; caller's keywords to whatever call runs next -- and this one runs a
    ; whole module body before it returns.
    mov rax, [rel kw_names_pending]
    mov qword [rel kw_names_pending], 0
    test rax, rax
    jz .imp_have_pos

    mov rcx, [rax + PyTupleObject.ob_size]
    sub qword [rbp - BIM_NPOS], rcx     ; the positional count alone
    xor r9d, r9d
.imp_kw_loop:
    cmp r9, rcx
    jge .imp_have_pos
    push rcx
    push rax
    push r9
    sub rsp, 8                          ; align for ap_strcmp

    mov r10, [rax + PyTupleObject.ob_item]
    mov r10, [r10 + r9*8]               ; the keyword's name
    mov r11, [rbp - BIM_NPOS]
    add r11, r9
    mov rdi, [rbp - BIM_ARGS]
    mov r11, [rdi + r11*8]              ; its value

    push r11
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "fromlist"
    call ap_strcmp
    pop r11
    test eax, eax
    jz .imp_kw_fromlist

    push r11
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "level"
    call ap_strcmp
    pop r11
    test eax, eax
    jz .imp_kw_level

    ; globals= and locals= are accepted and ignored, as the positional forms
    ; are; anything else is a genuine error.
    push r11
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "globals"
    call ap_strcmp
    pop r11
    test eax, eax
    jz .imp_kw_next
    push r11
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "locals"
    call ap_strcmp
    pop r11
    test eax, eax
    jz .imp_kw_next
    push r11
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "name"
    call ap_strcmp
    pop r11
    test eax, eax
    jnz .imp_kw_bad
    add rsp, 8
    pop r9
    pop rax
    pop rcx
    mov [rbp - BIM_NAME], r11
    inc r9
    jmp .imp_kw_loop
.imp_kw_fromlist:
    mov [rbp - BIM_FROMLIST], r11
    jmp .imp_kw_next
.imp_kw_level:
    mov [rbp - BIM_LEVEL], r11
.imp_kw_next:
    add rsp, 8
    pop r9
    pop rax
    pop rcx
    inc r9
    jmp .imp_kw_loop

.imp_have_pos:
    ; Positional: name, globals, locals, fromlist, level
    mov rdi, [rbp - BIM_ARGS]
    mov rsi, [rbp - BIM_NPOS]
    test rsi, rsi
    jz .imp_check_name
    mov rax, [rdi]
    mov [rbp - BIM_NAME], rax
    cmp rsi, 4
    jl .imp_check_name
    mov rax, [rdi + 24]
    mov [rbp - BIM_FROMLIST], rax
    cmp rsi, 5
    jl .imp_check_name
    mov rax, [rdi + 32]
    mov [rbp - BIM_LEVEL], rax

.imp_check_name:
    mov rdi, [rbp - BIM_NAME]
    test rdi, rdi
    jz .imp_nargs_error
    ; And it has to be a str.  import_module reads PyStrObject.data off it, so
    ; an int immediate was a SIGSEGV and a heap singleton was worse than one:
    ; __import__(None) read whatever .rodata sits near None and answered
    ; "No module named 'plemented'".
    V_TEST_PTR rdi, rax
    ja .imp_name_error
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .imp_name_error

    ; level: only 0 is honoured.  A relative import needs the caller's
    ; __package__, which this entry point does not consult, so say so rather
    ; than import the wrong module.
    mov rdi, [rbp - BIM_LEVEL]
    test rdi, rdi
    jz .imp_level_ok
    V_UNPACK rdi, rdx
    call obj_as_index
    test rax, rax
    jnz .imp_level_error
.imp_level_ok:

    ; import_module reads the fromlist as a tuple, so what reaches it has to
    ; be one.  __import__("sys", None, None, 0) -- a falsy fromlist CPython
    ; accepts -- faulted on ob_size; None was the only shape rejected here.
    ; A list is passed through, since that is what `from x import *` compiles
    ; to and it carries ob_size in the same place; anything else truthy is
    ; wrapped, so "there is a fromlist" survives without handing over a shape
    ; that will be dereferenced as one.
    mov rax, [rbp - BIM_FROMLIST]
    test rax, rax
    jz .imp_do
    V_TEST_PTR rax, rcx
    ja .imp_no_fromlist         ; an immediate is not a sequence of names
    LOAD_NONE rcx
    cmp rax, rcx
    je .imp_no_fromlist
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    je .imp_do
    lea rdx, [rel list_type]
    cmp rcx, rdx
    je .imp_do

    mov rdi, rax
    call obj_is_true
    test eax, eax
    jz .imp_no_fromlist
    mov edi, 1
    call tuple_new
    test rax, rax
    jz .imp_no_fromlist
    mov [rbp - BIM_TEMP], rax
    mov rcx, [rbp - BIM_FROMLIST]
    mov rdx, [rax + PyTupleObject.ob_item]
    mov [rdx], rcx
    mov rax, rcx
    INCREF_V rax, rcx
    mov rax, [rbp - BIM_TEMP]
    mov [rbp - BIM_FROMLIST], rax
    jmp .imp_do
.imp_no_fromlist:
    mov qword [rbp - BIM_FROMLIST], 0

.imp_do:
    mov rdi, [rbp - BIM_NAME]
    mov rsi, [rbp - BIM_FROMLIST]
    xor edx, edx                ; level = 0
    call import_module
    ; import_module never sets rdx, so V_PACK was branching on whatever the
    ; last call left there -- re-encoding the module *pointer* as an int or a
    ; double, i.e. a Value whose payload is a pointer but whose tag says
    ; otherwise.  A module is a pointer; a pointer is its own Value.
    mov edx, TAG_PTR
    test rax, rax
    jz .imp_failed

    ; With a non-empty fromlist the caller wants the module it named, not the
    ; package that anchors it.  import_module has already put every level in
    ; sys.modules, so the leaf is one lookup away.
    mov rcx, [rbp - BIM_FROMLIST]
    test rcx, rcx
    jz .imp_done
    push rax
    mov rdi, rcx
    call obj_is_true
    mov edx, TAG_PTR            ; obj_is_true clobbers rdx, and the pack below
    test eax, eax               ; branches on it
    pop rax
    jz .imp_done

    push rax                    ; the package, still owned
    mov rdi, [rel sys_modules_dict]
    mov rsi, [rbp - BIM_NAME]
    V_PACK rsi, rdx
    call dict_get
    test rax, rax
    jz .imp_leaf_missing
    V_UNPACK rax, rdx
    INCREF rax                  ; dict_get hands back a borrowed reference
    mov rdi, rax
    pop rax                     ; the package
    push rdi
    call obj_decref
    pop rax
    mov edx, TAG_PTR
    jmp .imp_done
.imp_leaf_missing:
    pop rax                     ; no leaf: the package is the honest answer
    mov edx, TAG_PTR

.imp_done:
    cmp qword [rbp - BIM_TEMP], 0
    je .imp_no_temp
    push rax
    push rdx
    mov rdi, [rbp - BIM_TEMP]
    mov qword [rbp - BIM_TEMP], 0
    call obj_decref
    pop rdx
    pop rax
.imp_no_temp:
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.imp_failed:
    ; NULL means the module body raised and the exception is still pending.
    extern current_exception
    extern eval_exception_unwind
    cmp qword [rel current_exception], 0
    jne .imp_propagate
    extern exc_ImportError_type
    RAISE exc_ImportError_type, "import failed"
.imp_propagate:
    leave
    jmp eval_exception_unwind

.imp_kw_bad:
    add rsp, 8
    pop r9
    pop rax
    pop rcx
    RAISE exc_TypeError_type, "__import__() got an unexpected keyword argument"
.imp_level_error:
    RAISE exc_NotImplementedError_type, "__import__(): relative import is not supported"
.imp_nargs_error:
    RAISE exc_TypeError_type, "__import__() requires at least 1 argument"
.imp_name_error:
    RAISE exc_TypeError_type, "module name must be a string"
END_FUNC builtin_import_fn

;; ============================================================================
;; builtin_breakpoint(rdi = args, rsi = nargs) - breakpoint() stub (no-op)
;;   -> rax = Value
;; ============================================================================
DEF_FUNC_BARE builtin_breakpoint
    ; No-op: return None
    xor eax, eax
    RET_NONE
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC builtin_breakpoint
