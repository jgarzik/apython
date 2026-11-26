; io_bytesio.asm - _io.BytesIO, a file whose storage is memory
;
; Split out of io.asm when that file crossed the 100k cap a hand-written file
; in this tree is held to.  The seam is one the file already had: io.asm is
; the module, the four base types and FileIO -- everything whose answers come
; from a file descriptor -- and this is the one type that has none.  Nothing
; here makes a syscall.
;
; What crosses is small, and goes almost entirely one way: the error builders
; and a handful of helpers come from io.asm, and only bytesio_check and
; io_make_bytesio go back.

%include "macros.inc"
%include "object.inc"

ASM_INIT

; --- from io.asm, the half this came out of ---
extern dict_set_str
extern io_bases1
extern io_set_number
extern io_append_i64
extern io_copy_bounded
extern io_add_method
extern io_add_property
extern io_bytesio_type
extern fileio_writable_buffer
extern bytesio_flush_fn

; --- the rest of the tree ---
extern ap_malloc
extern ap_free
extern ap_realloc
extern ap_memcpy
extern obj_decref
extern obj_incref
extern bytes_new
extern bytes_type
extern str_from_cstr_heap
extern int_from_i64
extern none_singleton
extern bool_true
extern bool_false
extern exc_ValueError_type
extern exc_TypeError_type
extern set_exception
extern obj_as_index
extern type_from_parts
extern gc_alloc
extern gc_track

extern dict_new
extern io_msg_binto
extern io_msg_readinto
extern ap_strlen
extern bytes_from_data
extern bytes_like_ptr_len
extern dict_set
extern exc_BufferError_type
extern exc_OSError_type
extern exc_OverflowError_type
extern exc_StopIteration_type
extern im_a_closed
extern im_modattr
extern io_msgbuf
extern io_msg_byteslike
extern io_msg_negseek
extern io_msg_negsize
extern io_msg_whence
extern io_msg_whence2
extern io_readinto_msg
extern memoryview_type
extern mv_format_B
extern set_exception
extern type_stamp_methods
extern im_n_close
extern im_n_enter
extern im_n_exit
extern im_n_init
extern im_n_module
extern im_n_read
extern im_n_readable
extern im_n_readinto
extern im_n_seek
extern im_n_seekable
extern im_n_tell
extern im_n_truncate
extern im_n_writable
extern im_n_write

global bytesio_check
global io_make_bytesio
global im_n_BytesIO
global im_n_flush

;; The two registration macros, copied rather than shared: they are five lines
;; each, a NASM macro does not cross a file, and a header that only these two
;; files would include is the heavier of the two costs.  posixproc.asm's
;; POSIX_CHECK is the precedent.
%macro IO_METHOD 2              ; %1 = name symbol, %2 = implementation
    mov rdi, rbx
    lea rsi, [rel %1]
    lea rdx, [rel %2]
    call io_add_method
%endmacro

%macro IO_PROPERTY 2            ; %1 = name symbol, %2 = the getter
    mov rdi, rbx
    lea rsi, [rel %1]
    lea rdx, [rel %2]
    call io_add_property
%endmacro


;; ============================================================================
;; _io.BytesIO -- a file whose storage is memory.
;;
;; Same construction as FileIO: a heaptype over _BufferedIOBase with a patched
;; tp_basicsize.  The buffer is grown by doubling, and `size` is what has been
;; written rather than what has been allocated, so seeking past the end and
;; then writing zero-fills the gap the way a real file does.
;; ============================================================================

section .rodata

im_n_BytesIO:    db "BytesIO", 0
im_n_getvalue:   db "getvalue", 0
im_n_getbuffer:  db "getbuffer", 0
im_n_read1:      db "read1", 0
im_n_readline:   db "readline", 0
im_n_readlines:  db "readlines", 0
im_n_writelines: db "writelines", 0
im_n_flush:      db "flush", 0
im_n_iter:       db "__iter__", 0
im_n_next:       db "__next__", 0

section .data
align 8
bytesio_base_dealloc: dq 0

section .text

;; bytesio_check(rdi = self) -> rax = 0 on an open buffer
;; Fails: -1
;; An open buffer costs one compare and keeps every register but rax, which
;; is what lets its callers hold their arguments across it.
DEF_FUNC_BARE bytesio_check
    cmp qword [rdi + PyBytesIOObject.bio_buf], 0
    je .closed
    xor eax, eax
    ret
.closed:
    ; CPython punctuates this one and not FileIO's, and the wording is what
    ; a caller sees.
    push rbp
    mov rbp, rsp
    and rsp, -16                ; some callers arrive with a push outstanding
    SET_EXC exc_ValueError_type, "I/O operation on closed file."
    mov rax, -1
    leave
    ret
END_FUNC bytesio_check

