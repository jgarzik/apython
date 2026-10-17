; opcodes/call.asm - Opcode handler for CALL (Python 3.12)
;
; Register convention (callee-saved, preserved across handlers):
;   rbx = bytecode instruction pointer (current position in co_code[])
;   r12 = current frame pointer (PyFrame*)
;   r13 = value stack payload top pointer
;
; ecx = opcode argument on entry (set by eval_dispatch)
; rbx has already been advanced past the 2-byte instruction word.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

section .text

extern eval_dispatch
extern eval_saved_r13
extern obj_dealloc
extern obj_decref
extern raise_exception
extern func_new
extern exc_TypeError_type
extern str_type
extern exc_SystemError_type
extern current_exception
extern eval_exception_unwind
extern kw_names_pending
extern func_type
extern cfex_temp_pending
extern cfex_merged_pending
extern cfex_kwnames_pending
extern ap_malloc
extern ap_free
extern tuple_new
extern eval_saved_rbx
extern opcode_table
extern opcode_dispatch_table

; --- Named frame-layout constants ---

; op_call locals (DEF_FUNC op_call, CL_FRAME)
CL_NARGS     equ 8
CL_CALLABLE  equ 16
CL_RETVAL    equ 24
CL_IS_METHOD equ 32
CL_TOTAL     equ 40
CL_SAVED_RSP equ 48
CL_TPCALL    equ 56
CL_CFUNC     equ 64            ; the C function, while sys.setprofile is on
CL_CALL_TAG  equ 72            ; spare: the callable is classified in place
CL_SAVED_R13 equ 80
CL_FRAME     equ 104         ; + 0 pushes = 96

; op_make_function locals (DEF_FUNC op_make_function, MF_FRAME)
MF_FLAGS   equ 8
MF_CODE    equ 16
MF_CLOSURE equ 24
MF_DEFAULTS equ 32
MF_KWDEFS  equ 40
MF_CTAG    equ 48
MF_ANNOS   equ 56
MF_FRAME   equ 72           ; + 0 pushes = 64

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
WES_VAL    equ 24
WES_RESULT equ 32
WES_RETTAG equ 40
WES_FRAME  equ 56           ; + 0 pushes = 48

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
    ; Specialize, then run generically this time.  A plain Python function
    ; whose parameters are exactly filled is the shape almost every call has,
    ; and the specialized handler needs neither this frame nor func_call's.
    ;
    ; Checked here rather than in the specialized handler alone so that a site
    ; which will never qualify -- a builtin, a class, a callable instance --
    ; is not rewritten and immediately deopted on every execution.
    cmp qword [rel kw_names_pending], 0
    jne .cl_no_spec
    mov r8d, ecx
    add r8d, 2
    neg r8
    mov r9, [r13 + r8*8]                ; func_or_null
    mov r10d, ecx
    test r9, r9
    jz .cl_spec_plain
    inc r10d
    jmp .cl_spec_callable
.cl_spec_plain:
    mov r8d, ecx
    inc r8d
    neg r8
    mov r9, [r13 + r8*8]
.cl_spec_callable:
    V_TEST_PTR r9, rax
    ja .cl_no_spec
    lea rax, [rel func_type]
    cmp [r9 + PyObject.ob_type], rax
    jne .cl_no_spec
    mov rax, [r9 + PyFuncObject.func_code]
    cmp r10d, [rax + PyCodeObject.co_argcount]
    jne .cl_no_spec
    cmp dword [rax + PyCodeObject.co_kwonlyargcount], 0
    jne .cl_no_spec
    test dword [rax + PyCodeObject.co_flags], \
         CO_VARARGS | CO_VARKEYWORDS | CO_GENERATOR | CO_COROUTINE | \
         CO_ASYNC_GENERATOR
    jnz .cl_no_spec
    mov byte [rbx - 2], OP_CALL_PY_EXACT
.cl_no_spec:


    ; Save value stack pointers in case callee clobbers callee-saved regs
    mov [rbp - CL_SAVED_R13], r13

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
    mov qword [rbp - CL_IS_METHOD], 1          ; is_method = 1
    jmp .setup_call

.func_call:
    ; === Function call: callable is in the shallower slot ===
    mov rax, rcx
    inc rax
    neg rax
    lea rdi, [r13 + rax*8]
    mov rdi, [rdi]
    mov [rbp - CL_CALLABLE], rdi               ; callable = callable_or_self

