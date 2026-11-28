; mmap.asm - the `_mmapcore` module: the mapping, and nothing else.
;
; The split src/modules/zlib.asm's header states as a contract.  What is
; genuinely machine work -- the mmap/munmap/mremap/msync calls, the raw bytes
; of the mapping, and the search over them -- lives here; everything a Python
; program sees is lib/mmap.py: the mmap object, the ACCESS_* translation, the
; cursor, readline, the slice protocol and every default.  So each function
; here takes a fixed number of positional arguments and answers with a bytes,
; an int or None.
;
; A handle is an INDEX into mc_handles, not a pointer.  That matters more here
; than anywhere else in the tree: the thing behind it is a raw address and a
; length, and a pointer handed to Python would be an integer a program could
; forge and this module would then write through.  An index is bounds-checked,
; carries a magic word, and a freed slot reads back as 0.
;
; Offsets are checked HERE rather than in lib/mmap.py, for the same reason.
; Every read, write, move and find bounds-checks against the handle's own
; length before it touches the mapping; a Python-side check would be one
; refactor away from being the only one.

%include "macros.inc"
%include "object.inc"

ASM_INIT
extern none_singleton
extern ap_malloc
extern ap_free
extern ap_realloc
extern ap_memcpy
extern dict_new
extern dict_set
extern module_new
extern obj_decref
extern str_from_cstr_heap
extern builtin_func_new
extern bytes_new
extern bytes_type
extern bytearray_type
extern int_from_i64
extern obj_as_index
extern exc_TypeError_type
extern exc_ValueError_type
extern set_oserror
extern set_exception
extern sys_mmap
extern sys_munmap
extern sys_mremap
extern sys_msync
extern sys_madvise

;; ============================================================================
;; MC_CHECK reg
;;
;; The kernel returns -errno in [-4095, -1] and the result otherwise, which as
;; an unsigned compare is "at or above -4095".  src/modules/posix.asm has the
;; same macro under its own name; it is four instructions and sharing it would
;; mean a header for four instructions.
;; ============================================================================
%macro MC_CHECK 2               ; %1 = the result, %2 = the error exit
    cmp %1, -4095
    jb %%ok
    mov rdi, %1
    neg rdi
    xor esi, esi
    call set_oserror
    jmp %2
%%ok:
%endmacro

MC_MAGIC equ 0x4D4D4150         ; "MMAP"

struc MHandle
    .addr:   resq 1
    .length: resq 1
    .magic:  resq 1
endstruc

section .bss
alignb 64
mc_handle_lock: resd 1
alignb 8
mc_handles:    resq 1
mc_handle_n:   resq 1
mc_handle_cap: resq 1

section .text

;; ============================================================================
;; mc_handle_at(rdi = handle index) -> rax = MHandle*, or 0
;;
;; Bounds-checked and magic-checked, because the index came from Python.
;; ============================================================================
DEF_FUNC_BARE mc_handle_at
    xor eax, eax
    test rdi, rdi
    js .mha_no
    RT_LOCK_GATED mc_handle_lock
    cmp rdi, [rel mc_handle_n]
    jae .mha_unlock_no
    mov rax, [rel mc_handles]
    test rax, rax
    jz .mha_unlock_no
    mov rax, [rax + rdi*8]
    test rax, rax
    jz .mha_unlock_no
    cmp qword [rax + MHandle.magic], MC_MAGIC
    je .mha_unlock_out
    xor eax, eax
.mha_unlock_out:
    RT_UNLOCK_GATED mc_handle_lock
    ret
.mha_unlock_no:
    xor eax, eax
    RT_UNLOCK_GATED mc_handle_lock
.mha_no:
    ret
END_FUNC mc_handle_at

;; ============================================================================
;; mc_arg_int(rdi = args, rsi = index) -> rax = the int
;; Fails: -1
;; ============================================================================
DEF_FUNC_BARE mc_arg_int
    mov rdi, [rdi + rsi*8]
    V_UNPACK rdi, rdx
    sub rsp, 8                  ; a call, so the refusal can be seen
    call obj_as_index           ; err: its -1 is handed on as it is
    add rsp, 8
    ret
