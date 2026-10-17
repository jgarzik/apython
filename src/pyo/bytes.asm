; pyo/bytes.asm - Bytes type implementation
; Immutable sequence of raw bytes with inline storage

%include "macros.inc"
%include "object.inc"

extern str_new_heap
extern exc_UnicodeDecodeError_type
extern exc_new
extern exc_setattr
extern tuple_type
extern tuple_new
extern bytes_method_hex
extern str_from_cstr_heap
extern tuple_new
extern list_append
extern list_new
extern int_is_integer
extern int_unwrap
extern type_is_subtype
extern hash_not_implemented
extern io_buffer_released
extern io_buffer_acquired
extern ap_memcmp
extern ap_memmove
extern exc_MemoryError_type
extern int_fits_i64
extern exc_BufferError_type
extern set_exception
extern ap_realloc
extern ap_malloc
extern ap_free
extern gc_alloc
extern gc_track
extern str_from_cstr
extern str_new
extern ap_memcpy
extern type_type
extern obj_incref
extern obj_decref
extern none_singleton
extern obj_dealloc
extern raise_exception
extern exc_IndexError_type
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_NotImplementedError_type
extern int_type
extern obj_as_index
extern obj_as_index_seq
extern bool_type
extern int_to_i64
extern slice_type
extern slice_indices
extern ap_strcmp

extern bytearray_data
extern bytearray_empty_data
extern bytearray_new
extern bytearray_type
extern memoryview_type
section .text

;; ============================================================================
;; bytes_new(int64_t size) -> PyBytesObject*
;; Allocate a bytes object with room for 'size' bytes
;; ============================================================================
DEF_FUNC bytes_new
    push rbx
    push r12

    mov r12, rdi                ; r12 = size

    ; Allocate: header + size + a NUL.  The terminator is not decoration: a
    ; bytes reaches the kernel as a path, and posix_path_arg compares
    ; ap_strlen against ob_size to refuse an embedded one.  Without it that
    ; comparison read past the end of the object and the answer depended on
    ; whatever byte the allocator happened to leave there -- so
    ; posix.stat(b"/some/path") raised "embedded null byte" or not, by luck.
    ; CPython terminates its bytes for the same reason.
    lea rdi, [r12 + PyBytesObject.data + 1]
    call ap_malloc
    mov rbx, rax                ; rbx = new bytes obj

    ; Fill header
    mov qword [rbx + PyObject.ob_refcnt], 1
    lea rax, [rel bytes_type]
    mov [rbx + PyObject.ob_type], rax
    mov [rbx + PyBytesObject.ob_size], r12
    mov byte [rbx + PyBytesObject.data + r12], 0

    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret
END_FUNC bytes_new

;; ============================================================================
;; bytes_from_data(const void *data, int64_t size) -> PyBytesObject*
;; Allocate a bytes object and copy data into it
;; ============================================================================
DEF_FUNC bytes_from_data, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13

    mov r12, rdi                ; r12 = source data ptr
    mov r13, rsi                ; r13 = size

    ; Allocate: header + size + a NUL -- see bytes_new for why.
    lea rdi, [r13 + PyBytesObject.data + 1]
    call ap_malloc
    mov rbx, rax                ; rbx = new bytes obj

    ; Fill header
    mov qword [rbx + PyObject.ob_refcnt], 1
    lea rax, [rel bytes_type]
    mov [rbx + PyObject.ob_type], rax
    mov [rbx + PyBytesObject.ob_size], r13
    mov byte [rbx + PyBytesObject.data + r13], 0

    ; Copy data in
    lea rdi, [rbx + PyBytesObject.data]
    mov rsi, r12                ; source
    mov rdx, r13                ; length
    call ap_memcpy

    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC bytes_from_data

;; ============================================================================
;; bytes_dealloc(PyObject *self)
;; Data is inline, just free the object
;; ============================================================================
DEF_FUNC_BARE bytes_dealloc
    jmp ap_free
END_FUNC bytes_dealloc

;; ============================================================================
;; bytes_len(PyObject *self) -> int64_t
;; ============================================================================
DEF_FUNC_BARE bytes_len
    mov rax, [rdi + PyBytesObject.ob_size]
    ret
END_FUNC bytes_len

;; ============================================================================
;; bytes_getitem(PyBytesObject *self, int64_t index) -> rax = Value (SmallInt 0-255)
;; sq_item: return byte at index as integer
;; ============================================================================
DEF_FUNC_BARE bytes_getitem
    ; Handle negative index
    test rsi, rsi
    jns .positive
    add rsi, [rdi + PyBytesObject.ob_size]
.positive:
    ; Bounds check
    cmp rsi, [rdi + PyBytesObject.ob_size]
    jge .index_error
    test rsi, rsi
    jl .index_error

    ; Get byte and return as SmallInt
    movzx eax, byte [rdi + PyBytesObject.data + rsi]
    RET_TAG_SMALLINT
    V_PACK rax, rdx             ; return one Value
    ret

.index_error:
    push rdi
    RAISE exc_IndexError_type, "index out of range"
END_FUNC bytes_getitem

;; ============================================================================
;; bytes_subscript(PyBytesObject *self, PyObject *key) -> rax = Value
;; mp_subscript: handles both int and slice keys
;; ============================================================================
DEF_FUNC bytes_subscript
    V_UNPACK rsi, rdx           ; key Value -> (payload, tag)
    push rbx
    push r12

    mov rbx, rdi               ; bytes obj
    mov r12, rsi               ; key

    ; Check if key is a SmallInt (edx = key tag from caller)
    cmp edx, TAG_SMALLINT
    je .bs_int                 ; SmallInt → int path
    cmp edx, TAG_PTR            ; a float key is neither: classify
    jne .bs_int                 ; fully before dereferencing, or raw
                                ; f64 bits get used as an address
    mov rax, [r12 + PyObject.ob_type]
    lea rcx, [rel slice_type]
    cmp rax, rcx
    je .bs_slice

.bs_int:
    ; obj_as_index covers int, bool, an int subclass and __index__, and
    ; raises for anything else.
    mov rdi, r12
    lea rsi, [rel bs_index_msg]
    call obj_as_index_seq
    ; Call bytes_getitem
    mov rdi, rbx
    mov rsi, rax
    call bytes_getitem          ; already returns a Value

    pop r12
    pop rbx
    leave
    ret

.bs_slice:
    ; Slice: create new bytes from slice
    push r13
    push r14
    push r15

    mov rdi, r12               ; slice
    mov rsi, [rbx + PyBytesObject.ob_size]
    call slice_indices
    ; rax = start, rdx = stop, rcx = step
    mov r13, rax               ; start
    mov r14, rdx               ; stop
    mov r15, rcx               ; step

    ; For step=1, simple case
    cmp r15, 1
    jne .bs_step_slice

    ; Compute length
    mov rdi, r14
    sub rdi, r13
    jle .bs_empty

    ; Create new bytes
    push rdi                   ; save length
    call bytes_new
    pop rdi                    ; length
    push rax                   ; save new bytes

    ; Copy data
    lea rsi, [rbx + PyBytesObject.data]
    add rsi, r13               ; src = data + start
    lea rdi, [rax + PyBytesObject.data]  ; dst
    mov rdx, r14
    sub rdx, r13               ; count
    call ap_memcpy

    pop rax                    ; new bytes
    jmp .bs_slice_done

.bs_step_slice:
    ; Extended slice: compute length
    test r15, r15
    jg .bs_pos_step
    ; Negative step.  The span has to be tested before it is divided: a stop
    ; at or above start means the slice is empty, and (start - stop - 1) is
    ; then negative -- which `div` reads as a number near 2^64 and `bytes_new`
    ; tries to allocate.  The positive arm has had this guard all along;
    ; b"..."[5:10:-1] built a bytes whose ob_size was negative, and
    ; b"..."[0:256:-1] was "Fatal: out of memory".
    mov rax, r13
    sub rax, r14
    jle .bs_empty
    dec rax
    mov rcx, r15
    neg rcx
    xor edx, edx
    div rcx
    inc rax
    jmp .bs_have_slen

.bs_pos_step:
    mov rax, r14
    sub rax, r13
    jle .bs_empty
    dec rax
    xor edx, edx
    div r15
    inc rax
    jmp .bs_have_slen

.bs_have_slen:
    push rax                   ; slicelength
    mov rdi, rax
    call bytes_new
    push rax                   ; new bytes obj

    ; Fill items
    xor ecx, ecx              ; i = 0
.bs_step_loop:
    cmp rcx, [rsp + 8]        ; slicelength
    jge .bs_step_done
    ; idx = start + i * step
    mov rax, rcx
    imul rax, r15
    add rax, r13
    movzx edx, byte [rbx + PyBytesObject.data + rax]
    mov rdi, [rsp]             ; new bytes obj
    mov [rdi + PyBytesObject.data + rcx], dl
    inc rcx
    jmp .bs_step_loop

.bs_step_done:
    pop rax                    ; new bytes
    add rsp, 8                 ; discard slicelength
    jmp .bs_slice_done

.bs_empty:
    xor edi, edi
    call bytes_new

.bs_slice_done:
    mov edx, TAG_PTR           ; bytes_new doesn't set tag; ap_memcpy clobbers rdx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

END_FUNC bytes_subscript

section .rodata
bs_index_msg: db `byte indices must be integers or slices, not \x01`, 0
section .text

;; ============================================================================
;; bytes_contains(PyBytesObject *self, PyObject *value) -> int (0/1)
;; sq_contains: check if byte value is in bytes
;; ============================================================================
BCN_ARG   equ 8             ; the operand as it arrived, for the refusal
BCN_FRAME equ 48            ; + 4 pushes = 80, 16-aligned
DEF_FUNC bytes_contains, BCN_FRAME
    mov [rbp - BCN_ARG], rsi
    V_UNPACK rsi, rdx           ; decode the operand Value
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi               ; bytes obj

    ; An int (or bool) searches for a single byte; a bytes searches for a
    ; subsequence.  The operand used to go straight to int_to_i64, which
    ; reads PyIntObject.compact unconditionally -- so 1.5 in b"ab" read raw
    ; f64 bits as an address -- and the subsequence form was missing
    ; entirely, so b"a" in b"xaby" was False.
    cmp edx, TAG_SMALLINT
    je .bc_immediate
    cmp edx, TAG_PTR
    jne .bc_type_error
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .bc_sub
    REQUIRE_INT_TYPE rax, rcx, .bc_type_error
    mov edx, TAG_PTR            ; the macro above clobbered the tag register
    jmp .bc_byte
.bc_immediate:
    mov edx, TAG_SMALLINT
.bc_byte:
    mov rdi, rsi                ; int_to_i64 takes the payload plus the tag
    ; ...and int_to_i64 TRUNCATES a wide one through __gmpz_get_si, so
    ; `(1 << 70) in b"abc"` answered False rather than raising: a number
    ; that does not fit is certainly not a byte.
    cmp edx, TAG_PTR
    jne .bc_have_int
    push rsi
    push rdx
    extern int_fits_i64
    call int_fits_i64
    pop rdx
    pop rsi
    test eax, eax
    jz .bc_range_error
    mov rdi, rsi
.bc_have_int:
    call int_to_i64             ; in edx, not a packed Value
    ; A byte value outside 0..255 can never be present, and CPython raises
    ; for it rather than answering False.
    cmp rax, 255
    ja .bc_range_error

    mov rcx, [rbx + PyBytesObject.ob_size]
    lea rdx, [rbx + PyBytesObject.data]
    xor r8d, r8d               ; index
