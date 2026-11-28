; synctest.asm - standalone self-test for src/sync.asm (--selftest-sync).
;
; Exercises 32-bit futex locks, register-preserving wrappers, ordered dual
; locking (deadlock freedom + alias handling), and the BRC thread registry
; and merge queue under real 4-thread pthread contention.

%include "macros.inc"
%include "threadstate.inc"
%include "sync.inc"

ASM_INIT

extern pthread_create
extern pthread_join
extern free
extern sys_write
extern rt_mutex_lock
extern rt_mutex_unlock
extern rt_mutex_lock_p
extern rt_mutex_unlock_p
extern rt_mutex_lock2_p
extern rt_mutex_unlock2_p
extern rt_tid_alloc
extern brc_register_thread
extern brc_unregister_thread
extern brc_enqueue
extern brc_take_queue
extern rt_threaded
extern tstate_link
extern tstate_unlink
extern rt_detach
extern rt_reattach
extern stw_safepoint
extern stw_stop_world
extern stw_start_world

ST_NTHREADS  equ 4
ST_ITERS     equ 100000
ST_ITERS2    equ 50000
ST_STW_REQ   equ 2000
ST_STW_MUT   equ 20000
SYS_arch_prctl equ 158
ARCH_SET_GS  equ 0x1001

section .bss
alignb 64
st_lock_a:      resd 1
                resb 60
st_lock_b:      resd 1
                resb 60
st_counter:     resq 1
st_bal_a:       resq 1
st_bal_b:       resq 1
st_reg_err:     resq 1
st_stw_in_stw:  resq 1
st_stw_epochs:  resq 1
st_fake_ts:     resb ThreadState_size
alignb 64
st_stw_ts:      resb ThreadState_size * ST_NTHREADS

section .rodata
st_ok_msg:      db "sync selftest: OK", 10
st_ok_len       equ $ - st_ok_msg
st_fail_msg:    db "sync selftest: FAIL", 10
st_fail_len     equ $ - st_fail_msg

section .text

;; st_worker_single(rdi = unused) -> rax = NULL
;; Worker 1: contended rt_mutex_lock_p / rt_mutex_unlock_p + register check.
DEF_FUNC_LOCAL st_worker_single
    push rbx
    push r12
    mov ebx, ST_ITERS
.ws_loop:
    ; Load sentinel patterns into caller-saved regs to verify _p preservation.
    mov rax, 0x1122334455667788
    mov rcx, 0x2233445566778899
    mov rdx, 0x33445566778899aa
    mov rsi, 0x445566778899aabb
    mov r8,  0x5566778899aabbcc
    mov r9,  0x66778899aabbccdd
    mov r10, 0x778899aabbccddee
    mov r11, 0x8899aabbccddeeff
    lea rdi, [rel st_lock_a]
    call rt_mutex_lock_p
    mov r12, 0x1122334455667788
    cmp rax, r12
    jne .ws_bad
    mov r12, 0x8899aabbccddeeff
    cmp r11, r12
    jne .ws_bad
    inc qword [rel st_counter]
    call rt_mutex_unlock_p
    mov r12, 0x2233445566778899
    cmp rcx, r12
    jne .ws_bad
    dec ebx
    jnz .ws_loop
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
.ws_bad:
    lock inc qword [rel st_reg_err]
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC st_worker_single

;; st_worker_dual(rdi = thread index) -> rax = NULL
;; Worker 2: opposing lock2 order (A,B) vs (B,A) + aliased (A,A).
DEF_FUNC_LOCAL st_worker_dual
    push rbx
    push r12
    mov r12, rdi
    mov ebx, ST_ITERS2
.wd_loop:
    test r12, 1
    jnz .wd_odd
    lea rdi, [rel st_lock_a]
    lea rsi, [rel st_lock_b]
    call rt_mutex_lock2_p
    dec qword [rel st_bal_a]
    inc qword [rel st_bal_b]
    call rt_mutex_unlock2_p
    jmp .wd_alias
.wd_odd:
    lea rdi, [rel st_lock_b]
    lea rsi, [rel st_lock_a]
    call rt_mutex_lock2_p
    inc qword [rel st_bal_a]
    dec qword [rel st_bal_b]
    call rt_mutex_unlock2_p
