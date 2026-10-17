; eventloop.asm - Async event loop core
;
; Provides:
;   - EventLoop singleton with ready queue
;   - task_new(coro) -> AsyncTask*
;   - task_step(task) -> resume coro, dispatch result
;   - task_wake_waiters(task) -> wake tasks waiting on completion
;   - ready_enqueue(task) / ready_dequeue() -> task
;   - eventloop_run(root_task) -> fat value (main loop)
;   - eventloop_init() / eventloop_teardown()
;   - task_type — Python type for AsyncTask
;
; Uses IOBackend vtable for I/O abstraction (poll or io_uring).

%include "macros.inc"
%include "object.inc"
%include "eventloop.inc"

%if EventLoop_size != TS_EVENTLOOP_SIZE
%error "ThreadState.eventloop is not EventLoop_size bytes: fix TS_EVENTLOOP_SIZE in threadstate.inc"
%endif

extern bool_true
extern bool_false
extern coro_type
extern gen_type
extern exc_TypeError_type
extern set_exception
extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern ap_free
extern obj_incref
extern obj_decref
extern obj_dealloc
extern gen_send
extern gen_throw
extern none_singleton
extern str_from_cstr
extern type_type
extern ap_strcmp
extern raise_exception
extern raise_exception_obj
extern exc_new
extern exc_RuntimeError_type
extern exc_CancelledError_type
extern eval_exception_unwind
extern builtin_func_new
extern getenv

; Poll backend (always available)
extern poll_backend

; io_uring backend (may fail at runtime)
extern uring_backend

;; ============================================================================
;; eventloop_init() -> 0 ok, -1 fail
;; Initialize the event loop. Try io_uring first, fall back to poll.
;; ============================================================================
DEF_FUNC eventloop_init
    ; Check APYTHON_IO_BACKEND env var
    CSTRING rdi, "APYTHON_IO_BACKEND"
    call getenv
    test rax, rax
    jz .try_uring              ; not set → default (try uring, fall back to poll)
    cmp byte [rax], 'p'        ; "poll"
    je .try_poll
    ; else: try iouring (default)

.try_uring:
    ; Set uring backend, then call init via vtable
    lea rax, [rel uring_backend]
    mov [gs:ThreadState.eventloop + EventLoop.backend], rax
    call [rax + IOBackend.init]
    test eax, eax
    js .try_poll

    ; io_uring available
    jmp .init_done

.try_poll:
    ; Use poll backend
    lea rax, [rel poll_backend]
    mov [gs:ThreadState.eventloop + EventLoop.backend], rax

    ; Call poll init via vtable
    call [rax + IOBackend.init]

.init_done:
    ; Initialize ready queue
    ; eventloop_teardown drains the queue and clears root_task, so these are
    ; a first-run initialisation rather than a way of forgetting a previous
    ; run's contents -- which is what they used to be.
    mov qword [gs:ThreadState.eventloop + EventLoop.ready_head], 0
    mov qword [gs:ThreadState.eventloop + EventLoop.ready_tail], 0
    mov dword [gs:ThreadState.eventloop + EventLoop.running], 1
    mov qword [gs:ThreadState.eventloop + EventLoop.root_task], 0

    xor eax, eax               ; return 0 = success
    leave
    ret
END_FUNC eventloop_init

;; ============================================================================
;; eventloop_teardown()
;; Shut down the event loop and backend.
;; ============================================================================
DEF_FUNC eventloop_teardown
    ; Drain the ready queue first.  It owns a reference per task, and
    ; eventloop_init used to start the next run by zeroing the head and tail
    ; over whatever was still linked there -- every one of those tasks leaked,
    ; and with them their coroutine, its frame and everything the frame held.
.tdn_drain:
    call ready_dequeue
    test rax, rax
    jz .tdn_drained
    mov rdi, rax
    call obj_decref
    jmp .tdn_drain
.tdn_drained:

    mov rax, [gs:ThreadState.eventloop + EventLoop.backend]
    test rax, rax
    jz .td_done
    mov rax, [rax + IOBackend.teardown]
    call rax
.td_done:
    mov dword [gs:ThreadState.eventloop + EventLoop.running], 0
    leave
    ret
END_FUNC eventloop_teardown

;; ============================================================================
;; task_new(PyGenObject *coro) -> AsyncTask*
;; Allocate and initialize a new async task.
;; ============================================================================

extern async_gen_type

;; ============================================================================
;; task_is_generator(rdi = the object a task holds) -> eax = 1 when gen_send
;; can drive it, 0 when it has to go through tp_iternext.
;; ============================================================================
global task_is_generator
DEF_FUNC task_is_generator
    xor eax, eax
    ; A Value, not a pointer: create_task(2.5) hands over a NaN-boxed float,
    ; and reading ob_type off one dereferences the number.
    V_TEST_PTR rdi, rcx
    ja .tig_no
    test rdi, rdi
    jz .tig_no
    mov rcx, [rdi + PyObject.ob_type]
    lea rdx, [rel coro_type]
    cmp rcx, rdx
    je .tig_yes
    lea rdx, [rel gen_type]
    cmp rcx, rdx
    je .tig_yes
    lea rdx, [rel async_gen_type]
    cmp rcx, rdx
    jne .tig_no
.tig_yes:
    mov eax, 1
.tig_no:
    leave
    ret
END_FUNC task_is_generator

