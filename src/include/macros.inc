; macros.inc - Common NASM macros for apython
; System V AMD64 ABI conventions
;
; ==========================================================================
; REGISTER CONVENTION STANDARD
; ==========================================================================
;
; 1. EVAL LOOP REGISTERS (callee-saved, global interpreter state)
;    rbx  = bytecode instruction pointer (IP into co_code[])
;    r12  = current frame pointer (PyFrame*)
;    r13  = value stack top pointer (Value[], one 64-bit word per slot)
;    r14  = co_consts tuple data pointer (&tuple.ob_item[0])
;    r15  = free (the single-word representation retired the tag stack)
;    ecx  = opcode arg on handler entry (set by eval_dispatch)
;
;    co_names / co_consts are read from the eval_co_names / eval_co_consts
;    globals via the LOAD_CO_NAMES macro.
;
; 2. OPCODE HANDLER RULE
;    Never hold live values in caller-saved registers (rax, rcx, rdx,
;    rsi, rdi, r8-r11) across any `call` instruction or DECREF/DECREF_REG
;    macro.  Two safe patterns for preserving values across calls:
;      a) Machine stack: push val before call, pop val after
;      b) Callee-saved reg or rbp-frame local [rbp-N]
;
; 3. DECREF SAFETY
;    DECREF_REG contains `call obj_dealloc` which clobbers ALL caller-saved
;    regs.  DECREF saves/restores rdi only.  Any value in rax, rcx, rdx,
;    rsi, r8-r11 is destroyed if the refcount reaches zero.
;
; 4. REGULAR FUNCTION CONVENTION (SysV ABI)
;    rdi = self/first arg.  Use callee-saved regs (rbx, r12-r15) or
;    machine stack to preserve values across calls.  Prefer tail calls
;    (jmp) over call+ret when no cleanup is needed after the call.
; ==========================================================================

%ifndef MACROS_INC
%define MACROS_INC

%include "value.inc"
%include "threadstate.inc"

; Standard global function with RBP frame
%macro DEF_FUNC 1
    global %1:function (%1 %+ .end - %1)
%1:
    push rbp
    mov rbp, rsp
%endmacro

; Global function with RBP frame + local space
%macro DEF_FUNC 2
    global %1:function (%1 %+ .end - %1)
%1:
    push rbp
    mov rbp, rsp
    sub rsp, %2
%endmacro

; Global function without prologue (opcode handlers, leaf, tail-call)
%macro DEF_FUNC_BARE 1
    global %1:function (%1 %+ .end - %1)
%1:
%endmacro

; File-local function with RBP frame (not exported)
%macro DEF_FUNC_LOCAL 1
%1:
    push rbp
    mov rbp, rsp
%endmacro

; File-local function with RBP frame + local space (not exported)
%macro DEF_FUNC_LOCAL 2
%1:
    push rbp
    mov rbp, rsp
    sub rsp, %2
%endmacro

; End any function — emits .end label for ELF size
%macro END_FUNC 1
%1 %+ .end:
%endmacro

; File initialization (GNU-stack + text section reset)
%macro ASM_INIT 0
    section .note.GNU-stack noalloc noexec nowrite progbits
    section .text
%endmacro

; Reference counting (heap pointers only — callers must not pass SmallInts).
; INCREF checks nothing: hand it an immediate int or a NULL and it writes
; through a non-pointer.  Use INCREF_V for a Value whose kind is not
; established, or obj_incref, which at least checks for NULL.
%macro INCREF 1
    inc qword [%1 + PyObject.ob_refcnt]
%endmacro

%macro DECREF 1
    dec qword [%1 + PyObject.ob_refcnt]
    jnz %%skip
    push rdi
%ifnidni %1, rdi
    mov rdi, %1
%endif
    call obj_dealloc
    pop rdi
    %%skip:
%endmacro

; DECREF for a register operand.  Always clobbers rdi, and the zero path calls
; obj_dealloc, so every caller-saved register dies there.
%macro DECREF_REG 1
    dec qword [%1 + PyObject.ob_refcnt]
    jnz %%skip
%ifnidni %1, rdi
    mov rdi, %1
%endif
    call obj_dealloc
    %%skip:
%endmacro

; Opcode dispatch - inline decode + jump (direct threading)
; Each DISPATCH site gets its own BTB entry for better branch prediction.
;
; The jump goes through opcode_dispatch_table, a pointer, rather than straight
; at opcode_table.  That is what makes `-t` work: tracing swaps the pointer for
; a table of 256 entries that all reach eval_trace_thunk, which prints and then
; jumps to the real handler.  The cost is a load where there used to be an lea,
; and no branch at all -- the previous arrangement tested a flag only inside
; eval_dispatch, which nothing reaches, so `-t` printed one opcode per frame.
;
; The two words it publishes go into the RUNNING FRAME (r12), not into a
; global: the unwinder finds that frame through ThreadState.eval_saved_r12 and
; reads them back from PyFrame.disp_ip / .disp_sp.  A frame belongs to one
; thread, so this is per-thread state that costs nothing to reach -- where a
; gs-relative store, measured on a Core Ultra 9 285K, issues at half the rate
; of a plain one and cost this loop 20% on the core benchmarks.
%macro DISPATCH 0
    mov [r12 + PyFrame.disp_ip], rbx  ; save bytecode IP for exception unwind
    mov [r12 + PyFrame.disp_sp], r13  ; save value stack ptr for exception unwind
    movzx eax, byte [rbx]         ; load opcode
    movzx ecx, byte [rbx+1]      ; load arg into ecx
    add rbx, 2                     ; advance past instruction word
    mov rdx, [rel opcode_dispatch_table]
    jmp [rdx + rax*8]             ; dispatch to handler
%endmacro