END_FUNC mc_arg_int

;; ============================================================================
;; mc_state_arg(rdi = args, rsi = index) -> rax = MHandle*
;; Fails: 0
;; (an argument that is no index, or a handle that is not live)
;; ============================================================================
MSA_FRAME equ 16                ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL mc_state_arg, MSA_FRAME
    call mc_arg_int
    ERR_M1 .msa_fail
    mov rdi, rax
    call mc_handle_at
    test rax, rax
    jz .msa_bad
    leave
    ret
.msa_bad:
    SET_EXC exc_ValueError_type, "mmap closed or invalid"
.msa_fail:
    xor eax, eax
    leave
    ret
END_FUNC mc_state_arg

;; ============================================================================
;; mc_buffer(rdi = a Value) -> rax = data pointer, rdx = length, rax = 0 when
;;   it is neither bytes nor bytearray
;; ============================================================================
DEF_FUNC_BARE mc_buffer
    V_TEST_PTR rdi, rax
    ja .mb_no
    test rdi, rdi
    jz .mb_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .mb_bytes
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    jne .mb_no
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    mov rax, [rdi + PyByteArrayObject.ob_bytes]
    ret
.mb_bytes:
    mov rdx, [rdi + PyBytesObject.ob_size]
    lea rax, [rdi + PyBytesObject.data]
    ret
.mb_no:
    xor eax, eax
    xor edx, edx
    ret
END_FUNC mc_buffer

;; ============================================================================
;; mc_slot(rdi = MHandle*) -> rax = the handle index, as a Value
;;
;; Files the mapping in the table, reusing a slot a close() gave back.
;; Cannot fail: out of memory is fatal_error inside ap_realloc.
;; ============================================================================
MS_H     equ 8
MS_CAP   equ 16
MS_FRAME equ 40                 ; + 1 push = 48, 16-aligned
DEF_FUNC_LOCAL mc_slot, MS_FRAME
    push rbx
    mov rbx, rdi
    RT_LOCK_GATED mc_handle_lock
    xor ecx, ecx
    mov rdx, [rel mc_handles]
    test rdx, rdx
    jz .ms_grow
.ms_scan:
    cmp rcx, [rel mc_handle_n]
    jae .ms_grow
    cmp qword [rdx + rcx*8], 0
    je .ms_have
    inc rcx
    jmp .ms_scan

.ms_grow:
    mov rax, [rel mc_handle_n]
    cmp rax, [rel mc_handle_cap]
    jb .ms_no_grow
    mov rsi, [rel mc_handle_cap]
    test rsi, rsi
    jnz .ms_double
    mov esi, 8
    jmp .ms_realloc
.ms_double:
    add rsi, rsi
.ms_realloc:
    mov [rbp - MS_CAP], rsi
    shl rsi, 3
    mov rdi, [rel mc_handles]
    call ap_realloc
    mov [rel mc_handles], rax
    mov rcx, [rbp - MS_CAP]
    mov [rel mc_handle_cap], rcx
.ms_no_grow:
    mov rcx, [rel mc_handle_n]
    inc qword [rel mc_handle_n]
    mov rdx, [rel mc_handles]

.ms_have:
    mov [rdx + rcx*8], rbx
    RT_UNLOCK_GATED mc_handle_lock
    mov rdi, rcx
    call int_from_i64
    V_PACK rax, rdx
    pop rbx
    leave
    ret
END_FUNC mc_slot