.bc_loop:
    cmp r8, rcx
    jge .bc_not_found
    movzx edi, byte [rdx + r8]
    cmp rdi, rax
    je .bc_found
    inc r8
    jmp .bc_loop

.bc_sub:
    ; Naive subsequence search: needle is short in practice.
    mov r12, [rsi + PyBytesObject.ob_size]      ; needle length
    mov r13, [rbx + PyBytesObject.ob_size]      ; haystack length
    lea r14, [rsi + PyBytesObject.data]         ; needle data
    test r12, r12
    jz .bc_found                                ; b"" is in everything
    mov rax, r13
    sub rax, r12
    js .bc_not_found                            ; needle longer than haystack
    xor r8d, r8d                                ; start offset
.bc_sub_outer:
    cmp r8, rax
    jg .bc_not_found
    xor r9d, r9d                                ; offset within the needle
.bc_sub_inner:
    cmp r9, r12
    jge .bc_found
    mov rcx, r8
    add rcx, r9
    movzx edi, byte [rbx + PyBytesObject.data + rcx]
    cmp dil, [r14 + r9]
    jne .bc_sub_next
    inc r9
    jmp .bc_sub_inner
.bc_sub_next:
    inc r8
    jmp .bc_sub_outer

.bc_found:
    mov eax, 1
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.bc_not_found:
    xor eax, eax
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.bc_type_error:
    mov rsi, [rbp - BCN_ARG]
    CSTRING rdi, `a bytes-like object is required, not '\x01'`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.bc_range_error:
    RAISE exc_ValueError_type, "byte must be in range(0, 256)"
END_FUNC bytes_contains

;; ============================================================================
;; bytes_repr(PyObject *self) -> PyStrObject*
;; Returns b'...' representation with hex escapes for non-printable bytes
;; ============================================================================
;; bytes and bytearray have identical layouts -- ob_size at +16, data at +24 --
;; so one implementation serves both; only the wrapper text differs.
global bytearray_repr
;; bytes and bytearray no longer share a layout -- a bytearray's data is out
;; of line -- so each hands the renderer its own (pointer, length) pair.
DEF_FUNC bytes_repr
    mov rsi, [rdi + PyBytesObject.ob_size]
    lea rdi, [rdi + PyBytesObject.data]
    xor edx, edx               ; 0 = b'...'
    call bytes_repr_impl
    leave
    ret
END_FUNC bytes_repr

DEF_FUNC bytearray_repr, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    call bytearray_data
    mov rdi, rax
    mov rsi, [rbx + PyByteArrayObject.ob_size]
    mov edx, 1                 ; 1 = bytearray(b'...')
    call bytes_repr_impl
    pop rbx
    leave
    ret
END_FUNC bytearray_repr

;; The render buffer is on the HEAP and sized from the input.  It used to be
;; 1024 bytes of stack with a `if outpos >= 1000: stop` in the loop, so any
;; object whose repr ran past that was silently cut short -- and a cut repr
;; still carries its closing quote, so it looks well-formed.  bytes(range(256))
;; needs 5883 characters and got 1001 of them.
;;
;; Four output bytes per input byte is the worst any byte can do (\xHH), and
;; the wrapper is at most `bytearray(b'` plus `')` plus the NUL, so 4n + 32
;; cannot be exceeded.
BRI_FRAME equ 8             ; + 5 pushes = 48, 16-aligned
DEF_FUNC_LOCAL bytes_repr_impl, BRI_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi               ; the data pointer
    mov r12, rsi               ; length
    mov r14d, edx              ; wrap flag, preserved across the loop

    ; Pick the delimiter the way CPython does: a single quote normally, but a
    ; double quote when the data contains ' and no ", so the quote inside
    ; needs no backslash.
    mov r15d, 0x27
    xor eax, eax               ; saw a single quote?
    xor edx, edx
.br_scan:
    cmp rdx, r12
    jge .br_scan_done
    movzx ecx, byte [rbx + rdx]
    cmp ecx, 0x22              ; a double quote rules the switch out
    je .br_scan_done_squote
    cmp ecx, 0x27
    jne .br_scan_next
    mov eax, 1
.br_scan_next:
    inc rdx
    jmp .br_scan
.br_scan_done:
    test eax, eax
    jz .br_scan_done_squote
    mov r15d, 0x22
.br_scan_done_squote:

    lea rdi, [r12*4 + 32]
    call ap_malloc
    test rax, rax
    jz .br_oom
    mov r13, rax                  ; the render buffer

    xor ecx, ecx               ; output pos
    test r14d, r14d
    jz .br_prefix_b
    mov byte [r13 + 0], 'b'
    mov byte [r13 + 1], 'y'
    mov byte [r13 + 2], 't'
    mov byte [r13 + 3], 'e'
    mov byte [r13 + 4], 'a'
    mov byte [r13 + 5], 'r'
    mov byte [r13 + 6], 'r'
    mov byte [r13 + 7], 'a'
    mov byte [r13 + 8], 'y'
    mov byte [r13 + 9], '('
    mov ecx, 10
.br_prefix_b:
    mov byte [r13 + rcx], 'b'
    mov [r13 + rcx + 1], r15b        ; opening delimiter
    add ecx, 2

    ; Iterate bytes
    xor edx, edx               ; input pos
.br_loop:
    cmp rdx, r12
    jge .br_close

    movzx eax, byte [rbx + rdx]

    ; Printable ASCII (32-126, excluding backslash and quote)?
    cmp eax, 32
    jl .br_hex
    cmp eax, 127
    jge .br_hex
    cmp eax, r15d              ; the delimiter in use
    je .br_escape_quote
    test r14d, r14d            ; CPython's bytearray_repr escapes a single
    jz .br_not_squote          ; quote even under a double-quote delimiter,
    cmp eax, 0x27              ; where its bytes_repr does not
    je .br_escape_squote
.br_not_squote:
    cmp eax, 0x5c              ; backslash
    je .br_escape_bs

    ; Printable: emit directly
    mov [r13 + rcx], al
    inc ecx
    inc edx
    jmp .br_loop

.br_escape_squote:
    mov byte [r13 + rcx], 0x5c     ; backslash
    mov byte [r13 + rcx + 1], 0x27
    add ecx, 2
    inc edx
    jmp .br_loop

.br_escape_quote:
    mov byte [r13 + rcx], 0x5c     ; backslash
    mov [r13 + rcx + 1], r15b      ; the delimiter in use
    add ecx, 2
    inc edx
    jmp .br_loop

.br_escape_bs:
    mov byte [r13 + rcx], 0x5c
    mov byte [r13 + rcx + 1], 0x5c
    add ecx, 2
    inc edx
    jmp .br_loop

.br_hex:
    ; Non-printable: emit \xHH
    ; Common escapes first
    cmp eax, 0x0a
    je .br_escape_n
    cmp eax, 0x0d
    je .br_escape_r
    cmp eax, 0x09
    je .br_escape_t
    cmp eax, 0x00
    je .br_escape_0

    ; General \xHH
    mov byte [r13 + rcx], 0x5c     ; backslash
    mov byte [r13 + rcx + 1], 'x'
    push rdx
    ; High nibble
    mov edx, eax
    shr edx, 4
    lea rsi, [rel hex_digits]
    movzx edx, byte [rsi + rdx]
    mov [r13 + rcx + 2], dl
    ; Low nibble
    and eax, 0x0f
    movzx eax, byte [rsi + rax]
    mov [r13 + rcx + 3], al
    pop rdx
    add ecx, 4
    inc edx
    jmp .br_loop

.br_escape_n:
    mov byte [r13 + rcx], 0x5c
    mov byte [r13 + rcx + 1], 'n'
    add ecx, 2
    inc edx
    jmp .br_loop
.br_escape_r:
    mov byte [r13 + rcx], 0x5c
    mov byte [r13 + rcx + 1], 'r'
    add ecx, 2
    inc edx
    jmp .br_loop
.br_escape_t:
    mov byte [r13 + rcx], 0x5c
    mov byte [r13 + rcx + 1], 't'
    add ecx, 2
    inc edx
    jmp .br_loop
.br_escape_0:
    mov byte [r13 + rcx], 0x5c
    mov byte [r13 + rcx + 1], 'x'
    mov byte [r13 + rcx + 2], '0'
    mov byte [r13 + rcx + 3], '0'
    add ecx, 4
    inc edx
    jmp .br_loop

.br_close:
    mov [r13 + rcx], r15b          ; closing delimiter
    inc ecx
    test r14d, r14d
    jz .br_terminate
    mov byte [r13 + rcx], ')'
    inc ecx
.br_terminate:
    mov byte [r13 + rcx], 0        ; null terminator

    ; The length is already known, so str_new_heap rather than str_from_cstr:
    ; no strlen, and no dependence on the output being NUL-free.
    mov rdi, r13
    movsxd rsi, ecx
    call str_new_heap
    push rax
    push rax                       ; two slots: rsp stays 16-aligned
    mov rdi, r13
    call ap_free
    pop rax
    pop rax
    ; ap_free clobbers edx, and edx is the RETURN TAG this function's callers
    ; propagate straight out.  Without this the repr came back as a Value with
    ; a stale tag -- which read as an int, and only under valgrind, because
    ; without it edx happened to still hold something usable.
    mov edx, TAG_PTR

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.br_oom:
    extern exc_MemoryError_type
    RAISE exc_MemoryError_type, "out of memory"
END_FUNC bytes_repr_impl


;; ============================================================================
;; bytes_getattr(PyBytesObject *self, PyObject *name) -> rax = Value
;; Attribute lookup for bytes: handles decode, hex, etc.
;; ============================================================================
DEF_FUNC bytes_getattr
    ; Nothing of its own.  There used to be a "decode" arm here that answered
    ; the UNBOUND builtin -- no self attached -- and it ran ahead of the
    ; tp_dict entry that decode has had since methods_init registered it.  A
    ; direct `b.decode()` went through LOAD_METHOD and found the dict; `m =
    ; b.decode` went through LOAD_ATTR and found this, so `m()` read whatever
    ; args[0] happened to be as the bytes object.  Every shape that reaches a
    ; builtin through a bound method did the same: `b.decode(*args)` too.
    RET_NULL
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC bytes_getattr



;; ============================================================================
;; bytes_tp_iter(PyBytesObject *self) -> PyBytesIterObject*
;; Create an iterator for bytes
;; ============================================================================
DEF_FUNC bytes_tp_iter, 8            ; 1 push, so rsp is 16-aligned
    push rbx

    mov rbx, rdi               ; save bytes obj

    mov edi, PyBytesIterObject_size
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel bytes_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyBytesIterObject.it_seq], rbx
    mov qword [rax + PyBytesIterObject.it_index], 0

    INCREF rbx

    pop rbx
    leave
    ret
END_FUNC bytes_tp_iter

;; ============================================================================
;; bytes_iter_next(PyBytesIterObject *self) -> PyObject* or NULL
;; Return next byte as SmallInt, or NULL if exhausted
;; ============================================================================
DEF_FUNC_BARE bytes_iter_next
    mov rax, [rdi + PyBytesIterObject.it_seq]   ; bytes obj
    test rax, rax
    jz .exhausted               ; already dropped, or cleared by the collector
    mov rcx, [rdi + PyBytesIterObject.it_index] ; index

    ; Check bounds
    cmp rcx, [rax + PyBytesObject.ob_size]
    jge .exhausted_mark

    ; Get byte and return as an int immediate (0..255 always fits)
    movzx eax, byte [rax + PyBytesObject.data + rcx]
    add rax, [rel v_int_bias]

    ; Advance index
    inc qword [rdi + PyBytesIterObject.it_index]
    ret

