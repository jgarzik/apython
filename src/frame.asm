; frame.asm - Frame allocation and deallocation
; Manages execution frames for the bytecode interpreter
;
; Frame pooling: 4 size classes (256, 512, 1024, 2048 bytes).
; Each class has a freelist (singly-linked, max FRAME_POOL_MAX_FREE entries).
; frame_pool_get(size) checks freelist first, falls back to ap_malloc.
; frame_pool_put(frame, size) pushes to freelist or ap_free if full.

%include "macros.inc"
%include "object.inc"

extern ap_malloc
extern ap_free
extern obj_dealloc
extern obj_decref

; The pool's constants live in object.inc, beside PyFrame: the specialized
; call pops the smallest class inline and needs them too.  A pool record is
; (head, count), selected as a unit with `lea rcx, [rel frame_pool_free_N]`
; and then indexed -- the count was once reached as a bare [rcx + 8], which
; made frame_pool_count_N decoration.


;; ============================================================================
;; THE FRAME DATASTACK
;;
;; A frame pushed inline by the specialized call has a lifetime the
;; interpreter can prove.  That handler's guards refuse CO_GENERATOR,
;; CO_COROUTINE and CO_ASYNC_GENERATOR -- the only shapes that return with the
;; frame still live -- so such a frame is always released by the resume of the
;; very call that made it.  Inline calls nest, so their frames nest, so the
;; region they come from can be a bump pointer: an allocation is an add and a
;; compare, a release is one store, against a four-way size ladder and a
;; capped freelist each way.
;;
;; Everything else still comes from the pool -- module bodies, eval(), class
;; bodies, generators, func_call's slow path -- so nothing about a generator
;; frame's lifetime changes, and frame_free tells the two apart by address.
;;
;; The region is not grown.  Running out falls back to the pool, which is
;; correct if slower, and stays correct while both are in use: a datastack
;; frame's callee may come from the pool without disturbing the top, and the
;; datastack frames that remain still nest among themselves.
;;
;; Four megabytes is about sixteen thousand frames of the smallest size,
;; against a default recursion limit of a thousand.  It is malloc'd on the
;; first inline call rather than at startup, so a program that makes none --
;; and the .pyc probes are full of them -- pays nothing.
;; ============================================================================
FRAME_DATASTACK_BYTES equ 4 * 1024 * 1024

;; ============================================================================
;; frame_alloc_inline(rdi = size) -> rax = a block of at least that size
;;
;; The slow half of the specialized call's frame allocation: the fast half is
;; four instructions inlined in the handler, and this is where it lands when
;; the region does not exist yet or has no room.  Falling back to the pool is
;; a tail call, so the handler makes one call either way.
;; ============================================================================
DEF_FUNC frame_alloc_inline
    cmp qword [gs:ThreadState.frame_datastack_base], 0
    je .fai_create
.fai_have_region:
    mov rax, [gs:ThreadState.frame_datastack_top]
    lea rcx, [rax + rdi]
    cmp rcx, [gs:ThreadState.frame_datastack_end]
    ja .fai_pool                ; no room: the pool, which can always grow
    mov [gs:ThreadState.frame_datastack_top], rcx
    leave
    ret
.fai_pool:
    leave
    jmp frame_pool_get          ; rdi is still the size

.fai_create:
    push rdi
    push rdi                    ; twice: rsp keeps its alignment
    mov edi, FRAME_DATASTACK_BYTES
    call ap_malloc
    pop rdi
    pop rdi
    test rax, rax
    jz .fai_pool                ; no region, ever: the pool does the work
    mov [gs:ThreadState.frame_datastack_base], rax
    mov [gs:ThreadState.frame_datastack_top], rax
    add rax, FRAME_DATASTACK_BYTES
    mov [gs:ThreadState.frame_datastack_end], rax
    jmp .fai_have_region
END_FUNC frame_alloc_inline

