; buildclass_stmt.asm - the `class` statement: __build_class__ and its helpers
;
; Split off from buildclass.asm, which reached the 100k cap that
; src/compiler/lint.py enforces.  The seam is the one the file already had:
; everything here serves the CLASS STATEMENT -- resolving the bases through
; __mro_entries__, picking the metaclass, running __prepare__, executing the
; body in the namespace it returns -- and then hands three finished arguments
; to type_from_parts, which stayed behind with the rest of the type
; constructor.  Nothing above the seam calls anything below it.
;
; bc_call_kw stayed in buildclass.asm: type_from_parts calls it too, for
; __init_subclass__.

%include "macros.inc"
%include "object.inc"

; --- what buildclass.asm keeps ---
extern type_from_parts
extern bc_call_kw
extern bc_prepare_name
extern class_kwnames_pending
extern class_kwvalues_pending

; --- the rest of the tree ---
extern ap_strcmp
extern builtins_dict_global
extern current_exception
extern dict_new
extern eval_exception_unwind
extern eval_frame
extern exc_TypeError_type
extern exc_metatype
extern frame_free
extern frame_new
extern func_type
extern kw_names_pending
extern obj_dealloc
extern obj_decref
extern obj_getattr_opt
extern obj_incref
extern raise_exception
extern str_from_cstr_heap
extern dict_type
extern dict_set
extern str_type
extern tuple_new
extern tuple_type
extern type_check_is_class
extern type_is_subtype
extern type_type
extern user_type_metatype

section .text

;; ============================================================================
;; bc_split_kwargs(names, Value *kwvals, PyObject **out) -> rax = 1 ok, 0 error
;;
;; Split a class statement's keywords into the metaclass and the rest:
;;   out[0] = the metaclass= value, borrowed, or 0
;;   out[1] = a tuple of the other names, owned
;;   out[2] = a tuple of their values, owned
;;
;; The two tuples are sized by a first pass, because they must be exactly as
;; long as what goes into them: one sized for the keywords INCLUDING metaclass
;; would end with a NULL slot, and whoever read it next would walk into the
;; hole.  Doing this as a function rather than inline keeps it away from the
;; four callee-saved registers __build_class__ has already spoken for.
;; ============================================================================
BSK_NAMES equ 8
BSK_VALS  equ 16
BSK_OUT   equ 24
BSK_N     equ 32
BSK_KEPT  equ 40
BSK_I     equ 48
BSK_FRAME equ 56          ; + 3 pushes = 80
DEF_FUNC_LOCAL bc_split_kwargs, BSK_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - BSK_NAMES], rdi
    mov [rbp - BSK_VALS], rsi
    mov [rbp - BSK_OUT], rdx
    mov qword [rdx], 0
    mov qword [rdx + 8], 0
    mov qword [rdx + 16], 0
    mov rax, [rdi + PyTupleObject.ob_size]
    mov [rbp - BSK_N], rax

    ; --- pass one: how many are not metaclass= ---
    mov qword [rbp - BSK_KEPT], 0
    mov qword [rbp - BSK_I], 0
.count:
    mov rax, [rbp - BSK_I]
    cmp rax, [rbp - BSK_N]
    jae .counted
    mov rdi, [rbp - BSK_NAMES]
    mov rdi, [rdi + PyTupleObject.ob_item]
    mov rdi, [rdi + rax*8]
    add rdi, PyStrObject.data
    CSTRING rsi, "metaclass"
    call ap_strcmp
    test eax, eax
    je .count_next
    inc qword [rbp - BSK_KEPT]
.count_next:
    inc qword [rbp - BSK_I]
    jmp .count
.counted:

    mov rdi, [rbp - BSK_KEPT]
    call tuple_new
    test rax, rax
    jz .fail
    mov r12, rax
    mov rdi, [rbp - BSK_KEPT]
    call tuple_new
    test rax, rax
    jz .fail_names
    mov r13, rax

    ; --- pass two: fill them, and pick out the metaclass ---
    xor ebx, ebx                        ; the write index
    mov qword [rbp - BSK_I], 0
.fill:
    mov rax, [rbp - BSK_I]
    cmp rax, [rbp - BSK_N]
    jae .filled
    mov rdi, [rbp - BSK_NAMES]
    mov rdi, [rdi + PyTupleObject.ob_item]
    mov rdi, [rdi + rax*8]
    add rdi, PyStrObject.data
    CSTRING rsi, "metaclass"
    call ap_strcmp
    mov rcx, [rbp - BSK_I]
    mov rdx, [rbp - BSK_VALS]
    mov rdx, [rdx + rcx*8]              ; the value Value
    test eax, eax
    jne .keep
    mov rcx, [rbp - BSK_OUT]
    mov [rcx], rdx                      ; the metaclass, borrowed
    jmp .fill_next
.keep:
    mov rcx, [rbp - BSK_I]
    mov rax, [rbp - BSK_NAMES]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rax, [rax + rcx*8]              ; the name
    INCREF rax
    mov rcx, [r12 + PyTupleObject.ob_item]
    mov [rcx + rbx*8], rax
    INCREF_V rdx, rax
    mov rcx, [r13 + PyTupleObject.ob_item]
    mov [rcx + rbx*8], rdx
    inc rbx
.fill_next:
    inc qword [rbp - BSK_I]
    jmp .fill
.filled:
    mov rcx, [rbp - BSK_OUT]
    mov [rcx + 8], r12
    mov [rcx + 16], r13
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    leave
    ret

