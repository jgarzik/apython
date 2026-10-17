; frameobj.asm - the frame object, which is a VIEW onto a live frame.
;
; A PyFrame is pooled and recycled: eval_frame takes one from a free list and
; puts it back on return, so a frame object cannot simply BE the frame the way
; CPython's is.  What it can do is point at one and know when to stop.
;
; PyFrame.frame_obj holds the view, borrowed; PyFrameObject.f_frame holds the
; frame, borrowed.  frameobj_for hands back the one that already exists rather
; than making a second, which is what lets sys._getframe() answer the same
; object twice and lets a trace function write f_trace onto a frame it will be
; handed again later -- bdb compares frames by IDENTITY across events, and a
; fresh copy per event makes every one of those comparisons false.
;
; frameobj_detach is CPython's take_ownership: frame_free calls it just before
; the pool reclaims the frame, and it copies out everything that will stop
; being readable -- the line, the instruction offset, the fast locals -- and
; drops both pointers.  After that the object is what this file used to hand
; back unconditionally, a snapshot, and every attribute still reads.
;
; A traceback entry's frame object (frameobj_from_code) is born detached: by
; the time anything looks at a traceback the frame is long gone.
;
; Between them that covers what the stdlib does with a frame -- warnings.warn
; reads f_globals to find the module a warning came from and walks f_back to
; skip its own frames -- and what a debugger does, which is everything else.

%include "macros.inc"
%include "object.inc"

ASM_INIT

extern ap_malloc
extern obj_decref
extern obj_dealloc
extern obj_incref
extern type_type
extern dict_new
extern frame_fast_to_locals
extern dict_set
extern str_from_cstr_heap
extern ap_strcmp
extern int_from_i64
extern none_singleton
extern bool_true
extern bool_false
extern raise_exception
extern exc_ValueError_type
extern exc_TypeError_type
extern exc_AttributeError_type
extern rbt_append_cstr
extern dict_type
extern code_addr2line
extern obj_as_index
extern str_type

;; FRAMEOBJ_DROP field -- release one owned field during dealloc.
%macro FRAMEOBJ_DROP 1
    mov rdi, [rbx + PyFrameObject.%1]
    test rdi, rdi
    jz %%skip
    mov qword [rbx + PyFrameObject.%1], 0
    call obj_decref
%%skip:
%endmacro

