; buildclass_ns.asm - what type_from_parts does to a new class's NAMESPACE
;
; Split off from buildclass.asm when it reached the 100k cap that
; src/compiler/lint.py enforces.  The seam is the one the file already had:
; each of these takes the class and its dict as arguments and works on the
; dict alone -- __set_name__ on every descriptor in it, the rule that an
; __eq__ without a __hash__ makes the class unhashable, the three hooks that
; are classmethods without saying so, and the private-name mangling a slot
; name gets -- where everything that stayed behind reads or writes
; type_from_parts's own frame and registers.  Nothing here calls back into
; buildclass.asm.

%include "macros.inc"
%include "object.inc"

extern ap_free
extern ap_malloc
extern ap_memcpy
extern ap_strcmp
extern dunder_call_3
extern obj_dealloc
extern obj_decref
extern str_new_heap
extern str_type
extern tuple_new

section .text

;; ============================================================================
;; type_apply_set_name(PyTypeObject *cls, PyDictObject *ns)
;;
;; Call __set_name__(owner, name) on every value in the class body that defines
;; one, once the class exists.  It is the hook a descriptor uses to learn what
;; it was assigned to, and enum is built on it: each member starts as a
;; _proto_member and __set_name__ is what replaces it with the real member.
;;
;; The names are snapshotted first, because a __set_name__ is entitled to
;; setattr on the owner -- which is this very dict, and rehashing it under the
;; walk would lose entries.
;;
;; Returns 0 when one of them raised.  Returning the class anyway would leave
;; the exception pending with nothing to attach it to, and the next opcode to
;; look at a NULL would be the one that crashed.
;; ============================================================================
TSN_CLS   equ 8
TSN_NS    equ 16
TSN_KEYS  equ 24
TSN_I     equ 32
TSN_N     equ 40
TSN_NAME  equ 48
TSN_FRAME equ 56          ; + 3 pushes = 80
DEF_FUNC type_apply_set_name, TSN_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - TSN_CLS], rdi
    mov [rbp - TSN_NS], rsi
    test rsi, rsi
    jz .done

    ; --- snapshot the keys under OBJ_LOCK ---
    OBJ_LOCK rsi
    mov r12, [rsi + PyDictObject.capacity]
    mov r13, [rsi + PyDictObject.entries]
    xor ebx, ebx
    xor ecx, ecx
.count:
    cmp rcx, r12
    jae .counted
    imul rax, rcx, DICT_ENTRY_SIZE
    cmp qword [r13 + rax + DictEntry.key], 0
    je .count_next
    inc rbx
.count_next:
    inc rcx
    jmp .count
.counted:
    test rbx, rbx
    jz .unlock_done
    mov [rbp - TSN_N], rbx
    mov rdi, rbx
    call tuple_new
    test rax, rax
    jz .unlock_ns_done
    mov [rbp - TSN_KEYS], rax
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rsi, [rbp - TSN_NS]
    mov r12, [rsi + PyDictObject.capacity]
    mov r13, [rsi + PyDictObject.entries]
    xor ebx, ebx
    xor ecx, ecx
.fill:
    cmp rcx, r12
    jae .filled
    imul rax, rcx, DICT_ENTRY_SIZE
    mov rdi, [r13 + rax + DictEntry.key]
    test rdi, rdi
    jz .fill_next
    INCREF_V rdi, r8
    mov [rdx + rbx*8], rdi
    inc rbx
.fill_next:
    inc rcx
    jmp .fill
.filled:
    OBJ_UNLOCK rsi
    jmp .apply_loop
.unlock_ns_done:
    mov rsi, [rbp - TSN_NS]
.unlock_done:
    OBJ_UNLOCK rsi
    jmp .done
.apply_loop:

    ; --- call each value's __set_name__, if its TYPE defines one ---
    mov qword [rbp - TSN_I], 0