.fail_names:
    mov rdi, r12
    call obj_decref
.fail:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC bc_split_kwargs

;; ============================================================================
;; bc_prepare_namespace(meta, name, bases, fallback) -> rax = mapping, or 0
;;
;; The namespace a class body executes in.  A metaclass that overrides
;; __prepare__ -- enum's EnumType, returning an _EnumDict that records every
;; member as it is stored -- gets that mapping used as the body's locals.
;; Returns 0 to mean "keep the fallback".
;; ============================================================================
BPN_META  equ 8
BPN_NAME  equ 16
BPN_BASES equ 24
BPN_FALL  equ 32
BPN_FN    equ 40
BPN_ARGS  equ 64
BPN_KWN   equ 80
BPN_KWV   equ 88
BPN_EXC   equ 96          ; current_exception before the call
BPN_FRAME equ 104         ; + 1 push = 112
DEF_FUNC_LOCAL bc_prepare_namespace, BPN_FRAME
    push rbx
    mov [rbp - BPN_META], rdi
    mov [rbp - BPN_NAME], rsi
    mov [rbp - BPN_BASES], rdx
    mov [rbp - BPN_FALL], rcx
    mov [rbp - BPN_KWN], r8
    mov [rbp - BPN_KWV], r9

    ; __prepare__ is looked up on the metaclass as an attribute, so a
    ; classmethod arrives already bound.
    lea rdi, [rel bc_prepare_name]
    call str_from_cstr_heap
    test rax, rax
    jz .none
    mov rbx, rax
    mov rdi, [rbp - BPN_META]
    mov rsi, rbx
    call obj_getattr_opt
    mov [rbp - BPN_FN], rax
    mov rdi, rbx
    call obj_decref
    cmp qword [rbp - BPN_FN], 0
    je .none

    mov rax, [rbp - BPN_NAME]
    mov [rbp - BPN_ARGS], rax
    mov rax, [rbp - BPN_BASES]
    test rax, rax
    jnz .have_bases
    xor edi, edi
    call tuple_new
.have_bases:
    mov [rbp - BPN_ARGS + 8], rax
    DUNDER_EXC_SAVE [rbp - BPN_EXC]
    mov rdi, [rbp - BPN_FN]
    lea rsi, [rbp - BPN_ARGS]
    mov edx, 2
    mov rcx, [rbp - BPN_KWN]
    mov r8, [rbp - BPN_KWV]
    call bc_call_kw
    mov rbx, rax
    mov rdi, [rbp - BPN_FN]
    call obj_decref
    test rbx, rbx
    jnz .have_ns
    ; A NULL means either "there is no usable __prepare__" or "it ran and
    ; raised", and they are not the same: treating the second as the first
    ; built the class anyway and left the exception to surface somewhere
    ; unrelated.  -1 says the caller must propagate.
    DUNDER_RAISED [rbp - BPN_EXC], .failed
    jmp .none
.have_ns:

    ; It has to be a MAPPING.  Anything else was treated as "keep the
    ; fallback", and None is a pointer -- so a __prepare__ returning None
    ; passed the test below, the real dict was released, and the class body
    ; executed with None as its locals.  The first STORE_NAME then handed None
    ; to dict_set, which read its header as a dict: a SIGSEGV inside
    ; dict_lookup, from seven lines of ordinary Python.  CPython refuses with
    ; "BadMeta.__prepare__() must return a mapping, not NoneType", and
    ; test_types.test_bad___prepare__ is exactly this.
    V_TEST_PTR rbx, rcx
    ja .bad_prepare
    test rbx, rbx
    jz .bad_prepare
    mov rcx, [rbx + PyObject.ob_type]
    cmp qword [rcx + PyTypeObject.tp_as_mapping], 0
    je .bad_prepare
    mov rdi, [rbp - BPN_FALL]
    call obj_decref
    mov rax, rbx
    pop rbx
    leave
    ret

.bad_prepare:
    ; The metaclass names itself when it is a type; CPython writes
    ; "<metaclass>" for anything else, which is what `metaclass=BadMeta()`
    ; for a plain class gives.
    mov rdi, [rbp - BPN_META]
    mov rsi, rbx
    call bc_raise_bad_prepare   ; does not return
.none:
    xor eax, eax
    pop rbx
    leave
    ret
.failed:
    mov rax, -1
    pop rbx
    leave
    ret
END_FUNC bc_prepare_namespace

;; ============================================================================
;; bc_raise_bad_prepare(rdi = the metaclass, rsi = what __prepare__ returned)
;;   -> does not return: raises CPython's TypeError
;;
;;   BadMeta.__prepare__() must return a mapping, not NoneType
;;   <metaclass>.__prepare__() must return a mapping, not NoneType
;;
;; The second form is CPython's when the metaclass is not a type -- there is
;; no tp_name to quote.
;; ============================================================================
BRP_META  equ 8
BRP_GOT   equ 16
BRP_BUF   equ 288
BRP_FRAME equ 288           ; + 0 pushes = 288, 16-aligned
DEF_FUNC_LOCAL bc_raise_bad_prepare, BRP_FRAME
    mov [rbp - BRP_META], rdi
    mov [rbp - BRP_GOT], rsi

    ; Is the metaclass a type?  Asked FIRST, because type_check_is_class takes
    ; the object in rdi and the buffer wants rdi too.
    mov rdi, [rbp - BRP_META]
    call type_check_is_class
    lea rdi, [rbp - BRP_BUF]
    test eax, eax
    jz .brp_anon
    mov rcx, [rbp - BRP_META]
    mov rsi, [rcx + PyTypeObject.tp_name]
    jmp .brp_have_name
