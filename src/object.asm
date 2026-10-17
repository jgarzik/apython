; object.asm - PyObject base operations
; Allocation, reference counting, type dispatch for repr/str/hash/bool
; Fat-value aware: functions accept (payload, tag) pairs

%include "macros.inc"
%include "object.inc"

extern ap_malloc
extern ap_free
extern str_from_cstr
extern dict_get
extern dict_new
extern ap_strcmp
extern none_singleton
extern str_type
extern bool_false
extern bool_true
extern int_repr
extern int_type
extern eval_exception_unwind
extern int_promote_mpz
extern int_to_i64
extern float_type
extern float_repr
extern none_repr
extern bool_repr
extern type_getattr
extern type_setattr
extern type_call


;; ============================================================================
;; obj_incref(PyObject *obj)
;; Increment reference count; NULL-safe.
;; Callers must only pass heap pointers (not SmallInts).
;; ============================================================================
DEF_FUNC_BARE obj_incref
    test rdi, rdi
    jz .skip
    inc qword [rdi + PyObject.ob_refcnt]
.skip:
    ret
END_FUNC obj_incref

;; ============================================================================
;; obj_decref(PyObject *obj)
;; Decrement reference count; deallocate if zero; NULL-safe.
;; Callers must only pass heap pointers (not SmallInts).
;; ============================================================================
DEF_FUNC_BARE obj_decref
    test rdi, rdi
    jz .skip
    dec qword [rdi + PyObject.ob_refcnt]
    jnz .skip
    ; refcount hit zero - deallocate
    jmp obj_dealloc
.skip:
    ret
END_FUNC obj_decref

; The trashcan.
;
; obj_decref -> obj_dealloc -> tp_dealloc -> obj_decref is one machine frame
; per level of a nested structure, and nothing bounded it: a list nested 200k
; deep walked the stack off its guard page the moment it was dropped, and the
; only symptom was SIGSEGV.  Past a nesting limit the object is set aside
; instead, on a chain threaded through its own ob_refcnt -- which is zero by
; definition here, and read by nothing until the object is picked back up --
; and the outermost dealloc frees the chain iteratively.
;
; This is CPython's Py_TRASHCAN, put in the one place every deallocation
; already funnels through rather than in each type's tp_dealloc.  The limit is
; CPython's Py_TRASHCAN_HEADROOM, and it has to be well above 1: the drain
; below runs at nesting 1, so a smaller one would deposit every child of every
; drained object and make no progress in the ordinary case.
TRASH_LIMIT equ 50

; trash_nesting and trash_later lives in ThreadState (src/include/threadstate.inc).

;; ============================================================================
;; obj_dealloc(PyObject *obj)
;; Calls type's tp_dealloc if present, else just frees
;; ============================================================================
DEF_FUNC_BARE obj_dealloc

    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8                  ; the calls below want a 16-byte rsp
    mov rbx, rdi

    cmp qword [gs:ThreadState.trash_nesting], TRASH_LIMIT
    jl .td_enter

    ; Too deep: set it aside for the outermost dealloc.  It has to leave the
    ; collector's lists first -- its tp_dealloc has not run, so nothing has
    ; untracked it, and a collection during the drain would otherwise walk an
    ; object whose refcount is already zero.  gc_untrack is idempotent, so the
    ; untrack inside tp_dealloc still runs harmlessly later.
    mov rax, [rbx + PyObject.ob_type]
    test rax, rax
    jz .td_no_gc
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .td_no_gc
    extern gc_untrack
    mov rdi, rbx
    call gc_untrack
.td_no_gc:
    mov rax, [gs:ThreadState.trash_later]
    mov [rbx + PyObject.ob_refcnt], rax
    mov [gs:ThreadState.trash_later], rbx
    jmp .td_out

.td_enter:
    inc qword [gs:ThreadState.trash_nesting]

    ; PEP 442: __del__ runs before anything is taken apart -- before the weak
    ; references are cleared and before tp_dealloc releases a field -- and if
    ; it brings the object back, nothing below may run at all.  It used to be
    ; called from inside instance_dealloc, after the weakrefs had already been
    ; emptied and with no way to say the object had been resurrected, so
    ; `def __del__(self): survivors.append(self)` freed an object that the
    ; list it had just been added to still pointed at.
    ;
    ; TYPE_FLAG_HAS_DEL is one bit, maintained by type_refresh_attr_flags down
    ; every subclass, and it is only ever set on a heaptype.
    mov rax, [rbx + PyObject.ob_type]
    test rax, rax
    jz .no_finalizer
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HAS_DEL
    jz .no_finalizer

    ; A finalizer runs at most once, and the collector may have run this one
    ; already: it finalizes a whole unreachable cycle before clearing any of
    ; it.  The bit lives in the GC head, which is only there to read while the
    ; object is still tracked -- gc_untrack happens later, inside gc_dealloc.
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .td_do_finalize
    cmp qword [rbx - GC_HEAD_SIZE + PyGC_Head.gc_next], 0
    je .td_do_finalize              ; untracked: no bit to read
    test qword [rbx - GC_HEAD_SIZE + PyGC_Head.gc_prev], GC_PREV_MASK_FINALIZED
    jnz .no_finalizer
    or qword [rbx - GC_HEAD_SIZE + PyGC_Head.gc_prev], GC_PREV_MASK_FINALIZED

.td_do_finalize:
    extern obj_call_finalizer
    mov rdi, rbx
    call obj_call_finalizer
    test eax, eax
    jnz .td_leave                   ; resurrected: free nothing

.no_finalizer:

    ; The object is dead: take it out of the collector's lists NOW, before a
    ; single field is released.  This used to happen last, inside gc_dealloc,
    ; so for the whole of a container's teardown -- every field released and
    ; every __del__ those releases fire -- it sat in a generation list with a
    ; refcount of zero, and anything walking the generations from inside one
    ; of those finalizers found it.  gc.get_objects() took a reference to a
    ; dead object and freed it a second time when the list went;
    ; gc.collect() computed gc_refs = 0 for it, cleared it, and left the
    ; freed block in its own young list.  CPython untracks at the top of
    ; every tp_dealloc, and this is the one funnel they all come through.
    ;
    ; After the finalizer, not before it: __del__ runs with the object
    ; tracked and held at one, which is what CPython's subtype_dealloc
    ; arranges by re-tracking around the call.  gc_untrack is idempotent, so
    ; the one inside gc_dealloc still runs, harmlessly.
    mov rax, [rbx + PyObject.ob_type]
    test rax, rax
    jz .no_untrack
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .no_untrack
    mov rdi, rbx
    call gc_untrack
.no_untrack:

    ; Weak references to this object have to be emptied, and their callbacks
    ; run, before it is freed.  The links live in a side table rather than in
    ; the object, so the check is one compare against a counter that stays
    ; zero in a program that makes no weak references.
    extern weakref_live
    cmp qword [rel weakref_live], 0
    je .no_weakrefs
    extern weakref_clear_for
    mov rdi, rbx
    call weakref_clear_for
.no_weakrefs:

    ; Get type's tp_dealloc
    mov rax, [rbx + PyObject.ob_type]
    test rax, rax
    jz .just_free
    mov rax, [rax + PyTypeObject.tp_dealloc]
    test rax, rax
    jz .just_free

    ; Call tp_dealloc(obj)
    mov rdi, rbx
    call rax
    jmp .td_leave

.just_free:
    mov rdi, rbx
    call ap_free

.td_leave:
    dec qword [gs:ThreadState.trash_nesting]
    jnz .td_out
    cmp qword [gs:ThreadState.trash_later], 0
    je .td_out

    ; The outermost dealloc empties the chain, one object at a time.  The
    ; nesting stays at 1 for the whole drain, so each object's own children go
    ; on the chain rather than onto the machine stack once they are deep
    ; enough -- which is what keeps this loop, and not the stack, bounded.
.td_drain:
    inc qword [gs:ThreadState.trash_nesting]
.td_drain_loop:
    mov rbx, [gs:ThreadState.trash_later]
    test rbx, rbx
    jz .td_drain_done
    mov rax, [rbx + PyObject.ob_refcnt]
    mov [gs:ThreadState.trash_later], rax
    mov qword [rbx + PyObject.ob_refcnt], 0
    mov rdi, rbx
    call obj_dealloc
    jmp .td_drain_loop
.td_drain_done:
    dec qword [gs:ThreadState.trash_nesting]

.td_out:
    add rsp, 8
    pop rbx
    pop rbp
.bail:
    ret
END_FUNC obj_dealloc

;; ============================================================================
;; obj_repr(rdi=value) -> PyObject* (string)
;; Decodes the Value, then dispatches: int immediate → int_repr, pointer → tp_repr.
;; ============================================================================
DEF_FUNC obj_repr
    V_UNPACK rdi, rsi

    cmp esi, TAG_SMALLINT
    je .smallint
    cmp esi, TAG_FLOAT
    je .float_tag

    ; TAG_PTR: use tp_repr
    test rdi, rdi
    jz .null_obj

    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .no_repr
    mov rax, [rax + PyTypeObject.tp_repr]
    test rax, rax
    jz .no_repr

    ; tail-call tp_repr(obj, tag)
    mov edx, esi               ; pass tag for tag-aware repr (e.g., int_repr)
    leave
    jmp rax

.smallint:
    ; rdi = raw int value — int_repr checks edx for TAG_SMALLINT
    RET_TAG_SMALLINT
    call int_repr
    leave
    ret

.float_tag:
    ; rdi = raw double bits.  float_repr reads edx to tell these from a
    ; float subclass instance, which reaches it as a pointer.
    mov edx, TAG_FLOAT
    call float_repr
    leave
    ret

.none_tag:
    call none_repr
    leave
    ret

.bool_tag:
    test rdi, rdi
    jz .bool_false_repr
    lea rdi, [rel bool_true]
    call bool_repr
    leave
    ret
.bool_false_repr:
    lea rdi, [rel bool_false]
    call bool_repr
    leave
    ret

.no_repr:
    ; A type with no tp_repr used to answer a NULL Value and set no
    ; exception, and every caller had to guess what that meant: print()
    ; skipped the argument, and repr(iter({1})) handed ITS caller a missing
    ; argument -- or, one frame further on, a segfault.
    ;
    ; CPython's default: "<set_iterator object at 0x7f...>".  The address is
    ; this object's own, so it cannot match CPython's -- but neither can
    ; CPython's match its own from one run to the next, so nothing correct
    ; can be comparing it, and leaving it out only made the shape wrong.
    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .null_obj
    mov rsi, rdi
    mov rdi, rax
    call obj_default_repr
    mov edx, TAG_PTR
    leave
    ret

.null_obj:
    ; Return a NULL *Value*, not just a zero payload: callers test the tag,
    ; and leaving edx stale made print() dereference the NULL.
    RET_NULL
    leave
    ret
END_FUNC obj_repr

;; ============================================================================
;; obj_default_repr(rdi = a PyTypeObject*, rsi = the object)
;; -> rax = PyStrObject* "<name object at 0x...>"
;;
;; The repr a type with no tp_repr gets, and object.__repr__'s own answer.  Its
;; own function because the instance repr wants the same shape, and because
;; rbt_buf is shared with the TypeError composer -- neither can be live across
;; the other.
;; ============================================================================
global obj_default_repr
DEF_FUNC obj_default_repr
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rel rbt_buf]
    lea rsi, [rel odr_open]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbx + PyTypeObject.tp_name]
    test rsi, rsi
    jnz .odr_have_name
    lea rsi, [rel rbt_unknown]
.odr_have_name:
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel odr_object]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, r12
    call obj_repr_address
    lea rdi, [rel rbt_buf]
    call str_from_cstr
    pop r12
    pop rbx
    leave
    ret
END_FUNC obj_default_repr

;; ============================================================================
;; obj_default_repr_named(rdi = the object, rsi = a module cstr or 0,
;; rdx = the type's name cstr)
;; -> rax = PyStrObject* "<module.name object at 0x...>"
;;
;; What object.__repr__ answers for a class defined in Python.  CPython leaves
;; the module out when it is "builtins", which is the same rule that makes
;; `repr(iter({1}))` say "set_iterator" and not "builtins.set_iterator".
;; ============================================================================
global obj_default_repr_named
ODN_OBJ  equ 8
ODN_MOD  equ 16
ODN_NAME equ 24
ODN_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC obj_default_repr_named, ODN_FRAME
    mov [rbp - ODN_OBJ], rdi
    mov [rbp - ODN_MOD], rsi
    mov [rbp - ODN_NAME], rdx

    lea rdi, [rel rbt_buf]
    lea rsi, [rel odr_open]
    call rbt_append_cstr
    mov rsi, [rbp - ODN_MOD]
    test rsi, rsi
    jz .odn_name
    mov rdi, rax
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel odr_dot]
    call rbt_append_cstr