.loop:
    mov rax, [rbp - TSN_I]
    cmp rax, [rbp - TSN_N]
    jae .release
    mov rcx, [rbp - TSN_KEYS]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov rcx, [rcx + rax*8]
    mov [rbp - TSN_NAME], rcx

    mov rdi, [rbp - TSN_NS]
    mov rsi, rcx
    extern dict_get
    call dict_get
    ERR_DICT_GET .raised        ; the key is the namespace's own, and anyone's
    V_UNPACK rax, rdx
    test edx, edx
    jz .next                            ; deleted while we walked
    ; The classification is the TAG's to make: after V_UNPACK rax holds a
    ; payload, and testing a payload as if it were a Value calls a small int a
    ; pointer.
    cmp edx, TAG_PTR
    jne .next
    test rax, rax
    jz .next
    mov rbx, rax

    ; Looked up on the type, not the instance: an instance attribute called
    ; __set_name__ is not the hook.
    mov rdi, [rbx + PyObject.ob_type]
    lea rsi, [rel tsn_name]
    extern dunder_exists
    call dunder_exists
    test eax, eax
    jz .next_drop

    mov rdi, rbx                        ; self = the value
    mov rsi, [rbp - TSN_CLS]            ; owner
    mov rdx, [rbp - TSN_NAME]           ; name
    lea rcx, [rel tsn_name]
    mov r8d, TAG_PTR
    call dunder_call_3          ; err: 0, absent or raised, goes to .raised_drop
    test rax, rax               ; dunder_call_3 answers with a Value; 0 is the miss
    jz .raised_drop
    mov rdi, rax
    DECREF_V rdi, rsi
.next_drop:
    mov rdi, rbx
    call obj_decref
.next:
    inc qword [rbp - TSN_I]
    jmp .loop

.release:
    mov rdi, [rbp - TSN_KEYS]
    call obj_decref
.done:
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    leave
    ret
.raised_drop:
    mov rdi, rbx
    call obj_decref
.raised:
    mov rdi, [rbp - TSN_KEYS]
    call obj_decref
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_apply_set_name

;; ============================================================================
;; type_mangle_name(rdi = the name, rsi = the class name) -> rax = an OWNED
;;                  reference: a new string when it mangles, the argument with
;;                  one more reference when it does not
;;
;; CPython's rule, and the same one comp_intern_name applies at compile time:
;; two leading underscores, not two trailing ones, and the class name with its
;; own leading underscores stripped -- an all-underscore class name mangles
;; nothing.  Both have to agree, or a slot and the code that uses it name
;; different things.
;; ============================================================================
TMN_NAME  equ 8
TMN_CLS   equ 16
TMN_BUF   equ 24
TMN_LEN   equ 32
TMN_FRAME equ 48                ; 32 used + 16 pad = 48, 16-aligned
DEF_FUNC type_mangle_name, TMN_FRAME
    push rbx
    push r12
    mov [rbp - TMN_NAME], rdi
    mov [rbp - TMN_CLS], rsi

    test rsi, rsi
    jz .tmn_plain
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .tmn_plain
    mov rax, [rdi + PyObject.ob_type]
    cmp rax, rcx
    jne .tmn_plain

    mov rdx, [rdi + PyStrObject.ob_size]
    cmp rdx, 2
    jl .tmn_plain
    cmp byte [rdi + PyStrObject.data], '_'
    jne .tmn_plain
    cmp byte [rdi + PyStrObject.data + 1], '_'
    jne .tmn_plain
    ; ...but not one that also ends in two underscores.
    cmp rdx, 4
    jl .tmn_mangle
    cmp byte [rdi + PyStrObject.data + rdx - 1], '_'
    jne .tmn_mangle
    cmp byte [rdi + PyStrObject.data + rdx - 2], '_'
    je .tmn_plain

.tmn_mangle:
    ; Strip the class name's own leading underscores.
    mov rsi, [rbp - TMN_CLS]
    lea rbx, [rsi + PyStrObject.data]
    mov r12, [rsi + PyStrObject.ob_size]
.tmn_strip:
    test r12, r12
    jz .tmn_plain               ; nothing but underscores: no mangling
    cmp byte [rbx], '_'
    jne .tmn_stripped
    inc rbx
    dec r12
    jmp .tmn_strip
.tmn_stripped:

    ; "_" + the stripped class name + the name
    mov rdi, [rbp - TMN_NAME]
    mov rax, [rdi + PyStrObject.ob_size]
    lea rdi, [rax + r12 + 2]
    mov [rbp - TMN_LEN], rdi
    call ap_malloc
    test rax, rax
    jz .tmn_plain
    mov [rbp - TMN_BUF], rax
    mov byte [rax], '_'
    lea rdi, [rax + 1]
    mov rsi, rbx
    mov rdx, r12
    call ap_memcpy
    mov rdi, [rbp - TMN_BUF]
    lea rdi, [rdi + r12 + 1]
    mov rsi, [rbp - TMN_NAME]
    mov rdx, [rsi + PyStrObject.ob_size]
    lea rsi, [rsi + PyStrObject.data]
    call ap_memcpy
    mov rdi, [rbp - TMN_BUF]
    mov rsi, [rbp - TMN_NAME]
    mov rsi, [rsi + PyStrObject.ob_size]
    lea rsi, [rsi + r12 + 1]
    call str_new_heap           ; -> rax = PyStrObject*, refcount 1
    push rax
    mov rdi, [rbp - TMN_BUF]
    call ap_free
    pop rax
    pop r12
    pop rbx
    leave
    ret

