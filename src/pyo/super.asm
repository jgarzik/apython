; super.asm - the super type
;
; `super` used to be a name with nothing behind it: a 27-quadword table whose
; only filled slots were tp_name and tp_basicsize, and whose ob_type was
; ITSELF -- so calling it found no tp_call on its metatype and raised "object
; is not callable".  It existed only because LOAD_SUPER_ATTR needs the name to
; be loadable; the opcode popped that value, discarded it, and did the MRO
; walk itself.  `super().m()` therefore worked and `s = super()` did not, and
; neither did storing one, passing one, or reaching one through getattr.
;
; This is the real type.  The lookup is shared with the opcode rather than
; written twice: super_check computes __self_class__, super_find walks the
; MRO, and super_lookup applies the descriptor protocol to what it finds.
; LOAD_SUPER_ATTR's attribute form is a call to super_lookup; its method form
; keeps arms of its own, because it pushes two values and leaves a function
; unbound on purpose.
;
; The zero-argument form reads the calling frame, as CPython's does: the first
; positional argument, and the __class__ cell the compiler creates for any
; method inside a class body that so much as mentions `super` (sym_note_super)
; and that type_from_parts fills through __classcell__.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

extern type_type
extern type_is_subtype
extern type_mro_next
extern dict_get
extern method_new
extern property_descr_get
extern property_type
extern staticmethod_type
extern classmethod_type
extern func_type
extern builtin_func_type
extern gc_alloc
extern gc_track
extern gc_dealloc
extern obj_incref
extern obj_decref
extern set_exception
extern str_from_cstr_heap
extern eval_saved_r12
extern exc_TypeError_type
extern exc_RuntimeError_type
extern none_singleton
extern value_type
extern obj_dealloc
extern exc_AttributeError_type

; Room for a message plus a type name; a tp_name is a literal in an assembled
; table, so this is a guard rather than a case that happens.
SUP_MSG_MAX equ 240

section .text

;; ============================================================================
;; sup_streq(rdi = a NUL-terminated string, rsi = another) -> eax = 0 if equal
;;
;; The attribute names below are interned, but comparing the bytes costs
;; nothing and does not depend on that being true of the argument.
;; ============================================================================
DEF_FUNC_LOCAL sup_streq
.loop:
    movzx eax, byte [rdi]
    movzx ecx, byte [rsi]
    cmp eax, ecx
    jne .differ
    test eax, eax
    jz .same
    inc rdi
    inc rsi
    jmp .loop
.same:
    xor eax, eax
    leave
    ret
.differ:
    mov eax, 1
    leave
    ret
END_FUNC sup_streq

;; ============================================================================
;; sup_error(rdi = the exception type, rsi = a template, rdx = the text to
;;           substitute for the byte 1 in it, or 0)
;;
;; CPython names the offending type and counts the arguments, and both messages
;; are tested against it.  raise_type_error_with_typename next door composes the
;; same shape but RAISES, and a tp_new has to report by returning instead: it is
;; called from type_call, which holds the argument array.
;; ============================================================================
DEF_FUNC_LOCAL sup_error
    push rbx
    push r12
    push r13
    push r14                    ; four pushes keep rsp 16-aligned at the call
    mov rbx, rsi                ; the template
    mov r12, rdx                ; the substitution
    mov r13, rdi                ; the exception type
    lea r14, [rel sup_msg_buf]
    xor ecx, ecx
.se_copy:
    movzx eax, byte [rbx]
    test al, al
    jz .se_end
    inc rbx
    cmp al, 1
    je .se_insert
    cmp rcx, SUP_MSG_MAX - 2
    jae .se_copy
    mov [r14 + rcx], al
    inc rcx
    jmp .se_copy
.se_insert:
    test r12, r12
    jz .se_copy
    push rsi
    mov rsi, r12
.se_ins_loop:
    movzx eax, byte [rsi]
    test al, al
    jz .se_ins_done
    inc rsi
    cmp rcx, SUP_MSG_MAX - 2
    jae .se_ins_done
    mov [r14 + rcx], al
    inc rcx
    jmp .se_ins_loop
.se_ins_done:
    pop rsi
    jmp .se_copy
.se_end:
    mov byte [r14 + rcx], 0
    mov rdi, r13
    mov rsi, r14
    call set_exception
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sup_error

;; ============================================================================
;; super_no_attribute(rdi = the attribute name) -- sets the AttributeError
;; LOAD_SUPER_ATTR reports, and returns.  A super OBJECT gets the same wording
;; for free: its tp_getattr answers "not here" and the generic path names the
;; type.  The opcode has no object to name, so it composes the same sentence.
;; ============================================================================
global super_no_attribute
DEF_FUNC super_no_attribute
    lea rdx, [rdi + PyStrObject.data]
    lea rdi, [rel exc_AttributeError_type]
    lea rsi, [rel sup_msg_noattr]
    call sup_error
    leave
    ret
END_FUNC super_no_attribute