DEF_FUNC task_new, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx

    ; What a task can step.  A coroutine, a generator or an async generator is
    ; driven with gen_send, which reads PyGenObject fields off it -- so those
    ; three have to BE one, and nothing checked: `gather("hello")` wrapped
    ; whatever it was given and crashed on the first step, several stack
    ; frames from where the mistake was made.
    ;
    ; Anything else with a tp_iternext is driven through that instead, which
    ; is how a nested gather works: gather() hands back a GatherAwaitable,
    ; which is not a generator and cannot be sent to, and wrapping one meant
    ; wrapping an arbitrary awaitable in a coroutine -- which is what
    ; CPython's ensure_future does and what there is no way to do from here.
    ; Stepping it directly needs no coroutine: op_send already drives that
    ; object through tp_iternext when a coroutine awaits one, and its
    ; gi_return_value sits at the offset PyGenObject keeps it at, which is
    ; the whole reason that field is where it is.
    V_TEST_PTR rdi, rax
    ja .tn_not_awaitable
    test rdi, rdi
    jz .tn_not_awaitable
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel coro_type]
    cmp rax, rcx
    je .tn_ok
    lea rcx, [rel gen_type]
    cmp rax, rcx
    je .tn_ok
    lea rcx, [rel async_gen_type]
    cmp rax, rcx
    je .tn_ok
    cmp qword [rax + PyTypeObject.tp_iternext], 0
    je .tn_not_awaitable
.tn_ok:
    mov rbx, rdi               ; save coro

    mov edi, AsyncTask_size
    lea rsi, [rel task_type]
    call gc_alloc

    mov qword [rax + AsyncTask.ob_refcnt], 1
    mov [rax + AsyncTask.coro], rbx
    ; INCREF coro
    mov rdi, rbx
    push rax
    call obj_incref
    pop rax

    mov qword [rax + AsyncTask.result], 0
    mov qword [rax + AsyncTask.exception], 0
    mov dword [rax + AsyncTask.queued], 0
    ; send_value starts as None, and is OWNED from here on: task_step stores
    ; into it with an INCREF, and task_dealloc releases it.  Storing the
    ; singleton without taking a reference made that release one too many.
    lea rcx, [rel none_singleton]
    mov [rax + AsyncTask.send_value], rcx
    inc qword [rcx + PyObject.ob_refcnt]
    mov dword [rax + AsyncTask.done], 0
    mov dword [rax + AsyncTask.cancelling], 0
    mov dword [rax + AsyncTask.n_waiters], 0
    mov qword [rax + AsyncTask.waiters], 0
    mov dword [rax + AsyncTask.waiters_cap], 0
    mov qword [rax + AsyncTask.next], 0
    mov qword [rax + AsyncTask.ts_sec], 0
    mov qword [rax + AsyncTask.ts_nsec], 0
    mov qword [rax + AsyncTask.pad_result], 0
    mov qword [rax + AsyncTask.pad_send], 0

    ; gc_track only now, for the reason code_new gives: tracking can trigger
    ; a collection, and the traverse would walk fields not yet written.
    mov rbx, rax
    mov rdi, rax
    call gc_track
    mov rax, rbx

    pop rbx
    leave
    ret

.tn_not_awaitable:
    ; SET_EXC and 0, not RAISE: every caller checks for the NULL and releases
    ; what it is holding, and a builtin that abandons its C frame leaks it.
    SET_EXC exc_TypeError_type, \
            "An asyncio.Future, a coroutine or an awaitable is required"
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC task_new

;; ============================================================================
;; task_dealloc(AsyncTask *self)
;; ============================================================================
DEF_FUNC task_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; DECREF coro
    mov rdi, [rbx + AsyncTask.coro]
    test rdi, rdi
    jz .td_no_coro
    call obj_decref
.td_no_coro:

    ; XDECREF result
    mov rdi, [rbx + AsyncTask.result]
    V_UNPACK rdi, rsi
    XDECREF_VAL rdi, rsi

    ; XDECREF exception
    mov rdi, [rbx + AsyncTask.exception]
    test rdi, rdi
    jz .td_no_exc
    call obj_decref
.td_no_exc:

    ; Release any waiters still in the array, then free it.  A task that dies
    ; without ever completing -- cancelled, or dropped with the loop torn
    ; down under it -- still holds one reference per waiter.
    mov ecx, [rbx + AsyncTask.n_waiters]
    test ecx, ecx
    jz .td_free_waiters
    mov dword [rbx + AsyncTask.n_waiters], 0
.td_waiter_loop:
    mov rax, [rbx + AsyncTask.waiters]
    mov rdi, [rax + rcx*8 - 8]
    push rcx
    call obj_decref
    pop rcx
    dec ecx
    jnz .td_waiter_loop
.td_free_waiters:
    mov rdi, [rbx + AsyncTask.waiters]
    test rdi, rdi
    jz .td_no_waiters
    mov qword [rbx + AsyncTask.waiters], 0
    call ap_free
.td_no_waiters:

    ; send_value is a Value the task owns: task_step stores None into it with
    ; an INCREF, and nothing released it.  A plain leak, one per task.
    mov rdi, [rbx + AsyncTask.send_value]
    test rdi, rdi
    jz .td_no_send
    DECREF_V rdi, rcx
.td_no_send:

    ; Free self
    mov rdi, rbx
    call gc_dealloc

    pop rbx
    leave
    ret
END_FUNC task_dealloc