;; ============================================================================
;; bytesio_reserve(rdi = self, rsi = the total size needed) -> rax = 1 or 0
;;
;; Doubling, with the requested size as the floor: a write of a megabyte into
;; an empty buffer allocates once, and a million one-byte writes allocate
;; twenty times.
;; ============================================================================
DEF_FUNC_LOCAL bytesio_reserve
    push rbx
    push r12
    sub rsp, 16
    mov rbx, rdi
    mov r12, rsi
    ; ap_realloc calls fatal_error rather than returning NULL, so a size that
    ; can only fail has to be refused here.  This also makes the `jle` below
    ; safe against a negative arriving from a caller that did not check.
    test r12, r12
    js .bre_fail
    mov eax, 0x7fffffff
    cmp r12, rax
    jg .bre_fail
    cmp r12, [rbx + PyBytesIOObject.bio_cap]
    jle .bre_ok
    mov rax, [rbx + PyBytesIOObject.bio_cap]
    test rax, rax
    jnz .bre_double
    mov eax, 64
.bre_double:
    add rax, rax
    cmp rax, r12
    jge .bre_have_cap
    mov rax, r12
.bre_have_cap:
    mov rdi, [rbx + PyBytesIOObject.bio_buf]
    mov rsi, rax
    mov [rsp], rax
    call ap_realloc
    mov rcx, [rsp]
    test rax, rax
    jz .bre_fail
    mov [rbx + PyBytesIOObject.bio_buf], rax
    mov [rbx + PyBytesIOObject.bio_cap], rcx
.bre_ok:
    mov eax, 1
    add rsp, 16
    pop r12
    pop rbx
    leave
    ret
.bre_fail:
    xor eax, eax
    add rsp, 16
    pop r12
    pop rbx
    leave
    ret
END_FUNC bytesio_reserve

;; ============================================================================
;; BytesIO.__init__(self, initial_bytes=b'')
;;   -> rax = None, or 0 with the exception pending -- which is what lets
;;      type_call release the instance a refused BytesIO() was building
;; Fails: 0
;; ============================================================================
BI_SELF   equ 8
BI_ARG    equ 16
BI_FRAME  equ 16            ; + 0 pushes = 16

DEF_FUNC bytesio_init_fn, BI_FRAME
    test rsi, rsi
    jz .bi_argerr
    mov rax, [rdi]
    mov [rbp - BI_SELF], rax

    ; __init__ can be called again on a live object; the previous buffer is
    ; this one's to release before it is replaced.  rdi still holds the
    ; argument array and the code below reads args[1] out of it, so it has to
    ; survive the call.
    ; rsi is nargs and rdi the argument array, and BOTH are read below --
    ; ap_free tail-jumps into glibc, which clobbers every caller-saved
    ; register.  Saving only rdi left `cmp rsi, 2` deciding on garbage and
    ; `mov rcx, [rdi + 8]` reading one slot past a one-element array.
    push rdi
    push rsi
    mov rdi, [rax + PyBytesIOObject.bio_buf]
    test rdi, rdi
    jz .bi_no_previous
    mov qword [rax + PyBytesIOObject.bio_buf], 0
    call ap_free
.bi_no_previous:
    pop rsi
    pop rdi
    mov rax, [rbp - BI_SELF]

    ; A fresh object is all zeroes, so an empty BytesIO still needs a buffer:
    ; bio_buf doubles as the closed flag, and 0 means closed.
    mov qword [rax + PyBytesIOObject.bio_size], 0
    mov qword [rax + PyBytesIOObject.bio_pos], 0
    mov qword [rax + PyBytesIOObject.bio_exports], 0
    cmp rsi, 2
    jl .bi_empty
    mov rcx, [rdi + 8]
    mov [rbp - BI_ARG], rcx
    LOAD_NONE rax
    cmp rcx, rax
    je .bi_empty

    mov rdi, rcx
    call bytes_like_ptr_len     ; rax = data, r10 = length, ecx = ok
    test ecx, ecx
    jz .bi_type
    push rax
    push r10
    mov rdi, [rbp - BI_SELF]
    mov qword [rdi + PyBytesIOObject.bio_buf], 0
    mov qword [rdi + PyBytesIOObject.bio_cap], 0
    mov rsi, r10
    test rsi, rsi
    jnz .bi_reserve
    mov esi, 1                  ; never a zero-byte allocation
.bi_reserve:
    call bytesio_reserve
    test eax, eax
    jz .bi_nomem_pop
    pop rdx                     ; length
    pop rsi                     ; data
    mov rdi, [rbp - BI_SELF]
    mov [rdi + PyBytesIOObject.bio_size], rdx
    mov rdi, [rdi + PyBytesIOObject.bio_buf]
    call ap_memcpy
    jmp .bi_done

.bi_empty:
    mov rdi, [rbp - BI_SELF]
    mov qword [rdi + PyBytesIOObject.bio_buf], 0
    mov qword [rdi + PyBytesIOObject.bio_cap], 0
    mov esi, 64
    call bytesio_reserve
    test eax, eax
    jz .bi_nomem