.tmn_plain:
    mov rax, [rbp - TMN_NAME]
    INCREF rax
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_mangle_name

;; ============================================================================
;; type_apply_hash_rule(rdi = the type, rsi = the class dict) -> rax = 0
;; Fails: -1
;;
;; Python's inherited-hash rule, which is about a name being ABSENT and so
;; cannot be a slot wrapper:
;;
;;   __hash__ = None in the body   -> unhashable
;;   __eq__ defined, __hash__ not  -> unhashable
;;   otherwise                     -> whatever was inherited or installed
;;
;; __ne__ does not count: only __eq__ suppresses it.
;; ============================================================================
TAH_TYPE  equ 8
TAH_DICT  equ 16
TAH_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC type_apply_hash_rule, TAH_FRAME
    mov [rbp - TAH_TYPE], rdi
    mov [rbp - TAH_DICT], rsi
    test rsi, rsi
    jz .tah_done

    CSTRING rdi, "__hash__"
    mov rsi, [rbp - TAH_DICT]
    call tah_dict_get
    ERR_PENDING .tah_fail
    test rax, rax
    jz .tah_no_hash

    ; Present in the body: only None means unhashable.
    extern none_singleton
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .tah_unhashable_slot
    DECREF_V rax, rcx
    jmp .tah_done

.tah_no_hash:
    ; Absent from the body: __eq__ here suppresses it...
    CSTRING rdi, "__eq__"
    mov rsi, [rbp - TAH_DICT]
    call tah_dict_get
    ERR_PENDING .tah_fail
    test rax, rax
    jz .tah_check_inherited
    DECREF_V rax, rcx
    jmp .tah_unhashable
.tah_check_inherited:

    ; ...and so does an INHERITED __hash__ of None, which is how a subclass
    ; of an unhashable class stays unhashable without a rule of its own.
    ; The name resolves through the MRO; the slot does not follow it, so the
    ; two have to be reconciled here.
    mov rdi, [rbp - TAH_TYPE]
    CSTRING rsi, "__hash__"
    extern dunder_lookup
    call dunder_lookup
    test rax, rax
    jz .tah_done
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .tah_unhashable_slot
    DECREF_V rax, rcx
    jmp .tah_done

.tah_unhashable_slot:
    ; The slot only: the name already says None, here or up the MRO.
    extern hash_not_implemented
    mov rax, [rbp - TAH_TYPE]
    lea rcx, [rel hash_not_implemented]
    mov [rax + PyTypeObject.tp_hash], rcx
    jmp .tah_done

.tah_unhashable:
    mov rax, [rbp - TAH_TYPE]
    lea rcx, [rel hash_not_implemented]
    mov [rax + PyTypeObject.tp_hash], rcx

    ; The NAME has to say so too: `Eq.__hash__ is None` is how the stdlib
    ; asks, and a subclass that defines neither inherits the None through the
    ; MRO -- which is why SubEq(Eq) is unhashable in CPython without any
    ; rule of its own.
    CSTRING rdi, "__hash__"
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    mov rdi, [rbp - TAH_DICT]
    mov rsi, rax
    lea rdx, [rel none_singleton]
    extern dict_set
    call dict_set               ; err: tested once the key is released
    add rsp, 8
    pop rdi
    push rax                    ; the verdict, across the release
    sub rsp, 8
    call obj_decref
    add rsp, 8
    pop rax
    ERR_M1 .tah_fail
.tah_done:
    xor eax, eax
    leave
    ret
.tah_fail:
    mov rax, -1
    leave
    ret
END_FUNC type_apply_hash_rule