;; ============================================================================
;; super_check(rdi = the class super was written with, rsi = the object)
;;   -> rax = __self_class__, or 0 with a TypeError pending
;;   -> edx = 1 when that reference is HANDED OVER, 0 when it is borrowed
;;
;; CPython's supercheck.  The object is either an instance of the class -- in
;; which case its type is what gets searched -- or a subclass of it, which is
;; what a classmethod's first argument is, and then the object IS the type to
;; search, or -- the third question -- it SAYS it is an instance of the class,
;; which is what makes super() work through a proxy that forwards attribute
;; access.  Anything else is a TypeError, worded as CPython words it.
;;
;; Only the first two were asked, so every shape that does not compile to
;; LOAD_SUPER_ATTR refused a proxy outright: `s = super(C, p)` then `s.f()`,
;; `getattr(super(C, p), "f")`, and a super object passed anywhere.  The opcode
;; handler asks all three, which is why test_descr.test_proxy_super passed --
;; it happens to use the one shape that specialises -- and why bugs.md read the
;; difference as position-dependent.
;;
;; The third answer is the one place the result is owned: obj_declared_class
;; composes it, and it may be a property's fresh object with no other
;; reference.  edx says which, because the search has to START from it -- for
;; a declared class that is a strict subclass of the written one, its MRO holds
;; classes the written one's does not.
;;
;; **Every `ret` in this function must write edx**, including the arms that can
;; only ever answer "borrowed".  It is an out-parameter, so a path that leaves
;; it is not returning a stale flag -- it is returning whatever the last `call`
;; happened to put in rdx.  The metatype arm did exactly that, and because
;; super_construct reads it as "the reference is already ours" and skips its
;; incref, every `super()` written inside a classmethod took one reference off
;; a live heaptype.  Nothing failed where the mistake was: the class was freed
;; while still reachable and the segfault landed in dict_lookup, type_mro_next
;; or tuple_clear, thousands of instructions away.  make check, make
;; check-cpython, both -source gates and lint.py were green over it; eight of
;; CPython's own test modules segfaulted.  tests/test_super_classmethod_refcount.py
;; is the shape.
;;
;; The object is a VALUE, so its type comes from value_type and not from a raw
;; ob_type read: `super(int, 1)` and `super(float, 1.5)` hand over a NaN-boxed
;; immediate, and reading a header off one is reading the number as an
;; address.  `super(int, 10**30)` worked all along because a big int is boxed.
;; ============================================================================
SC_CLASS equ 8
SC_OBJ   equ 16
SC_OBJTY equ 24
SC_DECL  equ 32                 ; what the object says its class is, owned
SC_FRAME equ 48                 ; 32 used + 16 pad = 48, 16-aligned
global super_check
DEF_FUNC super_check, SC_FRAME
    mov [rbp - SC_CLASS], rdi
    mov [rbp - SC_OBJ], rsi

    mov rdi, rsi
    call value_type
    mov [rbp - SC_OBJTY], rax

    ; A class that derives from the class: search that class's own MRO.
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .sc_instance
    mov rdi, [rbp - SC_OBJ]             ; the candidate subclass
    mov rsi, [rbp - SC_CLASS]
    call type_is_subtype
    test eax, eax
    jz .sc_instance
    mov rax, [rbp - SC_OBJ]
    xor edx, edx                    ; borrowed: it is the caller's own argument
    leave
    ret

.sc_instance:
    mov rdi, [rbp - SC_OBJTY]
    mov rsi, [rbp - SC_CLASS]
    call type_is_subtype
    test eax, eax
    jz .sc_declared
    mov rax, [rbp - SC_OBJTY]
    xor edx, edx                    ; borrowed: the object holds its own type
    leave
    ret

.sc_declared:
    ; Neither the object's type nor the object itself is a subtype.  Ask what
    ; the object SAYS its class is.  obj_declared_class answers 0 for anything
    ; without a __class__ of its own, and unwinds if __class__ raised something
    ; other than an AttributeError -- which is safe here, because nothing in
    ; this frame is owned yet.
    mov rdi, [rbp - SC_OBJ]
    extern obj_declared_class
    call obj_declared_class
    test rax, rax
    jz .sc_bad
    mov [rbp - SC_DECL], rax
    mov rdi, rax
    mov rsi, [rbp - SC_CLASS]
    call type_is_subtype
    test eax, eax
    jz .sc_decl_no
    mov rax, [rbp - SC_DECL]
    mov edx, 1                      ; handed over
    leave
    ret
.sc_decl_no:
    mov rdi, [rbp - SC_DECL]
    call obj_decref
    ; ...and fall into the refusal.

.sc_bad:
    SET_EXC exc_TypeError_type, "super(type, obj): obj must be an instance or subtype of type"
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC super_check

;; ============================================================================
;; super_find(rdi = __self_class__, rsi = __thisclass__, rdx = the name)
;;   -> rax = payload, rdx = tag, BORROWED from the tp_dict that holds it;
;;      (0, 0) when no class after __thisclass__ defines the name
;;
;; The search starts at the entry AFTER __thisclass__ in __self_class__'s MRO.
;; That is the whole point of super in a diamond: following __thisclass__'s
;; own tp_base chain reaches its bases and skips the sibling branch entirely.
;; ============================================================================
SF_ORIGIN equ 8
SF_NAME   equ 16
SF_FRAME  equ 32                ; 16 used + 16 pad = 32, 16-aligned
global super_find
DEF_FUNC super_find, SF_FRAME
    mov [rbp - SF_ORIGIN], rdi
    mov [rbp - SF_NAME], rdx
    call type_mro_next          ; rdi = origin, rsi = the class
    test rax, rax
    jz .sf_absent