.setup_call:
    ; Get tp_call from the callable's type
    mov rdi, [rbp - CL_CALLABLE]              ; callable
    test rdi, rdi
    jz .not_callable               ; NULL check
    ; V_TAG_OF used to derive the callable's tag here -- the whole six-compare
    ; classify -- and store it, so that this could compare it against TAG_PTR
    ; and .not_callable could V_PACK it back into the Value it already was.
    ; One test answers both questions: NULL and every immediate fail it.
    V_TEST_PTR rdi, rax
    ja .not_callable
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
    V_UNPACK rax, rdx           ; returns a Value
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
    ; Save dunder_func in the frame, and keep the original
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
    ; The arguments are already a contiguous Value array on the value stack,
    ; so tp_call gets a pointer straight into it — no copy.
    mov rcx, [rbp - CL_TOTAL]              ; total nargs
    mov rax, rcx
    neg rax
    lea rax, [r13 + rax*8]                 ; deepest arg = args base
    mov [rbp - CL_SAVED_RSP], rax
.args_ready:
    ; sys.setprofile's c_call / c_return / c_exception.  One load and one
    ; never-taken branch on the hottest opcode there is; without them
    ; profile.py charges every builtin's time to its caller.  systrace_c_callable
    ; answers 0 for everything that is not a C function, which includes every
    ; Python call, so the second branch is free too.
    extern sys_profilefunc
    cmp qword [rel sys_profilefunc], 0
    jne .call_profiled
.call_unprofiled:
    mov rdi, [rbp - CL_CALLABLE]           ; callable
    mov rsi, [rbp - CL_SAVED_RSP]          ; args_ptr
    mov rdx, [rbp - CL_TOTAL]              ; total nargs
    mov rax, [rbp - CL_TPCALL]             ; tp_call
    call rax
    mov [rbp - CL_RETVAL], rax             ; the Value tp_call returned
    jmp .cleanup

.call_profiled:
    mov rdi, [rbp - CL_CALLABLE]
    extern systrace_c_callable
    call systrace_c_callable
    mov [rbp - CL_CFUNC], rax
    test rax, rax
    jz .call_unprofiled
    mov rdi, rax
    xor esi, esi                            ; c_call
    extern systrace_c_event
    call systrace_c_event

    mov rdi, [rbp - CL_CALLABLE]
    mov rsi, [rbp - CL_SAVED_RSP]
    mov rdx, [rbp - CL_TOTAL]
    mov rax, [rbp - CL_TPCALL]
    call rax
    mov [rbp - CL_RETVAL], rax

    mov rdi, [rbp - CL_CFUNC]
    mov esi, 1                              ; c_return
    test rax, rax
    jnz .call_prof_done
    mov esi, 2                              ; c_exception: a NULL Value
.call_prof_done:
    call systrace_c_event
    jmp .cleanup

.cleanup:
    ; Restore value stack pointers (defensive against callee clobber)
    mov r13, [rbp - CL_SAVED_R13]

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
    ; One classify per argument per call, to feed DECREF_VAL a tag it does not
    ; need -- the two slots popped just below have always used the Value form.
    VPOP rdi
    mov [rbp - CL_NARGS], rcx     ; save loop counter (DECREF_V may call obj_dealloc)
    DECREF_V rdi, rsi
    mov rcx, [rbp - CL_NARGS]     ; restore loop counter
    dec rcx
    jnz .decref_args
.args_done:

    ; Pop shallower slot (self for method, callable for function) and DECREF
    VPOP rdi
    DECREF_V rdi, rsi

    ; Pop deeper slot (callable for method, NULL for function) and DECREF
    VPOP rdi
    XDECREF_V rdi, rsi
    ; Check for exception (a NULL return with current_exception set).  The
    ; comment here used to say the TAG had to be tested rather than the
    ; payload, "because None and SmallInt(0) have payload=0".  Neither is true
    ; of a Value: None is a pointer and integer 0 encodes as V_INT_BIAS, so 0
    ; is NULL and nothing else.
    mov rax, [rbp - CL_RETVAL]
    test rax, rax
    jnz .push_result
    extern current_exception
    mov rcx, [rel current_exception]
    test rcx, rcx
    jnz .propagate_exc

.push_result:
    ; Push the return Value (rax already loaded)
    VPUSH rax

    ; Skip 3 CACHE entries (6 bytes)
    add rbx, 6

    leave
    ; A call is where a signal arrives: the process was inside a syscall, and
    ; this is the instruction that made it.  CPython checks the eval breaker
    ; here for the same reason.
    CHECK_EVAL_SIGNALS
    DISPATCH