;; ============================================================================
;; _mmapcore.map(fd, length, prot, flags, offset) -> a handle
;;
;; fd of -1 is the anonymous mapping mmap.mmap(-1, n) asks for; lib/mmap.py
;; adds MAP_ANONYMOUS for it, because the flag is the caller's business and
;; the syscall is this module's.
;; ============================================================================
MM_LEN   equ 8
MM_ADDR  equ 16
MM_H     equ 24
MM_ARGS  equ 32
MM_FD    equ 40                 ; in the frame, not in registers: an argument
MM_PROT  equ 48                 ; with __index__ runs Python, and nothing in
MM_FLAGS equ 56                 ; r8-r10 survives that
MM_FRAME equ 64                 ; + 0 pushes = 64, 16-aligned
DEF_FUNC mc_map, MM_FRAME
    cmp rsi, 5
    jne .mm_nargs
    mov [rbp - MM_ARGS], rdi

    mov esi, 1
    call mc_arg_int
    ERR_M1 .mm_fail
    test rax, rax
    js .mm_badlen
    mov [rbp - MM_LEN], rax

    mov rdi, [rbp - MM_ARGS]
    xor esi, esi
    call mc_arg_int
    ERR_M1 .mm_fail
    mov [rbp - MM_FD], rax
    mov rdi, [rbp - MM_ARGS]
    mov esi, 2
    call mc_arg_int
    ERR_M1 .mm_fail
    mov [rbp - MM_PROT], rax
    mov rdi, [rbp - MM_ARGS]
    mov esi, 3
    call mc_arg_int
    ERR_M1 .mm_fail
    mov [rbp - MM_FLAGS], rax
    mov rdi, [rbp - MM_ARGS]
    mov esi, 4
    call mc_arg_int
    ERR_M1 .mm_fail

    ; sys_mmap(addr, len, prot, flags, fd, offset)
    mov r9, rax                 ; offset
    xor edi, edi
    mov rsi, [rbp - MM_LEN]
    mov rdx, [rbp - MM_PROT]
    mov rcx, [rbp - MM_FLAGS]
    mov r8, [rbp - MM_FD]
    call sys_mmap
    MC_CHECK rax, .mm_fail
    mov [rbp - MM_ADDR], rax

    mov edi, MHandle_size
    call ap_malloc              ; cannot fail: out of memory is fatal_error
    mov [rbp - MM_H], rax
    mov rcx, [rbp - MM_ADDR]
    mov [rax + MHandle.addr], rcx
    mov rcx, [rbp - MM_LEN]
    mov [rax + MHandle.length], rcx
    mov qword [rax + MHandle.magic], MC_MAGIC

    mov rdi, rax
    call mc_slot
    leave
    ret

.mm_badlen:
    FAIL exc_ValueError_type, "memory mapped length must be positive", .mm_fail
.mm_nargs:
    SET_EXC exc_TypeError_type, "_mmapcore: wrong number of arguments"
.mm_fail:
    xor eax, eax
    leave
    ret
END_FUNC mc_map

;; ============================================================================
;; _mmapcore.unmap(handle) -> None
;;
;; Idempotent: a handle already given back is not an error, because close() is
;; reached from __del__ as well as from the caller.
;; ============================================================================
MU_IDX   equ 8
MU_FRAME equ 16                 ; + 0 pushes = 16, 16-aligned
DEF_FUNC mc_unmap, MU_FRAME
    cmp rsi, 1
    jne .mu_nargs
    xor esi, esi
    call mc_arg_int
    ERR_M1 .mu_fail
    mov [rbp - MU_IDX], rax
    RT_LOCK_GATED mc_handle_lock
    mov rdx, rax
    test rdx, rdx
    js .mu_unlock_done
    cmp rdx, [rel mc_handle_n]
    jae .mu_unlock_done
    mov rcx, [rel mc_handles]
    test rcx, rcx
    jz .mu_unlock_done
    mov rax, [rcx + rdx*8]
    test rax, rax
    jz .mu_unlock_done
    cmp qword [rax + MHandle.magic], MC_MAGIC
    jne .mu_unlock_done
    mov qword [rcx + rdx*8], 0
    mov qword [rax + MHandle.magic], 0
    RT_UNLOCK_GATED mc_handle_lock
    push rax
    sub rsp, 8
    mov rdi, [rax + MHandle.addr]
    mov rsi, [rax + MHandle.length]
    call sys_munmap
    add rsp, 8
    pop rdi
    call ap_free
    jmp .mu_done
.mu_unlock_done:
    RT_UNLOCK_GATED mc_handle_lock
.mu_done:
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
.mu_nargs:
    FAIL exc_TypeError_type, "_mmapcore: wrong number of arguments", .mu_fail
