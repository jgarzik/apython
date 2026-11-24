; bytearray_methods.asm - bytearray's share of bytes' methods
;
; bytes keeps its data inline and bytearray keeps it out of line, so the
; bytes bodies cannot read a bytearray directly.  Each read-only method is a
; trampoline that copies self into a temporary bytes, runs the bytes body on
; it and wraps the answer back -- and this file is that block, split out of
; methods/bytes.asm when it crossed the 100k cap.

%include "macros.inc"
%include "object.inc"

extern bool_false
extern bool_true
extern _bytes_decode_impl
extern bytes_method_count
extern bytes_method_endswith
extern bytes_method_find
extern bytes_method_hex
extern bytes_method_index
extern bytes_method_join
extern bytes_method_lstrip
extern bytes_method_partition
extern bytes_method_replace
extern bytes_method_rfind
extern bytes_method_rindex
extern bytes_method_rpartition
extern bytes_method_rsplit
extern bytes_method_rstrip
extern bytes_method_split
extern bytes_method_startswith
extern bytes_method_strip
extern exc_MemoryError_type
extern none_singleton
extern bytes_type
extern bytearray_type
extern str_type
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_IndexError_type
extern set_exception
extern obj_decref
extern obj_incref
extern bytearray_new
extern bytearray_data
extern bytes_from_data
extern bytearray_from_data
extern bytearray_subscript
extern bytearray_ass_subscript
extern bytearray_contains
extern bytearray_tp_iter
extern bytes_from_bytes_like
extern list_type
extern list_new
extern list_append
extern tuple_type

section .text

;; ============================================================================
;; bytearray's share of bytes' read-only methods.
;;
;; bytes keeps its data inline and bytearray keeps it out of line, so the
;; bytes bodies cannot read a bytearray directly.  Rather than thread a
;; (pointer, length) pair through sixty-odd read sites in two files -- churn
;; on the hot, well-tested type for the benefit of the scratch one -- each
;; wrapper builds a temporary bytes, runs the bytes body on it and releases
;; it.  A bytearray is a scratch buffer by definition; the copy is cheap
;; against the risk of that refactor, and it is the sort of thing to revisit
;; only if bytearray ever becomes hot.
;;
;; Some of these answer with a bytes-like where CPython answers with a
;; bytearray, so the result is converted back where it should be.
;; ============================================================================
BSC_ARGS  equ 8
BSC_NARGS equ 16
BSC_TMP   equ 24            ; the temporary bytes standing in for self
BSC_COPY  equ 32            ; the argument array with args[0] replaced
BSC_RES   equ 40
BSC_FRAME equ 64            ; + 1 push = 72... see the DEF_FUNC below

;; bytearray_shared_call(rdi = args, rsi = nargs, rdx = the bytes body,
;;                       ecx = 0 raw / 1 wrap a bytes-like / 2 wrap a list)
;;   -> the body's Value
;; Fails: 0
DEF_FUNC bytearray_shared_call, 72
    push rbx
    mov [rbp - BSC_ARGS], rdi
    mov [rbp - BSC_NARGS], rsi
    mov [rbp - BSC_RES], rdx
    mov rbx, rcx                ; the wrap mode

    test rsi, rsi
    jz .bsc_bad
    mov rdi, [rdi]              ; self
    mov r8, [rdi + PyByteArrayObject.ob_size]
    push r8
    call bytearray_data
    pop r8
    mov rdi, rax
    mov rsi, r8
    call bytes_from_data
    test rax, rax
    jz .bsc_oom
    mov [rbp - BSC_TMP], rax

    ; Copy the arguments, with args[0] swapped for the temporary.  Eight
    ; slots is more than any of these methods takes.
    mov rcx, [rbp - BSC_NARGS]
    cmp rcx, 8
    ja .bsc_bad_free
    sub rsp, 64
    mov [rbp - BSC_COPY], rsp
    mov rax, [rbp - BSC_TMP]
    mov [rsp], rax
    mov rsi, [rbp - BSC_ARGS]
    mov edx, 1
.bsc_copy_loop:
    cmp rdx, rcx
    jge .bsc_copied
    mov rax, [rsi + rdx*8]
    mov [rsp + rdx*8], rax
    inc rdx
    jmp .bsc_copy_loop
.bsc_copied:
    mov rdi, rsp
    mov rsi, [rbp - BSC_NARGS]
    call qword [rbp - BSC_RES]
    add rsp, 64
    mov [rbp - BSC_RES], rax

    mov rdi, [rbp - BSC_TMP]
    call obj_decref

    mov rax, [rbp - BSC_RES]
    test rax, rax
    jz .bsc_out                 ; it raised, or answered NULL
    cmp rbx, 1
    je .bsc_wrap_one
    cmp rbx, 2
    je .bsc_wrap_list
