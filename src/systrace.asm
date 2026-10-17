; systrace.asm - sys.settrace and sys.setprofile, and the events they see.
;
; CPython 3.12 builds these on top of PEP 669's sys.monitoring; this builds
; them directly.  Monitoring would need a writable, versioned co_code and a
; second set of INSTRUMENTED_* opcodes to swap into it, and co_code here is
; inline object payload that arrives from marshal.  CPython layered them this
; way through 3.11 and inverted it only to serve monitoring, which nothing
; here asks for.
;
; WHAT IT COSTS WHEN IT IS OFF: nothing.  DISPATCH already jumps through
; opcode_dispatch_table -- a pointer, not the table -- because `-t` needed
; somewhere to interpose, and 222 expansions of the macro already pay for the
; load.  Turning tracing on stores opcode_trace_table there; turning it off
; stores opcode_table back.  A `cmp [rel tracing]` inside DISPATCH would have
; been strictly worse: a second conditional branch at each of those 222 sites,
; against a design that deliberately spends one BTB entry per site on the
; indirect jump so each predicts its own successor.
;
; THE EVENTS, and where each is raised from:
;
;   'call'      eval_frame, once the frame's globals and eval_base_rsp are in
;               place so a raise from the tracer unwinds through it
;   'line'      the dispatch thunk, when the line changes or a jump goes
;               backwards
;   'opcode'    the same thunk, when the frame asked for f_trace_opcodes
;   'return'    the top of eval_return, which is the single exit -- a return,
;               a yield and the unwinder's .no_handler all reach it.  rax and
;               current_exception between them say which of CPython's
;               PY_RETURN / PY_YIELD / PY_UNWIND it is, and all three map to
;               'return' the way CPython's legacy layer maps them
;   'exception' eval_exception_unwind, which is entered once per frame as an
;               exception propagates outward
;
; THE LINE RULE.  CPython decides statically which instructions start a line
; and then suppresses at run time when the dynamically previous instruction
; had the same line; on top of that it fires on EVERY backward jump, even
; within one line, which is what makes `while True: pass` traceable.  Here the
; static half is folded into the dynamic one: an event fires when the line
; differs from the last one reported, or when the offset went backwards.  The
; two are equivalent for compiler output.  END_FOR, END_SEND and RESUME need
; no special case -- the first two are only ever reached from an instruction on
; their own line, and RESUME is covered by the reset at frame entry, which is
; exactly why CPython special-cases it.
;
; RE-ENTRY.  tracing_depth is non-zero for the whole of a callback, so a trace
; function that itself runs Python is not traced.  sys.call_tracing exists to
; turn that off deliberately, and is four instructions, as CPython's is.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

ASM_INIT

extern obj_call_n
extern raise_exception
extern builtin_func_type
extern method_type
extern obj_decref
extern none_singleton
extern bool_true
extern bool_false
extern frameobj_for
extern frameobj_refresh_pos
extern code_addr2line
extern opcode_dispatch_table
extern opcode_trace_table
extern opcode_table

; Per thread, as CPython's are, so in ThreadState (src/include/threadstate.inc):
;   sys_tracefunc, sys_profilefunc  the trace and profile functions, as
;                                   Values, or 0 for "not set"
;   tracing_depth                   non-zero while a callback is running:
;                                   nothing inside one is traced
;   systrace_any                    non-zero when either hook is installed.
;                                   eval_frame and eval_return test this one
;                                   word rather than two, so the cost of
;                                   tracing being off is a single
;                                   predictable, never-taken branch
;
; eval_hook_mask and the dispatch table it selects stay global: DISPATCH reads
; one table for every thread.

section .data
align 8

; bit 0 = the -t opcode printer, bit 1 = sys.settrace.  Two independent
; reasons to want the same table, so they cannot simply overwrite each other.
global eval_hook_mask
eval_hook_mask:  dq 0

section .rodata
ev_call:      db "call", 0
ev_line:      db "line", 0
ev_return:    db "return", 0
ev_exception: db "exception", 0
ev_opcode:    db "opcode", 0
ev_c_call:      db "c_call", 0
ev_c_return:    db "c_return", 0
ev_c_exception: db "c_exception", 0