;; ============================================================================
;; type_wrap_implicit_classmethods(rdi = the type, rsi = the class dict)
;;   -> rax = 0
;; Fails: -1
;;
;; __init_subclass__ and __class_getitem__ are classmethods even when the
;; class body defines them as plain functions -- CPython does this in
;; type_new, and it cannot be expressed as a slot.  Anything already wrapped,
;; or not a plain function at all, is left alone.
;; ============================================================================
TWI_TYPE  equ 8
TWI_DICT  equ 16
TWI_KEY   equ 24
TWI_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC type_wrap_implicit_classmethods, TWI_FRAME
    push rbx
    mov [rbp - TWI_TYPE], rdi
    mov [rbp - TWI_DICT], rsi
    test rsi, rsi
    jz .twi_done

    CSTRING rbx, "__init_subclass__"
    call .twi_one
    test eax, eax
    jnz .twi_fail
    CSTRING rbx, "__class_getitem__"
    call .twi_one
    test eax, eax
    jnz .twi_fail
.twi_done:
    xor eax, eax
    pop rbx
    leave
    ret
.twi_fail:
    mov rax, -1
    pop rbx
    leave
    ret

;; rbx = the name, as a C string -> eax = 0, or -1 with the exception pending
.twi_one:
    push rbx
    sub rsp, 8
    mov rdi, rbx
    extern str_from_cstr_heap
    call str_from_cstr_heap
    add rsp, 8
    pop rbx
    mov [rbp - TWI_KEY], rax

    mov rdi, [rbp - TWI_DICT]
    mov rsi, rax
    extern dict_get
    call dict_get
    ERR_DICT_GET .twi_one_fail
    test rax, rax
    jz .twi_release

    ; Only a plain function is wrapped; a classmethod or staticmethod the
    ; body wrote is already what the author asked for.
    V_TEST_PTR rax, rcx
    ja .twi_release
    mov rcx, [rax + PyObject.ob_type]
    extern func_type
    lea rdx, [rel func_type]
    cmp rcx, rdx
    jne .twi_drop_release

    push rax                    ; [rsp + 8] is the one-element argument array (owned func)
    sub rsp, 8
    extern classmethod_type
    extern classmethod_construct
    lea rdi, [rel classmethod_type]
    lea rsi, [rsp + 8]
    mov edx, 1
    call classmethod_construct  ; err: rax is tested once the old func is released
    add rsp, 8
    pop rdi                     ; owned func from dict_get
    push rax
    sub rsp, 8
    extern obj_decref
    call obj_decref
    add rsp, 8
    pop rax
    test rax, rax
    jz .twi_release

    push rax
    sub rsp, 8
    mov rdi, [rbp - TWI_DICT]
    mov rsi, [rbp - TWI_KEY]
    mov rdx, rax
    extern dict_set
    call dict_set               ; err: tested once the wrapper is released
    add rsp, 8
    pop rdi
    push rax                    ; the verdict, across the release
    sub rsp, 8
    call obj_decref             ; dict_set took its own reference
    add rsp, 8
    pop rax
    ERR_M1 .twi_one_fail
    jmp .twi_release

.twi_drop_release:
    mov rdi, rax
    call obj_decref

.twi_release:
    mov rdi, [rbp - TWI_KEY]
    call obj_decref
    xor eax, eax
    ret
.twi_one_fail:
    mov rdi, [rbp - TWI_KEY]
    call obj_decref
    mov eax, -1
    ret
END_FUNC type_wrap_implicit_classmethods

;; tah_dict_get(rdi = a name C string, rsi = the dict)
;;   -> rax = the Value, or 0 when absent
;; Fails: 0?
DEF_FUNC_LOCAL tah_dict_get, 16
    push rbx
    sub rsp, 8
    mov rbx, rsi
    extern str_from_cstr_heap
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    mov rdi, rbx
    mov rsi, rax
    extern dict_get
    call dict_get               ; err: returned to the caller as is, once the
                                ; key this built is released
    add rsp, 8
    pop rdi
    push rax
    sub rsp, 8
    call obj_decref             ; the key this built
    add rsp, 8
    pop rax
    add rsp, 8
    pop rbx
    leave
    ret
END_FUNC tah_dict_get

section .rodata
tsn_name: db "__set_name__", 0
section .text