.mu_fail:
    xor eax, eax
    leave
    ret
END_FUNC mc_unmap

;; ============================================================================
;; _mmapcore.size(handle) -> the mapping's length in bytes
;; ============================================================================
MZ_FRAME equ 16                 ; + 0 pushes = 16, 16-aligned
DEF_FUNC mc_size, MZ_FRAME
    cmp rsi, 1
    jne .mz_nargs
    xor esi, esi
    call mc_state_arg
    ERR_NULL .mz_fail
    mov rdi, [rax + MHandle.length]
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
.mz_nargs:
    FAIL exc_TypeError_type, "_mmapcore: wrong number of arguments", .mz_fail
.mz_fail:
    xor eax, eax
    leave
    ret
END_FUNC mc_size

;; ============================================================================
;; _mmapcore.read(handle, start, count) -> bytes
;;
;; start and count are clamped to the mapping rather than refused: the caller
;; is m.read(n) at some cursor, and CPython returns what is there.
;; ============================================================================
MR_H     equ 8
MR_START equ 16
MR_N     equ 24
MR_FRAME equ 40                 ; + 1 push = 48, 16-aligned
DEF_FUNC mc_read, MR_FRAME
    push rbx
    cmp rsi, 3
    jne .mr_nargs
    mov rbx, rdi
    xor esi, esi
    call mc_state_arg
    ERR_NULL .mr_fail
    mov [rbp - MR_H], rax
    mov rdi, rbx
    mov esi, 1
    call mc_arg_int
    ERR_M1 .mr_fail
    mov [rbp - MR_START], rax
    mov rdi, rbx
    mov esi, 2
    call mc_arg_int
    ERR_M1 .mr_fail
    mov [rbp - MR_N], rax

    mov rcx, [rbp - MR_H]
    mov rcx, [rcx + MHandle.length]
    mov rax, [rbp - MR_START]
    test rax, rax
    js .mr_range
    cmp rax, rcx
    ja .mr_range
    mov rdx, rcx
    sub rdx, rax                ; what is left after start
    mov rax, [rbp - MR_N]
    test rax, rax
    js .mr_range
    cmp rax, rdx
    jbe .mr_have_n
    mov rax, rdx
.mr_have_n:
    mov [rbp - MR_N], rax

    mov rdi, rax
    call bytes_new              ; cannot fail: out of memory is fatal_error
    mov rbx, rax
    mov rdx, [rbp - MR_N]
    test rdx, rdx
    jz .mr_done
    lea rdi, [rbx + PyBytesObject.data]
    mov rsi, [rbp - MR_H]
    mov rsi, [rsi + MHandle.addr]
    add rsi, [rbp - MR_START]
    call ap_memcpy
.mr_done:
    mov rax, rbx
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.mr_range:
    FAIL exc_ValueError_type, "read out of range", .mr_fail
.mr_nargs:
    FAIL exc_TypeError_type, "_mmapcore: wrong number of arguments", .mr_fail
.mr_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC mc_read

;; ============================================================================
;; _mmapcore.write(handle, start, data) -> the number of bytes written
;;
;; Refused rather than clamped, because a short write into a mapping is a lost
;; write and CPython raises for it.
;; ============================================================================
MW_H     equ 8
MW_START equ 16
MW_SRC   equ 24
MW_N     equ 32
MW_FRAME equ 56                 ; + 1 push = 64, 16-aligned
DEF_FUNC mc_write, MW_FRAME
    push rbx
    cmp rsi, 3
    jne .mw_nargs
    mov rbx, rdi
    xor esi, esi
    call mc_state_arg
    ERR_NULL .mw_fail
    mov [rbp - MW_H], rax
    mov rdi, rbx
    mov esi, 1
    call mc_arg_int
    ERR_M1 .mw_fail
    mov [rbp - MW_START], rax

    mov rdi, [rbx + 16]
    call mc_buffer
    test rax, rax
    jz .mw_type
    mov [rbp - MW_SRC], rax
    mov [rbp - MW_N], rdx

    mov rcx, [rbp - MW_H]
    mov rcx, [rcx + MHandle.length]
    mov rax, [rbp - MW_START]
    test rax, rax
    js .mw_range
    cmp rax, rcx
    ja .mw_range
    sub rcx, rax
    cmp [rbp - MW_N], rcx
    ja .mw_range

    mov rdx, [rbp - MW_N]
    test rdx, rdx
    jz .mw_done
    mov rdi, [rbp - MW_H]
    mov rdi, [rdi + MHandle.addr]
    add rdi, [rbp - MW_START]
    mov rsi, [rbp - MW_SRC]
    call ap_memcpy
