; posixproc.asm - the process primitives: fork, exec, wait and signal
;
; fork, execv, _exit, kill, setsid and PEP 3143's fork hooks.  They came out
; of posixmod.asm, which crossed the size cap when they arrived, and they are
; a seam of their own: everything else in that file is a question about a
; FILE, and these are the only ones that make a second process.
;
; `_posixsubprocess.fork_exec` is written on top of them in lib/, which is
; where the argument marshalling and the error pipe belong -- CPython's is C
; only because it must run between fork and exec, where almost nothing is
; safe to call, and the same is true of a Python function that allocates
; nothing new.

%include "macros.inc"
%include "object.inc"
%include "gil.inc"
%include "value.inc"

extern sys_fork
extern sys_execve
extern sys_exit_now
extern sys_kill
extern sys_setsid
extern sys_close_range
extern sys_pidfd_open
extern sys_wait4
extern int_from_i64
extern tuple_new
extern bool_true
extern bool_false
extern posix_int_arg
extern posix_path_arg
extern posix_embedded_nul
extern posix_set_missing
extern set_oserror
extern obj_dealloc
extern none_singleton
extern list_new
extern list_append
extern list_type
extern dict_type
extern tuple_type
extern str_type
extern ap_strcmp
extern environ
extern exc_TypeError_type
extern exc_ValueError_type
extern set_exception

global posix_fork
global posix_execv
global posix_exit_now
global posix_kill
global posix_setsid
global posix_close_range
global posix_pidfd_open
; The W* readers are exported by the macro that defines them, below.
global posix_waitpid
global posix_waitstatus_to_exitcode
global posix_register_at_fork
global pm_atfork_before
global pm_atfork_parent
global pm_atfork_child

;; POSIX_CHECK_RET result, filename, exit -- a negative errno becomes a
;; pending OSError and control goes to the caller's error exit.
%macro POSIX_CHECK_RET 3        ; %1 = the result register, %2 = filename Value,
                                ; %3 = the error exit
    cmp %1, -4095
    jb %%ok
    mov rdi, %1
    neg rdi
    mov rsi, %2
    call set_oserror
    jmp %3
%%ok:
%endmacro

;; PM_MISSING func, arg, pos -- the three-argument form of the arity error.
%macro PM_MISSING 4             ; %4 = the caller's error exit
    CSTRING rdi, %1
    CSTRING rsi, %2
    mov edx, %3
    call posix_set_missing      ; err: it always fails; %4 is where that goes
    jmp %4
%endmacro

section .bss
; The PEP 3143 fork hooks, one list each.  They are module state rather than
; dict entries because posix_fork walks them without a name lookup.
pm_atfork_before: resq 1
pm_atfork_parent: resq 1
pm_atfork_child:  resq 1

section .text

;; ============================================================================
;; posix.fork() -> 0 in the child, the child's pid in the parent
;;
;; The four primitives a subprocess needs, and nothing more: fork, execv,
;; _exit and kill.  `_posixsubprocess.fork_exec` is written on top of them in
;; lib/, which is where the argument marshalling and the error pipe belong --
;; CPython's is C only because it must run between fork and exec, where
;; almost nothing is safe to call, and the same is true of a Python function
;; that allocates nothing new.
;;
;; PEP 3143's hooks run around it.  CPython registers its own in C so that
;; its locks are reacquired in the child; the only caller here is random.py,
;; which reseeds so a forked child does not repeat the parent's stream.
;; ============================================================================
PFK_PID   equ 8
PFK_FRAME equ 16            ; + 1 push = 24... one more word to land right
DEF_FUNC posix_fork, 24                 ; + 1 push = 32, 16-aligned
    push rbx
    ; `before` runs in reverse registration order, as CPython's does.
    mov rdi, [rel pm_atfork_before]
    mov esi, 1
    call posix_run_fork_hooks

    extern gil_fork
    call gil_fork               ; glibc's fork, and the GIL reset in the child
    mov [rbp - PFK_PID], rax
    test rax, rax
    jl .pfk_failed

    mov rdi, [rel pm_atfork_parent]
    test rax, rax
    jnz .pfk_have_list
    extern signal_after_fork_child
    call signal_after_fork_child
    extern native_asyncio_clear_running_loop
    call native_asyncio_clear_running_loop
    mov rdi, [rel pm_atfork_child]
.pfk_have_list:
    xor esi, esi
    call posix_run_fork_hooks

    mov rax, [rbp - PFK_PID]
    mov edx, TAG_SMALLINT
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.pfk_failed:
    POSIX_CHECK_RET rax, 0, .pfk_fail
.pfk_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
END_FUNC posix_fork

;; ============================================================================
;; posix_run_fork_hooks(rdi = a list or 0, esi = 1 to walk it backwards)
;;   -> nothing.  A hook that raises is reported as unraisable and the
;;      exception is dropped, as CPython's run_at_forkers does: fork() itself
;;      still answers, and in the child there is nobody else to tell.  It used
;;      to stay pending behind a fork() that returned a pid, and surfaced at
;;      whatever asked next whether anything had failed.
;; ============================================================================
PRH_LIST  equ 8
PRH_I     equ 16
PRH_REV   equ 24
PRH_FN    equ 32            ; the hook being called, for the report
PRH_FRAME equ 32            ; + 1 push = 40... one more word to land right
DEF_FUNC_LOCAL posix_run_fork_hooks, 40 ; + 1 push = 48, 16-aligned
    push rbx
    mov rbx, rdi
    mov [rbp - PRH_LIST], rdi
    mov [rbp - PRH_REV], rsi
    test rdi, rdi
    jz .prh_done
    mov rax, [rdi + PyListObject.ob_size]
    test rax, rax
    jz .prh_done
    mov qword [rbp - PRH_I], 0
.prh_loop:
    mov rcx, [rbp - PRH_I]
    mov rbx, [rbp - PRH_LIST]
    cmp rcx, [rbx + PyListObject.ob_size]
    jge .prh_done
    cmp qword [rbp - PRH_REV], 0
    je .prh_forward
    mov rax, [rbx + PyListObject.ob_size]
    sub rax, rcx
    dec rax
    mov rcx, rax
.prh_forward:
    mov rax, [rbx + PyListObject.ob_item]
    mov rdi, [rax + rcx*8]
    V_TEST_PTR rdi, rax
    ja .prh_next
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .prh_next
    mov [rbp - PRH_FN], rdi
    xor esi, esi
    xor edx, edx
    call rax
    test rax, rax
    jz .prh_raised
    DECREF_V rax, rcx
    jmp .prh_next