; PUBLISH_SP / PUBLISH_IP -- republish the value stack top (r13) or the
; bytecode IP (rbx) for the unwinder, from code that cannot be sure r12 is
; still the running frame: a helper with its own use of r12, or one reached
; from a handler through a call.  The running frame is found through
; ThreadState.eval_saved_r12, which is where the unwinder will look.  Every
; register and the flags' consumers are preserved; rsp moves by 8 and back.
; A handler that has not touched r12 writes [r12 + PyFrame.disp_sp] directly.
%macro PUBLISH_SP 0
    push rax
    mov rax, [gs:ThreadState.eval_saved_r12]
    mov [rax + PyFrame.disp_sp], r13
    pop rax
%endmacro
%macro PUBLISH_IP 0
    push rax
    mov rax, [gs:ThreadState.eval_saved_r12]
    mov [rax + PyFrame.disp_ip], rbx
    pop rax
%endmacro

; CLEAR_ATTR_ERROR_PENDING -- every ordinary attribute lookup clears
; ThreadState.attr_error_pending.  It is almost always zero already, and a
; gs-relative store issues at half the rate of a plain one, so the store is
; made only when there is something to clear.  Clobbers the flags.
%macro CLEAR_ATTR_ERROR_PENDING 0
    cmp qword [gs:ThreadState.attr_error_pending], 0
    je %%clear_done
    mov qword [gs:ThreadState.attr_error_pending], 0
%%clear_done:
%endmacro

; CHECK_EVAL_SIGNALS -- run any Python signal handler that is waiting.
;
; A C signal handler cannot run Python: it has no frame and no value stack,
; and it interrupted something half-finished.  So signal_trampoline sets a
; flag and the eval loop reads it -- here, at the points CPython reads it.
;
; Those points are the top of a loop and THE RETURN OF A CALL.  The second was
; missing, and it is the one that matters: a signal arrives while the process
; is inside a syscall, and the instruction that was running is the call that
; made it.  With only the loop check, `os.kill(os.getpid(), SIGINT)` followed
; by straight-line code ran no handler at all -- the flag sat set until the
; program happened to reach a backward jump, and a program with no loop after
; it never delivered.
;
; Falls through when nothing is pending, which is every time but one; that
; path is one load and one branch.  Jumps to the unwinder when a handler
; raised, so KeyboardInterrupt lands on the instruction that was interrupted.
; rbx must already be advanced past the instruction and r13 be the live stack
; top: both are published for the unwinder, exactly as DISPATCH publishes
; them.
%macro CHECK_EVAL_SIGNALS 0
    extern signal_any_pending
    cmp qword [rel signal_any_pending], 0
    je %%no_signals
    mov [r12 + PyFrame.disp_ip], rbx
    mov [r12 + PyFrame.disp_sp], r13
    extern signal_run_pending
    call signal_run_pending
    test eax, eax
    jz %%no_signals
    extern eval_exception_unwind
    jmp eval_exception_unwind
%%no_signals:
%endmacro

; Save/restore callee-saved registers used in eval loop
%macro SAVE_EVAL_REGS 0
    push rbx
    push r12
    push r13
    push r14
    push r15
%endmacro

%macro RESTORE_EVAL_REGS 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
%endmacro

; Create a C string in .rodata and load its address
%macro CSTRING 2  ; %1 = register, %2 = string
    section .rodata
    %%str: db %2, 0
    section .text
    lea %1, [rel %%str]
%endmacro

; CSTRING_DUNDER reg, suffix -- the address of "__<suffix>__".
;
; A dunder generator knows its own suffix as a bare token, and NASM does not
; expand one inside a string literal.  %defstr turns the token into a string
; first, which is the only way to build the name the descriptor is registered
; under from the name the macro was invoked with.
%macro CSTRING_DUNDER 2
    %defstr CSTRING_DUNDER_STR %2
    section .rodata
    %%str: db "__", CSTRING_DUNDER_STR, "__", 0
    section .text
    lea %1, [rel %%str]
%endmacro

; REQUIRE_SELF / REQUIRE_SELF_BARE type_label
;
; A dunder registered by name is called with whatever the caller passed, and
; the slot behind it decodes args[0] without asking -- so str.__getitem__(5, 0)
; is a wild pointer, not an error.  Both forms read args[0] out of rdi, hand
; it to dunder_require_self, and leave rdi untouched; the helper raises and
; does not return when the receiver is of the wrong type.
;
; Both preserve rdi AND rsi.  rsi is the argument count, and every one of
; these checks its arity after the receiver, so clobbering it turns a correct
; call into "expected exactly one argument".
;
; Two spellings only because of the stack: inside DEF_FUNC the frame has
; already realigned rsp, and inside DEF_FUNC_BARE it has not.
; An optional second argument names the descriptor, so the TypeError reads
; as CPython's "descriptor '__and__' requires a 'set' object"; without one
; the two type names carry the message alone.
%macro REQUIRE_SELF 1-2 0
    push rdi
    push rsi                    ; rsi is the argument COUNT here, not a value
    mov rdi, [rdi]
    lea rsi, [rel %1]
    xor edx, edx
%ifnum %2
    xor ecx, ecx
%else
    CSTRING rcx, %2
%endif
    extern dunder_require_self
    call dunder_require_self
    pop rsi
    pop rdi
%endmacro

%macro REQUIRE_SELF_BARE 1-2 0
    push rdi
    push rsi
    sub rsp, 8
    mov rdi, [rdi]
    lea rsi, [rel %1]
    xor edx, edx
%ifnum %2
    xor ecx, ecx
%else
    CSTRING rcx, %2
%endif
    extern dunder_require_self
    call dunder_require_self
    add rsp, 8
    pop rsi
    pop rdi
%endmacro

; Raise an exception with a literal message.  436 sites hand-rolled this triple.
; raise_exception does not return, so nothing follows it.
;
;   RAISE exc_TypeError_type, "descriptive error message"
;
; The macro declares no externs of its own: eval.asm *defines* raise_exception
; and exception.asm defines the exception types, so an extern here would
; collide with the definition.  Declare them per file, as before.
; A Value with the same TYPE as a (payload, tag) pair, for a message that only
; wants the type name.  An immediate's payload is not a Value, and packing a
; large int would box it -- on a path that is about to raise, and so about to
; abandon the stack that would have freed it.  Zero has the same type.
%macro VALUE_FOR_TYPE 2         ; %1 = payload in / Value out, %2 = tag (clobbered)
    cmp %2, TAG_PTR
    je %%done
    xor %1, %1
    V_PACK %1, %2