.sf_walk:
    ; rcx tracks the current type for the .sf_next step, including the
    ; no-tp_dict path, which would otherwise fall through with rcx undefined.
    mov rcx, rax
    mov rdi, [rax + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .sf_next

    push rax
    mov rsi, [rbp - SF_NAME]
    call dict_get
    V_UNPACK rax, rdx
    pop rcx
    test edx, edx               ; the tag, not the payload: a hit may be int 0
    jnz .sf_done

.sf_next:
    MRO_NEXT rcx, [rbp - SF_ORIGIN]
    mov rax, rcx
    test rax, rax
    jnz .sf_walk

.sf_absent:
    xor eax, eax
    xor edx, edx
.sf_done:
    leave
    ret
END_FUNC super_find

;; ============================================================================
;; super_lookup(rdi = __thisclass__, rsi = __self__, rdx = __self_class__,
;;              rcx = the name, r8 = int64_t *out_absent)
;;   -> rax = payload, rdx = tag, OWNED
;;
;; The attribute form: what `super(B, obj).name` evaluates to, and what
;; LOAD_SUPER_ATTR pushes when its low bit is clear.  Whatever the MRO walk
;; finds goes through the descriptor protocol, which is where the four cases
;; come from:
;;
;;   staticmethod   unwrapped, never bound
;;   classmethod    bound to __self_class__, not to the instance
;;   function       bound to __self__ -- but NOT when __self__ IS
;;                  __self_class__, which is CPython's rule and is why
;;                  `super(B, B).m` is the plain function there and was a
;;                  bound method here
;;   property       run, because `super().value` is the getter's answer and
;;                  not the descriptor
;;
;; and anything else is the class attribute as it stands.
;;
;; *out_absent is 1, with no exception set, when nothing on the MRO has the
;; name; the caller words that failure, because the opcode and the getattr
;; slot word it differently.  A (0, 0) result with *out_absent 0 is a getter
;; that raised.
;; ============================================================================
SL_TYPE     equ 8
SL_OBJ      equ 16
SL_OBJTYPE  equ 24
SL_NAME     equ 32
SL_ATTR     equ 40
SL_TAG      equ 48
SL_BIND     equ 56
SL_ABSENT   equ 64
SL_FRAME    equ 80              ; 64 used + 16 pad = 80, 16-aligned
global super_lookup
DEF_FUNC super_lookup, SL_FRAME
    mov [rbp - SL_TYPE], rdi
    mov [rbp - SL_OBJ], rsi
    mov [rbp - SL_OBJTYPE], rdx
    mov [rbp - SL_NAME], rcx
    mov [rbp - SL_ABSENT], r8
    mov qword [r8], 0

    mov rdi, rdx                ; __self_class__
    mov rsi, [rbp - SL_TYPE]
    mov rdx, rcx                ; the name
    call super_find
    test edx, edx
    jz .sl_absent
    mov [rbp - SL_ATTR], rax
    mov [rbp - SL_TAG], rdx
    INCREF_VAL rax, rdx         ; ours from here on

    cmp qword [rbp - SL_TAG], TAG_PTR
    jne .sl_plain               ; an immediate is never a descriptor

    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel staticmethod_type]
    cmp rcx, rdx
    je .sl_staticmethod
    lea rdx, [rel classmethod_type]
    cmp rcx, rdx
    je .sl_classmethod
    lea rdx, [rel property_type]
    cmp rcx, rdx
    je .sl_property
    lea rdx, [rel func_type]
    cmp rcx, rdx
    je .sl_bind_obj
    lea rdx, [rel builtin_func_type]
    cmp rcx, rdx
    je .sl_bind_obj

.sl_plain:
    mov rax, [rbp - SL_ATTR]
    mov rdx, [rbp - SL_TAG]
    leave
    ret

;; --- a function, bound to __self__ unless __self__ IS the class -------------
.sl_bind_obj:
    mov rsi, [rbp - SL_OBJ]
    test rsi, rsi
    jz .sl_plain                ; super(B): no instance to bind to
    cmp rsi, [rbp - SL_OBJTYPE]
    je .sl_plain                ; super(B, B).m is A.m, not a bound method
    mov rdi, [rbp - SL_ATTR]
    call method_new             ; INCREFs both
    mov [rbp - SL_BIND], rax
    mov rdi, [rbp - SL_ATTR]
    call obj_decref             ; drop the reference the walk took
    mov rax, [rbp - SL_BIND]
    mov edx, TAG_PTR
    leave
    ret