.odn_name:
    mov rdi, rax
    mov rsi, [rbp - ODN_NAME]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel odr_object]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - ODN_OBJ]
    call obj_repr_address
    lea rdi, [rel rbt_buf]
    call str_from_cstr
    leave
    ret
END_FUNC obj_default_repr_named

;; ============================================================================
;; obj_repr_named_at(rdi = the object, rsi = a prefix cstr, rdx = a name cstr
;; or 0) -> rax = PyStrObject* "<prefix name at 0x...>"
;;
;; The shape a function, a generator, a coroutine and an async generator all
;; have.  With no name it is just "<prefix at 0x...>".
;; ============================================================================
global obj_repr_named_at
ORN_OBJ  equ 8
ORN_NAME equ 16
ORN_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC obj_repr_named_at, ORN_FRAME
    mov [rbp - ORN_OBJ], rdi
    mov [rbp - ORN_NAME], rdx
    mov rdx, rsi
    lea rdi, [rel rbt_buf]
    lea rsi, [rel odr_open]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, rdx
    call rbt_append_cstr
    mov rsi, [rbp - ORN_NAME]
    test rsi, rsi
    jz .orn_addr
    mov rdi, rax
    push rsi
    lea rsi, [rel odr_space]
    call rbt_append_cstr
    pop rsi
    mov rdi, rax
    call rbt_append_cstr
.orn_addr:
    mov rdi, rax
    mov rsi, [rbp - ORN_OBJ]
    call obj_repr_address
    lea rdi, [rel rbt_buf]
    call str_from_cstr
    leave
    ret
END_FUNC obj_repr_named_at

;; ============================================================================
;; obj_repr_buf(rdi = the first cstr) -> rax = a cursor into the shared repr
;; buffer, with that string already in it.  Append with rbt_append_cstr and
;; finish with obj_repr_buf_str; the buffer is shared with the TypeError
;; composer, so nothing may be live across the two.
;; ============================================================================
global obj_repr_buf
DEF_FUNC obj_repr_buf
    mov rsi, rdi
    lea rdi, [rel rbt_buf]
    call rbt_append_cstr
    leave
    ret
END_FUNC obj_repr_buf

;; ============================================================================
;; obj_repr_buf_str() -> rax = the buffer as a str
;; ============================================================================
global obj_repr_buf_str
DEF_FUNC obj_repr_buf_str
    lea rdi, [rel rbt_buf]
    call str_from_cstr
    leave
    ret
END_FUNC obj_repr_buf_str

;; ============================================================================
;; obj_repr_address(rdi = cursor into rbt_buf, rsi = the object)
;; -> rax = the new cursor, having written " at 0xADDR>"
;;
;; CPython formats the address with %p, which on glibc is "0x" and lowercase
;; hex with no leading zeroes.  Every default repr in the tree ends this way.
;; ============================================================================
global obj_repr_address
DEF_FUNC obj_repr_address
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    lea rsi, [rel odr_object_at]
    call rbt_append_cstr
    mov rbx, rax
    ; The digits, high nibble first, skipping leading zeroes.
    mov rax, r12
    mov ecx, 60
.ora_skip:
    mov rdx, rax
    shr rdx, cl
    and edx, 15
    jnz .ora_digits
    sub ecx, 4
    jns .ora_skip
    xor ecx, ecx                ; the address is 0: print one digit
.ora_digits:
    mov rdx, rax
    shr rdx, cl
    and edx, 15
    add dl, '0'
    cmp dl, '9'
    jbe .ora_put
    add dl, 'a' - '0' - 10
.ora_put:
    mov [rbx], dl
    inc rbx
    sub ecx, 4
    jns .ora_digits
    mov byte [rbx], '>'
    inc rbx
    mov byte [rbx], 0
    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret
END_FUNC obj_repr_address

;; ============================================================================
;; obj_str(rdi=value) -> PyObject* (string)
;; Decodes the Value, then dispatches: int immediate → int_repr, pointer → tp_str
;; falling back to tp_repr.
;; ============================================================================
DEF_FUNC obj_str
    V_UNPACK rdi, rsi
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi               ; save tag

    cmp esi, TAG_SMALLINT
    je .smallint
    cmp esi, TAG_FLOAT
    je .float_tag

    ; TAG_PTR path
    test rdi, rdi
    jz .fallback

    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .fallback

    mov rax, [rax + PyTypeObject.tp_str]
    test rax, rax
    jz .fallback

    mov rdi, rbx
    mov edx, r12d              ; tag for tp_str (e.g., int_repr checks edx)
    call rax
    pop r12
    pop rbx
    leave
    ret

.smallint:
    ; SmallInt: delegate to int_repr
    mov rdi, rbx
    RET_TAG_SMALLINT
    call int_repr
    pop r12
    pop rbx
    leave
    ret

.float_tag:
    ; rbx = raw double bits; see the note in obj_repr.
    mov rdi, rbx
    mov edx, TAG_FLOAT
    call float_repr
    pop r12
    pop rbx
    leave
    ret

.none_tag:
    call none_repr
    pop r12
    pop rbx
    leave
    ret

.bool_tag:
    test rbx, rbx
    jz .bool_false_str
    lea rdi, [rel bool_true]
    call bool_repr                 ; bool tp_str = bool_repr
    pop r12
    pop rbx
    leave
    ret
.bool_false_str:
    lea rdi, [rel bool_false]
    call bool_repr
    pop r12
    pop rbx
    leave
    ret

.fallback:
    mov rdi, rbx
    mov rsi, r12
    V_PACK rdi, rsi
    call obj_repr
    pop r12
    pop rbx
    leave
    ret
END_FUNC obj_str
;; ============================================================================
;; obj_as_slice_index(rdi = payload, edx = tag) -> rax = the i64, or does not
;; return
;;
;; obj_as_index with CPython's other wording.  The start and stop of
;; list.index and tuple.index are slice bounds, and CPython blames them as
;; such -- "slice indices must be integers or have an __index__ method" --
;; where a tabsize or a repetition count gets "'str' object cannot be
;; interpreted as an integer".  The acceptance test is the same one
;; obj_as_index applies; only the refusal differs, so this decides and hands
;; over.
;; ============================================================================
global obj_as_slice_index
DEF_FUNC obj_as_slice_index, OAI_FRAME
    cmp edx, TAG_SMALLINT
    je .oasi_ok
    cmp edx, TAG_PTR
    jne .oasi_bad
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jz .oasi_bad
    cmp qword [rax + PyNumberMethods.nb_index], 0
    je .oasi_bad
.oasi_ok:
    ; The same body, in clamping mode: `[1,2,3][2**70:]` is [] in CPython,
    ; not an error, because a bound past the end is the end.
    leave
    jmp obj_as_index_clamped
.oasi_bad:
    RAISE exc_TypeError_type, \
        "slice indices must be integers or have an __index__ method"
END_FUNC obj_as_slice_index


;; ============================================================================
;; obj_as_index(rdi = payload, edx = tag) -> rax = int64
;;
;; Convert a Value to a C index, or raise TypeError.  Callers used to hand
;; whatever they were given straight to int_to_i64, which reads
;; PyIntObject.compact unconditionally: a float's payload is raw IEEE bits, so
;; range(1.5) dereferenced 0x3ff8000000000000, and None's fields decoded as a
;; garbage length, so range(None) hung.
;;
;; Takes the same (payload, tag) pair as int_to_i64 so a call site changes by
;; one word.  This is where the __index__ protocol belongs once heaptypes
;; carry real slots.
;;
;; obj_as_index_clamped, below, is the same body with an int too wide for an
;; index coming back as the nearest end rather than raising.  For a caller
;; whose field IS an int64 and whose CPython counterpart holds an object: a
;; slice bound, because `[1,2,3][2**70:]` is [] there and not an error, and
;; range, which keeps its three bounds in int64s where `range(1 << 1000)` is
;; an ordinary range -- _collections_abc builds one at import, to name the
;; type its iterator has.
;; ============================================================================
OAI_MODE  equ 8             ; 0 = refuse what will not fit, 1 = clamp to it,
                            ; 2 = refuse it as a SEQUENCE index
; The template a non-index is refused with, or 0 for the generic one.  A
; subscript says "list indices must be integers or slices, not float" and
; names the container as well as the key.
OAI_MSG   equ 16
OAI_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC obj_as_index, OAI_FRAME
    mov qword [rbp - OAI_MODE], 0
    xor esi, esi
oai_body:
    mov [rbp - OAI_MSG], rsi
    cmp edx, TAG_SMALLINT
    je .oai_immediate
    cmp edx, TAG_PTR
    jne .oai_error
    ; An int subclass WRAPS an int rather than being one -- buildclass gives
    ; it a PyInstanceObject layout, not room on the end of a PyIntObject -- so
    ; the value has to be unwrapped before it can be read.  Without this the
    ; wrapper's own header was read as the number, and every index built from
    ; one, `class N(int)` or an IntEnum member alike, came out as 0.
    extern int_unwrap
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .oai_immediate
    mov rax, [rdi + PyObject.ob_type]
    REQUIRE_INT_TYPE rax, rcx, .oai_try_dunder
    jmp .oai_to_i64

.oai_immediate:
    mov rax, rdi
    leave
    ret

.oai_try_dunder:
    ; Not an int, but __index__ makes an object usable wherever one is
    ; wanted -- as a subscript, a repetition count, a slice bound, or an
    ; argument to hex().  This is the single place all of those converge.
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jz .oai_error
    mov rax, [rax + PyNumberMethods.nb_index]
    test rax, rax
    jz .oai_error
    call rax                    ; nb_index returns a Value
    V_UNPACK rax, rdx
    ; __index__ must itself return an int; one level only, so a class whose
    ; __index__ returns another such class is an error rather than a loop.
    cmp edx, TAG_SMALLINT
    je .oai_dunder_done
    cmp edx, TAG_PTR
    jne .oai_bad_index
    mov rcx, [rax + PyObject.ob_type]
    REQUIRE_INT_TYPE rcx, rsi, .oai_bad_index
    mov rdi, rax
    mov edx, TAG_PTR
    call int_unwrap             ; __index__ may itself return an int subclass
    cmp edx, TAG_SMALLINT
    je .oai_dunder_immediate
    jmp .oai_to_i64
.oai_dunder_immediate:
    mov rax, rdi
    leave
    ret
.oai_dunder_done:
    leave
    ret

;; A heap int, which may be wider than an index.  int_to_i64 truncates
;; through __gmpz_get_si, so `[1][2**70]` answered [1]'s first element and
;; `chr(2**70)` answered "\x00" -- a wrong ANSWER, not a refusal.  CPython
;; raises here; a SLICE bound is the exception, and clamps.
.oai_to_i64:
    push rdi
    push rdx
    extern int_fits_i64
    call int_fits_i64
    pop rdx
    pop rdi
    test eax, eax
    jz .oai_too_wide
    call int_to_i64
    leave
    ret

.oai_too_wide:
    cmp qword [rbp - OAI_MODE], 1
    je .oai_clamp
    cmp qword [rbp - OAI_MODE], 2
    je .oai_too_wide_seq
    extern exc_OverflowError_type
    RAISE exc_OverflowError_type, "Python int too large to convert to C ssize_t"
.oai_too_wide_seq:
    ; CPython passes the exception TYPE to PyNumber_AsSsize_t, and every
    ; sequence subscript passes IndexError: `[1][2**70]` is an IndexError
    ; there, not an OverflowError, and the sentence is a different one.
    extern exc_IndexError_type
    RAISE exc_IndexError_type, "cannot fit 'int' into an index-sized integer"
.oai_clamp:
    ; A slice bound past either end is that end, which is what CPython's
    ; _PyEval_SliceIndex does.  The sign is the mpz's: a heap int this wide
    ; always has one.
    INT_NEED_MPZ rdi
    lea rdi, [rdi + PyIntObject.mpz]
    extern __gmpz_cmp_si
    xor esi, esi
    call __gmpz_cmp_si wrt ..plt
    test eax, eax
    mov rax, 0x7FFFFFFFFFFFFFFF
    jns .oai_clamped
    mov rax, 0x8000000000000000
.oai_clamped:
    leave
    ret