%%done:
%endmacro

%macro RAISE 2                  ; %1 = exception type symbol, %2 = message
    lea rdi, [rel %1]
    CSTRING rsi, %2
    call raise_exception
%endmacro

; The same, but it comes back: set_exception records the exception and returns,
; leaving the unwind to the interpreter frame.  For a helper that holds owned
; references at the point it fails -- RAISE would abandon the C stack and leak
; every one of them.  The caller must return its documented error value.
; A builtin that takes no keyword arguments at all, refusing them the way
; CPython does.  kw_names_pending is CONSUMED either way: a builtin that
; leaves it set hands its caller's keywords to whatever call runs next.
;
;   NO_KEYWORDS "set() takes no keyword arguments"
;
; Placed at the top of the function, before anything is popped or allocated,
; so RAISE has nothing to release.
%macro NO_KEYWORDS 1            ; %1 = the whole message
    cmp qword [gs:ThreadState.kw_names_pending], 0
    je %%no_kw
    mov qword [gs:ThreadState.kw_names_pending], 0
    RAISE exc_TypeError_type, %1
%%no_kw:
%endmacro

; The same refusal, with the carve-out CPython's generated constructors carry:
; a class that overrides __init__ absorbs the keywords itself, so only the type
; itself and a subclass that has NOT overridden __init__ refuse them.  tuple,
; float and frozenset are written this way; list is the odd one out and puts
; its check in __init__ with a carve-out on __new__ instead.
;
;   NO_KEYWORDS_TP_INIT owner_type, "tuple() takes no keyword arguments"
;
; rax must hold the class being constructed.
%macro NO_KEYWORDS_TP_INIT 2    ; %1 = the owning type, %2 = the whole message
    cmp qword [gs:ThreadState.kw_names_pending], 0
    je %%no_kw
    lea rcx, [rel %1]
    cmp rax, rcx
    je %%refuse
    mov rdx, [rax + PyTypeObject.tp_init]
    cmp rdx, [rcx + PyTypeObject.tp_init]
    jne %%no_kw
%%refuse:
    mov qword [gs:ThreadState.kw_names_pending], 0
    RAISE exc_TypeError_type, %2
%%no_kw:
%endmacro

%macro SET_EXC 2                ; %1 = exception type symbol, %2 = message
    lea rdi, [rel %1]
    CSTRING rsi, %2
    call set_exception
%endmacro

; Build a builtin function and store it in a module dict under its own name.
; abcmod, weakrefmod and sre_module each carried a byte-identical private copy
; of this (ABC_ADD_FUNC, WR_ADD_FUNC, SRE_ADD_FUNC).  r12 holds the dict.
;
;   MODULE_ADD_FUNC impl_symbol, name_cstr_symbol
;
%macro MODULE_ADD_FUNC 2        ; %1 = implementation, %2 = NUL-terminated name
    lea rdi, [rel %1]
    lea rsi, [rel %2]
    call builtin_func_new
    push rax
    lea rdi, [rel %2]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref
%endmacro

; Load co_names payload pointer (&tuple.ob_item[0]) into a register
%macro LOAD_CO_NAMES 1          ; %1 = dest reg
    mov %1, [gs:ThreadState.eval_co_names]
%endmacro

; ==========================================================================
; LEGACY (payload, tag) SUPPORT — being retired
; ==========================================================================
;
; Every value store -- the stack, frame locals, containers and object fields
; -- now holds one NaN-boxed Value (see include/value.inc).  What is left of
; the split form is the runtime function ABI: functions still return
; (rax=payload, edx=tag) and take tags as extra arguments.  The V_PACK /
; V_UNPACK macros bridge the two until P5 finishes the conversion.
;
; Tag encoding (u8):
;   bits 0-6: type tag (TAG_SMALLINT..TAG_PTR)
;   bit 7:    TAG_RC_BIT — payload is a refcounted heap pointer

; Tag constants (u8).  There is no TAG_NONE or TAG_BOOL: None, True and
; False are the immortal heap singletons and travel as TAG_PTR.
TAG_NULL     equ 0           ; null/empty slot
TAG_SMALLINT equ 1           ; payload = int64_t (full 64-bit range)
TAG_FLOAT    equ 2           ; payload = double bits (IEEE 754)
TAG_RC_BIT   equ 0x80        ; bit 7: refcounted flag
TAG_PTR      equ (5 | TAG_RC_BIT)    ; heap PyObject*, refcounted
TAG_SLEEP    equ 7           ; payload = delay_ns (uint64) — async sleep sentinel
TAG_IO_WAIT  equ 8           ; payload = fd | (direction << 32) — async I/O sentinel

; ==========================================================================
; VALUE STACK
;
; One u64 per slot, holding a NaN-boxed Value.  r13 is the top; there is no
; tag sidecar and r15 is free.
; ==========================================================================

; Push a Value.
%macro VPUSH 1                  ; %1 = Value
    mov [r13], %1
    add r13, 8
%endmacro

; Pop a Value.
%macro VPOP 1                   ; %1 = dest
    sub r13, 8
    mov %1, [r13]
%endmacro

; Peek at the top Value without popping.
%macro VPEEK 1                  ; %1 = dest
    mov %1, [r13 - 8]
%endmacro

; --- (payload, tag) shims, for call sites not yet converted ---------------

; Push from an old fat pair.  %2 must not be rax.
%macro VPUSH_VAL 2              ; %1 = payload (clobbered), %2 = tag (clobbered)
    V_PACK %1, %2
    mov [r13], %1
    add r13, 8
%endmacro

; Pop into an old fat pair.
%macro VPOP_VAL 2               ; %1 = payload dest, %2 = tag dest
    sub r13, 8
    mov %1, [r13]
    V_UNPACK %1, %2
%endmacro