;; ============================================================================
;; frame_pool_get(size) -> ptr
;; Allocate from pool or ap_malloc. rdi = requested size.
;; Returns rax = pointer (size rounded up to next pool class).
;; ============================================================================
DEF_FUNC frame_pool_get
    ; Round up to pool class
    cmp rdi, FRAME_POOL_CLASS_0
    jbe .fp_class0
    cmp rdi, FRAME_POOL_CLASS_1
    jbe .fp_class1
    cmp rdi, FRAME_POOL_CLASS_2
    jbe .fp_class2
    cmp rdi, FRAME_POOL_CLASS_3
    jbe .fp_class3
    ; Too large for pool — ap_malloc
    jmp .fp_malloc

.fp_class0:
    lea rcx, [rel frame_pool_free_0]
    mov edi, FRAME_POOL_CLASS_0
    jmp .fp_try_pool
.fp_class1:
    lea rcx, [rel frame_pool_free_1]
    mov edi, FRAME_POOL_CLASS_1
    jmp .fp_try_pool
.fp_class2:
    lea rcx, [rel frame_pool_free_2]
    mov edi, FRAME_POOL_CLASS_2
    jmp .fp_try_pool
.fp_class3:
    lea rcx, [rel frame_pool_free_3]
    mov edi, FRAME_POOL_CLASS_3

.fp_try_pool:
    ; rcx = &pool_free_N, edi = class size
    mov rax, [rcx + FRAME_POOL_HEAD]      ; head of freelist
    test rax, rax
    jz .fp_malloc              ; empty freelist
    ; Pop from freelist: head = head->next
    mov rdx, [rax]             ; next pointer (stored at offset 0)
    mov [rcx + FRAME_POOL_HEAD], rdx
    ; Decrement count
    lea rdx, [rcx + FRAME_POOL_COUNT]     ; &pool_count_N
    dec dword [rdx]
    ; rax = recycled frame
    leave
    ret

.fp_malloc:
    call ap_malloc
    leave
    ret
END_FUNC frame_pool_get

;; ============================================================================
;; frame_pool_put(ptr, size)
;; Return to pool or ap_free. rdi = ptr, rsi = size.
;; ============================================================================
DEF_FUNC frame_pool_put
    ; Determine pool class
    cmp rsi, FRAME_POOL_CLASS_0
    jbe .fpp_class0
    cmp rsi, FRAME_POOL_CLASS_1
    jbe .fpp_class1
    cmp rsi, FRAME_POOL_CLASS_2
    jbe .fpp_class2
    cmp rsi, FRAME_POOL_CLASS_3
    jbe .fpp_class3
    ; Too large — ap_free
    leave
    jmp ap_free                ; tail call

.fpp_class0:
    lea rcx, [rel frame_pool_free_0]
    jmp .fpp_try_push
.fpp_class1:
    lea rcx, [rel frame_pool_free_1]
    jmp .fpp_try_push
.fpp_class2:
    lea rcx, [rel frame_pool_free_2]
    jmp .fpp_try_push
.fpp_class3:
    lea rcx, [rel frame_pool_free_3]

.fpp_try_push:
    ; rcx = &pool_free_N
    lea rdx, [rcx + FRAME_POOL_COUNT]     ; &pool_count_N
    cmp dword [rdx], FRAME_POOL_MAX_FREE
    jge .fpp_full
    ; Push to freelist: frame->next = head; head = frame
    mov rax, [rcx + FRAME_POOL_HEAD]      ; old head
    mov [rdi], rax                  ; frame->next = old head
    mov [rcx + FRAME_POOL_HEAD], rdi      ; head = frame
    inc dword [rdx]            ; count++
    leave
    ret

.fpp_full:
    ; Pool is full — ap_free
    leave
    jmp ap_free                ; tail call (rdi already set)
END_FUNC frame_pool_put

