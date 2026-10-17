; eval.asm - Bytecode evaluation loop
; Core dispatch loop and opcode table for the Python 3.12 interpreter
; Includes exception unwind mechanism

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

; External opcode handlers (defined in opcodes_*.asm files)
extern eval_hook_mask
extern op_pop_top
extern op_push_null
extern op_return_value
extern op_return_const
extern op_load_const
extern op_load_fast
extern op_store_fast
extern op_load_global
extern op_load_global_module
extern op_load_global_builtin
extern op_load_attr_method
extern op_load_attr_instance
extern op_binary_op_and_int
extern op_binary_op_or_int
extern op_binary_op_xor_int
extern op_binary_op_mod_int
extern op_compare_op_float
extern op_compare_op_float_jump_false
extern op_compare_op_float_jump_true
extern op_load_name
extern op_store_name
extern op_store_global
extern op_binary_op
extern op_call
extern op_compare_op
extern op_pop_jump_if_false
extern op_pop_jump_if_true
extern op_jump_forward
extern op_jump_backward
extern op_copy
extern op_swap
extern op_unary_negative
extern op_unary_not
extern op_pop_jump_if_none
extern op_pop_jump_if_not_none
extern op_make_function
extern op_binary_subscr
extern op_store_subscr
extern op_build_tuple
extern op_build_list
extern op_build_map
extern op_build_const_key_map
extern op_unpack_sequence
extern op_get_iter
extern op_for_iter
extern op_end_for
extern op_list_append
extern op_list_extend
extern op_map_add
extern op_dict_update
extern op_dict_merge
extern op_unpack_ex
extern op_kw_names
extern op_is_op
extern op_contains_op
extern op_load_build_class
extern op_store_attr
extern op_load_attr
extern op_unary_invert
extern op_make_cell
extern op_load_closure
extern op_load_deref
extern op_store_deref
extern op_delete_deref
extern op_copy_free_vars
extern op_build_slice
extern op_binary_slice
extern op_store_slice
extern op_format_value
extern op_build_string
extern op_delete_fast
extern op_delete_name
extern op_delete_global
extern op_delete_attr
extern op_delete_subscr
extern op_load_fast_check
extern op_load_fast_and_clear
extern op_return_generator
extern op_yield_value
extern op_end_send
extern op_send
extern op_get_yield_from_iter
extern op_jump_backward_no_interrupt
extern op_call_intrinsic_1
extern op_call_function_ex
extern op_before_with
extern op_with_except_start
extern op_build_set
extern op_set_add
extern op_set_update
extern op_get_len
extern op_setup_annotations
extern op_load_locals
extern op_load_from_dict_or_globals
extern op_load_from_dict_or_deref
extern op_match_mapping
extern op_match_sequence
extern op_match_keys
extern op_match_class
extern op_call_intrinsic_2
extern op_load_super_attr
extern op_import_name
extern op_import_from
extern op_binary_subscr_list_int
extern op_unpack_sequence_tuple
extern op_store_attr_instance
extern op_store_attr_slot
extern op_call_py_exact
extern op_load_attr_property
extern op_unpack_sequence_list
extern op_binary_subscr_tuple_int
extern op_store_subscr_list_int
extern op_binary_op_add_int
extern op_binary_op_sub_int
extern op_compare_op_int
extern op_compare_op_int_jump_false
extern op_compare_op_int_jump_true
extern op_binary_op_add_float
extern op_binary_op_sub_float
extern op_binary_op_mul_float
extern op_binary_op_truediv_float
extern op_binary_op_mul_int
extern op_binary_op_floordiv_int
extern op_binary_op_lshift_int
extern op_binary_op_rshift_int
extern op_binary_op_pow_int
extern op_binary_op_truediv_int
extern op_binary_op_inplace_add_unicode
extern op_for_iter_list
extern op_for_iter_range

; Async opcode handlers
extern op_get_awaitable
extern op_get_aiter
extern op_get_anext
extern op_before_async_with
extern op_end_async_for
extern op_cleanup_throw

; External error handler
extern error_unimplemented_opcode

; Exception infrastructure
extern exc_table_find_handler
extern exc_isinstance
extern exc_new
extern exc_from_cstr
extern exc_set_context
extern obj_decref
extern obj_incref
extern obj_dealloc
extern sys_write
extern sys_exit
extern str_type
extern none_singleton

; Exception type singletons (for raising)
extern exc_TypeError_type
extern exc_ExceptionGroup_type

; ExceptionGroup support
extern eg_is_base_exception_group
extern eg_new
extern eg_split
extern tuple_new

; eval_frame(PyFrame *frame) -> PyObject*
; Main entry point: sets up registers from the frame and enters the dispatch loop.
; Returns NULL if an unhandled exception propagated out.
; rdi = frame
section .data
eval_no_frame_msg: db "exception raised outside the interpreter loop", 0
; The message above is 45 bytes, which left every counter below it at
; `addr % 8 == 6`: recursion_depth's per-call `inc qword` was a misaligned
; read-modify-write and c_recursion_depth straddled a cache line.  Costs
; nothing to say so.
align 8
global recursion_limit
; recursion_depth and c_recursion_depth are per thread, in ThreadState; the
; LIMIT is the interpreter's, as CPython's is.  c_recursion_depth is the depth
; of C-level container recursion -- comparing or hashing a structure that
; reaches itself.  Separate from recursion_depth because a non-local exit
; discards those C frames without unwinding them, so it is reset by
; eval_exception_unwind rather than balanced, exactly as repr_depth is.
; CPython's default.  apython's frames are cheaper -- about 320 machine-stack
; bytes each against an 8 MB rlimit -- but matching CPython is what programs
; and tests expect, and sys.setrecursionlimit() can raise it.
recursion_limit: dq 1000
extern op_push_exc_info
extern op_pop_except
extern op_check_exc_match
extern op_check_eg_match
extern op_raise_varargs
extern op_reraise

extern fatal_error

section .text

DEF_FUNC eval_frame
    SAVE_EVAL_REGS
    mov r15, [gs:ThreadState.ts_self]   ; one gs load; the rest are base+disp

    ; r12 = frame
    mov r12, rdi

    ; Load code object from frame
    mov rax, [r12 + PyFrame.code]

    ; Check for generator resume (instr_ptr != 0 means resume)
    mov rbx, [r12 + PyFrame.instr_ptr]
    test rbx, rbx
    jnz .eval_resume

    ; Normal entry: start from co_code beginning
    lea rbx, [rax + PyCodeObject.co_code]
    mov r13, [r12 + PyFrame.stack_base]
    jmp .eval_setup_consts

.eval_resume:
    ; Generator resume: use saved IP and stack pointer
    mov r13, [r12 + PyFrame.stack_ptr]

.eval_setup_consts:
    ; Derive the co_consts / co_names item pointers
    mov r14, [rax + PyCodeObject.co_consts]
    mov r14, [r14 + PyTupleObject.ob_item]

    mov rcx, [rax + PyCodeObject.co_names]
    mov rcx, [rcx + PyTupleObject.ob_item]

    ; Save caller's eval globals (for nested eval_frame calls).  The caller's
    ; IP and stack top need no saving: DISPATCH published them into the
    ; caller's own frame (PyFrame.disp_ip / .disp_sp), which this frame does
    ; not touch.
    mov rax, [r15 + ThreadState.eval_saved_r12]
    push rax
    mov rax, [r15 + ThreadState.eval_co_names]
    push rax
    mov rax, [r15 + ThreadState.eval_co_consts]
    push rax
    mov rax, [r15 + ThreadState.eval_base_rsp]
    push rax
    ; The CALL_FUNCTION_EX cleanup registrations belong to whichever frame is
    ; running.  There is one global for each, and a raise inside a *nested*
    ; frame unwinds only to that frame -- leaving the outer opcode's C frame
    ; alive, so the unwinder freed a buffer the outer opcode then freed
    ; again.  Scope them the way the other eval globals are scoped.
    mov rax, [r15 + ThreadState.cfex_temp_pending]
    push rax
    mov rax, [r15 + ThreadState.cfex_merged_pending]
    push rax
    mov rax, [r15 + ThreadState.cfex_kwnames_pending]
    push rax
    ; build_class_pending is the same kind of registration, and was the one
    ; left unscoped.  type_from_parts records the half-built class in it so
    ; that a raise which longjmps past its C frame can still release it --
    ; and a raise inside a NESTED frame unwinds only to that frame, leaving
    ; the construction's C frame alive.  Dropping a generator that never ran
    ; to exhaustion is exactly such a raise: closing one throws GeneratorExit
    ; in, which runs a frame of its own and unwinds out of it.  So a class
    ; whose parent's __init_subclass__ abandoned a generator came out of
    ; construction with a refcount one short.
    mov rax, [r15 + ThreadState.build_class_pending]
    push rax
    ; One pad, because the push list has to stay even: everything below it
    ; would otherwise make its calls 8 bytes out of alignment.  eval_return
    ; also uses the slot, to carry an exception past the restore that has to
    ; be released after it rather than during it.
    sub rsp, 8
    mov qword [r15 + ThreadState.cfex_temp_pending], 0
    mov qword [r15 + ThreadState.cfex_merged_pending], 0
    mov qword [r15 + ThreadState.cfex_kwnames_pending], 0
    mov qword [r15 + ThreadState.build_class_pending], 0

    ; KW_NAMES is per-call-site state: it names the keywords of the ONE call
    ; that follows it, and the callee is meant to consume it.  A builtin that
    ; ignores it leaves it set -- and __import__ runs a whole module body
    ; before returning, so the first class statement in that module read the
    ; importer's `fromlist=`/`level=` as its own class keywords and raised
    ; "__init_subclass__() takes no keyword arguments" from a module with no
    ; keyword arguments in it anywhere.  Scope it to the frame, as the cfex
    ; globals above are.  The tuple is borrowed from co_consts, so no
    ; refcounting.
    mov rax, [r15 + ThreadState.kw_names_pending]
    push rax
    mov qword [r15 + ThreadState.kw_names_pending], 0

    ; The exception being HANDLED is scoped to the frame as well, and takes
    ; the slot the alignment pad used to occupy, so the push list stays even.
    ;
    ; Two rules, and both are CPython's.  A frame that is handling nothing
    ; SHARES its caller's, which is what makes `except E: f()` give a raise
    ; inside f a __context__ of E -- CPython reaches the same answer by
    ; walking previous_item until it finds one that is set.  A frame that has
    ; its own -- only a generator or coroutine can, by suspending inside an
    ; except block -- swaps it in here and back out in eval_return.
    ;
    ; Which of the two it is, is PyFrame.exc_depth: the number of
    ; PUSH_EXC_INFOs this frame has run and not popped.  Answering it from
    ; the global instead -- "did it change?" -- is wrong twice over: an
    ; except block that catches the object its caller is already handling
    ; does not change it, and a generator that pops one it pushed BEFORE the
    ; suspension leaves the global holding an exception that is nobody's.
    ;
    ; The references are moved rather than counted wherever a slot gives one
    ; up in the same breath as another takes it.  The one exception is the
    ; shared case, which counts -- the frame may hand the global's own
    ; reference to a PUSH_EXC_INFO of its own and then die without the
    ; matching POP_EXCEPT -- and eval_return gives that count back once the
    ; caller's state is whole again, never in the middle of restoring it.
    mov rax, [r12 + PyFrame.exc_state]
    test rax, rax
    jnz .ef_own_exc
    mov rax, [r15 + ThreadState.handled_exception]        ; shared: keep it, count it
    test rax, rax
    jz .ef_exc_pushed
    INCREF rax
    jmp .ef_exc_pushed