.propagate_exc:
    ; Exception pending from callee — propagate to caller's handler
    extern eval_exception_unwind
    leave
    mov [rel eval_saved_r13], r13  ; update — cleanup already popped/DECREF'd args
    jmp eval_exception_unwind

.not_callable:
    ; CPython names the type: "'int' object is not callable" is what tells a
    ; caller WHICH of its values was not a function.
    mov rsi, [rbp - CL_CALLABLE]    ; already a Value
    CSTRING rdi, `'\x01' object is not callable`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
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
;;   annotations (if flag 0x04) - a tuple of alternating name and value
;;   closure tuple (if flag 0x08)
;;   code_obj (always on top)
;; ============================================================================
DEF_FUNC op_make_function, MF_FRAME

    mov [rbp - MF_FLAGS], ecx               ; save flags
    mov qword [rbp - MF_CLOSURE], 0          ; closure = NULL default
    mov qword [rbp - MF_DEFAULTS], 0          ; defaults = NULL default
    mov qword [rbp - MF_KWDEFS], 0          ; kwdefaults = NULL default
    mov qword [rbp - MF_ANNOS], 0           ; annotations = NULL default

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

    ; annotations (0x04) - pop and save (transfer ownership to func).  It was
    ; popped and thrown away, so every function in the process reported no
    ; __annotations__ at all -- and functools.singledispatch's `@register` on
    ; an annotated function reads exactly that to find the type to dispatch
    ; on, which is how one missing attribute stopped importlib.resources.
    test ecx, MAKE_FUNC_ANNOTATIONS
    jz .mf_no_annotations
    VPOP rdi
    mov [rbp - MF_ANNOS], rdi
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

    ; Set annotations if present (transfer ownership, no INCREF needed)
    mov rcx, [rbp - MF_ANNOS]
    mov [rax + PyFuncObject.func_annotations], rcx

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

; Additional frame slots for kwargs merging
CFX_TPCALL  equ 72
CFX_NPOS    equ 80
CFX_NKW     equ 88
CFX_MERGED  equ 96       ; merged args buffer (heap ptr)
CFX_KWNAMES equ 104      ; kw_names tuple
CFX_RETTAG  equ 112      ; return tag from tp_call
CFX_TEMP    equ 120      ; temp args buffer for fat tuple extraction
CFX_FUNC_TAG equ 128     ; func tag for SmallInt check
CFX_FRAME2  equ 144      ; new frame size (manual push, so offset from rbp-16)
; What the prologue actually subtracts.  A handler is JUMPED to, so rsp
; arrives 16-aligned and `push rbp` plus two more pushes leave it 8 out; the
; carve has to be odd-by-eight to put it back.  It was CFX_FRAME2 - 16, which
; is even, so every call this handler made was misaligned -- and so was every
; frame the called function ran, since the misalignment propagates.  The slots
; are addressed off rbp and do not move; only this number and the two matching
; `add rsp` do.
CFX_CARVE   equ CFX_FRAME2 - 8

DEF_FUNC op_call_function_ex
    push rbx                        ; save (clobbered by eval convention save)
    push r12
    sub rsp, CFX_CARVE             ; allocate local frame

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

    ; Normalize the argument sequence.  CPython emits CALL_FUNCTION_EX with
    ; whatever iterable the * was applied to -- f(*aset), f(*"ab"), f(*gen),
    ; f(*range(3)) all arrive here as-is.  Only tuple and list carry an
    ; ob_item array that can be handed straight to tp_call; the old code
    ; assumed "not a tuple" meant "a list" and read [obj+16] as the argument
    ; count and [obj+32] as the Value array, which is memory corruption on
    ; every other type and a plain dereference of the payload for f(*5).
    V_TEST_PTR_M [rbp - CFX_ARGS], rcx
    ja .cfex_star_not_iterable      ; an immediate is never iterable
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    je .cfex_args_ok
    extern list_type
    lea rdx, [rel list_type]
    cmp rcx, rdx
    je .cfex_args_ok
    ; A type with neither tp_iter nor sq_item is refused HERE rather than by
    ; the materialisation below, because CPython's check_args_iterable runs
    ; before the conversion and so has the callable to name: `f(*5)` is
    ; "__main__.f() argument after * must be an iterable, not int" and not the
    ; anonymous "'int' object is not iterable" the iterator protocol words.
    ; The callable is on the value stack -- args has just been popped, so it
    ; is TOS -- and is still owned by the frame.
    cmp qword [rcx + PyTypeObject.tp_iter], 0
    jne .cfex_materialise
    mov rdx, [rcx + PyTypeObject.tp_as_sequence]
    test rdx, rdx
    jz .cfex_star_try_mapping
    cmp qword [rdx + PySequenceMethods.sq_item], 0
    jne .cfex_materialise