.prh_raised:
    mov rdi, [gs:ThreadState.current_exception]
    test rdi, rdi
    jz .prh_next
    mov rsi, [rbp - PRH_FN]
    extern traceback_print_unraisable
    call traceback_print_unraisable
    mov rdi, [gs:ThreadState.current_exception]
    test rdi, rdi
    jz .prh_next
    mov qword [gs:ThreadState.current_exception], 0
    call obj_decref
.prh_next:
    inc qword [rbp - PRH_I]
    jmp .prh_loop
.prh_done:
    pop rbx
    leave
    ret
END_FUNC posix_run_fork_hooks

;; ============================================================================
;; posix.register_at_fork(*, before=None, after_in_parent=None,
;;                        after_in_child=None) -> None
;;
;; Keyword-only, as CPython's is, and at least one of the three is required.
;; ============================================================================
PRF_I     equ 8
PRF_NAMES equ 16
PRF_FRAME equ 32            ; + 2 pushes = 48, 16-aligned
DEF_FUNC posix_register_at_fork, PRF_FRAME
    push rbx
    push r12
    ; Everything arrives as a keyword: the positional count must be zero, and
    ; kw_names_pending names each one.
    mov rbx, rdi
    mov r12, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0
    test r12, r12
    jz .prf_none
    cmp rsi, [r12 + PyTupleObject.ob_size]
    jne .prf_positional

    mov qword [rbp - PRF_I], 0
.prf_loop:
    mov rcx, [rbp - PRF_I]
    cmp rcx, [r12 + PyTupleObject.ob_size]
    jge .prf_ok
    mov rax, [r12 + PyTupleObject.ob_item]
    mov rdi, [rax + rcx*8]              ; the keyword's name
    add rdi, PyStrObject.data
    CSTRING rsi, "before"
    call ap_strcmp
    mov rcx, [rbp - PRF_I]
    test eax, eax
    jz .prf_before

    mov rax, [r12 + PyTupleObject.ob_item]
    mov rdi, [rax + rcx*8]
    add rdi, PyStrObject.data
    CSTRING rsi, "after_in_parent"
    call ap_strcmp
    mov rcx, [rbp - PRF_I]
    test eax, eax
    jz .prf_parent

    mov rax, [r12 + PyTupleObject.ob_item]
    mov rdi, [rax + rcx*8]
    add rdi, PyStrObject.data
    CSTRING rsi, "after_in_child"
    call ap_strcmp
    mov rcx, [rbp - PRF_I]
    test eax, eax
    jnz .prf_unexpected
    mov rdi, [rel pm_atfork_child]
    jmp .prf_append
.prf_before:
    mov rdi, [rel pm_atfork_before]
    jmp .prf_append
.prf_parent:
    mov rdi, [rel pm_atfork_parent]
.prf_append:
    mov rsi, [rbx + rcx*8]              ; the callable
    lea rax, [rel none_singleton]
    cmp rsi, rax
    je .prf_next
    extern list_append
    call list_append          ; err: the three fork-hook lists are private to this module
.prf_next:
    inc qword [rbp - PRF_I]
    jmp .prf_loop

.prf_ok:
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.prf_none:
    FAIL exc_TypeError_type, "At least one argument is required.", .prf_fail
.prf_positional:
    FAIL exc_TypeError_type, \
        "register_at_fork() takes no positional arguments", .prf_fail
.prf_unexpected:
    SET_EXC exc_TypeError_type, \
        "register_at_fork() got an unexpected keyword argument"
.prf_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC posix_register_at_fork


;; ============================================================================
;; posix._exit(code) -> does not return
;;
;; The bare exit: no flush, no atexit handlers.  A forked child that failed to
;; exec has to call this rather than unwind, or it would run the parent's
;; cleanup a second time -- including flushing buffers the parent still owns.
;; ============================================================================
DEF_FUNC posix_exit_now
    test rsi, rsi
    jz .pen_zero
    mov rdi, [rdi]
    call posix_int_arg
    ERR_M1 .pen_fail
    mov rdi, rax
    jmp .pen_go
.pen_fail:                      ; a code that is not an int: nothing exits
    xor eax, eax
    leave
    ret
.pen_zero:
    xor edi, edi
.pen_go:
    and edi, 0xff
    call sys_exit_now
    ud2
END_FUNC posix_exit_now


;; ============================================================================
;; posix.kill(pid, sig) -> None
;; ============================================================================
DEF_FUNC posix_kill, 8         ; lint: pushes=1 -- the `push rbx` below sits after the
                            ; argument test, and lint counts only the pushes before
                            ; the first non-push instruction.  Unannotated it read
                            ; this frame as pushless and demanded the size that
                            ; MISALIGNS it.
    cmp rsi, 2
    jl .pk_argerr
    push rbx
    mov rbx, rdi
    mov rdi, [rbx]
    call posix_int_arg
    ERR_M1 .pk_fail
    push rax
    push rax
    mov rdi, [rbx + 8]
    call posix_int_arg
    ERR_M1 .pk_fail2
    mov rsi, rax
    pop rdi
    pop rdi
    call sys_kill
    POSIX_CHECK_RET rax, 0, .pk_fail
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.pk_argerr:
    PM_MISSING "kill", "sig", 2, .pk_fail0
.pk_fail2:
    add rsp, 16                 ; the first argument, parked twice
.pk_fail:
    pop rbx
.pk_fail0:
    xor eax, eax
    leave
    ret
END_FUNC posix_kill


;; ============================================================================
;; posix.closerange(fd_low, fd_high) -> None
;;
;; Shuts every descriptor in [fd_low, fd_high), which is CPython's half-open
;; span -- the close_range syscall's is inclusive, so the top is stepped down
;; by one.  A forked child cannot safely walk /proc to find what it inherited,
;; and `subprocess` asks for close_fds by DEFAULT, so without this every open
;; file, socket and pipe in the parent leaks into the child.
;;
;; Errors are swallowed, as CPython's is: closing a descriptor that was never
;; open is the ordinary case, not a failure.
;; ============================================================================
DEF_FUNC posix_close_range, 8         ; lint: pushes=1 -- the `push rbx` below sits after the
                            ; argument test, and lint counts only the pushes before
                            ; the first non-push instruction.  Unannotated it read
                            ; this frame as pushless and demanded the size that
                            ; MISALIGNS it.
    cmp rsi, 2
    jl .pcr_argerr
    push rbx
    mov rbx, rdi
    mov rdi, [rbx]
    call posix_int_arg
    ERR_M1 .pcr_fail
    push rax
    push rax
    mov rdi, [rbx + 8]
    call posix_int_arg
    ERR_M1 .pcr_fail2
    mov rsi, rax
    pop rdi
    pop rdi
    dec rsi                             ; CPython's top is exclusive
    cmp rsi, rdi
    jl .pcr_empty
    xor edx, edx
    call sys_close_range