.exhausted_mark:
    ; Drop the bytes at exhaustion, as CPython's striter does.  Clear before
    ; releasing -- list_iter_next carries the reason in full.
    mov rax, [rdi + PyBytesIterObject.it_seq]
    mov qword [rdi + PyBytesIterObject.it_seq], 0
    push rdi
    mov rdi, rax
    call obj_decref
    pop rdi
.exhausted:
    RET_NULL
    ret
END_FUNC bytes_iter_next

;; ============================================================================
;; bytes_iter_dealloc(PyObject *self)
;; ============================================================================
DEF_FUNC bytes_iter_dealloc, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; DECREF the bytes obj
    mov rdi, [rbx + PyBytesIterObject.it_seq]
    call obj_decref

    ; Free self
    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC bytes_iter_dealloc

;; ============================================================================
;; iter_self - tp_iter for iterators: return self with INCREF
;; ============================================================================
DEF_FUNC_BARE bytes_iter_self
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret
END_FUNC bytes_iter_self

;; ============================================================================
;; bytes_compare(PyObject *a, PyObject *b, int op) -> PyObject*
;; Rich comparison for bytes (supports == and !=)
;; ============================================================================
extern bool_true
extern bool_false

;; ============================================================================
;; bytes_like_ptr_len(rdi = a Value) -> rax = data, r10 = length, ecx = 1
;;   ecx = 0 when the object has no readable bytes at all.
;;
;; bytes, bytearray and memoryview keep their data in three different places --
;; inline, out of line, and borrowed -- so anything that reads any of them goes
;; through here.  Anything ELSE is asked through its type's tp_as_buffer, which
;; is what makes one added arm reach all forty-odd callers: memoryview(),
;; bytes(), FileIO.write, marshal, sre and the bytes methods.
;; ============================================================================
DEF_FUNC bytes_like_ptr_len, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    ; A Value, which may be an int or a float immediate -- sq_concat and
    ; tp_richcompare are both called with whatever the other operand was.
    V_TEST_PTR rdi, rax
    ja .bpl_no
    test rdi, rdi
    jz .bpl_no
    mov rbx, rdi
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .bpl_bytes
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .bpl_bytearray
    lea rcx, [rel memoryview_type]
    cmp rax, rcx
    je .bpl_memoryview

    ; A subclass counts.  There is no family flag for either, so the answer
    ; comes from the MRO -- and without this `B(bytes)(b"xy") == b"xy"` was
    ; False, because the comparison declined and identity took over.
    mov rdi, rax
    lea rsi, [rel bytes_type]
    call type_is_subtype
    test eax, eax
    jnz .bpl_bytes_sub
    mov rdi, [rbx + PyObject.ob_type]
    lea rsi, [rel bytearray_type]
    call type_is_subtype
    test eax, eax
    jnz .bpl_bytearray_sub

    ; Neither, and no subclass of either: ask the TYPE where its bytes are.
    ; That is what tp_as_buffer is for, and it is how array -- or any exporter
    ; added later -- becomes readable by every one of this function's forty-odd
    ; callers at once, instead of each learning the type by name.
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_buffer]
    test rax, rax
    jz .bpl_no
    mov rdi, rbx
    mov esi, BUF_GET            ; read it and be done; no view outlives this
    call rax
    test ecx, ecx
    jz .bpl_no
    mov r10, rdx                ; the slot answers in rdx; this returns in r10
    pop rbx
    leave
    ret

.bpl_bytearray_sub:
    mov rdi, rbx
    jmp .bpl_bytearray_have

.bpl_bytes_sub:
    mov rdi, rbx
.bpl_bytes:
    mov r10, [rdi + PyBytesObject.ob_size]
    lea rax, [rdi + PyBytesObject.data]
    jmp .bpl_yes
.bpl_bytearray:
.bpl_bytearray_have:
    mov r10, [rdi + PyByteArrayObject.ob_size]
    mov rax, [rdi + PyByteArrayObject.ob_bytes]
    test rax, rax
    jnz .bpl_yes
    lea rax, [rel bytearray_empty_data]
    jmp .bpl_yes
.bpl_memoryview:
    ; release() zeroes mv_buf and leaves mv_len alone, so a released view
    ; would hand back a NULL pointer with the old length -- and every caller
    ; here reads through it.  It is not bytes-like any more; the callers that
    ; should raise instead of declining call memoryview_check first.
    mov rax, [rdi + PyMemoryViewObject.mv_buf]
    cmp rax, MV_RELEASED
    je .bpl_no
    ; A strided view has no contiguous run to point at: mv_buf is its first
    ; item and the rest are mv_stride items apart, in either direction.  It
    ; declines here and is materialised by the one caller that can --
    ; memoryview's own tp_richcompare, which copies before it compares.
    cmp qword [rdi + PyMemoryViewObject.mv_stride], 1
    jne .bpl_no
    mov r10, [rdi + PyMemoryViewObject.mv_len]
.bpl_yes:
    mov ecx, 1
    pop rbx
    leave
    ret
.bpl_no:
    xor ecx, ecx
    pop rbx
    leave
    ret
END_FUNC bytes_like_ptr_len

DEF_FUNC bytes_compare
    V_UNPACK rdi, rcx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, r8            ; right Value -> (payload, tag)
    ; rdi=a, rsi=b, edx=op
    push rbx
    mov ebx, edx              ; save op in ebx

    ; Either side may be bytes OR bytearray -- `b"ab" == bytearray(b"ab")` is
    ; True in CPython, and this function is now both types' tp_richcompare.
    ; The two layouts differ, so each side is reduced to a (pointer, length)
    ; pair before the walk.
    cmp r8d, TAG_PTR          ; b may be an int or float immediate, whose
    jne .bytes_cmp_not_impl   ; payload is not an address
    push rsi
    push rdi
    mov rdi, rsi
    call bytes_like_ptr_len
    pop rdi
    pop rsi
    test ecx, ecx
    jz .bytes_cmp_not_impl
    mov r9, rax               ; b's data
    mov rdx, r10              ; len(b)
    push rdx
    push r9
    call bytes_like_ptr_len   ; rdi is still a
    pop r9
    pop rdx
    test ecx, ecx
    jz .bytes_cmp_not_impl
    mov r8, rax               ; a's data
    mov rcx, r10              ; len(a)

    ; Lexicographic three-way compare, as CPython does: walk the common
    ; prefix, and if that matches, the shorter operand sorts first.  Only
    ; == and != were implemented before, so every ordering comparison
    ; between two bytes fell through to NotImplemented.
    mov r11, rcx
    cmp r11, rdx
    jle .bytes_have_min
    mov r11, rdx
.bytes_have_min:                             ; r11 = min(len(a), len(b))
    xor eax, eax
.bytes_cmp_loop:
    cmp rax, r11
    jge .bytes_prefix_equal
    movzx r10d, byte [r8 + rax]
    cmp r10b, [r9 + rax]                     ; bytes compare unsigned
    jb .bytes_cmp_lt
    ja .bytes_cmp_gt
    inc rax
    jmp .bytes_cmp_loop

.bytes_prefix_equal:
    cmp rcx, rdx
    jb .bytes_cmp_lt
    ja .bytes_cmp_gt
    ; fall through: the two are equal

.bytes_cmp_eq:
    cmp ebx, PY_EQ
    je .bytes_ret_true
    cmp ebx, PY_LE
    je .bytes_ret_true
    cmp ebx, PY_GE
    je .bytes_ret_true
    jmp .bytes_ret_false

.bytes_cmp_lt:
    cmp ebx, PY_LT
    je .bytes_ret_true
    cmp ebx, PY_LE
    je .bytes_ret_true
    cmp ebx, PY_NE
    je .bytes_ret_true
    jmp .bytes_ret_false

.bytes_cmp_gt:
    cmp ebx, PY_GT
    je .bytes_ret_true
    cmp ebx, PY_GE
    je .bytes_ret_true
    cmp ebx, PY_NE
    je .bytes_ret_true
    jmp .bytes_ret_false

.bytes_ret_true:
    RET_TRUE
    pop rbx
    leave
    ret
.bytes_ret_false:
    RET_FALSE
    pop rbx
    leave
    ret
.bytes_cmp_not_impl:
    ; NotImplemented is a NULL return, so op_compare_op can try the reflected
    ; operand and then fall back to identity.  Returning None instead made
    ; b"a" == 5 and every ordering comparison evaluate to None.
    RET_NULL
    pop rbx
    leave
    ret
END_FUNC bytes_compare

;; ============================================================================
;; Data section
;; ============================================================================
section .data

bytes_name_str: db "bytes", 0
bytes_iter_name_str: db "bytes_iterator", 0
hex_digits: db "0123456789abcdef"


; bytes sequence methods
align 8
bytes_sequence_methods:
    dq bytes_len            ; sq_length       +0
    dq bytes_concat         ; sq_concat       +8
    dq bytes_repeat         ; sq_repeat       +16
    dq bytes_getitem        ; sq_item         +24
    dq 0                    ; sq_ass_item     +32
    dq bytes_contains       ; sq_contains     +40
    dq 0                    ; sq_inplace_concat +48
    dq 0                    ; sq_inplace_repeat +56

section .text

;; bytes_latin1_to_str(rdi = data, rsi = length) -> a new str, or 0
;; One code point per byte, which is what makes the round trip through
;; str_mod exact: bytes_mod re-encodes the result the same way.
BL1_SRC   equ 8
BL1_LEN   equ 16
BL1_OUT   equ 24
BL1_POS   equ 32
BL1_FRAME equ 48            ; + 0 pushes = 48

global bytes_latin1_to_str
DEF_FUNC bytes_latin1_to_str, BL1_FRAME
    mov [rbp - BL1_SRC], rdi
    mov [rbp - BL1_LEN], rsi
    lea rdi, [rsi + rsi]
    add rdi, PyStrObject.data + 8
    call ap_malloc
    test rax, rax
    jz .bl1_fail
    mov [rbp - BL1_OUT], rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel str_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyStrObject.ob_hash], -1
    mov rcx, [rbp - BL1_LEN]
    mov [rax + PyStrObject.ob_length], rcx
    mov qword [rbp - BL1_POS], 0
    xor ecx, ecx
.bl1_loop:
    cmp rcx, [rbp - BL1_LEN]
    jge .bl1_done
    mov rdx, [rbp - BL1_SRC]
    movzx eax, byte [rdx + rcx]
    mov rdx, [rbp - BL1_OUT]
    mov r8, [rbp - BL1_POS]
    test al, 0x80
    jnz .bl1_two
    mov [rdx + PyStrObject.data + r8], al
    inc qword [rbp - BL1_POS]
    jmp .bl1_next
.bl1_two:
    mov r9d, eax
    shr r9d, 6
    or r9b, 0xc0
    mov [rdx + PyStrObject.data + r8], r9b
    and eax, 0x3f
    or al, 0x80
    mov [rdx + PyStrObject.data + r8 + 1], al
    add qword [rbp - BL1_POS], 2
.bl1_next:
    inc rcx
    jmp .bl1_loop
.bl1_done:
    mov rax, [rbp - BL1_OUT]
    mov rcx, [rbp - BL1_POS]
    mov [rax + PyStrObject.ob_size], rcx
    mov qword [rax + PyStrObject.data + rcx], 0
    leave
    ret
.bl1_fail:
    xor eax, eax
    leave
    ret
END_FUNC bytes_latin1_to_str

