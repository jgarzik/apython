; generator.asm - Generator, coroutine, and async generator object implementation
; Phase 10: suspendable frames via RETURN_GENERATOR / YIELD_VALUE
; Phase 11: async/await — coro_type, async_gen_type, gen_throw

%include "macros.inc"
%include "object.inc"
%include "types.inc"
%include "frame.inc"
%include "errcodes.inc"

extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern ap_free
extern obj_decref
extern obj_incref
extern eval_frame
extern frame_free
extern none_singleton
extern str_from_cstr
extern obj_dealloc
extern type_type
extern gen_traverse
extern gen_clear
extern ap_strcmp
extern raise_exception
extern raise_exception_obj
extern exc_new
extern exc_TypeError_type
extern exc_StopIteration_type
extern exc_StopAsyncIteration_type
extern method_new
extern builtin_func_new
extern current_exception
extern throw_pending

;; ============================================================================
;; gen_new(PyFrame *frame) -> PyGenObject*
;; Create a new generator object that owns the given frame.
;; rdi = frame (ownership transfers to generator)
;; ============================================================================
DEF_FUNC gen_new
    push rbx
    push r12

    mov rbx, rdi               ; rbx = frame

    mov edi, PyGenObject_size
    lea rsi, [rel gen_type]
    call gc_alloc
    mov r12, rax               ; r12 = gen object (ob_refcnt=1, ob_type set)

    mov [r12 + PyGenObject.gi_frame], rbx
    mov qword [r12 + PyGenObject.gi_running], 0

    ; Copy code from frame and INCREF it
    mov rdx, [rbx + PyFrame.code]
    mov [r12 + PyGenObject.gi_code], rdx
    mov rdi, rdx
    call obj_incref

    ; gi_name = NULL (not critical)
    mov qword [r12 + PyGenObject.gi_name], 0

    ; gi_return_value = NULL (no return value yet)
    mov qword [r12 + PyGenObject.gi_return_value], 0
    mov qword [r12 + PyGenObject.gi_return_tag], 0

    mov rdi, r12
    call gc_track

    mov rax, r12               ; return gen object
    mov edx, TAG_PTR             ; return tag
    pop r12
    pop rbx
    leave
    ret
END_FUNC gen_new

;; ============================================================================
;; coro_new(PyFrame *frame) -> PyGenObject* (coroutine)
;; Same as gen_new but ob_type = coro_type.
;; rdi = frame (ownership transfers to coroutine)
;; ============================================================================
DEF_FUNC coro_new
    push rbx
    push r12

    mov rbx, rdi               ; rbx = frame

    mov edi, PyGenObject_size
    lea rsi, [rel coro_type]
    call gc_alloc
    mov r12, rax               ; r12 = coro object (ob_refcnt=1, ob_type set)

    mov [r12 + PyGenObject.gi_frame], rbx
    mov qword [r12 + PyGenObject.gi_running], 0

    ; Copy code from frame and INCREF it
    mov rdx, [rbx + PyFrame.code]
    mov [r12 + PyGenObject.gi_code], rdx
    mov rdi, rdx
    call obj_incref

    mov qword [r12 + PyGenObject.gi_name], 0
    mov qword [r12 + PyGenObject.gi_return_value], 0
    mov qword [r12 + PyGenObject.gi_return_tag], 0

    mov rdi, r12
    call gc_track

    mov rax, r12               ; return coro object
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC coro_new

;; ============================================================================
;; async_gen_new(PyFrame *frame) -> PyGenObject* (async generator)
;; Same as gen_new but ob_type = async_gen_type.
;; rdi = frame (ownership transfers to async generator)
;; ============================================================================
DEF_FUNC async_gen_new
    push rbx
    push r12

    mov rbx, rdi               ; rbx = frame

    mov edi, PyGenObject_size
    lea rsi, [rel async_gen_type]
    call gc_alloc
    mov r12, rax               ; ob_refcnt=1, ob_type set

    mov [r12 + PyGenObject.gi_frame], rbx
    mov qword [r12 + PyGenObject.gi_running], 0

    mov rdx, [rbx + PyFrame.code]
    mov [r12 + PyGenObject.gi_code], rdx
    mov rdi, rdx
    call obj_incref

    mov qword [r12 + PyGenObject.gi_name], 0
    mov qword [r12 + PyGenObject.gi_return_value], 0
    mov qword [r12 + PyGenObject.gi_return_tag], 0

    mov rdi, r12
    call gc_track

    mov rax, r12
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC async_gen_new