.bi_done:
    LOAD_NONE rax
    mov rdi, rax
    call obj_incref
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
.bi_nomem_pop:
    add rsp, 16
.bi_nomem:
    FAIL exc_OSError_type, "out of memory", .bi_fail
.bi_type:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel io_msg_byteslike]
    mov rdx, [rbp - BI_ARG]
    extern io_set_typename_q
    call io_set_typename_q
.bi_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
.bi_argerr:
    FAIL exc_TypeError_type, "BytesIO() missing self", .bi_fail
END_FUNC bytesio_init_fn

;; ============================================================================
;; BytesIO.read(size=-1) / read1(size=-1)
;;
;; read1 is the same thing here: there is no underlying stream to make a
;; second call to, so one call always returns everything asked for.
;; ============================================================================
BR_SELF   equ 8
BR_SIZE   equ 16
BR_FRAME  equ 16            ; + 0 pushes = 16

DEF_FUNC bytesio_read_fn, BR_FRAME
    test rsi, rsi
    jz .br_argerr
    mov rax, [rdi]
    mov [rbp - BR_SELF], rax
    mov r8, -1
    cmp rsi, 2
    jl .br_have_size
    mov rcx, [rdi + 8]
    LOAD_NONE rax
    cmp rcx, rax
    je .br_have_size
    mov rdi, rcx
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .idx_fail
    mov r8, rax
.br_have_size:
    mov rdi, [rbp - BR_SELF]
    call bytesio_check
    ERR_M1 .fail

    ; What is left, clamped by what was asked for.
    mov rcx, [rdi + PyBytesIOObject.bio_size]
    sub rcx, [rdi + PyBytesIOObject.bio_pos]
    jg .br_have_avail
    xor ecx, ecx                ; the cursor is at or past the end
.br_have_avail:
    test r8, r8
    js .br_take_all
    cmp r8, rcx
    jge .br_take_all
    mov rcx, r8
.br_take_all:
    mov rsi, [rdi + PyBytesIOObject.bio_buf]
    add rsi, [rdi + PyBytesIOObject.bio_pos]
    add [rdi + PyBytesIOObject.bio_pos], rcx
    mov rdi, rsi
    mov rsi, rcx
    call bytes_from_data
    mov edx, TAG_PTR
    leave
    ret
.br_argerr:
    FAIL exc_TypeError_type, "read() missing self", .fail
.idx_fail:                      ; not an index: the exception is pending
    xor eax, eax
    leave
    ret
.fail:
    xor eax, eax
    leave
    ret
END_FUNC bytesio_read_fn

;; ============================================================================
;; BytesIO.readline(size=-1) -- up to and including the newline
;; ============================================================================
DEF_FUNC bytesio_readline_fn, BR_FRAME
    test rsi, rsi
    jz .brl_argerr
    mov rax, [rdi]
    mov [rbp - BR_SELF], rax
    mov r8, -1
    cmp rsi, 2
    jl .brl_have_size
    mov rcx, [rdi + 8]
    LOAD_NONE rax
    cmp rcx, rax
    je .brl_have_size
    mov rdi, rcx
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .fail
    mov r8, rax
.brl_have_size:
    mov rdi, [rbp - BR_SELF]
    call bytesio_check
    ERR_M1 .fail

    mov rcx, [rdi + PyBytesIOObject.bio_size]
    sub rcx, [rdi + PyBytesIOObject.bio_pos]
    jg .brl_scan
    xor ecx, ecx
.brl_scan:
    test r8, r8
    js .brl_no_cap
    cmp r8, rcx
    jge .brl_no_cap
    mov rcx, r8
.brl_no_cap:
    mov rsi, [rdi + PyBytesIOObject.bio_buf]
    add rsi, [rdi + PyBytesIOObject.bio_pos]
    xor r9d, r9d
.brl_loop:
    cmp r9, rcx
    jge .brl_done
    cmp byte [rsi + r9], 10
    je .brl_found
    inc r9
    jmp .brl_loop
.brl_found:
    inc r9                      ; the newline belongs to the line
.brl_done:
    add [rdi + PyBytesIOObject.bio_pos], r9
    mov rdi, rsi
    mov rsi, r9
    call bytes_from_data
    mov edx, TAG_PTR
    leave
    ret
.brl_argerr:
    SET_EXC exc_TypeError_type, "readline() missing self"
.fail:
    xor eax, eax
    leave
    ret
END_FUNC bytesio_readline_fn

;; ============================================================================
;; BytesIO.readinto(b)
;; ============================================================================
BRI_SELF  equ 8
BRI_FRAME equ 16            ; + 0 pushes = 16

