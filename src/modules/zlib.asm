; zlibmod.asm - the _zlibcore module: libz's stream, and nothing else.
;
; The same split _iocore/lib/_io.py and _socketcore/lib/_socket.py use.  What
; is genuinely C lives here -- the z_stream calls, the output buffer that has
; to grow while deflate writes into it, the handle table -- and everything a
; Python program sees is lib/zlib.py: the Compress and Decompress objects, the
; constants, `zlib.error`, the keyword arguments and every default.  So every
; function here takes a fixed number of positional arguments and answers with
; a bytes, an int or a tuple.
;
; And it is a SHIM.  -lgmp already set that precedent at the most load-bearing
; place there is -- every big integer in this interpreter is GMP's -- and the
; callers here (gzip, zipfile, tarfile, shutil) care about speed in a way that
; a thousand lines of hand-written inflate could not serve.
;
; A handle is an INDEX into zc_handles, not a pointer.  A pointer would be an
; integer a Python program could forge and this module would dereference; an
; index is bounds-checked and a freed slot reads back as 0.

%include "macros.inc"
%include "object.inc"

ASM_INIT

extern dict_new
extern dict_set
extern module_new
extern str_from_cstr_heap
extern obj_decref
extern int_from_i64
extern builtin_func_new
extern bytes_new
extern bytes_from_data
extern bytes_type
extern bytearray_type
extern ap_malloc
extern ap_realloc
extern ap_free
extern ap_memcpy
extern ap_memset
extern obj_as_index
extern set_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern set_type_error_with_name
extern rbt_append_cstr
extern tuple_new
extern bool_true
extern bool_false
extern none_singleton

extern crc32
extern adler32
extern deflateInit2_
extern deflate
extern deflateEnd
extern inflateInit2_
extern inflate
extern inflateEnd
extern zlibVersion

; --- z_stream, from /usr/include/zlib.h on x86-64 -------------------------
struc ZStream
    .next_in:   resq 1  ; +0
    .avail_in:  resd 1  ; +8   uInt
    .zpad0:     resd 1  ; +12
    .total_in:  resq 1  ; +16
    .next_out:  resq 1  ; +24
    .avail_out: resd 1  ; +32
    .zpad1:     resd 1  ; +36
    .total_out: resq 1  ; +40
    .msg:       resq 1  ; +48
    .state:     resq 1  ; +56
    .zalloc:    resq 1  ; +64
    .zfree:     resq 1  ; +72
    .opaque:    resq 1  ; +80
    .data_type: resd 1  ; +88
    .zpad2:     resd 1  ; +92
    .adler:     resq 1  ; +96
    .reserved:  resq 1  ; +104
endstruc                ; sizeof = 112

; --- one open stream ------------------------------------------------------
ZC_MAGIC equ 0x5A4C4942            ; "ZLIB": a freed handle must not look live

struc ZHandle
    ; The z_stream FIRST, so it inherits the allocator's 16-byte alignment.
    ; libz's inflate reads it with SSE on this build, and a struct at 8 mod 16
    ; is a general protection fault inside the library rather than a wrong
    ; answer -- which is what putting the magic word in front of it caused.
    .zs:         resb ZStream_size
    .mode:       resq 1  ; 0 = deflate, 1 = inflate
    .eof:        resq 1  ; inflate reached Z_STREAM_END
    .ended:      resq 1  ; deflateEnd/inflateEnd has run
    .tail:       resq 1  ; input the last feed did not consume, ours to free
    .tail_len:   resq 1
    .unused:     resq 1  ; input past the end of an inflate stream, ours
    .unused_len: resq 1
    .magic:      resq 1  ; ZC_MAGIC while the handle is open, 0 once freed
endstruc

Z_OK            equ 0
Z_STREAM_END    equ 1
Z_BUF_ERROR     equ -5
Z_NO_FLUSH      equ 0
Z_FINISH        equ 4
Z_DEFLATED      equ 8

; The output buffer starts here and doubles.  16 KB is a compromise: large
; enough that an ordinary source file or image finishes in one pass, small
; enough that a program holding a thousand small compressobjs does not pay
; for it.
ZC_INITIAL_OUT  equ 16384

section .data
align 8
zc_handles:     dq 0        ; ZHandle*[], grown by doubling
zc_handle_cap:  dq 0
zc_handle_n:    dq 0

section .rodata
zc_modname:      db "_zlibcore", 0
zn_crc32:        db "crc32", 0
zn_adler32:      db "adler32", 0
zn_stream_new:   db "stream_new", 0
zn_stream_feed:  db "stream_feed", 0
zn_stream_state: db "stream_state", 0
zn_stream_drop_tail: db "stream_drop_tail", 0
zn_stream_free:  db "stream_free", 0
zn_version:      db "ZLIB_VERSION", 0
zc_e_init:       db "failed to initialise the compression stream", 0
zc_e_handle:     db "invalid stream handle", 0
zc_e_ended:      db "stream is already finished", 0
zc_e_mem:        db "out of memory while compressing", 0
zc_e_data:       db "invalid or incomplete deflate data", 0
zc_e_notbytes:   db `a bytes-like object is required, not '\x01'`, 0
zc_e_open:       db "Error ", 0
zc_e_decomp:     db " while decompressing data", 0
zc_e_comp:       db " while compressing data", 0
zc_e_colon:      db ": ", 0
section .bss
zc_msgbuf:       resb 256
section .rodata
zc_e_nargs:      db "_zlibcore: wrong number of arguments", 0

