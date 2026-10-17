; signalmod.asm - the `_signalcore` module (lib/_signal.py is the rest of `_signal`), and delivering a signal to Python code
;
; A signal arrives at a moment the interpreter cannot run Python in: the
; handler is a C frame on some other stack, with no frame, no value stack and
; no idea what half-finished operation it interrupted.  So the C handler here
; does the only thing that is safe -- it records that signal N arrived and
; sets one flag -- and the eval loop runs the Python handler at a point of its
; own choosing.  That is CPython's design, and the point it chooses is the
; same one: a backward jump, which is the top of every loop, so a program that
; is computing rather than blocking still notices.
;
; `signal.signal` is the whole reason six stdlib modules could not be imported
; -- doctest, pdb, unittest, asyncio, multiprocessing and signal itself.
;
; What is NOT here, because signal.py guards each with `if 'x' in _globals`:
; pthread_sigmask, sigpending, sigwait, sigtimedwait, sigwaitinfo and
; valid_signals.  They are about a thread's mask, and this interpreter has one
; thread.

%include "macros.inc"
%include "object.inc"
%include "value.inc"

ASM_INIT

extern dict_new
extern dict_set
extern module_new
extern str_from_cstr_heap
extern str_from_cstr
extern obj_decref
extern obj_incref
extern obj_dealloc
extern int_from_i64
extern int_to_i64
extern obj_as_index
extern builtin_func_new
extern none_singleton
extern obj_call_n
extern raise_exception
extern raise_oserror
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_KeyboardInterrupt_type
extern sigaction
extern sys_alarm
extern sys_pause
extern strsignal

;; The kernel signal numbers run 1..NSIG-1; glibc's NSIG is 65 here.
SIG_NSIG      equ 65
SIG_SA_SIZE   equ 152          ; sizeof(struct sigaction) on x86-64 glibc
SIG_SA_MASK   equ 8            ; sa_mask, 128 bytes
SIG_SA_FLAGS  equ 136
SIG_SA_RESTART equ 0x10000000

section .bss
;; The Python handler for each signal, as a Value, or 0 for "not ours" --
;; which means SIG_DFL, SIG_IGN or something installed outside this module.
;; Owned; nothing ever releases one, because a handler lives as long as the
;; interpreter does.
global signal_handlers
signal_handlers: resq SIG_NSIG

;; One byte per signal, set by the C handler and cleared when the Python one
;; runs.  A byte rather than a counter: a signal that arrives twice before the
;; handler runs is delivered once, as CPython's is.
signal_pending: resb SIG_NSIG
    align 8

;; Scratch for building a `struct sigaction`.  Only ever touched with signals
;; that are about to be reinstalled, so a handler cannot see it half-written.
sig_act: resb SIG_SA_SIZE
sig_old: resb SIG_SA_SIZE

section .data
align 8
;; Non-zero when at least one signal is waiting to be delivered.  The eval
;; loop reads exactly this word, so the check it pays on every backward jump
;; is one load and one branch.
global signal_any_pending
signal_any_pending: dq 0

section .text

;; ============================================================================
;; signal_trampoline(rdi = the signal number) -> void
;;
;; The C-level handler.  Everything it does has to be safe to do from a signal:
;; two stores and a return, no allocation, no lock, no libc.
;; ============================================================================
DEF_FUNC_LOCAL signal_trampoline
    cmp rdi, SIG_NSIG
    jae .st_out
    lea rax, [rel signal_pending]
    mov byte [rax + rdi], 1
    mov qword [rel signal_any_pending], 1
.st_out:
    leave
    ret
END_FUNC signal_trampoline

