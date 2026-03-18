; eval.asm - Bytecode evaluation loop
; Core dispatch loop and opcode table for the Python 3.12 interpreter
; Includes exception unwind mechanism

%include "macros.inc"
%include "object.inc"
%include "frame.inc"
%include "opcodes.inc"
%include "types.inc"
%include "errcodes.inc"

; External opcode handlers (defined in opcodes_*.asm files)
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
extern obj_decref
extern obj_incref
extern obj_dealloc
extern obj_str
extern sys_write
extern sys_exit
extern str_type
extern str_from_cstr
extern none_singleton

; Exception type singletons (for raising)
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_BaseException_type
extern exc_BaseExceptionGroup_type
extern exc_Exception_type
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
DEF_FUNC eval_frame
    SAVE_EVAL_REGS

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
    mov r15, [r12 + PyFrame.stack_tag_base]
    jmp .eval_setup_consts

.eval_resume:
    ; Generator resume: use saved IP and stack pointer
    mov r13, [r12 + PyFrame.stack_ptr]
    mov r15, [r12 + PyFrame.stack_tag_ptr]

.eval_setup_consts:
    ; Derive co_consts payload + tags pointers
    mov r14, [rax + PyCodeObject.co_consts]
    mov rdx, [r14 + PyTupleObject.ob_item_tags]
    mov r14, [r14 + PyTupleObject.ob_item]       ; co_consts payload ptr (→ global)

    ; rcx = co_names payload pointer, r8 = co_names tags pointer
    mov rcx, [rax + PyCodeObject.co_names]
    mov r8, [rcx + PyTupleObject.ob_item_tags]
    mov rcx, [rcx + PyTupleObject.ob_item]

    ; Save caller's eval globals (for nested eval_frame calls)
    mov rax, [rel eval_saved_rbx]
    push rax
    mov rax, [rel eval_saved_r12]
    push rax
    mov rax, [rel eval_saved_r13]
    push rax
    mov rax, [rel eval_saved_r15]
    push rax
    mov rax, [rel eval_co_names]
    push rax
    mov rax, [rel eval_co_names_tags]
    push rax
    mov rax, [rel eval_co_consts_tags]
    push rax
    mov rax, [rel eval_co_consts]
    push rax
    mov rax, [rel eval_base_rsp]
    push rax

    ; Set globals for this frame
    mov [rel eval_co_consts], r14               ; co_consts payload → global
    mov [rel eval_co_consts_tags], rdx
    mov [rel eval_co_names_tags], r8
    mov [rel eval_co_names], rcx

    ; r14 = locals_tag_base (hot: used by LOAD_FAST/STORE_FAST)
    mov r14, [r12 + PyFrame.locals_tag_base]

    ; Set up for this frame
    mov [rel eval_saved_r12], r12
    ; Save machine stack pointer for exception unwind cleanup
    mov [rel eval_base_rsp], rsp

    ; Check for pending throw (set by gen_throw before resume)
    mov [rel eval_saved_rbx], rbx
    mov [rel eval_saved_r13], r13
    mov [rel eval_saved_r15], r15
    cmp byte [rel throw_pending], 0
    je .no_throw

.throw_resume:
    mov byte [rel throw_pending], 0
    jmp eval_exception_unwind

.no_throw:
    ; Fall through to eval_dispatch
END_FUNC eval_frame

; eval_dispatch - Main dispatch point
; Reads the next opcode and arg, advances rbx, and jumps to the handler.
align 16
DEF_FUNC_BARE eval_dispatch
    mov [rel eval_saved_rbx], rbx  ; save bytecode IP for exception unwind
    mov [rel eval_saved_r13], r13  ; save payload stack ptr for exception unwind
    mov [rel eval_saved_r15], r15  ; save tag stack ptr for exception unwind
    movzx eax, byte [rbx]      ; load opcode
    movzx ecx, byte [rbx+1]    ; load arg into ecx
    add rbx, 2                  ; advance past instruction word
    cmp byte [rel trace_opcodes], 0
    jz .no_trace
    push rax
    push rcx
    mov edi, eax
    mov esi, ecx
    call trace_print_opcode
    pop rcx
    pop rax
.no_trace:
    lea rdx, [rel opcode_table]
    jmp [rdx + rax*8]              ; dispatch to handler
END_FUNC eval_dispatch

