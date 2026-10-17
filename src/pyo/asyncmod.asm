; asyncmod.asm - asyncio builtin module
;
; Provides: asyncio.run, asyncio.sleep, asyncio.create_task, asyncio.gather,
;           asyncio.wait_for, asyncio.get_running_loop
;
; asyncio.run(coro) — main entry point
; asyncio.sleep(delay) — suspend for delay seconds
; asyncio.create_task(coro) — wrap coro in a Task and schedule it
; asyncio.gather(*coros) — run multiple coros concurrently

%include "macros.inc"
%include "object.inc"
%include "eventloop.inc"

extern ap_strcmp
extern obj_is_true
extern task_type
extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern ap_free
extern obj_decref
extern obj_incref
extern obj_dealloc
extern str_from_cstr_heap
extern dict_new
extern dict_set
extern module_new
extern builtin_func_new
extern none_singleton
extern raise_exception
extern raise_exception_obj
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_RuntimeError_type
extern exc_TimeoutError_type
extern exc_CancelledError_type
extern task_type
extern type_type
extern task_new
extern eventloop_init
extern eventloop_teardown
extern eventloop_run
extern ready_enqueue
extern list_new
extern list_append

; SleepAwaitable type methods

;; ============================================================================
;; asyncio_run(args, nargs) — asyncio.run(coro)
;; Main event loop entry point.
;; ============================================================================
AR_FRAME equ 16             ; + 2 pushes = 32
DEF_FUNC asyncio_run_func, AR_FRAME
    push rbx
    push r12

    cmp rsi, 1
    jne .ar_error

    ; Get coroutine from args[0]
    mov rax, [rdi]             ; args[0] = coro
    V_TEST_PTR rax, rdx
    ja .ar_type_error

    mov rbx, rax               ; rbx = coro

    ; Check if loop already running
    cmp dword [gs:ThreadState.eventloop + EventLoop.running], 1
    je .ar_reentrant

    ; Initialize event loop
    call eventloop_init

    ; Create root task.  task_new answers 0 for anything that cannot be sent
    ; to, with the TypeError already recorded.
    mov rdi, rbx
    call task_new
    test rax, rax
    jz .ar_not_coro
    mov r12, rax               ; r12 = root task

    ; Run the event loop
    mov rdi, r12
    call eventloop_run
    ; rax = result payload, edx = tag
    push rdx
    push rax

    ; Teardown event loop
    call eventloop_teardown

    ; DECREF root task
    mov rdi, r12
    call obj_decref

    pop rax
    pop rdx

    ; An exception that reached the root task is re-raised here, once the
    ; loop is down: the run() call is where the caller expects to see it.
    mov rcx, [gs:ThreadState.eventloop_root_exception]
    test rcx, rcx
    jnz .ar_raise_root

    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.ar_raise_root:
    mov qword [gs:ThreadState.eventloop_root_exception], 0
    mov rdi, rcx
    pop r12
    pop rbx
    leave
    extern raise_exception_obj
    jmp raise_exception_obj     ; takes the reference; does not return

.ar_not_coro:
    ; The loop was initialised above; leave it as it was found.  CPython's
    ; runner raises ValueError here where everything else raises TypeError,
    ; so the TypeError task_new recorded is replaced rather than propagated.
    call eventloop_teardown
    pop r12
    pop rbx
    RAISE exc_ValueError_type, "a coroutine was expected"

.ar_error:
    RAISE exc_TypeError_type, "asyncio.run() takes exactly 1 argument"

.ar_type_error:
    RAISE exc_ValueError_type, "a coroutine was expected"

.ar_reentrant:
    RAISE exc_RuntimeError_type, "asyncio.run() cannot be called from a running event loop"
END_FUNC asyncio_run_func

;; ============================================================================
;; asyncio_sleep(args, nargs) — asyncio.sleep(delay)
;; Returns a SleepAwaitable.
;; ============================================================================
DEF_FUNC asyncio_sleep_func, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx

    cmp rsi, 1
    jne .as_error

    ; Get delay from args[0]
    mov rax, [rdi]             ; args[0]
    V_UNPACK rax, rdx

    ; Normalize: int_unwrap flattens bool, compact heap ints and int
    ; subclasses to (value, TAG_SMALLINT); floats pass through untouched.
    push rdi
    mov rdi, rax
    call int_unwrap
    mov rax, rdi
    pop rdi

    ; Convert to nanoseconds
    ; Supports: float (seconds), int (seconds)
    cmp edx, TAG_FLOAT
    je .as_float
    cmp edx, TAG_SMALLINT
    je .as_int
    jmp .as_type_error

.as_float:
    ; payload = IEEE 754 double bits representing seconds
    movq xmm0, rax
    ; Multiply by 1e9 to get nanoseconds
    movsd xmm1, [rel async_1e9]
    mulsd xmm0, xmm1
    cvttsd2si rbx, xmm0       ; rbx = delay_ns
    jmp .as_create

.as_int:
    ; payload = seconds as integer
    mov rbx, rax
    imul rbx, 1000000000      ; rbx = delay_ns

