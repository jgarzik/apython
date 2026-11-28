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

; Per-thread lazy path scratch layout (allocated via ts_get_path_scratch,
; freed on worker thread exit).
TS_PATH_IMPORT equ 0            ; 4096B: import_path_buf
TS_PATH_ISP    equ 4096         ; 4096B: import_source_path buffer
TS_PATH_IAP    equ 8192         ; 4096B: import_abs_path buffer
TS_PATH_PYCW   equ 12288        ; 4160B: pycw_path
TS_PATH_PYTMP  equ 16448        ; 4160B: pycw_tmp
TS_PATH_SIZE   equ 20608

TS_ERRBUF_SIZE equ 512
TS_NUMBUF_SIZE equ 32

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
    .eval_stack_floor:    resq 1  ; lowest safe rsp at Python frame entry
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
    .trash_buf:           resq 1  ;   libc-realloc'd PyObject** deferred stack
    .trash_len:           resq 1  ;   entries currently deferred
    .trash_cap:           resq 1  ;   allocated capacity of trash_buf
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
    ; ---- the unmarshal reader (src/marshal.asm) ----------------------------
    .marshal_buf:         resq 1  ; the bytes being read
    .marshal_pos:         resq 1  ;   the read position
    .marshal_len:         resq 1  ;   their length
    .marshal_refs:        resq 1  ; FLAG_REF table: PyObject*[]
    .marshal_ref_count:   resq 1  ;   entries in use
    .marshal_ref_cap:     resq 1  ;   capacity
    .marshal_soft:        resq 1  ; refuse softly rather than fatally
    .marshal_error:       resq 1  ; MARSHAL_ERR_*, the first refusal recorded
    .marshal_rsp_floor:   resq 1  ; how far down the machine stack it may nest
    .ts_next:             resq 1  ; the list of every thread's state, which
    .ts_prev:             resq 1  ;   tstate_list_head anchors (src/gil.asm)
    .ts_ident:            resq 1  ; pthread_self(), what get_ident() answers
    .ts_native_id:        resq 1  ; gettid()
    .ts_tid:              resd 1  ; compact monotonic owner ID (main=1; 0=immortal)
    .ts_state:            resd 1  ; TS_STATE_ATTACHED / DETACHED / PARKED
    .ts_dict_ver:         resq 1  ; thread-local dict version clock ((tid<<40)|seq)
    .ts_brc_hash_next:    resq 1  ; next ThreadState* in brc_buckets[tid & 63]
    .ts_brc_buf:          resq 1  ; libc-malloc'd PyObject** BRC merge queue
    .ts_brc_len:          resq 1  ; queued object count in ts_brc_buf
    .ts_brc_cap:          resq 1  ; capacity of ts_brc_buf
    .ts_dict:             resq 1  ; this thread's own dict, or NULL: where
                                  ;   _thread._local keeps its namespaces
    .import_path_override: resq 1 ; search path for one import, or NULL
    .comp_inherit_future: resq 1  ; PEP 563 inherited by the next compile
    .tb_seen_n:           resq 1  ; traceback printing: cycle guard count
    .tb_chain_suppress:   resq 1  ;   print no __cause__/__context__ chain
    .tb_output_sink:      resq 1  ;   redirected stream for a contextual report
    .tb_seen:             resq TB_SEEN_MAX  ; the exceptions already printed
    ; ---- asyncio: the running loop and its backend's state ----------------
    .eventloop:           resb TS_EVENTLOOP_SIZE
    .eventloop_root_exception: resq 1
    .asyncio_running_loop: resq 1 ; owned stdlib loop Value, or zero
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
    ; ---- module per-thread state (ctypes, ssl) ----------------------------
    .cx_errno:            resq 1  ; ctypes use_errno=True private errno
    .ssl_last_errno:      resq 1  ; _sslcore last engine errno
    .ssl_pw_len_plus1:    resq 1  ; _sslcore PEM password len+1 (0 = none)
    .ssl_pw_buf:          resq 1  ; _sslcore lazily malloc'd 1024B pw buffer
    ; ---- per-thread scratch & reentrant subsystem channels ----------------
    .ts_sre_cpcache:      resq 4  ; SRE_CpCache: buf, len, subject, borrows
    .ts_path_scratch:     resq 1  ; lazy malloc'd TS_PATH_SIZE bytes
    .ts_import_ns_portions: resq 1 ; PEP 420 portion list for current search
    .ts_pycw_dirlen:      resq 1  ; pyc_cache_path dirlen out
    .ts_pycw_len:         resq 1  ; pyc_cache_path len out
    .ts_mw_buf:           resq 1  ; marshal writer state
    .ts_mw_len:           resq 1
    .ts_mw_cap:           resq 1
    .ts_mw_error:         resq 1
    .ts_mw_memo:          resq 1
    .ts_mw_memo_len:      resq 1
    .ts_mw_memo_cap:      resq 1
    .ts_fs_printf_pending: resq 1 ; format.asm % vs format() channel
    .ts_io_readinto_msg:  resq 1  ; io.asm readinto vs readinto1 error msg
    .ts_io_badmode_char:  resq 1  ; io.asm invalid mode char
    .ts_gm_referents_out: resq 1  ; modules/gc.asm get_referents target list
    .ts_udn_active:       resq 1  ; unicodenorm active UdnTables*
    .ts_udn_pending_tables: resq 1 ; unicodenorm pending UdnTables*
    .ts_ev_locals_owned:  resq 1  ; compiler eval/exec locals ownership flag
    .ts_akb_nlocal_out:   resq 1  ; compiler assemble local count out
    .ts_lex_tc_own_line:  resq 1  ; compiler lexer type-comment own-line flag
    .ts_psu_what:         resq 1  ; compiler parser suite expected-what ptr
    .ts_psu_line:         resq 1  ; compiler parser suite line number
    .ts_errbuf:           resb TS_ERRBUF_SIZE ; primary error/format scratch
    .ts_errbuf2:          resb TS_ERRBUF_SIZE ; secondary scratch (rtn_buf)
    .ts_numbuf:           resb TS_NUMBUF_SIZE ; integer formatting scratch
    ; ---- per-thread pool allocator cache & object freelists ----------------
    .ts_sc_free:          resq 32 ; AP_NCLASSES per-thread free-list heads
    .ts_sc_free_count:    resd 32 ; per-class local free-list lengths
    .ts_sc_bump:          resq 32 ; per-class current pool bump ptr
    .ts_sc_bump_end:      resq 32 ; per-class current pool end ptr
    .ts_alloc_live:       resq 1  ; signed net live blocks for this thread
    .ts_frame_pool:       resq 8  ; 4 x (head:8, count:4, pad:4)
    .ts_int_freelist:     resq 1  ; PyIntObject freelist head
    .ts_int_freelist_cnt: resq 1  ; PyIntObject freelist count
    .ts_list_pool_head:   resq 1  ; PyListObject freelist head
    .ts_list_pool_count:  resd 1  ; PyListObject freelist count
    .ts_list_pool_pad:    resd 1
    .ts_slice_pool_head:  resq 1  ; PySliceObject freelist head
    .ts_slice_pool_count: resd 1  ; PySliceObject freelist count
    .ts_slice_pool_pad:   resd 1
    .ts_tuple_pool:       resq 6  ; 3 x (head:8, count:4, pad:4) for 1/2/3-tuples
    ; ---- byte flags, last -------------------------------------------------
    .throw_pending:       resb 1  ; gen_throw set current_exception
    .tb_suppress_frame:   resb 1  ; the next unwind adds no traceback entry
    .ts_gc_pending:       resb 1  ; deferred auto-GC requested by this thread
    .pad:                 resb 5
endstruc

%endif ; THREADSTATE_INC