;; ============================================================================
;; task_set_send_value(rdi = task, rsi = the Value to resume it with)
;;
;; send_value is an OWNED reference -- task_dealloc releases it -- so every
;; store has to release what was there.  Both backends stored none_singleton
;; over it with neither an incref of the new nor a release of the old: None is
;; immortal, so nothing crashed, and whatever the field had been holding was
;; leaked once per timer expiry and once per fd readiness.
;;
;; The new value is increfd before the old is released, so setting a task's
;; send_value to what it already holds is safe.
;; ============================================================================
global task_set_send_value
DEF_FUNC task_set_send_value
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    INCREF_V r12, rax
    mov rdi, [rbx + AsyncTask.send_value]
    mov [rbx + AsyncTask.send_value], r12
    XDECREF_V rdi, rax
    pop r12
    pop rbx
    leave
    ret
END_FUNC task_set_send_value

;; ============================================================================
;; task_traverse / task_clear
;;
;; A task holds its coroutine, the coroutine holds a frame, and the frame's
;; locals can hold the task -- an ordinary cycle, and one nothing could
;; collect while a task was invisible to the collector.
;;
;; The waiters array is part of it: an awaited task holds every task waiting
;; on it, so a pair of coroutines awaiting each other is a cycle through two
;; waiters arrays.
;;
;; The three awaitable types stay untracked, and keep counted references to
;; the tasks they hold.  That is conservative in the safe direction: an
;; untracked holder's reference is not subtracted, so a task it holds looks
;; reachable and is never freed early.  It can leave a cycle uncollected.
;; ============================================================================
global task_traverse
DEF_FUNC task_traverse, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov rdi, [rbx + AsyncTask.coro]
    VISIT_PTR rdi
    mov rdi, [rbx + AsyncTask.result]
    VISIT_V rdi, rsi
    mov rdi, [rbx + AsyncTask.exception]
    VISIT_PTR rdi
    mov rdi, [rbx + AsyncTask.send_value]
    VISIT_V rdi, rsi
    mov r12d, [rbx + AsyncTask.n_waiters]
    test r12d, r12d
    jz .tt_done
    mov r13, [rbx + AsyncTask.waiters]
    test r13, r13
    jz .tt_done
.tt_waiter_loop:
    dec r12d
    mov rdi, [r13 + r12*8]
    VISIT_PTR rdi
    test r12d, r12d
    jnz .tt_waiter_loop
.tt_done:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC task_traverse

;; The coroutine is the field that closes the cycle; the result and the send
;; value can too, and neither is read again once the task is unreachable.
;; The waiters go with them -- a waiter list on a task nothing can reach is
;; a list nothing will ever wake.
global task_clear
DEF_FUNC task_clear
    push rbx
    push r12
    mov rbx, rdi

    mov r12d, [rbx + AsyncTask.n_waiters]
    test r12d, r12d
    jz .tc_no_waiters
    mov dword [rbx + AsyncTask.n_waiters], 0
.tc_waiter_loop:
    dec r12d
    mov rax, [rbx + AsyncTask.waiters]
    mov rdi, [rax + r12*8]
    test rdi, rdi
    jz .tc_waiter_next
    call obj_decref
.tc_waiter_next:
    test r12d, r12d
    jnz .tc_waiter_loop
.tc_no_waiters:

    mov rdi, [rbx + AsyncTask.coro]
    test rdi, rdi
    jz .tc_no_coro
    mov qword [rbx + AsyncTask.coro], 0
    call obj_decref
.tc_no_coro:

    mov rdi, [rbx + AsyncTask.result]
    mov qword [rbx + AsyncTask.result], 0
    XDECREF_V rdi, rcx

    mov rdi, [rbx + AsyncTask.send_value]
    mov qword [rbx + AsyncTask.send_value], 0
    XDECREF_V rdi, rcx

    pop r12
    pop rbx
    leave
    ret
END_FUNC task_clear

;; ============================================================================
;; ready_enqueue(AsyncTask *task)
;; O(1) append to ready queue tail.
;; ============================================================================
DEF_FUNC_BARE ready_enqueue
    ; The queue OWNS what it holds.  It used to link tasks through .next with
    ; no reference at all, which was safe only because the collector could not
    ; see tasks: make them visible and a cyclic task sitting in the queue
    ; becomes collectable, and the queue is left following a freed pointer.
    ; One reference here, released by the drain loop after task_step.
    ;
    ; And a task already in the queue is left where it is: the line below
    ; zeroes .next, so enqueuing one twice cut the list off after it.  The
    ; queue holds a task once; task_step reads send_value when it runs, so
    ; the second enqueue has nothing to deliver that the first will not.
    cmp dword [rdi + AsyncTask.queued], 0
    jne .re_already
    mov dword [rdi + AsyncTask.queued], 1
    inc qword [rdi + PyObject.ob_refcnt]
    mov qword [rdi + AsyncTask.next], 0
    mov rax, [gs:ThreadState.eventloop + EventLoop.ready_tail]
    test rax, rax
    jz .re_empty

    ; Append to tail
    mov [rax + AsyncTask.next], rdi
    mov [gs:ThreadState.eventloop + EventLoop.ready_tail], rdi
    ret

.re_empty:
    ; Queue was empty
    mov [gs:ThreadState.eventloop + EventLoop.ready_head], rdi
    mov [gs:ThreadState.eventloop + EventLoop.ready_tail], rdi
    ret
.re_already:
    ret