.as_create:
    ; Allocate SleepAwaitable
    mov edi, SleepAwaitable_size
    lea rsi, [rel sleep_awaitable_type]
    call gc_alloc               ; sets ob_refcnt and ob_type
    mov [rax + SleepAwaitable.delay_ns], rbx
    mov dword [rax + SleepAwaitable.yielded], 0
    ; gc_track only once the fields are written, for the reason code_new
    ; gives: tracking can trigger a collection, and a traverse would walk
    ; whatever the allocator left behind.
    push rax
    mov rdi, rax
    call gc_track
    pop rax

    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.as_error:
    RAISE exc_TypeError_type, "asyncio.sleep() takes exactly 1 argument"

.as_type_error:
    RAISE exc_TypeError_type, "asyncio.sleep() delay must be a number"
END_FUNC asyncio_sleep_func

;; ============================================================================
;; sleep_awaitable_iter_self — tp_iter for SleepAwaitable (return self)
DEF_FUNC_BARE sleep_awaitable_iter_self
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret
END_FUNC sleep_awaitable_iter_self

;; sleep_awaitable_iternext — tp_iternext for SleepAwaitable
;; First call: yield (delay_ns, TAG_SLEEP). Second call: return NULL (done).
;; ============================================================================
DEF_FUNC_BARE sleep_awaitable_iternext
    ; rdi = SleepAwaitable*
    cmp dword [rdi + SleepAwaitable.yielded], 0
    jne .sai_done

    ; First call: yield the SLEEP sentinel Value carrying delay_ns
    mov dword [rdi + SleepAwaitable.yielded], 1
    mov rax, [rdi + SleepAwaitable.delay_ns]
    or rax, [rel v_sleep_lo]
    ret

.sai_done:
    ; Already yielded — done, return None via StopIteration
    RET_NULL
    ret
END_FUNC sleep_awaitable_iternext

;; ============================================================================
;; sleep_awaitable_dealloc
;; ============================================================================
DEF_FUNC_BARE sleep_awaitable_dealloc
    ; No references to release, but it is GC-tracked, so it comes off the
    ; collector's list before its memory goes back.
    jmp gc_dealloc             ; tail call
END_FUNC sleep_awaitable_dealloc

;; A tracked type must have a traverse, even when there is nothing to visit:
;; the collector calls it on every object it holds.
DEF_FUNC_BARE sleep_awaitable_traverse
    xor eax, eax
    ret
END_FUNC sleep_awaitable_traverse

;; ============================================================================
;; asyncio_wait_fd_func(args, nargs) -- _asynciocore.wait_fd(fd, events)
;;
;; The primitive the Python stream layer is built on: an awaitable that
;; suspends the running task until a descriptor is ready, and answers None.
;; task_step already understands the IO_WAIT sentinel -- it is what
;; src/pyo/asyncio_streams.asm yielded from four hand-written awaitables of
;; its own -- so exposing it is all the event loop owes lib/asyncio.py.
;;
;; events is the poll mask: 1 for readable, 4 for writable, which is what the
;; two backends submit and what CPython's add_reader/add_writer split into.
;; ============================================================================
AWF_ARGS  equ 24            ; the args array, across the two conversions
AWF_FRAME equ 32            ; + 1 push = 40... one word more to land right
DEF_FUNC asyncio_wait_fd_func, 40           ; + 1 push = 48, 16-aligned
    push rbx
    cmp rsi, 2
    jne .awf_error

    ; Both arguments through obj_as_index rather than V_IS_INT: that macro is
    ; true only for an int IMMEDIATE, so a descriptor on the heap -- which is
    ; every descriptor at all under INT_STRESS=1, and any descriptor past
    ; 2**50 otherwise -- was refused as "arguments must be int".  Three
    ; concurrent connections is enough to reach fd 8, which is where the
    ; stress build starts boxing.
    mov [rbp - AWF_ARGS], rdi   ; a frame slot, not a push: everything below
    mov rdi, [rdi]              ; makes calls, and a lone push would put each
    V_UNPACK rdi, rdx           ; of them eight bytes out of alignment
    extern obj_as_index
    call obj_as_index
    test rax, rax
    js .awf_value_error
    mov rbx, rax
    mov ebx, ebx                    ; zero-extend: same as and 0xffffffff

    mov rdi, [rbp - AWF_ARGS]
    mov rdi, [rdi + 8]          ; the poll mask
    V_UNPACK rdi, rdx
    call obj_as_index
    shl rax, 32
    or rbx, rax

    mov edi, IOWaitAwaitable_size
    lea rsi, [rel io_wait_awaitable_type]
    call gc_alloc               ; sets ob_refcnt and ob_type
    mov [rax + IOWaitAwaitable.fd_events], rbx
    mov dword [rax + IOWaitAwaitable.yielded], 0
    push rax
    mov rdi, rax
    call gc_track
    pop rax

    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.awf_error:
    RAISE exc_TypeError_type, "wait_fd() takes exactly 2 arguments"
.awf_type_error:
    RAISE exc_TypeError_type, "wait_fd() arguments must be int"
.awf_value_error:
    extern exc_ValueError_type
    RAISE exc_ValueError_type, "wait_fd() fd must not be negative"
END_FUNC asyncio_wait_fd_func

DEF_FUNC_BARE io_wait_awaitable_iter_self
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret
END_FUNC io_wait_awaitable_iter_self