;; --- a staticmethod, unwrapped ---------------------------------------------
.sl_staticmethod:
    mov rcx, [rax + PyStaticMethodObject.sm_callable]
    mov [rbp - SL_BIND], rcx
    mov rdi, rcx
    call obj_incref
    mov rdi, [rbp - SL_ATTR]
    call obj_decref
    mov rax, [rbp - SL_BIND]
    mov edx, TAG_PTR
    leave
    ret

;; --- a classmethod, bound to the class -------------------------------------
.sl_classmethod:
    mov rdi, [rax + PyClassMethodObject.cm_callable]
    mov rsi, [rbp - SL_OBJTYPE]
    call method_new             ; INCREFs both
    mov [rbp - SL_BIND], rax
    mov rdi, [rbp - SL_ATTR]
    call obj_decref
    mov rax, [rbp - SL_BIND]
    mov edx, TAG_PTR
    leave
    ret

;; --- a property, run --------------------------------------------------------
.sl_property:
    ; With no instance -- super(B) unbound, or super(B, B) whose __self__ IS
    ; the class -- CPython calls __get__(None, type), and a property answers
    ; that with itself.  Lib/ssl.py depends on it:
    ; `super(SSLContext, SSLContext).options.__set__(self, value)` reaches
    ; the base class's property to run its setter.
    mov rsi, [rbp - SL_OBJ]
    test rsi, rsi
    jz .sl_plain
    cmp rsi, [rbp - SL_OBJTYPE]
    je .sl_plain
    mov rdi, rax
    call property_descr_get     ; -> (rax, rdx), owned
    mov [rbp - SL_BIND], rax
    mov [rbp - SL_TYPE], rdx    ; SL_TYPE is spent; reuse it for the tag
    mov rdi, [rbp - SL_ATTR]
    call obj_decref
    mov rax, [rbp - SL_BIND]
    mov rdx, [rbp - SL_TYPE]
    leave
    ret

.sl_absent:
    mov rcx, [rbp - SL_ABSENT]
    mov qword [rcx], 1
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC super_lookup

;; ============================================================================
;; super_frame_class() -> rax = the __class__ cell's contents, borrowed, or 0
;;                        with a RuntimeError pending;
;;                        rdx = the first positional argument, borrowed
;;
;; What the zero-argument form reads out of the calling frame.  A builtin has
;; no Python frame of its own, so eval_saved_r12 is the method that wrote
;; `super()` -- the same frame sys._getframe() hands back at depth 0.
;;
;; The compiler guarantees both halves: sym_note_super records a use of
;; __class__ in any function inside a class body that mentions `super`, so the
;; free variable exists even when nothing reads it, and type_from_parts fills
;; the cell through __classcell__ once the class is built.  The checks are
;; still made, because a function lifted out of its class reaches here too.
;; ============================================================================
SFC_FRAME_P equ 8
SFC_CODE    equ 16
SFC_FRAME   equ 32              ; 16 used + 16 pad = 32, 16-aligned
DEF_FUNC_LOCAL super_frame_class, SFC_FRAME
    push rbx
    push r12
    mov rax, [rel eval_saved_r12]
    test rax, rax
    jz .sfc_no_args
    mov [rbp - SFC_FRAME_P], rax
    mov rcx, [rax + PyFrame.code]
    test rcx, rcx
    jz .sfc_no_args
    mov [rbp - SFC_CODE], rcx
    cmp dword [rcx + PyCodeObject.co_argcount], 0
    je .sfc_no_args

    ; Find __class__ among the free variables.
    mov rsi, [rcx + PyCodeObject.co_localsplusnames]
    test rsi, rsi
    jz .sfc_no_cell
    mov r8, [rcx + PyCodeObject.co_localspluskinds]
    test r8, r8
    jz .sfc_no_cell
    mov r9, [rsi + PyTupleObject.ob_item]
    mov r10, [rsi + PyTupleObject.ob_size]
    xor rbx, rbx                ; the slot index, across the strcmp calls
.sfc_scan:
    cmp rbx, r10
    jge .sfc_no_cell
    cmp rbx, [r8 + PyBytesObject.ob_size]
    jae .sfc_no_cell
    movzx eax, byte [r8 + PyBytesObject.data + rbx]
    test eax, CO_FAST_FREE
    jz .sfc_scan_next
    mov rax, [r9 + rbx*8]
    test rax, rax
    jz .sfc_scan_next
    mov r12, r9                 ; the names array, across the call
    push r8
    push r10
    lea rdi, [rax + PyStrObject.data]
    lea rsi, [rel sup_class_name]
    call sup_streq
    pop r10
    pop r8
    mov r9, r12
    test eax, eax
    jz .sfc_found
.sfc_scan_next:
    inc rbx
    jmp .sfc_scan

.sfc_found:
    mov rax, [rbp - SFC_FRAME_P]
    mov rcx, [rax + PyFrame.localsplus + rbx*8]
    test rcx, rcx
    jz .sfc_empty_cell
    mov rcx, [rcx + PyCellObject.ob_ref]
    test rcx, rcx
    jz .sfc_empty_cell
    mov rdx, [rax + PyFrame.localsplus]     ; the first positional argument
    test rdx, rdx
    jz .sfc_arg_deleted
    mov rax, rcx
    pop r12
    pop rbx
    leave
    ret