.oai_bad_index:
    ; Name what it did return.  CPython says "__index__ returned non-int
    ; (type str)", and the word that identifies the mistake was the one
    ; missing.
    mov rsi, rax
    V_PACK rsi, rdx
    lea rdi, [rel oai_bad_index_msg]
    jmp raise_type_error_with_name

.oai_error:
    ; Name the type.  This is the single funnel for every __index__ context --
    ; subscripts, slice bounds, repetition counts, hex() -- so the one word
    ; that identifies the mistake was missing from all of them.  The Value has
    ; to be rebuilt from the (payload, tag) pair the caller passed.
    mov rsi, rdi
    V_PACK rsi, rdx
    mov rdi, [rbp - OAI_MSG]
    test rdi, rdi
    jnz raise_type_error_with_name
    lea rdi, [rel oai_not_an_index]
    jmp raise_type_error_with_name
END_FUNC obj_as_index

;; ============================================================================
;; obj_as_index_object(rdi = payload, edx = tag) -> rax = an int Value, owned
;;
;; The same refusal as obj_as_index, answering the OBJECT rather than an
;; int64.  For a caller whose CPython counterpart keeps the object: range's
;; three bounds, which are ints there and were int64s here, so
;; `range(1 << 1000)` had nowhere to put its stop.
;; ============================================================================
OAO_ARG   equ 8
OAO_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
global obj_as_index_object
DEF_FUNC obj_as_index_object, OAO_FRAME
    ; The tag first: V_PACK below clobbers the register it is in.
    mov ecx, edx
    mov rax, rdi
    V_PACK rax, rdx
    mov [rbp - OAO_ARG], rax
    mov edx, ecx
    cmp edx, TAG_SMALLINT
    je .oao_keep
    cmp edx, TAG_PTR
    jne .oao_refuse
    extern int_unwrap
    call int_unwrap             ; an int subclass wraps a real int, and
                                ; answers in the same pair it was handed
    cmp edx, TAG_SMALLINT
    je .oao_unwrapped
    mov rax, [rdi + PyObject.ob_type]
    REQUIRE_INT_TYPE rax, rcx, .oao_dunder
.oao_unwrapped:
    mov rax, rdi
    V_PACK rax, rdx
    INCREF_V rax, rcx
    leave
    ret
.oao_keep:
    mov rax, [rbp - OAO_ARG]
    leave
    ret
.oao_dunder:
    mov rax, [rbp - OAO_ARG]
    V_TEST_PTR rax, rcx
    ja .oao_refuse
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_as_number]
    test rcx, rcx
    jz .oao_refuse
    mov rcx, [rcx + PyNumberMethods.nb_index]
    test rcx, rcx
    jz .oao_refuse
    mov rdi, rax
    call rcx                    ; nb_index returns an owned Value
    test rax, rax
    jz .oao_zero
    leave
    ret
.oao_zero:
    xor eax, eax
    leave
    ret
.oao_refuse:
    ; obj_as_index's own wording, which names the type.
    mov rsi, [rbp - OAO_ARG]
    lea rdi, [rel oai_not_an_index]
    jmp raise_type_error_with_name
END_FUNC obj_as_index_object

;; ============================================================================
;; obj_as_index_seq(rdi = payload, edx = tag, rsi = the refusal's template,
;;                  whose \x01 stands for the key's type, or 0)
;;   -> rax = int64
;; The same, refusing a too-wide int as a sequence subscript does: an
;; IndexError naming the index, not an OverflowError naming a C type.
;; ============================================================================
global obj_as_index_seq
DEF_FUNC obj_as_index_seq, OAI_FRAME
    mov qword [rbp - OAI_MODE], 2
    jmp oai_body
END_FUNC obj_as_index_seq

;; ============================================================================
;; obj_as_index_clamped(rdi = payload, edx = tag) -> rax = int64
;; The same, clamping instead of refusing.  See obj_as_index above.
;; ============================================================================
global obj_as_index_clamped
DEF_FUNC obj_as_index_clamped, OAI_FRAME
    mov qword [rbp - OAI_MODE], 1
    xor esi, esi
    jmp oai_body
END_FUNC obj_as_index_clamped

;; ============================================================================
;; obj_as_index_clamped_msg(rdi = payload, edx = tag, rsi = the refusal's
;;                          template, whose \x01 stands for the type, or 0)
;;   -> rax = int64
;; The same again, with the caller's wording.  A slice bound has its own:
;; CPython says "slice indices must be integers or None or have an __index__
;; method" and names no type at all.
;; ============================================================================
global obj_as_index_clamped_msg
DEF_FUNC obj_as_index_clamped_msg, OAI_FRAME
    mov qword [rbp - OAI_MODE], 1
    jmp oai_body
END_FUNC obj_as_index_clamped_msg

section .rodata
oai_not_an_index: db "'", 1, "' object cannot be interpreted as an integer", 0
oai_bad_index_msg: db "__index__ returned non-int (type ", 1, ")", 0
section .text

;; ============================================================================
;; value_number_methods(rdi = payload, edx = tag) -> rax = PyNumberMethods*, or 0
;;
;; Resolve a Value's numeric protocol table, immediates included.  Callers that
;; want an arithmetic slot need this rather than assuming int: builtin_divmod
;; called int_floordiv unconditionally, so divmod(1.5, 1.5) crashed even though
;; 1.5 // 1.5 has always worked.
;; ============================================================================
DEF_FUNC_BARE value_number_methods
    cmp edx, TAG_SMALLINT
    je .vnm_int
    cmp edx, TAG_FLOAT
    je .vnm_float
    cmp edx, TAG_PTR
    jne .vnm_none
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_number]
    ret
.vnm_int:
    lea rax, [rel int_type]
    mov rax, [rax + PyTypeObject.tp_as_number]
    ret
.vnm_float:
    lea rax, [rel float_type]
    mov rax, [rax + PyTypeObject.tp_as_number]
    ret
.vnm_none:
    xor eax, eax
    ret
END_FUNC value_number_methods

;; ============================================================================
;; value_type(rdi = Value) -> rax = PyTypeObject*, or 0 for a NULL Value
;;
;; Resolve a Value's type, immediates included.  Several places open-code this
;; three-way test; having it once keeps them from disagreeing.
;; ============================================================================
DEF_FUNC_BARE value_type
    V_IS_INT rdi, rax
    jae .vt_int
    V_IS_FLOAT rdi, rax
    jb .vt_float
    test rdi, rdi
    jz .vt_null
    mov rax, [rdi + PyObject.ob_type]
    ; A heaptype's metatype is an internal split -- it exists only so that
    ; heaptypes get a tp_dealloc that static types must not have.  CPython
    ; has one `type`, and `type(C) is type` for an ordinary class, so report
    ; the one the language defines.
    extern user_type_metatype
    lea rcx, [rel user_type_metatype]
    cmp rax, rcx
    jne .vt_done
    lea rax, [rel type_type]
.vt_done:
    ret
.vt_int:
    lea rax, [rel int_type]
    ret
.vt_float:
    lea rax, [rel float_type]
    ret
.vt_null:
    xor eax, eax
    ret
END_FUNC value_type

; raise_type_error_with_name(rdi = template C string with a single %s marker
;                            written as \x01, rsi = Value whose type to name)
; Composes the message into a static buffer and raises TypeError.  Does not
; return.
; Wide enough for the longest message that goes through it, which is now a
; deprecation rather than an error: CPython's "__index__ returned non-int
; (type bool).  The ability to return an instance of a strict subclass of int
; is deprecated..." is 155 characters before the type name goes in.
; The longest is now float()'s subclass deprecation, which carries the
; receiver's class name as well: "ReturnsSubclass.__float__ returned
; non-float (type SubFloat).  The ability to return an instance of a strict
; subclass of float is deprecated, and may be removed in a future version of
; Python." -- two type names plus 160 fixed characters.
RTN_BUFSZ equ 512

section .rodata
rbt_open:    db ": '", 0
rbt_and:     db "' and '", 0
rbt_close:   db "'", 0
rbt_unknown: db "object", 0
hni_open:    db "unhashable type: '", 0
odr_open:    db "<", 0
odr_close:   db ">", 0
odr_object:  db " object", 0
odr_object_at: db " at 0x", 0
odr_quote:   db "'", 0
odr_space:   db " ", 0
odr_dot:     db ".", 0
drs_prefix:  db "descriptor ", 0
drs_after_name: db "' ", 0
drs_requires: db "requires a '", 0
drs_middle:  db "' object but received a '", 0
mah_digits:  db "0123456789abcdef", 0
tnm_none:    db "None", 0

section .bss
rbt_buf: resb 320   ; two 80-char type names plus the prefix and separators

section .text
DEF_FUNC raise_type_error_with_name
    push rbx
    push r12
    mov rbx, rdi
    mov rdi, rsi
    call value_type
    mov r12, rax                    ; type, or 0
    jmp rtn_compose
END_FUNC raise_type_error_with_name

;; ============================================================================
;; raise_type_error_with_typename(rdi = the same template, rsi = a type object)
;; For a caller that has released the object it is complaining about and kept
;; only its type -- the object is gone by then, and reading ob_type off freed
;; memory is exactly the bug this message is reporting.
;; ============================================================================
DEF_FUNC raise_type_error_with_typename
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
rtn_compose:
    mov rdi, rbx
    mov rsi, r12
    call type_name_message
    lea rdi, [rel exc_TypeError_type]
    mov rsi, rax
    extern exc_TypeError_type
    extern raise_exception
    call raise_exception
    ud2
END_FUNC raise_type_error_with_typename

;; ============================================================================
;; type_name_message(rdi = a template whose \x01 stands for a type name and
;;                   whose \x02 stands for the same but "None" for NoneType,
;;                   rsi = the type object, or 0 to leave the marker out)
;;   -> rax = the composed C string, in a shared static buffer
;;
;; The composition the two raisers above have always done, given a name of
;; its own because a WARNING wants it too: CPython's "__index__ returned
;; non-int (type bool)." names the type the same way its errors do.  The
;; buffer is shared and overwritten on every call, so the string is only good
;; until the next one -- which is all a raise or a warn needs.
;;
;; The \x02 form is CPython's _PyArg_BadArgument rule: that helper prints
;; "None" rather than "NoneType", so "format() argument 2 must be str, not
;; None" reads as it does there while every message built from a plain tp_name
;; keeps saying NoneType.
;; ============================================================================
global type_name_message
DEF_FUNC type_name_message
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rel rtn_buf]
    xor ecx, ecx
.tnm_copy:
    movzx eax, byte [rbx]
    test al, al
    jz .tnm_end
    inc rbx
    cmp al, 1
    je .tnm_insert
    cmp al, 2
    je .tnm_insert_arg
    cmp rcx, RTN_BUFSZ - 2
    jae .tnm_copy
    mov [rdi + rcx], al
    inc rcx
    jmp .tnm_copy
.tnm_insert_arg:
    extern none_type
    lea rax, [rel none_type]
    cmp r12, rax
    jne .tnm_insert
    lea rsi, [rel tnm_none]
    jmp .tnm_name
.tnm_insert:
    test r12, r12
    jz .tnm_copy
    mov rsi, [r12 + PyTypeObject.tp_name]
.tnm_name:
    movzx eax, byte [rsi]
    test al, al
    jz .tnm_copy
    inc rsi
    cmp rcx, RTN_BUFSZ - 2
    jae .tnm_copy
    mov [rdi + rcx], al
    inc rcx
    jmp .tnm_name
.tnm_end:
    mov byte [rdi + rcx], 0
    lea rax, [rel rtn_buf]
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_name_message