;; First call: yield the IO_WAIT sentinel, which suspends the task on the
;; descriptor.  Second: exhausted, with None as the value -- readiness is the
;; whole answer, and what to do about it is the caller's business.
DEF_FUNC_BARE io_wait_awaitable_iternext
    cmp dword [rdi + IOWaitAwaitable.yielded], 0
    jne .iwa_done
    mov dword [rdi + IOWaitAwaitable.yielded], 1
    mov rax, [rdi + IOWaitAwaitable.fd_events]
    or rax, [rel v_iowait_lo]
    ret
.iwa_done:
    RET_NULL
    ret
END_FUNC io_wait_awaitable_iternext

DEF_FUNC_BARE io_wait_awaitable_dealloc
    jmp gc_dealloc              ; tail call; nothing to release
END_FUNC io_wait_awaitable_dealloc

DEF_FUNC_BARE io_wait_awaitable_traverse
    xor eax, eax
    ret
END_FUNC io_wait_awaitable_traverse

;; ============================================================================
;; asyncio_wait_for_func(args, nargs) — asyncio.wait_for(coro, timeout)
;; Creates inner task, wraps in WaitForAwaitable.
;; ============================================================================
WF_INNER equ 8
WF_DELAY equ 16
WF_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC asyncio_wait_for_func, WF_FRAME
    push rbx

    cmp rsi, 2
    jne .wf_error

    ; args[0] = coro, args[1] = timeout
    push rdi                   ; save args

    ; Create inner task from coro
    mov rdi, [rdi]             ; coro = args[0] payload
    call task_new
    test rax, rax
    jz .wf_failed
    mov [rbp - WF_INNER], rax  ; save inner task

    ; Enqueue inner task on ready queue
    mov rdi, rax
    call ready_enqueue

    ; Convert timeout (args[1]) to nanoseconds
    pop rdi                    ; restore args
    mov rax, [rdi + 8]       ; args[1] payload
    V_UNPACK rax, rdx       ; args[1]

    ; Normalize: int_unwrap flattens bool, compact heap ints and int
    ; subclasses to (value, TAG_SMALLINT); floats pass through untouched.
    extern int_unwrap
    push rdi
    mov rdi, rax
    call int_unwrap
    mov rax, rdi
    pop rdi

    cmp edx, TAG_FLOAT
    je .wf_float_timeout
    cmp edx, TAG_SMALLINT
    je .wf_int_timeout
    jmp .wf_type_error

.wf_float_timeout:
    movq xmm0, rax
    movsd xmm1, [rel async_1e9]
    mulsd xmm0, xmm1
    cvttsd2si rbx, xmm0       ; rbx = timeout_ns
    jmp .wf_create

.wf_int_timeout:
    mov rbx, rax
    imul rbx, 1000000000      ; rbx = timeout_ns

.wf_create:
    mov [rbp - WF_DELAY], rbx

    ; Allocate WaitForAwaitable
    mov edi, WaitForAwaitable_size
    lea rsi, [rel wait_for_awaitable_type]
    call gc_alloc               ; sets ob_refcnt and ob_type
    mov rcx, [rbp - WF_INNER]
    mov [rax + WaitForAwaitable.inner_task], rcx  ; transfer ownership (task_new ref)
    mov rcx, [rbp - WF_DELAY]
    mov [rax + WaitForAwaitable.timeout_ns], rcx
    mov dword [rax + WaitForAwaitable.state], 0
    mov qword [rax + WaitForAwaitable.unused], 0
    mov qword [rax + WaitForAwaitable.gi_return_value], 0
    push rax
    mov rdi, rax
    call gc_track
    pop rax

    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.wf_failed:
    ; task_new recorded the TypeError; the saved args are still on the stack.
    add rsp, 8
    pop rbx
    xor eax, eax
    xor edx, edx
    leave
    ret

.wf_error:
    RAISE exc_TypeError_type, "asyncio.wait_for() takes exactly 2 arguments"

.wf_type_error:
    RAISE exc_TypeError_type, "asyncio.wait_for() timeout must be a number"
END_FUNC asyncio_wait_for_func

;; ============================================================================
;; wait_for_awaitable_iter_self — tp_iter for WaitForAwaitable (return self)
;; ============================================================================
DEF_FUNC_BARE wait_for_awaitable_iter_self
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret
END_FUNC wait_for_awaitable_iter_self

;; ============================================================================
;; wait_for_awaitable_iternext — tp_iternext for WaitForAwaitable
;; State 0: first call — yield self; task_step intercepts it by ob_type.
;; State 1: resumed — check inner task, return result or raise TimeoutError.
;; State 2+: exhausted.
;; ============================================================================
DEF_FUNC_BARE wait_for_awaitable_iternext
    ; rdi = WaitForAwaitable*
    mov eax, [rdi + WaitForAwaitable.state]

    test eax, eax
    je .wfai_first

    cmp eax, 1
    je .wfai_check

    ; State 2+: exhausted
    RET_NULL
    ret

.wfai_first:
    ; State 0 → 1: yield self for task_step (identified by ob_type)
    mov dword [rdi + WaitForAwaitable.state], 1
    INCREF rdi
    mov rax, rdi
    ret