;; ============================================================================
;; frame_new(PyCodeObject *code, PyObject *globals, PyObject *builtins, PyObject *locals) -> PyFrame*
;; Allocates and initializes a new execution frame.
;; rdi = code, rsi = globals, rdx = builtins, rcx = locals
;; ============================================================================
DEF_FUNC frame_new, 8            ; 5 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi            ; rbx = code
    mov r12, rsi            ; r12 = globals
    mov r13, rdx            ; r13 = builtins
    mov r14, rcx            ; r14 = locals

    ; Calculate frame size: FRAME_HEADER_SIZE + (nlocalsplus + stacksize) * 8
    ;
    ; In 64 bits.  The two fields are 32-bit and came out of a .pyc, so adding
    ; them in 32 bits let a crafted pair near 2^31 wrap to a small total: the
    ; frame was allocated far too short and the value stack ran off the end of
    ; it.  The marshal reader now caps each field, and this is the other half
    ; -- frame_new is also reached from the compiler, which produces its own
    ; numbers, so the arithmetic has to be right on its own.
    mov eax, [rbx + PyCodeObject.co_nlocalsplus]
    mov ecx, [rbx + PyCodeObject.co_stacksize]
    add rax, rcx
    mov r15, rax            ; r15 = nlocalsplus + stacksize (total slots)
    shl rax, 3              ; * 8 bytes per slot (payload only)
    add rax, FRAME_HEADER_SIZE
    mov rdi, rax
    call frame_pool_get
    ; rax = frame pointer
    mov r11, rax
    ; nlocalsplus, once.  It was re-read four times below -- twice from the
    ; code object and twice from the frame field just written -- because eax
    ; and ecx kept being spent on the size arithmetic.  r8 is free here:
    ; frame_pool_get has already returned.
    mov r8d, [rbx + PyCodeObject.co_nlocalsplus]

    ; Fill frame header fields
    mov qword [r11 + PyFrame.prev_frame], 0
    mov [r11 + PyFrame.code], rbx
    mov [r11 + PyFrame.globals], r12
    mov [r11 + PyFrame.builtins], r13
    mov [r11 + PyFrame.locals], r14
    mov qword [r11 + PyFrame.instr_ptr], 0
    mov qword [r11 + PyFrame.stack_ptr], 0
    ; disp_ip is read by frameobj_refresh_pos for any frame that is not the
    ; innermost, and nothing wrote it here -- so a recycled frame answered
    ; f_lineno from the previous call's saved IP.  Valgrind reports it as a
    ; branch on uninitialised memory in frameobj_detach.
    mov qword [r11 + PyFrame.disp_ip], 0
    mov dword [r11 + PyFrame.exc_depth], 0
    ; The pool hands back memory it did not zero, so a field that is read
    ; before it is written has to be initialised here.  exc_state is XDECREFd
    ; by frame_free, which makes a stale pointer a free of someone else's
    ; object rather than a wrong answer.
    mov qword [r11 + PyFrame.exc_state], 0
    ; frame_obj is the same trap one field along: it is a BORROWED pointer to
    ; a refcounted object, so a stale one is a live frame object handed to
    ; whoever calls frameobj_for next.
    mov qword [r11 + PyFrame.frame_obj], 0
    ; The pool does not zero, and a recycled frame carrying a dead
    ; generator's back-pointer would let frame.clear() close it.
    mov qword [r11 + PyFrame.gen_owner], 0
    ; And how the frame is entered.  Every caller of frame_new that goes on to
    ; `call eval_frame` wants FRAME_ENTRY_CALL, which is zero; the one handler
    ; that pushes the frame inline overwrites it.  A recycled frame carrying a
    ; stale FRAME_ENTRY_INLINE would make eval_return jump to a resume with no
    ; call to resume, so this is not an optional zero.  Both dwords go at once.
    mov qword [r11 + PyFrame.entry_kind], 0

    ; Set nlocalsplus and func_obj
    mov [r11 + PyFrame.nlocalsplus], r8d
    mov qword [r11 + PyFrame.func_obj], 0

    ; stack_base = &localsplus[nlocalsplus] (8 bytes/slot)
    lea rdi, [r11 + PyFrame.localsplus]
    lea rsi, [rdi + r8*8]
    mov [r11 + PyFrame.stack_base], rsi

    ; Zero the locals (one Value per slot; an empty slot is 0).
    ;
    ; `rep stosq` carries twenty to thirty cycles of startup whatever the
    ; count, and the count here is usually tiny -- a function of one or two
    ; parameters is the common shape.  Four or fewer slots are stored straight
    ; through, which is the same argument ap_memcpy's size ladder makes.
    mov ecx, r8d
    test ecx, ecx
    jz .done
    xor eax, eax
    cmp ecx, 4
    ja .zero_rep
    mov [rdi], rax
    cmp ecx, 1
    je .done
    mov [rdi + 8], rax
    cmp ecx, 2
    je .done
    mov [rdi + 16], rax
    cmp ecx, 3
    je .done
    mov [rdi + 24], rax
    jmp .done