;; ============================================================================
;; signal_install(rdi = signum, rsi = the C handler to install) -> rax = 0 ok
;;
;; sigaction(2) with sa_flags = 0, which is what CPython's PyOS_setsig passes.
;;
;; It used to pass SA_RESTART, on the reading that PEP 475 made restarting the
;; language's behaviour.  PEP 475 says the retry happens -- it does not say the
;; KERNEL does it, and CPython deliberately does not let it: with SA_RESTART a
;; blocked read never returns, so the Python handler cannot run until the read
;; finishes, and a program whose handler is what UNBLOCKS the read waits for
;; ever.  `signal.alarm(1)` during `f.read(6)`, where the handler writes the
;; rest of the data, is exactly that shape, and it is CPython's own
;; test_io.check_interrupted_read_retry.
;;
;; The restart PEP 475 promises is done in software instead: the syscall
;; funnels in runtime.asm retry EINTR themselves, and the ones with a Python
;; frame to run a handler on run signal_run_pending in between.
;; ============================================================================
SI_NUM   equ 8
SI_FRAME equ 16             ; + 0 pushes = 16
DEF_FUNC_LOCAL signal_install, SI_FRAME
    mov [rbp - SI_NUM], rdi
    lea rax, [rel sig_act]
    mov [rax], rsi                          ; sa_handler
    mov dword [rax + SIG_SA_FLAGS], 0
    ; An empty sa_mask: only the signal being delivered is blocked, which is
    ; sigaction's own default and what CPython asks for.
    lea rdi, [rax + SIG_SA_MASK]
    xor eax, eax
    mov ecx, 128 / 8
    rep stosq
    mov rdi, [rbp - SI_NUM]
    lea rsi, [rel sig_act]
    lea rdx, [rel sig_old]
    call sigaction
    leave
    ret
END_FUNC signal_install

;; ============================================================================
;; signal_run_pending() -> rax = 0 when every handler ran, 1 when one raised
;;
;; Called from the eval loop with a live frame, so a handler that raises can
;; be unwound the ordinary way.  The flag is cleared FIRST: a signal that
;; arrives while a handler is running sets it again and is delivered on the
;; next pass rather than being lost.
;; ============================================================================
SRP_I     equ 8
SRP_FN    equ 16            ; the handler being called
; The two-Value argument array.  A slot names its LOWEST address and the
; array grows UPWARD toward rbp, so args[0] is [rbp - SRP_ARGS] and args[1]
; is eight bytes above it -- and nothing else may live in either.  Putting
; the callable at SRP_ARGS+8 made it args[1]: every handler was called with
; itself as the frame, and the None meant for the frame went one word past
; the array.
SRP_ARGS  equ 32
SRP_FRAME equ 40            ; + 1 push = 48, 16-aligned
global signal_run_pending
DEF_FUNC signal_run_pending, SRP_FRAME
    push rbx
    mov qword [rel signal_any_pending], 0
    mov ebx, 1
.srp_loop:
    cmp rbx, SIG_NSIG
    jae .srp_done
    lea rax, [rel signal_pending]
    cmp byte [rax + rbx], 0
    je .srp_next
    mov byte [rax + rbx], 0
    lea rax, [rel signal_handlers]
    mov rax, [rax + rbx*8]
    test rax, rax
    jz .srp_next                            ; nothing of ours to run
    ; SIG_DFL and SIG_IGN live in the table as the ints 0 and 1; neither is
    ; something to call, and neither installs the trampoline that would set
    ; the flag -- but one may have replaced a handler after the flag was set.
    V_TEST_PTR rax, rcx
    ja .srp_next
    mov [rbp - SRP_FN], rax                 ; keep the handler
    mov rdi, rbx
    call int_from_i64
    V_PACK rax, rdx
    mov [rbp - SRP_ARGS], rax               ; args[0] = the signal number

    ; args[1] is the interrupted frame, and it has to be a real one: pdb's
    ; sigint_handler stores it, and traceback.print_stack(frame) walks it.
    ; It is the frame this loop is running in, which is what eval_saved_r12
    ; holds -- the same one sys._getframe() answers with.
    mov rdi, [gs:ThreadState.eval_saved_r12]
    test rdi, rdi
    jz .srp_no_frame
    extern frameobj_for
    call frameobj_for
    test rax, rax
    jnz .srp_have_frame
.srp_no_frame:
    lea rax, [rel none_singleton]
    INCREF rax
.srp_have_frame:
    mov [rbp - SRP_ARGS + 8], rax           ; args[1]

    mov rdi, [rbp - SRP_FN]
    lea rsi, [rbp - SRP_ARGS]
    mov edx, 2
    call obj_call_n
    push rax
    mov rax, [rbp - SRP_ARGS]
    DECREF_V rax, rcx
    mov rdi, [rbp - SRP_ARGS + 8]
    call obj_decref
    pop rax
    test rax, rax
    jz .srp_raised
    DECREF_V rax, rcx
.srp_next:
    inc rbx
    jmp .srp_loop
.srp_done:
    xor eax, eax
    pop rbx
    leave
    ret