.wfai_check:
    ; State 1 → 2: check inner task
    mov dword [rdi + WaitForAwaitable.state], 2
    push rbx
    mov rbx, rdi              ; rbx = WaitForAwaitable

    ; Check if inner task completed
    mov rax, [rbx + WaitForAwaitable.inner_task]
    cmp dword [rax + AsyncTask.done], 1
    jne .wfai_timeout

    ; Inner task done — check for exception
    mov rax, [rbx + WaitForAwaitable.inner_task]
    cmp qword [rax + AsyncTask.exception], 0
    jne .wfai_inner_exc

    ; Copy result to gi_return_value for SEND exhaustion protocol
    mov rax, [rbx + WaitForAwaitable.inner_task]
    mov rcx, [rax + AsyncTask.result]
    mov [rbx + WaitForAwaitable.gi_return_value], rcx
    INCREF_V rcx, rdx

    RET_NULL
    pop rbx
    ret

.wfai_inner_exc:
    ; Inner task had exception — re-raise it
    mov rax, [rbx + WaitForAwaitable.inner_task]
    mov rdi, [rax + AsyncTask.exception]
    INCREF rdi
    call raise_exception_obj
    RET_NULL
    pop rbx
    ret

.wfai_timeout:
    ; Inner task not done — cancel it and raise TimeoutError
    mov rax, [rbx + WaitForAwaitable.inner_task]
    mov dword [rax + AsyncTask.cancelling], 1

    RAISE exc_TimeoutError_type, "asyncio.wait_for() timed out"
    RET_NULL
    pop rbx
    ret
END_FUNC wait_for_awaitable_iternext

;; ============================================================================
;; wait_for_awaitable_dealloc — tp_dealloc for WaitForAwaitable
;; ============================================================================
DEF_FUNC_BARE wait_for_awaitable_dealloc
    push rdi                   ; save self
    ; DECREF inner_task
    mov rdi, [rdi + WaitForAwaitable.inner_task]
    test rdi, rdi
    jz .wfad_no_inner
    call obj_decref
.wfad_no_inner:
    pop rdi
    push rdi
    ; XDECREF_VAL gi_return_value
    mov rax, [rdi + WaitForAwaitable.gi_return_value]
    V_UNPACK rax, rdx
    XDECREF_VAL rax, rdx
    pop rdi
    jmp gc_dealloc             ; tail call
END_FUNC wait_for_awaitable_dealloc

;; wait_for_awaitable_traverse / _clear -- the inner task and the result.  A
;; coroutine's frame can hold the wait_for that is holding its task, which is
;; the cycle this makes visible.
DEF_FUNC wait_for_awaitable_traverse
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + WaitForAwaitable.inner_task]
    VISIT_PTR rdi
    mov rdi, [rbx + WaitForAwaitable.gi_return_value]
    VISIT_V rdi, rsi
    pop r12
    pop rbx
    leave
    ret
END_FUNC wait_for_awaitable_traverse

DEF_FUNC wait_for_awaitable_clear, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + WaitForAwaitable.inner_task]
    mov qword [rbx + WaitForAwaitable.inner_task], 0
    test rdi, rdi
    jz .wfac_value
    call obj_decref
.wfac_value:
    mov rdi, [rbx + WaitForAwaitable.gi_return_value]
    mov qword [rbx + WaitForAwaitable.gi_return_value], 0
    XDECREF_V rdi, rcx
    pop rbx
    leave
    ret
END_FUNC wait_for_awaitable_clear

;; ============================================================================
;; asyncio_create_task(args, nargs) — asyncio.create_task(coro)
;; ============================================================================
ACT_TASK equ 8
ACT_FRAME equ 16            ; + 0 pushes = 16
DEF_FUNC asyncio_create_task_func, ACT_FRAME
    cmp rsi, 1
    jne .act_error

    ; A coroutine, and only a coroutine: CPython's create_task refuses
    ; anything else with this wording, and task_new is broader than that
    ; because gather needs it to be.
    mov rdi, [rdi]             ; coro = args[0]
    push rdi
    extern task_is_generator
    call task_is_generator
    pop rdi
    test eax, eax
    jz .act_not_coro
    call task_new
    test rax, rax
    jz .act_failed
    mov [rbp - ACT_TASK], rax  ; save task (stack-aligned)

    ; Enqueue the new task
    mov rdi, rax
    call ready_enqueue

    mov rax, [rbp - ACT_TASK]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.act_failed:
    xor eax, eax
    xor edx, edx
    leave
    ret

.act_not_coro:
    mov rsi, rdi                ; the value, before CSTRING takes rdi
    CSTRING rdi, `a coroutine was expected, got \x01`
    extern raise_type_error_with_name
    call raise_type_error_with_name
    ud2

.act_error:
    RAISE exc_TypeError_type, "asyncio.create_task() takes exactly 1 argument"
END_FUNC asyncio_create_task_func

