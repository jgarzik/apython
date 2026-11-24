; shutdown.asm - what the interpreter does on its way out, before it starts
; taking itself apart.
;
; CPython's Py_FinalizeEx begins with two calls into Python, in this order:
; threading._shutdown(), which waits for every non-daemon thread to finish,
; and atexit's callbacks.  Both run while the interpreter is still whole.
; Then finalization proper starts, and from that moment no other thread may
; run Python again: gil_finalizing makes the main thread keep the GIL for
; good and parks anyone else who asks for it (src/gil.asm).
;
; Neither module is imported for the purpose.  A program that never imported
; threading has no threads to wait for, and one that never imported atexit
; registered nothing.

%include "macros.inc"
%include "object.inc"
%include "threadstate.inc"

ASM_INIT

extern sys_modules_dict
extern module_type
extern dict_get
extern str_from_cstr_heap
extern obj_decref
extern obj_dealloc
extern obj_call_n
extern traceback_print
extern fileobj_flush_std
extern gil_finalizing

section .text

;; ============================================================================
;; shutdown_call(rdi = module name, rsi = function name) -> nothing
;;
;; If sys.modules holds a module of that name with that function, call it
;; with no arguments.  An exception it lets out is reported and dropped:
;; there is nothing above this to propagate to.
;; ============================================================================
SC_FN    equ 8                  ; the function name, then the function
SC_NAME  equ 16                 ; a name str being looked up
SC_MOD   equ 24                 ; the module, borrowed
SC_FRAME equ 32                 ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL shutdown_call, SC_FRAME
    mov [rbp - SC_FN], rsi
    call str_from_cstr_heap
    mov [rbp - SC_NAME], rax
    xor eax, eax
    mov rdi, [rel sys_modules_dict]
    test rdi, rdi
    jz .sc_have_mod
    mov rsi, [rbp - SC_NAME]
    call dict_get               ; borrowed
.sc_have_mod:
    mov [rbp - SC_MOD], rax
    mov rdi, [rbp - SC_NAME]
    call obj_decref

    mov rax, [rbp - SC_MOD]
    test rax, rax
    jz .sc_out
    V_TEST_PTR rax, rcx
    ja .sc_out
    lea rcx, [rel module_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .sc_out                 ; sys.modules may hold anything

    mov rdi, [rbp - SC_FN]
    call str_from_cstr_heap
    mov [rbp - SC_NAME], rax
    mov rdi, [rbp - SC_MOD]
    mov rdi, [rdi + PyModuleObject.mod_dict]
    mov rsi, rax
    call dict_get               ; borrowed
    INCREF_V rax, rcx
    mov [rbp - SC_FN], rax
    mov rdi, [rbp - SC_NAME]
    call obj_decref
    cmp qword [rbp - SC_FN], 0
    je .sc_out

    mov rdi, [rbp - SC_FN]
    xor esi, esi
    xor edx, edx
    call obj_call_n
    mov [rbp - SC_NAME], rax    ; the result, or NULL
    mov rdi, [rbp - SC_FN]
    DECREF_V rdi, rcx
    mov rdi, [rbp - SC_NAME]
    test rdi, rdi
    jz .sc_raised
    DECREF_V rdi, rcx
    jmp .sc_out

.sc_raised:
    cmp qword [gs:ThreadState.current_exception], 0
    je .sc_out
    call fileobj_flush_std
    mov rdi, [gs:ThreadState.current_exception]
    call traceback_print
    mov rdi, [gs:ThreadState.current_exception]
    mov qword [gs:ThreadState.current_exception], 0
    call obj_decref
.sc_out:
    leave
    ret
END_FUNC shutdown_call

;; ============================================================================
;; interp_shutdown() -> nothing
;;
;; Wait for the non-daemon threads, run the atexit callbacks, then close the
;; GIL to every thread but this one.  Called once, by main, before
;; finalization begins.
;; ============================================================================
global interp_shutdown
DEF_FUNC interp_shutdown
    lea rdi, [rel sd_threading]
    lea rsi, [rel sd_shutdown]
    call shutdown_call
    lea rdi, [rel sd_atexit]
    lea rsi, [rel sd_run_exitfuncs]
    call shutdown_call
    mov qword [rel gil_finalizing], 1
    leave
    ret
END_FUNC interp_shutdown

section .rodata
sd_threading:     db "threading", 0
sd_shutdown:      db "_shutdown", 0
sd_atexit:        db "atexit", 0
sd_run_exitfuncs: db "_run_exitfuncs", 0
