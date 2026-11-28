; tracebackobj.asm - the traceback OBJECT: what `e.__traceback__` is
;
; Split out of exception.asm, which had grown past the 100k cap for a
; hand-written file.  The seam is the one that file already had: everything
; here is the type a traceback IS -- allocation, the three attributes a
; program reads off one, and the type object -- while raising, chaining and
; the exception hierarchy stay behind.  RENDERING a traceback is a third
; thing again and lives in src/traceback.asm, beside both of a code object's
; side tables.

%include "macros.inc"
%include "object.inc"
%include "value.inc"

ASM_INIT

extern ap_malloc
extern ap_free
extern obj_decref
extern obj_incref
extern int_from_i64
extern str_from_cstr
extern ap_strcmp
extern str_type
extern type_type
extern none_singleton
extern set_exception
extern exc_AttributeError_type
extern exc_TypeError_type
extern exc_ValueError_type
extern obj_dealloc

section .text

;; ============================================================================
;; Traceback support
;; ============================================================================

;; ============================================================================
;; traceback_new() -> PyTracebackObject*
;; Allocates a new traceback with tb_next=NULL, tb_lineno=0.
;; ============================================================================
DEF_FUNC traceback_new
    mov edi, PyTracebackObject_size
    call ap_malloc
    INIT_OBJ_RC rax
    lea rcx, [rel traceback_type]
    mov [rax + PyTracebackObject.ob_type], rcx
    mov qword [rax + PyTracebackObject.tb_next], 0
    mov qword [rax + PyTracebackObject.tb_lineno], 0
    mov qword [rax + PyTracebackObject.tb_code], 0
    mov qword [rax + PyTracebackObject.tb_lasti], 0
    leave
    ret
END_FUNC traceback_new

;; ============================================================================
;; traceback_dealloc(PyTracebackObject *tb) -> void
;; XDECREF tb_next, free self.
;; ============================================================================
DEF_FUNC traceback_dealloc
    push rbx
    push r12
    mov rbx, rdi
.td_node:
    ; Iterative, not recursive: a traceback chain is as deep as the call
    ; stack was, and freeing it recursively would overflow on exactly the
    ; deep-recursion case that produced it.
    mov rdi, [rbx + PyTracebackObject.tb_code]
    test rdi, rdi
    jz .td_no_code
    mov qword [rbx + PyTracebackObject.tb_code], 0
    call obj_decref
.td_no_code:
    mov r12, [rbx + PyTracebackObject.tb_next]
    mov rdi, rbx
    call ap_free
    test r12, r12
    jz .td_done
    mov rdi, r12
    extern obj_decref_no_dealloc
    call obj_decref_no_dealloc
    test eax, eax
    jnz .td_done                   ; still referenced elsewhere
    mov rbx, r12
    jmp .td_node
.td_done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC traceback_dealloc


;; ============================================================================
;; traceback_setattr(rdi = tb, rsi = name str, rdx = value Value, ecx = tag)
;;   -> rax = 0 on success; raises and does not return otherwise
;;
;; Only tb_next, and only a traceback or None -- which is all CPython's setter
;; accepts either.  unittest trims its own frames out of a failure's traceback
;; by walking to the last entry it wants and assigning None to that entry's
;; tb_next, so without this every assertion failure inside unittest reported
;; `AttributeError: cannot set attribute` instead of the failure.
;;
;; CPython also refuses a cycle (`tb.tb_next = tb` is a ValueError); so does
;; this, by walking the chain the new value would create.
;; ============================================================================
TBS_SELF  equ 8
TBS_NAME  equ 16
TBS_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC traceback_setattr, TBS_FRAME
    mov [rbp - TBS_SELF], rdi
    mov [rbp - TBS_NAME], rsi
    push rdx
    push rdx                    ; pad: ap_strcmp below is a call
    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "tb_next"
    call ap_strcmp
    pop rdx
    pop rdx
    test eax, eax
    jnz .tbs_no_attr

    lea rcx, [rel none_singleton]
    cmp rdx, rcx
    je .tbs_clear
    V_TEST_PTR rdx, rax
    ja .tbs_bad
    mov rax, [rdx + PyObject.ob_type]
    lea rcx, [rel traceback_type]
    cmp rax, rcx
    jne .tbs_bad

    ; A traceback that reaches itself would make the chain infinite, and every
    ; walker of it -- the renderer included -- would never stop.
    mov rcx, rdx
.tbs_cycle:
    test rcx, rcx
    jz .tbs_no_cycle
    cmp rcx, [rbp - TBS_SELF]
    je .tbs_loop
    mov rcx, [rcx + PyTracebackObject.tb_next]
    jmp .tbs_cycle
.tbs_no_cycle:
    mov rdi, rdx
    call obj_incref
    jmp .tbs_store
.tbs_clear:
    xor edx, edx
.tbs_store:
    mov rax, [rbp - TBS_SELF]
    mov rcx, [rax + PyTracebackObject.tb_next]
    mov [rax + PyTracebackObject.tb_next], rdx
    test rcx, rcx
    jz .tbs_done
    mov rdi, rcx
    call obj_decref