.zero_rep:
    push r11                ; rep stosq advances rdi; r11 is the frame
    rep stosq               ; store ecx qwords of 0 at [rdi]
    pop r11

.done:
    mov rax, r11            ; return frame pointer
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC frame_new

;; ============================================================================
;; frame_free(PyFrame *frame)
;; XDECREF all non-NULL localsplus entries, then free the frame.
;; rdi = frame
;; ============================================================================
DEF_FUNC frame_free, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    mov rbx, rdi            ; rbx = frame

    ; Anything looking at this frame has to stop looking before the pool takes
    ; the memory back.  frameobj_detach copies out the line, the offset and
    ; the fast locals -- everything that stops being readable -- and drops
    ; both borrowed pointers.
    ;
    ; BEFORE the localsplus walk below, not after: the copy INCREFs each
    ; local, and the walk has already released them by then.  Detaching last
    ; resurrected freed objects into the snapshot's f_locals dict, and the
    ; crash landed in the collector rather than here.
    cmp qword [rbx + PyFrame.frame_obj], 0
    je .no_frame_obj
    mov rdi, rbx
    extern frameobj_detach
    call frameobj_detach
.no_frame_obj:

    mov r12d, [rbx + PyFrame.nlocalsplus]  ; r12d = nlocalsplus
    xor r13d, r13d          ; r13d = loop index
    ; Iterate through localsplus entries.  The index arithmetic is the
    ; addressing mode's -- it used to be a `mov` and a `shl` per slot, on a
    ; loop that runs once per local of every call that returns.
    test r12d, r12d
    jz .stack_walk
.loop:
    mov rdi, [rbx + r13*8 + PyFrame.localsplus]
    XDECREF_V rdi, rsi      ; no-op for NULL and for immediates

.next:
    inc r13d
    cmp r13d, r12d
    jb .loop

.stack_walk:
    ; A SUSPENDED frame still owns everything on its VALUE STACK -- the
    ; iterator a `for` was walking, an operand half-way through an expression
    ; -- and this walked localsplus and stopped there.  So an abandoned
    ; generator released its locals and leaked the rest.
    ;
    ; instr_ptr is what says the frame is suspended.  For one that ran to
    ; completion the stack is already empty and stack_ptr holds the LAST
    ; suspension's value, which would be walked twice.
    cmp qword [rbx + PyFrame.instr_ptr], 0
    je .free_frame
    mov r12, [rbx + PyFrame.stack_ptr]
    test r12, r12
    jz .free_frame
    mov r13, [rbx + PyFrame.stack_base]
.stack_loop:
    cmp r12, r13
    jbe .free_frame
    sub r12, 8
    mov rdi, [r12]
    XDECREF_V rdi, rsi
    jmp .stack_loop