.pcr_empty:
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.pcr_argerr:
    PM_MISSING "closerange", "fd_high", 2, .pcr_fail0
.pcr_fail2:
    add rsp, 16                 ; the first argument, parked twice
.pcr_fail:
    pop rbx
.pcr_fail0:
    xor eax, eax
    leave
    ret
END_FUNC posix_close_range

;; ============================================================================
;; posix.setsid() -> the new session id
;; ============================================================================
DEF_FUNC posix_setsid
    call sys_setsid
    POSIX_CHECK_RET rax, 0, .pss_fail
    mov edx, TAG_SMALLINT
    leave
    V_PACK rax, rdx
    ret
.pss_fail:
    xor eax, eax
    leave
    ret
END_FUNC posix_setsid

;; ============================================================================
;; posix.execv(path, args) -> does not return on success
;; posix.execve(path, args, env) -> likewise, with the environment given
;;
;; The argv array is built on the machine stack rather than the heap: this
;; runs in a freshly forked child, where the allocator's locks belong to a
;; thread that no longer exists.  There is one thread here, so that is
;; theatre -- but the array has to outlive nothing, and the stack is where it
;; naturally goes.
;;
;; Without a third argument the child inherits this process's environment,
;; which glibc already keeps as the NULL-terminated array execve wants.  With
;; one it gets exactly that list and nothing else -- which is the whole point
;; of `subprocess.run(env=...)`, and dropping it would hand the child every
;; variable the caller was trying to keep from it.
;; ============================================================================
PXV_PATH  equ 8
PXV_ARGS  equ 16
PXV_N     equ 24
PXV_OWNED equ 32            ; what posix_path_arg asked us to release
PXV_NARGS equ 40
PXV_MAX   equ 256
; The vector grows UPWARD from its base, so its slot is the DEEPEST one --
; naming it 32 put the first pointer over PXV_ARGS and the second over
; PXV_PATH.
; Two vectors: argv, then envp above it.  Each grows UPWARD from its base, so
; each slot names the DEEPEST word -- naming argv's 32 put its first pointer
; over PXV_ARGS and its second over PXV_PATH.
PXV_VEC   equ 48 + (PXV_MAX + 1) * 8
PXV_ENV   equ PXV_VEC + (PXV_MAX + 1) * 8
PXV_FRAME equ ((PXV_ENV + 15) / 16) * 16
DEF_FUNC posix_execv, PXV_FRAME
    push rbx
    mov qword [rbp - PXV_OWNED], 0
    cmp rsi, 2
    jl .pxv_argerr
    mov [rbp - PXV_NARGS], rsi
    mov rbx, rdi

    mov rdi, [rbx]
    xor esi, esi
    mov edx, -1                         ; every kind posix_path_arg takes
    call posix_path_arg
    ERR_NULL .pxv_fail
    mov [rbp - PXV_PATH], rax
    mov [rbp - PXV_OWNED], rdx

    mov rdi, [rbx + 8]
    lea rsi, [rbp - PXV_VEC]
    call pxv_string_vector
    ERR_NULL .pxv_fail

    ; The environment: the caller's when there is one, this process's when
    ; there is not.
    mov rdx, [rel environ]
    cmp qword [rbp - PXV_NARGS], 3
    jl .pxv_have_env
    mov rdi, [rbx + 16]
    lea rsi, [rbp - PXV_ENV]
    call pxv_env_vector
    ERR_NULL .pxv_fail
    lea rdx, [rbp - PXV_ENV]
.pxv_have_env:
    mov rdi, [rbp - PXV_PATH]
    lea rsi, [rbp - PXV_VEC]
    call sys_execve
    ; Only ever reached on failure.
    POSIX_CHECK_RET rax, 0, .pxv_fail
.pxv_fail:
    ; A PathLike's resolved path: nothing released it on any of these exits.
    mov rdi, [rbp - PXV_OWNED]
    test rdi, rdi
    jz .pxv_fail_out
    call obj_decref
.pxv_fail_out:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.pxv_argerr:
    PM_MISSING "execv", "args", 2, .pxv_fail
END_FUNC posix_execv

;; ============================================================================
;; pxv_string_vector(rdi = a list or tuple of str, rsi = where to build it)
;;   -> rax = 1, or 0 with a TypeError or ValueError pending
;; Fails: 0
;;
;; A NULL-terminated char*[] pointing INTO the strings, which is what execve
;; takes.  Nothing is copied: the strings outlive the call, because the call
;; either replaces the process or fails.
;; ============================================================================
PSV_SEQ   equ 8
PSV_OUT   equ 16
PSV_N     equ 24
PSV_FRAME equ 32            ; + 1 push = 40... one word more to land right
DEF_FUNC_LOCAL pxv_string_vector, 40    ; + 1 push = 48, 16-aligned
    push rbx
    mov [rbp - PSV_OUT], rsi
    mov rax, rdi
    V_TEST_PTR rax, rcx
    ja .psv_seqerr
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel list_type]
    cmp rcx, rdx
    je .psv_have_seq
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    jne .psv_seqerr
.psv_have_seq:
    mov [rbp - PSV_SEQ], rax
    mov rcx, [rax + PyTupleObject.ob_size]  ; list and tuple agree here
    cmp rcx, PXV_MAX
    jae .psv_toomany
    mov [rbp - PSV_N], rcx

    xor r10d, r10d