.srp_raised:
    mov eax, 1
    pop rbx
    leave
    ret
END_FUNC signal_run_pending

;; ============================================================================
;; signal_arg(rdi = a Value) -> rax = the signal number, or raises
;;
;; Every entry point takes one, and every one of them has to refuse a number
;; outside 1..NSIG-1 rather than index the tables with it.
;; ============================================================================
DEF_FUNC_LOCAL signal_arg
    ; obj_as_index takes the old (payload, tag) pair, not a Value.
    mov rax, rdi
    V_UNPACK rax, rdx
    mov rdi, rax
    call obj_as_index
    test rax, rax
    js .sa_range
    cmp rax, SIG_NSIG
    jae .sa_range
    test rax, rax
    je .sa_range
    leave
    ret
.sa_range:
    RAISE exc_ValueError_type, "signal number out of range"
END_FUNC signal_arg

;; ============================================================================
;; signal_method_signal(args, nargs) -> the handler that was installed before
;;
;; signal(signum, handler).  `handler` is SIG_DFL (0), SIG_IGN (1) or a
;; callable; anything else is a TypeError, as CPython has it.
;; ============================================================================
SS_NUM   equ 8
SS_OLD   equ 16
SS_FRAME equ 32             ; + 1 push = 40... pad to land right
global signal_method_signal
DEF_FUNC signal_method_signal, 24           ; + 1 push = 32, 16-aligned
    push rbx
    cmp rsi, 2
    jne .ss_argerr
    mov rbx, rdi
    mov rdi, [rbx]
    call signal_arg
    mov [rbp - SS_NUM], rax

    ; What was there before, so it can be handed back.
    lea rcx, [rel signal_handlers]
    mov rax, [rcx + rax*8]
    test rax, rax
    jnz .ss_have_old
    ; Not ours: report SIG_DFL, which is what it will be unless someone
    ; outside this interpreter installed something.
    xor edi, edi
    call int_from_i64
    V_PACK rax, rdx
    jmp .ss_old_ready
.ss_have_old:
    INCREF_V rax, rcx
.ss_old_ready:
    mov [rbp - SS_OLD], rax

    ; The new one.  SIG_DFL and SIG_IGN arrive as the ints 0 and 1.
    mov rdi, [rbx + 8]
    V_TEST_PTR rdi, rax
    ja .ss_maybe_sentinel
    ; A pointer is only a handler if it is callable; CPython's check is the
    ; same one, tp_call being non-NULL, and a str got that far here.
    test rdi, rdi
    jz .ss_typeerr
    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .ss_typeerr
    cmp qword [rax + PyTypeObject.tp_call], 0
    jne .ss_callable
    jmp .ss_typeerr
.ss_maybe_sentinel:
    V_IS_INT rdi, rax
    jb .ss_typeerr
    mov rax, rdi
    sub rax, [rel v_int_bias]
    test rax, rax
    je .ss_dfl
    cmp rax, 1
    je .ss_ign
    jmp .ss_typeerr

.ss_dfl:
    mov rdi, [rbp - SS_NUM]
    xor esi, esi                            ; SIG_DFL
    jmp .ss_install
.ss_ign:
    mov rdi, [rbp - SS_NUM]
    mov esi, 1                              ; SIG_IGN
    jmp .ss_install

.ss_callable:
    ; A callable of any kind: the C handler goes in, and the object is kept
    ; here for signal_run_pending to call.
    mov rdi, [rbp - SS_NUM]
    lea rsi, [rel signal_trampoline]
.ss_install:
    push rdi
    call signal_install
    pop rdi
    test eax, eax
    js .ss_oserror

    ; Record it only once the kernel has accepted it, so a refused signal --
    ; SIGKILL, SIGSTOP -- leaves the table as it was.
    ; The table holds whatever was installed, sentinel or callable, so that
    ; getsignal can tell SIG_IGN from SIG_DFL -- they are the ints 1 and 0,
    ; and an entry of 0 means "never set", which reads as SIG_DFL too.
    mov rcx, [rbp - SS_NUM]
    lea rdx, [rel signal_handlers]
    mov rax, [rbx + 8]
    INCREF_V rax, rsi
    mov [rdx + rcx*8], rax
.ss_return:
    mov rax, [rbp - SS_OLD]
    pop rbx
    leave
    ret