.ef_own_exc:
    mov qword [r12 + PyFrame.exc_state], 0
    mov r11, [r15 + ThreadState.handled_exception]        ; ours to hold for the duration
    mov [r15 + ThreadState.handled_exception], rax        ; the frame's reference moves in
    mov rax, r11
.ef_exc_pushed:
    push rax

    ; Set globals for this frame
    mov [r15 + ThreadState.eval_co_consts], r14
    mov [r15 + ThreadState.eval_co_names], rcx

    ; Set up for this frame.  The frame that was current until now is this
    ; one's caller, and linking them is what gives sys._getframe an f_back to
    ; walk: nothing else maintained the chain, and PyFrame.prev_frame was
    ; written once, as zero, and never read.  eval_return restores the global
    ; from its own stack, so the links stay consistent as frames unwind.
    mov rax, [r15 + ThreadState.eval_saved_r12]
    mov [r12 + PyFrame.prev_frame], rax
    ; Where the caller was when it made this call needs no recording: its
    ; last DISPATCH left it in the caller's PyFrame.disp_ip, which is what
    ; sys._getframe(1).f_lineno reads for a frame that is not the one running.
    mov [r15 + ThreadState.eval_saved_r12], r12
    ; Save machine stack pointer for exception unwind cleanup
    mov [r15 + ThreadState.eval_base_rsp], rsp

    ; Recursion guard.  A Python-level call costs about 320 bytes of machine
    ; stack across op_call, func_call and eval_frame, so the 8 MB default ran
    ; out at roughly 25 000 frames -- as a bare SIGSEGV, with no
    ; RecursionError and no message.  The counter is incremented here, once
    ; the frame's globals and eval_base_rsp are in place so the raise unwinds
    ; through this frame, and decremented in eval_return, which is the only
    ; exit (.no_handler jumps there too).
    inc qword [r15 + ThreadState.recursion_depth]
    mov rax, [r15 + ThreadState.recursion_depth]
    cmp rax, [rel recursion_limit]
    jg .eval_recursion_error

    ; Check for pending throw (set by gen_throw before resume)
    mov [r12 + PyFrame.disp_ip], rbx
    mov [r12 + PyFrame.disp_sp], r13
    cmp byte [r15 + ThreadState.throw_pending], 0
    je .no_throw

.throw_resume:
    mov byte [r15 + ThreadState.throw_pending], 0
    jmp eval_exception_unwind

.eval_recursion_error:
    ; Out of line: this must not sit between the throw_pending test and
    ; .throw_resume, or every generator throw falls into it.
    mov [r12 + PyFrame.disp_ip], rbx
    mov [r12 + PyFrame.disp_sp], r13
    ; CPython refuses the call before the frame exists, so its traceback ends
    ; at the caller.  This frame is already up; keep it out of the report.
    mov byte [r15 + ThreadState.tb_suppress_frame], 1
    RAISE exc_RecursionError_type, "maximum recursion depth exceeded"

.trace_call_raised:
    ; A trace function that raised on the way into the frame.  The exception
    ; is pending; unwind from here, which is what the frame's own raise would
    ; have done.  Out of line, so it is not in the fall-through to dispatch.
    mov [r12 + PyFrame.disp_ip], rbx
    mov [r12 + PyFrame.disp_sp], r13
    jmp eval_exception_unwind

.no_throw:
    ; The 'call' event.  Here rather than earlier because the frame's globals
    ; and eval_base_rsp are in place by now, so a raise from the trace
    ; function unwinds through this frame and sys._getframe() inside the
    ; tracer sees it.  systrace_call is a load and a branch when nothing is
    ; set.
    cmp qword [r15 + ThreadState.systrace_any], 0
    je .no_trace_call
    extern systrace_call
    call systrace_call
    test eax, eax
    js .trace_call_raised
.no_trace_call:
    ; Fall through to eval_dispatch
END_FUNC eval_frame

;; ============================================================================
;; eval_dispatch - Main dispatch point
;; Reads the next opcode and arg, advances rbx, and jumps to the handler.
;; ============================================================================
align 16
DEF_FUNC_BARE eval_dispatch
    DISPATCH
END_FUNC eval_dispatch

;; ============================================================================
;; eval_hook_thunk - reached in place of every real handler while a hook is on
;;
;; opcode_trace_table has all 256 entries pointing here, so an interpreter-wide
;; hook costs one store to opcode_dispatch_table and NOTHING at all when it is
;; off: DISPATCH already loads through that pointer, at all 222 of its
;; expansions, and has since `-t` needed somewhere to interpose.  A
;; `cmp [rel tracing]` inside DISPATCH would have added a second conditional
;; branch at every one of those sites, against a design that spends a BTB
;; entry per site on the indirect jump precisely so each predicts its own
;; successor.
;;
;; Two independent reasons to be here -- `-t` printing opcodes and
;; sys.settrace wanting line events -- so eval_hook_mask says which, and both
;; run when both are on.  rax holds the opcode and ecx the argument, exactly
;; as the real handler expects them.
;; ============================================================================
DEF_FUNC_BARE eval_hook_thunk
    push rax
    push rcx                    ; two pushes: rsp keeps whatever alignment it had
    test qword [rel eval_hook_mask], 1
    jz .eht_no_print
    mov edi, eax
    mov esi, ecx
    call trace_print_opcode
.eht_no_print:
    test qword [rel eval_hook_mask], 2
    jz .eht_done
    ; rbx already points PAST the instruction word; systrace_line backs up.
    mov rdi, rbx
    extern systrace_line
    call systrace_line
.eht_done:
    pop rcx
    pop rax
    lea rdx, [rel opcode_table]
    jmp [rdx + rax*8]
END_FUNC eval_hook_thunk

;; ============================================================================
;; eval_return - Return from eval_frame
;; rax contains the return value. Restores callee-saved regs and returns.
;; ============================================================================
DEF_FUNC_BARE eval_return
    mov r15, [gs:ThreadState.ts_self]   ; one gs load; the rest are base+disp
    dec qword [r15 + ThreadState.recursion_depth]

    ; The 'return' event.  This is the single exit -- op_return_value,
    ; op_yield_value, op_interpreter_exit and the unwinder's .no_handler all
    ; arrive here -- so one hook covers CPython's PY_RETURN, PY_YIELD and
    ; PY_UNWIND, which its legacy layer maps to 'return' anyway.  rax says
    ; which: a value means a return or a yield, 0 means the frame is
    ; unwinding and CPython reports None.
    ;
    ; It has to run BEFORE the pop chain below, and rax and rdx are the return
    ; value, so both are saved across it.
    cmp qword [r15 + ThreadState.systrace_any], 0
    je .er_no_trace
    push rax
    push rdx
    mov rdi, rax
    extern systrace_return
    call systrace_return
    pop rdx
    pop rax
.er_no_trace:
    ; Restore caller's eval globals (reverse of save order)
    ; Use rcx as scratch — rdx holds return tag (fat value protocol)

    ; The handled exception: the caller's goes back into the global, and the
    ; frame keeps what was there only if it has an except block still open --
    ; PyFrame.exc_depth non-zero.  A generator picks that up again on its
    ; next resume, and if it is never resumed frame_free releases it.
    ;
    ; Keeping it unconditionally was wrong, and quietly: a generator first
    ; advanced from inside an `except` block was handling nothing of its own,
    ; but took a copy of its caller's on the way out and re-installed it on
    ; every later resume.  sys.exc_info() answered ValueError long after the
    ; except block that raised it had ended.
    ;
    ; r12 is the frame on all three ways in -- a return, a yield, and the
    ; unwinder's .no_handler, which restores it from eval_saved_r12 first.
    pop rcx
    mov r11, [r15 + ThreadState.handled_exception]
    mov [r15 + ThreadState.handled_exception], rcx
    mov qword [rsp + 8], 0      ; the pad, standing in for "nothing to release"
    cmp dword [r12 + PyFrame.exc_depth], 0
    jne .er_exc_own
    mov qword [r12 + PyFrame.exc_state], 0
    mov [rsp + 8], r11          ; the count this frame's entry took, given back
    jmp .er_exc_done            ; below, once the caller's state is whole
.er_exc_own:
    mov [r12 + PyFrame.exc_state], r11
.er_exc_done:

    pop rcx
    mov [r15 + ThreadState.kw_names_pending], rcx
    pop r11                     ; the pad: an exception to release, or 0
    pop rcx
    mov [r15 + ThreadState.build_class_pending], rcx
    pop rcx
    mov [r15 + ThreadState.cfex_kwnames_pending], rcx
    pop rcx
    mov [r15 + ThreadState.cfex_merged_pending], rcx
    pop rcx
    mov [r15 + ThreadState.cfex_temp_pending], rcx
    pop rcx
    mov [r15 + ThreadState.eval_base_rsp], rcx
    pop rcx
    mov [r15 + ThreadState.eval_co_consts], rcx
    pop rcx
    mov [r15 + ThreadState.eval_co_names], rcx
    pop rcx
    mov [r15 + ThreadState.eval_saved_r12], rcx

    ; How was this frame entered?  Asked HERE, while r12 is still the frame
    ; being left -- RESTORE_EVAL_REGS below makes it the caller's again.  A
    ; frame pushed inline by a bytecode handler has no return address to go
    ; back to; the handler left a resume label instead, and everything above
    ; has already put the caller's registers and globals back, so jumping to
    ; it lands exactly where a `ret` would have.
    ;
    ; r9 and r10 carry the two things the resume cannot recover for itself
    ; across RESTORE_EVAL_REGS.  Nothing is called between, so they survive.
    ; The compare happens before RESTORE_EVAL_REGS and the branch after it:
    ; `pop` does not touch the flags, so the answer survives the five of them.
    cmp dword [r12 + PyFrame.entry_kind], FRAME_ENTRY_CALL
    mov r9, r12                 ; the frame being left, for the resume to free
    RESTORE_EVAL_REGS
    jne .er_inline
    test r11, r11
    jnz .er_release
    pop rbp
    ret