; The fully-inline spellings of the two above.  V_PACK and V_UNPACK send their
; cold arms to a helper in src/val.asm (see the comment on V_PACK in
; value.inc); these keep every arm at the call site.  Reaching for one is a
; claim that the site was profiled -- say what you measured in the commit that
; adds it.  Nothing in the tree needs one at present: inlining the int arm of
; both macros was enough, and it was enough uniformly.
%macro VPUSH_VAL_INLINE 2       ; %1 = payload (clobbered), %2 = tag (clobbered)
    V_PACK_INLINE %1, %2
    mov [r13], %1
    add r13, 8
%endmacro

%macro VPOP_VAL_INLINE 2        ; %1 = payload dest, %2 = tag dest
    sub r13, 8
    mov %1, [r13]
    V_UNPACK_INLINE %1, %2
%endmacro

; Push a raw int64, boxing it when it falls outside the immediate range.
; %2 must not be rax.
%macro VPUSH_INT 2              ; %1 = int64 (clobbered), %2 = scratch
    V_PACK_I64 %1, %2
    mov [r13], %1
    add r13, 8
%endmacro

; Push raw IEEE-754 double bits.
%macro VPUSH_FLOAT 2            ; %1 = bits (clobbered), %2 = scratch
    V_FROM_F64 %1, %2
    mov [r13], %1
    add r13, 8
%endmacro

; Push the None singleton (owned).  No scratch needed: the binary is linked
; -no-pie, so the address fits an imm32.
%macro VPUSH_NONE 0
    mov qword [r13], none_singleton
    inc qword [rel none_singleton]      ; ob_refcnt is at offset 0
    add r13, 8
%endmacro

; Push True/False (owned) from a 0/1 value.  Clobbers %1.
%macro VPUSH_BOOL 1             ; %1 = 0 (False) or 1 (True)
    test %1, %1
    jz %%false
    lea %1, [rel bool_true]
    jmp %%store
%%false:
    lea %1, [rel bool_false]
%%store:
    inc qword [%1 + PyObject.ob_refcnt]
    mov [r13], %1
    add r13, 8
%endmacro

; Push a heap pointer.  A pointer is its own Value.
%macro VPUSH_PTR 1
    mov [r13], %1
    add r13, 8
%endmacro

; Push a NULL Value (the empty callable slot CALL expects).
%macro VPUSH_NULL 0
    mov qword [r13], 0
    add r13, 8
%endmacro

; Undo N pops by re-advancing the stack pointer (deopt paths, where the
; popped slots are still intact in memory).
%macro VUNDROP 1                ; %1 = number of slots
    add r13, %1 * 8
%endmacro

; Discard the top %1 slots without reading them.  For values the caller has
; already established are immediates, so there is nothing to DECREF.
%macro VDROP 1                  ; %1 = number of slots
    sub r13, %1 * 8
%endmacro

; ==========================================================================
; None / True / False as owned singleton pointers
;
; These have no immediate form: they are the immortal heap singletons.  The
; including file must declare the externs itself (none.asm / bool.asm define
; these symbols and must not also extern them).
; ==========================================================================

; Fat return of None: (rax = none_singleton, edx = TAG_PTR).  Clobbers rax.
%macro RET_NONE 0
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
%endmacro

; Fat return of a constant bool.  110 sites open-coded one of these three
; three-line sequences; RET_NONE already existed, its bool siblings did not.
%macro RET_TRUE 0
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
%endmacro

%macro RET_FALSE 0
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
%endmacro

; Fat return of a bool from a 0/1 value already in rax.  Clobbers rax, rdx.
%macro RET_BOOL_RAX 0
    lea rdx, [rel bool_false]
    test rax, rax
    jz %%false
    lea rdx, [rel bool_true]
%%false:
    mov rax, rdx
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
%endmacro

; Compare a value against the None singleton; ZF is set when it is None.
%macro IS_NONE 2                ; %1 = payload reg/mem, %2 = scratch reg
    lea %2, [rel none_singleton]
    cmp %1, %2
%endmacro

; Load the None singleton (owned) into a register.  Clobbers only %1.
%macro LOAD_NONE 1              ; %1 = dest
    lea %1, [rel none_singleton]
    inc qword [%1 + PyObject.ob_refcnt]
%endmacro

; --- legacy (payload, tag) refcounting and returns ------------------------

; --- (payload, tag) refcount shims, for code not yet converted ------------
; INCREF a fat value — only when the tag says the payload is refcounted.
%macro INCREF_VAL 2             ; %1 = payload, %2 = tag reg
    test %2, TAG_RC_BIT
    jz %%skip
    inc qword [%1 + PyObject.ob_refcnt]
    %%skip:
%endmacro

; DECREF a fat value.  Clobbers rdi and all caller-saved regs when the
; object is freed.
%macro DECREF_VAL 2             ; %1 = payload, %2 = tag reg
    test %2, TAG_RC_BIT
    jz %%skip
    dec qword [%1 + PyObject.ob_refcnt]
    jnz %%skip
%ifnidni %1, rdi
    mov rdi, %1
%endif
    call obj_dealloc
    %%skip:
%endmacro

; NULL-safe DECREF_VAL.
%macro XDECREF_VAL 2            ; %1 = payload, %2 = tag reg
    test %2, TAG_RC_BIT
    jz %%skip
    test %1, %1
    jz %%skip
    dec qword [%1 + PyObject.ob_refcnt]
    jnz %%skip
%ifnidni %1, rdi
    mov rdi, %1
%endif
    call obj_dealloc
    %%skip:
%endmacro

; Fat return of NULL/error: (rax = 0, edx = TAG_NULL = 0).
%macro RET_NULL 0
    xor eax, eax
    xor edx, edx
%endmacro

; Fat return tag for an inline integer; the caller sets rax.
%macro RET_TAG_SMALLINT 0
    mov edx, TAG_SMALLINT
%endmacro

; Push one pointer Value as a single-argument array on the machine stack.
%macro SPUSH_PTR 1              ; %1 = PyObject*
    sub rsp, 16                 ; one Value; 16 keeps rsp 16-byte aligned
    mov [rsp], %1
%endmacro