.brp_anon:
    CSTRING rsi, "<metaclass>"
.brp_have_name:
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, ".__prepare__() must return a mapping, not "
    call rbt_append_cstr
    mov rdi, rax
    ; value_type, not ob_type: an int or a float may be the Value itself, and
    ; reading a header off one gave "object" where CPython names the type.
    push rdi
    mov rdi, [rbp - BRP_GOT]
    extern value_type
    call value_type
    pop rdi
    test rax, rax
    jz .brp_unknown
    mov rsi, [rax + PyTypeObject.tp_name]
    jmp .brp_join
.brp_unknown:
    CSTRING rsi, "object"
.brp_join:
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - BRP_BUF]
    call raise_exception
    ud2
END_FUNC bc_raise_bad_prepare

;; ============================================================================
;; builtin___build_class__(PyObject **args, int64_t nargs) -> rax = Value
;; __build_class__(body_func, class_name, *bases)
;;
;; 1. body_func = args[0], class_name = args[1]
;; 2. Create a class dict
;; 3. Execute body_func with class_dict as locals
;; 4. Create a new type object with class_dict as tp_dict
;; 5. Return the new type
;; ============================================================================
;; ============================================================================
;; bc_normalize_metatype(rdi = a metatype) -> rdi, with the interpreter's own
;; metatypes mapped to type_type
;;
;; user_type_metatype and exc_metatype are implementation detail: they exist
;; so an ordinary class and an exception class can carry different tp_call,
;; and no metaclass a program writes derives from either.  For the purpose of
;; "which metaclass is most derived" they are `type`.
;; ============================================================================
DEF_FUNC_BARE bc_normalize_metatype
    lea rax, [rel user_type_metatype]
    cmp rdi, rax
    je .bnm_type
    lea rax, [rel exc_metatype]
    cmp rdi, rax
    je .bnm_type
    ret
.bnm_type:
    lea rdi, [rel type_type]
    ret
END_FUNC bc_normalize_metatype

;; ============================================================================
;; builtin___build_class__(rdi = args, rsi = nargs) -> Value: the new class
;;
;; What every `class` statement compiles to a call of.  args[0] is the body's
;; code object wrapped in a function, args[1] its name, args[2:] the bases,
;; and the keywords arrive through kw_names_pending as they do for any
;; builtin.  In order: resolve the bases through __mro_entries__, split
;; `metaclass=` out of the keywords, pick the winning metatype, run its
;; __prepare__ for the namespace, execute the body in it, and hand name,
;; bases and namespace to type_from_parts -- or to the metaclass, when one
;; was given that is not a metatype we can build directly.
;; ============================================================================
DEF_FUNC builtin___build_class__, 8            ; 5 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    push r14
    push r15
BCL_BASES equ 48        ; the bases tuple built from args[2:]
BCL_META  equ 56        ; the metaclass= keyword, or 0
BCL_NPOS  equ 64        ; positional arg count (nargs minus the keywords)
; bc_split_kwargs fills a three-slot scratch: the metaclass, then the class's
; own keyword names and values as two tuples.  Frame offsets count DOWN from
; rbp while the slots count up in address, so the lowest offset is out[2].
BCL_OMETA equ 88
BCL_OKWN  equ 80
BCL_OKWV  equ 72
; The bases AS WRITTEN, kept only when __mro_entries__ changed them, so they
; can be recorded as __orig_bases__ once the namespace exists.  96 rather than
; a lower number because the five pushes above occupy [rbp-16, rbp-48]: the
; carved space starts below them.
BCL_ORIG  equ 96
    sub rsp, 64

    ; Check nargs >= 2
    cmp rsi, 2
    jl .build_class_error

    mov rbx, rdi            ; rbx = args
    mov qword [rbp - BCL_META], 0
    mov qword [rbp - BCL_ORIG], 0
    mov [rbp - BCL_NPOS], rsi

    ; `class C(metaclass=M)` passes M as a keyword, and it arrives in the
    ; positional array with its name in kw_names_pending.  Without splitting
    ; them off, M was treated as a *base* -- which is why metaclass= appeared
    ; to be ignored: the metatype never got a chance to run.
    mov qword [rbp - BCL_OKWN], 0
    mov qword [rbp - BCL_OKWV], 0
    mov rax, [rel kw_names_pending]
    test rax, rax
    jz .bc_no_kwargs
    mov rcx, [rax + PyTupleObject.ob_size]
    sub [rbp - BCL_NPOS], rcx

    ; Every keyword but metaclass= belongs to the class, and is handed on to
    ; __prepare__, to the metaclass, and through it to __init_subclass__.
    mov rdi, rax
    mov rsi, [rbp - BCL_NPOS]
    lea rsi, [rbx + rsi*8]              ; where the keyword values start
    lea rdx, [rbp - BCL_OMETA]
    call bc_split_kwargs
    test eax, eax
    jz .build_class_error
    mov rax, [rbp - BCL_OMETA]
    mov [rbp - BCL_META], rax
.bc_no_kwargs:
    ; Consumed: anything we call from here on must not see them again.
    mov qword [rel kw_names_pending], 0
    mov rsi, [rbp - BCL_NPOS]
    ; r12 will be used later for the type object

    ; Collect every base into a tuple.  Only args[2] used to be read, so
    ; `class C(A, B)` silently produced a class that had never heard of B.
    xor eax, eax
    mov [rbp - BCL_BASES], rax
    cmp rsi, 3
    jl .bc_no_base
    push rsi
    lea rdi, [rsi - 2]      ; nbases
    extern tuple_new
    call tuple_new
    pop rsi
    mov [rbp - BCL_BASES], rax
    mov r8, [rax + PyTupleObject.ob_item]
    xor r9, r9
