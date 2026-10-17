; repr.asm - Container repr implementations (list, tuple, dict, set)
;
; Uses a heap buffer that grows as needed. Each repr function:
; 1. Allocates initial buffer
; 2. Appends opening bracket
; 3. For each element, calls obj_repr and appends result
; 4. Appends closing bracket
; 5. Converts buffer to PyStrObject

%include "macros.inc"
%include "object.inc"


; Set entry layout (must match set.asm)
SET_ENTRY_KEY     equ 8
SET_ENTRY_SIZE    equ 16

extern ap_malloc
extern ap_free
extern ap_realloc
extern obj_repr
extern obj_decref
extern str_from_cstr_heap
extern str_type

; Recursion detection for container repr: the objects currently being repr'd,
; so that a container holding itself prints "..." instead of recursing.
;
; It used to be a fixed 64 entries, and a 65th was a RecursionError -- so
; repr(eval("["*70 + "1" + "]"*70)) failed on a structure CPython prints
; without complaint.  The bound that belongs here is sys.setrecursionlimit's,
; which is the one the repr's own C recursion is measured against; the array
; grows to meet it.
; repr_depth, repr_stack and repr_stack_cap lives in ThreadState (src/include/threadstate.inc).
; eval_exception_unwind resets repr_depth: a raise from inside a nested
; __repr__ skips repr_pop.

section .text
extern ap_realloc
extern recursion_limit

; obj_repr returns NULL both for "this type has no repr" and for "the repr
; raised".  A container propagating that NULL must have an exception pending,
; or the caller sees a bare NULL Value and pushes it.
%macro REPR_ENSURE_EXC 0
    cmp qword [gs:ThreadState.current_exception], 0
    jne %%have_exc
    RAISE exc_TypeError_type, "object has no repr"
%%have_exc:
%endmacro

; Check if ptr is in repr_stack. Returns 1 in eax if found, 0 if not.
; Does NOT clobber rdi.
;
; These three are global because the container reprs are not all in this
; file: dict's views live with dict, and a view can reach itself.
global repr_check_active
repr_check_active:
    mov rcx, [gs:ThreadState.repr_depth]
    test rcx, rcx
    jz .rca_not_found
    mov rax, [gs:ThreadState.repr_stack]
.rca_loop:
    dec rcx
    cmp [rax + rcx*8], rdi
    je .rca_found
    test rcx, rcx
    jnz .rca_loop
.rca_not_found:
    xor eax, eax
    ret
.rca_found:
    mov eax, 1
    ret

; Push ptr onto repr_stack.  Grows it as needed; RecursionError only at the
; interpreter's own recursion limit.  Preserves rdi, which the caller still
; needs.
global repr_push
repr_push:
    mov rax, [gs:ThreadState.repr_depth]
    cmp rax, [rel recursion_limit]
    jge .rp_overflow
    cmp rax, [gs:ThreadState.repr_stack_cap]
    jl .rp_have_room

    ; Double it, starting at the 64 the fixed array used to be.
    push rdi
    push rsi
    mov rsi, [gs:ThreadState.repr_stack_cap]
    test rsi, rsi
    jnz .rp_double
    mov esi, 64
    jmp .rp_sized
.rp_double:
    shl rsi, 1
.rp_sized:
    mov [gs:ThreadState.repr_stack_cap], rsi
    shl rsi, 3
    mov rdi, [gs:ThreadState.repr_stack]
    call ap_realloc
    mov [gs:ThreadState.repr_stack], rax
    pop rsi
    pop rdi
    mov rax, [gs:ThreadState.repr_depth]

.rp_have_room:
    mov rcx, [gs:ThreadState.repr_stack]
    mov [rcx + rax*8], rdi
    inc qword [gs:ThreadState.repr_depth]
    ret
.rp_overflow:
    extern exc_RecursionError_type
    extern raise_exception
extern exc_TypeError_type
    RAISE exc_RecursionError_type, "maximum recursion depth exceeded while getting the repr of an object"

