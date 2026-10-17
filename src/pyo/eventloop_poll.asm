; eventloop_poll.asm - poll()-based I/O backend for event loop
;
; Uses libc poll() for fd readiness + timer min-heap for timeouts.
; Fallback when io_uring is unavailable.

%include "macros.inc"
%include "object.inc"
%include "eventloop.inc"

extern ap_malloc
extern ap_realloc
extern ready_enqueue
extern none_singleton
extern obj_incref
extern obj_decref
extern task_set_send_value

; libc poll(struct pollfd *fds, nfds_t nfds, int timeout_ms)
extern poll

; clock_gettime(clockid_t, struct timespec *)
extern clock_gettime

CLOCK_MONOTONIC equ 1

;; ============================================================================
;; Poll backend state (file-scope globals)
;; ============================================================================
section .bss

align 8
; Both arrays GROW.  They were fixed at 1024 fds and 256 timers, and both
; submit paths simply returned when full -- as though the request had been
; armed -- so the task waited for a wakeup that could never come.  256 timers
; is one `gather` of 300 sleeps, which is not an unusual program.
;
; The pollfd array and the parallel fd->task mapping, one entry each per fd
; (poll_fds, poll_fd_tasks, poll_cap, poll_nfds), and the timer min-heap of
; (deadline_ns, task*) entries (timer_heap, timer_cap, timer_count), belong to
; the loop, which is per thread: they are in ThreadState.

; Scratch timespec for clock_gettime
timespec_buf:   resq 2

section .text

;; ============================================================================
;; poll_init() -> 0
;; Initialize poll backend.
;; ============================================================================
DEF_FUNC poll_init
    mov dword [gs:ThreadState.poll_nfds], 0
    mov dword [gs:ThreadState.timer_count], 0
    xor eax, eax
    leave
    ret
END_FUNC poll_init

;; ============================================================================
;; poll_grow_timers() / poll_grow_fds() -> rax = 1 ok, 0 out of memory
;;
;; Room for one more entry, doubling from a first allocation of 64.  The two
;; fd arrays are parallel and grow together, so one capacity covers both.
;; ============================================================================
POLL_FIRST_CAP equ 64

DEF_FUNC_LOCAL poll_grow_timers, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov ebx, [gs:ThreadState.timer_cap]
    cmp ebx, [gs:ThreadState.timer_count]
    jg .pgt_ok
    test ebx, ebx
    jnz .pgt_double
    mov ebx, POLL_FIRST_CAP
    jmp .pgt_alloc
.pgt_double:
    add ebx, ebx
.pgt_alloc:
    mov rdi, [gs:ThreadState.timer_heap]
    mov esi, ebx
    imul rsi, rsi, TimerEntry_size
    call ap_realloc             ; ap_realloc(0, n) is a fresh allocation
    test rax, rax
    jz .pgt_fail
    mov [gs:ThreadState.timer_heap], rax
    mov [gs:ThreadState.timer_cap], ebx
.pgt_ok:
    mov eax, 1
    pop rbx
    leave
    ret
.pgt_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC poll_grow_timers

DEF_FUNC_LOCAL poll_grow_fds
    push rbx
    push r12
    mov ebx, [gs:ThreadState.poll_cap]
    cmp ebx, [gs:ThreadState.poll_nfds]
    jg .pgf_ok
    test ebx, ebx
    jnz .pgf_double
    mov ebx, POLL_FIRST_CAP
    jmp .pgf_alloc
.pgf_double:
    add ebx, ebx
.pgf_alloc:
    mov rdi, [gs:ThreadState.poll_fds]
    mov esi, ebx
    imul rsi, rsi, PollFd_size
    call ap_realloc
    test rax, rax
    jz .pgf_fail
    mov [gs:ThreadState.poll_fds], rax
    mov rdi, [gs:ThreadState.poll_fd_tasks]
    mov esi, ebx
    shl rsi, 3
    call ap_realloc
    test rax, rax
    jz .pgf_fail
    mov [gs:ThreadState.poll_fd_tasks], rax
    mov [gs:ThreadState.poll_cap], ebx
.pgf_ok:
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret
.pgf_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC poll_grow_fds