.er_release:
    ; Everything is the caller's again -- rbx, r12, r13, the globals -- so a
    ; __del__ reached from this DECREF runs exactly where the caller's next
    ; opcode would.  Doing it any earlier would run it in a state that is
    ; neither frame's.  rax and rdx are the return value.
    push rax
    push rdx                    ; two pushes: rsp keeps its alignment
    mov rdi, r11
    call obj_decref
    pop rdx
    pop rax
    pop rbp
    ret

.er_inline:
    ; The caller is a bytecode handler, not C.  Undo the two words that stand
    ; where `call eval_frame` would have left rbp and a return address, and
    ; hand over: r9 = the frame just left, r11 = an exception whose release
    ; was deferred to the caller's position (or 0), rax:rdx = the returned
    ; Value, with rax 0 meaning the frame is unwinding.
    pop rbp
    add rsp, 8                  ; the poisoned return slot the handler pushed
    extern eval_inline_resume
    jmp eval_inline_resume
END_FUNC eval_return

;; ============================================================================
;; eval_inline_ret_bug() -> does not return
;;
;; The poisoned return address an inline frame carries.
;;
;; A frame pushed inline by a bytecode handler is left through .er_inline, not
;; through `ret`.  The word standing where a return address would be points
;; here, so that getting PyFrame.entry_kind wrong is a named death rather than
;; a jump into whatever the value stack happened to hold.  It also supplies
;; the stack parity a `call` would have: a handler is entered with rsp
;; 16-aligned and eval_frame's push list is counted from rsp being 8 past it.
;; ============================================================================
DEF_FUNC_BARE eval_inline_ret_bug
    lea rdi, [rel eval_inline_ret_msg]
    call fatal_error            ; does not return
END_FUNC eval_inline_ret_bug

section .rodata
eval_inline_ret_msg: db "eval_return: an inline frame returned through ret", 0
section .text

;; ============================================================================
;; trace_print_opcode - Print opcode name and arg to stderr
;; Called from eval_dispatch when tracing is enabled.
;; edi = opcode number, esi = arg value
;; ============================================================================
TP_OPCODE equ 8
TP_ARG    equ 16
TP_NAME   equ 24
TP_NL     equ 25            ; the digits are written backwards from here
TP_FRAME  equ 48            ; + 0 pushes = 48

DEF_FUNC trace_print_opcode, TP_FRAME
    mov dword [rbp - TP_OPCODE], edi
    mov dword [rbp - TP_ARG], esi

    ; Look up opcode name string
    lea rax, [rel opcode_names]
    movzx edi, dil
    mov rax, [rax + rdi*8]
    mov [rbp - TP_NAME], rax

    ; Write "  " prefix to stderr
    mov edi, 2
    lea rsi, [rel trace_prefix]
    mov edx, 2
    call sys_write

    ; Write opcode name (strlen + write)
    mov rsi, [rbp - TP_NAME]
    xor ecx, ecx
.strlen:
    cmp byte [rsi + rcx], 0
    je .strlen_done
    inc ecx
    jmp .strlen
.strlen_done:
    mov edx, ecx
    mov edi, 2
    call sys_write

    ; Write " " separator
    mov edi, 2
    lea rsi, [rel trace_space]
    mov edx, 1
    call sys_write

    ; Convert arg to decimal string + newline in frame buffer
    mov eax, dword [rbp - TP_ARG]
    lea rdi, [rbp - TP_NL]        ; newline position
    mov byte [rdi], 10

    test eax, eax
    jnz .convert
    dec rdi
    mov byte [rdi], '0'
    jmp .write_num
.convert:
    mov ecx, 10
.div_loop:
    xor edx, edx
    div ecx
    add dl, '0'
    dec rdi
    mov byte [rdi], dl
    test eax, eax
    jnz .div_loop
.write_num:
    lea rdx, [rbp - TP_NL + 1]    ; one past the newline
    sub rdx, rdi
    mov rsi, rdi
    mov edi, 2
    call sys_write

    leave
    ret
END_FUNC trace_print_opcode

;; ============================================================================
;; Exception unwind mechanism
;; ============================================================================

;; ============================================================================
;; eval_exception_unwind - Called when an exception is raised
;; The exception object must already be stored in [current_exception].
;; This routine searches the exception table for a handler. If found,
;; it adjusts the value stack and jumps to the handler. If not found,
;; it returns NULL from eval_frame to propagate to the caller.
;; ============================================================================
DEF_FUNC_BARE eval_exception_unwind
    ; eval_base_rsp lives in .bss, so it is 0 before the first eval_frame and
    ; again after the last one -- during startup, and during the shutdown
    ; DECREF cascade, which runs __del__.  Unwinding to it would be
    ; `mov rsp, 0`; there is genuinely nowhere to unwind to, so say so.
    cmp qword [gs:ThreadState.eval_base_rsp], 0
    je .no_interpreter_frame

    ; Restore machine stack to eval frame level (discard intermediate frames)
    mov rsp, [gs:ThreadState.eval_base_rsp]

    ; Clear stale kw_names_pending — the non-local jump from raise_exception
    ; bypasses CALL opcode cleanup, leaving kw_names_pending set.
    mov qword [gs:ThreadState.kw_names_pending], 0

    ; repr_depth is bracketed by repr_push/repr_pop around a container repr,
    ; and the pop is skipped by any raise from inside a nested __repr__.  It
    ; saturates at 64 and then every container repr in the process raises,
    ; and repr_stack keeps 64 dangling pointers that repr_check_active
    ; compares by address.
    mov qword [gs:ThreadState.repr_depth], 0
    mov qword [gs:ThreadState.c_recursion_depth], 0

    ; gc_collecting is set for the duration of a collection and cleared at
    ; the end.  A raise that escapes the collector -- one with no Python frame
    ; beneath it, which lands in an OUTER frame and so discards
    ; gc_collect_gen's -- would leave it set forever, after which the
    ; reentrancy guard makes the collector a permanent no-op and cyclic
    ; garbage accumulates silently.
    ;
    ; But clearing it unconditionally was worse.  A __del__ that raises and is
    ; merely reported unwinds only as far as the finalizer's OWN frame and
    ; returns to the collector, which is still walking lists anchored in its
    ; own stack frame -- with the guard now switched off behind it.  The
    ; finalizer's next allocation past the gen0 threshold, or its next
    ; gc.collect(), then started a second pass over those same lists, and the
    ; outer pass was left following links into a frame that had moved on.  It
    ; surfaced as a segfault in gc_list_remove, pages from anything at fault.
    ;
    ; The stack grows down, so the landing point tells the two apart exactly:
    ; below the collector's frame it survives, above it it is gone.
    mov rax, [gs:ThreadState.gc_collect_rsp]
    test rax, rax
    jz .gc_flag_done            ; no collection running; nothing to decide
    cmp rax, [gs:ThreadState.eval_base_rsp]
    ja .gc_flag_done            ; landing deeper: the collector is still there
    mov qword [rel gc_collecting], 0
    mov qword [gs:ThreadState.gc_collect_rsp], 0
.gc_flag_done:

    ; Free stale cfex_temp_pending buffer if set
    mov rdi, [gs:ThreadState.cfex_temp_pending]
    test rdi, rdi
    jz .no_cfex_temp
    mov qword [gs:ThreadState.cfex_temp_pending], 0
    extern gc_collecting
extern ap_free
extern exc_RecursionError_type
    call ap_free
.no_cfex_temp:

    ; Free stale cfex_merged_pending buffer if set
    mov rdi, [gs:ThreadState.cfex_merged_pending]
    test rdi, rdi
    jz .no_cfex_merged
    mov qword [gs:ThreadState.cfex_merged_pending], 0
    call ap_free
.no_cfex_merged:

    ; DECREF stale cfex_kwnames_pending tuple if set
    mov rdi, [gs:ThreadState.cfex_kwnames_pending]
    test rdi, rdi
    jz .no_cfex_kwnames
    mov qword [gs:ThreadState.cfex_kwnames_pending], 0
    extern obj_decref
    call obj_decref
.no_cfex_kwnames:

    ; DECREF stale build_class_pending type object if set
    mov rdi, [gs:ThreadState.build_class_pending]
    test rdi, rdi
    jz .no_build_class
    mov qword [gs:ThreadState.build_class_pending], 0
    call obj_decref
.no_build_class:

    ; Restore eval loop registers that may have been corrupted.
    ; When raise_exception is called from inside a function that saved/modified
    ; callee-saved regs (e.g. list_subscript saves rbx for temp use), the
    ; non-local jump to here bypasses the restore, leaving regs corrupted.
    ; rbx: use saved copy from eval_dispatch (pre-advance, points to instruction)
    ; r12: reload from frame pointer (saved in eval_frame_r12)
    mov r12, [gs:ThreadState.eval_saved_r12]   ; restore frame pointer
    mov rbx, [r12 + PyFrame.disp_ip]           ; restore bytecode IP (pre-advance copy)
    mov r13, [r12 + PyFrame.disp_sp]           ; restore value stack pointer

    ; Record this frame in the exception's traceback.  Every frame the
    ; exception passes through gets an entry, which is what makes a real
    ; "most recent call last" report possible; the old code attached one
    ; empty entry to the first frame and nothing after that.
    cmp byte [gs:ThreadState.tb_suppress_frame], 0
    je .tb_record
    mov byte [gs:ThreadState.tb_suppress_frame], 0
    jmp .skip_tb
.tb_record:
    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jz .skip_tb
    mov rsi, [r12 + PyFrame.code]
    test rsi, rsi
    jz .skip_tb
    mov rdi, rax
    lea rdx, [rsi + PyCodeObject.co_code]
    mov rcx, rbx                     ; pre-advance IP
    sub rcx, rdx
    sar rcx, 1                       ; code units
    mov rdx, rcx
    extern traceback_here
    call traceback_here
.skip_tb:

    ; The 'exception' event.  The unwinder is entered once per frame as an
    ; exception travels outward, which is where CPython raises it too, and by
    ; here rbx, r12 and r13 are the frame's own again.
    cmp qword [gs:ThreadState.systrace_any], 0
    je .no_trace_exc
    extern systrace_exception
    call systrace_exception