;; bytes_mod_is_byteslike(rdi = a Value) -> eax = 1 when %s would insert its
;; bytes rather than its repr
;; bytes_mod_reject_wide(rdi = a Value)
;; A str argument survives this pipeline only if it is pure ASCII: everything
;; goes out through a latin-1 re-encode, so a code point above 0x7f would come
;; back as a single mangled byte.  CPython rejects a str for %s outright
;; ("%b requires a bytes-like object..."); it accepts one for %r and %a, which
;; is why only the wide ones are refused here rather than all of them.
DEF_FUNC bytes_mod_reject_wide
    V_TEST_PTR rdi, rax
    ja .bmw_ok
    test rdi, rdi
    jz .bmw_ok
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .bmw_is_str
    ; A subclass has str's layout and str's data, so it reaches the same
    ; latin-1 re-encode.  Testing the type pointer alone let one straight
    ; past this guard and into the overflow it exists to prevent:
    ; `class S(str): pass` then b"%s" % (S("中"*20),) wrote past the
    ; allocation, because the size came from code points and the re-encode
    ; assumed two bytes for each of them.
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .bmw_ok
.bmw_is_str:
    mov rax, [rdi + PyStrObject.ob_size]
    cmp rax, [rdi + PyStrObject.ob_length]
    jne .bmw_wide               ; more bytes than code points: not ASCII
.bmw_ok:
    leave
    ret
.bmw_wide:
    ; The class, not the literal word "str": CPython names the argument's own
    ; type, which for a subclass is the subclass.
    mov rsi, rdi
    CSTRING rdi, `%b requires a bytes-like object, or an object that implements __bytes__, not '\x01'`
    call raise_type_error_with_name
END_FUNC bytes_mod_reject_wide

global bytes_mod_is_byteslike
DEF_FUNC_BARE bytes_mod_is_byteslike
    xor eax, eax
    V_TEST_PTR rdi, rcx
    ja .bmi_out
    test rdi, rdi
    jz .bmi_out
    mov rcx, [rdi + PyObject.ob_type]
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    je .bmi_yes
    lea rdx, [rel bytearray_type]
    cmp rcx, rdx
    je .bmi_yes
    lea rdx, [rel memoryview_type]
    cmp rcx, rdx
    jne .bmi_out
.bmi_yes:
    mov eax, 1
.bmi_out:
    ret
END_FUNC bytes_mod_is_byteslike

;; ============================================================================
;; bytes_mod_prepare_args(rdi = the right operand Value) -> a Value to format
;; bytes_mod_release_args(rdi = what it returned)
;;
;; %s on a bytes format means "insert these bytes", not "insert str(x)".
;; Decoding each bytes-like argument as latin-1 turns it into a str whose code
;; points are its bytes, and bytes_mod re-encodes the result the same way, so
;; the round trip is exact.  Anything else is passed through untouched.
;;
;; A tuple is rebuilt only if it contains something bytes-like; a lone
;; argument is converted in place.  Nothing else here allocates, so
;; release_args frees exactly what prepare_args made.
;; ============================================================================
BMP_ARGS  equ 8
BMP_OUT   equ 16
BMP_I     equ 24
BMP_N     equ 32
BMP_FRAME equ 48            ; + 0 pushes = 48

DEF_FUNC_LOCAL bytes_mod_prepare_args, BMP_FRAME
    mov [rbp - BMP_ARGS], rdi
    V_TEST_PTR rdi, rax
    ja .bmp_asis
    test rdi, rdi
    jz .bmp_asis
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .bmp_tuple

    ; A single argument.
    call bytes_mod_reject_wide
    mov rdi, [rbp - BMP_ARGS]
    call bytes_mod_as_str
    test rax, rax
    jnz .bmp_out
.bmp_asis:
    mov rax, [rbp - BMP_ARGS]
    leave
    ret
.bmp_out:
    leave
    ret

.bmp_tuple:
    mov rcx, [rdi + PyTupleObject.ob_size]
    mov [rbp - BMP_N], rcx
    ; Only rebuild if there is something to convert.  Building a copy
    ; unconditionally meant that when str_mod raised -- which it does for a
    ; wrong argument count, and a raise abandons the C stack -- the copy was
    ; never released.
    mov rax, [rdi + PyTupleObject.ob_item]
    xor rdx, rdx
.bmp_scan:
    cmp rdx, rcx
    jge .bmp_asis
    mov rdi, [rax + rdx*8]
    push rax
    push rcx
    push rdx
    sub rsp, 8
    call bytes_mod_reject_wide
    mov rax, [rsp + 8 + 16]
    mov rcx, [rsp + 8 + 8]
    mov rdx, [rsp + 8]
    mov rdi, [rax + rdx*8]
    call bytes_mod_is_byteslike
    add rsp, 8
    pop rdx
    pop rcx
    pop rax
    test eax, eax
    jnz .bmp_rebuild
    inc rdx
    jmp .bmp_scan

.bmp_rebuild:
    mov rdi, [rbp - BMP_N]
    call tuple_new
    test rax, rax
    jz .bmp_asis
    mov [rbp - BMP_OUT], rax
    mov qword [rbp - BMP_I], 0
.bmp_loop:
    mov rcx, [rbp - BMP_I]
    cmp rcx, [rbp - BMP_N]
    jge .bmp_tuple_done
    mov rax, [rbp - BMP_ARGS]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdi, [rax + rcx*8]
    call bytes_mod_as_str
    test rax, rax
    jnz .bmp_store
    mov rax, [rbp - BMP_ARGS]           ; not bytes-like: keep it, with a
    mov rax, [rax + PyTupleObject.ob_item]   ; reference of its own
    mov rcx, [rbp - BMP_I]
    mov rax, [rax + rcx*8]
    push rax
    INCREF_V rax, rcx
    pop rax
.bmp_store:
    mov rcx, [rbp - BMP_OUT]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov rdx, [rbp - BMP_I]
    mov [rcx + rdx*8], rax
    inc qword [rbp - BMP_I]
    jmp .bmp_loop
.bmp_tuple_done:
    mov rax, [rbp - BMP_OUT]
    leave
    ret
END_FUNC bytes_mod_prepare_args

;; ============================================================================
;; bytes_latin1_from_str(rdi = a str whose code points are all below 256)
;;   -> rax = a new bytes, one byte per code point
;;
;; The inverse of bytes_latin1_to_str.  str_mod_impl needs it for a %(name)s
;; key in a BYTES format: the format was decoded to a str to be scanned, so the
;; key comes out as a str, and the mapping is keyed by bytes.
;; ============================================================================
global bytes_latin1_from_str
DEF_FUNC bytes_latin1_from_str
    push rbx
    push r12
    mov r12, rdi
    mov rdi, [r12 + PyStrObject.ob_length]
    call bytes_new
    test rax, rax
    jz .blf_out
    mov rbx, rax
    lea rdi, [rax + PyBytesObject.data]
    lea rsi, [r12 + PyStrObject.data]
    mov rdx, [r12 + PyStrObject.ob_size]
    xor rcx, rcx
    xor r8, r8
.blf_loop:
    cmp rcx, rdx
    jge .blf_done
    movzx eax, byte [rsi + rcx]
    test al, 0x80
    jz .blf_one
    and eax, 0x1f
    shl eax, 6
    movzx r9d, byte [rsi + rcx + 1]
    and r9d, 0x3f
    or eax, r9d
    add rcx, 2
    jmp .blf_store
.blf_one:
    inc rcx
.blf_store:
    mov [rdi + r8], al
    inc r8
    jmp .blf_loop
.blf_done:
    mov [rbx + PyBytesObject.ob_size], r8
    mov rax, rbx
.blf_out:
    pop r12
    pop rbx
    leave
    ret
END_FUNC bytes_latin1_from_str

;; bytes_mod_as_str(rdi = a Value) -> a new str, or 0 if it is not bytes-like
;; str_mod_impl calls it for %s and %b, which is where the conversion is known.
global bytes_mod_as_str
DEF_FUNC bytes_mod_as_str
    V_TEST_PTR rdi, rax
    ja .bma_no
    test rdi, rdi
    jz .bma_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .bma_yes
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .bma_yes
    lea rcx, [rel memoryview_type]
    cmp rax, rcx
    jne .bma_no
.bma_yes:
    call bytes_like_ptr_len     ; rax = data, r10 = length
    test ecx, ecx
    jz .bma_no
    mov rdi, rax
    mov rsi, r10
    call bytes_latin1_to_str
    leave
    ret
.bma_no:
    xor eax, eax
    leave
    ret
END_FUNC bytes_mod_as_str

DEF_FUNC_LOCAL bytes_mod_release_args
    ; Only what prepare_args ALLOCATED: it hands back the caller's own object
    ; when there was nothing to convert, and releasing that decrefs a tuple
    ; nobody gave us -- which surfaced as free() complaining, later, about a
    ; constant.
    cmp rdi, rsi
    je .bmr_out
    V_TEST_PTR rdi, rax
    ja .bmr_out
    test rdi, rdi
    jz .bmr_out
    call obj_decref
.bmr_out:
    leave
    ret
END_FUNC bytes_mod_release_args

;; ============================================================================
;; bytes_mod(PyBytesObject *fmt, PyObject *args) -> PyBytesObject*
;; nb_remainder: implements b"fmt" % args
;; Strategy: convert bytes fmt to str, call str_mod, convert result to bytes
;; ============================================================================
BM_FMT   equ 8
BM_ARGS  equ 16
BM_ORIG  equ 24             ; the caller's own args, to tell a copy from it
BM_FRAME equ 32             ; + 2 pushes = 48, 16-aligned

DEF_FUNC bytes_mod, BM_FRAME
    ; The right operand stays a Value.  It used to be V_UNPACK'd here and the
    ; raw payload handed to str_mod -- which is itself an nb_remainder slot and
    ; unpacks its arguments again.  For `b"%d" % 5` the bare 5 has a zero
    ; high16, so the second unpack read it as a pointer and dereferenced
    ; address 0x5.  A heap int survived by luck, a pointer being its own Value,
    ; which is why tests/cpython/test_int.py:843 never caught it.
    mov [rbp-BM_ARGS], rsi      ; args, still a Value
    V_TEST_PTR rdi, rax         ; ja == not a pointer, so not bytes either
    ja .bm_decline
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    jne .bm_decline
    push rbx
    push r12

    mov [rbp-BM_FMT], rdi     ; fmt bytes obj
    ; The FORMAT is latin-1 decoded too, exactly as the arguments are below.
    ; Copying its bytes verbatim into the temp str left the two halves of the
    ; round trip disagreeing: the arguments went in as one code point per
    ; byte and the result came back out the same way, but a format byte above
    ; 0x7f had arrived as part of a multi-byte sequence, so the re-encode
    ; wrote MORE bytes than the code-point count it had sized the result by.
    ; b"\xe4\xb8\xad" % () overran the allocation and aborted the process.
    ; The arguments are prepared BEFORE the format is decoded, because
    ; preparing them can raise -- a wide str for %s -- and a raise abandons
    ; the C stack.  With the temp str built first it was the thing abandoned,
    ; one leaked str per `b"%s" % ("\u4e2d",)`.
    ;
    ; Any bytes-like argument becomes the str its bytes decode to under
    ; latin-1, one code point per byte.  The result is re-encoded the same way
    ; below, so the bytes come through untouched -- where handing the object
    ; itself to str_mod applied str() to it and `b"%s" % (b"abc",)` produced
    ; b"b'abc'".
    ; The arguments are NOT pre-converted any more.  Doing it here could not
    ; tell %s from %r from %c -- the conversion is not known until str_mod_impl
    ; reads it -- so b"%r" % (b"x",) answered b"'x'" where CPython gives
    ; b"b'x'", and b"%s" % 5 answered b"5" where it is a TypeError.

    mov rdi, [rbp-BM_FMT]
    mov rsi, [rdi + PyBytesObject.ob_size]
    lea rdi, [rdi + PyBytesObject.data]
    call bytes_latin1_to_str
    test rax, rax
    jz .bm_failed_fmt
    mov rbx, rax               ; rbx = temp str

    ; Call str_mod(temp_str, args)
    extern str_mod
    mov rdi, rbx               ; temp str
    mov rsi, [rbp-BM_ARGS]    ; args, a Value -- str_mod is a slot and unpacks
    mov edx, 1                 ; and this one is a BYTES format
    mov ecx, 1                 ; report by RETURNING: see below
    extern str_mod_impl
    call str_mod_impl
    mov r12, rax               ; r12 = result str Value (a str is a pointer)

    ; DECREF temp fmt str.  This is the whole reason str_mod_impl is asked to
    ; return rather than raise: a raise abandons the C stack, so the decoded
    ; copy of the format above was leaked once per malformed `b"%d" % (1, 2)`
    ; -- and putting it somewhere the unwinder frees would be worse, since an
    ; argument's __str__ can run Python and a raise caught inside it would
    ; free a buffer str_mod_impl is still reading.
    mov rdi, rbx
    DECREF_REG rdi

    test r12, r12
    jz .bm_failed

    ; Convert the result str back to bytes, one BYTE per code point -- the
    ; reverse of the latin-1 decoding the arguments went through.  Copying
    ; the str's UTF-8 out verbatim turned every byte above 0x7f back into the
    ; two bytes that encode it, so b"%s" % (b"\xff",) came out as b"\xc3\xbf".
    mov rdi, [r12 + PyStrObject.ob_length]
    call bytes_new
    mov rbx, rax
    lea rdi, [rax + PyBytesObject.data]
    lea rsi, [r12 + PyStrObject.data]
    mov rdx, [r12 + PyStrObject.ob_size]
    xor rcx, rcx                ; read cursor
    xor r8, r8                  ; write cursor