;; ============================================================================
;; dunder_require_self(rdi = self Value, rsi = the type whose method this is,
;; rdx = a second acceptable type, or 0,
;; rcx = the descriptor's own name, or 0)
;; -> rax = the self Value, unchanged; does not return if the type is wrong
;;
;; A dunder reached BY NAME is handed whatever the caller passed, and the slot
;; behind it decodes self without asking: int.__neg__(2.5) gives int's
;; nb_negative a float, str.__getitem__(5, 0) gives str's subscript an
;; integer, and each is a wild pointer rather than an error.  Registering
;; these names is what made the calls reachable at all, so every generator of
;; one has to ask this first.
;;
;; CPython words it "descriptor '__neg__' requires a 'int' object but received
;; a 'float'".  The generators know their own suffix, so they pass it and the
;; message reads as CPython's; a caller with nothing to say passes 0 and gets
;; the two type names alone.
;;
;; A subclass is accepted: int.__neg__(D(2)) for class D(int) is how a
;; subclass reaches the base's operator, and is the reason this is
;; type_is_subtype rather than a pointer compare.
;;
;; The second type is for the pairs that genuinely share one function.  set
;; and frozenset are registered from one table -- they are siblings, neither a
;; subtype of the other -- so set_dunder_len has to answer for both.  The
;; eight set operators used to need it too, and no longer do: each type
;; carries its own bodies now.
;; ============================================================================
DRS_SELF  equ 8
DRS_TYPE  equ 16
DRS_ALT   equ 24
DRS_NAME  equ 32
DRS_FRAME equ 48            ; + 0 pushes = 48

global dunder_require_self
DEF_FUNC dunder_require_self, DRS_FRAME
    mov [rbp - DRS_SELF], rdi
    mov [rbp - DRS_TYPE], rsi
    mov [rbp - DRS_ALT], rdx
    mov [rbp - DRS_NAME], rcx
    call value_type
    test rax, rax
    jz .drs_bad
    mov rdi, rax
    mov rsi, [rbp - DRS_TYPE]
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jnz .drs_ok
    mov rdx, [rbp - DRS_ALT]
    test rdx, rdx
    jz .drs_bad
    mov rdi, [rbp - DRS_SELF]
    call value_type
    mov rdi, rax
    mov rsi, [rbp - DRS_ALT]
    call type_is_subtype
    test eax, eax
    jz .drs_bad
.drs_ok:
    mov rax, [rbp - DRS_SELF]
    leave
    ret
.drs_bad:
    lea rdi, [rel rbt_buf]
    lea rsi, [rel drs_prefix]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - DRS_NAME]
    test rsi, rsi
    jz .drs_no_name
    lea rsi, [rel rbt_close]        ; the opening quote
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - DRS_NAME]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel drs_after_name]
    call rbt_append_cstr
    mov rdi, rax
.drs_no_name:
    lea rsi, [rel drs_requires]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - DRS_TYPE]
    mov rsi, [rsi + PyTypeObject.tp_name]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel drs_middle]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - DRS_SELF]
    call rbt_typename
    mov rdi, rax
    lea rsi, [rel rbt_close]
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel rbt_buf]
    call raise_exception
    ud2
END_FUNC dunder_require_self

;; ============================================================================
;; raise_binop_type_error(rdi = left Value, rsi = right Value,
;; rdx = prefix C string) -> never returns
;; "<prefix>: 'int' and 'complex'", which is how CPython words every binary
;; operator's TypeError.  With two operands the bare prefix does not say which
;; one was wrong.
;; ============================================================================
RBT_LEFT  equ 8
RBT_RIGHT equ 16
RBT_OPEN  equ 24
RBT_FRAME equ 40            ; + 1 push = 48, 16-aligned

DEF_FUNC_BARE raise_binop_type_error
    lea rcx, [rel rbt_open]     ; the default opener, ": '"
    jmp raise_binop_type_error_ex
END_FUNC raise_binop_type_error

;; ============================================================================
;; compose_binop_type_error(rdi = left Value, rsi = right Value,
;;                          rdx = the prefix, rcx = the text before the first
;;                          type name, or 0 for the usual ": '")
;;   -> rax = the composed C string, in the shared rbt_buf
;;
;; The composition raise_binop_type_error_ex does, without the raise.  A
;; caller that still has two references to release cannot unwind from where
;; it notices, so it sets the exception instead -- and was reporting the bare
;; "unsupported operand type(s)", with neither the operator nor the types.
;; ============================================================================
global compose_binop_type_error
DEF_FUNC compose_binop_type_error, RBT_FRAME
    push rbx
    mov [rbp - RBT_LEFT], rdi
    mov [rbp - RBT_RIGHT], rsi
    mov rbx, rdx
    test rcx, rcx
    jnz .cbt_have_open
    lea rcx, [rel rbt_open]
.cbt_have_open:
    mov [rbp - RBT_OPEN], rcx

    lea rdi, [rel rbt_buf]
    mov rsi, rbx
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RBT_OPEN]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RBT_LEFT]
    call rbt_typename
    mov rdi, rax
    lea rsi, [rel rbt_and]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RBT_RIGHT]
    call rbt_typename
    mov rdi, rax
    lea rsi, [rel rbt_close]
    call rbt_append_cstr

    lea rax, [rel rbt_buf]
    pop rbx
    leave
    ret
END_FUNC compose_binop_type_error

;; ============================================================================
;; raise_binop_type_error_ex(rdi = left Value, rsi = right Value,
;; rdx = prefix C string, rcx = opener C string)
;; -> never returns
;; The opener is what sits between the prefix and the first type name.  A
;; binary operator wants ": '", and COMPARE_OP wants " of '", because CPython
;; words that one "'<' not supported between instances of 'int' and 'str'".
;; ============================================================================
DEF_FUNC raise_binop_type_error_ex, RBT_FRAME
    push rbx
    mov [rbp - RBT_LEFT], rdi
    mov [rbp - RBT_RIGHT], rsi
    mov rbx, rdx
    mov [rbp - RBT_OPEN], rcx

    lea rdi, [rel rbt_buf]
    mov rsi, rbx
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RBT_OPEN]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RBT_LEFT]
    call rbt_typename
    mov rdi, rax
    lea rsi, [rel rbt_and]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RBT_RIGHT]
    call rbt_typename
    mov rdi, rax
    lea rsi, [rel rbt_close]
    call rbt_append_cstr

    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel rbt_buf]
    call raise_exception
    ud2
END_FUNC raise_binop_type_error_ex

; The cap and the buffer have to agree: 40 (prefix) + 3 + 80 + 7 + 80 + 1 + a
; NUL is 212, which overran a 192-byte buffer and wrote into the globals
; after it -- one of them being attr_error_pending, so an over-long type name
; in a divmod TypeError made the NEXT attribute error re-raise this one.
;; rbt_append_cstr(rdi = dest, rsi = src cstr) -> rax = the NUL it wrote.
;; Bounded at 80 bytes per field; the callers' buffers are sized for that.
global rbt_append_cstr
DEF_FUNC rbt_append_cstr
    xor ecx, ecx
.rbtc_loop:
    cmp rcx, 80
    jge .rbtc_done
    mov al, [rsi + rcx]
    test al, al
    jz .rbtc_done
    mov [rdi + rcx], al
    inc rcx
    jmp .rbtc_loop
.rbtc_done:
    lea rax, [rdi + rcx]
    mov byte [rax], 0
    leave
    ret
END_FUNC rbt_append_cstr

global rbt_typename
DEF_FUNC rbt_typename, 8            ; 1 push, so rsp is 16-aligned     ; (rdi = dest, rsi = a Value) -> rax = the NUL
    push rbx
    mov rbx, rdi
    mov rdi, rsi
    call value_type
    test rax, rax
    jz .rbtt_unknown
    mov rsi, [rax + PyTypeObject.tp_name]
    jmp .rbtt_have
.rbtt_unknown:
    lea rsi, [rel rbt_unknown]
.rbtt_have:
    mov rdi, rbx
    call rbt_append_cstr
    pop rbx
    leave
    ret
END_FUNC rbt_typename

;; ============================================================================
;; msg_append_i64(rdi = dest, rsi = the number) -> rax = the NUL it wrote
;;
;; The one thing a message could not carry.  Six file-local near-duplicates of
;; this exist -- in build.asm, bytes.asm twice, iomod.asm, structseq.asm and
;; func.asm -- and none of them is reachable from another file, which is why
;; "attempt to assign sequence of wrong size to extended slice" does not name
;; either size.  Signed, unlike most of those.
;; ============================================================================
DEF_FUNC msg_append_i64
    push rbx
    push r12
    mov rbx, rdi                ; dest
    mov rax, rsi

    sub rsp, 40
    lea rcx, [rsp + 32]
    mov byte [rcx], 0
    xor r12d, r12d              ; negative?
    test rax, rax
    jns .mai_digits
    mov r12d, 1
    neg rax
.mai_digits:
    test rax, rax
    jnz .mai_loop
    dec rcx
    mov byte [rcx], '0'
    jmp .mai_emit
.mai_loop:
    test rax, rax
    jz .mai_emit
    xor edx, edx
    mov r8d, 10
    div r8
    add dl, '0'
    dec rcx
    mov [rcx], dl
    jmp .mai_loop
.mai_emit:
    test r12d, r12d
    jz .mai_copy
    dec rcx
    mov byte [rcx], '-'
.mai_copy:
    mov rdi, rbx
    mov rsi, rcx
    call rbt_append_cstr
    add rsp, 40
    pop r12
    pop rbx
    leave
    ret
END_FUNC msg_append_i64

;; ============================================================================
;; msg_append_hex2(rdi = dest, esi = a byte) -> rax = the NUL it wrote
;; Two lowercase hex digits, which is how CPython spells the byte in a
;; UnicodeDecodeError.
;; ============================================================================
DEF_FUNC msg_append_hex2
    movzx esi, sil
    mov eax, esi
    shr eax, 4
    lea rcx, [rel mah_digits]
    movzx eax, byte [rcx + rax]
    mov [rdi], al
    mov eax, esi
    and eax, 15
    movzx eax, byte [rcx + rax]
    mov [rdi + 1], al
    mov byte [rdi + 2], 0
    lea rax, [rdi + 2]
    leave
    ret
END_FUNC msg_append_hex2

;; ============================================================================
;; msg_append_escaped_cp(rdi = dest, rsi = a str, rdx = index in code points)
;;   -> rax = the NUL it wrote
;;
;; One character, quoted and escaped the way CPython writes it in a
;; UnicodeEncodeError: '\xNN', '\uNNNN' or '\UNNNNNNNN' by magnitude.
;; ============================================================================
MAE_DEST equ 8
MAE_CP   equ 16
MAE_FRAME equ 40            ; + 1 push = 48, 16-aligned

DEF_FUNC msg_append_escaped_cp, MAE_FRAME
    push rbx
    mov [rbp - MAE_DEST], rdi
    mov rbx, rdi

    ; The code point at that index.  A str keeps UTF-8, so the byte offset has
    ; to be found first; an ASCII string is its own index.
    mov rdi, rsi
    mov rsi, rdx
    extern str_cp_at
    call str_cp_at
    mov [rbp - MAE_CP], rax

    mov byte [rbx], 39          ; a single quote
    lea rdi, [rbx + 1]
    ; Always escaped, printable or not: CPython writes even 'Z' as '\x5a' in
    ; a UnicodeEncodeError.
.mae_escape:
    mov byte [rdi], 92          ; a backslash
    inc rdi
    mov rax, [rbp - MAE_CP]
    cmp rax, 0x100
    jb .mae_x
    cmp rax, 0x10000
    jb .mae_u
    mov byte [rdi], 'U'
    inc rdi
    mov ecx, 8
    jmp .mae_digits
.mae_u:
    mov byte [rdi], 'u'
    inc rdi
    mov ecx, 4
    jmp .mae_digits
.mae_x:
    mov byte [rdi], 'x'
    inc rdi
    mov ecx, 2
.mae_digits:
    ; ecx nibbles, most significant first
    mov rax, [rbp - MAE_CP]
    lea r8, [rel mah_digits]
.mae_digit_loop:
    dec ecx
    mov r9, rax
    mov r10d, ecx
    shl r10d, 2
    mov r11, rcx
    mov ecx, r10d
    shr r9, cl
    mov rcx, r11
    and r9, 15
    movzx r9d, byte [r8 + r9]
    mov [rdi], r9b
    inc rdi
    test ecx, ecx
    jnz .mae_digit_loop

.mae_close:
    mov byte [rdi], 39
    mov byte [rdi + 1], 0
    lea rax, [rdi + 1]
    pop rbx
    leave
    ret
END_FUNC msg_append_escaped_cp

;; ============================================================================
;; raise_value_error_with_repr(rdi = prefix C string, rsi = the object Value)
;; -> never returns
;;
;; ValueError("<prefix><repr(obj)>"), which CPython writes as "%s: %R".  int's
;; own copy of this is inline and stays there, because its prefix carries the
;; base; float's message had simply lost the value it could not convert, and
;; complex's underscore rule needs the same shape.
;; ============================================================================
RVR_PREFIX equ 8
RVR_OBJ    equ 16
RVR_REPR   equ 24
RVR_FULL   equ 32
RVR_SUFFIX equ 40           ; the text after the repr, or 0
RVR_FRAME  equ 48           ; + 0 pushes = 48, 16-aligned

extern str_from_cstr_heap
extern str_concat
extern exc_new
extern exc_ValueError_type
extern raise_exception_obj

DEF_FUNC raise_value_error_with_repr, RVR_FRAME
    xor edx, edx