.ss_oserror:
    ; sigaction refuses SIGKILL and SIGSTOP, and EINVAL is the only way it can
    ; fail once the number has been range-checked -- which is the OSError
    ; CPython reports for those two.
    mov rax, [rbp - SS_OLD]
    DECREF_V rax, rcx
    mov edi, 22                             ; EINVAL
    xor esi, esi
    call raise_oserror
.ss_typeerr:
    mov rax, [rbp - SS_OLD]
    DECREF_V rax, rcx
    RAISE exc_TypeError_type, "signal handler must be signal.SIG_IGN, signal.SIG_DFL, or a callable object"
.ss_argerr:
    RAISE exc_TypeError_type, "signal() takes exactly 2 arguments"
END_FUNC signal_method_signal

;; ============================================================================
;; signal_method_getsignal(args, nargs) -> the current handler
;;
;; The object that was installed, or the ints SIG_DFL / SIG_IGN.  CPython
;; answers None for a handler installed outside Python; this cannot tell that
;; apart from SIG_DFL and says SIG_DFL, which is what it was before anything
;; touched it.
;; ============================================================================
global signal_method_getsignal
DEF_FUNC signal_method_getsignal, 16
    cmp rsi, 1
    jne .sg_argerr
    mov rdi, [rdi]
    call signal_arg
    lea rcx, [rel signal_handlers]
    mov rax, [rcx + rax*8]
    test rax, rax
    jz .sg_default
    INCREF_V rax, rcx
    leave
    ret
.sg_default:
    xor edi, edi
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
.sg_argerr:
    RAISE exc_TypeError_type, "getsignal() takes exactly 1 argument"
END_FUNC signal_method_getsignal

;; ============================================================================
;; signal_method_default_int_handler(args, nargs) -> never returns normally
;; The handler SIGINT starts with: it raises KeyboardInterrupt.
;; ============================================================================
global signal_method_default_int_handler
DEF_FUNC signal_method_default_int_handler
    RAISE exc_KeyboardInterrupt_type, ""
END_FUNC signal_method_default_int_handler

;; ============================================================================
;; signal_method_raise_signal(args, nargs) -> None
;; raise_signal(signum): send the signal to this process.
;; ============================================================================
global signal_method_raise_signal
DEF_FUNC signal_method_raise_signal, 16
    cmp rsi, 1
    jne .sr_argerr
    mov rdi, [rdi]
    call signal_arg
    push rax
    extern sys_getpid
    call sys_getpid
    pop rsi
    mov rdi, rax
    extern sys_kill
    call sys_kill
    test rax, rax
    js .sr_oserror
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.sr_oserror:
    neg rax
    mov rdi, rax
    xor esi, esi
    call raise_oserror
.sr_argerr:
    RAISE exc_TypeError_type, "raise_signal() takes exactly 1 argument"
END_FUNC signal_method_raise_signal

;; ============================================================================
;; signal_method_alarm(args, nargs) -> the seconds left on the previous alarm
;; ============================================================================
global signal_method_alarm
DEF_FUNC signal_method_alarm, 16
    cmp rsi, 1
    jne .sal_argerr
    mov rax, [rdi]
    V_UNPACK rax, rdx
    mov rdi, rax
    call obj_as_index
    mov rdi, rax
    call sys_alarm
    mov rdi, rax
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
.sal_argerr:
    RAISE exc_TypeError_type, "alarm() takes exactly 1 argument"
END_FUNC signal_method_alarm

;; ============================================================================
;; signal_method_pause(args, nargs) -> None
;; Blocks until a signal arrives.  Its handler runs at the next backward jump,
;; like any other, so a KeyboardInterrupt out of pause() surfaces there.
;; ============================================================================
global signal_method_pause
DEF_FUNC signal_method_pause, 16
    call sys_pause
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
END_FUNC signal_method_pause

;; ============================================================================
;; signal_method_strsignal(args, nargs) -> the platform's description, or None
;; ============================================================================
global signal_method_strsignal
DEF_FUNC signal_method_strsignal, 16
    cmp rsi, 1
    jne .sts_argerr
    mov rax, [rdi]
    V_UNPACK rax, rdx
    mov rdi, rax
    call obj_as_index
    test rax, rax
    jle .sts_none
    cmp rax, SIG_NSIG
    jae .sts_none
    mov rdi, rax
    call strsignal
    test rax, rax
    jz .sts_none
    mov rdi, rax
    call str_from_cstr
    leave
    V_PACK rax, rdx
    ret