.bm_latin1_loop:
    cmp rcx, rdx
    jge .bm_latin1_done
    movzx eax, byte [rsi + rcx]
    test al, 0x80
    jz .bm_latin1_one
    ; A two-byte sequence encodes one code point below 0x100 here.
    and eax, 0x1f
    shl eax, 6
    movzx r9d, byte [rsi + rcx + 1]
    and r9d, 0x3f
    or eax, r9d
    add rcx, 2
    jmp .bm_latin1_store
.bm_latin1_one:
    inc rcx
.bm_latin1_store:
    mov [rdi + r8], al
    inc r8
    jmp .bm_latin1_loop
.bm_latin1_done:
    ; bytes_new already sized the block and wrote the terminator, and the
    ; loop writes exactly the code-point count it was given: adding a NUL
    ; here put one byte past the end of the allocation.
    mov [rbx + PyBytesObject.ob_size], r8

    ; DECREF result str
    mov rdi, r12
    DECREF_REG rdi

    mov rax, rbx               ; return bytes
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.bm_failed_fmt:
    ; The arguments were prepared first, so they are ours to release here.
    mov rdi, [rbp-BM_ARGS]
    mov rsi, [rbp-BM_ORIG]
    call bytes_mod_release_args
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret

.bm_failed:
    ; str_mod_impl recorded the error rather than raising it, so that the
    ; temporary above could be released; now that it has been, the exception
    ; goes on its way.  Returning the NULL instead would be read as "this
    ; slot declines" -- a number slot has no other way to say NULL -- and the
    ; interpreter would report "unsupported operand type(s) for %" over the
    ; top of the real message.
    extern current_exception
    mov rdi, [rel current_exception]
    test rdi, rdi
    jz .bm_failed_no_exc
    mov qword [rel current_exception], 0
    pop r12
    pop rbx
    leave
    extern raise_exception_obj
    jmp raise_exception_obj     ; takes the reference, does not return
.bm_failed_no_exc:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.bm_decline:
    ; Reached before the pushes, so there is no mirror to unwind.
    xor eax, eax                ; NULL Value = NotImplemented
    leave
    ret
END_FUNC bytes_mod

;; ============================================================================
;; bytearray_mod(rdi = self Value, rsi = args Value) -> a bytearray Value
;;
;; bytearray_type.tp_as_number was 0 and nothing supplied nb_remainder, so
;; `bytearray(b"%d") % 5` was a TypeError where CPython answers
;; bytearray(b'5').  The work is bytes_mod's: a temporary bytes of the same
;; bytes, the shared body, and the result re-wrapped -- which is how
;; bytearray_repr already borrows bytes_repr_impl.
;; ============================================================================
BMOD_ARGS  equ 8
BMOD_TMP   equ 16
BMOD_FRAME equ 40            ; + 1 push = 48, 16-aligned

DEF_FUNC bytearray_mod, BMOD_FRAME
    push rbx
    mov [rbp - BMOD_ARGS], rsi
    V_TEST_PTR rdi, rax
    ja .bam_decline
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    jne .bam_decline

    push rdi
    call bytearray_data         ; rax = the payload, rdx = the length
    pop rdi
    mov rsi, [rdi + PyByteArrayObject.ob_size]
    mov rdi, rax
    call bytes_from_data
    mov [rbp - BMOD_TMP], rax

    mov rdi, rax
    mov rsi, [rbp - BMOD_ARGS]
    call bytes_mod
    mov rbx, rax

    mov rdi, [rbp - BMOD_TMP]
    call obj_decref
    test rbx, rbx
    jz .bam_out                 ; declined or raised; hand it on as it is

    ; bytearray_new copies a (pointer, length) range, which is what the
    ; result bytes is.  bytearray_from_bytes lives in methods/bytes.asm and
    ; would be a circular dependency from here.
    lea rdi, [rbx + PyBytesObject.data]
    mov rsi, [rbx + PyBytesObject.ob_size]
    call bytearray_new
    push rax
    mov rdi, rbx
    call obj_decref
    pop rbx
.bam_out:
    mov rax, rbx
    pop rbx
    leave
    ret

.bam_decline:
    xor eax, eax                ; NULL Value = NotImplemented
    pop rbx
    leave
    ret
END_FUNC bytearray_mod

section .data

; bytes number methods (for % formatting)
align 8
bytes_number_methods:
    dq 0                    ; nb_add -- see list_number_methods: the concat
                            ; is sq_concat so the reflected half is reachable
    dq 0                    ; nb_subtract     +8
    dq bytes_repeat         ; nb_multiply     +16
    dq bytes_mod            ; nb_remainder    +24
    dq 0                    ; nb_divmod       +32
    dq 0                    ; nb_power        +40
    dq 0                    ; nb_negative     +48
    dq 0                    ; nb_positive     +56
    dq 0                    ; nb_absolute     +64
    dq 0                    ; nb_bool         +72
    dq 0                    ; nb_invert       +80
    dq 0                    ; nb_lshift       +88
    dq 0                    ; nb_rshift       +96
    dq 0                    ; nb_and          +104
    dq 0                    ; nb_xor          +112
    dq 0                    ; nb_or           +120
    dq 0                    ; nb_int          +128
    dq 0                    ; nb_float        +136
    dq 0                    ; nb_floor_divide +144
    dq 0                    ; nb_true_divide  +152
    dq 0                    ; nb_index        +160
    dq 0                        ; nb_iadd         +168
    dq 0                        ; nb_isub         +176
    dq 0                        ; nb_imul         +184
    dq 0                        ; nb_irem         +192
    dq 0                        ; nb_ipow         +200
    dq 0                        ; nb_ilshift      +208
    dq 0                        ; nb_irshift      +216
    dq 0                        ; nb_iand         +224
    dq 0                        ; nb_ixor         +232
    dq 0                        ; nb_ior          +240
    dq 0                        ; nb_ifloor_divide +248
    dq 0                        ; nb_itrue_divide +256
    dq 0 ; nb_matmul
    dq 0 ; nb_imatmul

; bytes mapping methods (for subscript with int/slice)
align 8
bytes_mapping_methods:
    dq bytes_len            ; mp_length       +0
    dq bytes_subscript      ; mp_subscript    +8
    dq 0                    ; mp_ass_subscript +16

section .text

;; ============================================================================
;; bytes_concat(left Value, right Value) -> Value
;; bytes had neither sq_concat nor nb_add, so `x + y` on two bytes variables
;; raised TypeError; only the constant-folded form worked.
;; ============================================================================
DEF_FUNC bytes_concat
    BINOP_REQUIRE_LEFT bytes_type, TYPE_FLAG_BYTES_SUBCLASS, 1
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r12, rsi

    V_TEST_PTR rbx, rax
    ja .bc_type_error
    V_TEST_PTR r12, rax
    ja .bc_type_error
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .bc_left_ok
    ; A subclass instance has bytes' layout, which is all the copies below
    ; need; BINOP_REQUIRE_LEFT above already let it through.
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_BYTES_SUBCLASS
    jz .bc_type_error
.bc_left_ok:
    ; The right operand may be any bytes-like: `b"ab" + bytearray(b"cd")` is
    ; b'abcd' in CPython -- bytes, from the left operand -- and requiring an
    ; exact bytes on the right refused it.  r14 carries the right side's
    ; length and r12 becomes its DATA pointer, so the copies below read one
    ; layout whichever type arrived.
    mov rax, [r12 + PyObject.ob_type]
    cmp rax, rcx
    je .bc_right_bytes
    ; A bytes subclass on the right has bytes' layout too.
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_BYTES_SUBCLASS
    jz .bc_right_bytearray
.bc_right_bytes:
    mov r14, [r12 + PyBytesObject.ob_size]
    lea r12, [r12 + PyBytesObject.data]
    jmp .bc_right_done
.bc_right_bytearray:
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .bc_right_ba
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_BYTEARRAY_SUBCLASS
    jz .bc_type_error
.bc_right_ba:
    mov r14, [r12 + PyByteArrayObject.ob_size]
    mov rdi, r12
    call bytearray_data
    mov r12, rax
.bc_right_done:

    mov r13, [rbx + PyBytesObject.ob_size]
    add r13, r14
    lea rdi, [r13 + PyBytesObject.data + 8]
    call ap_malloc
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel bytes_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyBytesObject.ob_size], r13

    push rax
    lea rdi, [rax + PyBytesObject.data]
    lea rsi, [rbx + PyBytesObject.data]
    mov rdx, [rbx + PyBytesObject.ob_size]
    call ap_memcpy
    mov rax, [rsp]
    mov rdi, [rbx + PyBytesObject.ob_size]
    lea rdi, [rax + PyBytesObject.data + rdi]
    mov rsi, r12
    mov rdx, r14
    call ap_memcpy
    pop rax
    mov qword [rax + PyBytesObject.data + r13], 0
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.bc_type_error:
    ; raise_type_error_with_name does not return, so the pushes above are
    ; abandoned with the rest of the C stack; nothing to restore.
    mov rsi, r12
    CSTRING rdi, `can't concat \x01 to bytes`
    extern raise_type_error_with_name
    call raise_type_error_with_name
END_FUNC bytes_concat

;; ============================================================================
;; bytes_repeat(bytes Value, count Value) -> Value
;; ============================================================================
DEF_FUNC bytes_repeat
    BINOP_REQUIRE_LEFT bytes_type, TYPE_FLAG_BYTES_SUBCLASS, 1
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r14, rsi

    mov rsi, r14
    ; Not a count at all: DECLINE rather than raise, so the protocol carries
    ; on to the right operand's __rmul__.  This raised, and `x * R()` for an R
    ; with an __rmul__ never reached it.  op_binary_op words the failure when
    ; nothing else answers either.
    mov rdi, rsi
    push rsi
    extern binop_is_count
    call binop_is_count
    pop rsi
    test eax, eax
    jz .brep_decline
    extern seq_repeat_count
    call seq_repeat_count    ; __index__ counts, and one too big to be an
    mov r12, rax             ; index is refused rather than truncated
    test r12, r12
    jg .brep_positive
    xor r12d, r12d