.cfex_star_try_mapping:
    ; CPython asks PySequence_Check, which is sq_item alone -- but a class
    ; whose only indexing dunder is __getitem__ gets mp_subscript here and no
    ; sq_item, and `f(*obj)` over such a class is legal: the iterator protocol
    ; falls back to indexing from 0 until IndexError.
    mov rdx, [rcx + PyTypeObject.tp_as_mapping]
    test rdx, rdx
    jz .cfex_star_not_iterable
    cmp qword [rdx + PyMappingMethods.mp_subscript], 0
    je .cfex_star_not_iterable

.cfex_materialise:
    ; Anything else: materialise it through the iterator protocol.  This
    ; raises for a non-iterable, which is what CPython does too.
    extern tuple_type_call
    lea rdi, [rel tuple_type]
    lea rsi, [rbp - CFX_ARGS]
    mov edx, 1
    call tuple_type_call
    test rax, rax
    jz .cfex_args_raised
    mov rdi, [rbp - CFX_ARGS]       ; the original iterable, still owned
    mov [rbp - CFX_ARGS], rax
    call obj_decref
.cfex_args_ok:

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
    ; No kwargs (or empty kwargs dict) — simple path: call with positional args
    ; only.  A list's and a tuple's ob_item are both already a contiguous
    ; Value array, which is exactly what tp_call wants, so pass it straight in.
    mov rsi, [rbp - CFX_ARGS]                  ; args sequence
    mov rcx, [rsi + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    je .cfex_tuple_args
    mov rsi, [rsi + PyListObject.ob_item]
    jmp .cfex_args_ready

.cfex_tuple_args:
    mov rsi, [rsi + PyTupleObject.ob_item]

.cfex_args_ready:
    ; Clear cfex_temp_pending BEFORE the call, so exception unwind
    ; won't free it (we free it ourselves in the normal path below).
    mov qword [rel cfex_temp_pending], 0
    mov rdx, [rbp - CFX_ARGS]
    mov rdx, [rdx + PyVarObject.ob_size]
    mov rdi, [rbp - CFX_FUNC]
    mov rax, [rbp - CFX_TPCALL]
    call rax
    V_UNPACK rax, rdx           ; tp_call returns a Value
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

    ; Every key has to be a string, and CPython refuses a call where one is
    ; not before anything else happens.  DictEntry.key is a full Value and a
    ; dict takes any hashable key, so `f(**{1: 2})` put an int IMMEDIATE in
    ; the names tuple and the INCREF below wrote through the number itself --
    ; one line of Python, and a segfault.  Checked here, before the merged
    ; buffer and the names tuple exist, so the refusal has nothing to release.
    mov rsi, [rbp - CFX_KWARGS]
    mov r8, [rsi + PyDictObject.entries]
    mov r9, [rsi + PyDictObject.capacity]
    xor ecx, ecx
.cfex_kwkey_scan:
    cmp rcx, r9
    jge .cfex_kwkeys_ok
    imul rax, rcx, DictEntry_size
    mov rax, [r8 + rax + DictEntry.key]
    test rax, rax
    jz .cfex_kwkey_next            ; empty slot or a tombstone
    V_TEST_PTR rax, rdx
    ja .cfex_kwkey_bad
    mov rdx, [rax + PyObject.ob_type]
    lea rdi, [rel str_type]
    cmp rdx, rdi
    je .cfex_kwkey_next
    ; A str SUBCLASS is a string, which is what CPython's check accepts.
    test qword [rdx + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .cfex_kwkey_bad
.cfex_kwkey_next:
    inc rcx
    jmp .cfex_kwkey_scan
.cfex_kwkey_bad:
    RAISE exc_TypeError_type, "keywords must be strings"
.cfex_kwkeys_ok:

    ; Get n_pos from args tuple
    mov rax, [rbp - CFX_ARGS]
    mov rcx, [rax + PyVarObject.ob_size]
    mov [rbp - CFX_NPOS], rcx

    ; Allocate merged args buffer: (n_pos + n_kw) Values
    mov rdi, [rbp - CFX_NPOS]
    add rdi, [rbp - CFX_NKW]
    shl rdi, 3
    test rdi, rdi
    jnz .cfex_alloc_merged
    mov edi, 8                      ; minimum one slot
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
    mov rsi, [rsi + PyListObject.ob_item]
    jmp .cfex_merge_copy_pos
.cfex_merge_tuple_src:
    mov rsi, [rsi + PyTupleObject.ob_item]
.cfex_merge_copy_pos:
    mov rdi, [rbp - CFX_MERGED]
    mov rcx, [rbp - CFX_NPOS]
    test rcx, rcx
    jz .cfex_pos_copied
    xor edx, edx
.cfex_copy_pos_loop:
    mov r8, [rsi + rdx * 8]       ; the argument Value
    mov [rdi + rdx * 8], r8
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
    xor ecx, ecx                    ; dict scan index
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
    mov rdi, [rax + DictEntry.value]

    ; Store value in merged buffer at position [n_pos + kw_idx]
    push rcx
    push rdx
    mov rcx, [rbp - CFX_NPOS]
    add rcx, rdx                 ; merged index = n_pos + kw_idx
    mov rax, [rbp - CFX_MERGED]
    mov [rax + rcx * 8], rdi     ; merged[n_pos + kw_idx] = the value Value

    ; Store key in kw_names tuple at kw_idx
    mov rax, [rbp - CFX_KWNAMES]
    mov r8, [rax + PyTupleObject.ob_item]       ; payloads
    mov [r8 + rdx * 8], rsi
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
    V_UNPACK rax, rdx           ; tp_call returns a Value
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

.cfex_star_not_iterable:
    ; The message names the callee and the type it was handed.  The value
    ; stack still owns func, the NULL under it and the sequence -- this raise
    ; abandons the frame and the unwinder releases all three from
    ; eval_saved_r13, which DISPATCH set before the pops.
    VPEEK rdi
    V_TEST_PTR rdi, rcx
    ja .cfex_args_not_iterable      ; an immediate callable: no name to read
    mov rdi, [rbp - CFX_ARGS]
    V_TEST_PTR rdi, rcx
    jbe .cfex_star_heap
    extern int_type
    extern float_type
    lea rax, [rel int_type]
    V_IS_INT rdi, rcx           ; CF clear (jae) for an int immediate
    jae .cfex_star_named
    lea rax, [rel float_type]
    jmp .cfex_star_named
.cfex_star_heap:
    mov rax, [rdi + PyObject.ob_type]
.cfex_star_named:
    mov rsi, [rax + PyTypeObject.tp_name]
    VPEEK rdi
    CSTRING rdx, " argument after * must be an iterable, not "
    xor ecx, ecx
    ; NO `mov [rel eval_saved_r13], r13` here.  DISPATCH set that global before
    ; this handler popped its three operands, which is exactly what the comment
    ; above relies on; republishing it now would point the unwinder BELOW them
    ; and leak the starred sequence -- measured at 48 bytes per raise.
    extern raise_callable_arg
    add rsp, CFX_CARVE
    pop r12
    pop rbx
    leave
    jmp raise_callable_arg

.cfex_args_not_iterable:
    RAISE exc_TypeError_type, "argument after * must be an iterable"

.cfex_args_raised:
    ; Materialising the iterable raised: a generator that throws part way, an
    ; __iter__ or a __next__ that does.  The NULL used to be stored as the
    ; argument sequence and its ob_type read a few lines below, which is a
    ; dereference of address zero -- `copy.deepcopy(list[T] | int)` reaches it,
    ; and that is two of CPython's test modules.
    ;
    ; func and the NULL under it are still on the value stack; the unwinder
    ; releases them with the rest of the frame, which is why r13 is
    ; republished rather than adjusted here.
    mov rdi, [rbp - CFX_ARGS]
    call obj_decref
    mov qword [rbp - CFX_ARGS], 0
    mov rdi, [rbp - CFX_KWARGS]
    test rdi, rdi
    jz .cfex_ar_no_kwargs
    call obj_decref
    mov qword [rbp - CFX_KWARGS], 0
.cfex_ar_no_kwargs:
    ; A 0 with nothing pending is the allocator failing rather than user code
    ; raising, and the caller still needs to be told something.
    cmp qword [rel current_exception], 0
    je .cfex_args_not_iterable
    add rsp, CFX_CARVE
    pop r12
    pop rbx
    pop rbp
    mov [rel eval_saved_r13], r13
    jmp eval_exception_unwind

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

    add rsp, CFX_CARVE
    pop r12
    pop rbx
    pop rbp
    DISPATCH

.cfex_propagate_exc:
    ; Exception pending from callee — propagate to caller's handler
    extern eval_exception_unwind
    add rsp, CFX_CARVE
    pop r12
    pop rbx
    pop rbp
    mov [rel eval_saved_r13], r13
    jmp eval_exception_unwind

.cfex_not_callable:
    mov rsi, [rbp - CFX_FUNC]
    mov rcx, [rbp - CFX_FUNC_TAG]
    V_PACK rsi, rcx
    CSTRING rdi, `'\x01' object is not callable`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
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
extern method_new

DEF_FUNC op_before_with
    push rbx
    push r12
    ; 40, not 32: a handler is entered 16-byte ALIGNED, so `push rbp` plus
    ; these two pushes leave rsp 8 out and the frame is what puts it back.
    ; The epilogue below is a hand-written `pop rbp` with no `leave`, so this
    ; and the matching `add rsp` have to move together.
    sub rsp, 40

    ; Pop mgr
    VPOP_VAL rax, rdx
    mov [rbp - BW_MGR], rax
    mov rbx, rax                    ; rbx = mgr

    ; An int or float manager has no type pointer to walk: its payload is a
    ; value, not an address.  `with 5:` dereferenced it.
    cmp edx, TAG_PTR
    jne .bw_not_a_manager

    ; __exit__, through the descriptor protocol -- CPython's
    ; _PyObject_LookupSpecial.  This read the type's OWN tp_dict and called
    ; whatever it found: no MRO walk, and no __get__, so a context manager
    ; whose __exit__ is a descriptor bound the DESCRIPTOR as the method.  For
    ; one with no __call__ that is a jump to a NULL tp_call; unittest.mock's
    ; MagicMock is exactly that shape.
    mov rdi, rbx
    lea rsi, [rel bw_str_exit]
    extern dunder_lookup_special
    call dunder_lookup_special
    test rax, rax
    jnz .bw_exit_bound
    cmp qword [rel current_exception], 0
    jne .bw_lookup_raised

    ; Some types serve their attributes from tp_getattr rather than a type
    ; dict -- a file object is one -- so `with open(...) as f` reported that
    ; a file is not a context manager.
    lea rdi, [rel bw_str_exit]
    call str_from_cstr_heap
    mov r12, rax                    ; r12 = exit name str

.bw_exit_via_getattr:
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_getattr]
    test rax, rax
    jz .bw_no_exit_decref_name
    mov rdi, rbx
    mov rsi, r12
    call rax
    V_UNPACK rax, rdx
    test edx, edx
    jz .bw_no_exit_decref_name
    ; tp_getattr already bound it to the instance.
    mov rdi, r12
    push rax
    push rax                        ; and a pad: the frame above is odd, so a
                                    ; lone push here would misalign this call
    call obj_decref
    pop rax
    pop rax
    VPUSH_PTR rax
    jmp .bw_exit_pushed

.bw_exit_bound:
    ; Already bound, and owned: the value stack takes the reference.
    mov [rbp - BW_EXIT], rax
    VPUSH_PTR rax
.bw_exit_pushed:

    ; __enter__, the same way.
    mov rdi, rbx
    lea rsi, [rel bw_str_enter]
    call dunder_lookup_special
    test rax, rax
    jnz .bw_enter_bound
    cmp qword [rel current_exception], 0
    jne .bw_lookup_raised_after_exit

    lea rdi, [rel bw_str_enter]
    call str_from_cstr_heap
    mov r12, rax                    ; r12 = enter name str

.bw_enter_via_getattr:
    ; As for __exit__: a type may serve its attributes from tp_getattr.
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_getattr]
    test rax, rax
    jz .bw_no_enter_decref_name
    mov rdi, rbx
    mov rsi, r12
    call rax
    V_UNPACK rax, rdx
    test edx, edx
    jz .bw_no_enter_decref_name
    ; Already bound, so it takes no self argument.
    push rax
    push rax                        ; and a pad, as above: this frame is even,
                                    ; so a lone push misaligns the call
    mov rdi, r12
    call obj_decref
    pop rax
    pop rax
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .bw_no_enter
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call rcx
    test rax, rax               ; a NULL Value is a raise -- see .bw_enter_raised
    jz .bw_enter_raised
    V_UNPACK rax, rdx
    mov [rbp - BW_ENTER], rax
    mov [rbp - BW_RETTAG], rdx
    jmp .bw_enter_called