;; ============================================================================
;; poll_teardown()
;; Nothing to clean up for poll backend.
;; ============================================================================
DEF_FUNC poll_teardown
    push rbx
    push r12
    ; Release everything the two arrays still hold.  A loop torn down with
    ; work outstanding -- a cancelled sleep, a socket nobody read -- used to
    ; leave those tasks unreferenced by anything and unfreed.
    mov ebx, [gs:ThreadState.poll_nfds]
    mov dword [gs:ThreadState.poll_nfds], 0
    test ebx, ebx
    jz .pt_timers
.pt_fd_loop:
    dec ebx
    mov rax, [gs:ThreadState.poll_fd_tasks]
    mov rdi, [rax + rbx*8]
    mov qword [rax + rbx*8], 0
    test rdi, rdi
    jz .pt_fd_next
    call obj_decref
.pt_fd_next:
    test ebx, ebx
    jnz .pt_fd_loop

.pt_timers:
    mov ebx, [gs:ThreadState.timer_count]
    mov dword [gs:ThreadState.timer_count], 0
    test ebx, ebx
    jz .pt_done
.pt_timer_loop:
    dec ebx
    mov rax, [gs:ThreadState.timer_heap]
    mov r12d, ebx
    shl r12d, 4
    mov rdi, [rax + r12 + TimerEntry.task]
    mov qword [rax + r12 + TimerEntry.task], 0
    test rdi, rdi
    jz .pt_timer_next
    call obj_decref
.pt_timer_next:
    test ebx, ebx
    jnz .pt_timer_loop

.pt_done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC poll_teardown

;; ============================================================================
;; get_monotonic_ns() -> rax = current time in nanoseconds
;; ============================================================================
DEF_FUNC_LOCAL get_monotonic_ns
    mov edi, CLOCK_MONOTONIC
    lea rsi, [rel timespec_buf]
    call clock_gettime

    ; Convert to nanoseconds: tv_sec * 1_000_000_000 + tv_nsec
    mov rax, [rel timespec_buf]        ; tv_sec
    mov ecx, 1000000000
    imul rax, rcx
    add rax, [rel timespec_buf + 8]    ; tv_nsec
    leave
    ret
END_FUNC get_monotonic_ns

;; ============================================================================
;; poll_submit_timeout(AsyncTask *task, uint64_t delay_ns)
;; Insert into timer min-heap.
;; ============================================================================
DEF_FUNC poll_submit_timeout
    push rbx
    push r12

    mov rbx, rdi               ; task
    mov r12, rsi               ; delay_ns

    ; Get current time
    call get_monotonic_ns
    add rax, r12               ; deadline = now + delay_ns

    ; Insert at end of heap, growing it if this is the entry that does not fit.
    push rax
    call poll_grow_timers
    test eax, eax
    pop rax
    jz .pst_full                ; out of memory: the only way to lose one now
    mov ecx, [gs:ThreadState.timer_count]

    mov rdx, [gs:ThreadState.timer_heap]
    ; Entry = timer_heap[timer_count]
    mov rdi, rcx
    shl rdi, 4                 ; * TimerEntry_size (16 bytes)
    add rdi, rdx

    mov [rdi + TimerEntry.deadline_ns], rax
    mov [rdi + TimerEntry.task], rbx

    inc dword [gs:ThreadState.timer_count]

    ; The heap OWNS its entry.  A task waiting on a timer may have no other
    ; reference at all -- asyncio.sleep() inside a task nobody holds -- and
    ; a raw pointer here was safe only while a task could not be collected.
    ; Released where the entry is removed: expiry, cancellation, teardown.
    push rcx
    mov rdi, rbx
    call obj_incref
    pop rcx

    ; Sift up
    mov eax, ecx               ; index = timer_count (before inc, 0-based)
    call timer_sift_up

.pst_full:
    pop r12
    pop rbx
    leave
    ret
END_FUNC poll_submit_timeout

;; ============================================================================
;; poll_submit_poll_fd(AsyncTask *task, int fd, int events)
;; Add fd to pollfd array.
;; ============================================================================
DEF_FUNC poll_submit_poll_fd
    ; rdi = task, esi = fd, edx = events
    push rdi
    push rsi
    push rdx
    sub rsp, 8
    call poll_grow_fds
    add rsp, 8
    pop rdx
    pop rsi
    pop rdi
    test eax, eax
    jz .pspf_full
    mov ecx, [gs:ThreadState.poll_nfds]

    ; Fill pollfd entry
    mov rax, [gs:ThreadState.poll_fds]
    mov r8d, ecx
    imul r8d, PollFd_size
    add rax, r8
    mov [rax + PollFd.fd], esi
    mov [rax + PollFd.events], dx
    mov word [rax + PollFd.revents], 0

    ; Store task mapping.  The array owns it, for the same reason the timer
    ; heap owns its entries.
    mov rax, [gs:ThreadState.poll_fd_tasks]
    mov [rax + rcx*8], rdi

    inc dword [gs:ThreadState.poll_nfds]
    call obj_incref