.psv_loop:
    cmp r10, [rbp - PSV_N]
    jge .psv_done
    mov rax, [rbp - PSV_SEQ]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdi, [rax + r10*8]
    V_TEST_PTR rdi, rcx
    ja .psv_seqerr
    mov rcx, [rdi + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .psv_seqerr
    ; An embedded NUL would truncate this argument where the exec'd program
    ; reads it, and nothing downstream could tell.  Refused, as CPython does.
    push r10
    push rdi                            ; twice, to keep rsp 16-byte aligned
    mov rsi, [rdi + PyStrObject.ob_size]
    add rdi, PyStrObject.data
    call posix_embedded_nul
    pop rdi
    pop r10
    test eax, eax
    jnz .psv_nul
    add rdi, PyStrObject.data
    mov rax, [rbp - PSV_OUT]
    mov [rax + r10*8], rdi
    inc r10
    jmp .psv_loop
.psv_done:
    mov rax, [rbp - PSV_OUT]
    mov qword [rax + r10*8], 0
    mov eax, 1
    pop rbx
    leave
    ret
.psv_seqerr:
    FAIL exc_TypeError_type, "execv() takes a sequence of strings", .psv_fail
.psv_toomany:
    FAIL exc_ValueError_type, "execv() was given too many strings", .psv_fail
.psv_nul:
    FAIL exc_ValueError_type, "embedded null byte", .psv_fail
.psv_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC pxv_string_vector

;; ============================================================================
;; pxv_env_vector(rdi = a mapping or a sequence of "K=V" strings,
;;                rsi = where to build it) -> rax = 1, or 0 with an exception
;; Fails: 0
;;
;; CPython's execve takes a MAPPING, and the strings it hands the kernel are
;; "key=value" pairs it builds itself.  _posixsubprocess already has that list
;; form -- subprocess.py assembles it -- so both are accepted, and a dict is
;; flattened into a scratch buffer here.
;;
;; The buffer is fixed because this may run in a freshly forked child, where
;; allocating is the one thing a program is told not to do.  Overflowing it is
;; a refusal rather than a truncation: a child that ran with HALF an
;; environment is worse than one that did not run.
;; ============================================================================
PEV_MAP   equ 8
PEV_OUT   equ 16
PEV_N     equ 24
PEV_POS   equ 32
PEV_I     equ 40
PEV_FRAME equ 64            ; + 2 pushes = 80, 16-aligned
DEF_FUNC_LOCAL pxv_env_vector, PEV_FRAME
    push rbx
    push r12
    mov rbx, rdi
    mov [rbp - PEV_MAP], rdi
    mov [rbp - PEV_OUT], rsi

    V_TEST_PTR rbx, rax
    ja .pev_bad
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel dict_type]
    cmp rax, rcx
    jne .pev_sequence

    mov qword [rbp - PEV_POS], 0
    mov qword [rbp - PEV_I], 0
    mov rax, [rbx + PyDictObject.ob_size]
    cmp rax, PXV_MAX
    jae .pev_toomany
    xor r12d, r12d                      ; how many pointers are written
.pev_loop:
    mov rcx, [rbp - PEV_I]
    cmp rcx, [rbx + PyDictObject.capacity]
    jge .pev_done
    mov rax, [rbx + PyDictObject.entries]
    imul rdx, rcx, DictEntry_size
    mov rdi, [rax + rdx + DictEntry.key]
    test rdi, rdi
    jz .pev_next                        ; empty, or a tombstone
    mov rsi, [rax + rdx + DictEntry.value]

    V_TEST_PTR rdi, rcx
    ja .pev_bad
    mov rcx, [rdi + PyObject.ob_type]
    lea rax, [rel str_type]
    cmp rcx, rax
    jne .pev_bad
    V_TEST_PTR rsi, rcx
    ja .pev_bad
    mov rcx, [rsi + PyObject.ob_type]
    cmp rcx, rax
    jne .pev_bad

    ; pev_append copies up to the first NUL, so an embedded one truncates the
    ; entry where execve reads it -- and a NUL in the KEY produces an entry
    ; with no '=' in it at all, which is not an environment variable of any
    ; name.  Both halves are checked here, before anything is written, so a
    ; refusal leaves no half-built entry in the buffer.
    push rdi
    push rsi                            ; an even count keeps rsp 16-aligned
    mov rsi, [rdi + PyStrObject.ob_size]
    add rdi, PyStrObject.data
    call posix_embedded_nul
    test eax, eax
    jnz .pev_nul
    mov rdi, [rsp]                      ; the value
    mov rsi, [rdi + PyStrObject.ob_size]
    add rdi, PyStrObject.data
    call posix_embedded_nul
    test eax, eax
    jnz .pev_nul
    pop rsi
    pop rdi

    ; An '=' in the NAME is the same failure wearing a different byte: the
    ; entry is built as "<key>=<value>", so a key of "FRUIT=ORANGE" with the
    ; value "lemon" becomes "FRUIT=ORANGE=lemon" -- which sets FRUIT, not the
    ; variable that was asked for.  CPython refuses it, and names it
    ; separately because it is not a NUL.
    push rdi
    push rsi                            ; an even count keeps rsp 16-aligned
    mov rcx, [rdi + PyStrObject.ob_size]
    add rdi, PyStrObject.data
    xor eax, eax
.pev_eq_scan:
    cmp rax, rcx
    jge .pev_eq_ok
    cmp byte [rdi + rax], '='
    je .pev_badname
    inc rax
    jmp .pev_eq_scan
.pev_eq_ok:
    pop rsi
    pop rdi

    ; This entry's text starts where the buffer has got to.
    mov rax, [rbp - PEV_OUT]
    mov rcx, [rbp - PEV_POS]
    lea rdx, [rel pxv_envbuf]
    add rdx, rcx
    mov [rax + r12*8], rdx
    inc r12

    push rsi
    add rdi, PyStrObject.data
    call pev_append
    pop rsi
    test eax, eax
    jz .pev_full
    mov rcx, [rbp - PEV_POS]
    lea rdx, [rel pxv_envbuf]
    mov byte [rdx + rcx], '='
    inc qword [rbp - PEV_POS]
    mov rdi, rsi
    add rdi, PyStrObject.data
    call pev_append
    test eax, eax
    jz .pev_full
    mov rcx, [rbp - PEV_POS]
    lea rdx, [rel pxv_envbuf]
    mov byte [rdx + rcx], 0
    inc qword [rbp - PEV_POS]
.pev_next:
    inc qword [rbp - PEV_I]
    jmp .pev_loop
.pev_done:
    mov rax, [rbp - PEV_OUT]
    mov qword [rax + r12*8], 0
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret

.pev_sequence:
    mov rdi, rbx
    mov rsi, [rbp - PEV_OUT]
    call pxv_string_vector      ; err: its 0 and its exception are ours
    pop r12
    pop rbx
    leave
    ret

.pev_bad:
    FAIL exc_TypeError_type, \
        "execve() arg 3 must be a mapping of str to str", .pev_fail
.pev_toomany:
.pev_full:
    FAIL exc_ValueError_type, "execve() environment is too large", .pev_fail