section .text

;; ============================================================================
;; zc_set_z(rdi = the ZHandle*, esi = libz's return code) -> rax = 0, with
;;   the ValueError pending
;;
;; CPython's wording, which programs match on:
;;   Error -3 while decompressing data: incorrect header check
;; The tail is whatever libz left in strm.msg, which is the only place the
;; reason for the failure exists.
;; ============================================================================
ZE_H     equ 8
ZE_CODE  equ 16
ZE_FRAME equ 32             ; + 0 pushes = 32
DEF_FUNC_LOCAL zc_set_z, ZE_FRAME
    mov [rbp - ZE_H], rdi
    movsxd rsi, esi
    mov [rbp - ZE_CODE], rsi

    lea rdi, [rel zc_msgbuf]
    lea rsi, [rel zc_e_open]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - ZE_CODE]
    call zc_append_i64
    mov rdi, rax
    mov rcx, [rbp - ZE_H]
    lea rsi, [rel zc_e_decomp]
    cmp qword [rcx + ZHandle.mode], 0
    jne .zez_verb
    lea rsi, [rel zc_e_comp]
.zez_verb:
    call rbt_append_cstr
    mov rcx, [rbp - ZE_H]
    mov rcx, [rcx + ZHandle.zs + ZStream.msg]
    test rcx, rcx
    jz .zez_raise
    mov rdi, rax
    lea rsi, [rel zc_e_colon]
    call rbt_append_cstr
    mov rdi, rax
    mov rcx, [rbp - ZE_H]
    mov rsi, [rcx + ZHandle.zs + ZStream.msg]
    call rbt_append_cstr
.zez_raise:
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel zc_msgbuf]
    call set_exception
    leave
    ret
END_FUNC zc_set_z

;; ============================================================================
;; zc_append_i64(rdi = where to write, rsi = the number) -> rax = the new NUL
;;
;; Decimal, with a sign.  Small enough not to be worth a general formatter,
;; and the only number this module ever has to spell.
;; ============================================================================
ZI_DIGITS equ 8             ; twenty digits, written backwards from here
ZI_FRAME  equ 40            ; + 0 pushes = 40
DEF_FUNC_LOCAL zc_append_i64, ZI_FRAME
    mov r8, rdi
    mov rax, rsi
    test rax, rax
    jns .zai_positive
    mov byte [r8], '-'
    inc r8
    neg rax
.zai_positive:
    ; The digits go in backwards, so the copy has to stop at where they
    ; STARTED rather than at rbp: one uninitialised byte between the two got
    ; copied out, and when it happened to be a NUL the message ended there --
    ; everything appended after it was written past the terminator and never
    ; read.
    lea r10, [rbp - ZI_DIGITS]  ; one past the last digit
    mov r9, r10
    mov ecx, 10
.zai_digit:
    xor edx, edx
    div rcx
    add dl, '0'
    dec r9
    mov [r9], dl
    test rax, rax
    jnz .zai_digit
.zai_copy:
    cmp r9, r10
    jae .zai_end
    mov al, [r9]
    mov [r8], al
    inc r8
    inc r9
    jmp .zai_copy
.zai_end:
    mov byte [r8], 0
    mov rax, r8
    leave
    ret
END_FUNC zc_append_i64

;; ============================================================================
;; zc_buffer(rdi = a Value) -> rax = data pointer, rdx = length, rax = 0 if it
;;   is neither bytes nor bytearray
;;
;; A str is refused rather than encoded: `zlib.compress("x")` is a TypeError in
;; CPython too, and guessing an encoding would be worse than the error.
;; ============================================================================
DEF_FUNC_BARE zc_buffer
    V_TEST_PTR rdi, rax
    ja .zb_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .zb_bytes
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    jne .zb_no
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    mov rax, [rdi + PyByteArrayObject.ob_bytes]
    ret
.zb_bytes:
    mov rdx, [rdi + PyBytesObject.ob_size]
    lea rax, [rdi + PyBytesObject.data]
    ret
.zb_no:
    xor eax, eax
    xor edx, edx
    ret
END_FUNC zc_buffer

;; ============================================================================
;; zc_handle_at(rdi = handle index) -> rax = ZHandle*, or 0
;;
;; Bounds-checked, because the index came from Python.
;; ============================================================================
DEF_FUNC_BARE zc_handle_at
    xor eax, eax
    test rdi, rdi
    js .zh_no
    cmp rdi, [rel zc_handle_n]
    jae .zh_no
    mov rax, [rel zc_handles]
    mov rax, [rax + rdi*8]
    test rax, rax
    jz .zh_no
    ; A handle whose magic is gone is a freed one whose slot was handed back
    ; and whose memory may since have been reused.  libz's own state pointer
    ; is dangling by then, and inflate() dereferences it: the fault landed
    ; inside libz with a z_stream that still read plausibly.
    cmp qword [rax + ZHandle.magic], ZC_MAGIC
    je .zh_ok
    xor eax, eax