.free_frame:
    ; A generator abandoned inside an except block still holds the exception
    ; it was handling, swapped out of the global by its last suspension.
    mov rdi, [rbx + PyFrame.exc_state]
    test rdi, rdi
    jz .no_exc_state
    mov qword [rbx + PyFrame.exc_state], 0
    call obj_decref
.no_exc_state:
    mov rcx, [gs:ThreadState.ts_self]   ; one gs load; the rest are base+disp

    ; A datastack frame goes back by moving the top, and that is correct
    ; because these frames nest -- see the header above frame_alloc_inline.
    ; The test is an address range, which is also what keeps the two kinds of
    ; frame apart while both are in use.
    mov rax, [rcx + ThreadState.frame_datastack_base]
    cmp rbx, rax
    jb .ff_pool
    cmp rbx, [rcx + ThreadState.frame_datastack_end]
    jae .ff_pool
    mov [rcx + ThreadState.frame_datastack_top], rbx
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ff_pool:
    ; Calculate frame size for pool return.  The same 64-bit add frame_new
    ; makes, and it has to be the same or the pool is handed a size the block
    ; was never allocated at.
    mov rdi, [rbx + PyFrame.code]
    mov eax, [rdi + PyCodeObject.co_nlocalsplus]
    mov ecx, [rdi + PyCodeObject.co_stacksize]
    add rax, rcx
    shl rax, 3
    add rax, FRAME_HEADER_SIZE

    mov rdi, rbx            ; ptr
    mov rsi, rax            ; size
    call frame_pool_put

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC frame_free

;; ============================================================================
;; frame_pool_drain()
;; Free all entries in all pool freelists. Called at exit.
;; ============================================================================
DEF_FUNC frame_pool_drain
    push rbx
    push r12        ; alignment

    ; The datastack region, if one was ever made.  Nothing can still be using
    ; it: this runs at exit, after the last frame.
    mov rdi, [gs:ThreadState.frame_datastack_base]
    test rdi, rdi
    jz .no_datastack
    mov qword [gs:ThreadState.frame_datastack_base], 0
    mov qword [gs:ThreadState.frame_datastack_top], 0
    mov qword [gs:ThreadState.frame_datastack_end], 0
    call ap_free
.no_datastack:

    ; Drain pool class 0
    lea rbx, [rel frame_pool_free_0]
.drain_0:
    mov rdi, [rbx]
    test rdi, rdi
    jz .done_0
    mov rax, [rdi]          ; next = head->next
    mov [rbx], rax          ; head = next
    call ap_free
    jmp .drain_0
.done_0:
    mov dword [rbx + 8], 0

    ; Drain pool class 1
    lea rbx, [rel frame_pool_free_1]
.drain_1:
    mov rdi, [rbx]
    test rdi, rdi
    jz .done_1
    mov rax, [rdi]
    mov [rbx], rax
    call ap_free
    jmp .drain_1
.done_1:
    mov dword [rbx + 8], 0

    ; Drain pool class 2
    lea rbx, [rel frame_pool_free_2]
.drain_2:
    mov rdi, [rbx]
    test rdi, rdi
    jz .done_2
    mov rax, [rdi]
    mov [rbx], rax
    call ap_free
    jmp .drain_2
.done_2:
    mov dword [rbx + 8], 0

    ; Drain pool class 3
    lea rbx, [rel frame_pool_free_3]
.drain_3:
    mov rdi, [rbx]
    test rdi, rdi
    jz .done_3
    mov rax, [rdi]
    mov [rbx], rax
    call ap_free
    jmp .drain_3
.done_3:
    mov dword [rbx + 8], 0

    pop r12
    pop rbx
    leave
    ret
END_FUNC frame_pool_drain

;; ============================================================================
;; Pool data
;; ============================================================================
section .data

; The datastack: base and end bound the region, top is the bump pointer.
; Zero until the first inline call, which is what makes the handler's inline
; fast path fall through to frame_alloc_inline exactly once.  The three words
; (frame_datastack_base/_top/_end) lives in ThreadState (src/include/threadstate.inc).