.pev_nul:
    SET_EXC exc_ValueError_type, "embedded null byte"
    jmp .pev_fail_pop2
.pev_badname:
    SET_EXC exc_ValueError_type, "illegal environment variable name"
.pev_fail_pop2:
    add rsp, 16                 ; the key and the value, parked for the scan
.pev_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

; Local: append a NUL-terminated string to the scratch buffer, advancing
; PEV_POS in this frame.  eax = 0 when it would not fit.
.pev_append_body:
pev_append:
    mov rcx, [rbp - PEV_POS]
    lea rdx, [rel pxv_envbuf]
.pea_loop:
    cmp rcx, PXV_ENVBUF - 2
    jae .pea_full
    movzx eax, byte [rdi]
    test al, al
    jz .pea_done
    mov [rdx + rcx], al
    inc rcx
    inc rdi
    jmp .pea_loop
.pea_done:
    mov [rbp - PEV_POS], rcx
    mov eax, 1
    ret
.pea_full:
    xor eax, eax
    ret
END_FUNC pxv_env_vector

PXV_ENVBUF equ 65536

section .bss
; The environment a dict is flattened into.  Fixed, because this may run in a
; freshly forked child where allocating is the one thing not to do.
pxv_envbuf: resb PXV_ENVBUF

section .text

;; ============================================================================
;; posix.putenv(name, value) -> None   /   posix.unsetenv(name) -> None
;;
;; os.environ.__setitem__ calls the first and __delitem__ the second, so
;; without them `os.environ["X"] = "1"` is a NameError -- which is what the
;; setUp of CPython's test_argparse does on every one of its four hundred
;; tests, and what os_helper.EnvironmentVarGuard is built on.
;;
;; They go through libc rather than a syscall because there is no syscall:
;; the environment is a process-image thing, and glibc's `environ` is what
;; execve is handed here, so setenv keeps the child's view in step with this
;; one's for free.
;;
;; The two refusals are CPython's.  A name with '=' in it is a ValueError
;; because it could not be read back; an empty one is what setenv itself
;; refuses, with EINVAL.
;;
;;   posix_putenv(rdi = args, rsi = nargs) -> rax = Value (None), or 0 raising
;;   posix_unsetenv(rdi = args, rsi = nargs) -> rax = Value (None), or 0 raising
;; ============================================================================
POSIX_PATH_KIND_PLAIN equ 0     ; spelled out: posix.asm is at the 100k cap

%macro PXE_PATH_DONE 1          ; %1 = a frame slot holding what rdx returned
    mov rdi, %1
    test rdi, rdi
    jz %%none
    mov qword %1, 0
    call obj_decref
%%none:
%endmacro

extern obj_decref
extern setenv
extern unsetenv
extern builtin_func_new
extern str_from_cstr_heap
extern dict_set

;; posix_putenv(rdi = args, rsi = nargs) -> rax = Value (None)
;; Fails: 0
PPE_NAME  equ 8             ; the C string
PPE_VALUE equ 16
PPE_ON    equ 24            ; the object holding the name's bytes
PPE_OV    equ 32            ; and the value's
PPE_RC    equ 40            ; setenv's answer, across the releases
PPE_FRAME equ 56            ; + 1 push = 64, 16-aligned
DEF_FUNC posix_putenv, PPE_FRAME
    push rbx
    mov qword [rbp - PPE_ON], 0
    mov qword [rbp - PPE_OV], 0
    cmp rsi, 2
    jne .ppe_argerr
    mov rbx, rdi

    mov rdi, [rbx]
    CSTRING rsi, "putenv: name"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    ERR_NULL .ppe_fail
    mov [rbp - PPE_NAME], rax
    mov [rbp - PPE_ON], rdx

    mov rdi, [rbx + 8]
    CSTRING rsi, "putenv: value"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    ERR_NULL .ppe_fail
    mov [rbp - PPE_VALUE], rax
    mov [rbp - PPE_OV], rdx

    ; A name carrying '=' could never be read back, and CPython says so.
    mov rdi, [rbp - PPE_NAME]
.ppe_scan:
    movzx eax, byte [rdi]
    test al, al
    jz .ppe_name_ok
    cmp al, '='
    je .ppe_badname
    inc rdi
    jmp .ppe_scan
.ppe_name_ok:

    mov rdi, [rbp - PPE_NAME]
    mov rsi, [rbp - PPE_VALUE]
    mov edx, 1                      ; overwrite
    call setenv wrt ..plt
    mov [rbp - PPE_RC], eax
    PXE_PATH_DONE [rbp - PPE_OV]
    PXE_PATH_DONE [rbp - PPE_ON]
    cmp dword [rbp - PPE_RC], 0
    jne .ppe_failed_set

    RET_NONE
    pop rbx
    leave
    ret

.ppe_failed_set:
    ; setenv refuses an empty name with EINVAL, and has nothing else to fail
    ; on once the name has been checked.
    mov edi, 22                     ; EINVAL
    xor esi, esi
    call set_oserror
    jmp .ppe_fail

.ppe_badname:
    SET_EXC exc_ValueError_type, "illegal environment variable name"

.ppe_fail:
    PXE_PATH_DONE [rbp - PPE_OV]
    PXE_PATH_DONE [rbp - PPE_ON]
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret

.ppe_argerr:
    FAIL exc_TypeError_type, "putenv expected 2 arguments", .ppe_fail
END_FUNC posix_putenv

;; posix_unsetenv(rdi = args, rsi = nargs) -> rax = Value (None)
;; Fails: 0
PUE_NAME  equ 8
PUE_ON    equ 16
PUE_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC posix_unsetenv, PUE_FRAME
    push rbx
    mov qword [rbp - PUE_ON], 0
    cmp rsi, 1
    jne .pue_argerr
    mov rbx, rdi

    mov rdi, [rbx]
    CSTRING rsi, "unsetenv: name"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    ERR_NULL .pue_fail
    mov [rbp - PUE_NAME], rax
    mov [rbp - PUE_ON], rdx

    mov rdi, [rbp - PUE_NAME]
    call unsetenv wrt ..plt
    PXE_PATH_DONE [rbp - PUE_ON]

    RET_NONE
    pop rbx
    leave
    ret

.pue_fail:
    PXE_PATH_DONE [rbp - PUE_ON]
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret

.pue_argerr:
    FAIL exc_TypeError_type, "unsetenv expected 1 argument", .pue_fail
END_FUNC posix_unsetenv