.zh_ok:
.zh_no:
    ret
END_FUNC zc_handle_at

;; ============================================================================
;; zc_arg_int(rdi = args, rsi = index) -> rax = the int
;; Fails: -1
;; ============================================================================
DEF_FUNC_BARE zc_arg_int
    mov rdi, [rdi + rsi*8]
    V_UNPACK rdi, rdx
    sub rsp, 8                  ; a call, so the refusal can be seen
    call obj_as_index           ; err: its -1 and its exception are this one's
    add rsp, 8
    ret
END_FUNC zc_arg_int

;; ============================================================================
;; _zlibcore.crc32(data, seed) -> int
;; _zlibcore.adler32(data, seed) -> int
;;
;; libz's own, so they agree with every other zlib in the world -- which
;; matters, because a .zip records the crc32 of what it holds and a reader
;; that computes a different one refuses the file.
;; ============================================================================
ZK_LEN   equ 8
ZK_SEED  equ 16
ZK_ARG   equ 24             ; the data argument, for the type error
ZK_FRAME equ 32             ; + 0 pushes = 32
DEF_FUNC zc_crc32, ZK_FRAME
    cmp rsi, 2
    jne .zk_nargs
    push rdi
    sub rsp, 8
    mov esi, 1
    call zc_arg_int
    ERR_M1 .zk_fail             ; leave drops what was pushed
    add rsp, 8
    pop rdi
    mov [rbp - ZK_SEED], rax

    mov rdi, [rdi]
    mov [rbp - ZK_ARG], rdi
    call zc_buffer
    test rax, rax
    jz .zk_type
    mov rsi, rax
    mov [rbp - ZK_LEN], rdx
    mov rdi, [rbp - ZK_SEED]
    mov rdx, [rbp - ZK_LEN]
    call crc32 wrt ..plt
.zk_return:
    mov rdi, rax
    mov edi, edi                    ; uLong in, an unsigned 32-bit answer out
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
.zk_type:
    lea rdi, [rel zc_e_notbytes]
    mov rsi, [rbp - ZK_ARG]
    call set_type_error_with_name
    jmp .zk_fail
.zk_nargs:
    SET_EXC exc_TypeError_type, "_zlibcore: wrong number of arguments"
.zk_fail:
    xor eax, eax
    leave
    ret
END_FUNC zc_crc32

;; ============================================================================
;; zc_adler32(rdi = args, rsi = nargs) -> rax = the checksum as a Value
;; ============================================================================
DEF_FUNC zc_adler32, ZK_FRAME
    cmp rsi, 2
    jne .za_nargs
    push rdi
    sub rsp, 8
    mov esi, 1
    call zc_arg_int
    ERR_M1 .za_fail             ; leave drops what was pushed
    add rsp, 8
    pop rdi
    mov [rbp - ZK_SEED], rax

    mov rdi, [rdi]
    mov [rbp - ZK_ARG], rdi
    call zc_buffer
    test rax, rax
    jz .za_type
    mov rsi, rax
    mov [rbp - ZK_LEN], rdx
    mov rdi, [rbp - ZK_SEED]
    mov rdx, [rbp - ZK_LEN]
    call adler32 wrt ..plt
    mov rdi, rax
    mov edi, edi                    ; zero-extend: same as and 0xffffffff
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
.za_type:
    lea rdi, [rel zc_e_notbytes]
    mov rsi, [rbp - ZK_ARG]
    call set_type_error_with_name
    jmp .za_fail
.za_nargs:
    SET_EXC exc_TypeError_type, "_zlibcore: wrong number of arguments"
.za_fail:
    xor eax, eax
    leave
    ret
END_FUNC zc_adler32

;; ============================================================================
;; _zlibcore.stream_new(mode, level, wbits, memLevel, strategy) -> int handle
;;
;; mode 0 opens a deflate stream, 1 an inflate.  wbits carries zlib's three
;; conventions in one number and is passed straight through: positive is a
;; zlib wrapper, negative is raw deflate (which is what zipfile and tarfile
;; ask for), and 16 added on top is a gzip wrapper.
;;
;; deflateInit2_ and inflateInit2_ are the versioned forms, and they check the
;; version string and the struct size against what they were built with --
;; which is exactly the check worth having when the struct is written out by
;; hand in another language.
;; ============================================================================
ZN_H     equ 8
ZN_MODE  equ 16
ZN_LEVEL equ 24
ZN_WBITS equ 32
ZN_MEML  equ 40
ZN_STRAT equ 48
ZN_FRAME equ 72             ; + 1 push = 80, 16-aligned
DEF_FUNC zc_stream_new, ZN_FRAME
    push r12
    mov r12, rsp
    and rsp, -16                ; libz uses aligned SSE; see zc_stream_feed
    cmp rsi, 5
    jne .zn_nargs
    push rdi
    sub rsp, 8
%assign i 0
%rep 5
    mov rdi, [rsp + 8]
    mov rsi, i
    call zc_arg_int
    ERR_M1 .zn_fail
    mov [rbp - ZN_MODE - i*8], rax