.bc_base_copy:
    lea rcx, [r9 + 2]
    cmp rcx, rsi
    jge .bc_bases_written
    mov rdx, [rbx + rcx*8]
    mov [r8 + r9*8], rdx
    push rsi
    push r8
    push r9
    INCREF_V rdx, rcx
    pop r9
    pop r8
    pop rsi
    inc r9
    jmp .bc_base_copy

.bc_bases_written:
    ; PEP 560 runs over the bases AS WRITTEN.  `__mro_entries__` is handed the
    ; whole original tuple -- typing's NamedTuple asserts it can find itself
    ; in there -- so the tuple has to be complete before any of them is
    ; replaced, which is why this is a second pass and not part of the copy.
    mov rdi, [rbp - BCL_BASES]
    call bc_resolve_bases
    test rax, rax
    jz .bc_bases_failed
    mov rcx, [rbp - BCL_BASES]
    mov [rbp - BCL_BASES], rax
    cmp rax, rcx
    jne .bc_bases_substituted
    ; Nothing was replaced, and bc_resolve_bases answered the original
    ; increfed -- so there are two references and one of them is ours.
    mov rdi, rcx
    call obj_decref
    jmp .bc_no_base
.bc_bases_substituted:
    ; The written tuple survives as __orig_bases__; this reference becomes
    ; that one.  It is released once the namespace has taken a copy.
    mov [rbp - BCL_ORIG], rcx
    jmp .bc_no_base

.bc_bases_failed:
    mov rdi, [rbp - BCL_BASES]
    mov qword [rbp - BCL_BASES], 0
    call obj_decref
    jmp .build_class_base_error