;; ============================================================================
;; asyncio_gather(args, nargs) — asyncio.gather(*coros)
;; Creates tasks for all args, returns a GatherAwaitable.
;; For simplicity: create tasks, return a list of results when all done.
;; Implementation: returns a coroutine that awaits all tasks.
;;
;; Since we can't easily create a gather coroutine in asm, we create all tasks
;; and return a special GatherAwaitable that the event loop recognizes.
;; For now: simply create tasks and return a list placeholder.
;; ============================================================================
AGF_LIST  equ 8
AGF_ARGS  equ 16
AGF_NARGS equ 24
AGF_RETEX equ 32
AGF_IDX   equ 40
AGF_FRAME equ 56            ; + 1 push = 64, 16-aligned
DEF_FUNC asyncio_gather_func, AGF_FRAME
    push rbx
    mov [rbp - AGF_ARGS], rdi
    mov [rbp - AGF_NARGS], rsi
    mov qword [rbp - AGF_RETEX], 0

    ; return_exceptions is the one keyword gather takes.
    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jz .ag_no_kw
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov rcx, [rax + PyTupleObject.ob_size]
    sub [rbp - AGF_NARGS], rcx
    xor edx, edx
.ag_kw_loop:
    cmp rdx, [rax + PyTupleObject.ob_size]
    jge .ag_no_kw
    mov rcx, [rax + PyTupleObject.ob_item]
    mov r8, [rcx + rdx*8]
    mov rcx, [rbp - AGF_NARGS]
    add rcx, rdx
    mov r9, [rbp - AGF_ARGS]
    mov r9, [r9 + rcx*8]
    push rax
    push rdx
    push r9
    sub rsp, 8
    lea rdi, [r8 + PyStrObject.data]
    CSTRING rsi, "return_exceptions"
    call ap_strcmp
    mov r10d, eax               ; the verdict, before the pops overwrite rax
    add rsp, 8
    pop r9
    pop rdx
    pop rax
    test r10d, r10d
    jnz .ag_bad_kw
    mov rdi, r9
    push rax
    push rdx
    call obj_is_true
    pop rdx
    pop rcx
    mov [rbp - AGF_RETEX], rax
    mov rax, rcx
    inc rdx
    jmp .ag_kw_loop
.ag_no_kw:

    ; One task per argument, all enqueued, so they run concurrently.  The
    ; array is plain memory: see the struct comment on why it is not a list.
    mov rdi, [rbp - AGF_NARGS]
    shl rdi, 3
    add rdi, 8                  ; ap_malloc(0) is not worth reasoning about
    call ap_malloc
    test rax, rax
    jz .ag_nomem
    mov rbx, rax
    mov [rbp - AGF_LIST], rax
    mov qword [rbp - AGF_IDX], 0
.ag_loop:
    mov rcx, [rbp - AGF_IDX]
    cmp rcx, [rbp - AGF_NARGS]
    jge .ag_done
    mov rax, [rbp - AGF_ARGS]
    mov rdi, [rax + rcx*8]
    V_TEST_PTR rdi, rdx
    ja .ag_type_error
    test rdi, rdi
    jz .ag_type_error

    ; A task or future passed straight in is used as it stands; anything
    ; else is wrapped, which is what CPython's ensure_future does.
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel task_type]
    cmp rax, rcx
    je .ag_have_task
    call task_new
    jmp .ag_enqueue
.ag_have_task:
    INCREF rdi
    mov rax, rdi
.ag_enqueue:
    test rax, rax
    jz .ag_failed
    mov rcx, [rbp - AGF_IDX]
    mov [rbx + rcx*8], rax      ; the array takes over the reference
    push rax
    sub rsp, 8
    mov rdi, rax
    call ready_enqueue
    add rsp, 8
    pop rax
    inc qword [rbp - AGF_IDX]
    jmp .ag_loop

.ag_done:
    mov edi, GatherAwaitable_size
    lea rsi, [rel gather_awaitable_type]
    call gc_alloc               ; sets ob_refcnt and ob_type
    test rax, rax
    jz .ag_failed
    mov [rax + GatherAwaitable.ga_tasks], rbx   ; takes over the array
    mov rcx, [rbp - AGF_NARGS]
    mov [rax + GatherAwaitable.ga_count], rcx
    mov qword [rax + GatherAwaitable.ga_index], 0
    mov rcx, [rbp - AGF_RETEX]
    mov [rax + GatherAwaitable.ga_flags], rcx
    mov qword [rax + GatherAwaitable.ga_state], 0
    mov qword [rax + GatherAwaitable.gi_return_value], 0
    push rax
    mov rdi, rax
    call gc_track
    pop rax
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.ag_failed:
    call .ag_release
    xor eax, eax
    pop rbx
    leave
    ret
.ag_nomem:
    xor eax, eax
    pop rbx
    leave
    ret
.ag_release:
    ; Whatever tasks were built before the failure.
    xor ecx, ecx
.ag_rel_loop:
    cmp rcx, [rbp - AGF_IDX]
    jge .ag_rel_done
    push rcx
    mov rdi, [rbx + rcx*8]
    call obj_decref
    pop rcx
    inc rcx
    jmp .ag_rel_loop
.ag_rel_done:
    mov rdi, rbx
    jmp ap_free
.ag_type_error:
    call .ag_release
    pop rbx
    RAISE exc_TypeError_type, "An asyncio.Future, a coroutine or an awaitable is required"
.ag_bad_kw:
    lea rdi, [r8 + PyStrObject.data]
    call ag_raise_bad_keyword
END_FUNC asyncio_gather_func