.brep_positive:

    mov r13, [rbx + PyBytesObject.ob_size]
    mov r14, r13
    imul r14, r12
    jo .brep_overflow
    cmp r14, 0x10000000
    ja .brep_toobig

    lea rdi, [r14 + PyBytesObject.data + 8]
    call ap_malloc
    push rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel bytes_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyBytesObject.ob_size], r14

    lea rdi, [rax + PyBytesObject.data]
    xor ecx, ecx
.brep_loop:
    cmp rcx, r12
    jge .brep_done
    push rcx
    push rdi
    lea rsi, [rbx + PyBytesObject.data]
    mov rdx, r13
    call ap_memcpy
    pop rdi
    pop rcx
    add rdi, r13
    inc rcx
    jmp .brep_loop
.brep_done:
    pop rax
    mov qword [rax + PyBytesObject.data + r14], 0
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.brep_decline:
    xor eax, eax
    xor edx, edx
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.brep_toobig:
    ; Too large to allocate is a MemoryError in CPython; only a count that
    ; does not fit an index is an OverflowError.
    RAISE exc_MemoryError_type, ""
.brep_overflow:
    extern exc_OverflowError_type
    RAISE exc_OverflowError_type, "repeated bytes are too long"
END_FUNC bytes_repeat

;; ============================================================================
;; bytes_type_call(type, args, nargs) -> PyBytesObject*
;; Constructor: bytes(bytes_obj) — copies data, uses passed-in type for subclass
;; ============================================================================
global bytes_type_call

;; ============================================================================
;; byteslike_source(rdi = args, rsi = nargs, rdx = name cstr)
;;   -> rax = ap_malloc'd buffer (0 when empty), rdx = length
;;
;; The raw bytes a bytes() or bytearray() call asks for, gathered before
;; anything is allocated.  CPython accepts no argument, a count, another
;; bytes-like, or any iterable of ints; the constructors here used to accept
;; a bytes object and nothing else, which is what stopped _collections_abc
;; at `type(iter(bytearray()))` and with it every module behind it.
;;
;; The buffer is over-allocated by 8 so bytes objects can zero-terminate.
;; ============================================================================

;; ============================================================================
;; bls_item_byte(rdi = item Value) -> eax = the byte 0..255,
;;                                    -1 not an integer,
;;                                    -2 an integer outside range(0, 256)
;;
;; One item of the iterable handed to bytes() or bytearray().  It used to test
;; V_IS_INT and nothing else, so only an int *immediate* was accepted: every
;; heap PyIntObject -- which under INT_STRESS is every int at all, and
;; otherwise any value past 2^50 -- was reported as "'int' object cannot be
;; interpreted as an integer".  Nothing caught it because `make INT_STRESS=1`
;; silently relinked the unstressed binary.
;;
;; __index__ is honoured because CPython honours it here: bytes([C()]) is b'A'
;; when C.__index__ returns 65.  A value too wide for int64 is out of range
;; rather than a type error, matching bytes([2**100]) -> ValueError.
;; ============================================================================
BIB_ITEM  equ 8
BIB_FRAME equ 16            ; + 0 pushes = 16
DEF_FUNC_LOCAL bls_item_byte, BIB_FRAME
    mov [rbp - BIB_ITEM], rdi
    V_IS_INT rdi, rdx
    jae .bib_immediate

    V_TEST_PTR rdi, rdx
    ja .bib_not_int
    mov rax, [rdi + PyObject.ob_type]
    REQUIRE_INT_TYPE rax, rcx, .bib_try_index

    mov edx, TAG_PTR
    call int_fits_i64
    test eax, eax
    jz .bib_range               ; wider than int64 is certainly not a byte
    mov rdi, [rbp - BIB_ITEM]
    mov edx, TAG_PTR
    call int_unwrap             ; an int subclass wraps its value
    call int_to_i64
    jmp .bib_check

.bib_immediate:
    V_TO_I64 rdi
    mov rax, rdi
    jmp .bib_check

    ; Not an int, but __index__ makes an object usable wherever one is wanted.
    ; obj_as_index raises on anything else, so the protocol is checked first
    ; and a bare object falls out as a type error with the buffer still owned
    ; by the caller.
.bib_try_index:
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_number]
    test rax, rax
    jz .bib_not_int
    cmp qword [rax + PyNumberMethods.nb_index], 0
    je .bib_not_int
    mov edx, TAG_PTR
    call obj_as_index

.bib_check:
    test rax, rax
    jl .bib_range
    cmp rax, 255
    jg .bib_range
    leave
    ret

.bib_not_int:
    mov eax, -1
    leave
    ret

.bib_range:
    mov eax, -2
    leave
    ret
END_FUNC bls_item_byte

;; ============================================================================
;; (continued) bytes_load_source
;; ============================================================================
BLS_ARGS  equ 8
BLS_RANGEMSG equ 16
BLS_NARGS equ 24
BLS_BADITEM equ 56
BLS_BUF   equ 32
BLS_LIST  equ 40
BLS_TMP   equ 48
BLS_ENCMSG equ 64
; The arity refusal's prefix, which names the constructor: both come
; through here and CPython says "bytes()" or "bytearray()".
BLS_ARITY equ 72
; "cannot convert '\x01' object to bytes", which likewise names one or
; the other constructor.
BLS_CONVMSG equ 80
; What __index__ answered, held across int_fits_i64 and int_to_i64.  A frame
; slot rather than a push, because the calls below have to stay aligned.
BLS_IDXOBJ equ 88
BLS_FRAME equ 96            ; + 2 pushes = 112, 16-aligned
DEF_FUNC byteslike_source, BLS_FRAME
    push rbx
    push r12
    mov [rbp - BLS_ARGS], rdi
    mov [rbp - BLS_RANGEMSG], rdx
    mov [rbp - BLS_ENCMSG], rcx
    mov [rbp - BLS_ARITY], r8
    mov [rbp - BLS_CONVMSG], r9
    mov [rbp - BLS_NARGS], rsi
    mov qword [rbp - BLS_LIST], 0
    mov qword [rbp - BLS_BUF], 0
    test rsi, rsi
    jz .bls_empty
    cmp rsi, 1
    jb .bls_empty
    ja .bls_with_encoding

    mov rdi, [rdi]              ; the one argument, as a Value
    V_IS_INT rdi, rax
    jae .bls_count
    V_TEST_PTR rdi, rax
    ja .bls_bad_type
    test rdi, rdi
    jz .bls_bad_type

    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .bls_copy_bytes
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .bls_copy_bytearray
    lea rcx, [rel memoryview_type]
    cmp rax, rcx
    je .bls_copy_view
    extern int_type
    lea rcx, [rel int_type]
    cmp rax, rcx
    je .bls_count_obj
    ; bytes(N(3)) for an int subclass is bytes(3): CPython takes any index
    ; here, and the wrapper is unwrapped on the way to the count.  bool is
    ; an int too, and a static type, so it carries no subclass flag --
    ; bytes(True) was "'bool' object is not iterable".
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_INT_SUBCLASS
    jnz .bls_count_obj
    extern bool_type
    lea rcx, [rel bool_type]
    cmp rax, rcx
    je .bls_count_obj

    ; ...and anything else whose only numeric face is __index__.  CPython's
    ; bytes_new_impl asks PyIndex_Check here, between __bytes__ and
    ; PyBytes_FromObject, so `bytes(C())` for a C whose __index__ answers 3 is
    ; three zero bytes.  This arm named int, an int subclass and bool, so such
    ; an object fell past the buffer test into the iterable road and came back
    ; as "cannot convert 'C' object to bytes".
    ;
    ; The slot is PEEKED and then called directly rather than going through
    ; obj_as_index, for one reason: CPython asks PyNumber_AsSsize_t and CLEARS
    ; a TypeError from it before falling through to PyBytes_FromObject, so an
    ; __index__ that answers a non-int leaves the argument to be tried as an
    ; ITERABLE.  obj_as_index raises instead, non-locally, and there would be
    ; nothing to catch.  Two loads, and only for an argument that is none of
    ; the four named types above.
    mov rcx, [rax + PyTypeObject.tp_as_number]
    test rcx, rcx
    jz .bls_not_index
    mov rcx, [rcx + PyNumberMethods.nb_index]
    test rcx, rcx
    jz .bls_not_index
    call rcx                    ; nb_index answers an owned Value
    test rax, rax
    jz .bls_propagate           ; __index__ itself raised
    mov [rbp - BLS_IDXOBJ], rax
    V_IS_INT rax, rcx
    jae .bls_index_immediate
    V_TEST_PTR rax, rcx
    ja .bls_index_not_int       ; a float immediate is not an int
    mov rcx, [rax + PyObject.ob_type]
    REQUIRE_INT_TYPE rcx, rsi, .bls_index_not_int

    ; A heap int, which may be wider than an index.
    mov rdi, rax
    mov edx, TAG_PTR
    call int_fits_i64
    test eax, eax
    jz .bls_index_overflow
    mov rdi, [rbp - BLS_IDXOBJ]
    mov edx, TAG_PTR
    call int_to_i64
    mov rbx, rax
    mov rdi, [rbp - BLS_IDXOBJ]
    call obj_decref
    jmp .bls_count_have

.bls_index_immediate:
    V_TO_I64 rax
    mov rbx, rax
    jmp .bls_count_have

.bls_index_not_int:
    ; __index__ answered something that is not an int at all.  Nothing was
    ; raised, so falling through to the iterable road IS CPython's cleared
    ; TypeError: bytes(C()) for such a C is "cannot convert 'C' object to
    ; bytes", unless C is also iterable, in which case it is iterated.
    ;
    ; The road resumed at expects rdi = the argument and rax = its TYPE, the
    ; two the dispatch above set up.  Both were spent getting here, so both are
    ; put back; reading a float immediate's bits as a type was a segfault.
    mov rdi, [rbp - BLS_IDXOBJ]
    DECREF_V rdi, rcx
    mov rdi, [rbp - BLS_ARGS]
    mov rdi, [rdi]
    mov rax, [rdi + PyObject.ob_type]
    jmp .bls_not_index

.bls_index_overflow:
    ; Named for the ORIGINAL argument, as PyNumber_AsSsize_t names it:
    ; bytes(2**70) says 'int' and bytes(C()) says 'C'.
    mov rdi, [rbp - BLS_IDXOBJ]
    call obj_decref
    mov rdi, [rbp - BLS_ARGS]
    mov rdi, [rdi]
    extern value_type
    call value_type
    mov rsi, rax
    CSTRING rdi, `cannot fit '\x01' into an index-sized integer`
    extern type_name_message
    call type_name_message
    mov rsi, rax
    lea rdi, [rel exc_OverflowError_type]
    extern raise_exception
    call raise_exception
    ud2

.bls_not_index:
    extern str_type
extern codec_error_id
extern exc_LookupError_type
extern str_set_length
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .bls_need_encoding

    ; A buffer EXPORTER is copied as bytes, not iterated as a sequence of
    ; ints.  CPython's bytes() asks for the buffer first, so
    ; bytes(array('i', [1, 2])) is the array's eight raw bytes -- here it fell
    ; through to the iterable road and answered b'\x01\x02', two bytes taken
    ; from the two ITEMS.  The explicit arms above are bytes, bytearray and
    ; memoryview; this is everything else that can hand over a run of bytes.
    mov rax, [rax + PyTypeObject.tp_as_buffer]
    test rax, rax
    jz .bls_dunder_buffer
    jmp .bls_copy_buffer