.sts_none:
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.sts_argerr:
    RAISE exc_TypeError_type, "strsignal() takes exactly 1 argument"
END_FUNC signal_method_strsignal

;; ============================================================================
;; signal_default_init() -> void
;;
;; Called once at start-up: SIGINT gets default_int_handler, so Ctrl-C raises
;; KeyboardInterrupt at the next backward jump instead of killing the process
;; where it stands.  That is what CPython does, and what every `except
;; KeyboardInterrupt` in the stdlib is written against.
;;
;; SIGPIPE gets SIG_IGN, which CPython also does and for the same reason: a
;; write to a closed pipe should be a BrokenPipeError the program can catch,
;; not a signal that kills it where it stands.  Without it `apython foo.py |
;; head` died at exit code 141 with no message, and every test in CPython's
;; test_subprocess that closes a pipe early took the interpreter with it.
;; ============================================================================
SDI_FRAME equ 16            ; + 0 pushes = 16
global signal_default_init
DEF_FUNC signal_default_init, SDI_FRAME
    lea rdi, [rel signal_method_default_int_handler]
    lea rsi, [rel signal_s_default_int_handler]
    call builtin_func_new
    test rax, rax
    jz .sdi_done
    lea rcx, [rel signal_handlers]
    mov [rcx + 2*8], rax                    ; SIGINT
    mov edi, 2
    lea rsi, [rel signal_trampoline]
    call signal_install
.sdi_done:
    ; SIGPIPE -> SIG_IGN, recorded in the table as the int 1 so that
    ; getsignal(SIGPIPE) answers signal.SIG_IGN as CPython's does.
    mov edi, 13
    mov esi, 1                              ; SIG_IGN
    call signal_install
    test eax, eax
    js .sdi_out
    mov edi, 1
    extern int_from_i64
    call int_from_i64
    V_PACK rax, rdx
    lea rcx, [rel signal_handlers]
    mov [rcx + 13*8], rax
.sdi_out:
    leave
    ret
END_FUNC signal_default_init

;; ============================================================================
;; signal_module_create() -> PyObject*
;; The module: the numbers, the two sentinels, and the seven functions.
;; ============================================================================
SM_DICT  equ 8
SM_ENT   equ 16
SM_NAME  equ 24
SM_FRAME equ 32             ; + 2 pushes = 48
global signal_module_create
DEF_FUNC signal_module_create, SM_FRAME
    push rbx
    push r12
    call dict_new
    mov r12, rax
    mov [rbp - SM_DICT], rax

    lea rbx, [rel sig_name_table]
.sm_loop:
    mov rdi, [rbx]
    test rdi, rdi
    jz .sm_consts
    mov rdi, [rbx + 8]
    call sm_add_int_named
    add rbx, 16
    jmp .sm_loop

.sm_consts:
    lea rbx, [rel sig_const_table]
.sm_const_loop:
    mov rdi, [rbx]
    test rdi, rdi
    jz .sm_funcs
    mov rdi, [rbx + 8]
    call sm_add_int_named
    add rbx, 16
    jmp .sm_const_loop

.sm_funcs:
    MODULE_ADD_FUNC signal_method_signal,   signal_s_signal
    MODULE_ADD_FUNC signal_method_getsignal, signal_s_getsignal
    MODULE_ADD_FUNC signal_method_default_int_handler, signal_s_default_int_handler
    MODULE_ADD_FUNC signal_method_raise_signal, signal_s_raise_signal
    MODULE_ADD_FUNC signal_method_alarm,    signal_s_alarm
    MODULE_ADD_FUNC signal_method_pause,    signal_s_pause
    MODULE_ADD_FUNC signal_method_strsignal, signal_s_strsignal
    MODULE_ADD_FUNC signal_method_setitimer, signal_s_setitimer
    MODULE_ADD_FUNC signal_method_getitimer, signal_s_getitimer

    lea rdi, [rel signal_s_name]
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, rbx
    mov rsi, [rbp - SM_DICT]
    call module_new
    push rax
    mov rdi, rbx
    call obj_decref
    pop rax
    pop r12
    pop rbx
    leave
    ret
END_FUNC signal_module_create