%assign i i+1
%endrep
    add rsp, 8
    pop rdi

    mov edi, ZHandle_size
    call ap_malloc
    test rax, rax
    jz .zn_mem
    mov [rbp - ZN_H], rax
    mov rdi, rax
    xor esi, esi
    mov edx, ZHandle_size
    call ap_memset

    mov rax, [rbp - ZN_H]
    mov qword [rax + ZHandle.magic], ZC_MAGIC
    mov rcx, [rbp - ZN_MODE]
    mov [rax + ZHandle.mode], rcx
    test rcx, rcx
    jnz .zn_inflate

    ; deflateInit2_(strm, level, Z_DEFLATED, wbits, memLevel, strategy,
    ;               version, sizeof(z_stream)) -- the last two are libz's own
    ; check that the caller was built against the same header, which is
    ; exactly the check worth having when the struct is written out by hand
    ; in another language.
    call zlibVersion wrt ..plt
    push rax                        ; two pushes: rsp keeps its alignment
    push qword ZStream_size
    mov rdi, [rbp - ZN_H]
    lea rdi, [rdi + ZHandle.zs]
    mov esi, [rbp - ZN_LEVEL]
    mov edx, Z_DEFLATED
    mov ecx, [rbp - ZN_WBITS]
    mov r8d, [rbp - ZN_MEML]
    mov r9d, [rbp - ZN_STRAT]
    mov r10, [rsp + 8]              ; version
    mov r11, [rsp]                  ; sizeof
    mov [rsp], r10
    mov [rsp + 8], r11
    call deflateInit2_ wrt ..plt
    add rsp, 16
    jmp .zn_check

.zn_inflate:
    ; inflateInit2_(strm, wbits, version, sizeof(z_stream))
    call zlibVersion wrt ..plt
    mov rdx, rax
    mov rcx, ZStream_size
    mov rdi, [rbp - ZN_H]
    lea rdi, [rdi + ZHandle.zs]
    mov esi, [rbp - ZN_WBITS]
    call inflateInit2_ wrt ..plt

.zn_check:
    test eax, eax
    jnz .zn_init_failed

    mov rdi, [rbp - ZN_H]
    call zc_handle_alloc
    test rax, rax
    jl .zn_table_failed
    mov rdi, rax
    call int_from_i64
    mov rsp, r12
    pop r12
    leave
    V_PACK rax, rdx
    ret

.zn_init_failed:
    mov rdi, [rbp - ZN_H]
    call ap_free
    FAIL exc_ValueError_type, "failed to initialise the compression stream", .zn_fail
.zn_table_failed:
    mov rdi, [rbp - ZN_H]
    call ap_free
.zn_mem:
    FAIL exc_ValueError_type, "out of memory while compressing", .zn_fail
.zn_nargs:
    SET_EXC exc_TypeError_type, "_zlibcore: wrong number of arguments"
.zn_fail:
    xor eax, eax
    mov rsp, r12                ; r12 is the interpreter's frame: it goes back
    pop r12
    leave
    ret
END_FUNC zc_stream_new

;; ============================================================================
;; zc_handle_alloc(rdi = a new ZHandle*) -> rax = its index, or -1
;;
;; A freed slot is reused; the table itself only ever grows.
;; ============================================================================
ZA_H     equ 8
ZA_CAP   equ 16
ZA_FRAME equ 32             ; + 1 push = 40... padded below
DEF_FUNC_LOCAL zc_handle_alloc, 40
    push rbx
    mov [rbp - ZA_H], rdi
    xor ebx, ebx
.za_scan:
    cmp rbx, [rel zc_handle_n]
    jae .za_append
    mov rax, [rel zc_handles]
    cmp qword [rax + rbx*8], 0
    je .za_take
    inc rbx
    jmp .za_scan
.za_take:
    mov rcx, [rbp - ZA_H]
    mov [rax + rbx*8], rcx
    mov rax, rbx
    pop rbx
    leave
    ret

.za_append:
    mov rax, [rel zc_handle_n]
    cmp rax, [rel zc_handle_cap]
    jb .za_have_room
    mov rax, [rel zc_handle_cap]
    test rax, rax
    jnz .za_double
    mov eax, 8
    jmp .za_grow
.za_double:
    add rax, rax
.za_grow:
    mov [rbp - ZA_CAP], rax
    mov rdi, [rel zc_handles]
    mov rsi, rax
    shl rsi, 3
    call ap_realloc
    test rax, rax
    jz .za_fail
    mov [rel zc_handles], rax
    mov rcx, [rbp - ZA_CAP]
    mov [rel zc_handle_cap], rcx
.za_have_room:
    mov rax, [rel zc_handle_n]
    mov rcx, [rel zc_handles]
    mov rdx, [rbp - ZA_H]
    mov [rcx + rax*8], rdx
    inc qword [rel zc_handle_n]
    pop rbx
    leave
    ret
.za_fail:
    mov rax, -1
    pop rbx
    leave
    ret
END_FUNC zc_handle_alloc