;; ============================================================================
;; gen_iternext(PyGenObject *self) -> PyObject* or NULL
;; Resume the generator. Push None as sent value, call eval_frame.
;; Returns yielded value, or NULL if generator is exhausted.
;; rdi = generator
;; ============================================================================
DEF_FUNC gen_iternext
    push rbx
    push r12

    mov rbx, rdi               ; rbx = generator

    ; Check if generator is exhausted
    mov r12, [rbx + PyGenObject.gi_frame]
    test r12, r12
    jz .exhausted

    ; Check if already running (recursive call)
    cmp qword [rbx + PyGenObject.gi_running], 1
    je .running_error

    ; Mark as running
    mov qword [rbx + PyGenObject.gi_running], 1

    ; Push None as the "sent" value onto the frame's value stack
    FRAME_PUSH_NONE r12, rax

    ; Resume execution
    mov rdi, r12
    call eval_frame
    ; rax = yielded/returned value payload, rdx = tag

    mov r12, rax               ; save return value payload
    push rdx                   ; save return value tag

    ; Mark as not running
    mov qword [rbx + PyGenObject.gi_running], 0

    ; Check if generator returned (vs yielded)
    ; If frame->instr_ptr == 0, generator returned (exhausted)
    mov rdi, [rbx + PyGenObject.gi_frame]
    cmp qword [rdi + PyFrame.instr_ptr], 0
    jne .yielded

    ; Generator is exhausted: free frame, set gi_frame = NULL
    call frame_free
    mov qword [rbx + PyGenObject.gi_frame], 0

    ; Store return value in gi_return_value (for StopIteration.value)
    mov [rbx + PyGenObject.gi_return_value], r12
    pop rax                    ; rax = return value tag
    mov [rbx + PyGenObject.gi_return_tag], rax

    ; Return NULL to signal StopIteration
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.yielded:
    ; Return the yielded value
    mov rax, r12
    pop rdx                    ; restore result tag
    pop r12
    pop rbx
    leave
    ret

.exhausted:
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.running_error:
    RET_NULL
    pop r12
    pop rbx
    leave
    ret
END_FUNC gen_iternext

;; ============================================================================
;; async_gen_iternext(PyGenObject *self) -> fat value (AsyncGenASend wrapper)
;; Called by GET_ANEXT. Creates an AsyncGenASend wrapper that, when iterated
;; by SEND, actually resumes the async generator.
;; rdi = async generator
;; Returns: (rax=AsyncGenASend*, edx=TAG_PTR)
;; ============================================================================
DEF_FUNC async_gen_iternext
    push rbx
    mov rbx, rdi               ; rbx = async generator

    ; Allocate AsyncGenASend wrapper
    mov edi, AsyncGenASend_size
    call ap_malloc
    ; rax = wrapper

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel async_gen_asend_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + AsyncGenASend.ags_gen], rbx
    mov dword [rax + AsyncGenASend.ags_state], 0   ; initial
    mov qword [rax + AsyncGenASend.gi_return_value], 0
    mov qword [rax + AsyncGenASend.gi_return_tag], 0

    ; INCREF the async generator (wrapper holds a ref)
    inc qword [rbx + PyObject.ob_refcnt]

    mov edx, TAG_PTR
    pop rbx
    leave
    ret
END_FUNC async_gen_iternext

