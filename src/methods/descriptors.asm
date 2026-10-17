; methods/descriptors.asm - the methods in staticmethod's, classmethod's and
;                           property's tp_dicts
;
; The same split as everywhere else in the tree: src/pyo/descriptors.asm is
; the three types, this is what they answer to by NAME.  It exists because
; each of them needs an `__init__`, and until it did a SUBCLASS could not have
; one of its own:
;
;     class Named(property):
;         def __init__(self, fget, label):
;             super().__init__(fget)      ; reached object.__init__, which
;             self.label = label          ; refuses arguments
;
; CPython puts the argument parsing in tp_init and leaves tp_new to allocate.
; Here it is in tp_new, because that is what the interpreter's own call path
; reaches for the exact type -- type_call's builtin shortcut runs tp_new and
; nothing else.  A heaptype subclass takes the other road and runs both, so
; these re-run the parse over whatever the subclass passed up, and the last
; write wins.  For a subclass that defines no __init__ of its own they are
; simply handed the same arguments twice and settle on the same answer.

%include "macros.inc"
%include "object.inc"

extern obj_decref
extern obj_dealloc
extern obj_incref
extern none_singleton
extern exc_TypeError_type
extern raise_exception
extern eval_exception_unwind
extern property_type
extern property_construct

section .text

;; ============================================================================
;; prop_new_of(rdi = the class to build, rsi = a [fget, fset, fdel] array,
;;             rdx = how many of them are meaningful) -> rax = a new property
;;
;; What property.getter, property.setter and property.deleter each hand back:
;; a copy of the original with one accessor replaced, and of the ORIGINAL'S
;; class, so a decorator chain on a subclass still yields the subclass.
;;
;; It goes through __init__ rather than through the constructor's own parse,
;; because a subclass's tp_new deliberately leaves the accessors alone -- they
;; are its __init__'s business, which is the only way `class Named(property)`
;; taking (fget, label) can work at all.  Building one here therefore has to
;; run the same fill type_call would, and running it for the exact type too
;; keeps one path instead of two.
;; ============================================================================
PNO_SELF  equ 8
PNO_ARGS  equ 48                ; [self, fget, fset, fdel], contiguous
PNO_N     equ 56
PNO_FRAME equ 56                ; 56 + 1 push keeps rsp 16-aligned

DEF_FUNC prop_new_of, PNO_FRAME
    push rbx
    mov [rbp - PNO_N], rdx

    ; Copy the accessors into the tail of the argument array, leaving room for
    ; self in front of them.
    xor ecx, ecx
.pno_copy:
    cmp rcx, rdx
    jge .pno_copied
    mov rax, [rsi + rcx*8]
    mov [rbp - PNO_ARGS + 8 + rcx*8], rax
    inc rcx
    jmp .pno_copy
.pno_copied:

    ; An EMPTY property of the right class.  Nought arguments, so the exact
    ; type does not parse either -- one fill, below.
    xor esi, esi
    xor edx, edx
    call property_construct
    test rax, rax
    jz .pno_out
    mov rbx, rax
    mov [rbp - PNO_ARGS], rax               ; args[0] = self

    lea rdi, [rbp - PNO_ARGS]
    mov rsi, [rbp - PNO_N]
    inc rsi                                 ; self as well
    call property_method_init
    test rax, rax
    jz .pno_failed
    mov rax, rbx
.pno_out:
    pop rbx
    leave
    ret
.pno_failed:
    mov rdi, rbx
    call obj_decref
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC prop_new_of

;; ============================================================================
;; staticmethod_method_init(rdi = args, rsi = nargs) -> a Value, always None
;;
;; staticmethod.__init__(self, callable).  The wrapped callable is a VALUE,
;; not a pointer: `staticmethod(0)` is an ordinary call.
;; ============================================================================
DEF_FUNC staticmethod_method_init
    push rbx
    push r12
    cmp rsi, 2
    jne .smi_bad
    mov rbx, [rdi]                          ; self
    mov r12, [rdi + 8]                      ; the new callable
    mov rdi, [rbx + PyStaticMethodObject.sm_callable]
    mov [rbx + PyStaticMethodObject.sm_callable], r12
    INCREF_V r12, rax
    XDECREF_V rdi, rax
    RET_NONE
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.smi_bad:
    RAISE exc_TypeError_type, "staticmethod expected 1 argument"
