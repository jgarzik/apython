; asyncio_future.asm - publish a Future's terminal state before Python re-entry.
;
; The Future facade owns the state record, which is a fixed-length list so the
; ordinary GC and heap-type subclass paths traverse it. The transition holds
; the GIL and installs every field before releasing any displaced references.

%include "macros.inc"
%include "object.inc"
%include "value.inc"

extern bool_false
extern bool_true
extern builtin_func_new
extern list_type
extern obj_dealloc
extern obj_decref
extern set_exception
extern str_from_cstr_heap

extern exc_TypeError_type

AF_STATE        equ 0
AF_RESULT       equ 1
AF_EXCEPTION    equ 2
AF_TRACEBACK    equ 3
AF_CANCEL       equ 4
AF_LOG          equ 5
AF_RECORD_SIZE  equ 6

AF_SET_RESULT   equ 0
AF_SET_ERROR    equ 1
AF_CANCEL_STATE equ 2

section .text

;; async_future_init(r12 = private module dictionary) -> void
DEF_FUNC async_future_init
    MODULE_ADD_FUNC async_future_transition, async_future_transition_name
    leave
    ret
END_FUNC async_future_init

;; async_future_transition(args, nargs) -> True if a pending Future settled
;; Fails: 0
;; args are the state record, operation, value and an optional traceback
;; carried as None when absent.
AFT_OLD_VALUE equ 8
AFT_OLD_TB    equ 16
AFT_OLD_LOG   equ 24
AFT_FRAME     equ 32
DEF_FUNC_LOCAL async_future_transition, AFT_FRAME
    cmp rsi, 4
    jne .bad_record
    mov r8, [rdi]
    V_TEST_PTR r8, rcx
    ja .bad_record
    test r8, r8
    jz .bad_record
    lea rcx, [rel list_type]
    cmp [r8 + PyObject.ob_type], rcx
    jne .bad_record
    cmp qword [r8 + PyListObject.ob_size], AF_RECORD_SIZE
    jne .bad_record
    mov r8, [r8 + PyListObject.ob_item]
    test r8, r8
    jz .bad_record
    mov rax, [rdi + 8]
    mov rcx, V_INT(0)
    sub rax, rcx
    cmp rax, AF_CANCEL_STATE
    ja .bad_record

    cmp [r8 + AF_STATE * 8], rcx
    je .settle
    cmp rax, AF_CANCEL_STATE
    jne .unchanged
    mov rdi, [r8 + AF_LOG * 8]
    mov [r8 + AF_LOG * 8], rcx
    DECREF_V rdi, rcx
.unchanged:
    RET_FALSE
    leave
    ret

.settle:
    mov r9, [rdi + 16]
    mov r11, [rdi + 24]
    mov qword [rbp - AFT_OLD_TB], 0
    mov qword [rbp - AFT_OLD_LOG], 0
    mov r10, V_INT(1)            ; FINISHED
    mov edx, AF_RESULT
    cmp eax, AF_SET_RESULT
    je .write_value
    mov edx, AF_EXCEPTION
    cmp eax, AF_SET_ERROR
    je .write_exception
    mov edx, AF_CANCEL
    mov r10, V_INT(2)            ; CANCELLED
    mov rax, [r8 + AF_LOG * 8]
    mov [rbp - AFT_OLD_LOG], rax
    mov rax, V_INT(0)
    mov [r8 + AF_LOG * 8], rax
    jmp .write_value
.write_exception:
    mov rcx, [r8 + AF_TRACEBACK * 8]
    mov [rbp - AFT_OLD_TB], rcx
    INCREF_V r11, rcx
    mov [r8 + AF_TRACEBACK * 8], r11
    mov rax, [r8 + AF_LOG * 8]
    mov [rbp - AFT_OLD_LOG], rax
    mov rax, V_INT(1)
    mov [r8 + AF_LOG * 8], rax
.write_value:
    mov rcx, [r8 + rdx * 8]
    mov [rbp - AFT_OLD_VALUE], rcx
    INCREF_V r9, rcx
    mov [r8 + rdx * 8], r9
    mov [r8 + AF_STATE * 8], r10
    mov rdi, [rbp - AFT_OLD_VALUE]
    XDECREF_V rdi, rcx
    mov rdi, [rbp - AFT_OLD_TB]
    XDECREF_V rdi, rcx
    mov rdi, [rbp - AFT_OLD_LOG]
    XDECREF_V rdi, rcx
    RET_TRUE
    leave
    ret

.bad_record:
    FAIL exc_TypeError_type, "invalid asyncio Future state record", .failed
.failed:
    xor eax, eax
    leave
    ret
END_FUNC async_future_transition

section .rodata
async_future_transition_name: db "_future_transition", 0