;; FRAMEOBJ_ATTR name, field -- one object-valued attribute of the snapshot.
%macro FRAMEOBJ_ATTR 2
    mov rdi, [rbp - FOG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, %1
    call ap_strcmp
    test eax, eax
    jnz %%next
    mov rax, [rbp - FOG_SELF]
    mov rax, [rax + PyFrameObject.%2]
    test rax, rax
    jz %%none
    INCREF rax
    jmp %%have
%%none:
    LOAD_NONE rax               ; which increfs; a second one here leaked it
%%have:
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
%%next:
%endmacro

;; FRAMEOBJ_FLAG name, field -- one of the two trace flags.  They are stored
;; as plain 0/1 words rather than as objects, so FRAMEOBJ_ATTR is wrong for
;; them: its INCREF would write through the number.
%macro FRAMEOBJ_FLAG 2
    mov rdi, [rbp - FOG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, %1
    call ap_strcmp
    test eax, eax
    jnz %%next
    mov rax, [rbp - FOG_SELF]
    cmp qword [rax + PyFrameObject.%2], 0
    je %%false
    lea rax, [rel bool_true]
    jmp %%have
%%false:
    lea rax, [rel bool_false]
%%have:
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
%%next:
%endmacro

section .text

;; ============================================================================
;; frameobj_new(rdi = a live PyFrame*) -> rax = the view, or 0
;;
;; The one reference it comes back with is the FRAME's, parked in
;; PyFrame.frame_obj; go through frameobj_for, which is what hands out a
;; reference of your own.  f_back is filled in by the caller, which walks the
;; chain outward.
;; ============================================================================
FON_FRAME_IN equ 8
FON_OBJ      equ 16
FON_FRAME    equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC_LOCAL frameobj_new, FON_FRAME
    push rbx
    mov [rbp - FON_FRAME_IN], rdi

    ; Through the collector, not ap_malloc.  A frame object can be part of a
    ; cycle it is the only route into: `f = sys._getframe()` puts the object
    ; in the very f_locals that frameobj_detach then copies the fast locals
    ; into, so the object refers to itself and its refcount never reaches
    ; zero.  The type has had tp_traverse and tp_clear all along and the
    ; collector never saw one, because nothing tracked it -- so every such
    ; frame, its locals dict, and every local in it leaked.
    mov edi, PyFrameObject_size
    lea rsi, [rel frame_object_type]
    extern gc_alloc
    call gc_alloc               ; sets ob_refcnt = 1 and ob_type
    test rax, rax
    jz .fon_fail
    mov rbx, rax
    mov qword [rbx + PyFrameObject.f_back], 0
    mov qword [rbx + PyFrameObject.f_trace], 0
    mov qword [rbx + PyFrameObject.f_trace_lines], 1
    mov qword [rbx + PyFrameObject.f_trace_opcodes], 0
    mov qword [rbx + PyFrameObject.ft_line], -1
    mov qword [rbx + PyFrameObject.ft_prev], -1
    ; The view is live from here: the frame keeps a borrowed pointer back, and
    ; frameobj_for finds it rather than building a second object.
    mov rdi, [rbp - FON_FRAME_IN]
    mov [rbx + PyFrameObject.f_frame], rdi
    mov [rdi + PyFrame.frame_obj], rbx

    mov rax, [rdi + PyFrame.code]
    mov [rbx + PyFrameObject.f_code], rax
    test rax, rax
    jz .fon_no_code
    INCREF rax
.fon_no_code:

    mov rdi, [rbp - FON_FRAME_IN]
    mov rax, [rdi + PyFrame.globals]
    test rax, rax
    jnz .fon_have_globals
    LOAD_NONE rax
.fon_have_globals:
    mov [rbx + PyFrameObject.f_globals], rax
    INCREF rax

    mov rdi, [rbp - FON_FRAME_IN]
    mov rax, [rdi + PyFrame.locals]
    test rax, rax
    jnz .fon_have_locals
    ; A frame using fast locals has no dict; CPython builds one on demand and
    ; this hands back the globals, which is what locals() does at module
    ; scope and the closest honest answer here.
    mov rax, [rbx + PyFrameObject.f_globals]
.fon_have_locals:
    mov [rbx + PyFrameObject.f_locals], rax
    INCREF rax

    mov rdi, [rbp - FON_FRAME_IN]
    mov rax, [rdi + PyFrame.builtins]
    test rax, rax
    jnz .fon_have_builtins
    LOAD_NONE rax
.fon_have_builtins:
    mov [rbx + PyFrameObject.f_builtins], rax
    INCREF rax

    mov rdi, rbx
    call frameobj_refresh_pos

    ; Tracked last: every field it traverses is filled by now, and gc_track
    ; can collect.
    mov rdi, rbx
    extern gc_track
    call gc_track

    mov rax, rbx
    pop rbx
    leave
    ret
.fon_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC frameobj_new

;; ============================================================================
;; frameobj_refresh_pos(rdi = a PyFrameObject*) -> nothing (f_lineno and
;;   f_lasti updated in place)
;;
;; Recompute f_lineno and f_lasti from where the live frame is NOW.  A
;; detached view keeps what it was left with; that is the whole point of
;; detaching.
;;
;; Every frame's position is its PyFrame.disp_ip, which DISPATCH writes on
;; each instruction: the innermost frame's is the instruction running, an
;; outer one's is the call it is waiting in.  A frame that has never run has
;; 0 there and is answered from instr_ptr.  Reading only instr_ptr answered 0
;; for every running frame.
;; ============================================================================
global frameobj_refresh_pos
DEF_FUNC frameobj_refresh_pos, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rcx, [rbx + PyFrameObject.f_frame]
    test rcx, rcx
    jz .frp_done                ; detached: what it holds is what it gets
    ; Nothing is written unless there is a real answer.  A frame that has run
    ; to completion has no IP left to read, and zeroing first meant that the
    ; refresh frameobj_detach makes on the way out threw away the last
    ; position the frame WAS at -- so f_lineno went to 0 exactly when the
    ; object stopped being able to recompute it.
    mov rdi, [rbx + PyFrameObject.f_code]
    test rdi, rdi
    jz .frp_done
    mov rax, [gs:ThreadState.eval_saved_r12]
    cmp rax, rcx
    jne .frp_not_current
    mov rsi, [rcx + PyFrame.disp_ip]   ; the running frame's last DISPATCH
    jmp .frp_have_ip
.frp_not_current:
    mov rsi, [rcx + PyFrame.disp_ip]
    test rsi, rsi
    jnz .frp_have_ip
    mov rsi, [rcx + PyFrame.instr_ptr]
.frp_have_ip:
    test rsi, rsi
    jz .frp_done
    lea rax, [rdi + PyCodeObject.co_code]
    sub rsi, rax                ; the byte offset
    js .frp_done
    ; f_lasti is a BYTE offset into co_code, as CPython's is; the line table
    ; is indexed in code units, so the two are kept apart here.
    mov [rbx + PyFrameObject.f_lasti], rsi
    shr rsi, 1                  ; code units are two bytes
    call code_addr2line
    mov [rbx + PyFrameObject.f_lineno], rax
.frp_done:
    pop rbx
    leave
    ret
END_FUNC frameobj_refresh_pos

;; ============================================================================
;; frameobj_for(rdi = a live PyFrame*) -> rax = an OWNED PyFrameObject*, or 0
;;
;; The frame's own view if it has one, a new one otherwise.  Identity is the
;; contract: `sys._getframe() is sys._getframe()` inside one call, and a
;; trace function handed the same frame twice sees the f_trace it set the
;; first time.  bdb rests on both.
;; ============================================================================
global frameobj_for
DEF_FUNC frameobj_for
    mov rax, [rdi + PyFrame.frame_obj]
    test rax, rax
    jz .ffor_new
    INCREF rax
    leave
    ret
.ffor_new:
    call frameobj_new
    test rax, rax
    jz .ffor_done
    ; frameobj_new's reference is the FRAME's, held until frame_free detaches;
    ; the caller gets one of its own.  The frame has to own it, or a caller
    ; that drops the last reference takes the view down while the frame is
    ; still running -- and a trace function that set f_trace on it would find
    ; the frame untraced on the very next event.
    INCREF rax
.ffor_done:
    leave
    ret
END_FUNC frameobj_for

;; ============================================================================
;; frameobj_detach(rdi = a PyFrame* about to be recycled) -> nothing (the
;;   frame's view, if it has one, is left detached and complete)
;;
;; CPython's take_ownership.  Copy out everything that stops being readable
;; when the pool takes the frame back -- the line, the offset, the fast
;; locals -- and drop the two borrowed pointers.  What is left is a snapshot,
;; and every attribute still reads.
;;
;; The object may well outlive this: a traceback holds one, and so does a
;; debugger that kept a reference.
;; ============================================================================
global frameobj_detach
DEF_FUNC frameobj_detach, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, [rdi + PyFrame.frame_obj]
    test rbx, rbx
    jz .fdt_done
    mov qword [rdi + PyFrame.frame_obj], 0

    ; The position, while the IP is still meaningful.
    mov rdi, rbx
    call frameobj_refresh_pos

    ; And f_back, while prev_frame is still readable.  A frame object that
    ; outlives its frame keeps a working chain outward -- which is what
    ; `sys._getframe()` returned from a function is for.
    cmp qword [rbx + PyFrameObject.f_back], 0
    jne .fdt_have_back
    mov rcx, [rbx + PyFrameObject.f_frame]
    test rcx, rcx
    jz .fdt_have_back
    mov rdi, [rcx + PyFrame.prev_frame]
    test rdi, rdi
    jz .fdt_have_back
    call frameobj_for
    test rax, rax
    jz .fdt_have_back
    mov [rbx + PyFrameObject.f_back], rax   ; takes over the reference
.fdt_have_back:

    ; The fast locals, while localsplus is still this frame's.  Through
    ; refresh_locals rather than frame_fast_to_locals, so that a key the
    ; caller put in the dict itself survives -- pdb writes __return__ there
    ; and reads it back after the frame is gone, which is exactly this
    ; moment.
    mov rdi, rbx
    call frameobj_refresh_locals

.fdt_drop:
    mov qword [rbx + PyFrameObject.f_frame], 0
    ; And the frame's own reference goes with the frame.  Anything else
    ; holding one keeps a working snapshot; nothing else holding one frees it
    ; here, which is where a view nobody kept should go.
    mov rdi, rbx
    call obj_decref
.fdt_done:
    pop rbx
    leave
    ret
END_FUNC frameobj_detach

;; ============================================================================
;; frameobj_refresh_locals(rdi = a PyFrameObject*) -> rax = the dict, borrowed,
;;   or 0
;;
;; A frame using a locals DICT already has the real thing in f_locals and
;; needs nothing.  A frame using fast locals does not have a dict at all, so
;; one is built from localsplus and then UPDATED in place on every later read
;; -- in place because pdb writes `__return__` and `__exception__` into it and
;; expects to read them back, which a fresh dict each time would lose.  That
;; is CPython's PyFrame_FastToLocalsWithError, and it leaves extra keys alone
;; for the same reason.
;; ============================================================================
FRL_SELF  equ 8
FRL_FRESH equ 16
FRL_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC frameobj_refresh_locals, FRL_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - FRL_SELF], rdi
    mov rcx, [rbx + PyFrameObject.f_frame]
    test rcx, rcx
    jz .frl_asis                ; detached: f_locals is already the answer
    cmp qword [rcx + PyFrame.locals], 0
    jne .frl_asis               ; a real locals mapping; the frame owns it

    mov rdi, rcx
    call frame_fast_to_locals
    test rax, rax
    jz .frl_asis
    mov [rbp - FRL_FRESH], rax

    ; Merge, rather than replace: whatever f_locals already is stays the
    ; object the caller saw last time.
    mov rbx, [rbp - FRL_SELF]
    mov rdi, [rbx + PyFrameObject.f_locals]
    test rdi, rdi
    jz .frl_adopt
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel dict_type]
    cmp rax, rcx
    jne .frl_adopt
    ; f_locals starts life pointing at f_globals for a fast-locals frame, and
    ; merging into the module dict would be a disaster.  Only a dict this
    ; function itself installed is merged into, which is the one whose
    ; identity is not f_globals.
    cmp rdi, [rbx + PyFrameObject.f_globals]
    je .frl_adopt
    mov rsi, [rbp - FRL_FRESH]
    call frameobj_merge_dict
    mov rdi, [rbp - FRL_FRESH]
    call obj_decref
    jmp .frl_asis

.frl_adopt:
    mov rdi, [rbx + PyFrameObject.f_locals]
    mov rax, [rbp - FRL_FRESH]
    mov [rbx + PyFrameObject.f_locals], rax
    test rdi, rdi
    jz .frl_asis
    call obj_decref

.frl_asis:
    mov rbx, [rbp - FRL_SELF]
    mov rax, [rbx + PyFrameObject.f_locals]
    pop rbx
    leave
    ret
END_FUNC frameobj_refresh_locals

;; ============================================================================
;; frameobj_merge_dict(rdi = destination dict, rsi = source dict) -> nothing
;;   (the destination is updated in place)
;;
;; Every key of the source, written over the destination.  Keys the
;; destination has and the source does not are LEFT -- that is the whole
;; reason this is not a fresh dict.
;; ============================================================================
FMD_DST equ 8
FMD_SRC equ 16
FMD_I   equ 24
FMD_FRAME equ 40            ; + 0 pushes = 40... padded below
DEF_FUNC_LOCAL frameobj_merge_dict, 48
    mov [rbp - FMD_DST], rdi
    mov [rbp - FMD_SRC], rsi
    mov qword [rbp - FMD_I], 0
.fmd_loop:
    mov rsi, [rbp - FMD_SRC]
    mov rax, [rbp - FMD_I]
    cmp rax, [rsi + PyDictObject.dk_nentries]
    jae .fmd_done
    imul rcx, rax, DICT_ENTRY_SIZE
    add rcx, [rsi + PyDictObject.entries]
    mov rsi, [rcx + DictEntry.key]
    test rsi, rsi
    jz .fmd_next                ; empty or a tombstone
    mov rdx, [rcx + DictEntry.value]
    mov rdi, [rbp - FMD_DST]
    call dict_set
.fmd_next:
    inc qword [rbp - FMD_I]
    jmp .fmd_loop
.fmd_done:
    leave
    ret
END_FUNC frameobj_merge_dict

;; ============================================================================
;; frameobj_setattr(rdi = self, rsi = name str, rdx = value Value, or 0 to
;;   delete) -> eax = 0 on success, -1 with an exception pending
;;
;; f_trace, f_trace_lines and f_trace_opcodes are what a debugger writes;
;; bdb sets f_trace on a caller's frame during set_trace and deletes it again
;; in set_continue, so the delete form is not optional.
;; ============================================================================
FSA_SELF  equ 8
FSA_NAME  equ 16
FSA_VAL   equ 24
FSA_FRAME equ 40            ; + 0 pushes = 40; padded to 48 below
DEF_FUNC frameobj_setattr, 48
    mov [rbp - FSA_SELF], rdi
    mov [rbp - FSA_NAME], rsi
    mov [rbp - FSA_VAL], rdx

    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "f_trace"
    call ap_strcmp
    test eax, eax
    jz .fsa_trace

    mov rdi, [rbp - FSA_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "f_trace_lines"
    call ap_strcmp
    test eax, eax
    jz .fsa_lines

    mov rdi, [rbp - FSA_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "f_trace_opcodes"
    call ap_strcmp
    test eax, eax
    jz .fsa_opcodes

    mov rdi, [rbp - FSA_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "f_lineno"
    call ap_strcmp
    test eax, eax
    jz .fsa_lineno

    ; CPython names the attribute and the type:
    ;   attribute 'f_code' of 'frame' objects is not writable
    lea rdi, [rel fsa_buf]
    lea rsi, [rel fsa_ro_open]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - FSA_NAME]
    lea rsi, [rsi + PyStrObject.data]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel fsa_ro_tail]
    call rbt_append_cstr
    lea rdi, [rel exc_AttributeError_type]
    lea rsi, [rel fsa_buf]
    leave
    jmp raise_exception

.fsa_trace:
    ; None is a delete, as it is in CPython: bdb assigns None to turn local
    ; tracing off as readily as it deletes the attribute.
    mov rax, [rbp - FSA_VAL]
    test rax, rax
    jz .fsa_trace_clear
    LOAD_NONE rcx
    cmp rax, rcx
    je .fsa_trace_clear
    INCREF_V rax, rcx
.fsa_trace_clear:
    mov rcx, [rbp - FSA_SELF]
    mov rdi, [rcx + PyFrameObject.f_trace]
    mov rax, [rbp - FSA_VAL]
    test rax, rax
    jz .fsa_trace_store
    LOAD_NONE rdx
    cmp rax, rdx
    jne .fsa_trace_store
    xor eax, eax
.fsa_trace_store:
    mov [rcx + PyFrameObject.f_trace], rax
    test rdi, rdi
    jz .fsa_ok
    call obj_decref
    jmp .fsa_ok

.fsa_lines:
    mov rdi, [rbp - FSA_VAL]
    call frameobj_flag_value
    mov rcx, [rbp - FSA_SELF]
    mov [rcx + PyFrameObject.f_trace_lines], rax
    jmp .fsa_ok

.fsa_opcodes:
    mov rdi, [rbp - FSA_VAL]
    call frameobj_flag_value
    mov rcx, [rbp - FSA_SELF]
    mov [rcx + PyFrameObject.f_trace_opcodes], rax
    jmp .fsa_ok

.fsa_lineno:
    ; pdb's `jump`.  Moving the instruction pointer to the start of another
    ; line means re-deriving the block stack for the destination, which this
    ; interpreter does not have the machinery to do; refusing is CPython's
    ; own answer for a jump it cannot make.
    RAISE exc_ValueError_type, "f_lineno can only be set in a trace function"

.fsa_ok:
    xor eax, eax
    leave
    ret
END_FUNC frameobj_setattr

section .rodata
fsa_ro_open: db "attribute '", 0
fsa_ro_tail: db "' of 'frame' objects is not writable", 0
section .bss
fsa_buf: resb 128
section .text

;; ============================================================================
;; frameobj_flag_value(rdi = a Value, or 0) -> rax = 0 or 1
;;
;; The truth of one of the two trace flags.  A delete, and an error from
;; __bool__, both read as false: the flags are advisory and a debugger that
;; sets one to a broken object should not take the frame down with it.
;; ============================================================================
DEF_FUNC_LOCAL frameobj_flag_value
    test rdi, rdi
    jz .ffv_false               ; a delete reads as false
    extern obj_is_true
    call obj_is_true
    test eax, eax
    jle .ffv_false              ; an error reads as false; the flag is advisory
    mov eax, 1
    leave
    ret
.ffv_false:
    xor eax, eax
    leave
    ret
END_FUNC frameobj_flag_value

;; ============================================================================
;; frameobj_traverse(rdi = self) -> nothing (each owned field visited)
;; frameobj_clear(rdi = self) -> nothing (the cycle-closing fields released)
;;
;; f_trace closes a cycle
;;
;; A debugger's trace function is a bound method of an object that holds the
;; frame, so frame -> f_trace -> Bdb -> botframe -> frame is the ordinary
;; shape rather than a corner case.  Without these the cycle leaks for the
;; life of the process.
;; ============================================================================
DEF_FUNC frameobj_traverse, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyFrameObject.f_back]
    VISIT_PTR rdi
    mov rdi, [rbx + PyFrameObject.f_globals]
    VISIT_PTR rdi
    mov rdi, [rbx + PyFrameObject.f_locals]
    VISIT_PTR rdi
    mov rdi, [rbx + PyFrameObject.f_trace]
    VISIT_PTR rdi
    pop rbx
    leave
    ret
END_FUNC frameobj_traverse

;; ============================================================================
;; frameobj_clear(rdi = self) -> nothing (the cycle-closing fields released)
;;
;; f_trace and f_back are the two that can point back at this object; f_code,
;; f_globals and f_builtins cannot close a cycle through a frame and are left
;; for the dealloc.
;; ============================================================================
DEF_FUNC frameobj_clear, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    FRAMEOBJ_DROP f_trace
    FRAMEOBJ_DROP f_back
    pop rbx
    leave
    ret
END_FUNC frameobj_clear

;; ============================================================================
;; frameobj_from_code(rdi = a code object or 0, rsi = the line, rdx = lasti)
;;   -> rax = a snapshot, or 0
;;
;; What a traceback entry can offer for tb_frame.  A traceback records the
;; code and the line and NOT the frame -- by the time anything looks, the
;; frame has been recycled -- so the globals are an empty dict rather than a
;; lie about which module it was.  CPython's traceback.py reads f_code and
;; f_globals; the first is right, and the second only costs it the source
;; line it would have looked up.
;; ============================================================================
FFC_CODE  equ 8
FFC_LINE  equ 16
FFC_LASTI equ 24
FFC_OBJ   equ 32
FFC_FRAME equ 48            ; + 0 pushes = 48
DEF_FUNC frameobj_from_code, FFC_FRAME
    mov [rbp - FFC_CODE], rdi
    mov [rbp - FFC_LINE], rsi
    mov [rbp - FFC_LASTI], rdx

    ; Through the collector, as frameobj_new is: the type carries
    ; TYPE_FLAG_HAVE_GC, so frameobj_dealloc frees at obj - GC_HEAD_SIZE and an
    ; ap_malloc'd one would hand the allocator a pointer sixteen bytes short of
    ; what it gave out.
    mov edi, PyFrameObject_size
    lea rsi, [rel frame_object_type]
    call gc_alloc               ; sets ob_refcnt = 1 and ob_type
    test rax, rax
    jz .ffc_fail
    mov [rbp - FFC_OBJ], rax
    mov qword [rax + PyFrameObject.f_back], 0
    ; Detached from birth: a traceback is looked at long after its frame went
    ; back on the pool.
    mov qword [rax + PyFrameObject.f_frame], 0
    mov qword [rax + PyFrameObject.f_trace], 0
    mov qword [rax + PyFrameObject.f_trace_lines], 1
    mov qword [rax + PyFrameObject.f_trace_opcodes], 0
    mov qword [rax + PyFrameObject.ft_line], -1
    mov qword [rax + PyFrameObject.ft_prev], -1
    mov rcx, [rbp - FFC_CODE]
    mov [rax + PyFrameObject.f_code], rcx
    test rcx, rcx
    jz .ffc_no_code
    INCREF rcx
.ffc_no_code:
    mov rcx, [rbp - FFC_LINE]
    mov [rax + PyFrameObject.f_lineno], rcx
    ; The caller passes code units, as the traceback stores them; the
    ; attribute is a byte offset, as CPython's is.
    mov rcx, [rbp - FFC_LASTI]
    add rcx, rcx
    mov [rax + PyFrameObject.f_lasti], rcx

    call dict_new
    test rax, rax
    jz .ffc_drop
    mov rcx, [rbp - FFC_OBJ]
    mov [rcx + PyFrameObject.f_globals], rax
    INCREF rax
    mov [rcx + PyFrameObject.f_locals], rax
    LOAD_NONE rax
    INCREF rax
    mov [rcx + PyFrameObject.f_builtins], rax
    ; Tracked once every field it traverses is filled.  A traceback's frame
    ; can be part of a cycle like any other -- the traceback holds the frame
    ; and the exception holds the traceback.
    mov rdi, rcx
    call gc_track
    mov rax, [rbp - FFC_OBJ]
    leave
    ret
.ffc_drop:
    mov rdi, [rbp - FFC_OBJ]
    call gc_dealloc
.ffc_fail:
    xor eax, eax
    leave
    ret
END_FUNC frameobj_from_code

;; ============================================================================
;; sys._getframe([depth]) -> a snapshot of the frame `depth` levels up
;;
;; Depth 0 is the caller's frame: a builtin has no Python frame of its own for
;; it to count.  The whole chain from there outward is snapshotted, because
;; f_back has to keep working after the live frames are gone.
;; ============================================================================

SGF_DEPTH equ 8
SGF_HEAD  equ 16
SGF_PREV  equ 24
SGF_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC sys_getframe_func, SGF_FRAME
    push rbx
    mov qword [rbp - SGF_DEPTH], 0
    test rsi, rsi
    jz .sgf_have_depth
    mov rdi, [rdi]
    V_UNPACK rdi, rdx
    call obj_as_index
    ; CPython treats a negative depth as zero rather than refusing it.
    test rax, rax
    js .sgf_have_depth
    mov [rbp - SGF_DEPTH], rax
.sgf_have_depth:

    mov rbx, [gs:ThreadState.eval_saved_r12]
    test rbx, rbx
    jz .sgf_too_deep
.sgf_descend:
    cmp qword [rbp - SGF_DEPTH], 0
    je .sgf_at_frame
    mov rbx, [rbx + PyFrame.prev_frame]
    test rbx, rbx
    jz .sgf_too_deep
    dec qword [rbp - SGF_DEPTH]
    jmp .sgf_descend

.sgf_at_frame:
    ; One view; f_back walks outward from it on demand.
    mov rdi, rbx
    call frameobj_for
    test rax, rax
    jz .sgf_null
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.sgf_null:
    xor eax, eax
    pop rbx
    leave
    ret

.sgf_too_deep:
    pop rbx
    RAISE exc_ValueError_type, "call stack is not deep enough"
END_FUNC sys_getframe_func

;; ============================================================================
;; sys._current_frames() -> {thread ident: frame}
;;
;; One thread, so one entry: the frame the caller is running in, under the
;; ident lib/_thread.py answers for it.  CPython's is how a monitor or a
;; profiler takes a stack sample of every thread, and threading, faulthandler
;; and test.support all reach for it.
;;
;; The frame is the same snapshot sys._getframe(0) hands out, because f_back
;; has to keep working after the live frames are gone.
;; ============================================================================
SCF_DICT  equ 8
SCF_VIEW  equ 16
SCF_KEY   equ 24
SCF_FRAME equ 32            ; + 1 push = 40... one word more to land right
DEF_FUNC sys_current_frames_func, 40    ; + 1 push = 48, 16-aligned
    push rbx
    mov qword [rbp - SCF_VIEW], 0
    mov qword [rbp - SCF_KEY], 0
    extern dict_new
    call dict_new
    test rax, rax
    jz .scf_fail
    mov [rbp - SCF_DICT], rax

    mov rbx, [gs:ThreadState.eval_saved_r12]
    test rbx, rbx
    jz .scf_done                ; no Python frame: an empty mapping

    mov rdi, rbx
    call frameobj_for
    test rax, rax
    jz .scf_drop
    mov [rbp - SCF_VIEW], rax

    ; The ident lib/_thread.py hands out for the only thread there is.
    mov edi, 1
    extern int_from_i64
    call int_from_i64
    V_PACK rax, rdx             ; an immediate int is its own Value
    mov [rbp - SCF_KEY], rax

    mov rdi, [rbp - SCF_DICT]
    mov rsi, [rbp - SCF_KEY]
    mov rdx, [rbp - SCF_VIEW]
    extern dict_set
    call dict_set               ; takes its own references

    mov rax, [rbp - SCF_KEY]
    DECREF_V rax, rcx
    mov rdi, [rbp - SCF_VIEW]
    call obj_decref
.scf_done:
    mov rax, [rbp - SCF_DICT]
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.scf_drop:
    mov rdi, [rbp - SCF_DICT]
    call obj_decref
.scf_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
END_FUNC sys_current_frames_func

;; ============================================================================
;; sys._getframemodulename([depth]) -> the __name__ of that frame's globals
;;
;; What warnings._deprecated actually wants; CPython added it in 3.12 for
;; exactly this, so the common case need not build a frame object at all.
;; ============================================================================
SGM_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC sys_getframemodulename_func, SGM_FRAME
    push rbx
    xor ecx, ecx
    test rsi, rsi
    jz .sgm_have_depth
    push rcx
    mov rdi, [rdi]
    V_UNPACK rdi, rdx
    call obj_as_index
    pop rcx
    mov rcx, rax
.sgm_have_depth:
    mov rbx, [gs:ThreadState.eval_saved_r12]
.sgm_descend:
    test rbx, rbx
    jz .sgm_none
    test rcx, rcx
    jz .sgm_at_frame
    mov rbx, [rbx + PyFrame.prev_frame]
    dec rcx
    jmp .sgm_descend
.sgm_at_frame:
    mov rdi, [rbx + PyFrame.globals]
    test rdi, rdi
    jz .sgm_none
    CSTRING rsi, "__name__"
    push rdi
    sub rsp, 8
    mov rdi, rsi
    call str_from_cstr_heap
    add rsp, 8
    pop rdi
    push rax
    sub rsp, 8
    mov rsi, rax
    extern dict_get
    call dict_get
    add rsp, 8
    pop rcx
    push rax
    sub rsp, 8
    mov rdi, rcx
    call obj_decref             ; the key
    add rsp, 8
    pop rax
    test rax, rax
    jz .sgm_none
    INCREF_V rax, rdx
    pop rbx
    leave
    ret
.sgm_none:
    LOAD_NONE rax
    INCREF rax
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
END_FUNC sys_getframemodulename_func

;; ============================================================================
;; The frame snapshot's own behaviour.
;; ============================================================================
DEF_FUNC frameobj_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    ; The frame's back-pointer is borrowed and must not outlive this object.
    ; Miss this and the PyFrame hands the next frameobj_for a freed pointer.
    mov rcx, [rbx + PyFrameObject.f_frame]
    test rcx, rcx
    jz .fod_detached
    mov qword [rbx + PyFrameObject.f_frame], 0
    mov qword [rcx + PyFrame.frame_obj], 0
.fod_detached:
    FRAMEOBJ_DROP f_back
    FRAMEOBJ_DROP f_code
    FRAMEOBJ_DROP f_globals
    FRAMEOBJ_DROP f_locals
    FRAMEOBJ_DROP f_builtins
    FRAMEOBJ_DROP f_trace
    ; gc_dealloc, not ap_free: the object carries a PyGC_Head and may still be
    ; in a generation list.
    mov rdi, rbx
    extern gc_dealloc
    call gc_dealloc
    pop rbx
    leave
    ret
END_FUNC frameobj_dealloc

FOG_SELF  equ 8
FOG_NAME  equ 16
FOG_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC frameobj_getattr, FOG_FRAME
    mov [rbp - FOG_SELF], rdi
    mov [rbp - FOG_NAME], rsi
    lea rdi, [rsi + PyStrObject.data]

    mov rdi, [rbp - FOG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "f_back"
    call ap_strcmp
    test eax, eax
    jz .fog_back

    FRAMEOBJ_ATTR "f_code",     f_code
    FRAMEOBJ_ATTR "f_globals",  f_globals
    FRAMEOBJ_ATTR "f_builtins", f_builtins
    FRAMEOBJ_ATTR "f_trace",    f_trace

    FRAMEOBJ_FLAG "f_trace_lines",   f_trace_lines
    FRAMEOBJ_FLAG "f_trace_opcodes", f_trace_opcodes

    ; f_locals is not a plain field on a LIVE view: the frame's fast locals
    ; are the truth and the dict is a copy of them, so it is rebuilt on each
    ; read.  pdb writes __return__ into it and reads it back, so the dict has
    ; to be the same object each time -- the refresh updates in place rather
    ; than allocating a second one.
    mov rdi, [rbp - FOG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "f_locals"
    call ap_strcmp
    test eax, eax
    jz .fog_locals

    lea rdi, [rsi + PyStrObject.data]
    mov rdi, [rbp - FOG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "f_lineno"
    call ap_strcmp
    test eax, eax
    jz .fog_lineno
    mov rdi, [rbp - FOG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "f_lasti"
    call ap_strcmp
    test eax, eax
    jz .fog_lasti

    ; Unknown: NULL, so the caller decides -- the contract every other
    ; tp_getattr here keeps.
    RET_NULL
    leave
    V_PACK rax, rdx
    ret

.fog_back:
    ; Linked on demand.  Building the chain at construction would walk the
    ; whole stack every time a hook asked for one frame, and a debugger asks
    ; for one per event; leaving it unlinked was worse -- bdb sets
    ; `self.botframe = frame.f_back` on the first call event and then compares
    ; every later frame against it, so a None there made it re-arm on every
    ; call and never report one.
    mov rax, [rbp - FOG_SELF]
    mov rcx, [rax + PyFrameObject.f_back]
    test rcx, rcx
    jnz .fog_back_have
    mov rcx, [rax + PyFrameObject.f_frame]
    test rcx, rcx
    jz .fog_back_none           ; detached: what it was left with is all there is
    mov rdi, [rcx + PyFrame.prev_frame]
    test rdi, rdi
    jz .fog_back_none
    call frameobj_for
    test rax, rax
    jz .fog_back_none
    mov rcx, [rbp - FOG_SELF]
    mov [rcx + PyFrameObject.f_back], rax   ; takes over the reference
    mov rcx, rax
.fog_back_have:
    mov rax, rcx
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.fog_back_none:
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.fog_locals:
    mov rdi, [rbp - FOG_SELF]
    call frameobj_refresh_locals
    test rax, rax
    jz .fog_locals_none
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.fog_locals_none:
    LOAD_NONE rax
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.fog_lineno:
    mov rdi, [rbp - FOG_SELF]
    call frameobj_refresh_pos
    mov rax, [rbp - FOG_SELF]
    mov rdi, [rax + PyFrameObject.f_lineno]
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
.fog_lasti:
    mov rdi, [rbp - FOG_SELF]
    call frameobj_refresh_pos
    mov rax, [rbp - FOG_SELF]
    mov rdi, [rax + PyFrameObject.f_lasti]
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
END_FUNC frameobj_getattr

;; ============================================================================
;; frameobj_method_clear(rdi = args, rsi = nargs) -> rax = Value, None
;;
;; `frame.clear()` drops what the frame holds so that a reference cycle through
;; a traceback can be broken.  traceback.clear_frames() calls it on every entry
;; of a traceback, and unittest's assertRaises calls THAT in its __exit__ --
;; which is why its absence stopped nearly every test CPython ships.
;;
;; An EXECUTING frame raises RuntimeError, which is what CPython does; a
;; suspended generator's frame is CLOSED, which is also what CPython does --
;; the finally blocks run, gi_frame becomes None, and a later next() raises
;; StopIteration.  A detached snapshot, which is what a traceback entry holds
;; by the time anyone looks at it, is simply cleared.
;;
;; This used to refuse everything still attached to a live PyFrame, and
;; nothing noticed because clear_frames is written as
;;
;;     try: tb.tb_frame.clear()
;;     except RuntimeError: pass
;;
;; so the suspended-generator half was silently skipped.
;;
;; What a detached frame owns and this releases: f_locals, the snapshot
;; frameobj_detach copied out of localsplus, and f_trace.  f_back, f_code,
;; f_globals and f_builtins are NOT released: CPython keeps them, and a
;; traceback that has been cleared still renders its own lines.
;; ============================================================================
FMC_SELF  equ 8
FMC_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC frameobj_method_clear, FMC_FRAME
    cmp rsi, 1
    jne .fmc_arity
    mov rax, [rdi]
    mov [rbp - FMC_SELF], rax

    ; A frame still attached to a live PyFrame is usually executing, and
    ; clearing one is refused.  A SUSPENDED GENERATOR is the exception:
    ; CPython closes it -- the finally blocks run, gi_frame becomes None, and
    ; a later next() raises StopIteration.  It was refused here along with
    ; everything else, and traceback.clear_frames() hid that by catching
    ; RuntimeError.
    ;
    ; gen_owner says whose frame this is, and gi_running tells a suspended
    ; generator from one that is actually on the interpreter's chain -- which
    ; is the question CPython answers with FRAME_OWNED_BY_GENERATOR plus the
    ; frame's state, and it needs no walk of the live frames.
    mov rcx, [rax + PyFrameObject.f_frame]
    test rcx, rcx
    jz .fmc_detached
    mov rcx, [rcx + PyFrame.gen_owner]
    test rcx, rcx
    jz .fmc_executing
    cmp qword [rcx + PyGenObject.gi_running], 0
    jne .fmc_executing
    ; Close it, which is the whole of what CPython's clear() does for one.
    mov rdi, rcx
    extern gen_close
    call gen_close
    mov rax, [rbp - FMC_SELF]
    mov qword [rax + PyFrameObject.f_frame], 0
.fmc_detached:

    mov rdi, [rax + PyFrameObject.f_locals]
    test rdi, rdi
    jz .fmc_no_locals
    ; CPython leaves f_locals an EMPTY DICT, not None: what clear() drops is
    ; the fast locals, and the mapping over them survives.  Emptying it in
    ; place releases exactly the references the cycle runs through, and keeps
    ; the object for anything already holding it -- releasing the dict instead
    ; made `frame.f_locals` read None afterwards, where CPython reads {}.
    sub rsp, 16
    mov [rsp], rdi
    mov rdi, rsp
    mov esi, 1
    extern dict_method_clear
    call dict_method_clear
    add rsp, 16
.fmc_no_locals:
    mov rax, [rbp - FMC_SELF]
    mov rdi, [rax + PyFrameObject.f_trace]
    test rdi, rdi
    jz .fmc_done
    mov qword [rax + PyFrameObject.f_trace], 0
    call obj_decref
.fmc_done:
    LOAD_NONE rax
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.fmc_executing:
    extern exc_RuntimeError_type
    RAISE exc_RuntimeError_type, "cannot clear an executing frame"
.fmc_arity:
    dec rsi                     ; the count CPython reports excludes self
    CSTRING rdi, "clear() takes no arguments ("
    CSTRING rdx, " given)"
    extern raise_type_error_counted
    jmp raise_type_error_counted
END_FUNC frameobj_method_clear

DEF_FUNC frameobj_repr
    CSTRING rdi, "<frame object>"
    extern str_from_cstr
    call str_from_cstr
    leave
    ret
END_FUNC frameobj_repr

section .data
align 8
global frame_object_type
frame_object_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq fo_name                  ; tp_name
    dq PyFrameObject_size       ; tp_basicsize
    dq frameobj_dealloc         ; tp_dealloc
    dq frameobj_repr            ; tp_repr
    dq frameobj_repr            ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq frameobj_getattr         ; tp_getattr
    dq frameobj_setattr         ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC        ; tp_flags
    dq 0                        ; tp_bases
    dq frameobj_traverse        ; tp_traverse
    dq frameobj_clear           ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

section .rodata
fo_name: db "frame", 0