; ===== Fat result save/restore across DECREF calls =====
; Save a fat (rax=payload, rdx=tag) result on the machine stack.
; IMPORTANT: All rsp-relative addresses between SAVE and RESTORE need +16 offset.
%macro SAVE_FAT_RESULT 0
    push rdx                   ; save result tag
    push rax                   ; save result payload
%endmacro

; Restore a fat (rax=payload, rdx=tag) result from the machine stack.
%macro RESTORE_FAT_RESULT 0
    pop rax                    ; restore result payload
    pop rdx                    ; restore result tag
%endmacro

; ==========================================================================
; FRAME STACK PUSH — push onto a saved frame's value stack (stack_ptr)
; Used by generator resume to push sent/None values before calling eval_frame.
; ==========================================================================

; Push None onto a frame's saved value stack.
; %1 = frame register, %2 = scratch register (clobbered)
%macro FRAME_PUSH_NONE 2
    mov %2, [%1 + PyFrame.stack_ptr]
    mov qword [%2], none_singleton
    inc qword [rel none_singleton]      ; ob_refcnt is at offset 0
    add %2, 8
    mov [%1 + PyFrame.stack_ptr], %2
%endmacro

; Push a Value onto a frame's saved value stack.
; %1 = frame register, %2 = Value register, %3 = scratch register
%macro FRAME_PUSH_VALUE 3
    mov %3, [%1 + PyFrame.stack_ptr]
    mov [%3], %2
    add %3, 8
    mov [%1 + PyFrame.stack_ptr], %3
%endmacro

; Bound C-level recursion through a container: comparing or hashing a
; structure that reaches itself recursed until the machine stack ran out.
; %1 is taken when the limit is hit; the counter is reset wholesale by
; eval_exception_unwind, since a raise discards these frames.
%macro C_RECURSION_ENTER 1
    inc qword [gs:ThreadState.c_recursion_depth]
    mov rax, [gs:ThreadState.c_recursion_depth]
    cmp rax, [rel recursion_limit]
    jg %1
%endmacro

%macro C_RECURSION_LEAVE 0
    dec qword [gs:ThreadState.c_recursion_depth]
%endmacro

; Instance __dict__ access, via the type's tp_dictoffset rather than a fixed
; +16.  A subclass of list, tuple, dict or set embeds the base layout first
; and carries its dict after it, so the offset varies by family; a str
; subclass has none at all.  Only a heaptype ever has a non-zero offset.
;
; LOAD_INST_DICT dest, inst, none_label -- dest gets the dict pointer, or the
; label is taken when this type's instances have no dict slot.
%macro LOAD_INST_DICT 3
    mov %1, [%2 + PyObject.ob_type]
    mov %1, [%1 + PyTypeObject.tp_dictoffset]
    test %1, %1
    jz %3
    cmp %1, TP_DICT_AT_TAIL
    je %%tail
    mov %1, [%2 + %1]
    jmp %%done
%%tail:
    INST_DICT_TAIL %1, %2
    mov %1, [%1]
%%done:
%endmacro

; STORE_INST_DICT inst, value, scratch, none_label
%macro STORE_INST_DICT 4
    mov %3, [%1 + PyObject.ob_type]
    mov %3, [%3 + PyTypeObject.tp_dictoffset]
    test %3, %3
    jz %4
    cmp %3, TP_DICT_AT_TAIL
    je %%tail
    mov [%1 + %3], %2
    jmp %%done
%%tail:
    INST_DICT_TAIL %3, %1
    mov [%3], %2
%%done:
%endmacro

; A str keeps its characters inline, so there is no fixed offset past the
; header for a __dict__ -- which is why a str subclass had none, and why
; setting any attribute on one raised.  The pointer goes at the tail instead,
; past the data and the eight NUL bytes str_new_heap pads with, and
; tp_dictoffset carries this sentinel to say so.  CPython does the same thing
; with a negative offset.
TP_DICT_AT_TAIL equ -1

; MV_ITEM_ADDR dest, view, index, scratch -- the address of a memoryview's
; item.  A contiguous view is mv_buf + i*itemsize; a strided one steps by
; mv_stride items, which is negative for a reversed view.  %3 is preserved.
%macro MV_ITEM_ADDR 4           ; %1 = dest, %2 = view, %3 = index, %4 = scratch
    mov %4, %3
    imul %4, [%2 + PyMemoryViewObject.mv_stride]
    imul %4, [%2 + PyMemoryViewObject.mv_itemsize]
    mov %1, [%2 + PyMemoryViewObject.mv_buf]
    add %1, %4
%endmacro

; SLOT_ADDR dest, inst, off -- the address of a __slots__ word.
;
; A non-negative md_offset is a byte offset from the object's start, which is
; every ordinary class.  A NEGATIVE one is a tail slot: a str subclass keeps
; its characters inline, so there is no fixed offset past the header to lay a
; slot at, and its slots follow the tail dict word instead.  -1 is the first,
; -2 the second, so the address is the tail plus 8 * -off.
%macro SLOT_ADDR 3              ; %1 = dest, %2 = instance, %3 = md_offset
    test %3, %3
    js %%tail
    lea %1, [%2 + %3]
    jmp %%done
%%tail:
    INST_DICT_TAIL %1, %2
    neg %3
    lea %1, [%1 + %3*8]
    neg %3
%%done:
%endmacro