; Pop from repr_stack, with a floor at zero.
;
; eval_exception_unwind ZEROES repr_depth, because a raise from inside a
; nested __repr__ skips the pop and leaves the entries stale.  But an unwind
; can land INSIDE an outer container repr rather than outside it -- a Python
; __repr__ that calls another repr, and catches what that one raises -- and
; the outer repr then still pops on its way out.  Unclamped the counter went
; NEGATIVE, and repr_check_active's `dec rcx` loop walked backwards out of the
; array from there: thirteen lines reproduce it, and CPython's test_wsgiref
; segfaulted in tuple_repr.
;
; This is the shape gc_collecting has, recorded in eval.asm: the unwinder
; cannot tell "escaped the C routine" from "landed inside it" by the fact of
; the raise alone.  Here the floor is enough -- the entries the counter
; indexes were discarded by that same reset, so nothing is lost by counting
; the remainder of an abandoned repr as zero.
;
; It touches no register: callers pop with the finished repr in rax, which the
; first cut of this clamp clobbered -- and a print that answered nothing at all
; is what that looked like.
global repr_pop
repr_pop:
    cmp qword [gs:ThreadState.repr_depth], 0
    je .rp_floor
    dec qword [gs:ThreadState.repr_depth]
.rp_floor:
    ret

; The growable buffer every container repr builds into, as three frame slots.
; All four reprs and the BUF_* macros share this layout, which is why it is
; named once here rather than per function -- STYLE.md's alternative form for a
; file whose functions share a frame.
RB_PTR   equ 8              ; the buffer
RB_USED  equ 16             ; bytes of content written
RB_CAP   equ 24             ; bytes allocated
RB_FRAME equ 32            ; + 4 pushes = 64, 16-aligned
; list and tuple keep one callee-saved register fewer than dict and set.
RB_FRAME3 equ 40           ; + 3 pushes = 64, 16-aligned

; buf_ensure_space(needed)
; Ensures buf has at least 'needed' more bytes available.
; Uses the RB_* slots
; Clobbers rdi, rsi, rax
%macro BUF_ENSURE 1
    mov rax, [rbp - RB_USED]          ; used
    add rax, %1                ; used + needed
    inc rax                    ; +1 for NUL
    cmp rax, [rbp - RB_CAP]          ; compare with capacity
    jbe %%ok
    ; Grow: new_cap = max(cap*2, used+needed+1)
    mov rdi, [rbp - RB_CAP]
    shl rdi, 1                 ; cap * 2
    cmp rdi, rax
    cmovb rdi, rax             ; max(cap*2, needed)
    mov [rbp - RB_CAP], rdi          ; save new capacity
    mov rsi, rdi               ; new size
    mov rdi, [rbp - RB_PTR]           ; old ptr
    call ap_realloc
    mov [rbp - RB_PTR], rax           ; save new ptr
%%ok:
%endmacro

; Append a single byte to buffer
%macro BUF_BYTE 1
    mov rax, [rbp - RB_PTR]
    mov rcx, [rbp - RB_USED]
    mov byte [rax + rcx], %1
    inc qword [rbp - RB_USED]
%endmacro

;; ============================================================================
;; list_repr(PyListObject *self) -> PyStrObject*
;; Returns string like "[1, 2, 3]"
;; ============================================================================
DEF_FUNC list_repr, RB_FRAME3               ; buf ptr, used, capacity
    push rbx                   ; self
    push r12                   ; index
    push r13                   ; count

    mov rbx, rdi               ; rbx = list

    ; Recursion check: if already repr'ing this list, return "[...]"
    mov rdi, rbx
    call repr_check_active
    test eax, eax
    jnz .lr_recursive

    ; Push onto repr stack
    mov rdi, rbx
    call repr_push

    ; Get count
    mov r13, [rbx + PyListObject.ob_size]

    ; Allocate initial buffer (256 bytes)
    mov edi, 256
    call ap_malloc
    mov [rbp - RB_PTR], rax           ; buf ptr
    mov qword [rbp - RB_USED], 0      ; used = 0
    mov qword [rbp - RB_CAP], 256    ; capacity = 256

    ; Append '['
    BUF_BYTE '['

    ; Iterate elements
    xor r12d, r12d             ; index = 0