DEF_FUNC bytesio_readinto_fn, BRI_FRAME
    cmp rsi, 2
    jl .bri_argerr
    mov rax, [rdi]
    mov [rbp - BRI_SELF], rax
    mov rsi, [rdi + 8]
    mov rdi, rax
    call bytesio_check
    ERR_M1 .fail
    mov rdi, rsi
    mov qword [rel io_readinto_msg], io_msg_binto
    call fileio_writable_buffer   ; rax = data, r10 = length
    mov qword [rel io_readinto_msg], io_msg_readinto
    ERR_PENDING .fail

    mov rdi, [rbp - BRI_SELF]
    mov rcx, [rdi + PyBytesIOObject.bio_size]
    sub rcx, [rdi + PyBytesIOObject.bio_pos]
    jg .bri_avail
    xor ecx, ecx
.bri_avail:
    cmp rcx, r10
    jle .bri_have_n
    mov rcx, r10
.bri_have_n:
    mov rsi, [rdi + PyBytesIOObject.bio_buf]
    add rsi, [rdi + PyBytesIOObject.bio_pos]
    add [rdi + PyBytesIOObject.bio_pos], rcx
    mov rdi, rax
    mov rdx, rcx
    push rdx
    call ap_memcpy
    pop rdx
    V_PACK_I64 rdx, rcx
    mov rax, rdx
    leave
    ret
.bri_argerr:
    SET_EXC exc_TypeError_type, "readinto() takes exactly one argument"
.fail:
    xor eax, eax
    leave
    ret
END_FUNC bytesio_readinto_fn

;; ============================================================================
;; BytesIO.write(b) -- a write past the end zero-fills the gap, as a file does
;; ============================================================================
BW_SELF   equ 8
BW_DATA   equ 16
BW_LEN    equ 24
BW_ARG    equ 32
BW_FRAME  equ 32            ; + 0 pushes = 32

DEF_FUNC bytesio_write_fn, BW_FRAME
    cmp rsi, 2
    jl .bw_argerr
    mov rax, [rdi]
    mov [rbp - BW_SELF], rax
    mov rsi, [rdi + 8]
    mov [rbp - BW_ARG], rsi
    mov rdi, rax
    call bytesio_check
    ERR_M1 .fail
    cmp qword [rdi + PyBytesIOObject.bio_exports], 0
    jne .bw_exported

    mov rdi, rsi
    call bytes_like_ptr_len
    test ecx, ecx
    jz .bw_type
    mov [rbp - BW_DATA], rax
    mov [rbp - BW_LEN], r10

    mov rdi, [rbp - BW_SELF]
    mov rsi, [rdi + PyBytesIOObject.bio_pos]
    add rsi, r10
    ; A cursor near 2^63 plus a length overflows to negative, and
    ; bytesio_reserve's `jle` then read that as "the buffer is already big
    ; enough".  The gap-fill below duly ran `rep stosb` with rcx around 2^63
    ; over a 64-byte allocation.
    jo .bw_toolarge
    call bytesio_reserve
    test eax, eax
    jz .bw_nomem

    ; Zero the gap between the old end and the cursor.  Without it a seek
    ; past the end followed by a write leaves whatever realloc handed back.
    mov rdi, [rbp - BW_SELF]
    mov rcx, [rdi + PyBytesIOObject.bio_pos]
    mov rdx, [rdi + PyBytesIOObject.bio_size]
    cmp rcx, rdx
    jle .bw_no_gap
    sub rcx, rdx
    mov rax, [rdi + PyBytesIOObject.bio_buf]
    lea rdi, [rax + rdx]
    xor eax, eax
    rep stosb
.bw_no_gap:
    mov rdi, [rbp - BW_SELF]
    mov rdi, [rdi + PyBytesIOObject.bio_buf]
    mov rax, [rbp - BW_SELF]
    add rdi, [rax + PyBytesIOObject.bio_pos]
    mov rsi, [rbp - BW_DATA]
    mov rdx, [rbp - BW_LEN]
    call ap_memcpy

    mov rdi, [rbp - BW_SELF]
    mov rax, [rdi + PyBytesIOObject.bio_pos]
    add rax, [rbp - BW_LEN]
    mov [rdi + PyBytesIOObject.bio_pos], rax
    cmp rax, [rdi + PyBytesIOObject.bio_size]
    jle .bw_size_ok
    mov [rdi + PyBytesIOObject.bio_size], rax
.bw_size_ok:
    mov rdx, [rbp - BW_LEN]
    V_PACK_I64 rdx, rcx
    mov rax, rdx
    leave
    ret
.bw_exported:
    FAIL exc_BufferError_type, "Existing exports of data: object cannot be re-sized", .fail
.bw_toolarge:
    FAIL exc_OverflowError_type, "new buffer size too large", .fail
.bw_nomem:
    FAIL exc_OSError_type, "out of memory", .fail
.bw_type:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel io_msg_byteslike]
    mov rdx, [rbp - BW_ARG]
    call io_set_typename_q
    jmp .fail
.bw_argerr:
    SET_EXC exc_TypeError_type, "write() takes exactly one argument"