; INST_DICT_TAIL dest, inst -- address of the tail dict pointer.
; str and bytes both keep eight spare bytes past their data (the NUL a str is
; padded with, the terminator bytes_type_call writes), so the dict sits one
; word beyond that in both.  Only where the data starts differs.
%macro INST_DICT_TAIL 2
    mov %1, [%2 + PyObject.ob_type]
    test qword [%1 + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz %%bytes_tail
    mov %1, [%2 + PyStrObject.ob_size]
    lea %1, [%2 + %1 + PyStrObject.data + 8]
    jmp %%tail_done
%%bytes_tail:
    mov %1, [%2 + PyBytesObject.ob_size]
    lea %1, [%2 + %1 + PyBytesObject.data + 8]
%%tail_done:
%endmacro

; A dunder call returns NULL for two different reasons: the type does not
; define the dunder, or it ran and raised.  Only the first is a fallback --
; treating the second as one swallows the exception, which then surfaces
; later at an unrelated instruction.
;
; current_exception alone cannot tell them apart: it stays set for the whole
; of an `except` block, so an ordinary dunder miss inside a handler would
; look like a failure.  Save it before the call and compare after.
%macro DUNDER_EXC_SAVE 1        ; %1 = destination slot (register or memory)
    push rax
    mov rax, [gs:ThreadState.current_exception]
    mov %1, rax
    pop rax
%endmacro

%macro DUNDER_RAISED 2          ; %1 = the saved slot, %2 = label to take
    push rax
    mov rax, [gs:ThreadState.current_exception]
    cmp rax, %1
    pop rax                     ; pop does not disturb the flags
    jne %2
%endmacro

; The same question asked of a call that may legitimately CLEAR the pending
; exception rather than raise: call_iternext swallows a StopIteration by
; zeroing current_exception, so inside an `except` block the global goes from
; the handled exception to 0 -- a change, but not a raise.  DUNDER_RAISED
; alone read that as "it raised", and list(it)/tuple(it) inside a handler
; returned NULL.  An exception was raised only if one is pending NOW and it
; is not the one that was already being handled.
%macro EXC_RAISED_SINCE 3       ; %1 = saved slot, %2 = scratch, %3 = label
    push %2                     ; the scratch is restored on both paths, so a
    mov %2, [gs:ThreadState.current_exception]  ; caller need not find a dead register
    test %2, %2
    jz %%no
    cmp %2, %1
    je %%no
    pop %2
    jmp %3
%%no:
    pop %2
%endmacro

; The same, for the container families.  Each exact-type test these replace
; rejected a subclass: [1] == MyList([1]) was silently False, and
; {**MyDict(...)} was a TypeError.
%macro REQUIRE_LIST_TYPE 3
    lea %2, [rel list_type]
    cmp %1, %2
    je %%list_like
    test qword [%1 + PyTypeObject.tp_flags], TYPE_FLAG_LIST_SUBCLASS
    jz %3
%%list_like:
%endmacro

%macro REQUIRE_TUPLE_TYPE 3
    lea %2, [rel tuple_type]
    cmp %1, %2
    je %%tuple_like
    test qword [%1 + PyTypeObject.tp_flags], TYPE_FLAG_TUPLE_SUBCLASS
    jz %3
%%tuple_like:
%endmacro

%macro REQUIRE_DICT_TYPE 3
    lea %2, [rel dict_type]
    cmp %1, %2
    je %%dict_like
    test qword [%1 + PyTypeObject.tp_flags], TYPE_FLAG_DICT_SUBCLASS
    jz %3
%%dict_like:
%endmacro

; Decline -- with a NULL Value, this tree's NotImplemented -- unless the LEFT
; operand of a binary nb_* slot is a pointer whose type is %1, or a subclass of
; it when %2 names a TYPE_FLAG_*_SUBCLASS bit (pass 0 for none).  %3 is 1 when
; the enclosing function has an rbp frame and must `leave` on the way out.
;
; Must be placed at the very top of the slot, before any push: the decline path
; unwinds nothing.
;
; Sequence operations live in nb_add / nb_multiply here, where CPython keeps
; them in sq_concat / sq_repeat and leaves the nb_* slots NULL.  Since
; op_binary_op now offers a declined pair to the RIGHT operand's slot as well
; -- CPython's binary_op1 -- `1 + "a"` reaches str_concat with an int on the
; left.  Assuming the left operand is the slot's own type stopped being safe at
; that moment.
%macro BINOP_REQUIRE_LEFT 3
    V_TEST_PTR rdi, rax         ; ja == not a pointer, so not %1 either
    ja %%decline
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel %1]
    cmp rax, rcx
    je %%ok
%if %2
    test qword [rax + PyTypeObject.tp_flags], %2
    jnz %%ok
%endif
%%decline:
    xor eax, eax
%if %3
    leave
%endif
    ret
%%ok:
%endmacro

; Require that a type object is set, frozenset, or a subclass of either; jump
; away if not.  set was the one family with no such macro, which is why its
; nb_* slots handed whatever they were given straight to set_method_union --
; `{1,2} | 5` read address 5 as a set table.
%macro REQUIRE_SET_TYPE 3
    lea %2, [rel set_type]
    cmp %1, %2
    je %%set_like
    lea %2, [rel frozenset_type]
    cmp %1, %2
    je %%set_like
    test qword [%1 + PyTypeObject.tp_flags], TYPE_FLAG_SET_SUBCLASS
    jz %3
%%set_like:
%endmacro