.lr_loop:
    cmp r12, r13
    jge .lr_done

    ; If not first element, append ", "
    test r12, r12
    jz .lr_no_comma
    BUF_ENSURE 2
    BUF_BYTE ','
    BUF_BYTE ' '
.lr_no_comma:

    ; Get element (payload + tag arrays)
    mov rax, [rbx + PyListObject.ob_item]
    mov rdi, [rax + r12 * 8]      ; payload

    ; Call obj_repr(payload, tag)
    call obj_repr
    test rax, rax
    jz .lr_elem_failed

    ; Append repr string to buffer
    push rax                   ; save repr str for DECREF
    mov rcx, [rax + PyStrObject.ob_size]
    BUF_ENSURE rcx
    ; Copy repr data into buffer
    mov rsi, [rsp]             ; repr str
    lea rsi, [rsi + PyStrObject.data]
    mov rdi, [rbp - RB_PTR]
    add rdi, [rbp - RB_USED]          ; buf + used
    mov rcx, [rsp]
    mov rcx, [rcx + PyStrObject.ob_size]
    add [rbp - RB_USED], rcx          ; used += len
    ; memcpy
    rep movsb

    ; DECREF repr str
    pop rdi
    call obj_decref

.lr_next:
    inc r12
    jmp .lr_loop

.lr_done:
    ; Append ']' and NUL
    BUF_ENSURE 2
    BUF_BYTE ']'
    mov rax, [rbp - RB_PTR]
    mov rcx, [rbp - RB_USED]
    mov byte [rax + rcx], 0    ; NUL terminate

    ; Convert to PyStrObject
    mov rdi, [rbp - RB_PTR]
    call str_from_cstr_heap
    push rax                   ; save result

    ; Free buffer
    mov rdi, [rbp - RB_PTR]
    call ap_free

    pop rax                    ; return str
    mov edx, TAG_PTR           ; ap_free clobbers rdx

    ; Pop from repr stack
    call repr_pop

    pop r13
    pop r12
    pop rbx
    leave
    ret

.lr_elem_failed:
    ; An element's repr failed.  Skipping it left the exception pending with
    ; a perfectly good-looking string as the result, so it surfaced later at
    ; an unrelated instruction instead of at the repr() call.
    mov rdi, [rbp - RB_PTR]
    call ap_free
    call repr_pop
    REPR_ENSURE_EXC
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret

.lr_recursive:
    ; Return "[...]" for recursive reference
    CSTRING rdi, "[...]"
    call str_from_cstr_heap
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_repr

;; ============================================================================
;; tuple_repr(PyTupleObject *self) -> PyStrObject*
;; Returns string like "(1, 2, 3)" or "(1,)" for single-element
;; ============================================================================
DEF_FUNC tuple_repr, RB_FRAME3
    push rbx
    push r12
    push r13

    mov rbx, rdi               ; rbx = tuple

    ; Cycle guard, as list_repr has.  Without it a tuple that reaches itself
    ; -- l = []; t = (l,); l.append(t) -- recursed to a stack overflow.
    mov rdi, rbx
    call repr_check_active
    test eax, eax
    jnz .tr_recursive
    mov rdi, rbx
    call repr_push

    mov r13, [rbx + PyTupleObject.ob_size]

    ; Allocate buffer
    mov edi, 256
    call ap_malloc
    mov [rbp - RB_PTR], rax
    mov qword [rbp - RB_USED], 0
    mov qword [rbp - RB_CAP], 256

    BUF_BYTE '('

    xor r12d, r12d
.tr_loop:
    cmp r12, r13
    jge .tr_done

    test r12, r12
    jz .tr_no_comma
    BUF_ENSURE 2
    BUF_BYTE ','
    BUF_BYTE ' '