;; ============================================================================
;; sig_seconds_to_timeval(rdi = a Value in seconds, rsi = where the timeval
;;                        goes) -> void, or raises
;;
;; The whole seconds and the microseconds, as setitimer wants them.  A
;; negative or non-numeric value is CPython's ValueError/TypeError.
;; ============================================================================
STV_PTR   equ 8
STV_ARG   equ 16            ; the argument itself, for the message
STV_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC_LOCAL sig_seconds_to_timeval, STV_FRAME
    mov [rbp - STV_PTR], rsi
    mov [rbp - STV_ARG], rdi
    V_UNPACK rdi, rsi
    push rdi
    push rsi
    extern float_binop_accepts
    call float_binop_accepts
    pop rsi
    pop rdi
    test eax, eax
    jz .stv_type
    extern float_to_f64
    call float_to_f64           ; seconds, as a double

    ; NaN is not a delay; a NEGATIVE one is left to the kernel, which refuses
    ; it with EINVAL -- CPython does the same, and the ItimerError that comes
    ; back is not the ValueError a check here would give.
    ucomisd xmm0, xmm0
    jp .stv_value

    roundsd xmm1, xmm0, 1       ; floor
    subsd xmm0, xmm1
    cvttsd2si rax, xmm1
    mov rcx, [rbp - STV_PTR]
    mov [rcx], rax              ; tv_sec
    mulsd xmm0, [rel sig_1e6]
    cvttsd2si rax, xmm0
    mov [rcx + 8], rax          ; tv_usec
    leave
    ret
.stv_type:
    ; CPython's wording, from the same conversion an index goes through.
    mov rsi, [rbp - STV_ARG]
    CSTRING rdi, `'\x01' object cannot be interpreted as an integer`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
.stv_value:
    RAISE exc_ValueError_type, "Invalid value NaN (not a number)"
END_FUNC sig_seconds_to_timeval

;; ============================================================================
;; sig_itimerval_tuple(rdi = a struct itimerval) -> rax = (delay, interval),
;;   both floats, or 0
;;
;; CPython's order is the VALUE first and the interval second, which is the
;; other way round from the struct's own.
;; ============================================================================
SIT_BUF   equ 8
SIT_TUP   equ 16
SIT_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC_LOCAL sig_itimerval_tuple, SIT_FRAME
    mov [rbp - SIT_BUF], rdi
    mov edi, 2
    extern tuple_new
    call tuple_new
    test rax, rax
    jz .sitt_fail
    mov [rbp - SIT_TUP], rax

    mov rcx, [rbp - SIT_BUF]
    lea rdi, [rcx + 16]         ; it_value
    call sig_timeval_seconds
    mov rcx, [rbp - SIT_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx], rax

    mov rcx, [rbp - SIT_BUF]
    mov rdi, rcx                ; it_interval
    call sig_timeval_seconds
    mov rcx, [rbp - SIT_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + 8], rax

    mov rax, [rbp - SIT_TUP]
.sitt_fail:
    leave
    ret
END_FUNC sig_itimerval_tuple

;; ============================================================================
;; sig_timeval_seconds(rdi = a struct timeval) -> rax = it, as a float Value
;; ============================================================================
DEF_FUNC_LOCAL sig_timeval_seconds
    cvtsi2sd xmm0, qword [rdi]
    cvtsi2sd xmm1, qword [rdi + 8]
    divsd xmm1, [rel sig_1e6]
    addsd xmm0, xmm1
    movq rax, xmm0
    V_FROM_F64 rax, rcx
    leave
    ret
END_FUNC sig_timeval_seconds

;; ============================================================================
;; signal_method_setitimer(args, nargs) -> the timer that was there before,
;;   as (delay, interval)
;;
;; signal.alarm takes whole seconds and nothing else, so a test that wants a
;; sub-second alarm -- which is most of the ones that test signal delivery at
;; all -- had nothing to reach for.
;; ============================================================================
SSI_NEW   equ 32            ; struct itimerval: interval, then value
SSI_OLD   equ 64
SSI_FRAME equ 80            ; + 0 pushes = 80
global signal_method_setitimer
DEF_FUNC signal_method_setitimer, SSI_FRAME
    cmp rsi, 2
    jl .ssi_argerr
    cmp rsi, 3
    jg .ssi_argerr
    push rsi
    push rdi

    ; it_interval, args[2] when it is there
    xor eax, eax
    mov [rbp - SSI_NEW], rax
    mov [rbp - SSI_NEW + 8], rax
    cmp qword [rsp + 8], 3
    jl .ssi_have_interval
    mov rdi, [rsp]
    mov rdi, [rdi + 16]
    lea rsi, [rbp - SSI_NEW]
    call sig_seconds_to_timeval