.mw_done:
    mov rdi, [rbp - MW_N]
    call int_from_i64
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.mw_type:
    FAIL exc_TypeError_type, "data must be bytes or bytearray", .mw_fail
.mw_range:
    FAIL exc_ValueError_type, "data out of range", .mw_fail
.mw_nargs:
    FAIL exc_TypeError_type, "_mmapcore: wrong number of arguments", .mw_fail
.mw_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC mc_write

;; ============================================================================
;; _mmapcore.find(handle, sub, start, end, reverse) -> the index, or -1
;;
;; find and rfind in one, because they differ only in which end the scan
;; starts from and doing it in Python would read the mapping a byte at a time
;; through the interpreter.  An empty needle matches at `start`, which is what
;; every other find in the language does.
;; ============================================================================
MF_H     equ 8
MF_SUB   equ 16
MF_SUBN  equ 24
MF_START equ 32
MF_END   equ 40
MF_REV   equ 48
MF_FRAME equ 56                 ; + 1 push = 64, 16-aligned
DEF_FUNC mc_find, MF_FRAME
    push rbx
    cmp rsi, 5
    jne .mf_nargs
    mov rbx, rdi
    xor esi, esi
    call mc_state_arg
    ERR_NULL .mf_fail
    mov [rbp - MF_H], rax

    mov rdi, [rbx + 8]
    call mc_buffer
    test rax, rax
    jz .mf_type
    mov [rbp - MF_SUB], rax
    mov [rbp - MF_SUBN], rdx

    mov rdi, rbx
    mov esi, 2
    call mc_arg_int
    ERR_M1 .mf_fail
    mov [rbp - MF_START], rax
    mov rdi, rbx
    mov esi, 3
    call mc_arg_int
    ERR_M1 .mf_fail
    mov [rbp - MF_END], rax
    mov rdi, rbx
    mov esi, 4
    call mc_arg_int
    ERR_M1 .mf_fail
    mov [rbp - MF_REV], rax

    ; Clamp the window to the mapping.
    mov rcx, [rbp - MF_H]
    mov rcx, [rcx + MHandle.length]
    mov rax, [rbp - MF_START]
    test rax, rax
    jns .mf_start_ok
    xor eax, eax
.mf_start_ok:
    cmp rax, rcx
    jbe .mf_start_in
    mov rax, rcx
.mf_start_in:
    mov [rbp - MF_START], rax
    mov rax, [rbp - MF_END]
    test rax, rax
    jns .mf_end_ok
    xor eax, eax
.mf_end_ok:
    cmp rax, rcx
    jbe .mf_end_in
    mov rax, rcx
.mf_end_in:
    mov [rbp - MF_END], rax

    ; The last position a match could start at: end - len(sub).
    mov rax, [rbp - MF_END]
    sub rax, [rbp - MF_SUBN]
    js .mf_miss
    cmp rax, [rbp - MF_START]
    jb .mf_miss
    mov rdx, rax                ; rdx = the last candidate
    mov rcx, [rbp - MF_START]   ; rcx = the first candidate
    cmp qword [rbp - MF_REV], 0
    jne .mf_back

.mf_fwd:
    cmp rcx, rdx
    ja .mf_miss
    call mc_match_at
    test eax, eax
    jnz .mf_hit
    inc rcx
    jmp .mf_fwd

.mf_back:
    mov r8, rcx
    mov rcx, rdx