section .text

;; ============================================================================
;; eval_hooks_set(edi = which bit, esi = 1 to set / 0 to clear)
;;   -> nothing (opcode_dispatch_table repointed to match)
;;
;; The dispatch table is shared by `-t` and by sys.settrace, so it is the OR
;; of the two that decides which table DISPATCH jumps through.
;; ============================================================================
global eval_hooks_set
DEF_FUNC eval_hooks_set
    mov ecx, edi
    mov eax, 1
    shl rax, cl
    test esi, esi
    jz .ehs_clear
    or [rel eval_hook_mask], rax
    jmp .ehs_apply
.ehs_clear:
    not rax
    and [rel eval_hook_mask], rax
.ehs_apply:
    lea rax, [rel opcode_table]
    cmp qword [rel eval_hook_mask], 0
    je .ehs_store
    lea rax, [rel opcode_trace_table]
.ehs_store:
    mov [rel opcode_dispatch_table], rax
    leave
    ret
END_FUNC eval_hooks_set

;; ============================================================================
;; systrace_recount() -> nothing (systrace_any updated)
;; ============================================================================
DEF_FUNC_BARE systrace_recount
    xor eax, eax
    cmp qword [gs:ThreadState.sys_tracefunc], 0
    jne .src_on
    cmp qword [gs:ThreadState.sys_profilefunc], 0
    je .src_store
.src_on:
    mov eax, 1
.src_store:
    mov [gs:ThreadState.systrace_any], rax
    ret
END_FUNC systrace_recount

;; ============================================================================
;; systrace_active() -> eax = 1 when a callback may be made right now
;;
;; A trace function is set, and we are not already inside one.  Everything
;; below opens with this, because the answer is the same for all five events.
;; ============================================================================
DEF_FUNC_BARE systrace_active
    xor eax, eax
    cmp qword [gs:ThreadState.tracing_depth], 0
    jne .sta_no
    cmp qword [gs:ThreadState.sys_tracefunc], 0
    je .sta_no
    mov eax, 1
.sta_no:
    ret
END_FUNC systrace_active

;; ============================================================================
;; systrace_invoke(rdi = the callback Value, rsi = frame object,
;;                 rdx = the event name, a C string, rcx = the arg Value)
;;   -> rax = the callback's result Value, or 0 with an exception pending
;;
;; One call, with tracing suppressed around it.  The frame object is BORROWED
;; and INCREFd for the duration, because the callback may drop the last other
;; reference to it.  The ARG is borrowed too and is never touched: every
;; caller already holds it for as long as the call lasts.
;; ============================================================================
SI_FN    equ 8
SI_ARGS  equ 40             ; three Values: frame, event, arg
SI_EVENT equ 48
SI_FRAME equ 72             ; + 0 pushes = 72; padded to 80 below
DEF_FUNC_LOCAL systrace_invoke, 80
    mov [rbp - SI_FN], rdi
    mov [rbp - SI_ARGS], rsi
    mov [rbp - SI_ARGS + 16], rcx
    mov [rbp - SI_EVENT], rdx

    INCREF rsi

    ; The event name is a str built here rather than interned once: these are
    ; five short literals and a callback runs Python for far longer.
    mov rdi, [rbp - SI_EVENT]
    extern str_from_cstr_heap
    call str_from_cstr_heap
    test rax, rax
    jz .si_fail
    mov [rbp - SI_ARGS + 8], rax

    inc qword [gs:ThreadState.tracing_depth]
    mov rdi, [rbp - SI_FN]
    lea rsi, [rbp - SI_ARGS]
    mov edx, 3
    call obj_call_n
    dec qword [gs:ThreadState.tracing_depth]

    push rax
    mov rdi, [rbp - SI_ARGS + 8]
    call obj_decref
    mov rdi, [rbp - SI_ARGS]
    call obj_decref
    pop rax
    leave
    ret
.si_fail:
    mov rdi, [rbp - SI_ARGS]
    call obj_decref
    xor eax, eax
    leave
    ret
END_FUNC systrace_invoke