.tr_no_comma:

    ; Get element at index r12
    mov rax, [rbx + PyTupleObject.ob_item]
    mov rdi, [rax + r12 * 8]       ; the element Value
    call obj_repr                  ; obj_repr decodes it itself
    test rax, rax
    jz .tr_elem_failed

    push rax
    mov rcx, [rax + PyStrObject.ob_size]
    BUF_ENSURE rcx
    mov rsi, [rsp]
    lea rsi, [rsi + PyStrObject.data]
    mov rdi, [rbp - RB_PTR]
    add rdi, [rbp - RB_USED]
    mov rcx, [rsp]
    mov rcx, [rcx + PyStrObject.ob_size]
    add [rbp - RB_USED], rcx
    rep movsb

    pop rdi
    call obj_decref                ; DECREF repr string

.tr_next:
    inc r12
    jmp .tr_loop

.tr_done:
    ; Single-element tuple needs trailing comma
    cmp r13, 1
    jne .tr_no_trailing
    BUF_ENSURE 1
    BUF_BYTE ','
.tr_no_trailing:

    BUF_ENSURE 2
    BUF_BYTE ')'
    mov rax, [rbp - RB_PTR]
    mov rcx, [rbp - RB_USED]
    mov byte [rax + rcx], 0

    mov rdi, [rbp - RB_PTR]
    call str_from_cstr_heap
    push rax

    mov rdi, [rbp - RB_PTR]
    call ap_free

    pop rax
    mov edx, TAG_PTR           ; ap_free clobbers rdx
    call repr_pop
    pop r13
    pop r12
    pop rbx
    leave
    ret

.tr_elem_failed:
    mov rdi, [rbp - RB_PTR]
    call ap_free
    call repr_pop
    REPR_ENSURE_EXC
    RET_NULL
    pop r13
    pop r12
    pop rbx
    leave
    ret

.tr_recursive:
    CSTRING rdi, "(...)"
    call str_from_cstr_heap
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC tuple_repr

;; ============================================================================
;; dict_repr(PyDictObject *self) -> PyStrObject*
;; Returns string like "{'a': 1, 'b': 2}"
;; Iterates the entries array directly.
;; ============================================================================
DEF_FUNC dict_repr, RB_FRAME
    push rbx                   ; self
    push r12                   ; entry index
    push r13                   ; capacity
    push r14                   ; items printed count

    mov rbx, rdi

    ; Cycle guard: d = {}; d['k'] = d; repr(d) recursed to a segfault.
    mov rdi, rbx
    call repr_check_active
    test eax, eax
    jnz .dr_recursive
    mov rdi, rbx
    call repr_push

    ; Allocate buffer
    mov edi, 256
    call ap_malloc
    mov [rbp - RB_PTR], rax
    mov qword [rbp - RB_USED], 0
    mov qword [rbp - RB_CAP], 256

    BUF_BYTE '{'

    mov r13, [rbx + PyDictObject.capacity]
    xor r12d, r12d             ; entry index = 0
    xor r14d, r14d             ; items printed = 0

.dr_loop:
    cmp r12, r13
    jge .dr_done

    ; Occupied entries have a non-zero key Value
    mov rax, [rbx + PyDictObject.entries]
    imul rcx, r12, DICT_ENTRY_SIZE
    cmp qword [rax + rcx + DictEntry.key], 0
    je .dr_next_entry

    ; Print separator if not first
    test r14, r14
    jz .dr_no_comma
    BUF_ENSURE 2
    BUF_BYTE ','
    BUF_BYTE ' '
.dr_no_comma:

    ; Reload entry data (BUF macros clobber rax, rcx, rdi)
    mov rax, [rbx + PyDictObject.entries]
    imul rcx, r12, DICT_ENTRY_SIZE
    mov rdi, [rax + rcx + DictEntry.key]
    push r12                   ; save entry index across calls
    call obj_repr
    test rax, rax
    jz .dr_elem_failed

    push rax
    mov rcx, [rax + PyStrObject.ob_size]
    BUF_ENSURE rcx
    mov rsi, [rsp]
    lea rsi, [rsi + PyStrObject.data]
    mov rdi, [rbp - RB_PTR]
    add rdi, [rbp - RB_USED]
    mov rcx, [rsp]
    mov rcx, [rcx + PyStrObject.ob_size]
    add [rbp - RB_USED], rcx
    rep movsb
    pop rdi
    call obj_decref