rvr_body:
    mov [rbp - RVR_SUFFIX], rdx
    mov [rbp - RVR_OBJ], rsi
    call str_from_cstr_heap         ; rdi still holds the prefix
    mov [rbp - RVR_PREFIX], rax

    mov rdi, [rbp - RVR_OBJ]
    call obj_repr
    test rax, rax
    jnz .rvr_have_repr
    ; repr itself raised.  Let that exception stand rather than replacing it
    ; with one about a message we could not build.
    mov rdi, [rbp - RVR_PREFIX]
    call obj_decref
    leave
    jmp eval_exception_unwind

.rvr_have_repr:
    mov [rbp - RVR_REPR], rax
    mov rdi, [rbp - RVR_PREFIX]
    mov rsi, rax
    mov ecx, TAG_PTR
    call str_concat
    mov [rbp - RVR_FULL], rax

    mov rdi, [rbp - RVR_PREFIX]
    call obj_decref
    mov rdi, [rbp - RVR_REPR]
    call obj_decref

    ; ...and the tail, when the repr goes in the MIDDLE: CPython's
    ; "None is not in list" puts it first and the sentence after.
    cmp qword [rbp - RVR_SUFFIX], 0
    je .rvr_no_suffix
    mov rdi, [rbp - RVR_SUFFIX]
    call str_from_cstr_heap
    mov [rbp - RVR_REPR], rax
    mov rdi, [rbp - RVR_FULL]
    mov rsi, rax
    mov ecx, TAG_PTR
    call str_concat
    push rax
    mov rdi, [rbp - RVR_FULL]
    call obj_decref
    mov rdi, [rbp - RVR_REPR]
    call obj_decref
    pop rax
    mov [rbp - RVR_FULL], rax
.rvr_no_suffix:

    lea rdi, [rel exc_ValueError_type]
    mov rsi, [rbp - RVR_FULL]
    mov edx, TAG_PTR
    call exc_new
    mov [rbp - RVR_PREFIX], rax     ; the exception; that slot is free now
    mov rdi, [rbp - RVR_FULL]
    call obj_decref                 ; exc_new took its own reference

    mov rdi, [rbp - RVR_PREFIX]
    leave
    jmp raise_exception_obj         ; chains and unwinds; takes the reference
END_FUNC raise_value_error_with_repr

;; ============================================================================
;; raise_value_error_with_repr2(rdi = prefix, rsi = the object Value,
;;                              rdx = the text after the repr)
;;   -> does not return
;; The same, with the repr in the middle: "None is not in list".
;; ============================================================================
global raise_value_error_with_repr2
DEF_FUNC raise_value_error_with_repr2, RVR_FRAME
    jmp rvr_body
END_FUNC raise_value_error_with_repr2

section .bss
; Set by instance_getattr when __getattr__ raised an AttributeError and it
; handed the exception back rather than unwinding.  Cleared on entry to every
; instance_getattr, so it cannot survive a lookup, and consumed by
; raise_no_attribute.  attr_error_pending lives in ThreadState (src/include/threadstate.inc).

rtn_buf: resb RTN_BUFSZ
section .text

;; ============================================================================
;; seq_repeat_not_index(rsi = the count that was not one) -- does not return
;;
;; What __mul__, __rmul__ and __imul__ say when called by name and handed
;; something that is not an index.  The OPERATOR words the same refusal
;; differently -- "can't multiply sequence by non-int of type 'str'" -- and
;; CPython draws exactly that line, because the two go through different
;; code: the operator through sequence_repeat, the dunder through the
;; wrapper's own PyNumber_AsSsize_t.
;; ============================================================================
DEF_FUNC seq_repeat_not_index
    CSTRING rdi, `'\x01' object cannot be interpreted as an integer`
    jmp raise_type_error_with_name
END_FUNC seq_repeat_not_index

;; ============================================================================
;; binop_is_count(rdi = a Value) -> eax = 1 when it could be a repetition count
;;
;; An int, a bool, an int subclass, or anything with an __index__.  Every
;; sq_repeat and sq_inplace_repeat asks this BEFORE seq_repeat_count, because
;; the answer decides between declining and raising -- and declining is what
;; lets the right operand's __rmul__ be asked at all.  `[1] * R()`, for an R
;; with an __rmul__ and nothing else, is R.__rmul__([1]) in CPython; here the
;; sequence's own slot raised first and the reflected dunder was never
;; reached.
;; ============================================================================
DEF_FUNC_BARE binop_is_count
    mov eax, 1
    V_IS_INT rdi, rcx
    jae .bic_yes
    V_TEST_PTR rdi, rcx
    ja .bic_no
    test rdi, rdi
    jz .bic_no
    mov rcx, [rdi + PyObject.ob_type]
    test rcx, rcx
    jz .bic_no
    lea rdx, [rel int_type]
    cmp rcx, rdx
    je .bic_yes
    lea rdx, [rel bool_type]
    cmp rcx, rdx
    je .bic_yes
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_INT_SUBCLASS
    jnz .bic_yes
    mov rcx, [rcx + PyTypeObject.tp_as_number]
    test rcx, rcx
    jz .bic_no
    cmp qword [rcx + PyNumberMethods.nb_index], 0
    je .bic_no
.bic_yes:
    ret
.bic_no:
    xor eax, eax
    ret
END_FUNC binop_is_count

;; ============================================================================
;; seq_repeat_count(rsi = the count, a Value) -> rax = the count as an i64
;;
;; Every sequence's sq_repeat and sq_inplace_repeat comes through here, which
;; is CPython's sequence_repeat: PyNumber_Check decides whether the argument
;; is a count at all, and PyNumber_AsSsize_t turns it into one.  Two things
;; follow from the second, and neither was done.  __index__ counts -- `[1] *
;; Index()` is a list of three in CPython and was a TypeError here.  And a
;; value too big for an index is an OverflowError naming the int, where every
;; caller used to run its own int_fits_i64 and report in terms of the
;; sequence: "too many items for list repetition" against CPython's "cannot
;; fit 'int' into an index-sized integer".  The in-place pair did not even do
;; that -- they took the count through obj_as_index, which truncates, so
;; `b *= 2**64` emptied the bytearray instead of refusing.
;;
;; Does not return on failure.
;; ============================================================================
SRC_ARG   equ 8             ; the count as the caller passed it, for the message
SRC_HELD  equ 16            ; an __index__ result, owned across the conversion
SRC_FRAME equ 32            ; + 0 pushes = 16-aligned
DEF_FUNC seq_repeat_count, SRC_FRAME
    mov [rbp - SRC_ARG], rsi
    mov qword [rbp - SRC_HELD], 0
    V_IS_INT rsi, rax
    jae .src_have_int
    V_TEST_PTR rsi, rax
    ja .src_bad
    test rsi, rsi
    jz .src_bad
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .src_have_int
    lea rcx, [rel bool_type]
    cmp rax, rcx
    je .src_have_int
    mov rcx, [rax + PyTypeObject.tp_flags]
    test rcx, TYPE_FLAG_INT_SUBCLASS
    jnz .src_have_int

    ; Not an int.  __index__ makes it one, exactly where a subscript would.
    mov rcx, [rax + PyTypeObject.tp_as_number]
    test rcx, rcx
    jz .src_bad
    mov rcx, [rcx + PyNumberMethods.nb_index]
    test rcx, rcx
    jz .src_bad
    mov rdi, rsi
    call rcx                    ; nb_index answers a Value
    test rax, rax
    jz .src_bad
    mov [rbp - SRC_HELD], rax
    mov rsi, rax
    ; and it has to BE an int; one level only, as obj_as_index does it.
    V_IS_INT rsi, rax
    jae .src_have_int
    V_TEST_PTR rsi, rax
    ja .src_bad_index
    mov rax, [rsi + PyObject.ob_type]
    REQUIRE_INT_TYPE rax, rcx, .src_bad_index

.src_have_int:
    mov rdi, rsi
    V_UNPACK rdi, rdx
    push rdi
    push rdx
    extern int_fits_i64
    call int_fits_i64
    pop rdx
    pop rdi
    test eax, eax
    jz .src_overflow
    extern int_to_i64
    call int_to_i64
    mov [rbp - SRC_ARG], rax    ; the answer, across the release below
    call .src_release
    mov rax, [rbp - SRC_ARG]
    leave
    ret

;; Give back the __index__ result, if there was one.  Every exit needs it and
;; three of the four are raises, which do not come back here.
.src_release:
    mov rdi, [rbp - SRC_HELD]
    test rdi, rdi
    jz .src_release_done
    mov qword [rbp - SRC_HELD], 0
    XDECREF_V rdi, rax
.src_release_done:
    ret

.src_bad_index:
    call .src_release
    RAISE exc_TypeError_type, "__index__ returned non-int"
.src_overflow:
    call .src_release
    extern exc_OverflowError_type
    RAISE exc_OverflowError_type, "cannot fit 'int' into an index-sized integer"
.src_bad:
    call .src_release
    mov rsi, [rbp - SRC_ARG]
    CSTRING rdi, `can't multiply sequence by non-int of type '\x01'`
    jmp raise_type_error_with_name
END_FUNC seq_repeat_count


