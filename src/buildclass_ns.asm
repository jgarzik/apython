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

    ; --- snapshot the keys ---
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
    jz .done
    mov [rbp - TSN_N], rbx
    mov rdi, rbx
    call tuple_new
    test rax, rax
    jz .done
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
    call dict_get
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
    call dunder_lookup
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    jz .next

    mov rdi, rbx                        ; self = the value
    mov rsi, [rbp - TSN_CLS]            ; owner
    mov rdx, [rbp - TSN_NAME]           ; name
    lea rcx, [rel tsn_name]
    mov r8d, TAG_PTR
    call dunder_call_3          ; err: 0, absent or raised, goes to .raised
    test rax, rax               ; dunder_call_3 answers with a Value; 0 is the miss
    jz .raised
    mov rdi, rax
    DECREF_V rdi, rsi
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
;; type_apply_hash_rule(rdi = the type, rsi = the class dict)
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
    test rax, rax
    jz .tah_no_hash

    ; Present in the body: only None means unhashable.
    extern none_singleton
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .tah_unhashable_slot
    jmp .tah_done

.tah_no_hash:
    ; Absent from the body: __eq__ here suppresses it...
    CSTRING rdi, "__eq__"
    mov rsi, [rbp - TAH_DICT]
    call tah_dict_get
    test rax, rax
    jnz .tah_unhashable

    ; ...and so does an INHERITED __hash__ of None, which is how a subclass
    ; of an unhashable class stays unhashable without a rule of its own.
    ; The name resolves through the MRO; the slot does not follow it, so the
    ; two have to be reconciled here.
    mov rdi, [rbp - TAH_TYPE]
    CSTRING rsi, "__hash__"
    extern dunder_lookup
    call dunder_lookup
    V_UNPACK rax, rdx
    test edx, edx
    jz .tah_done
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    jne .tah_done
    jmp .tah_unhashable_slot

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
    call dict_set
    add rsp, 8
    pop rdi
    call obj_decref
.tah_done:
    leave
    ret
END_FUNC type_apply_hash_rule

;; ============================================================================
;; type_wrap_implicit_classmethods(rdi = the type, rsi = the class dict)
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
    CSTRING rbx, "__class_getitem__"
    call .twi_one
.twi_done:
    pop rbx
    leave
    ret

;; rbx = the name, as a C string
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
    jne .twi_release

    push rax                    ; [rsp] is the one-element argument array
    sub rsp, 8
    extern classmethod_type
    extern classmethod_construct
    lea rdi, [rel classmethod_type]
    lea rsi, [rsp + 8]
    mov edx, 1
    call classmethod_construct  ; err: rax is tested once the stack is back
    add rsp, 8
    pop rcx
    test rax, rax
    jz .twi_release

    push rax
    sub rsp, 8
    mov rdi, [rbp - TWI_DICT]
    mov rsi, [rbp - TWI_KEY]
    mov rdx, rax
    extern dict_set
    call dict_set
    add rsp, 8
    pop rdi
    extern obj_decref
    call obj_decref             ; dict_set took its own reference

.twi_release:
    mov rdi, [rbp - TWI_KEY]
    call obj_decref
    ret
END_FUNC type_wrap_implicit_classmethods

;; tah_dict_get(rdi = a name C string, rsi = the dict)
;;   -> rax = the Value, or 0 when absent
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
    call dict_get
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