.mf_back_loop:
    cmp rcx, r8
    jb .mf_miss
    call mc_match_at
    test eax, eax
    jnz .mf_hit
    test rcx, rcx
    jz .mf_miss
    dec rcx
    jmp .mf_back_loop

.mf_hit:
    mov rdi, rcx
    call int_from_i64
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.mf_miss:
    mov rdi, -1
    call int_from_i64
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.mf_type:
    FAIL exc_TypeError_type, "the pattern must be bytes or bytearray", .mf_fail
.mf_nargs:
    FAIL exc_TypeError_type, "_mmapcore: wrong number of arguments", .mf_fail
.mf_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC mc_find

;; ============================================================================
;; mc_match_at(rcx = the offset) -> eax = 1 when the needle is there
;;
;; A leaf of mc_find, reading its frame through rbp: the loop is the whole
;; cost of find() over a mapping, so the comparison does not go through a
;; call's register shuffling.  rcx, rdx and r8 are the caller's loop state and
;; are preserved.
;; ============================================================================
DEF_FUNC_BARE mc_match_at
    push rcx
    push rsi
    push rdi
    mov rsi, [rbp - MF_H]
    mov rsi, [rsi + MHandle.addr]
    add rsi, rcx
    mov rdi, [rbp - MF_SUB]
    mov rax, [rbp - MF_SUBN]
.mma_loop:
    test rax, rax
    jz .mma_yes
    mov cl, [rsi]
    cmp cl, [rdi]
    jne .mma_no
    inc rsi
    inc rdi
    dec rax
    jmp .mma_loop
.mma_yes:
    mov eax, 1
    jmp .mma_out
.mma_no:
    xor eax, eax
.mma_out:
    pop rdi
    pop rsi
    pop rcx
    ret
END_FUNC mc_match_at

;; ============================================================================
;; _mmapcore.flush(handle, offset, size) -> 0
;;
;; msync with MS_SYNC.  The mapping is already coherent with the file through
;; the page cache, so what a caller asking for a flush wants is durability.
;; ============================================================================
MS_SYNC equ 4

MQ_H     equ 8
MQ_OFF   equ 16
MQ_SIZE  equ 24
MQ_FRAME equ 40                 ; + 1 push = 48, 16-aligned
DEF_FUNC mc_flush, MQ_FRAME
    push rbx
    cmp rsi, 3
    jne .mq_nargs
    mov rbx, rdi
    xor esi, esi
    call mc_state_arg
    ERR_NULL .mq_fail
    mov [rbp - MQ_H], rax
    mov rdi, rbx
    mov esi, 1
    call mc_arg_int
    ERR_M1 .mq_fail
    mov [rbp - MQ_OFF], rax
    mov rdi, rbx
    mov esi, 2
    call mc_arg_int
    ERR_M1 .mq_fail
    mov [rbp - MQ_SIZE], rax

    mov rcx, [rbp - MQ_H]
    mov rcx, [rcx + MHandle.length]
    mov rax, [rbp - MQ_OFF]
    test rax, rax
    js .mq_range
    cmp rax, rcx
    ja .mq_range
    sub rcx, rax
    mov rax, [rbp - MQ_SIZE]
    test rax, rax
    js .mq_range
    cmp rax, rcx
    ja .mq_range

    mov rdi, [rbp - MQ_H]
    mov rdi, [rdi + MHandle.addr]
    add rdi, [rbp - MQ_OFF]
    mov rsi, [rbp - MQ_SIZE]
    mov edx, MS_SYNC
    call sys_msync
    MC_CHECK rax, .mq_fail
    xor edi, edi
    call int_from_i64
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.mq_range:
    FAIL exc_ValueError_type, "flush values out of range", .mq_fail
.mq_nargs:
    FAIL exc_TypeError_type, "_mmapcore: wrong number of arguments", .mq_fail
.mq_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC mc_flush

;; ============================================================================
;; _mmapcore.resize(handle, new_length) -> None
;;
;; mremap with MREMAP_MAYMOVE, so the address changes; nothing outside this
;; module holds it, which is the point of the handle being an index.
;; ============================================================================
MREMAP_MAYMOVE equ 1