END_FUNC staticmethod_method_init

;; ============================================================================
;; classmethod_method_init(rdi = args, rsi = nargs) -> a Value, always None
;;
;; classmethod.__init__(self, callable), and the same VALUE caveat.
;; ============================================================================
DEF_FUNC classmethod_method_init
    push rbx
    push r12
    cmp rsi, 2
    jne .cmi_bad
    mov rbx, [rdi]                          ; self
    mov r12, [rdi + 8]                      ; the new callable
    mov rdi, [rbx + PyClassMethodObject.cm_callable]
    mov [rbx + PyClassMethodObject.cm_callable], r12
    INCREF_V r12, rax
    XDECREF_V rdi, rax
    RET_NONE
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.cmi_bad:
    RAISE exc_TypeError_type, "classmethod expected 1 argument"
END_FUNC classmethod_method_init

;; Move one field out of the freshly parsed property and into self, releasing
;; what self was holding.  The temporary's slot is zeroed first so that
;; releasing IT afterwards does not take the value with it.
%macro PMI_MOVE 1               ; %1 = the PyPropertyObject field
    mov rax, [r12 + PyPropertyObject.%1]
    mov rdi, [rbx + PyPropertyObject.%1]
    mov [rbx + PyPropertyObject.%1], rax
    mov qword [r12 + PyPropertyObject.%1], 0
    XDECREF_V rdi, rcx          ; may dealloc, so nothing lives in rax here
%endmacro

;; ============================================================================
;; property_method_init(rdi = args, rsi = nargs) -> a Value, always None
;;
;; property.__init__(self, fget, fset, fdel, doc), with all four
;; positional-or-keyword, which is a hundred lines of parsing in
;; property_construct.  Rather than keep a second copy of it, this builds a
;; throwaway property from the same arguments and moves its four fields over.
;; The allocation is one gc_alloc on the coldest path there is -- constructing
;; a property subclass -- and the alternative is two spellings of the argument
;; rules that can drift apart.
;;
;; prop_name is deliberately not moved: __set_name__ records where the
;; property was assigned, and re-running __init__ does not move it.
;; ============================================================================
PMI_FRAME equ 8                 ; 8 + 3 pushes keeps rsp 16-aligned

DEF_FUNC property_method_init, PMI_FRAME
    push rbx
    push r12
    push r13
    test rsi, rsi
    jz .pmi_bad
    mov rbx, [rdi]                          ; self

    mov rdx, rsi
    dec rdx                                 ; the arguments after self
    lea rsi, [rdi + 8]
    lea rdi, [rel property_type]
    call property_construct                 ; -> rax = a parsed property
    mov r12, rax

    PMI_MOVE prop_get
    PMI_MOVE prop_set
    PMI_MOVE prop_del
    PMI_MOVE prop_doc

    ; A SUBCLASS keeps __doc__ in its own instance dict.  property's fget,
    ; fset and fdel are read through property_getattr, which a subclass
    ; instance still reaches -- but __doc__ never gets that far, because the
    ; MRO walk finds the SUBCLASS's own class docstring first, and for a class
    ; that has none that is None.  CPython's property_init_impl writes it to
    ; the instance for exactly this reason.
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel property_type]
    cmp rax, rcx
    je .pmi_done
    mov r13, [rbx + PyPropertyObject.prop_doc]
    test r13, r13
    jz .pmi_done
    lea rdi, [rel pmi_doc_name]
    extern dunder_name_obj
    call dunder_name_obj                    ; an interned "__doc__"
    mov rsi, rax
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_setattr]
    test rax, rax
    jz .pmi_done
    mov rdi, rbx
    mov rdx, r13                            ; the doc, a Value
    call rax
.pmi_done:

    mov rdi, r12                            ; the throwaway, now emptied
    call obj_decref
    RET_NONE
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.pmi_bad:
    RAISE exc_TypeError_type, "property.__init__() needs an instance"

section .rodata
pmi_doc_name: db "__doc__", 0
section .text
END_FUNC property_method_init