.bw_enter_bound:
    ; Bound and owned, so it takes no self argument and this frame owes it a
    ; release -- r12's name string is not needed on this road.
    mov r12, rax
    V_TEST_PTR r12, rcx
    ja .bw_no_enter
    mov rcx, [r12 + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .bw_no_enter
    mov rdi, r12
    xor esi, esi
    xor edx, edx
    call rcx
    push rax
    push rax                        ; and a pad, as above
    mov rdi, r12
    call obj_decref
    pop rax
    pop rax
    test rax, rax               ; a NULL Value is a raise
    jz .bw_enter_raised
    V_UNPACK rax, rdx           ; tp_call returns a Value
    mov [rbp - BW_ENTER], rax              ; save __enter__ result
    mov [rbp - BW_RETTAG], rdx             ; save __enter__ result tag
.bw_enter_called:

    ; DECREF mgr
    mov rdi, [rbp - BW_MGR]
    call obj_decref

    ; Push __enter__ result
    mov rax, [rbp - BW_ENTER]
    mov rdx, [rbp - BW_RETTAG]
    VPUSH_VAL rax, rdx

    add rsp, 40
    pop r12
    pop rbx
    pop rbp
    DISPATCH

.bw_enter_raised:
    ; __enter__ raised.  CPython's BEFORE_WITH is (mgr -- exit, res) and its
    ; error arm releases the bound __exit__ and pushes nothing, so the block is
    ; entered by nobody.  Pushing the NULL instead let the exception escape the
    ; enclosing `try` altogether: `try: with E(): pass / except ValueError` did
    ; not catch an __enter__ that raised ValueError.
    ;
    ; The test must precede V_UNPACK, which maps NULL and integer 0 to the
    ; same payload.
    mov rax, [rel current_exception]
    test rax, rax
    jz .bw_enter_null_no_exc
    VPOP rdi                        ; the bound __exit__ pushed above
    XDECREF_V rdi, rsi
    mov rdi, [rbp - BW_MGR]         ; and the reference VPOP_VAL took
    call obj_decref
    add rsp, 40
    pop r12
    pop rbx
    pop rbp
    ; r13 is now one slot BELOW what DISPATCH published -- mgr was popped and
    ; the __exit__ that replaced it has been popped too -- so the unwinder
    ; must be told, or its pop loop reads the dead mgr slot as a live Value.
    mov [rel eval_saved_r13], r13
    jmp eval_exception_unwind

.bw_enter_null_no_exc:
    RAISE exc_SystemError_type, "__enter__ returned NULL without setting an exception"

.bw_no_exit_decref_name:
    mov rdi, r12
    call obj_decref
.bw_no_exit:
    ; CPython reports a missing __enter__/__exit__ as a protocol TypeError,
    ; not as a bare AttributeError on the dunder name -- and it names the type.
    ;
    ; It also says WHICH of the two was missing, but only when __enter__ was
    ; there: it looks __enter__ up first, so an object with neither gets the
    ; plain message.  This looks __exit__ up first, because __exit__ is what
    ; goes on the value stack; asking the cheap question again on this one
    ; failing path is what keeps the two wordings apart.
    extern dunder_enter
    mov rdi, [rbx + PyObject.ob_type]
    lea rsi, [rel dunder_enter]
    extern dunder_lookup
    call dunder_lookup
    mov rsi, rbx
    V_TEST_PTR rax, rcx
    ja .bw_no_either
    CSTRING rdi, `'\x01' object does not support the context manager protocol (missed __exit__ method)`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
.bw_no_either:
    CSTRING rdi, `'\x01' object does not support the context manager protocol`
    jmp raise_type_error_with_name

.bw_no_enter_decref_name:
    mov rdi, r12
    call obj_decref
.bw_no_enter:
    ; Every path here is past .bw_exit_pushed, so the bound __exit__ has
    ; already OVERWRITTEN mgr's slot on the value stack: the unwinder gives
    ; back what is in the slot, which is the method, and nobody gives back the
    ; reference VPOP_VAL took on mgr.  .bw_no_exit above needs no such line --
    ; it is reached before the push, with mgr still in its own slot.
    ; COMPOSE FIRST, then release.  The message names the manager's TYPE, and
    ; this decref can be the last one -- an __exit__ bound from a descriptor
    ; whose __get__ answered a module-level function holds no reference to it
    ; -- so naming the type afterwards read a freed object.
    mov rsi, [rbx + PyObject.ob_type]
    CSTRING rdi, `'\x01' object does not support the context manager protocol`
    extern type_name_message
    call type_name_message      ; rax = the composed C string, in a static buffer
    push rax
    push rax
    mov rdi, [rbp - BW_MGR]
    call obj_decref
    pop rsi
    pop rax
    lea rdi, [rel exc_TypeError_type]
    call raise_exception        ; does not return

.bw_lookup_raised_after_exit:
    ; __exit__ is on the value stack in mgr's slot; the unwinder gives that
    ; back, and the reference VPOP_VAL took on mgr is this frame's.
    mov rdi, [rbp - BW_MGR]
    call obj_decref
.bw_lookup_raised:
    ; A __get__ on one of the two raised.  Its exception is the caller's.
    ;
    ; r13 is NOT published here, unlike .bw_enter_raised: reached before the
    ; push, mgr is still in the slot the unwinder will release; reached after
    ; it, __exit__ is, and the arm above has already given mgr back.
    add rsp, 40
    pop r12
    pop rbx
    pop rbp
    jmp eval_exception_unwind

.bw_not_a_manager:
    ; An int, a float or None.  BW_MGR holds the PAYLOAD, not a Value, so the
    ; tag VPOP_VAL left in rdx is what turns it back into one that names a
    ; type -- reading the payload as a pointer is what an int payload is not.
    mov rsi, [rbp - BW_MGR]
    VALUE_FOR_TYPE rsi, rdx
    CSTRING rdi, `'\x01' object does not support the context manager protocol`
    jmp raise_type_error_with_name
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
    sub rsp, 32                      ; 3 Values, rsp stays aligned
    ; Get type of exception
    test rcx, rcx
    jz .wes_none_exc
    V_TEST_PTR rcx, rdx                    ; only a real object can be an exception
    ja .wes_none_exc
    ; Exception case
    mov rdx, [rcx + PyObject.ob_type]
    mov [rsp], rdx                   ; exc_type
    mov [rsp + 8], rcx               ; exc_val
    ; exc_tb is the exception's own __traceback__, as CPython's
    ; PyException_GetTraceback -- not None.  contextlib's __exit__ writes it
    ; back with `exc.__traceback__ = traceback`, so None there wiped every
    ; frame below the `with` from the exception, and pytest reported a
    ; failing test at the line in pluggy that threw it.
    mov rdx, [rcx + PyExceptionObject.exc_tb]
    test rdx, rdx
    jnz .wes_have_tb
    lea rdx, [rel none_singleton]
.wes_have_tb:
    mov [rsp + 16], rdx
    jmp .wes_call
.wes_none_exc:
    lea rdx, [rel none_singleton]
    mov [rsp], rdx                   ; exc_type = None
    mov [rsp + 8], rdx               ; exc_val = None
    mov [rsp + 16], rdx              ; exc_tb = None
.wes_call:

    ; Call bound_exit(exc_type, exc_val, exc_tb)
    mov rdi, [rbp - WES_FUNC]                 ; callable = bound method
    mov rsi, rsp                     ; args ptr
    mov edx, 3                      ; nargs = 3 (method_call adds self)
    call rax
    add rsp, 32

    ; A NULL Value is a raise, not a result.  Test it BEFORE V_UNPACK: that
    ; maps NULL to payload 0 AND integer 0 to payload 0, so after it the two
    ; are indistinguishable.  A raw Value of 0 is NULL and nothing else.
    ;
    ; Pushing it instead is what made an exception raised inside __exit__,
    ; while another was in flight, a SIGSEGV: POP_JUMP_IF_TRUE popped the 0
    ; and obj_is_true dereferenced address 0.  This is CPython's
    ; ERROR_IF(res == NULL, error) in WITH_EXCEPT_START.
    test rax, rax
    jz .wes_raised

    V_UNPACK rax, rdx           ; tp_call returns a Value
    mov [rbp - WES_RESULT], rax                ; save result
    mov [rbp - WES_RETTAG], rdx                ; save result tag

    ; Push result onto value stack
    mov rax, [rbp - WES_RESULT]
    mov rdx, [rbp - WES_RETTAG]
    VPUSH_VAL rax, rdx

    leave
    DISPATCH

.wes_raised:
    ; Nothing was popped and nothing pushed, so eval_saved_r13 is still what
    ; DISPATCH published -- which is what the exception table wants.  CPython
    ; leaves all four inputs in place here too and lets the handler's own
    ; depth pop them.
    mov rax, [rel current_exception]
    test rax, rax
    jz .wes_null_no_exc
    leave
    jmp eval_exception_unwind

.wes_null_no_exc:
    RAISE exc_SystemError_type, "__exit__ returned NULL without setting an exception"

.wes_error:
    RAISE exc_TypeError_type, "__exit__ is not callable"
END_FUNC op_with_except_start