MX_H     equ 8
MX_NEW   equ 16
MX_FRAME equ 40                 ; + 1 push = 48, 16-aligned
DEF_FUNC mc_resize, MX_FRAME
    push rbx
    cmp rsi, 2
    jne .mx_nargs
    mov rbx, rdi
    xor esi, esi
    call mc_state_arg
    ERR_NULL .mx_fail
    mov [rbp - MX_H], rax
    mov rdi, rbx
    mov esi, 1
    call mc_arg_int
    ERR_M1 .mx_fail
    test rax, rax
    jle .mx_bad
    mov [rbp - MX_NEW], rax

    mov rdi, [rbp - MX_H]
    mov rsi, [rdi + MHandle.length]
    mov rdi, [rdi + MHandle.addr]
    mov rdx, [rbp - MX_NEW]
    mov ecx, MREMAP_MAYMOVE
    xor r8d, r8d
    call sys_mremap
    MC_CHECK rax, .mx_fail
    mov rcx, [rbp - MX_H]
    mov [rcx + MHandle.addr], rax
    mov rdx, [rbp - MX_NEW]
    mov [rcx + MHandle.length], rdx
    RET_NONE
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.mx_bad:
    FAIL exc_ValueError_type, "new size must be positive", .mx_fail
.mx_nargs:
    FAIL exc_TypeError_type, "_mmapcore: wrong number of arguments", .mx_fail
.mx_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC mc_resize

;; ============================================================================
;; _mmapcore.move(handle, dest, src, count) -> None
;;
;; An overlapping copy inside the mapping; ap_memcpy is a memmove, so the
;; overlap is already handled.
;; ============================================================================
MV_H     equ 8
MV_DEST  equ 16
MV_SRC   equ 24
MV_N     equ 32
MV_FRAME equ 56                 ; + 1 push = 64, 16-aligned
DEF_FUNC mc_move, MV_FRAME
    push rbx
    cmp rsi, 4
    jne .mv_nargs
    mov rbx, rdi
    xor esi, esi
    call mc_state_arg
    ERR_NULL .mv_fail
    mov [rbp - MV_H], rax
    mov rdi, rbx
    mov esi, 1
    call mc_arg_int
    ERR_M1 .mv_fail
    mov [rbp - MV_DEST], rax
    mov rdi, rbx
    mov esi, 2
    call mc_arg_int
    ERR_M1 .mv_fail
    mov [rbp - MV_SRC], rax
    mov rdi, rbx
    mov esi, 3
    call mc_arg_int
    ERR_M1 .mv_fail
    mov [rbp - MV_N], rax

    mov r9, [rbp - MV_H]
    mov r9, [r9 + MHandle.length]
    mov rax, [rbp - MV_N]
    test rax, rax
    js .mv_range
    mov rcx, [rbp - MV_DEST]
    test rcx, rcx
    js .mv_range
    add rcx, rax
    jc .mv_range
    cmp rcx, r9
    ja .mv_range
    mov rcx, [rbp - MV_SRC]
    test rcx, rcx
    js .mv_range
    add rcx, rax
    jc .mv_range
    cmp rcx, r9
    ja .mv_range

    mov rcx, [rbp - MV_N]
    test rcx, rcx
    jz .mv_done
    mov rdi, [rbp - MV_H]
    mov rdi, [rdi + MHandle.addr]
    mov rsi, rdi
    add rdi, [rbp - MV_DEST]
    add rsi, [rbp - MV_SRC]
    ; The two regions overlap whenever a caller shifts data along the
    ; mapping, which is what move() is FOR, so the direction has to be chosen:
    ; ap_memcpy walks downwards, and m.move(0, 1, 2) over "0123456789" then
    ; wrote "22" where CPython writes "12" -- the second byte was copied first
    ; and the first read it back.
    cmp rdi, rsi
    jbe .mv_forward
    lea rdi, [rdi + rcx - 1]
    lea rsi, [rsi + rcx - 1]
    std
    rep movsb
    cld
    jmp .mv_done
.mv_forward:
    rep movsb