.pspf_full:
    ; `ret` alone was wrong: DEF_FUNC pushes rbp, so returning without
    ; `leave` jumps to whatever the caller's rbp happened to be.  Nothing had
    ; noticed, because the only caller is a socket read or write and the
    ; stream tests skip when the poll backend is not the one in use.
    leave
    ret
END_FUNC poll_submit_poll_fd

;; ============================================================================
;; poll_cancel_io(AsyncTask *task)
;; Remove task from poll arrays and timer heap.
;; ============================================================================
DEF_FUNC poll_cancel_io, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi               ; task to cancel

    ; Scan pollfd array
    xor ecx, ecx
    mov edx, [gs:ThreadState.poll_nfds]
.pc_fd_loop:
    cmp ecx, edx
    jge .pc_check_timers
    mov rax, [gs:ThreadState.poll_fd_tasks]
    cmp [rax + rcx*8], rbx
    je .pc_remove_fd
    inc ecx
    jmp .pc_fd_loop

.pc_remove_fd:
    ; Swap with last and decrement count.  The array's reference on the task
    ; goes with the entry; rbx still names it, and the caller holds one too.
    push rcx
    push rdx
    mov rdi, rbx
    call obj_decref
    pop rdx
    pop rcx
    dec edx
    mov [gs:ThreadState.poll_nfds], edx
    cmp ecx, edx
    je .pc_check_timers        ; was already last

    ; Copy last entry to current slot
    mov rax, [gs:ThreadState.poll_fds]
    mov r8d, edx
    imul r8d, PollFd_size
    mov edi, ecx
    imul edi, PollFd_size
    ; Copy pollfd
    mov r9d, [rax + r8]
    mov [rax + rdi], r9d
    mov r9w, [rax + r8 + 4]
    mov [rax + rdi + 4], r9w
    ; Copy task mapping
    mov rax, [gs:ThreadState.poll_fd_tasks]
    mov r9, [rax + rdx*8]
    mov [rax + rcx*8], r9

.pc_check_timers:
    ; Scan timer heap (linear scan, rare operation)
    xor ecx, ecx
    mov edx, [gs:ThreadState.timer_count]
.pc_timer_loop:
    cmp ecx, edx
    jge .pc_done
    mov rax, [gs:ThreadState.timer_heap]
    mov edi, ecx
    shl edi, 4
    cmp [rax + rdi + TimerEntry.task], rbx
    je .pc_remove_timer
    inc ecx
    jmp .pc_timer_loop

.pc_remove_timer:
    ; Replace with last and re-heapify.  As above, the heap's reference ends
    ; with the entry.
    push rcx
    push rdx
    mov rdi, rbx
    call obj_decref
    pop rdx
    pop rcx
    dec edx
    mov [gs:ThreadState.timer_count], edx
    cmp ecx, edx
    je .pc_done
    mov rax, [gs:ThreadState.timer_heap]
    mov edi, edx
    shl edi, 4
    mov r8d, ecx
    shl r8d, 4
    ; Copy last to current
    mov r9, [rax + rdi + TimerEntry.deadline_ns]
    mov [rax + r8 + TimerEntry.deadline_ns], r9
    mov r9, [rax + rdi + TimerEntry.task]
    mov [rax + r8 + TimerEntry.task], r9
    ; Sift down from current position
    mov eax, ecx
    call timer_sift_down

.pc_done:
    pop rbx
    leave
    ret
END_FUNC poll_cancel_io

;; ============================================================================
;; poll_wait_and_drain()
;; Compute min timeout from timer heap, call poll(), process results.
;; ============================================================================
DEF_FUNC poll_wait_and_drain, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    ; Compute timeout_ms from timer heap
    mov eax, [gs:ThreadState.timer_count]
    test eax, eax
    jz .pwd_no_timers

    ; Get earliest deadline
    mov rax, [gs:ThreadState.timer_heap]
    mov rbx, [rax + TimerEntry.deadline_ns]  ; min deadline

    ; Get current time
    call get_monotonic_ns
    ; rax = now_ns

    sub rbx, rax               ; remaining_ns = deadline - now
    test rbx, rbx
    jle .pwd_timeout_zero

    ; Convert ns to ms: remaining_ns / 1_000_000
    mov rax, rbx
    mov ecx, 1000000
    xor edx, edx
    div rcx
    ; rax = timeout_ms (may be 0 for sub-ms)
    test rax, rax
    jz .pwd_timeout_one        ; at least 1ms
    mov r12d, eax
    jmp .pwd_do_poll