.bsc_out:
    pop rbx
    leave
    ret

.bsc_wrap_one:
    ; A bytes result becomes a bytearray, as CPython's does -- and the bytes
    ; the body made is released, which it was not.
    mov [rbp - BSC_RES], rax
    mov rdi, rax
    call bytearray_from_bytes
    mov [rbp - BSC_TMP], rax
    mov rdi, [rbp - BSC_RES]
    call obj_decref
    mov rax, [rbp - BSC_TMP]
    pop rbx
    leave
    ret

.bsc_wrap_list:
    ; Every element of the list, likewise.
    mov [rbp - BSC_RES], rax
    mov rcx, [rax + PyListObject.ob_size]
    xor esi, esi
.bsc_wrap_loop:
    cmp rsi, rcx
    jge .bsc_wrapped
    mov rax, [rbp - BSC_RES]
    mov rax, [rax + PyListObject.ob_item]
    mov rdi, [rax + rsi*8]
    push rsi
    push rcx
    call bytearray_from_bytes
    pop rcx
    pop rsi
    test rax, rax
    jz .bsc_wrapped
    mov rdx, [rbp - BSC_RES]
    mov rdx, [rdx + PyListObject.ob_item]
    push rax
    push rsi
    mov rdi, [rdx + rsi*8]
    call obj_decref             ; the bytes the body made
    pop rsi
    pop rax
    mov rdx, [rbp - BSC_RES]
    mov rdx, [rdx + PyListObject.ob_item]
    mov [rdx + rsi*8], rax
    mov rcx, [rbp - BSC_RES]
    mov rcx, [rcx + PyListObject.ob_size]
    inc rsi
    jmp .bsc_wrap_loop
.bsc_wrapped:
    mov rax, [rbp - BSC_RES]
    pop rbx
    leave
    ret

.bsc_bad_free:
    mov rdi, [rbp - BSC_TMP]
    call obj_decref
.bsc_bad:
    SET_EXC exc_TypeError_type, "descriptor requires a bytearray object"
    xor eax, eax
    jmp .bsc_out
.bsc_oom:
    SET_EXC exc_MemoryError_type, "out of memory"
    xor eax, eax
    jmp .bsc_out
END_FUNC bytearray_shared_call

;; bytearray_from_bytes(rdi = a bytes, borrowed) -> rax = a new bytearray
DEF_FUNC bytearray_from_bytes, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    V_TEST_PTR rdi, rax
    ja .bfb_passthrough
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    jne .bfb_passthrough        ; not a bytes: hand it back untouched
    mov rsi, [rbx + PyBytesObject.ob_size]
    lea rdi, [rbx + PyBytesObject.data]
    call bytearray_new
    pop rbx
    leave
    ret
.bfb_passthrough:
    mov rax, rbx
    pop rbx
    leave
    ret
END_FUNC bytearray_from_bytes