;; ag_raise_bad_keyword(rdi = the keyword's name, as a C string) -- no return
AGK_NAME  equ 8
AGK_BUF   equ 176
AGK_FRAME equ 176           ; + 0 pushes = 176, 16-aligned
DEF_FUNC_LOCAL ag_raise_bad_keyword, AGK_FRAME
    mov [rbp - AGK_NAME], rdi
    lea rdi, [rbp - AGK_BUF]
    CSTRING rsi, "gather() got an unexpected keyword argument '"
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - AGK_NAME]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "'"
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - AGK_BUF]
    call raise_exception
END_FUNC ag_raise_bad_keyword

;; ============================================================================
;; The gather awaitable.
;;
;; It waits on one task at a time, yielding each unfinished one; task_step
;; already knows how to suspend on a yielded task, so this needs no new case
;; in the event loop.  Every task is enqueued before the first yield, so they
;; run concurrently regardless of the order this observes them in.
;; ============================================================================
DEF_FUNC_BARE gather_awaitable_iter_self
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret
END_FUNC gather_awaitable_iter_self

GAI_SELF  equ 8
GAI_LIST  equ 16
GAI_N     equ 24
GAI_I     equ 32
GAI_FRAME equ 48            ; + 0 pushes = 48
DEF_FUNC gather_awaitable_iternext, GAI_FRAME
    mov [rbp - GAI_SELF], rdi
    cmp qword [rdi + GatherAwaitable.ga_state], 0
    jne .gai_exhausted

    mov rax, [rdi + GatherAwaitable.ga_tasks]
    mov [rbp - GAI_LIST], rax
    mov rcx, [rdi + GatherAwaitable.ga_count]
    mov [rbp - GAI_N], rcx

.gai_scan:
    mov rdi, [rbp - GAI_SELF]
    mov rcx, [rdi + GatherAwaitable.ga_index]
    cmp rcx, [rbp - GAI_N]
    jge .gai_collect
    mov rax, [rbp - GAI_LIST]
    mov rax, [rax + rcx*8]      ; the task
    cmp dword [rax + AsyncTask.done], 1
    je .gai_next
    ; Yield it.  task_step decrefs what it was handed, so this owes it a
    ; reference -- the same contract task_iternext keeps when it yields
    ; itself.
    INCREF rax
    leave
    ret
.gai_next:
    inc qword [rdi + GatherAwaitable.ga_index]
    jmp .gai_scan

.gai_collect:
    ; Every task has finished.  Build the results, in the order the arguments
    ; were given -- which is what gather promises, not completion order.
    mov qword [rdi + GatherAwaitable.ga_state], 1
    ; list_new takes a CAPACITY.  Calling it with rdi still holding self made
    ; that capacity a pointer -- about 700 million -- and the zeroing loop
    ; inside it ran for ever.  Which pointer, and so how long, depended on
    ; ASLR, which is what made this look like an intermittent hang.
    mov rdi, [rbp - GAI_N]
    call list_new
    test rax, rax
    jz .gai_failed
    push rax
    sub rsp, 8
    mov qword [rbp - GAI_I], 0
.gai_gather:
    mov rcx, [rbp - GAI_I]
    cmp rcx, [rbp - GAI_N]
    jge .gai_gathered
    mov rax, [rbp - GAI_LIST]
    mov rax, [rax + rcx*8]
    mov rdx, [rax + AsyncTask.exception]
    test rdx, rdx
    jnz .gai_had_exception
    mov rsi, [rax + AsyncTask.result]
.gai_append:
    mov rdi, [rsp + 8]
    call list_append
    inc qword [rbp - GAI_I]
    jmp .gai_gather

.gai_had_exception:
    ; return_exceptions puts the exception in the list; without it the first
    ; one propagates, which is what CPython's default does.
    mov rcx, [rbp - GAI_SELF]
    cmp qword [rcx + GatherAwaitable.ga_flags], 0
    je .gai_propagate
    mov rsi, rdx
    jmp .gai_append

.gai_propagate:
    ; Set it and RETURN, rather than unwinding from here.  Both callers know
    ; what a NULL with an exception pending means -- op_send propagates it
    ; into the awaiting coroutine's frame, task_step records it on the task
    ; -- and raise_exception_obj knows neither: it tail-jumps into the
    ; unwinder, which resumes whatever eval frame is current.  From op_send
    ; that is the right one; from task_step it is asyncio.run's caller, so a
    ; nested gather's exception blew straight past the `except` that was
    ; awaiting it.
    add rsp, 8
    pop rdi
    call obj_decref             ; the partial results list
    mov rcx, [rbp - GAI_I]
    mov rax, [rbp - GAI_LIST]
    mov rax, [rax + rcx*8]
    mov rdi, [rax + AsyncTask.exception]
    INCREF rdi
    extern exc_install
    call exc_install
    xor eax, eax
    leave
    ret

.gai_gathered:
    add rsp, 8
    pop rax
    mov rdi, [rbp - GAI_SELF]
    mov [rdi + GatherAwaitable.gi_return_value], rax
    xor eax, eax                ; NULL, with the value in gi_return_value
    leave
    ret

.gai_exhausted:
    xor eax, eax
    leave
    ret
.gai_failed:
    xor eax, eax
    leave
    ret
END_FUNC gather_awaitable_iternext