.bls_dunder_buffer:
    ; ...and a class written in Python exports through __buffer__ (PEP 688);
    ; its view is then laid out end to end like any other memoryview.
    extern memoryview_from_dunder_buffer
    call memoryview_from_dunder_buffer
    test rax, rax
    jnz .bls_dunder_view
    test ecx, ecx
    jnz .bls_propagate          ; __buffer__ raised
    mov rdi, [rbp - BLS_ARGS]
    mov rdi, [rdi]
    jmp .bls_iterable
.bls_dunder_view:
    push rax
    sub rsp, 8
    mov rdi, rax
    call memoryview_as_bytes
    add rsp, 8
    pop rdi
    push rax
    sub rsp, 8
    call obj_decref             ; the view; its bytes are copied out
    add rsp, 8
    pop rax
    test rax, rax
    jz .bls_empty
    mov [rbp - BLS_LIST], rax   ; released below, with the list's arm
    mov rbx, [rax + PyBytesObject.ob_size]
    lea r12, [rax + PyBytesObject.data]
    jmp .bls_copy

.bls_copy_buffer:
    ; bytes_like_ptr_len asks the slot and hands back (data, length); the copy
    ; below is the same one the bytes and bytearray arms make.
    mov rdi, [rbp - BLS_ARGS]
    mov rdi, [rdi]
    call bytes_like_ptr_len
    test ecx, ecx
    jz .bls_iterable            ; the slot declined after all
    test r10, r10
    jz .bls_empty
    mov rbx, rax                ; the source bytes
    mov r12, r10                ; and how many
    lea rdi, [r12 + 8]
    call ap_malloc
    test rax, rax
    jz .bls_empty
    push rax
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    call ap_memcpy
    pop rax
    mov rdx, r12
    pop r12
    pop rbx
    leave
    ret

.bls_empty:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret

    ; bytes(n) / bytearray(n): n zero bytes.
.bls_count:
    V_TO_I64 rdi
    mov rbx, rdi
    jmp .bls_count_have
.bls_count_obj:
    mov edx, TAG_PTR
    ; A count that does not fit is an OverflowError, not a truncation:
    ; bytes(2**70) answered b"" and bytearray(-(2**70)) "negative count".
    push rdi
    extern int_fits_i64
    call int_fits_i64
    pop rdi
    test eax, eax
    jz .bls_count_overflow
    mov edx, TAG_PTR
    call int_to_i64
    mov rbx, rax
.bls_count_have:
    test rbx, rbx
    js .bls_negative
    jz .bls_empty
    lea rdi, [rbx + 8]
    call ap_malloc
    mov r12, rax
    mov rdi, rax
    xor esi, esi
    lea rdx, [rbx + 8]
    extern ap_memset
    call ap_memset
    mov rax, r12
    mov rdx, rbx
    pop r12
    pop rbx
    leave
    ret

.bls_copy_bytes:
    mov rbx, [rdi + PyBytesObject.ob_size]
    lea r12, [rdi + PyBytesObject.data]
    jmp .bls_copy

.bls_copy_bytearray:
    mov rbx, [rdi + PyByteArrayObject.ob_size]
    call bytearray_data
    mov r12, rax
    jmp .bls_copy

.bls_copy_view:
    ; A memoryview used to fall through to the iterable path, which takes one
    ; byte per ITEM -- so bytes(m.cast('I')) was "bytes must be in range(0,
    ; 256)" for a view whose items are four bytes wide, and a strided view
    ; has no contiguous run to read at all.  memoryview_as_bytes answers
    ; both: it lays the items out end to end, which is what bytes() means.
    extern memoryview_as_bytes
    call memoryview_as_bytes
    test rax, rax
    jz .bls_empty
    mov [rbp - BLS_LIST], rax   ; released below, with the list's arm
    mov rbx, [rax + PyBytesObject.ob_size]
    lea r12, [rax + PyBytesObject.data]

.bls_copy:
    test rbx, rbx
    jz .bls_copy_empty
    lea rdi, [rbx + 8]
    call ap_malloc
    push rax
    mov rdi, rax
    mov rsi, r12
    mov rdx, rbx
    call ap_memcpy
    pop rax
    mov qword [rax + rbx], 0
    mov rdx, rbx
    push rax
    push rdx
    mov rdi, [rbp - BLS_LIST]   ; the memoryview's temporary, if there was one
    test rdi, rdi
    jz .bls_copy_no_temp
    mov qword [rbp - BLS_LIST], 0
    call obj_decref
.bls_copy_no_temp:
    pop rdx
    pop rax
    pop r12
    pop rbx
    leave
    ret

.bls_copy_empty:
    mov rdi, [rbp - BLS_LIST]
    test rdi, rdi
    jz .bls_empty
    mov qword [rbp - BLS_LIST], 0
    call obj_decref
    jmp .bls_empty

    ; Any other iterable: materialise it as a list, then take one byte per
    ; item.  Going through list() rather than the iterator protocol directly
    ; keeps __iter__/__next__ on heap types working for free.
.bls_iterable:
    ; A non-iterable has CPython's own wording here -- "cannot convert 'X'
    ; object to bytes" -- and list() below would report it as not iterable.
    extern get_iterator_opt
    mov rsi, TAG_PTR
    call get_iterator_opt
    test rax, rax
    jz .bls_bad_type
    V_UNPACK rax, rdx
    mov rdi, rax
    call obj_decref
    extern list_type
    extern list_type_call
    lea rdi, [rel list_type]
    mov rsi, [rbp - BLS_ARGS]
    mov edx, 1
    call list_type_call
    V_UNPACK rax, rdx
    test rax, rax
    jz .bls_bad_type
    mov [rbp - BLS_LIST], rax
    mov rbx, [rax + PyListObject.ob_size]
    test rbx, rbx
    jz .bls_iter_empty
    lea rdi, [rbx + 8]
    call ap_malloc
    mov [rbp - BLS_BUF], rax
    mov r12, rax
    mov rax, [rbp - BLS_LIST]
    mov rax, [rax + PyListObject.ob_item]
    xor ecx, ecx
.bls_iter_loop:
    cmp rcx, rbx
    jge .bls_iter_done
    mov rdi, [rax + rcx*8]
    push rax                    ; bls_item_byte clobbers the caller-saved regs
    push rcx                    ; two pushes, so rsp stays 16-byte aligned
    call bls_item_byte
    mov edx, eax                ; the result, before `pop rax` overwrites it
    pop rcx
    pop rax
    test edx, edx
    js .bls_iter_reject
    mov [r12 + rcx], dl
    inc rcx
    jmp .bls_iter_loop

.bls_iter_reject:
    ; -1 = not an integer at all, -2 = an integer outside range(0, 256).
    mov rdi, [rax + rcx*8]      ; the offending item, for the message
    cmp edx, -2
    je .bls_iter_range
    jmp .bls_iter_bad
.bls_iter_done:
    mov qword [r12 + rbx], 0
    mov rdi, [rbp - BLS_LIST]
    call obj_decref
    mov rax, r12
    mov rdx, rbx
    pop r12
    pop rbx
    leave
    ret
.bls_iter_empty:
    mov rdi, [rbp - BLS_LIST]
    call obj_decref
    jmp .bls_empty
    ; raise_exception abandons this frame, so the list and the buffer have to
    ; go first or a loop that keeps catching the error keeps leaking them.
.bls_release:
    mov rdi, [rbp - BLS_LIST]
    test rdi, rdi
    jz .bls_release_buf
    mov qword [rbp - BLS_LIST], 0
    call obj_decref
.bls_release_buf:
    mov rdi, [rbp - BLS_BUF]
    test rdi, rdi
    jz .bls_released
    mov qword [rbp - BLS_BUF], 0
    call ap_free
.bls_released:
    ret

.bls_iter_bad:
    ; A non-integer item is a TypeError, as it is in CPython; only an integer
    ; that will not fit in a byte is a ValueError.
    mov [rbp - BLS_BADITEM], rdi
    call .bls_release
    extern raise_type_error_with_name
    CSTRING rdi, `'\x01' object cannot be interpreted as an integer`
    mov rsi, [rbp - BLS_BADITEM]
    call raise_type_error_with_name
.bls_iter_range:
    call .bls_release
    lea rdi, [rel exc_ValueError_type]
    ; bytes() and bytearray() word this differently; the caller says which.
    mov rsi, [rbp - BLS_RANGEMSG]
    call raise_exception

    ; bytes(s, encoding[, errors]) / bytearray(s, encoding[, errors]).  The
    ; arguments are str.encode's, in str.encode's order, so that is what runs
    ; them -- one decoder table, not two.
.bls_with_encoding:
    cmp rsi, 3
    ja .bls_too_many
    ; The encoding argument is checked before the subject, as CPython's is:
    ; bytes(1, 2) complains about the 2, not about the 1.
    mov rax, [rdi + 8]
    V_TEST_PTR rax, rcx
    ja .bls_enc_bad_encoding
    test rax, rax
    jz .bls_enc_bad_encoding
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .bls_enc_bad_encoding
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .bls_enc_no_str
    test rdi, rdi
    jz .bls_enc_no_str
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .bls_encode
    mov [rbp - BLS_TMP], rdi
    mov rdi, rax
    lea rsi, [rel str_type]
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jz .bls_enc_no_str

.bls_encode:
    mov rdi, [rbp - BLS_ARGS]
    mov rsi, [rbp - BLS_NARGS]
    extern str_method_encode
    call str_method_encode
    V_UNPACK rax, rdx
    test rax, rax
    jz .bls_bad_type
    mov [rbp - BLS_LIST], rax   ; the release slot: it wants a decref too
    mov rbx, [rax + PyBytesObject.ob_size]
    lea r12, [rax + PyBytesObject.data]
    lea rdi, [rbx + 8]
    call ap_malloc
    mov [rbp - BLS_BUF], rax
    mov rdi, rax
    mov rsi, r12
    mov rdx, rbx
    call ap_memcpy
    mov rax, [rbp - BLS_BUF]
    mov qword [rax + rbx], 0
    mov rdi, [rbp - BLS_LIST]
    mov qword [rbp - BLS_LIST], 0
    call obj_decref
    mov rax, [rbp - BLS_BUF]
    mov rdx, rbx
    pop r12
    pop rbx
    leave
    ret

.bls_count_overflow:
    extern exc_OverflowError_type
    RAISE exc_OverflowError_type, \
          "cannot fit 'int' into an index-sized integer"
.bls_negative:
    RAISE exc_ValueError_type, "negative count"
.bls_enc_no_str:
    RAISE exc_TypeError_type, "encoding without a string argument"
.bls_enc_bad_encoding:
    mov rdi, [rbp - BLS_ARGS]
    mov rsi, [rdi + 8]
    mov rdi, [rbp - BLS_ENCMSG]
    extern raise_type_error_with_name
    call raise_type_error_with_name
.bls_need_encoding:
    RAISE exc_TypeError_type, "string argument without an encoding"
.bls_too_many:
    ; Which constructor this is comes from the range message the caller set:
    ; both go through byteslike_source, and CPython names each.
    mov rsi, [rbp - BLS_NARGS]
    CSTRING rdx, " given)"
    mov rdi, [rbp - BLS_ARITY]
    extern raise_type_error_counted
    jmp raise_type_error_counted