;; ============================================================================
;; type_slots_conflict(rdi = the __slots__ sequence, rsi = the class dict,
;;                     rdx = the class name, rcx = TFP_FILLED_* bits)
;;   -> rax = 0
;; Fails: -1
;;
;; "'x' in __slots__ conflicts with class variable", a ValueError, for a slot
;; whose name the class body also bound.  The member descriptor goes into the
;; dict under that name, so without the refusal `__slots__ = ('x',); x = 1`
;; silently lost the 1.  CPython's type_new_copy_slots asks after it has
;; mangled the name, so the name in the message is the mangled one, and it
;; never asks about '__dict__' or '__weakref__', which are not copied.
;;
;; The dict is asked as the class body left it.  __module__ and __doc__ are
;; in it by now whether the body wrote them or not, and rcx says which of the
;; two type_from_parts put there itself; the two cells are plumbing the
;; compiler leaves, and CPython excuses those by name as well.
;;
;; Every item is a str and an identifier: bc_slots_validate runs first.
;; ============================================================================
TSC_SLOTS  equ 8
TSC_DICT   equ 16
TSC_CLS    equ 24
TSC_FILLED equ 32
TSC_I      equ 40
TSC_NAME   equ 48               ; the mangled name, owned
TSC_BUF    equ 48 + 192
TSC_FRAME  equ 48 + 192         ; + 0 pushes = 240, 16-aligned
TSC_FILLED_MODULE equ 1         ; buildclass.asm's TFP_FILLED_MODULE
TSC_FILLED_DOC    equ 2         ; ... and TFP_FILLED_DOC
global type_slots_conflict
DEF_FUNC type_slots_conflict, TSC_FRAME
    mov [rbp - TSC_SLOTS], rdi
    mov [rbp - TSC_DICT], rsi
    mov [rbp - TSC_CLS], rdx
    mov [rbp - TSC_FILLED], rcx
    mov qword [rbp - TSC_I], 0
.tsc_loop:
    mov rax, [rbp - TSC_SLOTS]
    mov rcx, [rbp - TSC_I]
    cmp rcx, [rax + PyTupleObject.ob_size]      ; a list keeps both where a tuple does
    jge .tsc_ok
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdi, [rax + rcx*8]
    mov [rbp - TSC_NAME], rdi                   ; borrowed, until it is mangled
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "__dict__"
    call ap_strcmp
    test eax, eax
    jz .tsc_next
    mov rdi, [rbp - TSC_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "__weakref__"
    call ap_strcmp
    test eax, eax
    jz .tsc_next

    mov rdi, [rbp - TSC_NAME]
    mov rsi, [rbp - TSC_CLS]
    call type_mangle_name
    mov [rbp - TSC_NAME], rax                   ; owned from here
    mov rdi, [rbp - TSC_DICT]
    mov rsi, rax
    extern dict_get
    call dict_get               ; a Value; 0 is the miss
    ERR_DICT_GET .tsc_fail_name
    test rax, rax
    jz .tsc_release
    DECREF_V rax, rcx           ; presence-only check

    ; Bound -- unless it is one of the four that are not the body's doing.
    mov rdi, [rbp - TSC_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "__classcell__"
    call ap_strcmp
    test eax, eax
    jz .tsc_release
    mov rdi, [rbp - TSC_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "__classdictcell__"
    call ap_strcmp
    test eax, eax
    jz .tsc_release
    test qword [rbp - TSC_FILLED], TSC_FILLED_MODULE
    jz .tsc_not_module
    mov rdi, [rbp - TSC_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "__module__"
    call ap_strcmp
    test eax, eax
    jz .tsc_release
.tsc_not_module:
    test qword [rbp - TSC_FILLED], TSC_FILLED_DOC
    jz .tsc_conflict
    mov rdi, [rbp - TSC_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "__doc__"
    call ap_strcmp
    test eax, eax
    jnz .tsc_conflict

.tsc_release:
    mov rdi, [rbp - TSC_NAME]
    call obj_decref
.tsc_next:
    inc qword [rbp - TSC_I]
    jmp .tsc_loop

.tsc_ok:
    xor eax, eax
    leave
    ret

.tsc_conflict:
    ; rbt_append_cstr stops each field at 80 bytes, which is what the buffer
    ; is sized for.
    lea rdi, [rbp - TSC_BUF]
    CSTRING rsi, "'"
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - TSC_NAME]
    lea rsi, [rsi + PyStrObject.data]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "' in __slots__ conflicts with class variable"
    call rbt_append_cstr
    extern exc_ValueError_type
    extern set_exception
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rbp - TSC_BUF]
    call set_exception
.tsc_fail_name:
    mov rdi, [rbp - TSC_NAME]
    call obj_decref
    mov rax, -1
    leave
    ret
END_FUNC type_slots_conflict
