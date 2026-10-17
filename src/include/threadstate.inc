; threadstate.inc - the per-thread interpreter state, reached through gs
;
; Everything the interpreter keeps that belongs to ONE thread of execution
; rather than to the process: the exception in flight and the one being
; handled, the dispatch loop's published registers, the "pending" words one
; call site leaves for the next, the recursion counters, the frame data
; stack, the repr and traceback cycle guards, the trace hooks and the asyncio
; event loop with its backend.  What is shared under the GIL -- the
; allocator, freelists, the collector's generations, type and inline caches,
; interned strings, weakref and signal tables -- stays an ordinary global.
;
; The block is addressed through the gs segment base, which main sets with
; arch_prctl(ARCH_SET_GS) before anything reads a field (tstate_install in
; src/eval.asm).  glibc owns fs; gs is free on x86-64 Linux.  So a field is
;
;     mov rax, [gs:ThreadState.current_exception]
;
; which costs what `mov rax, [rel current_exception]` did.  A field whose
; ADDRESS is wanted is reached through ts_self, the block's own linear
; address:
;
;     mov rax, [gs:ThreadState.ts_self]
;     lea rax, [rax + ThreadState.tb_seen]
;
; and an array field can be indexed in place: [gs:ThreadState.tb_seen + rdx*8].
;
; Field order is layout: the first cache line is the words eval_frame and
; eval_return touch, and the byte flags go last so nothing after
; them is off 8-byte alignment.

%ifndef THREADSTATE_INC
%define THREADSTATE_INC

; tb_print_one's cycle guard: how many exceptions one report remembers.
TB_SEEN_MAX equ 64

; EventLoop (src/include/eventloop.inc) is embedded by size, so that every
; file need not include eventloop.inc; src/pyo/eventloop.asm asserts the two
; agree.
TS_EVENTLOOP_SIZE equ 40

struc ThreadState
    ; ---- line 0: the dispatch loop's words --------------------------------
    .current_exception:   resq 1  ; PyExceptionObject* or NULL -- IN FLIGHT
    .handled_exception:   resq 1  ; PyExceptionObject* or NULL -- BEING HANDLED
    .eval_base_rsp:       resq 1  ; machine rsp at eval dispatch level
    .eval_saved_r12:      resq 1  ; the running frame, set at frame entry; the
                                  ; IP and stack top DISPATCH publishes are in
                                  ; it (PyFrame.disp_ip / .disp_sp)
    .eval_co_names:       resq 1  ; &co_names.ob_item[0]
    .eval_co_consts:      resq 1  ; &co_consts.ob_item[0]
    .kw_names_pending:    resq 1  ; kw names tuple for the next CALL, or NULL
    .recursion_depth:     resq 1  ; Python call depth
    ; ---- line 1 -----------------------------------------------------------
    .c_recursion_depth:   resq 1  ; C-level container recursion depth
    .frame_datastack_top: resq 1  ; frame data stack: next free byte
    .frame_datastack_end: resq 1  ;   one past the current chunk
    .frame_datastack_base: resq 1 ;   the current chunk
    .attr_error_pending:  resq 1  ; AttributeError __getattr__ handed back
    .ts_self:             resq 1  ; this block's own linear address
    ; ---- the rest ---------------------------------------------------------
    .cfex_temp_pending:   resq 1  ; CALL_FUNCTION_EX temp buffer, or NULL
    .cfex_merged_pending: resq 1  ; CALL_FUNCTION_EX merged kwargs buffer
    .cfex_kwnames_pending: resq 1 ; CALL_FUNCTION_EX kw_names tuple
    .build_class_pending: resq 1  ; class under construction by __build_class__
    .class_kwnames_pending: resq 1  ; class keywords for __init_subclass__
    .class_kwvalues_pending: resq 1
    .class_metatype_pending: resq 1 ; the metatype type.__new__ was handed
    .instance_getattr_skip: resq 1  ; object object.__getattribute__ resolves
    .trash_nesting:       resq 1  ; dealloc nesting (trashcan)
    .trash_later:         resq 1  ;   objects deferred until it unwinds
    .repr_depth:          resq 1  ; container repr recursion guard: depth
    .repr_stack:          resq 1  ;   the entries, on the heap
    .repr_stack_cap:      resq 1  ;   their capacity
    .tracing_depth:       resq 1  ; non-zero inside a trace/profile callback
    .sys_tracefunc:       resq 1  ; sys.settrace function, Value or 0
    .sys_profilefunc:     resq 1  ; sys.setprofile function, Value or 0
    .systrace_any:        resq 1  ; either of the two is set
    .coroutine_origin_depth: resq 1
    .asyncgen_firstiter_hook: resq 1
    .asyncgen_finalizer_hook: resq 1
    .gc_collect_rsp:      resq 1  ; rsp of the collection THIS thread runs
    .import_path_override: resq 1 ; search path for one import, or NULL
    .comp_inherit_future: resq 1  ; PEP 563 inherited by the next compile
    .tb_seen_n:           resq 1  ; traceback printing: cycle guard count
    .tb_chain_suppress:   resq 1  ;   print no __cause__/__context__ chain
    .tb_seen:             resq TB_SEEN_MAX  ; the exceptions already printed
    ; ---- asyncio: the running loop and its backend's state ----------------
    .eventloop:           resb TS_EVENTLOOP_SIZE
    .eventloop_root_exception: resq 1
    .poll_fds:            resq 1  ; PollFd*
    .poll_fd_tasks:       resq 1  ; AsyncTask**
    .poll_cap:            resd 1
    .poll_nfds:           resd 1
    .timer_heap:          resq 1  ; TimerEntry*
    .timer_cap:           resd 1
    .timer_count:         resd 1
    .uring_fd:            resd 1
    .uring_pad:           resd 1
    .uring_sq_ring:       resq 1  ; mmap'd SQ ring base
    .uring_cq_ring:       resq 1  ; mmap'd CQ ring base
    .uring_sqes:          resq 1  ; mmap'd SQE array base
    .uring_sq_size:       resq 1
    .uring_cq_size:       resq 1
    .uring_sqe_size:      resq 1
    .uring_sq_mask:       resd 1
    .uring_cq_mask:       resd 1
    .uring_sq_head:       resq 1  ; ptr to sq head in shared memory
    .uring_sq_tail:       resq 1
    .uring_sq_array:      resq 1
    .uring_cq_head:       resq 1
    .uring_cq_tail:       resq 1
    .uring_cqes_base:     resq 1
    ; ---- byte flags, last -------------------------------------------------
    .throw_pending:       resb 1  ; gen_throw set current_exception
    .tb_suppress_frame:   resb 1  ; the next unwind adds no traceback entry
    .pad:                 resb 6
endstruc

%endif ; THREADSTATE_INC