.tbs_done:
    xor eax, eax
    leave
    ret

.tbs_loop:
    FAIL exc_ValueError_type, "traceback loop detected", .tbs_fail
.tbs_bad:
    ; Name what was actually assigned.  The message was a fixed 'NoneType',
    ; which is the one value this arm cannot be reached with -- None is the
    ; legal way to clear tb_next, handled above.
    mov rsi, rdx
    CSTRING rdi, `expected traceback object, got '\x01'`
    extern set_type_error_with_name
    call set_type_error_with_name
    jmp .tbs_fail
.tbs_no_attr:
    ; CPython is not uniform here and this follows it exactly: tb_lineno has a
    ; setter that refuses, tb_frame and tb_lasti are plain members, and a name
    ; that is not an attribute at all is an ordinary AttributeError.
    mov rdi, [rbp - TBS_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "tb_lineno"
    call ap_strcmp
    test eax, eax
    jz .tbs_not_writable
    mov rdi, [rbp - TBS_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "tb_frame"
    call ap_strcmp
    test eax, eax
    jz .tbs_readonly
    mov rdi, [rbp - TBS_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "tb_lasti"
    call ap_strcmp
    test eax, eax
    jz .tbs_readonly
    mov rdi, [rbp - TBS_SELF]
    mov rsi, [rbp - TBS_NAME]
    extern set_no_attribute_store
    call set_no_attribute_store
    jmp .tbs_fail
.tbs_not_writable:
    FAIL exc_AttributeError_type, \
        "attribute 'tb_lineno' of 'traceback' objects is not writable", .tbs_fail
.tbs_readonly:
    SET_EXC exc_AttributeError_type, "readonly attribute"
.tbs_fail:
    mov rax, -1                 ; tp_setattr: -1 with the exception pending
    leave
    ret
END_FUNC traceback_setattr

;; ============================================================================
;; traceback_getattr(PyTracebackObject *tb, PyStrObject *name) -> (rax, edx)
;; Handles tb_lineno, tb_next, tb_frame attributes.
;; ============================================================================
DEF_FUNC traceback_getattr
    push rbx
    push r12

    mov rbx, rdi            ; tb
    mov r12, rsi            ; name str

    ; Check "tb_lineno"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "tb_lineno"
    call ap_strcmp
    test eax, eax
    jz .tb_get_lineno

    ; Check "tb_next"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "tb_next"
    call ap_strcmp
    test eax, eax
    jz .tb_get_next

    ; Check "tb_frame"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "tb_frame"
    call ap_strcmp
    test eax, eax
    jz .tb_get_frame

    ; Check "tb_lasti"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "tb_lasti"
    call ap_strcmp
    test eax, eax
    jz .tb_get_lasti

    ; Not found
    RET_NULL
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.tb_get_lineno:
    mov rax, [rbx + PyTracebackObject.tb_lineno]
    mov edx, TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.tb_get_next:
    mov rax, [rbx + PyTracebackObject.tb_next]
    test rax, rax
    jz .tb_return_none
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.tb_get_frame:
    ; A snapshot built from what the entry records.  This answered None, and
    ; CPython's traceback.py reads tb_frame.f_code on every entry -- so
    ; importing anything that formats a traceback died on the None.
    mov rdi, [rbx + PyTracebackObject.tb_code]
    mov rsi, [rbx + PyTracebackObject.tb_lineno]
    mov rdx, [rbx + PyTracebackObject.tb_lasti]
    extern frameobj_from_code
    call frameobj_from_code
    test rax, rax
    jz .tb_return_none
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.tb_get_lasti:
    ; Stored in code units, which is what the line and column tables are
    ; indexed by; CPython's attribute is a BYTE offset into co_code, and
    ; anything that indexes co_code with it -- dis, traceback -- reads it
    ; that way.
    mov rax, [rbx + PyTracebackObject.tb_lasti]
    add rax, rax
    mov edx, TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.tb_return_none:
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC traceback_getattr

section .data
; Traceback type object (immortal)
align 8
global traceback_type
traceback_type:
    dq 0x00000000FFFFFFFF       ; ob_ref_local=IMMORTAL, ob_ref_shared=0
    dq 0                        ; ob_tid=0 (immortal), ob_mutex=0
    dq type_type            ; ob_type
    dq tb_type_name         ; tp_name
    dq PyTracebackObject_size ; tp_basicsize
    dq traceback_dealloc    ; tp_dealloc
    dq 0                    ; tp_repr
    dq 0                    ; tp_str
    dq 0                    ; tp_hash
    dq 0                    ; tp_call
    dq traceback_getattr    ; tp_getattr
    dq traceback_setattr    ; tp_setattr
    dq 0                    ; tp_richcompare
    dq 0                    ; tp_iter
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq 0                    ; tp_new
    dq 0                    ; tp_as_number
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq 0                    ; tp_flags
    dq 0                    ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
tb_type_name: db "traceback", 0
