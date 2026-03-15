; opcodes_call.asm - Opcode handler for CALL (Python 3.12)
;
; Register convention (callee-saved, preserved across handlers):
;   rbx = bytecode instruction pointer (current position in co_code[])
;   r12 = current frame pointer (PyFrame*)
;   r13 = value stack payload top pointer
;   r14 = locals_tag_base pointer (frame's tag sidecar for localsplus[])
;   r15 = value stack tag top pointer
;
; ecx = opcode argument on entry (set by eval_dispatch)
; rbx has already been advanced past the 2-byte instruction word.

%include "macros.inc"
%include "object.inc"
%include "types.inc"
%include "opcodes.inc"
%include "frame.inc"
%include "builtins.inc"

section .text

extern eval_dispatch
extern eval_saved_rbx
extern eval_saved_r13
extern eval_saved_r15
extern opcode_table
extern obj_dealloc
extern obj_decref
extern obj_incref
extern fatal_error
extern raise_exception
extern func_new
extern exc_TypeError_type
extern kw_names_pending
extern cfex_temp_pending
extern cfex_merged_pending
extern cfex_kwnames_pending
extern ap_malloc
extern ap_free
extern tuple_new

; --- Named frame-layout constants ---

; op_call locals (DEF_FUNC op_call, CL_FRAME)
CL_NARGS     equ 8
CL_CALLABLE  equ 16
CL_RETVAL    equ 24
CL_IS_METHOD equ 32
CL_TOTAL     equ 40
CL_SAVED_RSP equ 48
CL_TPCALL    equ 56
CL_RETTAG    equ 64
CL_CALL_TAG  equ 72
CL_SAVED_R13 equ 80
CL_SAVED_R15 equ 88
CL_FRAME     equ 96

; op_make_function locals (DEF_FUNC op_make_function, MF_FRAME)
MF_FLAGS   equ 8
MF_CODE    equ 16
MF_CLOSURE equ 24
MF_DEFAULTS equ 32
MF_KWDEFS  equ 40
MF_CTAG    equ 48
MF_FRAME   equ 48

; op_call_function_ex locals (manual frame, push rbx; push r12; sub rsp, 48)
CFX_FUNC    equ 32
CFX_ARGS    equ 40
CFX_KWARGS  equ 48
CFX_RESULT  equ 56
CFX_OPARG   equ 64

; op_before_with locals (manual frame, push rbx; push r12; sub rsp, 32)
BW_RETTAG  equ 24
BW_MGR     equ 32
BW_EXIT    equ 40
BW_ENTER   equ 48

; op_with_except_start locals (DEF_FUNC op_with_except_start, WES_FRAME)
WES_FUNC   equ 8
WES_SELF   equ 16
WES_VAL    equ 24
WES_RESULT equ 32
WES_RETTAG equ 40
WES_FRAME  equ 48

;; ============================================================================
;; op_call - Call a callable object
;;
;; Python 3.12 CALL opcode (171).
;;
;; Stack layout before CALL (bottom to top):
;;   ... | NULL_or_self | callable | arg0 | arg1 | ... | argN-1 |
;;                                                            ^ r13 (TOS)
;;
;; ecx = nargs (number of positional arguments)
;;
;; Addresses:
;;   args[0]      = [r13 - nargs*8]
;;   callable     = [r13 - (nargs+1)*8]
;;   null_or_self = [r13 - (nargs+2)*8]
;;
;; Method calls (null_or_self != NULL):
;;   self is inserted as the first argument by overwriting the callable's
;;   value stack slot, and nargs is incremented by 1.
;;
;; After the call:
;;   1. DECREF each argument (including self copy for method calls)
;;   2. For method calls: DECREF original self_or_null, DECREF saved callable
;;      For function calls: DECREF callable, DECREF null_or_self (NULL)
;;   3. Pop all consumed items from value stack
;;   4. Push return value
;;   5. Skip 3 CACHE entries (6 bytes): add rbx, 6
;;
;; Followed by 3 CACHE entries (6 bytes) that must be skipped.
;; ============================================================================
DEF_FUNC op_call, CL_FRAME

    ; Save value stack pointers in case callee clobbers callee-saved regs
    mov [rbp - CL_SAVED_R13], r13
    mov [rbp - CL_SAVED_R15], r15

    mov [rbp - CL_NARGS], rcx                ; save nargs
    mov qword [rbp - CL_IS_METHOD], 0          ; is_method = 0

    ; CPython 3.12 stack layout (bottom to top):
    ;   ... | func_or_null | callable_or_self | arg0 | ... | argN-1
    ; func_or_null = PEEK(nargs+2) — deeper slot
    ; callable_or_self = PEEK(nargs+1) — shallower slot
    ;
    ; Method call (func_or_null != NULL): callable=func_or_null, self=callable_or_self
    ; Function call (func_or_null == NULL): callable=callable_or_self

    ; Read func_or_null from deeper slot
    mov rax, rcx
    add rax, 2
    neg rax
    lea rdi, [r13 + rax*8]
    mov rdi, [rdi]

    test rdi, rdi
    jz .func_call

    ; === Method call: callable is in the deeper slot ===
    mov [rbp - CL_CALLABLE], rdi               ; callable = func_or_null
    lea rdx, [r15 + rax]
    movzx edx, byte [rdx]                      ; callable tag
    mov [rbp - CL_CALL_TAG], rdx
    mov qword [rbp - CL_IS_METHOD], 1          ; is_method = 1
    jmp .setup_call

.func_call:
    ; === Function call: callable is in the shallower slot ===
    mov rax, rcx
    add rax, 1
    neg rax
    lea rdi, [r13 + rax*8]
    mov rdi, [rdi]
    mov [rbp - CL_CALLABLE], rdi               ; callable = callable_or_self
    lea rdx, [r15 + rax]
    movzx edx, byte [rdx]                      ; callable tag
    mov [rbp - CL_CALL_TAG], rdx

.setup_call:
    ; Get tp_call from the callable's type
    mov rdi, [rbp - CL_CALLABLE]              ; callable
    test rdi, rdi
    jz .not_callable               ; NULL check
    cmp qword [rbp - CL_CALL_TAG], TAG_SMALLINT
    je .not_callable               ; SmallInt check
    cmp qword [rbp - CL_CALL_TAG], TAG_PTR
    jne .not_callable              ; non-pointer tag (TAG_FLOAT, TAG_NONE, TAG_BOOL)
    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .not_callable               ; no type (shouldn't happen)
    mov rcx, rax                    ; save type for dunder check
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jnz .have_tp_call

    ; tp_call NULL — try __call__ on heaptype
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .not_callable
    extern dunder_lookup
    extern dunder_call
    mov rdi, rcx              ; type
    lea rsi, [rel dunder_call]
    call dunder_lookup
    test edx, edx
    jz .not_callable
    ; Found __call__ — use its tp_call to dispatch
    mov rcx, rax              ; __call__ func
    mov rax, [rcx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .not_callable
    ; Rewrite callable: we need to call __call__(self, *args)
    ; The self is the original callable, prepend it to args
    ; Actually, we can just call dunder_func's tp_call with [callable, args...]
    ; But that requires restructuring the args. For simplicity, call it as
    ; tp_call(dunder_func, args_including_self, nargs+1)
    ; where args_including_self starts at the callable's slot on the value stack
    ; The callable is at [r13 - (nargs+1)*8], and args start at [r13 - nargs*8]
    ; We already have self in the callable's slot... actually this is tricky.
    ; Let's use a simpler approach: save dunder_func in [rbp-16], store original
    ; callable as first arg by shifting the args pointer back by 1
    mov [rbp - CL_CALLABLE], rcx         ; replace callable with __call__ func
    ; args_ptr should now include the original callable as self
    ; The original callable is already on the value stack at the right position
    ; We just need to point args_ptr one slot earlier and increment nargs
    ; Actually, let's just use the value stack directly:
    ; Stack: ... | NULL_or_self | original_callable | arg0 | arg1 | ...
    ; We want: tp_call(__call_func__, &[original_callable, arg0, ...], nargs+1)
    ; The original_callable is at [r13 - (nargs+1)*8], which is exactly where
    ; args_ptr - 8 would be. So we can just decrement args_ptr and inc nargs.
    ; But wait, we need to read nargs first...
    mov rcx, [rbp - CL_NARGS]
    mov rdx, rcx
    inc rdx                    ; nargs + 1 (include callable as self for __call__)
    ; For method calls, the value stack has an extra slot (the original callable
    ; in the deeper position, and method_self in the shallower). Include both.
    cmp qword [rbp - CL_IS_METHOD], 0
    je .dunder_not_method
    inc rdx                    ; nargs + 2 for method calls
.dunder_not_method:
    mov [rbp - CL_TPCALL], rax          ; save tp_call
    mov [rbp - CL_TOTAL], rdx          ; save total nargs
    jmp .call_with_args

.have_tp_call:
    ; Set up args: tp_call(callable, args_ptr, nargs)
    mov [rbp - CL_TPCALL], rax               ; save tp_call function ptr
    mov rcx, [rbp - CL_NARGS]               ; original nargs
    mov rdx, rcx                    ; rdx = nargs for tp_call

    cmp qword [rbp - CL_IS_METHOD], 0
    je .no_method_adj

    ; Method call: include self (shallower slot) as first arg
    inc rdx

.no_method_adj:
    mov [rbp - CL_TOTAL], rdx               ; save total nargs
    jmp .call_with_args

.call_with_args:
    ; Build temporary fat args array on machine stack from payload+tag stacks
    mov rcx, [rbp - CL_TOTAL]              ; total nargs
    mov [rbp - CL_SAVED_RSP], rsp
    test rcx, rcx
    jz .args_ready
    mov rax, rcx
    shl rax, 4                             ; total_nargs * 16
    sub rsp, rax
    mov [rbp - CL_SAVED_RSP], rsp
    mov r8, rsp                            ; dst ptr (fat args)
    ; Pre-compute source base pointers (deepest arg = total_nargs below TOS)
    mov rax, rcx
    neg rax
    lea r9, [r13 + rax*8]                  ; src payload start (deepest arg)
    lea r10, [r15 + rax]                   ; src tag start (deepest arg)
.copy_loop:
    mov rax, [r9]
    movzx edx, byte [r10]
    mov [r8], rax
    mov [r8 + 8], rdx
    add r9, 8
    inc r10
    add r8, 16
    dec ecx
    jnz .copy_loop
.args_ready:
    mov rdi, [rbp - CL_CALLABLE]           ; callable
    mov rsi, [rbp - CL_SAVED_RSP]          ; args_ptr
    mov rdx, [rbp - CL_TOTAL]              ; total nargs
    mov rax, [rbp - CL_TPCALL]             ; tp_call
    call rax
    mov [rbp - CL_RETVAL], rax             ; save return value
    mov [rbp - CL_RETTAG], rdx             ; save return tag
    mov rcx, [rbp - CL_TOTAL]
    test rcx, rcx
    jz .cleanup
    shl rcx, 4
    add rsp, rcx
    jmp .cleanup

.cleanup:
    ; Restore value stack pointers (defensive against callee clobber)
    mov r13, [rbp - CL_SAVED_R13]
    mov r15, [rbp - CL_SAVED_R15]

    ; === Unified cleanup ===
    ; Clear kw_names_pending: func_call clears it for Python functions,
    ; but builtins and other callables don't. Ensure it's always clean
    ; after a call so it can't contaminate the next func_call.
    mov qword [rel kw_names_pending], 0

    ; Pop nargs args and DECREF each (tag-aware for SmallInts)
    mov rcx, [rbp - CL_NARGS]
    test rcx, rcx
    jz .args_done
.decref_args:
    VPOP_VAL rdi, rsi
    mov [rbp - CL_NARGS], rcx     ; save loop counter (DECREF_VAL may call obj_dealloc)
    DECREF_VAL rdi, rsi
    mov rcx, [rbp - CL_NARGS]     ; restore loop counter
    dec rcx
    jnz .decref_args
.args_done:

    ; Pop shallower slot (self for method, callable for function) and DECREF
    VPOP_VAL rdi, rsi
    DECREF_VAL rdi, rsi

    ; Pop deeper slot (callable for method, NULL for function) and DECREF
    VPOP_VAL rdi, rsi
    XDECREF_VAL rdi, rsi
    ; Check for exception (TAG_NULL return with current_exception set)
    ; Must check TAG (not payload) — None and SmallInt(0) have payload=0
    mov rax, [rbp - CL_RETVAL]
    mov rdx, [rbp - CL_RETTAG]
    test rdx, rdx                    ; TAG_NULL = 0 means error
    jnz .push_result
    extern current_exception
    mov rcx, [rel current_exception]
    test rcx, rcx
    jnz .propagate_exc

.push_result:
    ; Push return value onto value stack (rax, rdx already loaded)
    VPUSH_VAL rax, rdx

    ; Skip 3 CACHE entries (6 bytes)
    add rbx, 6

    leave
    DISPATCH

.propagate_exc:
    ; Exception pending from callee — propagate to caller's handler
    extern eval_exception_unwind
    leave
    mov [rel eval_saved_r13], r13  ; update — cleanup already popped/DECREF'd args
    mov [rel eval_saved_r15], r15
    jmp eval_exception_unwind

.not_callable:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "object is not callable"
    call raise_exception
    ; does not return
END_FUNC op_call

;; ============================================================================
;; op_make_function - Create a function from code object on TOS
;;
;; Python 3.12 MAKE_FUNCTION (opcode 132).
;; arg = flags: 0 = plain, 1 = defaults, 2 = kwdefaults, 4 = annotations, 8 = closure
;;
;; Stack order (when flags set, bottom to top):
;;   defaults tuple (if flag 0x01)
;;   kwdefaults dict (if flag 0x02)
;;   annotations (if flag 0x04) - ignored
;;   closure tuple (if flag 0x08)
;;   code_obj (always on top)
;; ============================================================================
DEF_FUNC op_make_function, MF_FRAME

    mov [rbp - MF_FLAGS], ecx               ; save flags
    mov qword [rbp - MF_CLOSURE], 0          ; closure = NULL default
    mov qword [rbp - MF_DEFAULTS], 0          ; defaults = NULL default
    mov qword [rbp - MF_KWDEFS], 0          ; kwdefaults = NULL default

    ; Pop code object from value stack (always TOS)
    VPOP_VAL rdi, rax
    mov [rbp - MF_CODE], rdi
    mov [rbp - MF_CTAG], rax              ; save code tag

    ; Pop in CPython 3.12 order (reverse of push): 0x08, 0x04, 0x02, 0x01

    ; closure (0x08) - pop and save
    test ecx, MAKE_FUNC_CLOSURE
    jz .mf_no_closure
    VPOP rax
    mov [rbp - MF_CLOSURE], rax              ; save closure tuple
.mf_no_closure:

    ; annotations (0x04) - pop and discard
    test ecx, MAKE_FUNC_ANNOTATIONS
    jz .mf_no_annotations
    VPOP_VAL rdi, rsi
    DECREF_VAL rdi, rsi
    mov ecx, [rbp - MF_FLAGS]              ; reload flags (DECREF clobbers ecx)
.mf_no_annotations:

    ; kwdefaults (0x02) - pop and save (transfer ownership to func)
    test ecx, MAKE_FUNC_KWDEFAULTS
    jz .mf_no_kwdefaults
    VPOP rdi
    mov [rbp - MF_KWDEFS], rdi
.mf_no_kwdefaults:

    ; defaults (0x01) - pop and save (transfer ownership to func)
    test ecx, MAKE_FUNC_DEFAULTS
    jz .mf_no_defaults
    VPOP rdi
    mov [rbp - MF_DEFAULTS], rdi
.mf_no_defaults:

    ; Create function: func_new(code, globals)
    mov rdi, [rbp - MF_CODE]
    mov rsi, [r12 + PyFrame.globals]
    call func_new
    ; rax = new function object

    ; Set closure if present
    mov rcx, [rbp - MF_CLOSURE]
    mov [rax + PyFuncObject.func_closure], rcx

    ; Set defaults if present (transfer ownership, no INCREF needed)
    mov rcx, [rbp - MF_DEFAULTS]
    mov [rax + PyFuncObject.func_defaults], rcx

    ; Set kwdefaults if present (transfer ownership, no INCREF needed)
    mov rcx, [rbp - MF_KWDEFS]
    mov [rax + PyFuncObject.func_kwdefaults], rcx

    ; Save func obj, DECREF the code object (tag-aware)
    push rax
    mov rdi, [rbp - MF_CODE]
    mov rsi, [rbp - MF_CTAG]
    DECREF_VAL rdi, rsi
    pop rax

    ; Push function onto value stack
    VPUSH_PTR rax
    leave
    DISPATCH
END_FUNC op_make_function

;; ============================================================================
;; op_call_function_ex - Call with *args and optional **kwargs
;;
;; Python 3.12 CALL_FUNCTION_EX (opcode 142).
;; arg & 1: kwargs dict is present on TOS
;;
;; Stack layout (bottom to top):
;;   ... | func | NULL | args_tuple | [kwargs_dict]
;;
;; After: ... | result
;; ============================================================================
extern tuple_type
extern dict_type

; Additional frame slots for kwargs merging
CFX_TPCALL  equ 72
CFX_NPOS    equ 80
CFX_NKW     equ 88
CFX_MERGED  equ 96       ; merged args buffer (heap ptr)
CFX_KWNAMES equ 104      ; kw_names tuple
CFX_RETTAG  equ 112      ; return tag from tp_call
CFX_TEMP    equ 120      ; temp args buffer for fat tuple extraction
CFX_FUNC_TAG equ 128     ; func tag for SmallInt check
CFX_FRAME2  equ 136      ; new frame size (manual push, so offset from rbp-16)

DEF_FUNC op_call_function_ex
    push rbx                        ; save (clobbered by eval convention save)
    push r12
    sub rsp, CFX_FRAME2 - 16       ; allocate local frame

    mov [rbp - CFX_OPARG], ecx               ; save oparg
    mov qword [rbp - CFX_TEMP], 0             ; no temp buffer yet

    ; Pop kwargs if present
    mov qword [rbp - CFX_KWARGS], 0
    test ecx, 1
    jz .cfex_no_kwargs
    VPOP rax
    mov [rbp - CFX_KWARGS], rax               ; kwargs dict
.cfex_no_kwargs:

    ; Pop args tuple
    VPOP rax
    mov [rbp - CFX_ARGS], rax

    ; Pop func
    VPOP_VAL rax, rdx
    mov [rbp - CFX_FUNC], rax
    mov [rbp - CFX_FUNC_TAG], rdx

    ; Pop NULL (unused, 16 bytes/slot)
    VPOP rax

    ; Get tp_call from func's type
    mov rdi, [rbp - CFX_FUNC]
    test rdi, rdi
    jz .cfex_not_callable
    cmp qword [rbp - CFX_FUNC_TAG], TAG_PTR
    jne .cfex_not_callable
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .cfex_not_callable
    mov [rbp - CFX_TPCALL], rax

    ; Check if we have kwargs to merge
    mov rdi, [rbp - CFX_KWARGS]
    test rdi, rdi
    jnz .cfex_merge_kwargs

.cfex_empty_kwargs:
    ; No kwargs (or empty kwargs dict) — simple path: call with positional args only
    mov rsi, [rbp - CFX_ARGS]                  ; args sequence
    mov rcx, [rsi + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    je .cfex_tuple_args
    ; List: extract payload+tag to temp fat array
    mov rcx, [rsi + PyListObject.ob_size]
    mov rbx, [rsi + PyListObject.ob_item_tags]
    mov rsi, [rsi + PyListObject.ob_item]
    jmp .cfex_extract_fat

.cfex_tuple_args:
    ; Tuple: extract payload+tag to temp fat array
    mov rcx, [rsi + PyTupleObject.ob_size]
    mov rbx, [rsi + PyTupleObject.ob_item_tags]
    mov rsi, [rsi + PyTupleObject.ob_item]

.cfex_extract_fat:
    ; rsi = payloads ptr, rbx = tags ptr, rcx = count
    push rsi                       ; save items ptr
    push rcx                       ; save count
    mov rdi, rcx
    shl rdi, 4                     ; count * 16
    add rdi, 16                    ; alloc size (16B per arg + pad)
    call ap_malloc
    mov [rbp - CFX_TEMP], rax      ; save temp buffer
    mov [rel cfex_temp_pending], rax  ; register for exception cleanup
    pop rcx                        ; restore count
    pop rsi                        ; restore items ptr
    xor edx, edx
.cfex_extract_loop:
    cmp rdx, rcx
    jge .cfex_extract_done
    mov r8, [rsi + rdx * 8]        ; payload
    movzx r9d, byte [rbx + rdx]    ; tag
    mov rdi, [rbp - CFX_TEMP]
    mov r10, rdx
    shl r10, 4                     ; dest offset * 16
    mov [rdi + r10], r8            ; store payload at 16B stride
    mov [rdi + r10 + 8], r9       ; store tag
    inc rdx
    jmp .cfex_extract_loop
.cfex_extract_done:
    mov rsi, [rbp - CFX_TEMP]      ; use temp buffer as args
.cfex_args_ready:
    ; Clear cfex_temp_pending BEFORE the call, so exception unwind
    ; won't free it (we free it ourselves in the normal path below).
    mov qword [rel cfex_temp_pending], 0
    mov rdx, [rbp - CFX_ARGS]
    mov rdx, [rdx + PyVarObject.ob_size]
    mov rdi, [rbp - CFX_FUNC]
    mov rax, [rbp - CFX_TPCALL]
    call rax
    mov [rbp - CFX_RESULT], rax
    mov [rbp - CFX_RETTAG], rdx

    ; Free temp args if allocated
    mov rdi, [rbp - CFX_TEMP]
    test rdi, rdi
    jz .cfex_cleanup
    push rax
    push rdx
    call ap_free
    pop rdx
    pop rax
    jmp .cfex_cleanup

.cfex_merge_kwargs:
    ; --- Merge positional args + keyword args ---
    ; Get n_kw from kwargs dict — if empty, take simple path
    mov rax, [rbp - CFX_KWARGS]
    mov rcx, [rax + PyDictObject.ob_size]
    test rcx, rcx
    jz .cfex_empty_kwargs          ; empty dict → treat as no kwargs
    mov [rbp - CFX_NKW], rcx

    ; Get n_pos from args tuple
    mov rax, [rbp - CFX_ARGS]
    mov rcx, [rax + PyVarObject.ob_size]
    mov [rbp - CFX_NPOS], rcx

    ; Allocate merged args buffer: (n_pos + n_kw) * 16
    mov rdi, [rbp - CFX_NPOS]
    add rdi, [rbp - CFX_NKW]
    shl rdi, 4                    ; * 16 bytes per fat arg
    test rdi, rdi
    jnz .cfex_alloc_merged
    mov rdi, 16                   ; minimum 16 bytes
.cfex_alloc_merged:
    call ap_malloc
    mov [rbp - CFX_MERGED], rax
    mov [rel cfex_merged_pending], rax  ; register for exception cleanup

    ; Copy positional args from tuple to merged buffer
    mov rsi, [rbp - CFX_ARGS]
    mov rcx, [rsi + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    je .cfex_merge_tuple_src
    mov rbx, [rsi + PyListObject.ob_item_tags]
    mov rsi, [rsi + PyListObject.ob_item]
    jmp .cfex_merge_copy_pos
.cfex_merge_tuple_src:
    mov rbx, [rsi + PyTupleObject.ob_item_tags]
    mov rsi, [rsi + PyTupleObject.ob_item]
.cfex_merge_copy_pos:
    mov rdi, [rbp - CFX_MERGED]
    mov rcx, [rbp - CFX_NPOS]
    test rcx, rcx
    jz .cfex_pos_copied
    xor edx, edx
.cfex_copy_pos_loop:
    mov r8, [rsi + rdx * 8]       ; payload
    movzx r9d, byte [rbx + rdx]   ; tag
    mov r10, rdx
    shl r10, 4                    ; *16 for merged buffer
    mov [rdi + r10], r8           ; store payload at 16B stride
    mov [rdi + r10 + 8], r9      ; store tag
    inc rdx
    cmp rdx, rcx
    jb .cfex_copy_pos_loop
.cfex_pos_copied:

    ; Create kw_names tuple
    mov rdi, [rbp - CFX_NKW]
    call tuple_new
    mov [rbp - CFX_KWNAMES], rax
    mov [rel cfex_kwnames_pending], rax  ; register for exception cleanup

    ; Iterate kwargs dict entries, copy values to merged buffer and keys to kw_names
    mov r12, [rbp - CFX_KWARGS]
    mov rbx, [r12 + PyDictObject.entries]
    mov ecx, 0                   ; dict scan index
    xor edx, edx                 ; kw output index (0..n_kw-1)

.cfex_dict_scan:
    cmp rcx, [r12 + PyDictObject.capacity]
    jge .cfex_dict_done

    ; Check if entry at index has key and value_tag != TAG_NULL
    imul rax, rcx, DictEntry_size
    add rax, rbx
    mov rsi, [rax + DictEntry.key]
    test rsi, rsi
    jz .cfex_dict_skip
    cmp byte [rax + DictEntry.value_tag], 0
    je .cfex_dict_skip
    mov rdi, [rax + DictEntry.value]

    ; Store value in merged buffer at position [n_pos + kw_idx]
    ; Also read value_tag from dict entry for fat arg
    push rcx
    push rdx
    mov rcx, [rbp - CFX_NPOS]
    add rcx, rdx                 ; merged index = n_pos + kw_idx
    shl rcx, 4                   ; * 16 for fat args
    mov rax, [rbp - CFX_MERGED]
    mov [rax + rcx], rdi         ; merged[n_pos + kw_idx].payload = value
    ; Read value_tag — rax from earlier imul still points to entry (but was clobbered)
    ; Recalculate entry pointer
    mov r8, [rsp + 8]           ; restore dict scan index (pushed rcx)
    imul r8, r8, DictEntry_size
    add r8, rbx                  ; r8 = entry ptr
    movzx r9d, byte [r8 + DictEntry.value_tag]
    mov [rax + rcx + 8], r9     ; merged[...].tag = value_tag

    ; Store key in kw_names tuple at kw_idx (fat: *16 + TAG_PTR)
    mov rax, [rbp - CFX_KWNAMES]
    mov r8, [rax + PyTupleObject.ob_item]       ; payloads
    mov r9, [rax + PyTupleObject.ob_item_tags]  ; tags
    mov [r8 + rdx * 8], rsi                     ; payload
    mov byte [r9 + rdx], TAG_PTR                ; tag
    INCREF rsi                   ; tuple owns a ref
    pop rdx
    pop rcx
    inc edx                      ; next kw slot

.cfex_dict_skip:
    inc ecx
    jmp .cfex_dict_scan

.cfex_dict_done:
    ; Set kw_names_pending for the callee
    mov rax, [rbp - CFX_KWNAMES]
    mov [rel kw_names_pending], rax

    ; Call tp_call(func, merged_args, n_pos + n_kw)
    mov rdi, [rbp - CFX_FUNC]
    mov rsi, [rbp - CFX_MERGED]
    mov rdx, [rbp - CFX_NPOS]
    add rdx, [rbp - CFX_NKW]
    mov rax, [rbp - CFX_TPCALL]
    call rax
    mov [rbp - CFX_RESULT], rax
    mov [rbp - CFX_RETTAG], rdx

    ; Clear kw_names_pending
    mov qword [rel kw_names_pending], 0

    ; Free merged buffer and clear pending
    mov qword [rel cfex_merged_pending], 0
    mov rdi, [rbp - CFX_MERGED]
    call ap_free

    ; DECREF kw_names tuple and clear pending
    mov qword [rel cfex_kwnames_pending], 0
    mov rdi, [rbp - CFX_KWNAMES]
    call obj_decref

    jmp .cfex_cleanup_shared

.cfex_cleanup:
    ; Clear kw_names_pending (safety)
    mov qword [rel kw_names_pending], 0

.cfex_cleanup_shared:
    ; DECREF args tuple
    mov rdi, [rbp - CFX_ARGS]
    call obj_decref

    ; DECREF kwargs if present
    mov rdi, [rbp - CFX_KWARGS]
    test rdi, rdi
    jz .cfex_no_kwargs_decref
    call obj_decref
.cfex_no_kwargs_decref:

    ; DECREF func
    mov rdi, [rbp - CFX_FUNC]
    call obj_decref

    ; Check for exception (TAG_NULL return with current_exception set)
    mov rax, [rbp - CFX_RESULT]
    mov rdx, [rbp - CFX_RETTAG]
    test rdx, rdx                    ; TAG_NULL = 0 means error
    jnz .cfex_push_result
    extern current_exception
    mov rcx, [rel current_exception]
    test rcx, rcx
    jnz .cfex_propagate_exc

.cfex_push_result:
    VPUSH_VAL rax, rdx

    add rsp, CFX_FRAME2 - 16
    pop r12
    pop rbx
    pop rbp
    DISPATCH

.cfex_propagate_exc:
    ; Exception pending from callee — propagate to caller's handler
    extern eval_exception_unwind
    add rsp, CFX_FRAME2 - 16
    pop r12
    pop rbx
    pop rbp
    mov [rel eval_saved_r13], r13
    mov [rel eval_saved_r15], r15
    jmp eval_exception_unwind

.cfex_not_callable:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "object is not callable"
    call raise_exception
END_FUNC op_call_function_ex

;; ============================================================================
;; op_before_with - Set up context manager
;;
;; Python 3.12 BEFORE_WITH (opcode 53).
;;
;; Stack: ... | mgr  ->  ... | bound_exit | result_of___enter__()
;;
;; CPython pushes a single bound method for __exit__ (not self+func separately).
;; Stack effect: +1 (pop mgr, push exit_method + enter_result).
;; Exception table depth=1 preserves just the exit_method.
;; ============================================================================
extern dict_get
extern str_from_cstr_heap
extern exc_AttributeError_type
extern method_new

DEF_FUNC op_before_with
    push rbx
    push r12
    sub rsp, 32

    ; Pop mgr
    VPOP_VAL rax, rdx
    mov [rbp - BW_MGR], rax
    mov rbx, rax                    ; rbx = mgr

    ; Look up __exit__ on mgr's type
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_dict]
    test rax, rax
    jz .bw_no_exit

    ; Get "__exit__" from type dict (heap — dict key, DECREFed)
    lea rdi, [rel bw_str_exit]
    call str_from_cstr_heap
    mov r12, rax                    ; r12 = exit name str
    mov rdi, [rbx + PyObject.ob_type]
    mov rdi, [rdi + PyTypeObject.tp_dict]
    mov rsi, r12
    mov edx, TAG_PTR
    call dict_get
    test edx, edx
    jz .bw_no_exit_decref_name

    ; Got __exit__ function — create bound method(exit_func, mgr)
    mov [rbp - BW_EXIT], rax
    mov rdi, r12
    call obj_decref                 ; DECREF exit name string

    mov rdi, [rbp - BW_EXIT]       ; func
    mov rsi, [rbp - BW_MGR]        ; self = mgr
    call method_new                 ; rax = bound exit method
    mov [rbp - BW_EXIT], rax

    ; Push bound __exit__ method (single item, matching CPython)
    VPUSH_PTR rax

    ; Now look up __enter__ on mgr's type
    mov rdi, [rbx + PyObject.ob_type]
    mov rdi, [rdi + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .bw_no_enter

    lea rdi, [rel bw_str_enter]
    call str_from_cstr_heap
    mov r12, rax                    ; r12 = enter name str
    mov rdi, [rbx + PyObject.ob_type]
    mov rdi, [rdi + PyTypeObject.tp_dict]
    mov rsi, r12
    mov edx, TAG_PTR
    call dict_get
    test edx, edx
    jz .bw_no_enter_decref_name

    ; Got __enter__ function - call it with mgr as self
    push rax                        ; save func
    mov rdi, r12
    call obj_decref                 ; DECREF enter name
    pop rax                         ; restore func

    ; Call __enter__(mgr): tp_call(enter_func, &mgr, 1)
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .bw_no_enter

    ; Set up call: build fat arg on stack
    mov r8, [rbp - BW_MGR]
    SPUSH_PTR r8                   ; args[0] = mgr
    mov rdi, rax                   ; callable = __enter__
    mov rsi, rsp                   ; args ptr
    mov rdx, 1                     ; nargs = 1
    call rcx
    add rsp, 16                    ; pop fat arg
    mov [rbp - BW_ENTER], rax              ; save __enter__ result
    mov [rbp - BW_RETTAG], rdx             ; save __enter__ result tag

    ; DECREF mgr
    mov rdi, [rbp - BW_MGR]
    call obj_decref

    ; Push __enter__ result
    mov rax, [rbp - BW_ENTER]
    mov rdx, [rbp - BW_RETTAG]
    VPUSH_VAL rax, rdx

    add rsp, 32
    pop r12
    pop rbx
    pop rbp
    DISPATCH

.bw_no_exit_decref_name:
    mov rdi, r12
    call obj_decref
.bw_no_exit:
    lea rdi, [rel exc_AttributeError_type]
    CSTRING rsi, "__exit__"
    call raise_exception

.bw_no_enter_decref_name:
    mov rdi, r12
    call obj_decref
.bw_no_enter:
    lea rdi, [rel exc_AttributeError_type]
    CSTRING rsi, "__enter__"
    call raise_exception
END_FUNC op_before_with

section .rodata
bw_str_exit:  db "__exit__", 0
bw_str_enter: db "__enter__", 0
section .text

;; ============================================================================
;; op_with_except_start - Call __exit__ with exception info
;;
;; Python 3.12 WITH_EXCEPT_START (opcode 49).
;;
;; Stack: ... | bound_exit | lasti | prev_exc | val  ->
;;        ... | bound_exit | lasti | prev_exc | val | result
;;
;; bound_exit is a bound method (__exit__ with self baked in).
;; Calls bound_exit(exc_type, exc_val, exc_tb) via tp_call (method_call
;; prepends self automatically).
;; Push result of __exit__ call.
;; ============================================================================
extern none_singleton

DEF_FUNC op_with_except_start, WES_FRAME

    ; Stack layout (TOS is rightmost, payload slots):
    ; PEEK(1) = val (exception)          = [r13-8]
    ; PEEK(2) = prev_exc                = [r13-16]
    ; PEEK(3) = lasti                    = [r13-24]
    ; PEEK(4) = bound_exit              = [r13-32]

    mov rax, [r13-32]               ; bound_exit method
    mov [rbp - WES_FUNC], rax
    mov rax, [r13-8]                ; val (exception value)
    mov [rbp - WES_VAL], rax

    ; Get tp_call on bound_exit (should be method_call)
    mov rdi, [rbp - WES_FUNC]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .wes_error

    ; Build args array: [exc_type, exc_val, exc_tb]
    ; method_call will prepend self automatically
    mov rcx, [rbp - WES_VAL]               ; val
    sub rsp, 48                      ; 3 fat args (16 bytes each)
    ; Get type of exception
    test rcx, rcx
    jz .wes_none_exc
    cmp byte [r15 - 1], TAG_SMALLINT       ; val tag from stack
    je .wes_none_exc
    ; Exception case
    mov rdx, [rcx + PyObject.ob_type]
    mov [rsp], rdx                   ; exc_type payload
    mov qword [rsp + 8], TAG_PTR     ; exc_type tag
    mov [rsp + 16], rcx              ; exc_val payload
    mov qword [rsp + 24], TAG_PTR    ; exc_val tag
    jmp .wes_set_tb
.wes_none_exc:
    lea rdx, [rel none_singleton]
    mov [rsp], rdx                   ; exc_type = None
    mov qword [rsp + 8], TAG_PTR     ; exc_type tag
    mov [rsp + 16], rdx              ; exc_val = None
    mov qword [rsp + 24], TAG_PTR    ; exc_val tag
.wes_set_tb:
    lea rdx, [rel none_singleton]
    mov [rsp + 32], rdx              ; exc_tb = None
    mov qword [rsp + 40], TAG_PTR    ; exc_tb tag

    ; Call bound_exit(exc_type, exc_val, exc_tb)
    mov rdi, [rbp - WES_FUNC]                 ; callable = bound method
    mov rsi, rsp                     ; args ptr
    mov rdx, 3                       ; nargs = 3 (method_call adds self)
    call rax
    add rsp, 48
    mov [rbp - WES_RESULT], rax                ; save result
    mov [rbp - WES_RETTAG], rdx                ; save result tag

    ; Push result onto value stack
    mov rax, [rbp - WES_RESULT]
    mov rdx, [rbp - WES_RETTAG]
    VPUSH_VAL rax, rdx

    leave
    DISPATCH

.wes_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "__exit__ is not callable"
    call raise_exception
END_FUNC op_with_except_start