END_FUNC ready_enqueue

;; ============================================================================
;; ready_dequeue() -> AsyncTask* or NULL
;; O(1) pop from ready queue head.
;; ============================================================================
DEF_FUNC_BARE ready_dequeue
    mov rax, [gs:ThreadState.eventloop + EventLoop.ready_head]
    test rax, rax
    jz .rd_empty
    mov dword [rax + AsyncTask.queued], 0

    ; Advance head
    mov rcx, [rax + AsyncTask.next]
    mov [gs:ThreadState.eventloop + EventLoop.ready_head], rcx
    test rcx, rcx
    jnz .rd_done
    ; Queue now empty
    mov qword [gs:ThreadState.eventloop + EventLoop.ready_tail], 0
.rd_done:
    mov qword [rax + AsyncTask.next], 0
.rd_empty:
    ret
END_FUNC ready_dequeue

;; ============================================================================
;; task_step(AsyncTask *task)
;; Resume the task's coroutine via gen_send. Dispatch on result tag.
;; ============================================================================
TS_TASK  equ 8
TS_EXC   equ 16             ; current_exception before the step
TS_FRAME equ 32             ; + 2 pushes = 48, 16-aligned
DEF_FUNC task_step, TS_FRAME
    push rbx
    push r12

    mov rbx, rdi               ; rbx = task
    mov [rbp - TS_TASK], rdi

    ; Done-guard: double-wakeup protection
    cmp dword [rbx + AsyncTask.done], 1
    je .ts_ret

    ; The snapshot goes in BEFORE the cancel test, not after it: .ts_cancel
    ; compares against it too, and jumping there first read a slot nothing
    ; had written -- whatever the stack happened to hold, compared against a
    ; live exception.  Valgrind says so on every cancelled task.
    ;
    ; gen_send hands back a NULL tag for a return and for a raise alike, so
    ; the exception is what tells them apart -- and the answer has to be "one
    ; that was not already there".  It matters less than it did, now that
    ; current_exception means only "in flight" and the exception an except
    ; block is HANDLING lives in handled_exception: a task that finished
    ; inside a live handler no longer adopts that exception and re-raises out
    ; of asyncio.run what the coroutine had already caught.  The snapshot
    ; stays because it costs two instructions and is the honest test: it is
    ; still possible to reach here with something in flight.
    DUNDER_EXC_SAVE [rbp - TS_EXC]

    ; Check if cancelled
    cmp dword [rbx + AsyncTask.cancelling], 1
    je .ts_cancel

    ; A generator is sent to; anything else with a tp_iternext is stepped
    ; through that.  task_new is what decides which, and this is the mirror
    ; of it -- a value cannot be sent INTO a plain awaitable, and none of
    ; them wants one: a gather resumes from its own state.
    mov rdi, [rbx + AsyncTask.coro]
    call task_is_generator
    test eax, eax
    jz .ts_step_iternext
    mov rdi, [rbx + AsyncTask.coro]
    mov rsi, [rbx + AsyncTask.send_value]   ; already a Value
    call gen_send
    V_UNPACK rax, rdx          ; gen_send returns a Value
    jmp .ts_stepped
.ts_step_iternext:
    mov rdi, [rbx + AsyncTask.coro]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    call rax
    V_UNPACK rax, rdx          ; tp_iternext answers a Value too
.ts_stepped:

    ; Check for exhaustion (NULL tag = coroutine returned)
    test edx, edx
    jz .ts_finished

    ; Dispatch on the yielded value.  Sleep and io-wait carry raw data and
    ; need their own tags; a yielded task or wait_for is an ordinary object,
    ; so it is identified by its type rather than by a tag of its own.
    cmp edx, TAG_SLEEP
    je .ts_sleep
    cmp edx, TAG_IO_WAIT
    je .ts_io_wait
    cmp edx, TAG_PTR
    jne .ts_plain_value
    ; rcx/rsi are scratch here; r13 must not be touched -- it is the VM value
    ; stack pointer and task_step does not save it.
    mov rcx, [rax + PyObject.ob_type]
    lea rsi, [rel task_type]
    cmp rcx, rsi
    je .ts_await_task
    extern wait_for_awaitable_type
    lea rsi, [rel wait_for_awaitable_type]
    cmp rcx, rsi
    je .ts_wait_for