; eval_return - Return from eval_frame
; rax contains the return value. Restores callee-saved regs and returns.
DEF_FUNC_BARE eval_return
    ; Restore caller's eval globals (reverse of save order)
    ; Use rcx as scratch — rdx holds return tag (fat value protocol)
    pop rcx
    mov [rel eval_base_rsp], rcx
    pop rcx
    mov [rel eval_co_consts], rcx
    pop rcx
    mov [rel eval_co_consts_tags], rcx
    pop rcx
    mov [rel eval_co_names_tags], rcx
    pop rcx
    mov [rel eval_co_names], rcx
    pop rcx
    mov [rel eval_saved_r15], rcx
    pop rcx
    mov [rel eval_saved_r13], rcx
    pop rcx
    mov [rel eval_saved_r12], rcx
    pop rcx
    mov [rel eval_saved_rbx], rcx
    RESTORE_EVAL_REGS
    pop rbp
    ret
END_FUNC eval_return

; ---------------------------------------------------------------------------
; trace_print_opcode - Print opcode name and arg to stderr
; Called from eval_dispatch when tracing is enabled.
; edi = opcode number, esi = arg value
; ---------------------------------------------------------------------------
TP_OPCODE equ 8
TP_ARG    equ 16
TP_NAME   equ 24
TP_FRAME  equ 48

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
    lea rdi, [rbp - 25]           ; newline position
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
    lea rdx, [rbp - 24]           ; one past newline
    sub rdx, rdi
    mov rsi, rdi
    mov edi, 2
    call sys_write

    leave
    ret
END_FUNC trace_print_opcode

; ============================================================================
; Exception unwind mechanism
; ============================================================================

; eval_exception_unwind - Called when an exception is raised
; The exception object must already be stored in [current_exception].
; This routine searches the exception table for a handler. If found,
; it adjusts the value stack and jumps to the handler. If not found,
; it returns NULL from eval_frame to propagate to the caller.
DEF_FUNC_BARE eval_exception_unwind
    ; Restore machine stack to eval frame level (discard intermediate frames)
    mov rsp, [rel eval_base_rsp]

    ; Clear stale kw_names_pending — the non-local jump from raise_exception
    ; bypasses CALL opcode cleanup, leaving kw_names_pending set.
    mov qword [rel kw_names_pending], 0

    ; Free stale cfex_temp_pending buffer if set
    mov rdi, [rel cfex_temp_pending]
    test rdi, rdi
    jz .no_cfex_temp
    mov qword [rel cfex_temp_pending], 0
    extern ap_free
    call ap_free
.no_cfex_temp:

    ; Free stale cfex_merged_pending buffer if set
    mov rdi, [rel cfex_merged_pending]
    test rdi, rdi
    jz .no_cfex_merged
    mov qword [rel cfex_merged_pending], 0
    call ap_free
.no_cfex_merged:

    ; DECREF stale cfex_kwnames_pending tuple if set
    mov rdi, [rel cfex_kwnames_pending]
    test rdi, rdi
    jz .no_cfex_kwnames
    mov qword [rel cfex_kwnames_pending], 0
    extern obj_decref
    call obj_decref
.no_cfex_kwnames:

    ; DECREF stale build_class_pending type object if set
    mov rdi, [rel build_class_pending]
    test rdi, rdi
    jz .no_build_class
    mov qword [rel build_class_pending], 0
    call obj_decref
.no_build_class:

    ; Restore eval loop registers that may have been corrupted.
    ; When raise_exception is called from inside a function that saved/modified
    ; callee-saved regs (e.g. list_subscript saves rbx for temp use), the
    ; non-local jump to here bypasses the restore, leaving regs corrupted.
    ; rbx: use saved copy from eval_dispatch (pre-advance, points to instruction)
    ; r12: reload from frame pointer (saved in eval_frame_r12)
    ; r14: re-derive locals_tag_base from frame
    mov rbx, [rel eval_saved_rbx]   ; restore bytecode IP (pre-advance copy)
    mov r12, [rel eval_saved_r12]   ; restore frame pointer
    mov r13, [rel eval_saved_r13]   ; restore payload stack pointer
    mov r15, [rel eval_saved_r15]   ; restore tag stack pointer

    ; Attach traceback to exception if none exists yet
    mov rax, [rel current_exception]
    test rax, rax
    jz .skip_tb
    cmp qword [rax + PyExceptionObject.exc_tb], 0
    jne .skip_tb
    push rax                         ; save exception ptr
    extern traceback_new
    call traceback_new               ; rax = new traceback object
    pop rdx                          ; rdx = exception
    mov [rdx + PyExceptionObject.exc_tb], rax  ; attach (transfer ownership)