GAD_I     equ 8
GAD_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC gather_awaitable_dealloc, GAD_FRAME
    push rbx
    mov rbx, rdi
    mov rax, [rbx + GatherAwaitable.ga_tasks]
    test rax, rax
    jz .gad_value
    mov qword [rbp - GAD_I], 0
.gad_loop:
    mov rcx, [rbp - GAD_I]
    cmp rcx, [rbx + GatherAwaitable.ga_count]
    jge .gad_free_array
    mov rax, [rbx + GatherAwaitable.ga_tasks]
    mov rdi, [rax + rcx*8]
    call obj_decref
    inc qword [rbp - GAD_I]
    jmp .gad_loop
.gad_free_array:
    mov rdi, [rbx + GatherAwaitable.ga_tasks]
    mov qword [rbx + GatherAwaitable.ga_tasks], 0
    call ap_free
.gad_value:
    mov rdi, [rbx + GatherAwaitable.gi_return_value]
    mov qword [rbx + GatherAwaitable.gi_return_value], 0
    XDECREF_V rdi, rcx
    mov rdi, rbx
    call gc_dealloc
    pop rbx
    leave
    ret
END_FUNC gather_awaitable_dealloc

;; gather_awaitable_traverse / _clear.  ga_tasks is a raw AsyncTask*[] rather
;; than a list, and stays one -- but every entry is a counted reference, so
;; the collector has to be shown them or the tasks look reachable from
;; nowhere and a cycle through the gather never collects.
GAT_I     equ 8
GAT_FRAME equ 32            ; 8 used + 24 pad = 32, 16-aligned
DEF_FUNC gather_awaitable_traverse, GAT_FRAME
    push rbx
    push r12
    push r13
    push r14                    ; four pushes keep rsp 16-aligned at the call
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rbx + GatherAwaitable.ga_tasks]
    test r13, r13
    jz .gat_value
    mov qword [rbp - GAT_I], 0
.gat_loop:
    mov rcx, [rbp - GAT_I]
    cmp rcx, [rbx + GatherAwaitable.ga_count]
    jge .gat_value
    mov rdi, [r13 + rcx*8]
    VISIT_PTR rdi
    inc qword [rbp - GAT_I]
    jmp .gat_loop
.gat_value:
    mov rdi, [rbx + GatherAwaitable.gi_return_value]
    VISIT_V rdi, rsi
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC gather_awaitable_traverse

GAC_I     equ 8
GAC_FRAME equ 32            ; 8 used + 24 pad = 32, 16-aligned
DEF_FUNC gather_awaitable_clear, GAC_FRAME
    push rbx
    push r12
    mov rbx, rdi
    mov r12, [rbx + GatherAwaitable.ga_tasks]
    test r12, r12
    jz .gac_value
    mov qword [rbp - GAC_I], 0
.gac_loop:
    mov rcx, [rbp - GAC_I]
    cmp rcx, [rbx + GatherAwaitable.ga_count]
    jge .gac_free
    mov rdi, [r12 + rcx*8]
    mov qword [r12 + rcx*8], 0
    test rdi, rdi
    jz .gac_next
    call obj_decref
.gac_next:
    inc qword [rbp - GAC_I]
    jmp .gac_loop
.gac_free:
    mov rdi, [rbx + GatherAwaitable.ga_tasks]
    mov qword [rbx + GatherAwaitable.ga_tasks], 0
    mov qword [rbx + GatherAwaitable.ga_count], 0
    call ap_free
.gac_value:
    mov rdi, [rbx + GatherAwaitable.gi_return_value]
    mov qword [rbx + GatherAwaitable.gi_return_value], 0
    XDECREF_V rdi, rcx
    pop r12
    pop rbx
    leave
    ret
END_FUNC gather_awaitable_clear

;; ============================================================================
;; asyncio_get_running_loop(args, nargs)
;; ============================================================================
DEF_FUNC asyncio_get_running_loop_func
    cmp dword [gs:ThreadState.eventloop + EventLoop.running], 1
    jne .grl_error

    ; Return None as a placeholder for the loop object
    lea rax, [rel none_singleton]
    mov rdi, rax
    push rax
    call obj_incref
    pop rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.grl_error:
    RAISE exc_RuntimeError_type, "no running event loop"
END_FUNC asyncio_get_running_loop_func