.sfc_no_args:
    SET_EXC exc_RuntimeError_type, "super(): no arguments"
    jmp .sfc_fail
.sfc_no_cell:
    SET_EXC exc_RuntimeError_type, "super(): __class__ cell not found"
    jmp .sfc_fail
.sfc_empty_cell:
    SET_EXC exc_RuntimeError_type, "super(): empty __class__ cell"
    jmp .sfc_fail
.sfc_arg_deleted:
    SET_EXC exc_RuntimeError_type, "super(): arg[0] deleted"
.sfc_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC super_frame_class

;; ============================================================================
;; super_construct(rdi = super_type, rsi = args, rdx = nargs) -> Value
;;
;; tp_new, which is where a type's constructor goes: tp_call on a type is what
;; makes that type's INSTANCES callable, and a super object is not callable.
;; ============================================================================
SN_TYPE   equ 8
SN_OBJ    equ 16
SN_OBJTY  equ 24
SN_SELF   equ 32
SN_OBJTY_OWNED equ 40           ; super_check's third arm hands the class over
SN_FRAME  equ 48                ; 40 used + 8 pad = 48, 16-aligned
global super_construct
DEF_FUNC super_construct, SN_FRAME
    mov qword [rbp - SN_OBJ], 0
    mov qword [rbp - SN_OBJTY], 0
    mov qword [rbp - SN_OBJTY_OWNED], 0
    test rdx, rdx
    je .sn_zero_arg
    cmp rdx, 1
    je .sn_one_arg
    cmp rdx, 2
    je .sn_two_arg
    ; "...got 3" -- render the count, which is what CPython reports.
    lea rcx, [rel sup_msg_buf + SUP_MSG_MAX]
    mov byte [rcx], 0
    mov rax, rdx
    mov r8d, 10
.sn_digits:
    xor edx, edx
    div r8
    add dl, '0'
    dec rcx
    mov [rcx], dl
    test rax, rax
    jnz .sn_digits
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sup_msg_nargs]
    mov rdx, rcx
    call sup_error
    jmp .sn_fail

.sn_one_arg:
    ; super(B) -- unbound.  Useless until it is bound, but CPython builds it.
    mov rax, [rsi]
    mov [rbp - SN_TYPE], rax
    jmp .sn_check_type

.sn_two_arg:
    mov rax, [rsi]
    mov [rbp - SN_TYPE], rax
    mov rax, [rsi + 8]
    mov [rbp - SN_OBJ], rax
    jmp .sn_check_type

.sn_zero_arg:
    call super_frame_class
    test rax, rax
    jz .sn_fail
    mov [rbp - SN_TYPE], rax
    mov [rbp - SN_OBJ], rdx

.sn_check_type:
    ; The first argument has to be a class; the object is checked against it.
    mov rax, [rbp - SN_TYPE]
    V_TEST_PTR rax, rcx
    ja .sn_bad_type             ; NULL or an immediate is not a class
    mov rcx, [rax + PyObject.ob_type]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .sn_bad_type

    mov rax, [rbp - SN_OBJ]
    test rax, rax
    jz .sn_alloc                ; super(B): no object, no __self_class__
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .sn_none_obj
    mov rdi, [rbp - SN_TYPE]
    mov rsi, rax
    call super_check
    test rax, rax
    jz .sn_fail                 ; super_check set the TypeError
    mov [rbp - SN_OBJTY], rax
    mov [rbp - SN_OBJTY_OWNED], rdx ; 1 when super_check handed the reference
                                    ; over: its third arm composes the class
    jmp .sn_alloc

.sn_none_obj:
    ; CPython treats super(B, None) as the unbound form.
    mov qword [rbp - SN_OBJ], 0

.sn_alloc:
    mov edi, PySuperObject_size
    lea rsi, [rel super_type]
    call gc_alloc               ; ob_refcnt = 1, ob_type set
    mov [rbp - SN_SELF], rax
    mov rcx, [rbp - SN_TYPE]
    mov [rax + PySuperObject.su_type], rcx
    mov rcx, [rbp - SN_OBJ]
    mov [rax + PySuperObject.su_obj], rcx
    mov rcx, [rbp - SN_OBJTY]
    mov [rax + PySuperObject.su_obj_type], rcx

    mov rdi, [rbp - SN_TYPE]
    call obj_incref
    mov rdi, [rbp - SN_OBJ]
    INCREF_V rdi, rcx           ; a Value: super(int, 1) holds an immediate
    mov rdi, [rbp - SN_OBJTY]
    test rdi, rdi
    jz .sn_no_objty_ref
    cmp qword [rbp - SN_OBJTY_OWNED], 0
    jne .sn_no_objty_ref        ; already ours
    call obj_incref
.sn_no_objty_ref:
    ; gc_track only now, for the reason code_new gives: tracking can trigger a
    ; collection, and a half-filled object would be traversed by it.
    mov rdi, [rbp - SN_SELF]
    call gc_track

    mov rax, [rbp - SN_SELF]
    mov edx, TAG_PTR
    leave
    ret