.pwd_timeout_one:
    mov r12d, 1
    jmp .pwd_do_poll

.pwd_timeout_zero:
    xor r12d, r12d             ; 0ms timeout
    jmp .pwd_do_poll

.pwd_no_timers:
    ; No timers — check if we have fds
    mov eax, [gs:ThreadState.poll_nfds]
    test eax, eax
    jz .pwd_idle
    mov r12d, 100              ; 100ms default timeout
    jmp .pwd_do_poll

.pwd_idle:
    ; Nothing to wait on — shouldn't happen in a well-formed program
    pop r13
    pop r12
    pop rbx
    leave
    ret

.pwd_do_poll:
    ; Call poll(poll_fds, nfds, timeout_ms)
    mov rdi, [gs:ThreadState.poll_fds]
    mov esi, [gs:ThreadState.poll_nfds]
    mov edx, r12d
    call poll
    ; rax = number of fds ready (or -1 on error)

    ; Process expired timers first
    call get_monotonic_ns
    mov r13, rax               ; r13 = now_ns

.pwd_timer_check:
    mov eax, [gs:ThreadState.timer_count]
    test eax, eax
    jz .pwd_check_fds

    mov rcx, [gs:ThreadState.timer_heap]
    cmp r13, [rcx + TimerEntry.deadline_ns]
    jl .pwd_check_fds          ; heap top not expired yet

    ; Pop expired timer (top of heap)
    mov rbx, [rcx + TimerEntry.task]  ; expired task

    ; Remove top: replace with last, sift down
    dec dword [gs:ThreadState.timer_count]
    mov eax, [gs:ThreadState.timer_count]
    test eax, eax
    jz .pwd_timer_empty

    ; Copy last to top
    mov edx, eax
    shl edx, 4
    mov r8, [rcx + rdx + TimerEntry.deadline_ns]
    mov [rcx + TimerEntry.deadline_ns], r8
    mov r8, [rcx + rdx + TimerEntry.task]
    mov [rcx + TimerEntry.task], r8
    xor eax, eax
    call timer_sift_down

.pwd_timer_empty:
    ; Enqueue the expired task and let go of the heap's reference: the entry
    ; is gone, and ready_enqueue has taken one of its own.
    mov rdi, rbx
    lea rsi, [rel none_singleton]
    call task_set_send_value
    mov rdi, rbx
    call ready_enqueue
    mov rdi, rbx
    call obj_decref
    jmp .pwd_timer_check

.pwd_check_fds:
    ; Process ready fds
    xor ecx, ecx               ; index
    mov r12d, [gs:ThreadState.poll_nfds]

.pwd_fd_loop:
    cmp ecx, r12d
    jge .pwd_done

    mov rax, [gs:ThreadState.poll_fds]
    mov edx, ecx
    imul edx, PollFd_size
    movzx r8d, word [rax + rdx + PollFd.revents]
    test r8d, r8d
    jz .pwd_fd_next

    ; This fd has events — enqueue its task
    push rcx
    mov rax, [gs:ThreadState.poll_fd_tasks]
    mov rbx, [rax + rcx*8]

    ; Set send_value to None (fd ready notification)
    mov rdi, rbx
    lea rsi, [rel none_singleton]
    call task_set_send_value

    ; Remove this fd entry (swap with last, decrement)
    dec r12d
    mov [gs:ThreadState.poll_nfds], r12d

    pop rcx
    cmp ecx, r12d
    je .pwd_fd_removed          ; was last entry

    ; Swap with last
    push rcx
    mov rax, [gs:ThreadState.poll_fds]
    mov edx, r12d
    imul edx, PollFd_size
    mov edi, ecx
    imul edi, PollFd_size
    mov r9d, [rax + rdx]
    mov [rax + rdi], r9d
    mov r9w, [rax + rdx + 4]
    mov [rax + rdi + 4], r9w

    mov rax, [gs:ThreadState.poll_fd_tasks]
    mov r9, [rax + r12*8]
    mov [rax + rcx*8], r9
    pop rcx