;; ============================================================================
;; _zlibcore.stream_feed(handle, data, flush, max_length) -> bytes
;;
;; Push `data` through the stream and answer everything that came out.  The
;; input is COPIED first, and whatever the last call did not consume is copied
;; in front of it: libz keeps next_in pointing into that buffer for the length
;; of the loop, and a bytes handed in from Python is not ours to pin.
;;
;; max_length > 0 stops once that much output exists and parks the rest of the
;; input in the handle, where stream_state hands it back as unconsumed_tail --
;; which is the whole reason decompressobj takes the argument.
;;
;; The output buffer is grown by doubling while libz writes into it and copied
;; into a bytes only at the end, when its final length is known.
;; ============================================================================
ZF_ARGS   equ 8
ZF_INBUF  equ 16            ; the owned input copy
ZF_INLEN  equ 24
ZF_FLUSH  equ 32
ZF_MAX    equ 40
ZF_OUT    equ 48            ; the owned output buffer
ZF_OUTCAP equ 56
ZF_OUTLEN equ 64
ZF_RES    equ 72            ; the bytes, while the buffers are freed
ZF_FRAME  equ 80            ; + 2 pushes = 96, 16-aligned
DEF_FUNC zc_stream_feed, ZF_FRAME
    push rbx
    push r12
    ; libz's inflate stores to its own frame with `movaps`, so it faults --
    ; a general protection fault inside the library, not a wrong answer -- if
    ; rsp is 8 out when it is called.  This function is reached at both
    ; alignments, because func_call is (see bugs.md), so it aligns rsp for
    ; itself rather than trusting the caller.  The frame slots are rbp-based
    ; and do not move.  int_true_divide does the same for glibc's strtod.
    mov r12, rsp
    and rsp, -16
    cmp rsi, 4
    jne .zf_nargs
    mov [rbp - ZF_ARGS], rdi
    mov qword [rbp - ZF_INBUF], 0
    mov qword [rbp - ZF_OUT], 0

    xor esi, esi
    call zc_arg_int
    ERR_M1 .zf_fail
    mov rdi, rax
    call zc_handle_at
    test rax, rax
    jz .zf_bad_handle
    mov rbx, rax
    cmp qword [rbx + ZHandle.ended], 0
    jne .zf_ended

    mov rdi, [rbp - ZF_ARGS]
    mov esi, 2
    call zc_arg_int
    ERR_M1 .zf_fail
    mov [rbp - ZF_FLUSH], rax
    mov rdi, [rbp - ZF_ARGS]
    mov esi, 3
    call zc_arg_int
    ERR_M1 .zf_fail
    mov [rbp - ZF_MAX], rax

    ; --- the input: the handle's leftover, then what was handed in ---------
    mov rdi, [rbp - ZF_ARGS]
    mov rdi, [rdi + 8]
    call zc_buffer
    test rax, rax
    jnz .zf_have_buf
    mov rdx, [rbp - ZF_ARGS]
    cmp qword [rdx + 8], 0      ; an empty bytes is a pointer, so 0 is a type
    jmp .zf_type                ; error however it got here
.zf_have_buf:
    mov r10, rax                ; the caller's data, borrowed
    mov r11, rdx                ; its length
    mov rax, [rbx + ZHandle.tail_len]
    add rax, r11
    mov [rbp - ZF_INLEN], rax
    test rax, rax
    jz .zf_input_ready

    push r10
    push r11
    mov rdi, rax
    call ap_malloc
    pop r11
    pop r10
    test rax, rax
    jz .zf_mem
    mov [rbp - ZF_INBUF], rax

    mov rdx, [rbx + ZHandle.tail_len]
    test rdx, rdx
    jz .zf_copy_new
    push r10
    push r11
    mov rdi, rax
    mov rsi, [rbx + ZHandle.tail]
    call ap_memcpy
    pop r11
    pop r10
.zf_copy_new:
    test r11, r11
    jz .zf_input_ready
    mov rdi, [rbp - ZF_INBUF]
    add rdi, [rbx + ZHandle.tail_len]
    mov rsi, r10
    mov rdx, r11
    call ap_memcpy

.zf_input_ready:
    ; The leftover has been folded in; the handle no longer owns it.
    mov rdi, [rbx + ZHandle.tail]
    mov qword [rbx + ZHandle.tail], 0
    mov qword [rbx + ZHandle.tail_len], 0
    test rdi, rdi
    jz .zf_tail_gone
    call ap_free
.zf_tail_gone:
    mov rax, [rbp - ZF_INBUF]
    mov [rbx + ZHandle.zs + ZStream.next_in], rax
    mov rax, [rbp - ZF_INLEN]
    mov [rbx + ZHandle.zs + ZStream.avail_in], eax

    ; --- the output buffer -------------------------------------------------
    ;
    ; A max_length SMALLER than the default sizes the buffer exactly, because
    ; that is the only way the cap is ever reached: with a buffer larger than
    ; the cap, libz finishes in one pass, avail_out never falls to zero and
    ; the whole answer comes back at once.  A larger one is only a ceiling --
    ; allocating it up front would mean a 2 GB malloc for a caller that asked
    ; for "up to everything", which is what gzip's reader does.
    mov rdi, ZC_INITIAL_OUT
    mov rcx, [rbp - ZF_MAX]
    test rcx, rcx
    jz .zf_out_size
    cmp rcx, rdi
    jae .zf_out_size
    mov rdi, rcx
.zf_out_size:
    mov [rbp - ZF_OUTCAP], rdi
    call ap_malloc
    test rax, rax
    jz .zf_mem
    mov [rbp - ZF_OUT], rax
    mov qword [rbp - ZF_OUTLEN], 0