.sn_bad_type:
    mov rdi, [rbp - SN_TYPE]
    call value_type             ; NULL for an immediate, which prints nothing
    test rax, rax
    jz .sn_bad_type_bare
    mov rdx, [rax + PyTypeObject.tp_name]
    jmp .sn_bad_type_msg
.sn_bad_type_bare:
    xor edx, edx
.sn_bad_type_msg:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel sup_msg_argtype]
    call sup_error
    jmp .sn_fail
.sn_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC super_construct

;; ============================================================================
;; super_own_attr(rdi = the name, rsi = __thisclass__, rdx = __self__ as a
;;                Value, rcx = __self_class__ or 0)
;;   -> rax = an OWNED Value, or 0 when the name is not one super answers
;;
;; The four names a super answers for itself, without a super object to ask.
;; LOAD_SUPER_ATTR is `super(C, o).attr` written out in full and has no super
;; object -- it has the three operands -- so it searched the MRO for these and
;; came back empty: `super(list, [1]).__self__` was an AttributeError where
;; CPython, whose unspecialised path builds a real super and getattrs it,
;; answers the list.
;;
;; super_getattr keeps its own copy of the comparisons rather than calling
;; this, because it has to tell "one of mine" from "absent" to fall through to
;; the MRO search, and it reaches __class__ through the generic path.
;; ============================================================================
SOA_NAME  equ 8
SOA_CLASS equ 16
SOA_SELF  equ 24
SOA_OBJTY equ 32
SOA_FRAME equ 48                ; 32 used + 16 pad = 48, 16-aligned
global super_own_attr
DEF_FUNC super_own_attr, SOA_FRAME
    mov [rbp - SOA_NAME], rdi
    mov [rbp - SOA_CLASS], rsi
    mov [rbp - SOA_SELF], rdx
    mov [rbp - SOA_OBJTY], rcx

    lea rdi, [rdi + PyStrObject.data]
    lea rsi, [rel sup_a_self]
    call sup_streq
    test eax, eax
    jz .soa_self

    mov rdi, [rbp - SOA_NAME]
    lea rdi, [rdi + PyStrObject.data]
    lea rsi, [rel sup_a_thisclass]
    call sup_streq
    test eax, eax
    jz .soa_thisclass

    mov rdi, [rbp - SOA_NAME]
    lea rdi, [rdi + PyStrObject.data]
    lea rsi, [rel sup_a_selfclass]
    call sup_streq
    test eax, eax
    jz .soa_selfclass

    mov rdi, [rbp - SOA_NAME]
    lea rdi, [rdi + PyStrObject.data]
    lea rsi, [rel sup_a_class]
    call sup_streq
    test eax, eax
    jz .soa_class

    xor eax, eax                ; not ours
    leave
    ret

.soa_self:
    mov rax, [rbp - SOA_SELF]
    test rax, rax
    jz .soa_none                ; the unbound form
    jmp .soa_one
.soa_thisclass:
    mov rax, [rbp - SOA_CLASS]
    jmp .soa_one
.soa_selfclass:
    mov rax, [rbp - SOA_OBJTY]
    test rax, rax
    jz .soa_none
    jmp .soa_one
.soa_class:
    lea rax, [rel super_type]
    jmp .soa_one
.soa_none:
    lea rax, [rel none_singleton]
.soa_one:
    INCREF_V rax, rcx           ; __self__ may be an immediate
    leave
    ret
END_FUNC super_own_attr