;; ============================================================================
;; ags_iternext(AsyncGenASend *self) -> fat value or NULL
;; Called by SEND loop. Drives the async generator.
;;
;; State machine:
;;   0 (initial)  → resume async gen, return yielded value, go to state 1
;;   1 (yielded)  → return NULL (SEND sees exhausted, reads gi_return_value)
;;   2 (closed)   → raise StopAsyncIteration
;;
;; rdi = AsyncGenASend wrapper
;; Returns: (rax=payload, edx=tag) or (rax=0, edx=0) for exhaustion
;; ============================================================================
DEF_FUNC ags_iternext
    push rbx
    push r12

    mov rbx, rdi               ; rbx = wrapper

    ; Check state
    mov eax, [rbx + AsyncGenASend.ags_state]
    cmp eax, 1
    je .agsi_second_call
    cmp eax, 2
    jae .agsi_closed

    ; State 0: initial — resume the async generator
    mov r12, [rbx + AsyncGenASend.ags_gen] ; r12 = async generator

    ; Check if generator is exhausted
    mov rdi, [r12 + PyGenObject.gi_frame]
    test rdi, rdi
    jz .agsi_gen_exhausted

    ; Check if already running
    cmp qword [r12 + PyGenObject.gi_running], 1
    je .agsi_error

    ; Mark as running
    mov qword [r12 + PyGenObject.gi_running], 1

    ; Push None as sent value onto the generator's frame stack
    mov rdi, [r12 + PyGenObject.gi_frame]
    FRAME_PUSH_NONE rdi, rax

    ; Resume execution of the async generator
    mov rdi, [r12 + PyGenObject.gi_frame]
    call eval_frame
    ; rax = result payload, rdx = result tag
    push rax
    push rdx

    ; Mark as not running
    mov qword [r12 + PyGenObject.gi_running], 0

    ; Check if exhausted (instr_ptr == 0)
    mov rdi, [r12 + PyGenObject.gi_frame]
    cmp qword [rdi + PyFrame.instr_ptr], 0
    jne .agsi_yielded

    ; Async gen returned (exhausted): free frame, raise StopAsyncIteration
    call frame_free
    mov qword [r12 + PyGenObject.gi_frame], 0
    pop rdx                    ; result tag
    pop rax                    ; result payload
    mov [r12 + PyGenObject.gi_return_value], rax
    mov [r12 + PyGenObject.gi_return_tag], rdx

    ; Mark wrapper as closed
    mov dword [rbx + AsyncGenASend.ags_state], 2

    ; Raise StopAsyncIteration
    lea rdi, [rel exc_StopAsyncIteration_type]
    xor esi, esi
    xor edx, edx
    call exc_new
    mov rdi, rax
    call raise_exception_obj
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.agsi_yielded:
    ; Async gen yielded a value — store it and return it
    pop rdx                    ; result tag
    pop rax                    ; result payload

    ; Store yielded value in wrapper's gi_return_value for SEND exhaustion path
    mov [rbx + AsyncGenASend.gi_return_value], rax
    mov [rbx + AsyncGenASend.gi_return_tag], rdx

    ; INCREF the value (we're storing + returning it)
    INCREF_VAL rax, rdx

    ; Transition to state 1 (yielded)
    mov dword [rbx + AsyncGenASend.ags_state], 1

    pop r12
    pop rbx
    leave
    ret

.agsi_second_call:
    ; State 1: already yielded — return NULL to signal SEND exhaustion
    ; SEND will read gi_return_value from the wrapper (at offset +48)
    ; which holds the yielded value stored during state 0.
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.agsi_gen_exhausted:
    ; Generator already exhausted
    mov dword [rbx + AsyncGenASend.ags_state], 2
    lea rdi, [rel exc_StopAsyncIteration_type]
    xor esi, esi
    xor edx, edx
    call exc_new
    mov rdi, rax
    call raise_exception_obj
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.agsi_closed:
    ; State 2: closed — raise StopAsyncIteration
    lea rdi, [rel exc_StopAsyncIteration_type]
    xor esi, esi
    xor edx, edx
    call exc_new
    mov rdi, rax
    call raise_exception_obj
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.agsi_error:
    RET_NULL
    pop r12
    pop rbx
    leave
    ret
END_FUNC ags_iternext

;; ============================================================================
;; ags_iter_self(AsyncGenASend *self) -> self with INCREF
;; tp_iter for AsyncGenASend: return self (it IS the iterator)
;; ============================================================================
DEF_FUNC_BARE ags_iter_self
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    mov edx, TAG_PTR
    ret
END_FUNC ags_iter_self

;; ============================================================================
;; ags_dealloc(AsyncGenASend *self)
;; Free the wrapper: DECREF stored value and async generator, then free.
;; ============================================================================
DEF_FUNC ags_dealloc
    push rbx
    mov rbx, rdi

    ; DECREF stored return value if present
    mov rdi, [rbx + AsyncGenASend.gi_return_value]
    mov rsi, [rbx + AsyncGenASend.gi_return_tag]
    DECREF_VAL rdi, rsi

    ; DECREF the async generator
    mov rdi, [rbx + AsyncGenASend.ags_gen]
    call obj_decref

    ; Free the wrapper itself
    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC ags_dealloc

;; ============================================================================
;; gen_dealloc(PyObject *self)
;; Free generator: free frame if still held, DECREF code.
;; ============================================================================
DEF_FUNC gen_dealloc
    push rbx

    mov rbx, rdi

    ; Free frame if still held
    mov rdi, [rbx + PyGenObject.gi_frame]
    test rdi, rdi
    jz .no_frame
    call frame_free
.no_frame:

    ; XDECREF gi_return_value (tag-aware)
    mov rdi, [rbx + PyGenObject.gi_return_value]
    mov rsi, [rbx + PyGenObject.gi_return_tag]
    XDECREF_VAL rdi, rsi

    ; DECREF code object
    mov rdi, [rbx + PyGenObject.gi_code]
    call obj_decref

    ; Free self (GC-aware)
    mov rdi, rbx
    call gc_dealloc

    pop rbx
    leave
    ret
END_FUNC gen_dealloc

;; ============================================================================
;; gen_iter_self(PyObject *self) -> self with INCREF
;; tp_iter for generator: return self
;; ============================================================================
DEF_FUNC_BARE gen_iter_self
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret
END_FUNC gen_iter_self

;; ============================================================================
;; gen_repr(PyObject *self) -> PyStrObject*
;; ============================================================================
DEF_FUNC_BARE gen_repr
    lea rdi, [rel gen_repr_str]
    jmp str_from_cstr
END_FUNC gen_repr

;; ============================================================================
;; coro_repr(PyObject *self) -> PyStrObject*
;; ============================================================================
DEF_FUNC_BARE coro_repr
    lea rdi, [rel coro_repr_str]
    jmp str_from_cstr
END_FUNC coro_repr

;; ============================================================================
;; async_gen_repr(PyObject *self) -> PyStrObject*
;; ============================================================================
DEF_FUNC_BARE async_gen_repr
    lea rdi, [rel async_gen_repr_str]
    jmp str_from_cstr
END_FUNC async_gen_repr

;; ============================================================================
;; gen_send(PyGenObject *gen, PyObject *value) -> PyObject*
;; Resume generator with a sent value. Returns yielded value or NULL.
;; rdi = generator, rsi = value to send
;; ============================================================================
global gen_send
DEF_FUNC gen_send
    ; rdi = generator, rsi = value, edx = value_tag
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi               ; rbx = generator
    mov r13, rsi               ; r13 = value to send
    mov r14d, edx              ; r14d = value tag

    ; Check if generator is exhausted
    mov r12, [rbx + PyGenObject.gi_frame]
    test r12, r12
    jz .gs_exhausted

    ; Check if already running
    cmp qword [rbx + PyGenObject.gi_running], 1
    je .gs_error

    ; Mark as running
    mov qword [rbx + PyGenObject.gi_running], 1

    ; Push sent value onto the frame's value stack
    FRAME_PUSH_VAL r12, r13, r14b, rax

    ; INCREF sent value (tag-aware, may be SmallInt)
    INCREF_VAL r13, r14

    ; Resume execution
    mov rdi, r12
    call eval_frame
    mov r12, rax               ; save return value payload
    mov r13, rdx               ; save return value tag (sent value no longer needed)

    ; Mark as not running
    mov qword [rbx + PyGenObject.gi_running], 0

    ; Check if exhausted
    mov rdi, [rbx + PyGenObject.gi_frame]
    cmp qword [rdi + PyFrame.instr_ptr], 0
    jne .gs_yielded

    ; Exhausted: free frame
    call frame_free
    mov qword [rbx + PyGenObject.gi_frame], 0

    ; Store return value in gi_return_value (for StopIteration.value)
    mov [rbx + PyGenObject.gi_return_value], r12
    mov [rbx + PyGenObject.gi_return_tag], r13

    ; Return NULL to signal StopIteration
    RET_NULL
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.gs_yielded:
    mov rax, r12
    mov rdx, r13               ; restore result tag
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.gs_exhausted:
    RET_NULL
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.gs_error:
    RET_NULL
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC gen_send

;; ============================================================================
;; gen_throw(PyGenObject *gen, PyObject *exc_type) -> fat value
;; Throw an exception into a generator/coroutine.
;; If gi_frame == NULL → re-raise (generator exhausted).
;; Sets current_exception, pushes dummy value onto frame stack,
;; resumes eval_frame → exception unwind finds handler or propagates.
;; On yield: return yielded value. On exhaustion: return NULL.
;; rdi = generator, rsi = exc_type (PyTypeObject*)
;; ============================================================================
GT_GEN   equ 8
GT_EXC   equ 16
GT_FRAME equ 16
DEF_FUNC gen_throw, GT_FRAME
    push rbx
    push r12
    push r13

    mov rbx, rdi               ; rbx = generator
    mov r12, rsi               ; r12 = exc_type

    ; Check if generator is exhausted
    mov r13, [rbx + PyGenObject.gi_frame]
    test r13, r13
    jz .gt_exhausted

    ; Check if already running
    cmp qword [rbx + PyGenObject.gi_running], 1
    je .gt_error

    ; Mark as running
    mov qword [rbx + PyGenObject.gi_running], 1

    ; Create exception and set as current_exception
    ; XDECREF any pre-existing current_exception first
    mov rdi, [rel current_exception]
    test rdi, rdi
    jz .gt_no_prev_exc
    push r12
    push r13
    call obj_decref
    pop r13
    pop r12
.gt_no_prev_exc:
    mov rdi, r12               ; exc_type
    xor esi, esi               ; no message
    xor edx, edx               ; TAG_NULL
    call exc_new
    mov [rel current_exception], rax

    ; Push dummy value onto frame stack (eval_frame expects TOS after YIELD_VALUE)
    FRAME_PUSH_NONE r13, rax

    ; Back up instr_ptr by 2 bytes so it points to YIELD_VALUE itself
    ; (not the CACHE entry after it). The exception table covers YIELD_VALUE's
    ; offset but NOT the CACHE entry's offset.
    mov rax, [r13 + PyFrame.instr_ptr]
    sub rax, 2
    mov [r13 + PyFrame.instr_ptr], rax

    ; Set throw_pending so eval_frame resume immediately unwinds
    mov byte [rel throw_pending], 1

    ; Resume execution — eval_frame will see throw_pending and unwind
    mov rdi, r13
    call eval_frame
    mov r12, rax               ; save result payload
    mov r13, rdx               ; save result tag

    ; Mark as not running
    mov qword [rbx + PyGenObject.gi_running], 0

    ; Check if exhausted
    mov rdi, [rbx + PyGenObject.gi_frame]
    cmp qword [rdi + PyFrame.instr_ptr], 0
    jne .gt_yielded

    ; Exhausted: free frame
    call frame_free
    mov qword [rbx + PyGenObject.gi_frame], 0
    mov [rbx + PyGenObject.gi_return_value], r12
    mov [rbx + PyGenObject.gi_return_tag], r13

    ; Return NULL to signal StopIteration
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret

.gt_yielded:
    mov rax, r12
    mov rdx, r13
    pop r13
    pop r12
    pop rbx
    leave
    ret

.gt_exhausted:
    ; Generator is exhausted — re-raise the exception
    mov rdi, r12               ; exc_type
    xor esi, esi
    xor edx, edx
    call exc_new
    mov rdi, rax
    call raise_exception_obj
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret

.gt_error:
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC gen_throw

;; ============================================================================
;; gen_close(PyGenObject *gen) -> None
;; Close the generator by marking it as exhausted.
;; rdi = generator
;; ============================================================================
DEF_FUNC gen_close
    push rbx
    mov rbx, rdi

    ; Free frame if present
    mov rdi, [rbx + PyGenObject.gi_frame]
    test rdi, rdi
    jz .gc_done
    call frame_free
    mov qword [rbx + PyGenObject.gi_frame], 0

.gc_done:
    lea rax, [rel none_singleton]
    mov rdi, rax
    push rax
    call obj_incref
    pop rax
    mov edx, TAG_PTR             ; None is a heap pointer

    pop rbx
    leave
    ret
END_FUNC gen_close

;; ============================================================================
;; gen_getattr(PyGenObject *self, PyObject *name) -> PyObject*
;; Attribute lookup for generators: handles send, close, throw
;; ============================================================================
DEF_FUNC gen_getattr
    push rbx
    push r12

    mov rbx, rdi               ; self
    mov r12, rsi               ; name

    lea rdi, [r12 + PyStrObject.data]

    ; Check "send"
    CSTRING rsi, "send"
    call ap_strcmp
    test eax, eax
    jz .gga_send

    ; Check "close"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "close"
    call ap_strcmp
    test eax, eax
    jz .gga_close

    ; Check "throw"
    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "throw"
    call ap_strcmp
    test eax, eax
    jz .gga_throw

    ; Not found
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.gga_send:
    ; Return raw builtin — LOAD_ATTR handles binding via flag
    call _get_gen_send_builtin
    mov rdi, rax
    call obj_incref
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.gga_close:
    call _get_gen_close_builtin
    mov rdi, rax
    call obj_incref
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.gga_throw:
    call _get_gen_throw_builtin
    mov rdi, rax
    call obj_incref
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC gen_getattr

;; ============================================================================
;; coro_getattr(PyGenObject *self, PyObject *name) -> PyObject*
;; Attribute lookup for coroutines: send, close, throw, cr_await, cr_running
;; ============================================================================
DEF_FUNC coro_getattr
    push rbx
    push r12

    mov rbx, rdi               ; self
    mov r12, rsi               ; name

    lea rdi, [r12 + PyStrObject.data]

    ; Check "send"
    CSTRING rsi, "send"
    call ap_strcmp
    test eax, eax
    jz .cga_send

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "close"
    call ap_strcmp
    test eax, eax
    jz .cga_close

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "throw"
    call ap_strcmp
    test eax, eax
    jz .cga_throw

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "cr_running"
    call ap_strcmp
    test eax, eax
    jz .cga_cr_running

    ; Not found
    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.cga_send:
    call _get_gen_send_builtin
    mov rdi, rax
    call obj_incref
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.cga_close:
    call _get_gen_close_builtin
    mov rdi, rax
    call obj_incref
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.cga_throw:
    call _get_gen_throw_builtin
    mov rdi, rax
    call obj_incref
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.cga_cr_running:
    ; Return bool for cr_running
    mov rax, [rbx + PyGenObject.gi_running]
    mov edx, TAG_BOOL
    pop r12
    pop rbx
    leave
    ret
END_FUNC coro_getattr

;; ============================================================================
;; async_gen_getattr(PyGenObject *self, PyObject *name) -> PyObject*
;; Attribute lookup for async generators: asend, aclose, athrow
;; Also supports send, close, throw (same underlying operations)
;; ============================================================================
DEF_FUNC async_gen_getattr
    push rbx
    push r12

    mov rbx, rdi
    mov r12, rsi

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "asend"
    call ap_strcmp
    test eax, eax
    jz .aga_send

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "send"
    call ap_strcmp
    test eax, eax
    jz .aga_send

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "aclose"
    call ap_strcmp
    test eax, eax
    jz .aga_close

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "close"
    call ap_strcmp
    test eax, eax
    jz .aga_close

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "athrow"
    call ap_strcmp
    test eax, eax
    jz .aga_throw

    lea rdi, [r12 + PyStrObject.data]
    CSTRING rsi, "throw"
    call ap_strcmp
    test eax, eax
    jz .aga_throw

    RET_NULL
    pop r12
    pop rbx
    leave
    ret

.aga_send:
    call _get_gen_send_builtin
    mov rdi, rax
    call obj_incref
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.aga_close:
    call _get_gen_close_builtin
    mov rdi, rax
    call obj_incref
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.aga_throw:
    call _get_gen_throw_builtin
    mov rdi, rax
    call obj_incref
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC async_gen_getattr

;; ============================================================================
;; Builtin implementations for gen.send(), gen.close(), gen.throw()
;; These follow the builtin calling convention: (args, nargs)
;; args[0] = self (generator), remaining args follow
;; ============================================================================

;; _gen_send_impl(args, nargs) — gen.send(value)
DEF_FUNC _gen_send_impl
    push rbx

    cmp rsi, 2
    jne .gsi_error

    mov rax, rdi               ; save args ptr
    mov rbx, [rax]            ; rbx = gen (save for return value access)
    mov rdx, [rax + 24]       ; value_tag = args[1].tag
    mov rsi, [rax + 16]       ; value = args[1].payload
    mov rdi, rbx              ; gen = args[0].payload
    call gen_send
    test edx, edx             ; check tag, not payload (SmallInt-0 vs NULL)
    jnz .gsi_ret

    ; StopIteration — raise with actual return value from generator
    ; exc_new(type, value_payload, value_tag)
    lea rdi, [rel exc_StopIteration_type]
    mov rsi, [rbx + PyGenObject.gi_return_value]
    mov rdx, [rbx + PyGenObject.gi_return_tag]
    test edx, edx
    jnz .gsi_have_val
    ; No return value stored — use None
    lea rsi, [rel none_singleton]
    mov edx, TAG_PTR
.gsi_have_val:
    call exc_new
    mov rdi, rax
    call raise_exception_obj

.gsi_ret:
    pop rbx
    leave
    ret

.gsi_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "send() takes exactly one argument"
    call raise_exception
END_FUNC _gen_send_impl

;; _gen_close_impl(args, nargs) — gen.close()
DEF_FUNC _gen_close_impl
    mov rdi, [rdi]             ; gen = args[0]
    call gen_close
    leave
    ret
END_FUNC _gen_close_impl

;; _gen_throw_impl(args, nargs) — gen.throw(exc_type)
DEF_FUNC _gen_throw_impl
    push rbx

    cmp rsi, 2
    jne .gti_error

    mov rax, rdi               ; save args ptr
    mov rbx, [rax]            ; rbx = gen
    mov rsi, [rax + 16]       ; exc_type = args[1].payload
    mov rdi, rbx              ; gen = args[0].payload
    call gen_throw
    test edx, edx
    jnz .gti_ret

    ; Exhausted — raise StopIteration with return value
    lea rdi, [rel exc_StopIteration_type]
    mov rsi, [rbx + PyGenObject.gi_return_value]
    mov rdx, [rbx + PyGenObject.gi_return_tag]
    test edx, edx
    jnz .gti_have_val
    lea rsi, [rel none_singleton]
    mov edx, TAG_PTR
.gti_have_val:
    call exc_new
    mov rdi, rax
    call raise_exception_obj

.gti_ret:
    pop rbx
    leave
    ret

.gti_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "throw() takes exactly one argument"
    call raise_exception
END_FUNC _gen_throw_impl

;; Lazy-init helpers for gen method builtins
DEF_FUNC_LOCAL _get_gen_send_builtin
    mov rax, [rel _gen_send_cache]
    test rax, rax
    jnz .ret
    lea rdi, [rel _gen_send_impl]
    CSTRING rsi, "send"
    call builtin_func_new
    mov [rel _gen_send_cache], rax
.ret:
    leave
    ret
END_FUNC _get_gen_send_builtin

DEF_FUNC_LOCAL _get_gen_close_builtin
    mov rax, [rel _gen_close_cache]
    test rax, rax
    jnz .ret
    lea rdi, [rel _gen_close_impl]
    CSTRING rsi, "close"
    call builtin_func_new
    mov [rel _gen_close_cache], rax
.ret:
    leave
    ret
END_FUNC _get_gen_close_builtin

DEF_FUNC_LOCAL _get_gen_throw_builtin
    mov rax, [rel _gen_throw_cache]
    test rax, rax
    jnz .ret
    lea rdi, [rel _gen_throw_impl]
    CSTRING rsi, "throw"
    call builtin_func_new
    mov [rel _gen_throw_cache], rax
.ret:
    leave
    ret
END_FUNC _get_gen_throw_builtin

;; ============================================================================
;; Data section
;; ============================================================================
section .data

gen_name_str:       db "generator", 0
gen_repr_str:       db "<generator>", 0
coro_name_str:      db "coroutine", 0
coro_repr_str:      db "<coroutine>", 0
async_gen_name_str: db "async_generator", 0
async_gen_repr_str: db "<async_generator>", 0

; Cached builtin singletons for gen methods
align 8
_gen_send_cache: dq 0
_gen_close_cache: dq 0
_gen_throw_cache: dq 0

align 8
global gen_type
gen_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq gen_name_str             ; tp_name
    dq PyGenObject_size         ; tp_basicsize
    dq gen_dealloc              ; tp_dealloc
    dq gen_repr                 ; tp_repr
    dq gen_repr                 ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq gen_getattr              ; tp_getattr (.send, .close, .throw)
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq gen_iter_self            ; tp_iter (return self)
    dq gen_iternext             ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC                        ; tp_flags
    dq 0                        ; tp_bases
    dq gen_traverse                        ; tp_traverse
    dq gen_clear                        ; tp_clear

align 8
global coro_type
coro_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq coro_name_str            ; tp_name
    dq PyGenObject_size         ; tp_basicsize
    dq gen_dealloc              ; tp_dealloc
    dq coro_repr                ; tp_repr
    dq coro_repr                ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq coro_getattr             ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq gen_iter_self            ; tp_iter (return self)
    dq gen_iternext             ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC                        ; tp_flags
    dq 0                        ; tp_bases
    dq gen_traverse                        ; tp_traverse
    dq gen_clear                        ; tp_clear

align 8
global async_gen_type
async_gen_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq async_gen_name_str       ; tp_name
    dq PyGenObject_size         ; tp_basicsize
    dq gen_dealloc              ; tp_dealloc
    dq async_gen_repr           ; tp_repr
    dq async_gen_repr           ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq async_gen_getattr        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq gen_iter_self            ; tp_iter (return self)
    dq async_gen_iternext       ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_HAVE_GC                        ; tp_flags
    dq 0                        ; tp_bases
    dq gen_traverse                        ; tp_traverse
    dq gen_clear                        ; tp_clear

ags_name_str: db "async_generator_asend", 0

align 8
global async_gen_asend_type
async_gen_asend_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq ags_name_str             ; tp_name
    dq AsyncGenASend_size       ; tp_basicsize
    dq ags_dealloc              ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq ags_iter_self            ; tp_iter (return self)
    dq ags_iternext             ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq 0                        ; tp_flags
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