.ssi_have_interval:

    ; it_value, args[1]
    mov rdi, [rsp]
    mov rdi, [rdi + 8]
    lea rsi, [rbp - SSI_NEW + 16]
    call sig_seconds_to_timeval

    mov rdi, [rsp]
    mov rdi, [rdi]              ; which
    V_UNPACK rdi, rdx
    call obj_as_index
    mov rdi, rax
    add rsp, 16

    mov eax, 38                 ; __NR_setitimer
    lea rsi, [rbp - SSI_NEW]
    lea rdx, [rbp - SSI_OLD]
    syscall
    test rax, rax
    js .ssi_oserror

    lea rdi, [rbp - SSI_OLD]
    call sig_itimerval_tuple
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.ssi_oserror:
    neg rax
    mov rdi, rax
    xor esi, esi                ; no filename: raise_oserror reads one
    call raise_oserror
.ssi_argerr:
    ; CPython's two, which name the bound that was missed and the count.
    cmp rsi, 2
    jge .ssi_too_many
    extern raise_type_error_counted
    CSTRING rdi, "setitimer expected at least 2 arguments, got "
    xor edx, edx
    jmp raise_type_error_counted
.ssi_too_many:
    CSTRING rdi, "setitimer expected at most 3 arguments, got "
    xor edx, edx
    jmp raise_type_error_counted
END_FUNC signal_method_setitimer

;; ============================================================================
;; signal_method_getitimer(args, nargs) -> (delay, interval) for one timer
;; ============================================================================
SGI_CUR   equ 32
SGI_FRAME equ 48            ; + 0 pushes = 48
global signal_method_getitimer
DEF_FUNC signal_method_getitimer, SGI_FRAME
    cmp rsi, 1
    jne .sgi_argerr
    mov rdi, [rdi]
    V_UNPACK rdi, rdx
    call obj_as_index
    mov rdi, rax
    mov eax, 36                 ; __NR_getitimer
    lea rsi, [rbp - SGI_CUR]
    syscall
    test rax, rax
    js .sgi_oserror
    lea rdi, [rbp - SGI_CUR]
    call sig_itimerval_tuple
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.sgi_oserror:
    neg rax
    mov rdi, rax
    xor esi, esi                ; no filename: raise_oserror reads one
    call raise_oserror
.sgi_argerr:
    extern raise_type_error_counted
    CSTRING rdi, "_signal.getitimer() takes exactly one argument ("
    CSTRING rdx, " given)"
    jmp raise_type_error_counted
END_FUNC signal_method_getitimer

;; ============================================================================
;; sm_add_int_named(rdi = the value; rbx = the row) -> void
;; One `name = number` in the module dict, with the dict in r12 and the row's
;; name pointer at [rbx].
;; ============================================================================
SAN_ENT   equ 8
SAN_NAME  equ 16
SAN_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC_LOCAL sm_add_int_named, SAN_FRAME
    call int_from_i64
    V_PACK rax, rdx
    mov [rbp - SAN_ENT], rax
    mov rdi, [rbx]
    call str_from_cstr_heap
    mov [rbp - SAN_NAME], rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rbp - SAN_ENT]
    call dict_set
    mov rdi, [rbp - SAN_NAME]
    call obj_decref
    mov rax, [rbp - SAN_ENT]
    DECREF_V rax, rcx
    leave
    ret
END_FUNC sm_add_int_named

section .rodata
signal_s_name:      db "_signalcore", 0
signal_s_signal:    db "signal", 0
signal_s_getsignal: db "getsignal", 0
signal_s_default_int_handler: db "default_int_handler", 0
signal_s_raise_signal: db "raise_signal", 0
signal_s_alarm:     db "alarm", 0
signal_s_pause:     db "pause", 0
signal_s_strsignal: db "strsignal", 0
signal_s_setitimer: db "setitimer", 0
signal_s_getitimer: db "getitimer", 0

align 8
sig_1e6: dq 1000000.0

sig_c_SIG_DFL: db "SIG_DFL", 0
sig_c_SIG_IGN: db "SIG_IGN", 0
sig_c_NSIG:    db "NSIG", 0
sig_c_ITIMER_REAL: db "ITIMER_REAL", 0
sig_c_ITIMER_VIRTUAL: db "ITIMER_VIRTUAL", 0
sig_c_ITIMER_PROF: db "ITIMER_PROF", 0