;; ============================================================================
;; super_getattr(rdi = the super object, rsi = the name)
;;   -> rax = payload, rdx = tag; (0, 0) for "not here, try the generic path"
;;
;; The (payload, tag) worker behind super_getattr_value, which is the slot:
;; tp_getattr answers a VALUE, and this was in the table until __self__ could
;; be an immediate.  Every answer used to be a pointer, and a pointer is its
;; own Value, so the mismatch was invisible -- until `super(int, 1).__self__`
;; came back as the payload 1, which op_load_attr's V_UNPACK then read as a
;; pointer to address 1.
;;
;; The three attributes of its own answer first -- CPython keeps
;; them as members, and `s.__self__` must not be looked for in the MRO -- and
;; everything else is super_lookup.  An unbound super has no __self_class__
;; and so nothing to search, which is what makes `super(B).__class__` answer
;; `super` rather than something out of B's bases.
;; ============================================================================
SG_SELF  equ 8
SG_NAME  equ 16
SG_ABS   equ 24
SG_FRAME equ 32                 ; 24 used + 8 pad = 32, 16-aligned
global super_getattr
DEF_FUNC super_getattr, SG_FRAME
    mov [rbp - SG_SELF], rdi
    mov [rbp - SG_NAME], rsi

    lea rdi, [rsi + PyStrObject.data]
    lea rsi, [rel sup_a_self]
    call sup_streq
    test eax, eax
    jz .sg_self

    mov rdi, [rbp - SG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    lea rsi, [rel sup_a_thisclass]
    call sup_streq
    test eax, eax
    jz .sg_thisclass

    mov rdi, [rbp - SG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    lea rsi, [rel sup_a_selfclass]
    call sup_streq
    test eax, eax
    jz .sg_selfclass

    ; An ordinary attribute: search the MRO past __thisclass__.
    mov rax, [rbp - SG_SELF]
    mov rdx, [rax + PySuperObject.su_obj_type]
    test rdx, rdx
    jz .sg_absent               ; unbound: nothing to search
    mov rdi, [rax + PySuperObject.su_type]
    mov rsi, [rax + PySuperObject.su_obj]
    mov rcx, [rbp - SG_NAME]
    lea r8, [rbp - SG_ABS]
    call super_lookup
    leave
    ret

.sg_self:
    mov rax, [rbp - SG_SELF]
    mov rax, [rax + PySuperObject.su_obj]
    test rax, rax
    jz .sg_none
    ; A Value: an immediate is not a pointer to INCREF, and not a TAG_PTR.
    INCREF_V rax, rcx
    V_UNPACK rax, rdx
    leave
    ret
.sg_thisclass:
    mov rax, [rbp - SG_SELF]
    mov rax, [rax + PySuperObject.su_type]
    jmp .sg_one
.sg_selfclass:
    mov rax, [rbp - SG_SELF]
    mov rax, [rax + PySuperObject.su_obj_type]
    test rax, rax
    jz .sg_none
    jmp .sg_one
.sg_none:
    lea rax, [rel none_singleton]
.sg_one:
    INCREF rax
    mov edx, TAG_PTR
    leave
    ret

.sg_absent:
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC super_getattr

;; ============================================================================
;; super_getattr_value(rdi = the super object, rsi = the name) -> rax = Value
;;
;; super_getattr in the shape both tp_getattr and a getset descriptor's getter
;; are called in: it answers a (payload, tag) pair and this packs it.  It is
;; the tp_getattr slot as well as the getter for the three names it owns --
;; __self__, __self_class__ and __thisclass__ -- so the pair never escapes.
;;
;; V_PACK runs BEFORE the leave: its cold path is a call, and after the leave
;; that call is made at the caller's stack parity rather than this frame's.
;; ============================================================================
DEF_FUNC super_getattr_value
    call super_getattr
    test edx, edx
    jz .sgv_absent
    V_PACK rax, rdx
    leave
    ret
.sgv_absent:
    xor eax, eax
    leave
    ret
END_FUNC super_getattr_value

;; ============================================================================
;; super_dunder_new(args, nargs) -> Value    -- super.__new__
;;
;; super keeps its constructor in tp_new, so `super.__new__` was
;; object.__new__ and a subclass could not reach it by name.
;; ============================================================================
extern new_from_slot
DEF_FUNC super_dunder_new
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rel super_type]
    call new_from_slot
    leave
    ret
END_FUNC super_dunder_new

;; ============================================================================
;; super_dunder_get(args, nargs) -> Value    -- super.__get__(obj[, owner])
;;
;; An unbound super binds itself to the instance on the way out, exactly as a
;; function does, which is what makes `C._C__super = super(C)` and then
;; `self.__super.meth(a)` work -- the idiom test_descr.test_supers is built
;; on.  Without it `hasattr(super(C), '__get__')` was False, the attribute
;; paths handed the unbound super back unchanged, and every name on it missed.
;;
;; Already bound, or bound to nothing, is the identity: CPython's
;; super_descr_get returns self for both.  A strict subclass of super is built
;; through super_construct too rather than through its own type; that differs
;; from CPython only for a subclass that overrides __new__, which the tree has
;; no other machinery for either.
;; ============================================================================
SDG_ARGS  equ 16            ; the two-element array super_construct reads
SDG_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
global super_dunder_get
DEF_FUNC super_dunder_get, SDG_FRAME
    mov rax, [rdi]              ; self, always a pointer
    cmp rsi, 2
    jl .sdg_as_is
    mov rcx, [rdi + 8]          ; the instance
    test rcx, rcx
    jz .sdg_as_is
    lea rdx, [rel none_singleton]
    cmp rcx, rdx
    je .sdg_as_is
    cmp qword [rax + PySuperObject.su_obj], 0
    jne .sdg_as_is              ; already bound

    mov rdx, [rax + PySuperObject.su_type]
    mov [rbp - SDG_ARGS], rdx
    mov [rbp - SDG_ARGS + 8], rcx
    lea rdi, [rel super_type]
    lea rsi, [rbp - SDG_ARGS]
    mov edx, 2
    call super_construct        ; answers a Value, and does the supercheck
    leave
    ret

.sdg_as_is:
    INCREF rax
    leave
    ret
END_FUNC super_dunder_get

;; ============================================================================
;; super_repr(rdi = the super object) -> rax = PyStrObject*, rdx = TAG_PTR
;;
;; CPython's two forms: "<super: <class 'B'>, <B object>>" when it is bound,
;; and "<super: <class 'B'>, NULL>" when it is not.  Both name types, and a
;; type's name is a C string in the table, so this never runs Python.
;; ============================================================================
SR_SELF  equ 8
SR_LEN   equ 16
SR_BUF   equ 528
SR_FRAME equ 544                ; 528 used + 16 pad = 544, 16-aligned
DEF_FUNC_LOCAL super_repr, SR_FRAME
    push rbx
    push r12
    mov [rbp - SR_SELF], rdi
    lea rbx, [rbp - SR_BUF]
    xor r12d, r12d

    CSTRING rsi, "<super: <class '"
    call .sr_append

    mov rax, [rbp - SR_SELF]
    mov rax, [rax + PySuperObject.su_type]
    test rax, rax
    jz .sr_type_null
    mov rsi, [rax + PyTypeObject.tp_name]
    jmp .sr_type_name
.sr_type_null:
    CSTRING rsi, "NULL"
.sr_type_name:
    call .sr_append

    CSTRING rsi, "'>, "
    call .sr_append

    mov rax, [rbp - SR_SELF]
    mov rax, [rax + PySuperObject.su_obj_type]
    test rax, rax
    jz .sr_obj_null
    CSTRING rsi, "<"
    call .sr_append
    mov rax, [rbp - SR_SELF]
    mov rax, [rax + PySuperObject.su_obj_type]
    mov rsi, [rax + PyTypeObject.tp_name]
    call .sr_append
    CSTRING rsi, " object>>"
    call .sr_append
    jmp .sr_build
.sr_obj_null:
    CSTRING rsi, "NULL>"
    call .sr_append

.sr_build:
    mov byte [rbx + r12], 0
    mov rdi, rbx
    call str_from_cstr_heap
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

;; .sr_append(rsi = a C string) -- copies it into the buffer at r12, stopping
;; short of the end.  A tp_name is a literal in an assembled table, so the cap
;; is a guard rather than a case that happens.
.sr_append:
    movzx eax, byte [rsi]
    test al, al
    jz .sr_append_done
    cmp r12, SR_BUF - 16
    jae .sr_append_done
    mov [rbx + r12], al
    inc r12
    inc rsi
    jmp .sr_append
.sr_append_done:
    ret
END_FUNC super_repr

;; ============================================================================
;; super_dealloc / super_traverse / super_clear
;;
;; All three fields are strong: an unbound super has only the first, and a
;; bound one holds its instance, which is how a super stored on that instance
;; makes a cycle the collector has to be able to see.
;;
;; su_obj is a VALUE and the other two are types, so it is the one released,
;; visited and cleared as a Value -- an immediate is neither a reference to
;; drop nor an edge for the collector to follow.
;; ============================================================================
DEF_FUNC_LOCAL super_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PySuperObject.su_type]
    test rdi, rdi
    jz .sd_no_type
    call obj_decref