.zf_loop:
    mov rax, [rbp - ZF_OUT]
    add rax, [rbp - ZF_OUTLEN]
    mov [rbx + ZHandle.zs + ZStream.next_out], rax
    mov rax, [rbp - ZF_OUTCAP]
    sub rax, [rbp - ZF_OUTLEN]
    mov [rbx + ZHandle.zs + ZStream.avail_out], eax

    lea rdi, [rbx + ZHandle.zs]
    mov esi, [rbp - ZF_FLUSH]
    cmp qword [rbx + ZHandle.mode], 0
    jne .zf_inflate
    call deflate wrt ..plt
    jmp .zf_after
.zf_inflate:
    call inflate wrt ..plt
.zf_after:
    mov r9d, eax                        ; the return code

    ; What came out: the room that was there, less the room that is left.
    mov rax, [rbp - ZF_OUTCAP]
    mov ecx, [rbx + ZHandle.zs + ZStream.avail_out]
    sub rax, rcx
    mov [rbp - ZF_OUTLEN], rax

    cmp r9d, Z_STREAM_END
    je .zf_stream_end
    cmp r9d, Z_BUF_ERROR
    je .zf_done                         ; no progress possible: that is an end
    cmp r9d, Z_OK
    jne .zf_zerror

    ; Still going.  A full output buffer means grow and continue; room left
    ; over means libz had nothing more to write on this pass.
    cmp dword [rbx + ZHandle.zs + ZStream.avail_out], 0
    jne .zf_done

    mov rcx, [rbp - ZF_MAX]
    test rcx, rcx
    jz .zf_grow
    cmp [rbp - ZF_OUTLEN], rcx
    jae .zf_done                        ; the cap is reached; park the rest
.zf_grow:
    mov rax, [rbp - ZF_OUTCAP]
    add rax, rax
    mov rcx, [rbp - ZF_MAX]
    test rcx, rcx
    jz .zf_grow_to
    cmp rax, rcx
    jbe .zf_grow_to
    mov rax, rcx                ; never past the ceiling the caller named
.zf_grow_to:
    mov rdi, [rbp - ZF_OUT]
    mov rsi, rax
    push rax
    sub rsp, 8
    call ap_realloc
    add rsp, 8
    pop rcx
    test rax, rax
    jz .zf_mem
    mov [rbp - ZF_OUT], rax
    mov [rbp - ZF_OUTCAP], rcx
    jmp .zf_loop

.zf_stream_end:
    mov qword [rbx + ZHandle.eof], 1
    ; Input past the end of the stream belongs to whoever comes next: gzip
    ; reads it to find the following member.
    mov ecx, [rbx + ZHandle.zs + ZStream.avail_in]
    test rcx, rcx
    jz .zf_done
    mov rdi, rcx
    push rcx
    sub rsp, 8
    call ap_malloc
    add rsp, 8
    pop rcx
    test rax, rax
    jz .zf_done
    mov [rbx + ZHandle.unused], rax
    mov [rbx + ZHandle.unused_len], rcx
    mov rdi, rax
    mov rsi, [rbx + ZHandle.zs + ZStream.next_in]
    mov rdx, rcx
    call ap_memcpy
    mov dword [rbx + ZHandle.zs + ZStream.avail_in], 0

.zf_done:
    ; Whatever is left unconsumed is the caller's unconsumed_tail, and has to
    ; outlive the input copy this call owns.
    mov ecx, [rbx + ZHandle.zs + ZStream.avail_in]
    test rcx, rcx
    jz .zf_no_tail
    mov rdi, rcx
    push rcx
    sub rsp, 8
    call ap_malloc
    add rsp, 8
    pop rcx
    test rax, rax
    jz .zf_no_tail
    mov [rbx + ZHandle.tail], rax
    mov [rbx + ZHandle.tail_len], rcx
    mov rdi, rax
    mov rsi, [rbx + ZHandle.zs + ZStream.next_in]
    mov rdx, rcx
    call ap_memcpy
.zf_no_tail:
    mov dword [rbx + ZHandle.zs + ZStream.avail_in], 0
    mov qword [rbx + ZHandle.zs + ZStream.next_in], 0

    mov rdi, [rbp - ZF_OUT]
    mov rsi, [rbp - ZF_OUTLEN]
    call bytes_from_data
    test rax, rax
    jz .zf_mem
    mov [rbp - ZF_RES], rax
    call zc_release_buffers
    mov rax, [rbp - ZF_RES]
    mov edx, TAG_PTR
    mov rsp, r12
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.zf_zerror:
    mov rdi, rbx
    mov esi, r9d                ; the code
    call zc_set_z
    jmp .zf_fail
.zf_mem:
    FAIL exc_ValueError_type, "out of memory while compressing", .zf_fail
.zf_type:
    lea rdi, [rel zc_e_notbytes]
    mov rsi, [rbp - ZF_ARGS]
    mov rsi, [rsi + 8]
    call set_type_error_with_name
    jmp .zf_fail
.zf_bad_handle:
    FAIL exc_ValueError_type, "invalid stream handle", .zf_fail