.no_trace_exc:

    ; Re-derive the co_consts / co_names globals from the code object
    mov rax, [r12 + PyFrame.code]
    mov rcx, [rax + PyCodeObject.co_consts]
    mov rcx, [rcx + PyTupleObject.ob_item]          ; consts payload array
    mov [gs:ThreadState.eval_co_consts], rcx
    mov rcx, [rax + PyCodeObject.co_names]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [gs:ThreadState.eval_co_names], rcx

    ; Compute bytecode offset in instruction units (halfwords)
    ; PyFrame.disp_ip points to the instruction word (before add rbx, 2)
    lea rcx, [rax + PyCodeObject.co_code]
    mov rdi, rax             ; rdi = code object for exc_table_find_handler
    mov rsi, rbx             ; rbx = saved pre-advance bytecode IP
    sub rsi, rcx             ; rsi = byte offset from co_code start
    shr esi, 1               ; rsi = offset in instruction units (halfwords)

    ; Call exc_table_find_handler(code, offset)
    ; Returns: rax = handler target (in halfwords), edx = depth, ecx = push_lasti
    ; Or rax = -1 if no handler
    call exc_table_find_handler

    cmp rax, -1
    je .no_handler

    ; Handler found!
    ; rax = handler target in instruction units
    ; edx = stack depth (number of items on value stack relative to stack_base)
    ; ecx = push_lasti flag

    ; Save handler info
    push rax                 ; save target
    push rcx                 ; save push_lasti flag

    ; Adjust value stack to target depth
    mov rdi, [r12 + PyFrame.stack_base]
    mov eax, edx
    lea rdi, [rdi + rax*8]              ; target stack ptr
    ; DECREF any items being popped from stack
    cmp r13, rdi
    jb .stack_below          ; shallower than the table says -- see below
    jbe .stack_adjusted
.pop_stack:
    sub r13, 8
    cmp r13, rdi
    jb .stack_adjusted
    push rdi                 ; save target stack ptr
    mov rdi, [r13]
    XDECREF_V rdi, rsi
    pop rdi
    cmp r13, rdi
    ja .pop_stack