.sd_no_type:
    mov rdi, [rbx + PySuperObject.su_obj]
    DECREF_V rdi, rax
    mov rdi, [rbx + PySuperObject.su_obj_type]
    test rdi, rdi
    jz .sd_no_objty
    call obj_decref
.sd_no_objty:
    mov rdi, rbx
    call gc_dealloc
    pop rbx
    leave
    ret
END_FUNC super_dealloc

global super_traverse
DEF_FUNC super_traverse
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + PySuperObject.su_type]
    VISIT_PTR rdi
    mov rdi, [rbx + PySuperObject.su_obj]
    VISIT_V rdi, rax
    mov rdi, [rbx + PySuperObject.su_obj_type]
    VISIT_PTR rdi
    pop r12
    pop rbx
    leave
    ret
END_FUNC super_traverse

global super_clear
DEF_FUNC super_clear
    push rbx
    push r12
    mov rbx, rdi
    xor r12d, r12d
.scl_loop:
    cmp r12d, 3
    jge .scl_done
    mov rax, r12
    shl rax, 3
    mov rdi, [rbx + PySuperObject.su_type + rax]
    mov qword [rbx + PySuperObject.su_type + rax], 0
    DECREF_V rdi, rax           ; su_obj may be an immediate; the rest are types
.scl_next:
    inc r12d
    jmp .scl_loop
.scl_done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC super_clear

section .data
align 8
global super_type
super_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq sup_name_str             ; tp_name
    dq PySuperObject_size       ; tp_basicsize
    dq super_dealloc            ; tp_dealloc
    dq super_repr               ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call  (a super is not callable)
    dq super_getattr_value      ; tp_getattr -- answers a Value, not a pair
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq super_construct          ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC | TYPE_FLAG_DESCRIPTOR  ; tp_flags
    dq 0                        ; tp_bases
    dq super_traverse           ; tp_traverse
    dq super_clear              ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

sup_msg_nargs:     db "super() expected at most 2 arguments, got ", 1, 0
sup_msg_noattr:    db "'super' object has no attribute '", 1, "'", 0
sup_msg_argtype:   db "super() argument 1 must be a type, not ", 1, 0

sup_name_str:      db "super", 0
sup_class_name:    db "__class__", 0
sup_a_self:        db "__self__", 0
sup_a_thisclass:   db "__thisclass__", 0
sup_a_selfclass:   db "__self_class__", 0
sup_a_class:       db "__class__", 0

section .bss
sup_msg_buf: resb SUP_MSG_MAX + 24      ; the message, then room for the digits