.skip_tb:

    ; Re-derive globals + r14 from the code object
    mov rax, [r12 + PyFrame.code]
    mov rcx, [rax + PyCodeObject.co_consts]
    mov rdx, [rcx + PyTupleObject.ob_item_tags]
    mov rcx, [rcx + PyTupleObject.ob_item]          ; consts payload array
    mov [rel eval_co_consts], rcx
    mov [rel eval_co_consts_tags], rdx
    mov rcx, [rax + PyCodeObject.co_names]
    mov r8, [rcx + PyTupleObject.ob_item_tags]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rel eval_co_names], rcx
    mov [rel eval_co_names_tags], r8
    ; r14 = locals_tag_base (hot register)
    mov r14, [r12 + PyFrame.locals_tag_base]

    ; Compute bytecode offset in instruction units (halfwords)
    ; eval_saved_rbx points to the instruction word (before add rbx, 2)
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
    ; target r13/r15 = stack_base + depth
    mov rdi, [r12 + PyFrame.stack_base]
    mov rsi, [r12 + PyFrame.stack_tag_base]
    mov eax, edx
    lea r8, [rsi + rax]      ; target tag ptr
    shl rax, 3               ; depth * 8 (payload)
    add rdi, rax             ; target payload ptr
    ; DECREF any items being popped from stack
    cmp r13, rdi
    jbe .stack_adjusted
.pop_stack:
    sub r13, 8
    sub r15, 1
    cmp r13, rdi
    jb .stack_adjusted
    push r8                  ; save target tag ptr (caller-saved, clobbered by XDECREF_VAL)
    push rdi                 ; save target payload ptr
    mov rdi, [r13]           ; payload
    movzx rsi, byte [r15]    ; tag
    XDECREF_VAL rdi, rsi    ; tag-aware NULL-safe DECREF
    pop rdi
    pop r8
    cmp r13, rdi
    ja .pop_stack