;; ============================================================================
;; posixproc_register_env(rdi = the posix module dict) -> void
;; Two entries, registered from here because posix.asm is at the 100k cap.
;; ============================================================================
PRE_FRAME equ 16            ; + 1 push = 24 ... padded below
DEF_FUNC posixproc_register_env, PRE_FRAME
    push r12
    sub rsp, 8                  ; pad: 16 + 8 + 8 = 32, so the calls are aligned
    mov r12, rdi
    MODULE_ADD_FUNC posix_putenv, pxe_n_putenv
    MODULE_ADD_FUNC posix_unsetenv, pxe_n_unsetenv
    add rsp, 8
    pop r12
    leave
    ret
END_FUNC posixproc_register_env

section .rodata
pxe_n_putenv:   db "putenv", 0
pxe_n_unsetenv: db "unsetenv", 0
section .text

;; ============================================================================
;; posix.waitpid(pid, options) -> (pid, status), and the W* status readers.
;;
;; The status word's encoding, which subprocess and multiprocessing decode by
;; hand through these:
;;   low 7 bits == 0x7f  -> stopped, and (status >> 8) & 0xff is the signal
;;   low 7 bits == 0     -> exited,  and (status >> 8) & 0xff is the code
;;   otherwise           -> signalled, and the low 7 bits are the signal
;;   bit 7 within a signalled status is the core-dump flag
;; ============================================================================
PWP_STATUS equ 8
PWP_TUP    equ 16
; 24 and not 32: the `push rbx` below is a push, wherever it sits.  It comes
; after the arity test rather than before it, and lint's alignment check counts
; only the pushes BEFORE the first non-push instruction -- so it read this frame
; as pushless and passed it, while every call in the body was made eight out.
PWP_FRAME  equ 24           ; + 1 push = 32, 16-aligned

DEF_FUNC posix_waitpid, PWP_FRAME   ; lint: pushes=1 -- see PWP_FRAME above
    cmp rsi, 2
    jl .pwp_argerr
    push rbx
    mov rbx, rdi
    mov rdi, [rbx]
    call posix_int_arg
    ERR_M1 .pwp_fail
    push rax
    push rax
    mov rdi, [rbx + 8]
    call posix_int_arg
    ERR_M1 .pwp_fail2
    mov rdx, rax                    ; options
    pop rdi
    pop rdi                         ; pid
    lea rsi, [rbp - PWP_STATUS]
    mov qword [rbp - PWP_STATUS], 0
    xor ecx, ecx                    ; no rusage
    BLOCKING_CALL sys_wait4
    POSIX_CHECK_RET rax, 0, .pwp_fail
    push rax
    push rax
    mov edi, 2
    call tuple_new
    pop rdi
    pop rdi                         ; the pid wait4 reported
    test rax, rax
    jz .pwp_fail
    mov [rbp - PWP_TUP], rax
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - PWP_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx], rax
    mov edi, [rbp - PWP_STATUS]
    movsxd rdi, edi
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - PWP_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + 8], rax
    mov rax, [rbp - PWP_TUP]
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.pwp_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.pwp_argerr:
    SET_EXC exc_TypeError_type, "waitpid() takes exactly 2 arguments"
    leave                           ; nothing pushed yet; rax = 0
    ret
.pwp_fail2:
    add rsp, 16                     ; the pid, parked twice
    jmp .pwp_fail
END_FUNC posix_waitpid

;; The status readers.  Each takes the status word and answers an int or a
;; bool; every one of them is pure bit arithmetic on it.
%macro POSIX_WSTATUS 3          ; %1 = name, %2 = the body label, %3 = message
DEF_FUNC %1, 16
    test rsi, rsi
    jz %%argerr
    mov rdi, [rdi]
    call posix_int_arg
    ERR_M1 %%fail
    jmp %2
%%argerr:
    SET_EXC exc_TypeError_type, %3
%%fail:
    xor eax, eax
    leave
    ret
END_FUNC %1
%endmacro

;; Shared tails.  Each expects the status in rax and leaves through the
;; caller's frame, so each is entered with `jmp` from a wrapper that has one.
; Plain labels, not functions: each wrapper reaches them with `jmp` after
; setting up its own frame, and the `leave` here pops that one.  A prologue
; would push a second rbp that nothing ever pops.
pw_ret_int:
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    mov edx, TAG_PTR
    leave
    ret

pw_ret_bool:
    test eax, eax
    jz .prb_false
    lea rax, [rel bool_true]
    jmp .prb_out
.prb_false:
    lea rax, [rel bool_false]
.prb_out:
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret

pw_exitstatus:
    shr rax, 8
    and rax, 0xff
    jmp pw_ret_int
pw_termsig:
    and rax, 0x7f
    jmp pw_ret_int
pw_stopsig:
    shr rax, 8
    and rax, 0xff
    jmp pw_ret_int
pw_ifexited:
    and eax, 0x7f
    test eax, eax
    setz al
    movzx eax, al
    jmp pw_ret_bool
pw_ifstopped:
    and eax, 0xff
    cmp eax, 0x7f
    sete al
    movzx eax, al
    jmp pw_ret_bool
pw_ifsignaled:
    ; glibc: ((signed char) (((status) & 0x7f) + 1) >> 1) > 0
    ;
    ; The signed-char cast is the whole macro.  0x7f + 1 is 128, which as a
    ; signed byte is -128 and shifts to -64 -- not greater than zero, which is
    ; how a STOPPED status (low byte 0x7f) and a CONTINUED one (0xffff) are
    ; excluded.  Without the cast both answered "signalled".
    mov ecx, eax
    and ecx, 0x7f
    inc ecx
    movsx ecx, cl
    sar ecx, 1
    xor eax, eax
    test ecx, ecx
    setg al                     ; signed, not setnz
    jmp pw_ret_bool
pw_ifcontinued:
    cmp eax, 0xffff
    sete al
    movzx eax, al
    jmp pw_ret_bool
pw_coredump:
    and eax, 0x80
    jmp pw_ret_bool

POSIX_WSTATUS posix_wexitstatus, pw_exitstatus, "WEXITSTATUS() takes exactly 1 argument"
POSIX_WSTATUS posix_wtermsig,    pw_termsig,    "WTERMSIG() takes exactly 1 argument"
POSIX_WSTATUS posix_wstopsig,    pw_stopsig,    "WSTOPSIG() takes exactly 1 argument"
POSIX_WSTATUS posix_wifexited,   pw_ifexited,   "WIFEXITED() takes exactly 1 argument"
POSIX_WSTATUS posix_wifstopped,  pw_ifstopped,  "WIFSTOPPED() takes exactly 1 argument"
POSIX_WSTATUS posix_wifsignaled, pw_ifsignaled, "WIFSIGNALED() takes exactly 1 argument"
POSIX_WSTATUS posix_wifcontinued, pw_ifcontinued, "WIFCONTINUED() takes exactly 1 argument"
POSIX_WSTATUS posix_wcoredump,   pw_coredump,   "WCOREDUMP() takes exactly 1 argument"