.wd_alias:
    ; Alias check: lock2(A, A) must not self-deadlock.
    lea rdi, [rel st_lock_a]
    mov rsi, rdi
    call rt_mutex_lock2_p
    call rt_mutex_unlock2_p
    dec ebx
    jnz .wd_loop
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC st_worker_dual

;; st_worker_stw(rdi = thread index 0..3) -> rax = NULL
;; Worker 4: 0,1 issue concurrent stw_stop_world/start_world; 2,3 alternate
;; stw_safepoint and rt_detach/rt_reattach, asserting st_stw_in_stw == 0
;; whenever attached outside STW.
DEF_FUNC_LOCAL st_worker_stw
    push rbx
    push r12
    mov r12, rdi
    imul rax, r12, ThreadState_size
    lea rbx, [rel st_stw_ts]
    add rbx, rax
    mov [rbx + ThreadState.ts_self], rbx
    lea eax, [r12d + 1]
    mov [rbx + ThreadState.ts_tid], eax
    mov dword [rbx + ThreadState.ts_state], TS_STATE_DETACHED
    mov qword [rbx + ThreadState.ts_next], 0

    mov eax, SYS_arch_prctl
    mov edi, ARCH_SET_GS
    mov rsi, rbx
    syscall

    call tstate_link
    call rt_reattach

    cmp r12, 2
    jae .w4_mutator

    mov ebx, ST_STW_REQ
.w4_req_loop:
    call stw_stop_world
    cmp qword [rel st_stw_in_stw], 0
    je .w4_req_ok1
    lock inc qword [rel st_reg_err]
.w4_req_ok1:
    mov qword [rel st_stw_in_stw], 1
    inc qword [rel st_stw_epochs]
    pause
    pause
    cmp qword [rel st_stw_in_stw], 1
    je .w4_req_ok2
    lock inc qword [rel st_reg_err]
.w4_req_ok2:
    mov qword [rel st_stw_in_stw], 0
    call stw_start_world
    test ebx, 3
    jnz .w4_req_next
    call stw_safepoint
.w4_req_next:
    dec ebx
    jnz .w4_req_loop
    jmp .w4_exit

.w4_mutator:
    mov ebx, ST_STW_MUT
.w4_mut_loop:
    call stw_safepoint
    cmp qword [rel st_stw_in_stw], 0
    je .w4_mut_ok1
    lock inc qword [rel st_reg_err]
.w4_mut_ok1:
    test ebx, 7
    jnz .w4_mut_next
    call rt_detach
    pause
    pause
    call rt_reattach
    cmp qword [rel st_stw_in_stw], 0
    je .w4_mut_next
    lock inc qword [rel st_reg_err]
.w4_mut_next:
    dec ebx
    jnz .w4_mut_loop

.w4_exit:
    call tstate_unlink
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC st_worker_stw

;; ============================================================================
;; sync_selftest_main() -> eax = 0 on pass, 1 on fail
;; ============================================================================
STM_TIDS  equ 32                ; 4 * pthread_t
STM_LEN   equ 40                ; brc_take_queue out_len
STM_FRAME equ 48                ; + 2 pushes = 64, 16-aligned
global sync_selftest_main
DEF_FUNC sync_selftest_main, STM_FRAME
    push rbx
    push r12

    ; --- Test 1: 4-thread contended futex + register preservation ---
    mov dword [rel st_lock_a], 0
    mov qword [rel st_counter], 0
    mov qword [rel st_reg_err], 0

    xor ebx, ebx
.t1_spawn:
    lea rdi, [rbp - STM_TIDS + rbx*8]
    xor esi, esi
    lea rdx, [rel st_worker_single]
    xor ecx, ecx
    call pthread_create wrt ..plt
    test eax, eax
    jnz .fail
    inc ebx
    cmp ebx, ST_NTHREADS
    jb .t1_spawn

    xor ebx, ebx