.fail:
    xor eax, eax
    leave
    ret
END_FUNC bytesio_write_fn

;; ============================================================================
;; BytesIO.seek / tell / truncate / getvalue / getbuffer
;; ============================================================================
BS_SELF   equ 8
BS_POS    equ 16
BS_FRAME  equ 32            ; + 0 pushes = 32

DEF_FUNC bytesio_seek_fn, BS_FRAME
    cmp rsi, 2
    jl .bs_argerr
    mov rax, [rdi]
    mov [rbp - BS_SELF], rax
    push rdi
    push rsi
    mov rdi, [rdi + 8]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .fail
    mov [rbp - BS_POS], rax
    pop rsi
    pop rdi
    xor r8d, r8d
    cmp rsi, 3
    jl .bs_have_whence
    mov rdi, [rdi + 16]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .fail
    mov r8, rax
.bs_have_whence:
    push r8
    mov rdi, [rbp - BS_SELF]
    call bytesio_check
    ERR_M1 .fail
    pop r8

    mov rax, [rbp - BS_POS]
    cmp r8, SEEK_SET
    je .bs_set
    cmp r8, SEEK_CUR
    je .bs_cur
    cmp r8, SEEK_END
    je .bs_end
    lea rdi, [rel io_msgbuf]
    lea rsi, [rel io_msg_whence]
    mov edx, 100
    push r8
    call io_copy_bounded
    pop rsi
    mov rdi, rax
    call io_append_i64
    lea rdi, [rel io_msgbuf]
    call ap_strlen
    lea rdi, [rel io_msgbuf]
    add rdi, rax
    lea rsi, [rel io_msg_whence2]
    mov edx, 40
    call io_copy_bounded
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel io_msgbuf]
    call set_exception
    jmp .fail
.bs_cur:
    add rax, [rdi + PyBytesIOObject.bio_pos]
    jmp .bs_clamp
.bs_end:
    add rax, [rdi + PyBytesIOObject.bio_size]
.bs_clamp:
    ; A computed position below zero clamps; only an absolute seek refuses.
    ; CPython does the same, and code that walks backwards from the cursor
    ; relies on it.
    test rax, rax
    jns .bs_store
    xor eax, eax
    jmp .bs_store
.bs_set:
    test rax, rax
    js .bs_negative
.bs_store:
    mov [rdi + PyBytesIOObject.bio_pos], rax
    mov rdx, rax
    V_PACK_I64 rdx, rcx
    mov rax, rdx
    leave
    ret
.bs_negative:
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel io_msg_negseek]
    mov rdx, rax
    call io_set_number
    jmp .fail
.bs_argerr:
    SET_EXC exc_TypeError_type, "seek() takes at least one argument"
.fail:
    xor eax, eax
    leave
    ret
END_FUNC bytesio_seek_fn

DEF_FUNC bytesio_tell_fn
    test rsi, rsi
    jz .bt_argerr
    mov rdi, [rdi]
    call bytesio_check
    ERR_M1 .fail
    mov rdx, [rdi + PyBytesIOObject.bio_pos]
    V_PACK_I64 rdx, rcx
    mov rax, rdx
    leave
    ret
.bt_argerr:
    SET_EXC exc_TypeError_type, "tell() takes no arguments"
.fail:
    xor eax, eax
    leave
    ret
END_FUNC bytesio_tell_fn

BTR_SELF  equ 8
BTR_SIZE  equ 16
BTR_FRAME equ 32            ; + 0 pushes = 32

DEF_FUNC bytesio_truncate_fn, BTR_FRAME
    test rsi, rsi
    jz .btr_argerr
    mov rax, [rdi]
    mov [rbp - BTR_SELF], rax
    mov qword [rbp - BTR_SIZE], -1
    cmp rsi, 2
    jl .btr_have_size
    mov rcx, [rdi + 8]
    LOAD_NONE rax
    cmp rcx, rax
    je .btr_have_size
    mov rdi, rcx
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .idx_fail
    test rax, rax
    jl .btr_negative
    mov [rbp - BTR_SIZE], rax
.btr_have_size:
    mov rdi, [rbp - BTR_SELF]
    call bytesio_check
    ERR_M1 .fail
    cmp qword [rdi + PyBytesIOObject.bio_exports], 0
    jne .btr_exported
    mov rax, [rbp - BTR_SIZE]
    test rax, rax
    jge .btr_do
    mov rax, [rdi + PyBytesIOObject.bio_pos]   ; None truncates here
.btr_do:
    ; Only ever shrinks: CPython's BytesIO.truncate does not extend, unlike a
    ; file's, and the position is left alone either way.
    cmp rax, [rdi + PyBytesIOObject.bio_size]
    jge .btr_out
    mov [rdi + PyBytesIOObject.bio_size], rax
.btr_out:
    mov rdx, rax
    V_PACK_I64 rdx, rcx
    mov rax, rdx
    leave
    ret