;; ============================================================================
;; ba_shared_hex(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.hex, run as bytes_method_hex over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
;; BA_SHARED suffix, impl, wrap -- one bytearray method that is a bytes method
;;
;; Each generates ba_shared_<suffix>(rdi = args, rsi = nargs) -> rax = Value.
;;
;; Forty of these existed as forty copies of the same four instructions,
;; identical except for which bytes body to run and how to wrap the result.
;; Each defines ba_shared_<suffix> and tail-jumps into bytearray_shared_call,
;; which builds the temporary bytes, runs the body over it and converts what
;; comes back -- `wrap` says how: 0 raw, 1 a bytes-like, 2 a list of them.
;;
;; DEF_FUNC_BARE, not DEF_FUNC: the whole body is a tail jump, and a function
;; that has pushed rbp cannot make one.  That is also why the copies all had a
;; `leave` before the `jmp`, which this does not need.
;;
;; The per-method docblocks stay above their invocations, because what each
;; one says -- which bytes method answers, and why the wrapping differs -- is
;; the only thing that varies.
;; ============================================================================
%macro BA_SHARED 3              ; %1 = suffix, %2 = bytes body, %3 = wrap mode
    extern %2
DEF_FUNC_BARE ba_shared_ %+ %1
    lea rdx, [rel %2]
%if %3 == 0
    xor ecx, ecx
%else
    mov ecx, %3
%endif
    jmp bytearray_shared_call
END_FUNC ba_shared_ %+ %1
%endmacro

;; ============================================================================
BA_SHARED hex, bytes_method_hex, 0

;; ============================================================================
;; ba_shared_startswith(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.startswith, run as bytes_method_startswith over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED startswith, bytes_method_startswith, 0

;; ============================================================================
;; ba_shared_endswith(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.endswith, run as bytes_method_endswith over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED endswith, bytes_method_endswith, 0

;; ============================================================================
;; ba_shared_count(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.count, run as bytes_method_count over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED count, bytes_method_count, 0

;; ============================================================================
;; ba_shared_find(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.find, run as bytes_method_find over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED find, bytes_method_find, 0

;; ============================================================================
;; ba_shared_decode(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.decode, run as _bytes_decode_impl over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED decode, _bytes_decode_impl, 0

;; ============================================================================
;; ba_shared_replace(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.replace, run as bytes_method_replace over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED replace, bytes_method_replace, 1

;; ============================================================================
;; ba_shared_split(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.split, run as bytes_method_split over a temporary bytes;
;; the result becomes a list of bytearrays.
;; ============================================================================
BA_SHARED split, bytes_method_split, 2

;; ============================================================================
;; ba_shared_rsplit(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.rsplit, run as bytes_method_rsplit over a temporary bytes;
;; the result becomes a list of bytearrays.
;; ============================================================================
BA_SHARED rsplit, bytes_method_rsplit, 2

;; ============================================================================
;; ba_shared_rfind(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.rfind, run as bytes_method_rfind over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED rfind, bytes_method_rfind, 0

;; ============================================================================
;; ba_shared_index(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.index, run as bytes_method_index over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED index, bytes_method_index, 0

;; ============================================================================
;; ba_shared_rindex(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.rindex, run as bytes_method_rindex over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED rindex, bytes_method_rindex, 0

;; ============================================================================
;; ba_shared_strip(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.strip, run as bytes_method_strip over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED strip, bytes_method_strip, 1

;; ============================================================================
;; ba_shared_lstrip(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.lstrip, run as bytes_method_lstrip over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED lstrip, bytes_method_lstrip, 1

;; ============================================================================
;; ba_shared_rstrip(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.rstrip, run as bytes_method_rstrip over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED rstrip, bytes_method_rstrip, 1

;; ============================================================================
;; ba_shared_partition(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.partition, run as bytes_method_partition over a temporary bytes;
;; the result becomes a list of bytearrays.
;; ============================================================================
BA_SHARED partition, bytes_method_partition, 2

;; ============================================================================
;; ba_shared_rpartition(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.rpartition, run as bytes_method_rpartition over a temporary bytes;
;; the result becomes a list of bytearrays.
;; ============================================================================
BA_SHARED rpartition, bytes_method_rpartition, 2

;; ============================================================================
;; ba_shared_join(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.join, run as bytes_method_join over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED join, bytes_method_join, 1

;; ============================================================================
;; bytearray_dunder_len(rdi = args, rsi = nargs) -> rax = Value
;; Fails: 0
;;
;; The slots, reachable by name.  __setitem__ and __delitem__ especially:
;; CPython's own code calls them directly, and `del b[i]` compiles to
;; DELETE_SUBSCR but `b.__delitem__(i)` does not.
;; ============================================================================
DEF_FUNC bytearray_dunder_len
    REQUIRE_SELF bytearray_type, "__len__"
    test rsi, rsi
    jz .badl_bad
    mov rdi, [rdi]
    mov rax, [rdi + PyByteArrayObject.ob_size]
    V_PACK_I64 rax, rcx
    mov edx, TAG_PTR
    leave
    ret
.badl_bad:
    SET_EXC exc_TypeError_type, "expected exactly one argument"
    xor eax, eax
    leave
    ret
END_FUNC bytearray_dunder_len

;; ============================================================================
;; bytearray_dunder_iter(rdi = args, rsi = nargs) -> rax = Value
;; Fails: 0
;; bytearray.__iter__, reached by name rather than through the slot.
;; ============================================================================
DEF_FUNC bytearray_dunder_iter
    REQUIRE_SELF bytearray_type, "__iter__"
    test rsi, rsi
    jz .badi_bad
    mov rdi, [rdi]
    call bytearray_tp_iter
    mov edx, TAG_PTR
    leave
    ret
.badi_bad:
    SET_EXC exc_TypeError_type, "expected exactly one argument"
    xor eax, eax
    leave
    ret
END_FUNC bytearray_dunder_iter

;; ============================================================================
;; bytearray_dunder_getitem(rdi = args, rsi = nargs) -> rax = Value
;; Fails: 0
;; bytearray.__getitem__, reached by name rather than through the slot.
;; ============================================================================
DEF_FUNC bytearray_dunder_getitem
    REQUIRE_SELF bytearray_type, "__getitem__"
    cmp rsi, 2
    jne .badg_bad
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call bytearray_subscript
    mov edx, TAG_PTR
    leave
    ret
.badg_bad:
    SET_EXC exc_TypeError_type, "expected exactly one argument"
    xor eax, eax
    leave
    ret
END_FUNC bytearray_dunder_getitem

;; ============================================================================
;; bytearray_dunder_setitem(rdi = args, rsi = nargs) -> rax = Value
;; Fails: 0
;; bytearray.__setitem__, reached by name rather than through the slot.
;; ============================================================================
DEF_FUNC bytearray_dunder_setitem
    REQUIRE_SELF bytearray_type, "__setitem__"
    cmp rsi, 3
    jne .bads_bad
    mov rdx, [rdi + 16]
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call bytearray_ass_subscript
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
.bads_bad:
    SET_EXC exc_TypeError_type, "expected exactly two arguments"
    xor eax, eax
    leave
    ret
END_FUNC bytearray_dunder_setitem

;; ============================================================================
;; bytearray_dunder_delitem(rdi = args, rsi = nargs) -> rax = Value
;; Fails: 0
;; bytearray.__delitem__, reached by name rather than through the slot.
;; ============================================================================
DEF_FUNC bytearray_dunder_delitem
    REQUIRE_SELF bytearray_type, "__delitem__"
    cmp rsi, 2
    jne .badd_bad
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    xor edx, edx                ; a NULL value Value means delete
    call bytearray_ass_subscript
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
.badd_bad:
    SET_EXC exc_TypeError_type, "expected exactly one argument"
    xor eax, eax
    leave
    ret
END_FUNC bytearray_dunder_delitem

;; ============================================================================
;; bytearray_dunder_contains(rdi = args, rsi = nargs) -> rax = Value
;; Fails: 0
;; bytearray.__contains__, reached by name rather than through the slot.
;; ============================================================================
DEF_FUNC bytearray_dunder_contains
    REQUIRE_SELF bytearray_type, "__contains__"
    cmp rsi, 2
    jne .badc_bad
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call bytearray_contains
    test eax, eax
    jz .badc_false
    lea rax, [rel bool_true]
    jmp .badc_out
.badc_false:
    lea rax, [rel bool_false]
.badc_out:
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
.badc_bad:
    SET_EXC exc_TypeError_type, "expected exactly one argument"
    xor eax, eax
    leave
    ret
END_FUNC bytearray_dunder_contains

;; ============================================================================
;; bytearray's share of the string-shaped methods in methods/bytes_str.asm.
;;
;; Same shape as the trampolines above: the bytes body runs on a temporary
;; bytes and the wrap mode says what the answer has to become -- a bytearray
;; for the ones that build a new buffer, a list of bytearrays for splitlines,
;; and nothing at all for the predicates, which answer with a bool.
;;
;; ba_shared_upper(rdi = args, rsi = nargs) -> rax = Value, and so does every
;; one of its siblings below.
;; ============================================================================

BA_SHARED upper, bytes_method_upper, 1

;; ============================================================================
;; ba_shared_lower(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.lower, run as bytes_method_lower over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED lower, bytes_method_lower, 1

;; ============================================================================
;; ba_shared_swapcase(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.swapcase, run as bytes_method_swapcase over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED swapcase, bytes_method_swapcase, 1

;; ============================================================================
;; ba_shared_capitalize(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.capitalize, run as bytes_method_capitalize over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED capitalize, bytes_method_capitalize, 1

;; ============================================================================
;; ba_shared_title(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.title, run as bytes_method_title over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED title, bytes_method_title, 1

;; ============================================================================
;; ba_shared_isalpha(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.isalpha, run as bytes_method_isalpha over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED isalpha, bytes_method_isalpha, 0

;; ============================================================================
;; ba_shared_isdigit(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.isdigit, run as bytes_method_isdigit over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED isdigit, bytes_method_isdigit, 0

;; ============================================================================
;; ba_shared_isspace(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.isspace, run as bytes_method_isspace over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED isspace, bytes_method_isspace, 0

;; ============================================================================
;; ba_shared_isalnum(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.isalnum, run as bytes_method_isalnum over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED isalnum, bytes_method_isalnum, 0

;; ============================================================================
;; ba_shared_isascii(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.isascii, run as bytes_method_isascii over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED isascii, bytes_method_isascii, 0

;; ============================================================================
;; ba_shared_isupper(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.isupper, run as bytes_method_isupper over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED isupper, bytes_method_isupper, 0

;; ============================================================================
;; ba_shared_islower(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.islower, run as bytes_method_islower over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED islower, bytes_method_islower, 0

;; ============================================================================
;; ba_shared_istitle(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.istitle, run as bytes_method_istitle over a temporary bytes;
;; the body answers, unchanged.
;; ============================================================================
BA_SHARED istitle, bytes_method_istitle, 0

;; ============================================================================
;; ba_shared_ljust(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.ljust, run as bytes_method_ljust over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED ljust, bytes_method_ljust, 1

;; ============================================================================
;; ba_shared_rjust(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.rjust, run as bytes_method_rjust over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED rjust, bytes_method_rjust, 1

;; ============================================================================
;; ba_shared_center(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.center, run as bytes_method_center over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED center, bytes_method_center, 1

;; ============================================================================
;; ba_shared_zfill(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.zfill, run as bytes_method_zfill over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED zfill, bytes_method_zfill, 1

;; ============================================================================
;; ba_shared_expandtabs(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.expandtabs, run as bytes_method_expandtabs over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED expandtabs, bytes_method_expandtabs, 1

;; ============================================================================
;; ba_shared_translate(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.translate, run as bytes_method_translate over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED translate, bytes_method_translate, 1

;; ============================================================================
;; ba_shared_splitlines(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.splitlines, run as bytes_method_splitlines over a temporary bytes;
;; the result becomes a list of bytearrays.
;; ============================================================================
BA_SHARED splitlines, bytes_method_splitlines, 2

;; ============================================================================
;; ba_shared_removeprefix(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.removeprefix, run as bytes_method_removeprefix over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED removeprefix, bytes_method_removeprefix, 1

;; ============================================================================
;; ba_shared_removesuffix(rdi = args, rsi = nargs) -> rax = Value
;; bytearray.removesuffix, run as bytes_method_removesuffix over a temporary bytes;
;; the result becomes a bytearray.
;; ============================================================================
BA_SHARED removesuffix, bytes_method_removesuffix, 1

;; ============================================================================
;; bytearray.__reduce__(self) -> (type(self), (str, 'latin-1'), None)
;;
;; CPython's shape exactly, including that an EMPTY bytearray answers with no
;; constructor arguments at all rather than with ('', 'latin-1').  The data is
;; carried as a str decoded latin-1 -- one code point per byte, so the round
;; trip is exact -- because that is what bytearray(str, encoding) takes back.
;;
;; type(self), so a subclass rebuilds as itself.
;; ============================================================================
global bytearray_method_reduce
BRD_SELF  equ 8
BRD_STR   equ 16
BRD_ARGS  equ 24
BRD_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC bytearray_method_reduce, BRD_FRAME
    push rbx
    mov rbx, [rdi]                      ; args[0] = self, always a pointer
    mov [rbp - BRD_SELF], rbx

    mov rdi, [rbx + PyByteArrayObject.ob_size]
    test rdi, rdi
    jz .brd_empty

    mov rdi, [rbx + PyByteArrayObject.ob_bytes]
    mov rsi, [rbx + PyByteArrayObject.ob_size]
    extern bytes_latin1_to_str
    call bytes_latin1_to_str
    test rax, rax
    jz .brd_failed
    mov [rbp - BRD_STR], rax

    mov edi, 2
    extern tuple_new
    call tuple_new
    test rax, rax
    jz .brd_drop_str
    mov [rbp - BRD_ARGS], rax
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbp - BRD_STR]
    mov [rcx], rdx                      ; the tuple takes the str's reference
    CSTRING rdi, "latin-1"
    extern str_from_cstr_heap
    call str_from_cstr_heap
    test rax, rax
    jz .brd_drop_args
    mov rcx, [rbp - BRD_ARGS]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + 8], rax
    jmp .brd_wrap

.brd_empty:
    xor edi, edi
    call tuple_new
    test rax, rax
    jz .brd_failed
    mov [rbp - BRD_ARGS], rax

.brd_wrap:
    mov rsi, [rbp - BRD_ARGS]           ; its reference is taken
    mov rdi, [rbp - BRD_SELF]
    mov rdi, [rdi + PyObject.ob_type]
    extern none_singleton
    lea rdx, [rel none_singleton]
    mov ecx, 1
    extern ir_reduce_tuple
    call ir_reduce_tuple
    test rax, rax
    jz .brd_failed
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.brd_drop_args:
    mov rdi, [rbp - BRD_ARGS]
    call obj_decref                     ; releases the str it already holds
    jmp .brd_failed
.brd_drop_str:
    mov rdi, [rbp - BRD_STR]
    call obj_decref
.brd_failed:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
END_FUNC bytearray_method_reduce