.t1_join:
    mov rdi, [rbp - STM_TIDS + rbx*8]
    xor esi, esi
    call pthread_join wrt ..plt
    inc ebx
    cmp ebx, ST_NTHREADS
    jb .t1_join

    cmp qword [rel st_reg_err], 0
    jne .fail
    cmp qword [rel st_counter], ST_NTHREADS * ST_ITERS
    jne .fail

    ; --- Test 2: 4-thread opposing lock2 (A,B) vs (B,A) + alias (A,A) ---
    mov dword [rel st_lock_a], 0
    mov dword [rel st_lock_b], 0
    mov qword [rel st_bal_a], 1000000
    mov qword [rel st_bal_b], 1000000

    xor ebx, ebx
.t2_spawn:
    lea rdi, [rbp - STM_TIDS + rbx*8]
    xor esi, esi
    lea rdx, [rel st_worker_dual]
    mov rcx, rbx
    call pthread_create wrt ..plt
    test eax, eax
    jnz .fail
    inc ebx
    cmp ebx, ST_NTHREADS
    jb .t2_spawn

    xor ebx, ebx
.t2_join:
    mov rdi, [rbp - STM_TIDS + rbx*8]
    xor esi, esi
    call pthread_join wrt ..plt
    inc ebx
    cmp ebx, ST_NTHREADS
    jb .t2_join

    mov rax, [rel st_bal_a]
    add rax, [rel st_bal_b]
    cmp rax, 2000000
    jne .fail

    ; --- Test 3: BRC registry + live enqueue + take_queue + orphan ---
    lea rbx, [rel st_fake_ts]
    call rt_tid_alloc
    mov [rbx + ThreadState.ts_tid], eax
    mov r12d, eax

    mov rdi, rbx
    call brc_register_thread

    ; Enqueue 100 dummy object pointers (forces queue growth past 64).
    mov ecx, 100
.t3_enq:
    push rcx
    sub rsp, 8
    mov edi, r12d
    mov rsi, rcx
    shl rsi, 4
    call brc_enqueue
    add rsp, 8
    pop rcx
    cmp eax, 1
    jne .fail
    dec ecx
    jnz .t3_enq

    mov rdi, rbx
    lea rsi, [rbp - STM_LEN]
    call brc_take_queue
    test rax, rax
    jz .fail
    cmp qword [rbp - STM_LEN], 100
    jne .fail
    mov rdi, rax
    call free wrt ..plt

    ; Unregister -> subsequent enqueue must report orphan (0).
    mov rdi, rbx
    call brc_unregister_thread
    mov edi, r12d
    mov esi, 0x1000
    call brc_enqueue
    test eax, eax
    jnz .fail

    ; --- Test 4: 4-thread STW coordinator stress (stop/start/safepoint/detach) ---
    mov qword [rel st_reg_err], 0
    mov qword [rel st_stw_in_stw], 0
    mov qword [rel st_stw_epochs], 0
    mov byte [rel rt_threaded], 1
    call rt_detach

    xor ebx, ebx
.t4_spawn:
    lea rdi, [rbp - STM_TIDS + rbx*8]
    xor esi, esi
    lea rdx, [rel st_worker_stw]
    mov rcx, rbx
    call pthread_create wrt ..plt
    test eax, eax
    jnz .fail_stw
    inc ebx
    cmp ebx, ST_NTHREADS
    jb .t4_spawn

    xor ebx, ebx
.t4_join:
    mov rdi, [rbp - STM_TIDS + rbx*8]
    xor esi, esi
    call pthread_join wrt ..plt
    inc ebx
    cmp ebx, ST_NTHREADS
    jb .t4_join

    call rt_reattach
    mov byte [rel rt_threaded], 0
    cmp qword [rel st_reg_err], 0
    jne .fail
    cmp qword [rel st_stw_epochs], 2 * ST_STW_REQ
    jne .fail

    mov edi, 1
    lea rsi, [rel st_ok_msg]
    mov edx, st_ok_len
    call sys_write
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.fail_stw:
    mov byte [rel rt_threaded], 0
.fail:
    mov edi, 2
    lea rsi, [rel st_fail_msg]
    mov edx, st_fail_len
    call sys_write
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret
END_FUNC sync_selftest_main