.dr_after_key:
    ; Append ": "
    BUF_ENSURE 2
    BUF_BYTE ':'
    BUF_BYTE ' '

    ; repr(value)
    pop r12                    ; restore entry index
    mov rax, [rbx + PyDictObject.entries]
    imul rcx, r12, DICT_ENTRY_SIZE
    mov rdi, [rax + rcx + DictEntry.value]
    push r12
    call obj_repr
    test rax, rax
    jz .dr_elem_failed

    push rax
    mov rcx, [rax + PyStrObject.ob_size]
    BUF_ENSURE rcx
    mov rsi, [rsp]
    lea rsi, [rsi + PyStrObject.data]
    mov rdi, [rbp - RB_PTR]
    add rdi, [rbp - RB_USED]
    mov rcx, [rsp]
    mov rcx, [rcx + PyStrObject.ob_size]
    add [rbp - RB_USED], rcx
    rep movsb
    pop rdi
    call obj_decref

.dr_after_val:
    pop r12                    ; restore entry index
    inc r14                    ; items printed++

.dr_next_entry:
    inc r12
    jmp .dr_loop

.dr_done:
    BUF_ENSURE 2
    BUF_BYTE '}'
    mov rax, [rbp - RB_PTR]
    mov rcx, [rbp - RB_USED]
    mov byte [rax + rcx], 0

    mov rdi, [rbp - RB_PTR]
    call str_from_cstr_heap
    push rax

    mov rdi, [rbp - RB_PTR]
    call ap_free

    pop rax
    mov edx, TAG_PTR           ; ap_free clobbers rdx
    call repr_pop
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.dr_elem_failed:
    ; The entry index is on the machine stack: both arms above push it across
    ; obj_repr and pop it once that repr comes back, and neither gets there
    ; when it fails.  Without this pop the four register restores below take
    ; each saved register off by one slot -- and one of them is r13, the
    ; interpreter's value stack pointer.
    pop r12
    mov rdi, [rbp - RB_PTR]
    call ap_free
    call repr_pop
    REPR_ENSURE_EXC
    RET_NULL
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.dr_recursive:
    CSTRING rdi, "{...}"
    call str_from_cstr_heap
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_repr

;; ============================================================================
;; set_repr(PySetObject *self) -> PyStrObject*
;; Returns string like "{1, 2, 3}" or "set()" for empty
;; ============================================================================
DEF_FUNC set_repr, RB_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi

    ; Check empty set.  An empty frozenset or subclass is Name(), not set().
    cmp qword [rbx + PyDictObject.ob_size], 0
    jne .sr_notempty
    extern set_type
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel set_type]
    cmp rax, rcx
    jne .sr_empty_named
    lea rdi, [rel set_repr_empty_str]
    call str_from_cstr_heap
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sr_empty_named:
    ; "Name()" -- built with str_from_cstr into a small stack buffer.
    mov rsi, [rax + PyTypeObject.tp_name]
    lea rdi, [rbp - RB_CAP]           ; the three locals are unused on this path
    xor ecx, ecx
.sr_empty_copy:
    cmp ecx, 20
    jge .sr_empty_close
    movzx edx, byte [rsi + rcx]
    test dl, dl
    jz .sr_empty_close
    mov [rdi + rcx], dl
    inc ecx
    jmp .sr_empty_copy