;; posix.waitstatus_to_exitcode(status) -> int
;; Exited: the code.  Signalled: minus the signal.  Anything else: ValueError.
DEF_FUNC posix_waitstatus_to_exitcode, 16
    test rsi, rsi
    jz .pwe_argerr
    mov rdi, [rdi]
    call posix_int_arg
    ERR_M1 .pwe_fail
    mov ecx, eax
    and ecx, 0x7f
    test ecx, ecx
    jnz .pwe_signalled
    shr rax, 8
    and rax, 0xff
    jmp pw_ret_int
.pwe_signalled:
    ; The same signed-char test: a stopped or continued status is neither an
    ; exit nor a signal, and CPython raises for it.
    mov ecx, eax
    and ecx, 0x7f
    inc ecx
    movsx ecx, cl
    sar ecx, 1
    test ecx, ecx
    jle .pwe_bad
    and eax, 0x7f
    neg rax
    jmp pw_ret_int
.pwe_bad:
    SET_EXC exc_ValueError_type, "Invalid wait status"
    leave
    ret
.pwe_argerr:
    SET_EXC exc_TypeError_type, "waitstatus_to_exitcode() takes exactly 1 argument"
    leave
    ret
.pwe_fail:
    xor eax, eax
    leave
    ret
END_FUNC posix_waitstatus_to_exitcode

section .text

;; ============================================================================
;; posix.prlimit(pid, resource, soft=None, hard=None) -> (soft, hard)
;;
;; getrlimit, setrlimit and prlimit in one entry point, because they are one
;; syscall: `new` is NULL for a read and `old` is always asked for, so a set
;; answers what the limit WAS, which is what CPython's prlimit returns.  pid 0
;; is this process, and lib/resource.py builds getrlimit and setrlimit on it.
;;
;; RLIM_INFINITY is (unsigned)-1 to the kernel and CPython reports it as -1, so
;; the two values are handed across as SIGNED 64-bit and converted at the
;; boundary rather than in Python.
;; ============================================================================
PRL_NEW  equ 16             ; struct rlimit64 new: two u64
PRL_OLD  equ 32             ; struct rlimit64 old
PRL_PID  equ 40
PRL_RES  equ 48
PRL_FRAME equ 64            ; + 1 push = 72... padded below
global posix_prlimit
DEF_FUNC posix_prlimit, PRL_FRAME
    push rbx
    push r12
    ; Exactly 2 or exactly 4.  Three used to be admitted and then silently
    ; ignored: the `cmp r12, 4 / jb .prl_call` below skips the `new` struct
    ; whenever the count is short, so posix.prlimit(0, res, 512) reported
    ; success and set nothing.
    cmp rsi, 2
    je .prl_have_argc
    cmp rsi, 4
    jne .prl_argerr
.prl_have_argc:
    mov rbx, rdi
    mov r12, rsi

    mov rdi, [rbx]
    call posix_int_arg
    ERR_M1 .prl_failed_nomem
    mov [rbp - PRL_PID], rax
    mov rdi, [rbx + 8]
    call posix_int_arg
    ERR_M1 .prl_failed_nomem
    mov [rbp - PRL_RES], rax

    xor edx, edx                        ; no `new` unless both limits are given
    cmp r12, 4
    jb .prl_call
    mov rax, [rbx + 16]
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .prl_call
    mov rdi, rax
    call posix_int_arg
    ERR_M1 .prl_failed_nomem
    mov [rbp - PRL_NEW], rax
    mov rdi, [rbx + 24]
    call posix_int_arg
    ERR_M1 .prl_failed_nomem
    mov [rbp - PRL_NEW + 8], rax
    lea rdx, [rbp - PRL_NEW]

.prl_call:
    mov rdi, [rbp - PRL_PID]
    mov rsi, [rbp - PRL_RES]
    lea rcx, [rbp - PRL_OLD]
    extern sys_prlimit64
    call sys_prlimit64
    test rax, rax
    js .prl_failed

    mov edi, 2
    call tuple_new
    test rax, rax
    jz .prl_failed_nomem
    mov rbx, rax
    mov rdi, [rbp - PRL_OLD]
    call int_from_i64
    V_PACK rax, rdx                     ; a (payload, tag) pair, not a Value
    mov rcx, [rbx + PyTupleObject.ob_item]
    mov [rcx], rax
    mov rdi, [rbp - PRL_OLD + 8]
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbx + PyTupleObject.ob_item]
    mov [rcx + 8], rax
    mov rax, rbx
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.prl_failed:
    neg eax
    mov edi, eax
    xor esi, esi
    call set_oserror
.prl_failed_nomem:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret
.prl_argerr:
    FAIL exc_TypeError_type, "prlimit() takes exactly 2 or 4 arguments", .prl_failed_nomem
END_FUNC posix_prlimit

;; ============================================================================
;; posix.getrusage(who) -> a 16-tuple of the fields CPython's struct_rusage
;;   carries, in its order
;;
;; struct rusage is two timevals and fourteen longs.  The two times come back
;; as FLOATS of seconds, which is what CPython reports; everything after them
;; is an integer, and the fields Linux does not maintain are 0 there too.
;; lib/resource.py names them.
;; ============================================================================
GRU_BUF   equ 160           ; struct rusage is 144 bytes
GRU_TUP   equ 168
GRU_FRAME equ 176           ; + 1 push = 184... padded below
global posix_getrusage
DEF_FUNC posix_getrusage, GRU_FRAME
    push rbx
    push r12
    test rsi, rsi
    jz .gru_argerr
    mov rdi, [rdi]
    call posix_int_arg
    ERR_M1 .gru_nomem
    mov rdi, rax
    lea rsi, [rbp - GRU_BUF]
    extern sys_getrusage
    call sys_getrusage
    test rax, rax
    js .gru_failed

    mov edi, 16
    call tuple_new
    test rax, rax
    jz .gru_nomem
    mov [rbp - GRU_TUP], rax

    ; ru_utime and ru_stime, each a struct timeval at +0 and +16.
    xor r12d, r12d