;; ============================================================================
;; obj_generic_attr(rdi = object Value, rsi = name str) -> Value, or 0
;;
;; The attributes every object has regardless of type.  They used to be
;; nobody's job: each tp_getattr special-cased its own names and there was no
;; shared tail, so `(5).__class__` and `obj.__dict__` were AttributeErrors on
;; every type in the tree.  Called from the miss path of the attribute
;; lookups, so a type that defines one of these itself still wins.
;;
;; Returns a new reference, or 0 when the name is not one of these.
;; ============================================================================
OGA_OBJ   equ 8
OGA_NAME  equ 16
OGA_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC obj_generic_attr, OGA_FRAME
    push rbx
    mov [rbp - OGA_OBJ], rdi
    mov [rbp - OGA_NAME], rsi

    test rsi, rsi
    jz .oga_none
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .oga_none

    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "__class__"
    call ap_strcmp
    test eax, eax
    jz .oga_class

    mov rdi, [rbp - OGA_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "__dict__"
    call ap_strcmp
    test eax, eax
    jz .oga_dict

.oga_none:
    xor eax, eax
    pop rbx
    leave
    ret

.oga_class:
    ; Every value has a type, including the immediates.
    mov rdi, [rbp - OGA_OBJ]
    call value_type
    test rax, rax
    jz .oga_none
    mov rdi, rax
    push rax
    call obj_incref
    pop rax
    pop rbx
    leave
    ret

.oga_dict:
    ; Only an object with a real instance dict has one.  tp_dictoffset is 0
    ; for every static type and for the layouts that cannot host a dict.
    mov rdi, [rbp - OGA_OBJ]
    V_TEST_PTR rdi, rax
    ja .oga_none
    test rdi, rdi
    jz .oga_none
    ; A __slots__ class has none, whatever its tp_dictoffset says.  Its dict
    ; word is still in the layout, but nothing may put a dict there -- and
    ; this arm CREATED one on first read, which is how `__slots__` classes
    ; came to accept arbitrary attributes: asking for o.__dict__ gave them the
    ; dict they were supposed not to have.
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HAS_SLOTS
    jnz .oga_none
    LOAD_INST_DICT rbx, rdi, .oga_none
    test rbx, rbx
    jnz .oga_dict_have
    ; Not created yet: an instance gets its dict on first use, so asking for
    ; it has to create one or the attribute would come and go.
    call dict_new
    mov rbx, rax
    mov rdi, [rbp - OGA_OBJ]
    STORE_INST_DICT rdi, rbx, rcx, .oga_dict_have
.oga_dict_have:
    mov rdi, rbx
    call obj_incref
    mov rax, rbx
    pop rbx
    leave
    ret
END_FUNC obj_generic_attr

;; ============================================================================
;; obj_richcompare_bool(rdi = left Value, rsi = right Value, edx = op)
;; -> eax = 1 (true), 0 (false), or -1 (an exception is pending)
;;
;; CPython's PyObject_RichCompareBool, which is what every container search
;; uses and what none of them used here.  Nine sites open-coded a comparison
;; and treated a NULL result as "not equal" -- but NULL means either
;; NotImplemented, in which case the reflected operand and then identity must
;; be tried, or that the comparison raised, in which case it must propagate.
;; None of them read current_exception, so a raising __eq__ inside `x in list`
;; silently answered False.
;;
;; The identity shortcut comes first, as in CPython: a container holding an
;; object finds it even if its __eq__ is broken or raises.
;; ============================================================================
ORB_LEFT  equ 8
ORB_RIGHT equ 16
ORB_OP    equ 24
ORB_EXC   equ 32
ORB_RES   equ 40
ORB_FRAME equ 48            ; + 0 pushes = 48

DEF_FUNC obj_richcompare_bool, ORB_FRAME
    ; Two int immediates settle every operator right here, with no frame, no
    ; pair of references, no subclass question and no slot lookup.  The
    ; encoding is monotonic -- an immediate is i + V_INT_BIAS and the whole
    ; range lands in [0xFFF8.., 0xFFFF..] without wrapping -- so an UNSIGNED
    ; compare of the two Values IS the integer compare, which is the same
    ; identity list.sort's int comparator uses.
    ;
    ; It is worth an arm of its own because of what the general path costs for
    ; two small integers: int_compare builds a bool OBJECT, this function
    ; tests it with obj_is_true and then releases it.  Those three were 62% of
    ; min() and max() over a list of them.
    V_IS_INT rdi, rax
    jb .orb_general
    V_IS_INT rsi, rax
    jb .orb_general
    cmp rdi, rsi
    jb .orb_int_lt
    ja .orb_int_gt
    mov eax, 2                  ; equal
    jmp .orb_int_have
.orb_int_lt:
    mov eax, 1
    jmp .orb_int_have
.orb_int_gt:
    mov eax, 4
.orb_int_have:
    ; Each operator is the set of relations it accepts; the answer is whether
    ; the one that holds is in it.
    and edx, 7
    lea rcx, [rel orb_int_ops]
    movzx ecx, byte [rcx + rdx]
    test al, cl
    setnz al
    movzx eax, al
    leave
    ret

.orb_general:
    mov [rbp - ORB_LEFT], rdi
    mov [rbp - ORB_RIGHT], rsi
    mov [rbp - ORB_OP], rdx

    ; Hold a strong reference to both operands for the duration.  A
    ; comparison can run arbitrary Python: CPython's own
    ; test_count_index_remove_crashes has an __eq__ that clears the very list
    ; being searched, which frees the element the caller handed us as a
    ; borrowed slot reference (bpo-38610).  Doing it here rather than in each
    ; of the six search loops means no loop can forget.
    INCREF_V rdi, rax
    INCREF_V rsi, rax

    ; Identity: for == this is true and for != false, without consulting the
    ; type at all.  One compare, since a Value is one word.
    mov rdi, [rbp - ORB_LEFT]
    cmp rdi, [rbp - ORB_RIGHT]
    jne .orb_compare
    mov edx, [rbp - ORB_OP]
    cmp edx, PY_EQ
    je .orb_true
    cmp edx, PY_NE
    je .orb_false

.orb_compare:
    DUNDER_EXC_SAVE [rbp - ORB_EXC]

    ; --- the subclass-first rule ---
    ; When the RIGHT operand's type is a proper subclass of the left's, it is
    ; asked first, with the operator reversed.  COMPARE_OP has always done
    ; this; obj_richcompare_bool is what every CONTAINER asks, and it went
    ; straight to the left's slot -- so for a str subclass whose __eq__
    ; answers False, `SK("hello") == "hello"` was False and
    ; `SK("hello") in ["hello"]` was True.  Forty-three call sites: `in` on
    ; every container, list.count, list.index, list.remove, tuple.count,
    ; min, max and the sort.
    ;
    ; Looser than the arithmetic rule, exactly as CPython's do_richcompare is:
    ; a proper subclass with a tp_richcompare is enough, with no question
    ; about which methods it overrides.
    mov rsi, [rbp - ORB_RIGHT]
    V_TEST_PTR rsi, rax
    ja .orb_left_first          ; an immediate is int or float exactly
    mov rdi, [rbp - ORB_LEFT]
    call value_type
    test rax, rax
    jz .orb_left_first
    mov rcx, [rbp - ORB_RIGHT]
    mov rcx, [rcx + PyObject.ob_type]
    cmp rax, rcx
    je .orb_left_first          ; same type: nothing to prefer
    mov rdi, rcx
    mov rsi, rax
    call type_is_subtype
    test eax, eax
    jz .orb_left_first
    mov rdi, [rbp - ORB_RIGHT]
    mov rdi, [rdi + PyObject.ob_type]
    mov rax, [rdi + PyTypeObject.tp_richcompare]
    test rax, rax
    jz .orb_left_first
    mov rdi, [rbp - ORB_RIGHT]
    mov rsi, [rbp - ORB_LEFT]
    mov edx, [rbp - ORB_OP]
    lea rcx, [rel orb_swap_table]
    movsxd rdx, edx
    mov edx, [rcx + rdx*4]      ; the reversed op
    call rax
    test rax, rax
    jnz .orb_have_result
    ; It declined, or it raised.  A raise is the caller's; a decline means
    ; the ordinary order still gets its turn.
    DUNDER_RAISED [rbp - ORB_EXC], .orb_error

.orb_left_first:
    ; Left operand's tp_richcompare.
    mov rdi, [rbp - ORB_LEFT]
    call value_type
    test rax, rax
    jz .orb_identity
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jz .orb_reflected
    mov rdi, [rbp - ORB_LEFT]
    mov rsi, [rbp - ORB_RIGHT]
    mov edx, [rbp - ORB_OP]
    call rax
    test rax, rax
    jnz .orb_have_result
    DUNDER_RAISED [rbp - ORB_EXC], .orb_error

.orb_reflected:
    ; NotImplemented from the left: try the right operand with the op
    ; reversed, which is how a subclass or a mixed-type comparison gets its
    ; say.
    mov rdi, [rbp - ORB_RIGHT]
    call value_type
    test rax, rax
    jz .orb_identity
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jz .orb_identity
    mov rdi, [rbp - ORB_RIGHT]
    mov rsi, [rbp - ORB_LEFT]
    mov edx, [rbp - ORB_OP]
    lea rcx, [rel orb_swap_table]
    movsxd rdx, edx
    mov edx, [rcx + rdx*4]      ; the reversed op
    call rax
    test rax, rax
    jnz .orb_have_result
    DUNDER_RAISED [rbp - ORB_EXC], .orb_error

.orb_identity:
    ; Neither side had an opinion.  Equality falls back to identity, which
    ; the fast path above already ruled out, so the answer is fixed.
    mov edx, [rbp - ORB_OP]
    cmp edx, PY_EQ
    je .orb_false
    cmp edx, PY_NE
    je .orb_true
    ; Name the operator the caller actually asked for.  A flat "unorderable
    ; types" here read differently from the identical failure raised by
    ; COMPARE_OP and by list.sort, and min()/max() go through this one.
    lea rax, [rel orb_unorderable_msgs]
    movsxd rdx, edx
    mov rdx, [rax + rdx*8]
    ; ...and both types, which is the rest of CPython's sentence.  min() and
    ; max() come through here, and said only that it was not supported.
    mov rdi, [rbp - ORB_LEFT]
    mov rsi, [rbp - ORB_RIGHT]
    extern cmp_msg_open
    lea rcx, [rel cmp_msg_open]
    call compose_binop_type_error
    mov rsi, rax
    lea rdi, [rel exc_TypeError_type]
    ; set_exception, not raise_exception: this function holds a reference to
    ; both operands, and an unwind from here abandons the C stack and leaks
    ; them.  -1 is what the contract above already promises.
    extern set_exception
    call set_exception
    jmp .orb_error

.orb_have_result:
    mov [rbp - ORB_RES], rax    ; the result Value, owned
    mov rdi, rax
    call obj_is_true
    mov [rbp - ORB_OP], rax     ; the op is finished with; reuse the slot
    mov rdi, [rbp - ORB_RES]
    DECREF_V rdi, rdx
    mov rax, [rbp - ORB_OP]
    jmp .orb_done

.orb_true:
    mov eax, 1
    jmp .orb_done

.orb_false:
    xor eax, eax
    jmp .orb_done

.orb_error:
    mov eax, -1

.orb_done:
    mov [rbp - ORB_RES], rax
    mov rdi, [rbp - ORB_LEFT]
    DECREF_V rdi, rdx
    mov rdi, [rbp - ORB_RIGHT]
    DECREF_V rdi, rdx
    mov rax, [rbp - ORB_RES]
    leave
    ret
END_FUNC obj_richcompare_bool

;; ============================================================================
;; obj_binary_op(rdi = left Value, rsi = right Value, edx = op index, 0..12)
;; -> rax = result Value, or 0 with an exception pending
;;
;; CPython's PyNumber_Add and its siblings, made callable.  The whole protocol
;; lived inside op_binary_op, which pops from r13 and leaves through DISPATCH,
;; so no builtin could reach it: sum() hardcoded int_add/float_add and
;; min()/max() hardcoded a type ladder.  Both then read a declining slot's NULL
;; Value as the answer, and a NULL on the value stack surfaces as a failure in
;; whatever runs next -- sum([1j, 2j]) reported "build_string expects str".
;;
;; The order is binary_op1's: the left type's slot, the right type's same slot,
;; then the sequence fallback, then the dunder pair on a heaptype, then
;; TypeError.  Only the non-inplace half, 0..12; nothing that reduces a
;; sequence needs the other one.
;; ============================================================================
OBO_LEFT  equ 8
OBO_RIGHT equ 16
OBO_OP    equ 24
OBO_OFF   equ 32
OBO_EXC   equ 40
OBO_FRAME equ 48            ; + 0 pushes = 48

extern binary_op_offsets
extern binop_dunder_table
extern binop_rdunder_table
extern notimpl_singleton
extern dunder_call_2

; After a slot, a sequence method or a dunder: a Value that is not
; NotImplemented is the answer; NotImplemented is released and, like a NULL
; with nothing raised, hands the pair to the next candidate.  The dunder arms
; call Python-level methods by name, and `1.5 + Decimal(1)` reaches
; Decimal.__radd__, which RETURNS NotImplemented -- sum(), math.prod and
; math.sumprod all handed that object back as the sum.  Flags from a
; `test rax, rax` on entry.
%macro OBO_ANSWERED 0
    jz %%null
    lea rcx, [rel notimpl_singleton]
    cmp rax, rcx
    jne .obo_done
    mov rdi, rax
    call obj_decref
    jmp %%next
%%null:
    DUNDER_RAISED [rbp - OBO_EXC], .obo_error
%%next:
%endmacro

DEF_FUNC obj_binary_op, OBO_FRAME
    mov [rbp - OBO_LEFT], rdi
    mov [rbp - OBO_RIGHT], rsi
    movsxd rdx, edx
    mov [rbp - OBO_OP], rdx
    lea rax, [rel binary_op_offsets]
    mov rax, [rax + rdx*8]
    mov [rbp - OBO_OFF], rax    ; the nb_* offset both slot tries use

    ; Hold a strong reference to both operands for the duration, as
    ; obj_richcompare_bool does and for the same reason: a slot or a dunder
    ; runs arbitrary Python, and the caller's operands are usually borrowed
    ; slots in an array that call can reach.
    INCREF_V rdi, rax
    INCREF_V rsi, rax

    DUNDER_EXC_SAVE [rbp - OBO_EXC]

    ; --- the subclass-first rule ---
    ; When the RIGHT operand's type is a proper subclass of the left's and
    ; overrides the reflected name, it goes first.  op_binary_op has always
    ; done this; this function is what every builtin that adds two objects
    ; calls, and it went straight to the left type's slot -- so
    ; `1 + MyInt(3)` was right and `sum([1, 2, MyInt(3)])` was not.
    ;
    ; Only the forward half, 0..12, reaches here, and binop_rdunder_table is
    ; indexed the same way.
    mov rdx, [rbp - OBO_OP]
    lea rax, [rel binop_rdunder_table]
    mov rdx, [rax + rdx*8]
    mov rdi, [rbp - OBO_LEFT]
    mov rsi, [rbp - OBO_RIGHT]
    extern slot_binop_reflect_first
    call slot_binop_reflect_first
    test ecx, ecx
    jz .obo_left_slot
    cmp ecx, 2
    je .obo_error               ; the reflected call raised
    jmp .obo_done

.obo_left_slot:
    ; --- the left type's slot ---
    mov rdi, [rbp - OBO_LEFT]
    call value_type
    test rax, rax
    jz .obo_right_slot
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jz .obo_right_slot
    mov rcx, [rbp - OBO_OFF]
    mov rax, [rax + rcx]
    test rax, rax
    jz .obo_right_slot
    mov rdi, [rbp - OBO_LEFT]
    mov rsi, [rbp - OBO_RIGHT]
    call rax
    test rax, rax
    OBO_ANSWERED

.obo_right_slot:
    ; The left slot declined.  The right type gets the same slot with the
    ; operands still in their original order -- the only route by which a
    ; numeric type the left side has never heard of can answer.
    mov rdi, [rbp - OBO_RIGHT]
    call value_type
    test rax, rax
    jz .obo_seq
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jz .obo_seq
    mov rcx, [rbp - OBO_OFF]
    mov rax, [rax + rcx]
    test rax, rax
    jz .obo_seq
    mov rdi, [rbp - OBO_LEFT]
    mov rsi, [rbp - OBO_RIGHT]
    call rax
    test rax, rax
    OBO_ANSWERED

.obo_seq:
    ; sq_concat for +, sq_repeat for *, off the left operand -- what makes
    ; sum(list_of_lists, []) work.
    mov rcx, [rbp - OBO_OP]
    test rcx, rcx                   ; NB_ADD
    je .obo_seq_have_op
    cmp rcx, 5                  ; NB_MULTIPLY
    jne .obo_dunder
.obo_seq_have_op:
    mov rdi, [rbp - OBO_LEFT]
    call value_type
    test rax, rax
    jz .obo_dunder
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .obo_dunder
    mov rcx, [rbp - OBO_OP]
    test rcx, rcx
    jnz .obo_seq_repeat
    mov rax, [rax + PySequenceMethods.sq_concat]
    jmp .obo_seq_call
.obo_seq_repeat:
    mov rax, [rax + PySequenceMethods.sq_repeat]
.obo_seq_call:
    test rax, rax
    jz .obo_dunder
    mov rdi, [rbp - OBO_LEFT]
    mov rsi, [rbp - OBO_RIGHT]
    call rax
    test rax, rax
    OBO_ANSWERED

.obo_dunder:
    ; __add__ on the left, then __radd__ on the right.  A heaptype's binary
    ; dunders have no nb_* slot of their own -- slots.asm installs only the
    ; unary ones -- so this arm, not the two above, is what serves a user
    ; class.  The tag argument is TAG_PTR because V_PACK leaves a Value
    ; alone under it, which is what the operands already are.
    mov rdi, [rbp - OBO_LEFT]
    V_TEST_PTR rdi, rax
    ja .obo_rdunder          ; an immediate has no dunders
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .obo_rdunder
    mov rcx, [rbp - OBO_OP]
    lea rdx, [rel binop_dunder_table]
    mov rdx, [rdx + rcx*8]
    test rdx, rdx
    jz .obo_rdunder
    mov rsi, [rbp - OBO_RIGHT]
    mov ecx, TAG_PTR
    call dunder_call_2
    test rax, rax
    OBO_ANSWERED

.obo_rdunder:
    mov rdi, [rbp - OBO_RIGHT]
    V_TEST_PTR rdi, rax
    ja .obo_unsupported          ; an immediate has no dunders
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .obo_unsupported
    mov rcx, [rbp - OBO_OP]
    lea rdx, [rel binop_rdunder_table]
    mov rdx, [rdx + rcx*8]
    test rdx, rdx
    jz .obo_unsupported
    mov rsi, [rbp - OBO_LEFT]   ; reflected: the right operand is self
    mov ecx, TAG_PTR
    call dunder_call_2
    test rax, rax
    OBO_ANSWERED

.obo_unsupported:
    ; Multiplication still has PyNumber_Multiply's sequence tail.  A left
    ; sequence was offered the right operand above and declined it, so the
    ; right was not a count; a right sequence has not been asked at all, and
    ; `1 * "ab"` -- math.prod(["ab"]) starts from the int 1 -- is its repeat.
    cmp qword [rbp - OBO_OP], 5  ; NB_MULTIPLY
    jne .obo_unsupported_msg
    mov rdi, [rbp - OBO_LEFT]
    call obo_sq_repeat
    test rax, rax
    jnz .obo_right_not_count
    mov rdi, [rbp - OBO_RIGHT]
    call obo_sq_repeat
    test rax, rax
    jz .obo_unsupported_msg
    mov [rbp - OBO_OFF], rax    ; the offset slot is finished with
    mov rdi, [rbp - OBO_LEFT]
    call binop_is_count
    test eax, eax
    jz .obo_left_not_count
    mov rdi, [rbp - OBO_RIGHT]  ; sq_repeat(sequence, count)
    mov rsi, [rbp - OBO_LEFT]
    call [rbp - OBO_OFF]
    test rax, rax
    OBO_ANSWERED
    jmp .obo_unsupported_msg
.obo_right_not_count:
    mov rdi, [rbp - OBO_RIGHT]
    jmp .obo_not_count
.obo_left_not_count:
    mov rdi, [rbp - OBO_LEFT]
.obo_not_count:
    ; CPython's sequence_repeat wording, set rather than raised for the same
    ; reason as below.
    call value_type
    mov rsi, rax
    CSTRING rdi, `can't multiply sequence by non-int of type '\x01'`
    call type_name_message
    mov rsi, rax
    lea rdi, [rel exc_TypeError_type]
    call set_exception
    jmp .obo_error

.obo_unsupported_msg:
    ; SET_EXC, not RAISE: .obo_done below still has to release both operands,
    ; and an unwind from here would never reach it.  The message names the
    ; operator and both types, as CPython's does -- it was the bare prefix,
    ; so `sum([1, "a"])` said nothing about what it could not add.
    mov rcx, [rbp - OBO_OP]
    cmp rcx, 26
    jb .obo_have_op
    xor ecx, ecx
.obo_have_op:
    extern binary_op_symbols
    lea rax, [rel binary_op_symbols]
    mov rcx, [rax + rcx*8]
    mov [rbp - OBO_OFF], rcx    ; the offset slot is finished with
    sub rsp, 128                ; the prefix and the operator, as one string
    mov rdi, rsp
    extern binop_msg_prefix
    lea rsi, [rel binop_msg_prefix]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - OBO_OFF]
    call rbt_append_cstr
    mov rdi, [rbp - OBO_LEFT]
    mov rsi, [rbp - OBO_RIGHT]
    mov rdx, rsp
    xor ecx, ecx                ; the default ": '" before the first name
    call compose_binop_type_error
    mov rsi, rax
    lea rdi, [rel exc_TypeError_type]
    call set_exception
    add rsp, 128
    jmp .obo_error