; An object that its type's TYPE_FLAG_HAVE_GC says is collectable, but which
; has no GC head all the same: a STATIC type.  Every metatype carries HAVE_GC,
; because the heap types it makes are collected, so `object`, `str` and `type`
; itself pass the flag test -- while the sixteen bytes in front of a static
; type's table are whatever the assembler put there, usually a string.  Read as
; a PyGC_Head, those bytes put the static type into a collection list and the
; next phase traversed it; the fault landed in gc_list_remove, and WHICH bytes
; were there depended on the binary's layout, so it appeared and vanished with
; edits that had nothing to do with it.
;
; A type's own GC-ness is what CPython asks through tp_is_gc, and `type`'s
; implementation of that slot is exactly "is this a heap type".  Every visitor
; and every is-it-tracked question has to ask it, because a tp_traverse hands
; over ob_type, tp_base and every tp_mro entry, and those are static types in
; any program at all.
; %1 = the object, %2 = its type, already loaded.  %3 = label to take when the
; object has no GC head.  Neither register is touched.
%macro GC_SKIP_STATIC_TYPE 3
    test qword [%2 + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz %%not_a_type             ; not a class: the flag answered already
    test qword [%1 + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz %3                       ; a static type has no head to read
%%not_a_type:
%endmacro

; Require that a type object is str or a str subclass; jump away if not.
; The exact-type test these replace rejected a str subclass everywhere it
; appeared -- "a" + MyStr("b") was a TypeError, and "a" == MyStr("a") was
; silently False.
; %1 = register holding the PyTypeObject*, %2 = scratch, %3 = fail label.
%macro REQUIRE_STR_TYPE 3
    lea %2, [rel str_type]
    cmp %1, %2
    je %%str_like
    test qword [%1 + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz %3
%%str_like:
%endmacro

; Require that a type object is int, bool, or an int subclass; jump away if
; not.  Python's bool derives from int, so an object indexed with True is
; indexed with 1 -- and bool_type carries tp_base = int_type but no
; TYPE_FLAG_INT_SUBCLASS, so testing the flag alone misses it.
; %1 = register holding the PyTypeObject*, %2 = scratch, %3 = label to take
; when the type is not int-like.  Both registers are preserved.
%macro REQUIRE_INT_TYPE 3
    lea %2, [rel int_type]
    cmp %1, %2
    je %%int_like
    lea %2, [rel bool_type]
    cmp %1, %2
    je %%int_like
    test qword [%1 + PyTypeObject.tp_flags], TYPE_FLAG_INT_SUBCLASS
    jz %3
%%int_like:
%endmacro

; Mark stack as non-executable and reset to .text section
ASM_INIT

; MRO_NEXT walker, origin -- advance `walker` to the next entry of `origin`'s
; method resolution order, or 0 at the end.  For a type with no tp_mro (every
; static builtin type) this is exactly the old `mov walker, [walker+tp_base]`.
; Clobbers rax, rcx, rdx, rsi, rdi, r8-r11.
%macro MRO_NEXT 2
%ifnidni %2, rdi
    mov rdi, %2
%endif
%ifnidni %1, rsi
    mov rsi, %1
%endif
    extern type_mro_next
    call type_mro_next
    mov %1, rax
%endmacro

%endif ; MACROS_INC

;; ============================================================================
;; FLOAT_PAIR_OR_DEOPT label -- xmm0 = left, xmm1 = right, or jump to `label`
;;
;; Accepts a float on both sides, or a float on one side and an INTEGER
;; IMMEDIATE on the other.  r9d/r8d are the left/right tags and rdi/rsi the
;; payloads, as VPOP_VAL leaves them.
;;
;; Mixed int/float had no fast arm anywhere: `x * 2` and `2 * x` both took the
;; whole generic protocol on EVERY execution, with nothing ever rewritten --
;; binop_left_wrapper, binop_subclass_first, binop_is_number, and then
;; float_mul, which runs float_binop_accepts and float_to_f64 twice each.
;; Around two hundred instructions to reach one cvtsi2sd and one mulsd.
;; CPython does not specialize this either; its binary-op specializer rejects
;; `!Py_IS_TYPE(lhs, Py_TYPE(rhs))` before it ever looks at float.
;;
;; TWO INTEGERS ARE REFUSED.  That pair belongs to the integer opcode, and
;; answering it here would produce a float where Python produces an int.
;;
;; Safe in a specialized handler for the same reason the both-float form is:
;; neither a TAG_FLOAT nor a TAG_SMALLINT immediate can be a heaptype
;; instance, so no user __add__ on a float or int subclass is bypassed.
;; ============================================================================
%macro FLOAT_PAIR_OR_DEOPT 1
    cmp r9d, TAG_FLOAT
    je %%left_float
    cmp r9d, TAG_SMALLINT
    jne %1
    cmp r8d, TAG_FLOAT
    jne %1                      ; int against a non-float: not this opcode
    cvtsi2sd xmm0, rdi
    movq xmm1, rsi
    jmp %%ready
%%left_float:
    movq xmm0, rdi
    cmp r8d, TAG_FLOAT
    je %%right_float
    cmp r8d, TAG_SMALLINT
    jne %1
    cvtsi2sd xmm1, rsi
    jmp %%ready
%%right_float:
    movq xmm1, rsi
%%ready:
%endmacro

;; ============================================================================
;; FLOAT_PAIR_OR_DEOPT_M label -- xmm0 = left, xmm1 = right, or jump to `label`
;;
;; What FLOAT_PAIR_OR_DEOPT accepts, read STRAIGHT OFF THE STACK instead of out
;; of the (payload, tag) pairs VPOP_VAL leaves behind.  Same rules: float
;; against float, float against an integer immediate either way round, and two
;; integers REFUSED, because that pair belongs to the integer opcode and
;; answering it here would produce a float where Python produces an int.
;;
;; The pair version cost two V_UNPACKs -- twenty instructions to classify by
;; high16, subtract a bias and synthesise a tag -- before a six-compare ladder
;; over those tags could look at them.  This classifies the raw Values with
;; V_IS_FLOAT, which is the same three instructions V_UNPACK would have spent
;; on step one, and then stops.
;;
;; Nothing is popped, so a handler using this has nothing to put back on its
;; deopt arm: it writes the generic opcode and re-dispatches with the stack as
;; it found it.
;;
;; Clobbers rax, rdi and rsi.  A pointer or NULL fails both tests and deopts.
;; ============================================================================
%macro FLOAT_PAIR_OR_DEOPT_M 1
    mov rdi, [r13 - 16]         ; left Value
    mov rsi, [r13 - 8]          ; right Value
    V_IS_FLOAT rdi, rax
    jb %%left_float
    ; Not a float, so the only pair left to accept is integer against float.
    cmp rdi, [rel v_int_lo]
    jb %1                       ; a pointer, NULL, or a sentinel
    V_IS_FLOAT rsi, rax
    jae %1                      ; two integers: not this opcode
    V_TO_I64 rdi
    cvtsi2sd xmm0, rdi
    V_TO_F64 rsi
    movq xmm1, rsi
    jmp %%ready
%%left_float:
    V_TO_F64 rdi
    movq xmm0, rdi
    V_IS_FLOAT rsi, rax
    jb %%right_float
    cmp rsi, [rel v_int_lo]
    jb %1
    V_TO_I64 rsi
    cvtsi2sd xmm1, rsi
    jmp %%ready
%%right_float:
    V_TO_F64 rsi
    movq xmm1, rsi
%%ready:
%endmacro

;; ============================================================================
;; INT_PAIR_OR_DEOPT label -- rdx = left Value, rax = right Value, or jump
;;
;; Reads the top two stack slots WITHOUT popping them, and rejects anything
;; that is not an integer immediate.  Because nothing was popped, the deopt
;; arm has nothing to undo: it writes the generic opcode back and re-dispatches
;; with the stack exactly as it found it.
;;
;; The two Values are left BIASED.  An immediate is `i - 2^50` taken modulo
;; 2^64 (V_INT_BIAS is 2^64 - 2^50), so for i in [-2^50, 2^50) the encoding is
;; strictly increasing as an UNSIGNED 64-bit number and never wraps.  Three
;; consequences the handlers below use:
;;
;;   - `v >= V_INT_LO` unsigned is the whole type check, one compare per side.
;;   - `cmp` on the biased Values, read unsigned, IS the signed comparison of
;;     the integers -- so a compare needs no decoding at all.
;;   - adding or subtracting biased Values gives the biased answer after one
;;     correction by the bias, and the same `>= V_INT_LO` test then doubles as
;;     the overflow check, since a sum outside the immediate range lands
;;     outside [V_INT_LO, 2^64) in either direction.
;;
;; Only multiply, divide and the bitwise ops have to decode, and they do it
;; with a single `sub` per operand.
;;
;; Safe in a specialized handler for the same reason the float form is: an
;; integer immediate is never a heaptype instance, so no user __add__ on an
;; int subclass is bypassed.  A COMPACT HEAP INT is refused here -- see P4.
;; ============================================================================
%macro INT_PAIR_OR_DEOPT 1
    mov rax, [r13 - 8]          ; right
    mov rdx, [r13 - 16]         ; left
    cmp rax, [rel v_int_lo]
    jb %1
    cmp rdx, [rel v_int_lo]
    jb %1
%endmacro

;; ============================================================================
;; VREPLACE2 value -- drop two stack slots and store one Value in their place
;;
;; The counterpart to reading with INT_PAIR_OR_DEOPT rather than popping.
;; ============================================================================
%macro VREPLACE2 1              ; %1 = Value
    sub r13, 8
    mov [r13 - 8], %1
%endmacro

;; ============================================================================
;; VREPLACE2_BOOL reg, scratch -- the same, for a 0/1 in the low byte of %1
;;
;; Branchless: both singletons are addressed and one is selected with cmov,
;; so a comparison whose answer alternates costs no misprediction.  %1 is
;; clobbered.
;; ============================================================================
%macro VREPLACE2_BOOL 2         ; %1 = 0/1 (clobbered), %2 = scratch
    lea %2, [rel bool_true]
    test %1, %1
    lea %1, [rel bool_false]
    cmovnz %1, %2
    inc qword [%1 + PyObject.ob_refcnt]
    sub r13, 8
    mov [r13 - 8], %1
%endmacro

;; ============================================================================
;; STR_PAIR_OR_DEOPT left, right, label
;;
;; Continue only when both Values are EXACT strs; jump to `label` otherwise.
;; Both arguments must really be VALUES.  Handed a (payload, tag) pair's
;; payload instead, a small int arrives as the bare number and passes the
;; pointer test, and the type load then dereferences it.
;; Clobbers r10.  It deliberately does NOT touch rcx: at the specialization
;; site rcx still holds the BINARY_OP operator index that .binop_generic needs
;; on the way out, and at a specialized handler's deopt rcx is the oparg.
;; ============================================================================
%macro STR_PAIR_OR_DEOPT 3      ; %1 = left, %2 = right, %3 = deopt label
    V_TEST_PTR %1, r10
    ja %3
    test %1, %1
    jz %3
    V_TEST_PTR %2, r10
    ja %3
    test %2, %2
    jz %3
    lea r10, [rel str_type]
    cmp [%1 + PyObject.ob_type], r10
    jne %3
    cmp [%2 + PyObject.ob_type], r10
    jne %3
%endmacro

;; ============================================================================
;; INPLACE_ADD_TARGET_OR_DEOPT left, label
;;
;; Continue only when the string in %1 can be appended to where it stands:
;; the next instruction is the STORE_FAST that will consume the result, that
;; local still holds this very object, this stack slot and that local are its
;; only two references, and it has never been hashed.
;;
;; rbx is past the 2-byte instruction word, so the CACHE is at [rbx] and the
;; instruction after it at [rbx + 2].  Clobbers r10 and r11, and not rcx.
;; ============================================================================
%macro INPLACE_ADD_TARGET_OR_DEOPT 2    ; %1 = left, %2 = deopt label
    cmp byte [rbx + 2], 125             ; STORE_FAST
    jne %2
    movzx r11d, byte [rbx + 3]
    mov r10, [r12 + PyFrame.localsplus + r11*8]
    cmp %1, r10
    jne %2
    cmp qword [%1 + PyObject.ob_refcnt], 2
    jne %2
    cmp qword [%1 + PyStrObject.ob_hash], -1
    jne %2
%endmacro

; Indices into main_sysflags (src/main.asm), one byte per field, in the order
; of sys.flags itself -- sys_module_init copies them across by index.
SF_DEBUG          equ 0
SF_INSPECT        equ 1
SF_INTERACTIVE    equ 2
SF_OPTIMIZE       equ 3
SF_DONT_WRITE_BC  equ 4
SF_NO_USER_SITE   equ 5
SF_NO_SITE        equ 6
SF_IGNORE_ENV     equ 7
SF_VERBOSE        equ 8
SF_BYTES_WARNING  equ 9
SF_QUIET          equ 10
SF_HASH_RANDOM    equ 11
SF_ISOLATED       equ 12
SF_DEV_MODE       equ 13
SF_UTF8_MODE      equ 14
SF_WARN_DEF_ENC   equ 15
SF_SAFE_PATH      equ 16
SYSFLAGS_COUNT    equ 17