.stack_adjusted:
    mov r13, rdi             ; set payload stack to target depth
    mov r15, r8              ; set tag stack to target depth

    ; Check push_lasti flag
    pop rcx                  ; restore push_lasti
    pop rax                  ; restore target

    ; If push_lasti, push the instruction offset (as SmallInt)
    test ecx, ecx
    jz .no_lasti
    ; Push a dummy lasti value (we don't use it for now)
    xor edx, edx
    VPUSH_INT rdx
.no_lasti:

    ; Push the exception onto the value stack (transfer ownership)
    mov rdx, [rel current_exception]
    mov qword [rel current_exception], 0   ; clear: ownership moves to value stack
    VPUSH_PTR rdx

    ; Set rbx to handler target
    ; target is in instruction units (halfwords), so bytes = target * 2
    mov rcx, [r12 + PyFrame.code]
    lea rbx, [rcx + PyCodeObject.co_code]
    lea rbx, [rbx + rax*2]   ; target * 2 = byte offset

    DISPATCH

.no_handler:
    ; No handler found - must clean up value stack before returning
    ; DECREF all items on value stack (from stack_base to r13)
    mov rdi, [r12 + PyFrame.stack_base]
    mov rsi, [r12 + PyFrame.stack_tag_base]
.no_handler_cleanup:
    cmp r13, rdi
    jbe .no_handler_done
    sub r13, 8
    sub r15, 1
    push rdi                 ; save stack_base
    mov rdi, [r13]           ; payload
    movzx rsi, byte [r15]    ; tag
    XDECREF_VAL rdi, rsi     ; tag-aware NULL-safe DECREF
    pop rdi                  ; restore stack_base
    jmp .no_handler_cleanup
.no_handler_done:
    ; Clear instr_ptr so gen_throw/gen_send detect exhaustion
    mov qword [r12 + PyFrame.instr_ptr], 0
    xor eax, eax
    xor edx, edx              ; TAG_NULL for proper value return
    jmp eval_return
END_FUNC eval_exception_unwind

; raise_exception(PyTypeObject *type, const char *msg_cstr)
; Create an exception from a C string and begin unwinding.
; Callable from opcode handlers - uses eval loop registers.
DEF_FUNC raise_exception

    ; Create exception: exc_from_cstr(type, msg)
    call exc_from_cstr
    ; rax = exception object

    ; Store in current_exception
    ; First XDECREF any existing exception
    push rax
    mov rdi, [rel current_exception]
    test rdi, rdi
    jz .no_prev
    call obj_decref
.no_prev:
    pop rax
    mov [rel current_exception], rax

    leave
    jmp eval_exception_unwind
END_FUNC raise_exception

; raise_exception_obj(PyExceptionObject *exc)
; Set exception and begin unwinding.
; Takes ownership of the exc reference (caller must pass an owned ref).
DEF_FUNC raise_exception_obj

    ; XDECREF any existing exception
    push rdi
    mov rax, [rel current_exception]
    test rax, rax
    jz .no_prev2
    push rdi
    mov rdi, rax
    call obj_decref
    pop rdi
.no_prev2:
    pop rdi
    mov [rel current_exception], rdi

    leave
    jmp eval_exception_unwind
END_FUNC raise_exception_obj

; ============================================================================
; Exception-related opcode handlers (inline in eval.asm for access to globals)
; ============================================================================

; op_push_exc_info (35) - Push exception info for try/except
; TOS has the exception. Save current exception state, install new one.
; Stack effect: exc -> prev_exc, exc
DEF_FUNC_BARE op_push_exc_info
    ; TOS = new exception
    VPOP rax                 ; rax = new exception

    ; Push the previous current_exception (or None if NULL)
    mov rdx, [rel current_exception]
    test rdx, rdx
    jnz .have_prev
    lea rdx, [rel none_singleton]
    INCREF rdx
.have_prev:
    VPUSH_PTR rdx            ; push prev_exc

    ; Set new exception as current and push it too
    ; INCREF for the value stack copy
    INCREF rax
    mov [rel current_exception], rax
    VPUSH_PTR rax            ; push new exc

    DISPATCH
END_FUNC op_push_exc_info

; op_pop_except (89) - Restore previous exception state
; TOS = the exception to restore as current
DEF_FUNC_BARE op_pop_except
    VPOP rax                 ; rax = exception to restore

    ; XDECREF old current_exception
    push rax
    mov rdi, [rel current_exception]
    test rdi, rdi
    jz .no_old
    call obj_decref
.no_old:
    pop rax

    ; Set restored exception as current (or NULL if None)
    lea rdx, [rel none_singleton]
    cmp rax, rdx
    jne .set_exc
    ; It's None - set current to NULL and DECREF the None
    mov qword [rel current_exception], 0
    DECREF rax
    DISPATCH
.set_exc:
    mov [rel current_exception], rax
    DISPATCH
END_FUNC op_pop_except

; op_check_exc_match (36) - Check if exception matches a type
; TOS = type to match against, TOS1 = exception
; Push True/False, don't pop the exception
DEF_FUNC_BARE op_check_exc_match
    VPOP rsi                 ; rsi = type to match
    VPEEK rdi                ; rdi = exception (don't pop)

    ; Save type for DECREF
    push rsi

    ; Call exc_isinstance(exc, type)
    call exc_isinstance
    ; eax = 0 or 1

    ; DECREF the type
    push rax
    mov rdi, [rsp + 8]
    call obj_decref
    pop rax
    add rsp, 8

    ; Push bool result
    test eax, eax
    jz .no_match
    extern bool_true
    lea rax, [rel bool_true]
    jmp .push_result
.no_match:
    extern bool_false
    lea rax, [rel bool_false]
.push_result:
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
END_FUNC op_check_exc_match

;; op_check_eg_match (37) - Check exception group match for except*
;; Stack in:  [..., exc_value, match_type]
;; On match:  [..., rest_or_None, match_eg]  (pop exc_value, push rest, push match)
;; No match:  [..., exc_value, None]          (keep exc_value, push None)
;;
;; Cases:
;; 1. exc_value isinstance match_type AND is ExceptionGroup → eg_split
;; 2. exc_value isinstance match_type AND is NOT ExceptionGroup → wrap in EG, rest=None
;; 3. exc_value is ExceptionGroup but NOT isinstance → eg_split (may return NULL match)
;; 4. No match at all → push None

CEM_EXC    equ 8
CEM_MTYPE  equ 16
CEM_MATCH  equ 24
CEM_REST   equ 32
CEM_TMP1   equ 40
CEM_TMP2   equ 48
CEM_FRAME  equ 48
DEF_FUNC op_check_eg_match, CEM_FRAME

    VPOP rsi                 ; rsi = match_type
    VPEEK rdi                ; rdi = exc_value (don't pop yet)
    mov [rbp - CEM_EXC], rdi
    mov [rbp - CEM_MTYPE], rsi

    ; Check if exc_value is None → no match
    lea rax, [rel none_singleton]
    cmp rdi, rax
    je .cem_no_match

    ; Case 1/2: isinstance(exc_value, match_type)?
    ; rdi = exc, rsi = type already set
    call exc_isinstance
    test eax, eax
    jz .cem_check_group_split

    ; Match! Check if exc_value is an ExceptionGroup
    mov rdi, [rbp - CEM_EXC]
    call eg_is_base_exception_group
    test eax, eax
    jnz .cem_full_group_match

    ; Case 2: Naked exception matches — wrap in ExceptionGroup
    ; Create a 1-element tuple containing the exception
    mov edi, 1
    call tuple_new
    mov [rbp - CEM_TMP1], rax ; TMP1 = tuple
    mov rcx, [rbp - CEM_EXC]
    INCREF rcx
    mov rdx, [rax + PyTupleObject.ob_item]
    mov r8, [rax + PyTupleObject.ob_item_tags]
    mov [rdx], rcx
    mov byte [r8], TAG_PTR

    ; Create empty message string (heap — stored in exception struct)
    extern str_from_cstr_heap
    CSTRING rdi, ""
    call str_from_cstr_heap
    mov [rbp - CEM_TMP2], rax ; TMP2 = empty msg str

    ; eg_new(ExceptionGroup_type, empty_str, tuple)
    lea rdi, [rel exc_ExceptionGroup_type]
    mov rsi, [rbp - CEM_TMP2]
    mov rdx, [rbp - CEM_TMP1]
    call eg_new
    mov [rbp - CEM_MATCH], rax  ; match_eg

    ; DECREF temp empty str (eg_new INCREFed it)
    mov rdi, [rbp - CEM_TMP2]
    call obj_decref
    ; DECREF temp tuple (eg_new INCREFed it)
    mov rdi, [rbp - CEM_TMP1]
    call obj_decref

    ; Pop exc_value from stack, push None (rest), push match_eg
    VPOP rdi                 ; pop exc_value
    call obj_decref

    lea rax, [rel none_singleton]
    INCREF rax
    VPUSH_PTR rax            ; push rest = None

    mov rax, [rbp - CEM_MATCH]
    VPUSH_PTR rax            ; push match_eg (owns ref from eg_new)

    ; DECREF match_type
    mov rdi, [rbp - CEM_MTYPE]
    call obj_decref

    leave
    DISPATCH

.cem_full_group_match:
    ; Case 1: exc_value is ExceptionGroup and isinstance matches entirely
    ; Do eg_split to separate matching from non-matching
    mov rdi, [rbp - CEM_EXC]
    mov rsi, [rbp - CEM_MTYPE]
    call eg_split
    ; rax = match_eg (or NULL), rdx = rest_eg (or NULL)
    mov [rbp - CEM_MATCH], rax
    mov [rbp - CEM_REST], rdx

    ; Pop exc_value, push rest, push match
    VPOP rdi
    call obj_decref

    ; Push rest (or None if NULL)
    mov rax, [rbp - CEM_REST]
    test rax, rax
    jnz .cem_push_rest
    lea rax, [rel none_singleton]
    INCREF rax
.cem_push_rest:
    VPUSH_PTR rax

    ; Push match (or None if NULL — shouldn't happen since isinstance matched)
    mov rax, [rbp - CEM_MATCH]
    test rax, rax
    jnz .cem_push_match
    lea rax, [rel none_singleton]
    INCREF rax
.cem_push_match:
    VPUSH_PTR rax

    ; DECREF match_type
    mov rdi, [rbp - CEM_MTYPE]
    call obj_decref

    leave
    DISPATCH

.cem_check_group_split:
    ; Not a direct isinstance match. Check if exc_value is an ExceptionGroup
    ; and split by match_type.
    mov rdi, [rbp - CEM_EXC]
    call eg_is_base_exception_group
    test eax, eax
    jz .cem_no_match

    ; It IS an ExceptionGroup — split it
    mov rdi, [rbp - CEM_EXC]
    mov rsi, [rbp - CEM_MTYPE]
    call eg_split
    ; rax = match_eg (or NULL), rdx = rest_eg (or NULL)
    mov [rbp - CEM_MATCH], rax
    mov [rbp - CEM_REST], rdx

    ; If match is NULL, no match at all
    test rax, rax
    jz .cem_split_no_match

    ; Pop exc_value, push rest, push match
    VPOP rdi
    call obj_decref

    ; Push rest (or None if NULL)
    mov rax, [rbp - CEM_REST]
    test rax, rax
    jnz .cem_split_push_rest
    lea rax, [rel none_singleton]
    INCREF rax
.cem_split_push_rest:
    VPUSH_PTR rax

    ; Push match
    mov rax, [rbp - CEM_MATCH]
    VPUSH_PTR rax

    ; DECREF match_type
    mov rdi, [rbp - CEM_MTYPE]
    call obj_decref

    leave
    DISPATCH

.cem_split_no_match:
    ; Split returned no match — clean up and push None
    ; rest_eg might be non-NULL, DECREF it
    mov rdi, [rbp - CEM_REST]
    test rdi, rdi
    jz .cem_no_match
    call obj_decref
    ; Fall through to no_match

.cem_no_match:
    ; No match — keep exc_value on stack, push None
    lea rax, [rel none_singleton]
    INCREF rax
    VPUSH_PTR rax

    ; DECREF match_type
    mov rdi, [rbp - CEM_MTYPE]
    call obj_decref

    leave
    DISPATCH
END_FUNC op_check_eg_match

; op_raise_varargs (130) - Raise an exception
; arg 0: reraise current exception
; arg 1: raise TOS
; arg 2: raise TOS1 from TOS (chaining, simplified)
DEF_FUNC_BARE op_raise_varargs
    cmp ecx, 0
    je .reraise
    cmp ecx, 1
    je .raise_exc
    cmp ecx, 2
    je .raise_from

    ; Invalid arg
    CSTRING rdi, "SystemError: bad RAISE_VARARGS arg"
    extern fatal_error
    call fatal_error

.reraise:
    ; Re-raise current exception
    mov rax, [rel current_exception]
    test rax, rax
    jnz .do_reraise
    ; No current exception - raise RuntimeError
    lea rdi, [rel exc_RuntimeError_type]
    extern exc_RuntimeError_type
    CSTRING rsi, "No active exception to re-raise"
    call raise_exception
    ; does not return here

.do_reraise:
    ; current_exception is already set, just unwind
    jmp eval_exception_unwind

.raise_exc:
    ; TOS is the exception to raise
    VPOP_VAL rdi, r8
    mov [rel eval_saved_r13], r13  ; update saved stack — VPOP consumed the item
    mov [rel eval_saved_r15], r15

    ; Check if it's already an exception object or a type
    ; If it's a type, create an instance with no args
    cmp r8d, TAG_PTR
    jne .raise_bad_no_decref  ; non-pointer can't be an exception
    test rdi, rdi
    jz .raise_bad_no_decref   ; NULL can't be an exception

    ; Check INSTANCE first (most common case: raise SomeException("msg"))
    ; An instance's ob_type chain might be an exception type
    extern type_is_exc_subclass
    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .raise_bad
    push rdi
    mov rdi, rax
    call type_is_exc_subclass
    pop rdi
    test eax, eax
    jnz .raise_exc_obj

    ; Check if rdi is an exception TYPE (e.g., bare "raise ValueError")
    ; First verify rdi is actually a type object (ob_type == type_type, exc_metatype,
    ; or user_type_metatype) to avoid segfault on non-type objects like strings
    mov rax, [rdi + PyObject.ob_type]
    extern type_type
    lea rcx, [rel type_type]
    cmp rax, rcx
    je .raise_check_type
    extern exc_metatype
    lea rcx, [rel exc_metatype]
    cmp rax, rcx
    je .raise_check_type
    extern user_type_metatype
    lea rcx, [rel user_type_metatype]
    cmp rax, rcx
    jne .raise_bad               ; not a type object at all

.raise_check_type:
    ; rdi is a type object — check if it's an exception subclass
    push rdi
    call type_is_exc_subclass
    pop rdi
    test eax, eax
    jnz .raise_type

    jmp .raise_bad

.raise_type:
    ; rdi = exception type - create instance with no message
    push rdi
    xor esi, esi              ; no message
    xor edx, edx              ; no tag (NULL msg)
    call exc_new
    pop rdi                  ; discard type (immortal, no DECREF needed)
    mov rdi, rax
    jmp .raise_exc_obj

.raise_exc_obj:
    ; rdi = exception object
    ; Store as current_exception
    push rdi
    mov rax, [rel current_exception]
    test rax, rax
    jz .no_prev_raise
    push rdi
    mov rdi, rax
    call obj_decref
    pop rdi
.no_prev_raise:
    pop rdi
    mov [rel current_exception], rdi
    ; Don't DECREF rdi - we transferred ownership from value stack to current_exception
    jmp eval_exception_unwind

.raise_bad:
    ; DECREF the bad value (pointer guaranteed here) and raise TypeError
    call obj_decref
.raise_bad_no_decref:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "exceptions must derive from BaseException"
    call raise_exception

.raise_from:
    ; TOS = cause, TOS1 = exception
    VPOP_VAL rsi, rcx         ; cause payload + tag
    push rcx                 ; save cause tag
    push rsi                 ; save cause payload
    VPOP_VAL rdi, r8          ; exception payload
    mov [rel eval_saved_r13], r13  ; update saved stack — VPOPs consumed both items
    mov [rel eval_saved_r15], r15
    push rdi                 ; save exception

    ; Store __cause__ on exception object (if exception is a pointer)
    ; cause is at [rsp+8], cause_tag at [rsp+16]
    mov rax, [rsp + 8]      ; cause payload
    mov rcx, [rsp + 16]     ; cause tag
    ; Only store cause if it's a pointer (heap exception object)
    test ecx, TAG_RC_BIT
    jz .raise_from_no_cause
    ; Store cause (transfer ownership — no INCREF, we own the ref from VPOP)
    mov [rdi + PyExceptionObject.exc_cause], rax
    jmp .raise_from_done

.raise_from_no_cause:
    ; Non-pointer cause or None — DECREF if needed and set cause to NULL
    mov rdi, rax
    mov rsi, rcx
    DECREF_VAL rdi, rsi
    mov rdi, [rsp]           ; restore exception
    mov qword [rdi + PyExceptionObject.exc_cause], 0

.raise_from_done:
    ; Raise the exception
    pop rdi
    add rsp, 16
    jmp .raise_exc_obj
END_FUNC op_raise_varargs

; op_reraise (119) - Re-raise the current exception
; TOS = exception to re-raise
DEF_FUNC_BARE op_reraise
    ; Pop the exception from value stack
    VPOP_VAL rdi, r8
    mov [rel eval_saved_r13], r13  ; update saved stack — VPOP consumed the item
    mov [rel eval_saved_r15], r15

    ; Store it as current exception
    push rdi
    mov rax, [rel current_exception]
    test rax, rax
    jz .no_prev_rr
    push rdi
    mov rdi, rax
    call obj_decref
    pop rdi
.no_prev_rr:
    pop rdi
    mov [rel current_exception], rdi
    jmp eval_exception_unwind
END_FUNC op_reraise

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
    mov rax, [rel current_exception]
    test rax, rax
    jnz .unhandled_exception
    VPOP_VAL rax, rdx
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
    mov rdi, [rel current_exception]
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
    cmp qword [rdi + PyExceptionObject.exc_value_tag], TAG_PTR
    jne .no_message
    mov rax, [rdi + PyExceptionObject.exc_value]
    test rax, rax
    jz .no_message

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

; ---------------------------------------------------------------------------
; op_extended_arg - Extend the arg of the NEXT instruction
;
; Shifts current arg left 8 bits, combines with next instruction's arg,
; then dispatches next instruction with the combined arg.
; Can chain: multiple EXTENDED_ARGs shift 8 more bits each time.
; ---------------------------------------------------------------------------
op_extended_arg:
    shl ecx, 8                 ; shift current arg left 8
    movzx eax, byte [rbx]     ; next opcode
    movzx edx, byte [rbx+1]   ; next arg
    or ecx, edx               ; combine args
    add rbx, 2                 ; advance past next instruction
    lea rdx, [rel opcode_table]
    jmp [rdx + rax*8]         ; dispatch with combined arg in ecx

; ---------------------------------------------------------------------------
; op_load_assertion_error - Push AssertionError type
; ---------------------------------------------------------------------------
extern exc_AssertionError_type
op_load_assertion_error:
    lea rax, [rel exc_AssertionError_type]
    INCREF rax
    VPUSH_PTR rax
    DISPATCH

; ---------------------------------------------------------------------------
; Opcode dispatch table (256 entries, section .data for potential patching)
; ---------------------------------------------------------------------------
section .data
align 8
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
    dq op_unimplemented      ; 204
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
    dq op_unimplemented      ; 223
    dq op_unimplemented      ; 224
    dq op_unimplemented      ; 225
    dq op_unimplemented      ; 226
    dq op_unimplemented      ; 227
    dq op_unimplemented      ; 228
    dq op_unimplemented      ; 229
    dq op_unimplemented      ; 230
    dq op_unimplemented      ; 231
    dq op_unimplemented      ; 232
    dq op_unimplemented      ; 233
    dq op_unimplemented      ; 234
    dq op_unimplemented      ; 235
    dq op_unimplemented      ; 236
    dq op_unimplemented      ; 237
    dq op_unimplemented      ; 238
    dq op_unimplemented      ; 239
    dq op_unimplemented      ; 240
    dq op_unimplemented      ; 241
    dq op_unimplemented      ; 242
    dq op_unimplemented      ; 243
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

; ============================================================================
; Global exception state (BSS)
; ============================================================================
section .bss
global current_exception
current_exception: resq 1    ; PyExceptionObject* or NULL
eval_base_rsp: resq 1        ; machine stack pointer at eval dispatch level
global eval_saved_rbx
eval_saved_rbx: resq 1       ; bytecode IP saved at dispatch (for exception unwind)
global eval_saved_r12
eval_saved_r12: resq 1       ; frame pointer saved at frame entry (for exception unwind)
global eval_saved_r13
eval_saved_r13: resq 1       ; value stack ptr saved at dispatch (for exception unwind)
global eval_saved_r15
eval_saved_r15: resq 1       ; tag stack ptr saved at dispatch (for exception unwind)
global eval_co_names
eval_co_names: resq 1        ; co_names payload pointer (&tuple.ob_item[0])
global eval_co_names_tags
eval_co_names_tags: resq 1   ; co_names tag pointer (&tuple.ob_item_tags[0])
global eval_co_consts
eval_co_consts: resq 1       ; co_consts payload pointer (&tuple.ob_item[0])
global eval_co_consts_tags
eval_co_consts_tags: resq 1  ; co_consts tag pointer (&tuple.ob_item_tags[0])

global kw_names_pending
kw_names_pending: resq 1     ; tuple of kw names for next CALL, or NULL

global cfex_temp_pending
cfex_temp_pending: resq 1    ; temp buffer from op_call_function_ex, or NULL

global cfex_merged_pending
cfex_merged_pending: resq 1  ; merged buffer from op_call_function_ex kwargs, or NULL

global cfex_kwnames_pending
cfex_kwnames_pending: resq 1 ; kw_names tuple from op_call_function_ex kwargs, or NULL

global build_class_pending
build_class_pending: resq 1  ; type object from builtin___build_class__ during construction, or NULL

global trace_opcodes
trace_opcodes: resb 1           ; nonzero = trace opcodes to stderr

global throw_pending
throw_pending: resb 1           ; nonzero = gen_throw set current_exception before resume

; ============================================================================
; Read-only data for traceback printing
; ============================================================================
section .rodata
tb_header: db "Traceback (most recent call last):", 10
tb_header_len equ $ - tb_header

tb_file_prefix: db '  File "', 0
tb_file_prefix_len equ $ - tb_file_prefix - 1

tb_line_prefix: db '", line ?, in '
tb_line_prefix_len equ $ - tb_line_prefix

tb_colon: db ": "
tb_newline: db 10

; ============================================================================
; Trace output helper strings
; ============================================================================
trace_prefix: db "  "
trace_space: db " "

; ============================================================================
; Opcode name strings
; ============================================================================
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

; ============================================================================
; Opcode name lookup table (256 entries, in .data for relocations)
; ============================================================================
section .data
align 8
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
    dq opn_unknown                    ; 235
    dq opn_unknown                    ; 236
    dq opn_unknown                    ; 237
    dq opn_unknown                    ; 238
    dq opn_unknown                    ; 239
    dq opn_unknown                    ; 240
    dq opn_unknown                    ; 241
    dq opn_unknown                    ; 242
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