.obo_error:
    xor eax, eax

.obo_done:
    mov [rbp - OBO_OP], rax     ; the op is finished with; reuse the slot
    mov rdi, [rbp - OBO_LEFT]
    DECREF_V rdi, rdx
    mov rdi, [rbp - OBO_RIGHT]
    DECREF_V rdi, rdx
    mov rax, [rbp - OBO_OP]
    leave
    ret
END_FUNC obj_binary_op

;; obo_sq_repeat(rdi = a Value) -> rax = its type's sq_repeat, or 0
DEF_FUNC_LOCAL obo_sq_repeat
    call value_type
    test rax, rax
    jz .osr_done
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .osr_done
    mov rax, [rax + PySequenceMethods.sq_repeat]
.osr_done:
    leave
    ret
END_FUNC obo_sq_repeat

section .rodata
align 8
orb_unorderable_msgs:
    dq orb_msg_lt, orb_msg_le, orb_msg_eq, orb_msg_eq, orb_msg_gt, orb_msg_ge
orb_msg_lt: db "'<' not supported between instances", 0
orb_msg_le: db "'<=' not supported between instances", 0
orb_msg_gt: db "'>' not supported between instances", 0
orb_msg_ge: db "'>=' not supported between instances", 0
; == and != never reach the raise -- both fall back to identity above -- but
; the table is indexed by the op, so the two slots have to hold something.
orb_msg_eq: db "unorderable types", 0

align 4
; Which relations each operator accepts: less = 1, equal = 2, greater = 4.
orb_int_ops:
    db 1                        ; PY_LT
    db 3                        ; PY_LE
    db 2                        ; PY_EQ
    db 5                        ; PY_NE
    db 4                        ; PY_GT
    db 6                        ; PY_GE
    db 0, 0                     ; no such operator; the mask makes it False

orb_swap_table:
    dd PY_GT                    ; PY_LT reversed
    dd PY_GE                    ; PY_LE
    dd PY_EQ                    ; PY_EQ
    dd PY_NE                    ; PY_NE
    dd PY_LT                    ; PY_GT
    dd PY_LE                    ; PY_GE
section .text

;; ============================================================================
;; hash_not_implemented(rdi = the object) -> never returns
;; Used as tp_hash for unhashable types (dict, list, set, bytearray), and
;; installed on a class that defines __eq__ without __hash__ or sets
;; __hash__ = None.  Raises TypeError("unhashable type: 'list'") -- it used to
;; name nothing, which is the one thing the message is for.
;; ============================================================================
global hash_not_implemented
DEF_FUNC hash_not_implemented
    extern raise_exception
    extern exc_TypeError_type
    push rdi
    sub rsp, 8
    lea rdi, [rel rbt_buf]
    lea rsi, [rel hni_open]
    call rbt_append_cstr
    mov rdi, rax
    add rsp, 8
    pop rsi
    call rbt_typename
    mov rdi, rax
    lea rsi, [rel rbt_close]
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel rbt_buf]
    call raise_exception
    ud2
END_FUNC hash_not_implemented

;; ============================================================================
;; object_hash(rdi = the object, edx = its tag) -> int64
;;
;; object.__hash__: the address, which is CPython's default for any object
;; that does not define one.  object_type.tp_hash was 0, and tp_hash is
;; inherited -- so every instance, every plain class, every function, module,
;; iterator and object() had none, and hash() on one raised TypeError.  dict
;; and set did not notice because obj_hash falls back to the address itself;
;; only the hash() builtin, which reads tp_hash directly, could see it.
;; ============================================================================
global object_hash
DEF_FUNC_BARE object_hash
    mov rax, rdi
    ret
END_FUNC object_hash

;; ============================================================================
;; obj_hash(rdi=value) -> int64
;; Decodes the Value, then dispatches: int immediate → int_hash_i64, pointer → tp_hash.
;; ============================================================================
DEF_FUNC obj_hash
    V_UNPACK rdi, rsi

    cmp esi, TAG_SMALLINT
    je .smallint_hash
    cmp esi, TAG_FLOAT
    je .float_hash

    ; TAG_PTR path
    test rdi, rdi
    jz .default_hash

    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .default_hash
    mov rax, [rax + PyTypeObject.tp_hash]
    test rax, rax
    jz .default_hash

    ; tail-call tp_hash(rdi=obj, edx=tag)
    ; tp_hash implementations (int_hash) forward edx to int_unwrap, so the
    ; tag MUST be supplied here -- leaving edx undefined makes int_unwrap
    ; take a random branch and int_hash return the object address.
    mov edx, esi
    leave
    jmp rax

.smallint_hash:
    ; Shared with int_hash / builtin_hash: sign(v) * (|v| mod 2^61-1).
    ; All three must agree or dict and set lookups silently break.
    extern int_hash_i64
    leave
    jmp int_hash_i64

.float_hash:
    ; Inline float: call float_hash for PEP-correct integer-float matching
    extern float_hash
    mov edx, TAG_FLOAT
    call float_hash
    leave
    ret

.bool_hash:
    ; Hash of bool: 0 for False, 1 for True (matches Python int hash)
    mov rax, rdi
    leave
    ret

.none_hash:
    ; Hash of None: constant (avoids -1 which is reserved error value)
    mov eax, 0x48ae2ce5
    leave
    ret

.default_hash:
    ; Default: hash is the object address
    mov rax, rdi
    leave
    ret
END_FUNC obj_hash

;; ============================================================================
;; obj_is_true(rdi=value) -> int (0 or 1)
;; Decodes the Value, then dispatches: int immediate → value != 0, pointer → type-based.
;; ============================================================================
OIT_PAD equ 8               ; rbp and one callee-saved push leave the body
                            ; eight bytes out of 16-alignment, and __bool__,
                            ; __len__ and nb_bool are all reached by a call
                            ; from here -- nb_bool for an int is int_bool,
                            ; which asks GMP.