.stack_adjusted:
    mov r13, rdi             ; set stack to target depth

    ; Check push_lasti flag
    pop rcx                  ; restore push_lasti
    pop rax                  ; restore target

    ; If push_lasti, push the instruction offset (as SmallInt)
    test ecx, ecx
    jz .no_lasti
    ; Push a dummy lasti value (we don't use it for now)
    xor edx, edx
    VPUSH_INT rdx, rsi
.no_lasti:

    ; Push the exception onto the value stack (transfer ownership)
    mov rdx, [gs:ThreadState.current_exception]
    mov qword [gs:ThreadState.current_exception], 0   ; clear: ownership moves to value stack
    VPUSH_PTR rdx

    ; Set rbx to handler target
    ; target is in instruction units (halfwords), so bytes = target * 2
    mov rcx, [r12 + PyFrame.code]
    lea rbx, [rcx + PyCodeObject.co_code]
    lea rbx, [rbx + rax*2]   ; target * 2 = byte offset

    DISPATCH

.stack_below:
    ; The stack is SHALLOWER than the depth the exception table names.  CPython
    ; asserts here (`STACK_LEVEL() >= level`, Python/ceval.c); this cannot
    ; assert, so it makes the recovery safe instead.
    ;
    ; The unconditional `mov r13, rdi` below raises the stack back to the
    ; table's depth, which re-exposes whatever words happen to sit between --
    ; a handler's dead operands, or nothing that was ever a Value.  The
    ; handler then reads them, and the next unwind DECREFs them.  Zeroing
    ; first makes them NULL, which every VPOP/XDECREF_V path already treats as
    ; empty, so a reachable-but-wrong depth degrades to a clean NULL rather
    ; than to a wild pointer.
    ;
    ; Reaching here at all means some handler published PyFrame.disp_sp below
    ; the depth its own instruction is covered at.  Nothing does today.
    mov rsi, r13
.sb_zero:
    cmp rsi, rdi
    jae .stack_adjusted
    mov qword [rsi], 0
    add rsi, 8
    jmp .sb_zero

.no_interpreter_frame:
    lea rdi, [rel eval_no_frame_msg]
    call fatal_error            ; does not return

.no_handler:
    ; No handler found - must clean up value stack before returning
    ; DECREF all items on value stack (from stack_base to r13)
    mov rdi, [r12 + PyFrame.stack_base]
.no_handler_cleanup:
    cmp r13, rdi
    jbe .no_handler_done
    sub r13, 8
    push rdi                 ; save stack_base
    mov rdi, [r13]
    XDECREF_V rdi, rsi
    pop rdi                  ; restore stack_base
    jmp .no_handler_cleanup
.no_handler_done:
    ; Clear instr_ptr so gen_throw/gen_send detect exhaustion
    mov qword [r12 + PyFrame.instr_ptr], 0
    xor eax, eax
    xor edx, edx              ; TAG_NULL for proper value return
    jmp eval_return
END_FUNC eval_exception_unwind

;; ============================================================================
;; exc_install(rdi = the new exception, an OWNED reference) -> void
;;
;; Chains __context__ and makes it the exception in flight.  The one place
;; that rule is written down; four call sites had a copy of it.
;;
;; The context is the exception being HANDLED, which is CPython's rule and is
;; why handled_exception exists as a word of its own.  It stays installed --
;; the `except` block it belongs to is still running and its POP_EXCEPT will
;; take it down -- so it is borrowed here, and exc_set_context takes the
;; reference it keeps.
;;
;; An exception already in flight is a different matter: it is being replaced,
;; so it is both the context and ours to release.  That happens when something
;; raises while the unwinder is running a finalizer, and nothing else.
;; ============================================================================
DEF_FUNC exc_install, 8            ; 1 pushes, so rsp is 16-aligned
    push rdi
    mov rsi, [gs:ThreadState.current_exception]
    test rsi, rsi
    jnz .ei_replace
    mov rsi, [gs:ThreadState.handled_exception]
    test rsi, rsi
    jz .ei_done
    call exc_set_context        ; rdi = new, rsi = context (borrowed)
    jmp .ei_done
.ei_replace:
    call exc_set_context
    mov rdi, [gs:ThreadState.current_exception]
    call obj_decref
.ei_done:
    pop rdi
    mov [gs:ThreadState.current_exception], rdi
    leave
    ret
END_FUNC exc_install

;; ============================================================================
;; raise_exception(PyTypeObject *type, const char *msg_cstr)
;; Create an exception from a C string and begin unwinding.
;; Callable from opcode handlers - uses eval loop registers.
;; set_exception(rdi = exception type, rsi = message C string)
;;
;; raise_exception's first half, without the unwind.  raise_exception tail-jumps
;; into eval_exception_unwind, which abandons the C stack -- so a helper that
;; holds an owned reference cannot raise and still release it, and every one
;; that tried leaked.  A helper whose contract already says "0 (or -1) with an
;; exception pending" uses this instead and returns normally, leaving the
;; unwinding to the interpreter frame that called it.
;; ============================================================================
DEF_FUNC set_exception
    call exc_from_cstr
    mov rdi, rax
    call exc_install
    leave
    ret
END_FUNC set_exception

DEF_FUNC raise_exception
    call exc_from_cstr
    mov rdi, rax
    call exc_install
    leave
    jmp eval_exception_unwind
END_FUNC raise_exception

;; ============================================================================
;; raise_exception_obj(PyExceptionObject *exc)
;; Set exception and begin unwinding.
;; Takes ownership of the exc reference (caller must pass an owned ref).
;; ============================================================================
DEF_FUNC raise_exception_obj
    call exc_install
    leave
    jmp eval_exception_unwind
END_FUNC raise_exception_obj







; op_unimplemented - Handler for unimplemented opcodes
; The opcode is in eax (set by dispatch). Calls fatal error.
op_unimplemented:
    ; eax still holds the opcode from dispatch
    ; but dispatch already jumped here, so we need the opcode
    ; Recalculate: rbx was advanced by 2, so opcode is at [rbx-2]
    movzx edi, byte [rbx-2]
    call error_unimplemented_opcode
    ; does not return

; op_cache - CACHE opcode (0): no-op, just dispatch next
op_cache:
    DISPATCH

; op_nop - NOP opcode (9): no-op, just dispatch next
op_nop:
    DISPATCH

; op_resume - RESUME opcode (151): no-op, just dispatch next
op_resume:
    DISPATCH

; op_interpreter_exit - INTERPRETER_EXIT opcode (3)
; Pop the return value from the value stack and return from eval_frame.
op_interpreter_exit:
    ; Check for unhandled exception
    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jnz .unhandled_exception
    VPOP rax                  ; the return Value
    jmp eval_return

.unhandled_exception:
    ; Print traceback and exit
    ; For now, print "Traceback (most recent call last):" and the exception
    push rbp
    mov rbp, rsp

    ; Print traceback header
    mov edi, 2
    lea rsi, [rel tb_header]
    mov edx, tb_header_len
    call sys_write

    ; Print "  File "<filename>", line N, in <name>\n"
    ; Get filename and function name from code object
    mov rax, [r12 + PyFrame.code]
    mov rdi, [rax + PyCodeObject.co_filename]
    test rdi, rdi
    jz .no_filename

    ; Print "  File \""
    push rax
    mov edi, 2
    lea rsi, [rel tb_file_prefix]
    mov edx, tb_file_prefix_len
    call sys_write
    pop rax

    ; Print filename
    push rax
    mov rdi, [rax + PyCodeObject.co_filename]
    mov esi, 2
    lea rdx, [rdi + PyStrObject.data]
    mov rcx, [rdi + PyStrObject.ob_size]
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, rcx
    call sys_write
    pop rax

    ; Print "\", line ???, in "
    push rax
    mov edi, 2
    lea rsi, [rel tb_line_prefix]
    mov edx, tb_line_prefix_len
    call sys_write
    pop rax

    ; Print function name
    mov rdi, [rax + PyCodeObject.co_name]
    test rdi, rdi
    jz .no_funcname
    push rax
    lea rsi, [rdi + PyStrObject.data]
    mov rdx, [rdi + PyStrObject.ob_size]
    mov edi, 2
    call sys_write
    pop rax
.no_funcname:
    ; Print newline
    mov edi, 2
    lea rsi, [rel tb_newline]
    mov edx, 1
    call sys_write

.no_filename:
    ; Print exception: "TypeName: message\n"
    mov rdi, [gs:ThreadState.current_exception]
    test rdi, rdi
    jz .exit_now

    ; Get type name
    mov rax, [rdi + PyExceptionObject.ob_type]
    mov rsi, [rax + PyTypeObject.tp_name]
    ; Print type name
    push rdi
    ; strlen of type name
    mov rdi, rsi
    xor ecx, ecx
.strlen1:
    cmp byte [rdi + rcx], 0
    je .strlen1_done
    inc ecx
    jmp .strlen1
.strlen1_done:
    mov edx, ecx
    mov edi, 2
    call sys_write
    pop rdi

    ; Check for message (must be a heap pointer to dereference)
    mov rax, [rdi + PyExceptionObject.exc_value]
    V_TEST_PTR rax, rcx
    ja .no_message

    ; Print ": "
    push rax
    mov edi, 2
    lea rsi, [rel tb_colon]
    mov edx, 2
    call sys_write
    pop rax

    ; Print message (must be a string)
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .no_message

    lea rsi, [rax + PyStrObject.data]
    mov rdx, [rax + PyStrObject.ob_size]
    mov edi, 2
    call sys_write

.no_message:
    ; Print final newline
    mov edi, 2
    lea rsi, [rel tb_newline]
    mov edx, 1
    call sys_write

.exit_now:
    ; Exit with code 1
    mov edi, 1
    call sys_exit

;; ============================================================================
;; op_extended_arg - Extend the arg of the NEXT instruction
;;
;; Shifts current arg left 8 bits, combines with next instruction's arg,
;; then dispatches next instruction with the combined arg.
;; Can chain: multiple EXTENDED_ARGs shift 8 more bits each time.
;; ============================================================================
op_extended_arg:
    shl ecx, 8                 ; shift current arg left 8
    movzx eax, byte [rbx]     ; next opcode
    movzx edx, byte [rbx+1]   ; next arg
    or ecx, edx               ; combine args
    add rbx, 2                 ; advance past next instruction
    mov rdx, [rel opcode_dispatch_table]
    jmp [rdx + rax*8]         ; dispatch with combined arg in ecx

;; ============================================================================
;; op_load_assertion_error - Push AssertionError type
;; ============================================================================
extern exc_AssertionError_type
op_load_assertion_error:
    lea rax, [rel exc_AssertionError_type]
    INCREF rax
    VPUSH_PTR rax
    DISPATCH

;; ============================================================================
;; Opcode dispatch table (256 entries, section .data for potential patching)
;; ============================================================================
section .data
align 8

; What DISPATCH jumps through.  Normally the real table; `-t` and
; sys.settrace point it at opcode_trace_table instead, which is how a hook
; reaches handlers that dispatch inline -- which is all of them.
; eval_hooks_set, in src/systrace.asm, is what writes here.
global opcode_dispatch_table
opcode_dispatch_table: dq opcode_table

; 256 identical entries: the thunk reads the opcode out of rax, so it does not
; need one entry per opcode to know which it is.
global opcode_trace_table
opcode_trace_table:
    times 256 dq eval_hook_thunk

global opcode_table
opcode_table:
    dq op_cache              ; 0   = CACHE
    dq op_pop_top            ; 1   = POP_TOP
    dq op_push_null          ; 2   = PUSH_NULL
    dq op_interpreter_exit   ; 3   = INTERPRETER_EXIT
    dq op_end_for            ; 4   = END_FOR
    dq op_end_send           ; 5   = END_SEND
    dq op_unimplemented      ; 6
    dq op_unimplemented      ; 7
    dq op_unimplemented      ; 8
    dq op_nop                ; 9   = NOP
    dq op_unimplemented      ; 10
    dq op_unary_negative     ; 11  = UNARY_NEGATIVE
    dq op_unary_not          ; 12  = UNARY_NOT
    dq op_unimplemented      ; 13
    dq op_unimplemented      ; 14
    dq op_unary_invert       ; 15  = UNARY_INVERT
    dq op_unimplemented      ; 16
    dq op_unimplemented      ; 17  = RESERVED
    dq op_unimplemented      ; 18
    dq op_unimplemented      ; 19
    dq op_unimplemented      ; 20
    dq op_unimplemented      ; 21
    dq op_unimplemented      ; 22
    dq op_unimplemented      ; 23
    dq op_unimplemented      ; 24
    dq op_binary_subscr      ; 25  = BINARY_SUBSCR
    dq op_binary_slice       ; 26  = BINARY_SLICE
    dq op_store_slice        ; 27  = STORE_SLICE
    dq op_unimplemented      ; 28
    dq op_unimplemented      ; 29
    dq op_get_len            ; 30  = GET_LEN
    dq op_match_mapping      ; 31  = MATCH_MAPPING
    dq op_match_sequence     ; 32  = MATCH_SEQUENCE
    dq op_match_keys         ; 33  = MATCH_KEYS
    dq op_unimplemented      ; 34
    dq op_push_exc_info      ; 35  = PUSH_EXC_INFO
    dq op_check_exc_match    ; 36  = CHECK_EXC_MATCH
    dq op_check_eg_match     ; 37  = CHECK_EG_MATCH
    dq op_unimplemented      ; 38
    dq op_unimplemented      ; 39
    dq op_unimplemented      ; 40
    dq op_unimplemented      ; 41
    dq op_unimplemented      ; 42
    dq op_unimplemented      ; 43
    dq op_unimplemented      ; 44
    dq op_unimplemented      ; 45
    dq op_unimplemented      ; 46
    dq op_unimplemented      ; 47
    dq op_unimplemented      ; 48
    dq op_with_except_start  ; 49  = WITH_EXCEPT_START
    dq op_get_aiter          ; 50  = GET_AITER
    dq op_get_anext          ; 51  = GET_ANEXT
    dq op_before_async_with  ; 52  = BEFORE_ASYNC_WITH
    dq op_before_with        ; 53  = BEFORE_WITH
    dq op_end_async_for      ; 54  = END_ASYNC_FOR
    dq op_cleanup_throw      ; 55  = CLEANUP_THROW
    dq op_unimplemented      ; 56
    dq op_unimplemented      ; 57
    dq op_unimplemented      ; 58
    dq op_unimplemented      ; 59
    dq op_store_subscr       ; 60  = STORE_SUBSCR
    dq op_delete_subscr      ; 61  = DELETE_SUBSCR
    dq op_unimplemented      ; 62
    dq op_unimplemented      ; 63
    dq op_unimplemented      ; 64
    dq op_unimplemented      ; 65
    dq op_unimplemented      ; 66
    dq op_unimplemented      ; 67
    dq op_get_iter           ; 68  = GET_ITER
    dq op_get_yield_from_iter ; 69  = GET_YIELD_FROM_ITER
    dq op_unimplemented      ; 70
    dq op_load_build_class   ; 71  = LOAD_BUILD_CLASS
    dq op_unimplemented      ; 72
    dq op_unimplemented      ; 73
    dq op_load_assertion_error ; 74  = LOAD_ASSERTION_ERROR
    dq op_return_generator   ; 75  = RETURN_GENERATOR
    dq op_unimplemented      ; 76
    dq op_unimplemented      ; 77
    dq op_unimplemented      ; 78
    dq op_unimplemented      ; 79
    dq op_unimplemented      ; 80
    dq op_unimplemented      ; 81
    dq op_unimplemented      ; 82
    dq op_return_value       ; 83  = RETURN_VALUE
    dq op_unimplemented      ; 84
    dq op_setup_annotations  ; 85  = SETUP_ANNOTATIONS
    dq op_unimplemented      ; 86
    dq op_load_locals        ; 87  = LOAD_LOCALS
    dq op_unimplemented      ; 88
    dq op_pop_except         ; 89  = POP_EXCEPT
    dq op_store_name         ; 90  = STORE_NAME
    dq op_delete_name        ; 91  = DELETE_NAME
    dq op_unpack_sequence    ; 92  = UNPACK_SEQUENCE
    dq op_for_iter           ; 93  = FOR_ITER
    dq op_unpack_ex          ; 94  = UNPACK_EX
    dq op_store_attr         ; 95  = STORE_ATTR
    dq op_delete_attr        ; 96  = DELETE_ATTR
    dq op_store_global       ; 97  = STORE_GLOBAL
    dq op_delete_global      ; 98  = DELETE_GLOBAL
    dq op_swap               ; 99  = SWAP
    dq op_load_const         ; 100 = LOAD_CONST
    dq op_load_name          ; 101 = LOAD_NAME
    dq op_build_tuple        ; 102 = BUILD_TUPLE
    dq op_build_list         ; 103 = BUILD_LIST
    dq op_build_set          ; 104 = BUILD_SET
    dq op_build_map          ; 105 = BUILD_MAP
    dq op_load_attr          ; 106 = LOAD_ATTR
    dq op_compare_op         ; 107 = COMPARE_OP
    dq op_import_name        ; 108 = IMPORT_NAME
    dq op_import_from        ; 109 = IMPORT_FROM
    dq op_jump_forward       ; 110 = JUMP_FORWARD
    dq op_unimplemented      ; 111
    dq op_unimplemented      ; 112
    dq op_unimplemented      ; 113
    dq op_pop_jump_if_false  ; 114 = POP_JUMP_IF_FALSE
    dq op_pop_jump_if_true   ; 115 = POP_JUMP_IF_TRUE
    dq op_load_global        ; 116 = LOAD_GLOBAL
    dq op_is_op              ; 117 = IS_OP
    dq op_contains_op        ; 118 = CONTAINS_OP
    dq op_reraise            ; 119 = RERAISE
    dq op_copy               ; 120 = COPY
    dq op_return_const       ; 121 = RETURN_CONST
    dq op_binary_op          ; 122 = BINARY_OP
    dq op_send               ; 123 = SEND
    dq op_load_fast          ; 124 = LOAD_FAST
    dq op_store_fast         ; 125 = STORE_FAST
    dq op_delete_fast        ; 126 = DELETE_FAST
    dq op_load_fast_check    ; 127 = LOAD_FAST_CHECK
    dq op_pop_jump_if_not_none ; 128 = POP_JUMP_IF_NOT_NONE
    dq op_pop_jump_if_none   ; 129 = POP_JUMP_IF_NONE
    dq op_raise_varargs      ; 130 = RAISE_VARARGS
    dq op_get_awaitable      ; 131 = GET_AWAITABLE
    dq op_make_function      ; 132 = MAKE_FUNCTION
    dq op_build_slice        ; 133 = BUILD_SLICE
    dq op_jump_backward_no_interrupt ; 134 = JUMP_BACKWARD_NO_INTERRUPT
    dq op_make_cell          ; 135 = MAKE_CELL
    dq op_load_closure       ; 136 = LOAD_CLOSURE
    dq op_load_deref         ; 137 = LOAD_DEREF
    dq op_store_deref        ; 138 = STORE_DEREF
    dq op_delete_deref       ; 139 = DELETE_DEREF
    dq op_jump_backward      ; 140 = JUMP_BACKWARD
    dq op_load_super_attr    ; 141 = LOAD_SUPER_ATTR
    dq op_call_function_ex   ; 142 = CALL_FUNCTION_EX
    dq op_load_fast_and_clear ; 143 = LOAD_FAST_AND_CLEAR
    dq op_extended_arg       ; 144 = EXTENDED_ARG
    dq op_list_append        ; 145 = LIST_APPEND
    dq op_set_add            ; 146 = SET_ADD
    dq op_map_add            ; 147 = MAP_ADD
    dq op_unimplemented      ; 148
    dq op_copy_free_vars     ; 149 = COPY_FREE_VARS
    dq op_yield_value        ; 150 = YIELD_VALUE
    dq op_resume             ; 151 = RESUME
    dq op_match_class        ; 152 = MATCH_CLASS
    dq op_unimplemented      ; 153
    dq op_unimplemented      ; 154
    dq op_format_value       ; 155 = FORMAT_VALUE
    dq op_build_const_key_map ; 156 = BUILD_CONST_KEY_MAP
    dq op_build_string       ; 157 = BUILD_STRING
    dq op_unimplemented      ; 158
    dq op_unimplemented      ; 159
    dq op_unimplemented      ; 160
    dq op_unimplemented      ; 161
    dq op_list_extend        ; 162 = LIST_EXTEND
    dq op_set_update         ; 163 = SET_UPDATE
    dq op_dict_merge         ; 164 = DICT_MERGE
    dq op_dict_update        ; 165 = DICT_UPDATE
    dq op_unimplemented      ; 166
    dq op_unimplemented      ; 167
    dq op_unimplemented      ; 168
    dq op_unimplemented      ; 169
    dq op_unimplemented      ; 170
    dq op_call               ; 171 = CALL
    dq op_kw_names           ; 172 = KW_NAMES
    dq op_call_intrinsic_1   ; 173 = CALL_INTRINSIC_1
    dq op_call_intrinsic_2   ; 174 = CALL_INTRINSIC_2
    dq op_load_from_dict_or_globals ; 175 = LOAD_FROM_DICT_OR_GLOBALS
    dq op_load_from_dict_or_deref ; 176 = LOAD_FROM_DICT_OR_DEREF
    dq op_unimplemented      ; 177
    dq op_unimplemented      ; 178
    dq op_unimplemented      ; 179
    dq op_unimplemented      ; 180
    dq op_unimplemented      ; 181
    dq op_unimplemented      ; 182
    dq op_unimplemented      ; 183
    dq op_unimplemented      ; 184
    dq op_unimplemented      ; 185
    dq op_unimplemented      ; 186
    dq op_unimplemented      ; 187
    dq op_unimplemented      ; 188
    dq op_unimplemented      ; 189
    dq op_unimplemented      ; 190
    dq op_unimplemented      ; 191
    dq op_unimplemented      ; 192
    dq op_unimplemented      ; 193
    dq op_unimplemented      ; 194
    dq op_unimplemented      ; 195
    dq op_unimplemented      ; 196
    dq op_unimplemented      ; 197
    dq op_unimplemented      ; 198
    dq op_unimplemented      ; 199
    dq op_load_global_module ; 200 = LOAD_GLOBAL_MODULE (IC)
    dq op_load_global_builtin ; 201 = LOAD_GLOBAL_BUILTIN (IC)
    dq op_unimplemented      ; 202
    dq op_load_attr_method   ; 203 = LOAD_ATTR_METHOD (IC)
    dq op_load_attr_instance ; 204 = LOAD_ATTR_INSTANCE (inline cache)
    dq op_unimplemented      ; 205
    dq op_unimplemented      ; 206
    dq op_unimplemented      ; 207
    dq op_unimplemented      ; 208
    dq op_compare_op_int     ; 209 = COMPARE_OP_INT (specialized)
    dq op_unimplemented      ; 210
    dq op_binary_op_add_int  ; 211 = BINARY_OP_ADD_INT (specialized)
    dq op_binary_op_sub_int  ; 212 = BINARY_OP_SUBTRACT_INT (specialized)
    dq op_for_iter_list      ; 213 = FOR_ITER_LIST (specialized)
    dq op_for_iter_range     ; 214 = FOR_ITER_RANGE (specialized)
    dq op_compare_op_int_jump_false ; 215 = COMPARE_OP_INT_JUMP_FALSE (superinstruction)
    dq op_compare_op_int_jump_true  ; 216 = COMPARE_OP_INT_JUMP_TRUE (superinstruction)
    dq op_binary_op_add_float    ; 217 = BINARY_OP_ADD_FLOAT (specialized)
    dq op_binary_op_sub_float    ; 218 = BINARY_OP_SUB_FLOAT (specialized)
    dq op_binary_op_mul_float    ; 219 = BINARY_OP_MUL_FLOAT (specialized)
    dq op_binary_op_truediv_float ; 220 = BINARY_OP_TRUEDIV_FLOAT (specialized)
    dq op_binary_op_mul_int      ; 221 = BINARY_OP_MULTIPLY_INT (specialized)
    dq op_binary_op_floordiv_int ; 222 = BINARY_OP_FLOORDIV_INT (specialized)
    dq op_compare_op_float   ; 223 = COMPARE_OP_FLOAT (IC)
    dq op_compare_op_float_jump_false ; 224 = fused with POP_JUMP_IF_FALSE
    dq op_compare_op_float_jump_true  ; 225 = fused with POP_JUMP_IF_TRUE
    dq op_binary_op_and_int  ; 226 = BINARY_OP_AND_INT (specialized)
    dq op_binary_op_or_int   ; 227 = BINARY_OP_OR_INT (specialized)
    dq op_binary_op_xor_int  ; 228 = BINARY_OP_XOR_INT (specialized)
    dq op_binary_op_mod_int  ; 229 = BINARY_OP_REMAINDER_INT (specialized)
    dq op_binary_op_lshift_int ; 230 = BINARY_OP_LSHIFT_INT (specialized)
    dq op_binary_op_rshift_int ; 231 = BINARY_OP_RSHIFT_INT (specialized)
    dq op_binary_op_pow_int  ; 232 = BINARY_OP_POWER_INT (specialized)
    dq op_binary_op_truediv_int ; 233 = BINARY_OP_TRUEDIV_INT (specialized)
    dq op_binary_op_inplace_add_unicode ; 234 = BINARY_OP_INPLACE_ADD_UNICODE
    dq op_binary_subscr_list_int ; 235
    dq op_binary_subscr_tuple_int ; 236
    dq op_store_subscr_list_int ; 237
    dq op_unpack_sequence_tuple ; 238
    dq op_unpack_sequence_list ; 239
    dq op_store_attr_instance ; 240
    dq op_call_py_exact     ; 241
    dq op_load_attr_property ; 242
    dq op_store_attr_slot   ; 243
    dq op_unimplemented      ; 244
    dq op_unimplemented      ; 245
    dq op_unimplemented      ; 246
    dq op_unimplemented      ; 247
    dq op_unimplemented      ; 248
    dq op_unimplemented      ; 249
    dq op_unimplemented      ; 250
    dq op_unimplemented      ; 251
    dq op_unimplemented      ; 252
    dq op_unimplemented      ; 253
    dq op_unimplemented      ; 254
    dq op_unimplemented      ; 255

;; ============================================================================
;; The main thread's ThreadState (src/include/threadstate.inc)
;; ============================================================================
;; Every per-thread word the interpreter keeps -- current_exception and
;; handled_exception, the registers DISPATCH publishes, the pending words, the
;; recursion counters -- lives in a ThreadState reached through gs.  This is
;; the main thread's, installed by tstate_install as the first thing main does.
;;
;; `align 64` because the first line of the struct is the eight words DISPATCH
;; and eval_frame/eval_return touch; the struct keeps its byte flags at the end
;; so no word after them is off 8-byte alignment.  That arrangement was learned
;; the hard way when these were loose .bss words: a lone `resb 1` in the middle
;; put eval_saved_r12 across a line on every Python call.
;;
;; The two exception words answer different questions.  current_exception is
;; the one IN FLIGHT; handled_exception is the one an `except` block is
;; HANDLING -- CPython's tstate->exc_info->exc_value, which sys.exc_info()
;; reads, a bare `raise` re-raises and an implicit __context__ chains to.  A
;; generator swaps its own in and out around each resume (PyFrame.exc_state).
section .bss
align 64
global main_tstate
main_tstate: resb ThreadState_size

section .text
;; ============================================================================
;; tstate_install(rdi = ThreadState*) -> nothing
;;
;; Point gs at a ThreadState and record its own address in ts_self.  The
;; raw syscall, not glibc's: arch_prctl has no wrapper worth the PLT, and
;; nothing here may touch a field before gs is set.  Failure is fatal --
;; every opcode writes through gs.
;; ============================================================================
ARCH_SET_GS     equ 0x1001
SYS_arch_prctl  equ 158
DEF_FUNC tstate_install
    push rdi
    sub rsp, 8
    mov rsi, rdi
    mov edi, ARCH_SET_GS
    mov eax, SYS_arch_prctl
    syscall
    add rsp, 8
    pop rdi
    test rax, rax
    jnz .ti_failed
    mov [gs:ThreadState.ts_self], rdi
    leave
    ret
.ti_failed:
    CSTRING rdi, "tstate_install: arch_prctl(ARCH_SET_GS) failed"
    call fatal_error
END_FUNC tstate_install

;; ============================================================================
;; Read-only data for traceback printing
;; ============================================================================
section .rodata
tb_header: db "Traceback (most recent call last):", 10
tb_header_len equ $ - tb_header

tb_file_prefix: db '  File "', 0
tb_file_prefix_len equ $ - tb_file_prefix - 1

tb_line_prefix: db '", line ?, in '
tb_line_prefix_len equ $ - tb_line_prefix

tb_colon: db ": "
tb_newline: db 10

;; ============================================================================
;; Trace output helper strings
;; ============================================================================
trace_prefix: db "  "
trace_space: db " "

;; ============================================================================
;; Opcode name strings
;; ============================================================================
opn_unknown: db "???", 0
opn_CACHE: db "CACHE", 0
opn_POP_TOP: db "POP_TOP", 0
opn_PUSH_NULL: db "PUSH_NULL", 0
opn_INTERPRETER_EXIT: db "INTERPRETER_EXIT", 0
opn_END_FOR: db "END_FOR", 0
opn_END_SEND: db "END_SEND", 0
opn_NOP: db "NOP", 0
opn_UNARY_NEGATIVE: db "UNARY_NEGATIVE", 0
opn_UNARY_NOT: db "UNARY_NOT", 0
opn_UNARY_INVERT: db "UNARY_INVERT", 0
opn_BINARY_SUBSCR: db "BINARY_SUBSCR", 0
opn_BINARY_SLICE: db "BINARY_SLICE", 0
opn_STORE_SLICE: db "STORE_SLICE", 0
opn_GET_LEN: db "GET_LEN", 0
opn_MATCH_MAPPING: db "MATCH_MAPPING", 0
opn_MATCH_SEQUENCE: db "MATCH_SEQUENCE", 0
opn_MATCH_KEYS: db "MATCH_KEYS", 0
opn_PUSH_EXC_INFO: db "PUSH_EXC_INFO", 0
opn_CHECK_EXC_MATCH: db "CHECK_EXC_MATCH", 0
opn_CHECK_EG_MATCH: db "CHECK_EG_MATCH", 0
opn_WITH_EXCEPT_START: db "WITH_EXCEPT_START", 0
opn_GET_AITER: db "GET_AITER", 0
opn_GET_ANEXT: db "GET_ANEXT", 0
opn_BEFORE_ASYNC_WITH: db "BEFORE_ASYNC_WITH", 0
opn_BEFORE_WITH: db "BEFORE_WITH", 0
opn_END_ASYNC_FOR: db "END_ASYNC_FOR", 0
opn_CLEANUP_THROW: db "CLEANUP_THROW", 0
opn_STORE_SUBSCR: db "STORE_SUBSCR", 0
opn_DELETE_SUBSCR: db "DELETE_SUBSCR", 0
opn_GET_ITER: db "GET_ITER", 0
opn_GET_YIELD_FROM_ITER: db "GET_YIELD_FROM_ITER", 0
opn_LOAD_BUILD_CLASS: db "LOAD_BUILD_CLASS", 0
opn_LOAD_ASSERTION_ERROR: db "LOAD_ASSERTION_ERROR", 0
opn_RETURN_GENERATOR: db "RETURN_GENERATOR", 0
opn_RETURN_VALUE: db "RETURN_VALUE", 0
opn_SETUP_ANNOTATIONS: db "SETUP_ANNOTATIONS", 0
opn_LOAD_LOCALS: db "LOAD_LOCALS", 0
opn_POP_EXCEPT: db "POP_EXCEPT", 0
opn_STORE_NAME: db "STORE_NAME", 0
opn_DELETE_NAME: db "DELETE_NAME", 0
opn_UNPACK_SEQUENCE: db "UNPACK_SEQUENCE", 0
opn_FOR_ITER: db "FOR_ITER", 0
opn_UNPACK_EX: db "UNPACK_EX", 0
opn_STORE_ATTR: db "STORE_ATTR", 0
opn_DELETE_ATTR: db "DELETE_ATTR", 0
opn_STORE_GLOBAL: db "STORE_GLOBAL", 0
opn_DELETE_GLOBAL: db "DELETE_GLOBAL", 0
opn_SWAP: db "SWAP", 0
opn_LOAD_CONST: db "LOAD_CONST", 0
opn_LOAD_NAME: db "LOAD_NAME", 0
opn_BUILD_TUPLE: db "BUILD_TUPLE", 0
opn_BUILD_LIST: db "BUILD_LIST", 0
opn_BUILD_SET: db "BUILD_SET", 0
opn_BUILD_MAP: db "BUILD_MAP", 0
opn_LOAD_ATTR: db "LOAD_ATTR", 0
opn_COMPARE_OP: db "COMPARE_OP", 0
opn_IMPORT_NAME: db "IMPORT_NAME", 0
opn_IMPORT_FROM: db "IMPORT_FROM", 0
opn_JUMP_FORWARD: db "JUMP_FORWARD", 0
opn_POP_JUMP_IF_FALSE: db "POP_JUMP_IF_FALSE", 0
opn_POP_JUMP_IF_TRUE: db "POP_JUMP_IF_TRUE", 0
opn_LOAD_GLOBAL: db "LOAD_GLOBAL", 0
opn_IS_OP: db "IS_OP", 0
opn_CONTAINS_OP: db "CONTAINS_OP", 0
opn_RERAISE: db "RERAISE", 0
opn_COPY: db "COPY", 0
opn_RETURN_CONST: db "RETURN_CONST", 0
opn_BINARY_OP: db "BINARY_OP", 0
opn_SEND: db "SEND", 0
opn_LOAD_FAST: db "LOAD_FAST", 0
opn_STORE_FAST: db "STORE_FAST", 0
opn_DELETE_FAST: db "DELETE_FAST", 0
opn_LOAD_FAST_CHECK: db "LOAD_FAST_CHECK", 0
opn_POP_JUMP_IF_NOT_NONE: db "POP_JUMP_IF_NOT_NONE", 0
opn_POP_JUMP_IF_NONE: db "POP_JUMP_IF_NONE", 0
opn_RAISE_VARARGS: db "RAISE_VARARGS", 0
opn_GET_AWAITABLE: db "GET_AWAITABLE", 0
opn_MAKE_FUNCTION: db "MAKE_FUNCTION", 0
opn_BUILD_SLICE: db "BUILD_SLICE", 0
opn_JUMP_BACKWARD_NO_INTERRUPT: db "JUMP_BACKWARD_NO_INTERRUPT", 0
opn_MAKE_CELL: db "MAKE_CELL", 0
opn_LOAD_CLOSURE: db "LOAD_CLOSURE", 0
opn_LOAD_DEREF: db "LOAD_DEREF", 0
opn_STORE_DEREF: db "STORE_DEREF", 0
opn_DELETE_DEREF: db "DELETE_DEREF", 0
opn_JUMP_BACKWARD: db "JUMP_BACKWARD", 0
opn_LOAD_SUPER_ATTR: db "LOAD_SUPER_ATTR", 0
opn_CALL_FUNCTION_EX: db "CALL_FUNCTION_EX", 0
opn_LOAD_FAST_AND_CLEAR: db "LOAD_FAST_AND_CLEAR", 0
opn_EXTENDED_ARG: db "EXTENDED_ARG", 0
opn_LIST_APPEND: db "LIST_APPEND", 0
opn_SET_ADD: db "SET_ADD", 0
opn_MAP_ADD: db "MAP_ADD", 0
opn_COPY_FREE_VARS: db "COPY_FREE_VARS", 0
opn_YIELD_VALUE: db "YIELD_VALUE", 0
opn_RESUME: db "RESUME", 0
opn_MATCH_CLASS: db "MATCH_CLASS", 0
opn_FORMAT_VALUE: db "FORMAT_VALUE", 0
opn_BUILD_CONST_KEY_MAP: db "BUILD_CONST_KEY_MAP", 0
opn_BUILD_STRING: db "BUILD_STRING", 0
opn_LIST_EXTEND: db "LIST_EXTEND", 0
opn_SET_UPDATE: db "SET_UPDATE", 0
opn_DICT_MERGE: db "DICT_MERGE", 0
opn_DICT_UPDATE: db "DICT_UPDATE", 0
opn_CALL: db "CALL", 0
opn_KW_NAMES: db "KW_NAMES", 0
opn_CALL_INTRINSIC_1: db "CALL_INTRINSIC_1", 0
opn_CALL_INTRINSIC_2: db "CALL_INTRINSIC_2", 0
opn_LOAD_FROM_DICT_OR_GLOBALS: db "LOAD_FROM_DICT_OR_GLOBALS", 0
opn_LOAD_FROM_DICT_OR_DEREF: db "LOAD_FROM_DICT_OR_DEREF", 0
opn_LOAD_GLOBAL_MODULE: db "LOAD_GLOBAL_MODULE", 0
opn_LOAD_GLOBAL_BUILTIN: db "LOAD_GLOBAL_BUILTIN", 0
opn_LOAD_ATTR_METHOD: db "LOAD_ATTR_METHOD", 0
opn_COMPARE_OP_INT: db "COMPARE_OP_INT", 0
opn_BINARY_OP_ADD_INT: db "BINARY_OP_ADD_INT", 0
opn_BINARY_OP_SUBTRACT_INT: db "BINARY_OP_SUBTRACT_INT", 0
opn_FOR_ITER_LIST: db "FOR_ITER_LIST", 0
opn_FOR_ITER_RANGE: db "FOR_ITER_RANGE", 0
opn_BINARY_SUBSCR_LIST_INT: db "BINARY_SUBSCR_LIST_INT", 0
opn_BINARY_SUBSCR_TUPLE_INT: db "BINARY_SUBSCR_TUPLE_INT", 0
opn_STORE_SUBSCR_LIST_INT: db "STORE_SUBSCR_LIST_INT", 0
opn_UNPACK_SEQUENCE_TUPLE: db "UNPACK_SEQUENCE_TUPLE", 0
opn_UNPACK_SEQUENCE_LIST: db "UNPACK_SEQUENCE_LIST", 0
opn_STORE_ATTR_INSTANCE: db "STORE_ATTR_INSTANCE", 0
opn_CALL_PY_EXACT: db "CALL_PY_EXACT", 0
opn_LOAD_ATTR_PROPERTY: db "LOAD_ATTR_PROPERTY", 0

;; ============================================================================
;; Opcode name lookup table (256 entries, in .data for relocations)
;; ============================================================================
section .data
align 8
global opcode_names
opcode_names:
    dq opn_CACHE                      ; 0
    dq opn_POP_TOP                    ; 1
    dq opn_PUSH_NULL                  ; 2
    dq opn_INTERPRETER_EXIT           ; 3
    dq opn_END_FOR                    ; 4
    dq opn_END_SEND                   ; 5
    dq opn_unknown                    ; 6
    dq opn_unknown                    ; 7
    dq opn_unknown                    ; 8
    dq opn_NOP                        ; 9
    dq opn_unknown                    ; 10
    dq opn_UNARY_NEGATIVE             ; 11
    dq opn_UNARY_NOT                  ; 12
    dq opn_unknown                    ; 13
    dq opn_unknown                    ; 14
    dq opn_UNARY_INVERT               ; 15
    dq opn_unknown                    ; 16
    dq opn_unknown                    ; 17
    dq opn_unknown                    ; 18
    dq opn_unknown                    ; 19
    dq opn_unknown                    ; 20
    dq opn_unknown                    ; 21
    dq opn_unknown                    ; 22
    dq opn_unknown                    ; 23
    dq opn_unknown                    ; 24
    dq opn_BINARY_SUBSCR              ; 25
    dq opn_BINARY_SLICE               ; 26
    dq opn_STORE_SLICE                ; 27
    dq opn_unknown                    ; 28
    dq opn_unknown                    ; 29
    dq opn_GET_LEN                    ; 30
    dq opn_MATCH_MAPPING              ; 31
    dq opn_MATCH_SEQUENCE             ; 32
    dq opn_MATCH_KEYS                 ; 33
    dq opn_unknown                    ; 34
    dq opn_PUSH_EXC_INFO              ; 35
    dq opn_CHECK_EXC_MATCH            ; 36
    dq opn_CHECK_EG_MATCH             ; 37
    dq opn_unknown                    ; 38
    dq opn_unknown                    ; 39
    dq opn_unknown                    ; 40
    dq opn_unknown                    ; 41
    dq opn_unknown                    ; 42
    dq opn_unknown                    ; 43
    dq opn_unknown                    ; 44
    dq opn_unknown                    ; 45
    dq opn_unknown                    ; 46
    dq opn_unknown                    ; 47
    dq opn_unknown                    ; 48
    dq opn_WITH_EXCEPT_START          ; 49
    dq opn_GET_AITER                  ; 50
    dq opn_GET_ANEXT                  ; 51
    dq opn_BEFORE_ASYNC_WITH          ; 52
    dq opn_BEFORE_WITH                ; 53
    dq opn_END_ASYNC_FOR              ; 54
    dq opn_CLEANUP_THROW              ; 55
    dq opn_unknown                    ; 56
    dq opn_unknown                    ; 57
    dq opn_unknown                    ; 58
    dq opn_unknown                    ; 59
    dq opn_STORE_SUBSCR               ; 60
    dq opn_DELETE_SUBSCR              ; 61
    dq opn_unknown                    ; 62
    dq opn_unknown                    ; 63
    dq opn_unknown                    ; 64
    dq opn_unknown                    ; 65
    dq opn_unknown                    ; 66
    dq opn_unknown                    ; 67
    dq opn_GET_ITER                   ; 68
    dq opn_GET_YIELD_FROM_ITER        ; 69
    dq opn_unknown                    ; 70
    dq opn_LOAD_BUILD_CLASS           ; 71
    dq opn_unknown                    ; 72
    dq opn_unknown                    ; 73
    dq opn_LOAD_ASSERTION_ERROR       ; 74
    dq opn_RETURN_GENERATOR           ; 75
    dq opn_unknown                    ; 76
    dq opn_unknown                    ; 77
    dq opn_unknown                    ; 78
    dq opn_unknown                    ; 79
    dq opn_unknown                    ; 80
    dq opn_unknown                    ; 81
    dq opn_unknown                    ; 82
    dq opn_RETURN_VALUE               ; 83
    dq opn_unknown                    ; 84
    dq opn_SETUP_ANNOTATIONS          ; 85
    dq opn_unknown                    ; 86
    dq opn_LOAD_LOCALS                ; 87
    dq opn_unknown                    ; 88
    dq opn_POP_EXCEPT                 ; 89
    dq opn_STORE_NAME                 ; 90
    dq opn_DELETE_NAME                ; 91
    dq opn_UNPACK_SEQUENCE            ; 92
    dq opn_FOR_ITER                   ; 93
    dq opn_UNPACK_EX                  ; 94
    dq opn_STORE_ATTR                 ; 95
    dq opn_DELETE_ATTR                ; 96
    dq opn_STORE_GLOBAL               ; 97
    dq opn_DELETE_GLOBAL              ; 98
    dq opn_SWAP                       ; 99
    dq opn_LOAD_CONST                 ; 100
    dq opn_LOAD_NAME                  ; 101
    dq opn_BUILD_TUPLE                ; 102
    dq opn_BUILD_LIST                 ; 103
    dq opn_BUILD_SET                  ; 104
    dq opn_BUILD_MAP                  ; 105
    dq opn_LOAD_ATTR                  ; 106
    dq opn_COMPARE_OP                 ; 107
    dq opn_IMPORT_NAME                ; 108
    dq opn_IMPORT_FROM                ; 109
    dq opn_JUMP_FORWARD               ; 110
    dq opn_unknown                    ; 111
    dq opn_unknown                    ; 112
    dq opn_unknown                    ; 113
    dq opn_POP_JUMP_IF_FALSE          ; 114
    dq opn_POP_JUMP_IF_TRUE           ; 115
    dq opn_LOAD_GLOBAL                ; 116
    dq opn_IS_OP                      ; 117
    dq opn_CONTAINS_OP                ; 118
    dq opn_RERAISE                    ; 119
    dq opn_COPY                       ; 120
    dq opn_RETURN_CONST               ; 121
    dq opn_BINARY_OP                  ; 122
    dq opn_SEND                       ; 123
    dq opn_LOAD_FAST                  ; 124
    dq opn_STORE_FAST                 ; 125
    dq opn_DELETE_FAST                ; 126
    dq opn_LOAD_FAST_CHECK            ; 127
    dq opn_POP_JUMP_IF_NOT_NONE       ; 128
    dq opn_POP_JUMP_IF_NONE           ; 129
    dq opn_RAISE_VARARGS              ; 130
    dq opn_GET_AWAITABLE              ; 131
    dq opn_MAKE_FUNCTION              ; 132
    dq opn_BUILD_SLICE                ; 133
    dq opn_JUMP_BACKWARD_NO_INTERRUPT ; 134
    dq opn_MAKE_CELL                  ; 135
    dq opn_LOAD_CLOSURE               ; 136
    dq opn_LOAD_DEREF                 ; 137
    dq opn_STORE_DEREF                ; 138
    dq opn_DELETE_DEREF               ; 139
    dq opn_JUMP_BACKWARD              ; 140
    dq opn_LOAD_SUPER_ATTR            ; 141
    dq opn_CALL_FUNCTION_EX           ; 142
    dq opn_LOAD_FAST_AND_CLEAR        ; 143
    dq opn_EXTENDED_ARG               ; 144
    dq opn_LIST_APPEND                ; 145
    dq opn_SET_ADD                    ; 146
    dq opn_MAP_ADD                    ; 147
    dq opn_unknown                    ; 148
    dq opn_COPY_FREE_VARS             ; 149
    dq opn_YIELD_VALUE                ; 150
    dq opn_RESUME                     ; 151
    dq opn_MATCH_CLASS                ; 152
    dq opn_unknown                    ; 153
    dq opn_unknown                    ; 154
    dq opn_FORMAT_VALUE               ; 155
    dq opn_BUILD_CONST_KEY_MAP        ; 156
    dq opn_BUILD_STRING               ; 157
    dq opn_unknown                    ; 158
    dq opn_unknown                    ; 159
    dq opn_unknown                    ; 160
    dq opn_unknown                    ; 161
    dq opn_LIST_EXTEND                ; 162
    dq opn_SET_UPDATE                 ; 163
    dq opn_DICT_MERGE                 ; 164
    dq opn_DICT_UPDATE                ; 165
    dq opn_unknown                    ; 166
    dq opn_unknown                    ; 167
    dq opn_unknown                    ; 168
    dq opn_unknown                    ; 169
    dq opn_unknown                    ; 170
    dq opn_CALL                       ; 171
    dq opn_KW_NAMES                   ; 172
    dq opn_CALL_INTRINSIC_1           ; 173
    dq opn_CALL_INTRINSIC_2           ; 174
    dq opn_LOAD_FROM_DICT_OR_GLOBALS  ; 175
    dq opn_LOAD_FROM_DICT_OR_DEREF    ; 176
    dq opn_unknown                    ; 177
    dq opn_unknown                    ; 178
    dq opn_unknown                    ; 179
    dq opn_unknown                    ; 180
    dq opn_unknown                    ; 181
    dq opn_unknown                    ; 182
    dq opn_unknown                    ; 183
    dq opn_unknown                    ; 184
    dq opn_unknown                    ; 185
    dq opn_unknown                    ; 186
    dq opn_unknown                    ; 187
    dq opn_unknown                    ; 188
    dq opn_unknown                    ; 189
    dq opn_unknown                    ; 190
    dq opn_unknown                    ; 191
    dq opn_unknown                    ; 192
    dq opn_unknown                    ; 193
    dq opn_unknown                    ; 194
    dq opn_unknown                    ; 195
    dq opn_unknown                    ; 196
    dq opn_unknown                    ; 197
    dq opn_unknown                    ; 198
    dq opn_unknown                    ; 199
    dq opn_LOAD_GLOBAL_MODULE         ; 200
    dq opn_LOAD_GLOBAL_BUILTIN        ; 201
    dq opn_unknown                    ; 202
    dq opn_LOAD_ATTR_METHOD           ; 203
    dq opn_unknown                    ; 204
    dq opn_unknown                    ; 205
    dq opn_unknown                    ; 206
    dq opn_unknown                    ; 207
    dq opn_unknown                    ; 208
    dq opn_COMPARE_OP_INT             ; 209
    dq opn_unknown                    ; 210
    dq opn_BINARY_OP_ADD_INT          ; 211
    dq opn_BINARY_OP_SUBTRACT_INT     ; 212
    dq opn_FOR_ITER_LIST              ; 213
    dq opn_FOR_ITER_RANGE             ; 214
    dq opn_unknown                    ; 215
    dq opn_unknown                    ; 216
    dq opn_unknown                    ; 217
    dq opn_unknown                    ; 218
    dq opn_unknown                    ; 219
    dq opn_unknown                    ; 220
    dq opn_unknown                    ; 221
    dq opn_unknown                    ; 222
    dq opn_unknown                    ; 223
    dq opn_unknown                    ; 224
    dq opn_unknown                    ; 225
    dq opn_unknown                    ; 226
    dq opn_unknown                    ; 227
    dq opn_unknown                    ; 228
    dq opn_unknown                    ; 229
    dq opn_unknown                    ; 230
    dq opn_unknown                    ; 231
    dq opn_unknown                    ; 232
    dq opn_unknown                    ; 233
    dq opn_unknown                    ; 234
    dq opn_BINARY_SUBSCR_LIST_INT    ; 235
    dq opn_BINARY_SUBSCR_TUPLE_INT   ; 236
    dq opn_STORE_SUBSCR_LIST_INT     ; 237
    dq opn_UNPACK_SEQUENCE_TUPLE     ; 238
    dq opn_UNPACK_SEQUENCE_LIST      ; 239
    dq opn_STORE_ATTR_INSTANCE       ; 240
    dq opn_CALL_PY_EXACT             ; 241
    dq opn_LOAD_ATTR_PROPERTY        ; 242
    dq opn_unknown                    ; 243
    dq opn_unknown                    ; 244
    dq opn_unknown                    ; 245
    dq opn_unknown                    ; 246
    dq opn_unknown                    ; 247
    dq opn_unknown                    ; 248
    dq opn_unknown                    ; 249
    dq opn_unknown                    ; 250
    dq opn_unknown                    ; 251
    dq opn_unknown                    ; 252
    dq opn_unknown                    ; 253
    dq opn_unknown                    ; 254
    dq opn_unknown                    ; 255