.btr_exported:
    FAIL exc_BufferError_type, "Existing exports of data: object cannot be re-sized", .fail
.btr_negative:
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel io_msg_negsize]
    mov rdx, rax
    call io_set_number
    jmp .fail
.btr_argerr:
    FAIL exc_TypeError_type, "truncate() missing self", .fail
.idx_fail:                      ; not an index: the exception is pending
    xor eax, eax
    leave
    ret
.fail:
    xor eax, eax
    leave
    ret
END_FUNC bytesio_truncate_fn

DEF_FUNC bytesio_getvalue_fn
    test rsi, rsi
    jz .bg_argerr
    mov rdi, [rdi]
    call bytesio_check
    ERR_M1 .fail
    mov rsi, [rdi + PyBytesIOObject.bio_size]
    mov rdi, [rdi + PyBytesIOObject.bio_buf]
    call bytes_from_data
    mov edx, TAG_PTR
    leave
    ret
.bg_argerr:
    SET_EXC exc_TypeError_type, "getvalue() takes no arguments"
.fail:
    xor eax, eax
    leave
    ret
END_FUNC bytesio_getvalue_fn

;; getbuffer() hands out a memoryview over the storage itself, so nothing may
;; resize it while the view is alive.  CPython counts the live views and
;; refuses to write or truncate; the count is decremented by release().
DEF_FUNC bytesio_getbuffer_fn
    test rsi, rsi
    jz .bgb_argerr
    push rbx
    mov rdi, [rdi]
    mov rbx, rdi
    call bytesio_check
    ERR_M1 .fail
    mov edi, PyMemoryViewObject_size
    call ap_malloc
    test rax, rax
    jz .bgb_nomem
    mov qword [rax + PyMemoryViewObject.ob_refcnt], 1
    lea rcx, [rel memoryview_type]
    mov [rax + PyMemoryViewObject.ob_type], rcx
    mov qword [rax + PyMemoryViewObject.mv_exports], 0
    mov [rax + PyMemoryViewObject.mv_source], rbx
    inc qword [rbx + PyObject.ob_refcnt]
    mov rcx, [rbx + PyBytesIOObject.bio_buf]
    mov [rax + PyMemoryViewObject.mv_buf], rcx
    mov rcx, [rbx + PyBytesIOObject.bio_size]
    mov [rax + PyMemoryViewObject.mv_len], rcx
    mov qword [rax + PyMemoryViewObject.mv_itemsize], 1
    mov qword [rax + PyMemoryViewObject.mv_stride], 1
    lea rcx, [rel mv_format_B]
    mov [rax + PyMemoryViewObject.mv_format], rcx
    mov qword [rax + PyMemoryViewObject.mv_readonly], 0
    inc qword [rbx + PyBytesIOObject.bio_exports]
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.bgb_nomem:
    FAIL exc_OSError_type, "out of memory", .fail
.bgb_argerr:
    SET_EXC exc_TypeError_type, "getbuffer() takes no arguments"
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC bytesio_getbuffer_fn

;; ============================================================================
;; BytesIO.close and the predicates.  close frees the storage, which is what
;; makes getvalue() after close a ValueError rather than an empty answer.
;; ============================================================================
DEF_FUNC bytesio_close_fn
    test rsi, rsi
    jz .bc_argerr
    mov rdi, [rdi]
    cmp qword [rdi + PyBytesIOObject.bio_exports], 0
    jne .bc_exported
    mov rax, [rdi + PyBytesIOObject.bio_buf]
    test rax, rax
    jz .bc_done
    mov qword [rdi + PyBytesIOObject.bio_buf], 0
    mov qword [rdi + PyBytesIOObject.bio_cap], 0
    mov qword [rdi + PyBytesIOObject.bio_size], 0
    mov qword [rdi + PyBytesIOObject.bio_pos], 0
    mov rdi, rax
    call ap_free
.bc_done:
    LOAD_NONE rax
    mov rdi, rax
    call obj_incref
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
.bc_exported:
    FAIL exc_BufferError_type, "Existing exports of data: object cannot be re-sized", .fail
.bc_argerr:
    SET_EXC exc_TypeError_type, "close() takes no arguments"
.fail:
    xor eax, eax
    leave
    ret
END_FUNC bytesio_close_fn

DEF_FUNC bytesio_closed_get_fn
    test rsi, rsi
    jz .bcg_argerr
    mov rdi, [rdi]
    cmp qword [rdi + PyBytesIOObject.bio_buf], 0
    je .bcg_true
    lea rax, [rel bool_false]
    jmp .bcg_out
.bcg_true:
    lea rax, [rel bool_true]
.bcg_out:
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
.bcg_argerr:
    SET_EXC exc_TypeError_type, "closed getter takes no arguments"
.fail:
    xor eax, eax
    leave
    ret
END_FUNC bytesio_closed_get_fn