.bls_bad_type:
    ; Reached both when the argument is the wrong TYPE and when materialising
    ; it RAISED -- list_type_call answers 0 for either.  Substituting "cannot
    ; convert 'map' object to bytes" over a pending exception threw the real
    ; one away: a generator or a map that raises part way through reported a
    ; type error, which is exactly the shape str.join was fixed for.
    extern current_exception
    cmp qword [rel current_exception], 0
    jne .bls_propagate
    mov rdi, [rbp - BLS_ARGS]
    mov rsi, [rdi]
    mov rdi, [rbp - BLS_CONVMSG]
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

.bls_propagate:
    ; A (0, 0) return means "empty", so there is no value to report failure
    ; with: the exception already pending is carried out the way every other
    ; error in this function leaves, non-locally.
    pop r12
    pop rbx
    leave
    extern eval_exception_unwind
    jmp eval_exception_unwind
END_FUNC byteslike_source

BTC_TYPE  equ 8
BTC_BUF   equ 16
BTC_LEN   equ 24
BTC_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC bytes_type_call, BTC_FRAME
    ; rdi=type, rsi=args, rdx=nargs
    push rbx
    mov [rbp - BTC_TYPE], rdi

    ; CPython asks the object for __bytes__ before it tries a buffer, an
    ; index or an iterable, and this asked nothing -- so `bytes(headers)` on
    ; wsgiref's Headers, which has one, fell through to the iterable path and
    ; indexed the mapping with integers until something asked an int to
    ; .lower().  Only a HEAPTYPE instance is asked: none of the builtins
    ; byteslike_source handles natively defines the dunder, so the order
    ; between them is not observable, and `bytes(5)` stays five zero bytes.
    cmp rdx, 1
    jne .btc_no_dunder
    mov rax, [rsi]                      ; args[0]
    V_TEST_PTR rax, rcx
    ja .btc_no_dunder
    mov rcx, [rax + PyObject.ob_type]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .btc_no_dunder
    mov [rbp - BTC_BUF], rsi            ; args, across the call
    mov [rbp - BTC_LEN], rdx            ; nargs
    mov rdi, rax
    CSTRING rsi, "__bytes__"
    extern dunder_call_1
    call dunder_call_1
    test rax, rax
    jz .btc_dunder_absent               ; absent, not callable, or it raised
    V_TEST_PTR rax, rcx
    ja .btc_dunder_bad
    mov rcx, [rax + PyObject.ob_type]
    ; PyBytes_Check, which takes a SUBCLASS, where this asked for the exact
    ; type -- so a __bytes__ answering a `class Sub(bytes)` instance was
    ; refused as "returned non-bytes".  The flag is set on bytes_type itself,
    ; so type_from_parts propagates it to every subclass.
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_BYTES_SUBCLASS
    jz .btc_dunder_bad

    ; Whose type the answer gets is two rules, not one.  bytes() hands over the
    ; dunder's own object, subclass and all -- measured: bytes(C()) whose
    ; __bytes__ answers a Sub is a Sub.  A SUBCLASS constructor ADOPTS it
    ; instead, which is CPython's bytes_subtype_new: Other(C()) is an Other.
    mov rdx, [rbp - BTC_TYPE]
    lea rcx, [rel bytes_type]
    cmp rdx, rcx
    jne .btc_dunder_adopt
    pop rbx
    leave
    ret

.btc_dunder_adopt:
    ; Copied into a buffer of the shape byteslike_source hands back -- len + 8,
    ; and freed by .btc_no_free -- so the allocation tail below, which already
    ; honours TP_DICT_AT_TAIL, the GC head and the NUL, is reached unchanged.
    ; Borrowing the dunder object's own data instead would hand that tail a
    ; pointer into the middle of a live object for it to ap_free.
    mov rbx, rax                        ; the dunder's bytes, ours to release
    mov rcx, [rbx + PyBytesObject.ob_size]
    mov [rbp - BTC_LEN], rcx
    lea rdi, [rcx + 8]
    call ap_malloc
    mov [rbp - BTC_BUF], rax
    mov rdx, [rbp - BTC_LEN]
    test rdx, rdx
    jz .btc_adopt_copied
    mov rdi, rax
    lea rsi, [rbx + PyBytesObject.data]
    call ap_memcpy
.btc_adopt_copied:
    mov rdi, rbx
    call obj_decref                     ; the dunder's answer was ours
    jmp .btc_have_buf
.btc_dunder_bad:
    mov rdi, rax
    ; "__bytes__ returned non-bytes (type int)" -- the type is the point.
    CSTRING rsi, "__bytes__ returned non-bytes (type "
    CSTRING rdx, ")"
    extern raise_typed_message
    call raise_typed_message
.btc_dunder_absent:
    cmp qword [rel current_exception], 0
    jne .btc_propagate                  ; it raised: that is the answer
    mov rsi, [rbp - BTC_BUF]
    mov rdx, [rbp - BTC_LEN]
.btc_no_dunder:
    mov rdi, rsi
    mov rsi, rdx
    lea rdx, [rel bytes_range_msg]
    lea rcx, [rel bytes_enc_msg]
    lea r8, [rel bytes_arity_msg]
    lea r9, [rel bytes_conv_msg]
    call byteslike_source
    mov [rbp - BTC_BUF], rax
    mov [rbp - BTC_LEN], rdx

.btc_have_buf:
    mov rcx, [rbp - BTC_LEN]
    mov rdx, [rbp - BTC_TYPE]
    lea rdi, [rcx + PyBytesObject.data + 8]
    ; A subclass carrying a __dict__ at its tail needs one more word for it.
    cmp qword [rdx + PyTypeObject.tp_dictoffset], TP_DICT_AT_TAIL
    jne .btc_no_tail
    add rdi, 8
.btc_no_tail:
    test qword [rdx + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .btc_plain_alloc
    mov rsi, rdx
    call gc_alloc
    jmp .btc_alloc_done
.btc_plain_alloc:
    call ap_malloc
    mov qword [rax + PyBytesObject.ob_refcnt], 1
    mov rdx, [rbp - BTC_TYPE]
    mov [rax + PyBytesObject.ob_type], rdx
.btc_alloc_done:
    mov rbx, rax
    mov rcx, [rbp - BTC_LEN]
    mov [rbx + PyBytesObject.ob_size], rcx
    mov rdx, [rbp - BTC_TYPE]
    inc qword [rdx + PyObject.ob_refcnt]

    test rcx, rcx
    jz .btc_no_copy
    lea rdi, [rbx + PyBytesObject.data]
    mov rsi, [rbp - BTC_BUF]
    mov rdx, rcx
    call ap_memcpy
.btc_no_copy:
    mov rcx, [rbp - BTC_LEN]
    mov qword [rbx + PyBytesObject.data + rcx], 0
    mov rdx, [rbp - BTC_TYPE]
    cmp qword [rdx + PyTypeObject.tp_dictoffset], TP_DICT_AT_TAIL
    jne .btc_no_tail_zero
    mov qword [rbx + PyBytesObject.data + rcx + 8], 0    ; the tail __dict__
.btc_no_tail_zero:
    mov rdi, [rbp - BTC_BUF]
    test rdi, rdi
    jz .btc_no_free
    call ap_free
.btc_no_free:

    mov rdx, [rbp - BTC_TYPE]
    test qword [rdx + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .btc_no_track
    mov rdi, rbx
    call gc_track
.btc_no_track:
    mov rax, rbx
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.btc_propagate:
    extern eval_saved_r13
    mov [rel eval_saved_r13], r13
    pop rbx
    leave
    extern eval_exception_unwind
    jmp eval_exception_unwind
END_FUNC bytes_type_call

;; ============================================================================
;; bytes_hash(rdi = PyBytesObject *) -> rax = the hash
;;
;; bytes had no tp_hash at all, so obj_hash fell through to its address: two
;; equal bytes objects hashed differently, and every dict and set holding
;; them was silently wrong.  A small dict hid it, because dict_lookup probes
;; and compares keys -- but 200 distinct byte strings gave 0 lookups found
;; and a set of 400.  posix.environ is a dict[bytes, bytes], which is how
;; this surfaced.
;;
;; FNV-1a, as str_hash computes it, and equal to str_hash's answer for the
;; same bytes.  That is legal -- unequal objects may share a hash, and
;; bytes_compare keeps them apart -- and it is what makes this a transcription
;; rather than a second algorithm to keep in step.
;;
;; No cache: PyBytesObject has no ob_hash field, and adding one means every
;; constructor has to initialise it or a new object reads a stale value.
;; Nothing hashes bytes in a hot loop.
;; ============================================================================
DEF_FUNC_BARE bytes_hash
    mov rcx, [rdi + PyBytesObject.ob_size]
    lea rsi, [rdi + PyBytesObject.data]
    mov rax, 0xcbf29ce484222325     ; FNV offset basis
    mov rdx, 0x100000001b3          ; FNV prime
.bh_loop4:
    cmp rcx, 4
    jb .bh_tail
    movzx r8d, byte [rsi]
    xor rax, r8
    imul rax, rdx
    movzx r8d, byte [rsi+1]
    xor rax, r8
    imul rax, rdx
    movzx r8d, byte [rsi+2]
    xor rax, r8
    imul rax, rdx
    movzx r8d, byte [rsi+3]
    xor rax, r8
    imul rax, rdx
    add rsi, 4
    sub rcx, 4
    jmp .bh_loop4
.bh_tail:
    test rcx, rcx
    jz .bh_done
    movzx r8d, byte [rsi]
    xor rax, r8
    imul rax, rdx
    inc rsi
    dec rcx
    jmp .bh_tail
.bh_done:
    ; -1 is the "no hash yet" marker everywhere it is stored.
    cmp rax, -1
    jne .bh_out
    mov rax, -2
.bh_out:
    ret
END_FUNC bytes_hash
section .data

; bytes type object
align 8
global bytes_type
bytes_type:
    dq 1                    ; ob_refcnt
    dq type_type            ; ob_type
    dq bytes_name_str       ; tp_name
    dq PyBytesObject.data   ; tp_basicsize (header, without data)
    dq bytes_dealloc        ; tp_dealloc
    dq bytes_repr           ; tp_repr
    dq bytes_repr           ; tp_str
    dq bytes_hash           ; tp_hash
    dq 0                    ; tp_call
    dq bytes_getattr        ; tp_getattr
    dq 0                    ; tp_setattr
    dq bytes_compare        ; tp_richcompare
    dq bytes_tp_iter        ; tp_iter
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq 0                    ; tp_new
    dq bytes_number_methods  ; tp_as_number
    dq bytes_sequence_methods ; tp_as_sequence
    dq bytes_mapping_methods  ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq TYPE_FLAG_BASETYPE | TYPE_FLAG_BYTES_SUBCLASS   ; tp_flags -- the
                            ; subclass bit is carried by the base too, as
                            ; bytearray's is, so type_from_parts inherits it
    dq 0                    ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

; bytes_iter type object
align 8
global bytes_iter_type
bytes_iter_type:
    dq 1                        ; ob_refcnt
    dq type_type                ; ob_type
    dq bytes_iter_name_str      ; tp_name
    dq PyBytesIterObject_size   ; tp_basicsize
    dq bytes_iter_dealloc       ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq bytes_iter_self          ; tp_iter
    dq bytes_iter_next          ; tp_iternext
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
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

section .rodata
bytes_range_msg: db "bytes must be in range(0, 256)", 0
global bytearray_range_msg
bytearray_range_msg: db "byte must be in range(0, 256)", 0
; The \x01 is raise_type_error_with_name's placeholder for the argument's type.
bytes_enc_msg: db `bytes() argument 'encoding' must be str, not \x01`, 0
bytes_arity_msg: db "bytes() takes at most 3 arguments (", 0
bytes_conv_msg: db `cannot convert '\x01' object to bytes`, 0
bytearray_enc_msg: db `bytearray() argument 'encoding' must be str, not \x01`, 0