.pwd_fd_removed:
    mov rdi, rbx
    call ready_enqueue
    mov rdi, rbx                ; and the array's reference, entry removed
    call obj_decref
    jmp .pwd_fd_loop            ; don't increment, new entry at same index

.pwd_fd_next:
    inc ecx
    jmp .pwd_fd_loop

.pwd_done:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC poll_wait_and_drain

;; ============================================================================
;; Timer heap sift operations (binary min-heap)
;; ============================================================================

;; timer_sift_up(int index)
;; eax = index of newly inserted element
DEF_FUNC_LOCAL timer_sift_up
    push rbx
    mov rbx, [gs:ThreadState.timer_heap]

.tsu_loop:
    test eax, eax
    jz .tsu_done

    ; parent = (index - 1) / 2
    mov ecx, eax
    dec ecx
    shr ecx, 1

    ; Compare: heap[index].deadline < heap[parent].deadline ?
    mov edx, eax
    shl edx, 4
    mov edi, ecx
    shl edi, 4

    mov r8, [rbx + rdx + TimerEntry.deadline_ns]
    cmp r8, [rbx + rdi + TimerEntry.deadline_ns]
    jge .tsu_done

    ; Swap entries
    mov r8, [rbx + rdx + TimerEntry.deadline_ns]
    mov r9, [rbx + rdx + TimerEntry.task]
    mov r10, [rbx + rdi + TimerEntry.deadline_ns]
    mov r11, [rbx + rdi + TimerEntry.task]
    mov [rbx + rdx + TimerEntry.deadline_ns], r10
    mov [rbx + rdx + TimerEntry.task], r11
    mov [rbx + rdi + TimerEntry.deadline_ns], r8
    mov [rbx + rdi + TimerEntry.task], r9

    mov eax, ecx               ; index = parent
    jmp .tsu_loop

.tsu_done:
    pop rbx
    leave
    ret
END_FUNC timer_sift_up

;; timer_sift_down(int index)
;; eax = index of element to sift down
DEF_FUNC_LOCAL timer_sift_down
    push rbx
    push r12
    mov rbx, [gs:ThreadState.timer_heap]
    mov r12d, [gs:ThreadState.timer_count]

.tsd_loop:
    ; left = 2*index + 1
    mov ecx, eax
    shl ecx, 1
    inc ecx

    cmp ecx, r12d
    jge .tsd_done              ; no children

    ; right = left + 1
    mov edx, ecx
    inc edx

    ; Find smallest child
    mov edi, ecx
    shl edi, 4
    mov r8, [rbx + rdi + TimerEntry.deadline_ns]  ; left deadline

    cmp edx, r12d
    jge .tsd_left_only

    ; Compare left vs right
    mov esi, edx
    shl esi, 4
    mov r9, [rbx + rsi + TimerEntry.deadline_ns]  ; right deadline
    cmp r9, r8
    jge .tsd_left_only

    ; Right is smaller
    mov ecx, edx              ; smallest = right
    mov r8, r9

.tsd_left_only:
    ; Compare parent vs smallest child
    mov edi, eax
    shl edi, 4
    cmp [rbx + rdi + TimerEntry.deadline_ns], r8
    jle .tsd_done              ; parent <= smallest child, done

    ; Swap parent with smallest child
    mov esi, ecx
    shl esi, 4
    mov r8, [rbx + rdi + TimerEntry.deadline_ns]
    mov r9, [rbx + rdi + TimerEntry.task]
    mov r10, [rbx + rsi + TimerEntry.deadline_ns]
    mov r11, [rbx + rsi + TimerEntry.task]
    mov [rbx + rdi + TimerEntry.deadline_ns], r10
    mov [rbx + rdi + TimerEntry.task], r11
    mov [rbx + rsi + TimerEntry.deadline_ns], r8
    mov [rbx + rsi + TimerEntry.task], r9

    mov eax, ecx               ; index = smallest child
    jmp .tsd_loop

.tsd_done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC timer_sift_down

;; ============================================================================
;; Data: poll_backend vtable
;; ============================================================================
section .data
align 8
global poll_backend
poll_backend:
    dq poll_init
    dq poll_teardown
    dq poll_submit_timeout
    dq poll_submit_poll_fd
    dq poll_cancel_io
    dq poll_wait_and_drain