.sr_empty_close:
    mov byte [rdi + rcx], '('
    mov byte [rdi + rcx + 1], ')'
    mov byte [rdi + rcx + 2], 0
    call str_from_cstr_heap
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sr_notempty:
    ; Cycle guard.  The empty-set exit above must stay ahead of the push.
    mov rdi, rbx
    call repr_check_active
    test eax, eax
    jnz .sr_recursive
    mov rdi, rbx
    call repr_push

    mov edi, 256
    call ap_malloc
    mov [rbp - RB_PTR], rax
    mov qword [rbp - RB_USED], 0
    mov qword [rbp - RB_CAP], 256

    ; Anything that is not exactly `set` prints as Name({...}): that is how
    ; CPython renders frozenset, and a subclass of either.  Neither was
    ; handled, so repr(frozenset([1])) came out as {1}.
    extern set_type
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel set_type]
    cmp rax, rcx
    je .sr_no_prefix
    mov r14, [rax + PyTypeObject.tp_name]
.sr_name_loop:
    movzx r13d, byte [r14]      ; not rax: BUF_ENSURE clobbers it
    test r13b, r13b
    jz .sr_name_done
    BUF_ENSURE 1
    mov rcx, [rbp - RB_PTR]
    mov rdx, [rbp - RB_USED]
    mov [rcx + rdx], r13b
    inc qword [rbp - RB_USED]
    inc r14
    jmp .sr_name_loop
.sr_name_done:
    BUF_BYTE '('
.sr_no_prefix:

    BUF_BYTE '{'

    mov r13, [rbx + PyDictObject.capacity]
    xor r12d, r12d
    xor r14d, r14d

.sr_loop:
    cmp r12, r13
    jge .sr_done

    ; SetEntry is SET_ENTRY_SIZE bytes: hash(8) + key Value(8)
    mov rax, [rbx + PyDictObject.entries]
    imul rcx, r12, SET_ENTRY_SIZE
    SET_ENTRY_CLASSIFY rax + rcx, .sr_next, .sr_next
    mov rdi, [rax + rcx + SET_ENTRY_KEY]                      ; key payload

    ; Print separator if not first
    test r14, r14
    jz .sr_no_comma
    BUF_ENSURE 2
    BUF_BYTE ','
    BUF_BYTE ' '
.sr_no_comma:

    ; Reload entry data (BUF macros may clobber rdi, esi)
    mov rax, [rbx + PyDictObject.entries]
    imul rcx, r12, SET_ENTRY_SIZE
    mov rdi, [rax + rcx + SET_ENTRY_KEY]
    push r12
    call obj_repr
    test rax, rax
    jz .sr_elem_failed

    push rax
    mov rcx, [rax + PyStrObject.ob_size]
    BUF_ENSURE rcx
    mov rsi, [rsp]
    lea rsi, [rsi + PyStrObject.data]
    mov rdi, [rbp - RB_PTR]
    add rdi, [rbp - RB_USED]
    mov rcx, [rsp]
    mov rcx, [rcx + PyStrObject.ob_size]
    add [rbp - RB_USED], rcx
    rep movsb
    pop rdi
    call obj_decref

.sr_after_elem:
    pop r12
    inc r14

.sr_next:
    inc r12
    jmp .sr_loop

.sr_done:
    BUF_ENSURE 3
    BUF_BYTE '}'
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel set_type]
    cmp rax, rcx
    je .sr_no_suffix
    BUF_BYTE ')'
.sr_no_suffix:
    mov rax, [rbp - RB_PTR]
    mov rcx, [rbp - RB_USED]
    mov byte [rax + rcx], 0

    mov rdi, [rbp - RB_PTR]
    call str_from_cstr_heap
    push rax

    mov rdi, [rbp - RB_PTR]
    call ap_free

    pop rax
    mov edx, TAG_PTR           ; ap_free clobbers rdx
    call repr_pop
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sr_elem_failed:
    pop r12                    ; the entry index, as in dict_repr
    mov rdi, [rbp - RB_PTR]
    call ap_free
    call repr_pop
    REPR_ENSURE_EXC
    RET_NULL
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sr_recursive:
    CSTRING rdi, "{...}"
    call str_from_cstr_heap
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_repr

section .rodata
set_repr_empty_str: db "set()", 0