.ts_plain_value:

    ; Unknown yield value — coroutine yielded a regular value
    ; For asyncio: this means the coroutine is waiting
    ; Re-enqueue to retry (shouldn't normally happen with proper awaitables)
    mov rdi, rbx
    call ready_enqueue
    jmp .ts_ret

.ts_sleep:
    ; rax = delay_ns
    mov rdi, [gs:ThreadState.eventloop + EventLoop.backend]
    mov rdi, [rdi + IOBackend.submit_timeout]
    mov rsi, rbx               ; task
    mov rdx, rax               ; delay_ns
    ; swap args: submit_timeout(task, delay_ns)
    mov rdi, rbx
    mov rsi, rax
    mov rax, [gs:ThreadState.eventloop + EventLoop.backend]
    call [rax + IOBackend.submit_timeout]
    jmp .ts_ret

.ts_io_wait:
    ; rax = fd | (direction << 32)
    mov r12, rax
    mov edi, eax               ; fd = low 32 bits
    shr r12, 32
    mov esi, r12d              ; events (POLLIN=1, POLLOUT=4)
    mov rdx, rbx               ; task
    ; submit_poll_fd(task, fd, events)
    mov rdi, rbx
    mov esi, eax               ; fd
    mov edx, r12d              ; events
    mov rax, [gs:ThreadState.eventloop + EventLoop.backend]
    call [rax + IOBackend.submit_poll_fd]
    jmp .ts_ret

.ts_await_task:
    ; rax = AsyncTask* being awaited
    mov r12, rax               ; r12 = awaited task

    ; If the awaited task is already done, immediately wake us
    cmp dword [r12 + AsyncTask.done], 1
    je .ts_await_done

    ; Add current task as waiter on the awaited task
    mov rdi, r12               ; awaited task
    mov rsi, rbx               ; waiter (current task)
    call task_add_waiter
    jmp .ts_decref_awaited

.ts_await_done:
    ; Awaited task already done — check for exception first
    mov rax, [r12 + AsyncTask.exception]
    test rax, rax
    jnz .ts_await_done_exc

    ; No exception — set send_value to its result, re-enqueue.  The waiter's
    ; send_value is an OWNED reference: task_dealloc releases it, and the
    ; sibling path below increfs for exactly this reason.  Handing over the
    ; awaited task's own result borrowed made that release one too many.
    mov rdi, rbx
    mov rsi, [r12 + AsyncTask.result]
    call task_set_send_value
    mov rdi, rbx
    call ready_enqueue
    jmp .ts_decref_awaited

.ts_await_done_exc:
    ; Awaited task had exception — set send_value = None, re-enqueue.
    ; When waiter resumes, SEND calls task_iternext which detects the
    ; awaited task's exception and raises it via eval_exception_unwind.
    mov rdi, rbx
    lea rsi, [rel none_singleton]
    call task_set_send_value
    mov rdi, rbx
    call ready_enqueue

.ts_decref_awaited:
    ; DECREF awaited task (INCREFed by task_iternext before yielding itself)
    mov rdi, r12
    call obj_decref
    jmp .ts_ret

.ts_wait_for:
    ; rax = WaitForAwaitable*
    mov r12, rax               ; r12 = wfa

    ; Check if inner task already done
    mov rax, [r12 + WaitForAwaitable.inner_task]
    cmp dword [rax + AsyncTask.done], 1
    je .ts_wf_done

    ; Inner task still running — add outer as waiter + start timeout
    mov rdi, [r12 + WaitForAwaitable.inner_task]
    mov rsi, rbx               ; waiter = outer task
    call task_add_waiter

    ; Submit timeout for outer task
    mov rdi, rbx               ; task
    mov rsi, [r12 + WaitForAwaitable.timeout_ns]
    mov rax, [gs:ThreadState.eventloop + EventLoop.backend]
    call [rax + IOBackend.submit_timeout]

    ; DECREF wfa
    mov rdi, r12
    call obj_decref
    jmp .ts_ret

.ts_wf_done:
    ; Inner task already done — fast path: set send_value, re-enqueue
    ; Set None as send_value (wfa iternext will check inner task result)
    mov rdi, rbx
    lea rsi, [rel none_singleton]
    call task_set_send_value
    mov rdi, rbx
    call ready_enqueue
    ; DECREF wfa
    mov rdi, r12
    call obj_decref
    jmp .ts_ret

.ts_finished:
    ; A NULL tag from gen_send means the coroutine RETURNED or RAISED, and
    ; this arm used to assume the first.  Nothing ever wrote
    ; AsyncTask.exception outside the cancellation path, so `await t` on a
    ; task that raised saw a done task with no exception, took .ti_done, and
    ; evaluated to None -- try/except around the await caught nothing, and
    ; the exception surfaced at interpreter exit instead.  t.result() and
    ; asyncio.wait_for read the same never-set field.
    ;
    ; The exception IS available here: a raise inside a coroutine body does
    ; not abandon the C stack past the generator frame -- the unwinder's
    ; no-handler arm returns normally through eval_return -- and gen_send
    ; deliberately leaves it pending.  The whole re-raise path downstream
    ; (task_wake_waiters' .tw_set_cancel, task_iternext's .ti_done_exc)
    ; already exists and was simply unreachable.
    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jz .ts_finished_value
    cmp rax, [rbp - TS_EXC]
    je .ts_finished_value       ; the one that was already in flight

    ; Move it, owned: raise_exception_obj took over its caller's reference,
    ; so the global holds exactly one and the task takes it over in turn.
    mov [rbx + AsyncTask.exception], rax
    mov qword [gs:ThreadState.current_exception], 0
    mov dword [rbx + AsyncTask.done], 1
    mov rdi, rbx
    call task_wake_waiters
    jmp .ts_ret

.ts_finished_value:
    ; Coroutine returned (StopIteration) — task is done
    ; The return value is in gen.gi_return_value
    mov rdi, [rbx + AsyncTask.coro]
    mov rax, [rdi + PyGenObject.gi_return_value]
    mov [rbx + AsyncTask.result], rax
    INCREF_V rax, rdx
    mov dword [rbx + AsyncTask.done], 1

    ; Wake waiters
    mov rdi, rbx
    call task_wake_waiters
    jmp .ts_ret

.ts_cancel:
    ; A plain awaitable cannot be thrown into: gen_throw reads PyGenObject
    ; fields off whatever it is handed, and a GatherAwaitable is not one.
    ; There is nothing to unwind in it either -- it holds tasks, and each of
    ; those is cancelled in its own right -- so the CancelledError is simply
    ; recorded, which is where the throw would have arrived anyway.
    mov rdi, [rbx + AsyncTask.coro]
    call task_is_generator
    test eax, eax
    jz .ts_cancel_no_exc

    ; Throw CancelledError into coroutine
    mov rdi, [rbx + AsyncTask.coro]
    lea rsi, [rel exc_CancelledError_type]
    call gen_throw

    ; Store CancelledError exception on the task
    ; gen_throw may have left it in current_exception, or coro caught it
    test edx, edx
    jnz .ts_cancel_caught
    ; Exception propagated (NULL return) — grab from current_exception, and
    ; for the same reason as above, only if it is not the one that was
    ; already in flight when the step began.
    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jz .ts_cancel_no_exc
    cmp rax, [rbp - TS_EXC]
    je .ts_cancel_no_exc
    INCREF rax
    mov [rbx + AsyncTask.exception], rax
    ; Clear current_exception
    mov rdi, [gs:ThreadState.current_exception]
    mov qword [gs:ThreadState.current_exception], 0
    call obj_decref
    jmp .ts_cancel_done
.ts_cancel_caught:
    ; Coro caught the error and returned — no exception to propagate
    ; Store return value as result (from gi_return_value since gen exhausted)
    mov rdi, [rbx + AsyncTask.coro]
    mov rax, [rdi + PyGenObject.gi_return_value]
    mov [rbx + AsyncTask.result], rax
    INCREF_V rax, rdx
    jmp .ts_cancel_done
.ts_cancel_no_exc:
    ; No exception found — create one
    lea rdi, [rel exc_CancelledError_type]
    xor esi, esi
    xor edx, edx
    call exc_new
    mov [rbx + AsyncTask.exception], rax
.ts_cancel_done:
    ; Mark as done
    mov dword [rbx + AsyncTask.done], 1
    mov dword [rbx + AsyncTask.cancelling], 0
    ; Wake waiters (they'll see exception)
    mov rdi, rbx
    call task_wake_waiters

.ts_ret:
    pop r12
    pop rbx
    leave
    ret
END_FUNC task_step

;; ============================================================================
;; task_wake_waiters(AsyncTask *task)
;; Iterate waiters, set their send_value to task's result, enqueue them.
;; ============================================================================
DEF_FUNC task_wake_waiters, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    mov rbx, rdi               ; task

    mov r12d, [rbx + AsyncTask.n_waiters]
    test r12d, r12d
    jz .tw_done

    mov r13, [rbx + AsyncTask.waiters]
    xor ecx, ecx

.tw_loop:
    cmp ecx, r12d
    jge .tw_done

    push rcx
    mov rdi, [r13 + rcx*8]    ; waiter task
    push rdi

    ; Check if completed task has an exception
    mov rax, [rbx + AsyncTask.exception]
    test rax, rax
    jnz .tw_set_cancel

    ; Set send_value = task's result, one owned reference per waiter
    mov rsi, [rbx + AsyncTask.result]
    call task_set_send_value
    jmp .tw_enqueue

.tw_set_cancel:
    ; Task had exception — set send_value = None and enqueue waiter.
    ; When waiter is resumed, SEND calls task_iternext which will detect
    ; the awaited task's exception and raise it via eval_exception_unwind.
    lea rsi, [rel none_singleton]
    call task_set_send_value

.tw_enqueue:
    ; Enqueue the waiter, and let go of the array's own reference: the
    ; waiters array holds one per entry, and this is where they end.
    pop rdi
    push rdi
    call ready_enqueue
    pop rdi
    call obj_decref
    pop rcx
    inc ecx
    jmp .tw_loop

.tw_done:
    ; Clear waiters
    mov dword [rbx + AsyncTask.n_waiters], 0

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC task_wake_waiters

;; ============================================================================
;; task_add_waiter(AsyncTask *awaited, AsyncTask *waiter)
;; Add waiter to awaited's waiters array, growing if needed.
;; rdi = awaited task, rsi = waiter task
;; ============================================================================
DEF_FUNC task_add_waiter
    push rbx
    push r12

    mov rbx, rdi               ; rbx = awaited task
    mov r12, rsi               ; r12 = waiter task

    ; Check if waiters array needs growing
    mov eax, [rbx + AsyncTask.n_waiters]
    cmp eax, [rbx + AsyncTask.waiters_cap]
    jb .taw_add

    ; Grow: new_cap = old_cap ? old_cap*2 : 4
    mov ecx, [rbx + AsyncTask.waiters_cap]
    test ecx, ecx
    jz .taw_init_cap
    shl ecx, 1
    jmp .taw_grow
.taw_init_cap:
    mov ecx, 4
.taw_grow:
    mov [rbx + AsyncTask.waiters_cap], ecx
    ; Allocate new array
    lea edi, [ecx * 8]
    push rcx
    call ap_malloc
    pop rcx
    ; Copy old entries
    mov rsi, [rbx + AsyncTask.waiters]
    test rsi, rsi
    jz .taw_no_copy
    mov rdi, rax
    mov edx, [rbx + AsyncTask.n_waiters]
    shl edx, 3
    push rax
    xor ecx, ecx
.taw_copy_loop:
    cmp ecx, edx
    jge .taw_copy_done
    mov r8, [rsi + rcx]
    mov [rdi + rcx], r8
    add ecx, 8
    jmp .taw_copy_loop
.taw_copy_done:
    ; Free old array
    mov rdi, rsi
    call ap_free
    pop rax
.taw_no_copy:
    mov [rbx + AsyncTask.waiters], rax

.taw_add:
    ; The array OWNS what it holds.  It used to be raw pointers, which was
    ; safe only while a task could not be collected: an awaited task keeps a
    ; waiter alive for as long as it takes to finish, and nothing else has to
    ; be holding that waiter.  task_wake_waiters releases them, and
    ; task_dealloc releases whatever is left.
    mov rdi, r12
    call obj_incref
    mov eax, [rbx + AsyncTask.n_waiters]
    mov rcx, [rbx + AsyncTask.waiters]
    mov [rcx + rax*8], r12     ; waiters[n_waiters] = waiter
    inc dword [rbx + AsyncTask.n_waiters]

    pop r12
    pop rbx
    leave
    ret
END_FUNC task_add_waiter

;; ============================================================================
;; eventloop_run(AsyncTask *root_task) -> fat value
;; Main event loop: drain ready queue, step tasks, wait for I/O.
;; Returns when root_task completes.
;; ============================================================================
ER_ROOT equ 8
ER_FRAME equ 16            ; + 2 pushes = 32, 16-aligned
; eventloop_root_exception -- the root task's exception, owned, or 0 -- is
; in ThreadState with the loop itself.

DEF_FUNC eventloop_run, ER_FRAME
    push rbx
    push r12

    mov rbx, rdi               ; root task
    ; The loop's own reference on the root task, released at .er_release.  It
    ; is read on every pass round the loop for the done check, and a raw
    ; pointer there was safe only while tasks could not be collected.
    call obj_incref
    mov [gs:ThreadState.eventloop + EventLoop.root_task], rbx
    mov [rbp - ER_ROOT], rbx
    mov qword [gs:ThreadState.eventloop_root_exception], 0

    ; Enqueue root task
    mov rdi, rbx
    call ready_enqueue

.er_loop:
    ; Process all ready tasks
.er_drain:
    call ready_dequeue
    test rax, rax
    jz .er_wait

    mov rdi, rax
    push rax
    push rax                    ; twice, to keep rsp 16-byte aligned
    call task_step
    pop rdi
    pop rdi
    call obj_decref             ; the queue's reference
    jmp .er_drain

.er_wait:
    ; Check if root task is done
    mov rbx, [rbp - ER_ROOT]
    cmp dword [rbx + AsyncTask.done], 1
    je .er_done

    ; Wait for I/O events
    mov rax, [gs:ThreadState.eventloop + EventLoop.backend]
    call [rax + IOBackend.wait_and_drain]

    jmp .er_loop

.er_done:
    ; An exception that reached the root task was DROPPED here: this read
    ; only .result, so `asyncio.run(main())` where main raises answered None
    ; and the exception was never seen again.  It is handed back through a
    ; global rather than raised here, because the loop still has to be torn
    ; down before anything unwinds.
    mov rax, [rbx + AsyncTask.exception]
    test rax, rax
    jz .er_result
    INCREF rax
    mov [gs:ThreadState.eventloop_root_exception], rax
    xor eax, eax
    xor edx, edx
    jmp .er_release

.er_result:
    ; Return root task's result
    mov rax, [rbx + AsyncTask.result]
    V_UNPACK rax, rdx
    INCREF_VAL rax, rdx

.er_release:

    ; And let go of the root task.
    mov rdi, [gs:ThreadState.eventloop + EventLoop.root_task]
    mov qword [gs:ThreadState.eventloop + EventLoop.root_task], 0
    test rdi, rdi
    jz .er_out
    push rax
    push rdx
    call obj_decref
    pop rdx
    pop rax
.er_out:

    pop r12
    pop rbx
    leave
    ret
END_FUNC eventloop_run

;; ============================================================================
;; task_getattr — attribute lookup for task_type
;; Supports: done, result, cancel, cancelled
;; ============================================================================
DEF_FUNC task_getattr
    push rbx
    push r12

    mov rbx, rdi               ; self (AsyncTask*)
    mov r12, rsi               ; name

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "done"
    call ap_strcmp
    test eax, eax
    jz .ta_done_method

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "result"
    call ap_strcmp
    test eax, eax
    jz .ta_result_method

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "cancel"
    call ap_strcmp
    test eax, eax
    jz .ta_cancel_method

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "cancelled"
    call ap_strcmp
    test eax, eax
    jz .ta_cancelled_method

    RET_NULL
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.ta_done_method:
    call _get_task_done_builtin
    mov rdi, rax
    call obj_incref
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.ta_result_method:
    call _get_task_result_builtin
    mov rdi, rax
    call obj_incref
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.ta_cancel_method:
    call _get_task_cancel_builtin
    mov rdi, rax
    call obj_incref
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.ta_cancelled_method:
    call _get_task_cancelled_builtin
    mov rdi, rax
    call obj_incref
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC task_getattr

;; ============================================================================
;; task_iter_self — tp_iter for task: return self
;; ============================================================================
DEF_FUNC_BARE task_iter_self
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret
END_FUNC task_iter_self

;; ============================================================================
;; task_iternext — tp_iternext for task: yield self or stop.
;; When awaited, yields itself so the event loop can track the dependency;
;; task_step recognizes it by its type.
;; ============================================================================
DEF_FUNC_BARE task_iternext
    ; If done, return NULL (signals StopIteration to SEND)
    cmp dword [rdi + AsyncTask.done], 1
    je .ti_done

    ; Not done — yield self; task_step identifies it by ob_type
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret

.ti_done:
    ; Check for exception — if task was cancelled/errored, raise it
    mov rax, [rdi + AsyncTask.exception]
    test rax, rax
    jnz .ti_done_exc

    ; No exception — copy result for StopIteration protocol.  A copy into an
    ; owned slot needs its own reference, even from the same task's result:
    ; both are released.
    mov rsi, [rdi + AsyncTask.result]
    call task_set_send_value
    ; Return NULL to signal completion
    RET_NULL
    ret

.ti_done_exc:
    ; The task carries an exception: re-raise it into the awaiting frame.
    ;
    ; This used to store straight into current_exception, which drops
    ; whatever was already there without releasing it and skips
    ; __context__ chaining entirely.  Reached from SEND inside an except
    ; block -- which is exactly where `try: await t` puts it -- that leaks
    ; the handled exception's reference and loses the chain.  It was
    ; unreachable until task_step started recording the exception, and is
    ; live now.  raise_exception_obj does both, and takes over the reference
    ; INCREF just added.
    INCREF rax
    mov rdi, rax
    extern raise_exception_obj
    call raise_exception_obj    ; does not return
END_FUNC task_iternext

;; ============================================================================
;; task_repr
;; ============================================================================
DEF_FUNC_BARE task_repr
    lea rdi, [rel task_repr_str]
    jmp str_from_cstr
END_FUNC task_repr

;; ============================================================================
;; Builtin method implementations for task
;; ============================================================================

;; task.done() -> bool
DEF_FUNC _task_done_impl
    mov rax, [rdi]             ; self = args[0]
    mov eax, [rax + AsyncTask.done]
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC _task_done_impl

;; task.result() -> value
DEF_FUNC _task_result_impl
    mov rax, [rdi]
    cmp dword [rax + AsyncTask.done], 0
    je .tr_not_done
    ; Check for exception
    mov rcx, [rax + AsyncTask.exception]
    test rcx, rcx
    jnz .tr_exception
    ; Return result
    mov rax, [rax + AsyncTask.result]
    INCREF_V rax, rdx
    V_UNPACK rax, rdx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.tr_not_done:
    RAISE exc_RuntimeError_type, "Result is not ready"

.tr_exception:
    mov rdi, rcx
    INCREF rdi                 ; borrowed from AsyncTask; raise takes ownership
    call raise_exception_obj
END_FUNC _task_result_impl

;; task.cancel() -> True
DEF_FUNC _task_cancel_impl
    mov rax, [rdi]
    mov dword [rax + AsyncTask.cancelling], 1
    mov eax, 1
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC _task_cancel_impl

;; task.cancelled() -> bool
DEF_FUNC _task_cancelled_impl
    mov rax, [rdi]
    mov eax, [rax + AsyncTask.cancelling]
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC _task_cancelled_impl

;; Lazy-init builtin caches
DEF_FUNC_LOCAL _get_task_done_builtin
    mov rax, [rel _task_done_cache]
    test rax, rax
    jnz .ret
    lea rdi, [rel _task_done_impl]
    CSTRING rsi, "done"
    call builtin_func_new
    mov [rel _task_done_cache], rax
.ret:
    leave
    ret
END_FUNC _get_task_done_builtin

DEF_FUNC_LOCAL _get_task_result_builtin
    mov rax, [rel _task_result_cache]
    test rax, rax
    jnz .ret
    lea rdi, [rel _task_result_impl]
    CSTRING rsi, "result"
    call builtin_func_new
    mov [rel _task_result_cache], rax
.ret:
    leave
    ret
END_FUNC _get_task_result_builtin

DEF_FUNC_LOCAL _get_task_cancel_builtin
    mov rax, [rel _task_cancel_cache]
    test rax, rax
    jnz .ret
    lea rdi, [rel _task_cancel_impl]
    CSTRING rsi, "cancel"
    call builtin_func_new
    mov [rel _task_cancel_cache], rax
.ret:
    leave
    ret
END_FUNC _get_task_cancel_builtin

DEF_FUNC_LOCAL _get_task_cancelled_builtin
    mov rax, [rel _task_cancelled_cache]
    test rax, rax
    jnz .ret
    lea rdi, [rel _task_cancelled_impl]
    CSTRING rsi, "cancelled"
    call builtin_func_new
    mov [rel _task_cancelled_cache], rax
.ret:
    leave
    ret
END_FUNC _get_task_cancelled_builtin

;; ============================================================================
;; Data section
;; ============================================================================
section .data

task_name_str:  db "Task", 0
task_repr_str:  db "<Task>", 0

align 8
_task_done_cache: dq 0
_task_result_cache: dq 0
_task_cancel_cache: dq 0
_task_cancelled_cache: dq 0

align 8
global task_type
task_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq task_name_str            ; tp_name
    dq AsyncTask_size           ; tp_basicsize
    dq task_dealloc             ; tp_dealloc
    dq task_repr                ; tp_repr
    dq task_repr                ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq task_getattr             ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq task_iter_self           ; tp_iter
    dq task_iternext            ; tp_iternext
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
    dq task_traverse            ; tp_traverse
    dq task_clear               ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; The loop is per thread, as CPython's running loop is: ThreadState.eventloop
; (src/include/threadstate.inc), with its backend's state beside it.

section .data