.gru_time_loop:
    mov rax, r12
    shl rax, 4                          ; 0 then 16
    lea rcx, [rbp - GRU_BUF]
    cvtsi2sd xmm0, qword [rcx + rax]    ; tv_sec
    cvtsi2sd xmm1, qword [rcx + rax + 8]; tv_usec
    mov edi, 1000000
    cvtsi2sd xmm2, rdi
    divsd xmm1, xmm2
    addsd xmm0, xmm1
    movq rax, xmm0
    V_FROM_F64 rax, rcx
    mov rcx, [rbp - GRU_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + r12*8], rax
    inc r12
    cmp r12, 2
    jb .gru_time_loop

    ; The fourteen longs that follow, at +32 upwards.
.gru_long_loop:
    lea rcx, [rbp - GRU_BUF]
    mov rdi, [rcx + r12*8 + 16]         ; field i sits at 32 + (i-2)*8
    call int_from_i64
    V_PACK rax, rdx                     ; a (payload, tag) pair, not a Value
    mov rcx, [rbp - GRU_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + r12*8], rax
    inc r12
    cmp r12, 16
    jb .gru_long_loop

    mov rax, [rbp - GRU_TUP]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.gru_failed:
    neg eax
    mov edi, eax
    xor esi, esi
    call set_oserror
.gru_nomem:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret
.gru_argerr:
    FAIL exc_TypeError_type, "getrusage() takes exactly 1 argument", .gru_nomem
END_FUNC posix_getrusage

;; ============================================================================
;; posix.pidfd_open(pid, flags=0) -> int fd
;;
;; Opens a Linux pidfd for `pid` via SYS_pidfd_open (434).  The kernel sets
;; O_CLOEXEC automatically.  Accepts positional or keyword pid=/flags=.
;; ============================================================================
PFO_PID   equ 8
PFO_FLAGS equ 16
PFO_HAVE  equ 24
PFO_NPOS  equ 32
PFO_ARGS  equ 40
PFO_I     equ 48
PFO_FRAME equ 48            ; + 2 pushes = 64, 16-aligned
DEF_FUNC posix_pidfd_open, PFO_FRAME
    push rbx
    push r12
    mov [rbp - PFO_ARGS], rdi
    mov [rbp - PFO_NPOS], rsi
    mov qword [rbp - PFO_PID], 0
    mov qword [rbp - PFO_FLAGS], 0
    mov qword [rbp - PFO_HAVE], 0

    mov r12, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0
    test r12, r12
    jz .pfo_pos
    mov rax, [r12 + PyTupleObject.ob_size]
    sub [rbp - PFO_NPOS], rax

.pfo_pos:
    mov rax, [rbp - PFO_NPOS]
    cmp rax, 2
    ja .pfo_toomany
    test rax, rax
    jz .pfo_kw
    mov rbx, [rbp - PFO_ARGS]
    mov rax, [rbx]
    mov [rbp - PFO_PID], rax
    or qword [rbp - PFO_HAVE], 1
    cmp qword [rbp - PFO_NPOS], 2
    jb .pfo_kw
    mov rax, [rbx + 8]
    mov [rbp - PFO_FLAGS], rax
    or qword [rbp - PFO_HAVE], 2

.pfo_kw:
    test r12, r12
    jz .pfo_parse
    mov qword [rbp - PFO_I], 0
.pfo_kw_loop:
    mov rcx, [rbp - PFO_I]
    cmp rcx, [r12 + PyTupleObject.ob_size]
    jae .pfo_parse
    mov rax, [r12 + PyTupleObject.ob_item]
    mov rdi, [rax + rcx*8]
    add rdi, PyStrObject.data
    CSTRING rsi, "pid"
    call ap_strcmp
    mov rcx, [rbp - PFO_I]
    test eax, eax
    jz .pfo_kw_pid
    mov rax, [r12 + PyTupleObject.ob_item]
    mov rdi, [rax + rcx*8]
    add rdi, PyStrObject.data
    CSTRING rsi, "flags"
    call ap_strcmp
    mov rcx, [rbp - PFO_I]
    test eax, eax
    jnz .pfo_badkw
    test qword [rbp - PFO_HAVE], 2
    jnz .pfo_dup
    mov rdx, [rbp - PFO_NPOS]
    add rdx, rcx
    mov rbx, [rbp - PFO_ARGS]
    mov rax, [rbx + rdx*8]
    mov [rbp - PFO_FLAGS], rax
    or qword [rbp - PFO_HAVE], 2
    jmp .pfo_kw_next
.pfo_kw_pid:
    test qword [rbp - PFO_HAVE], 1
    jnz .pfo_dup
    mov rdx, [rbp - PFO_NPOS]
    add rdx, rcx
    mov rbx, [rbp - PFO_ARGS]
    mov rax, [rbx + rdx*8]
    mov [rbp - PFO_PID], rax
    or qword [rbp - PFO_HAVE], 1
.pfo_kw_next:
    inc qword [rbp - PFO_I]
    jmp .pfo_kw_loop

.pfo_parse:
    test qword [rbp - PFO_HAVE], 1
    jz .pfo_missing
    mov rdi, [rbp - PFO_PID]
    call posix_int_arg
    ERR_M1 .pfo_fail
    mov rbx, rax                    ; rbx = pid
    xor r12d, r12d                  ; r12 = flags (default 0)
    test qword [rbp - PFO_HAVE], 2
    jz .pfo_call
    mov rdi, [rbp - PFO_FLAGS]
    call posix_int_arg
    ERR_M1 .pfo_fail
    test rax, rax
    js .pfo_neg_flags
    mov r12, rax

.pfo_call:
    mov rdi, rbx
    mov rsi, r12
    call sys_pidfd_open
    POSIX_CHECK_RET rax, 0, .pfo_fail
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    pop r12
    pop rbx
    leave
    ret
.pfo_neg_flags:
    FAIL exc_ValueError_type, "value must be positive", .pfo_fail
.pfo_missing:
    PM_MISSING "pidfd_open", "pid", 1, .pfo_fail
.pfo_toomany:
    FAIL exc_TypeError_type, "pidfd_open() takes at most 2 arguments", .pfo_fail
.pfo_badkw:
    FAIL exc_TypeError_type, "pidfd_open() got an unexpected keyword argument", .pfo_fail
.pfo_dup:
    FAIL exc_TypeError_type, "pidfd_open() got multiple values for argument", .pfo_fail
.pfo_fail:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret
END_FUNC posix_pidfd_open