DEF_FUNC_BARE obj_is_true
    ; rdi is a Value.  This used to open with V_UNPACK -- classify by high16,
    ; subtract a bias, synthesise a tag -- so that the next two instructions
    ; could compare that tag against two constants.  V_IS_INT and V_IS_FLOAT
    ; ask the same two questions of the Value directly, three instructions
    ; each, and the integer arm then needs no decoding at all.
    ;
    ; This runs on every `if`, every `while`, every `and`/`or`, every `not`,
    ; and on the result of every rich comparison.
    V_IS_INT rdi, rsi
    jae .smallint
    V_IS_FLOAT rdi, rsi
    jb .float_tag

    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, OIT_PAD
    mov rbx, rdi

    ; None is false (legacy — TAG_PTR none_singleton)
    lea rax, [rel none_singleton]
    cmp rbx, rax
    je .false

    ; bool False is false (legacy — TAG_PTR bool_false)
    lea rax, [rel bool_false]
    cmp rbx, rax
    je .false

    ; Check for nb_bool in type's number methods
    mov rax, [rbx + PyObject.ob_type]
    test rax, rax
    jz .true
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jz .check_seq_len
    mov rax, [rax + PyNumberMethods.nb_bool]
    test rax, rax
    jz .check_seq_len
    mov rdi, rbx
    ; nb_bool still takes (payload, tag): int_bool hands the pair straight to
    ; int_unwrap, and without the tag it read whatever the caller had left in
    ; edx.  When that happened to be TAG_SMALLINT it tested the POINTER,
    ; which is never zero -- so bool() of a heap-boxed 0 was True, while
    ; `not x` and `if x:` were right, because they go elsewhere.
    mov edx, TAG_PTR
    call rax
    add rsp, OIT_PAD
    pop rbx
    pop rbp
    ret

.check_seq_len:
    ; Check for sq_length in type's sequence methods
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .check_map_len
    mov rax, [rax + PySequenceMethods.sq_length]
    test rax, rax
    jz .check_map_len
    mov rdi, rbx
    call rax
    test rax, rax
    jnz .true
    jmp .false

.check_map_len:
    ; Check for mp_length in type's mapping methods
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .check_dunder_bool
    mov rax, [rax + PyMappingMethods.mp_length]
    test rax, rax
    jz .check_dunder_bool
    mov rdi, rbx
    call rax
    test rax, rax
    jnz .true
    jmp .false

.check_dunder_bool:
    ; Try __bool__ dunder on heaptype
    mov rax, [rbx + PyObject.ob_type]
    mov rdx, [rax + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .true                ; default: objects are truthy

    ; Look up __bool__ in type dict to check for None
    extern dunder_bool
    extern dunder_lookup
    mov rdi, [rbx + PyObject.ob_type]
    lea rsi, [rel dunder_bool]
    call dunder_lookup
    test rax, rax               ; dunder_lookup answers with a Value; 0 is the miss
    jz .check_dunder_len       ; not found (TAG_NULL) → try __len__

    ; Check if __bool__ is None → TypeError
    ; Handle both inline (0, TAG_NONE) and pointer (none_singleton, TAG_PTR) forms
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .dunder_bool_none_error

    ; Call __bool__ via dunder_call_1
    extern dunder_call_1
    mov rdi, rbx
    lea rsi, [rel dunder_bool]
    call dunder_call_1
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx              ; TAG_NULL = call failed
    jz .check_dunder_len

    ; __bool__ returned a result — must be bool
    ; Check TAG_PTR pointing to bool_type
    cmp edx, TAG_PTR
    jne .dunder_bool_type_error
    test rax, rax
    jz .dunder_bool_type_error
    mov rcx, [rax + PyObject.ob_type]
    extern bool_type
    lea r8, [rel bool_type]
    cmp rcx, r8
    jne .dunder_bool_type_error
    ; TAG_PTR bool singleton: convert to 0/1
    lea rcx, [rel bool_true]
    cmp rax, rcx
    sete al
    movzx eax, al
    add rsp, OIT_PAD
    pop rbx
    pop rbp
    ret

.dunder_bool_is_bool:
    ; Result is TAG_BOOL: rax payload is 0 or 1
    add rsp, OIT_PAD
    pop rbx
    pop rbp
    ret

.dunder_bool_none_error:
    extern raise_exception
    extern exc_TypeError_type
    RAISE exc_TypeError_type, "cannot interpret 'NoneType' object as an integer"

.dunder_bool_type_error:
    ; __bool__ didn't return bool — DECREF result and raise TypeError
    ; rax=payload, edx=tag from dunder_call_1
    mov rdi, rax
    mov esi, edx
    DECREF_VAL rdi, rsi
    RAISE exc_TypeError_type, "__bool__ should return bool, returned non-bool"

.check_dunder_len:
    ; Try __len__ dunder
    extern dunder_len
    mov rdi, rbx
    lea rsi, [rel dunder_len]
    call dunder_call_1
    V_UNPACK rax, rdx           ; returns a Value
    test edx, edx              ; TAG_NULL = not found
    jz .true                ; no __len__ → truthy by default

    ; __len__ returned a result — check for negative
    cmp edx, TAG_SMALLINT
    jne .len_check_ptr
    ; SmallInt: check if negative
    test rax, rax
    js .len_negative_error
    ; Non-negative SmallInt: truthy if != 0
    test rax, rax
    setnz al
    movzx eax, al
    add rsp, OIT_PAD
    pop rbx
    pop rbp
    ret

.len_check_ptr:
    ; Non-SmallInt result: use obj_is_true
    push rdx                   ; save tag
    push rax                   ; save payload
    mov rdi, rax
    mov rsi, rdx
    V_PACK rdi, rsi
    call obj_is_true
    mov ecx, eax
    pop rdi                    ; payload
    pop rsi                    ; tag
    DECREF_VAL rdi, rsi
    mov eax, ecx
    add rsp, OIT_PAD
    pop rbx
    pop rbp
    ret

.len_negative_error:
    extern exc_ValueError_type
    RAISE exc_ValueError_type, "__len__() should return >= 0"

.false:
    xor eax, eax
    add rsp, OIT_PAD
    pop rbx
    pop rbp
    ret

.true:
    mov eax, 1
    add rsp, OIT_PAD
    pop rbx
    pop rbp
    ret

.smallint:
    ; An integer immediate is zero exactly when its Value IS the bias, so the
    ; truth test is one compare on the encoded form, with nothing decoded.
    xor eax, eax
    cmp rdi, [rel v_int_bias]
    setne al
    ret

.float_tag:
    ; Inline float: true iff not 0.0 and not -0.0
    V_TO_F64 rdi
    movq xmm0, rdi
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    setne al
    setp cl                    ; NaN is truthy
    or al, cl
    movzx eax, al
    ret

.bool_tag:
    ; TAG_BOOL: payload = 0 (False) or 1 (True)
    mov eax, edi
    and eax, 1
    ret

.none_tag:
    ; TAG_NONE: always false
    xor eax, eax
    ret
END_FUNC obj_is_true


;; ============================================================================
;; type_repr(PyObject *type_obj) -> PyStrObject*
;; Formats "<class 'name'>" for a type object.
;; ============================================================================
TR_TYPE  equ 8
TR_LEN   equ 16
TR_BUF   equ 272            ; 256 bytes, [rbp-272, rbp-16)
TR_FRAME equ 288            ; + 2 pushes = 304
DEF_FUNC type_repr, TR_FRAME
    push rbx
    push r12
    mov [rbp - TR_TYPE], rdi

    mov rax, [rdi + PyTypeObject.tp_name]  ; C string pointer
    test rax, rax
    jz .type_repr_unknown

    lea rbx, [rbp - TR_BUF]
    CSTRING rsi, `<class '`
    xor r12d, r12d
.tr_open:
    movzx eax, byte [rsi]
    test al, al
    jz .tr_module
    inc rsi
    mov [rbx + r12], al
    inc r12
    jmp .tr_open

.tr_module:
    ; CPython qualifies a class with its module: <class '__main__.C'>.  Only
    ; the bare name was printed, so every class repr differed from CPython's.
    ; Builtins live in "builtins" and are shown unqualified.
    mov rdi, [rbp - TR_TYPE]
    mov rdi, [rdi + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .tr_name
    mov [rbp - TR_LEN], rdi         ; the type dict
    CSTRING rdi, "__module__"
    call str_from_cstr
    mov rsi, rax
    mov rdi, [rbp - TR_LEN]
    call dict_get
    V_UNPACK rax, rdx
    test edx, edx
    jz .tr_name
    cmp edx, TAG_PTR
    jne .tr_name
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .tr_name
    mov rdx, [rax + PyStrObject.ob_size]
    test rdx, rdx
    jz .tr_name
    cmp rdx, 8
    jne .tr_copy_module
    lea rdi, [rax + PyStrObject.data]
    CSTRING rsi, "builtins"
    push rax
    push rdx
    call ap_strcmp
    mov ecx, eax                ; the verdict, before the restores overwrite it
    pop rdx
    pop rax
    ; `test eax, eax` was here, AFTER the pop that puts the module string back
    ; in rax -- so it tested the low half of a heap pointer, which is never
    ; zero, and every class defined with builtins as its module printed as
    ; <class 'builtins.C'>.  exec(src, {}) is the ordinary way to get one:
    ; the class body's LOAD_NAME __name__ falls through to builtins.
    test ecx, ecx
    jz .tr_name                 ; module is "builtins": leave it off
.tr_copy_module:
    lea rsi, [rax + PyStrObject.data]
    xor ecx, ecx
.tr_mod_loop:
    cmp rcx, rdx
    jge .tr_mod_done
    cmp r12, 200
    jae .tr_mod_done
    mov al, [rsi + rcx]
    mov [rbx + r12], al
    inc r12
    inc rcx
    jmp .tr_mod_loop
.tr_mod_done:
    mov byte [rbx + r12], '.'
    inc r12

.tr_name:
    ; CPython's repr uses __qualname__, not __name__: a nested class prints
    ; "<class 'M.Inner'>", and a class RENAMED through __name__ keeps the
    ; qualname it was built with.  Only a heaptype records one; a static type
    ; falls through to tp_name, which is the same string.
    mov rax, [rbp - TR_TYPE]
    mov rdi, [rax + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .tr_name_from_tp
    mov [rbp - TR_LEN], rdi
    CSTRING rdi, "__qualname__"
    call str_from_cstr
    mov rsi, rax
    mov rdi, [rbp - TR_LEN]
    call dict_get
    V_UNPACK rax, rdx
    test edx, edx
    jz .tr_name_from_tp
    cmp edx, TAG_PTR
    jne .tr_name_from_tp
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .tr_name_from_tp
    cmp qword [rax + PyStrObject.ob_size], 0
    je .tr_name_from_tp
    lea rsi, [rax + PyStrObject.data]
    jmp .tr_name_loop
.tr_name_from_tp:
    mov rax, [rbp - TR_TYPE]
    mov rsi, [rax + PyTypeObject.tp_name]
.tr_name_loop:
    movzx eax, byte [rsi]
    test al, al
    jz .tr_close
    inc rsi
    cmp r12, 250
    jae .tr_close
    mov [rbx + r12], al
    inc r12
    jmp .tr_name_loop

.tr_close:
    mov byte [rbx + r12], 0x27
    mov byte [rbx + r12 + 1], '>'
    mov byte [rbx + r12 + 2], 0
    mov rdi, rbx
    call str_from_cstr
    pop r12
    pop rbx
    leave
    ret

.type_repr_unknown:
    lea rdi, [rel type_repr_unknown_str]
    call str_from_cstr
    pop r12
    pop rbx
    leave
    ret
END_FUNC type_repr

section .rodata
align 8
extern union_type_or
global type_number_methods
type_number_methods:
    times 15 dq 0
    dq union_type_or          ; nb_or (+120): `int | str` builds a UnionType
    times 20 dq 0

section .rodata
obj_print_newline: db 10
obj_print_null_str: db "<NULL>", 10
type_repr_unknown_str: db "<class '?'>", 0
type_type_name: db "type", 0

section .data
align 8
global type_type
type_type:
    dq 1                      ; ob_refcnt (immortal)
    dq type_type              ; ob_type (self-referential)
    dq type_type_name         ; tp_name
    dq TYPE_OBJECT_SIZE       ; tp_basicsize
    dq 0                      ; tp_dealloc
    dq type_repr              ; tp_repr
    dq type_repr              ; tp_str
    dq 0                      ; tp_hash
    dq type_call              ; tp_call — calling a type creates instances
    dq type_getattr           ; tp_getattr — __name__, tp_dict lookups
    dq type_setattr           ; tp_setattr
    dq 0                      ; tp_richcompare
    dq 0                      ; tp_iter
    dq 0                      ; tp_iternext
    dq 0                      ; tp_init
    dq 0                      ; tp_new
    dq type_number_methods    ; tp_as_number -- PEP 604: int | str
    dq 0                      ; tp_as_sequence
    dq 0                      ; tp_as_mapping
    dq 0                      ; tp_base
    dq 0                      ; tp_dict
    dq 0                      ; tp_mro
    dq TYPE_FLAG_METATYPE     ; tp_flags — instances of `type` are classes
    dq 0                      ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
