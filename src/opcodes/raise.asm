; opcodes/raise.asm - The raises a handler makes by name
;
; An error is RETURNED everywhere but in an opcode handler: a handler is the
; eval loop, so it alone may jump into the unwinder, which releases what it
; left on the value stack.  The composed messages live with their subjects --
; objerr.asm, object.asm, pyo/exception.asm -- as `set_*` functions that
; record the exception and return.  What is here is the other half, for the
; handlers only: each is its `set_*` twin and then the unwind.
;
; Each takes its own frame down before the jump, so the unwinder starts from
; the handler's.
;
; None of them republishes PyFrame.disp_sp.  A handler that has released its
; operands itself says so before it gets here (PUBLISH_SP); one that has only
; popped them leaves the release to the unwinder.  See check_unwind_balance
; in src/compiler/lint.py.

%include "macros.inc"
%include "object.inc"

extern eval_exception_unwind
extern set_type_error_with_name
extern set_type_error_with_typename
extern set_binop_type_error
extern set_binop_type_error_ex
extern set_typed_message
extern set_callable_arg
extern set_attribute_error
extern exc_set_import

section .text

;; ============================================================================
;; raise_type_error_with_name(rdi = a message with one \x01, rsi = a Value)
;;   -> does not return: set_type_error_with_name, then the unwind
;; ============================================================================
DEF_FUNC raise_type_error_with_name
    call set_type_error_with_name
    leave
    jmp eval_exception_unwind
END_FUNC raise_type_error_with_name

;; ============================================================================
;; raise_type_error_with_typename(rdi = a message with one \x01, rsi = a type)
;;   -> does not return: set_type_error_with_typename, then the unwind
;; ============================================================================
DEF_FUNC raise_type_error_with_typename
    call set_type_error_with_typename
    leave
    jmp eval_exception_unwind
END_FUNC raise_type_error_with_typename

;; ============================================================================
;; raise_binop_type_error(set_binop_type_error's arguments)
;;   -> does not return: the twin, then the unwind
;; ============================================================================
DEF_FUNC raise_binop_type_error
    call set_binop_type_error
    leave
    jmp eval_exception_unwind
END_FUNC raise_binop_type_error

;; ============================================================================
;; raise_binop_type_error_ex(set_binop_type_error_ex's arguments)
;;   -> does not return: the twin, then the unwind
;; ============================================================================
DEF_FUNC raise_binop_type_error_ex
    call set_binop_type_error_ex
    leave
    jmp eval_exception_unwind
END_FUNC raise_binop_type_error_ex

;; ============================================================================
;; raise_typed_message(set_typed_message's arguments)
;;   -> does not return: the twin, then the unwind
;; ============================================================================
DEF_FUNC raise_typed_message
    call set_typed_message
    leave
    jmp eval_exception_unwind
END_FUNC raise_typed_message

;; ============================================================================
;; raise_callable_arg(set_callable_arg's arguments)
;;   -> does not return: the twin, then the unwind
;; ============================================================================
DEF_FUNC raise_callable_arg
    call set_callable_arg
    leave
    jmp eval_exception_unwind
END_FUNC raise_callable_arg

;; ============================================================================
;; raise_no_attribute(rdi = the object as a Value, rsi = the attribute name,
;;                    edx = 1 for a store or a delete, 0 for a read)
;;   -> does not return: set_attribute_error, then the unwind
;;
;; The AttributeError a failed LOAD_ATTR ends in, or the one a __getattr__
;; hook already raised, completed.
;; ============================================================================
DEF_FUNC raise_no_attribute
    call set_attribute_error
    leave
    jmp eval_exception_unwind
END_FUNC raise_no_attribute

;; ============================================================================
;; exc_raise_import(exc_set_import's arguments)
;;   -> does not return: the twin, then the unwind
;; ============================================================================
DEF_FUNC exc_raise_import
    call exc_set_import
    leave
    jmp eval_exception_unwind
END_FUNC exc_raise_import