align 8
sig_const_table:
    dq sig_c_SIG_DFL, 0
    dq sig_c_SIG_IGN, 1
    dq sig_c_NSIG, SIG_NSIG
    dq sig_c_ITIMER_REAL, 0
    dq sig_c_ITIMER_VIRTUAL, 1
    dq sig_c_ITIMER_PROF, 2
    dq 0, 0

; 34 signal names
sig_n_SIGHUP: db "SIGHUP", 0
sig_n_SIGINT: db "SIGINT", 0
sig_n_SIGQUIT: db "SIGQUIT", 0
sig_n_SIGILL: db "SIGILL", 0
sig_n_SIGTRAP: db "SIGTRAP", 0
sig_n_SIGABRT: db "SIGABRT", 0
sig_n_SIGIOT: db "SIGIOT", 0
sig_n_SIGBUS: db "SIGBUS", 0
sig_n_SIGFPE: db "SIGFPE", 0
sig_n_SIGKILL: db "SIGKILL", 0
sig_n_SIGUSR1: db "SIGUSR1", 0
sig_n_SIGSEGV: db "SIGSEGV", 0
sig_n_SIGUSR2: db "SIGUSR2", 0
sig_n_SIGPIPE: db "SIGPIPE", 0
sig_n_SIGALRM: db "SIGALRM", 0
sig_n_SIGTERM: db "SIGTERM", 0
sig_n_SIGSTKFLT: db "SIGSTKFLT", 0
sig_n_SIGCHLD: db "SIGCHLD", 0
sig_n_SIGCLD: db "SIGCLD", 0
sig_n_SIGCONT: db "SIGCONT", 0
sig_n_SIGSTOP: db "SIGSTOP", 0
sig_n_SIGTSTP: db "SIGTSTP", 0
sig_n_SIGTTIN: db "SIGTTIN", 0
sig_n_SIGTTOU: db "SIGTTOU", 0
sig_n_SIGURG: db "SIGURG", 0
sig_n_SIGXCPU: db "SIGXCPU", 0
sig_n_SIGXFSZ: db "SIGXFSZ", 0
sig_n_SIGVTALRM: db "SIGVTALRM", 0
sig_n_SIGPROF: db "SIGPROF", 0
sig_n_SIGWINCH: db "SIGWINCH", 0
sig_n_SIGIO: db "SIGIO", 0
sig_n_SIGPOLL: db "SIGPOLL", 0
sig_n_SIGPWR: db "SIGPWR", 0
sig_n_SIGSYS: db "SIGSYS", 0

align 8
sig_name_table:
    dq sig_n_SIGHUP, 1
    dq sig_n_SIGINT, 2
    dq sig_n_SIGQUIT, 3
    dq sig_n_SIGILL, 4
    dq sig_n_SIGTRAP, 5
    dq sig_n_SIGABRT, 6
    dq sig_n_SIGIOT, 6
    dq sig_n_SIGBUS, 7
    dq sig_n_SIGFPE, 8
    dq sig_n_SIGKILL, 9
    dq sig_n_SIGUSR1, 10
    dq sig_n_SIGSEGV, 11
    dq sig_n_SIGUSR2, 12
    dq sig_n_SIGPIPE, 13
    dq sig_n_SIGALRM, 14
    dq sig_n_SIGTERM, 15
    dq sig_n_SIGSTKFLT, 16
    dq sig_n_SIGCHLD, 17
    dq sig_n_SIGCLD, 17
    dq sig_n_SIGCONT, 18
    dq sig_n_SIGSTOP, 19
    dq sig_n_SIGTSTP, 20
    dq sig_n_SIGTTIN, 21
    dq sig_n_SIGTTOU, 22
    dq sig_n_SIGURG, 23
    dq sig_n_SIGXCPU, 24
    dq sig_n_SIGXFSZ, 25
    dq sig_n_SIGVTALRM, 26
    dq sig_n_SIGPROF, 27
    dq sig_n_SIGWINCH, 28
    dq sig_n_SIGIO, 29
    dq sig_n_SIGPOLL, 29
    dq sig_n_SIGPWR, 30
    dq sig_n_SIGSYS, 31
    dq 0, 0