;; A BytesIO is readable, writable and seekable whenever it is open, so the
;; three predicates differ only in nothing at all -- but each still has to
;; raise on a closed buffer, which is why they are not one function.
DEF_FUNC bytesio_true_fn
    test rsi, rsi
    jz .btf_argerr
    mov rdi, [rdi]
    call bytesio_check
    ERR_M1 .fail
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
.btf_argerr:
    SET_EXC exc_TypeError_type, "takes no arguments"
.fail:
    xor eax, eax
    leave
    ret
END_FUNC bytesio_true_fn

DEF_FUNC bytesio_enter_fn
    test rsi, rsi
    jz .ben_argerr
    mov rdi, [rdi]
    call bytesio_check
    ERR_M1 .fail
    call obj_incref
    mov rax, rdi
    mov edx, TAG_PTR
    leave
    ret
.ben_argerr:
    SET_EXC exc_TypeError_type, "__enter__() takes no arguments"
.fail:
    xor eax, eax
    leave
    ret
END_FUNC bytesio_enter_fn

DEF_FUNC bytesio_exit_fn
    test rsi, rsi
    jz .bex_argerr
    mov esi, 1
    call bytesio_close_fn
    leave
    ret
.bex_argerr:
    SET_EXC exc_TypeError_type, "__exit__() missing self"
.fail:
    xor eax, eax
    leave
    ret
END_FUNC bytesio_exit_fn

;; ============================================================================
;; Iteration: `for line in BytesIO(...)`.  The object is its own iterator, as
;; every file object in Python is.
;; ============================================================================
DEF_FUNC bytesio_iter_fn
    test rsi, rsi
    jz .bit_argerr
    mov rdi, [rdi]
    call bytesio_check
    ERR_M1 .fail
    call obj_incref
    mov rax, rdi
    mov edx, TAG_PTR
    leave
    ret
.bit_argerr:
    SET_EXC exc_TypeError_type, "__iter__() takes no arguments"
.fail:
    xor eax, eax
    leave
    ret
END_FUNC bytesio_iter_fn

DEF_FUNC bytesio_next_fn
    test rsi, rsi
    jz .bnx_argerr
    push rbx
    mov rdi, [rdi]
    mov rbx, rdi
    call bytesio_check
    ERR_M1 .fail
    mov rax, [rbx + PyBytesIOObject.bio_pos]
    cmp rax, [rbx + PyBytesIOObject.bio_size]
    jge .bnx_stop
    sub rsp, 16
    mov [rsp], rbx
    mov rdi, rsp
    mov esi, 1
    call bytesio_readline_fn
    add rsp, 16
    pop rbx
    leave
    ret
.bnx_stop:
    ; set_exception, not RAISE: RAISE tail-jumps into the unwinder, which for
    ; a builtin __next__ means unwinding straight past slot_tp_iternext and
    ; out of the `for` that was calling it.  A builtin returns NULL and leaves
    ; the exception pending; the slot wrapper is what turns StopIteration into
    ; exhaustion.
    pop rbx
    SET_EXC exc_StopIteration_type, ""
    RET_NULL
    leave
    ret
.bnx_argerr:
    SET_EXC exc_TypeError_type, "__next__() takes no arguments"
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC bytesio_next_fn

;; ============================================================================
;; bytesio_dealloc -- free the storage, then let the generic dealloc run.
;; The same zeroing as FileIO's, and for the same reason: instance_dealloc
;; walks the words past the dict slot as if they were __slots__ values.
;; ============================================================================

;; ============================================================================
;; io_buffer_acquired / io_buffer_released(rdi = a memoryview's source)
;;
;; Called wherever a memoryview takes or drops a source, whatever that source
;; is.  Only a BytesIO counts, and the global is 0 until _io is imported, so
;; both checks are one compare.
;;
;; They have to be symmetric.  Counting only the view getbuffer() returned
;; meant a slice of it -- which shares the storage and the source -- decremented
;; a count it never incremented: releasing the original dropped it to zero
;; while the slice was still pointing into the buffer, and the next write
;; reallocated underneath it.
;; ============================================================================
DEF_FUNC_BARE io_buffer_acquired
    test rdi, rdi
    jz .iba_out
    mov rax, [rel io_bytesio_type]
    test rax, rax
    jz .iba_out
    cmp [rdi + PyObject.ob_type], rax
    jne .iba_out
    inc qword [rdi + PyBytesIOObject.bio_exports]
.iba_out:
    ret
END_FUNC io_buffer_acquired

DEF_FUNC_BARE io_buffer_released
    test rdi, rdi
    jz .ibr_out
    mov rax, [rel io_bytesio_type]
    test rax, rax
    jz .ibr_out
    cmp [rdi + PyObject.ob_type], rax
    jne .ibr_out
    cmp qword [rdi + PyBytesIOObject.bio_exports], 0
    jle .ibr_out
    dec qword [rdi + PyBytesIOObject.bio_exports]
.ibr_out:
    ret
END_FUNC io_buffer_released


;; BytesIO holds no objects at all past the dict -- the buffer is raw memory --
;; so its traverse is the dict and nothing more.
DEF_FUNC bytesio_traverse
    mov rdi, [rdi + PyBytesIOObject.inst_dict]
    VISIT_PTR rdi
    xor eax, eax
    leave
    ret
END_FUNC bytesio_traverse

DEF_FUNC bytesio_clear, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyBytesIOObject.inst_dict]
    test rdi, rdi
    jz .bic_done
    mov qword [rbx + PyBytesIOObject.inst_dict], 0
    call obj_decref