.bc_no_base:

    mov r13, [rbx]          ; r13 = body_func (args[0])
    mov r14, [rbx + 8]     ; r14 = class_name (args[1])

    ; Neither was checked, and both are dereferenced below: a function's code
    ; object off args[0], a str's characters off args[1].  `__build_class__
    ; (None, None)` read the None singleton's header as a code pointer.
    ; CPython names each refusal separately, and `class` statements never
    ; reach either -- this is the builtin called by hand.
    V_TEST_PTR r13, rax
    ja .bc_func_error
    test r13, r13
    jz .bc_func_error
    mov rax, [r13 + PyObject.ob_type]
    lea rcx, [rel func_type]
    cmp rax, rcx
    jne .bc_func_error
    V_TEST_PTR r14, rax
    ja .bc_name_error
    test r14, r14
    jz .bc_name_error
    mov rax, [r14 + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .bc_name_ok
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .bc_name_error
.bc_name_ok:

    ; A metaclass is inherited: `class D(C)` where type(C) is M gives D the
    ; metatype M as well.  CPython's rule is a winner among the explicit
    ; metaclass and every base's type -- the one that is a subclass of all the
    ; others, and a TypeError when no such one exists.
    ;
    ; The three metatypes this interpreter ships stand in for `type` and are
    ; not in any user metaclass's MRO, so each is normalised to type_type
    ; before the comparison.  Without that, an ordinary Python base made the
    ; winner user_type_metatype, no real metaclass was a subclass of it, and
    ; `class RawIOBase(_io._RawIOBase, IOBase)` in Lib/io.py came out a plain
    ; type -- so RawIOBase.register(), which is how io tells isinstance() that
    ; FileIO is a raw stream, did not exist.
    mov r8, [rbp - BCL_META]                ; the winner so far
    test r8, r8
    jz .bc_meta_default
    ; An explicit metaclass= need not be a type at all: CPython accepts any
    ; callable, and `class D(object, metaclass=f)` for a plain function is
    ; legal.  Seeding the scan with one and handing it to type_is_subtype read
    ; tp_mro off the function.  Before this scan existed an explicit
    ; metaclass= short-circuited it, so leave a non-type alone the same way --
    ; it is called directly further down.
    push r8
    sub rsp, 8
    mov rdi, r8
    call type_check_is_class
    add rsp, 8
    pop r8
    test eax, eax
    jz .bc_meta_scan_done
    jmp .bc_meta_have_winner
.bc_meta_default:
    ; No metaclass= keyword: CPython starts from type(bases[0]), not from
    ; type, so a first base whose type is not a metatype at all -- an
    ; instance of some class -- makes that class the metaclass.
    lea r8, [rel type_type]
    mov rcx, [rbp - BCL_BASES]
    test rcx, rcx
    jz .bc_meta_have_winner
    cmp qword [rcx + PyTupleObject.ob_size], 0
    je .bc_meta_have_winner
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov rdi, [rcx]
    V_TEST_PTR rdi, rax
    ja .bc_meta_have_winner
    test rdi, rdi
    jz .bc_meta_have_winner
    mov rdi, [rdi + PyObject.ob_type]
    call bc_normalize_metatype
    mov r8, rdi
.bc_meta_have_winner:
    mov rcx, [rbp - BCL_BASES]
    test rcx, rcx
    jz .bc_meta_scan_done
    mov r9, [rcx + PyTupleObject.ob_size]
    mov r10, [rcx + PyTupleObject.ob_item]
    xor r11d, r11d
.bc_meta_scan:
    cmp r11, r9
    jge .bc_meta_scan_done
    mov rdi, [r10 + r11*8]
    V_TEST_PTR rdi, rax
    ja .bc_meta_scan_next
    test rdi, rdi
    jz .bc_meta_scan_next
    mov rdi, [rdi + PyObject.ob_type]       ; the base's metatype
    call bc_normalize_metatype
    cmp rdi, r8
    je .bc_meta_scan_next

    ; The winner already derives from this one: nothing to do.
    push r8
    push r9
    push r10
    push r11
    push rdi
    sub rsp, 8
    mov rsi, rdi
    mov rdi, r8
    call type_is_subtype
    add rsp, 8
    pop rdi
    pop r11
    pop r10
    pop r9
    pop r8
    test eax, eax
    jnz .bc_meta_scan_next

    ; This one derives from the winner: it becomes the winner.
    push r8
    push r9
    push r10
    push r11
    push rdi
    sub rsp, 8
    mov rsi, r8
    call type_is_subtype
    add rsp, 8
    pop rdi
    pop r11
    pop r10
    pop r9
    pop r8
    test eax, eax
    jz .bc_meta_conflict
    mov r8, rdi
.bc_meta_scan_next:
    inc r11
    jmp .bc_meta_scan

.bc_meta_conflict:
    RAISE exc_TypeError_type, "metaclass conflict: the metaclass of a derived class must be a (non-strict) subclass of the metaclasses of all its bases"

.bc_meta_scan_done:
    ; The three built-in metatypes go through type_from_parts as before --
    ; they have no __new__ of their own to run.
    lea rax, [rel type_type]
    cmp r8, rax
    je .bc_metaclass_settled
    extern user_type_metatype
    lea rax, [rel user_type_metatype]
    cmp r8, rax
    je .bc_metaclass_settled
    extern exc_metatype
    lea rax, [rel exc_metatype]
    cmp r8, rax
    je .bc_metaclass_settled
    mov [rbp - BCL_META], r8

.bc_metaclass_settled:

    ; The namespace the body executes in.  A metaclass may supply its own
    ; through __prepare__, and that has to happen BEFORE the body runs --
    ; enum's EnumType returns an _EnumDict whose __setitem__ records each
    ; member, so with a plain dict every enum class fails on _member_names.
    ; Which metaclass it is has to be settled first, which is why the scan
    ; above moved ahead of the body.
    call dict_new
    mov r15, rax            ; r15 = class_dict
    cmp qword [rbp - BCL_META], 0
    je .bc_ns_ready
    mov rdi, [rbp - BCL_META]
    mov rsi, r14            ; the class name
    mov rdx, [rbp - BCL_BASES]
    mov rcx, r15            ; the plain dict, freed if __prepare__ supplies one
    mov r8, [rbp - BCL_OKWN]
    mov r9, [rbp - BCL_OKWV]
    call bc_prepare_namespace
    cmp rax, -1
    je .bc_prepare_failed       ; __prepare__ raised; it is already pending
    test rax, rax
    jz .bc_ns_ready
    mov r15, rax
.bc_ns_ready:

    ; Execute body function with class_dict as locals
    ; frame_new(code, globals, builtins, locals)
    mov rdi, [r13 + PyFuncObject.func_code]     ; code from body func
    mov rsi, [r13 + PyFuncObject.func_globals]  ; globals from body func
    mov rdx, [rel builtins_dict_global]         ; builtins dict
    mov rcx, r15                                ; class_dict as locals
    call frame_new
    mov r12, rax            ; r12 = new frame

    ; Store body function in frame for COPY_FREE_VARS (closure support)
    mov [r12 + PyFrame.func_obj], r13

    ; eval_frame(frame)
    mov rdi, r12
    call eval_frame
    V_UNPACK rax, rdx           ; eval_frame returns a Value
    ; A class body that raised returns NULL with current_exception set.  The
    ; same omission the module-body path had: the exception was left pending
    ; and the class built anyway, so `class C: raise X` inside a try/except
    ; produced a class *and* an error reported somewhere else entirely.
    test edx, edx
    jnz .bc_body_ok
    extern current_exception
    cmp qword [rel current_exception], 0
    jne .bc_body_raised
.bc_body_ok:
    ; DECREF return value (should be None — TAG_NONE, not a pointer)
    mov rsi, rdx
    DECREF_VAL rax, rsi

    ; Free the frame
    mov rdi, r12
    call frame_free

    ; PEP 560's other half: when the bases were substituted, the ones AS
    ; WRITTEN are recorded in the namespace.  `typing` reads __orig_bases__
    ; throughout -- NamedTuple, TypedDict and every generic alias base -- and
    ; nothing here set it; only types.new_class did.  It goes in after the
    ; body has run and before the metaclass sees the namespace, which is
    ; where CPython puts it.
    cmp qword [rbp - BCL_ORIG], 0
    je .bc_orig_done
    test r15, r15
    jz .bc_orig_release
    ; Only a real dict is written into.  A metaclass __prepare__ may answer
    ; any mapping, and going through the generic protocol here would run user
    ; code between the body and the metaclass call; type.__prepare__ answers
    ; a dict, which is every class the substitution can apply to.
    lea rax, [rel dict_type]
    cmp [r15 + PyObject.ob_type], rax
    jne .bc_orig_release
    CSTRING rdi, "__orig_bases__"
    call str_from_cstr_heap
    test rax, rax
    jz .bc_orig_release
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rbp - BCL_ORIG]
    call dict_set               ; takes its own reference
    pop rdi
    call obj_decref
.bc_orig_release:
    mov rdi, [rbp - BCL_ORIG]
    mov qword [rbp - BCL_ORIG], 0
    call obj_decref
.bc_orig_done:

    ; With a metaclass, CPython calls meta(name, bases, ns) rather than
    ; building the type itself -- that is what runs M.__new__ and
    ; M.__init__, and what makes type(C) be M.
    cmp qword [rbp - BCL_META], 0
    je .bc_no_metaclass
    mov rdi, [rbp - BCL_META]
    ; Whatever it is, it gets called.  CPython requires a callable here, not a
    ; type: `class D(metaclass=f)` for a plain function binds D to f's return
    ; value.  This used to ask type_check_is_class first and quietly build an
    ; ordinary class when the answer was no, so metaclass=f was ignored.
    extern type_check_is_class

    ; meta(name, bases, ns, **kwds)
    mov rcx, [rbp - BCL_BASES]
    test rcx, rcx
    jnz .bc_meta_have_bases
    push rdi
    xor edi, edi
    call tuple_new
    mov [rbp - BCL_BASES], rax
    pop rdi
.bc_meta_have_bases:
    sub rsp, 32
    mov [rsp], r14                      ; name
    mov rcx, [rbp - BCL_BASES]
    mov [rsp + 8], rcx                  ; bases
    mov [rsp + 16], r15                 ; namespace
    mov rsi, rsp
    mov edx, 3
    mov rcx, [rbp - BCL_OKWN]
    mov r8, [rbp - BCL_OKWV]
    call bc_call_kw
    ; Kept as a Value, not unpacked: a metaclass that is not a type may answer
    ; anything, including an immediate.  Unpacking here and re-packing in the
    ; epilogue with a hardcoded TAG_PTR turned a returned 42 into a pointer to
    ; address 42.  A class is a pointer, and a pointer is its own Value, so
    ; the ordinary case is unchanged.
    add rsp, 32
    push rax
    mov rdi, [rbp - BCL_BASES]
    test rdi, rdi
    jz .bc_meta_bases_done
    call obj_decref
.bc_meta_bases_done:
    ; The metaclass took its own reference to the namespace -- type.__new__
    ; increfs before type_from_parts adopts it -- so ours is not the class's.
    ; Only the no-metaclass path below transfers it; here it was dropped on
    ; the floor, one dict per class built through a metaclass, which is every
    ; enum and every ABC.
    mov rdi, r15
    test rdi, rdi
    jz .bc_meta_done
    xor r15d, r15d
    call obj_decref
.bc_meta_done:
    pop rax
    jmp .bc_have_value

.bc_no_metaclass:
    ; Build the heaptype from (name, bases, namespace); the three-argument
    ; type() reaches the same code.  The class keywords go through the pending
    ; pair: type_from_parts calls __init_subclass__ and has no other way to
    ; know them.
    mov rax, [rbp - BCL_OKWN]
    mov [rel class_kwnames_pending], rax
    mov rax, [rbp - BCL_OKWV]
    mov [rel class_kwvalues_pending], rax
    mov rdi, r14
    mov rsi, [rbp - BCL_BASES]
    mov rdx, r15
    call type_from_parts
    mov qword [rel class_kwnames_pending], 0
    mov qword [rel class_kwvalues_pending], 0
    push rax
    mov rdi, [rbp - BCL_BASES]
    test rdi, rdi
    jz .bc_bases_released
    call obj_decref         ; type_from_parts took its own reference
.bc_bases_released:
    pop rax
    test rax, rax
    jz .bc_have_class       ; NULL, with the exception already pending

.bc_have_value:
    ; The metaclass path arrives here with a finished Value in rax.  Same
    ; unwind as below, minus the re-pack: there is nothing to tag.
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.bc_have_class:
    add rsp, 64        ; must match the sub above: the epilogue unwinds
                       ; the locals by hand before popping the registers
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret


.build_class_error:
    RAISE exc_TypeError_type, "__build_class__: not enough arguments"

.bc_func_error:
    RAISE exc_TypeError_type, "__build_class__: func must be a function"

.bc_name_error:
    RAISE exc_TypeError_type, "__build_class__: name is not a string"

.bc_prepare_failed:
    ; __prepare__ raised.  Release the fallback namespace and the bases and
    ; let its exception keep unwinding, rather than building the class with
    ; an exception already pending.
    mov rdi, r15
    call obj_decref
    mov rdi, [rbp - BCL_BASES]
    test rdi, rdi
    jz .bc_body_raised_go
    call obj_decref
    jmp .bc_body_raised_go

.bc_body_raised:
    ; Release the frame and the namespace, then let the body's exception
    ; keep unwinding in the caller's frame.
    mov rdi, r12
    call frame_free
    mov rdi, r15
    call obj_decref
    mov rdi, [rbp - BCL_BASES]
    test rdi, rdi
    jz .bc_body_raised_go
    call obj_decref
.bc_body_raised_go:
    extern eval_exception_unwind
    jmp eval_exception_unwind

.build_class_base_error:
    RAISE exc_TypeError_type, "bases must be types"
END_FUNC builtin___build_class__

;; ============================================================================
;; bc_resolve_bases(rdi = the bases as written) -> rax = the bases to use
;;
;; CPython's update_bases.  Every base that is already a class stands for
;; itself; anything else is asked what it stands for, and is handed the
;; ORIGINAL tuple -- unchanged, however many replacements have happened
;; already -- because that is what the answer may be computed from.
;;
;; Returns an owned reference: the original tuple, increfed, when nothing
;; needed replacing, or a fresh one.  0 with no exception means some base is
;; neither a class nor able to name one, which the caller reports.
;; ============================================================================
BRB_ORIG  equ 8
BRB_OUT   equ 16
BRB_N     equ 24
BRB_SCRAT equ 32            ; per-base: the class itself, or its entries tuple
BRB_TOTAL equ 40            ; how many real bases those add up to
BRB_ASKED equ 48            ; 1 once any base's __mro_entries__ has run
BRB_FRAME equ 64            ; + 2 pushes = 80, 16-aligned
DEF_FUNC_LOCAL bc_resolve_bases, BRB_FRAME
    push rbx
    push r12
    mov [rbp - BRB_ORIG], rdi
    mov rax, [rdi + PyTupleObject.ob_size]
    mov [rbp - BRB_N], rax
    mov qword [rbp - BRB_OUT], 0
    mov qword [rbp - BRB_SCRAT], 0
    mov qword [rbp - BRB_TOTAL], 0
    mov qword [rbp - BRB_ASKED], 0

    ; A first pass that only asks: is any of them not a class?  The common
    ; case allocates nothing.
    xor ebx, ebx
.brb_scan:
    cmp rbx, [rbp - BRB_N]
    jge .brb_all_classes
    mov rax, [rbp - BRB_ORIG]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdi, [rax + rbx*8]
    call type_check_is_class
    test eax, eax
    jz .brb_needs_work
    inc rbx
    jmp .brb_scan

.brb_all_classes:
    mov rax, [rbp - BRB_ORIG]
    mov rdi, rax
    push rax
    call obj_incref
    pop rax
    pop r12
    pop rbx
    leave
    ret

.brb_needs_work:
    ; Something has to be asked, and an answer may be any length -- so the
    ; result cannot be written in place over a tuple sized like the input.
    ; That was the old shape, and it is why every __mro_entries__ returning
    ; anything but exactly one class came back as "bases must be types":
    ; typing.List[T] answers two, the origin and Generic, so `class
    ; C(typing.List[T])` could not be written at all.
    ;
    ; Two passes, over a SCRATCH tuple, because __mro_entries__ is user code
    ; and must run exactly once per base.  Each scratch slot holds either the
    ; class itself or the entries tuple that base stood for -- the two are
    ; told apart by ob_type, and a class is never a tuple -- and the second
    ; pass splices them into a tuple of the size they add up to.
    mov rdi, [rbp - BRB_N]
    call tuple_new
    test rax, rax
    jz .brb_fail
    mov [rbp - BRB_SCRAT], rax
    xor rbx, rbx
.brb_fill:
    cmp rbx, [rbp - BRB_N]
    jge .brb_splice
    mov rax, [rbp - BRB_ORIG]
    mov rax, [rax + PyTupleObject.ob_item]
    mov r12, [rax + rbx*8]
    mov rdi, r12
    call type_check_is_class
    test eax, eax
    jz .brb_ask
    mov rdi, r12
    call obj_incref
    mov rax, [rbp - BRB_SCRAT]
    mov rax, [rax + PyTupleObject.ob_item]
    mov [rax + rbx*8], r12
    inc qword [rbp - BRB_TOTAL]
    inc rbx
    jmp .brb_fill
.brb_ask:
    mov rdi, r12
    mov rsi, [rbp - BRB_ORIG]
    call bc_mro_entries
    test rax, rax
    jz .brb_fail_out
    or [rbp - BRB_ASKED], rdx
    mov rcx, [rbp - BRB_SCRAT]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + rbx*8], rax      ; bc_mro_entries hands over its reference
    mov rcx, [rax + PyTupleObject.ob_size]
    add [rbp - BRB_TOTAL], rcx
    inc rbx
    jmp .brb_fill

.brb_splice:
    mov rdi, [rbp - BRB_TOTAL]
    call tuple_new
    test rax, rax
    jz .brb_fail_out
    mov [rbp - BRB_OUT], rax
    xor rbx, rbx                ; index into the scratch
    xor r12, r12                ; index into the output
.brb_splice_loop:
    cmp rbx, [rbp - BRB_N]
    jge .brb_done
    mov rax, [rbp - BRB_SCRAT]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdi, [rax + rbx*8]
    lea rcx, [rel tuple_type]
    cmp [rdi + PyObject.ob_type], rcx
    je .brb_splice_entries
    ; a class: one base
    call obj_incref
    mov rax, [rbp - BRB_SCRAT]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdi, [rax + rbx*8]
    mov rax, [rbp - BRB_OUT]
    mov rax, [rax + PyTupleObject.ob_item]
    mov [rax + r12*8], rdi
    inc r12
    inc rbx
    jmp .brb_splice_loop
.brb_splice_entries:
    ; an entries tuple: as many bases as it holds, in order
    push rbx
    push r12
    xor ebx, ebx
.brb_entry_loop:
    mov rax, [rbp - BRB_SCRAT]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rcx, [rsp + 8]          ; the scratch index
    mov rdi, [rax + rcx*8]      ; the entries tuple
    cmp rbx, [rdi + PyTupleObject.ob_size]
    jge .brb_entry_done
    mov rax, [rdi + PyTupleObject.ob_item]
    mov rdi, [rax + rbx*8]
    push rdi
    call obj_incref
    pop rdi
    mov rax, [rbp - BRB_OUT]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rcx, [rsp]              ; the output index
    mov [rax + rcx*8], rdi
    inc qword [rsp]
    inc rbx
    jmp .brb_entry_loop
.brb_entry_done:
    pop r12
    pop rbx
    inc rbx
    jmp .brb_splice_loop

.brb_done:
    mov rdi, [rbp - BRB_SCRAT]
    call obj_decref             ; releases the classes and the entries tuples
    ; Nothing had an __mro_entries__ -- only bases kept as they are -- so the
    ; bases are the ones written, and the caller must see the same tuple:
    ; that is what tells it not to record __orig_bases__, which CPython sets
    ; only when update_bases changed something.
    cmp qword [rbp - BRB_ASKED], 0
    jne .brb_changed
    mov rdi, [rbp - BRB_OUT]
    call obj_decref
    mov rdi, [rbp - BRB_ORIG]
    call obj_incref
    mov rax, [rbp - BRB_ORIG]
    pop r12
    pop rbx
    leave
    ret
.brb_changed:
    mov rax, [rbp - BRB_OUT]
    pop r12
    pop rbx
    leave
    ret

.brb_fail_out:
    mov rdi, [rbp - BRB_SCRAT]
    test rdi, rdi
    jz .brb_fail
    call obj_decref
    mov rdi, [rbp - BRB_OUT]
    test rdi, rdi
    jz .brb_fail
    call obj_decref
.brb_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC bc_resolve_bases

;; ============================================================================
;; bc_mro_entries(rdi = a base that is not a class, rsi = the bases tuple)
;;   -> rax = its entries tuple, owned, or 0; edx = 1 when an __mro_entries__
;;      produced it, 0 when the base had none and is kept as written
;;
;; PEP 560's __mro_entries__.  A base that is not a type is asked what it
;; stands for, and answers a TUPLE -- of any length.  `class C[T]` compiles to
;; a base of Generic[T], which answers one; typing.List[T] answers two, the
;; origin and Generic; a proxy may legitimately answer none.
;;
;; The whole tuple is handed back rather than a single class, because it used
;; to insist on exactly one: the caller's output tuple was sized like its
;; input, so a longer answer had nowhere to go and was discarded.  Every shape
;; but one-class then reached the caller's "bases must be types", which is
;; why `class C(typing.List[T])` could not be written and test_typing aborted
;; at import.
;;
;; A non-tuple answer is CPython's own error, and is raised rather than
;; discarded -- it is a mistake in the object, not an object that declines.
;; ============================================================================
BME_BASES equ 8
BME_RES   equ 16
BME_ARG   equ 24
BME_FRAME equ 32            ; + 1 push = 40... one word more to land right
DEF_FUNC_LOCAL bc_mro_entries, 40           ; + 1 push = 48, 16-aligned
    push rbx
    mov rbx, rdi
    mov [rbp - BME_BASES], rsi

    V_TEST_PTR rbx, rax
    ja .bme_no
    test rbx, rbx
    jz .bme_no

    CSTRING rdi, "__mro_entries__"
    extern str_from_cstr_heap
    call str_from_cstr_heap
    test rax, rax
    jz .bme_no
    push rax
    mov rdi, rbx
    mov rsi, rax
    extern obj_getattr_opt
    call obj_getattr_opt
    pop rdi
    push rax
    call obj_decref
    pop rax
    test rax, rax
    jz .bme_clear_and_no
    mov [rbp - BME_RES], rax

    mov rax, [rbp - BME_BASES]
    mov [rbp - BME_ARG], rax
    mov rdi, [rbp - BME_RES]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .bme_release
    lea rsi, [rbp - BME_ARG]
    mov edx, 1
    call rax
    push rax
    mov rdi, [rbp - BME_RES]
    call obj_decref
    pop rax
    test rax, rax
    jz .bme_no

    ; It has to be a tuple; what is IN it is the caller's business, and
    ; type_from_parts words a non-class base the way CPython does.
    mov rbx, rax
    V_TEST_PTR rbx, rax
    ja .bme_not_tuple
    lea rcx, [rel tuple_type]
    cmp [rbx + PyObject.ob_type], rcx
    jne .bme_not_tuple
    mov rax, rbx
    mov edx, 1                  ; an __mro_entries__ answered
    pop rbx
    leave
    ret

.bme_not_tuple:
    mov rdi, rbx
    call obj_decref
    RAISE exc_TypeError_type, "__mro_entries__ must return a tuple"
.bme_release:
    mov rdi, [rbp - BME_RES]
    call obj_decref
    jmp .bme_no
.bme_clear_and_no:
    ; No __mro_entries__ is not an error: CPython's update_bases keeps such a
    ; base as it is, and the metaclass decides what to make of it.
    ; zope.interface's `class IElement(Interface)`, where Interface is an
    ; InterfaceClass INSTANCE, is the reason that matters: type(Interface)
    ; is the metaclass, and it builds another instance.  type.__new__ still
    ; refuses a non-class base, in type_from_parts, in CPython's words.
    extern current_exception
    mov rdi, [rel current_exception]
    test rdi, rdi
    jz .bme_keep
    mov qword [rel current_exception], 0
    call obj_decref
.bme_keep:
    mov edi, 1
    call tuple_new
    test rax, rax
    jz .bme_no
    INCREF rbx
    mov rcx, [rax + PyTupleObject.ob_item]
    mov [rcx], rbx
    xor edx, edx                ; kept as written
    pop rbx
    leave
    ret
.bme_no:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC bc_mro_entries