.zf_ended:
    FAIL exc_ValueError_type, "stream is already finished", .zf_fail
.zf_nargs:
    ; Before the two buffer slots are initialised, so not through the release.
    FAIL exc_TypeError_type, "_zlibcore: wrong number of arguments", .zf_fail_bare
.zf_fail:
    ; The one error exit: the exception is pending, and the input copy and
    ; the output buffer -- whichever exist -- are this call's to free.
    call zc_release_buffers
.zf_fail_bare:
    xor eax, eax
    mov rsp, r12
    pop r12
    pop rbx
    leave
    ret

;; The two malloc'd buffers this call owns, released on every way out.  A
;; local label rather than a function, because it reads the caller's frame.
zc_release_buffers:
    mov rdi, [rbp - ZF_INBUF]
    mov qword [rbp - ZF_INBUF], 0
    test rdi, rdi
    jz .zrb_out
    push rax
    sub rsp, 8
    call ap_free
    add rsp, 8
    pop rax
.zrb_out:
    mov rdi, [rbp - ZF_OUT]
    mov qword [rbp - ZF_OUT], 0
    test rdi, rdi
    jz .zrb_done
    push rax
    sub rsp, 8
    call ap_free
    add rsp, 8
    pop rax
.zrb_done:
    ret
END_FUNC zc_stream_feed

;; ============================================================================
;; _zlibcore.stream_state(handle) -> (eof, unconsumed_tail, unused_data)
;;
;; The three things a Decompress object reports and cannot compute for itself.
;; unused_data is taken away by this call, because gzip reads it once to find
;; the next member and must not see it again.
;; ============================================================================
ZS_H     equ 8
ZS_TUP   equ 16
ZS_FRAME equ 32             ; + 0 pushes = 32
DEF_FUNC zc_stream_state, ZS_FRAME
    cmp rsi, 1
    jne .zs_nargs
    xor esi, esi
    call zc_arg_int
    ERR_M1 .zs_fail
    mov rdi, rax
    call zc_handle_at
    test rax, rax
    jz .zs_bad_handle
    mov [rbp - ZS_H], rax

    mov edi, 3
    call tuple_new
    test rax, rax
    jz .zs_mem
    mov [rbp - ZS_TUP], rax

    mov rcx, [rbp - ZS_H]
    lea rax, [rel bool_false]
    cmp qword [rcx + ZHandle.eof], 0
    je .zs_have_eof
    lea rax, [rel bool_true]
.zs_have_eof:
    INCREF rax
    mov rdx, [rbp - ZS_TUP]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov [rdx], rax

    mov rcx, [rbp - ZS_H]
    mov rdi, [rcx + ZHandle.tail]
    mov rsi, [rcx + ZHandle.tail_len]
    call zc_bytes_or_empty
    mov rdx, [rbp - ZS_TUP]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov [rdx + 8], rax

    mov rcx, [rbp - ZS_H]
    mov rdi, [rcx + ZHandle.unused]
    mov rsi, [rcx + ZHandle.unused_len]
    call zc_bytes_or_empty
    mov rdx, [rbp - ZS_TUP]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov [rdx + 16], rax

    ; unused_data is handed over once and then forgotten.
    mov rcx, [rbp - ZS_H]
    mov rdi, [rcx + ZHandle.unused]
    mov qword [rcx + ZHandle.unused], 0
    mov qword [rcx + ZHandle.unused_len], 0
    test rdi, rdi
    jz .zs_done
    call ap_free
.zs_done:
    mov rax, [rbp - ZS_TUP]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.zs_mem:
    FAIL exc_ValueError_type, "out of memory while compressing", .zs_fail
.zs_bad_handle:
    FAIL exc_ValueError_type, "invalid stream handle", .zs_fail
.zs_nargs:
    SET_EXC exc_TypeError_type, "_zlibcore: wrong number of arguments"
.zs_fail:
    xor eax, eax
    leave
    ret
END_FUNC zc_stream_state

;; ============================================================================
;; _zlibcore.stream_drop_tail(handle) -> None
;;
;; Forget the unconsumed input the last feed parked, without decompressing it.
;;
;; Two objects are built on this stream and they disagree about who owns that
;; input.  _ZlibDecompressor holds it -- `needs_input` is how its reader knows
;; whether to go back to the file -- so stream_feed prepending the leftover to
;; the next call is exactly right for it.  zlib.Decompress does not: CPython
;; hands the leftover back as `unconsumed_tail` and the CALLER feeds it in
;; again, which is what every documented max_length loop does.  Prepending as
;; well meant the input doubled every round -- 315 bytes, then 630, then 1260
;; from a 356-byte stream -- until the process ran out of memory.  So
;; Decompress.decompress drops the parked copy first and passes the caller's.
;;
;; Decompress.flush does NOT, because CPython's flush() really does inflate
;; whatever is left in unconsumed_tail.
;; ============================================================================
ZD_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC zc_stream_drop_tail, ZD_FRAME
    cmp rsi, 1
    jne .zd_nargs
    xor esi, esi
    call zc_arg_int
    ERR_M1 .zd_fail
    mov rdi, rax
    call zc_handle_at
    test rax, rax
    jz .zd_bad_handle
    mov rdi, [rax + ZHandle.tail]
    mov qword [rax + ZHandle.tail], 0
    mov qword [rax + ZHandle.tail_len], 0
    test rdi, rdi
    jz .zd_done
    call ap_free