.mv_done:
    RET_NONE
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.mv_range:
    FAIL exc_ValueError_type, "source, destination, or count out of range", .mv_fail
.mv_nargs:
    FAIL exc_TypeError_type, "_mmapcore: wrong number of arguments", .mv_fail
.mv_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC mc_move

;; ============================================================================
;; _mmapcore.advise(handle, option, start, length) -> None
;;
;; madvise, which the kernel is free to ignore -- so a refusal is reported and
;; a shrug is not.
;; ============================================================================
MA_H     equ 8
MA_OPT   equ 16
MA_START equ 24
MA_LEN   equ 32
MA_FRAME equ 56                 ; + 1 push = 64, 16-aligned
DEF_FUNC mc_advise, MA_FRAME
    push rbx
    cmp rsi, 4
    jne .ma_nargs
    mov rbx, rdi
    xor esi, esi
    call mc_state_arg
    ERR_NULL .ma_fail
    mov [rbp - MA_H], rax
    mov rdi, rbx
    mov esi, 1
    call mc_arg_int
    ERR_M1 .ma_fail
    mov [rbp - MA_OPT], rax
    mov rdi, rbx
    mov esi, 2
    call mc_arg_int
    ERR_M1 .ma_fail
    mov [rbp - MA_START], rax
    mov rdi, rbx
    mov esi, 3
    call mc_arg_int
    ERR_M1 .ma_fail
    mov [rbp - MA_LEN], rax

    mov rcx, [rbp - MA_H]
    mov rcx, [rcx + MHandle.length]
    mov rax, [rbp - MA_START]
    test rax, rax
    js .ma_range
    cmp rax, rcx
    ja .ma_range
    sub rcx, rax
    mov rax, [rbp - MA_LEN]
    test rax, rax
    js .ma_range
    cmp rax, rcx
    ja .ma_range

    mov rdi, [rbp - MA_H]
    mov rdi, [rdi + MHandle.addr]
    add rdi, [rbp - MA_START]
    mov rsi, [rbp - MA_LEN]
    mov rdx, [rbp - MA_OPT]
    call sys_madvise
    MC_CHECK rax, .ma_fail
    RET_NONE
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.ma_range:
    FAIL exc_ValueError_type, "madvise start or length out of range", .ma_fail
.ma_nargs:
    FAIL exc_TypeError_type, "_mmapcore: wrong number of arguments", .ma_fail
.ma_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC mc_advise

;; ============================================================================
;; mmap_module_create() -> rax = the module object
;; ============================================================================
MMC_FRAME equ 32                ; + 2 pushes = 48, 16-aligned
DEF_FUNC mmap_module_create, MMC_FRAME
    push rbx
    push r12
    call dict_new
    mov r12, rax                ; MODULE_ADD_FUNC reads the dict from r12

    MODULE_ADD_FUNC mc_map,    mc_n_map
    MODULE_ADD_FUNC mc_unmap,  mc_n_unmap
    MODULE_ADD_FUNC mc_size,   mc_n_size
    MODULE_ADD_FUNC mc_read,   mc_n_read
    MODULE_ADD_FUNC mc_write,  mc_n_write
    MODULE_ADD_FUNC mc_find,   mc_n_find
    MODULE_ADD_FUNC mc_flush,  mc_n_flush
    MODULE_ADD_FUNC mc_resize, mc_n_resize
    MODULE_ADD_FUNC mc_move,   mc_n_move
    MODULE_ADD_FUNC mc_advise, mc_n_advise

    lea rdi, [rel mc_name]
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov rbx, rax
    mov rdi, r12
    call obj_decref
    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret
END_FUNC mmap_module_create

section .rodata
mc_name:     db "_mmapcore", 0
mc_n_map:    db "map", 0
mc_n_unmap:  db "unmap", 0
mc_n_size:   db "size", 0
mc_n_read:   db "read", 0
mc_n_write:  db "write", 0
mc_n_find:   db "find", 0
mc_n_flush:  db "flush", 0
mc_n_resize: db "resize", 0
mc_n_move:   db "move", 0
mc_n_advise: db "advise", 0