;; ============================================================================
;; asyncio_module_create() -> PyObject*
;; Creates and returns the asyncio module.
;; ============================================================================
DEF_FUNC asyncio_module_create
    push rbx
    push r12

    ; Create module dict
    call dict_new
    mov r12, rax

    ; Helper macro equivalent: add function to dict
    ; Pattern: builtin_func_new -> str_from_cstr_heap -> dict_set -> decref key+func

    ; asyncio.run
    lea rdi, [rel asyncio_run_func]
    lea rsi, [rel am_run]
    call builtin_func_new
    push rax
    lea rdi, [rel am_run]
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

    ; asyncio.sleep
    lea rdi, [rel asyncio_sleep_func]
    lea rsi, [rel am_sleep]
    call builtin_func_new
    push rax
    lea rdi, [rel am_sleep]
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

    ; asyncio.create_task
    lea rdi, [rel asyncio_create_task_func]
    lea rsi, [rel am_create_task]
    call builtin_func_new
    push rax
    lea rdi, [rel am_create_task]
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

    ; asyncio.gather
    lea rdi, [rel asyncio_gather_func]
    lea rsi, [rel am_gather]
    call builtin_func_new
    push rax
    lea rdi, [rel am_gather]
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

    ; asyncio.wait_for
    lea rdi, [rel asyncio_wait_for_func]
    lea rsi, [rel am_wait_for]
    call builtin_func_new
    push rax
    lea rdi, [rel am_wait_for]
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

    ; asyncio.get_running_loop
    lea rdi, [rel asyncio_get_running_loop_func]
    lea rsi, [rel am_get_running_loop]
    call builtin_func_new
    push rax
    lea rdi, [rel am_get_running_loop]
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

    ; _asynciocore.wait_fd -- the one primitive lib/asyncio.py's stream layer
    ; needs from the loop: suspend this task until a descriptor is ready.
    lea rdi, [rel asyncio_wait_fd_func]
    lea rsi, [rel am_wait_fd]
    call builtin_func_new
    push rax
    lea rdi, [rel am_wait_fd]
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

    ; asyncio.CancelledError and asyncio.TimeoutError.  They are what a caller
    ; writes in an `except`, so a module that raises them and does not export
    ; them cannot be used: `except asyncio.TimeoutError` was an AttributeError
    ; on the line that was meant to catch the timeout.  In 3.12 both are the
    ; builtins, aliased here exactly as CPython's asyncio aliases them.
    lea rdi, [rel am_cancelled_error]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rel exc_CancelledError_type]
    call dict_set
    pop rdi
    call obj_decref

    lea rdi, [rel am_timeout_error]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rel exc_TimeoutError_type]
    call dict_set
    pop rdi
    call obj_decref

    ; asyncio.Task (type), so isinstance(t, asyncio.Task) can be asked
    lea rdi, [rel am_task]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rel task_type]
    call dict_set
    pop rdi
    call obj_decref

    ; Create module object
    lea rdi, [rel am_asyncio]
    call str_from_cstr_heap
    push rax                ; save name for DECREF
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov rbx, rax            ; save module
    pop rdi                 ; DECREF name (module_new INCREF'd)
    call obj_decref
    mov rdi, r12            ; DECREF dict (module_new INCREF'd)
    call obj_decref
    mov rax, rbx            ; return module

    pop r12
    pop rbx
    leave
    ret
END_FUNC asyncio_module_create

;; ============================================================================
;; Data section
;; ============================================================================
section .rodata
align 8
async_1e9: dq 0x41cdcd6500000000   ; 1e9 as IEEE 754 double

am_asyncio:          db "_asynciocore", 0
am_run:              db "run", 0
am_sleep:            db "sleep", 0
am_create_task:      db "create_task", 0
am_gather:           db "gather", 0
am_get_running_loop: db "get_running_loop", 0
am_wait_for:         db "wait_for", 0
am_wait_fd:          db "wait_fd", 0
am_cancelled_error:  db "CancelledError", 0
am_timeout_error:    db "TimeoutError", 0
am_task:             db "Task", 0

io_wait_awaitable_name: db "IOWaitAwaitable", 0
sleep_awaitable_name: db "SleepAwaitable", 0
gather_awaitable_name: db "_GatherAwaitable", 0
wait_for_awaitable_name: db "WaitForAwaitable", 0

section .data

align 8
io_wait_awaitable_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq io_wait_awaitable_name   ; tp_name
    dq IOWaitAwaitable_size     ; tp_basicsize
    dq io_wait_awaitable_dealloc ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq io_wait_awaitable_iter_self ; tp_iter
    dq io_wait_awaitable_iternext  ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC | TYPE_FLAG_AWAITABLE        ; tp_flags
    dq 0                        ; tp_bases
    dq io_wait_awaitable_traverse ; tp_traverse
    dq 0                        ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

align 8
sleep_awaitable_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq sleep_awaitable_name     ; tp_name
    dq SleepAwaitable_size      ; tp_basicsize
    dq sleep_awaitable_dealloc  ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq sleep_awaitable_iter_self ; tp_iter (return self — __await__ protocol)
    dq sleep_awaitable_iternext ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC | TYPE_FLAG_AWAITABLE                        ; tp_flags
    dq 0                        ; tp_bases
    dq sleep_awaitable_traverse                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

align 8
global wait_for_awaitable_type
gather_awaitable_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq gather_awaitable_name    ; tp_name
    dq GatherAwaitable_size     ; tp_basicsize
    dq gather_awaitable_dealloc ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq gather_awaitable_iter_self ; tp_iter
    dq gather_awaitable_iternext  ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC | TYPE_FLAG_AWAITABLE                        ; tp_flags
    dq 0                        ; tp_bases
    dq gather_awaitable_traverse                        ; tp_traverse
    dq gather_awaitable_clear                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

align 8
global gather_awaitable_type
wait_for_awaitable_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq wait_for_awaitable_name  ; tp_name
    dq WaitForAwaitable_size    ; tp_basicsize
    dq wait_for_awaitable_dealloc ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq wait_for_awaitable_iter_self ; tp_iter
    dq wait_for_awaitable_iternext ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC | TYPE_FLAG_AWAITABLE                        ; tp_flags
    dq 0                        ; tp_bases
    dq wait_for_awaitable_traverse                        ; tp_traverse
    dq wait_for_awaitable_clear                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