.zd_done:
    RET_NONE
    leave
    V_PACK rax, rdx
    ret

.zd_bad_handle:
    FAIL exc_ValueError_type, "invalid stream handle", .zd_fail
.zd_nargs:
    SET_EXC exc_TypeError_type, "_zlibcore: wrong number of arguments"
.zd_fail:
    xor eax, eax
    leave
    ret
END_FUNC zc_stream_drop_tail

;; ============================================================================
;; zc_bytes_or_empty(rdi = data or 0, rsi = length) -> rax = a bytes object
;; ============================================================================
DEF_FUNC_LOCAL zc_bytes_or_empty
    test rdi, rdi
    jnz .zbe_copy
    xor edi, edi
    leave
    jmp bytes_new
.zbe_copy:
    leave
    jmp bytes_from_data
END_FUNC zc_bytes_or_empty

;; ============================================================================
;; _zlibcore.stream_free(handle) -> None
;;
;; Ends the libz stream and gives the slot back.  lib/zlib.py calls it from
;; __del__, so a program that drops a compressobj mid-stream does not leak
;; libz's window -- 256 KB at the default settings, which a loop over a
;; thousand files would notice.
;; ============================================================================
ZR_IDX   equ 8              ; the slot to clear once the ZHandle is in hand
ZR_FRAME equ 24             ; + 1 push = 32, 16-aligned
DEF_FUNC zc_stream_free, ZR_FRAME
    push r12
    mov r12, rsp
    and rsp, -16                ; libz uses aligned SSE; see zc_stream_feed
    cmp rsi, 1
    jne .zr_nargs
    xor esi, esi
    call zc_arg_int
    ERR_M1 .zr_fail
    mov [rbp - ZR_IDX], rax
    mov rdi, rax
    call zc_handle_at
    test rax, rax
    jz .zr_none                 ; freeing twice is not an error
    mov rcx, [rel zc_handles]
    mov rdx, [rbp - ZR_IDX]
    mov qword [rcx + rdx*8], 0
    mov qword [rax + ZHandle.magic], 0

    push rax
    sub rsp, 8
    lea rdi, [rax + ZHandle.zs]
    cmp qword [rax + ZHandle.mode], 0
    jne .zr_inflate
    call deflateEnd wrt ..plt
    jmp .zr_ended
.zr_inflate:
    call inflateEnd wrt ..plt
.zr_ended:
    add rsp, 8
    pop rax

    mov rdi, [rax + ZHandle.tail]
    test rdi, rdi
    jz .zr_no_tail
    push rax
    sub rsp, 8
    call ap_free
    add rsp, 8
    pop rax
.zr_no_tail:
    mov rdi, [rax + ZHandle.unused]
    test rdi, rdi
    jz .zr_no_unused
    push rax
    sub rsp, 8
    call ap_free
    add rsp, 8
    pop rax
.zr_no_unused:
    mov rdi, rax
    call ap_free

.zr_none:
    LOAD_NONE rax
    mov edx, TAG_PTR
    mov rsp, r12
    pop r12
    leave
    V_PACK rax, rdx
    ret
.zr_nargs:
    SET_EXC exc_TypeError_type, "_zlibcore: wrong number of arguments"
.zr_fail:
    xor eax, eax
    mov rsp, r12
    pop r12
    leave
    ret
END_FUNC zc_stream_free

;; ============================================================================
;; zlib_module_create() -> PyObject*
;; ============================================================================
ZM_FRAME equ 8              ; + 3 pushes = 32, 16-aligned
DEF_FUNC zlib_module_create, ZM_FRAME
    push rbx
    push r12
    push r13

    call dict_new
    mov r12, rax                ; MODULE_ADD_FUNC reads the dict from r12

    MODULE_ADD_FUNC zc_crc32,        zn_crc32
    MODULE_ADD_FUNC zc_adler32,      zn_adler32
    MODULE_ADD_FUNC zc_stream_new,   zn_stream_new
    MODULE_ADD_FUNC zc_stream_feed,  zn_stream_feed
    MODULE_ADD_FUNC zc_stream_drop_tail, zn_stream_drop_tail
    MODULE_ADD_FUNC zc_stream_state, zn_stream_state
    MODULE_ADD_FUNC zc_stream_free,  zn_stream_free

    ; ZLIB_VERSION comes from the library that is actually linked, not from a
    ; constant compiled in here: a program that logs it should see the truth.
    lea rdi, [rel zn_version]
    call str_from_cstr_heap
    mov rbx, rax
    call zlibVersion wrt ..plt
    mov rdi, rax
    call str_from_cstr_heap
    mov r13, rax
    mov rdi, r12
    mov rsi, rbx
    mov rdx, r13
    call dict_set
    mov rdi, rbx
    call obj_decref
    mov rdi, r13
    call obj_decref

    lea rdi, [rel zc_modname]
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r12
    call module_new
    mov r13, rax
    mov rdi, rbx
    call obj_decref             ; module_new took its own
    mov rdi, r12
    call obj_decref
    mov rax, r13

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC zlib_module_create