;; ============================================================================
;; systrace_result(rdi = the frame object, rsi = the callback's result)
;;   -> eax = 0, or -1 with an exception pending
;;
;; CPython's trace_trampoline tail.  NULL means the callback raised: tracing
;; is turned off wholesale, as sys.settrace(None) would, and the frame's local
;; hook is dropped -- otherwise every later event would re-enter a function
;; that is known to fail.  None leaves f_trace alone; anything else becomes
;; the frame's local trace function.
;; ============================================================================
DEF_FUNC_LOCAL systrace_result, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    test rsi, rsi
    jz .sr_failed

    lea rcx, [rel none_singleton]
    cmp rsi, rcx
    je .sr_drop_result

    mov rdi, [rbx + PyFrameObject.f_trace]
    mov [rbx + PyFrameObject.f_trace], rsi
    test rdi, rdi
    jz .sr_ok
    call obj_decref
    jmp .sr_ok

.sr_drop_result:
    mov rdi, rsi
    call obj_decref
.sr_ok:
    xor eax, eax
    pop rbx
    leave
    ret

.sr_failed:
    mov rdi, [rbx + PyFrameObject.f_trace]
    mov qword [rbx + PyFrameObject.f_trace], 0
    test rdi, rdi
    jz .sr_off
    call obj_decref
.sr_off:
    mov rdi, [gs:ThreadState.sys_tracefunc]
    mov qword [gs:ThreadState.sys_tracefunc], 0
    test rdi, rdi
    jz .sr_off_done
    call obj_decref
.sr_off_done:
    mov edi, 1
    xor esi, esi
    call eval_hooks_set
    call systrace_recount
    mov eax, -1
    pop rbx
    leave
    ret
END_FUNC systrace_result

;; ============================================================================
;; systrace_profile(rdi = the event name, rsi = the arg Value)
;;   -> eax = 0, or -1 with an exception pending
;;
;; The profile hook is global, not per-frame: it sees every frame's 'call' and
;; 'return' and no lines at all, which is the whole point of it.  Its return
;; value is ignored, as CPython ignores it.
;; ============================================================================
SPR_EVENT equ 8
SPR_ARG   equ 16
SPR_OBJ   equ 24
SPR_FRAME equ 40            ; + 0 pushes = 40; padded to 48 below
global systrace_profile
DEF_FUNC systrace_profile, 48
    mov [rbp - SPR_EVENT], rdi
    mov [rbp - SPR_ARG], rsi
    cmp qword [gs:ThreadState.tracing_depth], 0
    jne .spr_none
    cmp qword [gs:ThreadState.sys_profilefunc], 0
    je .spr_none
    mov rdi, [gs:ThreadState.eval_saved_r12]
    test rdi, rdi
    jz .spr_none
    call frameobj_for
    test rax, rax
    jz .spr_none
    mov [rbp - SPR_OBJ], rax

    mov rdi, [gs:ThreadState.sys_profilefunc]
    mov rsi, rax
    mov rdx, [rbp - SPR_EVENT]
    mov rcx, [rbp - SPR_ARG]
    call systrace_invoke
    test rax, rax
    jz .spr_raised
    mov rdi, rax
    call obj_decref
    mov rdi, [rbp - SPR_OBJ]
    call obj_decref
    xor eax, eax
    leave
    ret
.spr_raised:
    ; A profile function that raised turns profiling off, the way a trace
    ; function that raised turns tracing off.
    mov rdi, [gs:ThreadState.sys_profilefunc]
    mov qword [gs:ThreadState.sys_profilefunc], 0
    test rdi, rdi
    jz .spr_off
    call obj_decref
.spr_off:
    call systrace_recount
    mov rdi, [rbp - SPR_OBJ]
    call obj_decref
    mov eax, -1
    leave
    ret
.spr_none:
    xor eax, eax
    leave
    ret
END_FUNC systrace_profile

;; ============================================================================
;; systrace_c_callable(rdi = the callable Value) -> rax = the builtin, or 0
;;
;; The profile hook's c_* events are for C functions only, and the argument
;; they carry is the function itself.  A builtin bound to an instance is an
;; ordinary method object here where CPython has a second builtin type, so
;; both shapes have to be unwrapped -- see DIVERGENCES.md.
;; ============================================================================
global systrace_c_callable
DEF_FUNC_BARE systrace_c_callable
    xor eax, eax
    cmp qword [gs:ThreadState.sys_profilefunc], 0
    je .scc_no
    cmp qword [gs:ThreadState.tracing_depth], 0
    jne .scc_no
    V_TEST_PTR rdi, rcx
    ja .scc_no
    mov rcx, [rdi + PyObject.ob_type]
    lea rdx, [rel builtin_func_type]
    cmp rcx, rdx
    je .scc_yes
    lea rdx, [rel method_type]
    cmp rcx, rdx
    jne .scc_no
    mov rdi, [rdi + PyMethodObject.im_func]
    test rdi, rdi
    jz .scc_no
    V_TEST_PTR rdi, rcx
    ja .scc_no
    mov rcx, [rdi + PyObject.ob_type]
    lea rdx, [rel builtin_func_type]
    cmp rcx, rdx
    jne .scc_no
.scc_yes:
    mov rax, rdi
.scc_no:
    ret
END_FUNC systrace_c_callable

;; ============================================================================
;; systrace_c_event(rdi = the builtin, esi = 0 for c_call, 1 for c_return,
;;                  2 for c_exception) -> nothing
;;
;; The three events around a call into C.  profile.py needs them: without
;; them every builtin's time is charged to its caller.
;; ============================================================================
SCE_FN    equ 8
SCE_FRAME equ 16            ; + 0 pushes = 16
global systrace_c_event
DEF_FUNC systrace_c_event, SCE_FRAME
    mov [rbp - SCE_FN], rdi
    lea rdx, [rel ev_c_call]
    test esi, esi
    jz .sce_go
    lea rdx, [rel ev_c_return]
    cmp esi, 1
    je .sce_go
    lea rdx, [rel ev_c_exception]
.sce_go:
    mov rdi, rdx                ; the event name
    mov rsi, [rbp - SCE_FN]     ; the arg, borrowed
    call systrace_profile
    leave
    ret
END_FUNC systrace_c_event

;; ============================================================================
;; systrace_call() -> eax = 0, or -1 with an exception pending
;;
;; The 'call' event, from eval_frame.  The GLOBAL trace function is the one
;; consulted here -- that is what makes a per-frame f_trace exist at all, and
;; it is why a frame entered while tracing is off is never traced.
;; ============================================================================
STC_OBJ   equ 8
STC_FRAME equ 24            ; + 0 pushes = 24; padded to 32 below
global systrace_call
DEF_FUNC systrace_call, 32
    ; A generator function's first pass through eval_frame exists only to run
    ; RETURN_GENERATOR and hand back the generator object; CPython reports
    ; nothing for it, and the 'call' its caller sees comes from the first
    ; send().  The instruction about to run is what says which pass this is.
    mov rax, [gs:ThreadState.eval_saved_r12]   ; the running frame
    test rax, rax
    jz .stc_not_birth
    mov rax, [rax + PyFrame.disp_ip]
    test rax, rax
    jz .stc_not_birth
    cmp byte [rax], OP_RETURN_GENERATOR
    je .stc_none
.stc_not_birth:

    lea rdi, [rel ev_call]
    lea rsi, [rel none_singleton]
    call systrace_profile
    test eax, eax
    js .stc_out

    call systrace_active
    test eax, eax
    jz .stc_none

    mov rdi, [gs:ThreadState.eval_saved_r12]
    test rdi, rdi
    jz .stc_none
    call frameobj_for
    test rax, rax
    jz .stc_none
    mov [rbp - STC_OBJ], rax
    ; Seed the line state from where the frame actually IS.  That is the
    ; RESUME, or the generator prologue's POP_TOP just before it, and CPython
    ; reports neither: `def g(n):` is never a line of g's body, and a
    ; generator resuming does not re-report the line it suspended on.  A
    ; module's RESUME carries line 0, which is why the module's first real
    ; line still fires.
    mov rdi, rax
    call frameobj_refresh_pos
    mov rax, [rbp - STC_OBJ]
    mov rcx, [rax + PyFrameObject.f_lasti]
    sar rcx, 1
    mov [rax + PyFrameObject.ft_prev], rcx
    ; ...but a seed of LINE ZERO suppresses nothing, because line 0 is not a
    ; line: it is what a module's RESUME carries, and CPython reports the next
    ; instruction whatever line it is on.  Seeding it meant an EMPTY module --
    ; whose only other instruction is the implicit return, also at line 0 --
    ; compared equal and fired no line event at all.  pdb sets
    ; _user_requested_quit from a command read during a line event, so with no
    ; event `pdb empty.py` printed "The program finished and will be
    ; restarted" for ever.  Leaving the -1 the constructor wrote makes that
    ; one instruction fire, and changes nothing for any frame that enters on a
    ; real line -- a function, or a comprehension's own frame, which would
    ; otherwise re-report the line it was called from.
    mov rcx, [rax + PyFrameObject.f_lineno]
    test rcx, rcx
    jz .stc_seeded
    mov [rax + PyFrameObject.ft_line], rcx
.stc_seeded:

    mov rdi, [gs:ThreadState.sys_tracefunc]
    mov rsi, rax
    lea rdx, [rel ev_call]
    lea rcx, [rel none_singleton]   ; the arg is borrowed; invoke never drops it
    call systrace_invoke
    mov rsi, rax
    mov rdi, [rbp - STC_OBJ]
    call systrace_result
    push rax
    mov rdi, [rbp - STC_OBJ]
    call obj_decref
    pop rax
    leave
    ret
.stc_none:
    xor eax, eax
.stc_out:
    leave
    ret
END_FUNC systrace_call

;; ============================================================================
;; systrace_local(rdi = the event name, rsi = the arg Value)
;;   -> eax = 0, or -1 with an exception pending
;;
;; The three events that go to the frame's OWN hook rather than to the global
;; one: 'line', 'return' and 'exception'.  A frame with no f_trace is not
;; traced, which is how a `return None` from the 'call' handler switches local
;; tracing off for a whole call -- bdb's set_continue does exactly that.
;; ============================================================================
STL_EVENT equ 8
STL_ARG   equ 16
STL_OBJ   equ 24
STL_FRAME equ 40            ; + 0 pushes = 40; padded to 48 below
global systrace_local
DEF_FUNC systrace_local, 48
    mov [rbp - STL_EVENT], rdi
    mov [rbp - STL_ARG], rsi

    call systrace_active
    test eax, eax
    jz .stl_none

    mov rdi, [gs:ThreadState.eval_saved_r12]
    test rdi, rdi
    jz .stl_none
    ; frameobj_for, not frame_obj directly: a frame the tracer never asked
    ; about has no view, and no view means no f_trace, which means nothing to
    ; call -- but the check has to be on f_trace, not on the view.
    mov rax, [rdi + PyFrame.frame_obj]
    test rax, rax
    jz .stl_none
    cmp qword [rax + PyFrameObject.f_trace], 0
    je .stl_none
    INCREF rax
    mov [rbp - STL_OBJ], rax

    mov rdi, [rax + PyFrameObject.f_trace]
    mov rsi, rax
    mov rdx, [rbp - STL_EVENT]
    mov rcx, [rbp - STL_ARG]
    call systrace_invoke
    mov rsi, rax
    mov rdi, [rbp - STL_OBJ]
    call systrace_result
    push rax
    mov rdi, [rbp - STL_OBJ]
    call obj_decref
    pop rax
    leave
    ret
.stl_none:
    xor eax, eax
    leave
    ret
END_FUNC systrace_local

;; ============================================================================
;; systrace_return(rdi = the returned Value, or 0 when the frame is unwinding)
;;   -> nothing (any exception the tracer raised is left pending)
;;
;; CPython's PY_RETURN, PY_YIELD and PY_UNWIND all become 'return'; a yield is
;; a return here in the same sense, because a generator's resume is a fresh
;; eval_frame and so a fresh 'call'.  An unwinding frame reports None, as
;; CPython's does.
;; ============================================================================
STR_VAL equ 8
STR_FRAME equ 16            ; + 0 pushes = 16
global systrace_return
DEF_FUNC systrace_return, STR_FRAME
    test rdi, rdi
    jnz .str_have
    lea rdi, [rel none_singleton]
.str_have:
    mov [rbp - STR_VAL], rdi
    ; The position the frame reached, while its IP is still readable: after
    ; this the frame goes back on the pool and f_lineno can only be whatever
    ; was copied out.
    mov rax, [gs:ThreadState.eval_saved_r12]
    test rax, rax
    jz .str_go
    mov rax, [rax + PyFrame.frame_obj]
    test rax, rax
    jz .str_go
    mov rdi, rax
    call frameobj_refresh_pos
.str_go:
    lea rdi, [rel ev_return]
    mov rsi, [rbp - STR_VAL]
    call systrace_local
    lea rdi, [rel ev_return]
    mov rsi, [rbp - STR_VAL]
    call systrace_profile
    leave
    ret
END_FUNC systrace_return

;; ============================================================================
;; systrace_line(rdi = the current bytecode IP) -> eax = 0, or -1
;;
;; The line rule, and the only event that has to decide whether to fire.
;; ============================================================================
STLN_OBJ  equ 8
STLN_OFF  equ 16
STLN_FRAME equ 32           ; + 0 pushes = 32
global systrace_line
DEF_FUNC systrace_line, STLN_FRAME
    mov r10, [gs:ThreadState.eval_saved_r12]
    test r10, r10
    jz .sln_none
    mov rax, [r10 + PyFrame.frame_obj]
    test rax, rax
    jz .sln_none
    cmp qword [rax + PyFrameObject.f_trace], 0
    je .sln_none
    mov [rbp - STLN_OBJ], rax

    mov rsi, [r10 + PyFrame.code]
    test rsi, rsi
    jz .sln_none
    ; The IP arrives pointing PAST the instruction word DISPATCH just read,
    ; so back up two bytes to name the instruction about to run.
    sub rdi, 2
    lea rcx, [rsi + PyCodeObject.co_code]
    sub rdi, rcx
    js .sln_none
    shr rdi, 1                  ; code units
    mov [rbp - STLN_OFF], rdi

    cmp qword [rax + PyFrameObject.f_trace_opcodes], 0
    jne .sln_fire_opcode
.sln_after_opcode:

    cmp qword [rax + PyFrameObject.f_trace_lines], 0
    je .sln_none

    ; RESUME never starts a line.  Skipping it without recording its line is
    ; what makes a module's first statement report -- CPython gives a module's
    ; RESUME line 0 and this compiler gives it line 1, so recording it would
    ; swallow line 1 exactly where trace.py counts it.
    ; DISPATCH stores rbx BEFORE advancing it, so PyFrame.disp_ip points AT the
    ; instruction about to run and its first byte is the opcode.
    mov rcx, [gs:ThreadState.eval_saved_r12]   ; the running frame
    test rcx, rcx
    jz .sln_not_resume
    mov rcx, [rcx + PyFrame.disp_ip]
    test rcx, rcx
    jz .sln_not_resume
    cmp byte [rcx], OP_RESUME
    je .sln_none
.sln_not_resume:

    ; A backward step is a jump, and CPython fires on every one of those even
    ; within a single line -- `while True: pass` needs it.
    mov rcx, [rbp - STLN_OFF]
    cmp rcx, [rax + PyFrameObject.ft_prev]
    mov [rax + PyFrameObject.ft_prev], rcx
    jb .sln_lookup

    ; Forward: the line has to have changed.
    mov rdi, rsi
    mov rsi, rcx
    call code_addr2line
    mov rcx, [rbp - STLN_OBJ]
    cmp rax, [rcx + PyFrameObject.ft_line]
    je .sln_none
    mov [rcx + PyFrameObject.ft_line], rax
    jmp .sln_fire

.sln_lookup:
    mov rdi, rsi
    mov rsi, rcx
    call code_addr2line
    mov rcx, [rbp - STLN_OBJ]
    mov [rcx + PyFrameObject.ft_line], rax

.sln_fire:
    lea rdi, [rel ev_line]
    lea rsi, [rel none_singleton]
    call systrace_local
    leave
    ret

.sln_fire_opcode:
    ; f_trace_opcodes is nearly free here: the thunk already runs at every
    ; instruction, so this is one more test rather than a second mechanism.
    push rsi
    lea rdi, [rel ev_opcode]
    lea rsi, [rel none_singleton]
    call systrace_local
    pop rsi
    mov rax, [rbp - STLN_OBJ]
    jmp .sln_after_opcode

.sln_none:
    xor eax, eax
    leave
    ret
END_FUNC systrace_line

;; ============================================================================
;; systrace_exception() -> nothing (the in-flight exception is left as it was)
;;
;; The 'exception' event, from the unwinder.  arg is the (type, value,
;; traceback) triple CPython passes.
;;
;; The exception in flight is parked in a local for the duration: the callback
;; runs Python, and a raise from inside it would replace current_exception.
;; Restoring it afterwards is what keeps the unwind that is already under way
;; from being lost.
;; ============================================================================
STE_EXC   equ 8
STE_TUP   equ 16
STE_FRAME equ 32            ; + 0 pushes = 32
global systrace_exception
DEF_FUNC systrace_exception, STE_FRAME
    push rbx
    push r12                    ; two pushes: rsp keeps its alignment
    call systrace_active
    test eax, eax
    jz .ste_done

    mov rax, [gs:ThreadState.eval_saved_r12]
    test rax, rax
    jz .ste_done
    mov rax, [rax + PyFrame.frame_obj]
    test rax, rax
    jz .ste_done
    cmp qword [rax + PyFrameObject.f_trace], 0
    je .ste_done

    mov rbx, [gs:ThreadState.current_exception]
    test rbx, rbx
    jz .ste_done
    mov [rbp - STE_EXC], rbx
    INCREF rbx

    mov edi, 3
    extern tuple_new
    call tuple_new
    test rax, rax
    jz .ste_release
    mov [rbp - STE_TUP], rax
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rbx, [rbp - STE_EXC]
    mov rcx, [rbx + PyObject.ob_type]
    mov [rdx], rcx
    INCREF rcx
    mov [rdx + 8], rbx
    INCREF rbx
    mov rcx, [rbx + PyExceptionObject.exc_tb]
    test rcx, rcx
    jnz .ste_have_tb
    lea rcx, [rel none_singleton]
.ste_have_tb:
    mov [rdx + 16], rcx
    INCREF rcx

    lea rdi, [rel ev_exception]
    mov rsi, [rbp - STE_TUP]
    call systrace_local

    mov rdi, [rbp - STE_TUP]
    call obj_decref

.ste_release:
    ; Whatever the callback did to current_exception, the unwind that was
    ; already running is the one that continues.
    mov rax, [rbp - STE_EXC]
    mov [gs:ThreadState.current_exception], rax
    mov rdi, rax
    call obj_decref
.ste_done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC systrace_exception

;; ============================================================================
;; sys_settrace_func(rdi = args, rsi = nargs) -> rax = None as a Value
;; sys_gettrace_func(rdi = args, rsi = nargs) -> rax = the function, or None
;;
;; sys.settrace(f) installs the global trace function and repoints dispatch;
;; sys.settrace(None) takes both back down.
;; ============================================================================
global sys_settrace_func
DEF_FUNC sys_settrace_func, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    xor ebx, ebx
    test rsi, rsi
    jz .sst_have
    mov rbx, [rdi]
    lea rcx, [rel none_singleton]
    cmp rbx, rcx
    jne .sst_keep
    xor ebx, ebx
    jmp .sst_have
.sst_keep:
    INCREF rbx
.sst_have:
    mov rdi, [gs:ThreadState.sys_tracefunc]
    mov [gs:ThreadState.sys_tracefunc], rbx
    test rdi, rdi
    jz .sst_set
    call obj_decref
.sst_set:
    mov edi, 1
    xor esi, esi
    test rbx, rbx
    jz .sst_apply
    mov esi, 1
.sst_apply:
    call eval_hooks_set
    call systrace_recount
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
END_FUNC sys_settrace_func

;; ============================================================================
;; sys_gettrace_func(rdi = args, rsi = nargs) -> rax = the trace function as a
;;   Value, or None when none is set
;; ============================================================================
global sys_gettrace_func
DEF_FUNC sys_gettrace_func
    mov rax, [gs:ThreadState.sys_tracefunc]
    test rax, rax
    jnz .sgt_have
    lea rax, [rel none_singleton]
.sgt_have:
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
END_FUNC sys_gettrace_func

;; ============================================================================
;; sys_setprofile_func(rdi = args, rsi = nargs) -> rax = None as a Value
;; sys_getprofile_func(rdi = args, rsi = nargs) -> rax = the function, or None
;;
;; The profile hook sees 'call' and 'return' and not 'line', which is the
;; whole point of it: no per-instruction work at all.  It shares the trace
;; function's slot logic and its own global.
;; ============================================================================
global sys_setprofile_func
DEF_FUNC sys_setprofile_func, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    xor ebx, ebx
    test rsi, rsi
    jz .ssp_have
    mov rbx, [rdi]
    lea rcx, [rel none_singleton]
    cmp rbx, rcx
    jne .ssp_keep
    xor ebx, ebx
    jmp .ssp_have
.ssp_keep:
    INCREF rbx
.ssp_have:
    mov rdi, [gs:ThreadState.sys_profilefunc]
    mov [gs:ThreadState.sys_profilefunc], rbx
    test rdi, rdi
    jz .ssp_done
    call obj_decref
.ssp_done:
    call systrace_recount
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
END_FUNC sys_setprofile_func

;; ============================================================================
;; sys_getprofile_func(rdi = args, rsi = nargs) -> rax = the profile function
;;   as a Value, or None when none is set
;; ============================================================================
global sys_getprofile_func
DEF_FUNC sys_getprofile_func
    mov rax, [gs:ThreadState.sys_profilefunc]
    test rax, rax
    jnz .sgp_have
    lea rax, [rel none_singleton]
.sgp_have:
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
END_FUNC sys_getprofile_func

;; ============================================================================
;; sys_call_tracing_func(rdi = args, rsi = nargs) -> rax = whatever func
;;   returned, as a Value, or 0 with an exception pending
;;
;; Call func with tracing suppressed and then restored, so a debugger can run
;; a command inside its own trace function without tracing itself.  Four
;; instructions around the call, as CPython's _PyEval_CallTracing is.
;; ============================================================================
SCT_SAVED equ 8
SCT_ARG2  equ 16            ; the second argument, for the refusal below
SCT_FRAME equ 32            ; + 0 pushes = 32
global sys_call_tracing_func
DEF_FUNC sys_call_tracing_func, SCT_FRAME
    cmp rsi, 2
    jne .sct_arity
    mov rdx, [rdi + 8]              ; the args tuple
    mov rdi, [rdi]                  ; the callable
    ; It is a VALUE, and an int is an immediate: `sys.call_tracing(type, 2)`
    ; -- which is the whole of CPython's own test for this function -- read
    ; ob_type off the number 2.
    mov [rbp - SCT_ARG2], rdx
    V_TEST_PTR rdx, rax
    ja .sct_not_tuple
    test rdx, rdx
    jz .sct_not_tuple
    mov rcx, [rdx + PyObject.ob_type]
    extern tuple_type
    lea rax, [rel tuple_type]
    cmp rcx, rax
    jne .sct_not_tuple

    mov rax, [gs:ThreadState.tracing_depth]
    mov [rbp - SCT_SAVED], rax
    mov qword [gs:ThreadState.tracing_depth], 0
    mov rsi, [rdx + PyTupleObject.ob_item]
    mov rdx, [rdx + PyTupleObject.ob_size]
    call obj_call_n
    push rax
    mov rcx, [rbp - SCT_SAVED]
    mov [gs:ThreadState.tracing_depth], rcx
    pop rax
    leave
    ret
.sct_arity:
    ; CPython says how many it got, and the two refusals are different
    ; sentences: the count is an arity error, the type is an argument error.
    extern raise_type_error_counted
    CSTRING rdi, "call_tracing expected 2 arguments, got "
    xor edx, edx
    jmp raise_type_error_counted

.sct_not_tuple:
    mov rsi, [rbp - SCT_ARG2]
    CSTRING rdi, `call_tracing() argument 2 must be tuple, not \x02`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
END_FUNC sys_call_tracing_func