; Freelists: each is (head_ptr, count)
align 8
global frame_pool_free_0
frame_pool_free_0:  dq 0        ; 256B class freelist head
frame_pool_count_0: dd 0         ; count
              dd 0         ; padding

frame_pool_free_1:  dq 0         ; 512B class freelist head
frame_pool_count_1: dd 0
              dd 0

frame_pool_free_2:  dq 0         ; 1024B class freelist head
frame_pool_count_2: dd 0
              dd 0

frame_pool_free_3:  dq 0         ; 2048B class freelist head
frame_pool_count_3: dd 0
              dd 0

section .text

;; ============================================================================
;; frame_fast_to_locals(PyFrame *f) -> PyDictObject*, owned, or NULL
;;
;; A function frame keeps its locals in the localsplus array, not in a mapping,
;; so PyFrame.locals is NULL for one -- and everything that wants a mapping
;; substituted globals instead.  locals() therefore returned the module dict,
;; and eval("lv + 1") inside a function raised NameError for a name that was
;; sitting in a slot two words away.
;;
;; This is CPython's PyFrame_FastToLocalsWithError: walk co_localsplusnames
;; against the slots, unwrapping the cells, and skip anything unbound.  It is a
;; snapshot -- writing to it does not write back, which is also what CPython
;; does outside a tracing hook.
;; ============================================================================
FTL_FRAME_P equ 8
FTL_DICT    equ 16
FTL_NAMES   equ 24
FTL_I       equ 32
FTL_N       equ 40
FTL_FRAME   equ 56        ; + 1 push = 64
global frame_fast_to_locals
extern dict_new
extern dict_set
extern cell_type
DEF_FUNC frame_fast_to_locals, FTL_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - FTL_FRAME_P], rdi

    call dict_new
    test rax, rax
    jz .ftl_fail
    mov [rbp - FTL_DICT], rax

    mov rax, [rbx + PyFrame.code]
    test rax, rax
    jz .ftl_done
    mov rax, [rax + PyCodeObject.co_localsplusnames]
    test rax, rax
    jz .ftl_done
    mov [rbp - FTL_NAMES], rax
    mov rcx, [rax + PyTupleObject.ob_size]
    mov [rbp - FTL_N], rcx
    ; The frame's own count is the authority on how many slots exist.
    mov ecx, [rbx + PyFrame.nlocalsplus]
    cmp rcx, [rbp - FTL_N]
    jae .ftl_have_n
    mov [rbp - FTL_N], rcx
.ftl_have_n:
    mov qword [rbp - FTL_I], 0

.ftl_loop:
    mov rax, [rbp - FTL_I]
    cmp rax, [rbp - FTL_N]
    jae .ftl_done

    lea rdx, [rbx + PyFrame.localsplus]     ; an inline array, not a pointer
    mov rdx, [rdx + rax*8]
    test rdx, rdx
    jz .ftl_next                        ; the slot was never bound

    ; A cell or free slot holds the cell, not the value.
    V_TEST_PTR rdx, rcx
    ja .ftl_have_value
    mov rcx, [rdx + PyObject.ob_type]
    lea r8, [rel cell_type]
    cmp rcx, r8
    jne .ftl_have_value
    mov rdx, [rdx + PyCellObject.ob_ref]
    test rdx, rdx
    jz .ftl_next                        ; an empty cell is an unbound name

.ftl_have_value:
    mov rax, [rbp - FTL_NAMES]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rcx, [rbp - FTL_I]
    mov rsi, [rax + rcx*8]              ; the name, as a Value
    test rsi, rsi
    jz .ftl_next
    mov rdi, [rbp - FTL_DICT]
    call dict_set
.ftl_next:
    inc qword [rbp - FTL_I]
    jmp .ftl_loop

.ftl_done:
    mov rax, [rbp - FTL_DICT]
    pop rbx
    leave
    ret
.ftl_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC frame_fast_to_locals