.bic_done:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC bytesio_clear

DEF_FUNC_LOCAL bytesio_dealloc, 8            ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyBytesIOObject.bio_buf]
    test rdi, rdi
    jz .bd_no_buf
    call ap_free
.bd_no_buf:
    mov qword [rbx + PyBytesIOObject.bio_buf], 0
    mov qword [rbx + PyBytesIOObject.bio_size], 0
    mov qword [rbx + PyBytesIOObject.bio_cap], 0
    mov qword [rbx + PyBytesIOObject.bio_pos], 0
    mov qword [rbx + PyBytesIOObject.bio_exports], 0
    mov rdi, rbx
    pop rbx
    leave
    jmp [rel bytesio_base_dealloc]
END_FUNC bytesio_dealloc

;; ============================================================================
;; io_make_bytesio(rdi = _BufferedIOBase) -> rax = the BytesIO type
;; ============================================================================
MBI_BASES equ 8
MBI_NS    equ 16
MBI_NAME  equ 24
MBI_FRAME equ 40            ; + 1 push = 48, 16-aligned

DEF_FUNC_LOCAL io_make_bytesio, MBI_FRAME
    push rbx
    call io_bases1
    mov [rbp - MBI_BASES], rax

    call dict_new
    mov rbx, rax
    mov [rbp - MBI_NS], rax

    IO_METHOD im_n_init,       bytesio_init_fn
    IO_METHOD im_n_read,       bytesio_read_fn
    IO_METHOD im_n_read1,      bytesio_read_fn
    IO_METHOD im_n_readline,   bytesio_readline_fn
    IO_METHOD im_n_readinto,   bytesio_readinto_fn
    IO_METHOD im_n_write,      bytesio_write_fn
    IO_METHOD im_n_seek,       bytesio_seek_fn
    IO_METHOD im_n_tell,       bytesio_tell_fn
    IO_METHOD im_n_truncate,   bytesio_truncate_fn
    IO_METHOD im_n_getvalue,   bytesio_getvalue_fn
    IO_METHOD im_n_getbuffer,  bytesio_getbuffer_fn
    IO_METHOD im_n_flush,      bytesio_flush_fn
    IO_METHOD im_n_close,      bytesio_close_fn
    IO_METHOD im_n_readable,   bytesio_true_fn
    IO_METHOD im_n_writable,   bytesio_true_fn
    IO_METHOD im_n_seekable,   bytesio_true_fn
    IO_METHOD im_n_enter,      bytesio_enter_fn
    IO_METHOD im_n_exit,       bytesio_exit_fn
    IO_METHOD im_n_iter,       bytesio_iter_fn
    IO_METHOD im_n_next,       bytesio_next_fn
    IO_PROPERTY im_a_closed,   bytesio_closed_get_fn

    lea rdi, [rel im_n_module]
    call str_from_cstr_heap
    push rax
    lea rdi, [rel im_modattr]
    call str_from_cstr_heap
    push rax
    mov rdi, rbx
    mov rsi, [rsp + 8]
    mov rdx, rax
    call dict_set_str
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    lea rdi, [rel im_n_BytesIO]
    call str_from_cstr_heap
    mov [rbp - MBI_NAME], rax
    mov rdi, rax
    mov rsi, [rbp - MBI_BASES]
    mov rdx, [rbp - MBI_NS]
    call type_from_parts
    mov rbx, rax
    mov rdi, rbx
    call type_stamp_methods     ; see _IOBase above
    mov rdi, [rbp - MBI_NAME]
    call obj_decref
    mov rdi, [rbp - MBI_BASES]
    call obj_decref

    mov qword [rbx + PyTypeObject.tp_basicsize], PyBytesIOObject_size
    mov [rel io_bytesio_type], rbx
    mov rax, [rbx + PyTypeObject.tp_dealloc]
    mov [rel bytesio_base_dealloc], rax
    lea rax, [rel bytesio_dealloc]
    mov [rbx + PyTypeObject.tp_dealloc], rax
    lea rax, [rel bytesio_traverse]
    mov [rbx + PyTypeObject.tp_traverse], rax
    lea rax, [rel bytesio_clear]
    mov [rbx + PyTypeObject.tp_clear], rax

    mov rax, rbx
    pop rbx
    leave
    ret
END_FUNC io_make_bytesio
